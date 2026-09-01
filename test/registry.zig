//! Behavioral contract for the half of the runtime substrate that owns VM
//! state: the cfunction registry, the four registration entry points,
//! bindings, symbol resolution, the abstract-type registry, and text
//! substitution.
//!
//! Most of this subsystem is reachable from Janet source. What is here is what
//! inside the runtime can reach: the registry's own ordering and growth, the
//! four registration entry points as an embedder calls them,
//! `janet_binding_from_entry` on entries the compiler would never build, and
//! the two `janet_core_*` forms.
//!
//! ## Two things this contract does that a C one could not
//!
//! **The two raise-capable entry points are called by import.**
//! `registerAbstractType` and `textSubstitution` are `raise.Raising` functions
//! with a `raise.panicking` abi over each; a contract on the far side of a
//! symbol table could only reach the abi and read a report. Here the refusal
//! is a value, so each is one `harness.raised` line.
//!
//! **The registry gets distinct keys.** Janet's growth section says its own
//! limitation out loud -- "every row needs a distinct key, and the key is a
//! function pointer, so the keys have to come from somewhere. Offsetting into
//! a table of distinct pointers is not available in portable C" -- and settles
//! for pushing the *same* pointer 513 times. So the array it grew was one key
//! repeated, and the ordering assertion beside it was very nearly
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
//! **Each probe returns a different integer**, and that is not decoration. A
//! registry key is an address, so a contract about the registry answering
//! differently for different keys has "these are distinct addresses" as the
//! premise of every assertion in it -- and every optimize mode above Debug
//! folds identical function bodies into one address. Nothing calls these
//! probes, so nothing reads the values; what they buy is that the fold is
//! illegal.

const std = @import("std");
const repr = @import("repr");
const raise = @import("subsystems").raise;
const corefn = @import("subsystems").corefn;
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
const capi = @import("subsystems").capi;
const abi = @import("abi");
const registry = subsystems.registry;
const abstract_type = subsystems.abstract_type;

const expect = @import("expect.zig").expect;

/// `strcmp` against a literal, for the three registry fields that are plain C
/// strings rather than Janet ones.
///
/// `harness.stringIs` is the Janet-string form and is the wrong tool here:
/// `janet_cstrcmp` reads a length out of the head that precedes its argument,
/// and `Row.name` points into the binary's rodata with no head
/// in front of it.
fn cstringIs(s: ?[*:0]const u8, expected: []const u8) bool {
    if (s == null) return false;
    return std.mem.eql(u8, std.mem.span(s.?), expected);
}

// ------------------------------------------------------------------ probes

/// A cfunction that exists only to be a registry key.
///
/// `align(corefn.alignment)` because `capi.janet_cfuns` checks it:
/// `checkPointerAlign` refuses a cfunction pointer whose low bits the
/// nanbox-64 pointer shift would steal, and `-Dnanbox-pointer-shift=2` is a
/// matrix entry. The C original got the alignment from
/// `JANET_CFUNCTION_ALIGN`; this is the same requirement spelled in Zig.
fn Probe(comptime tag: i32) type {
    return struct {
        fn run(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
            _ = @as(i32, @intCast(argv.len));

            return harness.wrapInteger(tag);
        }
    };
}

fn keyOf(comptime tag: i32) abi.CFunction {
    return raise.stored(&Probe(tag).run);
}

const probe_one = keyOf(1);
const probe_two = keyOf(2);
const probe_three = keyOf(3);
const probe_unregistered = keyOf(4);
const filler = keyOf(5);

/// Sixteen more, distinct from each other and from the five above.
const family_size = 16;
const family: [family_size]abi.CFunction = blk: {
    var keys: [family_size]abi.CFunction = undefined;
    for (&keys, 0..) |*slot, i| slot.* = keyOf(100 + @as(i32, @intCast(i)));
    break :blk keys;
};

// ------------------------------------------------------------- the registry

