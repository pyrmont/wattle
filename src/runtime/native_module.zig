//! A dynamically loaded Janet module written in Zig: the proof that a `.so`
//! outside the runtime can define a builtin, and that all fifteen
//! abstract-type slots are writable from one.
//!
//! It is written against the published interface: `wattle` and `std` are its
//! whole import list, which is what makes it a proof of the thing a module
//! author actually uses. Reaching past that interface for the runtime's own
//! declarations would prove something else, and the comptime `StaticStringMap`
//! below is the point of saying so.
//!
//! A sentence claiming all fifteen slots are writable is not a proof, so
//! `Keeper` below sets every one of them and the claim is compiled.
//! `examples/numarray/numarray.zig` is the worked example an author reads; it
//! sets the seven a numeric array has a use for, and the rest are here.
//!
//! Loaded by `test/zig-native.janet`, which `zig build test` runs.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const wattle = @import("wattle");

// ==========================================================================
// Constants
// ==========================================================================

/// The gate `abandoned`'s thread waits at, so that the test decides when the
/// post happens rather than a sleep deciding it.
///
/// A spin rather than a semaphore, because `std.Thread` in Zig 0.16 has
/// neither: the blocking primitives live under `std.Io` and take an `Io`
/// instance a module has no reason to build. The wait is milliseconds long and
/// happens once in the test, and `yield` is what keeps it from being a busy
/// loop on a single-core runner.
var abandon_gate: std.atomic.Value(bool) = .init(false);

/// How many payloads the collector has finalized.
var finalized: u32 = 0;

/// All fifteen slots. Adding a slot to `abstract_type.Spec` and not to an
/// author's reach breaks this declaration.
const keeper_type = wattle.define(Keeper, .{
    .name = "zig-native/keeper",
    .gc = keeperGc,
    .gcmark = keeperMark,
    .get = keeperGet,
    .put = keeperPut,
    .marshal = keeperMarshal,
    .unmarshal = keeperUnmarshal,
    .tostring = keeperTostring,
    .compare = keeperCompare,
    .hash = keeperHash,
    .next = keeperNext,
    .call = keeperCall,
    .length = keeperLength,
    .bytes = keeperBytes,
    .gcperthread = keeperPerThread,
    .chunk = keeperChunk,
    .contents = .elements,
});

/// How many times the collector has reached `gcmark`.
///
/// A module-level `var`, as `finalized` is, because the point they prove is
/// that the slots are reached: a module cannot otherwise observe a traversal
/// or a sweep it did not start. Whether the collector then keeps a marked
/// value alive is the runtime's own behaviour, and `test/gc_stress.zig` is
/// where that is pinned.
var marks: u32 = 0;

/// What `get`'s keyword arm and `next` both walk.
const methods = [_]wattle.Method{
    .{ .name = "kept", .cfun = &kept },
    .{ .name = "rank", .cfun = &rank },
};

/// The serial number `keep` stamps each payload with, so that the marshal pair
/// has a 64-bit field to write and `tostring` something to show in.
var next_serial: i64 = 1;

/// A method table with a `:length`, which a call such as `(:length o)` finds
/// through `get`.
const odd_methods = [_]wattle.Method{.{ .name = "length", .cfun = &oddLength }};

/// No `length` slot, on purpose: `length` refuses such a type rather than
/// calling its `:length` method, as C Janet would.
const odd_type = wattle.define(Odd, .{ .name = "zig-native/odd", .get = oddGet });

/// What `pointerValue` hands out the address of. A file-scope variable rather
/// than a stack local, because the `Value` outlives the call.
var pointer_target: i64 = 0x5eed;

/// How many contexts the false branch of `wake` has freed.
var refused_freed: u32 = 0;

/// The keyword options `markup` accepts, and what each contributes.
///
/// This is the twelve-entry lookup table a C module builds, dissolved. The
/// reference module allocates a Janet table at first use, roots it against the
/// collector so it survives the program, and puts one row per option into it:
/// a table, a root, twelve puts and a get, all to map a name fixed at compile
/// time to a small integer fixed at compile time. A `StaticStringMap` is that
/// map with no allocation and nothing for the collector to traverse, so this
/// module asks the runtime for none of it.
const render_options = std.StaticStringMap(u32).initComptime(.{
    .{ "sourcepos", 1 },
    .{ "hardbreaks", 2 },
    .{ "smart", 4 },
    .{ "footnotes", 8 },
});

/// How many times either marshal callback has seen the unsafe flag set.
///
/// It stays zero, and that is the assertion. Janet's own `marshal` cfunction
/// exposes only the no-cycles flag, so nothing a Janet program can write
/// reaches this type in unsafe mode. What the counter is really for is the
/// compile: `isUnsafe` takes `anytype` and decides at comptime, so calling it
/// on a `*Marshal` here and on an `*Unmarshal` below is what says both arms
/// instantiate.
var unsafe_seen: u32 = 0;

/// How many times a callback has seen `wake` report false.
///
/// This and `refused_freed` are two counters rather than one because the point
/// of the false branch is that the cleanup happens on it: a module that freed
/// its context only on the true branch would leak exactly the case
/// `ev/cancel` produces.
var wake_refused: u32 = 0;

// ==========================================================================
// Types
// ==========================================================================

