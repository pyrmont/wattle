//! Janet's mutable dictionary, its prototype chain, and the linear probe that
//! keeps tombstones.
//!
//! `new` allocates a collectable table and `newFrom` fills one from pairs.
//! `init` and `initRaw` set up a table the caller owns, and `deinit` releases
//! its buckets. `get` follows the prototype chain, `rawget` does not, `getEx`
//! reports which table in the chain the value came from, and `getKeyword`
//! looks a key up from raw bytes. `put` inserts, updates and removes, and
//! `remove` returns what it took out. `weakk`, `weakkv` and `weakv` are `new`
//! on the weak heap.
//!
//! `structs.zig` is the sibling and the other half of the dictionary group.
//! The two call each other, `toStruct` calling `structs.begin`, `structs.put`
//! and `structs.end` and `structs.toTable` calling `put`, so the two files
//! import each other, which Zig allows. Each declares its own `isNilKey` and
//! `isUnstorableKey`, two inline predicates of two lines, because neither file
//! is the right owner of a rule about the other's keys.
//!
//! ## The probe keeps tombstones
//!
//! A removed entry leaves a nil key with a false value behind, which stops a
//! lookup from treating the hole as the end of a run. `value.dictionaryFind`
//! therefore distinguishes a nil key with a nil value, which is a true empty
//! slot and the end of the search, from a nil key with a non-nil value, which
//! it remembers as the first reusable bucket and walks past. Table layout
//! depends on insertion order and on deletion order, and nothing observable
//! depends on table layout.
//!
//! That is the opposite discipline to a struct's, which has no tombstones and
//! a layout that is a function of its pairs. `structs.zig` records why.
//!
//! ## No lookup path here raises
//!
//! `value.dictionaryFind` returns a bucket and `order.equals` returns a
//! `bool`; an abstract key's `compare` and `hash` are `callconv(.c) i32` and
//! have no way to raise, which is the contract `api/abstract_type.zig` states.
//! `rehash` is where that matters, because it publishes the new bucket array
//! into the table before the loop that fills it and keeps the old array in a
//! local across that loop.
//!
//! ## The cfunction surface
//!
//! Each `cfunTable*` is a `raise.Raising(repr.Value)` and takes its raise out
//! with `try`; nothing in them is stranded across a call that can raise. The
//! `align(corefn.alignment)` is what `registry.zig`'s `checkPointerAlign`
//! requires of a wrapped function pointer under a shifting nanbox layout.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const args_core = @import("../args.zig");
const c = @import("cabi");
const config = @import("config");
const corefn = @import("../corefn.zig");
const gc_alloc = @import("../gc.zig");
const raise = @import("../../api/raise.zig");
const repr = @import("repr");
const structs = @import("structs.zig");
const utils = @import("../utils.zig");
const value = @import("../value.zig");
const wrap = @import("helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// Bit 0 of the GC header's per-type field: this table's bucket array came
/// from the scratch allocator rather than from the heap, so `deinit` must
/// release it there.
const own_scratch: u6 = 1;

// ==========================================================================
// Aliased types
// ==========================================================================

/// One entry: a key beside its value.
///
/// It is declared in `abi.zig` because a module author walks an array of them.
/// A dictionary crosses to an author as `abi.DictView`, which points at such an
/// array, so both compilations have to spell the same two fields; the
/// operations over a table are all here, which is the split `AbstractHead`,
/// `Method` and `ByteView` already have.
pub const KV = abi.KV;

// ==========================================================================
// Types
// ==========================================================================

/// A prototype-chain lookup's two results: the value, and which table in the
/// chain it came from.
///
/// `holder` is null on a miss, which is the same thing a nil `value` says. Only
/// the pair says which table the value came from, and that is the whole reason
/// this differs from `get`.
pub const Found = struct {
    value: repr.Value,
    holder: ?*Table,
};

/// Janet's mutable dictionary: a collectable header, the counts, the bucket
/// array and the prototype.
///
/// `capacity` is always a power of two and never zero, which is what the
/// constructors guarantee and what `value.mapHash`'s mask relies on. `count`
/// is the live pairs and `deleted` the tombstones among them.
pub const Table = struct {
    gc: abi.GCObject = .{},
    count: usize = 0,
    capacity: usize = 0,
    deleted: usize = 0,
    data: ?[*]KV = null,
    proto: ?*Table = null,
    /// The open-addressed slot array, `capacity` long, rather than the
    /// entries: `count` is how many slots are occupied and `deleted` how many
    /// are tombstones, so a walk over a table is a walk over this with a
    /// nil-key test inside it. Named `slots` rather than `slice` for that
    /// reason, `arrays.Array` and `buffers.Buffer` giving back their live
    /// contents where this gives back the probe table.
    ///
    /// Empty rather than a trap for a table that has never been grown: a
    /// zeroed `Table` has a null `data` and a zero `capacity`, and
    /// `data.?[0..0]` traps on exactly that.
    pub inline fn slots(self: anytype) utils.View(@TypeOf(self), KV) {
        if (self.capacity == 0) return &.{};
        return self.data.?[0..self.capacity];
    }
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Empties `t` without releasing its bucket array. The capacity survives, and
/// so does the prototype.
pub fn clear(t: *Table) void {
    value.memempty(t.slots());
    t.count = 0;
    t.deleted = 0;
}

/// Copies `table`, bucket array and all.
///
/// The layout is copied verbatim rather than rebuilt, so the clone keeps the
/// original's tombstones and its `deleted` count along with its pairs. The
/// prototype is shared, not copied.
///
/// The copy goes through `slots()`, which is an empty slice at a zero
/// capacity, so a table with a null `data` copies nothing rather than
/// dereferencing the null. No constructor here builds such a table and no
/// Janet binding reaches one; `test/struct_table.zig` zeroes one by hand to
/// pin the case.
pub fn clone(table: *Table) *Table {
    const new_table = gc_alloc.gcalloc(Table, .table);
    new_table.count = table.count;
    new_table.capacity = table.capacity;
    new_table.deleted = table.deleted;
    new_table.proto = table.proto;
    new_table.data = utils.allocMany(KV, new_table.capacity);
    @memcpy(new_table.slots(), table.slots());
    return new_table;
}

/// Releases `table`'s bucket array to whichever allocator produced it.
///
/// This is for a table the caller set up with `init` or `initRaw`. A
/// collectable table does not come here: `gc/sweep.zig`'s `deinitBlock` frees
/// its bucket array directly, and that is the same call, because `initImpl`
/// never gives a collectable table scratch buckets.
pub fn deinit(table: *Table) void {
    if (isScratch(table)) {
        gc_alloc.sfree(@ptrCast(table.data));
    } else {
        utils.free(@ptrCast(table.data));
    }
}

/// Returns the bucket with `key` in it, or the bucket it should go in.
pub fn find(t: *Table, key: repr.Value) ?*KV {
    return @constCast(value.dictionaryFind(t.slots(), key));
}

/// Looks `key` up in `t_in`, following prototypes to `config.max_proto_depth`.
pub fn get(t_in: *Table, key: repr.Value) repr.Value {
    var t: ?*Table = t_in;
    var i: c_int = config.max_proto_depth;
    while (i != 0) : (i -= 1) {
        const tab = t orelse break;
        if (find(tab, key)) |bucket| {
            if (!isNilKey(bucket.key)) return bucket.value;
        }
        t = tab.proto;
    }
    return wrap.fromNil();
}

/// The same as `get`, also reporting which table in the prototype chain the
/// value came from.
pub fn getEx(t_in: *Table, key: repr.Value) Found {
    var t: ?*Table = t_in;
    var i: c_int = config.max_proto_depth;
    while (i != 0) : (i -= 1) {
        const tab = t orelse break;
        if (find(tab, key)) |bucket| {
            if (!isNilKey(bucket.key)) {
                return .{ .value = bucket.value, .holder = tab };
            }
        }
        t = tab.proto;
    }
    return .{ .value = wrap.fromNil(), .holder = null };
}

/// Looks up a keyword, symbol or string key given as raw bytes.
///
/// `keyword` is the NUL-terminated name. The compiler reads the core
/// environment through this without interning a symbol first.
/// `value.dictionaryFindKeyword` hashes the bytes the way a string is hashed
/// and compares byte-wise, so it finds the bucket the interned key would.
pub fn getKeyword(t_in: *Table, keyword: [*:0]const u8) repr.Value {
    const keyword_len: i32 = @intCast(c.strlen(keyword));
    var t: ?*Table = t_in;
    var i: c_int = config.max_proto_depth;
    while (i != 0) : (i -= 1) {
        const tab = t orelse break;
        if (value.dictionaryFindKeyword(tab.slots(), keyword, keyword_len)) |bucket| {
            if (!isNilKey(bucket.key)) return bucket.value;
        }
        t = tab.proto;
    }
    return wrap.fromNil();
}

/// Initialises a caller-owned table whose buckets come from scratch memory.
pub fn init(table: *Table, capacity: usize) *Table {
    return initImpl(table, capacity, true);
}

/// Initialises a caller-owned table whose buckets come from the ordinary heap.
pub fn initRaw(table: *Table, capacity: usize) *Table {
    return initImpl(table, capacity, false);
}

/// Whether `table`'s bucket array came from the scratch allocator.
pub inline fn isScratch(table: *const Table) bool {
    return table.gc.flags.own & own_scratch != 0;
}

/// Installs the `table/` cfunctions into `env`.
pub fn lib(env: *Table) void {
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

/// Merges a struct's own pairs into `table`. Its prototype is not consulted.
pub fn mergeStruct(table: *Table, other: [*]const KV) void {
    mergeKV(table, other[0..structs.head(other).capacity]);
}

/// Merges another table's own pairs into `table`. Its prototype is not
/// consulted.
pub fn mergeTable(table: *Table, other: *Table) void {
    mergeKV(table, other.slots());
}

/// Allocates a collectable table with strong references to keys and values.
pub fn new(capacity: usize) *Table {
    const table = gc_alloc.gcalloc(Table, .table);
    return initImpl(table, capacity, false);
}

/// Builds a table from `kvs`, which is what `module.tableOf` reaches through
/// `capi.zig`'s `new_table`. See `structs.newFrom` for why this takes pairs
/// rather than a view, and for what a nil value does.
///
/// The capacity is `2 * len` so that no `put` in the loop can rehash. `new`
/// rounds its argument up through `value.capacityFor`, which gives the
/// smallest power of two strictly greater than what it is given, and `put`
/// grows when `2 * (count + deleted + 1)` passes the capacity, so `new(2)`
/// gives four buckets and the second pair reallocates. Sizing up front makes
/// the first allocation the only allocation, which is what a constructor
/// filling a table it just made should cost.
pub fn newFrom(kvs: []const KV) *Table {
    const t = new(2 *| kvs.len);
    for (kvs) |kv| put(t, kv.key, kv.value);
    return t;
}

/// Collapses `t_in`'s prototype chain into one table.
///
/// Walked child first with `putNoOverwrite`, so a binding nearer the child
/// wins, which is the precedence a lookup through the chain would have given.
///
/// Bounded by `config.max_proto_depth`, like every other prototype walk here.
/// `table/setproto` accepts a cycle, so an unbounded walk would not terminate.
/// The bound also makes the result exactly the set a lookup through the chain
/// can reach, which is the set the flattening is for.
pub fn protoFlatten(t_in: *Table) *Table {
    const new_table = new(0);
    var t: ?*Table = t_in;
    var depth: c_int = config.max_proto_depth;
    while (t) |tab| : (t = tab.proto) {
        if (depth == 0) break;
        depth -= 1;
        for (tab.slots()) |kv| {
            if (!isNilKey(kv.key)) putNoOverwrite(new_table, kv.key, kv.value);
        }
    }
    return new_table;
}

/// Inserts, updates or removes a pair.
///
/// A nil `val` is a removal rather than a stored nil, which is the same rule
/// that makes a table's absent keys and its nil-valued keys
/// indistinguishable. Growth is triggered when the live pairs plus the
/// tombstones would pass half the capacity, so a table that is churned rather
/// than grown still rehashes and reclaims its tombstones.
pub fn put(t: *Table, key: repr.Value, val: repr.Value) void {
    if (isUnstorableKey(key)) return;
    if (repr.checkType(val, repr.Tag.nil)) {
        _ = remove(t, key);
        return;
    }
    const found = find(t, key);
    if (found) |old| {
        if (!isNilKey(old.key)) {
            old.value = val;
            return;
        }
    }
    if (found == null or 2 *% (t.count +% t.deleted +% 1) > t.capacity) {
        rehash(t, value.capacityFor(2 *% t.count +% 2));
    }
    // The growth test above leaves the array less than half full counting
    // tombstones, so this probe always reaches an empty bucket: it cannot come
    // back empty-handed, and what it comes back with is never a tombstone.
    // `deleted` therefore stands until the next rehash, which is what makes a
    // churned table rehash and shrink.
    const bucket = find(t, key) orelse unreachable;
    bucket.key = key;
    bucket.value = val;
    t.count += 1;
}

/// Looks `key` up in `t` alone, without following prototypes.
pub fn rawget(t: *Table, key: repr.Value) repr.Value {
    if (find(t, key)) |bucket| {
        if (!isNilKey(bucket.key)) return bucket.value;
    }
    return wrap.fromNil();
}

/// Removes `key` and returns the value it was stored with.
///
/// The bucket is left with a nil key and a false value, which is the
/// tombstone: `value.dictionaryFind` stops only at a bucket whose key and
/// value are both nil, so the hole does not truncate a probe run through it.
/// `deleted` counts tombstones and is what eventually forces a rehash.
pub fn remove(t: *Table, key: repr.Value) repr.Value {
    if (find(t, key)) |bucket| {
        if (!isNilKey(bucket.key)) {
            const ret = bucket.value;
            t.count -= 1;
            t.deleted += 1;
            bucket.key = wrap.fromNil();
            bucket.value = wrap.fromFalse();
            return ret;
        }
    }
    return wrap.fromNil();
}

/// Freezes `t`'s own pairs into a struct.
///
/// The struct is begun at `count` rather than at `capacity`, so tombstones
/// cost nothing here. The prototype is not copied; `table/to-struct` takes the
/// struct's prototype as a separate argument.
pub fn toStruct(t: *Table) [*]const KV {
    const st = structs.begin(@intCast(t.count));
    for (t.slots()) |kv| {
        if (!isNilKey(kv.key)) structs.put(st, kv.key, kv.value);
    }
    return structs.end(st);
}

/// The three weak variants differ from `new` only in their memory type, which
/// is what puts them on `vm.gc.weak_blocks` instead of `vm.gc.blocks` and
/// tells `gc/sweep.zig` which half of each pair to drop when its referent is
/// unreachable.
pub fn weakk(capacity: usize) *Table {
    const table = gc_alloc.gcalloc(Table, .table_weakk);
    return initImpl(table, capacity, false);
}

pub fn weakkv(capacity: usize) *Table {
    const table = gc_alloc.gcalloc(Table, .table_weakkv);
    return initImpl(table, capacity, false);
}

pub fn weakv(capacity: usize) *Table {
    const table = gc_alloc.gcalloc(Table, .table_weakv);
    return initImpl(table, capacity, false);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// `table/clear`: every pair removed, the capacity and the prototype kept.
fn cfunTableClear(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const table = try args_core.getTable(argv, 0);
    clear(table);
    return wrap.fromTable(table);
}

/// `table/clone`: a copy, bucket array and all.
fn cfunTableClone(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromTable(clone(try args_core.getTable(argv, 0)));
}

/// `table/getproto`: the prototype, or nil where there is none.
fn cfunTableGetproto(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const t = try args_core.getTable(argv, 0);
    return if (t.proto) |proto| wrap.fromTable(proto) else wrap.fromNil();
}

/// `table/new`: an empty table with capacity reserved.
fn cfunTableNew(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromTable(new(@intCast(try args_core.getNat(argv, 0))));
}

/// `table/proto-flatten`: the prototype chain collapsed into one table.
fn cfunTableProtoFlatten(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromTable(protoFlatten(try args_core.getTable(argv, 0)));
}

/// `table/rawget`: a lookup that does not follow the prototype chain.
fn cfunTableRawget(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    return rawget(try args_core.getTable(argv, 0), argv[1]);
}

/// `table/setproto`: the prototype replaced, or cleared by an explicit nil.
///
/// The second argument is tested before it is fetched rather than going
/// through `args.optTable`, because that would build an empty table for the
/// default where a nil has to clear the prototype instead.
fn cfunTableSetproto(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    const table = try args_core.getTable(argv, 0);
    var proto: ?*Table = null;
    if (!repr.checkType(argv[1], repr.Tag.nil)) proto = try args_core.getTable(argv, 1);
    table.proto = proto;
    return argv[0];
}

/// `table/to-struct`: the pairs frozen, with the struct's prototype taken as a
/// separate argument.
fn cfunTableTostruct(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, 2);
    const t = try args_core.getTable(argv, 0);
    const proto = try args_core.optStruct(argv, 1, null);
    const st = toStruct(t);
    structs.head(st).proto = proto;
    return wrap.fromStruct(st);
}

/// `table/weak`: `table/new` with weak keys and weak values.
fn cfunTableWeak(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromTable(weakkv(@intCast(try args_core.getNat(argv, 0))));
}

/// `table/weak-keys`: `table/new` with weak keys and strong values.
fn cfunTableWeakKeys(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromTable(weakk(@intCast(try args_core.getNat(argv, 0))));
}

/// `table/weak-values`: `table/new` with strong keys and weak values.
fn cfunTableWeakValues(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromTable(weakv(@intCast(try args_core.getNat(argv, 0))));
}

/// Gives `table` its initial bucket array.
///
/// `capacity_in` is rounded up by `value.capacityFor`, which gives the
/// smallest power of two strictly greater than its argument, so a requested
/// zero gets one bucket rather than none, and the `usize` parameter is what
/// makes a negative request unsayable.
///
/// No constructor here can build a table with a zero capacity, and that is the
/// reason: `value.mapHash` degenerates into the identity when the mask is all
/// ones, so the whole hash becomes a bucket number and only a hash of zero
/// lands in bounds. A zeroed `Table` still has those fields, which is how
/// `test/struct_table.zig` builds the case.
///
/// `stackalloc` selects the scratch allocator, and the flag it sets is
/// assigned rather than ored, which overwrites the memory type in `gc.flags`.
/// That is safe only because a scratch table is never `gcalloc`ed: `init` is
/// called on caller-owned memory the collector never sees.
fn initImpl(table: *Table, capacity_in: usize, stackalloc: bool) *Table {
    const capacity = value.capacityFor(capacity_in);
    if (stackalloc) table.gc.flags = .{ .own = own_scratch };
    table.data = if (stackalloc)
        memallocEmptyLocal(capacity)
    else
        value.memallocEmpty(capacity);
    table.capacity = capacity;
    table.count = 0;
    table.deleted = 0;
    table.proto = null;
    return table;
}

/// Whether `key` is the nil that marks an empty bucket.
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

/// Allocates an empty bucket array of `count` slots from the scratch
/// allocator.
///
/// Unlike `value.memallocEmpty` this adds no collection pressure and does not
/// check for failure: `gc.smalloc` exits the process rather than returning
/// null. Scratch memory is released wholesale by `gc.freeAllScratch`, which is
/// also what recovers it if a signal unwinds past a scratch table.
fn memallocEmptyLocal(count: usize) [*]KV {
    const mem: [*]KV = @ptrCast(@alignCast(gc_alloc.smalloc(count *% @sizeOf(KV))));
    for (mem[0..count]) |*kv| {
        kv.key = wrap.fromNil();
        kv.value = wrap.fromNil();
    }
    return mem;
}

/// Copies every live pair in `kvs` into `table`.
fn mergeKV(table: *Table, kvs: []const KV) void {
    for (kvs) |kv| {
        if (!isNilKey(kv.key)) put(table, kv.key, kv.value);
    }
}

/// Inserts only where the key is absent. Internal, so the key is not
/// validated: every caller is copying pairs a table or struct already
/// accepted.
fn putNoOverwrite(t: *Table, key: repr.Value, val: repr.Value) void {
    const found = find(t, key);
    if (found) |old| {
        if (!isNilKey(old.key)) return;
    }
    if (found == null or 2 *% (t.count +% t.deleted +% 1) > t.capacity) {
        rehash(t, value.capacityFor(2 *% t.count +% 2));
    }
    // As in `put`: the growth test leaves an empty bucket for this probe to
    // find, so it cannot come back empty-handed or with a tombstone.
    const bucket = find(t, key) orelse unreachable;
    bucket.key = key;
    bucket.value = val;
    t.count += 1;
}

/// Moves `t`'s contents into a fresh bucket array of `size` buckets.
///
/// Tombstones are not copied over, and a rehash is the only thing that ever
/// reclaims them: `deleted` is reset to zero and only live pairs are
/// re-inserted. The new array is published into the table's `data` before the
/// loop runs, because `find` reads it, and the old array is kept only in a
/// local across that loop, which is safe because nothing in the loop can
/// raise.
///
/// Neither `put` nor `putNoOverwrite` retires a tombstone: the load factor
/// guarantees an empty bucket and `value.dictionaryFind` prefers an empty
/// bucket to a tombstone, so the bucket they fill is never a tombstone.
fn rehash(t: *Table, size: usize) void {
    const olddata = t.data;
    const islocal = isScratch(t);
    const newdata: [*]KV = if (islocal)
        memallocEmptyLocal(size)
    else
        value.memallocEmpty(size);
    const oldcapacity = t.capacity;
    t.data = newdata;
    t.capacity = size;
    t.deleted = 0;
    for (0..oldcapacity) |i| {
        const kv = &olddata.?[i];
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
