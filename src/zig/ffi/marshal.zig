//! `ffi.c`'s marshalling: a Janet value written into memory as a C value would
//! appear there, and the same memory read back. Part 16's middle layer, and
//! the reason the FFI's remaining half was recorded in Phase 6 as blocked --
//! it holds Janet values and panics on every second line.
//!
//! ## Misaligned access is reproduced rather than repaired
//!
//! A `:pack`ed struct field lands wherever the previous field ended, so
//! `((double *) to)[0] = ...` writes through a pointer that may not be aligned
//! for a `double`. `FOUND.md` records this as a pre-existing defect and Phase 8
//! agreed to leave it unfixed, so the port has to place the same bytes.
//!
//! Every access here therefore goes through an `align(1)` pointer. That is the
//! same store, and it produces the same byte image, but where C's version is
//! undefined -- and aborts under the sanitizer, which is why the differential
//! corpus's byte-image half runs at `ReleaseFast` -- Zig's is defined. The
//! divergence is entirely in what a sanitizer says about it.
//!
//! ## Why this file is jump-transparent
//!
//! The argument layer is behind `-Dargs-core`, so every `janet_get*` here
//! raises by `longjmp` until Part 17. No `defer` may appear until then.

const std = @import("std");
const raise = @import("raise");
const pp_format = @import("../pp/format.zig");
const ffi_types = @import("types.zig");
const args_core = @import("../args.zig");
const config = @import("config");
const gc_alloc = @import("../gc.zig");
const tuples = @import("../value/tuples.zig");
const kind = @import("../value/helpers/kind.zig");
const wrap = @import("../value/helpers/wrap.zig");
const arrays = @import("../value/arrays.zig");

const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const value = @import("../value.zig");
const inttypes = @import("../value/ints.zig");
const Type = ffi_types.Type;
const Struct = ffi_types.Struct;

const has_int_types = config.int_types;

/// Store `value` at `to`, which may be aligned for nothing at all.
inline fn put(comptime T: type, to: *anyopaque, val: T) void {
    const p: *align(1) T = @ptrCast(@alignCast(@as([*]align(1) u8, @ptrCast(to))));
    p.* = val;
}

/// Load a `T` from `from`, which may be aligned for nothing at all.
inline fn get(comptime T: type, from: [*]const u8) T {
    const p: *align(1) const T = @ptrCast(from);
    return p.*;
}

/// `janet_ffi_getpointer`: every Janet type that can stand in for a C pointer.
pub fn getPointer(argv: []const types.Janet, n: i32) raise.Raising(?*anyopaque) {
    return switch (kind.typeOf(argv[@intCast(n)])) {
        constants.JANET_POINTER,
        constants.JANET_STRING,
        constants.JANET_KEYWORD,
        constants.JANET_SYMBOL,
        constants.JANET_CFUNCTION,
        => wrap.toPointer(argv[@intCast(n)]),
        constants.JANET_ABSTRACT => @ptrCast(@constCast((try args_core.getBytes(argv, n)).bytes)),
        constants.JANET_BUFFER => wrap.toBuffer(argv[@intCast(n)]).*.data,
        constants.JANET_FUNCTION => blk: {
            // A function passed here is almost certainly a callback, so it
            // joins the root set and never leaves it.
            gc_alloc.gcroot(argv[@intCast(n)]);
            break :blk wrap.toPointer(argv[@intCast(n)]);
        },
        constants.JANET_NIL => null,
        else => pp_format.panicf(
            "bad slot #%d, expected ffi pointer convertible type, got %v",
            .{ n, argv[@intCast(n)] },
        ),
    };
}