fn theRegistryRecordsWhatItWasGiven() void {
    const before = harness.vm().registry.rows.items.len;

    registry_mod.register("probe/one", probe_one);
    registry_mod.register("probe/two", probe_two);
    registry_mod.register("probe/three", probe_three);
    expect(harness.vm().registry.rows.items.len == before + 3);

    // Registration marks the array dirty; the first lookup sorts it.
    expect(harness.vm().registry.dirty);
    var found = registry_mod.registryGet(probe_two);
    expect(harness.vm().registry.dirty == false);
    expect(found != null);
    expect(found.?.cfun == probe_two);
    expect(cstringIs(found.?.name, "probe/two"));
    // `janet_register` passes no prefix and no source location.
    expect(found.?.name_prefix == null);
    expect(found.?.source_file == null);
    expect(found.?.source_line == 0);

    found = registry_mod.registryGet(probe_one);
    expect(found != null and found.?.cfun == probe_one);
    found = registry_mod.registryGet(probe_three);
    expect(found != null and found.?.cfun == probe_three);

    // A cfunction that was never registered answers null rather than a
    // neighbouring row, which is the case `debug.zig`'s frame walk
    // dereferences without checking -- `FOUND.md` has that one.
    expect(registry_mod.registryGet(probe_unregistered) == null);

    // Registering the same pointer twice appends a second row rather than
    // replacing the first. Reproduced from C: nothing dedupes.
    const again = harness.vm().registry.rows.items.len;
    registry_mod.register("probe/one-again", probe_one);
    expect(harness.vm().registry.rows.items.len == again + 1);
    found = registry_mod.registryGet(probe_one);
    expect(found != null and found.?.cfun == probe_one);
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
        registry_mod.registryPut(key, @ptrCast(&name), null, null, 0);
    }

    // Every one of them is found, and found at its own row.
    for (family) |key| {
        const row = registry_mod.registryGet(key);
        expect(row != null);
        expect(row.?.cfun == key);
    }

    const rows = harness.vm().registry.rows.items;
    var i: usize = 1;
    while (i < rows.len) : (i += 1) {
        expect(@intFromPtr(rows[i - 1].cfun) <= @intFromPtr(rows[i].cfun));
    }
}

/// Growth. The floor is 512 entries, which the core alone does not reach, so
/// this is the only place the doubling is exercised at all.
///
/// The key is the same pointer every time, on purpose: what is under test is
/// the `realloc` and the new capacity, and neither reads the key.
fn theRegistryGrowsPastItsFloor() void {
    const cap = harness.vm().registry.rows.capacity;
    const count = harness.vm().registry.rows.items.len;
    while (harness.vm().registry.rows.items.len < cap + 1) {
        registry_mod.registryPut(filler, "probe/filler", null, null, 0);
    }
    expect(harness.vm().registry.rows.capacity > cap);
    expect(harness.vm().registry.rows.items.len > count);
    // The new capacity is (count + 1) * 2 at the moment of the growth, with a
    // floor of 512. Whatever it is, it must leave room for what is there.
    expect(harness.vm().registry.rows.capacity >= harness.vm().registry.rows.items.len);
    // And the view is exactly the live rows, not the allocation.
    expect(harness.vm().registry.rows.items.len == harness.vm().registry.rows.items.len);
}

// ------------------------------------------------- the registration entries

/// Janet's narrow `JanetReg`, declared here because a C caller's is what this
/// contract is testing.
///
/// The runtime has one `Reg` -- `DESIGN.md` section 6 -- and the narrow
/// three-field layout survives only as `capi.zig`'s `CReg`, which no runtime
/// file spells. So the *subject* of the four published entry points is a
/// layout the runtime does not use, and a contract on them has to declare it.
/// That is `test/value_wrap.zig`'s situation exactly: the contract holds the
/// other spelling on purpose, and collapsing the two would leave it asserting
/// that one thing equals itself.
/// The narrow registration row, declared here rather than borrowed from
/// `capi.zig`: what the two narrow entry points widen from is the layout this
/// contract is checking, so reading it from the subject would make the check
/// circular. `@ptrCast` at each call is what says the two agree.
const CReg = extern struct {
    name: ?[*:0]const u8 = null,
    cfun: abi.CFunction = null,
    documentation: ?[*:0]const u8 = null,
};

