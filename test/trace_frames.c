/* Behavioral contract for stack frame decoding, run against whichever
 * implementation the build selected (`-Dtrace-frames=c` or the Zig default).
 *
 * What this file is guarding is a rendering. `janet_stacktrace_ext` prints the
 * trace every Janet user reads, and the decoding under test decides every part
 * of each line except the punctuation. The suites cover the two common shapes -
 * a named Janet function with a source map, and a registered cfunction - and
 * nothing else, because the remaining shapes need a funcdef or a registry entry
 * that the compiler and `janet_cfuns` never produce.
 *
 * So the cases are enumerated here rather than sampled, and the awkward one is
 * the point: the name and the location are classified separately, and an entry
 * that fails the name test can still pass the location test. Collapsing the two
 * is the mistake this file exists to catch.
 */

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "features.h"
#include <janet.h>
#include "fiber.h"
#include "state.h"
#include "util.h"

static JanetTable *test_env;

static JanetFunction *compile_function(const char *source) {
    Janet out = janet_wrap_nil();
    int status = janet_dostring(test_env, source, "trace-frames-test", &out);
    assert(status == 0);
    assert(janet_checktype(out, JANET_FUNCTION));
    janet_gcroot(out);
    return janet_unwrap_function(out);
}

/* The decoder reads three fields of a frame and nothing else, so a frame can be
 * a plain local rather than four slots carved out of a live fiber's stack. That
 * keeps every case below constructible, including the ones no fiber would ever
 * hold. */
static void frame_of_function(JanetStackFrame *frame, JanetFunction *func, int32_t pc_offset) {
    memset(frame, 0, sizeof(*frame));
    frame->func = func;
    frame->pc = pc_offset < 0 ? NULL : func->def->bytecode + pc_offset;
}

static void frame_of_cfunction(JanetStackFrame *frame, JanetCFunction cfun) {
    memset(frame, 0, sizeof(*frame));
    frame->func = NULL;
    frame->pc = (uint32_t *) cfun;
}

/* Two cfunctions used only as registry keys. They are never called; what
 * matters is that each is a distinct address the registry can be keyed on. */
static Janet probe_named(int32_t argc, Janet *argv) {
    (void) argc;
    (void) argv;
    return janet_wrap_nil();
}

static Janet probe_unnamed(int32_t argc, Janet *argv) {
    (void) argc;
    (void) argv;
    return janet_wrap_nil();
}

static Janet probe_unregistered(int32_t argc, Janet *argv) {
    (void) argc;
    (void) argv;
    return janet_wrap_nil();
}

/* -------------------------------------------------------- Janet functions */

/* A compiled function carries a name, a source, and a source map, which is the
 * shape behind almost every line of a real trace. A -Dsourcemaps=false build
 * has no source map to decode, and takes the bytecode-offset path below for
 * every Janet frame in the program instead. */
#ifndef JANET_NO_SOURCEMAPS
static void test_named_function_with_a_sourcemap(JanetFunction *named) {
    JanetStackFrame frame;
    JanetTraceFrame desc;

    assert(named->def->name != NULL);
    assert(named->def->sourcemap != NULL);

    frame_of_function(&frame, named, 0);
    janet_trace_frame(&frame, &desc);

    assert(desc.name_kind == JANET_TRACE_NAME_FUNCTION);
    assert(desc.name == (const char *) named->def->name);
    assert(desc.name_prefix == NULL);
    assert(desc.source == (const char *) named->def->source);
    assert(desc.loc_kind == JANET_TRACE_LOC_SOURCEMAP);
    assert(desc.line == named->def->sourcemap[0].line);
    assert(desc.column == named->def->sourcemap[0].column);
    assert(desc.tail == 0);

    /* The offset the program counter reports is an index into the bytecode,
     * not a byte offset, and it selects the mapping. */
    if (named->def->bytecode_length > 1) {
        frame_of_function(&frame, named, 1);
        janet_trace_frame(&frame, &desc);
        assert(desc.loc_kind == JANET_TRACE_LOC_SOURCEMAP);
        assert(desc.line == named->def->sourcemap[1].line);
        assert(desc.column == named->def->sourcemap[1].column);
    }
}
#endif /* JANET_NO_SOURCEMAPS */

/* A funcdef with no name renders as "<anonymous>", and the descriptor says so
 * by kind rather than by handing the caller that string - the caller owns the
 * wording. */
static void test_anonymous_function(JanetFunction *anonymous) {
    JanetStackFrame frame;
    JanetTraceFrame desc;

    assert(anonymous->def->name == NULL);

    frame_of_function(&frame, anonymous, 0);
    janet_trace_frame(&frame, &desc);

    assert(desc.name_kind == JANET_TRACE_NAME_ANONYMOUS);
    assert(desc.name == NULL);
    assert(desc.source == (const char *) anonymous->def->source);
}

