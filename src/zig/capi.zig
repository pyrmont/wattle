//! The C ABI, in one file.
//!
//! Every symbol a C caller can reach is an entry point here calling ordinary
//! Zig, and `@export` appears nowhere else under `src/zig` -- so the export
//! inventory is a read of this file rather than a checked-in list something
//! has to keep in step.
//!
//! **Why the entry points are separate from the definitions.**  A slice has no
//! guaranteed in-memory representation, so Zig refuses one in a `callconv(.c)`
//! signature, and `export fn` forces that calling convention.  A runtime
//! function that published its own symbol could not take a slice.
//! `DESIGN.md` section 9 has the measurement: 890 of the 1,981 `[*c]` sites
//! the tree once had were held there.
//!
//! **The gating is this file's too.**  A file is analysed when something
//! *references* one of its declarations, so the condition around an `@export`
//! below is what decides whether the subsystem behind it is compiled at all.
//! The bare `@import`s are inert on their own.  The conditions are
//! `root.zig`'s comptime block and the guards the sources already carried,
//! spelled against `options` and `config` rather than against a file-local
//! `const`.
//!
//! **Two populations, and the second is not a shortcut.**  423 symbols get an
//! entry point that calls an ordinary Zig function.  The other 110 are
//! `@export`ed directly, because the thing they name is *already* a dedicated
//! C-ABI shim with no other caller -- `raise.panicking(f).abi`, or one of
//! `args.zig`'s generated getters.  Those have no second hat to take off, so
//! each carries a `publishes(...)` assertion at the foot of this file instead.

const builtin = @import("builtin");
const options = @import("options");
const config = @import("config");
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const raise = @import("raise");

const is_windows = builtin.os.tag == .windows;
/// The runtime, in a namespace: a parameter name copied from a
/// definition cannot shadow an import that is not at this level.
const impl = struct {
    pub const args = @import("args.zig");
    pub const bytecode = @import("bytecode.zig");
    pub const bytecode_disasm = @import("bytecode/disasm.zig");
    pub const bytecode_verify = @import("bytecode/verify.zig");
    pub const compiler = @import("compiler.zig");
    pub const compiler_emit = @import("compiler/emit.zig");
    pub const compiler_optimize = @import("compiler/optimize.zig");
    pub const compiler_regalloc = @import("compiler/regalloc.zig");
    pub const compiler_specials = @import("compiler/specials.zig");
    pub const debug = @import("debug.zig");
    pub const dynlib = @import("dynlib.zig");
    pub const env = @import("env.zig");
    pub const ev = @import("ev.zig");
    pub const ev_backend = @import("ev/backend.zig");
    pub const ev_channel = @import("ev/channel.zig");
    pub const ev_locks = @import("ev/locks.zig");
    pub const ev_stream = @import("ev/stream.zig");
    pub const fatal = @import("fatal.zig");
    pub const ffi = @import("ffi.zig");
    pub const filewatch = @import("filewatch.zig");
    pub const gc = @import("gc.zig");
    pub const gc_mark = @import("gc/mark.zig");
    pub const gc_sweep = @import("gc/sweep.zig");
    pub const io = @import("io.zig");
    pub const marsh = @import("marsh.zig");
    pub const math = @import("math.zig");
    pub const net = @import("net.zig");
    pub const os = @import("os.zig");
    pub const os_fs = @import("os/fs.zig");
    pub const os_fs_stat = @import("os/fs/stat.zig");
    pub const parser = @import("parser.zig");
    pub const peg = @import("peg.zig");
    pub const pp = @import("pp.zig");
    pub const pp_format = @import("pp/format.zig");
    pub const pp_pretty = @import("pp/pretty.zig");
    pub const registry = @import("registry.zig");
    pub const scan = @import("scan.zig");
    pub const signal = @import("signal.zig");
    pub const stretchy = @import("stretchy.zig");
    pub const utils = @import("utils.zig");
    pub const value = @import("value.zig");
    pub const value_abstracts = @import("value/abstracts.zig");
    pub const value_arrays = @import("value/arrays.zig");
    pub const value_buffers = @import("value/buffers.zig");
    pub const value_fibers = @import("value/fibers.zig");
    pub const value_functions = @import("value/functions.zig");
    pub const value_helpers_access = @import("value/helpers/access.zig");
    pub const value_helpers_order = @import("value/helpers/order.zig");
    pub const value_helpers_wrap = @import("value/helpers/wrap.zig");
    pub const value_ints = @import("value/ints.zig");
    pub const value_strings = @import("value/strings.zig");
    pub const value_structs = @import("value/structs.zig");
    pub const value_symbols = @import("value/symbols.zig");
    pub const value_tables = @import("value/tables.zig");
    pub const value_tuples = @import("value/tuples.zig");
    pub const vm = @import("vm.zig");
    pub const vm_entry = @import("vm/entry.zig");
    pub const vm_lifecycle = @import("vm/lifecycle.zig");
};

// args.zig
//
pub fn janet_panic_type(x: repr.Value, n: i32, expected: c_int) callconv(.c) void {
    return impl.args.panicTypeAbi(x, n, expected);
}
pub fn janet_panic_abstract(x: repr.Value, n: i32, at: *const types.AbstractType) callconv(.c) void {
    return impl.args.panicAbstractAbi(x, n, at);
}
pub fn janet_bytes_view(str: repr.Value, data: *?[*]const u8, len: *i32) callconv(.c) c_int {
    return impl.args.bytesView(str, data, len);
}
pub fn janet_checkabstract(x: repr.Value, at: *const types.AbstractType) callconv(.c) ?*anyopaque {
    return impl.args.checkabstract(x, at);
}
pub fn janet_checkfloat(x: repr.Value) callconv(.c) c_int {
    return impl.args.checkfloat(x);
}
pub fn janet_checkint(x: repr.Value) callconv(.c) c_int {
    return impl.args.checkint(x);
}
pub fn janet_checkint16(x: repr.Value) callconv(.c) c_int {
    return impl.args.checkint16(x);
}
pub fn janet_checkint64(x: repr.Value) callconv(.c) c_int {
    return impl.args.checkint64(x);
}
pub fn janet_checkint8(x: repr.Value) callconv(.c) c_int {
    return impl.args.checkint8(x);
}
pub fn janet_checksize(x: repr.Value) callconv(.c) c_int {
    return impl.args.checksize(x);
}
pub fn janet_checkuint(x: repr.Value) callconv(.c) c_int {
    return impl.args.checkuint(x);
}
pub fn janet_checkuint16(x: repr.Value) callconv(.c) c_int {
    return impl.args.checkuint16(x);
}
pub fn janet_checkuint64(x: repr.Value) callconv(.c) c_int {
    return impl.args.checkuint64(x);
}
pub fn janet_checkuint8(x: repr.Value) callconv(.c) c_int {
    return impl.args.checkuint8(x);
}
pub fn janet_dictionary_view(tab: repr.Value, data: *?[*]const types.JanetKV, len: *i32, cap: *i32) callconv(.c) c_int {
    return impl.args.dictionaryView(tab, data, len, cap);
}
pub fn janet_getmethod(method: [*:0]const u8, methods: [*]const types.JanetMethod, out: *repr.Value) callconv(.c) c_int {
    return impl.args.getmethod(method, methods, out);
}
pub fn janet_indexed_view(seq: repr.Value, data: *?[*]const repr.Value, len: *i32) callconv(.c) c_int {
    return impl.args.indexedView(seq, data, len);
}
pub fn janet_keyeq(x: repr.Value, cstring: [*:0]const u8) callconv(.c) c_int {
    return impl.args.keyeq(x, cstring);
}
pub fn janet_nextmethod(methods: [*]const types.JanetMethod, key: repr.Value) callconv(.c) repr.Value {
    return impl.args.nextmethod(methods, key);
}
pub fn janet_streq(x: repr.Value, cstring: [*:0]const u8) callconv(.c) c_int {
    return impl.args.streq(x, cstring);
}
pub fn janet_symeq(x: repr.Value, cstring: [*:0]const u8) callconv(.c) c_int {
    return impl.args.symeq(x, cstring);
}
/// Export a target directly, stating the signature the symbol publishes.
///
/// **One declaration, so the symbol cannot drift from the assertion.** These
/// were two: an `@export` near the top of the file and a `publishes` six
/// hundred lines below it. Changing the target of the `@export` without
/// changing the assertion left a build that still passed, with the assertion
/// certifying one function while the symbol published another; a wrong *name*
/// went the same way, since neither statement mentioned the other.
///
/// Taking the pointer rather than the value is what lets one call do both:
/// `@export` needs a pointer to a container-level declaration, and `ptr.*`
/// recovers the type to compare. It works for a data export too -- the three
/// name tables state an array type here rather than a function type.
fn publish(comptime name: []const u8, comptime ptr: anytype, comptime Signature: type) void {
    if (@TypeOf(ptr.*) != Signature) @compileError(
        "`" ++ name ++ "` publishes `" ++ @typeName(@TypeOf(ptr.*)) ++
            "` but this manifest states `" ++ @typeName(Signature) ++ "`",
    );
    @export(ptr, .{ .name = name });
}

/// `publish` for a symbol the shared library does not offer: an entry point no
/// native module calls, which another translation unit in this build does.
fn publishHidden(comptime name: []const u8, comptime ptr: anytype, comptime Signature: type) void {
    if (@TypeOf(ptr.*) != Signature) @compileError(
        "`" ++ name ++ "` publishes `" ++ @typeName(@TypeOf(ptr.*)) ++
            "` but this manifest states `" ++ @typeName(Signature) ++ "`",
    );
    @export(ptr, .{ .name = name, .visibility = .hidden });
}

comptime {
    if (options.args) {
        @export(&janet_panic_type, .{ .name = "janet_panic_type" });
        @export(&janet_panic_abstract, .{ .name = "janet_panic_abstract" });
        publish("janet_fixarity", &impl.args.fixArityAbi, fn (i32, i32) callconv(.c) void);
        publish("janet_arity", &impl.args.checkArityAbi, fn (i32, i32, i32) callconv(.c) void);
        publish("janet_getnumber", &impl.args.GetNumber.abi, fn ([*]const repr.Value, i32) callconv(.c) f64);
        publish("janet_getarray", &impl.args.GetArray.abi, fn ([*]const repr.Value, i32) callconv(.c) *types.JanetArray);
        publish("janet_gettuple", &impl.args.GetTuple.abi, fn ([*]const repr.Value, i32) callconv(.c) [*]const repr.Value);
        publish("janet_gettable", &impl.args.GetTable.abi, fn ([*]const repr.Value, i32) callconv(.c) *types.JanetTable);
        publish("janet_getstruct", &impl.args.GetStruct.abi, fn ([*]const repr.Value, i32) callconv(.c) [*]const types.JanetKV);
        publish("janet_getstring", &impl.args.GetString.abi, fn ([*]const repr.Value, i32) callconv(.c) [*:0]const u8);
        publish("janet_getkeyword", &impl.args.GetKeyword.abi, fn ([*]const repr.Value, i32) callconv(.c) [*:0]const u8);
        publish("janet_getsymbol", &impl.args.GetSymbol.abi, fn ([*]const repr.Value, i32) callconv(.c) [*:0]const u8);
        publish("janet_getbuffer", &impl.args.GetBuffer.abi, fn ([*]const repr.Value, i32) callconv(.c) *types.JanetBuffer);
        publish("janet_getfiber", &impl.args.GetFiber.abi, fn ([*]const repr.Value, i32) callconv(.c) *types.JanetFiber);
        publish("janet_getfunction", &impl.args.GetFunction.abi, fn ([*]const repr.Value, i32) callconv(.c) *types.JanetFunction);
        publish("janet_getcfunction", &impl.args.GetCFunction.abi, fn ([*]const repr.Value, i32) callconv(.c) types.JanetCFunction);
        publish("janet_getboolean", &impl.args.GetBoolean.abi, fn ([*]const repr.Value, i32) callconv(.c) c_int);
        publish("janet_getpointer", &impl.args.GetPointer.abi, fn ([*]const repr.Value, i32) callconv(.c) ?*anyopaque);
        publish("janet_optnumber", &impl.args.Opt(impl.args.GetNumber).abi, fn ([*]const repr.Value, i32, i32, f64) callconv(.c) f64);
        publish("janet_opttuple", &impl.args.Opt(impl.args.GetTuple).abi, fn ([*]const repr.Value, i32, i32, ?[*]const repr.Value) callconv(.c) ?[*]const repr.Value);
        publish("janet_optstruct", &impl.args.Opt(impl.args.GetStruct).abi, fn ([*]const repr.Value, i32, i32, ?[*]const types.JanetKV) callconv(.c) ?[*]const types.JanetKV);
        publish("janet_optstring", &impl.args.Opt(impl.args.GetString).abi, fn ([*]const repr.Value, i32, i32, ?[*:0]const u8) callconv(.c) ?[*:0]const u8);
        publish("janet_optkeyword", &impl.args.Opt(impl.args.GetKeyword).abi, fn ([*]const repr.Value, i32, i32, ?[*:0]const u8) callconv(.c) ?[*:0]const u8);
        publish("janet_optsymbol", &impl.args.Opt(impl.args.GetSymbol).abi, fn ([*]const repr.Value, i32, i32, ?[*:0]const u8) callconv(.c) ?[*:0]const u8);
        publish("janet_optfiber", &impl.args.Opt(impl.args.GetFiber).abi, fn ([*]const repr.Value, i32, i32, ?*types.JanetFiber) callconv(.c) ?*types.JanetFiber);
        publish("janet_optfunction", &impl.args.Opt(impl.args.GetFunction).abi, fn ([*]const repr.Value, i32, i32, ?*types.JanetFunction) callconv(.c) ?*types.JanetFunction);
        publish("janet_optcfunction", &impl.args.Opt(impl.args.GetCFunction).abi, fn ([*]const repr.Value, i32, i32, types.JanetCFunction) callconv(.c) types.JanetCFunction);
        publish("janet_optboolean", &impl.args.Opt(impl.args.GetBoolean).abi, fn ([*]const repr.Value, i32, i32, c_int) callconv(.c) c_int);
        publish("janet_optpointer", &impl.args.Opt(impl.args.GetPointer).abi, fn ([*]const repr.Value, i32, i32, ?*anyopaque) callconv(.c) ?*anyopaque);
        publish("janet_optbuffer", &impl.args.OptLen(impl.args.GetBuffer, impl.args.buffers.new).abi, fn ([*]const repr.Value, i32, i32, i32) callconv(.c) *types.JanetBuffer);
        publish("janet_opttable", &impl.args.OptLen(impl.args.GetTable, impl.args.tables.new).abi, fn ([*]const repr.Value, i32, i32, i32) callconv(.c) *types.JanetTable);
        publish("janet_optarray", &impl.args.OptLen(impl.args.GetArray, impl.args.arrays.new).abi, fn ([*]const repr.Value, i32, i32, i32) callconv(.c) *types.JanetArray);
        publish("janet_getnat", &impl.args.GetNat.abi, fn ([*]const repr.Value, i32) callconv(.c) i32);
        publish("janet_getinteger", &impl.args.GetInteger.abi, fn ([*]const repr.Value, i32) callconv(.c) i32);
        publish("janet_getuinteger", &impl.args.GetUInteger.abi, fn ([*]const repr.Value, i32) callconv(.c) u32);
        publish("janet_getinteger16", &impl.args.GetInteger16.abi, fn ([*]const repr.Value, i32) callconv(.c) i16);
        publish("janet_getuinteger16", &impl.args.GetUInteger16.abi, fn ([*]const repr.Value, i32) callconv(.c) u16);
        publish("janet_getinteger8", &impl.args.GetInteger8.abi, fn ([*]const repr.Value, i32) callconv(.c) i8);
        publish("janet_getuinteger8", &impl.args.GetUInteger8.abi, fn ([*]const repr.Value, i32) callconv(.c) u8);
        publish("janet_getfloat", &impl.args.GetFloat.abi, fn ([*]const repr.Value, i32) callconv(.c) f32);
        publish("janet_getsize", &impl.args.GetSize.abi, fn ([*]const repr.Value, i32) callconv(.c) usize);
        publish("janet_getinteger64", &impl.args.GetInteger64.abi, fn ([*]const repr.Value, i32) callconv(.c) i64);
        publish("janet_getuinteger64", &impl.args.GetUInteger64.abi, fn ([*]const repr.Value, i32) callconv(.c) u64);
        publish("janet_optnat", &impl.args.Opt(impl.args.GetNat).abi, fn ([*]const repr.Value, i32, i32, i32) callconv(.c) i32);
        publish("janet_optinteger", &impl.args.Opt(impl.args.GetInteger).abi, fn ([*]const repr.Value, i32, i32, i32) callconv(.c) i32);
        publish("janet_optinteger64", &impl.args.Opt(impl.args.GetInteger64).abi, fn ([*]const repr.Value, i32, i32, i64) callconv(.c) i64);
        publish("janet_optsize", &impl.args.Opt(impl.args.GetSize).abi, fn ([*]const repr.Value, i32, i32, usize) callconv(.c) usize);
        publish("janet_optuinteger", &impl.args.Opt(impl.args.GetUInteger).abi, fn ([*]const repr.Value, i32, i32, u32) callconv(.c) u32);
        publish("janet_optuinteger64", &impl.args.Opt(impl.args.GetUInteger64).abi, fn ([*]const repr.Value, i32, i32, u64) callconv(.c) u64);
        publish("janet_getslice", &impl.args.getSliceAbi, fn (i32, [*]const repr.Value) callconv(.c) types.JanetRange);
        publish("janet_gethalfrange", &impl.args.halfRangeAbi, fn ([*]const repr.Value, i32, i32, [*:0]const u8) callconv(.c) i32);
        publish("janet_getargindex", &impl.args.argIndexAbi, fn ([*]const repr.Value, i32, i32, [*:0]const u8) callconv(.c) i32);
        publish("janet_getstartrange", &impl.args.startRangeAbi, fn ([*]const repr.Value, i32, i32, i32) callconv(.c) i32);
        publish("janet_getendrange", &impl.args.endRangeAbi, fn ([*]const repr.Value, i32, i32, i32) callconv(.c) i32);
        publish("janet_getindexed", &impl.args.getIndexedAbi, fn ([*]const repr.Value, i32) callconv(.c) types.JanetView);
        publish("janet_getdictionary", &impl.args.getDictionaryAbi, fn ([*]const repr.Value, i32) callconv(.c) types.JanetDictView);
        publish("janet_getbytes", &impl.args.getBytesAbi, fn ([*]const repr.Value, i32) callconv(.c) types.JanetByteView);
        publish("janet_getabstract", &impl.args.getAbstractAbi, fn ([*]const repr.Value, i32, *const types.AbstractType) callconv(.c) ?*anyopaque);
        publish("janet_optabstract", &impl.args.optAbstractAbi, fn ([*]const repr.Value, i32, i32, *const types.AbstractType, ?*anyopaque) callconv(.c) ?*anyopaque);
        publish("janet_getcbytes", &impl.args.getCBytesAbi, fn ([*]const repr.Value, i32) callconv(.c) [*c]const u8);
        publish("janet_getcstring", &impl.args.getCStringAbi, fn ([*]const repr.Value, i32) callconv(.c) [*c]const u8);
        publish("janet_optcbytes", &impl.args.optCBytesAbi, fn ([*]const repr.Value, i32, i32, [*c]const u8) callconv(.c) [*c]const u8);
        publish("janet_optcstring", &impl.args.optCStringAbi, fn ([*]const repr.Value, i32, i32, [*c]const u8) callconv(.c) [*c]const u8);
        publish("janet_getflags", &impl.args.getFlagsAbi, fn ([*]const repr.Value, i32, [*:0]const u8) callconv(.c) u64);
        @export(&janet_bytes_view, .{ .name = "janet_bytes_view" });
        @export(&janet_checkabstract, .{ .name = "janet_checkabstract" });
        @export(&janet_checkfloat, .{ .name = "janet_checkfloat" });
        @export(&janet_checkint, .{ .name = "janet_checkint" });
        @export(&janet_checkint16, .{ .name = "janet_checkint16" });
        @export(&janet_checkint64, .{ .name = "janet_checkint64" });
        @export(&janet_checkint8, .{ .name = "janet_checkint8" });
        @export(&janet_checksize, .{ .name = "janet_checksize" });
        @export(&janet_checkuint, .{ .name = "janet_checkuint" });
        @export(&janet_checkuint16, .{ .name = "janet_checkuint16" });
        @export(&janet_checkuint64, .{ .name = "janet_checkuint64" });
        @export(&janet_checkuint8, .{ .name = "janet_checkuint8" });
        @export(&janet_dictionary_view, .{ .name = "janet_dictionary_view" });
        @export(&janet_getmethod, .{ .name = "janet_getmethod" });
        @export(&janet_indexed_view, .{ .name = "janet_indexed_view" });
        @export(&janet_keyeq, .{ .name = "janet_keyeq" });
        @export(&janet_nextmethod, .{ .name = "janet_nextmethod" });
        @export(&janet_streq, .{ .name = "janet_streq" });
        @export(&janet_symeq, .{ .name = "janet_symeq" });
    }
}

