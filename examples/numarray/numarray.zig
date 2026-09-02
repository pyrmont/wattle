//! A native module, written in Zig against the published interface.
//!
//! This is `numarray.c` — the sample that shipped with Janet — brought over
//! to the interface `DESIGN.md` sections 5 and 6 decided on. It is here to be
//! *read*: everything a module author needs is `@import("janet")`, and the
//! two things this file no longer contains are the point.
//!
//! **The cast is gone.** The C original opens every callback with
//!
//! ```c
//! static int num_array_gc(void *p, size_t s) {
//!     num_array *array = (num_array *)p;   /* nothing checks this */
//! ```
//!
//! and nothing in the language or the runtime can tell you it is wrong.
//! `janet.define(NumArray, .{ ... })` takes the payload type once and
//! generates the erased dispatch, so a callback is written over `*NumArray`
//! and a mistake is a compile error at the callback's own definition. Break
//! one on purpose and `zig build module-errors` shows what an author sees.
//!
//! **The `JANET_ATEND_PUT` chain is gone.** C needs sixteen macros to let an
//! author fill in the first few fields of a positional initializer without a
//! warning; Zig's default field values are that mechanism, so a declaration
//! names the fields it sets and a callback added later breaks nobody's source.
//!
//! Built by `build.zig` and loaded by `examples/numarray/test/numarray.janet`,
//! which `zig build test` runs — because "a sample module compiles and loads"
//! is a claim, and a sample nothing executes is a file rather than an example.

const janet = @import("janet");

/// The payload. `janet.define` is told about this type once, below, and every
/// callback is written over it.
const NumArray = struct {
    data: [*]f64,
    size: usize,

    fn slice(self: *NumArray) []f64 {
        return self.data[0..self.size];
    }
};

// ---------------------------------------------------------- the callbacks

/// A finalizer cannot raise and has nothing to report, and the interface says
/// both in its type: this returns `void`. `DESIGN.md` section 5 has the reason
/// — a finalizer runs mid-sweep on an object that is already unreachable, so
/// there is no scope above it and nothing to retry.
fn numArrayGc(self: *NumArray, _: usize) void {
    janet.free(self.data);
}

fn numArrayGet(self: *NumArray, key: janet.Value) janet.Error!?janet.Value {
    if (janet.isKeyword(key)) return janet.getMethod(key, &methods);
    if (!janet.isInteger(key)) return janet.panic("expected integer key");
    // A negative index is out of range, not index zero. See `inRange`.
    const index = inRange(self, janet.toInteger(key)) orelse return null;
    return janet.number(self.slice()[index]);
}

/// `i` as an index into `self`, or null if it addresses no element.
///
/// **A negative index is a miss, and this is the one place that is decided.**
/// The C original wrote `(size_t) i`, so -1 became a very large index and fell
/// out of the `>= size` test on its own -- a lookup failure for `get` and a
/// silently ignored write for `put`. Clamping with `@max(0, i)` instead, which
/// is the obvious Zig transliteration, quietly turns `(a -1)` into `(a 0)` and
/// `(put a -1 x)` into a write over element zero. That is a worse answer than
/// either: it is wrong data rather than a refusal.
///
/// So the conversion is written out. The behaviour a Janet program sees is the
/// C original's exactly, and it no longer depends on an accident of unsigned
/// wraparound.
fn inRange(self: *const NumArray, i: i32) ?usize {
    if (i < 0) return null;
    const index: usize = @intCast(i);
    return if (index < self.size) index else null;
}

/// `put` runs inside an interpreter frame with a real scope above it, so it
/// may raise and its type says that too.
fn numArrayPut(self: *NumArray, key: janet.Value, value: janet.Value) janet.Error!void {
    if (!janet.isInteger(key)) return janet.panic("expected integer key");
    if (!janet.isNumber(value)) return janet.panic("expected number value");
    // Out of range is ignored rather than refused, which is the C original's
    // choice and is kept; `inRange` has the negative half.
    const index = inRange(self, janet.toInteger(key)) orelse return;
    self.slice()[index] = janet.toNumber(value);
}

/// The abstract type: one declaration, one payload type, the callbacks it
/// actually has.
const num_array_type = janet.define(NumArray, .{
    .name = "numarray",
    .gc = numArrayGc,
    .get = numArrayGet,
    .put = numArrayPut,
});

// --------------------------------------------------------- the cfunctions

fn new(argv: []janet.Value) align(janet.fn_align) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    // **A negative size is refused, and that is a deliberate difference.** The
    // C original converted it to `size_t` as well, so `(numarray/new -1)` asked
    // `janet_calloc` for about 147 exabytes and died in the out-of-memory exit
    // -- a real outcome, but not one worth copying into the module an author
    // reads first. Clamping to zero, the other obvious choice, hands back an
    // empty array as though the argument had been fine. Refusing says what
    // happened, and a cfunction may refuse.
    const requested = try janet.getInteger(argv, 0);
    if (requested < 0) return janet.panic("expected a non-negative size");
    const size: usize = @intCast(requested);
    // **The payload is allocated before the abstract, because this one can
    // refuse.** `janet.new` returns a block that is already on the collector's
    // heap list and already tagged as an abstract, so from that moment a sweep
    // may run this type's `gc` over it. Allocating second and raising on
    // failure would leave exactly that block unreachable with `data` never
    // written, and the finalizer would free a wild pointer. Allocating first
    // puts nothing between `new` and the assignment below.
    const data = janet.alloc(f64, size) orelse return janet.panic("out of memory");
    const array = janet.new(NumArray, &num_array_type, null);
    array.* = .{ .data = data.ptr, .size = size };
    return janet.abstract(array);
}

fn scale(argv: []janet.Value) align(janet.fn_align) janet.Error!janet.Value {
    try janet.fixarity(argv, 2);
    const array = try janet.getAbstract(NumArray, argv, 0, &num_array_type);
    const factor = try janet.getNumber(argv, 1);
    for (array.slice()) |*cell| cell.* *= factor;
    return argv[0];
}

fn sum(argv: []janet.Value) align(janet.fn_align) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    const array = try janet.getAbstract(NumArray, argv, 0, &num_array_type);
    var total: f64 = 0;
    for (array.slice()) |cell| total += cell;
    return janet.number(total);
}

fn length(argv: []janet.Value) align(janet.fn_align) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    const array = try janet.getAbstract(NumArray, argv, 0, &num_array_type);
    return janet.number(@floatFromInt(array.size));
}

const methods = [_]janet.Method{
    .{ .name = "scale", .cfun = &scale },
    .{ .name = "sum", .cfun = &sum },
    .{ .name = "length", .cfun = &length },
};

// -------------------------------------------------------------- the module

fn defs(env: *janet.Env) void {
    janet.cfuns(env, "numarray", &.{
        janet.reg("new", &new, "(numarray/new size)\n\nCreate new numarray"),
        janet.reg("scale", &scale, "(numarray/scale numarray factor)\n\nScale numarray by factor"),
        janet.reg("sum", &sum, "(numarray/sum numarray)\n\nSum numarray"),
        janet.reg("length", &length, "(numarray/length numarray)\n\nLength of numarray"),
    });
}

comptime {
    janet.entry(defs);
}
