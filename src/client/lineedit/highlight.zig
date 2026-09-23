//! The classifier that gives each byte of a buffer the class it is drawn in.
//!
//! `session.zig` calls `classify` over the whole buffer before each frame of
//! a line that reads source, and `render.zig` draws each class in its colour.
//! `classify` builds no value and uses nothing from an earlier call.
//!
//! ## A second description of the syntax
//!
//! `src/runtime/parser.zig` is the first description of the grammar and this
//! file is the second. The parser stops at its first error, and a buffer
//! being typed has to be classified to its end, so the classifier cannot be
//! the parser. The two share the tables in `src/lexicon.zig`: the whitespace
//! and symbol bytes, the escapes, the hex digits and the UTF-8 check. The
//! runtime gives the classifier `Predicates`: which tokens are numbers, which
//! are special forms and which are bound. What the classifier describes again
//! is dispatch, the `!` lookahead, the run of quotes and the adjacency of a
//! prefix. `test/highlight.zig` compares the classifier with the parser.
//!
//! ## Errors
//!
//! A byte is classed as an error only where the parser refuses the buffer:
//!
//! - Where the classifier classes a byte as an error, a fresh parser given the
//!   buffer has reported an error by the end of the line with the first such
//!   byte. A buffer the parser accepts is never shown as wrong.
//!
//! - What the end of the buffer cuts short is not an error: an unclosed
//!   delimiter, string or dispatch, an escape, a prefix, and the token at the
//!   end of the buffer. Each is what a correct form looks like while it is
//!   typed, so `1e` is not an error until a byte after it ends the token.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const lexicon = @import("lexicon");

// ==========================================================================
// Constants
// ==========================================================================

/// The most open delimiters whose closing delimiter is checked. A closing
/// delimiter deeper than this is not classed as an error.
const depth_limit = 256;

// ==========================================================================
// Aliased types
// ==========================================================================

/// Returns whether the symbol `token` is bound.
///
/// `Predicates` has a `Bound`.
pub const Bound = *const fn (token: []const u8) bool;

/// Returns whether `token` is a number.
///
/// `Predicates` has a `Number`. `token` is a run of symbol bytes that begins
/// with a digit, `-`, `+` or `.`.
pub const Number = *const fn (token: []const u8) bool;

/// Returns whether `token` is the name of a special form.
///
/// `Predicates` has a `Special`.
pub const Special = *const fn (token: []const u8) bool;

// ==========================================================================
// Types
// ==========================================================================

/// The class of a byte.
///
/// `classify` writes a `Class` for each byte and `render.Frame` takes them.
/// `plain` is a byte drawn in the terminal's own colour: a symbol that is not
/// bound, a delimiter, a prefix and whitespace. `bound` is a symbol that is
/// bound, `constant` is `nil`, `true` and `false`, and `string` includes a
/// buffer and the `!` before it.
pub const Class = enum(u8) {
    plain,
    comment,
    string,
    number,
    keyword,
    constant,
    special,
    bound,
    @"error",
};

/// The tests of a token the classifier takes from the runtime.
///
/// `classify` takes a `Predicates`. `number` reports which tokens are
/// numbers, `special` which are special forms, and `bound` which symbols are
/// bound, or null for none.
pub const Predicates = struct {
    number: Number,
    special: Special,
    bound: ?Bound = null,
};

