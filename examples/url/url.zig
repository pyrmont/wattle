//! A native Janet module written in Zig: the worked example of the views.
//!
//! `numarray` is the worked example of the abstract type. This module
//! imports `janet` and `std` and nothing else. `build.zig` builds it and
//! `examples/url/test/url.janet` loads it, which `zig build test` runs.
//!
//! ## A module that owns nothing
//!
//! `DESIGN.md` section 14 records the decision that a type crosses to a
//! module author as a read-only view or as a capability, never as a pointer
//! to the aggregate.
//! `numarray` is the capability half: it owns a payload and fills in the
//! abstract type's slots. This module owns nothing. It reads its arguments,
//! does its work in plain Zig and returns a string. That is the shape most
//! native modules have, because a binding around a C library is usually a
//! translator rather than a container.
//!
//! ## What that shape needs, and what it does not
//!
//! Three views cover every Janet aggregate an argument can be: bytes,
//! indexed and dictionary. Each is the same pair of members: a string or a
//! buffer, a tuple or an array, a struct or a table. `slug` reads the bytes
//! and indexed views, `query` reads the dictionary view, and `cut` takes a
//! range over a length of its own. Between them that is the whole of what
//! this module asks the runtime for.
//!
//! ## The lookup table resolved at compile time
//!
//! `option_names` is a `std.StaticStringMap`. A C module of this shape
//! allocates a Janet table at first use, roots it against the collector so
//! it survives the program, and looks a keyword up in it. That is a table, a
//! root, one put per option and a get, all to map a name known at compile
//! time to a value known at compile time. Zig has that map already, so none
//! of it is asked for and there is nothing for the collector to see.

const std = @import("std");
const janet = @import("janet");

/// The most bytes any result in this file may be, including a terminator. A
/// fixed buffer rather than an allocation, because every function here
/// writes once and returns immediately: there is no ownership to pass
/// anywhere, and `janet.alloc` exists for the case where there is.
/// Overflowing it is a refusal rather than a truncation, because a silently
/// shortened URL is a wrong result from a working program.
const limit = 512;

// ==========================================================================
// The indexed view: a tuple of keyword options
// ==========================================================================

/// What a `:keyword` in the options argument selects.
///
/// `option_names` maps a name to an `Option` and `readStyle` switches on the
/// result.
const Option = enum { lower, upper, underscore };

/// The three option names, resolved at compile time, each mapped to its
/// `Option`. This is the lookup table a C module allocates and roots,
/// replaced by a compile-time map: nothing is allocated, nothing is rooted
/// and the collector has nothing to scan.
const option_names = std.StaticStringMap(Option).initComptime(.{
    .{ "lower", .lower },
    .{ "upper", .upper },
    .{ "underscore", .underscore },
});

/// How `slug` renders, after the options have been applied.
///
/// `readStyle` returns a `Style` and `slug` keeps it in a local. `case` is
/// what happens to a letter and `separator` is the byte written between
/// words.
const Style = struct {
    case: enum { keep, lower, upper } = .keep,
    separator: u8 = '-',
};

/// Reads the optional keyword-options argument at slot `n`.
///
/// `argv` is the cfunction's arguments and `n` is the slot the options are
/// in. An absent slot gives the default `Style`.
///
/// This function raises if slot `n` is not an indexed value, if an element
/// of it is not a keyword, or if a keyword names no option.
fn readStyle(argv: []janet.Value, n: i32) janet.Error!Style {
    var style: Style = .{};
    if (argv.len <= @as(usize, @intCast(n))) return style;
    // `janet.getIndexed` returns a `[]const Value`, so this is an ordinary
    // loop.
    for (try janet.getIndexed(argv, n), 0..) |option, i| {
        // `janet.toKeyword` returns null rather than raising, so both refusals
        // below are this module's: an unknown option is not a type error, and
        // the runtime does not check it.
        const name = janet.toKeyword(option) orelse
            return janet.panicFormat("option {d} is not a keyword", .{i});
        switch (option_names.get(name) orelse
            return janet.panicFormat("unknown option :{s}", .{name})) {
            .lower => style.case = .lower,
            .upper => style.case = .upper,
            .underscore => style.separator = '_',
        }
    }
    return style;
}

