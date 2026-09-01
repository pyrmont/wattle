//! Behavioral contract for the collector's sweep: dropping dead weak
//! references, unlinking and freeing unreachable blocks, running finalizers,
//! and tearing the heap down at `janet_deinit`.
//!
//! The sweep is driven through `janet_collect` rather than by calling
//! `janet_sweep` directly, and that is not a convenience. `janet_sweep` frees
//! every block the mark phase did not reach, so calling it against a hand-made
//! mark set would free the core environment along with everything else.
//! Driving it through a collection means liveness is expressed the way the
//! runtime expresses it — a value is alive because it is rooted — and the mark
//! phase is an input to this contract rather than part of it.
//!
//! Freeing is mostly invisible: a freed block cannot be read, and a
//! `janet_free` that does not happen leaves nothing to observe from inside the
//! process. So three channels stand in for it. `vm.gc.block_count` is
//! decremented exactly once per block freed. An abstract type's `gc` and
//! `gcperthread` callbacks fire on the way out and can count themselves. And
//! `vm.symcache.count` falls when a symbol block leaves the symbol cache,
//! which is the only external obligation any immutable block has.
//!
//! What that leaves uncovered is honest to state: the frees inside
//! `janet_deinit_block` for an array's, a table's, a fiber's or a funcdef's
//! payload are leaks when omitted and double frees when duplicated, and
//! neither is observable here. A leak checker sees the first; the second is
//! what the repeated init/deinit cycle at the end of this file would catch.
//!
//! Nothing here exercises a raising finalizer. The hinge typed `gc`
//! non-raising, so the case can no longer be written — see `test/gc_mark.zig`,
//! which says the same thing about `gcmark`.
//!
//! ## The head-offset check is not repeated here
//!
//! a C predecessor of this file carried its own copy of the four
//! `sizeof(Head) == offsetof(Head, data)` assertions, because each C contract
//! was a standalone translation unit and the sweep crosses those headers in
//! both directions. **`test/gc_mark.zig` now holds the one oracle**, and it is
//! a different one: the C spelling cannot be translated at all, so what
//! replaced it derives the offset from the allocator at run time. Copying that
//! machinery into a second file would test the same property twice and give
//! two places to keep correct. The property belongs to the layout rather than
//! to either subsystem.

const std = @import("std");
const repr = @import("repr");
const constants = @import("constants");
const options = @import("options");
const value = @import("subsystems").value;
const harness = @import("harness.zig");
const abstract_type = @import("subsystems").abstract_type;
const tables = @import("subsystems").value.tables;
const gc_alloc = @import("subsystems").gc_alloc;
const arrays = @import("subsystems").value.arrays;
const buffers = @import("subsystems").value.buffers;
const gc_mark = @import("subsystems").gc_mark;
const core_env = @import("subsystems").env;
const wrap = @import("subsystems").value.wrap;
const abstracts = @import("subsystems").value.abstracts;
const vm_lifecycle = @import("subsystems").lifecycle;
const fibers = @import("subsystems").value.fibers;
const abi = @import("abi");
const expect = @import("expect.zig").expect;

/// `vm.ev.threaded_abstracts` and `janet_abstract_threaded` exist only
/// where the event loop does, and this has to be comptime so that the branch
/// naming them is not analysed elsewhere.
///
/// `options` is the build's `Selection`, which names **subsystems** rather
/// than features, so there is no `options.ev` to read.
/// `ev_core` is set to `hasEv(options)` by `build.zig` and is therefore the
/// same condition spelled in the vocabulary this module has.
const has_ev = options.ev;

fn headerOf(pointer: ?*anyopaque) *abi.GCObject {
    return @ptrCast(@alignCast(pointer.?));
}

fn reachable(pointer: ?*anyopaque) bool {
    return harness.gcBits(headerOf(pointer).flags) & constants.JANET_MEM_REACHABLE != 0;
}

/// Whether a block is still on one of the two heap lists. Only ever called for
/// a block that is known to have survived, so nothing freed is dereferenced.
fn onList(list: ?*anyopaque, block: ?*anyopaque) bool {
    var current = list;
    while (current != null) {
        if (current == block) return true;
        current = @ptrCast(headerOf(current).data.next);
    }
    return false;
}

/// Start from a heap with nothing collectable left over from an earlier case,
/// so that a block count taken here means what the next case assumes.
fn settle() void {
    gc_mark.collect();
}

// ------------------------------------------------------------ probe types

var gc_calls: i32 = 0;
var gc_data: ?*anyopaque = null;
var gc_size: usize = 0;