// bytecode.zig
//
pub fn janet_lib_asm(env: *types.JanetTable) callconv(.c) void {
    return impl.bytecode.libAsmAbi(env);
}
pub fn janet_asm(source: repr.Value, flags: c_int) callconv(.c) types.JanetAssembleResult {
    return impl.bytecode.assembleValue(source, flags);
}
comptime {
    if (options.bytecode) {
        @export(&janet_lib_asm, .{ .name = "janet_lib_asm", .visibility = .hidden });
        @export(&janet_asm, .{ .name = "janet_asm" });
    }
}

// bytecode/disasm.zig
//
pub fn janet_zig_disasm_field(definition: *types.JanetFuncDef, field_value: c_int) callconv(.c) repr.Value {
    return impl.bytecode_disasm.disassembleFieldExport(definition, field_value);
}
pub fn janet_disasm(definition: *types.JanetFuncDef) callconv(.c) repr.Value {
    return impl.bytecode_disasm.disasm(definition);
}
pub fn janet_asm_decode_instruction(instruction: u32) callconv(.c) repr.Value {
    return impl.bytecode_disasm.asmDecodeInstruction(instruction);
}
comptime {
    if (options.disasm) {
        @export(&janet_zig_disasm_field, .{ .name = "janet_zig_disasm_field", .visibility = .hidden });
        @export(&janet_disasm, .{ .name = "janet_disasm" });
        @export(&janet_asm_decode_instruction, .{ .name = "janet_asm_decode_instruction" });
    }
}

// bytecode/verify.zig
//
pub fn janet_verify(definition: *types.JanetFuncDef) callconv(.c) c_int {
    return impl.bytecode_verify.verify(definition);
}
comptime {
    if (options.verify) {
        @export(&janet_verify, .{ .name = "janet_verify" });
    }
}

// compiler.zig
//
pub fn janet_compile(source: repr.Value, environment: *types.JanetTable, where: ?types.JanetString) callconv(.c) types.JanetCompileResult {
    return impl.compiler.compile(source, environment, where);
}
pub fn janet_compile_lint(source: repr.Value, environment: *types.JanetTable, where: ?types.JanetString, lints: ?*types.JanetArray) callconv(.c) types.JanetCompileResult {
    return impl.compiler.compileLint(source, environment, where, lints);
}
pub fn janet_def_addflags(definition: *types.JanetFuncDef) callconv(.c) void {
    return impl.compiler.defAddflags(definition);
}
pub fn janet_lib_compile(env: *types.JanetTable) callconv(.c) void {
    return impl.compiler.libCompile(env);
}
comptime {
    if (options.compiler_primitives) {
        @export(&janet_compile, .{ .name = "janet_compile" });
        @export(&janet_compile_lint, .{ .name = "janet_compile_lint" });
        @export(&janet_def_addflags, .{ .name = "janet_def_addflags", .visibility = .hidden });
        @export(&janet_lib_compile, .{ .name = "janet_lib_compile", .visibility = .hidden });
    }
}

// compiler/emit.zig
//
comptime {
    if (options.emit_core) {}
}

// compiler/optimize.zig
//
comptime {
    if (options.optimize) {}
}

// compiler/regalloc.zig
//
comptime {
    if (options.regalloc) {}
}

// compiler/specials.zig
//
comptime {
    if (options.specials_core) {}
}

// debug.zig
//
pub fn janet_debug_break(definition: *types.JanetFuncDef, pc: i32) callconv(.c) void {
    return impl.debug.debugBreakAbi(definition, pc);
}
pub fn janet_debug_find(definition_out: *?*types.JanetFuncDef, pc_out: *i32, source: [*:0]const u8, source_line: i32, source_column: i32) callconv(.c) void {
    return impl.debug.debugFind(definition_out, pc_out, source, source_line, source_column);
}
pub fn janet_debug_unbreak(definition: *types.JanetFuncDef, pc: i32) callconv(.c) void {
    return impl.debug.debugUnbreakAbi(definition, pc);
}
pub fn janet_lib_debug(env: *types.JanetTable) callconv(.c) void {
    return impl.debug.libDebug(env);
}
pub fn janet_stacktrace_ext(fiber: *types.JanetFiber, err: repr.Value, prefix: ?[*:0]const u8) callconv(.c) void {
    return impl.debug.stacktraceExtAbi(fiber, err, prefix);
}
pub fn janet_stacktrace(fiber: *types.JanetFiber, err: repr.Value) callconv(.c) void {
    return impl.debug.stacktrace(fiber, err);
}
comptime {
    if (options.debug) {
        @export(&janet_debug_break, .{ .name = "janet_debug_break" });
        @export(&janet_debug_find, .{ .name = "janet_debug_find" });
        @export(&janet_debug_unbreak, .{ .name = "janet_debug_unbreak" });
        @export(&janet_lib_debug, .{ .name = "janet_lib_debug", .visibility = .hidden });
        @export(&janet_stacktrace_ext, .{ .name = "janet_stacktrace_ext" });
        @export(&janet_stacktrace, .{ .name = "janet_stacktrace" });
    }
}

// dynlib.zig
//
pub fn dynlib__errorClibUnsupportedAbi() callconv(.c) [*]const u8 {
    return impl.dynlib.errorClibUnsupportedAbi();
}
pub fn dynlib__errorClibAbi() callconv(.c) [*]const u8 {
    return impl.dynlib.errorClibAbi();
}
pub fn load_clib(name: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    return impl.dynlib.loadClibAbi(name);
}
pub fn free_clib(lib: ?*anyopaque) callconv(.c) void {
    return impl.dynlib.freeClibAbi(lib);
}
comptime {
    if (!config.dynamic_modules) {
        @export(&dynlib__errorClibUnsupportedAbi, .{ .name = "error_clib" });
    }
    if (config.dynamic_modules and is_windows) {
        @export(&dynlib__errorClibAbi, .{ .name = "error_clib" });
        @export(&load_clib, .{ .name = "load_clib" });
        @export(&free_clib, .{ .name = "free_clib" });
        publish("symbol_clib", &impl.dynlib.symbolClibAbi, fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque);
    }
}

// env.zig
//
pub fn janet_core_env(replacements: ?*types.JanetTable) callconv(.c) *types.JanetTable {
    return impl.env.coreEnvAbi(replacements);
}
pub fn janet_core_lookup_table(replacements: *types.JanetTable) callconv(.c) *types.JanetTable {
    return impl.env.coreLookupTableAbi(replacements);
}
pub fn janet_loop_fiber(fiber: *types.JanetFiber) callconv(.c) c_int {
    return impl.env.loopFiberAbi(fiber);
}
pub fn janet_dobytes(env: *types.JanetTable, bytes: ?[*]const u8, len: i32, source_path: ?[*:0]const u8, out: ?*repr.Value) callconv(.c) c_int {
    return impl.env.dobytes(env, bytes, len, source_path, out);
}
pub fn janet_dostring(env: *types.JanetTable, str: [*:0]const u8, source_path: ?[*:0]const u8, out: ?*repr.Value) callconv(.c) c_int {
    return impl.env.dostring(env, str, source_path, out);
}
pub fn janet_native(name: [*:0]const u8, err: *?types.JanetString) callconv(.c) types.JanetModule {
    return impl.env.nativeAbi(name, err);
}
comptime {
    if (options.env) {
        @export(&janet_core_env, .{ .name = "janet_core_env" });
        @export(&janet_core_lookup_table, .{ .name = "janet_core_lookup_table" });
        @export(&janet_loop_fiber, .{ .name = "janet_loop_fiber" });
        @export(&janet_dobytes, .{ .name = "janet_dobytes" });
        @export(&janet_dostring, .{ .name = "janet_dostring" });
        @export(&janet_native, .{ .name = "janet_native" });
    }
}

// ev.zig
//
pub fn janet_cancel(fiber: *types.JanetFiber, val: repr.Value) callconv(.c) void {
    return impl.ev.cancelAbi(fiber, val);
}
pub fn janet_async_start_fiber(fiber: *types.JanetFiber, s: *types.JanetStream, mode: types.JanetAsyncMode, callback: types.JanetEVCallback, state: ?*anyopaque) callconv(.c) void {
    return impl.ev.asyncStartFiberAbi(fiber, s, mode, callback, state);
}
pub fn janet_async_start(s: *types.JanetStream, mode: types.JanetAsyncMode, callback: types.JanetEVCallback, state: ?*anyopaque) callconv(.c) void {
    return impl.ev.asyncStartAbi(s, mode, callback, state);
}
pub fn janet_await() callconv(.c) void {
    return impl.ev.awaitEventAbi();
}
pub fn janet_sleep_await(sec: f64) callconv(.c) void {
    return impl.ev.sleepAwaitAbi(sec);
}
pub fn janet_loop1() callconv(.c) ?*types.JanetFiber {
    return impl.ev.loop1Abi();
}
pub fn janet_loop() callconv(.c) void {
    return impl.ev.loopAbi();
}
pub fn janet_addtimeout(sec: f64) callconv(.c) void {
    return impl.ev.addtimeout(sec);
}
pub fn janet_addtimeout_nil(sec: f64) callconv(.c) void {
    return impl.ev.addtimeoutNil(sec);
}
pub fn janet_async_end(fiber: *types.JanetFiber) callconv(.c) void {
    return impl.ev.asyncEnd(fiber);
}
pub fn janet_async_in_flight(fiber: *types.JanetFiber) callconv(.c) void {
    return impl.ev.asyncInFlight(fiber);
}
pub fn janet_ev_dec_refcount() callconv(.c) void {
    return impl.ev.evDecRefcount();
}
pub fn janet_ev_default_threaded_callback(return_value: types.JanetEVGenericMessage) callconv(.c) void {
    return impl.ev.evDefaultThreadedCallback(return_value);
}
pub fn janet_ev_inc_refcount() callconv(.c) void {
    return impl.ev.evIncRefcount();
}
pub fn janet_ev_mark() callconv(.c) void {
    return impl.ev.evMark();
}
pub fn janet_ev_post_event(target: ?*types.Vm, cb: types.JanetCallback, msg: types.JanetEVGenericMessage) callconv(.c) void {
    return impl.ev.evPostEvent(target, cb, msg);
}
pub fn janet_ev_threaded_await(fp: types.JanetThreadedSubroutine, tag: c_int, argi: c_int, argp: ?*anyopaque) callconv(.c) void {
    return impl.ev.evThreadedAwait(fp, tag, argi, argp);
}
pub fn janet_ev_threaded_call(fp: types.JanetThreadedSubroutine, arguments: types.JanetEVGenericMessage, cb: types.JanetThreadedCallback) callconv(.c) void {
    return impl.ev.evThreadedCall(fp, arguments, cb);
}
pub fn janet_lib_ev(env: *types.JanetTable) callconv(.c) void {
    return impl.ev.libEvAbi(env);
}
pub fn janet_loop1_interrupt(v: *types.Vm) callconv(.c) void {
    return impl.ev.loop1Interrupt(v);
}
pub fn janet_loop_done() callconv(.c) c_int {
    return impl.ev.loopDone();
}
pub fn janet_schedule(fiber: *types.JanetFiber, val: repr.Value) callconv(.c) void {
    return impl.ev.schedule(fiber, val);
}
pub fn janet_schedule_signal(fiber: *types.JanetFiber, val: repr.Value, sig: c_uint) callconv(.c) void {
    return impl.ev.scheduleSignal(fiber, val, types.Signal.fromWire(sig));
}
pub fn janet_schedule_soon(fiber: *types.JanetFiber, val: repr.Value, sig: c_uint) callconv(.c) void {
    return impl.ev.scheduleSoon(fiber, val, types.Signal.fromWire(sig));
}
comptime {
    if (config.ev) {
        @export(&janet_cancel, .{ .name = "janet_cancel" });
        @export(&janet_async_start_fiber, .{ .name = "janet_async_start_fiber" });
        @export(&janet_async_start, .{ .name = "janet_async_start" });
        @export(&janet_await, .{ .name = "janet_await" });
        @export(&janet_sleep_await, .{ .name = "janet_sleep_await" });
        @export(&janet_loop1, .{ .name = "janet_loop1" });
        @export(&janet_loop, .{ .name = "janet_loop" });
        @export(&janet_addtimeout, .{ .name = "janet_addtimeout" });
        @export(&janet_addtimeout_nil, .{ .name = "janet_addtimeout_nil" });
        @export(&janet_async_end, .{ .name = "janet_async_end" });
        @export(&janet_async_in_flight, .{ .name = "janet_async_in_flight" });
        @export(&janet_ev_dec_refcount, .{ .name = "janet_ev_dec_refcount" });
        @export(&janet_ev_default_threaded_callback, .{ .name = "janet_ev_default_threaded_callback" });
        @export(&janet_ev_inc_refcount, .{ .name = "janet_ev_inc_refcount" });
        @export(&janet_ev_mark, .{ .name = "janet_ev_mark", .visibility = .hidden });
        @export(&janet_ev_post_event, .{ .name = "janet_ev_post_event" });
        @export(&janet_ev_threaded_await, .{ .name = "janet_ev_threaded_await" });
        @export(&janet_ev_threaded_call, .{ .name = "janet_ev_threaded_call" });
        @export(&janet_lib_ev, .{ .name = "janet_lib_ev", .visibility = .hidden });
        @export(&janet_loop1_interrupt, .{ .name = "janet_loop1_interrupt" });
        @export(&janet_loop_done, .{ .name = "janet_loop_done" });
        @export(&janet_schedule, .{ .name = "janet_schedule" });
        @export(&janet_schedule_signal, .{ .name = "janet_schedule_signal" });
        @export(&janet_schedule_soon, .{ .name = "janet_schedule_soon" });
    }
}

