//! The growable byte container, its capacity policy, its push primitives, and
//! the `buffer/*` surface.
//!
//! `new` allocates a collectable buffer, `newFrom` copies bytes into one, and
//! `init` sets up a buffer the caller owns. `pushBytes`, `pushU8`, `pushU16`,
//! `pushU32` and `pushU64` append; `ensure` and `extra` make room ahead of
//! them; `setcount` sets the length, zero-filling what it newly covers.
//! `pointerUnsafe` wraps memory the runtime did not allocate.
//!
//! `arrays.zig` is the sibling: one data structure with two element types, a
//! `GCObject` header followed by `count`, `capacity` and `data`, with `data`
//! in a separate heap block reallocated in place. They are separate files
//! because Janet's taxonomy separates them: a buffer is bytes and an array is
//! indexed. Neither calls into the other, and the shared layout is a fact
//! rather than a dependency. A buffer is not traversed here either:
//! `gc/mark.zig` skips its bytes, nothing below marks, and nothing below frees
//! a collectable block.
//!
//! ## Nothing here is stranded by a raise
//!
//! Three functions raise directly, `canRealloc`, `pointerUnsafe` and `extra`,
//! and each of those raises happens before the allocation it guards:
//! `canRealloc` runs before the reallocation it protects, and `extra`'s
//! overflow check is its first statement. So no path below keeps a raw block
//! between acquiring it and storing it where the collector can see it, which
//! is the one shape a skipped cleanup would turn into a leak.
//!
//! ## The capacity policy cannot overflow
//!
//! `ensure` computes the product in `i64` where both factors fit in 32 bits
//! and clamps at `maxInt(i32)`, and the growth is never caller-supplied: there
//! is no `buffer/ensure` binding, and every call under `src/` passes 1 or 2.
//! `array/ensure` is reachable from Janet, so `arrays.zig` validates its
//! growth and this file does not.
//!
//! `ensure` charges GC pressure before the reallocation where the array's
//! charges after, so a failed buffer growth is accounted for and a failed
//! array growth is not. Both end the process, so nothing observes it.
//!
//! ## The nfunction surface
//!
//! A published `NFunction` has no error channel in its signature, so the
//! `nfunBuffer*` functions deliver a raise through `raise.Error!`. Nothing in
//! them is stranded across a call that can raise, which for a growable
//! container means in particular that no local caches `data` across an
//! `ensure`: a reallocation invalidates it whether or not anything raises.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const args_core = @import("../args.zig");
const c = @import("cabi");
const corefn = @import("../corefn.zig");
const fatal = @import("../fatal.zig");
const gc_alloc = @import("../gc.zig");
const pp_format = @import("../pp/format.zig");
const raise = @import("../../api/raise.zig");
const repr = @import("repr");
const strings = @import("strings.zig");
const tables = @import("tables.zig");
const utils = @import("../utils.zig");
const wrap = @import("helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// Whether the host is big-endian, decided at compile time.
/// `shouldReverseBytes` compares a caller's keyword against it.
const big_endian = (builtin.cpu.arch.endian() == .big);

/// Bit 0 of the GC header's per-type field: this buffer's payload is memory
/// the runtime did not allocate, so every growth path and `deinit` leave the
/// pointer alone.
const own_foreign: u6 = 1;

// ==========================================================================
// Types
// ==========================================================================

/// A buffer with a byte index and a bit index within that byte, which is what
/// `bitloc` decodes a bit index into.
const BitLoc = struct { buffer: *Buffer, index: i32, bit: u3 };

/// The growable byte container: a collectable header, a count, a capacity, and
/// a payload in a separate heap block.
///
/// The methods below allocate nothing. `ensure`, `extra` and the constructors
/// are what reach the allocator.
pub const Buffer = struct {
    gc: abi.GCObject = .{},
    count: usize = 0,
    capacity: usize = 0,
    data: ?[*]u8 = null,
    /// The bytes written so far. Empty rather than a trap where `data` is
    /// null, which is a default-initialised `Buffer` or a foreign one wrapping
    /// a null pointer. `initImpl` floors the capacity at four, so `init`,
    /// `new` and `newFrom` always leave a payload behind.
    pub inline fn slice(self: anytype) utils.View(@TypeOf(self), u8) {
        if (self.count == 0) return &.{};
        return self.data.?[0..self.count];
    }

    /// Stores one byte at the end and advances the count. The caller has
    /// already made room, through `buffers.extra` or `buffers.ensure`.
    pub inline fn appendAssumingCapacity(self: *Buffer, byte: u8) void {
        std.debug.assert(self.count < self.capacity);
        self.data.?[self.count] = byte;
        self.count += 1;
    }

    /// The allocation, `capacity` long, for the two callers that read or write
    /// outside the live range on purpose: `snprintf` fills past the end and
    /// then says how much it wrote, and the pretty-printer's newline
    /// compaction shortens the count first and then compacts what is still
    /// there into the space that leaves.
    pub inline fn reserved(self: *Buffer) []u8 {
        if (self.capacity == 0) return &.{};
        return self.data.?[0..self.capacity];
    }

    /// The room past the end, `capacity - count` bytes of it.
    pub inline fn spare(self: *Buffer) []u8 {
        if (self.capacity <= self.count) return &.{};
        return self.reserved()[self.count..];
    }
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Refuses to reallocate a buffer that does not own its memory.
///
/// Called before every reallocation of a buffer payload and never after one.
/// The callers are `ensure`, `extra` and `nfunBufferTrim`, plus
/// `test/buffer_array.zig`, which reaches it by import.
pub fn canRealloc(buffer: *Buffer) raise.Error!void {
    if (isForeign(buffer)) {
        return raise.panic("buffer cannot reallocate foreign memory");
    }
}

/// Releases `buffer`'s payload, and leaves a foreign payload alone.
///
/// `gc/sweep.zig`'s `deinitBlock` calls this too, which is a collectable
/// buffer's only route here.
pub fn deinit(buffer: *Buffer) void {
    if (!isForeign(buffer)) {
        utils.free(buffer.data);
        buffer.data = null;
    }
}

/// Grows `buffer` to at least `capacity_in` bytes, overshooting by `growth`.
///
/// The product is computed in 64 bits and clamped at `maxInt(i32)`, which is
/// the width a marshalled buffer records. `growth` is asserted positive rather
/// than checked, because it is never caller-supplied; the header says why.
pub fn ensure(buffer: *Buffer, capacity_in: usize, growth: i32) raise.Error!void {
    const old = buffer.data;
    if (capacity_in <= buffer.capacity) return;
    try canRealloc(buffer);
    std.debug.assert(growth > 0);
    // Cannot overflow: the capacity fits in 32 bits and so does the growth,
    // so the product fits in 62.
    const big_capacity: i64 = @as(i64, @intCast(capacity_in)) * @as(i64, growth);
    const capacity: usize = @intCast(@min(big_capacity, std.math.maxInt(i32)));
    gc_alloc.gcpressure(capacity -% buffer.capacity);
    buffer.data = utils.resizeMany(u8, @ptrCast(old), capacity);
    buffer.capacity = capacity;
}

/// Reserves room for `n` more bytes, so that the next `n` pushes cannot
/// reallocate.
///
/// The overflow check is the first statement, before any allocation, which is
/// what makes the panic safe to raise through this frame.
pub fn extra(buffer: *Buffer, n: usize) raise.Error!void {
    const sum = @as(i64, @intCast(n)) + @as(i64, @intCast(buffer.count));
    if (sum > std.math.maxInt(i32)) return raise.panic("buffer overflow");
    const new_size: usize = @intCast(sum);
    if (new_size > buffer.capacity) {
        try canRealloc(buffer);
        const new_capacity: usize = if (new_size > @divTrunc(std.math.maxInt(i32), 2))
            std.math.maxInt(i32)
        else
            new_size *% 2;
        const new_data = utils.realloc(buffer.data, new_capacity);
        // The pressure is charged between the allocation and the null test, so
        // a failed growth is accounted for on the way out.
        gc_alloc.gcpressure(new_capacity -% buffer.capacity);
        if (new_data == null) fatal.outOfMemory();
        buffer.data = @ptrCast(new_data);
        buffer.capacity = new_capacity;
    }
}

/// Initialises a buffer the caller owns.
///
/// The block is not on a heap list, so `gc.flags.disabled` is set and the
/// collector leaves it alone.
pub fn init(buffer: *Buffer, capacity: usize) *Buffer {
    _ = initImpl(buffer, capacity);
    buffer.gc.data.next = null;
    buffer.gc.flags = .{ .disabled = true };
    return buffer;
}

/// Whether `buffer`'s payload is memory the runtime did not allocate.
pub inline fn isForeign(buffer: *const Buffer) bool {
    return buffer.gc.flags.own & own_foreign != 0;
}

/// Installs the `buffer/` nfunctions into `env`.
pub fn lib(env: *tables.Table) void {
    const push_tail = "Returns ds. " ++
        "Expands ds as necessary. Raises an error if the size limit is exceeded. " ++
        "order is `:le`, `:be` or `:native`.";
    const entries = comptime [_]corefn.Entry{
        corefn.reg("buffer/new", &nfunBufferNew, @src(), "(buffer/new capacity)", "Creates a new, empty buffer with enough backing memory for capacity bytes. " ++
            "Returns a new buffer of length 0."),
        corefn.reg("buffer/new-filled", &nfunBufferNewFilled, @src(), "(buffer/new-filled n)\n(buffer/new-filled n byte)", "Creates a new buffer of length n filled with byte. By default, byte is 0. " ++
            "byte is reduced modulo 256. Returns the new buffer."),
        corefn.reg("buffer/from-bytes", &nfunBufferFrombytes, @src(), "(buffer/from-bytes & byte-vals)", "Creates a buffer from integer parameters with byte values. Each integer " ++
            "is reduced modulo 256."),
        corefn.reg("buffer/fill", &nfunBufferFill, @src(), "(buffer/fill ds)\n(buffer/fill ds byte)", "Fills ds, a buffer, with byte, which defaults to 0. Does not change the length of ds. " ++
            "Returns ds mutated."),
        corefn.reg("buffer/trim", &nfunBufferTrim, @src(), "(buffer/trim ds)", "Sets the backing capacity of ds, a buffer, to its current length. Returns ds mutated."),
        corefn.reg("buffer/push-byte", &nfunBufferU8, @src(), "(buffer/push-byte ds & bytes)", "Appends each of bytes, integers reduced modulo 256, to ds, a buffer. Returns ds mutated. " ++
            "Expands ds as necessary. Raises an error if the size limit is exceeded."),
        corefn.reg("buffer/push-word", &nfunBufferWord, @src(), "(buffer/push-word ds & vals)", "Appends machine words to a buffer. The 4 bytes of the integer are appended " ++
            "in twos complement, little endian order, unsigned for all vals. Returns the modified buffer. " ++
            "Expands the buffer as necessary. Throws an error if size limit is exceeded."),
        corefn.reg("buffer/push-string", &nfunBufferChars, @src(), "(buffer/push-string ds & bytes)", "Appends each of bytes, a string, keyword, symbol or buffer, to the end of ds, a buffer. " ++
            "Returns ds mutated. " ++
            "Expands ds as necessary. Raises an error if the size limit is exceeded."),
        corefn.reg("buffer/push-uint16", &nfunBufferPushUint16, @src(), "(buffer/push-uint16 ds order n)", "Appends n, a 16 bit unsigned integer, to the end of ds, a buffer. " ++ push_tail),
        corefn.reg("buffer/push-uint32", &nfunBufferPushUint32, @src(), "(buffer/push-uint32 ds order n)", "Appends n, a 32 bit unsigned integer, to the end of ds, a buffer. " ++ push_tail),
        corefn.reg("buffer/push-uint64", &nfunBufferPushUint64, @src(), "(buffer/push-uint64 ds order n)", "Appends n, a 64 bit unsigned integer, to the end of ds, a buffer. " ++ push_tail),
        corefn.reg("buffer/push-float32", &nfunBufferPushFloat32, @src(), "(buffer/push-float32 ds order val)", "Appends the underlying bytes of val, a 32 bit float, to the end of ds, a buffer. " ++ push_tail),
        corefn.reg("buffer/push-float64", &nfunBufferPushFloat64, @src(), "(buffer/push-float64 ds order val)", "Appends the underlying bytes of val, a 64 bit float, to the end of ds, a buffer. " ++ push_tail),
        corefn.reg("buffer/push", &nfunBufferPush, @src(), "(buffer/push ds & vals)", "Appends both individual bytes and byte sequences to ds, a buffer. For each val in vals, " ++
            "appends the byte if val is an integer, otherwise appends the byte sequence. " ++
            "Thus, this function behaves like both ^buffer/push-string and ^buffer/push-byte. " ++
            "Returns ds mutated. " ++
            "Expands ds as necessary. Raises an error if the size limit is exceeded."),
        corefn.reg("buffer/push-at", &nfunBufferPushAt, @src(), "(buffer/push-at ds index & vals)", "Behaves as ^buffer/push, but overwrites the bytes of ds from index onward, " ++
            "extending ds if the data runs past its end. index must be between 0 and the length of ds. Returns ds mutated."),
        corefn.reg("buffer/popn", &nfunBufferPopn, @src(), "(buffer/popn ds n)", "Removes the last n bytes from ds, a buffer, or all of them if ds is shorter. n must be non-negative. Returns ds mutated."),
        corefn.reg("buffer/clear", &nfunBufferClear, @src(), "(buffer/clear ds)", "Sets the length of ds, a buffer, to 0. ds retains " ++
            "its backing memory. Returns ds mutated."),
        corefn.reg("buffer/slice", &nfunBufferSlice, @src(), "(buffer/slice bytes)\n(buffer/slice bytes start)\n(buffer/slice bytes start end)", "Returns a new buffer holding the bytes of bytes, a string, keyword, symbol or buffer, " ++
            "from start to end. The range is half open, [start, end). All indexing " ++
            "is from 0. start and end can also be negative to indicate indexing " ++
            "from the end. A negative start is exclusive and a negative end is inclusive. " ++
            "By default, start is 0 and end is the length of bytes."),
        corefn.reg("buffer/bit-set", &nfunBufferBitset, @src(), "(buffer/bit-set ds index)", "Sets the bit at index in ds, a buffer. Bit 0 is the least significant bit of the first byte. Raises if index is beyond the length of ds. Returns ds mutated."),
        corefn.reg("buffer/bit-clear", &nfunBufferBitclear, @src(), "(buffer/bit-clear ds index)", "Clears the bit at index in ds, a buffer. Bit 0 is the least significant bit of the first byte. Raises if index is beyond the length of ds. Returns ds mutated."),
        corefn.reg("buffer/bit", &nfunBufferBitget, @src(), "(buffer/bit ds index)", "Gets the bit at index in ds, a buffer. Bit 0 is the least significant bit of the first byte. Returns true if the bit is set, false if not."),
        corefn.reg("buffer/bit-toggle", &nfunBufferBittoggle, @src(), "(buffer/bit-toggle ds index)", "Toggles the bit at index in ds, a buffer. Bit 0 is the least significant bit of the first byte. Raises if index is beyond the length of ds. Returns ds mutated."),
        corefn.reg("buffer/blit", &nfunBufferBlit, @src(), "(buffer/blit ds src)\n(buffer/blit ds src ds-start)\n(buffer/blit ds src ds-start src-start)\n(buffer/blit ds src ds-start src-start src-end)", "Copies the bytes of src, a string, keyword, symbol or buffer, into ds, a buffer, " ++
            "overwriting its bytes and extending it as needed. Can optionally take indices that " ++
            "indicate which part of src to copy into which part of ds. Indices can be " ++
            "negative in order to index from the end of src or ds. Returns ds mutated."),
        corefn.reg("buffer/format", &nfunBufferFormat, @src(), "(buffer/format ds format & args)", "Formats args as ^string/format does and appends the result to ds, a buffer. Returns " ++
            "ds mutated."),
        corefn.reg("buffer/format-at", &nfunBufferFormatAt, @src(), "(buffer/format-at ds at format & args)", "Formats args as ^string/format does and writes the result into ds, a buffer, starting at at. " ++
            "A negative at indexes from the end of ds. Returns ds mutated."),
    };
    corefn.install(env, entries);
}

/// Allocates a collectable buffer with room for `capacity` bytes, floored at
/// four.
pub fn new(capacity: usize) *Buffer {
    const buffer = gc_alloc.gcalloc(Buffer, .buffer);
    return initImpl(buffer, capacity);
}

/// Allocates a collectable buffer with a copy of `bytes` in it.
///
/// `arrays.newFrom` is the same constructor for the other mutable sequence,
/// and this raises where that does not: `pushBytes` grows through `extra`,
/// which is where a length no allocation could satisfy is refused.
pub fn newFrom(bytes: []const u8) raise.Error!*Buffer {
    const buffer = new(bytes.len);
    try pushBytes(buffer, bytes);
    return buffer;
}

/// Wraps memory the runtime did not allocate.
///
/// `memory` is the payload, `capacity` its size and `count` how much of it is
/// live. The result is collectable but its payload is not: the foreign flag
/// makes `deinit` and every growth path leave the pointer alone.
pub fn pointerUnsafe(memory: ?*anyopaque, capacity: usize, count: usize) raise.Error!*Buffer {
    if (capacity < count) return raise.panic("capacity < count");
    const buffer = gc_alloc.gcalloc(Buffer, .buffer);
    buffer.gc.flags.own |= own_foreign;
    buffer.capacity = capacity;
    buffer.count = count;
    buffer.data = @ptrCast(memory);
    return buffer;
}

/// Appends `bytes` to `buffer`.
pub fn pushBytes(buffer: *Buffer, bytes: []const u8) raise.Error!void {
    if (0 == bytes.len) return;
    try extra(buffer, @intCast(bytes.len));
    _ = c.memcpy(buffer.data.? + @as(usize, @intCast(buffer.count)), bytes.ptr, bytes.len);
    buffer.count += @intCast(bytes.len);
}

/// Appends `bytes` to the buffer a `Value` names, refusing anything that is
/// not a buffer.
///
/// This is the module boundary's form, for the reason `arrays.pushChecked`
/// gives: a `*Buffer` does not cross to an author, so a module names a buffer
/// by its `Value` and the tag test is here.
pub fn pushBytesChecked(v: repr.Value, bytes: []const u8) raise.Error!void {
    if (!repr.checkType(v, repr.Tag.buffer)) {
        return pp_format.panicf("expected %T, got %v", .{ repr.TagSet.one(repr.Tag.buffer), v });
    }
    return pushBytes(wrap.toBuffer(v), bytes);
}

/// Appends a NUL-terminated string to `buffer`, measuring it with `strlen`.
pub fn pushCString(buffer: *Buffer, cstring: [*:0]const u8) raise.Error!void {
    return pushBytes(buffer, cstring[0..c.strlen(cstring)]);
}

/// `pushCString` for a caller with no error channel, delivering the raise
/// through `raise.toAbi`.
pub fn pushCstringAbi(buffer: *Buffer, cstring: [*:0]const u8) void {
    raise.toAbi(pushCString(buffer, cstring));
}

/// Appends a Janet string to `buffer`, taking its length from its head.
pub fn pushString(buffer: *Buffer, string: [*]const u8) raise.Error!void {
    return pushBytes(buffer, string[0..stringLength(string)]);
}

/// The three multi-byte pushes write little-endian regardless of host order.
/// Each shifts rather than copying the host's bytes.
pub fn pushU16(buffer: *Buffer, x: u16) raise.Error!void {
    try extra(buffer, 2);
    const room = buffer.spare();
    room[0] = @truncate(x);
    room[1] = @truncate(x >> 8);
    buffer.count += 2;
}

pub fn pushU32(buffer: *Buffer, x: u32) raise.Error!void {
    try extra(buffer, 4);
    const room = buffer.spare();
    inline for (0..4) |i| {
        room[i] = @truncate(x >> (8 * i));
    }
    buffer.count += 4;
}

pub fn pushU64(buffer: *Buffer, x: u64) raise.Error!void {
    try extra(buffer, 8);
    const room = buffer.spare();
    inline for (0..8) |i| {
        room[i] = @truncate(x >> (8 * i));
    }
    buffer.count += 8;
}

/// Appends one byte to `buffer`.
pub fn pushU8(buffer: *Buffer, byte: u8) raise.Error!void {
    try extra(buffer, 1);
    buffer.appendAssumingCapacity(byte);
}

/// Sets `buffer`'s length to `count`, zero-filling any bytes the count newly
/// covers.
pub fn setcount(buffer: *Buffer, count: usize) raise.Error!void {
    if (count > buffer.count) {
        const oldcount = buffer.count;
        try ensure(buffer, count, 1);
        @memset(buffer.reserved()[oldcount..count], 0);
    }
    buffer.count = count;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Decodes a bit index into a byte index and a bit within that byte.
///
/// `argv` is the nfunction's arguments, the buffer at 0 and the bit index at
/// 1. The test `bitindex != x` is what rejects a fractional index, a check the
/// argument layer cannot make because the value is legitimately wider than the
/// byte index it becomes.
fn bitloc(argv: []repr.Value) raise.Error!BitLoc {
    try args_core.fixarity(argv, 2);
    const buffer = try args_core.getBuffer(argv, 0);
    const x = try args_core.getNumber(argv, 1);
    const bitindex: i64 = @intFromFloat(x);
    const byteindex = bitindex >> 3;
    if (@as(f64, @floatFromInt(bitindex)) != x or bitindex < 0 or byteindex >= buffer.count) {
        return pp_format.panicf("invalid bit index %v", .{argv[1]});
    }
    return .{ .buffer = buffer, .index = @intCast(byteindex), .bit = @intCast(bitindex & 7) };
}

/// `buffer/bit-clear`: the bit at a bit index cleared.
fn nfunBufferBitclear(argv: []repr.Value) raise.Error!repr.Value {
    const loc = try bitloc(argv);
    loc.buffer.slice()[@intCast(loc.index)] &= ~(@as(u8, 1) << loc.bit);
    return argv[0];
}

/// `buffer/bit`: whether the bit at a bit index is set.
fn nfunBufferBitget(argv: []repr.Value) raise.Error!repr.Value {
    const loc = try bitloc(argv);
    const set = loc.buffer.slice()[@intCast(loc.index)] & (@as(u8, 1) << loc.bit);
    return wrap.fromBoolean(set != 0);
}

/// `buffer/bit-set`: the bit at a bit index set.
fn nfunBufferBitset(argv: []repr.Value) raise.Error!repr.Value {
    const loc = try bitloc(argv);
    loc.buffer.slice()[@intCast(loc.index)] |= @as(u8, 1) << loc.bit;
    return argv[0];
}

/// `buffer/bit-toggle`: the bit at a bit index flipped.
fn nfunBufferBittoggle(argv: []repr.Value) raise.Error!repr.Value {
    const loc = try bitloc(argv);
    loc.buffer.slice()[@intCast(loc.index)] ^= @as(u8, 1) << loc.bit;
    return argv[0];
}

/// `buffer/blit`: part of one byte sequence copied into a buffer, growing it
/// where the copy runs past the end.
fn nfunBufferBlit(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 2, 5);
    const dest = try args_core.getBuffer(argv, 0);
    var src = try args_core.getBytes(argv, 1);
    const same_buf = src.bytes == dest.data;
    var offset_dest: i32 = 0;
    var offset_src: i32 = 0;
    if (argv.len > 2 and !repr.checkType(argv[2], repr.Tag.nil)) {
        offset_dest = try args_core.getHalfRange(argv, 2, @intCast(dest.count), "dest-start");
    }
    if (argv.len > 3 and !repr.checkType(argv[3], repr.Tag.nil)) {
        offset_src = try args_core.getHalfRange(argv, 3, @intCast(src.len), "src-start");
    }
    var length_src: i32 = undefined;
    if (argv.len > 4) {
        var src_end: i32 = @intCast(src.len);
        if (!repr.checkType(argv[4], repr.Tag.nil)) {
            src_end = try args_core.getHalfRange(argv, 4, @intCast(src.len), "src-end");
        }
        length_src = src_end - offset_src;
        if (length_src < 0) length_src = 0;
    } else {
        length_src = @as(i32, @intCast(src.len)) - offset_src;
    }
    const last: i64 = @as(i64, offset_dest) + length_src;
    if (last > std.math.maxInt(i32)) return raise.panic("buffer blit out of range");
    const last32: i32 = @intCast(last);
    try ensure(dest, @intCast(last32), 2);
    if (last32 > dest.count) dest.count = @intCast(last32);
    if (length_src != 0) {
        const n: usize = @intCast(length_src);
        // `ensure` may have moved the payload and invalidated `src`.
        if (same_buf) src.bytes = dest.data.?;
        const to = dest.data.? + @as(usize, @intCast(offset_dest));
        const from = src.bytes.? + @as(usize, @intCast(offset_src));
        if (same_buf) {
            if (@intFromPtr(to) < @intFromPtr(from)) {
                std.mem.copyForwards(u8, to[0..n], from[0..n]);
            } else {
                std.mem.copyBackwards(u8, to[0..n], from[0..n]);
            }
        } else {
            @memcpy(to[0..n], from[0..n]);
        }
    }
    return argv[0];
}

/// `buffer/push-string`: byte sequences appended.
fn nfunBufferChars(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    const buffer = try args_core.getBuffer(argv, 0);
    for (1..argv.len) |i| try pushBytesAliasSafe(buffer, try args_core.getBytes(argv, i));
    return argv[0];
}

/// `buffer/clear`: the count set to zero, the backing capacity kept.
fn nfunBufferClear(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    (try args_core.getBuffer(argv, 0)).count = 0;
    return argv[0];
}

/// `buffer/fill`: every live byte replaced, the length unchanged.
fn nfunBufferFill(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    const buffer = try args_core.getBuffer(argv, 0);
    const byte: u8 = if (argv.len == 2) @truncate(@as(u32, @bitCast(try args_core.getInteger(argv, 1)))) else 0;
    if (buffer.count != 0) @memset(buffer.slice(), byte);
    return argv[0];
}

/// Refuses a format whose destination is also one of its arguments.
///
/// `(buffer/format b "%s" b)` has no defensible answer: the rendering would be
/// of the buffer *partway through the call that is writing it*, and the three
/// conversion families disagreed about which moment that was -- `%p` and `%q`
/// reported the buffer as at the call, `%w`, `%v` and `%y` as it stood when
/// the conversion ran, and `%s` read the byte view it had taken before a push
/// reallocated the block, so it copied freed memory and printed different
/// debris on each run. Refused on 2026-09-19 rather than specified, because
/// none of the three readings is worth keeping.
///
/// The check is shallow, and deliberately: it catches what a program actually
/// writes. A buffer reachable only inside another argument, as in
/// `(buffer/format b "%w" [b])`, still arrives at the printer, where
/// `pp.escapeBufferB` reserves the worst case before reading and so stays
/// safe. What is removed here is the unsafe path, `%s`, which takes its bytes
/// directly from an argument and so cannot be reached that way.
fn refuseSelfFormat(buffer: *Buffer, argv: []repr.Value, first: usize) raise.Error!void {
    for (argv[first..]) |arg| {
        if (!repr.checkType(arg, repr.Tag.buffer)) continue;
        if (wrap.toBuffer(arg) == buffer) {
            return raise.panic("cannot format a buffer into itself");
        }
    }
}

/// `buffer/format`: `pp_format.bufferFormat` appended at the end.
fn nfunBufferFormat(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 2, -1);
    const buffer = try args_core.getBuffer(argv, 0);
    const strfrmt = try args_core.getString(argv, 1);
    try refuseSelfFormat(buffer, argv, 2);
    try pp_format.bufferFormat(buffer, @ptrCast(strfrmt), 2, argv);
    return argv[0];
}

/// `buffer/format-at`: `buffer/format` written at an index instead of at the
/// end, with the original length restored where the write was shorter.
fn nfunBufferFormatAt(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 2, -1);
    const buffer = try args_core.getBuffer(argv, 0);
    var at = try args_core.getInteger(argv, 1);
    if (at < 0) at += @as(i32, @intCast(buffer.count)) + 1;
    if (at > buffer.count or at < 0) {
        return pp_format.panicf("expected index at to be in range [0, %d), got %d", .{ @as(i64, @intCast(buffer.count)), at });
    }
    const strfrmt = try args_core.getString(argv, 2);
    // Before the truncation below, not after: a refusal must leave the buffer
    // as it found it, and setting `count` first would leave a raised call
    // having thrown the tail away.
    try refuseSelfFormat(buffer, argv, 3);
    const oldcount = buffer.count;
    buffer.count = @intCast(at);
    try pp_format.bufferFormat(buffer, @ptrCast(strfrmt), 3, argv);
    if (buffer.count < oldcount) buffer.count = oldcount;
    return argv[0];
}

