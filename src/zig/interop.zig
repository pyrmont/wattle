const std = @import("std");

const c = @cImport({
    @cInclude("interop.h");
});

const identity_operation = 0;
const length_operation = 1;
const call_operation = 2;
const rooted_operation = 3;
const fail_operation = 4;

var process_io: std.Io = undefined;

pub fn setIo(io: std.Io) void {
    process_io = io;
}

export fn janet_zig_readline(prompt: [*:0]const u8, out: *c.JanetZigLine) callconv(.c) c_int {
    std.Io.File.stderr().writeStreamingAll(process_io, std.mem.span(prompt)) catch return 0;

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(std.heap.c_allocator);

    while (true) {
        var byte: [1]u8 = undefined;
        const count = std.Io.File.stdin().readStreaming(process_io, &.{byte[0..]}) catch return 0;
        if (count == 0) break;
        line.append(std.heap.c_allocator, byte[0]) catch return 0;
        if (byte[0] == '\n') break;
    }

    if (line.items.len == 0) return 0;
    const owned = line.toOwnedSlice(std.heap.c_allocator) catch return 0;
    out.bytes = owned.ptr;
    out.length = std.math.cast(i32, owned.len) orelse {
        std.heap.c_allocator.free(owned);
        return 0;
    };
    return 1;
}

export fn janet_zig_dispatch(
    operation: i32,
    argc: i32,
    argv: [*c]const c.Janet,
    out: *c.Janet,
) callconv(.c) c_int {
    _ = argc;
    switch (operation) {
        identity_operation => out.* = argv[0],
        length_operation => c.janet_zig_wrap_integer(c.janet_length(argv[0]), out),
        call_operation => {
            var fiber: ?*c.JanetFiber = null;
            const function = c.janet_zig_unwrap_function(&argv[0]);
            const signal = c.janet_pcall(function, 1, argv + 1, out, &fiber);
            if (signal != c.JANET_SIGNAL_OK) return 0;
        },
        rooted_operation => {
            if (c.janet_zig_make_rooted(out) != c.JANET_SIGNAL_OK) return 0;
        },
        fail_operation => {
            out.* = argv[0];
            return 0;
        },
        else => return 0,
    }
    return 1;
}
