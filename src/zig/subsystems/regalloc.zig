const std = @import("std");

const c = @cImport({
    @cInclude("regalloc.h");
    @cInclude("runtime.h");
});

const chunk_bits = 32;
const reserved_chunk = 7;
const reserved_mask: u32 = 0xffff0000;
const temporary_base = 0xf0;

export fn janetc_regalloc_init(allocator: *c.JanetcRegisterAllocator) callconv(.c) void {
    allocator.* = .{
        .chunks = null,
        .count = 0,
        .capacity = 0,
        .max = 0,
        .regtemps = 0,
    };
}

export fn janetc_regalloc_deinit(allocator: *c.JanetcRegisterAllocator) callconv(.c) void {
    c.janet_free(allocator.chunks);
}

export fn janetc_regalloc_clone(
    destination: *c.JanetcRegisterAllocator,
    source: *c.JanetcRegisterAllocator,
) callconv(.c) void {
    destination.count = source.count;
    destination.capacity = source.capacity;
    destination.max = source.max;
    destination.regtemps = 0;
    const size = @sizeOf(u32) * @as(usize, @intCast(destination.capacity));
    if (size == 0) {
        destination.chunks = null;
        return;
    }
    const memory = c.janet_malloc(size) orelse c.janet_zig_out_of_memory();
    destination.chunks = @ptrCast(@alignCast(memory));
    const destination_bytes: [*]u8 = @ptrCast(destination.chunks);
    const source_bytes: [*]const u8 = @ptrCast(source.chunks);
    @memcpy(destination_bytes[0..size], source_bytes[0..size]);
}

export fn janetc_regalloc_touch(allocator: *c.JanetcRegisterAllocator, register: i32) callconv(.c) void {
    const chunk: i32 = register >> 5;
    const bit: u5 = @intCast(register & 0x1f);
    while (chunk >= allocator.count) pushChunk(allocator);
    allocator.chunks[@intCast(chunk)] |= @as(u32, 1) << bit;
}

export fn janetc_regalloc_1(allocator: *c.JanetcRegisterAllocator) callconv(.c) i32 {
    const old_chunk_count = allocator.count;
    var chunk: i32 = 0;
    var bit: u5 = 0;
    while (chunk < old_chunk_count) : (chunk += 1) {
        const block = allocator.chunks[@intCast(chunk)];
        if (block == std.math.maxInt(u32)) continue;
        bit = @intCast(@ctz(~block));
        break;
    } else {
        pushChunk(allocator);
        chunk = old_chunk_count;
    }

    allocator.chunks[@intCast(chunk)] |= @as(u32, 1) << bit;
    const register = (chunk << 5) + @as(i32, bit);
    if (register > allocator.max) allocator.max = register;
    return register;
}

export fn janetc_regalloc_free(allocator: *c.JanetcRegisterAllocator, register: i32) callconv(.c) void {
    const chunk: usize = @intCast(register >> 5);
    const bit: u5 = @intCast(register & 0x1f);
    allocator.chunks[chunk] &= ~(@as(u32, 1) << bit);
}

export fn janetc_regalloc_check(allocator: *c.JanetcRegisterAllocator, register: i32) callconv(.c) c_int {
    const chunk: i32 = register >> 5;
    const bit: u5 = @intCast(register & 0x1f);
    while (chunk >= allocator.count) pushChunk(allocator);
    return @intFromBool(allocator.chunks[@intCast(chunk)] & (@as(u32, 1) << bit) != 0);
}

export fn janetc_regalloc_temp(
    allocator: *c.JanetcRegisterAllocator,
    temporary: c.JanetcRegisterTemp,
) callconv(.c) i32 {
    const temporary_index: u5 = @intCast(temporary);
    const temporary_mask = @as(i32, 1) << temporary_index;
    if (allocator.regtemps & temporary_mask != 0) {
        c.janet_zig_fatal("regtemp already allocated");
    }
    allocator.regtemps |= temporary_mask;
    const old_max = allocator.max;
    var register = janetc_regalloc_1(allocator);
    if (register > 0xff) {
        register = temporary_base + @as(i32, @intCast(temporary));
        allocator.max = @max(register, old_max);
    }
    return register;
}

export fn janetc_regalloc_freetemp(
    allocator: *c.JanetcRegisterAllocator,
    register: i32,
    temporary: c.JanetcRegisterTemp,
) callconv(.c) void {
    const temporary_index: u5 = @intCast(temporary);
    allocator.regtemps &= ~(@as(i32, 1) << temporary_index);
    if (register < temporary_base) janetc_regalloc_free(allocator, register);
}

fn pushChunk(allocator: *c.JanetcRegisterAllocator) void {
    const chunk: u32 = if (allocator.count == reserved_chunk) reserved_mask else 0;
    const new_count = allocator.count + 1;
    if (new_count > allocator.capacity) {
        const new_capacity = new_count * 2;
        const size = @sizeOf(u32) * @as(usize, @intCast(new_capacity));
        const memory = c.janet_realloc(allocator.chunks, size) orelse c.janet_zig_out_of_memory();
        allocator.chunks = @ptrCast(@alignCast(memory));
        allocator.capacity = new_capacity;
    }
    allocator.chunks[@intCast(allocator.count)] = chunk;
    allocator.count = new_count;
}