/// A payload of a `Value`, a rank and six bytes: one field per group of
/// callbacks that needs something to act on.
///
/// `kept` is what `gcmark` marks and `call` returns; `rank` is what `compare`
/// and `hash` are computed from; `text` is what `bytes`, `tostring` and
/// `length` report. `codes` is `text` converted to numbers, which is what
/// `chunk` hands out, since a run is made of `Value`s and `text` is bytes.
const Keeper = struct {
    kept: wattle.Value,
    rank: i32,
    serial: i64,
    text: [6]u8,
    codes: [6]wattle.Value,
};

/// An abstract type with a `:length` method and no `length` slot, which
/// `length` refuses rather than calling the method. The payload is a byte
/// because an abstract needs one to exist.
const Odd = struct { unused: u8 = 0 };

/// What several threads posting at once share.
///
/// `arrived` needs no lock, which is what the fixture is showing. Posted
/// callbacks run one at a time on the loop thread, so the increment below is
/// as safe as a
/// single-threaded one however many threads posted; nothing here depends on
/// the order they arrive in, which is the one thing the loop does not promise.
const Stampede = struct {
    loop: *wattle.Loop,
    fiber: wattle.Value,
    expected: u32,
    arrived: u32,
};

/// What one waiting fiber's thread is given, and what its callback frees.
///
/// `loop` and `fiber` are read on the loop thread before the fiber suspends;
/// `answer` is written by the worker and read by the callback, which are two
/// different threads with the post between them.
const Work = struct {
    loop: *wattle.Loop,
    fiber: wattle.Value,
    answer: f64,
};

// ==========================================================================
// Private functions
// ==========================================================================

/// The `false` branch of `wake`, which is what `abandoned` exists to reach.
///
/// `ev/cancel` has moved the fiber on, so the resume would have been dropped;
/// the context is still this module's to free, and so is the root on the
/// fiber. Doing both here rather than under the `true` branch is the whole
/// difference between this callback and `workDone` above.
fn abandonDone(w: *wattle.Wake, raw: *anyopaque) callconv(.c) void {
    const work: *Work = @ptrCast(@alignCast(raw));
    if (!wattle.wake(w, work.fiber, wattle.number(work.answer))) {
        wake_refused += 1;
        refused_freed += 1;
    }
    _ = wattle.gcunroot(work.fiber);
    wattle.free(work);
}

/// Waits at the gate, then posts.
fn abandonThread(work: *Work) void {
    while (!abandon_gate.load(.acquire)) std.Thread.yield() catch {};
    work.answer = 0;
    wattle.post(work.loop, &abandonDone, work);
}

/// `(abandoned)`: a fiber whose thread posts only once released, so that the
/// test can cancel it in between and reach `wake`'s `false`.
fn abandoned(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 0);
    const l = try wattle.loop();
    const fiber = try wattle.rootFiber();
    const cells = wattle.alloc(Work, 1) orelse return wattle.panic("out of memory");
    const work = &cells[0];
    work.* = .{ .loop = l, .fiber = fiber, .answer = 0 };
    wattle.gcroot(work.fiber);
    const thread = std.Thread.spawn(.{}, abandonThread, .{work}) catch {
        _ = wattle.gcunroot(work.fiber);
        wattle.free(work);
        return wattle.panic("could not start a thread");
    };
    thread.detach();
    return wattle.await();
}

/// `(apply f & args)`: `call`, which raises on anything but a return.
fn apply(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.arity(argv, 1, -1);
    return wattle.call(argv[0], argv[1..]);
}

/// `(attempt f & args)`: `pcall`, as `[signal value fiber]`.
///
/// The signal comes back as a keyword built from `@tagName`, which is the
/// enum's own spelling rather than `fiber/status`'s: `user8` and `user9` print
/// as themselves where Janet prints `:interrupted` and `:suspended`. The
/// surface publishes the vocabulary and no name table, so a module needing
/// Janet's spelling writes it.
///
/// The fiber is handed on as it is. `pcall` refuses a callee that is not a
/// function before it makes one, and the fiber slot is then nil, which is the
/// one thing about the result a caller has to test before asking
/// `fiberStatus` about it.
fn attempt(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.arity(argv, 1, -1);
    const called = wattle.pcall(argv[0], argv[1..]);
    const row = [_]wattle.Value{
        wattle.keyword(@tagName(called.signal)),
        called.value,
        called.fiber,
    };
    return wattle.tuple(&row);
}

/// `(built bytes)`: one of every composite, built from the argument, in a
/// tuple. Janet's own equality is what checks them.
///
/// Every constructor takes exactly what the getter of the same type returns.
/// `built` passes the slice `getBytes` returns straight to `string`, `symbol`,
/// `keyword` and `buffer`, and passes a `[]const Value` to `tuple` and
/// `array`.
fn built(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 1);
    // The slice goes straight into the three interning constructors: no
    // copy, no length recomputed, and a buffer argument works as a string one
    // does.
    const seed = try wattle.getBytes(argv, 0);
    const items = [_]wattle.Value{ wattle.number(1), wattle.number(2) };
    // Pairs, not a hash array. `mapOf` and `tableOf` take what the caller
    // wrote; a table's own storage is slots with empties among them, and
    // `Dictionary` is what reads that.
    const pairs = [_]wattle.Keyval{
        .{ .key = wattle.keyword("a"), .value = wattle.number(1) },
        .{ .key = wattle.keyword("b"), .value = wattle.number(2) },
    };
    const composites = [_]wattle.Value{
        wattle.boolean(true),
        wattle.boolean(false),
        wattle.string(seed),
        wattle.symbol(seed),
        wattle.keyword(seed),
        wattle.tuple(&items),
        wattle.array(&items),
        wattle.buffer(seed),
        wattle.mapOf(&pairs),
        wattle.tableOf(&pairs),
    };
    return wattle.tuple(&composites);
}

