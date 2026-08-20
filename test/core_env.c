/* Behavioral contract for the core environment, run against whichever
 * implementation the build selected (`-Dcore-env=c` or the Zig default).
 *
 * `test/suite-corelib.janet` covers the cfunctions, because every one of them
 * has a Janet spelling. What it cannot reach is everything around them:
 *
 *  - `janet_core_env`'s `replacements` parameter has no Janet spelling at all.
 *    Nothing in the tree passes it a non-NULL table, so the substitution it
 *    performs -- and the memoization that makes it a one-shot -- are C-only.
 *  - `janet_core_lookup_table` is the same table without the unmarshal, and is
 *    reached from `marsh.c` with a NULL argument and from nowhere else.
 *  - `janet_dobytes` reports a *set of flags* and a value. Janet code sees
 *    neither: `dofile` and the REPL go through `janet_dostring`, which drops
 *    the distinction, and the diagnostics go to stderr rather than to a value.
 *    The `len` parameter has no Janet spelling either -- `janet_dostring`
 *    computes it -- so a stream that stops mid-source is only reachable here.
 *  - `janet_loop_fiber` is called by `shell.c` and by no Janet code.
 *  - `janet_native` is behind `(native ...)`, which needs a shared object on
 *    disk to say anything at all. Its failure paths do not.
 *
 * The diagnostics are captured rather than printed. `janet_dynprintf` resolves
 * `:err` before falling back to the handle, and at the top level -- which is
 * where `janet_dobytes` prints its diagnostics from, after the fiber has
 * finished -- that lookup goes to `janet_vm.top_dyns`. So binding `:err` to a
 * buffer here both asserts the text and keeps this program's output clean.
 */

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "features.h"
#include <janet.h>

#include "support.h"
#include "state.h"
#include "util.h"

static JanetTable *test_env;
static JanetBuffer *errsink;

static int panics_fired = 0;
#define EXPECTED_PANICS 1

#define EXPECT_PANIC(expr) do { \
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
    panics_fired++; \
} while (0)

/* ------------------------------------------------------- captured stderr */

static void err_reset(void) {
    errsink->count = 0;
}

/* NUL-terminate without counting the terminator, so the buffer stays usable. */
static const char *err_text(void) {
    janet_buffer_push_u8(errsink, 0);
    errsink->count--;
    return (const char *) errsink->data;
}

static void expect_err(const char *expected) {
    const char *got = err_text();
    if (strcmp(got, expected)) {
        printf("expected stderr: %s\n            got: %s\n", expected, got);
        assert(0 && "diagnostic mismatch");
    }
}

static void expect_err_prefix(const char *prefix) {
    const char *got = err_text();
    if (strncmp(got, prefix, strlen(prefix))) {
        printf("expected stderr prefix: %s\n                   got: %s\n", prefix, got);
        assert(0 && "diagnostic prefix mismatch");
    }
}

static void expect_string(Janet x, const char *expected) {
    assert(janet_checktype(x, JANET_STRING));
    if (janet_cstrcmp(janet_unwrap_string(x), expected)) {
        printf("expected value: %s\n           got: %s\n", expected,
               (const char *) janet_unwrap_string(x));
        assert(0 && "value mismatch");
    }
}

/* ----------------------------------------------------- the replacement cfun
 *
 * `gcinterval` is the substitution target because nothing in `boot.janet`
 * calls it while the image is loading, so replacing it cannot affect anything
 * but the one call this file makes. */

static Janet replaced_gcinterval(int32_t argc, Janet *argv) {
    (void) argc;
    (void) argv;
    return janet_ckeywordv("replaced");
}

/* ---------------------------------------------------------- the flag words */

