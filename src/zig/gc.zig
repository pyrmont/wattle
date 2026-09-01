//! The collector's memory: allocating a collectable block onto one of the two
//! heap lists, the root set, the GC suspend counter, and the scratch
//! allocator. Traversal and reclamation are `gc/mark.zig`'s and
//! `gc/sweep.zig`'s; this file is only where a block is born.
//!
//! Nothing here traverses or frees a collectable object. `janet_gcalloc`
//! returns raw memory with only its type tag written, exactly as the C
//! original does — the caller initialises the block and the collector never
//! looks at it until it is reachable. The block lists are touched at one end
//! only: this file prepends, and `gc/sweep.zig`'s `sweep` unlinks.
//!
//! **Nothing here holds anything a skipped cleanup would strand.** One call
//! reaches code this runtime does not own: `freeOneScratch` calls a
//! `ScratchFinalizer` an embedder installed through `janet_sfinalizer`.
//! No in-tree caller installs one, and a finalizer that raises is undefined
//! behaviour, but the frames below must still hold nothing. A raise from a
//! scratch finalizer leaves `scratch_len` unreduced and the block re-finalized
//! on the next collection, which is what Janet does too.
//!
//! Two pieces of the C arithmetic are reproduced rather than repaired, and
//! both are in `FOUND.md`:
//!
//!  - The scratch table grows by `newcap * @sizeOf(ScratchBlock)` where the element
//!    is a `*ScratchBlock`. The header is a function pointer plus a flexible array,
//!    so it is never smaller than a pointer and the table is over-allocated
//!    rather than short — harmless, and preserved.
//!  - `smalloc` and `srealloc` add the header size to the caller's size without
//!    checking for wraparound, so a near-`SIZE_MAX` request allocates a few
//!    bytes and returns a pointer into a block far too small. Wrapping addition
//!    is used below to reproduce it exactly rather than trap.
//!
//! One assumption the C code makes is worth naming because this file relies on
//! it in the same way. `janet_smalloc` returns `s->mem` and `janet_mem2scratch`
//! recovers the header with `((ScratchBlock *)mem) - 1`; those are inverses
//! only if `sizeof(ScratchBlock)` equals `offsetof(ScratchBlock, mem)`, which
//! holds because the header is one pointer followed by a `long long[]`. Zig
//! does the same arithmetic through `header_size` below, so the two
//! implementations hand out and accept the same addresses.

const std = @import("std");
const config = @import("config");
const abi = @import("abi");

/// Which heap type a block is, stored in the low byte of its GC header's
/// flags.
///
/// It lives here rather than in `abi.zig` because nothing an author compiles
/// reads a memory type: it is the collector's vocabulary. It was briefly in
/// the boundary module, carried there by `GCObject`'s two accessors,
/// which is the "shares a file" coupling `DESIGN.md` §14 is against surviving
/// at one-declaration scale. The accessors are free functions below for the
/// same reason.
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
    // Every value, for the reason given beside the signal table above: five of
    // eighteen sampled left thirteen members in which a transposition would
    // compile, and this one is read out of a marshalled image.
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
/// the two calls are already the ones `janet_init` and `janet_deinit` make.
pub const Collector = struct {
    /// The main heap: every block `janet_gcalloc` returns, newest first.
    blocks: ?*abi.GCObject = null,
    /// The weak heap, which `janet_clear_memory` deliberately does not walk.
    weak_blocks: ?*abi.GCObject = null,
    /// Bytes allocated since the last collection, and the threshold that ends
    /// the interval.
    next_collection: usize = 0,
    interval: usize = 0,
    block_count: usize = 0,
    /// Nesting depth, not a flag: `gcSuspend` answers the previous value and
    /// `gcResume` restores it, so a scope may nest inside another.
    suspend_count: u32 = 0,
    /// True for the duration of the mark phase. Nothing in the runtime reads
    /// it; `test/gc_mark.zig` does, to assert that a `gcmark` callback runs
    /// inside the phase rather than beside it.
    mark_phase: bool = false,
    /// The mark phase's recursion guard: the traversal budget `janet_mark`
    /// spends on the way down and restores on the way up, and which
    /// `gc/mark.zig` resets at the head of every collection.
    ///
    /// **`collectorInit` sets it, and the field default deliberately does
    /// not.** As a `threadlocal var` in `gc/mark.zig` this was
    /// `config.recursion_guard` from the moment a thread started; as a field
    /// it cannot be, because the VM storage is `std.mem.zeroes(Vm)` and a
    /// default is not applied to it. Carrying the guard as the default would
    /// only make `Vm{}` disagree with the zeroed storage a fresh thread
    /// actually gets -- which `test/vm_state.zig` compares -- while leaving
    /// the storage itself at zero. So the budget is filled in by
    /// `collectorInit`, which `janet_init` calls on every cycle, and nothing
    /// can mark before that: `janet_gcalloc` refuses to run in an
    /// uninitialised VM.
    depth: u32 = 0,
    /// The number of roots that existed when the current collection began.
    /// Per-collection state, set by `collect` and read by nothing else; a
    /// `threadlocal var` beside `depth` before.
    orig_rootcount: usize = 0,
};

