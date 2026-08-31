//! The half of `src/core/util.c` that owns VM state: the cfunction registry,
//! the four registration entry points and the two `janet_core_*` forms beside
//! them, the abstract-type registry, environment bindings and their
//! resolution, and `janet_text_substitution`.
//!
//! `utils.zig` has the other half -- the pure substrate, which raises nowhere
//! and owns nothing. Two boundaries, two selections.
//!
//! ## What this subsystem is for
//!
//! Two tables and one array, and everything here is a way into one of them.
//!
//! `vm.registry.rows` is an array of `JanetCFunRegistry`, one row per builtin,
//! keyed by the cfunction pointer and holding the name, prefix and source
//! location that a stack trace prints. It is *not* a Janet table: the key is a
//! function pointer, the rows are static strings the collector never sees, and
//! it must be readable while the collector runs.
//!
//! `vm.abstract_registry` is a Janet table from type name to
//! `*const AbstractType`, and exists so that `janet_unmarshal` can rebuild an
//! abstract from a name in a byte stream.
//!
//! An environment is an ordinary Janet table from symbol to an entry table,
//! and `janet_binding_from_entry` is the reader that turns one of those entries
//! into the `JanetBinding` the compiler and `janet_resolve` work from.
//!
//! ## Running user code
//!
//! `janet_text_substitution` runs arbitrary Janet code: `janet_call` for a
//! function, and a cfunction pointer for a builtin. The second is invoked
//! through `raise.callCFunction` so that the raise cannot be forgotten -- see
//! the note on `textSubstitution`, which is where Janet's own version was
//! found to be missing exactly that test.

const std = @import("std");
const raise = @import("raise");
const pp_format = @import("pp/format.zig");
const arrays = @import("value/arrays.zig");
const vm_entry = @import("vm/entry.zig");
const config = @import("config");
const tables = @import("value/tables.zig");
const gc_alloc = @import("gc.zig");
const symbols = @import("value/symbols.zig");
const tuples = @import("value/tuples.zig");
const utils = @import("utils.zig");
const wrap = @import("value/helpers/wrap.zig");
const args_core = @import("args.zig");
const fatal = @import("fatal.zig");
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const value = @import("value.zig");
const c = @import("cabi");
const vm_state = @import("vm/lifecycle.zig");
const pp_describe = @import("pp.zig");

// ==========================================================================
// Bindings in an environment
// ==========================================================================

/// Attach documentation and a source map to a binding's entry table.
///
/// Both are optional and independent: a binding with no docstring gets no
/// `:doc`, and one whose source is unknown gets no `:source-map`. The line
/// number is tested rather than the file name because the file alone locates
/// nothing.
fn addMeta(table: *types.JanetTable, doc: ?[*:0]const u8, source_file: ?[*:0]const u8, source_line: i32) void {
    if (doc != null) {
        tables.put(table, value.fromBytes("doc", .keyword), value.fromBytes(std.mem.span(doc.?), .string));
    }
    if (source_file != null and source_line != 0) {
        var triple: [3]repr.Value = .{
            value.fromBytes(std.mem.span(source_file.?), .string),
            wrapInteger(source_line),
            wrapInteger(1),
        };
        const val = wrap.fromTuple(tuples.newFrom(&triple));
        tables.put(table, value.fromBytes("source-map", .keyword), val);
    }
}

/// `janet_wrap_integer`, written out rather than called.
///
/// `janet.h` declares the function beside its macro and `wrap.c` defines it
/// only for the two nanbox layouts, so a tagged build has no such symbol and a
/// Zig caller -- which cannot use the macro -- does not link. `os_files.zig`,
/// `marsh.zig`, `pp_pretty.zig` and `value_access.zig` write it out for the
/// same reason, and `FOUND.md` has the defect.
inline fn wrapInteger(x: i32) repr.Value {
    return wrap.fromNumber(@floatFromInt(x));
}

