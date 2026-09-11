//! Behavioral contract for the PEG engine.
//!
//! The reason this file exists rather than leaning on `test/suite-peg.janet`:
//! that suite has 366 assertions and every one of them is about what a pattern
//! *matches*. Three things it cannot see:
//!
//!  - The bytecode. The compiler, the matcher and the verifier share a private
//!    instruction encoding with no other consumer, so a change made
//!    consistently in all three is invisible from Janet. It is also a file
//!    format: a marshalled peg is those words, so a renumbered opcode silently
//!    invalidates every stored peg.
//!  - The one allocation. `makePeg` packs the header, the bytecode and the
//!    constants into a single abstract, with padding computed so that each
//!    array is aligned. Nothing in Janet can observe the layout, and
//!    `pegUnmarshal` has to reproduce it exactly or read the wrong words.
//!  - Crafted bytecode. `pegUnmarshal` is the untrusted entry point, and most
//!    of what it must reject cannot be produced by the compiler at all.
//!
//! The shape of the peg's callback table is pinned too, and Janet cannot see
//! it: which callbacks a peg has decides what the runtime will do with one.
//! `theAbstractTypeIsShapedAsTheRuntimeExpects` asserts the table the runtime
//! dispatches through.
//!
//! `peg/compile` is reached as a cfunction rather than by import, because a
//! grammar error has to arrive as a refusal rather than as a status code
//! `env.dostring` has already caught. A cfunction *is* a raising Zig function,
//! so `harness.core` and `harness.raised` are the whole of it.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const access = @import("subsystems").value.access;
const args_core = @import("subsystems").args;
const arrays = @import("subsystems").value.arrays;
const buffers = @import("subsystems").value.buffers;
const c = @import("cabi");
const config = @import("config");
const constants = @import("constants");
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const gc_alloc = @import("subsystems").gc_alloc;
const harness = @import("harness.zig");
const marsh = subsystems.marsh;
const op = harness.op;
const peg = subsystems.peg;
const raise = @import("subsystems").raise;
const registry = @import("subsystems").registry;
const repr = @import("repr");
const strings = @import("subsystems").value.strings;
const subsystems = @import("subsystems");
const tables = @import("subsystems").value.tables;
const utils = @import("subsystems").utils;
const value = @import("subsystems").value;
const vm_calls = subsystems.vm;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// `peg/compile`, resolved once. The type assertion is `harness.core`'s.
var compile_cfun: raise.CFunction = undefined;
const lb_integer: u8 = 205;
const lb_nil: u8 = 201;

/// The two marshal lead bytes these streams spell by number, for the reason
/// `test/marsh.zig` gives: the enumeration is a file format and the subject's
/// own is not the oracle for it.
const lb_real: u8 = 200;

/// Six without the integer types and eight with them, because a `double`
/// capture cannot represent more than 53 bits. Both the compiler's limit and
/// the
/// verifier's move with it, so the assertions that name a width have to as
/// well.
///
/// Read from the environment rather than from a build condition: the boxed
/// 64-bit conversions are compiled exactly when the integer types are, which
/// is the same test `peg.zig` itself makes.
const max_readint_width: u32 = if (config.int_types) 8 else 6;
const max_readint_width_text = if (max_readint_width == 8) "8" else "6";

/// The framing every crafted stream shares, up to and including the type name.
/// What follows is `bytecode_len`, `num_constants`, the words and the
/// constants, all of them small enough to be one byte each in the marshal
/// encoding except
/// where a case says otherwise.
const peg_header = [_]u8{ 217, 207, 8 } ++ "core/peg".*;

/// Compiled pegs and the forms they came from. A `Janet` in a Zig local is not
/// a GC root, and compiling one form allocates enough to collect the next.
var rooted: *arrays.Array = undefined;
var test_env: *tables.Table = undefined;

// ==========================================================================
// Cases
// ==========================================================================

fn keep(val: repr.Value) repr.Value {
    harness.arrayPush(rooted, val);
    return val;
}

fn evaluate(source: [*:0]const u8) repr.Value {
    var out = wrap.fromNil();
    if (core_env.dostring(test_env, source, "peg-contract", &out) != 0) {
        std.debug.print("evaluating {s} failed\n", .{source});
        @panic("evaluation failed");
    }
    return keep(out);
}

fn compiled(pattern: []const u8) *peg.Peg {
    var source: [1024]u8 = undefined;
    const written = std.fmt.bufPrintZ(&source, "(peg/compile {s})", .{pattern}) catch
        @panic("pattern too long");
    const val = evaluate(written.ptr);
    expect(args_core.checkabstract(val, &peg.pegType) != null);
    return @ptrCast(@alignCast(wrap.toAbstract(val)));
}

/// The refusal `peg/compile` made for `source`, or null if it compiled.
///
/// `source` is Janet source for the *pattern*, evaluated before the scope
/// opens so that only the compilation is inside it.
fn grammarError(source: [*:0]const u8) harness.Raise {
    var argv = [_]repr.Value{evaluate(source)};
    return harness.raised(compile_cfun, .{argv[0..1]}).?;
}

fn bytecodeIs(pattern: []const u8, expected: []const u32) void {
    const p = compiled(pattern);
    const got = p.instructions()[0..p.bytecode_len];
    if (std.mem.eql(u32, got, expected)) return;
    std.debug.print("{s}\n  expected {d} words:", .{ pattern, expected.len });
    for (expected) |word| std.debug.print(" {d}", .{word});
    std.debug.print("\n       got {d} words:", .{got.len});
    for (got) |word| std.debug.print(" {d}", .{word});
    std.debug.print("\n", .{});
    @panic("bytecode mismatch");
}

