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
const abi = @import("abi");
const c = abi.c;

const vector_header_size = 2 * @sizeOf(i32);
const slot_type_mask: u32 = c.JANET_SLOTTYPE_ANY;
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
fn report(compiler: *c.JanetCompiler, emit_error: EmitError) void {
    switch (emit_error) {
        error.TooManyConstants => c.janetc_cerror(compiler, "too many constants"),
        error.TooManyRegisters => c.janetc_cerror(compiler, "ran out of internal registers"),
    }
}

/// A far register, or an error recorded on the compiler.
///
/// `janetc_regalloc_1` allocates from the whole 32-bit space and the
/// instruction encoding has sixteen bits for a far slot, so the ceiling is
/// checked here rather than in the allocator.
export fn janetc_allocfar(compiler: *c.JanetCompiler) callconv(.c) i32 {
    const register = allocFar(compiler);
    if (register > 0xFFFF) {
        c.janetc_cerror(compiler, "ran out of internal registers");
    }
    return register;
}

/// The allocation without the ceiling check. `registerFar` below has its own
/// caller to unwind before it can report, so it takes the raw number and
/// answers `error.TooManyRegisters`, which `report` renders as the same
/// message. The C original reaches `janetc_allocfar` there and lets the
/// second report be swallowed by "keep the first error"; this says the same
/// thing once.
fn allocFar(compiler: *c.JanetCompiler) i32 {
    return c.janetc_regalloc_1(&compiler.scope.*.ra);
}

export fn janetc_allocnear(
    compiler: *c.JanetCompiler,
    temporary: c.JanetcRegisterTemp,
) callconv(.c) i32 {
    return c.janetc_regalloc_temp(&compiler.scope.*.ra, temporary);
}

export fn janetc_emit(compiler: *c.JanetCompiler, instruction: u32) callconv(.c) void {
    pushVector(u32, &compiler.buffer, instruction);
    pushVector(c.JanetSourceMapping, &compiler.mapbuffer, compiler.current_mapping);
}

export fn janetc_sequal(lhs: c.JanetSlot, rhs: c.JanetSlot) callconv(.c) c_int {
    if ((lhs.flags & ~slot_type_mask) != (rhs.flags & ~slot_type_mask) or
        lhs.index != rhs.index or
        lhs.envindex != rhs.envindex)
    {
        return 0;
    }

    if (lhs.flags & (c.JANET_SLOT_REF | c.JANET_SLOT_CONSTANT) != 0) {
        return c.janet_equals(lhs.constant, rhs.constant);
    }
    return 1;
}

/// `dest = src`, or an error recorded on the compiler.
export fn janetc_copy(
    compiler: *c.JanetCompiler,
    destination: c.JanetSlot,
    source: c.JanetSlot,
) callconv(.c) void {
    if (destination.flags & c.JANET_SLOT_CONSTANT != 0) {
        c.janetc_cerror(compiler, "cannot write to constant");
        return;
    }
    if (!copySlot(compiler, destination, source)) {
        c.janetc_cerror(compiler, "too many constants");
    }
}

