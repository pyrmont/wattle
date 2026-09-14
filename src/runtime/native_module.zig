//! A dynamically loaded Janet module written in Zig: the proof that a `.so`
//! outside the runtime can define a builtin, and that all fourteen
//! abstract-type slots are writable from one.
//!
//! It is written against the published interface: `janet` and `std` are its
//! whole import list, which is what makes it a proof of the thing a module
//! author actually uses. Reaching past that interface for the runtime's own
//! declarations would prove something else, and the comptime `StaticStringMap`
//! below is the point of saying so.
//!
//! A sentence claiming all fourteen slots are writable is not a proof, so
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

const janet = @import("janet");

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

/// All fourteen slots. Adding a slot to `abstract_type.Spec` and not to an
/// author's reach breaks this declaration.
const keeper_type = janet.define(Keeper, .{
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
const methods = [_]janet.Method{
    .{ .name = "kept", .cfun = &kept },
    .{ .name = "rank", .cfun = &rank },
};

/// The serial number `keep` stamps each payload with, so that the marshal pair
/// has a 64-bit field to write and `tostring` something to show in.
var next_serial: i64 = 1;

/// A method table whose `:length` lies, in one of two ways. `mcall` finds it
/// through `get`.
const odd_methods = [_]janet.Method{.{ .name = "length", .cfun = &oddLength }};

/// No `length` slot, on purpose: that is what sends `length` to the method.
const odd_type = janet.define(Odd, .{ .name = "zig-native/odd", .get = oddGet });

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
/// `length` report.
const Keeper = struct {
    kept: janet.Value,
    rank: i32,
    serial: i64,
    text: [6]u8,
};

/// `mode` selects what the `:length` method returns, so that both kinds of
/// wrong result are reachable from a test.
///
/// This is the one path on the surface where a runtime call re-enters Janet
/// code, and the only fixture in the tree that reaches it. An abstract type
/// with no `length` slot resolves `:length` as a Janet method, which is an
/// ordinary call back into the interpreter, so the collector's safe points are
/// live under this module's frame while it runs. That is also where
/// `access.length` could come back negative, since a method may return one,
/// and this type is what fires the refusal that now stops it.
const Odd = struct { mode: u8 = 0 };

/// What several threads posting at once share.
///
/// `arrived` needs no lock, which is what the fixture is showing. Posted
/// callbacks run one at a time on the loop thread, so the increment below is
/// as safe as a
/// single-threaded one however many threads posted; nothing here depends on
/// the order they arrive in, which is the one thing the loop does not promise.
const Stampede = struct {
    loop: *janet.Loop,
    fiber: janet.Value,
    expected: u32,
    arrived: u32,
};

/// What one waiting fiber's thread is given, and what its callback frees.
///
/// `loop` and `fiber` are read on the loop thread before the fiber suspends;
/// `answer` is written by the worker and read by the callback, which are two
/// different threads with the post between them.
const Work = struct {
    loop: *janet.Loop,
    fiber: janet.Value,
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
fn abandonDone(w: *janet.Wake, raw: *anyopaque) callconv(.c) void {
    const work: *Work = @ptrCast(@alignCast(raw));
    if (!janet.wake(w, work.fiber, janet.number(work.answer))) {
        wake_refused += 1;
        refused_freed += 1;
    }
    _ = janet.gcunroot(work.fiber);
    janet.free(work);
}

/// Waits at the gate, then posts.
fn abandonThread(work: *Work) void {
    while (!abandon_gate.load(.acquire)) std.Thread.yield() catch {};
    work.answer = 0;
    janet.post(work.loop, &abandonDone, work);
}

/// `(abandoned)`: a fiber whose thread posts only once released, so that the
/// test can cancel it in between and reach `wake`'s `false`.
fn abandoned(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 0);
    const l = try janet.loop();
    const fiber = try janet.rootFiber();
    const cells = janet.alloc(Work, 1) orelse return janet.panic("out of memory");
    const work = &cells[0];
    work.* = .{ .loop = l, .fiber = fiber, .answer = 0 };
    janet.gcroot(work.fiber);
    const thread = std.Thread.spawn(.{}, abandonThread, .{work}) catch {
        _ = janet.gcunroot(work.fiber);
        janet.free(work);
        return janet.panic("could not start a thread");
    };
    thread.detach();
    return janet.await();
}

/// `(apply f & args)`: `call`, which raises on anything but a return.
fn apply(argv: []janet.Value) janet.Error!janet.Value {
    try janet.arity(argv, 1, -1);
    return janet.call(argv[0], argv[1..]);
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
fn attempt(argv: []janet.Value) janet.Error!janet.Value {
    try janet.arity(argv, 1, -1);
    const called = janet.pcall(argv[0], argv[1..]);
    const row = [_]janet.Value{
        janet.keyword(@tagName(called.signal)),
        called.value,
        called.fiber,
    };
    return janet.tuple(&row);
}

/// `(built bytes)`: one of every composite, built from the argument, in a
/// tuple. Janet's own equality is what checks them.
///
/// Every constructor takes exactly what the getter of the same type returns.
/// `built` passes the slice `getBytes` returns straight to `string`, `symbol`,
/// `keyword` and `buffer`, and passes a `[]const Value`, the type `getIndexed`
/// returns, to `tuple` and `array`.
fn built(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    // The slice goes straight into the three interning constructors: no
    // copy, no length recomputed, and a buffer argument works as a string one
    // does.
    const seed = try janet.getBytes(argv, 0);
    const items = [_]janet.Value{ janet.number(1), janet.number(2) };
    // Pairs, not a hash array. `structOf` and `tableOf` take what the caller
    // wrote; a dictionary's own storage is `cap` slots with empties among
    // them, and `Pairs` is what reads that.
    const pairs = [_]janet.Pair{
        .{ .key = janet.keyword("a"), .value = janet.number(1) },
        .{ .key = janet.keyword("b"), .value = janet.number(2) },
    };
    const composites = [_]janet.Value{
        janet.boolean(true),
        janet.boolean(false),
        janet.string(seed),
        janet.symbol(seed),
        janet.keyword(seed),
        janet.tuple(&items),
        janet.array(&items),
        janet.buffer(seed),
        janet.structOf(&pairs),
        janet.tableOf(&pairs),
    };
    return janet.tuple(&composites);
}

/// `(classify x)`: the tag of a value, named.
///
/// One cfunction over all thirteen predicates, because what they are for is
/// telling apart the types one getter accepts, and a module that has them all
/// has no reason to reach for anything else. `isFunction` is the odd one out:
/// what it is for is refusing a callback `pcall` could not run, at the point
/// the callback is handed over rather than at the call.
fn classify(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    const v = argv[0];
    const name: [:0]const u8 = if (janet.isNil(v))
        "nil"
    else if (janet.isBoolean(v))
        "boolean"
    else if (janet.isNumber(v))
        "number"
    else if (janet.isPointer(v))
        "pointer"
    else if (janet.isString(v))
        "string"
    else if (janet.isSymbol(v))
        "symbol"
    else if (janet.isKeyword(v))
        "keyword"
    else if (janet.isBuffer(v))
        "buffer"
    else if (janet.isTuple(v))
        "tuple"
    else if (janet.isArray(v))
        "array"
    else if (janet.isStruct(v))
        "struct"
    else if (janet.isTable(v))
        "table"
    else if (janet.isFunction(v))
        "function"
    else
        "other";
    return janet.cstring(name);
}

/// `(cut bytes &opt start end)`: a slice of a byte argument.
///
/// The length handed to `getRange` is the slice's own, so the negative index,
/// the absent slot and the clamp are the ones every core builtin taking a
/// slice already has.
fn cut(argv: []janet.Value) janet.Error!janet.Value {
    try janet.arity(argv, 1, 3);
    const bytes = try janet.getBytes(argv, 0);
    const range: janet.Range = try janet.getRange(argv, 1, bytes.len);
    const from: usize = @intCast(range.start);
    const to: usize = @intCast(range.end);
    var out: [256]u8 = undefined;
    if (to - from >= out.len) return janet.panic("slice does not fit");
    @memcpy(out[0 .. to - from], bytes[from..to]);
    out[to - from] = 0;
    return janet.cstring(out[0 .. to - from :0]);
}

/// The module's entry point: registers the abstract type and the cfunctions.
///
/// A type with an `unmarshal` callback has to be registered, or the
/// unmarshaller never finds it: an abstract names its type on the wire and
/// resolves it through the runtime's registry. That registration is what this
/// may raise for.
fn defs(env: *janet.Env) janet.Error!void {
    // A type with an `unmarshal` callback has to be registered, or the
    // unmarshaller never finds it: an abstract names its type on the wire and
    // resolves it through the runtime's registry. This is what `defs` may
    // raise for.
    try janet.registerAbstract(&keeper_type);
    janet.cfuns(env, "zig-native", &.{
        janet.reg(
            "identity",
            &identity,
            "(identity x)\n\nRound-trip a Janet value through a dynamically loaded Zig module.",
        ),
        janet.reg("keep", &keep, "(keep x &opt rank)\n\nAn abstract holding x, with every callback set."),
        janet.reg("kept", &kept, "(kept keeper)\n\nThe value a keeper holds."),
        janet.reg("rank", &rank, "(rank keeper)\n\nThe rank compare and hash are computed from."),
        janet.reg("mark-count", &markCount, "(mark-count)\n\nHow many times gcmark has been reached."),
        janet.reg("finalized-count", &finalizedCount, "(finalized-count)\n\nHow many keepers have been finalized."),
        janet.reg("unsafe-seen", &unsafeSeen, "(unsafe-seen)\n\nHow many marshal callbacks saw the unsafe flag."),
        janet.reg("greeting", &greeting, "(greeting)\n\nA string built by the module."),
        janet.reg("markup", &markup, "(markup bytes &opt opts strict)\n\nA byte argument and a tuple of keyword options."),
        janet.reg("tally", &tally, "(tally dict)\n\nThe sum of a struct's or a table's numeric values."),
        janet.reg("cut", &cut, "(cut bytes &opt start end)\n\nA slice of a byte argument."),
        janet.reg("wrap", &wrap, "(wrap bytes width)\n\nThe first width bytes."),
        janet.reg("classify", &classify, "(classify x)\n\nThe name of a value's type."),
        janet.reg("named", &named, "(named x)\n\nThe name of a string, a symbol or a keyword."),
        janet.reg("peek", &peek, "(peek indexed n)\n\nThe value the keeper at index n holds."),
        janet.reg("viewed", &viewed, "(viewed x)\n\nWhich *View function reads a value, and its length."),
        janet.reg("built", &built, "(built bytes)\n\nOne of every composite, built from the argument."),
        janet.reg("pointer-value", &pointerValue, "(pointer-value)\n\nA raw pointer as a value."),
        janet.reg("mutate", &mutate, "(mutate array table buffer)\n\nThe three mutations, through the Value."),
        janet.reg("fetch", &fetch, "(fetch ds key)\n\nJanet's own get, over anything."),
        janet.reg("size", &size, "(size x)\n\nThe generic length."),
        janet.reg("odd", &oddValue, "(odd)\n\nAn abstract whose :length method returns -1."),
        janet.reg("apply", &apply, "(apply f & args)\n\nCall f on the current fiber, raising on anything but a return."),
        janet.reg("invoke", &invoke, "(invoke name & args)\n\nCall the method name on the first of args."),
        janet.reg("attempt", &attempt, "(attempt f & args)\n\nCall f on a fresh fiber, returning [signal value fiber]."),
        janet.reg("status-of", &statusOf, "(status-of x)\n\nThe status of a fiber, refusing anything else."),
        janet.reg("sorted", &sorted, "(sorted cmp indexed)\n\nAn insertion sort whose comparator is a Janet function."),
        janet.reg("kept-across", &keptAcross, "(kept-across f)\n\nA rooted value carried across a call into f."),
        janet.reg("unkept-across", &unkeptAcross, "(unkept-across f)\n\nThe same with no root: the case the root exists for."),
        janet.reg("later", &later, "(later x)\n\nA value computed on this module's own thread, awaited and woken."),
        janet.reg("stampede", &stampede, "(stampede n)\n\nn threads posting at once; returns how many arrived."),
        janet.reg("abandoned", &abandoned, "(abandoned)\n\nA wait whose thread posts only once released."),
        janet.reg("release-abandoned", &releaseAbandoned, "(release-abandoned)\n\nLet the abandoned wait's thread post."),
        janet.reg("wake-refused", &wakeRefused, "(wake-refused)\n\nHow many times wake has returned false."),
        janet.reg("refused-freed", &refusedFreed, "(refused-freed)\n\nHow many contexts the false branch has freed."),
        janet.reg("loop-available", &loopAvailable, "(loop-available)\n\nWhether the loop capability is available."),
    });
}

/// `(fetch ds key)`: Janet's own `get`, over anything.
fn fetch(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 2);
    return janet.get(argv[0], argv[1]);
}

/// `(finalized-count)`.
fn finalizedCount(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 0);
    return janet.number(@floatFromInt(finalized));
}

/// `(greeting)`: a cfunction returning a string, which `janet.cstring` is the
/// whole of.
fn greeting(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 0);
    return janet.cstring("hello from a module");
}

