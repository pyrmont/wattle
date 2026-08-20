//! The two growable containers: `JanetBuffer` and `JanetArray`. This is the
//! first of the three increments Phase 8 Part 6 is split into, and it takes
//! the data-structure core of `src/core/buffer.c` and `src/core/array.c` — the
//! constructors, the capacity policy, and the push/pop primitives. The
//! `JANET_CORE_FN` bodies in both files stayed in C, as they did for every
//! subsystem Phase 8 ported, on the rule that they are standard-library
//! surface rather than value construction. Phase 10 Part 6 brought them here;
//! they are at the foot of the file and they still reach the code below
//! through the same public API an embedder uses.
//!
//! Buffer and array are here together because they are one data structure with
//! two element types. Both are a `JanetGCObject` header followed by
//! `count`/`capacity`/`data`, both keep `data` in a separate `janet_malloc`
//! block that is reallocated in place as the container grows, and both leave
//! the freeing of that block to `janet_deinit_block`, which Part 5 already
//! moved to Zig. So this file allocates payloads that `gc_sweep.zig` releases,
//! and neither file needs to know anything about the other beyond the layout
//! they share with C.
//!
//! Neither type is traversed here. `gc_mark.zig` walks an array's elements and
//! skips a buffer's bytes; nothing below marks, and nothing below frees a
//! collectable block.
//!
//! **The file is jump-transparent**, under the rule SPIKE-8 settled, and it is
//! the first subsystem where the reason is ordinary rather than exotic. Four
//! functions here call `janet_panic` directly — `janet_buffer_can_realloc`,
//! `janet_pointer_buffer_unsafe` and `janet_buffer_extra` — and `janet_gcalloc`
//! can trigger a collection, which runs finalizers, which SPIKE-8 permits to
//! raise. A signal from any of them unwinds straight through these frames, so
//! there is no `defer` in this file and `build.zig` checks that there is not.
//!
//! Every frame here is safe to leave that way, and it is worth saying why
//! rather than assuming it. The panics all happen *before* the allocation they
//! guard: `janet_buffer_can_realloc` is called before the `janet_realloc` it
//! protects, and `janet_buffer_extra`'s overflow check is the first statement
//! in the function. So no path below holds a raw block between acquiring it and
//! storing it in a structure the collector can see — the one shape that a
//! skipped cleanup would turn into a leak.
//!
//! ## Arithmetic reproduced rather than repaired
//!
//! The capacity policy in both files multiplies a caller-supplied count by a
//! caller-supplied growth factor and trusts the product to be positive. C's
//! conversion of the negative result to `size_t` is defined and wraps; Zig's
//! would trap, so the conversions are written out through `asSize` below and
//! the arithmetic uses wrapping operators wherever the C original can wrap.
//!
//! This is not hypothetical. `array/ensure` passes its third argument to
//! `janet_array_ensure` unchecked, so a growth of zero frees an array's backing
//! store while leaving `count` untouched — a use-after-free reachable from pure
//! Janet — and a negative growth requests almost the whole address space and
//! ends the process through `JANET_OUT_OF_MEMORY`, which `protect` cannot catch.
//! `FOUND.md` records both symptoms and the measurement; they are left unfixed
//! under the usual rule and reproduced exactly here, so that the two selectors
//! misbehave identically. `test/buffer_array.c` pins them.
//!
//! Two smaller asymmetries between the C originals are preserved for the same
//! reason, and neither is a defect:
//!
//!  - `janet_buffer_ensure` charges GC pressure before the `janet_realloc` and
//!    `janet_array_ensure` charges it after, so a failed array growth is not
//!    accounted for and a failed buffer growth is. Both exit the process on
//!    failure, so nothing observes the difference.
//!  - `janet_array_impl` adds to `janet_vm.next_collection` directly where
//!    `janet_buffer_init_impl` calls `janet_gcpressure`. The two are the same
//!    operation; the direct form is mirrored directly so that the byte counts
//!    charged by the two selectors match term for term.
//!
//! `janet_array_n` charges no pressure at all, which is a third asymmetry and
//! also preserved.

const std = @import("std");
const abi = @import("abi");
const corefn = @import("corefn");
const c = abi.c;
const raise = @import("raise");
const arglayer = @import("arglayer.zig");
const pp_format = @import("pp_format.zig");

/// `janet_vm` as `src/core/state.h` declares it, resolved through `abi.zig`.
inline fn vm() *c.JanetVM {
    return &c.janet_vm;
}

/// `safe_memcpy` from `src/core/util.c`. Declared here rather than imported:
/// `util.h` is deliberately outside `abi.zig` — see the note at the head of
/// that file — and this function's parameters are primitive, so no Janet type
/// crosses and the single-translation rule is not at stake.
extern fn safe_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void;

const buffer_flag_no_realloc: i32 = c.JANET_BUFFER_FLAG_NO_REALLOC;
const mem_disabled: i32 = c.JANET_MEM_DISABLED;

/// C's conversion of a signed count to `size_t`: sign-extend to the pointer
/// width, then reinterpret. For a negative count that yields a very large
/// size, which is exactly what the C code does and what `FOUND.md` records for
/// `array/ensure`. Written out because Zig has no implicit signed-to-unsigned
/// conversion and `@intCast` would trap on the values this reaches.
inline fn asSize(n: i32) usize {
    return @bitCast(@as(isize, n));
}

/// Recover a string's head from its data pointer. Same shape as `gc_sweep.zig`
/// uses: `@sizeOf` rather than `@offsetOf`, because translate-c drops the
/// flexible array member and the two are equal for this layout. `test/gc_sweep.c`
/// already pins that equality from C.
inline fn stringHead(s: [*c]const u8) *c.JanetStringHead {
    return @ptrFromInt(@intFromPtr(s) -% @sizeOf(c.JanetStringHead));
}