pub fn defSm(
    env: *types.JanetTable,
    name: [*:0]const u8,
    val: repr.Value,
    doc: ?[*:0]const u8,
    source_file: ?[*:0]const u8,
    source_line: i32,
) callconv(.c) void {
    const subt = tables.new(2);
    tables.put(subt, value.fromBytes("value", .keyword), val);
    addMeta(subt, doc, source_file, source_line);
    tables.put(env, value.fromBytes(std.mem.span(name), .symbol), wrap.fromTable(subt));
}

pub fn def(env: *types.JanetTable, name: [*:0]const u8, val: repr.Value, doc: ?[*:0]const u8) void {
    defSm(env, name, val, doc, null, 0);
}

/// A var differs from a def in one thing: the value lives in a one-element
/// array under `:ref`, so that `set` has somewhere to write.
pub fn defVarSm(
    env: *types.JanetTable,
    name: [*:0]const u8,
    val: repr.Value,
    doc: ?[*:0]const u8,
    source_file: ?[*:0]const u8,
    source_line: i32,
) raise.Raising(void) {
    const array = arrays.new(1);
    const subt = tables.new(2);
    try arrays.push(array, val);
    tables.put(subt, value.fromBytes("ref", .keyword), wrap.fromArray(array));
    addMeta(subt, doc, source_file, source_line);
    tables.put(env, value.fromBytes(std.mem.span(name), .symbol), wrap.fromTable(subt));
}

pub fn defVarAbi(env: *types.JanetTable, name: [*:0]const u8, val: repr.Value, doc: ?[*:0]const u8) void {
    raise.reported(defVarSm(env, name, val, doc, null, 0));
}

pub fn varSmAbi(
    env: *types.JanetTable,
    name: [*:0]const u8,
    val: repr.Value,
    doc: ?[*:0]const u8,
    source_file: ?[*:0]const u8,
    source_line: i32,
) callconv(.c) void {
    raise.reported(defVarSm(env, name, val, doc, source_file, source_line));
}

// ==========================================================================
// The cfunction registry
// ==========================================================================

/// The registry's whole lifecycle, and the reason it is two functions rather
/// than eight assignments in `janet_init` and two in `janet_deinit`.
///
/// **A `janet_deinit` that frees the rows and leaves the three scalars set**
/// makes `registryGet` bisect `null` over a non-zero `count`, and `registryPut`
/// write `rows[count]` through the freed pointer, in the window before the
/// next `janet_init`. It is Janet's, and `FOUND.md` has the entry. It is not
/// fixed in place here; the state is made unsayable instead.
pub fn registryInit(r: *types.Registry) void {
    r.* = .{};
}

/// Release the rows and return the registry to what `registryInit` starts
/// from. The names the rows carry are static and unmanaged, so there is
/// nothing else to free.
pub fn registryDeinit(r: *types.Registry) void {
    utils.free(r.rows.items);
    r.* = .{};
}

/// Sort the registry by cfunction pointer, so that a lookup can bisect it.
///
/// Insertion sort, which is the C original's choice and the right one for the
/// shape of the input: the registry is filled once at startup in whatever order
/// the libraries register, and then appended to rarely.
///
/// Comparing function pointers with `<` is undefined in C unless they are into
/// the same array, and this does the same thing through `@intFromPtr`, which
/// is defined. The order does not have to mean anything --
/// it only has to be consistent with the bisection in `janet_registry_get`.
fn sortRows(r: *types.Registry) void {
    const rows = r.rows.slice();
    var i: usize = 1;
    while (i < rows.len) : (i += 1) {
        const reg = rows[i];
        var j: usize = i;
        while (j > 0) : (j -= 1) {
            if (@intFromPtr(rows[j - 1].cfun) < @intFromPtr(reg.cfun)) break;
            rows[j] = rows[j - 1];
        }
        rows[j] = reg;
    }
    r.dirty = false;
}