static void test_a_clean_run_reports_no_flags(void) {
    Janet out = janet_wrap_true();
    err_reset();
    int flags = janet_dostring(test_env, "(+ 1 2)", "contract", &out);
    assert(flags == 0);
    assert(janet_checktype(out, JANET_NUMBER));
    assert(janet_unwrap_number(out) == 3.0);
    expect_err("");

    /* The value is the last form's, not the first's. */
    flags = janet_dostring(test_env, "(+ 1 2) (+ 3 4)", "contract", &out);
    assert(flags == 0);
    assert(janet_unwrap_number(out) == 7.0);

    /* An empty source runs nothing and answers nil. */
    flags = janet_dostring(test_env, "", "contract", &out);
    assert(flags == 0);
    assert(janet_checktype(out, JANET_NIL));

    /* The out parameter is optional. */
    flags = janet_dostring(test_env, "(+ 1 2)", "contract", NULL);
    assert(flags == 0);
    expect_err("");
}

static void test_the_length_parameter_truncates_the_source(void) {
    Janet out = janet_wrap_nil();
    err_reset();
    /* Seven bytes is exactly the first form; the second is never seen. */
    int flags = janet_dobytes(test_env, (const uint8_t *) "(+ 1 2) (+ 3 4)", 7, "contract", &out);
    assert(flags == 0);
    assert(janet_unwrap_number(out) == 3.0);
    expect_err("");

    /* Cutting a form in half is an EOF in the middle of it, which is a parse
     * error rather than a silent truncation. */
    flags = janet_dobytes(test_env, (const uint8_t *) "(+ 1 2)", 5, "contract", &out);
    assert(flags == JANET_DO_ERROR_PARSE);

    /* The bound is exclusive. `janet_dostring` always passes a length that
     * stops on a NUL, so only a caller of `janet_dobytes` can tell an
     * off-by-one here from correct behaviour: reading one byte too many turns
     * 1 into 12. */
    flags = janet_dobytes(test_env, (const uint8_t *) "12", 1, "contract", &out);
    assert(flags == 0);
    assert(janet_unwrap_number(out) == 1.0);
}

/* Every failure sets `done`, whatever kind it was. The runtime case is below;
 * these are the other two, and each needs a second form after the failing one
 * to have anything to observe. */
static void test_a_parse_or_compile_failure_stops_the_stream(void) {
    Janet out = janet_wrap_nil();
    JanetTable *env = janet_table(4);
    env->proto = test_env;

    err_reset();
    int flags = janet_dostring(env, ")\n(setdyn :contract-parse true)", "contract", &out);
    assert(flags == JANET_DO_ERROR_PARSE);
    assert(janet_checktype(janet_table_get(env, janet_ckeywordv("contract-parse")), JANET_NIL));

    err_reset();
    flags = janet_dostring(env, "(def)\n(setdyn :contract-compile true)", "contract", &out);
    assert(flags == JANET_DO_ERROR_COMPILE);
    assert(janet_checktype(janet_table_get(env, janet_ckeywordv("contract-compile")), JANET_NIL));
}

/* A compile error reports the *form's* position when the compiler supplies one
 * and the parser's otherwise, and the two only differ once the source has more
 * than one line in it. */
static void test_a_compile_error_prefers_the_source_mapping(void) {
    Janet out = janet_wrap_nil();
    err_reset();
    /* The parser has consumed three lines by the time the second form fails,
     * so a position of 2 can only have come from the source mapping. */
    int flags = janet_dostring(test_env, "(+ 1 2)\n(def)\n", "contract", &out);
    assert(flags == JANET_DO_ERROR_COMPILE);
    expect_err_prefix("contract:2:1: compile error: ");
}

static void test_a_parse_error_names_a_position(void) {
    Janet out = janet_wrap_nil();
    err_reset();
    int flags = janet_dostring(test_env, "(+ 1 2))", "contract", &out);
    assert(flags == JANET_DO_ERROR_PARSE);
    expect_string(out, "contract:1:8: parse error: unexpected closing delimiter )");
    expect_err("contract:1:8: parse error: unexpected closing delimiter )\n");
}