inline fn stringLength(s: [*c]const u8) i32 {
    return stringHead(s).length;
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
/// Phase 10 Part 6 brought that caller here too, so the declaration is now for
/// `buffer.c`'s benefit under `-Dbuffer-array=c` and nothing else.
/// Duplicating it instead would put the same policy in two places and let them
/// drift; one definition and three words of declaration is cheaper.
pub fn canRealloc(buffer: *c.JanetBuffer) raise.Raising(void) {
    if ((buffer.gc.flags & buffer_flag_no_realloc) != 0) {
        return raise.panic("buffer cannot reallocate foreign memory");
    }
}

export fn janet_buffer_can_realloc(buffer: *c.JanetBuffer) callconv(.c) void {
    raise.reported(canRealloc(buffer));
}

/// Give a buffer its initial payload. Shared by the collectable and the
/// caller-owned constructors, and it touches no field of `gc` — which is why
/// `janet_buffer_init` can set those afterwards.
fn bufferInitImpl(buffer: *c.JanetBuffer, capacity_in: i32) *c.JanetBuffer {
    var capacity = capacity_in;
    if (capacity < 4) capacity = 4;
    c.janet_gcpressure(asSize(capacity));
    const data = c.janet_malloc(asSize(capacity)) orelse c.janet_zig_out_of_memory();
    buffer.count = 0;
    buffer.capacity = capacity;
    buffer.data = @ptrCast(data);
    return buffer;
}

/// Initialise a buffer the caller owns. The block is not on a heap list, so it
/// is marked `JANET_MEM_DISABLED` and the collector leaves it alone.
export fn janet_buffer_init(buffer: *c.JanetBuffer, capacity: i32) callconv(.c) *c.JanetBuffer {
    _ = bufferInitImpl(buffer, capacity);
    buffer.gc.data.next = null;
    buffer.gc.flags = mem_disabled;
    return buffer;
}

/// Wrap memory the runtime did not allocate. The result is collectable but its
/// payload is not: `JANET_BUFFER_FLAG_NO_REALLOC` makes both `janet_buffer_deinit`
/// and every growth path leave the foreign pointer alone.
pub fn pointerBufferUnsafe(memory: ?*anyopaque, capacity: i32, count: i32) raise.Raising(*c.JanetBuffer) {
    if (count < 0) return raise.panic("count < 0");
    if (capacity < count) return raise.panic("capacity < count");
    const buffer: *c.JanetBuffer = @ptrCast(@alignCast(c.janet_gcalloc(c.JANET_MEMORY_BUFFER, @sizeOf(c.JanetBuffer))));
    buffer.gc.flags |= buffer_flag_no_realloc;
    buffer.capacity = capacity;
    buffer.count = count;
    buffer.data = @ptrCast(memory);
    return buffer;
}

/// Release a buffer's payload. Also called from `janet_deinit_block` in
/// `gc_sweep.zig`, which is the collectable buffer's only route here.
export fn janet_buffer_deinit(buffer: *c.JanetBuffer) callconv(.c) void {
    if ((buffer.gc.flags & buffer_flag_no_realloc) == 0) {
        c.janet_free(buffer.data);
        buffer.data = null;
    }
}

/// Allocate a collectable buffer.
export fn janet_buffer(capacity: i32) callconv(.c) *c.JanetBuffer {
    const buffer: *c.JanetBuffer = @ptrCast(@alignCast(c.janet_gcalloc(c.JANET_MEMORY_BUFFER, @sizeOf(c.JanetBuffer))));
    return bufferInitImpl(buffer, capacity);
}

/// Grow a buffer to at least `capacity`, overshooting by `growth`.
///
/// The product is computed in 64 bits and clamped at the top only; a growth of
/// zero or less passes through as a zero or negative capacity, and the
/// conversions below reproduce what C then does with it. No caller inside the
/// tree reaches that — every one passes 1 or 2 — but the C API is public.
pub fn bufferEnsure(buffer: *c.JanetBuffer, capacity_in: i32, growth: i32) raise.Raising(void) {
    var capacity = capacity_in;
    const old = buffer.data;
    if (capacity <= buffer.capacity) return;
    try canRealloc(buffer);
    // Cannot overflow: both factors fit in 32 bits, so the product fits in 62.
    const big_capacity: i64 = @as(i64, capacity) * @as(i64, growth);
    capacity = if (big_capacity > std.math.maxInt(i32)) std.math.maxInt(i32) else @truncate(big_capacity);
    c.janet_gcpressure(asSize(capacity -% buffer.capacity));
    const new_data = c.janet_realloc(old, asSize(capacity)) orelse c.janet_zig_out_of_memory();
    buffer.data = @ptrCast(new_data);
    buffer.capacity = capacity;
}

export fn janet_buffer_ensure(buffer: *c.JanetBuffer, capacity_in: i32, growth: i32) callconv(.c) void {
    raise.reported(bufferEnsure(buffer, capacity_in, growth));
}

/// Set a buffer's length, zero-filling any bytes the count newly covers.
pub fn bufferSetcount(buffer: *c.JanetBuffer, count: i32) raise.Raising(void) {
    if (count < 0) return;
    if (count > buffer.count) {
        const oldcount = buffer.count;
        try bufferEnsure(buffer, count, 1);
        _ = c.memset(buffer.data + @as(usize, @intCast(oldcount)), 0, @intCast(count - oldcount));
    }
    buffer.count = count;
}

export fn janet_buffer_setcount(buffer: *c.JanetBuffer, count: i32) callconv(.c) void {
    raise.reported(bufferSetcount(buffer, count));
}

export fn janet_buffer_extra(buffer: *c.JanetBuffer, n: i32) callconv(.c) void {
    raise.reported(bufferExtra(buffer, n));
}

export fn janet_array_push(array: *c.JanetArray, x: c.Janet) callconv(.c) void {
    raise.reported(arrayPush(array, x));
}

export fn janet_pointer_buffer_unsafe(memory: ?*anyopaque, capacity: i32, count: i32) callconv(.c) *c.JanetBuffer {
    return raise.reported(pointerBufferUnsafe(memory, capacity, count));
}

/// Reserve room for `n` more bytes, so that the next `n` pushes cannot
/// reallocate. The overflow check is the first statement, before any
/// allocation, which is what makes the panic safe to raise through this frame.
pub fn bufferExtra(buffer: *c.JanetBuffer, n: i32) raise.Raising(void) {
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
        const new_data = c.janet_realloc(buffer.data, asSize(new_capacity));
        // The C original charges the pressure between the allocation and the
        // null test, so a failed growth is accounted for on the way out. Kept.
        c.janet_gcpressure(asSize(new_capacity -% buffer.capacity));
        if (new_data == null) c.janet_zig_out_of_memory();
        buffer.data = @ptrCast(new_data);
        buffer.capacity = new_capacity;
    }
}

