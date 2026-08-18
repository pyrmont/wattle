//! jump-transparent
//!
//! The collector's memory: allocating a collectable block onto one of the two
//! heap lists, the root set, the GC suspend counter, and the scratch
//! allocator. This is the first of the three increments `gc.c` is split into;
//! marking and sweeping stay in C until Parts 4 and 5.
//!
//! Nothing here traverses or frees a collectable object. `janet_gcalloc`
//! returns raw memory with only its type tag written, exactly as the C
//! original does — the caller initialises the block and the collector never
//! looks at it until it is reachable. The block lists are touched at one end
//! only: this file prepends, and `janet_sweep` in `gc.c` unlinks.
//!
//! **The file is jump-transparent**, under the rule SPIKE-8 settled. One call
//! here reaches code this runtime does not own: `freeOneScratch` calls a
//! `JanetScratchFinalizer` an embedder installed through `janet_sfinalizer`.
//! No in-tree caller installs one, and a finalizer that raises is undefined
//! behaviour, but the frames below must still hold nothing that a skipped
//! cleanup would strand — so there is no `defer` in this file and `build.zig`
//! checks that there is not. A signal from a scratch finalizer leaves
//! `scratch_len` unreduced and the block re-finalized on the next collection,
//! which is what the C original does too; the port does not diverge there.
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
const abi = @import("abi");
const c = abi.c;

/// `janet_vm` as `src/core/state.h` declares it, resolved through `abi.zig`.
inline fn vm() *c.JanetVM {
    return &c.janet_vm;
}

/// The first memory type that belongs on the weak heap. `gc.c` compares
/// against the enum constant directly; naming it here keeps the comparison in
/// the enum's own type, so a caller passing a value outside the enumeration
/// lands where C lands rather than tripping a conversion check.
const first_weak_type: c.enum_JanetMemoryType = c.JANET_MEMORY_TABLE_WEAKK;

/// The distance from a `JanetScratch` header to the memory it hands out. See
/// the note at the head of the file about why this is `@sizeOf` and not an
/// offset of the flexible array member.
const header_size = @sizeOf(c.JanetScratch);

// ------------------------------------------------------------- collectable

/// Tell the collector that `s` bytes were allocated outside its accounting.
/// Unsigned wraparound is defined in C and reproduced here; the field is a
/// heuristic threshold, and a wrapped value only delays a collection.
export fn janet_gcpressure(s: usize) callconv(.c) void {
    vm().next_collection +%= s;
}

/// Allocate a block the collector owns and prepend it to the appropriate heap
/// list. The block is *not* initialised beyond its type tag, and it is
/// reachable by the collector from this moment, so every caller fills it in
/// before anything can collect.
export fn janet_gcalloc(mtype: c.enum_JanetMemoryType, size: usize) callconv(.c) ?*anyopaque {
    const v = vm();

    if (v.cache == null) c.janet_zig_fatal("please initialize janet before use");

    const mem: *c.JanetGCObject = @ptrCast(@alignCast(c.janet_malloc(size) orelse
        c.janet_zig_out_of_memory()));

    mem.flags = @bitCast(@as(u32, @truncate(mtype)));

    v.next_collection +%= size;
    if (mtype < first_weak_type) {
        mem.data.next = @ptrCast(@alignCast(v.blocks));
        v.blocks = mem;
    } else {
        mem.data.next = @ptrCast(@alignCast(v.weak_blocks));
        v.weak_blocks = mem;
    }
    v.block_count +%= 1;

    return mem;
}

// -------------------------------------------------------------- root set

/// Add a root. Rooting the same value twice requires unrooting it twice; the
/// root set is a multiset, not a set, which is why this appends unconditionally.
export fn janet_gcroot(root: c.Janet) callconv(.c) void {
    const v = vm();
    const newcount = v.root_count +% 1;
    if (newcount > v.root_capacity) {
        const newcap = 2 *% newcount;
        // The C original stores the result before testing it, so a failed
        // grow leaves `roots` null on the way to exiting. Preserved.
        v.roots = @ptrCast(@alignCast(c.janet_realloc(v.roots, @sizeOf(c.Janet) *% newcap)));
        if (v.roots == null) c.janet_zig_out_of_memory();
        v.root_capacity = newcap;
    }
    v.roots[v.root_count] = root;
    v.root_count = newcount;
}

/// Identity for root bookkeeping. The three immediate types compare equal to
/// any other value of their type, which costs nothing: the collector never
/// traces them, so which one a root slot holds cannot matter.
fn idequals(lhs: c.Janet, rhs: c.Janet) bool {
    if (c.janet_type(lhs) != c.janet_type(rhs)) return false;
    return switch (c.janet_type(lhs)) {
        c.JANET_BOOLEAN, c.JANET_NIL, c.JANET_NUMBER => true,
        else => c.janet_unwrap_pointer(lhs) == c.janet_unwrap_pointer(rhs),
    };
}

