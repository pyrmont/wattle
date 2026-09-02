//! The collector's memory: allocating a collectable block onto one of the two
//! heap lists, the root set, the GC suspend counter, and the scratch
//! allocator. Traversal and reclamation are `gc/mark.zig`'s and
//! `gc/sweep.zig`'s; this file is only where a block is born.
//!
//! Nothing here traverses or frees a collectable object. `gcallocBytes`
//! returns raw memory with only its type tag written: the caller initialises
//! the block, and the collector never looks at it until it is reachable. The
//! block lists are touched at one end only — this file prepends, and
//! `gc/sweep.zig`'s `sweep` unlinks.
//!
//! **Nothing here holds anything a skipped cleanup would strand.** One call
//! reaches code this runtime does not own: `freeOneScratch` calls a
//! `ScratchFinalizer` an embedder installed through `sfinalizer`.
//! No in-tree caller installs one, and a finalizer that raises is undefined
//! behaviour, but the frames below must still hold nothing. A raise from a
//! scratch finalizer leaves `scratch_len` unreduced and the block re-finalized
//! on the next collection, which is the behaviour a program sees.
//!
//! **The header size is added with a checked add.** A request within a header
//! of `SIZE_MAX` is an out-of-memory rather than a small allocation the caller
//! believes addresses the whole range, which is the exit `scalloc` already
//! took for its own multiplication.

const std = @import("std");
const config = @import("config");
const abi = @import("abi");

/// Which heap type a block is, stored in the low byte of its GC header's
/// flags.
///
/// It lives here rather than in `abi.zig` because nothing an author compiles
/// reads a memory type: it is the collector's vocabulary. `memoryTypeOf` below
/// is a free function rather than a `GCObject` method for the same reason —
/// a method would carry this enum into the boundary module, which is the
/// "shares a file" coupling `DESIGN.md` §14 rules out at one-declaration scale.
pub const MemoryType = enum(u8) {
    none = 0,
    string = 1,
    symbol = 2,
    array = 3,
    tuple = 4,
    table = 5,
    @"struct" = 6,
    fiber = 7,
    buffer = 8,
    function = 9,
    abstract = 10,
    funcenv = 11,
    funcdef = 12,
    threaded_abstract = 13,
    table_weakk = 14,
    table_weakv = 15,
    table_weakkv = 16,
    array_weak = 17,
};

/// The block's type, read out of the low byte of the header's flag word.
pub inline fn memoryTypeOf(self: *const abi.GCObject) MemoryType {
    return @enumFromInt(self.flags.type);
}

comptime {
    // Eighteen values in the header's order, and a byte-wide field to hold
    // them.
    std.debug.assert(@sizeOf(MemoryType) == 1);
    // Every value, not a sample: a sample cannot catch a transposition, since
    // swapping two unasserted members leaves both the count and every sampled
    // value correct. This vocabulary is read out of a marshalled image, so a
    // transposition is a wrong answer from a working program.
    const expected_memory = [_]struct { MemoryType, comptime_int }{
        .{ .none, 0 },         .{ .string, 1 },             .{ .symbol, 2 },
        .{ .array, 3 },        .{ .tuple, 4 },              .{ .table, 5 },
        .{ .@"struct", 6 },    .{ .fiber, 7 },              .{ .buffer, 8 },
        .{ .function, 9 },     .{ .abstract, 10 },          .{ .funcenv, 11 },
        .{ .funcdef, 12 },     .{ .threaded_abstract, 13 }, .{ .table_weakk, 14 },
        .{ .table_weakv, 15 }, .{ .table_weakkv, 16 },      .{ .array_weak, 17 },
    };
    std.debug.assert(expected_memory.len == @typeInfo(MemoryType).@"enum".fields.len);
    for (expected_memory) |row| std.debug.assert(@intFromEnum(row[0]) == row[1]);
    // The stored field is eight bits wide and the reachable mark is the first
    // bit above it, so a type can never collide with a flag.
    for (@typeInfo(MemoryType).@"enum".fields) |f| std.debug.assert(f.value <= 0xFF);
}
const utils = @import("utils.zig");
const fatal = @import("fatal.zig");
const wrap = @import("value/helpers/wrap.zig");
const repr = @import("repr");
const vm_state = @import("vm/state.zig");

