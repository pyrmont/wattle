/* Behavioral contract for the file watcher's backends, watcher type and
 * cfunction surface, run against whichever implementation the build selected
 * (`-Dfilewatch-core=c` or the Zig default).
 *
 * ## What the Janet suites cannot reach
 *
 * `test/suite-filewatch.janet` drives a real watcher over a real directory,
 * which is what it is for. Five things have no Janet spelling at all:
 *
 *  - **The abstract type's callback set.** `janet_filewatch_at` is
 *    `JANET_ATEND_GCMARK`, so a mark callback and nothing else. From Janet
 *    only the *name* is visible, through `(type watcher)`; that the `get`,
 *    `put`, `tostring`, `compare`, `hash`, `next`, `call`, `length` and
 *    `bytes` slots are all null is what makes a watcher opaque, and it is
 *    invisible from the language.
 *  - **The mark callback on an incompletely initialised watcher.**
 *    `janet_abstract` does not zero, and `janet_watcher_init` fills the
 *    structure field by field, so `janet_filewatch_mark` opens by asking
 *    whether the channel is set. Nothing in Janet can hand the collector a
 *    watcher in that state; a `memset` and a `janet_abstract` can.
 *  - **A stale `errno`.** Two of this file's retry loops repeat on
 *    *success* -- see `FOUND.md`, "filewatch/remove retries a close that
 *    succeeded" -- and reaching that needs `EINTR` in `errno` when the
 *    cfunction is entered, which no Janet program can arrange. It is a
 *    defect, so the contract pins it rather than asserting the behaviour
 *    anyone would want.
 *  - **The two halves of the flag table.** The names are behind
 *    `-Dfilewatch-flags` and the values are here, and only C can ask the name
 *    lookup and the value decoder the same question and compare the answers.
 *  - **The failure messages that need an argument no Janet caller would
 *    write.** A raise is asserted here by its *message*, which Part 11
 *    recorded as the difference between a test and a tautology.
 *
 * ## What it deliberately does not do
 *
 * It does not run the event loop. `filewatch/listen` starts a fiber that
 * suspends on the watcher's stream, and pumping that from a C contract means
 * running the loop -- a contract that waits on the kernel is a contract that
 * hangs when it is wrong. The suite does that, where it belongs. What is
 * checked here is everything either side of it: the argument decoding, the
 * flag decoding, the watcher's shape, and every raise on the way.
 *
 * ## The two faces
 *
 * Phase 10's acceptance list requires the C face and the Zig face of a
 * converted symbol to be tested separately. As in Part 14, this increment
 * converts no raise-capable *exported* symbol: every one of `filewatch.c`'s
 * raises is inside a cfunction, and a cfunction is a C face already --
 * `Face(...).cfun` catches the error and calls `raise.deliverToC()`. So the
 * check is met by calling the registered cfunction pointer directly, which is
 * what `call_core` does, and there is no second face to drift from it. */

#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "features.h"
#include <janet.h>

#include "support.h"
#include "state.h"

#if defined(JANET_EV) && defined(JANET_FILEWATCH)

#ifndef JANET_WINDOWS
#include <sys/stat.h>
#include <unistd.h>
#endif

/* The platform ordinals `filewatch.c` pins with a compile-time assertion and
 * `filewatch_flags.zig` mirrors as an enumeration. Declared rather than
 * included so the contract depends only on the ABI it exercises. */
enum {
    PLATFORM_LINUX = 0,
    PLATFORM_WINDOWS = 1,
    PLATFORM_KQUEUE = 2
};

extern int32_t janet_filewatch_flag_count(uint32_t platform);
extern const char *janet_filewatch_flag_name(uint32_t platform, int32_t index);

/* Which backend this build compiled, and the word it puts in "unknown %s flag".
 * The chain is `filewatch.c`'s; a host with no backend takes the last arm and
 * every entry point there raises before a flag is ever looked at. */
#if defined(JANET_LINUX)
#define BACKEND_PLATFORM PLATFORM_LINUX
#define BACKEND_WORD "linux"
#elif defined(JANET_WINDOWS)
#define BACKEND_PLATFORM PLATFORM_WINDOWS
#define BACKEND_WORD "windows filewatch"
#elif defined(JANET_APPLE) || defined(JANET_BSD)
#define BACKEND_PLATFORM PLATFORM_KQUEUE
#define BACKEND_WORD "bsd"
#else
#define BACKEND_NONE 1
#endif

