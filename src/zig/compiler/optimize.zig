//! The three bytecode-to-bytecode passes the compiler runs after emission.
//!
//! Three files once, one per pass, split along the C originals rather than
//! along the subject: constant folding over the builtin table, `mov`
//! elimination and `noop` removal are three walks over the same `JanetFuncDef`
//! bytecode, run in sequence by one caller. None has a name Janet publishes
//! and none exists because a platform differs, so they are one file, and the
//! sequence is visible in one place.
//!
//! **The merge forced one deduplication and it was a real duplicate.**
//! `movopt.zig` and `remove_noops.zig` each carried
//!
//!     fn opcode(instruction: u32) u32 {
//!         return instruction & 0x7f;
//!     }
//!
//! byte for byte, because neither could see the other. Zig rejects both in one
//! file, so there is one now -- **as `opcodeOf`**, because hoisting it to
//! container level made it shadow four parameters named `opcode` in the
//! constant-folding half, which is a hard error. A private helper's name is
//! local to its file until the file grows.
//!
//! Nothing else collided: the rest of the overlap between the three was import
//! aliases, which dedupe into the block below.

const std = @import("std");

const repr = @import("repr");
const constants = @import("constants");

const compiler_primitives = @import("../compiler.zig");
const emit_core = @import("emit.zig");
const regalloc = @import("regalloc.zig");
const args_core = @import("../args.zig");
const fatal = @import("../fatal.zig");
const gc_alloc = @import("../gc.zig");
const utils = @import("../utils.zig");
const wrap = @import("../value/helpers/wrap.zig");
const abi = @import("abi");
const functions = @import("../value/functions.zig");

/// The opcode an instruction word carries. Bit 7 is the breakpoint bit and is
/// masked off here as it is in `runVm`, so this answers the operation the
/// optimizer is reasoning about rather than whether a debugger stopped on it.
fn opcodeOf(instruction: u32) constants.Opcode {
    return @enumFromInt(@as(u8, @intCast(instruction & 0x7f)));
}

// ---------------------------------------------------------------------------
// Constant folding over the builtin table.
// ---------------------------------------------------------------------------

/// The constants this file builds slots out of.
inline fn wrapNil() repr.Value {
    return wrap.fromNil();
}

inline fn wrapBoolean(val: bool) repr.Value {
    return wrap.fromBoolean(val);
}

fn argumentCount(args: []const compiler_primitives.JanetSlot) i32 {
    return @intCast(args.len);
}

fn nilSlot() compiler_primitives.JanetSlot {
    return compiler_primitives.cslot(wrapNil());
}

fn integerSlot(val: i32) compiler_primitives.JanetSlot {
    return compiler_primitives.cslot(wrap.fromInteger(val));
}

fn arity1or2(_: compiler_primitives.JanetFopts, args: []const compiler_primitives.JanetSlot) bool {
    const count = argumentCount(args);
    return count == 1 or count == 2;
}

fn arity2or3(_: compiler_primitives.JanetFopts, args: []const compiler_primitives.JanetSlot) bool {
    const count = argumentCount(args);
    return count == 2 or count == 3;
}

fn fixarity1(_: compiler_primitives.JanetFopts, args: []const compiler_primitives.JanetSlot) bool {
    return argumentCount(args) == 1;
}

fn maxarity1(_: compiler_primitives.JanetFopts, args: []const compiler_primitives.JanetSlot) bool {
    return argumentCount(args) <= 1;
}

fn minarity2(_: compiler_primitives.JanetFopts, args: []const compiler_primitives.JanetSlot) bool {
    return argumentCount(args) >= 2;
}

fn fixarity2(_: compiler_primitives.JanetFopts, args: []const compiler_primitives.JanetSlot) bool {
    return argumentCount(args) == 2;
}

fn fixarity3(_: compiler_primitives.JanetFopts, args: []const compiler_primitives.JanetSlot) bool {
    return argumentCount(args) == 3;
}

