/* Behavioral contract for the host clock services, run against whichever
 * implementation the build selected (`-Dos-time=c` or the Zig default).
 *
 * Clocks cannot be pinned to fixed vectors the way a pure kernel can, so this
 * contract fixes their invariants instead: ranges, orderings, the fallback for
 * an unrecognized source, and that a sleep actually advances a monotonic
 * clock. */

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include <janet.h>

/* Declared rather than included from src/core/util.h, so the contract depends
 * only on the internal ABI it exercises. */
enum JanetTimeSource {
    JANET_TIME_REALTIME,
    JANET_TIME_MONOTONIC,
    JANET_TIME_CPUTIME
};
int janet_gettime(struct timespec *spec, enum JanetTimeSource source);
double janet_os_time_now(void);
void janet_os_sleep(double seconds);

/* Any run of this test is after the start of 2023 and before the end of 2200. */
#define EPOCH_LOWER_BOUND 1672531200LL
#define EPOCH_UPPER_BOUND 7289654400LL

static double seconds_of(struct timespec spec) {
    return (double) spec.tv_sec + (double) spec.tv_nsec / 1e9;
}

static void check_normalized(struct timespec spec) {
    assert(spec.tv_nsec >= 0);
    assert(spec.tv_nsec < 1000000000L);
}

static void test_realtime(void) {
    struct timespec spec;
    assert(janet_gettime(&spec, JANET_TIME_REALTIME) == 0);
    check_normalized(spec);
    assert((int64_t) spec.tv_sec > EPOCH_LOWER_BOUND);
    assert((int64_t) spec.tv_sec < EPOCH_UPPER_BOUND);

    /* The wall clock behind os/time agrees with the real-time source. */
    double now = janet_os_time_now();
    assert(now > (double) EPOCH_LOWER_BOUND);
    assert(now < (double) EPOCH_UPPER_BOUND);
    assert(now - (double) spec.tv_sec >= -2.0);
    assert(now - (double) spec.tv_sec <= 2.0);
}

static void test_monotonic(void) {
    struct timespec first, second;
    assert(janet_gettime(&first, JANET_TIME_MONOTONIC) == 0);
    assert(janet_gettime(&second, JANET_TIME_MONOTONIC) == 0);
    check_normalized(first);
    check_normalized(second);
    assert(seconds_of(second) >= seconds_of(first));
}

static void test_cputime(void) {
    struct timespec before, after;
    volatile double sink = 0;
    assert(janet_gettime(&before, JANET_TIME_CPUTIME) == 0);
    check_normalized(before);
    for (int32_t i = 0; i < 8000000; i++) sink += (double) i;
    assert(janet_gettime(&after, JANET_TIME_CPUTIME) == 0);
    check_normalized(after);
    /* Consumed CPU time is measured from process start, so it is positive and
     * never decreases. */
    assert(seconds_of(before) > 0);
    assert(seconds_of(after) >= seconds_of(before));
}

static void test_unknown_source(void) {
    struct timespec realtime, unknown;
    assert(janet_gettime(&realtime, JANET_TIME_REALTIME) == 0);
    /* An unrecognized source falls back to the real-time clock rather than
     * failing, because the C shim initializes its clock id before testing. */
    assert(janet_gettime(&unknown, (enum JanetTimeSource) 99) == 0);
    check_normalized(unknown);
    assert(seconds_of(unknown) - seconds_of(realtime) >= -2.0);
    assert(seconds_of(unknown) - seconds_of(realtime) <= 2.0);
}

static void test_sleep(void) {
    struct timespec before, after;
    double elapsed;

    assert(janet_gettime(&before, JANET_TIME_MONOTONIC) == 0);
    janet_os_sleep(0.05);
    assert(janet_gettime(&after, JANET_TIME_MONOTONIC) == 0);
    elapsed = seconds_of(after) - seconds_of(before);
    /* The lower bound is the contract; the upper bound is loose enough to
     * survive a loaded machine while still catching a sleep that multiplied
     * its argument by the wrong factor. */
    assert(elapsed >= 0.04);
    assert(elapsed < 10.0);

    /* A zero delay returns promptly rather than blocking. */
    assert(janet_gettime(&before, JANET_TIME_MONOTONIC) == 0);
    janet_os_sleep(0);
    assert(janet_gettime(&after, JANET_TIME_MONOTONIC) == 0);
    assert(seconds_of(after) - seconds_of(before) < 10.0);
}

static void run(JanetTable *env, const char *source) {
    Janet result;
    assert(janet_dostring(env, source, "os-time-contract", &result) == 0);
}

static void test_core_functions(void) {
    JanetTable *env = janet_core_env(NULL);

    /* Every documented source and format. */
    run(env,
        "(assert (number? (os/clock)))\n"
        "(assert (number? (os/clock :realtime)))\n"
        "(assert (number? (os/clock :monotonic)))\n"
        "(assert (number? (os/clock :cputime)))\n"
        "(assert (number? (os/clock :realtime :double)))\n");

    run(env,
        "(def whole (os/clock :realtime :int))\n"
        "(assert (= whole (math/floor whole)))\n"
        "(def parts (os/clock :monotonic :tuple))\n"
        "(assert (tuple? parts))\n"
        "(assert (= 2 (length parts)))\n"
        "(assert (= (parts 0) (math/floor (parts 0))))\n"
        "(assert (>= (parts 1) 0))\n"
        "(assert (< (parts 1) 1000000000))\n");

    /* The real-time clock and os/time agree; the monotonic clock does not go
     * backwards. */
    run(env,
        "(assert (< (math/abs (- (os/time) (os/clock :realtime :int))) 2))\n"
        "(assert (> (os/time) 1672531200))\n"
        "(def earlier (os/clock :monotonic))\n"
        "(assert (>= (os/clock :monotonic) earlier))\n");

    /* Sleeping advances the monotonic clock. */
    run(env,
        "(def before (os/clock :monotonic))\n"
        "(os/sleep 0.05)\n"
        "(def elapsed (- (os/clock :monotonic) before))\n"
        "(assert (>= elapsed 0.04))\n"
        "(assert (< elapsed 10))\n"
        "(assert (nil? (os/sleep 0)))\n");

    /* Invalid arguments keep raising from the C validation boundary. */
    run(env,
        "(assert (not (first (protect (os/clock :nope)))))\n"
        "(assert (not (first (protect (os/clock :realtime :nope)))))\n"
        "(assert (not (first (protect (os/sleep -1)))))\n");
}

int main(void) {
    test_realtime();
    test_monotonic();
    test_cputime();
    test_unknown_source();
    test_sleep();

    janet_init();
    test_core_functions();
    janet_deinit();
    return 0;
}
