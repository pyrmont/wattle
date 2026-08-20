/* Behavioral contract for rendering one Janet value as text, run against
 * whichever implementation the build selected (`-Dpp=c` or the Zig default).
 *
 * The reason this file exists rather than leaning on the Janet suites: from
 * Janet, `janet_to_string_b` and `janet_description_b` are only ever reached
 * through `string/format` and friends, which hand them a buffer that is either
 * empty or is not the value being printed. Both functions are documented to
 * *append*, both special-case a buffer printed into itself, and neither
 * property is observable through a cfunction that returns a fresh string.
 *
 * The escape width is the other subject. `janet_zig_pp_escape_string` returns
 * how many columns it wrote, the pretty printer's alignment is computed from
 * it, and nothing in the tree asserts it directly — a return value that was
 * consistently two too small would show up only as slightly wrong wrapping in
 * output no test compares.
 */

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "features.h"
#include <janet.h>

#include "support.h"
#include "util.h"

/* The seam `pp_pretty.zig` reaches this layer through. Declared here rather
 * than included, because it is deliberately in no header: it exists for one
 * caller in one other subsystem. */
int janet_zig_pp_escape_string(JanetBuffer *buffer, const uint8_t *str, int32_t len);

static JanetTable *test_env;

/* Assert that a buffer holds exactly `expected`, and say what it held if not. */
static void check_buffer(JanetBuffer *b, const char *expected) {
    size_t len = strlen(expected);
    if ((size_t) b->count != len || memcmp(b->data, expected, len) != 0) {
        printf("expected: %s\n     got: %.*s\n", expected, (int) b->count, (const char *) b->data);
        assert(0 && "buffer mismatch");
    }
}

static void check_string(JanetString s, const char *expected) {
    if (janet_cstrcmp(s, expected)) {
        printf("expected: %s\n     got: %s\n", expected, (const char *) s);
        assert(0 && "string mismatch");
    }
}

static Janet eval(const char *source) {
    Janet out = janet_wrap_nil();
    int status = janet_dostring(test_env, source, "pp-describe-test", &out);
    assert(status == 0);
    return out;
}

/* --------------------------------------------------------------- appending */

/* Both functions append. Every caller in the tree relies on it — `%v` in the
 * middle of a format string is the common case — and a version that reset the
 * buffer first would pass every Janet suite that formats a whole string at
 * once. */
static void test_both_append_rather_than_replace(void) {
    JanetBuffer *b = janet_buffer(16);

    janet_buffer_push_cstring(b, "head:");
    janet_to_string_b(b, janet_wrap_integer(7));
    janet_buffer_push_u8(b, '|');
    janet_description_b(b, janet_cstringv("x"));
    check_buffer(b, "head:7|\"x\"");

    /* And again, so that a second append after a first is covered too. */
    janet_to_string_b(b, janet_wrap_boolean(1));
    check_buffer(b, "head:7|\"x\"true");
}

/* A buffer printed into itself. `janet_to_string_b` reserves the extra length
 * before pushing and `janet_description_b` reserves five times it, because in
 * both cases the source of the bytes is the storage the push may reallocate.
 * Dropping either reservation is a use-after-free that a sanitizer build would
 * catch and an ordinary one would not. */
static void test_a_buffer_printed_into_itself(void) {
    JanetBuffer *b = janet_buffer(1);
    janet_buffer_push_cstring(b, "ab");
    janet_to_string_b(b, janet_wrap_buffer(b));
    check_buffer(b, "abab");

    {
        JanetBuffer *d = janet_buffer(1);
        janet_buffer_push_cstring(d, "a\nb");
        janet_description_b(d, janet_wrap_buffer(d));
        /* The '@' is pushed before the length is read, so it is escaped as
         * part of the contents. That is a defect and it is pinned here rather
         * than corrected: `FOUND.md` has it, and the pretty printer avoids it
         * by escaping `bufstartlen` bytes instead of `count`. */
        check_buffer(d, "a\nb@\"a\\nb@\"");
    }
}