/// Which callbacks a peg's abstract type has, and which it does not. A peg has
/// no `gc` because it
/// owns no memory outside its own allocation, no `tostring` because the
/// default `<core/peg 0x...>` is the intended rendering, and no `compare` or
/// `hash` because two separately compiled pegs are distinct values even when
/// they came from the same source.
///
/// See the header comment for why this reads the table once rather than twice.
fn theAbstractTypeIsShapedAsTheRuntimeExpects() void {
    const zig = &peg.pegType;

    expect(std.mem.eql(u8, "core/peg", zig.name));

    // Which callbacks exist, read off the runtime's own table...
    expect(zig.gc == null);
    expect(zig.gcmark != null);
    expect(zig.get != null);
    expect(zig.put == null);
    expect(zig.marshal != null);
    expect(zig.unmarshal != null);
    expect(zig.tostring == null);
    expect(zig.compare == null);
    expect(zig.hash == null);
    expect(zig.next != null);
    expect(zig.call == null);
    expect(zig.length == null);
    expect(zig.bytes == null);

    // Registered under its own name, which is what lets a marshalled peg name
    // its type on the wire. The registry gives back the pointer it was given
    // at registration, so this compares two addresses at run time rather than
    // something the compiler can fold.
    const registered = registry.getAbstractType(value.fromBytes("core/peg", .symbol));
    expect(registered == zig);
}

/// The five methods, in the order `args.nextmethod` walks them, which is the
/// order `(keys peg)` reports and therefore the order a Janet program sees.
fn theMethodTableAndItsOrder() raise.Raising(void) {
    const val = wrap.fromAbstract(compiled("\"a\""));
    const names = [_][*:0]const u8{ "match", "find", "find-all", "replace", "replace-all" };

    var key = wrap.fromNil();
    for (names) |name| {
        key = try access.next(val, key);
        expect(harness.keywordIs(key, name));
        expect(harness.isType(try access.get(val, key), repr.Tag.cfunction));
    }
    expect(harness.isType(try access.next(val, key), repr.Tag.nil));

    // A non-keyword key is not a method lookup at all.
    expect(harness.isType(try access.get(val, harness.wrapInteger(0)), repr.Tag.nil));
}

/// The alignment formula, written out again rather than imported.
///
/// `makePeg` and `pegUnmarshal` compute the same three offsets and have to
/// agree, the unmarshaller writing through pointers the compiler never sees.
/// Duplicating the formula here is what makes a change to it in the
/// implementation show up as a failure rather than as agreement.
fn padded(offset: usize, size: usize) usize {
    const x = size + offset - 1;
    return x - (x % size);
}

fn theHeaderBytecodeAndConstantsShareOneAllocation() void {
    const p = compiled("'(* (<- \"ab\") (constant 7))");
    const mem = @intFromPtr(p);
    const bytecode_start = padded(@sizeOf(peg.Peg), @sizeOf(u32));
    const constants_start =
        padded(bytecode_start + p.bytecode_len * @sizeOf(u32), @sizeOf(repr.Value));

    expect(@intFromPtr(p.bytecode) == mem + bytecode_start);
    expect(@intFromPtr(p.constants) == mem + constants_start);
    expect(p.num_constants == 1);
    expect(harness.equals(p.constantValues()[0], harness.wrapInteger(7)));

    // Both arrays are aligned for their element type, which is what the
    // padding is computed for.
    expect(@intFromPtr(p.bytecode) % @sizeOf(u32) == 0);
    expect(@intFromPtr(p.constants) % @sizeOf(repr.Value) == 0);

    // And the abstract really is one allocation: its size covers both.
    expect(utils.abstractHead(p).size ==
        constants_start + p.num_constants * @sizeOf(repr.Value));
}

