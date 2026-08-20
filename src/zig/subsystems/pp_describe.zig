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
const abi = @import("abi");
const c = abi.c;
const raise = @import("raise");
const containers = @import("containers.zig");
const abstract_type = @import("abstract_type.zig");

/// `BUFSIZE` in `src/core/pp.c`: the scratch a number or a pointer
/// description is rendered into, and the headroom reserved before rendering.
const bufsize = 64;

/// `POINTSIZE`. A 64-bit build prints the low six bytes of a pointer rather
/// than all eight, because the top two are never significant on any supported
/// 64-bit target and dropping them keeps the description inside `bufsize`.
const pointsize: usize = if (@hasDecl(c, "JANET_64")) 6 else @sizeOf(?*anyopaque);

extern fn snprintf(buffer: [*c]u8, size: usize, format: [*:0]const u8, ...) callconv(.c) c_int;

/// `src/core/util.h`. Not reached through `abi.zig`, which deliberately does
/// not translate `util.h` — see the comment at the top of that file.
extern const janet_base64: [65]u8;
extern fn janet_registry_get(key: c.JanetCFunction) callconv(.c) [*c]c.JanetCFunRegistry;

inline fn hex(nibble: u8) u8 {
    return janet_base64[nibble];
}

// ------------------------------------------------------------------ numbers

/// `number_to_string_b`. Integral values inside the exactly-representable
/// range print without an exponent or a fraction; everything else gets
/// `DBL_DIG` significant digits.
fn numberToStringB(buffer: *c.JanetBuffer, x: f64) raise.Raising(void) {
    try containers.bufferEnsure(buffer, buffer.count + bufsize, 2);
    const integral = x == @floor(x) and x <= c.JANET_INTMAX_DOUBLE and x >= c.JANET_INTMIN_DOUBLE;
    const format: [*:0]const u8 = if (integral) "%.0f" else "%.15g";
    var count: c_int = undefined;
    if (x == 0.0) {
        // Print '0' rather than letting the formatter render '-0'.
        count = 1;
        buffer.data[@intCast(buffer.count)] = '0';
    } else {
        count = snprintf(buffer.data + @as(usize, @intCast(buffer.count)), bufsize, format, x);
    }
    buffer.count += count;
}

// ------------------------------------------------------------------ pointers

