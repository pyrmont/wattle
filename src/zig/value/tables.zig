//! Tables: Janet's mutable dictionary, its prototype chain, and the linear
//! probe that carries tombstones.
//!
//! `structs.zig` is the sibling and the other half of the dictionary group.
//! They were one file, whose name was two nouns because C had two files. They
//! still call each other -- `janet_table_to_struct` calls `structs.begin`,
//! `structs.put` and `structs.end`, `janet_struct_to_table` calls `put` -- so
//! the two files import each other. Zig has no trouble with that; the reason a
//! C original cannot be split this way is that C has no such thing as an
//! import.
//!
//! Both files hold `asSize`, `isNilKey` and `isUnstorableKey`, three inline
//! predicates of two lines each. That is deliberate: neither file is the right
//! owner of a rule about the other's keys, and a fifteenth file in `value/`
//! to hold six lines would contradict the layout `NAMESPACES.md` settled.
//!
//! ## The probe carries tombstones
//!
//! **A table probes linearly and carries tombstones.** A removed entry leaves
//! a nil key with a *false* value behind, which stops a lookup from treating
//! the hole as the end of a run. `value.dictionaryFind` in `utils.zig` therefore
//! distinguishes "nil key, nil value" -- a true empty slot, and the end of the
//! search -- from "nil key, non-nil value", which it remembers as the first
//! reusable bucket and keeps walking past. Table layout depends on insertion
//! *and deletion* order, and nothing observable depends on table layout.
//!
//! That is the opposite discipline to a struct's, which has no tombstones and
//! a layout that is a function of its pairs. `structs.zig` records why.
//!
//! ## SPIKE-8, and the rehash that publishes before it re-inserts
//!
//! `value.dictionaryFind` -- reached from every table operation -- calls
//! `janet_equals`, which dispatches to a third-party abstract type's callback
//! for an abstract key. Under SPIKE-8 such a callback may not raise, and if
//! one does the signal jumps straight through these frames. There is no
//! `defer` here and `build.zig` checks that there is not.
//!
//! One consequence is worth naming rather than leaving to be discovered.
//! `rehash` publishes the new bucket array into `t->data` before it
//! re-inserts, and holds the old one only in a local. A signal raised out of a
//! key comparison during that loop leaks the old array and leaves the table
//! holding a partially populated new one. The C does the same thing, and the
//! same rule covers both: a callback that raises is out of contract. Nothing
//! is restructured to survive it, because surviving it is not the promise.
//!
//! ## What is reproduced rather than repaired
//!
//! A table whose capacity is zero cannot be looked up in at all, and
//! `janet_table` produces one for any negative capacity. The details are on
//! `initImpl` below; the short version is that `janet_maphash` degenerates
//! into the identity when the mask is all ones, so the whole hash is used as a
//! bucket number and only a hash of zero stays in bounds. Not reachable from
//! Janet source, kept as written, recorded in `FOUND.md`.
//!
//! The tombstone-retiring branch in `janet_table_put` and `putNoOverwrite` is
//! unreachable for the same kind of reason -- the load factor guarantees an
//! empty bucket, and `value.dictionaryFind` prefers one over a tombstone. Also
//! kept, also recorded.
//!
//! `janet_table_clone` copies with plain `memcpy`. A table with a null bucket
//! array makes that `memcpy(dst, NULL, 0)`, which the standard does not
//! exempt, and `janet_table` produces exactly that for any negative capacity:
//! `value.capacityFor` returns 0 only for a negative argument, and 0 is the one
//! result `initImpl` turns into a null `data`. It is not reachable from Janet
//! source -- every Janet-level constructor validates its capacity as a
//! non-negative integer, and `janet_table(0)` has a capacity of *one* -- so
//! this needs a C API caller. `safe_memcpy` exists in `util.c` for exactly
//! this case, "avoid some undefined behavior that was common in the code
//! base", and this call site was missed. The port uses `safe_memcpy` and
//! `FOUND.md` records the C original. No observable behaviour differs.

const std = @import("std");
const config = @import("config");
const corefn = @import("corefn");
const types = @import("types");
const repr = @import("repr");
const c = @import("cabi");
const raise = @import("raise");
const args_core = @import("../args.zig");
const gc_alloc = @import("../gc.zig");
const utils = @import("../utils.zig");
const wrap = @import("helpers/wrap.zig");
const fatal = @import("../fatal.zig");
const structs = @import("structs.zig");
const value = @import("../value.zig");

