//! The `json/` library: `json/decode`, `json/encode` and `json/null`.
//!
//! `env.zig`'s `loadLibs` calls `libJson` in every configuration. The decoder
//! reads tokens from `std.json.Scanner`, which checks the grammar, the UTF-8
//! of every string and the pairing of surrogate escapes. The encoder writes
//! its text directly.
//!
//! ## What each side refuses
//!
//! Decoding raises where the text has no Wattle value, and encoding raises
//! where the value has no JSON text. The flags relax two of those rules:
//!
//! - `:n` decodes `null` as nil and encodes nil as `null`. Without it, `null`
//!   is `json/null` and nil raises, because a map cannot hold nil and an
//!   object member would otherwise be dropped.
//!
//! - `:s` encodes a buffer, a keyword or a symbol as a string. Without it
//!   each raises, because the decoder returns a string in its place.
//!
//! - An integer written without a fraction or an exponent must be exactly
//!   representable as a double. A number with a fraction or an exponent is
//!   rounded. Either raises where it is out of range.
//!
//! - The encoder writes an integral number up to 2^53 without a fraction, and
//!   any number above 2^53 with an exponent, so that the decoder reads
//!   back every number the encoder writes.
//!
//! ## The null value
//!
//! `json/null` is the one instance of an abstract type, created once per VM
//! and kept in `Vm.json_null` as a root. Its `unmarshal` callback returns
//! that instance rather than a new one, so it survives `marshal` and a
//! thread boundary as the same value.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstract_type = @import("../api/abstract_type.zig");
const abstracts = @import("value/abstracts.zig");
const args_core = @import("args.zig");
const buffers = @import("value/buffers.zig");
const config = @import("config");
const corefn = @import("corefn.zig");
const fatal = @import("fatal.zig");
const gc_alloc = @import("gc.zig");
const maps = @import("value/maps.zig");
const marsh = @import("marsh.zig");
const pp_format = @import("pp/format.zig");
const raise = @import("../api/raise.zig");
const registry = @import("registry.zig");
const repr = @import("repr");
const scratch_vector = @import("scratch_vector.zig");
const strings = @import("value/strings.zig");
const tables = @import("value/tables.zig");
const value = @import("value.zig");
const vectors = @import("value/vectors.zig");
const vm_state = @import("vm/state.zig");
const wrap = @import("value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The largest magnitude below which every integer is a double.
const max_exact: f64 = 9007199254740992.0;

/// The abstract type of `json/null`.
pub const null_type = abstract_type.define(Null, .{
    .name = "json/null",
    .tostring = &nullTostring,
    .marshal = &nullMarshal,
    .unmarshal = &nullUnmarshal,
});

// ==========================================================================
// Types
// ==========================================================================

/// The state of one `json/decode` call.
///
/// `scanner` reads `json/decode`'s argument, and `diagnostics` is where it
/// records the line and column of a syntax error. `as_nil` is the `:n` flag,
/// and `depth` counts the arrays and objects open.
const Decoder = struct {
    scanner: std.json.Scanner,
    diagnostics: std.json.Diagnostics = .{},
    as_nil: bool,
    depth: i32 = 0,

    /// Returns the next token, raising where the scanner refuses the text.
    ///
    /// A string with an escape comes back as `.allocated_string`, on the
    /// scratch heap, and the caller frees it with `release`.
    fn next(self: *Decoder) raise.Error!std.json.Token {
        return self.scanner.nextAllocMax(
            gc_alloc.scratch_heap,
            .alloc_if_needed,
            std.math.maxInt(usize),
        ) catch |err| switch (err) {
            error.UnexpectedEndOfInput => raise.panic("unexpected end of JSON text"),
            error.SyntaxError => pp_format.panicf("invalid JSON at line %d, column %d", .{
                @as(i64, @intCast(self.diagnostics.getLine())),
                @as(i64, @intCast(self.diagnostics.getColumn())),
            }),
            error.OutOfMemory => fatal.outOfMemory(),
            // The limit passed above is the largest length there is.
            error.ValueTooLong => unreachable,
        };
    }

    /// Returns the value that begins with `token`.
    ///
    /// This function raises where the text or a number in it is refused, or
    /// where the nesting is deeper than `config.recursion_guard`.
    fn decode(self: *Decoder, token: std.json.Token) raise.Error!repr.Value {
        return switch (token) {
            .object_begin => self.object(),
            .array_begin => self.array(),
            .true => wrap.fromTrue(),
            .false => wrap.fromFalse(),
            .null => if (self.as_nil) wrap.fromNil() else nullValue(),
            .number => |bytes| decodeNumber(bytes),
            .allocated_number => |bytes| {
                defer gc_alloc.scratch_heap.free(bytes);
                return decodeNumber(bytes);
            },
            .string, .allocated_string => try decodeString(token),
            // The scanner returns an end token only after a begin token, and
            // `array` and `object` read those themselves. The refusal
            // depends on `std.json`, so it raises.
            else => unexpectedToken(),
        };
    }

    /// Returns the vector of the elements up to the next `]`.
    fn array(self: *Decoder) raise.Error!repr.Value {
        try enter(&self.depth);
        var items: scratch_vector.Vector(repr.Value) = .empty;
        defer scratch_vector.free(&items);
        while (true) {
            const token = try self.next();
            if (token == .array_end) break;
            scratch_vector.push(&items, try self.decode(token));
        }
        self.depth -= 1;
        return wrap.fromVector(vectors.fromSlice(items.items));
    }

    /// Returns the map of the members up to the next `}`.
    ///
    /// `maps.build` keeps the last value of a repeated key, and removes a key
    /// whose last value is nil, which is how `:n` drops a `null` member.
    fn object(self: *Decoder) raise.Error!repr.Value {
        try enter(&self.depth);
        var entries: scratch_vector.Vector(repr.Value) = .empty;
        defer scratch_vector.free(&entries);
        while (true) {
            const token = try self.next();
            if (token == .object_end) break;
            scratch_vector.push(&entries, try decodeString(token));
            scratch_vector.push(&entries, try self.decode(try self.next()));
        }
        self.depth -= 1;
        return wrap.fromMap(maps.build(.map, entries.items));
    }
};

/// The state of one `json/encode` call.
///
/// `out` is the text written so far. `as_null` and `as_string` are the `:n`
/// and `:s` flags, and `depth` counts the arrays and objects open.
const Encoder = struct {
    out: scratch_vector.Vector(u8) = .empty,
    as_null: bool,
    as_string: bool,
    depth: i32 = 0,

    /// Appends `bytes` to the text.
    fn push(self: *Encoder, bytes: []const u8) void {
        self.out.appendSlice(gc_alloc.scratch_heap, bytes) catch fatal.outOfMemory();
    }

    /// Writes `x`.
    ///
    /// This function raises where `x`, or a value inside it, has no JSON
    /// text under the flags, or where the nesting is deeper than
    /// `config.recursion_guard`.
    fn encode(self: *Encoder, x: repr.Value) raise.Error!void {
        switch (repr.typeOf(x)) {
            repr.Tag.nil => {
                if (!self.as_null) return raise.panic("cannot encode nil as JSON without the :n flag");
                self.push("null");
            },
            repr.Tag.boolean => self.push(if (wrap.toBoolean(x)) "true" else "false"),
            repr.Tag.number => try self.number(wrap.toNumber(x)),
            repr.Tag.string => try self.string(strings.bytesOf(wrap.toString(x))),
            repr.Tag.buffer, repr.Tag.symbol => {
                if (!self.as_string) {
                    return pp_format.panicf("cannot encode %v as JSON without the :s flag", .{x});
                }
                try self.string(textOf(x));
            },
            repr.Tag.array, repr.Tag.tuple, repr.Tag.vector => try self.array(x),
            repr.Tag.table, repr.Tag.map => try self.object(x),
            repr.Tag.abstract => {
                if (!isNull(x)) return pp_format.panicf("cannot encode %v as JSON", .{x});
                self.push("null");
            },
            else => return pp_format.panicf("cannot encode %v as JSON", .{x}),
        }
    }

    /// Writes the elements of `x`, an array, a tuple or a vector.
    fn array(self: *Encoder, x: repr.Value) raise.Error!void {
        try enter(&self.depth);
        self.push("[");
        var runs = (try args_core.chunks(x)).?;
        var first = true;
        while (try runs.next()) |run| {
            for (run) |element| {
                if (!first) self.push(",");
                first = false;
                try self.encode(element);
            }
        }
        self.push("]");
        self.depth -= 1;
    }

    /// Writes the entries of `x`, a table or a map, in its iteration order.
    fn object(self: *Encoder, x: repr.Value) raise.Error!void {
        try enter(&self.depth);
        self.push("{");
        var pairs = (try args_core.keyvals(x)).?;
        var first = true;
        while (try pairs.next()) |kv| {
            if (!first) self.push(",");
            first = false;
            try self.key(kv.key);
            self.push(":");
            try self.encode(kv.value);
        }
        self.push("}");
        self.depth -= 1;
    }

    /// Writes `x` as an object key.
    ///
    /// This function raises where `x` is not a string, or not a buffer, a
    /// keyword or a symbol under `:s`.
    fn key(self: *Encoder, x: repr.Value) raise.Error!void {
        switch (repr.typeOf(x)) {
            repr.Tag.string => try self.string(strings.bytesOf(wrap.toString(x))),
            repr.Tag.buffer, repr.Tag.symbol => {
                if (!self.as_string) {
                    return pp_format.panicf("cannot use %v as a JSON object key without the :s flag", .{x});
                }
                try self.string(textOf(x));
            },
            else => return pp_format.panicf("cannot use %v as a JSON object key", .{x}),
        }
    }

    /// Writes `x`.
    ///
    /// This function raises where `x` is NaN or an infinity. An integral
    /// value up to 2^53 is written without a fraction, and `-0` keeps its
    /// sign. A value above 2^53, or below 10^-6, is written with an
    /// exponent: the decoder refuses an integer it cannot represent exactly,
    /// and most integers above 2^53 written out in full are such integers.
    fn number(self: *Encoder, x: f64) raise.Error!void {
        if (!std.math.isFinite(x)) return pp_format.panicf("cannot encode %v as JSON", .{wrap.fromNumber(x)});
        var buf: [64]u8 = undefined;
        const magnitude = @abs(x);
        const text = if (x == 0 and std.math.signbit(x))
            "-0"
        else if (x == @trunc(x) and magnitude <= max_exact)
            std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(x))}) catch unreachable
        else if (magnitude > max_exact or magnitude < 1e-6)
            std.fmt.bufPrint(&buf, "{e}", .{x}) catch unreachable
        else
            std.fmt.bufPrint(&buf, "{d}", .{x}) catch unreachable;
        self.push(text);
    }

    /// Writes `bytes` as a JSON string.
    ///
    /// This function raises where `bytes` is not valid UTF-8. A quote, a
    /// backslash and each control character are escaped, and every other
    /// byte is written as it is.
    fn string(self: *Encoder, bytes: []const u8) raise.Error!void {
        if (!std.unicode.utf8ValidateSlice(bytes)) {
            return raise.panic("cannot encode a string that is not valid UTF-8 as JSON");
        }
        self.push("\"");
        var start: usize = 0;
        for (bytes, 0..) |byte, index| {
            const escape: []const u8 = switch (byte) {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                0x08 => "\\b",
                0x0C => "\\f",
                0x00...0x07, 0x0B, 0x0E...0x1F => "",
                else => continue,
            };
            self.push(bytes[start..index]);
            start = index + 1;
            if (escape.len != 0) {
                self.push(escape);
            } else {
                var hex: [6]u8 = undefined;
                self.push(std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{byte}) catch unreachable);
            }
        }
        self.push(bytes[start..]);
        self.push("\"");
    }
};