/// `(identity x)`: a value round-tripped through a loaded module.
fn identity(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    return argv[0];
}

/// `(invoke name & args)`: `mcall`, with the method named by a keyword.
fn invoke(argv: []janet.Value) janet.Error!janet.Value {
    try janet.arity(argv, 1, -1);
    const name = janet.toKeyword(argv[0]) orelse return janet.panic("expected keyword");
    return janet.mcall(name, argv[1..]);
}

/// `(keep x &opt rank)`: a new keeper.
fn keep(argv: []janet.Value) janet.Error!janet.Value {
    try janet.arity(argv, 1, 2);
    const given = if (argv.len == 2) try janet.getInteger(argv, 1) else 0;
    const k = janet.new(Keeper, &keeper_type, null);
    k.* = .{ .kept = argv[0], .rank = given, .serial = next_serial, .text = "keeper".* };
    next_serial += 1;
    return janet.abstract(k);
}

/// The runtime reads the bytes where they are returned, so the slice may point
/// at the payload's own storage.
fn keeperBytes(self: *const Keeper, _: usize) []const u8 {
    return &self.text;
}

/// Calling the abstract gives back what it kept.
fn keeperCall(self: *Keeper, argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 0);
    return self.kept;
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
fn keeperGet(self: *Keeper, key: janet.Value) janet.Error!?janet.Value {
    if (janet.isKeyword(key)) return janet.getMethod(key, &methods);
    const i = janet.toInteger(key) orelse return janet.panic("expected integer key");
    if (i < 0 or i >= self.text.len) return null;
    return janet.number(@floatFromInt(self.text[@intCast(i)]));
}