pub fn bufferPushCString(buffer: *c.JanetBuffer, cstring: [*c]const u8) raise.Raising(void) {
    const len: i32 = @intCast(c.strlen(cstring));
    return bufferPushBytes(buffer, cstring, len);
}

export fn janet_buffer_push_cstring(buffer: *c.JanetBuffer, cstring: [*c]const u8) callconv(.c) void {
    raise.reported(bufferPushCString(buffer, cstring));
}

pub fn bufferPushBytes(buffer: *c.JanetBuffer, string: [*c]const u8, length: i32) raise.Raising(void) {
    if (0 == length) return;
    try bufferExtra(buffer, length);
    _ = c.memcpy(buffer.data + @as(usize, @intCast(buffer.count)), string, @intCast(length));
    buffer.count += length;
}

export fn janet_buffer_push_bytes(buffer: *c.JanetBuffer, string: [*c]const u8, length: i32) callconv(.c) void {
    _ = raise.reported(bufferPushBytes(buffer, string, length));
}

pub fn bufferPushString(buffer: *c.JanetBuffer, string: [*c]const u8) raise.Raising(void) {
    return bufferPushBytes(buffer, string, stringLength(string));
}

export fn janet_buffer_push_string(buffer: *c.JanetBuffer, string: [*c]const u8) callconv(.c) void {
    raise.reported(bufferPushString(buffer, string));
}

pub fn bufferPushU8(buffer: *c.JanetBuffer, byte: u8) raise.Raising(void) {
    try bufferExtra(buffer, 1);
    buffer.data[@intCast(buffer.count)] = byte;
    buffer.count += 1;
}

export fn janet_buffer_push_u8(buffer: *c.JanetBuffer, byte: u8) callconv(.c) void {
    _ = raise.reported(bufferPushU8(buffer, byte));
}

/// The three multi-byte pushes write little-endian regardless of host order,
/// which is what the C original does by shifting rather than by copying.
pub fn bufferPushU16(buffer: *c.JanetBuffer, x: u16) raise.Raising(void) {
    try bufferExtra(buffer, 2);
    const at: usize = @intCast(buffer.count);
    buffer.data[at] = @truncate(x);
    buffer.data[at + 1] = @truncate(x >> 8);
    buffer.count += 2;
}

export fn janet_buffer_push_u16(buffer: *c.JanetBuffer, x: u16) callconv(.c) void {
    _ = raise.reported(bufferPushU16(buffer, x));
}

pub fn bufferPushU32(buffer: *c.JanetBuffer, x: u32) raise.Raising(void) {
    try bufferExtra(buffer, 4);
    const at: usize = @intCast(buffer.count);
    inline for (0..4) |i| {
        buffer.data[at + i] = @truncate(x >> (8 * i));
    }
    buffer.count += 4;
}

export fn janet_buffer_push_u32(buffer: *c.JanetBuffer, x: u32) callconv(.c) void {
    _ = raise.reported(bufferPushU32(buffer, x));
}

pub fn bufferPushU64(buffer: *c.JanetBuffer, x: u64) raise.Raising(void) {
    try bufferExtra(buffer, 8);
    const at: usize = @intCast(buffer.count);
    inline for (0..8) |i| {
        buffer.data[at + i] = @truncate(x >> (8 * i));
    }
    buffer.count += 8;
}

export fn janet_buffer_push_u64(buffer: *c.JanetBuffer, x: u64) callconv(.c) void {
    _ = raise.reported(bufferPushU64(buffer, x));
}

// ------------------------------------------------------------------- array

/// Give an array its initial payload. A capacity of zero leaves `data` null,
/// and the growth paths handle that: `janet_realloc(NULL, n)` allocates.
fn arrayImpl(array: *c.JanetArray, capacity: i32) void {
    var data: [*c]c.Janet = null;
    if (capacity > 0) {
        // Written as the C original writes it, rather than through
        // `janet_gcpressure`, so the two selectors charge the same term.
        vm().next_collection +%= asSize(capacity) *% @sizeOf(c.Janet);
        data = @ptrCast(@alignCast(c.janet_malloc(@sizeOf(c.Janet) *% asSize(capacity)) orelse
            c.janet_zig_out_of_memory()));
    }
    array.count = 0;
    array.capacity = capacity;
    array.data = data;
}

export fn janet_array(capacity: i32) callconv(.c) *c.JanetArray {
    const array: *c.JanetArray = @ptrCast(@alignCast(c.janet_gcalloc(c.JANET_MEMORY_ARRAY, @sizeOf(c.JanetArray))));
    arrayImpl(array, capacity);
    return array;
}

/// An array whose elements do not keep their targets alive. The only
/// difference is the memory type, which puts the block on the weak heap and
/// sends it to `dropDeadElements` in `gc_sweep.zig` instead of to the marker.
export fn janet_array_weak(capacity: i32) callconv(.c) *c.JanetArray {
    const array: *c.JanetArray = @ptrCast(@alignCast(c.janet_gcalloc(c.JANET_MEMORY_ARRAY_WEAK, @sizeOf(c.JanetArray))));
    arrayImpl(array, capacity);
    return array;
}

