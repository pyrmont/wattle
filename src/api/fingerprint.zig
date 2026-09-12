//! The shape of the interface a module and the runtime share, as one number.
//!
//! `api` is that number. Both compilations compile this file, so both compute
//! it from the same source: the runtime puts its own in `build_config`, a
//! module reports the same field through `_janet_mod_config`, and
//! `runtime/env.zig`'s `native` refuses the module unless the two are equal.
//! A module and a runtime with the same `api` were built against the same
//! interface, whatever Janet release either of them came from.
//!
//! ## What the number covers
//!
//! The _description_ is a string built at comptime that spells out every
//! declaration the two compilations must agree on, and `api` is its hash.
//! `covered` is the list, in the order the description spells it: the runtime
//! table, the value representation, the layouts that cross by pointer, the two
//! enums, the six capabilities, and the Zig-convention signatures a module
//! writes. `abstract_payload` follows them, because a module subtracts it to
//! reach an abstract's header.
//!
//! The configuration bits are not in it. `constants.JANET_CURRENT_CONFIG_BITS`
//! records the options a build was configured with, the loader compares that
//! field on its own, and a refusal names whichever of the two differed. What
//! a configured option changes about a layout is in the description anyway,
//! because the layout is described as it is compiled: `repr.Value` under
//! `-Dnanbox=false` is a different shape and gives a different `api`.
//!
//! ## How a type is described
//!
//! `typeDesc` writes structure and not names. For an integer it writes the
//! signedness and the width, for a pointer the size, the constness, the
//! sentinel and the pointee, for a struct the container layout, the size, the
//! alignment and each field's name, offset and type, for an enum each member's
//! name and value, and for a function the calling convention, the parameters
//! and the return. It recurses into every one of those.
//!
//! A type's name is never hashed. A module is a separate compilation and a
//! qualified type name can differ between two graphs that declare the same
//! type, so a name would make two identical interfaces look different. The
//! exception is a primitive, whose name is its structure.
//!
//! An `opaque` has no structure to describe, so the six capabilities would
//! otherwise be indistinguishable from each other. Each of the six has a
//! label in `capabilities`, and `typeDesc` writes that label, so a crossing
//! that takes a `*Env` differs from a crossing that takes a `*Loop`. An
//! `opaque` `capabilities` has no label for is a compile error, so a seventh
//! capability is named there before it can reach the description. `anyopaque`
//! is written as itself.
//!
//! `path` is the chain of types `typeDesc` is inside. A type already on it is
//! written as a back-reference rather than described again, which is what
//! terminates on a recursive type: `abi.GCData` has a pointer to the
//! `abi.GCObject` that contains it.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const config = @import("config");
const constants = @import("constants");
const interface = @import("interface.zig");
const module = @import("../module.zig");
const repr = @import("repr");

// ==========================================================================
// Constants
// ==========================================================================

/// The hash of the description, and the number the loader compares.
pub const api: u64 = digest(description);

/// What this build reports to a loader, and what the loader compares a
/// module's report against.
///
/// `module.entry`'s `_janet_mod_config` writes this, and `runtime/env.zig`'s
/// `native` reads both this and the module's copy. `major`, `minor` and
/// `patch` are reported in a refusal and are not compared.
pub const build_config: abi.BuildConfig = .{
    .major = config.version_major,
    .minor = config.version_minor,
    .patch = config.version_patch,
    .bits = constants.JANET_CURRENT_CONFIG_BITS,
    .api = api,
    .zig = zig_version,
};

/// The six capabilities, each with the label `typeDesc` writes for it.
///
/// The order is the description's, so a member added, removed or moved
/// changes `api`. A capability missing from this list is a compile error in
/// `typeDesc` rather than a shape shared with every other unlabelled
/// `opaque`.
const capabilities = [_]struct { name: []const u8, type: type }{
    .{ .name = "Env", .type = abi.Env },
    .{ .name = "Loop", .type = abi.Loop },
    .{ .name = "Marshal", .type = abi.Marshal },
    .{ .name = "Render", .type = abi.Render },
    .{ .name = "Unmarshal", .type = abi.Unmarshal },
    .{ .name = "Wake", .type = abi.Wake },
};