// ev/backend.zig
//
pub fn janet_stream_edge_triggered(s: *types.JanetStream) callconv(.c) void {
    return impl.ev_backend.streamEdgeTriggered(s);
}
pub fn janet_stream_level_triggered(s: *types.JanetStream) callconv(.c) void {
    return impl.ev_backend.streamLevelTriggered(s);
}
comptime {
    if (config.ev) {
        @export(&janet_stream_edge_triggered, .{ .name = "janet_stream_edge_triggered" });
        @export(&janet_stream_level_triggered, .{ .name = "janet_stream_level_triggered" });
    }
}

// ev/channel.zig
//
pub fn janet_channel_give(chan: ?*types.JanetChannel, x: repr.Value) callconv(.c) c_int {
    return impl.ev_channel.channelGiveAbi(chan, x);
}
pub fn janet_channel_take(chan: ?*types.JanetChannel, out: *repr.Value) callconv(.c) c_int {
    return impl.ev_channel.channelTakeAbi(chan, out);
}
pub fn janet_channel_make(limit: u32) callconv(.c) ?*types.JanetChannel {
    return impl.ev_channel.channelMake(limit);
}
pub fn janet_channel_make_threaded(limit: u32) callconv(.c) ?*types.JanetChannel {
    return impl.ev_channel.channelMakeThreaded(limit);
}
pub fn janet_getchannel(argv: [*]const repr.Value, n: i32) callconv(.c) ?*types.JanetChannel {
    return raise.reported(impl.ev_channel.getChannel(argv[0..@intCast(n + 1)], n));
}
pub fn janet_optchannel(argv: [*]const repr.Value, argc: i32, n: i32, dflt: ?*types.JanetChannel) callconv(.c) ?*types.JanetChannel {
    return raise.reported(impl.ev_channel.optChannel(argv[0..@intCast(argc)], n, dflt));
}
comptime {
    if (config.ev) {
        @export(&janet_channel_give, .{ .name = "janet_channel_give" });
        @export(&janet_channel_take, .{ .name = "janet_channel_take" });
        @export(&janet_channel_make, .{ .name = "janet_channel_make" });
        @export(&janet_channel_make_threaded, .{ .name = "janet_channel_make_threaded" });
        @export(&janet_getchannel, .{ .name = "janet_getchannel" });
        @export(&janet_optchannel, .{ .name = "janet_optchannel" });
    }
}

// ev/locks.zig
//
pub fn janet_os_mutex_size() callconv(.c) usize {
    return impl.ev_locks.mutexSizeAbi();
}
pub fn janet_os_rwlock_size() callconv(.c) usize {
    return impl.ev_locks.rwlockSizeAbi();
}
pub fn janet_os_mutex_init(m: *anyopaque) callconv(.c) void {
    return impl.ev_locks.mutexInitAbi(m);
}
pub fn janet_os_mutex_deinit(m: *anyopaque) callconv(.c) void {
    return impl.ev_locks.mutexDeinitAbi(m);
}
pub fn janet_os_mutex_lock(m: *anyopaque) callconv(.c) void {
    return impl.ev_locks.mutexLockAbi(m);
}
pub fn janet_os_mutex_unlock(m: *anyopaque) callconv(.c) void {
    return impl.ev_locks.mutexUnlockAbi(m);
}
pub fn janet_os_rwlock_init(r: *anyopaque) callconv(.c) void {
    return impl.ev_locks.rwlockInitAbi(r);
}
pub fn janet_os_rwlock_deinit(r: *anyopaque) callconv(.c) void {
    return impl.ev_locks.rwlockDeinitAbi(r);
}
pub fn janet_os_rwlock_rlock(r: *anyopaque) callconv(.c) void {
    return impl.ev_locks.rwlockRlockAbi(r);
}
pub fn janet_os_rwlock_wlock(r: *anyopaque) callconv(.c) void {
    return impl.ev_locks.rwlockWlockAbi(r);
}
pub fn janet_os_rwlock_runlock(r: *anyopaque) callconv(.c) void {
    return impl.ev_locks.rwlockRunlockAbi(r);
}
pub fn janet_os_rwlock_wunlock(r: *anyopaque) callconv(.c) void {
    return impl.ev_locks.rwlockWunlockAbi(r);
}
comptime {
    @export(&janet_os_mutex_size, .{ .name = "janet_os_mutex_size" });
    @export(&janet_os_rwlock_size, .{ .name = "janet_os_rwlock_size" });
    @export(&janet_os_mutex_init, .{ .name = "janet_os_mutex_init" });
    @export(&janet_os_mutex_deinit, .{ .name = "janet_os_mutex_deinit" });
    @export(&janet_os_mutex_lock, .{ .name = "janet_os_mutex_lock" });
    @export(&janet_os_mutex_unlock, .{ .name = "janet_os_mutex_unlock" });
    @export(&janet_os_rwlock_init, .{ .name = "janet_os_rwlock_init" });
    @export(&janet_os_rwlock_deinit, .{ .name = "janet_os_rwlock_deinit" });
    @export(&janet_os_rwlock_rlock, .{ .name = "janet_os_rwlock_rlock" });
    @export(&janet_os_rwlock_wlock, .{ .name = "janet_os_rwlock_wlock" });
    @export(&janet_os_rwlock_runlock, .{ .name = "janet_os_rwlock_runlock" });
    @export(&janet_os_rwlock_wunlock, .{ .name = "janet_os_rwlock_wunlock" });
}

// ev/stream.zig
//
pub fn janet_stream(handle: types.JanetHandle, flags: u32, methods: ?[*]const types.JanetMethod) callconv(.c) *types.JanetStream {
    return impl.ev_stream.makeStreamAbi(handle, flags, methods);
}
pub fn janet_stream_close(s: *types.JanetStream) callconv(.c) void {
    return impl.ev_stream.streamCloseAbi(s);
}
pub fn janet_stream_flags(s: *types.JanetStream, flags: u32) callconv(.c) void {
    return impl.ev_stream.streamFlagsAbi(s, flags);
}
pub fn janet_ev_recv(s: *types.JanetStream, buf: *types.JanetBuffer, nbytes: i32, flags: c_int) callconv(.c) void {
    return impl.ev_stream.evRecv(s, buf, nbytes, flags);
}
pub fn janet_ev_recvchunk(s: *types.JanetStream, buf: *types.JanetBuffer, nbytes: i32, flags: c_int) callconv(.c) void {
    return impl.ev_stream.evRecvChunk(s, buf, nbytes, flags);
}
pub fn janet_ev_recvfrom(s: *types.JanetStream, buf: *types.JanetBuffer, nbytes: i32, flags: c_int) callconv(.c) void {
    return impl.ev_stream.evRecvFrom(s, buf, nbytes, flags);
}
pub fn janet_ev_send_buffer(s: *types.JanetStream, buf: *types.JanetBuffer, flags: c_int) callconv(.c) void {
    return impl.ev_stream.evSendBuffer(s, buf, flags);
}
pub fn janet_ev_send_string(s: *types.JanetStream, str: [*:0]const u8, flags: c_int) callconv(.c) void {
    return impl.ev_stream.evSendString(s, str, flags);
}
pub fn janet_ev_sendto_buffer(s: *types.JanetStream, buf: *types.JanetBuffer, dest: ?*anyopaque, flags: c_int) callconv(.c) void {
    return impl.ev_stream.evSendToBuffer(s, buf, dest, flags);
}
pub fn janet_ev_sendto_string(s: *types.JanetStream, str: [*:0]const u8, dest: ?*anyopaque, flags: c_int) callconv(.c) void {
    return impl.ev_stream.evSendToString(s, str, dest, flags);
}
pub fn janet_ev_lasterr() callconv(.c) repr.Value {
    return impl.ev_stream.evLasterr();
}
pub fn janet_ev_read(s: *types.JanetStream, buf: *types.JanetBuffer, nbytes: i32) callconv(.c) void {
    return impl.ev_stream.evRead(s, buf, nbytes);
}
pub fn janet_ev_readchunk(s: *types.JanetStream, buf: *types.JanetBuffer, nbytes: i32) callconv(.c) void {
    return impl.ev_stream.evReadchunk(s, buf, nbytes);
}
pub fn janet_ev_write_buffer(s: *types.JanetStream, buf: *types.JanetBuffer) callconv(.c) void {
    return impl.ev_stream.evWriteBuffer(s, buf);
}
pub fn janet_ev_write_string(s: *types.JanetStream, str: [*:0]const u8) callconv(.c) void {
    return impl.ev_stream.evWriteString(s, str);
}
pub fn janet_stream_ext(handle: types.JanetHandle, flags: u32, methods: ?[*]const types.JanetMethod, size: usize) callconv(.c) *types.JanetStream {
    return impl.ev_stream.streamExt(handle, flags, methods, size);
}
comptime {
    if (config.ev and config.net) {
        @export(&janet_ev_recv, .{ .name = "janet_ev_recv" });
        @export(&janet_ev_recvchunk, .{ .name = "janet_ev_recvchunk" });
        @export(&janet_ev_recvfrom, .{ .name = "janet_ev_recvfrom" });
        @export(&janet_ev_send_buffer, .{ .name = "janet_ev_send_buffer" });
        @export(&janet_ev_send_string, .{ .name = "janet_ev_send_string" });
        @export(&janet_ev_sendto_buffer, .{ .name = "janet_ev_sendto_buffer" });
        @export(&janet_ev_sendto_string, .{ .name = "janet_ev_sendto_string" });
    }
    if (config.ev) {
        @export(&janet_stream, .{ .name = "janet_stream" });
        @export(&janet_stream_close, .{ .name = "janet_stream_close" });
        @export(&janet_stream_flags, .{ .name = "janet_stream_flags" });
        @export(&janet_ev_lasterr, .{ .name = "janet_ev_lasterr" });
        @export(&janet_ev_read, .{ .name = "janet_ev_read" });
        @export(&janet_ev_readchunk, .{ .name = "janet_ev_readchunk" });
        @export(&janet_ev_write_buffer, .{ .name = "janet_ev_write_buffer" });
        @export(&janet_ev_write_string, .{ .name = "janet_ev_write_string" });
        @export(&janet_stream_ext, .{ .name = "janet_stream_ext" });
    }
}

// fatal.zig
//
pub fn janet_zig_fatal(message: [*:0]const u8) callconv(.c) noreturn {
    return impl.fatal.fatal(message);
}
comptime {
    @export(&janet_zig_fatal, .{ .name = "janet_zig_fatal", .visibility = .hidden });
}

// ffi.zig
//
pub fn janet_lib_ffi(env: *types.JanetTable) callconv(.c) void {
    return impl.ffi.libFfi(env);
}
comptime {
    if (options.ffi_zig) {
        @export(&janet_lib_ffi, .{ .name = "janet_lib_ffi", .visibility = .hidden });
    }
}

// filewatch.zig
//
pub fn janet_lib_filewatch(env: *types.JanetTable) callconv(.c) void {
    return impl.filewatch.libFilewatch(env);
}
comptime {
    if (options.filewatch) {
        @export(&janet_lib_filewatch, .{ .name = "janet_lib_filewatch", .visibility = .hidden });
    }
}

// gc.zig
//
pub fn janet_gclock() callconv(.c) c_int {
    return impl.gc.gclock();
}
pub fn janet_gcpressure(s: usize) callconv(.c) void {
    return impl.gc.gcpressure(s);
}
pub fn janet_gcroot(root: repr.Value) callconv(.c) void {
    return impl.gc.gcroot(root);
}
pub fn janet_gcunlock(handle: c_int) callconv(.c) void {
    return impl.gc.gcunlock(handle);
}
pub fn janet_gcunroot(root: repr.Value) callconv(.c) c_int {
    return impl.gc.gcunroot(root);
}
pub fn janet_gcunrootall(root: repr.Value) callconv(.c) c_int {
    return impl.gc.gcunrootall(root);
}
pub fn janet_scalloc(nmemb: usize, size: usize) callconv(.c) ?*anyopaque {
    return impl.gc.scalloc(nmemb, size);
}
pub fn janet_sfinalizer(mem: ?*anyopaque, finalizer: types.JanetScratchFinalizer) callconv(.c) void {
    return impl.gc.sfinalizer(mem, finalizer);
}
pub fn janet_sfree(mem: ?*anyopaque) callconv(.c) void {
    return impl.gc.sfree(mem);
}
pub fn janet_smalloc(size: usize) callconv(.c) ?*anyopaque {
    return impl.gc.smalloc(size);
}
pub fn janet_srealloc(mem: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    return impl.gc.srealloc(mem, size);
}
comptime {
    if (options.gc_alloc) {
        @export(&janet_gclock, .{ .name = "janet_gclock" });
        @export(&janet_gcpressure, .{ .name = "janet_gcpressure" });
        @export(&janet_gcroot, .{ .name = "janet_gcroot" });
        @export(&janet_gcunlock, .{ .name = "janet_gcunlock" });
        @export(&janet_gcunroot, .{ .name = "janet_gcunroot" });
        @export(&janet_gcunrootall, .{ .name = "janet_gcunrootall" });
        @export(&janet_scalloc, .{ .name = "janet_scalloc" });
        @export(&janet_sfinalizer, .{ .name = "janet_sfinalizer" });
        @export(&janet_sfree, .{ .name = "janet_sfree" });
        @export(&janet_smalloc, .{ .name = "janet_smalloc" });
        @export(&janet_srealloc, .{ .name = "janet_srealloc" });
    }
}

// gc/mark.zig
//
pub fn janet_collect() callconv(.c) void {
    return impl.gc_mark.collect();
}
pub fn janet_mark(x: repr.Value) callconv(.c) void {
    return impl.gc_mark.mark(x);
}
comptime {
    if (options.gc_mark) {
        @export(&janet_collect, .{ .name = "janet_collect" });
        @export(&janet_mark, .{ .name = "janet_mark" });
    }
}

// gc/sweep.zig
//
pub fn janet_clear_memory() callconv(.c) void {
    return impl.gc_sweep.clearMemoryAbi();
}
pub fn janet_sweep() callconv(.c) void {
    return impl.gc_sweep.sweep();
}
comptime {
    if (options.gc_sweep) {
        @export(&janet_clear_memory, .{ .name = "janet_clear_memory" });
        @export(&janet_sweep, .{ .name = "janet_sweep" });
    }
}

// io.zig
//
pub fn janet_io_write(handle: ?*anyopaque, src: [*]const u8, count: usize) callconv(.c) i32 {
    return impl.io.write(handle, src, count);
}
pub fn janet_checkfile(j: repr.Value) callconv(.c) types.JanetAbstract {
    return impl.io.checkfile(j);
}
pub fn janet_dynfile(name: [*:0]const u8, def: ?*impl.io.FILE) callconv(.c) ?*impl.io.FILE {
    return impl.io.dynfile(name, def);
}
pub fn janet_file_close(file: *types.JanetFile) callconv(.c) c_int {
    return impl.io.fileClose(file);
}
pub fn janet_getfile(argv: [*]const repr.Value, n: i32, flags: ?*i32) callconv(.c) ?*impl.io.FILE {
    return raise.reported(impl.io.getfile(argv[0..@intCast(n + 1)], n, flags));
}
pub fn janet_getjfile(argv: [*]const repr.Value, n: i32) callconv(.c) *types.JanetFile {
    return raise.reported(impl.io.getjfile(argv[0..@intCast(n + 1)], n));
}
pub fn janet_lib_io(env: *types.JanetTable) callconv(.c) void {
    return impl.io.libIoAbi(env);
}
pub fn janet_makefile(f: ?*impl.io.FILE, flags: i32) callconv(.c) repr.Value {
    return impl.io.makefile(f, flags);
}
pub fn janet_makejfile(f: ?*impl.io.FILE, flags: i32) callconv(.c) *types.JanetFile {
    return impl.io.makejfile(f, flags);
}
pub fn janet_unwrapfile(j: repr.Value, flags: ?*i32) callconv(.c) ?*impl.io.FILE {
    return impl.io.unwrapfile(j, flags);
}
pub fn janet_zig_io_assert_writeable(iof: *types.JanetFile) callconv(.c) void {
    return impl.io.zigIoAssertWriteable(iof);
}
comptime {
    if (options.io) {
        @export(&janet_io_write, .{ .name = "janet_io_write", .visibility = .hidden });
        @export(&janet_checkfile, .{ .name = "janet_checkfile" });
        @export(&janet_dynfile, .{ .name = "janet_dynfile" });
        @export(&janet_file_close, .{ .name = "janet_file_close" });
        @export(&janet_getfile, .{ .name = "janet_getfile" });
        @export(&janet_getjfile, .{ .name = "janet_getjfile" });
        @export(&janet_lib_io, .{ .name = "janet_lib_io", .visibility = .hidden });
        @export(&janet_makefile, .{ .name = "janet_makefile" });
        @export(&janet_makejfile, .{ .name = "janet_makejfile" });
        @export(&janet_unwrapfile, .{ .name = "janet_unwrapfile" });
        @export(&janet_zig_io_assert_writeable, .{ .name = "janet_zig_io_assert_writeable", .visibility = .hidden });
    }
}