/* ------------------------------------------------------- raise assertions */

static int panics_fired = 0;

#define EXPECT_PANIC_MSG(expr, text) do { \
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
    if (janet_cstrcmp(janet_unwrap_string(_state.payload), (text))) { \
        printf("expected: %s\n     got: %s\n", (text), (const char *) janet_unwrap_string(_state.payload)); \
        assert(0 && "message mismatch"); \
    } \
    panics_fired++; \
} while (0)

/* For a message whose tail is the host's own wording: `janet_ev_lasterr`
 * renders `strerror`, which differs by platform and by libc, and pinning it
 * would make this contract a test of the C library. */
#define EXPECT_PANIC_PREFIX(expr, text) do { \
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
    assert((size_t) janet_string_length(janet_unwrap_string(_state.payload)) >= strlen(text)); \
    assert(!memcmp(janet_unwrap_string(_state.payload), (text), strlen(text))); \
    panics_fired++; \
} while (0)

#define EXPECT_ANY_PANIC(expr) do { \
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

/* Call a core cfunction by name. This is the pointer `janet_lib_filewatch`
 * registered, so it is the same face a Janet call would reach. */
static Janet call_core(const char *name, int32_t argc, Janet *argv) {
    Janet fun = janet_resolve_core(name);
    assert(janet_checktype(fun, JANET_CFUNCTION));
    return janet_contract_call_cfunction(janet_unwrap_cfunction(fun), argc, argv);
}

/* ------------------------------------------------------------ registration */

/* Every name `janet_lib_filewatch` registers, in the order it registers them.
 * The order is not itself a contract -- a table has none -- but the list is: a
 * binding that stops being registered is what this catches, and Part 6
 * recorded that a registration table is the one place a cfunction can go
 * missing without a link error. */
static const char *const filewatch_bindings[] = {
    "filewatch/new", "filewatch/add", "filewatch/remove",
    "filewatch/listen", "filewatch/unlisten",
};

static void test_registration(void) {
    size_t count = sizeof(filewatch_bindings) / sizeof(filewatch_bindings[0]);
    assert(count == 5);
    for (size_t i = 0; i < count; i++) {
        Janet fun = janet_resolve_core(filewatch_bindings[i]);
        assert(janet_checktype(fun, JANET_CFUNCTION));
    }
}

/* ------------------------------------------------------------- a channel */

/* `filewatch/new` takes a channel and there is no C entry point that makes
 * one, so it comes from the language. Nothing else in this file does. */
static Janet make_channel(void) {
    Janet chan = janet_wrap_nil();
    JanetTable *env = janet_core_env(NULL);
    int status = janet_dostring(env, "(ev/chan 16)", "filewatch_core", &chan);
    assert(status == 0);
    assert(janet_checkabstract(chan, &janet_channel_type));
    return chan;
}

/* --------------------------------------------------- arguments and flags */

static void test_argument_faults(Janet chan) {
    Janet one[1] = { chan };
    EXPECT_PANIC_MSG(call_core("filewatch/new", 0, NULL),
                     "arity mismatch, expected at least 1, got 0");
    {
        Janet bad[1] = { janet_wrap_integer(7) };
        EXPECT_PANIC_MSG(call_core("filewatch/new", 1, bad),
                         "bad slot #0, expected core/channel, got 7");
    }
    EXPECT_PANIC_MSG(call_core("filewatch/add", 1, one),
                     "arity mismatch, expected at least 2, got 1");
    EXPECT_PANIC_MSG(call_core("filewatch/remove", 1, one),
                     "arity mismatch, expected 2, got 1");
    EXPECT_PANIC_MSG(call_core("filewatch/listen", 0, NULL),
                     "arity mismatch, expected 1, got 0");
    EXPECT_PANIC_MSG(call_core("filewatch/unlisten", 0, NULL),
                     "arity mismatch, expected 1, got 0");
    /* A channel is not a watcher, and every entry point that takes one says so
     * with the abstract type's name -- which is the only place that name is
     * visible from outside this file. */
    EXPECT_PANIC_PREFIX(call_core("filewatch/listen", 1, one),
                        "bad slot #0, expected filewatch/watcher, got ");
}

