//! Behavioral contract for the bytecode interpreter's main loop.
//!
//! The Janet suites already run every opcode; thirty-eight of them execute for
//! this binary to reach `main`. What they do not pin is what this file is for.
//!
//! **The messages the loop raises itself.** Fourteen of them, and they are the
//! one part of `runVm` that no Janet program checks and every Janet programmer
//! reads. Each is built by `janet_panicf` with a `%v` holding a `Janet`, a `%d`
//! holding an `int32_t` and a `%s` holding a `const char *`, so a formatting
//! mistake produces a plausible wrong message rather than a crash. Every one is
//! compared byte for byte.
//!
//! **The signal, not the message.** `janet_continue` hands back a
//! `JanetSignal`, and several opcodes exist only to produce a particular one:
//! `JOP_SIGNAL` clamps its operand into the user range, an unknown opcode is
//! how a breakpoint reports itself, and `JOP_PROPAGATE` passes a child's status
//! upward unchanged. A test that only looked at payloads would pass with all
//! three confused.
//!
//! **The resume-state decoding at the head of the loop.** Five flags decide
//! where a resumed fiber puts the value it was resumed with, whether it re-runs
//! the instruction it stopped on, and whether it pops a C frame first. Nothing
//! else in the tree reads them and the suites reach them only incidentally.
//!
//! Three things are deliberately not pinned.
//!
//! `"rhs must be valid 32-bit signed integer, got %f"` hands a `Janet` to a
//! `%f`, which the formatter reads as a `double`. That is undefined, it is
//! recorded in `FOUND.md`, and the two behavioral targets already disagree —
//! aarch64 Darwin prints the value and x86-64 Linux prints `0.000000`. Phase
//! 8's sixth rule says nothing pins undefined behavior, so only the fixed
//! prefix is asserted.
//!
//! `"invalid constant"`, `"invalid funcdef"`, `"invalid upvalue index"` and
//! `"invalid upvalue environment"` are unreachable from here: the assembler
//! rejects every instruction that would produce them, so reaching them needs a
//! funcdef built by hand or unmarshalled from crafted bytes. They are the
//! verifier's subject rather than the loop's.
//!
//! `JOP_SIGNAL`'s lower clamp is unreachable for the same reason — the
//! assembler will not encode a negative operand in a one-byte field.
//!
//! ## What the migration changed
//!
//! **The error counter is gone.** The C original counted the errors it
//! expected and compared the total at the end, because a case that silently
//! stopped raising would look exactly like one that passed. `raised` below
//! asserts the signal at each site and stops there, so a case that stops
//! raising fails on its own line; the count was scaffolding for a total that
//! also had to be maintained by hand in two arms of an `#ifdef`.
//!
//! **The assembler sections ask the environment rather than the
//! configuration.** They were `#ifdef JANET_ASSEMBLER`; they are
//! `harness.coreOptional("asm")` now, which is rule 7's distinction — what
//! these cases need is the `asm` *binding*, and `options` names subsystems.

const std = @import("std");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
const value = @import("subsystems").value;
const gc_alloc = @import("subsystems").gc_alloc;
const core_env = @import("subsystems").env;
const fibers = @import("subsystems").value.fibers;
const signal_core = @import("subsystems").signal;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const vm_entry_mod = @import("subsystems").vm_entry;
const pp_describe = @import("subsystems").pp_describe;
const vm_entry = subsystems.vm_entry;

const assert = std.debug.assert;

var test_env: ?*types.JanetTable = null;

/// Whether this build registered `asm`. Four groups of cases below can only be
/// expressed in assembled bytecode, and an absent binding is a *compile* error
/// inside `eval` rather than the runtime error they are looking for.
var has_assembler = false;

/// Roots whatever it produces and never unroots it: a Janet value in a Zig
/// local is not a root, and these live across calls that compile source and
/// intern keywords.
fn eval(source: [*:0]const u8) types.Janet {
    var out = wrap.fromNil();
    const status = core_env.dostring(test_env.?, source, "vm-run-test", &out);
    if (status != 0) {
        std.debug.print("unexpected error from: {s}\n", .{source});
        std.debug.print("                  got: {s}\n", .{pp_describe.toString(out)});
        assert(false);
    }
    gc_alloc.gcroot(out);
    return out;
}