fn genericSS(options: compiler_primitives.JanetFopts, opcode: constants.Opcode, source: compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    const target = compiler_primitives.gettarget(options);
    _ = emit_core.emitSs(options.compiler, opcode, target, source, 1);
    return target;
}

fn genericSSI(options: compiler_primitives.JanetFopts, opcode: constants.Opcode, source: compiler_primitives.JanetSlot, immediate: i8) compiler_primitives.JanetSlot {
    const target = compiler_primitives.gettarget(options);
    _ = emit_core.emitSsi(options.compiler, opcode, target, source, immediate, 1);
    return target;
}

fn opFunction(options: compiler_primitives.JanetFopts, args: []const compiler_primitives.JanetSlot, opcode: constants.Opcode, default_value: repr.Value) compiler_primitives.JanetSlot {
    const target = compiler_primitives.gettarget(options);
    const second = if (argumentCount(args) == 1) compiler_primitives.cslot(default_value) else args[1];
    _ = emit_core.emitSss(options.compiler, opcode, target, args[0], second, 1);
    return target;
}

fn slotImmediate(slot: compiler_primitives.JanetSlot) ?i8 {
    if (!slot.flags.constant or !args_core.checkint(slot.constant)) return null;
    const integer: i32 = @intFromFloat(wrap.toNumber(slot.constant));
    if (integer < -128 or integer > 127) return null;
    return @intCast(integer);
}

fn opReduce(
    options: compiler_primitives.JanetFopts,
    args: []const compiler_primitives.JanetSlot,
    opcode: constants.Opcode,
    immediate_opcode: ?constants.Opcode,
    nullary: repr.Value,
    unary: repr.Value,
) compiler_primitives.JanetSlot {
    const count = argumentCount(args);
    if (count == 0) return compiler_primitives.cslot(nullary);
    if (count == 1) {
        const target = compiler_primitives.gettarget(options);
        if (opcode == constants.Opcode.subtract) {
            _ = emit_core.emitSsi(options.compiler, constants.Opcode.multiply_immediate, target, args[0], -1, 1);
        } else {
            _ = emit_core.emitSss(options.compiler, opcode, target, compiler_primitives.cslot(unary), args[0], 1);
        }
        return target;
    }
    const target = compiler_primitives.gettarget(options);
    if (immediate_opcode != null and slotImmediate(args[1]) != null) {
        _ = emit_core.emitSsi(options.compiler, immediate_opcode.?, target, args[0], slotImmediate(args[1]).?, 1);
    } else {
        _ = emit_core.emitSss(options.compiler, opcode, target, args[0], args[1], 1);
    }
    var index: i32 = 2;
    while (index < count) : (index += 1) {
        if (immediate_opcode != null and slotImmediate(args[@intCast(index)]) != null) {
            _ = emit_core.emitSsi(options.compiler, immediate_opcode.?, target, target, slotImmediate(args[@intCast(index)]).?, 1);
        } else {
            _ = emit_core.emitSss(options.compiler, opcode, target, target, args[@intCast(index)], 1);
        }
    }
    return target;
}

fn compareReduce(options: compiler_primitives.JanetFopts, args: []const compiler_primitives.JanetSlot, opcode: constants.Opcode, immediate_opcode: ?constants.Opcode, invert: bool) compiler_primitives.JanetSlot {
    const count = argumentCount(args);
    if (count < 2) return compiler_primitives.cslot(wrapBoolean(!invert));
    const target = compiler_primitives.gettarget(options);
    const first_instruction = options.compiler.here();
    var index: i32 = 1;
    while (index < count) : (index += 1) {
        const right = args[@intCast(index)];
        if (immediate_opcode != null and slotImmediate(right) != null) {
            _ = emit_core.emitSsi(options.compiler, immediate_opcode.?, target, args[@intCast(index - 1)], slotImmediate(right).?, 1);
        } else {
            _ = emit_core.emitSss(options.compiler, opcode, target, args[@intCast(index - 1)], right, 1);
        }
        if (index != count - 1) {
            _ = emit_core.emitSi(options.compiler, if (invert) constants.Opcode.jump_if else constants.Opcode.jump_if_not, target, 0, 1);
        }
    }
    const end = options.compiler.here();
    var instruction = first_instruction;
    while (instruction < end) : (instruction += 1) {
        const opcode_byte = opcodeOf(options.compiler.buffer.items[@intCast(instruction)]);
        if (opcode_byte == .jump_if or opcode_byte == .jump_if_not) {
            options.compiler.buffer.items[@intCast(instruction)] |= @as(u32, @intCast(end - instruction)) << 16;
        }
    }
    return target;
}

