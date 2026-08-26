//! The half of `src/core/util.c` that owns VM state: the cfunction registry,
//! the four registration entry points and the two `janet_core_*` forms beside
//! them, the abstract-type registry, environment bindings and their
//! resolution, and `janet_text_substitution`.
//!
//! Phase 10 Part 17f. `utils.zig` has the other half — the pure substrate,
//! which raises nowhere and owns nothing. The split is what Phase 10's rule 2
//! asks for: two boundaries, two selectors, rather than one selector whose
//! subject is a file.
//!
//! ## What this subsystem is for
//!
//! Two tables and one array, and everything here is a way into one of them.
//!
//! `janet_vm.registry` is an array of `JanetCFunRegistry`, one row per builtin,
//! keyed by the cfunction pointer and holding the name, prefix and source
//! location that a stack trace prints. It is *not* a Janet table: the key is a
//! function pointer, the rows are static strings the collector never sees, and
//! it must be readable while the collector runs.
//!
//! `janet_vm.abstract_registry` is a Janet table from type name to
//! `JanetAbstractType *`, and exists so that `janet_unmarshal` can rebuild an
//! abstract from a name in a byte stream.
//!
//! An environment is an ordinary Janet table from symbol to an entry table,
//! and `janet_binding_from_entry` is the reader that turns one of those entries
//! into the `JanetBinding` the compiler and `janet_resolve` work from.
//!
//! ## The jump-transparent marker
//!
//! `janet_text_substitution` runs arbitrary Janet code: `janet_call` for a
//! function, and a cfunction pointer for a builtin. The first still raises by
//! jumping, so a raise can cross these frames and `defer` is not available.
//! The second returns its raise since Part 17e, and is invoked through
//! `raise.callCFunction` so that the test cannot be forgotten — see the note on
//! `textSubstitutionImpl`, which is where the C original was found to be
//! missing exactly that test.

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
const kind = @import("value/helpers/kind.zig");
const wrap = @import("value/helpers/wrap.zig");
const args_core = @import("args.zig");
const fatal = @import("fatal.zig");
const types = @import("types");
const constants = @import("constants");
const value = @import("value.zig");
const c = @import("cabi");
const pp_describe = @import("pp.zig");

/// `src/core/util.h`, declared here rather than in `cabi.zig`.
extern fn janet_table_get_keyword(table: *types.JanetTable, keyword: [*]const u8) callconv(.c) types.Janet;

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
        var triple: [3]types.Janet = .{
            value.fromBytes(std.mem.span(source_file.?), .string),
            wrapInteger(source_line),
            wrapInteger(1),
        };
        const val = wrap.fromTuple(tuples.newFrom(&triple, 3));
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
inline fn wrapInteger(x: i32) types.Janet {
    return wrap.fromNumber(@floatFromInt(x));
}

pub fn defSm(
    env: *types.JanetTable,
    name: [*:0]const u8,
    val: types.Janet,
    doc: ?[*:0]const u8,
    source_file: ?[*:0]const u8,
    source_line: i32,
) callconv(.c) void {
    const subt = tables.new(2);
    tables.put(subt, value.fromBytes("value", .keyword), val);
    addMeta(subt, doc, source_file, source_line);
    tables.put(env, value.fromBytes(std.mem.span(name), .symbol), wrap.fromTable(subt));
}

pub fn def(env: *types.JanetTable, name: [*:0]const u8, val: types.Janet, doc: ?[*:0]const u8) void {
    defSm(env, name, val, doc, null, 0);
}

