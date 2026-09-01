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
const scratch_vector = @import("../scratch_vector.zig");
const wrap = @import("../value/helpers/wrap.zig");
const args_core = @import("../args.zig");
const repr = @import("repr");
const constants = @import("constants");

/// `compiler.scope`, with the invariant that it is open named once in
/// `compiler.zig`.
const currentScope = compiler_primitives.currentScope;

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
fn report(compiler: *compiler_primitives.Compiler, emit_error: EmitError) void {
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
pub fn allocfar(compiler: *compiler_primitives.Compiler) i32 {
    const register = allocFar(compiler);
    if (register > 0xFFFF) {
        compiler_primitives.cerror(compiler, "ran out of internal registers");
    }
    return @intCast(register);
}

/// The allocation without the ceiling check. `registerFar` below has its own
/// caller to unwind before it can report, so it takes the raw number and
/// answers `error.TooManyRegisters`, which `report` renders as the same
/// message. The C original reaches `janetc_allocfar` there and lets the
/// second report be swallowed by "keep the first error"; this says the same
/// thing once.
fn allocFar(compiler: *compiler_primitives.Compiler) u32 {
    return currentScope(compiler).ra.allocate();
}

pub fn allocnear(
    compiler: *compiler_primitives.Compiler,
    temporary: constants.RegisterTemp,
) u8 {
    return currentScope(compiler).ra.allocateTemp(temporary);
}

pub fn emit(compiler: *compiler_primitives.Compiler, instruction: u32) void {
    scratch_vector.push(&compiler.buffer, instruction);
    scratch_vector.push(&compiler.mapbuffer, compiler.current_mapping);
}

pub fn sequal(lhs: compiler_primitives.Slot, rhs: compiler_primitives.Slot) bool {
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
    compiler: *compiler_primitives.Compiler,
    destination: compiler_primitives.Slot,
    source: compiler_primitives.Slot,
) void {
    if (destination.flags.constant) {
        compiler_primitives.cerror(compiler, "cannot write to constant");
        return;
    }
    if (!copySlot(compiler, destination, source)) {
        compiler_primitives.cerror(compiler, "too many constants");
    }
}

fn copySlot(compiler: *compiler_primitives.Compiler, destination: compiler_primitives.Slot, source: compiler_primitives.Slot) bool {
    if (slotsEqual(destination, source)) return true;

    if (destination.envindex < 0 and destination.index >= 0 and destination.index <= 0xff) {
        return moveNear(compiler, @intCast(destination.index), source);
    }
    if (source.envindex < 0 and source.index >= 0 and source.index <= 0xff) {
        return moveBack(compiler, destination, @intCast(source.index));
    }

    const temporary = currentScope(compiler).ra.allocateTemp(constants.RegisterTemp.t3);
    if (!moveNear(compiler, temporary, source)) {
        currentScope(compiler).ra.freeTemp(temporary, constants.RegisterTemp.t3);
        return false;
    }
    const success = moveBack(compiler, destination, temporary);
    currentScope(compiler).ra.freeTemp(temporary, constants.RegisterTemp.t3);
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
    compiler: *compiler_primitives.Compiler,
    operation: constants.Opcode,
    slot_value: compiler_primitives.Slot,
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
    compiler: *compiler_primitives.Compiler,
    operation: constants.Opcode,
    slot_value: compiler_primitives.Slot,
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
    compiler: *compiler_primitives.Compiler,
    operation: constants.Opcode,
    slot_value: compiler_primitives.Slot,
    typeflags: i32,
) i32 {
    return emitOneSlot(compiler, operation, slot_value, typeflags, false) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

pub fn emitSi(
    compiler: *compiler_primitives.Compiler,
    operation: constants.Opcode,
    slot_value: compiler_primitives.Slot,
    immediate: i16,
    write_back: c_int,
) i32 {
    return emitOneSlot(compiler, operation, slot_value, immediate, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

pub fn emitSu(
    compiler: *compiler_primitives.Compiler,
    operation: constants.Opcode,
    slot_value: compiler_primitives.Slot,
    immediate: u16,
    write_back: c_int,
) i32 {
    return emitOneSlot(compiler, operation, slot_value, immediate, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

pub fn emitSs(
    compiler: *compiler_primitives.Compiler,
    operation: constants.Opcode,
    slot1: compiler_primitives.Slot,
    slot2: compiler_primitives.Slot,
    write_back: c_int,
) i32 {
    return emitSS(compiler, operation, slot1, slot2, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

pub fn emitSsi(
    compiler: *compiler_primitives.Compiler,
    operation: constants.Opcode,
    slot1: compiler_primitives.Slot,
    slot2: compiler_primitives.Slot,
    immediate: i8,
    write_back: c_int,
) i32 {
    return emitTwoSlots(compiler, operation, slot1, slot2, immediate, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

pub fn emitSsu(
    compiler: *compiler_primitives.Compiler,
    operation: constants.Opcode,
    slot1: compiler_primitives.Slot,
    slot2: compiler_primitives.Slot,
    immediate: u8,
    write_back: c_int,
) i32 {
    return emitTwoSlots(compiler, operation, slot1, slot2, immediate, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

pub fn emitSss(
    compiler: *compiler_primitives.Compiler,
    operation: constants.Opcode,
    slot1: compiler_primitives.Slot,
    slot2: compiler_primitives.Slot,
    slot3: compiler_primitives.Slot,
    write_back: c_int,
) i32 {
    return emitSSS(compiler, operation, slot1, slot2, slot3, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

fn emitS(compiler: *compiler_primitives.Compiler, operation: constants.Opcode, slot_value: compiler_primitives.Slot, write_back: bool) EmitError!i32 {
    const register = try registerFar(compiler, slot_value, constants.RegisterTemp.t0);
    const label = compiler.here();
    emitInstruction(compiler, opcode(operation) | (@as(u32, register) << 8));
    if (write_back and !moveBack(compiler, slot_value, register)) return error.TooManyConstants;
    freeRegister(compiler, slot_value, register, constants.RegisterTemp.t0);
    return label;
}

fn emitOneSlot(
    compiler: *compiler_primitives.Compiler,
    operation: constants.Opcode,
    slot_value: compiler_primitives.Slot,
    rest: i32,
    write_back: bool,
) EmitError!i32 {
    const register = try registerNear(compiler, slot_value, constants.RegisterTemp.t0);
    const label = compiler.here();
    const rest_bits: u32 = @bitCast(rest);
    emitInstruction(compiler, opcode(operation) |
        (@as(u32, register) << 8) |
        (rest_bits << 16));
    if (write_back and !moveBack(compiler, slot_value, register)) return error.TooManyConstants;
    freeRegister(compiler, slot_value, register, constants.RegisterTemp.t0);
    return label;
}

fn emitSS(
    compiler: *compiler_primitives.Compiler,
    operation: constants.Opcode,
    slot1: compiler_primitives.Slot,
    slot2: compiler_primitives.Slot,
    write_back: bool,
) EmitError!i32 {
    const register1 = try registerNear(compiler, slot1, constants.RegisterTemp.t0);
    const register2 = registerFar(compiler, slot2, constants.RegisterTemp.t1) catch |emit_error| {
        freeRegister(compiler, slot1, register1, constants.RegisterTemp.t0);
        return emit_error;
    };
    const label = compiler.here();
    emitInstruction(compiler, opcode(operation) |
        (@as(u32, register1) << 8) |
        (@as(u32, register2) << 16));
    freeRegister(compiler, slot2, register2, constants.RegisterTemp.t1);
    if (write_back and !moveBack(compiler, slot1, register1)) return error.TooManyConstants;
    freeRegister(compiler, slot1, register1, constants.RegisterTemp.t0);
    return label;
}

fn emitTwoSlots(
    compiler: *compiler_primitives.Compiler,
    operation: constants.Opcode,
    slot1: compiler_primitives.Slot,
    slot2: compiler_primitives.Slot,
    rest: i32,
    write_back: bool,
) EmitError!i32 {
    const register1 = try registerNear(compiler, slot1, constants.RegisterTemp.t0);
    const register2 = registerNear(compiler, slot2, constants.RegisterTemp.t1) catch |emit_error| {
        freeRegister(compiler, slot1, register1, constants.RegisterTemp.t0);
        return emit_error;
    };
    const label = compiler.here();
    const rest_bits: u32 = @bitCast(rest);
    emitInstruction(compiler, opcode(operation) |
        (@as(u32, register1) << 8) |
        (@as(u32, register2) << 16) |
        (rest_bits << 24));
    freeRegister(compiler, slot2, register2, constants.RegisterTemp.t1);
    if (write_back and !moveBack(compiler, slot1, register1)) return error.TooManyConstants;
    freeRegister(compiler, slot1, register1, constants.RegisterTemp.t0);
    return label;
}

fn emitSSS(
    compiler: *compiler_primitives.Compiler,
    operation: constants.Opcode,
    slot1: compiler_primitives.Slot,
    slot2: compiler_primitives.Slot,
    slot3: compiler_primitives.Slot,
    write_back: bool,
) EmitError!i32 {
    const register1 = try registerNear(compiler, slot1, constants.RegisterTemp.t0);
    const register2 = registerNear(compiler, slot2, constants.RegisterTemp.t1) catch |emit_error| {
        freeRegister(compiler, slot1, register1, constants.RegisterTemp.t0);
        return emit_error;
    };
    const register3 = registerNear(compiler, slot3, constants.RegisterTemp.t2) catch |emit_error| {
        freeRegister(compiler, slot2, register2, constants.RegisterTemp.t1);
        freeRegister(compiler, slot1, register1, constants.RegisterTemp.t0);
        return emit_error;
    };
    const label = compiler.here();
    emitInstruction(compiler, opcode(operation) |
        (@as(u32, register1) << 8) |
        (@as(u32, register2) << 16) |
        (@as(u32, register3) << 24));
    freeRegister(compiler, slot2, register2, constants.RegisterTemp.t1);
    freeRegister(compiler, slot3, register3, constants.RegisterTemp.t2);
    if (write_back and !moveBack(compiler, slot1, register1)) return error.TooManyConstants;
    freeRegister(compiler, slot1, register1, constants.RegisterTemp.t0);
    return label;
}

fn registerFar(compiler: *compiler_primitives.Compiler, slot_value: compiler_primitives.Slot, temporary: constants.RegisterTemp) EmitError!u16 {
    // `@truncate`, not `@intCast`: a slot's index can exceed `0xffff` after
    // `allocfar` has already reported "ran out of internal registers", and the
    // instruction word C builds keeps the low sixteen bits of it. The compile
    // has failed by then and the bytecode is never run; trapping here would
    // replace a reported compile error with a panic.
    if (slot_value.envindex < 0 and slot_value.index >= 0) {
        return @truncate(@as(u32, @bitCast(slot_value.index)));
    }

    const near_register = currentScope(compiler).ra.allocateTemp(temporary);
    if (!moveNear(compiler, near_register, slot_value)) {
        currentScope(compiler).ra.freeTemp(near_register, temporary);
        return error.TooManyConstants;
    }
    if (near_register >= 0xf0) {
        const far_register = allocFar(compiler);
        if (far_register > 0xffff) {
            currentScope(compiler).ra.freeTemp(near_register, temporary);
            return error.TooManyRegisters;
        }
        emitInstruction(compiler, opcode(constants.Opcode.move_far) |
            (@as(u32, near_register) << 8) |
            (far_register << 16));
        currentScope(compiler).ra.freeTemp(near_register, temporary);
        return @intCast(far_register);
    }

    currentScope(compiler).ra.freeTemp(near_register, temporary);
    currentScope(compiler).ra.touch(near_register);
    return near_register;
}

fn registerNear(compiler: *compiler_primitives.Compiler, slot_value: compiler_primitives.Slot, temporary: constants.RegisterTemp) EmitError!u8 {
    if (slot_value.envindex < 0 and slot_value.index >= 0 and slot_value.index <= 0xff) {
        return @intCast(slot_value.index);
    }
    const register = currentScope(compiler).ra.allocateTemp(temporary);
    if (!moveNear(compiler, register, slot_value)) {
        currentScope(compiler).ra.freeTemp(register, temporary);
        return error.TooManyConstants;
    }
    return register;
}

fn freeRegister(
    compiler: *compiler_primitives.Compiler,
    slot_value: compiler_primitives.Slot,
    register: u16,
    temporary: constants.RegisterTemp,
) void {
    if (register != slot_value.index or
        slot_value.envindex >= 0 or
        (slot_value.flags.constant or slot_value.flags.ref))
    {
        currentScope(compiler).ra.freeTemp(register, temporary);
    }
}

fn moveNear(compiler: *compiler_primitives.Compiler, destination: u8, source: compiler_primitives.Slot) bool {
    if (source.flags.constant or source.flags.ref) {
        if (!loadConstant(compiler, source.constant, destination)) return false;
        if (source.flags.ref) {
            emitInstruction(compiler, opcode(constants.Opcode.get_index) |
                (@as(u32, destination) << 8) |
                (@as(u32, destination) << 16));
        }
    } else if (source.envindex >= 0) {
        emitInstruction(compiler, opcode(constants.Opcode.load_upvalue) |
            (@as(u32, destination) << 8) |
            (@as(u32, @intCast(source.envindex)) << 16) |
            (@as(u32, @intCast(source.index)) << 24));
    } else if (source.index != destination) {
        emitInstruction(compiler, opcode(constants.Opcode.move_near) |
            (@as(u32, destination) << 8) |
            (@as(u32, @intCast(source.index)) << 16));
    }
    return true;
}

fn moveBack(compiler: *compiler_primitives.Compiler, destination: compiler_primitives.Slot, source_value: u16) bool {
    var source: u16 = source_value;
    if (destination.flags.ref) {
        const reference = currentScope(compiler).ra.allocateTemp(constants.RegisterTemp.t5);
        if (!loadConstant(compiler, destination.constant, reference)) {
            currentScope(compiler).ra.freeTemp(reference, constants.RegisterTemp.t5);
            return false;
        }
        emitInstruction(compiler, opcode(constants.Opcode.put_index) |
            (@as(u32, reference) << 8) |
            (@as(u32, source) << 16));
        currentScope(compiler).ra.freeTemp(reference, constants.RegisterTemp.t5);
    } else if (destination.envindex >= 0) {
        source = makeNearSource(compiler, source);
        emitInstruction(compiler, opcode(constants.Opcode.set_upvalue) |
            (@as(u32, source) << 8) |
            (@as(u32, @intCast(destination.envindex)) << 16) |
            (@as(u32, @intCast(destination.index)) << 24));
    } else if (destination.index != source) {
        source = makeNearSource(compiler, source);
        emitInstruction(compiler, opcode(constants.Opcode.move_far) |
            (@as(u32, source) << 8) |
            (@as(u32, @intCast(destination.index)) << 16));
    }
    return true;
}

fn makeNearSource(compiler: *compiler_primitives.Compiler, source_value: u16) u8 {
    if (source_value <= 0xff) return @intCast(source_value);
    const near_source: u8 = 0xf0 + @as(u8, @intFromEnum(constants.RegisterTemp.t5));
    emitInstruction(compiler, opcode(constants.Opcode.move_near) |
        (@as(u32, near_source) << 8) |
        (@as(u32, source_value) << 16));
    return near_source;
}

fn loadConstant(compiler: *compiler_primitives.Compiler, val: repr.Value, register: u8) bool {
    const register_bits = @as(u32, register) << 8;
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

fn loadFromConstantPool(compiler: *compiler_primitives.Compiler, val: repr.Value, register_bits: u32) bool {
    const index = internConstant(compiler, val) orelse return false;
    emitInstruction(compiler, opcode(constants.Opcode.load_constant) |
        register_bits |
        (@as(u32, index) << 16));
    return true;
}

fn internConstant(compiler: *compiler_primitives.Compiler, val: repr.Value) ?u16 {
    var scope = compiler.scope;
    while (scope) |current| {
        if (current.flags.function) break;
        scope = current.parent;
    }

    // The walk above stops on a function scope or runs out of scopes, and it
    // cannot run out: `compileLintImpl` pushes the root scope with
    // `.function = true` before any value is compiled, so every scope chain a
    // constant is interned from ends in one.
    const function_scope = scope orelse unreachable;

    for (function_scope.consts.items, 0..) |constant, index| {
        if (order.equals(val, constant)) return @intCast(index);
    }
    const count = function_scope.consts.items.len;
    if (count >= 0xffff) return null;
    scratch_vector.push(&function_scope.consts, val);
    return @intCast(count);
}

fn slotsEqual(lhs: compiler_primitives.Slot, rhs: compiler_primitives.Slot) bool {
    return sequal(lhs, rhs);
}

fn emitInstruction(compiler: *compiler_primitives.Compiler, instruction: u32) void {
    emit(compiler, instruction);
}

/// An opcode in the low byte of an instruction word, which is where the
/// bytecode puts it. This is the one place the enum becomes a number.
fn opcode(op: constants.Opcode) u32 {
    return op.number();
}
