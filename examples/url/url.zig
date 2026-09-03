//! A native Janet module written in Zig: the worked example of the *views*,
//! as `numarray` is the worked example of the abstract type.
//!
//! `DESIGN.md` section 15 decides that a type crosses to a module author as a
//! read-only view or as a capability, never as a pointer to the aggregate.
//! `numarray` is the capability half — it owns a payload and fills in the
//! abstract type's slots. This module owns nothing. It reads its arguments,
//! does its work in plain Zig and answers a string, which is the shape most
//! native modules actually have: a binding around a C library is usually a
//! translator, not a container.
//!
//! **What that shape needs, and what it does not.** Three views cover every
//! Janet aggregate an argument can be — bytes, indexed, dictionary — and each
//! is the same pair of members: a string or a buffer, a tuple or an array, a
//! struct or a table. `slug` reads the first two, `query` reads the third and
//! `cut` takes a range over a length of its own. Between them that is the
//! whole of what this module asks the runtime for.
//!
//! **The lookup table is a `StaticStringMap`, and that is the point.** A C
//! module of this shape allocates a Janet table at first use, roots it against
//! the collector so it survives the program, and looks a keyword up in it — a
//! table, a root, one put per option and a get, all to map a name known at
//! compile time to a value known at compile time. Zig has that map already, so
//! none of it is asked for and there is nothing for the collector to see.
//!
//! It imports `janet` and `std` and nothing else. Built by `build.zig` and
//! loaded by `test/url.janet`, which `zig build test` runs.

const std = @import("std");
const janet = @import("janet");

/// The longest answer any of these builds.
///
/// A fixed buffer rather than an allocation because every function here writes
/// once and answers immediately: there is no ownership to hand anywhere, and
/// `janet.alloc` exists for the case where there is. Overflowing it is a
/// refusal rather than a truncation, because a silently shortened URL is a
/// wrong answer from a working program.
const limit = 512;

// ==========================================================================
// The indexed view: a tuple of keyword options
// ==========================================================================

/// What a `:keyword` in the options argument selects.
const Option = enum { lower, upper, underscore };

/// The names, resolved at compile time.
///
/// **This is the GC-rooted lookup table, dissolved.** See the header.
const option_names = std.StaticStringMap(Option).initComptime(.{
    .{ "lower", .lower },
    .{ "upper", .upper },
    .{ "underscore", .underscore },
});

/// How `slug` renders, after the options have been applied.
const Style = struct {
    case: enum { keep, lower, upper } = .keep,
    separator: u8 = '-',
};

