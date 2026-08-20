//! `ffi.c`'s type system: the machine-type representation, the two abstract
//! types the collector walks, the size and alignment dispatchers, and the
//! decoder that turns a Janet value into a type. This is the base of Phase 10
//! Part 16 and nothing here calls anything.
//!
//! ## What crosses, now that nothing has to
//!
//! `-Dffi-layout` and `-Dffi-classify` were written under a rule that has just
//! expired: `JanetFFIType` carries a pointer into a garbage-collected
//! abstract, so keeping Zig away from that pointer kept the collector's roots
//! a purely C concern. C dispatched on the type and passed the scalars that
//! resulted. The roots are Zig's now -- this file defines the abstract types
//! and their mark callbacks -- so the pointer stays inside one language again
//! and the dispatchers are three lines here instead of three lines there.
//!
//! What does *not* change is the seam with those two selectors. Their kernels
//! are reached across the C ABI exactly as `ffi.c` reached them, so
//! `-Dffi-layout=c` still runs a C struct-layout machine under a Zig type
//! system, and the flat `TypeNode` form still exists for the classifiers'
//! sake.
//!
//! ## Why this file is jump-transparent
//!
//! The argument layer is behind `-Dargs-core`, so `janet_getnat`,
//! `janet_getindexed` and their kin raise by `longjmp` through these frames
//! until Part 17. No `defer` may appear here until then.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");

pub const c = abi.c;
const arglayer = @import("arglayer.zig");
const abstract_type = @import("abstract_type.zig");

/// How deep a type may nest before `ffi/read` and `ffi/write` give up.
pub const max_recur: c_int = 64;

/// The most arguments a signature may hold. `ffi.c`'s `JANET_FFI_MAX_ARGS`,
/// and the bound its own `cfun_ffi_signature` fails to check -- see `FOUND.md`.
pub const max_args: u32 = 32;

// ==========================================================================
// The enumerations, whose ordinals `ffi.c` pins
// ==========================================================================

/// `JanetFFIPrimType`. The ordinals are mirrored rather than imported --
/// the enumeration is file-local to `ffi.c`, which still holds the
/// compile-time assertion that pins the two together for the sake of the
/// `-Dffi-layout` and `-Dffi-classify` fallbacks.
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

/// `JanetFFICallingConvention`.
pub const Cc = enum(u32) {
    none = 0,
    sysv64 = 1,
    win64 = 2,
    aapcs64 = 3,
};

/// `JanetFFIWordSpec`: the class a classifier reached, and afterwards the
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

// ==========================================================================
// Which conventions this target may call
// ==========================================================================

/// The three `JANET_FFI_*_ENABLED` chains, which are host facts and were three
/// `#if`s over the compiler's predefines.
///
/// Read from `builtin` rather than through `@cImport`, on Part 12's rule: a
/// `JANET_*` macro derived from the compiler's own predefines is not reliable
/// through a translation, because Aro predefines `__unix__` for
/// `x86_64-windows-gnu` and `janet.h` tests its Unix chain first. `builtin` is
/// the build's own answer and cannot disagree with itself.
pub const windows = builtin.os.tag == .windows;
pub const win64_enabled = windows and builtin.cpu.arch == .x86_64;
pub const sysv64_enabled = !windows and builtin.cpu.arch == .x86_64;
pub const aapcs64_enabled = !windows and builtin.cpu.arch == .aarch64;

/// `JANET_FFI_CC_DEFAULT`: what `:default` resolves to, which is a property of
/// the target rather than of the name.
pub const default_cc: Cc = if (win64_enabled)
    .win64
else if (sysv64_enabled)
    .sysv64
else if (aapcs64_enabled)
    .aapcs64
else
    .none;

/// `ffi_cc_enabled`. Whether a build may *call* a convention is a separate
/// question from whether it can decode the name, and separating the two is
/// what let `-Dffi-layout` put every name in one table compiled everywhere.
pub fn ccEnabled(cc: Cc) bool {
    return switch (cc) {
        .none => true,
        .win64 => win64_enabled,
        .sysv64 => sysv64_enabled,
        .aapcs64 => aapcs64_enabled,
    };
}

// ==========================================================================
// The type representation
// ==========================================================================

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

pub const StructMember = extern struct {
    type: Type,
    offset: usize,
};

/// `JanetFFIStruct`, which also stores array types. The fields follow the
/// header as a flexible array member; Phase 8's fourth rule makes `@sizeOf`
/// stand in for the `offsetof` that would have measured where they start.
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