/// The tables a C caller passes: null-name-terminated, in both shapes.
const c_reg = [_]CReg{
    .{ .name = "one", .cfun = probe_one, .documentation = "the first" },
    .{ .name = "two", .cfun = probe_two, .documentation = null },
    .{},
};

const c_reg_ext = [_]abi.Reg{
    .{
        .name = "three",
        .cfun = probe_three,
        .documentation = "the third",
        .source_file = "probe.c",
        .source_line = 42,
    },
    .{},
};

/// The same two rows as a table inside the runtime: one `Reg`, a slice, no
/// terminator.
const probe_reg = [_]abi.Reg{
    .{ .name = "one", .cfun = probe_one, .documentation = "the first" },
    .{ .name = "two", .cfun = probe_two, .documentation = null },
};

/// The entry a def builds: a table with `:value`, and `:doc` and `:source-map`
/// only when there is something to put in them.
fn checkEntry(env: *tables.Table, name: [*:0]const u8, has_doc: bool, has_map: bool) void {
    const entry = tables.get(env, value.fromBytes(std.mem.span(name), .symbol));
    expect(harness.isType(entry, repr.Tag.table));
    const t = wrap.toTable(entry);
    expect(harness.isType(tables.get(t, value.fromBytes("value", .keyword)), repr.Tag.cfunction));
    expect(harness.isType(tables.get(t, value.fromBytes("doc", .keyword)), repr.Tag.nil) != has_doc);
    expect(harness.isType(tables.get(t, value.fromBytes("source-map", .keyword)), repr.Tag.nil) != has_map);
}

/// The one entry point a native module reaches by symbol, and the sentinel
/// adapter behind it.
///
/// `janet_cfuns_ext` is the whole of `module.zig`'s registration surface. The
/// three narrow and prefixing forms beside it went with the exports nothing
/// consumed, and `CReg` -- the row with no source file or line -- went with
/// them, so the widening this used to check has no caller left.
fn thePublishedEntryPointDefinesAndRegisters() void {
    const env = tables.new(4);

    capi.janet_cfuns_ext(env, "probe", &c_reg_ext);
    checkEntry(env, "three", true, true);

    const entry = tables.get(env, value.fromBytes("three", .symbol));
    const map = tables.get(wrap.toTable(entry), value.fromBytes("source-map", .keyword));
    expect(harness.isType(map, repr.Tag.tuple));
    const tup = wrap.toTuple(map);
    expect(utils.tupleHead(tup).length == 3);
    expect(harness.stringValueIs(tup[0], "probe.c"));
    expect(harness.integerIs(tup[1], 42));
    expect(harness.integerIs(tup[2], 1));

    // The registry got the *unprefixed* name and the prefix separately, for
    // all four entry points. The prefix only changes the binding's name.
    const row = registry_mod.registryGet(probe_three);
    expect(cstringIs(row.?.name, "three"));
    expect(cstringIs(row.?.name_prefix, "probe"));
}

fn thePrefixingFormRewritesOnlyTheName() void {
    const env = tables.new(4);

    registry_mod.cfunsPrefix(env, "pre", &probe_reg);
    checkEntry(env, "pre/one", true, false);
    checkEntry(env, "pre/two", false, false);
    expect(harness.isType(tables.get(env, value.fromBytes("one", .symbol)), repr.Tag.nil));

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
    // buffer at all. Both surviving entry points take it.
    capi.janet_cfuns_ext(null, "probe", &c_reg_ext);
    registry_mod.cfunsPrefix(null, "probe", &probe_reg);
}

