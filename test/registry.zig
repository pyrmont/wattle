//! Behavioral contract for the half of `src/core/util.c` that owns VM state:
//! the cfunction registry, the four registration entry points, bindings,
//! symbol resolution, the abstract-type registry, and text substitution.
//!
//! Most of this subsystem is reachable from Janet source and is covered by
//! `port/probe-17/util-remainder.janet`. What is here is what only a caller
//! inside the runtime can reach: the registry's own ordering and growth, the
//! four registration entry points as an embedder calls them,
//! `janet_binding_from_entry` on entries the compiler would never build, and
//! the two `janet_core_*` forms.
//!
//! ## What the migration changed
//!
//! Three things, and the first two are the reason the migration is worth
//! making rather than a cost of it.
//!
//! **The two raise-capable entry points are called by import.**
//! `registerAbstractType` and `textSubstitution` are `raise.Raising`
//! functions with a `raise.panicking` abi over each; the C contract could
//! only reach the abi and read `janet_contract_raised`. Here the refusal is a
//! value, so each is one `harness.raised` line — and `janet_text_substitution`,
//! declared in `util.h` alone, loses its last caller and goes with this file.
//! That is rule 12 again: the way to find a dead abi is to migrate its
//! contract and then delete it.
//!
//! **The registry gets distinct keys.** The C original's growth section says
//! its own limitation out loud — "every row needs a distinct key, and the key
//! is a function pointer, so the keys have to come from somewhere. Offsetting
//! into a table of distinct pointers is not available in portable C" — and
//! settles for pushing the *same* pointer 513 times. So the array it grew was
//! one key repeated, and the ordering assertion beside it was very nearly
//! vacuous: three distinct rows among five hundred identical ones. A comptime
//! family gives as many distinct probes as are asked for, and `theSortIsTotal`
//! below runs the sort over sixteen of them.
//!
//! Sixteen rather than five hundred and thirteen, deliberately. Reaching the
//! capacity floor with distinct keys would need 513 generated functions to
//! test the `realloc`, which is a property of the *array* and not of the keys;
//! the fill below still does that with a repeated pointer, which is all it
//! ever needed.
//!
//! **Each probe returns a different integer**, which is rule 28 and is not
//! decoration. A registry key is an address, so a contract about the registry
//! answering differently for different keys has "these are distinct addresses"
//! as the premise of every assertion in it — and every optimize mode above
//! Debug folds identical function bodies into one address. Nothing calls these
//! probes, so nothing reads the values; what they buy is that the fold is
//! illegal.

const std = @import("std");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const corefn = @import("corefn");
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
const value = @import("subsystems").value;
const tables = @import("subsystems").value.tables;
const symbols = @import("subsystems").value.symbols;
const utils = @import("subsystems").utils;
const args_core = @import("subsystems").args;
const registry_mod = @import("subsystems").registry;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const arrays = @import("subsystems").value.arrays;
const registry = subsystems.registry;
const abstract_type = subsystems.abstract_type;
const AbstractType = abstract_type.AbstractType;

const assert = std.debug.assert;
const internal = harness.internal;

/// `strcmp` against a literal, for the three registry fields that are plain C
/// strings rather than Janet ones.
///
/// `harness.stringIs` is the Janet-string form and is the wrong tool here:
/// `janet_cstrcmp` reads a length out of the head that precedes its argument,
/// and `JanetCFunRegistry.name` points into the binary's rodata with no head
/// in front of it.
fn cstringIs(s: ?[*:0]const u8, expected: []const u8) bool {
    if (s == null) return false;
    return std.mem.eql(u8, std.mem.span(s.?), expected);
}

// ------------------------------------------------------------------ probes

/// A cfunction that exists only to be a registry key.
///
/// `align(corefn.alignment)` because `janet_cfuns` checks it:
/// `checkPointerAlign` refuses a cfunction pointer whose low bits the
/// nanbox-64 pointer shift would steal, and `-Dnanbox-pointer-shift=2` is a
/// matrix entry. The C original got the alignment from
/// `JANET_CFUNCTION_ALIGN`; this is the same requirement spelled in Zig.
fn Probe(comptime tag: i32) type {
    return struct {
        fn run(argv: []types.Janet) align(corefn.alignment) raise.Raising(types.Janet) {
            _ = @as(i32, @intCast(argv.len));

            return harness.wrapInteger(tag);
        }
    };
}