/// The rank, spread over the word.
fn keeperHash(self: *const Keeper, _: usize) i32 {
    return self.rank *% 31;
}

/// The length of the text, which is what `length` reports for this type.
fn keeperLength(self: *Keeper, _: usize) janet.Error!usize {
    return self.text.len;
}

/// The one thing this slot can do with a payload of a `Value`, and it needs a
/// crossing to do it: `gc/mark.zig` reads the thread-local VM, which a `.so`
/// cannot import.
fn keeperMark(self: *Keeper, _: usize) void {
    marks += 1;
    janet.mark(self.kept);
}

/// Every `push*` an author has except `pushPointer`, which is meaningful only
/// in unsafe mode, and `pushNumber`, which `examples/numarray` uses.
fn keeperMarshal(self: *Keeper, m: *janet.Marshal) janet.Error!void {
    if (janet.isUnsafe(m)) unsafe_seen += 1;
    janet.pushAbstract(m, self);
    try janet.pushInteger(m, self.rank);
    try janet.pushInt64(m, self.serial);
    try janet.pushByte(m, @intCast(self.text.len));
    try janet.pushBytes(m, &self.text);
    try janet.pushValue(m, self.kept);
}

/// The iteration order behind `next` and `(keys k)`.
fn keeperNext(self: *Keeper, key: janet.Value) janet.Error!janet.Value {
    _ = self;
    return janet.nextMethod(&methods, key);
}