/// Build an array from `n` elements. Note that this does not go through
/// `arrayImpl` and charges no GC pressure for the payload it allocates; the
/// asymmetry is the C original's and is preserved.
export fn janet_array_n(elements: [*c]const c.Janet, n: i32) callconv(.c) *c.JanetArray {
    const array: *c.JanetArray = @ptrCast(@alignCast(c.janet_gcalloc(c.JANET_MEMORY_ARRAY, @sizeOf(c.JanetArray))));
    array.capacity = n;
    array.count = n;
    array.data = @ptrCast(@alignCast(c.janet_malloc(@sizeOf(c.Janet) *% asSize(n))));
    if (array.data == null) c.janet_zig_out_of_memory();
    safe_memcpy(@ptrCast(array.data), @ptrCast(elements), @sizeOf(c.Janet) *% asSize(n));
    return array;
}

/// Grow an array to at least `capacity`, overshooting by `growth`.
///
/// This is the function `FOUND.md` records against: `array/ensure` hands a
/// script's growth factor straight through, and a factor of zero or less
/// produces a zero or negative capacity that this passes to `janet_realloc`
/// while leaving `count` alone. Reproduced exactly, wrapping operators and all.
export fn janet_array_ensure(array: *c.JanetArray, capacity_in: i32, growth: i32) callconv(.c) void {
    var capacity = capacity_in;
    const old = array.data;
    if (capacity <= array.capacity) return;
    // Cannot overflow: both factors fit in 32 bits, so the product fits in 62.
    var new_capacity: i64 = @as(i64, capacity) * @as(i64, growth);
    if (new_capacity > std.math.maxInt(i32)) new_capacity = std.math.maxInt(i32);
    capacity = @truncate(new_capacity);
    const new_data = c.janet_realloc(@ptrCast(old), asSize(capacity) *% @sizeOf(c.Janet)) orelse
        c.janet_zig_out_of_memory();
    // Charged after the allocation, where the buffer twin charges it before.
    vm().next_collection +%= asSize(capacity -% array.capacity) *% @sizeOf(c.Janet);
    array.data = @ptrCast(@alignCast(new_data));
    array.capacity = capacity;
}

/// Set an array's length, filling any newly covered slots with nil.
export fn janet_array_setcount(array: *c.JanetArray, count: i32) callconv(.c) void {
    if (count < 0) return;
    if (count > array.count) {
        janet_array_ensure(array, count, 1);
        var i = array.count;
        while (i < count) : (i += 1) {
            array.data[@intCast(i)] = c.janet_wrap_nil();
        }
    }
    array.count = count;
}

pub fn arrayPush(array: *c.JanetArray, x: c.Janet) raise.Raising(void) {
    if (array.count == std.math.maxInt(i32)) {
        return raise.panic("array overflow");
    }
    const newcount = array.count + 1;
    janet_array_ensure(array, newcount, 2);
    array.data[@intCast(array.count)] = x;
    array.count = newcount;
}

export fn janet_array_pop(array: *c.JanetArray) callconv(.c) c.Janet {
    if (array.count != 0) {
        array.count -= 1;
        return array.data[@intCast(array.count)];
    }
    return c.janet_wrap_nil();
}

export fn janet_array_peek(array: *c.JanetArray) callconv(.c) c.Janet {
    if (array.count != 0) {
        return array.data[@intCast(array.count - 1)];
    }
    return c.janet_wrap_nil();
}

// ==========================================================================
// array/* and buffer/*, the cfunction surfaces.
//
// Phase 10 Part 6. These raise, and a `JanetCFunction` has no error channel in
// its signature, so each delivers a raise as the jump its C caller expects and
// relies on this file's jump-transparent marker to make that safe. Nothing
// below holds anything across a call that can raise -- which for the growable
// containers means in particular that no local caches `array->data` across a
// `janet_array_ensure`, because a reallocation invalidates it whether or not
// anything jumps.
// ==========================================================================

fn cfunArrayNew(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    return c.janet_wrap_array(janet_array(try arglayer.getInteger(argv, 0)));
}

fn cfunArrayWeak(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    return c.janet_wrap_array(janet_array_weak(try arglayer.getInteger(argv, 0)));
}

fn cfunArrayNewFilled(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 2);
    const count = try arglayer.getNat(argv, 0);
    const x = if (argc == 2) argv[1] else c.janet_wrap_nil();
    const array = janet_array(count);
    var i: i32 = 0;
    while (i < count) : (i += 1) array.*.data[@intCast(i)] = x;
    array.*.count = count;
    return c.janet_wrap_array(array);
}

fn cfunArrayFill(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 2);
    const array = try arglayer.getArray(argv, 0);
    const x = if (argc == 2) argv[1] else c.janet_wrap_nil();
    var i: i32 = 0;
    while (i < array.*.count) : (i += 1) array.*.data[@intCast(i)] = x;
    return argv[0];
}

fn cfunArrayPop(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    return janet_array_pop(try arglayer.getArray(argv, 0));
}

fn cfunArrayPeek(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    return janet_array_peek(try arglayer.getArray(argv, 0));
}

fn cfunArrayPush(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, -1);
    const array = try arglayer.getArray(argv, 0);
    if (std.math.maxInt(i32) - argc + 1 <= array.*.count) return raise.panic("array overflow");
    const newcount = array.*.count - 1 + argc;
    janet_array_ensure(array, newcount, 2);
    if (argc > 1) {
        safe_memcpy(
            @ptrCast(array.*.data + @as(usize, @intCast(array.*.count))),
            @ptrCast(argv + 1),
            @as(usize, @intCast(argc - 1)) *% @sizeOf(c.Janet),
        );
    }
    array.*.count = newcount;
    return argv[0];
}

fn cfunArrayEnsure(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 3);
    const array = try arglayer.getArray(argv, 0);
    const newcount = try arglayer.getInteger(argv, 1);
    const growth = try arglayer.getInteger(argv, 2);
    if (newcount < 1) return raise.panic("expected positive integer");
    janet_array_ensure(array, newcount, growth);
    return argv[0];
}