/// Wrapped in a fiber rather than handed to `janet_dostring`, because
/// `janet_dostring` prints a stack trace on the way out: this file expects
/// twenty-five errors and would otherwise bury its own output in them. The
/// fiber masks error and yield, so `janet_continue` reports the signal instead.
fn raised(source: []const u8) types.Janet {
    var buffer: [2048]u8 = undefined;
    const wrapped = std.fmt.bufPrintZ(&buffer, "(fiber/new (fn [] {s}) :ye)", .{source}) catch unreachable;
    const fiberv = eval(wrapped);
    var out = wrap.fromNil();
    const sig = vm_entry_mod.continueFiber(wrap.toFiber(fiberv), wrap.fromNil(), &out);
    if (sig != constants.JANET_SIGNAL_ERROR) {
        std.debug.print("expected an error from: {s}\n", .{source});
        assert(false);
    }
    gc_alloc.gcroot(out);
    return out;
}

fn expectError(source: []const u8, message: [*:0]const u8) void {
    const payload = raised(source);
    if (!harness.stringValueIs(payload, message)) {
        std.debug.print("source:   {s}\n", .{source});
        std.debug.print("expected: {s}\n", .{message});
        std.debug.print("     got: {s}\n", .{pp_describe.toString(payload)});
        assert(false);
    }
}

/// For the one message whose tail is undefined; see the header.
fn expectErrorPrefix(source: []const u8, prefix: []const u8) void {
    const payload = raised(source);
    assert(harness.isType(payload, constants.JANET_STRING));
    const text = wrap.toString(payload);
    const length: usize = @intCast(types.stringHead(text).length);
    if (!std.mem.startsWith(u8, text[0..length], prefix)) {
        std.debug.print("source:   {s}\n", .{source});
        std.debug.print("expected prefix: {s}\n", .{prefix});
        std.debug.print("            got: {s}\n", .{text[0..length]});
        assert(false);
    }
}

/// Compares pretty-printed forms rather than values, because `janet_equals` on
/// a mutable collection compares identity: two separately built `@[1 2 3]`s are
/// not equal, and most of what the loop constructs is mutable.
fn expectEqual(source: []const u8, expected: []const u8) void {
    var buffer: [2048]u8 = undefined;
    var wanted: [2048]u8 = undefined;
    const got = eval(std.fmt.bufPrintZ(&buffer, "(string/format \"%p\" (do {s}))", .{source}) catch unreachable);
    const want = eval(std.fmt.bufPrintZ(&wanted, "(string/format \"%p\" (do {s}))", .{expected}) catch unreachable);
    if (!harness.equals(got, want)) {
        std.debug.print("source:   {s}\n", .{source});
        std.debug.print("expected: {s}\n", .{wrap.toString(want)});
        std.debug.print("     got: {s}\n", .{wrap.toString(got)});
        assert(false);
    }
}

/// Resume a fiber built in Janet source and report the signal as well as the
/// value, which is the whole point of the `JOP_SIGNAL` and `JOP_PROPAGATE`
/// cases.
fn resumeFiber(fiberv: types.Janet, in: types.Janet, out: *types.Janet) types.JanetSignal {
    assert(harness.isType(fiberv, constants.JANET_FIBER));
    return vm_entry_mod.continueFiber(wrap.toFiber(fiberv), in, out);
}

// ------------------------------------------ arithmetic and bitwise operands

/// The four arithmetic opcodes and their immediate forms take the numeric path
/// only when both operands are numbers, and every other opcode in the group
/// narrows a double to an integer first. The narrowing is what raises.
///
/// Every operand here comes from a function parameter, and that is not
/// stylistic. The compiler folds constant arithmetic, so `(- 2 3)` is a load of
/// -1 and reaches no opcode at all: the mutation sweep proved it by swapping
/// the operands of every binary opcode without failing a single assertion. A
/// contract for the interpreter has to keep its operands away from the
/// optimizer.
fn arithmeticTakesTheNumericPath() void {
    expectEqual("(do (defn f [a b] [(+ a b) (- a b) (* a b) (/ a b)]) (f 3 2))", "[5 1 6 1.5]");
    expectEqual("(do (defn f [a b] [(div a b) (mod a b) (% a b)]) (f 7 -2))", "[-4 -1 1]");
    expectEqual("(do (defn f [a b] (mod a b)) (f 7 0))", "7");
    expectEqual("(do (defn f [a b] [(band a b) (bor a b) (bxor a b)]) (f 12 10))", "[8 14 6]");
    // The left operand of a left shift stays positive and in range: C leaves
    // `int32_t << int32_t` undefined for a negative value, for an overflow into
    // the sign bit, and for a count above 31, and a Debug build aborts on all
    // three. `FOUND.md` has it; by Phase 8's sixth rule nothing here pins it.
    // The two right shifts take the negative operand, where C is merely
    // implementation-defined and both targets agree.
    expectEqual("(do (defn f [a b] (blshift a b)) (f 3 4))", "48");
    // The unsigned form narrows its left operand to `uint32_t`, so a negative
    // one raises there rather than shifting; only the signed form takes it.
    expectEqual("(do (defn f [a b] (brshift a b)) (f -8 1))", "-4");
    expectEqual("(do (defn f [a b] (brushift a b)) (f 4026531840 1))", "2013265920");
    // The immediate forms, which encode the right operand in the instruction.
    // The negative ones matter on their own: the immediate field is read with
    // an arithmetic shift, and reading it unsigned passes every non-negative
    // test there is.
    expectEqual("(do (defn f [x] [(+ x 3) (- x 3) (* x 3)]) (f 4))", "[7 1 12]");
    expectEqual("(do (defn f [x] [(+ x -3) (* x -3)]) (f 4))", "[1 -12]");
    expectEqual("(do (defn f [x] (blshift x 3)) (f 64))", "512");
    expectEqual("(do (defn f [x] (brshift x 3)) (f -64))", "-8");
    expectEqual("(do (defn f [x] (brushift x 3)) (f 4026531840))", "503316480");
}

