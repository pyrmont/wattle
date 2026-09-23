//! The key decoder: the bytes a terminal sends, turned into the keys the
//! editor acts on.
//!
//! `session.zig` passes each byte it is given to a `Decoder`, and applies the
//! `Key` that `feed` returns with `editor.zig`. A _sequence_ is an escape
//! sequence: `ESC [` followed by parameter bytes and one final byte (a
//! _CSI_), or `ESC O` followed by one final byte (an _SS3_).
//!
//! ## What a byte becomes
//!
//! - A sequence is consumed whole, whether or not it names a key. A sequence
//!   that names no key the editor has becomes `.ignored`, so no byte of it is
//!   inserted.
//!
//! - A byte that is not valid inside a CSI ends the sequence, and the byte is
//!   decoded on its own. A terminal does not send such a byte, and decoding
//!   it keeps a stray `ESC [` from swallowing a keystroke such as Enter.
//!
//! - `ESC` followed by a byte that begins no sequence is `.ignored`, both
//!   bytes together. A terminal sends this for a key pressed with Alt.
//!
//! - A UTF-8 sequence is collected until it is complete and inserted as one
//!   key, so a rune split across two reads is inserted once. A lead byte
//!   whose sequence is broken by a byte that does not continue it is dropped,
//!   and that byte is decoded on its own. A byte that begins no valid
//!   sequence is inserted on its own, and `rune.zig` gives it width 1.
//!
//! - Enter arrives as CR and Ctrl-J as LF, because raw mode clears `ICRNL`.
//!   They are separate keys.
//!
//! - A bracketed paste arrives between `ESC [ 200 ~` and `ESC [ 201 ~`, which
//!   are the keys `paste_start` and `paste_end`. The bytes between them are
//!   decoded as they would be if typed.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Constants
// ==========================================================================

/// The escape byte, which begins every sequence.
const escape: u8 = 0x1b;

/// The most parameter and intermediate bytes a CSI keeps. A longer sequence
/// is still consumed to its final byte, and the bytes past this length are
/// not kept.
const max_parameters = 16;

// ==========================================================================
// Types
// ==========================================================================

/// One key, as the editor acts on it.
///
/// `Decoder.feed` returns a `Key` and `editor.Editor.apply` takes one.
/// `insert` has the bytes of one rune, or of one byte that begins no valid
/// UTF-8 sequence. `interrupt` is Ctrl-C and `eof` is Ctrl-D.
/// `paste_start` and `paste_end` are the markers around a bracketed paste.
pub const Key = union(enum) {
    insert: Rune,
    left,
    right,
    up,
    down,
    home,
    end,
    backspace,
    delete,
    kill_end,
    kill_start,
    enter,
    newline,
    eof,
    interrupt,
    paste_start,
    paste_end,
    ignored,
};

/// The bytes of one rune, at most four.
///
/// `Key.insert` has a `Rune`, and `slice` returns its bytes.
pub const Rune = struct {
    bytes: [4]u8 = .{ 0, 0, 0, 0 },
    len: u3 = 0,

    /// Returns the rune's bytes.
    ///
    /// The result points into `rune` and is valid while `rune` is.
    pub fn slice(rune: *const Rune) []const u8 {
        return rune.bytes[0..rune.len];
    }
};