static void test_a_compile_error_names_a_position(void) {
    Janet out = janet_wrap_nil();
    err_reset();
    int flags = janet_dostring(test_env, "(def)", "contract", &out);
    assert(flags == JANET_DO_ERROR_COMPILE);
    assert(janet_checktype(out, JANET_STRING));
    {
        const char *text = (const char *) janet_unwrap_string(out);
        assert(!strncmp(text, "contract:1:1: compile error: ", 28));
    }
    expect_err_prefix("contract:1:1: compile error: ");
}

/* A macro that raises during expansion leaves a fiber behind, and that branch
 * prints the context *without* a newline and follows it with a stack trace,
 * where the ordinary branch prints the whole message with one. */
static void test_a_macro_expansion_error_prints_a_trace(void) {
    Janet out = janet_wrap_nil();
    err_reset();
    int flags = janet_dostring(test_env,
                               "(defmacro contract-boom [] (error :expansion)) (contract-boom)",
                               "contract", &out);
    assert(flags == JANET_DO_ERROR_COMPILE);
    /* The context is printed with `%s` and no separator, so it runs straight
     * into the first line of the trace. `FOUND.md` records that; it is pinned
     * here because it is the whole difference between this branch and the
     * ordinary one. */
    expect_err_prefix("contract:1:48: compile errorerror: contract:1:48: compile error: ");
    assert(strstr(err_text(), "expansion") != NULL);
    assert(strstr(err_text(), "\n  in contract-boom ") != NULL);
}

static void test_a_runtime_error_reports_the_value(void) {
    Janet out = janet_wrap_nil();
    err_reset();
    int flags = janet_dostring(test_env, "(error :thrown)", "contract", &out);
    assert(flags == JANET_DO_ERROR_RUNTIME);
    assert(janet_checktype(out, JANET_KEYWORD));
    assert(!janet_cstrcmp(janet_unwrap_keyword(out), "thrown"));
    expect_err_prefix("error: thrown\n  in thunk [contract] ");
}

/* Every failure sets `done`, so the flag word only ever holds one bit and the
 * forms after the failing one never run. */
static void test_a_failure_stops_the_stream(void) {
    Janet out = janet_wrap_nil();
    err_reset();
    JanetTable *env = janet_table(4);
    env->proto = test_env;
    int flags = janet_dostring(env, "(error :stop) (setdyn :contract-ran true)", "contract", &out);
    assert(flags == JANET_DO_ERROR_RUNTIME);
    assert(flags == (flags & -flags) && "more than one error flag was set");
    assert(janet_checktype(janet_table_get(env, janet_ckeywordv("contract-ran")), JANET_NIL));
}

static void test_a_null_source_path_is_named_unknown(void) {
    Janet out = janet_wrap_nil();
    err_reset();
    int flags = janet_dostring(test_env, "(+ 1 2))", NULL, &out);
    assert(flags == JANET_DO_ERROR_PARSE);
    expect_string(out, "<unknown>:1:8: parse error: unexpected closing delimiter )");
}

/* --------------------------------------------------------- janet_loop_fiber */

static void test_loop_fiber_reports_a_status(void) {
    Janet out = janet_wrap_nil();
    err_reset();
    assert(janet_dostring(test_env, "(fiber/new (fn [] 42))", "contract", &out) == 0);
    assert(janet_checktype(out, JANET_FIBER));
    assert(janet_loop_fiber(janet_unwrap_fiber(out)) == JANET_STATUS_DEAD);

    assert(janet_dostring(test_env, "(fiber/new (fn [] (error :in-fiber)))", "contract", &out) == 0);
    err_reset();
    assert(janet_loop_fiber(janet_unwrap_fiber(out)) == JANET_STATUS_ERROR);
}

/* ---------------------------------------------------------- the lookup table */

