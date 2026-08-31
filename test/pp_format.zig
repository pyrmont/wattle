//! Behavioral contract for the format-string engine.
//!
//! Its subject has no C name: `formatTuple`'s format string is a `comptime`
//! parameter, so a caller does not call it, a caller *instantiates* it. No C
//! contract could.
//!
//! ## What it links against
//!
//! The runtime, because it is inside it: `@import("subsystems").pp_format` is
//! the same file the rest of the binary runs.
//!
//! **A contract compiled beside `libjanet.a` would test a local copy**, and
//! that is worth recording rather than quietly avoiding. With every selector
//! false the neighbours resolve to shims and the subject's own `@export`s are
//! suppressed so they do not collide with the library's. It works, and what it
//! tests is a second instance of the subject, sharing the runtime's state and
//! its source but not its code.
//!
//! ## Why this file exists rather than leaning on the Janet suites
//!
//! Half of this engine has no Janet caller at all. `formatTuple` and
//! `bufferFormat` are two loops over two different argument sources, and
//! `string/format` reaches only the second. `%S` and `%T` exist only in the
//! first; `%D` and `%I` are separate cases only in the first; `%s` reads a C
//! string there and a Janet value here. The suites exercise one of the two and
//! the panic messages of neither.
//!
//! ## What moved, and where the three grammar faults went
//!
//! The C original asserted seven refusals that this file cannot: `"%z"`,
//! `"%5z"`, `"%ld"`, `"%-+ #0-d"`, `"%123d"` and `"%.123f"` were runtime
//! panics from `scanFormat`, and against a `comptime` format string they are
//! **compile errors** -- `comptimeScan` raises them with `@compileError`, so
//! the case cannot be written down at all.
//!
//! They are not lost. Every one is still reachable through `bufferFormat`,
//! which keeps the runtime parser because `string/format` takes its format
//! string from Janet source, and that is the loop a user can actually reach
//! them on. `theGrammarFaults` below asserts all six there.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const harness = @import("harness.zig");
const value = @import("subsystems").value;
const fmt = @import("subsystems").pp_format;
const gc_alloc = @import("subsystems").gc_alloc;
const buffers = @import("subsystems").value.buffers;
const strings = @import("subsystems").value.strings;
const core_env = @import("subsystems").env;
const vm_state = @import("subsystems").lifecycle;
const signal_core = @import("subsystems").signal;
const wrap = @import("subsystems").value.wrap;

var test_env: *types.JanetTable = undefined;
var raises_fired: usize = 0;
const expected_raises = 15;

// ------------------------------------------------------------- assertions

fn checkString(s: types.JanetString, expected: []const u8) void {
    const len: usize = @intCast(types.stringHead(s).length);
    if (len != expected.len or !std.mem.eql(u8, s[0..len], expected)) {
        std.debug.print("expected: {s}\n     got: {s}\n", .{ expected, s[0..len] });
        @panic("string mismatch");
    }
}

fn checkBuffer(b: *types.JanetBuffer, expected: []const u8) void {
    const len: usize = @intCast(b.count);
    if (len != expected.len or !std.mem.eql(u8, b.slice()[0..len], expected)) {
        std.debug.print("expected: {s}\n     got: {s}\n", .{ expected, b.slice()[0..len] });
        @panic("buffer mismatch");
    }
}

/// `janet_wrap_integer`, which no Zig contract may call under
/// `-Dnanbox=false`. This file found that, and `test/harness.zig` now holds
/// the replacement and the argument for it.
const wrapInteger = harness.wrapInteger;

fn bytes(s: types.JanetString) []const u8 {
    return s[0..@intCast(types.stringHead(s).length)];
}

fn eval(source: [*:0]const u8) repr.Value {
    var out = wrap.fromNil();
    const status = core_env.dostring(test_env, source, "pp-format-test", &out);
    std.debug.assert(status == 0);
    _ = gc_alloc.gcroot(out);
    return out;
}

