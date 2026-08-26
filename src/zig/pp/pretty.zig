//! Laying a structure of Janet values out on a page, and writing one back out
//! as JDN.
//!
//! `pp_describe.zig` answers what a single value is called. This is everything
//! that needs more than one: the recursion into arrays, tuples, structs and
//! tables, the cycle table that stops it looping, the column arithmetic, the
//! newline backtracking that pulls a short tail back onto its parent's line,
//! the two truncation limits, and the key sort that makes a dictionary print
//! the same way twice.
//!
//! ## Two printers, one state record
//!
//! `struct pretty` serves both the pretty printer and the JDN writer, and they
//! share almost nothing else: JDN has no width, no colour, no alignment and no
//! truncation, and it *fails* on values the pretty printer renders happily —
//! a function, a fiber, an abstract, a keyword that would not read back. The
//! record is shared because the C shares it, and because `seen` and the buffer
//! are genuinely common to both.
//!
//! ## What raises, and where the seam puts it
//!
//! One thing here raises: a value with no JDN form. `print_jdn_one` *reports*
//! that upwards as a flag, exactly as in C, and only the perimeter turns the
//! flag into a panic — so the recursion carries no error union and the message
//! is written once.
//!
//! The perimeter is two functions, and both are exported, because
//! `pp_format.zig` is a separate object reached across the C ABI and an error
//! union cannot cross a subsystem seam. `janet_zig_pp_jdn_impl` is therefore a
//! **panicking abi**: it raises by jumping, which is what the C original does
//! across the same boundary and what `-Dpp-format=c` still expects. That jump
//! crosses `pp_format.zig`'s frames, which is why that file is jump-transparent
//! too and holds nothing.
//!
//! ## The marker, and the two allocations it strands
//!
//! `janet_table_put` hashes a key that may be abstract, `janet_description_b`
//! runs an abstract type's `tostring`, and both can panic through here. The
//! `seen` table and the key-sort scratch are then stranded — the same two
//! allocations the C original strands at the same two calls, because
//! `janet_table_deinit` sits after `janet_pretty_one` there as it does here.
//! Reproduced, not introduced.

const std = @import("std");
const options = @import("options");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const describe = @import("../pp.zig");
const structs = @import("../value/structs.zig");
const tables = @import("../value/tables.zig");
const gc_alloc = @import("../gc.zig");
const utils = @import("../utils.zig");
const kind = @import("../value/helpers/kind.zig");
const wrap = @import("../value/helpers/wrap.zig");
const args_core = @import("../args.zig");
const fatal = @import("../fatal.zig");
const value = @import("../value.zig");
const buffers = @import("../value/buffers.zig");

/// `BUFSIZE`.
const bufsize = 64;

/// `JANET_COLUMNS`: the page width a `%p` with no explicit width gets.
const columns_default: c_int = 80;

/// The two truncation limits and the point past which sorting keys is
/// abandoned as not worth it.
const dict_limit: i32 = 30;
const dict_keysort_limit: i32 = 2000;
const array_limit: i32 = 160;

const pretty_color: c_int = 1;
const pretty_oneline: c_int = 2;
const pretty_notrunc: c_int = 4;

extern fn janet_valid_utf8(str: [*]const u8, len: i32) callconv(.c) c_int;
extern fn janet_is_symbol_char(byte: u8) callconv(.c) c_int;
extern fn janet_buffer_dtostr(buffer: *types.JanetBuffer, x: f64) callconv(.c) void;

// ----------------------------------------------------------------- colouring

const cycle_color = "\x1B[36m";
const class_color = "\x1B[34m";
const color_reset = "\x1B[0m";

/// One escape per `JanetType`, in `JanetType` order — which starts at
/// `JANET_NUMBER`, not at `JANET_NIL`.
const type_colors = [16][*:0]const u8{
    "\x1B[32m", // number
    "\x1B[36m", // nil
    "\x1B[36m", // boolean
    "\x1B[36m", // fiber
    "\x1B[35m", // string
    "\x1B[34m", // symbol
    "\x1B[33m", // keyword
    "\x1B[36m", // array
    "\x1B[36m", // tuple
    "\x1B[36m", // table
    "\x1B[36m", // struct
    "\x1B[35m", // buffer
    "\x1B[36m", // function
    "\x1B[36m", // cfunction
    "\x1B[36m", // abstract
    "\x1B[36m", // pointer
};

