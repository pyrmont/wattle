//! Parsing expression grammars: the matcher, the compiler that feeds it, the
//! bytecode verifier that guards the unmarshalled form, and the six
//! cfunctions over all three.
//!
//! One file, because the compiler emits the bytecode the matcher runs and the
//! verifier accepts, so the three share a private instruction encoding that
//! appears in no header and has no other consumer. A split would put a
//! boundary between two halves of one instruction set.
//!
//! ## The selector could not be called `-Dpeg`
//!
//! `-Dpeg` already exists and is a *feature* flag: it decides whether PEG
//! support is compiled at all, and `peg.c` is one `#ifdef JANET_PEG` from its
//! first line to its last. A selector cannot share the name, so this one is
//! `-Dpeg-engine`. `-Dpeg-core` was the other candidate and was rejected
//! because `core` means something specific in this tree -- `io-core`,
//! `ev-core`, `asm-core` and `parser-core` all name a kernel with its
//! cfunction surface left in C -- and this increment moves the surface too.
//!
//! The feature flag also gates the object: `build.zig` builds this file only
//! when `-Dpeg` is on, because `JanetPeg` and `janet_peg_type` are themselves
//! declared inside `janet.h`'s `#ifdef JANET_PEG` and a `-Dpeg=false` build has
//! no types for this file to name.
//!
//! ## Why this file is jump-transparent
//!
//! Every raise this file *decides* returns an error, as decisions 1 and 3
//! require. Three kinds of call inside the matcher still jump past these frames
//! whatever this file does:
//!
//!  - `janet_array_push` and `janet_buffer_push_u8`, reached from `pushcap` on
//!    almost every capturing rule;
//!  - `janet_call` and a raw `JanetCFunction`, which `(cmt ...)` and
//!    `(/ ...)` invoke with the captures so far -- arbitrary Janet code in the
//!    middle of the matcher's own recursion;
//!  - `janet_abstract`, `janet_table_put` and the other allocators the
//!    compiler reaches.
//!
//! The second is the interesting one and it is not going away with a later
//! increment: a matchtime function is user code, and user code raises.
//!
//! ## Two recursions, two depth counters, and they are not the same counter
//!
//! `PegState.depth` bounds the *matcher* and is reset per call by
//! `pegCallReset`, so `peg/find` gets a fresh budget at every offset it tries.
//! `Builder.depth` bounds the *compiler* and is not reset. Both start at
//! `JANET_RECURSION_GUARD` and they count in opposite directions in the
//! source -- `down1` pre-decrements and compares against zero, `Builder.depth`
//! post-decrements -- which is preserved rather than tidied because the
//! off-by-one is observable in the message a deep grammar produces.
//!
//! ## What the verifier is for
//!
//! A compiled peg is an abstract type with a `marshal` and an `unmarshal`
//! callback, so peg bytecode arrives from untrusted bytes exactly as
//! marshalled values do. `pegUnmarshal` therefore walks every instruction
//! before returning, checking that each rule index lands inside the bytecode,
//! each constant index inside the constants, and that no word is reachable as a
//! rule operand without also being an instruction start. The matcher trusts
//! that walk completely: nothing in `pegRule` bounds-checks a rule index.

const std = @import("std");
const corefn = @import("corefn");
const raise = @import("raise");
const pp_format = @import("pp/format.zig");
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const c = @import("cabi");
const stdio = @import("stdio.zig");
const pp_describe = @import("pp.zig");
const registry = @import("registry.zig");
const marsh = @import("marsh.zig");
const vm_entry = @import("vm/entry.zig");
const abstract_type = @import("abstract_type.zig");
const method_type = @import("method_type.zig");
const config = @import("config");
const structs = @import("value/structs.zig");
const tables = @import("value/tables.zig");
const gc_alloc = @import("gc.zig");
const tuples = @import("value/tuples.zig");
const utils = @import("utils.zig");
const gc_mark = @import("gc/mark.zig");
const stretchy = @import("stretchy.zig");
const numscan = @import("scan.zig");
const vm_state = @import("vm/lifecycle.zig");
const wrap = @import("value/helpers/wrap.zig");
const args_core = @import("args.zig");
const fatal = @import("fatal.zig");
const arrays = @import("value/arrays.zig");
const buffers = @import("value/buffers.zig");
const value = @import("value.zig");
const abstracts = @import("value/abstracts.zig");
const inttypes = @import("value/ints.zig");

/// `src/core/util.h`, declared here rather than in `cabi.zig`.
extern fn safe_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void;

const recursion_guard: i32 = config.recursion_guard;

/// Six without `JANET_INT_TYPES` and eight with it, because a `double` capture
/// cannot carry more than 53 bits and the wider widths need a boxed integer to
/// land in.
const max_readint_width: i32 = if (config.int_types) 8 else 6;

/// `JANET_OUT_OF_MEMORY`, which is fatal rather than raising.
inline fn allocated(pointer: ?*anyopaque) ?*anyopaque {
    if (pointer == null) fatal.outOfMemory();
    return pointer;
}

/// `janet_assert`, which prints and aborts. Reached only by a `reserve` that
/// disagrees with the `emit` that closes it, which is a program error in this
/// file rather than anything a grammar can provoke.
inline fn pegAssert(condition: bool, message: [*:0]const u8) void {
    if (!condition) fatal.fatal(message);
}

/// Text positions are compared, not just walked, and Zig has no relational
/// operator on pointers. Every `text < s->text_end` in the C original becomes
/// an address comparison through here.
inline fn at(pointer: [*]const u8) usize {
    return @intFromPtr(pointer);
}

/// `text + n` for an `n` that came out of bytecode. Wrapping rather than
/// checked because that is what C's pointer arithmetic does on a 32-bit host,
/// and because the verifier -- not this arithmetic -- is what keeps `n` sane.
inline fn skip(pointer: [*]const u8, delta: usize) [*]const u8 {
    return @ptrFromInt(@intFromPtr(pointer) +% delta);
}

/// The same, for the signed offset `(> n rule)` carries.
inline fn shift(pointer: [*]const u8, delta: i32) [*]const u8 {
    return @ptrFromInt(@intFromPtr(pointer) +% @as(usize, @bitCast(@as(isize, delta))));
}

/// `s->extrav[index]`, with `index` signed and unchecked.
///
/// Written as address arithmetic rather than as `extrav[@intCast(index)]`
/// because the index can be negative: `(argument)` takes a non-negative
/// integer from the compiler, but crafted bytecode does not go through the
/// compiler and the matcher does not check. `FOUND.md` has the entry. An
/// `@intCast` here would turn a silent out-of-bounds read into a Zig panic in
/// a safety-checked build and into something worse in a fast one, which is a
/// change in behaviour rather than a reproduction of it.
inline fn extraAt(extrav: ?[*]const repr.Value, index: i32) repr.Value {
    const offset = @as(usize, @bitCast(@as(isize, index))) *% @sizeOf(repr.Value);
    const element: *align(@alignOf(repr.Value)) const repr.Value = @ptrFromInt(@intFromPtr(extrav.?) +% offset);
    return element.*;
}

/// The handle `janet_dynprintf` falls back to when `:err` is unbound.
/// `trace_frames.zig` records why `stderr` cannot be named from Zig portably
/// and why `io.c` keeps this one-line accessor.
/// `janet_wrap_integer`, written out rather than called. `janet.h` declares the
/// function beside its macro and `wrap.c` defines it only for the two nanbox
/// layouts, so a tagged build has no such symbol and a Zig caller -- which
/// cannot use the macro -- does not link. `marsh.zig`, `pp_pretty.zig` and
/// `value_access.zig` write it out for the same reason and `FOUND.md` has the
/// defect.
inline fn wrapInteger(x: i32) repr.Value {
    return wrap.fromNumber(@floatFromInt(x));
}

/// `janet_eprintf`, a variadic macro over `janet_dynprintf` that translate-c
/// cannot bring across. Written out here the same way `trace_frames.zig`
/// writes it out, except that the format is a runtime value: `(??)` picks
/// between a coloured and a plain rendering per line.
inline fn eprintf(comptime format: [:0]const u8, args: anytype) void {
    // `pp/format.dynprintf` can raise: `(dyn :err)` may be a Janet function, and
    // calling it can. This position cannot carry one -- it is a trace or a
    // diagnostic on the way out -- so the raise is reported.
    raise.reported(pp_format.dynprintf("err", @ptrCast(@alignCast(stdio.err())), format, args));
}

// ==========================================================================
// The matcher
// ==========================================================================

/// Whether captures are collected as values or concatenated into `scratch`.
/// `(% ...)` and `(<- ...)` swap between them and put the old one back.
const Mode = enum(c_int) {
    normal = 0,
    accumulate = 1,
};

/// Captured patterns and match state. Internal to this file in C and in Zig,
/// so it is a native struct: nothing outside ever sees the layout.
const PegState = struct {
    text_start: [*]const u8,
    /// Restricted by `(sub ...)`, `(til ...)` and `(split ...)` while their
    /// inner pattern runs, and put back afterwards.
    text_end: [*]const u8,
    /// The real end of input, which the line map needs whatever `text_end`
    /// currently says.
    outer_text_end: [*]const u8,
    bytecode: [*]const u32,
    constants: [*]const repr.Value,
    captures: *types.JanetArray,
    scratch: *types.JanetBuffer,
    tags: *types.JanetBuffer,
    tagged_captures: *types.JanetArray,
    extrav: ?[*]const repr.Value,
    linemap: ?[*]i32,
    extrac: i32,
    depth: i32,
    linemaplen: i32,
    has_backref: i32,
    mode: Mode,

    inline fn ruleAt(s: *const PegState, index: u32) [*]const u32 {
        return s.bytecode + index;
    }
};

/// Enough to rewind the three capture stacks when a branch fails.
const CapState = struct {
    cap: i32,
    tcap: i32,
    scratch: i32,
};

fn capSave(s: *PegState) CapState {
    return .{
        .scratch = s.scratch.count,
        .cap = s.captures.count,
        .tcap = s.tagged_captures.count,
    };
}

/// Rewind after a failure.
fn capLoad(s: *PegState, cs: CapState) void {
    s.scratch.count = cs.scratch;
    s.captures.count = cs.cap;
    s.tags.count = cs.tcap;
    s.tagged_captures.count = cs.tcap;
}

/// Rewind after a success, keeping the tagged captures so that a later
/// `(-> :tag)` can still find them.
fn capLoadKeept(s: *PegState, cs: CapState) void {
    s.scratch.count = cs.scratch;
    s.captures.count = cs.cap;
}

/// Add a capture, to whichever of the three stacks the current mode and the
/// grammar's use of backrefs call for.
fn pushcap(s: *PegState, capture: repr.Value, tag: u32) raise.Raising(void) {
    if (s.mode == .accumulate) try pp_describe.toStringB(s.scratch, capture);
    if (s.mode == .normal) try arrays.push(s.captures, capture);
    if (s.has_backref != 0) {
        try arrays.push(s.tagged_captures, capture);
        try buffers.pushU8(s.tags, @truncate(tag));
    }
}

