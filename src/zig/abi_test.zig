const std = @import("std");
const abi = @import("abi.zig");
const c = abi.c;

const JanetGCData = extern union {
    next: ?*c.JanetGCObject,
    refcount: c.JanetAtomicInt,
};

const JanetGCObject = extern struct {
    flags: i32,
    data: JanetGCData,
};

const JanetArray = extern struct {
    gc: JanetGCObject,
    count: i32,
    capacity: i32,
    data: [*c]c.Janet,
};

const JanetBuffer = extern struct {
    gc: JanetGCObject,
    count: i32,
    capacity: i32,
    data: [*c]u8,
};

const JanetTable = extern struct {
    gc: JanetGCObject,
    count: i32,
    capacity: i32,
    deleted: i32,
    data: [*c]c.JanetKV,
    proto: ?*c.JanetTable,
};

test "public enum and flag values remain stable" {
    try std.testing.expectEqual(@as(c_int, 0), c.JANET_NUMBER);
    try std.testing.expectEqual(@as(c_int, 1), c.JANET_NIL);
    try std.testing.expectEqual(@as(c_int, 15), c.JANET_POINTER);
    try std.testing.expectEqual(@as(comptime_int, 16), c.JANET_COUNT_TYPES);
    try std.testing.expectEqual(@as(c_int, 0), c.JANET_SIGNAL_OK);
    try std.testing.expectEqual(@as(c_int, 1), c.JANET_SIGNAL_ERROR);
    try std.testing.expectEqual(@as(comptime_int, 4), c.JANET_FRAME_SIZE);
}

test "Janet native callbacks use the C calling convention" {
    const callback: c.JanetCFunction = &abiCallback;
    try std.testing.expect(callback != null);
}

test "Zig declarations reproduce public C layouts" {
    try expectSameLayout(JanetGCObject, c.JanetGCObject);
    try expectSameLayout(JanetArray, c.JanetArray);
    try expectSameLayout(JanetBuffer, c.JanetBuffer);
    try expectSameLayout(JanetTable, c.JanetTable);

    try std.testing.expectEqual(@offsetOf(JanetArray, "count"), @offsetOf(c.JanetArray, "count"));
    try std.testing.expectEqual(@offsetOf(JanetBuffer, "data"), @offsetOf(c.JanetBuffer, "data"));
    try std.testing.expectEqual(@offsetOf(JanetTable, "proto"), @offsetOf(c.JanetTable, "proto"));
    try std.testing.expectEqual(2 * @sizeOf(c.Janet), @sizeOf(c.JanetKV));
}

fn expectSameLayout(comptime zig_type: type, comptime c_type: type) !void {
    try std.testing.expectEqual(@sizeOf(c_type), @sizeOf(zig_type));
    try std.testing.expectEqual(@alignOf(c_type), @alignOf(zig_type));
}

fn abiCallback(argc: i32, argv: [*c]c.Janet) callconv(.c) c.Janet {
    _ = argc;
    _ = argv;
    return std.mem.zeroes(c.Janet);
}