/// `buffer/from-bytes`: a buffer of the byte values given as arguments.
fn nfunBufferFrombytes(argv: []repr.Value) raise.Error!repr.Value {
    const buffer = new(argv.len);
    for (0..argv.len) |i| {
        const byte = try args_core.getInteger(argv, i);
        buffer.reserved()[i] = @truncate(@as(u32, @bitCast(byte)));
    }
    buffer.count = argv.len;
    return wrap.fromBuffer(buffer);
}

/// `buffer/new`: an empty buffer with capacity reserved.
fn nfunBufferNew(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const capacity = try args_core.getInteger(argv, 0);
    // A negative request is a zero request, and `initImpl`'s floor of four
    // then treats the two alike.
    return wrap.fromBuffer(new(if (capacity < 0) 0 else @intCast(capacity)));
}

/// `buffer/new-filled`: a buffer of `count` bytes, all set to one value.
fn nfunBufferNewFilled(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    const requested = try args_core.getInteger(argv, 0);
    const count: usize = if (requested < 0) 0 else @intCast(requested);
    const byte: u8 = if (argv.len == 2) @truncate(@as(u32, @bitCast(try args_core.getInteger(argv, 1)))) else 0;
    const buffer = new(count);
    if (count > 0) @memset(buffer.reserved()[0..count], byte);
    buffer.count = count;
    return wrap.fromBuffer(buffer);
}

