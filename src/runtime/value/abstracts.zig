//! Allocating an abstract, and the refcount a threaded abstract lives by.
//!
//! An abstract is a value whose payload and lifetime belong to its
//! `AbstractType`. Construction is two calls: `beginBytes` returns a block for
//! the caller to fill in and `end` publishes it. `newBytes` and `newFor` are
//! the two in one call, for a payload the caller fills in afterwards or not at
//! all. `beginThreaded`, `endThreaded` and `threaded` are the same three for
//! an abstract that outlives the VM that allocated it.
//!
//! ## Two allocators, one head
//!
//! A plain abstract and a threaded abstract share `AbstractHead` and share
//! nothing else. A plain abstract comes from the collector's allocator and its
//! lifetime is the collector's. A threaded abstract comes from
//! `utils.rawAlloc`, is on neither heap list, and lives until its refcount
//! reaches zero, so `beginThreaded` does by hand the three things the
//! collectable allocator would have done: write the type tag, clear the whole
//! `data` union so a sanitizer reads nothing uninitialised, and charge the
//! block against `vm.gc.next_collection`. Both charges wrap on overflow, which
//! delays a collection and does nothing else.
//!
//! ## The atomic counters
//!
//! `atomicInc`, `atomicDec`, `atomicLoad` and `atomicLoadRelaxed` are refcount
//! primitives rather than abstract operations. The threaded refcount is why
//! they are here, and it is not their only caller: `ev.zig`'s `listener_count`
//! and `vm/state.zig`'s `auto_suspend` are counted with them too. The
//! orderings are the contract rather than a local choice, relaxed to increment
//! and acquire-release to decrement, which is what makes the decrement that
//! reaches zero see every write the other owners made.
//!
//! Nothing here raises. `decrefMaybeFree` runs the type's `gc` finalizer and
//! `beginThreaded` puts an abstract key into a table, which may run the type's
//! `hash`; `abi.zig` declares both callbacks `callconv(.c)`, so neither has a
//! way to.

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const gc_alloc = @import("../gc.zig");
const tables = @import("tables.zig");
const utils = @import("../utils.zig");
const vm_state = @import("../vm/state.zig");
const wrap = @import("helpers/wrap.zig");

// ==========================================================================
// Aliased types
// ==========================================================================

/// The payload Janet passes an abstract around as: the address just past the
/// head. It has no type of its own, and the `AbstractType` in the head is what
/// says what is there.
pub const Abstract = *anyopaque;

// ==========================================================================
// Public functions
// ==========================================================================

/// Subtracts one from `x` and returns the result.
///
/// Acquire-release, which is what makes the decrement that reaches zero see
/// every write the other owners made. `@atomicRmw` returns the value from
/// before the operation, so the delta is applied again here.
pub fn atomicDec(x: *volatile abi.AtomicInt) abi.AtomicInt {
    return @atomicRmw(abi.AtomicInt, x, .Add, -1, .acq_rel) -% 1;
}

/// Adds one to `x` and returns the result.
///
/// Relaxed: an increment publishes nothing another thread has to observe in
/// order. `@atomicRmw` returns the value from before the operation, so the
/// delta is applied again here.
pub fn atomicInc(x: *volatile abi.AtomicInt) abi.AtomicInt {
    return @atomicRmw(abi.AtomicInt, x, .Add, 1, .monotonic) +% 1;
}

/// Reads `x` with acquire ordering, for a caller that acts on the result.
/// `ev.zig` reads `listener_count` through this before deciding to sleep.
pub fn atomicLoad(x: *volatile abi.AtomicInt) abi.AtomicInt {
    return @atomicLoad(abi.AtomicInt, x, .acquire);
}

/// Reads `x` with relaxed ordering. `vm.zig` and `ev.zig` poll `auto_suspend`
/// through this, where a stale read costs another turn of the loop and
/// nothing else.
pub fn atomicLoadRelaxed(x: *volatile abi.AtomicInt) abi.AtomicInt {
    return @atomicLoad(abi.AtomicInt, x, .monotonic);
}

/// Allocates an abstract whose payload is not yet initialised.
///
/// `atype` is the type and `size` the payload in bytes. The result is the
/// payload, which the caller fills in before calling `end`.
///
/// The block is on the collector's heap list when this returns, tagged
/// `.none`, and `gc/sweep.zig`'s `deinitBlock` lists `.none` among the tags it
/// does nothing for, so a collection before `end` frees the block without
/// running a finalizer on it and without reading a field of it. An abstract
/// type whose `gc` releases a pointer it has not been given yet is the failure
/// that prevents.
///
/// It is the sweep the tag protects and not the traversal. The mark phase
/// dispatches on the type of the `Value` it is handed rather than on the
/// block's memory tag, so a caller that wraps and roots the block before
/// filling it in gets `gcmark` called on an uninitialised payload. Nothing
/// here prevents that: the contract is that the caller roots the value after
/// `end`. `test/abstract_core.zig` pins both halves.
///
/// The size is a run-time byte count rather than a type because several
/// payloads are sized by their contents: a compiled PEG, a socket address, an
/// unmarshalled abstract. Where the caller has the type, `newFor` takes it and
/// returns a `*T`.
pub fn beginBytes(atype: *const abi.AbstractType, size: usize) *anyopaque {
    const header = gc_alloc.gcallocWithPayload(abi.AbstractHead, .none, size);
    header.size = size;
    header.type = atype;
    return data(header);
}

