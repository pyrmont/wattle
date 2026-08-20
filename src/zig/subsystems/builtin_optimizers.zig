const abi = @import("abi");
const c = abi.c;

const vector_header_size = 2 * @sizeOf(i32);

/// The three constants this file builds slots out of.
///
/// Until Phase 10 Part 7 these were three one-line C functions in `cfuns.c`,
/// because this subsystem translated only `compile.h` and `emit.h` and so had
/// no `janet_wrap_*` of its own. Sharing `abi.zig`'s translation removes the
/// detour. `janet_wrap_integer` is still written out rather than called: it is
/// a macro under nanboxing and a symbol `wrap.c` never defines there, which is
/// the defect `FOUND.md` records and `value_wrap_extern.zig` works around the
/// same way.
inline fn wrapNil() c.Janet {
    return c.janet_wrap_nil();
}

inline fn wrapBoolean(value: bool) c.Janet {
    return c.janet_wrap_boolean(@intFromBool(value));
}

inline fn wrapInteger(value: i32) c.Janet {
    return c.janet_wrap_number(@floatFromInt(value));
}

fn vectorCount(comptime Element: type, vector: [*c]Element) i32 {
    if (vector == null) return 0;
    const header: [*]i32 = @ptrFromInt(@intFromPtr(vector) - vector_header_size);
    return header[1];
}

fn argumentCount(args: [*c]c.JanetSlot) i32 {
    return vectorCount(c.JanetSlot, args);
}

fn nilSlot() c.JanetSlot {
    return c.janetc_cslot(wrapNil());
}

fn integerSlot(value: i32) c.JanetSlot {
    return c.janetc_cslot(wrapInteger(value));
}

fn arity1or2(_: c.JanetFopts, args: [*c]c.JanetSlot) callconv(.c) c_int {
    const count = argumentCount(args);
    return @intFromBool(count == 1 or count == 2);
}

fn arity2or3(_: c.JanetFopts, args: [*c]c.JanetSlot) callconv(.c) c_int {
    const count = argumentCount(args);
    return @intFromBool(count == 2 or count == 3);
}

fn fixarity1(_: c.JanetFopts, args: [*c]c.JanetSlot) callconv(.c) c_int {
    return @intFromBool(argumentCount(args) == 1);
}

fn maxarity1(_: c.JanetFopts, args: [*c]c.JanetSlot) callconv(.c) c_int {
    return @intFromBool(argumentCount(args) <= 1);
}

fn minarity2(_: c.JanetFopts, args: [*c]c.JanetSlot) callconv(.c) c_int {
    return @intFromBool(argumentCount(args) >= 2);
}

fn fixarity2(_: c.JanetFopts, args: [*c]c.JanetSlot) callconv(.c) c_int {
    return @intFromBool(argumentCount(args) == 2);
}

fn fixarity3(_: c.JanetFopts, args: [*c]c.JanetSlot) callconv(.c) c_int {
    return @intFromBool(argumentCount(args) == 3);
}

fn genericSS(options: c.JanetFopts, opcode: u8, source: c.JanetSlot) c.JanetSlot {
    const target = c.janetc_gettarget(options);
    _ = c.janetc_emit_ss(options.compiler, opcode, target, source, 1);
    return target;
}

fn genericSSI(options: c.JanetFopts, opcode: u8, source: c.JanetSlot, immediate: i8) c.JanetSlot {
    const target = c.janetc_gettarget(options);
    _ = c.janetc_emit_ssi(options.compiler, opcode, target, source, immediate, 1);
    return target;
}

fn opFunction(options: c.JanetFopts, args: [*c]c.JanetSlot, opcode: u8, default_value: c.Janet) c.JanetSlot {
    const target = c.janetc_gettarget(options);
    const second = if (argumentCount(args) == 1) c.janetc_cslot(default_value) else args[1];
    _ = c.janetc_emit_sss(options.compiler, opcode, target, args[0], second, 1);
    return target;
}

