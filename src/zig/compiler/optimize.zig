//! The three bytecode-to-bytecode passes the compiler runs after emission.
//!
//! Three files until Phase 12 increment 6f, one per pass, and the split was
//! `compile.c`'s rather than the subject's: constant folding over the builtin
//! table, `mov` elimination, and `noop` removal are three walks over the same
//! `JanetFuncDef` bytecode, run in sequence by one caller. `port/TREE.md`'s
//! heuristic puts them together -- no name Janet publishes, no platform
//! difference -- and the merge is what makes the sequence visible in one place.
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

const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");

const compiler_primitives = @import("../compiler.zig");
const emit_core = @import("emit.zig");
const regalloc = @import("regalloc.zig");
const args_core = @import("../args.zig");
const fatal = @import("../fatal.zig");
const gc_alloc = @import("../gc.zig");
const utils = @import("../utils.zig");
const wrap = @import("../value/helpers/wrap.zig");

/// The instruction's opcode. `movopt.zig` and `remove_noops.zig` both had this
/// and `builtin_optimizers.zig` did not need it; see the header.
fn opcodeOf(instruction: u32) u32 {
    return instruction & 0x7f;
}

// ---------------------------------------------------------------------------
// Constant folding over the builtin table -- what `builtin_optimizers.zig` was.
// ---------------------------------------------------------------------------

const vector_header_size = 2 * @sizeOf(i32);

/// The three constants this file builds slots out of.
///
/// Until Phase 10 Part 7 these were three one-line C functions in `cfuns.c`,
/// because this subsystem translated only `compile.h` and `emit.h` and so had
/// no `janet_wrap_*` of its own. One shared set of types removes the
/// detour. `janet_wrap_integer` is still written out rather than called: it is
/// a macro under nanboxing and a symbol `wrap.c` never defines there, which is
/// the defect `FOUND.md` records. `value_wrap_extern.zig` worked around it the
/// same way until Phase 11 Part 26 deleted it.
inline fn wrapNil() types.Janet {
    return wrap.fromNil();
}

inline fn wrapBoolean(val: bool) types.Janet {
    return wrap.fromBoolean(@intFromBool(val));
}

inline fn wrapInteger(val: i32) types.Janet {
    return wrap.fromNumber(@floatFromInt(val));
}

fn vectorCount(comptime Element: type, vector: ?[*]Element) i32 {
    const v = vector orelse return 0;
    const header: [*]i32 = @ptrFromInt(@intFromPtr(v) - vector_header_size);
    return header[1];
}

fn argumentCount(args: ?[*]types.JanetSlot) i32 {
    return vectorCount(types.JanetSlot, args);
}

fn nilSlot() types.JanetSlot {
    return compiler_primitives.cslot(wrapNil());
}

fn integerSlot(val: i32) types.JanetSlot {
    return compiler_primitives.cslot(wrapInteger(val));
}

fn arity1or2(_: types.JanetFopts, args: ?[*]types.JanetSlot) callconv(.c) c_int {
    const count = argumentCount(args);
    return @intFromBool(count == 1 or count == 2);
}

fn arity2or3(_: types.JanetFopts, args: ?[*]types.JanetSlot) callconv(.c) c_int {
    const count = argumentCount(args);
    return @intFromBool(count == 2 or count == 3);
}

fn fixarity1(_: types.JanetFopts, args: ?[*]types.JanetSlot) callconv(.c) c_int {
    return @intFromBool(argumentCount(args) == 1);
}

fn maxarity1(_: types.JanetFopts, args: ?[*]types.JanetSlot) callconv(.c) c_int {
    return @intFromBool(argumentCount(args) <= 1);
}

fn minarity2(_: types.JanetFopts, args: ?[*]types.JanetSlot) callconv(.c) c_int {
    return @intFromBool(argumentCount(args) >= 2);
}

fn fixarity2(_: types.JanetFopts, args: ?[*]types.JanetSlot) callconv(.c) c_int {
    return @intFromBool(argumentCount(args) == 2);
}

fn fixarity3(_: types.JanetFopts, args: ?[*]types.JanetSlot) callconv(.c) c_int {
    return @intFromBool(argumentCount(args) == 3);
}

fn genericSS(options: types.JanetFopts, opcode: u8, source: types.JanetSlot) types.JanetSlot {
    const target = compiler_primitives.gettarget(options);
    _ = emit_core.emitSs(options.compiler, opcode, target, source, 1);
    return target;
}