// -------------------------------------------------------------- the printer

/// `struct pretty` in `src/core/pp.c`.
const Pretty = struct {
    buffer: *types.JanetBuffer,
    depth: c_int,
    width: c_int,
    align_col: c_int,
    leaf_align: c_int,
    flags: c_int,
    bufstartlen: i32,
    lookback_barrier: i32,
    keysort_buffer: ?[*]i32,
    keysort_capacity: i32,
    keysort_start: i32,
    seen: types.JanetTable,

    inline fn has(self: *const Pretty, flag: c_int) bool {
        return (self.flags & flag) != 0;
    }

    inline fn pushByte(self: *Pretty, byte: u8) raise.Raising(void) {
        try buffers.pushU8(self.buffer, byte);
    }

    inline fn pushCstring(self: *Pretty, str: [*:0]const u8) raise.Raising(void) {
        try buffers.pushCString(self.buffer, str);
    }

    /// Emit a colour escape, or nothing when the build is not colouring.
    inline fn pushColor(self: *Pretty, color: [*:0]const u8) raise.Raising(void) {
        try if (self.has(pretty_color)) self.pushCstring(color);
    }
};

/// `janet_wrap_integer`, written out rather than called. `janet.h` declares
/// the function beside its macro and `wrap.c` defines it only for the two
/// nanbox layouts, so a tagged build has no such symbol and a Zig caller — which
/// cannot use the macro — does not link. `value_access.zig` writes it out for
/// the same reason and `FOUND.md` has the defect.
inline fn wrapInteger(x: i32) types.Janet {
    return wrap.fromNumber(@floatFromInt(x));
}

/// `count_dig10`, which expects a non-positive `x`. Counting on the negative
/// side is what lets `INT32_MIN` be counted at all.
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

/// `integer_to_string_b`. Returns the number of bytes written, which is what
/// the cycle marker adds to its alignment.
///
/// The digits are produced from the negative side for the same reason
/// `countDig10` counts there: negating `INT32_MIN` overflows and negating the
/// rest does not, so the loop works in the range that holds every input.
fn integerToStringB(buffer: *types.JanetBuffer, val: i32) raise.Raising(i32) {
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
    buffer.count += len + neg;
    return len + neg;
}

/// `contains_bad_chars`. A symbol or keyword that fails this has no JDN form,
/// because reading the printed text back would not produce the same value.
fn containsBadChars(sym: types.JanetString, issym: bool) bool {
    const len = types.stringHead(sym).length;
    if (len != 0 and issym and sym[0] >= '0' and sym[0] <= '9') return true;
    if (janet_valid_utf8(sym, len) == 0) return true;
    var i: i32 = 0;
    while (i < len) : (i += 1) {
        if (janet_is_symbol_char(sym[@intCast(i)]) == 0) return true;
    }
    return false;
}

// ------------------------------------------------------------------- the JDN