fn keyOf(comptime tag: i32) types.JanetCFunction {
    return raise.stored(&Probe(tag).run);
}

const probe_one = keyOf(1);
const probe_two = keyOf(2);
const probe_three = keyOf(3);
const probe_unregistered = keyOf(4);
const filler = keyOf(5);

/// Sixteen more, distinct from each other and from the five above.
const family_size = 16;
const family: [family_size]types.JanetCFunction = blk: {
    var keys: [family_size]types.JanetCFunction = undefined;
    for (&keys, 0..) |*slot, i| slot.* = keyOf(100 + @as(i32, @intCast(i)));
    break :blk keys;
};

// ------------------------------------------------------------- the registry

fn theRegistryRecordsWhatItWasGiven() void {
    const before = c.vm().registry_count;

    registry_mod.register("probe/one", probe_one);
    registry_mod.register("probe/two", probe_two);
    registry_mod.register("probe/three", probe_three);
    assert(c.vm().registry_count == before + 3);

    // Registration marks the array dirty; the first lookup sorts it.
    assert(c.vm().registry_dirty != 0);
    var found = internal.janet_registry_get(probe_two);
    assert(c.vm().registry_dirty == 0);
    assert(found != null);
    assert(found.?.cfun == probe_two);
    assert(cstringIs(found.?.name, "probe/two"));
    // `janet_register` passes no prefix and no source location.
    assert(found.?.name_prefix == null);
    assert(found.?.source_file == null);
    assert(found.?.source_line == 0);

    found = internal.janet_registry_get(probe_one);
    assert(found != null and found.?.cfun == probe_one);
    found = internal.janet_registry_get(probe_three);
    assert(found != null and found.?.cfun == probe_three);

    // A cfunction that was never registered answers null rather than a
    // neighbouring row, which is the case `doframe` in `debug_frames.zig`
    // dereferences without checking -- `FOUND.md` has that one.
    assert(internal.janet_registry_get(probe_unregistered) == null);

    // Registering the same pointer twice appends a second row rather than
    // replacing the first. Reproduced from C: nothing dedupes.
    const again = c.vm().registry_count;
    registry_mod.register("probe/one-again", probe_one);
    assert(c.vm().registry_count == again + 1);
    found = internal.janet_registry_get(probe_one);
    assert(found != null and found.?.cfun == probe_one);
}

/// The sort is by pointer and orders the *whole* array, not only the rows this
/// contract added. That is what the bisection in `janet_registry_get` is
/// written against, and it holds even though the linear scan above it means
/// the bisection never runs.
///
/// The C original asserted this over three distinct keys and five hundred
/// copies of a fourth. Sixteen more distinct rows is what makes the insertion
/// sort actually have work to do, and each is looked up afterwards so that a
/// sort which lost or duplicated a row is caught rather than merely ordered.
fn theSortIsTotalOverDistinctKeys() void {
    for (family, 0..) |key, i| {
        var name: [32]u8 = @splat(0);
        _ = std.fmt.bufPrint(&name, "probe/family-{d}", .{i}) catch unreachable;
        internal.janet_registry_put(key, @ptrCast(&name), null, null, 0);
    }

    // Every one of them is found, and found at its own row.
    for (family) |key| {
        const row = internal.janet_registry_get(key);
        assert(row != null);
        assert(row.?.cfun == key);
    }

    var i: usize = 1;
    while (i < c.vm().registry_count) : (i += 1) {
        const previous = @intFromPtr(c.vm().registry.?[i - 1].cfun);
        const current = @intFromPtr(c.vm().registry.?[i].cfun);
        assert(previous <= current);
    }
}

/// Growth. The floor is 512 entries, which the core alone does not reach, so
/// this is the only place the doubling is exercised at all.
///
/// The key is the same pointer every time, on purpose: what is under test is
/// the `realloc` and the new capacity, and neither reads the key.
fn theRegistryGrowsPastItsFloor() void {
    const cap = c.vm().registry_cap;
    const count = c.vm().registry_count;
    while (c.vm().registry_count < cap + 1) {
        internal.janet_registry_put(filler, "probe/filler", null, null, 0);
    }
    assert(c.vm().registry_cap > cap);
    assert(c.vm().registry_count > count);
    // The new capacity is (count + 1) * 2 at the moment of the growth, with a
    // floor of 512. Whatever it is, it must leave room for what is there.
    assert(c.vm().registry_cap >= c.vm().registry_count);
}