static void test_the_lookup_table_is_keyed_by_symbol(void) {
    JanetTable *dict = janet_core_lookup_table(NULL);
    Janet found = janet_table_get(dict, janet_csymbolv("gcinterval"));
    assert(janet_checktype(found, JANET_CFUNCTION));
    /* A keyword of the same name is not the key. */
    assert(janet_checktype(janet_table_get(dict, janet_ckeywordv("gcinterval")), JANET_NIL));
    /* Every `janet_lib_*` the configuration has is in it, not only corelib's. */
    assert(janet_checktype(janet_table_get(dict, janet_csymbolv("string/slice")), JANET_CFUNCTION));
    assert(janet_checktype(janet_table_get(dict, janet_csymbolv("marshal")), JANET_CFUNCTION));
#ifdef JANET_PEG
    assert(janet_checktype(janet_table_get(dict, janet_csymbolv("peg/match")), JANET_CFUNCTION));
#endif
}

static void test_the_lookup_table_takes_replacements(void) {
    JanetTable *replacements = janet_table(2);
    janet_table_put(replacements, janet_csymbolv("gcinterval"),
                    janet_wrap_cfunction(janet_contract_cfunction(replaced_gcinterval)));
    janet_table_put(replacements, janet_csymbolv("contract/added"),
                    janet_ckeywordv("added"));
    JanetTable *dict = janet_core_lookup_table(replacements);
    assert(janet_unwrap_cfunction(janet_table_get(dict, janet_csymbolv("gcinterval")))
           == janet_contract_cfunction(replaced_gcinterval));
    /* A key the core does not define is added rather than rejected. */
    assert(janet_checktype(janet_table_get(dict, janet_csymbolv("contract/added")), JANET_KEYWORD));
    /* A nil-keyed slot in the replacement table's storage is skipped, which is
     * what the walk over `capacity` rather than `count` is for. */
    assert(dict->count > replacements->count);
}

/* ------------------------------------------------------------------ getline
 *
 * `(getline)` reads through `(dyn :in)` and writes its prompt through
 * `(dyn :out)`, both of which `janet_dynfile` resolves and both of which fall
 * back to the process handles. The Janet suites cannot bind either without a
 * file to bind it to, and cannot assert what was read without controlling what
 * is on the other end, so the whole cfunction is exercised here.
 */

