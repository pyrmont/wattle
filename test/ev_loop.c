/* Behavioral contract for the event loop, the scheduler, streams and channels,
 * run against whichever implementation the build selected (`-Dev-loop=c` or
 * the Zig default).
 *
 * ## What the Janet suites cannot reach
 *
 * `test/suite-ev.janet` has 742 assertions and every one of them goes through
 * the thirty `ev/` bindings. Six areas have no Janet spelling at all:
 *
 *  - **The embedder's channel API.** `janet_channel_make`,
 *    `janet_channel_give` and `janet_channel_take` are the non-blocking mode
 *    (`mode == 2`) of the push and pop, which `ev/give` and `ev/take` never
 *    select. Only the supervisor path inside the loop reaches it otherwise,
 *    and then only on a fiber that has already failed.
 *  - **`janet_stream_ext`.** Type-punning a stream -- a larger allocation and
 *    a caller-supplied method table -- is what `net.c` does and what no Janet
 *    program can ask for.
 *  - **`janet_make_pipe`'s four modes.** Janet reaches mode 1 through
 *    `os/spawn` and nothing else; the descriptor flags each mode sets are
 *    invisible from Janet even then.
 *  - **`janet_ev_default_threaded_callback`'s nine tags.** `ev/thread` uses
 *    two of them.
 *  - **The C face of every symbol this increment converted.** While both
 *    mechanisms are live an exported symbol raises by `longjmp` for its C
 *    callers and returns an error to its Zig ones, and Phase 10's acceptance
 *    list requires the two to be tested separately. The Janet suites exercise
 *    only the Zig face.
 *  - **The protected scope itself.** `janet_zig_ev_protect` was the one
 *    function left in `ev.c` and the second of the phase's three `setjmp`
 *    sites; the hinge deleted it, and `janet_contract_protect` in
 *    `test/support.zig` opens the same scope without a jump.
 *
 * ## What it deliberately does not do
 *
 * It does not drive the polling backend. `janet_loop1_impl` blocks until a
 * descriptor is ready or a timeout expires, and a contract that waits on the
 * kernel is a contract that hangs when it is wrong. What is checked instead is
 * everything either side of the poll: the loop's own exit condition, the
 * timer heap's ordering decisions, and the self-pipe round trip, which
 * `janet_loop1` performs without entering the backend at all.
 */

#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <janet.h>

#include "support.h"

#ifndef JANET_WINDOWS
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#endif

/* `src/core/util.h`, which is internal: declared rather than included so that
 * the contract depends only on the ABI it exercises. */
int janet_make_pipe(JanetHandle handles[2], int mode);

/* ------------------------------------------------------- the two faces */

/* Run `body` under a try scope and report the signal, so that a raise reaching
 * a C caller can be asserted on. This is the C face of every raise this
 * increment converted.
 *
 * It was `janet_zig_ev_protect`, which `ev.c` kept compiled under both arms of
 * the selector so that this file could name it. That function was the second
 * of the phase's three setjmp sites and went with the jump; the scope it
 * opened now comes from test/support.zig, which is where the test-only symbols
 * belong. */
static JanetSignal catching(void (*body)(void *), void *ctx, Janet *payload) {
    return janet_contract_protect(body, ctx, payload);
}

static int payload_is(Janet payload, const char *text) {
    if (!janet_checktype(payload, JANET_STRING)) return 0;
    JanetString s = janet_unwrap_string(payload);
    return janet_string_length(s) == (int32_t) strlen(text) &&
           0 == memcmp(s, text, strlen(text));
}

static void body_noop(void *ctx) {
    (void) ctx;
}

static void body_panic(void *ctx) {
    (void) ctx;
    janet_panic("contract panic");
}

static void test_protect_scope(void) {
    /* The success arm reports zero and leaves the payload alone. */
    Janet payload = janet_wrap_keyword(janet_ckeyword("untouched"));
    assert(0 == catching(body_noop, NULL, &payload));
    assert(janet_checktype(payload, JANET_KEYWORD));

    /* The failure arm reports the signal and publishes the payload. */
    assert(JANET_SIGNAL_ERROR == catching(body_panic, NULL, &payload));
    assert(payload_is(payload, "contract panic"));

    /* Scopes nest, and the inner one does not swallow the outer's state. */
    Janet inner = janet_wrap_nil();
    assert(0 == catching(body_noop, NULL, &inner));
    assert(JANET_SIGNAL_ERROR == catching(body_panic, NULL, &inner));
    assert(payload_is(inner, "contract panic"));
}

/* ------------------------------------------------------------- channels */

static void test_channel_embedder_api(void) {
    JanetChannel *chan = janet_channel_make(2);
    assert(chan != NULL);

    /* Nothing to take from an empty channel, and mode 2 registers no pending
     * read, so a second take behaves the same as the first. */
    Janet out = janet_wrap_keyword(janet_ckeyword("untouched"));
    assert(0 == janet_channel_take(chan, &out));
    assert(janet_checktype(out, JANET_KEYWORD));
    assert(0 == janet_channel_take(chan, &out));

    /* Two gives fit under the limit and report "do not block". */
    assert(0 == janet_channel_give(chan, janet_wrap_integer(1)));
    assert(0 == janet_channel_give(chan, janet_wrap_integer(2)));
    /* The third exceeds the limit; mode 2 declines to block and says so. */
    assert(1 == janet_channel_give(chan, janet_wrap_integer(3)));

    /* All three are queued, in order. */
    assert(1 == janet_channel_take(chan, &out));
    assert(janet_unwrap_integer(out) == 1);
    assert(1 == janet_channel_take(chan, &out));
    assert(janet_unwrap_integer(out) == 2);
    assert(1 == janet_channel_take(chan, &out));
    assert(janet_unwrap_integer(out) == 3);
    assert(0 == janet_channel_take(chan, &out));
}

