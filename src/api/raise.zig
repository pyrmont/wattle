//! Raising a Janet signal by returning rather than by jumping.
//!
//! Every subsystem imports this file. It is shared rather than selected,
//! because it declares no `export`: two subsystems can import it without a
//! definition appearing twice.
//!
//! `Error` and `NFunction` are `module.zig`'s, re-exported under the names the
//! runtime uses. That import is a cycle, since `module.zig` imports this file.
//! It costs nothing: both declarations are comptime, and no function of
//! `module.zig` is analysed in the runtime.
//!
//! ## How a raise reaches its caller
//!
//! An _abi_ is a `callconv(.c)` wrapper around a raise-capable function.
//!
//! `Error` has one member. A Zig error has no payload, and both parts of a
//! raise are stored elsewhere: the value goes to the VM's `return_reg`, where
//! the try scope points, and the signal goes to `pending_signal` beside it.
//!
//! `runtime/signal.zig`'s `signalRecord` makes every part of the decision
//! except the delivery: the plan, the coercion message, the commit into the
//! return register, the fiber flag. Both deliveries call it, so they cannot
//! differ.
//!
//! - A Zig caller is returned `error.Signal` and reads `pending_signal`
//!   at the `catch`.
//!
//! - A caller across the C ABI reaches `runtime/signal.zig`'s `signalv`, which
//!   records the raise and then reports it, with the signal read from the same
//!   field.
//!
//! A Zig error is fully unwound before a report happens, so `defer` and
//! `errdefer` are legal everywhere. An abi catches the error in its own frame
//! and reports only then, so every `errdefer` between the raise and that frame
//! has already run.
//!
//! ## The two compilations
//!
//! This file is compiled into the runtime and into a native module. Inside the
//! runtime it reaches `runtime/signal.zig`, `runtime/value/strings.zig`,
//! `runtime/value/helpers/wrap.zig` and `runtime/fatal.zig` by import. Inside
//! a native module the runtime is on the other side of a `dlopen`, so the same
//! four calls go through `interface.rt`, whose `signal_record`, `cstring`,
//! `wrap_string`, `c_raise_take`, `c_raise_record` and `fatal` fields exist
//! for them.
//!
//! `in_module` picks the arm. The imports are container-level `const`s and so
//! are lazy: the arm a compilation does not take is never analysed, so a
//! native module does not compile the runtime files named here.
//!
//! `interface.rt` is assigned before any of this runs. The only way into a
//! module is `module.entry`'s `_wattle_init` shim, which stores the table the
//! loader passed before it calls the author's `defs`.
//!
//! `panicf` is not here. A raise whose message Janet's own formatter builds
//! lives in `runtime/pp/format.zig`, beside the engine, because `%v` and the
//! eight spellings of `%q` run the pretty printer.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const config = @import("config");
const fatal_impl = @import("../runtime/fatal.zig");
const interface = @import("interface.zig");
const module = @import("../module.zig");
const repr = @import("repr");
const signal_impl = @import("../runtime/signal.zig");
const strings_impl = @import("../runtime/value/strings.zig");
const wrap_impl = @import("../runtime/value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// Whether this compilation is a native module rather than the runtime.
///
/// Every function here that reaches the runtime tests this and takes either an
/// import or a field of `interface.rt`.
const in_module = config.native_module;

// ==========================================================================
// Aliased types
// ==========================================================================

/// The type of a Janet builtin. This is `module.NFunction`, under the name the
/// runtime uses.
///
/// An nfunction takes its arguments as one slice and returns a `Value` or
/// raises, so a caller has to `try` it. Janet's own signature is
/// `Janet (*)(int32_t, Janet *)`, which returns no error union, so a C body
/// cannot have this type and a C caller cannot invoke it. `abi.NFunction` is
/// the C ABI's shape for the same pointer, and `nfunction` and `stored` are
/// the casts between the two.
pub const NFunction = module.NFunction;

/// The one error a raise-capable function returns. This is `module.Error`,
/// under the name the runtime uses. A raise-capable function returning `T` is
/// spelled `raise.Error!T`.
pub const Error = module.Error;

// ==========================================================================
// Public functions
// ==========================================================================

/// Reads an nfunction out of a stored slot.
///
/// `slot` is the C ABI's shape for the pointer, which is how a `Value`'s union
/// member, a registration row, a registry key and a stack frame's `pc` are
/// typed. That is a layout rather than a calling convention, so this is a cast
/// and everything downstream of it is an ordinary Zig call that returns an
/// error. This function cannot raise.
///
/// See `stored`, which is the same pointer on its way into that storage.
pub inline fn nfunction(slot: abi.NFunction) NFunction {
    return @ptrCast(slot.?);
}

/// Returns the value a call through an abi produced, or the error it reported.
///
/// `value` is the result of that call. A `callconv(.c)` callee returns no
/// error union, so `toAbi` moves the raise onto a flag, and this is where it
/// comes back off. This function raises if a raise reached the abi.
///
/// ```zig
/// const value = try raise.fromAbi(interface.rt.call_value(f, p, n));
/// ```
///
/// `module.zig` wraps every call it makes through the table in this, and
/// `runtime/env.zig` wraps the `_wattle_init` it reached by name.
pub inline fn fromAbi(value: anytype) Error!@TypeOf(value) {
    if (tookCRaise()) return error.Signal;
    return value;
}

/// Raises an error whose message is a string.
///
/// `message` is a sentinel-terminated pointer rather than a slice, because the
/// runtime walks it to a NUL. A slice would accept a string with no terminator
/// and read past its end, and a string literal satisfies this signature as it
/// stands.
pub fn panic(message: [*:0]const u8) Error {
    if (comptime in_module) return panicv(interface.rt.wrap_string(interface.rt.cstring(message)));
    return panicv(wrap_impl.fromString(strings_impl.cstring(message)));
}

/// Builds the abi of a raise-capable function.
///
/// `f` is that function. The result has one declaration, `abi`, which calls
/// `f` and reports a returned error to the C caller rather than jumping:
///
/// ```zig
/// pub const marshalAbi = raise.panicking(marshal).abi;
/// ```
///
/// A signature of more than five parameters is a compile error. A Zig function
/// body cannot be written generically over a parameter list, only over a type,
/// so each arity is a case. Add a case when a subsystem needs another arity.
///
/// Two limits are neither checked nor currently reached: a parameter's
/// `noalias` is dropped, and a variadic function has no abi.
pub fn panicking(comptime f: anytype) type {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    const P = @typeInfo(info.return_type.?).error_union.payload;
    const p = info.params;
    return switch (p.len) {
        0 => struct {
            pub fn abi() callconv(.c) P {
                return f() catch reportToAbi(P);
            }
        },
        1 => struct {
            pub fn abi(a: p[0].type.?) callconv(.c) P {
                return f(a) catch reportToAbi(P);
            }
        },
        2 => struct {
            pub fn abi(a: p[0].type.?, b: p[1].type.?) callconv(.c) P {
                return f(a, b) catch reportToAbi(P);
            }
        },
        3 => struct {
            pub fn abi(a: p[0].type.?, b: p[1].type.?, d: p[2].type.?) callconv(.c) P {
                return f(a, b, d) catch reportToAbi(P);
            }
        },
        4 => struct {
            pub fn abi(a: p[0].type.?, b: p[1].type.?, d: p[2].type.?, e: p[3].type.?) callconv(.c) P {
                return f(a, b, d, e) catch reportToAbi(P);
            }
        },
        5 => struct {
            pub fn abi(a: p[0].type.?, b: p[1].type.?, d: p[2].type.?, e: p[3].type.?, g: p[4].type.?) callconv(.c) P {
                return f(a, b, d, e, g) catch reportToAbi(P);
            }
        },
        else => @compileError("panicking: add an arity case for this signature"),
    };
}

/// Builds the abi of a raise-capable function whose last parameter is a slice.
///
/// `f` is that function. The result's `abi` takes `argc` and `argv` where `f`
/// takes a slice, and rebuilds the slice from the pair. An arity other than
/// one, two or four is a compile error.
///
/// `panicking` cannot build this abi, because a slice has no guaranteed
/// in-memory representation and so cannot cross a `callconv(.c)` signature.
/// `runtime/pp/format.zig`'s `bufferFormatPanicking` is the one use.
pub fn panickingArgv(comptime f: anytype) type {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    const P = @typeInfo(info.return_type.?).error_union.payload;
    const p = info.params;
    const S = @typeInfo(p[p.len - 1].type.?).pointer;
    const Ptr = if (S.is_const) [*]const S.child else [*]S.child;
    return switch (p.len) {
        1 => struct {
            pub fn abi(argc: i32, argv: Ptr) callconv(.c) P {
                return f(argv[0..@intCast(argc)]) catch reportToAbi(P);
            }
        },
        2 => struct {
            pub fn abi(a: p[0].type.?, argc: i32, argv: Ptr) callconv(.c) P {
                return f(a, argv[0..@intCast(argc)]) catch reportToAbi(P);
            }
        },
        4 => struct {
            pub fn abi(a: p[0].type.?, b: p[1].type.?, d: p[2].type.?, argc: i32, argv: Ptr) callconv(.c) P {
                return f(a, b, d, argv[0..@intCast(argc)]) catch reportToAbi(P);
            }
        },
        else => @compileError("panickingArgv: unhandled arity"),
    };
}

/// Raises an error whose message is any Janet value.
///
/// `message` is that value.
pub fn panicv(message: repr.Value) Error {
    return signal(.@"error", message);
}

/// Reports a raise across the C ABI, taking the raise that produced it.
///
/// `_` is unused by construction: everything a report needs is already on the
/// VM. This is the counterpart of `toAbi` for a function that returns the bare
/// error set rather than an error union.
///
/// ```zig
/// pub fn panicv(message: repr.Value) void {
///     raise.report(raise.panicv(message));
/// }
/// ```
///
/// That is `runtime/signal.zig`'s. `panicv` here and `runtime/ev.zig`'s
/// `awaitEvent` are the functions that return the bare error set. Neither is
/// `noreturn`, because a report is how the abi's caller is told.
pub inline fn report(_: Error) void {
    raiseRecord();
}

/// Reports a raise to a C caller and returns a zeroed value of `T`.
///
/// `T` is the abi's return type. The C callers are the variadic shells, and
/// none can take a jump: catching a jump needs a `setjmp`, and this tree has
/// none. So an abi records the raise and returns, and its caller tests
/// `tookCRaise` on the next statement:
///
/// ```zig
/// const value = interface.rt.call_value(f, p, n);
/// if (raise.tookCRaise()) return error.Signal;
/// ```
///
/// The result is zeroed rather than `undefined`, so a forgotten test gives the
/// same wrong answer every time. No caller may read it.
pub inline fn reportToAbi(comptime T: type) T {
    raiseRecord();
    return blank(T);
}

/// Raises `sig` with `message`.
///
/// `sig` is the signal to raise and `message` is the value that goes with it.
/// The record is made in `runtime/signal.zig`, with the rest of the signal
/// decision. This function does not return when the plan is `TOP_LEVEL`: there
/// is no scope to raise into, so the process or the thread ends.
pub fn signal(sig: abi.Signal, message: repr.Value) Error {
    if (comptime in_module) {
        // The table's field takes the wire width, because a C caller may pass
        // any `c_uint`. The caller here holds a member, so the conversion goes
        // the other way and the clamp on the far side does nothing.
        interface.rt.signal_record(@intFromEnum(sig), message);
    } else {
        signal_impl.signalRecord(sig, message);
    }
    return error.Signal;
}

/// Returns an nfunction on its way into a stored slot, at registration.
///
/// `nfun` is the nfunction. This function cannot raise.
///
/// See `nfunction`, which is the cast back out of that storage.
pub inline fn stored(nfun: anytype) abi.NFunction {
    return @ptrCast(nfun);
}

/// Returns the value a raise-capable call produced, or a determinate zero if
/// it raised.
///
/// `result` is the whole error-union expression rather than a type, so a call
/// site does not have to name its payload. The raise is recorded for the abi's
/// caller either way.
///
/// This is what a hand-written abi is made of. `panicking` builds the same
/// thing for the abis that are derived rather than written, and `fromAbi` is
/// the inverse, on the other side of the call.
pub inline fn toAbi(result: anytype) @typeInfo(@TypeOf(result)).error_union.payload {
    const Payload = @typeInfo(@TypeOf(result)).error_union.payload;
    return result catch reportToAbi(Payload);
}

/// Returns whether a raise reached an abi since this was last asked, and
/// clears the flag.
///
/// The result is meaningful on the statement after a call into C that could
/// reach an abi, and nowhere else. This function cannot raise.
pub inline fn tookCRaise() bool {
    if (comptime in_module) return interface.rt.c_raise_take() != 0;
    return signal_impl.cRaiseTake();
}

/// Returns the value of a raise-capable call at a site that cannot take a
/// raise, and aborts if it raised.
///
/// `result` is that call, and `site` names the position and appears in the
/// abort message.
///
/// Some raise-capable calls sit at a position rather than under a caller: a
/// collector traversal, a finalizer, a teardown, the entry point of a thread.
/// There is no scope above any of them and nothing that could consume an
/// error. Prefer making the enclosing function raising, and use this only
/// where the position has no caller that can take an error.
pub inline fn total(
    result: anytype,
    comptime site: [:0]const u8,
) @typeInfo(@TypeOf(result)).error_union.payload {
    const message = "a raise reached " ++ site ++ ", which has no caller that can take an error";
    return result catch if (comptime in_module) interface.rt.fatal(message) else fatal_impl.fatal(message);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Returns an all-zero value of any type an abi can return.
///
/// `std.mem.zeroes` rejects a non-nullable pointer, and rightly: zero is not a
/// value of a `*JanetTable`. Writing the bytes instead keeps `reportToAbi`'s
/// determinacy without asking the type system to accept the result as
/// meaningful. No caller may read it.
inline fn blank(comptime T: type) T {
    var value: T = undefined;
    if (@sizeOf(T) != 0) @memset(std.mem.asBytes(&value), 0);
    return value;
}

/// Records that a raise reached an abi.
///
/// `report` and `reportToAbi` are the callers. This function cannot raise.
inline fn raiseRecord() void {
    if (comptime in_module) interface.rt.c_raise_record() else signal_impl.cRaiseRecord();
}
