/* Behavioral contract for the bytecode interpreter's main loop. Run against
 * whichever implementation the build selected (`-Dvm-run=c` or the Zig
 * default), and under either raise mechanism (`-Dcall-trampoline`).
 *
 * The Janet suites already run every opcode; thirty-eight of them execute for
 * this binary to reach `main`. What they do not pin is what this file is for.
 *
 * **The messages the loop raises itself.** Fourteen of them, and they are the
 * one part of `run_vm` that no Janet program checks and every Janet programmer
 * reads. Under the Zig selector each crosses the C variadic ABI --
 * `janet_panicf` without the trampoline, `janet_vm_error_string` with it -- so
 * a `%v` holding a `Janet`, a `%d` holding an `int32_t` and a `%s` holding a
 * `const char *` are all live ABI questions whose failure mode is a plausible
 * wrong message rather than a crash. Every one is compared byte for byte.
 *
 * **The signal, not the message.** `janet_continue` hands back a `JanetSignal`,
 * and several opcodes exist only to produce a particular one: `JOP_SIGNAL`
 * clamps its operand into the user range, an unknown opcode is how a breakpoint
 * reports itself, and `JOP_PROPAGATE` passes a child's status upward unchanged.
 * A test that only looked at payloads would pass with all three confused.
 *
 * **The resume-state decoding at the head of the loop.** Five flags decide
 * where a resumed fiber puts the value it was resumed with, whether it re-runs
 * the instruction it stopped on, and whether it pops a C frame first. Nothing
 * else in the tree reads them and the suites reach them only incidentally.
 *
 * Three things are deliberately not pinned.
 *
 * `"rhs must be valid 32-bit signed integer, got %f"` hands a `Janet` to a `%f`,
 * which the formatter reads as a `double`. That is undefined, it is recorded in
 * `FOUND.md`, and the two behavioral targets already disagree -- aarch64 Darwin
 * prints the value and x86-64 Linux prints `0.000000`. Phase 8's sixth rule
 * says nothing pins undefined behavior, so only the fixed prefix is asserted.
 *
 * `"invalid constant"`, `"invalid funcdef"`, `"invalid upvalue index"` and
 * `"invalid upvalue environment"` are unreachable from here: the assembler
 * rejects every instruction that would produce them, so reaching them needs a
 * funcdef built by hand or unmarshalled from crafted bytes. They are the
 * verifier's subject rather than the loop's.
 *
 * `JOP_SIGNAL`'s lower clamp is unreachable for the same reason -- the
 * assembler will not encode a negative operand in a one-byte field.
 */

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "features.h"
#include <janet.h>
#include "fiber.h"
#include "state.h"

/* ------------------------------------------------------------------ helpers */

/* Every error this file expects is counted, because a case that silently
 * stopped raising would otherwise look exactly like one that passed. Fixed
 * rather than a floor, and verified against -Dvm-run=c first. */
static int errors_fired = 0;
/* Four of these are raised by bytecode only the assembler can emit, so a build
 * without it expects four fewer. See `test_the_type_assertions` below. */
#ifdef JANET_ASSEMBLER
#define EXPECTED_ERRORS 25
#else
#define EXPECTED_ERRORS 21
#endif

static JanetTable *test_env = NULL;

/* Roots whatever it produces and never unroots it, for the reason
 * test/vm_calls.c gives: a Janet value in a C local is not a root, and these
 * live across calls that compile source and intern keywords. */
static Janet eval(const char *source) {
    Janet out = janet_wrap_nil();
    int status = janet_dostring(test_env, source, "vm-run-test", &out);
    if (status) {
        printf("unexpected error from: %s\n", source);
        printf("                  got: %s\n", (const char *) janet_to_string(out));
        assert(0 && "expected the source to evaluate");
    }
    janet_gcroot(out);
    return out;
}

/* Wrapped in a fiber rather than handed to janet_dostring, because
 * janet_dostring prints a stack trace on the way out: this file expects
 * twenty-five errors and would otherwise bury its own output in them. The fiber
 * masks error and yield, so janet_continue reports the signal instead. */
static Janet raised(const char *source) {
    Janet out = janet_wrap_nil();
    Janet fiberv;
    JanetSignal sig;
    char wrapped[2048];
    int written = snprintf(wrapped, sizeof wrapped, "(fiber/new (fn [] %s) :ye)", source);
    assert(written > 0 && (size_t) written < sizeof wrapped);
    fiberv = eval(wrapped);
    sig = janet_continue(janet_unwrap_fiber(fiberv), janet_wrap_nil(), &out);
    if (sig != JANET_SIGNAL_ERROR) {
        printf("expected an error from: %s\n", source);
        assert(0 && "expected an error");
    }
    janet_gcroot(out);
    errors_fired++;
    return out;
}