fn probeGc(data: *anyopaque, length: usize) void {
    gc_calls += 1;
    gc_data = data;
    gc_size = length;
}

var order_log: [8]u8 = undefined;
var order_len: usize = 0;

fn logOrder(character: u8) void {
    if (order_len < order_log.len) {
        order_log[order_len] = character;
        order_len += 1;
    }
}

fn probeGcOrdered(_: *anyopaque, _: usize) void {
    logOrder('G');
}

fn probePerthreadOrdered(_: *anyopaque, _: usize) void {
    logOrder('P');
}

const at_final = abstract_type.define(anyopaque, .{ .name = "gc-sweep-test/final", .gc = probeGc });
const at_ordered = abstract_type.define(anyopaque, .{
    .name = "gc-sweep-test/ordered",
    .gc = probeGcOrdered,
    .gcperthread = probePerthreadOrdered,
});
const at_plain = abstract_type.define(anyopaque, .{ .name = "gc-sweep-test/plain" });

fn plain() *const abi.AbstractType {
    return &at_plain;
}

fn final() *const abi.AbstractType {
    return &at_final;
}

// --------------------------------------------------------- freeing blocks

/// The block count is the sweep's arithmetic made visible: one decrement per
/// block freed, and no decrement for a block kept.
fn unreachableBlocksAreFreed() void {
    settle();
    const before = harness.vm().gc.block_count;

    for (0..16) |_| _ = buffers.new(8);
    expect(harness.vm().gc.block_count == before + 16);

    gc_mark.collect();
    expect(harness.vm().gc.block_count == before);
}

/// A survivor stays on its list, keeps its payload, and loses its mark. The
/// last part is what makes the next collection meaningful: `REACHABLE` is
/// cleared on the way past, so every mark phase starts from a clean heap.
fn aSurvivorKeepsItsPayloadAndLosesItsMark() void {
    settle();
    const before = harness.vm().gc.block_count;

    const buffer = buffers.new(8);
    _ = buffers.pushCstringAbi(buffer, "still here");
    const val = wrap.fromBuffer(buffer);
    gc_alloc.gcroot(val);

    gc_mark.collect();
    expect(harness.vm().gc.block_count == before + 1);
    expect(onList(harness.vm().gc.blocks, buffer));
    expect(!reachable(buffer));
    expect(buffer.count == 10);
    expect(std.mem.eql(u8, buffer.slice()[0..10], "still here"));

    _ = gc_alloc.gcunroot(val);
    gc_mark.collect();
    expect(harness.vm().gc.block_count == before);
}

/// `JANET_MEM_DISABLED` holds a block through a sweep that never reached it,
/// and unlike `JANET_MEM_REACHABLE` it is not cleared on the way past — it
/// holds the block through every later sweep too, until whoever set it clears
/// it. `janet_buffer_init` sets it on a caller-owned buffer for exactly that
/// reason; here it is set by hand on a heap block, which is the general case
/// the flag is defined for.
fn theDisabledFlagOutlivesASweep() void {
    settle();
    const before = harness.vm().gc.block_count;

    const buffer = buffers.new(8);
    harness.gcSetBits(&buffer.gc.flags, constants.JANET_MEM_DISABLED);

    gc_mark.collect();
    expect(harness.vm().gc.block_count == before + 1);
    expect(onList(harness.vm().gc.blocks, buffer));
    expect(harness.gcBits(buffer.gc.flags) & constants.JANET_MEM_DISABLED != 0);
    expect(!reachable(buffer));

    gc_mark.collect();
    expect(harness.vm().gc.block_count == before + 1);

    buffer.gc.flags = @bitCast(harness.gcBits(buffer.gc.flags) & ~@as(u32, constants.JANET_MEM_DISABLED));
    gc_mark.collect();
    expect(harness.vm().gc.block_count == before);
}

// ------------------------------------------------------------ finalization

/// A finalizer runs once, on the way out, with the pointer and size the
/// runtime handed the type — not the block address, and not the header size.
fn aFinalizerRunsOnceWithTheAbstract() void {
    settle();
    const abstract = abstracts.newBytes(final(), 24);
    gc_calls = 0;
    gc_data = null;
    gc_size = 0;

    gc_mark.collect();
    expect(gc_calls == 1);
    expect(gc_data == abstract);
    expect(gc_size == 24);

    gc_mark.collect();
    expect(gc_calls == 1);
}

