//! `JanetBuffer`: the growable byte container, its capacity policy, its push
//! primitives and the `buffer/*` surface.
//!
//! `arrays.zig` is the sibling. Phase 8 Part 6 put buffer and array in one
//! file because they are one data structure with two element types — a
//! `JanetGCObject` header followed by `count`/`capacity`/`data`, with `data` in
//! a separate `janet_malloc` block reallocated in place, and the freeing of
//! that block left to `janet_deinit_block` in `gc_sweep.zig`. Phase 12's
//! namespace batch 2 separated them, because Janet's own taxonomy does: a
//! buffer is **bytes** and an array is **indexed**, which is the distinction
//! `janet_bytes_view` and `janet_indexed_view` draw and the one a reader
//! reaching for `arrays.new` beside `buffers.new` does not expect. See
//! `port/NAMESPACES.md`.
//!
//! Nothing here calls into `arrays.zig` and nothing there calls in here. The
//! shared layout is a fact about the C structs, not a dependency, which is why
//! this split is cheaper than batch 1's.
//!
//! Neither type is traversed here. `gc_mark.zig` walks an array's elements and
//! skips a buffer's bytes; nothing below marks, and nothing below frees a
//! collectable block.
//!
//! **The file is jump-transparent**, under the rule SPIKE-8 settled, and it is
//! the first subsystem where the reason is ordinary rather than exotic. Three
//! functions here call `janet_panic` directly — `janet_buffer_can_realloc`,
//! `janet_pointer_buffer_unsafe` and `janet_buffer_extra` — and `janet_gcalloc`
//! can trigger a collection, which runs finalizers, which SPIKE-8 permits to
//! raise. A signal from any of them unwinds straight through these frames, so
//! there is no `defer` in this file and `build.zig` checks that there is not.
//!
//! Every frame here is safe to leave that way, and it is worth saying why
//! rather than assuming it. The panics all happen *before* the allocation they
//! guard: `canRealloc` is called before the `janet_realloc` it protects, and
//! `extra`'s overflow check is the first statement in the function. So no path
//! below holds a raw block between acquiring it and storing it in a structure
//! the collector can see — the one shape that a skipped cleanup would turn
//! into a leak.
//!
//! ## Arithmetic reproduced rather than repaired
//!
//! The capacity policy multiplies a caller-supplied count by a caller-supplied
//! growth factor and trusts the product to be positive. C's conversion of the
//! negative result to `size_t` is defined and wraps; Zig's would trap, so the
//! conversions are written out through `asSize` below and the arithmetic uses
//! wrapping operators wherever the C original can wrap. `arrays.zig` records
//! the reachable instance of that, which is `array/ensure`'s.
//!
//! `janet_buffer_ensure` charges GC pressure before the `janet_realloc` and
//! `janet_array_ensure` charges it after, so a failed array growth is not
//! accounted for and a failed buffer growth is. Both exit the process on
//! failure, so nothing observes the difference. Preserved, so that the two
//! files' byte counts match the C term for term.
//!
//! ## `pushCString` and `pushCstringAbi`
//!
//! The raising kernel and its `callconv(.c)` abi differed by one letter's
//! case — `bufferPushCString` against `bufferPushCstring` — because increment
//! 5d's mechanical rule spelled the abi from `janet_buffer_push_cstring` and
//! the kernel had been named by hand. Under the namespace both would have
//! landed in one scope as `pushCString` and `pushCstring`, where picking the
//! wrong one silently swallows a raise. The abi is `pushCstringAbi` now,
//! after the tree's own convention for an abi over a raising implementation.

const std = @import("std");
const corefn = @import("corefn");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const args_core = @import("../args.zig");
const pp_format = @import("../pp/format.zig");
const builtin = @import("builtin");
const gc_alloc = @import("../gc.zig");
const utils = @import("../utils.zig");
const kind = @import("helpers/kind.zig");
const wrap = @import("helpers/wrap.zig");
const fatal = @import("../fatal.zig");

/// `safe_memcpy` from `src/core/util.c`. Declared here rather than imported:
/// `util.h` was never in a translation, and this function's parameters are
/// primitive, so no Janet type crosses. `arrays.zig` has
/// the same declaration for the same reason; `utils.zig` defines it without
/// `pub`, and making it `pub` is what deletes both.
extern fn safe_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void;

const buffer_flag_no_realloc: i32 = constants.JANET_BUFFER_FLAG_NO_REALLOC;
const mem_disabled: i32 = constants.JANET_MEM_DISABLED;

/// C's conversion of a signed count to `size_t`: sign-extend to the pointer
/// width, then reinterpret. For a negative count that yields a very large
/// size, which is exactly what the C code does and what `FOUND.md` records for
/// `array/ensure`. Written out because Zig has no implicit signed-to-unsigned
/// conversion and `@intCast` would trap on the values this reaches.
inline fn asSize(n: i32) usize {
    return @bitCast(@as(isize, n));
}

