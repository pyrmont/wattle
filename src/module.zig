//! The interface a native module imports, and the only one it needs.
//!
//! Native modules remain a goal; a C API for writing them does not. Nothing
//! has to keep working that was compiled against upstream Janet's public
//! header, but a module should still be writable in native code, so this is a
//! real interface with third-party authors, not an internal detail.
//!
//! **One import.** A module writes `@import("janet")` and nothing else. The
//! declarations below are a *deliberate* list: what an author is offered,
//! decided here, rather than whatever the runtime still calls through a symbol.
//!
//! **What a module links against.** A native module is a shared object the
//! loader opens at run time, so it reaches the runtime through the symbol
//! table. The `extern fn` declarations at the foot of this file are that
//! boundary, and they are why this interface is a small file rather than a
//! second compilation of the runtime: `abstract_type.zig` and `raise.zig`
//! compile *into* the module, and everything they need is a symbol.
//!
//! The Zig-side calling convention is `.auto`, which is deterministic for a
//! compiler version and target rather than documented -- `client/interop.zig`
//! has the note. That is the guarantee this interface makes: **a module is
//! built with the same Zig version as the runtime it loads into.** It is a
//! source interface, not a binary one.
//!
//! **What is deliberately not here**: the value representation, the head
//! structs, the collector, the VM. A module holds Janet's data as an opaque
//! `Value` and shares only `src/api/abi.zig`, which `DESIGN.md` section 4
//! decides: private to public breaks nobody, public to private breaks every
//! module there is.
//!
//! **What an author is handed, rather than obtains, is a capability.** There
//! are six: `Env`, the authority to define a binding; `Render`, to append to
//! what a value is being rendered into; `Marshal` and `Unmarshal`, to write
//! and read the stream a value is being marshalled through; and `Wake`, to put
//! a fiber back on the event loop's run queue. Each is `opaque {}` -- it
//! arrives as a parameter, it goes back to a function here, and it converts to
//! and from a `Value` in neither direction. `Loop` is the sixth and the one an
//! author *asks* for rather than is handed; `post` is all it permits, and it
//! is the one thing here a thread with no VM may call. `abi.zig`'s header
//! states the rule and says what it rules out.

const std = @import("std");
const abi = @import("abi");
const repr = @import("repr");
const constants = @import("constants");
const config = @import("config");
const raise = @import("api/raise.zig");
const crossings = @import("api/crossings.zig");
const abstract_type = @import("api/abstract_type.zig");

// ==========================================================================
// The vocabulary
// ==========================================================================

/// A Janet value.
///
/// **Its representation is unsupported, which is not the same as hidden.**
/// This is an alias of the runtime's own value type, so a module that reaches
/// into its union fields will compile. Nothing stops it and nothing is meant
/// to imply otherwise: the interface here is the operations below, and a
/// module that reads the representation is relying on something that changes
/// with `-Dnanbox`, with the target's pointer width, and without notice.
///
/// A by-value runtime type cannot be `opaque` in Zig -- the caller has to know
/// its size to hold one -- so the distinction is stated rather than enforced.
pub const Value = repr.Value;

/// What every fallible entry point here answers. `error.JanetSignal` says the
/// signal and its payload are recorded in the runtime's state -- see `panic`.
pub const Error = raise.Error;

/// The authority to define a binding, which is what a module's entry point is
/// handed.
///
/// A capability rather than a layout: every operation on an environment is a
/// call across the symbol boundary, so an author needs the object and not its
/// fields. The runtime's `tables.Table` keeps the layout, and the two are one
/// pointer to each other. `abi.zig`'s header has the rule that decides this.
pub const Env = abi.Env;

/// The authority to append bytes to what a value is being rendered into, which
/// is what an abstract type's `tostring` callback is handed.
///
/// `push` and `format` below are the operations. It is a capability and not a
/// `Value` for a reason `abi.zig`'s declaration states: the buffer behind it is
/// sometimes a stack local off the collector's heap list, so a `Value` an
/// author kept would sometimes outlive what it points at.
pub const Render = abi.Render;

/// A module's cfunction: arguments in, a value or a signal out.
pub const CFunction = raise.CFunction;

/// An abstract type's dispatch description, and the constructor that builds
/// one from callbacks over `*T`. `DESIGN.md` section 5.
pub const AbstractType = abstract_type.AbstractType;

/// A byte sequence and its length, which is what an abstract type's `bytes`
/// callback answers.
///
/// **The one thing here that is a view rather than a capability.** It is read
/// where it is returned -- `args.bytesView` is the runtime's side -- and
/// nothing crosses again, so a callback may hand back a pointer into its own
/// payload. Storing one outlives nothing the callback owns.
pub const ByteView = abi.ByteView;

/// The elements of a table or a struct, which is what `getDictionary` answers.
///
/// **Three numbers rather than a slice, and that is the shape on purpose.**
/// `kvs` is the whole hash array and `cap` is how long it is; `len` is how
/// many of its slots are occupied. A walk reads every slot and skips the
/// empty ones -- `if (kv.key is nil) continue` -- so a `[]const KV` alone
/// would be a slice whose length answered the wrong question. `abi.zig` has
/// the fields.
///
/// A dictionary lookup by key is `get` rather than a walk, once Janet's own
/// `get` crosses.
pub const DictView = abi.DictView;

/// One entry of a dictionary: a key beside its value, which is what a
/// `DictView` points at an array of.
pub const KV = abi.KV;

/// The two ends of a slice argument, which is what `getRange` answers.
///
/// The fields are `i32` because a Janet index is: `getRange` folds a negative
/// index against the length the caller gave it and reports a half-open
/// interval in the width the interpreter indexes with. Slicing Zig memory with
/// one casts, and the range is already known to fit.
pub const Range = abi.Range;

/// What a raise, a yield or an event asks the interpreter to do.
///
/// It is what `pcall` reports, and it is a closed vocabulary rather than a
/// layout -- `abi.zig` may gain one of those, which `DESIGN.md` section 15's
/// invariant turns on.
pub const Signal = abi.Signal;

/// What a fiber's status is, which is what `pcall` hands a fiber back to be
/// asked. `fiberStatus` is the question.
pub const FiberStatus = abi.FiberStatus;

/// The definition-site checker, so a fixture or an author can reach it without
/// a module of its own.
pub const abstracts = abstract_type;
pub const define = abstract_type.define;

/// One registration row. `DESIGN.md` section 6: one struct, five fields, and
/// the three a build may omit are defaulted.
pub const Reg = abi.Reg;

/// The alignment every cfunction -- and every posted callback -- must be
/// declared with.
///
/// Under 64-bit nanboxing with a nonzero pointer shift, wrapping a function
/// pointer reuses the low bits of its address, and what happens to an
/// under-aligned one differs between the two:
///
/// - a **cfunction** is registered, and `registry.checkPointerAlign` asserts
///   the bits are clear -- with `janet abort`, at load time, naming the module;
/// - a **posted callback** is registered nowhere, so `PostCallback` carries
///   this alignment in the type instead and an under-aligned one is a coercion
///   error at the `&callback` that would have posted it.
///
/// `16` satisfies every shift the build accepts, and over-aligning costs
/// padding measured in bytes. Write
/// `fn myFn(argv: []Value) align(module.fn_align) Error!Value`, and
/// `fn done(w: *Wake, ctx: *anyopaque) align(module.fn_align) callconv(.c) void`.
pub const fn_align = abi.fn_align;

// ==========================================================================
// Raising
// ==========================================================================

/// Refuse, with a message. The signal and payload go into the runtime's state
/// and `error.JanetSignal` says so.
pub const panic = raise.panic;

/// The same, formatted, which is what a refusal naming the offending value
/// needs.
///
/// ```zig
/// return panicFormat("invalid option :{s}", .{name});
/// ```
///
/// **Author-side over `panic`, with no crossing of its own**, and the
/// formatter is Zig's rather than Janet's: `pp/format.zig`'s `panicf` runs the
/// pretty printer over `%v` and the eight spellings of `%q`, which is a
/// runtime engine and not something a module compilation has. What an author
/// gets instead is `std.fmt`, whose `{}` an author already knows.
///
/// It returns the error rather than raising through a `try`, exactly as
/// `panic` does: `return panicFormat(...)` is the shape, and there is nothing
/// to `try` because the payload is `noreturn` in effect.
///
/// The length is counted first so the message is written once into storage
/// that fits it; `std.fmt.count` and `std.fmt.bufPrintZ` run the same
/// formatter over the same arguments, so the second cannot want more room
/// than the first reported. A short message stays on the stack. The heap copy
/// is freed on the way out, which is safe because `panic` interns its message
/// into a Janet string before returning.
pub fn panicFormat(comptime fmt: []const u8, args: anytype) Error {
    const len = std.fmt.count(fmt, args);
    var stack: [256]u8 = undefined;
    if (len < stack.len) return panic(std.fmt.bufPrintZ(&stack, fmt, args) catch unreachable);
    const heap = alloc(u8, len + 1) orelse return panic("out of memory building a refusal");
    defer free(heap);
    return panic(std.fmt.bufPrintZ(heap, fmt, args) catch unreachable);
}

