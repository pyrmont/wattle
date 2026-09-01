//! Raising a Janet signal by returning, rather than by jumping.
//!
//! The file every subsystem imports. It is shared like `cabi.zig` rather than
//! selected like a subsystem, because it holds no `export` at all: every
//! subsystem can import it without the definitions appearing twice.
//!
//! ## One error, and where everything else lives
//!
//! `Error` has a single member. Zig errors carry no payload, and both things a
//! raise carries already have homes: the value goes to the VM's `return_reg`,
//! which is where the try scope pointed it, and the signal goes to
//! `pending_signal` beside it. A per-signal error set was considered and
//! rejected -- it would duplicate a decision `signalPlan` has already made,
//! and `catch` would then have to agree with the plan or diverge from it
//! silently.
//!
//! ## The decision is shared; only the delivery differs
//!
//! `signal.signalRecord` does everything a raise does except deliver it: the
//! plan, the coercion message, the commit into the return register, the fiber
//! flag. Every delivery calls it, so they cannot drift.
//!
//!  - A Zig caller gets `error.JanetSignal` returned, and reads
//!    `pending_signal` at the `catch`.
//!  - A C caller gets `janet_signalv`, which calls it and then jumps, with the
//!    signal taken from the same field.
//!
//! ## Unwinding, and why a `defer` is safe
//!
//! A Zig error is **fully unwound before any jump happens**. A converted
//! function's abi catches the error in its own frame and only then calls into
//! the jump, so every `errdefer` between the raise and that frame has already
//! run and the stack is settled. `defer` and `errdefer` are legal everywhere.

const std = @import("std");
const abi = @import("abi");
const repr = @import("repr");
const config = @import("config");
const c = @import("crossings.zig");

/// **This file is compiled into two different things.**
///
/// Inside the runtime it is an ordinary file of `root` and reaches
/// `signal.zig`, `value/strings.zig`, `value/helpers/wrap.zig` and `fatal.zig`
/// by import, the way any neighbour does. Inside a *native module* it is the
/// root of its own module and the runtime is on the other side of a `dlopen`,
/// so the same four calls are symbols — which is why `janet_zig_signal_record`,
/// `janet_cstring`, `janet_wrap_string`, `janet_zig_c_raise_take`,
/// `janet_zig_c_raise_record` and `janet_zig_fatal` are published.
///
/// `config.native_module` picks the arm. The imports below are container-level
/// `const`s and therefore lazy: the arm a compilation does not take is loaded
/// and never analysed, so a native module does not compile the runtime it
/// names here.
///
/// The six symbols are declared in `crossings.zig` rather than in `cabi.zig`,
/// and that is what keeps `cabi` out of a module author's compilation
/// entirely -- with it, the 163 libc declarations, `FILE`, `JanetHandle` and
/// the two `pthread` types that an author's `.so` has no use for.
const in_module = config.native_module;
const signal_impl = @import("signal.zig");
const strings_impl = @import("value/strings.zig");
const wrap_impl = @import("value/helpers/wrap.zig");
const fatal_impl = @import("fatal.zig");

/// The one error a raise-capable function can return.
pub const Error = error{JanetSignal};

/// Shorthand for a raise-capable result. `Raising(Janet)` reads better at a
/// declaration than `Error!Janet` and is the same type.
pub fn Raising(comptime T: type) type {
    return Error!T;
}

// ---------------------------------------------------------------- raising

/// Raise `sig` with `message`. The Zig delivery: record, then return.
///
/// Recording lives in `signal.zig` with the rest of the signal decision. It
/// does not return when the plan is `TOP_LEVEL`: there is no scope to raise
/// into, so the process or the thread ends.
pub fn signal(sig: abi.Signal, message: repr.Value) Error {
    if (comptime in_module) {
        // The published entry point takes the wire width, because a C caller
        // may pass any `c_uint`; the caller here already holds a member, so it
        // converts the other way and the clamp on the far side is a no-op.
        c.janet_zig_signal_record(@intFromEnum(sig), message);
    } else {
        signal_impl.zigSignalRecord(sig, message);
    }
    return error.JanetSignal;
}