/// Functions from `src/core/util.c` and `src/core/wrap.c`, declared here rather
/// than in `cabi.zig`: `util.h` was internal, and never in a translation.
///
/// All six are Zig, and batch 4 spent two of them. `value_wrap.zig` defined
/// `memempty` and `memallocEmpty` without `pub`; that batch opened the file to
/// split it, so making them `pub` cost nothing and they are imports now. The
/// four left are `utils.zig`'s -- `tablen`, `safeMemcpy`, `dictFind` and
/// `dictFindKeyword` -- and they need that file opened, which is an increment
/// rather than a side effect.
extern fn safe_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void;

/// A table whose bucket array came from the scratch allocator rather than from
/// `janet_malloc`. `table.c` keeps this out of `janet.h` because it is not part
/// of the public flag vocabulary; it is stored in the same `gc.flags` word the
/// memory type occupies, which is safe only because a scratch table is never
/// `janet_gcalloc`ed.
const table_flag_stack: i32 = 0x10000;

/// C's conversion of a signed count to `size_t`: sign-extend to the pointer
/// width, then reinterpret. Same helper, and same reason, as `buffer_array.zig`
/// and `string_symbol.zig` -- a negative length becomes a request the allocator
/// cannot satisfy rather than a trap one statement earlier.
inline fn asSize(n: i32) usize {
    return @bitCast(@as(isize, n));
}

inline fn isNilKey(key: repr.Value) bool {
    return repr.checkType(key, repr.Tag.nil);
}

/// The two keys a dictionary refuses to store. Nil is the absent-key sentinel,
/// and a NaN is refused because it does not compare equal to itself, so a
/// lookup could never find it again.
inline fn isUnstorableKey(key: repr.Value) bool {
    if (repr.checkType(key, repr.Tag.nil)) return true;
    return repr.checkType(key, repr.Tag.number) and
        std.math.isNan(wrap.toNumber(key));
}

/// Allocate an empty bucket array from the scratch allocator.
///
/// Unlike `value.memallocEmpty` this adds no collection pressure and does not
/// check for failure: `janet_smalloc` exits the process rather than returning
/// null. Scratch memory is released wholesale by `janet_free_all_scratch`,
/// which is also what recovers it if a signal unwinds past a scratch table.
fn memallocEmptyLocal(count: i32) [*]types.JanetKV {
    const mem: [*]types.JanetKV = @ptrCast(@alignCast(gc_alloc.smalloc(asSize(count) *% @sizeOf(types.JanetKV))));
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        mem[@intCast(i)].key = wrap.fromNil();
        mem[@intCast(i)].value = wrap.fromNil();
    }
    return mem;
}

/// Give a table its initial bucket array.
///
/// The requested capacity is rounded up by `value.capacityFor`, which returns the
/// smallest power of two strictly greater than its argument -- so `janet_table(0)`
/// gets *one* bucket, not none. The only argument that yields zero is a
/// negative one, and that is the sole route to a table with a null `data`.
///
/// Such a table cannot be used. `janet_maphash` masks the hash with
/// `capacity - 1`, which at a capacity of zero is every bit set, so the mask is
/// the identity and the "bucket index" `value.dictionaryFind` works from is the
/// whole 32-bit hash. Both of its loops are then bounded by that number rather
/// than by the capacity -- the first runs when the hash is negative, the second
/// when it is positive -- so exactly one hash value is survivable, and it is
/// zero. `janet_table_put` reaches the same call before the rehash that would
/// have given the table buckets, so it cannot recover either.
///
/// `FOUND.md` records it, with the reproducer. It needs a
/// C API caller, since every route from Janet source validates the capacity as
/// a non-negative integer. `value.dictionaryFind` is in `util.c` and stays there, so
/// both selectors behave identically.
///
/// The stack flag is *assigned* rather than or-ed, which overwrites the memory
/// type in `gc.flags`. That is safe only because a scratch table is never
/// `janet_gcalloc`ed -- `janet_table_init` is called on caller-owned memory the
/// collector never sees.
fn initImpl(table: *types.JanetTable, capacity_in: i32, stackalloc: bool) *types.JanetTable {
    const capacity = value.capacityFor(capacity_in);
    if (stackalloc) table.gc.flags = table_flag_stack;
    if (capacity != 0) {
        const data: [*]types.JanetKV = if (stackalloc)
            memallocEmptyLocal(capacity)
        else
            @ptrCast(@alignCast(value.memallocEmpty(capacity) orelse fatal.outOfMemory()));
        table.data = data;
        table.capacity = capacity;
    } else {
        table.data = null;
        table.capacity = 0;
    }
    table.count = 0;
    table.deleted = 0;
    table.proto = null;
    return table;
}

