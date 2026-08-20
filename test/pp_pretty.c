/* Behavioral contract for the pretty printer and the JDN writer, run against
 * whichever implementation the build selected (`-Dpp=c` or the Zig default).
 *
 * The reason this file exists rather than leaning on the Janet suites: from
 * Janet these are reached only through `string/format` and `buffer/format`,
 * which always supply a buffer and always take the page width from the format
 * string. Three of the printer's parameters are therefore never varied from
 * Janet at all — the null buffer, the start length, and the lookback barrier —
 * and the last two exist precisely so that printing *into text that is already
 * there* behaves differently from printing into an empty buffer.
 *
 * `janet_jdn` has no caller anywhere in the tree and no declaration in any
 * header. This is the only thing that calls it.
 */

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "features.h"
#include <janet.h>

#include "support.h"
#include "util.h"

/* `janet_jdn` is non-static in `pp.c` and declared nowhere. */
JanetBuffer *janet_jdn(JanetBuffer *buffer, int depth, Janet x);

static JanetTable *test_env;

/* Every panic this file expects is counted, because a case that silently
 * stopped panicking would look exactly like one that passed. Fixed rather than
 * a floor, and verified against `-Dpp=c` first. */
static int panics_fired = 0;
#define EXPECTED_PANICS 3

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

/* `memmem` is not in C99, and these run on every target the library builds
 * for. */
static int buffer_contains(JanetBuffer *b, const char *needle) {
    size_t len = strlen(needle);
    int32_t i;
    if ((size_t) b->count < len) return 0;
    for (i = 0; i + (int32_t) len <= b->count; i++) {
        if (memcmp(b->data + i, needle, len) == 0) return 1;
    }
    return 0;
}

static int buffer_ends_with(JanetBuffer *b, const char *tail) {
    size_t len = strlen(tail);
    if ((size_t) b->count < len) return 0;
    return memcmp(b->data + b->count - len, tail, len) == 0;
}

static void check_buffer(JanetBuffer *b, const char *expected) {
    size_t len = strlen(expected);
    if ((size_t) b->count != len || memcmp(b->data, expected, len) != 0) {
        printf("expected: %s\n     got: %.*s\n", expected, (int) b->count, (const char *) b->data);
        assert(0 && "buffer mismatch");
    }
}

static Janet eval(const char *source) {
    Janet out = janet_wrap_nil();
    int status = janet_dostring(test_env, source, "pp-pretty-test", &out);
    assert(status == 0);
    janet_gcroot(out);
    return out;
}

/* Print with an explicit width and flag set.
 *
 * There is no entry point that takes them directly: `janet_pretty` fixes the
 * width at 80, and the printer's three layers are one object behind one
 * selector, so the internal seam that used to carry them is an ordinary Zig
 * call with no C name. This goes through the formatter instead, which is how
 * every real caller reaches those parameters anyway -- and it means the start
 * length and the lookback barrier are set the way a `%p` in the middle of a
 * format string sets them rather than the way a test would.
 *
 * Eight conversion characters carry the eight flag combinations, and the width
 * field holds two digits, which bounds the width at 99. */
/* Through `janet_buffer_format` rather than `janet_formatb`, since Phase 10
 * Part 18. The two loops share `renderPretty` outright -- `test/pp_format.zig`
 * asserts that they agree -- and they set the start length and the lookback
 * barrier the same way, so this reaches the printer exactly as it did. What
 * changed is that the format string is built at runtime here, and the loop
 * that takes a runtime format string is the array one: `formatTuple` parses
 * its format at compile time now, so a width computed here cannot reach it.
 *
 * `janet_buffer_format` is `string/format`'s own loop, which makes this the
 * spelling a real caller uses in any case. It is hidden rather than public,
 * exactly as the C build hid it, so the declaration is here. */
void janet_buffer_format(JanetBuffer *b, const char *strfrmt, int32_t argstart,
                         int32_t argc, Janet *argv);

static JanetBuffer *pretty_width(JanetBuffer *b, int width, int flags, Janet x) {
    static const char conv[8] = { 'p', 'P', 'q', 'Q', 'm', 'M', 'n', 'N' };
    int idx = ((flags & JANET_PRETTY_COLOR) ? 1 : 0)
              | ((flags & JANET_PRETTY_ONELINE) ? 2 : 0)
              | ((flags & JANET_PRETTY_NOTRUNC) ? 4 : 0);
    char fmt[8];
    Janet argv[1];
    assert(width >= 1 && width <= 99);
    snprintf(fmt, sizeof fmt, "%%%d%c", width, conv[idx]);
    argv[0] = x;
    janet_buffer_format(b, fmt, -1, 1, argv);
    return b;
}

/* ------------------------------------------------------ the null buffer */