/// `buffer/popn`: the last `n` bytes dropped, stopping at empty.
fn nfunBufferPopn(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 2);
    const buffer = try args_core.getBuffer(argv, 0);
    const n = try args_core.getInteger(argv, 1);
    if (n < 0) return raise.panic("n must be non-negative");
    const drop: usize = @intCast(n);
    buffer.count = if (buffer.count < drop) 0 else buffer.count - drop;
    return argv[0];
}

/// `buffer/push`: bytes and byte sequences appended, by argument type.
fn nfunBufferPush(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    try push(try args_core.getBuffer(argv, 0), argv, 1, argv.len);
    return argv[0];
}

/// `buffer/push-at`: `buffer/push` written at an index instead of at the end.
fn nfunBufferPushAt(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 2, -1);
    const buffer = try args_core.getBuffer(argv, 0);
    const index = try args_core.getInteger(argv, 1);
    const old_count: i32 = @intCast(buffer.count);
    if (index < 0 or index > old_count) return pp_format.panicf("index out of range [0, %d)", .{old_count});
    buffer.count = @intCast(index);
    try push(buffer, argv, 2, argv.len);
    if (buffer.count < old_count) buffer.count = @intCast(old_count);
    return argv[0];
}

/// `buffer/push-float32`: four bytes of a float, in the caller's byte order.
fn nfunBufferPushFloat32(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 3);
    const buffer = try args_core.getBuffer(argv, 0);
    const reverse = try shouldReverseBytes(argv, 1);
    try pushScalar(f32, buffer, @floatCast(try args_core.getNumber(argv, 2)), reverse);
    return argv[0];
}