inline fn stringLength(s: [*]const u8) i32 {
    return types.stringHead(s).length;
}

// ------------------------------------------------------------------ buffer

/// Refuse to reallocate a buffer that does not own its memory. Called before
/// every `janet_realloc` of a buffer payload, never after one.
///
/// This is the increment's one seam, and it is a declaration rather than a
/// bridge — the same shape Part 3 needed for `janet_free_all_scratch`. The
/// function was `static` in `buffer.c`, and `cfun_buffer_trim` called it from
/// the standard-library half of the file that stayed in C, so it is exported
/// here and declared in `util.h` beside the other cross-file buffer helpers.
/// Phase 10 Part 6 brought that caller here too, and Phase 11 Part 9 took the
/// `janet_buffer_can_realloc` abi with `test/buffer_array.c`: `util.h` was
/// the only header that declared it, the migrated contract calls this function
/// directly, and `cfunBufferTrim` below is the last caller in the tree.
pub fn canRealloc(buffer: *types.JanetBuffer) raise.Raising(void) {
    if ((buffer.gc.flags & buffer_flag_no_realloc) != 0) {
        return raise.panic("buffer cannot reallocate foreign memory");
    }
}

/// Give a buffer its initial payload. Shared by the collectable and the
/// caller-owned constructors, and it touches no field of `gc` — which is why
/// `janet_buffer_init` can set those afterwards.
fn initImpl(buffer: *types.JanetBuffer, capacity_in: i32) *types.JanetBuffer {
    var capacity = capacity_in;
    if (capacity < 4) capacity = 4;
    gc_alloc.gcpressure(asSize(capacity));
    const data = utils.malloc(asSize(capacity)) orelse fatal.outOfMemory();
    buffer.count = 0;
    buffer.capacity = capacity;
    buffer.data = @ptrCast(data);
    return buffer;
}

/// Initialise a buffer the caller owns. The block is not on a heap list, so it
/// is marked `JANET_MEM_DISABLED` and the collector leaves it alone.
pub fn init(buffer: *types.JanetBuffer, capacity: i32) *types.JanetBuffer {
    _ = initImpl(buffer, capacity);
    buffer.gc.data.next = null;
    buffer.gc.flags = mem_disabled;
    return buffer;
}

/// Wrap memory the runtime did not allocate. The result is collectable but its
/// payload is not: `JANET_BUFFER_FLAG_NO_REALLOC` makes both `janet_buffer_deinit`
/// and every growth path leave the foreign pointer alone.
pub fn pointerUnsafe(memory: ?*anyopaque, capacity: i32, count: i32) raise.Raising(*types.JanetBuffer) {
    if (count < 0) return raise.panic("count < 0");
    if (capacity < count) return raise.panic("capacity < count");
    const buffer: *types.JanetBuffer = @ptrCast(@alignCast(gc_alloc.gcalloc(constants.JANET_MEMORY_BUFFER, @sizeOf(types.JanetBuffer))));
    buffer.gc.flags |= buffer_flag_no_realloc;
    buffer.capacity = capacity;
    buffer.count = count;
    buffer.data = @ptrCast(memory);
    return buffer;
}

/// Release a buffer's payload. Also called from `janet_deinit_block` in
/// `gc_sweep.zig`, which is the collectable buffer's only route here.
pub fn deinit(buffer: *types.JanetBuffer) void {
    if ((buffer.gc.flags & buffer_flag_no_realloc) == 0) {
        utils.free(buffer.data);
        buffer.data = null;
    }
}

/// Allocate a collectable buffer.
pub fn new(capacity: i32) *types.JanetBuffer {
    const buffer: *types.JanetBuffer = @ptrCast(@alignCast(gc_alloc.gcalloc(constants.JANET_MEMORY_BUFFER, @sizeOf(types.JanetBuffer))));
    return initImpl(buffer, capacity);
}

/// Grow a buffer to at least `capacity`, overshooting by `growth`.
///
/// The product is computed in 64 bits and clamped at the top only; a growth of
/// zero or less passes through as a zero or negative capacity, and the
/// conversions below reproduce what C then does with it. No caller inside the
/// tree reaches that — every one passes 1 or 2 — but the C API is public.
pub fn ensure(buffer: *types.JanetBuffer, capacity_in: i32, growth: i32) raise.Raising(void) {
    var capacity = capacity_in;
    const old = buffer.data;
    if (capacity <= buffer.capacity) return;
    try canRealloc(buffer);
    // Cannot overflow: both factors fit in 32 bits, so the product fits in 62.
    const big_capacity: i64 = @as(i64, capacity) * @as(i64, growth);
    capacity = if (big_capacity > std.math.maxInt(i32)) std.math.maxInt(i32) else @truncate(big_capacity);
    gc_alloc.gcpressure(asSize(capacity -% buffer.capacity));
    const new_data = utils.realloc(old, asSize(capacity)) orelse fatal.outOfMemory();
    buffer.data = @ptrCast(new_data);
    buffer.capacity = capacity;
}