/// Raise an error carrying `message`, the equivalent of `janet_panicv`.
pub fn panicv(message: repr.Value) Error {
    return signal(.@"error", message);
}

/// Raise an error carrying a string, the equivalent of `janet_panic` and
/// `janet_panics`.
///
/// The parameter is a sentinel-terminated pointer rather than a slice because
/// `janet_cstring` walks to a NUL. A slice would accept one that has none and
/// read past its end; a string literal satisfies this signature as it stands.
pub fn panic(message: [*:0]const u8) Error {
    if (comptime in_module) return panicv(c.janet_wrap_string(c.janet_cstring(message)));
    return panicv(wrap_impl.fromString(strings_impl.cstring(message)));
}

/// `panicf` -- a raise whose message Janet's own formatter builds -- is not
/// here. It lives in `pp/format.zig`, beside the engine, because `%v` and the
/// eight spellings of `%q` run the pretty printer and this file is the shared
/// mechanism rather than a subsystem.
// ---------------------------------------------------------- the cfunction

/// What a Janet builtin is.
///
/// A cfunction returns `Error!Value` and is called with Zig's own calling
/// convention, so a raise leaves it the way a raise leaves anything else -- as
/// a returned error the caller must `try`. Janet's own signature is
/// `Janet (*)(int32_t, Janet *)`, and a C function cannot return an error
/// union: the alternative was a flag on the VM that a raising builtin set
/// before returning a zero, with four call sites testing it on the next
/// statement. This type makes forgetting the test a compile error.
///
/// **What it costs is every C cfunction.** A C body cannot have this type and
/// a C caller cannot invoke it.
///
/// **The arguments are a slice.** Janet fixes them at `int32_t argc, Janet
/// *argv`, so every builtin took a pointer with a count beside it and `argv[n]`
/// read whatever was there. Both sides of this call are Zig -- the pointer is
/// reached by `@ptrCast` off the stored slot, with no thunk -- so the type says
/// what is true and the index is checked. `DESIGN.md` section 9.
///
/// The alignment is not part of the type. `JANET_CFUNCTION_ALIGN` is a
/// property of each definition -- `corefn.alignment`, written at the `fn` --
/// and Zig coerces an over-aligned function pointer to a plain one, so the
/// type does not have to carry the maximum every `-Dnanbox-pointer-shift`
/// might ask for.
pub const CFunction = *const fn ([]repr.Value) Error!repr.Value;

/// A cfunction read out of a stored slot.
///
/// The places that *hold* one are typed by the C ABI's layout: a `Value`'s
/// union member, a registration row, a registry key, a stack frame's `pc`.
/// That is a layout rather than a calling convention, so the cast is here, in
/// one inline function, and everything downstream of it is an ordinary Zig
/// call that returns an error.
/// A published entry point whose C signature carries `(..., int32_t argc,
/// const Janet *argv)` where the Zig one takes a slice in their place.
///
/// `panicking` mirrors its subject's parameter list, so it cannot build a
/// `callconv(.c)` abi for a function taking a slice -- a slice has no
/// guaranteed in-memory representation. This expands the last parameter back
/// into the pair, which is what `janet_getslice`, `janet_buffer_format`,
/// `janet_call` and `janet_mcall` publish.
pub fn panickingArgv(comptime f: anytype) type {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    const P = @typeInfo(info.return_type.?).error_union.payload;
    const p = info.params;
    const S = @typeInfo(p[p.len - 1].type.?).pointer;
    const Ptr = if (S.is_const) [*]const S.child else [*]S.child;
    return switch (p.len) {
        1 => struct {
            pub fn abi(argc: i32, argv: Ptr) callconv(.c) P {
                return f(argv[0..@intCast(argc)]) catch reportToC(P);
            }
        },
        2 => struct {
            pub fn abi(a: p[0].type.?, argc: i32, argv: Ptr) callconv(.c) P {
                return f(a, argv[0..@intCast(argc)]) catch reportToC(P);
            }
        },
        4 => struct {
            pub fn abi(a: p[0].type.?, b: p[1].type.?, d: p[2].type.?, argc: i32, argv: Ptr) callconv(.c) P {
                return f(a, b, d, argv[0..@intCast(argc)]) catch reportToC(P);
            }
        },
        else => @compileError("panickingArgv: unhandled arity"),
    };
}