// ------------------------------------------------- the registration entries

const probe_reg = [_]types.JanetReg{
    .{ .name = "one", .cfun = probe_one, .documentation = "the first" },
    .{ .name = "two", .cfun = probe_two, .documentation = null },
    .{ .name = null, .cfun = null, .documentation = null },
};

const probe_reg_ext = [_]types.JanetRegExt{
    .{
        .name = "three",
        .cfun = probe_three,
        .documentation = "the third",
        .source_file = "probe.c",
        .source_line = 42,
    },
    .{ .name = null, .cfun = null, .documentation = null, .source_file = null, .source_line = 0 },
};

/// The entry a def builds: a table with `:value`, and `:doc` and `:source-map`
/// only when there is something to put in them.
fn checkEntry(env: *types.JanetTable, name: [*:0]const u8, has_doc: bool, has_map: bool) void {
    const entry = tables.get(env, value.fromBytes(std.mem.span(name), .symbol));
    assert(harness.isType(entry, constants.JANET_TABLE));
    const t = wrap.toTable(entry);
    assert(harness.isType(tables.get(t, value.fromBytes("value", .keyword)), constants.JANET_CFUNCTION));
    assert(harness.isType(tables.get(t, value.fromBytes("doc", .keyword)), constants.JANET_NIL) != has_doc);
    assert(harness.isType(tables.get(t, value.fromBytes("source-map", .keyword)), constants.JANET_NIL) != has_map);
}

fn theFourEntryPointsDefineAndRegister() void {
    const env = tables.new(4);

    registry_mod.cfuns(env, "probe", &probe_reg);
    checkEntry(env, "one", true, false);
    // A NULL docstring means no `:doc` key at all rather than a nil value.
    checkEntry(env, "two", false, false);

    registry_mod.cfunsExt(env, "probe", &probe_reg_ext);
    checkEntry(env, "three", true, true);

    const entry = tables.get(env, value.fromBytes("three", .symbol));
    const map = tables.get(wrap.toTable(entry), value.fromBytes("source-map", .keyword));
    assert(harness.isType(map, constants.JANET_TUPLE));
    const tup = wrap.toTuple(map);
    assert(utils.tupleHead(tup).*.length == 3);
    assert(harness.stringValueIs(tup[0], "probe.c"));
    assert(harness.integerIs(tup[1], 42));
    assert(harness.integerIs(tup[2], 1));

    // The registry got the *unprefixed* name and the prefix separately, for
    // all four entry points. The prefix only changes the binding's name.
    const row = internal.janet_registry_get(probe_three);
    assert(cstringIs(row.?.name, "three"));
    assert(cstringIs(row.?.name_prefix, "probe"));
}

fn thePrefixingFormsRewriteOnlyTheName() void {
    const env = tables.new(4);

    registry_mod.cfunsPrefix(env, "pre", &probe_reg);
    checkEntry(env, "pre/one", true, false);
    checkEntry(env, "pre/two", false, false);
    assert(harness.isType(tables.get(env, value.fromBytes("one", .symbol)), constants.JANET_NIL));

    registry_mod.cfunsExtPrefix(env, "pre", &probe_reg_ext);
    checkEntry(env, "pre/three", true, true);

    // A prefix long enough that the name buffer's 256-byte reserve is not what
    // carries it, so the realloc in `NameBuf.name` is exercised.
    {
        var big: [400]u8 = @splat('p');
        big[big.len - 1] = 0;
        var expected: [420]u8 = @splat(0);
        const env2 = tables.new(4);
        registry_mod.cfunsPrefix(env2, @ptrCast(&big), &probe_reg);
        _ = std.fmt.bufPrint(&expected, "{s}/one", .{big[0 .. big.len - 1]}) catch unreachable;
        checkEntry(env2, @ptrCast(&expected), true, false);
    }

    // A null environment registers without defining, and must not build a name
    // buffer at all. Every entry point takes it.
    registry_mod.cfuns(null, "probe", &probe_reg);
    registry_mod.cfunsExt(null, "probe", &probe_reg_ext);
    registry_mod.cfunsPrefix(null, "probe", &probe_reg);
    registry_mod.cfunsExtPrefix(null, "probe", &probe_reg_ext);
}

// ------------------------------------------------------------- def and var