pub fn janet_buffer_ensure(buffer: *types.JanetBuffer, capacity_in: i32, growth: i32) void {
    raise.reported(ensure(buffer, capacity_in, growth));
}

/// Set a buffer's length, zero-filling any bytes the count newly covers.
pub fn setcount(buffer: *types.JanetBuffer, count: i32) raise.Raising(void) {
    if (count < 0) return;
    if (count > buffer.count) {
        const oldcount = buffer.count;
        try ensure(buffer, count, 1);
        _ = c.memset(buffer.data.? + @as(usize, @intCast(oldcount)), 0, @intCast(count - oldcount));
    }
    buffer.count = count;
}

pub fn janet_buffer_setcount(buffer: *types.JanetBuffer, count: i32) void {
    raise.reported(setcount(buffer, count));
}

pub fn janet_buffer_extra(buffer: *types.JanetBuffer, n: i32) void {
    raise.reported(extra(buffer, n));
}

pub fn janet_pointer_buffer_unsafe(memory: ?*anyopaque, capacity: i32, count: i32) *types.JanetBuffer {
    return raise.reported(pointerUnsafe(memory, capacity, count));
}

/// Reserve room for `n` more bytes, so that the next `n` pushes cannot
/// reallocate. The overflow check is the first statement, before any
/// allocation, which is what makes the panic safe to raise through this frame.
pub fn extra(buffer: *types.JanetBuffer, n: i32) raise.Raising(void) {
    if (@as(i64, n) + @as(i64, buffer.count) > std.math.maxInt(i32)) {
        return raise.panic("buffer overflow");
    }
    // Cannot overflow for a positive `n`: the check above bounds the sum. A
    // negative `n` only shrinks it, and `count` is never negative.
    const new_size = buffer.count +% n;
    if (new_size > buffer.capacity) {
        try canRealloc(buffer);
        const new_capacity: i32 = if (new_size > @divTrunc(std.math.maxInt(i32), 2))
            std.math.maxInt(i32)
        else
            new_size *% 2;
        const new_data = utils.realloc(buffer.data, asSize(new_capacity));
        // The C original charges the pressure between the allocation and the
        // null test, so a failed growth is accounted for on the way out. Kept.
        gc_alloc.gcpressure(asSize(new_capacity -% buffer.capacity));
        if (new_data == null) fatal.outOfMemory();
        buffer.data = @ptrCast(new_data);
        buffer.capacity = new_capacity;
    }
}

pub fn pushCString(buffer: *types.JanetBuffer, cstring: [*:0]const u8) raise.Raising(void) {
    return pushBytes(buffer, cstring[0..c.strlen(cstring)]);
}

pub fn pushCstringAbi(buffer: *types.JanetBuffer, cstring: [*:0]const u8) void {
    raise.reported(pushCString(buffer, cstring));
}

pub fn pushBytes(buffer: *types.JanetBuffer, bytes: []const u8) raise.Raising(void) {
    if (0 == bytes.len) return;
    try extra(buffer, @intCast(bytes.len));
    _ = c.memcpy(buffer.data.? + @as(usize, @intCast(buffer.count)), bytes.ptr, bytes.len);
    buffer.count += @intCast(bytes.len);
}

pub fn janet_buffer_push_bytes(buffer: *types.JanetBuffer, bytes: []const u8) void {
    _ = raise.reported(pushBytes(buffer, bytes));
}

pub fn pushString(buffer: *types.JanetBuffer, string: [*]const u8) raise.Raising(void) {
    return pushBytes(buffer, string[0..@intCast(stringLength(string))]);
}

pub fn janet_buffer_push_string(buffer: *types.JanetBuffer, string: [*]const u8) void {
    raise.reported(pushString(buffer, string));
}

pub fn pushU8(buffer: *types.JanetBuffer, byte: u8) raise.Raising(void) {
    try extra(buffer, 1);
    buffer.data.?[@intCast(buffer.count)] = byte;
    buffer.count += 1;
}

pub fn janet_buffer_push_u8(buffer: *types.JanetBuffer, byte: u8) void {
    _ = raise.reported(pushU8(buffer, byte));
}