fn genericSSI(options: types.JanetFopts, opcode: u8, source: types.JanetSlot, immediate: i8) types.JanetSlot {
    const target = compiler_primitives.gettarget(options);
    _ = emit_core.emitSsi(options.compiler, opcode, target, source, immediate, 1);
    return target;
}

fn opFunction(options: types.JanetFopts, args: ?[*]types.JanetSlot, opcode: u8, default_value: types.Janet) types.JanetSlot {
    const target = compiler_primitives.gettarget(options);
    const second = if (argumentCount(args) == 1) compiler_primitives.cslot(default_value) else args.?[1];
    _ = emit_core.emitSss(options.compiler, opcode, target, args.?[0], second, 1);
    return target;
}

fn slotImmediate(slot: types.JanetSlot) ?i8 {
    if (slot.flags & constants.JANET_SLOT_CONSTANT == 0 or args_core.checkint(slot.constant) == 0) return null;
    const integer: i32 = @intFromFloat(wrap.toNumber(slot.constant));
    if (integer < -128 or integer > 127) return null;
    return @intCast(integer);
}

fn opReduce(
    options: types.JanetFopts,
    args: ?[*]types.JanetSlot,
    opcode: u8,
    immediate_opcode: u8,
    nullary: types.Janet,
    unary: types.Janet,
) types.JanetSlot {
    const count = argumentCount(args);
    if (count == 0) return compiler_primitives.cslot(nullary);
    if (count == 1) {
        const target = compiler_primitives.gettarget(options);
        if (opcode == constants.JOP_SUBTRACT) {
            _ = emit_core.emitSsi(options.compiler, constants.JOP_MULTIPLY_IMMEDIATE, target, args.?[0], -1, 1);
        } else {
            _ = emit_core.emitSss(options.compiler, opcode, target, compiler_primitives.cslot(unary), args.?[0], 1);
        }
        return target;
    }
    const target = compiler_primitives.gettarget(options);
    if (immediate_opcode != 0 and slotImmediate(args.?[1]) != null) {
        _ = emit_core.emitSsi(options.compiler, immediate_opcode, target, args.?[0], slotImmediate(args.?[1]).?, 1);
    } else {
        _ = emit_core.emitSss(options.compiler, opcode, target, args.?[0], args.?[1], 1);
    }
    var index: i32 = 2;
    while (index < count) : (index += 1) {
        if (immediate_opcode != 0 and slotImmediate(args.?[@intCast(index)]) != null) {
            _ = emit_core.emitSsi(options.compiler, immediate_opcode, target, target, slotImmediate(args.?[@intCast(index)]).?, 1);
        } else {
            _ = emit_core.emitSss(options.compiler, opcode, target, target, args.?[@intCast(index)], 1);
        }
    }
    return target;
}

fn compareReduce(options: types.JanetFopts, args: ?[*]types.JanetSlot, opcode: u8, immediate_opcode: u8, invert: bool) types.JanetSlot {
    const count = argumentCount(args);
    if (count < 2) return compiler_primitives.cslot(wrapBoolean(!invert));
    const target = compiler_primitives.gettarget(options);
    const first_instruction = vectorCount(u32, options.compiler.*.buffer);
    var index: i32 = 1;
    while (index < count) : (index += 1) {
        const right = args.?[@intCast(index)];
        if (immediate_opcode != 0 and slotImmediate(right) != null) {
            _ = emit_core.emitSsi(options.compiler, immediate_opcode, target, args.?[@intCast(index - 1)], slotImmediate(right).?, 1);
        } else {
            _ = emit_core.emitSss(options.compiler, opcode, target, args.?[@intCast(index - 1)], right, 1);
        }
        if (index != count - 1) {
            _ = emit_core.emitSi(options.compiler, if (invert) constants.JOP_JUMP_IF else constants.JOP_JUMP_IF_NOT, target, 0, 1);
        }
    }
    const end = vectorCount(u32, options.compiler.*.buffer);
    var instruction = first_instruction;
    while (instruction < end) : (instruction += 1) {
        const opcode_byte = options.compiler.*.buffer.?[@intCast(instruction)] & 0x7f;
        if (opcode_byte == constants.JOP_JUMP_IF or opcode_byte == constants.JOP_JUMP_IF_NOT) {
            options.compiler.*.buffer.?[@intCast(instruction)] |= @as(u32, @intCast(end - instruction)) << 16;
        }
    }
    return target;
}