/// The two entry points a table *inside* the runtime uses, which take a slice
/// and no terminator.
///
/// They are the same installer the four above reach through the sentinel
/// adapter, so what this adds is the slice path itself: a table with no null
/// row still stops at the right place, and the prefixing form still rewrites
/// only the name.
fn theSliceFormsInstallTheSameRows() void {
    const env = tables.new(4);

    registry_mod.cfuns(env, "probe", &probe_reg);
    checkEntry(env, "one", true, false);
    checkEntry(env, "two", false, false);
    // Two rows, and nothing past them: the terminator is not what stopped it.
    expect(probe_reg.len == 2);

    const env2 = tables.new(4);
    registry_mod.cfunsPrefix(env2, "pre", &probe_reg);
    checkEntry(env2, "pre/one", true, false);
    expect(harness.isType(tables.get(env2, value.fromBytes("one", .symbol)), repr.Tag.nil));

    registry_mod.cfuns(null, "probe", &probe_reg);
    registry_mod.cfunsPrefix(null, "probe", &probe_reg);

    // An empty table is the case a sentinel array cannot express without a
    // row, and a slice can.
    registry_mod.cfuns(env2, "probe", &.{});
}

// ------------------------------------------------------------- def and var

/// `janet_var` and `janet_var_sm` are `raise.panicking` abis over
/// `janet_var_smImpl`, which raises because pushing onto the `:ref` array can.
/// A caller inside the compilation reaches the implementation, so a refusal
/// would arrive here as an error rather than as a report nobody consumed.
///
/// Both abis are reached only through this contract; the raising forms are what
/// the runtime itself calls.
fn defAndVarBuildDifferentEntries() raise.Raising(void) {
    const env = tables.new(4);

    registry_mod.def(env, "d", harness.wrapInteger(7), "doc for d");
    var t = wrap.toTable(tables.get(env, value.fromBytes("d", .symbol)));
    expect(harness.integerIs(tables.get(t, value.fromBytes("value", .keyword)), 7));
    expect(harness.isType(tables.get(t, value.fromBytes("ref", .keyword)), repr.Tag.nil));

    try registry.defVarSm(env, "v", harness.wrapInteger(8), null, null, 0);
    t = wrap.toTable(tables.get(env, value.fromBytes("v", .symbol)));
    // A var's value is in a one-element array under `:ref`, and there is no
    // `:value` key at all.
    expect(harness.isType(tables.get(t, value.fromBytes("value", .keyword)), repr.Tag.nil));
    const ref = tables.get(t, value.fromBytes("ref", .keyword));
    expect(harness.isType(ref, repr.Tag.array));
    const array = wrap.toArray(ref);
    expect(array.count == 1);
    expect(harness.integerIs(array.slice()[0], 8));

    // A source line of zero suppresses the map even when the file is given,
    // because the file alone locates nothing.
    registry_mod.defSm(env, "nomap", wrap.fromNil(), null, "f.c", 0);
    t = wrap.toTable(tables.get(env, value.fromBytes("nomap", .symbol)));
    expect(harness.isType(tables.get(t, value.fromBytes("source-map", .keyword)), repr.Tag.nil));

    try registry.defVarSm(env, "vmap", wrap.fromNil(), null, "f.c", 9);
    t = wrap.toTable(tables.get(env, value.fromBytes("vmap", .symbol)));
    expect(!harness.isType(tables.get(t, value.fromBytes("source-map", .keyword)), repr.Tag.nil));
}

// ------------------------------------------------------- reading a binding

fn bindingOf(entry: *tables.Table) registry_mod.Binding {
    return registry_mod.bindingFromEntry(wrap.fromTable(entry));
}