// ==========================================================================
// Arguments
// ==========================================================================

/// Exactly `n` arguments, or a refusal naming the arity.
pub fn fixarity(argv: []const Value, n: i32) Error!void {
    return crossing(crossings.janet_fixarity(@intCast(argv.len), n));
}

/// Between `lo` and `hi`, with `-1` for "no bound".
pub fn arity(argv: []const Value, lo: i32, hi: i32) Error!void {
    return crossing(crossings.janet_arity(@intCast(argv.len), lo, hi));
}

pub fn getNumber(argv: []const Value, n: i32) Error!f64 {
    return crossing(crossings.janet_getnumber(argv.ptr, n));
}

pub fn getInteger(argv: []const Value, n: i32) Error!i32 {
    return crossing(crossings.janet_getinteger(argv.ptr, n));
}

/// An argument of this abstract type, as a `*T`.
///
/// The typed half of `DESIGN.md` section 5: the runtime checks the type and
/// this returns the payload already cast, so a module author's first line is
/// not an unchecked `@ptrCast` the runtime cannot diagnose.
pub fn getAbstract(comptime T: type, argv: []const Value, n: i32, at: *const AbstractType) Error!*T {
    const p = try crossing(crossings.janet_getabstract(argv.ptr, n, at));
    return @ptrCast(@alignCast(p.?));
}

/// The size of a value the runtime treats as a count.
pub fn getSize(argv: []const Value, n: i32) Error!usize {
    return crossing(crossings.janet_getsize(argv.ptr, n));
}

/// An unsigned 32-bit argument.
///
/// **`getSize` is not this**, and the difference is the refusal a user reads:
/// this one says "32 bit unsigned integer" and `getSize` says "size". A width
/// a C library takes as `unsigned` -- a wrap column, a level, a count of
/// something bounded -- is this one.
pub fn getUInteger(argv: []const Value, n: i32) Error!u32 {
    return crossing(crossings.janet_getuinteger(argv.ptr, n));
}

/// A boolean argument. `true` and `false` only: every other value is refused
/// rather than tested for truthiness, which is `isBoolean`'s question and not
/// Janet's `truthy?`.
pub fn getBoolean(argv: []const Value, n: i32) Error!bool {
    return crossing(crossings.janet_getboolean(argv.ptr, n));
}

// ==========================================================================
// The views
// ==========================================================================
//
// **A heap type is read through a view and never handed over as a pointer**,
// which is half of `DESIGN.md` section 15's rule. There are three, and they
// differ only in what an element is: a `u8`, a `Value`, a `KV`. There is no
// `getTuple`, `getArray`, `getString`, `getBuffer`, `getTable` or `getStruct`,
// and there is not meant to be -- the pair on each line below is one view.
//
// **How long a view stays valid is decided by which member of the pair it came
// from**, and each getter says which of the two it can hand back. It is the
// same rule the runtime lives by internally.

/// The bytes of a string, a symbol, a keyword, a buffer, or an abstract with a
/// `bytes` callback.
///
/// **A string's, a symbol's and a keyword's bytes are stable while the value
/// is reachable; a buffer's are not.** A buffer's view is `data[0..count]`,
/// and a push may reallocate the block out from under it. So a view may be
/// read freely within the call, and must not be stored across anything that
/// can mutate the source, which for a buffer includes any Janet code the
/// module re-enters.
///
/// **There is no separate `getCString`.** A C string is this view plus a NUL
/// guarantee, which a string, a symbol and a keyword carry and a buffer does
/// not; a library taking a pointer and a length -- which is most of them --
/// wants the slice as it stands.
pub fn getBytes(argv: []const Value, n: i32) Error![]const u8 {
    const view = try crossing(crossings.janet_getbytes(argv.ptr, n));
    const p = view.bytes orelse return &.{};
    return p[0..view.len];
}

/// The elements of a tuple or an array.
///
/// **The `argv` getters read an element of one.** `getNumber(items, i)` over
/// what this returns is already legal, because every getter above takes any
/// slice of values and an index into it -- so a tuple of numbers is read with
/// the functions already here and there is no second family for elements.
/// `getIndexed(argv, 1)`, then `isKeyword` and `toKeyword` over the result, is
/// what a keyword-options argument looks like. There is no `getKeyword`
/// here: a keyword *argument* is a bytes view like any other, and a keyword
/// inside a view is tested and unwrapped rather than got.
///
/// **A tuple's elements are stable while the tuple is reachable; an array's
/// are not.** An array's view is `data[0..count]` and a push may reallocate,
/// so the view must not be stored across a call that can mutate the source.
/// Same rule as the runtime's own `argIndexed`.
pub fn getIndexed(argv: []const Value, n: i32) Error![]const Value {
    const view = try crossing(crossings.janet_getindexed(argv.ptr, n));
    const p = view.items orelse return &.{};
    return p[0..view.len];
}

/// The entries of a struct or a table, as the three numbers a walk needs.
///
/// ```zig
/// const d = try getDictionary(argv, 0);
/// for (0..d.cap) |i| {
///     const kv = d.kvs.?[i];
///     if (isNil(kv.key)) continue;
///     // ...
/// }
/// ```
///
/// **A `DictView` rather than a `[]const KV`**, because the slice would answer
/// the wrong question: the array is `cap` long and only `len` of its slots are
/// occupied, so a walk reads every slot and skips the empty ones. Handing back
/// `kvs[0..cap]` would put the occupied count out of reach and handing back
/// `kvs[0..len]` would stop the walk early.
///
/// **A struct's entries are stable while it is reachable; a table's are not.**
/// A `put` may rehash, which moves every entry, so the view must not be stored
/// across one.
pub fn getDictionary(argv: []const Value, n: i32) Error!DictView {
    return crossing(crossings.janet_getdictionary(argv.ptr, n));
}

/// A pair of optional index arguments at `n` and `n + 1`, folded against
/// `len`.
///
/// This is what `(f x &opt start end)` reads. A negative index counts from the
/// end, an absent or nil slot takes that whole side, and an end below the
/// start is clamped up to it -- the same three rules `string/slice` and every
/// other core builtin taking a slice follows, because the fold is the same
/// code; the clamp is a line of its own, here and in `args.getSlice` alike.
///
/// `len` is the caller's own count, not a Janet value's: it may be the length
/// of a view read above, or a size a C library reported. It is refused above
/// `maxInt(i32)`, because an index Janet cannot hold cannot name a position in
/// it.
///
/// It is `len` and not `length` because `length` is the generic operation
/// below, and a parameter of that name shadows it for the whole body.
pub fn getRange(argv: []const Value, n: i32, len: usize) Error!Range {
    if (len > std.math.maxInt(i32)) return panic("length exceeds the range a Janet index can name");
    return crossing(crossings.janet_getrange(argv.ptr, @intCast(argv.len), n, @intCast(len)));
}

// ------------------------------------------------ the same three, over a Value
//
// **What reads an element *out* of a view.** The three getters above take an
// argument slot, which is right for an argument and wrong for a `Value` an
// author already holds -- the element of a tuple, the value of a dictionary
// entry. These take the `Value`.
//
// **Absence is `null`, not a refusal.** A getter raises with the runtime's
// message naming a slot, which is what an author wants for a bad *argument*
// and not for a value out of a view, where the slot number would name nothing
// the caller can see. These answer nothing instead, so the refusal is the
// module's own:
//
// ```zig
// const text = bytesView(kv.value) orelse
//     return panicFormat("the value of :{s} is not text", .{name});
// ```
//
// The lifetime rule is the getters', unchanged: which member of the pair the
// value is decides whether the view survives a mutation, and it is not stored
// across one.