fn aBitwiseOperandOutOfRange() void {
    expectError("(band 1e20 1)", "value 1e+20 out of range for 32-bit signed integers");
    expectError("(brushift 1e20 1)", "value 1e+20 out of range for 32-bit unsigned integers");
    // The immediate form narrows the same way.
    expectError("(do (defn f [x] (blshift x 3)) (f 1e20))", "value 1e+20 out of range for 32-bit signed integers");
    expectError("(do (defn f [x] (brushift x 3)) (f 1e20))", "value 1e+20 out of range for 32-bit unsigned integers");
    // A NaN fails the range test rather than the round trip. Produced by
    // dividing at run time rather than written as `math/nan`: a NaN *constant*
    // reaches `janetc_loadconst`, which casts it to `int32_t` unchecked, and a
    // Debug build aborts before this opcode runs. `FOUND.md` has it; it is the
    // compiler's defect rather than the loop's, and this contract found it by
    // accident.
    expectError("(do (defn f [a b] (band (/ a b) 1)) (f 0 0))", "value nan out of range for 32-bit signed integers");
}

/// The right operand is narrowed to `int32_t` whatever the left was narrowed
/// to, and its message is the one `FOUND.md` records: the `Janet` is handed to
/// a `%f`.
fn aBitwiseRightOperandOutOfRange() void {
    expectErrorPrefix("(band 1 1e20)", "rhs must be valid 32-bit signed integer, got ");
    expectErrorPrefix("(brushift 1 1e20)", "rhs must be valid 32-bit signed integer, got ");
    // A count that fits a `uint32_t` and not an `int32_t` is rejected even by
    // the unsigned opcode. That asymmetry is the only well-defined way to tell
    // the two narrowings apart.
    expectErrorPrefix(
        "(do (defn f [a b] (brushift a b)) (f 4 3000000000))",
        "rhs must be valid 32-bit signed integer, got ",
    );
}

/// Every arithmetic and bitwise opcode falls back to a method when an operand
/// is not a number, and the fallback tries `:op` on the left before `:rop` on
/// the right. `vm_calls` owns the fallback; what is asserted here is that the
/// loop reaches it from both the register and the immediate forms.
fn theOperatorFallbacks() void {
    expectEqual("(do (def t @{:+ (fn [self o] [:plus o])}) (+ t 1))", "[:plus 1]");
    expectEqual("(do (def t @{:r+ (fn [self o] [:rplus o])}) (+ 1 t))", "[:rplus 1]");
    expectEqual("(do (def t @{:& (fn [self o] :and)}) (band t 1))", ":and");
    // `:~` is not a keyword literal: the reader takes `~` for the quasiquote
    // shorthand and leaves the empty keyword behind.
    expectEqual("(do (def t @{(keyword \"~\") (fn [self] :not)}) (bnot t))", ":not");
    // Both shift-right opcodes fall back to the same method name, because C
    // stringified the operator and the signed and unsigned forms share it.
    expectEqual("(do (def t @{:>> (fn [self o] :shr)}) (brshift t 1))", ":shr");
    expectEqual("(do (def t @{:>> (fn [self o] :shr)}) (brushift t 1))", ":shr");
    // The immediate forms reach `mcall` rather than `binopCall`.
    expectEqual("(do (def t @{:+ (fn [self o] [:plus o])})    (defn f [x] (+ x 3)) (f t))", "[:plus 3]");
    expectError("(do (defn f [x] (+ x 3)) (f :kw))", "could not find method :+ for :kw");
}