/// Runs only for a threaded abstract, and this module makes none. It is here
/// because the fourteenth slot has to be spellable to be counted.
fn keeperPerThread(_: *Keeper, _: usize) void {}

/// A keyword key sets the rank, and anything else is refused.
fn keeperPut(self: *Keeper, key: janet.Value, value: janet.Value) janet.Error!void {
    if (!janet.isKeyword(key)) return janet.panic("expected a keyword key");
    self.rank = janet.toInteger(value) orelse return janet.panic("expected an integer value");
}

/// The text, then the rank and the serial number.
fn keeperTostring(self: *Keeper, render: *janet.Render) janet.Error!void {
    try janet.push(render, &self.text);
    try janet.format(render, "#{d}@{d}", .{ self.rank, self.serial });
}

/// And every `pull*` except the two that mirror the omissions in
/// `keeperMarshal`.
fn keeperUnmarshal(u: *janet.Unmarshal) janet.Error!*Keeper {
    if (janet.isUnsafe(u)) unsafe_seen += 1;
    const keeper = try janet.pullAbstract(u, Keeper, null);
    // Every field written before anything else can raise: the block is on the
    // collector's heap list from the line above, so a raise in the middle
    // would hand `gc` and `gcmark` a payload that was never written.
    keeper.* = .{ .kept = janet.nil(), .rank = 0, .serial = 0, .text = @splat(0) };
    keeper.rank = try janet.pullInteger(u);
    keeper.serial = try janet.pullInt64(u);
    const len = try janet.pullByte(u);
    if (len != keeper.text.len) return janet.panic("wrong keeper text length");
    // The stream is asked for the bytes before they are read, which is what
    // `pullEnsure` is for: `pullBytes` would refuse at the same point, and a
    // callback with more to allocate than this one has is better off knowing
    // first.
    try janet.pullEnsure(u, len);
    try janet.pullBytes(u, &keeper.text);
    keeper.kept = try janet.pullValue(u);
    return keeper;
}