/// `JanetFFIMapping`: one argument as a convention sees it.
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
            // `void_mapping` leaves this uninitialized in C and every caller
            // overwrites the whole mapping before reading it. Zeroing it is a
            // divergence only in what an unread field holds.
            .offset2 = 0,
        };
    }
};

/// `JanetFFISignature`.
///
/// `arg_stack_words` is where C had `word_count`, a field `cfun_ffi_signature`
/// never wrote and nothing ever read. Part 16 needs the outgoing half of the
/// frame measured in words -- the rung a call selects -- and this is the slot
/// it goes in. Nothing outside these files sees this structure: it was
/// file-local to `ffi.c` and `ffi.c` no longer declares it.
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

// ==========================================================================
// The host's own sizes, which are facts rather than rules
// ==========================================================================

/// `janet_ffi_type_info`. Built from the host's `sizeof` and `alignof`, which
/// is why it never moved behind `-Dffi-layout`: the kernels there receive it as
/// the `el_size` and `el_align` arguments.
///
/// `ALIGNOF(type)` in C is `offsetof(struct { char c; type member; }, member)`,
/// which is what `@alignOf` answers for every type in this table.
const PrimInfo = struct { size: usize, alignment: usize };

fn primInfo(prim: Prim) PrimInfo {
    return switch (prim) {
        .void => .{ .size = 0, .alignment = 0 },
        .bool => .{ .size = @sizeOf(u8), .alignment = @alignOf(u8) },
        .ptr => .{ .size = @sizeOf(*anyopaque), .alignment = @alignOf(*anyopaque) },
        .string => .{ .size = @sizeOf([*c]u8), .alignment = @alignOf([*c]u8) },
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

// ==========================================================================
// The kernels behind `-Dffi-layout`
// ==========================================================================

extern fn janet_ffi_decode_prim(name: [*c]const u8, len: i32) callconv(.c) i32;
extern fn janet_ffi_decode_cc(name: [*c]const u8, len: i32) callconv(.c) i32;
extern fn janet_ffi_type_extent(base_size: usize, array_count: i32) callconv(.c) usize;

/// `type_size`. The array count is multiplied in by the kernel, which is where
/// the "no array count" sentinel is decided.
pub fn typeSize(t: Type) usize {
    const base = if (t.prim == .@"struct") t.st.?.size else primInfo(t.prim).size;
    return janet_ffi_type_extent(base, t.array_count);
}

/// `type_align`.
pub fn typeAlign(t: Type) usize {
    if (t.prim == .@"struct") return t.st.?.alignment;
    return primInfo(t.prim).alignment;
}

/// `decode_ffi_cc`. `:default` never reaches the table: it resolves to
/// whichever convention the build enables, which is a property of the target.
pub fn decodeCc(name: [*c]const u8) raise.Raising(Cc) {
    if (0 == c.janet_cstrcmp(name, "default")) return default_cc;
    const cc = janet_ffi_decode_cc(name, c.janet_string_length(name));
    if (cc < 0 or !ccEnabled(@enumFromInt(@as(u32, @intCast(cc))))) {
        return pp_format.panicf("unknown calling convention %s", .{name});
    }
    return @enumFromInt(@as(u32, @intCast(cc)));
}

/// `decode_ffi_prim`.
pub fn decodePrim(name: [*c]const u8) raise.Raising(Prim) {
    const prim = janet_ffi_decode_prim(name, c.janet_string_length(name));
    if (prim < 0) return pp_format.panicf("unknown machine type %s", .{name});
    return @enumFromInt(@as(u32, @intCast(prim)));
}

const Layout = extern struct {
    size: u32,
    alignment: u32,
    is_aligned: u32,
};

extern fn janet_ffi_layout_init(layout: *Layout) callconv(.c) void;
extern fn janet_ffi_layout_place(layout: *Layout, el_size: usize, el_align: usize, packed_field: c_int) callconv(.c) usize;
extern fn janet_ffi_layout_finish(layout: *Layout) callconv(.c) void;

// ==========================================================================
// The abstract types
// ==========================================================================

/// `signature_mark`. Every argument that is a struct holds an abstract the
/// collector has to reach.
fn signatureMark(p: ?*anyopaque, s: usize) callconv(.c) c_int {
    _ = s;
    const sig: *Signature = @ptrCast(@alignCast(p));
    var i: u32 = 0;
    while (i < sig.arg_count) : (i += 1) {
        const t = sig.args[i].type;
        if (t.prim == .@"struct") c.janet_mark(c.janet_wrap_abstract(t.st));
    }
    return 0;
}

/// `struct_mark`. A nested struct type is an abstract of this same type.
fn structMark(p: ?*anyopaque, s: usize) callconv(.c) c_int {
    _ = s;
    const st: *Struct = @ptrCast(@alignCast(p));
    const members = Struct.fields(st);
    var i: u32 = 0;
    while (i < st.field_count) : (i += 1) {
        const t = members[i].type;
        if (t.prim == .@"struct") c.janet_mark(c.janet_wrap_abstract(t.st));
    }
    return 0;
}

/// `janet_signature_type`. `JANET_ATEND_GCMARK` leaves every field after
/// `gcmark` null, which the translated structure already defaults them to.
pub const signature_at: abstract_type.AbstractType = .{
    .name = "core/ffi-signature",
    .gc = null,
    .gcmark = &signatureMark,
};

/// `janet_struct_type`.
pub const struct_at: abstract_type.AbstractType = .{
    .name = "core/ffi-struct",
    .gc = null,
    .gcmark = &structMark,
};

// ==========================================================================
// Decoding a type out of a Janet value
// ==========================================================================

/// `build_struct_type`.
///
/// The layout runs beside the struct rather than inside it: `field_count` stays
/// zero until the end so a collection triggered by a nested type does not scan
/// a field that has not been filled in yet, and the totals are copied over once
/// the last field has been placed.
pub fn buildStruct(argc: i32, argv: [*c]const c.Janet) raise.Raising(*Struct) {
    // `:pack` marks a single packed member and `:pack-all` packs the rest.
    var member_count = argc;
    var all_packed = false;
    {
        var i: i32 = 0;
        while (i < argc) : (i += 1) {
            if (0 != c.janet_keyeq(argv[@intCast(i)], "pack")) {
                member_count -= 1;
            } else if (0 != c.janet_keyeq(argv[@intCast(i)], "pack-all")) {
                member_count -= 1;
                all_packed = true;
            }
        }
    }

    const st: *Struct = @ptrCast(@alignCast(c.janet_abstract(
        abstract_type.stored(&struct_at),
        Struct.allocSize(@intCast(argc)),
    )));
    st.field_count = 0;
    st.size = 0;
    st.alignment = 1;
    if (argc == 0) return raise.panic("invalid empty struct");

    var layout: Layout = undefined;
    janet_ffi_layout_init(&layout);
    const members = Struct.fields(st);
    var i: usize = 0;
    var j: i32 = 0;
    while (j < argc) : (j += 1) {
        var pack_one: bool = false;
        if (0 != c.janet_keyeq(argv[@intCast(j)], "pack") or
            0 != c.janet_keyeq(argv[@intCast(j)], "pack-all"))
        {
            pack_one = true;
            j += 1;
            if (j == argc) break;
        }
        members[i].type = try decodeType(argv[@intCast(j)]);
        const el_size = typeSize(members[i].type);
        const el_align = typeAlign(members[i].type);
        // `el_align <= 0` in C, on a size_t, which is `el_align == 0` -- the
        // void type is the only entry with no alignment.
        if (el_align == 0) return pp_format.panicf("bad field type %V", .{argv[@intCast(j)]});
        members[i].offset = janet_ffi_layout_place(
            &layout,
            el_size,
            el_align,
            @intFromBool(all_packed or pack_one),
        );
        i += 1;
    }
    janet_ffi_layout_finish(&layout);
    st.size = layout.size;
    st.alignment = layout.alignment;
    st.is_aligned = layout.is_aligned;
    st.field_count = @intCast(member_count);
    return st;
}

/// `decode_ffi_type`.
pub fn decodeType(x: c.Janet) raise.Raising(Type) {
    if (0 != c.janet_checktype(x, c.JANET_KEYWORD)) {
        return Type.of(try decodePrim(c.janet_unwrap_keyword(x)));
    }
    var ret: Type = .{ .st = null, .prim = .@"struct", .array_count = -1 };
    if (null != c.janet_checkabstract(x, abstract_type.stored(&struct_at))) {
        ret.st = @ptrCast(@alignCast(c.janet_unwrap_abstract(x)));
        return ret;
    }
    var len: i32 = undefined;
    var els: [*c]const c.Janet = undefined;
    if (0 == c.janet_indexed_view(x, &els, &len)) {
        return pp_format.panicf("bad native type %v", .{x});
    }
    if (0 != c.janet_checktype(x, c.JANET_ARRAY)) {
        if (len != 2 and len != 1) {
            return pp_format.panicf("array type must be of form @[type count], got %v", .{x});
        }
        ret = try decodeType(els[0]);
        ret.array_count = if (len == 1) 0 else try arglayer.getNat(els, 1);
    } else {
        ret.st = try buildStruct(len, els);
    }
    return ret;
}
