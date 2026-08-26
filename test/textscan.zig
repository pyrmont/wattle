//! Behavioral contract for the two text predicates in `util.h`:
//! `janet_valid_utf8` and `janet_is_symbol_char`.
//!
//! Both are reached from the parser rather than from Janet, and the inputs
//! that matter are exactly the ones no Janet program can hand them — a source
//! file holding an overlong encoding does not parse, so a suite cannot ask
//! whether the validator rejected it or the reader did.
//!
//! ## The permissive case is deliberate, and this is where it is written down
//!
//! `janet_valid_utf8` accepts `f7 bf bf bf`, which encodes U+1FFFFF and is
//! above Unicode's U+10FFFF ceiling. A strict validator refuses it. This one
//! checks the *shape* — a lead byte, the right number of continuations, and no
//! overlong form — and does not range-check the code point. That is Janet's
//! behaviour rather than an oversight, and the assertion below is here so that
//! a port cannot quietly tighten it.
//!
//! `util.h` was the one core header the shared translation deliberately left
//! out: its dynamic-library section falls through to `<dlfcn.h>` when
//! `JANET_WINDOWS` is undefined, which broke the Windows cross-compile for
//! every subsystem at once. Its rule outlived it -- a caller declares what it
//! needs directly, because these take primitives and no Janet type crosses.
//! Two declarations is what that costs here.

const std = @import("std");

extern fn janet_valid_utf8(string: [*]const u8, length: i32) callconv(.c) c_int;
extern fn janet_is_symbol_char(byte: u8) callconv(.c) c_int;

fn valid(bytes: []const u8) bool {
    return janet_valid_utf8(bytes.ptr, @intCast(bytes.len)) != 0;
}

fn symbolChar(byte: u8) bool {
    return janet_is_symbol_char(byte) != 0;
}

fn theWellFormedEncodings() void {
    std.debug.assert(valid("janet"));
    std.debug.assert(valid(&.{ 0xc2, 0xa2 })); // cent sign, two bytes
    std.debug.assert(valid(&.{ 0xe3, 0x81, 0x98 })); // hiragana ji, three
    std.debug.assert(valid(&.{ 0xf0, 0x9f, 0x90, 0x89 })); // dragon, four

    // Above U+10FFFF and accepted; see the header comment.
    std.debug.assert(valid(&.{ 0xf7, 0xbf, 0xbf, 0xbf }));
}

fn theMalformedEncodings() void {
    // Overlong: a code point encoded in more bytes than it needs, which is the
    // classic way past a validator that only counts continuations.
    std.debug.assert(!valid(&.{ 0xc0, 0x80 }));
    std.debug.assert(!valid(&.{ 0xe0, 0x80, 0x80 }));
    std.debug.assert(!valid(&.{ 0xf0, 0x80, 0x80, 0x80 }));

    // A three-byte lead with only one continuation.
    std.debug.assert(!valid(&.{ 0xe3, 0x81 }));
    // A continuation slot holding an ASCII byte.
    std.debug.assert(!valid(&.{ 0xe3, 0x41, 0x98 }));
    // Five bytes, which UTF-8 has not had since 2003.
    std.debug.assert(!valid(&.{ 0xf8, 0x88, 0x80, 0x80, 0x80 }));
}

fn theSymbolAlphabet() void {
    std.debug.assert(symbolChar('a'));
    std.debug.assert(symbolChar('Z'));
    std.debug.assert(symbolChar('0'));
    std.debug.assert(symbolChar('-'));
    // Every byte with the high bit set is a symbol character, which is how a
    // symbol may hold UTF-8 without the parser decoding it.
    std.debug.assert(symbolChar(0x80));

    std.debug.assert(!symbolChar(' '));
    std.debug.assert(!symbolChar(','));
    std.debug.assert(!symbolChar('('));
    std.debug.assert(!symbolChar(')'));
}

pub fn run() void {
    theWellFormedEncodings();
    theMalformedEncodings();
    theSymbolAlphabet();
}