/// A block that survives is not finalized. The pair matters more than either
/// half: it is the only place the contract says the callback is driven by
/// reachability rather than by the sweep visiting the block.
fn aSurvivorIsNotFinalized() void {
    settle();
    const abstract = abstracts.newBytes(final(), 8);
    const val = wrap.fromAbstract(abstract);
    gc_alloc.gcroot(val);
    gc_calls = 0;

    gc_mark.collect();
    expect(gc_calls == 0);

    _ = gc_alloc.gcunroot(val);
    gc_mark.collect();
    expect(gc_calls == 1);
}

/// Both finalizers run, and `gcperthread` runs first. The order is not
/// incidental: the per-thread callback releases what belongs to this
/// interpreter, and the type's `gc` releases what the value owns outright, so
/// reversing them would let `gc` free memory `gcperthread` still reads.
fn perthreadRunsBeforeGc() void {
    settle();
    _ = abstracts.newBytes(&at_ordered, 8);
    order_len = 0;

    gc_mark.collect();
    expect(order_len == 2);
    expect(order_log[0] == 'P');
    expect(order_log[1] == 'G');
}

/// An abstract with no callbacks at all is freed without incident. The sweep
/// tests each slot before calling it, and a type may fill neither.
fn anAbstractWithoutFinalizers() void {
    settle();
    const before = harness.vm().gc.block_count;
    _ = abstracts.newBytes(plain(), 8);
    expect(harness.vm().gc.block_count == before + 1);
    gc_mark.collect();
    expect(harness.vm().gc.block_count == before);
}

/// A symbol is the one immutable block with an obligation outside its own
/// allocation: it has to leave the symbol cache, or the cache keeps a pointer
/// into freed memory and the next symbol with those bytes is handed it. The
/// cache counters are the observation.
fn aSymbolLeavesTheCache() void {
    settle();
    const count = harness.vm().symcache.count;
    const deleted = harness.vm().symcache.deleted;

    _ = value.fromBytes("gc-sweep-test-unique-symbol", .symbol);
    expect(harness.vm().symcache.count == count + 1);

    gc_mark.collect();
    expect(harness.vm().symcache.count == count);
    expect(harness.vm().symcache.deleted == deleted + 1);
}

// -------------------------------------------------------------- weak heap

/// A weak array keeps its shape and loses its dead elements. The count does
/// not change and the live entries do not move: a dead slot becomes nil in
/// place, which is what lets an index into a weak array stay meaningful across
/// a collection. Immediates have no header to consult and are always live.
fn aWeakArrayDropsDeadElementsInPlace() void {
    settle();
    const weak = arrays.weak(4);
    gc_alloc.gcroot(wrap.fromArray(weak));

    const live = buffers.new(8);
    gc_alloc.gcroot(wrap.fromBuffer(live));
    const dead = buffers.new(8);

    harness.arrayPush(weak, wrap.fromBuffer(live));
    harness.arrayPush(weak, wrap.fromBuffer(dead));
    harness.arrayPush(weak, harness.wrapInteger(42));

    gc_mark.collect();

    expect(weak.count == 3);
    expect(wrap.toBuffer(weak.slice()[0]) == live);
    expect(harness.isType(weak.slice()[1], repr.Tag.nil));
    expect(harness.integerIs(weak.slice()[2], 42));

    _ = gc_alloc.gcunroot(wrap.fromBuffer(live));
    _ = gc_alloc.gcunroot(wrap.fromArray(weak));
}