fn copySlot(compiler: *c.JanetCompiler, destination: c.JanetSlot, source: c.JanetSlot) bool {
    if (slotsEqual(destination, source)) return true;

    if (destination.envindex < 0 and destination.index >= 0 and destination.index <= 0xff) {
        return moveNear(compiler, destination.index, source);
    }
    if (source.envindex < 0 and source.index >= 0 and source.index <= 0xff) {
        return moveBack(compiler, destination, source.index);
    }

    const temporary = c.janetc_regalloc_temp(&compiler.scope.*.ra, c.JANETC_REGTEMP_3);
    if (!moveNear(compiler, temporary, source)) {
        c.janetc_regalloc_freetemp(&compiler.scope.*.ra, temporary, c.JANETC_REGTEMP_3);
        return false;
    }
    const success = moveBack(compiler, destination, temporary);
    c.janetc_regalloc_freetemp(&compiler.scope.*.ra, temporary, c.JANETC_REGTEMP_3);
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
export fn janetc_emit_s(
    compiler: *c.JanetCompiler,
    operation: u8,
    slot_value: c.JanetSlot,
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
export fn janetc_emit_sl(
    compiler: *c.JanetCompiler,
    operation: u8,
    slot_value: c.JanetSlot,
    label: i32,
) callconv(.c) i32 {
    const current = vectorCount(u32, compiler.buffer) - 1;
    const jump = label - current;
    if (jump < std.math.minInt(i16) or jump > std.math.maxInt(i16)) {
        c.janetc_cerror(compiler, "jump is too far");
    }
    return emitOneSlot(compiler, operation, slot_value, jump, false) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

export fn janetc_emit_st(
    compiler: *c.JanetCompiler,
    operation: u8,
    slot_value: c.JanetSlot,
    typeflags: i32,
) callconv(.c) i32 {
    return emitOneSlot(compiler, operation, slot_value, typeflags, false) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

export fn janetc_emit_si(
    compiler: *c.JanetCompiler,
    operation: u8,
    slot_value: c.JanetSlot,
    immediate: i16,
    write_back: c_int,
) callconv(.c) i32 {
    return emitOneSlot(compiler, operation, slot_value, immediate, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

export fn janetc_emit_su(
    compiler: *c.JanetCompiler,
    operation: u8,
    slot_value: c.JanetSlot,
    immediate: u16,
    write_back: c_int,
) callconv(.c) i32 {
    return emitOneSlot(compiler, operation, slot_value, immediate, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

export fn janetc_emit_ss(
    compiler: *c.JanetCompiler,
    operation: u8,
    slot1: c.JanetSlot,
    slot2: c.JanetSlot,
    write_back: c_int,
) callconv(.c) i32 {
    return emitSS(compiler, operation, slot1, slot2, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

export fn janetc_emit_ssi(
    compiler: *c.JanetCompiler,
    operation: u8,
    slot1: c.JanetSlot,
    slot2: c.JanetSlot,
    immediate: i8,
    write_back: c_int,
) callconv(.c) i32 {
    return emitTwoSlots(compiler, operation, slot1, slot2, immediate, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

export fn janetc_emit_ssu(
    compiler: *c.JanetCompiler,
    operation: u8,
    slot1: c.JanetSlot,
    slot2: c.JanetSlot,
    immediate: u8,
    write_back: c_int,
) callconv(.c) i32 {
    return emitTwoSlots(compiler, operation, slot1, slot2, immediate, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

export fn janetc_emit_sss(
    compiler: *c.JanetCompiler,
    operation: u8,
    slot1: c.JanetSlot,
    slot2: c.JanetSlot,
    slot3: c.JanetSlot,
    write_back: c_int,
) callconv(.c) i32 {
    return emitSSS(compiler, operation, slot1, slot2, slot3, write_back != 0) catch |emit_error| {
        report(compiler, emit_error);
        return 0;
    };
}

fn emitS(compiler: *c.JanetCompiler, operation: u8, slot_value: c.JanetSlot, write_back: bool) EmitError!i32 {
    const register = try registerFar(compiler, slot_value, c.JANETC_REGTEMP_0);
    const label = vectorCount(u32, compiler.buffer);
    emitInstruction(compiler, operation | (@as(u32, @intCast(register)) << 8));
    if (write_back and !moveBack(compiler, slot_value, register)) return error.TooManyConstants;
    freeRegister(compiler, slot_value, register, c.JANETC_REGTEMP_0);
    return label;
}

fn emitOneSlot(
    compiler: *c.JanetCompiler,
    operation: u8,
    slot_value: c.JanetSlot,
    rest: i32,
    write_back: bool,
) EmitError!i32 {
    const register = try registerNear(compiler, slot_value, c.JANETC_REGTEMP_0);
    const label = vectorCount(u32, compiler.buffer);
    const rest_bits: u32 = @bitCast(rest);
    emitInstruction(compiler, operation |
        (@as(u32, @intCast(register)) << 8) |
        (rest_bits << 16));
    if (write_back and !moveBack(compiler, slot_value, register)) return error.TooManyConstants;
    freeRegister(compiler, slot_value, register, c.JANETC_REGTEMP_0);
    return label;
}

fn emitSS(
    compiler: *c.JanetCompiler,
    operation: u8,
    slot1: c.JanetSlot,
    slot2: c.JanetSlot,
    write_back: bool,
) EmitError!i32 {
    const register1 = try registerNear(compiler, slot1, c.JANETC_REGTEMP_0);
    const register2 = registerFar(compiler, slot2, c.JANETC_REGTEMP_1) catch |emit_error| {
        freeRegister(compiler, slot1, register1, c.JANETC_REGTEMP_0);
        return emit_error;
    };
    const label = vectorCount(u32, compiler.buffer);
    emitInstruction(compiler, operation |
        (@as(u32, @intCast(register1)) << 8) |
        (@as(u32, @intCast(register2)) << 16));
    freeRegister(compiler, slot2, register2, c.JANETC_REGTEMP_1);
    if (write_back and !moveBack(compiler, slot1, register1)) return error.TooManyConstants;
    freeRegister(compiler, slot1, register1, c.JANETC_REGTEMP_0);
    return label;
}

fn emitTwoSlots(
    compiler: *c.JanetCompiler,
    operation: u8,
    slot1: c.JanetSlot,
    slot2: c.JanetSlot,
    rest: i32,
    write_back: bool,
) EmitError!i32 {
    const register1 = try registerNear(compiler, slot1, c.JANETC_REGTEMP_0);
    const register2 = registerNear(compiler, slot2, c.JANETC_REGTEMP_1) catch |emit_error| {
        freeRegister(compiler, slot1, register1, c.JANETC_REGTEMP_0);
        return emit_error;
    };
    const label = vectorCount(u32, compiler.buffer);
    const rest_bits: u32 = @bitCast(rest);
    emitInstruction(compiler, operation |
        (@as(u32, @intCast(register1)) << 8) |
        (@as(u32, @intCast(register2)) << 16) |
        (rest_bits << 24));
    freeRegister(compiler, slot2, register2, c.JANETC_REGTEMP_1);
    if (write_back and !moveBack(compiler, slot1, register1)) return error.TooManyConstants;
    freeRegister(compiler, slot1, register1, c.JANETC_REGTEMP_0);
    return label;
}

fn emitSSS(
    compiler: *c.JanetCompiler,
    operation: u8,
    slot1: c.JanetSlot,
    slot2: c.JanetSlot,
    slot3: c.JanetSlot,
    write_back: bool,
) EmitError!i32 {
    const register1 = try registerNear(compiler, slot1, c.JANETC_REGTEMP_0);
    const register2 = registerNear(compiler, slot2, c.JANETC_REGTEMP_1) catch |emit_error| {
        freeRegister(compiler, slot1, register1, c.JANETC_REGTEMP_0);
        return emit_error;
    };
    const register3 = registerNear(compiler, slot3, c.JANETC_REGTEMP_2) catch |emit_error| {
        freeRegister(compiler, slot2, register2, c.JANETC_REGTEMP_1);
        freeRegister(compiler, slot1, register1, c.JANETC_REGTEMP_0);
        return emit_error;
    };
    const label = vectorCount(u32, compiler.buffer);
    emitInstruction(compiler, operation |
        (@as(u32, @intCast(register1)) << 8) |
        (@as(u32, @intCast(register2)) << 16) |
        (@as(u32, @intCast(register3)) << 24));
    freeRegister(compiler, slot2, register2, c.JANETC_REGTEMP_1);
    freeRegister(compiler, slot3, register3, c.JANETC_REGTEMP_2);
    if (write_back and !moveBack(compiler, slot1, register1)) return error.TooManyConstants;
    freeRegister(compiler, slot1, register1, c.JANETC_REGTEMP_0);
    return label;
}

fn registerFar(compiler: *c.JanetCompiler, slot_value: c.JanetSlot, temporary: c.JanetcRegisterTemp) EmitError!i32 {
    if (slot_value.envindex < 0 and slot_value.index >= 0) return slot_value.index;

    const near_register = c.janetc_regalloc_temp(&compiler.scope.*.ra, temporary);
    if (!moveNear(compiler, near_register, slot_value)) {
        c.janetc_regalloc_freetemp(&compiler.scope.*.ra, near_register, temporary);
        return error.TooManyConstants;
    }
    if (near_register >= 0xf0) {
        const far_register = allocFar(compiler);
        if (far_register > 0xffff) {
            c.janetc_regalloc_freetemp(&compiler.scope.*.ra, near_register, temporary);
            return error.TooManyRegisters;
        }
        emitInstruction(compiler, opcode(c.JOP_MOVE_FAR) |
            (@as(u32, @intCast(near_register)) << 8) |
            (@as(u32, @intCast(far_register)) << 16));
        c.janetc_regalloc_freetemp(&compiler.scope.*.ra, near_register, temporary);
        return far_register;
    }

    c.janetc_regalloc_freetemp(&compiler.scope.*.ra, near_register, temporary);
    c.janetc_regalloc_touch(&compiler.scope.*.ra, near_register);
    return near_register;
}

fn registerNear(compiler: *c.JanetCompiler, slot_value: c.JanetSlot, temporary: c.JanetcRegisterTemp) EmitError!i32 {
    if (slot_value.envindex < 0 and slot_value.index >= 0 and slot_value.index <= 0xff) {
        return slot_value.index;
    }
    const register = c.janetc_regalloc_temp(&compiler.scope.*.ra, temporary);
    if (!moveNear(compiler, register, slot_value)) {
        c.janetc_regalloc_freetemp(&compiler.scope.*.ra, register, temporary);
        return error.TooManyConstants;
    }
    return register;
}

fn freeRegister(
    compiler: *c.JanetCompiler,
    slot_value: c.JanetSlot,
    register: i32,
    temporary: c.JanetcRegisterTemp,
) void {
    if (register != slot_value.index or
        slot_value.envindex >= 0 or
        slot_value.flags & (c.JANET_SLOT_CONSTANT | c.JANET_SLOT_REF) != 0)
    {
        c.janetc_regalloc_freetemp(&compiler.scope.*.ra, register, temporary);
    }
}

fn moveNear(compiler: *c.JanetCompiler, destination: i32, source: c.JanetSlot) bool {
    if (source.flags & (c.JANET_SLOT_CONSTANT | c.JANET_SLOT_REF) != 0) {
        if (!loadConstant(compiler, source.constant, destination)) return false;
        if (source.flags & c.JANET_SLOT_REF != 0) {
            emitInstruction(compiler, opcode(c.JOP_GET_INDEX) |
                (@as(u32, @intCast(destination)) << 8) |
                (@as(u32, @intCast(destination)) << 16));
        }
    } else if (source.envindex >= 0) {
        emitInstruction(compiler, opcode(c.JOP_LOAD_UPVALUE) |
            (@as(u32, @intCast(destination)) << 8) |
            (@as(u32, @intCast(source.envindex)) << 16) |
            (@as(u32, @intCast(source.index)) << 24));
    } else if (source.index != destination) {
        emitInstruction(compiler, opcode(c.JOP_MOVE_NEAR) |
            (@as(u32, @intCast(destination)) << 8) |
            (@as(u32, @intCast(source.index)) << 16));
    }
    return true;
}

fn moveBack(compiler: *c.JanetCompiler, destination: c.JanetSlot, source_value: i32) bool {
    var source = source_value;
    if (destination.flags & c.JANET_SLOT_REF != 0) {
        const reference = c.janetc_regalloc_temp(&compiler.scope.*.ra, c.JANETC_REGTEMP_5);
        if (!loadConstant(compiler, destination.constant, reference)) {
            c.janetc_regalloc_freetemp(&compiler.scope.*.ra, reference, c.JANETC_REGTEMP_5);
            return false;
        }
        emitInstruction(compiler, opcode(c.JOP_PUT_INDEX) |
            (@as(u32, @intCast(reference)) << 8) |
            (@as(u32, @intCast(source)) << 16));
        c.janetc_regalloc_freetemp(&compiler.scope.*.ra, reference, c.JANETC_REGTEMP_5);
    } else if (destination.envindex >= 0) {
        source = makeNearSource(compiler, source);
        emitInstruction(compiler, opcode(c.JOP_SET_UPVALUE) |
            (@as(u32, @intCast(source)) << 8) |
            (@as(u32, @intCast(destination.envindex)) << 16) |
            (@as(u32, @intCast(destination.index)) << 24));
    } else if (destination.index != source) {
        source = makeNearSource(compiler, source);
        emitInstruction(compiler, opcode(c.JOP_MOVE_FAR) |
            (@as(u32, @intCast(source)) << 8) |
            (@as(u32, @intCast(destination.index)) << 16));
    }
    return true;
}

fn makeNearSource(compiler: *c.JanetCompiler, source_value: i32) i32 {
    if (source_value <= 0xff) return source_value;
    const near_source = 0xf0 + @as(i32, @intCast(c.JANETC_REGTEMP_5));
    emitInstruction(compiler, opcode(c.JOP_MOVE_NEAR) |
        (@as(u32, @intCast(near_source)) << 8) |
        (@as(u32, @intCast(source_value)) << 16));
    return near_source;
}

fn loadConstant(compiler: *c.JanetCompiler, value: c.Janet, register: i32) bool {
    const register_bits = @as(u32, @intCast(register)) << 8;
    switch (c.janet_type(value)) {
        c.JANET_NIL => emitInstruction(compiler, opcode(c.JOP_LOAD_NIL) | register_bits),
        c.JANET_BOOLEAN => emitInstruction(
            compiler,
            opcode(if (c.janet_unwrap_boolean(value) != 0) c.JOP_LOAD_TRUE else c.JOP_LOAD_FALSE) | register_bits,
        ),
        c.JANET_NUMBER => {
            if (c.janet_checkint16(value) != 0) {
                const integer: i32 = @intFromFloat(c.janet_unwrap_number(value));
                const integer_bits: u32 = @bitCast(integer);
                emitInstruction(compiler, opcode(c.JOP_LOAD_INTEGER) | register_bits | (integer_bits << 16));
            } else {
                return loadFromConstantPool(compiler, value, register_bits);
            }
        },
        else => return loadFromConstantPool(compiler, value, register_bits),
    }
    return true;
}

fn loadFromConstantPool(compiler: *c.JanetCompiler, value: c.Janet, register_bits: u32) bool {
    const index = internConstant(compiler, value) orelse return false;
    emitInstruction(compiler, opcode(c.JOP_LOAD_CONSTANT) |
        register_bits |
        (@as(u32, @intCast(index)) << 16));
    return true;
}

fn internConstant(compiler: *c.JanetCompiler, value: c.Janet) ?i32 {
    var scope = compiler.scope;
    while (scope != null and scope.*.flags & c.JANET_SCOPE_FUNCTION == 0) {
        scope = scope.*.parent;
    }

    const count = vectorCount(c.Janet, scope.*.consts);
    var index: i32 = 0;
    while (index < count) : (index += 1) {
        if (c.janet_equals(value, scope.*.consts[@intCast(index)]) != 0) return index;
    }
    if (count >= 0xffff) return null;
    pushVector(c.Janet, &scope.*.consts, value);
    return count;
}

fn slotsEqual(lhs: c.JanetSlot, rhs: c.JanetSlot) bool {
    return janetc_sequal(lhs, rhs) != 0;
}

fn emitInstruction(compiler: *c.JanetCompiler, instruction: u32) void {
    janetc_emit(compiler, instruction);
}

fn opcode(value: c_int) u32 {
    return @intCast(value);
}

fn pushVector(comptime Element: type, vector_pointer: *[*c]Element, value: Element) void {
    var vector = vector_pointer.*;
    const count = vectorCount(Element, vector);
    if (vector == null or count + 1 >= vectorCapacity(Element, vector)) {
        vector = @ptrCast(@alignCast(c.janet_v_grow(vector, 1, @sizeOf(Element))));
        vector_pointer.* = vector;
    }
    vector[@intCast(count)] = value;
    vectorHeader(Element, vector)[1] = count + 1;
}

fn vectorCount(comptime Element: type, vector: [*c]Element) i32 {
    return if (vector == null) 0 else vectorHeader(Element, vector)[1];
}

fn vectorCapacity(comptime Element: type, vector: [*c]Element) i32 {
    return vectorHeader(Element, vector)[0];
}

fn vectorHeader(comptime Element: type, vector: [*c]Element) [*]i32 {
    return @ptrFromInt(@intFromPtr(vector) - vector_header_size);
}