/* Without a source map the location degrades to the raw bytecode offset. A
 * build compiled with -Dsourcemaps=false takes this path for every Janet frame
 * in the program, so it is not an exotic case. */
static void test_function_without_a_sourcemap(JanetFunction *named) {
    JanetStackFrame frame;
    JanetTraceFrame desc;
    JanetSourceMapping *saved = named->def->sourcemap;

    /* Already null in a -Dsourcemaps=false build; the assignment makes the
     * branch under test the same one in either configuration. */
    named->def->sourcemap = NULL;
    frame_of_function(&frame, named, 1);
    janet_trace_frame(&frame, &desc);
    named->def->sourcemap = saved;

    assert(desc.name_kind == JANET_TRACE_NAME_FUNCTION);
    assert(desc.loc_kind == JANET_TRACE_LOC_PC);
    assert(desc.pc == 1);
    assert(desc.line == 0);
    assert(desc.column == 0);
}

/* A function frame whose program counter is null reports no location at all -
 * not offset zero, and not the registry line a cfunction would report. The C
 * original arrives here by falling out of one branch into another that cannot
 * fire, which is exactly the kind of accident a rewrite tidies away. */
static void test_function_without_a_pc(JanetFunction *named) {
    JanetStackFrame frame;
    JanetTraceFrame desc;

    frame_of_function(&frame, named, -1);
    janet_trace_frame(&frame, &desc);

    assert(desc.name_kind == JANET_TRACE_NAME_FUNCTION);
    assert(desc.loc_kind == JANET_TRACE_LOC_NONE);
}

/* The tail-call marker is independent of everything else. */
static void test_tail_call_flag(JanetFunction *named) {
    JanetStackFrame frame;
    JanetTraceFrame desc;

    frame_of_function(&frame, named, 0);
    frame.flags |= JANET_STACKFRAME_TAILCALL;
    janet_trace_frame(&frame, &desc);
    assert(desc.tail == 1);
    assert(desc.name_kind == JANET_TRACE_NAME_FUNCTION);

    frame_of_cfunction(&frame, probe_named);
    frame.flags |= JANET_STACKFRAME_TAILCALL;
    janet_trace_frame(&frame, &desc);
    assert(desc.tail == 1);
}

/* -------------------------------------------------------------- cfunctions */

/* A registered cfunction reports its prefix, its name, its file, and its line.
 * This is every core function that appears in a trace. */
static void test_registered_cfunction(void) {
    JanetStackFrame frame;
    JanetTraceFrame desc;

    frame_of_cfunction(&frame, probe_named);
    janet_trace_frame(&frame, &desc);

    assert(desc.name_kind == JANET_TRACE_NAME_CFUNCTION);
    assert(!strcmp(desc.name, "probe"));
    assert(!strcmp(desc.name_prefix, "trace"));
    assert(!strcmp(desc.source, "trace_frames.c"));
    assert(desc.loc_kind == JANET_TRACE_LOC_CFUN_LINE);
    assert(desc.line == 41);
    assert(desc.pc == 0);
    assert(desc.column == 0);
}

/* A cfunction the registry has never heard of renders as a bare "<cfunction>"
 * with no source and no location. Reaching this from Janet needs a cfunction
 * installed without janet_cfuns, which nothing in the core does - and the
 * decoder must not dereference the null the registry returns. */
static void test_unregistered_cfunction(void) {
    JanetStackFrame frame;
    JanetTraceFrame desc;

    assert(janet_registry_get(probe_unregistered) == NULL);

    frame_of_cfunction(&frame, probe_unregistered);
    janet_trace_frame(&frame, &desc);

    assert(desc.name_kind == JANET_TRACE_NAME_CFUNCTION_BARE);
    assert(desc.name == NULL);
    assert(desc.name_prefix == NULL);
    assert(desc.source == NULL);
    assert(desc.loc_kind == JANET_TRACE_LOC_NONE);
}

/* The case the two-field descriptor exists for. A registry entry with no name
 * fails the name test and still passes the location test, so the frame renders
 * as "<cfunction> on line 99" - a bare name with a real location. One tag
 * covering both would have to choose, and either choice changes a line of
 * output that the C implementation prints today. */
static void test_registered_cfunction_without_a_name(void) {
    JanetStackFrame frame;
    JanetTraceFrame desc;
    JanetCFunRegistry *reg = janet_registry_get(probe_unnamed);

    assert(reg != NULL);
    assert(reg->name == NULL);
    assert(reg->source_line == 99);

    frame_of_cfunction(&frame, probe_unnamed);
    janet_trace_frame(&frame, &desc);

    assert(desc.name_kind == JANET_TRACE_NAME_CFUNCTION_BARE);
    assert(desc.name == NULL);
    /* Not reported, even though the entry has one: the C original prints a
     * source only in the branch that printed a name. */
    assert(desc.source == NULL);
    assert(desc.loc_kind == JANET_TRACE_LOC_CFUN_LINE);
    assert(desc.line == 99);
}

