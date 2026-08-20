/* Behavioral contract for the PEG engine, run against whichever
 * implementation the build selected (`-Dpeg-engine=c` or the Zig default).
 *
 * The reason this file exists rather than leaning on `test/suite-peg.janet`:
 * that suite has 366 assertions and every one of them is about what a pattern
 * *matches*. Three things it cannot see:
 *
 *  - **The bytecode.** The compiler, the matcher and the verifier share a
 *    private instruction encoding that appears in no header and has no other
 *    consumer, so a change made consistently in all three is invisible from
 *    Janet. It is also a file format: a marshalled peg is those words, so a
 *    renumbered opcode silently invalidates every stored peg.
 *  - **The one allocation.** `make_peg` packs the header, the bytecode and the
 *    constants into a single `janet_abstract`, with padding computed so that
 *    each array is aligned. Nothing in Janet can observe the layout, and
 *    `peg_unmarshal` has to reproduce it exactly or read the wrong words.
 *  - **Crafted bytecode.** `peg_unmarshal` is the untrusted entry point, and
 *    most of what it must reject cannot be produced by the compiler at all.
 *
 * `janet_peg_type` is public API, so the shape of its callback table is a
 * contract too, and one Janet cannot see.
 */

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "features.h"
#include "features.h"
#include <janet.h>

#include "support.h"
#include "state.h"
#include "util.h"

static JanetTable *test_env;
static JanetArray *rooted;

/* Six without `JANET_INT_TYPES` and eight with it, because a `double` capture
 * cannot carry more than 53 bits. Both the compiler's limit and the verifier's
 * move with it, so the assertions that name a width have to as well. */
#ifdef JANET_INT_TYPES
#define MAX_READINT_WIDTH 8
#define MAX_READINT_WIDTH_TEXT "8"
#else
#define MAX_READINT_WIDTH 6
#define MAX_READINT_WIDTH_TEXT "6"
#endif

static int panics_fired = 0;
#define EXPECTED_PANICS 34

#define EXPECT_PANIC(expr, message) do { \
    JanetTryState _state; \
    int _raised = 0; \
    JanetSignal _sig = JANET_SIGNAL_OK; \
    janet_try_init(&_state); \
    janet_contract_arm(); \
    (void)(expr); \
    _raised = janet_contract_raised(); \
    if (_raised) _sig = janet_contract_signal(); \
    janet_restore(&_state); \
    assert(_raised && "expected a panic, got a return"); \
    assert(_sig == JANET_SIGNAL_ERROR); \
    assert(janet_checktype(_state.payload, JANET_STRING)); \
    if (janet_cstrcmp(janet_unwrap_string(_state.payload), (message))) { \
        printf("expected: %s\n     got: %s\n", (message), \
               (const char *) janet_unwrap_string(_state.payload)); \
        assert(0 && "message mismatch"); \
    } \
    panics_fired++; \
} while (0)

/* Every grammar error renders the offending form with `%p`, which prints a
 * pointer for a mutable form. Only the tail after that is a contract, so these
 * are matched by suffix. */
#define EXPECT_PANIC_SUFFIX(expr, suffix) do { \
    JanetTryState _state; \
    int _raised = 0; \
    JanetSignal _sig = JANET_SIGNAL_OK; \
    janet_try_init(&_state); \
    janet_contract_arm(); \
    (void)(expr); \
    _raised = janet_contract_raised(); \
    if (_raised) _sig = janet_contract_signal(); \
    janet_restore(&_state); \
    assert(_raised && "expected a panic, got a return"); \
    assert(_sig == JANET_SIGNAL_ERROR); \
    assert(janet_checktype(_state.payload, JANET_STRING)); \
    { \
        JanetString _s = janet_unwrap_string(_state.payload); \
        size_t _n = strlen(suffix); \
        int32_t _len = janet_string_length(_s); \
        if ((size_t) _len < _n || memcmp(_s + _len - _n, (suffix), _n)) { \
            printf("expected suffix: %s\n            got: %s\n", (suffix), (const char *) _s); \
            assert(0 && "message suffix mismatch"); \
        } \
    } \
    panics_fired++; \
} while (0)

/* ------------------------------------------------------------- evaluation */

static Janet eval(const char *source) {
    Janet out = janet_wrap_nil();
    int status = janet_dostring(test_env, source, "peg-contract", &out);
    if (status) {
        printf("evaluating %s failed\n", source);
        assert(0 && "evaluation failed");
    }
    return out;
}

/* Compiled pegs and the forms they came from are held here: a `Janet` in a C
 * local is not a GC root, and compiling one form allocates enough to collect
 * the next. Declared with `test_env` above.
 */

static JanetPeg *compiled(const char *pattern) {
    char source[1024];
    int written = snprintf(source, sizeof(source), "(peg/compile %s)", pattern);
    assert(written > 0 && (size_t) written < sizeof(source));
    Janet value = eval(source);
    assert(janet_checkabstract(value, &janet_peg_type));
    janet_array_push(rooted, value);
    return (JanetPeg *) janet_unwrap_abstract(value);
}