/// Which half of an entry is checked is what makes a table weak, and it
/// mirrors the mark phase exactly: whichever half the walk did not mark is the
/// half that may have died. A weak-keyed table therefore keeps an entry whose
/// value is otherwise unreferenced — the walk marked that value — and drops
/// one whose key is. A dropped entry becomes the (nil, false) tombstone
/// `janet_table_put` writes, so the count falls and the deleted count rises.
fn theFourTableKinds() void {
    settle();

    const weakk = tables.weakk(4);
    const weakv = tables.weakv(4);
    const weakkv = tables.weakkv(4);
    const strong = tables.new(4);
    gc_alloc.gcroot(wrap.fromTable(weakk));
    gc_alloc.gcroot(wrap.fromTable(weakv));
    gc_alloc.gcroot(wrap.fromTable(weakkv));
    gc_alloc.gcroot(wrap.fromTable(strong));

    const live = buffers.new(8);
    gc_alloc.gcroot(wrap.fromBuffer(live));
    const live_value = wrap.fromBuffer(live);

    // One entry per table with a doomed key, one with a doomed value.
    for ([_]*tables.Table{ weakk, weakv, weakkv, strong }) |table| {
        tables.put(table, wrap.fromBuffer(buffers.new(8)), live_value);
        tables.put(table, live_value, wrap.fromBuffer(buffers.new(8)));
    }

    expect(weakk.count == 2 and weakv.count == 2 and weakkv.count == 2);
    const deleted = weakk.deleted;

    gc_mark.collect();

    // Weak keys: the doomed-key entry goes, the doomed-value one stays because
    // a weak-keyed table's values are marked.
    expect(weakk.count == 1);
    expect(weakk.deleted == deleted + 1);
    expect(!harness.isType(tables.get(weakk, live_value), repr.Tag.nil));

    // Weak values: the mirror image.
    expect(weakv.count == 1);
    expect(harness.isType(tables.get(weakv, live_value), repr.Tag.nil));

    // Weak in both halves: neither entry survives.
    expect(weakkv.count == 0);

    // A strong table marks both halves, so nothing in it can die.
    expect(strong.count == 2);
    expect(!harness.isType(tables.get(strong, live_value), repr.Tag.nil));

    _ = gc_alloc.gcunroot(wrap.fromBuffer(live));
    _ = gc_alloc.gcunroot(wrap.fromTable(weakk));
    _ = gc_alloc.gcunroot(wrap.fromTable(weakv));
    _ = gc_alloc.gcunroot(wrap.fromTable(weakkv));
    _ = gc_alloc.gcunroot(wrap.fromTable(strong));
}

/// The weak heap is swept for blocks as well as for references. A weak
/// container nothing refers to is freed like any other block — it is on a
/// separate list, not exempt from collection.
fn weakContainersAreThemselvesCollected() void {
    settle();
    const before = harness.vm().gc.block_count;

    _ = arrays.weak(4);
    _ = tables.weakk(4);
    _ = tables.weakv(4);
    _ = tables.weakkv(4);
    expect(harness.vm().gc.block_count == before + 4);

    gc_mark.collect();
    expect(harness.vm().gc.block_count == before);
}

/// A weak reference to a block that is itself dying is dropped, not read after
/// it is freed. That is the whole reason the weak heap is walked twice: the
/// first pass consults the mark of every value a surviving weak container
/// holds, and the second frees. Reversing them would make this case a
/// use-after-free rather than a wrong answer, so what is asserted here is only
/// that the survivor is intact and empty; a sanitizer is what sees the
/// difference.
fn aWeakEntryAndItsTargetDieTogether() void {
    settle();
    const before = harness.vm().gc.block_count;

    const weak = tables.weakv(4);
    gc_alloc.gcroot(wrap.fromTable(weak));
    tables.put(weak, value.fromBytes("doomed", .keyword), wrap.fromBuffer(buffers.new(8)));
    expect(weak.count == 1);

    gc_mark.collect();

    expect(weak.count == 0);
    expect(onList(harness.vm().gc.weak_blocks, weak));

    // The table and its key survive this collection; the buffer does not. The
    // key is alive because a weak-valued table marks its keys — the entry was
    // dropped by the sweep, after the walk had already reached the keyword
    // through it. The next collection is where the keyword goes, which is the
    // one collection of lag a weak table costs.
    expect(harness.vm().gc.block_count == before + 2);
    gc_mark.collect();
    expect(harness.vm().gc.block_count == before + 1);

    _ = gc_alloc.gcunroot(wrap.fromTable(weak));
}

// ------------------------------------------------------ threaded abstracts

var threaded_gc_calls: i32 = 0;
var threaded_perthread_calls: i32 = 0;

fn probeThreadedGc(_: *anyopaque, _: usize) void {
    threaded_gc_calls += 1;
}

fn probeThreadedPerthread(_: *anyopaque, _: usize) void {
    threaded_perthread_calls += 1;
}

const at_threaded = abstract_type.define(anyopaque, .{
    .name = "gc-sweep-test/threaded",
    .gc = probeThreadedGc,
    .gcperthread = probeThreadedPerthread,
});