// marsh.zig
//
pub fn janet_marshal_size(ctx: *types.JanetMarshalContext, val: usize) callconv(.c) void {
    return impl.marsh.marshalSizeAbi(ctx, val);
}
pub fn janet_marshal_int64(ctx: *types.JanetMarshalContext, val: i64) callconv(.c) void {
    return impl.marsh.marshalInt64Abi(ctx, val);
}
pub fn janet_marshal_int(ctx: *types.JanetMarshalContext, val: i32) callconv(.c) void {
    return impl.marsh.marshalIntAbi(ctx, val);
}
pub fn janet_marshal_byte(ctx: *types.JanetMarshalContext, val: u8) callconv(.c) void {
    return impl.marsh.marshalByteAbi(ctx, val);
}
pub fn janet_env_lookup(env: *types.JanetTable) callconv(.c) *types.JanetTable {
    return impl.marsh.envLookup(env);
}
pub fn janet_env_lookup_into(renv: *types.JanetTable, env_in: ?*types.JanetTable, prefix: ?[*:0]const u8, recurse: c_int) callconv(.c) void {
    return impl.marsh.envLookupInto(renv, env_in, prefix, recurse);
}
pub fn janet_lib_marsh(env: *types.JanetTable) callconv(.c) void {
    return impl.marsh.libMarsh(env);
}
pub fn janet_marshal_abstract(ctx: *types.JanetMarshalContext, abstract: ?*anyopaque) callconv(.c) void {
    return impl.marsh.marshalAbstract(ctx, abstract);
}
pub fn janet_marshal_flags(ctx: *types.JanetMarshalContext) callconv(.c) c_int {
    return impl.marsh.marshalFlags(ctx);
}
pub fn janet_unmarshal_flags(ctx: *types.JanetMarshalContext) callconv(.c) c_int {
    return impl.marsh.unmarshalFlags(ctx);
}
comptime {
    if (options.marsh) {
        publish("janet_marshal", &impl.marsh.marshalAbi, fn (*types.JanetBuffer, repr.Value, ?*types.JanetTable, c_int) callconv(.c) void);
        @export(&janet_marshal_size, .{ .name = "janet_marshal_size" });
        @export(&janet_marshal_int64, .{ .name = "janet_marshal_int64" });
        @export(&janet_marshal_int, .{ .name = "janet_marshal_int" });
        @export(&janet_marshal_byte, .{ .name = "janet_marshal_byte" });
        publish("janet_marshal_ptr", &impl.marsh.marshalPtrAbi, fn (*types.JanetMarshalContext, ?*const anyopaque) callconv(.c) void);
        publish("janet_marshal_bytes", &impl.marsh.marshalBytesAbi, fn (*types.JanetMarshalContext, ?[*]const u8, usize) callconv(.c) void);
        publish("janet_marshal_janet", &impl.marsh.marshalJanetAbi, fn (*types.JanetMarshalContext, repr.Value) callconv(.c) void);
        publish("janet_unmarshal_ensure", &impl.marsh.unmarshalEnsureAbi, fn (*types.JanetMarshalContext, usize) callconv(.c) void);
        publish("janet_unmarshal_int", &impl.marsh.unmarshalIntAbi, fn (*types.JanetMarshalContext) callconv(.c) i32);
        publish("janet_unmarshal_size", &impl.marsh.unmarshalSizeAbi, fn (*types.JanetMarshalContext) callconv(.c) usize);
        publish("janet_unmarshal_int64", &impl.marsh.unmarshalInt64Abi, fn (*types.JanetMarshalContext) callconv(.c) i64);
        publish("janet_unmarshal_ptr", &impl.marsh.unmarshalPtrAbi, fn (*types.JanetMarshalContext) callconv(.c) ?*anyopaque);
        publish("janet_unmarshal_byte", &impl.marsh.unmarshalByteAbi, fn (*types.JanetMarshalContext) callconv(.c) u8);
        publish("janet_unmarshal_bytes", &impl.marsh.unmarshalBytesAbi, fn (*types.JanetMarshalContext, [*]u8, usize) callconv(.c) void);
        publish("janet_unmarshal_janet", &impl.marsh.unmarshalJanetAbi, fn (*types.JanetMarshalContext) callconv(.c) repr.Value);
        publish("janet_unmarshal_abstract_reuse", &impl.marsh.unmarshalAbstractReuseAbi, fn (*types.JanetMarshalContext, ?*anyopaque) callconv(.c) void);
        publish("janet_unmarshal_abstract", &impl.marsh.unmarshalAbstractAbi, fn (*types.JanetMarshalContext, usize) callconv(.c) ?*anyopaque);
        publish("janet_unmarshal_abstract_threaded", &impl.marsh.unmarshalAbstractThreadedAbi, fn (*types.JanetMarshalContext, usize) callconv(.c) ?*anyopaque);
        publish("janet_unmarshal", &impl.marsh.unmarshalAbi, fn (?[*]const u8, usize, c_int, ?*types.JanetTable, ?*[*]const u8) callconv(.c) repr.Value);
        @export(&janet_env_lookup, .{ .name = "janet_env_lookup" });
        @export(&janet_env_lookup_into, .{ .name = "janet_env_lookup_into" });
        @export(&janet_lib_marsh, .{ .name = "janet_lib_marsh", .visibility = .hidden });
        @export(&janet_marshal_abstract, .{ .name = "janet_marshal_abstract" });
        @export(&janet_marshal_flags, .{ .name = "janet_marshal_flags" });
        @export(&janet_unmarshal_flags, .{ .name = "janet_unmarshal_flags" });
    }
}

// math.zig
//
pub fn janet_default_rng() callconv(.c) *types.JanetRNG {
    return impl.math.defaultRng();
}
pub fn janet_lib_math(env: *types.JanetTable) callconv(.c) void {
    return impl.math.libMathAbi(env);
}
pub fn janet_rng_double(rng: *types.JanetRNG) callconv(.c) f64 {
    return impl.math.rngDouble(rng);
}
pub fn janet_rng_longseed(rng: *types.JanetRNG, bytes: ?[*]const u8, len: i32) callconv(.c) void {
    return impl.math.rngLongseed(rng, cbytes(bytes, len));
}
pub fn janet_rng_seed(rng: *types.JanetRNG, seed: u32) callconv(.c) void {
    return impl.math.rngSeed(rng, seed);
}
pub fn janet_rng_u32(rng: *types.JanetRNG) callconv(.c) u32 {
    return impl.math.rngU32(rng);
}
comptime {
    if (options.math_core) {
        @export(&janet_default_rng, .{ .name = "janet_default_rng" });
        @export(&janet_lib_math, .{ .name = "janet_lib_math", .visibility = .hidden });
        @export(&janet_rng_double, .{ .name = "janet_rng_double" });
        @export(&janet_rng_longseed, .{ .name = "janet_rng_longseed" });
        @export(&janet_rng_seed, .{ .name = "janet_rng_seed" });
        @export(&janet_rng_u32, .{ .name = "janet_rng_u32" });
    }
}

// net.zig
//
pub fn janet_lib_net(env: *types.JanetTable) callconv(.c) void {
    return impl.net.libNet(env);
}
comptime {
    if (options.net) {
        @export(&janet_lib_net, .{ .name = "janet_lib_net", .visibility = .hidden });
    }
}

// os.zig
//
pub fn janet_os_time_now() callconv(.c) f64 {
    return impl.os.timeNow();
}
pub fn janet_os_sleep(seconds: f64) callconv(.c) void {
    return impl.os.sleepFor(seconds);
}
pub fn janet_os_gettime(source: i32, sec_out: *i64, nsec_out: *i64) callconv(.c) i32 {
    return impl.os.gettime(source, sec_out, nsec_out);
}
pub fn janet_os_environ_count(environ: ?[*]const ?[*:0]u8) callconv(.c) i32 {
    return impl.os.environCount(environ);
}
pub fn janet_os_environ_separator(entry: [*:0]const u8) callconv(.c) i32 {
    return impl.os.environSeparator(entry);
}
pub fn janet_os_getenv(name: [*:0]const u8) callconv(.c) ?[*:0]const u8 {
    return impl.os.environGet(name);
}
pub fn janet_os_setenv(name: [*:0]const u8, val: ?[*:0]const u8) callconv(.c) i32 {
    return impl.os.environSet(name, val);
}
pub fn janet_lib_os(env: *types.JanetTable) callconv(.c) void {
    return impl.os.libOsAbi(env);
}
pub fn janet_gettime(spec: *impl.os.Timespec, source: c_uint) callconv(.c) c_int {
    return impl.os.gettimeAbi(spec, source);
}
pub fn janet_os_arch() callconv(.c) [*:0]const u8 {
    return impl.os.osArch();
}
pub fn janet_os_compiler() callconv(.c) [*:0]const u8 {
    return impl.os.osCompiler();
}
pub fn janet_os_cpu_count() callconv(.c) i32 {
    return impl.os.osCpuCount();
}
pub fn janet_os_name() callconv(.c) [*:0]const u8 {
    return impl.os.osName();
}
comptime {
    if (options.os and options.os_environ) {
        @export(&janet_os_environ_count, .{ .name = "janet_os_environ_count", .visibility = .hidden });
        @export(&janet_os_environ_separator, .{ .name = "janet_os_environ_separator", .visibility = .hidden });
        @export(&janet_os_getenv, .{ .name = "janet_os_getenv", .visibility = .hidden });
        @export(&janet_os_setenv, .{ .name = "janet_os_setenv", .visibility = .hidden });
    }
    if (options.os and options.os_time) {
        @export(&janet_os_time_now, .{ .name = "janet_os_time_now", .visibility = .hidden });
        @export(&janet_os_sleep, .{ .name = "janet_os_sleep", .visibility = .hidden });
        @export(&janet_os_gettime, .{ .name = "janet_os_gettime", .visibility = .hidden });
    }
    if (options.os) {
        @export(&janet_lib_os, .{ .name = "janet_lib_os", .visibility = .hidden });
        @export(&janet_gettime, .{ .name = "janet_gettime", .visibility = .hidden });
        @export(&janet_os_arch, .{ .name = "janet_os_arch", .visibility = .hidden });
        @export(&janet_os_compiler, .{ .name = "janet_os_compiler", .visibility = .hidden });
        @export(&janet_os_cpu_count, .{ .name = "janet_os_cpu_count", .visibility = .hidden });
        @export(&janet_os_name, .{ .name = "janet_os_name", .visibility = .hidden });
    }
}

// os/fs.zig
//
pub fn janet_os_getcwd(buffer: [*]u8, size: i32) callconv(.c) i32 {
    return impl.os_fs.hostGetcwd(buffer, size);
}
pub fn janet_os_mkdir(path: [*:0]const u8) callconv(.c) i32 {
    return impl.os_fs.hostMkdir(path);
}
pub fn janet_os_rmdir(path: [*:0]const u8) callconv(.c) i32 {
    return impl.os_fs.hostRmdir(path);
}
pub fn janet_os_chdir(path: [*:0]const u8) callconv(.c) i32 {
    return impl.os_fs.hostChdir(path);
}
pub fn janet_os_remove(path: [*:0]const u8) callconv(.c) i32 {
    return impl.os_fs.hostRemove(path);
}
pub fn janet_os_rename(old_path: [*:0]const u8, new_path: [*:0]const u8) callconv(.c) i32 {
    return impl.os_fs.hostRename(old_path, new_path);
}
pub fn janet_os_dir_open(path: [*:0]const u8) callconv(.c) ?*anyopaque {
    return impl.os_fs.dirOpen(path);
}
pub fn janet_os_dir_next(handle: *anyopaque, name_out: *[*:0]const u8) callconv(.c) i32 {
    return impl.os_fs.dirNextAbi(handle, name_out);
}
pub fn janet_os_dir_close(handle: *anyopaque) callconv(.c) void {
    return impl.os_fs.dirClose(handle);
}
pub fn janet_os_link(oldpath: [*:0]const u8, newpath: [*:0]const u8) callconv(.c) i32 {
    return impl.os_fs.hardLink(oldpath, newpath);
}
pub fn janet_os_symlink(oldpath: [*:0]const u8, newpath: [*:0]const u8) callconv(.c) i32 {
    return impl.os_fs.symbolicLink(oldpath, newpath);
}
pub fn janet_os_readlink(path: [*:0]const u8, buffer: [*]u8, size: usize) callconv(.c) i64 {
    return impl.os_fs.readLink(path, buffer, size);
}
pub fn janet_os_touch(path: [*:0]const u8, has_times: i32, actime: f64, modtime: f64) callconv(.c) i32 {
    return impl.os_fs.touch(path, has_times, actime, modtime);
}
pub fn janet_os_realpath(path: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    return impl.os_fs.canonicalPath(path);
}
comptime {
    if (options.os_fs and !is_windows) {
        @export(&janet_os_dir_open, .{ .name = "janet_os_dir_open", .visibility = .hidden });
        @export(&janet_os_dir_next, .{ .name = "janet_os_dir_next", .visibility = .hidden });
        @export(&janet_os_dir_close, .{ .name = "janet_os_dir_close", .visibility = .hidden });
        @export(&janet_os_link, .{ .name = "janet_os_link", .visibility = .hidden });
        @export(&janet_os_symlink, .{ .name = "janet_os_symlink", .visibility = .hidden });
        @export(&janet_os_readlink, .{ .name = "janet_os_readlink", .visibility = .hidden });
    }
    if (options.os_fs) {
        @export(&janet_os_getcwd, .{ .name = "janet_os_getcwd", .visibility = .hidden });
        @export(&janet_os_mkdir, .{ .name = "janet_os_mkdir", .visibility = .hidden });
        @export(&janet_os_rmdir, .{ .name = "janet_os_rmdir", .visibility = .hidden });
        @export(&janet_os_chdir, .{ .name = "janet_os_chdir", .visibility = .hidden });
        @export(&janet_os_remove, .{ .name = "janet_os_remove", .visibility = .hidden });
        @export(&janet_os_rename, .{ .name = "janet_os_rename", .visibility = .hidden });
        @export(&janet_os_touch, .{ .name = "janet_os_touch", .visibility = .hidden });
        @export(&janet_os_realpath, .{ .name = "janet_os_realpath", .visibility = .hidden });
    }
}

// os/fs/stat.zig
//
pub fn janet_os_mode_name(mode: u32) callconv(.c) [*:0]const u8 {
    return impl.os_fs_stat.hostModeName(mode);
}
pub fn janet_os_decode_permissions(mode: u32) callconv(.c) i32 {
    return impl.os_fs_stat.hostDecodePermissions(mode);
}
pub fn janet_os_perm_to_unix(mode: u32) callconv(.c) i32 {
    return impl.os_fs_stat.hostPermToUnix(mode);
}
pub fn janet_os_perm_from_unix(permissions: i32) callconv(.c) u32 {
    return impl.os_fs_stat.hostPermFromUnix(permissions);
}
pub fn janet_os_parse_permissions(permissions: [*]const u8) callconv(.c) i32 {
    return impl.os_fs_stat.hostParsePermissions(permissions);
}
pub fn janet_os_format_permissions(mode: i32, out: [*]u8) callconv(.c) void {
    return impl.os_fs_stat.hostFormatPermissions(mode, out);
}
comptime {
    if (options.os_fs) {
        @export(&janet_os_mode_name, .{ .name = "janet_os_mode_name", .visibility = .hidden });
        @export(&janet_os_decode_permissions, .{ .name = "janet_os_decode_permissions", .visibility = .hidden });
        @export(&janet_os_perm_to_unix, .{ .name = "janet_os_perm_to_unix", .visibility = .hidden });
        @export(&janet_os_perm_from_unix, .{ .name = "janet_os_perm_from_unix", .visibility = .hidden });
        @export(&janet_os_parse_permissions, .{ .name = "janet_os_parse_permissions", .visibility = .hidden });
        @export(&janet_os_format_permissions, .{ .name = "janet_os_format_permissions", .visibility = .hidden });
    }
}

// parser.zig
//
pub fn janet_lib_parse(env: *types.JanetTable) callconv(.c) void {
    return impl.parser.libParse(env);
}
pub fn janet_parser_clone(source: *const types.JanetParser, destination: *types.JanetParser) callconv(.c) void {
    return impl.parser.parserClone(source, destination);
}
pub fn janet_parser_deinit(parser: *types.JanetParser) callconv(.c) void {
    return impl.parser.parserDeinit(parser);
}
pub fn janet_parser_error(parser: *types.JanetParser) callconv(.c) ?[*:0]const u8 {
    return impl.parser.parserError(parser);
}
pub fn janet_parser_flush(parser: *types.JanetParser) callconv(.c) void {
    return impl.parser.parserFlush(parser);
}
pub fn janet_parser_has_more(parser: *types.JanetParser) callconv(.c) c_int {
    return impl.parser.parserHasMore(parser);
}
pub fn janet_parser_init(parser: *types.JanetParser) callconv(.c) void {
    return impl.parser.parserInit(parser);
}
pub fn janet_parser_produce(parser: *types.JanetParser) callconv(.c) repr.Value {
    return impl.parser.parserProduce(parser);
}
pub fn janet_parser_produce_wrapped(parser: *types.JanetParser) callconv(.c) repr.Value {
    return impl.parser.parserProduceWrapped(parser);
}
pub fn janet_parser_status(parser: *types.JanetParser) callconv(.c) types.JanetParserStatus {
    return impl.parser.parserStatus(parser);
}
comptime {
    if (options.parser) {
        publish("janet_parser_consume", &impl.parser.consumeAbi, fn (*types.JanetParser, u8) callconv(.c) void);
        publish("janet_parser_eof", &impl.parser.eofAbi, fn (*types.JanetParser) callconv(.c) void);
        @export(&janet_lib_parse, .{ .name = "janet_lib_parse", .visibility = .hidden });
        @export(&janet_parser_clone, .{ .name = "janet_parser_clone", .visibility = .hidden });
        @export(&janet_parser_deinit, .{ .name = "janet_parser_deinit" });
        @export(&janet_parser_error, .{ .name = "janet_parser_error" });
        @export(&janet_parser_flush, .{ .name = "janet_parser_flush" });
        @export(&janet_parser_has_more, .{ .name = "janet_parser_has_more" });
        @export(&janet_parser_init, .{ .name = "janet_parser_init" });
        @export(&janet_parser_produce, .{ .name = "janet_parser_produce" });
        @export(&janet_parser_produce_wrapped, .{ .name = "janet_parser_produce_wrapped" });
        @export(&janet_parser_status, .{ .name = "janet_parser_status" });
    }
}