/* ---------------------------------------------------------------- escaping */

/* Every escape the table has, in one string, plus the two boundaries of the
 * printable range. A missing case does not corrupt anything; it emits a raw
 * control byte, which reads as valid output until something parses it back. */
static void test_the_whole_escape_table(void) {
    static const uint8_t raw[] = {
        '"', '\n', '\r', 0, '\f', '\v', '\a', '\b', 27, '\\', '\t',
        31, 32, 126, 127, 255, 'z'
    };
    JanetBuffer *b = janet_buffer(64);
    int width = janet_zig_pp_escape_string(b, raw, (int32_t) sizeof(raw));

    check_buffer(b,
                 "\"\\\"\\n\\r\\0\\f\\v\\a\\b\\e\\\\\\t"
                 "\\x1F \x7E\\x7F\\xFFz\"");

    /* The width is the column count, which is the byte count here because
     * nothing written is multi-byte: two quotes, eleven two-byte escapes,
     * three four-byte escapes, and three bytes that escape to themselves. */
    assert(width == b->count);
    assert(width == 2 + 11 * 2 + 3 * 4 + 3);
}

/* A description escapes; a stringification does not. This is the whole
 * difference between the two entry points for the byte types, and the pair is
 * asserted together so that a change to one of them cannot look like a change
 * to both. */
static void test_description_escapes_where_to_string_does_not(void) {
    Janet s = janet_cstringv("a\"b");
    JanetBuffer *b = janet_buffer(16);

    janet_to_string_b(b, s);
    check_buffer(b, "a\"b");

    b->count = 0;
    janet_description_b(b, s);
    check_buffer(b, "\"a\\\"b\"");

    /* A keyword keeps its colon in a description and loses it in a string. */
    b->count = 0;
    janet_description_b(b, janet_ckeywordv("kw"));
    check_buffer(b, ":kw");
    b->count = 0;
    janet_to_string_b(b, janet_ckeywordv("kw"));
    check_buffer(b, "kw");
}

/* ----------------------------------------------------------------- numbers */

/* Three properties of the number path, none of which the suites pin: negative
 * zero prints without its sign, an integral value inside the exact range
 * prints with no fraction and no exponent, and one outside it falls back to
 * fifteen significant digits. */
static void test_numbers(void) {
    JanetBuffer *b = janet_buffer(32);

    janet_to_string_b(b, janet_wrap_number(-0.0));
    check_buffer(b, "0");

    b->count = 0;
    janet_to_string_b(b, janet_wrap_number(9007199254740992.0));
    check_buffer(b, "9007199254740992");

    /* One past the exactly-representable range: the integral shortcut must not
     * take it, because %.0f would print all of its digits as if they were
     * significant. */
    b->count = 0;
    janet_to_string_b(b, janet_wrap_number(9007199254740994.0));
    check_buffer(b, "9.00719925474099e+15");

    b->count = 0;
    janet_to_string_b(b, janet_wrap_number(1.5));
    check_buffer(b, "1.5");
}

/* ------------------------------------------------------- the two wrappers */

/* `janet_to_string` answers with the contents of a byte type and with a
 * rendering of everything else; `janet_description` renders in every case. The
 * three byte types take a path through neither renderer at all, which is why a
 * change there is invisible to a test that only checks the text. */