/// `(classify x)`: the tag of a value, named.
///
/// One cfunction over all fourteen predicates, because what they are for is
/// telling apart the types one getter accepts, and a module that has them all
/// has no reason to reach for anything else. `isFunction` and `isCFunction`
/// are the odd ones out: what the pair is for is refusing a callback `call`
/// could not run, and `isFunction` alone a callback `pcall` could not run, at
/// the point the callback is handed over rather than at the call.
fn classify(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 1);
    const v = argv[0];
    const name: [:0]const u8 = if (wattle.isNil(v))
        "nil"
    else if (wattle.isBoolean(v))
        "boolean"
    else if (wattle.isNumber(v))
        "number"
    else if (wattle.isPointer(v))
        "pointer"
    else if (wattle.isString(v))
        "string"
    else if (wattle.isSymbol(v))
        "symbol"
    else if (wattle.isKeyword(v))
        "keyword"
    else if (wattle.isBuffer(v))
        "buffer"
    else if (wattle.isTuple(v))
        "tuple"
    else if (wattle.isArray(v))
        "array"
    else if (wattle.isMap(v))
        "map"
    else if (wattle.isTable(v))
        "table"
    else if (wattle.isFunction(v))
        "function"
    else if (wattle.isCFunction(v))
        "cfunction"
    else
        "other";
    return wattle.cstring(name);
}

/// `(cut bytes &opt start end)`: a slice of a byte argument.
///
/// The length handed to `getRange` is the slice's own, so the negative index,
/// the absent slot and the clamp are the ones every core builtin taking a
/// slice already has.
fn cut(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.arity(argv, 1, 3);
    const bytes = try wattle.getBytes(argv, 0);
    const range: wattle.Range = try wattle.getRange(argv, 1, bytes.len);
    const from: usize = @intCast(range.start);
    const to: usize = @intCast(range.end);
    var out: [256]u8 = undefined;
    if (to - from >= out.len) return wattle.panic("slice does not fit");
    @memcpy(out[0 .. to - from], bytes[from..to]);
    out[to - from] = 0;
    return wattle.cstring(out[0 .. to - from :0]);
}

/// The module's entry point: registers the abstract type and the cfunctions.
///
/// A type with an `unmarshal` callback has to be registered, or the
/// unmarshaller never finds it: an abstract names its type on the wire and
/// resolves it through the runtime's registry. That registration is what this
/// may raise for.
fn defs(env: *wattle.Env) wattle.Error!void {
    // A type with an `unmarshal` callback has to be registered, or the
    // unmarshaller never finds it: an abstract names its type on the wire and
    // resolves it through the runtime's registry. This is what `defs` may
    // raise for.
    try wattle.registerAbstract(&keeper_type);
    wattle.cfuns(env, "zig-native", &.{
        wattle.reg(
            "identity",
            &identity,
            "(identity x)\n\nRound-trip a Wattle value through a dynamically loaded Zig module.",
        ),
        wattle.reg("keep", &keep, "(keep x &opt rank)\n\nAn abstract holding x, with every callback set."),
        wattle.reg("kept", &kept, "(kept keeper)\n\nThe value a keeper holds."),
        wattle.reg("rank", &rank, "(rank keeper)\n\nThe rank compare and hash are computed from."),
        wattle.reg("mark-count", &markCount, "(mark-count)\n\nHow many times gcmark has been reached."),
        wattle.reg("finalized-count", &finalizedCount, "(finalized-count)\n\nHow many keepers have been finalized."),
        wattle.reg("unsafe-seen", &unsafeSeen, "(unsafe-seen)\n\nHow many marshal callbacks saw the unsafe flag."),
        wattle.reg("greeting", &greeting, "(greeting)\n\nA string built by the module."),
        wattle.reg("markup", &markup, "(markup bytes &opt opts strict)\n\nA byte argument and a tuple of keyword options."),
        wattle.reg("tally", &tally, "(tally dict)\n\nThe sum of a struct's or a table's numeric values."),
        wattle.reg("cut", &cut, "(cut bytes &opt start end)\n\nA slice of a byte argument."),
        wattle.reg("wrap", &wrap, "(wrap bytes width)\n\nThe first width bytes."),
        wattle.reg("classify", &classify, "(classify x)\n\nThe name of a value's type."),
        wattle.reg("named", &named, "(named x)\n\nThe name of a string, a symbol or a keyword."),
        wattle.reg("peek", &peek, "(peek indexed n)\n\nThe value the keeper at index n holds."),
        wattle.reg("viewed", &viewed, "(viewed x)\n\nWhich Value-form getter reads a value, and its length."),
        wattle.reg("walked", &walked, "(walked indexed)\n\nAn indexed argument read with next, get and nextChunk."),
        wattle.reg("built", &built, "(built bytes)\n\nOne of every composite, built from the argument."),
        wattle.reg("pointer-value", &pointerValue, "(pointer-value)\n\nA raw pointer as a value."),
        wattle.reg("mutate", &mutate, "(mutate array table buffer)\n\nThe three mutations, through the Value."),
        wattle.reg("fetch", &fetch, "(fetch ds key)\n\nWattle's own get, over anything."),
        wattle.reg("size", &size, "(size x)\n\nThe generic length."),
        wattle.reg("odd", &oddValue, "(odd)\n\nAn abstract with a :length method and no length slot."),
        wattle.reg("apply", &apply, "(apply f & args)\n\nCall f on the current fiber, raising on anything but a return."),
        wattle.reg("invoke", &invoke, "(invoke name & args)\n\nCall the method name on the first of args."),
        wattle.reg("attempt", &attempt, "(attempt f & args)\n\nCall f on a fresh fiber, returning [signal value fiber]."),
        wattle.reg("status-of", &statusOf, "(status-of x)\n\nThe status of a fiber, refusing anything else."),
        wattle.reg("sorted", &sorted, "(sorted cmp indexed)\n\nAn insertion sort whose comparator is a Wattle function."),
        wattle.reg("kept-across", &keptAcross, "(kept-across f)\n\nA rooted value carried across a call into f."),
        wattle.reg("unkept-across", &unkeptAcross, "(unkept-across f)\n\nThe same with no root: the case the root exists for."),
        wattle.reg("later", &later, "(later x)\n\nA value computed on this module's own thread, awaited and woken."),
        wattle.reg("stampede", &stampede, "(stampede n)\n\nn threads posting at once; returns how many arrived."),
        wattle.reg("abandoned", &abandoned, "(abandoned)\n\nA wait whose thread posts only once released."),
        wattle.reg("release-abandoned", &releaseAbandoned, "(release-abandoned)\n\nLet the abandoned wait's thread post."),
        wattle.reg("wake-refused", &wakeRefused, "(wake-refused)\n\nHow many times wake has returned false."),
        wattle.reg("refused-freed", &refusedFreed, "(refused-freed)\n\nHow many contexts the false branch has freed."),
        wattle.reg("loop-available", &loopAvailable, "(loop-available)\n\nWhether the loop capability is available."),
    });
}