// ==========================================================================
// The cfunctions
// ==========================================================================

/// Appends `bytes` to `out` and advances `n`.
///
/// `out` is the fixed buffer, `n` is how many bytes it already holds, and
/// `bytes` is what to add. One byte is left free for the terminator.
///
/// This function raises if the result would not fit in `out`.
fn append(out: []u8, n: *usize, bytes: []const u8) janet.Error!void {
    if (n.* + bytes.len + 1 > out.len) return janet.panic("the result does not fit");
    @memcpy(out[n.*..][0..bytes.len], bytes);
    n.* += bytes.len;
}

/// Returns `title` as a URL path segment. Implements
/// `(url/slug title &opt opts)`.
///
/// `argv` slot 0 is the title and slot 1 is an optional tuple of keyword
/// options, which `readStyle` reads.
///
/// This function raises if the arity is wrong, if slot 0 is not a string,
/// symbol, keyword or buffer, if an option is unknown, or if the result does
/// not fit in `limit` bytes.
fn slug(argv: []janet.Value) janet.Error!janet.Value {
    try janet.arity(argv, 1, 2);
    // A bytes view: a string, a symbol, a keyword or a buffer, read in place.
    // A buffer's bytes move on a push, so the view is used inside this call
    // and never stored.
    const title = try janet.getBytes(argv, 0);
    const style = try readStyle(argv, 1);

    var out: [limit]u8 = undefined;
    var n: usize = 0;
    var gap = false;
    for (title) |raw| {
        if (!std.ascii.isAlphanumeric(raw)) {
            gap = n > 0;
            continue;
        }
        if (gap) {
            try append(&out, &n, &.{style.separator});
            gap = false;
        }
        try append(&out, &n, &.{switch (style.case) {
            .keep => raw,
            .lower => std.ascii.toLower(raw),
            .upper => std.ascii.toUpper(raw),
        }});
    }
    out[n] = 0;
    return janet.cstring(out[0..n :0]);
}

/// Returns `params` as a query string. Implements `(url/query params)`.
///
/// `argv` slot 0 is a struct or a table. Every key must be a keyword and
/// every value must be a number or a byte value. The result is in hash order,
/// the order Janet's own `pairs` gives; a caller that needs a stable string
/// sorts it.
///
/// This function raises if the arity is wrong, if slot 0 is not a
/// dictionary, if a key is not a keyword, if a value is neither a number nor
/// text, if the result does not fit in `limit` bytes, or if the walk finds a
/// different number of entries from `len`.
fn query(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    var params = try janet.getDictionary(argv, 0);

    var out: [limit]u8 = undefined;
    var n: usize = 0;
    var written: usize = 0;
    // `janet.getDictionary` returns an iterator over the filled slots of the
    // hash array; `len` is how many there are.
    while (params.next()) |kv| {
        const name = janet.toKeyword(kv.key) orelse
            return janet.panic("every query key must be a keyword");

        // An entry's value is in no argument slot, so it is read with the
        // `Value` forms, `janet.toNumber` and `janet.bytesView`, which return
        // null rather than raising; the refusals name the key, not a slot.
        var scratch: [32]u8 = undefined;
        const text: []const u8 = if (janet.toNumber(kv.value)) |x|
            std.fmt.bufPrint(&scratch, "{d}", .{x}) catch
                return janet.panicFormat("the value of :{s} does not render", .{name})
        else
            janet.bytesView(kv.value) orelse
                return janet.panicFormat("the value of :{s} is neither a number nor text", .{name});

        if (written != 0) try append(&out, &n, "&");
        try append(&out, &n, name);
        try append(&out, &n, "=");
        try append(&out, &n, text);
        written += 1;
    }

    // `len` counts the filled slots, so a walk that saw a different number is
    // a defect.
    if (written != params.len) {
        return janet.panicFormat("walked {d} entries where the view holds {d}", .{ written, params.len });
    }
    out[n] = 0;
    return janet.cstring(out[0..n :0]);
}