// peg.zig
//
pub fn janet_lib_peg(env: *types.JanetTable) callconv(.c) void {
    return impl.peg.libPegAbi(env);
}
comptime {
    if (options.peg_engine) {
        @export(&janet_lib_peg, .{ .name = "janet_lib_peg", .visibility = .hidden });
    }
}

// pp.zig
//
pub fn janet_to_string_b(buffer: *types.JanetBuffer, x: repr.Value) callconv(.c) void {
    return impl.pp.toStringBAbi(buffer, x);
}
pub fn janet_description_b(buffer: *types.JanetBuffer, x: repr.Value) callconv(.c) void {
    return impl.pp.descriptionBAbi(buffer, x);
}
pub fn janet_description(x: repr.Value) callconv(.c) types.JanetString {
    return impl.pp.description(x);
}
pub fn janet_to_string(x: repr.Value) callconv(.c) types.JanetString {
    return impl.pp.toString(x);
}
comptime {
    if (options.pp) {
        @export(&janet_to_string_b, .{ .name = "janet_to_string_b" });
        @export(&janet_description_b, .{ .name = "janet_description_b" });
        @export(&janet_description, .{ .name = "janet_description" });
        @export(&janet_to_string, .{ .name = "janet_to_string" });
    }
}

// pp/format.zig
//
comptime {
    if (options.pp and options.pp) {
        publishHidden("janet_buffer_format", &impl.pp_format.bufferFormatPanicking, fn (*types.JanetBuffer, [*]const u8, i32, i32, [*]repr.Value) callconv(.c) void);
    }
}

// pp/pretty.zig
//
pub fn janet_pretty(buffer: ?*types.JanetBuffer, depth: c_int, flags: c_int, x: repr.Value) callconv(.c) *types.JanetBuffer {
    return impl.pp_pretty.prettyPublic(buffer, depth, flags, x);
}
comptime {
    if (options.pp) {
        @export(&janet_pretty, .{ .name = "janet_pretty" });
    }
}

// registry.zig
//
pub fn janet_core_def_sm(env: *types.JanetTable, name: [*:0]const u8, x: repr.Value, p: ?*const anyopaque, sf: ?*const anyopaque, sl: i32) callconv(.c) void {
    return impl.registry.coreDefSm(env, name, x, p, sf, sl);
}
pub fn janet_core_cfuns_ext(env: *types.JanetTable, regprefix: ?[*:0]const u8, registrations: [*]const types.Reg) callconv(.c) void {
    return impl.registry.coreCfunsExt(env, regprefix, registrations);
}
pub fn janet_binding_from_entry(entry: repr.Value) callconv(.c) types.JanetBinding {
    return impl.registry.bindingFromEntry(entry);
}
pub fn janet_cfuns_ext(env: ?*types.JanetTable, regprefix: ?[*:0]const u8, registrations: [*]const types.Reg) callconv(.c) void {
    installSentinel(types.Reg, env, regprefix, false, registrations);
}
/// The narrow registration row, which is `janet.h`'s `JanetReg`.
///
/// The runtime has one `Reg` -- `DESIGN.md` section 6 -- and this is the
/// boundary type the two published narrow entry points still receive. It lives
/// here and nowhere else: no runtime file spells it.
pub const CReg = extern struct {
    name: ?[*:0]const u8 = null,
    cfun: types.JanetCFunction = null,
    documentation: ?[*:0]const u8 = null,
};

/// Walk a null-name-terminated C table into the installer.
///
/// This is the sentinel adapter `DESIGN.md` section 6 keeps: a boundary that
/// actually receives a C table. Internally a registration table is a slice and
/// its length is known at comptime.
fn installSentinel(
    comptime Row: type,
    env: ?*types.JanetTable,
    regprefix: ?[*:0]const u8,
    prefixed: bool,
    registrations: [*]const Row,
) void {
    var it = impl.registry.Installer.init(env, regprefix, prefixed);
    defer it.deinit();
    var row = registrations;
    while (row[0].name != null) : (row += 1) {
        it.put(if (Row == CReg) .{
            .name = row[0].name,
            .cfun = row[0].cfun,
            .documentation = row[0].documentation,
        } else row[0]);
    }
}

pub fn janet_cfuns_ext_prefix(env: ?*types.JanetTable, regprefix: ?[*:0]const u8, registrations: [*]const types.Reg) callconv(.c) void {
    installSentinel(types.Reg, env, regprefix, true, registrations);
}
pub fn janet_cfuns_prefix(env: ?*types.JanetTable, regprefix: ?[*:0]const u8, registrations: [*]const CReg) callconv(.c) void {
    installSentinel(CReg, env, regprefix, true, registrations);
}
pub fn janet_def(env: *types.JanetTable, name: [*:0]const u8, val: repr.Value, doc: ?[*:0]const u8) callconv(.c) void {
    return impl.registry.def(env, name, val, doc);
}
pub fn janet_def_sm(env: *types.JanetTable, name: [*:0]const u8, val: repr.Value, doc: ?[*:0]const u8, source_file: ?[*:0]const u8, source_line: i32) callconv(.c) void {
    return impl.registry.defSm(env, name, val, doc, source_file, source_line);
}
pub fn janet_get_abstract_type(key: repr.Value) callconv(.c) ?*const types.AbstractType {
    return impl.registry.getAbstractType(key);
}
pub fn janet_get_core_table(name: [*:0]const u8) callconv(.c) ?*types.JanetTable {
    return impl.registry.getCoreTable(name);
}
pub fn janet_register(name: ?[*:0]const u8, cfun: types.JanetCFunction) callconv(.c) void {
    return impl.registry.register(name, cfun);
}
pub fn janet_registry_get(key: types.JanetCFunction) callconv(.c) ?*types.JanetCFunRegistry {
    return impl.registry.registryGet(key);
}
pub fn janet_registry_put(key: types.JanetCFunction, name: ?[*:0]const u8, name_prefix: ?[*:0]const u8, source_file: ?[*:0]const u8, source_line: i32) callconv(.c) void {
    return impl.registry.registryPut(key, name, name_prefix, source_file, source_line);
}
pub fn janet_resolve(env: *types.JanetTable, sym: [*:0]const u8, out: *repr.Value) callconv(.c) types.JanetBindingType {
    return impl.registry.resolve(env, sym, out);
}
pub fn janet_resolve_core(name: [*:0]const u8) callconv(.c) repr.Value {
    return impl.registry.resolveCore(name);
}
pub fn janet_resolve_ext(env: *types.JanetTable, sym: [*:0]const u8) callconv(.c) types.JanetBinding {
    return impl.registry.resolveExt(env, sym);
}
pub fn janet_var_sm(env: *types.JanetTable, name: [*:0]const u8, val: repr.Value, doc: ?[*:0]const u8, source_file: ?[*:0]const u8, source_line: i32) callconv(.c) void {
    return impl.registry.varSmAbi(env, name, val, doc, source_file, source_line);
}
pub fn janet_var(env: *types.JanetTable, name: [*:0]const u8, val: repr.Value, doc: ?[*:0]const u8) callconv(.c) void {
    return impl.registry.defVarAbi(env, name, val, doc);
}
pub fn janet_cfuns(env: ?*types.JanetTable, regprefix: ?[*:0]const u8, registrations: [*]const CReg) callconv(.c) void {
    installSentinel(CReg, env, regprefix, false, registrations);
}
comptime {
    if (options.registry and !config.bootstrap) {
        @export(&janet_core_def_sm, .{ .name = "janet_core_def_sm", .visibility = .hidden });
        @export(&janet_core_cfuns_ext, .{ .name = "janet_core_cfuns_ext", .visibility = .hidden });
    }
    if (options.registry) {
        publish("janet_register_abstract_type", &impl.registry.registerAbstractTypeAbi, fn (*const types.AbstractType) callconv(.c) void);
        @export(&janet_binding_from_entry, .{ .name = "janet_binding_from_entry", .visibility = .hidden });
        @export(&janet_cfuns_ext, .{ .name = "janet_cfuns_ext" });
        @export(&janet_cfuns_ext_prefix, .{ .name = "janet_cfuns_ext_prefix" });
        @export(&janet_cfuns_prefix, .{ .name = "janet_cfuns_prefix" });
        @export(&janet_def, .{ .name = "janet_def" });
        @export(&janet_def_sm, .{ .name = "janet_def_sm" });
        @export(&janet_get_abstract_type, .{ .name = "janet_get_abstract_type" });
        @export(&janet_get_core_table, .{ .name = "janet_get_core_table", .visibility = .hidden });
        @export(&janet_register, .{ .name = "janet_register" });
        @export(&janet_registry_get, .{ .name = "janet_registry_get", .visibility = .hidden });
        @export(&janet_registry_put, .{ .name = "janet_registry_put", .visibility = .hidden });
        @export(&janet_resolve, .{ .name = "janet_resolve" });
        @export(&janet_resolve_core, .{ .name = "janet_resolve_core" });
        @export(&janet_resolve_ext, .{ .name = "janet_resolve_ext" });
        @export(&janet_var_sm, .{ .name = "janet_var_sm" });
        @export(&janet_var, .{ .name = "janet_var" });
        @export(&janet_cfuns, .{ .name = "janet_cfuns" });
    }
}

// scan.zig
//
pub fn janet_scan_numeric(str: ?[*]const u8, len: i32, out: *repr.Value) callconv(.c) c_int {
    return impl.scan.scanNumeric(cbytes(str, len), out);
}
pub fn janet_buffer_dtostr(buffer: *types.JanetBuffer, val: f64) callconv(.c) void {
    return impl.scan.bufferDtostrAbi(buffer, val);
}
pub fn janet_scan_number(str: ?[*]const u8, len: i32, out: *f64) callconv(.c) c_int {
    return impl.scan.scanNumber(cbytes(str, len), out);
}
pub fn janet_scan_number_base(str: [*]const u8, len: i32, base_arg: i32, out: *f64) callconv(.c) c_int {
    return impl.scan.scanNumberBase(str, len, base_arg, out);
}
pub fn janet_scan_int64(string: ?[*]const u8, length: i32, out: *i64) callconv(.c) c_int {
    return impl.scan.scanInt64(cbytes(string, length), out);
}
pub fn janet_scan_uint64(string: ?[*]const u8, length: i32, out: *u64) callconv(.c) c_int {
    return impl.scan.scanUint64(cbytes(string, length), out);
}
pub fn janet_is_symbol_char(character: u8) callconv(.c) c_int {
    return impl.scan.isSymbolChar(character);
}
pub fn janet_valid_utf8(string: ?[*]const u8, length: i32) callconv(.c) c_int {
    return impl.scan.validUtf8(cbytes(string, length));
}
comptime {
    if (options.scan and config.int_types) {
        @export(&janet_scan_numeric, .{ .name = "janet_scan_numeric" });
    }
    if (options.scan) {
        @export(&janet_buffer_dtostr, .{ .name = "janet_buffer_dtostr", .visibility = .hidden });
        @export(&janet_scan_number, .{ .name = "janet_scan_number" });
        @export(&janet_scan_number_base, .{ .name = "janet_scan_number_base" });
        @export(&janet_scan_int64, .{ .name = "janet_scan_int64" });
        @export(&janet_scan_uint64, .{ .name = "janet_scan_uint64" });
        @export(&janet_is_symbol_char, .{ .name = "janet_is_symbol_char", .visibility = .hidden });
        @export(&janet_valid_utf8, .{ .name = "janet_valid_utf8", .visibility = .hidden });
    }
}

// signal.zig
//
pub fn janet_top_level_signal(msg: [*]const u8) callconv(.c) noreturn {
    return impl.signal.topLevelSignal(msg);
}
pub fn janet_panic(message: [*:0]const u8) callconv(.c) void {
    return impl.signal.panic(message);
}
pub fn janet_panics(message: [*:0]const u8) callconv(.c) void {
    return impl.signal.panics(message);
}
pub fn janet_panicv(message: repr.Value) callconv(.c) void {
    return impl.signal.panicv(message);
}
pub fn janet_restore(state: *types.JanetTryState) callconv(.c) void {
    return impl.signal.restore(state);
}
pub fn janet_signalv(sig: c_uint, message: repr.Value) callconv(.c) void {
    return impl.signal.signalv(types.Signal.fromWire(sig), message);
}
pub fn janet_try_init(state: *types.JanetTryState) callconv(.c) void {
    return impl.signal.tryInit(state);
}
pub fn janet_zig_c_raise_clear() callconv(.c) void {
    return impl.signal.zigCRaiseClear();
}
pub fn janet_zig_c_raise_record() callconv(.c) void {
    return impl.signal.zigCRaiseRecord();
}
pub fn janet_zig_c_raise_take() callconv(.c) c_int {
    return impl.signal.zigCRaiseTake();
}
pub fn janet_zig_signal_record(sig: c_uint, message: repr.Value) callconv(.c) void {
    return impl.signal.zigSignalRecord(types.Signal.fromWire(sig), message);
}
comptime {
    if (options.signal) {
        @export(&janet_top_level_signal, .{ .name = "janet_top_level_signal", .visibility = .hidden });
        @export(&janet_panic, .{ .name = "janet_panic" });
        @export(&janet_panics, .{ .name = "janet_panics" });
        @export(&janet_panicv, .{ .name = "janet_panicv" });
        @export(&janet_restore, .{ .name = "janet_restore" });
        @export(&janet_signalv, .{ .name = "janet_signalv" });
        @export(&janet_try_init, .{ .name = "janet_try_init" });
        @export(&janet_zig_c_raise_clear, .{ .name = "janet_zig_c_raise_clear", .visibility = .hidden });
        @export(&janet_zig_c_raise_record, .{ .name = "janet_zig_c_raise_record", .visibility = .hidden });
        @export(&janet_zig_c_raise_take, .{ .name = "janet_zig_c_raise_take" });
        @export(&janet_zig_signal_record, .{ .name = "janet_zig_signal_record" });
    }
}

// stretchy.zig
//
comptime {
    if (options.stretchy) {}
}

// utils.zig
//
pub fn janet_strerror(e: c_int) callconv(.c) [*:0]const u8 {
    return impl.utils.strerrorSafe(e);
}
pub fn get_processed_name(name: [*]const u8) callconv(.c) [*]u8 {
    return impl.utils.getProcessedName(name);
}
pub fn janet_abstract_head(abstract: ?*const anyopaque) callconv(.c) *types.JanetAbstractHead {
    return impl.utils.abstractHead(abstract);
}
pub fn janet_calloc(nmemb: usize, size: usize) callconv(.c) ?*anyopaque {
    return impl.utils.calloc(nmemb, size);
}
pub fn janet_cryptorand(out: [*]u8, n: usize) callconv(.c) c_int {
    return impl.utils.cryptorand(out, n);
}
pub fn janet_cstrcmp(str: [*:0]const u8, other: [*:0]const u8) callconv(.c) c_int {
    return impl.utils.cstrcmp(str, other);
}
pub fn janet_free(ptr: ?*anyopaque) callconv(.c) void {
    return impl.utils.free(ptr);
}
pub fn janet_malloc(size: usize) callconv(.c) ?*anyopaque {
    return impl.utils.malloc(size);
}
pub fn janet_realloc(ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    return impl.utils.realloc(ptr, size);
}
pub fn janet_sorted_keys(dict: [*]const types.JanetKV, cap: i32, index_buffer: ?[*]i32) callconv(.c) i32 {
    return impl.utils.sortedKeys(dict, cap, index_buffer);
}
pub fn janet_strbinsearch(tab: ?*const anyopaque, tabcount: usize, itemsize: usize, key: [*:0]const u8) callconv(.c) ?*const anyopaque {
    return impl.utils.strbinsearch(tab, tabcount, itemsize, key);
}
pub fn janet_string_head(s: [*]const u8) callconv(.c) *types.JanetStringHead {
    return impl.utils.stringHead(s);
}
pub fn janet_struct_head(st: [*]const types.JanetKV) callconv(.c) *types.JanetStructHead {
    return impl.utils.structHead(st);
}
pub fn janet_tuple_head(tuple: [*]const repr.Value) callconv(.c) *types.JanetTupleHead {
    return impl.utils.tupleHead(tuple);
}
pub fn safe_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void {
    return impl.utils.safeMemcpy(dest, src, len);
}
comptime {
    if (options.utilities) {
        @export(&janet_strerror, .{ .name = "janet_strerror", .visibility = .hidden });
        @export(&get_processed_name, .{ .name = "get_processed_name", .visibility = .hidden });
        @export(&janet_abstract_head, .{ .name = "janet_abstract_head" });
        @export(&janet_calloc, .{ .name = "janet_calloc" });
        @export(&janet_cryptorand, .{ .name = "janet_cryptorand" });
        @export(&janet_cstrcmp, .{ .name = "janet_cstrcmp" });
        @export(&janet_free, .{ .name = "janet_free" });
        @export(&janet_malloc, .{ .name = "janet_malloc" });
        @export(&janet_realloc, .{ .name = "janet_realloc" });
        @export(&janet_sorted_keys, .{ .name = "janet_sorted_keys" });
        @export(&janet_strbinsearch, .{ .name = "janet_strbinsearch", .visibility = .hidden });
        @export(&janet_string_head, .{ .name = "janet_string_head" });
        @export(&janet_struct_head, .{ .name = "janet_struct_head" });
        @export(&janet_tuple_head, .{ .name = "janet_tuple_head" });
        @export(&safe_memcpy, .{ .name = "safe_memcpy", .visibility = .hidden });
        publishHidden("janet_base64", &impl.utils.base64, [65]u8);
        publish("janet_signal_names", &impl.utils.signalNames, [14][*:0]const u8);
        publish("janet_status_names", &impl.utils.statusNames, [16][*:0]const u8);
        publish("janet_type_names", &impl.utils.typeNames, [16][*:0]const u8);
    }
}