/// `(fetch ds key)`: Janet's own `get`, over anything.
fn fetch(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 2);
    return wattle.get(argv[0], argv[1]);
}

/// Converts a keeper's text into the numbers `chunk` hands out.
fn fillCodes(k: *Keeper) void {
    for (k.text, &k.codes) |byte, *code| code.* = wattle.number(@floatFromInt(byte));
}

/// `(finalized-count)`.
fn finalizedCount(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 0);
    return wattle.number(@floatFromInt(finalized));
}

/// `(greeting)`: a cfunction returning a string, which `wattle.cstring` is the
/// whole of.
fn greeting(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 0);
    return wattle.cstring("hello from a module");
}

/// `(identity x)`: a value round-tripped through a loaded module.
fn identity(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 1);
    return argv[0];
}

/// `(invoke name & args)`: `mcall`, with the method named by a keyword.
fn invoke(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.arity(argv, 1, -1);
    const name = wattle.toKeyword(argv[0]) orelse return wattle.panic("expected keyword");
    return wattle.mcall(name, argv[1..]);
}

/// `(keep x &opt rank)`: a new keeper.
fn keep(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.arity(argv, 1, 2);
    const given = if (argv.len == 2) try wattle.getInteger(argv, 1) else 0;
    const k = wattle.new(Keeper, &keeper_type, null);
    k.* = .{ .kept = argv[0], .rank = given, .serial = next_serial, .text = "keeper".*, .codes = undefined };
    fillCodes(k);
    next_serial += 1;
    return wattle.abstract(k);
}

/// The runtime reads the bytes where they are returned, so the slice may point
/// at the payload's own storage.
fn keeperBytes(self: *const Keeper, _: usize) []const u8 {
    return &self.text;
}

/// Calling the abstract gives back what it kept.
fn keeperCall(self: *Keeper, argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 0);
    return self.kept;
}

/// The codes of the text, in runs of four, so that a reader crosses a run
/// boundary. The runs are `codes[0..4]` and `codes[4..6]`.
fn keeperChunk(self: *Keeper, index: usize) wattle.Chunk {
    const start = index - index % 4;
    const end = @min(start + 4, self.codes.len);
    return .{ .items = self.codes[start..end], .start = start };
}

/// Both payloads really are this type: the runtime reaches this slot only for
/// two abstracts of it, which is what lets the parameters be `*const Keeper`
/// rather than erased pointers.
fn keeperCompare(a: *const Keeper, b: *const Keeper) i32 {
    if (a.rank < b.rank) return -1;
    return if (a.rank > b.rank) 1 else 0;
}

/// The finaliser, which counts rather than freeing: the payload is the
/// collector's.
fn keeperGc(_: *Keeper, _: usize) void {
    finalized += 1;
}

/// A keyword key is a method and an integer key indexes the text.
fn keeperGet(self: *Keeper, key: wattle.Value) wattle.Error!?wattle.Value {
    if (wattle.isKeyword(key)) return wattle.getMethod(key, &methods);
    const i = wattle.toInteger(key) orelse return wattle.panic("expected integer key");
    if (i < 0 or i >= self.text.len) return null;
    return wattle.number(@floatFromInt(self.text[@intCast(i)]));
}

