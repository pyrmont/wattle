//! The compiler's register allocator: a bitmap of the registers a scope has
//! handed out.
//!
//! `allocate` takes the lowest free register and `free` releases one.
//! `touch` marks one taken without allocating it, `isTaken` reads the bit, and
//! `allocateTemp` and `freeTemp` are the scratch-register pair. `clone` starts
//! a child scope from a parent's occupancy.
//!
//! One bit per register in 32-bit chunks, grown on demand. Chunk 7 covers
//! registers 224 through 255 and is born with its high sixteen bits set, so
//! `allocate` never hands out 240 through 255 by accident. Those are reserved
//! for `allocateTemp`, which falls back to them where a form needs a scratch
//! register and the ordinary range is exhausted.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const constants = @import("constants");
const fatal = @import("../fatal.zig");
const utils = @import("../utils.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The chunk that covers registers 224 through 255, and the only one born
/// with any bit already set.
const reserved_chunk = 7;

/// The bits `reserved_chunk` starts with set: registers 240 through 255, which
/// `allocate` therefore never hands out.
const reserved_mask: u32 = 0xffff0000;

/// The first reserved register, 240. `allocateTemp` falls back to
/// `temporary_base` plus the temporary's own index, and `freeTemp` releases
/// nothing at or above it because the reserved block is never in the bitmap.
const temporary_base = 0xf0;

// ==========================================================================
// Types
// ==========================================================================

/// One scope's register occupancy.
///
/// The initial state is the field defaults, so `.{}` is how one is made, and
/// `deinit` returns it to that state.
pub const RegisterAllocator = struct {
    /// One bit per register, in 32-bit chunks. The count is the container's.
    chunks: std.ArrayListUnmanaged(u32) = .empty,
    max: u32 = 0,
    regtemps: i32 = 0,

    /// Releases the bitmap and returns this allocator to its initial state.
    pub fn deinit(self: *RegisterAllocator) void {
        self.chunks.deinit(utils.heap);
        self.chunks = .empty;
    }

    /// A child scope starts from the parent's occupancy but not its
    /// temporaries: a temporary is live only inside the form that took it.
    pub fn clone(self: *const RegisterAllocator) RegisterAllocator {
        var copy: RegisterAllocator = .{ .max = self.max };
        copy.chunks.appendSlice(utils.heap, self.chunks.items) catch fatal.outOfMemory();
        return copy;
    }

    /// Marks `register` taken without allocating it, which is what a slot the
    /// parent already owns needs where a child scope must not reuse it.
    pub fn touch(self: *RegisterAllocator, register: u32) void {
        const chunk: u32 = register >> 5;
        const bit: u5 = @intCast(register & 0x1f);
        while (chunk >= self.chunks.items.len) self.pushChunk();
        self.chunks.items[chunk] |= @as(u32, 1) << bit;
    }

    /// The lowest free register, growing the bitmap where every chunk is full.
    pub fn allocate(self: *RegisterAllocator) u32 {
        const old_chunk_count = self.chunks.items.len;
        var chunk: usize = 0;
        var bit: u5 = 0;
        while (chunk < old_chunk_count) : (chunk += 1) {
            const block = self.chunks.items[chunk];
            if (block == std.math.maxInt(u32)) continue;
            bit = @intCast(@ctz(~block));
            break;
        } else {
            self.pushChunk();
            chunk = old_chunk_count;
        }

        self.chunks.items[chunk] |= @as(u32, 1) << bit;
        const register = (@as(u32, @intCast(chunk)) << 5) + @as(u32, bit);
        if (register > self.max) self.max = register;
        return register;
    }

    /// Releases `register`. The caller has already established that it was
    /// taken.
    pub fn free(self: *RegisterAllocator, register: u32) void {
        const chunk: usize = register >> 5;
        const bit: u5 = @intCast(register & 0x1f);
        self.chunks.items[chunk] &= ~(@as(u32, 1) << bit);
    }

    /// Whether `register` is taken, growing the bitmap far enough to have a
    /// bit for it.
    pub fn isTaken(self: *RegisterAllocator, register: u32) bool {
        const chunk: u32 = register >> 5;
        const bit: u5 = @intCast(register & 0x1f);
        while (chunk >= self.chunks.items.len) self.pushChunk();
        return self.chunks.items[chunk] & (@as(u32, 1) << bit) != 0;
    }

    /// A scratch register for one form.
    ///
    /// A temporary may be taken once at a time, which `regtemps` tracks and
    /// this aborts on: two live uses of the same temporary would emit two
    /// writes to one register.
    ///
    /// Where the ordinary range is exhausted the reserved block at
    /// `temporary_base` is used instead, and that is what chunk 7 is born half
    /// full for.
    pub fn allocateTemp(self: *RegisterAllocator, temporary: constants.RegisterTemp) u8 {
        const temporary_index: u5 = @intFromEnum(temporary);
        const temporary_mask = @as(i32, 1) << temporary_index;
        if (self.regtemps & temporary_mask != 0) {
            fatal.fatal("regtemp already allocated");
        }
        self.regtemps |= temporary_mask;
        const old_max = self.max;
        var register = self.allocate();
        if (register > 0xff) {
            register = temporary_base + @as(u32, @intFromEnum(temporary));
            self.max = @max(register, old_max);
        }
        return @intCast(register);
    }

    /// Releases a register `allocateTemp` gave out. The reserved fallback is
    /// never in the bitmap, so only an ordinary register is released.
    pub fn freeTemp(
        self: *RegisterAllocator,
        register: u32,
        temporary: constants.RegisterTemp,
    ) void {
        const temporary_index: u5 = @intFromEnum(temporary);
        self.regtemps &= ~(@as(i32, 1) << temporary_index);
        if (register < temporary_base) self.free(register);
    }

    /// Appends one chunk, with the reserved bits already set where this is
    /// `reserved_chunk`.
    fn pushChunk(self: *RegisterAllocator) void {
        const chunk: u32 = if (self.chunks.items.len == reserved_chunk) reserved_mask else 0;
        self.chunks.append(utils.heap, chunk) catch fatal.outOfMemory();
    }
};
