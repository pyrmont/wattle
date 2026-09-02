//! The compiler's register allocator: a bitmap of the registers a scope has
//! handed out.
//!
//! One bit per register in 32-bit chunks, grown on demand. Chunk 7 --- registers
//! 224 through 255 --- is born with its high sixteen bits set, so `allocate`
//! never hands out 240-255 by accident: those are reserved for `allocateTemp`,
//! which falls back to them when a form needs a scratch register and the
//! ordinary range is exhausted.

const std = @import("std");
const constants = @import("constants");

const utils = @import("../utils.zig");
const fatal = @import("../fatal.zig");
const reserved_chunk = 7;
const reserved_mask: u32 = 0xffff0000;
const temporary_base = 0xf0;

pub const RegisterAllocator = struct {
    /// One bit per register, in 32-bit chunks. The count is the container's.
    chunks: std.ArrayListUnmanaged(u32) = .empty,
    max: u32 = 0,
    regtemps: i32 = 0,

    /// The initial state is the field defaults; `.{}` is how one is made.
    pub fn deinit(self: *RegisterAllocator) void {
        self.chunks.deinit(utils.heap);
        self.chunks = .empty;
    }

    /// A child scope starts from the parent's occupancy but not its temporaries:
    /// a temporary is live only inside the form that took it.
    pub fn clone(self: *const RegisterAllocator) RegisterAllocator {
        var copy: RegisterAllocator = .{ .max = self.max };
        copy.chunks.appendSlice(utils.heap, self.chunks.items) catch fatal.outOfMemory();
        return copy;
    }

    /// Mark `register` taken without allocating it --- what a slot the parent
    /// already owns needs when a child scope must not reuse it.
    pub fn touch(self: *RegisterAllocator, register: u32) void {
        const chunk: u32 = register >> 5;
        const bit: u5 = @intCast(register & 0x1f);
        while (chunk >= self.chunks.items.len) self.pushChunk();
        self.chunks.items[chunk] |= @as(u32, 1) << bit;
    }

    /// The lowest free register, growing the bitmap if every chunk is full.
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

    pub fn free(self: *RegisterAllocator, register: u32) void {
        const chunk: usize = register >> 5;
        const bit: u5 = @intCast(register & 0x1f);
        self.chunks.items[chunk] &= ~(@as(u32, 1) << bit);
    }

    pub fn isTaken(self: *RegisterAllocator, register: u32) bool {
        const chunk: u32 = register >> 5;
        const bit: u5 = @intCast(register & 0x1f);
        while (chunk >= self.chunks.items.len) self.pushChunk();
        return self.chunks.items[chunk] & (@as(u32, 1) << bit) != 0;
    }

    /// A scratch register for one form. **A temporary may be taken once at a
    /// time**, which `regtemps` tracks and this aborts on: two live uses of the
    /// same temporary would emit two writes to one register.
    ///
    /// When the ordinary range is exhausted the reserved block above
    /// `temporary_base` answers instead, which is why chunk 7 is born half
    /// full.
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

    /// The reserved fallback is never in the bitmap, so only an ordinary
    /// register is released.
    pub fn freeTemp(
        self: *RegisterAllocator,
        register: u32,
        temporary: constants.RegisterTemp,
    ) void {
        const temporary_index: u5 = @intFromEnum(temporary);
        self.regtemps &= ~(@as(i32, 1) << temporary_index);
        if (register < temporary_base) self.free(register);
    }

    fn pushChunk(self: *RegisterAllocator) void {
        const chunk: u32 = if (self.chunks.items.len == reserved_chunk) reserved_mask else 0;
        self.chunks.append(utils.heap, chunk) catch fatal.outOfMemory();
    }
};