static void test_channel_threaded_make(void) {
    /* A threaded channel is a threaded abstract, so it is not on this
     * thread's GC heap and takes its lock on every operation. */
    JanetChannel *chan = janet_channel_make_threaded(1);
    assert(chan != NULL);
    Janet out = janet_wrap_nil();
    assert(0 == janet_channel_give(chan, janet_wrap_integer(7)));
    assert(1 == janet_channel_take(chan, &out));
    assert(janet_unwrap_integer(out) == 7);
    /* Packing is what a threaded channel does that an ordinary one does not:
     * a value that is not one of the five self-contained types is marshalled
     * on the way in and unmarshalled on the way out. */
    assert(0 == janet_channel_give(chan, janet_cstringv("packed")));
    assert(1 == janet_channel_take(chan, &out));
    assert(payload_is(out, "packed"));
}

static void body_give_closed(void *ctx) {
    janet_channel_give((JanetChannel *) ctx, janet_wrap_integer(1));
}

static void test_channel_closed_c_face(void) {
    Janet chanv;
    assert(0 == janet_dostring(janet_core_env(NULL),
                               "(def c (ev/chan 4)) (ev/chan-close c) c",
                               "ev_loop", &chanv));
    JanetChannel *chan = janet_getchannel(&chanv, 0);
    assert(chan != NULL);

    /* Taking from a closed channel succeeds and yields nil. */
    Janet out = janet_wrap_integer(99);
    assert(1 == janet_channel_take(chan, &out));
    assert(janet_checktype(out, JANET_NIL));

    /* Giving to one raises, and for a C caller that is a jump. */
    Janet payload = janet_wrap_nil();
    assert(JANET_SIGNAL_ERROR == catching(body_give_closed, chan, &payload));
    assert(payload_is(payload, "cannot write to closed channel"));
}

static void test_channel_getters(void) {
    Janet argv[2];
    Janet chanv;
    assert(0 == janet_dostring(janet_core_env(NULL), "(ev/chan 3)", "ev_loop", &chanv));
    argv[0] = chanv;
    argv[1] = janet_wrap_nil();
    assert(janet_getchannel(argv, 0) == janet_getchannel(argv, 0));
    /* optchannel takes the default for a missing argument and for nil, and
     * the channel for anything else. */
    assert(janet_optchannel(argv, 1, 1, NULL) == NULL);
    assert(janet_optchannel(argv, 2, 1, NULL) == NULL);
    assert(janet_optchannel(argv, 2, 0, NULL) == janet_getchannel(argv, 0));
}

/* -------------------------------------------------------------- streams */

#ifdef JANET_WINDOWS
#define BAD_HANDLE INVALID_HANDLE_VALUE
#else
#define BAD_HANDLE (-1)
#endif

static Janet stream_probe_method(int32_t argc, Janet *argv) {
    (void) argc;
    (void) argv;
    return janet_ckeywordv("probe");
}

static const JanetMethod probe_methods[] = {
    {"probe", stream_probe_method},
    {NULL, NULL}
};

/* A stream with room for a payload after the header, which is what
 * `janet_stream_ext` exists for. */
typedef struct {
    JanetStream stream;
    uint64_t marker;
} ProbeStream;

static void test_stream_ext(void) {
    JanetHandle handles[2];
    assert(0 == janet_make_pipe(handles, 0));
    ProbeStream *ps = (ProbeStream *) janet_stream_ext(
                          handles[0], JANET_STREAM_READABLE, probe_methods, sizeof(ProbeStream));
    ps->marker = 0x0123456789ABCDEFull;

    JanetStream *s = &ps->stream;
    assert(s->handle == handles[0]);
    assert(s->flags == JANET_STREAM_READABLE);
    assert(s->read_fiber == NULL && s->write_fiber == NULL);
    assert(s->methods == probe_methods);

    /* The abstract's size is the caller's, not the header's. */
    assert(janet_abstract_size(ps) == sizeof(ProbeStream));

    /* The getter reaches the caller's table rather than the default one. */
    Janet out = janet_wrap_nil();
    Janet found = janet_wrap_nil();
    assert(1 == janet_contract_at_get(janet_abstract_type(ps), ps, janet_ckeywordv("probe"), &found));
    assert(janet_checktype(found, JANET_CFUNCTION));
    assert(0 == janet_contract_at_get(janet_abstract_type(ps), ps, janet_ckeywordv("close"), &out));
    /* `next` walks the same table. */
    assert(janet_keyeq(janet_contract_at_next(janet_abstract_type(ps), ps, janet_wrap_nil()), "probe"));
    assert(janet_checktype(janet_contract_at_next(janet_abstract_type(ps), ps, janet_ckeywordv("probe")), JANET_NIL));

    assert(ps->marker == 0x0123456789ABCDEFull);
    janet_stream_close(s);
    assert(s->flags & JANET_STREAM_CLOSED);
    assert(s->handle == BAD_HANDLE);
    /* Closing twice is a no-op rather than a double close. */
    janet_stream_close(s);
    assert(s->handle == BAD_HANDLE);
#ifndef JANET_WINDOWS
    close(handles[1]);
#endif
}

