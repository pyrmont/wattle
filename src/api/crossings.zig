//! Every runtime symbol a separately compiled module reaches by name.
//!
//! **This file exists so `raise.zig` can be compiled into a module without
//! `cabi.zig`.** A module's `raise` has to record a signal, build a message,
//! take the C-raise flag and abort; those are calls into the runtime's own
//! `.so`, and the only way a separate compilation makes one is by symbol.
//! `raise.zig` reached them through `cabi` because `cabi` is where every
//! `extern fn` lives — which meant an author's module took **163 libc and
//! runtime declarations to obtain six**, and with them `FILE`, `host.Handle`
//! and the two `pthread` types. Six declarations of its own is the whole cost
//! of not doing that.
//!
//! Every one is under `if (comptime in_module)` in `raise.zig`. Inside the
//! runtime the same six are ordinary Zig calls to `signal.zig` and
//! `fatal.zig`, so nothing here is reached from a `root` build at all; this is
//! the module side of a fork `raise.zig` already had.
//!
//! `cabi.zig` declares the same six for the runtime's own compilation and
//! `cabi_check.zig` compares each against its definition, so the two spellings
//! cannot drift without the build saying so.

const repr = @import("repr");
const abi = @import("abi");
const method_type = @import("../runtime/method_type.zig");

const Value = repr.Value;
const Env = abi.Table;

/// `janet_cstring` — interns a NUL-terminated message as a Janet string.
/// `raise.panic` builds its payload with this, and the sentinel is what the
/// callee walks.
pub extern fn janet_cstring(str: [*:0]const u8) [*:0]const u8;

/// Wraps that string as a `Value`, which is what `raise.panicv` carries.
pub extern fn janet_wrap_string(x: [*:0]const u8) repr.Value;

/// The out-of-band C-raise flag: `raise.raiseRecord` sets it and
/// `raise.tookCRaise` takes it. A module cannot see the runtime's
/// `signal.zig`, so it asks across the boundary.
pub extern fn janet_zig_c_raise_record() void;
pub extern fn janet_zig_c_raise_take() c_int;

/// `raise.total`'s abort, for a raise that cannot happen and would leave the
/// runtime inconsistent if it did.
pub extern fn janet_zig_fatal(message: [*:0]const u8) noreturn;

/// The signal a raise records. It takes the wire width because the published
/// entry point does; the caller here holds an enum member and converts, and
/// the clamp on the far side is then a no-op.
pub extern fn janet_zig_signal_record(sig: c_uint, message: repr.Value) void;

// ==========================================================================
// The module interface's own twenty-one
// ==========================================================================
//
// `module.zig` calls these; they are declared here rather than there so that
// `cabi_check.zig` compares each against the definition `capi.zig` publishes.
// **What an unchecked declaration costs**: a `janet_getmethod` declaring
// `abi.Method` where the definition takes `method_type.CMethod` is two layouts
// agreeing only by luck, and a `janet_wrap_abstract` declaring a non-optional
// pointer against a definition that accepts null loses the null. Neither is
// something a linker can catch, and an author's `.so` is the one compilation
// where getting it wrong is not this project's crash to debug.

pub extern fn janet_fixarity(argc: i32, fix: i32) void;
pub extern fn janet_arity(argc: i32, min: i32, max: i32) void;
pub extern fn janet_getnumber(argv: [*]const Value, n: i32) f64;
pub extern fn janet_getinteger(argv: [*]const Value, n: i32) i32;
pub extern fn janet_getsize(argv: [*]const Value, n: i32) usize;
pub extern fn janet_getabstract(argv: [*]const Value, n: i32, at: *const abi.AbstractType) ?*anyopaque;
pub extern fn janet_wrap_number(x: f64) Value;
pub extern fn janet_wrap_nil() Value;
pub extern fn janet_wrap_abstract(p: ?*anyopaque) Value;
pub extern fn janet_abstract(at: *const abi.AbstractType, size: usize) ?*anyopaque;
pub extern fn janet_calloc(n: usize, size: usize) ?*anyopaque;
pub extern fn janet_free(p: ?*anyopaque) void;
pub extern fn janet_cfuns_ext(env: ?*Env, prefix: ?[*:0]const u8, table: [*]const abi.Reg) void;
pub extern fn janet_def(env: *Env, name: [*:0]const u8, val: Value, doc: ?[*:0]const u8) void;
pub extern fn janet_checkint(x: Value) c_int;
pub extern fn janet_checktype(x: Value, t: c_uint) c_int;
pub extern fn janet_unwrap_integer(x: Value) i32;
pub extern fn janet_unwrap_number(x: Value) f64;
pub extern fn janet_unwrap_keyword(x: Value) [*:0]const u8;
pub extern fn janet_getmethod(method: [*:0]const u8, methods: [*]const method_type.CMethod, out: *Value) c_int;
pub extern fn janet_nextmethod(methods: [*]const method_type.CMethod, key: Value) Value;
