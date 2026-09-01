//! Behavioral contract for the two text predicates the parser reaches:
//! `validUtf8` and `isSymbolChar`.
//!
//! Both are reached from the parser rather than from Janet, and the inputs
//! that matter are exactly the ones no Janet program can hand them — a source
//! file holding an overlong encoding does not parse, so a suite cannot ask
//! whether the validator rejected it or the reader did.
//!
//! ## The permissive case is deliberate, and this is where it is written down
//!
//! `validUtf8` accepts `f7 bf bf bf`, which encodes U+1FFFFF and is
//! above Unicode's U+10FFFF ceiling. A strict validator refuses it. This one
//! checks the *shape* — a lead byte, the right number of continuations, and no
//! overlong form — and does not range-check the code point. That is Janet's
//! behaviour rather than an oversight, and the assertion below is here so that
//! a port cannot quietly tighten it.
//!
//! Both take primitives and neither is reachable from Janet source, so this
//! file is the only thing that asks either of them anything.

const scan = @import("subsystems").scan;
const expect = @import("expect.zig").expect;

fn valid(bytes: []const u8) bool {
    return scan.validUtf8(bytes);
}

fn symbolChar(byte: u8) bool {
    return scan.isSymbolChar(byte);
}

fn theWellFormedEncodings() void {
    expect(valid("janet"));
    expect(valid(&.{ 0xc2, 0xa2 })); // cent sign, two bytes
    expect(valid(&.{ 0xe3, 0x81, 0x98 })); // hiragana ji, three
    expect(valid(&.{ 0xf0, 0x9f, 0x90, 0x89 })); // dragon, four

    // Above U+10FFFF and accepted; see the header comment.
    expect(valid(&.{ 0xf7, 0xbf, 0xbf, 0xbf }));
}

fn theMalformedEncodings() void {
    // Overlong: a code point encoded in more bytes than it needs, which is the
    // classic way past a validator that only counts continuations.
    expect(!valid(&.{ 0xc0, 0x80 }));
    expect(!valid(&.{ 0xe0, 0x80, 0x80 }));
    expect(!valid(&.{ 0xf0, 0x80, 0x80, 0x80 }));

    // A three-byte lead with only one continuation.
    expect(!valid(&.{ 0xe3, 0x81 }));
    // A continuation slot holding an ASCII byte.
    expect(!valid(&.{ 0xe3, 0x41, 0x98 }));
    // Five bytes, which UTF-8 has not had since 2003.
    expect(!valid(&.{ 0xf8, 0x88, 0x80, 0x80, 0x80 }));
}

fn theSymbolAlphabet() void {
    expect(symbolChar('a'));
    expect(symbolChar('Z'));
    expect(symbolChar('0'));
    expect(symbolChar('-'));
    // Every byte with the high bit set is a symbol character, which is how a
    // symbol may hold UTF-8 without the parser decoding it.
    expect(symbolChar(0x80));

    expect(!symbolChar(' '));
    expect(!symbolChar(','));
    expect(!symbolChar('('));
    expect(!symbolChar(')'));
}

pub fn run() void {
    theWellFormedEncodings();
    theMalformedEncodings();
    theSymbolAlphabet();
}