/// Line and column, both 1-indexed.
const LineCol = struct {
    line: i32,
    col: i32,
};

/// The line map is built on first use and then kept, because `(line)` and
/// `(column)` are usually either absent from a grammar or all over it.
///
/// It is `janet_smalloc` scratch rather than an owned allocation, and nothing
/// frees it: the collector reclaims scratch at the next unwind, which is what
/// makes the matcher's panic paths harmless.
fn getLinecolFromPosition(s: *PegState, position: i32) LineCol {
    if (s.linemaplen < 0) {
        var newline_count: i32 = 0;
        var cursor = s.text_start;
        while (at(cursor) < at(s.outer_text_end)) : (cursor += 1) {
            if (cursor[0] == '\n') newline_count += 1;
        }
        const mem: [*]i32 = @ptrCast(@alignCast(gc_alloc.smalloc(@sizeOf(i32) * @as(usize, @intCast(newline_count)))));
        var index: usize = 0;
        cursor = s.text_start;
        while (at(cursor) < at(s.outer_text_end)) : (cursor += 1) {
            if (cursor[0] == '\n') {
                mem[index] = @intCast(at(cursor) - at(s.text_start));
                index += 1;
            }
        }
        s.linemaplen = newline_count;
        s.linemap = mem;
    }

    // Binary search for the line, with three departures from the classic
    // shape, all of them the C original's and all of them load-bearing:
    // a newline belongs to the line before it, the not-found case wants the
    // greatest newline index below `position`, and `lo == 0` with a first
    // newline already past `position` means the first line.
    var hi = s.linemaplen;
    var lo: i32 = 0;
    while (lo + 1 < hi) {
        const mid = lo + @divTrunc(hi - lo, 2);
        if (s.linemap.?[@intCast(mid)] >= position) {
            hi = mid;
        } else {
            lo = mid;
        }
    }
    if (s.linemaplen == 0 or (lo == 0 and s.linemap.?[0] >= position)) {
        return .{ .line = 1, .col = position + 1 };
    }
    return .{ .line = lo + 2, .col = position - s.linemap.?[@intCast(lo)] };
}

/// Sign-extend the low `width` bytes of `from`, the way `(int n)` reads them.
fn pegConvertU64S64(from: u64, width: i32) i64 {
    const amount: u6 = @intCast(8 * (8 - width));
    return @as(i64, @bitCast(from << amount)) >> amount;
}

/// Prevent stack overflow. Pre-decrement and compare against zero, so the
/// budget is spent one frame before the message says it is.
inline fn down1(s: *PegState) raise.Raising(void) {
    s.depth -= 1;
    if (s.depth == 0) return raise.panic("peg/match recursed too deeply");
}

inline fn up1(s: *PegState) void {
    s.depth += 1;
}

