const std = @import("std");
const abi = @import("abi");
const c = abi.c;

const hash_seed: u32 = 0x9e3779b9;
const hash_key_size = c.JANET_HASH_KEY_SIZE;

var hash_key: [hash_key_size]u8 = @splat(0);

comptime {
    if (@hasDecl(c, "JANET_PRF")) {
        @export(&initHashKey, .{ .name = "janet_init_hash_key" });
    }
}

export fn janet_hash_mix(input: u32, more: u32) callconv(.c) u32 {
    const mix = more +% hash_seed +% (input << 6) +% (input >> 2);
    return input ^ (hash_seed +% (mix << 6) +% (mix >> 2));
}

export fn janet_string_calchash(string: [*c]const u8, length: i32) callconv(.c) i32 {
    if (@hasDecl(c, "JANET_PRF")) {
        return @bitCast(halfSipHash(string, @intCast(length), &hash_key));
    }

    if (string == null or length == 0) return 5381;
    var hash: u32 = 5381;
    for (string[0..@intCast(length)]) |byte| {
        hash = (hash << 5) +% hash +% byte;
    }
    return @bitCast(janet_hash_mix(hash, @bitCast(length)));
}

export fn janet_tablen(value: i32) callconv(.c) i32 {
    if (value < 0) return 0;
    var result = value;
    result |= result >> 1;
    result |= result >> 2;
    result |= result >> 4;
    result |= result >> 8;
    result |= result >> 16;
    return if (result == std.math.maxInt(i32)) result else result + 1;
}

fn initHashKey(new_key: [*c]u8) callconv(.c) void {
    @memcpy(&hash_key, new_key[0..hash_key.len]);
}

fn halfSipHash(input: [*c]const u8, length: usize, key: *const [hash_key_size]u8) u32 {
    var v0: u32 = 0;
    var v1: u32 = 0;
    var v2: u32 = 0x6c796765;
    var v3: u32 = 0x74656462;
    const k0 = readU32Little(key[0..4]);
    const k1 = readU32Little(key[4..8]);

    v3 ^= k1;
    v2 ^= k0;
    v1 ^= k1;
    v0 ^= k0;

    const word_bytes = length - (length % 4);
    var offset: usize = 0;
    while (offset < word_bytes) : (offset += 4) {
        const message = readU32Little(input[offset..][0..4]);
        v3 ^= message;
        sipRound(&v0, &v1, &v2, &v3);
        sipRound(&v0, &v1, &v2, &v3);
        v0 ^= message;
    }

    var final: u32 = @as(u32, @truncate(length)) << 24;
    const remaining = length - word_bytes;
    if (remaining >= 3) final |= @as(u32, input[offset + 2]) << 16;
    if (remaining >= 2) final |= @as(u32, input[offset + 1]) << 8;
    if (remaining >= 1) final |= input[offset];

    v3 ^= final;
    sipRound(&v0, &v1, &v2, &v3);
    sipRound(&v0, &v1, &v2, &v3);
    v0 ^= final;
    v2 ^= 0xff;
    inline for (0..4) |_| sipRound(&v0, &v1, &v2, &v3);
    return v1 ^ v3;
}

fn sipRound(v0: *u32, v1: *u32, v2: *u32, v3: *u32) void {
    v0.* +%= v1.*;
    v1.* = rotateLeft(v1.*, 5);
    v1.* ^= v0.*;
    v0.* = rotateLeft(v0.*, 16);
    v2.* +%= v3.*;
    v3.* = rotateLeft(v3.*, 8);
    v3.* ^= v2.*;
    v0.* +%= v3.*;
    v3.* = rotateLeft(v3.*, 7);
    v3.* ^= v0.*;
    v2.* +%= v1.*;
    v1.* = rotateLeft(v1.*, 13);
    v1.* ^= v2.*;
    v2.* = rotateLeft(v2.*, 16);
}

fn rotateLeft(value: u32, comptime amount: u5) u32 {
    return std.math.rotl(u32, value, amount);
}

fn readU32Little(bytes: *const [4]u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}
