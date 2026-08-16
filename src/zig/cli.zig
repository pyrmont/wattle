const std = @import("std");
const interop = @import("interop.zig");

const c = @cImport({
    @cInclude("interop.h");
});

pub fn main(init: std.process.Init) !u8 {
    interop.setIo(init.io);
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len == 0) return 1;

    const c_arguments = try init.arena.allocator().alloc([*c]const u8, arguments.len);
    for (arguments, c_arguments) |argument, *c_argument| c_argument.* = argument.ptr;
    const status = c.janet_zig_cli_run(@intCast(c_arguments.len), c_arguments.ptr);
    return std.math.cast(u8, status) orelse 1;
}