/// Evaluate a peg rule.
///
/// Pre-condition: `s` is in a valid state. Post-condition: on a match, the
/// address just past the matched text, with every capture on the stacks valid;
/// on no match, null, possibly with extra captures a successful child left
/// behind for the caller to rewind.
///
/// The C original's `tail:` label is the `while (true)` below: a rule that ends
/// in another rule assigns `rule` and `continue`s rather than recursing, which
/// is what keeps `(some ...)` over a long input off the C stack. Every other
/// arm returns, so falling out of the `switch` is not reachable.
fn pegRule(s: *PegState, rule_in: [*]const u32, text_in: [*]const u8) raise.Raising(?[*]const u8) {
    var rule = rule_in;
    var text = text_in;
    while (true) {
        switch (rule[0]) {
            constants.RULE_LITERAL => {
                const len: usize = rule[1];
                if (at(text) +% len > at(s.text_end)) return null;
                const bytes: [*]const u8 = @ptrCast(rule + 2);
                if (len != 0 and !std.mem.eql(u8, text[0..len], bytes[0..len])) return null;
                return skip(text, len);
            },

            constants.RULE_DEBUG => {
                var buffer: [32]u8 = @splat(0);
                const remaining = at(s.outer_text_end) - at(text);
                const shown = @min(remaining, 31);
                @memcpy(buffer[0..shown], text[0..shown]);
                eprintf("?? at [%s] (index %d)\n", .{
                    @as([*]const u8, &buffer),
                    @as(i32, @intCast(at(text) - at(s.text_start))),
                });
                const has_color = repr.truthy(vm_state.dyn("err-color"));
                if (s.scratch.count != 0) {
                    eprintf("accumulate buffer: %v\n", .{wrap.fromBuffer(s.scratch)});
                }
                if (s.captures.count != 0) {
                    eprintf("stack [%d]:\n", .{s.captures.count});
                    var i: i32 = 0;
                    while (i < s.captures.count) : (i += 1) {
                        // Two calls rather than one: the format string is
                        // `comptime` now, so a runtime `has_color` cannot
                        // choose between two of them.
                        const capture = s.captures.slice()[@intCast(i)];
                        if (has_color)
                            eprintf("  [%d]: %M\n", .{ i, capture })
                        else
                            eprintf("  [%d]: %m\n", .{ i, capture });
                    }
                }
                if (s.tagged_captures.count != 0) {
                    eprintf("tag stack [%d]:\n", .{s.tagged_captures.count});
                    var i: i32 = 0;
                    while (i < s.tagged_captures.count) : (i += 1) {
                        const tag = @as(i32, s.tags.slice()[@intCast(i)]);
                        const capture = s.tagged_captures.slice()[@intCast(i)];
                        if (has_color)
                            eprintf("  [%d] tag=%d: %M\n", .{ i, tag, capture })
                        else
                            eprintf("  [%d] tag=%d: %m\n", .{ i, tag, capture });
                    }
                }
                return text;
            },

            constants.RULE_NCHAR => {
                const n: usize = rule[1];
                return if (at(text) +% n > at(s.text_end)) null else skip(text, n);
            },

            constants.RULE_NOTNCHAR => {
                const n: usize = rule[1];
                return if (at(text) +% n > at(s.text_end)) text else null;
            },

            constants.RULE_RANGE => {
                const lo: u8 = @truncate(rule[1]);
                const hi: u8 = @truncate(rule[1] >> 16);
                if (at(text) < at(s.text_end) and text[0] >= lo and text[0] <= hi) return text + 1;
                return null;
            },

            constants.RULE_SET => {
                if (at(text) >= at(s.text_end)) return null;
                const word = rule[1 + (text[0] >> 5)];
                const mask = @as(u32, 1) << @truncate(text[0] & 0x1F);
                return if (word & mask != 0) text + 1 else null;
            },

            constants.RULE_LOOK => {
                const offset: i32 = @bitCast(rule[1]);
                const looked = shift(text, offset);
                if (at(looked) < at(s.text_start) or at(looked) > at(s.text_end)) return null;
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[2]), looked);
                up1(s);
                return if (result != null) text else null;
            },

            constants.RULE_CHOICE => {
                const len = rule[1];
                const args = rule + 2;
                if (len == 0) return null;
                try down1(s);
                const cs = capSave(s);
                var i: u32 = 0;
                while (i < len - 1) : (i += 1) {
                    if (try pegRule(s, s.ruleAt(args[i]), text)) |result| {
                        up1(s);
                        return result;
                    }
                    capLoad(s, cs);
                }
                up1(s);
                rule = s.ruleAt(args[len - 1]);
                continue;
            },

            constants.RULE_SEQUENCE => {
                const len = rule[1];
                const args = rule + 2;
                if (len == 0) return text;
                try down1(s);
                var cursor: ?[*]const u8 = text;
                var i: u32 = 0;
                while (cursor != null and i < len - 1) : (i += 1) {
                    cursor = try pegRule(s, s.ruleAt(args[i]), cursor.?);
                }
                up1(s);
                text = cursor orelse return null;
                rule = s.ruleAt(args[len - 1]);
                continue;
            },

            constants.RULE_IF => {
                const rule_a = s.ruleAt(rule[1]);
                const rule_b = s.ruleAt(rule[2]);
                try down1(s);
                const result = try pegRule(s, rule_a, text);
                up1(s);
                if (result == null) return null;
                rule = rule_b;
                continue;
            },

            constants.RULE_IFNOT => {
                const rule_a = s.ruleAt(rule[1]);
                const rule_b = s.ruleAt(rule[2]);
                try down1(s);
                const cs = capSave(s);
                const result = try pegRule(s, rule_a, text);
                if (result != null) {
                    up1(s);
                    return null;
                }
                capLoad(s, cs);
                up1(s);
                rule = rule_b;
                continue;
            },

            constants.RULE_NOT => {
                const rule_a = s.ruleAt(rule[1]);
                try down1(s);
                const cs = capSave(s);
                const result = try pegRule(s, rule_a, text);
                if (result != null) {
                    up1(s);
                    return null;
                }
                capLoad(s, cs);
                up1(s);
                return text;
            },

            constants.RULE_THRU, constants.RULE_TO => {
                const rule_a = s.ruleAt(rule[1]);
                var next_text: ?[*]const u8 = null;
                const cs = capSave(s);
                try down1(s);
                while (at(text) <= at(s.text_end)) {
                    const cs2 = capSave(s);
                    next_text = try pegRule(s, rule_a, text);
                    if (next_text != null) {
                        if (rule[0] == constants.RULE_TO) capLoad(s, cs2);
                        break;
                    }
                    capLoad(s, cs2);
                    text += 1;
                }
                up1(s);
                if (at(text) > at(s.text_end)) {
                    capLoad(s, cs);
                    return null;
                }
                return if (rule[0] == constants.RULE_TO) text else next_text;
            },

            constants.RULE_BETWEEN => {
                const lo = rule[1];
                const hi = rule[2];
                const rule_a = s.ruleAt(rule[3]);
                var captured: u32 = 0;
                const cs = capSave(s);
                try down1(s);
                while (captured < hi) {
                    const cs2 = capSave(s);
                    const next_text = try pegRule(s, rule_a, text);
                    // The second half is what stops `(any "")` spinning: a rule
                    // that matches nothing counts once and then ends the loop.
                    if (next_text == null or (next_text.? == text and hi == std.math.maxInt(u32))) {
                        capLoad(s, cs2);
                        break;
                    }
                    captured += 1;
                    text = next_text.?;
                }
                up1(s);
                if (captured < lo) {
                    capLoad(s, cs);
                    return null;
                }
                return text;
            },

            // ---------------------------------------------------- capturing

            constants.RULE_GETTAG => {
                const search = rule[1];
                const tag = rule[2];
                var i: i32 = s.tags.count - 1;
                while (i >= 0) : (i -= 1) {
                    if (@as(u32, s.tags.slice()[@intCast(i)]) == search) {
                        try pushcap(s, s.tagged_captures.slice()[@intCast(i)], tag);
                        return text;
                    }
                }
                return null;
            },

            constants.RULE_POSITION => {
                try pushcap(s, wrap.fromNumber(@floatFromInt(at(text) - at(s.text_start))), rule[1]);
                return text;
            },

            constants.RULE_LINE => {
                const lc = getLinecolFromPosition(s, @intCast(at(text) - at(s.text_start)));
                try pushcap(s, wrap.fromNumber(@floatFromInt(lc.line)), rule[1]);
                return text;
            },

            constants.RULE_COLUMN => {
                const lc = getLinecolFromPosition(s, @intCast(at(text) - at(s.text_start)));
                try pushcap(s, wrap.fromNumber(@floatFromInt(lc.col)), rule[1]);
                return text;
            },

            constants.RULE_ARGUMENT => {
                const index: i32 = @bitCast(rule[1]);
                const capture = if (index >= s.extrac) wrap.fromNil() else extraAt(s.extrav, index);
                try pushcap(s, capture, rule[2]);
                return text;
            },

            constants.RULE_CONSTANT => {
                try pushcap(s, s.constants[rule[1]], rule[2]);
                return text;
            },

            constants.RULE_CAPTURE => {
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[1]), text);
                up1(s);
                const matched = result orelse return null;
                const len: i32 = @intCast(at(matched) - at(text));
                // Specialized pushcap - avoid intermediate string creation.
                if (s.has_backref == 0 and s.mode == .accumulate) {
                    try buffers.pushBytes(s.scratch, text[0..@intCast(len)]);
                } else {
                    try pushcap(s, value.fromBytes(text[0..@intCast(len)], .string), rule[2]);
                }
                return matched;
            },

            constants.RULE_CAPTURE_NUM => {
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[1]), text);
                up1(s);
                const matched = result orelse return null;
                const len: i32 = @intCast(at(matched) - at(text));
                var x: f64 = 0.0;
                const base: i32 = @bitCast(rule[2]);
                if (numscan.scanNumberBase(text, len, base, &x) != 0) return null;
                if (s.has_backref == 0 and s.mode == .accumulate) {
                    try buffers.pushBytes(s.scratch, text[0..@intCast(len)]);
                } else {
                    try pushcap(s, wrap.fromNumber(x), rule[3]);
                }
                return matched;
            },

            constants.RULE_ACCUMULATE => {
                const tag = rule[2];
                const oldmode = s.mode;
                if (tag == 0 and oldmode == .accumulate) {
                    rule = s.ruleAt(rule[1]);
                    continue;
                }
                const cs = capSave(s);
                s.mode = .accumulate;
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[1]), text);
                up1(s);
                s.mode = oldmode;
                const matched = result orelse return null;
                const cap = value.fromBytes(s.scratch.slice()[@intCast(cs.scratch)..@intCast(s.scratch.count)], .string);
                capLoadKeept(s, cs);
                try pushcap(s, cap, tag);
                return matched;
            },

            constants.RULE_DROP => {
                const cs = capSave(s);
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[1]), text);
                up1(s);
                const matched = result orelse return null;
                capLoad(s, cs);
                return matched;
            },

            constants.RULE_ONLY_TAGS => {
                const cs = capSave(s);
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[1]), text);
                up1(s);
                const matched = result orelse return null;
                capLoadKeept(s, cs);
                return matched;
            },

            constants.RULE_GROUP => {
                const tag = rule[2];
                const oldmode = s.mode;
                const cs = capSave(s);
                s.mode = .normal;
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[1]), text);
                up1(s);
                s.mode = oldmode;
                const matched = result orelse return null;
                const num_sub_captures = s.captures.count - cs.cap;
                const sub_captures = arrays.new(num_sub_captures);
                safe_memcpy(
                    sub_captures.*.data,
                    s.captures.data.? + @as(usize, @intCast(cs.cap)),
                    @sizeOf(repr.Value) * @as(usize, @intCast(num_sub_captures)),
                );
                sub_captures.*.count = num_sub_captures;
                capLoadKeept(s, cs);
                try pushcap(s, wrap.fromArray(sub_captures), tag);
                return matched;
            },

            constants.RULE_NTH => {
                var nth = rule[1];
                if (nth > std.math.maxInt(i32)) nth = std.math.maxInt(i32);
                const tag = rule[3];
                const oldmode = s.mode;
                const cs = capSave(s);
                s.mode = .normal;
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[2]), text);
                up1(s);
                s.mode = oldmode;
                const matched = result orelse return null;
                const num_sub_captures = s.captures.count - cs.cap;
                if (num_sub_captures <= @as(i32, @intCast(nth))) return null;
                const cap = s.captures.slice()[@intCast(cs.cap + @as(i32, @intCast(nth)))];
                capLoadKeept(s, cs);
                try pushcap(s, cap, tag);
                return matched;
            },

            constants.RULE_SUB => {
                const text_start = text;
                const rule_window = s.ruleAt(rule[1]);
                const rule_subpattern = s.ruleAt(rule[2]);
                try down1(s);
                const window = try pegRule(s, rule_window, text);
                up1(s);
                const window_end = window orelse return null;
                const saved_end = s.text_end;
                s.text_end = window_end;
                try down1(s);
                const next_text = try pegRule(s, rule_subpattern, text_start);
                up1(s);
                s.text_end = saved_end;
                if (next_text == null) return null;
                return window_end;
            },

            constants.RULE_TIL => {
                const rule_terminus = s.ruleAt(rule[1]);
                const rule_subpattern = s.ruleAt(rule[2]);
                var terminus_start = text;
                var terminus_end: ?[*]const u8 = null;
                try down1(s);
                while (at(terminus_start) <= at(s.text_end)) {
                    const cs2 = capSave(s);
                    terminus_end = try pegRule(s, rule_terminus, terminus_start);
                    capLoad(s, cs2);
                    if (terminus_end != null) break;
                    terminus_start += 1;
                }
                up1(s);
                const found = terminus_end orelse return null;
                const saved_end = s.text_end;
                s.text_end = terminus_start;
                try down1(s);
                const matched = try pegRule(s, rule_subpattern, text);
                up1(s);
                s.text_end = saved_end;
                if (matched == null) return null;
                return found;
            },

            constants.RULE_SPLIT => {
                const saved_end = s.text_end;
                const rule_separator = s.ruleAt(rule[1]);
                const rule_subpattern = s.ruleAt(rule[2]);
                var chunk_start = text;
                var chunk_end: [*]const u8 = text;
                while (at(text) <= at(saved_end)) {
                    // Find the next separator, or the end of the text.
                    const cs = capSave(s);
                    try down1(s);
                    while (at(text) <= at(saved_end)) {
                        chunk_end = text;
                        const check = try pegRule(s, rule_separator, text);
                        capLoad(s, cs);
                        if (check) |next| {
                            text = next;
                            break;
                        }
                        text += 1;
                    }
                    up1(s);

                    // Match between splits.
                    s.text_end = chunk_end;
                    try down1(s);
                    const subpattern_end = try pegRule(s, rule_subpattern, chunk_start);
                    up1(s);
                    s.text_end = saved_end;
                    if (subpattern_end == null) return null;

                    // Ensure forward progress.
                    if (text == chunk_start) return null;
                    chunk_start = text;
                }
                s.text_end = saved_end;
                return s.text_end;
            },

            constants.RULE_REPLACE, constants.RULE_MATCHSPLICE, constants.RULE_MATCHTIME => {
                const tag = rule[3];
                const oldmode = s.mode;
                const cs = capSave(s);
                s.mode = .normal;
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[1]), text);
                up1(s);
                s.mode = oldmode;
                const matched = result orelse return null;

                var cap = wrap.fromNil();
                const constant = s.constants[rule[2]];
                switch (repr.typeOf(constant)) {
                    repr.Tag.@"struct" => {
                        if (s.captures.count != 0) {
                            cap = structs.get(
                                wrap.toStruct(constant),
                                s.captures.slice()[@intCast(s.captures.count - 1)],
                            );
                        }
                    },
                    repr.Tag.table => {
                        if (s.captures.count != 0) {
                            cap = tables.get(
                                wrap.toTable(constant),
                                s.captures.slice()[@intCast(s.captures.count - 1)],
                            );
                        }
                    },
                    // Both of these run arbitrary Janet code in the middle of
                    // the matcher's recursion.
                    repr.Tag.cfunction => {
                        cap = try raise.cfunction(wrap.toCfunction(constant))(
                            (s.captures.data.? + @as(usize, @intCast(cs.cap)))[0..@intCast(s.captures.count - cs.cap)],
                        );
                    },
                    repr.Tag.function => {
                        cap = try vm_entry.call(
                            wrap.toFunction(constant),
                            (s.captures.data.? + @as(usize, @intCast(cs.cap)))[0..@intCast(s.captures.count - cs.cap)],
                        );
                    },
                    else => cap = constant,
                }
                capLoadKeept(s, cs);
                if (rule[0] != constants.RULE_REPLACE and !repr.truthy(cap)) return null;
                var elements: ?[*]const repr.Value = null;
                var len: i32 = 0;
                if (rule[0] == constants.RULE_MATCHSPLICE and args_core.indexedView(cap, &elements, &len) != 0) {
                    var i: i32 = 0;
                    while (i < len) : (i += 1) try pushcap(s, elements.?[@intCast(i)], tag);
                } else {
                    try pushcap(s, cap, tag);
                }
                return matched;
            },

            constants.RULE_ERROR => {
                const oldmode = s.mode;
                s.mode = .normal;
                const old_cap = s.captures.count;
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[1]), text);
                up1(s);
                s.mode = oldmode;
                if (result == null) return null;
                if (s.captures.count > old_cap) {
                    return raise.panicv(s.captures.slice()[@intCast(s.captures.count - 1)]);
                }
                const start: i32 = @intCast(at(text) - at(s.text_start));
                const lc = getLinecolFromPosition(s, start);
                return pp_format.panicf("match error at line %d, column %d", .{ lc.line, lc.col });
            },

            constants.RULE_BACKMATCH => {
                const search = rule[1];
                var i: i32 = s.tags.count - 1;
                while (i >= 0) : (i -= 1) {
                    if (@as(u32, s.tags.slice()[@intCast(i)]) != search) continue;
                    const capture = s.tagged_captures.slice()[@intCast(i)];
                    if (!repr.checkType(capture, repr.Tag.string)) return null;
                    const bytes = wrap.toString(capture);
                    const len: usize = @intCast(types.stringHead(bytes).length);
                    if (at(text) +% len > at(s.text_end)) return null;
                    if (len != 0 and !std.mem.eql(u8, text[0..len], bytes[0..len])) return null;
                    return skip(text, len);
                }
                return null;
            },

            constants.RULE_LENPREFIX => {
                const oldmode = s.mode;
                s.mode = .normal;
                const cs = capSave(s);
                try down1(s);
                var next_text = try pegRule(s, s.ruleAt(rule[1]), text);
                up1(s);
                // The C original returns here without putting `mode` back, and
                // that is reproduced rather than fixed: see `FOUND.md`.
                if (next_text == null) return null;
                s.mode = oldmode;
                const num_sub_captures = s.captures.count - cs.cap;
                if (num_sub_captures <= 0) {
                    capLoad(s, cs);
                    return null;
                }
                const lencap = s.captures.slice()[@intCast(cs.cap)];
                if (args_core.checkint(lencap) == 0) {
                    capLoad(s, cs);
                    return null;
                }
                const nrep = wrap.toInteger(lencap);
                // Drop the captures the length pattern made.
                capLoad(s, cs);
                var i: i32 = 0;
                while (i < nrep) : (i += 1) {
                    try down1(s);
                    next_text = try pegRule(s, s.ruleAt(rule[2]), next_text.?);
                    up1(s);
                    if (next_text == null) {
                        capLoad(s, cs);
                        return null;
                    }
                }
                return next_text;
            },

            constants.RULE_READINT => {
                const tag = rule[2];
                const signedness = rule[1] & 0x10;
                const endianness = rule[1] & 0x20;
                const width: i32 = @intCast(rule[1] & 0xF);
                const uwidth: usize = @intCast(width);
                if (at(text) +% uwidth > at(s.text_end)) return null;
                var accum: u64 = 0;
                if (endianness != 0) {
                    var i: usize = 0;
                    while (i < uwidth) : (i += 1) accum = (accum << 8) | text[i];
                } else {
                    var i = width - 1;
                    while (i >= 0) : (i -= 1) accum = (accum << 8) | text[@intCast(i)];
                }

                // Above six bytes a `double` capture would lose precision, so
                // the wider widths need a boxed integer to land in and are
                // only reachable when `JANET_INT_TYPES` provides one.
                var capture_value: repr.Value = undefined;
                if (config.int_types and width > 6) {
                    capture_value = if (signedness != 0)
                        inttypes.wrapS64(pegConvertU64S64(accum, width))
                    else
                        inttypes.wrapU64(accum);
                } else {
                    const double_value: f64 = if (signedness != 0)
                        @floatFromInt(pegConvertU64S64(accum, width))
                    else
                        @floatFromInt(accum);
                    capture_value = wrap.fromNumber(double_value);
                }

                try pushcap(s, capture_value, tag);
                return skip(text, uwidth);
            },

            constants.RULE_UNREF => {
                const tcap = s.tags.count;
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[1]), text);
                up1(s);
                const matched = result orelse return null;
                const final_tcap = s.tags.count;
                // Truncate the tagged captures to exclude the given tag. With
                // no tag, drop all of them.
                var w = tcap;
                if (rule[2] != 0) {
                    var i = tcap;
                    while (i < final_tcap) : (i += 1) {
                        if (s.tags.slice()[@intCast(i)] != @as(u8, @truncate(rule[2]))) {
                            s.tags.slice()[@intCast(w)] = s.tags.slice()[@intCast(i)];
                            s.tagged_captures.slice()[@intCast(w)] = s.tagged_captures.slice()[@intCast(i)];
                            w += 1;
                        }
                    }
                }
                s.tags.count = w;
                s.tagged_captures.count = w;
                return matched;
            },

            else => return raise.panic("unexpected opcode"),
        }
    }
}

