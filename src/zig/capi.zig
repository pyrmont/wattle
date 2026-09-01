//! The published surface, in one file.
//!
//! **What is published is what a native module reaches by symbol**, and
//! nothing else. `DESIGN.md` section 11 is the decision: the runtime runs
//! Janet code, a native module is written in Zig and loads through
//! `module.zig`, and there is no C API. So this file is the other side of
//! `module.zig`'s `extern fn` list plus the two `janet_zig_*` entry points
//! `raise.zig` reaches when it is compiled *into* a module rather than into
//! the runtime.
//!
//! Everything else a file needs from a neighbour it reaches by `@import`,
//! which keeps the error union, allows inlining, and is checked.
//!
//! **Why the entry points are separate from the definitions.** A slice has no
//! guaranteed in-memory representation, so Zig refuses one in a `callconv(.c)`
//! signature, and `export fn` forces that calling convention. A runtime
//! function that published its own symbol could not take a slice.
//!
//! **Two populations.** An entry point below calls ordinary Zig. The rest are
//! `@export`ed directly, because the thing they name is *already* a dedicated
//! C-ABI shim with no other caller -- `args.zig`'s generated getters, and the
//! `abi` namespace in `value/helpers/wrap.zig`. Those have no second hat to
//! take off, so each carries its signature in the `publish(...)` call.

const repr = @import("repr");
const strings = @import("value/strings.zig");
const abi = @import("abi");
const method_type = @import("method_type.zig");
const tables = @import("value/tables.zig");

/// The runtime, in a namespace: a parameter name copied from a
/// definition cannot shadow an import that is not at this level.
const impl = struct {
    pub const args = @import("args.zig");
    pub const registry = @import("registry.zig");
    pub const fatal = @import("fatal.zig");
    pub const signal = @import("signal.zig");
    pub const utils = @import("utils.zig");
    pub const value_abstracts = @import("value/abstracts.zig");
    pub const value_helpers_wrap = @import("value/helpers/wrap.zig");
    pub const value_strings = @import("value/strings.zig");
};

/// Export a target directly, stating the signature the symbol publishes.
///
/// **One declaration, so the symbol cannot drift from the assertion.** Taking
/// the pointer rather than the value is what lets one call do both: `@export`
/// needs a pointer to a container-level declaration, and `ptr.*` recovers the
/// type to compare.
fn publish(comptime name: []const u8, comptime ptr: anytype, comptime Signature: type) void {
    if (@TypeOf(ptr.*) != Signature) @compileError(
        "`" ++ name ++ "` publishes `" ++ @typeName(@TypeOf(ptr.*)) ++
            "` but this manifest states `" ++ @typeName(Signature) ++ "`",
    );
    @export(ptr, .{ .name = name });
}

// ==========================================================================
// The entry points
// ==========================================================================

// args.zig
//
pub fn janet_checkint(x: repr.Value) callconv(.c) c_int {
    return @intFromBool(impl.args.checkint(x));
}
pub fn janet_getmethod(method: [*:0]const u8, methods: [*]const method_type.CMethod, out: *repr.Value) callconv(.c) c_int {
    return impl.args.getmethod(method, methods, out);
}
pub fn janet_nextmethod(methods: [*]const method_type.CMethod, key: repr.Value) callconv(.c) repr.Value {
    return impl.args.nextmethod(methods, key);
}

// registry.zig
//
/// Walk a null-name-terminated C table into the installer.
///
/// This is the sentinel adapter `DESIGN.md` section 6 keeps: a boundary that
/// actually receives a table from outside. Internally a registration table is
/// a slice and its length is known at comptime.
fn installSentinel(
    env: ?*tables.Table,
    regprefix: ?[*:0]const u8,
    registrations: [*]const abi.Reg,
) void {
    var it = impl.registry.Installer.init(env, regprefix, false);
    defer it.deinit();
    var row = registrations;
    while (row[0].name != null) : (row += 1) it.put(row[0]);
}

pub fn janet_cfuns_ext(env: ?*tables.Table, regprefix: ?[*:0]const u8, registrations: [*]const abi.Reg) callconv(.c) void {
    installSentinel(env, regprefix, registrations);
}
pub fn janet_def(env: *tables.Table, name: [*:0]const u8, val: repr.Value, doc: ?[*:0]const u8) callconv(.c) void {
    return impl.registry.def(env, name, val, doc);
}

