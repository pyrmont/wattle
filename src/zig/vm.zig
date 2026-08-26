//! The interpreter loop, and the call protocol it dispatches through.
//!
//! Two files until Phase 12 increment 6f, and `root.zig` already said they
//! were one object: `vm_calls.zig` is imported by `vm_run.zig` as well as by
//! the root, because the loop inlines it -- Phase 11 Part 2 measured 2.4-3.4%
//! on method dispatch for reaching it out of line.  A merge is what that
//! measurement was describing.
//!
//! `asSize` was declared identically in both.
const std = @import("std");
const raise = @import("raise");
const io_core = @import("io.zig");
const pp_format = @import("pp/format.zig");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const stdio = @import("stdio.zig");
const options = @import("options");
const structs = @import("value/structs.zig");
const tables = @import("value/tables.zig");
const gc_alloc = @import("gc.zig");
const arrays = @import("value/arrays.zig");
const buffers = @import("value/buffers.zig");
const tuples = @import("value/tuples.zig");
const order = @import("value/helpers/order.zig");
const abstracts = @import("value/abstracts.zig");
const gc_mark = @import("gc/mark.zig");
const args_core = @import("args.zig");
const vm_calls = @import("vm.zig");
const wrap = @import("value/helpers/wrap.zig");
const fibers = @import("value/fibers.zig");
const functions = @import("value/functions.zig");
const access = @import("value/helpers/access.zig");
const vm_entry = @import("vm/entry.zig");
const pp_describe = @import("pp.zig");
const abstract_type = @import("abstract_type.zig");
const value = @import("value.zig");
const kind = @import("value/helpers/kind.zig");
const utils = @import("utils.zig");

// -------------------------------------------------------------------------
// The loop -- what `vm_run.zig` was.
// -------------------------------------------------------------------------

/// Whether this build checks for an interpreter interrupt between instructions.
/// `state_abi.h` restates `JANET_NO_INTERPRETER_INTERRUPT` as a valued macro,
/// because translate-c does not surface one defined without a value.
const has_interrupt = constants.JANET_VM_HAS_INTERRUPT == 1;

/// `janet.h`'s frame size. The function-like macros over it — `janet_stack_frame`
/// and `janet_fiber_frame` — do not survive translation and are written out below.
const frame_size: i32 = constants.JANET_FRAME_SIZE;

/// A sign-preserving widening, matching C's `int32_t` to `size_t` conversion in
/// `fiber->data + fiber->frame`. The operands are fiber stack indices the fiber
/// itself maintains, so none is negative in practice.
inline fn asSize(n: i32) usize {
    return @bitCast(@as(isize, n));
}

inline fn stackFrame(values: [*]types.Janet) *types.JanetStackFrame {
    return @ptrCast(@alignCast(values - frame_size));
}

/// `func->envs[i]` as an lvalue.
inline fn funcEnvSlot(func: *types.JanetFunction, i: i32) *?*types.JanetFuncEnv {
    return &types.envsOf(func)[@intCast(i)];
}

// ------------------------------------------------------------ value layer

/// The value operations the loop reaches on every instruction.
///
/// In C every one of these is a macro in `janet.h`, so `run_vm` pays a shift
/// and a compare for a type check rather than a call. Zig sees the *functions*
/// the same header declares, and reaching them through the symbol table costs
/// the arithmetic workload 89% -- measured, before this import existed. So the
/// value layer arrives the same way Part 2's helpers do: as a module, which was
/// resolved to `value_wrap.zig` or to `value_wrap_extern.zig` on the selector
/// until Phase 11 Part 26.
const val = wrap.ops;

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

inline fn fA(pc: [*]const u32) u32 {
    return (pc[0] >> 8) & 0xFF;
}
inline fn fB(pc: [*]const u32) u32 {
    return (pc[0] >> 16) & 0xFF;
}
inline fn fC(pc: [*]const u32) u32 {
    return pc[0] >> 24;
}
inline fn fD(pc: [*]const u32) u32 {
    return pc[0] >> 8;
}
inline fn fE(pc: [*]const u32) u32 {
    return pc[0] >> 16;
}

/// Signed interpretations of the same fields, as C's arithmetic right shift of
/// the word reinterpreted as `int32_t`.
inline fn fCS(pc: [*]const u32) i32 {
    return @as(i32, @bitCast(pc[0])) >> 24;
}
inline fn fDS(pc: [*]const u32) i32 {
    return @as(i32, @bitCast(pc[0])) >> 8;
}
inline fn fES(pc: [*]const u32) i32 {
    return @as(i32, @bitCast(pc[0])) >> 16;
}

