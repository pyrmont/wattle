//! Behavioral contract for the PEG engine.
//!
//! The reason this file exists rather than leaning on `test/suite-peg.janet`:
//! that suite has 366 assertions and every one of them is about what a pattern
//! *matches*. Three things it cannot see:
//!
//!  - **The bytecode.** The compiler, the matcher and the verifier share a
//!    private instruction encoding that appears in no header and has no other
//!    consumer, so a change made consistently in all three is invisible from
//!    Janet. It is also a file format: a marshalled peg is those words, so a
//!    renumbered opcode silently invalidates every stored peg.
//!  - **The one allocation.** `makePeg` packs the header, the bytecode and the
//!    constants into a single `janet_abstract`, with padding computed so that
//!    each array is aligned. Nothing in Janet can observe the layout, and
//!    `pegUnmarshal` has to reproduce it exactly or read the wrong words.
//!  - **Crafted bytecode.** `pegUnmarshal` is the untrusted entry point, and
//!    most of what it must reject cannot be produced by the compiler at all.
//!
//! `janet_peg_type` is public API, so the shape of its callback table is a
//! contract too, and one Janet cannot see.
//!
//! ## What the migration changed
//!
//! **The callback table has two spellings here, and comparing them is the
//! oracle the C version could not have.** `janet.h` declares
//! `janet_peg_type` as a `JanetAbstractType`; `peg.zig` defines it as an
//! `abstract_type.AbstractType`, which is the same layout with seven of the
//! fifteen callbacks typed as raising Zig functions. The C contract saw only
//! the first, so `janet_peg_type.gc == NULL` was a fact about one description.
//! Reading both and requiring them to agree is rule 25's shape — a duplication
//! the *port* introduced, wanting the contract the old pair had — and it is
//! what would catch a field inserted into one mirror and not the other, which
//! `abstract_type.zig`'s `@sizeOf` assertion cannot.
//!
//! **`peg/compile` is still reached as a cfunction rather than by import**,
//! for the reason the C original gives: a grammar error has to arrive as a
//! refusal rather than as a status code `janet_dostring` has already caught.
//! What changed is that no shim is involved — a cfunction *is* a raising Zig
//! function, so `harness.core` and `harness.raised` are the whole of it and
//! `janet_contract_call_cfunction` loses a user.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const raise = @import("raise");
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
const peg = subsystems.peg;
const marsh = subsystems.marsh;
const access = subsystems.access;
const vm_calls = subsystems.vm_calls;
const abstract_type = subsystems.abstract_type;

const assert = std.debug.assert;
const op = harness.op;

var test_env: *c.JanetTable = undefined;

/// Compiled pegs and the forms they came from. A `Janet` in a Zig local is not
/// a GC root, and compiling one form allocates enough to collect the next.
var rooted: *c.JanetArray = undefined;

fn keep(value: c.Janet) c.Janet {
    c.janet_array_push(rooted, value);
    return value;
}

/// `peg/compile`, resolved once. The type assertion is `harness.core`'s.
var compile_cfun: raise.CFunction = undefined;

/// Six without `JANET_INT_TYPES` and eight with it, because a `double` capture
/// cannot carry more than 53 bits. Both the compiler's limit and the
/// verifier's move with it, so the assertions that name a width have to as
/// well.
///
/// Rule 35: read from the translation rather than from a build condition.
/// `janet_unwrap_s64` exists exactly when the boxed integer types do, which is
/// the same test `peg.zig` itself makes.
const max_readint_width: u32 = if (@hasDecl(c, "janet_unwrap_s64")) 8 else 6;
const max_readint_width_text = if (max_readint_width == 8) "8" else "6";

// ------------------------------------------------------------- evaluation

fn evaluate(source: [*:0]const u8) c.Janet {
    var out = c.janet_wrap_nil();
    if (c.janet_dostring(test_env, source, "peg-contract", &out) != 0) {
        std.debug.print("evaluating {s} failed\n", .{source});
        @panic("evaluation failed");
    }
    return keep(out);
}

fn compiled(pattern: []const u8) *c.JanetPeg {
    var source: [1024]u8 = undefined;
    const written = std.fmt.bufPrintZ(&source, "(peg/compile {s})", .{pattern}) catch
        @panic("pattern too long");
    const value = evaluate(written.ptr);
    assert(c.janet_checkabstract(value, abstract_type.stored(&peg.janet_peg_type)) != null);
    return @ptrCast(@alignCast(c.janet_unwrap_abstract(value)));
}

/// The refusal `peg/compile` made for `source`, or null if it compiled.
///
/// `source` is Janet source for the *pattern*, evaluated before the scope
/// opens so that only the compilation is inside it.
fn grammarError(source: [*:0]const u8) harness.Raise {
    var argv = [_]c.Janet{evaluate(source)};
    return harness.raised(compile_cfun, .{ @as(i32, 1), &argv }).?;
}