// signal.zig
//
pub fn janet_zig_c_raise_take() callconv(.c) c_int {
    return @intFromBool(impl.signal.zigCRaiseTake());
}
pub fn janet_zig_c_raise_record() callconv(.c) void {
    return impl.signal.zigCRaiseRecord();
}
pub fn janet_zig_fatal(message: [*:0]const u8) callconv(.c) noreturn {
    return impl.fatal.fatal(message);
}
pub fn janet_zig_signal_record(sig: c_uint, message: repr.Value) callconv(.c) void {
    return impl.signal.zigSignalRecord(abi.Signal.fromWire(sig), message);
}

// utils.zig
//
pub fn janet_calloc(nmemb: usize, size: usize) callconv(.c) ?*anyopaque {
    return impl.utils.calloc(nmemb, size);
}
pub fn janet_free(ptr: ?*anyopaque) callconv(.c) void {
    return impl.utils.free(ptr);
}

// value/
//
pub fn janet_abstract(atype: *const abi.AbstractType, size: usize) callconv(.c) ?*anyopaque {
    return impl.value_abstracts.newBytes(atype, size);
}
pub fn janet_cstring(str: [*:0]const u8) callconv(.c) [*:0]const u8 {
    return impl.value_strings.cstring(str);
}
pub fn janet_checktype(x: repr.Value, t: c_uint) callconv(.c) c_int {
    if (t >= repr.tag_count) return 0;
    return @intFromBool(repr.checkType(x, @enumFromInt(t)));
}
pub fn janet_unwrap_integer(x: repr.Value) callconv(.c) i32 {
    return impl.value_helpers_wrap.toIntegerAbi(x);
}
pub fn janet_unwrap_keyword(x: repr.Value) callconv(.c) strings.Keyword {
    return impl.value_helpers_wrap.toKeyword(x);
}
pub fn janet_unwrap_number(x: repr.Value) callconv(.c) f64 {
    return impl.value_helpers_wrap.toNumber(x);
}

// ==========================================================================
// The manifest
// ==========================================================================

comptime {
    @export(&janet_checkint, .{ .name = "janet_checkint" });
    @export(&janet_getmethod, .{ .name = "janet_getmethod" });
    @export(&janet_nextmethod, .{ .name = "janet_nextmethod" });
    @export(&janet_cfuns_ext, .{ .name = "janet_cfuns_ext" });
    @export(&janet_def, .{ .name = "janet_def" });
    @export(&janet_zig_c_raise_take, .{ .name = "janet_zig_c_raise_take" });
    @export(&janet_zig_c_raise_record, .{ .name = "janet_zig_c_raise_record" });
    @export(&janet_zig_fatal, .{ .name = "janet_zig_fatal" });
    @export(&janet_zig_signal_record, .{ .name = "janet_zig_signal_record" });
    @export(&janet_calloc, .{ .name = "janet_calloc" });
    @export(&janet_free, .{ .name = "janet_free" });
    @export(&janet_abstract, .{ .name = "janet_abstract" });
    @export(&janet_cstring, .{ .name = "janet_cstring" });
    @export(&janet_checktype, .{ .name = "janet_checktype" });
    @export(&janet_unwrap_integer, .{ .name = "janet_unwrap_integer" });
    @export(&janet_unwrap_keyword, .{ .name = "janet_unwrap_keyword" });
    @export(&janet_unwrap_number, .{ .name = "janet_unwrap_number" });

    publish("janet_fixarity", &impl.args.fixArityAbi, fn (i32, i32) callconv(.c) void);
    publish("janet_arity", &impl.args.checkArityAbi, fn (i32, i32, i32) callconv(.c) void);
    publish("janet_getnumber", &impl.args.GetNumber.abi, fn ([*]const repr.Value, i32) callconv(.c) f64);
    publish("janet_getinteger", &impl.args.GetInteger.abi, fn ([*]const repr.Value, i32) callconv(.c) i32);
    publish("janet_getsize", &impl.args.GetSize.abi, fn ([*]const repr.Value, i32) callconv(.c) usize);
    publish("janet_getabstract", &impl.args.getAbstractAbi, fn ([*]const repr.Value, i32, *const abi.AbstractType) callconv(.c) ?*anyopaque);
    publish("janet_wrap_nil", &impl.value_helpers_wrap.abi.fromNil, fn () callconv(.c) repr.Value);
    publish("janet_wrap_number", &impl.value_helpers_wrap.abi.fromNumber, fn (f64) callconv(.c) repr.Value);
    publish("janet_wrap_string", &impl.value_helpers_wrap.abi.fromString, fn ([*:0]const u8) callconv(.c) repr.Value);
    publish("janet_wrap_abstract", &impl.value_helpers_wrap.abi.fromAbstract, fn (?*anyopaque) callconv(.c) repr.Value);
}
