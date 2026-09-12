//! Rendering one Janet value as text: `toStringB` and `descriptionB`, the two
//! functions that wrap them into a string, and the escaping and number
//! formatting underneath.
//!
//! `toStringB` renders a value the way `(string x)` does and `descriptionB`
//! the way `(describe x)` does, both into a caller's buffer. `toString` and
//! `description` are the same two into a fresh scratch buffer, giving back an
//! interned string. `escapeString` is the quoting the pretty printer shares.
//!
//! Nothing here recurses into a container and nothing here lays anything out.
//! A tuple printed by `descriptionB` comes out as `<tuple 0x...>`; the layer
//! that walks it is `pp/pretty.zig`. That is the whole reason the seam is
//! here: this file settles what a value is called, and the next one settles
//! how a structure of them sits on a page. Only the second has a width, a
//! depth, a cycle table and a backtracking pass.
//!
//! ## Nothing in this file raises, and something can raise through it
//!
//! Not one of these functions raises in its own body, so none of them returns
//! `raise.Error`: converting a function that cannot raise buys a signature and
//! nothing else. What they do is call an abstract type's `tostring` callback,
//! which is a function pointer the runtime does not own and which may raise
//! through these frames. Nothing here is stranded when it does.
//!
//! The scratch buffer is released on every path. `description` and `toString`
//! initialise a `buffers.Buffer` on the stack and call the raise-capable
//! half through `raise.toAbi`, which catches, so `intern`, and the
//! `buffers.deinit` inside it, runs whether or not a `tostring` callback
//! raised. What a raise does leave is a report, which the caller of these two
//! must consume.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abstract_type = @import("../api/abstract_type.zig");
const buffers = @import("value/buffers.zig");
const c = @import("cabi");
const config = @import("config");
const constants = @import("constants");
const raise = @import("../api/raise.zig");
const registry = @import("registry.zig");
const repr = @import("repr");
const strings = @import("value/strings.zig");
const utils = @import("utils.zig");
const wrap = @import("value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The scratch a number or a pointer description is rendered into, and the
/// headroom reserved before rendering.
const bufsize = 64;

/// How many bytes of a pointer a description prints. A 64-bit build prints the
/// low six rather than all eight, because the top two are never significant on
/// any supported 64-bit target and dropping them keeps the description inside
/// `bufsize`.
const pointsize: usize = if (config.bits64) 6 else @sizeOf(?*anyopaque);

// ==========================================================================
// Public functions
// ==========================================================================

/// Renders `x` the way `(describe x)` does, as an interned string.
pub fn description(x: repr.Value) strings.String {
    var buffer: buffers.Buffer = undefined;
    _ = buffers.init(&buffer, 10);
    raise.toAbi(descriptionB(&buffer, x));
    return intern(&buffer);
}

/// Renders `x` the way `(describe x)` does, into `buffer`.
///
/// A container is not walked: it comes out as `<tuple 0x...>`. An abstract
/// with a `tostring` callback is rendered through it, inside angle brackets.
pub fn descriptionB(buffer: *buffers.Buffer, x: repr.Value) raise.Error!void {
    switch (repr.typeOf(x)) {
        repr.Tag.nil => return try buffers.pushCString(buffer, "nil"),
        repr.Tag.keyword => try buffers.pushU8(buffer, ':'),
        repr.Tag.string => return escapeStringB(buffer, wrap.toString(x)),
        repr.Tag.buffer => return escapeBufferB(buffer, wrap.toBuffer(x)),
        repr.Tag.abstract => {
            const p = wrap.toAbstract(x);
            const t = abstract_type.ofAbstract(p);
            if (t.tostring) |tostring| {
                try buffers.pushCString(buffer, "<");
                try buffers.pushBytes(buffer, t.name);
                try buffers.pushCString(buffer, " ");
                try tostring(p, @ptrCast(buffer));
                try buffers.pushCString(buffer, ">");
            } else {
                try stringDescriptionB(buffer, t.name, p);
            }
            return;
        },
        // A keyword has pushed its ':' and falls through to its bytes; every
        // other type is described exactly as it is stringified.
        else => {},
    }
    try toStringB(buffer, x);
}

/// Pushes `str` into `buffer` quoted and escaped, and returns how many columns
/// the escaped form occupies, which is what the pretty printer adds to its
/// alignment.
///
/// `pp/pretty.zig` calls this directly, as an import, and so does
/// `test/pp_describe.zig`. There is no abi beside it, and the width is why:
/// nothing else observes it, so a width consistently two too small would show
/// up only as slightly wrong wrapping in output no test compares. The contract
/// asserts it through this function and takes the error.
pub fn escapeString(buffer: *buffers.Buffer, str: []const u8) raise.Error!i32 {
    try buffers.pushU8(buffer, '"');
    var align_count: i32 = 1;
    for (str) |byte| {
        if (shortEscape(byte)) |escape| {
            try buffers.pushBytes(buffer, escape[0..2]);
            align_count += 2;
        } else if (byte < 32 or byte > 126) {
            const escape = [4]u8{ '\\', 'x', utils.base64[(byte >> 4) & 0xF], utils.base64[byte & 0xF] };
            try buffers.pushBytes(buffer, &escape);
            align_count += 4;
        } else {
            try buffers.pushU8(buffer, byte);
            align_count += 1;
        }
    }
    try buffers.pushU8(buffer, '"');
    return align_count + 1;
}

/// Renders `x` the way `(string x)` does, as an interned string.
///
/// The three byte-sequence types and a buffer give back their contents rather
/// than a printed form, and the first three of those need no rendering at all.
pub fn toString(x: repr.Value) strings.String {
    switch (repr.typeOf(x)) {
        repr.Tag.buffer => {
            const b = wrap.toBuffer(x);
            return strings.new(b.slice());
        },
        repr.Tag.string, repr.Tag.symbol, repr.Tag.keyword => return wrap.toString(x),
        else => {
            var buffer: buffers.Buffer = undefined;
            _ = buffers.init(&buffer, 10);
            raise.toAbi(toStringB(&buffer, x));
            return intern(&buffer);
        },
    }
}

/// Renders `x` the way `(string x)` does, into `buffer`.
pub fn toStringB(buffer: *buffers.Buffer, x: repr.Value) raise.Error!void {
    switch (repr.typeOf(x)) {
        repr.Tag.nil => try buffers.pushCString(buffer, ""),
        repr.Tag.boolean => try buffers.pushCString(
            buffer,
            if (wrap.toBoolean(x)) "true" else "false",
        ),
        repr.Tag.number => try numberToStringB(buffer, wrap.toNumber(x)),
        repr.Tag.string, repr.Tag.symbol, repr.Tag.keyword => {
            const str = wrap.toString(x);
            try buffers.pushBytes(buffer, str[0..strings.head(str).length]);
        },
        repr.Tag.buffer => {
            const to = wrap.toBuffer(x);
            // Reserve before pushing, so that appending a buffer to itself
            // cannot resize the storage the push is reading from.
            if (buffer == to) try buffers.extra(buffer, @intCast(to.count));
            try buffers.pushBytes(buffer, to.slice());
        },
        repr.Tag.abstract => {
            const p = wrap.toAbstract(x);
            const t = abstract_type.ofAbstract(p);
            if (t.tostring) |tostring| {
                // The slot takes `*abi.Render`; see `abi.zig`.
                try tostring(p, @ptrCast(buffer));
            } else {
                try stringDescriptionB(buffer, t.name, p);
            }
        },
        repr.Tag.cfunction => {
            const reg = registry.registryGet(wrap.toCfunction(x)) orelse
                return genericDescriptionB(buffer, x);
            try buffers.pushCString(buffer, "<cfunction ");
            if (reg.name_prefix) |prefix| {
                try buffers.pushCString(buffer, prefix);
                try buffers.pushU8(buffer, '/');
            }
            try buffers.pushCString(buffer, reg.name.?);
            try buffers.pushU8(buffer, '>');
        },
        repr.Tag.function => {
            const def = wrap.toFunction(x).def orelse
                return try buffers.pushCString(buffer, "<incomplete function>");
            const name = def.name orelse return genericDescriptionB(buffer, x);
            try buffers.pushCString(buffer, "<function ");
            try buffers.pushBytes(buffer, name[0..strings.head(name).length]);
            try buffers.pushU8(buffer, '>');
        },
        else => try genericDescriptionB(buffer, x),
    }
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Pushes `source`'s contents into `buffer` as a quoted buffer literal.
///
/// The length is read before the `@` marker is pushed, and that is what makes
/// a buffer describing itself describe what it had. Pushing first and then
/// escaping `source.slice()` escapes the `@` as well, because the push has
/// already moved `count` past it: `(buffer/format b "%v" b)` on a buffer of
/// `a` would give `a@"a@"`. The pretty printer keeps the same record under the
/// name `bufstartlen`.
fn escapeBufferB(buffer: *buffers.Buffer, source: *buffers.Buffer) raise.Error!void {
    const count: usize = @intCast(source.count);
    if (source == buffer) {
        // Reserve the worst case up front so that the buffer cannot resize
        // underneath the loop that is reading it.
        try buffers.ensure(source, source.count + 5 * source.count + 3, 1);
    }
    try buffers.pushU8(buffer, '@');
    _ = try escapeString(buffer, source.slice()[0..count]);
}

/// `escapeString` over a Janet string, discarding the width.
fn escapeStringB(buffer: *buffers.Buffer, str: strings.String) raise.Error!void {
    _ = try escapeString(buffer, str[0..strings.head(str).length]);
}

/// The `<type 0x...>` fallback, which three cases in `toStringB` reach: an
/// unregistered cfunction, a function with no name, and everything with no
/// case of its own.
fn genericDescriptionB(buffer: *buffers.Buffer, x: repr.Value) raise.Error!void {
    try stringDescriptionB(buffer, std.mem.span(utils.typeNames[@intFromEnum(repr.typeOf(x))]), wrap.toPointer(x));
}

/// One hex digit, from the shared alphabet.
inline fn hex(nibble: u8) u8 {
    return utils.base64[nibble];
}

/// Interns `buffer`'s contents and releases the buffer.
///
/// Both callers reach this after a `raise.toAbi`, which catches, so the
/// `buffers.deinit` here is reached on the raising path as well as the plain
/// one.
fn intern(buffer: *buffers.Buffer) strings.String {
    const ret = strings.new(buffer.slice());
    buffers.deinit(buffer);
    return ret;
}

/// Renders a number into `buffer`.
///
/// An integral value inside the exactly-representable range prints without an
/// exponent or a fraction; everything else gets `DBL_DIG` significant digits.
fn numberToStringB(buffer: *buffers.Buffer, x: f64) raise.Error!void {
    try buffers.ensure(buffer, buffer.count + bufsize, 2);
    const integral = x == @floor(x) and x <= constants.JANET_INTMAX_DOUBLE and x >= constants.JANET_INTMIN_DOUBLE;
    const format: [*:0]const u8 = if (integral) "%.0f" else "%.15g";
    if (x == 0.0) {
        // Print '0' rather than letting the formatter render '-0'.
        buffer.appendAssumingCapacity('0');
        return;
    }
    const room = buffer.spare();
    buffer.count += @intCast(c.snprintf(room.ptr, bufsize, format, x));
}

/// The two-byte escape a byte gets, or nothing where it needs none of them.
fn shortEscape(byte: u8) ?*const [2]u8 {
    return switch (byte) {
        '"' => "\\\"",
        '\n' => "\\n",
        '\r' => "\\r",
        0 => "\\0",
        // Zig has no '\f' or '\v' literal; these are the C ones.
        0x0C => "\\f",
        0x0B => "\\v",
        0x07 => "\\a",
        0x08 => "\\b",
        27 => "\\e",
        '\\' => "\\\\",
        '\t' => "\\t",
        else => null,
    };
}

/// Pushes `<title 0xHEXHEX...>` into `buffer`, with the title truncated to 32
/// bytes so that the whole thing fits the `bufsize` reservation.
fn stringDescriptionB(buffer: *buffers.Buffer, title: []const u8, pointer: ?*const anyopaque) raise.Error!void {
    try buffers.ensure(buffer, buffer.count + bufsize, 2);
    const bytes: [@sizeOf(?*const anyopaque)]u8 = @bitCast(@intFromPtr(pointer));
    var at = buffer.data.? + @as(usize, @intCast(buffer.count));

    at[0] = '<';
    at += 1;
    var i: usize = 0;
    while (i < 32 and i < title.len) : (i += 1) {
        at[0] = title[i];
        at += 1;
    }
    at[0] = ' ';
    at[1] = '0';
    at[2] = 'x';
    at += 3;

    // The C reads the pointer back through a `uint8_t[sizeof(void *)]` union
    // member, which is memory order; `@bitCast` of the address gives the same
    // bytes. Printing walks down from the most significant of the six.
    // The address is read back as bytes with `@bitCast`, which is memory
    // order. Printing walks down from the most significant of the six.
    var byte_index = pointsize;
    while (byte_index > 0) : (byte_index -= 1) {
        const byte = bytes[byte_index - 1];
        at[0] = hex(byte >> 4);
        at[1] = hex(byte & 0xF);
        at += 2;
    }
    at[0] = '>';
    at += 1;
    buffer.count = @intCast(at - buffer.data.?);
}