fn slotImmediate(slot: c.JanetSlot) ?i8 {
    if (slot.flags & c.JANET_SLOT_CONSTANT == 0 or c.janet_checkint(slot.constant) == 0) return null;
    const integer: i32 = @intFromFloat(c.janet_unwrap_number(slot.constant));
    if (integer < -128 or integer > 127) return null;
    return @intCast(integer);
}

fn opReduce(
    options: c.JanetFopts,
    args: [*c]c.JanetSlot,
    opcode: u8,
    immediate_opcode: u8,
    nullary: c.Janet,
    unary: c.Janet,
) c.JanetSlot {
    const count = argumentCount(args);
    if (count == 0) return c.janetc_cslot(nullary);
    if (count == 1) {
        const target = c.janetc_gettarget(options);
        if (opcode == c.JOP_SUBTRACT) {
            _ = c.janetc_emit_ssi(options.compiler, c.JOP_MULTIPLY_IMMEDIATE, target, args[0], -1, 1);
        } else {
            _ = c.janetc_emit_sss(options.compiler, opcode, target, c.janetc_cslot(unary), args[0], 1);
        }
        return target;
    }
    const target = c.janetc_gettarget(options);
    if (immediate_opcode != 0 and slotImmediate(args[1]) != null) {
        _ = c.janetc_emit_ssi(options.compiler, immediate_opcode, target, args[0], slotImmediate(args[1]).?, 1);
    } else {
        _ = c.janetc_emit_sss(options.compiler, opcode, target, args[0], args[1], 1);
    }
    var index: i32 = 2;
    while (index < count) : (index += 1) {
        if (immediate_opcode != 0 and slotImmediate(args[@intCast(index)]) != null) {
            _ = c.janetc_emit_ssi(options.compiler, immediate_opcode, target, target, slotImmediate(args[@intCast(index)]).?, 1);
        } else {
            _ = c.janetc_emit_sss(options.compiler, opcode, target, target, args[@intCast(index)], 1);
        }
    }
    return target;
}

fn compareReduce(options: c.JanetFopts, args: [*c]c.JanetSlot, opcode: u8, immediate_opcode: u8, invert: bool) c.JanetSlot {
    const count = argumentCount(args);
    if (count < 2) return c.janetc_cslot(wrapBoolean(!invert));
    const target = c.janetc_gettarget(options);
    const first_instruction = vectorCount(u32, options.compiler.*.buffer);
    var index: i32 = 1;
    while (index < count) : (index += 1) {
        const right = args[@intCast(index)];
        if (immediate_opcode != 0 and slotImmediate(right) != null) {
            _ = c.janetc_emit_ssi(options.compiler, immediate_opcode, target, args[@intCast(index - 1)], slotImmediate(right).?, 1);
        } else {
            _ = c.janetc_emit_sss(options.compiler, opcode, target, args[@intCast(index - 1)], right, 1);
        }
        if (index != count - 1) {
            _ = c.janetc_emit_si(options.compiler, if (invert) c.JOP_JUMP_IF else c.JOP_JUMP_IF_NOT, target, 0, 1);
        }
    }
    const end = vectorCount(u32, options.compiler.*.buffer);
    var instruction = first_instruction;
    while (instruction < end) : (instruction += 1) {
        const opcode_byte = options.compiler.*.buffer[@intCast(instruction)] & 0x7f;
        if (opcode_byte == c.JOP_JUMP_IF or opcode_byte == c.JOP_JUMP_IF_NOT) {
            options.compiler.*.buffer[@intCast(instruction)] |= @as(u32, @intCast(end - instruction)) << 16;
        }
    }
    return target;
}

fn doPropagate(options: c.JanetFopts, args: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return opReduce(options, args, c.JOP_PROPAGATE, 0, wrapNil(), wrapNil());
}

fn doError(options: c.JanetFopts, args: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    _ = c.janetc_emit_s(options.compiler, c.JOP_ERROR, args[0], 0);
    return nilSlot();
}

