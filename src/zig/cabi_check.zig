//! `cabi.zig`'s declarations, against the definitions they name.
//!
//! **An `extern fn` is a promise the compiler believes without reading.** A
//! signature here that disagrees with the definition it names links and runs,
//! and the disagreement is undiagnosed: a `callconv(.c)` boundary has two
//! halves and nothing compares them. Both halves are Zig and both are
//! reachable from one module, so the comparison is a type equality and it runs
//! on every build.
//!
//! It lives inside the runtime module because that is the only module that can
//! see a subsystem's definitions. The definitions are `pub` for it, which
//! changes Zig visibility and not the symbol table.
//!
//! **The imports are gated the way `root.zig` gates them**, and they have to
//! be: an `export fn` is emitted because its file is in the compilation, not
//! because something calls it, so importing `ev/backend.zig` in a `-Dev=false`
//! build compiles code whose VM state has no `selfpipe` field. An instrument
//! must be gated the way its subject is.

const std = @import("std");
const c = @import("cabi");
const options = @import("options");
const config = @import("config");
const capi = @import("capi.zig");

/// Whether a declared type and a defined one are the same type.
///
/// **Exactly the same.** This was a loose comparison once, exempting pointer
/// flavour: a `translate-c` rendering of `T *` is `[*c]T`, 139 of the pairs
/// differed on that and nothing else, and reporting 139 non-findings would
/// have been worse than reporting none. There is no `translate-c` and no
/// `[*c]` in `cabi.zig` now, so the exemption protected nothing and hid
/// something.
///
/// **What it hid.** Tightening this to equality reported two disagreements in
/// the population it had been checking all along, both nullability:
/// `janet_buffer_push_cstring` declared `[*]const u8` for a definition that
/// reads to a sentinel, and `janet_pcall` declared `argv` and `f` non-optional
/// where the definition accepts null for both. A dropped sentinel and a lost
/// null are exactly what a linker cannot catch. Keep this exact.
///
/// `agrees` below compares every field of `Fn` and of each `Param`: the
/// convention, varargs, genericity, the return type, and each parameter's type
/// and `noalias`. Whole-type equality is tried first and is what usually
/// answers; the field walk exists only to produce a readable diagnostic.
fn compatible(comptime A: type, comptime B: type) bool {
    return A == B;
}

/// The declaration against the definition.
fn agrees(comptime Decl: type, comptime Def: type) bool {
    if (Decl == Def) return true;
    const a = switch (@typeInfo(Decl)) {
        .@"fn" => |f| f,
        else => return false,
    };
    const b = switch (@typeInfo(Def)) {
        .@"fn" => |f| f,
        else => return false,
    };
    // `CallingConvention` is a tagged union in 0.16, so it compares by tag
    // and payload rather than with `!=`.
    if (!std.meta.eql(a.calling_convention, b.calling_convention)) return false;
    if (a.is_var_args != b.is_var_args) return false;
    // `is_generic` and each parameter's `is_noalias` complete the comparison.
    // Neither can differ among the pairs checked today, so this is a hole with
    // nothing in it -- which is exactly the kind that opens quietly. A
    // `noalias` on one side and not the other is a real aliasing promise made
    // to the optimizer by one translation unit and not the other, and the
    // whole point of this file is that a `callconv(.c)` boundary has two
    // descriptions and no compiler compares them.
    if (a.is_generic != b.is_generic) return false;
    if (a.params.len != b.params.len) return false;
    const ra = a.return_type orelse return false;
    const rb = b.return_type orelse return false;
    if (!compatible(ra, rb)) return false;
    for (a.params, b.params) |pa, pb| {
        if (pa.is_noalias != pb.is_noalias) return false;
        if (pa.is_generic != pb.is_generic) return false;
        const ta = pa.type orelse return false;
        const tb = pb.type orelse return false;
        if (!compatible(ta, tb)) return false;
    }
    return true;
}

/// One file's declarations against its definitions, as a report fragment.
fn checkFile(comptime pairs: anytype) []const u8 {
    comptime {
        var r: []const u8 = "";
        for (pairs) |p| {
            if (!agrees(p[1], p[2])) r = r ++ "\n  " ++ p[0] ++ ": declared `" ++
                @typeName(p[1]) ++ "` but defined `" ++ @typeName(p[2]) ++ "`";
        }
        return r;
    }
}