// -------------------------------------------------- comparison and equality

fn comparison() void {
    expectEqual("(do (defn f [a b] [(< a b) (<= a b) (> a b) (>= a b)]) (f 1 2))", "[true true false false]");
    expectEqual("(do (defn f [a b] [(< a b) (<= a b) (> a b) (>= a b)]) (f 2 2))", "[false true false true]");
    expectEqual("(do (defn f [a b] [(= a b) (not= a b)]) (f 1 1))", "[true false]");
    expectEqual("(do (defn f [a b] [(= a b) (not= a b)]) (f [1] [1]))", "[true false]");
    expectEqual("(do (defn f [a b] (compare a b)) [(f 1 2) (f 2 2) (f 2 1)])", "[-1 0 1]");
    // The immediate forms, including the negative operand.
    expectEqual("(do (defn f [x] [(< x 3) (> x 3)]) [(f 2) (f 4)])", "[[true false] [false true]]");
    expectEqual("(do (defn f [x] [(< x -3) (> x -3)]) [(f -5) (f 0)])", "[[true false] [false true]]");
    // Equality against an immediate answers false for a non-number without
    // unwrapping it. Zero is the operand that distinguishes checking from not
    // checking, because a tagged-layout nil unwraps to 0.0 and a NaN-boxed one
    // unwraps to a NaN.
    expectEqual("(do (defn f [x] (= x 0)) [(f 0) (f nil) (f :kw)])", "[true false false]");
    expectEqual("(do (defn f [x] (not= x 0)) [(f 0) (f nil)])", "[false true]");
    // A non-number operand goes through `janet_compare`, which orders across
    // types rather than raising.
    expectEqual("(do (defn f [a b] (< a b)) (f :a :b))", "true");
    expectEqual("(do (defn f [x] (< x 3)) (f :a))", "false");
}

// --------------------------------------------------------------- calling

/// The arity message is built at `JOP_CALL` and again at `JOP_TAILCALL`, with
/// a `%v` for the callee, two `%d`s and a `%s` carrying the plural. Both sites
/// and both spellings of the plural are asserted, because they are separate
/// format calls.
fn theCallArityMessage() void {
    // JOP_TAILCALL: a call in tail position, which builds the message after
    // recomputing the frame it commits to.
    expectError("(do (defn f [x] x) (defn g [] (f)) (g))", "<function f> called with 0 arguments, expected 1");
    expectError("(do (defn f [x y] x) (defn g [] (f 1)) (g))", "<function f> called with 1 argument, expected 2");
    // JOP_CALL: the same message from a separate site, which the arithmetic
    // around the call is here to force. Every tail-position case above misses
    // it entirely, which the mutation sweep found by inverting one plural.
    expectError("(do (defn f [x] x) (defn g [] (+ 1 (f))) (g))", "<function f> called with 0 arguments, expected 1");
    expectError("(do (defn f [x y] x) (defn g [] (+ 1 (f 1))) (g))", "<function f> called with 1 argument, expected 2");
}

fn callingACfunction() void {
    expectEqual("(+ (length @[1 2 3]) 0)", "3");
    // In tail position, which pops two frames rather than one.
    expectEqual("(do (defn f [] (length @[1 2])) (f))", "2");
}

/// A callee that is neither a function nor a cfunction goes to `callNonfn`,
/// which is `vm_calls`'; what is asserted here is that both call opcodes reach
/// it and place the result.
fn callingANonFunction() void {
    expectEqual("(do (def t @{:a 1}) (t :a))", "1");
    expectEqual("(do (def t @{:a 1}) (defn f [] (t :a)) (f))", "1");
    // A keyword callee is a method *name* rather than a key: `JOP_CALL`
    // resolves it against the receiver and then calls whatever it named, with
    // the receiver as the first argument. `(:a @{:a 2})` is consequently nil
    // and not 2 — it finds 2 and calls it, and calling a number indexes the
    // receiver by it.
    expectEqual("(:a @{:a 2})", "nil");
    expectEqual("(do (def t @{:go (fn [self x] [:went x])}) (:go t 7))", "[:went 7]");
    // A keyword receiver rather than a table or a struct, because `%v` renders
    // both of those by address and an address cannot be compared.
    expectError("(:nope :recv)", "unknown method :nope invoked on :recv");
}