/// The bytes of a string, symbol, keyword, buffer or byte-like abstract, or
/// nothing if it is none of them.
pub fn bytesView(v: Value) ?[]const u8 {
    var out: ByteView = undefined;
    if (!crossings.janet_bytes_view(v, &out)) return null;
    const p = out.bytes orelse return &.{};
    return p[0..out.len];
}

/// The elements of a tuple or an array, or nothing.
pub fn indexedView(v: Value) ?[]const Value {
    var out: abi.IndexedView = undefined;
    if (!crossings.janet_indexed_view(v, &out)) return null;
    const p = out.items orelse return &.{};
    return p[0..out.len];
}

/// The entries of a struct or a table, or nothing. See `getDictionary` for
/// what the three numbers mean and how a walk uses them.
pub fn dictionaryView(v: Value) ?DictView {
    var out: DictView = undefined;
    if (!crossings.janet_dictionary_view(v, &out)) return null;
    return out;
}

// ==========================================================================
// Values
// ==========================================================================

pub const number = crossings.janet_wrap_number;
pub const nil = crossings.janet_wrap_nil;

/// Wrap an abstract's payload as a value.
pub fn abstract(p: *anyopaque) Value {
    return crossings.janet_wrap_abstract(p);
}

/// Whether a value is an integer the runtime can hand back as `i32`.
pub fn isInteger(v: Value) bool {
    return crossings.janet_checkint(v) != 0;
}

// ------------------------------------------------------------- the tag tests
//
// **One test per Janet type, named after the tag**, which is what tells the
// members of a view apart: a `[]const Value` from `getIndexed` is a sequence
// of anything, and `isKeyword(items[i])` is how a module reading an options
// tuple refuses the wrong element with its own message rather than the
// runtime's.
//
// **They cross one symbol between them.** `janet_checktype` takes the tag as a
// `c_uint`, and `repr.Tag` is the runtime's spelling of that number: it is a
// module's *own* import -- `repr` is one of the four build modules an
// author's package gets -- so no new crossing is needed for any of these and
// none is added. An author sees neither the tag nor the `c_int`; they see
// `bool`.

/// The one place the tag and the `c_int` are spelled, so twelve predicates
/// cannot disagree about either.
inline fn checkTag(v: Value, comptime t: repr.Tag) bool {
    return crossings.janet_checktype(v, @intFromEnum(t)) != 0;
}

/// Whether a value is nil. Note that `getIndexed` and friends treat an absent
/// or nil argument as a default; this is the direct question.
pub fn isNil(v: Value) bool {
    return checkTag(v, .nil);
}

/// Whether a value is `true` or `false`. Not truthiness: in Janet everything
/// but `nil` and `false` is truthy, and this asks about the type.
pub fn isBoolean(v: Value) bool {
    return checkTag(v, .boolean);
}

/// Janet's truthiness: everything but `nil` and `false`.
///
/// **This is what a value answered by Janet code means**, and it is the only
/// way to read a boolean out of a `Value` at all: `getBoolean` reads an
/// argument slot, and a comparator's answer or an element of a view has no
/// slot. `isBoolean` above asks about the type; this asks the question `(if x
/// ...)` asks.
pub fn truthy(v: Value) bool {
    return crossings.janet_truthy(v);
}

/// Whether a value is a number.
pub fn isNumber(v: Value) bool {
    return checkTag(v, .number);
}

/// Whether a value is a raw pointer.
pub fn isPointer(v: Value) bool {
    return checkTag(v, .pointer);
}

/// Whether a value is a string. `getBytes` accepts this and four other types,
/// so this is the test for a module that wants a string specifically.
pub fn isString(v: Value) bool {
    return checkTag(v, .string);
}

/// Whether a value is a symbol.
pub fn isSymbol(v: Value) bool {
    return checkTag(v, .symbol);
}

/// Whether a value is a keyword, which is what a method lookup is keyed on and
/// what an options tuple holds.
pub fn isKeyword(v: Value) bool {
    return checkTag(v, .keyword);
}

/// Whether a value is a buffer -- the mutable member of the byte pair, whose
/// `getBytes` view a push may invalidate.
pub fn isBuffer(v: Value) bool {
    return checkTag(v, .buffer);
}

/// Whether a value is a tuple -- the immutable member of the indexed pair.
pub fn isTuple(v: Value) bool {
    return checkTag(v, .tuple);
}

/// Whether a value is an array -- the mutable member of the indexed pair,
/// whose `getIndexed` view a push may invalidate.
pub fn isArray(v: Value) bool {
    return checkTag(v, .array);
}

/// Whether a value is a struct -- the immutable member of the dictionary pair.
pub fn isStruct(v: Value) bool {
    return checkTag(v, .@"struct");
}

/// Whether a value is a table -- the mutable member of the dictionary pair,
/// whose `getDictionary` view a `put` may invalidate.
pub fn isTable(v: Value) bool {
    return checkTag(v, .table);
}

pub const toInteger = crossings.janet_unwrap_integer;
pub const toNumber = crossings.janet_unwrap_number;

/// A keyword's name, without the leading colon.
///
/// **An unwrap and not a getter**, in the pattern `toInteger` and `toNumber`
/// already set: it does not check the tag, so `isKeyword` is the caller's
/// first line when the value came out of a view. It is the crossing
/// `getMethod` already makes.
///
/// It is `[:0]` rather than `[]` because a keyword is interned with a
/// terminator, which is the guarantee that lets it be handed straight to a C
/// library taking a `const char *`. The length is the interned one; the span
/// walks to the NUL.
pub fn toKeyword(v: Value) [:0]const u8 {
    return std.mem.span(crossings.janet_unwrap_keyword(v));
}

/// Intern a NUL-terminated string and wrap it as a value.
///
/// **Named for the sentinel, because the runtime walks to it.** The symbol
/// behind this is `janet_cstring`, whose definition is
/// `strings.cstring(str) = new(str[0..strlen(str)])`: the length the runtime
/// interns comes from the NUL and not from a caller's count. A `[]const u8`
/// parameter would accept a slice whose length the result then contradicts, so
/// the sentinel is in the type.
///
/// **There is no constructor for a plain `[]const u8` yet**, which is the
/// shape `std.fmt.bufPrint` answers; `bufPrintZ` covers it until the
/// construction increment `DESIGN.md` section 15 defers to.
pub fn cstring(bytes: [:0]const u8) Value {
    return string(bytes);
}

// ==========================================================================
// Construction
// ==========================================================================
//
// **Construction is the views run backwards.** A constructor takes exactly
// what the getter of the same type hands out -- `[]const u8`, `[]const Value`,
// `[]const KV` -- so `string(try getBytes(argv, 0))` type-checks and so does
// `tuple(try getIndexed(argv, 0))`. That symmetry is what `DESIGN.md` section
// 15's rule predicts, and it is why this half needed no new layout.
//
// **Every one answers a `Value`.** None returns a pointer to an aggregate,
// because an aggregate an author can obtain from a `Value` is addressed by
// that `Value`. Upstream's constructors answer the unwrapped type and wrapping
// is a second call; these are one crossing and put no heap pointer on the
// author's side at any point.
//
// **A value a cfunction builds needs no rooting, and here is the rule that
// makes that true.** A collection runs at the interpreter's safe points --
// `vm.zig`'s `maybeCollect`, between instructions -- and in the `gccollect`
// builtin, and nowhere else: allocating does not collect, it only moves the
// threshold. So a value built here is safe for as long as the cfunction holds
// the frame, even though the collector cannot see a module's stack.
//
// **What ends that is re-entering Janet code**, because the interpreter's safe
// points are then live underneath the module's frame. Three functions below
// do: `call` and `pcall`, which are re-entry by definition, and `length` on an
// abstract type with no `length` slot, which falls through to a Janet-level
// `:length` method. `gcroot` is what protects a value across one, and `call`'s
// doc states the whole rule.

/// `true` or `false` as a value.
pub fn boolean(b: bool) Value {
    return crossings.janet_wrap_boolean(b);
}

/// Intern `bytes` as a string.
///
/// **This is the general constructor and `cstring` is now sugar over it.**
/// `cstring` takes a `[:0]const u8` and was named for the sentinel because the
/// symbol behind it walked to the NUL to find its length; this takes the
/// length from the slice, which for a sentinel slice is the same number. So
/// `cstring(x)` and `string(x)` answer the same string for every `x` either
/// accepts, and `cstring` is kept because it is a published name rather than
/// because it does anything this does not. The crossing it was built on stays
/// regardless: `raise.zig` reaches `janet_cstring` to build a panic message
/// inside a module's own compilation.
pub fn string(bytes: []const u8) Value {
    return crossings.janet_new_string(bytes.ptr, bytes.len);
}