/// The three multi-byte pushes write little-endian regardless of host order,
/// which is what the C original does by shifting rather than by copying.
pub fn pushU16(buffer: *types.JanetBuffer, x: u16) raise.Raising(void) {
    try extra(buffer, 2);
    const at: usize = @intCast(buffer.count);
    buffer.data.?[at] = @truncate(x);
    buffer.data.?[at + 1] = @truncate(x >> 8);
    buffer.count += 2;
}

pub fn janet_buffer_push_u16(buffer: *types.JanetBuffer, x: u16) void {
    _ = raise.reported(pushU16(buffer, x));
}

pub fn pushU32(buffer: *types.JanetBuffer, x: u32) raise.Raising(void) {
    try extra(buffer, 4);
    const at: usize = @intCast(buffer.count);
    inline for (0..4) |i| {
        buffer.data.?[at + i] = @truncate(x >> (8 * i));
    }
    buffer.count += 4;
}

pub fn janet_buffer_push_u32(buffer: *types.JanetBuffer, x: u32) void {
    _ = raise.reported(pushU32(buffer, x));
}

pub fn pushU64(buffer: *types.JanetBuffer, x: u64) raise.Raising(void) {
    try extra(buffer, 8);
    const at: usize = @intCast(buffer.count);
    inline for (0..8) |i| {
        buffer.data.?[at + i] = @truncate(x >> (8 * i));
    }
    buffer.count += 8;
}

pub fn janet_buffer_push_u64(buffer: *types.JanetBuffer, x: u64) void {
    _ = raise.reported(pushU64(buffer, x));
}

// ==========================================================================
// The cfunction surface.
//
// Phase 10 Part 6. These raise, and a `JanetCFunction` has no error channel in
// its signature, so each delivers a raise as the jump its C caller expects and
// relies on this file's jump-transparent marker to make that safe. Nothing
// below holds anything across a call that can raise -- which for a growable
// container means in particular that no local caches `data` across an
// `ensure`, because a reallocation invalidates it whether or not anything
// jumps.
// ==========================================================================

// ---------------------------------------------------------------- buffer/*

/// `src/core/util.h`, declared here rather than in `cabi.zig`. Provided by
/// `pp_format.zig` or by `pp.c` according to `-Dpp`; either way it is a
/// C-ABI call across a selector seam, so a bad conversion inside it raises by
/// jumping through the two frames below.
extern fn janet_buffer_format(
    b: *types.JanetBuffer,
    strfrmt: [*]const u8,
    argstart: i32,
    argc: i32,
    argv: [*]types.Janet,
) callconv(.c) void;

/// `should_reverse_bytes`. The keyword names the byte order the caller wants,
/// and the answer is whether it differs from the host's -- so `:native` is
/// always false and the other two are decided at compile time.
///
/// `janet.h` picks `JANET_LITTLE_ENDIAN` or `JANET_BIG_ENDIAN` from the
/// target, and the check below reads the same macros rather than Zig's own
/// `@import("builtin")`, so a configuration that overrides them is honoured on
/// both sides of the selector.
const big_endian = (builtin.cpu.arch.endian() == .big);

fn shouldReverseBytes(argv: []types.Janet, n: i32) raise.Raising(bool) {
    const order = try args_core.getKeyword(argv, n);
    if (utils.cstrcmp(order, "le") == 0) return big_endian;
    if (utils.cstrcmp(order, "be") == 0) return !big_endian;
    if (utils.cstrcmp(order, "native") == 0) return false;
    // The C original reports argv[1] rather than argv[n]. Every caller passes
    // 1, so the two agree; reproduced rather than corrected.
    return pp_format.panicf("expected endianness :le, :be or :native, got %v", .{argv[1]});
}

/// Push `data`'s bytes, reversed if the caller asked for the other order.
/// `janet_getuinteger16` and friends have already rejected anything that does
/// not fit, so the only thing left is the byte order.
fn pushScalar(comptime T: type, buffer: *types.JanetBuffer, data: T, reverse: bool) raise.Raising(void) {
    var bytes: [@sizeOf(T)]u8 = @bitCast(data);
    if (reverse) std.mem.reverse(u8, &bytes);
    try pushBytes(buffer, &bytes);
}

fn cfunBufferNew(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    return wrap.fromBuffer(new(try args_core.getInteger(argv, 0)));
}

fn cfunBufferNewFilled(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.arity(argv, 1, 2);
    var count = try args_core.getInteger(argv, 0);
    if (count < 0) count = 0;
    const byte: u8 = if (@as(i32, @intCast(argv.len)) == 2) @truncate(@as(u32, @bitCast(try args_core.getInteger(argv, 1)))) else 0;
    const buffer = new(count);
    if (buffer.data != null and count > 0) @memset(buffer.data.?[0..@intCast(count)], byte);
    buffer.count = count;
    return wrap.fromBuffer(buffer);
}

