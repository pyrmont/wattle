const gc_alloc = @import("gc.zig");
const utils = @import("utils.zig");
const fatal = @import("fatal.zig");
const c = @import("cabi");

const header_words = 2;
const header_size = header_words * @sizeOf(i32);

pub fn vGrow(
    vector: ?*anyopaque,
    increment: i32,
    item_size: i32,
) callconv(.c) ?*anyopaque {
    const current_capacity = if (vector) |v| rawWords(v)[0] else 0;
    const current_count = if (vector) |v| rawWords(v)[1] else 0;
    const doubled_capacity = current_capacity *% 2;
    const minimum_capacity = current_count +% increment;
    const new_capacity = @max(doubled_capacity, minimum_capacity);
    const allocation_size = @as(usize, @intCast(item_size)) *%
        @as(usize, @intCast(new_capacity)) +% header_size;

    const allocation = gc_alloc.srealloc(
        if (vector) |v| @ptrFromInt(@intFromPtr(v) - header_size) else null,
        allocation_size,
    ) orelse {
        fatal.outOfMemory();
    };
    const words: [*]i32 = @ptrCast(@alignCast(allocation));
    words[0] = new_capacity;
    if (vector == null) words[1] = 0;
    return @ptrCast(&words[header_words]);
}

pub fn vFlattenmem(vector: ?*anyopaque, item_size: i32) ?*anyopaque {
    const source = vector orelse return null;
    const count = rawWords(source)[1];
    const size = @as(usize, @intCast(item_size)) *% @as(usize, @intCast(count));
    const allocation = utils.malloc(size) orelse {
        fatal.outOfMemory();
    };

    const destination_bytes: [*]u8 = @ptrCast(allocation);
    const source_bytes: [*]const u8 = @ptrCast(source);
    @memcpy(destination_bytes[0..size], source_bytes[0..size]);
    return allocation;
}

fn rawWords(vector: *anyopaque) [*]i32 {
    return @ptrFromInt(@intFromPtr(vector) - header_size);
}
