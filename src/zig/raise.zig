//! Raising a Janet signal by returning, rather than by jumping.
//!
//! This is Phase 10 Part 2's mechanism, and the file every converted subsystem
//! imports. It is shared like `cabi.zig` rather than selected like a subsystem,
//! for a reason recorded in `PLAN.md`: a `-Draise=c` would have to be spelled
//! at every converted call site, and there is nothing for it to select — the
//! "C implementation" of an error return is the `longjmp`, and the two cannot
//! coexist inside one function. What replaces the selector is that a converted
//! symbol keeps **two forms**, so its abi and its Zig implementation are each other's
//! differential for as long as any C caller remains.
//!
//! ## One error, and where everything else lives
//!
//! `Error` has a single member. Zig errors carry no payload, and both things a
//! raise carries already have homes: the value goes to `janet_vm.return_reg`,
//! which is where `janet_try` pointed it, and the signal goes to
//! `janet_vm.pending_signal`, which Part 2 added beside it. A per-signal error
//! set was considered and rejected — it would duplicate a decision
//! `janet_signal_plan` has already made, and `catch` would then have to agree
//! with the plan or diverge from it silently.
//!
//! ## The decision is shared; only the delivery differs
//!
//! `janet_zig_signal_record` does everything a raise does except deliver it:
//! the plan, the coercion message, the commit into the return register, the
//! fiber flag. Both deliveries call it, so they cannot drift. It lives with the
//! rest of the signal decision, under `-Dsignal-core`, rather than here: this
//! file has no `export` at all, so every subsystem can import it without the
//! definition appearing once per object.
//!
//!  - A Zig caller gets `error.JanetSignal` returned, and reads
//!    `janet_vm.pending_signal` at the `catch`.
//!  - A C caller gets `janet_signalv`, which calls it and then jumps, exactly
//!    as before, with the signal taken from the same field. Since Phase 10
//!    Part 5 `janet_signalv` is itself Zig, under `-Dsignal-core`, and is the
//!    abi of `signal` below — one line of each.
//!
//! ## What makes the jump safe while both are live
//!
//! `SPIKE-10.md` has the demonstration; the claim is that a Zig error is
//! **fully unwound before any jump happens**. A converted function's abi
//! catches the error in its own frame and only then calls into the jump, so
//! every `errdefer` between the raise and that frame has already run and the
//! frame the jump leaves owns nothing. That is the inverse of the arrangement
//! Phases 7 to 9 lived with, and it is why `build.zig` can retire the `defer`
//! ban one file at a time instead of all at once.
//!
//! This file is itself jump-transparent and has to be, for one call: rendering
//! `%v` in a coercion message runs an abstract type's `tostring` callback,
//! which can still panic through C. It holds nothing, so the jump costs
//! nothing.
//!
//! Part 4 was expected to end that and did not. It moved the formatter to Zig,
//! but the jump was never the formatter's: the `tostring` callback is a C
//! function pointer supplied by `abstract.c` or by a native module, and it
//! jumps whatever language surrounds it. The marker comes off when abstract
//! callbacks stop jumping.

const std = @import("std");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");

/// The one error a raise-capable function can return.
pub const Error = error{JanetSignal};

/// Shorthand for a raise-capable result. `Raising(Janet)` reads better at a
/// declaration than `Error!c.Janet` and is the same type.
pub fn Raising(comptime T: type) type {
    return Error!T;
}

inline fn vm() *types.JanetVM {
    return c.vm();
}

const sig_error: types.JanetSignal = @intCast(constants.JANET_SIGNAL_ERROR);

// ---------------------------------------------------------------- raising

/// Raise `sig` with `message`. The Zig delivery: record, then return.
///
/// `janet_zig_signal_record` is the shared half and lives with the rest of the
/// signal decision, under `-Dsignal-core`, so that it has a C implementation to
/// be differential against. It does not return when the plan is `TOP_LEVEL`:
/// there is no scope to raise into, so the process or the thread ends.
pub fn signal(sig: types.JanetSignal, message: types.Janet) Error {
    c.janet_zig_signal_record(sig, message);
    return error.JanetSignal;
}

/// Raise an error carrying `message`, the equivalent of `janet_panicv`.
pub fn panicv(message: types.Janet) Error {
    return signal(sig_error, message);
}

/// Raise an error carrying a string, the equivalent of `janet_panic` and
/// `janet_panics`.
///
/// The parameter is a sentinel-terminated pointer rather than a slice because
/// `janet_cstring` walks to a NUL. A slice would accept one that has none and
/// read past its end; a string literal satisfies this signature as it stands.
pub fn panic(message: [*:0]const u8) Error {
    return panicv(c.janet_wrap_string(c.janet_cstring(message)));
}