fn cfunBufferFrombytes(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    const buffer = new(@as(i32, @intCast(argv.len)));
    var i: i32 = 0;
    while (i < @as(i32, @intCast(argv.len))) : (i += 1) {
        const byte = try args_core.getInteger(argv, i);
        buffer.data.?[@intCast(i)] = @truncate(@as(u32, @bitCast(byte)));
    }
    buffer.count = @as(i32, @intCast(argv.len));
    return wrap.fromBuffer(buffer);
}

fn cfunBufferFill(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.arity(argv, 1, 2);
    const buffer = try args_core.getBuffer(argv, 0);
    const byte: u8 = if (@as(i32, @intCast(argv.len)) == 2) @truncate(@as(u32, @bitCast(try args_core.getInteger(argv, 1)))) else 0;
    if (buffer.*.count != 0) @memset(buffer.*.data.?[0..@intCast(buffer.*.count)], byte);
    return argv[0];
}

/// The floor of four is the C original's and is not the same as `array/trim`'s
/// behaviour: an empty buffer keeps a four-byte allocation where an empty
/// array releases its payload entirely.
fn cfunBufferTrim(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    const buffer = try args_core.getBuffer(argv, 0);
    try canRealloc(buffer);
    if (buffer.*.count < buffer.*.capacity) {
        const newcap = if (buffer.*.count > 4) buffer.*.count else 4;
        const new_data = utils.realloc(@ptrCast(buffer.*.data), @intCast(newcap)) orelse
            fatal.outOfMemory();
        buffer.*.data = @ptrCast(new_data);
        buffer.*.capacity = newcap;
    }
    return argv[0];
}

fn cfunBufferU8(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.arity(argv, 1, -1);
    const buffer = try args_core.getBuffer(argv, 0);
    var i: i32 = 1;
    while (i < @as(i32, @intCast(argv.len))) : (i += 1) {
        try raise.crossing(janet_buffer_push_u8(buffer, @truncate(@as(u32, @bitCast(try args_core.getInteger(argv, i))))));
    }
    return argv[0];
}

fn cfunBufferWord(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.arity(argv, 1, -1);
    const buffer = try args_core.getBuffer(argv, 0);
    var i: i32 = 1;
    while (i < @as(i32, @intCast(argv.len))) : (i += 1) {
        const number = try args_core.getNumber(argv, i);
        const word: u32 = @intFromFloat(number);
        if (@as(f64, @floatFromInt(word)) != number) {
            return pp_format.panicf("cannot convert %v to machine word", .{argv[@intCast(i)]});
        }
        try raise.crossing(janet_buffer_push_u32(buffer, word));
    }
    return argv[0];
}

/// Pushing a buffer onto itself grows it, and the growth may move the payload,
/// so the space is reserved first and the view retaken. The C original writes
/// this out at both of its call sites and so does this.
fn pushBytesAliasSafe(buffer: *types.JanetBuffer, view_in: types.JanetByteView) raise.Raising(void) {
    var view = view_in;
    if (view.bytes == buffer.data) {
        try ensure(buffer, buffer.count + view.len, 2);
        view.bytes = buffer.data.?;
    }
    try pushBytes(buffer, args_core.viewBytes(view));
}

fn cfunBufferChars(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.arity(argv, 1, -1);
    const buffer = try args_core.getBuffer(argv, 0);
    var i: i32 = 1;
    while (i < @as(i32, @intCast(argv.len))) : (i += 1) try pushBytesAliasSafe(buffer, try args_core.getBytes(argv, i));
    return argv[0];
}

fn cfunBufferPushUint16(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 3);
    const buffer = try args_core.getBuffer(argv, 0);
    const reverse = try shouldReverseBytes(argv, 1);
    try pushScalar(u16, buffer, try args_core.getUInteger16(argv, 2), reverse);
    return argv[0];
}

fn cfunBufferPushUint32(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 3);
    const buffer = try args_core.getBuffer(argv, 0);
    const reverse = try shouldReverseBytes(argv, 1);
    try pushScalar(u32, buffer, try args_core.getUInteger(argv, 2), reverse);
    return argv[0];
}

fn cfunBufferPushUint64(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 3);
    const buffer = try args_core.getBuffer(argv, 0);
    const reverse = try shouldReverseBytes(argv, 1);
    try pushScalar(u64, buffer, try args_core.getUInteger64(argv, 2), reverse);
    return argv[0];
}

fn cfunBufferPushFloat32(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 3);
    const buffer = try args_core.getBuffer(argv, 0);
    const reverse = try shouldReverseBytes(argv, 1);
    try pushScalar(f32, buffer, @floatCast(try args_core.getNumber(argv, 2)), reverse);
    return argv[0];
}