fn doPropagate(options: compiler_primitives.JanetFopts, args: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return opReduce(options, args, constants.Opcode.propagate, null, wrapNil(), wrapNil());
}

fn doError(options: compiler_primitives.JanetFopts, args: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    _ = emit_core.emitSlot(options.compiler, constants.Opcode.@"error", args[0], 0);
    return nilSlot();
}

fn doDebug(options: compiler_primitives.JanetFopts, args: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    const target = compiler_primitives.gettarget(options);
    const source = if (argumentCount(args) == 1) args[0] else nilSlot();
    _ = emit_core.emitSsu(options.compiler, constants.Opcode.signal, target, source, @intFromEnum(abi.Signal.debug), 1);
    return target;
}

fn doIn(options: compiler_primitives.JanetFopts, args: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return opReduce(options, args, constants.Opcode.in, null, wrapNil(), wrapNil());
}

fn doGet(options: compiler_primitives.JanetFopts, args: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    if (argumentCount(args) != 3) return opReduce(options, args, constants.Opcode.get, null, wrapNil(), wrapNil());
    const target = compiler_primitives.gettarget(options);
    const target_is_default = emit_core.sequal(target, args[2]);
    var default_slot = args[2];
    if (target_is_default) {
        default_slot = compiler_primitives.farslot(options.compiler) orelse nilSlot();
        emit_core.copy(options.compiler, default_slot, target);
    }
    _ = emit_core.emitSss(options.compiler, constants.Opcode.get, target, args[0], args[1], 1);
    const label = emit_core.emitSi(options.compiler, constants.Opcode.jump_if_not_nil, target, 0, 0);
    emit_core.copy(options.compiler, target, default_slot);
    if (target_is_default) compiler_primitives.freeslot(options.compiler, default_slot);
    const current = options.compiler.here();
    options.compiler.buffer.items[@intCast(label)] |= @as(u32, @intCast(current - label)) << 16;
    return target;
}

fn doPut(options: compiler_primitives.JanetFopts, args: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    const immediate = slotImmediate(args[1]);
    if (options.flags.drop) {
        if (immediate) |index| {
            _ = emit_core.emitSsi(options.compiler, constants.Opcode.put_index, args[0], args[2], index, 0);
        } else {
            _ = emit_core.emitSss(options.compiler, constants.Opcode.put, args[0], args[1], args[2], 0);
        }
        return nilSlot();
    }
    const target = compiler_primitives.gettarget(options);
    emit_core.copy(options.compiler, target, args[0]);
    if (immediate) |index| {
        _ = emit_core.emitSsi(options.compiler, constants.Opcode.put_index, target, args[2], index, 0);
    } else {
        _ = emit_core.emitSss(options.compiler, constants.Opcode.put, target, args[1], args[2], 0);
    }
    return target;
}

fn doApply(options: compiler_primitives.JanetFopts, args: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    const count = argumentCount(args);
    var index: i32 = 1;
    while (index < count - 3) : (index += 3) {
        _ = emit_core.emitSss(options.compiler, constants.Opcode.push_3, args[@intCast(index)], args[@intCast(index + 1)], args[@intCast(index + 2)], 0);
    }
    if (index == count - 3) {
        _ = emit_core.emitSs(options.compiler, constants.Opcode.push_2, args[@intCast(index)], args[@intCast(index + 1)], 0);
    } else if (index == count - 2) {
        _ = emit_core.emitSlot(options.compiler, constants.Opcode.push, args[@intCast(index)], 0);
    }
    _ = emit_core.emitSlot(options.compiler, constants.Opcode.push_array, args[@intCast(count - 1)], 0);
    if (options.flags.tail) {
        _ = emit_core.emitSlot(options.compiler, constants.Opcode.tailcall, args[0], 0);
        var target = nilSlot();
        target.flags.returned = true;
        return target;
    }
    const target = compiler_primitives.gettarget(options);
    _ = emit_core.emitSs(options.compiler, constants.Opcode.call, target, args[0], 1);
    return target;
}