/// The two heap lists, what the collector is owed, and what suspends it.
///
/// The lifecycle is `collectorInit` below and `gc/sweep.zig`'s `clearMemory`
/// rather than a method here, because a `deinit` needs Janet's allocator and
/// the two calls are already the ones `vm/lifecycle.zig` makes.
pub const Collector = struct {
    /// The main heap: every block `gcallocBytes` returns, newest first.
    blocks: ?*abi.GCObject = null,
    /// The weak heap, which `gc/sweep.zig`'s `clearMemory` deliberately does
    /// not walk.
    weak_blocks: ?*abi.GCObject = null,
    /// Bytes allocated since the last collection, and the threshold that ends
    /// the interval.
    next_collection: usize = 0,
    interval: usize = 0,
    block_count: usize = 0,
    /// Nesting depth, not a flag: `gclock` answers the previous value and
    /// `gcunlock` restores it, so a scope may nest inside another.
    suspend_count: u32 = 0,
    /// True for the duration of the mark phase. Nothing in the runtime reads
    /// it; `test/gc_mark.zig` does, to assert that a `gcmark` callback runs
    /// inside the phase rather than beside it.
    mark_phase: bool = false,
    /// The mark phase's recursion guard: the traversal budget `gc/mark.zig`'s
    /// `mark` spends on the way down and restores on the way up, and which
    /// `gc/mark.zig` resets at the head of every collection.
    ///
    /// **`collectorInit` sets it, and the field default deliberately does
    /// not.** The VM storage is `std.mem.zeroes(Vm)`, which does not apply a
    /// field default, so carrying the guard as the default would make `Vm{}`
    /// disagree with the zeroed storage a fresh thread actually gets --
    /// `test/vm_state.zig` compares the two -- while leaving the storage at
    /// zero anyway. `collectorInit` runs on every VM cycle, and nothing can
    /// mark before it: `gcallocBytes` refuses to run in an uninitialised VM.
    depth: u32 = 0,
    /// The number of roots that existed when the current collection began.
    /// Per-collection state, set by `gc/mark.zig`'s `collect` and read by
    /// nothing else.
    orig_rootcount: usize = 0,
};

/// The GC root set. The values the collector marks first.
pub const Roots = std.ArrayListUnmanaged(repr.Value);

/// The scratch table: allocations freed together at the next `freeAllScratch`
/// rather than by the collector.
pub const ScratchTable = std.ArrayListUnmanaged(*ScratchBlock);

pub const ScratchFinalizer = ?*const fn (?*anyopaque) callconv(.c) void;

/// `extern` for the same reason the flexible-array heads have it: a `[0]T` in
/// an auto-layout struct is not guaranteed to stay last, and if `_mem` moved
/// the payload would be written over `finalize`. `DESIGN.md` section 3 counts
/// this among the six carriers and says why `extern` is the only thing that
/// fixes the order.
pub const ScratchBlock = extern struct {
    finalize: ScratchFinalizer = null,
    _mem: [0]c_longlong = std.mem.zeroes([0]c_longlong),
    pub fn mem(_self: anytype) @TypeOf(&_self._mem[0]) {
        return @ptrCast(@alignCast(&_self._mem));
    }
};

/// The first memory type that belongs on the weak heap. The two lists are
/// split by this ordering alone, so a value outside the enumeration lands on
/// one heap or the other rather than tripping a conversion check.
const first_weak_type: MemoryType = MemoryType.table_weakk;

/// The distance from a `ScratchBlock` header to the memory it hands out.
///
/// `scratchData` adds it and `mem2scratch` subtracts it, so the two are
/// inverses only while it equals the offset of `_mem`. `@sizeOf` is that
/// offset here because the header is one pointer followed by a zero-length
/// `c_longlong` array and `extern` fixes the order; `DESIGN.md` section 3 is
/// why the `extern` is not optional.
const header_size = @sizeOf(ScratchBlock);

// ------------------------------------------------------------- collectable

/// Tell the collector that `s` bytes were allocated outside its accounting.
/// The add wraps: the field is a heuristic threshold, so a wrapped value only
/// delays a collection.
pub fn gcpressure(s: usize) void {
    vm_state.current().gc.next_collection +%= s;
}