fn cfunArraySlice(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    const view = try arglayer.getIndexed(argv, 0);
    const range = try arglayer.getSlice(argc, argv);
    const len = range.end - range.start;
    const array = janet_array(len);
    if (array.*.data != null) {
        safe_memcpy(
            @ptrCast(array.*.data),
            @ptrCast(view.items + @as(usize, @intCast(range.start))),
            @sizeOf(c.Janet) *% asSize(len),
        );
    }
    array.*.count = len;
    return c.janet_wrap_array(array);
}

/// The aliasing check is the C original's and is not paranoia: concatenating
/// an array onto itself grows it, and the growth may move the payload, so the
/// view is reserved first and then taken again. It is done here rather than in
/// the loop because `janet_array_push` grows one element at a time.
fn appendIndexed(array: [*c]c.JanetArray, x: c.Janet, vals_in: [*c]const c.Janet, len_in: i32) raise.Raising(void) {
    var vals = vals_in;
    var len = len_in;
    if (array.*.data == vals) {
        janet_array_ensure(array, array.*.count + len, 2);
        _ = c.janet_indexed_view(x, &vals, &len);
    }
    var j: i32 = 0;
    while (j < len) : (j += 1) try arrayPush(array, vals[@intCast(j)]);
}

fn cfunArrayConcat(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, -1);
    const array = try arglayer.getArray(argv, 0);
    var i: i32 = 1;
    while (i < argc) : (i += 1) {
        switch (c.janet_type(argv[@intCast(i)])) {
            c.JANET_ARRAY, c.JANET_TUPLE => {
                var len: i32 = 0;
                var vals: [*c]const c.Janet = null;
                _ = c.janet_indexed_view(argv[@intCast(i)], &vals, &len);
                try appendIndexed(array, argv[@intCast(i)], vals, len);
            },
            else => try arrayPush(array, argv[@intCast(i)]),
        }
    }
    return c.janet_wrap_array(array);
}

/// `array/join` differs from `array/concat` in exactly one way: a part that is
/// not indexed is an error here and is appended as a single element there.
fn cfunArrayJoin(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, -1);
    const array = try arglayer.getArray(argv, 0);
    var i: i32 = 1;
    while (i < argc) : (i += 1) {
        var len: i32 = 0;
        var vals: [*c]const c.Janet = null;
        if (c.janet_indexed_view(argv[@intCast(i)], &vals, &len) == 0) {
            return pp_format.panicf("expected indexed type for argument %d, got %v", .{ i, argv[@intCast(i)] });
        }
        try appendIndexed(array, argv[@intCast(i)], vals, len);
    }
    return c.janet_wrap_array(array);
}

fn cfunArrayInsert(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 2, -1);
    const array = try arglayer.getArray(argv, 0);
    var at = try arglayer.getInteger(argv, 1);
    if (at < 0) at = array.*.count + at + 1;
    if (at < 0 or at > array.*.count) {
        return pp_format.panicf("insertion index %d out of range [0,%d]", .{ at, array.*.count });
    }
    const chunksize = @as(usize, @intCast(argc - 2)) *% @sizeOf(c.Janet);
    const restsize = @as(usize, @intCast(array.*.count - at)) *% @sizeOf(c.Janet);
    if (std.math.maxInt(i32) - (argc - 2) < array.*.count) return raise.panic("array overflow");
    janet_array_ensure(array, array.*.count + argc - 2, 2);
    if (restsize != 0) {
        const dest = array.*.data + @as(usize, @intCast(at + argc - 2));
        const src = array.*.data + @as(usize, @intCast(at));
        std.mem.copyBackwards(u8, @as([*]u8, @ptrCast(dest))[0..restsize], @as([*]const u8, @ptrCast(src))[0..restsize]);
    }
    safe_memcpy(@ptrCast(array.*.data + @as(usize, @intCast(at))), @ptrCast(argv + 2), chunksize);
    array.*.count += argc - 2;
    return argv[0];
}

fn cfunArrayRemove(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 2, 3);
    const array = try arglayer.getArray(argv, 0);
    var at = try arglayer.getInteger(argv, 1);
    var n: i32 = 1;
    if (at < 0) at = array.*.count + at;
    if (at < 0 or at > array.*.count) {
        return pp_format.panicf("removal index %d out of range [0,%d]", .{ at, array.*.count });
    }
    if (argc == 3) {
        n = try arglayer.getInteger(argv, 2);
        if (n < 0) return pp_format.panicf("expected non-negative integer for argument n, got %v", .{argv[2]});
    }
    if (at + n > array.*.count) n = array.*.count - at;
    const moved = @as(usize, @intCast(array.*.count - at - n)) *% @sizeOf(c.Janet);
    if (moved != 0) {
        const dest = array.*.data + @as(usize, @intCast(at));
        const src = array.*.data + @as(usize, @intCast(at + n));
        std.mem.copyForwards(u8, @as([*]u8, @ptrCast(dest))[0..moved], @as([*]const u8, @ptrCast(src))[0..moved]);
    }
    array.*.count -= n;
    return argv[0];
}

fn cfunArrayTrim(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const array = try arglayer.getArray(argv, 0);
    if (array.*.count != 0) {
        if (array.*.count < array.*.capacity) {
            const new_data = c.janet_realloc(
                @ptrCast(array.*.data),
                @as(usize, @intCast(array.*.count)) *% @sizeOf(c.Janet),
            ) orelse c.janet_zig_out_of_memory();
            array.*.data = @ptrCast(@alignCast(new_data));
            array.*.capacity = array.*.count;
        }
    } else {
        array.*.capacity = 0;
        c.janet_free(@ptrCast(array.*.data));
        array.*.data = null;
    }
    return argv[0];
}

fn cfunArrayClear(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    (try arglayer.getArray(argv, 0)).*.count = 0;
    return argv[0];
}