fn doAdd(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return opReduce(o, a, constants.Opcode.add, constants.Opcode.add_immediate, wrap.fromInteger(0), wrap.fromInteger(0));
}
fn doSub(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return opReduce(o, a, constants.Opcode.subtract, constants.Opcode.subtract_immediate, wrap.fromInteger(0), wrap.fromInteger(0));
}
fn doMul(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return opReduce(o, a, constants.Opcode.multiply, constants.Opcode.multiply_immediate, wrap.fromInteger(1), wrap.fromInteger(1));
}
fn doDiv(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return opReduce(o, a, constants.Opcode.divide, constants.Opcode.divide_immediate, wrap.fromInteger(1), wrap.fromInteger(1));
}
fn doDivf(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return opReduce(o, a, constants.Opcode.divide_floor, null, wrap.fromInteger(1), wrap.fromInteger(1));
}
fn doModulo(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return opReduce(o, a, constants.Opcode.modulo, null, wrap.fromInteger(0), wrap.fromInteger(1));
}
fn doRemainder(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return opReduce(o, a, constants.Opcode.remainder, null, wrap.fromInteger(0), wrap.fromInteger(1));
}
fn doBand(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return opReduce(o, a, constants.Opcode.band, null, wrap.fromInteger(-1), wrap.fromInteger(-1));
}
fn doBor(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return opReduce(o, a, constants.Opcode.bor, null, wrap.fromInteger(0), wrap.fromInteger(0));
}
fn doBxor(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return opReduce(o, a, constants.Opcode.bxor, null, wrap.fromInteger(0), wrap.fromInteger(0));
}
fn doLshift(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return opReduce(o, a, constants.Opcode.shift_left, constants.Opcode.shift_left_immediate, wrap.fromInteger(1), wrap.fromInteger(1));
}
fn doRshift(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return opReduce(o, a, constants.Opcode.shift_right, constants.Opcode.shift_right_immediate, wrap.fromInteger(1), wrap.fromInteger(1));
}
fn doRshiftu(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return opReduce(o, a, constants.Opcode.shift_right_unsigned, constants.Opcode.shift_right_unsigned_immediate, wrap.fromInteger(1), wrap.fromInteger(1));
}
fn doBnot(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return genericSS(o, constants.Opcode.bnot, a[0]);
}
fn doGt(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return compareReduce(o, a, constants.Opcode.greater_than, constants.Opcode.greater_than_immediate, false);
}
fn doLt(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return compareReduce(o, a, constants.Opcode.less_than, constants.Opcode.less_than_immediate, false);
}
fn doGte(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return compareReduce(o, a, constants.Opcode.greater_than_equal, null, false);
}
fn doLte(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return compareReduce(o, a, constants.Opcode.less_than_equal, null, false);
}
fn doEq(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return compareReduce(o, a, constants.Opcode.equals, constants.Opcode.equals_immediate, false);
}
fn doNeq(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return compareReduce(o, a, constants.Opcode.not_equals, constants.Opcode.not_equals_immediate, true);
}
fn doLength(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return genericSS(o, constants.Opcode.length, a[0]);
}
fn doYield(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return genericSSI(o, constants.Opcode.signal, if (argumentCount(a) == 0) nilSlot() else a[0], 3);
}
fn doResume(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return opFunction(o, a, constants.Opcode.@"resume", wrapNil());
}
fn doCancel(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return opFunction(o, a, constants.Opcode.cancel, wrapNil());
}
fn doNext(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return opFunction(o, a, constants.Opcode.next, wrapNil());
}
fn doCmp(o: compiler_primitives.JanetFopts, a: []const compiler_primitives.JanetSlot) compiler_primitives.JanetSlot {
    return opReduce(o, a, constants.Opcode.compare, null, wrapNil(), wrapNil());
}