/// The GC root set. The values the collector marks first.
pub const Roots = std.ArrayListUnmanaged(repr.Value);

/// The scratch table: allocations freed together at the next
/// `janet_free_all_scratch` rather than by the collector.
pub const ScratchTable = std.ArrayListUnmanaged(*ScratchBlock);

pub const ScratchFinalizer = ?*const fn (?*anyopaque) callconv(.c) void;

/// `extern` for the same reason the four heads have it, and it is the reason
/// the plan's "four" undercounts: `scratch_data` is `@offsetOf(_mem)` and the
/// allocator sizes the block `@sizeOf(ScratchBlock) + payload`. A `[0]T` in an
/// auto-layout struct is not guaranteed to stay last, and if it moved the
/// payload would be written over a header field.
pub const ScratchBlock = extern struct {
    finalize: ScratchFinalizer = null,
    _mem: [0]c_longlong = std.mem.zeroes([0]c_longlong),
    pub fn mem(_self: anytype) @TypeOf(&_self._mem[0]) {
        return @ptrCast(@alignCast(&_self._mem));
    }
};

/// The first memory type that belongs on the weak heap. Janet compares
/// against the enum constant directly; naming it here keeps the comparison in
/// the enum's own type, so a caller passing a value outside the enumeration
/// lands where C lands rather than tripping a conversion check.
const first_weak_type: MemoryType = MemoryType.table_weakk;

/// The distance from a `ScratchBlock` header to the memory it hands out. See
/// the note at the head of the file about why this is `@sizeOf` and not an
/// offset of the flexible array member.
const header_size = @sizeOf(ScratchBlock);

// ------------------------------------------------------------- collectable

/// Tell the collector that `s` bytes were allocated outside its accounting.
/// Unsigned wraparound is defined in C and reproduced here; the field is a
/// heuristic threshold, and a wrapped value only delays a collection.
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
    // `janet_init` allocates it first, so a null table means nothing has been
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
/// case: `JanetFunction` spells it `_envs` and the other four spell it
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
/// The addition wraps, because the callers computed the same sum with `+%` and
/// one of them (`strings.begin`, through `asSize`) is reproducing C's
/// sign-extended count on purpose: a negative length must reach `janet_malloc`
/// as the enormous size it becomes, not trap on the way.
pub inline fn gcallocWithPayload(
    comptime Head: type,
    mtype: MemoryType,
    payload_bytes: usize,
) *Head {
    comptime assertHeaderFirst(Head);
    const offset = comptime payloadOffset(Head);
    return @ptrCast(@alignCast(gcallocBytes(mtype, offset +% payload_bytes)));
}

// ------------------------------------------------------------- lifecycle
//
// **The three aggregates `Vm` gives this file are constructed and destroyed
// here, not in `vm/lifecycle.zig`.** `janet_init` used to set thirteen of
// these fields by name and `janet_deinit` clear three of them, and the class
// of defect that produces is in `FOUND.md` twice over -- the traversal stack
// and the cfunction registry are both one member left out of an assignment
// list. A type whose starting state is one statement has no list to leave a
// member out of.
//
// The types are declared just above and their lifecycles are here because a
// starting state is one statement rather than an assignment list.

/// Bytes allocated before the first collection. Upstream's `janet_init`
/// figure, and the only field of a fresh collector that is not a zero.
pub const default_interval: usize = 0x400000;

