//! Emitting one bytecode instruction, and the register bookkeeping around it.
//!
//! Ten entry points, one per operand shape, over five kernels. The kernels
//! return an error union and the entry points carry it, which is only possible
//! because there is no C-ABI boundary between them: an error union does not
//! cross one.
//!
//! Nothing here raises. The compiler front end reports by *flag*:
//! `janetc_error` sets `c->result.status`, keeps the first error, and returns,
//! so compilation continues and the user sees the first thing that went wrong
//! rather than the last.

const std = @import("std");
const order = @import("../value/helpers/order.zig");
const compiler_primitives = @import("../compiler.zig");
const stretchy = @import("../stretchy.zig");
const regalloc = @import("regalloc.zig");
const wrap = @import("../value/helpers/wrap.zig");
const args_core = @import("../args.zig");
const repr = @import("repr");
const constants = @import("constants");

const EmitError = error{ TooManyConstants, TooManyRegisters };

/// Record an emit failure on the compiler and carry on.
///
/// The mapping from an error to its text sits next to the code that raises it.
/// While the kernels below were on the far side of a C-ABI boundary it could
/// not: an error union does not cross one, so the five emit shapes were
/// squeezed through a single `int`-returning call with an enum to say which,
/// and something on the near side turned the code back into a message.
///
/// This is not a raise. `compiler.cerror` records the message on the compiler
/// and returns; the front end reports by flag and keeps compiling, so that the
/// first error is the one the user sees.
fn report(compiler: *compiler_primitives.JanetCompiler, emit_error: EmitError) void {
    switch (emit_error) {
        error.TooManyConstants => compiler_primitives.cerror(compiler, "too many constants"),
        error.TooManyRegisters => compiler_primitives.cerror(compiler, "ran out of internal registers"),
    }
}

/// A far register, or an error recorded on the compiler.
///
/// `janetc_regalloc_1` allocates from the whole 32-bit space and the
/// instruction encoding has sixteen bits for a far slot, so the ceiling is
/// checked here rather than in the allocator.
pub fn allocfar(compiler: *compiler_primitives.JanetCompiler) i32 {
    const register = allocFar(compiler);
    if (register > 0xFFFF) {
        compiler_primitives.cerror(compiler, "ran out of internal registers");
    }
    return register;
}

/// The allocation without the ceiling check. `registerFar` below has its own
/// caller to unwind before it can report, so it takes the raw number and
/// answers `error.TooManyRegisters`, which `report` renders as the same
/// message. The C original reaches `janetc_allocfar` there and lets the
/// second report be swallowed by "keep the first error"; this says the same
/// thing once.
fn allocFar(compiler: *compiler_primitives.JanetCompiler) i32 {
    return regalloc.regalloc1(&compiler.scope.?.ra);
}

pub fn allocnear(
    compiler: *compiler_primitives.JanetCompiler,
    temporary: compiler_primitives.JanetcRegisterTemp,
) i32 {
    return regalloc.regallocTemp(&compiler.scope.?.ra, temporary);
}

pub fn emit(compiler: *compiler_primitives.JanetCompiler, instruction: u32) void {
    stretchy.push(&compiler.buffer, instruction);
    stretchy.push(&compiler.mapbuffer, compiler.current_mapping);
}

pub fn sequal(lhs: compiler_primitives.JanetSlot, rhs: compiler_primitives.JanetSlot) bool {
    if (!std.meta.eql(lhs.flags.withoutTypes(), rhs.flags.withoutTypes()) or
        lhs.index != rhs.index or
        lhs.envindex != rhs.envindex)
    {
        return false;
    }

    if (lhs.flags.ref or lhs.flags.constant) {
        return order.equals(lhs.constant, rhs.constant);
    }
    return true;
}

/// `dest = src`, or an error recorded on the compiler.
pub fn copy(
    compiler: *compiler_primitives.JanetCompiler,
    destination: compiler_primitives.JanetSlot,
    source: compiler_primitives.JanetSlot,
) void {
    if (destination.flags.constant) {
        compiler_primitives.cerror(compiler, "cannot write to constant");
        return;
    }
    if (!copySlot(compiler, destination, source)) {
        compiler_primitives.cerror(compiler, "too many constants");
    }
}