static void expect_error(const char *source, const char *message) {
    Janet payload = raised(source);
    assert(janet_checktype(payload, JANET_STRING));
    if (janet_cstrcmp(janet_unwrap_string(payload), message)) {
        printf("source:   %s\n", source);
        printf("expected: %s\n", message);
        printf("     got: %s\n", (const char *) janet_unwrap_string(payload));
        assert(0 && "message mismatch");
    }
}

/* For the one message whose tail is undefined; see the header. */
static void expect_error_prefix(const char *source, const char *prefix) {
    Janet payload = raised(source);
    const uint8_t *text;
    assert(janet_checktype(payload, JANET_STRING));
    text = janet_unwrap_string(payload);
    if (strncmp((const char *) text, prefix, strlen(prefix))) {
        printf("source:   %s\n", source);
        printf("expected prefix: %s\n", prefix);
        printf("            got: %s\n", (const char *) text);
        assert(0 && "message prefix mismatch");
    }
}

/* Compares pretty-printed forms rather than values, because janet_equals on a
 * mutable collection compares identity: two separately built `@[1 2 3]`s are
 * not equal, and most of what the loop constructs is mutable. */
static void expect_equal(const char *source, const char *expected) {
    char buffer[2048];
    Janet got, want;
    int written = snprintf(buffer, sizeof buffer, "(string/format \"%%p\" (do %s))", source);
    assert(written > 0 && (size_t) written < sizeof buffer);
    got = eval(buffer);
    written = snprintf(buffer, sizeof buffer, "(string/format \"%%p\" (do %s))", expected);
    assert(written > 0 && (size_t) written < sizeof buffer);
    want = eval(buffer);
    if (!janet_equals(got, want)) {
        printf("source:   %s\n", source);
        printf("expected: %s\n", (const char *) janet_unwrap_string(want));
        printf("     got: %s\n", (const char *) janet_unwrap_string(got));
        assert(0 && "value mismatch");
    }
}

/* Resume a fiber built in Janet source and report the signal as well as the
 * value, which is the whole point of the JOP_SIGNAL and JOP_PROPAGATE tests. */
static JanetSignal resume_fiber(Janet fiberv, Janet in, Janet *out) {
    assert(janet_checktype(fiberv, JANET_FIBER));
    return janet_continue(janet_unwrap_fiber(fiberv), in, out);
}

/* ------------------------------------------ arithmetic and bitwise operands */

/* The four arithmetic opcodes and their immediate forms take the numeric path
 * only when both operands are numbers, and every other opcode in the group
 * narrows a double to an integer first. The narrowing is what raises. */
/* Every operand here comes from a function parameter, and that is not stylistic.
 * The compiler folds constant arithmetic, so `(- 2 3)` is a load of -1 and
 * reaches no opcode at all: the mutation sweep proved it by swapping the
 * operands of every binary opcode without failing a single assertion. A
 * contract for the interpreter has to keep its operands away from the
 * optimizer. */
static void test_arithmetic_takes_the_numeric_path(void) {
    expect_equal("(do (defn f [a b] [(+ a b) (- a b) (* a b) (/ a b)]) (f 3 2))",
                 "[5 1 6 1.5]");
    expect_equal("(do (defn f [a b] [(div a b) (mod a b) (% a b)]) (f 7 -2))",
                 "[-4 -1 1]");
    expect_equal("(do (defn f [a b] (mod a b)) (f 7 0))", "7");
    expect_equal("(do (defn f [a b] [(band a b) (bor a b) (bxor a b)]) (f 12 10))",
                 "[8 14 6]");
    /* The left operand of a left shift stays positive and in range: C leaves
     * `int32_t << int32_t` undefined for a negative value, for an overflow into
     * the sign bit, and for a count above 31, and a Debug build aborts on all
     * three. FOUND.md has it; by Phase 8's sixth rule nothing here pins it. The
     * two right shifts take the negative operand, where C is merely
     * implementation-defined and both targets agree. */
    expect_equal("(do (defn f [a b] (blshift a b)) (f 3 4))", "48");
    /* The unsigned form narrows its left operand to `uint32_t`, so a negative
     * one raises there rather than shifting; only the signed form takes it. */
    expect_equal("(do (defn f [a b] (brshift a b)) (f -8 1))", "-4");
    expect_equal("(do (defn f [a b] (brushift a b)) (f 4026531840 1))", "2013265920");
    /* The immediate forms, which encode the right operand in the instruction.
     * The negative ones matter on their own: the immediate field is read with
     * an arithmetic shift, and reading it unsigned passes every non-negative
     * test there is. */
    expect_equal("(do (defn f [x] [(+ x 3) (- x 3) (* x 3)]) (f 4))", "[7 1 12]");
    expect_equal("(do (defn f [x] [(+ x -3) (* x -3)]) (f 4))", "[1 -12]");
    expect_equal("(do (defn f [x] (blshift x 3)) (f 64))", "512");
    expect_equal("(do (defn f [x] (brshift x 3)) (f -64))", "-8");
    expect_equal("(do (defn f [x] (brushift x 3)) (f 4026531840))", "503316480");
}