/// A raise, with the message it carried.
///
/// The C original spelled this as a macro over `janet_try_init`,
/// `janet_contract_arm` and `janet_contract_raised`, because a raise reached it
/// as a report on a flag. Here it is the error union itself; the scope is still
/// needed, because `janet_try_init` is what points `vm.return_reg` at a
/// payload and therefore what makes `janet_signal_plan` answer `RAISE` rather
/// than ending the process.
fn expectRaise(comptime message: []const u8, comptime body: anytype, args: anytype) void {
    var state: types.JanetTryState = undefined;
    signal_core.tryInit(&state);
    const result = @call(.auto, body, args);
    signal_core.restore(&state);

    if (result) |_| {
        std.debug.print("expected a raise: {s}\n", .{message});
        @panic("expected a raise, got a return");
    } else |_| {}

    std.debug.assert(repr.checkType(state.payload, repr.Tag.string));
    const got = bytes(wrap.toString(state.payload));
    if (!std.mem.eql(u8, got, message)) {
        std.debug.print("expected: {s}\n     got: {s}\n", .{ message, got });
        @panic("message mismatch");
    }
    raises_fired += 1;
}

/// `janet_buffer_format`, which is what `string/format` and `buffer/format`
/// run, and the only way into the other loop. It is the library's, not this
/// module's -- a panicking abi, so a raise comes back as a report.
extern fn janet_buffer_format(
    b: *types.JanetBuffer,
    strfrmt: [*]const u8,
    argstart: i32,
    argc: i32,
    argv: [*]repr.Value,
) callconv(.c) void;

fn formatted(format: [*]const u8, argv: []repr.Value) raise.Raising(types.JanetString) {
    const b = buffers.new(32);
    janet_buffer_format(b, format, -1, @intCast(argv.len), argv.ptr);
    _ = try raise.crossing({});
    return strings.new(b.*.slice());
}

// ------------------------------------------- the widths that crossed va_arg

/// Every argument the tuple driver can render, in one call.
///
/// It was written for the variadic loop, where an accessor reading the wrong
/// width corrupted every argument after it as well as its own, and it survives
/// the move because the widths still differ: `%c` renders a `c_int`, `%d` an
/// `i32`, `%D` an `i64`, `%x` a `u64`, `%f` an `f64`, `%s` a C string, `%v` a
/// `Janet`. What used to be a runtime hazard is now a coercion the compiler
/// checks, which is the whole point of the change -- but the rendering still
/// has to be right.
fn everyArgumentWidthInOneCall() void {
    const s = fmt.formatc("%c|%d|%d|%x|%.2f|%s|%v|%d", .{
        @as(c_int, 'A'),
        @as(i32, -2000000000),
        @as(i64, -8000000000000000000),
        @as(u64, 0xFEDCBA9876543210),
        @as(f64, 3.25),
        @as([*]const u8, "tail"),
        value.fromBytes("kw", .keyword),
        @as(i32, 7),
    }) catch @panic("raised");
    checkString(s, "A|-2000000000|-8000000000000000000|fedcba9876543210|3.25|tail|:kw|7");
}

/// `%D` renders whatever the host libc makes of an unrecognised conversion,
/// and this is the only place that says so.
///
/// **This assertion used to sit inside `everyArgumentWidthInOneCall`, and it
/// made that contract fail on Linux.** `FOUND.md` records the defect --
/// `format_mappings` carries `D` and `I` entries that `FMT_REPLACE_INTTYPES`
/// never consults, so the specifier reaches `snprintf` unrewritten -- and says
/// of Janet that it "pins only that the mapping does *not* happen, which is
/// the part that is the same everywhere". Pinning the *rendering* instead is
/// pinning macOS's BSD synonym for `%ld`, and musl produces nothing at all.
///
/// So the widths above use `%d`, which maps to `PRId64` and is well defined on
/// every host, and the host-specific behaviour is asserted here and only where
/// it is known. Nothing is lost on macOS and Linux stops failing on a
/// divergence this project has already decided not to fix.
fn theUnmappedIntegerConversions() void {
    if (builtin.os.tag != .macos) return;

    // macOS accepts `%D` as a BSD synonym for `%ld`...
    const rendered = fmt.formatc("%D", .{@as(i64, -8000000000000000000)}) catch @panic("raised");
    checkString(rendered, "-8000000000000000000");

    // ...and does not recognise `%I`, rendering the conversion character as a
    // literal, padded according to the flags.
    const literal = fmt.formatc("[%-8I]", .{@as(i64, 8)}) catch @panic("raised");
    checkString(literal, "[I       ]");
}