// value.zig
//
pub fn janet_init_hash_key(new_key: [*]u8) callconv(.c) void {
    return impl.value.initHashKey(new_key);
}
/// A `(pointer, count)` pair from a C caller, as a slice.
///
/// The published signatures take an `int32_t` and admit a null pointer, and
/// `janet.h`'s callers use both: `janet_string_calchash(NULL, 0)` is the hash
/// of nothing, and every one of these functions read nothing from a negative
/// count rather than walking backwards. Neither state is representable in a
/// `[]const u8`, so this is where they stop being possible.
inline fn cbytes(ptr: ?[*]const u8, count: i32) []const u8 {
    if (count <= 0) return &.{};
    if (ptr) |p| return p[0..@intCast(count)];
    return &.{};
}

pub fn janet_string_calchash(string: ?[*]const u8, length: i32) callconv(.c) i32 {
    return impl.value.hashBytes(cbytes(string, length));
}
pub fn janet_array_calchash(array: ?[*]const repr.Value, len: i32) callconv(.c) i32 {
    return impl.value.hashIndexed(if (array) |p| p[0..@intCast(len)] else &.{});
}
pub fn janet_kv_calchash(kvs: ?[*]const types.JanetKV, len: i32) callconv(.c) i32 {
    return impl.value.hashDictionary(if (kvs) |p| p[0..@intCast(len)] else &.{});
}
pub fn janet_hash_mix(input: u32, more: u32) callconv(.c) u32 {
    return impl.value.hashMix(input, more);
}
pub fn janet_tablen(val: i32) callconv(.c) i32 {
    return impl.value.capacityFor(val);
}
pub fn janet_dict_find(buckets: [*]const types.JanetKV, cap: i32, key: repr.Value) callconv(.c) ?*const types.JanetKV {
    return impl.value.dictionaryFind(buckets[0..@intCast(cap)], key);
}
pub fn janet_dict_find_keyword(buckets: [*]const types.JanetKV, cap: i32, cstr: [*]const u8, cstr_len: i32) callconv(.c) ?*const types.JanetKV {
    return impl.value.dictionaryFindKeyword(buckets[0..@intCast(cap)], cstr, cstr_len);
}
pub fn janet_dictionary_get(data: [*]const types.JanetKV, cap: i32, key: repr.Value) callconv(.c) repr.Value {
    return impl.value.dictionaryGet(data[0..@intCast(cap)], key);
}
pub fn janet_dictionary_next(kvs: [*]const types.JanetKV, cap: i32, kv: ?*const types.JanetKV) callconv(.c) ?*const types.JanetKV {
    return impl.value.dictionaryNext(kvs[0..@intCast(cap)], kv);
}
comptime {
    if (config.prf) {
        @export(&janet_init_hash_key, .{ .name = "janet_init_hash_key" });
    }
    @export(&janet_string_calchash, .{ .name = "janet_string_calchash", .visibility = .hidden });
    @export(&janet_array_calchash, .{ .name = "janet_array_calchash", .visibility = .hidden });
    @export(&janet_kv_calchash, .{ .name = "janet_kv_calchash", .visibility = .hidden });
    @export(&janet_hash_mix, .{ .name = "janet_hash_mix", .visibility = .hidden });
    @export(&janet_tablen, .{ .name = "janet_tablen", .visibility = .hidden });
    @export(&janet_dict_find, .{ .name = "janet_dict_find", .visibility = .hidden });
    @export(&janet_dict_find_keyword, .{ .name = "janet_dict_find_keyword", .visibility = .hidden });
    @export(&janet_dictionary_get, .{ .name = "janet_dictionary_get" });
    @export(&janet_dictionary_next, .{ .name = "janet_dictionary_next" });
}

// value/abstracts.zig
//
pub fn janet_abstract_begin_threaded(atype: *const types.AbstractType, size: usize) callconv(.c) ?*anyopaque {
    return impl.value_abstracts.beginThreaded(atype, size);
}
pub fn janet_abstract_end_threaded(x: ?*anyopaque) callconv(.c) ?*anyopaque {
    return impl.value_abstracts.endThreaded(x);
}
pub fn janet_abstract_threaded(atype: *const types.AbstractType, size: usize) callconv(.c) ?*anyopaque {
    return impl.value_abstracts.threaded(atype, size);
}
pub fn janet_abstract_incref(abst: ?*anyopaque) callconv(.c) i32 {
    return impl.value_abstracts.incref(abst);
}
pub fn janet_abstract_decref(abst: ?*anyopaque) callconv(.c) i32 {
    return impl.value_abstracts.decref(abst);
}
pub fn janet_abstract_decref_maybe_free(abst: ?*anyopaque) callconv(.c) i32 {
    return impl.value_abstracts.decrefMaybeFree(abst);
}
pub fn janet_abstract(atype: *const types.AbstractType, size: usize) callconv(.c) ?*anyopaque {
    return impl.value_abstracts.new(atype, size);
}
pub fn janet_abstract_begin(atype: *const types.AbstractType, size: usize) callconv(.c) ?*anyopaque {
    return impl.value_abstracts.begin(atype, size);
}
pub fn janet_abstract_end(x: ?*anyopaque) callconv(.c) ?*anyopaque {
    return impl.value_abstracts.end(x);
}
pub fn janet_atomic_dec(x: *volatile types.JanetAtomicInt) callconv(.c) types.JanetAtomicInt {
    return impl.value_abstracts.atomicDec(x);
}
pub fn janet_atomic_inc(x: *volatile types.JanetAtomicInt) callconv(.c) types.JanetAtomicInt {
    return impl.value_abstracts.atomicInc(x);
}
pub fn janet_atomic_load(x: *volatile types.JanetAtomicInt) callconv(.c) types.JanetAtomicInt {
    return impl.value_abstracts.atomicLoad(x);
}
pub fn janet_atomic_load_relaxed(x: *volatile types.JanetAtomicInt) callconv(.c) types.JanetAtomicInt {
    return impl.value_abstracts.atomicLoadRelaxed(x);
}
comptime {
    if (options.abstracts and config.ev) {
        @export(&janet_abstract_begin_threaded, .{ .name = "janet_abstract_begin_threaded" });
        @export(&janet_abstract_end_threaded, .{ .name = "janet_abstract_end_threaded" });
        @export(&janet_abstract_threaded, .{ .name = "janet_abstract_threaded" });
        @export(&janet_abstract_incref, .{ .name = "janet_abstract_incref" });
        @export(&janet_abstract_decref, .{ .name = "janet_abstract_decref" });
        @export(&janet_abstract_decref_maybe_free, .{ .name = "janet_abstract_decref_maybe_free" });
    }
    if (options.abstracts) {
        @export(&janet_abstract, .{ .name = "janet_abstract" });
        @export(&janet_abstract_begin, .{ .name = "janet_abstract_begin" });
        @export(&janet_abstract_end, .{ .name = "janet_abstract_end" });
        @export(&janet_atomic_dec, .{ .name = "janet_atomic_dec" });
        @export(&janet_atomic_inc, .{ .name = "janet_atomic_inc" });
        @export(&janet_atomic_load, .{ .name = "janet_atomic_load" });
        @export(&janet_atomic_load_relaxed, .{ .name = "janet_atomic_load_relaxed" });
    }
}

// value/arrays.zig
//
pub fn janet_array_push(array: *types.JanetArray, x: repr.Value) callconv(.c) void {
    return impl.value_arrays.pushAbi(array, x);
}
pub fn janet_array(capacity: i32) callconv(.c) *types.JanetArray {
    return impl.value_arrays.new(capacity);
}
pub fn janet_array_weak(capacity: i32) callconv(.c) *types.JanetArray {
    return impl.value_arrays.weak(capacity);
}
pub fn janet_array_n(elements: [*]const repr.Value, count: i32) callconv(.c) *types.JanetArray {
    return impl.value_arrays.newFrom(elements[0..@intCast(count)]);
}
pub fn janet_array_ensure(array: *types.JanetArray, capacity_in: i32, growth: i32) callconv(.c) void {
    return impl.value_arrays.ensure(array, capacity_in, growth);
}
pub fn janet_array_setcount(array: *types.JanetArray, count: i32) callconv(.c) void {
    return impl.value_arrays.setcount(array, count);
}
pub fn janet_array_pop(array: *types.JanetArray) callconv(.c) repr.Value {
    return impl.value_arrays.pop(array);
}
pub fn janet_array_peek(array: *types.JanetArray) callconv(.c) repr.Value {
    return impl.value_arrays.peek(array);
}
pub fn janet_lib_array(env: *types.JanetTable) callconv(.c) void {
    return impl.value_arrays.lib(env);
}
comptime {
    if (options.arrays) {
        @export(&janet_array_push, .{ .name = "janet_array_push" });
        @export(&janet_array, .{ .name = "janet_array" });
        @export(&janet_array_weak, .{ .name = "janet_array_weak" });
        @export(&janet_array_n, .{ .name = "janet_array_n" });
        @export(&janet_array_ensure, .{ .name = "janet_array_ensure" });
        @export(&janet_array_setcount, .{ .name = "janet_array_setcount" });
        @export(&janet_array_pop, .{ .name = "janet_array_pop" });
        @export(&janet_array_peek, .{ .name = "janet_array_peek" });
        @export(&janet_lib_array, .{ .name = "janet_lib_array", .visibility = .hidden });
    }
}

// value/buffers.zig
//
pub fn janet_buffer_ensure(buffer: *types.JanetBuffer, capacity_in: i32, growth: i32) callconv(.c) void {
    return impl.value_buffers.ensureAbi(buffer, capacity_in, growth);
}
pub fn janet_buffer_setcount(buffer: *types.JanetBuffer, count: i32) callconv(.c) void {
    return impl.value_buffers.setcountAbi(buffer, count);
}
pub fn janet_buffer_extra(buffer: *types.JanetBuffer, n: i32) callconv(.c) void {
    return impl.value_buffers.extraAbi(buffer, n);
}
pub fn janet_pointer_buffer_unsafe(memory: ?*anyopaque, capacity: i32, count: i32) callconv(.c) *types.JanetBuffer {
    return impl.value_buffers.pointerUnsafeAbi(memory, capacity, count);
}
pub fn janet_buffer_push_bytes(buffer: *types.JanetBuffer, string: ?[*]const u8, length: i32) callconv(.c) void {
    return impl.value_buffers.pushBytesAbi(buffer, cbytes(string, length));
}
pub fn janet_buffer_push_string(buffer: *types.JanetBuffer, string: [*]const u8) callconv(.c) void {
    return impl.value_buffers.pushStringAbi(buffer, string);
}
pub fn janet_buffer_push_u8(buffer: *types.JanetBuffer, byte: u8) callconv(.c) void {
    return impl.value_buffers.pushU8Abi(buffer, byte);
}
pub fn janet_buffer_push_u16(buffer: *types.JanetBuffer, x: u16) callconv(.c) void {
    return impl.value_buffers.pushU16Abi(buffer, x);
}
pub fn janet_buffer_push_u32(buffer: *types.JanetBuffer, x: u32) callconv(.c) void {
    return impl.value_buffers.pushU32Abi(buffer, x);
}
pub fn janet_buffer_push_u64(buffer: *types.JanetBuffer, x: u64) callconv(.c) void {
    return impl.value_buffers.pushU64Abi(buffer, x);
}
pub fn janet_buffer(capacity: i32) callconv(.c) *types.JanetBuffer {
    return impl.value_buffers.new(capacity);
}
pub fn janet_buffer_init(buffer: *types.JanetBuffer, capacity: i32) callconv(.c) *types.JanetBuffer {
    return impl.value_buffers.init(buffer, capacity);
}
pub fn janet_buffer_deinit(buffer: *types.JanetBuffer) callconv(.c) void {
    return impl.value_buffers.deinit(buffer);
}
pub fn janet_buffer_push_cstring(buffer: *types.JanetBuffer, cstring: [*:0]const u8) callconv(.c) void {
    return impl.value_buffers.pushCstringAbi(buffer, cstring);
}
pub fn janet_lib_buffer(env: *types.JanetTable) callconv(.c) void {
    return impl.value_buffers.lib(env);
}
comptime {
    if (options.buffers) {
        @export(&janet_buffer_ensure, .{ .name = "janet_buffer_ensure" });
        @export(&janet_buffer_setcount, .{ .name = "janet_buffer_setcount" });
        @export(&janet_buffer_extra, .{ .name = "janet_buffer_extra" });
        @export(&janet_pointer_buffer_unsafe, .{ .name = "janet_pointer_buffer_unsafe" });
        @export(&janet_buffer_push_bytes, .{ .name = "janet_buffer_push_bytes" });
        @export(&janet_buffer_push_string, .{ .name = "janet_buffer_push_string" });
        @export(&janet_buffer_push_u8, .{ .name = "janet_buffer_push_u8" });
        @export(&janet_buffer_push_u16, .{ .name = "janet_buffer_push_u16" });
        @export(&janet_buffer_push_u32, .{ .name = "janet_buffer_push_u32" });
        @export(&janet_buffer_push_u64, .{ .name = "janet_buffer_push_u64" });
        @export(&janet_buffer, .{ .name = "janet_buffer" });
        @export(&janet_buffer_init, .{ .name = "janet_buffer_init" });
        @export(&janet_buffer_deinit, .{ .name = "janet_buffer_deinit" });
        @export(&janet_buffer_push_cstring, .{ .name = "janet_buffer_push_cstring" });
        @export(&janet_lib_buffer, .{ .name = "janet_lib_buffer", .visibility = .hidden });
    }
}

// value/fibers.zig
//
pub fn janet_fiber(callee: *types.JanetFunction, capacity: i32, argc: i32, argv: ?[*]const repr.Value) callconv(.c) ?*types.JanetFiber {
    return impl.value_fibers.new(callee, capacity, argc, argv);
}
pub fn janet_fiber_reset(fiber: *types.JanetFiber, callee: *types.JanetFunction, argc: i32, argv: ?[*]const repr.Value) callconv(.c) ?*types.JanetFiber {
    return impl.value_fibers.reset(fiber, callee, argc, argv);
}
pub fn janet_current_fiber() callconv(.c) ?*types.JanetFiber {
    return impl.value_fibers.current();
}
pub fn janet_fiber_can_resume(fiber: *types.JanetFiber) callconv(.c) c_int {
    return impl.value_fibers.canResume(fiber);
}
pub fn janet_fiber_status(f: *types.JanetFiber) callconv(.c) types.FiberStatus {
    return impl.value_fibers.status(f);
}
pub fn janet_lib_fiber(env: *types.JanetTable) callconv(.c) void {
    return impl.value_fibers.libAbi(env);
}
pub fn janet_root_fiber() callconv(.c) ?*types.JanetFiber {
    return impl.value_fibers.root();
}
comptime {
    if (options.fibers) {
        @export(&janet_fiber, .{ .name = "janet_fiber" });
        @export(&janet_fiber_reset, .{ .name = "janet_fiber_reset" });
        @export(&janet_current_fiber, .{ .name = "janet_current_fiber" });
        @export(&janet_fiber_can_resume, .{ .name = "janet_fiber_can_resume" });
        @export(&janet_fiber_status, .{ .name = "janet_fiber_status" });
        @export(&janet_lib_fiber, .{ .name = "janet_lib_fiber", .visibility = .hidden });
        @export(&janet_root_fiber, .{ .name = "janet_root_fiber" });
    }
}

// value/functions.zig
//
pub fn janet_thunk(def: *types.JanetFuncDef) callconv(.c) *types.JanetFunction {
    return impl.value_functions.thunk(def);
}
pub fn janet_thunk_delay(x: repr.Value) callconv(.c) *types.JanetFunction {
    return impl.value_functions.thunkDelay(x);
}
comptime {
    if (options.functions) {
        publish("janet_funcdef_alloc", &impl.value_functions.defs.new, fn () callconv(.c) *types.JanetFuncDef);
        @export(&janet_thunk, .{ .name = "janet_thunk" });
        @export(&janet_thunk_delay, .{ .name = "janet_thunk_delay" });
    }
}