static void test_a_bitwise_operand_out_of_range(void) {
    expect_error("(band 1e20 1)",
                 "value 1e+20 out of range for 32-bit signed integers");
    expect_error("(brushift 1e20 1)",
                 "value 1e+20 out of range for 32-bit unsigned integers");
    /* The immediate form narrows the same way. */
    expect_error("(do (defn f [x] (blshift x 3)) (f 1e20))",
                 "value 1e+20 out of range for 32-bit signed integers");
    expect_error("(do (defn f [x] (brushift x 3)) (f 1e20))",
                 "value 1e+20 out of range for 32-bit unsigned integers");
    /* A NaN fails the range test rather than the round trip. Produced by
     * dividing at run time rather than written as `math/nan`: a NaN *constant*
     * reaches `janetc_loadconst`, which casts it to `int32_t` unchecked, and a
     * Debug build with `-Demit-core=c` aborts before this opcode runs. FOUND.md
     * has it; it is the compiler's defect rather than the loop's, and this
     * contract found it by accident. */
    expect_error("(do (defn f [a b] (band (/ a b) 1)) (f 0 0))",
                 "value nan out of range for 32-bit signed integers");
}

/* The right operand is narrowed to int32_t whatever the left was narrowed to,
 * and its message is the one FOUND.md records: the Janet is handed to a %f. */
static void test_a_bitwise_right_operand_out_of_range(void) {
    expect_error_prefix("(band 1 1e20)",
                        "rhs must be valid 32-bit signed integer, got ");
    expect_error_prefix("(brushift 1 1e20)",
                        "rhs must be valid 32-bit signed integer, got ");
    /* The right operand is narrowed to `int32_t` whatever the left was narrowed
     * to, so a count that fits a `uint32_t` and not an `int32_t` is rejected
     * even by the unsigned opcode. That asymmetry is the only well-defined way
     * to tell the two narrowings apart. */
    expect_error_prefix("(do (defn f [a b] (brushift a b)) (f 4 3000000000))",
                        "rhs must be valid 32-bit signed integer, got ");
}

/* Every arithmetic and bitwise opcode falls back to a method when an operand is
 * not a number, and the fallback tries `:op` on the left before `:rop` on the
 * right. Part 2 owns the fallback; what is asserted here is that the loop
 * reaches it from both the register and the immediate forms. */
static void test_the_operator_fallbacks(void) {
    expect_equal("(do (def t @{:+ (fn [self o] [:plus o])}) (+ t 1))", "[:plus 1]");
    expect_equal("(do (def t @{:r+ (fn [self o] [:rplus o])}) (+ 1 t))", "[:rplus 1]");
    expect_equal("(do (def t @{:& (fn [self o] :and)}) (band t 1))", ":and");
    /* `:~` is not a keyword literal: the reader takes `~` for the quasiquote
     * shorthand and leaves the empty keyword behind. */
    expect_equal("(do (def t @{(keyword \"~\") (fn [self] :not)}) (bnot t))", ":not");
    /* Both shift-right opcodes fall back to the same method name, because C
     * stringifies the operator and the signed and unsigned forms share it. */
    expect_equal("(do (def t @{:>> (fn [self o] :shr)}) (brshift t 1))", ":shr");
    expect_equal("(do (def t @{:>> (fn [self o] :shr)}) (brushift t 1))", ":shr");
    /* The immediate forms reach janet_mcall rather than janet_binop_call. */
    expect_equal("(do (def t @{:+ (fn [self o] [:plus o])})"
                 "    (defn f [x] (+ x 3)) (f t))", "[:plus 3]");
    expect_error("(do (defn f [x] (+ x 3)) (f :kw))",
                 "could not find method :+ for :kw");
}

/* ---------------------------------------------------- comparison and equality */

