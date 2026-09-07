//! Everything that owns VM state: the cfunction registry, the four
//! registration entry points and the two core forms beside them, the
//! abstract-type registry, environment bindings and their resolution, and the
//! text substitution.
//!
//! `utils.zig` has the other half, the pure substrate, which raises nowhere and
//! owns nothing.
//!
//! Two tables and one array, and everything here is a way into one of them.
//!
//! `vm.registry.rows` is an array of `Row`, one per builtin, keyed by the
//! cfunction pointer, with the name, prefix and source location a stack
//! trace prints. It is not a Janet table: the key is a function pointer, the
//! rows are static strings the collector never sees, and it must be readable
//! while the collector runs.
//!
//! `vm.abstract_registry` is a Janet table from type name to
//! `*const AbstractType`, and exists so that the unmarshaller can rebuild an
//! abstract from a name in a byte stream.
//!
//! An environment is an ordinary Janet table from symbol to an entry table, and
//! `bindingFromEntry` is the reader that turns one of those entries into the
//! `Binding` the compiler and `resolve` work from.
//!
//! `textSubstitution` runs arbitrary Janet code: a call for a function, and a
//! cfunction pointer for a builtin. The second goes through `raise.cfunction`,
//! which is what makes forgetting the raise impossible, and that function's
//! block says what forgetting it costs.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const args_core = @import("args.zig");
const arrays = @import("value/arrays.zig");
const config = @import("config");
const env_core = @import("env.zig");
const fatal = @import("fatal.zig");
const gc_alloc = @import("gc.zig");
const pp_describe = @import("pp.zig");
const pp_format = @import("pp/format.zig");
const raise = @import("../api/raise.zig");
const repr = @import("repr");
const strings = @import("value/strings.zig");
const symbols = @import("value/symbols.zig");
const tables = @import("value/tables.zig");
const tuples = @import("value/tuples.zig");
const utils = @import("utils.zig");
const value = @import("value.zig");
const vm_entry = @import("vm/entry.zig");
const vm_state = @import("vm/state.zig");
const wrap = @import("value/helpers/wrap.zig");

// ==========================================================================
// Types
// ==========================================================================

/// A resolved binding: what kind it is, its value, and its deprecation.
///
/// `bindingFromEntry` produces one and `resolve` dereferences the two dynamic
/// forms. It is `extern` because the published resolution entry points return
/// it by value.
pub const Binding = extern struct {
    type: BindingType = .none,
    value: repr.Value = std.mem.zeroes(repr.Value),
    deprecation: BindingDeprecation = .none,
};

/// `Binding.deprecation`: none, relaxed, normal or strict.
pub const BindingDeprecation = enum(u32) {
    none = 0,
    relaxed = 1,
    normal = 2,
    strict = 3,
};

/// What a resolved binding is.
///
/// `bindingFromEntry` is the only thing that produces one, reading an
/// environment entry's keys and deciding, so nothing outside this runtime can
/// supply a value and the enum is exhaustive. The width is `u32` because
/// `Binding` is `extern`.
pub const BindingType = enum(u32) {
    none = 0,
    def = 1,
    @"var" = 2,
    macro = 3,
    dynamic_def = 4,
    dynamic_macro = 5,
};

