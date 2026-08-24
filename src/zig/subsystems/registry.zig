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
const abi = @import("abi");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");
const buffer_array = @import("buffer_array.zig");
const vm_entry = @import("vm_entry.zig");
const c = abi.c;

/// `src/core/util.h`, which `abi.zig` deliberately does not translate.
extern fn janet_table_get_keyword(table: [*c]c.JanetTable, keyword: [*c]const u8) callconv(.c) c.Janet;

// ==========================================================================
// Bindings in an environment
// ==========================================================================

/// Attach documentation and a source map to a binding's entry table.
///
/// Both are optional and independent: a binding with no docstring gets no
/// `:doc`, and one whose source is unknown gets no `:source-map`. The line
/// number is tested rather than the file name because the file alone locates
/// nothing.
fn addMeta(table: *c.JanetTable, doc: [*c]const u8, source_file: [*c]const u8, source_line: i32) void {
    if (doc != null) {
        c.janet_table_put(table, c.janet_ckeywordv("doc"), c.janet_cstringv(doc));
    }
    if (source_file != null and source_line != 0) {
        var triple: [3]c.Janet = .{
            c.janet_cstringv(source_file),
            wrapInteger(source_line),
            wrapInteger(1),
        };
        const value = c.janet_wrap_tuple(c.janet_tuple_n(&triple, 3));
        c.janet_table_put(table, c.janet_ckeywordv("source-map"), value);
    }
}

/// `janet_wrap_integer`, written out rather than called.
///
/// `janet.h` declares the function beside its macro and `wrap.c` defines it
/// only for the two nanbox layouts, so a tagged build has no such symbol and a
/// Zig caller -- which cannot use the macro -- does not link. `os_files.zig`,
/// `marsh.zig`, `pp_pretty.zig` and `value_access.zig` write it out for the
/// same reason, and `FOUND.md` has the defect.
inline fn wrapInteger(x: i32) c.Janet {
    return c.janet_wrap_number(@floatFromInt(x));
}

export fn janet_def_sm(
    env: *c.JanetTable,
    name: [*c]const u8,
    val: c.Janet,
    doc: [*c]const u8,
    source_file: [*c]const u8,
    source_line: i32,
) callconv(.c) void {
    const subt = c.janet_table(2);
    c.janet_table_put(subt, c.janet_ckeywordv("value"), val);
    addMeta(subt, doc, source_file, source_line);
    c.janet_table_put(env, c.janet_csymbolv(name), c.janet_wrap_table(subt));
}

export fn janet_def(env: *c.JanetTable, name: [*c]const u8, value: c.Janet, doc: [*c]const u8) callconv(.c) void {
    janet_def_sm(env, name, value, doc, null, 0);
}

/// A var differs from a def in one thing: the value lives in a one-element
/// array under `:ref`, so that `set` has somewhere to write.
pub fn janet_var_smImpl(
    env: *c.JanetTable,
    name: [*c]const u8,
    val: c.Janet,
    doc: [*c]const u8,
    source_file: [*c]const u8,
    source_line: i32,
) raise.Raising(void) {
    const array = c.janet_array(1);
    const subt = c.janet_table(2);
    try buffer_array.arrayPush(array, val);
    c.janet_table_put(subt, c.janet_ckeywordv("ref"), c.janet_wrap_array(array));
    addMeta(subt, doc, source_file, source_line);
    c.janet_table_put(env, c.janet_csymbolv(name), c.janet_wrap_table(subt));
}

export fn janet_var(env: *c.JanetTable, name: [*c]const u8, val: c.Janet, doc: [*c]const u8) callconv(.c) void {
    raise.reported(janet_var_smImpl(env, name, val, doc, null, 0));
}