/// `formatb` appends to a buffer the caller already owns, and returns it. A
/// version that replaced the contents rather than appending would be invisible
/// until an embedder tripped over it.
fn formatbAppendsAndReturnsItsBuffer() void {
    const b = buffers.new(16);
    _ = buffers.pushCstringAbi(b, "head:");

    const returned = fmt.formatb(b, "%d-%d", .{ @as(i32, 1), @as(i32, 2) }) catch @panic("raised");
    std.debug.assert(returned == b);
    checkBuffer(b, "head:1-2");

    _ = fmt.formatb(b, "|%s", .{@as([*]const u8, "tail")}) catch @panic("raised");
    checkBuffer(b, "head:1-2|tail");
}

// ----------------------------------------- the conversions only Zig reaches

/// `%S` takes a Janet string and knows its length without walking it, where
/// `%s` takes a C string and does. The difference is only observable for a
/// string with an interior zero, which is exactly the case `%s` cannot carry.
fn theJanetStringConversion() void {
    const raw = [_]u8{ 'a', 0, 'b' };
    const embedded = strings.new(raw[0..@intCast(3)]);

    const s = fmt.formatc("[%S]", .{embedded}) catch @panic("raised");
    std.debug.assert(types.stringHead(s).length == 5);
    std.debug.assert(std.mem.eql(u8, bytes(s), "[a\x00b]"));

    // The same bytes through `%s` stop at the zero.
    checkString(fmt.formatc("[%s]", .{embedded}) catch @panic("raised"), "[a]");
}

/// `%T` renders a *set* of types, which is what an argument check reports.
/// There is no Janet syntax for it: the only callers build the mask from a
/// `repr.TagSet` -- what `JANET_TFLAG_*` used to spell as an `int`.
fn theTypeSetConversion() void {
    // One member: no separator at all.
    checkString(
        fmt.formatc("%T", .{repr.TagSet.one(.number)}) catch @panic("raised"),
        "number",
    );
    // Two: joined with " or " rather than a comma, because the last pair always is.
    checkString(
        fmt.formatc("%T", .{repr.TagSet.of(&.{ .number, .string })}) catch @panic("raised"),
        "number or string",
    );
    // Three: commas until the last, then " or ". Getting this backwards reads
    // as English either way and is wrong in every message Janet prints.
    checkString(
        fmt.formatc("%T", .{repr.TagSet.of(&.{ .number, .string, .keyword })}) catch @panic("raised"),
        "number, string or keyword",
    );
    // An empty set renders as nothing rather than as an error.
    checkString(fmt.formatc("%T", .{repr.TagSet.none}) catch @panic("raised"), "");
}

/// `%t` names one type, and an abstract value names its own type rather than
/// the word "abstract".
fn theTypeNameConversion() void {
    checkString(fmt.formatc("%t", .{wrapInteger(1)}) catch @panic("raised"), "number");
    checkString(fmt.formatc("%t", .{value.fromBytes("k", .keyword)}) catch @panic("raised"), "keyword");
    checkString(fmt.formatc("%t", .{wrap.fromNil()}) catch @panic("raised"), "nil");
}

