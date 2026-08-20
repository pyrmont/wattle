//! jump-transparent
//!
//! `run_vm`: the bytecode interpreter's main loop, its seventy-eight opcode
//! bodies, and the resume-state decoding at its head. This is Part 3 of Phase 9
//! and it is the increment that first puts a Zig frame on the VM call path.
//!
//! What is deliberately not here is everything that holds a `jmp_buf` or sits
//! above the loop: `janet_call`, `janet_step`, `janet_continue`,
//! `janet_continue_no_check`, `janet_check_can_resume` and `janet_pcall` all
//! stay in `src/core/vm.c` for Part 4, and `janet_continue_no_check` stays
//! there permanently through this phase by Phase 7's fourth rule.
//!
//! ## Dispatch
//!
//! A labelled `switch` with `continue :sw` in every arm, settled by Part 1
//! rather than assumed: the four-way skeleton in `probe-9/dispatch/` puts Zig's
//! labelled switch within 1.3% of C's computed gotos at both ends of a bracket
//! built to exaggerate the difference, and the real VM measured with
//! `-Dcomputed-gotos=false` puts the whole question of dispatch shape at three
//! percent or less on any real workload. `SPIKE-9.md` has the tables.
//!
//! The consequence for how this file is written is that the arms carry the
//! weight, not the loop. Each arm ends by advancing `pc` and continuing, and
//! the work in between is a direct translation of the C body: same order of
//! operations, same commits, same points at which `stack` is refreshed and the
//! two at which it deliberately is not.
//!
//! ## Raising
//!
//! By default a raise is a `longjmp` that passes straight through this frame to
//! the `setjmp` in `janet_continue_no_check`, which is exactly what happens to
//! the C loop's frame. Nothing here catches it and nothing here needs to: the
//! frame holds no resource, and every piece of state a resume depends on has
//! already been committed to the fiber. The loop's *own* raises — the arity
//! message, `"stack overflow"`, `"invalid constant"` — go the same way, through
//! `janet_panicf` and `janet_signalv`.
//!
//! `-Dcall-trampoline=true` selects the other mechanism, which Phase 7 built:
//! a `setjmp` scope one frame below this one catches a callee's signal and hands
//! it back as a value, and the loop's own raises are *returned* out of
//! `janet_run_vm` rather than jumped, since no scope can catch a raise in its
//! own frame. Both are supported and the difference is confined to `scoped` and
//! `raiseSignal`; every one of the seventy-eight arms reads the same either way,
//! because a raise arrives at the call site as a signal to propagate in both.
//!
//! Phase 7 closed the decision that the scopes would flip *on* in this
//! increment. Part 3 reversed it, and PLAN.md's Phase 9 section has the
//! reasoning rather than just the outcome. In short: the scope machinery is C
//! written to serve a Zig caller, so switching it on would have the increment
//! that moves the interpreter to Zig add C underneath it; every Phase 8
//! subsystem below this loop already raises through its own Zig frame, so the
//! scopes would make `run_vm` a carved-out exception to a mechanism the runtime
//! relies on everywhere; and the end state has neither a `setjmp` nor a
//! `longjmp`, so neither setting is closer to it. The scopes cost 6 to 21% on
//! call-heavy workloads, which is the smallest of those reasons.
//!
//! ## The file is jump-transparent, and that is load-bearing
//!
//! Under the default every raise crosses this frame. Under `-Dcall-trampoline`
//! three still do, all of them uncaught in the C loop too:
//!
//!  - `janet_vm_trace` reaches `janet_eprintf`, which reaches `janet_formatbv`,
//!    which panics on a string containing zeros.
//!  - `janet_collect` runs finalizers and `gcmark` callbacks. SPIKE-8 says
//!    those may not raise; nothing enforces it.
//!  - the allocators end an allocation failure in `JANET_OUT_OF_MEMORY`, which
//!    exits rather than jumping — checked, not assumed.
//!
//! Abandoning this frame is safe because there is nothing in it to release, and
//! `build.zig` enforces that half by rejecting `defer` and `errdefer` in a file
//! carrying the marker at the top.
//!
//! ## Two subsystems are imported rather than linked
//!
//! Part 2 measured what a translation-unit boundary costs the method-dispatch
//! path: 2.4-3.4% on the `methods` workload, because the C loop inlines
//! `janet_resolve_method`, `janet_call_nonfn` and the three fills outright while
//! a separate object cannot. The value layer is the same problem an order of
//! magnitude larger — `janet.h` gives a C caller `janet_checktype` and
//! `janet_unwrap_number` as macros, and reaching them through the symbol table
//! instead costs the arithmetic workload 89%, measured.
//!
//! So both arrive as modules. `build.zig` resolves each import to the Zig
//! subsystem when that selector is Zig and to a small `*_extern.zig` shim
//! declaring the C symbols when it is C, which keeps the selectors independent:
//! `-Dvm-calls=c` and `-Dvalue-wrap=c` still answer for the loop, out of line,
//! and that is the honest cost of those combinations rather than a silent
//! substitution. Folding an implementation in folds its exports in too, so
//! `build.zig` stops building those objects separately in the folded
//! configuration; two objects defining `janet_wrap_number` is a duplicate
//! symbol rather than a choice.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const vm_calls = @import("vm_calls");
const value_wrap = @import("value_wrap");

/// Whether this build checks for an interpreter interrupt between instructions.
/// `state_abi.h` restates `JANET_NO_INTERPRETER_INTERRUPT` as a valued macro,
/// because translate-c does not surface one defined without a value.
const has_interrupt = c.JANET_VM_HAS_INTERRUPT == 1;

/// Whether raise-capable callees are entered through a per-call `setjmp` scope.
/// Off by default; the header has the reasoning and the two shapes.
const trampoline = c.JANET_VM_CALL_TRAMPOLINE == 1;

/// `janet.h`'s frame size. The function-like macros over it — `janet_stack_frame`
/// and `janet_fiber_frame` — do not survive translation and are written out below.
const frame_size: i32 = c.JANET_FRAME_SIZE;

/// A sign-preserving widening, matching C's `int32_t` to `size_t` conversion in
/// `fiber->data + fiber->frame`. The operands are fiber stack indices the fiber
/// itself maintains, so none is negative in practice.
inline fn asSize(n: i32) usize {
    return @bitCast(@as(isize, n));
}

inline fn stackFrame(values: [*c]c.Janet) *c.JanetStackFrame {
    return @ptrCast(@alignCast(values - frame_size));
}

inline fn tupleHead(t: c.JanetTuple) *c.JanetTupleHead {
    return @ptrFromInt(@intFromPtr(t) -% @sizeOf(c.JanetTupleHead));
}

/// `func->envs[i]` as an lvalue. `envs` is a flexible array member and
/// translate-c drops it, so the slot is computed the way `janet_function`
/// allocates it: immediately after the header. `gc_mark.zig` reads the same
/// slots the same way.
inline fn funcEnvSlot(func: [*c]c.JanetFunction, i: i32) *[*c]c.JanetFuncEnv {
    const base = @intFromPtr(func) +% @sizeOf(c.JanetFunction);
    return @ptrFromInt(base +% @as(usize, @intCast(i)) *% @sizeOf([*c]c.JanetFuncEnv));
}

// ------------------------------------------------------------ value layer