/// `janet_ffi_write_one`: a Janet value, laid out as its FFI type says.
///
/// The space and alignment available are assumed to be sufficient, which for
/// alignment is the assumption the packed-field defect breaks.
pub fn writeOne(
    to: *anyopaque,
    argv: []const types.Janet,
    n: i32,
    ty: Type,
    recur: c_int,
) raise.Error!void {
    if (recur == 0) return raise.panic("recursion too deep");
    const arg = argv[@intCast(n)];

    if (ty.array_count >= 0) {
        const el_type = ty.element();
        const el_size = ffi_types.typeSize(el_type);
        const els = try args_core.getIndexed(argv, n);
        if (els.len != ty.array_count) {
            return pp_format.panicf("bad array length, expected %d, got %d", .{ ty.array_count, els.len });
        }
        var cursor: [*]u8 = @ptrCast(to);
        var i: i32 = 0;
        while (i < els.len) : (i += 1) {
            try writeOne(cursor, args_core.viewItems(els), i, el_type, recur - 1);
            cursor += el_size;
        }
        return;
    }

    switch (ty.prim) {
        .void => {
            if (0 == kind.checkType(arg, constants.JANET_NIL)) {
                return pp_format.panicf("expected nil, got %v", .{arg});
            }
        },
        .@"struct" => {
            const els = try args_core.getIndexed(argv, n);
            const st = ty.st.?;
            if (@as(u32, @bitCast(els.len)) != st.field_count) {
                return pp_format.panicf(
                    "wrong number of fields in struct, expected %d, got %d",
                    .{ @as(i32, @bitCast(st.field_count)), els.len },
                );
            }
            const members = Struct.fields(st);
            var i: i32 = 0;
            while (i < els.len) : (i += 1) {
                const member = members[@intCast(i)];
                const at: [*]u8 = @as([*]u8, @ptrCast(to)) + member.offset;
                try writeOne(at, args_core.viewItems(els), i, member.type, recur - 1);
            }
        },
        .double => put(f64, to, try args_core.getNumber(argv, n)),
        .float => put(f32, to, @floatCast(try args_core.getNumber(argv, n))),
        .ptr => put(?*anyopaque, to, try getPointer(argv, n)),
        .string => put([*]const u8, to, try args_core.getCString(argv, n)),
        .bool => put(bool, to, 0 != try args_core.getBoolean(argv, n)),
        .int8 => put(i8, to, @truncate(try args_core.getInteger(argv, n))),
        .int16 => put(i16, to, @truncate(try args_core.getInteger(argv, n))),
        .int32 => put(i32, to, try args_core.getInteger(argv, n)),
        .int64 => put(i64, to, try args_core.getInteger64(argv, n)),
        .uint8 => put(u8, to, @truncate(try args_core.getUInteger64(argv, n))),
        .uint16 => put(u16, to, @truncate(try args_core.getUInteger64(argv, n))),
        .uint32 => put(u32, to, @truncate(try args_core.getUInteger64(argv, n))),
        .uint64 => put(u64, to, try args_core.getUInteger64(argv, n)),
    }
}

/// `janet_ffi_read_one`: the inverse of `writeOne`, assuming the memory holds
/// what the type says it holds.
pub fn readOne(from: [*]const u8, ty: Type, recur: c_int) raise.Raising(types.Janet) {
    if (recur == 0) return raise.panic("recursion too deep");

    if (ty.array_count >= 0) {
        const el_type = ty.element();
        const el_size = ffi_types.typeSize(el_type);
        const array = arrays.new(ty.array_count);
        var cursor = from;
        var i: i32 = 0;
        while (i < ty.array_count) : (i += 1) {
            try arrays.push(array, try readOne(cursor, el_type, recur - 1));
            cursor += el_size;
        }
        return wrap.fromArray(array);
    }

    return switch (ty.prim) {
        .void => wrap.fromNil(),
        .@"struct" => blk: {
            const st = ty.st.?;
            const members = Struct.fields(st);
            const tup = tuples.begin(@bitCast(st.field_count));
            var i: u32 = 0;
            while (i < st.field_count) : (i += 1) {
                tup[i] = try readOne(from + members[i].offset, members[i].type, recur - 1);
            }
            break :blk wrap.fromTuple(tuples.end(tup));
        },
        .double => wrap.fromNumber(get(f64, from)),
        .float => wrap.fromNumber(get(f32, from)),
        .ptr => blk: {
            const ptr = get(?*anyopaque, from);
            break :blk if (ptr == null) wrap.fromNil() else wrap.fromPointer(ptr);
        },
        .string => value.fromBytes(std.mem.span(get([*:0]const u8, from)), .string),
        // Read as a byte and compared, not loaded as a `bool`. The memory is
        // whatever the callee left there, and a byte that is neither 0 nor 1
        // is not a valid `bool` in Zig -- where C's `((bool *) from)[0]` is
        // merely nonzero. This is the same answer for every input and a
        // defined one for all of them.
        .bool => wrap.fromBoolean(@intFromBool(get(u8, from) != 0)),
        .int8 => wrap.fromNumber(@floatFromInt(get(i8, from))),
        .int16 => wrap.fromNumber(@floatFromInt(get(i16, from))),
        .int32 => wrap.fromNumber(@floatFromInt(get(i32, from))),
        .uint8 => wrap.fromNumber(@floatFromInt(get(u8, from))),
        .uint16 => wrap.fromNumber(@floatFromInt(get(u16, from))),
        .uint32 => wrap.fromNumber(@floatFromInt(get(u32, from))),
        // Without the integer types these two lose precision exactly as the C
        // original does, which is why the branch is on the build rather than on
        // the value.
        .int64 => if (has_int_types)
            inttypes.wrapS64(get(i64, from))
        else
            wrap.fromNumber(@floatFromInt(get(i64, from))),
        .uint64 => if (has_int_types)
            inttypes.wrapU64(get(u64, from))
        else
            wrap.fromNumber(@floatFromInt(get(u64, from))),
    };
}