/// `(kept keeper)`.
fn kept(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    const k = try janet.getAbstract(Keeper, argv, 0, &keeper_type);
    return k.kept;
}

/// `(kept-across f)`: a composite built here, rooted, kept across a call into
/// `f`, and given back intact.
///
/// `f` is expected to run `(gccollect)`, which is one of the two callers of
/// `gc/mark.zig`'s `collect` and therefore one of the two places a collection
/// happens at all. Without the root, what is built below is reachable from
/// nothing the collector scans while `f` runs.
fn keptAcross(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    const pairs = [_]janet.Pair{
        .{ .key = janet.keyword("kept"), .value = janet.string("across a collection") },
    };
    const held = janet.tableOf(&pairs);
    janet.gcroot(held);
    defer _ = janet.gcunroot(held);
    _ = try janet.call(argv[0], &.{});
    return held;
}

/// `(later x)`: a value computed on this module's own thread.
///
/// The order is what a caller has to keep: read the loop and the fiber, root
/// the fiber, start the thread, and only then suspend. Starting the thread
/// before the suspend is not a race, because the loop is single-threaded, so
/// an event posted before this cfunction has returned is not processed until
/// the fiber has suspended.
fn later(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    const l = try janet.loop();
    const fiber = try janet.rootFiber();
    const cells = janet.alloc(Work, 1) orelse return janet.panic("out of memory");
    const work = &cells[0];
    work.* = .{ .loop = l, .fiber = fiber, .answer = try janet.getNumber(argv, 0) };
    janet.gcroot(work.fiber);
    const thread = std.Thread.spawn(.{}, workThread, .{work}) catch {
        _ = janet.gcunroot(work.fiber);
        janet.free(work);
        return janet.panic("could not start a thread");
    };
    thread.detach();
    return janet.await();
}

/// `(loop-available)`: whether the loop capability can be obtained.
///
/// This is what a build without the event loop is tested through. The four
/// loop fields are filled in every build and `loop` is the one that refuses,
/// so a module asking for the capability is exactly where the refusal shows
/// up. Every other shape here calls `loop` first for the same reason.
fn loopAvailable(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 0);
    _ = janet.loop() catch return janet.boolean(false);
    return janet.boolean(true);
}

/// `(mark-count)`.
fn markCount(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 0);
    return janet.number(@floatFromInt(marks));
}