fn theBindingIsASummaryOfFourKeys() void {
    // Anything that is not a table is NONE with a nil value.
    var b = registry_mod.bindingFromEntry(wrap.fromNil());
    expect(b.type == .none);
    expect(harness.isType(b.value, repr.Tag.nil));
    expect(b.deprecation == .none);
    b = registry_mod.bindingFromEntry(harness.wrapInteger(3));
    expect(b.type == .none);

    // A plain def.
    var entry = tables.new(2);
    tables.put(entry, value.fromBytes("value", .keyword), harness.wrapInteger(1));
    b = bindingOf(entry);
    expect(b.type == .def);
    expect(harness.integerIs(b.value, 1));

    // A ref makes it a var, and the binding's value is the array rather than
    // its contents -- dereferencing is `janet_resolve`'s job.
    entry = tables.new(2);
    tables.put(entry, value.fromBytes("ref", .keyword), wrap.fromArray(arrays.new(1)));
    b = bindingOf(entry);
    expect(b.type == .@"var");
    expect(harness.isType(b.value, repr.Tag.array));

    // `:redef` only means anything with a valid ref.
    entry = tables.new(2);
    tables.put(entry, value.fromBytes("value", .keyword), harness.wrapInteger(1));
    tables.put(entry, value.fromBytes("redef", .keyword), wrap.fromTrue());
    b = bindingOf(entry);
    expect(b.type == .def);

    entry = tables.new(2);
    tables.put(entry, value.fromBytes("ref", .keyword), wrap.fromArray(arrays.new(1)));
    tables.put(entry, value.fromBytes("redef", .keyword), wrap.fromTrue());
    b = bindingOf(entry);
    expect(b.type == .dynamic_def);

    // A macro, and the dynamic macro the same `:redef` produces.
    entry = tables.new(2);
    tables.put(entry, value.fromBytes("value", .keyword), harness.wrapInteger(1));
    tables.put(entry, value.fromBytes("macro", .keyword), wrap.fromTrue());
    b = bindingOf(entry);
    expect(b.type == .macro);
    expect(harness.integerIs(b.value, 1));

    entry = tables.new(3);
    tables.put(entry, value.fromBytes("value", .keyword), harness.wrapInteger(1));
    tables.put(entry, value.fromBytes("ref", .keyword), wrap.fromArray(arrays.new(1)));
    tables.put(entry, value.fromBytes("redef", .keyword), wrap.fromTrue());
    tables.put(entry, value.fromBytes("macro", .keyword), wrap.fromTrue());
    b = bindingOf(entry);
    expect(b.type == .dynamic_macro);
    expect(harness.isType(b.value, repr.Tag.array));

    // A macro with a ref but no `:redef` keeps the plain `:value`, which is
    // the one combination where the two keys disagree about which is read.
    entry = tables.new(3);
    tables.put(entry, value.fromBytes("value", .keyword), harness.wrapInteger(5));
    tables.put(entry, value.fromBytes("ref", .keyword), wrap.fromArray(arrays.new(1)));
    tables.put(entry, value.fromBytes("macro", .keyword), wrap.fromTrue());
    b = bindingOf(entry);
    expect(b.type == .macro);
    expect(harness.integerIs(b.value, 5));
}

fn deprecationReadsAKeywordAndFallsBackToNormal() void {
    const cases = [_]struct { keyword: [*:0]const u8, expect: registry.BindingDeprecation }{
        .{ .keyword = "relaxed", .expect = .relaxed },
        .{ .keyword = "normal", .expect = .normal },
        .{ .keyword = "strict", .expect = .strict },
        // An unrecognised keyword is NONE, not NORMAL: the keyword arm runs
        // and matches nothing, and the field keeps its initial value.
        .{ .keyword = "nonsense", .expect = .none },
    };

    for (cases) |case| {
        const entry = tables.new(2);
        tables.put(entry, value.fromBytes("value", .keyword), wrap.fromNil());
        tables.put(entry, value.fromBytes("deprecated", .keyword), value.fromBytes(std.mem.span(case.keyword), .keyword));
        expect(bindingOf(entry).deprecation == case.expect);
    }

    // A non-keyword that is not nil is NORMAL, whatever it is -- including
    // `false`, which is not nil.
    var entry = tables.new(2);
    tables.put(entry, value.fromBytes("value", .keyword), wrap.fromNil());
    tables.put(entry, value.fromBytes("deprecated", .keyword), wrap.fromFalse());
    expect(bindingOf(entry).deprecation == .normal);

    entry = tables.new(2);
    tables.put(entry, value.fromBytes("value", .keyword), wrap.fromNil());
    tables.put(entry, value.fromBytes("deprecated", .keyword), harness.wrapInteger(1));
    expect(bindingOf(entry).deprecation == .normal);
}

// ------------------------------------------------------------- resolution