/// The decoder's state between two bytes.
///
/// `init` returns a `Decoder` and `feed` takes one. `state` is which kind of
/// input the next byte continues. `parameters` has the CSI bytes collected so
/// far and `count` is how many there were, which may exceed the length kept.
/// `rune` has the UTF-8 bytes collected so far, and `expected` is the length
/// of the sequence they begin.
pub const Decoder = struct {
    state: State = .ground,
    parameters: [max_parameters]u8 = undefined,
    count: usize = 0,
    rune: Rune = .{},
    expected: u3 = 0,

    /// Returns a decoder with nothing collected.
    pub fn init() Decoder {
        return .{};
    }

    /// Decodes one byte, and returns the key it completes.
    ///
    /// `byte` is the next byte the terminal sent. The result is null while a
    /// sequence or a rune is incomplete. This function cannot fail.
    pub fn feed(decoder: *Decoder, byte: u8) ?Key {
        switch (decoder.state) {
            .ground => return decoder.ground(byte),
            .escape => {
                decoder.state = .ground;
                switch (byte) {
                    '[' => {
                        decoder.state = .csi;
                        decoder.count = 0;
                        return null;
                    },
                    'O' => {
                        decoder.state = .ss3;
                        return null;
                    },
                    else => return .ignored,
                }
            },
            .ss3 => {
                decoder.state = .ground;
                return final(byte, &.{});
            },
            .csi => {
                if (byte >= 0x40 and byte <= 0x7e) {
                    decoder.state = .ground;
                    const kept = @min(decoder.count, max_parameters);
                    return final(byte, decoder.parameters[0..kept]);
                }
                if (byte >= 0x20 and byte <= 0x3f) {
                    if (decoder.count < max_parameters) decoder.parameters[decoder.count] = byte;
                    decoder.count += 1;
                    return null;
                }
                // Not a CSI byte: the sequence ends here and the byte is
                // decoded on its own.
                decoder.state = .ground;
                return decoder.replay(byte);
            },
            .utf8 => {
                if (byte & 0xc0 != 0x80) {
                    // The sequence is broken. Its bytes are dropped and this
                    // byte begins again.
                    decoder.state = .ground;
                    return decoder.ground(byte);
                }
                decoder.rune.bytes[decoder.rune.len] = byte;
                decoder.rune.len += 1;
                if (decoder.rune.len < decoder.expected) return null;
                decoder.state = .ground;
                return .{ .insert = decoder.rune };
            },
        }
    }

    /// Decodes a byte that follows no incomplete sequence.
    ///
    /// `feed` calls this from the ground state and after a broken rune.
    fn ground(decoder: *Decoder, byte: u8) ?Key {
        switch (byte) {
            escape => {
                decoder.state = .escape;
                return null;
            },
            0x01 => return .home,
            0x02 => return .left,
            0x03 => return .interrupt,
            0x04 => return .eof,
            0x05 => return .end,
            0x06 => return .right,
            0x08, 0x7f => return .backspace,
            '\t' => return .{ .insert = single(byte) },
            '\n' => return .newline,
            0x0b => return .kill_end,
            '\r' => return .enter,
            0x0e => return .down,
            0x10 => return .up,
            0x15 => return .kill_start,
            0x00, 0x07, 0x0c, 0x0f, 0x11...0x14, 0x16...0x1a, 0x1c...0x1f => return .ignored,
            else => {},
        }
        const len = std.unicode.utf8ByteSequenceLength(byte) catch return .{ .insert = single(byte) };
        if (len == 1) return .{ .insert = single(byte) };
        decoder.state = .utf8;
        decoder.rune = single(byte);
        decoder.expected = len;
        return null;
    }

    /// Returns `.ignored` for a CSI that a byte outside the CSI range ended,
    /// and decodes that byte too where it completes a key on its own.
    ///
    /// Only one key can be returned, so a byte that would begin a sequence
    /// or a rune is decoded and its key, which is always null, is dropped. A
    /// byte that is a whole key is returned as that key, because the ended
    /// CSI inserted nothing.
    fn replay(decoder: *Decoder, byte: u8) ?Key {
        return decoder.ground(byte) orelse .ignored;
    }
};

/// Which kind of input the next byte continues.
const State = enum { ground, escape, csi, ss3, utf8 };

// ==========================================================================
// Private functions
// ==========================================================================

/// Returns the key a sequence names.
///
/// `byte` is the final byte and `parameters` the bytes between `ESC [` and
/// it, empty for an SS3. The result is `.ignored` for a sequence that names
/// no key the editor has, including a cursor key with a modifier.
fn final(byte: u8, parameters: []const u8) Key {
    // A parameter other than 1 on a cursor key is a modifier, such as Ctrl
    // or Shift, and the editor has no modified cursor keys.
    const plain = parameters.len == 0 or std.mem.eql(u8, parameters, "1");
    if (!plain and byte != '~') return .ignored;
    switch (byte) {
        'A' => return .up,
        'B' => return .down,
        'C' => return .right,
        'D' => return .left,
        'F' => return .end,
        'H' => return .home,
        '~' => {
            if (std.mem.eql(u8, parameters, "1") or std.mem.eql(u8, parameters, "7")) return .home;
            if (std.mem.eql(u8, parameters, "4") or std.mem.eql(u8, parameters, "8")) return .end;
            if (std.mem.eql(u8, parameters, "3")) return .delete;
            if (std.mem.eql(u8, parameters, "200")) return .paste_start;
            if (std.mem.eql(u8, parameters, "201")) return .paste_end;
            return .ignored;
        },
        else => return .ignored,
    }
}

