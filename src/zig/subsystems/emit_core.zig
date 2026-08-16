const c = @cImport({
    @cInclude("emit.h");
    @cInclude("vector.h");
});

const vector_header_size = 2 * @sizeOf(i32);
const slot_type_mask: u32 = c.JANET_SLOTTYPE_ANY;
const EmitError = error{ TooManyConstants, TooManyRegisters };

const TemplateKind = enum(c_int) {
    s,
    one_s,
    ss,
    two_s,
    sss,
};

comptime {
    @export(&allocFar, .{ .name = "janet_zig_allocfar", .visibility = .hidden });
    @export(&copySlot, .{ .name = "janet_zig_copy", .visibility = .hidden });
    @export(&emitTemplate, .{ .name = "janet_zig_emit_template", .visibility = .hidden });
}

fn allocFar(compiler: *c.JanetCompiler) callconv(.c) i32 {
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

fn copySlot(compiler: *c.JanetCompiler, destination: c.JanetSlot, source: c.JanetSlot) callconv(.c) c_int {
    if (slotsEqual(destination, source)) return 1;

    if (destination.envindex < 0 and destination.index >= 0 and destination.index <= 0xff) {
        return @intFromBool(moveNear(compiler, destination.index, source));
    }
    if (source.envindex < 0 and source.index >= 0 and source.index <= 0xff) {
        return @intFromBool(moveBack(compiler, destination, source.index));
    }

    const temporary = c.janetc_regalloc_temp(&compiler.scope.*.ra, c.JANETC_REGTEMP_3);
    if (!moveNear(compiler, temporary, source)) {
        c.janetc_regalloc_freetemp(&compiler.scope.*.ra, temporary, c.JANETC_REGTEMP_3);
        return 0;
    }
    const success = moveBack(compiler, destination, temporary);
    c.janetc_regalloc_freetemp(&compiler.scope.*.ra, temporary, c.JANETC_REGTEMP_3);
    return @intFromBool(success);
}

fn emitTemplate(
    compiler: *c.JanetCompiler,
    kind_value: c_int,
    operation: u8,
    slot1: c.JanetSlot,
    slot2: c.JanetSlot,
    slot3: c.JanetSlot,
    rest: i32,
    write_back: c_int,
    label_out: *i32,
) callconv(.c) c_int {
    const kind: TemplateKind = @enumFromInt(kind_value);
    label_out.* = switch (kind) {
        .s => emitS(compiler, operation, slot1, write_back != 0),
        .one_s => emitOneSlot(compiler, operation, slot1, rest, write_back != 0),
        .ss => emitSS(compiler, operation, slot1, slot2, write_back != 0),
        .two_s => emitTwoSlots(compiler, operation, slot1, slot2, rest, write_back != 0),
        .sss => emitSSS(compiler, operation, slot1, slot2, slot3, write_back != 0),
    } catch |emit_error| return switch (emit_error) {
        error.TooManyConstants => 1,
        error.TooManyRegisters => 2,
    };
    return 0;
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