/* `janet_pretty(NULL, ...)` allocates its own buffer. No caller in the tree
 * passes NULL — every one of them is a format string with a buffer already in
 * hand — so this branch has never run. */
static void test_a_null_buffer_is_allocated(void) {
    JanetBuffer *b = janet_pretty(NULL, JANET_RECURSION_GUARD, 0, eval("[1 2 3]"));
    assert(b != NULL);
    check_buffer(b, "(1 2 3)");

    /* The JDN writer has the same branch and the same absence of callers. */
    {
        JanetBuffer *j = janet_jdn(NULL, JANET_RECURSION_GUARD, eval("[1 2 3]"));
        assert(j != NULL);
        check_buffer(j, "(1 2 3)");
    }
}

/* --------------------------------------------------- the lookback barrier */

/* The barrier is what stops the reflow from rewriting text the caller had
 * already put in the buffer. Without it a `%p` in the middle of a format
 * string could delete newlines belonging to the text before it, which is a
 * corruption rather than a formatting difference. */
static void test_the_barrier_protects_earlier_text(void) {
    JanetBuffer *b = janet_buffer(64);
    static const char preamble[] = "one\n  two\n  three)";
    Janet value = eval("@[@[1 2] @[3 4]]");

    janet_buffer_push_cstring(b, preamble);
    pretty_width(b, 12, 0, value);

    /* Byte for byte, the preamble is untouched — including its newlines and
     * the ')' that would otherwise make the backtracker start here. */
    assert(b->count > (int32_t) strlen(preamble));
    assert(memcmp(b->data, preamble, strlen(preamble)) == 0);

    /* And what followed it did wrap, so the case is not vacuous. */
    assert(memchr(b->data + strlen(preamble), '\n', (size_t)(b->count) - strlen(preamble)) != NULL);
}

/* A narrow page wraps and a wide one does not, from the same value. The pair
 * is what makes the width parameter's effect observable at all, and the wide
 * case is the only one in this file where the reflow actually fires: a printer
 * that never backtracked would still pass every other assertion here.
 *
 * The value is flat rather than nested on purpose. A nested one does not
 * reflow at its outer level whatever the width, because `leaf_align` is left
 * at the inner level's indentation and the walk stops at the first newline
 * indented less than that. */
static void test_the_width_decides_the_wrapping(void) {
    Janet value = eval("@[1 2 3 4 5]");
    JanetBuffer *narrow = janet_buffer(64);
    JanetBuffer *wide = janet_buffer(64);

    pretty_width(narrow, 12, 0, value);
    pretty_width(wide, 16, 0, value);

    check_buffer(narrow, "@[1\n  2\n  3\n  4\n  5]");
    check_buffer(wide, "@[1 2 3 4 5]");
}

/* One-line mode never emits a newline, whatever the width says. */
static void test_one_line_never_wraps(void) {
    JanetBuffer *b = janet_buffer(64);
    pretty_width(b, 4, JANET_PRETTY_ONELINE, eval("@[@[1 2] @[3 4]]"));
    check_buffer(b, "@[@[1 2] @[3 4]]");
}

/* Nesting is the case the reflow does *not* reach, and it is asserted so that
 * a change to the `leaf_align` test shows up as a failure rather than as
 * quietly nicer output. */
static void test_nesting_blocks_the_reflow(void) {
    JanetBuffer *b = janet_buffer(64);
    pretty_width(b, 99, 0, eval("@[@[1 2] @[3 4]]"));
    check_buffer(b, "@[@[1 2]\n  @[3 4]]");
}

/* Colour escapes occupy no columns, and the backtracker steps over them rather
 * than charging the page for them. The same value at the same width must
 * therefore wrap the same way with and without colour — which is the one
 * observable consequence of two `strncmp` branches that nothing else covers. */
static void test_colour_costs_no_columns(void) {
    Janet value = eval("@[1 2 3 4 5]");
    JanetBuffer *plain = janet_buffer(64);
    JanetBuffer *colored = janet_buffer(64);
    int32_t plain_newlines = 0;
    int32_t colored_newlines = 0;
    int32_t i;

    pretty_width(plain, 16, 0, value);
    pretty_width(colored, 16, JANET_PRETTY_COLOR, value);

    for (i = 0; i < plain->count; i++) if (plain->data[i] == '\n') plain_newlines++;
    for (i = 0; i < colored->count; i++) if (colored->data[i] == '\n') colored_newlines++;

    assert(colored->count > plain->count);
    assert(plain_newlines == 0);
    assert(colored_newlines == 0);

    /* And one column narrower, where both must wrap the same way. */
    {
        JanetBuffer *narrow_plain = janet_buffer(64);
        JanetBuffer *narrow_colored = janet_buffer(64);
        int32_t a = 0, e = 0;
        pretty_width(narrow_plain, 12, 0, value);
        pretty_width(narrow_colored, 12, JANET_PRETTY_COLOR, value);
        for (i = 0; i < narrow_plain->count; i++) if (narrow_plain->data[i] == '\n') a++;
        for (i = 0; i < narrow_colored->count; i++) if (narrow_colored->data[i] == '\n') e++;
        assert(a == 4 && e == 4);
    }
}