/* A registry entry whose source line is zero or negative reports no location.
 * janet_cfuns installs exactly this for every function registered without
 * source information. */
static void test_registered_cfunction_without_a_line(void) {
    JanetStackFrame frame;
    JanetTraceFrame desc;
    JanetCFunRegistry *reg = janet_registry_get(probe_named);
    int32_t saved = reg->source_line;

    reg->source_line = 0;
    frame_of_cfunction(&frame, probe_named);
    janet_trace_frame(&frame, &desc);
    assert(desc.name_kind == JANET_TRACE_NAME_CFUNCTION);
    assert(desc.loc_kind == JANET_TRACE_LOC_NONE);

    reg->source_line = -1;
    janet_trace_frame(&frame, &desc);
    assert(desc.loc_kind == JANET_TRACE_LOC_NONE);

    reg->source_line = saved;
}

/* A registered cfunction with no prefix reports a null prefix rather than an
 * empty string, because the caller branches on it to choose between "%s/%s"
 * and "%s". */
static void test_registered_cfunction_without_a_prefix(void) {
    JanetStackFrame frame;
    JanetTraceFrame desc;
    JanetCFunRegistry *reg = janet_registry_get(probe_named);
    const char *saved = reg->name_prefix;

    reg->name_prefix = NULL;
    frame_of_cfunction(&frame, probe_named);
    janet_trace_frame(&frame, &desc);
    assert(desc.name_kind == JANET_TRACE_NAME_CFUNCTION);
    assert(desc.name_prefix == NULL);
    assert(!strcmp(desc.name, "probe"));

    reg->name_prefix = saved;
}

/* Neither a function nor a cfunction: the frame contributes a bare "  in" line.
 * A cframe pushed with a null cfunction produces this, and janet_call pushes
 * one whenever it has to clear a dirty stack. */
static void test_empty_frame(void) {
    JanetStackFrame frame;
    JanetTraceFrame desc;

    frame_of_cfunction(&frame, NULL);
    janet_trace_frame(&frame, &desc);

    assert(desc.name_kind == JANET_TRACE_NAME_NONE);
    assert(desc.name == NULL);
    assert(desc.name_prefix == NULL);
    assert(desc.source == NULL);
    assert(desc.loc_kind == JANET_TRACE_LOC_NONE);
    assert(desc.tail == 0);
}

/* ---------------------------------------------------------- the whole trace */

/* The decoder is one half of a printer, so run the printer too. This does not
 * inspect the text - stderr belongs to the harness - but it does drive
 * janet_stacktrace_ext over a real fiber that has stopped at an error, which is
 * the only check here that the descriptor and the loop that consumes it agree
 * about the frames of a live stack. */
static void test_stacktrace_over_a_real_fiber(JanetFunction *failing) {
    JanetFiber *fiber = janet_fiber(failing, 32, 0, NULL);
    Janet out = janet_wrap_nil();
    JanetSignal sig;

    assert(fiber != NULL);
    janet_gcroot(janet_wrap_fiber(fiber));
    sig = janet_continue(fiber, janet_wrap_nil(), &out);
    assert(sig == JANET_SIGNAL_ERROR);
    janet_stacktrace_ext(fiber, out, "trace-frames-test");
    /* And with no prefix, which suppresses the error line entirely. */
    janet_stacktrace_ext(fiber, out, NULL);
    janet_gcunroot(janet_wrap_fiber(fiber));
}

/* ------------------------------------------------------------------- main */

int main(void) {
    JanetFunction *named;
    JanetFunction *anonymous;
    JanetFunction *failing;

    janet_init();
    test_env = janet_core_env(NULL);
    janet_gcroot(janet_wrap_table(test_env));

    /* The line numbers here are the contract's, not the file's: they are what
     * the registry reports back, and the tests above assert them literally. */
    janet_registry_put(probe_named, "probe", "trace", "trace_frames.c", 41);
    janet_registry_put(probe_unnamed, NULL, NULL, "unnamed.c", 99);

    named = compile_function("(defn traced-function [] nil) traced-function");
    anonymous = compile_function("(fn [] nil)");
    failing = compile_function("(fn [] (error \"from a fiber\"))");

#ifndef JANET_NO_SOURCEMAPS
    test_named_function_with_a_sourcemap(named);
#endif
    test_anonymous_function(anonymous);
    test_function_without_a_sourcemap(named);
    test_function_without_a_pc(named);
    test_tail_call_flag(named);

    test_registered_cfunction();
    test_unregistered_cfunction();
    test_registered_cfunction_without_a_name();
    test_registered_cfunction_without_a_line();
    test_registered_cfunction_without_a_prefix();
    test_empty_frame();

    test_stacktrace_over_a_real_fiber(failing);

    janet_deinit();
    printf("trace frames contract ok\n");
    return 0;
}