/// Allocate a block the collector owns and prepend it to the appropriate heap
/// list. The block is *not* initialised beyond its type tag, and it is
/// reachable by the collector from this moment, so every caller fills it in
/// before anything can collect.
///
/// This is the byte-counted form, and only three kinds of caller want it: the
/// two typed wrappers below, and a contract whose subject is the list itself.
/// Everything else names the type it is allocating and lets `gcalloc` answer
/// a pointer to it.
pub fn gcallocBytes(mtype: MemoryType, size: usize) *abi.GCObject {
    const v = vm_state.current();
    const g = &v.gc;

    // The symbol cache, read as a liveness probe rather than as cache work:
    // VM start-up allocates it first, so a null table means nothing has been
    // initialised. It is the one place this file names an aggregate that is
    // not the collector's, and naming `g` beside it is what makes that visible.
    if (v.symcache.entries == null) fatal.fatal("please initialize janet before use");

    const mem: *abi.GCObject = @ptrCast(@alignCast(utils.rawAlloc(size)));

    mem.flags = .{ .type = @intFromEnum(mtype) };

    g.next_collection +%= size;
    if (@intFromEnum(mtype) < @intFromEnum(first_weak_type)) {
        mem.data.next = g.blocks;
        g.blocks = mem;
    } else {
        mem.data.next = g.weak_blocks;
        g.weak_blocks = mem;
    }
    g.block_count +%= 1;

    return mem;
}

/// **Every collectable type puts its `GCObject` first**, and this is what
/// says so.
///
/// `gcallocBytes` writes the memory type through a `*GCObject` at the
/// start of the block and the sweep recovers the header the same way, so the
/// cast back to `*T` is only sound while the header is at offset zero. The heap
/// types are ordinary auto-layout structs -- `extern` is kept only where a
/// layout is a stated obligation -- so Zig is free to reorder their fields, and
/// nothing but this would notice. A reorder is a build error here instead of
/// heap corruption at the first collection.
///
/// `gc/mark.zig` needs no such assertion: it reaches the header with `&mem.gc`,
/// which is true at any offset. The allocator and the sweep cannot, because
/// each holds a block before it has a type.
fn assertHeaderFirst(comptime T: type) void {
    comptime {
        if (!@hasField(T, "gc"))
            @compileError(@typeName(T) ++ " is not collectable: it has no `gc` field");
        if (@offsetOf(T, "gc") != 0)
            @compileError(@typeName(T) ++ " puts its `gc` header at offset " ++
                std.fmt.comptimePrint("{d}", .{@offsetOf(T, "gc")}) ++
                " rather than 0, which the allocator and the sweep both assume");
    }
}

/// Allocate a collectable block that is exactly a `T`, and answer it as one.
/// Out of memory is fatal inside `rawAlloc`, so the twenty-two callers of this
/// do not each write an `orelse`.
pub inline fn gcalloc(comptime T: type, mtype: MemoryType) *T {
    comptime assertHeaderFirst(T);
    return @ptrCast(@alignCast(gcallocBytes(mtype, @sizeOf(T))));
}

/// Where a head's payload begins: the offset of its one zero-length member.
///
/// `DESIGN.md` section 3 records why this is an offset and not a `@sizeOf` --
/// the compiler reports where it put the payload rather than where it ought to
/// go -- and why the zero-length field is kept in order to be able to ask.
/// Finding the field rather than naming it is what makes the five heads one
/// case: `functions.Function` spells it `_envs` and the other four spell it
/// `_data`, and a head that grew a second flexible member, or lost the one it
/// has, would be a compile error here rather than a wrong size.
fn payloadOffset(comptime Head: type) usize {
    comptime {
        var found: ?usize = null;
        for (@typeInfo(Head).@"struct".fields) |f| {
            const info = @typeInfo(f.type);
            if (info != .array or info.array.len != 0) continue;
            if (found != null) @compileError(@typeName(Head) ++ " has more than one flexible member");
            found = @offsetOf(Head, f.name);
        }
        return found orelse @compileError(@typeName(Head) ++ " has no flexible member");
    }
}