fn doPropagate(options: types.JanetFopts, args: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return opReduce(options, args, constants.JOP_PROPAGATE, 0, wrapNil(), wrapNil());
}

fn doError(options: types.JanetFopts, args: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    _ = emit_core.emitSlot(options.compiler, constants.JOP_ERROR, args.?[0], 0);
    return nilSlot();
}

fn doDebug(options: types.JanetFopts, args: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    const target = compiler_primitives.gettarget(options);
    const source = if (argumentCount(args) == 1) args.?[0] else nilSlot();
    _ = emit_core.emitSsu(options.compiler, constants.JOP_SIGNAL, target, source, constants.JANET_SIGNAL_DEBUG, 1);
    return target;
}

fn doIn(options: types.JanetFopts, args: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return opReduce(options, args, constants.JOP_IN, 0, wrapNil(), wrapNil());
}

fn doGet(options: types.JanetFopts, args: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    if (argumentCount(args) != 3) return opReduce(options, args, constants.JOP_GET, 0, wrapNil(), wrapNil());
    const target = compiler_primitives.gettarget(options);
    const target_is_default = emit_core.sequal(target, args.?[2]) != 0;
    var default_slot = args.?[2];
    if (target_is_default) {
        default_slot = compiler_primitives.farslot(options.compiler);
        emit_core.copy(options.compiler, default_slot, target);
    }
    _ = emit_core.emitSss(options.compiler, constants.JOP_GET, target, args.?[0], args.?[1], 1);
    const label = emit_core.emitSi(options.compiler, constants.JOP_JUMP_IF_NOT_NIL, target, 0, 0);
    emit_core.copy(options.compiler, target, default_slot);
    if (target_is_default) compiler_primitives.freeslot(options.compiler, default_slot);
    const current = vectorCount(u32, options.compiler.*.buffer);
    options.compiler.*.buffer.?[@intCast(label)] |= @as(u32, @intCast(current - label)) << 16;
    return target;
}

fn doPut(options: types.JanetFopts, args: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    const immediate = slotImmediate(args.?[1]);
    if (options.flags & constants.JANET_FOPTS_DROP != 0) {
        if (immediate) |index| {
            _ = emit_core.emitSsi(options.compiler, constants.JOP_PUT_INDEX, args.?[0], args.?[2], index, 0);
        } else {
            _ = emit_core.emitSss(options.compiler, constants.JOP_PUT, args.?[0], args.?[1], args.?[2], 0);
        }
        return nilSlot();
    }
    const target = compiler_primitives.gettarget(options);
    emit_core.copy(options.compiler, target, args.?[0]);
    if (immediate) |index| {
        _ = emit_core.emitSsi(options.compiler, constants.JOP_PUT_INDEX, target, args.?[2], index, 0);
    } else {
        _ = emit_core.emitSss(options.compiler, constants.JOP_PUT, target, args.?[1], args.?[2], 0);
    }
    return target;
}

fn doApply(options: types.JanetFopts, args: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    const count = argumentCount(args);
    var index: i32 = 1;
    while (index < count - 3) : (index += 3) {
        _ = emit_core.emitSss(options.compiler, constants.JOP_PUSH_3, args.?[@intCast(index)], args.?[@intCast(index + 1)], args.?[@intCast(index + 2)], 0);
    }
    if (index == count - 3) {
        _ = emit_core.emitSs(options.compiler, constants.JOP_PUSH_2, args.?[@intCast(index)], args.?[@intCast(index + 1)], 0);
    } else if (index == count - 2) {
        _ = emit_core.emitSlot(options.compiler, constants.JOP_PUSH, args.?[@intCast(index)], 0);
    }
    _ = emit_core.emitSlot(options.compiler, constants.JOP_PUSH_ARRAY, args.?[@intCast(count - 1)], 0);
    if (options.flags & constants.JANET_FOPTS_TAIL != 0) {
        _ = emit_core.emitSlot(options.compiler, constants.JOP_TAILCALL, args.?[0], 0);
        var target = nilSlot();
        target.flags |= constants.JANET_SLOT_RETURNED;
        return target;
    }
    const target = compiler_primitives.gettarget(options);
    _ = emit_core.emitSs(options.compiler, constants.JOP_CALL, target, args.?[0], 1);
    return target;
}