/// Intern `bytes` as a symbol.
pub fn symbol(bytes: []const u8) Value {
    return crossings.janet_new_symbol(bytes.ptr, bytes.len);
}

/// Intern `bytes` as a keyword, which is `toKeyword`'s inverse.
pub fn keyword(bytes: []const u8) Value {
    return crossings.janet_new_keyword(bytes.ptr, bytes.len);
}

/// A tuple holding a copy of `items` -- `getIndexed`'s inverse for the
/// immutable member of the pair.
pub fn tuple(items: []const Value) Value {
    return crossings.janet_new_tuple(items.ptr, items.len);
}

/// An array holding a copy of `items`, and the mutable member: `arrayPush`
/// appends to what this returns, which is why there is no capacity parameter.
/// A module building an array of unknown length makes an empty one and pushes.
pub fn array(items: []const Value) Value {
    return crossings.janet_new_array(items.ptr, items.len);
}

/// A new buffer holding a copy of `bytes`.
pub fn buffer(bytes: []const u8) Value {
    return crossings.janet_new_buffer(bytes.ptr, bytes.len);
}

/// A struct holding these key-value pairs.
///
/// **`kvs` is the caller's pairs and not a `DictView`.** A view is a hash
/// array, `cap` slots long with `len` of them occupied and the rest empty;
/// this is `kvs.len` pairs with nothing empty among them. Passing a view's
/// `kvs[0..len]` would be wrong for that reason, and the types keep them
/// apart. A repeated key keeps the last, as a struct literal does.
///
/// **A nil value drops its pair**, and so does a key a dictionary cannot store,
/// exactly as a struct literal does: `{:a nil}` is `{}`.
///
/// **Named `structOf` because `struct` is a Zig keyword.** `@"struct"` is the
/// alternative and it would have to be written that way at every call site in
/// every module; `tableOf` follows it so the pair reads as a pair.
pub fn structOf(kvs: []const KV) Value {
    return crossings.janet_new_struct(kvs.ptr, kvs.len);
}

/// A table holding these key-value pairs. See `structOf`, including what a nil
/// value does.
pub fn tableOf(kvs: []const KV) Value {
    return crossings.janet_new_table(kvs.ptr, kvs.len);
}

/// A raw pointer as a value, which only `toPointer` reads back.
///
/// It is opaque to Janet: nothing dereferences it and marshalling one is
/// refused outside unsafe mode, for the reason `pushPointer` gives.
///
/// **It survives the round trip only if it is aligned to `fn_align`.** Under
/// 64-bit nanboxing with a nonzero pointer shift the wrap discards the low
/// bits of the address, and nothing checks this one -- `registry`'s check is
/// for a registered cfunction or abstract type, and this is neither. A pointer
/// from `alloc` or `new` is aligned well past that; a pointer into the middle
/// of a buffer may not be.
pub fn pointer(p: ?*anyopaque) Value {
    return crossings.janet_wrap_pointer(p);
}

/// `pointer`'s inverse. Like `toInteger` and `toKeyword` it does not check the
/// tag, so `isPointer` is the caller's first line when the value came out of a
/// view.
pub fn toPointer(v: Value) ?*anyopaque {
    return crossings.janet_unwrap_pointer(v);
}

// ==========================================================================
// Access and mutation, through the `Value`
// ==========================================================================
//
// **Janet's own `get`, `put` and `length`, over any value rather than one per
// type.** The runtime decides what each type means by them, so a module
// carries no switch over collections -- and no `*Table` or `*Array` ever
// crosses to be mutated, which is the other half of section 15's rule. A
// generic `get` also answers a dictionary lookup without walking a view, which
// is what a keyword-options module wants most of the time.

/// What `(get ds key)` answers.
///
/// **A miss is nil and so is a value with no indexed access**: `get` on a
/// number answers nil rather than refusing, which is Janet's own behaviour and
/// is checked rather than assumed. What it can raise is an abstract type's
/// `get` callback, which is why it is fallible at all.
pub fn get(v: Value, key: Value) Error!Value {
    return crossing(crossings.janet_get(v, key));
}

/// What `(put ds key x)` does. Unlike `get` this refuses a value it cannot
/// store into, with the runtime's own message -- `expected array, table or
/// buffer, got 3`.
pub fn put(v: Value, key: Value, x: Value) Error!void {
    return crossing(crossings.janet_put(v, key, x));
}

/// What `(length x)` answers, refusing anything with no length.
///
/// `usize` because it is a count, where the runtime answers Janet's own `i32`.
///
/// **A length is never negative, and that is the runtime's refusal rather than
/// a property of the arms.** Every arm that reads a count narrows from an
/// unsigned one, and both ends of the range are refused where the length is
/// produced: an abstract type's `length` slot above `maxInt(i32)`, and a
/// Janet-level `:length` method below zero. So the narrowing here is one-way
/// and needs no guard of its own. `DESIGN.md` section 12 carries the second of
/// those, which this interface is the reason for.
///
/// **Its method arm re-enters Janet code**, so it is one of the three
/// functions here under which a collection can run. `call` states the rule and
/// what to do about it.
pub fn length(v: Value) Error!usize {
    return @intCast(try crossing(crossings.janet_length(v)));
}

/// Append to an array, which `put` has no spelling for -- `put` writes at an
/// index and this extends. Refused on anything that is not an array.
pub fn arrayPush(v: Value, x: Value) Error!void {
    return crossing(crossings.janet_array_push_value(v, x));
}

/// Append to a buffer. See `arrayPush`.
pub fn bufferPush(v: Value, bytes: []const u8) Error!void {
    return crossing(crossings.janet_buffer_push_value(v, bytes.ptr, bytes.len));
}

/// Keep a value reachable for the collection in progress.
///
/// **This is what an abstract type's `gcmark` callback is for**, and the only
/// thing it may do: a payload holding a `Value` has no other way to say the
/// collector must not free what it points at. Reached from anywhere else it
/// sets mark bits against whatever traversal happens to be running -- or, once
/// the collector's recursion budget is spent, roots the value *permanently*,
/// because `gc/mark.zig`'s exhausted arm is `gcroot`.
///
/// It cannot raise, which is the same contract `gcmark` itself carries --
/// `abstract_type.Spec` has the argument.
pub fn mark(v: Value) void {
    crossings.janet_mark(v);
}

// ==========================================================================
// Calling back into Janet
// ==========================================================================
//
// **Two shapes, because the runtime has two.** `call` runs a callee on the
// current fiber and raises on anything but a return; `pcall` runs one on a
// fresh fiber and reports the signal, the value and the fiber. `call` is the
// one to reach for. `pcall` is for a module that has to *look* at a yield or
// an error rather than propagate it, and it is the only way to obtain a fiber
// here.

/// Call `f` with `args`, as `(f ;args)` does, raising on anything else.
///
/// **`f` is whatever Janet calls.** A function, a cfunction, an abstract type
/// with a `call` slot, and the six indexable types, which index their one
/// argument rather than call it -- `(:key struct)` and `({:a 1} :a)` are both
/// calls in Janet and are both calls here. That is `vm.zig`'s `methodInvoke`,
/// which is the dispatcher the interpreter itself reaches; `vm/entry.zig`'s
/// `call` is narrower and takes an already-resolved function.
///
/// **It raises on every signal but a return.** An error from Janet code
/// arrives as `Error.JanetSignal` carrying that error's own payload. A yield
/// or a debug signal arrives as one too, carrying the message the runtime
/// coerces it into -- `<value> coerced from yield to error`. Use `pcall` where
/// that is a case to handle rather than to propagate.
///
/// **Three things about a `Value` across this call**, which is where a
/// module's temporaries stop being safe:
///
/// 1. A collection runs at the interpreter's safe points, and this call is
///    what puts them underneath a module's frame. A `Value` reachable from
///    nothing but the module's own stack can be freed here; the collector does
///    not scan that stack.
/// 2. `gcroot` before the call and `gcunroot` after is the protection, one
///    pair per value. Nothing here roots on a module's behalf.
/// 3. `args` needs no root of its own -- they are copied onto the fiber's
///    stack before the loop runs, which is where the collector does look --
///    and neither does the result, which comes back the same way and is safe
///    until the next re-entry. Passing the cfunction's own `argv`, or a tail
///    of it, is safe and is the ordinary thing to do: those are a slice of
///    that same stack, and the runtime's push re-derives its source when it is
///    also the push that grows the stack it is reading from.
///
/// **What does not survive this call is `argv` itself**, which is the same
/// fact from the other side. The arguments a cfunction was handed live on that
/// fiber's stack, and a call into Janet *may* grow it, which reallocates, and
/// a `-Dfiber-stack-shuffle=true` build moves it on every frame push whether
/// it needs to or not. So `argv` is good until the first call and not after
/// it: copy what is still wanted into a local *before* that call. A `Value`
/// copied that way is safe if something the collector traces still holds what
/// it names -- an argument the calling Janet frame passed is such a thing --
/// and needs `gcroot` otherwise.
///
/// A `ByteView`, an `IndexedView` or a `DictView` taken from `argv` is not
/// affected by any of this: those point at the aggregate's own heap storage
/// rather than at the stack. What invalidates one is the callee mutating the
/// aggregate it views, which is the lifetime rule each getter already states.
///
/// The recursion guard is the runtime's: a module calling into Janet code that
/// calls the module again refuses with `C stack recursed too deeply` at the
/// same depth the interpreter refuses its own.
pub fn call(f: Value, args: []const Value) Error!Value {
    return crossing(crossings.janet_call_value(f, args.ptr, args.len));
}