// ==========================================================================
// The compiler
// ==========================================================================

const Builder = struct {
    grammar: *types.JanetTable,
    default_grammar: ?*types.JanetTable,
    tags: *types.JanetTable,
    constants: ?[*]repr.Value,
    bytecode: ?[*]u32,
    /// The form currently being compiled, named by every grammar error.
    form: repr.Value,
    depth: c_int,
    nexttag: u32,
    has_backref: c_int,
};

fn builderCleanup(b: *Builder) void {
    stretchy.free(repr.Value, b.constants);
    stretchy.free(u32, b.bytecode);
}

/// Every grammar error goes through here, and every one of them frees the two
/// scratch vectors on the way out.
///
/// That free is why this file has no `errdefer` even where the jump-transparent
/// marker would allow one: the C original does it in one place and so does
/// this, and the raise is the only exit a partially built grammar has.
fn pegPanic(b: *Builder, msg: [*]const u8) raise.Error {
    builderCleanup(b);
    return pp_format.panicf("grammar error in %p, %s", .{ b.form, msg });
}

fn pegPanicf(b: *Builder, comptime format: [:0]const u8, args: anytype) raise.Error {
    // The formatter can raise -- `%v` runs a `tostring` callback -- and that
    // raise is the real one, so it wins over the grammar error below.
    const msg = pp_format.formatc(format, args) catch |err| return err;
    return pegPanic(b, msg);
}

fn pegFixarity(b: *Builder, argc: i32, arity: i32) raise.Raising(void) {
    if (argc != arity) {
        return pegPanicf(b, "expected %d argument%s, got %d", .{
            arity,
            @as([*]const u8, if (arity == 1) "" else "s"),
            argc,
        });
    }
}

fn pegArity(b: *Builder, arity: i32, min: i32, max: i32) raise.Raising(void) {
    if (min >= 0 and arity < min)
        return pegPanicf(b, "arity mismatch, expected at least %d, got %d", .{ min, arity });
    if (max >= 0 and arity > max)
        return pegPanicf(b, "arity mismatch, expected at most %d, got %d", .{ max, arity });
}

fn pegGetset(b: *Builder, x: repr.Value) raise.Raising([*]const u8) {
    if (!repr.checkType(x, repr.Tag.string))
        return pegPanic(b, "expected string for character set");
    return wrap.toString(x);
}

fn pegGetrange(b: *Builder, x: repr.Value) raise.Raising([*]const u8) {
    if (!repr.checkType(x, repr.Tag.string))
        return pegPanic(b, "expected string for character range");
    const str = wrap.toString(x);
    if (types.stringHead(str).length != 2)
        return pegPanicf(b, "expected string to have length 2, got %v", .{x});
    if (str[1] < str[0])
        return pegPanicf(b, "range %v is empty", .{x});
    return str;
}

fn pegGetinteger(b: *Builder, x: repr.Value) raise.Raising(i32) {
    if (args_core.checkint(x) == 0)
        return pegPanicf(b, "expected integer, got %v", .{x});
    return wrap.toInteger(x);
}

fn pegGetnat(b: *Builder, x: repr.Value) raise.Raising(i32) {
    const i = try pegGetinteger(b, x);
    if (i < 0)
        return pegPanicf(b, "expected non-negative integer, got %v", .{x});
    return i;
}

// ------------------------------------------------------------------ emission

fn emitConstant(b: *Builder, val: repr.Value) u32 {
    const cindex: u32 = @intCast(stretchy.count(repr.Value, b.constants));
    stretchy.push(repr.Value, &b.constants, val);
    return cindex;
}

fn emitTag(b: *Builder, t: repr.Value) raise.Raising(u32) {
    if (!repr.checkType(t, repr.Tag.keyword))
        return pegPanicf(b, "expected keyword for capture tag, got %v", .{t});
    const check = tables.get(b.tags, t);
    if (repr.checkType(check, repr.Tag.nil)) {
        const tag = b.nexttag;
        b.nexttag +%= 1;
        // A tag rides in one byte of the tag buffer, so 255 is the ceiling.
        if (tag > 255) return pegPanic(b, "too many tags - up to 255 tags are supported per peg");
        tables.put(b.tags, t, wrap.fromNumber(@floatFromInt(tag)));
        return tag;
    }
    return @intFromFloat(wrap.toNumber(check));
}

/// Space held in the bytecode for a rule whose body is not written yet.
///
/// A special has to place its rule on the bytecode stack *before* compiling its
/// children, so that a child referring back to it finds an index. `Reserve`
/// keeps the builder rather than the bytecode pointer, because compiling those
/// children is exactly what reallocates the vector.
const Reserve = struct {
    builder: *Builder,
    index: u32,
    size: i32,
};

fn reserve(b: *Builder, size: i32) Reserve {
    const r: Reserve = .{
        .builder = b,
        .index = @intCast(stretchy.count(u32, b.bytecode)),
        .size = size,
    };
    var i: i32 = 0;
    while (i < size) : (i += 1) stretchy.push(u32, &b.bytecode, 0);
    return r;
}

fn emitRule(r: Reserve, op: u32, n: i32, body: [*]const u32) void {
    pegAssert(r.size == n + 1, "bad reserve");
    stretchy.slice(u32, r.builder.bytecode)[r.index] = op;
    const count: usize = @intCast(n);
    @memcpy((r.builder.bytecode.? + r.index + 1)[0..count], body[0..count]);
}

/// For `RULE_LITERAL`, whose body is bytes rather than words.
fn emitBytes(b: *Builder, op: u32, bytes: []const u8) void {
    const next_rule: u32 = @intCast(stretchy.count(u32, b.bytecode));
    stretchy.push(u32, &b.bytecode, op);
    stretchy.push(u32, &b.bytecode, @intCast(bytes.len));
    const words = (bytes.len + 3) >> 2;
    var i: usize = 0;
    while (i < words) : (i += 1) stretchy.push(u32, &b.bytecode, 0);
    if (bytes.len != 0) {
        const dest: [*]u8 = @ptrCast(b.bytecode.? + next_rule + 2);
        @memcpy(dest[0..bytes.len], bytes);
    }
}

fn emit1(r: Reserve, op: u32, arg: u32) void {
    const body = [_]u32{arg};
    emitRule(r, op, 1, &body);
}

fn emit2(r: Reserve, op: u32, arg1: u32, arg2: u32) void {
    const body = [_]u32{ arg1, arg2 };
    emitRule(r, op, 2, &body);
}

fn emit3(r: Reserve, op: u32, arg1: u32, arg2: u32, arg3: u32) void {
    const body = [_]u32{ arg1, arg2, arg3 };
    emitRule(r, op, 3, &body);
}

// ------------------------------------------------------------------ specials

fn bitmapSet(bitmap: *[8]u32, ch: u8) void {
    bitmap[ch >> 5] |= @as(u32, 1) << @truncate(ch & 0x1F);
}

fn specRange(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    try pegArity(b, @as(i32, @intCast(argv.len)), 1, -1);
    if (@as(i32, @intCast(argv.len)) == 1) {
        const r = reserve(b, 2);
        const str = try pegGetrange(b, argv[0]);
        emit1(r, constants.RULE_RANGE, @as(u32, str[0]) | (@as(u32, str[1]) << 16));
    } else {
        // More than one range compiles to a set instead.
        const r = reserve(b, 9);
        var bitmap: [8]u32 = @splat(0);
        var i: i32 = 0;
        while (i < @as(i32, @intCast(argv.len))) : (i += 1) {
            const str = try pegGetrange(b, argv[@intCast(i)]);
            var ch: u32 = str[0];
            while (ch <= str[1]) : (ch += 1) bitmapSet(&bitmap, @truncate(ch));
        }
        emitRule(r, constants.RULE_SET, 8, &bitmap);
    }
}

fn specSet(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    try pegFixarity(b, @as(i32, @intCast(argv.len)), 1);
    const r = reserve(b, 9);
    const str = try pegGetset(b, argv[0]);
    var bitmap: [8]u32 = @splat(0);
    var i: i32 = 0;
    while (i < types.stringHead(str).length) : (i += 1) bitmapSet(&bitmap, str[@intCast(i)]);
    emitRule(r, constants.RULE_SET, 8, &bitmap);
}