#ifndef BACKEND_NONE

/* The message names the backend, and that word is the only part of it that
 * ever differed between them. */
static void test_flag_faults(Janet chan) {
    {
        Janet argv[2] = { chan, janet_ckeywordv("not-a-flag") };
        EXPECT_PANIC_MSG(call_core("filewatch/new", 2, argv),
                         "unknown " BACKEND_WORD " flag :not-a-flag");
    }
    {
        /* A non-keyword is refused before the vocabulary is consulted, so this
         * message has no backend word in it. */
        Janet argv[2] = { chan, janet_cstringv("all") };
        EXPECT_PANIC_MSG(call_core("filewatch/new", 2, argv),
                         "expected keyword, got \"all\"");
    }
    {
        /* The first flag is good and the second is not: the decoder folds left
         * and reports the one that failed rather than the first argument. */
        Janet argv[3] = { chan, janet_ckeywordv("all"), janet_ckeywordv("nope") };
        EXPECT_PANIC_MSG(call_core("filewatch/new", 3, argv),
                         "unknown " BACKEND_WORD " flag :nope");
    }
    {
        /* A keyword holding a zero byte matches nothing. It is the case the
         * name lookup compares by length for, and it is unreachable from a
         * source literal. */
        const uint8_t bytes[4] = { 'a', 'l', 'l', 0 };
        Janet argv[2] = { chan, janet_wrap_keyword(janet_keyword(bytes, 4)) };
        EXPECT_PANIC_PREFIX(call_core("filewatch/new", 2, argv),
                            "unknown " BACKEND_WORD " flag :all");
    }
}

/* The two halves of one table. The names are behind `-Dfilewatch-flags` and
 * the values are in the subject of this contract, and the index the lookup
 * reports is what selects a value -- so a name the host has a constant for is
 * accepted and one it does not is refused *by that name*. Asking every row of
 * this platform's vocabulary is the only way to see the halves line up.
 *
 * `:all` is index zero on every backend and is the union of the rest, so it is
 * the one row that must always be accepted. */
static void test_flag_table_halves(Janet chan) {
    int32_t count = janet_filewatch_flag_count(BACKEND_PLATFORM);
    int accepted = 0;
    assert(count > 0);
    for (int32_t i = 0; i < count; i++) {
        const char *name = janet_filewatch_flag_name(BACKEND_PLATFORM, i);
        assert(name != NULL);
        Janet argv[2] = { chan, janet_ckeywordv(name) };
        JanetTryState state;
        janet_try_init(&state);
        janet_contract_arm();
        Janet watcher = call_core("filewatch/new", 2, argv);
        JanetSignal sig = janet_contract_raised() ? janet_contract_signal() : JANET_SIGNAL_OK;
        if (!sig) {
            assert(janet_checktype(watcher, JANET_ABSTRACT));
            accepted++;
        } else {
            /* The only reason a name from this platform's own vocabulary is
             * refused is that the host's headers do not define the constant,
             * which the value table records as a zero. The message still
             * names the flag. */
            assert(sig == JANET_SIGNAL_ERROR);
            assert(janet_checktype(state.payload, JANET_STRING));
            assert(!memcmp(janet_unwrap_string(state.payload),
                           "unknown " BACKEND_WORD " flag :",
                           strlen("unknown " BACKEND_WORD " flag :")));
        }
        janet_restore(&state);
    }
    assert(accepted >= 1);
    /* Index zero is `:all`. */
    {
        const char *first = janet_filewatch_flag_name(BACKEND_PLATFORM, 0);
        assert(first != NULL && 0 == strcmp(first, "all"));
    }
    /* A name that belongs to a different backend is refused here, which is
     * what makes the split a split rather than one shared vocabulary. The
     * three tables share only `all`. */
    {
        uint32_t other = (BACKEND_PLATFORM == PLATFORM_LINUX)
                         ? (uint32_t) PLATFORM_WINDOWS : (uint32_t) PLATFORM_LINUX;
        int32_t other_count = janet_filewatch_flag_count(other);
        int refused = 0;
        for (int32_t i = 0; i < other_count; i++) {
            const char *name = janet_filewatch_flag_name(other, i);
            if (janet_filewatch_flag_name(BACKEND_PLATFORM, 0) == NULL) break;
            if (0 == strcmp(name, "all")) continue;
            /* Names shared with this platform's vocabulary are not the test. */
            int shared = 0;
            for (int32_t j = 0; j < count; j++) {
                if (0 == strcmp(name, janet_filewatch_flag_name(BACKEND_PLATFORM, j))) shared = 1;
            }
            if (shared) continue;
            {
                Janet argv[2] = { chan, janet_ckeywordv(name) };
                EXPECT_PANIC_PREFIX(call_core("filewatch/new", 2, argv),
                                    "unknown " BACKEND_WORD " flag :");
                refused++;
            }
        }
        assert(refused >= 1);
    }
}