export fn janet_var_sm(
    env: *c.JanetTable,
    name: [*c]const u8,
    val: c.Janet,
    doc: [*c]const u8,
    source_file: [*c]const u8,
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
    while (i < c.janet_vm.registry_count) : (i += 1) {
        const reg = c.janet_vm.registry[i];
        var j: usize = i;
        while (j > 0) : (j -= 1) {
            if (@intFromPtr(c.janet_vm.registry[j - 1].cfun) < @intFromPtr(reg.cfun)) break;
            c.janet_vm.registry[j] = c.janet_vm.registry[j - 1];
        }
        c.janet_vm.registry[j] = reg;
    }
    c.janet_vm.registry_dirty = 0;
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
export fn janet_registry_put(
    key: c.JanetCFunction,
    name: [*c]const u8,
    name_prefix: [*c]const u8,
    source_file: [*c]const u8,
    source_line: i32,
) callconv(.c) void {
    if (c.janet_vm.registry_count == c.janet_vm.registry_cap) {
        var newcap = (c.janet_vm.registry_count + 1) * 2;
        if (newcap < 512) newcap = 512;
        const newmem = std.c.realloc(
            @ptrCast(c.janet_vm.registry),
            newcap * @sizeOf(c.JanetCFunRegistry),
        ) orelse c.janet_zig_out_of_memory();
        c.janet_vm.registry = @ptrCast(@alignCast(newmem));
        c.janet_vm.registry_cap = newcap;
    }
    c.janet_vm.registry[c.janet_vm.registry_count] = .{
        .cfun = key,
        .name = name,
        .name_prefix = name_prefix,
        .source_file = source_file,
        .source_line = source_line,
    };
    c.janet_vm.registry_count += 1;
    c.janet_vm.registry_dirty = 1;
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
export fn janet_registry_get(key: c.JanetCFunction) callconv(.c) [*c]c.JanetCFunRegistry {
    if (c.janet_vm.registry_dirty != 0) registrySort();

    var i: usize = 0;
    while (i < c.janet_vm.registry_count) : (i += 1) {
        if (c.janet_vm.registry[i].cfun == key) return c.janet_vm.registry + i;
    }

    var lo: [*c]c.JanetCFunRegistry = c.janet_vm.registry;
    var hi: [*c]c.JanetCFunRegistry = lo + c.janet_vm.registry_count;
    while (@intFromPtr(lo) < @intFromPtr(hi)) {
        const span = (@intFromPtr(hi) - @intFromPtr(lo)) / @sizeOf(c.JanetCFunRegistry);
        const mid = lo + span / 2;
        if (mid.*.cfun == key) return mid;
        if (@intFromPtr(mid.*.cfun) > @intFromPtr(key)) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    return null;
}

export fn janet_register(name: [*c]const u8, cfun: c.JanetCFunction) callconv(.c) void {
    janet_registry_put(cfun, name, null, null, 0);
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
    buf: [*c]u8,
    plen: usize,

    fn init(prefix: [*c]const u8) NameBuf {
        const plen = std.mem.len(prefix);
        const buf: [*c]u8 = @ptrCast(c.janet_smalloc(plen + 256) orelse c.janet_zig_out_of_memory());
        @memcpy(buf[0..plen], prefix[0..plen]);
        buf[plen] = '/';
        return .{ .buf = buf, .plen = plen };
    }

    fn deinit(self: *NameBuf) void {
        c.janet_sfree(self.buf);
    }

    /// The C original reallocates on every call rather than only when the
    /// suffix outgrows the 256 bytes `init` reserved. Reproduced: the scratch
    /// allocator's `realloc` is cheap and the difference is not observable.
    fn name(self: *NameBuf, suffix: [*c]const u8) [*c]u8 {
        const slen = std.mem.len(suffix);
        self.buf = @ptrCast(c.janet_srealloc(self.buf, self.plen + 2 + slen) orelse
            c.janet_zig_out_of_memory());
        @memcpy(self.buf[self.plen + 1 .. self.plen + 1 + slen], suffix[0..slen]);
        self.buf[self.plen + 1 + slen] = 0;
        return self.buf;
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
    if (!@hasDecl(c, "JANET_NANBOX_64") or c.JANET_NANBOX_64_POINTER_SHIFT == 0) return;
    const mask: usize = (@as(usize, 1) << c.JANET_NANBOX_64_POINTER_SHIFT) - 1;
    if (@intFromPtr(p) & mask != 0) {
        c.janet_zig_fatal("unaligned pointer wrap - cfunction pointers and abstract types " ++
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
        fn install(env: [*c]c.JanetTable, regprefix: [*c]const u8, cfuns: [*c]const Entry) void {
            const ext = Entry == c.JanetRegExt;
            var nb: NameBuf = undefined;
            if (prefixed and env != null) nb = NameBuf.init(regprefix);

            var entry = cfuns;
            while (entry.*.name != null) : (entry += 1) {
                checkPointerAlign(@ptrCast(entry.*.cfun));
                const fun = c.janet_wrap_cfunction(entry.*.cfun);
                if (env != null) {
                    const name = if (prefixed) nb.name(entry.*.name) else entry.*.name;
                    if (ext) {
                        janet_def_sm(
                            env,
                            name,
                            fun,
                            entry.*.documentation,
                            entry.*.source_file,
                            entry.*.source_line,
                        );
                    } else {
                        janet_def(env, name, fun, entry.*.documentation);
                    }
                }
                janet_registry_put(
                    entry.*.cfun,
                    entry.*.name,
                    regprefix,
                    if (ext) entry.*.source_file else null,
                    if (ext) entry.*.source_line else 0,
                );
            }

            if (prefixed and env != null) nb.deinit();
        }
    };
}

export fn janet_cfuns(env: [*c]c.JanetTable, regprefix: [*c]const u8, cfuns: [*c]const c.JanetReg) callconv(.c) void {
    Register(c.JanetReg, false).install(env, regprefix, cfuns);
}

export fn janet_cfuns_ext(env: [*c]c.JanetTable, regprefix: [*c]const u8, cfuns: [*c]const c.JanetRegExt) callconv(.c) void {
    Register(c.JanetRegExt, false).install(env, regprefix, cfuns);
}

export fn janet_cfuns_prefix(env: [*c]c.JanetTable, regprefix: [*c]const u8, cfuns: [*c]const c.JanetReg) callconv(.c) void {
    Register(c.JanetReg, true).install(env, regprefix, cfuns);
}

export fn janet_cfuns_ext_prefix(env: [*c]c.JanetTable, regprefix: [*c]const u8, cfuns: [*c]const c.JanetRegExt) callconv(.c) void {
    Register(c.JanetRegExt, true).install(env, regprefix, cfuns);
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
    if (!@hasDecl(c, "JANET_BOOTSTRAP")) {
        @export(&coreDefSm, .{ .name = "janet_core_def_sm" });
        @export(&coreCfunsExt, .{ .name = "janet_core_cfuns_ext" });
    }
}

fn coreDefSm(
    env: *c.JanetTable,
    name: [*c]const u8,
    x: c.Janet,
    p: ?*const anyopaque,
    sf: ?*const anyopaque,
    sl: i32,
) callconv(.c) void {
    _ = p;
    _ = sf;
    _ = sl;
    const key = c.janet_csymbolv(name);
    c.janet_table_put(env, key, x);
    if (c.janet_checktype(x, c.JANET_CFUNCTION) != 0) {
        janet_registry_put(c.janet_unwrap_cfunction(x), name, null, null, 0);
    }
}

fn coreCfunsExt(
    env: *c.JanetTable,
    regprefix: [*c]const u8,
    cfuns: [*c]const c.JanetRegExt,
) callconv(.c) void {
    var entry = cfuns;
    while (entry.*.name != null) : (entry += 1) {
        checkPointerAlign(@ptrCast(entry.*.cfun));
        const fun = c.janet_wrap_cfunction(entry.*.cfun);
        c.janet_table_put(env, c.janet_csymbolv(entry.*.name), fun);
        janet_registry_put(
            entry.*.cfun,
            entry.*.name,
            regprefix,
            entry.*.source_file,
            entry.*.source_line,
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
fn registerAbstractTypeImpl(at: *const c.JanetAbstractType) raise.Raising(void) {
    checkPointerAlign(at);
    const sym = c.janet_csymbolv(at.name);
    const check = c.janet_table_get(c.janet_vm.abstract_registry, sym);
    if (c.janet_checktype(check, c.JANET_NIL) == 0 and at != @as(*const c.JanetAbstractType, @ptrCast(@alignCast(c.janet_unwrap_pointer(check))))) {
        return pp_format.panicf(
            "cannot register abstract type %s, a type with the same name exists",
            .{at.name},
        );
    }
    c.janet_table_put(c.janet_vm.abstract_registry, sym, c.janet_wrap_pointer(@constCast(at)));
}

/// The Zig entry point, for a caller inside this module.
pub const registerAbstractType = registerAbstractTypeImpl;

const registerAbstractTypeFace = raise.panicking(registerAbstractTypeImpl).face;

comptime {
    @export(&registerAbstractTypeFace, .{ .name = "janet_register_abstract_type" });
}

export fn janet_get_abstract_type(key: c.Janet) callconv(.c) [*c]const c.JanetAbstractType {
    const wrapped = c.janet_table_get(c.janet_vm.abstract_registry, key);
    if (c.janet_checktype(wrapped, c.JANET_NIL) != 0) return null;
    return @ptrCast(@alignCast(c.janet_unwrap_pointer(wrapped)));
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
export fn janet_binding_from_entry(entry: c.Janet) callconv(.c) c.JanetBinding {
    var binding: c.JanetBinding = .{
        .type = c.JANET_BINDING_NONE,
        .value = c.janet_wrap_nil(),
        .deprecation = c.JANET_BINDING_DEP_NONE,
    };

    if (c.janet_checktype(entry, c.JANET_TABLE) == 0) return binding;
    const entry_table = c.janet_unwrap_table(entry);

    const deprecate = janet_table_get_keyword(entry_table, "deprecated");
    const macro = c.janet_truthy(janet_table_get_keyword(entry_table, "macro")) != 0;
    const value = janet_table_get_keyword(entry_table, "value");
    const ref = janet_table_get_keyword(entry_table, "ref");

    if (c.janet_checktype(deprecate, c.JANET_KEYWORD) != 0) {
        const depkw = c.janet_unwrap_keyword(deprecate);
        if (c.janet_cstrcmp(depkw, "relaxed") == 0) {
            binding.deprecation = c.JANET_BINDING_DEP_RELAXED;
        } else if (c.janet_cstrcmp(depkw, "normal") == 0) {
            binding.deprecation = c.JANET_BINDING_DEP_NORMAL;
        } else if (c.janet_cstrcmp(depkw, "strict") == 0) {
            binding.deprecation = c.JANET_BINDING_DEP_STRICT;
        }
    } else if (c.janet_checktype(deprecate, c.JANET_NIL) == 0) {
        binding.deprecation = c.JANET_BINDING_DEP_NORMAL;
    }

    const ref_is_valid = c.janet_checktype(ref, c.JANET_ARRAY) != 0;
    const redef = ref_is_valid and c.janet_truthy(janet_table_get_keyword(entry_table, "redef")) != 0;

    if (macro) {
        binding.value = if (redef) ref else value;
        binding.type = if (redef) c.JANET_BINDING_DYNAMIC_MACRO else c.JANET_BINDING_MACRO;
        return binding;
    }

    if (ref_is_valid) {
        binding.value = ref;
        binding.type = if (redef) c.JANET_BINDING_DYNAMIC_DEF else c.JANET_BINDING_VAR;
    } else {
        binding.value = value;
        binding.type = c.JANET_BINDING_DEF;
    }

    return binding;
}

export fn janet_resolve_ext(env: *c.JanetTable, sym: [*c]const u8) callconv(.c) c.JanetBinding {
    const entry = c.janet_table_get(env, c.janet_wrap_symbol(sym));
    return janet_binding_from_entry(entry);
}

/// Resolve a symbol to its value, dereferencing the two dynamic forms.
export fn janet_resolve(env: *c.JanetTable, sym: [*c]const u8, out: *c.Janet) callconv(.c) c.JanetBindingType {
    const binding = janet_resolve_ext(env, sym);
    if (binding.type == c.JANET_BINDING_DYNAMIC_DEF or binding.type == c.JANET_BINDING_DYNAMIC_MACRO) {
        out.* = c.janet_array_peek(c.janet_unwrap_array(binding.value));
    } else {
        out.* = binding.value;
    }
    return binding.type;
}

export fn janet_resolve_core(name: [*c]const u8) callconv(.c) c.Janet {
    const env = c.janet_core_env(null);
    var out = c.janet_wrap_nil();
    _ = janet_resolve(env, c.janet_csymbol(name), &out);
    return out;
}

/// A core binding that is expected to be a table, or null.
///
/// Two ways to answer null and both are silent: the symbol is unbound, or it is
/// bound to something that is not a table. The callers are looking up
/// `module/cache` and its neighbours, which the core always defines, so neither
/// is expected to happen.
export fn janet_get_core_table(name: [*c]const u8) callconv(.c) [*c]c.JanetTable {
    const env = c.janet_core_env(null);
    var out = c.janet_wrap_nil();
    const bt = janet_resolve(env, c.janet_csymbol(name), &out);
    if (bt == c.JANET_BINDING_NONE) return null;
    if (c.janet_checktype(out, c.JANET_TABLE) == 0) return null;
    return c.janet_unwrap_table(out);
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
fn memoizeByteView(value: *c.Janet) c.JanetByteView {
    var result: c.JanetByteView = undefined;
    if (c.janet_bytes_view(value.*, &result.bytes, &result.len) == 0) {
        const str = c.janet_to_string(value.*);
        value.* = c.janet_wrap_string(str);
        result.bytes = str;
        result.len = c.janet_string_length(str);
    }
    return result;
}

/// The same, for a value the caller does not own a slot for.
///
/// The view points into a string only the collector holds, which is safe
/// because the caller copies out of it before the next allocation. That is a
/// property of the two callers rather than of this function.
fn toByteView(value: c.Janet) c.JanetByteView {
    var result: c.JanetByteView = undefined;
    if (c.janet_bytes_view(value, &result.bytes, &result.len) == 0) {
        const str = c.janet_to_string(value);
        result.bytes = str;
        result.len = c.janet_string_length(str);
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
    subst: *c.Janet,
    bytes: [*c]const u8,
    len: u32,
    extra_argv: [*c]c.JanetArray,
) raise.Raising(c.JanetByteView) {
    const extra_argc: i32 = if (extra_argv == null) 0 else extra_argv.*.count;
    const value_type = c.janet_type(subst.*);
    switch (value_type) {
        c.JANET_FUNCTION, c.JANET_CFUNCTION => {
            const argc = 1 + extra_argc;
            const argv = c.janet_tuple_begin(argc);
            argv[0] = c.janet_stringv(bytes, @as(i32, @bitCast(len)));
            var i: i32 = 0;
            while (i < extra_argc) : (i += 1) {
                argv[@intCast(i + 1)] = extra_argv.*.data[@intCast(i)];
            }
            _ = c.janet_tuple_end(argv);
            if (value_type == c.JANET_FUNCTION) {
                // `janet_call` still raises by jumping, which is why this file
                // is jump-transparent. It converts with the rest of the entry
                // points above the interpreter.
                return toByteView(try vm_entry.callImpl(c.janet_unwrap_function(subst.*), argc, argv));
            }
            return toByteView(try raise.cfunction(c.janet_unwrap_cfunction(subst.*))(argc, argv));
        },
        else => return memoizeByteView(subst),
    }
}

/// The Zig entry point, and now the only one.
///
/// The `raise.panicking` face under the name `janet_text_substitution` went in
/// Phase 11 Part 13. `util.h` was the only header that declared it, so nothing
/// outside the runtime ever had a reason to call it, and inside the runtime
/// `string_symbol.zig` reaches this by import through `registration.zig`. Its
/// last caller was `test/registry.c`, which is now `test/registry.zig`.
pub const textSubstitution = textSubstitutionImpl;
