//! The interface a native module imports, and the only one it needs.
//!
//! Native modules remain a goal; a C API for writing them does not. Nothing
//! has to keep working that was compiled against Janet's `janet.h`, but people
//! should still be able to write a module in native code, so this is a real
//! interface with real third-party authors rather than an internal detail.
//!
//! ## One import
//!
//! A module writes `@import("janet")` and nothing else. Before this increment
//! `src/zig/native_module.zig` reached for four modules, one of which was the
//! C ABI, and hand-copied `raise.CFunction` and `raise.crossing` because it
//! could not import the file that declares them. The declarations below are a
//! *deliberate* list: what a module author is offered, decided here, rather
//! than whatever the runtime happens to still call through a symbol.
//!
//! ## What a module links against
//!
//! A native module is a shared object the loader opens at run time, so it
//! reaches the runtime through the symbol table. The `extern fn` declarations
//! at the foot of this file are that boundary, and they are the reason this
//! interface can be a small file rather than a second compilation of the
//! runtime: `abstract_type.zig` and `raise.zig` compile *into* the module,
//! and everything they need from the runtime is a symbol.
//!
//! The Zig-side calling convention is `.auto`, which is deterministic for a
//! compiler version and target rather than documented -- `src/zig/interop.zig`
//! has the note. That is the compatibility guarantee this interface makes:
//! **a module is built with the same Zig version as the runtime it loads
//! into.** It is a source interface, not a binary one.
//!
//! ## What is deliberately not here
//!
//! The value representation, the head structs, the collector, the VM. A module
//! reaches Janet's data through the functions below and holds it as an opaque
//! `Value`. `DESIGN.md` section 4 is the decision and its reason: private to
//! public is available at any time and breaks nobody; public to private breaks
//! every module that exists.

const std = @import("std");
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const config = @import("config");
const raise = @import("raise");
const abstract_type = @import("abstract_type");

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

/// An environment table, which is what a module's entry point is handed.
pub const Env = types.JanetTable;

/// A module's cfunction: arguments in, a value or a signal out.
pub const CFunction = raise.CFunction;

/// An abstract type's dispatch description, and the constructor that builds
/// one from callbacks over `*T`. `DESIGN.md` section 5.
pub const AbstractType = abstract_type.AbstractType;
pub const define = abstract_type.define;

/// One registration row. `DESIGN.md` section 6: one struct, five fields, and
/// the three a build may omit are defaulted.
pub const Reg = types.Reg;

/// The alignment every cfunction must be declared with.
///
/// Under 64-bit nanboxing with a nonzero pointer shift, wrapping a cfunction
/// reuses the low bits of its pointer and registration asserts they are clear
/// -- with `janet abort`, at load time, naming the module. `16` satisfies
/// every shift the build accepts, and over-aligning costs padding measured in
/// bytes. Write `fn myFn(argv: []Value) align(module.fn_align) Error!Value`.
pub const fn_align = 16;

// ==========================================================================
// Raising
// ==========================================================================

/// Refuse, with a message. The signal and payload go into the runtime's state
/// and `error.JanetSignal` says so.
pub const panic = raise.panic;

// ==========================================================================
// Arguments
// ==========================================================================

/// Exactly `n` arguments, or a refusal naming the arity.
pub fn fixarity(argv: []const Value, n: i32) Error!void {
    return crossing(janet_fixarity(@intCast(argv.len), n));
}

/// Between `lo` and `hi`, with `-1` for "no bound".
pub fn arity(argv: []const Value, lo: i32, hi: i32) Error!void {
    return crossing(janet_arity(@intCast(argv.len), lo, hi));
}

pub fn getNumber(argv: []const Value, n: i32) Error!f64 {
    return crossing(janet_getnumber(argv.ptr, n));
}

pub fn getInteger(argv: []const Value, n: i32) Error!i32 {
    return crossing(janet_getinteger(argv.ptr, n));
}

/// An argument of this abstract type, as a `*T`.
///
/// The typed half of `DESIGN.md` section 5: the runtime checks the type and
/// this returns the payload already cast, so a module author's first line is
/// not an unchecked `@ptrCast` the runtime cannot diagnose.
pub fn getAbstract(comptime T: type, argv: []const Value, n: i32, at: *const AbstractType) Error!*T {
    const p = try crossing(janet_getabstract(argv.ptr, n, at));
    return @ptrCast(@alignCast(p.?));
}

/// The size of a value the runtime treats as a count.
pub fn getSize(argv: []const Value, n: i32) Error!usize {
    return crossing(janet_getsize(argv.ptr, n));
}

// ==========================================================================
// Values
// ==========================================================================

pub const number = janet_wrap_number;
pub const nil = janet_wrap_nil;

/// Wrap an abstract's payload as a value.
pub fn abstract(p: *anyopaque) Value {
    return janet_wrap_abstract(p);
}

/// Whether a value is an integer the runtime can hand back as `i32`.
pub fn isInteger(v: Value) bool {
    return janet_checkint(v) != 0;
}

// The two below cross the symbol table, where the tag is the C `c_uint` it
// has always been; `repr.Tag` is the runtime's spelling and does not travel.
// A module author sees neither -- they see `bool`.

/// Whether a value is a keyword, which is what a method lookup is keyed on.
pub fn isKeyword(v: Value) bool {
    return janet_checktype(v, @intFromEnum(repr.Tag.keyword)) != 0;
}

/// Whether a value is a number.
pub fn isNumber(v: Value) bool {
    return janet_checktype(v, @intFromEnum(repr.Tag.number)) != 0;
}

pub const toInteger = janet_unwrap_integer;
pub const toNumber = janet_unwrap_number;