/// A var differs from a def in one thing: the value lives in a one-element
/// array under `:ref`, so that `set` has somewhere to write.
pub fn janet_var_smImpl(
    env: *types.JanetTable,
    name: [*:0]const u8,
    val: types.Janet,
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

pub fn defVar(env: *types.JanetTable, name: [*:0]const u8, val: types.Janet, doc: ?[*:0]const u8) void {
    raise.reported(janet_var_smImpl(env, name, val, doc, null, 0));
}

pub fn varSm(
    env: *types.JanetTable,
    name: [*:0]const u8,
    val: types.Janet,
    doc: ?[*:0]const u8,
    source_file: ?[*:0]const u8,
    source_line: i32,
) callconv(.c) void {
    raise.reported(janet_var_smImpl(env, name, val, doc, source_file, source_line));
}

// ==========================================================================
// The cfunction registry
// ==========================================================================

/// Sort the registry by cfunction pointer, so that a lookup can bisect it.
///
/// Insertion sort, which is the C original's choice and the right one for the
/// shape of the input: the registry is filled once at startup in whatever order
/// the libraries register, and then appended to rarely.
///
/// Comparing function pointers with `<` is undefined in C unless they are into
/// the same array, and this is the port doing the same thing through
/// `@intFromPtr`, which is defined. The order does not have to mean anything --
/// it only has to be consistent with the bisection in `janet_registry_get`.
fn registrySort() void {
    var i: usize = 1;
    while (i < c.vm().registry_count) : (i += 1) {
        const reg = c.vm().registry.?[i];
        var j: usize = i;
        while (j > 0) : (j -= 1) {
            if (@intFromPtr(c.vm().registry.?[j - 1].cfun) < @intFromPtr(reg.cfun)) break;
            c.vm().registry.?[j] = c.vm().registry.?[j - 1];
        }
        c.vm().registry.?[j] = reg;
    }
    c.vm().registry_dirty = 0;
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
pub fn registryPut(
    key: types.JanetCFunction,
    name: ?[*:0]const u8,
    name_prefix: ?[*:0]const u8,
    source_file: ?[*:0]const u8,
    source_line: i32,
) callconv(.c) void {
    if (c.vm().registry_count == c.vm().registry_cap) {
        var newcap = (c.vm().registry_count + 1) * 2;
        if (newcap < 512) newcap = 512;
        const newmem = std.c.realloc(
            @ptrCast(c.vm().registry),
            newcap * @sizeOf(types.JanetCFunRegistry),
        ) orelse fatal.outOfMemory();
        c.vm().registry = @ptrCast(@alignCast(newmem));
        c.vm().registry_cap = newcap;
    }
    c.vm().registry.?[c.vm().registry_count] = .{
        .cfun = key,
        .name = name,
        .name_prefix = name_prefix,
        .source_file = source_file,
        .source_line = source_line,
    };
    c.vm().registry_count += 1;
    c.vm().registry_dirty = 1;
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
pub fn registryGet(key: types.JanetCFunction) ?*types.JanetCFunRegistry {
    if (c.vm().registry_dirty != 0) registrySort();

    var i: usize = 0;
    while (i < c.vm().registry_count) : (i += 1) {
        if (c.vm().registry.?[i].cfun == key) return &c.vm().registry.?[@intCast(i)];
    }

    var lo: [*]types.JanetCFunRegistry = c.vm().registry.?;
    var hi: [*]types.JanetCFunRegistry = lo + c.vm().registry_count;
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

pub fn register(name: ?[*:0]const u8, cfun: types.JanetCFunction) void {
    registryPut(cfun, name, null, null, 0);
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
    const mask: usize = (@as(usize, 1) << constants.JANET_NANBOX_64_POINTER_SHIFT) - 1;
    if (@intFromPtr(p) & mask != 0) {
        fatal.fatal("unaligned pointer wrap - cfunction pointers and abstract types " ++
            "must be aligned with this nanboxing configuration.");
    }
}

/// The four registration entry points differ along two axes and nothing else:
/// whether the table carries source locations (`Ext`), and whether each name is
/// prefixed with the registration prefix (`Prefix`). Writing the loop once and
/// selecting on two comptime flags keeps the four in step; the C original
/// writes it out four times and they have drifted before.
fn Register(comptime Entry: type, comptime prefixed: bool) type {
    return struct {
        fn install(env: ?*types.JanetTable, regprefix: ?[*:0]const u8, registrations: [*]const Entry) void {
            const ext = Entry == types.JanetRegExt;
            var nb: NameBuf = undefined;
            if (prefixed and env != null) nb = NameBuf.init(regprefix.?);

            var entry = registrations;
            while (entry[0].name) |entry_name| : (entry += 1) {
                checkPointerAlign(@ptrCast(entry[0].cfun));
                const fun = wrap.fromCfunction(entry[0].cfun);
                if (env != null) {
                    const name = if (prefixed) nb.name(entry_name) else entry_name;
                    if (ext) {
                        defSm(
                            env.?,
                            name,
                            fun,
                            entry[0].documentation,
                            entry[0].source_file,
                            entry[0].source_line,
                        );
                    } else {
                        def(env.?, name, fun, entry[0].documentation);
                    }
                }
                registryPut(
                    entry[0].cfun,
                    entry[0].name,
                    regprefix,
                    if (ext) entry[0].source_file else null,
                    if (ext) entry[0].source_line else 0,
                );
            }

            if (prefixed and env != null) nb.deinit();
        }
    };
}

pub fn cfuns(env: ?*types.JanetTable, regprefix: ?[*:0]const u8, registrations: [*]const types.JanetReg) void {
    Register(types.JanetReg, false).install(env, regprefix, registrations);
}

pub fn cfunsExt(env: ?*types.JanetTable, regprefix: ?[*:0]const u8, registrations: [*]const types.JanetRegExt) void {
    Register(types.JanetRegExt, false).install(env, regprefix, registrations);
}

pub fn cfunsPrefix(env: ?*types.JanetTable, regprefix: ?[*:0]const u8, registrations: [*]const types.JanetReg) void {
    Register(types.JanetReg, true).install(env, regprefix, registrations);
}

pub fn cfunsExtPrefix(env: ?*types.JanetTable, regprefix: ?[*:0]const u8, registrations: [*]const types.JanetRegExt) void {
    Register(types.JanetRegExt, true).install(env, regprefix, registrations);
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
    x: types.Janet,
    p: ?*const anyopaque,
    sf: ?*const anyopaque,
    sl: i32,
) callconv(.c) void {
    _ = p;
    _ = sf;
    _ = sl;
    const key = value.fromBytes(std.mem.span(name), .symbol);
    tables.put(env, key, x);
    if (kind.checkType(x, constants.JANET_CFUNCTION) != 0) {
        registryPut(wrap.toCfunction(x), name, null, null, 0);
    }
}

pub fn coreCfunsExt(
    env: *types.JanetTable,
    regprefix: ?[*:0]const u8,
    registrations: [*]const types.JanetRegExt,
) callconv(.c) void {
    var entry = registrations;
    while (entry[0].name) |entry_name| : (entry += 1) {
        checkPointerAlign(@ptrCast(entry[0].cfun));
        const fun = wrap.fromCfunction(entry[0].cfun);
        tables.put(env, value.fromBytes(std.mem.span(entry_name), .symbol), fun);
        registryPut(
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
fn registerAbstractTypeImpl(at: *const types.JanetAbstractType) raise.Raising(void) {
    checkPointerAlign(at);
    const sym = value.fromBytes(std.mem.span(at.name), .symbol);
    const check = tables.get(c.vm().abstract_registry.?, sym);
    if (kind.checkType(check, constants.JANET_NIL) == 0 and at != @as(*const types.JanetAbstractType, @ptrCast(@alignCast(wrap.toPointer(check))))) {
        return pp_format.panicf(
            "cannot register abstract type %s, a type with the same name exists",
            .{at.name},
        );
    }
    tables.put(c.vm().abstract_registry.?, sym, wrap.fromPointer(@constCast(at)));
}

/// The Zig entry point, for a caller inside this module.
pub const registerAbstractType = registerAbstractTypeImpl;

pub const registerAbstractTypeAbi = raise.panicking(registerAbstractTypeImpl).abi;

pub fn getAbstractType(key: types.Janet) ?*const types.JanetAbstractType {
    const wrapped = tables.get(c.vm().abstract_registry.?, key);
    if (kind.checkType(wrapped, constants.JANET_NIL) != 0) return null;
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
pub fn bindingFromEntry(entry: types.Janet) types.JanetBinding {
    var binding: types.JanetBinding = .{
        .type = constants.JANET_BINDING_NONE,
        .value = wrap.fromNil(),
        .deprecation = constants.JANET_BINDING_DEP_NONE,
    };

    if (kind.checkType(entry, constants.JANET_TABLE) == 0) return binding;
    const entry_table = wrap.toTable(entry);

    const deprecate = janet_table_get_keyword(entry_table, "deprecated");
    const macro = kind.truthy(janet_table_get_keyword(entry_table, "macro")) != 0;
    const val = janet_table_get_keyword(entry_table, "value");
    const ref = janet_table_get_keyword(entry_table, "ref");

    if (kind.checkType(deprecate, constants.JANET_KEYWORD) != 0) {
        const depkw = wrap.toKeyword(deprecate);
        if (utils.cstrcmp(depkw, "relaxed") == 0) {
            binding.deprecation = constants.JANET_BINDING_DEP_RELAXED;
        } else if (utils.cstrcmp(depkw, "normal") == 0) {
            binding.deprecation = constants.JANET_BINDING_DEP_NORMAL;
        } else if (utils.cstrcmp(depkw, "strict") == 0) {
            binding.deprecation = constants.JANET_BINDING_DEP_STRICT;
        }
    } else if (kind.checkType(deprecate, constants.JANET_NIL) == 0) {
        binding.deprecation = constants.JANET_BINDING_DEP_NORMAL;
    }

    const ref_is_valid = kind.checkType(ref, constants.JANET_ARRAY) != 0;
    const redef = ref_is_valid and kind.truthy(janet_table_get_keyword(entry_table, "redef")) != 0;

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
pub fn resolve(env: *types.JanetTable, sym: [*:0]const u8, out: *types.Janet) types.JanetBindingType {
    const binding = resolveExt(env, sym);
    if (binding.type == constants.JANET_BINDING_DYNAMIC_DEF or binding.type == constants.JANET_BINDING_DYNAMIC_MACRO) {
        out.* = arrays.peek(wrap.toArray(binding.value));
    } else {
        out.* = binding.value;
    }
    return binding.type;
}

pub fn resolveCore(name: [*:0]const u8) types.Janet {
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
    if (kind.checkType(out, constants.JANET_TABLE) == 0) return null;
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
fn memoizeByteView(val: *types.Janet) types.JanetByteView {
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
fn toByteView(val: types.Janet) types.JanetByteView {
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
/// **The cfunction call goes through `raise.callCFunction`, and the C original
/// does not.** Part 17e converted 193 builtins to record a raise in
/// `janet_vm.raising` and return, counted the places that invoke a cfunction
/// pointer, and found three; this is a fourth, in a file that increment did not
/// touch. Without the test a raising substitution is carried past this frame
/// and reported against whichever builtin called it, and the remaining matches
/// are substituted with nil in the meantime. `src/core/util.c`'s arm was given
/// the same test in this part so that the two selectors still agree.
fn textSubstitutionImpl(
    subst: *types.Janet,
    bytes: []const u8,
    extra_argv: ?*types.JanetArray,
) raise.Raising(types.JanetByteView) {
    const extra_argc: i32 = if (extra_argv == null) 0 else extra_argv.?.count;
    const value_type = kind.typeOf(subst.*);
    switch (value_type) {
        constants.JANET_FUNCTION, constants.JANET_CFUNCTION => {
            const argc = 1 + extra_argc;
            const argv = tuples.begin(argc);
            argv[0] = value.fromBytes(bytes, .string);
            var i: i32 = 0;
            while (i < extra_argc) : (i += 1) {
                argv[@intCast(i + 1)] = extra_argv.?.data.?[@intCast(i)];
            }
            _ = tuples.end(argv);
            if (value_type == constants.JANET_FUNCTION) {
                // `janet_call` still raises by jumping, which is why this file
                // is jump-transparent. It converts with the rest of the entry
                // points above the interpreter.
                return toByteView(try vm_entry.callImpl(wrap.toFunction(subst.*), argv[0..@intCast(argc)]));
            }
            return toByteView(try raise.cfunction(wrap.toCfunction(subst.*))(argv[0..@intCast(argc)]));
        },
        else => return memoizeByteView(subst),
    }
}

/// The Zig entry point, and now the only one.
///
/// The `raise.panicking` abi under the name `janet_text_substitution` went in
/// Phase 11 Part 13. `util.h` was the only header that declared it, so nothing
/// outside the runtime ever had a reason to call it, and inside the runtime
/// `string_symbol.zig` reaches this by import through `registration.zig`. Its
/// last caller was `test/registry.c`, which is now `test/registry.zig`.
pub const textSubstitution = textSubstitutionImpl;