/// Every declaration the description spells out, each with the label it is
/// spelled under.
///
/// The order is the description's, so a member added, removed or moved
/// changes `api`. The labels are written here rather than taken from
/// `@typeName`, for the reason the file header gives.
const covered = [_]struct { name: []const u8, type: type }{
    .{ .name = "Runtime", .type = interface.Runtime },
    .{ .name = "Value", .type = repr.Value },
    .{ .name = "Tag", .type = repr.Tag },
    .{ .name = "Signal", .type = abi.Signal },
    .{ .name = "FiberStatus", .type = abi.FiberStatus },
    .{ .name = "AbstractHead", .type = abi.AbstractHead },
    .{ .name = "AbstractType", .type = abi.AbstractType },
    .{ .name = "BuildConfig", .type = abi.BuildConfig },
    .{ .name = "ByteView", .type = abi.ByteView },
    .{ .name = "DictView", .type = abi.DictView },
    .{ .name = "IndexedView", .type = abi.IndexedView },
    .{ .name = "KV", .type = abi.KV },
    .{ .name = "Range", .type = abi.Range },
    .{ .name = "Reg", .type = abi.Reg },
    .{ .name = "AtomicInt", .type = abi.AtomicInt },
    .{ .name = "abi.CFunction", .type = abi.CFunction },
    .{ .name = "Env", .type = abi.Env },
    .{ .name = "Loop", .type = abi.Loop },
    .{ .name = "Marshal", .type = abi.Marshal },
    .{ .name = "Render", .type = abi.Render },
    .{ .name = "Unmarshal", .type = abi.Unmarshal },
    .{ .name = "Wake", .type = abi.Wake },
    .{ .name = "module.CFunction", .type = module.CFunction },
    .{ .name = "module.Error", .type = module.Error },
    .{ .name = "module.PostCallback", .type = module.PostCallback },
};

/// The whole of what `api` hashes.
const description: []const u8 = blk: {
    @setEvalBranchQuota(40_000_000);
    var text: []const u8 = "janet-module-interface\n";
    for (covered) |entry| text = text ++ entry.name ++ "=" ++ typeDesc(entry.type, &.{}) ++ "\n";
    text = text ++ std.fmt.comptimePrint("abstract_payload={d}\n", .{abi.abstract_payload});
    break :blk text;
};