/// `%D` and `%I` are declared in the mapping table and never reached by it,
/// because the table is consulted only for the lower-case spellings. What they
/// print is whatever the host's `snprintf` makes of an unrecognised conversion,
/// and that is what is pinned: *not* the 64-bit rendering the table intends.
/// `FOUND.md` has the entry.
///
/// The assertion is deliberately weak -- it says the mapping did not happen,
/// rather than what the libc did instead -- because the libc's answer differs
/// by platform and pinning it would make this a platform check.
fn theUpperCaseIntegerConversionsAreNotMapped() void {
    const d = fmt.formatc("%D", .{@as(i64, 5)}) catch @panic("raised");
    const i = fmt.formatc("%I", .{@as(i64, 6)}) catch @panic("raised");

    // Were the table consulted, these would be "5" and "6".
    std.debug.assert(!std.mem.eql(u8, bytes(i), "6"));
    _ = d; // BSD libc happens to accept %D, glibc and musl do not.
}

// --------------------------------------------------- the specifier grammar

/// Flags, width and precision all reach `snprintf` through the rebuilt
/// specifier, and the integer conversions are rebuilt with a 64-bit length
/// modifier on the way. A rebuild that dropped the flags would still produce
/// the right digits.
fn flagsWidthAndPrecisionSurviveTheRebuild() void {
    const third: f64 = 1.0 / 3.0;
    checkString(fmt.formatc("[%8d]", .{@as(i32, 42)}) catch @panic("raised"), "[      42]");
    checkString(fmt.formatc("[%-8d]", .{@as(i32, 42)}) catch @panic("raised"), "[42      ]");
    checkString(fmt.formatc("[%08d]", .{@as(i32, 42)}) catch @panic("raised"), "[00000042]");
    checkString(fmt.formatc("[%+d]", .{@as(i32, 42)}) catch @panic("raised"), "[+42]");
    checkString(fmt.formatc("[%#x]", .{@as(u64, 255)}) catch @panic("raised"), "[0xff]");
    checkString(fmt.formatc("[%.2f]", .{third}) catch @panic("raised"), "[0.33]");
    checkString(fmt.formatc("[%8.2f]", .{third}) catch @panic("raised"), "[    0.33]");
    checkString(
        fmt.formatc("[%.3s]", .{@as([*]const u8, "abcdef")}) catch @panic("raised"),
        "[abc]",
    );

    // A doubled percent is a literal one and consumes no argument.
    checkString(fmt.formatc("100%% of %d", .{@as(i32, 3)}) catch @panic("raised"), "100% of 3");
}

/// A bare `%s` bypasses `snprintf` entirely, which is the only way a string
/// longer than the 256-byte item scratch can be formatted at all.
fn aBareStringConversionHasNoLengthLimit() void {
    var big: [600]u8 = @splat('x');
    big[big.len - 1] = 0;
    const s = fmt.formatc("%s", .{@as([*]const u8, &big)}) catch @panic("raised");
    std.debug.assert(types.stringHead(s).length == big.len - 1);
}

// -------------------------------------------------------- the raise messages

/// Every way the engine refuses at *runtime*, with the message it refuses
/// with. These are user-visible strings that no suite asserts, and a port that
/// reworded one would break nobody's test and every user's error handling.
fn theRefusals() void {
    // A width or precision means `snprintf`, which stops at the first zero;
    // refusing is better than silently dropping the rest.
    const raw = [_]u8{ 'a', 0, 'b' };
    const embedded = strings.new(raw[0..@intCast(3)]);
    expectRaise("string contains zeros", fmt.formatc, .{ "%10S", .{embedded} });

    // Without a precision, `snprintf` would write as many bytes as the string
    // has, and the item scratch is 256.
    var big: [200]u8 = @splat('x');
    big[big.len - 1] = 0;
    expectRaise(
        "no precision and string is too long to be formatted",
        fmt.formatc,
        .{ "%10s", .{@as([*]const u8, &big)} },
    );

    // Only the Janet-array loop can run out of arguments.
    var two = [_]repr.Value{ wrapInteger(1), wrapInteger(2) };
    expectRaise("not enough values for format", formatted, .{ "%d %d %d", two[0..] });

    // `%j` is the one conversion that can refuse the value it was given, and it
    // must refuse it through both loops. Without this, a `%j` that
    // pretty-printed instead of writing JDN would pass every other assertion
    // here: the two spellings agree on the values that have both forms, and
    // disagree only on the values that have one.
    var fn_slot = [_]repr.Value{eval("print")};
    expectRaise("could not print to jdn format", fmt.formatc, .{ "%j", .{fn_slot[0]} });
    expectRaise("could not print to jdn format", formatted, .{ "%j", fn_slot[0..] });
}