static void test_getline_reads_a_line_through_the_dyn(void) {
    /* Two handles, not one. Interleaving reads and writes on a single `FILE *`
     * without a seek between them is undefined, and `(getline)` does exactly
     * that when `:in` and `:out` name the same file. */
    FILE *in = tmpfile();
    FILE *out = tmpfile();
    assert(in != NULL && out != NULL);
    fputs("first line\nsecond", in);
    fflush(in);
    rewind(in);

    Janet in_handle = janet_makefile(in, JANET_FILE_READ | JANET_FILE_WRITE);
    Janet out_handle = janet_makefile(out, JANET_FILE_WRITE);
    janet_gcroot(in_handle);
    janet_gcroot(out_handle);
    /* Into the environment table rather than through `janet_setdyn`. A dynamic
     * binding is fiber-local, `janet_dobytes` gives each form a fiber whose env
     * is this table, and `janet_setdyn` at the top level -- where there is no
     * fiber -- writes to `janet_vm.top_dyns` instead, which the cfunction never
     * looks at. That split is why `:err` above is set the other way: those
     * diagnostics are printed after the fiber has finished. */
    janet_table_put(test_env, janet_ckeywordv("in"), in_handle);
    janet_table_put(test_env, janet_ckeywordv("out"), out_handle);

    Janet result = janet_wrap_nil();
    /* The newline is part of what is returned. */
    assert(janet_dostring(test_env, "(getline)", "contract", &result) == 0);
    assert(janet_checktype(result, JANET_BUFFER));
    {
        JanetBuffer *b = janet_unwrap_buffer(result);
        assert(b->count == 11 && !memcmp(b->data, "first line\n", 11));
    }

    /* A supplied buffer is reused -- the same object comes back, not a copy --
     * and its previous contents are dropped. The last line has no newline, so
     * this also covers the EOF exit. */
    assert(janet_dostring(test_env,
                          "(let [b @\"seed\"] [(= b (getline \"P>\" b)) b])",
                          "contract", &result) == 0);
    {
        const Janet *pair = janet_unwrap_tuple(result);
        JanetBuffer *b = janet_unwrap_buffer(pair[1]);
        assert(janet_truthy(pair[0]) && "getline must return the buffer it was given");
        assert(b->count == 6 && !memcmp(b->data, "second", 6));
    }

    /* At EOF it answers an empty buffer rather than failing. */
    assert(janet_dostring(test_env, "(getline)", "contract", &result) == 0);
    assert(janet_unwrap_buffer(result)->count == 0);

    /* A one-argument call writes its prompt too: the prompt is guarded by
     * `argc >= 1` and the buffer by `argc >= 2`, and only a call with exactly
     * one argument tells the two guards apart. */
    assert(janet_dostring(test_env, "(getline \"Q>\")", "contract", &result) == 0);
    assert(janet_checktype(result, JANET_BUFFER));

    /* Both prompts went to `(dyn :out)`, in order, and nothing else did. */
    fflush(out);
    rewind(out);
    {
        char written[8] = {0};
        assert(fread(written, 1, sizeof(written) - 1, out) == 4);
        assert(!strcmp(written, "P>Q>"));
    }

    /* A zero byte is data, not a terminator: the read stops at a newline or at
     * end of file and at nothing else. */
    {
        FILE *nul = tmpfile();
        assert(nul != NULL);
        fwrite("a\0b\n", 1, 4, nul);
        fflush(nul);
        rewind(nul);
        Janet nul_handle = janet_makefile(nul, JANET_FILE_READ | JANET_FILE_WRITE);
        janet_gcroot(nul_handle);
        janet_table_put(test_env, janet_ckeywordv("in"), nul_handle);
        assert(janet_dostring(test_env, "(getline)", "contract", &result) == 0);
        {
            JanetBuffer *b = janet_unwrap_buffer(result);
            assert(b->count == 4 && !memcmp(b->data, "a\0b\n", 4));
        }
        janet_table_put(test_env, janet_ckeywordv("in"), in_handle);
        janet_gcunroot(nul_handle);
    }

    /* The documented third parameter is accepted and ignored: `getline` never
     * looks at `argv[2]`. `FOUND.md` has it. */
    rewind(in);
    assert(janet_dostring(test_env, "(getline \"\" @\"\" :not-a-table)", "contract", &result) == 0);
    assert(janet_unwrap_buffer(result)->count == 11);
    /* A fourth is a plain arity error. */
    err_reset();
    assert(janet_dostring(test_env, "(getline \"\" @\"\" :a :b)", "contract", &result)
           == JANET_DO_ERROR_RUNTIME);

    janet_table_put(test_env, janet_ckeywordv("in"), janet_wrap_nil());
    janet_table_put(test_env, janet_ckeywordv("out"), janet_wrap_nil());
    janet_gcunroot(in_handle);
    janet_gcunroot(out_handle);
}

/* ------------------------------------------------------------ janet_native */

static void test_native_reports_a_loader_error(void) {
    JanetString err = NULL;
    JanetModule init = janet_native("./contract-no-such-module.so", &err);
    assert(init == NULL);
    assert(err != NULL);
    assert(janet_string_length(err) > 0);
}

/* ------------------------------------------------------------------ sandbox
 *
 * Every capability `(sandbox ...)` applies is permanent for the VM, so this
 * runs last and the suites cannot run it at all. What it pins is that the
 * argument walk visits every argument and accumulates a flag per capability,
 * which is invisible from Janet: there is no way to read the flag word back.
 */