fn cfunBufferPushFloat64(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 3);
    const buffer = try args_core.getBuffer(argv, 0);
    const reverse = try shouldReverseBytes(argv, 1);
    try pushScalar(f64, buffer, try args_core.getNumber(argv, 2), reverse);
    return argv[0];
}

/// A number is a byte and anything else is a byte sequence, which is what
/// makes `buffer/push` the union of `buffer/push-byte` and
/// `buffer/push-string`.
fn pushImpl(buffer: *types.JanetBuffer, argv: []types.Janet, start: i32, argc: i32) raise.Raising(void) {
    var i: i32 = start;
    while (i < argc) : (i += 1) {
        if (kind.checkType(argv[@intCast(i)], constants.JANET_NUMBER) != 0) {
            try raise.crossing(janet_buffer_push_u8(buffer, @truncate(@as(u32, @bitCast(try args_core.getInteger(argv, i))))));
        } else {
            try pushBytesAliasSafe(buffer, try args_core.getBytes(argv, i));
        }
    }
}

/// Writing before the end shortens the buffer for the duration of the write
/// and then restores the length, so a short write leaves the tail intact and a
/// long one extends it. That is the whole difference from `buffer/push`.
fn cfunBufferPushAt(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.arity(argv, 2, -1);
    const buffer = try args_core.getBuffer(argv, 0);
    const index = try args_core.getInteger(argv, 1);
    const old_count = buffer.*.count;
    if (index < 0 or index > old_count) return pp_format.panicf("index out of range [0, %d)", .{old_count});
    buffer.*.count = index;
    try pushImpl(buffer, argv, 2, @as(i32, @intCast(argv.len)));
    if (buffer.*.count < old_count) buffer.*.count = old_count;
    return argv[0];
}

fn cfunBufferPush(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.arity(argv, 1, -1);
    try pushImpl(try args_core.getBuffer(argv, 0), argv, 1, @as(i32, @intCast(argv.len)));
    return argv[0];
}

fn cfunBufferClear(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 1);
    (try args_core.getBuffer(argv, 0)).*.count = 0;
    return argv[0];
}

fn cfunBufferPopn(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 2);
    const buffer = try args_core.getBuffer(argv, 0);
    const n = try args_core.getInteger(argv, 1);
    if (n < 0) return raise.panic("n must be non-negative");
    buffer.*.count = if (buffer.*.count < n) 0 else buffer.*.count - n;
    return argv[0];
}

fn cfunBufferSlice(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    const view = try args_core.getBytes(argv, 0);
    const range = try args_core.getSlice(argv);
    const len = range.end - range.start;
    const buffer = new(len);
    if (buffer.data != null) {
        safe_memcpy(
            @ptrCast(buffer.data),
            @ptrCast(view.bytes.? + @as(usize, @intCast(range.start))),
            @intCast(len),
        );
    }
    buffer.count = len;
    return wrap.fromBuffer(buffer);
}

const BitLoc = struct { buffer: *types.JanetBuffer, index: i32, bit: u3 };

/// `bitloc`. The index is a bit index rather than a byte index, and the test
/// `bitindex != x` is what rejects a fractional one -- a check the argument
/// layer cannot make, because the value is legitimately wider than the byte
/// index it becomes.
fn bitloc(argv: []types.Janet) raise.Raising(BitLoc) {
    try args_core.fixarity(argv, 2);
    const buffer = try args_core.getBuffer(argv, 0);
    const x = try args_core.getNumber(argv, 1);
    const bitindex: i64 = @intFromFloat(x);
    const byteindex = bitindex >> 3;
    if (@as(f64, @floatFromInt(bitindex)) != x or bitindex < 0 or byteindex >= buffer.*.count) {
        return pp_format.panicf("invalid bit index %v", .{argv[1]});
    }
    return .{ .buffer = buffer, .index = @intCast(byteindex), .bit = @intCast(bitindex & 7) };
}

fn cfunBufferBitset(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    const loc = try bitloc(argv);
    loc.buffer.data.?[@intCast(loc.index)] |= @as(u8, 1) << loc.bit;
    return argv[0];
}

fn cfunBufferBitclear(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    const loc = try bitloc(argv);
    loc.buffer.data.?[@intCast(loc.index)] &= ~(@as(u8, 1) << loc.bit);
    return argv[0];
}

fn cfunBufferBitget(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    const loc = try bitloc(argv);
    const set = loc.buffer.data.?[@intCast(loc.index)] & (@as(u8, 1) << loc.bit);
    return wrap.fromBoolean(@intCast(set));
}

fn cfunBufferBittoggle(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    const loc = try bitloc(argv);
    loc.buffer.data.?[@intCast(loc.index)] ^= @as(u8, 1) << loc.bit;
    return argv[0];
}

