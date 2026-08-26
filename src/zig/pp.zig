//! Rendering one Janet value as text, which is the leaf of `pp.c`'s three
//! layers: `janet_to_string_b` and `janet_description_b`, the two functions
//! that wrap them into a `JanetString`, and the escaping and number formatting
//! underneath.
//!
//! Nothing here recurses into a container and nothing here lays anything out.
//! A tuple printed by `janet_description_b` comes out as `<tuple 0x...>`; the
//! layer that walks it is `pp_pretty.zig`. That is the whole reason the seam is
//! here: this file answers "what is this value called", the next one answers
//! "how does a structure of them sit on a page", and only the second has a
//! width, a depth, a cycle table and a backtracking pass.
//!
//! ## Nothing in this file raises, and it is still jump-transparent
//!
//! Not one of these functions panics in its own body, so none of them returns
//! `raise.Error` — Phase 10 Part 2's rule is that converting a function which
//! cannot raise buys a signature and nothing else. What they *do* is call an
//! abstract type's `tostring` callback, which is a C function pointer supplied
//! by `abstract.c` or by a native module and which may panic through these
//! frames. So the marker is here and `build.zig` rejects `defer`.
//!
//! That costs something real and it is reproduced rather than introduced.
//! `janet_description` and `janet_to_string` initialise a `JanetBuffer` on the
//! stack and deinitialise it after rendering; a panic out of a `tostring`
//! callback strands that buffer's allocation. The C original strands it in
//! exactly the same place. It closes when abstract callbacks stop jumping, not
//! here.

const std = @import("std");
const options = @import("options");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const abstract_type = @import("abstract_type.zig");
const config = @import("config");
const buffers = @import("value/buffers.zig");
const strings = @import("value/strings.zig");
const kind = @import("value/helpers/kind.zig");
const wrap = @import("value/helpers/wrap.zig");
const utils = @import("utils.zig");

/// `BUFSIZE` in `src/core/pp.c`: the scratch a number or a pointer
/// description is rendered into, and the headroom reserved before rendering.
const bufsize = 64;

/// `POINTSIZE`. A 64-bit build prints the low six bytes of a pointer rather
/// than all eight, because the top two are never significant on any supported
/// 64-bit target and dropping them keeps the description inside `bufsize`.
const pointsize: usize = if (config.bits64) 6 else @sizeOf(?*anyopaque);

extern fn snprintf(buffer: [*]u8, size: usize, format: [*:0]const u8, ...) callconv(.c) c_int;

/// `src/core/util.h`, declared here rather than in `cabi.zig`.
extern const janet_base64: [65]u8;
extern fn janet_registry_get(key: types.JanetCFunction) callconv(.c) ?*types.JanetCFunRegistry;

inline fn hex(nibble: u8) u8 {
    return janet_base64[nibble];
}

// ------------------------------------------------------------------ numbers

/// `number_to_string_b`. Integral values inside the exactly-representable
/// range print without an exponent or a fraction; everything else gets
/// `DBL_DIG` significant digits.
fn numberToStringB(buffer: *types.JanetBuffer, x: f64) raise.Raising(void) {
    try buffers.ensure(buffer, buffer.count + bufsize, 2);
    const integral = x == @floor(x) and x <= constants.JANET_INTMAX_DOUBLE and x >= constants.JANET_INTMIN_DOUBLE;
    const format: [*:0]const u8 = if (integral) "%.0f" else "%.15g";
    var count: c_int = undefined;
    if (x == 0.0) {
        // Print '0' rather than letting the formatter render '-0'.
        count = 1;
        buffer.data.?[@intCast(buffer.count)] = '0';
    } else {
        count = snprintf(buffer.data.? + @as(usize, @intCast(buffer.count)), bufsize, format, x);
    }
    buffer.count += count;
}

// ------------------------------------------------------------------ pointers