/// `print_jdn_one`. Reports failure rather than raising it: `true` means the
/// value has no JDN representation, and the perimeter is what panics.
///
/// Depth is a parameter here rather than a field of the record, because JDN
/// counts down a separate recursion from the pretty printer's.
fn printJdnOne(S: *Pretty, x: types.Janet, depth: c_int) raise.Raising(bool) {
    if (depth == 0) return true;
    switch (kind.typeOf(x)) {
        constants.JANET_NIL, constants.JANET_BOOLEAN, constants.JANET_BUFFER, constants.JANET_STRING => {
            try describe.descriptionB(S.buffer, x);
        },
        constants.JANET_NUMBER => {
            try buffers.ensure(S.buffer, S.buffer.count + bufsize, 2);
            const num = wrap.toNumber(x);
            // Neither has a JDN spelling that reads back as itself.
            if (std.math.isNan(num)) return true;
            if (std.math.isInf(num)) return true;
            janet_buffer_dtostr(S.buffer, num);
        },
        constants.JANET_SYMBOL, constants.JANET_KEYWORD => {
            if (containsBadChars(wrap.toKeyword(x), kind.typeOf(x) == constants.JANET_SYMBOL)) return true;
            try describe.descriptionB(S.buffer, x);
        },
        constants.JANET_TUPLE => {
            const t = wrap.toTuple(x);
            const bracketed = (types.tupleHead(t).gc.flags & constants.JANET_TUPLE_FLAG_BRACKETCTOR) != 0;
            try S.pushByte(if (bracketed) '[' else '(');
            var i: i32 = 0;
            while (i < types.tupleHead(t).length) : (i += 1) {
                try if (i != 0) S.pushByte(' ');
                if (try printJdnOne(S, t[@intCast(i)], depth - 1)) return true;
            }
            try S.pushByte(if (bracketed) ']' else ')');
        },
        constants.JANET_ARRAY => {
            _ = tables.put(&S.seen, x, wrap.fromTrue());
            const a = wrap.toArray(x);
            try S.pushCstring("@[");
            var i: i32 = 0;
            while (i < a.*.count) : (i += 1) {
                try if (i != 0) S.pushByte(' ');
                if (try printJdnOne(S, a.*.data.?[@intCast(i)], depth - 1)) return true;
            }
            try S.pushByte(']');
        },
        constants.JANET_TABLE => {
            _ = tables.put(&S.seen, x, wrap.fromTrue());
            const tab = wrap.toTable(x);
            try S.pushCstring("@{");
            if (try printJdnKvs(S, tab.*.data.?, tab.*.capacity, depth)) return true;
            try S.pushByte('}');
        },
        constants.JANET_STRUCT => {
            const st = wrap.toStruct(x);
            try S.pushByte('{');
            if (try printJdnKvs(S, st, types.structHead(st).capacity, depth)) return true;
            try S.pushByte('}');
        },
        else => return true,
    }
    return false;
}

/// The body the table and struct cases share. In C it is written out twice
/// over `tab->data`/`tab->capacity` and `st`/`janet_struct_capacity(st)`; the
/// two copies are identical once those two expressions are parameters.
fn printJdnKvs(S: *Pretty, kvs: [*]const types.JanetKV, capacity: i32, depth: c_int) raise.Raising(bool) {
    var first = true;
    var i: i32 = 0;
    while (i < capacity) : (i += 1) {
        const kv = &kvs[@intCast(i)];
        if (kind.checkType(kv.key, constants.JANET_NIL) != 0) continue;
        try if (!first) S.pushByte(' ');
        first = false;
        if (try printJdnOne(S, kv.key, depth - 1)) return true;
        try S.pushByte(' ');
        if (try printJdnOne(S, kv.value, depth - 1)) return true;
    }
    return false;
}

// ------------------------------------------------------- the layout pass