/// `buffer/push-float64`: eight bytes of a float, in the caller's byte order.
fn nfunBufferPushFloat64(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 3);
    const buffer = try args_core.getBuffer(argv, 0);
    const reverse = try shouldReverseBytes(argv, 1);
    try pushScalar(f64, buffer, try args_core.getNumber(argv, 2), reverse);
    return argv[0];
}

/// `buffer/push-uint16`: two bytes of an integer, in the caller's byte order.
fn nfunBufferPushUint16(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 3);
    const buffer = try args_core.getBuffer(argv, 0);
    const reverse = try shouldReverseBytes(argv, 1);
    try pushScalar(u16, buffer, try args_core.getUInteger16(argv, 2), reverse);
    return argv[0];
}

/// `buffer/push-uint32`: four bytes of an integer, in the caller's byte order.
fn nfunBufferPushUint32(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 3);
    const buffer = try args_core.getBuffer(argv, 0);
    const reverse = try shouldReverseBytes(argv, 1);
    try pushScalar(u32, buffer, try args_core.getUInteger(argv, 2), reverse);
    return argv[0];
}

/// `buffer/push-uint64`: eight bytes of an integer, in the caller's byte
/// order.
fn nfunBufferPushUint64(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 3);
    const buffer = try args_core.getBuffer(argv, 0);
    const reverse = try shouldReverseBytes(argv, 1);
    try pushScalar(u64, buffer, try args_core.getUInteger64(argv, 2), reverse);
    return argv[0];
}

