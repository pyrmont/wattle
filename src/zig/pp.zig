//! Rendering one Janet value as text: `toStringB` and `descriptionB`, the two
//! functions that wrap them into a string, and the escaping and number
//! formatting underneath.
//!
//! Nothing here recurses into a container and nothing here lays anything out.
//! A tuple printed by `descriptionB` comes out as `<tuple 0x...>`; the layer
//! that walks it is `pp/pretty.zig`. That is the whole reason the seam is
//! here: this file answers "what is this value called", the next one answers
//! "how does a structure of them sit on a page", and only the second has a
//! width, a depth, a cycle table and a backtracking pass.
//!
//! ## Nothing in this file raises, and something can raise through it
//!
//! Not one of these functions raises in its own body, so none of them returns
//! `raise.Error`: converting a function that cannot raise buys a signature and
//! nothing else. What they *do* is call an abstract type's `tostring`
//! callback, which is a function pointer the runtime does not own and which
//! may raise through these frames. So nothing here holds anything.
//!
//! That costs something real and it is reproduced rather than introduced.
//! `janet_description` and `janet_to_string` initialise a `JanetBuffer` on the
//! stack and deinitialise it after rendering; a panic out of a `tostring`
//! callback strands that buffer's allocation. The C original strands it in
//! exactly the same place. It closes when abstract callbacks stop jumping, not
//! here.

const std = @import("std");
const repr = @import("repr");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise.zig");
const abstract_type = @import("abstract_type.zig");
const config = @import("config");
const buffers = @import("value/buffers.zig");
const strings = @import("value/strings.zig");
const wrap = @import("value/helpers/wrap.zig");
const utils = @import("utils.zig");
const registry = @import("registry.zig");

/// The scratch a number or a pointer description is rendered into, and the
/// headroom reserved before rendering.
const bufsize = 64;

/// A 64-bit build prints the low six bytes of a pointer rather
/// than all eight, because the top two are never significant on any supported
/// 64-bit target and dropping them keeps the description inside `bufsize`.
const pointsize: usize = if (config.bits64) 6 else @sizeOf(?*anyopaque);

/// One hex digit, from the shared alphabet.
inline fn hex(nibble: u8) u8 {
    return utils.base64[nibble];
}

// ------------------------------------------------------------------ numbers

/// Render a number into a buffer. Integral values inside the exactly-representable
/// range print without an exponent or a fraction; everything else gets
/// `DBL_DIG` significant digits.
fn numberToStringB(buffer: *buffers.Buffer, x: f64) raise.Raising(void) {
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

// ------------------------------------------------------------------ pointers

/// `string_description_b`. `<title 0xHEXHEX...>`, with the title truncated to
/// 32 bytes so that the whole thing fits the `bufsize` reservation.
fn stringDescriptionB(buffer: *buffers.Buffer, title: []const u8, pointer: ?*const anyopaque) raise.Raising(void) {
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

// ------------------------------------------------------------------ escaping

/// The two-byte escape a byte gets, or nothing if it needs none of them.
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

/// `janet_escape_string_impl`. Returns the number of columns the escaped form
/// occupies, which is what the pretty printer adds to its alignment.
///
/// `pp/pretty.zig` calls this directly, as an import, and so does
/// `test/pp_describe.zig`. **There is no abi beside it**: one existed for a C
/// caller and outlived it by one contract, which asserted the returned width
/// because nothing else observes it -- a width consistently two too small
/// would show up only as slightly wrong wrapping in output no test compares.
/// The contract asserts the same thing through this function and takes the
/// error.
pub fn escapeString(buffer: *buffers.Buffer, str: []const u8) raise.Raising(i32) {
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

fn escapeStringB(buffer: *buffers.Buffer, str: strings.String) raise.Raising(void) {
    _ = try escapeString(buffer, str[0..strings.head(str).length]);
}

fn escapeBufferB(buffer: *buffers.Buffer, source: *buffers.Buffer) raise.Raising(void) {
    if (source == buffer) {
        // Reserve the worst case up front so that the buffer cannot resize
        // underneath the loop that is reading it.
        try buffers.ensure(source, source.count + 5 * source.count + 3, 1);
    }
    try buffers.pushU8(buffer, '@');
    _ = try escapeString(buffer, source.slice());
}

// ---------------------------------------------------------------- to_string

/// The `<type 0x...>` fallback, which three cases in `toStringB` reach: an
/// unregistered cfunction, a function with no name, and everything with no
/// case of its own. In C the first two arrive by `goto fallthrough`.
fn genericDescriptionB(buffer: *buffers.Buffer, x: repr.Value) raise.Raising(void) {
    try stringDescriptionB(buffer, std.mem.span(utils.typeNames[@intFromEnum(repr.typeOf(x))]), wrap.toPointer(x));
}

pub fn toStringB(buffer: *buffers.Buffer, x: repr.Value) raise.Raising(void) {
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
                // The slot takes `abi.Buffer`; see `abi.zig`.
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

// -------------------------------------------------------------- description

pub fn descriptionB(buffer: *buffers.Buffer, x: repr.Value) raise.Raising(void) {
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

/// Render into a scratch buffer and hand back an interned string. The buffer
/// is deinitialised on the way out and stranded if a `tostring` callback
/// panics, which is what the C does.
fn intern(buffer: *buffers.Buffer) strings.String {
    const ret = strings.new(buffer.slice());
    buffers.deinit(buffer);
    return ret;
}

pub fn description(x: repr.Value) strings.String {
    var buffer: buffers.Buffer = undefined;
    _ = buffers.init(&buffer, 10);
    raise.reported(descriptionB(&buffer, x));
    return intern(&buffer);
}

/// Like `janet_description`, except that the three byte-sequence types and a
/// buffer answer with their contents rather than with a printed form — and the
/// first three of those need no rendering at all.
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
            raise.reported(toStringB(&buffer, x));
            return intern(&buffer);
        },
    }
}
