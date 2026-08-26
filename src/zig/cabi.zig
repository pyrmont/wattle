//! The C-ABI namespace, in Zig.
//!
//! Phase 12 increment 5b. Until here `c` was `abi.zig`'s `@cImport` of
//! `janet.h` and six internal headers, which made the header the source of
//! every type, every constant and every declaration the runtime calls itself
//! through. Increments 3 and 4 moved the types and the constants into Zig;
//! this file moves the *declarations*, and with them the last reason the
//! header has to be translated.
//!
//! **Every name here is one the tree actually spells**, generated from the
//! translation rather than transcribed: `zig build translate` for each
//! configuration, then the `pub extern fn` and `pub inline fn` lines for the
//! names in use, with the Janet type spellings rewritten to `types.`. What a
//! signature says is therefore still translate-c's reading of the C, and the
//! types in it are Zig's.
//!
//! **What this does and does not buy.** It buys the header's retirement, and
//! it means a call site holds Zig types rather than `cimport.struct_*`. It
//! does **not** yet buy checking: an `extern fn` declaration is still a
//! promise Zig believes, so a signature that disagrees with the `export fn`
//! it names is undiagnosed exactly as it was through the header. That is what
//! increment 5d takes, one call site at a time -- and every conversion deletes
//! a line from this file.
//!
//! **`cabi_check.zig` holds a declaration here against its definition**, per
//! name, on every build -- increment 5c, which is what makes 5d's
//! conversions verifiable rather than hopeful. What it cannot reach is named
//! in that file.
//!
//! **The 565 aliases are gone, and this file no longer flattens anything.**
//! Increment 5g spent them: `c.Janet` is `types.Janet` at all 8,577 call
//! sites and `c.JANET_NUMBER` is `constants.JANET_NUMBER`, so `types` and
//! `constants` are imported by the 131 files that name them rather than
//! re-exported through here. The 0.15.1 release notes give the rationale for
//! removing `usingnamespace` as *"namespacing is good, actually"*, and the
//! aliases were exactly the flattening that keyword was removed to
//! discourage. They existed so that increment 5b changed no call site.
//!
//! What is left is the seam itself: the extern declarations, nine macros and
//! the data, none of which is flattening, each staying until increment 5d
//! converts it to a direct call. **Those macros call the declarations by bare
//! name**, which is why deleting the aliases needed one requalification --
//! `JANET_CURRENT_CONFIG_BITS` in `janet_config_current` -- and why a sweep
//! for `c.`-prefixed references under-reports what this file uses.
//!
//! **Nine of the eighteen macros went in increment 5e**, every one that read a
//! field out of a head; see the section comment above the survivors.
//! (`port/seam.txt` counted 18 rather than 16 because two of `janet.h`'s
//! macros expand to a call and are `extern fn` here.)
//!
//! **`janet_vm` is `vm()` and not a declaration**, because it is the one
//! symbol whose storage class follows the build: `threadlocal` unless
//! `-Dsingle-threaded`. A container-level declaration cannot be conditional,
//! Zig 0.16 has no `usingnamespace` to merge two variants of this file, and an
//! alias of a variable is a copy. `@extern` takes `is_thread_local` as a
//! runtime-known option inside a function, so an `inline fn` gives the same
//! address with none of that -- verified against `&janet_vm` directly.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const types = @import("types");
const constants = @import("constants");

/// Two constants that are libc's rather than Janet's. Phase 10's decision 4
/// permits libc through `@cImport` explicitly: "no C in the tree" and "no
/// libc" are different claims, and only the first is a goal.
const libc = @cImport({
    @cInclude("stdio.h");
});

pub const BUFSIZ = libc.BUFSIZ;
pub const EOF = libc.EOF;

/// `janet_vm`, whose storage class follows `-Dsingle-threaded`.
///
/// Call sites spell `c.vm()` where they spelled `c.janet_vm`; field access
/// reads the same, because Zig auto-dereferences a single-item pointer. See
/// the header comment for why this is a function.
pub inline fn vm() *types.JanetVM {
    return @extern(*types.JanetVM, .{
        .name = "janet_vm",
        .is_thread_local = !config.single_threaded,
    });
}

// ---------------------------------------------------------------------------
// The exported data. Declared rather than aliased: Phase 11's rule 56 --
// an alias of a `const` is a copy, and seven call sites take the address
// of an abstract type and compare it.
// ---------------------------------------------------------------------------

pub extern const janet_peg_type: types.JanetAbstractType;