// value/helpers/access.zig
//
pub fn janet_next(ds: repr.Value, key: repr.Value) callconv(.c) repr.Value {
    return impl.value_helpers_access.nextAbi(ds, key);
}
pub fn janet_in(ds: repr.Value, key: repr.Value) callconv(.c) repr.Value {
    return impl.value_helpers_access.inAbi(ds, key);
}
pub fn janet_get(ds: repr.Value, key: repr.Value) callconv(.c) repr.Value {
    return impl.value_helpers_access.getAbi(ds, key);
}
pub fn janet_length(x: repr.Value) callconv(.c) i32 {
    return impl.value_helpers_access.lengthAbi(x);
}
pub fn janet_lengthv(x: repr.Value) callconv(.c) repr.Value {
    return impl.value_helpers_access.lengthvAbi(x);
}
pub fn janet_put(ds: repr.Value, key: repr.Value, val: repr.Value) callconv(.c) void {
    return impl.value_helpers_access.putAbi(ds, key, val);
}
pub fn janet_getindex(ds: repr.Value, index: i32) callconv(.c) repr.Value {
    return impl.value_helpers_access.getindexAbi(ds, index);
}
pub fn janet_putindex(ds: repr.Value, index: i32, val: repr.Value) callconv(.c) void {
    return impl.value_helpers_access.putindexAbi(ds, index, val);
}
comptime {
    if (options.access) {
        @export(&janet_next, .{ .name = "janet_next" });
        @export(&janet_in, .{ .name = "janet_in" });
        @export(&janet_get, .{ .name = "janet_get" });
        @export(&janet_length, .{ .name = "janet_length" });
        @export(&janet_lengthv, .{ .name = "janet_lengthv" });
        @export(&janet_put, .{ .name = "janet_put" });
        @export(&janet_getindex, .{ .name = "janet_getindex" });
        @export(&janet_putindex, .{ .name = "janet_putindex" });
    }
}

// repr.zig -- the four type predicates
//
// `c_uint` rather than `repr.Tag`: the tag is four bits and an `enum(u4)` is
// not extern compatible, so the published width is the C one and the
// conversion is here. That is principle 2 at the value representation -- the
// width at the boundary and the width of the truth are different questions.
//
// They are `repr`'s, and `repr` is a module below `types` that every
// configuration compiles, so there is nothing to gate on.
pub fn janet_type(x: repr.Value) callconv(.c) c_uint {
    return @intFromEnum(repr.typeOf(x));
}
pub fn janet_checktype(x: repr.Value, t: c_uint) callconv(.c) c_int {
    if (t >= repr.tag_count) return 0;
    return @intFromBool(repr.checkType(x, @enumFromInt(t)));
}
// `janet_checktypes` answers the *masked bit* rather than a normalized
// boolean, because `janet.h`'s did and a C caller may compare against the
// bit; `test/value_wrap.zig` pins it. A mask bit above fifteen names no tag,
// so narrowing the caller's `int` to the set's sixteen loses nothing.
pub fn janet_checktypes(x: repr.Value, typeflags: c_int) callconv(.c) c_int {
    return @as(c_int, repr.TagSet.one(repr.typeOf(x)).bits()) & typeflags;
}
pub fn janet_truthy(x: repr.Value) callconv(.c) c_int {
    return @intFromBool(repr.truthy(x));
}
comptime {
    @export(&janet_type, .{ .name = "janet_type" });
    @export(&janet_checktype, .{ .name = "janet_checktype" });
    @export(&janet_checktypes, .{ .name = "janet_checktypes" });
    @export(&janet_truthy, .{ .name = "janet_truthy" });
}

// value/helpers/order.zig
//
pub fn janet_compare(x_in: repr.Value, y_in: repr.Value) callconv(.c) c_int {
    return impl.value_helpers_order.compare(x_in, y_in);
}
pub fn janet_equals(x_in: repr.Value, y_in: repr.Value) callconv(.c) c_int {
    return impl.value_helpers_order.equals(x_in, y_in);
}
pub fn janet_hash(x: repr.Value) callconv(.c) i32 {
    return impl.value_helpers_order.hash(x);
}
comptime {
    if (options.order) {
        @export(&janet_compare, .{ .name = "janet_compare" });
        @export(&janet_equals, .{ .name = "janet_equals" });
        @export(&janet_hash, .{ .name = "janet_hash" });
    }
}

// value/helpers/wrap.zig
//
pub fn janet_nanbox_to_pointer(x: repr.Value) callconv(.c) ?*anyopaque {
    return impl.value_helpers_wrap.nanboxToPointer(x);
}
pub fn janet_nanbox_from_pointer(p: ?*anyopaque, tagmask: u64) callconv(.c) repr.Value {
    return impl.value_helpers_wrap.nanboxFromPointer(p, tagmask);
}
pub fn janet_nanbox_from_cpointer(p: ?*const anyopaque, tagmask: u64) callconv(.c) repr.Value {
    return impl.value_helpers_wrap.nanboxFromCPointer(p, tagmask);
}
pub fn janet_nanbox_from_double(d: f64) callconv(.c) repr.Value {
    return impl.value_helpers_wrap.nanboxFromDouble(d);
}
pub fn janet_nanbox_from_bits(bits: u64) callconv(.c) repr.Value {
    return impl.value_helpers_wrap.nanboxFromBits(bits);
}
pub fn janet_nanbox32_from_tagi(t: u32, integer: i32) callconv(.c) repr.Value {
    return impl.value_helpers_wrap.nanbox32FromTagI(t, integer);
}
pub fn janet_nanbox32_from_tagp(t: u32, p: ?*anyopaque) callconv(.c) repr.Value {
    return impl.value_helpers_wrap.nanbox32FromTagP(t, p);
}
pub fn janet_memalloc_empty(count: i32) callconv(.c) ?*anyopaque {
    return impl.value.memallocEmpty(count);
}
pub fn janet_memempty(mem: [*]types.JanetKV, count: i32) callconv(.c) void {
    return impl.value.memempty(mem[0..@intCast(count)]);
}
pub fn janet_unwrap_abstract(x: repr.Value) callconv(.c) types.JanetAbstract {
    return impl.value_helpers_wrap.toAbstract(x);
}
pub fn janet_unwrap_array(x: repr.Value) callconv(.c) *types.JanetArray {
    return impl.value_helpers_wrap.toArray(x);
}
pub fn janet_unwrap_boolean(x: repr.Value) callconv(.c) c_int {
    return @intFromBool(impl.value_helpers_wrap.toBoolean(x));
}
pub fn janet_unwrap_buffer(x: repr.Value) callconv(.c) *types.JanetBuffer {
    return impl.value_helpers_wrap.toBuffer(x);
}
pub fn janet_unwrap_cfunction(x: repr.Value) callconv(.c) types.JanetCFunction {
    return impl.value_helpers_wrap.toCfunction(x);
}
pub fn janet_unwrap_fiber(x: repr.Value) callconv(.c) *types.JanetFiber {
    return impl.value_helpers_wrap.toFiber(x);
}
pub fn janet_unwrap_function(x: repr.Value) callconv(.c) *types.JanetFunction {
    return impl.value_helpers_wrap.toFunction(x);
}
pub fn janet_unwrap_keyword(x: repr.Value) callconv(.c) types.JanetKeyword {
    return impl.value_helpers_wrap.toKeyword(x);
}
pub fn janet_unwrap_number(x: repr.Value) callconv(.c) f64 {
    return impl.value_helpers_wrap.toNumber(x);
}
pub fn janet_unwrap_string(x: repr.Value) callconv(.c) types.JanetString {
    return impl.value_helpers_wrap.toString(x);
}
pub fn janet_unwrap_struct(x: repr.Value) callconv(.c) types.JanetStruct {
    return impl.value_helpers_wrap.toStruct(x);
}
pub fn janet_unwrap_symbol(x: repr.Value) callconv(.c) types.JanetSymbol {
    return impl.value_helpers_wrap.toSymbol(x);
}
pub fn janet_unwrap_table(x: repr.Value) callconv(.c) *types.JanetTable {
    return impl.value_helpers_wrap.toTable(x);
}
pub fn janet_unwrap_tuple(x: repr.Value) callconv(.c) types.JanetTuple {
    return impl.value_helpers_wrap.toTuple(x);
}
pub fn janet_unwrap_integer(x: repr.Value) callconv(.c) i32 {
    return impl.value_helpers_wrap.toIntegerAbi(x);
}
pub fn janet_unwrap_pointer(x: repr.Value) callconv(.c) ?*anyopaque {
    return impl.value_helpers_wrap.toPointerAbi(x);
}
pub fn janet_wrap_number_safe(d: f64) callconv(.c) repr.Value {
    return impl.value_helpers_wrap.fromNumberSafe(d);
}
comptime {
    if (options.wrap and (config.value_repr != .tagged)) {
        publish("janet_wrap_integer", &impl.value_helpers_wrap.abi.fromInteger, fn (i32) callconv(.c) repr.Value);
    }
    if (options.wrap and config.value_repr == .nanbox_32) {
        @export(&janet_nanbox32_from_tagi, .{ .name = "janet_nanbox32_from_tagi" });
        @export(&janet_nanbox32_from_tagp, .{ .name = "janet_nanbox32_from_tagp" });
    }
    if (options.wrap and config.value_repr == .nanbox_64) {
        @export(&janet_nanbox_to_pointer, .{ .name = "janet_nanbox_to_pointer" });
        @export(&janet_nanbox_from_pointer, .{ .name = "janet_nanbox_from_pointer" });
        @export(&janet_nanbox_from_cpointer, .{ .name = "janet_nanbox_from_cpointer" });
        @export(&janet_nanbox_from_double, .{ .name = "janet_nanbox_from_double" });
        @export(&janet_nanbox_from_bits, .{ .name = "janet_nanbox_from_bits" });
    }
    if (options.wrap) {
        publish("janet_wrap_nil", &impl.value_helpers_wrap.abi.fromNil, fn () callconv(.c) repr.Value);
        publish("janet_wrap_boolean", &impl.value_helpers_wrap.abi.fromBoolean, fn (c_int) callconv(.c) repr.Value);
        publish("janet_wrap_true", &impl.value_helpers_wrap.abi.fromTrue, fn () callconv(.c) repr.Value);
        publish("janet_wrap_false", &impl.value_helpers_wrap.abi.fromFalse, fn () callconv(.c) repr.Value);
        publish("janet_wrap_number", &impl.value_helpers_wrap.abi.fromNumber, fn (f64) callconv(.c) repr.Value);
        publish("janet_wrap_string", &impl.value_helpers_wrap.abi.fromString, fn ([*:0]const u8) callconv(.c) repr.Value);
        publish("janet_wrap_symbol", &impl.value_helpers_wrap.abi.fromSymbol, fn ([*:0]const u8) callconv(.c) repr.Value);
        publish("janet_wrap_keyword", &impl.value_helpers_wrap.abi.fromKeyword, fn ([*:0]const u8) callconv(.c) repr.Value);
        publish("janet_wrap_array", &impl.value_helpers_wrap.abi.fromArray, fn (*types.JanetArray) callconv(.c) repr.Value);
        publish("janet_wrap_tuple", &impl.value_helpers_wrap.abi.fromTuple, fn ([*]const repr.Value) callconv(.c) repr.Value);
        publish("janet_wrap_struct", &impl.value_helpers_wrap.abi.fromStruct, fn ([*]const types.JanetKV) callconv(.c) repr.Value);
        publish("janet_wrap_fiber", &impl.value_helpers_wrap.abi.fromFiber, fn (?*types.JanetFiber) callconv(.c) repr.Value);
        publish("janet_wrap_buffer", &impl.value_helpers_wrap.abi.fromBuffer, fn (*types.JanetBuffer) callconv(.c) repr.Value);
        publish("janet_wrap_function", &impl.value_helpers_wrap.abi.fromFunction, fn (*types.JanetFunction) callconv(.c) repr.Value);
        publish("janet_wrap_cfunction", &impl.value_helpers_wrap.abi.fromCfunction, fn (types.JanetCFunction) callconv(.c) repr.Value);
        publish("janet_wrap_table", &impl.value_helpers_wrap.abi.fromTable, fn (*types.JanetTable) callconv(.c) repr.Value);
        publish("janet_wrap_abstract", &impl.value_helpers_wrap.abi.fromAbstract, fn (?*anyopaque) callconv(.c) repr.Value);
        publish("janet_wrap_pointer", &impl.value_helpers_wrap.abi.fromPointer, fn (?*anyopaque) callconv(.c) repr.Value);
        @export(&janet_memalloc_empty, .{ .name = "janet_memalloc_empty", .visibility = .hidden });
        @export(&janet_memempty, .{ .name = "janet_memempty", .visibility = .hidden });
        @export(&janet_unwrap_abstract, .{ .name = "janet_unwrap_abstract" });
        @export(&janet_unwrap_array, .{ .name = "janet_unwrap_array" });
        @export(&janet_unwrap_boolean, .{ .name = "janet_unwrap_boolean" });
        @export(&janet_unwrap_buffer, .{ .name = "janet_unwrap_buffer" });
        @export(&janet_unwrap_cfunction, .{ .name = "janet_unwrap_cfunction" });
        @export(&janet_unwrap_fiber, .{ .name = "janet_unwrap_fiber" });
        @export(&janet_unwrap_function, .{ .name = "janet_unwrap_function" });
        @export(&janet_unwrap_keyword, .{ .name = "janet_unwrap_keyword" });
        @export(&janet_unwrap_number, .{ .name = "janet_unwrap_number" });
        @export(&janet_unwrap_string, .{ .name = "janet_unwrap_string" });
        @export(&janet_unwrap_struct, .{ .name = "janet_unwrap_struct" });
        @export(&janet_unwrap_symbol, .{ .name = "janet_unwrap_symbol" });
        @export(&janet_unwrap_table, .{ .name = "janet_unwrap_table" });
        @export(&janet_unwrap_tuple, .{ .name = "janet_unwrap_tuple" });
        @export(&janet_unwrap_integer, .{ .name = "janet_unwrap_integer" });
        @export(&janet_unwrap_pointer, .{ .name = "janet_unwrap_pointer" });
        @export(&janet_wrap_number_safe, .{ .name = "janet_wrap_number_safe" });
    }
}

// value/ints.zig
//
pub fn janet_unwrap_s64(x: repr.Value) callconv(.c) i64 {
    return impl.value_ints.unwrapS64Abi(x);
}
pub fn janet_unwrap_u64(x: repr.Value) callconv(.c) u64 {
    return impl.value_ints.unwrapU64Abi(x);
}
pub fn janet_is_int(x: repr.Value) callconv(.c) types.JanetIntType {
    return impl.value_ints.isInt(x);
}
pub fn janet_lib_inttypes(env: *types.JanetTable) callconv(.c) void {
    return impl.value_ints.libInttypesAbi(env);
}
pub fn janet_wrap_s64(x: i64) callconv(.c) repr.Value {
    return impl.value_ints.wrapS64(x);
}
pub fn janet_wrap_u64(x: u64) callconv(.c) repr.Value {
    return impl.value_ints.wrapU64(x);
}
comptime {
    if (options.int_types_core) {
        @export(&janet_unwrap_s64, .{ .name = "janet_unwrap_s64" });
        @export(&janet_unwrap_u64, .{ .name = "janet_unwrap_u64" });
        @export(&janet_is_int, .{ .name = "janet_is_int" });
        @export(&janet_lib_inttypes, .{ .name = "janet_lib_inttypes", .visibility = .hidden });
        @export(&janet_wrap_s64, .{ .name = "janet_wrap_s64" });
        @export(&janet_wrap_u64, .{ .name = "janet_wrap_u64" });
    }
}

// value/strings.zig
//
pub fn janet_string(buf: ?[*]const u8, len: i32) callconv(.c) [*:0]const u8 {
    return impl.value_strings.new(cbytes(buf, len));
}
pub fn janet_string_begin(length: i32) callconv(.c) [*]u8 {
    return impl.value_strings.begin(length);
}
pub fn janet_string_end(str: [*]u8) callconv(.c) [*:0]const u8 {
    return impl.value_strings.end(str);
}
pub fn janet_string_compare(lhs: [*]const u8, rhs: [*]const u8) callconv(.c) c_int {
    return impl.value_strings.compare(lhs, rhs);
}
pub fn janet_string_equal(lhs: [*]const u8, rhs: [*]const u8) callconv(.c) c_int {
    return impl.value_strings.equal(lhs, rhs);
}
pub fn janet_string_equalconst(lhs: [*]const u8, rhs: ?[*]const u8, rlen: i32, rhash: i32) callconv(.c) c_int {
    return impl.value_strings.equalconst(lhs, cbytes(rhs, rlen), rhash);
}
pub fn janet_cstring(str: [*:0]const u8) callconv(.c) [*:0]const u8 {
    return impl.value_strings.cstring(str);
}
pub fn janet_lib_string(env: *types.JanetTable) callconv(.c) void {
    return impl.value_strings.lib(env);
}
comptime {
    if (options.strings) {
        @export(&janet_string, .{ .name = "janet_string" });
        @export(&janet_string_begin, .{ .name = "janet_string_begin" });
        @export(&janet_string_end, .{ .name = "janet_string_end" });
        @export(&janet_string_compare, .{ .name = "janet_string_compare" });
        @export(&janet_string_equal, .{ .name = "janet_string_equal" });
        @export(&janet_string_equalconst, .{ .name = "janet_string_equalconst" });
        @export(&janet_cstring, .{ .name = "janet_cstring" });
        @export(&janet_lib_string, .{ .name = "janet_lib_string", .visibility = .hidden });
    }
}