// ==========================================================================
// Methods
// ==========================================================================

/// One row of a method table: a name and a cfunction, exactly as a
/// registration row is a name and a cfunction. It is its own type because a
/// method table is not a registration -- `DESIGN.md` section 6 keeps them
/// apart for that reason.
pub const Method = extern struct {
    name: ?[*:0]const u8 = null,
    cfun: ?CFunction = null,
};

/// Answer a `:keyword` lookup out of a method table.
///
/// This is what an abstract type's `get` callback delegates to when the key is
/// a keyword, which is how `(:scale a 5)` finds `scale`.
pub fn getMethod(key: Value, methods: []const Method, out: *Value) Error!bool {
    const table = terminate(Method, methods);
    return try crossing(janet_getmethod(janet_unwrap_keyword(key), @ptrCast(&table), out)) != 0;
}

/// The next method name after `key`, or nil at the end -- an abstract type's
/// `next` callback over the same table.
pub fn nextMethod(methods: []const Method, key: Value) Error!Value {
    const table = terminate(Method, methods);
    return crossing(janet_nextmethod(@ptrCast(&table), key));
}

// ==========================================================================
// Allocating an abstract
// ==========================================================================

/// Allocate an abstract of this type, as a `*T`.
///
/// `size` is the whole allocation and defaults to `@sizeOf(T)`. It is a
/// parameter because `T` is the *header* type: an abstract may carry trailing
/// bytes, which is the shape `DESIGN.md` section 3 describes and what
/// `janet_address_type`, `janet_peg_type` and `janet_stream_type` all do.
pub fn new(comptime T: type, at: *const AbstractType, size: ?usize) *T {
    const p = janet_abstract(at, size orelse @sizeOf(T));
    return @ptrCast(@alignCast(p.?));
}

/// The runtime's allocator, for memory an abstract owns and its `gc` frees.
pub const alloc = janet_calloc;
pub const free = janet_free;

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
    janet_cfuns_ext(env, prefix, @ptrCast(&terminated));
}

/// The most rows one table may hold, terminator excluded.
///
/// **It is the buffer's length minus the terminator, and it says so.** The
/// prose said 128 while `rows.len < 128` permitted 127; naming the bound once
/// and deriving both from it is what stops the two disagreeing again.
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
/// `PLAN.md`'s "Target" is the reason this is worth code: a decision about a
/// callback type is a decision about somebody else's compile error, so the
/// truth goes in the type where it can be diagnosed early. Without this the
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
        // whose payload is `Value` let `anyerror!Value` through, and the
        // runtime then invokes it through the narrower `Error!Value` -- so the
        // author's broader error set was silently reinterpreted rather than
        // diagnosed at the definition, which is the one place it could be.
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
    janet_def(env, name.ptr, val, if (doc) |d| d.ptr else null);
}

// ==========================================================================
// The module entry point
// ==========================================================================

/// The two symbols the loader looks up by name.
///
/// `JANET_MODULE_ENTRY` is a preprocessor facility in C and there is nothing
/// to translate; written out it is two exports, and neither has anything to do
/// with C beyond the names the loader searches for. A module says:
///
/// ```zig
/// comptime { module.entry(defs); }
/// ```
///
/// where `defs` is `fn (*module.Env) void`.
pub fn entry(comptime defs: fn (*Env) void) void {
    const Shim = struct {
        fn modConfig() callconv(.c) types.JanetBuildConfig {
            return .{
                .major = config.version_major,
                .minor = config.version_minor,
                .patch = config.version_patch,
                .bits = constants.JANET_CURRENT_CONFIG_BITS,
            };
        }
        fn modInit(env: *Env) callconv(.c) void {
            defs(env);
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

extern fn janet_fixarity(argc: i32, fix: i32) void;
extern fn janet_arity(argc: i32, min: i32, max: i32) void;
extern fn janet_getnumber(argv: [*]const Value, n: i32) f64;
extern fn janet_getinteger(argv: [*]const Value, n: i32) i32;
extern fn janet_getabstract(argv: [*]const Value, n: i32, at: *const AbstractType) ?*anyopaque;
extern fn janet_wrap_number(x: f64) Value;
extern fn janet_wrap_nil() Value;
extern fn janet_wrap_abstract(p: *anyopaque) Value;
extern fn janet_abstract(at: *const AbstractType, size: usize) ?*anyopaque;
extern fn janet_calloc(n: usize, size: usize) ?*anyopaque;
extern fn janet_free(p: ?*anyopaque) void;
extern fn janet_cfuns_ext(env: *Env, prefix: ?[*:0]const u8, table: [*]const Reg) void;
extern fn janet_def(env: *Env, name: [*:0]const u8, val: Value, doc: ?[*:0]const u8) void;
extern fn janet_getsize(argv: [*]const Value, n: i32) usize;
extern fn janet_checkint(x: Value) c_int;
extern fn janet_checktype(x: Value, t: c_uint) c_int;
extern fn janet_unwrap_integer(x: Value) i32;
extern fn janet_unwrap_number(x: Value) f64;
extern fn janet_unwrap_keyword(x: Value) [*:0]const u8;
extern fn janet_getmethod(method: [*:0]const u8, methods: [*]const Method, out: *Value) c_int;
extern fn janet_nextmethod(methods: [*]const Method, key: Value) Value;

/// A refusal made by the runtime arrives as a *report* rather than as an
/// error, because the symbol it crossed has a C calling convention and Zig
/// will not put an error union on one. This is where it becomes an error
/// again, at the one boundary that has to convert it.
inline fn crossing(v: anytype) Error!@TypeOf(v) {
    return raise.crossing(v);
}