/// `buffer/slice`: a new buffer over a half-open range of a byte sequence.
fn nfunBufferSlice(argv: []repr.Value) raise.Error!repr.Value {
    const view = try args_core.getBytes(argv, 0);
    const range = try args_core.getSlice(argv);
    const len: usize = @intCast(range.end - range.start);
    const buffer = new(len);
    if (len != 0) @memcpy(buffer.reserved()[0..len], args_core.viewBytes(view)[@intCast(range.start)..][0..len]);
    buffer.count = len;
    return wrap.fromBuffer(buffer);
}

/// `buffer/trim`: the backing capacity set to the current length.
///
/// The floor of four is not `array/trim`'s behaviour: an empty buffer keeps a
/// four-byte allocation where an empty array releases its payload entirely.
fn nfunBufferTrim(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const buffer = try args_core.getBuffer(argv, 0);
    try canRealloc(buffer);
    if (buffer.count < buffer.capacity) {
        const newcap = if (buffer.count > 4) buffer.count else 4;
        const new_data = utils.realloc(@ptrCast(buffer.data), @intCast(newcap)) orelse
            fatal.outOfMemory();
        buffer.data = @ptrCast(new_data);
        buffer.capacity = newcap;
    }
    return argv[0];
}

/// `buffer/push-byte`: byte values appended.
fn nfunBufferU8(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    const buffer = try args_core.getBuffer(argv, 0);
    for (1..argv.len) |i| {
        try pushU8(buffer, @truncate(@as(u32, @bitCast(try args_core.getInteger(argv, i)))));
    }
    return argv[0];
}

