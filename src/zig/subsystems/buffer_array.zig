//! jump-transparent
//!
//! The two growable containers: `JanetBuffer` and `JanetArray`. This is the
//! first of the three increments Phase 8 Part 6 is split into, and it takes
//! the data-structure core of `src/core/buffer.c` and `src/core/array.c` — the
//! constructors, the capacity policy, and the push/pop primitives. The
//! `JANET_CORE_FN` bodies in both files stay in C, as they do for every
//! subsystem ported so far; they are standard-library surface, not value
//! construction, and they reach the code below through the same public API an
//! embedder uses.
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
const c = abi.c;

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
/// function was `static` in `buffer.c`, and `cfun_buffer_trim` calls it from
/// the standard-library half of the file that stays in C, so it is exported
/// here and declared in `util.h` beside the other cross-file buffer helpers.
/// Duplicating it instead would put the same policy in two places and let them
/// drift; one definition and three words of declaration is cheaper.
export fn janet_buffer_can_realloc(buffer: *c.JanetBuffer) callconv(.c) void {
    if ((buffer.gc.flags & buffer_flag_no_realloc) != 0) {
        c.janet_panic("buffer cannot reallocate foreign memory");
    }
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
export fn janet_pointer_buffer_unsafe(memory: ?*anyopaque, capacity: i32, count: i32) callconv(.c) *c.JanetBuffer {
    if (count < 0) c.janet_panic("count < 0");
    if (capacity < count) c.janet_panic("capacity < count");
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
export fn janet_buffer_ensure(buffer: *c.JanetBuffer, capacity_in: i32, growth: i32) callconv(.c) void {
    var capacity = capacity_in;
    const old = buffer.data;
    if (capacity <= buffer.capacity) return;
    janet_buffer_can_realloc(buffer);
    // Cannot overflow: both factors fit in 32 bits, so the product fits in 62.
    const big_capacity: i64 = @as(i64, capacity) * @as(i64, growth);
    capacity = if (big_capacity > std.math.maxInt(i32)) std.math.maxInt(i32) else @truncate(big_capacity);
    c.janet_gcpressure(asSize(capacity -% buffer.capacity));
    const new_data = c.janet_realloc(old, asSize(capacity)) orelse c.janet_zig_out_of_memory();
    buffer.data = @ptrCast(new_data);
    buffer.capacity = capacity;
}

/// Set a buffer's length, zero-filling any bytes the count newly covers.
export fn janet_buffer_setcount(buffer: *c.JanetBuffer, count: i32) callconv(.c) void {
    if (count < 0) return;
    if (count > buffer.count) {
        const oldcount = buffer.count;
        janet_buffer_ensure(buffer, count, 1);
        _ = c.memset(buffer.data + @as(usize, @intCast(oldcount)), 0, @intCast(count - oldcount));
    }
    buffer.count = count;
}

/// Reserve room for `n` more bytes, so that the next `n` pushes cannot
/// reallocate. The overflow check is the first statement, before any
/// allocation, which is what makes the panic safe to raise through this frame.
export fn janet_buffer_extra(buffer: *c.JanetBuffer, n: i32) callconv(.c) void {
    if (@as(i64, n) + @as(i64, buffer.count) > std.math.maxInt(i32)) {
        c.janet_panic("buffer overflow");
    }
    // Cannot overflow for a positive `n`: the check above bounds the sum. A
    // negative `n` only shrinks it, and `count` is never negative.
    const new_size = buffer.count +% n;
    if (new_size > buffer.capacity) {
        janet_buffer_can_realloc(buffer);
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

export fn janet_buffer_push_cstring(buffer: *c.JanetBuffer, cstring: [*c]const u8) callconv(.c) void {
    const len: i32 = @intCast(c.strlen(cstring));
    janet_buffer_push_bytes(buffer, cstring, len);
}

export fn janet_buffer_push_bytes(buffer: *c.JanetBuffer, string: [*c]const u8, length: i32) callconv(.c) void {
    if (0 == length) return;
    janet_buffer_extra(buffer, length);
    _ = c.memcpy(buffer.data + @as(usize, @intCast(buffer.count)), string, @intCast(length));
    buffer.count += length;
}

export fn janet_buffer_push_string(buffer: *c.JanetBuffer, string: [*c]const u8) callconv(.c) void {
    janet_buffer_push_bytes(buffer, string, stringLength(string));
}

export fn janet_buffer_push_u8(buffer: *c.JanetBuffer, byte: u8) callconv(.c) void {
    janet_buffer_extra(buffer, 1);
    buffer.data[@intCast(buffer.count)] = byte;
    buffer.count += 1;
}

/// The three multi-byte pushes write little-endian regardless of host order,
/// which is what the C original does by shifting rather than by copying.
export fn janet_buffer_push_u16(buffer: *c.JanetBuffer, x: u16) callconv(.c) void {
    janet_buffer_extra(buffer, 2);
    const at: usize = @intCast(buffer.count);
    buffer.data[at] = @truncate(x);
    buffer.data[at + 1] = @truncate(x >> 8);
    buffer.count += 2;
}

export fn janet_buffer_push_u32(buffer: *c.JanetBuffer, x: u32) callconv(.c) void {
    janet_buffer_extra(buffer, 4);
    const at: usize = @intCast(buffer.count);
    inline for (0..4) |i| {
        buffer.data[at + i] = @truncate(x >> (8 * i));
    }
    buffer.count += 4;
}

export fn janet_buffer_push_u64(buffer: *c.JanetBuffer, x: u64) callconv(.c) void {
    janet_buffer_extra(buffer, 8);
    const at: usize = @intCast(buffer.count);
    inline for (0..8) |i| {
        buffer.data[at + i] = @truncate(x >> (8 * i));
    }
    buffer.count += 8;
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

export fn janet_array_push(array: *c.JanetArray, x: c.Janet) callconv(.c) void {
    if (array.count == std.math.maxInt(i32)) {
        c.janet_panic("array overflow");
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