pub inline fn cfunction(slot: abi.JanetCFunction) CFunction {
    return @ptrCast(slot.?);
}

/// The same pointer on its way into that storage, at registration.
pub inline fn stored(cfun: anytype) abi.JanetCFunction {
    return @ptrCast(cfun);
}

// ------------------------------------------- reporting to a C caller

/// Hand a raise to a C caller by returning, rather than by jumping.
///
/// The remaining C callers are the variadic shells, and none can take a jump:
/// catching one needs a `setjmp`, and there is no `setjmp` anywhere in this
/// tree.
///
/// So an abi records the raise and returns a zeroed value, and its caller
/// tests `tookCRaise` on the next statement:
///
///     const s = janet_formatc("...", args);
///     if (raise.tookCRaise()) return error.JanetSignal;
///
/// **This is not a flag on the hot path.** It is on the C ABI, which the
/// runtime never crosses; it costs the runtime nothing because the runtime
/// does not call it.
///
/// Zeroed rather than `undefined`: an unspecified value that is determinate
/// keeps a forgotten test reproducible.
pub inline fn reportToC(comptime T: type) T {
    raiseRecord();
    return blank(T);
}

/// An all-zero value of any type an abi can return.
///
/// `std.mem.zeroes` refuses a non-nullable pointer, and it is right to: zero is
/// not a value of `*JanetTable`. Three abis return one. Writing the bytes
/// instead keeps 17e's determinacy argument — a caller that forgets the test
/// gets the same wrong answer every time rather than whatever was in the
/// register — without asking the type system to agree that the result is
/// meaningful. It is not meaningful; no caller may look at it.
inline fn blank(comptime T: type) T {
    var value: T = undefined;
    if (@sizeOf(T) != 0) @memset(std.mem.asBytes(&value), 0);
    return value;
}

/// The value a raise-capable call produced, or a determinate zero if it
/// raised — with the raise recorded for the C caller either way.
///
/// This is what a hand-written abi is made of, and it takes the whole
/// error-union expression rather than a type so that converting the 122 of
/// them was a textual change: `X catch raise.deliverToC()` became
/// `raise.reported(X)`, with no need to name each payload. `panicking` builds
/// the same thing for the abis that are derived rather than written.
pub inline fn reported(result: anytype) @typeInfo(@TypeOf(result)).error_union.payload {
    const Payload = @typeInfo(@TypeOf(result)).error_union.payload;
    return result catch reportToC(Payload);
}

/// A raise reported to a C caller, taking the raise that produced it.
///
/// The counterpart of `reported` for a function that answers with the bare
/// error set rather than an error union. `janet_panicv` and `janet_await` are
/// the two ends of that population: one is an error the caller asked for, the
/// other is how a fiber suspends. Neither is `noreturn`, because a report is
/// how a C caller is told.
///
///     export fn janet_panicv(message: Janet) callconv(.c) void {
///         raise.report(raise.panicv(message));
///     }
///
/// The parameter is unused by construction, exactly as the deleted `deliver`'s
/// was: everything the report needs is already in `janet_vm`.
pub inline fn report(_: Error) void {
    raiseRecord();
}

/// The value a call *through the C ABI* produced, or the error it reported.
///
/// A Zig caller that reaches its neighbour by symbol rather than by import
/// gets that neighbour's abi, which reports instead of returning an error.
/// This turns the report back:
///
///     const value = try raise.crossing(janet_call(fun, argc, argv));
///
/// Each one is a crossing an ordinary import would remove, marked rather than
/// hidden. `tools/check/seam.janet` counts them.
pub inline fn crossing(value: anytype) Error!@TypeOf(value) {
    if (tookCRaise()) return error.JanetSignal;
    return value;
}