/* ---------------------------------------------------- the abstract type */

/* `JANET_ATEND_GCMARK`: a mark callback and nothing else. Every later slot
 * being null is what makes a watcher opaque to `get`, `put`, `next`, `compare`
 * and the rest, and none of that is visible from Janet. */
static void test_abstract_type(Janet chan) {
    Janet argv[1] = { chan };
    Janet watcher = call_core("filewatch/new", 1, argv);
    void *abst;
    const JanetAbstractType *at;
    assert(janet_checktype(watcher, JANET_ABSTRACT));
    /* A `Janet` in a C local is not a root: the collector scans the VM and the
     * fiber stacks, and a cfunction's arguments are on one of those. Nothing
     * here is, so every watcher this file holds across an allocation has to be
     * rooted by hand -- and a watcher that is collected closes its stream, so
     * the symptom is a later call failing on a descriptor the test still
     * believes it owns. */
    janet_gcroot(watcher);
    abst = janet_unwrap_abstract(watcher);
    at = janet_abstract_type(abst);
    assert(0 == strcmp(at->name, "filewatch/watcher"));
    assert(at->gc == NULL);
    assert(at->gcmark != NULL);
    assert(at->get == NULL);
    assert(at->put == NULL);
    assert(at->marshal == NULL);
    assert(at->unmarshal == NULL);
    assert(at->tostring == NULL);
    assert(at->compare == NULL);
    assert(at->hash == NULL);
    assert(at->next == NULL);
    assert(at->call == NULL);
    assert(at->length == NULL);
    assert(at->bytes == NULL);
    assert(at->gcperthread == NULL);

    /* The live watcher marks without complaint, and reports zero as every
     * `gcmark` in the tree does. */
    assert(0 == at->gcmark(abst, janet_abstract_size(abst)));

    /* And a watcher that never reached `janet_watcher_init`. `janet_abstract`
     * does not zero, so the guard is a read of whatever was there; a zeroed
     * one is the case it exists for, and the collector reaching a watcher in
     * that state is what a raise between the allocation and the initialisation
     * would leave behind. */
    {
        size_t size = janet_abstract_size(abst);
        void *blank = janet_abstract(at, size);
        memset(blank, 0, size);
        assert(0 == at->gcmark(blank, size));
    }
    janet_gcunroot(watcher);
}

/* ------------------------------------------------- the watcher lifecycle */

#ifndef JANET_WINDOWS

#define PROBE_DIR "/tmp/janet-filewatch-contract"