/// The value operations the loop reaches on every instruction.
///
/// In C every one of these is a macro in `janet.h`, so `run_vm` pays a shift
/// and a compare for a type check rather than a call. Zig sees the *functions*
/// the same header declares, and reaching them through the symbol table costs
/// the arithmetic workload 89% -- measured, before this import existed. So the
/// value layer arrives the same way Part 2's helpers do: as a module `build.zig`
/// resolves to `value_wrap.zig` itself when that selector is Zig, and to
/// `value_wrap_extern.zig` when it is C.
const val = value_wrap.ops;

/// `janet_checkintrange` and `janet_checkuintrange` from `janet.h`, which are
/// macros with no function behind them. Written out the way `args_core.zig`
/// writes the same test: a range check first, so that the round trip through
/// the integer type — which is what rejects a fractional value — is always in
/// range and Zig's conversion safety check cannot fire. NaN fails the first
/// comparison in both languages.
inline fn checkRange(comptime T: type, dval: f64) bool {
    const lo: f64 = @floatFromInt(std.math.minInt(T));
    const hi: f64 = @floatFromInt(std.math.maxInt(T));
    if (!(dval >= lo and dval <= hi)) return false;
    const truncated: T = @intFromFloat(dval);
    const back: f64 = @floatFromInt(truncated);
    return dval == back;
}

// ------------------------------------------------------- instruction word

// One instruction word:
//
//     CC | BB | AA | OP
//     DD | DD | DD | OP
//     EE | EE | AA | OP

inline fn fA(pc: [*c]const u32) u32 {
    return (pc[0] >> 8) & 0xFF;
}
inline fn fB(pc: [*c]const u32) u32 {
    return (pc[0] >> 16) & 0xFF;
}
inline fn fC(pc: [*c]const u32) u32 {
    return pc[0] >> 24;
}
inline fn fD(pc: [*c]const u32) u32 {
    return pc[0] >> 8;
}
inline fn fE(pc: [*c]const u32) u32 {
    return pc[0] >> 16;
}

/// Signed interpretations of the same fields, as C's arithmetic right shift of
/// the word reinterpreted as `int32_t`.
inline fn fCS(pc: [*c]const u32) i32 {
    return @as(i32, @bitCast(pc[0])) >> 24;
}
inline fn fDS(pc: [*c]const u32) i32 {
    return @as(i32, @bitCast(pc[0])) >> 8;
}
inline fn fES(pc: [*c]const u32) i32 {
    return @as(i32, @bitCast(pc[0])) >> 16;
}

// ------------------------------------------------------------ scoped call

/// What one call through a C setjmp scope produced. `value` is meaningful only
/// when `sig` is `JANET_SIGNAL_OK`; `payload` only when it is not.
fn Scoped(comptime Value: type) type {
    return struct {
        sig: c.JanetSignal,
        value: Value,
        payload: c.Janet,
    };
}

fn ReturnOf(comptime F: type) type {
    return @typeInfo(F).@"fn".return_type.?;
}

/// Call `f` inside a `setjmp` scope that lives in a C frame, and hand back
/// whatever it produced or whatever signal it raised.
///
/// This is `vm.c`'s `vm_scoped` and its twenty-five `scoped_*` wrappers, with
/// the enumeration replaced by a thunk the compiler writes. The context struct
/// holds the arguments on the way in and the result on the way out, and lives
/// in the caller's frame; the thunk writes `ret` from its own frame, and the
/// caller reads it only after seeing `JANET_SIGNAL_OK`. That ordering is what
/// keeps the C rule about indeterminate locals after a `longjmp` satisfied.
inline fn scoped(comptime f: anytype, args: anytype) Scoped(ReturnOf(@TypeOf(f))) {
    if (!trampoline) {
        // The default. No scope: a raise in the callee jumps past this frame,
        // which is what the C loop does without JANET_CALL_TRAMPOLINE. Nothing
        // after the call runs on that path, and nothing needs to -- every caller
        // here already checks the signal before touching the result, so the two
        // shapes agree at the call site.
        return .{ .sig = c.JANET_SIGNAL_OK, .value = @call(.auto, f, args), .payload = undefined };
    }
    const Context = struct {
        args: @TypeOf(args),
        ret: ReturnOf(@TypeOf(f)),

        fn thunk(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.ret = @call(.auto, f, self.args);
        }
    };
    var context: Context = .{ .args = args, .ret = undefined };
    var payload: c.Janet = undefined;
    const sig = c.janet_vm_scoped(&Context.thunk, &context, &payload);
    return .{ .sig = sig, .value = context.ret, .payload = payload };
}

/// `janet_in`, `janet_get` and the rest of the access layer are reached through
/// `scoped`, which needs a comptime-known callee. A `JanetCFunction` is not one,
/// so the indirection is named here and the pointer travels as an argument.
fn invokeCFunction(cfun: c.JanetCFunction, argc: i32, argv: [*c]c.Janet) callconv(.c) c.Janet {
    return cfun.?(argc, argv);
}

/// `src/core/util.h`, declared here rather than translated, for the reason
/// `abi.zig` gives: that header falls through to `dlfcn.h` on any target it does
/// not recognise as Windows and breaks the shared translation. The `Janet`
/// parameters are `abi.zig`'s own type, so nothing about the single-translation
/// rule is at stake.
extern fn janet_next_impl(ds: c.Janet, key: c.Janet, is_interpreter: c_int) callconv(.c) c.Janet;

/// `janet_next_impl` always takes 1 from `run_vm`; naming that here keeps the
/// argument tuple at the call site the shape the C macro has.
fn nextImpl(ds: c.Janet, key: c.Janet) callconv(.c) c.Janet {
    return janet_next_impl(ds, key, 1);
}

// ------------------------------------------------------- opcode templates

/// The four arithmetic operators that have both a register and an immediate
/// form, plus the six bitwise ones. The method names are the operator spelled
/// out, exactly as C's `#op` stringification produces them — which is why
/// `JOP_SHIFT_RIGHT` and `JOP_SHIFT_RIGHT_UNSIGNED` both fall back to `:>>`.
const Op = enum {
    add,
    sub,
    mul,
    div,
    band,
    bor,
    bxor,
    shl,
    shr,
    shru,

    inline fn method(comptime self: Op) [*c]const u8 {
        return switch (self) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .band => "&",
            .bor => "|",
            .bxor => "^",
            .shl => "<<",
            .shr => ">>",
            .shru => ">>",
        };
    }

    inline fn rmethod(comptime self: Op) [*c]const u8 {
        return switch (self) {
            .add => "r+",
            .sub => "r-",
            .mul => "r*",
            .div => "r/",
            .band => "r&",
            .bor => "r|",
            .bxor => "r^",
            .shl => "r<<",
            .shr => "r>>",
            .shru => "r>>",
        };
    }

    inline fn applyNumber(comptime self: Op, x1: f64, x2: f64) f64 {
        return switch (self) {
            .add => x1 + x2,
            .sub => x1 - x2,
            .mul => x1 * x2,
            .div => x1 / x2,
            else => @compileError("not an arithmetic operator"),
        };
    }

    /// The integer type the operand is narrowed to, and the message naming it.
    inline fn intType(comptime self: Op) type {
        return switch (self) {
            .shru => u32,
            else => i32,
        };
    }

    inline fn intMessage(comptime self: Op) []const u8 {
        return if (self.intType() == u32) "32-bit unsigned integers" else "32-bit signed integers";
    }

    /// The bitwise operators, on the narrowed left operand and an `int32_t`
    /// right operand, with the result cast back before it is wrapped. C spells
    /// the cast `(type1) (x1 op x2)`; the shifts are the ones where it matters.
    inline fn applyBits(comptime self: Op, x1: self.intType(), x2: i32) self.intType() {
        const T = self.intType();
        const shift: std.math.Log2Int(T) = @truncate(@as(u32, @bitCast(x2)));
        return switch (self) {
            .band => x1 & @as(T, @bitCast(x2)),
            .bor => x1 | @as(T, @bitCast(x2)),
            .bxor => x1 ^ @as(T, @bitCast(x2)),
            .shl => x1 << shift,
            .shr, .shru => x1 >> shift,
            else => @compileError("not a bitwise operator"),
        };
    }
};