/// Returns a rune of one byte.
fn single(byte: u8) Rune {
    return .{ .bytes = .{ byte, 0, 0, 0 }, .len = 1 };
}

// ==========================================================================
// Tests
// ==========================================================================

/// Feeds `bytes` to a fresh decoder and returns every key it completes.
fn decodeAll(bytes: []const u8, out: []Key) []Key {
    var decoder = Decoder.init();
    var n: usize = 0;
    for (bytes) |byte| {
        if (decoder.feed(byte)) |key| {
            out[n] = key;
            n += 1;
        }
    }
    return out[0..n];
}

fn expectKeys(expected: []const Key, bytes: []const u8) !void {
    var out: [32]Key = undefined;
    const got = decodeAll(bytes, &out);
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| {
        try std.testing.expectEqual(std.meta.activeTag(e), std.meta.activeTag(g));
        if (e == .insert) try std.testing.expectEqualStrings(e.insert.slice(), g.insert.slice());
    }
}

fn ins(bytes: []const u8) Key {
    var rune: Rune = .{};
    @memcpy(rune.bytes[0..bytes.len], bytes);
    rune.len = @intCast(bytes.len);
    return .{ .insert = rune };
}

test "feed: printable ASCII inserts one key per byte" {
    try expectKeys(&.{ ins("("), ins("+"), ins(" "), ins("1") }, "(+ 1");
}

test "feed: a multi-byte rune is one key" {
    try expectKeys(&.{ ins("é"), ins("度"), ins("😀") }, "é度😀");
}

test "feed: a rune split across two calls is one key" {
    var decoder = Decoder.init();
    const bytes = "度";
    try std.testing.expectEqual(null, decoder.feed(bytes[0]));
    try std.testing.expectEqual(null, decoder.feed(bytes[1]));
    const key = decoder.feed(bytes[2]).?;
    try std.testing.expectEqualStrings("度", key.insert.slice());
}

test "feed: a broken rune is dropped and the next byte decoded" {
    try expectKeys(&.{ins("a")}, "\xe5a");
    try expectKeys(&.{ins("\x80")}, "\x80");
}

test "feed: cursor keys as CSI and as SS3" {
    try expectKeys(&.{ .left, .right, .home, .end }, "\x1b[D\x1b[C\x1b[H\x1b[F");
    try expectKeys(&.{ .left, .right, .home, .end }, "\x1bOD\x1bOC\x1bOH\x1bOF");
    try expectKeys(&.{ .up, .down, .up, .down }, "\x1b[A\x1b[B\x1bOA\x1bOB");
    try expectKeys(&.{ .home, .end, .home, .end, .delete }, "\x1b[1~\x1b[4~\x1b[7~\x1b[8~\x1b[3~");
}

test "feed: control keys" {
    try expectKeys(&.{ .home, .left, .interrupt, .eof, .end, .right }, "\x01\x02\x03\x04\x05\x06");
    try expectKeys(&.{ .backspace, .backspace, .kill_end, .kill_start }, "\x08\x7f\x0b\x15");
    try expectKeys(&.{ .enter, .newline }, "\r\n");
    try expectKeys(&.{ .up, .down }, "\x10\x0e");
}

test "feed: the bracketed paste markers are keys of their own" {
    try expectKeys(&.{ .paste_start, ins("a"), .enter, .paste_end }, "\x1b[200~a\r\x1b[201~");
}

test "feed: an unrecognised CSI is consumed whole" {
    try expectKeys(&.{ .ignored, ins("a") }, "\x1b[99~a");
    try expectKeys(&.{ .ignored, ins("a") }, "\x1b[1;5Za");
}

test "feed: a modified cursor key is ignored rather than moving" {
    try expectKeys(&.{.ignored}, "\x1b[1;5D");
}

test "feed: a CSI ended by a control byte decodes that byte" {
    try expectKeys(&.{.enter}, "\x1b[1\r");
}

test "feed: ESC and another byte are ignored together" {
    try expectKeys(&.{ .ignored, ins("x") }, "\x1bbx");
}

test "feed: a tab is inserted and other controls are ignored" {
    try expectKeys(&.{ ins("\t"), .ignored, .ignored }, "\t\x07\x0c");
}