fn doDebug(options: c.JanetFopts, args: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    const target = c.janetc_gettarget(options);
    const source = if (argumentCount(args) == 1) args[0] else nilSlot();
    _ = c.janetc_emit_ssu(options.compiler, c.JOP_SIGNAL, target, source, c.JANET_SIGNAL_DEBUG, 1);
    return target;
}

fn doIn(options: c.JanetFopts, args: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return opReduce(options, args, c.JOP_IN, 0, wrapNil(), wrapNil());
}

fn doGet(options: c.JanetFopts, args: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    if (argumentCount(args) != 3) return opReduce(options, args, c.JOP_GET, 0, wrapNil(), wrapNil());
    const target = c.janetc_gettarget(options);
    const target_is_default = c.janetc_sequal(target, args[2]) != 0;
    var default_slot = args[2];
    if (target_is_default) {
        default_slot = c.janetc_farslot(options.compiler);
        c.janetc_copy(options.compiler, default_slot, target);
    }
    _ = c.janetc_emit_sss(options.compiler, c.JOP_GET, target, args[0], args[1], 1);
    const label = c.janetc_emit_si(options.compiler, c.JOP_JUMP_IF_NOT_NIL, target, 0, 0);
    c.janetc_copy(options.compiler, target, default_slot);
    if (target_is_default) c.janetc_freeslot(options.compiler, default_slot);
    const current = vectorCount(u32, options.compiler.*.buffer);
    options.compiler.*.buffer[@intCast(label)] |= @as(u32, @intCast(current - label)) << 16;
    return target;
}

fn doPut(options: c.JanetFopts, args: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    const immediate = slotImmediate(args[1]);
    if (options.flags & c.JANET_FOPTS_DROP != 0) {
        if (immediate) |index| {
            _ = c.janetc_emit_ssi(options.compiler, c.JOP_PUT_INDEX, args[0], args[2], index, 0);
        } else {
            _ = c.janetc_emit_sss(options.compiler, c.JOP_PUT, args[0], args[1], args[2], 0);
        }
        return nilSlot();
    }
    const target = c.janetc_gettarget(options);
    c.janetc_copy(options.compiler, target, args[0]);
    if (immediate) |index| {
        _ = c.janetc_emit_ssi(options.compiler, c.JOP_PUT_INDEX, target, args[2], index, 0);
    } else {
        _ = c.janetc_emit_sss(options.compiler, c.JOP_PUT, target, args[1], args[2], 0);
    }
    return target;
}

fn doApply(options: c.JanetFopts, args: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    const count = argumentCount(args);
    var index: i32 = 1;
    while (index < count - 3) : (index += 3) {
        _ = c.janetc_emit_sss(options.compiler, c.JOP_PUSH_3, args[@intCast(index)], args[@intCast(index + 1)], args[@intCast(index + 2)], 0);
    }
    if (index == count - 3) {
        _ = c.janetc_emit_ss(options.compiler, c.JOP_PUSH_2, args[@intCast(index)], args[@intCast(index + 1)], 0);
    } else if (index == count - 2) {
        _ = c.janetc_emit_s(options.compiler, c.JOP_PUSH, args[@intCast(index)], 0);
    }
    _ = c.janetc_emit_s(options.compiler, c.JOP_PUSH_ARRAY, args[@intCast(count - 1)], 0);
    if (options.flags & c.JANET_FOPTS_TAIL != 0) {
        _ = c.janetc_emit_s(options.compiler, c.JOP_TAILCALL, args[0], 0);
        var target = nilSlot();
        target.flags |= c.JANET_SLOT_RETURNED;
        return target;
    }
    const target = c.janetc_gettarget(options);
    _ = c.janetc_emit_ss(options.compiler, c.JOP_CALL, target, args[0], 1);
    return target;
}