/// The six comparison operators, which reach `janet_compare` rather than a
/// method when either operand is not a number.
const Cmp = enum {
    lt,
    le,
    gt,
    ge,

    inline fn applyNumber(comptime self: Cmp, x1: f64, x2: f64) bool {
        return switch (self) {
            .lt => x1 < x2,
            .le => x1 <= x2,
            .gt => x1 > x2,
            .ge => x1 >= x2,
        };
    }

    inline fn applyOrder(comptime self: Cmp, cmp: c_int) bool {
        return switch (self) {
            .lt => cmp < 0,
            .le => cmp <= 0,
            .gt => cmp > 0,
            .ge => cmp >= 0,
        };
    }
};

// ------------------------------------------------------- interpreter state

/// `run_vm`'s three registers plus the fiber they belong to.
///
/// C declares `stack`, `pc` and `func` `register` and keeps the `setjmp` out of
/// their frame so that stays true. Here they are fields of a structure whose
/// address never reaches a call the optimiser cannot see through: every method
/// below is `inline`, and the only pointer handed to a C frame is the context
/// `scoped` builds, which is a separate object holding copies.
const Interp = struct {
    fiber: [*c]c.JanetFiber,
    stack: [*c]c.Janet,
    pc: [*c]u32,
    func: [*c]c.JanetFunction,

    // ---- state movement

    /// `vm_commit`. Publish the program counter before anything that could
    /// raise, so a stack trace names the instruction rather than its
    /// predecessor.
    inline fn commit(self: *Interp) void {
        stackFrame(self.stack).pc = self.pc;
    }

    /// `vm_restore`. Re-read all three registers from the frame the fiber is
    /// now in.
    inline fn restore(self: *Interp) void {
        self.stack = self.fiber.*.data + asSize(self.fiber.*.frame);
        self.func = stackFrame(self.stack).func;
        self.pc = stackFrame(self.stack).pc;
    }

    /// `stack = fiber->data + fiber->frame`, which the opcode bodies do on
    /// their own after any call that could have moved the stack.
    inline fn reload(self: *Interp) void {
        self.stack = self.fiber.*.data + asSize(self.fiber.*.frame);
    }

    inline fn nextOp(self: *const Interp) u32 {
        return self.pc[0] & 0xFF;
    }

    inline fn maybeCollect(self: *const Interp) void {
        _ = self;
        if (c.janet_vm.next_collection >= c.janet_vm.gc_interval) c.janet_collect();
    }

    // ---- leaving the loop

    /// `vm_return`.
    inline fn ret(self: *Interp, sig: c.JanetSignal, value: c.Janet) c.JanetSignal {
        c.janet_vm.return_reg[0] = value;
        self.commit();
        return sig;
    }

    /// `vm_return_no_restore`.
    inline fn retNoRestore(self: *Interp, sig: c.JanetSignal, value: c.Janet) c.JanetSignal {
        _ = self;
        c.janet_vm.return_reg[0] = value;
        return sig;
    }

    /// `vm_raise_signal`. Returns the error out of `janet_run_vm` rather than
    /// jumping past its frame, and sets `JANET_FIBER_DID_LONGJUMP` exactly as
    /// `janet_signalv` does, because the resume path reads that flag to pop a C
    /// frame and to turn a raise at a tail call into an implicit return.
    ///
    /// It does not commit. Each site keeps whatever commit it already had,
    /// because that is not uniform in the C: `JOP_PUSH_ARRAY` never committed,
    /// `JOP_CALL` committed before entering `janet_fiber_funcframe` and its
    /// `stack` is stale afterwards, and `JOP_TAILCALL` commits to a frame it
    /// recomputes.
    inline fn raiseSignal(self: *Interp, sig: c.JanetSignal, value: c.Janet) c.JanetSignal {
        _ = self;
        if (!trampoline) {
            // The jump the C loop takes without JANET_CALL_TRAMPOLINE.
            // janet_signalv sets JANET_FIBER_DID_LONGJUMP itself, which is the
            // flag the branch below has to set by hand.
            c.janet_signalv(sig, value);
            unreachable;
        }
        c.janet_vm.return_reg[0] = value;
        if (c.janet_vm.fiber != null) {
            c.janet_vm.fiber.*.flags |= c.JANET_FIBER_DID_LONGJUMP;
        }
        return sig;
    }

    /// `vm_raisev`.
    inline fn raisev(self: *Interp, value: c.Janet) c.JanetSignal {
        return self.raiseSignal(c.JANET_SIGNAL_ERROR, value);
    }

    /// `vm_raisef`. The format string and its arguments cross the C variadic
    /// ABI untouched, which is the whole reason the message is built in C:
    /// `janet_vm_error_string` is `janet_panicf` with the jump removed, so the
    /// two produce the same bytes by construction rather than by inspection.
    inline fn raisef(self: *Interp, comptime format: [*c]const u8, args: anytype) c.JanetSignal {
        if (!trampoline) {
            @call(.auto, c.janet_panicf, .{format} ++ args);
            unreachable;
        }
        return self.raisev(@call(.auto, c.janet_vm_error_string, .{format} ++ args));
    }

    /// `vm_throw`: commit, then raise a plain string.
    inline fn throw(self: *Interp, message: [*c]const u8) c.JanetSignal {
        self.commit();
        return self.raisev(c.janet_cstringv(message));
    }

    /// `vm_assert`.
    inline fn assert(self: *Interp, condition: bool, message: [*c]const u8) ?c.JanetSignal {
        if (condition) return null;
        return self.throw(message);
    }

    /// `vm_assert_type`.
    inline fn assertType(self: *Interp, x: c.Janet, comptime t: c.JanetType) ?c.JanetSignal {
        if (val.checkType(x, t)) return null;
        self.commit();
        return self.raisef("expected %T, got %v", .{ @as(c_int, 1) << t, x });
    }

    /// `vm_assert_types`.
    inline fn assertTypes(self: *Interp, x: c.Janet, typeflags: c_int) ?c.JanetSignal {
        if (val.checkTypes(x, typeflags)) return null;
        self.commit();
        return self.raisef("expected %T, got %v", .{ typeflags, x });
    }

    /// `vm_maybe_auto_suspend`. The condition is only ever a comparison on an
    /// instruction field, so evaluating it in a build without the interrupt —
    /// where C does not evaluate it at all — costs nothing and changes nothing.
    inline fn maybeAutoSuspend(self: *Interp, condition: bool) ?c.JanetSignal {
        if (!has_interrupt) return null;
        if (condition and c.janet_atomic_load_relaxed(&c.janet_vm.auto_suspend) != 0) {
            self.fiber.*.flags |= (c.JANET_FIBER_RESUME_NO_USEVAL | c.JANET_FIBER_RESUME_NO_SKIP);
            return self.ret(c.JANET_SIGNAL_INTERRUPT, val.wrapNil());
        }
        return null;
    }

    // ---- opcode templates
    //
    // Each returns null to mean "the instruction is done and `pc` is where the
    // next dispatch should read it", and a signal to mean "leave the loop".
    // The garbage-collector check belongs to the template rather than to the
    // arm because the two paths through most of these disagree about it: the
    // numeric path allocates nothing, and the fallback path can allocate a
    // whole method call's worth.

    /// `JOP_RETURN` and `JOP_RETURN_NIL`, which differ only in where the value
    /// comes from.
    inline fn doReturn(self: *Interp, retval: c.Janet) ?c.JanetSignal {
        const entrance_frame = (stackFrame(self.stack).flags & c.JANET_STACKFRAME_ENTRANCE) != 0;
        c.janet_fiber_popframe(self.fiber);
        if (entrance_frame) return self.retNoRestore(c.JANET_SIGNAL_OK, retval);
        self.restore();
        self.stack[fA(self.pc)] = retval;
        self.maybeCollect();
        self.pc += 1;
        return null;
    }

    /// `JOP_LOAD_UPVALUE` and `JOP_SET_UPVALUE`. The three assertions and the
    /// on-stack/off-stack choice are shared; `store` is comptime, so neither
    /// opcode pays a branch to find out which one it is.
    inline fn upvalue(self: *Interp, comptime store: bool) ?c.JanetSignal {
        const eindex: i32 = @intCast(fB(self.pc));
        const vindex: i32 = @intCast(fC(self.pc));
        if (self.assert(self.func.*.def.*.environments_length > eindex, "invalid upvalue environment")) |s| return s;
        const env = funcEnvSlot(self.func, eindex).*;
        if (self.assert(env.*.length > vindex, "invalid upvalue index")) |s| return s;
        if (self.assert(c.janet_env_valid(env) != 0, "invalid upvalue environment")) |s| return s;
        const slot: [*c]c.Janet = if (env.*.offset > 0)
            env.*.as.fiber.*.data + asSize(env.*.offset + vindex)
        else
            env.*.as.values + asSize(vindex);
        if (store) {
            slot[0] = self.stack[fA(self.pc)];
        } else {
            self.stack[fA(self.pc)] = slot[0];
        }
        self.pc += 1;
        return null;
    }

    /// `JOP_EQUALS` and `JOP_NOT_EQUALS`.
    inline fn equals(self: *Interp, comptime negate: bool) ?c.JanetSignal {
        self.commit();
        const r = scoped(c.janet_equals, .{ self.stack[fB(self.pc)], self.stack[fC(self.pc)] });
        if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
        const eq = r.value != 0;
        self.stack[fA(self.pc)] = val.wrapBoolean(if (negate) !eq else eq);
        self.pc += 1;
        return null;
    }

    /// `vm_binop_immediate`.
    inline fn binopImmediate(self: *Interp, comptime op: Op) ?c.JanetSignal {
        const op1 = self.stack[fB(self.pc)];
        if (!val.isNumber(op1)) {
            self.commit();
            var argv = [_]c.Janet{ op1, val.wrapNumber(@floatFromInt(fCS(self.pc))) };
            const r = scoped(vm_calls.mcall, .{ op.method(), 2, &argv });
            if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
            self.reload();
            self.stack[fA(self.pc)] = r.value;
            self.maybeCollect();
        } else {
            const x1 = val.unwrapNumber(op1);
            self.stack[fA(self.pc)] = val.wrapNumber(op.applyNumber(x1, @floatFromInt(fCS(self.pc))));
        }
        self.pc += 1;
        return null;
    }

    /// `_vm_bitop_immediate`.
    inline fn bitopImmediate(self: *Interp, comptime op: Op) ?c.JanetSignal {
        const op1 = self.stack[fB(self.pc)];
        if (!val.isNumber(op1)) {
            self.commit();
            var argv = [_]c.Janet{ op1, val.wrapNumber(@floatFromInt(fCS(self.pc))) };
            const r = scoped(vm_calls.mcall, .{ op.method(), 2, &argv });
            if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
            self.reload();
            self.stack[fA(self.pc)] = r.value;
            self.maybeCollect();
        } else {
            const T = op.intType();
            const y1 = val.unwrapNumber(op1);
            if (!checkRange(T, y1)) {
                self.commit();
                return self.raisef("value %v out of range for " ++ op.intMessage(), .{op1});
            }
            const x1: T = @intFromFloat(y1);
            self.stack[fA(self.pc)] = val.wrapNumber(intToDouble(T, op.applyBits(x1, fCS(self.pc))));
        }
        self.pc += 1;
        return null;
    }

    /// `_vm_binop`.
    inline fn binop(self: *Interp, comptime op: Op) ?c.JanetSignal {
        const op1 = self.stack[fB(self.pc)];
        const op2 = self.stack[fC(self.pc)];
        if (val.isNumber(op1) and val.isNumber(op2)) {
            const x1 = val.unwrapNumber(op1);
            const x2 = val.unwrapNumber(op2);
            self.stack[fA(self.pc)] = val.wrapNumber(op.applyNumber(x1, x2));
            self.pc += 1;
            return null;
        }
        return self.binopFallback(op.method(), op.rmethod(), op1, op2);
    }

    /// `_vm_bitop`.
    inline fn bitop(self: *Interp, comptime op: Op) ?c.JanetSignal {
        const op1 = self.stack[fB(self.pc)];
        const op2 = self.stack[fC(self.pc)];
        if (val.isNumber(op1) and val.isNumber(op2)) {
            const T = op.intType();
            const y1 = val.unwrapNumber(op1);
            const y2 = val.unwrapNumber(op2);
            if (!checkRange(T, y1)) {
                self.commit();
                return self.raisef("value %v out of range for " ++ op.intMessage(), .{op1});
            }
            if (!checkRange(i32, y2)) {
                self.commit();
                return self.raisef("rhs must be valid 32-bit signed integer, got %f", .{op2});
            }
            const x1: T = @intFromFloat(y1);
            const x2: i32 = @intFromFloat(y2);
            self.stack[fA(self.pc)] = val.wrapNumber(intToDouble(T, op.applyBits(x1, x2)));
            self.pc += 1;
            return null;
        }
        return self.binopFallback(op.method(), op.rmethod(), op1, op2);
    }

    /// The tail both fallbacks share: commit, try `:op` on the left operand and
    /// then `:rop` on the right, refresh `stack` because the call may have moved
    /// it, and check the collector.
    inline fn binopFallback(
        self: *Interp,
        lmethod: [*c]const u8,
        rmethod: [*c]const u8,
        op1: c.Janet,
        op2: c.Janet,
    ) ?c.JanetSignal {
        self.commit();
        const r = scoped(vm_calls.binopCall, .{ lmethod, rmethod, op1, op2 });
        if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
        self.reload();
        self.stack[fA(self.pc)] = r.value;
        self.maybeCollect();
        self.pc += 1;
        return null;
    }

    /// `vm_compop`.
    inline fn compop(self: *Interp, comptime op: Cmp) ?c.JanetSignal {
        const op1 = self.stack[fB(self.pc)];
        const op2 = self.stack[fC(self.pc)];
        if (val.isNumber(op1) and val.isNumber(op2)) {
            const x1 = val.unwrapNumber(op1);
            const x2 = val.unwrapNumber(op2);
            self.stack[fA(self.pc)] = val.wrapBoolean(op.applyNumber(x1, x2));
            self.pc += 1;
            return null;
        }
        return self.compareFallback(op, op1, op2);
    }

    /// `vm_compop_imm`.
    inline fn compopImmediate(self: *Interp, comptime op: Cmp) ?c.JanetSignal {
        const op1 = self.stack[fB(self.pc)];
        if (val.isNumber(op1)) {
            const x1 = val.unwrapNumber(op1);
            const x2: f64 = @floatFromInt(fCS(self.pc));
            self.stack[fA(self.pc)] = val.wrapBoolean(op.applyNumber(x1, x2));
            self.pc += 1;
            return null;
        }
        return self.compareFallback(op, op1, val.wrapInteger(fCS(self.pc)));
    }

    inline fn compareFallback(self: *Interp, comptime op: Cmp, op1: c.Janet, op2: c.Janet) ?c.JanetSignal {
        self.commit();
        const r = scoped(c.janet_compare, .{ op1, op2 });
        if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
        const a = val.wrapBoolean(op.applyOrder(r.value));
        self.reload();
        self.stack[fA(self.pc)] = a;
        self.maybeCollect();
        self.pc += 1;
        return null;
    }
};