static void test_sandbox_accumulates_every_capability(void) {
    Janet out = janet_wrap_nil();
    assert((janet_vm.sandbox_flags & JANET_SANDBOX_HRTIME) == 0);
    assert((janet_vm.sandbox_flags & JANET_SANDBOX_THREADS) == 0);

    /* No arguments changes nothing. */
    uint32_t before = janet_vm.sandbox_flags;
    assert(janet_dostring(test_env, "(sandbox)", "contract", &out) == 0);
    assert(janet_vm.sandbox_flags == before);

    /* Two capabilities in one call set two bits, which is what the walk over
     * `argc` is for; a repeat is idempotent. */
    assert(janet_dostring(test_env, "(sandbox :hrtime :threads :hrtime)", "contract", &out) == 0);
    assert(janet_vm.sandbox_flags & JANET_SANDBOX_HRTIME);
    assert(janet_vm.sandbox_flags & JANET_SANDBOX_THREADS);

    /* An unknown capability rejects the whole call, including the ones before
     * it in the same argument list. */
    before = janet_vm.sandbox_flags;
    assert(janet_dostring(test_env, "(sandbox :env :nope)", "contract", &out)
           == JANET_DO_ERROR_RUNTIME);
    assert(janet_vm.sandbox_flags == before);
    assert((janet_vm.sandbox_flags & JANET_SANDBOX_ENV) == 0);
}

/* Irreversible, so it goes last. */
static void test_native_is_behind_the_sandbox(void) {
    JanetString err = NULL;
    janet_sandbox(JANET_SANDBOX_DYNAMIC_MODULES);
    EXPECT_PANIC(janet_native("./contract-no-such-module.so", &err));
}

/* ------------------------------------------------------------------- main */

void core_env_contract(void) {
    janet_init();

    /* `janet_core_env` memoizes into `janet_vm.core_env`, so the replacement
     * table has to arrive on the very first call or it is ignored. That
     * one-shot is itself the contract below. */
    JanetTable *replacements = janet_table(2);
    janet_table_put(replacements, janet_csymbolv("gcinterval"),
                    janet_wrap_cfunction(janet_contract_cfunction(replaced_gcinterval)));
    test_env = janet_core_env(replacements);
    janet_gcroot(janet_wrap_table(test_env));

    errsink = janet_buffer(256);
    janet_gcroot(janet_wrap_buffer(errsink));
    janet_setdyn("err", janet_wrap_buffer(errsink));

    /* The substitution reached the unmarshalled environment: the image refers
     * to a core cfunction by name through the lookup table, so replacing the
     * name replaces the binding. */
    {
        Janet out = janet_wrap_nil();
        assert(janet_dostring(test_env, "(gcinterval)", "contract", &out) == 0);
        assert(janet_checktype(out, JANET_KEYWORD));
        assert(!janet_cstrcmp(janet_unwrap_keyword(out), "replaced"));
    }

    /* And the second call ignores both its argument and the work. */
    {
        JanetTable *again = janet_table(1);
        janet_table_put(again, janet_csymbolv("gcinterval"), janet_wrap_nil());
        assert(janet_core_env(again) == test_env);
        assert(janet_core_env(NULL) == test_env);
    }

    test_a_clean_run_reports_no_flags();
    test_the_length_parameter_truncates_the_source();
    test_a_parse_or_compile_failure_stops_the_stream();
    test_a_compile_error_prefers_the_source_mapping();
    test_a_parse_error_names_a_position();
    test_a_compile_error_names_a_position();
    test_a_macro_expansion_error_prints_a_trace();
    test_a_runtime_error_reports_the_value();
    test_a_failure_stops_the_stream();
    test_a_null_source_path_is_named_unknown();
    test_loop_fiber_reports_a_status();
    test_the_lookup_table_is_keyed_by_symbol();
    test_the_lookup_table_takes_replacements();
    test_getline_reads_a_line_through_the_dyn();
    test_native_reports_a_loader_error();
    test_sandbox_accumulates_every_capability();
    test_native_is_behind_the_sandbox();

    assert(panics_fired == EXPECTED_PANICS);

    janet_deinit();
    printf("core env contract ok\n");
}