// The per-call `setjmp` scope Phase 7 built for this loop was here, and Phase
// 10 Part 17e removed it. It had thirteen callees when Part 17 began -- the
// access layer, the callee layer, the fiber pushes, `janet_equals`,
// `janet_compare`, the three fills and the cfunction call -- and every one of
// them now returns its raise, so there was nothing left for a scope to catch.
// `-Dcall-trampoline` selected it, and the hinge spent the selector: by then
// its C arm was the only configuration in the tree that compiled a `setjmp`.

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

    inline fn method(comptime self: Op) [*:0]const u8 {
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

    inline fn rmethod(comptime self: Op) [*:0]const u8 {
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
    fiber: *types.JanetFiber,
    stack: [*]types.Janet,
    pc: [*]u32,
    func: *types.JanetFunction,

    // ---- state movement

    /// `vm_commit`. Publish the program counter before anything that could
    /// raise, so a stack trace names the instruction rather than its
    /// predecessor.
    inline fn commit(self: *Interp) void {
        stackFrame(self.stack).pc = self.pc;
    }

    /// `vm_restore`. Re-read all three registers from the frame the fiber is
    /// now in.
    /// A C frame has neither a function nor a program counter, and `runVm`
    /// restores onto one deliberately: the raise path checks
    /// `stackFrame(stack).func == null`, pops the frame and restores again.
    /// The C original copies the two nulls there and never reads them, so
    /// leaving the previous values in place is the same behaviour without a
    /// null in a type that says there is not one.
    inline fn restore(self: *Interp) void {
        self.stack = self.fiber.*.data.? + asSize(self.fiber.*.frame);
        const frame = stackFrame(self.stack);
        if (frame.func) |function| self.func = function;
        if (frame.pc) |counter| self.pc = counter;
    }

    /// `stack = fiber->data + fiber->frame`, which the opcode bodies do on
    /// their own after any call that could have moved the stack.
    inline fn reload(self: *Interp) void {
        self.stack = self.fiber.*.data.? + asSize(self.fiber.*.frame);
    }

    inline fn nextOp(self: *const Interp) u32 {
        return self.pc[0] & 0xFF;
    }

    inline fn maybeCollect(self: *const Interp) void {
        _ = self;
        if (c.vm().next_collection >= c.vm().gc_interval) gc_mark.collect();
    }

    // ---- leaving the loop

    /// `vm_return`.
    inline fn ret(self: *Interp, sig: types.JanetSignal, v: types.Janet) types.JanetSignal {
        c.vm().return_reg.?.* = v;
        self.commit();
        return sig;
    }

    /// `vm_return_no_restore`.
    inline fn retNoRestore(self: *Interp, sig: types.JanetSignal, v: types.Janet) types.JanetSignal {
        _ = self;
        c.vm().return_reg.?.* = v;
        return sig;
    }

    /// `vm_raise_signal`. Returns the error out of `janet_run_vm` rather than
    /// jumping past its frame, and sets `JANET_FIBER_DID_RAISE` exactly as
    /// `janet_signalv` does, because the resume path reads that flag to pop a C
    /// frame and to turn a raise at a tail call into an implicit return.
    ///
    /// It does not commit. Each site keeps whatever commit it already had,
    /// because that is not uniform in the C: `JOP_PUSH_ARRAY` never committed,
    /// `JOP_CALL` committed before entering `janet_fiber_funcframe` and its
    /// `stack` is stale afterwards, and `JOP_TAILCALL` commits to a frame it
    /// recomputes.
    inline fn raiseSignal(self: *Interp, sig: types.JanetSignal, v: types.Janet) raise.Error!types.JanetSignal {
        _ = self;
        // Returned rather than jumped since Phase 10 Part 2. `raise.signal`
        // reaches the same `janet_zig_signal_record` `janet_signalv` does, so
        // the plan, the coercion and `JANET_FIBER_DID_RAISE` are unchanged;
        // only the delivery differs. Since the hinge there is no other
        // delivery: `continueNoCheck` catches the error one frame up.
        return raise.signal(sig, v);
    }

    /// `vm_raisev`.
    inline fn raisev(self: *Interp, v: types.Janet) raise.Error!types.JanetSignal {
        return try self.raiseSignal(constants.JANET_SIGNAL_ERROR, v);
    }

    /// `vm_raisef`. The message is built by `pp_format.panicf`, which parses
    /// the format string at compile time and indexes the tuple; the specifier
    /// and the value it renders are checked against each other here.
    inline fn raisef(self: *Interp, comptime format: [:0]const u8, args: anytype) raise.Error!types.JanetSignal {
        _ = self;
        return pp_format.panicf(format, args);
    }

    /// `vm_throw`: commit, then raise a plain string.
    inline fn throw(self: *Interp, message: [*:0]const u8) raise.Error!types.JanetSignal {
        self.commit();
        return try self.raisev(value.fromBytes(std.mem.span(message), .string));
    }

    /// `vm_assert`.
    inline fn assert(self: *Interp, condition: bool, message: [*:0]const u8) raise.Error!?types.JanetSignal {
        if (condition) return null;
        return try self.throw(message);
    }

    /// `vm_assert_type`.
    inline fn assertType(self: *Interp, x: types.Janet, comptime t: types.JanetType) raise.Error!?types.JanetSignal {
        if (val.checkType(x, t)) return null;
        self.commit();
        return try self.raisef("expected %T, got %v", .{ @as(c_int, 1) << t, x });
    }

    /// `vm_assert_types`.
    inline fn assertTypes(self: *Interp, x: types.Janet, typeflags: c_int) raise.Error!?types.JanetSignal {
        if (val.checkTypes(x, typeflags)) return null;
        self.commit();
        return try self.raisef("expected %T, got %v", .{ typeflags, x });
    }

    /// `vm_maybe_auto_suspend`. The condition is only ever a comparison on an
    /// instruction field, so evaluating it in a build without the interrupt —
    /// where C does not evaluate it at all — costs nothing and changes nothing.
    inline fn maybeAutoSuspend(self: *Interp, condition: bool) raise.Error!?types.JanetSignal {
        if (!has_interrupt) return null;
        if (condition and abstracts.atomicLoadRelaxed(&c.vm().auto_suspend) != 0) {
            self.fiber.*.flags |= (constants.JANET_FIBER_RESUME_NO_USEVAL | constants.JANET_FIBER_RESUME_NO_SKIP);
            return self.ret(constants.JANET_SIGNAL_INTERRUPT, val.fromNil());
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
    inline fn doReturn(self: *Interp, retval: types.Janet) raise.Error!?types.JanetSignal {
        const entrance_frame = (stackFrame(self.stack).flags & constants.JANET_STACKFRAME_ENTRANCE) != 0;
        fibers.popframe(self.fiber);
        if (entrance_frame) return self.retNoRestore(constants.JANET_SIGNAL_OK, retval);
        self.restore();
        self.stack[fA(self.pc)] = retval;
        self.maybeCollect();
        self.pc += 1;
        return null;
    }

    /// `JOP_LOAD_UPVALUE` and `JOP_SET_UPVALUE`. The three assertions and the
    /// on-stack/off-stack choice are shared; `store` is comptime, so neither
    /// opcode pays a branch to find out which one it is.
    inline fn upvalue(self: *Interp, comptime store: bool) raise.Error!?types.JanetSignal {
        const eindex: i32 = @intCast(fB(self.pc));
        const vindex: i32 = @intCast(fC(self.pc));
        if (try self.assert(self.func.*.def.?.environments_length > eindex, "invalid upvalue environment")) |s| return s;
        const env = funcEnvSlot(self.func, eindex).*;
        if (try self.assert(env.?.length > vindex, "invalid upvalue index")) |s| return s;
        if (try self.assert(functions.envValid(env.?) != 0, "invalid upvalue environment")) |s| return s;
        const slot: [*]types.Janet = if (env.?.offset > 0)
            env.?.as.fiber.?.data.? + asSize(env.?.offset + vindex)
        else
            env.?.as.values.? + asSize(vindex);
        if (store) {
            slot[0] = self.stack[fA(self.pc)];
        } else {
            self.stack[fA(self.pc)] = slot[0];
        }
        self.pc += 1;
        return null;
    }

    /// `JOP_EQUALS` and `JOP_NOT_EQUALS`.
    inline fn equals(self: *Interp, comptime negate: bool) raise.Error!?types.JanetSignal {
        self.commit();
        const eq = order.equals(self.stack[fB(self.pc)], self.stack[fC(self.pc)]) != 0;
        self.stack[fA(self.pc)] = val.fromBoolean(if (negate) !eq else eq);
        self.pc += 1;
        return null;
    }

    /// `vm_binop_immediate`.
    inline fn binopImmediate(self: *Interp, comptime op: Op) raise.Error!?types.JanetSignal {
        const op1 = self.stack[fB(self.pc)];
        if (!val.isNumber(op1)) {
            self.commit();
            var argv = [_]types.Janet{ op1, val.fromNumber(@floatFromInt(fCS(self.pc))) };
            const v = try vm_calls.mcall(op.method(), &argv);
            self.reload();
            self.stack[fA(self.pc)] = v;
            self.maybeCollect();
        } else {
            const x1 = val.toNumber(op1);
            self.stack[fA(self.pc)] = val.fromNumber(op.applyNumber(x1, @floatFromInt(fCS(self.pc))));
        }
        self.pc += 1;
        return null;
    }

    /// `_vm_bitop_immediate`.
    inline fn bitopImmediate(self: *Interp, comptime op: Op) raise.Error!?types.JanetSignal {
        const op1 = self.stack[fB(self.pc)];
        if (!val.isNumber(op1)) {
            self.commit();
            var argv = [_]types.Janet{ op1, val.fromNumber(@floatFromInt(fCS(self.pc))) };
            const v = try vm_calls.mcall(op.method(), &argv);
            self.reload();
            self.stack[fA(self.pc)] = v;
            self.maybeCollect();
        } else {
            const T = op.intType();
            const y1 = val.toNumber(op1);
            if (!checkRange(T, y1)) {
                self.commit();
                return try self.raisef("value %v out of range for " ++ op.intMessage(), .{op1});
            }
            const x1: T = @intFromFloat(y1);
            self.stack[fA(self.pc)] = val.fromNumber(intToDouble(T, op.applyBits(x1, fCS(self.pc))));
        }
        self.pc += 1;
        return null;
    }

    /// `_vm_binop`.
    inline fn binop(self: *Interp, comptime op: Op) raise.Error!?types.JanetSignal {
        const op1 = self.stack[fB(self.pc)];
        const op2 = self.stack[fC(self.pc)];
        if (val.isNumber(op1) and val.isNumber(op2)) {
            const x1 = val.toNumber(op1);
            const x2 = val.toNumber(op2);
            self.stack[fA(self.pc)] = val.fromNumber(op.applyNumber(x1, x2));
            self.pc += 1;
            return null;
        }
        return self.binopFallback(op.method(), op.rmethod(), op1, op2);
    }

    /// `_vm_bitop`.
    inline fn bitop(self: *Interp, comptime op: Op) raise.Error!?types.JanetSignal {
        const op1 = self.stack[fB(self.pc)];
        const op2 = self.stack[fC(self.pc)];
        if (val.isNumber(op1) and val.isNumber(op2)) {
            const T = op.intType();
            const y1 = val.toNumber(op1);
            const y2 = val.toNumber(op2);
            if (!checkRange(T, y1)) {
                self.commit();
                return try self.raisef("value %v out of range for " ++ op.intMessage(), .{op1});
            }
            if (!checkRange(i32, y2)) {
                self.commit();
                // `y2`, not `op2`. The C passes the `Janet` to a `%f` that
                // reads a `double` -- undefined, and observed to print
                // `0.000000` on x86-64 where the System V classification sends
                // the union through a general-purpose register while
                // `va_arg(double)` reads the SSE save area. `FOUND.md` has the
                // measurement and names `y2` as the value the message wants.
                // Part 8's rule applies: there is no defined behaviour to
                // reproduce, so the port gets it right. The tuple driver made
                // it a compile error rather than a choice.
                return try self.raisef("rhs must be valid 32-bit signed integer, got %f", .{y2});
            }
            const x1: T = @intFromFloat(y1);
            const x2: i32 = @intFromFloat(y2);
            self.stack[fA(self.pc)] = val.fromNumber(intToDouble(T, op.applyBits(x1, x2)));
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
        lmethod: [*:0]const u8,
        rmethod: [*:0]const u8,
        op1: types.Janet,
        op2: types.Janet,
    ) raise.Error!?types.JanetSignal {
        self.commit();
        const v = try vm_calls.binopCall(lmethod, rmethod, op1, op2);
        self.reload();
        self.stack[fA(self.pc)] = v;
        self.maybeCollect();
        self.pc += 1;
        return null;
    }

    /// `vm_compop`.
    inline fn compop(self: *Interp, comptime op: Cmp) raise.Error!?types.JanetSignal {
        const op1 = self.stack[fB(self.pc)];
        const op2 = self.stack[fC(self.pc)];
        if (val.isNumber(op1) and val.isNumber(op2)) {
            const x1 = val.toNumber(op1);
            const x2 = val.toNumber(op2);
            self.stack[fA(self.pc)] = val.fromBoolean(op.applyNumber(x1, x2));
            self.pc += 1;
            return null;
        }
        return self.compareFallback(op, op1, op2);
    }

    /// `vm_compop_imm`.
    inline fn compopImmediate(self: *Interp, comptime op: Cmp) raise.Error!?types.JanetSignal {
        const op1 = self.stack[fB(self.pc)];
        if (val.isNumber(op1)) {
            const x1 = val.toNumber(op1);
            const x2: f64 = @floatFromInt(fCS(self.pc));
            self.stack[fA(self.pc)] = val.fromBoolean(op.applyNumber(x1, x2));
            self.pc += 1;
            return null;
        }
        return self.compareFallback(op, op1, val.fromInteger(fCS(self.pc)));
    }

    inline fn compareFallback(self: *Interp, comptime op: Cmp, op1: types.Janet, op2: types.Janet) raise.Error!?types.JanetSignal {
        self.commit();
        const a = val.fromBoolean(op.applyOrder(order.compare(op1, op2)));
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
pub fn runVm(fiber_in: *types.JanetFiber, in: types.Janet) raise.Error!types.JanetSignal {
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
    if ((fiber.*.flags & constants.JANET_FIBER_RESUME_SIGNAL) != 0) {
        const sig: types.JanetSignal = @intCast(@as(u32, @bitCast(fiber.*.gc.flags & constants.JANET_FIBER_STATUS_MASK)) >> constants.JANET_FIBER_STATUS_OFFSET);
        fiber.*.gc.flags &= ~@as(i32, constants.JANET_FIBER_STATUS_MASK);
        fiber.*.flags &= ~@as(i32, constants.JANET_FIBER_RESUME_SIGNAL | constants.JANET_FIBER_FLAG_MASK);
        c.vm().return_reg.?.* = in;
        return sig;
    }

    self.restore();

    if ((fiber.*.flags & constants.JANET_FIBER_DID_RAISE) != 0) {
        if (stackFrame(self.stack).func == null) {
            // Inside a c function
            fibers.popframe(fiber);
            self.restore();
        }
        // Check if we were at a tail call instruction. If so, do implicit return.
        if ((self.pc[0] & 0xFF) == constants.JOP_TAILCALL) {
            const entrance_frame = (stackFrame(self.stack).flags & constants.JANET_STACKFRAME_ENTRANCE) != 0;
            fibers.popframe(fiber);
            if (entrance_frame) {
                fiber.*.flags &= ~@as(i32, constants.JANET_FIBER_FLAG_MASK);
                return self.ret(constants.JANET_SIGNAL_OK, in);
            }
            self.restore();
        }
    }

    if ((fiber.*.flags & constants.JANET_FIBER_RESUME_NO_USEVAL) == 0) self.stack[fA(self.pc)] = in;
    if ((fiber.*.flags & constants.JANET_FIBER_RESUME_NO_SKIP) == 0) self.pc += 1;

    const breakpoint_mask: u32 = if ((fiber.*.flags & constants.JANET_FIBER_BREAKPOINT) != 0) 0x7F else 0xFF;
    const first_opcode: u32 = self.pc[0] & breakpoint_mask;

    fiber.*.flags &= ~@as(i32, constants.JANET_FIBER_FLAG_MASK);

    sw: switch (first_opcode) {
        constants.JOP_NOOP => {
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_ERROR => return self.ret(constants.JANET_SIGNAL_ERROR, self.stack[fA(self.pc)]),

        constants.JOP_TYPECHECK => {
            if (try self.assertTypes(self.stack[fA(self.pc)], @intCast(fE(self.pc)))) |s| return s;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_RETURN => {
            if (try self.doReturn(self.stack[fD(self.pc)])) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_RETURN_NIL => {
            if (try self.doReturn(val.fromNil())) |s| return s;
            continue :sw self.nextOp();
        },

        constants.JOP_ADD_IMMEDIATE => {
            if (try self.binopImmediate(.add)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_ADD => {
            if (try self.binop(.add)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_SUBTRACT_IMMEDIATE => {
            if (try self.binopImmediate(.sub)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_SUBTRACT => {
            if (try self.binop(.sub)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_MULTIPLY_IMMEDIATE => {
            if (try self.binopImmediate(.mul)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_MULTIPLY => {
            if (try self.binop(.mul)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_DIVIDE_IMMEDIATE => {
            if (try self.binopImmediate(.div)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_DIVIDE => {
            if (try self.binop(.div)) |s| return s;
            continue :sw self.nextOp();
        },

        constants.JOP_DIVIDE_FLOOR => {
            const op1 = self.stack[fB(self.pc)];
            const op2 = self.stack[fC(self.pc)];
            if (val.isNumber(op1) and val.isNumber(op2)) {
                const x1 = val.toNumber(op1);
                const x2 = val.toNumber(op2);
                self.stack[fA(self.pc)] = val.fromNumber(@floor(x1 / x2));
                self.pc += 1;
                continue :sw self.nextOp();
            }
            if (try self.binopFallback("div", "rdiv", op1, op2)) |s| return s;
            continue :sw self.nextOp();
        },

        constants.JOP_MODULO => {
            const op1 = self.stack[fB(self.pc)];
            const op2 = self.stack[fC(self.pc)];
            if (val.isNumber(op1) and val.isNumber(op2)) {
                const x1 = val.toNumber(op1);
                const x2 = val.toNumber(op2);
                if (x2 == 0) {
                    self.stack[fA(self.pc)] = val.fromNumber(x1);
                } else {
                    const intres = x2 * @floor(x1 / x2);
                    self.stack[fA(self.pc)] = val.fromNumber(x1 - intres);
                }
                self.pc += 1;
                continue :sw self.nextOp();
            }
            if (try self.binopFallback("mod", "rmod", op1, op2)) |s| return s;
            continue :sw self.nextOp();
        },

        constants.JOP_REMAINDER => {
            const op1 = self.stack[fB(self.pc)];
            const op2 = self.stack[fC(self.pc)];
            if (val.isNumber(op1) and val.isNumber(op2)) {
                const x1 = val.toNumber(op1);
                const x2 = val.toNumber(op2);
                self.stack[fA(self.pc)] = val.fromNumber(fmod(x1, x2));
                self.pc += 1;
                continue :sw self.nextOp();
            }
            if (try self.binopFallback("%", "r%", op1, op2)) |s| return s;
            continue :sw self.nextOp();
        },

        constants.JOP_BAND => {
            if (try self.bitop(.band)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_BOR => {
            if (try self.bitop(.bor)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_BXOR => {
            if (try self.bitop(.bxor)) |s| return s;
            continue :sw self.nextOp();
        },

        constants.JOP_BNOT => {
            const op = self.stack[fE(self.pc)];
            if (val.isNumber(op)) {
                self.stack[fA(self.pc)] = val.fromInteger(~val.toInteger(op));
                self.pc += 1;
                continue :sw self.nextOp();
            }
            self.commit();
            const v = try vm_calls.unaryCall("~", op);
            self.reload();
            self.stack[fA(self.pc)] = v;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_SHIFT_RIGHT_UNSIGNED => {
            if (try self.bitop(.shru)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_SHIFT_RIGHT_UNSIGNED_IMMEDIATE => {
            if (try self.bitopImmediate(.shru)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_SHIFT_RIGHT => {
            if (try self.bitop(.shr)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_SHIFT_RIGHT_IMMEDIATE => {
            if (try self.bitopImmediate(.shr)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_SHIFT_LEFT => {
            if (try self.bitop(.shl)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_SHIFT_LEFT_IMMEDIATE => {
            if (try self.bitopImmediate(.shl)) |s| return s;
            continue :sw self.nextOp();
        },

        constants.JOP_MOVE_NEAR => {
            self.stack[fA(self.pc)] = self.stack[fE(self.pc)];
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_MOVE_FAR => {
            self.stack[fE(self.pc)] = self.stack[fA(self.pc)];
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_JUMP => {
            if (try self.maybeAutoSuspend(fDS(self.pc) <= 0)) |s| return s;
            self.pc += asOffset(fDS(self.pc));
            continue :sw self.nextOp();
        },

        constants.JOP_JUMP_IF => {
            if (val.truthy(self.stack[fA(self.pc)])) {
                if (try self.maybeAutoSuspend(fES(self.pc) <= 0)) |s| return s;
                self.pc += asOffset(fES(self.pc));
            } else {
                self.pc += 1;
            }
            continue :sw self.nextOp();
        },

        constants.JOP_JUMP_IF_NOT => {
            if (val.truthy(self.stack[fA(self.pc)])) {
                self.pc += 1;
            } else {
                if (try self.maybeAutoSuspend(fES(self.pc) <= 0)) |s| return s;
                self.pc += asOffset(fES(self.pc));
            }
            continue :sw self.nextOp();
        },

        constants.JOP_JUMP_IF_NIL => {
            if (val.checkType(self.stack[fA(self.pc)], constants.JANET_NIL)) {
                if (try self.maybeAutoSuspend(fES(self.pc) <= 0)) |s| return s;
                self.pc += asOffset(fES(self.pc));
            } else {
                self.pc += 1;
            }
            continue :sw self.nextOp();
        },

        constants.JOP_JUMP_IF_NOT_NIL => {
            if (val.checkType(self.stack[fA(self.pc)], constants.JANET_NIL)) {
                self.pc += 1;
            } else {
                if (try self.maybeAutoSuspend(fES(self.pc) <= 0)) |s| return s;
                self.pc += asOffset(fES(self.pc));
            }
            continue :sw self.nextOp();
        },

        constants.JOP_LESS_THAN => {
            if (try self.compop(.lt)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_LESS_THAN_EQUAL => {
            if (try self.compop(.le)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_LESS_THAN_IMMEDIATE => {
            if (try self.compopImmediate(.lt)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_GREATER_THAN => {
            if (try self.compop(.gt)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_GREATER_THAN_EQUAL => {
            if (try self.compop(.ge)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_GREATER_THAN_IMMEDIATE => {
            if (try self.compopImmediate(.gt)) |s| return s;
            continue :sw self.nextOp();
        },

        constants.JOP_EQUALS => {
            if (try self.equals(false)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_NOT_EQUALS => {
            if (try self.equals(true)) |s| return s;
            continue :sw self.nextOp();
        },

        constants.JOP_EQUALS_IMMEDIATE => {
            const x = self.stack[fB(self.pc)];
            const eq = val.isNumber(x) and val.toNumber(x) == @as(f64, @floatFromInt(fCS(self.pc)));
            self.stack[fA(self.pc)] = val.fromBoolean(eq);
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_NOT_EQUALS_IMMEDIATE => {
            const x = self.stack[fB(self.pc)];
            const ne = !val.isNumber(x) or val.toNumber(x) != @as(f64, @floatFromInt(fCS(self.pc)));
            self.stack[fA(self.pc)] = val.fromBoolean(ne);
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_COMPARE => {
            self.commit();
            const a = val.fromInteger(order.compare(self.stack[fB(self.pc)], self.stack[fC(self.pc)]));
            self.reload();
            self.stack[fA(self.pc)] = a;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_NEXT => {
            self.commit();
            const v = try access.nextImpl(self.stack[fB(self.pc)], self.stack[fC(self.pc)], 1);
            self.restore();
            self.stack[fA(self.pc)] = v;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_LOAD_NIL => {
            self.stack[fD(self.pc)] = val.fromNil();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_LOAD_TRUE => {
            self.stack[fD(self.pc)] = val.fromTrue();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_LOAD_FALSE => {
            self.stack[fD(self.pc)] = val.fromFalse();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_LOAD_INTEGER => {
            self.stack[fA(self.pc)] = val.fromInteger(fES(self.pc));
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_LOAD_CONSTANT => {
            const cindex: i32 = @intCast(fE(self.pc));
            if (try self.assert(cindex < self.func.*.def.?.constants_length, "invalid constant")) |s| return s;
            self.stack[fA(self.pc)] = self.func.*.def.?.constants.?[asSize(cindex)];
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_LOAD_SELF => {
            self.stack[fD(self.pc)] = val.fromFunction(self.func);
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_LOAD_UPVALUE => {
            if (try self.upvalue(false)) |s| return s;
            continue :sw self.nextOp();
        },
        constants.JOP_SET_UPVALUE => {
            if (try self.upvalue(true)) |s| return s;
            continue :sw self.nextOp();
        },

        constants.JOP_CLOSURE => {
            const defindex: i32 = @intCast(fE(self.pc));
            if (try self.assert(defindex < self.func.*.def.?.defs_length, "invalid funcdef")) |s| return s;
            const fd = self.func.*.def.?.defs.?[asSize(defindex)];
            const elen = fd.*.environments_length;
            const fn_ptr: *types.JanetFunction = @ptrCast(@alignCast(gc_alloc.gcalloc(
                constants.JANET_MEMORY_FUNCTION,
                types.function_envs + @as(usize, @intCast(elen)) * @sizeOf(*types.JanetFuncEnv),
            )));
            fn_ptr.*.def = fd;
            var i: i32 = 0;
            while (i < elen) : (i += 1) {
                const inherit = fd.*.environments.?[asSize(i)];
                if (inherit == -1 or inherit >= self.func.*.def.?.environments_length) {
                    const frame = stackFrame(self.stack);
                    if (frame.env == null) {
                        // Lazy capture of current stack frame
                        const env: *types.JanetFuncEnv = @ptrCast(@alignCast(gc_alloc.gcalloc(
                            constants.JANET_MEMORY_FUNCENV,
                            @sizeOf(types.JanetFuncEnv),
                        )));
                        env.*.offset = fiber.*.frame;
                        env.*.as.fiber = fiber;
                        env.*.length = self.func.*.def.?.slotcount;
                        frame.env = env;
                    }
                    funcEnvSlot(fn_ptr, i).* = frame.env;
                } else {
                    funcEnvSlot(fn_ptr, i).* = funcEnvSlot(self.func, inherit).*;
                }
            }
            self.stack[fA(self.pc)] = val.fromFunction(fn_ptr);
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_PUSH => {
            try fibers.push(fiber, self.stack[fD(self.pc)]);
            self.reload();
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_PUSH_2 => {
            try fibers.push2(fiber, self.stack[fA(self.pc)], self.stack[fE(self.pc)]);
            self.reload();
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_PUSH_3 => {
            try fibers.push3(
                fiber,
                self.stack[fA(self.pc)],
                self.stack[fB(self.pc)],
                self.stack[fC(self.pc)],
            );
            self.reload();
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_PUSH_ARRAY => {
            var vals: ?[*]const types.Janet = undefined;
            var len: i32 = undefined;
            if (args_core.indexedView(self.stack[fD(self.pc)], &vals, &len) != 0) {
                try fibers.pushn(fiber, vals.?, len);
            } else {
                return try self.raisef("expected %T, got %v", .{
                    @as(c_int, constants.JANET_TFLAG_INDEXED),
                    self.stack[fD(self.pc)],
                });
            }
            self.reload();
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_CALL => {
            if (try self.maybeAutoSuspend(true)) |s| return s;
            var callee = self.stack[fE(self.pc)];
            if (fiber.*.stacktop > fiber.*.maxstack) return try self.throw("stack overflow");
            if (val.checkType(callee, constants.JANET_KEYWORD)) {
                self.commit();
                callee = try vm_calls.resolveMethod(callee, fiber);
            }
            if (val.checkType(callee, constants.JANET_FUNCTION)) {
                self.func = val.toFunction(callee);
                if ((self.func.*.gc.flags & constants.JANET_FUNCFLAG_TRACE) != 0) {
                    traceFiber(self.func, fiber.*.stacktop - fiber.*.stackstart, fiber);
                }
                self.commit();
                if (fibers.funcframe(fiber, self.func) != 0) {
                    const n = fiber.*.stacktop - fiber.*.stackstart;
                    return try self.raisef("%v called with %d argument%s, expected %d", .{
                        callee,
                        n,
                        if (n == 1) @as([*]const u8, "") else @as([*]const u8, "s"),
                        self.func.*.def.?.arity,
                    });
                }
                self.reload();
                self.pc = self.func.*.def.?.bytecode.?;
                self.maybeCollect();
                continue :sw self.nextOp();
            } else if (val.checkType(callee, constants.JANET_CFUNCTION)) {
                self.commit();
                const argc = fiber.*.stacktop - fiber.*.stackstart;
                fibers.cframe(fiber, val.toCFunction(callee));
                const v = try raise.cfunction(val.toCFunction(callee))(
                    (fiber.*.data.? + asSize(fiber.*.frame))[0..@intCast(argc)],
                );
                fibers.popframe(fiber);
                self.reload();
                self.stack[fA(self.pc)] = v;
                self.maybeCollect();
                self.pc += 1;
                continue :sw self.nextOp();
            } else {
                self.commit();
                const v = try vm_calls.callNonfn(fiber, callee);
                // `stack` is deliberately not refreshed here; FOUND.md records
                // it, and reproducing it is the point.
                self.stack[fA(self.pc)] = v;
                self.pc += 1;
                continue :sw self.nextOp();
            }
        },

        constants.JOP_TAILCALL => {
            if (try self.maybeAutoSuspend(true)) |s| return s;
            var callee = self.stack[fD(self.pc)];
            if (fiber.*.stacktop > fiber.*.maxstack) return try self.throw("stack overflow");
            if (val.checkType(callee, constants.JANET_KEYWORD)) {
                self.commit();
                callee = try vm_calls.resolveMethod(callee, fiber);
            }
            if (val.checkType(callee, constants.JANET_FUNCTION)) {
                self.func = val.toFunction(callee);
                if ((self.func.*.gc.flags & constants.JANET_FUNCFLAG_TRACE) != 0) {
                    traceFiber(self.func, fiber.*.stacktop - fiber.*.stackstart, fiber);
                }
                if (fibers.funcframeTail(fiber, self.func) != 0) {
                    stackFrame(fiber.*.data.? + asSize(fiber.*.frame)).pc = self.pc;
                    const n = fiber.*.stacktop - fiber.*.stackstart;
                    return try self.raisef("%v called with %d argument%s, expected %d", .{
                        callee,
                        n,
                        if (n == 1) @as([*]const u8, "") else @as([*]const u8, "s"),
                        self.func.*.def.?.arity,
                    });
                }
                self.reload();
                self.pc = self.func.*.def.?.bytecode.?;
                self.maybeCollect();
                continue :sw self.nextOp();
            }
            const entrance_frame = (stackFrame(self.stack).flags & constants.JANET_STACKFRAME_ENTRANCE) != 0;
            self.commit();
            var retreg: types.Janet = undefined;
            if (val.checkType(callee, constants.JANET_CFUNCTION)) {
                const argc = fiber.*.stacktop - fiber.*.stackstart;
                fibers.cframe(fiber, val.toCFunction(callee));
                retreg = try raise.cfunction(val.toCFunction(callee))(
                    (fiber.*.data.? + asSize(fiber.*.frame))[0..@intCast(argc)],
                );
                fibers.popframe(fiber);
            } else {
                retreg = try vm_calls.callNonfn(fiber, callee);
            }
            fibers.popframe(fiber);
            if (entrance_frame) return self.retNoRestore(constants.JANET_SIGNAL_OK, retreg);
            self.restore();
            self.stack[fA(self.pc)] = retreg;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_RESUME => {
            if (try self.maybeAutoSuspend(true)) |s| return s;
            if (try self.assertType(self.stack[fB(self.pc)], constants.JANET_FIBER)) |s| return s;
            var retreg: types.Janet = undefined;
            const child = val.toFiber(self.stack[fB(self.pc)]);
            if (vm_entry.checkCanResume(child, &retreg, 0) != 0) {
                self.commit();
                return try self.raisev(retreg);
            }
            fiber.*.child = child;
            const sig = vm_entry.continueNoCheck(child, self.stack[fC(self.pc)], &retreg);
            self.reload();
            if (sig != constants.JANET_SIGNAL_OK and (child.*.flags & (@as(i32, 1) << @intCast(sig))) == 0) {
                return self.ret(sig, retreg);
            }
            fiber.*.child = null;
            self.stack[fA(self.pc)] = retreg;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_SIGNAL => {
            var s: i32 = @intCast(fC(self.pc));
            if (s > constants.JANET_SIGNAL_USER9) s = constants.JANET_SIGNAL_USER9;
            if (s < 0) s = 0;
            return self.ret(@intCast(s), self.stack[fB(self.pc)]);
        },

        constants.JOP_PROPAGATE => {
            const fv = self.stack[fC(self.pc)];
            if (try self.assertType(fv, constants.JANET_FIBER)) |s| return s;
            const f = val.toFiber(fv);
            const sub_status = fibers.status(f);
            if (sub_status > constants.JANET_STATUS_USER9) {
                self.commit();
                return try self.raisef("cannot propagate from fiber with status :%s", .{
                    utils.statusNames[@intCast(sub_status)],
                });
            }
            fiber.*.child = f;
            return self.ret(@intCast(sub_status), self.stack[fB(self.pc)]);
        },

        constants.JOP_CANCEL => {
            if (try self.assertType(self.stack[fB(self.pc)], constants.JANET_FIBER)) |s| return s;
            var retreg: types.Janet = undefined;
            const child = val.toFiber(self.stack[fB(self.pc)]);
            if (vm_entry.checkCanResume(child, &retreg, 1) != 0) {
                self.commit();
                return try self.raisev(retreg);
            }
            fiber.*.child = child;
            const sig = vm_entry.continueSignal(child, self.stack[fC(self.pc)], &retreg, constants.JANET_SIGNAL_ERROR);
            if (sig != constants.JANET_SIGNAL_OK and (child.*.flags & (@as(i32, 1) << @intCast(sig))) == 0) {
                return self.ret(sig, retreg);
            }
            fiber.*.child = null;
            self.reload();
            self.stack[fA(self.pc)] = retreg;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_PUT => {
            self.commit();
            fiber.*.flags |= constants.JANET_FIBER_RESUME_NO_USEVAL;
            try access.put(
                self.stack[fA(self.pc)],
                self.stack[fB(self.pc)],
                self.stack[fC(self.pc)],
            );
            self.reload();
            fiber.*.flags &= ~@as(i32, constants.JANET_FIBER_RESUME_NO_USEVAL);
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_PUT_INDEX => {
            self.commit();
            fiber.*.flags |= constants.JANET_FIBER_RESUME_NO_USEVAL;
            try access.putIndex(
                self.stack[fA(self.pc)],
                @as(i32, @intCast(fC(self.pc))),
                self.stack[fB(self.pc)],
            );
            self.reload();
            fiber.*.flags &= ~@as(i32, constants.JANET_FIBER_RESUME_NO_USEVAL);
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_IN => {
            self.commit();
            const v = try access.in(self.stack[fB(self.pc)], self.stack[fC(self.pc)]);
            self.reload();
            self.stack[fA(self.pc)] = v;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_GET => {
            self.commit();
            // `janet_get` answers nil rather than raising, so it needs no
            // scope and no `try`; Phase 10's fourth rule.
            const v = try access.get(self.stack[fB(self.pc)], self.stack[fC(self.pc)]);
            self.reload();
            self.stack[fA(self.pc)] = v;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_GET_INDEX => {
            self.commit();
            const v = try access.getIndex(self.stack[fB(self.pc)], @as(i32, @intCast(fC(self.pc))));
            self.reload();
            self.stack[fA(self.pc)] = v;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_LENGTH => {
            self.commit();
            const v = try access.lengthv(self.stack[fE(self.pc)]);
            self.reload();
            self.stack[fA(self.pc)] = v;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_MAKE_ARRAY => {
            const count = fiber.*.stacktop - fiber.*.stackstart;
            const mem = fiber.*.data.? + asSize(fiber.*.stackstart);
            self.stack[fD(self.pc)] = val.fromArray(arrays.newFrom(mem, count));
            fiber.*.stacktop = fiber.*.stackstart;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_MAKE_TUPLE, constants.JOP_MAKE_BRACKET_TUPLE => |op| {
            const count = fiber.*.stacktop - fiber.*.stackstart;
            const mem = fiber.*.data.? + asSize(fiber.*.stackstart);
            const tup = tuples.newFrom(mem, count);
            if (op == constants.JOP_MAKE_BRACKET_TUPLE) {
                types.tupleHead(tup).gc.flags |= constants.JANET_TUPLE_FLAG_BRACKETCTOR;
            }
            self.stack[fD(self.pc)] = val.fromTuple(tup);
            fiber.*.stacktop = fiber.*.stackstart;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_MAKE_TABLE => {
            const count = fiber.*.stacktop - fiber.*.stackstart;
            const mem = fiber.*.data.? + asSize(fiber.*.stackstart);
            if (count & 1 != 0) {
                self.commit();
                return try self.raisef("expected even number of arguments to table constructor, got %d", .{count});
            }
            const table = tables.new(@divTrunc(count, 2));
            vm_calls.fillTable(table, mem, count);
            self.stack[fD(self.pc)] = val.fromTable(table);
            fiber.*.stacktop = fiber.*.stackstart;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_MAKE_STRUCT => {
            const count = fiber.*.stacktop - fiber.*.stackstart;
            const mem = fiber.*.data.? + asSize(fiber.*.stackstart);
            if (count & 1 != 0) {
                self.commit();
                return try self.raisef("expected even number of arguments to struct constructor, got %d", .{count});
            }
            const st = structs.begin(@divTrunc(count, 2));
            vm_calls.fillStruct(st, mem, count);
            self.stack[fD(self.pc)] = val.fromStruct(structs.end(st));
            fiber.*.stacktop = fiber.*.stackstart;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_MAKE_STRING => {
            const count = fiber.*.stacktop - fiber.*.stackstart;
            const mem = fiber.*.data.? + asSize(fiber.*.stackstart);
            var buffer: types.JanetBuffer = undefined;
            _ = buffers.init(&buffer, 10 *% count);
            // A raise inside the loop returns without reaching the deinit
            // below, so the buffer's janet_malloc block is leaked. That is what
            // the longjmp did too; see FOUND.md, "JOP_MAKE_STRING leaks its
            // scratch buffer when a conversion raises". Reproduced deliberately
            // rather than fixed -- and the reason this arm cannot use `defer`
            // even if the file were not jump-transparent.
            try vm_calls.fillString(&buffer, mem, count);
            self.stack[fD(self.pc)] = value.fromBytes(buffer.data.?[0..@intCast(buffer.count)], .string);
            buffers.deinit(&buffer);
            fiber.*.stacktop = fiber.*.stackstart;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        constants.JOP_MAKE_BUFFER => {
            const count = fiber.*.stacktop - fiber.*.stackstart;
            const mem = fiber.*.data.? + asSize(fiber.*.stackstart);
            const buffer = buffers.new(10 *% count);
            try vm_calls.fillString(buffer, mem, count);
            self.stack[fD(self.pc)] = val.fromBuffer(buffer);
            fiber.*.stacktop = fiber.*.stackstart;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        // An opcode the loop does not know, which is how a breakpoint is set:
        // bit 7 of the instruction word takes it out of the table.
        else => {
            fiber.*.flags |= (constants.JANET_FIBER_BREAKPOINT | constants.JANET_FIBER_RESUME_NO_USEVAL | constants.JANET_FIBER_RESUME_NO_SKIP);
            return self.ret(constants.JANET_SIGNAL_DEBUG, val.fromNil());
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

// The abi of the loop was here: `janet_run_vm`, built by
// `raise.jumping`, whose whole purpose was to turn the error back into the
// `longjmp` that `janet_continue_no_check` in `src/core/vm.c` was waiting for
// with a `setjmp`. It was the last such abi in the tree. The hinge moved that
// caller to `vm_entry.zig`, where it catches the error instead, so the loop is
// reached by an ordinary import and there is nothing left for an abi to
// convert.

// ------------------------------------------------------------- `(trace)`

/// `vm_do_trace`. Print a traced call and its arguments to `(dyn :err)`.
///
/// C kept this as a macro over two one-line functions in `src/core/vm.c`, and
/// the reason was the stack: `janet_eprintf` can resize a fiber's stack, so
/// `fiber->data + fiber->stackstart` has to be recomputed for every element and
/// a pointer handed across would freeze at the first. That is why there are two
/// entry points rather than one -- `traceFiber` recomputes, `traceArgv` takes
/// an argv the caller owns and that nothing here can move.
///
/// Neither can carry a raise: both are called from the middle of a call
/// sequence that has already committed. `dynprintf` can raise, because
/// `(dyn :err)` may be a Janet function; that is reported exactly as the abi
/// reported it.
pub fn traceFiber(func: *types.JanetFunction, argc: i32, fiber: *types.JanetFiber) void {
    traceHeader(func);
    var i: i32 = 0;
    while (i < argc) : (i += 1) {
        const argv = fiber.data.? + @as(usize, @intCast(fiber.stackstart));
        eprintf(" %p", .{argv[@intCast(i)]});
    }
    eprintf(")\n", .{});
}

pub fn traceArgv(func: *types.JanetFunction, argv: []const types.Janet) void {
    traceHeader(func);
    var i: i32 = 0;
    while (i < @as(i32, @intCast(argv.len))) : (i += 1) eprintf(" %p", .{argv[@intCast(i)]});
    eprintf(")\n", .{});
}

fn traceHeader(func: *types.JanetFunction) void {
    if (func.def.?.name != null) {
        eprintf("trace (%S", .{func.def.?.name});
    } else {
        eprintf("trace (%p", .{wrap.fromFunction(func)});
    }
}

inline fn eprintf(comptime format: [:0]const u8, args: anytype) void {
    raise.reported(pp_format.dynprintf("err", @ptrCast(@alignCast(stdio.err())), format, args));
}

// -------------------------------------------------------------------------
// The call protocol -- what `vm_calls.zig` was.
// -------------------------------------------------------------------------

inline fn isNil(x: types.Janet) bool {
    return kind.checkType(x, constants.JANET_NIL) != 0;
}

// -------------------------------------------------------------- invocation

/// The arity check and indexed access shared by `janet_method_invoke`'s last
/// two arms. `method_is_ds` picks which operand is the data structure, which is
/// the only thing that differs between them.
///
/// `argv` is passed rather than `argv[0]`, and that ordering is load-bearing:
/// the C reads `argv[0]` only after the arity check has passed, so a
/// zero-argument call must not touch it. Reading it eagerly would be a read of
/// whatever the previous frame left in that stack slot.
inline fn invokeIndexed(method: types.Janet, argv: []types.Janet, method_is_ds: bool) raise.Error!types.Janet {
    if (@as(i32, @intCast(argv.len)) != 1) {
        return pp_format.panicf("%v called with %d arguments, possibly expected 1", .{ method, @as(i32, @intCast(argv.len)) });
    }
    return if (method_is_ds) try access.in(method, argv[0]) else try access.in(argv[0], method);
}

/// `janet_method_invoke`. Calls a value that has already been resolved to a
/// callee, dispatching on what kind of thing it turned out to be.
///
/// The C original reaches its indexed arm two ways: by falling out of the
/// `JANET_ABSTRACT` case when the abstract type has no `call` callback, and by
/// listing the six indexable types beside it. Zig has no fallthrough, so the
/// abstract arm calls `invokeIndexed` itself. The order of operations is
/// unchanged — `at->call` is consulted first, and only its absence reaches the
/// arity check.
///
/// The default arm is the one that reverses the operands: calling a keyword
/// looks the *keyword* up in its argument, which is what makes `(:key struct)`
/// work, while calling a table looks the *argument* up in the table.
pub fn methodInvoke(method: types.Janet, argv: []types.Janet) raise.Error!types.Janet {
    switch (kind.typeOf(method)) {
        constants.JANET_CFUNCTION => return raise.cfunction(wrap.toCfunction(method))(argv),
        constants.JANET_FUNCTION => {
            const fun = wrap.toFunction(method);
            return try vm_entry.callImpl(fun, argv);
        },
        constants.JANET_ABSTRACT => {
            const abst = wrap.toAbstract(method);
            const at = abstract_type.ofAbstract(abst);
            if (at.call) |call| return try call(abst, @intCast(argv.len), argv.ptr);
            return try invokeIndexed(method, argv, true);
        },
        constants.JANET_STRING,
        constants.JANET_BUFFER,
        constants.JANET_TABLE,
        constants.JANET_STRUCT,
        constants.JANET_ARRAY,
        constants.JANET_TUPLE,
        => return try invokeIndexed(method, argv, true),
        else => return try invokeIndexed(method, argv, false),
    }
}

/// `call_nonfn`, renamed. The `JOP_CALL` and `JOP_TAILCALL` path for a callee
/// that is not a `JanetFunction`, with the arguments already pushed onto the
/// fiber stack.
///
/// It resets `stacktop` to `stackstart` *before* invoking, so the callee sees
/// an unpushed stack and the arguments it reads live above the new top. That is
/// not tidiness: `janet_method_invoke` can reach `janet_call`, which pushes a
/// frame of its own, and it would push it over these arguments if the top were
/// still where the caller left it.
pub fn callNonfn(fiber: *types.JanetFiber, callee: types.Janet) raise.Error!types.Janet {
    const argc = fiber.*.stacktop - fiber.*.stackstart;
    fiber.*.stacktop = fiber.*.stackstart;
    return methodInvoke(callee, (fiber.*.data.? + asSize(fiber.*.stacktop))[0..@intCast(argc)]);
}

/// `method_to_fun`. Kept as a Zig-private inline rather than a symbol: it is
/// `janet_get` with its operands swapped, and both of its callers are here.
///
/// Raising, since Phase 11 Part 15. It reached `janet_get` — the abi, which
/// is `raise.panicking` over `access.get` — from inside a chain every one of
/// whose callers is `raise.Raising`, so an abstract's `get` callback refusing
/// became a report nobody consumed. `(+ (int/s64 1) {})` killed the process
/// instead of raising a catchable error, because the binop fallback looks
/// `:r+` up on the right operand and that lookup is this function.
inline fn methodToFun(method: types.Janet, obj: types.Janet) raise.Raising(types.Janet) {
    return access.get(obj, method);
}

/// `resolve_method`, renamed. Turns the keyword of a method call into the
/// callee it names, reading the receiver from the bottom of the pushed
/// arguments.
///
/// The zero-argument branch cannot be reached from Janet source — the compiler
/// rejects a method call with no receiver outright — so `asm` is the only route
/// to it, and `test/vm_calls.c` takes that route.
pub fn resolveMethod(name: types.Janet, fiber: *types.JanetFiber) raise.Error!types.Janet {
    const argc = fiber.*.stacktop - fiber.*.stackstart;
    if (argc < 1) {
        return pp_format.panicf("method call (%v) takes at least 1 argument, got 0", .{name});
    }
    const receiver = fiber.*.data.?[asSize(fiber.*.stackstart)];
    const callee = try methodToFun(name, receiver);
    if (isNil(callee)) {
        return pp_format.panicf("unknown method %v invoked on %v", .{ name, receiver });
    }
    return callee;
}

/// `janet_method_lookup`. Looks a method up by C string, which is how the
/// operator fallbacks and `janet_mcall` name theirs.
///
/// `janet_ckeywordv` interns the name on every call. The C original does the
/// same, and the symbol cache makes the second and later calls a lookup rather
/// than an allocation.
///
/// The `callconv(.c)` this carried was a translation artefact: nothing exports
/// it and nothing takes its address, so `janet_method_lookup` has not been a
/// symbol since the seam closed. It went with the conversion above, because a
/// C calling convention cannot carry an error union.
pub fn methodLookup(x: types.Janet, name: [*:0]const u8) raise.Raising(types.Janet) {
    return methodToFun(value.fromBytes(std.mem.span(name), .keyword), x);
}

/// `janet_unary_call`. The operator fallback for a one-operand opcode whose
/// operand is not a number — `JOP_BNOT` is the only one that reaches it.
pub fn unaryCall(method: [*:0]const u8, arg: types.Janet) raise.Error!types.Janet {
    const m = try methodLookup(arg, method);
    if (isNil(m)) {
        return pp_format.panicf("could not find method :%s for %v", .{ method, arg });
    }
    var argv = [_]types.Janet{arg};
    return methodInvoke(m, argv[0..1]);
}

/// `janet_binop_call`. The operator fallback for a two-operand opcode where at
/// least one operand is not a number: `(+ x y)` on a non-number tries `:+` on
/// the left operand and then `:r+` on the right.
///
/// The right-hand attempt swaps the arguments, so a `:r+` method receives its
/// own receiver first. Both `argv` arrays are built before the nil check the
/// way the C does, which matters only in that the panic path never reads them.
pub fn binopCall(lmethod: [*:0]const u8, rmethod: [*:0]const u8, lhs: types.Janet, rhs: types.Janet) raise.Error!types.Janet {
    const lm = try methodLookup(lhs, lmethod);
    if (isNil(lm)) {
        const lr = try methodLookup(rhs, rmethod);
        var argv = [_]types.Janet{ rhs, lhs };
        if (isNil(lr)) {
            return pp_format.panicf(
                "could not find method :%s for %v or :%s for %v",
                .{ lmethod, lhs, rmethod, rhs },
            );
        }
        return methodInvoke(lr, argv[0..2]);
    } else {
        var argv = [_]types.Janet{ lhs, rhs };
        return methodInvoke(lm, argv[0..2]);
    }
}

/// `janet_mcall`. The public entry for calling a method by name, and the one
/// function here that was never `static`. `value.c` calls it for `:length` on
/// an abstract type, and `run_vm` reaches it from the immediate-operand
/// arithmetic opcodes.
pub fn mcall(name: [*:0]const u8, argv: []types.Janet) raise.Error!types.Janet {
    if (@as(i32, @intCast(argv.len)) < 1) {
        return pp_format.panicf("method :%s expected at least 1 argument", .{name});
    }
    const method = try methodLookup(argv[0], name);
    if (isNil(method)) {
        return pp_format.panicf("could not find method :%s for %v", .{ name, argv[0] });
    }
    return methodInvoke(method, argv);
}

// ------------------------------------------------------------- fill loops

/// `fill_table`, renamed. `JOP_MAKE_TABLE` over a run of key/value pairs on the
/// fiber stack.
///
/// `janet_table_put` hashes and compares every key on the way in, so an
/// abstract key with a `hash` or `compare` callback can raise from inside this
/// loop, or run the collector while the table being filled is unrooted.
/// `FOUND.md` has the second of those; it predates the port and is unaffected
/// by it.
pub fn fillTable(table: *types.JanetTable, mem: ?[*]const types.Janet, count: i32) callconv(.c) void {
    var i: i32 = 0;
    while (i < count) : (i += 2) {
        tables.put(table, mem.?[asSize(i)], mem.?[asSize(i + 1)]);
    }
}

/// `fill_struct`, renamed. `JOP_MAKE_STRUCT`, over a struct still under
/// construction: `janet_struct_put` writes into the buckets `janet_struct_begin`
/// allocated, and the caller calls `janet_struct_end` afterwards.
pub fn fillStruct(st: [*]types.JanetKV, mem: [*]const types.Janet, count: i32) callconv(.c) void {
    var i: i32 = 0;
    while (i < count) : (i += 2) {
        structs.put(st, mem[asSize(i)], mem[asSize(i + 1)]);
    }
}

/// `fill_string`, renamed. `JOP_MAKE_STRING` and `JOP_MAKE_BUFFER`, which
/// stringify each element in turn.
///
/// This is the loop that reaches an abstract type's `tostring` callback, and
/// `janet_to_string_b` can also raise `buffer overflow` from `janet_buffer_ensure`
/// with no callback involved at all. `JOP_MAKE_STRING`'s scratch buffer is
/// `janet_malloc`ed and invisible to the collector, so a raise from here leaks
/// it — recorded in `FOUND.md`, reproduced rather than repaired, and the reason
/// the trampoline build takes one scope around this loop rather than one per
/// element.
/// **This raises, and it used to be reached through an abi that did not.**
/// Phase 11 Part 12: `janet_fill_string` was `raise.reported` over this
/// implementation, and `vm_run.zig`'s `JOP_MAKE_STRING` and `JOP_MAKE_BUFFER`
/// arms called the *abi* from inside `runVm`, which is itself raising. A
/// `tostring` refusal was therefore flattened into a report nobody consumed:
/// the loop went on to build a string out of a half-filled buffer, and the
/// outstanding report killed the process at the next scope boundary with
/// `a raise was reported to a C caller and never consumed` — arbitrarily far
/// from the cause. Under the C original the same refusal was a `longjmp` and
/// propagated. The abi is gone and the callers use `try`, which is rule 13's
/// family: an ordinary import away from not needing the abi at all.
pub fn fillString(buffer: *types.JanetBuffer, mem: ?[*]const types.Janet, count: i32) raise.Raising(void) {
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        try pp_describe.toStringB(buffer, mem.?[asSize(i)]);
    }
}

// ------------------------------------------------------------- the one abi

// There were nine abis here, hidden exactly as the C build hid them,
// because `state.h` declared all nine and C callers cannot consume a Zig
// error. Phase 11 Part 12 spent eight of them: every remaining caller reaches
// this file by import, and the last C caller of each was `test/vm_calls.c`.
// The `state.h` block went with them.
//
// `janet_mcall` stays, and the reason is the same one Part 10 and Part 11
// recorded for eleven other names: it is `janet.h`'s public surface. It has no
// in-tree caller at all now — `value_access.zig` reaches `mcall` by import —
// and it is what an embedder calls to invoke a method.

pub const mcallPanicking = raise.panickingArgv(mcall).abi;