/// The payload of `json/null`, which nothing reads.
const Null = struct {
    unused: u8,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Checks whether `x` is `json/null`.
///
/// This function cannot raise.
pub fn isNull(x: repr.Value) bool {
    if (!repr.checkType(x, repr.Tag.abstract)) return false;
    return abstract_type.ofAbstract(wrap.toAbstract(x)) == &null_type;
}

/// Installs `json/decode`, `json/encode` and `json/null` into the core
/// environment and registers `json/null`'s type.
///
/// `env` is the environment. This function raises if the registration does.
pub fn libJson(env: *tables.Table) raise.Error!void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("json/decode", &nfunDecode, @src(), "(json/decode x)\n(json/decode x flags)", "Decodes x, a string or a buffer of JSON text. " ++
            "An array is a vector, an object is a map with string keys, and null is ^json/null. " ++
            "flags is a keyword of characters. `:n` decodes null as nil, and an object member whose value is null is then absent. " ++
            "Raises an error if x is not JSON, if an integer written without a fraction or an exponent is not exactly a number, " ++
            "if a number is out of range, or if the nesting is too deep."),
        corefn.reg("json/encode", &nfunEncode, @src(), "(json/encode x)\n(json/encode x flags)", "Encodes x as JSON text and returns a string. " ++
            "A vector, a tuple or an array is an array, a map or a table is an object with string keys, and ^json/null is null. " ++
            "flags is a keyword of characters. `:n` encodes nil as null, and `:s` encodes a buffer, a keyword or a symbol as a string, as a key or as a value. " ++
            "Raises an error for any other value, for NaN and the infinities, for a string that is not valid UTF-8, " ++
            "or if the nesting is too deep."),
    };
    corefn.install(env, entries);
    try registry.registerAbstractType(&null_type);
    corefn.def(env, "json/null", nullValue(), @src(), "The value ^json/decode returns for a JSON null, and that ^json/encode writes as null.");
}