/// What `pcall` answers: the signal the fiber ended on, the value that goes
/// with it, and the fiber that ran it.
///
/// **It does not cross.** A `callconv(.c)` return cannot carry a struct
/// holding a `Value` and an enum without an `extern` layout, and this boundary
/// adds none -- `DESIGN.md` section 15. The crossing answers the signal and
/// writes the two values through out-parameters; this is assembled on this
/// side.
///
/// `value` is the return value on `.ok`, the error's payload on `.@"error"`,
/// and the yielded value on `.yield`. `fiber` is what `fiberStatus` asks
/// about, and is nil only where no fiber was made.
///
/// **Both are ordinary results and neither is rooted.** Once `pcall` returns,
/// nothing the collector traces holds the fiber, so it lives under `call`'s
/// rule like any other value this surface hands back: safe until the next
/// re-entry, and `gcroot` is what keeps it past one. A module that means to
/// resume the fiber later is the case that needs it.
pub const Called = struct { signal: Signal, value: Value, fiber: Value };

/// Call `f` with `args` on a fresh fiber, and report rather than raise.
///
/// **It never raises**, which is the whole difference from `call`: an error in
/// the called code is `.@"error"` with the payload in `value`, a yield is
/// `.yield` with the yielded value, and the fiber is `:pending` and can be
/// resumed from Janet. A callee that is not a function is reported the same
/// way -- a fiber runs a function and nothing else, which is why
/// `(fiber/new <cfunction>)` refuses too.
///
/// **The fiber is always fresh.** The runtime's `pcall` can recycle one; that
/// is an ownership contract nothing else at this boundary has, so it is not
/// offered.
///
/// This re-enters Janet code, so `call`'s rule about a `Value` across a
/// re-entry holds here word for word.
pub fn pcall(f: Value, args: []const Value) Called {
    var out_value: Value = nil();
    var out_fiber: Value = nil();
    const signal = crossings.janet_pcall_value(f, args.ptr, args.len, &out_value, &out_fiber);
    return .{ .signal = signal, .value = out_value, .fiber = out_fiber };
}

/// The status of a fiber, refusing anything that is not one with the runtime's
/// own message.
///
/// The vocabulary is wider than `Signal` by two: `new`, which a fiber has
/// before it first runs, and `alive`, which it has while it is running. The
/// other fourteen share the signal's numbering.
pub fn fiberStatus(fiber: Value) Error!FiberStatus {
    return crossing(crossings.janet_fiber_status_value(fiber));
}

/// Keep `v` reachable across a call into Janet code, until `gcunroot`.
///
/// **The root set is a multiset**, so rooting the same value twice takes two
/// unrootings; a root and its unroot are a pair, and pairing them is the
/// module's job. This is what `call` and `pcall` need and it is the *only*
/// rooting on this surface: a global collection lock is what an author reaches
/// for when they do not know which value to protect, and a missing unlock is a
/// runtime that never collects again. `DESIGN.md` section 15 states that.
///
/// It is not `mark`. `mark` is for an abstract type's `gcmark` callback and
/// acts on the traversal already running; this adds to the set every traversal
/// starts from.
pub fn gcroot(v: Value) void {
    crossings.janet_gcroot(v);
}

/// Drop one rooting of `v`, answering whether there was one to drop.
///
/// A `false` answer means the pair was unbalanced -- nothing was rooted, or
/// something already dropped it -- and is worth testing during development for
/// exactly that reason.
pub fn gcunroot(v: Value) bool {
    return crossings.janet_gcunroot(v);
}

// ==========================================================================
// Scheduling work through the event loop
// ==========================================================================
//
// **The whole of what the loop does is one sentence: when something happens,
// resume a fiber with a value.** A module brings its own source of "something
// happens" -- its own thread, its own library's poll, its own socket -- and
// three operations are what it takes to join in:
//
//   1. `await` suspends the fiber a cfunction is running on;
//   2. `post` asks the loop thread to run a callback, and is the one function
//      here a thread with no VM may call;
//   3. `wake` puts the fiber back on the run queue with its value.
//
// `loop` and `rootFiber` are what a cfunction holds before it suspends, and
// `Loop` and `Wake` are what carry the thread discipline in the types: a
// worker thread can hold a `Loop` and do exactly one thing with it, and only
// a posted callback is handed a `Wake`.
//
// **The shape of a module that uses this**, and `examples/digest` is the
// worked instance:
//
// ```zig
// fn hash(argv: []janet.Value) align(janet.fn_align) janet.Error!janet.Value {
//     const ctx = janet.new(Context, ...);          // the module's own
//     ctx.loop = try janet.loop();
//     ctx.fiber = try janet.rootFiber();
//     janet.gcroot(ctx.fiber);
//     _ = try std.Thread.spawn(.{}, work, .{ctx});  // touches janet.post only
//     return janet.await();
// }
//
// fn done(w: *janet.Wake, raw: *anyopaque) callconv(.c) void {
//     const ctx: *Context = @ptrCast(@alignCast(raw));
//     _ = janet.wake(w, ctx.fiber, janet.string(ctx.answer));
//     _ = janet.gcunroot(ctx.fiber);
//     free(ctx);                                    // on the false branch too
// }
// ```
//
// **What is deliberately not offered**: the runtime's thread pool, its timers,
// its streams and async listeners, and its channels. A module brings its own
// thread and posts. `DESIGN.md` section 15 says why each waits.

/// The authority to ask the loop to run a callback, and the one capability an
/// author asks for rather than is handed.
pub const Loop = abi.Loop;

/// The authority to resume a fiber, handed to a posted callback for that call.
pub const Wake = abi.Wake;

/// What `post` runs on the loop thread: `fn (*Wake, *anyopaque) callconv(.c) void`.
pub const PostCallback = abi.PostCallback;

/// Suspend this fiber until something wakes it.
///
/// **It is a raise carrying the event signal**, so a cfunction writes
/// `return janet.await()` as the last thing it does, *after* arranging for the
/// wake. There is no capability, because there is nothing to check: it can
/// only be called where a cfunction can.
///
/// **Arrange first, then suspend.** Starting the thread before this returns is
/// not a race: the loop is single-threaded, so an event a worker posts before
/// the cfunction has returned is not processed until the fiber has suspended.
///
/// It is not a symbol. `raise.zig` compiles into the module and records the
/// signal through `janet_zig_signal_record`, which is the same path
/// `janet.panic` takes with a different signal.
pub fn await() Error {
    return raise.signal(.event, nil());
}

/// The loop this cfunction is running on.
///
/// **What it answers may be carried to any thread, and `post` is all that
/// accepts it.** Its lifetime is the runtime's: valid until the VM that
/// answered it shuts down. A module whose thread holds one is what has to stop
/// that thread before the runtime exits, and that is the one ownership
/// contract on this surface.
///
/// **A build without the event loop refuses here**, with `event loop not
/// enabled`, and that refusal is what makes `post`, `wake` and a useful
/// `await` unreachable in one: none of them can be called without this. The
/// loader's version check does not see the difference -- `JANET_VM_HAS_EV` is
/// not among the bits `_janet_mod_config` reports -- so this message is what a
/// user of a no-loop build actually gets.
pub fn loop() Error!*Loop {
    return crossing(crossings.janet_current_loop());
}