/// A threaded abstract is not on either heap list, so the sweep decides its
/// fate through `vm.ev.threaded_abstracts` instead. The table is a visit
/// record: the mark phase writes true for every threaded abstract it reaches,
/// and the sweep reads the entry and resets it to false for next time. An
/// entry still false is one this interpreter no longer refers to, so this
/// interpreter's reference goes — and because the last reference anywhere is
/// what frees the value, the type's `gc` runs exactly once across every
/// interpreter that ever held it.
fn aThreadedAbstractLosesItsReference() void {
    settle();
    const abstract = abstracts.threaded(&at_threaded, 8);
    const val = wrap.fromAbstract(abstract);
    gc_alloc.gcroot(val);
    threaded_gc_calls = 0;
    threaded_perthread_calls = 0;

    const tracked = harness.vm().ev.threaded_abstracts.count;
    gc_mark.collect();
    expect(threaded_perthread_calls == 0);
    expect(threaded_gc_calls == 0);
    expect(harness.vm().ev.threaded_abstracts.count == tracked);

    _ = gc_alloc.gcunroot(val);
    gc_mark.collect();
    expect(threaded_perthread_calls == 1);
    expect(threaded_gc_calls == 1);
    expect(harness.vm().ev.threaded_abstracts.count == tracked - 1);

    // The entry is a tombstone now, so a later sweep must not find it again.
    gc_mark.collect();
    expect(threaded_perthread_calls == 1);
    expect(threaded_gc_calls == 1);
}

// --------------------------------------------------------------- teardown

/// `janet_clear_memory` is not a collection. Nothing is marked, rooting buys a
/// block nothing, and every finalizer runs — which is what makes
/// `janet_deinit` safe to call with live values outstanding.
///
/// **The last assertion used to pin a defect and now pins the guarantee.**
/// Teardown walked `vm.gc.blocks` and never touched `vm.gc.weak_blocks`, so
/// every weak table and weak array alive at deinit leaked its block and its
/// data array, and the list head still pointing at them afterwards was that
/// leak seen from inside. It is fixed here and `FOUND.md` records the
/// divergence from upstream.
///
/// It was visible from outside too: `tools/testing/leaks.sh` carried
/// `expected_gc_sweep=8` -- the four weak containers this file leaves alive
/// across a teardown, the one here and `repeatedCycles`' three, times the block
/// and the data array each of them leaked. That entry is gone and the script
/// expects zero everywhere.
fn clearMemoryFinalizesEverything() void {
    const abstract = abstracts.newBytes(final(), 8);
    gc_alloc.gcroot(wrap.fromAbstract(abstract));
    _ = abstracts.newBytes(final(), 8);
    gc_calls = 0;

    const weak = tables.weakv(4);
    gc_alloc.gcroot(wrap.fromTable(weak));

    vm_lifecycle.deinit();

    expect(gc_calls == 2);
    expect(harness.vm().gc.blocks == null);
    expect(harness.vm().gc.weak_blocks == null);

    harness.init();
}

/// A second cycle over a heap that has held every block type. Nothing is
/// asserted beyond arriving here: this is the case that fails by crashing, and
/// it is the only coverage there is for the frees inside
fn repeatedCycles() void {
    for (0..3) |_| {
        const table = tables.new(4);
        gc_alloc.gcroot(wrap.fromTable(table));
        tables.put(table, value.fromBytes("array", .keyword), wrap.fromArray(arrays.new(4)));
        tables.put(table, value.fromBytes("buffer", .keyword), wrap.fromBuffer(buffers.new(8)));
        tables.put(table, value.fromBytes("weak", .keyword), wrap.fromArray(arrays.weak(4)));
        tables.put(
            table,
            value.fromBytes("abstract", .keyword),
            wrap.fromAbstract(abstracts.newBytes(plain(), 8)),
        );

        var function: repr.Value = wrap.fromNil();
        _ = core_env.dostring(harness.coreEnv(), "(fn [] 1)", "gc-sweep-test", &function);
        expect(harness.isType(function, repr.Tag.function));
        tables.put(
            table,
            value.fromBytes("fiber", .keyword),
            wrap.fromFiber(fibers.new(wrap.toFunction(function), 8, &.{}) catch unreachable),
        );

        gc_mark.collect();
        vm_lifecycle.deinit();
        harness.init();
    }
}

pub fn run() void {
    harness.init();

    unreachableBlocksAreFreed();
    aSurvivorKeepsItsPayloadAndLosesItsMark();
    theDisabledFlagOutlivesASweep();

    aFinalizerRunsOnceWithTheAbstract();
    aSurvivorIsNotFinalized();
    perthreadRunsBeforeGc();
    anAbstractWithoutFinalizers();
    aSymbolLeavesTheCache();

    aWeakArrayDropsDeadElementsInPlace();
    theFourTableKinds();
    weakContainersAreThemselvesCollected();
    aWeakEntryAndItsTargetDieTogether();

    if (has_ev) aThreadedAbstractLosesItsReference();

    clearMemoryFinalizesEverything();
    repeatedCycles();

    vm_lifecycle.deinit();
}