/// Allocate a head whose payload sits on the same allocation -- a string, a
/// symbol, a tuple, a struct, an abstract, a closure's environment array --
/// and answer the head.
///
/// **The addition is checked, and it is checked here because one caller's size
/// is not this runtime's.** Nine of the ten arrive with a size a narrower type
/// has already bounded -- a `[]const u8` length, an `i32` count, a `len > 255`
/// guard, a literal zero. The tenth is `value/abstracts.zig`'s `beginBytes`,
/// whose size is the caller's own `usize` and which `capi.zig` publishes as
/// `janet_abstract`. A size within `offset` of `usize` max would sum to
/// something small, `rawAlloc` would serve it -- it fails on a size it cannot
/// serve, not on one that has already wrapped -- and the module would write its
/// payload past the block. `std.math.add` makes the answer the fatal
/// out-of-memory this tree already gives a size it cannot serve.
pub inline fn gcallocWithPayload(
    comptime Head: type,
    mtype: MemoryType,
    payload_bytes: usize,
) *Head {
    comptime assertHeaderFirst(Head);
    const offset = comptime payloadOffset(Head);
    const total = std.math.add(usize, offset, payload_bytes) catch fatal.outOfMemory();
    return @ptrCast(@alignCast(gcallocBytes(mtype, total)));
}

// ------------------------------------------------------------- lifecycle
//
// **The three aggregates `Vm` gives this file are constructed and destroyed
// here, not in `vm/lifecycle.zig`.** Setting thirteen fields by name at init
// and clearing three of them at deinit is a list, and a list is a place to
// leave a member out of -- which is how a traversal stack and a cfunction
// registry come to be freed with their counts and capacities still set. A
// type whose starting state is one statement has no such list.

/// Bytes allocated before the first collection: Janet's figure, and the only
/// field of a fresh collector that is not a zero.
pub const default_interval: usize = 0x400000;

/// The collector's starting state.
///
/// **A fresh collector is unsuspended.** Starting a VM with a suspension still
/// outstanding would leave it never collecting. Nothing in the tree reaches
/// that state -- `signal.zig` restores the depth on an unwind -- and zeroing
/// the field is still what makes the starting state one statement rather than
/// six assignments and an omission.
pub fn collectorInit(g: *Collector) void {
    g.* = .{ .interval = default_interval, .depth = config.recursion_guard };
}

/// The root set starts empty; `gcroot` is what grows it.
pub fn rootsInit(r: *Roots) void {
    r.* = .empty;
}

/// Release the root set and return it to what `rootsInit` starts from.
///
/// **The reset after the free is load-bearing and is not the container's.**
/// `ArrayListUnmanaged.deinit` ends `self.* = undefined`, which is the
/// dangling-pointer-with-a-live-capacity state `scratchDeinit`'s note below
/// describes. The reset is what closes it.
pub fn rootsDeinit(r: *Roots) void {
    r.deinit(utils.heap);
    r.* = .empty;
}

/// The scratch table starts empty.
pub fn scratchInit(s: *ScratchTable) void {
    s.* = .empty;
}

/// Release the scratch table. The blocks themselves are `freeAllScratch`'s,
/// which runs first because this frees the table that names them.
///
/// **The pointer and the capacity go together.** Freeing the storage and
/// leaving the list's pointer dangling with its capacity at the old value lets
/// an `smalloc` before the next VM takes the no-growth path and writes through
/// the freed pointer.
pub fn scratchDeinit(s: *ScratchTable) void {
    freeAllScratch(s);
    s.deinit(utils.heap);
    // See `rootsDeinit`: the container's `deinit` leaves `undefined` behind,
    // and leaving it is the defect this reset exists to prevent.
    s.* = .empty;
}

// -------------------------------------------------------------- root set

/// Add a root. Rooting the same value twice requires unrooting it twice; the
/// root set is a multiset, not a set, which is why this appends unconditionally.
pub fn gcroot(root: repr.Value) void {
    const r = &vm_state.current().roots;
    r.append(utils.heap, root) catch fatal.outOfMemory();
}

