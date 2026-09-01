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
//! owner of a rule about the other's keys, and a fifteenth file in `value/` to
//! hold six lines would earn no name.
//!
//! ## The probe carries tombstones
//!
//! **A table probes linearly and carries tombstones.** A removed entry leaves
//! a nil key with a *false* value behind, which stops a lookup from treating
//! the hole as the end of a run. `value.dictionaryFind` therefore
//! distinguishes "nil key, nil value" -- a true empty slot, and the end of the
//! search -- from "nil key, non-nil value", which it remembers as the first
//! reusable bucket and keeps walking past. Table layout depends on insertion
//! *and deletion* order, and nothing observable depends on table layout.
//!
//! That is the opposite discipline to a struct's, which has no tombstones and
//! a layout that is a function of its pairs. `structs.zig` records why.
//!
//! ## The rehash publishes before it re-inserts
//!
//! `value.dictionaryFind` -- reached from every table operation -- calls
//! `janet_equals`, which dispatches to a third-party abstract type's callback
//! for an abstract key. Such a callback is out of contract if it raises, and
//! nothing here holds anything across one.
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
//! exempt, and `janet_table` produced exactly that for any negative capacity.
//! No constructor here can: a capacity is a `usize` and `capacityFor` answers
//! at least one. A zeroed `Table` still holds those fields, which is how
//! `test/struct_table.zig` builds the case. `safe_memcpy` exists in `util.c`
//! for exactly this, "avoid some undefined behavior that was common in the
//! code base", and this call site was missed. The port uses `safe_memcpy` and
//! `FOUND.md` records the C original. No observable behaviour differs.

const std = @import("std");
const config = @import("config");
const corefn = @import("../corefn.zig");
const repr = @import("repr");
const c = @import("cabi");
const raise = @import("../raise.zig");
const args_core = @import("../args.zig");
const gc_alloc = @import("../gc.zig");
const utils = @import("../utils.zig");
const wrap = @import("helpers/wrap.zig");
const structs = @import("structs.zig");
const value = @import("../value.zig");
const abi = @import("abi");

/// Bit 0 of the GC header's per-type field: this table's bucket array came
/// from the scratch allocator rather than from the heap, so `deinit` must
/// release it there.
const own_scratch: u6 = 1;