/// `buffer/push-word`: machine words appended, four bytes each, little-endian.
fn nfunBufferWord(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    const buffer = try args_core.getBuffer(argv, 0);
    for (1..argv.len) |i| {
        const number = try args_core.getNumber(argv, i);
        const word: u32 = @intFromFloat(number);
        if (@as(f64, @floatFromInt(word)) != number) {
            return pp_format.panicf("cannot convert %v to machine word", .{argv[i]});
        }
        try pushU32(buffer, word);
    }
    return argv[0];
}

/// Gives `buffer` its initial payload, at a capacity floored at four.
///
/// Shared by the collectable and the caller-owned constructors, and it writes
/// no field of `gc`, so `init` can set those afterwards.
fn initImpl(buffer: *Buffer, capacity_in: usize) *Buffer {
    const capacity = @max(capacity_in, 4);
    gc_alloc.gcpressure(capacity);
    buffer.count = 0;
    buffer.capacity = capacity;
    buffer.data = utils.allocMany(u8, capacity);
    return buffer;
}

/// Appends `argv[start..argc]` to `buffer`, a number as a byte and anything
/// else as a byte sequence, which is what makes `buffer/push` the union of
/// `buffer/push-byte` and `buffer/push-string`.
fn push(buffer: *Buffer, argv: []repr.Value, start: usize, argc: usize) raise.Error!void {
    for (start..argc) |i| {
        if (repr.checkType(argv[i], repr.Tag.number)) {
            try pushU8(buffer, @truncate(@as(u32, @bitCast(try args_core.getInteger(argv, i)))));
        } else {
            try pushBytesAliasSafe(buffer, try args_core.getBytes(argv, i));
        }
    }
}