const optimizers = [_]compiler_primitives.JanetFunOptimizer{
    .{ .can_optimize = maxarity1, .optimize = doDebug },
    .{ .can_optimize = fixarity1, .optimize = doError },
    .{ .can_optimize = minarity2, .optimize = doApply },
    .{ .can_optimize = maxarity1, .optimize = doYield },
    .{ .can_optimize = arity1or2, .optimize = doResume },
    .{ .can_optimize = fixarity2, .optimize = doIn },
    .{ .can_optimize = fixarity3, .optimize = doPut },
    .{ .can_optimize = fixarity1, .optimize = doLength },
    .{ .can_optimize = null, .optimize = doAdd },
    .{ .can_optimize = null, .optimize = doSub },
    .{ .can_optimize = null, .optimize = doMul },
    .{ .can_optimize = null, .optimize = doDiv },
    .{ .can_optimize = null, .optimize = doBand },
    .{ .can_optimize = null, .optimize = doBor },
    .{ .can_optimize = null, .optimize = doBxor },
    .{ .can_optimize = null, .optimize = doLshift },
    .{ .can_optimize = null, .optimize = doRshift },
    .{ .can_optimize = null, .optimize = doRshiftu },
    .{ .can_optimize = fixarity1, .optimize = doBnot },
    .{ .can_optimize = null, .optimize = doGt },
    .{ .can_optimize = null, .optimize = doLt },
    .{ .can_optimize = null, .optimize = doGte },
    .{ .can_optimize = null, .optimize = doLte },
    .{ .can_optimize = null, .optimize = doEq },
    .{ .can_optimize = null, .optimize = doNeq },
    .{ .can_optimize = fixarity2, .optimize = doPropagate },
    .{ .can_optimize = arity2or3, .optimize = doGet },
    .{ .can_optimize = arity1or2, .optimize = doNext },
    .{ .can_optimize = null, .optimize = doModulo },
    .{ .can_optimize = null, .optimize = doRemainder },
    .{ .can_optimize = fixarity2, .optimize = doCmp },
    .{ .can_optimize = fixarity2, .optimize = doCancel },
    .{ .can_optimize = null, .optimize = doDivf },
};

pub fn funopt(flags: functions.FuncDefFlags) ?*const compiler_primitives.JanetFunOptimizer {
    const tag = flags.tag;
    if (tag == 0) return null;
    const index = tag - 1;
    if (index >= optimizers.len) return null;
    return &optimizers[index];
}

// ---------------------------------------------------------------------------
// `mov` elimination.
// ---------------------------------------------------------------------------

pub fn bytecodeMovopt(definition: *functions.FuncDef) void {
    var repeat = true;
    while (repeat) {
        var registers: compiler_primitives.JanetcRegisterAllocator = undefined;
        regalloc.regallocInit(&registers);
        defer regalloc.regallocDeinit(&registers);

        if (definition.closure_bitset != null) {
            for (0..@as(usize, @intCast(definition.slotcount))) |slot| {
                const index = slot >> 5;
                const bit: u5 = @intCast(slot & 31);
                if (definition.closureBits()[index] & (@as(u32, 1) << bit) != 0) {
                    regalloc.regallocTouch(&registers, @intCast(slot));
                }
            }
        }

        for (definition.instructions()) |instruction| {
            markReads(&registers, instruction);
        }

        repeat = false;
        for (definition.instructions()) |*instruction| {
            const candidate: ?i32 = switch (opcodeOf(instruction.*)) {
                constants.Opcode.load_nil,
                constants.Opcode.load_true,
                constants.Opcode.load_false,
                constants.Opcode.load_self,
                constants.Opcode.make_array,
                constants.Opcode.make_tuple,
                constants.Opcode.make_bracket_tuple,
                => fieldD(instruction.*),

                constants.Opcode.move_far => fieldE(instruction.*),

                constants.Opcode.move_near,
                constants.Opcode.get_index,
                constants.Opcode.load_integer,
                constants.Opcode.load_constant,
                constants.Opcode.load_upvalue,
                constants.Opcode.closure,
                => fieldA(instruction.*),

                else => null,
            };
            if (candidate) |written_slot| {
                if (!regalloc.regallocCheck(&registers, written_slot)) {
                    instruction.* = constants.Opcode.noop.number();
                    repeat = true;
                }
            }
        }
    }
}