/// `janet_var` and `janet_var_sm` are `raise.panicking` abis over
/// `janet_var_smImpl`, which raises because pushing onto the `:ref` array can.
/// A caller inside the compilation reaches the implementation, so a refusal
/// would arrive here as an error rather than as a report nobody consumed.
///
/// Both abis stay: they are `janet.h`'s public surface. Neither has an
/// in-tree caller any more, which is data for the exported-symbol-surface
/// bullet rather than a deletion — see `janet_register`, `janet_resolve_core`
/// and the two prefixing forms, in the same position.
fn defAndVarBuildDifferentEntries() raise.Raising(void) {
    const env = tables.new(4);

    registry_mod.def(env, "d", harness.wrapInteger(7), "doc for d");
    var t = wrap.toTable(tables.get(env, value.fromBytes("d", .symbol)));
    assert(harness.integerIs(tables.get(t, value.fromBytes("value", .keyword)), 7));
    assert(harness.isType(tables.get(t, value.fromBytes("ref", .keyword)), constants.JANET_NIL));

    try registry.janet_var_smImpl(env, "v", harness.wrapInteger(8), null, null, 0);
    t = wrap.toTable(tables.get(env, value.fromBytes("v", .symbol)));
    // A var's value is in a one-element array under `:ref`, and there is no
    // `:value` key at all.
    assert(harness.isType(tables.get(t, value.fromBytes("value", .keyword)), constants.JANET_NIL));
    const ref = tables.get(t, value.fromBytes("ref", .keyword));
    assert(harness.isType(ref, constants.JANET_ARRAY));
    const array = wrap.toArray(ref);
    assert(array.*.count == 1);
    assert(harness.integerIs(array.*.data.?[0], 8));

    // A source line of zero suppresses the map even when the file is given,
    // because the file alone locates nothing.
    registry_mod.defSm(env, "nomap", wrap.fromNil(), null, "f.c", 0);
    t = wrap.toTable(tables.get(env, value.fromBytes("nomap", .symbol)));
    assert(harness.isType(tables.get(t, value.fromBytes("source-map", .keyword)), constants.JANET_NIL));

    try registry.janet_var_smImpl(env, "vmap", wrap.fromNil(), null, "f.c", 9);
    t = wrap.toTable(tables.get(env, value.fromBytes("vmap", .symbol)));
    assert(!harness.isType(tables.get(t, value.fromBytes("source-map", .keyword)), constants.JANET_NIL));
}

// ------------------------------------------------------- reading a binding

fn bindingOf(entry: *types.JanetTable) types.JanetBinding {
    return internal.janet_binding_from_entry(wrap.fromTable(entry));
}