/// The rank, spread over the word.
fn keeperHash(self: *const Keeper, _: usize) i32 {
    return self.rank *% 31;
}

/// The length of the text, which is what `length` reports for this type.
fn keeperLength(self: *Keeper, _: usize) wattle.Error!usize {
    return self.text.len;
}

/// The one thing this slot can do with a payload of a `Value`, and it needs a
/// crossing to do it: `gc/mark.zig` reads the thread-local VM, which a `.so`
/// cannot import.
fn keeperMark(self: *Keeper, _: usize) void {
    marks += 1;
    wattle.mark(self.kept);
}

/// Every `push*` an author has except `pushPointer`, which is meaningful only
/// in unsafe mode, and `pushNumber`, which `examples/numarray` uses.
fn keeperMarshal(self: *Keeper, m: *wattle.Marshal) wattle.Error!void {
    if (wattle.isUnsafe(m)) unsafe_seen += 1;
    wattle.pushAbstract(m, self);
    try wattle.pushInteger(m, self.rank);
    try wattle.pushInt64(m, self.serial);
    try wattle.pushByte(m, @intCast(self.text.len));
    try wattle.pushBytes(m, &self.text);
    try wattle.pushValue(m, self.kept);
}

/// The iteration order behind `next` and `(keys k)`.
fn keeperNext(self: *Keeper, key: wattle.Value) wattle.Error!wattle.Value {
    _ = self;
    return wattle.nextMethod(&methods, key);
}

/// Runs only for a threaded abstract, and this module makes none. It is here
/// because every slot has to be spellable to be counted.
fn keeperPerThread(_: *Keeper, _: usize) void {}

/// A keyword key sets the rank, and anything else is refused.
fn keeperPut(self: *Keeper, key: wattle.Value, value: wattle.Value) wattle.Error!void {
    if (!wattle.isKeyword(key)) return wattle.panic("expected a keyword key");
    self.rank = wattle.toInteger(value) orelse return wattle.panic("expected an integer value");
}

/// The text, then the rank and the serial number.
fn keeperTostring(self: *Keeper, render: *wattle.Render) wattle.Error!void {
    try wattle.push(render, &self.text);
    try wattle.format(render, "#{d}@{d}", .{ self.rank, self.serial });
}

/// And every `pull*` except the two that mirror the omissions in
/// `keeperMarshal`.
fn keeperUnmarshal(u: *wattle.Unmarshal) wattle.Error!*Keeper {
    if (wattle.isUnsafe(u)) unsafe_seen += 1;
    const keeper = try wattle.pullAbstract(u, Keeper, null);
    // Every field written before anything else can raise: the block is on the
    // collector's heap list from the line above, so a raise in the middle
    // would hand `gc` and `gcmark` a payload that was never written.
    keeper.* = .{ .kept = wattle.nil(), .rank = 0, .serial = 0, .text = @splat(0), .codes = @splat(wattle.number(0)) };
    keeper.rank = try wattle.pullInteger(u);
    keeper.serial = try wattle.pullInt64(u);
    const len = try wattle.pullByte(u);
    if (len != keeper.text.len) return wattle.panic("wrong keeper text length");
    // The stream is asked for the bytes before they are read, which is what
    // `pullEnsure` is for: `pullBytes` would refuse at the same point, and a
    // callback with more to allocate than this one has is better off knowing
    // first.
    try wattle.pullEnsure(u, len);
    try wattle.pullBytes(u, &keeper.text);
    fillCodes(keeper);
    keeper.kept = try wattle.pullValue(u);
    return keeper;
}

/// `(kept keeper)`.
fn kept(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 1);
    const k = try wattle.getAbstract(Keeper, argv, 0, &keeper_type);
    return k.kept;
}

/// `(kept-across f)`: a composite built here, rooted, kept across a call into
/// `f`, and given back intact.
///
/// `f` is expected to run `(gccollect)`, which is one of the two callers of
/// `gc/mark.zig`'s `collect` and therefore one of the two places a collection
/// happens at all. Without the root, what is built below is reachable from
/// nothing the collector scans while `f` runs.
fn keptAcross(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 1);
    const pairs = [_]wattle.Keyval{
        .{ .key = wattle.keyword("kept"), .value = wattle.string("across a collection") },
    };
    const held = wattle.tableOf(&pairs);
    wattle.gcroot(held);
    defer _ = wattle.gcunroot(held);
    _ = try wattle.call(argv[0], &.{});
    return held;
}

/// `(later x)`: a value computed on this module's own thread.
///
/// The order is what a caller has to keep: read the loop and the fiber, root
/// the fiber, start the thread, and only then suspend. Starting the thread
/// before the suspend is not a race, because the loop is single-threaded, so
/// an event posted before this cfunction has returned is not processed until
/// the fiber has suspended.
fn later(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 1);
    const l = try wattle.loop();
    const fiber = try wattle.rootFiber();
    const cells = wattle.alloc(Work, 1) orelse return wattle.panic("out of memory");
    const work = &cells[0];
    work.* = .{ .loop = l, .fiber = fiber, .answer = try wattle.getNumber(argv, 0) };
    wattle.gcroot(work.fiber);
    const thread = std.Thread.spawn(.{}, workThread, .{work}) catch {
        _ = wattle.gcunroot(work.fiber);
        wattle.free(work);
        return wattle.panic("could not start a thread");
    };
    thread.detach();
    return wattle.await();
}

