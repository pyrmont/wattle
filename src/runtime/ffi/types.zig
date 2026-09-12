//! The FFI's type vocabulary: what a primitive is, what a calling convention
//! is, and how a struct is laid out.
//!
//! One half decides and the other measures, and neither has a name of its own,
//! since every `ffi/` cfunction is registered in `ffi.zig`. They are a leaf
//! rather than part of a bucket because `ffi/` is designed as a group.
//!
//! `decodeCc` and `decodePrim` are not duplicates of `lookupCc` and
//! `lookupPrim`. The first pair raises and is what `ffi/call.zig` reaches; the
//! second reports an index or -1 and is what `test/ffi_layout.zig` reaches,
//! along with `Layout` and `typeExtent`, which it drives directly.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const abstract_type = @import("../../api/abstract_type.zig");
const abstracts = @import("../value/abstracts.zig");
const args_core = @import("../args.zig");
const config = @import("config");
const gc_mark = @import("../gc/mark.zig");
const pp_format = @import("../pp/format.zig");
const raise = @import("../../api/raise.zig");
const repr = @import("repr");
const strings = @import("../value/strings.zig");
const utils = @import("../utils.zig");
const wrap = @import("../value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

pub const aapcs64_enabled = !windows and builtin.cpu.arch == .aarch64;

/// The calling conventions that have a name of their own. `default` is not
/// here: it resolves to whichever convention the build enables, which is a
/// property of the target rather than of the name, so `decodeCc` maps it.
const cc_names = [_]NamedCc{
    .{ "none", .none },
    .{ "sysv64", .sysv64 },
    .{ "win64", .win64 },
    .{ "aapcs64", .aapcs64 },
};

/// What `:default` resolves to, which is a property of the target rather
/// than of the name.
pub const default_cc: Cc = if (win64_enabled)
    .win64
else if (sysv64_enabled)
    .sysv64
else if (aapcs64_enabled)
    .aapcs64
else
    .none;

/// Selects the width of the `size` and `ssize` machine types. Read from the
/// build's configuration rather than inferred from the target, so that the two
/// cannot disagree.
const is_64_bit = config.bits64;

/// The most arguments a signature may take. `cfunSignature` checks it: the
/// mapping and slot arrays are sized by it.
pub const max_args: u32 = 32;

pub const max_recur: c_int = 64;

/// Every machine-type name a signature may use, in order: the primary names,
/// the word-size-dependent pair, then the aliases. `struct` has no name of its
/// own, a struct type being written as a tuple rather than a keyword.
const prim_names = [_]NamedPrim{
    .{ "void", .void },
    .{ "bool", .bool },
    .{ "ptr", .ptr },
    .{ "pointer", .ptr },
    .{ "string", .string },
    .{ "float", .float },
    .{ "double", .double },
    .{ "int8", .int8 },
    .{ "uint8", .uint8 },
    .{ "int16", .int16 },
    .{ "uint16", .uint16 },
    .{ "int32", .int32 },
    .{ "uint32", .uint32 },
    .{ "int64", .int64 },
    .{ "uint64", .uint64 },
    .{ "size", if (is_64_bit) .uint64 else .uint32 },
    .{ "ssize", if (is_64_bit) .int64 else .int32 },
    .{ "r32", .float },
    .{ "r64", .double },
    .{ "s8", .int8 },
    .{ "u8", .uint8 },
    .{ "s16", .int16 },
    .{ "u16", .uint16 },
    .{ "s32", .int32 },
    .{ "u32", .uint32 },
    .{ "s64", .int64 },
    .{ "u64", .uint64 },
    .{ "char", .int8 },
    .{ "short", .int16 },
    .{ "int", .int32 },
    .{ "long", .int64 },
    .{ "byte", .uint8 },
    .{ "uchar", .uint8 },
    .{ "ushort", .uint16 },
    .{ "uint", .uint32 },
    .{ "ulong", .uint64 },
};

/// The signature's abstract type. Every field after `gcmark` is null, which
/// the structure already defaults them to.
pub const signature_at = abstract_type.define(Signature, .{
    .name = "core/ffi-signature",
    .gcmark = &signatureMark,
});

/// The FFI struct's abstract type.
pub const struct_at = abstract_type.define(Struct, .{
    .name = "core/ffi-struct",
    .gcmark = &structMark,
});

pub const sysv64_enabled = !windows and builtin.cpu.arch == .x86_64;
pub const win64_enabled = windows and builtin.cpu.arch == .x86_64;

pub const windows = builtin.os.tag == .windows;

// ==========================================================================
// Types
// ==========================================================================

/// The calling conventions the trampolines implement.
const CallingConvention = enum(i32) {
    none = 0,
    sysv64 = 1,
    win64 = 2,
    aapcs64 = 3,
};

/// The calling conventions a signature can name.
pub const Cc = enum(u32) {
    none = 0,
    sysv64 = 1,
    win64 = 2,
    aapcs64 = 3,
};

pub const Layout = extern struct {
    size: u32,
    alignment: u32,
    is_aligned: u32,

    /// An empty layout: no bytes, alignment one, and still aligned.
    pub fn init() Layout {
        return .{ .size = 0, .alignment = 1, .is_aligned = 1 };
    }

    /// Place one field and report the offset it takes.
    ///
    /// `el_align` must not be zero: the caller rejects a zero-aligned field
    /// with a panic immediately before calling, because that panic can name
    /// the offending Janet value and this cannot.
    ///
    /// A packed field is laid down where the cursor stands and contributes
    /// nothing to the struct's alignment, but a packed field that happens to
    /// land off its natural boundary clears `is_aligned`. That flag records
    /// whether the layout could have been produced without packing, which is
    /// what the callback path later relies on.
    ///
    /// `packed_field` is a `bool`. The one caller builds it from two keyword
    /// tests, and the flag deciding padding
    /// is the sort of argument a bare `0` at a call site says nothing about.
    pub fn place(self: *Layout, el_size: usize, el_align: usize, packed_field: bool) usize {
        if (packed_field) {
            if (@as(usize, self.size) % el_align != 0) self.is_aligned = 0;
            const offset = self.size;
            self.size = self.size +% @as(u32, @truncate(el_size));
            return offset;
        }
        if (el_align > self.alignment) self.alignment = @truncate(el_align);
        const aligned = ((@as(usize, self.size) +% el_align -% 1) / el_align) *% el_align;
        const offset: u32 = @truncate(aligned);
        self.size = @truncate(el_size +% offset);
        return offset;
    }

    /// Round the total up to the struct's own alignment, which is what makes an
    /// array of the struct place every element correctly.
    pub fn finish(self: *Layout) void {
        self.size = self.size +% (self.alignment -% 1);
        self.size = self.size / self.alignment;
        self.size = self.size *% self.alignment;
    }
};

/// One argument as a convention sees it.
pub const Mapping = extern struct {
    type: Type,
    spec: Spec,
    /// The register number or stack offset, according to `spec`.
    offset: u32,
    /// Where a by-reference argument's payload lives.
    offset2: u32,

    /// `void_mapping`.
    pub fn empty() Mapping {
        return .{
            .type = Type.of(.void),
            .spec = .sysv64_no_class,
            .offset = 0,
            // Every caller overwrites the whole mapping before reading it,
            // so the zero here is only what an unread field starts at.
            .offset2 = 0,
        };
    }
};

const NamedCc = struct { []const u8, CallingConvention };

const NamedPrim = struct { []const u8, PrimType };

pub const Prim = enum(u32) {
    void = 0,
    bool = 1,
    ptr = 2,
    string = 3,
    float = 4,
    double = 5,
    int8 = 6,
    uint8 = 7,
    int16 = 8,
    uint16 = 9,
    int32 = 10,
    uint32 = 11,
    int64 = 12,
    uint64 = 13,
    @"struct" = 14,
};

const PrimInfo = struct { size: usize, alignment: usize };

const PrimType = enum(i32) {
    void = 0,
    bool = 1,
    ptr = 2,
    string = 3,
    float = 4,
    double = 5,
    int8 = 6,
    uint8 = 7,
    int16 = 8,
    uint16 = 9,
    int32 = 10,
    uint32 = 11,
    int64 = 12,
    uint64 = 13,
    @"struct" = 14,
};

/// A described call: the convention, the return, and the arguments.
///
/// `arg_stack_words` is where Janet has `word_count`, a field
/// `cfun_ffi_signature` never writes and nothing ever reads. The outgoing half
/// of the frame measured in words, which is the rung a call selects, goes in
/// that slot. Nothing outside these files sees this structure.
pub const Signature = extern struct {
    frame_size: u32,
    arg_count: u32,
    arg_stack_words: u32,
    variant: u32,
    stack_count: u32,
    cc: Cc,
    ret: Mapping,
    args: [max_args]Mapping,
};

/// The class a classifier reached, and afterwards the
/// placement an allocator chose.
pub const Spec = enum(u32) {
    sysv64_integer = 0,
    sysv64_sse = 1,
    sysv64_sseup = 2,
    sysv64_pair_intint = 3,
    sysv64_pair_intsse = 4,
    sysv64_pair_sseint = 5,
    sysv64_pair_ssesse = 6,
    sysv64_no_class = 7,
    sysv64_memory = 8,
    win64_register = 9,
    win64_stack = 10,
    win64_register_ref = 11,
    win64_stack_ref = 12,
    aapcs64_general = 13,
    aapcs64_sse = 14,
    aapcs64_general_ref = 15,
    aapcs64_stack = 16,
    aapcs64_stack_ref = 17,
    aapcs64_none = 18,
};

/// A struct type, which also stores array types. The fields follow the
/// header as a flexible array member, so `@sizeOf` stands in for the
/// `offsetof` that would have measured where they start.
pub const Struct = extern struct {
    size: u32,
    alignment: u32,
    field_count: u32,
    is_aligned: u32,

    pub const header_size = std.mem.alignForward(usize, @sizeOf(Struct), @alignOf(StructMember));

    pub fn allocSize(field_count: usize) usize {
        return header_size + field_count * @sizeOf(StructMember);
    }

    pub fn fields(st: *Struct) [*]StructMember {
        const bytes: [*]u8 = @ptrCast(st);
        return @ptrCast(@alignCast(bytes + header_size));
    }
};

pub const StructMember = extern struct {
    type: Type,
    offset: usize,
};

pub const Type = extern struct {
    st: ?*Struct,
    prim: Prim,
    array_count: i32,

    /// `prim_type`: a scalar, with no struct behind it and no array around it.
    pub fn of(prim: Prim) Type {
        return .{ .st = null, .prim = prim, .array_count = -1 };
    }

    /// The same type with the array stripped, which is what an element is.
    pub fn element(t: Type) Type {
        var el = t;
        el.array_count = -1;
        return el;
    }
};

// ==========================================================================
// Public functions
// ==========================================================================

pub fn buildStruct(argv: []const repr.Value) raise.Error!*Struct {
    // `:pack` marks a single packed member and `:pack-all` packs the rest.
    var member_count = argv.len;
    var all_packed = false;
    {
        for (argv) |arg| {
            if (args_core.keyeq(arg, "pack")) {
                member_count -= 1;
            } else if (args_core.keyeq(arg, "pack-all")) {
                member_count -= 1;
                all_packed = true;
            }
        }
    }

    const st: *Struct = @ptrCast(@alignCast(abstracts.newBytes(
        &struct_at,
        Struct.allocSize(argv.len),
    )));
    st.field_count = 0;
    st.size = 0;
    st.alignment = 1;
    if (argv.len == 0) return raise.panic("invalid empty struct");

    var layout = Layout.init();
    const members = Struct.fields(st);
    var i: usize = 0;
    var j: usize = 0;
    while (j < argv.len) : (j += 1) {
        var pack_one: bool = false;
        if (args_core.keyeq(argv[j], "pack") or
            args_core.keyeq(argv[j], "pack-all"))
        {
            pack_one = true;
            j += 1;
            if (j == argv.len) break;
        }
        members[i].type = try decodeType(argv[j]);
        const el_size = typeSize(members[i].type);
        const el_align = typeAlign(members[i].type);
        // `el_align <= 0` in C, on a size_t, which is `el_align == 0`: the
        // void type is the only entry with no alignment.
        if (el_align == 0) return pp_format.panicf("bad field type %V", .{argv[j]});
        members[i].offset = layout.place(el_size, el_align, all_packed or pack_one);
        i += 1;
    }
    layout.finish();
    st.size = layout.size;
    st.alignment = layout.alignment;
    st.is_aligned = layout.is_aligned;
    st.field_count = @intCast(member_count);
    return st;
}

/// `ffi_cc_enabled`. Whether a build may call a convention is a separate
/// question from whether it can decode the name, and separating the two is
/// what lets `cc_names` below list every name on every target.
pub fn ccEnabled(cc: Cc) bool {
    return switch (cc) {
        .none => true,
        .win64 => win64_enabled,
        .sysv64 => sysv64_enabled,
        .aapcs64 => aapcs64_enabled,
    };
}

/// `decode_ffi_cc`. `:default` never reaches the table: it resolves to
/// whichever convention the build enables, which is a property of the target.
pub fn decodeCc(name: [*:0]const u8) raise.Error!Cc {
    if (0 == utils.cstrcmp(name, "default")) return default_cc;
    const cc = lookupCc(keywordBytes(name));
    if (cc < 0 or !ccEnabled(@enumFromInt(@as(u32, @intCast(cc))))) {
        return pp_format.panicf("unknown calling convention %s", .{name});
    }
    return @enumFromInt(@as(u32, @intCast(cc)));
}

/// `decode_ffi_prim`.
pub fn decodePrim(name: [*]const u8) raise.Error!Prim {
    const prim = lookupPrim(keywordBytes(name));
    if (prim < 0) return pp_format.panicf("unknown machine type %s", .{name});
    return @enumFromInt(@as(u32, @intCast(prim)));
}

/// `decode_ffi_type`.
pub fn decodeType(x: repr.Value) raise.Error!Type {
    if (repr.checkType(x, repr.Tag.keyword)) {
        return Type.of(try decodePrim(wrap.toKeyword(x)));
    }
    var ret: Type = .{ .st = null, .prim = .@"struct", .array_count = -1 };
    if (null != args_core.checkabstract(x, &struct_at)) {
        ret.st = @ptrCast(@alignCast(wrap.toAbstract(x)));
        return ret;
    }
    const els = args_core.indexedView(x) orelse {
        return pp_format.panicf("bad native type %v", .{x});
    };
    if (repr.checkType(x, repr.Tag.array)) {
        if (els.len != 2 and els.len != 1) {
            return pp_format.panicf("array type must be of form @[type count], got %v", .{x});
        }
        ret = try decodeType(els[0]);
        // A nested array type is refused rather than flattened. A `Type` has
        // one `array_count`, so assigning here would overwrite the inner
        // dimension and leave a type a quarter of the size the expression
        // names, and as a struct field that moves every later field's
        // offset. The working spelling is a struct of the inner
        // arrays, which the message names.
        if (ret.array_count >= 0) {
            return pp_format.panicf(
                "nested array type %v; use a struct of the inner arrays, as in @[[:u8 :u8 :u8 :u8] 3]",
                .{x},
            );
        }
        ret.array_count = if (els.len == 1) 0 else try args_core.getNat(els, 1);
    } else {
        ret.st = try buildStruct(els);
    }
    return ret;
}

/// Report the calling convention a keyword names, or -1 when it names none.
///
/// All four names decode on every target. Whether a convention is enabled is a
/// separate question and a property of the target; folding the two together is
/// what would leave the conventions a build does not enable with no coverage
/// at all.
pub fn lookupCc(name: []const u8) i32 {
    for (cc_names) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return @intFromEnum(entry[1]);
    }
    return -1;
}