/// `string_description_b`. `<title 0xHEXHEX...>`, with the title truncated to
/// 32 bytes so that the whole thing fits the `bufsize` reservation.
fn stringDescriptionB(buffer: *c.JanetBuffer, title: [*c]const u8, pointer: ?*const anyopaque) raise.Raising(void) {
    try containers.bufferEnsure(buffer, buffer.count + bufsize, 2);
    const bytes: [@sizeOf(?*const anyopaque)]u8 = @bitCast(@intFromPtr(pointer));
    var at = buffer.data + @as(usize, @intCast(buffer.count));

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
    buffer.count = @intCast(at - buffer.data);
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
/// ABI. The C name below exists for `test/pp_describe.c`, which asserts the
/// returned width: nothing else observes it, and a width consistently two too
/// small would show up only as slightly wrong wrapping in output no test
/// compares.
fn escapeStringImpl(buffer: *c.JanetBuffer, str: [*c]const u8, len: i32) raise.Raising(i32) {
    try containers.bufferPushU8(buffer, '"');
    var align_count: i32 = 1;
    var i: i32 = 0;
    while (i < len) : (i += 1) {
        const byte = str[@intCast(i)];
        if (shortEscape(byte)) |escape| {
            try containers.bufferPushBytes(buffer, escape, 2);
            align_count += 2;
        } else if (byte < 32 or byte > 126) {
            const escape = [4]u8{ '\\', 'x', janet_base64[(byte >> 4) & 0xF], janet_base64[byte & 0xF] };
            try containers.bufferPushBytes(buffer, &escape, 4);
            align_count += 4;
        } else {
            try containers.bufferPushU8(buffer, byte);
            align_count += 1;
        }
    }
    try containers.bufferPushU8(buffer, '"');
    return align_count + 1;
}

/// The C face. `pp.c` declares `janet_zig_pp_escape_string` under the other
/// selector, so the symbol has to exist with the C convention; every Zig
/// caller reaches `escapeStringImpl` and gets the error instead.
pub fn escapeString(buffer: *c.JanetBuffer, str: [*c]const u8, len: i32) callconv(.c) i32 {
    return raise.reported(escapeStringImpl(buffer, str, len));
}

comptime {
    if (options.pp) @export(&escapeString, .{ .name = "janet_zig_pp_escape_string" });
}

fn escapeStringB(buffer: *c.JanetBuffer, str: c.JanetString) raise.Raising(void) {
    _ = try escapeStringImpl(buffer, str, c.janet_string_length(str));
}

fn escapeBufferB(buffer: *c.JanetBuffer, source: *c.JanetBuffer) raise.Raising(void) {
    if (source == buffer) {
        // Reserve the worst case up front so that the buffer cannot resize
        // underneath the loop that is reading it.
        try containers.bufferEnsure(source, source.count + 5 * source.count + 3, 1);
    }
    try containers.bufferPushU8(buffer, '@');
    _ = try escapeStringImpl(buffer, source.data, source.count);
}

// ---------------------------------------------------------------- to_string

/// The `<type 0x...>` fallback, which three cases in `toStringB` reach: an
/// unregistered cfunction, a function with no name, and everything with no
/// case of its own. In C the first two arrive by `goto fallthrough`.
fn genericDescriptionB(buffer: *c.JanetBuffer, x: c.Janet) raise.Raising(void) {
    try stringDescriptionB(buffer, c.janet_type_names[c.janet_type(x)], c.janet_unwrap_pointer(x));
}

pub fn toStringB(buffer: *c.JanetBuffer, x: c.Janet) raise.Raising(void) {
    switch (c.janet_type(x)) {
        c.JANET_NIL => try containers.bufferPushCString(buffer, ""),
        c.JANET_BOOLEAN => try containers.bufferPushCString(
            buffer,
            if (c.janet_unwrap_boolean(x) != 0) "true" else "false",
        ),
        c.JANET_NUMBER => try numberToStringB(buffer, c.janet_unwrap_number(x)),
        c.JANET_STRING, c.JANET_SYMBOL, c.JANET_KEYWORD => {
            const str = c.janet_unwrap_string(x);
            try containers.bufferPushBytes(buffer, str, c.janet_string_length(str));
        },
        c.JANET_BUFFER => {
            const to = c.janet_unwrap_buffer(x);
            // Reserve before pushing, so that appending a buffer to itself
            // cannot resize the storage the push is reading from.
            if (buffer == to) try containers.bufferExtra(buffer, to.*.count);
            try containers.bufferPushBytes(buffer, to.*.data, to.*.count);
        },
        c.JANET_ABSTRACT => {
            const p = c.janet_unwrap_abstract(x);
            const t = abstract_type.ofAbstract(p);
            if (t.*.tostring) |tostring| {
                try tostring(p, buffer);
            } else {
                try stringDescriptionB(buffer, t.*.name, p);
            }
        },
        c.JANET_CFUNCTION => {
            const reg = janet_registry_get(c.janet_unwrap_cfunction(x));
            if (reg == null) return genericDescriptionB(buffer, x);
            try containers.bufferPushCString(buffer, "<cfunction ");
            if (reg.*.name_prefix != null) {
                try containers.bufferPushCString(buffer, reg.*.name_prefix);
                try containers.bufferPushU8(buffer, '/');
            }
            try containers.bufferPushCString(buffer, reg.*.name);
            try containers.bufferPushU8(buffer, '>');
        },
        c.JANET_FUNCTION => {
            const def = c.janet_unwrap_function(x).*.def;
            if (def == null) return try containers.bufferPushCString(buffer, "<incomplete function>");
            if (def.*.name == null) return genericDescriptionB(buffer, x);
            const name = def.*.name;
            try containers.bufferPushCString(buffer, "<function ");
            try containers.bufferPushBytes(buffer, name, c.janet_string_length(name));
            try containers.bufferPushU8(buffer, '>');
        },
        else => try genericDescriptionB(buffer, x),
    }
}

fn toStringBFace(buffer: *c.JanetBuffer, x: c.Janet) callconv(.c) void {
    raise.reported(toStringB(buffer, x));
}

// -------------------------------------------------------------- description

pub fn descriptionB(buffer: *c.JanetBuffer, x: c.Janet) raise.Raising(void) {
    switch (c.janet_type(x)) {
        c.JANET_NIL => return try containers.bufferPushCString(buffer, "nil"),
        c.JANET_KEYWORD => try containers.bufferPushU8(buffer, ':'),
        c.JANET_STRING => return escapeStringB(buffer, c.janet_unwrap_string(x)),
        c.JANET_BUFFER => return escapeBufferB(buffer, c.janet_unwrap_buffer(x)),
        c.JANET_ABSTRACT => {
            const p = c.janet_unwrap_abstract(x);
            const t = abstract_type.ofAbstract(p);
            if (t.*.tostring) |tostring| {
                try containers.bufferPushCString(buffer, "<");
                try containers.bufferPushCString(buffer, t.*.name);
                try containers.bufferPushCString(buffer, " ");
                try tostring(p, buffer);
                try containers.bufferPushCString(buffer, ">");
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

fn descriptionBFace(buffer: *c.JanetBuffer, x: c.Janet) callconv(.c) void {
    raise.reported(descriptionB(buffer, x));
}

/// Render into a scratch buffer and hand back an interned string. The buffer
/// is deinitialised on the way out and stranded if a `tostring` callback
/// panics, which is what the C does.
fn intern(buffer: *c.JanetBuffer) c.JanetString {
    const ret = c.janet_string(buffer.data, buffer.count);
    c.janet_buffer_deinit(buffer);
    return ret;
}

fn descriptionFace(x: c.Janet) callconv(.c) c.JanetString {
    var buffer: c.JanetBuffer = undefined;
    _ = c.janet_buffer_init(&buffer, 10);
    raise.reported(descriptionB(&buffer, x));
    return intern(&buffer);
}

/// Like `janet_description`, except that the three byte-sequence types and a
/// buffer answer with their contents rather than with a printed form — and the
/// first three of those need no rendering at all.
fn toStringFace(x: c.Janet) callconv(.c) c.JanetString {
    switch (c.janet_type(x)) {
        c.JANET_BUFFER => {
            const b = c.janet_unwrap_buffer(x);
            return c.janet_string(b.*.data, b.*.count);
        },
        c.JANET_STRING, c.JANET_SYMBOL, c.JANET_KEYWORD => return c.janet_unwrap_string(x),
        else => {
            var buffer: c.JanetBuffer = undefined;
            _ = c.janet_buffer_init(&buffer, 10);
            raise.reported(toStringB(&buffer, x));
            return intern(&buffer);
        },
    }
}

// A subsystem's exports follow its selector, which is what lets a *contract*
// module root itself at one of these files and compile the generic code under
// test without redefining the library's symbols. `root.zig` gates the import
// on the same flag, so the runtime is unaffected.
comptime {
    if (options.pp) @export(&toStringBFace, .{ .name = "janet_to_string_b" });
    if (options.pp) @export(&descriptionBFace, .{ .name = "janet_description_b" });
    if (options.pp) @export(&descriptionFace, .{ .name = "janet_description" });
    if (options.pp) @export(&toStringFace, .{ .name = "janet_to_string" });
}