static void test_stream_default_methods(void) {
    JanetHandle handles[2];
    assert(0 == janet_make_pipe(handles, 0));
    JanetStream *s = janet_stream(handles[0], JANET_STREAM_READABLE, NULL);
    /* A null method table means the four default stream methods.
     *
     * Named through the core bindings rather than as C symbols. Phase 10 Part
     * 17g removed janet_cfun_stream_close and its three neighbours from
     * janet.h: a cfunction is no longer a C function, so a contract cannot
     * take one's address. What is asserted is unchanged and slightly stronger
     * -- the method table and the ev/ binding are the same function. */
    Janet out = janet_wrap_nil();
    static const char *const method_names[] = {"close", "read", "chunk", "write"};
    for (size_t i = 0; i < sizeof(method_names) / sizeof(method_names[0]); i++) {
        char binding[16];
        snprintf(binding, sizeof(binding), "ev/%s", method_names[i]);
        assert(1 == janet_contract_at_get(janet_abstract_type(s), s, janet_ckeywordv(method_names[i]), &out));
        assert(janet_checktype(out, JANET_CFUNCTION));
        assert(janet_unwrap_cfunction(out)
               == janet_unwrap_cfunction(janet_resolve_core(binding)));
    }
    /* A non-keyword key is not a method lookup. */
    assert(0 == janet_contract_at_get(janet_abstract_type(s), s, janet_wrap_integer(0), &out));
    janet_stream_close(s);
#ifndef JANET_WINDOWS
    close(handles[1]);
#endif
}

static void test_stream_tostring(void) {
    JanetHandle handles[2];
    assert(0 == janet_make_pipe(handles, 0));
    JanetStream *s = janet_stream(handles[0], JANET_STREAM_READABLE, NULL);
    JanetBuffer *buf = janet_buffer(16);
    janet_contract_at_tostring(janet_abstract_type(s), s, buf);
    char expected[32];
#ifdef JANET_WINDOWS
    snprintf(expected, sizeof(expected), "[fd=%d]", (int32_t)(intptr_t) handles[0]);
#else
    snprintf(expected, sizeof(expected), "[fd=%d]", (int) handles[0]);
#endif
    assert(buf->count == (int32_t) strlen(expected));
    assert(0 == memcmp(buf->data, expected, strlen(expected)));
    janet_stream_close(s);
#ifndef JANET_WINDOWS
    close(handles[1]);
#endif
}

typedef struct {
    JanetStream *stream;
    uint32_t flags;
} FlagCheck;

static void body_stream_flags(void *ctx) {
    FlagCheck *fc = ctx;
    janet_stream_flags(fc->stream, fc->flags);
}

static void test_stream_flags_messages(void) {
    JanetHandle handles[2];
    assert(0 == janet_make_pipe(handles, 0));
    JanetStream *s = janet_stream(handles[0],
                                  JANET_STREAM_READABLE | JANET_STREAM_SOCKET, NULL);
    FlagCheck fc;
    Janet payload = janet_wrap_nil();

    /* Every flag the caller asks for is present, so nothing is raised. */
    fc.stream = s;
    fc.flags = JANET_STREAM_READABLE;
    assert(0 == catching(body_stream_flags, &fc, &payload));
    fc.flags = JANET_STREAM_READABLE | JANET_STREAM_SOCKET;
    assert(0 == catching(body_stream_flags, &fc, &payload));

    /* The message names every flag that was *asked for*, in a fixed order,
     * and the last word is "socket" only when a socket was asked for. */
    fc.flags = JANET_STREAM_WRITABLE;
    assert(JANET_SIGNAL_ERROR == catching(body_stream_flags, &fc, &payload));
    assert(payload_is(payload, "bad stream, expected writable stream"));

    fc.flags = JANET_STREAM_READABLE | JANET_STREAM_WRITABLE |
               JANET_STREAM_ACCEPTABLE | JANET_STREAM_UDPSERVER | JANET_STREAM_SOCKET;
    assert(JANET_SIGNAL_ERROR == catching(body_stream_flags, &fc, &payload));
    assert(payload_is(payload,
                      "bad stream, expected readable writable server datagram socket"));

    /* A closed stream is refused before its flags are looked at. */
    janet_stream_close(s);
    fc.flags = JANET_STREAM_READABLE;
    assert(JANET_SIGNAL_ERROR == catching(body_stream_flags, &fc, &payload));
    assert(payload_is(payload, "stream is closed"));
#ifndef JANET_WINDOWS
    close(handles[1]);
#endif
}

static void test_stream_not_closeable(void) {
    JanetHandle handles[2];
    assert(0 == janet_make_pipe(handles, 0));
    JanetStream *s = janet_stream(handles[0],
                                  JANET_STREAM_READABLE | JANET_STREAM_NOT_CLOSEABLE, NULL);
    janet_stream_close(s);
    /* The handle is forgotten either way; what NOT_CLOSEABLE changes is that
     * the descriptor itself survives, which is why it is still usable here. */
    assert(s->flags & JANET_STREAM_CLOSED);
    assert(s->handle == BAD_HANDLE);
#ifndef JANET_WINDOWS
    char byte = 'x';
    assert(1 == write(handles[1], &byte, 1));
    assert(1 == read(handles[0], &byte, 1));
    close(handles[0]);
    close(handles[1]);
#endif
}

/* ---------------------------------------------------------------- pipes */

#ifndef JANET_WINDOWS
static int is_cloexec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    assert(flags != -1);
    return (flags & FD_CLOEXEC) ? 1 : 0;
}

static int is_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL);
    assert(flags != -1);
    return (flags & O_NONBLOCK) ? 1 : 0;
}

/* The four modes and exactly which descriptor gets which flag. The mode
 * numbers are what `os/spawn` and the self pipe pass, and nothing in Janet can
 * observe the result. */