fn bytecodeIs(pattern: []const u8, expected: []const u32) void {
    const p = compiled(pattern);
    const got = p.bytecode[0..p.bytecode_len];
    if (std.mem.eql(u32, got, expected)) return;
    std.debug.print("{s}\n  expected {d} words:", .{ pattern, expected.len });
    for (expected) |word| std.debug.print(" {d}", .{word});
    std.debug.print("\n       got {d} words:", .{got.len});
    for (got) |word| std.debug.print(" {d}", .{word});
    std.debug.print("\n", .{});
    @panic("bytecode mismatch");
}

// -------------------------------------------------------- the abstract type

/// `janet_peg_type` is exported from `janet.h`, so an embedder sees which
/// callbacks a peg has and which it does not. A peg has no `gc` because it
/// owns no memory outside its own allocation, no `tostring` because the
/// default `<core/peg 0x...>` is the intended rendering, and no `compare` or
/// `hash` because two separately compiled pegs are distinct values even when
/// they came from the same source.
///
/// Asserted through both descriptions, which is what the C original could not
/// do — see the header comment.
fn theAbstractTypeIsShapedAsTheRuntimeExpects() void {
    const zig = &peg.janet_peg_type;
    const public = &c.janet_peg_type;

    assert(c.janet_cstrcmp(c.janet_cstring("core/peg"), zig.name) == 0);
    assert(c.janet_cstrcmp(c.janet_cstring("core/peg"), public.name) == 0);

    // Which callbacks exist, read off the runtime's own table...
    assert(zig.gc == null);
    assert(zig.gcmark != null);
    assert(zig.get != null);
    assert(zig.put == null);
    assert(zig.marshal != null);
    assert(zig.unmarshal != null);
    assert(zig.tostring == null);
    assert(zig.compare == null);
    assert(zig.hash == null);
    assert(zig.next != null);
    assert(zig.call == null);
    assert(zig.length == null);
    assert(zig.bytes == null);

    // ...and off `janet.h`'s, which is the description a native module reads.
    // A field that moved in one mirror and not the other shows up here as a
    // present callback answering absent, or the reverse.
    assert(public.gc == null);
    assert(public.gcmark != null);
    assert(public.get != null);
    assert(public.put == null);
    assert(public.marshal != null);
    assert(public.unmarshal != null);
    assert(public.tostring == null);
    assert(public.compare == null);
    assert(public.hash == null);
    assert(public.next != null);
    assert(public.call == null);
    assert(public.length == null);
    assert(public.bytes == null);

    // Registered under its own name, which is what lets a marshalled peg name
    // its type on the wire -- and what ties the two descriptions above to one
    // object. The registry answers with a pointer it was handed at
    // registration, from the import side; comparing it with the *symbol*
    // `janet.h` declares is the only spelling of "these are the same table"
    // that a compiler cannot fold away, because the lookup happens at run time.
    const registered = c.janet_get_abstract_type(c.janet_csymbolv("core/peg"));
    assert(registered == abstract_type.stored(zig));
    assert(registered == public);
}

/// The five methods, in the order `janet_nextmethod` walks them -- which is
/// the order `(keys peg)` reports and therefore the order a Janet program
/// sees.
fn theMethodTableAndItsOrder() raise.Raising(void) {
    const value = c.janet_wrap_abstract(compiled("\"a\""));
    const names = [_][*:0]const u8{ "match", "find", "find-all", "replace", "replace-all" };

    var key = c.janet_wrap_nil();
    for (names) |name| {
        key = try access.next(value, key);
        assert(harness.keywordIs(key, name));
        assert(harness.isType(try access.get(value, key), c.JANET_CFUNCTION));
    }
    assert(harness.isType(try access.next(value, key), c.JANET_NIL));

    // A non-keyword key is not a method lookup at all.
    assert(harness.isType(try access.get(value, harness.wrapInteger(0)), c.JANET_NIL));
}

// ------------------------------------------------------- the one allocation
//
// `makePeg` and `pegUnmarshal` compute the same three offsets, and they have
// to agree: the unmarshaller writes through pointers the compiler never sees.
// The formula is duplicated here rather than shared, so that a change to it in
// the implementation shows up as a failure rather than as agreement.

fn padded(offset: usize, size: usize) usize {
    const x = size + offset - 1;
    return x - (x % size);
}

fn theHeaderBytecodeAndConstantsShareOneAllocation() void {
    const p = compiled("'(* (<- \"ab\") (constant 7))");
    const mem = @intFromPtr(p);
    const bytecode_start = padded(@sizeOf(c.JanetPeg), @sizeOf(u32));
    const constants_start =
        padded(bytecode_start + p.bytecode_len * @sizeOf(u32), @sizeOf(c.Janet));

    assert(@intFromPtr(p.bytecode) == mem + bytecode_start);
    assert(@intFromPtr(p.constants) == mem + constants_start);
    assert(p.num_constants == 1);
    assert(harness.equals(p.constants[0], harness.wrapInteger(7)));

    // Both arrays are aligned for their element type, which is the whole point
    // of the padding.
    assert(@intFromPtr(p.bytecode) % @sizeOf(u32) == 0);
    assert(@intFromPtr(p.constants) % @sizeOf(c.Janet) == 0);

    // And the abstract really is one allocation: its size covers both.
    assert(c.janet_abstract_head(p).*.size ==
        constants_start + p.num_constants * @sizeOf(c.Janet));
}