/// `janet_wrap_number((type1) (x1 op x2))` in C, where `type1` is `int32_t` or
/// `uint32_t`. Named so that the `uint32_t` case, which is the only one whose
/// result can exceed what an `int32_t` holds, cannot be written the other way
/// by accident.
inline fn intToDouble(comptime T: type, x: T) f64 {
    return @floatFromInt(x);
}

// -------------------------------------------------------------- the loop

/// `run_vm`, renamed for the same reason Part 2 renamed five of its callees: a
/// static's name becomes a library symbol the moment its definition moves to
/// another translation unit, and `run_vm` is too general a name to put there.
fn runVm(fiber_in: [*c]c.JanetFiber, in: c.Janet) callconv(.c) c.JanetSignal {
    // Seventy-eight arms, each of which inlines several comptime templates.
    @setEvalBranchQuota(20000);
    var self: Interp = .{
        .fiber = fiber_in,
        .stack = undefined,
        .pc = undefined,
        .func = undefined,
    };
    const fiber = fiber_in;

    // A signal injected while the fiber was suspended is delivered instead of
    // resuming. It travels in `gc.flags` rather than in `flags`; `vm.c`'s
    // janet_signal_inject has the reason.
    if ((fiber.*.flags & c.JANET_FIBER_RESUME_SIGNAL) != 0) {
        const sig: c.JanetSignal = @intCast(@as(u32, @bitCast(fiber.*.gc.flags & c.JANET_FIBER_STATUS_MASK)) >> c.JANET_FIBER_STATUS_OFFSET);
        fiber.*.gc.flags &= ~@as(i32, c.JANET_FIBER_STATUS_MASK);
        fiber.*.flags &= ~@as(i32, c.JANET_FIBER_RESUME_SIGNAL | c.JANET_FIBER_FLAG_MASK);
        c.janet_vm.return_reg[0] = in;
        return sig;
    }

    self.restore();

    if ((fiber.*.flags & c.JANET_FIBER_DID_LONGJUMP) != 0) {
        if (stackFrame(self.stack).func == null) {
            // Inside a c function
            c.janet_fiber_popframe(fiber);
            self.restore();
        }
        // Check if we were at a tail call instruction. If so, do implicit return.
        if ((self.pc[0] & 0xFF) == c.JOP_TAILCALL) {
            const entrance_frame = (stackFrame(self.stack).flags & c.JANET_STACKFRAME_ENTRANCE) != 0;
            c.janet_fiber_popframe(fiber);
            if (entrance_frame) {
                fiber.*.flags &= ~@as(i32, c.JANET_FIBER_FLAG_MASK);
                return self.ret(c.JANET_SIGNAL_OK, in);
            }
            self.restore();
        }
    }

    if ((fiber.*.flags & c.JANET_FIBER_RESUME_NO_USEVAL) == 0) self.stack[fA(self.pc)] = in;
    if ((fiber.*.flags & c.JANET_FIBER_RESUME_NO_SKIP) == 0) self.pc += 1;

    const breakpoint_mask: u32 = if ((fiber.*.flags & c.JANET_FIBER_BREAKPOINT) != 0) 0x7F else 0xFF;
    const first_opcode: u32 = self.pc[0] & breakpoint_mask;

    fiber.*.flags &= ~@as(i32, c.JANET_FIBER_FLAG_MASK);

    sw: switch (first_opcode) {
        c.JOP_NOOP => {
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_ERROR => return self.ret(c.JANET_SIGNAL_ERROR, self.stack[fA(self.pc)]),

        c.JOP_TYPECHECK => {
            if (self.assertTypes(self.stack[fA(self.pc)], @intCast(fE(self.pc)))) |s| return s;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_RETURN => {
            if (self.doReturn(self.stack[fD(self.pc)])) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_RETURN_NIL => {
            if (self.doReturn(val.wrapNil())) |s| return s;
            continue :sw self.nextOp();
        },

        c.JOP_ADD_IMMEDIATE => {
            if (self.binopImmediate(.add)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_ADD => {
            if (self.binop(.add)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_SUBTRACT_IMMEDIATE => {
            if (self.binopImmediate(.sub)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_SUBTRACT => {
            if (self.binop(.sub)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_MULTIPLY_IMMEDIATE => {
            if (self.binopImmediate(.mul)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_MULTIPLY => {
            if (self.binop(.mul)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_DIVIDE_IMMEDIATE => {
            if (self.binopImmediate(.div)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_DIVIDE => {
            if (self.binop(.div)) |s| return s;
            continue :sw self.nextOp();
        },

        c.JOP_DIVIDE_FLOOR => {
            const op1 = self.stack[fB(self.pc)];
            const op2 = self.stack[fC(self.pc)];
            if (val.isNumber(op1) and val.isNumber(op2)) {
                const x1 = val.unwrapNumber(op1);
                const x2 = val.unwrapNumber(op2);
                self.stack[fA(self.pc)] = val.wrapNumber(@floor(x1 / x2));
                self.pc += 1;
                continue :sw self.nextOp();
            }
            if (self.binopFallback("div", "rdiv", op1, op2)) |s| return s;
            continue :sw self.nextOp();
        },

        c.JOP_MODULO => {
            const op1 = self.stack[fB(self.pc)];
            const op2 = self.stack[fC(self.pc)];
            if (val.isNumber(op1) and val.isNumber(op2)) {
                const x1 = val.unwrapNumber(op1);
                const x2 = val.unwrapNumber(op2);
                if (x2 == 0) {
                    self.stack[fA(self.pc)] = val.wrapNumber(x1);
                } else {
                    const intres = x2 * @floor(x1 / x2);
                    self.stack[fA(self.pc)] = val.wrapNumber(x1 - intres);
                }
                self.pc += 1;
                continue :sw self.nextOp();
            }
            if (self.binopFallback("mod", "rmod", op1, op2)) |s| return s;
            continue :sw self.nextOp();
        },

        c.JOP_REMAINDER => {
            const op1 = self.stack[fB(self.pc)];
            const op2 = self.stack[fC(self.pc)];
            if (val.isNumber(op1) and val.isNumber(op2)) {
                const x1 = val.unwrapNumber(op1);
                const x2 = val.unwrapNumber(op2);
                self.stack[fA(self.pc)] = val.wrapNumber(fmod(x1, x2));
                self.pc += 1;
                continue :sw self.nextOp();
            }
            if (self.binopFallback("%", "r%", op1, op2)) |s| return s;
            continue :sw self.nextOp();
        },

        c.JOP_BAND => {
            if (self.bitop(.band)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_BOR => {
            if (self.bitop(.bor)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_BXOR => {
            if (self.bitop(.bxor)) |s| return s;
            continue :sw self.nextOp();
        },

        c.JOP_BNOT => {
            const op = self.stack[fE(self.pc)];
            if (val.isNumber(op)) {
                self.stack[fA(self.pc)] = val.wrapInteger(~val.unwrapInteger(op));
                self.pc += 1;
                continue :sw self.nextOp();
            }
            self.commit();
            const r = scoped(vm_calls.unaryCall, .{ "~", op });
            if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
            self.reload();
            self.stack[fA(self.pc)] = r.value;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_SHIFT_RIGHT_UNSIGNED => {
            if (self.bitop(.shru)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_SHIFT_RIGHT_UNSIGNED_IMMEDIATE => {
            if (self.bitopImmediate(.shru)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_SHIFT_RIGHT => {
            if (self.bitop(.shr)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_SHIFT_RIGHT_IMMEDIATE => {
            if (self.bitopImmediate(.shr)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_SHIFT_LEFT => {
            if (self.bitop(.shl)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_SHIFT_LEFT_IMMEDIATE => {
            if (self.bitopImmediate(.shl)) |s| return s;
            continue :sw self.nextOp();
        },

        c.JOP_MOVE_NEAR => {
            self.stack[fA(self.pc)] = self.stack[fE(self.pc)];
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_MOVE_FAR => {
            self.stack[fE(self.pc)] = self.stack[fA(self.pc)];
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_JUMP => {
            if (self.maybeAutoSuspend(fDS(self.pc) <= 0)) |s| return s;
            self.pc += asOffset(fDS(self.pc));
            continue :sw self.nextOp();
        },

        c.JOP_JUMP_IF => {
            if (val.truthy(self.stack[fA(self.pc)])) {
                if (self.maybeAutoSuspend(fES(self.pc) <= 0)) |s| return s;
                self.pc += asOffset(fES(self.pc));
            } else {
                self.pc += 1;
            }
            continue :sw self.nextOp();
        },

        c.JOP_JUMP_IF_NOT => {
            if (val.truthy(self.stack[fA(self.pc)])) {
                self.pc += 1;
            } else {
                if (self.maybeAutoSuspend(fES(self.pc) <= 0)) |s| return s;
                self.pc += asOffset(fES(self.pc));
            }
            continue :sw self.nextOp();
        },

        c.JOP_JUMP_IF_NIL => {
            if (val.checkType(self.stack[fA(self.pc)], c.JANET_NIL)) {
                if (self.maybeAutoSuspend(fES(self.pc) <= 0)) |s| return s;
                self.pc += asOffset(fES(self.pc));
            } else {
                self.pc += 1;
            }
            continue :sw self.nextOp();
        },

        c.JOP_JUMP_IF_NOT_NIL => {
            if (val.checkType(self.stack[fA(self.pc)], c.JANET_NIL)) {
                self.pc += 1;
            } else {
                if (self.maybeAutoSuspend(fES(self.pc) <= 0)) |s| return s;
                self.pc += asOffset(fES(self.pc));
            }
            continue :sw self.nextOp();
        },

        c.JOP_LESS_THAN => {
            if (self.compop(.lt)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_LESS_THAN_EQUAL => {
            if (self.compop(.le)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_LESS_THAN_IMMEDIATE => {
            if (self.compopImmediate(.lt)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_GREATER_THAN => {
            if (self.compop(.gt)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_GREATER_THAN_EQUAL => {
            if (self.compop(.ge)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_GREATER_THAN_IMMEDIATE => {
            if (self.compopImmediate(.gt)) |s| return s;
            continue :sw self.nextOp();
        },

        c.JOP_EQUALS => {
            if (self.equals(false)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_NOT_EQUALS => {
            if (self.equals(true)) |s| return s;
            continue :sw self.nextOp();
        },

        c.JOP_EQUALS_IMMEDIATE => {
            const x = self.stack[fB(self.pc)];
            const eq = val.isNumber(x) and val.unwrapNumber(x) == @as(f64, @floatFromInt(fCS(self.pc)));
            self.stack[fA(self.pc)] = val.wrapBoolean(eq);
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_NOT_EQUALS_IMMEDIATE => {
            const x = self.stack[fB(self.pc)];
            const ne = !val.isNumber(x) or val.unwrapNumber(x) != @as(f64, @floatFromInt(fCS(self.pc)));
            self.stack[fA(self.pc)] = val.wrapBoolean(ne);
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_COMPARE => {
            self.commit();
            const r = scoped(c.janet_compare, .{ self.stack[fB(self.pc)], self.stack[fC(self.pc)] });
            if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
            const a = val.wrapInteger(r.value);
            self.reload();
            self.stack[fA(self.pc)] = a;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_NEXT => {
            self.commit();
            const r = scoped(nextImpl, .{ self.stack[fB(self.pc)], self.stack[fC(self.pc)] });
            if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
            self.restore();
            self.stack[fA(self.pc)] = r.value;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_LOAD_NIL => {
            self.stack[fD(self.pc)] = val.wrapNil();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_LOAD_TRUE => {
            self.stack[fD(self.pc)] = val.wrapTrue();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_LOAD_FALSE => {
            self.stack[fD(self.pc)] = val.wrapFalse();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_LOAD_INTEGER => {
            self.stack[fA(self.pc)] = val.wrapInteger(fES(self.pc));
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_LOAD_CONSTANT => {
            const cindex: i32 = @intCast(fE(self.pc));
            if (self.assert(cindex < self.func.*.def.*.constants_length, "invalid constant")) |s| return s;
            self.stack[fA(self.pc)] = self.func.*.def.*.constants[asSize(cindex)];
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_LOAD_SELF => {
            self.stack[fD(self.pc)] = val.wrapFunction(self.func);
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_LOAD_UPVALUE => {
            if (self.upvalue(false)) |s| return s;
            continue :sw self.nextOp();
        },
        c.JOP_SET_UPVALUE => {
            if (self.upvalue(true)) |s| return s;
            continue :sw self.nextOp();
        },

        c.JOP_CLOSURE => {
            const defindex: i32 = @intCast(fE(self.pc));
            if (self.assert(defindex < self.func.*.def.*.defs_length, "invalid funcdef")) |s| return s;
            const fd = self.func.*.def.*.defs[asSize(defindex)];
            const elen = fd.*.environments_length;
            const fn_ptr: [*c]c.JanetFunction = @ptrCast(@alignCast(c.janet_gcalloc(
                c.JANET_MEMORY_FUNCTION,
                @sizeOf(c.JanetFunction) + @as(usize, @intCast(elen)) * @sizeOf([*c]c.JanetFuncEnv),
            )));
            fn_ptr.*.def = fd;
            var i: i32 = 0;
            while (i < elen) : (i += 1) {
                const inherit = fd.*.environments[asSize(i)];
                if (inherit == -1 or inherit >= self.func.*.def.*.environments_length) {
                    const frame = stackFrame(self.stack);
                    if (frame.env == null) {
                        // Lazy capture of current stack frame
                        const env: [*c]c.JanetFuncEnv = @ptrCast(@alignCast(c.janet_gcalloc(
                            c.JANET_MEMORY_FUNCENV,
                            @sizeOf(c.JanetFuncEnv),
                        )));
                        env.*.offset = fiber.*.frame;
                        env.*.as.fiber = fiber;
                        env.*.length = self.func.*.def.*.slotcount;
                        frame.env = env;
                    }
                    funcEnvSlot(fn_ptr, i).* = frame.env;
                } else {
                    funcEnvSlot(fn_ptr, i).* = funcEnvSlot(self.func, inherit).*;
                }
            }
            self.stack[fA(self.pc)] = val.wrapFunction(fn_ptr);
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_PUSH => {
            const r = scoped(c.janet_fiber_push, .{ fiber, self.stack[fD(self.pc)] });
            if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
            self.reload();
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_PUSH_2 => {
            const r = scoped(c.janet_fiber_push2, .{ fiber, self.stack[fA(self.pc)], self.stack[fE(self.pc)] });
            if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
            self.reload();
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_PUSH_3 => {
            const r = scoped(c.janet_fiber_push3, .{
                fiber,
                self.stack[fA(self.pc)],
                self.stack[fB(self.pc)],
                self.stack[fC(self.pc)],
            });
            if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
            self.reload();
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_PUSH_ARRAY => {
            var vals: [*c]const c.Janet = undefined;
            var len: i32 = undefined;
            if (c.janet_indexed_view(self.stack[fD(self.pc)], &vals, &len) != 0) {
                const r = scoped(c.janet_fiber_pushn, .{ fiber, vals, len });
                if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
            } else {
                return self.raisef("expected %T, got %v", .{
                    @as(c_int, c.JANET_TFLAG_INDEXED),
                    self.stack[fD(self.pc)],
                });
            }
            self.reload();
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_CALL => {
            if (self.maybeAutoSuspend(true)) |s| return s;
            var callee = self.stack[fE(self.pc)];
            if (fiber.*.stacktop > fiber.*.maxstack) return self.throw("stack overflow");
            if (val.checkType(callee, c.JANET_KEYWORD)) {
                self.commit();
                const r = scoped(vm_calls.resolveMethod, .{ callee, fiber });
                if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
                callee = r.value;
            }
            if (val.checkType(callee, c.JANET_FUNCTION)) {
                self.func = val.unwrapFunction(callee);
                if ((self.func.*.gc.flags & c.JANET_FUNCFLAG_TRACE) != 0) {
                    c.janet_vm_trace(self.func, fiber.*.stacktop - fiber.*.stackstart, fiber);
                }
                self.commit();
                if (c.janet_fiber_funcframe(fiber, self.func) != 0) {
                    const n = fiber.*.stacktop - fiber.*.stackstart;
                    return self.raisef("%v called with %d argument%s, expected %d", .{
                        callee,
                        n,
                        if (n == 1) @as([*c]const u8, "") else @as([*c]const u8, "s"),
                        self.func.*.def.*.arity,
                    });
                }
                self.reload();
                self.pc = self.func.*.def.*.bytecode;
                self.maybeCollect();
                continue :sw self.nextOp();
            } else if (val.checkType(callee, c.JANET_CFUNCTION)) {
                self.commit();
                const argc = fiber.*.stacktop - fiber.*.stackstart;
                c.janet_fiber_cframe(fiber, val.unwrapCFunction(callee));
                const r = scoped(invokeCFunction, .{
                    val.unwrapCFunction(callee),
                    argc,
                    fiber.*.data + asSize(fiber.*.frame),
                });
                if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
                c.janet_fiber_popframe(fiber);
                self.reload();
                self.stack[fA(self.pc)] = r.value;
                self.maybeCollect();
                self.pc += 1;
                continue :sw self.nextOp();
            } else {
                self.commit();
                const r = scoped(vm_calls.callNonfn, .{ fiber, callee });
                if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
                // `stack` is deliberately not refreshed here; FOUND.md records
                // it, and reproducing it is the point.
                self.stack[fA(self.pc)] = r.value;
                self.pc += 1;
                continue :sw self.nextOp();
            }
        },

        c.JOP_TAILCALL => {
            if (self.maybeAutoSuspend(true)) |s| return s;
            var callee = self.stack[fD(self.pc)];
            if (fiber.*.stacktop > fiber.*.maxstack) return self.throw("stack overflow");
            if (val.checkType(callee, c.JANET_KEYWORD)) {
                self.commit();
                const r = scoped(vm_calls.resolveMethod, .{ callee, fiber });
                if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
                callee = r.value;
            }
            if (val.checkType(callee, c.JANET_FUNCTION)) {
                self.func = val.unwrapFunction(callee);
                if ((self.func.*.gc.flags & c.JANET_FUNCFLAG_TRACE) != 0) {
                    c.janet_vm_trace(self.func, fiber.*.stacktop - fiber.*.stackstart, fiber);
                }
                if (c.janet_fiber_funcframe_tail(fiber, self.func) != 0) {
                    stackFrame(fiber.*.data + asSize(fiber.*.frame)).pc = self.pc;
                    const n = fiber.*.stacktop - fiber.*.stackstart;
                    return self.raisef("%v called with %d argument%s, expected %d", .{
                        callee,
                        n,
                        if (n == 1) @as([*c]const u8, "") else @as([*c]const u8, "s"),
                        self.func.*.def.*.arity,
                    });
                }
                self.reload();
                self.pc = self.func.*.def.*.bytecode;
                self.maybeCollect();
                continue :sw self.nextOp();
            }
            const entrance_frame = (stackFrame(self.stack).flags & c.JANET_STACKFRAME_ENTRANCE) != 0;
            self.commit();
            var retreg: c.Janet = undefined;
            if (val.checkType(callee, c.JANET_CFUNCTION)) {
                const argc = fiber.*.stacktop - fiber.*.stackstart;
                c.janet_fiber_cframe(fiber, val.unwrapCFunction(callee));
                const r = scoped(invokeCFunction, .{
                    val.unwrapCFunction(callee),
                    argc,
                    fiber.*.data + asSize(fiber.*.frame),
                });
                if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
                retreg = r.value;
                c.janet_fiber_popframe(fiber);
            } else {
                const r = scoped(vm_calls.callNonfn, .{ fiber, callee });
                if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
                retreg = r.value;
            }
            c.janet_fiber_popframe(fiber);
            if (entrance_frame) return self.retNoRestore(c.JANET_SIGNAL_OK, retreg);
            self.restore();
            self.stack[fA(self.pc)] = retreg;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_RESUME => {
            if (self.maybeAutoSuspend(true)) |s| return s;
            if (self.assertType(self.stack[fB(self.pc)], c.JANET_FIBER)) |s| return s;
            var retreg: c.Janet = undefined;
            const child = val.unwrapFiber(self.stack[fB(self.pc)]);
            if (c.janet_check_can_resume(child, &retreg, 0) != 0) {
                self.commit();
                return self.raisev(retreg);
            }
            fiber.*.child = child;
            const sig = c.janet_continue_no_check(child, self.stack[fC(self.pc)], &retreg);
            self.reload();
            if (sig != c.JANET_SIGNAL_OK and (child.*.flags & (@as(i32, 1) << @intCast(sig))) == 0) {
                return self.ret(sig, retreg);
            }
            fiber.*.child = null;
            self.stack[fA(self.pc)] = retreg;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_SIGNAL => {
            var s: i32 = @intCast(fC(self.pc));
            if (s > c.JANET_SIGNAL_USER9) s = c.JANET_SIGNAL_USER9;
            if (s < 0) s = 0;
            return self.ret(@intCast(s), self.stack[fB(self.pc)]);
        },

        c.JOP_PROPAGATE => {
            const fv = self.stack[fC(self.pc)];
            if (self.assertType(fv, c.JANET_FIBER)) |s| return s;
            const f = val.unwrapFiber(fv);
            const sub_status = c.janet_fiber_status(f);
            if (sub_status > c.JANET_STATUS_USER9) {
                self.commit();
                return self.raisef("cannot propagate from fiber with status :%s", .{
                    c.janet_status_names[@intCast(sub_status)],
                });
            }
            fiber.*.child = f;
            return self.ret(@intCast(sub_status), self.stack[fB(self.pc)]);
        },

        c.JOP_CANCEL => {
            if (self.assertType(self.stack[fB(self.pc)], c.JANET_FIBER)) |s| return s;
            var retreg: c.Janet = undefined;
            const child = val.unwrapFiber(self.stack[fB(self.pc)]);
            if (c.janet_check_can_resume(child, &retreg, 1) != 0) {
                self.commit();
                return self.raisev(retreg);
            }
            fiber.*.child = child;
            const sig = c.janet_continue_signal(child, self.stack[fC(self.pc)], &retreg, c.JANET_SIGNAL_ERROR);
            if (sig != c.JANET_SIGNAL_OK and (child.*.flags & (@as(i32, 1) << @intCast(sig))) == 0) {
                return self.ret(sig, retreg);
            }
            fiber.*.child = null;
            self.reload();
            self.stack[fA(self.pc)] = retreg;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_PUT => {
            self.commit();
            fiber.*.flags |= c.JANET_FIBER_RESUME_NO_USEVAL;
            const r = scoped(c.janet_put, .{
                self.stack[fA(self.pc)],
                self.stack[fB(self.pc)],
                self.stack[fC(self.pc)],
            });
            if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
            self.reload();
            fiber.*.flags &= ~@as(i32, c.JANET_FIBER_RESUME_NO_USEVAL);
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_PUT_INDEX => {
            self.commit();
            fiber.*.flags |= c.JANET_FIBER_RESUME_NO_USEVAL;
            const r = scoped(c.janet_putindex, .{
                self.stack[fA(self.pc)],
                @as(i32, @intCast(fC(self.pc))),
                self.stack[fB(self.pc)],
            });
            if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
            self.reload();
            fiber.*.flags &= ~@as(i32, c.JANET_FIBER_RESUME_NO_USEVAL);
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_IN => {
            self.commit();
            const r = scoped(c.janet_in, .{ self.stack[fB(self.pc)], self.stack[fC(self.pc)] });
            if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
            self.reload();
            self.stack[fA(self.pc)] = r.value;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_GET => {
            self.commit();
            const r = scoped(c.janet_get, .{ self.stack[fB(self.pc)], self.stack[fC(self.pc)] });
            if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
            self.reload();
            self.stack[fA(self.pc)] = r.value;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_GET_INDEX => {
            self.commit();
            const r = scoped(c.janet_getindex, .{ self.stack[fB(self.pc)], @as(i32, @intCast(fC(self.pc))) });
            if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
            self.reload();
            self.stack[fA(self.pc)] = r.value;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_LENGTH => {
            self.commit();
            const r = scoped(c.janet_lengthv, .{self.stack[fE(self.pc)]});
            if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
            self.reload();
            self.stack[fA(self.pc)] = r.value;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_MAKE_ARRAY => {
            const count = fiber.*.stacktop - fiber.*.stackstart;
            const mem = fiber.*.data + asSize(fiber.*.stackstart);
            self.stack[fD(self.pc)] = val.wrapArray(c.janet_array_n(mem, count));
            fiber.*.stacktop = fiber.*.stackstart;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_MAKE_TUPLE, c.JOP_MAKE_BRACKET_TUPLE => |op| {
            const count = fiber.*.stacktop - fiber.*.stackstart;
            const mem = fiber.*.data + asSize(fiber.*.stackstart);
            const tup = c.janet_tuple_n(mem, count);
            if (op == c.JOP_MAKE_BRACKET_TUPLE) {
                tupleHead(tup).gc.flags |= c.JANET_TUPLE_FLAG_BRACKETCTOR;
            }
            self.stack[fD(self.pc)] = val.wrapTuple(tup);
            fiber.*.stacktop = fiber.*.stackstart;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_MAKE_TABLE => {
            const count = fiber.*.stacktop - fiber.*.stackstart;
            const mem = fiber.*.data + asSize(fiber.*.stackstart);
            if (count & 1 != 0) {
                self.commit();
                return self.raisef("expected even number of arguments to table constructor, got %d", .{count});
            }
            const table = c.janet_table(@divTrunc(count, 2));
            const r = scoped(vm_calls.fillTable, .{ table, mem, count });
            if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
            self.stack[fD(self.pc)] = val.wrapTable(table);
            fiber.*.stacktop = fiber.*.stackstart;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_MAKE_STRUCT => {
            const count = fiber.*.stacktop - fiber.*.stackstart;
            const mem = fiber.*.data + asSize(fiber.*.stackstart);
            if (count & 1 != 0) {
                self.commit();
                return self.raisef("expected even number of arguments to struct constructor, got %d", .{count});
            }
            const st = c.janet_struct_begin(@divTrunc(count, 2));
            const r = scoped(vm_calls.fillStruct, .{ st, mem, count });
            if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
            self.stack[fD(self.pc)] = val.wrapStruct(c.janet_struct_end(st));
            fiber.*.stacktop = fiber.*.stackstart;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_MAKE_STRING => {
            const count = fiber.*.stacktop - fiber.*.stackstart;
            const mem = fiber.*.data + asSize(fiber.*.stackstart);
            var buffer: c.JanetBuffer = undefined;
            _ = c.janet_buffer_init(&buffer, 10 *% count);
            // A raise inside the loop returns without reaching the deinit
            // below, so the buffer's janet_malloc block is leaked. That is what
            // the longjmp did too; see FOUND.md, "JOP_MAKE_STRING leaks its
            // scratch buffer when a conversion raises". Reproduced deliberately
            // rather than fixed -- and the reason this arm cannot use `defer`
            // even if the file were not jump-transparent.
            const r = scoped(vm_calls.fillString, .{ &buffer, mem, count });
            if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
            self.stack[fD(self.pc)] = c.janet_stringv(buffer.data, buffer.count);
            c.janet_buffer_deinit(&buffer);
            fiber.*.stacktop = fiber.*.stackstart;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        c.JOP_MAKE_BUFFER => {
            const count = fiber.*.stacktop - fiber.*.stackstart;
            const mem = fiber.*.data + asSize(fiber.*.stackstart);
            const buffer = c.janet_buffer(10 *% count);
            const r = scoped(vm_calls.fillString, .{ buffer, mem, count });
            if (r.sig != c.JANET_SIGNAL_OK) return self.raiseSignal(r.sig, r.payload);
            self.stack[fD(self.pc)] = val.wrapBuffer(buffer);
            fiber.*.stacktop = fiber.*.stackstart;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        // An opcode the loop does not know, which is how a breakpoint is set:
        // bit 7 of the instruction word takes it out of the table.
        else => {
            fiber.*.flags |= (c.JANET_FIBER_BREAKPOINT | c.JANET_FIBER_RESUME_NO_USEVAL | c.JANET_FIBER_RESUME_NO_SKIP);
            return self.ret(c.JANET_SIGNAL_DEBUG, val.wrapNil());
        },
    }
}

/// `pc += DS` in C, where `pc` is `uint32_t *` and `DS` is a signed instruction
/// field. Zig's pointer arithmetic takes an unsigned offset, so the two's
/// complement is taken explicitly and the wrap is the same one C performs.
inline fn asOffset(n: i32) usize {
    return @bitCast(@as(isize, n));
}

/// `fmod` from `<math.h>`. `@rem` has the same rounding for finite operands but
/// is not defined over infinities the way the C library function is, and
/// `JOP_REMAINDER` is reachable with either.
extern fn fmod(x: f64, y: f64) f64;

comptime {
    @export(&runVm, .{ .name = "janet_run_vm", .visibility = .hidden });
}
