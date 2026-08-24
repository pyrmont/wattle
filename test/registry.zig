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
//! functions with a `raise.panicking` face over each; the C contract could
//! only reach the face and read `janet_contract_raised`. Here the refusal is a
//! value, so each is one `harness.raised` line — and `janet_text_substitution`,
//! declared in `util.h` alone, loses its last caller and goes with this file.
//! That is rule 12 again: the way to find a dead face is to migrate its
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
const abi = @import("abi");
const c = abi.c;
const raise = @import("raise");
const corefn = @import("corefn");
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
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
fn cstringIs(s: [*c]const u8, expected: []const u8) bool {
    if (s == null) return false;
    return std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(s))), expected);
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
        fn run(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
            _ = argc;
            _ = argv;
            return harness.wrapInteger(tag);
        }
    };
}

fn keyOf(comptime tag: i32) c.JanetCFunction {
    return raise.stored(&Probe(tag).run);
}

const probe_one = keyOf(1);
const probe_two = keyOf(2);
const probe_three = keyOf(3);
const probe_unregistered = keyOf(4);
const filler = keyOf(5);

/// Sixteen more, distinct from each other and from the five above.
const family_size = 16;
const family: [family_size]c.JanetCFunction = blk: {
    var keys: [family_size]c.JanetCFunction = undefined;
    for (&keys, 0..) |*slot, i| slot.* = keyOf(100 + @as(i32, @intCast(i)));
    break :blk keys;
};

// ------------------------------------------------------------- the registry

fn theRegistryRecordsWhatItWasGiven() void {
    const before = c.janet_vm.registry_count;

    c.janet_register("probe/one", probe_one);
    c.janet_register("probe/two", probe_two);
    c.janet_register("probe/three", probe_three);
    assert(c.janet_vm.registry_count == before + 3);

    // Registration marks the array dirty; the first lookup sorts it.
    assert(c.janet_vm.registry_dirty != 0);
    var found = internal.janet_registry_get(probe_two);
    assert(c.janet_vm.registry_dirty == 0);
    assert(found != null);
    assert(found.*.cfun == probe_two);
    assert(cstringIs(found.*.name, "probe/two"));
    // `janet_register` passes no prefix and no source location.
    assert(found.*.name_prefix == null);
    assert(found.*.source_file == null);
    assert(found.*.source_line == 0);

    found = internal.janet_registry_get(probe_one);
    assert(found != null and found.*.cfun == probe_one);
    found = internal.janet_registry_get(probe_three);
    assert(found != null and found.*.cfun == probe_three);

    // A cfunction that was never registered answers null rather than a
    // neighbouring row, which is the case `doframe` in `debug_frames.zig`
    // dereferences without checking -- `FOUND.md` has that one.
    assert(internal.janet_registry_get(probe_unregistered) == null);

    // Registering the same pointer twice appends a second row rather than
    // replacing the first. Reproduced from C: nothing dedupes.
    const again = c.janet_vm.registry_count;
    c.janet_register("probe/one-again", probe_one);
    assert(c.janet_vm.registry_count == again + 1);
    found = internal.janet_registry_get(probe_one);
    assert(found != null and found.*.cfun == probe_one);
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
        internal.janet_registry_put(key, &name, null, null, 0);
    }

    // Every one of them is found, and found at its own row.
    for (family) |key| {
        const row = internal.janet_registry_get(key);
        assert(row != null);
        assert(row.*.cfun == key);
    }

    var i: usize = 1;
    while (i < c.janet_vm.registry_count) : (i += 1) {
        const previous = @intFromPtr(c.janet_vm.registry[i - 1].cfun);
        const current = @intFromPtr(c.janet_vm.registry[i].cfun);
        assert(previous <= current);
    }
}