/* `peg/compile` reached as a cfunction rather than through `janet_dostring`,
 * so that a grammar error arrives here as a panic instead of as a status code
 * the evaluator has already caught. That is also the face a C embedder uses. */
static JanetCFunction peg_compile_cfun;

static Janet compile_value(Janet source) {
    Janet argv[1] = {source};
    /* Phase 10 Part 17g: a cfunction is a Zig function, so C invokes one
     * through the shim, which also turns its raise back into the jump this
     * file's panic assertions want. See the same call in test/io_core.c. */
    return janet_contract_call_cfunction(peg_compile_cfun, 1, argv);
}

/* `source` is Janet source for the *pattern*, evaluated before the panic scope
 * opens so that only the compilation is inside it. */
#define EXPECT_GRAMMAR_ERROR(source, suffix) do { \
    Janet _pattern = eval(source); \
    janet_array_push(rooted, _pattern); \
    EXPECT_PANIC_SUFFIX(compile_value(_pattern), suffix); \
} while (0)

static void check_bytecode(const char *pattern, const uint32_t *expected, size_t count) {
    JanetPeg *peg = compiled(pattern);
    int wrong = peg->bytecode_len != count;
    for (size_t i = 0; !wrong && i < count; i++)
        wrong = peg->bytecode[i] != expected[i];
    if (wrong) {
        printf("%s\n  expected %zu words:", pattern, count);
        for (size_t i = 0; i < count; i++) printf(" %u", expected[i]);
        printf("\n       got %zu words:", peg->bytecode_len);
        for (size_t i = 0; i < peg->bytecode_len; i++) printf(" %u", peg->bytecode[i]);
        printf("\n");
        assert(0 && "bytecode mismatch");
    }
}

#define CHECK_BYTECODE(pattern, ...) do { \
    const uint32_t _want[] = {__VA_ARGS__}; \
    check_bytecode((pattern), _want, sizeof(_want) / sizeof(uint32_t)); \
} while (0)

/* ------------------------------------------------------ the abstract type */

/* `janet_peg_type` is exported from `janet.h`, so an embedder sees which
 * callbacks a peg has and which it does not. A peg has no `gc` because it owns
 * no memory outside its own allocation, no `tostring` because the default
 * `<core/peg 0x...>` is the intended rendering, and no `compare` or `hash`
 * because two separately compiled pegs are distinct values even when they came
 * from the same source. */
static void test_the_abstract_type_is_shaped_as_the_runtime_expects(void) {
    assert(!janet_cstrcmp(janet_cstring("core/peg"), janet_peg_type.name));

    assert(janet_peg_type.gc == NULL);
    assert(janet_peg_type.gcmark != NULL);
    assert(janet_peg_type.get != NULL);
    assert(janet_peg_type.put == NULL);
    assert(janet_peg_type.marshal != NULL);
    assert(janet_peg_type.unmarshal != NULL);
    assert(janet_peg_type.tostring == NULL);
    assert(janet_peg_type.compare == NULL);
    assert(janet_peg_type.hash == NULL);
    assert(janet_peg_type.next != NULL);
    assert(janet_peg_type.call == NULL);
    assert(janet_peg_type.length == NULL);
    assert(janet_peg_type.bytes == NULL);

    /* Registered under its own name, which is what lets a marshalled peg name
     * its type on the wire. */
    assert(janet_get_abstract_type(janet_csymbolv("core/peg")) == &janet_peg_type);
}

/* The five methods, in the order `janet_nextmethod` walks them -- which is the
 * order `(keys peg)` reports and therefore the order a Janet program sees. */
static void test_the_method_table_and_its_order(void) {
    JanetPeg *peg = compiled("\"a\"");
    Janet value = janet_wrap_abstract(peg);
    static const char *const names[] = {"match", "find", "find-all", "replace", "replace-all"};

    Janet key = janet_wrap_nil();
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        key = janet_next(value, key);
        assert(janet_checktype(key, JANET_KEYWORD));
        assert(!janet_cstrcmp(janet_unwrap_keyword(key), names[i]));
        Janet method = janet_get(value, key);
        assert(janet_checktype(method, JANET_CFUNCTION));
    }
    assert(janet_checktype(janet_next(value, key), JANET_NIL));

    /* A non-keyword key is not a method lookup at all. */
    assert(janet_checktype(janet_get(value, janet_wrap_integer(0)), JANET_NIL));
}

/* ------------------------------------------------------- the one allocation
 *
 * `make_peg` and `peg_unmarshal` compute the same three offsets, and they have
 * to agree: the unmarshaller writes through pointers the compiler never sees.
 * The formula is duplicated here rather than shared, so that a change to it in
 * the implementation shows up as a failure rather than as agreement. */
static size_t padded(size_t offset, size_t size) {
    size_t x = size + offset - 1;
    return x - (x % size);
}