/* ------------------------------------------------------------- the cycles */

/* A cycle marker carries the id of the value it points back at, and the id is
 * written by the printer's own integer formatter rather than by `snprintf`.
 * A two-digit id is what makes that formatter's digit loop run more than once;
 * every cycle in the Janet suites is `<cycle 0>`. */
static void test_a_two_digit_cycle_id(void) {
    Janet outer = eval(
        "(def as (seq [i :range [0 13]] @[]))\n"
        "(loop [i :range [0 12]] (array/push (as i) (as (+ i 1))))\n"
        "(array/push (last as) (last as))\n"
        "(as 0)");
    JanetBuffer *b = janet_buffer(64);
    pretty_width(b, 99, JANET_PRETTY_ONELINE, outer);
    check_buffer(b, "@[@[@[@[@[@[@[@[@[@[@[@[@[<cycle 12>]]]]]]]]]]]]]");
}

/* A value seen twice without a cycle is printed twice, not marked. The `seen`
 * table is emptied on the way back out of every subtree, and a version that
 * left entries behind would turn a repeated sibling into a cycle marker. */
static void test_a_repeat_that_is_not_a_cycle(void) {
    Janet pair = eval("(def inner @[1 2]) @[inner inner]");
    JanetBuffer *b = janet_buffer(64);
    pretty_width(b, 99, JANET_PRETTY_ONELINE, pair);
    check_buffer(b, "@[@[1 2] @[1 2]]");
}

/* --------------------------------------------------------- the truncations */

/* An indexed value longer than the limit prints three from each end with an
 * elision between; one exactly at the limit prints whole. The boundary is
 * where an off-by-one lives, and the suites use neither length. */
static void test_the_array_truncation_boundary(void) {
    JanetBuffer *at_limit = janet_buffer(1024);
    JanetBuffer *over = janet_buffer(1024);

    pretty_width(at_limit, 99, JANET_PRETTY_ONELINE, eval("(seq [i :range [0 160]] i)"));
    pretty_width(over, 99, JANET_PRETTY_ONELINE, eval("(seq [i :range [0 161]] i)"));

    /* 160 elements, whole: no elision anywhere, and the last element is the
     * last one rather than the last one printed before an elision. */
    assert(!buffer_contains(at_limit, "..."));
    assert(buffer_ends_with(at_limit, " 157 158 159]"));

    /* 161 elements: three, an elision, three. */
    check_buffer(over, "@[0 1 2 ... 158 159 160]");
}

/* The same boundary for a dictionary, where the limit is 30 rather than 160
 * and the elision goes at the end rather than in the middle. */
static void test_the_dictionary_truncation_boundary(void) {
    JanetBuffer *at_limit = janet_buffer(1024);
    JanetBuffer *over = janet_buffer(1024);

    pretty_width(at_limit, 99, JANET_PRETTY_ONELINE, eval("(tabseq [i :range [0 30]] i i)"));
    pretty_width(over, 99, JANET_PRETTY_ONELINE, eval("(tabseq [i :range [0 31]] i i)"));

    assert(!buffer_contains(at_limit, "..."));
    assert(buffer_ends_with(over, " ...}"));

    /* Truncation is off under NOTRUNC, for both shapes. */
    {
        JanetBuffer *whole = janet_buffer(4096);
        pretty_width(whole, 99, JANET_PRETTY_ONELINE | JANET_PRETTY_NOTRUNC,
                     eval("(tabseq [i :range [0 31]] i i)"));
        assert(!buffer_contains(whole, "..."));
    }
}

/* Keys are sorted, so a table prints the same way twice however it was built.
 * Above the key-sort limit the sort is abandoned and storage order is used
 * instead — which is still deterministic for one table, so what the boundary
 * changes is whether *two* tables with the same contents print alike. */
static void test_keys_are_sorted_below_the_limit(void) {
    JanetBuffer *forward = janet_buffer(1024);
    JanetBuffer *backward = janet_buffer(1024);

    pretty_width(forward, 99, JANET_PRETTY_ONELINE | JANET_PRETTY_NOTRUNC,
                 eval("(tabseq [i :range [0 40]] i i)"));
    pretty_width(backward, 99, JANET_PRETTY_ONELINE | JANET_PRETTY_NOTRUNC,
                 eval("(let [t @{}] (var i 39) (while (>= i 0) (put t i i) (-- i)) t)"));

    assert(forward->count == backward->count);
    assert(memcmp(forward->data, backward->data, (size_t) forward->count) == 0);
    /* Sorted, so the first entry is the smallest key. */
    assert(memcmp(forward->data, "@{0 0 ", 6) == 0);
}