fn doAdd(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return opReduce(o, a, constants.JOP_ADD, constants.JOP_ADD_IMMEDIATE, wrapInteger(0), wrapInteger(0));
}
fn doSub(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return opReduce(o, a, constants.JOP_SUBTRACT, constants.JOP_SUBTRACT_IMMEDIATE, wrapInteger(0), wrapInteger(0));
}
fn doMul(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return opReduce(o, a, constants.JOP_MULTIPLY, constants.JOP_MULTIPLY_IMMEDIATE, wrapInteger(1), wrapInteger(1));
}
fn doDiv(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return opReduce(o, a, constants.JOP_DIVIDE, constants.JOP_DIVIDE_IMMEDIATE, wrapInteger(1), wrapInteger(1));
}
fn doDivf(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return opReduce(o, a, constants.JOP_DIVIDE_FLOOR, 0, wrapInteger(1), wrapInteger(1));
}
fn doModulo(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return opReduce(o, a, constants.JOP_MODULO, 0, wrapInteger(0), wrapInteger(1));
}
fn doRemainder(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return opReduce(o, a, constants.JOP_REMAINDER, 0, wrapInteger(0), wrapInteger(1));
}
fn doBand(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return opReduce(o, a, constants.JOP_BAND, 0, wrapInteger(-1), wrapInteger(-1));
}
fn doBor(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return opReduce(o, a, constants.JOP_BOR, 0, wrapInteger(0), wrapInteger(0));
}
fn doBxor(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return opReduce(o, a, constants.JOP_BXOR, 0, wrapInteger(0), wrapInteger(0));
}
fn doLshift(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return opReduce(o, a, constants.JOP_SHIFT_LEFT, constants.JOP_SHIFT_LEFT_IMMEDIATE, wrapInteger(1), wrapInteger(1));
}
fn doRshift(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return opReduce(o, a, constants.JOP_SHIFT_RIGHT, constants.JOP_SHIFT_RIGHT_IMMEDIATE, wrapInteger(1), wrapInteger(1));
}
fn doRshiftu(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return opReduce(o, a, constants.JOP_SHIFT_RIGHT_UNSIGNED, constants.JOP_SHIFT_RIGHT_UNSIGNED_IMMEDIATE, wrapInteger(1), wrapInteger(1));
}
fn doBnot(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return genericSS(o, constants.JOP_BNOT, a.?[0]);
}
fn doGt(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return compareReduce(o, a, constants.JOP_GREATER_THAN, constants.JOP_GREATER_THAN_IMMEDIATE, false);
}
fn doLt(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return compareReduce(o, a, constants.JOP_LESS_THAN, constants.JOP_LESS_THAN_IMMEDIATE, false);
}
fn doGte(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return compareReduce(o, a, constants.JOP_GREATER_THAN_EQUAL, 0, false);
}
fn doLte(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return compareReduce(o, a, constants.JOP_LESS_THAN_EQUAL, 0, false);
}
fn doEq(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return compareReduce(o, a, constants.JOP_EQUALS, constants.JOP_EQUALS_IMMEDIATE, false);
}
fn doNeq(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return compareReduce(o, a, constants.JOP_NOT_EQUALS, constants.JOP_NOT_EQUALS_IMMEDIATE, true);
}
fn doLength(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return genericSS(o, constants.JOP_LENGTH, a.?[0]);
}
fn doYield(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return genericSSI(o, constants.JOP_SIGNAL, if (argumentCount(a) == 0) nilSlot() else a.?[0], 3);
}
fn doResume(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return opFunction(o, a, constants.JOP_RESUME, wrapNil());
}
fn doCancel(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return opFunction(o, a, constants.JOP_CANCEL, wrapNil());
}
fn doNext(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return opFunction(o, a, constants.JOP_NEXT, wrapNil());
}
fn doCmp(o: types.JanetFopts, a: ?[*]types.JanetSlot) callconv(.c) types.JanetSlot {
    return opReduce(o, a, constants.JOP_COMPARE, 0, wrapNil(), wrapNil());
}