/// Growth. The floor is 512 entries, which the core alone does not reach, so
/// this is the only place the doubling is exercised at all.
///
/// The key is the same pointer every time, on purpose: what is under test is
/// the `realloc` and the new capacity, and neither reads the key.
fn theRegistryGrowsPastItsFloor() void {
    const cap = c.janet_vm.registry_cap;
    const count = c.janet_vm.registry_count;
    while (c.janet_vm.registry_count < cap + 1) {
        internal.janet_registry_put(filler, "probe/filler", null, null, 0);
    }
    assert(c.janet_vm.registry_cap > cap);
    assert(c.janet_vm.registry_count > count);
    // The new capacity is (count + 1) * 2 at the moment of the growth, with a
    // floor of 512. Whatever it is, it must leave room for what is there.
    assert(c.janet_vm.registry_cap >= c.janet_vm.registry_count);
}

// ------------------------------------------------- the registration entries

const probe_reg = [_]c.JanetReg{
    .{ .name = "one", .cfun = probe_one, .documentation = "the first" },
    .{ .name = "two", .cfun = probe_two, .documentation = null },
    .{ .name = null, .cfun = null, .documentation = null },
};

const probe_reg_ext = [_]c.JanetRegExt{
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
fn checkEntry(env: *c.JanetTable, name: [*:0]const u8, has_doc: bool, has_map: bool) void {
    const entry = c.janet_table_get(env, c.janet_csymbolv(name));
    assert(harness.isType(entry, c.JANET_TABLE));
    const t = c.janet_unwrap_table(entry);
    assert(harness.isType(c.janet_table_get(t, c.janet_ckeywordv("value")), c.JANET_CFUNCTION));
    assert(harness.isType(c.janet_table_get(t, c.janet_ckeywordv("doc")), c.JANET_NIL) != has_doc);
    assert(harness.isType(c.janet_table_get(t, c.janet_ckeywordv("source-map")), c.JANET_NIL) != has_map);
}

fn theFourEntryPointsDefineAndRegister() void {
    const env = c.janet_table(4);

    c.janet_cfuns(env, "probe", &probe_reg);
    checkEntry(env, "one", true, false);
    // A NULL docstring means no `:doc` key at all rather than a nil value.
    checkEntry(env, "two", false, false);

    c.janet_cfuns_ext(env, "probe", &probe_reg_ext);
    checkEntry(env, "three", true, true);

    const entry = c.janet_table_get(env, c.janet_csymbolv("three"));
    const map = c.janet_table_get(c.janet_unwrap_table(entry), c.janet_ckeywordv("source-map"));
    assert(harness.isType(map, c.JANET_TUPLE));
    const tup = c.janet_unwrap_tuple(map);
    assert(c.janet_tuple_head(tup).*.length == 3);
    assert(harness.stringValueIs(tup[0], "probe.c"));
    assert(harness.integerIs(tup[1], 42));
    assert(harness.integerIs(tup[2], 1));

    // The registry got the *unprefixed* name and the prefix separately, for
    // all four entry points. The prefix only changes the binding's name.
    const row = internal.janet_registry_get(probe_three);
    assert(cstringIs(row.*.name, "three"));
    assert(cstringIs(row.*.name_prefix, "probe"));
}

fn thePrefixingFormsRewriteOnlyTheName() void {
    const env = c.janet_table(4);

    c.janet_cfuns_prefix(env, "pre", &probe_reg);
    checkEntry(env, "pre/one", true, false);
    checkEntry(env, "pre/two", false, false);
    assert(harness.isType(c.janet_table_get(env, c.janet_csymbolv("one")), c.JANET_NIL));

    c.janet_cfuns_ext_prefix(env, "pre", &probe_reg_ext);
    checkEntry(env, "pre/three", true, true);

    // A prefix long enough that the name buffer's 256-byte reserve is not what
    // carries it, so the realloc in `NameBuf.name` is exercised.
    {
        var big: [400]u8 = @splat('p');
        big[big.len - 1] = 0;
        var expected: [420]u8 = @splat(0);
        const env2 = c.janet_table(4);
        c.janet_cfuns_prefix(env2, &big, &probe_reg);
        _ = std.fmt.bufPrint(&expected, "{s}/one", .{big[0 .. big.len - 1]}) catch unreachable;
        checkEntry(env2, @ptrCast(&expected), true, false);
    }

    // A null environment registers without defining, and must not build a name
    // buffer at all. Every entry point takes it.
    c.janet_cfuns(null, "probe", &probe_reg);
    c.janet_cfuns_ext(null, "probe", &probe_reg_ext);
    c.janet_cfuns_prefix(null, "probe", &probe_reg);
    c.janet_cfuns_ext_prefix(null, "probe", &probe_reg_ext);
}

// ------------------------------------------------------------- def and var

/// `janet_var` and `janet_var_sm` are `raise.panicking` faces over
/// `janet_var_smImpl`, which raises because pushing onto the `:ref` array can.
/// A caller inside the compilation reaches the implementation, so a refusal
/// would arrive here as an error rather than as a report nobody consumed.
///
/// Both faces stay: they are `janet.h`'s public surface. Neither has an
/// in-tree caller any more, which is data for the exported-symbol-surface
/// bullet rather than a deletion — see `janet_register`, `janet_resolve_core`
/// and the two prefixing forms, in the same position.
fn defAndVarBuildDifferentEntries() raise.Raising(void) {
    const env = c.janet_table(4);

    c.janet_def(env, "d", harness.wrapInteger(7), "doc for d");
    var t = c.janet_unwrap_table(c.janet_table_get(env, c.janet_csymbolv("d")));
    assert(harness.integerIs(c.janet_table_get(t, c.janet_ckeywordv("value")), 7));
    assert(harness.isType(c.janet_table_get(t, c.janet_ckeywordv("ref")), c.JANET_NIL));

    try registry.janet_var_smImpl(env, "v", harness.wrapInteger(8), null, null, 0);
    t = c.janet_unwrap_table(c.janet_table_get(env, c.janet_csymbolv("v")));
    // A var's value is in a one-element array under `:ref`, and there is no
    // `:value` key at all.
    assert(harness.isType(c.janet_table_get(t, c.janet_ckeywordv("value")), c.JANET_NIL));
    const ref = c.janet_table_get(t, c.janet_ckeywordv("ref"));
    assert(harness.isType(ref, c.JANET_ARRAY));
    const array = c.janet_unwrap_array(ref);
    assert(array.*.count == 1);
    assert(harness.integerIs(array.*.data[0], 8));

    // A source line of zero suppresses the map even when the file is given,
    // because the file alone locates nothing.
    c.janet_def_sm(env, "nomap", c.janet_wrap_nil(), null, "f.c", 0);
    t = c.janet_unwrap_table(c.janet_table_get(env, c.janet_csymbolv("nomap")));
    assert(harness.isType(c.janet_table_get(t, c.janet_ckeywordv("source-map")), c.JANET_NIL));

    try registry.janet_var_smImpl(env, "vmap", c.janet_wrap_nil(), null, "f.c", 9);
    t = c.janet_unwrap_table(c.janet_table_get(env, c.janet_csymbolv("vmap")));
    assert(!harness.isType(c.janet_table_get(t, c.janet_ckeywordv("source-map")), c.JANET_NIL));
}

// ------------------------------------------------------- reading a binding

fn bindingOf(entry: *c.JanetTable) c.JanetBinding {
    return internal.janet_binding_from_entry(c.janet_wrap_table(entry));
}

fn theBindingIsASummaryOfFourKeys() void {
    // Anything that is not a table is NONE with a nil value.
    var b = internal.janet_binding_from_entry(c.janet_wrap_nil());
    assert(b.type == c.JANET_BINDING_NONE);
    assert(harness.isType(b.value, c.JANET_NIL));
    assert(b.deprecation == c.JANET_BINDING_DEP_NONE);
    b = internal.janet_binding_from_entry(harness.wrapInteger(3));
    assert(b.type == c.JANET_BINDING_NONE);

    // A plain def.
    var entry = c.janet_table(2);
    c.janet_table_put(entry, c.janet_ckeywordv("value"), harness.wrapInteger(1));
    b = bindingOf(entry);
    assert(b.type == c.JANET_BINDING_DEF);
    assert(harness.integerIs(b.value, 1));

    // A ref makes it a var, and the binding's value is the array rather than
    // its contents -- dereferencing is `janet_resolve`'s job.
    entry = c.janet_table(2);
    c.janet_table_put(entry, c.janet_ckeywordv("ref"), c.janet_wrap_array(c.janet_array(1)));
    b = bindingOf(entry);
    assert(b.type == c.JANET_BINDING_VAR);
    assert(harness.isType(b.value, c.JANET_ARRAY));

    // `:redef` only means anything with a valid ref.
    entry = c.janet_table(2);
    c.janet_table_put(entry, c.janet_ckeywordv("value"), harness.wrapInteger(1));
    c.janet_table_put(entry, c.janet_ckeywordv("redef"), c.janet_wrap_true());
    b = bindingOf(entry);
    assert(b.type == c.JANET_BINDING_DEF);

    entry = c.janet_table(2);
    c.janet_table_put(entry, c.janet_ckeywordv("ref"), c.janet_wrap_array(c.janet_array(1)));
    c.janet_table_put(entry, c.janet_ckeywordv("redef"), c.janet_wrap_true());
    b = bindingOf(entry);
    assert(b.type == c.JANET_BINDING_DYNAMIC_DEF);

    // A macro, and the dynamic macro the same `:redef` produces.
    entry = c.janet_table(2);
    c.janet_table_put(entry, c.janet_ckeywordv("value"), harness.wrapInteger(1));
    c.janet_table_put(entry, c.janet_ckeywordv("macro"), c.janet_wrap_true());
    b = bindingOf(entry);
    assert(b.type == c.JANET_BINDING_MACRO);
    assert(harness.integerIs(b.value, 1));

    entry = c.janet_table(3);
    c.janet_table_put(entry, c.janet_ckeywordv("value"), harness.wrapInteger(1));
    c.janet_table_put(entry, c.janet_ckeywordv("ref"), c.janet_wrap_array(c.janet_array(1)));
    c.janet_table_put(entry, c.janet_ckeywordv("redef"), c.janet_wrap_true());
    c.janet_table_put(entry, c.janet_ckeywordv("macro"), c.janet_wrap_true());
    b = bindingOf(entry);
    assert(b.type == c.JANET_BINDING_DYNAMIC_MACRO);
    assert(harness.isType(b.value, c.JANET_ARRAY));

    // A macro with a ref but no `:redef` keeps the plain `:value`, which is
    // the one combination where the two keys disagree about which is read.
    entry = c.janet_table(3);
    c.janet_table_put(entry, c.janet_ckeywordv("value"), harness.wrapInteger(5));
    c.janet_table_put(entry, c.janet_ckeywordv("ref"), c.janet_wrap_array(c.janet_array(1)));
    c.janet_table_put(entry, c.janet_ckeywordv("macro"), c.janet_wrap_true());
    b = bindingOf(entry);
    assert(b.type == c.JANET_BINDING_MACRO);
    assert(harness.integerIs(b.value, 5));
}

fn deprecationReadsAKeywordAndFallsBackToNormal() void {
    const cases = [_]struct { keyword: [*:0]const u8, expect: c_int }{
        .{ .keyword = "relaxed", .expect = c.JANET_BINDING_DEP_RELAXED },
        .{ .keyword = "normal", .expect = c.JANET_BINDING_DEP_NORMAL },
        .{ .keyword = "strict", .expect = c.JANET_BINDING_DEP_STRICT },
        // An unrecognised keyword is NONE, not NORMAL: the keyword arm runs
        // and matches nothing, and the field keeps its initial value.
        .{ .keyword = "nonsense", .expect = c.JANET_BINDING_DEP_NONE },
    };

    for (cases) |case| {
        const entry = c.janet_table(2);
        c.janet_table_put(entry, c.janet_ckeywordv("value"), c.janet_wrap_nil());
        c.janet_table_put(entry, c.janet_ckeywordv("deprecated"), c.janet_ckeywordv(case.keyword));
        assert(bindingOf(entry).deprecation == case.expect);
    }

    // A non-keyword that is not nil is NORMAL, whatever it is -- including
    // `false`, which is not nil.
    var entry = c.janet_table(2);
    c.janet_table_put(entry, c.janet_ckeywordv("value"), c.janet_wrap_nil());
    c.janet_table_put(entry, c.janet_ckeywordv("deprecated"), c.janet_wrap_false());
    assert(bindingOf(entry).deprecation == c.JANET_BINDING_DEP_NORMAL);

    entry = c.janet_table(2);
    c.janet_table_put(entry, c.janet_ckeywordv("value"), c.janet_wrap_nil());
    c.janet_table_put(entry, c.janet_ckeywordv("deprecated"), harness.wrapInteger(1));
    assert(bindingOf(entry).deprecation == c.JANET_BINDING_DEP_NORMAL);
}

// ------------------------------------------------------------- resolution

fn resolveDereferencesOnlyTheDynamicBindings() raise.Raising(void) {
    const env = c.janet_table(4);
    var out = c.janet_wrap_true();
    const ref = c.janet_array(1);

    // An unbound symbol answers NONE and writes nil, rather than leaving the
    // caller's value alone.
    assert(c.janet_resolve(env, c.janet_csymbol("missing"), &out) == c.JANET_BINDING_NONE);
    assert(harness.isType(out, c.JANET_NIL));

    c.janet_def(env, "d", harness.wrapInteger(3), null);
    assert(c.janet_resolve(env, c.janet_csymbol("d"), &out) == c.JANET_BINDING_DEF);
    assert(harness.integerIs(out, 3));

    // A plain var resolves to the ref *array*, not to its contents: only the
    // two dynamic types are dereferenced. So `janet_resolve` and
    // `janet_resolve_ext` agree here, and differ only below.
    try registry.janet_var_smImpl(env, "v", harness.wrapInteger(4), null, null, 0);
    assert(c.janet_resolve(env, c.janet_csymbol("v"), &out) == c.JANET_BINDING_VAR);
    assert(harness.isType(out, c.JANET_ARRAY));
    assert(harness.integerIs(c.janet_unwrap_array(out).*.data[0], 4));
    assert(harness.isType(c.janet_resolve_ext(env, c.janet_csymbol("v")).value, c.JANET_ARRAY));

    // A dynamic def dereferences to the array's last element.
    c.janet_array_push(ref, harness.wrapInteger(5));
    const entry = c.janet_table(2);
    c.janet_table_put(entry, c.janet_ckeywordv("ref"), c.janet_wrap_array(ref));
    c.janet_table_put(entry, c.janet_ckeywordv("redef"), c.janet_wrap_true());
    c.janet_table_put(env, c.janet_csymbolv("dd"), c.janet_wrap_table(entry));
    assert(c.janet_resolve(env, c.janet_csymbol("dd"), &out) == c.JANET_BINDING_DYNAMIC_DEF);
    assert(harness.integerIs(out, 5));
    c.janet_array_push(ref, harness.wrapInteger(6));
    assert(c.janet_resolve(env, c.janet_csymbol("dd"), &out) == c.JANET_BINDING_DYNAMIC_DEF);
    assert(harness.integerIs(out, 6));
}

fn theCoreFormsReachTheCoreEnvironment() void {
    // `janet_resolve_core` and `janet_get_core_table` reach the core
    // environment rather than one the caller built.
    assert(harness.isType(c.janet_resolve_core("string/find"), c.JANET_CFUNCTION));
    assert(harness.isType(c.janet_resolve_core("no-such-binding-17f"), c.JANET_NIL));

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
    assert(c.janet_get_abstract_type(c.janet_csymbolv("registry/probe")) ==
        abstract_type.stored(&probe_at));

    // Registering the same type twice is a no-op rather than an error.
    try registry.registerAbstractType(abstract_type.stored(&probe_at));
    assert(c.janet_get_abstract_type(c.janet_csymbolv("registry/probe")) ==
        abstract_type.stored(&probe_at));

    // An unregistered name answers null, which is what `janet_unmarshal` turns
    // into "unknown abstract type".
    assert(c.janet_get_abstract_type(c.janet_csymbolv("registry/never")) == null);
    assert(c.janet_get_abstract_type(c.janet_wrap_nil()) == null);

    // A *different* type under a name already taken raises. This is the one
    // raise in what was `util.c`, and in the C contract it took a try scope, a
    // flag and four lines to observe.
    const refusal = harness.raised(
        registry.registerAbstractType,
        .{abstract_type.stored(&probe_at_same_name)},
    ).?;
    assert(refusal.signal == c.JANET_SIGNAL_ERROR);
    assert(refusal.says("cannot register abstract type registry/probe, " ++
        "a type with the same name exists"));

    // The failed registration left the first type in place.
    assert(c.janet_get_abstract_type(c.janet_csymbolv("registry/probe")) ==
        abstract_type.stored(&probe_at));
}

// ------------------------------------------------------ text substitution

fn bytesAre(view: c.JanetByteView, expected: []const u8) bool {
    if (view.len != expected.len) return false;
    return std.mem.eql(u8, view.bytes[0..@intCast(view.len)], expected);
}

fn substitutionMemoizesAValueAndCallsACallable() raise.Raising(void) {
    const matched = "ab";

    // A value that is already bytes is used as-is, and the caller's slot is
    // left alone.
    var subst = c.janet_cstringv("X");
    var view = try registry.textSubstitution(&subst, matched, 2, null);
    assert(bytesAre(view, "X"));
    assert(harness.isType(subst, c.JANET_STRING));

    // A value that is not bytes is printed once and the caller's slot is
    // *overwritten* with the string, which is what "memoize" means here: the
    // second call must see a string rather than print again.
    subst = harness.wrapInteger(42);
    view = try registry.textSubstitution(&subst, matched, 2, null);
    assert(bytesAre(view, "42"));
    assert(harness.isType(subst, c.JANET_STRING));
    view = try registry.textSubstitution(&subst, matched, 2, null);
    assert(bytesAre(view, "42"));

    // A cfunction is called with the matched text.
    subst = c.janet_resolve_core("string/ascii-upper");
    assert(harness.isType(subst, c.JANET_CFUNCTION));
    view = try registry.textSubstitution(&subst, matched, 2, null);
    assert(bytesAre(view, "AB"));
    // The slot is *not* memoized for a callable: it must be called again for
    // the next match.
    assert(harness.isType(subst, c.JANET_CFUNCTION));

    // A raising cfunction. Since Phase 10 Part 17e a builtin records its raise
    // and returns, and this is the fourth place in the tree that invokes a
    // cfunction pointer -- the one 17e's count of three missed. The C contract
    // had to arm a flag to see it; here the substitution is `raise.Raising`
    // and the refusal is the return value.
    var finder = c.janet_resolve_core("string/find");
    const refusal = harness.raised(
        registry.textSubstitution,
        .{ &finder, @as([*c]const u8, matched), @as(u32, 2), @as([*c]c.JanetArray, null) },
    ).?;
    assert(refusal.signal == c.JANET_SIGNAL_ERROR);
    assert(refusal.beginsWith("arity mismatch"));

    // Extra captures are appended after the matched text. `string/slice` with
    // a start index proves the second argument arrived.
    const extra = c.janet_array(1);
    c.janet_array_push(extra, harness.wrapInteger(2));
    subst = c.janet_resolve_core("string/slice");
    view = try registry.textSubstitution(&subst, "abcd", 4, extra);
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
    _ = c.janet_init();
    body() catch @panic("registry: an entry point raised unexpectedly");
    c.janet_deinit();

    std.debug.print("registry contract ok\n", .{});
}