static void test_lifecycle(Janet chan) {
    Janet new_argv[1] = { chan };
    Janet watcher;
    Janet dir = janet_cstringv(PROBE_DIR);

    rmdir(PROBE_DIR);
    assert(0 == mkdir(PROBE_DIR, 0755) || errno == EEXIST);

    watcher = call_core("filewatch/new", 1, new_argv);
    assert(janet_checktype(watcher, JANET_ABSTRACT));
    janet_gcroot(watcher);

    /* A path the host cannot open. The two backends word this differently --
     * inotify reports `janet_ev_lasterr` bare and kqueue prefixes it -- and
     * both are the host's `strerror` after that. */
    {
        Janet argv[3] = { watcher, janet_cstringv(PROBE_DIR "/no-such-entry"),
                          janet_ckeywordv("all")
                        };
        EXPECT_ANY_PANIC(call_core("filewatch/add", 3, argv));
    }

    /* Adding returns the watcher itself rather than a descriptor, which is
     * what lets `(-> w (filewatch/add p) (filewatch/add q))` thread. */
    {
        Janet argv[3] = { watcher, dir, janet_ckeywordv("all") };
        Janet got = call_core("filewatch/add", 3, argv);
        assert(janet_equals(got, watcher));
    }

    /* A path that was never added has no descriptor to look up. */
    {
        Janet argv[2] = { watcher, janet_cstringv(PROBE_DIR "/never-added") };
        EXPECT_PANIC_MSG(call_core("filewatch/remove", 2, argv),
                         "bad watch descriptor");
    }

    /* `FOUND.md`, "filewatch/remove retries a close that succeeded". The
     * retry loop repeats while the call *succeeded* and `errno` holds EINTR,
     * so a stale EINTR turns one successful removal into two attempts and the
     * second one fails. Nothing in Janet can leave EINTR in `errno` across a
     * cfunction entry; this is what the contract is for. Pinned rather than
     * asserted away, on Phase 8's rule: the behaviour is defined, so the port
     * reproduces it and the assertion holds for both selectors. */
    {
        Janet argv[2] = { watcher, dir };
        errno = EINTR;
        EXPECT_ANY_PANIC(call_core("filewatch/remove", 2, argv));
    }

    /* With a clean `errno` the same call is the ordinary one, and it answers
     * with the watcher. The descriptor above is gone, so this needs a fresh
     * watch first. */
    {
        Janet add_argv[3] = { watcher, dir, janet_ckeywordv("all") };
        Janet rm_argv[2] = { watcher, dir };
        call_core("filewatch/add", 3, add_argv);
        errno = 0;
        assert(janet_equals(call_core("filewatch/remove", 2, rm_argv), watcher));
    }

    /* Listening twice is refused, and that refusal is the only thing outside
     * the event loop that reads `is_watching`. Unlistening twice is *not*
     * refused: the second call returns without touching the stream. */
    {
        Janet argv[3] = { watcher, dir, janet_ckeywordv("all") };
        Janet one[1] = { watcher };
        call_core("filewatch/add", 3, argv);
        assert(janet_checktype(call_core("filewatch/listen", 1, one), JANET_NIL));
        EXPECT_PANIC_MSG(call_core("filewatch/listen", 1, one), "already watching");
        assert(janet_checktype(call_core("filewatch/unlisten", 1, one), JANET_NIL));
        assert(janet_checktype(call_core("filewatch/unlisten", 1, one), JANET_NIL));
    }

    /* And the watcher is dead after that, which is why this is the last thing
     * the lifecycle does. `filewatch/unlisten` closes the *watcher's own*
     * descriptor -- the inotify instance or the kqueue -- and nothing reopens
     * it, so every later `filewatch/add` fails on it. `FOUND.md` has the
     * entry; it is pinned here because it is the shape of the whole object's
     * life, and because a Janet program that hit it would see the failure
     * several calls away from the call that caused it. */
    {
        Janet argv[3] = { watcher, dir, janet_ckeywordv("all") };
        EXPECT_ANY_PANIC(call_core("filewatch/add", 3, argv));
    }

    janet_gcunroot(watcher);
    rmdir(PROBE_DIR);
}

#endif /* JANET_WINDOWS */

#endif /* BACKEND_NONE */

void filewatch_core_contract(void) {
    Janet chan;
    janet_init();
    chan = make_channel();
    janet_gcroot(chan);

    test_registration();
    test_argument_faults(chan);
#ifndef BACKEND_NONE
    test_flag_faults(chan);
    test_flag_table_halves(chan);
    test_abstract_type(chan);
#ifndef JANET_WINDOWS
    test_lifecycle(chan);
#endif
#endif

    janet_gcunroot(chan);
    printf("filewatch_core contract ok (%d raises)\n", panics_fired);
    janet_deinit();
}

#else /* JANET_EV && JANET_FILEWATCH */

void filewatch_core_contract(void) {
    printf("filewatch_core contract skipped (no file watcher in this build)\n");
}

#endif