/// Whether a raise reached an abi since this was last asked. Clears.
///
/// Meaningful on the statement after a call into C that could reach one, and
/// nowhere else.
pub inline fn tookCRaise() bool {
    if (comptime in_module) return c.janet_zig_c_raise_take() != 0;
    return signal_impl.zigCRaiseTake();
}

inline fn raiseRecord() void {
    if (comptime in_module) c.janet_zig_c_raise_record() else signal_impl.zigCRaiseRecord();
}

// ------------------------------------------- a call that may not raise

/// A raise-capable call at a site that cannot carry a raise, asserted rather
/// than delivered.
///
/// Some raise-capable calls sit at a *position* rather than under a caller: a
/// collector traversal, a finalizer, a teardown, the entry point of a thread.
/// There is no scope above any of them and nothing that could consume an
/// error.
///
/// The rule this encodes: **where a raise cannot travel, say so at the site
/// rather than letting it leave.** An abort that names the position is worth
/// more than a jump into a half-torn-down VM, and it is a great deal easier to
/// debug than the blank value the flag protocol would leave.
///
/// This is a behaviour change wherever the C original jumped and something
/// upstream caught it, so it is not to be reached for by default. Prefer
/// making the enclosing function raising; use this only when the position
/// genuinely has no caller that can take an error, and say which in `site`.
pub inline fn total(
    result: anytype,
    comptime site: [:0]const u8,
) @typeInfo(@TypeOf(result)).error_union.payload {
    const message = "a raise reached " ++ site ++ ", which cannot carry one";
    return result catch if (comptime in_module) c.janet_zig_fatal(message) else fatal_impl.fatal(message);
}

/// Build the abi of a raise-capable function: call it, and hand a
/// returned error to the C caller as a *report* rather than as a jump.
///
/// It is built rather than written out, because 177 hand-written abis that can
/// drift from their implementations is a silent ABI change rather than a
/// compile error.
///
///     pub const callNonfnPanicking = raise.panicking(callNonfn).abi;
///
/// Here rather than written out per subsystem because this phase applies the
/// pattern to every exported function that raises, which is most of them. Two
/// lines each is not much until it is three hundred of them, and an abi that
/// drifts from the implementation it wraps is a silent ABI change rather than a
/// compile error.
///
/// The arity cases are unavoidable: a Zig function body cannot be written
/// generically over an arbitrary parameter list, only over an arbitrary type.
/// `@Fn` would construct the *type* — Zig 0.16 replaced `@Type` with per-kind
/// builtins and that is the one for functions — but the body still has to name
/// its parameters, so the switch would remain and the constructed type would
/// buy nothing that inference does not already give. Add a case when a
/// subsystem needs one.
///
/// Two limits, both currently vacuous and neither checked: a parameter's
/// `noalias` is dropped, and a variadic function has no abi. Nothing this
/// wraps is either.
pub fn panicking(comptime f: anytype) type {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    const P = @typeInfo(info.return_type.?).error_union.payload;
    const p = info.params;
    return switch (p.len) {
        0 => struct {
            pub fn abi() callconv(.c) P {
                return f() catch reportToC(P);
            }
        },
        1 => struct {
            pub fn abi(a: p[0].type.?) callconv(.c) P {
                return f(a) catch reportToC(P);
            }
        },
        2 => struct {
            pub fn abi(a: p[0].type.?, b: p[1].type.?) callconv(.c) P {
                return f(a, b) catch reportToC(P);
            }
        },
        3 => struct {
            pub fn abi(a: p[0].type.?, b: p[1].type.?, d: p[2].type.?) callconv(.c) P {
                return f(a, b, d) catch reportToC(P);
            }
        },
        4 => struct {
            pub fn abi(a: p[0].type.?, b: p[1].type.?, d: p[2].type.?, e: p[3].type.?) callconv(.c) P {
                return f(a, b, d, e) catch reportToC(P);
            }
        },
        5 => struct {
            pub fn abi(a: p[0].type.?, b: p[1].type.?, d: p[2].type.?, e: p[3].type.?, g: p[4].type.?) callconv(.c) P {
                return f(a, b, d, e, g) catch reportToC(P);
            }
        },
        else => @compileError("raise.panicking: add an arity case for this signature"),
    };
}