/* Nested dictionaries share one key-sort scratch allocation, each level taking
 * the slice above the level below it and putting the cursor back on the way
 * out. A level that forgot to restore the cursor would grow the scratch
 * without bound and mis-index the level above it. */
static void test_nested_dictionaries_share_the_key_sort_scratch(void) {
    JanetBuffer *b = janet_buffer(4096);
    pretty_width(b, 99, JANET_PRETTY_ONELINE, eval(
        "{:a {:x 1 :y 2 :z 3} :b {:x 4 :y 5 :z 6} :c {:x 7 :y 8 :z 9}}"));
    check_buffer(b, "{:a {:x 1 :y 2 :z 3} :b {:x 4 :y 5 :z 6} :c {:x 7 :y 8 :z 9}}");
}

/* ---------------------------------------------------------------- depth */

/* The depth limit elides rather than recursing, and it is counted per level of
 * nesting rather than per value. */
static void test_the_depth_limit(void) {
    JanetBuffer *b = janet_buffer(64);
    Janet argv[1];
    /* The depth is the precision, which is where every real caller puts it. */
    argv[0] = eval("[1 [2 [3 [4]]]]");
    janet_buffer_format(b, "%.2q", -1, 1, argv);
    check_buffer(b, "(1 (...))");
}

/* -------------------------------------------------------------- the JDN */

/* JDN and the pretty printer disagree on which values exist. Everything JDN
 * can write reads back as itself, so a function, a fiber or a keyword that
 * would not lex has no form and the writer fails rather than inventing one. */
static void test_what_jdn_refuses(void) {
    JanetBuffer *b = janet_buffer(64);

    /* One key, because JDN walks a dictionary in storage order rather than
     * sorted order and two would pin the hash layout rather than the writer. */
    janet_jdn(b, JANET_RECURSION_GUARD, eval("{:a [1 @[2 \"x\"] 1.5]}"));
    check_buffer(b, "{:a (1 @[2 \"x\"] 1.5)}");

    EXPECT_PANIC(janet_jdn(janet_buffer(16), JANET_RECURSION_GUARD, eval("print")),
                 "could not print to jdn format");

    /* A keyword whose text would not read back as a keyword. */
    EXPECT_PANIC(janet_jdn(janet_buffer(16), JANET_RECURSION_GUARD, eval("(keyword \"a b\")")),
                 "could not print to jdn format");

    /* Neither infinity nor NaN has a JDN spelling. */
    EXPECT_PANIC(janet_jdn(janet_buffer(16), JANET_RECURSION_GUARD, eval("math/inf")),
                 "could not print to jdn format");
}

/* A symbol may not start with a digit and a keyword may. The `issym` flag is
 * the only thing that separates the two, and swapping it is invisible unless
 * both are tried. */
static void test_jdn_treats_symbols_and_keywords_differently(void) {
    JanetBuffer *b = janet_buffer(64);
    janet_jdn(b, JANET_RECURSION_GUARD, eval("(keyword \"1abc\")"));
    check_buffer(b, ":1abc");

    {
        JanetTryState state;
        janet_try_init(&state);
        janet_contract_arm();
        janet_jdn(janet_buffer(16), JANET_RECURSION_GUARD, eval("(symbol \"1abc\")"));
        int raised = janet_contract_raised();
        janet_restore(&state);
        assert(raised && "a symbol starting with a digit has no jdn form");
    }
}

/* ------------------------------------------------------------------- main */

void pp_pretty_contract(void) {
    janet_init();
    test_env = janet_core_env(NULL);
    janet_gcroot(janet_wrap_table(test_env));

    test_a_null_buffer_is_allocated();
    test_the_barrier_protects_earlier_text();
    test_the_width_decides_the_wrapping();
    test_one_line_never_wraps();
    test_nesting_blocks_the_reflow();
    test_colour_costs_no_columns();
    test_a_two_digit_cycle_id();
    test_a_repeat_that_is_not_a_cycle();
    test_the_array_truncation_boundary();
    test_the_dictionary_truncation_boundary();
    test_keys_are_sorted_below_the_limit();
    test_nested_dictionaries_share_the_key_sort_scratch();
    test_the_depth_limit();
    test_what_jdn_refuses();
    test_jdn_treats_symbols_and_keywords_differently();

    assert(panics_fired == EXPECTED_PANICS);

    janet_deinit();
    printf("pp pretty contract ok\n");
}
