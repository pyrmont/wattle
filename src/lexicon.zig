//! The lexical tables of Wattle source: which bytes separate forms, which may
//! appear in a symbol, which letters name an escape, and which byte strings
//! are the UTF-8 a symbol or keyword may have.
//!
//! `build.zig` builds a module named `lexicon` from this file. The runtime's
//! parser and printer import it, and so does the line editor's classifier in
//! `client/lineedit/highlight.zig`, which may import nothing from the
//! runtime, so the two use the same tables. The grammar the tables serve, the
//! states the parser moves through, is described twice: once in
//! `runtime/parser.zig` and once in the classifier.

// ==========================================================================
// Constants
// ==========================================================================

/// The highest codepoint a `\U` escape may name.
pub const max_codepoint = 0x10ffff;

/// One bit per byte value, set where that byte may appear in a symbol.
/// `isSymbolChar` indexes it.
const symbol_characters = [8]u32{
    0x00000000, 0xf7ffec72, 0xc7ffffff, 0x07fffffe,
    0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff,
};

// ==========================================================================
// Types
// ==========================================================================

/// What the letter after a backslash in a string names.
///
/// `escape` returns an `Escape`. `byte` is the byte a simple escape stands
/// for, and `digits` is the number of hex digits that follow an `x`, `u` or
/// `U`.
pub const Escape = union(enum) {
    byte: u8,
    digits: u8,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Returns what the escape `letter` names, or null where `letter` names no
/// escape.
pub fn escape(letter: u8) ?Escape {
    return switch (letter) {
        'x' => .{ .digits = 2 },
        'u' => .{ .digits = 4 },
        'U' => .{ .digits = 6 },
        'n' => .{ .byte = '\n' },
        't' => .{ .byte = '\t' },
        'r' => .{ .byte = '\r' },
        '0', 'z' => .{ .byte = 0 },
        'f' => .{ .byte = 12 },
        'v' => .{ .byte = 11 },
        'a' => .{ .byte = 7 },
        'b' => .{ .byte = 8 },
        '\'' => .{ .byte = '\'' },
        '?' => .{ .byte = '?' },
        'e' => .{ .byte = 27 },
        '"' => .{ .byte = '"' },
        '\\' => .{ .byte = '\\' },
        else => null,
    };
}

/// Returns the value of the hex digit `character`, or null where it is not a
/// hex digit.
pub fn hexDigit(character: u8) ?u4 {
    return switch (character) {
        '0'...'9' => @intCast(character - '0'),
        'A'...'F' => @intCast(10 + character - 'A'),
        'a'...'f' => @intCast(10 + character - 'a'),
        else => null,
    };
}

/// Whether `character` may appear in a symbol.
pub fn isSymbolChar(character: u8) bool {
    return symbol_characters[character >> 5] & (@as(u32, 1) << @intCast(character & 0x1f)) != 0;
}

/// Whether `character` separates forms: space, tab, newline, carriage return,
/// NUL, vertical tab, form feed and the comma.
pub fn isWhitespace(character: u8) bool {
    return switch (character) {
        ' ', '\t', '\n', '\r', 0, 11, 12, ',' => true,
        else => false,
    };
}

/// Whether `string` is well-formed UTF-8, rejecting an overlong encoding as
/// well as a malformed one.
///
/// A codepoint above U+10FFFF of the right shape is accepted: a lead byte, the
/// right number of continuations and no overlong form.
pub fn validUtf8(string: []const u8) bool {
    const bytes = string;
    var index: usize = 0;
    while (index < bytes.len) {
        const first = bytes[index];
        const width: usize = if (first < 0x80)
            1
        else if (first >> 5 == 0x06)
            2
        else if (first >> 4 == 0x0e)
            3
        else if (first >> 3 == 0x1e)
            4
        else
            return false;

        const next = index + width;
        if (next > bytes.len) return false;
        for (bytes[index + 1 .. next]) |continuation| {
            if (continuation >> 6 != 2) return false;
        }
        if (width == 2 and first < 0xc2) return false;
        if (first == 0xe0 and bytes[index + 1] < 0xa0) return false;
        if (first == 0xf0 and bytes[index + 1] < 0x90) return false;
        index = next;
    }
    return true;
}
