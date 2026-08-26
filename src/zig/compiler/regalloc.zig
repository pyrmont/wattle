const std = @import("std");

const utils = @import("../utils.zig");
const fatal = @import("../fatal.zig");
const types = @import("types");
const c = @import("cabi");

const chunk_bits = 32;
const reserved_chunk = 7;
const reserved_mask: u32 = 0xffff0000;
const temporary_base = 0xf0;

pub fn regallocInit(allocator: *types.JanetcRegisterAllocator) void {
    allocator.* = .{
        .chunks = null,
        .count = 0,
        .capacity = 0,
        .max = 0,
        .regtemps = 0,
    };
}

pub fn regallocDeinit(allocator: *types.JanetcRegisterAllocator) void {
    utils.free(allocator.chunks);
}

pub fn regallocClone(
    destination: *types.JanetcRegisterAllocator,
    source: *types.JanetcRegisterAllocator,
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
    const memory = utils.malloc(size) orelse fatal.outOfMemory();
    destination.chunks = @ptrCast(@alignCast(memory));
    const destination_bytes: [*]u8 = @ptrCast(destination.chunks);
    const source_bytes: [*]const u8 = @ptrCast(source.chunks);
    @memcpy(destination_bytes[0..size], source_bytes[0..size]);
}

pub fn regallocTouch(allocator: *types.JanetcRegisterAllocator, register: i32) void {
    const chunk: i32 = register >> 5;
    const bit: u5 = @intCast(register & 0x1f);
    while (chunk >= allocator.count) pushChunk(allocator);
    allocator.chunks.?[@intCast(chunk)] |= @as(u32, 1) << bit;
}

pub fn regalloc1(allocator: *types.JanetcRegisterAllocator) i32 {
    const old_chunk_count = allocator.count;
    var chunk: i32 = 0;
    var bit: u5 = 0;
    while (chunk < old_chunk_count) : (chunk += 1) {
        const block = allocator.chunks.?[@intCast(chunk)];
        if (block == std.math.maxInt(u32)) continue;
        bit = @intCast(@ctz(~block));
        break;
    } else {
        pushChunk(allocator);
        chunk = old_chunk_count;
    }

    allocator.chunks.?[@intCast(chunk)] |= @as(u32, 1) << bit;
    const register = (chunk << 5) + @as(i32, bit);
    if (register > allocator.max) allocator.max = register;
    return register;
}

pub fn regallocFree(allocator: *types.JanetcRegisterAllocator, register: i32) void {
    const chunk: usize = @intCast(register >> 5);
    const bit: u5 = @intCast(register & 0x1f);
    allocator.chunks.?[chunk] &= ~(@as(u32, 1) << bit);
}

pub fn regallocCheck(allocator: *types.JanetcRegisterAllocator, register: i32) c_int {
    const chunk: i32 = register >> 5;
    const bit: u5 = @intCast(register & 0x1f);
    while (chunk >= allocator.count) pushChunk(allocator);
    return @intFromBool(allocator.chunks.?[@intCast(chunk)] & (@as(u32, 1) << bit) != 0);
}

pub fn regallocTemp(
    allocator: *types.JanetcRegisterAllocator,
    temporary: types.JanetcRegisterTemp,
) callconv(.c) i32 {
    const temporary_index: u5 = @intCast(temporary);
    const temporary_mask = @as(i32, 1) << temporary_index;
    if (allocator.regtemps & temporary_mask != 0) {
        fatal.fatal("regtemp already allocated");
    }
    allocator.regtemps |= temporary_mask;
    const old_max = allocator.max;
    var register = regalloc1(allocator);
    if (register > 0xff) {
        register = temporary_base + @as(i32, @intCast(temporary));
        allocator.max = @max(register, old_max);
    }
    return register;
}

pub fn regallocFreetemp(
    allocator: *types.JanetcRegisterAllocator,
    register: i32,
    temporary: types.JanetcRegisterTemp,
) callconv(.c) void {
    const temporary_index: u5 = @intCast(temporary);
    allocator.regtemps &= ~(@as(i32, 1) << temporary_index);
    if (register < temporary_base) regallocFree(allocator, register);
}

fn pushChunk(allocator: *types.JanetcRegisterAllocator) void {
    const chunk: u32 = if (allocator.count == reserved_chunk) reserved_mask else 0;
    const new_count = allocator.count + 1;
    if (new_count > allocator.capacity) {
        const new_capacity = new_count * 2;
        const size = @sizeOf(u32) * @as(usize, @intCast(new_capacity));
        const memory = utils.realloc(allocator.chunks, size) orelse fatal.outOfMemory();
        allocator.chunks = @ptrCast(@alignCast(memory));
        allocator.capacity = new_capacity;
    }
    allocator.chunks.?[@intCast(allocator.count)] = chunk;
    allocator.count = new_count;
}