static void test_make_pipe_modes(void) {
    static const int expect[4][4] = {
        /* mode  cloexec0 cloexec1 nonblock0 nonblock1 */
        /* 0 */ {1, 1, 1, 1},
        /* 1 */ {1, 0, 1, 0},
        /* 2 */ {0, 1, 0, 1},
        /* 3 */ {1, 1, 0, 0},
    };
    for (int mode = 0; mode < 4; mode++) {
        JanetHandle h[2];
        assert(0 == janet_make_pipe(h, mode));
        assert(is_cloexec(h[0]) == expect[mode][0]);
        assert(is_cloexec(h[1]) == expect[mode][1]);
        assert(is_nonblock(h[0]) == expect[mode][2]);
        assert(is_nonblock(h[1]) == expect[mode][3]);
        /* The two ends are a pipe rather than two unrelated descriptors. */
        char byte = (char)('a' + mode);
        char got = 0;
        assert(1 == write(h[1], &byte, 1));
        assert(1 == read(h[0], &got, 1));
        assert(got == byte);
        close(h[0]);
        close(h[1]);
    }
}

static void test_lasterr(void) {
    /* janet_ev_lasterr reads errno and renders it, with no side effect of its
     * own -- the same errno gives the same string twice. */
    errno = EBADF;
    Janet first = janet_ev_lasterr();
    Janet second = janet_ev_lasterr();
    assert(janet_checktype(first, JANET_STRING));
    assert(janet_equals(first, second));
    errno = EINVAL;
    assert(!janet_equals(first, janet_ev_lasterr()));
}
#endif

/* ------------------------------------------------- the loop's own state */

static void test_loop_done(void) {
    /* Nothing scheduled, no timers, no listeners. */
    assert(janet_loop_done());

    /* A listener is enough to keep the loop alive, and the count is a count
     * rather than a flag. */
    janet_ev_inc_refcount();
    assert(!janet_loop_done());
    janet_ev_inc_refcount();
    assert(!janet_loop_done());
    janet_ev_dec_refcount();
    assert(!janet_loop_done());
    janet_ev_dec_refcount();
    assert(janet_loop_done());
}

typedef struct {
    int calls;
    int tag;
    Janet value;
} PostRecord;

static PostRecord post_record;

static void post_callback(JanetEVGenericMessage msg) {
    post_record.calls++;
    post_record.tag = msg.tag;
    post_record.value = msg.argj;
}

/* The self pipe, end to end: posting an event raises the listener count, and
 * one turn of the loop delivers the callback and lowers it again. On Windows
 * the same round trip goes through the completion port instead. */
static void test_post_event_round_trip(void) {
    memset(&post_record, 0, sizeof(post_record));
    JanetEVGenericMessage msg;
    memset(&msg, 0, sizeof(msg));
    msg.tag = 41;
    msg.argj = janet_wrap_integer(42);

    assert(janet_loop_done());
    janet_ev_post_event(NULL, post_callback, msg);
    assert(!janet_loop_done());

    janet_loop();
    assert(post_record.calls == 1);
    assert(post_record.tag == 41);
    assert(janet_unwrap_integer(post_record.value) == 42);
    assert(janet_loop_done());
}

/* A null callback is what `janet_loop1_interrupt` posts, to wake a loop that
 * is blocked in the backend and do nothing else.
 *
 * **The reference it takes is never given back.** `janet_ev_post_event` raises
 * the listener count unconditionally, and the self-pipe handler lowers it only
 * inside `if (NULL != response.cb)`. So a null callback leaves the count one
 * higher for ever and `janet_loop_done` never reports done again. The Windows
 * completion port lowers it outside the test and does not have this. Both are
 * reproduced rather than repaired, and `FOUND.md` has the entry -- which is
 * why this drives one turn of the loop rather than calling `janet_loop`, and
 * why it puts the count back by hand afterwards. */
static void test_post_event_null_callback(void) {
    assert(janet_loop_done());
    JanetEVGenericMessage msg;
    memset(&msg, 0, sizeof(msg));
    janet_ev_post_event(NULL, NULL, msg);
    assert(!janet_loop_done());
    janet_loop1();
#ifdef JANET_WINDOWS
    assert(janet_loop_done());
#else
    assert(!janet_loop_done());
    janet_ev_dec_refcount();
    assert(janet_loop_done());
#endif
}

/* ----------------------------------------- the threaded-call reply tags */

static int freed_tags;

/* `janet_ev_default_threaded_callback` with a null fiber is the cleanup-only
 * path: nothing is scheduled and the payload is released. Every tag frees,
 * because both of the C original's switches send everything but the two
 * `*_STRINGF` cases to a `default` that also frees. */
static void test_threaded_callback_cleanup(void) {
    static const int tags[] = {
        JANET_EV_TCTAG_NIL, JANET_EV_TCTAG_INTEGER, JANET_EV_TCTAG_STRING,
        JANET_EV_TCTAG_STRINGF, JANET_EV_TCTAG_KEYWORD, JANET_EV_TCTAG_ERR_STRING,
        JANET_EV_TCTAG_ERR_STRINGF, JANET_EV_TCTAG_ERR_KEYWORD, JANET_EV_TCTAG_BOOLEAN,
    };
    freed_tags = 0;
    for (size_t i = 0; i < sizeof(tags) / sizeof(tags[0]); i++) {
        JanetEVGenericMessage msg;
        memset(&msg, 0, sizeof(msg));
        msg.tag = tags[i];
        msg.fiber = NULL;
        /* A heap payload, so that a missing free is a leak a sanitizer sees
         * and a double free is a crash. */
        msg.argp = janet_malloc(8);
        assert(msg.argp != NULL);
        memcpy(msg.argp, "abcdefg", 8);
        janet_ev_default_threaded_callback(msg);
        freed_tags++;
    }
    assert(freed_tags == 9);
    /* The loop is untouched: a null fiber schedules nothing. */
    assert(janet_loop_done());
}

