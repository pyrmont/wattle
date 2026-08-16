const std = @import("std");

const max_literal_length = 0xffff;

export fn janet_scan_int64(string: [*c]const u8, length: i32, out: *i64) callconv(.c) c_int {
    const parsed = scanUnsigned(string, length) orelse return 0;
    if (parsed.negative) {
        const minimum_magnitude = @as(u64, std.math.maxInt(i64)) + 1;
        if (parsed.value > minimum_magnitude) return 0;
        out.* = if (parsed.value == minimum_magnitude)
            std.math.minInt(i64)
        else
            -@as(i64, @intCast(parsed.value));
        return 1;
    }
    if (parsed.value > std.math.maxInt(i64)) return 0;
    out.* = @intCast(parsed.value);
    return 1;
}

export fn janet_scan_uint64(string: [*c]const u8, length: i32, out: *u64) callconv(.c) c_int {
    const parsed = scanUnsigned(string, length) orelse return 0;
    if (parsed.negative) return 0;
    out.* = parsed.value;
    return 1;
}

const ParsedUnsigned = struct {
    value: u64,
    negative: bool,
};

fn scanUnsigned(string: [*c]const u8, length: i32) ?ParsedUnsigned {
    if (length < 0 or length > max_literal_length) return null;
    const bytes = string[0..@intCast(length)];
    var index: usize = 0;
    var negative = false;
    var base: u8 = 10;
    var seen_digit = false;
    var accumulator: u64 = 0;

    if (bytes.len == 0) return null;
    if (bytes[index] == '-') {
        negative = true;
        index += 1;
    } else if (bytes[index] == '+') {
        index += 1;
    }

    if (index + 1 < bytes.len and bytes[index] == '0' and bytes[index + 1] == 'x') {
        base = 16;
        index += 2;
    } else if (index + 1 < bytes.len and isDecimal(bytes[index]) and bytes[index + 1] == 'r') {
        base = bytes[index] - '0';
        index += 2;
    } else if (index + 2 < bytes.len and isDecimal(bytes[index]) and isDecimal(bytes[index + 1]) and bytes[index + 2] == 'r') {
        base = 10 * (bytes[index] - '0') + (bytes[index + 1] - '0');
        if (base < 2 or base > 36) return null;
        index += 3;
    }

    while (index < bytes.len and bytes[index] == '0') : (index += 1) {
        seen_digit = true;
    }

    while (index < bytes.len) : (index += 1) {
        const byte = bytes[index];
        if (byte == '_') {
            if (!seen_digit) return null;
            continue;
        }
        const digit = digitValue(byte) orelse return null;
        if (digit >= base) return null;
        const wide_digit: u64 = digit;
        const wide_base: u64 = base;
        if (accumulator > (std.math.maxInt(u64) - wide_digit) / wide_base) return null;
        accumulator = accumulator * wide_base + wide_digit;
        seen_digit = true;
    }

    if (!seen_digit) return null;
    return .{ .value = accumulator, .negative = negative };
}

fn isDecimal(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn digitValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'A'...'Z' => byte - 'A' + 10,
        'a'...'z' => byte - 'a' + 10,
        else => null,
    };
}