/// `backtrack_newlines`. Having just closed a bracket, walk back over what was
/// written and, if the whole tail would fit inside the page width, pull it up
/// onto one line by deleting the newlines and their indentation.
///
/// The walk stops at `lookback_barrier`, which is where the caller's own text
/// ended: `%p` writing into a buffer that already holds output must not reflow
/// what was there before it.
fn backtrackNewlines(S: *const Pretty) void {
    if (S.has(pretty_oneline) or S.buffer.count <= 0) return;
    switch (S.buffer.data.?[@intCast(S.buffer.count - 1)]) {
        ')', '}', ']' => {},
        else => return,
    }

    var removed: i32 = 0;
    const old_count = S.buffer.count;
    var offset = old_count;
    const b0 = S.lookback_barrier;
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
            if (S.has(pretty_color) and at[0] == 'm') {
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

    S.buffer.count -= removed;
    var i = offset;
    var read = offset;
    while (i < S.buffer.count) : (i += 1) {
        if (S.buffer.data.?[@intCast(read)] == '\n') {
            S.buffer.data.?[@intCast(i)] = ' ';
            // Skip the newline and the indentation that followed it. The
            // single space just written is what the whole run collapses to.
            read += 1;
            while (S.buffer.data.?[@intCast(read)] == ' ') {
                if (read >= old_count) fatal.fatal("bad replacement of newline");
                read += 1;
            }
        } else {
            S.buffer.data.?[@intCast(i)] = S.buffer.data.?[@intCast(read)];
            read += 1;
        }
    }
}

/// `print_newline`. In one-line mode a separator is a space and nothing else
/// happens; otherwise this is where the reflow attempt is made.
fn printNewline(S: *Pretty, align_col: c_int) raise.Raising(void) {
    if (S.has(pretty_oneline)) {
        try S.pushByte(' ');
        return;
    }
    backtrackNewlines(S);
    try S.pushByte('\n');
    S.align_col = align_col;
    S.leaf_align = align_col;
    var i: c_int = 0;
    while (i < S.align_col) : (i += 1) try S.pushByte(' ');
}

/// The `...` that both truncations and the depth limit write.
fn pushEllipsis(S: *Pretty) raise.Raising(void) {
    try S.pushCstring("...");
    S.align_col += 3;
}

/// `janet_pretty_one`.
fn prettyOne(S: *Pretty, x: types.Janet) raise.Raising(void) {
    // Record the value as seen, unless it is one of the four types that
    // cannot participate in a cycle and so never needs a marker.
    switch (kind.typeOf(x)) {
        constants.JANET_NIL, constants.JANET_NUMBER, constants.JANET_SYMBOL, constants.JANET_BOOLEAN => {},
        else => {
            const seenid = tables.get(&S.seen, x);
            if (kind.checkType(seenid, constants.JANET_NUMBER) != 0) {
                try S.pushColor(cycle_color);
                try S.pushCstring("<cycle ");
                S.align_col += 8 + try integerToStringB(S.buffer, wrap.toInteger(seenid));
                try S.pushByte('>');
                try S.pushColor(color_reset);
                return;
            }
            // The id is the count *before* the insertion, so the first value
            // recorded is `<cycle 0>`.
            _ = tables.put(&S.seen, x, wrapInteger(S.seen.count));
        },
    }

    switch (kind.typeOf(x)) {
        constants.JANET_ARRAY, constants.JANET_TUPLE => try prettyIndexed(S, x),
        constants.JANET_STRUCT, constants.JANET_TABLE => try prettyDictionary(S, x),
        else => try prettyLeaf(S, x),
    }

    _ = tables.remove(&S.seen, x);
}

/// Everything with no structure to walk into, which is what `pp_describe.zig`
/// renders. The alignment is recovered from how much the buffer grew, since
/// that layer counts nothing.
fn prettyLeaf(S: *Pretty, x: types.Janet) raise.Raising(void) {
    try S.pushColor(type_colors[kind.typeOf(x)]);
    if (kind.checkType(x, constants.JANET_BUFFER) != 0 and wrap.toBuffer(x) == S.buffer) {
        // Printing a buffer into itself. Reserve the worst case first, then
        // escape only what was there when printing started, so that the loop
        // does not chase its own output.
        try buffers.ensure(S.buffer, S.buffer.count + S.bufstartlen * 4 + 3, 1);
        try S.pushByte('@');
        // `try`, not the abi. This read `describe.escapeString` -- the
        // `raise.reported` wrapper -- until Phase 11 Part 5 deleted it, and
        // that was a crossing rather than a choice: a raise inside the escape
        // became a report *nobody consumed*, so the blank width was used and
        // the leak surfaced at the next scope boundary's assertion. Both
        // functions are in this compilation, `prettyLeaf` is already
        // `raise.Raising`, and `raise.crossing`'s note says of the whole
        // family that each is "an ordinary import away from not needing this
        // at all". This is one of them.
        S.align_col += 1 + try describe.escapeStringImpl(S.buffer, S.buffer.data.?[0..@intCast(S.bufstartlen)]);
    } else {
        S.align_col -= S.buffer.count;
        try describe.descriptionB(S.buffer, x);
        S.align_col += S.buffer.count;
    }
    try S.pushColor(color_reset);
}

/// An array or a tuple.
fn prettyIndexed(S: *Pretty, x: types.Janet) raise.Raising(void) {
    var arr: ?[*]const types.Janet = null;
    var len: i32 = 0;
    const isarray = kind.checkType(x, constants.JANET_ARRAY) != 0;
    _ = args_core.indexedView(x, &arr, &len);
    const bracketed = !isarray and (types.tupleHead(arr.?).gc.flags & constants.JANET_TUPLE_FLAG_BRACKETCTOR) != 0;

    const opener: [*:0]const u8 = if (isarray) "@[" else if (bracketed) "[" else "(";
    const closer: u8 = if (isarray or bracketed) ']' else ')';
    try S.pushCstring(opener);
    S.align_col += @intCast(std.mem.len(opener));
    const align_col = S.align_col;
    S.leaf_align = align_col;

    S.depth -= 1;
    if (S.depth == 0) {
        try pushEllipsis(S);
    } else if (len > array_limit and !S.has(pretty_notrunc)) {
        // Three from each end, with the elision between them.
        var i: i32 = 0;
        while (i < 3) : (i += 1) {
            try if (i != 0) printNewline(S, align_col);
            try prettyOne(S, arr.?[@intCast(i)]);
        }
        try printNewline(S, align_col);
        try pushEllipsis(S);
        i = len - 3;
        while (i < len) : (i += 1) {
            try printNewline(S, align_col);
            try prettyOne(S, arr.?[@intCast(i)]);
        }
    } else {
        var i: i32 = 0;
        while (i < len) : (i += 1) {
            try if (i != 0) printNewline(S, align_col);
            try prettyOne(S, arr.?[@intCast(i)]);
        }
    }
    S.depth += 1;

    try S.pushByte(closer);
    S.align_col += 1;
}

/// The `_name` a prototype may carry, which is what makes an object-like table
/// print as `@Name{...}` rather than `@{...}`.
fn pushClassName(S: *Pretty, name: types.Janet) raise.Raising(void) {
    var n: ?[*]const u8 = undefined;
    var len: i32 = 0;
    if (args_core.bytesView(name, &n, &len) == 0) return;
    try S.pushColor(class_color);
    try buffers.pushBytes(S.buffer, n.?[0..@intCast(len)]);
    S.align_col += len;
    try S.pushColor(color_reset);
}

/// A struct or a table.
fn prettyDictionary(S: *Pretty, x: types.Janet) raise.Raising(void) {
    if (kind.checkType(x, constants.JANET_TABLE) != 0) {
        const t = wrap.toTable(x);
        S.align_col += 1;
        try S.pushCstring("@");
        if (t.*.proto) |proto| {
            try pushClassName(S, tables.get(proto, value.fromBytes("_name", .keyword)));
        }
    } else {
        const st = wrap.toStruct(x);
        if (types.structHead(st).proto) |proto| {
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
fn prettyEntries(S: *Pretty, x: types.Janet, align_col: c_int) raise.Raising(void) {
    var kvs: ?[*]const types.JanetKV = null;
    var len: i32 = 0;
    var cap: i32 = 0;
    _ = args_core.dictionaryView(x, &kvs, &len, &cap);
    const ks_start = S.keysort_start;
    var truncated = false;

    if (len > dict_keysort_limit) {
        // Too large to be worth sorting: print in storage order, and print
        // only the head of it unless truncation is off.
        if (!S.has(pretty_notrunc) and len > dict_limit) {
            len = dict_limit;
            truncated = true;
        }
        var j: i32 = 0;
        var i: i32 = 0;
        while (i < len) : (i += 1) {
            while (kind.checkType(kvs.?[@intCast(j)].key, constants.JANET_NIL) != 0) j += 1;
            try if (i != 0) printNewline(S, align_col);
            try prettyEntry(S, kvs.?[@intCast(j)]);
            j += 1;
        }
    } else {
        // The sort indices for every dictionary on the recursion stack share
        // one scratch allocation, each nesting level taking the slice above
        // the one below it.
        var mincap: i64 = @as(i64, len) + @as(i64, ks_start);
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

        _ = utils.sortedKeys(kvs.?, cap, if (S.keysort_buffer) |buf| buf + @as(usize, @intCast(ks_start)) else null);
        S.keysort_start += len;
        if (!S.has(pretty_notrunc) and len > dict_limit) {
            len = dict_limit;
            truncated = true;
        }

        var i: i32 = 0;
        while (i < len) : (i += 1) {
            try if (i != 0) printNewline(S, align_col);
            const j = S.keysort_buffer.?[@intCast(i + ks_start)];
            try prettyEntry(S, kvs.?[@intCast(j)]);
        }
    }

    if (truncated) {
        try printNewline(S, align_col);
        try pushEllipsis(S);
    }
    S.keysort_start = ks_start;
}

fn prettyEntry(S: *Pretty, kv: types.JanetKV) raise.Raising(void) {
    try prettyOne(S, kv.key);
    try S.pushByte(' ');
    S.align_col += 1;
    try prettyOne(S, kv.value);
}

// ------------------------------------------------------------- the perimeter

/// The two perimeters share this, as they share the record.
///
/// `leaf_align` is set to zero here where the C sets it to nothing at all:
/// `janet_pretty_` and `janet_jdn_` assign every other field of a `struct
/// pretty` declared on the stack and leave this one uninitialised. It is not
/// reachable before it is written in any case that could be constructed — the
/// only reader is `backtrackNewlines`, which returns before it unless the
/// buffer ends in a closing bracket, and anything that puts one there has gone
/// through a container and written the field. Zero rather than `undefined`,
/// because reproducing an uninitialised read reproduces nothing.
fn initState(buffer: ?*types.JanetBuffer, depth: c_int, width: c_int, flags: c_int, startlen: i32, lookback_barrier: i32) Pretty {
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

/// `janet_pretty_`, which `pp_format.zig` reaches `%p` and its seven siblings
/// through -- as an import rather than across the C ABI.
///
/// It *does* raise since Phase 10 Part 17c, and it did before: the buffer
/// pushes underneath it can overflow. What changed is that the raise is
/// returned rather than jumped, so the C convention came off the signature —
/// nothing calls this across the ABI, and an error union could not cross it if
/// anything did.
pub fn prettyBuffer(
    buffer: ?*types.JanetBuffer,
    depth: c_int,
    width: c_int,
    flags: c_int,
    x: types.Janet,
    startlen: i32,
    lookback_barrier: i32,
) raise.Raising(*types.JanetBuffer) {
    var S = initState(buffer, depth, width, flags, startlen, lookback_barrier);
    try prettyOne(&S, x);
    backtrackNewlines(&S);
    tables.deinit(&S.seen);
    return S.buffer;
}

pub fn prettyPublic(buffer: ?*types.JanetBuffer, depth: c_int, flags: c_int, x: types.Janet) *types.JanetBuffer {
    const start: i32 = if (buffer) |b| b.count else 0;
    return raise.reported(prettyBuffer(buffer, depth, columns_default, flags, x, start, start));
}

/// `janet_jdn_`. The one raise in this file, and the reason `print_jdn_one`
/// reports rather than raises: the message is written once, here.
///
/// `pp_format.zig` imports this and `try`s it. It was a **panicking abi** when
/// the two were separate objects, because an error union cannot cross a C-ABI
/// seam and a selector's seam is the C ABI; folding them under one selector is
/// what lets the JDN failure propagate as an error instead of as a jump through
/// the formatter's frames.
pub fn jdnImpl(
    buffer: ?*types.JanetBuffer,
    depth: c_int,
    x: types.Janet,
    startlen: i32,
    lookback_barrier: i32,
) raise.Raising(*types.JanetBuffer) {
    var S = initState(buffer, depth, 0, 0, startlen, lookback_barrier);
    const failed = printJdnOne(&S, x, depth);
    tables.deinit(&S.seen);
    if (try failed) return raise.panic("could not print to jdn format");
    return S.buffer;
}

// `janet_jdn` and its `raise.panicking` abi stood here, with a comment saying
// nothing in the tree called it. **That was wrong by one**, and Phase 11 Part 5
// found out by deleting it: `test/pp_pretty.c` hand-declared the symbol -- no
// header has ever carried it -- and was its only caller anywhere. The contract
// is `test/pp_pretty.zig` now, inside this compilation, so it calls `jdnImpl`
// and takes the error. The wrapper that fixed `startlen` and the lookback
// barrier to the buffer's current count went with it; the contract passes both
// explicitly, which is what every real caller does through the formatter.

// A subsystem's exports follow its selector, which is what lets a *contract*
// module root itself at one of these files and compile the generic code under
// test without redefining the library's symbols. `root.zig` gates the import
// on the same flag, so the runtime is unaffected.
