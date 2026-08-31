//! The C-ABI namespace, in Zig.
//!
//! `c` is this file. Every name in it is genuinely external -- libc, and the
//! few crossings a caller wants for their behaviour rather than by accident --
//! declared in Zig against Zig types.
//!
//! **An `extern fn` is a promise the compiler believes without reading.** A
//! declaration here that disagrees with the definition it names would link and
//! run, and the disagreement would be undiagnosed. `cabi_check.zig` compares
//! every one of them against its definition, by exact type equality, on every
//! build; what it cannot reach is named in that file.
//!
//! **This file flattens nothing.** It re-exported 565 type and constant
//! aliases once -- `pub const Janet = types.Janet;` and its kin -- so that a
//! call site could keep writing `c.Janet`. Those are gone: `types` and
//! `constants` are imported by the files that name them. The 0.15.1 release
//! notes give the rationale for removing `usingnamespace` as *"namespacing is
//! good, actually"*, and the aliases were exactly the flattening that keyword
//! was removed to discourage.
//!
//! **`janet_vm` is not declared here**, and could not be: it is the one symbol
//! whose storage class follows the build -- `threadlocal` unless
//! `-Dsingle-threaded` -- and a container-level declaration cannot be
//! conditional. Every caller reaches the state through `vm/lifecycle.zig`'s
//! `current()`, which takes the address of the variable directly.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");

/// Two constants that are libc's rather than Janet's. libc through `@cImport`
/// is deliberate: "no C in the tree" and "no libc" are different claims, and
/// only the first is a goal.
const libc = @cImport({
    @cInclude("stdio.h");
});

pub const BUFSIZ = libc.BUFSIZ;
pub const EOF = libc.EOF;

// ---------------------------------------------------------------------------
// The declarations. Everything below is genuinely external: libc, and the few
// crossings a caller wants for their behaviour rather than by accident.
// `cabi_check.zig` compares each one against the definition it names.
// ---------------------------------------------------------------------------