static void test_comparison(void) {
    expect_equal("(do (defn f [a b] [(< a b) (<= a b) (> a b) (>= a b)]) (f 1 2))",
                 "[true true false false]");
    expect_equal("(do (defn f [a b] [(< a b) (<= a b) (> a b) (>= a b)]) (f 2 2))",
                 "[false true false true]");
    expect_equal("(do (defn f [a b] [(= a b) (not= a b)]) (f 1 1))", "[true false]");
    expect_equal("(do (defn f [a b] [(= a b) (not= a b)]) (f [1] [1]))",
                 "[true false]");
    expect_equal("(do (defn f [a b] (compare a b)) [(f 1 2) (f 2 2) (f 2 1)])",
                 "[-1 0 1]");
    /* The immediate forms, including the negative operand. */
    expect_equal("(do (defn f [x] [(< x 3) (> x 3)]) [(f 2) (f 4)])",
                 "[[true false] [false true]]");
    expect_equal("(do (defn f [x] [(< x -3) (> x -3)]) [(f -5) (f 0)])",
                 "[[true false] [false true]]");
    /* Equality against an immediate answers false for a non-number without
     * unwrapping it. Zero is the operand that distinguishes checking from not
     * checking, because a tagged-layout nil unwraps to 0.0 and a NaN-boxed one
     * unwraps to a NaN. */
    expect_equal("(do (defn f [x] (= x 0)) [(f 0) (f nil) (f :kw)])",
                 "[true false false]");
    expect_equal("(do (defn f [x] (not= x 0)) [(f 0) (f nil)])", "[false true]");
    /* A non-number operand goes through janet_compare, which orders across
     * types rather than raising. */
    expect_equal("(do (defn f [a b] (< a b)) (f :a :b))", "true");
    expect_equal("(do (defn f [x] (< x 3)) (f :a))", "false");
}

/* ------------------------------------------------------------------- calling */

/* The arity message is built at JOP_CALL and again at JOP_TAILCALL, with a
 * `%v` for the callee, two `%d`s and a `%s` carrying the plural. Both sites and
 * both spellings of the plural are asserted, because they are separate format
 * calls in both implementations. */
static void test_the_call_arity_message(void) {
    /* JOP_TAILCALL: a call in tail position, which builds the message after
     * recomputing the frame it commits to. */
    expect_error("(do (defn f [x] x) (defn g [] (f)) (g))",
                 "<function f> called with 0 arguments, expected 1");
    expect_error("(do (defn f [x y] x) (defn g [] (f 1)) (g))",
                 "<function f> called with 1 argument, expected 2");
    /* JOP_CALL: the same message from a separate site, which the arithmetic
     * around the call is here to force. Every tail-position case above misses
     * it entirely, which the mutation sweep found by inverting one plural. */
    expect_error("(do (defn f [x] x) (defn g [] (+ 1 (f))) (g))",
                 "<function f> called with 0 arguments, expected 1");
    expect_error("(do (defn f [x y] x) (defn g [] (+ 1 (f 1))) (g))",
                 "<function f> called with 1 argument, expected 2");
}

static void test_calling_a_cfunction(void) {
    expect_equal("(+ (length @[1 2 3]) 0)", "3");
    /* In tail position, which pops two frames rather than one. */
    expect_equal("(do (defn f [] (length @[1 2])) (f))", "2");
}

/* A callee that is neither a function nor a cfunction goes to
 * janet_call_nonfn, which is Part 2's; what is asserted here is that both call
 * opcodes reach it and place the result. */
static void test_calling_a_non_function(void) {
    expect_equal("(do (def t @{:a 1}) (t :a))", "1");
    expect_equal("(do (def t @{:a 1}) (defn f [] (t :a)) (f))", "1");
    /* A keyword callee is a method *name* rather than a key: JOP_CALL resolves
     * it against the receiver and then calls whatever it named, with the
     * receiver as the first argument. `(:a @{:a 2})` is consequently nil and
     * not 2 -- it finds 2 and calls it, and calling a number indexes the
     * receiver by it. */
    expect_equal("(:a @{:a 2})", "nil");
    /* A keyword callee is resolved as a method against the first argument. */
    expect_equal("(do (def t @{:go (fn [self x] [:went x])}) (:go t 7))", "[:went 7]");
    /* A keyword receiver rather than a table or a struct, because `%v` renders
     * both of those by address and an address cannot be compared. */
    expect_error("(:nope :recv)", "unknown method :nope invoked on :recv");
}