fn theBindingIsASummaryOfFourKeys() void {
    // Anything that is not a table is NONE with a nil value.
    var b = internal.janet_binding_from_entry(wrap.fromNil());
    assert(b.type == constants.JANET_BINDING_NONE);
    assert(harness.isType(b.value, constants.JANET_NIL));
    assert(b.deprecation == constants.JANET_BINDING_DEP_NONE);
    b = internal.janet_binding_from_entry(harness.wrapInteger(3));
    assert(b.type == constants.JANET_BINDING_NONE);

    // A plain def.
    var entry = tables.new(2);
    tables.put(entry, value.fromBytes("value", .keyword), harness.wrapInteger(1));
    b = bindingOf(entry);
    assert(b.type == constants.JANET_BINDING_DEF);
    assert(harness.integerIs(b.value, 1));

    // A ref makes it a var, and the binding's value is the array rather than
    // its contents -- dereferencing is `janet_resolve`'s job.
    entry = tables.new(2);
    tables.put(entry, value.fromBytes("ref", .keyword), wrap.fromArray(arrays.new(1)));
    b = bindingOf(entry);
    assert(b.type == constants.JANET_BINDING_VAR);
    assert(harness.isType(b.value, constants.JANET_ARRAY));

    // `:redef` only means anything with a valid ref.
    entry = tables.new(2);
    tables.put(entry, value.fromBytes("value", .keyword), harness.wrapInteger(1));
    tables.put(entry, value.fromBytes("redef", .keyword), wrap.fromTrue());
    b = bindingOf(entry);
    assert(b.type == constants.JANET_BINDING_DEF);

    entry = tables.new(2);
    tables.put(entry, value.fromBytes("ref", .keyword), wrap.fromArray(arrays.new(1)));
    tables.put(entry, value.fromBytes("redef", .keyword), wrap.fromTrue());
    b = bindingOf(entry);
    assert(b.type == constants.JANET_BINDING_DYNAMIC_DEF);

    // A macro, and the dynamic macro the same `:redef` produces.
    entry = tables.new(2);
    tables.put(entry, value.fromBytes("value", .keyword), harness.wrapInteger(1));
    tables.put(entry, value.fromBytes("macro", .keyword), wrap.fromTrue());
    b = bindingOf(entry);
    assert(b.type == constants.JANET_BINDING_MACRO);
    assert(harness.integerIs(b.value, 1));

    entry = tables.new(3);
    tables.put(entry, value.fromBytes("value", .keyword), harness.wrapInteger(1));
    tables.put(entry, value.fromBytes("ref", .keyword), wrap.fromArray(arrays.new(1)));
    tables.put(entry, value.fromBytes("redef", .keyword), wrap.fromTrue());
    tables.put(entry, value.fromBytes("macro", .keyword), wrap.fromTrue());
    b = bindingOf(entry);
    assert(b.type == constants.JANET_BINDING_DYNAMIC_MACRO);
    assert(harness.isType(b.value, constants.JANET_ARRAY));

    // A macro with a ref but no `:redef` keeps the plain `:value`, which is
    // the one combination where the two keys disagree about which is read.
    entry = tables.new(3);
    tables.put(entry, value.fromBytes("value", .keyword), harness.wrapInteger(5));
    tables.put(entry, value.fromBytes("ref", .keyword), wrap.fromArray(arrays.new(1)));
    tables.put(entry, value.fromBytes("macro", .keyword), wrap.fromTrue());
    b = bindingOf(entry);
    assert(b.type == constants.JANET_BINDING_MACRO);
    assert(harness.integerIs(b.value, 5));
}

fn deprecationReadsAKeywordAndFallsBackToNormal() void {
    const cases = [_]struct { keyword: [*:0]const u8, expect: c_int }{
        .{ .keyword = "relaxed", .expect = constants.JANET_BINDING_DEP_RELAXED },
        .{ .keyword = "normal", .expect = constants.JANET_BINDING_DEP_NORMAL },
        .{ .keyword = "strict", .expect = constants.JANET_BINDING_DEP_STRICT },
        // An unrecognised keyword is NONE, not NORMAL: the keyword arm runs
        // and matches nothing, and the field keeps its initial value.
        .{ .keyword = "nonsense", .expect = constants.JANET_BINDING_DEP_NONE },
    };

    for (cases) |case| {
        const entry = tables.new(2);
        tables.put(entry, value.fromBytes("value", .keyword), wrap.fromNil());
        tables.put(entry, value.fromBytes("deprecated", .keyword), value.fromBytes(std.mem.span(case.keyword), .keyword));
        assert(bindingOf(entry).deprecation == case.expect);
    }

    // A non-keyword that is not nil is NORMAL, whatever it is -- including
    // `false`, which is not nil.
    var entry = tables.new(2);
    tables.put(entry, value.fromBytes("value", .keyword), wrap.fromNil());
    tables.put(entry, value.fromBytes("deprecated", .keyword), wrap.fromFalse());
    assert(bindingOf(entry).deprecation == constants.JANET_BINDING_DEP_NORMAL);

    entry = tables.new(2);
    tables.put(entry, value.fromBytes("value", .keyword), wrap.fromNil());
    tables.put(entry, value.fromBytes("deprecated", .keyword), harness.wrapInteger(1));
    assert(bindingOf(entry).deprecation == constants.JANET_BINDING_DEP_NORMAL);
}

// ------------------------------------------------------------- resolution