export fn janet_lib_array(env: *c.JanetTable) callconv(.c) void {
    const entries = [_]corefn.Entry{
        corefn.reg("array/new", &cfunArrayNew, @src(), "(array/new capacity)", "Creates a new empty array with a pre-allocated capacity. The same as " ++
            "`(array)` but can be more efficient if the maximum size of an array is known."),
        corefn.reg("array/weak", &cfunArrayWeak, @src(), "(array/weak capacity)", "Creates a new empty array with a pre-allocated capacity and support for weak references. Similar to `array/new`."),
        corefn.reg("array/new-filled", &cfunArrayNewFilled, @src(), "(array/new-filled count &opt value)", "Creates a new array of `count` elements, all set to `value`, which defaults to nil. Returns the new array."),
        corefn.reg("array/fill", &cfunArrayFill, @src(), "(array/fill arr &opt value)", "Replace all elements of an array with `value` (defaulting to nil) without changing the length of the array. " ++
            "Returns the modified array."),
        corefn.reg("array/pop", &cfunArrayPop, @src(), "(array/pop arr)", "Remove the last element of the array and return it. If the array is empty, will return nil. Modifies " ++
            "the input array."),
        corefn.reg("array/peek", &cfunArrayPeek, @src(), "(array/peek arr)", "Returns the last element of the array. Does not modify the array."),
        corefn.reg("array/push", &cfunArrayPush, @src(), "(array/push arr & xs)", "Push all the elements of xs to the end of an array. Modifies the input array and returns it."),
        corefn.reg("array/ensure", &cfunArrayEnsure, @src(), "(array/ensure arr capacity growth)", "Ensures that the memory backing the array is large enough for `capacity` " ++
            "items at the given rate of growth. `capacity` and `growth` must be integers. " ++
            "If the backing capacity is already enough, then this function does nothing. " ++
            "Otherwise, the backing memory will be reallocated so that there is enough space."),
        corefn.reg("array/slice", &cfunArraySlice, @src(), "(array/slice arrtup &opt start end)", "Takes a slice of array or tuple from `start` to `end`. The range is half open, " ++
            "[start, end). Indexes can also be negative, indicating indexing from the " ++
            "end of the array. By default, `start` is 0 and `end` is the length of the array. " ++
            "Note that if the range is negative, it is taken as (start, end] to allow a full " ++
            "negative slice range. Returns a new array."),
        corefn.reg("array/concat", &cfunArrayConcat, @src(), "(array/concat arr & parts)", "Concatenates a variable number of arrays (and tuples) into the first argument, " ++
            "which must be an array. If any of the parts are arrays or tuples, their elements will " ++
            "be inserted into the array. Otherwise, each part in `parts` will be appended to `arr` in order. " ++
            "Return the modified array `arr`."),
        corefn.reg("array/insert", &cfunArrayInsert, @src(), "(array/insert arr at & xs)", "Insert all `xs` into array `arr` at index `at`. `at` should be an integer between " ++
            "0 and the length of the array. A negative value for `at` will index backwards from " ++
            "the end of the array, inserting after the index such that inserting at -1 appends to " ++
            "the array. Returns the array."),
        corefn.reg("array/remove", &cfunArrayRemove, @src(), "(array/remove arr at &opt n)", "Remove up to `n` elements starting at index `at` in array `arr`. `at` can index from " ++
            "the end of the array with a negative index, and `n` must be a non-negative integer. " ++
            "By default, `n` is 1. " ++
            "Returns the array."),
        corefn.reg("array/trim", &cfunArrayTrim, @src(), "(array/trim arr)", "Set the backing capacity of an array to its current length. Returns the modified array."),
        corefn.reg("array/clear", &cfunArrayClear, @src(), "(array/clear arr)", "Empties an array, setting it's count to 0 but does not free the backing capacity. " ++
            "Returns the modified array."),
        corefn.reg("array/join", &cfunArrayJoin, @src(), "(array/join arr & parts)", "Join a variable number of arrays and tuples into the first argument, " ++
            "which must be an array. " ++
            "Return the modified array `arr`."),
        corefn.end,
    };
    corefn.install(env, &entries);
}

// ---------------------------------------------------------------- buffer/*

/// `src/core/util.h`, which `abi.zig` does not translate. Provided by
/// `pp_format.zig` or by `pp.c` according to `-Dpp`; either way it is a
/// C-ABI call across a selector seam, so a bad conversion inside it raises by
/// jumping through the two frames below.
extern fn janet_buffer_format(
    b: *c.JanetBuffer,
    strfrmt: [*c]const u8,
    argstart: i32,
    argc: i32,
    argv: [*c]c.Janet,
) callconv(.c) void;

/// `should_reverse_bytes`. The keyword names the byte order the caller wants,
/// and the answer is whether it differs from the host's -- so `:native` is
/// always false and the other two are decided at compile time.
///
/// `janet.h` picks `JANET_LITTLE_ENDIAN` or `JANET_BIG_ENDIAN` from the
/// target, and the check below reads the same macros rather than Zig's own
/// `@import("builtin")`, so a configuration that overrides them is honoured on
/// both sides of the selector.
const big_endian = @hasDecl(c, "JANET_BIG_ENDIAN");

fn shouldReverseBytes(argv: [*c]c.Janet, n: i32) raise.Raising(bool) {
    const order = try arglayer.getKeyword(argv, n);
    if (c.janet_cstrcmp(order, "le") == 0) return big_endian;
    if (c.janet_cstrcmp(order, "be") == 0) return !big_endian;
    if (c.janet_cstrcmp(order, "native") == 0) return false;
    // The C original reports argv[1] rather than argv[n]. Every caller passes
    // 1, so the two agree; reproduced rather than corrected.
    return pp_format.panicf("expected endianness :le, :be or :native, got %v", .{argv[1]});
}

/// Push `data`'s bytes, reversed if the caller asked for the other order.
/// `janet_getuinteger16` and friends have already rejected anything that does
/// not fit, so the only thing left is the byte order.
fn pushScalar(comptime T: type, buffer: *c.JanetBuffer, data: T, reverse: bool) raise.Raising(void) {
    var bytes: [@sizeOf(T)]u8 = @bitCast(data);
    if (reverse) std.mem.reverse(u8, &bytes);
    try bufferPushBytes(buffer, &bytes, @sizeOf(T));
}

fn cfunBufferNew(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    return c.janet_wrap_buffer(janet_buffer(try arglayer.getInteger(argv, 0)));
}