fn specLook(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    try pegArity(b, @as(i32, @intCast(argv.len)), 1, 2);
    const r = reserve(b, 3);
    const rulearg: i32 = if (@as(i32, @intCast(argv.len)) == 2) 1 else 0;
    const offset: i32 = if (@as(i32, @intCast(argv.len)) == 2) try pegGetinteger(b, argv[0]) else 0;
    const subrule = try pegCompile1(b, argv[@intCast(rulearg)]);
    emit2(r, constants.RULE_LOOK, @bitCast(offset), subrule);
}

/// Rule of the form `[len, rules...]`.
fn specVariadic(b: *Builder, argv: []const repr.Value, op: u32) raise.Raising(void) {
    const rule: u32 = @intCast(stretchy.count(u32, b.bytecode));
    stretchy.push(u32, &b.bytecode, op);
    stretchy.push(u32, &b.bytecode, @bitCast(@as(i32, @intCast(argv.len))));
    var i: i32 = 0;
    while (i < @as(i32, @intCast(argv.len))) : (i += 1) stretchy.push(u32, &b.bytecode, 0);
    i = 0;
    while (i < @as(i32, @intCast(argv.len))) : (i += 1) {
        const rulei = try pegCompile1(b, argv[@intCast(i)]);
        // Re-read `b.bytecode`: compiling a child grows the vector.
        stretchy.slice(u32, b.bytecode)[rule + 2 + @as(u32, @intCast(i))] = rulei;
    }
}

fn specChoice(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specVariadic(b, argv, constants.RULE_CHOICE);
}

fn specSequence(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specVariadic(b, argv, constants.RULE_SEQUENCE);
}

/// For `(if a b)`, `(if-not a b)` and `(lenprefix a b)`.
fn specBranch(b: *Builder, argv: []const repr.Value, op: u32) raise.Raising(void) {
    try pegFixarity(b, @as(i32, @intCast(argv.len)), 2);
    const r = reserve(b, 3);
    const rule_a = try pegCompile1(b, argv[0]);
    const rule_b = try pegCompile1(b, argv[1]);
    emit2(r, op, rule_a, rule_b);
}

fn specIf(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specBranch(b, argv, constants.RULE_IF);
}

fn specIfnot(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specBranch(b, argv, constants.RULE_IFNOT);
}

fn specLenprefix(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specBranch(b, argv, constants.RULE_LENPREFIX);
}

fn specBetween(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    try pegFixarity(b, @as(i32, @intCast(argv.len)), 3);
    const r = reserve(b, 4);
    const lo = try pegGetnat(b, argv[0]);
    const hi = try pegGetnat(b, argv[1]);
    const subrule = try pegCompile1(b, argv[2]);
    emit3(r, constants.RULE_BETWEEN, @bitCast(lo), @bitCast(hi), subrule);
}

fn specRepeater(b: *Builder, argv: []const repr.Value, min: u32) raise.Raising(void) {
    try pegFixarity(b, @as(i32, @intCast(argv.len)), 1);
    const r = reserve(b, 4);
    const subrule = try pegCompile1(b, argv[0]);
    emit3(r, constants.RULE_BETWEEN, min, std.math.maxInt(u32), subrule);
}

fn specSome(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specRepeater(b, argv, 1);
}

fn specAny(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specRepeater(b, argv, 0);
}

fn specAtleast(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    try pegFixarity(b, @as(i32, @intCast(argv.len)), 2);
    const r = reserve(b, 4);
    const n = try pegGetnat(b, argv[0]);
    const subrule = try pegCompile1(b, argv[1]);
    emit3(r, constants.RULE_BETWEEN, @bitCast(n), std.math.maxInt(u32), subrule);
}

fn specAtmost(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    try pegFixarity(b, @as(i32, @intCast(argv.len)), 2);
    const r = reserve(b, 4);
    const n = try pegGetnat(b, argv[0]);
    const subrule = try pegCompile1(b, argv[1]);
    emit3(r, constants.RULE_BETWEEN, 0, @bitCast(n), subrule);
}

fn specOpt(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    try pegFixarity(b, @as(i32, @intCast(argv.len)), 1);
    const r = reserve(b, 4);
    const subrule = try pegCompile1(b, argv[0]);
    emit3(r, constants.RULE_BETWEEN, 0, 1, subrule);
}

fn specRepeat(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    try pegFixarity(b, @as(i32, @intCast(argv.len)), 2);
    const r = reserve(b, 4);
    const n = try pegGetnat(b, argv[0]);
    const subrule = try pegCompile1(b, argv[1]);
    emit3(r, constants.RULE_BETWEEN, @bitCast(n), @bitCast(n), subrule);
}

/// Rule of the form `[rule]`.
fn specOnerule(b: *Builder, argv: []const repr.Value, op: u32) raise.Raising(void) {
    try pegFixarity(b, @as(i32, @intCast(argv.len)), 1);
    const r = reserve(b, 2);
    const rule = try pegCompile1(b, argv[0]);
    emit1(r, op, rule);
}

fn specNot(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specOnerule(b, argv, constants.RULE_NOT);
}

fn specError(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    if (@as(i32, @intCast(argv.len)) == 0) {
        const r = reserve(b, 2);
        const rule = try pegCompile1(b, wrap.fromNumber(0));
        emit1(r, constants.RULE_ERROR, rule);
        return;
    }
    return specOnerule(b, argv, constants.RULE_ERROR);
}

fn specTo(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specOnerule(b, argv, constants.RULE_TO);
}

fn specThru(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specOnerule(b, argv, constants.RULE_THRU);
}

fn specDrop(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specOnerule(b, argv, constants.RULE_DROP);
}

fn specOnlyTags(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specOnerule(b, argv, constants.RULE_ONLY_TAGS);
}

/// Rule of the form `[rule, tag]`.
fn specCap1(b: *Builder, argv: []const repr.Value, op: u32) raise.Raising(void) {
    try pegArity(b, @as(i32, @intCast(argv.len)), 1, 2);
    const r = reserve(b, 3);
    const tag: u32 = if (@as(i32, @intCast(argv.len)) == 2) try emitTag(b, argv[1]) else 0;
    const rule = try pegCompile1(b, argv[0]);
    emit2(r, op, rule, tag);
}

fn specCapture(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specCap1(b, argv, constants.RULE_CAPTURE);
}

fn specAccumulate(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specCap1(b, argv, constants.RULE_ACCUMULATE);
}

fn specGroup(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specCap1(b, argv, constants.RULE_GROUP);
}

fn specUnref(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specCap1(b, argv, constants.RULE_UNREF);
}

fn specNth(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    try pegArity(b, @as(i32, @intCast(argv.len)), 2, 3);
    const r = reserve(b, 4);
    const nth = try pegGetnat(b, argv[0]);
    const rule = try pegCompile1(b, argv[1]);
    const tag: u32 = if (@as(i32, @intCast(argv.len)) == 3) try emitTag(b, argv[2]) else 0;
    emit3(r, constants.RULE_NTH, @bitCast(nth), rule, tag);
}

fn specCaptureNumber(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    try pegArity(b, @as(i32, @intCast(argv.len)), 1, 3);
    const r = reserve(b, 4);
    var base: u32 = 0;
    if (@as(i32, @intCast(argv.len)) >= 2 and !repr.checkType(argv[1], repr.Tag.nil)) {
        if (args_core.checkint(argv[1]) == 0)
            return pegPanicf(b, "expected integer between 2 and 36, got %v", .{argv[1]});
        base = @bitCast(wrap.toInteger(argv[1]));
        if (base < 2 or base > 36)
            return pegPanicf(b, "expected integer between 2 and 36, got %v", .{argv[1]});
    }
    const tag: u32 = if (@as(i32, @intCast(argv.len)) == 3) try emitTag(b, argv[2]) else 0;
    const rule = try pegCompile1(b, argv[0]);
    emit3(r, constants.RULE_CAPTURE_NUM, rule, base, tag);
}

fn specReference(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    try pegArity(b, @as(i32, @intCast(argv.len)), 1, 2);
    const r = reserve(b, 3);
    const search = try emitTag(b, argv[0]);
    const tag: u32 = if (@as(i32, @intCast(argv.len)) == 2) try emitTag(b, argv[1]) else 0;
    b.has_backref = 1;
    emit2(r, constants.RULE_GETTAG, search, tag);
}

/// Rule of the form `[tag]`.
fn specTag1(b: *Builder, argv: []const repr.Value, op: u32) raise.Raising(void) {
    try pegArity(b, @as(i32, @intCast(argv.len)), 0, 1);
    const r = reserve(b, 2);
    const tag: u32 = if (@as(i32, @intCast(argv.len)) != 0) try emitTag(b, argv[0]) else 0;
    emit1(r, op, tag);
}

fn specPosition(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specTag1(b, argv, constants.RULE_POSITION);
}

fn specLine(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specTag1(b, argv, constants.RULE_LINE);
}

fn specColumn(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specTag1(b, argv, constants.RULE_COLUMN);
}

fn specBackmatch(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    b.has_backref = 1;
    return specTag1(b, argv, constants.RULE_BACKMATCH);
}

fn specArgument(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    try pegArity(b, @as(i32, @intCast(argv.len)), 1, 2);
    const r = reserve(b, 3);
    const tag: u32 = if (@as(i32, @intCast(argv.len)) == 2) try emitTag(b, argv[1]) else 0;
    const index = try pegGetnat(b, argv[0]);
    emit2(r, constants.RULE_ARGUMENT, @bitCast(index), tag);
}

/// The one special that checks its arity with `janet_arity` rather than
/// `peg_arity`, so a wrong count here reports "arity mismatch" and leaves the
/// builder's two vectors unfreed. Reproduced; see `FOUND.md`.
fn specConstant(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    try args_core.arity(argv, 1, 2);
    const r = reserve(b, 3);
    const tag: u32 = if (@as(i32, @intCast(argv.len)) == 2) try emitTag(b, argv[1]) else 0;
    emit2(r, constants.RULE_CONSTANT, emitConstant(b, argv[0]), tag);
}

fn specDebug(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    try pegArity(b, @as(i32, @intCast(argv.len)), 0, 0);
    const r = reserve(b, 1);
    const empty = [_]u32{0};
    emitRule(r, constants.RULE_DEBUG, 0, &empty);
}

fn specReplace(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    try pegArity(b, @as(i32, @intCast(argv.len)), 2, 3);
    const r = reserve(b, 4);
    const subrule = try pegCompile1(b, argv[0]);
    const constant = emitConstant(b, argv[1]);
    const tag: u32 = if (@as(i32, @intCast(argv.len)) == 3) try emitTag(b, argv[2]) else 0;
    emit3(r, constants.RULE_REPLACE, subrule, constant, tag);
}

fn specMatchtimeImpl(b: *Builder, argv: []const repr.Value, op: u32) raise.Raising(void) {
    try pegArity(b, @as(i32, @intCast(argv.len)), 2, 3);
    const r = reserve(b, 4);
    const subrule = try pegCompile1(b, argv[0]);
    const fun = argv[1];
    if (!repr.checkType(fun, repr.Tag.function) and
        !repr.checkType(fun, repr.Tag.cfunction))
    {
        return pegPanicf(b, "expected function or cfunction, got %v", .{fun});
    }
    const tag: u32 = if (@as(i32, @intCast(argv.len)) == 3) try emitTag(b, argv[2]) else 0;
    const cindex = emitConstant(b, fun);
    emit3(r, op, subrule, cindex, tag);
}