/// `panicf` -- a raise whose message Janet's own formatter builds -- is not
/// here. It lives in `subsystems/pp_format.zig`, beside the engine, because
/// `%v` and the eight spellings of `%q` run the pretty printer and this file
/// is the shared mechanism rather than a subsystem. It was here while the
/// formatter was reached through C's variadic ABI, which needed nothing of
/// the sort; Part 18 removed that ABI and the dependency became visible.
/// The signal a raise decided on. Meaningful between a `record` and the
/// `catch` that answers it, and nowhere else.
pub inline fn pendingSignal() types.JanetSignal {
    return vm().pending_signal;
}

/// The value a raise published. Reads through `return_reg`, which is where the
/// innermost scope pointed it, so this is the same value `janet_try` would
/// have left in its `JanetTryState`.
pub inline fn pendingPayload() types.Janet {
    return if (vm().return_reg) |reg| reg.* else c.janet_wrap_nil();
}

// ---------------------------------------------------------- the cfunction

/// What a Janet builtin is, since Phase 10 Part 17g.
///
/// A cfunction returns `Error!Janet` and is called with Zig's own calling
/// convention, so a raise leaves it the way a raise leaves anything else --
/// as a returned error the caller must `try`. That is the last of the phase's
/// out-of-band mechanisms to go. Part 17e had a flag instead: `janet.h` fixed
/// the signature at `Janet (*)(int32_t, Janet *)`, a C function cannot return
/// an error union, so a raising builtin set `janet_vm.raising`, returned a
/// zero, and four call sites tested the flag on the next statement. The type
/// below makes forgetting the test a compile error, which is decision 5's
/// argument applied to the one interface it could not reach until the
/// registration tables were Zig.
///
/// **What it costs is every C cfunction.** A C body cannot have this type and
/// a C caller cannot invoke it, so the `c` arm of every selector that defines
/// a builtin goes with the change, along with `janet.h`'s four cfunction
/// declarations. Decision 2 said that, and decision 5 priced it.
///
/// **The arguments are a slice, since Phase 12 increment 5h.** `janet.h` fixed
/// them at `int32_t argc, Janet *argv` and translate-c rendered the second
/// `[*c]`, so every builtin took a pointer with a count beside it and `argv[n]`
/// read whatever was there. Both sides of this call are Zig -- the pointer is
/// reached by `@ptrCast` off the stored slot, with no thunk -- so the type can
/// say what is true and the index is checked. `DESIGN.md` section 9.
///
/// The alignment is not part of the type. `JANET_CFUNCTION_ALIGN` is a
/// property of each definition -- `corefn.alignment`, written at the `fn` --
/// and Zig coerces an over-aligned function pointer to a plain one, so the
/// type does not have to carry the maximum every `-Dnanbox-pointer-shift`
/// might ask for.
pub const CFunction = *const fn ([]types.Janet) Error!types.Janet;

/// A cfunction read out of the storage `janet.h` still describes.
///
/// The pointer itself is unchanged and the places that *hold* one are still
/// typed by C: a `Janet`'s union member, a `JanetRegExt` row, a
/// `JanetCFunRegistry` key, a C stack frame's `pc`. Those are the C ABI's
/// layout rather than its calling convention, and Part 18 is where they go.
/// So the cast is here, in one inline function, and everything downstream of
/// it is an ordinary Zig call that returns an error.
///
/// It replaces `callCFunction`, which existed to make sure the flag test was
/// not forgotten. There is no test to forget now, so what is left is the cast.
/// A published entry point whose C signature carries `(..., int32_t argc,
/// const Janet *argv)` where the Zig one takes a slice in their place.
///
/// Phase 12 increment 5h. `panicking` mirrors its subject's parameter list, so
/// it cannot build a `callconv(.c)` abi for a function taking a slice -- a
/// slice has no guaranteed in-memory representation. This expands the last
/// parameter back into the pair, which is what `janet_getslice`,
/// `janet_buffer_format`, `janet_call` and `janet_mcall` publish.
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

pub inline fn cfunction(slot: types.JanetCFunction) CFunction {
    return @ptrCast(slot.?);
}

/// The same pointer on its way into that storage, at registration.
pub inline fn stored(cfun: anytype) types.JanetCFunction {
    return @ptrCast(cfun);
}

// ------------------------------------------- reporting to a C caller