/// Drop one rooting of `root`, returning whether one was found. Removal swaps
/// the last root into the vacated slot, so the root set has no order a caller
/// may depend on.
export fn janet_gcunroot(root: c.Janet) callconv(.c) c_int {
    const v = vm();
    const top = v.root_count;
    // Bottom to top, as the C original is; its comment says the access
    // pattern is expected to be LIFO, but the scan starts at slot zero.
    var i: usize = 0;
    while (i < top) : (i += 1) {
        if (idequals(root, v.roots[i])) {
            v.root_count -%= 1;
            v.roots[i] = v.roots[v.root_count];
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
export fn janet_gcunrootall(root: c.Janet) callconv(.c) c_int {
    const v = vm();
    var top = v.root_count;
    var ret: c_int = 0;
    var i: usize = 0;
    while (i < top) : (i += 1) {
        if (idequals(root, v.roots[i])) {
            v.root_count -%= 1;
            v.roots[i] = v.roots[v.root_count];
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
export fn janet_gclock() callconv(.c) c_int {
    const v = vm();
    const previous = v.gc_suspend;
    v.gc_suspend = previous +% 1;
    return previous;
}

export fn janet_gcunlock(handle: c_int) callconv(.c) void {
    vm().gc_suspend = handle;
}

// --------------------------------------------------------------- scratch

/// The memory a scratch header hands out.
inline fn scratchData(s: *c.JanetScratch) *anyopaque {
    return @ptrFromInt(@intFromPtr(s) + header_size);
}

/// The inverse. Wrapping subtraction so that a null argument produces the same
/// wild pointer the C original computes rather than trapping before it.
inline fn mem2scratch(mem: ?*anyopaque) *c.JanetScratch {
    return @ptrFromInt(@intFromPtr(mem) -% header_size);
}

/// Run a scratch block's finalizer, if it has one, and release it. The
/// finalizer is embedder code; see the jump-transparency note at the head of
/// the file.
fn freeOneScratch(s: *c.JanetScratch) void {
    if (s.finalize) |finalize| finalize(scratchData(s));
    c.janet_free(s);
}

/// Release every scratch block. Called by `janet_collect` at the end of a
/// collection and by `janet_clear_memory` at shutdown, both still in `gc.c`;
/// declared in `gc.h` so that this file can provide it for them.
export fn janet_free_all_scratch() callconv(.c) void {
    const v = vm();
    var i: usize = 0;
    while (i < v.scratch_len) : (i += 1) freeOneScratch(v.scratch_mem[i]);
    v.scratch_len = 0;
}

/// Allocate scratch memory: freed automatically at the next collection, and
/// optionally before that with `janet_sfree`. The header carries the finalizer
/// and the table of live blocks carries the pointer.
export fn janet_smalloc(size: usize) callconv(.c) ?*anyopaque {
    const s: *c.JanetScratch = @ptrCast(@alignCast(c.janet_malloc(header_size +% size) orelse
        c.janet_zig_out_of_memory()));
    s.finalize = null;

    const v = vm();
    if (v.scratch_len == v.scratch_cap) {
        const newcap = 2 *% v.scratch_cap +% 2;
        // `header_size` rather than the pointer size, reproducing the C
        // original's element size. See the note at the head of the file.
        // The cast is only Zig's: a `JanetScratch **` is a double pointer,
        // which does not coerce to `void *` on its own.
        const newmem = c.janet_realloc(@ptrCast(v.scratch_mem), newcap *% header_size) orelse
            c.janet_zig_out_of_memory();
        v.scratch_cap = newcap;
        v.scratch_mem = @ptrCast(@alignCast(newmem));
    }

    v.scratch_mem[v.scratch_len] = s;
    v.scratch_len +%= 1;
    return scratchData(s);
}

export fn janet_scalloc(nmemb: usize, size: usize) callconv(.c) ?*anyopaque {
    if (nmemb != 0 and size > std.math.maxInt(usize) / nmemb) c.janet_zig_out_of_memory();
    const n = nmemb *% size;
    const p = janet_smalloc(n).?;
    @memset(@as([*]u8, @ptrCast(p))[0..n], 0);
    return p;
}

/// Resize a scratch block in place in the table. A pointer that is not a live
/// scratch block is fatal rather than diagnosable, as in the C original: the
/// table is the only record that a block exists, and a miss means the caller
/// passed something this allocator never handed out.
export fn janet_srealloc(mem: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    if (mem == null) return janet_smalloc(size);
    const s = mem2scratch(mem);
    const v = vm();
    var i = v.scratch_len;
    while (i > 0) {
        i -= 1;
        if (v.scratch_mem[i] == s) {
            const news: *c.JanetScratch = @ptrCast(@alignCast(c.janet_realloc(s, size +% header_size) orelse
                c.janet_zig_out_of_memory()));
            v.scratch_mem[i] = news;
            return scratchData(news);
        }
    }
    c.janet_zig_fatal("invalid janet_srealloc");
}

/// Install a finalizer to run when the block is released, whether by
/// `janet_sfree` or by the next collection.
export fn janet_sfinalizer(mem: ?*anyopaque, finalizer: c.JanetScratchFinalizer) callconv(.c) void {
    mem2scratch(mem).finalize = finalizer;
}

export fn janet_sfree(mem: ?*anyopaque) callconv(.c) void {
    if (mem == null) return;
    const s = mem2scratch(mem);
    const v = vm();
    var i = v.scratch_len;
    while (i > 0) {
        i -= 1;
        if (v.scratch_mem[i] == s) {
            v.scratch_len -%= 1;
            v.scratch_mem[i] = v.scratch_mem[v.scratch_len];
            freeOneScratch(s);
            return;
        }
    }
    c.janet_zig_fatal("invalid janet_sfree");
}