pub fn lookupPrim(name: []const u8) i32 {
    for (prim_names) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return @intFromEnum(entry[1]);
    }
    return -1;
}

/// `type_align`.
pub fn typeAlign(t: Type) usize {
    if (t.prim == .@"struct") return t.st.?.alignment;
    return primInfo(t.prim).alignment;
}

pub fn typeExtent(base_size: usize, array_count: i32) usize {
    const count: usize = if (array_count < 0) 1 else @intCast(array_count);
    return base_size *% count;
}

/// `type_size`. The array count is multiplied in by the kernel, which is where
/// the "no array count" sentinel is decided.
pub fn typeSize(t: Type) usize {
    const base = if (t.prim == .@"struct") t.st.?.size else primInfo(t.prim).size;
    return typeExtent(base, t.array_count);
}

// ==========================================================================
// Private functions
// ==========================================================================

fn keywordBytes(name: [*]const u8) []const u8 {
    return name[0..strings.head(name).length];
}

fn primInfo(prim: Prim) PrimInfo {
    return switch (prim) {
        .void => .{ .size = 0, .alignment = 0 },
        .bool => .{ .size = @sizeOf(u8), .alignment = @alignOf(u8) },
        .ptr => .{ .size = @sizeOf(*anyopaque), .alignment = @alignOf(*anyopaque) },
        .string => .{ .size = @sizeOf([*]u8), .alignment = @alignOf([*]u8) },
        .float => .{ .size = @sizeOf(f32), .alignment = @alignOf(f32) },
        .double => .{ .size = @sizeOf(f64), .alignment = @alignOf(f64) },
        .int8 => .{ .size = @sizeOf(i8), .alignment = @alignOf(i8) },
        .uint8 => .{ .size = @sizeOf(u8), .alignment = @alignOf(u8) },
        .int16 => .{ .size = @sizeOf(i16), .alignment = @alignOf(i16) },
        .uint16 => .{ .size = @sizeOf(u16), .alignment = @alignOf(u16) },
        .int32 => .{ .size = @sizeOf(i32), .alignment = @alignOf(i32) },
        .uint32 => .{ .size = @sizeOf(u32), .alignment = @alignOf(u32) },
        .int64 => .{ .size = @sizeOf(i64), .alignment = @alignOf(i64) },
        .uint64 => .{ .size = @sizeOf(u64), .alignment = @alignOf(u64) },
        .@"struct" => .{ .size = 0, .alignment = @alignOf(u64) },
    };
}