static void test_stack_overflow(void) {
    Janet fiberv = eval("(do (defn deep [n] (+ 1 (deep (+ n 1))))"
                        "    (def f (fiber/new (fn [] (deep 0)) :e))"
                        "    (fiber/setmaxstack f 1000) f)");
    Janet out = janet_wrap_nil();
    JanetSignal sig = resume_fiber(fiberv, janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_ERROR);
    assert(janet_checktype(out, JANET_STRING));
    assert(!janet_cstrcmp(janet_unwrap_string(out), "stack overflow"));
    errors_fired++;
}

/* ------------------------------------------------------------ type assertions */

/* vm_assert_type and vm_assert_types share one message and one formatter, and
 * `%T` renders a bitmask of permitted types rather than a single one. */
static void test_the_type_assertions(void) {
    /* JOP_RESUME, JOP_CANCEL and JOP_PROPAGATE all assert a single type. */
    expect_error("(resume 5)", "expected fiber, got 5");
    expect_error("(cancel 5 :x)", "expected fiber, got 5");
    expect_error("(propagate :x 5)", "expected fiber, got 5");
    /* JOP_TYPECHECK asserts a mask, and the assembler is the only way to emit
     * one the compiler would not -- which is also why this is guarded. `asm`
     * is absent from a build without JANET_ASSEMBLER, and an absent binding is
     * a compile error inside `eval` rather than the runtime error the
     * assertion is looking for. */
#ifdef JANET_ASSEMBLER
    expect_error("((asm '{:arity 1 :bytecode [(tchck 0 :number) (ret 0)]}) :kw)",
                 "expected number, got :kw");
    expect_error("((asm '{:arity 1 :bytecode [(tchck 0 :indexed) (ret 0)]}) :kw)",
                 "expected array or tuple, got :kw");
#endif
    /* JOP_PUSH_ARRAY, which is the splice operator. */
    expect_error("(do (defn f [& xs] xs) (f ;5))", "expected array or tuple, got 5");
}

/* ------------------------------------------------- collection constructors */

static void test_the_collection_constructors(void) {
    expect_equal("@[1 2 3]", "@[1 2 3]");
    expect_equal("[1 2 3]", "[1 2 3]");
    expect_equal("@{:a 1}", "@{:a 1}");
    expect_equal("{:a 1}", "{:a 1}");
    expect_equal("(string \"a\" 1 :b)", "\"a1b\"");
    expect_equal("(buffer \"a\" 1 :b)", "@\"a1b\"");
    /* A bracket tuple carries a flag the round tuple does not, set inside the
     * opcode the two share. */
    expect_equal("(tuple/type '(1 2))", ":parens");
    expect_equal("(tuple/type '[1 2])", ":brackets");
#ifdef JANET_ASSEMBLER
    expect_equal("(tuple/type ((asm '{:arity 0 :constants [1]"
                 "  :bytecode [(ldc 0 0) (push 0) (mkbtp 1) (ret 1)]})))",
                 ":brackets");
    expect_equal("(tuple/type ((asm '{:arity 0 :constants [1]"
                 "  :bytecode [(ldc 0 0) (push 0) (mktup 1) (ret 1)]})))",
                 ":parens");
#endif
}

/* The two constructors that reject an odd argument count do it at run time, and
 * the compiler counts literal arguments before they get there, so the
 * assembler is again the only route. */
#ifdef JANET_ASSEMBLER
static void test_an_odd_constructor_argument_count(void) {
    expect_error("((asm '{:arity 0 :bytecode [(ldi 0 1) (push 0) (mktab 0) (ret 0)]}))",
                 "expected even number of arguments to table constructor, got 1");
    expect_error("((asm '{:arity 0 :bytecode [(ldi 0 1) (push 0) (mkstu 0) (ret 0)]}))",
                 "expected even number of arguments to struct constructor, got 1");
}
#endif

/* ------------------------------------------------------------------- signals */

/* JOP_SIGNAL clamps its operand into the user range. The upper clamp is
 * reachable; the lower is not, because the assembler will not encode a negative
 * one-byte operand. */
#ifdef JANET_ASSEMBLER
static void test_the_signal_opcode(void) {
    Janet out = janet_wrap_nil();
    Janet fiberv = eval("(fiber/new (asm '{:arity 0 :constants [:payload]"
                        "  :bytecode [(ldc 0 0) (sig 1 0 30) (ret 1)]})"
                        " :i0123456789)");
    JanetSignal sig = resume_fiber(fiberv, janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_USER9);
    assert(janet_equals(out, janet_ckeywordv("payload")));

    fiberv = eval("(fiber/new (asm '{:arity 0 :constants [:payload]"
                  "  :bytecode [(ldc 0 0) (sig 1 0 5) (ret 1)]})"
                  " :i0123456789)");
    sig = resume_fiber(fiberv, janet_wrap_nil(), &out);
    /* The operand is the signal number, not the user index: 5 is USER1. */
    assert(sig == JANET_SIGNAL_USER1);
    assert(janet_equals(out, janet_ckeywordv("payload")));
}
#endif