/// Hand a raise to a C caller by returning, rather than by jumping.
///
/// Phase 10 Part 17h, and the last out-of-band report this phase needs. The
/// remaining C callers are the contracts and four variadic shells, and neither
/// can keep the jump: a contract catches one with `janet_try`, which is a
/// `setjmp`, and the exit gate forbids a `setjmp` anywhere in the tree.
///
/// So an abi records the raise and returns a zeroed value, and its caller
/// tests `tookCRaise` on the next statement:
///
///     const s = c.janet_formatc("...", args);
///     if (raise.tookCRaise()) return error.JanetSignal;
///
/// **This is not Part 17e's flag coming back**, and the difference is the
/// population rather than the shape. 17e put a branch on the interpreter's hot
/// path, one per cfunction call, and 17g measured what removing it was worth.
/// This one is on the C ABI, which since 17g the runtime never crosses: the
/// only callers are `test/*.c` and the four shells C has to keep because Zig
/// 0.16 cannot define a variadic. It costs the runtime nothing because the
/// runtime does not call it, and it dies with the abis in Part 18.
///
/// Zeroed rather than `undefined`, for the reason 17e gave and which still
/// holds: an unspecified value that is determinate keeps a forgotten test
/// reproducible.
pub inline fn reportToC(comptime T: type) T {
    c.janet_zig_c_raise_record();
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
/// error set rather than an error union, which is what every `JANET_NO_RETURN`
/// abi was made of until the hinge. `janet_panicv` and `janet_await` are the
/// two ends of that population: one is an error the caller asked for, the
/// other is how a fiber suspends. Neither is `noreturn` any more, because the
/// only way to tell a C caller without returning was the jump.
///
///     export fn janet_panicv(message: c.Janet) callconv(.c) void {
///         raise.report(raise.panicv(message));
///     }
///
/// The parameter is unused by construction, exactly as the deleted `deliver`'s
/// was: everything the report needs is already in `janet_vm`.
pub inline fn report(_: Error) void {
    c.janet_zig_c_raise_record();
}

/// The value a call *through the C ABI* produced, or the error it reported.
///
/// Phase 10 Part 17h. A Zig caller that reaches its neighbour by symbol rather
/// than by import gets that neighbour's abi, which reports instead of
/// returning an error. This turns the report back:
///
///     const value = try raise.crossing(c.janet_call(fun, argc, argv));
///
/// **140 of these were found by removing the jump**, across twenty-seven
/// files. Part 17a's fold was meant to end them — a subsystem should reach a
/// neighbour by import, and then the error crosses as an error — and they
/// survived it because the jump made them work anyway. Each one is a crossing
/// the fold did not reach, marked rather than hidden, and each is an ordinary
/// import away from not needing this at all.
pub inline fn crossing(value: anytype) Error!@TypeOf(value) {
    if (tookCRaise()) return error.JanetSignal;
    return value;
}

/// Whether a raise reached an abi since this was last asked. Clears.
///
/// Meaningful on the statement after a call into C that could reach one, and
/// nowhere else.
pub inline fn tookCRaise() bool {
    return c.janet_zig_c_raise_take() != 0;
}

// ------------------------------------------- a call that may not raise

/// A raise-capable call at a site that cannot carry a raise, asserted rather
/// than delivered.
///
/// Phase 10's hinge. Some of what `deliverToC` was doing is not a C caller
/// waiting for a jump at all -- it is a *position*: a collector traversal, a
/// finalizer, a teardown, the entry point of a thread. There is no scope above
/// any of them and nothing that could consume an error, so the jump was going
/// somewhere arbitrary and the exit gate forbids it regardless.
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
    return result catch c.janet_zig_fatal(
        "a raise reached " ++ site ++ ", which cannot carry one",
    );
}

/// `declared` stood here until Phase 11 Part 26: the inverse of `panicking`,
/// putting the Zig signature on a C symbol that raised by jumping, so that a
/// converted caller could `try` it either way.
///
///     pub const getString = raise.declared(c.janet_getstring).call;
///
/// It was what an `_extern.zig` shim was made of, and what let a `c` selector
/// go on answering after its callers had converted: the error was **declared
/// and never returned**, because the C body jumped from the inside. Its last
/// users were the eleven stranded shims and `dynlib.zig`'s four `util.c`
/// symbols, and all fifteen went in Part 26.
///
/// `panicking` below is the surviving direction and is not its mirror. That one
/// wraps a Zig function so C can call it; this one wrapped a C function so Zig
/// could. Nothing left in the tree is a C function.
/// Build the abi of a raise-capable function: call it, and hand a
/// returned error to the C caller as a *report* rather than as a jump.
///
/// Phase 10 Part 17h changed the second half. It was `catch deliverToC()`
/// through six increments; it is now `catch reportToC(P)`, and the comment on
/// that function has the argument. What did not change is the first half: this
/// is still the one place a converted subsystem's abi is built, and it is
/// still built rather than written out, because 177 hand-written abis that
/// can drift from their implementations is a silent ABI change rather than a
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