/// Allocates a threaded abstract, which is on neither heap list.
///
/// `v` is the VM, `atype` the type and `size` the payload in bytes. What keeps
/// the block alive is its refcount, which starts at one, and what lets the
/// collector see it at all is the entry this makes in
/// `v.ev.threaded_abstracts`, the per-collection visit record `gc/mark.zig`
/// writes into and `gc/sweep.zig` reads.
///
/// The VM is a parameter rather than a lookup because this writes two pieces
/// of state with different owners, the collector's byte budget and the event
/// loop's visit record, and naming the thing that has both hides neither.
/// `threaded` is where the current VM is looked up.
pub fn beginThreaded(v: *vm_state.Vm, atype: *const abi.AbstractType, size: usize) *anyopaque {
    const header: *abi.AbstractHead = @ptrCast(@alignCast(utils.rawAlloc(
        abi.abstract_payload +% size,
    )));

    v.gc.next_collection +%= size +% abi.abstract_payload;
    header.gc.flags = .{ .type = @intFromEnum(gc_alloc.MemoryType.threaded_abstract) };
    // Clear the union before storing the refcount into it: the address
    // sanitizers read the whole word, so a partial write is an uninitialised
    // read.
    header.gc.data.next = null;
    header.gc.data.refcount = 1;
    header.size = size;
    header.type = atype;
    const abstract = data(header);
    tables.put(&v.ev.threaded_abstracts, wrap.fromAbstract(abstract), wrap.fromFalse());
    return abstract;
}

/// Returns the payload of a block the allocator has just returned, the inverse
/// of `abi.abstractHead`.
///
/// `hd` is the head. It is `*const` and the result is mutable: the allocator's
/// caller writes through the result, and a comparison or a hash is given a
/// const head.
pub inline fn data(hd: *const abi.AbstractHead) *anyopaque {
    return @ptrFromInt(@intFromPtr(hd) +% abi.abstract_payload);
}

/// Drops a reference to `abst` and returns the count that leaves, without
/// acting on it. The caller decides what a zero means; `decrefMaybeFree` is
/// the version that acts.
pub fn decref(abst: ?*anyopaque) i32 {
    return @truncate(atomicDec(refcount(abst)));
}

/// Drops a reference to `abst`, frees the block if that was the last
/// reference, and returns the count that leaves.
///
/// The finalizer runs on the thread that dropped the last reference, which is
/// not necessarily the thread that allocated the abstract.
pub fn decrefMaybeFree(abst: ?*anyopaque) i32 {
    const result = decref(abst);
    if (result == 0) {
        const head = abi.abstractHead(abst);
        // A finalizer returns `void` and has no way to raise: `abi.zig`
        // declares `AbstractType.gc` as `callconv(.c) void`.
        // `api/abstract_type.zig` has the contract.
        if (head.type.gc) |finalizer| finalizer(data(head), head.size);
        utils.free(head);
    }
    return result;
}

/// Publishes an abstract the caller has finished initialising, by writing the
/// type tag the collector dispatches on, and returns `x`.
///
/// The tag is ored into `flags.type` rather than stored. That byte is `.none`
/// after `beginBytes`, so the or leaves the tag behind; `reachable` and
/// `disabled` are separate fields of `abi.GCFlags` and neither write reaches
/// them.
pub fn end(x: *anyopaque) *anyopaque {
    gcSetType(abi.abstractHead(x), gc_alloc.MemoryType.abstract);
    return x;
}

/// The threaded counterpart of `end`, returning `x`. `beginThreaded` has
/// already written this tag, so this sets bits that are already set.
pub fn endThreaded(x: *anyopaque) *anyopaque {
    gcSetType(abi.abstractHead(x), gc_alloc.MemoryType.threaded_abstract);
    return x;
}

/// Takes a reference to `abst` and returns the count that leaves.
pub fn incref(abst: ?*anyopaque) i32 {
    return @truncate(atomicInc(refcount(abst)));
}

/// `beginBytes` and `end` in one call, for a payload the caller fills in
/// afterwards or not at all.
pub fn newBytes(atype: *const abi.AbstractType, size: usize) *anyopaque {
    return end(beginBytes(atype, size));
}

/// The same as `newBytes`, for a payload that is exactly a `T`.
///
/// A caller of `newBytes` writes `@sizeOf(T)` on the way in and
/// `@ptrCast(@alignCast(...))` on the way out, and the two halves can disagree
/// without anything noticing.
pub inline fn newFor(comptime T: type, atype: *const abi.AbstractType) *T {
    return @ptrCast(@alignCast(newBytes(atype, @sizeOf(T))));
}

/// `beginThreaded` and `endThreaded` in one call, over the current VM.
pub fn threaded(atype: *const abi.AbstractType, size: usize) *anyopaque {
    return endThreaded(beginThreaded(vm_state.current(), atype, size));
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Ors a memory type into the header's flag word.
///
/// `head` is the header and `mtype` the type. The or is over `flags.type`, the
/// type's own byte, rather than over the whole word.
inline fn gcSetType(head: *abi.AbstractHead, mtype: gc_alloc.MemoryType) void {
    head.gc.flags.type |= @intFromEnum(mtype);
}

/// Returns a threaded abstract's refcount field.
///
/// `abst` is the abstract. The field shares a union with the heap-list link a
/// collectable block uses, and a threaded abstract is on no heap list, so the
/// two never contend.
inline fn refcount(abst: ?*anyopaque) *volatile abi.AtomicInt {
    return &abi.abstractHead(abst).gc.data.refcount;
}