const optimizers = [_]types.JanetFunOptimizer{
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

pub fn funopt(flags: u32) ?*const types.JanetFunOptimizer {
    const tag = flags & constants.JANET_FUNCDEF_FLAG_TAG;
    if (tag == 0) return null;
    const index = tag - 1;
    if (index >= optimizers.len) return null;
    return &optimizers[index];
}

// ---------------------------------------------------------------------------
// `mov` elimination -- what `movopt.zig` was.
// ---------------------------------------------------------------------------

pub fn bytecodeMovopt(definition: *types.JanetFuncDef) void {
    var repeat = true;
    while (repeat) {
        var registers: types.JanetcRegisterAllocator = undefined;
        regalloc.regallocInit(&registers);
        defer regalloc.regallocDeinit(&registers);

        if (definition.closure_bitset != null) {
            var slot: i32 = 0;
            while (slot < definition.slotcount) : (slot += 1) {
                const index: usize = @intCast(slot >> 5);
                const bit: u5 = @intCast(slot & 31);
                if (definition.closure_bitset.?[index] & (@as(u32, 1) << bit) != 0) {
                    regalloc.regallocTouch(&registers, slot);
                }
            }
        }

        for (definition.bytecode.?[0..@intCast(definition.bytecode_length)]) |instruction| {
            markReads(&registers, instruction);
        }

        repeat = false;
        for (definition.bytecode.?[0..@intCast(definition.bytecode_length)]) |*instruction| {
            const candidate: ?i32 = switch (opcodeOf(instruction.*)) {
                constants.JOP_LOAD_NIL,
                constants.JOP_LOAD_TRUE,
                constants.JOP_LOAD_FALSE,
                constants.JOP_LOAD_SELF,
                constants.JOP_MAKE_ARRAY,
                constants.JOP_MAKE_TUPLE,
                constants.JOP_MAKE_BRACKET_TUPLE,
                => fieldD(instruction.*),

                constants.JOP_MOVE_FAR => fieldE(instruction.*),

                constants.JOP_MOVE_NEAR,
                constants.JOP_GET_INDEX,
                constants.JOP_LOAD_INTEGER,
                constants.JOP_LOAD_CONSTANT,
                constants.JOP_LOAD_UPVALUE,
                constants.JOP_CLOSURE,
                => fieldA(instruction.*),

                else => null,
            };
            if (candidate) |written_slot| {
                if (regalloc.regallocCheck(&registers, written_slot) == 0) {
                    instruction.* = constants.JOP_NOOP;
                    repeat = true;
                }
            }
        }
    }
}

fn markReads(registers: *types.JanetcRegisterAllocator, instruction: u32) void {
    switch (opcodeOf(instruction)) {
        constants.JOP_JUMP,
        constants.JOP_NOOP,
        constants.JOP_RETURN_NIL,
        constants.JOP_LOAD_INTEGER,
        constants.JOP_LOAD_CONSTANT,
        constants.JOP_LOAD_UPVALUE,
        constants.JOP_CLOSURE,
        constants.JOP_LOAD_NIL,
        constants.JOP_LOAD_TRUE,
        constants.JOP_LOAD_FALSE,
        constants.JOP_LOAD_SELF,
        => {},

        constants.JOP_MAKE_ARRAY,
        constants.JOP_MAKE_BUFFER,
        constants.JOP_MAKE_STRING,
        constants.JOP_MAKE_STRUCT,
        constants.JOP_MAKE_TABLE,
        constants.JOP_MAKE_TUPLE,
        constants.JOP_MAKE_BRACKET_TUPLE,
        constants.JOP_RETURN,
        constants.JOP_PUSH,
        constants.JOP_PUSH_ARRAY,
        constants.JOP_TAILCALL,
        => touch(registers, fieldD(instruction)),

        constants.JOP_ERROR,
        constants.JOP_TYPECHECK,
        constants.JOP_JUMP_IF,
        constants.JOP_JUMP_IF_NOT,
        constants.JOP_JUMP_IF_NIL,
        constants.JOP_JUMP_IF_NOT_NIL,
        constants.JOP_SET_UPVALUE,
        constants.JOP_MOVE_FAR,
        => touch(registers, fieldA(instruction)),

        constants.JOP_SIGNAL,
        constants.JOP_ADD_IMMEDIATE,
        constants.JOP_SUBTRACT_IMMEDIATE,
        constants.JOP_MULTIPLY_IMMEDIATE,
        constants.JOP_DIVIDE_IMMEDIATE,
        constants.JOP_SHIFT_LEFT_IMMEDIATE,
        constants.JOP_SHIFT_RIGHT_IMMEDIATE,
        constants.JOP_SHIFT_RIGHT_UNSIGNED_IMMEDIATE,
        constants.JOP_GREATER_THAN_IMMEDIATE,
        constants.JOP_LESS_THAN_IMMEDIATE,
        constants.JOP_EQUALS_IMMEDIATE,
        constants.JOP_NOT_EQUALS_IMMEDIATE,
        constants.JOP_GET_INDEX,
        => touch(registers, fieldB(instruction)),

        constants.JOP_MOVE_NEAR,
        constants.JOP_LENGTH,
        constants.JOP_BNOT,
        constants.JOP_CALL,
        => touch(registers, fieldE(instruction)),

        constants.JOP_PUT_INDEX => {
            touch(registers, fieldA(instruction));
            touch(registers, fieldB(instruction));
        },

        constants.JOP_PUSH_2 => {
            touch(registers, fieldA(instruction));
            touch(registers, fieldE(instruction));
        },

        constants.JOP_PROPAGATE,
        constants.JOP_BAND,
        constants.JOP_BOR,
        constants.JOP_BXOR,
        constants.JOP_ADD,
        constants.JOP_SUBTRACT,
        constants.JOP_MULTIPLY,
        constants.JOP_DIVIDE,
        constants.JOP_DIVIDE_FLOOR,
        constants.JOP_MODULO,
        constants.JOP_REMAINDER,
        constants.JOP_SHIFT_LEFT,
        constants.JOP_SHIFT_RIGHT,
        constants.JOP_SHIFT_RIGHT_UNSIGNED,
        constants.JOP_GREATER_THAN,
        constants.JOP_LESS_THAN,
        constants.JOP_EQUALS,
        constants.JOP_COMPARE,
        constants.JOP_IN,
        constants.JOP_GET,
        constants.JOP_GREATER_THAN_EQUAL,
        constants.JOP_LESS_THAN_EQUAL,
        constants.JOP_NOT_EQUALS,
        constants.JOP_CANCEL,
        constants.JOP_RESUME,
        constants.JOP_NEXT,
        => {
            touch(registers, fieldB(instruction));
            touch(registers, fieldC(instruction));
        },

        constants.JOP_PUT, constants.JOP_PUSH_3 => {
            touch(registers, fieldA(instruction));
            touch(registers, fieldB(instruction));
            touch(registers, fieldC(instruction));
        },

        else => fatal.fatal("unhandled instruction"),
    }
}

fn touch(registers: *types.JanetcRegisterAllocator, slot: i32) void {
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
// `noop` removal -- what `remove_noops.zig` was.
// ---------------------------------------------------------------------------

pub fn bytecodeRemoveNoops(definition: *types.JanetFuncDef) void {
    const old_length = definition.bytecode_length;
    const map_length: usize = @intCast(old_length + 1);
    const map_size = map_length * @sizeOf(u32);
    const map_memory = gc_alloc.smalloc(map_size) orelse fatal.outOfMemory();
    const pc_map: [*]u32 = @ptrCast(@alignCast(map_memory));
    defer gc_alloc.sfree(pc_map);

    var new_length: u32 = 0;
    for (definition.bytecode.?[0..@intCast(old_length)], 0..) |instruction, index| {
        pc_map[index] = new_length;
        if (opcodeOf(instruction) != constants.JOP_NOOP) new_length += 1;
    }
    pc_map[@intCast(old_length)] = new_length;

    var destination_index: i32 = 0;
    var source_index: i32 = 0;
    while (source_index < old_length) : (source_index += 1) {
        var instruction = definition.bytecode.?[@intCast(source_index)];
        const shift: ?u5 = switch (opcodeOf(instruction)) {
            constants.JOP_NOOP => continue,
            constants.JOP_JUMP => 8,
            constants.JOP_JUMP_IF, constants.JOP_JUMP_IF_NIL, constants.JOP_JUMP_IF_NOT, constants.JOP_JUMP_IF_NOT_NIL => 16,
            else => null,
        };
        if (shift) |field_shift| {
            const old_target = source_index + signedField(instruction, field_shift);
            if (old_target < 0 or old_target >= old_length) fatal.fatal("bounds");
            const new_target: i32 = @intCast(pc_map[@intCast(old_target)]);
            const adjustment = new_target - old_target + (source_index - destination_index);
            instruction +%= @as(u32, @bitCast(adjustment)) << field_shift;
        }
        definition.bytecode.?[@intCast(destination_index)] = instruction;
        if (definition.sourcemap != null) {
            definition.sourcemap.?[@intCast(destination_index)] = definition.sourcemap.?[@intCast(source_index)];
        }
        destination_index += 1;
    }

    if (definition.symbolmap_length > 0) {
        for (definition.symbolmap.?[0..@intCast(definition.symbolmap_length)]) |*symbol| {
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
