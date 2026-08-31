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
//! `JanetScratchFinalizer` an embedder installed through `janet_sfinalizer`.
//! No in-tree caller installs one, and a finalizer that raises is undefined
//! behaviour, but the frames below must still hold nothing -- so there is no
//! `defer` in this file. A signal from a scratch finalizer leaves
//! `scratch_len` unreduced and the block re-finalized on the next collection,
//! which is what Janet does too.
//!
//! Two pieces of the C arithmetic are reproduced rather than repaired, and
//! both are in `FOUND.md`:
//!
//!  - `janet_smalloc` grows the scratch table by `newcap * sizeof(JanetScratch)`
//!    where the element is a `JanetScratch *`. The header is a function pointer
//!    plus a flexible array, so it is never smaller than a pointer and the
//!    table is over-allocated rather than short — harmless, and preserved so
//!    the two selectors request the same byte counts.
//!  - `janet_smalloc` and `janet_srealloc` add the header size to the caller's
//!    size without checking for wraparound, so a near-`SIZE_MAX` request
//!    allocates a few bytes and returns a pointer into a block far too small.
//!    Wrapping addition is used below to reproduce it exactly rather than trap.
//!
//! One assumption the C code makes is worth naming because this file relies on
//! it in the same way. `janet_smalloc` returns `s->mem` and `janet_mem2scratch`
//! recovers the header with `((JanetScratch *)mem) - 1`; those are inverses
//! only if `sizeof(JanetScratch)` equals `offsetof(JanetScratch, mem)`, which
//! holds because the header is one pointer followed by a `long long[]`. Zig
//! does the same arithmetic through `header_size` below, so the two
//! implementations hand out and accept the same addresses.

const std = @import("std");
const utils = @import("utils.zig");
const fatal = @import("fatal.zig");
const wrap = @import("value/helpers/wrap.zig");
const types = @import("types");
const repr = @import("repr");
const vm_state = @import("vm/lifecycle.zig");

/// The first memory type that belongs on the weak heap. Janet compares
/// against the enum constant directly; naming it here keeps the comparison in
/// the enum's own type, so a caller passing a value outside the enumeration
/// lands where C lands rather than tripping a conversion check.
const first_weak_type: types.MemoryType = types.MemoryType.table_weakk;