fn cfunBufferNewFilled(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 2);
    var count = try arglayer.getInteger(argv, 0);
    if (count < 0) count = 0;
    const byte: u8 = if (argc == 2) @truncate(@as(u32, @bitCast(try arglayer.getInteger(argv, 1)))) else 0;
    const buffer = janet_buffer(count);
    if (buffer.data != null and count > 0) @memset(buffer.data[0..@intCast(count)], byte);
    buffer.count = count;
    return c.janet_wrap_buffer(buffer);
}

fn cfunBufferFrombytes(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    const buffer = janet_buffer(argc);
    var i: i32 = 0;
    while (i < argc) : (i += 1) {
        const byte = try arglayer.getInteger(argv, i);
        buffer.data[@intCast(i)] = @truncate(@as(u32, @bitCast(byte)));
    }
    buffer.count = argc;
    return c.janet_wrap_buffer(buffer);
}

fn cfunBufferFill(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 2);
    const buffer = try arglayer.getBuffer(argv, 0);
    const byte: u8 = if (argc == 2) @truncate(@as(u32, @bitCast(try arglayer.getInteger(argv, 1)))) else 0;
    if (buffer.*.count != 0) @memset(buffer.*.data[0..@intCast(buffer.*.count)], byte);
    return argv[0];
}

/// The floor of four is the C original's and is not the same as `array/trim`'s
/// behaviour: an empty buffer keeps a four-byte allocation where an empty
/// array releases its payload entirely.
fn cfunBufferTrim(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const buffer = try arglayer.getBuffer(argv, 0);
    try canRealloc(buffer);
    if (buffer.*.count < buffer.*.capacity) {
        const newcap = if (buffer.*.count > 4) buffer.*.count else 4;
        const new_data = c.janet_realloc(@ptrCast(buffer.*.data), @intCast(newcap)) orelse
            c.janet_zig_out_of_memory();
        buffer.*.data = @ptrCast(new_data);
        buffer.*.capacity = newcap;
    }
    return argv[0];
}

fn cfunBufferU8(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, -1);
    const buffer = try arglayer.getBuffer(argv, 0);
    var i: i32 = 1;
    while (i < argc) : (i += 1) {
        try raise.crossing(janet_buffer_push_u8(buffer, @truncate(@as(u32, @bitCast(try arglayer.getInteger(argv, i))))));
    }
    return argv[0];
}

fn cfunBufferWord(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, -1);
    const buffer = try arglayer.getBuffer(argv, 0);
    var i: i32 = 1;
    while (i < argc) : (i += 1) {
        const number = try arglayer.getNumber(argv, i);
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
fn pushBytesAliasSafe(buffer: *c.JanetBuffer, view_in: c.JanetByteView) raise.Raising(void) {
    var view = view_in;
    if (view.bytes == buffer.data) {
        try bufferEnsure(buffer, buffer.count + view.len, 2);
        view.bytes = buffer.data;
    }
    try bufferPushBytes(buffer, view.bytes, view.len);
}

fn cfunBufferChars(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, -1);
    const buffer = try arglayer.getBuffer(argv, 0);
    var i: i32 = 1;
    while (i < argc) : (i += 1) try pushBytesAliasSafe(buffer, try arglayer.getBytes(argv, i));
    return argv[0];
}

fn cfunBufferPushUint16(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 3);
    const buffer = try arglayer.getBuffer(argv, 0);
    const reverse = try shouldReverseBytes(argv, 1);
    try pushScalar(u16, buffer, try arglayer.getUInteger16(argv, 2), reverse);
    return argv[0];
}

fn cfunBufferPushUint32(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 3);
    const buffer = try arglayer.getBuffer(argv, 0);
    const reverse = try shouldReverseBytes(argv, 1);
    try pushScalar(u32, buffer, try arglayer.getUInteger(argv, 2), reverse);
    return argv[0];
}

fn cfunBufferPushUint64(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 3);
    const buffer = try arglayer.getBuffer(argv, 0);
    const reverse = try shouldReverseBytes(argv, 1);
    try pushScalar(u64, buffer, try arglayer.getUInteger64(argv, 2), reverse);
    return argv[0];
}

fn cfunBufferPushFloat32(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 3);
    const buffer = try arglayer.getBuffer(argv, 0);
    const reverse = try shouldReverseBytes(argv, 1);
    try pushScalar(f32, buffer, @floatCast(try arglayer.getNumber(argv, 2)), reverse);
    return argv[0];
}

fn cfunBufferPushFloat64(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 3);
    const buffer = try arglayer.getBuffer(argv, 0);
    const reverse = try shouldReverseBytes(argv, 1);
    try pushScalar(f64, buffer, try arglayer.getNumber(argv, 2), reverse);
    return argv[0];
}

/// A number is a byte and anything else is a byte sequence, which is what
/// makes `buffer/push` the union of `buffer/push-byte` and
/// `buffer/push-string`.
fn bufferPushImpl(buffer: *c.JanetBuffer, argv: [*c]c.Janet, start: i32, argc: i32) raise.Raising(void) {
    var i: i32 = start;
    while (i < argc) : (i += 1) {
        if (c.janet_checktype(argv[@intCast(i)], c.JANET_NUMBER) != 0) {
            try raise.crossing(janet_buffer_push_u8(buffer, @truncate(@as(u32, @bitCast(try arglayer.getInteger(argv, i))))));
        } else {
            try pushBytesAliasSafe(buffer, try arglayer.getBytes(argv, i));
        }
    }
}

/// Writing before the end shortens the buffer for the duration of the write
/// and then restores the length, so a short write leaves the tail intact and a
/// long one extends it. That is the whole difference from `buffer/push`.
fn cfunBufferPushAt(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 2, -1);
    const buffer = try arglayer.getBuffer(argv, 0);
    const index = try arglayer.getInteger(argv, 1);
    const old_count = buffer.*.count;
    if (index < 0 or index > old_count) return pp_format.panicf("index out of range [0, %d)", .{old_count});
    buffer.*.count = index;
    try bufferPushImpl(buffer, argv, 2, argc);
    if (buffer.*.count < old_count) buffer.*.count = old_count;
    return argv[0];
}