/// Appends `view_in` to `buffer`, taking the view again where the two alias.
///
/// Pushing a buffer onto itself grows it, and the growth may move the payload,
/// so the room is reserved first and the view then taken again. Both call
/// sites write it out rather than sharing a helper.
fn pushBytesAliasSafe(buffer: *Buffer, view_in: abi.ByteView) raise.Error!void {
    var view = view_in;
    if (view.bytes == buffer.data) {
        try ensure(buffer, buffer.count + @as(usize, @intCast(view.len)), 2);
        view.bytes = buffer.data.?;
    }
    try pushBytes(buffer, args_core.viewBytes(view));
}

/// Appends `data`'s bytes to `buffer`, reversed where `reverse` says so.
///
/// The argument getters have already rejected anything that does not fit, so
/// the byte order is all that is left.
fn pushScalar(comptime T: type, buffer: *Buffer, data: T, reverse: bool) raise.Error!void {
    var bytes: [@sizeOf(T)]u8 = @bitCast(data);
    if (reverse) std.mem.reverse(u8, &bytes);
    try pushBytes(buffer, &bytes);
}

/// Whether `argv[n]`'s endianness keyword differs from the host's.
///
/// `:native` is always false and the other two are decided at compile time
/// against `big_endian`.
fn shouldReverseBytes(argv: []repr.Value, n: usize) raise.Error!bool {
    const order = try args_core.getKeyword(argv, n);
    if (utils.cstrcmp(order, "le") == 0) return big_endian;
    if (utils.cstrcmp(order, "be") == 0) return !big_endian;
    if (utils.cstrcmp(order, "native") == 0) return false;
    // The message names `argv[1]` rather than `argv[n]`. Every caller passes 1,
    // so the two agree, and the text is what a program sees either way.
    return pp_format.panicf("expected endianness :le, :be or :native, got %v", .{argv[1]});
}

/// A Janet string's length, read from its head.
inline fn stringLength(s: [*]const u8) u32 {
    return strings.head(s).length;
}