/// The fiber `await` suspends and `wake` puts back.
///
/// **Read it before `await`, hold it across the wait, and hand it to `wake`.**
/// It is an ordinary `Value` under `call`'s rule, and the wait is a re-entry
/// like any other: `gcroot` it before `await` and `gcunroot` it in the
/// callback after `wake`. From the wake onward the runtime holds it too -- the
/// scheduler marks a woken fiber as a task -- but before the wake the root is
/// the only thing that does.
///
/// This is the outermost fiber the interpreter is running, which under
/// `ev/go` is the task fiber the loop resumes.
pub fn rootFiber() Error!Value {
    return crossing(crossings.janet_root_fiber_value());
}

/// Ask the loop thread to run `cb(wake, ctx)` at its next turn.
///
/// **This is the one function in this file that may be called from a thread
/// with no VM**, which is what a module's own worker thread is. It reads no
/// Janet state to do it: the loop is the `l` you pass, not a thread-local, and
/// what it writes is one fixed-size event into the loop's self-pipe. It
/// allocates nothing away from Windows, where the completion-port arm
/// allocates one event per post.
///
/// **Everything else here is off limits on such a thread**, and calling one
/// aborts with `called from a thread that is not running Janet` rather than
/// reading null state. `ctx` is the module's and the runtime neither reads nor
/// frees it.
///
/// **Back-pressure is a block, not a drop.** The self-pipe's write side is
/// blocking, so a thread posting faster than the loop drains waits in the
/// write. Any number of threads may post at once; callbacks run one at a time
/// on the loop thread, in arrival order, and nothing promises an order across
/// modules.
///
/// Before the loop runs or after it stops, posts queue and are drained at the
/// loop's next turn; a program that never enters the loop never runs them.
pub fn post(l: *Loop, cb: PostCallback, ctx: *anyopaque) void {
    crossings.janet_post(l, cb, ctx);
}

/// Put `fiber` back on the run queue with `value`, answering whether it took.
///
/// **Only inside a posted callback**, which is what holding a `*Wake` means.
///
/// **A `false` answer is not a failure to handle but a state to clean up
/// after**: `ev/cancel` may have moved the fiber on, or the fiber may have
/// finished, and in either case the runtime would have dropped the resume.
/// The context is the module's to free in the callback whether this answered
/// true or false, and so is the `gcunroot` of the fiber.
///
/// **The fiber must be one this loop runs**, which in practice means the one
/// `rootFiber` answered on the way in. Waking another interpreter's fiber onto
/// this scheduler's queue is undefined and nothing here can detect it; the
/// capability names the loop and not the fiber.
///
/// A fiber that has never run is started rather than resumed, which `ev/go`
/// would also do -- so this is a way to launch one, if a module has a reason to.
///
/// A fiber that is already queued gets a second task, and the runtime keeps
/// the later one: `ev.scheduleGeneral` bumps the fiber's `sched_id` and
/// `ev.loop1` skips any task whose recorded id no longer matches. That is
/// Janet's own behaviour for two schedules of one fiber and not something this
/// adds.
///
/// It cannot raise. The callback it runs inside has no scope above it, which
/// is the same contract the six non-raising abstract-type slots carry.
/// Building a `Value` inside one is still allowed: the collector's allocation
/// is fatal on failure rather than a raise, and no safe point runs between
/// fibers on the loop thread.
pub fn wake(w: *Wake, fiber: Value, value: Value) bool {
    return crossings.janet_wake(w, fiber, value);
}

// ==========================================================================
// Rendering
// ==========================================================================

/// Append bytes to what a value is being rendered into.
///
/// This is the whole of what an abstract type's `tostring` callback may do
/// with the `*Render` it is handed. `push` after `buffers.pushBytes` and
/// Janet's own `buffer/push`, which is this project's verb for appending to a
/// buffer at every level.
pub fn push(r: *Render, bytes: []const u8) Error!void {
    return crossing(crossings.janet_buffer_push_bytes(r, bytes.ptr, bytes.len));
}

/// The same, formatted, after `buffer/format`.
///
/// **Author-side over `push`, with no crossing of its own.** The length is
/// counted first so that the rendering is written once into storage that fits
/// it; `std.fmt.count` and `std.fmt.bufPrint` run the same formatter over the
/// same arguments, so the second cannot want more room than the first
/// reported. A short result stays on the stack, because a `tostring` runs once
/// per rendered value and an allocation per value is a cost `push` does not
/// have.
pub fn format(r: *Render, comptime fmt: []const u8, args: anytype) Error!void {
    const len = std.fmt.count(fmt, args);
    if (len == 0) return;
    var stack: [256]u8 = undefined;
    if (len <= stack.len) return push(r, std.fmt.bufPrint(&stack, fmt, args) catch unreachable);
    const heap = alloc(u8, len) orelse return panic("out of memory");
    defer free(heap);
    return push(r, std.fmt.bufPrint(heap, fmt, args) catch unreachable);
}

// ==========================================================================
// Marshalling
// ==========================================================================

/// The authority to append to the stream a value is being marshalled into,
/// which is what an abstract type's `marshal` callback is handed.
///
/// The `push*` functions below are the operations. **`pull*` will not compile
/// against one**, and that is the reason there are two types: the runtime
/// builds the push side and the pull side at separate sites, so a read inside
/// a `marshal` callback has no stream to read from. `abi.zig`'s declaration
/// has the argument.
pub const Marshal = abi.Marshal;

/// The authority to read from the stream a value is being unmarshalled from,
/// which is what an abstract type's `unmarshal` callback is handed. The
/// `pull*` functions below are the operations. See `Marshal`.
pub const Unmarshal = abi.Unmarshal;

/// Enter the abstract into the stream's reference table.
///
/// **Call it before pushing the payload**, and `unmarshal` must call
/// `pullAbstract` or `pullAbstractReuse` in the same position. That is what
/// lets a value reached later in the same stream refer back to this object
/// rather than encoding a second copy of it; the runtime refuses an
/// `unmarshal` that never registers.
pub fn pushAbstract(m: *Marshal, p: *anyopaque) void {
    crossings.janet_marshal_abstract(m, p);
}

pub fn pushSize(m: *Marshal, n: usize) Error!void {
    return crossing(crossings.janet_marshal_size(m, n));
}

pub fn pushInteger(m: *Marshal, x: i32) Error!void {
    return crossing(crossings.janet_marshal_int(m, x));
}

pub fn pushInt64(m: *Marshal, x: i64) Error!void {
    return crossing(crossings.janet_marshal_int64(m, x));
}

pub fn pushByte(m: *Marshal, b: u8) Error!void {
    return crossing(crossings.janet_marshal_byte(m, b));
}

pub fn pushBytes(m: *Marshal, bytes: []const u8) Error!void {
    return crossing(crossings.janet_marshal_bytes(m, bytes.ptr, bytes.len));
}

/// Push a whole `Value`, which re-enters the marshaller's own traversal.
pub fn pushValue(m: *Marshal, v: Value) Error!void {
    return crossing(crossings.janet_marshal_janet(m, v));
}

/// **No float entry point exists, and this is why there is sugar for one.**
/// Neither the marshaller nor the retired header has one, so an author's
/// obvious move is a raw `pushBytes` of host-endian doubles -- which a stream
/// written on one machine and read on another decodes as garbage. A number
/// `Value` is the runtime's own encoding and travels correctly.
pub fn pushNumber(m: *Marshal, x: f64) Error!void {
    return pushValue(m, number(x));
}

/// Only meaningful in unsafe mode; a pointer means nothing to another process.
/// The runtime refuses this outright when `isUnsafe` is false, so ask first.
pub fn pushPointer(m: *Marshal, p: ?*const anyopaque) Error!void {
    return crossing(crossings.janet_marshal_ptr(m, p));
}

/// Allocate this type's payload and enter it into the stream's reference
/// table, which is `pushAbstract`'s counterpart.
///
/// `size` is the whole allocation and defaults to `@sizeOf(T)`, exactly as
/// `new`'s does and for the same reason: `T` is the *header* type, and an
/// abstract may carry trailing bytes whose length the stream has just been
/// read for. `new` plus `pullAbstractReuse` is the same thing in two calls.
pub fn pullAbstract(u: *Unmarshal, comptime T: type, size: ?usize) Error!*T {
    const p = try crossing(crossings.janet_unmarshal_abstract(u, size orelse @sizeOf(T)));
    return @ptrCast(@alignCast(p.?));
}