/* ------------------------------------------------------- the timer heap */

/* `janet_addtimeout` and `janet_addtimeout_nil` differ only in what the
 * expired timer does to the fiber, and both are reachable from Janet only
 * through `ev/read`'s optional timeout. Scheduling one and running the loop
 * checks the ordering the heap imposes rather than the wall clock: three
 * deadlines set out of order come back in order.
 */
static void test_timeouts_ordered(void) {
    Janet out;
    assert(0 == janet_dostring(janet_core_env(NULL),
                               "(def log @[])\n"
                               "(defn t [n d] (ev/go (fn [] (ev/sleep d) (array/push log n))))\n"
                               "(t :c 0.03) (t :a 0.01) (t :b 0.02)\n"
                               "(ev/sleep 0.06)\n"
                               "log",
                               "ev_loop", &out));
    assert(janet_checktype(out, JANET_ARRAY));
    JanetArray *log = janet_unwrap_array(out);
    assert(log->count == 3);
    assert(janet_keyeq(log->data[0], "a"));
    assert(janet_keyeq(log->data[1], "b"));
    assert(janet_keyeq(log->data[2], "c"));
}

/* ------------------------------------------------------------ scheduling */

static void body_cancel_plain(void *ctx) {
    janet_cancel((JanetFiber *) ctx, janet_cstringv("nope"));
}

/* `janet_cancel` is the one scheduling entry point that raises, and only for
 * a fiber the loop has never seen. Its C face is a jump.
 *
 * The second half is the supervisor path, which is the loop's own use of the
 * non-blocking push (`mode == 2`) and which a Janet program reaches only by
 * passing a channel to `ev/go`. Attaching the channel by hand is what lets
 * this check the event's shape without one. */
static void test_cancel_non_task(void) {
    Janet fiberv;
    assert(0 == janet_dostring(janet_core_env(NULL), "(fiber/new (fn [] 1) :e)",
                               "ev_loop", &fiberv));
    JanetFiber *fiber = janet_unwrap_fiber(fiberv);
    janet_gcroot(fiberv);

    Janet payload = janet_wrap_nil();
    assert(JANET_SIGNAL_ERROR == catching(body_cancel_plain, fiber, &payload));
    assert(payload_is(payload, "cannot cancel non-task fiber"));

    /* Scheduling it makes it a task, and cancelling then succeeds. */
    JanetChannel *sup = janet_channel_make(4);
    Janet supv = janet_wrap_abstract(sup);
    janet_gcroot(supv);
    fiber->supervisor_channel = sup;

    janet_schedule(fiber, janet_wrap_nil());
    assert(0 == catching(body_cancel_plain, fiber, &payload));
    janet_loop();
    assert(janet_loop_done());

    /* The supervisor got `[:error fiber nil]` rather than a stack trace on
     * stderr, and the fiber's last value is what the cancel carried. */
    Janet event = janet_wrap_nil();
    assert(1 == janet_channel_take(sup, &event));
    assert(janet_checktype(event, JANET_TUPLE));
    const Janet *tup = janet_unwrap_tuple(event);
    assert(janet_tuple_length(tup) == 3);
    assert(janet_keyeq(tup[0], "error"));
    assert(janet_unwrap_fiber(tup[1]) == fiber);
    assert(janet_checktype(tup[2], JANET_NIL));
    assert(payload_is(fiber->last_value, "nope"));
    /* One event, not two: the first schedule was superseded by the cancel. */
    assert(0 == janet_channel_take(sup, &event));

    janet_gcunroot(supv);
    janet_gcunroot(fiberv);
}

/* `janet_schedule_soon` puts a task at the head of the spawn queue where
 * `janet_schedule` appends. Nothing in Janet chooses between them. */
static void test_schedule_soon_order(void) {
    Janet out;
    assert(0 == janet_dostring(janet_core_env(NULL),
                               "(def log @[]) "
                               "(def a (fiber/new (fn [] (array/push log :a)))) "
                               "(def b (fiber/new (fn [] (array/push log :b)))) "
                               "[log a b]",
                               "ev_loop", &out));
    const Janet *tup = janet_unwrap_tuple(out);
    janet_gcroot(out);
    JanetArray *log = janet_unwrap_array(tup[0]);
    JanetFiber *a = janet_unwrap_fiber(tup[1]);
    JanetFiber *b = janet_unwrap_fiber(tup[2]);

    janet_schedule(a, janet_wrap_nil());
    janet_schedule_soon(b, janet_wrap_nil(), JANET_SIGNAL_OK);
    janet_loop();

    assert(log->count == 2);
    assert(janet_keyeq(log->data[0], "b"));
    assert(janet_keyeq(log->data[1], "a"));
    janet_gcunroot(out);
}

/* ------------------------------------------- the two timeout constructors */

/* `janet_addtimeout` and `janet_addtimeout_nil` differ in one field of the
 * `JanetTimeout` they build: `is_error`. An expired error timeout cancels the
 * fiber and an expired nil timeout resumes it with nil.
 *
 * Neither can be called from here directly -- both read `janet_vm.root_fiber`,
 * which is only set while the loop is running a task -- and
 * `janet_addtimeout_nil` has **no Janet caller at all**: `ev/read`'s optional
 * timeout uses the error one, and only `net.c` uses the other. So the contract
 * lends the core environment two cfunctions of its own and drives them from a
 * task, which is the only way to reach the pair. */

static Janet cfun_add_timeout(int32_t argc, Janet *argv) {
    janet_fixarity(argc, 2);
    double sec = janet_getnumber(argv, 0);
    if (janet_getboolean(argv, 1)) {
        janet_addtimeout(sec);
    } else {
        janet_addtimeout_nil(sec);
    }
    return janet_wrap_nil();
}