/// One installation of a table of cfunctions, one row at a time.
///
/// `env` is the environment to define into, `regprefix` the prefix a row's
/// registry entry records, `nb` the name buffer where names are prefixed, and
/// `registry` the table every row goes into, bound once for the whole
/// installation rather than looked up per row.
///
/// One `Reg` and one loop over one axis, whether each name is prefixed, because
/// `def(env, n, f, doc)` is `defSm(env, n, f, doc, null, 0)`, and a source
/// location the caller does not have is two nulls rather than a second entry
/// point.
///
/// It is a struct rather than a function because a caller with a
/// sentinel-terminated table cannot pass a slice: `capi.zig`'s
/// `janet_cfuns_ext` takes the rows one at a time through `put`, and the name
/// buffer's lifetime is what the type owns.
pub const Installer = struct {
    env: ?*tables.Table,
    regprefix: ?[*:0]const u8,
    nb: ?NameBuf,
    /// The table every row goes into, bound once for the whole installation
    /// rather than looked up per row.
    registry: *Registry,

    pub fn init(env: ?*tables.Table, regprefix: ?[*:0]const u8, prefixed: bool) Installer {
        return .{
            .env = env,
            .regprefix = regprefix,
            .nb = if (prefixed and env != null) NameBuf.init(regprefix.?) else null,
            .registry = &vm_state.current().registry,
        };
    }

    pub fn put(self: *Installer, entry: abi.Reg) void {
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

/// A reusable `prefix/suffix` buffer, for the two entry points that prefix
/// every name they define.
///
/// It exists so that registering many functions under one prefix does not
/// allocate a string each: the prefix is written once and only the suffix is
/// rewritten. The storage is Janet's scratch allocator, which is released
/// wholesale at the next collection, so `deinit` is a courtesy rather than a
/// requirement.
const NameBuf = struct {
    buf: [*]u8,
    plen: usize,

    fn init(prefix: [*:0]const u8) NameBuf {
        const plen = std.mem.len(prefix);
        const buf: [*]u8 = @ptrCast(gc_alloc.smalloc(plen + 256));
        @memcpy(buf[0..plen], prefix[0..plen]);
        buf[plen] = '/';
        return .{ .buf = buf, .plen = plen };
    }

    fn deinit(self: *NameBuf) void {
        gc_alloc.sfree(self.buf);
    }

    /// The realloc runs on every call rather than only when the suffix outgrows
    /// the 256 bytes `init` reserved. The scratch allocator's `realloc` is
    /// cheap and the difference is not observable.
    fn name(self: *NameBuf, suffix: [*:0]const u8) [*:0]u8 {
        const slen = std.mem.len(suffix);
        self.buf = @ptrCast(gc_alloc.srealloc(self.buf, self.plen + 2 + slen) orelse
            fatal.outOfMemory());
        @memcpy(self.buf[self.plen + 1 .. self.plen + 1 + slen], suffix[0..slen]);
        self.buf[self.plen + 1 + slen] = 0;
        return @ptrCast(self.buf);
    }
};

/// The cfunction registry: one row per builtin, sorted by function pointer so
/// that a lookup can bisect. This file owns the lifecycle.
///
/// `dirty` is what says the sort is owed; `registryPut` sets it and `sortRows`
/// clears it. It is the reason this is a struct around a vector rather than a
/// vector: the sortedness is a fourth fact about the rows, and it is not the
/// vector's.
pub const Registry = struct {
    rows: std.ArrayListUnmanaged(Row) = .empty,
    dirty: bool = false,
};

/// One row of the cfunction registry: the pointer, the name and prefix a trace
/// prints, and the source location.
pub const Row = struct {
    cfun: abi.CFunction = null,
    name: ?[*:0]const u8 = null,
    name_prefix: ?[*:0]const u8 = null,
    source_file: ?[*:0]const u8 = null,
    source_line: i32 = 0,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Turns an environment entry into the binding the compiler works from.
///
/// `entry` is the entry table, and the binding is a summary of four of its
/// keys. An entry that is not a table gives a binding of type `.none`.
///
/// `:redef` is the one that changes the shape of the result: with it a def
/// has its value in a one-element array like a var, so that redefining it
/// updates every closure that captured it, and the binding type is
/// `.dynamic_def` rather than `.def` to say the value must be dereferenced.
///
/// A `:deprecated` value that is not a keyword is `.normal` rather than an
/// error, and an unrecognised keyword is `.none`. Both are what a Janet program
/// sees.
pub fn bindingFromEntry(entry: repr.Value) Binding {
    var binding: Binding = .{
        .type = .none,
        .value = wrap.fromNil(),
        .deprecation = .none,
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
            binding.deprecation = .relaxed;
        } else if (utils.cstrcmp(depkw, "normal") == 0) {
            binding.deprecation = .normal;
        } else if (utils.cstrcmp(depkw, "strict") == 0) {
            binding.deprecation = .strict;
        }
    } else if (!repr.checkType(deprecate, repr.Tag.nil)) {
        binding.deprecation = .normal;
    }

    const ref_is_valid = repr.checkType(ref, repr.Tag.array);
    const redef = ref_is_valid and repr.truthy(tables.getKeyword(entry_table, "redef"));

    if (macro) {
        binding.value = if (redef) ref else val;
        binding.type = if (redef) .dynamic_macro else .macro;
        return binding;
    }

    if (ref_is_valid) {
        binding.value = ref;
        binding.type = if (redef) .dynamic_def else .@"var";
    } else {
        binding.value = val;
        binding.type = .def;
    }

    return binding;
}

/// Registers a table of cfunctions, with each name as written.
///
/// `env` is the environment, `regprefix` the prefix a row's registry entry
/// records, and `registrations` the rows.
pub fn cfuns(env: ?*tables.Table, regprefix: ?[*:0]const u8, registrations: []const abi.Reg) void {
    install(env, regprefix, false, registrations);
}

/// The same, with every name prefixed by `regprefix`.
pub fn cfunsPrefix(env: ?*tables.Table, regprefix: ?[*:0]const u8, registrations: []const abi.Reg) void {
    install(env, regprefix, true, registrations);
}

/// The runtime's registration of a sentinel-terminated table.
///
/// `env` is the core lookup dictionary, `regprefix` the prefix a row records
/// and `registrations` a null-name-terminated array. This and `coreDefSm` are
/// the runtime's forms, where `defSm` and `Installer` are the bootstrap's, and
/// `corefn.zig` picks between them and records why both arms are real.
///
/// The runtime's forms drop the documentation and the source map and put the
/// bare value, because the binding itself arrived in the image. What they build
/// is the core lookup dictionary, which is what the unmarshaller resolves the
/// image's symbol references against.
pub fn coreCfunsExt(
    env: *tables.Table,
    regprefix: ?[*:0]const u8,
    registrations: [*]const abi.Reg,
) void {
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

/// The runtime's definition of one core binding.
///
/// `env` is the core lookup dictionary, `name` the binding and `x` its value.
/// `p`, `sf` and `sl` are the documentation and source map the runtime drops;
/// they are parameters so that this and `defSm` have one shape.
pub fn coreDefSm(
    env: *tables.Table,
    name: [*:0]const u8,
    x: repr.Value,
    p: ?*const anyopaque,
    sf: ?*const anyopaque,
    sl: i32,
) void {
    _ = p;
    _ = sf;
    _ = sl;
    const key = value.fromBytes(std.mem.span(name), .symbol);
    tables.put(env, key, x);
    if (repr.checkType(x, repr.Tag.cfunction)) {
        putRow(&vm_state.current().registry, wrap.toCfunction(x), name, null, null, 0);
    }
}

/// Defines a binding with no source map.
///
/// `env` is the environment, `name` the binding, `val` its value and `doc` its
/// documentation.
pub fn def(env: *tables.Table, name: [*:0]const u8, val: repr.Value, doc: ?[*:0]const u8) void {
    defSm(env, name, val, doc, null, 0);
}

/// Defines a binding, with documentation and a source map.
///
/// `env` is the environment, `name` the binding, `val` its value, `doc` its
/// documentation, and `source_file` and `source_line` where it was written.
pub fn defSm(
    env: *tables.Table,
    name: [*:0]const u8,
    val: repr.Value,
    doc: ?[*:0]const u8,
    source_file: ?[*:0]const u8,
    source_line: i32,
) void {
    const subt = tables.new(2);
    tables.put(subt, value.fromBytes("value", .keyword), val);
    addMeta(subt, doc, source_file, source_line);
    tables.put(env, value.fromBytes(std.mem.span(name), .symbol), wrap.fromTable(subt));
}

/// Defines a var with no source map, reporting a raise across the C ABI.
///
/// `env` is the environment, `name` the binding, `val` its value and `doc` its
/// documentation.
pub fn defVarAbi(env: *tables.Table, name: [*:0]const u8, val: repr.Value, doc: ?[*:0]const u8) void {
    raise.toAbi(defVarSm(env, name, val, doc, null, 0));
}

/// Defines a var, with documentation and a source map.
///
/// `env` is the environment, `name` the binding, `val` its value, `doc` its
/// documentation, and `source_file` and `source_line` where it was written.
/// This function raises what the array push raises.
///
/// A var differs from a def in one thing: the value lives in a one-element
/// array under `:ref`, so that `set` has somewhere to write.
pub fn defVarSm(
    env: *tables.Table,
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

/// Returns the abstract type registered under `key`, or null.
pub fn getAbstractType(key: repr.Value) ?*const abi.AbstractType {
    const wrapped = tables.get(vm_state.current().abstract_registry.?, key);
    if (repr.checkType(wrapped, repr.Tag.nil)) return null;
    return @ptrCast(@alignCast(wrap.toPointer(wrapped)));
}

/// Returns a core binding that is expected to be a table, or null.
///
/// `name` is the binding. Two ways to return null and both are silent: the
/// symbol is unbound, or it is bound to something that is not a table. The
/// callers look up `module/cache` and its neighbours, which the core always
/// defines, so neither is expected to happen.
pub fn getCoreTable(name: [*:0]const u8) ?*tables.Table {
    const env = env_core.coreEnvAbi(null);
    const binding = resolve(env, symbols.csymbol(name));
    if (binding.type == .none) return null;
    if (!repr.checkType(binding.value, repr.Tag.table)) return null;
    return wrap.toTable(binding.value);
}

/// Records a builtin's name against its function pointer, with no prefix and
/// no source location.
pub fn register(name: ?[*:0]const u8, cfun: abi.CFunction) void {
    putRow(&vm_state.current().registry, cfun, name, null, null, 0);
}

/// Records an abstract type under its name, so that the unmarshaller can find
/// it again.
///
/// `at` is the type. Registering the same type twice is allowed and has no
/// effect. Registering a different type under a name already taken raises,
/// because the name is what a marshalled abstract includes and one name
/// resolving to two types would make the stream ambiguous.
pub fn registerAbstractType(at: *const abi.AbstractType) raise.Raising(void) {
    checkPointerAlign(at);
    const sym = value.fromBytes(at.name, .symbol);
    const check = tables.get(vm_state.current().abstract_registry.?, sym);
    if (!repr.checkType(check, repr.Tag.nil) and at != @as(*const abi.AbstractType, @ptrCast(@alignCast(wrap.toPointer(check))))) {
        return pp_format.panicf(
            "cannot register abstract type %s, a type with the same name exists",
            .{at.name},
        );
    }
    tables.put(vm_state.current().abstract_registry.?, sym, wrap.fromPointer(@constCast(at)));
}

/// Releases the rows and returns the registry to what `registryInit` starts
/// from.
///
/// `r` is the registry. The names in the rows are static and unmanaged, so
/// there is nothing else to free.
pub fn registryDeinit(r: *Registry) void {
    r.rows.deinit(utils.heap);
    // `ArrayListUnmanaged.deinit` ends `self.* = undefined`; see
    // `gc.rootsDeinit` for why this reset is not optional.
    r.rows = .empty;
    r.* = .{};
}

/// Finds a builtin's metadata by its function pointer, in the current VM's
/// registry, or null.
pub fn registryGet(key: abi.CFunction) ?*Row {
    return getRow(&vm_state.current().registry, key);
}

/// Starts the registry empty.
///
/// `r` is the registry. This and `registryDeinit` are two functions rather than
/// eight assignments at VM start-up and two at shutdown, because a teardown
/// that freed the rows and left the scalars set would make `registryGet` bisect
/// null over a non-zero count, and `registryPut` write through the freed
/// pointer, in the window before the next init. Two functions over one type is
/// what makes that state unsayable: there is no assignment list to leave a
/// member out of.
pub fn registryInit(r: *Registry) void {
    r.* = .{};
}

/// Records a builtin's metadata in the current VM's registry.
///
/// `key` is the cfunction, `name` and `name_prefix` what a trace prints, and
/// `source_file` and `source_line` where it was written. A caller that already
/// has the table calls `putRow`.
pub fn registryPut(
    key: abi.CFunction,
    name: ?[*:0]const u8,
    name_prefix: ?[*:0]const u8,
    source_file: ?[*:0]const u8,
    source_line: i32,
) void {
    putRow(&vm_state.current().registry, key, name, name_prefix, source_file, source_line);
}

/// Resolves a symbol, dereferencing the two dynamic forms.
///
/// `env` is the environment and `sym` the symbol. The result is the same
/// `Binding` `resolveExt` returns, with `value` already read out of the dynamic
/// cell.
pub fn resolve(env: *tables.Table, sym: [*:0]const u8) Binding {
    var binding = resolveExt(env, sym);
    if (binding.type == .dynamic_def or binding.type == .dynamic_macro) {
        binding.value = arrays.peek(wrap.toArray(binding.value));
    }
    return binding;
}

/// Resolves a symbol in the core environment and returns its value.
pub fn resolveCore(name: [*:0]const u8) repr.Value {
    const env = env_core.coreEnvAbi(null);
    return resolve(env, symbols.csymbol(name)).value;
}

/// Resolves a symbol without dereferencing a dynamic form.
///
/// `env` is the environment and `sym` the symbol.
pub fn resolveExt(env: *tables.Table, sym: [*:0]const u8) Binding {
    const entry = tables.get(env, wrap.fromSymbol(sym));
    return bindingFromEntry(entry);
}

/// Computes one substitution for `string/replace`, `string/replace-all` and
/// the PEG engine's `replace`.
///
/// `subst` is the substitution, `bytes` the matched text and `extra_argv` any
/// extra captures. A function or a builtin is called with the matched text and
/// the extra captures; anything else is used as a value. So
/// `(string/replace "a" f s)` runs `f` per match and
/// `(string/replace "a" "b" s)` does not. This function raises what the call
/// raises.
///
/// The cfunction call goes through `raise.cfunction`, and Janet's does not.
/// Without the test a raising substitution passes this frame unnoticed and is
/// reported against whichever builtin called it, and the remaining matches are
/// substituted with nil in the meantime.
pub fn textSubstitution(
    subst: *repr.Value,
    bytes: []const u8,
    extra_argv: ?*arrays.Array,
) raise.Raising(abi.ByteView) {
    const extra: []const repr.Value = if (extra_argv) |array| array.slice() else &.{};
    const extra_argc: i32 = @intCast(extra.len);
    const value_type = repr.typeOf(subst.*);
    switch (value_type) {
        repr.Tag.function, repr.Tag.cfunction => {
            const argc = 1 + extra_argc;
            const argv = tuples.begin(@intCast(argc));
            argv[0] = value.fromBytes(bytes, .string);
            for (0..@as(usize, @intCast(extra_argc))) |i| {
                argv[i + 1] = extra[i];
            }
            _ = tuples.end(argv);
            if (value_type == repr.Tag.function) {
                return toByteView(try vm_entry.call(wrap.toFunction(subst.*), argv[0..@intCast(argc)]));
            }
            return toByteView(try raise.cfunction(wrap.toCfunction(subst.*))(argv[0..@intCast(argc)]));
        },
        else => return memoizeByteView(subst),
    }
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Attaches documentation and a source map to a binding's entry table.
///
/// `table` is the entry, `doc` the documentation, and `source_file` and
/// `source_line` the location. Both are optional and independent: a binding
/// with no docstring gets no `:doc`, and one whose source is unknown gets no
/// `:source-map`. The line number is tested rather than the file name, because
/// the file alone locates nothing.
fn addMeta(table: *tables.Table, doc: ?[*:0]const u8, source_file: ?[*:0]const u8, source_line: i32) void {
    if (doc) |text| {
        tables.put(table, value.fromBytes("doc", .keyword), value.fromBytes(std.mem.span(text), .string));
    }
    if (source_file) |file| {
        if (source_line != 0) {
            var triple: [3]repr.Value = .{
                value.fromBytes(std.mem.span(file), .string),
                wrap.fromInteger(source_line),
                wrap.fromInteger(1),
            };
            const val = wrap.fromTuple(tuples.newFrom(&triple));
            tables.put(table, value.fromBytes("source-map", .keyword), val);
        }
    }
}

/// Checks that a pointer survives being wrapped, on the nanbox layouts that
/// steal its low bits, and aborts if it does not.
///
/// `p` is the pointer. Registration is where the check goes rather than every
/// wrap, because a cfunction pointer and an abstract type pointer are each
/// registered exactly once and wrapped repeatedly afterwards.
inline fn checkPointerAlign(p: ?*const anyopaque) void {
    if (config.value_repr != .nanbox_64 or config.nanbox_pointer_shift == 0) return;
    const mask: usize = (@as(usize, 1) << repr.pointer_shift) - 1;
    if (@intFromPtr(p) & mask != 0) {
        fatal.fatal("unaligned pointer wrap - cfunction pointers and abstract types " ++
            "must be aligned with this nanboxing configuration.");
    }
}

/// Finds a builtin's metadata by its function pointer, or null.
///
/// `r` is the registry and `key` the cfunction. The bisection is the lookup,
/// which is what the sorted array and the `dirty` flag are maintained for; a
/// linear walk would be per frame, on the path a stack trace takes to name each
/// one.
///
/// The result is the first row with this key rather than whichever the
/// bisection landed on. A bisection over a run of equal keys may land anywhere
/// in the run, so walking back to its start is what makes the result
/// independent of the search path. Which registration that first row has is
/// not a property this code has: one cfunction may be registered more than once
/// under different names, and `sortRows` shifts past equal keys rather than
/// stopping at them, so every re-sort reverses the order of a tie. The property
/// that is true either way is the one `test/registry.zig` pins, the row a
/// walk of the array would find first.
fn getRow(r: *Registry, key: abi.CFunction) ?*Row {
    if (r.dirty) sortRows(r);

    const rows = r.rows.items;
    var lo: usize = 0;
    var hi: usize = rows.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (rows[mid].cfun == key) {
            // The first row with this key, rather than whichever the
            // bisection landed on. A bisection over a run of equal keys may
            // land anywhere in the run, so walking back to its start is what
            // makes the result independent of the search path.
            var first = mid;
            while (first > 0 and rows[first - 1].cfun == key) first -= 1;
            return &rows[first];
        }
        if (@intFromPtr(rows[mid].cfun) > @intFromPtr(key)) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    return null;
}

/// Installs `registrations` into `env`, prefixing each name where `prefixed`.
fn install(env: ?*tables.Table, regprefix: ?[*:0]const u8, prefixed: bool, registrations: []const abi.Reg) void {
    var it = Installer.init(env, regprefix, prefixed);
    defer it.deinit();
    for (registrations) |entry| it.put(entry);
}

/// Returns a byte view over `val`, replacing it with its printed form if it
/// has none.
///
/// `val` is the caller's slot. The replacement is what memoising means here:
/// the slot is overwritten with the string, so a substitution used against many
/// matches is printed once. The view points into that string, so the caller's
/// slot is what the view depends on.
fn memoizeByteView(val: *repr.Value) abi.ByteView {
    if (args_core.bytesView(val.*)) |bytes| {
        return .{ .bytes = bytes.ptr, .len = bytes.len };
    }
    const str = pp_describe.toString(val.*);
    val.* = wrap.fromString(str);
    return .{ .bytes = str, .len = strings.head(str).length };
}

/// Records a builtin's metadata in `r`.
///
/// `r` is the registry, `key` the cfunction, `name` and `name_prefix` what a
/// trace prints, and `source_file` and `source_line` where it was written.
///
/// The growth floor is sized to the core, so that registering the builtins is
/// one allocation for the whole startup rather than several. Every string
/// stored here is static and unmanaged: the registry stores pointers into the
/// binary rather than into the heap, so nothing marks it.
fn putRow(
    r: *Registry,
    key: abi.CFunction,
    name: ?[*:0]const u8,
    name_prefix: ?[*:0]const u8,
    source_file: ?[*:0]const u8,
    source_line: i32,
) void {
    r.rows.append(utils.heap, .{
        .cfun = key,
        .name = name,
        .name_prefix = name_prefix,
        .source_file = source_file,
        .source_line = source_line,
    }) catch fatal.outOfMemory();
    r.dirty = true;
}

/// Sorts the registry by cfunction pointer, so that a lookup can bisect it.
///
/// `r` is the registry. Insertion sort, which is right for the shape of the
/// input: the registry is filled once at startup in whatever order the
/// libraries register, and then appended to rarely.
///
/// The comparison is through `@intFromPtr`, and the order it produces does not
/// have to mean anything. It only has to be the order `getRow`'s bisection
/// assumes.
fn sortRows(r: *Registry) void {
    const rows = r.rows.items;
    for (rows[1..], 1..) |reg, i| {
        var j: usize = i;
        while (j > 0) : (j -= 1) {
            if (@intFromPtr(rows[j - 1].cfun) < @intFromPtr(reg.cfun)) break;
            rows[j] = rows[j - 1];
        }
        rows[j] = reg;
    }
    r.dirty = false;
}

/// The same as `memoizeByteView`, for a value the caller does not own a slot
/// for.
///
/// `val` is the value. The view points into a string only the collector owns,
/// which is safe because the caller copies out of it before the next
/// allocation. That is a property of the two callers rather than of this
/// function.
fn toByteView(val: repr.Value) abi.ByteView {
    if (args_core.bytesView(val)) |bytes| {
        return .{ .bytes = bytes.ptr, .len = bytes.len };
    }
    const str = pp_describe.toString(val);
    return .{ .bytes = str, .len = strings.head(str).length };
}