/// Identity for root bookkeeping. The three immediate types compare equal to
/// any other value of their type, which costs nothing: the collector never
/// traces them, so which one a root slot holds cannot matter.
fn idequals(lhs: repr.Value, rhs: repr.Value) bool {
    if (repr.typeOf(lhs) != repr.typeOf(rhs)) return false;
    return switch (repr.typeOf(lhs)) {
        repr.Tag.boolean, repr.Tag.nil, repr.Tag.number => true,
        else => wrap.toPointer(lhs) == wrap.toPointer(rhs),
    };
}

/// Drop one rooting of `root`, returning whether one was found. Removal swaps
/// the last root into the vacated slot, so the root set has no order a caller
/// may depend on.
pub fn gcunroot(root: repr.Value) bool {
    const r = &vm_state.current().roots;
    const top = r.items.len;
    // Bottom to top. The set is small and unordered, so the direction is not
    // a performance claim; `gcunrootall` below scans the same way.
    for (0..top) |i| {
        if (idequals(root, r.items[i])) {
            _ = r.swapRemove(i);
            return true;
        }
    }
    return false;
}

/// Drop every rooting of `root`, returning whether there was at least one.
///
/// **The index does not advance on a match.** `swapRemove` fills the vacated
/// slot from the top, so the element now at `i` has not been examined;
/// advancing past it leaves half the rootings behind and still reports
/// success.
pub fn gcunrootall(root: repr.Value) bool {
    const r = &vm_state.current().roots;
    var found = false;
    var i: usize = 0;
    while (i < r.items.len) {
        if (idequals(root, r.items[i])) {
            _ = r.swapRemove(i);
            found = true;
        } else {
            i += 1;
        }
    }
    return found;
}

// ------------------------------------------------------------ suspension

/// Suspend collection, returning the previous nesting depth. The handle is the
/// depth to restore, not a token to match, so unlocking with a stale handle
/// deliberately unwinds every lock taken since it was issued.
pub fn gclock() u32 {
    const g = &vm_state.current().gc;
    const previous = g.suspend_count;
    g.suspend_count = previous +% 1;
    return previous;
}

pub fn gcunlock(handle: u32) void {
    vm_state.current().gc.suspend_count = handle;
}

// --------------------------------------------------------------- scratch

/// The memory a scratch header hands out.
inline fn scratchData(s: *ScratchBlock) *anyopaque {
    return @ptrFromInt(@intFromPtr(s) + header_size);
}

/// The inverse. The subtraction wraps, so a null argument produces a wild
/// pointer rather than trapping here: `sfinalizer` does not test for null, and
/// the fault belongs at its store rather than at this line.
inline fn mem2scratch(mem: ?*anyopaque) *ScratchBlock {
    return @ptrFromInt(@intFromPtr(mem) -% header_size);
}

/// Run a scratch block's finalizer, if it has one, and release it. The
/// finalizer is embedder code; see the note at the head of the file.
fn freeOneScratch(s: *ScratchBlock) void {
    if (s.finalize) |finalize| finalize(scratchData(s));
    utils.free(s);
}

/// Release every scratch block. Called by `gc/mark.zig`'s `collect` at the end
/// of a collection and by `gc/sweep.zig`'s `clearMemory` at shutdown.
///
/// **It frees the blocks named by the table it is given**, and its caller must
/// free that same table's storage: a call that took its blocks from one table
/// and its pointer array from another would free half of each.
pub fn freeAllScratch(table: *ScratchTable) void {
    for (table.items) |block| freeOneScratch(block);
    table.clearRetainingCapacity();
}

/// Allocate scratch memory: freed automatically at the next collection, and
/// optionally before that with `sfree`. The header carries the finalizer
/// and the table of live blocks carries the pointer.
pub fn smalloc(size: usize) *anyopaque {
    const total = std.math.add(usize, header_size, size) catch fatal.outOfMemory();
    const s: *ScratchBlock = @ptrCast(@alignCast(utils.rawAlloc(total)));
    s.finalize = null;

    const table = &vm_state.current().scratch;
    table.append(utils.heap, s) catch fatal.outOfMemory();
    return scratchData(s);
}

pub fn scalloc(nmemb: usize, size: usize) ?*anyopaque {
    if (nmemb != 0 and size > std.math.maxInt(usize) / nmemb) fatal.outOfMemory();
    const n = nmemb *% size;
    const p = smalloc(n);
    @memset(@as([*]u8, @ptrCast(p))[0..n], 0);
    return p;
}