static void test_the_header_bytecode_and_constants_share_one_allocation(void) {
    JanetPeg *peg = compiled("'(* (<- \"ab\") (constant 7))");
    const char *mem = (const char *) peg;
    size_t bytecode_start = padded(sizeof(JanetPeg), sizeof(uint32_t));
    size_t constants_start =
        padded(bytecode_start + peg->bytecode_len * sizeof(uint32_t), sizeof(Janet));

    assert((const char *) peg->bytecode == mem + bytecode_start);
    assert((const char *) peg->constants == mem + constants_start);
    assert(peg->num_constants == 1);
    assert(janet_equals(peg->constants[0], janet_wrap_integer(7)));

    /* Both arrays are aligned for their element type, which is the whole point
     * of the padding. */
    assert(((uintptr_t) peg->bytecode) % sizeof(uint32_t) == 0);
    assert(((uintptr_t) peg->constants) % sizeof(Janet) == 0);

    /* And the abstract really is one allocation: its size covers both. */
    assert(janet_abstract_size(peg) ==
           constants_start + peg->num_constants * sizeof(Janet));
}

/* --------------------------------------------------------- the instructions
 *
 * One assertion per opcode the compiler can emit, which is the vocabulary the
 * matcher switches on and the verifier walks. Written as literal words for the
 * reason `test/marsh.c` writes literal bytes: a round trip through the same
 * two halves agrees with itself whatever it encodes. */