fn doAdd(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return opReduce(o, a, c.JOP_ADD, c.JOP_ADD_IMMEDIATE, wrapInteger(0), wrapInteger(0));
}
fn doSub(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return opReduce(o, a, c.JOP_SUBTRACT, c.JOP_SUBTRACT_IMMEDIATE, wrapInteger(0), wrapInteger(0));
}
fn doMul(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return opReduce(o, a, c.JOP_MULTIPLY, c.JOP_MULTIPLY_IMMEDIATE, wrapInteger(1), wrapInteger(1));
}
fn doDiv(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return opReduce(o, a, c.JOP_DIVIDE, c.JOP_DIVIDE_IMMEDIATE, wrapInteger(1), wrapInteger(1));
}
fn doDivf(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return opReduce(o, a, c.JOP_DIVIDE_FLOOR, 0, wrapInteger(1), wrapInteger(1));
}
fn doModulo(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return opReduce(o, a, c.JOP_MODULO, 0, wrapInteger(0), wrapInteger(1));
}
fn doRemainder(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return opReduce(o, a, c.JOP_REMAINDER, 0, wrapInteger(0), wrapInteger(1));
}
fn doBand(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return opReduce(o, a, c.JOP_BAND, 0, wrapInteger(-1), wrapInteger(-1));
}
fn doBor(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return opReduce(o, a, c.JOP_BOR, 0, wrapInteger(0), wrapInteger(0));
}
fn doBxor(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return opReduce(o, a, c.JOP_BXOR, 0, wrapInteger(0), wrapInteger(0));
}
fn doLshift(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return opReduce(o, a, c.JOP_SHIFT_LEFT, c.JOP_SHIFT_LEFT_IMMEDIATE, wrapInteger(1), wrapInteger(1));
}
fn doRshift(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return opReduce(o, a, c.JOP_SHIFT_RIGHT, c.JOP_SHIFT_RIGHT_IMMEDIATE, wrapInteger(1), wrapInteger(1));
}
fn doRshiftu(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return opReduce(o, a, c.JOP_SHIFT_RIGHT_UNSIGNED, c.JOP_SHIFT_RIGHT_UNSIGNED_IMMEDIATE, wrapInteger(1), wrapInteger(1));
}
fn doBnot(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return genericSS(o, c.JOP_BNOT, a[0]);
}
fn doGt(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return compareReduce(o, a, c.JOP_GREATER_THAN, c.JOP_GREATER_THAN_IMMEDIATE, false);
}
fn doLt(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return compareReduce(o, a, c.JOP_LESS_THAN, c.JOP_LESS_THAN_IMMEDIATE, false);
}
fn doGte(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return compareReduce(o, a, c.JOP_GREATER_THAN_EQUAL, 0, false);
}
fn doLte(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return compareReduce(o, a, c.JOP_LESS_THAN_EQUAL, 0, false);
}
fn doEq(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return compareReduce(o, a, c.JOP_EQUALS, c.JOP_EQUALS_IMMEDIATE, false);
}
fn doNeq(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return compareReduce(o, a, c.JOP_NOT_EQUALS, c.JOP_NOT_EQUALS_IMMEDIATE, true);
}
fn doLength(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return genericSS(o, c.JOP_LENGTH, a[0]);
}
fn doYield(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return genericSSI(o, c.JOP_SIGNAL, if (argumentCount(a) == 0) nilSlot() else a[0], 3);
}
fn doResume(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return opFunction(o, a, c.JOP_RESUME, wrapNil());
}
fn doCancel(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return opFunction(o, a, c.JOP_CANCEL, wrapNil());
}
fn doNext(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return opFunction(o, a, c.JOP_NEXT, wrapNil());
}
fn doCmp(o: c.JanetFopts, a: [*c]c.JanetSlot) callconv(.c) c.JanetSlot {
    return opReduce(o, a, c.JOP_COMPARE, 0, wrapNil(), wrapNil());
}

const optimizers = [_]c.JanetFunOptimizer{
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

export fn janetc_funopt(flags: u32) callconv(.c) ?*const c.JanetFunOptimizer {
    const tag = flags & c.JANET_FUNCDEF_FLAG_TAG;
    if (tag == 0) return null;
    const index = tag - 1;
    if (index >= optimizers.len) return null;
    return &optimizers[index];
}
