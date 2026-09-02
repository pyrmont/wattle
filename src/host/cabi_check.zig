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
//! **`crossings.zig` is checked here too, and that is what lets it exist.**
//! `tools/check/seam.janet` forbids an `extern fn janet*` outside `cabi.zig`
//! for one stated reason -- that this file compares every declaration there
//! against its definition -- so a second file of `extern fn janet*` is
//! allowed only by extending the comparison rather than the exemption. Its
//! six are the same six `cabi.zig` declares for the runtime's own
//! compilation, and both are compared against the one definition, so the two
//! spellings cannot drift from each other without drifting from it.
//!
//! **The imports are gated the way `root.zig` gates them**, and they have to
//! be: an `export fn` is emitted because its file is in the compilation, not
//! because something calls it, so importing `ev/backend.zig` in a `-Dev=false`
//! build compiles code whose VM state has no `selfpipe` field. An instrument
//! must be gated the way its subject is.

const std = @import("std");
const c = @import("cabi");
const crossings = @import("../api/crossings.zig");
const capi = @import("../runtime/capi.zig");
const wrap = @import("../runtime/value/helpers/wrap.zig");
const args = @import("../runtime/args.zig");
const abi = @import("abi");
const tables = @import("../runtime/value/tables.zig");
const buffers = @import("../runtime/value/buffers.zig");

/// Whether a declared type and a defined one are the same type.
///
/// **Exactly the same**, with no exemption for pointer flavour: nothing in
/// `cabi.zig` is translated, so `[*c]T` never appears on one side of a pair
/// and a loose comparison would only hide a real disagreement.
///
/// **What a loose one hid.** Tightening to equality reported two
/// disagreements in the population it had been checking all along, both
/// nullability: a buffer
/// push declared `[*]const u8` for a definition that reads to a sentinel, and
/// a protected call declared its argument vector and its callee non-optional
/// where the definition accepts null for both. Both crossings went with the
/// contraction to 27 published names; a dropped sentinel and a lost null are
/// exactly what a linker cannot catch, so keep this exact.
///
/// `agrees` below compares every field of `Fn` and of each `Param`: the
/// convention, varargs, genericity, the return type, and each parameter's type
/// and `noalias`. Whole-type equality is tried first and is what usually
/// answers; the field walk exists only to produce a readable diagnostic.
fn compatible(comptime A: type, comptime B: type) bool {
    if (A == B) return true;
    return sameHandle(A, B);
}

/// The one equivalence this comparison admits, and it is a declared one.
///
/// `abi.Table` and `abi.Buffer` are `opaque {}`: they exist so that an author's
/// compilation can hold a pointer to a runtime aggregate **without being able
/// to see inside it**, which is the whole reason `abi.zig` is a module of its
/// own. So the author-side declaration of `janet_def` genuinely says
/// `*abi.Table` where the definition genuinely says `*tables.Table`, and the
/// two are the same pointer at the symbol.
///
/// It is written as a table rather than as "ignore the pointee" because that is
/// the loose comparison this file's header records tightening: exempting
/// pointer flavour hid a dropped sentinel and two lost nullabilities. Two named
/// pairs hide nothing -- and only the pointee is substituted, so optionality,
/// constness and sentinel still have to match exactly.
fn sameHandle(comptime A: type, comptime B: type) bool {
    comptime {
        var a = @typeInfo(A);
        var b = @typeInfo(B);
        // Optionality is compared, not stripped: `*T` and `?*T` are different
        // promises and only one of them may be null.
        if (a == .optional and b == .optional) {
            a = @typeInfo(a.optional.child);
            b = @typeInfo(b.optional.child);
        }
        if (a != .pointer or b != .pointer) return false;
        const pa = a.pointer;
        const pb = b.pointer;
        if (pa.size != pb.size) return false;
        if (pa.is_const != pb.is_const) return false;
        if (pa.is_volatile != pb.is_volatile) return false;
        if (pa.is_allowzero != pb.is_allowzero) return false;
        if ((pa.sentinel_ptr == null) != (pb.sentinel_ptr == null)) return false;
        return opaqueFor(pa.child, pb.child) or opaqueFor(pb.child, pa.child);
    }
}