/// The three faults `scanFormat` raises, on the loop that can still reach them.
///
/// Against `formatTuple` all six of these are compile errors, so the cases
/// below are the whole of the coverage now -- and they are the reachable half
/// in any case, because a Janet program supplies `string/format`'s format
/// string and no Janet program supplies `formatTuple`'s.
fn theGrammarFaults() void {
    var one = [_]repr.Value{wrapInteger(1)};

    // An unrecognised conversion names the rebuilt specifier, not the original:
    // `%5z` reports as `%5z`, and a mapped one would report its mapping.
    expectRaise("invalid conversion '%z' to 'format'", formatted, .{ "%z", one[0..] });
    expectRaise("invalid conversion '%5z' to 'format'", formatted, .{ "%5z", one[0..] });
    // 'l', 'h' and 'L' are C length modifiers, and Janet has no use for them
    // because every conversion is already fixed-width.
    expectRaise("invalid conversion '%l' to 'format'", formatted, .{ "%ld", one[0..] });

    // Six flag characters, where five is the whole set.
    expectRaise("invalid format (repeated flags)", formatted, .{ "%-+ #0-d", one[0..] });

    // Three digits of width, where the field holds two.
    expectRaise("invalid format (width or precision too long)", formatted, .{ "%123d", one[0..] });
    expectRaise("invalid format (width or precision too long)", formatted, .{ "%.123f", one[0..] });
}

/// A conversion whose rendering exceeds the item scratch is refused rather than
/// truncated. `snprintf` reports what it *would* have written, which is what
/// makes the check possible at all.
///
/// The boundary case matters more than the obvious one. `%.99f` of 1e155 needs
/// exactly 256 bytes, which is the scratch's size: `snprintf` wrote 255 and a
/// terminator, and reported 256. A check spelled `>` rather than `>=` accepts
/// that and pushes 256 bytes out of a buffer holding 255 real ones, so the
/// output ends in a stray zero byte. Only this one length shows it.
fn anOversizedItemIsRefused() void {
    expectRaise("format buffer overflow", fmt.formatc, .{ "%99.99f", .{@as(f64, 1e300)} });
    expectRaise("format buffer overflow", fmt.formatc, .{ "%.99f", .{@as(f64, 1e155)} });

    // One byte under, which must still be accepted.
    const ok = fmt.formatc("%.99f", .{@as(f64, 1e154)}) catch @panic("raised");
    std.debug.assert(types.stringHead(ok).length == 255);
}

// -------------------------------------------------------- the two loops

fn theTwoLoopsAgreeWhereTheyOverlap() void {
    var slot = [_]repr.Value{eval("@{:a [1 2 3] :b \"x\"}")};

    inline for (.{ "%q", "%j", "%t", "%V" }) |spelling| {
        checkString(
            formatted(spelling, slot[0..]) catch @panic("raised"),
            bytes(fmt.formatc(spelling, .{slot[0]}) catch @panic("raised")),
        );
    }

    slot[0] = wrap.fromNumber(1.0 / 3.0);
    const third: f64 = 1.0 / 3.0;
    checkString(
        formatted("%.4f", slot[0..]) catch @panic("raised"),
        bytes(fmt.formatc("%.4f", .{third}) catch @panic("raised")),
    );
    checkString(
        formatted("%8.2e", slot[0..]) catch @panic("raised"),
        bytes(fmt.formatc("%8.2e", .{third}) catch @panic("raised")),
    );
}

// ------------------------------------------------- the pretty conversions