static void test_addtimeout_and_addtimeout_nil(void) {
    JanetTable *env = janet_core_env(NULL);
    janet_def(env, "test/add-timeout", janet_wrap_cfunction(janet_contract_cfunction(cfun_add_timeout)),
              "Contract-only: janet_addtimeout when the second argument is "
              "true, janet_addtimeout_nil when it is false.");

    Janet out;
    assert(0 == janet_dostring(env,
                               "(def results @[])\n"
                               "(ev/go (fn []\n"
                               "  (test/add-timeout 0.01 false)\n"
                               "  (array/push results [:nil (ev/take (ev/chan 0))])))\n"
                               "(ev/go (fn []\n"
                               "  (test/add-timeout 0.01 true)\n"
                               "  (array/push results [:err (protect (ev/take (ev/chan 0)))])))\n"
                               "(ev/sleep 0.08)\n"
                               "results",
                               "ev_loop", &out));
    JanetArray *results = janet_unwrap_array(out);
    assert(results->count == 2);
    for (int32_t i = 0; i < results->count; i++) {
        const Janet *row = janet_unwrap_tuple(results->data[i]);
        if (janet_keyeq(row[0], "nil")) {
            /* addtimeout_nil resumes with nil rather than raising. */
            assert(janet_checktype(row[1], JANET_NIL));
        } else {
            /* addtimeout cancels the fiber, so `protect` reports a failure
             * carrying the message the loop supplies. */
            const Janet *pair = janet_unwrap_tuple(row[1]);
            assert(janet_checktype(pair[0], JANET_BOOLEAN));
            assert(!janet_unwrap_boolean(pair[0]));
            assert(payload_is(pair[1], "timeout"));
        }
    }
    assert(janet_loop_done());
}

/* ---------------------------------------------- scheduling, order by order */

static void test_schedule_signal_order(void) {
    Janet out;
    assert(0 == janet_dostring(janet_core_env(NULL),
                               "(def log @[]) "
                               "(def a (fiber/new (fn [] (array/push log :a)) :e)) "
                               "(def b (fiber/new (fn [] (array/push log :b)) :e)) "
                               "[log a b]",
                               "ev_loop", &out));
    const Janet *tup = janet_unwrap_tuple(out);
    janet_gcroot(out);
    JanetArray *log = janet_unwrap_array(tup[0]);
    JanetFiber *a = janet_unwrap_fiber(tup[1]);
    JanetFiber *b = janet_unwrap_fiber(tup[2]);

    /* `janet_schedule_signal` appends where `janet_schedule_soon` prepends,
     * and nothing in Janet chooses between the two. */
    janet_schedule_signal(a, janet_wrap_nil(), JANET_SIGNAL_OK);
    janet_schedule_soon(b, janet_wrap_nil(), JANET_SIGNAL_OK);
    janet_loop();
    assert(log->count == 2);
    assert(janet_keyeq(log->data[0], "b"));
    assert(janet_keyeq(log->data[1], "a"));
    janet_gcunroot(out);
}

/* `janet_cancel` appends too, and nothing above distinguishes that from
 * prepending. Both fibers report into the same channel, so the order they
 * reach it in is the assertion -- and the cancel's `sched_id` bump means the
 * schedule that preceded it is skipped rather than run. */
static void test_cancel_appends(void) {
    Janet out;
    assert(0 == janet_dostring(janet_core_env(NULL),
                               "(def out (ev/chan 8)) "
                               "(def a (fiber/new (fn [] (ev/give out :a)) :e)) "
                               "(def b (fiber/new (fn [] (ev/sleep 10)) :e)) "
                               "[out a b]",
                               "ev_loop", &out));
    const Janet *tup = janet_unwrap_tuple(out);
    janet_gcroot(out);
    JanetChannel *chan = janet_getchannel(tup, 0);
    JanetFiber *a = janet_unwrap_fiber(tup[1]);
    JanetFiber *b = janet_unwrap_fiber(tup[2]);
    b->supervisor_channel = chan;

    /* b is scheduled first, so it is a task and `janet_cancel` will accept
     * it; the cancel then supersedes that schedule. */
    janet_schedule(b, janet_wrap_nil());
    janet_schedule(a, janet_wrap_nil());
    janet_cancel(b, janet_cstringv("late"));
    janet_loop();

    Janet first = janet_wrap_nil();
    Janet second = janet_wrap_nil();
    assert(1 == janet_channel_take(chan, &first));
    assert(1 == janet_channel_take(chan, &second));
    /* The task queued before the cancel runs first: the cancel appended. */
    assert(janet_keyeq(first, "a"));
    /* And b ran once, as an error, rather than twice or as a sleep. */
    assert(janet_checktype(second, JANET_TUPLE));
    assert(janet_keyeq(janet_unwrap_tuple(second)[0], "error"));
    assert(0 == janet_channel_take(chan, &first));
    janet_gcunroot(out);
}

/* ------------------------------------------ the threaded flag, and optchannel */

/* `janet_channel_make_threaded` differs from `janet_channel_make` in one
 * field, and no binding reads it. What reads it is `janet_chan_pack`: a
 * threaded channel marshals anything that is not one of five self-contained
 * types on the way in and unmarshals it on the way out, and an unthreaded one
 * stores the value as it is.
 *
 * So the flag is observable as *identity*. A buffer given to an unthreaded
 * channel comes back as the same object; the same buffer given to a threaded
 * one comes back as a copy with the same contents, because it made the round
 * trip through the wire format. Nothing in Janet can ask a channel whether it
 * is threaded, so this is the only way to pin the constructor. */