/// `(loop-available)`: whether the loop capability can be obtained.
///
/// This is what a build without the event loop is tested through. The four
/// loop fields are filled in every build and `loop` is the one that refuses,
/// so a module asking for the capability is exactly where the refusal shows
/// up. Every other shape here calls `loop` first for the same reason.
fn loopAvailable(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 0);
    _ = wattle.loop() catch return wattle.boolean(false);
    return wattle.boolean(true);
}

/// `(mark-count)`.
fn markCount(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 0);
    return wattle.number(@floatFromInt(marks));
}

/// `(markup bytes &opt opts strict)`: markable's shape.
///
/// Four steps, and every one of them was unreachable from a module before the
/// getters this file exercises existed: reading the byte argument, reading the
/// indexed argument, reading a keyword out of it, and refusing with a message
/// naming what was wrong.
fn markup(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.arity(argv, 1, 3);
    const input = try wattle.getBytes(argv, 0);
    const strict = if (argv.len == 3) try wattle.getBoolean(argv, 2) else true;

    var flags: u32 = 0;
    if (argv.len >= 2) {
        // The elements are read with the checked unwrap, which is what tells
        // the members of an `Indexed` apart.
        var options = try wattle.getIndexed(argv, 1);
        var i: usize = 0;
        while (try options.next()) |option| : (i += 1) {
            const name = wattle.toKeyword(option) orelse
                return wattle.panicFormat("option {d} is not a keyword", .{i});
            if (render_options.get(name)) |bit| {
                flags |= bit;
            } else if (strict) {
                return wattle.panicFormat("invalid option :{s}", .{name});
            }
        }
    }

    var out: [256]u8 = undefined;
    const text = std.fmt.bufPrintZ(&out, "<{d}>{s}</{d}>", .{ flags, input, flags }) catch
        return wattle.panic("rendered output does not fit");
    return wattle.cstring(text);
}

/// `(mutate array table buffer)`: the three mutations, on values handed in.
///
/// No aggregate crossed to get here. The array, the table and the buffer are
/// `Value`s; the runtime tests the tag on its own side and refuses with its
/// own message, which is what keeps `*Array` and `*Table` off the author
/// surface. What comes back is the array's new length, through the generic
/// `length`.
fn mutate(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 3);
    try wattle.arrayPush(argv[0], wattle.number(99));
    try wattle.put(argv[1], wattle.keyword("added"), wattle.boolean(true));
    try wattle.bufferPush(argv[2], "!");
    return wattle.number(@floatFromInt(try wattle.length(argv[0])));
}

/// `(named x)`: the name of a string, a symbol or a keyword, as a string.
///
/// The three tag-specific unwraps in one place. Each gives back a
/// `[:0]const u8`, which is what `cstring` takes, so the terminator the value
/// already has crosses rather than being looked for again. A buffer is the
/// same bytes without a terminator, so it is nil here and `bytesView` is what
/// reads one.
fn named(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 1);
    const v = argv[0];
    const name = wattle.toString(v) orelse
        wattle.toSymbol(v) orelse
        wattle.toKeyword(v) orelse
        return wattle.nil();
    return wattle.cstring(name);
}

/// The method lookup, which is the only slot this type sets.
fn oddGet(_: *Odd, key: wattle.Value) wattle.Error!?wattle.Value {
    return wattle.getMethod(key, &odd_methods);
}

/// `(:length o)`: 3.
fn oddLength(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 1);
    _ = try wattle.getAbstract(Odd, argv, 0, &odd_type);
    return wattle.number(3);
}

/// `(odd)`.
fn oddValue(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 0);
    return wattle.abstract(wattle.new(Odd, &odd_type, null));
}

/// `(peek indexed n)`: the value the keeper at index `n` kept.
///
/// This is the case `toAbstract` exists for. The keeper is an element of a
/// tuple rather than an argument, so it has no slot for `getAbstract` to read.
/// The unwrap tests the abstract type's identity, so an `odd` in the same
/// position is a refusal this module words rather than a read of another
/// type's payload.
fn peek(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 2);
    var items = try wattle.getIndexed(argv, 0);
    const n = try wattle.getSize(argv, 1);
    const item = try items.get(n) orelse return wattle.panicFormat("index {d} is past the end", .{n});
    const self = wattle.toAbstract(Keeper, item, &keeper_type) orelse
        return wattle.panicFormat("element {d} is not a keeper", .{n});
    return self.kept;
}

/// `(pointer-value)`: a raw pointer as a value, checked round trip.
///
/// The check is here rather than in Janet because a Janet program cannot read
/// a pointer back: `toPointer` is the only way, and it is on this side.
fn pointerValue(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 0);
    const p: *anyopaque = @ptrCast(&pointer_target);
    const v = wattle.pointer(p);
    if (!wattle.isPointer(v)) return wattle.panic("pointer() did not answer a pointer");
    const back = wattle.toPointer(v) orelse return wattle.panic("toPointer did not answer a pointer");
    if (back != p) return wattle.panic("toPointer did not answer what pointer took");
    return v;
}

/// `(rank keeper)`.
fn rank(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 1);
    const k = try wattle.getAbstract(Keeper, argv, 0, &keeper_type);
    return wattle.number(@floatFromInt(k.rank));
}

/// `(refused-freed)`.
fn refusedFreed(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 0);
    return wattle.number(@floatFromInt(refused_freed));
}