/// Eight characters select the same printer with three flags between them, and
/// the decoding is by character rather than by table. Each flag is asserted
/// through the one spelling that sets it alone.
fn theEightPrettySpellings() void {
    const val = eval("@[1 2 3 4 5]");

    const has = struct {
        fn scalar(s: types.JanetString, needle: u8) bool {
            return std.mem.indexOfScalar(u8, bytes(s), needle) != null;
        }
        fn sub(s: types.JanetString, needle: []const u8) bool {
            return std.mem.indexOf(u8, bytes(s), needle) != null;
        }
    };

    // Lower case: no colour. Upper case: colour.
    std.debug.assert(!has.scalar(fmt.formatc("%p", .{val}) catch @panic("raised"), 0x1B));
    std.debug.assert(has.scalar(fmt.formatc("%P", .{val}) catch @panic("raised"), 0x1B));

    // q and Q are one-line; p and P are not, at a width that forces a wrap.
    std.debug.assert(!has.scalar(fmt.formatc("%12q", .{val}) catch @panic("raised"), '\n'));
    std.debug.assert(has.scalar(fmt.formatc("%12p", .{val}) catch @panic("raised"), '\n'));

    // m and M keep everything; p truncates.
    const big = eval("(seq [i :range [0 400]] i)");
    std.debug.assert(has.sub(fmt.formatc("%p", .{big}) catch @panic("raised"), "..."));
    std.debug.assert(!has.sub(fmt.formatc("%m", .{big}) catch @panic("raised"), "..."));
    // Upper case keeps the flag as well as adding colour, which is the half of
    // the decoding that a table lookup keyed on the lower-case letter alone
    // would drop.
    std.debug.assert(!has.sub(fmt.formatc("%M", .{big}) catch @panic("raised"), "..."));
    std.debug.assert(has.scalar(fmt.formatc("%M", .{big}) catch @panic("raised"), 0x1B));
    // n and N are one-line *and* untruncated, which is neither of the above
    // alone.
    std.debug.assert(!has.sub(fmt.formatc("%n", .{big}) catch @panic("raised"), "..."));
    std.debug.assert(!has.scalar(fmt.formatc("%n", .{big}) catch @panic("raised"), '\n'));
    std.debug.assert(!has.sub(fmt.formatc("%N", .{big}) catch @panic("raised"), "..."));
    std.debug.assert(!has.scalar(fmt.formatc("%N", .{big}) catch @panic("raised"), '\n'));

    // The precision is the depth, and it is read from the specifier rather than
    // from an argument.
    checkString(
        fmt.formatc("%.2q", .{eval("[1 [2 [3]]]")}) catch @panic("raised"),
        "(1 (...))",
    );
}

/// A `%p` in the middle of a format string starts its own reflow at the point
/// it was reached, not at the start of the buffer, and takes its self-print
/// length from the start of the whole format. Both parameters are invisible
/// unless something was written first.
fn aPrettyConversionAfterOtherText() void {
    const b = buffers.new(64);
    _ = buffers.pushCstringAbi(b, "prefix)\n");
    _ = fmt.formatb(b, "%12p", .{eval("@[1 2 3 4 5]")}) catch @panic("raised");
    // The prefix, its newline and its bracket are all still there.
    std.debug.assert(std.mem.eql(u8, b.*.slice()[0..8], "prefix)\n"));
}

// ----------------------------------------------- the fourth entry point

const scratch = "janet-zig-pp-format-9d24";