/* JOP_ERROR returns the slot as an error signal without formatting it, which is
 * the precedent the whole return-rather-than-jump path was built on. */
static void test_the_error_opcode(void) {
    Janet out = janet_wrap_nil();
    Janet fiberv = eval("(fiber/new (fn [] (error [1 2])) :e)");
    JanetSignal sig = resume_fiber(fiberv, janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_ERROR);
    assert(janet_checktype(out, JANET_TUPLE));
    assert(janet_tuple_length(janet_unwrap_tuple(out)) == 2);
}

/* JOP_PROPAGATE hands a child's status upward as the parent's signal, and
 * refuses a status above the user range with the only message in the loop that
 * carries a `%s` from a static table. */
static void test_the_propagate_opcode(void) {
    Janet out = janet_wrap_nil();
    Janet fiberv = eval("(do (def child (fiber/new (fn [] (yield :inner)) :y))"
                        "    (resume child)"
                        "    (fiber/new (fn [] (propagate :outer child)) :y))");
    JanetSignal sig = resume_fiber(fiberv, janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_YIELD);
    assert(janet_equals(out, janet_ckeywordv("outer")));

    /* Only :new and :alive sit above JANET_STATUS_USER9, so an unstarted child
     * is the reachable half of the check and a dead one propagates fine. */
    expect_error("(propagate :x (fiber/new (fn [] 1) :y))",
                 "cannot propagate from fiber with status :new");
}

/* ------------------------------------------------------- resume-state decoding */

/* Five flags at the head of the loop decide what a resumed fiber does with the
 * value it was resumed with. Nothing else in the tree reads them. */
static void test_a_resumed_fiber_receives_its_value(void) {
    Janet out = janet_wrap_nil();
    Janet fiberv = eval("(fiber/new (fn [] [(yield 1) (yield 2)]) :y)");

    JanetSignal sig = resume_fiber(fiberv, janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_YIELD);
    assert(janet_equals(out, janet_wrap_integer(1)));

    sig = resume_fiber(fiberv, janet_ckeywordv("first"), &out);
    assert(sig == JANET_SIGNAL_YIELD);
    assert(janet_equals(out, janet_wrap_integer(2)));

    sig = resume_fiber(fiberv, janet_ckeywordv("second"), &out);
    assert(sig == JANET_SIGNAL_OK);
    assert(janet_checktype(out, JANET_TUPLE));
    assert(janet_equals(janet_unwrap_tuple(out)[0], janet_ckeywordv("first")));
    assert(janet_equals(janet_unwrap_tuple(out)[1], janet_ckeywordv("second")));
}

/* A fiber that has not started yet takes its resume value as its first
 * argument rather than into a slot, which happens above the loop -- but the
 * loop still has to skip the instruction it would otherwise re-run. */
static void test_a_new_fiber_receives_its_value_as_an_argument(void) {
    Janet out = janet_wrap_nil();
    Janet fiberv = eval("(fiber/new (fn [x] [:got x]) :y)");
    JanetSignal sig = resume_fiber(fiberv, janet_ckeywordv("in"), &out);
    assert(sig == JANET_SIGNAL_OK);
    assert(janet_equals(janet_unwrap_tuple(out)[1], janet_ckeywordv("in")));
}

/* After a raise the fiber carries JANET_FIBER_DID_LONGJUMP, which the head of
 * the loop reads to pop a C frame and to turn a raise at a tail call into an
 * implicit return. The signal-injection path sets it too, and travels in
 * gc.flags rather than in flags. */
static void test_a_fiber_resumed_after_a_raise(void) {
    Janet out = janet_wrap_nil();
    Janet fiberv = eval("(fiber/new (fn [] (error :boom)) :ey)");
    JanetSignal sig = resume_fiber(fiberv, janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_ERROR);
    assert(janet_equals(out, janet_ckeywordv("boom")));
    /* And is refused a second time, by janet_check_can_resume rather than by
     * the loop -- which is the boundary Part 4 will move. */
    expect_error("(do (def f (fiber/new (fn [] (error :boom)) :ey)) (resume f) (resume f))",
                 "cannot resume fiber with status :error");
}