/// `(markup bytes &opt opts strict)`: markable's shape.
///
/// Four steps, and every one of them was unreachable from a module before the
/// getters this file exercises existed: reading the byte argument, reading the
/// indexed argument, reading a keyword out of that slice, and refusing with a
/// message naming what was wrong.
fn markup(argv: []janet.Value) janet.Error!janet.Value {
    try janet.arity(argv, 1, 3);
    const input = try janet.getBytes(argv, 0);
    const strict = if (argv.len == 3) try janet.getBoolean(argv, 2) else true;

    var flags: u32 = 0;
    if (argv.len >= 2) {
        // The slice's elements are read with the checked unwrap, which is
        // what tells the members of a `[]const Value` apart.
        for (try janet.getIndexed(argv, 1), 0..) |option, i| {
            const name = janet.toKeyword(option) orelse
                return janet.panicFormat("option {d} is not a keyword", .{i});
            if (render_options.get(name)) |bit| {
                flags |= bit;
            } else if (strict) {
                return janet.panicFormat("invalid option :{s}", .{name});
            }
        }
    }

    var out: [256]u8 = undefined;
    const text = std.fmt.bufPrintZ(&out, "<{d}>{s}</{d}>", .{ flags, input, flags }) catch
        return janet.panic("rendered output does not fit");
    return janet.cstring(text);
}

/// `(mutate array table buffer)`: the three mutations, on values handed in.
///
/// No aggregate crossed to get here. The array, the table and the buffer are
/// `Value`s; the runtime tests the tag on its own side and refuses with its
/// own message, which is what keeps `*Array` and `*Table` off the author
/// surface. What comes back is the array's new length, through the generic
/// `length`.
fn mutate(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 3);
    try janet.arrayPush(argv[0], janet.number(99));
    try janet.put(argv[1], janet.keyword("added"), janet.boolean(true));
    try janet.bufferPush(argv[2], "!");
    return janet.number(@floatFromInt(try janet.length(argv[0])));
}

/// `(named x)`: the name of a string, a symbol or a keyword, as a string.
///
/// The three tag-specific unwraps in one place. Each gives back a
/// `[:0]const u8`, which is what `cstring` takes, so the terminator the value
/// already has crosses rather than being looked for again. A buffer is the
/// same bytes without a terminator, so it is nil here and `bytesView` is what
/// reads one.
fn named(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    const v = argv[0];
    const name = janet.toString(v) orelse
        janet.toSymbol(v) orelse
        janet.toKeyword(v) orelse
        return janet.nil();
    return janet.cstring(name);
}

/// The method lookup, which is the only slot this type sets.
fn oddGet(_: *Odd, key: janet.Value) janet.Error!?janet.Value {
    return janet.getMethod(key, &odd_methods);
}

/// `(:length o)`: a length that is negative in mode 0 and not a number
/// otherwise.
fn oddLength(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    const self = try janet.getAbstract(Odd, argv, 0, &odd_type);
    return switch (self.mode) {
        0 => janet.number(-1),
        else => janet.cstring("not a number at all"),
    };
}

/// `(odd &opt mode)`.
fn oddValue(argv: []janet.Value) janet.Error!janet.Value {
    try janet.arity(argv, 0, 1);
    const o = janet.new(Odd, &odd_type, null);
    o.mode = if (argv.len == 1) @truncate(try janet.getUInteger(argv, 0)) else 0;
    return janet.abstract(o);
}

/// `(peek indexed n)`: the value the keeper at index `n` kept.
///
/// This is the case `toAbstract` exists for. The keeper is an element of a
/// tuple rather than an argument, so it has no slot for `getAbstract` to read.
/// The unwrap tests the abstract type's identity, so an `odd` in the same
/// position is a refusal this module words rather than a read of another
/// type's payload.
fn peek(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 2);
    const items = try janet.getIndexed(argv, 0);
    const n = try janet.getSize(argv, 1);
    if (n >= items.len) return janet.panicFormat("index {d} is past the end", .{n});
    const self = janet.toAbstract(Keeper, items[n], &keeper_type) orelse
        return janet.panicFormat("element {d} is not a keeper", .{n});
    return self.kept;
}

