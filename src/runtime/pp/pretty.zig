//! Laying a structure of Janet values out on a page, and writing a value back
//! out as JDN.
//!
//! `pp.zig` renders what a single value is called. This file is everything
//! that takes more than a single value: the recursion into arrays, tuples,
//! structs and tables, the cycle table that stops it looping, the column
//! arithmetic, the newline backtracking that pulls a short tail back onto its
//! parent's line, the two truncation limits, and the key sort that makes a
//! dictionary print the same way twice.
//!
//! `Pretty` serves both the pretty printer and the JDN writer, which share
//! almost nothing else: JDN has no width, no colour, no alignment and no
//! truncation, and it fails on values the pretty printer renders happily, such
//! as a function, a fiber, an abstract, or a keyword that would not read back.
//! The record is shared because `seen` and the buffer are common to both.
//!
//! Two things in the recursion raise. `pp.descriptionB` does, when an abstract
//! type's `tostring` does, and a buffer push does, on a buffer that cannot
//! grow. `tables.put` does not: a type's `hash` and `compare` are
//! `callconv(.c) i32` with no error channel.
//!
//! A value with no JDN form is not a raise in the recursion. `printJdnOne`
//! reports it upwards as a `bool` and only `jdn` turns it into a panic, so the
//! recursion needs no second error channel and the message is written once.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const args_core = @import("../args.zig");
const buffers = @import("../value/buffers.zig");
const describe = @import("../pp.zig");
const fatal = @import("../fatal.zig");
const gc_alloc = @import("../gc.zig");
const numscan = @import("../scan.zig");
const order = @import("../value/helpers/order.zig");
const raise = @import("../../api/raise.zig");
const repr = @import("repr");
const strings = @import("../value/strings.zig");
const structs = @import("../value/structs.zig");
const tables = @import("../value/tables.zig");
const tuples = @import("../value/tuples.zig");
const utils = @import("../utils.zig");
const value = @import("../value.zig");
const wrap = @import("../value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The two truncation limits, and the size past which sorting a dictionary's
/// keys is given up on.
const array_limit: i32 = 160;
const dict_keysort_limit: i32 = 2000;
const dict_limit: i32 = 30;

/// How much room `integerToStringB` reserves before it writes digits.
const bufsize = 64;

/// The escapes that are not per type: a prototype's `_name`, the reset that
/// follows any escape, a cycle marker, and a keyword, which has the symbol's
/// tag.
const class_color = "\x1B[34m";
const color_reset = "\x1B[0m";
const cycle_color = "\x1B[36m";
const keyword_color = "\x1B[33m";

/// One escape per tag, in `repr.Tag` order.
const type_colors = [16][*:0]const u8{
    "\x1B[32m", // number
    "\x1B[36m", // nil
    "\x1B[36m", // boolean
    "\x1B[35m", // buffer
    "\x1B[35m", // string
    "\x1B[36m", // array
    "\x1B[36m", // vector
    "\x1B[36m", // table
    "\x1B[36m", // struct
    "\x1B[34m", // symbol
    "\x1B[36m", // tuple
    "\x1B[36m", // fiber
    "\x1B[36m", // function
    "\x1B[36m", // cfunction
    "\x1B[36m", // abstract
    "\x1B[36m", // pointer
};

// ==========================================================================
// Types
// ==========================================================================

/// One pretty-print in progress: where the output goes, how deep and how wide
/// it has got, and what the caller asked for.
///
/// Two of its fields are scratch, and neither is freed on a raising path.
/// `seen` is a scratch table, so `tables.deinit` takes the `gc.sfree` arm, but
/// `prettyBuffer` `try`s its recursion before reaching that call, so a raise
/// returns past it; `jdn` keeps the error union and deinitialises first, so it
/// does free. The key-sort buffer is freed here on no path: there is no
/// `gc.sfree` for it in this file, and its `gc.srealloc` block is the
/// collector's from the start. Nothing is leaked either way, because
/// `gc.freeAllScratch` reclaims both at the end of the next collection.
const Pretty = struct {
    buffer: *buffers.Buffer,
    depth: c_int,
    width: c_int,
    align_col: c_int,
    leaf_align: c_int,
    flags: PrettyFlags,
    bufstartlen: usize,
    lookback_barrier: usize,
    keysort_buffer: ?[*]i32,
    keysort_capacity: i32,
    keysort_start: i32,
    seen: tables.Table,

    inline fn pushByte(self: *Pretty, byte: u8) raise.Error!void {
        try buffers.pushU8(self.buffer, byte);
    }

    inline fn pushCstring(self: *Pretty, str: [*:0]const u8) raise.Error!void {
        try buffers.pushCString(self.buffer, str);
    }

    /// Emit a colour escape, or nothing when the build is not colouring.
    inline fn pushColor(self: *Pretty, color: [*:0]const u8) raise.Error!void {
        try if (self.flags.color) self.pushCstring(color);
    }
};

/// What the caller asked the pretty printer for: three independent bits,
/// numbered as C's `JANET_PRETTY_COLOR`, `JANET_PRETTY_ONELINE` and
/// `JANET_PRETTY_NOTRUNC`.
pub const PrettyFlags = packed struct(c_int) {
    /// Emit ANSI colour escapes.
    color: bool = false,
    /// Never break a line.
    oneline: bool = false,
    /// Print every element of a long collection rather than eliding.
    notrunc: bool = false,
    _reserved: u29 = 0,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Renders `x` as JDN into `buffer`, or raises saying it cannot be.
///
/// This is the only raise the file decides, and why `printJdnOne` reports a
/// flag rather than raising: the message is written once, here.
/// `pp/format.zig` imports this and `try`s it.
///
/// `startlen` and `lookback_barrier` are parameters rather than read from the
/// buffer's count, because every caller reaching this through the formatter
/// already has both.
pub fn jdn(
    buffer: ?*buffers.Buffer,
    depth: c_int,
    x: repr.Value,
    startlen: usize,
    lookback_barrier: usize,
) raise.Error!*buffers.Buffer {
    var S = initState(buffer, depth, 0, .{}, startlen, lookback_barrier);
    const failed = printJdnOne(&S, x, depth);
    tables.deinit(&S.seen);
    if (try failed) return raise.panic("could not print to jdn format");
    return S.buffer;
}

/// The pretty-printing perimeter, which `pp/format.zig` reaches `%p` and its
/// seven siblings through, by import.
///
/// `buffer` is the destination, or null for a fresh one; `depth` and `width`
/// are the recursion budget and the page width; `startlen` is where the
/// message began in the buffer, and `lookback_barrier` where a reflow must
/// stop.
///
/// It raises: the buffer pushes underneath it can overflow, and an abstract
/// type's `tostring` can. The raise is returned, and nothing calls this across
/// the ABI.
pub fn prettyBuffer(
    buffer: ?*buffers.Buffer,
    depth: c_int,
    width: c_int,
    flags: PrettyFlags,
    x: repr.Value,
    startlen: usize,
    lookback_barrier: usize,
) raise.Error!*buffers.Buffer {
    var S = initState(buffer, depth, width, flags, startlen, lookback_barrier);
    try prettyOne(&S, x);
    backtrackNewlines(&S);
    tables.deinit(&S.seen);
    return S.buffer;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Having just closed a bracket, walks back over what was written and, where
/// the whole tail fits inside the page width, pulls it up onto one line by
/// deleting the newlines and their indentation.
///
/// The walk stops at `lookback_barrier`, which is where the caller's own text
/// ended: a `%p` writing into a buffer with output already in it must not
/// reflow what was there before.
fn backtrackNewlines(S: *const Pretty) void {
    if (S.flags.oneline or S.buffer.count <= 0) return;
    switch (S.buffer.slice()[@intCast(S.buffer.count - 1)]) {
        ')', '}', ']' => {},
        else => return,
    }

    var removed: i32 = 0;
    const old_count = S.buffer.count;
    // The walk below is signed on purpose: it runs down to one byte past the
    // barrier, and the `offset += 1` after the loop brings it back. With
    // `buffer.count` unsigned that step underflows, so the two indices are
    // widened here and narrowed once, after the loop has finished.
    var offset: isize = @intCast(old_count);
    const b0: isize = @intCast(S.lookback_barrier);
    var columns = S.width;
    var align_run: i32 = 0;

    offset -= 1;
    while (offset >= b0) : (offset -= 1) {
        const at = S.buffer.data.? + @as(usize, @intCast(offset));
        if (at[0] == '\n') {
            // A line indented less than the leaf is a parent's line, and
            // pulling past it would reflow more than this bracket's contents.
            if (align_run < S.leaf_align) break;
            columns += align_run;
            removed += align_run;
            align_run = 0;
        } else if (at[0] == ' ') {
            align_run += 1;
        } else {
            align_run = 0;
            // A colour escape occupies no columns, so step over it rather
            // than charging the page for it: `\x1B[0m` and `\x1B[3<n>m`.
            if (S.flags.color and at[0] == 'm') {
                if (offset >= 3 + b0 and std.mem.eql(u8, (at - 3)[0..4], color_reset)) {
                    offset -= 3;
                    columns += 1;
                } else if (offset >= 4 + b0 and std.mem.eql(u8, (at - 4)[0..3], "\x1B[3")) {
                    offset -= 4;
                    columns += 1;
                }
            }
        }
        columns -= 1;
        if (columns <= 0) return;
    }

    // Either the walk ran off the barrier, or it stopped on a newline it must
    // not disturb; in both cases the rewrite starts one byte later.
    offset += 1;
    if (offset < b0) fatal.fatal("bad buffer index");
    const start: usize = @intCast(offset);

    S.buffer.count -= @as(usize, @intCast(removed));
    // The compaction reads ahead of what it writes, up to `old_count`, which
    // is past the count just shortened, so it works over the allocation rather
    // than over `slice()`, and the `read >= old_count` guard below keeps it
    // inside that range.
    //
    // The two cursors are independent, and `start` is not established as being
    // at or below the count just shortened, so `for (start..count)` would trap
    // on the empty case this loop correctly does nothing for.
    const bytes = S.buffer.reserved();
    var read = start;
    var i = start;
    while (i < S.buffer.count) : (i += 1) {
        if (bytes[read] == '\n') {
            bytes[i] = ' ';
            // Skip the newline and the indentation that followed it. The
            // single space just written is what the whole run collapses to.
            read += 1;
            while (bytes[read] == ' ') {
                if (read >= old_count) fatal.fatal("bad replacement of newline");
                read += 1;
            }
        } else {
            bytes[i] = bytes[read];
            read += 1;
        }
    }
}

/// Whether a symbol or keyword contains a character that stops it reading
/// back. `sym` is the text and `issym` says which of the two it is, since a
/// symbol may not begin with a digit. Text that fails this has no JDN form.
fn containsBadChars(sym: strings.String, issym: bool) bool {
    const len = strings.head(sym).length;
    if (len != 0 and issym and sym[0] >= '0' and sym[0] <= '9') return true;
    if (!numscan.validUtf8(sym[0..@intCast(len)])) return true;
    for (sym[0..len]) |ch| {
        if (!numscan.isSymbolChar(ch)) return true;
    }
    return false;
}

/// How many decimal digits `start` needs, for a non-positive `start`. Counting
/// on the negative side is what lets the most negative `i32` be counted at
/// all.
fn countDig10(start: i32) i32 {
    var x = start;
    var result: i32 = 1;
    while (true) {
        if (x > -10) return result;
        if (x > -100) return result + 1;
        if (x > -1000) return result + 2;
        if (x > -10000) return result + 3;
        x = @divTrunc(x, 10000);
        result += 4;
    }
}

/// The state both perimeters start from, as they share the record.
///
/// `leaf_align` is set to zero rather than left `undefined`. Nothing reads it
/// before it is written in any case that could be constructed: the only reader
/// is `backtrackNewlines`, which returns before it unless the buffer ends in a
/// closing bracket, and anything that puts one there has gone through a
/// container and written the field. An uninitialised read is still not a
/// behaviour worth preserving.
fn initState(buffer: ?*buffers.Buffer, depth: c_int, width: c_int, flags: PrettyFlags, startlen: usize, lookback_barrier: usize) Pretty {
    var S = Pretty{
        .buffer = buffer orelse buffers.new(0),
        .depth = depth,
        .width = width,
        .align_col = 0,
        .leaf_align = 0,
        .flags = flags,
        .bufstartlen = startlen,
        .lookback_barrier = lookback_barrier,
        .keysort_buffer = null,
        .keysort_capacity = 0,
        .keysort_start = 0,
        .seen = undefined,
    };
    _ = tables.init(&S.seen, 10);
    return S;
}

/// Writes `val` to `buffer` as decimal digits and returns how many bytes went
/// in, which is what the cycle marker adds to its alignment.
///
/// The digits are produced from the negative side for the same reason
/// `countDig10` counts there: negating the most negative `i32` overflows and
/// negating any other value does not, so the loop stays in the range every
/// input fits.
fn integerToStringB(buffer: *buffers.Buffer, val: i32) raise.Error!i32 {
    try buffers.extra(buffer, bufsize);
    var at = buffer.data.? + @as(usize, @intCast(buffer.count));
    var x = val;
    var neg: i32 = 0;

    if (x == 0) {
        at[0] = '0';
        buffer.count += 1;
        return 1;
    }
    if (x > 0) {
        x = -x;
    } else {
        neg = 1;
        at[0] = '-';
        at += 1;
    }
    const len = countDig10(x);
    at += @intCast(len);
    while (x != 0) {
        const digit: u8 = @intCast(-@rem(x, 10));
        at -= 1;
        at[0] = '0' + digit;
        x = @divTrunc(x, 10);
    }
    buffer.count += @as(usize, @intCast(len + neg));
    return len + neg;
}

/// The entries of a struct or table, as `printJdnOne` writes them.
///
/// The two containers differ only in where their buckets and capacity come
/// from, so both arrive as parameters.
///
/// The keys are sorted, as `prettyEntries` sorts them, because JDN is a
/// serialisation format and storage order is not reproducible: a key hashed by
/// pointer, such as a buffer, an array, a table, a fiber or an abstract, sits
/// in a bucket chosen by an allocation address, so the same value prints
/// differently in two runs of the same binary.
///
/// The sort is `std.mem.sort` rather than `utils.sortedKeys`, which is an
/// insertion sort. `prettyEntries` affords an insertion sort because it
/// refuses to sort past `dict_keysort_limit` and truncates instead. There is
/// nothing to truncate to here, so a quadratic sort over every entry would
/// make a large dictionary quadratic to serialise. `std.mem.sort` is stable,
/// so the order agrees with `%p`'s entry for entry.
fn printJdnKvs(S: *Pretty, kvs: []const tables.Keyval, depth: c_int) raise.Error!bool {
    const ks_start = S.keysort_start;
    defer S.keysort_start = ks_start;

    var len: usize = 0;
    for (kvs) |*kv| {
        if (!repr.checkType(kv.key, repr.Tag.nil)) len += 1;
    }
    if (len == 0) return false;

    // The sort indices for every dictionary on the recursion stack share one
    // scratch allocation, each nesting level taking the slice above the level
    // below it. `prettyEntries` uses the same arrangement and the same
    // buffer.
    const mincap: i64 = @as(i64, @intCast(len)) + @as(i64, ks_start);
    if (mincap > std.math.maxInt(i32)) return true;
    if (S.keysort_capacity < mincap) {
        S.keysort_capacity = if (mincap >= std.math.maxInt(i32) / 2)
            std.math.maxInt(i32)
        else
            @intCast(mincap * 2);
        S.keysort_buffer = @ptrCast(@alignCast(gc_alloc.srealloc(
            S.keysort_buffer,
            @sizeOf(i32) * @as(usize, @intCast(S.keysort_capacity)),
        )));
        if (S.keysort_buffer == null) fatal.outOfMemory();
    }
    // A nonzero `len` forces `mincap` above `keysort_capacity` unless the
    // capacity is already nonzero, and a nonzero capacity means some level
    // allocated the buffer and checked it, so the buffer is here.
    const buf = (S.keysort_buffer orelse unreachable) + @as(usize, @intCast(ks_start));
    var next: usize = 0;
    for (kvs, 0..) |*kv, i| {
        if (repr.checkType(kv.key, repr.Tag.nil)) continue;
        buf[next] = @intCast(i);
        next += 1;
    }
    std.mem.sort(i32, buf[0..len], kvs, struct {
        fn lessThan(context: []const tables.Keyval, a: i32, b: i32) bool {
            return order.compare(
                context[@intCast(a)].key,
                context[@intCast(b)].key,
            ) < 0;
        }
    }.lessThan);
    S.keysort_start += @intCast(len);

    for (buf[0..len], 0..) |j, i| {
        const kv = &kvs[@intCast(j)];
        try if (i != 0) S.pushByte(' ');
        if (try printJdnOne(S, kv.key, depth - 1)) return true;
        try S.pushByte(' ');
        if (try printJdnOne(S, kv.value, depth - 1)) return true;
    }
    return false;
}

/// Writes `x` as JDN, recursing to `depth`.
///
/// Failure is reported rather than raised: `true` means the value has no JDN
/// form, and the perimeter is what panics. Depth is a parameter here rather
/// than a field of the record, because JDN counts down a recursion of its own,
/// separate from the pretty printer's.
fn printJdnOne(S: *Pretty, x: repr.Value, depth: c_int) raise.Error!bool {
    if (depth == 0) return true;
    switch (repr.typeOf(x)) {
        repr.Tag.nil, repr.Tag.boolean, repr.Tag.buffer, repr.Tag.string => {
            try describe.descriptionB(S.buffer, x);
        },
        repr.Tag.number => {
            try buffers.ensure(S.buffer, S.buffer.count + bufsize, 2);
            const num = wrap.toNumber(x);
            // Neither has a JDN spelling that reads back as itself.
            if (std.math.isNan(num)) return true;
            if (std.math.isInf(num)) return true;
            try numscan.bufferDtostr(S.buffer, num);
        },
        repr.Tag.symbol => {
            if (containsBadChars(wrap.toSymbol(x), !wrap.isKeyword(x))) return true;
            try describe.descriptionB(S.buffer, x);
        },
        repr.Tag.tuple => {
            const t = wrap.toTuple(x);
            const bracketed = tuples.isBracketed(tuples.head(t));
            try S.pushByte(if (bracketed) '[' else '(');
            for (tuples.view(t), 0..) |item, i| {
                try if (i != 0) S.pushByte(' ');
                if (try printJdnOne(S, item, depth - 1)) return true;
            }
            try S.pushByte(if (bracketed) ']' else ')');
        },
        repr.Tag.array => {
            _ = tables.put(&S.seen, x, wrap.fromTrue());
            const a = wrap.toArray(x);
            try S.pushCstring("@[");
            for (0..a.count) |i| {
                try if (i != 0) S.pushByte(' ');
                if (try printJdnOne(S, a.slice()[i], depth - 1)) return true;
            }
            try S.pushByte(']');
        },
        repr.Tag.table => {
            _ = tables.put(&S.seen, x, wrap.fromTrue());
            const tab = wrap.toTable(x);
            try S.pushCstring("@{");
            if (try printJdnKvs(S, tab.slots(), depth)) return true;
            try S.pushByte('}');
        },
        repr.Tag.@"struct" => {
            const st = wrap.toStruct(x);
            try S.pushByte('{');
            if (try printJdnKvs(S, st[0..structs.head(st).capacity], depth)) return true;
            try S.pushByte('}');
        },
        else => return true,
    }
    return false;
}

/// `print_newline`. In one-line mode a separator is a space and nothing else
/// happens; otherwise this is where the reflow attempt is made. `align_col` is
/// the column the new line is indented to.
fn printNewline(S: *Pretty, align_col: c_int) raise.Error!void {
    if (S.flags.oneline) {
        try S.pushByte(' ');
        return;
    }
    backtrackNewlines(S);
    try S.pushByte('\n');
    S.align_col = align_col;
    S.leaf_align = align_col;
    // The column corrections above can drive `align_col` negative, and the
    // loop below simply does not run when they do.
    const indent: usize = if (S.align_col > 0) @intCast(S.align_col) else 0;
    for (0..indent) |_| try S.pushByte(' ');
}

/// A struct or a table.
fn prettyDictionary(S: *Pretty, x: repr.Value) raise.Error!void {
    if (repr.checkType(x, repr.Tag.table)) {
        const t = wrap.toTable(x);
        S.align_col += 1;
        try S.pushCstring("@");
        if (t.proto) |proto| {
            try pushClassName(S, tables.get(proto, value.fromBytes("_name", .keyword)));
        }
    } else {
        const st = wrap.toStruct(x);
        if (structs.head(st).proto) |proto| {
            try pushClassName(S, structs.get(proto, value.fromBytes("_name", .keyword)));
        }
    }

    try S.pushByte('{');
    S.align_col += 1;
    const align_col = S.align_col;
    S.leaf_align = align_col;

    S.depth -= 1;
    if (S.depth == 0) {
        try pushEllipsis(S);
    } else {
        try prettyEntries(S, x, align_col);
    }
    S.depth += 1;

    try S.pushByte('}');
    S.align_col += 1;
}

/// The entries of a struct or table, sorted where sorting is affordable.
fn prettyEntries(S: *Pretty, x: repr.Value, align_col: c_int) raise.Error!void {
    const view = args_core.dictionaryView(x).?;
    var len = view.len;
    const ks_start = S.keysort_start;
    var truncated = false;

    if (len > dict_keysort_limit) {
        // Too large to be worth sorting: print in storage order, and print
        // only the head of it unless truncation is off.
        if (!S.flags.notrunc and len > dict_limit) {
            len = dict_limit;
            truncated = true;
        }
        var j: usize = 0;
        for (0..len) |i| {
            while (repr.checkType(view.kvs.?[j].key, repr.Tag.nil)) j += 1;
            try if (i != 0) printNewline(S, align_col);
            try prettyEntry(S, view.kvs.?[j]);
            j += 1;
        }
    } else {
        // The sort indices for every dictionary on the recursion stack share
        // one scratch allocation, each nesting level taking the slice above
        // the level below it.
        var mincap: i64 = @as(i64, @intCast(len)) + @as(i64, ks_start);
        if (mincap > std.math.maxInt(i32)) {
            truncated = true;
            len = 0;
            mincap = ks_start;
        }
        if (S.keysort_capacity < mincap) {
            S.keysort_capacity = if (mincap >= std.math.maxInt(i32) / 2)
                std.math.maxInt(i32)
            else
                @intCast(mincap * 2);
            S.keysort_buffer = @ptrCast(@alignCast(gc_alloc.srealloc(
                S.keysort_buffer,
                @sizeOf(i32) * @as(usize, @intCast(S.keysort_capacity)),
            )));
            if (S.keysort_buffer == null) fatal.outOfMemory();
        }

        _ = utils.sortedKeys(view.kvs.?, @intCast(view.cap), if (S.keysort_buffer) |buf| buf + @as(usize, @intCast(ks_start)) else null);
        S.keysort_start += @intCast(len);
        if (!S.flags.notrunc and len > dict_limit) {
            len = dict_limit;
            truncated = true;
        }

        for (0..len) |i| {
            try if (i != 0) printNewline(S, align_col);
            // A nonzero `len` forces `mincap` above `keysort_capacity` unless
            // the capacity is already nonzero, and a nonzero capacity means
            // some level allocated the buffer and checked it, so it is here.
            const buf = S.keysort_buffer orelse unreachable;
            const j = buf[i + @as(usize, @intCast(ks_start))];
            try prettyEntry(S, view.kvs.?[@intCast(j)]);
        }
    }

    if (truncated) {
        try printNewline(S, align_col);
        try pushEllipsis(S);
    }
    S.keysort_start = ks_start;
}

/// One key and its value, a space apart.
fn prettyEntry(S: *Pretty, kv: tables.Keyval) raise.Error!void {
    try prettyOne(S, kv.key);
    try S.pushByte(' ');
    S.align_col += 1;
    try prettyOne(S, kv.value);
}

/// An array or a tuple.
fn prettyIndexed(S: *Pretty, x: repr.Value) raise.Error!void {
    const isarray = repr.checkType(x, repr.Tag.array);
    const arr = args_core.items(x).?;
    const bracketed = !isarray and tuples.isBracketed(tuples.head(arr.ptr));

    const opener: [*:0]const u8 = if (isarray) "@[" else if (bracketed) "[" else "(";
    const closer: u8 = if (isarray or bracketed) ']' else ')';
    try S.pushCstring(opener);
    S.align_col += @intCast(std.mem.len(opener));
    const align_col = S.align_col;
    S.leaf_align = align_col;

    S.depth -= 1;
    if (S.depth == 0) {
        try pushEllipsis(S);
    } else if (arr.len > array_limit and !S.flags.notrunc) {
        // Three from each end, with the elision between them.
        for (0..3) |i| {
            try if (i != 0) printNewline(S, align_col);
            try prettyOne(S, arr[i]);
        }
        try printNewline(S, align_col);
        try pushEllipsis(S);
        // `array_limit` is 160 and this arm is `arr.len > array_limit`, so
        // taking three off the end cannot underflow.
        for (arr.len - 3..arr.len) |i| {
            try printNewline(S, align_col);
            try prettyOne(S, arr[i]);
        }
    } else {
        for (0..arr.len) |i| {
            try if (i != 0) printNewline(S, align_col);
            try prettyOne(S, arr[i]);
        }
    }
    S.depth += 1;

    try S.pushByte(closer);
    S.align_col += 1;
}

/// Everything with no structure to walk into, which is what `pp.zig` renders.
/// The alignment is recovered from how much the buffer grew, since that layer
/// counts no columns.
fn prettyLeaf(S: *Pretty, x: repr.Value) raise.Error!void {
    try S.pushColor(if (wrap.isKeyword(x)) keyword_color else type_colors[@intFromEnum(repr.typeOf(x))]);
    if (repr.checkType(x, repr.Tag.buffer) and wrap.toBuffer(x) == S.buffer) {
        // Printing a buffer into itself. Reserve the worst case first, then
        // escape only what was there when printing started, so that the loop
        // does not chase its own output.
        try buffers.ensure(S.buffer, S.buffer.count + S.bufstartlen * 4 + 3, 1);
        try S.pushByte('@');
        // `try`, not an abi. Through a `raise.toAbi` wrapper a raise inside
        // the escape becomes a report nobody consumes: the blank width is used
        // and the outstanding report kills the process at the next scope
        // boundary. Both functions are in this compilation and `prettyLeaf` is
        // already raise-capable, so an ordinary import is enough.
        S.align_col += 1 + try describe.escapeString(S.buffer, S.buffer.slice()[0..@intCast(S.bufstartlen)]);
    } else {
        S.align_col -= @as(i32, @intCast(S.buffer.count));
        try describe.descriptionB(S.buffer, x);
        S.align_col += @as(i32, @intCast(S.buffer.count));
    }
    try S.pushColor(color_reset);
}

/// Renders `x`, recording it as seen and recursing into a container.
fn prettyOne(S: *Pretty, x: repr.Value) raise.Error!void {
    // Record the value as seen, unless it is one of the four types that
    // cannot participate in a cycle and so never needs a marker.
    switch (repr.typeOf(x)) {
        repr.Tag.nil, repr.Tag.number, repr.Tag.symbol, repr.Tag.boolean => {},
        else => {
            const seenid = tables.get(&S.seen, x);
            if (repr.checkType(seenid, repr.Tag.number)) {
                try S.pushColor(cycle_color);
                try S.pushCstring("<cycle ");
                S.align_col += 8 + try integerToStringB(S.buffer, wrap.toInteger(seenid));
                try S.pushByte('>');
                try S.pushColor(color_reset);
                return;
            }
            // The id is the count *before* the insertion, so the first value
            // recorded is `<cycle 0>`.
            _ = tables.put(&S.seen, x, wrap.fromInteger(@intCast(S.seen.count)));
        },
    }

    switch (repr.typeOf(x)) {
        repr.Tag.array, repr.Tag.tuple => try prettyIndexed(S, x),
        repr.Tag.@"struct", repr.Tag.table => try prettyDictionary(S, x),
        else => try prettyLeaf(S, x),
    }

    _ = tables.remove(&S.seen, x);
}

/// Renders the `_name` a prototype may define, which is what makes an
/// object-like table print as `@Name{...}` rather than `@{...}`. A `name` that
/// is no byte sequence prints nothing.
fn pushClassName(S: *Pretty, name: repr.Value) raise.Error!void {
    const n = args_core.bytesView(name) orelse return;
    try S.pushColor(class_color);
    try buffers.pushBytes(S.buffer, n);
    S.align_col += @intCast(n.len);
    try S.pushColor(color_reset);
}

/// The `...` that both truncations and the depth limit write.
fn pushEllipsis(S: *Pretty) raise.Error!void {
    try S.pushCstring("...");
    S.align_col += 3;
}