fn markReads(registers: *compiler_primitives.JanetcRegisterAllocator, instruction: u32) void {
    switch (opcodeOf(instruction)) {
        constants.Opcode.jump,
        constants.Opcode.noop,
        constants.Opcode.return_nil,
        constants.Opcode.load_integer,
        constants.Opcode.load_constant,
        constants.Opcode.load_upvalue,
        constants.Opcode.closure,
        constants.Opcode.load_nil,
        constants.Opcode.load_true,
        constants.Opcode.load_false,
        constants.Opcode.load_self,
        => {},

        constants.Opcode.make_array,
        constants.Opcode.make_buffer,
        constants.Opcode.make_string,
        constants.Opcode.make_struct,
        constants.Opcode.make_table,
        constants.Opcode.make_tuple,
        constants.Opcode.make_bracket_tuple,
        constants.Opcode.@"return",
        constants.Opcode.push,
        constants.Opcode.push_array,
        constants.Opcode.tailcall,
        => touch(registers, fieldD(instruction)),

        constants.Opcode.@"error",
        constants.Opcode.typecheck,
        constants.Opcode.jump_if,
        constants.Opcode.jump_if_not,
        constants.Opcode.jump_if_nil,
        constants.Opcode.jump_if_not_nil,
        constants.Opcode.set_upvalue,
        constants.Opcode.move_far,
        => touch(registers, fieldA(instruction)),

        constants.Opcode.signal,
        constants.Opcode.add_immediate,
        constants.Opcode.subtract_immediate,
        constants.Opcode.multiply_immediate,
        constants.Opcode.divide_immediate,
        constants.Opcode.shift_left_immediate,
        constants.Opcode.shift_right_immediate,
        constants.Opcode.shift_right_unsigned_immediate,
        constants.Opcode.greater_than_immediate,
        constants.Opcode.less_than_immediate,
        constants.Opcode.equals_immediate,
        constants.Opcode.not_equals_immediate,
        constants.Opcode.get_index,
        => touch(registers, fieldB(instruction)),

        constants.Opcode.move_near,
        constants.Opcode.length,
        constants.Opcode.bnot,
        constants.Opcode.call,
        => touch(registers, fieldE(instruction)),

        constants.Opcode.put_index => {
            touch(registers, fieldA(instruction));
            touch(registers, fieldB(instruction));
        },

        constants.Opcode.push_2 => {
            touch(registers, fieldA(instruction));
            touch(registers, fieldE(instruction));
        },

        constants.Opcode.propagate,
        constants.Opcode.band,
        constants.Opcode.bor,
        constants.Opcode.bxor,
        constants.Opcode.add,
        constants.Opcode.subtract,
        constants.Opcode.multiply,
        constants.Opcode.divide,
        constants.Opcode.divide_floor,
        constants.Opcode.modulo,
        constants.Opcode.remainder,
        constants.Opcode.shift_left,
        constants.Opcode.shift_right,
        constants.Opcode.shift_right_unsigned,
        constants.Opcode.greater_than,
        constants.Opcode.less_than,
        constants.Opcode.equals,
        constants.Opcode.compare,
        constants.Opcode.in,
        constants.Opcode.get,
        constants.Opcode.greater_than_equal,
        constants.Opcode.less_than_equal,
        constants.Opcode.not_equals,
        constants.Opcode.cancel,
        constants.Opcode.@"resume",
        constants.Opcode.next,
        => {
            touch(registers, fieldB(instruction));
            touch(registers, fieldC(instruction));
        },

        constants.Opcode.put, constants.Opcode.push_3 => {
            touch(registers, fieldA(instruction));
            touch(registers, fieldB(instruction));
            touch(registers, fieldC(instruction));
        },

        else => fatal.fatal("unhandled instruction"),
    }
}