fn specMatchtime(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specMatchtimeImpl(b, argv, constants.RULE_MATCHTIME);
}

fn specMatchtimeSplice(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specMatchtimeImpl(b, argv, constants.RULE_MATCHSPLICE);
}

/// Rule of the form `[rule, rule]`.
fn specTworule(b: *Builder, argv: []const repr.Value, op: u32) raise.Raising(void) {
    try pegFixarity(b, @as(i32, @intCast(argv.len)), 2);
    const r = reserve(b, 3);
    const subrule1 = try pegCompile1(b, argv[0]);
    const subrule2 = try pegCompile1(b, argv[1]);
    emit2(r, op, subrule1, subrule2);
}

fn specSub(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specTworule(b, argv, constants.RULE_SUB);
}

fn specTil(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specTworule(b, argv, constants.RULE_TIL);
}

fn specSplit(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specTworule(b, argv, constants.RULE_SPLIT);
}

fn specReadint(b: *Builder, argv: []const repr.Value, mask: u32) raise.Raising(void) {
    try pegArity(b, @as(i32, @intCast(argv.len)), 1, 2);
    const r = reserve(b, 3);
    const tag: u32 = if (@as(i32, @intCast(argv.len)) == 2) try emitTag(b, argv[1]) else 0;
    const width = try pegGetnat(b, argv[0]);
    if (width < 0 or width > max_readint_width) {
        return pegPanicf(b, "width must be between 0 and %d, got %d", .{ max_readint_width, width });
    }
    emit2(r, constants.RULE_READINT, mask | @as(u32, @bitCast(width)), tag);
}

fn specUintLe(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specReadint(b, argv, 0x0);
}

fn specIntLe(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specReadint(b, argv, 0x10);
}

fn specUintBe(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specReadint(b, argv, 0x20);
}

fn specIntBe(b: *Builder, argv: []const repr.Value) raise.Raising(void) {
    return specReadint(b, argv, 0x30);
}

const Special = *const fn (*Builder, []const repr.Value) raise.Raising(void);

const SpecialPair = struct {
    name: [:0]const u8,
    special: Special,
};

/// Kept in lexical order, because `findSpecial` below binary-searches it.
///
/// The C original says so in a comment and nothing checks it. Here the
/// `comptime` block underneath does, which is not a behaviour change: a table
/// out of order compiles in C and silently fails to find half its entries,
/// and here it does not compile at all.
const peg_specials = [_]SpecialPair{
    .{ .name = "!", .special = specNot },
    .{ .name = "$", .special = specPosition },
    .{ .name = "%", .special = specAccumulate },
    .{ .name = "*", .special = specSequence },
    .{ .name = "+", .special = specChoice },
    .{ .name = "->", .special = specReference },
    .{ .name = "/", .special = specReplace },
    .{ .name = "<-", .special = specCapture },
    .{ .name = ">", .special = specLook },
    .{ .name = "?", .special = specOpt },
    .{ .name = "??", .special = specDebug },
    .{ .name = "accumulate", .special = specAccumulate },
    .{ .name = "any", .special = specAny },
    .{ .name = "argument", .special = specArgument },
    .{ .name = "at-least", .special = specAtleast },
    .{ .name = "at-most", .special = specAtmost },
    .{ .name = "backmatch", .special = specBackmatch },
    .{ .name = "backref", .special = specReference },
    .{ .name = "between", .special = specBetween },
    .{ .name = "capture", .special = specCapture },
    .{ .name = "choice", .special = specChoice },
    .{ .name = "cms", .special = specMatchtimeSplice },
    .{ .name = "cmt", .special = specMatchtime },
    .{ .name = "column", .special = specColumn },
    .{ .name = "constant", .special = specConstant },
    .{ .name = "debug", .special = specDebug },
    .{ .name = "drop", .special = specDrop },
    .{ .name = "error", .special = specError },
    .{ .name = "group", .special = specGroup },
    .{ .name = "if", .special = specIf },
    .{ .name = "if-not", .special = specIfnot },
    .{ .name = "int", .special = specIntLe },
    .{ .name = "int-be", .special = specIntBe },
    .{ .name = "lenprefix", .special = specLenprefix },
    .{ .name = "line", .special = specLine },
    .{ .name = "look", .special = specLook },
    .{ .name = "not", .special = specNot },
    .{ .name = "nth", .special = specNth },
    .{ .name = "number", .special = specCaptureNumber },
    .{ .name = "only-tags", .special = specOnlyTags },
    .{ .name = "opt", .special = specOpt },
    .{ .name = "position", .special = specPosition },
    .{ .name = "quote", .special = specCapture },
    .{ .name = "range", .special = specRange },
    .{ .name = "repeat", .special = specRepeat },
    .{ .name = "replace", .special = specReplace },
    .{ .name = "sequence", .special = specSequence },
    .{ .name = "set", .special = specSet },
    .{ .name = "some", .special = specSome },
    .{ .name = "split", .special = specSplit },
    .{ .name = "sub", .special = specSub },
    .{ .name = "thru", .special = specThru },
    .{ .name = "til", .special = specTil },
    .{ .name = "to", .special = specTo },
    .{ .name = "uint", .special = specUintLe },
    .{ .name = "uint-be", .special = specUintBe },
    .{ .name = "unref", .special = specUnref },
};

comptime {
    for (peg_specials[1..], 0..) |entry, index| {
        if (std.mem.order(u8, peg_specials[index].name, entry.name) != .lt) {
            @compileError("peg_specials is not in lexical order at '" ++ entry.name ++ "'");
        }
    }
}

/// `janet_strbinsearch` over the table above, written out because the C helper
/// takes a `const char *` in the first word of each element and this table is a
/// Zig struct. The comparison is still `janet_cstrcmp`, whose treatment of an
/// embedded NUL a re-implementation would have to reproduce anyway.
fn findSpecial(sym: [*:0]const u8) ?Special {
    var low: usize = 0;
    var hi: usize = peg_specials.len;
    while (low < hi) {
        const mid = low + (hi - low) / 2;
        const comp = utils.cstrcmp(sym, peg_specials[mid].name.ptr);
        if (comp < 0) {
            hi = mid;
        } else if (comp > 0) {
            low = mid + 1;
        } else {
            return peg_specials[mid].special;
        }
    }
    return null;
}

/// Compile a Janet value into a rule, and return its index in the bytecode.
fn pegCompile1(b: *Builder, peg_in: repr.Value) raise.Raising(u32) {
    var peg = peg_in;

    // Keep track of the form being compiled, for error messages.
    const old_form = b.form;
    const old_grammar = b.grammar;
    b.form = peg;

    // Resolve keyword references.
    var i: i32 = recursion_guard;
    var grammar: ?*types.JanetTable = old_grammar;
    while (i > 0 and repr.checkType(peg, repr.Tag.keyword)) : (i -= 1) {
        var next_peg = tables.getEx(grammar.?, peg, &grammar);
        if (grammar == null or repr.checkType(next_peg, repr.Tag.nil)) {
            next_peg = if (b.default_grammar == null)
                wrap.fromNil()
            else
                tables.get(b.default_grammar.?, peg);
            if (repr.checkType(next_peg, repr.Tag.nil)) return pegPanic(b, "unknown rule");
        }
        peg = next_peg;
        b.form = peg;
        b.grammar = grammar.?;
    }
    if (i == 0) return pegPanic(b, "reference chain too deep");

    // Check the cache. A tuple gets only the local cache: in a different
    // grammar the same tuple can compile to a different rule, because
    // `(+ :a :b)` depends on whatever `:a` and `:b` are bound to there.
    const check = if (repr.checkType(peg, repr.Tag.tuple))
        tables.rawget(grammar.?, peg)
    else
        tables.get(grammar.?, peg);
    if (!repr.checkType(check, repr.Tag.nil)) {
        b.form = old_form;
        b.grammar = old_grammar;
        return @intFromFloat(wrap.toNumber(check));
    }

    // Check depth. Post-decrement, so the budget is spent one form later than
    // the matcher's pre-decrementing `down1`.
    const depth_before = b.depth;
    b.depth -= 1;
    if (depth_before == 0) return pegPanic(b, "peg grammar recursed too deeply");

    // The final rule to return.
    var rule: u32 = @intCast(stretchy.count(u32, b.bytecode));

    // Add to the cache. Structs are not cached, because we do not yet know
    // what rule they will return -- caching the struct's main rule is just as
    // effective.
    if (!repr.checkType(peg, repr.Tag.@"struct")) {
        var which_grammar = grammar.?;
        // A primitive pattern goes in the global cache, the root grammar table.
        if (!repr.checkType(peg, repr.Tag.tuple)) {
            while (which_grammar.proto) |proto| which_grammar = proto;
        }
        tables.put(which_grammar, peg, wrap.fromNumber(@floatFromInt(rule)));
    }

    switch (repr.typeOf(peg)) {
        repr.Tag.boolean => {
            const r = reserve(b, 2);
            emit1(r, if (wrap.toBoolean(peg)) constants.RULE_NCHAR else constants.RULE_NOTNCHAR, 0);
        },
        repr.Tag.number => {
            const n = try pegGetinteger(b, peg);
            const r = reserve(b, 2);
            if (n < 0) {
                emit1(r, constants.RULE_NOTNCHAR, @bitCast(-n));
            } else {
                emit1(r, constants.RULE_NCHAR, @bitCast(n));
            }
        },
        repr.Tag.string => {
            const str = wrap.toString(peg);
            emitBytes(b, constants.RULE_LITERAL, str[0..@intCast(types.stringHead(str).length)]);
        },
        repr.Tag.buffer => {
            const buf = wrap.toBuffer(peg);
            emitBytes(b, constants.RULE_LITERAL, buf.*.slice());
        },
        repr.Tag.table => {
            // Build a grammar table.
            const new_grammar = tables.clone(wrap.toTable(peg));
            new_grammar.*.proto = grammar;
            grammar = new_grammar;
            b.grammar = grammar.?;
            const main_rule = tables.rawget(grammar.?, value.fromBytes("main", .keyword));
            if (repr.checkType(main_rule, repr.Tag.nil))
                return pegPanic(b, "grammar requires :main rule");
            rule = try pegCompile1(b, main_rule);
        },
        repr.Tag.@"struct" => {
            // Build a grammar table.
            const st = wrap.toStruct(peg);
            const capacity = types.structHead(st).capacity;
            const new_grammar = tables.new(2 * capacity);
            var k: i32 = 0;
            while (k < capacity) : (k += 1) {
                const entry = st[@intCast(k)];
                if (repr.checkType(entry.key, repr.Tag.keyword)) {
                    tables.put(new_grammar, entry.key, entry.value);
                }
            }
            new_grammar.*.proto = grammar;
            grammar = new_grammar;
            b.grammar = grammar.?;
            const main_rule = tables.rawget(grammar.?, value.fromBytes("main", .keyword));
            if (repr.checkType(main_rule, repr.Tag.nil))
                return pegPanic(b, "grammar requires :main rule");
            rule = try pegCompile1(b, main_rule);
        },
        repr.Tag.tuple => {
            const tup = wrap.toTuple(peg);
            const len = types.tupleHead(tup).length;
            if (len == 0) return pegPanic(b, "tuple in grammar must have non-zero length");
            if (args_core.checkint(tup[0]) != 0) {
                const n = wrap.toInteger(tup[0]);
                if (n < 0) return pegPanicf(b, "expected non-negative integer, got %d", .{n});
                try specRepeat(b, tup[0..@intCast(len)]);
            } else if (!repr.checkType(tup[0], repr.Tag.symbol)) {
                return pegPanicf(b, "expected grammar command, found %v", .{tup[0]});
            } else {
                const sym = wrap.toSymbol(tup[0]);
                const special = findSpecial(sym) orelse
                    return pegPanicf(b, "unknown special %S", .{sym});
                try special(b, tup[1..@intCast(len)]);
            }
        },
        else => return pegPanic(b, "unexpected peg source"),
    }

    // Increase depth again.
    b.depth += 1;
    b.form = old_form;
    b.grammar = old_grammar;
    return rule;
}