fn resolveDereferencesOnlyTheDynamicBindings() raise.Raising(void) {
    const env = tables.new(4);
    var out = wrap.fromTrue();
    const ref = arrays.new(1);

    // An unbound symbol answers NONE and writes nil, rather than leaving the
    // caller's value alone.
    assert(registry_mod.resolve(env, symbols.csymbol("missing"), &out) == constants.JANET_BINDING_NONE);
    assert(harness.isType(out, constants.JANET_NIL));

    registry_mod.def(env, "d", harness.wrapInteger(3), null);
    assert(registry_mod.resolve(env, symbols.csymbol("d"), &out) == constants.JANET_BINDING_DEF);
    assert(harness.integerIs(out, 3));

    // A plain var resolves to the ref *array*, not to its contents: only the
    // two dynamic types are dereferenced. So `janet_resolve` and
    // `janet_resolve_ext` agree here, and differ only below.
    try registry.janet_var_smImpl(env, "v", harness.wrapInteger(4), null, null, 0);
    assert(registry_mod.resolve(env, symbols.csymbol("v"), &out) == constants.JANET_BINDING_VAR);
    assert(harness.isType(out, constants.JANET_ARRAY));
    assert(harness.integerIs(wrap.toArray(out).*.data.?[0], 4));
    assert(harness.isType(registry_mod.resolveExt(env, symbols.csymbol("v")).value, constants.JANET_ARRAY));

    // A dynamic def dereferences to the array's last element.
    harness.arrayPush(ref, harness.wrapInteger(5));
    const entry = tables.new(2);
    tables.put(entry, value.fromBytes("ref", .keyword), wrap.fromArray(ref));
    tables.put(entry, value.fromBytes("redef", .keyword), wrap.fromTrue());
    tables.put(env, value.fromBytes("dd", .symbol), wrap.fromTable(entry));
    assert(registry_mod.resolve(env, symbols.csymbol("dd"), &out) == constants.JANET_BINDING_DYNAMIC_DEF);
    assert(harness.integerIs(out, 5));
    harness.arrayPush(ref, harness.wrapInteger(6));
    assert(registry_mod.resolve(env, symbols.csymbol("dd"), &out) == constants.JANET_BINDING_DYNAMIC_DEF);
    assert(harness.integerIs(out, 6));
}

fn theCoreFormsReachTheCoreEnvironment() void {
    // `janet_resolve_core` and `janet_get_core_table` reach the core
    // environment rather than one the caller built.
    assert(harness.isType(registry_mod.resolveCore("string/find"), constants.JANET_CFUNCTION));
    assert(harness.isType(registry_mod.resolveCore("no-such-binding-17f"), constants.JANET_NIL));

    assert(internal.janet_get_core_table("module/cache") != null);
    assert(internal.janet_get_core_table("no-such-binding-17f") == null);
    // Bound, but not to a table.
    assert(internal.janet_get_core_table("string/find") == null);
}

// -------------------------------------------------- the abstract registry

// Two abstract types with the same name and *different addresses*, which is
// the whole premise of the section below: the registry keys on the name and
// refuses a second type under one that is taken.
//
// **They are `var` rather than `const`, and that is rule 28 for data.** Written
// as two `const`s — which is what a transcription of the C original's two
// `static const JanetAbstractType` gives — their initialisers are identical, so
// every optimize mode above Debug merges them into one address. Registering the
// "different" type then registers the same pointer, which is the no-op case
// asserted just above it, and the refusal never happens: `harness.raised(...).?`
// unwrapped a null and the contract died with `attempt to use null value` under
// `ReleaseSafe`, `ReleaseFast` and `ReleaseSmall`. Debug passed.
//
// Two mutable objects must have distinct addresses, so `var` is the whole fix.
// Nothing writes to either.
var probe_at: AbstractType = .{ .name = "registry/probe" };
var probe_at_same_name: AbstractType = .{ .name = "registry/probe" };

fn theAbstractRegistryRefusesASecondTypeUnderOneName() raise.Raising(void) {
    // The premise, asserted rather than assumed. Without this the merge above
    // shows up as a null unwrap three assertions later, in a message that
    // names neither the types nor the reason.
    assert(abstract_type.stored(&probe_at) != abstract_type.stored(&probe_at_same_name));

    try registry.registerAbstractType(abstract_type.stored(&probe_at));
    assert(registry_mod.getAbstractType(value.fromBytes("registry/probe", .symbol)) ==
        abstract_type.stored(&probe_at));

    // Registering the same type twice is a no-op rather than an error.
    try registry.registerAbstractType(abstract_type.stored(&probe_at));
    assert(registry_mod.getAbstractType(value.fromBytes("registry/probe", .symbol)) ==
        abstract_type.stored(&probe_at));

    // An unregistered name answers null, which is what `janet_unmarshal` turns
    // into "unknown abstract type".
    assert(registry_mod.getAbstractType(value.fromBytes("registry/never", .symbol)) == null);
    assert(registry_mod.getAbstractType(wrap.fromNil()) == null);

    // A *different* type under a name already taken raises. This is the one
    // raise in what was `util.c`, and in the C contract it took a try scope, a
    // flag and four lines to observe.
    const refusal = harness.raised(
        registry.registerAbstractType,
        .{abstract_type.stored(&probe_at_same_name)},
    ).?;
    assert(refusal.signal == constants.JANET_SIGNAL_ERROR);
    assert(refusal.says("cannot register abstract type registry/probe, " ++
        "a type with the same name exists"));

    // The failed registration left the first type in place.
    assert(registry_mod.getAbstractType(value.fromBytes("registry/probe", .symbol)) ==
        abstract_type.stored(&probe_at));
}