// --------------------------------------------------------- the instructions
//
// One assertion per opcode the compiler can emit, which is the vocabulary the
// matcher switches on and the verifier walks. Written as literal words for the
// reason `test/marsh.zig` writes literal bytes: a round trip through the same
// two halves agrees with itself whatever it encodes.

fn everySpecialEmitsItsInstruction() void {
    // Primitives, which are not tuples at all.
    bytecodeIs("true", &.{ op(c.RULE_NCHAR), 0 });
    bytecodeIs("false", &.{ op(c.RULE_NOTNCHAR), 0 });
    bytecodeIs("3", &.{ op(c.RULE_NCHAR), 3 });
    bytecodeIs("-3", &.{ op(c.RULE_NOTNCHAR), 3 });
    // A literal's bytes are packed four to a word, rounded up.
    bytecodeIs("\"abc\"", &.{ op(c.RULE_LITERAL), 3, 0x00636261 });
    bytecodeIs("\"abcde\"", &.{ op(c.RULE_LITERAL), 5, 0x64636261, 0x00000065 });
    bytecodeIs("\"\"", &.{ op(c.RULE_LITERAL), 0 });
    bytecodeIs("@\"ab\"", &.{ op(c.RULE_LITERAL), 2, 0x00006261 });

    // A single range is its own opcode; two or more compile to a set.
    bytecodeIs("'(range \"az\")", &.{ op(c.RULE_RANGE), 0x007A0061 });
    bytecodeIs("'(set \"ab\")", &.{ op(c.RULE_SET), 0, 0, 0, 0x00000006, 0, 0, 0, 0 });
    bytecodeIs("'(range \"ab\" \"yz\")", &.{ op(c.RULE_SET), 0, 0, 0, 0x06000006, 0, 0, 0, 0 });

    bytecodeIs("'(> 2 \"a\")", &.{ op(c.RULE_LOOK), 2, 3, op(c.RULE_LITERAL), 1, 0x61 });
    // The offset is signed and rides in the word as its two's complement.
    bytecodeIs("'(> -2 \"a\")", &.{ op(c.RULE_LOOK), 0xFFFFFFFE, 3, op(c.RULE_LITERAL), 1, 0x61 });
    // One argument means an offset of zero.
    bytecodeIs("'(look \"a\")", &.{ op(c.RULE_LOOK), 0, 3, op(c.RULE_LITERAL), 1, 0x61 });

    // A variadic rule reserves its operand slots before compiling into them.
    bytecodeIs("'(+ 1 2)", &.{ op(c.RULE_CHOICE), 2, 4, 6, op(c.RULE_NCHAR), 1, op(c.RULE_NCHAR), 2 });
    bytecodeIs("'(* 1 2)", &.{ op(c.RULE_SEQUENCE), 2, 4, 6, op(c.RULE_NCHAR), 1, op(c.RULE_NCHAR), 2 });
    bytecodeIs("'(+)", &.{ op(c.RULE_CHOICE), 0 });
    bytecodeIs("'(*)", &.{ op(c.RULE_SEQUENCE), 0 });

    bytecodeIs("'(if 1 2)", &.{ op(c.RULE_IF), 3, 5, op(c.RULE_NCHAR), 1, op(c.RULE_NCHAR), 2 });
    bytecodeIs("'(if-not 1 2)", &.{ op(c.RULE_IFNOT), 3, 5, op(c.RULE_NCHAR), 1, op(c.RULE_NCHAR), 2 });
    bytecodeIs("'(lenprefix 1 2)", &.{ op(c.RULE_LENPREFIX), 3, 5, op(c.RULE_NCHAR), 1, op(c.RULE_NCHAR), 2 });
    bytecodeIs("'(! 1)", &.{ op(c.RULE_NOT), 2, op(c.RULE_NCHAR), 1 });

    // Every repetition is one `RULE_BETWEEN` with different bounds.
    const max = std.math.maxInt(u32);
    bytecodeIs("'(between 2 4 1)", &.{ op(c.RULE_BETWEEN), 2, 4, 4, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(some 1)", &.{ op(c.RULE_BETWEEN), 1, max, 4, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(any 1)", &.{ op(c.RULE_BETWEEN), 0, max, 4, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(at-least 3 1)", &.{ op(c.RULE_BETWEEN), 3, max, 4, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(at-most 3 1)", &.{ op(c.RULE_BETWEEN), 0, 3, 4, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(? 1)", &.{ op(c.RULE_BETWEEN), 0, 1, 4, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(repeat 3 1)", &.{ op(c.RULE_BETWEEN), 3, 3, 4, op(c.RULE_NCHAR), 1 });
    // A leading integer is `repeat` spelled without the word.
    bytecodeIs("'(3 1)", &.{ op(c.RULE_BETWEEN), 3, 3, 4, op(c.RULE_NCHAR), 1 });

    bytecodeIs("'(<- 1)", &.{ op(c.RULE_CAPTURE), 3, 0, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(% 1)", &.{ op(c.RULE_ACCUMULATE), 3, 0, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(group 1)", &.{ op(c.RULE_GROUP), 3, 0, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(unref 1)", &.{ op(c.RULE_UNREF), 3, 0, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(drop 1)", &.{ op(c.RULE_DROP), 2, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(only-tags 1)", &.{ op(c.RULE_ONLY_TAGS), 2, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(to 1)", &.{ op(c.RULE_TO), 2, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(thru 1)", &.{ op(c.RULE_THRU), 2, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(error 1)", &.{ op(c.RULE_ERROR), 2, op(c.RULE_NCHAR), 1 });
    // `(error)` with no argument errors on the empty match.
    bytecodeIs("'(error)", &.{ op(c.RULE_ERROR), 2, op(c.RULE_NCHAR), 0 });

    bytecodeIs("'($)", &.{ op(c.RULE_POSITION), 0 });
    bytecodeIs("'(line)", &.{ op(c.RULE_LINE), 0 });
    bytecodeIs("'(column)", &.{ op(c.RULE_COLUMN), 0 });
    bytecodeIs("'(backmatch)", &.{ op(c.RULE_BACKMATCH), 0 });
    bytecodeIs("'(??)", &.{op(c.RULE_DEBUG)});
    bytecodeIs("'(argument 2)", &.{ op(c.RULE_ARGUMENT), 2, 0 });
    bytecodeIs("'(constant :x)", &.{ op(c.RULE_CONSTANT), 0, 0 });
    bytecodeIs("'(nth 2 1)", &.{ op(c.RULE_NTH), 2, 4, 0, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(number 1)", &.{ op(c.RULE_CAPTURE_NUM), 4, 0, 0, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(number 1 16)", &.{ op(c.RULE_CAPTURE_NUM), 4, 16, 0, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(number 1 nil)", &.{ op(c.RULE_CAPTURE_NUM), 4, 0, 0, op(c.RULE_NCHAR), 1 });

    bytecodeIs("'(sub 1 2)", &.{ op(c.RULE_SUB), 3, 5, op(c.RULE_NCHAR), 1, op(c.RULE_NCHAR), 2 });
    bytecodeIs("'(til 1 2)", &.{ op(c.RULE_TIL), 3, 5, op(c.RULE_NCHAR), 1, op(c.RULE_NCHAR), 2 });
    bytecodeIs("'(split 1 2)", &.{ op(c.RULE_SPLIT), 3, 5, op(c.RULE_NCHAR), 1, op(c.RULE_NCHAR), 2 });
    bytecodeIs("'(/ 1 :x)", &.{ op(c.RULE_REPLACE), 4, 0, 0, op(c.RULE_NCHAR), 1 });
    bytecodeIs("~(cmt 1 ,identity)", &.{ op(c.RULE_MATCHTIME), 4, 0, 0, op(c.RULE_NCHAR), 1 });
    bytecodeIs("~(cms 1 ,identity)", &.{ op(c.RULE_MATCHSPLICE), 4, 0, 0, op(c.RULE_NCHAR), 1 });

    // The width and the two flag bits share one operand word.
    bytecodeIs("'(uint 4)", &.{ op(c.RULE_READINT), 0x04, 0 });
    bytecodeIs("'(int 4)", &.{ op(c.RULE_READINT), 0x14, 0 });
    bytecodeIs("'(uint-be 4)", &.{ op(c.RULE_READINT), 0x24, 0 });
    bytecodeIs("'(int-be 4)", &.{ op(c.RULE_READINT), 0x34, 0 });

    // Every alias emits what the symbol it aliases emits.
    bytecodeIs("'(not 1)", &.{ op(c.RULE_NOT), 2, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(quote 1)", &.{ op(c.RULE_CAPTURE), 3, 0, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(capture 1)", &.{ op(c.RULE_CAPTURE), 3, 0, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(accumulate 1)", &.{ op(c.RULE_ACCUMULATE), 3, 0, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(choice 1)", &.{ op(c.RULE_CHOICE), 1, 3, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(sequence 1)", &.{ op(c.RULE_SEQUENCE), 1, 3, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(opt 1)", &.{ op(c.RULE_BETWEEN), 0, 1, 4, op(c.RULE_NCHAR), 1 });
    bytecodeIs("'(position)", &.{ op(c.RULE_POSITION), 0 });
    bytecodeIs("'(debug)", &.{op(c.RULE_DEBUG)});
}

/// Tags are numbered from one, because zero is the "no tag" sentinel, and the
/// same keyword reuses its number. `(-> :t)` and `(backmatch :t)` are also the
/// only two specials that set `has_backref`, which is what makes the matcher
/// maintain the third capture stack at all.
fn tagsAreNumberedAndBackrefsAreFlagged() void {
    bytecodeIs("'(<- 1 :a)", &.{ op(c.RULE_CAPTURE), 3, 1, op(c.RULE_NCHAR), 1 });
    // The third capture is the first one again -- same tuple, same grammar --
    // so it is cached rather than emitted, and its tag is reused too.
    bytecodeIs("'(* (<- 1 :a) (<- 1 :b) (<- 1 :a))", &.{
        op(c.RULE_SEQUENCE), 3, 5, 10,               5,
        op(c.RULE_CAPTURE),  8, 1, op(c.RULE_NCHAR), 1,
        op(c.RULE_CAPTURE),  8, 2,
    });

    assert(compiled("\"a\"").has_backref == 0);
    assert(compiled("'(<- 1 :a)").has_backref == 0);
    assert(compiled("'(-> :a)").has_backref == 1);
    assert(compiled("'(backmatch :a)").has_backref == 1);
    assert(compiled("'(backref :a)").has_backref == 1);
    // `unref` names a tag without needing the tagged stack.
    assert(compiled("'(unref 1 :a)").has_backref == 0);
}

/// A pattern already compiled in this grammar is reused rather than emitted
/// twice, which is what makes a recursive grammar terminate. A tuple is cached
/// only in the grammar it was seen in, because `(+ :a :b)` means different
/// things under different bindings; anything else goes to the root table.
fn theCompilerCachesRules() void {
    // Two references to the same primitive share one rule.
    bytecodeIs("'(* 1 1)", &.{ op(c.RULE_SEQUENCE), 2, 4, 4, op(c.RULE_NCHAR), 1 });
    // A recursive grammar refers back to a rule still being built.
    bytecodeIs("'{:main (* \"a\" (? :main))}", &.{
        op(c.RULE_SEQUENCE), 2, 4,    7,
        op(c.RULE_LITERAL),  1, 0x61, op(c.RULE_BETWEEN),
        0,                   1, 0,
    });
}

// ---------------------------------------------------------- grammar errors
//
// Every one of these renders through `pegPanic`, which prints the form being
// compiled and then the message. `(constant)` is the exception and is a
// defect; see `FOUND.md`.

fn grammarErrorsNameTheForm() void {
    assert(grammarError("'(unknown-special)").endsWith(", unknown special unknown-special"));
    assert(grammarError("'()").endsWith(", tuple in grammar must have non-zero length"));
    assert(grammarError("'(\"a\")").endsWith(", expected grammar command, found \"a\""));
    assert(grammarError(":nope").endsWith(", unknown rule"));
    assert(grammarError("{:notmain 1}").endsWith(", grammar requires :main rule"));
    assert(grammarError("@{:notmain 1}").endsWith(", grammar requires :main rule"));
    assert(grammarError("print").endsWith(", unexpected peg source"));

    assert(grammarError("'(! 1 2)").endsWith(", expected 1 argument, got 2"));
    assert(grammarError("'(sub 1)").endsWith(", expected 2 arguments, got 1"));
    assert(grammarError("'(nth 1)").endsWith(", arity mismatch, expected at least 2, got 1"));
    assert(grammarError("'(?? 1)").endsWith(", arity mismatch, expected at most 0, got 1"));

    assert(grammarError("'(set 1)").endsWith(", expected string for character set"));
    assert(grammarError("'(range 1)").endsWith(", expected string for character range"));
    assert(grammarError("'(range \"abc\")").endsWith(", expected string to have length 2, got \"abc\""));
    assert(grammarError("'(range \"ba\")").endsWith(", range \"ba\" is empty"));
    assert(grammarError("'(> \"x\" 1)").endsWith(", expected integer, got \"x\""));
    assert(grammarError("'(repeat -1 1)").endsWith(", expected non-negative integer, got -1"));
    assert(grammarError("'(-1 1)").endsWith(", expected non-negative integer, got -1"));
    assert(grammarError("'(<- 1 \"a\")").endsWith(", expected keyword for capture tag, got \"a\""));
    assert(grammarError("'(number 1 40)").endsWith(", expected integer between 2 and 36, got 40"));
    assert(grammarError("'(cmt 1 2)").endsWith(", expected function or cfunction, got 2"));
    assert(grammarError("'(uint " ++ max_readint_width_text ++ "1)")
        .endsWith(", width must be between 0 and " ++ max_readint_width_text ++
        ", got " ++ max_readint_width_text ++ "1"));

    // Two hundred and fifty-five tags fit in the byte the tag stack uses; the
    // two hundred and fifty-sixth does not.
    assert(grammarError("(tuple '* ;(map (fn [i] ~(<- 1 ,(keyword \"t\" i))) (range 256)))")
        .endsWith(", too many tags - up to 255 tags are supported per peg"));

    // `FOUND.md`: every special above checks its arity with `pegArity`, which
    // renders the form. `(constant)` uses `janet_arity` and does not.
    assert(grammarError("'(constant)").says("arity mismatch, expected at least 1, got 0"));
}

// ------------------------------------------------------------ the two guards
//
// The compiler and the matcher each have a recursion budget, and they are not
// the same budget: the matcher's is reset per attempt by `pegCallReset`, so
// `peg/find` gets a fresh one at every offset. Both start at
// `JANET_RECURSION_GUARD`.
//
// Only the compiler's two are asserted here. Reaching the matcher's needs a
// recursive grammar and about a thousand live `pegRule` frames, and the
// implementation overflows the stack before it gets there in an unoptimised
// build -- see `FOUND.md`. A test for it would crash the implementation this
// contract is verified against, which is the finding rather than a reason to
// write the test.

/// The `[status message]` a `(protect ...)` answered.
fn protectedResult(value: c.Janet) struct { ok: bool, message: c.Janet } {
    const pair = c.janet_unwrap_tuple(value);
    return .{ .ok = c.janet_unwrap_boolean(pair[0]) != 0, .message = pair[1] };
}

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
    assert(!chained.ok);
    assert(harness.stringValueIs(chained.message, "grammar error in :r1024, reference chain too deep"));

    // Nesting rather than chaining spends the other counter, and that one is
    // real recursion through `pegCompile1`.
    const nested = protectedResult(evaluate(
        \\(do (var p 1)
        \\    (loop [_ :range [0 1100]] (set p ~(! ,p)))
        \\    (protect (peg/compile p)))
    ));
    assert(!nested.ok);
    {
        // The form this one names is a thousand rules deep, so only the tail
        // of the message is a contract.
        const message = c.janet_unwrap_string(nested.message);
        const length: usize = @intCast(c.janet_string_length(message));
        assert(std.mem.endsWith(u8, message[0..length], ", peg grammar recursed too deeply"));
    }

    // One below the budget still compiles, which is what makes the number
    // above a boundary rather than an upper bound.
    const just_inside = protectedResult(evaluate(
        \\(do (var p 1)
        \\    (loop [_ :range [0 1022]] (set p ~(! ,p)))
        \\    (protect (peg/compile p)))
    ));
    assert(just_inside.ok);
}

// --------------------------------------------------------------- the wire
//
// A compiled peg is a marshalled abstract, and its payload is the bytecode
// word for word. The bytes below pin the opcode numbers: renumbering the
// `JanetPegOpcode` enum would keep every Janet test passing and invalidate
// every stored peg.

fn theMarshalledFormIsTheBytecode() raise.Raising(void) {
    const p = compiled("\"a\"");
    const buffer = c.janet_buffer(32);
    _ = keep(c.janet_wrap_buffer(buffer));
    try marsh.marshal(buffer, c.janet_wrap_abstract(p), null, 0);

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
        @intCast(op(c.RULE_LITERAL)), 1, 0x61, // the three words
    };
    const got = buffer.*.data[0..@intCast(buffer.*.count)];
    if (!std.mem.eql(u8, got, &expected)) {
        std.debug.print("expected {d} bytes:", .{expected.len});
        for (expected) |byte| std.debug.print(" {x:0>2}", .{byte});
        std.debug.print("\n     got {d} bytes:", .{got.len});
        for (got) |byte| std.debug.print(" {x:0>2}", .{byte});
        std.debug.print("\n", .{});
        @panic("peg wire format mismatch");
    }

    // And back, into an equal but distinct peg.
    const back = keep(try marsh.unmarshal(buffer.*.data, @intCast(buffer.*.count), 0, null, null));
    assert(c.janet_checkabstract(back, abstract_type.stored(&peg.janet_peg_type)) != null);
    const round: *c.JanetPeg = @ptrCast(@alignCast(c.janet_unwrap_abstract(back)));
    assert(round != p);
    assert(round.bytecode_len == 3);
    assert(round.num_constants == 0);
    assert(round.has_backref == 0);
    assert(std.mem.eql(u32, round.bytecode[0..3], p.bytecode[0..3]));
    // The unmarshaller reproduces the compiler's layout, not just its words.
    assert(@intFromPtr(round.bytecode) - @intFromPtr(round) ==
        @intFromPtr(p.bytecode) - @intFromPtr(p));
}

// -------------------------------------------------- the untrusted entry point
//
// Everything below builds a peg stream by hand. `pegUnmarshal` is the only way
// bytecode the compiler could not have produced reaches the matcher, and most
// of the verifier is unreachable without it.

/// The framing every crafted stream shares, up to and including the type name.
/// What follows is `bytecode_len`, `num_constants`, the words, the constants --
/// all of them small enough to be one byte each in the marshal encoding except
/// where a case says otherwise.
const peg_header = [_]u8{ 217, 207, 8 } ++ "core/peg".*;

/// An opcode as the one byte a marshalled word of it is.
///
/// Every crafted stream below is a *byte* string rather than a word list --
/// `pegUnmarshal` reads its counts and its words through the marshal integer
/// encoding, and a value under 128 is one bare byte there. So an opcode
/// appears in these streams as its own number, and writing it as `b(RULE_NOT)`
/// rather than as `10` is what keeps a renumbering of the enum from silently
/// changing what each case tests.
inline fn b(opcode: anytype) u8 {
    return @intCast(opcode);
}

fn crafted(comptime tail: []const u8) []const u8 {
    return &(peg_header ++ tail[0..tail.len].*);
}

fn unmarshalStream(bytes: []const u8) raise.Raising(c.Janet) {
    return marsh.unmarshal(bytes.ptr, bytes.len, 0, null, null);
}

/// A crafted stream the verifier must reject, asserted by its message.
fn rejected(comptime tail: []const u8) void {
    const refusal = harness.raised(unmarshalStream, .{crafted(tail)});
    assert(refusal != null);
    assert(refusal.?.says("invalid peg bytecode"));
}

/// A crafted stream the verifier must accept.
fn accepted(comptime tail: []const u8) *c.JanetPeg {
    const value = keep(unmarshalStream(crafted(tail)) catch
        @panic("a stream this contract expects to be accepted was refused"));
    assert(c.janet_checkabstract(value, abstract_type.stored(&peg.janet_peg_type)) != null);
    return @ptrCast(@alignCast(c.janet_unwrap_abstract(value)));
}

fn theVerifierWalksEveryInstruction() void {
    // The shortest valid program, and the shape everything below varies.
    const ok = accepted(&.{ 2, 0, b(c.RULE_NCHAR), 1 });
    assert(ok.bytecode_len == 2);
    assert(ok.has_backref == 0);

    // An opcode past the end of the vocabulary. Kept under 128 so that it is
    // one byte in the marshal integer encoding, like every other word here.
    rejected(&.{ 2, 0, 100, 0 });
    // A rule operand past the end of the bytecode.
    rejected(&.{ 2, 0, b(c.RULE_NOT), 9 });
    // A constant operand past the end of the constants.
    rejected(&.{ 3, 0, b(c.RULE_CONSTANT), 0, 0 });
    // An instruction that runs off the end.
    rejected(&.{ 3, 0, b(c.RULE_NCHAR), 1, b(c.RULE_NCHAR) });
    // A rule operand that points into the middle of another instruction:
    // word 1 is referenced but is not an instruction start.
    rejected(&.{ 4, 0, b(c.RULE_NOT), 1, b(c.RULE_NCHAR), 1 });
    // Unreachable bytecode is rejected too, which is stricter than a
    // depth-first walk would be: word 2 is an instruction nothing refers to,
    // and that is fine -- only the reverse is an error.
    _ = accepted(&.{ 4, 0, b(c.RULE_NCHAR), 1, b(c.RULE_NCHAR), 1 });

    // `has_backref` is recovered from the bytecode rather than marshalled.
    assert(accepted(&.{ 3, 0, b(c.RULE_GETTAG), 1, 0 }).has_backref == 1);
    assert(accepted(&.{ 2, 0, b(c.RULE_BACKMATCH), 1 }).has_backref == 1);
}

/// `FOUND.md`: the verifier accepts a program with no instructions in it, and
/// the matcher then reads `bytecode[0]` from past the end of the bytecode
/// array. Where the padding puts the constants immediately after -- which is
/// every 64-bit build -- that read lands in the constants, so a crafted
/// constant is executed as an instruction.
fn anEmptyProgramIsAccepted() raise.Raising(void) {
    const empty = accepted(&.{ 0, 0 });
    assert(empty.bytecode_len == 0);
    assert(empty.num_constants == 0);

    // The array the matcher will read from starts at or past the end of the
    // bytecode array, because the bytecode array has no elements.
    assert(@intFromPtr(empty.bytecode) <= @intFromPtr(empty.constants));

    if (@intFromPtr(empty.bytecode) == @intFromPtr(empty.constants)) {
        // One constant, a double whose low word is `RULE_NCHAR` and whose high
        // word is 3. `peg/match` on it consumes exactly three bytes.
        const stream = crafted(&.{
            0, 1, // no bytecode, one constant
            lb_real, b(c.RULE_NCHAR), 0, 0, 0, 3, 0, 0, 0, // little endian
        });
        const value = keep(try unmarshalStream(stream));
        assert(c.janet_checkabstract(value, abstract_type.stored(&peg.janet_peg_type)) != null);
        const p: *c.JanetPeg = @ptrCast(@alignCast(c.janet_unwrap_abstract(value)));
        assert(p.bytecode_len == 0);
        assert(@intFromPtr(p.bytecode) == @intFromPtr(p.constants));

        var args = [2]c.Janet{ value, c.janet_cstringv("abc") };
        assert(harness.isType(try vm_calls.mcall("match", 2, &args), c.JANET_ARRAY));
        args[1] = c.janet_cstringv("ab");
        assert(harness.isType(try vm_calls.mcall("match", 2, &args), c.JANET_NIL));
    }
}

/// The two marshal lead bytes these streams spell by number, for the reason
/// `test/marsh.zig` gives: the enumeration is a file format and `janet.h` does
/// not export it.
const lb_real: u8 = 200;
const lb_integer: u8 = 205;

/// `FOUND.md`: `(argument)` takes a non-negative index from the compiler, but
/// the verifier does not look at the operand and the matcher does not check
/// it, so crafted bytecode reaches `s->extrav[-1]`. Accepted here and
/// deliberately not run.
fn aNegativeArgumentIndexIsAccepted() void {
    // The operand is the one word here that needs the five-byte integer
    // encoding, because 0xFFFFFFFF is not a small natural.
    const p = accepted(&.{ 3, 0, b(c.RULE_ARGUMENT), lb_integer, 255, 255, 255, 255, 0 });
    assert(p.bytecode_len == 3);
    assert(p.bytecode[1] == 0xFFFFFFFF);
}

/// `FOUND.md`: `bytecode_len` comes off the wire as a 64-bit count and is
/// multiplied by four without a check, so a length of 2^62 wraps the byte
/// count to zero and the peg is allocated at the size of its header alone.
/// What follows in `pegUnmarshal` is a loop that writes `bytecode_len` words
/// into it.
///
/// The stream below stops immediately after the two counts, so the first
/// `unmarshalInt` runs out of input and raises before anything is written.
/// That is deliberate: a stream with words after it corrupts the heap, which
/// is the finding and not something to run. What the assertion pins is that
/// the allocation was made at all -- an implementation that checked the
/// multiplication would refuse, and one that did not wrap would ask for
/// sixteen exabytes and die of it.
fn theBytecodeLengthIsMultipliedWithoutACheck() void {
    const stream = crafted(&.{
        0xF0 + 8, 0, 0, 0, 0, 0, 0, 0, 0x40, // bytecode_len = 1 << 62
        0, // num_constants
    });
    assert(harness.raised(unmarshalStream, .{stream}).?.says("unexpected end of source"));
}

/// `FOUND.md`: the readint width check tests the whole packed operand, which
/// also carries the signedness and endianness bits, against the maximum width.
/// So three of the four readint specials compile fine and are rejected by the
/// verifier that reads them back.
fn readintPegsDoNotAllSurviveARoundTrip() raise.Raising(void) {
    const cases = [_]struct { pattern: []const u8, survives: bool }{
        .{ .pattern = "'(uint 4)", .survives = true },
        .{ .pattern = "'(int 4)", .survives = false },
        .{ .pattern = "'(uint-be 4)", .survives = false },
        .{ .pattern = "'(int-be 4)", .survives = false },
    };
    for (cases) |case| {
        const p = compiled(case.pattern);
        const buffer = c.janet_buffer(32);
        _ = keep(c.janet_wrap_buffer(buffer));
        try marsh.marshal(buffer, c.janet_wrap_abstract(p), null, 0);
        const bytes = buffer.*.data[0..@intCast(buffer.*.count)];
        if (case.survives) {
            const back = keep(try unmarshalStream(bytes));
            assert(c.janet_checkabstract(back, abstract_type.stored(&peg.janet_peg_type)) != null);
        } else {
            assert(harness.raised(unmarshalStream, .{bytes}).?.says("invalid peg bytecode"));
        }
    }
    // The width alone is what the check should have looked at, and a bare
    // width still passes.
    _ = accepted(&.{ 3, 0, b(c.RULE_READINT), @intCast(max_readint_width), 0 });
    rejected(&.{ 3, 0, b(c.RULE_READINT), @intCast(max_readint_width + 1), 0 });
}

// -------------------------------------------------------------------- entry

fn body() raise.Raising(void) {
    test_env = c.janet_core_env(null);
    c.janet_gcroot(c.janet_wrap_table(test_env));
    rooted = c.janet_array(0);
    c.janet_gcroot(c.janet_wrap_array(rooted));
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
    try anEmptyProgramIsAccepted();
    aNegativeArgumentIndexIsAccepted();
    theBytecodeLengthIsMultipliedWithoutACheck();
    try readintPegsDoNotAllSurviveARoundTrip();
}

pub fn run() void {
    _ = c.janet_init();
    body() catch @panic("peg: an entry point raised unexpectedly");
    c.janet_deinit();

    std.debug.print("peg contract ok\n", .{});
}