// ==========================================================================
// The compiled peg as an abstract type
// ==========================================================================

fn pegMark(peg: *types.JanetPeg, _: usize) c_int {
    for (peg.constantValues()) |x| gc_mark.mark(x);
    return 0;
}

fn pegMarshal(peg: *types.JanetPeg, ctx: *types.JanetMarshalContext) raise.Raising(void) {
    try marsh.marshalSize(ctx, peg.bytecode_len);
    try marsh.marshalInt(ctx, @bitCast(peg.num_constants));
    marsh.marshalAbstract(ctx, peg);
    for (peg.instructions()) |instruction| try marsh.marshalInt(ctx, @bitCast(instruction));
    for (peg.constantValues()) |x| try marsh.marshalJanet(ctx, x);
}

/// Round `offset` up so that an array of `size`-byte elements placed there is
/// aligned, which is what lets the header, the bytecode and the constants share
/// one allocation.
fn sizePadded(offset: usize, size: usize) usize {
    // Wrapping, because C's `size_t` arithmetic is and `peg_unmarshal` feeds
    // this a length it took from the stream. `FOUND.md` has what that costs.
    const x = size +% offset -% 1;
    return x -% (x % size);
}

/// `OVERFLOW_CHECK`, the verifier's only bounds test.
///
/// `limit -% n` is the C original's `blen - (n)` and underflows for the same
/// inputs, which is a defect and is reproduced rather than repaired -- see
/// `FOUND.md`, where the off-by-one for `RULE_LITERAL` is recorded with it.
inline fn overflows(index: u32, limit: u32, n: u32) bool {
    return index > limit -% n;
}

/// Whether every instruction in `bytecode` is one the matcher can run.
///
/// Split out of `pegUnmarshal` because the C original reaches its cleanup with
/// `goto bad` from twenty-odd places, and a `false` return is the same shape
/// without the label. `op_flags` records, per word, whether it is referenced as
/// a rule operand (`0x01`) or is itself an instruction start (`0x02`); a word
/// that is only referenced is an operand pointing into the middle of another
/// instruction, and is rejected. That is stricter than a depth-first walk,
/// which is deliberate: it also rejects unreachable bytecode.
fn verifyBytecode(
    bytecode: [*]const u32,
    blen: u32,
    clen: u32,
    op_flags: [*]u8,
    has_backref: *c_int,
) bool {
    var i: u32 = 0;
    while (i < blen) {
        const instr = bytecode[i];
        const rule = bytecode + i;
        op_flags[i] |= 0x02;

        switch (instr) {
            constants.RULE_LITERAL => {
                if (overflows(i, blen, 1)) return false; // We only read rule[1].
                i += 2 +% ((rule[1] +% 3) >> 2);
            },
            constants.RULE_DEBUG => i += 1, // [0 words]
            constants.RULE_NCHAR,
            constants.RULE_NOTNCHAR,
            constants.RULE_RANGE,
            constants.RULE_POSITION,
            constants.RULE_LINE,
            constants.RULE_COLUMN,
            => i += 2, // [1 word]
            constants.RULE_BACKMATCH => {
                i += 2; // [1 word]
                has_backref.* = 1;
            },
            constants.RULE_SET => i += 9, // [8 words]
            constants.RULE_LOOK => { // [offset, rule]
                if (overflows(i, blen, 3)) return false;
                if (rule[2] >= blen) return false;
                op_flags[rule[2]] |= 0x01;
                i += 3;
            },
            constants.RULE_CHOICE, constants.RULE_SEQUENCE => { // [len, rules...]
                if (overflows(i, blen, 2)) return false;
                const len = rule[1];
                if (overflows(i, blen, 2 +% len)) return false;
                var j: u32 = 0;
                while (j < len) : (j += 1) {
                    if (rule[2 + j] >= blen) return false;
                    op_flags[rule[2 + j]] |= 0x01;
                }
                i += 2 +% len;
            },
            constants.RULE_IF, constants.RULE_IFNOT, constants.RULE_LENPREFIX => { // [rule_a, rule_b]
                if (overflows(i, blen, 3)) return false;
                if (rule[1] >= blen) return false;
                if (rule[2] >= blen) return false;
                op_flags[rule[1]] |= 0x01;
                op_flags[rule[2]] |= 0x01;
                i += 3;
            },
            constants.RULE_BETWEEN => { // [lo, hi, rule]
                if (overflows(i, blen, 4)) return false;
                if (rule[3] >= blen) return false;
                op_flags[rule[3]] |= 0x01;
                i += 4;
            },
            constants.RULE_ARGUMENT => i += 3, // [argument-index, tag]
            constants.RULE_GETTAG => { // [searchtag, tag]
                i += 3;
                has_backref.* = 1;
            },
            constants.RULE_CONSTANT => { // [constant, tag]
                if (overflows(i, blen, 3)) return false;
                if (rule[1] >= clen) return false;
                i += 3;
            },
            constants.RULE_CAPTURE_NUM => { // [rule, base, tag]
                if (overflows(i, blen, 4)) return false;
                if (rule[1] >= blen) return false;
                op_flags[rule[1]] |= 0x01;
                i += 4;
            },
            constants.RULE_ACCUMULATE,
            constants.RULE_GROUP,
            constants.RULE_CAPTURE,
            constants.RULE_UNREF,
            => { // [rule, tag]
                if (overflows(i, blen, 3)) return false;
                if (rule[1] >= blen) return false;
                op_flags[rule[1]] |= 0x01;
                i += 3;
            },
            constants.RULE_REPLACE, constants.RULE_MATCHTIME, constants.RULE_MATCHSPLICE => { // [rule, constant, tag]
                if (overflows(i, blen, 4)) return false;
                if (rule[1] >= blen) return false;
                if (rule[2] >= clen) return false;
                op_flags[rule[1]] |= 0x01;
                i += 4;
            },
            constants.RULE_SUB, constants.RULE_TIL, constants.RULE_SPLIT => { // [rule, rule]
                if (overflows(i, blen, 3)) return false;
                if (rule[1] >= blen) return false;
                if (rule[2] >= blen) return false;
                op_flags[rule[1]] |= 0x01;
                op_flags[rule[2]] |= 0x01;
                i += 3;
            },
            constants.RULE_ERROR,
            constants.RULE_DROP,
            constants.RULE_ONLY_TAGS,
            constants.RULE_NOT,
            constants.RULE_TO,
            constants.RULE_THRU,
            => { // [rule]
                if (overflows(i, blen, 2)) return false;
                if (rule[1] >= blen) return false;
                op_flags[rule[1]] |= 0x01;
                i += 2;
            },
            constants.RULE_READINT => { // [width | endianness | signedness, tag]
                if (overflows(i, blen, 3)) return false;
                if (rule[1] > max_readint_width) return false;
                i += 3;
            },
            constants.RULE_NTH => { // [nth, rule, tag]
                if (overflows(i, blen, 4)) return false;
                if (rule[2] >= blen) return false;
                op_flags[rule[2]] |= 0x01;
                i += 4;
            },
            else => return false,
        }
    }

    // The last instruction cannot overflow.
    if (i != blen) return false;

    // Every referenced word has to be an instruction start as well.
    i = 0;
    while (i < blen) : (i += 1) {
        if (op_flags[i] == 0x01) return false;
    }
    return true;
}

fn pegUnmarshal(ctx: *types.JanetMarshalContext) raise.Raising(*types.JanetPeg) {
    const bytecode_len = try marsh.unmarshalSize(ctx);
    const num_constants: u32 = @bitCast(try marsh.unmarshalInt(ctx));

    // Offsets, which have to match `makePeg`.
    // Every one of these wraps rather than traps, which is what the C original
    // does and is not a tidy-up this port may make: `bytecode_len` came off the
    // wire, and a length above 2^62 wraps `bytecode_size` to something small.
    // `FOUND.md` records where that leads.
    const bytecode_start = sizePadded(@sizeOf(types.JanetPeg), @sizeOf(u32));
    const bytecode_size = bytecode_len *% @sizeOf(u32);
    const constants_start = sizePadded(bytecode_start +% bytecode_size, @sizeOf(repr.Value));
    const total_size = constants_start +% @sizeOf(repr.Value) *% @as(usize, num_constants);

    // No DOS prevention: the bytecode and the constants could be read ahead of
    // the allocation so that short, bad input does not reserve a lot of memory.

    const mem: [*]u8 = @ptrCast(try marsh.unmarshalAbstract(ctx, total_size));
    const peg: *types.JanetPeg = @ptrCast(@alignCast(mem));
    const bytecode: [*]u32 = @ptrCast(@alignCast(mem + bytecode_start));
    const consts: [*]repr.Value = @ptrCast(@alignCast(mem + constants_start));
    peg.bytecode = null;
    peg.constants = null;
    peg.bytecode_len = bytecode_len;
    peg.num_constants = num_constants;

    var i: usize = 0;
    while (i < peg.bytecode_len) : (i += 1) bytecode[i] = @bitCast(try marsh.unmarshalInt(ctx));
    var j: u32 = 0;
    while (j < peg.num_constants) : (j += 1) consts[j] = try marsh.unmarshalJanet(ctx);

    // After here, nothing raises except the rejection at the end.

    // `(int32_t) peg->bytecode_len` assigned straight into a `uint32_t`: the
    // low thirty-two bits, whatever `size_t` is on this target.
    const blen: u32 = @truncate(peg.bytecode_len);
    const clen: u32 = peg.num_constants;
    const op_flags: [*]u8 = @ptrCast(allocated(utils.calloc(1, blen)).?);

    var has_backref: c_int = 0;
    if (!verifyBytecode(bytecode, blen, clen, op_flags, &has_backref)) {
        utils.free(op_flags);
        return raise.panic("invalid peg bytecode");
    }

    peg.bytecode = bytecode;
    peg.constants = consts;
    peg.has_backref = has_backref;
    utils.free(op_flags);
    return peg;
}