/// Record a builtin's metadata against its function pointer.
///
/// The growth is `(count + 1) * 2` with a floor of 512, which the C original's
/// comment explains as sizing "nicely with core by default" -- the core
/// registers a little over three hundred builtins, so the floor means one
/// allocation for the whole startup rather than nine.
///
/// Every string stored here is static and unmanaged; the registry holds
/// pointers into the binary, not into the heap, which is why nothing marks it.
fn putRow(
    r: *types.Registry,
    key: types.JanetCFunction,
    name: ?[*:0]const u8,
    name_prefix: ?[*:0]const u8,
    source_file: ?[*:0]const u8,
    source_line: i32,
) void {
    if (r.rows.count == r.rows.capacity) {
        var newcap = (r.rows.count + 1) * 2;
        if (newcap < 512) newcap = 512;
        const newmem = std.c.realloc(
            @ptrCast(r.rows.items),
            newcap * @sizeOf(types.JanetCFunRegistry),
        ) orelse fatal.outOfMemory();
        r.rows.items = @ptrCast(@alignCast(newmem));
        r.rows.capacity = newcap;
    }
    r.rows.appendAssumingCapacity(.{
        .cfun = key,
        .name = name,
        .name_prefix = name_prefix,
        .source_file = source_file,
        .source_line = source_line,
    });
    r.dirty = true;
}

/// The ambient entry point, which is what `capi.zig` publishes as
/// `janet_registry_put`. A caller with the table already in hand calls `put`.
pub fn registryPut(
    key: types.JanetCFunction,
    name: ?[*:0]const u8,
    name_prefix: ?[*:0]const u8,
    source_file: ?[*:0]const u8,
    source_line: i32,
) callconv(.c) void {
    putRow(&vm_state.current().registry, key, name, name_prefix, source_file, source_line);
}