fn stackOverflow() void {
    const fiberv = eval(
        "(do (defn deep [n] (+ 1 (deep (+ n 1))))" ++
            "    (def f (fiber/new (fn [] (deep 0)) :e))" ++
            "    (fiber/setmaxstack f 1000) f)",
    );
    var out = wrap.fromNil();
    const sig = resumeFiber(fiberv, wrap.fromNil(), &out);
    assert(sig == constants.JANET_SIGNAL_ERROR);
    assert(harness.stringValueIs(out, "stack overflow"));
}

// ------------------------------------------------------------ type assertions

/// `vm_assert_type` and `vm_assert_types` share one message and one formatter,
/// and `%T` renders a bitmask of permitted types rather than a single one.
fn theTypeAssertions() void {
    // JOP_RESUME, JOP_CANCEL and JOP_PROPAGATE all assert a single type.
    expectError("(resume 5)", "expected fiber, got 5");
    expectError("(cancel 5 :x)", "expected fiber, got 5");
    expectError("(propagate :x 5)", "expected fiber, got 5");
    // JOP_TYPECHECK asserts a mask, and the assembler is the only way to emit
    // one the compiler would not.
    if (has_assembler) {
        expectError("((asm '{:arity 1 :bytecode [(tchck 0 :number) (ret 0)]}) :kw)", "expected number, got :kw");
        expectError("((asm '{:arity 1 :bytecode [(tchck 0 :indexed) (ret 0)]}) :kw)", "expected array or tuple, got :kw");
    }
    // JOP_PUSH_ARRAY, which is the splice operator.
    expectError("(do (defn f [& xs] xs) (f ;5))", "expected array or tuple, got 5");
}

// ------------------------------------------------- collection constructors

fn theCollectionConstructors() void {
    expectEqual("@[1 2 3]", "@[1 2 3]");
    expectEqual("[1 2 3]", "[1 2 3]");
    expectEqual("@{:a 1}", "@{:a 1}");
    expectEqual("{:a 1}", "{:a 1}");
    expectEqual("(string \"a\" 1 :b)", "\"a1b\"");
    expectEqual("(buffer \"a\" 1 :b)", "@\"a1b\"");
    // A bracket tuple carries a flag the round tuple does not, set inside the
    // opcode the two share.
    expectEqual("(tuple/type '(1 2))", ":parens");
    expectEqual("(tuple/type '[1 2])", ":brackets");
    if (has_assembler) {
        expectEqual(
            "(tuple/type ((asm '{:arity 0 :constants [1]  :bytecode [(ldc 0 0) (push 0) (mkbtp 1) (ret 1)]})))",
            ":brackets",
        );
        expectEqual(
            "(tuple/type ((asm '{:arity 0 :constants [1]  :bytecode [(ldc 0 0) (push 0) (mktup 1) (ret 1)]})))",
            ":parens",
        );
    }
}

/// The two constructors that reject an odd argument count do it at run time,
/// and the compiler counts literal arguments before they get there, so the
/// assembler is again the only route.
fn anOddConstructorArgumentCount() void {
    expectError(
        "((asm '{:arity 0 :bytecode [(ldi 0 1) (push 0) (mktab 0) (ret 0)]}))",
        "expected even number of arguments to table constructor, got 1",
    );
    expectError(
        "((asm '{:arity 0 :bytecode [(ldi 0 1) (push 0) (mkstu 0) (ret 0)]}))",
        "expected even number of arguments to struct constructor, got 1",
    );
}

// ------------------------------------------------------------------- signals

/// `JOP_SIGNAL` clamps its operand into the user range. The upper clamp is
/// reachable; the lower is not, because the assembler will not encode a
/// negative one-byte operand.
fn theSignalOpcode() void {
    var out = wrap.fromNil();
    var fiberv = eval(
        "(fiber/new (asm '{:arity 0 :constants [:payload]" ++
            "  :bytecode [(ldc 0 0) (sig 1 0 30) (ret 1)]}) :i0123456789)",
    );
    var sig = resumeFiber(fiberv, wrap.fromNil(), &out);
    assert(sig == constants.JANET_SIGNAL_USER9);
    assert(harness.keywordIs(out, "payload"));

    fiberv = eval(
        "(fiber/new (asm '{:arity 0 :constants [:payload]" ++
            "  :bytecode [(ldc 0 0) (sig 1 0 5) (ret 1)]}) :i0123456789)",
    );
    sig = resumeFiber(fiberv, wrap.fromNil(), &out);
    // The operand is the signal number, not the user index: 5 is USER1.
    assert(sig == constants.JANET_SIGNAL_USER1);
    assert(harness.keywordIs(out, "payload"));
}