/// Initialise a caller-owned table whose buckets come from scratch memory.
pub fn init(table: *types.JanetTable, capacity: i32) *types.JanetTable {
    return initImpl(table, capacity, true);
}

/// Initialise a caller-owned table whose buckets come from the ordinary heap.
pub fn initRaw(table: *types.JanetTable, capacity: i32) *types.JanetTable {
    return initImpl(table, capacity, false);
}

/// Release a table's bucket array to whichever allocator produced it. Also
/// called from `deinitBlock` in `gc/sweep.zig`, which is the collectable
/// table's only route here -- so a table's allocate/release round trip is
/// entirely inside Zig.
pub fn deinit(table: *types.JanetTable) void {
    if ((table.gc.flags & table_flag_stack) != 0) {
        gc_alloc.sfree(@ptrCast(table.data));
    } else {
        utils.free(@ptrCast(table.data));
    }
}

/// Allocate a collectable table with strong references to keys and values.
pub fn new(capacity: i32) *types.JanetTable {
    const table: *types.JanetTable = @ptrCast(@alignCast(gc_alloc.gcalloc(types.MemoryType.table, @sizeOf(types.JanetTable))));
    return initImpl(table, capacity, false);
}

/// The three weak variants differ from `janet_table` only in their memory type,
/// which is what puts them on `vm.gc.weak_blocks` instead of
/// `vm.gc.blocks` and tells `gc_sweep.zig` which half of each pair to drop
/// when its referent is unreachable.
pub fn weakk(capacity: i32) *types.JanetTable {
    const table: *types.JanetTable = @ptrCast(@alignCast(gc_alloc.gcalloc(types.MemoryType.table_weakk, @sizeOf(types.JanetTable))));
    return initImpl(table, capacity, false);
}

pub fn weakv(capacity: i32) *types.JanetTable {
    const table: *types.JanetTable = @ptrCast(@alignCast(gc_alloc.gcalloc(types.MemoryType.table_weakv, @sizeOf(types.JanetTable))));
    return initImpl(table, capacity, false);
}

pub fn weakkv(capacity: i32) *types.JanetTable {
    const table: *types.JanetTable = @ptrCast(@alignCast(gc_alloc.gcalloc(types.MemoryType.table_weakkv, @sizeOf(types.JanetTable))));
    return initImpl(table, capacity, false);
}

/// Find the bucket holding `key`, or the bucket it should go in.
pub fn find(t: *types.JanetTable, key: repr.Value) ?*types.JanetKV {
    return @constCast(value.dictionaryFind(t.slots(), key));
}

/// Move a table's contents into a bucket array of `size` buckets.
///
/// Tombstones are not carried over, which is the only thing that ever reclaims
/// them: `deleted` is reset to zero and only live pairs are re-inserted. The
/// new array is published into `t->data` before the loop runs, because
/// `janet_table_find` reads it -- which is also why a signal raised out of a
/// key comparison here strands the old array.
fn rehash(t: *types.JanetTable, size: i32) void {
    const olddata = t.data;
    const islocal = (t.gc.flags & table_flag_stack) != 0;
    const newdata: [*]types.JanetKV = if (islocal)
        memallocEmptyLocal(size)
    else
        @ptrCast(@alignCast(value.memallocEmpty(size) orelse fatal.outOfMemory()));
    const oldcapacity = t.capacity;
    t.data = newdata;
    t.capacity = size;
    t.deleted = 0;
    var i: i32 = 0;
    while (i < oldcapacity) : (i += 1) {
        const kv = &olddata.?[@intCast(i)];
        if (!isNilKey(kv.key)) {
            const newkv = find(t, kv.key);
            newkv.?.* = kv.*;
        }
    }
    if (islocal) {
        gc_alloc.sfree(@ptrCast(olddata));
    } else {
        utils.free(@ptrCast(olddata));
    }
}

/// Look up a key, following prototypes to a fixed depth.
pub fn get(t_in: *types.JanetTable, key: repr.Value) repr.Value {
    var t: ?*types.JanetTable = t_in;
    var i: c_int = config.max_proto_depth;
    while (t != null and i != 0) : ({
        t = t.?.proto;
        i -= 1;
    }) {
        const bucket = find(t.?, key);
        if (bucket != null and !isNilKey(bucket.?.key)) return bucket.?.value;
    }
    return wrap.fromNil();
}

