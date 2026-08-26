//! Emitting one bytecode instruction, and the register bookkeeping around it.
//!
//! Ten entry points, one per operand shape, over five kernels. Phase 10 Part 7
//! removed the seam between them: until then the kernels returned an error
//! union, an error union cannot cross a subsystem seam, and so the five shapes
//! were squeezed through one `int`-returning C-ABI call with an enum to say
//! which -- and a small C wrapper in `emit.c` turned the code back into a
//! message. With the callers in Zig there is no seam, no enum, and no wrapper.
//!
//! Nothing here raises. The compiler front end reports by *flag*:
//! `janetc_error` sets `c->result.status`, keeps the first error, and returns,
//! so compilation continues and the user sees the first thing that went wrong
//! rather than the last.

const std = @import("std");
const order = @import("../value/helpers/order.zig");
const compiler_primitives = @import("../compiler.zig");
const vector_mod = @import("../stretchy.zig");
const regalloc = @import("regalloc.zig");
const kind = @import("../value/helpers/kind.zig");
const wrap = @import("../value/helpers/wrap.zig");
const args_core = @import("../args.zig");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");

const vector_header_size = 2 * @sizeOf(i32);
const slot_type_mask: u32 = constants.JANET_SLOTTYPE_ANY;
const EmitError = error{ TooManyConstants, TooManyRegisters };