/// `dynprintf`'s four destinations.
///
/// It asserts the routing rather than the rendering: `dynprintf` is one of the
/// four entry points a variadic surface once held, and it sits in
/// `pp/format.zig` beside the other three.
/// What it asserts is the routing rather than the rendering -- a bound buffer,
/// an absent name, an empty name, a null name, a bound value of the wrong
/// type, and a file that cannot be written.
fn dynprintfReachesItsFourDestinations() void {
    const sink = buffers.new(0);
    vm_state.setdyn("pp-format-out", wrap.fromBuffer(sink));
    fmt.dynprintf("pp-format-out", null, "%d and %s", .{
        @as(i32, 7),
        @as([*]const u8, "text"),
    }) catch @panic("raised");
    checkBuffer(sink, "7 and text");

    // A name that is not bound, and an empty name, both use the default handle
    // rather than doing nothing.
    var raw = fopen(scratch, "wb");
    std.debug.assert(raw != null);
    fmt.dynprintf("pp-format-absent", raw, "to the default", .{}) catch @panic("raised");
    fmt.dynprintf("", raw, "%d", .{@as(i32, 42)}) catch @panic("raised");
    fmt.dynprintf(null, raw, "!", .{}) catch @panic("raised");
    std.debug.assert(io_core.close(raw.?) == 0);

    const check = buffers.new(0);
    raw = io_core.open(scratch, "rb");
    std.debug.assert(raw != null);
    buffers.extra(check, 64) catch @panic("pp_format: buffer extra raised");
    check.*.count = @intCast(io_core.read(raw.?, check.*.data.?, 64));
    std.debug.assert(io_core.close(raw.?) == 0);
    checkBuffer(check, "to the default42!");

    // A bound value of any other type is ignored entirely.
    vm_state.setdyn("pp-format-out", wrapInteger(3));
    fmt.dynprintf("pp-format-out", null, "dropped", .{}) catch @panic("raised");

    // A closed file is a raise.
    const jf = io_core.makejfile(@ptrCast(@alignCast(io_core.open(scratch, "rb"))), constants.JANET_FILE_READ);
    vm_state.setdyn("pp-format-out", wrap.fromAbstract(jf));
    expectRaise("file is not writeable", fmt.dynprintf, .{
        @as(?[*:0]const u8, "pp-format-out"),
        @as(?*anyopaque, null),
        "not writeable",
        .{},
    });
    std.debug.assert(io_core.fileClose(jf) == 0);

    vm_state.setdyn("pp-format-out", wrap.fromNil());
    _ = remove(scratch);
}

extern fn fopen(path: [*]const u8, mode: [*]const u8) callconv(.c) ?*anyopaque;
extern fn remove(path: [*]const u8) callconv(.c) c_int;

/// The stream operations, by import.
///
/// Three of them were `extern fn janet_io_*` declarations here, because that
/// is what they were: a seam exported so a C caller could reach them. Fourteen
/// of the fifteen have no caller left anywhere and stopped being symbols.
/// `janet_io_write` is the one that stays, because `pp/format.zig` itself is a
/// real caller by symbol.
const io_core = @import("subsystems").io;

/// A formatted raise.
///
/// `panicf` answers with the bare error set rather than an error union --
/// every call to it raises -- so the thunk gives `expectRaise` the shape it
/// tests, which is the same shape every other subject here has.
fn panicfThunk(comptime format: [:0]const u8, args: anytype) raise.Raising(void) {
    return fmt.panicf(format, args);
}

fn panicfCarriesItsFormattedMessage() void {
    expectRaise("bad 7 and true", panicfThunk, .{
        "bad %d and %v",
        .{ @as(i32, 7), wrap.fromTrue() },
    });
}

// -------------------------------------------------------------------- main

pub fn run() void {
    harness.init();
    test_env = harness.coreEnv();
    _ = gc_alloc.gcroot(wrap.fromTable(test_env));

    everyArgumentWidthInOneCall();
    theUnmappedIntegerConversions();
    formatbAppendsAndReturnsItsBuffer();
    theJanetStringConversion();
    theTypeSetConversion();
    theTypeNameConversion();
    theUpperCaseIntegerConversionsAreNotMapped();
    flagsWidthAndPrecisionSurviveTheRebuild();
    aBareStringConversionHasNoLengthLimit();
    theRefusals();
    theGrammarFaults();
    anOversizedItemIsRefused();
    theTwoLoopsAgreeWhereTheyOverlap();
    theEightPrettySpellings();
    aPrettyConversionAfterOtherText();
    dynprintfReachesItsFourDestinations();
    panicfCarriesItsFormattedMessage();

    std.debug.assert(raises_fired == expected_raises);

    vm_state.deinit();
    std.debug.print("pp format contract ok\n", .{});
}