/// Look up a keyword, symbol or string key given as raw bytes.
///
/// Used by the compiler to read the core environment without interning a
/// symbol first. `value.dictionaryFindKeyword` hashes the bytes the way a string
/// is hashed and compares byte-wise, so it finds the same bucket the interned
/// key would.
pub fn getKeyword(t_in: *types.JanetTable, keyword: [*:0]const u8) repr.Value {
    const keyword_len: i32 = @intCast(c.strlen(keyword));
    var t: ?*types.JanetTable = t_in;
    var i: c_int = config.max_proto_depth;
    while (t != null and i != 0) : ({
        t = t.?.proto;
        i -= 1;
    }) {
        const bucket = value.dictionaryFindKeyword(t.?.slots(), keyword, keyword_len);
        if (bucket != null and !isNilKey(bucket.?.key)) return bucket.?.value;
    }
    return wrap.fromNil();
}

/// Look up a key and report which table in the prototype chain held it.
pub fn getEx(t_in: *types.JanetTable, key: repr.Value, which: *?*types.JanetTable) repr.Value {
    var t: ?*types.JanetTable = t_in;
    var i: c_int = config.max_proto_depth;
    while (t != null and i != 0) : ({
        t = t.?.proto;
        i -= 1;
    }) {
        const bucket = find(t.?, key);
        if (bucket != null and !isNilKey(bucket.?.key)) {
            which.* = t;
            return bucket.?.value;
        }
    }
    return wrap.fromNil();
}

/// Look up a key in this table only.
pub fn rawget(t: *types.JanetTable, key: repr.Value) repr.Value {
    const bucket = find(t, key);
    if (bucket != null and !isNilKey(bucket.?.key)) return bucket.?.value;
    return wrap.fromNil();
}

/// Remove a key and return the value it held.
///
/// The bucket is left with a nil key and a *false* value, which is the
/// tombstone: `value.dictionaryFind` stops only at a bucket whose key and value are
/// both nil, so the hole does not truncate a probe run through it. `deleted`
/// counts tombstones and is what eventually forces a rehash.
pub fn remove(t: *types.JanetTable, key: repr.Value) repr.Value {
    const bucket = find(t, key);
    if (bucket != null and !isNilKey(bucket.?.key)) {
        const ret = bucket.?.value;
        t.count -= 1;
        t.deleted += 1;
        bucket.?.key = wrap.fromNil();
        bucket.?.value = wrap.fromFalse();
        return ret;
    }
    return wrap.fromNil();
}

/// Insert, update or remove a pair.
///
/// A nil value is a removal rather than a stored nil, which is the same rule
/// that makes a table's absent keys and its nil-valued keys indistinguishable.
/// Growth is triggered when the live pairs *plus the tombstones* would pass
/// half the capacity, so a table that is churned rather than grown still
/// rehashes and reclaims its tombstones.
pub fn put(t: *types.JanetTable, key: repr.Value, val: repr.Value) void {
    if (isUnstorableKey(key)) return;
    if (repr.checkType(val, repr.Tag.nil)) {
        _ = remove(t, key);
        return;
    }
    var bucket = find(t, key);
    if (bucket != null and !isNilKey(bucket.?.key)) {
        bucket.?.value = val;
        return;
    }
    if (bucket == null or 2 *% (t.count +% t.deleted +% 1) > t.capacity) {
        rehash(t, value.capacityFor(2 *% t.count +% 2));
    }
    bucket = find(t, key);
    // A boolean in an empty bucket's value is the tombstone marker, so filling
    // that bucket would retire one. It never happens: `value.dictionaryFind` returns
    // a remembered tombstone only when the array holds no empty bucket at all,
    // and the growth test above keeps the array at most half full counting
    // tombstones. So a rehash is the only thing that ever reclaims one, and
    // this branch is dead. `FOUND.md` records it. Kept, because this
    // reproduces rather than tidies.
    if (repr.checkType(bucket.?.value, repr.Tag.boolean)) t.deleted -= 1;
    bucket.?.key = key;
    bucket.?.value = val;
    t.count += 1;
}