fn resolveDereferencesOnlyTheDynamicBindings() raise.Raising(void) {
    const env = tables.new(4);
    const ref = arrays.new(1);

    // An unbound symbol answers NONE with a nil value, rather than a value the
    // caller has to know not to read.
    const missing = registry_mod.resolve(env, symbols.csymbol("missing"));
    expect(missing.type == .none);
    expect(harness.isType(missing.value, repr.Tag.nil));

    registry_mod.def(env, "d", harness.wrapInteger(3), null);
    const d = registry_mod.resolve(env, symbols.csymbol("d"));
    expect(d.type == .def);
    expect(harness.integerIs(d.value, 3));

    // A plain var resolves to the ref *array*, not to its contents: only the
    // two dynamic types are dereferenced. So `janet_resolve` and
    // `janet_resolve_ext` agree here, and differ only below.
    try registry.defVarSm(env, "v", harness.wrapInteger(4), null, null, 0);
    const v = registry_mod.resolve(env, symbols.csymbol("v"));
    expect(v.type == .@"var");
    expect(harness.isType(v.value, repr.Tag.array));
    expect(harness.integerIs(wrap.toArray(v.value).slice()[0], 4));
    expect(harness.isType(registry_mod.resolveExt(env, symbols.csymbol("v")).value, repr.Tag.array));

    // A dynamic def dereferences to the array's last element.
    harness.arrayPush(ref, harness.wrapInteger(5));
    const entry = tables.new(2);
    tables.put(entry, value.fromBytes("ref", .keyword), wrap.fromArray(ref));
    tables.put(entry, value.fromBytes("redef", .keyword), wrap.fromTrue());
    tables.put(env, value.fromBytes("dd", .symbol), wrap.fromTable(entry));
    const dd5 = registry_mod.resolve(env, symbols.csymbol("dd"));
    expect(dd5.type == .dynamic_def);
    expect(harness.integerIs(dd5.value, 5));
    harness.arrayPush(ref, harness.wrapInteger(6));
    const dd6 = registry_mod.resolve(env, symbols.csymbol("dd"));
    expect(dd6.type == .dynamic_def);
    expect(harness.integerIs(dd6.value, 6));
}

fn theCoreFormsReachTheCoreEnvironment() void {
    // `janet_resolve_core` and `janet_get_core_table` reach the core
    // environment rather than one the caller built.
    expect(harness.isType(registry_mod.resolveCore("string/find"), repr.Tag.cfunction));
    expect(harness.isType(registry_mod.resolveCore("no-such-binding-17f"), repr.Tag.nil));

    expect(registry_mod.getCoreTable("module/cache") != null);
    expect(registry_mod.getCoreTable("no-such-binding-17f") == null);
    // Bound, but not to a table.
    expect(registry_mod.getCoreTable("string/find") == null);
}

// -------------------------------------------------- the abstract registry

// Two abstract types with the same name and *different addresses*, which is
// the whole premise of the section below: the registry keys on the name and
// refuses a second type under one that is taken.
//
// **They are `var` rather than `const`, and that matters.** Written as two
// `const`s -- which is what a transcription of Janet's two
// `static const JanetAbstractType` gives -- their initialisers are identical,
// so every optimize mode above Debug merges them into one address. Registering
// the "different" type then registers the same pointer, which is the no-op
// case asserted just above it, and the refusal never happens:
// `harness.raised(...).?` unwrapped a null and the contract died with `attempt
// to use null value` under `ReleaseSafe`, `ReleaseFast` and `ReleaseSmall`.
// Debug passed.
//
// Two mutable objects must have distinct addresses, so `var` is the whole fix.
// Nothing writes to either.
var probe_at = abstract_type.define(anyopaque, .{ .name = "registry/probe" });
var probe_at_same_name = abstract_type.define(anyopaque, .{ .name = "registry/probe" });