static void test_threaded_flag_is_set(void) {
    JanetChannel *plain = janet_channel_make(2);
    JanetChannel *threaded = janet_channel_make_threaded(2);
    Janet plainv = janet_wrap_abstract(plain);
    janet_gcroot(plainv);

    JanetBuffer *orig = janet_buffer(8);
    janet_buffer_push_cstring(orig, "payload");
    Janet origv = janet_wrap_buffer(orig);
    janet_gcroot(origv);

    Janet item = janet_wrap_nil();

    assert(0 == janet_channel_give(plain, origv));
    assert(1 == janet_channel_take(plain, &item));
    assert(janet_checktype(item, JANET_BUFFER));
    assert(janet_unwrap_buffer(item) == orig);

    assert(0 == janet_channel_give(threaded, origv));
    assert(1 == janet_channel_take(threaded, &item));
    assert(janet_checktype(item, JANET_BUFFER));
    JanetBuffer *copy = janet_unwrap_buffer(item);
    assert(copy != orig);
    assert(copy->count == orig->count);
    assert(0 == memcmp(copy->data, orig->data, (size_t) orig->count));

    janet_gcunroot(origv);
    janet_gcunroot(plainv);
}

/* `janet_optchannel` takes its default when the argument is absent or nil, and
 * the channel otherwise. "Absent" is `argc > n`, and the boundary is the case
 * where the argument *exists* in the array but the count says it does not. */
static void test_optchannel_boundary(void) {
    Janet chanv;
    assert(0 == janet_dostring(janet_core_env(NULL), "(ev/chan 1)", "ev_loop", &chanv));
    janet_gcroot(chanv);
    JanetChannel *chan = janet_getchannel(&chanv, 0);

    Janet argv[2];
    argv[0] = chanv;
    argv[1] = janet_wrap_nil();

    /* A channel is there and the count says so. */
    assert(chan == janet_optchannel(argv, 1, 0, NULL));
    /* A channel is there and the count says it is not: the default wins, and
     * the value at that index is never looked at. */
    assert(NULL == janet_optchannel(argv, 0, 0, NULL));
    assert(chan == janet_optchannel(argv, 0, 0, chan));
    /* Present but nil: the default wins. */
    assert(NULL == janet_optchannel(argv, 2, 1, NULL));
    janet_gcunroot(chanv);
}

/* ---------------------------------------------------- marshalling a stream */

typedef struct {
    Janet value;
    JanetBuffer *buf;
    int flags;
} MarshalCase;

static void body_marshal_stream(void *ctx) {
    MarshalCase *mc = ctx;
    janet_marshal(mc->buf, mc->value, NULL, mc->flags);
}

static void body_unmarshal_stream(void *ctx) {
    MarshalCase *mc = ctx;
    mc->value = janet_unmarshal(mc->buf->data, mc->buf->count, mc->flags, NULL, NULL);
}

/* A stream carries a file descriptor, so both directions refuse to work
 * without `JANET_MARSHAL_UNSAFE` -- and the refusal is a raise, which for a C
 * caller is a jump. `ev/thread` is the only thing in Janet that marshals
 * unsafely, and it never marshals a bare stream, so neither the refusal nor
 * the success path has a Janet spelling. */
static void test_stream_marshalling(void) {
    JanetHandle handles[2];
    assert(0 == janet_make_pipe(handles, 0));
    JanetStream *s = janet_stream(handles[0], JANET_STREAM_READABLE, NULL);
    Janet streamv = janet_wrap_abstract(s);
    janet_gcroot(streamv);

    MarshalCase mc;
    Janet payload = janet_wrap_nil();
    mc.value = streamv;
    mc.buf = janet_buffer(32);
    mc.flags = 0;
    assert(JANET_SIGNAL_ERROR == catching(body_marshal_stream, &mc, &payload));
    assert(payload_is(payload, "can only marshal stream with unsafe flag"));

    /* With the flag, it marshals -- and duplicates the descriptor on the way
     * out, which is what makes an unmarshalled stream independent of this one. */
    mc.buf->count = 0;
    mc.flags = JANET_MARSHAL_UNSAFE;
    assert(0 == catching(body_marshal_stream, &mc, &payload));
    assert(mc.buf->count > 0);

    /* Marshalling clears NODUPS, because the handle may now have two owners. */
    assert(!(s->flags & JANET_STREAM_NODUPS));

    /* The reader refuses without the flag too. */
    mc.flags = 0;
    assert(JANET_SIGNAL_ERROR == catching(body_unmarshal_stream, &mc, &payload));
    assert(payload_is(payload, "can only unmarshal stream with unsafe flag"));

    mc.flags = JANET_MARSHAL_UNSAFE;
    assert(0 == catching(body_unmarshal_stream, &mc, &payload));
    JanetStream *back = janet_unwrap_abstract(mc.value);
    janet_gcroot(mc.value);
    assert(back != s);
    /* A different descriptor for the same pipe: `dup` was called. */
    assert(back->handle != s->handle);
    assert(back->flags == s->flags);
    assert(back->read_fiber == NULL && back->write_fiber == NULL);

#ifndef JANET_WINDOWS
    /* Both ends really do read the same pipe. */
    char byte = 'z';
    char got = 0;
    assert(1 == write(handles[1], &byte, 1));
    assert(1 == read(back->handle, &got, 1));
    assert(got == 'z');
#endif
    janet_stream_close(back);
    janet_stream_close(s);
    janet_gcunroot(mc.value);
    janet_gcunroot(streamv);
#ifndef JANET_WINDOWS
    close(handles[1]);
#endif
}

/* ------------------------------------------------ what only the queue holds */