fn cfunBufferPush(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, -1);
    try bufferPushImpl(try arglayer.getBuffer(argv, 0), argv, 1, argc);
    return argv[0];
}

fn cfunBufferClear(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    (try arglayer.getBuffer(argv, 0)).*.count = 0;
    return argv[0];
}

fn cfunBufferPopn(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 2);
    const buffer = try arglayer.getBuffer(argv, 0);
    const n = try arglayer.getInteger(argv, 1);
    if (n < 0) return raise.panic("n must be non-negative");
    buffer.*.count = if (buffer.*.count < n) 0 else buffer.*.count - n;
    return argv[0];
}

fn cfunBufferSlice(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    const view = try arglayer.getBytes(argv, 0);
    const range = try arglayer.getSlice(argc, argv);
    const len = range.end - range.start;
    const buffer = janet_buffer(len);
    if (buffer.data != null) {
        safe_memcpy(
            @ptrCast(buffer.data),
            @ptrCast(view.bytes + @as(usize, @intCast(range.start))),
            @intCast(len),
        );
    }
    buffer.count = len;
    return c.janet_wrap_buffer(buffer);
}

const BitLoc = struct { buffer: *c.JanetBuffer, index: i32, bit: u3 };

/// `bitloc`. The index is a bit index rather than a byte index, and the test
/// `bitindex != x` is what rejects a fractional one -- a check the argument
/// layer cannot make, because the value is legitimately wider than the byte
/// index it becomes.
fn bitloc(argc: i32, argv: [*c]c.Janet) raise.Raising(BitLoc) {
    try arglayer.fixarity(argc, 2);
    const buffer = try arglayer.getBuffer(argv, 0);
    const x = try arglayer.getNumber(argv, 1);
    const bitindex: i64 = @intFromFloat(x);
    const byteindex = bitindex >> 3;
    if (@as(f64, @floatFromInt(bitindex)) != x or bitindex < 0 or byteindex >= buffer.*.count) {
        return pp_format.panicf("invalid bit index %v", .{argv[1]});
    }
    return .{ .buffer = buffer, .index = @intCast(byteindex), .bit = @intCast(bitindex & 7) };
}

fn cfunBufferBitset(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    const loc = try bitloc(argc, argv);
    loc.buffer.data[@intCast(loc.index)] |= @as(u8, 1) << loc.bit;
    return argv[0];
}

fn cfunBufferBitclear(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    const loc = try bitloc(argc, argv);
    loc.buffer.data[@intCast(loc.index)] &= ~(@as(u8, 1) << loc.bit);
    return argv[0];
}

fn cfunBufferBitget(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    const loc = try bitloc(argc, argv);
    const set = loc.buffer.data[@intCast(loc.index)] & (@as(u8, 1) << loc.bit);
    return c.janet_wrap_boolean(@intCast(set));
}

fn cfunBufferBittoggle(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    const loc = try bitloc(argc, argv);
    loc.buffer.data[@intCast(loc.index)] ^= @as(u8, 1) << loc.bit;
    return argv[0];
}

fn cfunBufferBlit(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 2, 5);
    const dest = try arglayer.getBuffer(argv, 0);
    var src = try arglayer.getBytes(argv, 1);
    const same_buf = src.bytes == dest.*.data;
    var offset_dest: i32 = 0;
    var offset_src: i32 = 0;
    if (argc > 2 and c.janet_checktype(argv[2], c.JANET_NIL) == 0) {
        offset_dest = try arglayer.getHalfRange(argv, 2, dest.*.count, "dest-start");
    }
    if (argc > 3 and c.janet_checktype(argv[3], c.JANET_NIL) == 0) {
        offset_src = try arglayer.getHalfRange(argv, 3, src.len, "src-start");
    }
    var length_src: i32 = undefined;
    if (argc > 4) {
        var src_end = src.len;
        if (c.janet_checktype(argv[4], c.JANET_NIL) == 0) {
            src_end = try arglayer.getHalfRange(argv, 4, src.len, "src-end");
        }
        length_src = src_end - offset_src;
        if (length_src < 0) length_src = 0;
    } else {
        length_src = src.len - offset_src;
    }
    const last: i64 = @as(i64, offset_dest) + length_src;
    if (last > std.math.maxInt(i32)) return raise.panic("buffer blit out of range");
    const last32: i32 = @intCast(last);
    try bufferEnsure(dest, last32, 2);
    if (last32 > dest.*.count) dest.*.count = last32;
    if (length_src != 0) {
        const n: usize = @intCast(length_src);
        // janet_buffer_ensure may have invalidated src.
        if (same_buf) src.bytes = dest.*.data;
        const to = dest.*.data + @as(usize, @intCast(offset_dest));
        const from = src.bytes + @as(usize, @intCast(offset_src));
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

fn cfunBufferFormat(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 2, -1);
    const buffer = try arglayer.getBuffer(argv, 0);
    const strfrmt = try arglayer.getString(argv, 1);
    try pp_format.bufferFormat(buffer, @ptrCast(strfrmt), 1, argc, argv);
    return argv[0];
}

fn cfunBufferFormatAt(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 2, -1);
    const buffer = try arglayer.getBuffer(argv, 0);
    var at = try arglayer.getInteger(argv, 1);
    if (at < 0) at += buffer.*.count + 1;
    if (at > buffer.*.count or at < 0) {
        return pp_format.panicf("expected index at to be in range [0, %d), got %d", .{ buffer.*.count, at });
    }
    const oldcount = buffer.*.count;
    buffer.*.count = at;
    const strfrmt = try arglayer.getString(argv, 2);
    try pp_format.bufferFormat(buffer, @ptrCast(strfrmt), 2, argc, argv);
    if (buffer.*.count < oldcount) buffer.*.count = oldcount;
    return argv[0];
}

export fn janet_lib_buffer(env: *c.JanetTable) callconv(.c) void {
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