/// The distance from a `JanetScratch` header to the memory it hands out. See
/// the note at the head of the file about why this is `@sizeOf` and not an
/// offset of the flexible array member.
const header_size = @sizeOf(types.JanetScratch);

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
pub fn gcalloc(mtype: types.MemoryType, size: usize) ?*anyopaque {
    const v = vm_state.current();
    const g = &v.gc;

    // The symbol cache, read as a liveness probe rather than as cache work:
    // `janet_init` allocates it first, so a null table means nothing has been
    // initialised. It is the one place this file names an aggregate that is
    // not the collector's, and naming `g` beside it is what makes that visible.
    if (v.symcache.entries == null) fatal.fatal("please initialize janet before use");

    const mem: *types.JanetGCObject = @ptrCast(@alignCast(utils.malloc(size) orelse
        fatal.outOfMemory()));

    mem.flags = @intFromEnum(mtype);

    g.next_collection +%= size;
    if (@intFromEnum(mtype) < @intFromEnum(first_weak_type)) {
        mem.data.next = @ptrCast(@alignCast(g.blocks));
        g.blocks = mem;
    } else {
        mem.data.next = @ptrCast(@alignCast(g.weak_blocks));
        g.weak_blocks = mem;
    }
    g.block_count +%= 1;

    return mem;
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
// The types are in `types.zig` and their lifecycles are here because `types`
// is below the subsystems in the module graph: `cabi` imports it and cannot
// reach `utils.free`.

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
pub fn collectorInit(g: *types.Collector) void {
    g.* = .{ .interval = default_interval };
}

/// The root set starts empty; `gcroot` is what grows it.
pub fn rootsInit(r: *types.Roots) void {
    r.* = .{};
}

/// Release the root set and return it to what `rootsInit` starts from.
pub fn rootsDeinit(r: *types.Roots) void {
    utils.free(r.items);
    r.* = .{};
}

/// The scratch table starts empty.
pub fn scratchInit(s: *types.Scratch) void {
    s.* = .{};
}

/// Release the scratch table. The blocks themselves are `freeAllScratch`'s,
/// which runs first because this frees the table that names them.
///
/// The three fields go together, and `FOUND.md` has why: upstream's
/// `janet_clear_memory` frees the table and leaves `scratch_mem` dangling with
/// `scratch_cap` at its old value, so a `janet_smalloc` before the next
/// `janet_init` takes the no-growth path and writes through the freed pointer.
pub fn scratchDeinit(s: *types.Scratch) void {
    freeAllScratch(s);
    utils.free(@ptrCast(s.items));
    s.* = .{};
}

// -------------------------------------------------------------- root set

/// Add a root. Rooting the same value twice requires unrooting it twice; the
/// root set is a multiset, not a set, which is why this appends unconditionally.
pub fn gcroot(root: repr.Value) void {
    const r = &vm_state.current().roots;
    const newcount = r.count +% 1;
    if (newcount > r.capacity) {
        const newcap = 2 *% newcount;
        // The C original stores the result before testing it, so a failed
        // grow leaves `roots` null on the way to exiting. Preserved.
        r.items = @ptrCast(@alignCast(utils.realloc(r.items, @sizeOf(repr.Value) *% newcap)));
        if (r.items == null) fatal.outOfMemory();
        r.capacity = newcap;
    }
    r.appendAssumingCapacity(root);
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
pub fn gcunroot(root: repr.Value) c_int {
    const r = &vm_state.current().roots;
    const top = r.count;
    // Bottom to top, as the C original is; its comment says the access
    // pattern is expected to be LIFO, but the scan starts at slot zero.
    var i: usize = 0;
    while (i < top) : (i += 1) {
        if (idequals(root, r.at(i).*)) {
            r.swapRemove(i);
            return 1;
        }
    }
    return 0;
}

/// Drop every rooting of `root`, returning whether there was at least one.
///
/// It does not, in fact, drop every one. Filling the vacated slot from the top
/// and then advancing skips whatever was moved down, so a root that appears
/// twice can survive with one rooting left. `FOUND.md` records it; this
/// reproduces it. `top` shadows `root_count` the way the C original's `vtop`
/// shadows `roots + root_count` — the two fall together, one per match.
pub fn gcunrootall(root: repr.Value) c_int {
    const r = &vm_state.current().roots;
    var top = r.count;
    var ret: c_int = 0;
    var i: usize = 0;
    while (i < top) : (i += 1) {
        if (idequals(root, r.at(i).*)) {
            r.swapRemove(i);
            top -= 1;
            ret = 1;
        }
    }
    return ret;
}

// ------------------------------------------------------------ suspension

/// Suspend collection, returning the previous nesting depth. The handle is the
/// depth to restore, not a token to match, so unlocking with a stale handle
/// deliberately unwinds every lock taken since it was issued.
pub fn gclock() c_int {
    const g = &vm_state.current().gc;
    const previous = g.suspend_count;
    g.suspend_count = previous +% 1;
    return previous;
}

pub fn gcunlock(handle: c_int) void {
    vm_state.current().gc.suspend_count = handle;
}

// --------------------------------------------------------------- scratch

/// The memory a scratch header hands out.
inline fn scratchData(s: *types.JanetScratch) *anyopaque {
    return @ptrFromInt(@intFromPtr(s) + header_size);
}

/// The inverse. Wrapping subtraction so that a null argument produces the same
/// wild pointer the C original computes rather than trapping before it.
inline fn mem2scratch(mem: ?*anyopaque) *types.JanetScratch {
    return @ptrFromInt(@intFromPtr(mem) -% header_size);
}

/// Run a scratch block's finalizer, if it has one, and release it. The
/// finalizer is embedder code; see the jump-transparency note at the head of
/// the file.
fn freeOneScratch(s: *types.JanetScratch) void {
    if (s.finalize) |finalize| finalize(scratchData(s));
    utils.free(s);
}

/// Release every scratch block. Called by `janet_collect` at the end of a
/// collection and by `janet_clear_memory` at shutdown.
///
/// **It takes the table.** `scratchDeinit` once accepted a `*Scratch` and then
/// called this on the *current* VM's, so a call for any other `Scratch` would
/// have freed one table's blocks and the other's pointer array. The two are
/// the same object today and the signature said otherwise.
pub fn freeAllScratch(table: *types.Scratch) void {
    for (table.slice()) |block| freeOneScratch(block);
    table.count = 0;
}

/// Allocate scratch memory: freed automatically at the next collection, and
/// optionally before that with `janet_sfree`. The header carries the finalizer
/// and the table of live blocks carries the pointer.
pub fn smalloc(size: usize) ?*anyopaque {
    const s: *types.JanetScratch = @ptrCast(@alignCast(utils.malloc(header_size +% size) orelse
        fatal.outOfMemory()));
    s.finalize = null;

    const table = &vm_state.current().scratch;
    if (table.count == table.capacity) {
        const newcap = 2 *% table.capacity +% 2;
        // `header_size` rather than the pointer size, reproducing the C
        // original's element size. See the note at the head of the file.
        // The cast is only Zig's: a `JanetScratch **` is a double pointer,
        // which does not coerce to `void *` on its own.
        const newmem = utils.realloc(@ptrCast(table.items), newcap *% header_size) orelse
            fatal.outOfMemory();
        table.capacity = newcap;
        table.items = @ptrCast(@alignCast(newmem));
    }

    table.appendAssumingCapacity(s);
    return scratchData(s);
}

pub fn scalloc(nmemb: usize, size: usize) ?*anyopaque {
    if (nmemb != 0 and size > std.math.maxInt(usize) / nmemb) fatal.outOfMemory();
    const n = nmemb *% size;
    const p = smalloc(n).?;
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
    var i = table.count;
    while (i > 0) {
        i -= 1;
        if (table.at(i).* == s) {
            const news: *types.JanetScratch = @ptrCast(@alignCast(utils.realloc(s, size +% header_size) orelse
                fatal.outOfMemory()));
            table.at(i).* = news;
            return scratchData(news);
        }
    }
    fatal.fatal("invalid janet_srealloc");
}

/// Install a finalizer to run when the block is released, whether by
/// `janet_sfree` or by the next collection.
pub fn sfinalizer(mem: ?*anyopaque, finalizer: types.JanetScratchFinalizer) void {
    mem2scratch(mem).finalize = finalizer;
}

pub fn sfree(mem: ?*anyopaque) void {
    if (mem == null) return;
    const s = mem2scratch(mem);
    const table = &vm_state.current().scratch;
    var i = table.count;
    while (i > 0) {
        i -= 1;
        if (table.at(i).* == s) {
            table.swapRemove(i);
            freeOneScratch(s);
            return;
        }
    }
    fatal.fatal("invalid janet_sfree");
}
