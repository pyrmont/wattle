//! The interpreter loop, and the call protocol it dispatches through.
//!
//! `runVm` is the loop. `methodInvoke`, `callNonfn`, `resolveMethod`,
//! `methodLookup`, `unaryCall`, `binopCall` and `mcall` are the call protocol,
//! `fillTable`, `fillStruct` and `fillString` the three constructor loops, and
//! `traceFiber` and `traceArgv` what `(trace)` prints.
//!
//! The call protocol is imported by the loop as well as by the root, because
//! the loop inlines it. Reaching it out of line costs enough on method
//! dispatch and on arithmetic to be visible in a benchmark.
//!
//! The value operations the loop reaches on every instruction are `wrap`'s and
//! `repr`'s own, named directly at every site. They are `pub inline fn`, which
//! is what keeps them out of the symbol table; reaching them through it costs
//! the arithmetic workload about as much again.
//!
//! There is no per-call `setjmp` scope around the loop. Its callees, the
//! access layer, the callee layer, the fiber pushes, `order.zig`'s `equals`
//! and `compare`, the three fills and the cfunction call, each return their
//! raise, so there is nothing left for a scope to catch.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstract_type = @import("../api/abstract_type.zig");
const abstracts = @import("value/abstracts.zig");
const access = @import("value/helpers/access.zig");
const args_core = @import("args.zig");
const arrays = @import("value/arrays.zig");
const buffers = @import("value/buffers.zig");
const c = @import("cabi");
const constants = @import("constants");
const fibers = @import("value/fibers.zig");
const functions = @import("value/functions.zig");
const gc_alloc = @import("gc.zig");
const gc_mark = @import("gc/mark.zig");
const order = @import("value/helpers/order.zig");
const pp_describe = @import("pp.zig");
const pp_format = @import("pp/format.zig");
const raise = @import("../api/raise.zig");
const repr = @import("repr");
const stdio = @import("stdio.zig");
const structs = @import("value/structs.zig");
const tables = @import("value/tables.zig");
const tuples = @import("value/tuples.zig");
const utils = @import("utils.zig");
const value = @import("value.zig");
const vm_calls = @import("vm.zig");
const vm_entry = @import("vm/entry.zig");
const vm_state = @import("vm/state.zig");
const wrap = @import("value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// A stack frame's size in `Value` slots. `stackFrame` is the one place that
/// does the arithmetic.
const frame_size: i32 = constants.JANET_FRAME_SIZE;

/// Whether this build checks for an interpreter interrupt between
/// instructions. The negative spelling is Janet's; `constants` states it
/// positively so the guards read forwards.
const has_interrupt = constants.JANET_VM_HAS_INTERRUPT == 1;

// ==========================================================================
// Types
// ==========================================================================

/// The four comparison operators, which reach `order.zig`'s `compare` rather
/// than a method where either operand is not a number.
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

/// `runVm`'s three registers plus the fiber they belong to.
///
/// C declares `stack`, `pc` and `func` `register` and keeps the `setjmp` out
/// of their frame so that stays true. Here they are fields of a structure
/// whose address never reaches a call the optimiser cannot see through: every
/// method is `inline`, and the only pointer handed to a C frame is the context
/// `scoped` builds, which is a separate object with copies in it.
const Interp = struct {
    fiber: *fibers.Fiber,
    stack: [*]repr.Value,
    pc: [*]u32,
    func: *functions.Function,

    /// The VM, captured once at the top of `runVm` through
    /// `vm_state.pinned()`. Read it from here rather than calling `current()`
    /// in a loop helper: the helpers below inline into all seventy-eight arms,
    /// and a `current()` in one of them is a `_tlv_get_addr` call per arm on
    /// Darwin. See `pinned()`'s comment for the count and the oracle.
    vm: *vm_state.Vm,

    // State movement.

    /// Publish the program counter before anything that could raise, so a
    /// stack trace names the instruction rather than its predecessor.
    inline fn commit(self: *Interp) void {
        stackFrame(self.stack).pc = .{ .bytecode = self.pc };
    }

    /// Re-read all three registers from the frame the fiber is now in.
    ///
    /// A C frame has neither a function nor a program counter, and `runVm`
    /// restores onto one deliberately: the raise path checks
    /// `stackFrame(stack).func == null`, pops the frame and restores again.
    /// Neither is read while that frame is current, so the previous values are
    /// left in place rather than nulls being written into fields whose types
    /// say there are none.
    inline fn restore(self: *Interp) void {
        self.stack = self.fiber.data.? + utils.asSize(self.fiber.frame);
        const frame = stackFrame(self.stack);
        if (frame.func) |function| self.func = function;
        if (frame.pc.bytecode) |counter| self.pc = counter;
    }

    /// `stack = fiber->data + fiber->frame`, which the opcode bodies do on
    /// their own after any call that could have moved the stack.
    inline fn reload(self: *Interp) void {
        self.stack = self.fiber.data.? + utils.asSize(self.fiber.frame);
    }

    inline fn nextOp(self: *const Interp) constants.Opcode {
        return constants.Opcode.fromWord(self.pc[0]);
    }

    inline fn maybeCollect(self: *const Interp) void {
        if (self.vm.gc.next_collection >= self.vm.gc.interval) gc_mark.collect();
    }

    // Leaving the loop.

    /// Leave the loop with a signal and a value, committing the program
    /// counter on the way out.
    inline fn ret(self: *Interp, sig: abi.Signal, v: repr.Value) abi.Signal {
        self.vm.return_reg.?.* = v;
        self.commit();
        return sig;
    }

    /// The same without the commit, for a site whose `stack` is already stale.
    inline fn retNoRestore(self: *Interp, sig: abi.Signal, v: repr.Value) abi.Signal {
        self.vm.return_reg.?.* = v;
        return sig;
    }

    /// Returns the error out of `runVm` rather than jumping past its frame,
    /// and sets `fibers.FiberFlags.did_raise` exactly as `signal.zig`'s
    /// `signalv` does, both reaching `signalCommit` through `raise.signal`,
    /// because the resume path reads that flag to pop a C frame and to turn a
    /// raise at a tail call into an implicit return.
    ///
    /// It does not commit. Each site keeps whatever commit it already had,
    /// because that is not uniform: `.call` commits before entering
    /// `fibers.funcframe` and its `stack` is stale afterwards, and `.tailcall`
    /// commits to a frame it recomputes.
    inline fn raiseSignal(self: *Interp, sig: abi.Signal, v: repr.Value) raise.Error!abi.Signal {
        _ = self;
        // Returned rather than jumped. `raise.signal` reaches the same
        // `signalRecord` a jumping delivery would, so the plan, the
        // coercion and the `did_raise` flag are unchanged; only the
        // travel differs. `continueNoCheck` catches the error one frame up.
        return raise.signal(sig, v);
    }

    /// Raise an `error` signal with `v` as its value.
    inline fn raisev(self: *Interp, v: repr.Value) raise.Error!abi.Signal {
        return try self.raiseSignal(abi.Signal.@"error", v);
    }

    /// Raise with a formatted message, built by `pp_format.panicf`, which
    /// parses the format string at compile time and indexes the tuple; the
    /// specifier and the value it renders are checked against each other
    /// here.
    inline fn raisef(self: *Interp, comptime format: [:0]const u8, args: anytype) raise.Error!abi.Signal {
        _ = self;
        return pp_format.panicf(format, args);
    }

    /// Commit, then raise a plain string.
    inline fn throw(self: *Interp, message: [*:0]const u8) raise.Error!abi.Signal {
        self.commit();
        return try self.raisev(value.fromBytes(std.mem.span(message), .string));
    }

    /// Nothing where `condition` is true, and a raise with `message` where it
    /// is not.
    inline fn assert(self: *Interp, condition: bool, message: [*:0]const u8) raise.Error!?abi.Signal {
        if (condition) return null;
        return try self.throw(message);
    }

    /// The same for one expected tag, naming both it and what arrived.
    inline fn assertType(self: *Interp, x: repr.Value, comptime t: repr.Tag) raise.Error!?abi.Signal {
        if (repr.checkType(x, t)) return null;
        self.commit();
        return try self.raisef("expected %T, got %v", .{ repr.TagSet.one(t), x });
    }

    /// The same for a set of tags. A set that includes both array and tuple
    /// also passes an abstract whose type has a `chunk` callback, and its
    /// refusal names `indexed value`.
    inline fn assertTypes(self: *Interp, x: repr.Value, typeflags: repr.TagSet) raise.Error!?abi.Signal {
        if (repr.checkTypes(x, typeflags)) return null;
        const indexed = typeflags.bits() & repr.TagSet.indexed.bits() == repr.TagSet.indexed.bits();
        if (indexed and args_core.checkindexed(x)) return null;
        self.commit();
        if (indexed) return try self.raisef("expected %K, got %v", .{ typeflags, x });
        return try self.raisef("expected %T, got %v", .{ typeflags, x });
    }

    /// The auto-suspend check an interrupting build runs between instructions.
    /// `condition` is only ever a comparison on an instruction field, so
    /// evaluating it in a build without the interrupt costs nothing.
    inline fn maybeAutoSuspend(self: *Interp, condition: bool) raise.Error!?abi.Signal {
        if (!has_interrupt) return null;
        if (condition and abstracts.atomicLoadRelaxed(&self.vm.auto_suspend) != 0) {
            self.fiber.flags.resume_no_useval = true;
            self.fiber.flags.resume_no_skip = true;
            return self.ret(abi.Signal.interrupt, wrap.fromNil());
        }
        return null;
    }

    // Opcode templates.
    //
    // Each returns null to mean "the instruction is done and `pc` is where the
    // next dispatch should read it", and a signal to mean "leave the loop".
    // The garbage-collector check belongs to the template rather than to the
    // arm because the two paths through most of these disagree about it: the
    // numeric path allocates nothing, and the fallback path can allocate a
    // whole method call's worth.

    /// `.@"return"` and `.return_nil`, which differ only in where the value
    /// comes from.
    inline fn doReturn(self: *Interp, retval: repr.Value) raise.Error!?abi.Signal {
        const entrance_frame = stackFrame(self.stack).flags.entrance;
        fibers.popframe(self.fiber);
        if (entrance_frame) return self.retNoRestore(abi.Signal.ok, retval);
        self.restore();
        self.stack[fA(self.pc)] = retval;
        self.maybeCollect();
        self.pc += 1;
        return null;
    }

    /// `.load_upvalue` and `.set_upvalue`. The three assertions and the
    /// on-stack/off-stack choice are shared; `store` is comptime, so neither
    /// opcode pays a branch to find out which one it is.
    inline fn upvalue(self: *Interp, comptime store: bool) raise.Error!?abi.Signal {
        const eindex: i32 = @intCast(fB(self.pc));
        const vindex: i32 = @intCast(fC(self.pc));
        if (try self.assert(self.func.def.?.environments_length > eindex, "invalid upvalue environment")) |s| return s;
        const env = funcEnvSlot(self.func, eindex).*;
        if (try self.assert(env.?.length > vindex, "invalid upvalue index")) |s| return s;
        if (try self.assert(functions.envValid(env.?), "invalid upvalue environment")) |s| return s;
        const slot: [*]repr.Value = if (env.?.offset > 0)
            env.?.as.fiber.?.data.? + utils.asSize(env.?.offset + vindex)
        else
            env.?.as.values.? + utils.asSize(vindex);
        if (store) {
            slot[0] = self.stack[fA(self.pc)];
        } else {
            self.stack[fA(self.pc)] = slot[0];
        }
        self.pc += 1;
        return null;
    }

    /// `.equals` and `.not_equals`.
    inline fn equals(self: *Interp, comptime negate: bool) raise.Error!?abi.Signal {
        self.commit();
        const eq = order.equals(self.stack[fB(self.pc)], self.stack[fC(self.pc)]);
        self.stack[fA(self.pc)] = wrap.fromBoolean(if (negate) !eq else eq);
        self.pc += 1;
        return null;
    }

    /// A two-operand arithmetic opcode whose right operand is an instruction
    /// field rather than a register.
    inline fn binopImmediate(self: *Interp, comptime op: Op) raise.Error!?abi.Signal {
        const op1 = self.stack[fB(self.pc)];
        if (!repr.checkType(op1, .number)) {
            self.commit();
            var argv = [_]repr.Value{ op1, wrap.fromNumber(@floatFromInt(fCS(self.pc))) };
            const v = try vm_calls.mcall(op.method(), &argv);
            self.reload();
            self.stack[fA(self.pc)] = v;
            self.maybeCollect();
        } else {
            const x1 = wrap.toNumber(op1);
            self.stack[fA(self.pc)] = wrap.fromNumber(op.applyNumber(x1, @floatFromInt(fCS(self.pc))));
        }
        self.pc += 1;
        return null;
    }

    /// The same for a bitwise opcode.
    inline fn bitopImmediate(self: *Interp, comptime op: Op) raise.Error!?abi.Signal {
        const op1 = self.stack[fB(self.pc)];
        if (!repr.checkType(op1, .number)) {
            self.commit();
            var argv = [_]repr.Value{ op1, wrap.fromNumber(@floatFromInt(fCS(self.pc))) };
            const v = try vm_calls.mcall(op.method(), &argv);
            self.reload();
            self.stack[fA(self.pc)] = v;
            self.maybeCollect();
        } else {
            const T = op.intType();
            const y1 = wrap.toNumber(op1);
            if (!checkRange(T, y1)) {
                self.commit();
                return try self.raisef("value %v out of range for " ++ op.intMessage(), .{op1});
            }
            const x1: T = @intFromFloat(y1);
            self.stack[fA(self.pc)] = wrap.fromNumber(intToDouble(T, op.applyBits(x1, fCS(self.pc))));
        }
        self.pc += 1;
        return null;
    }

    /// A two-operand arithmetic opcode over two registers, falling back to the
    /// operator methods when either operand is not a number.
    inline fn binop(self: *Interp, comptime op: Op) raise.Error!?abi.Signal {
        const op1 = self.stack[fB(self.pc)];
        const op2 = self.stack[fC(self.pc)];
        if (repr.checkType(op1, .number) and repr.checkType(op2, .number)) {
            const x1 = wrap.toNumber(op1);
            const x2 = wrap.toNumber(op2);
            self.stack[fA(self.pc)] = wrap.fromNumber(op.applyNumber(x1, x2));
            self.pc += 1;
            return null;
        }
        return self.binopFallback(op.method(), op.rmethod(), op1, op2);
    }

    /// The same for a bitwise opcode.
    inline fn bitop(self: *Interp, comptime op: Op) raise.Error!?abi.Signal {
        const op1 = self.stack[fB(self.pc)];
        const op2 = self.stack[fC(self.pc)];
        if (repr.checkType(op1, .number) and repr.checkType(op2, .number)) {
            const T = op.intType();
            const y1 = wrap.toNumber(op1);
            const y2 = wrap.toNumber(op2);
            if (!checkRange(T, y1)) {
                self.commit();
                return try self.raisef("value %v out of range for " ++ op.intMessage(), .{op1});
            }
            if (!checkRange(i32, y2)) {
                self.commit();
                // `y2`, not `op2`: `%f` renders a `double`, and `op2` is a
                // `Janet`. Handing the union to it prints `0.000000` on
                // x86-64, where the System V classification sends it through a
                // general-purpose register while the conversion reads the SSE
                // save area. The tuple driver makes that a compile error
                // rather than a choice.
                return try self.raisef("rhs must be valid 32-bit signed integer, got %f", .{y2});
            }
            const x1: T = @intFromFloat(y1);
            const x2: i32 = @intFromFloat(y2);
            self.stack[fA(self.pc)] = wrap.fromNumber(intToDouble(T, op.applyBits(x1, x2)));
            self.pc += 1;
            return null;
        }
        return self.binopFallback(op.method(), op.rmethod(), op1, op2);
    }

    /// The tail both fallbacks share: commit, try `:op` on the left operand
    /// and then `:rop` on the right, refresh `stack` because the call may have
    /// moved it, and check the collector.
    inline fn binopFallback(
        self: *Interp,
        lmethod: [*:0]const u8,
        rmethod: [*:0]const u8,
        op1: repr.Value,
        op2: repr.Value,
    ) raise.Error!?abi.Signal {
        self.commit();
        const v = try vm_calls.binopCall(lmethod, rmethod, op1, op2);
        self.reload();
        self.stack[fA(self.pc)] = v;
        self.maybeCollect();
        self.pc += 1;
        return null;
    }

    /// A comparison opcode over two registers, falling back to `order.compare`
    /// when either operand is not a number.
    inline fn compop(self: *Interp, comptime op: Cmp) raise.Error!?abi.Signal {
        const op1 = self.stack[fB(self.pc)];
        const op2 = self.stack[fC(self.pc)];
        if (repr.checkType(op1, .number) and repr.checkType(op2, .number)) {
            const x1 = wrap.toNumber(op1);
            const x2 = wrap.toNumber(op2);
            self.stack[fA(self.pc)] = wrap.fromBoolean(op.applyNumber(x1, x2));
            self.pc += 1;
            return null;
        }
        return self.compareFallback(op, op1, op2);
    }

    /// The same with the right operand taken from an instruction field.
    inline fn compopImmediate(self: *Interp, comptime op: Cmp) raise.Error!?abi.Signal {
        const op1 = self.stack[fB(self.pc)];
        if (repr.checkType(op1, .number)) {
            const x1 = wrap.toNumber(op1);
            const x2: f64 = @floatFromInt(fCS(self.pc));
            self.stack[fA(self.pc)] = wrap.fromBoolean(op.applyNumber(x1, x2));
            self.pc += 1;
            return null;
        }
        return self.compareFallback(op, op1, wrap.fromInteger(fCS(self.pc)));
    }

    inline fn compareFallback(self: *Interp, comptime op: Cmp, op1: repr.Value, op2: repr.Value) raise.Error!?abi.Signal {
        self.commit();
        const a = wrap.fromBoolean(op.applyOrder(order.compare(op1, op2)));
        self.reload();
        self.stack[fA(self.pc)] = a;
        self.maybeCollect();
        self.pc += 1;
        return null;
    }
};

/// The four arithmetic operators that have both a register and an immediate
/// form, plus the six bitwise ones. The method names are the operator spelled
/// out, so `.shift_right` and `.shift_right_unsigned` both fall back to `:>>`.
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

    /// The bitwise operators, on the narrowed left operand and an `i32` right
    /// operand, with the result cast back to the narrowed type before it is
    /// wrapped. The shifts are where that cast matters.
    ///
    /// A shift is a wrapping shift and its count is taken modulo the
    /// operand's width. A negative left operand, an overflow into the sign
    /// bit, and a count at or beyond the width each have a defined result
    /// here, and it is the one every supported target gives. The boxed 64-bit
    /// shifts in `value/ints.zig` follow the same rule at 64 bits.
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

// ==========================================================================
// Public functions
// ==========================================================================

/// The operator fallback for a two-operand opcode where at least one operand
/// is not a number: `(+ x y)` on a non-number tries `:+` on the left operand
/// and then `:r+` on the right.
///
/// The right-hand attempt swaps the arguments, so a `:r+` method receives its
/// own receiver first. Both `argv` arrays are built before the nil check that
/// might discard them, which is safe only because the panic path never reads
/// one of them.
pub fn binopCall(lmethod: [*:0]const u8, rmethod: [*:0]const u8, lhs: repr.Value, rhs: repr.Value) raise.Error!repr.Value {
    const lm = try methodLookup(lhs, lmethod);
    if (isNil(lm)) {
        const lr = try methodLookup(rhs, rmethod);
        var argv = [_]repr.Value{ rhs, lhs };
        if (isNil(lr)) {
            return pp_format.panicf(
                "could not find method :%s for %v or :%s for %v",
                .{ lmethod, lhs, rmethod, rhs },
            );
        }
        return methodInvoke(lr, argv[0..2]);
    } else {
        var argv = [_]repr.Value{ lhs, rhs };
        return methodInvoke(lm, argv[0..2]);
    }
}

/// The `.call` and `.tailcall` path for a callee that is not a
/// `functions.Function`, with the arguments already pushed onto the fiber
/// stack.
///
/// It resets `stacktop` to `stackstart` before invoking, so the callee sees an
/// unpushed stack and the arguments it reads live above the new top. That is
/// not tidiness: `methodInvoke` can reach `vm/entry.zig`'s `call`, which
/// pushes a frame of its own, and it would push it over these arguments if the
/// top were still where the caller left it.
pub fn callNonfn(fiber: *fibers.Fiber, callee: repr.Value) raise.Error!repr.Value {
    const argc = fiber.stacktop - fiber.stackstart;
    fiber.stacktop = fiber.stackstart;
    return methodInvoke(callee, (fiber.data.? + utils.asSize(fiber.stacktop))[0..@intCast(argc)]);
}

/// `.make_string` and `.make_buffer`, which stringify each element in turn.
///
/// This is the loop that reaches an abstract type's `tostring` callback, and
/// `pp.zig`'s `toStringB` can also raise `buffer overflow` from
/// `buffers.extra`, which every push goes through, with no callback involved
/// at all. `.make_string`'s scratch buffer comes from `utils.allocMany` and is
/// off the collector's list, so that arm wraps it in a `defer`.
///
/// It raises, and it has to. Reached through a reporting abi instead, from
/// inside `runVm`, which is itself raising, a `tostring` refusal would be
/// flattened into a report nobody consumes: the loop would go on to build a
/// string out of a half-filled buffer, and the outstanding report would kill
/// the process at the next scope boundary, arbitrarily far from the cause. An
/// ordinary import is all it takes not to need the abi at all.
pub fn fillString(buffer: *buffers.Buffer, mem: []const repr.Value) raise.Error!void {
    for (mem) |x| try pp_describe.toStringB(buffer, x);
}

/// `.make_struct`, over a struct still under construction: `structs.put`
/// writes into the buckets `structs.begin` allocated, and the caller calls
/// `structs.end` afterwards.
pub fn fillStruct(st: [*]tables.KV, mem: [*]const repr.Value, count: i32) void {
    var i: i32 = 0;
    while (i < count) : (i += 2) {
        structs.put(st, mem[utils.asSize(i)], mem[utils.asSize(i + 1)]);
    }
}

/// `.make_table` over a run of key and value pairs on the fiber stack.
///
/// `tables.put` hashes and compares every key on the way in, so an abstract
/// key with a `hash` or `compare` callback runs from inside this loop. Such a
/// callback has no way to raise, `abi.zig` declaring both `callconv(.c)`, and
/// it may neither re-enter a comparison nor allocate GC memory: the table
/// being filled is reachable only from this frame, so a collection triggered
/// from underneath here would free it.
pub fn fillTable(table: *tables.Table, mem: ?[*]const repr.Value, count: i32) void {
    var i: i32 = 0;
    while (i < count) : (i += 2) {
        tables.put(table, mem.?[utils.asSize(i)], mem.?[utils.asSize(i + 1)]);
    }
}

/// The entry for calling a method by name.
///
/// `access.zig`'s `length` and `lengthv` reach it for `:length` on an abstract
/// type with no `length` callback, and `runVm` reaches it from the
/// immediate-operand arithmetic opcodes.
pub fn mcall(name: [*:0]const u8, argv: []repr.Value) raise.Error!repr.Value {
    if (argv.len < 1) {
        return pp_format.panicf("method :%s expected at least 1 argument", .{name});
    }
    const method = try methodLookup(argv[0], name);
    if (isNil(method)) {
        return pp_format.panicf("could not find method :%s for %v", .{ name, argv[0] });
    }
    return methodInvoke(method, argv);
}

/// Calls a value that has already been resolved to a callee, dispatching on
/// what kind of thing it turned out to be.
///
/// The abstract arm calls `invokeIndexed` itself rather than falling through
/// into the six indexable types beside it, because Zig has no fallthrough. The
/// order it keeps is that the type's own `call` callback is consulted first,
/// and only its absence reaches the arity check.
///
/// The default arm is the one that reverses the operands: calling a keyword
/// looks the keyword up in its argument, which is what makes `(:key struct)`
/// work, while calling a table looks the argument up in the table.
pub fn methodInvoke(method: repr.Value, argv: []repr.Value) raise.Error!repr.Value {
    switch (repr.typeOf(method)) {
        repr.Tag.cfunction => return raise.cfunction(wrap.toCfunction(method))(argv),
        repr.Tag.function => {
            const fun = wrap.toFunction(method);
            return try vm_entry.call(fun, argv);
        },
        repr.Tag.abstract => {
            const abst = wrap.toAbstract(method);
            const at = abstract_type.ofAbstract(abst);
            if (at.call) |call| return try call(abst, @intCast(argv.len), argv.ptr);
            return try invokeIndexed(method, argv, true);
        },
        repr.Tag.string,
        repr.Tag.buffer,
        repr.Tag.table,
        repr.Tag.@"struct",
        repr.Tag.array,
        repr.Tag.tuple,
        => return try invokeIndexed(method, argv, true),
        else => return try invokeIndexed(method, argv, false),
    }
}

/// Looks a method up by C string, which is how the operator fallbacks and
/// `mcall` name theirs.
///
/// The name is interned on every call, through `value.fromBytes`. The symbol
/// cache makes the second and later calls a lookup rather than an allocation.
pub fn methodLookup(x: repr.Value, name: [*:0]const u8) raise.Error!repr.Value {
    return methodToFun(value.fromBytes(std.mem.span(name), .keyword), x);
}

/// Turns the keyword of a method call into the callee it names, reading the
/// receiver from the bottom of the pushed arguments.
///
/// The zero-argument branch cannot be reached from Janet source, the compiler
/// rejecting a method call with no receiver outright, so `asm` is the only
/// route to it and `test/vm_calls.zig` takes that route.
pub fn resolveMethod(name: repr.Value, fiber: *fibers.Fiber) raise.Error!repr.Value {
    const argc = fiber.stacktop - fiber.stackstart;
    if (argc < 1) {
        return pp_format.panicf("method call (%v) takes at least 1 argument, got 0", .{name});
    }
    const receiver = fiber.data.?[utils.asSize(fiber.stackstart)];
    const callee = try methodToFun(name, receiver);
    if (isNil(callee)) {
        return pp_format.panicf("unknown method %v invoked on %v", .{ name, receiver });
    }
    return callee;
}

/// The interpreter loop.
///
/// `fiber_in` is the fiber to run and `in` the value the resume passes in.
/// The result is the signal the loop left on; the value that goes with it is
/// in the VM's `return_reg`.
///
/// It is `pub` because `vm/entry.zig` drives it, so it has a name specific
/// enough to sit in a symbol table.
pub fn runVm(fiber_in: *fibers.Fiber, in: repr.Value) raise.Error!abi.Signal {
    // Seventy-eight arms, each of which inlines several comptime templates.
    @setEvalBranchQuota(20000);
    var self: Interp = .{
        .vm = vm_state.pinned(),
        .fiber = fiber_in,
        .stack = undefined,
        .pc = undefined,
        .func = undefined,
    };
    const fiber = fiber_in;

    // A signal injected while the fiber was suspended is delivered instead of
    // resuming. It travels in `gc.flags` rather than in `flags`, for the
    // reason `signalInject` gives.
    //
    // The `@enumFromInt` below is safe because the six bits can only contain a
    // value `signalInject` put there, and every caller of that reaches it
    // through `Signal.fromWire`, which is the clamp. Without that clamp an
    // injected 14 through 63 would build an out-of-domain value of an
    // exhaustive enum right here.
    if (fiber.flags.resume_signal) {
        const sig: abi.Signal = @enumFromInt(fiber.gc.flags.own);
        fiber.gc.flags.own = 0;
        fiber.flags = fiber.flags.withoutResumeStateAndSignal();
        self.vm.return_reg.?.* = in;
        return sig;
    }

    self.restore();

    if (fiber.flags.did_raise) {
        if (stackFrame(self.stack).func == null) {
            // Inside a c function
            fibers.popframe(fiber);
            self.restore();
        }
        // Check if we were at a tail call instruction. If so, do an implicit
        // return.
        if (constants.Opcode.fromWord(self.pc[0]) == .tailcall) {
            const entrance_frame = stackFrame(self.stack).flags.entrance;
            fibers.popframe(fiber);
            if (entrance_frame) {
                fiber.flags = fiber.flags.withoutResumeState();
                return self.ret(abi.Signal.ok, in);
            }
            self.restore();
        }
    }

    if (!fiber.flags.resume_no_useval) self.stack[fA(self.pc)] = in;
    if (!fiber.flags.resume_no_skip) self.pc += 1;

    // With a breakpoint set, bit 7 is kept out of the masked value, so the
    // instruction lands on no arm and the `_ =>` arm below raises `debug`.
    const breakpoint_mask: u32 = if (fiber.flags.breakpoint) 0x7F else 0xFF;
    const first_opcode: constants.Opcode = @enumFromInt(@as(u8, @intCast(self.pc[0] & breakpoint_mask)));

    fiber.flags = fiber.flags.withoutResumeState();

    sw: switch (first_opcode) {
        .noop => {
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .@"error" => return self.ret(abi.Signal.@"error", self.stack[fA(self.pc)]),

        .typecheck => {
            // The instruction's E field *is* the set: `.typecheck` has
            // sixteen bits and `repr.TagSet` is sixteen bits, which is the
            // bytecode width the exit condition says to keep explicit.
            if (try self.assertTypes(self.stack[fA(self.pc)], repr.TagSet.fromBits(@intCast(fE(self.pc))))) |s| return s;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .@"return" => {
            if (try self.doReturn(self.stack[fD(self.pc)])) |s| return s;
            continue :sw self.nextOp();
        },
        .return_nil => {
            if (try self.doReturn(wrap.fromNil())) |s| return s;
            continue :sw self.nextOp();
        },

        .add_immediate => {
            if (try self.binopImmediate(.add)) |s| return s;
            continue :sw self.nextOp();
        },
        .add => {
            if (try self.binop(.add)) |s| return s;
            continue :sw self.nextOp();
        },
        .subtract_immediate => {
            if (try self.binopImmediate(.sub)) |s| return s;
            continue :sw self.nextOp();
        },
        .subtract => {
            if (try self.binop(.sub)) |s| return s;
            continue :sw self.nextOp();
        },
        .multiply_immediate => {
            if (try self.binopImmediate(.mul)) |s| return s;
            continue :sw self.nextOp();
        },
        .multiply => {
            if (try self.binop(.mul)) |s| return s;
            continue :sw self.nextOp();
        },
        .divide_immediate => {
            if (try self.binopImmediate(.div)) |s| return s;
            continue :sw self.nextOp();
        },
        .divide => {
            if (try self.binop(.div)) |s| return s;
            continue :sw self.nextOp();
        },

        .divide_floor => {
            const op1 = self.stack[fB(self.pc)];
            const op2 = self.stack[fC(self.pc)];
            if (repr.checkType(op1, .number) and repr.checkType(op2, .number)) {
                const x1 = wrap.toNumber(op1);
                const x2 = wrap.toNumber(op2);
                self.stack[fA(self.pc)] = wrap.fromNumber(@floor(x1 / x2));
                self.pc += 1;
                continue :sw self.nextOp();
            }
            if (try self.binopFallback("div", "rdiv", op1, op2)) |s| return s;
            continue :sw self.nextOp();
        },

        .modulo => {
            const op1 = self.stack[fB(self.pc)];
            const op2 = self.stack[fC(self.pc)];
            if (repr.checkType(op1, .number) and repr.checkType(op2, .number)) {
                const x1 = wrap.toNumber(op1);
                const x2 = wrap.toNumber(op2);
                if (x2 == 0) {
                    self.stack[fA(self.pc)] = wrap.fromNumber(x1);
                } else {
                    const intres = x2 * @floor(x1 / x2);
                    self.stack[fA(self.pc)] = wrap.fromNumber(x1 - intres);
                }
                self.pc += 1;
                continue :sw self.nextOp();
            }
            if (try self.binopFallback("mod", "rmod", op1, op2)) |s| return s;
            continue :sw self.nextOp();
        },

        .remainder => {
            const op1 = self.stack[fB(self.pc)];
            const op2 = self.stack[fC(self.pc)];
            if (repr.checkType(op1, .number) and repr.checkType(op2, .number)) {
                const x1 = wrap.toNumber(op1);
                const x2 = wrap.toNumber(op2);
                self.stack[fA(self.pc)] = wrap.fromNumber(c.fmod(x1, x2));
                self.pc += 1;
                continue :sw self.nextOp();
            }
            if (try self.binopFallback("%", "r%", op1, op2)) |s| return s;
            continue :sw self.nextOp();
        },

        .band => {
            if (try self.bitop(.band)) |s| return s;
            continue :sw self.nextOp();
        },
        .bor => {
            if (try self.bitop(.bor)) |s| return s;
            continue :sw self.nextOp();
        },
        .bxor => {
            if (try self.bitop(.bxor)) |s| return s;
            continue :sw self.nextOp();
        },

        .bnot => {
            const op = self.stack[fE(self.pc)];
            if (repr.checkType(op, .number)) {
                self.stack[fA(self.pc)] = wrap.fromInteger(~wrap.toInteger(op));
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

        .shift_right_unsigned => {
            if (try self.bitop(.shru)) |s| return s;
            continue :sw self.nextOp();
        },
        .shift_right_unsigned_immediate => {
            if (try self.bitopImmediate(.shru)) |s| return s;
            continue :sw self.nextOp();
        },
        .shift_right => {
            if (try self.bitop(.shr)) |s| return s;
            continue :sw self.nextOp();
        },
        .shift_right_immediate => {
            if (try self.bitopImmediate(.shr)) |s| return s;
            continue :sw self.nextOp();
        },
        .shift_left => {
            if (try self.bitop(.shl)) |s| return s;
            continue :sw self.nextOp();
        },
        .shift_left_immediate => {
            if (try self.bitopImmediate(.shl)) |s| return s;
            continue :sw self.nextOp();
        },

        .move_near => {
            self.stack[fA(self.pc)] = self.stack[fE(self.pc)];
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .move_far => {
            self.stack[fE(self.pc)] = self.stack[fA(self.pc)];
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .jump => {
            if (try self.maybeAutoSuspend(fDS(self.pc) <= 0)) |s| return s;
            self.pc += asOffset(fDS(self.pc));
            continue :sw self.nextOp();
        },

        .jump_if => {
            if (repr.truthy(self.stack[fA(self.pc)])) {
                if (try self.maybeAutoSuspend(fES(self.pc) <= 0)) |s| return s;
                self.pc += asOffset(fES(self.pc));
            } else {
                self.pc += 1;
            }
            continue :sw self.nextOp();
        },

        .jump_if_not => {
            if (repr.truthy(self.stack[fA(self.pc)])) {
                self.pc += 1;
            } else {
                if (try self.maybeAutoSuspend(fES(self.pc) <= 0)) |s| return s;
                self.pc += asOffset(fES(self.pc));
            }
            continue :sw self.nextOp();
        },

        .jump_if_nil => {
            if (repr.checkType(self.stack[fA(self.pc)], repr.Tag.nil)) {
                if (try self.maybeAutoSuspend(fES(self.pc) <= 0)) |s| return s;
                self.pc += asOffset(fES(self.pc));
            } else {
                self.pc += 1;
            }
            continue :sw self.nextOp();
        },

        .jump_if_not_nil => {
            if (repr.checkType(self.stack[fA(self.pc)], repr.Tag.nil)) {
                self.pc += 1;
            } else {
                if (try self.maybeAutoSuspend(fES(self.pc) <= 0)) |s| return s;
                self.pc += asOffset(fES(self.pc));
            }
            continue :sw self.nextOp();
        },

        .less_than => {
            if (try self.compop(.lt)) |s| return s;
            continue :sw self.nextOp();
        },
        .less_than_equal => {
            if (try self.compop(.le)) |s| return s;
            continue :sw self.nextOp();
        },
        .less_than_immediate => {
            if (try self.compopImmediate(.lt)) |s| return s;
            continue :sw self.nextOp();
        },
        .greater_than => {
            if (try self.compop(.gt)) |s| return s;
            continue :sw self.nextOp();
        },
        .greater_than_equal => {
            if (try self.compop(.ge)) |s| return s;
            continue :sw self.nextOp();
        },
        .greater_than_immediate => {
            if (try self.compopImmediate(.gt)) |s| return s;
            continue :sw self.nextOp();
        },

        .equals => {
            if (try self.equals(false)) |s| return s;
            continue :sw self.nextOp();
        },
        .not_equals => {
            if (try self.equals(true)) |s| return s;
            continue :sw self.nextOp();
        },

        .equals_immediate => {
            const x = self.stack[fB(self.pc)];
            const eq = repr.checkType(x, .number) and wrap.toNumber(x) == @as(f64, @floatFromInt(fCS(self.pc)));
            self.stack[fA(self.pc)] = wrap.fromBoolean(eq);
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .not_equals_immediate => {
            const x = self.stack[fB(self.pc)];
            const ne = !repr.checkType(x, .number) or wrap.toNumber(x) != @as(f64, @floatFromInt(fCS(self.pc)));
            self.stack[fA(self.pc)] = wrap.fromBoolean(ne);
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .compare => {
            self.commit();
            const a = wrap.fromInteger(order.compare(self.stack[fB(self.pc)], self.stack[fC(self.pc)]));
            self.reload();
            self.stack[fA(self.pc)] = a;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .next => {
            self.commit();
            const v = try access.nextImpl(self.stack[fB(self.pc)], self.stack[fC(self.pc)], true);
            self.restore();
            self.stack[fA(self.pc)] = v;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .load_nil => {
            self.stack[fD(self.pc)] = wrap.fromNil();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .load_true => {
            self.stack[fD(self.pc)] = wrap.fromTrue();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .load_false => {
            self.stack[fD(self.pc)] = wrap.fromFalse();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .load_integer => {
            self.stack[fA(self.pc)] = wrap.fromInteger(fES(self.pc));
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .load_constant => {
            const cindex: i32 = @intCast(fE(self.pc));
            if (try self.assert(cindex < self.func.def.?.constants_length, "invalid constant")) |s| return s;
            self.stack[fA(self.pc)] = self.func.def.?.constantValues()[utils.asSize(cindex)];
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .load_self => {
            self.stack[fD(self.pc)] = wrap.fromFunction(self.func);
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .load_upvalue => {
            if (try self.upvalue(false)) |s| return s;
            continue :sw self.nextOp();
        },
        .set_upvalue => {
            if (try self.upvalue(true)) |s| return s;
            continue :sw self.nextOp();
        },

        .closure => {
            const defindex: i32 = @intCast(fE(self.pc));
            if (try self.assert(defindex < self.func.def.?.defs_length, "invalid funcdef")) |s| return s;
            const fd = self.func.def.?.subdefs()[utils.asSize(defindex)];
            const elen = fd.environments_length;
            const fn_ptr = gc_alloc.gcallocWithPayload(
                functions.Function,
                .function,
                @as(usize, @intCast(elen)) *% @sizeOf(*functions.FuncEnv),
            );
            fn_ptr.def = fd;
            // `environmentIndices()` is `elen` long by construction, so this
            // walks exactly the range the counter did.
            for (fd.environmentIndices(), 0..) |inherit, i| {
                if (inherit == -1 or inherit >= self.func.def.?.environments_length) {
                    const frame = stackFrame(self.stack);
                    if (frame.env == null) {
                        // Lazy capture of current stack frame
                        const env = gc_alloc.gcalloc(functions.FuncEnv, .funcenv);
                        env.offset = fiber.frame;
                        env.as.fiber = fiber;
                        env.length = self.func.def.?.slotcount;
                        frame.env = env;
                    }
                    funcEnvSlot(fn_ptr, @intCast(i)).* = frame.env;
                } else {
                    funcEnvSlot(fn_ptr, @intCast(i)).* = funcEnvSlot(self.func, inherit).*;
                }
            }
            self.stack[fA(self.pc)] = wrap.fromFunction(fn_ptr);
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .push => {
            try fibers.push(fiber, self.stack[fD(self.pc)]);
            self.reload();
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .push_2 => {
            try fibers.push2(fiber, self.stack[fA(self.pc)], self.stack[fE(self.pc)]);
            self.reload();
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .push_3 => {
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

        .push_array => {
            // Committed the way `.length` commits: `chunks` reads an
            // abstract's `length` callback, which may raise.
            self.commit();
            const spliced = self.stack[fD(self.pc)];
            var source = try args_core.chunks(spliced);
            if (source) |*it| {
                try fibers.pushChunks(fiber, it);
            } else {
                return try self.raisef("expected %K, got %v", .{
                    repr.TagSet.indexed,
                    spliced,
                });
            }
            self.reload();
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .call => {
            if (try self.maybeAutoSuspend(true)) |s| return s;
            var callee = self.stack[fE(self.pc)];
            if (fiber.stacktop > fiber.maxstack) return try self.throw("stack overflow");
            if (repr.checkType(callee, repr.Tag.keyword)) {
                self.commit();
                callee = try vm_calls.resolveMethod(callee, fiber);
            }
            if (repr.checkType(callee, repr.Tag.function)) {
                self.func = wrap.toFunction(callee);
                // The commit goes before the trace and `stack` is reloaded
                // after it. Tracing renders through `(dyn :err)`, which may be
                // a Janet function, which runs on this fiber and may grow its
                // stack, and `commit` writes the program counter through
                // `self.stack`. Committing after the trace writes it where the
                // stack used to be, so the frame keeps the program counter of
                // the instruction now executing and re-runs the call when it
                // is next resumed from.
                self.commit();
                if (functions.isTraced(self.func)) {
                    try traceFiber(self.func, fiber.stacktop - fiber.stackstart, fiber);
                    self.reload();
                }
                fibers.funcframe(fiber, self.func) catch {
                    const n = fiber.stacktop - fiber.stackstart;
                    return try self.raisef("%v called with %d argument%s, expected %d", .{
                        callee,
                        n,
                        if (n == 1) @as([*]const u8, "") else @as([*]const u8, "s"),
                        self.func.def.?.arity,
                    });
                };
                self.reload();
                self.pc = self.func.def.?.bytecode.?;
                self.maybeCollect();
                continue :sw self.nextOp();
            } else if (repr.checkType(callee, repr.Tag.cfunction)) {
                self.commit();
                const argc = fiber.stacktop - fiber.stackstart;
                fibers.cframe(fiber, wrap.toCfunction(callee));
                const v = try raise.cfunction(wrap.toCfunction(callee))(
                    (fiber.data.? + utils.asSize(fiber.frame))[0..@intCast(argc)],
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
                // Reloaded for the same reason the cfunction branch above
                // reloads: an abstract type's `call` or `get` callback may
                // re-enter the interpreter and grow the fiber, and `stack` is
                // a pointer into what it grew out of.
                self.reload();
                self.stack[fA(self.pc)] = v;
                self.pc += 1;
                continue :sw self.nextOp();
            }
        },

        .tailcall => {
            if (try self.maybeAutoSuspend(true)) |s| return s;
            var callee = self.stack[fD(self.pc)];
            if (fiber.stacktop > fiber.maxstack) return try self.throw("stack overflow");
            if (repr.checkType(callee, repr.Tag.keyword)) {
                self.commit();
                callee = try vm_calls.resolveMethod(callee, fiber);
            }
            if (repr.checkType(callee, repr.Tag.function)) {
                self.func = wrap.toFunction(callee);
                // As in `.call` above: the trace may grow the fiber's stack,
                // so `stack` is reloaded before anything reads it again. There
                // is no commit here, because a tail call replaces the frame.
                if (functions.isTraced(self.func)) {
                    try traceFiber(self.func, fiber.stacktop - fiber.stackstart, fiber);
                    self.reload();
                }
                fibers.funcframeTail(fiber, self.func) catch {
                    stackFrame(fiber.data.? + utils.asSize(fiber.frame)).pc = .{ .bytecode = self.pc };
                    const n = fiber.stacktop - fiber.stackstart;
                    return try self.raisef("%v called with %d argument%s, expected %d", .{
                        callee,
                        n,
                        if (n == 1) @as([*]const u8, "") else @as([*]const u8, "s"),
                        self.func.def.?.arity,
                    });
                };
                self.reload();
                self.pc = self.func.def.?.bytecode.?;
                self.maybeCollect();
                continue :sw self.nextOp();
            }
            const entrance_frame = stackFrame(self.stack).flags.entrance;
            self.commit();
            var retreg: repr.Value = undefined;
            if (repr.checkType(callee, repr.Tag.cfunction)) {
                const argc = fiber.stacktop - fiber.stackstart;
                fibers.cframe(fiber, wrap.toCfunction(callee));
                retreg = try raise.cfunction(wrap.toCfunction(callee))(
                    (fiber.data.? + utils.asSize(fiber.frame))[0..@intCast(argc)],
                );
                fibers.popframe(fiber);
            } else {
                retreg = try vm_calls.callNonfn(fiber, callee);
            }
            fibers.popframe(fiber);
            if (entrance_frame) return self.retNoRestore(abi.Signal.ok, retreg);
            self.restore();
            self.stack[fA(self.pc)] = retreg;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .@"resume" => {
            if (try self.maybeAutoSuspend(true)) |s| return s;
            if (try self.assertType(self.stack[fB(self.pc)], repr.Tag.fiber)) |s| return s;
            const child = wrap.toFiber(self.stack[fB(self.pc)]);
            if (vm_entry.checkCanResume(self.vm, child, false)) |refusal| {
                self.commit();
                return try self.raisev(refusal.value);
            }
            fiber.child = child;
            const resumed = vm_entry.continueNoCheck(self.vm, child, self.stack[fC(self.pc)]);
            const retreg = resumed.value;
            const sig = resumed.signal;
            self.reload();
            if (sig != abi.Signal.ok and !child.flags.traps.has(sig)) {
                return self.ret(sig, retreg);
            }
            fiber.child = null;
            self.stack[fA(self.pc)] = retreg;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .signal => {
            // The instruction's C field is a raw number, so it is clamped
            // into the vocabulary before it becomes one, and the bounds are
            // contract. `Signal.fromWire` is that clamp, shared with the
            // published entry points so the rule is written once.
            const s: i32 = @intCast(fC(self.pc));
            const raw: c_uint = if (s < 0) 0 else @intCast(s);
            return self.ret(abi.Signal.fromWire(raw), self.stack[fB(self.pc)]);
        },

        .propagate => {
            const fv = self.stack[fC(self.pc)];
            if (try self.assertType(fv, repr.Tag.fiber)) |s| return s;
            const f = wrap.toFiber(fv);
            const sub_status = fibers.status(f);
            if (@intFromEnum(sub_status) > @intFromEnum(fibers.FiberStatus.user9)) {
                self.commit();
                return try self.raisef("cannot propagate from fiber with status :%s", .{
                    utils.statusNames[@intFromEnum(sub_status)],
                });
            }
            fiber.child = f;
            // Guarded above to be one of the fourteen the two vocabularies
            // share.
            return self.ret(@enumFromInt(@intFromEnum(sub_status)), self.stack[fB(self.pc)]);
        },

        .cancel => {
            if (try self.assertType(self.stack[fB(self.pc)], repr.Tag.fiber)) |s| return s;
            const child = wrap.toFiber(self.stack[fB(self.pc)]);
            if (vm_entry.checkCanResume(self.vm, child, true)) |refusal| {
                self.commit();
                return try self.raisev(refusal.value);
            }
            fiber.child = child;
            const resumed = vm_entry.continueSignal(child, self.stack[fC(self.pc)], abi.Signal.@"error");
            const retreg = resumed.value;
            const sig = resumed.signal;
            if (sig != abi.Signal.ok and !child.flags.traps.has(sig)) {
                return self.ret(sig, retreg);
            }
            fiber.child = null;
            self.reload();
            self.stack[fA(self.pc)] = retreg;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .put => {
            self.commit();
            fiber.flags.resume_no_useval = true;
            try access.put(
                self.stack[fA(self.pc)],
                self.stack[fB(self.pc)],
                self.stack[fC(self.pc)],
            );
            self.reload();
            fiber.flags.resume_no_useval = false;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .put_index => {
            self.commit();
            fiber.flags.resume_no_useval = true;
            try access.putIndex(
                self.stack[fA(self.pc)],
                @as(i32, @intCast(fC(self.pc))),
                self.stack[fB(self.pc)],
            );
            self.reload();
            fiber.flags.resume_no_useval = false;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .in => {
            self.commit();
            const v = try access.in(self.stack[fB(self.pc)], self.stack[fC(self.pc)]);
            self.reload();
            self.stack[fA(self.pc)] = v;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .get => {
            self.commit();
            // A missing key gives back nil rather than raising, but a table's
            // prototype chain, an abstract type's `get` and a `next` callback
            // are all reachable from here, and any of those may, so the `try`
            // is not decoration.
            const v = try access.get(self.stack[fB(self.pc)], self.stack[fC(self.pc)]);
            self.reload();
            self.stack[fA(self.pc)] = v;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .get_index => {
            self.commit();
            const v = try access.getIndex(self.stack[fB(self.pc)], @as(i32, @intCast(fC(self.pc))));
            self.reload();
            self.stack[fA(self.pc)] = v;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .length => {
            self.commit();
            const v = try access.lengthv(self.stack[fE(self.pc)]);
            self.reload();
            self.stack[fA(self.pc)] = v;
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .make_array => {
            const count = fiber.stacktop - fiber.stackstart;
            const mem = fiber.data.? + utils.asSize(fiber.stackstart);
            self.stack[fD(self.pc)] = wrap.fromArray(arrays.newFrom(mem[0..utils.asSize(count)]));
            fiber.stacktop = fiber.stackstart;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .make_tuple, .make_bracket_tuple => |op| {
            const count = fiber.stacktop - fiber.stackstart;
            const mem = fiber.data.? + utils.asSize(fiber.stackstart);
            const tup = tuples.newFrom(mem[0..utils.asSize(count)]);
            if (op == constants.Opcode.make_bracket_tuple) {
                tuples.setBracketed(tuples.head(tup));
            }
            self.stack[fD(self.pc)] = wrap.fromTuple(tup);
            fiber.stacktop = fiber.stackstart;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .make_table => {
            const count = fiber.stacktop - fiber.stackstart;
            const mem = fiber.data.? + utils.asSize(fiber.stackstart);
            if (count & 1 != 0) {
                self.commit();
                return try self.raisef("expected even number of arguments to table constructor, got %d", .{count});
            }
            const table = tables.new(@intCast(@divTrunc(count, 2)));
            vm_calls.fillTable(table, mem, count);
            self.stack[fD(self.pc)] = wrap.fromTable(table);
            fiber.stacktop = fiber.stackstart;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .make_struct => {
            const count = fiber.stacktop - fiber.stackstart;
            const mem = fiber.data.? + utils.asSize(fiber.stackstart);
            if (count & 1 != 0) {
                self.commit();
                return try self.raisef("expected even number of arguments to struct constructor, got %d", .{count});
            }
            const st = structs.begin(@intCast(@divTrunc(count, 2)));
            vm_calls.fillStruct(st, mem, count);
            self.stack[fD(self.pc)] = wrap.fromStruct(structs.end(st));
            fiber.stacktop = fiber.stackstart;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .make_string => {
            const count = fiber.stacktop - fiber.stackstart;
            const mem = fiber.data.? + utils.asSize(fiber.stackstart);
            var buffer: buffers.Buffer = undefined;
            _ = buffers.init(&buffer, 10 *% utils.asSize(count));
            // `defer`, because the fill raises: an abstract type's `tostring`
            // can, and `buffers.ensure` does past `INT32_MAX`. The storage is
            // `utils.allocMany`'s and off the collector's list, so nothing but
            // this line can free it and nothing else refers to the pointer.
            defer buffers.deinit(&buffer);
            try vm_calls.fillString(&buffer, mem[0..utils.asSize(count)]);
            self.stack[fD(self.pc)] = value.fromBytes(buffer.slice(), .string);
            fiber.stacktop = fiber.stackstart;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        .make_buffer => {
            const count = fiber.stacktop - fiber.stackstart;
            const mem = fiber.data.? + utils.asSize(fiber.stackstart);
            const buffer = buffers.new(10 *% utils.asSize(count));
            try vm_calls.fillString(buffer, mem[0..utils.asSize(count)]);
            self.stack[fD(self.pc)] = wrap.fromBuffer(buffer);
            fiber.stacktop = fiber.stackstart;
            self.maybeCollect();
            self.pc += 1;
            continue :sw self.nextOp();
        },

        // An opcode with no arm in the table, which is how a breakpoint is set:
        // bit 7 of the instruction word takes it out of the table.
        else => {
            fiber.flags.breakpoint = true;
            fiber.flags.resume_no_useval = true;
            fiber.flags.resume_no_skip = true;
            return self.ret(abi.Signal.debug, wrap.fromNil());
        },
    }
}

/// Prints a traced call and its arguments to `(dyn :err)`, taking an argv the
/// caller owns.
///
/// There are two entry points because of the stack. Printing can resize a
/// fiber's stack, so `fiber.data + fiber.stackstart` has to be recomputed for
/// every element and a pointer handed across would freeze at the first.
/// `traceFiber` recomputes; this one takes an argv that nothing here can move.
///
/// Both raise. `dynprintf` can, because `(dyn :err)` may be a Janet function,
/// and both callers, `runVm` and `vm/entry.call`, are raising already, so the
/// raise a traced call's rendering produces is returned rather than reported.
pub fn traceArgv(func: *functions.Function, argv: []const repr.Value) raise.Error!void {
    try traceHeader(func);
    for (argv) |a| try eprintf(" %p", .{a});
    try eprintf(")\n", .{});
}

/// Prints a traced call and its arguments to `(dyn :err)`, reading the
/// arguments off the fiber stack. See `traceArgv`.
pub fn traceFiber(func: *functions.Function, argc: i32, fiber: *fibers.Fiber) raise.Error!void {
    try traceHeader(func);
    // `argv` is re-derived per argument on purpose: `eprintf` reaches
    // `(dyn :err)`, which may be a Janet function, and running one can grow the
    // fiber's stack out from under a slice taken once.
    for (0..@as(usize, @intCast(argc))) |i| {
        const argv = fiber.data.? + @as(usize, @intCast(fiber.stackstart));
        try eprintf(" %p", .{argv[i]});
    }
    try eprintf(")\n", .{});
}

/// The operator fallback for a one-operand opcode whose operand is not a
/// number. `.bnot` is the only one that reaches it.
pub fn unaryCall(method: [*:0]const u8, arg: repr.Value) raise.Error!repr.Value {
    const m = try methodLookup(arg, method);
    if (isNil(m)) {
        return pp_format.panicf("could not find method :%s for %v", .{ method, arg });
    }
    var argv = [_]repr.Value{arg};
    return methodInvoke(m, argv[0..1]);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Moves the program counter by a signed instruction field. Zig's pointer
/// arithmetic takes an unsigned offset, so the two's complement is taken
/// explicitly and the wrap is what a backwards jump relies on.
inline fn asOffset(n: i32) usize {
    return @bitCast(@as(isize, n));
}

/// Whether `dval` is exactly representable in `T`.
///
/// A range check first, so that the round trip through the integer type, which
/// is what rejects a fractional value, is always in range and Zig's conversion
/// safety check cannot fire. NaN fails the first comparison.
inline fn checkRange(comptime T: type, dval: f64) bool {
    const lo: f64 = @floatFromInt(std.math.minInt(T));
    const hi: f64 = @floatFromInt(std.math.maxInt(T));
    if (!(dval >= lo and dval <= hi)) return false;
    const truncated: T = @intFromFloat(dval);
    const back: f64 = @floatFromInt(truncated);
    return dval == back;
}

/// Prints to `(dyn :err)`, falling back to the standard error handle.
inline fn eprintf(comptime format: [:0]const u8, args: anytype) raise.Error!void {
    return pp_format.dynprintf("err", stdio.err(), format, args);
}

/// The unsigned fields of one instruction word:
///
///     CC | BB | AA | OP
///     DD | DD | DD | OP
///     EE | EE | AA | OP
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

/// Signed interpretations of the same fields, as an arithmetic right shift of
/// the word reinterpreted as a signed 32-bit integer.
inline fn fCS(pc: [*]const u32) i32 {
    return @as(i32, @bitCast(pc[0])) >> 24;
}
inline fn fDS(pc: [*]const u32) i32 {
    return @as(i32, @bitCast(pc[0])) >> 8;
}
inline fn fES(pc: [*]const u32) i32 {
    return @as(i32, @bitCast(pc[0])) >> 16;
}

/// `func.envs[i]` as an lvalue.
inline fn funcEnvSlot(func: *functions.Function, i: i32) *?*functions.FuncEnv {
    return &functions.envsOf(func)[@intCast(i)];
}

/// A bitwise result back to an `f64`, over `i32` or `u32`. Named so that the
/// `u32` case, the only one whose result can exceed an `i32`'s range,
/// cannot be written the other way by accident.
inline fn intToDouble(comptime T: type, x: T) f64 {
    return @floatFromInt(x);
}

/// The arity check and indexed access shared by `methodInvoke`'s last two
/// arms. `method_is_ds` picks which operand is the data structure, which is
/// the only thing that differs between them.
///
/// `argv` is passed rather than `argv[0]`, and that ordering is load-bearing:
/// the arity check runs first, so a zero-argument call never touches the slot.
/// Reading it eagerly would be a read of whatever the previous frame left
/// there.
inline fn invokeIndexed(method: repr.Value, argv: []repr.Value, method_is_ds: bool) raise.Error!repr.Value {
    if (argv.len != 1) {
        return pp_format.panicf("%v called with %d arguments, possibly expected 1", .{ method, @as(i64, @intCast(argv.len)) });
    }
    return if (method_is_ds) try access.in(method, argv[0]) else try access.in(argv[0], method);
}

/// Whether `x` is nil.
inline fn isNil(x: repr.Value) bool {
    return repr.checkType(x, repr.Tag.nil);
}

/// Kept as a Zig-private inline rather than a symbol: it is `access.get` with
/// its operands swapped, and both of its callers are here.
///
/// It is raising, and it has to be. Every caller in the chain above is
/// raise-capable, and an abstract's `get` callback can refuse, so a
/// reporting form here would leave a report nobody consumes: the binop
/// fallback looks `:r+` up on the right operand and that lookup is this
/// function, which is what makes `(+ (int/s64 1) {})` a catchable error rather
/// than a dead process.
inline fn methodToFun(method: repr.Value, obj: repr.Value) raise.Error!repr.Value {
    return access.get(obj, method);
}

/// The frame that sits immediately below `values`.
inline fn stackFrame(values: [*]repr.Value) *vm_state.StackFrame {
    return @ptrCast(@alignCast(values - frame_size));
}

/// Prints the opening of a traced call: the function's name where it has one,
/// and its rendering where it does not.
fn traceHeader(func: *functions.Function) raise.Error!void {
    if (func.def.?.name != null) {
        try eprintf("trace (%S", .{func.def.?.name});
    } else {
        try eprintf("trace (%p", .{wrap.fromFunction(func)});
    }
}