/// The compiler's version, NUL-padded to the width `abi.BuildConfig` gives it.
///
/// The whole string is kept rather than the three numbers, so that a release
/// and a development build of the same release compare unequal.
const zig_version: [32]u8 = blk: {
    const text = builtin.zig_version_string;
    if (text.len > 32) @compileError(
        "the Zig version string is longer than `abi.BuildConfig.zig`",
    );
    var padded: [32]u8 = std.mem.zeroes([32]u8);
    @memcpy(padded[0..text.len], text);
    break :blk padded;
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Spells `v` as sixteen lowercase hexadecimal digits.
///
/// The result is NUL-terminated, so a caller printing it with `%s` needs no
/// second buffer. This function cannot raise.
pub fn hex(v: u64) [16:0]u8 {
    var out: [16:0]u8 = std.mem.zeroes([16:0]u8);
    _ = std.fmt.bufPrint(&out, "{x:0>16}", .{v}) catch unreachable;
    return out;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Hashes the description.
///
/// Wyhash rather than a hash written out here, because it runs at comptime as
/// it stands and both compilations run the same standard library.
fn digest(comptime text: []const u8) u64 {
    @setEvalBranchQuota(40_000_000);
    return std.hash.Wyhash.hash(0, text);
}

/// The offset of `field` within `T`, in bits for a packed container and in
/// bytes for any other.
///
/// A comptime field occupies no storage and has no offset, and is reported as
/// zero.
fn fieldOffset(
    comptime T: type,
    comptime layout: std.builtin.Type.ContainerLayout,
    comptime field: std.builtin.Type.StructField,
) usize {
    if (field.is_comptime) return 0;
    return if (layout == .@"packed") @bitOffsetOf(T, field.name) else @offsetOf(T, field.name);
}

/// A sentinel value as the description spells it.
///
/// `child` is the element type and `sentinel_ptr` the field `@typeInfo` gives
/// for an array or a pointer. A type without a sentinel is written as a dash.
/// `child` is read only where there is one, so an `anyopaque` pointee reaches
/// this and returns.
fn sentinelText(comptime child: type, comptime sentinel_ptr: ?*const anyopaque) []const u8 {
    comptime {
        const held: *const child = @ptrCast(@alignCast(sentinel_ptr orelse return "-"));
        return std.fmt.comptimePrint("{any}", .{held.*});
    }
}

/// The error names of `T`, in ascending order.
///
/// `T` is an error set with at least one member. The order a set is declared
/// in is not the order `@typeInfo` has to report, so the names are sorted
/// before they reach the description.
fn sortedErrors(comptime T: type) []const []const u8 {
    comptime {
        const errors = @typeInfo(T).error_set.?;
        var names: [errors.len][]const u8 = undefined;
        for (errors, 0..) |e, i| names[i] = e.name;
        if (names.len > 1) for (1..names.len) |i| {
            var j = i;
            while (j > 0 and std.mem.lessThan(u8, names[j], names[j - 1])) : (j -= 1) {
                std.mem.swap([]const u8, &names[j], &names[j - 1]);
            }
        };
        const frozen = names;
        return &frozen;
    }
}

/// The structure of `T`, as a string.
///
/// `path` is the chain of types this call is inside, outermost first. A `T`
/// already on it is written as `back(n)`, where `n` counts back to it, and is
/// not described again. A caller starts with an empty path.
///
/// A type that cannot appear on the module boundary is a compile error naming
/// the kind, and so is an `opaque` that `capabilities` has no label for.
fn typeDesc(comptime T: type, comptime path: []const type) []const u8 {
    comptime {
        @setEvalBranchQuota(40_000_000);
        for (path, 0..) |seen, i| {
            if (seen == T) return std.fmt.comptimePrint("back({d})", .{path.len - i});
        }
        if (T == anyopaque) return "anyopaque";
        const inner = path ++ [_]type{T};
        return switch (@typeInfo(T)) {
            .type => "type",
            .void => "void",
            .bool => "bool",
            .noreturn => "noreturn",
            .undefined => "undefined",
            .null => "null",
            .comptime_int => "comptime_int",
            .comptime_float => "comptime_float",
            .enum_literal => "enum_literal",
            .int => |i| std.fmt.comptimePrint("int({s},{d})", .{ @tagName(i.signedness), i.bits }),
            .float => |f| std.fmt.comptimePrint("float({d})", .{f.bits}),
            .optional => |o| "opt(" ++ typeDesc(o.child, inner) ++ ")",
            .vector => |v| std.fmt.comptimePrint("vec({d},", .{v.len}) ++
                typeDesc(v.child, inner) ++ ")",
            .array => |a| std.fmt.comptimePrint("arr({d},{s},", .{
                a.len,
                sentinelText(a.child, a.sentinel_ptr),
            }) ++ typeDesc(a.child, inner) ++ ")",
            .pointer => |p| std.fmt.comptimePrint("ptr({s},{},{},{},{?d},{s},", .{
                @tagName(p.size),
                p.is_const,
                p.is_volatile,
                p.is_allowzero,
                p.alignment,
                sentinelText(p.child, p.sentinel_ptr),
            }) ++ typeDesc(p.child, inner) ++ ")",
            .error_union => |eu| "eu(" ++ typeDesc(eu.error_set, inner) ++ "," ++
                typeDesc(eu.payload, inner) ++ ")",
            .error_set => |maybe| blk: {
                if (maybe == null) break :blk "anyerror";
                var text: []const u8 = "errorset{";
                for (sortedErrors(T)) |name| text = text ++ name ++ ";";
                break :blk text ++ "}";
            },
            .@"enum" => |e| blk: {
                var text: []const u8 = "enum(" ++ typeDesc(e.tag_type, inner) ++
                    std.fmt.comptimePrint(",{}){{", .{e.is_exhaustive});
                for (e.fields) |f| text = text ++
                    std.fmt.comptimePrint("{s}={d};", .{ f.name, f.value });
                break :blk text ++ "}";
            },
            .@"struct" => |s| blk: {
                var text: []const u8 = std.fmt.comptimePrint("struct({s},{d},{d},{}){{", .{
                    @tagName(s.layout),
                    @sizeOf(T),
                    @alignOf(T),
                    s.is_tuple,
                });
                if (s.backing_integer) |B| text = text ++ "backing=" ++ typeDesc(B, inner) ++ ";";
                for (s.fields) |f| text = text ++ f.name ++ ":" ++ typeDesc(f.type, inner) ++
                    std.fmt.comptimePrint("@{d}:{?d}:{}:{};", .{
                        fieldOffset(T, s.layout, f),
                        f.alignment,
                        f.is_comptime,
                        f.default_value_ptr != null,
                    });
                break :blk text ++ "}";
            },
            .@"union" => |u| blk: {
                var text: []const u8 = std.fmt.comptimePrint("union({s},{d},{d}){{", .{
                    @tagName(u.layout),
                    @sizeOf(T),
                    @alignOf(T),
                });
                if (u.tag_type) |Tag| text = text ++ "tag=" ++ typeDesc(Tag, inner) ++ ";";
                for (u.fields) |f| text = text ++ f.name ++ ":" ++ typeDesc(f.type, inner) ++
                    std.fmt.comptimePrint(":{?d};", .{f.alignment});
                break :blk text ++ "}";
            },
            .@"fn" => |f| blk: {
                var text: []const u8 = std.fmt.comptimePrint("fn({s},{},{})(", .{
                    @tagName(f.calling_convention),
                    f.is_generic,
                    f.is_var_args,
                });
                for (f.params) |p| {
                    text = text ++ (if (p.type) |P| typeDesc(P, inner) else "generic") ++
                        std.fmt.comptimePrint(":{};", .{p.is_noalias});
                }
                break :blk text ++ ")->" ++
                    (if (f.return_type) |R| typeDesc(R, inner) else "generic");
            },
            .@"opaque" => blk: {
                for (capabilities) |cap| {
                    if (cap.type == T) break :blk "opaque(" ++ cap.name ++ ")";
                }
                @compileError(
                    "an `opaque` with no label reached `typeDesc`. An `opaque` has no " ++
                        "structure to hash, so two unlabelled ones would be one shape. " ++
                        "Add the type to `fingerprint.capabilities` with a label of its own.",
                );
            },
            .frame, .@"anyframe" => @compileError(
                "a frame cannot appear on the module boundary and has no description",
            ),
        };
    }
}

// ==========================================================================
// Tests
// ==========================================================================

test "the description hashes to the published number" {
    try std.testing.expectEqual(api, std.hash.Wyhash.hash(0, description));
    try std.testing.expectEqual(api, digest(description));
}

test "the hexadecimal spelling is sixteen digits and reads back" {
    const spelled = hex(api);
    try std.testing.expectEqual(@as(usize, 16), std.mem.len(@as([*:0]const u8, &spelled)));
    try std.testing.expectEqual(api, try std.fmt.parseInt(u64, &spelled, 16));
    try std.testing.expectEqualStrings("000000000000002a", &hex(42));
}

test "a field's name, type, order and width each change the fingerprint" {
    // Four structs against one baseline, each differing from it in one way.
    // The baseline's own fingerprint is taken twice, so the first assertion
    // is that describing one type twice gives one answer.
    const Base = struct { a: u32, b: u32 };
    const Renamed = struct { a: u32, c: u32 };
    const Retyped = struct { a: u32, b: i32 };
    const Reordered = struct { b: u32, a: u32 };
    const Widened = struct { a: u32, b: u64 };

    const base = digest(typeDesc(Base, &.{}));
    try std.testing.expectEqual(base, digest(typeDesc(Base, &.{})));
    try std.testing.expect(base != digest(typeDesc(Renamed, &.{})));
    try std.testing.expect(base != digest(typeDesc(Retyped, &.{})));
    try std.testing.expect(base != digest(typeDesc(Reordered, &.{})));
    try std.testing.expect(base != digest(typeDesc(Widened, &.{})));
}

test "an auto-layout twin of an extern struct describes differently" {
    // The container layout is in the description, so two structs laid out the
    // same way under two layouts are two shapes. `abi.Range` is `extern`, and
    // this has its field names, its field types and its defaults.
    const Twin = struct { start: i32 = 0, end: i32 = 0 };
    try std.testing.expect(@sizeOf(abi.Range) == @sizeOf(Twin));
    try std.testing.expect(digest(typeDesc(abi.Range, &.{})) != digest(typeDesc(Twin, &.{})));
}

test "an enum's member names and values each change the fingerprint" {
    const Base = enum(u8) { one = 1, two = 2 };
    const Renumbered = enum(u8) { one = 1, two = 3 };
    const Renamed = enum(u8) { one = 1, three = 2 };
    const Rewidened = enum(u16) { one = 1, two = 2 };

    const base = digest(typeDesc(Base, &.{}));
    try std.testing.expect(base != digest(typeDesc(Renumbered, &.{})));
    try std.testing.expect(base != digest(typeDesc(Renamed, &.{})));
    try std.testing.expect(base != digest(typeDesc(Rewidened, &.{})));
}

test "a signature's convention, parameters and return each change the fingerprint" {
    const Base = *const fn (a: u32) callconv(.c) u32;
    const Reconvened = *const fn (a: u32) u32;
    const Reparametered = *const fn (a: u32, b: u32) callconv(.c) u32;
    const Rereturned = *const fn (a: u32) callconv(.c) i32;

    const base = digest(typeDesc(Base, &.{}));
    try std.testing.expect(base != digest(typeDesc(Reconvened, &.{})));
    try std.testing.expect(base != digest(typeDesc(Reparametered, &.{})));
    try std.testing.expect(base != digest(typeDesc(Rereturned, &.{})));
}

test "a recursive type terminates on a back-reference" {
    // The type reached again is three links up: the struct, the optional and
    // the pointer. Reaching it a second time is what the assertion is about,
    // and the count is left out of it.
    const Node = struct { next: ?*@This(), value: u32 };
    const text = comptime typeDesc(Node, &.{});
    try std.testing.expect(std.mem.indexOf(u8, text, "back(") != null);
}

comptime {
    // The six capabilities are `opaque {}` and have no structure, so the
    // labels above are the whole of what tells them apart. Two labels the same
    // would make two capabilities one shape.
    for (capabilities, 0..) |cap, i| {
        for (capabilities[i + 1 ..]) |other| {
            if (std.mem.eql(u8, cap.name, other.name)) @compileError(
                "two capabilities share the label `" ++ cap.name ++ "`",
            );
            if (cap.type == other.type) @compileError(
                "the capability `" ++ cap.name ++ "` is listed twice",
            );
        }
    }
}