fn signatureMark(sig: *Signature, _: usize) void {
    for (sig.args[0..sig.arg_count]) |arg| {
        const t = arg.type;
        if (t.prim == .@"struct") gc_mark.mark(wrap.fromAbstract(t.st));
    }
}

/// `struct_mark`. A nested struct type is an abstract of this same type.
fn structMark(st: *Struct, _: usize) void {
    const members = Struct.fields(st);
    for (members[0..st.field_count]) |member| {
        const t = member.type;
        if (t.prim == .@"struct") gc_mark.mark(wrap.fromAbstract(t.st));
    }
}

test "every machine type name decodes and unknown names are reported" {
    try std.testing.expectEqual(@as(i32, 0), lookupPrim("void"));
    try std.testing.expectEqual(@as(i32, 2), lookupPrim("pointer"));
    try std.testing.expectEqual(@as(i32, -1), lookupPrim("nonesuch"));
    try std.testing.expectEqual(@as(i32, -1), lookupPrim("voidx"));
    try std.testing.expectEqual(@as(i32, -1), lookupPrim("voi"));
}

test "every calling convention decodes regardless of target" {
    try std.testing.expectEqual(@as(i32, 1), lookupCc("sysv64"));
    try std.testing.expectEqual(@as(i32, 2), lookupCc("win64"));
    try std.testing.expectEqual(@as(i32, 3), lookupCc("aapcs64"));
    try std.testing.expectEqual(@as(i32, -1), lookupCc("default"));
}

test "layout pads to alignment and rounds the total" {
    var layout = Layout.init();
    try std.testing.expectEqual(@as(usize, 0), layout.place(1, 1, false));
    try std.testing.expectEqual(@as(usize, 8), layout.place(8, 8, false));
    layout.finish();
    try std.testing.expectEqual(@as(u32, 16), layout.size);
    try std.testing.expectEqual(@as(u32, 8), layout.alignment);
    try std.testing.expectEqual(@as(u32, 1), layout.is_aligned);
}

test "a packed field off its boundary clears the aligned flag" {
    var layout = Layout.init();
    try std.testing.expectEqual(@as(usize, 0), layout.place(1, 1, true));
    try std.testing.expectEqual(@as(usize, 1), layout.place(8, 8, true));
    layout.finish();
    try std.testing.expectEqual(@as(u32, 9), layout.size);
    try std.testing.expectEqual(@as(u32, 1), layout.alignment);
    try std.testing.expectEqual(@as(u32, 0), layout.is_aligned);
}

// ==========================================================================
// Tests
// ==========================================================================