static void test_the_two_wrappers_differ_where_they_should(void) {
    Janet s = janet_cstringv("a\"b");
    Janet k = janet_ckeywordv("kw");
    Janet n = janet_wrap_integer(12);

    check_string(janet_to_string(s), "a\"b");
    check_string(janet_description(s), "\"a\\\"b\"");
    check_string(janet_to_string(k), "kw");
    check_string(janet_description(k), ":kw");
    check_string(janet_to_string(n), "12");
    check_string(janet_description(n), "12");

    /* A buffer answers with a copy of its contents rather than with itself. */
    {
        JanetBuffer *b = janet_buffer(4);
        janet_buffer_push_cstring(b, "raw");
        check_string(janet_to_string(janet_wrap_buffer(b)), "raw");
        check_string(janet_description(janet_wrap_buffer(b)), "@\"raw\"");
    }

    /* A symbol is returned as it stands, without a copy: the identity is the
     * point, since symbols are interned. */
    {
        Janet sym = janet_csymbolv("sym");
        assert(janet_to_string(sym) == janet_unwrap_symbol(sym));
    }
}

/* ------------------------------------------------------------- the callables */

/* A registered cfunction prints its registry name, with the prefix when it has
 * one. An unregistered one falls through to the pointer description, which is
 * the same `goto fallthrough` an anonymous function takes. */
static void test_cfunctions_and_functions(void) {
    JanetBuffer *b = janet_buffer(64);

    janet_description_b(b, eval("print"));
    check_buffer(b, "<cfunction print>");

    b->count = 0;
    janet_description_b(b, eval("string/format"));
    check_buffer(b, "<cfunction string/format>");

    /* A named function names itself; an anonymous one cannot, and prints as a
     * pointer instead. Only the shape of the second is asserted, since the
     * address is not reproducible. */
    b->count = 0;
    janet_description_b(b, eval("(fn named [] nil)"));
    check_buffer(b, "<function named>");

    b->count = 0;
    janet_description_b(b, eval("(fn [] nil)"));
    assert(b->count > 11);
    assert(memcmp(b->data, "<function 0x", 12) == 0);
    assert(b->data[b->count - 1] == '>');
}

/* A pointer description truncates the type name at 32 bytes, which keeps the
 * whole thing inside the fixed reservation made before writing it. Nothing in
 * Janet has a name that long, so the bound is never approached in practice and
 * would never be noticed if it were wrong. */
static void test_the_pointer_description_truncates_its_title(void) {
    static const JanetAbstractType long_name = {
        .name = "abstract/with-an-extremely-long-type-name-here"
    };
    void *p = janet_abstract(CONTRACT_AT(long_name), 8);
    JanetBuffer *b = janet_buffer(64);

    janet_description_b(b, janet_wrap_abstract(p));
    assert(b->data[0] == '<');
    assert(b->data[b->count - 1] == '>');
    /* '<' + exactly 32 title bytes + " 0x" + the digits + '>'. The name is
     * 45 bytes long, so the cut lands mid-word and that is the point. */
    assert(memcmp(b->data + 1, "abstract/with-an-extremely-long- 0x", 35) == 0);
}

/* An abstract type with a `tostring` callback is wrapped in angle brackets and
 * its own name by a description, and is *not* wrapped by a stringification.
 * The two spellings are easy to swap and the suites print only one of them. */
static void test_an_abstract_with_a_tostring(void) {
    Janet value = eval("(int/s64 -5)");
    JanetBuffer *b = janet_buffer(32);

    janet_to_string_b(b, value);
    check_buffer(b, "-5");

    b->count = 0;
    janet_description_b(b, value);
    check_buffer(b, "<core/s64 -5>");
}

/* ------------------------------------------------------------------- main */

void pp_describe_contract(void) {
    janet_init();
    test_env = janet_core_env(NULL);
    janet_gcroot(janet_wrap_table(test_env));

    test_both_append_rather_than_replace();
    test_a_buffer_printed_into_itself();
    test_the_whole_escape_table();
    test_description_escapes_where_to_string_does_not();
    test_numbers();
    test_the_two_wrappers_differ_where_they_should();
    test_cfunctions_and_functions();
    test_the_pointer_description_truncates_its_title();
#ifdef JANET_INT_TYPES
    test_an_abstract_with_a_tostring();
#endif

    janet_deinit();
    printf("pp describe contract ok\n");
}