/* `janet_ev_mark` walks the spawn queue and marks each task's *value* as well
 * as its fiber. The fiber is redundant -- `janet_schedule_general` also puts it
 * in `janet_vm.active_tasks`, which is a root -- but the resume value is not
 * held anywhere else, so the queue's walk is the only thing keeping it alive.
 *
 * Reaching that needs a value with no other reference, which `ev/go` cannot
 * supply: it copies the value into the fiber's stack when it builds it, so the
 * fiber roots it too. Building the fiber in Janet and scheduling it from C
 * leaves the task entry as the only holder. */
static void test_mark_keeps_task_values(void) {
    Janet out;
    assert(0 == janet_dostring(janet_core_env(NULL),
                               "(def out (ev/chan 8)) "
                               "(def f (fiber/new (fn [x] (ev/give out x)) :e)) "
                               "[out f]",
                               "ev_loop", &out));
    const Janet *tup = janet_unwrap_tuple(out);
    janet_gcroot(out);
    JanetChannel *chan = janet_getchannel(tup, 0);
    JanetFiber *f = janet_unwrap_fiber(tup[1]);

    /* A string built here and rooted only until it is queued. */
    Janet value = janet_cstringv("only-in-the-queue");
    janet_gcroot(value);
    janet_schedule(f, value);
    janet_gcunroot(value);
    value = janet_wrap_nil();

    /* Nothing but the task entry refers to it now. */
    janet_collect();
    janet_loop();

    Janet got = janet_wrap_nil();
    assert(1 == janet_channel_take(chan, &got));
    assert(payload_is(got, "only-in-the-queue"));
    janet_gcunroot(out);
}

/* `janet_loop` returns when `janet_loop_done` says there is nothing left, and
 * a task suspended on a timer counts as something left -- through
 * `is_suspended`, which raises the listener count on the way out of
 * `janet_loop1`. Every Janet test reaches this from *inside* the loop, where
 * the caller's own fiber keeps it alive; only a C caller can watch `janet_loop`
 * decide for itself. */
static void test_loop_waits_for_a_sleeping_task(void) {
    Janet out;
    assert(janet_loop_done());
    assert(0 == janet_dostring(janet_core_env(NULL),
                               "(def out (ev/chan 8)) "
                               "(def f (fiber/new (fn [] (ev/sleep 0.05) (ev/give out :done)) :e)) "
                               "[out f]",
                               "ev_loop", &out));
    const Janet *tup = janet_unwrap_tuple(out);
    janet_gcroot(out);
    JanetChannel *chan = janet_getchannel(tup, 0);
    JanetFiber *f = janet_unwrap_fiber(tup[1]);

    janet_schedule(f, janet_wrap_nil());
    assert(!janet_loop_done());
    janet_loop();

    /* It ran to completion rather than being abandoned at its first suspend. */
    Janet got = janet_wrap_nil();
    assert(1 == janet_channel_take(chan, &got));
    assert(janet_keyeq(got, "done"));
    assert(janet_loop_done());
    janet_gcunroot(out);
}

/* `janet_schedule_signal` appends. `test_schedule_signal_order` above pairs it
 * with `janet_schedule_soon`, which cannot tell "appends" from "prepends" --
 * with both prepending the order comes out the same. Two appends in a row can.
 */
static void test_schedule_signal_is_fifo(void) {
    Janet out;
    assert(0 == janet_dostring(janet_core_env(NULL),
                               "(def log @[]) "
                               "(def a (fiber/new (fn [] (array/push log :a)) :e)) "
                               "(def b (fiber/new (fn [] (array/push log :b)) :e)) "
                               "(def c (fiber/new (fn [] (array/push log :c)) :e)) "
                               "[log a b c]",
                               "ev_loop", &out));
    const Janet *tup = janet_unwrap_tuple(out);
    janet_gcroot(out);
    JanetArray *log = janet_unwrap_array(tup[0]);

    janet_schedule_signal(janet_unwrap_fiber(tup[1]), janet_wrap_nil(), JANET_SIGNAL_OK);
    janet_schedule_signal(janet_unwrap_fiber(tup[2]), janet_wrap_nil(), JANET_SIGNAL_OK);
    janet_schedule_signal(janet_unwrap_fiber(tup[3]), janet_wrap_nil(), JANET_SIGNAL_OK);
    janet_loop();

    assert(log->count == 3);
    assert(janet_keyeq(log->data[0], "a"));
    assert(janet_keyeq(log->data[1], "b"));
    assert(janet_keyeq(log->data[2], "c"));
    janet_gcunroot(out);
}

/* ----------------------------------------------------------------- entry */

void ev_loop_contract(void) {
    janet_init();

    test_protect_scope();

    test_channel_embedder_api();
    test_channel_threaded_make();
    test_channel_closed_c_face();
    test_channel_getters();

    test_stream_ext();
    test_stream_default_methods();
    test_stream_tostring();
    test_stream_flags_messages();
    test_stream_not_closeable();
    test_stream_marshalling();

#ifndef JANET_WINDOWS
    test_make_pipe_modes();
    test_lasterr();
#endif

    test_loop_done();
    test_post_event_round_trip();
    test_post_event_null_callback();
    test_threaded_callback_cleanup();

    test_timeouts_ordered();
    test_addtimeout_and_addtimeout_nil();
    test_cancel_non_task();
    test_schedule_soon_order();
    test_schedule_signal_order();
    test_schedule_signal_is_fifo();
    test_mark_keeps_task_values();
    test_loop_waits_for_a_sleeping_task();
    test_cancel_appends();
    test_threaded_flag_is_set();
    test_optchannel_boundary();

    janet_deinit();
}