/* A raise inside a cfunction leaves a C frame on the fiber, which the head of
 * the loop pops before it can restore anything. */
static void test_a_fiber_resumed_after_a_raise_inside_a_cfunction(void) {
    Janet out = janet_wrap_nil();
    Janet fiberv = eval("(fiber/new (fn [] (yield (length 5))) :ey)");
    JanetSignal sig = resume_fiber(fiberv, janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_ERROR);
    assert(janet_checktype(out, JANET_STRING));
}

/* An injected signal is delivered instead of resuming, and is read back out of
 * gc.flags where janet_signal_inject put it. */
static void test_an_injected_signal(void) {
    Janet out = janet_wrap_nil();
    Janet fiberv = eval("(fiber/new (fn [] (yield 1) :never) :y)");
    JanetSignal sig = resume_fiber(fiberv, janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_YIELD);

    janet_signal_inject(janet_unwrap_fiber(fiberv), JANET_SIGNAL_USER3);
    sig = resume_fiber(fiberv, janet_ckeywordv("injected"), &out);
    assert(sig == JANET_SIGNAL_USER3);
    assert(janet_equals(out, janet_ckeywordv("injected")));
}

/* -------------------------------------------------------------- breakpoints */

/* An opcode the loop does not recognise returns JANET_SIGNAL_DEBUG and sets
 * three flags, so that the resume re-runs the instruction with the breakpoint
 * bit masked off. Bit 7 of the instruction word is how a breakpoint is set, and
 * janet_step sets a temporary one. */
static void test_a_breakpoint_reaches_the_unknown_opcode_arm(void) {
    Janet out = janet_wrap_nil();
    Janet fiberv = eval("(fiber/new (fn [] (+ 1 2) (+ 3 4) :done) :dy)");
    JanetFiber *fiber = janet_unwrap_fiber(fiberv);
    JanetSignal sig = janet_step(fiber, janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_DEBUG);
    assert(janet_fiber_status(fiber) == JANET_STATUS_DEBUG);
    /* Stepping again makes progress rather than repeating, which is what the
     * RESUME_NO_SKIP and RESUME_NO_USEVAL flags are for. */
    sig = janet_step(fiber, janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_DEBUG);
    /* And letting it run finishes. */
    sig = janet_continue(fiber, janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_OK);
    assert(janet_equals(out, janet_ckeywordv("done")));
}

/* janet_step's breakpoints are temporary: it restores the instruction words on
 * the way out, so the resume never re-reads one with bit 7 set. A breakpoint set
 * with debug/fbreak stays, and resuming from it is the only state in which the
 * mask the loop applies to its first opcode does anything. */
static void test_a_permanent_breakpoint(void) {
    Janet out = janet_wrap_nil();
    Janet fiberv = eval("(do (defn g [x] (+ x 1))"
                        "    (def f (fiber/new (fn [] (g 1) (g 2) :done) :dy))"
                        "    (debug/fbreak g 0) f)");
    JanetFiber *fiber = janet_unwrap_fiber(fiberv);
    JanetSignal sig = janet_continue(fiber, janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_DEBUG);
    /* Resuming re-runs the breakpointed instruction with bit 7 masked off, so
     * the second call reaches the same breakpoint rather than the loop
     * reporting the same one forever. */
    sig = janet_continue(fiber, janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_DEBUG);
    sig = janet_continue(fiber, janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_OK);
    assert(janet_equals(out, janet_ckeywordv("done")));
}

/* --------------------------------------------------------- the quieter opcodes */

/* Opcodes with no message and no signal of their own, grouped because each is
 * one line and a missing one is invisible. */