// ---------------------------------------------------------------------------
// The seam. Still a C-ABI call, but declared in Zig against Zig types --
// which is what lets `janet.h` go. Converting a call site to a direct
// import is increment 5d, and each one deletes a line here.
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
pub extern fn janet_abstract(atype: *const types.JanetAbstractType, size: usize) ?*anyopaque;
pub extern fn janet_arity(arity: i32, min: i32, max: i32) void;
pub extern fn janet_array(capacity: i32) *types.JanetArray;
pub extern fn janet_array_pop(array: *types.JanetArray) types.Janet;
pub extern fn janet_array_push(array: *types.JanetArray, x: types.Janet) void;
pub extern fn janet_await() void;
pub extern fn janet_buffer(capacity: i32) *types.JanetBuffer;
pub extern fn janet_buffer_extra(buffer: *types.JanetBuffer, n: i32) void;
pub extern fn janet_buffer_push_bytes(buffer: *types.JanetBuffer, string: ?[*]const u8, length: i32) void;
pub extern fn janet_buffer_push_cstring(buffer: *types.JanetBuffer, cstring: [*]const u8) void;
pub extern fn janet_buffer_push_u8(buffer: *types.JanetBuffer, byte: u8) void;
pub extern fn janet_buffer_setcount(buffer: *types.JanetBuffer, count: i32) void;
pub extern fn janet_call(fun: *types.JanetFunction, argc: i32, argv: [*]const types.Janet) types.Janet;
pub extern fn janet_cfuns_ext(env: ?*types.JanetTable, regprefix: ?[*:0]const u8, registrations: [*]const types.JanetRegExt) void;
pub extern fn janet_channel_give(channel: ?*types.JanetChannel, x: types.Janet) c_int;
pub extern fn janet_checktype(x: types.Janet, @"type": types.JanetType) c_int;
pub extern fn janet_checktypes(x: types.Janet, typeflags: c_int) c_int;
pub extern fn janet_collect() void;
pub extern fn janet_core_env(replacements: ?*types.JanetTable) *types.JanetTable;
pub extern fn janet_cstring(str: [*:0]const u8) [*:0]const u8;
pub extern fn janet_csymbol(cstr: [*:0]const u8) [*:0]const u8;
pub extern fn janet_def(env: *types.JanetTable, name: [*:0]const u8, val: types.Janet, doc: ?[*:0]const u8) void;
pub extern fn janet_def_sm(env: *types.JanetTable, name: [*:0]const u8, val: types.Janet, doc: ?[*:0]const u8, source_file: ?[*:0]const u8, source_line: i32) void;
pub extern fn janet_deinit() void;
pub extern fn janet_dobytes(env: *types.JanetTable, bytes: ?[*]const u8, len: i32, source_path: ?[*:0]const u8, out: ?*types.Janet) c_int;
pub extern fn janet_equals(x: types.Janet, y: types.Janet) c_int;
pub extern fn janet_fiber(callee: *types.JanetFunction, capacity: i32, argc: i32, argv: ?[*]const types.Janet) ?*types.JanetFiber;
pub extern fn janet_fiber_reset(fiber: *types.JanetFiber, callee: *types.JanetFunction, argc: i32, argv: ?[*]const types.Janet) ?*types.JanetFiber;
pub extern fn janet_fixarity(arity: i32, fix: i32) void;
pub extern fn janet_gcroot(root: types.Janet) void;
pub extern fn janet_gcunroot(root: types.Janet) c_int;
pub extern fn janet_getbuffer(argv: [*]const types.Janet, n: i32) *types.JanetBuffer;
pub extern fn janet_getstring(argv: [*]const types.Janet, n: i32) types.JanetString;
pub extern fn janet_hash(x: types.Janet) i32;
pub extern fn janet_init() c_int;
pub extern fn janet_length(x: types.Janet) i32;
pub extern fn janet_loop() void;
pub extern fn janet_loop1() ?*types.JanetFiber;
pub extern fn janet_loop_fiber(fiber: *types.JanetFiber) c_int;
pub extern fn janet_marshal(buf: *types.JanetBuffer, x: types.Janet, rreg: ?*types.JanetTable, flags: c_int) void;
pub extern fn janet_nanbox32_from_tagi(tag: u32, integer: i32) types.Janet;
pub extern fn janet_nanbox32_from_tagp(tag: u32, pointer: ?*anyopaque) types.Janet;
pub extern fn janet_nanbox_from_bits(bits: u64) types.Janet;
pub extern fn janet_nanbox_from_cpointer(p: ?*const anyopaque, tagmask: u64) types.Janet;
pub extern fn janet_nanbox_from_double(d: f64) types.Janet;
pub extern fn janet_nanbox_from_pointer(p: ?*anyopaque, tagmask: u64) types.Janet;
pub extern fn janet_nanbox_to_pointer(x: types.Janet) ?*anyopaque;
pub extern fn janet_panic(message: [*:0]const u8) void;
pub extern fn janet_panic_abstract(x: types.Janet, n: i32, at: *const types.JanetAbstractType) void;
pub extern fn janet_panic_type(x: types.Janet, n: i32, expected: c_int) void;
pub extern fn janet_panicv(message: types.Janet) void;
pub extern fn janet_pcall(fun: *types.JanetFunction, argn: i32, argv: [*]const types.Janet, out: *types.Janet, f: *?*types.JanetFiber) types.JanetSignal;
pub extern fn janet_resolve(env: *types.JanetTable, sym: [*:0]const u8, out: *types.Janet) types.JanetBindingType;
pub extern fn janet_restore(state: *types.JanetTryState) void;
pub extern fn janet_sandbox(flags: u32) void;
pub extern fn janet_scan_number(str: ?[*]const u8, len: i32, out: *f64) c_int;
pub extern fn janet_stacktrace_ext(fiber: *types.JanetFiber, err: types.Janet, prefix: ?[*:0]const u8) void;
pub extern fn janet_stream_close(s: *types.JanetStream) void;
pub extern fn janet_string(buf: ?[*]const u8, len: i32) [*:0]const u8;
pub extern fn janet_symbol(str: ?[*]const u8, len: i32) [*:0]const u8;
pub extern fn janet_table(capacity: i32) *types.JanetTable;
pub extern fn janet_type(x: types.Janet) types.JanetType;
pub extern fn janet_unwrap_integer(x: types.Janet) i32;
pub extern fn janet_unwrap_pointer(x: types.Janet) ?*anyopaque;
pub extern fn janet_abstract_head(abstract: ?*const anyopaque) *types.JanetAbstractHead;
pub extern fn janet_string_head(s: [*]const u8) *types.JanetStringHead;
pub extern fn janet_struct_head(st: [*]const types.JanetKV) *types.JanetStructHead;
pub extern fn janet_tuple_head(tuple: [*]const types.Janet) *types.JanetTupleHead;
pub extern fn janet_table_get(t_in: *types.JanetTable, key: types.Janet) types.Janet;
pub extern fn janet_table_put(t: *types.JanetTable, key: types.Janet, val: types.Janet) void;
pub extern fn janet_table_remove(t: *types.JanetTable, key: types.Janet) types.Janet;
// Corrected against the definition rather than left as translate-c wrote it:
// `which` is a pointer to an *optional* table pointer, which is what
// `struct_table.zig` declares and what the callers pass. The header could
// only say `JanetTable **`.
pub extern fn janet_top_level_signal(msg: [*]const u8) noreturn;
pub extern fn janet_try_init(state: *types.JanetTryState) void;
pub extern fn janet_tuple_begin(length: i32) [*]types.Janet;
pub extern fn janet_tuple_end(tuple: [*]types.Janet) [*]const types.Janet;
pub extern fn janet_unmarshal(bytes: ?[*]const u8, len: usize, flags: c_int, reg: ?*types.JanetTable, next: ?*[*]const u8) types.Janet;
pub extern fn janet_unwrap_function(x: types.Janet) *types.JanetFunction;
pub extern fn janet_unwrap_s64(x: types.Janet) i64;
pub extern fn janet_unwrap_u64(x: types.Janet) u64;
// Corrected against the definition: `vm_state.zig` promises not to write
// through `from`, and `janet.h` says `JanetVM *`. The definition is the
// stronger and the truer of the two.
pub extern fn janet_wrap_abstract(x: types.JanetAbstract) types.Janet;
pub extern fn janet_wrap_array(x: *types.JanetArray) types.Janet;
pub extern fn janet_wrap_boolean(x: c_int) types.Janet;
pub extern fn janet_wrap_buffer(x: *types.JanetBuffer) types.Janet;
pub extern fn janet_wrap_cfunction(x: types.JanetCFunction) types.Janet;
pub extern fn janet_wrap_false() types.Janet;
pub extern fn janet_wrap_fiber(x: ?*types.JanetFiber) types.Janet;
pub extern fn janet_wrap_function(x: *types.JanetFunction) types.Janet;
pub extern fn janet_wrap_integer(x: i32) types.Janet;
pub extern fn janet_wrap_keyword(x: types.JanetKeyword) types.Janet;
pub extern fn janet_wrap_nil() types.Janet;
pub extern fn janet_wrap_number(x: f64) types.Janet;
pub extern fn janet_wrap_pointer(x: ?*anyopaque) types.Janet;
pub extern fn janet_wrap_string(x: types.JanetString) types.Janet;
pub extern fn janet_wrap_struct(x: types.JanetStruct) types.Janet;
pub extern fn janet_wrap_symbol(x: types.JanetSymbol) types.Janet;
pub extern fn janet_wrap_table(x: *types.JanetTable) types.Janet;
pub extern fn janet_wrap_true() types.Janet;
pub extern fn janet_wrap_tuple(x: types.JanetTuple) types.Janet;
pub extern fn janet_zig_c_raise_clear() void;
pub extern fn janet_zig_c_raise_record() void;
pub extern fn janet_zig_c_raise_take() c_int;
pub extern fn janet_zig_fatal(message: [*:0]const u8) noreturn;
pub extern fn janet_zig_signal_record(sig: types.JanetSignal, message: types.Janet) void;
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