/// Returns a slice of `text`. Implements
/// `(url/cut text &opt start end)`.
///
/// `argv` slot 0 is the text, slot 1 is the start index and slot 2 is the
/// end index. Both indices are optional.
///
/// This function raises if the arity is wrong, if slot 0 is not a string,
/// symbol, keyword or buffer, if an index is present and is not a valid
/// index, or if the result does not fit in `limit` bytes.
fn cut(argv: []janet.Value) janet.Error!janet.Value {
    try janet.arity(argv, 1, 3);
    const text = try janet.getBytes(argv, 0);
    // The length is this module's own, here the view's; a binding around a C
    // library passes whatever that library reported. `janet.getRange` folds
    // the two slots the way `string/slice` does: a negative index counts from
    // the end, an absent or nil slot takes that whole side, and an end below
    // the start is clamped up to it.
    const range: janet.Range = try janet.getRange(argv, 1, text.len);
    // The range is already inside the length that was handed in, so the two
    // casts narrow a value that is already checked rather than asserting a
    // new bound.
    const from: usize = @intCast(range.start);
    const to: usize = @intCast(range.end);

    var out: [limit]u8 = undefined;
    var n: usize = 0;
    try append(&out, &n, text[from..to]);
    out[n] = 0;
    return janet.cstring(out[0..n :0]);
}

/// Returns a query string parsed back into a struct. Implements
/// `(url/parse-query query)`.
///
/// `argv` slot 0 is the query string. A repeated key keeps the last, which
/// is what a struct literal does and what `janet.structOf` documents.
///
/// This function raises if the arity is wrong, if slot 0 is not a string,
/// symbol, keyword or buffer, if there are more than thirty-two fields, or
/// if a field has no `'='`.
fn parseQuery(argv: []janet.Value) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    const text = try janet.getBytes(argv, 0);
    if (text.len == 0) return janet.structOf(&.{});

    var pairs: [32]janet.Pair = undefined;
    var n: usize = 0;
    var fields = std.mem.splitScalar(u8, text, '&');
    while (fields.next()) |field| {
        if (n == pairs.len) return janet.panicFormat("more than {d} fields", .{pairs.len});
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse
            return janet.panicFormat("field {d} has no '='", .{n});
        // `janet.keyword` and `janet.string` take the `[]const u8` that
        // `janet.getBytes` returned, so nothing is copied here; the runtime
        // interns its own copy, which is what lets the struct outlive `text`.
        pairs[n] = .{
            .key = janet.keyword(field[0..eq]),
            .value = janet.string(field[eq + 1 ..]),
        };
        n += 1;
    }
    return janet.structOf(pairs[0..n]);
}

// ==========================================================================
// The module entry point
// ==========================================================================

/// Defines the module's four cfunctions.
///
/// `env` is the capability to define a binding in the environment the module
/// is loading into. `janet.entry` below passes `defs` to the loader.
///
/// This function cannot raise. Nothing is registered but the four
/// cfunctions: this module declares no abstract type, so it has no
/// `janet.registerAbstract` to call and nothing fallible in it. It is still
/// typed as raising, because that is the one shape `janet.entry` takes.
fn defs(env: *janet.Env) janet.Error!void {
    janet.cfuns(env, "url", &.{
        janet.reg("slug", &slug, "(url/slug title &opt opts)\n\nA title as a URL path segment."),
        janet.reg("query", &query, "(url/query params)\n\nA struct or table as a query string."),
        janet.reg("cut", &cut, "(url/cut text &opt start end)\n\nA slice of a byte argument."),
        janet.reg("parse-query", &parseQuery, "(url/parse-query query)\n\nA query string back into a struct."),
    });
}

comptime {
    janet.entry(defs);
}