pub inline fn isScratch(table: *const Table) bool {
    return table.gc.flags.own & own_scratch != 0;
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
fn memallocEmptyLocal(count: usize) [*]KV {
    const mem: [*]KV = @ptrCast(@alignCast(gc_alloc.smalloc(count *% @sizeOf(KV))));
    for (mem[0..count]) |*kv| {
        kv.key = wrap.fromNil();
        kv.value = wrap.fromNil();
    }
    return mem;
}

/// Give a table its initial bucket array.
///
/// The requested capacity is rounded up by `value.capacityFor`, which returns
/// the smallest power of two strictly greater than its argument -- so a
/// requested zero gets *one* bucket, not none. C reached zero for a negative
/// request and left `data` null, which is a table no lookup survives;
/// `FOUND.md` records what that does and the type no longer admits it.
///
/// The stack flag is *assigned* rather than or-ed, which overwrites the memory
/// type in `gc.flags`. That is safe only because a scratch table is never
/// `gcalloc`ed -- `init` is called on caller-owned memory the collector never
/// sees.
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

/// Initialise a caller-owned table whose buckets come from scratch memory.
pub fn init(table: *Table, capacity: usize) *Table {
    return initImpl(table, capacity, true);
}

/// Initialise a caller-owned table whose buckets come from the ordinary heap.
pub fn initRaw(table: *Table, capacity: usize) *Table {
    return initImpl(table, capacity, false);
}

/// Release a table's bucket array to whichever allocator produced it. Also
/// called from `deinitBlock` in `gc/sweep.zig`, which is the collectable
/// table's only route here -- so a table's allocate/release round trip is
/// entirely inside Zig.
pub fn deinit(table: *Table) void {
    if (isScratch(table)) {
        gc_alloc.sfree(@ptrCast(table.data));
    } else {
        utils.free(@ptrCast(table.data));
    }
}

/// Allocate a collectable table with strong references to keys and values.
pub fn new(capacity: usize) *Table {
    const table = gc_alloc.gcalloc(Table, .table);
    return initImpl(table, capacity, false);
}

/// The three weak variants differ from `janet_table` only in their memory type,
/// which is what puts them on `vm.gc.weak_blocks` instead of
/// `vm.gc.blocks` and tells `gc_sweep.zig` which half of each pair to drop
/// when its referent is unreachable.
pub fn weakk(capacity: usize) *Table {
    const table = gc_alloc.gcalloc(Table, .table_weakk);
    return initImpl(table, capacity, false);
}

pub fn weakv(capacity: usize) *Table {
    const table = gc_alloc.gcalloc(Table, .table_weakv);
    return initImpl(table, capacity, false);
}

pub fn weakkv(capacity: usize) *Table {
    const table = gc_alloc.gcalloc(Table, .table_weakkv);
    return initImpl(table, capacity, false);
}

/// Find the bucket holding `key`, or the bucket it should go in.
pub fn find(t: *Table, key: repr.Value) ?*KV {
    return @constCast(value.dictionaryFind(t.slots(), key));
}

/// Move a table's contents into a bucket array of `size` buckets.
///
/// Tombstones are not carried over, which is the only thing that ever reclaims
/// them: `deleted` is reset to zero and only live pairs are re-inserted. The
/// new array is published into `t->data` before the loop runs, because
/// `janet_table_find` reads it -- which is also why a signal raised out of a
/// key comparison here strands the old array.
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

/// Look up a key, following prototypes to a fixed depth.
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

/// Look up a keyword, symbol or string key given as raw bytes.
///
/// Used by the compiler to read the core environment without interning a
/// symbol first. `value.dictionaryFindKeyword` hashes the bytes the way a string
/// is hashed and compares byte-wise, so it finds the same bucket the interned
/// key would.
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

/// A prototype-chain lookup's two answers: the value, and which table in the
/// chain held it.
///
/// `holder` is null on a miss, which is the same thing `value` being nil says
/// -- but only the pair says *which* table answered, and that is the whole
/// reason this differs from `get`. The out-parameter it replaces made a miss
/// look like "the caller's variable was left alone", which is why `peg.zig`
/// pre-seeded it and then had nine unwraps to show for it.
pub const Found = struct {
    value: repr.Value,
    holder: ?*Table,
};

/// Look up a key and report which table in the prototype chain held it.
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

/// Look up a key in this table only.
pub fn rawget(t: *Table, key: repr.Value) repr.Value {
    if (find(t, key)) |bucket| {
        if (!isNilKey(bucket.key)) return bucket.value;
    }
    return wrap.fromNil();
}

/// Remove a key and return the value it held.
///
/// The bucket is left with a nil key and a *false* value, which is the
/// tombstone: `value.dictionaryFind` stops only at a bucket whose key and value are
/// both nil, so the hole does not truncate a probe run through it. `deleted`
/// counts tombstones and is what eventually forces a rehash.
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

/// Insert, update or remove a pair.
///
/// A nil value is a removal rather than a stored nil, which is the same rule
/// that makes a table's absent keys and its nil-valued keys indistinguishable.
/// Growth is triggered when the live pairs *plus the tombstones* would pass
/// half the capacity, so a table that is churned rather than grown still
/// rehashes and reclaims its tombstones.
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
    // tombstones, so this probe always reaches an empty bucket and cannot come
    // back empty-handed.
    const bucket = find(t, key) orelse unreachable;
    // A boolean in an empty bucket's value is the tombstone marker, so filling
    // that bucket would retire one. It never happens: `value.dictionaryFind` returns
    // a remembered tombstone only when the array holds no empty bucket at all,
    // and the growth test above keeps the array at most half full counting
    // tombstones. So a rehash is the only thing that ever reclaims one, and
    // this branch is dead. `FOUND.md` records it. Kept, because this
    // reproduces rather than tidies.
    if (repr.checkType(bucket.value, repr.Tag.boolean)) t.deleted -= 1;
    bucket.key = key;
    bucket.value = val;
    t.count += 1;
}

/// Insert only if the key is absent. Internal, so the key is not validated --
/// every caller is copying pairs that a table or struct already accepted.
fn putNoOverwrite(t: *Table, key: repr.Value, val: repr.Value) void {
    const found = find(t, key);
    if (found) |old| {
        if (!isNilKey(old.key)) return;
    }
    if (found == null or 2 *% (t.count +% t.deleted +% 1) > t.capacity) {
        rehash(t, value.capacityFor(2 *% t.count +% 2));
    }
    // As in `put`: the growth test leaves an empty bucket for this probe to
    // find, so it cannot come back empty-handed.
    const bucket = find(t, key) orelse unreachable;
    if (repr.checkType(bucket.value, repr.Tag.boolean)) t.deleted -= 1;
    bucket.key = key;
    bucket.value = val;
    t.count += 1;
}