/// Read the optional keyword-options argument at slot `n`.
///
/// **The three things this needs were the whole of what a module of this shape
/// could not do**: read an indexed argument, tell the members of the view
/// apart, and refuse with a message naming what was wrong.
///
/// `getIndexed` answers a `[]const Value`, so the loop is an ordinary Zig
/// loop; `isKeyword` and `toKeyword` are what read an element out of it. The
/// two refusals are this module's own, because an unknown option is not a type
/// error and the runtime has nothing to say about it.
fn readStyle(argv: []janet.Value, n: i32) janet.Error!Style {
    var style: Style = .{};
    if (argv.len <= @as(usize, @intCast(n))) return style;
    for (try janet.getIndexed(argv, n), 0..) |option, i| {
        if (!janet.isKeyword(option)) {
            return janet.panicFormat("option {d} is not a keyword", .{i});
        }
        const name = janet.toKeyword(option);
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

/// Append to a fixed buffer, or refuse.
fn append(out: []u8, n: *usize, bytes: []const u8) janet.Error!void {
    if (n.* + bytes.len + 1 > out.len) return janet.panic("the result does not fit");
    @memcpy(out[n.*..][0..bytes.len], bytes);
    n.* += bytes.len;
}

/// `(url/slug title &opt opts)` — a title as a URL path segment.
///
/// The title is a **bytes view**, so a string, a symbol, a keyword or a buffer
/// all work and none of them is copied to be read. A string's, a symbol's and
/// a keyword's bytes are stable while the value is reachable; a buffer's are
/// `data[0..count]` and a push would move them — which is why the loop below
/// reads the view and finishes with it inside the call, rather than storing
/// it.
fn slug(argv: []janet.Value) align(janet.fn_align) janet.Error!janet.Value {
    try janet.arity(argv, 1, 2);
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

/// `(url/query params)` — a struct or a table as a query string.
///
/// **A dictionary view is three numbers, not a slice**, and this loop is why:
/// `kvs` is the whole hash array and `cap` is how long it is, while `len` is
/// how many of its slots hold an entry. The walk reads every slot and skips
/// the empty ones.
///
/// **`kvs` is checked as a formality.** Every struct and table a constructor
/// builds has at least one bucket — a requested capacity of zero is rounded up
/// to one, because the hash degenerates at a mask of zero — so no dictionary a
/// Janet program can pass here has a null array. The `if` costs nothing and
/// the optional is the field's declared default.
///
/// **The order is the hash order.** Nothing about a struct or a table promises
/// one, so a caller that needs a stable query string sorts the result; this is
/// the same thing Janet's own `pairs` gives.
fn query(argv: []janet.Value) align(janet.fn_align) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    const params = try janet.getDictionary(argv, 0);

    var out: [limit]u8 = undefined;
    var n: usize = 0;
    var written: usize = 0;
    if (params.kvs) |kvs| for (0..params.cap) |i| {
        const kv: janet.KV = kvs[i];
        if (janet.isNil(kv.key)) continue;
        if (!janet.isKeyword(kv.key)) return janet.panic("every query key must be a keyword");
        const name = janet.toKeyword(kv.key);

        // **`bytesView` is the getter's `Value` form**, and it is what reads an
        // element *out* of a view: `getBytes(argv, n)` takes an argument slot,
        // and this value is not in one. It answers nothing rather than
        // raising, so the refusal is this module's and names the key the
        // caller wrote rather than a slot number they cannot see.
        var scratch: [32]u8 = undefined;
        const text: []const u8 = if (janet.isNumber(kv.value))
            std.fmt.bufPrint(&scratch, "{d}", .{janet.toNumber(kv.value)}) catch
                return janet.panicFormat("the value of :{s} does not render", .{name})
        else
            janet.bytesView(kv.value) orelse
                return janet.panicFormat("the value of :{s} is neither a number nor text", .{name});

        if (written != 0) try append(&out, &n, "&");
        try append(&out, &n, name);
        try append(&out, &n, "=");
        try append(&out, &n, text);
        written += 1;
    };

    if (written != params.len) {
        return janet.panicFormat("walked {d} entries where the view holds {d}", .{ written, params.len });
    }
    out[n] = 0;
    return janet.cstring(out[0..n :0]);
}

/// `(url/cut text &opt start end)` — a slice of a byte argument.
///
/// **The length handed to `getRange` is this module's own**, which is the
/// difference between it and the `(x &opt start end)` every core builtin has:
/// here it is the view's length, and in a binding around a C library it is
/// whatever that library reported. What the caller gets in exchange is the
/// three rules Janet's own `string/slice` follows — a negative index counts
/// from the end, an absent or nil slot takes that whole side, and an end below
/// the start is clamped up to it — because the fold is the same code.
fn cut(argv: []janet.Value) align(janet.fn_align) janet.Error!janet.Value {
    try janet.arity(argv, 1, 3);
    const text = try janet.getBytes(argv, 0);
    const range: janet.Range = try janet.getRange(argv, 1, text.len);
    // The range is already inside the length that was handed in, so the two
    // casts are narrowing a checked value rather than asserting a new one.
    const from: usize = @intCast(range.start);
    const to: usize = @intCast(range.end);

    var out: [limit]u8 = undefined;
    var n: usize = 0;
    try append(&out, &n, text[from..to]);
    out[n] = 0;
    return janet.cstring(out[0..n :0]);
}

/// `(url/parse-query query)` — a query string back into a struct.
///
/// **`query`'s inverse, and what a module that answers with a composite
/// needs.** Everything above answers a string, which is as far as reading gets
/// you; a parser, a decoder, anything whose result is structured has to build
/// one. The constructors take exactly what the getters hand out, so the pairs
/// are assembled as ordinary Zig values and `structOf` makes the struct.
///
/// A repeated key keeps the last, which is what a struct literal does and what
/// `structOf` documents.
fn parseQuery(argv: []janet.Value) align(janet.fn_align) janet.Error!janet.Value {
    try janet.fixarity(argv, 1);
    const text = try janet.getBytes(argv, 0);
    if (text.len == 0) return janet.structOf(&.{});

    var pairs: [32]janet.KV = undefined;
    var n: usize = 0;
    var fields = std.mem.splitScalar(u8, text, '&');
    while (fields.next()) |field| {
        if (n == pairs.len) return janet.panicFormat("more than {d} fields", .{pairs.len});
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse
            return janet.panicFormat("field {d} has no '='", .{n});
        // **The bytes view goes straight into the constructor.** `keyword` and
        // `string` take a `[]const u8`, which is what `getBytes` answered, so
        // the module copies nothing and recomputes no length. The runtime
        // interns a copy on its own side, as it must: the struct outlives the
        // argument it was built from.
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
//
// Nothing is registered but the three cfunctions: this module declares no
// abstract type, so it has no `registerAbstract` to call and `defs` has
// nothing fallible in it. It is still typed as raising, because that is the
// one shape `entry` takes.

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