/// One pass over a buffer.
///
/// `classify` makes a `Scanner`. `at` is the offset of the next byte,
/// `closers` the closing delimiter of each open delimiter up to
/// `depth_limit`, `depth` the number open, and `pending` the offset of the
/// prefix whose form has not begun, or null.
const Scanner = struct {
    text: []const u8,
    classes: []Class,
    predicates: Predicates,
    at: usize = 0,
    closers: [depth_limit]u8 = undefined,
    depth: usize = 0,
    pending: ?usize = null,

    /// Classifies every byte.
    fn scan(s: *Scanner) void {
        while (s.at < s.text.len) {
            const c = s.text[s.at];
            switch (c) {
                '\n', '\r' => {
                    // A prefix's form begins on the prefix's line.
                    if (s.pending) |p| s.paint(p, p + 1, .@"error");
                    s.pending = null;
                    s.at += 1;
                },
                '\'', '`', '~', '|' => {
                    if (s.pending == null) s.pending = s.at;
                    s.at += 1;
                },
                // A comment does not begin a prefix's form, so `pending` stays.
                ';' => s.at = s.comment(s.at),
                '"' => {
                    s.pending = null;
                    s.at = s.string(s.at);
                },
                '#' => s.dispatch(),
                '!' => s.bang(),
                '@', '^' => s.refuse(),
                '(' => s.open(')', 1),
                '[' => s.open(']', 1),
                '{' => s.open('}', 1),
                ')', ']', '}' => s.close(c),
                else => {
                    if (lexicon.isWhitespace(c)) {
                        s.at += 1;
                        continue;
                    }
                    if (!lexicon.isSymbolChar(c)) {
                        s.refuse();
                        continue;
                    }
                    s.pending = null;
                    s.at = s.token(s.at, s.at);
                },
            }
        }
    }

    /// Classes the byte at `at` as an error and moves past it.
    fn refuse(s: *Scanner) void {
        s.pending = null;
        s.paint(s.at, s.at + 1, .@"error");
        s.at += 1;
    }

    /// Opens a delimiter whose opening bytes are `width` long and whose
    /// closing delimiter is `closer`.
    fn open(s: *Scanner, closer: u8, width: usize) void {
        s.pending = null;
        if (s.depth < depth_limit) s.closers[s.depth] = closer;
        s.depth += 1;
        s.at += width;
    }

    /// Closes the innermost delimiter with `closer`, or classes `closer` as an
    /// error where nothing is open or a different delimiter is.
    fn close(s: *Scanner, closer: u8) void {
        // With a prefix pending the parser's innermost state is the prefix's,
        // which no delimiter closes.
        const wrong = s.pending != null or s.depth == 0 or
            (s.depth <= depth_limit and s.closers[s.depth - 1] != closer);
        if (wrong) s.paint(s.at, s.at + 1, .@"error");
        s.pending = null;
        if (s.depth > 0) s.depth -= 1;
        s.at += 1;
    }

    /// Classes a comment that begins at `start`, and returns the offset of the
    /// newline or carriage return that ends it, or the end of the buffer.
    fn comment(s: *Scanner, start: usize) usize {
        const end = std.mem.indexOfAnyPos(u8, s.text, start, "\n\r") orelse s.text.len;
        s.paint(start, end, .comment);
        return end;
    }

    /// Classes what follows a `#`: a short function, a set, the shebang, or an
    /// error.
    fn dispatch(s: *Scanner) void {
        const start = s.at;
        s.pending = null;
        if (start + 1 >= s.text.len) {
            s.at += 1;
            return;
        }
        const next = s.text[start + 1];
        // The parser reads `#!` as a comment only at the first byte of its
        // source.
        if (start == 0 and next == '!') {
            s.at = s.comment(start);
            return;
        }
        switch (next) {
            '(' => s.open(')', 2),
            '{' => s.open('}', 2),
            else => {
                // A word tag is refused, and the word is classed with the `#`.
                var end = start + 1;
                while (end < s.text.len and lexicon.isSymbolChar(s.text[end])) end += 1;
                s.paint(start, @max(end, start + 1), .@"error");
                s.at = @max(end, start + 1);
            },
        }
    }

    /// Classes what follows a `!`: a mutable container, a buffer, or a token
    /// that begins with the `!`.
    fn bang(s: *Scanner) void {
        const start = s.at;
        s.pending = null;
        if (start + 1 >= s.text.len) {
            s.at += 1;
            return;
        }
        switch (s.text[start + 1]) {
            '(' => s.open(')', 2),
            '[' => s.open(']', 2),
            '{' => s.open('}', 2),
            '"' => {
                s.paint(start, start + 1, .string);
                s.at = s.string(start + 1);
            },
            else => s.at = s.token(start, start + 1),
        }
    }

    /// Classes the token that begins at `start` and whose symbol bytes are
    /// read from `from`, and returns the offset after it.
    fn token(s: *Scanner, start: usize, from: usize) usize {
        var end = from;
        while (end < s.text.len and lexicon.isSymbolChar(s.text[end])) end += 1;
        var class = tokenClass(s.text[start..end], s.predicates);
        // The parser checks a token when a byte after it ends it.
        if (class == .@"error" and end == s.text.len) class = if (s.text[start] == ':') .keyword else .plain;
        s.paint(start, end, class);
        return end;
    }

    /// Classes the run of quotes at `start` and the string it opens, and
    /// returns the offset after the string, or the end of the buffer where the
    /// string is not closed.
    fn string(s: *Scanner, start: usize) usize {
        var run = start;
        while (run < s.text.len and s.text[run] == '"') run += 1;
        const opening = run - start;
        s.paint(start, run, .string);
        if (opening == 2) return run;
        if (opening == 1) return s.ordinary(start, run);
        return s.raw(start, run, opening);
    }

    /// Classes an ordinary string opened at `start`, whose contents begin at
    /// `from`, and returns the offset after it.
    fn ordinary(s: *Scanner, start: usize, from: usize) usize {
        var k = from;
        while (k < s.text.len) {
            switch (s.text[k]) {
                '"' => {
                    s.paint(k, k + 1, .string);
                    return k + 1;
                },
                '\n', '\r' => {
                    // An ordinary string does not span lines.
                    s.paint(start, k, .@"error");
                    return k;
                },
                '\\' => k = s.escape(k),
                else => {
                    s.paint(k, k + 1, .string);
                    k += 1;
                },
            }
        }
        return k;
    }

    /// Classes the escape whose backslash is at `start`, and returns the
    /// offset after it.
    fn escape(s: *Scanner, start: usize) usize {
        const len = s.text.len;
        s.paint(start, @min(start + 2, len), .string);
        if (start + 1 >= len) return len;
        const letter = s.text[start + 1];
        const escaped = lexicon.escape(letter) orelse {
            // A newline after the backslash is left to end the string.
            const newline = letter == '\n' or letter == '\r';
            const end = if (newline) start + 1 else start + 2;
            s.paint(start, end, .@"error");
            return end;
        };
        const digits = switch (escaped) {
            .byte => return start + 2,
            .digits => |count| count,
        };
        var codepoint: u32 = 0;
        var k = start + 2;
        while (k < start + 2 + digits) : (k += 1) {
            if (k >= len) {
                s.paint(start, len, .string);
                return len;
            }
            const digit = lexicon.hexDigit(s.text[k]) orelse {
                const newline = s.text[k] == '\n' or s.text[k] == '\r';
                const end = if (newline) k else k + 1;
                s.paint(start, end, .@"error");
                return end;
            };
            codepoint = codepoint * 16 + digit;
        }
        const class: Class = if (codepoint > lexicon.max_codepoint) .@"error" else .string;
        s.paint(start, k, class);
        return k;
    }

    /// Classes a raw string opened at `start` by a run of `opening` quotes
    /// that ends at `from`, and returns the offset after it.
    ///
    /// The first run of `opening` quotes after `from` closes it, and a quote
    /// after that run begins a new string.
    fn raw(s: *Scanner, start: usize, from: usize, opening: usize) usize {
        var k = from;
        while (k < s.text.len) {
            if (s.text[k] != '"') {
                k += 1;
                continue;
            }
            var run = k;
            while (run < s.text.len and s.text[run] == '"' and run - k < opening) run += 1;
            if (run - k == opening) {
                s.paint(start, run, .string);
                return run;
            }
            k = run;
        }
        s.paint(start, k, .string);
        return k;
    }

    /// Writes `class` for the bytes from `from` up to `to`.
    fn paint(s: *Scanner, from: usize, to: usize, class: Class) void {
        @memset(s.classes[from..to], class);
    }
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Writes the class of each byte of `text` to `classes`.
///
/// `classes` has the length of `text`. `predicates` reports which tokens are
/// numbers, special forms and bound symbols. This function cannot fail.
pub fn classify(text: []const u8, classes: []Class, predicates: Predicates) void {
    std.debug.assert(classes.len == text.len);
    @memset(classes, .plain);
    var scanner: Scanner = .{ .text = text, .classes = classes, .predicates = predicates };
    scanner.scan();
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Returns the class of the token `text`, a run of symbol bytes.
///
/// The order is the parser's: a keyword, a number, `nil`, `true` or `false`,
/// and otherwise a symbol, which may not begin with a digit.
fn tokenClass(text: []const u8, predicates: Predicates) Class {
    const first = text[0];
    if (first == ':') return if (lexicon.validUtf8(text[1..])) .keyword else .@"error";
    const digit = first >= '0' and first <= '9';
    if ((digit or first == '-' or first == '+' or first == '.') and predicates.number(text)) return .number;
    if (std.mem.eql(u8, text, "nil") or std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false")) return .constant;
    if (digit or !lexicon.validUtf8(text)) return .@"error";
    if (predicates.special(text)) return .special;
    if (predicates.bound) |bound| {
        if (bound(text)) return .bound;
    }
    return .plain;
}

// ==========================================================================
// Tests
// ==========================================================================

/// The numbers of the tests: a sign or none, then digits with at most one
/// `.`, and at least one digit.
fn testNumber(token: []const u8) bool {
    var text = token;
    if (text[0] == '-' or text[0] == '+') text = text[1..];
    var digits: usize = 0;
    var dots: usize = 0;
    for (text) |byte| {
        if (byte == '.') {
            dots += 1;
        } else if (std.ascii.isDigit(byte)) {
            digits += 1;
        } else return false;
    }
    return digits > 0 and dots <= 1;
}

/// The bound symbols of the tests.
fn testBound(token: []const u8) bool {
    return std.mem.eql(u8, token, "map") or std.mem.eql(u8, token, "if");
}

/// The special forms of the tests.
fn testSpecial(token: []const u8) bool {
    return std.mem.eql(u8, token, "def") or std.mem.eql(u8, token, "fn") or std.mem.eql(u8, token, "if");
}

const test_predicates: Predicates = .{ .number = &testNumber, .special = &testSpecial, .bound = &testBound };

/// Checks the classes of `text` against `expected`, one letter for each byte:
/// `.` plain, `c` comment, `s` string, `n` number, `k` keyword, `o`
/// constant, `p` special, `b` bound and `E` error.
fn expectClasses(text: []const u8, expected: []const u8) !void {
    try std.testing.expectEqual(text.len, expected.len);
    var classes: [256]Class = undefined;
    classify(text, classes[0..text.len], test_predicates);
    var got: [256]u8 = undefined;
    for (classes[0..text.len], 0..) |class, i| {
        got[i] = switch (class) {
            .plain => '.',
            .comment => 'c',
            .string => 's',
            .number => 'n',
            .keyword => 'k',
            .constant => 'o',
            .special => 'p',
            .bound => 'b',
            .@"error" => 'E',
        };
    }
    try std.testing.expectEqualStrings(expected, got[0..text.len]);
}

test "classify: each class" {
    try expectClasses(
        \\(def x "a" :k 1 nil) ; c
    ,
        \\.ppp...sss.kk.n.ooo..ccc
    );
    try expectClasses("(if true -1.5 +)", ".pp.oooo.nnnn...");
    try expectClasses("!\"ab\" ![1] !{} !x x!", "sssss...n...........");
    // A special form is a special form whether or not it is bound.
    try expectClasses("(map if mapx)", ".bbb.pp......");
}

test "classify: strings, raw strings and escapes" {
    try expectClasses("\"\" \"a\\n\\x41\\u00e9\"", "ss.sssssssssssssss");
    try expectClasses("\"\"\"a\"b\"\"\"c", "sssssssss.");
    // A run longer than the opening run closes the string and opens another.
    try expectClasses("\"\"\"a\"\"\"\"", "ssssssss");
    try expectClasses("\"\\U10FFFF\"", "ssssssssss");
}

test "classify: each error" {
    try expectClasses("@a ^b", "E..E.");
    try expectClasses("a\\b \x01", ".E..E");
    try expectClasses("#foo x #[", "EEEE...E.");
    try expectClasses("\"\\q\"", "sEEs");
    try expectClasses("\"\\x4G\"", "sEEEEs");
    try expectClasses("\"\\u12\"", "sEEEEE");
    try expectClasses("\"\\U110000\"", "sEEEEEEEEs");
    try expectClasses("\"ab\ncd", "EEE...");
    try expectClasses("1x 1", "EE.n");
    try expectClasses("a\xff :\xff ", "EE.EE.");
    try expectClasses(") (] [}", "E..E..E");
    try expectClasses("' \n'x", "E....");
    try expectClasses("'; c\n", "Eccc.");
    try expectClasses("'; c\r\n", "Eccc..");
    try expectClasses("; a\rb", "ccc..");
    try expectClasses("(')", "..E");
}

test "classify: what is typed and unfinished is not an error" {
    try expectClasses("(def x", ".ppp..");
    try expectClasses("\"ab", "sss");
    try expectClasses("\"a\\", "sss");
    try expectClasses("\"a\\x4", "sssss");
    try expectClasses("\"\"\"a\nb", "ssssss");
    try expectClasses("#", ".");
    try expectClasses("'", ".");
    try expectClasses("!", ".");
    try expectClasses("1e", "..");
    try expectClasses("a\xc3", "..");
    try expectClasses(":\xc3", "kk");
    try expectClasses("#{1 #(a", "..n....");
}

test "classify: the shebang only at the first byte" {
    try expectClasses("#!/bin/w\nx", "cccccccc..");
    try expectClasses(" #!", ".EE");
}

test "classify: a closing delimiter beyond the depth limit is not checked" {
    var text: [depth_limit + 2]u8 = undefined;
    @memset(text[0 .. depth_limit + 1], '(');
    text[depth_limit + 1] = ']';
    var classes: [depth_limit + 2]Class = undefined;
    classify(&text, &classes, test_predicates);
    try std.testing.expectEqual(Class.plain, classes[depth_limit + 1]);
}