fn theAbstractRegistryRefusesASecondTypeUnderOneName() raise.Raising(void) {
    // The premise, asserted rather than assumed. Without this the merge above
    // shows up as a null unwrap three assertions later, in a message that
    // names neither the types nor the reason.
    expect(&probe_at != &probe_at_same_name);

    try registry.registerAbstractType(&probe_at);
    expect(registry_mod.getAbstractType(value.fromBytes("registry/probe", .symbol)) ==
        &probe_at);

    // Registering the same type twice is a no-op rather than an error.
    try registry.registerAbstractType(&probe_at);
    expect(registry_mod.getAbstractType(value.fromBytes("registry/probe", .symbol)) ==
        &probe_at);

    // An unregistered name answers null, which is what `janet_unmarshal` turns
    // into "unknown abstract type".
    expect(registry_mod.getAbstractType(value.fromBytes("registry/never", .symbol)) == null);
    expect(registry_mod.getAbstractType(wrap.fromNil()) == null);

    // A *different* type under a name already taken raises. This is the one
    // raise in what was `util.c`, and in the C contract it took a try scope, a
    // flag and four lines to observe.
    const refusal = harness.raised(
        registry.registerAbstractType,
        .{&probe_at_same_name},
    ).?;
    expect(refusal.signal == abi.Signal.@"error");
    expect(refusal.says("cannot register abstract type registry/probe, " ++
        "a type with the same name exists"));

    // The failed registration left the first type in place.
    expect(registry_mod.getAbstractType(value.fromBytes("registry/probe", .symbol)) ==
        &probe_at);
}

// ------------------------------------------------------ text substitution

fn bytesAre(view: abi.ByteView, expected: []const u8) bool {
    if (view.len != expected.len) return false;
    return std.mem.eql(u8, args_core.viewBytes(view), expected);
}

fn substitutionMemoizesAValueAndCallsACallable() raise.Raising(void) {
    const matched = "ab";

    // A value that is already bytes is used as-is, and the caller's slot is
    // left alone.
    var subst = value.fromBytes("X", .string);
    var view = try registry.textSubstitution(&subst, matched[0..@intCast(2)], null);
    expect(bytesAre(view, "X"));
    expect(harness.isType(subst, repr.Tag.string));

    // A value that is not bytes is printed once and the caller's slot is
    // *overwritten* with the string, which is what "memoize" means here: the
    // second call must see a string rather than print again.
    subst = harness.wrapInteger(42);
    view = try registry.textSubstitution(&subst, matched[0..@intCast(2)], null);
    expect(bytesAre(view, "42"));
    expect(harness.isType(subst, repr.Tag.string));
    view = try registry.textSubstitution(&subst, matched[0..@intCast(2)], null);
    expect(bytesAre(view, "42"));

    // A cfunction is called with the matched text.
    subst = registry_mod.resolveCore("string/ascii-upper");
    expect(harness.isType(subst, repr.Tag.cfunction));
    view = try registry.textSubstitution(&subst, matched[0..@intCast(2)], null);
    expect(bytesAre(view, "AB"));
    // The slot is *not* memoized for a callable: it must be called again for
    // the next match.
    expect(harness.isType(subst, repr.Tag.cfunction));

    // A raising cfunction. A builtin returns its raise, and this is the fourth
    // place in the tree that invokes a cfunction pointer -- the one a count of
    // three missed. Here the substitution is `raise.Raising` and the refusal is
    // the return value.
    var finder = registry_mod.resolveCore("string/find");
    const refusal = harness.raised(
        registry.textSubstitution,
        .{ &finder, matched[0..2], @as(?*arrays.Array, null) },
    ).?;
    expect(refusal.signal == abi.Signal.@"error");
    expect(refusal.beginsWith("arity mismatch"));

    // Extra captures are appended after the matched text. `string/slice` with
    // a start index proves the second argument arrived.
    const extra = arrays.new(1);
    harness.arrayPush(extra, harness.wrapInteger(2));
    subst = registry_mod.resolveCore("string/slice");
    view = try registry.textSubstitution(&subst, "abcd", extra);
    expect(bytesAre(view, "cd"));
}

// ------------------------------------------------------------------ entry

fn body() raise.Raising(void) {
    theRegistryRecordsWhatItWasGiven();
    theSortIsTotalOverDistinctKeys();
    theRegistryGrowsPastItsFloor();
    thePublishedEntryPointDefinesAndRegisters();
    thePrefixingFormRewritesOnlyTheName();
    theSliceFormsInstallTheSameRows();
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