/// `JOP_ERROR` returns the slot as an error signal without formatting it,
/// which is the precedent the whole return-rather-than-jump path was built on.
fn theErrorOpcode() void {
    var out = wrap.fromNil();
    const fiberv = eval("(fiber/new (fn [] (error [1 2])) :e)");
    const sig = resumeFiber(fiberv, wrap.fromNil(), &out);
    assert(sig == constants.JANET_SIGNAL_ERROR);
    assert(harness.isType(out, constants.JANET_TUPLE));
    assert(types.tupleHead(wrap.toTuple(out)).length == 2);
}

/// `JOP_PROPAGATE` hands a child's status upward as the parent's signal, and
/// refuses a status above the user range with the only message in the loop
/// that carries a `%s` from a static table.
fn thePropagateOpcode() void {
    var out = wrap.fromNil();
    const fiberv = eval(
        "(do (def child (fiber/new (fn [] (yield :inner)) :y))" ++
            "    (resume child)" ++
            "    (fiber/new (fn [] (propagate :outer child)) :y))",
    );
    const sig = resumeFiber(fiberv, wrap.fromNil(), &out);
    assert(sig == constants.JANET_SIGNAL_YIELD);
    assert(harness.keywordIs(out, "outer"));

    // Only `:new` and `:alive` sit above JANET_STATUS_USER9, so an unstarted
    // child is the reachable half of the check and a dead one propagates fine.
    expectError("(propagate :x (fiber/new (fn [] 1) :y))", "cannot propagate from fiber with status :new");
}

// ------------------------------------------------------- resume-state decoding

/// Five flags at the head of the loop decide what a resumed fiber does with
/// the value it was resumed with. Nothing else in the tree reads them.
fn aResumedFiberReceivesItsValue() void {
    var out = wrap.fromNil();
    const fiberv = eval("(fiber/new (fn [] [(yield 1) (yield 2)]) :y)");

    var sig = resumeFiber(fiberv, wrap.fromNil(), &out);
    assert(sig == constants.JANET_SIGNAL_YIELD);
    assert(harness.integerIs(out, 1));

    sig = resumeFiber(fiberv, value.fromBytes("first", .keyword), &out);
    assert(sig == constants.JANET_SIGNAL_YIELD);
    assert(harness.integerIs(out, 2));

    sig = resumeFiber(fiberv, value.fromBytes("second", .keyword), &out);
    assert(sig == constants.JANET_SIGNAL_OK);
    assert(harness.isType(out, constants.JANET_TUPLE));
    assert(harness.keywordIs(wrap.toTuple(out)[0], "first"));
    assert(harness.keywordIs(wrap.toTuple(out)[1], "second"));
}

/// A fiber that has not started yet takes its resume value as its first
/// argument rather than into a slot, which happens above the loop — but the
/// loop still has to skip the instruction it would otherwise re-run.
fn aNewFiberReceivesItsValueAsAnArgument() void {
    var out = wrap.fromNil();
    const fiberv = eval("(fiber/new (fn [x] [:got x]) :y)");
    const sig = resumeFiber(fiberv, value.fromBytes("in", .keyword), &out);
    assert(sig == constants.JANET_SIGNAL_OK);
    assert(harness.keywordIs(wrap.toTuple(out)[1], "in"));
}

/// After a raise the fiber carries `JANET_FIBER_DID_RAISE`, which the head of
/// the loop reads to pop a C frame and to turn a raise at a tail call into an
/// implicit return. The signal-injection path sets it too, and travels in
/// `gc.flags` rather than in `flags`.
fn aFiberResumedAfterARaise() void {
    var out = wrap.fromNil();
    const fiberv = eval("(fiber/new (fn [] (error :boom)) :ey)");
    const sig = resumeFiber(fiberv, wrap.fromNil(), &out);
    assert(sig == constants.JANET_SIGNAL_ERROR);
    assert(harness.keywordIs(out, "boom"));
    // And is refused a second time, by `checkCanResume` rather than by the
    // loop — which is the boundary `vm_entry` owns.
    expectError(
        "(do (def f (fiber/new (fn [] (error :boom)) :ey)) (resume f) (resume f))",
        "cannot resume fiber with status :error",
    );
}