/// Returns `json/null`, creating and rooting it on the first call in a VM.
///
/// This function cannot raise.
pub fn nullValue() repr.Value {
    const vm = vm_state.current();
    if (vm.json_null) |p| return wrap.fromAbstract(p);
    const p = abstracts.newBytes(&null_type, @sizeOf(Null));
    vm.json_null = p;
    gc_alloc.gcroot(wrap.fromAbstract(p));
    return wrap.fromAbstract(p);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Returns the number `bytes` spells.
///
/// This function raises where the number is out of range, or where `bytes`
/// has no fraction and no exponent and is not an integer a double
/// represents exactly.
fn decodeNumber(bytes: []const u8) raise.Error!repr.Value {
    // The scanner has checked the grammar, which `parseFloat` accepts, and the
    // refusal depends on the two agreeing. `parseFloat` rounds correctly,
    // which `scan.scanNumber` does not always do, and the encoder writes the
    // shortest text that reads back under correct rounding.
    const x = std.fmt.parseFloat(f64, bytes) catch
        return pp_format.panicf("invalid JSON number %S", .{strings.new(bytes)});
    if (std.math.isInf(x)) {
        return pp_format.panicf("JSON number %S is out of range", .{strings.new(bytes)});
    }
    const integer = std.mem.findAny(u8, bytes, ".eE") == null;
    const digits = if (bytes[0] == '-') bytes[1..] else bytes;
    if (integer and !exactInteger(digits, @abs(x))) {
        return pp_format.panicf("JSON integer %S is not exactly a number", .{strings.new(bytes)});
    }
    return wrap.fromNumber(x);
}

/// Returns the string of `token`, a `.string` or an `.allocated_string`, and
/// frees the allocation.
///
/// This function raises if `token` is any other token, which the scanner does
/// not return where a string is expected.
fn decodeString(token: std.json.Token) raise.Error!repr.Value {
    return switch (token) {
        .string => |bytes| value.fromBytes(bytes, .string),
        .allocated_string => |bytes| {
            defer gc_alloc.scratch_heap.free(bytes);
            return value.fromBytes(bytes, .string);
        },
        // An object key is a string token, which the scanner checks.
        else => unexpectedToken(),
    };
}

/// Counts one more array or object open, and raises where that is deeper
/// than `config.recursion_guard`.
fn enter(depth: *i32) raise.Error!void {
    depth.* += 1;
    if (depth.* > config.recursion_guard) {
        return pp_format.panicf("JSON nesting is deeper than %d levels", .{@as(i64, config.recursion_guard)});
    }
}

/// Checks whether `digits`, the decimal digits of an integer, spell exactly
/// `magnitude`, the double they were read as.
///
/// `magnitude` must be finite and not negative. Fifteen digits are below
/// 2^53, where every integer is a double. Past that, the double's exact value
/// is built in decimal, as its significand doubled once for each power of two
/// in its exponent, and compared digit by digit. JSON writes no leading zero
/// before another digit, so equal values have equal digits.
fn exactInteger(digits: []const u8, magnitude: f64) bool {
    if (digits.len <= 15) return true;
    // A value of 10^15 or more is normal. Its significand is `m` times two to
    // the `e`, and `e` is not negative once the zero bits `m` ends in are
    // moved into it, because the value is an integer.
    const bits: u64 = @bitCast(magnitude);
    var m: u64 = (bits & ((1 << 52) - 1)) | (1 << 52);
    var e: i32 = @as(i32, @intCast(bits >> 52)) - 1075;
    while (e < 0) : (e += 1) m >>= 1;

    // The digits of `m`, least significant first, then doubled `e` times. The
    // largest double has 309 digits.
    var decimal: [309]u8 = undefined;
    var len: usize = 0;
    while (m != 0) : (m /= 10) {
        decimal[len] = @intCast(m % 10);
        len += 1;
    }
    while (e > 0) : (e -= 1) {
        var carry: u8 = 0;
        for (decimal[0..len]) |*digit| {
            const doubled = digit.* * 2 + carry;
            digit.* = doubled % 10;
            carry = doubled / 10;
        }
        if (carry != 0) {
            decimal[len] = carry;
            len += 1;
        }
    }

    if (len != digits.len) return false;
    for (digits, 0..) |ch, index| {
        if (ch - '0' != decimal[len - 1 - index]) return false;
    }
    return true;
}

/// `(json/decode x [flags])`.
fn nfunDecode(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    const view = try args_core.getBytes(argv, 0);
    const flags = if (argv.len > 1) try args_core.getFlags(argv, 1, "n") else 0;
    const bytes: []const u8 = if (view.bytes) |p| p[0..view.len] else &.{};
    var decoder: Decoder = .{
        .scanner = .initCompleteInput(gc_alloc.scratch_heap, bytes),
        .as_nil = flags & 1 != 0,
    };
    defer decoder.scanner.deinit();
    decoder.scanner.enableDiagnostics(&decoder.diagnostics);
    const result = try decoder.decode(try decoder.next());
    // The scanner refuses anything after the value but whitespace.
    if (try decoder.next() != .end_of_document) return unexpectedToken();
    return result;
}

/// `(json/encode x [flags])`.
fn nfunEncode(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    const flags = if (argv.len > 1) try args_core.getFlags(argv, 1, "ns") else 0;
    var encoder: Encoder = .{
        .as_null = flags & 1 != 0,
        .as_string = flags & 2 != 0,
    };
    defer scratch_vector.free(&encoder.out);
    try encoder.encode(argv[0]);
    return value.fromBytes(encoder.out.items, .string);
}

/// Writes nothing beyond the type's name, which is all `nullUnmarshal` reads.
fn nullMarshal(p: *Null, m: *abi.Marshal) raise.Error!void {
    marsh.marshalAbstract(m, p);
}

/// Writes `json/null`'s name, which is how `string` prints it.
fn nullTostring(_: *Null, render: *abi.Render) raise.Error!void {
    const buffer: *buffers.Buffer = @ptrCast(@alignCast(render));
    try buffers.pushCString(buffer, "json/null");
}

/// Returns this VM's `json/null` and enters it in the reference table.
fn nullUnmarshal(u: *abi.Unmarshal) raise.Error!*Null {
    const x = nullValue();
    try marsh.unmarshalAbstractReuse(u, wrap.toAbstract(x));
    return @ptrCast(@alignCast(wrap.toAbstract(x)));
}

/// Returns the bytes of `x`, a buffer, a keyword or a symbol.
fn textOf(x: repr.Value) []const u8 {
    if (repr.checkType(x, repr.Tag.buffer)) return wrap.toBuffer(x).slice();
    return strings.bytesOf(wrap.toSymbol(x));
}

/// Raises for a token the scanner returned where its grammar allows none.
fn unexpectedToken() raise.Error {
    return raise.panic("unexpected JSON token");
}