// ------------------------------------------------------ text substitution

fn bytesAre(view: types.JanetByteView, expected: []const u8) bool {
    if (view.len != expected.len) return false;
    return std.mem.eql(u8, args_core.viewBytes(view), expected);
}

fn substitutionMemoizesAValueAndCallsACallable() raise.Raising(void) {
    const matched = "ab";

    // A value that is already bytes is used as-is, and the caller's slot is
    // left alone.
    var subst = value.fromBytes("X", .string);
    var view = try registry.textSubstitution(&subst, matched[0..@intCast(2)], null);
    assert(bytesAre(view, "X"));
    assert(harness.isType(subst, constants.JANET_STRING));

    // A value that is not bytes is printed once and the caller's slot is
    // *overwritten* with the string, which is what "memoize" means here: the
    // second call must see a string rather than print again.
    subst = harness.wrapInteger(42);
    view = try registry.textSubstitution(&subst, matched[0..@intCast(2)], null);
    assert(bytesAre(view, "42"));
    assert(harness.isType(subst, constants.JANET_STRING));
    view = try registry.textSubstitution(&subst, matched[0..@intCast(2)], null);
    assert(bytesAre(view, "42"));

    // A cfunction is called with the matched text.
    subst = registry_mod.resolveCore("string/ascii-upper");
    assert(harness.isType(subst, constants.JANET_CFUNCTION));
    view = try registry.textSubstitution(&subst, matched[0..@intCast(2)], null);
    assert(bytesAre(view, "AB"));
    // The slot is *not* memoized for a callable: it must be called again for
    // the next match.
    assert(harness.isType(subst, constants.JANET_CFUNCTION));

    // A raising cfunction. Since Phase 10 Part 17e a builtin records its raise
    // and returns, and this is the fourth place in the tree that invokes a
    // cfunction pointer -- the one 17e's count of three missed. The C contract
    // had to arm a flag to see it; here the substitution is `raise.Raising`
    // and the refusal is the return value.
    var finder = registry_mod.resolveCore("string/find");
    const refusal = harness.raised(
        registry.textSubstitution,
        .{ &finder, matched[0..2], @as(?*types.JanetArray, null) },
    ).?;
    assert(refusal.signal == constants.JANET_SIGNAL_ERROR);
    assert(refusal.beginsWith("arity mismatch"));

    // Extra captures are appended after the matched text. `string/slice` with
    // a start index proves the second argument arrived.
    const extra = arrays.new(1);
    harness.arrayPush(extra, harness.wrapInteger(2));
    subst = registry_mod.resolveCore("string/slice");
    view = try registry.textSubstitution(&subst, "abcd", extra);
    assert(bytesAre(view, "cd"));
}

// ------------------------------------------------------------------ entry

fn body() raise.Raising(void) {
    theRegistryRecordsWhatItWasGiven();
    theSortIsTotalOverDistinctKeys();
    theRegistryGrowsPastItsFloor();
    theFourEntryPointsDefineAndRegister();
    thePrefixingFormsRewriteOnlyTheName();
    try defAndVarBuildDifferentEntries();
    theBindingIsASummaryOfFourKeys();
    deprecationReadsAKeywordAndFallsBackToNormal();
    try resolveDereferencesOnlyTheDynamicBindings();
    theCoreFormsReachTheCoreEnvironment();
    try theAbstractRegistryRefusesASecondTypeUnderOneName();
    try substitutionMemoizesAValueAndCallsACallable();
}

pub fn run() void {
    harness.init();
    body() catch @panic("registry: an entry point raised unexpectedly");
    vm_lifecycle.deinit();

    std.debug.print("registry contract ok\n", .{});
}