/// `(release-abandoned)`: lets the waiting thread post.
fn releaseAbandoned(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 0);
    abandon_gate.store(true, .release);
    return wattle.nil();
}

/// `(size x)`: the generic `length`, so that its refusals are reachable.
fn size(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 1);
    return wattle.number(@floatFromInt(try wattle.length(argv[0])));
}

/// `(sorted cmp indexed)`: an insertion sort whose comparator is Janet's.
///
/// The working array is rooted for the whole sort, which is what the fixture
/// is for rather than an aside. Every `call` re-enters the interpreter
/// and every re-entry can collect; the array this builds is reachable from
/// nothing but this frame, which the collector does not scan, so without the
/// root it and every element reachable only from it could be freed under the
/// comparator. The elements need no root of their own, since the rooted array
/// refers to them and `gc/mark.zig` traverses what it marks.
///
/// The sort itself reads and writes through `get` and `put` rather than
/// through the `Indexed` `getIndexed` returned, because an `Indexed` does not
/// survive a re-entry.
fn sorted(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 2);
    var items = try wattle.getIndexed(argv, 1);
    const count = items.len;
    // Copied out of `argv` before the first call, which is not optional. A
    // cfunction's arguments live on the fiber's stack and a call into Janet may
    // move it; `call`'s doc states the rule, and
    // `-Dfiber-stack-shuffle=true` is the build that turns breaking it into a
    // use-after-free the allocator sees rather than a wrong result. The
    // comparator is safe as a local because the Janet frame that passed it is
    // still live.
    const cmp = argv[0];
    // Built before the first call, while the `Indexed` is still valid.
    const out = wattle.array(&.{});
    while (try items.nextChunk()) |chunk| {
        for (chunk) |item| try wattle.arrayPush(out, item);
    }
    wattle.gcroot(out);
    defer _ = wattle.gcunroot(out);
    var i: usize = 1;
    while (i < count) : (i += 1) {
        var j = i;
        while (j > 0) : (j -= 1) {
            const left = try wattle.get(out, wattle.number(@floatFromInt(j - 1)));
            const right = try wattle.get(out, wattle.number(@floatFromInt(j)));
            const verdict = try wattle.call(cmp, &.{ right, left });
            if (!wattle.truthy(verdict)) break;
            try wattle.put(out, wattle.number(@floatFromInt(j - 1)), right);
            try wattle.put(out, wattle.number(@floatFromInt(j)), left);
        }
    }
    return out;
}

/// `(stampede n)`: n threads posting at once, giving back how many arrived.
fn stampede(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 1);
    const count = try wattle.getUInteger(argv, 0);
    if (count == 0 or count > 32) return wattle.panic("stampede wants 1 to 32 threads");
    const l = try wattle.loop();
    const fiber = try wattle.rootFiber();
    const cells = wattle.alloc(Stampede, 1) orelse return wattle.panic("out of memory");
    const run = &cells[0];
    run.* = .{ .loop = l, .fiber = fiber, .expected = count, .arrived = 0 };
    wattle.gcroot(run.fiber);
    var started: u32 = 0;
    while (started < count) : (started += 1) {
        const thread = std.Thread.spawn(.{}, stampedeThread, .{run}) catch break;
        thread.detach();
    }
    // A thread that would not start is a refusal rather than a shorter wait:
    // the fiber is woken by the *last* arrival, so an expectation no thread
    // will meet is a fiber that never wakes.
    if (started != count) {
        run.expected = started;
        if (started == 0) {
            _ = wattle.gcunroot(run.fiber);
            wattle.free(run);
            return wattle.panic("could not start a thread");
        }
    }
    return wattle.await();
}

/// The last arrival wakes the fiber and frees the shared context.
fn stampedeDone(w: *wattle.Wake, raw: *anyopaque) callconv(.c) void {
    const run: *Stampede = @ptrCast(@alignCast(raw));
    run.arrived += 1;
    if (run.arrived < run.expected) return;
    _ = wattle.wake(w, run.fiber, wattle.number(@floatFromInt(run.arrived)));
    _ = wattle.gcunroot(run.fiber);
    wattle.free(run);
}

/// The last post a thread makes is its last touch of the context, which is
/// what lets the final callback free it. `post` reads `run.loop` before the
/// call and the runtime never reads the context at all, so a thread that has
/// returned from `post` has nothing left to lose.
fn stampedeThread(run: *Stampede) void {
    wattle.post(run.loop, &stampedeDone, run);
}

/// `(status-of x)`: `fiberStatus` over anything, so that its refusal is
/// reachable from Janet and so that every status a fixture can put a fiber in
/// can be asked for, `:new` and `:alive` included.
fn statusOf(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 1);
    return wattle.keyword(@tagName(try wattle.fiberStatus(argv[0])));
}

/// `(tally dict)`: the sum of a dictionary's numeric values.
///
/// The walk skips a table's empty slots, which is what `count` is for beside
/// `len`: the runs hold `len` values and `count` pairs are occupied.
///
/// The walk is `Dictionary.next` and the count is checked against it. What a
/// module can still get wrong is trusting `count` without walking, and this
/// compares the two.
fn tally(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 1);
    var entries = try wattle.getDictionary(argv, 0);
    var sum: f64 = 0;
    var seen: usize = 0;
    while (try entries.next()) |kv| {
        seen += 1;
        if (wattle.toNumber(kv.value)) |x| sum += x;
    }
    if (seen != entries.count) return wattle.panicFormat("walked {d} entries where count says {d}", .{ seen, entries.count });
    return wattle.number(sum);
}