/// Resize a scratch block in place in the table. A pointer that is not a live
/// scratch block is fatal rather than diagnosable: the table is the only record
/// that a block exists, so a miss means the caller passed something this
/// allocator never handed out.
pub fn srealloc(mem: ?*anyopaque, size: usize) ?*anyopaque {
    if (mem == null) return smalloc(size);
    const s = mem2scratch(mem);
    const table = &vm_state.current().scratch;
    var i = table.items.len;
    while (i > 0) {
        i -= 1;
        if (table.items[i] == s) {
            const total = std.math.add(usize, size, header_size) catch fatal.outOfMemory();
            const news: *ScratchBlock = @ptrCast(@alignCast(utils.realloc(s, total) orelse
                fatal.outOfMemory()));
            table.items[i] = news;
            return scratchData(news);
        }
    }
    fatal.fatal("invalid janet_srealloc");
}

/// Install a finalizer to run when the block is released, whether by `sfree`
/// or by the next collection.
pub fn sfinalizer(mem: ?*anyopaque, finalizer: ScratchFinalizer) void {
    mem2scratch(mem).finalize = finalizer;
}

pub fn sfree(mem: ?*anyopaque) void {
    if (mem == null) return;
    const s = mem2scratch(mem);
    const table = &vm_state.current().scratch;
    var i = table.items.len;
    while (i > 0) {
        i -= 1;
        if (table.items[i] == s) {
            _ = table.swapRemove(i);
            freeOneScratch(s);
            return;
        }
    }
    fatal.fatal("invalid janet_sfree");
}

// ----------------------------------------- the scratch heap as an Allocator
//
// `utils.heap` is the same idea over `utils.rawAlloc`, and this is deliberately
// a *second* vtable rather than a parameter on that one. The two allocators
// differ in lifetime, and that is the whole reason both exist: a scratch block
// is released by the next collection whether or not anyone freed it, and a
// `utils.heap` block is not.
//
// **Which one a container uses is a correctness question, not a preference.**
// The growable vectors this exists for belong to the compiler, the marshaller
// and the PEG builder, and every one of those raises between allocating and
// freeing: `compiler.zig`'s `compileLintImpl` reaches `deinitCompiler` only if
// `valueImpl` returns, and a macro that panics is enough to skip it. On the
// scratch heap that is bounded -- the next collection takes it. On
// `utils.heap` it would be a leak per compile error.
//
// `smalloc` and `srealloc` abort rather than answering null, so `alloc` and
// `remap` never fail here; the standard signatures still allow it, and a
// caller written to the interface stays correct either way.

/// What `smalloc` aligns to: the alignment of `ScratchBlock`, which is a
/// `[0]c_longlong` behind a function pointer. Nothing in the tree asks for
/// more; a request that did would be a silent misalignment, so it aborts.
const max_scratch_align: std.mem.Alignment = .fromByteUnits(@alignOf(ScratchBlock));

fn scratchAllocatorAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (@intFromEnum(alignment) > @intFromEnum(max_scratch_align))
        fatal.fatal("allocation alignment exceeds what janet_smalloc guarantees");
    return @ptrCast(@alignCast(smalloc(len)));
}

fn scratchAllocatorResize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    // `srealloc` may move, so an in-place resize can only be promised where
    // the block is not growing.
    return new_len <= memory.len;
}

fn scratchAllocatorRemap(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    return @ptrCast(@alignCast(srealloc(@ptrCast(memory.ptr), new_len)));
}

fn scratchAllocatorFree(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    sfree(@ptrCast(memory.ptr));
}

const scratch_vtable: std.mem.Allocator.VTable = .{
    .alloc = scratchAllocatorAlloc,
    .resize = scratchAllocatorResize,
    .remap = scratchAllocatorRemap,
    .free = scratchAllocatorFree,
};

/// Janet's scratch heap, as the standard interface. Stateless, so `ptr` is
/// `undefined` and must never be read -- but *not* stateless in the way
/// `utils.heap` is: every call reads `vm_state.current().scratch`, so this
/// allocator is only usable once a VM exists, exactly as `smalloc` is.
pub const scratch_heap: std.mem.Allocator = .{ .ptr = undefined, .vtable = &scratch_vtable };