/// Insert only if the key is absent. Internal, so the key is not validated --
/// every caller is copying pairs that a table or struct already accepted.
fn putNoOverwrite(t: *types.JanetTable, key: repr.Value, val: repr.Value) void {
    var bucket = find(t, key);
    if (bucket != null and !isNilKey(bucket.?.key)) return;
    if (bucket == null or 2 *% (t.count +% t.deleted +% 1) > t.capacity) {
        rehash(t, value.capacityFor(2 *% t.count +% 2));
    }
    bucket = find(t, key);
    if (repr.checkType(bucket.?.value, repr.Tag.boolean)) t.deleted -= 1;
    bucket.?.key = key;
    bucket.?.value = val;
    t.count += 1;
}

/// Empty a table without releasing its bucket array. The capacity survives, and
/// so does the prototype.
pub fn clear(t: *types.JanetTable) void {
    value.memempty(t.slots());
    t.count = 0;
    t.deleted = 0;
}

/// Copy a table, bucket array and all.
///
/// The layout is copied verbatim rather than rebuilt, so the clone keeps the
/// original's tombstones and its `deleted` count along with its pairs. The
/// prototype is shared, not copied.
///
/// `safe_memcpy` rather than `memcpy`: an empty table has a null `data` and a
/// zero capacity, and `memcpy(dst, NULL, 0)` is undefined behaviour the C
/// original reaches from `(table/clone @{})`. `FOUND.md` has it. Nothing
/// observable differs.
pub fn clone(table: *types.JanetTable) *types.JanetTable {
    const new_table: *types.JanetTable = @ptrCast(@alignCast(gc_alloc.gcalloc(types.MemoryType.table, @sizeOf(types.JanetTable))));
    new_table.count = table.count;
    new_table.capacity = table.capacity;
    new_table.deleted = table.deleted;
    new_table.proto = table.proto;
    const bytes = asSize(new_table.capacity) *% @sizeOf(types.JanetKV);
    new_table.data = @ptrCast(@alignCast(utils.malloc(bytes) orelse fatal.outOfMemory()));
    safe_memcpy(@ptrCast(new_table.data), @ptrCast(table.data), asSize(table.capacity) *% @sizeOf(types.JanetKV));
    return new_table;
}

/// Copy every live pair out of a bucket array into a table.
fn mergeKV(table: *types.JanetTable, kvs: []const types.JanetKV) void {
    for (kvs) |kv| {
        if (!isNilKey(kv.key)) put(table, kv.key, kv.value);
    }
}

/// Merge another table's own pairs in. Its prototype is not consulted.
pub fn mergeTable(table: *types.JanetTable, other: *types.JanetTable) void {
    mergeKV(table, other.slots());
}

/// Merge a struct's own pairs in. Its prototype is not consulted.
pub fn mergeStruct(table: *types.JanetTable, other: [*]const types.JanetKV) void {
    mergeKV(table, other[0..@intCast(types.structHead(other).capacity)]);
}

/// Freeze a table's own pairs into a struct.
///
/// The struct is begun at `count` rather than at `capacity`, so tombstones cost
/// nothing here. The prototype is not carried; `table/to-struct` takes the
/// struct's prototype as a separate argument.
pub fn toStruct(t: *types.JanetTable) [*]const types.JanetKV {
    const st = structs.begin(t.count);
    var kv = t.data.?;
    const end = t.data.? + @as(usize, @intCast(t.capacity));
    while (@intFromPtr(kv) < @intFromPtr(end)) : (kv += 1) {
        if (!isNilKey(kv[0].key)) structs.put(st, kv[0].key, kv[0].value);
    }
    return structs.end(st);
}

/// Collapse a prototype chain into one table.
///
/// Walked child first with `putNoOverwrite`, so a binding nearer the child
/// wins -- the same precedence a lookup through the chain would have given. The
/// chain is followed to its end rather than to `JANET_MAX_PROTO_DEPTH`, so a
/// cyclic prototype chain does not terminate here. That is the C behaviour and
/// it is left alone: `table/setproto` accepts a cycle, and the lookup paths
/// that bound their depth are the reason it is otherwise survivable.
pub fn protoFlatten(t_in: *types.JanetTable) *types.JanetTable {
    const new_table = new(0);
    var t: ?*types.JanetTable = t_in;
    while (t != null) : (t = t.?.proto) {
        var kv = t.?.data.?;
        const end = t.?.data.? + @as(usize, @intCast(t.?.capacity));
        while (@intFromPtr(kv) < @intFromPtr(end)) : (kv += 1) {
            if (!isNilKey(kv[0].key)) putNoOverwrite(new_table, kv[0].key, kv[0].value);
        }
    }
    return new_table;
}