/// Record an emit failure on the compiler and carry on.
///
/// Until Phase 10 Part 7 this switch was in `emit.c`, because the kernels
/// below returned an error union and an error union cannot cross a subsystem
/// seam: the five emit shapes were squeezed through one `int`-returning
/// C-ABI entry point and a small C wrapper turned the code back into a
/// message. With the callers in Zig there is no seam, and the mapping from an
/// error to its text sits next to the code that raises it.
///
/// This is not a raise. `janetc_error` sets `c->result.status` and returns;
/// the compiler front end reports by flag, and keeps compiling so that the
/// first error is the one the user sees. `janetc_cerror` is C's or
/// `compiler_primitives.zig`'s according to `-Dcompiler-primitives`, which is
/// why it is reached by its C name rather than imported.
fn report(compiler: *types.JanetCompiler, emit_error: EmitError) void {
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
pub fn allocfar(compiler: *types.JanetCompiler) i32 {
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
fn allocFar(compiler: *types.JanetCompiler) i32 {
    return regalloc.regalloc1(&compiler.scope.?.ra);
}

pub fn allocnear(
    compiler: *types.JanetCompiler,
    temporary: types.JanetcRegisterTemp,
) callconv(.c) i32 {
    return regalloc.regallocTemp(&compiler.scope.?.ra, temporary);
}

pub fn emit(compiler: *types.JanetCompiler, instruction: u32) void {
    pushVector(u32, &compiler.buffer, instruction);
    pushVector(types.JanetSourceMapping, &compiler.mapbuffer, compiler.current_mapping);
}

pub fn sequal(lhs: types.JanetSlot, rhs: types.JanetSlot) c_int {
    if ((lhs.flags & ~slot_type_mask) != (rhs.flags & ~slot_type_mask) or
        lhs.index != rhs.index or
        lhs.envindex != rhs.envindex)
    {
        return 0;
    }

    if (lhs.flags & (constants.JANET_SLOT_REF | constants.JANET_SLOT_CONSTANT) != 0) {
        return order.equals(lhs.constant, rhs.constant);
    }
    return 1;
}

/// `dest = src`, or an error recorded on the compiler.
pub fn copy(
    compiler: *types.JanetCompiler,
    destination: types.JanetSlot,
    source: types.JanetSlot,
) callconv(.c) void {
    if (destination.flags & constants.JANET_SLOT_CONSTANT != 0) {
        compiler_primitives.cerror(compiler, "cannot write to constant");
        return;
    }
    if (!copySlot(compiler, destination, source)) {
        compiler_primitives.cerror(compiler, "too many constants");
    }
}

fn copySlot(compiler: *types.JanetCompiler, destination: types.JanetSlot, source: types.JanetSlot) bool {
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
    compiler: *types.JanetCompiler,
    operation: u8,
    slot_value: types.JanetSlot,
    write_back: c_int,
) callconv(.c) i32 {
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
    compiler: *types.JanetCompiler,
    operation: u8,
    slot_value: types.JanetSlot,
    label: i32,
) callconv(.c) i32 {
    const current = vectorCount(u32, compiler.buffer) - 1;
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
    compiler: *types.JanetCompiler,
    operation: u8,
    slot_value: types.JanetSlot,
    typeflags: i32,
) callconv(.c) i32 {
    return emitOneSlot(compiler, operation, slot_value, typeflags, false) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

pub fn emitSi(
    compiler: *types.JanetCompiler,
    operation: u8,
    slot_value: types.JanetSlot,
    immediate: i16,
    write_back: c_int,
) callconv(.c) i32 {
    return emitOneSlot(compiler, operation, slot_value, immediate, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

pub fn emitSu(
    compiler: *types.JanetCompiler,
    operation: u8,
    slot_value: types.JanetSlot,
    immediate: u16,
    write_back: c_int,
) callconv(.c) i32 {
    return emitOneSlot(compiler, operation, slot_value, immediate, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

pub fn emitSs(
    compiler: *types.JanetCompiler,
    operation: u8,
    slot1: types.JanetSlot,
    slot2: types.JanetSlot,
    write_back: c_int,
) callconv(.c) i32 {
    return emitSS(compiler, operation, slot1, slot2, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

pub fn emitSsi(
    compiler: *types.JanetCompiler,
    operation: u8,
    slot1: types.JanetSlot,
    slot2: types.JanetSlot,
    immediate: i8,
    write_back: c_int,
) callconv(.c) i32 {
    return emitTwoSlots(compiler, operation, slot1, slot2, immediate, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

pub fn emitSsu(
    compiler: *types.JanetCompiler,
    operation: u8,
    slot1: types.JanetSlot,
    slot2: types.JanetSlot,
    immediate: u8,
    write_back: c_int,
) callconv(.c) i32 {
    return emitTwoSlots(compiler, operation, slot1, slot2, immediate, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

pub fn emitSss(
    compiler: *types.JanetCompiler,
    operation: u8,
    slot1: types.JanetSlot,
    slot2: types.JanetSlot,
    slot3: types.JanetSlot,
    write_back: c_int,
) callconv(.c) i32 {
    return emitSSS(compiler, operation, slot1, slot2, slot3, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

fn emitS(compiler: *types.JanetCompiler, operation: u8, slot_value: types.JanetSlot, write_back: bool) EmitError!i32 {
    const register = try registerFar(compiler, slot_value, constants.JANETC_REGTEMP_0);
    const label = vectorCount(u32, compiler.buffer);
    emitInstruction(compiler, operation | (@as(u32, @intCast(register)) << 8));
    if (write_back and !moveBack(compiler, slot_value, register)) return error.TooManyConstants;
    freeRegister(compiler, slot_value, register, constants.JANETC_REGTEMP_0);
    return label;
}

fn emitOneSlot(
    compiler: *types.JanetCompiler,
    operation: u8,
    slot_value: types.JanetSlot,
    rest: i32,
    write_back: bool,
) EmitError!i32 {
    const register = try registerNear(compiler, slot_value, constants.JANETC_REGTEMP_0);
    const label = vectorCount(u32, compiler.buffer);
    const rest_bits: u32 = @bitCast(rest);
    emitInstruction(compiler, operation |
        (@as(u32, @intCast(register)) << 8) |
        (rest_bits << 16));
    if (write_back and !moveBack(compiler, slot_value, register)) return error.TooManyConstants;
    freeRegister(compiler, slot_value, register, constants.JANETC_REGTEMP_0);
    return label;
}

fn emitSS(
    compiler: *types.JanetCompiler,
    operation: u8,
    slot1: types.JanetSlot,
    slot2: types.JanetSlot,
    write_back: bool,
) EmitError!i32 {
    const register1 = try registerNear(compiler, slot1, constants.JANETC_REGTEMP_0);
    const register2 = registerFar(compiler, slot2, constants.JANETC_REGTEMP_1) catch |emit_error| {
        freeRegister(compiler, slot1, register1, constants.JANETC_REGTEMP_0);
        return emit_error;
    };
    const label = vectorCount(u32, compiler.buffer);
    emitInstruction(compiler, operation |
        (@as(u32, @intCast(register1)) << 8) |
        (@as(u32, @intCast(register2)) << 16));
    freeRegister(compiler, slot2, register2, constants.JANETC_REGTEMP_1);
    if (write_back and !moveBack(compiler, slot1, register1)) return error.TooManyConstants;
    freeRegister(compiler, slot1, register1, constants.JANETC_REGTEMP_0);
    return label;
}

fn emitTwoSlots(
    compiler: *types.JanetCompiler,
    operation: u8,
    slot1: types.JanetSlot,
    slot2: types.JanetSlot,
    rest: i32,
    write_back: bool,
) EmitError!i32 {
    const register1 = try registerNear(compiler, slot1, constants.JANETC_REGTEMP_0);
    const register2 = registerNear(compiler, slot2, constants.JANETC_REGTEMP_1) catch |emit_error| {
        freeRegister(compiler, slot1, register1, constants.JANETC_REGTEMP_0);
        return emit_error;
    };
    const label = vectorCount(u32, compiler.buffer);
    const rest_bits: u32 = @bitCast(rest);
    emitInstruction(compiler, operation |
        (@as(u32, @intCast(register1)) << 8) |
        (@as(u32, @intCast(register2)) << 16) |
        (rest_bits << 24));
    freeRegister(compiler, slot2, register2, constants.JANETC_REGTEMP_1);
    if (write_back and !moveBack(compiler, slot1, register1)) return error.TooManyConstants;
    freeRegister(compiler, slot1, register1, constants.JANETC_REGTEMP_0);
    return label;
}

fn emitSSS(
    compiler: *types.JanetCompiler,
    operation: u8,
    slot1: types.JanetSlot,
    slot2: types.JanetSlot,
    slot3: types.JanetSlot,
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
    const label = vectorCount(u32, compiler.buffer);
    emitInstruction(compiler, operation |
        (@as(u32, @intCast(register1)) << 8) |
        (@as(u32, @intCast(register2)) << 16) |
        (@as(u32, @intCast(register3)) << 24));
    freeRegister(compiler, slot2, register2, constants.JANETC_REGTEMP_1);
    freeRegister(compiler, slot3, register3, constants.JANETC_REGTEMP_2);
    if (write_back and !moveBack(compiler, slot1, register1)) return error.TooManyConstants;
    freeRegister(compiler, slot1, register1, constants.JANETC_REGTEMP_0);
    return label;
}

fn registerFar(compiler: *types.JanetCompiler, slot_value: types.JanetSlot, temporary: types.JanetcRegisterTemp) EmitError!i32 {
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
        emitInstruction(compiler, opcode(constants.JOP_MOVE_FAR) |
            (@as(u32, @intCast(near_register)) << 8) |
            (@as(u32, @intCast(far_register)) << 16));
        regalloc.regallocFreetemp(&compiler.scope.?.ra, near_register, temporary);
        return far_register;
    }

    regalloc.regallocFreetemp(&compiler.scope.?.ra, near_register, temporary);
    regalloc.regallocTouch(&compiler.scope.?.ra, near_register);
    return near_register;
}

fn registerNear(compiler: *types.JanetCompiler, slot_value: types.JanetSlot, temporary: types.JanetcRegisterTemp) EmitError!i32 {
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
    compiler: *types.JanetCompiler,
    slot_value: types.JanetSlot,
    register: i32,
    temporary: types.JanetcRegisterTemp,
) void {
    if (register != slot_value.index or
        slot_value.envindex >= 0 or
        slot_value.flags & (constants.JANET_SLOT_CONSTANT | constants.JANET_SLOT_REF) != 0)
    {
        regalloc.regallocFreetemp(&compiler.scope.?.ra, register, temporary);
    }
}

fn moveNear(compiler: *types.JanetCompiler, destination: i32, source: types.JanetSlot) bool {
    if (source.flags & (constants.JANET_SLOT_CONSTANT | constants.JANET_SLOT_REF) != 0) {
        if (!loadConstant(compiler, source.constant, destination)) return false;
        if (source.flags & constants.JANET_SLOT_REF != 0) {
            emitInstruction(compiler, opcode(constants.JOP_GET_INDEX) |
                (@as(u32, @intCast(destination)) << 8) |
                (@as(u32, @intCast(destination)) << 16));
        }
    } else if (source.envindex >= 0) {
        emitInstruction(compiler, opcode(constants.JOP_LOAD_UPVALUE) |
            (@as(u32, @intCast(destination)) << 8) |
            (@as(u32, @intCast(source.envindex)) << 16) |
            (@as(u32, @intCast(source.index)) << 24));
    } else if (source.index != destination) {
        emitInstruction(compiler, opcode(constants.JOP_MOVE_NEAR) |
            (@as(u32, @intCast(destination)) << 8) |
            (@as(u32, @intCast(source.index)) << 16));
    }
    return true;
}

fn moveBack(compiler: *types.JanetCompiler, destination: types.JanetSlot, source_value: i32) bool {
    var source = source_value;
    if (destination.flags & constants.JANET_SLOT_REF != 0) {
        const reference = regalloc.regallocTemp(&compiler.scope.?.ra, constants.JANETC_REGTEMP_5);
        if (!loadConstant(compiler, destination.constant, reference)) {
            regalloc.regallocFreetemp(&compiler.scope.?.ra, reference, constants.JANETC_REGTEMP_5);
            return false;
        }
        emitInstruction(compiler, opcode(constants.JOP_PUT_INDEX) |
            (@as(u32, @intCast(reference)) << 8) |
            (@as(u32, @intCast(source)) << 16));
        regalloc.regallocFreetemp(&compiler.scope.?.ra, reference, constants.JANETC_REGTEMP_5);
    } else if (destination.envindex >= 0) {
        source = makeNearSource(compiler, source);
        emitInstruction(compiler, opcode(constants.JOP_SET_UPVALUE) |
            (@as(u32, @intCast(source)) << 8) |
            (@as(u32, @intCast(destination.envindex)) << 16) |
            (@as(u32, @intCast(destination.index)) << 24));
    } else if (destination.index != source) {
        source = makeNearSource(compiler, source);
        emitInstruction(compiler, opcode(constants.JOP_MOVE_FAR) |
            (@as(u32, @intCast(source)) << 8) |
            (@as(u32, @intCast(destination.index)) << 16));
    }
    return true;
}

fn makeNearSource(compiler: *types.JanetCompiler, source_value: i32) i32 {
    if (source_value <= 0xff) return source_value;
    const near_source = 0xf0 + @as(i32, @intCast(constants.JANETC_REGTEMP_5));
    emitInstruction(compiler, opcode(constants.JOP_MOVE_NEAR) |
        (@as(u32, @intCast(near_source)) << 8) |
        (@as(u32, @intCast(source_value)) << 16));
    return near_source;
}

fn loadConstant(compiler: *types.JanetCompiler, val: types.Janet, register: i32) bool {
    const register_bits = @as(u32, @intCast(register)) << 8;
    switch (kind.typeOf(val)) {
        constants.JANET_NIL => emitInstruction(compiler, opcode(constants.JOP_LOAD_NIL) | register_bits),
        constants.JANET_BOOLEAN => emitInstruction(
            compiler,
            opcode(if (wrap.toBoolean(val) != 0) constants.JOP_LOAD_TRUE else constants.JOP_LOAD_FALSE) | register_bits,
        ),
        constants.JANET_NUMBER => {
            if (args_core.checkint16(val) != 0) {
                const integer: i32 = @intFromFloat(wrap.toNumber(val));
                const integer_bits: u32 = @bitCast(integer);
                emitInstruction(compiler, opcode(constants.JOP_LOAD_INTEGER) | register_bits | (integer_bits << 16));
            } else {
                return loadFromConstantPool(compiler, val, register_bits);
            }
        },
        else => return loadFromConstantPool(compiler, val, register_bits),
    }
    return true;
}

fn loadFromConstantPool(compiler: *types.JanetCompiler, val: types.Janet, register_bits: u32) bool {
    const index = internConstant(compiler, val) orelse return false;
    emitInstruction(compiler, opcode(constants.JOP_LOAD_CONSTANT) |
        register_bits |
        (@as(u32, @intCast(index)) << 16));
    return true;
}

fn internConstant(compiler: *types.JanetCompiler, val: types.Janet) ?i32 {
    var scope = compiler.scope;
    while (scope) |current| {
        if (current.flags & constants.JANET_SCOPE_FUNCTION != 0) break;
        scope = current.parent;
    }

    const count = vectorCount(types.Janet, scope.?.consts);
    var index: i32 = 0;
    while (index < count) : (index += 1) {
        if (order.equals(val, scope.?.consts.?[@intCast(index)]) != 0) return index;
    }
    if (count >= 0xffff) return null;
    pushVector(types.Janet, &scope.?.consts, val);
    return count;
}

fn slotsEqual(lhs: types.JanetSlot, rhs: types.JanetSlot) bool {
    return sequal(lhs, rhs) != 0;
}

fn emitInstruction(compiler: *types.JanetCompiler, instruction: u32) void {
    emit(compiler, instruction);
}

fn opcode(val: c_int) u32 {
    return @intCast(val);
}

fn pushVector(comptime Element: type, vector_pointer: *?[*]Element, val: Element) void {
    var vector = vector_pointer.*;
    const count = vectorCount(Element, vector);
    if (vector == null or count + 1 >= vectorCapacity(Element, vector.?)) {
        const grown = vector_mod.vGrow(if (vector) |v| @ptrCast(v) else null, 1, @sizeOf(Element));
        vector = @ptrCast(@alignCast(grown));
        vector_pointer.* = vector;
    }
    vector.?[@intCast(count)] = val;
    vectorHeader(Element, vector.?)[1] = count + 1;
}

fn vectorCount(comptime Element: type, vector: ?[*]Element) i32 {
    return if (vector) |v| vectorHeader(Element, v)[1] else 0;
}

fn vectorCapacity(comptime Element: type, vector: [*]Element) i32 {
    return vectorHeader(Element, vector)[0];
}

fn vectorHeader(comptime Element: type, vector: [*]Element) [*]i32 {
    return @ptrFromInt(@intFromPtr(vector) - vector_header_size);
}