/// One assertion per opcode the compiler can emit, which is the vocabulary the
/// matcher switches on and the verifier walks. Written as literal words for
/// the reason `test/marsh.zig` writes literal bytes: a round trip through the
/// same two halves agrees with itself whatever it encodes.
fn everySpecialEmitsItsInstruction() void {
    // Primitives, which are not tuples at all.
    bytecodeIs("true", &.{ op(constants.PegRule.nchar), 0 });
    bytecodeIs("false", &.{ op(constants.PegRule.notnchar), 0 });
    bytecodeIs("3", &.{ op(constants.PegRule.nchar), 3 });
    bytecodeIs("-3", &.{ op(constants.PegRule.notnchar), 3 });
    // A literal's bytes are packed four to a word, rounded up.
    bytecodeIs("\"abc\"", &.{ op(constants.PegRule.literal), 3, 0x00636261 });
    bytecodeIs("\"abcde\"", &.{ op(constants.PegRule.literal), 5, 0x64636261, 0x00000065 });
    bytecodeIs("\"\"", &.{ op(constants.PegRule.literal), 0 });
    bytecodeIs("@\"ab\"", &.{ op(constants.PegRule.literal), 2, 0x00006261 });

    // A single range is its own opcode; two or more compile to a set.
    bytecodeIs("'(range \"az\")", &.{ op(constants.PegRule.range), 0x007A0061 });
    bytecodeIs("'(set \"ab\")", &.{ op(constants.PegRule.set), 0, 0, 0, 0x00000006, 0, 0, 0, 0 });
    bytecodeIs("'(range \"ab\" \"yz\")", &.{ op(constants.PegRule.set), 0, 0, 0, 0x06000006, 0, 0, 0, 0 });

    bytecodeIs("'(> 2 \"a\")", &.{ op(constants.PegRule.look), 2, 3, op(constants.PegRule.literal), 1, 0x61 });
    // The offset is signed and rides in the word as its two's complement.
    bytecodeIs("'(> -2 \"a\")", &.{ op(constants.PegRule.look), 0xFFFFFFFE, 3, op(constants.PegRule.literal), 1, 0x61 });
    // One argument means an offset of zero.
    bytecodeIs("'(look \"a\")", &.{ op(constants.PegRule.look), 0, 3, op(constants.PegRule.literal), 1, 0x61 });

    // A variadic rule reserves its operand slots before compiling into them.
    bytecodeIs("'(+ 1 2)", &.{ op(constants.PegRule.choice), 2, 4, 6, op(constants.PegRule.nchar), 1, op(constants.PegRule.nchar), 2 });
    bytecodeIs("'(* 1 2)", &.{ op(constants.PegRule.sequence), 2, 4, 6, op(constants.PegRule.nchar), 1, op(constants.PegRule.nchar), 2 });
    bytecodeIs("'(+)", &.{ op(constants.PegRule.choice), 0 });
    bytecodeIs("'(*)", &.{ op(constants.PegRule.sequence), 0 });

    bytecodeIs("'(if 1 2)", &.{ op(constants.PegRule.@"if"), 3, 5, op(constants.PegRule.nchar), 1, op(constants.PegRule.nchar), 2 });
    bytecodeIs("'(if-not 1 2)", &.{ op(constants.PegRule.ifnot), 3, 5, op(constants.PegRule.nchar), 1, op(constants.PegRule.nchar), 2 });
    bytecodeIs("'(lenprefix 1 2)", &.{ op(constants.PegRule.lenprefix), 3, 5, op(constants.PegRule.nchar), 1, op(constants.PegRule.nchar), 2 });
    bytecodeIs("'(! 1)", &.{ op(constants.PegRule.not), 2, op(constants.PegRule.nchar), 1 });

    // Every repetition is one `RULE_BETWEEN` with different bounds.
    const max = std.math.maxInt(u32);
    bytecodeIs("'(between 2 4 1)", &.{ op(constants.PegRule.between), 2, 4, 4, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(some 1)", &.{ op(constants.PegRule.between), 1, max, 4, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(any 1)", &.{ op(constants.PegRule.between), 0, max, 4, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(at-least 3 1)", &.{ op(constants.PegRule.between), 3, max, 4, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(at-most 3 1)", &.{ op(constants.PegRule.between), 0, 3, 4, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(? 1)", &.{ op(constants.PegRule.between), 0, 1, 4, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(repeat 3 1)", &.{ op(constants.PegRule.between), 3, 3, 4, op(constants.PegRule.nchar), 1 });
    // A leading integer is `repeat` spelled without the word.
    bytecodeIs("'(3 1)", &.{ op(constants.PegRule.between), 3, 3, 4, op(constants.PegRule.nchar), 1 });

    bytecodeIs("'(<- 1)", &.{ op(constants.PegRule.capture), 3, 0, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(% 1)", &.{ op(constants.PegRule.accumulate), 3, 0, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(group 1)", &.{ op(constants.PegRule.group), 3, 0, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(unref 1)", &.{ op(constants.PegRule.unref), 3, 0, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(drop 1)", &.{ op(constants.PegRule.drop), 2, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(only-tags 1)", &.{ op(constants.PegRule.only_tags), 2, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(to 1)", &.{ op(constants.PegRule.to), 2, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(thru 1)", &.{ op(constants.PegRule.thru), 2, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(error 1)", &.{ op(constants.PegRule.@"error"), 2, op(constants.PegRule.nchar), 1 });
    // `(error)` with no argument errors on the empty match.
    bytecodeIs("'(error)", &.{ op(constants.PegRule.@"error"), 2, op(constants.PegRule.nchar), 0 });

    bytecodeIs("'($)", &.{ op(constants.PegRule.position), 0 });
    bytecodeIs("'(line)", &.{ op(constants.PegRule.line), 0 });
    bytecodeIs("'(column)", &.{ op(constants.PegRule.column), 0 });
    bytecodeIs("'(backmatch)", &.{ op(constants.PegRule.backmatch), 0 });
    bytecodeIs("'(??)", &.{op(constants.PegRule.debug)});
    bytecodeIs("'(argument 2)", &.{ op(constants.PegRule.argument), 2, 0 });
    bytecodeIs("'(constant :x)", &.{ op(constants.PegRule.constant), 0, 0 });
    bytecodeIs("'(nth 2 1)", &.{ op(constants.PegRule.nth), 2, 4, 0, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(number 1)", &.{ op(constants.PegRule.capture_num), 4, 0, 0, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(number 1 16)", &.{ op(constants.PegRule.capture_num), 4, 16, 0, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(number 1 nil)", &.{ op(constants.PegRule.capture_num), 4, 0, 0, op(constants.PegRule.nchar), 1 });

    bytecodeIs("'(sub 1 2)", &.{ op(constants.PegRule.sub), 3, 5, op(constants.PegRule.nchar), 1, op(constants.PegRule.nchar), 2 });
    bytecodeIs("'(til 1 2)", &.{ op(constants.PegRule.til), 3, 5, op(constants.PegRule.nchar), 1, op(constants.PegRule.nchar), 2 });
    bytecodeIs("'(split 1 2)", &.{ op(constants.PegRule.split), 3, 5, op(constants.PegRule.nchar), 1, op(constants.PegRule.nchar), 2 });
    bytecodeIs("'(/ 1 :x)", &.{ op(constants.PegRule.replace), 4, 0, 0, op(constants.PegRule.nchar), 1 });
    bytecodeIs("~(cmt 1 ,identity)", &.{ op(constants.PegRule.matchtime), 4, 0, 0, op(constants.PegRule.nchar), 1 });
    bytecodeIs("~(cms 1 ,identity)", &.{ op(constants.PegRule.matchsplice), 4, 0, 0, op(constants.PegRule.nchar), 1 });

    // The width and the two flag bits share one operand word.
    bytecodeIs("'(uint 4)", &.{ op(constants.PegRule.readint), 0x04, 0 });
    bytecodeIs("'(int 4)", &.{ op(constants.PegRule.readint), 0x14, 0 });
    bytecodeIs("'(uint-be 4)", &.{ op(constants.PegRule.readint), 0x24, 0 });
    bytecodeIs("'(int-be 4)", &.{ op(constants.PegRule.readint), 0x34, 0 });

    // Every alias emits what the symbol it aliases emits.
    bytecodeIs("'(not 1)", &.{ op(constants.PegRule.not), 2, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(quote 1)", &.{ op(constants.PegRule.capture), 3, 0, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(capture 1)", &.{ op(constants.PegRule.capture), 3, 0, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(accumulate 1)", &.{ op(constants.PegRule.accumulate), 3, 0, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(choice 1)", &.{ op(constants.PegRule.choice), 1, 3, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(sequence 1)", &.{ op(constants.PegRule.sequence), 1, 3, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(opt 1)", &.{ op(constants.PegRule.between), 0, 1, 4, op(constants.PegRule.nchar), 1 });
    bytecodeIs("'(position)", &.{ op(constants.PegRule.position), 0 });
    bytecodeIs("'(debug)", &.{op(constants.PegRule.debug)});
}

/// Tags are numbered from one, because zero is the "no tag" sentinel, and the
/// same keyword reuses its number. `(-> :t)` and `(backmatch :t)` are also the
/// only two specials that set `has_backref`, which is what makes the matcher
/// maintain the third capture stack at all.
fn tagsAreNumberedAndBackrefsAreFlagged() void {
    bytecodeIs("'(<- 1 :a)", &.{ op(constants.PegRule.capture), 3, 1, op(constants.PegRule.nchar), 1 });
    // The third capture is the first one again, same tuple and same grammar,
    // so it is cached rather than emitted, and its tag is reused too.
    bytecodeIs("'(* (<- 1 :a) (<- 1 :b) (<- 1 :a))", &.{
        op(constants.PegRule.sequence), 3, 5, 10,                          5,
        op(constants.PegRule.capture),  8, 1, op(constants.PegRule.nchar), 1,
        op(constants.PegRule.capture),  8, 2,
    });

    expect(compiled("\"a\"").has_backref == false);
    expect(compiled("'(<- 1 :a)").has_backref == false);
    expect(compiled("'(-> :a)").has_backref == true);
    expect(compiled("'(backmatch :a)").has_backref == true);
    expect(compiled("'(backref :a)").has_backref == true);
    // `unref` names a tag without needing the tagged stack.
    expect(compiled("'(unref 1 :a)").has_backref == false);
}

/// A pattern already compiled in this grammar is reused rather than emitted
/// twice, which is what makes a recursive grammar terminate. A tuple is cached
/// only in the grammar it was seen in, because `(+ :a :b)` means different
/// things under different bindings; anything else goes to the root table.
fn theCompilerCachesRules() void {
    // Two references to the same primitive share one rule.
    bytecodeIs("'(* 1 1)", &.{ op(constants.PegRule.sequence), 2, 4, 4, op(constants.PegRule.nchar), 1 });
    // A recursive grammar refers back to a rule still being built.
    bytecodeIs("'{:main (* \"a\" (? :main))}", &.{
        op(constants.PegRule.sequence), 2, 4,    7,
        op(constants.PegRule.literal),  1, 0x61, op(constants.PegRule.between),
        0,                              1, 0,
    });
}

/// Every one of these renders through `pegPanic`, which prints the form being
/// compiled and then the message. There is no exception: all fifty-seven
/// specials check their arity the same way, so every grammar error names the
/// form that caused it.
fn grammarErrorsNameTheForm() void {
    expect(grammarError("'(unknown-special)").endsWith(", unknown special unknown-special"));
    expect(grammarError("'()").endsWith(", tuple in grammar must have non-zero length"));
    expect(grammarError("'(\"a\")").endsWith(", expected grammar command, found \"a\""));
    expect(grammarError(":nope").endsWith(", unknown rule"));
    expect(grammarError("{:notmain 1}").endsWith(", grammar requires :main rule"));
    expect(grammarError("@{:notmain 1}").endsWith(", grammar requires :main rule"));
    expect(grammarError("print").endsWith(", unexpected peg source"));

    expect(grammarError("'(! 1 2)").endsWith(", expected 1 argument, got 2"));
    expect(grammarError("'(sub 1)").endsWith(", expected 2 arguments, got 1"));
    expect(grammarError("'(nth 1)").endsWith(", arity mismatch, expected at least 2, got 1"));
    expect(grammarError("'(?? 1)").endsWith(", arity mismatch, expected at most 0, got 1"));

    expect(grammarError("'(set 1)").endsWith(", expected string for character set"));
    expect(grammarError("'(range 1)").endsWith(", expected string for character range"));
    expect(grammarError("'(range \"abc\")").endsWith(", expected string to have length 2, got \"abc\""));
    expect(grammarError("'(range \"ba\")").endsWith(", range \"ba\" is empty"));
    expect(grammarError("'(> \"x\" 1)").endsWith(", expected integer, got \"x\""));
    expect(grammarError("'(repeat -1 1)").endsWith(", expected non-negative integer, got -1"));
    expect(grammarError("'(-1 1)").endsWith(", expected non-negative integer, got -1"));
    expect(grammarError("'(<- 1 \"a\")").endsWith(", expected keyword for capture tag, got \"a\""));
    expect(grammarError("'(number 1 40)").endsWith(", expected integer between 2 and 36, got 40"));
    expect(grammarError("'(number 1 2.5)").endsWith(", expected integer between 2 and 36, got 2.5"));
    expect(grammarError("'(cmt 1 2)").endsWith(", expected function or cfunction, got 2"));
    expect(grammarError("'(uint " ++ max_readint_width_text ++ "1)")
        .endsWith(", width must be between 0 and " ++ max_readint_width_text ++
        ", got " ++ max_readint_width_text ++ "1"));

    // Two hundred and fifty-five tags fit in the byte the tag stack uses; the
    // two hundred and fifty-sixth does not.
    expect(grammarError("(tuple '* ;(map (fn [i] ~(<- 1 ,(keyword \"t\" i))) (range 256)))")
        .endsWith(", too many tags - up to 255 tags are supported per peg"));

    // `(constant)` is spelled out whole rather than left to `endsWith`,
    // because the prefix naming the form is what this case is about.
    expect(grammarError("'(constant)")
        .says("grammar error in (constant), arity mismatch, expected at least 1, got 0"));
}

/// The `[status message]` pair a `(protect ...)` produced.
fn protectedResult(val: repr.Value) struct { ok: bool, message: repr.Value } {
    const pair = wrap.toTuple(val);
    return .{ .ok = wrap.toBoolean(pair[0]), .message = pair[1] };
}

/// The compiler and the matcher each have a recursion budget, and they are not
/// the same budget: the matcher's is reset per attempt by `pegCallReset`, so
/// `peg/find` gets a fresh one at every offset. Both start at the recursion
/// guard.
///
/// This asserts the compiler's. `theMatcherReachesItsRecursionGuard` asserts
/// the other, and needs a left-recursive grammar to do it.
fn theCompilerBoundsBothOfItsRecursions() void {
    // A keyword chain that resolves through more than the guard allows.
    // `pegCompile1` walks this in a loop rather than by recursing.
    const chained = protectedResult(evaluate(
        \\(do (def g @{})
        \\    (loop [i :range [0 1100]] (put g (keyword "r" i) (keyword "r" (+ i 1))))
        \\    (put g :main :r0)
        \\    (put g (keyword "r" 1100) 1)
        \\    (protect (peg/compile g)))
    ));
    expect(!chained.ok);
    expect(harness.stringValueIs(chained.message, "grammar error in :r1024, reference chain too deep"));

    // Nesting rather than chaining spends the other counter, and that one is
    // real recursion through `pegCompile1`.
    const nested = protectedResult(evaluate(
        \\(do (var p 1)
        \\    (loop [_ :range [0 1100]] (set p ~(! ,p)))
        \\    (protect (peg/compile p)))
    ));
    expect(!nested.ok);
    {
        // The form this one names is a thousand rules deep, so only the tail
        // of the message can be compared.
        const message = wrap.toString(nested.message);
        const length: usize = strings.head(message).length;
        expect(std.mem.endsWith(u8, message[0..length], ", peg grammar recursed too deeply"));
    }

    // One below the budget still compiles, which is what makes the number
    // above a boundary rather than an upper bound.
    const just_inside = protectedResult(evaluate(
        \\(do (var p 1)
        \\    (loop [_ :range [0 1022]] (set p ~(! ,p)))
        \\    (protect (peg/compile p)))
    ));
    expect(just_inside.ok);
}

/// A compiled peg is a marshalled abstract, and its payload is the bytecode
/// word for word. The bytes below pin the opcode numbers: renumbering the
/// `constants.PegRule` enum would keep every Janet test passing and invalidate
/// every stored peg.
fn theMarshalledFormIsTheBytecode() raise.Raising(void) {
    const p = compiled("\"a\"");
    const buffer = buffers.new(32);
    _ = keep(wrap.fromBuffer(buffer));
    try marsh.marshal(buffer, wrap.fromAbstract(p), null, 0);

    const expected = [_]u8{
        217, // LB_ABSTRACT
        207,
        8,
        'c',
        'o',
        'r',
        'e',
        '/',
        'p',
        'e',
        'g',
        3, // bytecode_len
        0, // num_constants
        @intCast(op(constants.PegRule.literal)), 1, 0x61, // the three words
    };
    const got = buffer.slice();
    if (!std.mem.eql(u8, got, &expected)) {
        std.debug.print("expected {d} bytes:", .{expected.len});
        for (expected) |byte| std.debug.print(" {x:0>2}", .{byte});
        std.debug.print("\n     got {d} bytes:", .{got.len});
        for (got) |byte| std.debug.print(" {x:0>2}", .{byte});
        std.debug.print("\n", .{});
        @panic("peg wire format mismatch");
    }

    // And back, into an equal but distinct peg.
    const back = keep(try marsh.unmarshal(buffer.slice(), 0, null, null));
    expect(args_core.checkabstract(back, &peg.pegType) != null);
    const round: *peg.Peg = @ptrCast(@alignCast(wrap.toAbstract(back)));
    expect(round != p);
    expect(round.bytecode_len == 3);
    expect(round.num_constants == 0);
    expect(round.has_backref == false);
    expect(std.mem.eql(u32, round.instructions()[0..3], p.instructions()[0..3]));
    // The unmarshaller reproduces the compiler's layout, not just its words.
    expect(@intFromPtr(round.bytecode) - @intFromPtr(round) ==
        @intFromPtr(p.bytecode) - @intFromPtr(p));
}

/// An opcode as the one byte a marshalled word of it is.
///
/// Everything from here down builds a peg stream by hand. `pegUnmarshal` is
/// the only way bytecode the compiler could not have produced reaches the
/// matcher, and most of the verifier is unreachable without it.
///
/// Every crafted stream below is a *byte* string rather than a word list:
/// `pegUnmarshal` reads its counts and its words through the marshal integer
/// encoding, and a value under 128 is one bare byte there. So an opcode
/// appears in these streams as its own number, and writing it as `b(RULE_NOT)`
/// rather than as `10` is what keeps a renumbering of the enum from silently
/// changing what each case tests.
inline fn b(opcode: anytype) u8 {
    return if (@TypeOf(opcode) == constants.PegRule) @intCast(opcode.number()) else @intCast(opcode);
}

fn crafted(comptime tail: []const u8) []const u8 {
    return &(peg_header ++ tail[0..tail.len].*);
}

fn unmarshalStream(bytes: []const u8) raise.Raising(repr.Value) {
    return marsh.unmarshal(bytes, 0, null, null);
}

/// A crafted stream the verifier must reject, asserted by its message.
fn rejected(comptime tail: []const u8) void {
    const refusal = harness.raised(unmarshalStream, .{crafted(tail)});
    expect(refusal != null);
    expect(refusal.?.says("invalid peg bytecode"));
}

/// A crafted stream the verifier must accept.
fn accepted(comptime tail: []const u8) *peg.Peg {
    const val = keep(unmarshalStream(crafted(tail)) catch
        @panic("a stream this contract expects to be accepted was refused"));
    expect(args_core.checkabstract(val, &peg.pegType) != null);
    return @ptrCast(@alignCast(wrap.toAbstract(val)));
}

fn theVerifierWalksEveryInstruction() void {
    // The shortest valid program, and the shape everything below varies.
    const ok = accepted(&.{ 2, 0, b(constants.PegRule.nchar), 1 });
    expect(ok.bytecode_len == 2);
    expect(ok.has_backref == false);

    // An opcode past the end of the vocabulary. Kept under 128 so that it is
    // one byte in the marshal integer encoding, like every other word here.
    rejected(&.{ 2, 0, 100, 0 });
    // A rule operand past the end of the bytecode.
    rejected(&.{ 2, 0, b(constants.PegRule.not), 9 });
    // A constant operand past the end of the constants.
    rejected(&.{ 3, 0, b(constants.PegRule.constant), 0, 0 });
    // An instruction that runs off the end.
    rejected(&.{ 3, 0, b(constants.PegRule.nchar), 1, b(constants.PegRule.nchar) });
    // A rule operand that points into the middle of another instruction:
    // word 1 is referenced but is not an instruction start.
    rejected(&.{ 4, 0, b(constants.PegRule.not), 1, b(constants.PegRule.nchar), 1 });
    // Unreachable bytecode is rejected too, which is stricter than a
    // depth-first walk would be: word 2 is an instruction nothing refers to,
    // and that is fine; only the reverse is an error.
    _ = accepted(&.{ 4, 0, b(constants.PegRule.nchar), 1, b(constants.PegRule.nchar), 1 });

    // `has_backref` is recovered from the bytecode rather than marshalled.
    expect(accepted(&.{ 3, 0, b(constants.PegRule.gettag), 1, 0 }).has_backref == true);
    expect(accepted(&.{ 2, 0, b(constants.PegRule.backmatch), 1 }).has_backref == true);
}

/// A program with no instructions has no first instruction, so it is refused
/// rather than run. The shortest program any compiler emits is two words.
///
/// The second stream is the one that matters: with no bytecode the padding
/// puts the constants where the bytecode would start on every 64-bit build, so
/// an accepted empty program executes its first constant as an opcode. Here it
/// is a double whose low word is `RULE_NCHAR` and whose high word is 3, which
/// would consume exactly three bytes.
fn anEmptyProgramIsRefused() void {
    rejected(&.{ 0, 0 });
    rejected(&.{
        0, 1, // no bytecode, one constant
        lb_real, b(constants.PegRule.nchar), 0, 0, 0, 3, 0, 0, 0, // little endian
    });
}

/// `(argument n)` takes a non-negative index from the compiler; crafted
/// bytecode need not, so the matcher tests both ends of the range and gives
/// nil outside it, which is what an index past the end already gave.
///
/// The stream is accepted, because a nonsensical operand is not by itself
/// invalid bytecode; what is asserted is that running it is safe. `peg/match`
/// here is called with no extra arguments at all, so `extrav` is null: the
/// index is what decides whether that null is ever reached.
fn aNegativeArgumentIndexCapturesNil() raise.Raising(void) {
    // The operand is the one word here that needs the five-byte integer
    // encoding, because 0xFFFFFFFF is not a small natural.
    const p = accepted(&.{ 3, 0, b(constants.PegRule.argument), lb_integer, 255, 255, 255, 255, 0 });
    expect(p.bytecode_len == 3);
    expect(p.instructions()[1] == 0xFFFFFFFF);

    var args = [2]repr.Value{ wrap.fromAbstract(p), value.fromBytes("x", .string) };
    const captures = try vm_calls.mcall("match", args[0..2]);
    expect(harness.isType(captures, repr.Tag.array));
    const array = wrap.toArray(captures);
    expect(array.count == 1);
    expect(harness.isType(array.slice()[0], repr.Tag.nil));
}

/// An instruction count is refused when the stream is too short for it,
/// before anything is allocated or multiplied. One word is at least one
/// byte on the wire, so the bytes remaining are the bound.
///
/// The first stream names 2^62 words, which is the length whose byte count
/// wraps to zero. The second names four, which is small and still more than
/// the two bytes after it. The third names two and supplies them, which is the
/// shortest program there is: the bound must not refuse that.
fn anInstructionCountLongerThanTheStreamIsRefused() void {
    rejected(&.{
        0xF0 + 8, 0, 0, 0, 0, 0, 0, 0, 0x40, // bytecode_len = 1 << 62
        0, // num_constants
    });
    rejected(&.{ 4, 0, b(constants.PegRule.nchar), 1 });
    _ = accepted(&.{ 2, 0, b(constants.PegRule.nchar), 1 });
}

/// A constant count is refused on the same ground and by the same bound: every
/// constant on the wire has a lead byte, so the bytes remaining bound the
/// count of them exactly as they bound the count of words.
///
/// The first stream names 2^32 - 1 constants in seventeen bytes. Unbounded
/// that is a request for 2^32 values, 32 GiB where a `Value` is eight bytes
/// wide and 64 GiB where it is sixteen, and on a 32-bit target a product that
/// wraps the constants term to zero and leaves the fill loop writing past an
/// allocation the size of its header. The second names four and supplies none.
/// The third names one and supplies it, which the bound must not refuse.
fn aConstantCountLongerThanTheStreamIsRefused() void {
    rejected(&.{
        0, // bytecode_len
        lb_integer, 255, 255, 255, 255, // num_constants = 0xFFFFFFFF
    });
    rejected(&.{ 2, 4, b(constants.PegRule.nchar), 1 });
    _ = accepted(&.{ 2, 1, b(constants.PegRule.nchar), 1, lb_nil });

    // The bound is on the sum, and this is the case that says so. Two
    // words and two constants are each within the three bytes that follow,
    // and the four of them together are not. Two independent tests accept
    // this stream and fail later, with `unexpected end of source` after the
    // allocation; one test on the sum refuses it before.
    rejected(&.{ 2, 2, b(constants.PegRule.nchar), 1, lb_nil });
}

/// A literal's byte count is the stream's too, and the word count derived from
/// it is computed wide enough that it cannot wrap past the bounds check about
/// to use it. At 0xFFFFFFFF the count `2 + ((len + 3) >> 2)` is 2 in 32-bit
/// arithmetic, which scores a literal claiming four billion bytes as occupying
/// the two words it was written in.
fn aLiteralLengthCannotWrapItsWordCount() void {
    rejected(&.{ 2, 0, b(constants.PegRule.literal), lb_integer, 255, 255, 255, 255 });
    // The honest shapes either side of it: a two-word empty literal, and a
    // four-byte literal whose bytes are the word after it.
    _ = accepted(&.{ 2, 0, b(constants.PegRule.literal), 0 });
    _ = accepted(&.{ 3, 0, b(constants.PegRule.literal), 4, lb_integer, 'd', 'c', 'b', 'a' });
    // And one whose bytes are not there.
    rejected(&.{ 2, 0, b(constants.PegRule.literal), 4 });
}

/// A readint operand packs the width into its low four bits and the
/// signedness and endianness above them, so the width is what the verifier
/// compares. All four specials round-trip; the compiler's own output is not
/// bytecode the verifier gets to refuse.
fn everyReadintPegSurvivesARoundTrip() raise.Raising(void) {
    for ([_][]const u8{ "'(uint 4)", "'(int 4)", "'(uint-be 4)", "'(int-be 4)" }) |pattern| {
        const p = compiled(pattern);
        const buffer = buffers.new(32);
        _ = keep(wrap.fromBuffer(buffer));
        try marsh.marshal(buffer, wrap.fromAbstract(p), null, 0);
        const back = keep(try unmarshalStream(buffer.slice()));
        expect(args_core.checkabstract(back, &peg.pegType) != null);
    }
    // The width is still bounded, with the two flag bits set or clear.
    const signed_be: u32 = (1 << 4) | (1 << 5);
    _ = accepted(&.{ 3, 0, b(constants.PegRule.readint), @intCast(max_readint_width), 0 });
    rejected(&.{ 3, 0, b(constants.PegRule.readint), @intCast(max_readint_width + 1), 0 });
    _ = accepted(&.{ 3, 0, b(constants.PegRule.readint), lb_integer, 0, 0, 0, @intCast(signed_be | @as(u32, @intCast(max_readint_width))), 0 });
    rejected(&.{ 3, 0, b(constants.PegRule.readint), lb_integer, 0, 0, 0, @intCast(signed_be | @as(u32, @intCast(max_readint_width + 1))), 0 });
}

/// Every opcode arm of the verifier that carries a bounds check of its own,
/// one crafted stream per check.
///
/// `theVerifierWalksEveryInstruction` above asserts the walk's shape through
/// four opcodes; the arms below have their own operands and their own bounds,
/// and each was reachable only through this file. Two checks per arm, where it
/// has two: an instruction the bytecode is too short to hold, and an operand
/// that indexes exactly one past the end. The second is the one that matters
/// most, because `>= blen` and `> blen` differ only there and the matcher
/// bounds-checks nothing it is handed.
///
/// The programs are two words unless the arm needs more: the opcode at word 0
/// with its operands after it, and a trailing `nchar 1` where the arm needs a
/// valid rule to point at.
fn everyVerifierArmBoundsItsOperands() void {
    const nchar = b(constants.PegRule.nchar);

    // .look, [offset, rule]: three words, and the rule operand is word 2.
    rejected(&.{ 2, 0, b(constants.PegRule.look), 0 });
    rejected(&.{ 3, 0, b(constants.PegRule.look), 0, 3 });
    _ = accepted(&.{ 5, 0, b(constants.PegRule.look), 0, 3, nchar, 1 });

    // .choice and .sequence, [len, rules...]: the count is word 1 and every
    // word after it is a rule index. The first stream is one word long, which
    // is the case where the opcode has no count word at all: at two words the
    // instruction is exactly as long as the bytecode and does not overflow.
    rejected(&.{ 1, 0, b(constants.PegRule.choice) });
    rejected(&.{ 1, 0, b(constants.PegRule.sequence) });
    rejected(&.{ 2, 0, b(constants.PegRule.choice), 1 });
    rejected(&.{ 3, 0, b(constants.PegRule.choice), 1, 3 });
    rejected(&.{ 3, 0, b(constants.PegRule.sequence), 1, 3 });
    _ = accepted(&.{ 5, 0, b(constants.PegRule.sequence), 1, 3, nchar, 1 });

    // .if, .ifnot and .lenprefix, [rule_a, rule_b]: two rule operands.
    rejected(&.{ 2, 0, b(constants.PegRule.@"if"), 0 });
    rejected(&.{ 3, 0, b(constants.PegRule.@"if"), 3, 3 });
    rejected(&.{ 5, 0, b(constants.PegRule.@"if"), 3, 5, nchar, 1 });
    rejected(&.{ 3, 0, b(constants.PegRule.ifnot), 3, 3 });
    rejected(&.{ 3, 0, b(constants.PegRule.lenprefix), 3, 3 });
    _ = accepted(&.{ 5, 0, b(constants.PegRule.@"if"), 3, 3, nchar, 1 });

    // .between, [lo, hi, rule]: four words, the rule at word 3.
    rejected(&.{ 3, 0, b(constants.PegRule.between), 0, 1 });
    rejected(&.{ 4, 0, b(constants.PegRule.between), 0, 1, 4 });
    _ = accepted(&.{ 6, 0, b(constants.PegRule.between), 0, 1, 4, nchar, 1 });

    // .capture_num, [rule, base, tag]: four words, the rule at word 1.
    rejected(&.{ 3, 0, b(constants.PegRule.capture_num), 4, 0 });
    rejected(&.{ 4, 0, b(constants.PegRule.capture_num), 4, 0, 0 });
    _ = accepted(&.{ 6, 0, b(constants.PegRule.capture_num), 4, 0, 0, nchar, 1 });

    // .accumulate, .group, .capture and .unref, [rule, tag].
    rejected(&.{ 2, 0, b(constants.PegRule.accumulate), 3 });
    rejected(&.{ 3, 0, b(constants.PegRule.accumulate), 3, 0 });
    rejected(&.{ 3, 0, b(constants.PegRule.group), 3, 0 });
    rejected(&.{ 3, 0, b(constants.PegRule.capture), 3, 0 });
    rejected(&.{ 3, 0, b(constants.PegRule.unref), 3, 0 });
    _ = accepted(&.{ 5, 0, b(constants.PegRule.accumulate), 3, 0, nchar, 1 });

    // .replace, .matchtime and .matchsplice, [rule, constant, tag]: a rule
    // index bounded by the bytecode and a constant index bounded by the
    // constants, which is a different limit and its own check.
    rejected(&.{ 3, 0, b(constants.PegRule.replace), 4, 0 });
    rejected(&.{ 4, 1, b(constants.PegRule.replace), 4, 0, 0, lb_nil });
    rejected(&.{ 6, 1, b(constants.PegRule.replace), 4, 1, 0, nchar, 1, lb_nil });
    rejected(&.{ 6, 1, b(constants.PegRule.matchtime), 4, 1, 0, nchar, 1, lb_nil });
    rejected(&.{ 6, 1, b(constants.PegRule.matchsplice), 4, 1, 0, nchar, 1, lb_nil });
    _ = accepted(&.{ 6, 1, b(constants.PegRule.replace), 4, 0, 0, nchar, 1, lb_nil });

    // .sub, .til and .split, [rule, rule]: both operands bounded.
    rejected(&.{ 2, 0, b(constants.PegRule.sub), 3 });
    rejected(&.{ 3, 0, b(constants.PegRule.sub), 3, 3 });
    // Each operand is bounded on its own, so each needs a stream where it is
    // the one out of range and the other is not.
    rejected(&.{ 5, 0, b(constants.PegRule.sub), 3, 5, nchar, 1 });
    rejected(&.{ 5, 0, b(constants.PegRule.sub), 5, 3, nchar, 1 });
    rejected(&.{ 5, 0, b(constants.PegRule.til), 5, 3, nchar, 1 });
    rejected(&.{ 5, 0, b(constants.PegRule.split), 5, 3, nchar, 1 });
    rejected(&.{ 3, 0, b(constants.PegRule.til), 3, 3 });
    rejected(&.{ 3, 0, b(constants.PegRule.split), 3, 3 });
    _ = accepted(&.{ 5, 0, b(constants.PegRule.sub), 3, 3, nchar, 1 });

    // .error, .drop, .only_tags, .not, .to and .thru, [rule]. `not` is the one
    // the walk above already uses; the other five share its arm and its bound.
    rejected(&.{ 1, 0, b(constants.PegRule.@"error") });
    rejected(&.{ 2, 0, b(constants.PegRule.@"error"), 2 });
    rejected(&.{ 2, 0, b(constants.PegRule.drop), 2 });
    rejected(&.{ 2, 0, b(constants.PegRule.only_tags), 2 });
    rejected(&.{ 2, 0, b(constants.PegRule.to), 2 });
    rejected(&.{ 2, 0, b(constants.PegRule.thru), 2 });
    _ = accepted(&.{ 4, 0, b(constants.PegRule.@"error"), 2, nchar, 1 });

    // .nth, [nth, rule, tag]: four words, the rule at word 2.
    rejected(&.{ 3, 0, b(constants.PegRule.nth), 0, 4 });
    rejected(&.{ 4, 0, b(constants.PegRule.nth), 0, 4, 0 });
    _ = accepted(&.{ 6, 0, b(constants.PegRule.nth), 0, 4, 0, nchar, 1 });

    // .constant, [constant, tag]: bounded by the constants rather than the
    // bytecode, and the instruction itself can run off the end.
    rejected(&.{ 2, 1, b(constants.PegRule.constant), 0, lb_nil });
    _ = accepted(&.{ 3, 1, b(constants.PegRule.constant), 0, 0, lb_nil });

    // .literal with no count word after it at all, which is the check before
    // the one `aLiteralLengthCannotWrapItsWordCount` reaches.
    rejected(&.{ 1, 0, b(constants.PegRule.literal) });

    // .readint with no tag word after it.
    rejected(&.{ 2, 0, b(constants.PegRule.readint), 1 });
}

/// The matcher's budget, which is spent one frame per nested rule and reset
/// per attempt. A left-recursive grammar is what reaches it: the depth follows
/// the subject's length rather than the pattern's.
///
/// A hundred thousand characters is far past the budget of 1024, so what the
/// case distinguishes is reaching the guard from running out of stack on the
/// way, the guard counting frames without knowing how large one is.
fn theMatcherReachesItsRecursionGuard() raise.Raising(void) {
    const deep = protectedResult(evaluate(
        \\(protect (peg/match (peg/compile '{:main (+ (* "a" :main) 0)})
        \\                    (string/repeat "a" 100000)))
    ));
    expect(!deep.ok);
    expect(harness.stringValueIs(deep.message, "peg/match recursed too deeply"));

    // A subject short enough to fit inside the budget still matches, which is
    // what makes the refusal above the guard rather than the grammar.
    const shallow = protectedResult(evaluate(
        \\(protect (peg/match (peg/compile '{:main (+ (* "a" :main) 0)})
        \\                    (string/repeat "a" 100)))
    ));
    expect(shallow.ok);
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() raise.Raising(void) {
    test_env = harness.coreEnv();
    gc_alloc.gcroot(wrap.fromTable(test_env));
    rooted = arrays.new(0);
    gc_alloc.gcroot(wrap.fromArray(rooted));
    compile_cfun = harness.core("peg/compile");

    theAbstractTypeIsShapedAsTheRuntimeExpects();
    try theMethodTableAndItsOrder();
    theHeaderBytecodeAndConstantsShareOneAllocation();
    everySpecialEmitsItsInstruction();
    tagsAreNumberedAndBackrefsAreFlagged();
    theCompilerCachesRules();
    grammarErrorsNameTheForm();
    theCompilerBoundsBothOfItsRecursions();
    try theMarshalledFormIsTheBytecode();
    theVerifierWalksEveryInstruction();
    anEmptyProgramIsRefused();
    try aNegativeArgumentIndexCapturesNil();
    anInstructionCountLongerThanTheStreamIsRefused();
    aConstantCountLongerThanTheStreamIsRefused();
    aLiteralLengthCannotWrapItsWordCount();
    try everyReadintPegSurvivesARoundTrip();
    everyVerifierArmBoundsItsOperands();
    try theMatcherReachesItsRecursionGuard();
}

pub fn run() void {
    harness.init();
    body() catch @panic("peg: an entry point raised unexpectedly");
    vm_lifecycle.deinit();
}
