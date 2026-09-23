//! `ffi.c`'s marshalling: a Janet value written into memory as a C value would
//! appear there, and the same memory read back. It takes Janet values and can
//! raise on every second line.
//!
//! Misaligned access is written out. A `:pack`ed struct field lands wherever
//! the previous field ended, so a `double` field can sit at an odd offset.
//! Writing it through a `*double` is undefined, and aborts under the
//! sanitizer, which is what makes the differential corpus's byte-image half
//! run at `ReleaseFast`. Every access here goes through an `align(1)` pointer:
//! the same store and the same byte image, said in a way that is defined.
//!
//! The argument layer raises, so a raise can cross these frames. Nothing here
//! owns anything a skipped cleanup would strand.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const args_core = @import("../args.zig");
const arrays = @import("../value/arrays.zig");
const config = @import("config");
const ffi_types = @import("types.zig");
const gc_alloc = @import("../gc.zig");
const inttypes = @import("../value/ints.zig");
const pp_format = @import("../pp/format.zig");
const raise = @import("../../api/raise.zig");
const repr = @import("repr");
const value = @import("../value.zig");
const fatal = @import("../fatal.zig");
const vectors = @import("../value/vectors.zig");
const wrap = @import("../value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

const has_int_types = config.int_types;

// ==========================================================================
// Aliased types
// ==========================================================================

const Struct = ffi_types.Struct;
const Type = ffi_types.Type;

// ==========================================================================
// Public functions
// ==========================================================================

/// Every Janet type that can stand in for a C pointer.
pub fn getPointer(argv: []const repr.Value, n: usize) raise.Error!?*anyopaque {
    return switch (repr.typeOf(argv[n])) {
        repr.Tag.pointer,
        repr.Tag.string,
        repr.Tag.symbol,
        repr.Tag.nfunction,
        => wrap.toPointer(argv[n]),
        repr.Tag.abstract => @ptrCast(@constCast((try args_core.getBytes(argv, n)).bytes)),
        repr.Tag.buffer => wrap.toBuffer(argv[n]).data,
        repr.Tag.function => blk: {
            // A function passed here is almost certainly a callback, so it
            // joins the root set and never leaves it.
            gc_alloc.gcroot(argv[n]);
            break :blk wrap.toPointer(argv[n]);
        },
        repr.Tag.nil => null,
        else => pp_format.panicf(
            "bad slot #%d, expected ffi pointer convertible type, got %v",
            .{ @as(i64, @intCast(n)), argv[n] },
        ),
    };
}

/// The inverse of `writeOne`, on the assumption that the memory is what the
/// type says it is.
pub fn readOne(from: [*]const u8, ty: Type, recur: c_int) raise.Error!repr.Value {
    if (recur == 0) return raise.panic("recursion too deep");

    if (ty.array_count >= 0) {
        const el_type = ty.element();
        const el_size = ffi_types.typeSize(el_type);
        const array = arrays.new(@intCast(ty.array_count));
        var cursor = from;
        // `array_count` stays signed, since -1 is its "not an array" marker,
        // and the branch above is what rules that out here.
        for (0..@as(usize, @intCast(ty.array_count))) |_| {
            try arrays.push(array, try readOne(cursor, el_type, recur - 1));
            cursor += el_size;
        }
        return wrap.fromArray(array);
    }

    return switch (ty.prim) {
        .void => wrap.fromNil(),
        .@"struct" => blk: {
            // A struct read back is data, so it is a vector: `[ ]` is what
            // the type spelling and the value written to it both use.
            const st = ty.st.?;
            const members = Struct.fields(st);
            const block = gc_alloc.scratch_heap.alloc(repr.Value, st.field_count) catch
                fatal.outOfMemory();
            defer gc_alloc.scratch_heap.free(block);
            for (members[0..st.field_count], 0..) |member, i| {
                block[i] = try readOne(from + member.offset, member.type, recur - 1);
            }
            break :blk wrap.fromVector(vectors.fromSlice(block));
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
        // is not a valid `bool` in Zig, where C's `((bool *) from)[0]` is
        // merely nonzero. This gives the same result for every input and a
        // defined one for all of them.
        .bool => wrap.fromBoolean(get(u8, from) != 0),
        .int8 => wrap.fromNumber(@floatFromInt(get(i8, from))),
        .int16 => wrap.fromNumber(@floatFromInt(get(i16, from))),
        .int32 => wrap.fromNumber(@floatFromInt(get(i32, from))),
        .uint8 => wrap.fromNumber(@floatFromInt(get(u8, from))),
        .uint16 => wrap.fromNumber(@floatFromInt(get(u16, from))),
        .uint32 => wrap.fromNumber(@floatFromInt(get(u32, from))),
        // Without the integer types these two lose precision exactly as the C
        // original does, and the branch is on the build rather than on the
        // value for that reason.
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

/// A Janet value, laid out as its FFI type says.
///
/// The space and alignment available are assumed to be sufficient, which for
/// alignment is the assumption the packed-field defect breaks.
pub fn writeOne(
    to: *anyopaque,
    argv: []const repr.Value,
    n: usize,
    ty: Type,
    recur: c_int,
) raise.Error!void {
    if (recur == 0) return raise.panic("recursion too deep");
    const arg = argv[n];

    if (ty.array_count >= 0) {
        const el_type = ty.element();
        const el_size = ffi_types.typeSize(el_type);
        // Gathered rather than read a run at a time: each element is written
        // through `writeOne`, which takes the elements as an argument list and
        // an index into it, so one block is what this needs.
        var gathered = try args_core.gatherArg(argv, n);
        const els = gathered.items;
        if (els.len != ty.array_count) {
            return pp_format.panicf("bad array length, expected %d, got %d", .{ ty.array_count, @as(i64, @intCast(els.len)) });
        }
        var cursor: [*]u8 = @ptrCast(to);
        for (0..els.len) |i| {
            try writeOne(cursor, els, i, el_type, recur - 1);
            cursor += el_size;
        }
        gathered.free();
        return;
    }

    switch (ty.prim) {
        .void => {
            if (!repr.checkType(arg, repr.Tag.nil)) {
                return pp_format.panicf("expected nil, got %v", .{arg});
            }
        },
        .@"struct" => {
            var gathered = try args_core.gatherArg(argv, n);
            const els = gathered.items;
            const st = ty.st.?;
            if (els.len != st.field_count) {
                return pp_format.panicf(
                    "wrong number of fields in struct, expected %d, got %d",
                    .{ @as(i32, @bitCast(st.field_count)), @as(i64, @intCast(els.len)) },
                );
            }
            const members = Struct.fields(st);
            for (members[0..els.len], 0..) |member, i| {
                const at: [*]u8 = @as([*]u8, @ptrCast(to)) + member.offset;
                try writeOne(at, els, i, member.type, recur - 1);
            }
            gathered.free();
        },
        .double => put(f64, to, try args_core.getNumber(argv, n)),
        .float => put(f32, to, @floatCast(try args_core.getNumber(argv, n))),
        .ptr => put(?*anyopaque, to, try getPointer(argv, n)),
        .string => put([*]const u8, to, try args_core.getCString(argv, n)),
        .bool => put(bool, to, try args_core.getBoolean(argv, n)),
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

/// Write one argument into a register slot, extended to the register's width.
///
/// Extension is the caller's job under both AAPCS64 and the SysV ABI: a callee
/// that declares `int8_t` is entitled to read the whole register without
/// masking. `writeOne` places a value at the type's own width, which is what a
/// struct field and an array element need and is wrong here: an `:s8` of -1
/// written as one byte reaches such a callee as 255, whatever is in the other
/// seven bytes.
///
/// Everything wider than a register, and everything that is not an integer,
/// falls through to `writeOne`: a float's register is written at full width by
/// that path already, and an aggregate in a register bank is a pair the caller
/// splits itself.
pub fn writeRegister(
    to: *u64,
    argv: []const repr.Value,
    n: usize,
    ty: Type,
    recur: c_int,
) raise.Error!void {
    if (ty.array_count < 0) {
        switch (ty.prim) {
            .bool => {
                to.* = if (try args_core.getBoolean(argv, n)) 1 else 0;
                return;
            },
            .int8, .int16, .int32 => {
                const narrowed = try args_core.getInteger(argv, n);
                const widened: i64 = switch (ty.prim) {
                    .int8 => @as(i8, @truncate(narrowed)),
                    .int16 => @as(i16, @truncate(narrowed)),
                    else => narrowed,
                };
                to.* = @bitCast(widened);
                return;
            },
            .uint8, .uint16, .uint32 => {
                const narrowed = try args_core.getUInteger64(argv, n);
                to.* = switch (ty.prim) {
                    .uint8 => @as(u8, @truncate(narrowed)),
                    .uint16 => @as(u16, @truncate(narrowed)),
                    else => @as(u32, @truncate(narrowed)),
                };
                return;
            },
            else => {},
        }
    }
    return writeOne(to, argv, n, ty, recur);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Load a `T` from `from`, which may be aligned for nothing at all.
inline fn get(comptime T: type, from: [*]const u8) T {
    const p: *align(1) const T = @ptrCast(from);
    return p.*;
}

/// Store `value` at `to`, which may be aligned for nothing at all.
inline fn put(comptime T: type, to: *anyopaque, val: T) void {
    const p: *align(1) T = @ptrCast(@alignCast(@as([*]align(1) u8, @ptrCast(to))));
    p.* = val;
}