fn pegGetter(_: *types.JanetPeg, key: repr.Value, out: *repr.Value) raise.Raising(c_int) {
    if (!repr.checkType(key, repr.Tag.keyword)) return 0;
    return args_core.getmethod(wrap.toKeyword(key), @ptrCast(&peg_methods), out);
}

fn pegNext(_: *types.JanetPeg, key: repr.Value) raise.Raising(repr.Value) {
    return args_core.nextmethod(@ptrCast(&peg_methods), key);
}

pub const pegType = abstract_type.define(types.JanetPeg, .{
    .name = "core/peg",
    .gcmark = pegMark,
    .get = pegGetter,
    .marshal = pegMarshal,
    .unmarshal = pegUnmarshal,
    .next = pegNext,
});

/// Convert a `Builder` into the abstract value the matcher runs.
fn makePeg(b: *Builder) *types.JanetPeg {
    const bytecode_start = sizePadded(@sizeOf(types.JanetPeg), @sizeOf(u32));
    const bytecode_size = @as(usize, @intCast(stretchy.count(u32, b.bytecode))) * @sizeOf(u32);
    const constants_start = sizePadded(bytecode_start + bytecode_size, @sizeOf(repr.Value));
    const constants_size = @as(usize, @intCast(stretchy.count(repr.Value, b.constants))) * @sizeOf(repr.Value);
    const total_size = constants_start + constants_size;
    const mem: [*]u8 = @ptrCast(abstracts.new(&pegType, total_size));
    const peg: *types.JanetPeg = @ptrCast(@alignCast(mem));
    peg.bytecode = @ptrCast(@alignCast(mem + bytecode_start));
    peg.constants = @ptrCast(@alignCast(mem + constants_start));
    peg.num_constants = @intCast(stretchy.count(repr.Value, b.constants));
    safe_memcpy(peg.bytecode, b.bytecode, bytecode_size);
    safe_memcpy(peg.constants, b.constants, constants_size);
    peg.bytecode_len = @intCast(stretchy.count(u32, b.bytecode));
    peg.has_backref = b.has_backref;
    return peg;
}

/// The compiler's entry point.
fn compilePeg(x: repr.Value) raise.Raising(*types.JanetPeg) {
    var builder: Builder = .{
        .grammar = tables.new(0),
        .default_grammar = null,
        .tags = undefined,
        .constants = null,
        .bytecode = null,
        .nexttag = 1,
        .form = x,
        .depth = recursion_guard,
        .has_backref = 0,
    };
    const default_grammarv = vm_state.dyn("peg-grammar");
    if (repr.checkType(default_grammarv, repr.Tag.table)) {
        builder.default_grammar = wrap.toTable(default_grammarv);
    }
    builder.tags = tables.new(0);
    _ = try pegCompile1(&builder, x);
    const peg = makePeg(&builder);
    builderCleanup(&builder);
    return peg;
}

// ==========================================================================
// The cfunction surface
// ==========================================================================

/// Common data for the five matching cfunctions.
const PegCall = struct {
    peg: *types.JanetPeg,
    s: PegState,
    bytes: types.JanetByteView,
    subst: repr.Value,
    start: i32,
};

/// The state every `peg/...` call needs, including compiling the pattern when
/// it arrives as source rather than as a `<core/peg>`.
fn pegCfunInit(argv: []repr.Value, get_replace: bool) raise.Raising(PegCall) {
    var ret: PegCall = undefined;
    const min: i32 = if (get_replace) 3 else 2;
    try args_core.arity(argv, min, -1);
    if (repr.checkType(argv[0], repr.Tag.abstract) and
        types.abstractHead(wrap.toAbstract(argv[0])).type == &pegType)
    {
        ret.peg = @ptrCast(@alignCast(wrap.toAbstract(argv[0])));
    } else {
        ret.peg = try compilePeg(argv[0]);
    }
    if (get_replace) {
        ret.subst = argv[1];
        ret.bytes = try args_core.getBytes(argv, 2);
    } else {
        ret.bytes = try args_core.getBytes(argv, 1);
    }
    if (@as(i32, @intCast(argv.len)) > min) {
        ret.start = try args_core.getHalfRange(argv, min, ret.bytes.len, "offset");
        ret.s.extrac = @as(i32, @intCast(argv.len)) - min - 1;
        ret.s.extrav = tuples.newFrom(argv[@intCast(min + 1)..]);
    } else {
        ret.start = 0;
        ret.s.extrac = 0;
        ret.s.extrav = null;
    }
    ret.s.mode = .normal;
    ret.s.text_start = args_core.viewBytes(ret.bytes).ptr;
    ret.s.text_end = args_core.viewBytes(ret.bytes).ptr + @as(usize, @intCast(ret.bytes.len));
    ret.s.outer_text_end = ret.s.text_end;
    ret.s.depth = recursion_guard;
    ret.s.captures = arrays.new(0);
    ret.s.tagged_captures = arrays.new(0);
    ret.s.scratch = buffers.new(10);
    ret.s.tags = buffers.new(10);
    ret.s.constants = ret.peg.constants.?;
    ret.s.bytecode = ret.peg.bytecode.?;
    ret.s.linemap = null;
    ret.s.linemaplen = -1;
    ret.s.has_backref = ret.peg.has_backref;
    return ret;
}

/// Between two attempts at successive offsets. The recursion budget is part of
/// what is reset, so a long input does not run `peg/find` out of depth.
fn pegCallReset(call: *PegCall) void {
    call.s.depth = recursion_guard;
    call.s.captures.count = 0;
    call.s.tagged_captures.count = 0;
    call.s.scratch.count = 0;
    call.s.tags.count = 0;
}

fn cfunPegCompile(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    return wrap.fromAbstract(try compilePeg(argv[0]));
}

fn cfunPegMatch(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    var call = try pegCfunInit(argv, false);
    const result = try pegRule(&call.s, call.s.bytecode, args_core.viewBytes(call.bytes).ptr + @as(usize, @intCast(call.start)));
    return if (result != null) wrap.fromArray(call.s.captures) else wrap.fromNil();
}

fn cfunPegFind(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    var call = try pegCfunInit(argv, false);
    var i = call.start;
    while (i < call.bytes.len) : (i += 1) {
        pegCallReset(&call);
        if (try pegRule(&call.s, call.s.bytecode, args_core.viewBytes(call.bytes).ptr + @as(usize, @intCast(i))) != null) {
            return wrapInteger(i);
        }
    }
    return wrap.fromNil();
}

fn cfunPegFindAll(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    var call = try pegCfunInit(argv, false);
    const ret = arrays.new(0);
    var i = call.start;
    while (i < call.bytes.len) : (i += 1) {
        pegCallReset(&call);
        if (try pegRule(&call.s, call.s.bytecode, args_core.viewBytes(call.bytes).ptr + @as(usize, @intCast(i))) != null) {
            try arrays.push(ret, wrapInteger(i));
        }
    }
    return wrap.fromArray(ret);
}

fn pegReplaceGeneric(argv: []repr.Value, only_one: bool) raise.Raising(repr.Value) {
    var call = try pegCfunInit(argv, true);
    const ret = buffers.new(0);
    var trail: i32 = 0;
    var i = call.start;
    while (i < call.bytes.len) {
        pegCallReset(&call);
        const result = try pegRule(&call.s, call.s.bytecode, args_core.viewBytes(call.bytes).ptr + @as(usize, @intCast(i)));
        if (result) |matched| {
            if (trail < i) {
                try buffers.pushBytes(ret, args_core.viewBytes(call.bytes)[@intCast(trail)..@intCast(i)]);
                trail = i;
            }
            var nexti: i32 = @intCast(at(matched) - at(args_core.viewBytes(call.bytes).ptr));
            const subst = try registry.textSubstitution(
                &call.subst,
                args_core.viewBytes(call.bytes)[@intCast(i)..@intCast(nexti)],
                call.s.captures,
            );
            try buffers.pushBytes(ret, args_core.viewBytes(subst));
            trail = nexti;
            if (nexti == i) nexti += 1;
            i = nexti;
            if (only_one) break;
        } else {
            i += 1;
        }
    }
    if (trail < call.bytes.len) {
        try buffers.pushBytes(ret, args_core.viewBytes(call.bytes)[@intCast(trail)..@intCast(call.bytes.len)]);
    }
    return wrap.fromBuffer(ret);
}

fn cfunPegReplace(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    return pegReplaceGeneric(argv, true);
}

fn cfunPegReplaceAll(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    return pegReplaceGeneric(argv, false);
}

/// `janet_getmethod` scans this table linearly and `janet_nextmethod` walks it
/// in order, so the order is what `(keys peg)` reports. It is the C original's.
const peg_methods = [_]method_type.Method{
    .{ .name = "match", .cfun = cfunPegMatch },
    .{ .name = "find", .cfun = cfunPegFind },
    .{ .name = "find-all", .cfun = cfunPegFindAll },
    .{ .name = "replace", .cfun = cfunPegReplace },
    .{ .name = "replace-all", .cfun = cfunPegReplaceAll },
    .{ .name = null, .cfun = null },
};

pub fn libPeg(env: *types.JanetTable) raise.Raising(void) {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("peg/compile", &cfunPegCompile, @src(), "(peg/compile peg)", "Compiles a peg source data structure into a <core/peg>. This will speed up matching " ++
            "if the same peg will be used multiple times. `(dyn :peg-grammar)` replaces " ++
            "`default-peg-grammar` for the grammar of the peg."),
        corefn.reg("peg/match", &cfunPegMatch, @src(), "(peg/match peg text &opt start & args)", "Match a Parsing Expression Grammar to a byte string and return an array of captured values. " ++
            "Returns nil if text does not match the language defined by peg. The syntax of PEGs is documented on the Janet website."),
        corefn.reg("peg/find", &cfunPegFind, @src(), "(peg/find peg text &opt start & args)", "Find first index where the peg matches in text. Returns an integer, or nil if not found."),
        corefn.reg("peg/find-all", &cfunPegFindAll, @src(), "(peg/find-all peg text &opt start & args)", "Find all indexes where the peg matches in text. Returns an array of integers."),
        corefn.reg("peg/replace", &cfunPegReplace, @src(), "(peg/replace peg subst text &opt start & args)", "Replace first match of `peg` in `text` with `subst`, returning a new buffer. " ++
            "The peg does not need to make captures to do replacement. " ++
            "If `subst` is a function, it will be called with the " ++
            "matching text followed by any captures. " ++
            "If no matches are found, returns the input string in a new buffer."),
        corefn.reg("peg/replace-all", &cfunPegReplaceAll, @src(), "(peg/replace-all peg subst text &opt start & args)", "Replace all matches of `peg` in `text` with `subst`, returning a new buffer. " ++
            "The peg does not need to make captures to do replacement. " ++
            "If `subst` is a function, it will be called with the " ++
            "matching text followed by any captures."),
    };
    corefn.install(env, entries);
    try registry.registerAbstractType(&pegType);
}

pub fn libPegAbi(env: *types.JanetTable) void {
    raise.reported(libPeg(env));
}