fn cfunBufferBlit(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.arity(argv, 2, 5);
    const dest = try args_core.getBuffer(argv, 0);
    var src = try args_core.getBytes(argv, 1);
    const same_buf = src.bytes == dest.*.data;
    var offset_dest: i32 = 0;
    var offset_src: i32 = 0;
    if (@as(i32, @intCast(argv.len)) > 2 and kind.checkType(argv[2], constants.JANET_NIL) == 0) {
        offset_dest = try args_core.getHalfRange(argv, 2, dest.*.count, "dest-start");
    }
    if (@as(i32, @intCast(argv.len)) > 3 and kind.checkType(argv[3], constants.JANET_NIL) == 0) {
        offset_src = try args_core.getHalfRange(argv, 3, src.len, "src-start");
    }
    var length_src: i32 = undefined;
    if (@as(i32, @intCast(argv.len)) > 4) {
        var src_end = src.len;
        if (kind.checkType(argv[4], constants.JANET_NIL) == 0) {
            src_end = try args_core.getHalfRange(argv, 4, src.len, "src-end");
        }
        length_src = src_end - offset_src;
        if (length_src < 0) length_src = 0;
    } else {
        length_src = src.len - offset_src;
    }
    const last: i64 = @as(i64, offset_dest) + length_src;
    if (last > std.math.maxInt(i32)) return raise.panic("buffer blit out of range");
    const last32: i32 = @intCast(last);
    try ensure(dest, last32, 2);
    if (last32 > dest.*.count) dest.*.count = last32;
    if (length_src != 0) {
        const n: usize = @intCast(length_src);
        // janet_buffer_ensure may have invalidated src.
        if (same_buf) src.bytes = dest.*.data.?;
        const to = dest.*.data.? + @as(usize, @intCast(offset_dest));
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

fn cfunBufferFormat(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.arity(argv, 2, -1);
    const buffer = try args_core.getBuffer(argv, 0);
    const strfrmt = try args_core.getString(argv, 1);
    try pp_format.bufferFormat(buffer, @ptrCast(strfrmt), 1, argv);
    return argv[0];
}

fn cfunBufferFormatAt(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
    try args_core.arity(argv, 2, -1);
    const buffer = try args_core.getBuffer(argv, 0);
    var at = try args_core.getInteger(argv, 1);
    if (at < 0) at += buffer.*.count + 1;
    if (at > buffer.*.count or at < 0) {
        return pp_format.panicf("expected index at to be in range [0, %d), got %d", .{ buffer.*.count, at });
    }
    const oldcount = buffer.*.count;
    buffer.*.count = at;
    const strfrmt = try args_core.getString(argv, 2);
    try pp_format.bufferFormat(buffer, @ptrCast(strfrmt), 2, argv);
    if (buffer.*.count < oldcount) buffer.*.count = oldcount;
    return argv[0];
}

pub fn lib(env: *types.JanetTable) void {
    const push_tail = "Returns the modified buffer." ++
        "Expands the buffer as necessary. Throws an error if size limit is exceeded.";
    const entries = [_]corefn.Entry{
        corefn.reg("buffer/new", &cfunBufferNew, @src(), "(buffer/new capacity)", "Creates a new, empty buffer with enough backing memory for `capacity` bytes. " ++
            "Returns a new buffer of length 0."),
        corefn.reg("buffer/new-filled", &cfunBufferNewFilled, @src(), "(buffer/new-filled count &opt byte)", "Creates a new buffer of length `count` filled with `byte`. By default, `byte` is 0. " ++
            "Returns the new buffer."),
        corefn.reg("buffer/from-bytes", &cfunBufferFrombytes, @src(), "(buffer/from-bytes & byte-vals)", "Creates a buffer from integer parameters with byte values. All integers " ++
            "will be coerced to the range of 1 byte 0-255."),
        corefn.reg("buffer/fill", &cfunBufferFill, @src(), "(buffer/fill buffer &opt byte)", "Fill up a buffer with bytes, defaulting to 0s. Does not change the buffer's length. " ++
            "Returns the modified buffer."),
        corefn.reg("buffer/trim", &cfunBufferTrim, @src(), "(buffer/trim buffer)", "Set the backing capacity of the buffer to the current length of the buffer. Returns the " ++
            "modified buffer."),
        corefn.reg("buffer/push-byte", &cfunBufferU8, @src(), "(buffer/push-byte buffer & xs)", "Append bytes to a buffer. Returns the modified buffer. " ++
            "Expands the buffer as necessary. Throws an error if size limit is exceeded."),
        corefn.reg("buffer/push-word", &cfunBufferWord, @src(), "(buffer/push-word buffer & xs)", "Append machine words to a buffer. The 4 bytes of the integer are appended " ++
            "in twos complement, little endian order, unsigned for all x. Returns the modified buffer. " ++
            "Expands the buffer as necessary. Throws an error if size limit is exceeded."),
        corefn.reg("buffer/push-string", &cfunBufferChars, @src(), "(buffer/push-string buffer & xs)", "Push byte sequences onto the end of a buffer. " ++
            "Will accept any of strings, keywords, symbols, and buffers. " ++
            "Returns the modified buffer. " ++
            "Expands the buffer as necessary. Throws an error if size limit is exceeded."),
        corefn.reg("buffer/push-uint16", &cfunBufferPushUint16, @src(), "(buffer/push-uint16 buffer order data)", "Push a 16 bit unsigned integer data onto the end of the buffer. " ++ push_tail),
        corefn.reg("buffer/push-uint32", &cfunBufferPushUint32, @src(), "(buffer/push-uint32 buffer order data)", "Push a 32 bit unsigned integer data onto the end of the buffer. " ++ push_tail),
        corefn.reg("buffer/push-uint64", &cfunBufferPushUint64, @src(), "(buffer/push-uint64 buffer order data)", "Push a 64 bit unsigned integer data onto the end of the buffer. " ++ push_tail),
        corefn.reg("buffer/push-float32", &cfunBufferPushFloat32, @src(), "(buffer/push-float32 buffer order data)", "Push the underlying bytes of a 32 bit float data onto the end of the buffer. " ++ push_tail),
        corefn.reg("buffer/push-float64", &cfunBufferPushFloat64, @src(), "(buffer/push-float64 buffer order data)", "Push the underlying bytes of a 64 bit float data onto the end of the buffer. " ++ push_tail),
        corefn.reg("buffer/push", &cfunBufferPush, @src(), "(buffer/push buffer & xs)", "Push both individual bytes and byte sequences to a buffer. For each x in xs, " ++
            "push the byte if x is an integer, otherwise push the bytesequence to the buffer. " ++
            "Thus, this function behaves like both `buffer/push-string` and `buffer/push-byte`. " ++
            "Returns the modified buffer. " ++
            "Expands the buffer as necessary. Throws an error if size limit is exceeded."),
        corefn.reg("buffer/push-at", &cfunBufferPushAt, @src(), "(buffer/push-at buffer index & xs)", "Same as buffer/push, but copies the new data into the buffer " ++
            " at index `index`."),
        corefn.reg("buffer/popn", &cfunBufferPopn, @src(), "(buffer/popn buffer n)", "Removes the last `n` bytes from the buffer. Returns the modified buffer."),
        corefn.reg("buffer/clear", &cfunBufferClear, @src(), "(buffer/clear buffer)", "Sets the size of a buffer to 0 and empties it. The buffer retains " ++
            "its memory so it can be efficiently refilled. Returns the modified buffer."),
        corefn.reg("buffer/slice", &cfunBufferSlice, @src(), "(buffer/slice bytes &opt start end)", "Takes a slice of a byte sequence from `start` to `end`. The range is half open, " ++
            "[start, end). Indexes can also be negative, indicating indexing from the end of the " ++
            "end of the array. By default, `start` is 0 and `end` is the length of the buffer. " ++
            "Returns a new buffer."),
        corefn.reg("buffer/bit-set", &cfunBufferBitset, @src(), "(buffer/bit-set buffer index)", "Sets the bit at the given bit-index. Returns the buffer."),
        corefn.reg("buffer/bit-clear", &cfunBufferBitclear, @src(), "(buffer/bit-clear buffer index)", "Clears the bit at the given bit-index. Returns the buffer."),
        corefn.reg("buffer/bit", &cfunBufferBitget, @src(), "(buffer/bit buffer index)", "Gets the bit at the given bit-index. Returns true if the bit is set, false if not."),
        corefn.reg("buffer/bit-toggle", &cfunBufferBittoggle, @src(), "(buffer/bit-toggle buffer index)", "Toggles the bit at the given bit index in buffer. Returns the buffer."),
        corefn.reg("buffer/blit", &cfunBufferBlit, @src(), "(buffer/blit dest src &opt dest-start src-start src-end)", "Insert the contents of `src` into `dest`. Can optionally take indices that " ++
            "indicate which part of `src` to copy into which part of `dest`. Indices can be " ++
            "negative in order to index from the end of `src` or `dest`. Returns `dest`."),
        corefn.reg("buffer/format", &cfunBufferFormat, @src(), "(buffer/format buffer format & args)", "Snprintf like functionality for printing values into a buffer. Returns " ++
            "the modified buffer."),
        corefn.reg("buffer/format-at", &cfunBufferFormatAt, @src(), "(buffer/format-at buffer at format & args)", "Snprintf like functionality for printing values into a buffer. Returns " ++
            "the modified buffer."),
        corefn.end,
    };
    corefn.install(env, &entries);
}