fn touch(registers: *compiler_primitives.JanetcRegisterAllocator, slot: i32) void {
    regalloc.regallocTouch(registers, slot);
}

fn fieldA(instruction: u32) i32 {
    return @intCast((instruction >> 8) & 0xff);
}

fn fieldB(instruction: u32) i32 {
    return @intCast((instruction >> 16) & 0xff);
}

fn fieldC(instruction: u32) i32 {
    return @intCast(instruction >> 24);
}

fn fieldD(instruction: u32) i32 {
    return @intCast(instruction >> 8);
}

fn fieldE(instruction: u32) i32 {
    return @intCast(instruction >> 16);
}

// ---------------------------------------------------------------------------
// `noop` removal.
// ---------------------------------------------------------------------------

pub fn bytecodeRemoveNoops(definition: *functions.FuncDef) void {
    const old_length = definition.bytecode_length;
    const map_length: usize = @intCast(old_length + 1);
    const map_size = map_length * @sizeOf(u32);
    const pc_map: [*]u32 = @ptrCast(@alignCast(gc_alloc.smalloc(map_size)));
    defer gc_alloc.sfree(pc_map);

    var new_length: u32 = 0;
    for (definition.instructions()[0..@intCast(old_length)], 0..) |instruction, index| {
        pc_map[index] = new_length;
        if (opcodeOf(instruction) != constants.Opcode.noop) new_length += 1;
    }
    pc_map[@intCast(old_length)] = new_length;

    // Both counters are positions in the bytecode array. The jump arithmetic
    // inside stays signed -- an encoded offset is `target - here` and may be
    // negative -- so `here` is where the two meet.
    var destination_index: usize = 0;
    for (0..@as(usize, @intCast(old_length))) |source_index| {
        var instruction = definition.instructions()[source_index];
        const shift: ?u5 = switch (opcodeOf(instruction)) {
            constants.Opcode.noop => continue,
            constants.Opcode.jump => 8,
            constants.Opcode.jump_if, constants.Opcode.jump_if_nil, constants.Opcode.jump_if_not, constants.Opcode.jump_if_not_nil => 16,
            else => null,
        };
        if (shift) |field_shift| {
            const here: i32 = @intCast(source_index);
            const old_target = here + signedField(instruction, field_shift);
            if (old_target < 0 or old_target >= old_length) fatal.fatal("bounds");
            const new_target: i32 = @intCast(pc_map[@intCast(old_target)]);
            const adjustment = new_target - old_target + (here - @as(i32, @intCast(destination_index)));
            instruction +%= @as(u32, @bitCast(adjustment)) << field_shift;
        }
        definition.instructions()[destination_index] = instruction;
        if (definition.sourcemap != null) {
            definition.sourceMappings()[destination_index] = definition.sourceMappings()[source_index];
        }
        destination_index += 1;
    }

    if (definition.symbolmap_length > 0) {
        for (definition.symbols()) |*symbol| {
            if (symbol.birth_pc < std.math.maxInt(u32)) {
                symbol.birth_pc = pc_map[symbol.birth_pc];
                symbol.death_pc = pc_map[symbol.death_pc];
            }
        }
    }

    definition.bytecode_length = @intCast(new_length);
    const resized = utils.realloc(definition.bytecode, @as(usize, new_length) * @sizeOf(u32));
    definition.bytecode = @ptrCast(@alignCast(resized));
}

fn signedField(instruction: u32, shift: u5) i32 {
    return @as(i32, @bitCast(instruction)) >> shift;
}