/// A raise inside a cfunction leaves a C frame on the fiber, which the head of
/// the loop pops before it can restore anything.
fn aFiberResumedAfterARaiseInsideACfunction() void {
    var out = wrap.fromNil();
    const fiberv = eval("(fiber/new (fn [] (yield (length 5))) :ey)");
    const sig = resumeFiber(fiberv, wrap.fromNil(), &out);
    assert(sig == constants.JANET_SIGNAL_ERROR);
    assert(harness.isType(out, constants.JANET_STRING));
}

/// An injected signal is delivered instead of resuming, and is read back out
/// of `gc.flags` where `janet_signal_inject` put it.
fn anInjectedSignal() void {
    var out = wrap.fromNil();
    const fiberv = eval("(fiber/new (fn [] (yield 1) :never) :y)");
    var sig = resumeFiber(fiberv, wrap.fromNil(), &out);
    assert(sig == constants.JANET_SIGNAL_YIELD);

    signal_core.signalInject(wrap.toFiber(fiberv), constants.JANET_SIGNAL_USER3);
    sig = resumeFiber(fiberv, value.fromBytes("injected", .keyword), &out);
    assert(sig == constants.JANET_SIGNAL_USER3);
    assert(harness.keywordIs(out, "injected"));
}

// -------------------------------------------------------------- breakpoints

/// An opcode the loop does not recognise returns `JANET_SIGNAL_DEBUG` and sets
/// three flags, so that the resume re-runs the instruction with the breakpoint
/// bit masked off. Bit 7 of the instruction word is how a breakpoint is set,
/// and `stepImpl` sets a temporary one.
fn aBreakpointReachesTheUnknownOpcodeArm() raise.Raising(void) {
    var out = wrap.fromNil();
    const fiberv = eval("(fiber/new (fn [] (+ 1 2) (+ 3 4) :done) :dy)");
    const fiber = wrap.toFiber(fiberv);
    var sig = try vm_entry.stepImpl(fiber, wrap.fromNil(), &out);
    assert(sig == constants.JANET_SIGNAL_DEBUG);
    assert(fibers.status(fiber) == constants.JANET_STATUS_DEBUG);
    // Stepping again makes progress rather than repeating, which is what the
    // RESUME_NO_SKIP and RESUME_NO_USEVAL flags are for.
    sig = try vm_entry.stepImpl(fiber, wrap.fromNil(), &out);
    assert(sig == constants.JANET_SIGNAL_DEBUG);
    // And letting it run finishes.
    sig = vm_entry_mod.continueFiber(fiber, wrap.fromNil(), &out);
    assert(sig == constants.JANET_SIGNAL_OK);
    assert(harness.keywordIs(out, "done"));
}

/// `stepImpl`'s breakpoints are temporary: it restores the instruction words
/// on the way out, so the resume never re-reads one with bit 7 set. A
/// breakpoint set with `debug/fbreak` stays, and resuming from it is the only
/// state in which the mask the loop applies to its first opcode does anything.
fn aPermanentBreakpoint() void {
    var out = wrap.fromNil();
    const fiberv = eval(
        "(do (defn g [x] (+ x 1))" ++
            "    (def f (fiber/new (fn [] (g 1) (g 2) :done) :dy))" ++
            "    (debug/fbreak g 0) f)",
    );
    const fiber = wrap.toFiber(fiberv);
    var sig = vm_entry_mod.continueFiber(fiber, wrap.fromNil(), &out);
    assert(sig == constants.JANET_SIGNAL_DEBUG);
    // Resuming re-runs the breakpointed instruction with bit 7 masked off, so
    // the second call reaches the same breakpoint rather than the loop
    // reporting the same one forever.
    sig = vm_entry_mod.continueFiber(fiber, wrap.fromNil(), &out);
    assert(sig == constants.JANET_SIGNAL_DEBUG);
    sig = vm_entry_mod.continueFiber(fiber, wrap.fromNil(), &out);
    assert(sig == constants.JANET_SIGNAL_OK);
    assert(harness.keywordIs(out, "done"));
}

// --------------------------------------------------------- the quieter opcodes