static void test_every_special_emits_its_instruction(void) {
    /* Primitives, which are not tuples at all. */
    CHECK_BYTECODE("true", RULE_NCHAR, 0);
    CHECK_BYTECODE("false", RULE_NOTNCHAR, 0);
    CHECK_BYTECODE("3", RULE_NCHAR, 3);
    CHECK_BYTECODE("-3", RULE_NOTNCHAR, 3);
    /* A literal's bytes are packed four to a word, rounded up. */
    CHECK_BYTECODE("\"abc\"", RULE_LITERAL, 3, 0x00636261u);
    CHECK_BYTECODE("\"abcde\"", RULE_LITERAL, 5, 0x64636261u, 0x00000065u);
    CHECK_BYTECODE("\"\"", RULE_LITERAL, 0);
    CHECK_BYTECODE("@\"ab\"", RULE_LITERAL, 2, 0x00006261u);

    /* A single range is its own opcode; two or more compile to a set. */
    CHECK_BYTECODE("'(range \"az\")", RULE_RANGE, 0x007A0061u);
    CHECK_BYTECODE("'(set \"ab\")", RULE_SET, 0, 0, 0, 0x00000006u, 0, 0, 0, 0);
    CHECK_BYTECODE("'(range \"ab\" \"yz\")",
                   RULE_SET, 0, 0, 0, 0x06000006u, 0, 0, 0, 0);

    CHECK_BYTECODE("'(> 2 \"a\")", RULE_LOOK, 2, 3, RULE_LITERAL, 1, 0x61u);
    CHECK_BYTECODE("'(> -2 \"a\")", RULE_LOOK, (uint32_t) -2, 3, RULE_LITERAL, 1, 0x61u);
    /* One argument means an offset of zero. */
    CHECK_BYTECODE("'(look \"a\")", RULE_LOOK, 0, 3, RULE_LITERAL, 1, 0x61u);

    /* A variadic rule reserves its operand slots before compiling into them. */
    CHECK_BYTECODE("'(+ 1 2)", RULE_CHOICE, 2, 4, 6, RULE_NCHAR, 1, RULE_NCHAR, 2);
    CHECK_BYTECODE("'(* 1 2)", RULE_SEQUENCE, 2, 4, 6, RULE_NCHAR, 1, RULE_NCHAR, 2);
    CHECK_BYTECODE("'(+)", RULE_CHOICE, 0);
    CHECK_BYTECODE("'(*)", RULE_SEQUENCE, 0);

    CHECK_BYTECODE("'(if 1 2)", RULE_IF, 3, 5, RULE_NCHAR, 1, RULE_NCHAR, 2);
    CHECK_BYTECODE("'(if-not 1 2)", RULE_IFNOT, 3, 5, RULE_NCHAR, 1, RULE_NCHAR, 2);
    CHECK_BYTECODE("'(lenprefix 1 2)", RULE_LENPREFIX, 3, 5, RULE_NCHAR, 1, RULE_NCHAR, 2);
    CHECK_BYTECODE("'(! 1)", RULE_NOT, 2, RULE_NCHAR, 1);

    /* Every repetition is one `RULE_BETWEEN` with different bounds. */
    CHECK_BYTECODE("'(between 2 4 1)", RULE_BETWEEN, 2, 4, 4, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(some 1)", RULE_BETWEEN, 1, UINT32_MAX, 4, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(any 1)", RULE_BETWEEN, 0, UINT32_MAX, 4, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(at-least 3 1)", RULE_BETWEEN, 3, UINT32_MAX, 4, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(at-most 3 1)", RULE_BETWEEN, 0, 3, 4, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(? 1)", RULE_BETWEEN, 0, 1, 4, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(repeat 3 1)", RULE_BETWEEN, 3, 3, 4, RULE_NCHAR, 1);
    /* A leading integer is `repeat` spelled without the word. */
    CHECK_BYTECODE("'(3 1)", RULE_BETWEEN, 3, 3, 4, RULE_NCHAR, 1);

    CHECK_BYTECODE("'(<- 1)", RULE_CAPTURE, 3, 0, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(% 1)", RULE_ACCUMULATE, 3, 0, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(group 1)", RULE_GROUP, 3, 0, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(unref 1)", RULE_UNREF, 3, 0, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(drop 1)", RULE_DROP, 2, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(only-tags 1)", RULE_ONLY_TAGS, 2, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(to 1)", RULE_TO, 2, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(thru 1)", RULE_THRU, 2, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(error 1)", RULE_ERROR, 2, RULE_NCHAR, 1);
    /* `(error)` with no argument errors on the empty match. */
    CHECK_BYTECODE("'(error)", RULE_ERROR, 2, RULE_NCHAR, 0);

    CHECK_BYTECODE("'($)", RULE_POSITION, 0);
    CHECK_BYTECODE("'(line)", RULE_LINE, 0);
    CHECK_BYTECODE("'(column)", RULE_COLUMN, 0);
    CHECK_BYTECODE("'(backmatch)", RULE_BACKMATCH, 0);
    CHECK_BYTECODE("'(?\?)", RULE_DEBUG);
    CHECK_BYTECODE("'(argument 2)", RULE_ARGUMENT, 2, 0);
    CHECK_BYTECODE("'(constant :x)", RULE_CONSTANT, 0, 0);
    CHECK_BYTECODE("'(nth 2 1)", RULE_NTH, 2, 4, 0, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(number 1)", RULE_CAPTURE_NUM, 4, 0, 0, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(number 1 16)", RULE_CAPTURE_NUM, 4, 16, 0, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(number 1 nil)", RULE_CAPTURE_NUM, 4, 0, 0, RULE_NCHAR, 1);

    CHECK_BYTECODE("'(sub 1 2)", RULE_SUB, 3, 5, RULE_NCHAR, 1, RULE_NCHAR, 2);
    CHECK_BYTECODE("'(til 1 2)", RULE_TIL, 3, 5, RULE_NCHAR, 1, RULE_NCHAR, 2);
    CHECK_BYTECODE("'(split 1 2)", RULE_SPLIT, 3, 5, RULE_NCHAR, 1, RULE_NCHAR, 2);
    CHECK_BYTECODE("'(/ 1 :x)", RULE_REPLACE, 4, 0, 0, RULE_NCHAR, 1);
    CHECK_BYTECODE("~(cmt 1 ,identity)", RULE_MATCHTIME, 4, 0, 0, RULE_NCHAR, 1);
    CHECK_BYTECODE("~(cms 1 ,identity)", RULE_MATCHSPLICE, 4, 0, 0, RULE_NCHAR, 1);

    /* The width and the two flag bits share one operand word. */
    CHECK_BYTECODE("'(uint 4)", RULE_READINT, 0x04u, 0);
    CHECK_BYTECODE("'(int 4)", RULE_READINT, 0x14u, 0);
    CHECK_BYTECODE("'(uint-be 4)", RULE_READINT, 0x24u, 0);
    CHECK_BYTECODE("'(int-be 4)", RULE_READINT, 0x34u, 0);

    /* Every alias emits what the symbol it aliases emits. */
    CHECK_BYTECODE("'(not 1)", RULE_NOT, 2, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(quote 1)", RULE_CAPTURE, 3, 0, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(capture 1)", RULE_CAPTURE, 3, 0, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(accumulate 1)", RULE_ACCUMULATE, 3, 0, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(choice 1)", RULE_CHOICE, 1, 3, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(sequence 1)", RULE_SEQUENCE, 1, 3, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(opt 1)", RULE_BETWEEN, 0, 1, 4, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(position)", RULE_POSITION, 0);
    CHECK_BYTECODE("'(debug)", RULE_DEBUG);
}

/* Tags are numbered from one, because zero is the "no tag" sentinel, and the
 * same keyword reuses its number. `(-> :t)` and `(backmatch :t)` are also the
 * only two specials that set `has_backref`, which is what makes the matcher
 * maintain the third capture stack at all. */
static void test_tags_are_numbered_and_backrefs_are_flagged(void) {
    CHECK_BYTECODE("'(<- 1 :a)", RULE_CAPTURE, 3, 1, RULE_NCHAR, 1);
    /* The third capture is the first one again -- same tuple, same grammar --
     * so it is cached rather than emitted, and its tag is reused too. */
    CHECK_BYTECODE("'(* (<- 1 :a) (<- 1 :b) (<- 1 :a))",
                   RULE_SEQUENCE, 3, 5, 10, 5,
                   RULE_CAPTURE, 8, 1,
                   RULE_NCHAR, 1,
                   RULE_CAPTURE, 8, 2);

    assert(compiled("\"a\"")->has_backref == 0);
    assert(compiled("'(<- 1 :a)")->has_backref == 0);
    assert(compiled("'(-> :a)")->has_backref == 1);
    assert(compiled("'(backmatch :a)")->has_backref == 1);
    assert(compiled("'(backref :a)")->has_backref == 1);
    /* `unref` names a tag without needing the tagged stack. */
    assert(compiled("'(unref 1 :a)")->has_backref == 0);
}

/* A pattern already compiled in this grammar is reused rather than emitted
 * twice, which is what makes a recursive grammar terminate. A tuple is cached
 * only in the grammar it was seen in, because `(+ :a :b)` means different
 * things under different bindings; anything else goes to the root table. */
static void test_the_compiler_caches_rules(void) {
    /* Two references to the same primitive share one rule. */
    CHECK_BYTECODE("'(* 1 1)", RULE_SEQUENCE, 2, 4, 4, RULE_NCHAR, 1);
    /* A recursive grammar refers back to a rule still being built. */
    CHECK_BYTECODE("'{:main (* \"a\" (? :main))}",
                   RULE_SEQUENCE, 2, 4, 7,
                   RULE_LITERAL, 1, 0x61u,
                   RULE_BETWEEN, 0, 1, 0);
}

/* ---------------------------------------------------------- grammar errors
 *
 * Every one of these renders through `peg_panic`, which prints the form being
 * compiled and then the message. `(constant)` is the exception and is a
 * defect; see `FOUND.md`. */
static void test_grammar_errors_name_the_form(void) {
    EXPECT_GRAMMAR_ERROR("'(unknown-special)", ", unknown special unknown-special");
    EXPECT_GRAMMAR_ERROR("'()", ", tuple in grammar must have non-zero length");
    EXPECT_GRAMMAR_ERROR("'(\"a\")", ", expected grammar command, found \"a\"");
    EXPECT_GRAMMAR_ERROR(":nope", ", unknown rule");
    EXPECT_GRAMMAR_ERROR("{:notmain 1}", ", grammar requires :main rule");
    EXPECT_GRAMMAR_ERROR("@{:notmain 1}", ", grammar requires :main rule");
    EXPECT_GRAMMAR_ERROR("print", ", unexpected peg source");

    EXPECT_GRAMMAR_ERROR("'(! 1 2)", ", expected 1 argument, got 2");
    EXPECT_GRAMMAR_ERROR("'(sub 1)", ", expected 2 arguments, got 1");
    EXPECT_GRAMMAR_ERROR("'(nth 1)", ", arity mismatch, expected at least 2, got 1");
    EXPECT_GRAMMAR_ERROR("'(?\? 1)", ", arity mismatch, expected at most 0, got 1");

    EXPECT_GRAMMAR_ERROR("'(set 1)", ", expected string for character set");
    EXPECT_GRAMMAR_ERROR("'(range 1)", ", expected string for character range");
    EXPECT_GRAMMAR_ERROR("'(range \"abc\")", ", expected string to have length 2, got \"abc\"");
    EXPECT_GRAMMAR_ERROR("'(range \"ba\")", ", range \"ba\" is empty");
    EXPECT_GRAMMAR_ERROR("'(> \"x\" 1)", ", expected integer, got \"x\"");
    EXPECT_GRAMMAR_ERROR("'(repeat -1 1)", ", expected non-negative integer, got -1");
    EXPECT_GRAMMAR_ERROR("'(-1 1)", ", expected non-negative integer, got -1");
    EXPECT_GRAMMAR_ERROR("'(<- 1 \"a\")", ", expected keyword for capture tag, got \"a\"");
    EXPECT_GRAMMAR_ERROR("'(number 1 40)", ", expected integer between 2 and 36, got 40");
    EXPECT_GRAMMAR_ERROR("'(cmt 1 2)", ", expected function or cfunction, got 2");
    EXPECT_GRAMMAR_ERROR("'(uint " MAX_READINT_WIDTH_TEXT "1)",
                         ", width must be between 0 and " MAX_READINT_WIDTH_TEXT
                         ", got " MAX_READINT_WIDTH_TEXT "1");

    /* Two hundred and fifty-five tags fit in the byte the tag stack uses; the
     * two hundred and fifty-sixth does not. */
    EXPECT_GRAMMAR_ERROR(
        "(tuple '* ;(map (fn [i] ~(<- 1 ,(keyword \"t\" i))) (range 256)))",
        ", too many tags - up to 255 tags are supported per peg");

    /* `FOUND.md`: every special above checks its arity with `peg_arity`, which
     * renders the form. `(constant)` uses `janet_arity` and does not. */
    {
        Janet pattern = eval("'(constant)");
        janet_array_push(rooted, pattern);
        EXPECT_PANIC(compile_value(pattern), "arity mismatch, expected at least 1, got 0");
    }
}

/* ------------------------------------------------------------ the two guards
 *
 * The compiler and the matcher each have a recursion budget, and they are not
 * the same budget: the matcher's is reset per attempt by `peg_call_reset`, so
 * `peg/find` gets a fresh one at every offset. Both start at
 * `JANET_RECURSION_GUARD`.
 *
 * Only the compiler's two are asserted here. Reaching the matcher's needs a
 * recursive grammar and about a thousand live `peg_rule` frames, and the C
 * implementation overflows the stack before it gets there in an unoptimised
 * build -- see `FOUND.md`. A test for it would crash the implementation this
 * contract is verified against, which is the finding rather than a reason to
 * write the test.
 */
static void test_the_compiler_bounds_both_of_its_recursions(void) {
    /* A keyword chain that resolves through more than the guard allows.
     * `peg_compile1` walks this in a loop rather than by recursing. */
    Janet chained = eval(
        "(do (def g @{})"
        "    (loop [i :range [0 1100]] (put g (keyword \"r\" i) (keyword \"r\" (+ i 1))))"
        "    (put g :main :r0)"
        "    (put g (keyword \"r\" 1100) 1)"
        "    (protect (peg/compile g)))");
    assert(!janet_unwrap_boolean(janet_unwrap_tuple(chained)[0]));
    assert(!janet_cstrcmp(janet_unwrap_string(janet_unwrap_tuple(chained)[1]),
                          "grammar error in :r1024, reference chain too deep"));

    /* Nesting rather than chaining spends the other counter, and that one is
     * real recursion through `peg_compile1`. */
    Janet nested = eval(
        "(do (var p 1)"
        "    (loop [_ :range [0 1100]] (set p ~(! ,p)))"
        "    (protect (peg/compile p)))");
    assert(!janet_unwrap_boolean(janet_unwrap_tuple(nested)[0]));
    {
        /* The form this one names is a thousand rules deep, so only the tail
         * of the message is a contract. */
        JanetString message = janet_unwrap_string(janet_unwrap_tuple(nested)[1]);
        const char *tail = ", peg grammar recursed too deeply";
        size_t n = strlen(tail);
        int32_t len = janet_string_length(message);
        assert((size_t) len > n && !memcmp(message + len - n, tail, n));
    }

    /* One below the budget still compiles, which is what makes the number
     * above a boundary rather than an upper bound. */
    Janet just_inside = eval(
        "(do (var p 1)"
        "    (loop [_ :range [0 1022]] (set p ~(! ,p)))"
        "    (protect (peg/compile p)))");
    assert(janet_unwrap_boolean(janet_unwrap_tuple(just_inside)[0]));
}

/* -------------------------------------------------------------- the wire
 *
 * A compiled peg is a marshalled abstract, and its payload is the bytecode
 * word for word. The bytes below pin the opcode numbers: renumbering the
 * `JanetPegOpcode` enum would keep every Janet test passing and invalidate
 * every stored peg. */
static void test_the_marshalled_form_is_the_bytecode(void) {
    JanetPeg *peg = compiled("\"a\"");
    JanetBuffer *buffer = janet_buffer(32);
    janet_marshal(buffer, janet_wrap_abstract(peg), NULL, 0);

    static const uint8_t expected[] = {
        217,                                    /* LB_ABSTRACT */
        207, 8, 'c', 'o', 'r', 'e', '/', 'p', 'e', 'g',
        3,                                      /* bytecode_len */
        0,                                      /* num_constants */
        RULE_LITERAL, 1, 0x61,                  /* the three words */
    };
    if (buffer->count != (int32_t) sizeof(expected) ||
            memcmp(buffer->data, expected, sizeof(expected))) {
        printf("expected %zu bytes:", sizeof(expected));
        for (size_t i = 0; i < sizeof(expected); i++) printf(" %02x", expected[i]);
        printf("\n     got %d bytes:", buffer->count);
        for (int32_t i = 0; i < buffer->count; i++) printf(" %02x", buffer->data[i]);
        printf("\n");
        assert(0 && "peg wire format mismatch");
    }

    /* And back, into an equal but distinct peg. */
    Janet back = janet_unmarshal(buffer->data, (size_t) buffer->count, 0, NULL, NULL);
    assert(janet_checkabstract(back, &janet_peg_type));
    janet_array_push(rooted, back);
    JanetPeg *round = (JanetPeg *) janet_unwrap_abstract(back);
    assert(round != peg);
    assert(round->bytecode_len == 3);
    assert(round->num_constants == 0);
    assert(round->has_backref == 0);
    assert(!memcmp(round->bytecode, peg->bytecode, 3 * sizeof(uint32_t)));
    /* The unmarshaller reproduces the compiler's layout, not just its words. */
    assert((const char *) round->bytecode - (const char *) round ==
           (const char *) peg->bytecode - (const char *) peg);
}

/* -------------------------------------------------- the untrusted entry point
 *
 * Everything below builds a peg stream by hand. `peg_unmarshal` is the only
 * way bytecode the compiler could not have produced reaches the matcher, and
 * most of the verifier is unreachable without it. */

/* The framing every crafted stream shares, up to and including the type name.
 * What follows is `bytecode_len`, `num_constants`, the words, the constants --
 * all of them small enough to be one byte each in the marshal encoding. */
#define PEG_HEADER 217, 207, 8, 'c', 'o', 'r', 'e', '/', 'p', 'e', 'g'

static Janet unmarshal_bytes(const uint8_t *bytes, size_t len) {
    return janet_unmarshal(bytes, len, 0, NULL, NULL);
}

#define CRAFTED(...) ((const uint8_t[]){PEG_HEADER, __VA_ARGS__})
#define CRAFTED_LEN(...) (sizeof((const uint8_t[]){PEG_HEADER, __VA_ARGS__}))

#define EXPECT_REJECTED(...) \
    EXPECT_PANIC(unmarshal_bytes(CRAFTED(__VA_ARGS__), CRAFTED_LEN(__VA_ARGS__)), \
                 "invalid peg bytecode")

static JanetPeg *expect_accepted(const uint8_t *bytes, size_t len) {
    Janet value = unmarshal_bytes(bytes, len);
    assert(janet_checkabstract(value, &janet_peg_type));
    janet_array_push(rooted, value);
    return (JanetPeg *) janet_unwrap_abstract(value);
}

#define EXPECT_ACCEPTED(...) expect_accepted(CRAFTED(__VA_ARGS__), CRAFTED_LEN(__VA_ARGS__))

static void test_the_verifier_walks_every_instruction(void) {
    /* The shortest valid program, and the shape everything below varies. */
    JanetPeg *ok = EXPECT_ACCEPTED(2, 0, RULE_NCHAR, 1);
    assert(ok->bytecode_len == 2);
    assert(ok->has_backref == 0);

    /* An opcode past the end of the vocabulary. Kept under 128 so that it is
     * one byte in the marshal integer encoding, like every other word here. */
    EXPECT_REJECTED(2, 0, 100, 0);
    /* A rule operand past the end of the bytecode. */
    EXPECT_REJECTED(2, 0, RULE_NOT, 9);
    /* A constant operand past the end of the constants. */
    EXPECT_REJECTED(3, 0, RULE_CONSTANT, 0, 0);
    /* An instruction that runs off the end. */
    EXPECT_REJECTED(3, 0, RULE_NCHAR, 1, RULE_NCHAR);
    /* A rule operand that points into the middle of another instruction:
     * word 1 is referenced but is not an instruction start. */
    EXPECT_REJECTED(4, 0, RULE_NOT, 1, RULE_NCHAR, 1);
    /* Unreachable bytecode is rejected too, which is stricter than a
     * depth-first walk would be: word 2 is an instruction nothing refers to,
     * and that is fine -- only the reverse is an error. */
    EXPECT_ACCEPTED(4, 0, RULE_NCHAR, 1, RULE_NCHAR, 1);

    /* `has_backref` is recovered from the bytecode rather than marshalled. */
    JanetPeg *backref = EXPECT_ACCEPTED(3, 0, RULE_GETTAG, 1, 0);
    assert(backref->has_backref == 1);
    JanetPeg *backmatch = EXPECT_ACCEPTED(2, 0, RULE_BACKMATCH, 1);
    assert(backmatch->has_backref == 1);
}

/* `FOUND.md`: the verifier accepts a program with no instructions in it, and
 * the matcher then reads `bytecode[0]` from past the end of the bytecode
 * array. Where the padding puts the constants immediately after -- which is
 * every 64-bit build -- that read lands in the constants, so a crafted
 * constant is executed as an instruction. */
static void test_an_empty_program_is_accepted(void) {
    JanetPeg *empty = EXPECT_ACCEPTED(0, 0);
    assert(empty->bytecode_len == 0);
    assert(empty->num_constants == 0);

    /* The array the matcher will read from starts at or past the end of the
     * bytecode array, because the bytecode array has no elements. */
    assert((const char *) empty->bytecode <= (const char *) empty->constants);

    if ((const char *) empty->bytecode == (const char *) empty->constants) {
        /* One constant, a double whose low word is `RULE_NCHAR` and whose high
         * word is 3. `peg/match` on it consumes exactly three bytes. */
        static const uint8_t crafted[] = {
            PEG_HEADER, 0, 1,
            200, RULE_NCHAR, 0, 0, 0, 3, 0, 0, 0, /* LB_REAL, little-endian */
        };
        Janet value = unmarshal_bytes(crafted, sizeof(crafted));
        assert(janet_checkabstract(value, &janet_peg_type));
        janet_array_push(rooted, value);
        JanetPeg *peg = (JanetPeg *) janet_unwrap_abstract(value);
        assert(peg->bytecode_len == 0);
        assert((const char *) peg->bytecode == (const char *) peg->constants);

        Janet args[2] = {value, janet_cstringv("abc")};
        Janet matched = janet_mcall("match", 2, args);
        assert(janet_checktype(matched, JANET_ARRAY));
        args[1] = janet_cstringv("ab");
        assert(janet_checktype(janet_mcall("match", 2, args), JANET_NIL));
    }
}

/* `FOUND.md`: `(argument)` takes a non-negative index from the compiler, but
 * the verifier does not look at the operand and the matcher does not check it,
 * so crafted bytecode reaches `s->extrav[-1]`. Accepted here and deliberately
 * not run. */
static void test_a_negative_argument_index_is_accepted(void) {
    JanetPeg *peg = EXPECT_ACCEPTED(3, 0, RULE_ARGUMENT, 205, 255, 255, 255, 255, 0);
    assert(peg->bytecode_len == 3);
    assert(peg->bytecode[1] == 0xFFFFFFFFu);
}

/* `FOUND.md`: `bytecode_len` comes off the wire as a 64-bit count and is
 * multiplied by four without a check, so a length of 2^62 wraps the byte count
 * to zero and the peg is allocated at the size of its header alone. What
 * follows in `peg_unmarshal` is a loop that writes `bytecode_len` words into
 * it.
 *
 * The stream below stops immediately after the two counts, so the first
 * `janet_unmarshal_int` runs out of input and raises before anything is
 * written. That is deliberate: a stream with words after it corrupts the heap,
 * which is the finding and not something to run. What the assertion pins is
 * that the allocation was made at all -- an implementation that checked the
 * multiplication would refuse, and one that did not wrap would ask for
 * sixteen exabytes and die of it. */
static void test_the_bytecode_length_is_multiplied_without_a_check(void) {
    static const uint8_t crafted[] = {
        PEG_HEADER,
        0xF0 + 8, 0, 0, 0, 0, 0, 0, 0, 0x40,  /* bytecode_len = 1 << 62 */
        0,                                     /* num_constants */
    };
    EXPECT_PANIC(unmarshal_bytes(crafted, sizeof(crafted)), "unexpected end of source");
}

/* `FOUND.md`: the readint width check tests the whole packed operand, which
 * also carries the signedness and endianness bits, against the maximum width.
 * So three of the four readint specials compile fine and are rejected by the
 * verifier that reads them back. */
static void test_readint_pegs_do_not_all_survive_a_round_trip(void) {
    static const char *const patterns[] = {"'(uint 4)", "'(int 4)", "'(uint-be 4)", "'(int-be 4)"};
    static const int survives[] = {1, 0, 0, 0};
    for (size_t i = 0; i < sizeof(patterns) / sizeof(patterns[0]); i++) {
        JanetPeg *peg = compiled(patterns[i]);
        JanetBuffer *buffer = janet_buffer(32);
        janet_marshal(buffer, janet_wrap_abstract(peg), NULL, 0);
        if (survives[i]) {
            Janet back = janet_unmarshal(buffer->data, (size_t) buffer->count, 0, NULL, NULL);
            assert(janet_checkabstract(back, &janet_peg_type));
        } else {
            EXPECT_PANIC(janet_unmarshal(buffer->data, (size_t) buffer->count, 0, NULL, NULL),
                         "invalid peg bytecode");
        }
    }
    /* The width alone is what the check should have looked at, and a bare
     * width still passes. */
    EXPECT_ACCEPTED(3, 0, RULE_READINT, MAX_READINT_WIDTH, 0);
    EXPECT_REJECTED(3, 0, RULE_READINT, MAX_READINT_WIDTH + 1, 0);
}

/* ------------------------------------------------------------------- main */

void peg_contract(void) {
    janet_init();
    test_env = janet_core_env(NULL);
    janet_gcroot(janet_wrap_table(test_env));
    rooted = janet_array(0);
    janet_gcroot(janet_wrap_array(rooted));
    {
        Janet resolved = eval("peg/compile");
        assert(janet_checktype(resolved, JANET_CFUNCTION));
        peg_compile_cfun = janet_unwrap_cfunction(resolved);
    }

    test_the_abstract_type_is_shaped_as_the_runtime_expects();
    test_the_method_table_and_its_order();
    test_the_header_bytecode_and_constants_share_one_allocation();
    test_every_special_emits_its_instruction();
    test_tags_are_numbered_and_backrefs_are_flagged();
    test_the_compiler_caches_rules();
    test_grammar_errors_name_the_form();
    test_the_compiler_bounds_both_of_its_recursions();
    test_the_marshalled_form_is_the_bytecode();
    test_the_verifier_walks_every_instruction();
    test_an_empty_program_is_accepted();
    test_a_negative_argument_index_is_accepted();
    test_the_bytecode_length_is_multiplied_without_a_check();
    test_readint_pegs_do_not_all_survive_a_round_trip();

    assert(panics_fired == EXPECTED_PANICS);

    janet_deinit();
    printf("peg contract ok\n");
}