/// Enter an already-allocated payload into the stream's reference table.
/// Exactly one of this and `pullAbstract` is called, exactly once.
pub fn pullAbstractReuse(u: *Unmarshal, p: *anyopaque) Error!void {
    return crossing(crossings.janet_unmarshal_abstract_reuse(u, p));
}

pub fn pullSize(u: *Unmarshal) Error!usize {
    return crossing(crossings.janet_unmarshal_size(u));
}

pub fn pullInteger(u: *Unmarshal) Error!i32 {
    return crossing(crossings.janet_unmarshal_int(u));
}

pub fn pullInt64(u: *Unmarshal) Error!i64 {
    return crossing(crossings.janet_unmarshal_int64(u));
}

pub fn pullByte(u: *Unmarshal) Error!u8 {
    return crossing(crossings.janet_unmarshal_byte(u));
}

pub fn pullBytes(u: *Unmarshal, dest: []u8) Error!void {
    return crossing(crossings.janet_unmarshal_bytes(u, dest.ptr, dest.len));
}

/// Pull a whole `Value`, which re-enters the unmarshaller's own traversal.
pub fn pullValue(u: *Unmarshal) Error!Value {
    return crossing(crossings.janet_unmarshal_janet(u));
}

/// `pushNumber`'s counterpart, with the type check the push side promises.
pub fn pullNumber(u: *Unmarshal) Error!f64 {
    const v = try pullValue(u);
    if (!isNumber(v)) return panic("expected a number in the stream");
    return toNumber(v);
}

/// `pushPointer`'s counterpart, and refused outside unsafe mode for the same
/// reason. See `isUnsafe`.
pub fn pullPointer(u: *Unmarshal) Error!?*anyopaque {
    return crossing(crossings.janet_unmarshal_ptr(u));
}

/// Refuse now if the stream does not hold `n` more bytes.
pub fn pullEnsure(u: *Unmarshal, n: usize) Error!void {
    return crossing(crossings.janet_unmarshal_ensure(u, n));
}

/// How many bytes of the stream are still unread.
///
/// **This is what bounds a count the stream chose.** A callback told a length
/// before it is told the elements refuses a length this cannot cover: no
/// element is shorter than one byte, so a stream promising more elements than
/// it has bytes left is refused before anything is allocated for them.
pub fn pullRemaining(u: *Unmarshal) usize {
    return crossings.janet_unmarshal_remaining(u);
}

/// Whether this stream is being written or read in a process that trusts it.
///
/// ```zig
/// if (!isUnsafe(m)) return panic("cannot marshal a handle in safe mode");
/// ```
///
/// **The only bit of the marshal flag word an author has a reason to ask
/// about**, which is why it is the whole of what is offered. The rest of that
/// word is the marshaller's own bookkeeping -- the cycle policy, the recursion
/// depth -- and handing it over as a `c_int` meant handing over a number whose
/// bits an author's package cannot name, because the constants live in a
/// module it does not import. A predicate needs no constant.
///
/// It is what `pushPointer` and `pullPointer` are refused without: a pointer
/// means nothing to another process, so the runtime declines to write or read
/// one unless this is set.
///
/// **One name over both capabilities.** Zig has no overloading, so this takes
/// `anytype` and decides at comptime; the alternative is two names for one
/// question, and the question really is the same one on both sides. Anything
/// else is a compile error naming the two types, in the pattern
/// `checkCFunction` and `abstract_type.check` already set.
pub fn isUnsafe(capability: anytype) bool {
    const Given = @TypeOf(capability);
    if (Given != *Marshal and Given != *Unmarshal) @compileError(
        "isUnsafe takes the `*Marshal` a `marshal` callback is handed or the " ++
            "`*Unmarshal` an `unmarshal` callback is handed -- it is `" ++
            @typeName(Given) ++ "`.",
    );
    const flags = if (Given == *Marshal)
        crossings.janet_marshal_flags(capability)
    else
        crossings.janet_unmarshal_flags(capability);
    return (flags & constants.JANET_MARSHAL_UNSAFE) != 0;
}

// ==========================================================================
// Methods
// ==========================================================================

/// One row of a method table: a name and a cfunction, exactly as a
/// registration row is a name and a cfunction. It is its own type because a
/// method table is not a registration -- `DESIGN.md` section 6 keeps them
/// apart for that reason.
///
/// `abi.Method` is the one declaration, shared with the runtime's own
/// `method_type.zig`: a layout declared on both sides of a compilation
/// boundary is what `abi.zig` exists to stop, and
/// `tools/check/layouts.txt` carries a single row for it.
pub const Method = abi.Method;

/// Answer a `:keyword` lookup out of a method table, or nothing.
///
/// This is what an abstract type's `get` callback delegates to when the key is
/// a keyword, which is how `(:scale a 5)` finds `scale`. It answers `?Value`
/// because that is what `get` answers: absence is the absent value, not a flag
/// beside an out-parameter.
pub fn getMethod(key: Value, methods: []const Method) Error!?Value {
    const table = terminate(Method, methods);
    var out: Value = undefined;
    if (try crossing(crossings.janet_getmethod(crossings.janet_unwrap_keyword(key), @ptrCast(&table), &out)) == 0) return null;
    return out;
}

/// The next method name after `key`, or nil at the end -- an abstract type's
/// `next` callback over the same table.
pub fn nextMethod(methods: []const Method, key: Value) Error!Value {
    const table = terminate(Method, methods);
    return crossing(crossings.janet_nextmethod(@ptrCast(&table), key));
}

// ==========================================================================
// Allocating an abstract
// ==========================================================================

/// Allocate an abstract of this type, as a `*T`.
///
/// `size` is the whole allocation and defaults to `@sizeOf(T)`. It is a
/// parameter because `T` is the *header* type: an abstract may carry trailing
/// bytes, which is the shape `DESIGN.md` section 3 describes and what the
/// runtime's own socket-address, compiled-PEG and stream types all do.
pub fn new(comptime T: type, at: *const AbstractType, size: ?usize) *T {
    const p = crossings.janet_abstract(at, size orelse @sizeOf(T));
    return @ptrCast(@alignCast(p.?));
}

/// The runtime's allocator, for memory an abstract owns and its `gc` frees:
/// `n` contiguous zeroed `T`, or null if the allocation failed.
///
/// Zeroed is `calloc`'s own guarantee rather than a `@memset` after the fact,
/// and a module may rely on it.
///
/// **Typed for the reason `new` is typed.** The hook underneath answers
/// `?*anyopaque` for a count and an element size, so an untyped re-export of it
/// put `@sizeOf`, `@alignCast` and `@ptrCast` at every call in every module
/// that allocates -- and the `@alignCast` is the one that matters. `malloc`
/// promises no more than `max_align_t`; written out at an author's call site
/// that is an assumption nothing checks, and an over-aligned payload is
/// undefined behaviour with no diagnostic. Here it is a compile error, below.
///
/// **The null is kept, and that is where this parts company with `new`.**
/// `janet_abstract` collects and aborts, so it has no null to hand back; a
/// cfunction has a scope above it and may refuse. `orelse return panic("...")`
/// is the shape, and `examples/numarray` is the worked instance -- including
/// the ordering it forces, which is the part worth reading.
pub inline fn alloc(comptime T: type, n: usize) ?[]T {
    if (@alignOf(T) > @alignOf(std.c.max_align_t)) @compileError(std.fmt.comptimePrint(
        "alloc({s}): this type's alignment is {d}. The runtime's allocator is " ++
            "malloc-backed and promises nothing stricter than `max_align_t`, so a payload " ++
            "needing more has to align its own storage inside an allocation this can make.",
        .{ @typeName(T), @alignOf(T) },
    ));
    const p = crossings.janet_calloc(n, @sizeOf(T)) orelse return null;
    const many: [*]T = @ptrCast(@alignCast(p));
    return many[0..n];
}

/// Free what `alloc` returned, as either the slice or the pointer the owner
/// kept.
///
/// Typed for the other half of the same reason: a `free` taking `?*anyopaque`
/// leaves a `@ptrCast` in the one callback that must not get memory wrong.
pub inline fn free(mem: anytype) void {
    const p = switch (@typeInfo(@TypeOf(mem)).pointer.size) {
        .slice => mem.ptr,
        else => mem,
    };
    crossings.janet_free(@ptrCast(p));
}

// ==========================================================================
// Registering
// ==========================================================================