pub fn verify() void {
    @setEvalBranchQuota(400_000);
    comptime {
        var report: []const u8 = "";
        report = report ++ checkFile(.{
            .{ "janet_zig_fatal", @TypeOf(c.janet_zig_fatal), @TypeOf(capi.janet_zig_fatal) },
        });
        if (config.ev) {
            report = report ++ checkFile(.{
                .{ "janet_await", @TypeOf(c.janet_await), @TypeOf(capi.janet_await) },
                .{ "janet_channel_give", @TypeOf(c.janet_channel_give), @TypeOf(capi.janet_channel_give) },
                .{ "janet_loop", @TypeOf(c.janet_loop), @TypeOf(capi.janet_loop) },
                .{ "janet_loop1", @TypeOf(c.janet_loop1), @TypeOf(capi.janet_loop1) },
                .{ "janet_stream_close", @TypeOf(c.janet_stream_close), @TypeOf(capi.janet_stream_close) },
            });
        }
        if (options.abstracts) {
            report = report ++ checkFile(.{
                .{ "janet_abstract", @TypeOf(c.janet_abstract), @TypeOf(capi.janet_abstract) },
            });
        }
        if (options.access) {
            report = report ++ checkFile(.{
                .{ "janet_length", @TypeOf(c.janet_length), @TypeOf(capi.janet_length) },
            });
        }
        if (options.args) {
            report = report ++ checkFile(.{
                .{ "janet_panic_abstract", @TypeOf(c.janet_panic_abstract), @TypeOf(capi.janet_panic_abstract) },
                .{ "janet_panic_type", @TypeOf(c.janet_panic_type), @TypeOf(capi.janet_panic_type) },
            });
        }
        if (options.arrays) {
            report = report ++ checkFile(.{
                .{ "janet_array", @TypeOf(c.janet_array), @TypeOf(capi.janet_array) },
                .{ "janet_array_pop", @TypeOf(c.janet_array_pop), @TypeOf(capi.janet_array_pop) },
                .{ "janet_array_push", @TypeOf(c.janet_array_push), @TypeOf(capi.janet_array_push) },
            });
        }
        if (options.buffers) {
            report = report ++ checkFile(.{
                .{ "janet_buffer", @TypeOf(c.janet_buffer), @TypeOf(capi.janet_buffer) },
                .{ "janet_buffer_extra", @TypeOf(c.janet_buffer_extra), @TypeOf(capi.janet_buffer_extra) },
                .{ "janet_buffer_push_bytes", @TypeOf(c.janet_buffer_push_bytes), @TypeOf(capi.janet_buffer_push_bytes) },
                .{ "janet_buffer_push_cstring", @TypeOf(c.janet_buffer_push_cstring), @TypeOf(capi.janet_buffer_push_cstring) },
                .{ "janet_buffer_push_u8", @TypeOf(c.janet_buffer_push_u8), @TypeOf(capi.janet_buffer_push_u8) },
                .{ "janet_buffer_setcount", @TypeOf(c.janet_buffer_setcount), @TypeOf(capi.janet_buffer_setcount) },
            });
        }
        if (options.debug) {
            report = report ++ checkFile(.{
                .{ "janet_stacktrace_ext", @TypeOf(c.janet_stacktrace_ext), @TypeOf(capi.janet_stacktrace_ext) },
            });
        }
        if (options.env) {
            report = report ++ checkFile(.{
                .{ "janet_core_env", @TypeOf(c.janet_core_env), @TypeOf(capi.janet_core_env) },
                .{ "janet_dobytes", @TypeOf(c.janet_dobytes), @TypeOf(capi.janet_dobytes) },
                .{ "janet_loop_fiber", @TypeOf(c.janet_loop_fiber), @TypeOf(capi.janet_loop_fiber) },
            });
        }
        if (options.fibers) {
            report = report ++ checkFile(.{
                .{ "janet_fiber", @TypeOf(c.janet_fiber), @TypeOf(capi.janet_fiber) },
                .{ "janet_fiber_reset", @TypeOf(c.janet_fiber_reset), @TypeOf(capi.janet_fiber_reset) },
            });
        }
        if (options.gc_alloc) {
            report = report ++ checkFile(.{
                .{ "janet_gcroot", @TypeOf(c.janet_gcroot), @TypeOf(capi.janet_gcroot) },
                .{ "janet_gcunroot", @TypeOf(c.janet_gcunroot), @TypeOf(capi.janet_gcunroot) },
            });
        }
        if (options.gc_mark) {
            report = report ++ checkFile(.{
                .{ "janet_collect", @TypeOf(c.janet_collect), @TypeOf(capi.janet_collect) },
            });
        }
        if (options.int_types_core) {
            report = report ++ checkFile(.{
                .{ "janet_unwrap_s64", @TypeOf(c.janet_unwrap_s64), @TypeOf(capi.janet_unwrap_s64) },
                .{ "janet_unwrap_u64", @TypeOf(c.janet_unwrap_u64), @TypeOf(capi.janet_unwrap_u64) },
            });
        }
        {
            // `repr.zig`'s four predicates, unconditional because the module
            // below `types` is in every configuration.
            report = report ++ checkFile(.{
                .{ "janet_checktype", @TypeOf(c.janet_checktype), @TypeOf(capi.janet_checktype) },
                .{ "janet_checktypes", @TypeOf(c.janet_checktypes), @TypeOf(capi.janet_checktypes) },
                .{ "janet_truthy", @TypeOf(c.janet_truthy), @TypeOf(capi.janet_truthy) },
                .{ "janet_unwrap_boolean", @TypeOf(c.janet_unwrap_boolean), @TypeOf(capi.janet_unwrap_boolean) },
                .{ "janet_type", @TypeOf(c.janet_type), @TypeOf(capi.janet_type) },
            });
        }
        if (options.lifecycle) {
            report = report ++ checkFile(.{
                .{ "janet_deinit", @TypeOf(c.janet_deinit), @TypeOf(capi.janet_deinit) },
                .{ "janet_init", @TypeOf(c.janet_init), @TypeOf(capi.janet_init) },
                .{ "janet_sandbox", @TypeOf(c.janet_sandbox), @TypeOf(capi.janet_sandbox) },
            });
        }
        if (options.order) {
            report = report ++ checkFile(.{
                .{ "janet_equals", @TypeOf(c.janet_equals), @TypeOf(capi.janet_equals) },
                .{ "janet_hash", @TypeOf(c.janet_hash), @TypeOf(capi.janet_hash) },
            });
        }
        if (options.registry and !config.bootstrap) {
            report = report ++ checkFile(.{
                .{ "janet_core_cfuns_ext", @TypeOf(c.janet_core_cfuns_ext), @TypeOf(capi.janet_core_cfuns_ext) },
                .{ "janet_core_def_sm", @TypeOf(c.janet_core_def_sm), @TypeOf(capi.janet_core_def_sm) },
            });
        }
        if (options.registry) {
            report = report ++ checkFile(.{
                .{ "janet_cfuns_ext", @TypeOf(c.janet_cfuns_ext), @TypeOf(capi.janet_cfuns_ext) },
                .{ "janet_def", @TypeOf(c.janet_def), @TypeOf(capi.janet_def) },
                .{ "janet_def_sm", @TypeOf(c.janet_def_sm), @TypeOf(capi.janet_def_sm) },
                .{ "janet_resolve", @TypeOf(c.janet_resolve), @TypeOf(capi.janet_resolve) },
            });
        }
        if (options.scan) {
            report = report ++ checkFile(.{
                .{ "janet_scan_number", @TypeOf(c.janet_scan_number), @TypeOf(capi.janet_scan_number) },
            });
        }
        if (options.signal) {
            report = report ++ checkFile(.{
                .{ "janet_panic", @TypeOf(c.janet_panic), @TypeOf(capi.janet_panic) },
                .{ "janet_panicv", @TypeOf(c.janet_panicv), @TypeOf(capi.janet_panicv) },
                .{ "janet_restore", @TypeOf(c.janet_restore), @TypeOf(capi.janet_restore) },
                .{ "janet_top_level_signal", @TypeOf(c.janet_top_level_signal), @TypeOf(capi.janet_top_level_signal) },
                .{ "janet_try_init", @TypeOf(c.janet_try_init), @TypeOf(capi.janet_try_init) },
                .{ "janet_zig_c_raise_clear", @TypeOf(c.janet_zig_c_raise_clear), @TypeOf(capi.janet_zig_c_raise_clear) },
                .{ "janet_zig_c_raise_record", @TypeOf(c.janet_zig_c_raise_record), @TypeOf(capi.janet_zig_c_raise_record) },
                .{ "janet_zig_c_raise_take", @TypeOf(c.janet_zig_c_raise_take), @TypeOf(capi.janet_zig_c_raise_take) },
                .{ "janet_zig_signal_record", @TypeOf(c.janet_zig_signal_record), @TypeOf(capi.janet_zig_signal_record) },
            });
        }
        if (options.strings) {
            report = report ++ checkFile(.{
                .{ "janet_cstring", @TypeOf(c.janet_cstring), @TypeOf(capi.janet_cstring) },
                .{ "janet_string", @TypeOf(c.janet_string), @TypeOf(capi.janet_string) },
            });
        }
        if (options.symbols) {
            report = report ++ checkFile(.{
                .{ "janet_csymbol", @TypeOf(c.janet_csymbol), @TypeOf(capi.janet_csymbol) },
                .{ "janet_symbol", @TypeOf(c.janet_symbol), @TypeOf(capi.janet_symbol) },
            });
        }
        if (options.tables) {
            report = report ++ checkFile(.{
                .{ "janet_table", @TypeOf(c.janet_table), @TypeOf(capi.janet_table) },
                .{ "janet_table_get", @TypeOf(c.janet_table_get), @TypeOf(capi.janet_table_get) },
                .{ "janet_table_put", @TypeOf(c.janet_table_put), @TypeOf(capi.janet_table_put) },
                .{ "janet_table_remove", @TypeOf(c.janet_table_remove), @TypeOf(capi.janet_table_remove) },
            });
        }
        if (options.tuples) {
            report = report ++ checkFile(.{
                .{ "janet_tuple_begin", @TypeOf(c.janet_tuple_begin), @TypeOf(capi.janet_tuple_begin) },
                .{ "janet_tuple_end", @TypeOf(c.janet_tuple_end), @TypeOf(capi.janet_tuple_end) },
            });
        }
        if (options.utilities) {
            report = report ++ checkFile(.{
                .{ "janet_abstract_head", @TypeOf(c.janet_abstract_head), @TypeOf(capi.janet_abstract_head) },
                .{ "janet_string_head", @TypeOf(c.janet_string_head), @TypeOf(capi.janet_string_head) },
                .{ "janet_struct_head", @TypeOf(c.janet_struct_head), @TypeOf(capi.janet_struct_head) },
                .{ "janet_tuple_head", @TypeOf(c.janet_tuple_head), @TypeOf(capi.janet_tuple_head) },
            });
        }
        if (options.vm_entry) {
            report = report ++ checkFile(.{
                .{ "janet_pcall", @TypeOf(c.janet_pcall), @TypeOf(capi.janet_pcall) },
            });
        }
        if (options.wrap) {
            report = report ++ checkFile(.{
                .{ "janet_unwrap_function", @TypeOf(c.janet_unwrap_function), @TypeOf(capi.janet_unwrap_function) },
                .{ "janet_unwrap_integer", @TypeOf(c.janet_unwrap_integer), @TypeOf(capi.janet_unwrap_integer) },
                .{ "janet_unwrap_pointer", @TypeOf(c.janet_unwrap_pointer), @TypeOf(capi.janet_unwrap_pointer) },
            });
        }
        if (options.wrap and config.value_repr == .nanbox_32) {
            report = report ++ checkFile(.{
                .{ "janet_nanbox32_from_tagi", @TypeOf(c.janet_nanbox32_from_tagi), @TypeOf(capi.janet_nanbox32_from_tagi) },
                .{ "janet_nanbox32_from_tagp", @TypeOf(c.janet_nanbox32_from_tagp), @TypeOf(capi.janet_nanbox32_from_tagp) },
            });
        }
        if (options.wrap and config.value_repr == .nanbox_64) {
            report = report ++ checkFile(.{
                .{ "janet_nanbox_from_bits", @TypeOf(c.janet_nanbox_from_bits), @TypeOf(capi.janet_nanbox_from_bits) },
                .{ "janet_nanbox_from_cpointer", @TypeOf(c.janet_nanbox_from_cpointer), @TypeOf(capi.janet_nanbox_from_cpointer) },
                .{ "janet_nanbox_from_double", @TypeOf(c.janet_nanbox_from_double), @TypeOf(capi.janet_nanbox_from_double) },
                .{ "janet_nanbox_from_pointer", @TypeOf(c.janet_nanbox_from_pointer), @TypeOf(capi.janet_nanbox_from_pointer) },
                .{ "janet_nanbox_to_pointer", @TypeOf(c.janet_nanbox_to_pointer), @TypeOf(capi.janet_nanbox_to_pointer) },
            });
        }
        if (report.len != 0) @compileError("declarations disagree with the definitions they name:" ++ report);
    }
}