/// Empty a table without releasing its bucket array. The capacity survives, and
/// so does the prototype.
pub fn clear(t: *Table) void {
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

/// Copy every live pair out of a bucket array into a table.
fn mergeKV(table: *Table, kvs: []const KV) void {
    for (kvs) |kv| {
        if (!isNilKey(kv.key)) put(table, kv.key, kv.value);
    }
}

/// Merge another table's own pairs in. Its prototype is not consulted.
pub fn mergeTable(table: *Table, other: *Table) void {
    mergeKV(table, other.slots());
}

/// Merge a struct's own pairs in. Its prototype is not consulted.
pub fn mergeStruct(table: *Table, other: [*]const KV) void {
    mergeKV(table, other[0..structs.head(other).capacity]);
}

/// Freeze a table's own pairs into a struct.
///
/// The struct is begun at `count` rather than at `capacity`, so tombstones cost
/// nothing here. The prototype is not carried; `table/to-struct` takes the
/// struct's prototype as a separate argument.
pub fn toStruct(t: *Table) [*]const KV {
    const st = structs.begin(@intCast(t.count));
    for (t.slots()) |kv| {
        if (!isNilKey(kv.key)) structs.put(st, kv.key, kv.value);
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
pub fn protoFlatten(t_in: *Table) *Table {
    const new_table = new(0);
    var t: ?*Table = t_in;
    while (t) |tab| : (t = tab.proto) {
        for (tab.slots()) |kv| {
            if (!isNilKey(kv.key)) putNoOverwrite(new_table, kv.key, kv.value);
        }
    }
    return new_table;
}

// ==========================================================================
// The cfunction surface.
//
// A published `CFunction` has no error channel in its signature, so these
// deliver a raise through an abi. Nothing below holds anything across a call
// that can raise.
// ==========================================================================

fn cfunTableNew(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromTable(new(@intCast(try args_core.getNat(argv, 0))));
}

fn cfunTableWeak(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromTable(weakkv(@intCast(try args_core.getNat(argv, 0))));
}

fn cfunTableWeakKeys(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromTable(weakk(@intCast(try args_core.getNat(argv, 0))));
}

fn cfunTableWeakValues(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromTable(weakv(@intCast(try args_core.getNat(argv, 0))));
}

fn cfunTableGetproto(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const t = try args_core.getTable(argv, 0);
    return if (t.proto) |proto| wrap.fromTable(proto) else wrap.fromNil();
}

/// An explicit nil clears the prototype rather than faulting, which is why the
/// second argument is tested before it is fetched instead of going through
/// `janet_opttable` -- that would build an empty table for the default.
fn cfunTableSetproto(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 2);
    const table = try args_core.getTable(argv, 0);
    var proto: ?*Table = null;
    if (!repr.checkType(argv[1], repr.Tag.nil)) proto = try args_core.getTable(argv, 1);
    table.proto = proto;
    return argv[0];
}

fn cfunTableTostruct(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, 2);
    const t = try args_core.getTable(argv, 0);
    const proto = try args_core.optStruct(argv, 1, null);
    const st = toStruct(t);
    structs.head(st).proto = proto;
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

pub const Table = struct {
    gc: abi.GCObject = .{},
    count: usize = 0,
    capacity: usize = 0,
    deleted: usize = 0,
    data: ?[*]KV = null,
    proto: ?*Table = null,

    /// The open-addressed slot array, `capacity` long. **Not the entries**:
    /// `count` is how many slots are occupied and `deleted` how many hold a
    /// tombstone, so a walk over a table is a walk over this with a nil-key
    /// test inside it. Named `slots` rather than `slice` for that reason --
    /// `arrays.Array` and `buffers.Buffer` answer their live contents and this
    /// answers the probe table.
    ///
    /// Empty rather than a trap for a table that has never been grown:
    /// `janet_table_init(t, 0)` leaves `data` null with `capacity` zero, and
    /// `data.?[0..0]` traps on exactly that.
    pub inline fn slots(self: anytype) utils.View(@TypeOf(self), KV) {
        if (self.capacity == 0) return &.{};
        return self.data.?[0..self.capacity];
    }
};
pub const KV = extern struct {
    key: repr.Value = std.mem.zeroes(repr.Value),
    value: repr.Value = std.mem.zeroes(repr.Value),
};
