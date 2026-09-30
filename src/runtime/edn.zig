//! The `edn/` library: `edn/decode` and `edn/encode`.
//!
//! `env.zig`'s `loadLibs` calls `libEdn` in every configuration. The decoder
//! is a recursive reader over the whole text, and the encoder is the edn
//! writer of `pp/pretty.zig`, the one that `%y` runs.
//!
//! ## What each side refuses
//!
//! Decoding raises where the text is not exactly one edn value that Wattle has
//! a value for, and encoding raises where the value has no edn text. The flags
//! relax two of those rules:
//!
//! - `:t` reads the tags `#wattle/array`, `#wattle/table` and
//!   `#wattle/buffer` as a mutable array, table and buffer, and writes those
//!   three types as those tags. Without it a tag is refused on reading, and
//!   a mutable array, table or buffer is refused on writing.
//!
//! - `:d` dedents strings on reading. The first line of a string is left as
//!   written, and each line after a literal newline loses up to as many
//!   leading spaces as the second line has. An escaped `\n` is not a literal
//!   newline, so the flag works on the text and not on the decoded value.
//!
//! - `:p` dedents as `:d` does and then joins the lines of each paragraph
//!   with a space. A blank line ends a paragraph and is written as two
//!   newlines, and an escaped `\n` stays a hard line break.
//!
//! - A character literal, a number with an `N` or `M` suffix, a tag other than
//!   the three, a map whose value is nil, a map with a repeated key, a set
//!   with a repeated element and an integer that is not exactly a double are
//!   refused on reading. The decoder reads edn and nothing else, so a `"""`
//!   string, a `!` literal and a prefix are refused as well.
//!
//! - Text that is not valid UTF-8 is refused on reading, and a string that is
//!   not valid UTF-8 is refused on writing.
//!
//! - A list is a tuple, a vector a vector, a map a map and a set a set, each
//!   persistent. Commas are whitespace, `;` starts a comment and `#_`
//!   discards the next form.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const args_core = @import("args.zig");
const arrays = @import("value/arrays.zig");
const buffers = @import("value/buffers.zig");
const config = @import("config");
const corefn = @import("corefn.zig");
const json = @import("json.zig");
const maps = @import("value/maps.zig");
const pp_format = @import("pp/format.zig");
const pretty = @import("pp/pretty.zig");
const raise = @import("../api/raise.zig");
const repr = @import("repr");
const scratch_vector = @import("scratch_vector.zig");
const strings = @import("value/strings.zig");
const tables = @import("value/tables.zig");
const tuples = @import("value/tuples.zig");
const value = @import("value.zig");
const vectors = @import("value/vectors.zig");
const wrap = @import("value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The bytes that end a token: whitespace, a comma, a comment, a string and
/// the delimiters of a collection.
const terminators = " \t\n\r,;\"()[]{}";

/// The bytes other than letters and digits that a symbol or a keyword may
/// contain.
const symbol_punctuation = ".*+!-_?$%&=<>:#/";

// ==========================================================================
// Types
// ==========================================================================

/// The state of one `edn/decode` call.
///
/// `text` is the argument and `at` the offset of the next byte. `tags`,
/// `dedent` and `paragraphs` are the `:t`, `:d` and `:p` flags, and `depth`
/// counts the collections open.
const Decoder = struct {
    text: []const u8,
    at: usize = 0,
    tags: bool,
    dedent: bool,
    paragraphs: bool,
    depth: i32 = 0,

    /// Raises with the line and column of `at` and `reason`.
    fn fail(self: *Decoder, at: usize, reason: [*:0]const u8) raise.Error {
        const position = self.locate(at);
        return pp_format.panicf("invalid edn at line %d, column %d: %s", .{ position[0], position[1], reason });
    }

    /// Raises as `fail` does, with `name` written after `reason`.
    fn failNamed(self: *Decoder, at: usize, reason: [*:0]const u8, name: []const u8) raise.Error {
        const position = self.locate(at);
        return pp_format.panicf("invalid edn at line %d, column %d: %s%S", .{
            position[0],
            position[1],
            reason,
            strings.new(name),
        });
    }

    /// Returns the line and the column, counted from 1, of offset `at`.
    fn locate(self: *Decoder, at: usize) [2]i64 {
        var line: i64 = 1;
        var start: usize = 0;
        for (self.text[0..at], 0..) |byte, index| {
            if (byte == '\n') {
                line += 1;
                start = index + 1;
            }
        }
        return .{ line, @as(i64, @intCast(at - start)) + 1 };
    }

    /// Returns the value the text is, raising where it is not exactly one.
    fn document(self: *Decoder) raise.Error!repr.Value {
        if (!std.unicode.utf8ValidateSlice(self.text)) {
            return raise.panic("edn text is not valid UTF-8");
        }
        const result = try self.read();
        try self.skip();
        if (self.at < self.text.len) return self.fail(self.at, "unexpected text after the value");
        return result;
    }

    /// Steps over whitespace, commas, comments and discarded forms.
    ///
    /// This function raises where a `#_` has no form after it, or where the
    /// form is not edn.
    fn skip(self: *Decoder) raise.Error!void {
        while (self.at < self.text.len) {
            switch (self.text[self.at]) {
                ' ', '\t', '\n', '\r', ',' => self.at += 1,
                ';' => {
                    while (self.at < self.text.len and self.text[self.at] != '\n') self.at += 1;
                },
                '#' => {
                    if (self.at + 1 >= self.text.len or self.text[self.at + 1] != '_') return;
                    self.at += 2;
                    _ = try self.read();
                },
                else => return,
            }
        }
    }

    /// Returns the value that begins at the next byte that is not skipped.
    fn read(self: *Decoder) raise.Error!repr.Value {
        try self.skip();
        if (self.at >= self.text.len) return self.fail(self.at, "unexpected end of text");
        switch (self.text[self.at]) {
            '"' => return self.string(),
            '[' => return self.vector(),
            '(' => return self.list(),
            '{' => return self.map(),
            '#' => return self.dispatch(),
            '\\' => return self.fail(self.at, "character literals are not supported"),
            ')', ']', '}' => return self.fail(self.at, "unexpected closing delimiter"),
            else => return self.token(),
        }
    }

    /// Counts one more collection open, and raises where that is deeper than
    /// `config.recursion_guard`.
    fn enter(self: *Decoder, at: usize) raise.Error!void {
        self.depth += 1;
        if (self.depth > config.recursion_guard) {
            return self.fail(at, "nesting is too deep");
        }
    }

    /// Reads the elements up to `close` into `items`.
    ///
    /// `open` is the offset of the opening delimiter, which an unterminated
    /// collection is reported at, and `self.at` is the offset after it.
    fn elements(
        self: *Decoder,
        open: usize,
        close: u8,
        items: *scratch_vector.Vector(repr.Value),
    ) raise.Error!void {
        try self.enter(open);
        while (true) {
            try self.skip();
            if (self.at >= self.text.len) return self.fail(open, "unterminated collection");
            const byte = self.text[self.at];
            if (byte == close) {
                self.at += 1;
                break;
            }
            if (byte == ')' or byte == ']' or byte == '}') {
                return self.fail(self.at, "mismatched closing delimiter");
            }
            scratch_vector.push(items, try self.read());
        }
        self.depth -= 1;
    }

    /// Returns the vector of the elements between `[` and `]`.
    fn vector(self: *Decoder) raise.Error!repr.Value {
        const open = self.at;
        self.at += 1;
        var items: scratch_vector.Vector(repr.Value) = .empty;
        defer scratch_vector.free(&items);
        try self.elements(open, ']', &items);
        return wrap.fromVector(vectors.fromSlice(items.items));
    }

    /// Returns the tuple of the elements between `(` and `)`.
    fn list(self: *Decoder) raise.Error!repr.Value {
        const open = self.at;
        self.at += 1;
        var items: scratch_vector.Vector(repr.Value) = .empty;
        defer scratch_vector.free(&items);
        try self.elements(open, ')', &items);
        return wrap.fromTuple(tuples.newFrom(items.items));
    }

    /// Returns the map of the entries between `{` and `}`.
    ///
    /// This function raises where there is a key with no value, a key that a
    /// map cannot hold, a value that is nil, or a key that occurs twice.
    fn map(self: *Decoder) raise.Error!repr.Value {
        const open = self.at;
        self.at += 1;
        var items: scratch_vector.Vector(repr.Value) = .empty;
        defer scratch_vector.free(&items);
        try self.elements(open, '}', &items);
        if (items.items.len % 2 != 0) return self.fail(open, "a map has a key with no value");
        var index: usize = 0;
        while (index < items.items.len) : (index += 2) {
            try maps.checkKey(items.items[index]);
            if (repr.checkType(items.items[index + 1], repr.Tag.nil)) {
                return self.fail(open, "a map cannot hold nil");
            }
        }
        const tree = maps.build(.map, items.items);
        if (tree.count != items.items.len / 2) return self.fail(open, "a map has a repeated key");
        return wrap.fromMap(tree);
    }

    /// Returns the set of the elements between `#{` and `}`, where `open` is
    /// the offset of the `#` and `self.at` is the offset after the `{`.
    ///
    /// This function raises where an element is one that a set cannot hold, or
    /// occurs twice.
    fn set(self: *Decoder, open: usize) raise.Error!repr.Value {
        var items: scratch_vector.Vector(repr.Value) = .empty;
        defer scratch_vector.free(&items);
        try self.elements(open, '}', &items);
        for (items.items) |element| try maps.checkKey(element);
        const tree = maps.build(.set, items.items);
        if (tree.count != items.items.len) return self.fail(open, "a set has a repeated element");
        return wrap.fromAbstract(tree);
    }

    /// Returns the value of the form that begins with `#`.
    ///
    /// `#{` is a set and `#_` was skipped. Any other `#` begins a tag, which
    /// is read only with `:t`, and only for the three `#wattle/` tags.
    fn dispatch(self: *Decoder) raise.Error!repr.Value {
        const open = self.at;
        if (open + 1 >= self.text.len) return self.fail(open, "unexpected end of text");
        switch (self.text[open + 1]) {
            '{' => {
                self.at += 2;
                return self.set(open);
            },
            '#' => return self.fail(open, "symbolic values are not supported"),
            else => {},
        }
        const start = open + 1;
        var end = start;
        while (end < self.text.len and std.mem.findScalar(u8, terminators, self.text[end]) == null) end += 1;
        const name = self.text[start..end];
        if (!validSymbol(name, false)) return self.fail(open, "a tag is a symbol");
        const Tag = enum { array, table, buffer };
        const tag: Tag = if (std.mem.eql(u8, name, "wattle/array"))
            .array
        else if (std.mem.eql(u8, name, "wattle/table"))
            .table
        else if (std.mem.eql(u8, name, "wattle/buffer"))
            .buffer
        else
            return self.failNamed(open, "unknown tag #", name);
        if (!self.tags) return self.failNamed(open, "reading a tag needs the :t flag: #", name);
        self.at = end;
        const payload = try self.read();
        switch (tag) {
            .array => {
                if (!repr.checkType(payload, repr.Tag.vector)) return self.fail(open, "#wattle/array needs a vector");
                const length: usize = @intCast(wrap.toVector(payload).count);
                const array = arrays.new(length);
                var runs = (try args_core.chunks(payload)).?;
                while (try runs.next()) |run| {
                    for (run) |element| try arrays.push(array, element);
                }
                return wrap.fromArray(array);
            },
            .table => {
                if (!repr.checkType(payload, repr.Tag.map)) return self.fail(open, "#wattle/table needs a map");
                const table = tables.new(0);
                var pairs = (try args_core.keyvals(payload)).?;
                while (try pairs.next()) |kv| tables.put(table, kv.key, kv.value);
                return wrap.fromTable(table);
            },
            .buffer => {
                if (!repr.checkType(payload, repr.Tag.string)) return self.fail(open, "#wattle/buffer needs a string");
                const bytes = strings.bytesOf(wrap.toString(payload));
                const buffer = buffers.new(bytes.len);
                try buffers.pushBytes(buffer, bytes);
                return wrap.fromBuffer(buffer);
            },
        }
    }

    /// Returns the string between the quotes at the next byte.
    ///
    /// Under `:d`, the spaces counted from the first literal newline are the
    /// indentation, and up to that many are dropped after every literal
    /// newline. Under `:p`, the same indentation is dropped and the lines of
    /// a paragraph are joined as `joinLines` says. An escaped newline is
    /// neither, because only a literal one is a line break in the text.
    fn string(self: *Decoder) raise.Error!repr.Value {
        const open = self.at;
        self.at += 1;
        var out: scratch_vector.Vector(u8) = .empty;
        defer scratch_vector.free(&out);
        var indent: ?usize = null;
        var protected: usize = 0;
        while (true) {
            if (self.at >= self.text.len) return self.fail(open, "unterminated string");
            const byte = self.text[self.at];
            self.at += 1;
            switch (byte) {
                '"' => break,
                '\\' => {
                    try self.escape(&out, open);
                    protected = out.items.len;
                },
                '\r' => {
                    const crlf = self.at < self.text.len and self.text[self.at] == '\n';
                    if (!(self.paragraphs and crlf)) scratch_vector.push(&out, byte);
                },
                '\n' => {
                    if (self.paragraphs) {
                        self.joinLines(&out, &indent, protected);
                    } else {
                        scratch_vector.push(&out, '\n');
                        if (!self.dedent) continue;
                        if (indent == null) indent = self.spacesAhead();
                        self.dropSpaces(indent.?);
                    }
                },
                else => scratch_vector.push(&out, byte),
            }
        }
        return value.fromBytes(out.items, .string);
    }

    /// Returns the number of spaces that begin the text at `self.at`.
    fn spacesAhead(self: *Decoder) usize {
        var spaces: usize = 0;
        while (self.at + spaces < self.text.len and self.text[self.at + spaces] == ' ') spaces += 1;
        return spaces;
    }

    /// Steps over up to `limit` spaces.
    fn dropSpaces(self: *Decoder, limit: usize) void {
        var dropped: usize = 0;
        while (dropped < limit and self.at < self.text.len and self.text[self.at] == ' ') : (dropped += 1) {
            self.at += 1;
        }
    }

    /// Ends a line under `:p`, where `self.at` is the offset after the
    /// literal newline and `out` is the string so far.
    ///
    /// The spaces before the newline are dropped, except those an escape
    /// wrote, which end at offset `protected` of `out`. The indentation of
    /// the next line is dropped, and a line of only spaces is blank. The
    /// lines after this one that are blank are a paragraph break, which is
    /// written as two newlines, and the next line keeps the spaces it has past
    /// the indentation. Where there is none, the next line joins this one
    /// after a single space, and loses the spaces it has past the
    /// indentation. A break at the start or the end of the string writes
    /// nothing, and neither does a break after an escaped newline, which is a
    /// hard line break.
    fn joinLines(
        self: *Decoder,
        out: *scratch_vector.Vector(u8),
        indent: *?usize,
        protected: usize,
    ) void {
        while (out.items.len > protected and out.items[out.items.len - 1] == ' ') {
            out.shrinkRetainingCapacity(out.items.len - 1);
        }
        if (indent.* == null) indent.* = self.spacesAhead();
        var blanks: usize = 0;
        while (true) {
            self.dropSpaces(indent.*.?);
            var end = self.at;
            while (end < self.text.len and self.text[end] == ' ') end += 1;
            if (end + 1 < self.text.len and self.text[end] == '\r' and self.text[end + 1] == '\n') end += 1;
            if (end >= self.text.len or self.text[end] != '\n') break;
            self.at = end + 1;
            blanks += 1;
        }
        if (self.at < self.text.len and self.text[self.at] == '"') return;
        const length = out.items.len;
        if (length == 0) return;
        var newlines: usize = 0;
        while (newlines < 2 and newlines < length and out.items[length - 1 - newlines] == '\n') newlines += 1;
        if (blanks > 0) {
            var missing = 2 - newlines;
            while (missing > 0) : (missing -= 1) scratch_vector.push(out, '\n');
            return;
        }
        self.dropSpaces(std.math.maxInt(usize));
        if (newlines == 0) scratch_vector.push(out, ' ');
    }

    /// Appends the character the escape after a backslash stands for, where
    /// `self.at` is the offset after the backslash and `open` the offset of
    /// the string's quote.
    fn escape(self: *Decoder, out: *scratch_vector.Vector(u8), open: usize) raise.Error!void {
        if (self.at >= self.text.len) return self.fail(open, "unterminated string");
        const letter = self.text[self.at];
        self.at += 1;
        switch (letter) {
            't' => scratch_vector.push(out, '\t'),
            'r' => scratch_vector.push(out, '\r'),
            'n' => scratch_vector.push(out, '\n'),
            '\\' => scratch_vector.push(out, '\\'),
            '"' => scratch_vector.push(out, '"'),
            'u' => {
                var code = try self.hex4();
                if (code >= 0xD800 and code <= 0xDBFF) {
                    const pair = self.at;
                    if (self.at + 1 >= self.text.len or self.text[self.at] != '\\' or self.text[self.at + 1] != 'u') {
                        return self.fail(pair, "a high surrogate needs a low surrogate");
                    }
                    self.at += 2;
                    const low = try self.hex4();
                    if (low < 0xDC00 or low > 0xDFFF) return self.fail(pair, "a high surrogate needs a low surrogate");
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                } else if (code >= 0xDC00 and code <= 0xDFFF) {
                    return self.fail(self.at - 6, "a low surrogate needs a high surrogate");
                }
                var encoded: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(@intCast(code), &encoded) catch unreachable;
                for (encoded[0..length]) |byte| scratch_vector.push(out, byte);
            },
            else => return self.fail(self.at - 2, "invalid escape in a string"),
        }
    }

    /// Returns the four hex digits at the next bytes.
    fn hex4(self: *Decoder) raise.Error!u32 {
        if (self.at + 4 > self.text.len) return self.fail(self.at, "a \\u escape needs four hex digits");
        var code: u32 = 0;
        for (self.text[self.at..][0..4]) |digit| {
            const nibble = std.fmt.charToDigit(digit, 16) catch
                return self.fail(self.at, "a \\u escape needs four hex digits");
            code = code * 16 + nibble;
        }
        self.at += 4;
        return code;
    }

    /// Returns the value of the token at the next byte: `nil`, `true`,
    /// `false`, a number, a keyword or a symbol.
    fn token(self: *Decoder) raise.Error!repr.Value {
        const start = self.at;
        var end = start;
        while (end < self.text.len and std.mem.findScalar(u8, terminators, self.text[end]) == null) end += 1;
        const text = self.text[start..end];
        self.at = end;
        if (std.mem.eql(u8, text, "nil")) return wrap.fromNil();
        if (std.mem.eql(u8, text, "true")) return wrap.fromTrue();
        if (std.mem.eql(u8, text, "false")) return wrap.fromFalse();
        const first = text[0];
        const second: u8 = if (text.len > 1) text[1] else 0;
        if (first == ':') {
            if (!validSymbol(text[1..], true)) return self.fail(start, "invalid keyword");
            return value.fromBytes(text[1..], .keyword);
        }
        if (std.ascii.isDigit(first) or ((first == '+' or first == '-') and std.ascii.isDigit(second))) {
            return self.number(start, text);
        }
        if (!validSymbol(text, false)) return self.fail(start, "invalid symbol");
        return value.fromBytes(text, .symbol);
    }

    /// Returns the number `text` spells, which begins at offset `start`.
    ///
    /// The grammar is edn's: an optional sign, an integer with no leading
    /// zero, an optional fraction and an optional exponent. This function
    /// raises where `text` is not that, where it has an `N` or `M` suffix,
    /// where it is out of range, or where it is an integer a double does not
    /// represent exactly.
    fn number(self: *Decoder, start: usize, text: []const u8) raise.Error!repr.Value {
        var at: usize = 0;
        if (text[at] == '+' or text[at] == '-') at += 1;
        const digits_start = at;
        if (at >= text.len or !std.ascii.isDigit(text[at])) return self.fail(start, "invalid number");
        if (text[at] == '0') {
            at += 1;
        } else {
            while (at < text.len and std.ascii.isDigit(text[at])) at += 1;
        }
        const digits = text[digits_start..at];
        var integer = true;
        if (at < text.len and text[at] == '.') {
            integer = false;
            at += 1;
            const fraction = at;
            while (at < text.len and std.ascii.isDigit(text[at])) at += 1;
            if (at == fraction) return self.fail(start, "invalid number");
        }
        if (at < text.len and (text[at] == 'e' or text[at] == 'E')) {
            integer = false;
            at += 1;
            if (at < text.len and (text[at] == '+' or text[at] == '-')) at += 1;
            const exponent = at;
            while (at < text.len and std.ascii.isDigit(text[at])) at += 1;
            if (at == exponent) return self.fail(start, "invalid number");
        }
        if (at < text.len and (text[at] == 'N' or text[at] == 'M') and at + 1 == text.len) {
            return self.fail(start, "numbers with an N or M suffix are not supported");
        }
        if (at != text.len) return self.fail(start, "invalid number");
        const unsigned = if (text[0] == '+') text[1..] else text;
        const x = std.fmt.parseFloat(f64, unsigned) catch return self.fail(start, "invalid number");
        if (std.math.isInf(x)) return self.fail(start, "number is out of range");
        if (integer and !json.exactInteger(digits, @abs(x))) {
            return self.fail(start, "integer is not exactly a number");
        }
        return wrap.fromNumber(x);
    }
};

// ==========================================================================
// Private functions
// ==========================================================================

/// Checks whether `text` is a symbol, or a keyword's text after its colon
/// where `keyword` is true.
///
/// A symbol is letters, digits and the punctuation of `symbol_punctuation`,
/// and any byte above 127. It does not begin with a digit, a colon or `#`,
/// and a `-`, `+` or `.` that begins it is not followed by a digit. A keyword
/// may begin with a digit but not with a colon. There is at most one `/`, with
/// a name on each side of it, and the symbol `/` alone is a symbol.
fn validSymbol(text: []const u8, keyword: bool) bool {
    if (text.len == 0) return false;
    if (std.mem.eql(u8, text, "/")) return !keyword;
    if (text[0] == ':' or text[0] == '#') return false;
    if (!keyword and std.ascii.isDigit(text[0])) return false;
    if (text.len > 1 and std.mem.findScalar(u8, "-+.", text[0]) != null and std.ascii.isDigit(text[1])) return false;
    var slashes: usize = 0;
    for (text, 0..) |byte, index| {
        if (byte > 127 or std.ascii.isAlphanumeric(byte)) continue;
        if (std.mem.findScalar(u8, symbol_punctuation, byte) == null) return false;
        if (byte == '/') {
            slashes += 1;
            if (index == 0 or index + 1 == text.len) return false;
        }
    }
    return slashes <= 1;
}

/// `(edn/decode x [flags])`.
fn nfunDecode(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    const view = try args_core.getBytes(argv, 0);
    const flags = if (argv.len > 1) try args_core.getFlags(argv, 1, "tdp") else 0;
    var decoder: Decoder = .{
        .text = if (view.bytes) |p| p[0..view.len] else &.{},
        .tags = flags & 1 != 0,
        .dedent = flags & 2 != 0,
        .paragraphs = flags & 4 != 0,
    };
    return decoder.document();
}

/// `(edn/encode x [flags])`.
fn nfunEncode(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    const flags = if (argv.len > 1) try args_core.getFlags(argv, 1, "t") else 0;
    const depth: c_int = config.recursion_guard;
    const buffer = if (flags & 1 != 0)
        try pretty.edn(null, depth, argv[0], 0, 0)
    else
        try pretty.ednStrict(null, depth, argv[0], 0, 0);
    return value.fromBytes(buffer.slice(), .string);
}

// ==========================================================================
// Public functions
// ==========================================================================

/// Installs `edn/decode` and `edn/encode` into the core environment.
///
/// `env` is the environment. This function cannot raise.
pub fn libEdn(env: *tables.Table) raise.Error!void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("edn/decode", &nfunDecode, @src(), "(edn/decode x)\n(edn/decode x flags)", "Decodes x, a string or a buffer of edn text that holds one value. " ++
            "A list is a tuple, a vector is a vector, a map is a map and a set is a set, each persistent. " ++
            "flags is a keyword of characters. `:t` reads the tags #wattle/array, #wattle/table and #wattle/buffer as a mutable array, table and buffer. " ++
            "`:d` dedents each string: a line after a literal newline loses up to as many leading spaces as the second line has, and an escaped newline is left alone. " ++
            "`:p` dedents as `:d` does and joins the lines of each paragraph with a space, where a blank line ends a paragraph and an escaped newline is a hard line break. " ++
            "Raises an error if x is not edn, if it has a character literal, a number with an N or M suffix or a tag that is not read, " ++
            "if a map has a nil value or a repeated key, if a set has a repeated element, if an integer is not exactly a number, " ++
            "if a number is out of range, or if the nesting is too deep."),
        corefn.reg("edn/encode", &nfunEncode, @src(), "(edn/encode x)\n(edn/encode x flags)", "Encodes x as edn text and returns a string. " ++
            "A tuple is a list, a vector is a vector, a map or a table is a map, and a set is a set. " ++
            "flags is a keyword of characters. `:t` writes a mutable array, table or buffer as #wattle/array, #wattle/table or #wattle/buffer. " ++
            "Raises an error for a mutable array, table or buffer without `:t`, for any other value edn has no text for, " ++
            "for NaN and the infinities, for a string that is not valid UTF-8, or if the nesting is too deep."),
    };
    corefn.install(env, entries);
}