/// `(pointer-value)`: a raw pointer as a value, checked round trip.
///
/// The check is here rather than in Janet because a Janet program cannot read
/// a pointer back: `toPointer` is the only way, and it is on this side.
fn pointerValue(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 0);
    const p: *anyopaque = @ptrCast(&pointer_target);
    const v = janet.pointer(p);
    if (!janet.isPointer(v)) return janet.panic("pointer() did not answer a pointer");
    const back = janet.toPointer(v) orelse return janet.panic("toPointer did not answer a pointer");
    if (back != p) return janet.panic("toPointer did not answer what pointer took");
    return v;
}

/// `(rank keeper)`.
fn rank(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    const k = try janet.getAbstract(Keeper, argv, 0, &keeper_type);
    return janet.number(@floatFromInt(k.rank));
}

/// `(refused-freed)`.
fn refusedFreed(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 0);
    return janet.number(@floatFromInt(refused_freed));
}

/// `(release-abandoned)`: lets the waiting thread post.
fn releaseAbandoned(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 0);
    abandon_gate.store(true, .release);
    return janet.nil();
}

/// `(size x)`: the generic `length`, so that its refusals are reachable.
fn size(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    return janet.number(@floatFromInt(try janet.length(argv[0])));
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
/// through the slice `getIndexed` returned, because that slice is
/// `data[0..count]` and a re-entry may move it.
fn sorted(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 2);
    const items = try janet.getIndexed(argv, 1);
    const count = items.len;
    // Copied out of `argv` before the first call, which is not optional. A
    // cfunction's arguments live on the fiber's stack and a call into Janet may
    // move it; `call`'s doc states the rule, and
    // `-Dfiber-stack-shuffle=true` is the build that turns breaking it into a
    // use-after-free the allocator sees rather than a wrong result. The
    // comparator is safe as a local because the Janet frame that passed it is
    // still live.
    const cmp = argv[0];
    const out = janet.array(items);
    janet.gcroot(out);
    defer _ = janet.gcunroot(out);
    var i: usize = 1;
    while (i < count) : (i += 1) {
        var j = i;
        while (j > 0) : (j -= 1) {
            const left = try janet.get(out, janet.number(@floatFromInt(j - 1)));
            const right = try janet.get(out, janet.number(@floatFromInt(j)));
            const verdict = try janet.call(cmp, &.{ right, left });
            if (!janet.truthy(verdict)) break;
            try janet.put(out, janet.number(@floatFromInt(j - 1)), right);
            try janet.put(out, janet.number(@floatFromInt(j)), left);
        }
    }
    return out;
}

/// `(stampede n)`: n threads posting at once, giving back how many arrived.
fn stampede(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    const count = try janet.getUInteger(argv, 0);
    if (count == 0 or count > 32) return janet.panic("stampede wants 1 to 32 threads");
    const l = try janet.loop();
    const fiber = try janet.rootFiber();
    const cells = janet.alloc(Stampede, 1) orelse return janet.panic("out of memory");
    const run = &cells[0];
    run.* = .{ .loop = l, .fiber = fiber, .expected = count, .arrived = 0 };
    janet.gcroot(run.fiber);
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
            _ = janet.gcunroot(run.fiber);
            janet.free(run);
            return janet.panic("could not start a thread");
        }
    }
    return janet.await();
}

/// The last arrival wakes the fiber and frees the shared context.
fn stampedeDone(w: *janet.Wake, raw: *anyopaque) callconv(.c) void {
    const run: *Stampede = @ptrCast(@alignCast(raw));
    run.arrived += 1;
    if (run.arrived < run.expected) return;
    _ = janet.wake(w, run.fiber, janet.number(@floatFromInt(run.arrived)));
    _ = janet.gcunroot(run.fiber);
    janet.free(run);
}

/// The last post a thread makes is its last touch of the context, which is
/// what lets the final callback free it. `post` reads `run.loop` before the
/// call and the runtime never reads the context at all, so a thread that has
/// returned from `post` has nothing left to lose.
fn stampedeThread(run: *Stampede) void {
    janet.post(run.loop, &stampedeDone, run);
}

/// `(status-of x)`: `fiberStatus` over anything, so that its refusal is
/// reachable from Janet and so that every status a fixture can put a fiber in
/// can be asked for, `:new` and `:alive` included.
fn statusOf(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    return janet.keyword(@tagName(try janet.fiberStatus(argv[0])));
}