/// Find a builtin's metadata by its function pointer, or null.
///
/// **The linear scan makes the bisection below it dead code, and that is the C
/// original's, reproduced.** The scan is exhaustive, so a key it does not find
/// is not in the array and the bisection cannot find it either; a key it does
/// find has already been returned. So every lookup is O(n) over three hundred
/// entries, and the sort that `registry_dirty` maintains buys nothing. It is
/// defined behaviour rather than a fault, so it is reproduced and recorded in
/// `FOUND.md` rather than repaired.
fn getRow(r: *types.Registry, key: types.JanetCFunction) ?*types.JanetCFunRegistry {
    if (r.dirty) sortRows(r);

    const rows = r.rows.slice();
    for (rows) |*row| {
        if (row.cfun == key) return row;
    }
    if (rows.len == 0) return null;

    var lo: [*]types.JanetCFunRegistry = rows.ptr;
    var hi: [*]types.JanetCFunRegistry = lo + rows.len;
    while (@intFromPtr(lo) < @intFromPtr(hi)) {
        const span = (@intFromPtr(hi) - @intFromPtr(lo)) / @sizeOf(types.JanetCFunRegistry);
        const mid = lo + span / 2;
        if (mid[0].cfun == key) return &mid[0];
        if (@intFromPtr(mid[0].cfun) > @intFromPtr(key)) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    return null;
}

/// The ambient entry point, which is what `capi.zig` publishes as
/// `janet_registry_get`.
pub fn registryGet(key: types.JanetCFunction) ?*types.JanetCFunRegistry {
    return getRow(&vm_state.current().registry, key);
}

pub fn register(name: ?[*:0]const u8, cfun: types.JanetCFunction) void {
    putRow(&vm_state.current().registry, cfun, name, null, null, 0);
}

// ==========================================================================
// Registering a table of cfunctions
// ==========================================================================

/// A reusable `prefix/suffix` buffer, for the two entry points that prefix
/// every name they define.
///
/// It exists so that registering a hundred functions under one prefix does not
/// allocate a hundred strings: the prefix is written once and only the suffix
/// is rewritten. The storage is Janet's scratch allocator, which is released
/// wholesale at the next collection, so `deinit` is a courtesy rather than a
/// requirement.
const NameBuf = struct {
    buf: [*]u8,
    plen: usize,

    fn init(prefix: [*:0]const u8) NameBuf {
        const plen = std.mem.len(prefix);
        const buf: [*]u8 = @ptrCast(gc_alloc.smalloc(plen + 256) orelse fatal.outOfMemory());
        @memcpy(buf[0..plen], prefix[0..plen]);
        buf[plen] = '/';
        return .{ .buf = buf, .plen = plen };
    }

    fn deinit(self: *NameBuf) void {
        gc_alloc.sfree(self.buf);
    }

    /// The C original reallocates on every call rather than only when the
    /// suffix outgrows the 256 bytes `init` reserved. Reproduced: the scratch
    /// allocator's `realloc` is cheap and the difference is not observable.
    fn name(self: *NameBuf, suffix: [*:0]const u8) [*:0]u8 {
        const slen = std.mem.len(suffix);
        self.buf = @ptrCast(gc_alloc.srealloc(self.buf, self.plen + 2 + slen) orelse
            fatal.outOfMemory());
        @memcpy(self.buf[self.plen + 1 .. self.plen + 1 + slen], suffix[0..slen]);
        self.buf[self.plen + 1 + slen] = 0;
        return @ptrCast(self.buf);
    }
};

/// Check that a pointer survives being wrapped, on the nanbox layouts that
/// steal its low bits.
///
/// The C original's comment is the whole argument for where this is called:
/// "Instead of inserting run-time checks everywhere, we are only doing it
/// during registration which has much less cost". A cfunction pointer and an
/// abstract type pointer are both wrapped as Janet values, and both are
/// registered exactly once.
inline fn checkPointerAlign(p: ?*const anyopaque) void {
    if (config.value_repr != .nanbox_64 or config.nanbox_pointer_shift == 0) return;
    const mask: usize = (@as(usize, 1) << repr.pointer_shift) - 1;
    if (@intFromPtr(p) & mask != 0) {
        fatal.fatal("unaligned pointer wrap - cfunction pointers and abstract types " ++
            "must be aligned with this nanboxing configuration.");
    }
}

/// Registering a table of cfunctions, one row at a time.
///
/// **`DESIGN.md` section 6.** There were four entry points here and Janet
/// writes the loop out four times. They differ along two axes: whether the
/// table carries source locations, and whether each name is prefixed. There is
/// one `Reg`, and `def(env, n, f, doc)` *is* `defSm(env, n, f, doc, null, 0)`,
/// so the narrow arm was the wide one with two nulls written a second way.
/// What is left is one axis and one loop.
///
/// It is a struct rather than a function because a caller that has a C table
/// walks a sentinel and cannot hand over a slice: `capi.zig`'s `janet_cfuns`
/// takes the rows one at a time through `put`, and the name buffer's lifetime
/// is what the type owns.
pub const Installer = struct {
    env: ?*types.JanetTable,
    regprefix: ?[*:0]const u8,
    nb: ?NameBuf,
    /// The table every row goes into, bound once for the whole installation
    /// rather than looked up per row.
    registry: *types.Registry,

    pub fn init(env: ?*types.JanetTable, regprefix: ?[*:0]const u8, prefixed: bool) Installer {
        return .{
            .env = env,
            .regprefix = regprefix,
            .nb = if (prefixed and env != null) NameBuf.init(regprefix.?) else null,
            .registry = &vm_state.current().registry,
        };
    }

    pub fn put(self: *Installer, entry: types.Reg) void {
        const entry_name = entry.name orelse return;
        checkPointerAlign(@ptrCast(entry.cfun));
        const fun = wrap.fromCfunction(entry.cfun);
        if (self.env) |env| {
            const name = if (self.nb) |*nb| nb.name(entry_name) else entry_name;
            defSm(env, name, fun, entry.documentation, entry.source_file, entry.source_line);
        }
        putRow(self.registry, entry.cfun, entry_name, self.regprefix, entry.source_file, entry.source_line);
    }

    pub fn deinit(self: *Installer) void {
        if (self.nb) |*nb| nb.deinit();
    }
};

fn install(env: ?*types.JanetTable, regprefix: ?[*:0]const u8, prefixed: bool, registrations: []const types.Reg) void {
    var it = Installer.init(env, regprefix, prefixed);
    defer it.deinit();
    for (registrations) |entry| it.put(entry);
}

pub fn cfuns(env: ?*types.JanetTable, regprefix: ?[*:0]const u8, registrations: []const types.Reg) void {
    install(env, regprefix, false, registrations);
}

pub fn cfunsPrefix(env: ?*types.JanetTable, regprefix: ?[*:0]const u8, registrations: []const types.Reg) void {
    install(env, regprefix, true, registrations);
}

// ==========================================================================
// The core environment's own registration
// ==========================================================================

// `util.h` defines `janet_core_def_sm` and `janet_core_cfuns_ext` onto
// `janet_def_sm` and `janet_cfuns_ext` in a bootstrap build, and declares these
// two for the runtime. `corefn.zig` picks between them and records why both
// arms are real.
//
// The runtime's forms throw the documentation and the source map away and put
// the bare value, because the binding itself arrived in the image; what they
// build is `janet_core_lookup_table`'s dictionary, which is what
// `janet_unmarshal` resolves the image's symbol references against.

comptime {
    if (!config.bootstrap) {}
}

pub fn coreDefSm(
    env: *types.JanetTable,
    name: [*:0]const u8,
    x: repr.Value,
    p: ?*const anyopaque,
    sf: ?*const anyopaque,
    sl: i32,
) callconv(.c) void {
    _ = p;
    _ = sf;
    _ = sl;
    const key = value.fromBytes(std.mem.span(name), .symbol);
    tables.put(env, key, x);
    if (repr.checkType(x, repr.Tag.cfunction)) {
        putRow(&vm_state.current().registry, wrap.toCfunction(x), name, null, null, 0);
    }
}

pub fn coreCfunsExt(
    env: *types.JanetTable,
    regprefix: ?[*:0]const u8,
    registrations: [*]const types.Reg,
) callconv(.c) void {
    const r = &vm_state.current().registry;
    var entry = registrations;
    while (entry[0].name) |entry_name| : (entry += 1) {
        checkPointerAlign(@ptrCast(entry[0].cfun));
        const fun = wrap.fromCfunction(entry[0].cfun);
        tables.put(env, value.fromBytes(std.mem.span(entry_name), .symbol), fun);
        putRow(
            r,
            entry[0].cfun,
            entry_name,
            regprefix,
            entry[0].source_file,
            entry[0].source_line,
        );
    }
}

// ==========================================================================
// The abstract-type registry
// ==========================================================================

/// Record an abstract type under its name, so that `janet_unmarshal` can find
/// it again.
///
/// Registering the same type twice is allowed and is a no-op in effect;
/// registering a *different* type under a name already taken raises, because
/// the name is what a marshalled abstract carries and two answers to it would
/// make the stream ambiguous.
///
/// This is the one raise in `util.c`, and taking it is what moves the phase's
/// `janet_panic`-sites-in-C count from nine to eight.
pub fn registerAbstractType(at: *const types.AbstractType) raise.Raising(void) {
    checkPointerAlign(at);
    const sym = value.fromBytes(at.name, .symbol);
    const check = tables.get(vm_state.current().abstract_registry.?, sym);
    if (!repr.checkType(check, repr.Tag.nil) and at != @as(*const types.AbstractType, @ptrCast(@alignCast(wrap.toPointer(check))))) {
        return pp_format.panicf(
            "cannot register abstract type %s, a type with the same name exists",
            .{at.name},
        );
    }
    tables.put(vm_state.current().abstract_registry.?, sym, wrap.fromPointer(@constCast(at)));
}

pub const registerAbstractTypeAbi = raise.panicking(registerAbstractType).abi;

pub fn getAbstractType(key: repr.Value) ?*const types.AbstractType {
    const wrapped = tables.get(vm_state.current().abstract_registry.?, key);
    if (repr.checkType(wrapped, repr.Tag.nil)) return null;
    return @ptrCast(@alignCast(wrap.toPointer(wrapped)));
}

// ==========================================================================
// Reading a binding, and resolving a symbol
// ==========================================================================

/// Turn an environment entry into the binding the compiler works from.
///
/// The entry is a table and the binding is a summary of four of its keys.
/// `:redef` is the one that changes the *shape* of the answer: with it a def
/// keeps its value in a one-element array like a var, so that redefining it
/// updates every closure that captured it, and the binding type says
/// `DYNAMIC_DEF` rather than `DEF` to say the value must be dereferenced.
///
/// A `:deprecated` value that is not a keyword is `NORMAL` rather than an
/// error, and an unrecognised keyword is `NONE`. Both are the C original's.
pub fn bindingFromEntry(entry: repr.Value) types.JanetBinding {
    var binding: types.JanetBinding = .{
        .type = constants.JANET_BINDING_NONE,
        .value = wrap.fromNil(),
        .deprecation = constants.JANET_BINDING_DEP_NONE,
    };

    if (!repr.checkType(entry, repr.Tag.table)) return binding;
    const entry_table = wrap.toTable(entry);

    const deprecate = tables.getKeyword(entry_table, "deprecated");
    const macro = repr.truthy(tables.getKeyword(entry_table, "macro"));
    const val = tables.getKeyword(entry_table, "value");
    const ref = tables.getKeyword(entry_table, "ref");

    if (repr.checkType(deprecate, repr.Tag.keyword)) {
        const depkw = wrap.toKeyword(deprecate);
        if (utils.cstrcmp(depkw, "relaxed") == 0) {
            binding.deprecation = constants.JANET_BINDING_DEP_RELAXED;
        } else if (utils.cstrcmp(depkw, "normal") == 0) {
            binding.deprecation = constants.JANET_BINDING_DEP_NORMAL;
        } else if (utils.cstrcmp(depkw, "strict") == 0) {
            binding.deprecation = constants.JANET_BINDING_DEP_STRICT;
        }
    } else if (!repr.checkType(deprecate, repr.Tag.nil)) {
        binding.deprecation = constants.JANET_BINDING_DEP_NORMAL;
    }

    const ref_is_valid = repr.checkType(ref, repr.Tag.array);
    const redef = ref_is_valid and repr.truthy(tables.getKeyword(entry_table, "redef"));

    if (macro) {
        binding.value = if (redef) ref else val;
        binding.type = if (redef) constants.JANET_BINDING_DYNAMIC_MACRO else constants.JANET_BINDING_MACRO;
        return binding;
    }

    if (ref_is_valid) {
        binding.value = ref;
        binding.type = if (redef) constants.JANET_BINDING_DYNAMIC_DEF else constants.JANET_BINDING_VAR;
    } else {
        binding.value = val;
        binding.type = constants.JANET_BINDING_DEF;
    }

    return binding;
}

pub fn resolveExt(env: *types.JanetTable, sym: [*:0]const u8) types.JanetBinding {
    const entry = tables.get(env, wrap.fromSymbol(sym));
    return bindingFromEntry(entry);
}

/// Resolve a symbol to its value, dereferencing the two dynamic forms.
pub fn resolve(env: *types.JanetTable, sym: [*:0]const u8, out: *repr.Value) types.JanetBindingType {
    const binding = resolveExt(env, sym);
    if (binding.type == constants.JANET_BINDING_DYNAMIC_DEF or binding.type == constants.JANET_BINDING_DYNAMIC_MACRO) {
        out.* = arrays.peek(wrap.toArray(binding.value));
    } else {
        out.* = binding.value;
    }
    return binding.type;
}

pub fn resolveCore(name: [*:0]const u8) repr.Value {
    const env = c.janet_core_env(null);
    var out = wrap.fromNil();
    _ = resolve(env, symbols.csymbol(name), &out);
    return out;
}

/// A core binding that is expected to be a table, or null.
///
/// Two ways to answer null and both are silent: the symbol is unbound, or it is
/// bound to something that is not a table. The callers are looking up
/// `module/cache` and its neighbours, which the core always defines, so neither
/// is expected to happen.
pub fn getCoreTable(name: [*:0]const u8) ?*types.JanetTable {
    const env = c.janet_core_env(null);
    var out = wrap.fromNil();
    const bt = resolve(env, symbols.csymbol(name), &out);
    if (bt == constants.JANET_BINDING_NONE) return null;
    if (!repr.checkType(out, repr.Tag.table)) return null;
    return wrap.toTable(out);
}

// ==========================================================================
// Text substitution
// ==========================================================================

/// A byte view over `value`, replacing it with its printed form if it has none.
///
/// The replacement is what "memoize" means here: the caller's `Janet` is
/// overwritten with the string, so a substitution used against many matches is
/// printed once. The returned view points into that string, so the caller's
/// slot is what keeps it alive.
fn memoizeByteView(val: *repr.Value) types.JanetByteView {
    var result: types.JanetByteView = undefined;
    if (args_core.bytesView(val.*, &result.bytes, &result.len) == 0) {
        const str = pp_describe.toString(val.*);
        val.* = wrap.fromString(str);
        result.bytes = str;
        result.len = types.stringHead(str).length;
    }
    return result;
}

/// The same, for a value the caller does not own a slot for.
///
/// The view points into a string only the collector holds, which is safe
/// because the caller copies out of it before the next allocation. That is a
/// property of the two callers rather than of this function.
fn toByteView(val: repr.Value) types.JanetByteView {
    var result: types.JanetByteView = undefined;
    if (args_core.bytesView(val, &result.bytes, &result.len) == 0) {
        const str = pp_describe.toString(val);
        result.bytes = str;
        result.len = types.stringHead(str).length;
    }
    return result;
}

/// Compute one substitution for `string/replace`, `string/replace-all` and the
/// PEG engine's `replace`.
///
/// A function or a builtin is *called* with the matched text and any extra
/// captures; anything else is used as a value. So `(string/replace "a" f s)`
/// runs `f` per match and `(string/replace "a" "b" s)` does not.
///
/// **The cfunction call goes through `raise.callCFunction`, and Janet's does
/// not.** Without the test a raising substitution is carried past this frame
/// and reported against whichever builtin called it, and the remaining matches
/// are substituted with nil in the meantime.
pub fn textSubstitution(
    subst: *repr.Value,
    bytes: []const u8,
    extra_argv: ?*types.JanetArray,
) raise.Raising(types.JanetByteView) {
    const extra_argc: i32 = if (extra_argv == null) 0 else extra_argv.?.count;
    const value_type = repr.typeOf(subst.*);
    switch (value_type) {
        repr.Tag.function, repr.Tag.cfunction => {
            const argc = 1 + extra_argc;
            const argv = tuples.begin(argc);
            argv[0] = value.fromBytes(bytes, .string);
            var i: i32 = 0;
            while (i < extra_argc) : (i += 1) {
                argv[@intCast(i + 1)] = extra_argv.?.slice()[@intCast(i)];
            }
            _ = tuples.end(argv);
            if (value_type == repr.Tag.function) {
                // `janet_call` still raises by jumping, which is why this file
                // is jump-transparent. It converts with the rest of the entry
                // points above the interpreter.
                return toByteView(try vm_entry.call(wrap.toFunction(subst.*), argv[0..@intCast(argc)]));
            }
            return toByteView(try raise.cfunction(wrap.toCfunction(subst.*))(argv[0..@intCast(argc)]));
        },
        else => return memoizeByteView(subst),
    }
}