/// `(unkept-across f)`: the same sequence with no root, which is the case the
/// root exists for.
///
/// Nothing asserts that this fails, and nothing can: a collection freeing a
/// value this frame still refers to is undefined behaviour, not an outcome. It
/// is here so that the two read side by side and the one line of difference is
/// visible. `test/zig-native.janet` calls it and looks at nothing it gives
/// back.
fn unkeptAcross(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 1);
    const pairs = [_]wattle.Keyval{
        .{ .key = wattle.keyword("kept"), .value = wattle.string("across a collection") },
    };
    const held = wattle.tableOf(&pairs);
    _ = try wattle.call(argv[0], &.{});
    return held;
}

/// `(unsafe-seen)`.
fn unsafeSeen(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 0);
    return wattle.number(@floatFromInt(unsafe_seen));
}

/// `(viewed x)`: which of `bytesView`, `toIndexed` and `toDictionary` reads
/// a value, and how long the result is.
///
/// These are the `Value` form of the three getters. A getter takes an argument
/// slot and raises naming it; these take the `Value` and return null, because
/// a value pulled out of a tuple or a dictionary is in no slot the caller can
/// be told about.
fn viewed(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 1);
    const v = argv[0];
    var out: [64]u8 = undefined;
    const text = blk: {
        if (wattle.bytesView(v)) |bytes| {
            break :blk std.fmt.bufPrintZ(&out, "bytes {d}", .{bytes.len});
        }
        if (try wattle.toIndexed(v)) |items| {
            break :blk std.fmt.bufPrintZ(&out, "indexed {d}", .{items.len});
        }
        if (try wattle.toDictionary(v)) |dict| {
            break :blk std.fmt.bufPrintZ(&out, "dictionary {d}", .{dict.count});
        }
        break :blk std.fmt.bufPrintZ(&out, "none", .{});
    } catch return wattle.panic("the description does not fit");
    return wattle.cstring(text);
}

/// `(wake-refused)`.
fn wakeRefused(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 0);
    return wattle.number(@floatFromInt(wake_refused));
}

/// `(walked indexed)`: the elements of an indexed argument, read four ways.
///
/// The result is a tuple of five values: an array read with `next`, an array
/// read with `get` from the last index to the first, how many runs `nextChunk`
/// gave, how long the run `nextChunk` gave after one `next` was, and whether
/// `get` of the length was null. The `get`s come before the `next`s, and do not
/// move where `next` starts. A keeper's runs are four long, so a keeper crosses
/// a run boundary each way.
fn walked(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 1);
    var items = try wattle.getIndexed(argv, 0);
    const forward = wattle.array(&.{});
    const backward = wattle.array(&.{});
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const item = try items.get(i) orelse return wattle.panic("get refused an index below the length");
        try wattle.arrayPush(backward, item);
    }
    while (try items.next()) |item| try wattle.arrayPush(forward, item);
    const past_end = try items.get(items.len) == null;

    var whole = try wattle.getIndexed(argv, 0);
    var runs: usize = 0;
    while (try whole.nextChunk()) |_| runs += 1;

    // A second `Indexed` over the same value, read only after the first is
    // finished with.
    var rest = try wattle.getIndexed(argv, 0);
    var rest_len: usize = 0;
    if (try rest.next() != null) {
        if (try rest.nextChunk()) |chunk| rest_len = chunk.len;
    }

    const row = [_]wattle.Value{
        forward,
        backward,
        wattle.number(@floatFromInt(runs)),
        wattle.number(@floatFromInt(rest_len)),
        wattle.boolean(past_end),
    };
    return wattle.tuple(&row);
}

/// The callback the worker posts: wakes the fiber, then frees the root and the
/// context.
fn workDone(w: *wattle.Wake, raw: *anyopaque) callconv(.c) void {
    const work: *Work = @ptrCast(@alignCast(raw));
    // Building a `Value` inside a posted callback is allowed. Allocating
    // through the collector is fatal on failure rather than a raise, and no
    // safe point runs between fibers on the loop thread.
    if (!wattle.wake(w, work.fiber, wattle.number(work.answer))) wake_refused += 1;
    _ = wattle.gcunroot(work.fiber);
    wattle.free(work);
}

/// Computes the result, then posts.
fn workThread(work: *Work) void {
    work.answer = work.answer * 2 + 1;
    wattle.post(work.loop, &workDone, work);
}

/// `(wrap bytes width)`: markable's unsigned-integer argument, which is a wrap
/// column rather than a size.
fn wrap(argv: []wattle.Value) wattle.Error!wattle.Value {
    try wattle.fixarity(argv, 2);
    const bytes = try wattle.getBytes(argv, 0);
    const width = try wattle.getUInteger(argv, 1);
    var out: [256]u8 = undefined;
    const n = @min(bytes.len, @min(@as(usize, width), out.len - 1));
    @memcpy(out[0..n], bytes[0..n]);
    out[n] = 0;
    return wattle.cstring(out[0..n :0]);
}

// ==========================================================================
// Tests
// ==========================================================================

comptime {
    wattle.entry(defs);
}
