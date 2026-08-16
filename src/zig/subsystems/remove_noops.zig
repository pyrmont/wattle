const std = @import("std");

const c = @cImport({
    @cInclude("janet.h");
    @cInclude("runtime.h");
});

export fn janet_bytecode_remove_noops(definition: *c.JanetFuncDef) callconv(.c) void {
    const old_length = definition.bytecode_length;
    const map_length: usize = @intCast(old_length + 1);
    const map_size = map_length * @sizeOf(u32);
    const map_memory = c.janet_smalloc(map_size) orelse c.janet_zig_out_of_memory();
    const pc_map: [*]u32 = @ptrCast(@alignCast(map_memory));
    defer c.janet_sfree(pc_map);

    var new_length: u32 = 0;
    for (definition.bytecode[0..@intCast(old_length)], 0..) |instruction, index| {
        pc_map[index] = new_length;
        if (opcode(instruction) != c.JOP_NOOP) new_length += 1;
    }
    pc_map[@intCast(old_length)] = new_length;

    var destination_index: i32 = 0;
    var source_index: i32 = 0;
    while (source_index < old_length) : (source_index += 1) {
        var instruction = definition.bytecode[@intCast(source_index)];
        const shift: ?u5 = switch (opcode(instruction)) {
            c.JOP_NOOP => continue,
            c.JOP_JUMP => 8,
            c.JOP_JUMP_IF, c.JOP_JUMP_IF_NIL, c.JOP_JUMP_IF_NOT, c.JOP_JUMP_IF_NOT_NIL => 16,
            else => null,
        };
        if (shift) |field_shift| {
            const old_target = source_index + signedField(instruction, field_shift);
            if (old_target < 0 or old_target >= old_length) c.janet_zig_fatal("bounds");
            const new_target: i32 = @intCast(pc_map[@intCast(old_target)]);
            const adjustment = new_target - old_target + (source_index - destination_index);
            instruction +%= @as(u32, @bitCast(adjustment)) << field_shift;
        }
        definition.bytecode[@intCast(destination_index)] = instruction;
        if (definition.sourcemap != null) {
            definition.sourcemap[@intCast(destination_index)] = definition.sourcemap[@intCast(source_index)];
        }
        destination_index += 1;
    }

    if (definition.symbolmap_length > 0) {
        for (definition.symbolmap[0..@intCast(definition.symbolmap_length)]) |*symbol| {
            if (symbol.birth_pc < std.math.maxInt(u32)) {
                symbol.birth_pc = pc_map[symbol.birth_pc];
                symbol.death_pc = pc_map[symbol.death_pc];
            }
        }
    }

    definition.bytecode_length = @intCast(new_length);
    const resized = c.janet_realloc(definition.bytecode, @as(usize, new_length) * @sizeOf(u32));
    definition.bytecode = @ptrCast(@alignCast(resized));
}

fn opcode(instruction: u32) u32 {
    return instruction & 0x7f;
}

fn signedField(instruction: u32, shift: u5) i32 {
    return @as(i32, @bitCast(instruction)) >> shift;
}