/// `(tally dict)`: the sum of a struct's or a table's numeric values.
///
/// The walk reads every slot and skips the empty ones, which is what the
/// view's `cap` is for beside its `len`: the array is `cap` long and `len` of
/// its slots are occupied.
///
/// The walk is `Pairs` and the count is checked against it. An author never
/// sees the hash array, so what a module can still get wrong is trusting `len`
/// without walking, and this compares the two.
fn tally(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    var entries = try janet.getDictionary(argv, 0);
    var sum: f64 = 0;
    var seen: usize = 0;
    while (entries.next()) |kv| {
        seen += 1;
        if (janet.toNumber(kv.value)) |x| sum += x;
    }
    if (seen != entries.len) return janet.panicFormat("walked {d} entries where len says {d}", .{ seen, entries.len });
    return janet.number(sum);
}

/// `(unkept-across f)`: the same sequence with no root, which is the case the
/// root exists for.
///
/// Nothing asserts that this fails, and nothing can: a collection freeing a
/// value this frame still refers to is undefined behaviour, not an outcome. It
/// is here so that the two read side by side and the one line of difference is
/// visible. `test/zig-native.janet` calls it and looks at nothing it gives
/// back.
fn unkeptAcross(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    const pairs = [_]janet.Pair{
        .{ .key = janet.keyword("kept"), .value = janet.string("across a collection") },
    };
    const held = janet.tableOf(&pairs);
    _ = try janet.call(argv[0], &.{});
    return held;
}

/// `(unsafe-seen)`.
fn unsafeSeen(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 0);
    return janet.number(@floatFromInt(unsafe_seen));
}

/// `(viewed x)`: which of the three `*View` functions reads a value, and how
/// long the result is.
///
/// These are the `Value` form of the three getters. A getter takes an argument
/// slot and raises naming it; these take the `Value` and raise nothing,
/// because a value pulled out of a tuple or a dictionary is in no slot the
/// caller can be told about.
fn viewed(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    const v = argv[0];
    var out: [64]u8 = undefined;
    const text = blk: {
        if (janet.bytesView(v)) |bytes| {
            break :blk std.fmt.bufPrintZ(&out, "bytes {d}", .{bytes.len});
        }
        if (janet.indexedView(v)) |items| {
            break :blk std.fmt.bufPrintZ(&out, "indexed {d}", .{items.len});
        }
        if (janet.dictionaryView(v)) |dict| {
            break :blk std.fmt.bufPrintZ(&out, "dictionary {d}", .{dict.len});
        }
        break :blk std.fmt.bufPrintZ(&out, "none", .{});
    } catch return janet.panic("the description does not fit");
    return janet.cstring(text);
}

/// `(wake-refused)`.
fn wakeRefused(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 0);
    return janet.number(@floatFromInt(wake_refused));
}

/// The callback the worker posts: wakes the fiber, then frees the root and the
/// context.
fn workDone(w: *janet.Wake, raw: *anyopaque) callconv(.c) void {
    const work: *Work = @ptrCast(@alignCast(raw));
    // Building a `Value` inside a posted callback is allowed. Allocating
    // through the collector is fatal on failure rather than a raise, and no
    // safe point runs between fibers on the loop thread.
    if (!janet.wake(w, work.fiber, janet.number(work.answer))) wake_refused += 1;
    _ = janet.gcunroot(work.fiber);
    janet.free(work);
}

/// Computes the result, then posts.
fn workThread(work: *Work) void {
    work.answer = work.answer * 2 + 1;
    janet.post(work.loop, &workDone, work);
}

/// `(wrap bytes width)`: markable's unsigned-integer argument, which is a wrap
/// column rather than a size.
fn wrap(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 2);
    const bytes = try janet.getBytes(argv, 0);
    const width = try janet.getUInteger(argv, 1);
    var out: [256]u8 = undefined;
    const n = @min(bytes.len, @min(@as(usize, width), out.len - 1));
    @memcpy(out[0..n], bytes[0..n]);
    out[n] = 0;
    return janet.cstring(out[0..n :0]);
}

// ==========================================================================
// Tests
// ==========================================================================

comptime {
    janet.entry(defs);
}