static void test_the_remaining_opcodes(void) {
    /* Jumps, in both polarities, and both nil tests. */
    expect_equal("(do (defn f [x] (if x :t :f)) [(f true) (f false) (f nil)])",
                 "[:t :f :f]");
    expect_equal("(do (defn f [x] (if (nil? x) :n :s)) [(f nil) (f false)])",
                 "[:n :s]");
    /* Upvalues, read and written, on the stack and off it. */
    expect_equal("(do (var v 0) (defn f [] (set v (+ v 1)) v) [(f) (f) v])",
                 "[1 2 2]");
    /* A closure over a frame captured lazily. */
    expect_equal("(do (defn outer [x] (fn [] x)) ((outer 9)))", "9");
    /* Self reference, which is how a named function calls itself. */
    expect_equal("(do (defn fact [n] (if (< n 2) 1 (* n (fact (- n 1))))) (fact 5))",
                 "120");
    /* Keyed and indexed access, and their in-place writers. */
    expect_equal("(do (def t @{:a 1}) [(get t :a) (get t :b) (in [10 20] 1)])",
                 "[1 nil 20]");
    expect_equal("(do (def a @[1 2]) (put a 0 :x) a)", "@[:x 2]");
    expect_equal("(do (def t @{}) (put t :k :v) t)", "@{:k :v}");
    expect_equal("(length \"abcd\")", "4");
    /* next, which restores all three registers rather than just the stack. */
    expect_equal("(do (def t @{:a 1}) (next t nil))", ":a");
    expect_equal("(seq [[k v] :pairs {:a 1}] [k v])", "@[[:a 1]]");
    /* next over a fiber resumes it, and the opcode asks for the interpreter's
     * handling of a signal the child's mask does not catch: re-signalled, so an
     * escaping yield stays a yield. Called from C it would become an error
     * instead, which is the same function's other argument. */
    expect_equal("(do (def child (fiber/new (fn [] (yield 1)) :d))"
                 "    (def outer (fiber/new (fn [] (next child nil)) :yd))"
                 "    [(resume outer) (fiber/status outer)])",
                 "[1 :pending]");
    /* Constants, integers, booleans and nil. */
    expect_equal("(do (defn f [] [nil true false 7 :kw]) (f))",
                 "[nil true false 7 :kw]");
    /* The two opcodes nothing else in this tree reaches, because the compiler
     * cannot emit either. Phase 9's gate counted every dispatch made by
     * thirty-five suites and fifty-five contracts and found exactly these two
     * at zero; the assembler is the only way to execute them at all.
     *
     * JOP_NOOP is written by the dead-write optimizer and then deleted by
     * no-op removal before the function is ever run, so no compiled function
     * contains one -- `disasm` confirms the assembler leaves these in place.
     * JOP_MAKE_STRING has no emitter anywhere in the compiler: `(string ...)`
     * compiles to a call of the `string` cfunction. */
#ifdef JANET_ASSEMBLER
    expect_equal("((asm '{:arity 0 :bytecode [(noop) (ldi 0 7) (noop) (ret 0)]}))",
                 "7");
    expect_equal("((asm '{:arity 0 :constants [\"ab\" :cd]"
                 "  :bytecode [(ldc 0 0) (push 0) (ldc 0 1) (push 0)"
                 "             (mkstr 0) (ret 0)]}))",
                 "\"abcd\"");
#endif

    /* Register moves, near and far. */
    expect_equal("(do (defn f [a b c d e g h] [a h]) (f 1 2 3 4 5 6 7))", "[1 7]");
    /* Resume and cancel of a child fiber. */
    expect_equal("(do (def c (fiber/new (fn [] (yield 1) 2) :y)) [(resume c) (resume c)])",
                 "[1 2]");
    expect_equal("(do (def c (fiber/new (fn [] (yield 1)) :ye))"
                 "    (resume c) (try (cancel c :stop) ([e] e)))", ":stop");
}

/* ------------------------------------------------------------------- entry */

int main(void) {
    janet_init();
    test_env = janet_core_env(NULL);

    test_arithmetic_takes_the_numeric_path();
    test_a_bitwise_operand_out_of_range();
    test_a_bitwise_right_operand_out_of_range();
    test_the_operator_fallbacks();

    test_comparison();

    test_the_call_arity_message();
    test_calling_a_cfunction();
    test_calling_a_non_function();
    test_stack_overflow();

    test_the_type_assertions();
    test_the_collection_constructors();
#ifdef JANET_ASSEMBLER
    test_an_odd_constructor_argument_count();
    test_the_signal_opcode();
#endif
    test_the_error_opcode();
    test_the_propagate_opcode();

    test_a_resumed_fiber_receives_its_value();
    test_a_new_fiber_receives_its_value_as_an_argument();
    test_a_fiber_resumed_after_a_raise();
    test_a_fiber_resumed_after_a_raise_inside_a_cfunction();
    test_an_injected_signal();

    test_a_breakpoint_reaches_the_unknown_opcode_arm();
    test_a_permanent_breakpoint();
    test_the_remaining_opcodes();

    if (errors_fired != EXPECTED_ERRORS) {
        printf("expected %d errors, counted %d\n", EXPECTED_ERRORS, errors_fired);
        assert(0 && "error count mismatch");
    }

    janet_deinit();
    printf("vm run contract ok (%d errors)\n", errors_fired);
    return 0;
}