/// The collector's starting state.
///
/// **This zeroes `suspend_count` and `janet_init` did not**, which is the one
/// deliberate deviation in the increment. The state it closes is reaching a
/// `janet_init` with a suspension still outstanding, so the new VM never
/// collects; `signal.zig` restores the depth on an unwind, so nothing in the
/// tree reaches it, and the reason to close it anyway is that stating six
/// fields and skipping the seventh is the shape being removed.
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
/// `ArrayListUnmanaged.deinit` ends `self.* = undefined`, which is exactly the
/// dangling-pointer-with-a-live-capacity state `scratchDeinit`'s note below
/// records against upstream. The reset is what this port does instead.
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
/// The three fields go together, and `FOUND.md` has why: upstream's
/// `janet_clear_memory` frees the table and leaves `scratch_mem` dangling with
/// `scratch_cap` at its old value, so a `janet_smalloc` before the next
/// `janet_init` takes the no-growth path and writes through the freed pointer.
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
    // Bottom to top, as the C original is; its comment says the access
    // pattern is expected to be LIFO, but the scan starts at slot zero.
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
/// It does not, in fact, drop every one. Filling the vacated slot from the top
/// and then advancing skips whatever was moved down, so a root that appears
/// twice can survive with one rooting left. `FOUND.md` records it; this
/// reproduces it. `top` shadows `root_count` the way the C original's `vtop`
/// shadows `roots + root_count` — the two fall together, one per match.
pub fn gcunrootall(root: repr.Value) bool {
    const r = &vm_state.current().roots;
    var top = r.items.len;
    var found = false;
    var i: usize = 0;
    while (i < top) : (i += 1) {
        if (idequals(root, r.items[i])) {
            _ = r.swapRemove(i);
            top -= 1;
            found = true;
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

/// The inverse. Wrapping subtraction so that a null argument produces the same
/// wild pointer the C original computes rather than trapping before it.
inline fn mem2scratch(mem: ?*anyopaque) *ScratchBlock {
    return @ptrFromInt(@intFromPtr(mem) -% header_size);
}

/// Run a scratch block's finalizer, if it has one, and release it. The
/// finalizer is embedder code; see the note at the head of the file.
fn freeOneScratch(s: *ScratchBlock) void {
    if (s.finalize) |finalize| finalize(scratchData(s));
    utils.free(s);
}

/// Release every scratch block. Called by `janet_collect` at the end of a
/// collection and by `janet_clear_memory` at shutdown.
///
/// **It takes the table.** `scratchDeinit` once accepted a `*ScratchTable` and then
/// called this on the *current* VM's, so a call for any other `ScratchTable` would
/// have freed one table's blocks and the other's pointer array. The two are
/// the same object today and the signature said otherwise.
pub fn freeAllScratch(table: *ScratchTable) void {
    for (table.items) |block| freeOneScratch(block);
    table.clearRetainingCapacity();
}

/// Allocate scratch memory: freed automatically at the next collection, and
/// optionally before that with `janet_sfree`. The header carries the finalizer
/// and the table of live blocks carries the pointer.
pub fn smalloc(size: usize) *anyopaque {
    const s: *ScratchBlock = @ptrCast(@alignCast(utils.rawAlloc(header_size +% size)));
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
/// scratch block is fatal rather than diagnosable, as in the C original: the
/// table is the only record that a block exists, and a miss means the caller
/// passed something this allocator never handed out.
pub fn srealloc(mem: ?*anyopaque, size: usize) ?*anyopaque {
    if (mem == null) return smalloc(size);
    const s = mem2scratch(mem);
    const table = &vm_state.current().scratch;
    var i = table.items.len;
    while (i > 0) {
        i -= 1;
        if (table.items[i] == s) {
            const news: *ScratchBlock = @ptrCast(@alignCast(utils.realloc(s, size +% header_size) orelse
                fatal.outOfMemory()));
            table.items[i] = news;
            return scratchData(news);
        }
    }
    fatal.fatal("invalid janet_srealloc");
}

/// Install a finalizer to run when the block is released, whether by
/// `janet_sfree` or by the next collection.
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
// `utils.heap` is the same idea over `janet_malloc`, and this is deliberately
// a *second* vtable rather than a parameter on that one. The two allocators
// differ in lifetime, and that is the whole reason both exist: a scratch block
// is released by `janet_collect` whether or not anyone freed it, and a
// `janet_malloc` block is not.
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

/// What `janet_smalloc` aligns to: the offset of `ScratchBlock._mem`, which is
/// a `[0]c_longlong` behind a function pointer. Nothing in the tree asks for
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
/// allocator is only usable once a VM exists, exactly as `janet_smalloc` is.
pub const scratch_heap: std.mem.Allocator = .{ .ptr = undefined, .vtable = &scratch_vtable };