// value/structs.zig
//
pub fn janet_lib_struct(env: *types.JanetTable) callconv(.c) void {
    return impl.value_structs.lib(env);
}
pub fn janet_struct_begin(count: i32) callconv(.c) [*]types.JanetKV {
    return impl.value_structs.begin(count);
}
pub fn janet_struct_end(st_in: [*]types.JanetKV) callconv(.c) [*]const types.JanetKV {
    return impl.value_structs.end(st_in);
}
pub fn janet_struct_find(st: [*]const types.JanetKV, key: repr.Value) callconv(.c) ?*const types.JanetKV {
    return impl.value_structs.find(st, key);
}
pub fn janet_struct_get(st_in: [*]const types.JanetKV, key: repr.Value) callconv(.c) repr.Value {
    return impl.value_structs.get(st_in, key);
}
pub fn janet_struct_get_ex(st_in: [*]const types.JanetKV, key: repr.Value, which: *?types.JanetStruct) callconv(.c) repr.Value {
    return impl.value_structs.getEx(st_in, key, which);
}
pub fn janet_struct_put(st: [*]types.JanetKV, key: repr.Value, val: repr.Value) callconv(.c) void {
    return impl.value_structs.put(st, key, val);
}
pub fn janet_struct_put_ext(st: [*]types.JanetKV, key_in: repr.Value, value_in: repr.Value, replace: c_int) callconv(.c) void {
    return impl.value_structs.putExt(st, key_in, value_in, replace);
}
pub fn janet_struct_rawget(st: [*]const types.JanetKV, key: repr.Value) callconv(.c) repr.Value {
    return impl.value_structs.rawget(st, key);
}
pub fn janet_struct_to_table(st: [*]const types.JanetKV) callconv(.c) *types.JanetTable {
    return impl.value_structs.toTable(st);
}
comptime {
    if (options.structs) {
        @export(&janet_lib_struct, .{ .name = "janet_lib_struct", .visibility = .hidden });
        @export(&janet_struct_begin, .{ .name = "janet_struct_begin" });
        @export(&janet_struct_end, .{ .name = "janet_struct_end" });
        @export(&janet_struct_find, .{ .name = "janet_struct_find" });
        @export(&janet_struct_get, .{ .name = "janet_struct_get" });
        @export(&janet_struct_get_ex, .{ .name = "janet_struct_get_ex" });
        @export(&janet_struct_put, .{ .name = "janet_struct_put" });
        @export(&janet_struct_put_ext, .{ .name = "janet_struct_put_ext", .visibility = .hidden });
        @export(&janet_struct_rawget, .{ .name = "janet_struct_rawget" });
        @export(&janet_struct_to_table, .{ .name = "janet_struct_to_table" });
    }
}

// value/symbols.zig
//
pub fn janet_symbol(str: ?[*]const u8, len: i32) callconv(.c) [*:0]const u8 {
    return impl.value_symbols.new(cbytes(str, len));
}
pub fn janet_csymbol(cstr: [*:0]const u8) callconv(.c) [*:0]const u8 {
    return impl.value_symbols.csymbol(cstr);
}
pub fn janet_symbol_gen() callconv(.c) [*:0]const u8 {
    return impl.value_symbols.gen();
}
pub fn janet_symbol_deinit(sym: [*:0]const u8) callconv(.c) void {
    return impl.value_symbols.deinit(sym);
}
pub fn janet_symcache_init() callconv(.c) void {
    return impl.value_symbols.cacheInit();
}
pub fn janet_symcache_deinit() callconv(.c) void {
    return impl.value_symbols.cacheDeinit();
}
comptime {
    if (options.symbols) {
        @export(&janet_symbol, .{ .name = "janet_symbol" });
        @export(&janet_csymbol, .{ .name = "janet_csymbol" });
        @export(&janet_symbol_gen, .{ .name = "janet_symbol_gen" });
        @export(&janet_symbol_deinit, .{ .name = "janet_symbol_deinit", .visibility = .hidden });
        @export(&janet_symcache_init, .{ .name = "janet_symcache_init", .visibility = .hidden });
        @export(&janet_symcache_deinit, .{ .name = "janet_symcache_deinit", .visibility = .hidden });
    }
}

// value/tables.zig
//
pub fn janet_lib_table(env: *types.JanetTable) callconv(.c) void {
    return impl.value_tables.lib(env);
}
pub fn janet_table(capacity: i32) callconv(.c) *types.JanetTable {
    return impl.value_tables.new(capacity);
}
pub fn janet_table_clear(t: *types.JanetTable) callconv(.c) void {
    return impl.value_tables.clear(t);
}
pub fn janet_table_clone(table: *types.JanetTable) callconv(.c) *types.JanetTable {
    return impl.value_tables.clone(table);
}
pub fn janet_table_deinit(table: *types.JanetTable) callconv(.c) void {
    return impl.value_tables.deinit(table);
}
pub fn janet_table_find(t: *types.JanetTable, key: repr.Value) callconv(.c) ?*types.JanetKV {
    return impl.value_tables.find(t, key);
}
pub fn janet_table_get(t_in: *types.JanetTable, key: repr.Value) callconv(.c) repr.Value {
    return impl.value_tables.get(t_in, key);
}
pub fn janet_table_get_ex(t_in: *types.JanetTable, key: repr.Value, which: *?*types.JanetTable) callconv(.c) repr.Value {
    return impl.value_tables.getEx(t_in, key, which);
}
pub fn janet_table_get_keyword(t_in: *types.JanetTable, keyword: [*:0]const u8) callconv(.c) repr.Value {
    return impl.value_tables.getKeyword(t_in, keyword);
}
pub fn janet_table_init(table: *types.JanetTable, capacity: i32) callconv(.c) *types.JanetTable {
    return impl.value_tables.init(table, capacity);
}
pub fn janet_table_init_raw(table: *types.JanetTable, capacity: i32) callconv(.c) *types.JanetTable {
    return impl.value_tables.initRaw(table, capacity);
}
pub fn janet_table_merge_struct(table: *types.JanetTable, other: [*]const types.JanetKV) callconv(.c) void {
    return impl.value_tables.mergeStruct(table, other);
}
pub fn janet_table_merge_table(table: *types.JanetTable, other: *types.JanetTable) callconv(.c) void {
    return impl.value_tables.mergeTable(table, other);
}
pub fn janet_table_proto_flatten(t_in: *types.JanetTable) callconv(.c) *types.JanetTable {
    return impl.value_tables.protoFlatten(t_in);
}
pub fn janet_table_put(t: *types.JanetTable, key: repr.Value, val: repr.Value) callconv(.c) void {
    return impl.value_tables.put(t, key, val);
}
pub fn janet_table_rawget(t: *types.JanetTable, key: repr.Value) callconv(.c) repr.Value {
    return impl.value_tables.rawget(t, key);
}
pub fn janet_table_remove(t: *types.JanetTable, key: repr.Value) callconv(.c) repr.Value {
    return impl.value_tables.remove(t, key);
}
pub fn janet_table_to_struct(t: *types.JanetTable) callconv(.c) [*]const types.JanetKV {
    return impl.value_tables.toStruct(t);
}
pub fn janet_table_weakk(capacity: i32) callconv(.c) *types.JanetTable {
    return impl.value_tables.weakk(capacity);
}
pub fn janet_table_weakkv(capacity: i32) callconv(.c) *types.JanetTable {
    return impl.value_tables.weakkv(capacity);
}
pub fn janet_table_weakv(capacity: i32) callconv(.c) *types.JanetTable {
    return impl.value_tables.weakv(capacity);
}
comptime {
    if (options.tables) {
        @export(&janet_lib_table, .{ .name = "janet_lib_table", .visibility = .hidden });
        @export(&janet_table, .{ .name = "janet_table" });
        @export(&janet_table_clear, .{ .name = "janet_table_clear" });
        @export(&janet_table_clone, .{ .name = "janet_table_clone" });
        @export(&janet_table_deinit, .{ .name = "janet_table_deinit" });
        @export(&janet_table_find, .{ .name = "janet_table_find" });
        @export(&janet_table_get, .{ .name = "janet_table_get" });
        @export(&janet_table_get_ex, .{ .name = "janet_table_get_ex" });
        @export(&janet_table_get_keyword, .{ .name = "janet_table_get_keyword", .visibility = .hidden });
        @export(&janet_table_init, .{ .name = "janet_table_init" });
        @export(&janet_table_init_raw, .{ .name = "janet_table_init_raw" });
        @export(&janet_table_merge_struct, .{ .name = "janet_table_merge_struct" });
        @export(&janet_table_merge_table, .{ .name = "janet_table_merge_table" });
        @export(&janet_table_proto_flatten, .{ .name = "janet_table_proto_flatten", .visibility = .hidden });
        @export(&janet_table_put, .{ .name = "janet_table_put" });
        @export(&janet_table_rawget, .{ .name = "janet_table_rawget" });
        @export(&janet_table_remove, .{ .name = "janet_table_remove" });
        @export(&janet_table_to_struct, .{ .name = "janet_table_to_struct" });
        @export(&janet_table_weakk, .{ .name = "janet_table_weakk" });
        @export(&janet_table_weakkv, .{ .name = "janet_table_weakkv" });
        @export(&janet_table_weakv, .{ .name = "janet_table_weakv" });
    }
}

// value/tuples.zig
//
pub fn janet_tuple_begin(length: i32) callconv(.c) [*]repr.Value {
    return impl.value_tuples.begin(length);
}
pub fn janet_tuple_end(tuple: [*]repr.Value) callconv(.c) [*]const repr.Value {
    return impl.value_tuples.end(tuple);
}
pub fn janet_tuple_n(values: ?[*]const repr.Value, n: i32) callconv(.c) [*]const repr.Value {
    return impl.value_tuples.newFrom(if (values) |p| p[0..@intCast(n)] else &.{});
}
pub fn janet_lib_tuple(env: *types.JanetTable) callconv(.c) void {
    return impl.value_tuples.lib(env);
}
comptime {
    if (options.tuples) {
        @export(&janet_tuple_begin, .{ .name = "janet_tuple_begin" });
        @export(&janet_tuple_end, .{ .name = "janet_tuple_end" });
        @export(&janet_tuple_n, .{ .name = "janet_tuple_n" });
        @export(&janet_lib_tuple, .{ .name = "janet_lib_tuple", .visibility = .hidden });
    }
}

// vm.zig
//
comptime {
    if (options.vm) {
        publish("janet_mcall", &impl.vm.mcallPanicking, fn ([*:0]const u8, i32, [*]repr.Value) callconv(.c) repr.Value);
    }
}

// vm/entry.zig
//
pub fn janet_continue_signal(fiber: *types.JanetFiber, in: repr.Value, out: *repr.Value, sig: c_uint) callconv(.c) types.Signal {
    return impl.vm_entry.continueSignal(fiber, in, out, types.Signal.fromWire(sig));
}
pub fn janet_pcall(fun: *types.JanetFunction, argc: i32, argv: ?[*]const repr.Value, out: *repr.Value, f: ?*?*types.JanetFiber) callconv(.c) types.Signal {
    return impl.vm_entry.pcall(fun, argc, argv, out, f);
}
pub fn janet_continue(fiber: *types.JanetFiber, in: repr.Value, out: *repr.Value) callconv(.c) types.Signal {
    return impl.vm_entry.continueFiber(fiber, in, out);
}
comptime {
    if (options.vm_entry) {
        publish("janet_step", &impl.vm_entry.stepAbi, fn (*types.JanetFiber, repr.Value, *repr.Value) callconv(.c) types.Signal);
        publish("janet_call", &impl.vm_entry.callAbi, fn (*types.JanetFunction, i32, [*]const repr.Value) callconv(.c) repr.Value);
        @export(&janet_continue_signal, .{ .name = "janet_continue_signal" });
        @export(&janet_pcall, .{ .name = "janet_pcall" });
        @export(&janet_continue, .{ .name = "janet_continue" });
    }
}

// vm/lifecycle.zig
//
pub fn janet_init() callconv(.c) c_int {
    return impl.vm_lifecycle.initAbi();
}
pub fn janet_sandbox(flags: u32) callconv(.c) void {
    return impl.vm_lifecycle.sandboxAbi(flags);
}
pub fn janet_sandbox_assert(forbidden_flags: u32) callconv(.c) void {
    return impl.vm_lifecycle.sandboxAssertAbi(forbidden_flags);
}
pub fn janet_deinit() callconv(.c) void {
    return impl.vm_lifecycle.deinitAbi();
}
pub fn janet_dyn(name: [*:0]const u8) callconv(.c) repr.Value {
    return impl.vm_lifecycle.dyn(name);
}
pub fn janet_interpreter_interrupt(vm: ?*types.Vm) callconv(.c) void {
    return impl.vm_lifecycle.interpreterInterrupt(vm);
}
pub fn janet_interpreter_interrupt_handled(vm: ?*types.Vm) callconv(.c) void {
    return impl.vm_lifecycle.interpreterInterruptHandled(vm);
}
pub fn janet_local_vm() callconv(.c) *types.Vm {
    return impl.vm_lifecycle.localVm();
}
pub fn janet_setdyn(name: [*:0]const u8, val: repr.Value) callconv(.c) void {
    return impl.vm_lifecycle.setdyn(name, val);
}
pub fn janet_vm_alloc() callconv(.c) *types.Vm {
    return impl.vm_lifecycle.vmAlloc();
}
pub fn janet_vm_free(vm: ?*types.Vm) callconv(.c) void {
    return impl.vm_lifecycle.vmFree(vm);
}
pub fn janet_vm_load(from: *const types.Vm) callconv(.c) void {
    return impl.vm_lifecycle.vmLoad(from);
}
pub fn janet_vm_save(into: *types.Vm) callconv(.c) void {
    return impl.vm_lifecycle.vmSave(into);
}
comptime {
    if (options.lifecycle) {
        @export(&janet_init, .{ .name = "janet_init" });
        @export(&janet_sandbox, .{ .name = "janet_sandbox" });
        @export(&janet_sandbox_assert, .{ .name = "janet_sandbox_assert" });
        @export(&janet_deinit, .{ .name = "janet_deinit" });
        @export(&janet_dyn, .{ .name = "janet_dyn" });
        @export(&janet_interpreter_interrupt, .{ .name = "janet_interpreter_interrupt" });
        @export(&janet_interpreter_interrupt_handled, .{ .name = "janet_interpreter_interrupt_handled" });
        @export(&janet_local_vm, .{ .name = "janet_local_vm" });
        @export(&janet_setdyn, .{ .name = "janet_setdyn" });
        @export(&janet_vm_alloc, .{ .name = "janet_vm_alloc" });
        @export(&janet_vm_free, .{ .name = "janet_vm_free" });
        @export(&janet_vm_load, .{ .name = "janet_vm_load" });
        @export(&janet_vm_save, .{ .name = "janet_vm_save" });
    }
}

// The published surface of every export that names a runtime declaration
// directly.
//
// 423 of the `@export`s above name an entry point declared in this file, so
// the signature a C caller sees is written here and the compiler checks the
// forwarding call against its target. The other 110 name `impl.<module>.<decl>`
// -- a `raise.panicking(f).abi`, one of `args.zig`'s generated getters, or a
// data symbol -- and those have no second hat to take off, so wrapping them
// would add a call frame to the published path for nothing.
//
// What they did not have was a *statement* of what they publish. Whatever the
// target happened to be declared as became the C ABI, and an edit to the
// target changed the published surface silently: nothing in the manifest said
// otherwise, `tools/check/exports.txt` ratchets names rather than signatures, and the
// linker cannot see a Zig type. These assertions are that statement. They cost
// nothing at run time and they name the symbol when a target moves.
//
// The conditions are the ones the `@export`s above carry, so an arm this host
// does not compile is asserted where it is compiled and nowhere else --
// `symbol_clib` is Windows-only and is checked by the cross-build.
fn publishes(comptime name: []const u8, comptime target: anytype, comptime Signature: type) void {
    if (@TypeOf(target) != Signature) @compileError(
        "`" ++ name ++ "` publishes `" ++ @typeName(@TypeOf(target)) ++
            "` but this manifest states `" ++ @typeName(Signature) ++ "`",
    );
}

comptime {
    if (options.args) {}
    if (config.dynamic_modules and is_windows) {}
    if (options.marsh) {}
    if (options.parser) {}
    if (options.pp and options.pp) {}
    if (options.registry) {}
    if (options.utilities) {}
    if (options.functions) {}
    if (options.wrap and (config.value_repr != .tagged)) {}
    if (options.wrap) {}
    if (options.vm) {}
    if (options.vm_entry) {}
}

// The twenty generated optional getters. `Opt(GetX)` and `OptLen(GetX, new)`
// build the entry point from another one at comptime, so the target is an
// expression rather than a name -- which a sweep that matches an identifier
// and stops at the `(` will silently miss.
comptime {
    if (options.args) {}
}