// ==========================================================================
// The cfunction surface.
//
// A published `JanetCFunction` has no error channel in its signature, so these
// deliver a raise through an abi. Nothing below holds anything across a call
// that can raise.
// ==========================================================================

fn cfunTableNew(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromTable(new(try args_core.getNat(argv, 0)));
}

fn cfunTableWeak(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromTable(weakkv(try args_core.getNat(argv, 0)));
}

fn cfunTableWeakKeys(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromTable(weakk(try args_core.getNat(argv, 0)));
}

fn cfunTableWeakValues(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromTable(weakv(try args_core.getNat(argv, 0)));
}

fn cfunTableGetproto(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const t = try args_core.getTable(argv, 0);
    return if (t.*.proto) |proto| wrap.fromTable(proto) else wrap.fromNil();
}

/// An explicit nil clears the prototype rather than faulting, which is why the
/// second argument is tested before it is fetched instead of going through
/// `janet_opttable` -- that would build an empty table for the default.
fn cfunTableSetproto(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    const table = try args_core.getTable(argv, 0);
    var proto: ?*types.JanetTable = null;
    if (!repr.checkType(argv[1], repr.Tag.nil)) proto = try args_core.getTable(argv, 1);
    table.*.proto = proto;
    return argv[0];
}

fn cfunTableTostruct(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, 2);
    const t = try args_core.getTable(argv, 0);
    const proto = try args_core.optStruct(argv, 1, null);
    const st = toStruct(t);
    types.structHead(st).proto = proto;
    return wrap.fromStruct(st);
}

fn cfunTableRawget(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    return rawget(try args_core.getTable(argv, 0), argv[1]);
}

fn cfunTableClone(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromTable(clone(try args_core.getTable(argv, 0)));
}

fn cfunTableClear(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const table = try args_core.getTable(argv, 0);
    clear(table);
    return wrap.fromTable(table);
}

fn cfunTableProtoFlatten(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromTable(protoFlatten(try args_core.getTable(argv, 0)));
}

pub fn lib(env: *types.JanetTable) void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("table/new", &cfunTableNew, @src(), "(table/new capacity)", "Creates a new empty table with pre-allocated memory " ++
            "for `capacity` entries. This means that if one knows the number of " ++
            "entries going into a table on creation, extra memory allocation " ++
            "can be avoided. " ++
            "Returns the new table."),
        corefn.reg("table/weak", &cfunTableWeak, @src(), "(table/weak capacity)", "Creates a new empty table with weak references to keys and values. Similar to `table/new`. " ++
            "Returns the new table."),
        corefn.reg("table/weak-keys", &cfunTableWeakKeys, @src(), "(table/weak-keys capacity)", "Creates a new empty table with weak references to keys and normal references to values. Similar to `table/new`. " ++
            "Returns the new table."),
        corefn.reg("table/weak-values", &cfunTableWeakValues, @src(), "(table/weak-values capacity)", "Creates a new empty table with normal references to keys and weak references to values. Similar to `table/new`. " ++
            "Returns the new table."),
        corefn.reg("table/to-struct", &cfunTableTostruct, @src(), "(table/to-struct tab &opt proto)", "Convert a table to a struct. Returns a new struct."),
        corefn.reg("table/getproto", &cfunTableGetproto, @src(), "(table/getproto tab)", "Get the prototype table of a table. Returns nil if the table " ++
            "has no prototype, otherwise returns the prototype."),
        corefn.reg("table/setproto", &cfunTableSetproto, @src(), "(table/setproto tab proto)", "Set the prototype of a table. Returns the original table `tab`."),
        corefn.reg("table/rawget", &cfunTableRawget, @src(), "(table/rawget tab key)", "Gets a value from a table `tab` without looking at the prototype table. " ++
            "If `tab` does not contain the key directly, the function will return " ++
            "nil without checking the prototype. Returns the value in the table."),
        corefn.reg("table/clone", &cfunTableClone, @src(), "(table/clone tab)", "Create a copy of a table. Updates to the new table will not change the old table, " ++
            "and vice versa."),
        corefn.reg("table/clear", &cfunTableClear, @src(), "(table/clear tab)", "Remove all key-value pairs in a table and return the modified table `tab`."),
        corefn.reg("table/proto-flatten", &cfunTableProtoFlatten, @src(), "(table/proto-flatten tab)", "Create a new table that is the result of merging all prototypes into a new table."),
    };
    corefn.install(env, entries);
}