fn opaqueFor(comptime handle: type, comptime real: type) bool {
    return (handle == abi.Table and real == tables.Table) or
        (handle == abi.Buffer and real == buffers.Buffer);
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
    comptime {
        var report: []const u8 = "";
        report = report ++ checkFile(.{
            .{ "janet_cstring", @TypeOf(c.janet_cstring), @TypeOf(capi.janet_cstring) },
            .{ "janet_wrap_string", @TypeOf(c.janet_wrap_string), @TypeOf(wrap.abi.fromString) },
            .{ "janet_zig_c_raise_record", @TypeOf(c.janet_zig_c_raise_record), @TypeOf(capi.janet_zig_c_raise_record) },
            .{ "janet_zig_c_raise_take", @TypeOf(c.janet_zig_c_raise_take), @TypeOf(capi.janet_zig_c_raise_take) },
            .{ "janet_zig_fatal", @TypeOf(c.janet_zig_fatal), @TypeOf(capi.janet_zig_fatal) },
            .{ "janet_zig_signal_record", @TypeOf(c.janet_zig_signal_record), @TypeOf(capi.janet_zig_signal_record) },
        });
        // The six `raise.zig` calls from inside a module's compilation, as
        // `crossings.zig` declares them.
        report = report ++ checkFile(.{
            .{ "janet_cstring", @TypeOf(crossings.janet_cstring), @TypeOf(capi.janet_cstring) },
            .{ "janet_wrap_string", @TypeOf(crossings.janet_wrap_string), @TypeOf(wrap.abi.fromString) },
            .{ "janet_zig_c_raise_record", @TypeOf(crossings.janet_zig_c_raise_record), @TypeOf(capi.janet_zig_c_raise_record) },
            .{ "janet_zig_c_raise_take", @TypeOf(crossings.janet_zig_c_raise_take), @TypeOf(capi.janet_zig_c_raise_take) },
            .{ "janet_zig_fatal", @TypeOf(crossings.janet_zig_fatal), @TypeOf(capi.janet_zig_fatal) },
            .{ "janet_zig_signal_record", @TypeOf(crossings.janet_zig_signal_record), @TypeOf(capi.janet_zig_signal_record) },
        });

        // **The twenty-one `module.zig` calls.** They are the whole of the
        // author boundary, and an author's `.so` is the one compilation where
        // a disagreement is not this project's crash to debug.
        report = report ++ checkFile(.{
            .{ "janet_fixarity", @TypeOf(crossings.janet_fixarity), @TypeOf(args.fixArityAbi) },
            .{ "janet_arity", @TypeOf(crossings.janet_arity), @TypeOf(args.checkArityAbi) },
            .{ "janet_getnumber", @TypeOf(crossings.janet_getnumber), @TypeOf(args.GetNumber.abi) },
            .{ "janet_getinteger", @TypeOf(crossings.janet_getinteger), @TypeOf(args.GetInteger.abi) },
            .{ "janet_getsize", @TypeOf(crossings.janet_getsize), @TypeOf(args.GetSize.abi) },
            .{ "janet_getabstract", @TypeOf(crossings.janet_getabstract), @TypeOf(args.getAbstractAbi) },
            .{ "janet_wrap_number", @TypeOf(crossings.janet_wrap_number), @TypeOf(wrap.abi.fromNumber) },
            .{ "janet_wrap_nil", @TypeOf(crossings.janet_wrap_nil), @TypeOf(wrap.abi.fromNil) },
            .{ "janet_wrap_abstract", @TypeOf(crossings.janet_wrap_abstract), @TypeOf(wrap.abi.fromAbstract) },
            .{ "janet_abstract", @TypeOf(crossings.janet_abstract), @TypeOf(capi.janet_abstract) },
            .{ "janet_calloc", @TypeOf(crossings.janet_calloc), @TypeOf(capi.janet_calloc) },
            .{ "janet_free", @TypeOf(crossings.janet_free), @TypeOf(capi.janet_free) },
            .{ "janet_cfuns_ext", @TypeOf(crossings.janet_cfuns_ext), @TypeOf(capi.janet_cfuns_ext) },
            .{ "janet_def", @TypeOf(crossings.janet_def), @TypeOf(capi.janet_def) },
            .{ "janet_checkint", @TypeOf(crossings.janet_checkint), @TypeOf(capi.janet_checkint) },
            .{ "janet_checktype", @TypeOf(crossings.janet_checktype), @TypeOf(capi.janet_checktype) },
            .{ "janet_unwrap_integer", @TypeOf(crossings.janet_unwrap_integer), @TypeOf(capi.janet_unwrap_integer) },
            .{ "janet_unwrap_number", @TypeOf(crossings.janet_unwrap_number), @TypeOf(capi.janet_unwrap_number) },
            .{ "janet_unwrap_keyword", @TypeOf(crossings.janet_unwrap_keyword), @TypeOf(capi.janet_unwrap_keyword) },
            .{ "janet_getmethod", @TypeOf(crossings.janet_getmethod), @TypeOf(capi.janet_getmethod) },
            .{ "janet_nextmethod", @TypeOf(crossings.janet_nextmethod), @TypeOf(capi.janet_nextmethod) },
        });
        if (report.len != 0) @compileError("an extern declaration disagrees with its definition:" ++ report);
    }
}
