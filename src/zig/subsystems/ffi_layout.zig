//! Portable kernels of the FFI type system: the machine-type and
//! calling-convention name tables, and the struct layout machine that assigns
//! every field its offset.
//!
//! This was the first increment inside `ffi.c`, and it deliberately takes none
//! of the calling machinery — no register classification, no argument
//! marshalling, no trampolines. What is here is arithmetic over sizes,
//! alignments, and bytes. It holds no Janet value, allocates nothing, and
//! cannot fail: an unknown name is *reported* rather than raised, because the
//! panic that names the offending Janet value belongs to `ffi_types.zig`,
//! which has the value.
//!
//! Neither `Type` nor `Struct` crosses into this file. They carry a pointer
//! into a garbage-collected abstract, and keeping the layout machine away from
//! that pointer keeps it a decision about scalars; `ffi_types.zig` dispatches
//! on the type and passes the scalars that result.
//!
//! ## Reached by import, not by symbol
//!
//! Until Phase 11 Part 16 every function here was an `export fn` that
//! `ffi_types.zig` called through a hand-written `extern fn` declaration — the
//! shape the C `ffi.c` needed, kept after both ends had become Zig. Nothing
//! checked the declaration against the definition, and `Layout` was written
//! out twice, once at each end of a symbol nothing but Zig ever called. The
//! contract in `test/ffi_layout.zig` is what removed the last reason for the
//! symbols to exist: it is compiled into the runtime and reaches these by
//! import as well, so the six exports and the second copy of `Layout` are
//! gone.
//!
//! The primitive and calling-convention ordinals below mirror the enumerations
//! `ffi.c` kept file-local. `test/ffi_layout.zig` pins them, by writing the
//! numbers out rather than by importing these declarations.

const std = @import("std");
const abi = @import("abi");

/// `JanetFFIPrimType` in `src/core/ffi.c`.
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

/// `JanetFFICallingConvention` in `src/core/ffi.c`.
const CallingConvention = enum(i32) {
    none = 0,
    sysv64 = 1,
    win64 = 2,
    aapcs64 = 3,
};

/// `JANET_64` in `src/include/janet.h`, which selects the width of the `size`
/// and `ssize` machine types. It is read from the header rather than inferred
/// from the target so that the two cannot disagree.
const is_64_bit = @hasDecl(abi.c, "JANET_64");

const NamedPrim = struct { []const u8, PrimType };

/// Every machine-type name `ffi.c` accepts, in its order: the primary names,
/// the word-size-dependent pair, then the aliases. `struct` has no name of its
/// own — a struct type is written as a tuple rather than a keyword.
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

const NamedCc = struct { []const u8, CallingConvention };

/// The calling conventions that have a name of their own. `default` is not
/// here: it resolves to whichever convention the build enables, which is a
/// property of the target rather than of the name, so `ffi_types.zig` maps it.
const cc_names = [_]NamedCc{
    .{ "none", .none },
    .{ "sysv64", .sysv64 },
    .{ "win64", .win64 },
    .{ "aapcs64", .aapcs64 },
};

// ---------------------------------------------------------------------------
// Name decoding
// ---------------------------------------------------------------------------

/// Report the machine type a keyword names, or -1 when it names none.
///
/// The keyword arrives as bytes rather than as a C string because a Janet
/// keyword is length-prefixed and may contain a zero byte; that is also what
/// `janet_cstrcmp` compared, so equality here means exactly what equality meant
/// before.
///
/// Every name is decoded on every target, including the two whose meaning
/// depends on the word size. The ordinal is answered rather than a `PrimType`,
/// because the caller's own enumeration is the one the rest of the FFI speaks
/// and mapping into it is `ffi_types.zig`'s business — an unknown name is a
/// Janet error there, and it has the value to name.
pub fn decodePrim(name: []const u8) i32 {
    for (prim_names) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return @intFromEnum(entry[1]);
    }
    return -1;
}

/// Report the calling convention a keyword names, or -1 when it names none.
///
/// Unlike the C original, this decodes all four names everywhere. Whether a
/// convention is *enabled* is a property of the target, and `ffi_types.zig`
/// still decides that; folding the two questions together is what left the
/// conventions a build does not enable with no coverage at all.
pub fn decodeCc(name: []const u8) i32 {
    for (cc_names) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return @intFromEnum(entry[1]);
    }
    return -1;
}

// ---------------------------------------------------------------------------
// Type extent
// ---------------------------------------------------------------------------

/// The number of bytes an array of `array_count` elements of `base_size`
/// occupies, where a negative count means the type is not an array.
///
/// The multiplication wraps explicitly. A count comes from `janet_getnat` and a
/// base size from a completed layout, so Janet's own limits keep the product
/// well inside the range; but C leaves an overflow of `size_t` defined and Zig
/// would trap, so the port commits to the C result.
pub fn typeExtent(base_size: usize, array_count: i32) usize {
    const count: usize = if (array_count < 0) 1 else @intCast(array_count);
    return base_size *% count;
}

// ---------------------------------------------------------------------------
// Struct layout
// ---------------------------------------------------------------------------

/// The running state of a struct layout: the bytes placed so far, the strictest
/// alignment any field has demanded, and whether every field has so far landed
/// on its natural boundary.
///
/// `ffi_types.zig` holds the `Struct` this ends up in, and every field offset
/// reported here is written there. The three counters are `u32` because that is
/// what a `Struct` stores them in, and the arithmetic truncates to that width
/// exactly where the C implementation's casts did.
pub const Layout = extern struct {
    size: u32,
    alignment: u32,
    is_aligned: u32,

    /// `janet_ffi_layout_init`.
    pub fn init() Layout {
        return .{ .size = 0, .alignment = 1, .is_aligned = 1 };
    }

    /// Place one field and report the offset it takes.
    ///
    /// `el_align` must not be zero; `ffi_types.zig` rejects a zero-aligned
    /// field with a panic immediately before calling, because that panic names
    /// the offending Janet value.
    ///
    /// A packed field is laid down where the cursor stands and contributes
    /// nothing to the struct's alignment, but a packed field that happens to
    /// land off its natural boundary clears `is_aligned` — that flag records
    /// whether the layout could have been produced without packing, which is
    /// what the callback path later relies on.
    ///
    /// `packed_field` is a `bool` rather than the C original's `int`. The one
    /// caller builds it from two keyword tests, and the flag deciding padding
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

test "every machine type name decodes and unknown names are reported" {
    try std.testing.expectEqual(@as(i32, 0), decodePrim("void"));
    try std.testing.expectEqual(@as(i32, 2), decodePrim("pointer"));
    try std.testing.expectEqual(@as(i32, -1), decodePrim("nonesuch"));
    try std.testing.expectEqual(@as(i32, -1), decodePrim("voidx"));
    try std.testing.expectEqual(@as(i32, -1), decodePrim("voi"));
}

test "every calling convention decodes regardless of target" {
    try std.testing.expectEqual(@as(i32, 1), decodeCc("sysv64"));
    try std.testing.expectEqual(@as(i32, 2), decodeCc("win64"));
    try std.testing.expectEqual(@as(i32, 3), decodeCc("aapcs64"));
    try std.testing.expectEqual(@as(i32, -1), decodeCc("default"));
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