pub extern fn abort() noreturn;
pub extern fn acos(f64) f64;
pub extern fn acosh(f64) f64;
pub extern fn asin(f64) f64;
pub extern fn asinh(f64) f64;
pub extern fn atan(f64) f64;
pub extern fn atan2(f64, f64) f64;
pub extern fn atanh(f64) f64;
pub extern fn cbrt(f64) f64;
pub extern fn ceil(f64) f64;
pub extern fn cos(f64) f64;
pub extern fn cosh(f64) f64;
pub extern fn erf(f64) f64;
pub extern fn erfc(f64) f64;
pub extern fn exit(c_int) noreturn;
pub extern fn exp(f64) f64;
pub extern fn exp2(f64) f64;
pub extern fn expm1(f64) f64;
pub extern fn fabs(f64) f64;
pub extern fn fclose(?*types.FILE) c_int;
pub extern fn feof(?*types.FILE) c_int;
pub extern fn fflush(?*types.FILE) c_int;
pub extern fn fgetc(?*types.FILE) c_int;
pub extern fn floor(f64) f64;
pub extern fn fopen(noalias __filename: [*:0]const u8, noalias __mode: [*:0]const u8) ?*types.FILE;
pub extern fn fprintf(noalias ?*types.FILE, noalias [*:0]const u8, ...) c_int;
pub extern fn fputs(noalias [*:0]const u8, noalias ?*types.FILE) c_int;
pub extern fn fread(noalias __ptr: ?*anyopaque, __size: usize, __nitems: usize, noalias __stream: ?*types.FILE) usize;
pub extern fn frexp(f64, *c_int) f64;
pub extern fn fwrite(noalias __ptr: ?*const anyopaque, __size: usize, __nitems: usize, noalias __stream: ?*types.FILE) usize;
pub extern fn hypot(f64, f64) f64;
pub extern fn janet_abstract(atype: *const types.AbstractType, size: usize) ?*anyopaque;
pub extern fn janet_arity(arity: i32, min: i32, max: i32) void;
pub extern fn janet_array(capacity: i32) *types.JanetArray;
pub extern fn janet_array_pop(array: *types.JanetArray) repr.Value;
pub extern fn janet_array_push(array: *types.JanetArray, x: repr.Value) void;
pub extern fn janet_await() void;
pub extern fn janet_buffer(capacity: i32) *types.JanetBuffer;
pub extern fn janet_buffer_extra(buffer: *types.JanetBuffer, n: i32) void;
pub extern fn janet_buffer_push_bytes(buffer: *types.JanetBuffer, string: ?[*]const u8, length: i32) void;
pub extern fn janet_buffer_push_cstring(buffer: *types.JanetBuffer, cstring: [*:0]const u8) void;
pub extern fn janet_buffer_push_u8(buffer: *types.JanetBuffer, byte: u8) void;
pub extern fn janet_buffer_setcount(buffer: *types.JanetBuffer, count: i32) void;
pub extern fn janet_call(fun: *types.JanetFunction, argc: i32, argv: [*]const repr.Value) repr.Value;
pub extern fn janet_cfuns_ext(env: ?*types.JanetTable, regprefix: ?[*:0]const u8, registrations: [*]const types.Reg) void;
pub extern fn janet_channel_give(channel: ?*types.JanetChannel, x: repr.Value) c_int;
pub extern fn janet_checktype(x: repr.Value, @"type": c_uint) c_int;
pub extern fn janet_checktypes(x: repr.Value, typeflags: c_int) c_int;
pub extern fn janet_truthy(x: repr.Value) c_int;
pub extern fn janet_unwrap_boolean(x: repr.Value) c_int;
pub extern fn janet_collect() void;
pub extern fn janet_core_cfuns_ext(env: *types.JanetTable, regprefix: ?[*:0]const u8, registrations: [*]const types.Reg) void;
pub extern fn janet_core_def_sm(env: *types.JanetTable, name: [*:0]const u8, x: repr.Value, p: ?*const anyopaque, sf: ?*const anyopaque, sl: i32) void;
pub extern fn janet_core_env(replacements: ?*types.JanetTable) *types.JanetTable;
pub extern fn janet_cstring(str: [*:0]const u8) [*:0]const u8;
pub extern fn janet_csymbol(cstr: [*:0]const u8) [*:0]const u8;
pub extern fn janet_def(env: *types.JanetTable, name: [*:0]const u8, val: repr.Value, doc: ?[*:0]const u8) void;
pub extern fn janet_def_sm(env: *types.JanetTable, name: [*:0]const u8, val: repr.Value, doc: ?[*:0]const u8, source_file: ?[*:0]const u8, source_line: i32) void;
pub extern fn janet_deinit() void;
pub extern fn janet_dobytes(env: *types.JanetTable, bytes: ?[*]const u8, len: i32, source_path: ?[*:0]const u8, out: ?*repr.Value) c_int;
pub extern fn janet_equals(x: repr.Value, y: repr.Value) c_int;
pub extern fn janet_fiber(callee: *types.JanetFunction, capacity: i32, argc: i32, argv: ?[*]const repr.Value) ?*types.JanetFiber;
pub extern fn janet_fiber_reset(fiber: *types.JanetFiber, callee: *types.JanetFunction, argc: i32, argv: ?[*]const repr.Value) ?*types.JanetFiber;
pub extern fn janet_fixarity(arity: i32, fix: i32) void;
pub extern fn janet_gcroot(root: repr.Value) void;
pub extern fn janet_gcunroot(root: repr.Value) c_int;
pub extern fn janet_getbuffer(argv: [*]const repr.Value, n: i32) *types.JanetBuffer;
pub extern fn janet_getstring(argv: [*]const repr.Value, n: i32) types.JanetString;
pub extern fn janet_hash(x: repr.Value) i32;
pub extern fn janet_init() c_int;
pub extern fn janet_length(x: repr.Value) i32;
pub extern fn janet_loop() void;
pub extern fn janet_loop1() ?*types.JanetFiber;
pub extern fn janet_loop_fiber(fiber: *types.JanetFiber) c_int;
pub extern fn janet_marshal(buf: *types.JanetBuffer, x: repr.Value, rreg: ?*types.JanetTable, flags: c_int) void;
pub extern fn janet_nanbox32_from_tagi(tag: u32, integer: i32) repr.Value;
pub extern fn janet_nanbox32_from_tagp(tag: u32, pointer: ?*anyopaque) repr.Value;
pub extern fn janet_nanbox_from_bits(bits: u64) repr.Value;
pub extern fn janet_nanbox_from_cpointer(p: ?*const anyopaque, tagmask: u64) repr.Value;
pub extern fn janet_nanbox_from_double(d: f64) repr.Value;
pub extern fn janet_nanbox_from_pointer(p: ?*anyopaque, tagmask: u64) repr.Value;
pub extern fn janet_nanbox_to_pointer(x: repr.Value) ?*anyopaque;
pub extern fn janet_panic(message: [*:0]const u8) void;
pub extern fn janet_panic_abstract(x: repr.Value, n: i32, at: *const types.AbstractType) void;
pub extern fn janet_panic_type(x: repr.Value, n: i32, expected: c_int) void;
pub extern fn janet_panicv(message: repr.Value) void;
pub extern fn janet_pcall(fun: *types.JanetFunction, argn: i32, argv: ?[*]const repr.Value, out: *repr.Value, f: ?*?*types.JanetFiber) types.Signal;
pub extern fn janet_resolve(env: *types.JanetTable, sym: [*:0]const u8, out: *repr.Value) types.JanetBindingType;
pub extern fn janet_restore(state: *types.JanetTryState) void;
pub extern fn janet_sandbox(flags: u32) void;
pub extern fn janet_scan_number(str: ?[*]const u8, len: i32, out: *f64) c_int;
pub extern fn janet_stacktrace_ext(fiber: *types.JanetFiber, err: repr.Value, prefix: ?[*:0]const u8) void;
pub extern fn janet_stream_close(s: *types.JanetStream) void;
pub extern fn janet_string(buf: ?[*]const u8, len: i32) [*:0]const u8;
pub extern fn janet_symbol(str: ?[*]const u8, len: i32) [*:0]const u8;
pub extern fn janet_table(capacity: i32) *types.JanetTable;
pub extern fn janet_type(x: repr.Value) c_uint;
pub extern fn janet_unwrap_integer(x: repr.Value) i32;
pub extern fn janet_unwrap_pointer(x: repr.Value) ?*anyopaque;
pub extern fn janet_abstract_head(abstract: ?*const anyopaque) *types.JanetAbstractHead;
pub extern fn janet_string_head(s: [*]const u8) *types.JanetStringHead;
pub extern fn janet_struct_head(st: [*]const types.JanetKV) *types.JanetStructHead;
pub extern fn janet_tuple_head(tuple: [*]const repr.Value) *types.JanetTupleHead;
pub extern fn janet_table_get(t_in: *types.JanetTable, key: repr.Value) repr.Value;
pub extern fn janet_table_put(t: *types.JanetTable, key: repr.Value, val: repr.Value) void;
pub extern fn janet_table_remove(t: *types.JanetTable, key: repr.Value) repr.Value;
// Corrected against the definition rather than left as translate-c wrote it:
// `which` is a pointer to an *optional* table pointer, which is what
// `struct_table.zig` declares and what the callers pass. The header could
// only say `JanetTable **`.
pub extern fn janet_top_level_signal(msg: [*]const u8) noreturn;
pub extern fn janet_try_init(state: *types.JanetTryState) void;
pub extern fn janet_tuple_begin(length: i32) [*]repr.Value;
pub extern fn janet_tuple_end(tuple: [*]repr.Value) [*]const repr.Value;
pub extern fn janet_unmarshal(bytes: ?[*]const u8, len: usize, flags: c_int, reg: ?*types.JanetTable, next: ?*[*]const u8) repr.Value;
pub extern fn janet_unwrap_function(x: repr.Value) *types.JanetFunction;
pub extern fn janet_unwrap_s64(x: repr.Value) i64;
pub extern fn janet_unwrap_u64(x: repr.Value) u64;
pub extern fn janet_wrap_abstract(x: types.JanetAbstract) repr.Value;
pub extern fn janet_wrap_array(x: *types.JanetArray) repr.Value;
pub extern fn janet_wrap_boolean(x: c_int) repr.Value;
pub extern fn janet_wrap_buffer(x: *types.JanetBuffer) repr.Value;
pub extern fn janet_wrap_cfunction(x: types.JanetCFunction) repr.Value;
pub extern fn janet_wrap_false() repr.Value;
pub extern fn janet_wrap_fiber(x: ?*types.JanetFiber) repr.Value;
pub extern fn janet_wrap_function(x: *types.JanetFunction) repr.Value;
pub extern fn janet_wrap_integer(x: i32) repr.Value;
pub extern fn janet_wrap_keyword(x: types.JanetKeyword) repr.Value;
pub extern fn janet_wrap_nil() repr.Value;
pub extern fn janet_wrap_number(x: f64) repr.Value;
pub extern fn janet_wrap_pointer(x: ?*anyopaque) repr.Value;
pub extern fn janet_wrap_string(x: types.JanetString) repr.Value;
pub extern fn janet_wrap_struct(x: types.JanetStruct) repr.Value;
pub extern fn janet_wrap_symbol(x: types.JanetSymbol) repr.Value;
pub extern fn janet_wrap_table(x: *types.JanetTable) repr.Value;
pub extern fn janet_wrap_true() repr.Value;
pub extern fn janet_wrap_tuple(x: types.JanetTuple) repr.Value;
pub extern fn janet_zig_c_raise_clear() void;
pub extern fn janet_zig_c_raise_record() void;
pub extern fn janet_zig_c_raise_take() c_int;
pub extern fn janet_zig_fatal(message: [*:0]const u8) noreturn;
pub extern fn janet_zig_signal_record(sig: c_uint, message: repr.Value) void;
pub extern fn ldexp(f64, c_int) f64;
pub extern fn lgamma(f64) f64;
pub extern fn log(f64) f64;
pub extern fn log10(f64) f64;
pub extern fn log1p(f64) f64;
pub extern fn log2(f64) f64;
pub extern fn memcmp(__s1: ?*const anyopaque, __s2: ?*const anyopaque, __n: usize) c_int;
pub extern fn memcpy(__dst: ?*anyopaque, __src: ?*const anyopaque, __n: usize) ?*anyopaque;
pub extern fn memset(__b: ?*anyopaque, __c: c_int, __len: usize) ?*anyopaque;
pub extern fn nextafter(f64, f64) f64;
pub extern fn pow(f64, f64) f64;
pub extern fn remove([*:0]const u8) c_int;
pub extern fn rewind(?*types.FILE) void;
pub extern fn round(f64) f64;
pub extern fn sin(f64) f64;
pub extern fn sinh(f64) f64;
pub extern fn snprintf(noalias __str: [*]u8, __size: usize, noalias __format: [*:0]const u8, ...) c_int;
pub extern fn sqrt(f64) f64;
pub extern fn strlen(__s: [*:0]const u8) usize;
pub extern fn strncmp(__s1: [*]const u8, __s2: [*]const u8, __n: usize) c_int;
pub extern fn tan(f64) f64;
pub extern fn tanh(f64) f64;
pub extern fn tgamma(f64) f64;
pub extern fn tmpfile() ?*types.FILE;
pub extern fn trunc(f64) f64;