/// Opcodes with no message and no signal of their own, grouped because each is
/// one line and a missing one is invisible.
fn theRemainingOpcodes() void {
    // Jumps, in both polarities, and both nil tests.
    expectEqual("(do (defn f [x] (if x :t :f)) [(f true) (f false) (f nil)])", "[:t :f :f]");
    expectEqual("(do (defn f [x] (if (nil? x) :n :s)) [(f nil) (f false)])", "[:n :s]");
    // Upvalues, read and written, on the stack and off it.
    expectEqual("(do (var v 0) (defn f [] (set v (+ v 1)) v) [(f) (f) v])", "[1 2 2]");
    // A closure over a frame captured lazily.
    expectEqual("(do (defn outer [x] (fn [] x)) ((outer 9)))", "9");
    // Self reference, which is how a named function calls itself.
    expectEqual("(do (defn fact [n] (if (< n 2) 1 (* n (fact (- n 1))))) (fact 5))", "120");
    // Keyed and indexed access, and their in-place writers.
    expectEqual("(do (def t @{:a 1}) [(get t :a) (get t :b) (in [10 20] 1)])", "[1 nil 20]");
    expectEqual("(do (def a @[1 2]) (put a 0 :x) a)", "@[:x 2]");
    expectEqual("(do (def t @{}) (put t :k :v) t)", "@{:k :v}");
    expectEqual("(length \"abcd\")", "4");
    // `next`, which restores all three registers rather than just the stack.
    expectEqual("(do (def t @{:a 1}) (next t nil))", ":a");
    expectEqual("(seq [[k v] :pairs {:a 1}] [k v])", "@[[:a 1]]");
    // `next` over a fiber resumes it, and the opcode asks for the
    // interpreter's handling of a signal the child's mask does not catch:
    // re-signalled, so an escaping yield stays a yield. Called from C it would
    // become an error instead, which is the same function's other argument.
    expectEqual(
        "(do (def child (fiber/new (fn [] (yield 1)) :d))" ++
            "    (def outer (fiber/new (fn [] (next child nil)) :yd))" ++
            "    [(resume outer) (fiber/status outer)])",
        "[1 :pending]",
    );
    // Constants, integers, booleans and nil.
    expectEqual("(do (defn f [] [nil true false 7 :kw]) (f))", "[nil true false 7 :kw]");
    // The two opcodes nothing else in this tree reaches, because the compiler
    // cannot emit either. Phase 9's gate counted every dispatch made by
    // thirty-five suites and fifty-five contracts and found exactly these two
    // at zero; the assembler is the only way to execute them at all.
    //
    // JOP_NOOP is written by the dead-write optimizer and then deleted by
    // no-op removal before the function is ever run, so no compiled function
    // contains one. JOP_MAKE_STRING has no emitter anywhere in the compiler:
    // `(string ...)` compiles to a call of the `string` cfunction.
    if (has_assembler) {
        expectEqual("((asm '{:arity 0 :bytecode [(noop) (ldi 0 7) (noop) (ret 0)]}))", "7");
        expectEqual(
            "((asm '{:arity 0 :constants [\"ab\" :cd]" ++
                "  :bytecode [(ldc 0 0) (push 0) (ldc 0 1) (push 0)" ++
                "             (mkstr 0) (ret 0)]}))",
            "\"abcd\"",
        );
    }

    // Register moves, near and far.
    expectEqual("(do (defn f [a b c d e g h] [a h]) (f 1 2 3 4 5 6 7))", "[1 7]");
    // Resume and cancel of a child fiber.
    expectEqual("(do (def c (fiber/new (fn [] (yield 1) 2) :y)) [(resume c) (resume c)])", "[1 2]");
    expectEqual(
        "(do (def c (fiber/new (fn [] (yield 1)) :ye))    (resume c) (try (cancel c :stop) ([e] e)))",
        ":stop",
    );
}

// ------------------------------------------------------------------- entry

fn body() raise.Raising(void) {
    test_env = harness.coreEnv();
    has_assembler = harness.coreOptional("asm") != null;

    arithmeticTakesTheNumericPath();
    aBitwiseOperandOutOfRange();
    aBitwiseRightOperandOutOfRange();
    theOperatorFallbacks();

    comparison();

    theCallArityMessage();
    callingACfunction();
    callingANonFunction();
    stackOverflow();

    theTypeAssertions();
    theCollectionConstructors();
    if (has_assembler) {
        anOddConstructorArgumentCount();
        theSignalOpcode();
    }
    theErrorOpcode();
    thePropagateOpcode();

    aResumedFiberReceivesItsValue();
    aNewFiberReceivesItsValueAsAnArgument();
    aFiberResumedAfterARaise();
    aFiberResumedAfterARaiseInsideACfunction();
    anInjectedSignal();

    try aBreakpointReachesTheUnknownOpcodeArm();
    aPermanentBreakpoint();
    theRemainingOpcodes();
}

pub fn run() void {
    harness.init();
    body() catch @panic("vm_run: an operation raised unexpectedly");
    vm_lifecycle.deinit();

    std.debug.print("vm run contract ok\n", .{});
}