fn copySlot(compiler: *compiler_primitives.JanetCompiler, destination: compiler_primitives.JanetSlot, source: compiler_primitives.JanetSlot) bool {
    if (slotsEqual(destination, source)) return true;

    if (destination.envindex < 0 and destination.index >= 0 and destination.index <= 0xff) {
        return moveNear(compiler, destination.index, source);
    }
    if (source.envindex < 0 and source.index >= 0 and source.index <= 0xff) {
        return moveBack(compiler, destination, source.index);
    }

    const temporary = regalloc.regallocTemp(&compiler.scope.?.ra, constants.JANETC_REGTEMP_3);
    if (!moveNear(compiler, temporary, source)) {
        regalloc.regallocFreetemp(&compiler.scope.?.ra, temporary, constants.JANETC_REGTEMP_3);
        return false;
    }
    const success = moveBack(compiler, destination, temporary);
    regalloc.regallocFreetemp(&compiler.scope.?.ra, temporary, constants.JANETC_REGTEMP_3);
    return success;
}

/// The ten emit entry points, one per operand shape.
///
/// Each is the label of the instruction it appended, or zero if the compiler
/// recorded an error instead -- which is what the C original returned too,
/// having initialised its label to zero and left it untouched on a nonzero
/// status. A label of zero is a real instruction index, so it is not a
/// sentinel a caller may test; the caller tests `c->result.status`, as it did
/// before.
pub fn emitSlot(
    compiler: *compiler_primitives.JanetCompiler,
    operation: constants.Opcode,
    slot_value: compiler_primitives.JanetSlot,
    write_back: c_int,
) i32 {
    return emitS(compiler, operation, slot_value, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

/// A jump to an already-known label, encoded as a signed 16-bit displacement.
///
/// The range check reports and then emits anyway, exactly as the C original
/// does: `janetc_error` keeps only the first error, and the truncated
/// instruction is never run because the compile has already failed.
pub fn emitSl(
    compiler: *compiler_primitives.JanetCompiler,
    operation: constants.Opcode,
    slot_value: compiler_primitives.JanetSlot,
    label: i32,
) i32 {
    const current = compiler.here() - 1;
    const jump = label - current;
    if (jump < std.math.minInt(i16) or jump > std.math.maxInt(i16)) {
        compiler_primitives.cerror(compiler, "jump is too far");
    }
    return emitOneSlot(compiler, operation, slot_value, jump, false) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

pub fn emitSt(
    compiler: *compiler_primitives.JanetCompiler,
    operation: constants.Opcode,
    slot_value: compiler_primitives.JanetSlot,
    typeflags: i32,
) i32 {
    return emitOneSlot(compiler, operation, slot_value, typeflags, false) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

pub fn emitSi(
    compiler: *compiler_primitives.JanetCompiler,
    operation: constants.Opcode,
    slot_value: compiler_primitives.JanetSlot,
    immediate: i16,
    write_back: c_int,
) i32 {
    return emitOneSlot(compiler, operation, slot_value, immediate, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

pub fn emitSu(
    compiler: *compiler_primitives.JanetCompiler,
    operation: constants.Opcode,
    slot_value: compiler_primitives.JanetSlot,
    immediate: u16,
    write_back: c_int,
) i32 {
    return emitOneSlot(compiler, operation, slot_value, immediate, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

pub fn emitSs(
    compiler: *compiler_primitives.JanetCompiler,
    operation: constants.Opcode,
    slot1: compiler_primitives.JanetSlot,
    slot2: compiler_primitives.JanetSlot,
    write_back: c_int,
) i32 {
    return emitSS(compiler, operation, slot1, slot2, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

pub fn emitSsi(
    compiler: *compiler_primitives.JanetCompiler,
    operation: constants.Opcode,
    slot1: compiler_primitives.JanetSlot,
    slot2: compiler_primitives.JanetSlot,
    immediate: i8,
    write_back: c_int,
) i32 {
    return emitTwoSlots(compiler, operation, slot1, slot2, immediate, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

pub fn emitSsu(
    compiler: *compiler_primitives.JanetCompiler,
    operation: constants.Opcode,
    slot1: compiler_primitives.JanetSlot,
    slot2: compiler_primitives.JanetSlot,
    immediate: u8,
    write_back: c_int,
) i32 {
    return emitTwoSlots(compiler, operation, slot1, slot2, immediate, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

pub fn emitSss(
    compiler: *compiler_primitives.JanetCompiler,
    operation: constants.Opcode,
    slot1: compiler_primitives.JanetSlot,
    slot2: compiler_primitives.JanetSlot,
    slot3: compiler_primitives.JanetSlot,
    write_back: c_int,
) i32 {
    return emitSSS(compiler, operation, slot1, slot2, slot3, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

fn emitS(compiler: *compiler_primitives.JanetCompiler, operation: constants.Opcode, slot_value: compiler_primitives.JanetSlot, write_back: bool) EmitError!i32 {
    const register = try registerFar(compiler, slot_value, constants.JANETC_REGTEMP_0);
    const label = compiler.here();
    emitInstruction(compiler, opcode(operation) | (@as(u32, @intCast(register)) << 8));
    if (write_back and !moveBack(compiler, slot_value, register)) return error.TooManyConstants;
    freeRegister(compiler, slot_value, register, constants.JANETC_REGTEMP_0);
    return label;
}

fn emitOneSlot(
    compiler: *compiler_primitives.JanetCompiler,
    operation: constants.Opcode,
    slot_value: compiler_primitives.JanetSlot,
    rest: i32,
    write_back: bool,
) EmitError!i32 {
    const register = try registerNear(compiler, slot_value, constants.JANETC_REGTEMP_0);
    const label = compiler.here();
    const rest_bits: u32 = @bitCast(rest);
    emitInstruction(compiler, opcode(operation) |
        (@as(u32, @intCast(register)) << 8) |
        (rest_bits << 16));
    if (write_back and !moveBack(compiler, slot_value, register)) return error.TooManyConstants;
    freeRegister(compiler, slot_value, register, constants.JANETC_REGTEMP_0);
    return label;
}

fn emitSS(
    compiler: *compiler_primitives.JanetCompiler,
    operation: constants.Opcode,
    slot1: compiler_primitives.JanetSlot,
    slot2: compiler_primitives.JanetSlot,
    write_back: bool,
) EmitError!i32 {
    const register1 = try registerNear(compiler, slot1, constants.JANETC_REGTEMP_0);
    const register2 = registerFar(compiler, slot2, constants.JANETC_REGTEMP_1) catch |emit_error| {
        freeRegister(compiler, slot1, register1, constants.JANETC_REGTEMP_0);
        return emit_error;
    };
    const label = compiler.here();
    emitInstruction(compiler, opcode(operation) |
        (@as(u32, @intCast(register1)) << 8) |
        (@as(u32, @intCast(register2)) << 16));
    freeRegister(compiler, slot2, register2, constants.JANETC_REGTEMP_1);
    if (write_back and !moveBack(compiler, slot1, register1)) return error.TooManyConstants;
    freeRegister(compiler, slot1, register1, constants.JANETC_REGTEMP_0);
    return label;
}

fn emitTwoSlots(
    compiler: *compiler_primitives.JanetCompiler,
    operation: constants.Opcode,
    slot1: compiler_primitives.JanetSlot,
    slot2: compiler_primitives.JanetSlot,
    rest: i32,
    write_back: bool,
) EmitError!i32 {
    const register1 = try registerNear(compiler, slot1, constants.JANETC_REGTEMP_0);
    const register2 = registerNear(compiler, slot2, constants.JANETC_REGTEMP_1) catch |emit_error| {
        freeRegister(compiler, slot1, register1, constants.JANETC_REGTEMP_0);
        return emit_error;
    };
    const label = compiler.here();
    const rest_bits: u32 = @bitCast(rest);
    emitInstruction(compiler, opcode(operation) |
        (@as(u32, @intCast(register1)) << 8) |
        (@as(u32, @intCast(register2)) << 16) |
        (rest_bits << 24));
    freeRegister(compiler, slot2, register2, constants.JANETC_REGTEMP_1);
    if (write_back and !moveBack(compiler, slot1, register1)) return error.TooManyConstants;
    freeRegister(compiler, slot1, register1, constants.JANETC_REGTEMP_0);
    return label;
}

fn emitSSS(
    compiler: *compiler_primitives.JanetCompiler,
    operation: constants.Opcode,
    slot1: compiler_primitives.JanetSlot,
    slot2: compiler_primitives.JanetSlot,
    slot3: compiler_primitives.JanetSlot,
    write_back: bool,
) EmitError!i32 {
    const register1 = try registerNear(compiler, slot1, constants.JANETC_REGTEMP_0);
    const register2 = registerNear(compiler, slot2, constants.JANETC_REGTEMP_1) catch |emit_error| {
        freeRegister(compiler, slot1, register1, constants.JANETC_REGTEMP_0);
        return emit_error;
    };
    const register3 = registerNear(compiler, slot3, constants.JANETC_REGTEMP_2) catch |emit_error| {
        freeRegister(compiler, slot2, register2, constants.JANETC_REGTEMP_1);
        freeRegister(compiler, slot1, register1, constants.JANETC_REGTEMP_0);
        return emit_error;
    };
    const label = compiler.here();
    emitInstruction(compiler, opcode(operation) |
        (@as(u32, @intCast(register1)) << 8) |
        (@as(u32, @intCast(register2)) << 16) |
        (@as(u32, @intCast(register3)) << 24));
    freeRegister(compiler, slot2, register2, constants.JANETC_REGTEMP_1);
    freeRegister(compiler, slot3, register3, constants.JANETC_REGTEMP_2);
    if (write_back and !moveBack(compiler, slot1, register1)) return error.TooManyConstants;
    freeRegister(compiler, slot1, register1, constants.JANETC_REGTEMP_0);
    return label;
}

fn registerFar(compiler: *compiler_primitives.JanetCompiler, slot_value: compiler_primitives.JanetSlot, temporary: compiler_primitives.JanetcRegisterTemp) EmitError!i32 {
    if (slot_value.envindex < 0 and slot_value.index >= 0) return slot_value.index;

    const near_register = regalloc.regallocTemp(&compiler.scope.?.ra, temporary);
    if (!moveNear(compiler, near_register, slot_value)) {
        regalloc.regallocFreetemp(&compiler.scope.?.ra, near_register, temporary);
        return error.TooManyConstants;
    }
    if (near_register >= 0xf0) {
        const far_register = allocFar(compiler);
        if (far_register > 0xffff) {
            regalloc.regallocFreetemp(&compiler.scope.?.ra, near_register, temporary);
            return error.TooManyRegisters;
        }
        emitInstruction(compiler, opcode(constants.Opcode.move_far) |
            (@as(u32, @intCast(near_register)) << 8) |
            (@as(u32, @intCast(far_register)) << 16));
        regalloc.regallocFreetemp(&compiler.scope.?.ra, near_register, temporary);
        return far_register;
    }

    regalloc.regallocFreetemp(&compiler.scope.?.ra, near_register, temporary);
    regalloc.regallocTouch(&compiler.scope.?.ra, near_register);
    return near_register;
}

fn registerNear(compiler: *compiler_primitives.JanetCompiler, slot_value: compiler_primitives.JanetSlot, temporary: compiler_primitives.JanetcRegisterTemp) EmitError!i32 {
    if (slot_value.envindex < 0 and slot_value.index >= 0 and slot_value.index <= 0xff) {
        return slot_value.index;
    }
    const register = regalloc.regallocTemp(&compiler.scope.?.ra, temporary);
    if (!moveNear(compiler, register, slot_value)) {
        regalloc.regallocFreetemp(&compiler.scope.?.ra, register, temporary);
        return error.TooManyConstants;
    }
    return register;
}

fn freeRegister(
    compiler: *compiler_primitives.JanetCompiler,
    slot_value: compiler_primitives.JanetSlot,
    register: i32,
    temporary: compiler_primitives.JanetcRegisterTemp,
) void {
    if (register != slot_value.index or
        slot_value.envindex >= 0 or
        (slot_value.flags.constant or slot_value.flags.ref))
    {
        regalloc.regallocFreetemp(&compiler.scope.?.ra, register, temporary);
    }
}

fn moveNear(compiler: *compiler_primitives.JanetCompiler, destination: i32, source: compiler_primitives.JanetSlot) bool {
    if (source.flags.constant or source.flags.ref) {
        if (!loadConstant(compiler, source.constant, destination)) return false;
        if (source.flags.ref) {
            emitInstruction(compiler, opcode(constants.Opcode.get_index) |
                (@as(u32, @intCast(destination)) << 8) |
                (@as(u32, @intCast(destination)) << 16));
        }
    } else if (source.envindex >= 0) {
        emitInstruction(compiler, opcode(constants.Opcode.load_upvalue) |
            (@as(u32, @intCast(destination)) << 8) |
            (@as(u32, @intCast(source.envindex)) << 16) |
            (@as(u32, @intCast(source.index)) << 24));
    } else if (source.index != destination) {
        emitInstruction(compiler, opcode(constants.Opcode.move_near) |
            (@as(u32, @intCast(destination)) << 8) |
            (@as(u32, @intCast(source.index)) << 16));
    }
    return true;
}

fn moveBack(compiler: *compiler_primitives.JanetCompiler, destination: compiler_primitives.JanetSlot, source_value: i32) bool {
    var source = source_value;
    if (destination.flags.ref) {
        const reference = regalloc.regallocTemp(&compiler.scope.?.ra, constants.JANETC_REGTEMP_5);
        if (!loadConstant(compiler, destination.constant, reference)) {
            regalloc.regallocFreetemp(&compiler.scope.?.ra, reference, constants.JANETC_REGTEMP_5);
            return false;
        }
        emitInstruction(compiler, opcode(constants.Opcode.put_index) |
            (@as(u32, @intCast(reference)) << 8) |
            (@as(u32, @intCast(source)) << 16));
        regalloc.regallocFreetemp(&compiler.scope.?.ra, reference, constants.JANETC_REGTEMP_5);
    } else if (destination.envindex >= 0) {
        source = makeNearSource(compiler, source);
        emitInstruction(compiler, opcode(constants.Opcode.set_upvalue) |
            (@as(u32, @intCast(source)) << 8) |
            (@as(u32, @intCast(destination.envindex)) << 16) |
            (@as(u32, @intCast(destination.index)) << 24));
    } else if (destination.index != source) {
        source = makeNearSource(compiler, source);
        emitInstruction(compiler, opcode(constants.Opcode.move_far) |
            (@as(u32, @intCast(source)) << 8) |
            (@as(u32, @intCast(destination.index)) << 16));
    }
    return true;
}

fn makeNearSource(compiler: *compiler_primitives.JanetCompiler, source_value: i32) i32 {
    if (source_value <= 0xff) return source_value;
    const near_source = 0xf0 + @as(i32, @intCast(constants.JANETC_REGTEMP_5));
    emitInstruction(compiler, opcode(constants.Opcode.move_near) |
        (@as(u32, @intCast(near_source)) << 8) |
        (@as(u32, @intCast(source_value)) << 16));
    return near_source;
}

fn loadConstant(compiler: *compiler_primitives.JanetCompiler, val: repr.Value, register: i32) bool {
    const register_bits = @as(u32, @intCast(register)) << 8;
    switch (repr.typeOf(val)) {
        repr.Tag.nil => emitInstruction(compiler, opcode(constants.Opcode.load_nil) | register_bits),
        repr.Tag.boolean => emitInstruction(
            compiler,
            opcode(if (wrap.toBoolean(val)) constants.Opcode.load_true else constants.Opcode.load_false) | register_bits,
        ),
        repr.Tag.number => {
            if (args_core.checkint16(val)) {
                const integer: i32 = @intFromFloat(wrap.toNumber(val));
                const integer_bits: u32 = @bitCast(integer);
                emitInstruction(compiler, opcode(constants.Opcode.load_integer) | register_bits | (integer_bits << 16));
            } else {
                return loadFromConstantPool(compiler, val, register_bits);
            }
        },
        else => return loadFromConstantPool(compiler, val, register_bits),
    }
    return true;
}

fn loadFromConstantPool(compiler: *compiler_primitives.JanetCompiler, val: repr.Value, register_bits: u32) bool {
    const index = internConstant(compiler, val) orelse return false;
    emitInstruction(compiler, opcode(constants.Opcode.load_constant) |
        register_bits |
        (@as(u32, @intCast(index)) << 16));
    return true;
}

fn internConstant(compiler: *compiler_primitives.JanetCompiler, val: repr.Value) ?i32 {
    var scope = compiler.scope;
    while (scope) |current| {
        if (current.flags.function) break;
        scope = current.parent;
    }

    for (scope.?.consts.items, 0..) |constant, index| {
        if (order.equals(val, constant)) return @intCast(index);
    }
    const count = scope.?.consts.items.len;
    if (count >= 0xffff) return null;
    stretchy.push(&scope.?.consts, val);
    return @intCast(count);
}

fn slotsEqual(lhs: compiler_primitives.JanetSlot, rhs: compiler_primitives.JanetSlot) bool {
    return sequal(lhs, rhs);
}

fn emitInstruction(compiler: *compiler_primitives.JanetCompiler, instruction: u32) void {
    emit(compiler, instruction);
}

/// An opcode in the low byte of an instruction word, which is where the
/// bytecode puts it. This is the one place the enum becomes a number.
fn opcode(op: constants.Opcode) u32 {
    return op.number();
}