/// `string_description_b`. `<title 0xHEXHEX...>`, with the title truncated to
/// 32 bytes so that the whole thing fits the `bufsize` reservation.
fn stringDescriptionB(buffer: *types.JanetBuffer, title: [*]const u8, pointer: ?*const anyopaque) raise.Raising(void) {
    try buffers.ensure(buffer, buffer.count + bufsize, 2);
    const bytes: [@sizeOf(?*const anyopaque)]u8 = @bitCast(@intFromPtr(pointer));
    var at = buffer.data.? + @as(usize, @intCast(buffer.count));

    at[0] = '<';
    at += 1;
    var i: usize = 0;
    while (i < 32 and title[i] != 0) : (i += 1) {
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
/// `pp_pretty.zig` calls this directly, as an import rather than across the C
/// ABI, and since Phase 11 Part 5 so does `test/pp_describe.zig`. **The abi
/// that stood beside this is gone**: `janet_zig_pp_escape_string` existed for
/// `pp.c` under the other selector and outlived it by one caller, the C
/// contract, which asserted the returned width because nothing else observes
/// it — a width consistently two too small would show up only as slightly
/// wrong wrapping in output no test compares. The Zig contract asserts the
/// same thing through this function and takes the error, so the abi and its
/// `@export` have no callers left.
pub fn escapeStringImpl(buffer: *types.JanetBuffer, str: []const u8) raise.Raising(i32) {
    try buffers.pushU8(buffer, '"');
    var align_count: i32 = 1;
    for (str) |byte| {
        if (shortEscape(byte)) |escape| {
            try buffers.pushBytes(buffer, escape[0..2]);
            align_count += 2;
        } else if (byte < 32 or byte > 126) {
            const escape = [4]u8{ '\\', 'x', janet_base64[(byte >> 4) & 0xF], janet_base64[byte & 0xF] };
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

fn escapeStringB(buffer: *types.JanetBuffer, str: types.JanetString) raise.Raising(void) {
    _ = try escapeStringImpl(buffer, str[0..@intCast(types.stringHead(str).length)]);
}

fn escapeBufferB(buffer: *types.JanetBuffer, source: *types.JanetBuffer) raise.Raising(void) {
    if (source == buffer) {
        // Reserve the worst case up front so that the buffer cannot resize
        // underneath the loop that is reading it.
        try buffers.ensure(source, source.count + 5 * source.count + 3, 1);
    }
    try buffers.pushU8(buffer, '@');
    _ = try escapeStringImpl(buffer, source.data.?[0..@intCast(source.count)]);
}

// ---------------------------------------------------------------- to_string

/// The `<type 0x...>` fallback, which three cases in `toStringB` reach: an
/// unregistered cfunction, a function with no name, and everything with no
/// case of its own. In C the first two arrive by `goto fallthrough`.
fn genericDescriptionB(buffer: *types.JanetBuffer, x: types.Janet) raise.Raising(void) {
    try stringDescriptionB(buffer, utils.typeNames[kind.typeOf(x)], wrap.toPointer(x));
}

pub fn toStringB(buffer: *types.JanetBuffer, x: types.Janet) raise.Raising(void) {
    switch (kind.typeOf(x)) {
        constants.JANET_NIL => try buffers.pushCString(buffer, ""),
        constants.JANET_BOOLEAN => try buffers.pushCString(
            buffer,
            if (wrap.toBoolean(x) != 0) "true" else "false",
        ),
        constants.JANET_NUMBER => try numberToStringB(buffer, wrap.toNumber(x)),
        constants.JANET_STRING, constants.JANET_SYMBOL, constants.JANET_KEYWORD => {
            const str = wrap.toString(x);
            try buffers.pushBytes(buffer, str[0..@intCast(types.stringHead(str).length)]);
        },
        constants.JANET_BUFFER => {
            const to = wrap.toBuffer(x);
            // Reserve before pushing, so that appending a buffer to itself
            // cannot resize the storage the push is reading from.
            if (buffer == to) try buffers.extra(buffer, to.*.count);
            try buffers.pushBytes(buffer, to.*.data.?[0..@intCast(to.*.count)]);
        },
        constants.JANET_ABSTRACT => {
            const p = wrap.toAbstract(x);
            const t = abstract_type.ofAbstract(p);
            if (t.*.tostring) |tostring| {
                try tostring(p, buffer);
            } else {
                try stringDescriptionB(buffer, t.*.name, p);
            }
        },
        constants.JANET_CFUNCTION => {
            const reg = janet_registry_get(wrap.toCfunction(x));
            if (reg == null) return genericDescriptionB(buffer, x);
            try buffers.pushCString(buffer, "<cfunction ");
            if (reg.?.name_prefix != null) {
                try buffers.pushCString(buffer, reg.?.name_prefix.?);
                try buffers.pushU8(buffer, '/');
            }
            try buffers.pushCString(buffer, reg.?.name.?);
            try buffers.pushU8(buffer, '>');
        },
        constants.JANET_FUNCTION => {
            const def = wrap.toFunction(x).*.def orelse
                return try buffers.pushCString(buffer, "<incomplete function>");
            if (def.name == null) return genericDescriptionB(buffer, x);
            const name = def.name.?;
            try buffers.pushCString(buffer, "<function ");
            try buffers.pushBytes(buffer, name[0..@intCast(types.stringHead(name).length)]);
            try buffers.pushU8(buffer, '>');
        },
        else => try genericDescriptionB(buffer, x),
    }
}

pub fn toStringBAbi(buffer: *types.JanetBuffer, x: types.Janet) void {
    raise.reported(toStringB(buffer, x));
}

// -------------------------------------------------------------- description

pub fn descriptionB(buffer: *types.JanetBuffer, x: types.Janet) raise.Raising(void) {
    switch (kind.typeOf(x)) {
        constants.JANET_NIL => return try buffers.pushCString(buffer, "nil"),
        constants.JANET_KEYWORD => try buffers.pushU8(buffer, ':'),
        constants.JANET_STRING => return escapeStringB(buffer, wrap.toString(x)),
        constants.JANET_BUFFER => return escapeBufferB(buffer, wrap.toBuffer(x)),
        constants.JANET_ABSTRACT => {
            const p = wrap.toAbstract(x);
            const t = abstract_type.ofAbstract(p);
            if (t.*.tostring) |tostring| {
                try buffers.pushCString(buffer, "<");
                try buffers.pushCString(buffer, t.*.name);
                try buffers.pushCString(buffer, " ");
                try tostring(p, buffer);
                try buffers.pushCString(buffer, ">");
            } else {
                try stringDescriptionB(buffer, t.*.name, p);
            }
            return;
        },
        // A keyword has pushed its ':' and falls through to its bytes; every
        // other type is described exactly as it is stringified.
        else => {},
    }
    try toStringB(buffer, x);
}

pub fn descriptionBAbi(buffer: *types.JanetBuffer, x: types.Janet) void {
    raise.reported(descriptionB(buffer, x));
}

/// Render into a scratch buffer and hand back an interned string. The buffer
/// is deinitialised on the way out and stranded if a `tostring` callback
/// panics, which is what the C does.
fn intern(buffer: *types.JanetBuffer) types.JanetString {
    const ret = strings.new(buffer.data.?[0..@intCast(buffer.count)]);
    buffers.deinit(buffer);
    return ret;
}

pub fn description(x: types.Janet) types.JanetString {
    var buffer: types.JanetBuffer = undefined;
    _ = buffers.init(&buffer, 10);
    raise.reported(descriptionB(&buffer, x));
    return intern(&buffer);
}

/// Like `janet_description`, except that the three byte-sequence types and a
/// buffer answer with their contents rather than with a printed form — and the
/// first three of those need no rendering at all.
pub fn toString(x: types.Janet) types.JanetString {
    switch (kind.typeOf(x)) {
        constants.JANET_BUFFER => {
            const b = wrap.toBuffer(x);
            return strings.new(b.*.data.?[0..@intCast(b.*.count)]);
        },
        constants.JANET_STRING, constants.JANET_SYMBOL, constants.JANET_KEYWORD => return wrap.toString(x),
        else => {
            var buffer: types.JanetBuffer = undefined;
            _ = buffers.init(&buffer, 10);
            raise.reported(toStringB(&buffer, x));
            return intern(&buffer);
        },
    }
}

// A subsystem's exports follow its selector, which is what lets a *contract*
// module root itself at one of these files and compile the generic code under
// test without redefining the library's symbols. `root.zig` gates the import
// on the same flag, so the runtime is unaffected.