/// Install a table of cfunctions into the environment the entry point was
/// handed.
///
/// The table is a slice with no terminator row: its length is known where it
/// is written. `DESIGN.md` section 6.
pub fn cfuns(env: *Env, prefix: ?[*:0]const u8, table: []const Reg) void {
    const terminated = terminate(Reg, table);
    crossings.janet_cfuns_ext(env, prefix, @ptrCast(&terminated));
}

/// The most rows one table may hold, terminator excluded.
///
/// **It is the buffer's length minus the terminator, and it says so.** Naming
/// the bound once and deriving both the buffer and the assertion from it is
/// what keeps the prose and the check from disagreeing.
///
/// The bound applies to a **method table as well as a registration table** --
/// both go through `terminate` -- and the two are not equally easy to live
/// with. A registration table splits into two `cfuns` calls with no visible
/// difference. A method table is one value handed to `getMethod` and
/// `nextMethod`, so splitting one changes what an abstract type answers; a
/// type needing more than this many methods wants a different lookup, not a
/// second table.
pub const max_table_rows = 128;

/// A null-name row appended to a table, because the four entry points a module
/// can reach are C symbols that read one.
///
/// The bound is a fixed buffer rather than an allocation on purpose: this runs
/// at module load, before there is anything to clean up if it failed.
fn terminate(comptime Row: type, rows: []const Row) [max_table_rows + 1]Row {
    std.debug.assert(rows.len <= max_table_rows);
    var out: [max_table_rows + 1]Row = @splat(.{});
    @memcpy(out[0..rows.len], rows);
    return out;
}

/// One row, with the cfunction stored the way the runtime holds it.
///
/// The runtime holds a cfunction in a slot typed by the C ABI, so putting one
/// there is a `@ptrCast` and a cast accepts anything. `checkCFunction` is what
/// stops that being the module author's problem: the shape is checked here,
/// at the registration, which is the only place it can still be diagnosed.
pub fn reg(comptime name: [:0]const u8, cfun: anytype, comptime doc: ?[:0]const u8) Reg {
    comptime checkCFunction(name, @TypeOf(cfun));
    return .{
        .name = name.ptr,
        .cfun = raise.stored(cfun),
        .documentation = if (doc) |d| d.ptr else null,
    };
}

/// The contract a cfunction has to meet, stated rather than cast over.
///
/// **A decision about a callback type is a decision about somebody else's
/// compile error**, so the truth goes in the type where it can be diagnosed
/// early. Without this the
/// mistake is a wrong function pointer in a registration table, and it
/// surfaces as a crash inside the interpreter with nothing naming the module.
fn checkCFunction(comptime name: []const u8, comptime Given: type) void {
    const where = "cfunction '" ++ name ++ "': ";
    const wanted = "it must be `fn (argv: []Value) align(module.fn_align) Error!Value`";

    const fn_info = switch (@typeInfo(Given)) {
        .@"fn" => |fi| fi,
        .pointer => |ptr| switch (@typeInfo(ptr.child)) {
            .@"fn" => |fi| fi,
            else => @compileError(where ++ "this is not a function -- " ++ wanted),
        },
        else => @compileError(where ++ "this is not a function -- " ++ wanted),
    };
    if (fn_info.params.len != 1 or fn_info.params[0].type != []Value) {
        @compileError(where ++ "it takes its arguments as one `[]Value` slice, not " ++
            "a count and a pointer -- " ++ wanted);
    }
    const R = fn_info.return_type orelse @compileError(where ++ wanted);
    if (R != Error!Value) {
        // **The exact type, not the shape of it.** Accepting any error union
        // whose payload is `Value` admits `anyerror!Value`, which the runtime
        // then invokes through the narrower `Error!Value`: a broader error set
        // reinterpreted at the call rather than diagnosed at the definition,
        // which is the one place it can be.
        @compileError(where ++ "its return type is `" ++ @typeName(R) ++
            "`. A cfunction answers a `Value` or a signal, so the type is exactly " ++
            "`Error!Value`: a wider error set is reinterpreted at the call rather " ++
            "than diagnosed here.");
    }

    // **Alignment, which the expected-signature text advertises and nothing
    // checked.** `raise.stored` casts the pointer into the slot the runtime
    // holds a cfunction in, and Janet tags that pointer, so an under-aligned
    // function either survives by an accident of the linker or fails a runtime
    // assertion far from its definition. A function's declared alignment is
    // part of its type, so this is answerable here.
    // A pointer's `alignment` is optional in 0.16 -- `null` means "whatever the
    // pointee's natural alignment is" -- so the pointee answers when it is.
    const given_align: comptime_int = switch (@typeInfo(Given)) {
        .@"fn" => @alignOf(Given),
        .pointer => |ptr| ptr.alignment orelse @alignOf(ptr.child),
        else => unreachable,
    };
    if (given_align < fn_align) {
        @compileError(where ++ "its alignment is " ++ digits(given_align) ++
            ". The runtime tags the low bits of a cfunction's address, so the " ++
            "alignment must be at least `module.fn_align`, which is " ++
            digits(fn_align) ++ ".");
    }
}

/// A small unsigned number as text, for a `@compileError` message.
fn digits(comptime n: comptime_int) []const u8 {
    return std.fmt.comptimePrint("{d}", .{n});
}

/// Define a non-function binding.
pub fn def(env: *Env, comptime name: [:0]const u8, val: Value, comptime doc: ?[:0]const u8) void {
    crossings.janet_def(env, name.ptr, val, if (doc) |d| d.ptr else null);
}

/// Record an abstract type under its name, so the unmarshaller can find it.
///
/// **A type with an `unmarshal` callback is unreachable without this.** A
/// marshalled abstract carries its type's *name* on the wire, and the
/// unmarshaller resolves that name through the runtime's registry; a type that
/// never registers answers `unknown abstract type` however correct its
/// callback is. Call it from `entry`'s `defs`, which is why that takes a
/// raising function.
///
/// Registering the same type twice is allowed. Registering a *different* type
/// under a name already taken raises, because two answers to one name would
/// make a stream ambiguous.
pub fn registerAbstract(at: *const AbstractType) Error!void {
    return crossing(crossings.janet_register_abstract_type(at));
}

// ==========================================================================
// The module entry point
// ==========================================================================

/// The two symbols the loader looks up by name.
///
/// They are written out as two ordinary exports, and the only thing C about
/// them is the names `env.zig` looks up after `dynlib.zig` opens the object.
/// A module says:
///
/// ```zig
/// comptime { module.entry(defs); }
/// ```
///
/// where `defs` is `fn (*module.Env) Error!void`.
///
/// **`defs` may raise, and the loader already tests for it.** `env.zig`'s
/// `cfunNative` -- the `native` cfunction -- wraps its call to `_janet_init`
/// in `raise.crossing`, so a refusal from module initialisation fails that
/// call rather than loading a half-built module. What can refuse is `registerAbstract`, whose name
/// collision is exactly the kind of failure an author wants reported at the
/// load; the runtime's own subsystem initialisers are raising for the same
/// reason. A `defs` with nothing fallible in it still declares the type and
/// simply never returns an error.
pub fn entry(comptime defs: fn (*Env) Error!void) void {
    const Shim = struct {
        fn modConfig() callconv(.c) abi.BuildConfig {
            return .{
                .major = config.version_major,
                .minor = config.version_minor,
                .patch = config.version_patch,
                .bits = constants.JANET_CURRENT_CONFIG_BITS,
            };
        }
        /// The raise flattens here, because the symbol the loader looks up is
        /// `callconv(.c)` and cannot carry an error union. `raise.reported`
        /// records it and `env.zig`'s `raise.crossing` rebuilds it.
        fn modInit(env: *Env) callconv(.c) void {
            return raise.reported(defs(env));
        }
    };
    @export(&Shim.modConfig, .{ .name = "_janet_mod_config" });
    @export(&Shim.modInit, .{ .name = "_janet_init" });
}

// ==========================================================================
// The symbols a module links against
// ==========================================================================
//
// This is the boundary, and it is deliberately short. Every name here is one
// the runtime exports.
//
// They are declared rather than reached through `cabi.zig` because that file
// is the *runtime's* residual seam -- what the runtime still calls through a
// symbol -- which is a different question from what a module is offered.

/// A refusal made by the runtime arrives as a *report* rather than as an
/// error, because the symbol it crossed has a C calling convention and Zig
/// will not put an error union on one. This is where it becomes an error
/// again, at the one boundary that has to convert it.
inline fn crossing(v: anytype) Error!@TypeOf(v) {
    return raise.crossing(v);
}
