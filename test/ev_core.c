/* Behavioral contract for the event loop's portable kernels, run against
 * whichever implementation the build selected (`-Dev-core=c` or the Zig
 * default).
 *
 * The queue and the heap ordering are pure, so they are pinned with fixed
 * vectors. The heap functions are exercised through a local element type rather
 * than JanetTimeout: they take a stride and a field offset precisely so that
 * they never need the real structure, and testing them that way is what proves
 * it. A full heapsort through the two kernels checks the ordering end to end.
 */

#include <assert.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <janet.h>

/* Declared rather than included from src/core/state.h, so the contract depends
 * only on the internal ABI it exercises. */
typedef struct {
    int32_t capacity;
    int32_t head;
    int32_t tail;
    void *data;
} JanetQueue;

typedef int64_t JanetTimestamp;

void janet_ev_q_init(JanetQueue *q);
void janet_ev_q_deinit(JanetQueue *q);
int32_t janet_ev_q_count(const JanetQueue *q);
int janet_ev_q_maybe_resize(JanetQueue *q, size_t itemsize);
int janet_ev_q_push(JanetQueue *q, const void *item, size_t itemsize);
int janet_ev_q_push_head(JanetQueue *q, const void *item, size_t itemsize);
int janet_ev_q_pop(JanetQueue *q, void *out, size_t itemsize);
intptr_t janet_ev_heap_sift_down(const void *base, size_t stride, size_t when_offset,
                                 size_t count, size_t index);
intptr_t janet_ev_heap_sift_up(const void *base, size_t stride, size_t when_offset,
                               size_t index);
JanetTimestamp janet_ev_ts_delta(JanetTimestamp ts, double delta);
JanetTimestamp janet_ev_ts_from_parts(int64_t sec, int64_t nsec);
void janet_ev_ts_to_parts(JanetTimestamp ts, int64_t *sec_out, int64_t *nsec_out);
JanetTimestamp janet_ev_kqueue_interval(JanetTimestamp ts);

/* ------------------------------------------------------------------ queue */

static void test_queue_empty(void) {
    JanetQueue q;
    janet_ev_q_init(&q);
    assert(q.data == NULL);
    assert(q.capacity == 0);
    assert(janet_ev_q_count(&q) == 0);

    /* Popping an empty queue reports failure and leaves the output alone. */
    int32_t out = 12345;
    assert(janet_ev_q_pop(&q, &out, sizeof(out)) == 1);
    assert(out == 12345);

    janet_ev_q_deinit(&q);
}

static void test_queue_fifo(void) {
    JanetQueue q;
    janet_ev_q_init(&q);
    for (int32_t i = 0; i < 100; i++) {
        assert(janet_ev_q_push(&q, &i, sizeof(i)) == 0);
        assert(janet_ev_q_count(&q) == i + 1);
    }
    for (int32_t i = 0; i < 100; i++) {
        int32_t out = -1;
        assert(janet_ev_q_pop(&q, &out, sizeof(out)) == 0);
        assert(out == i);
    }
    assert(janet_ev_q_count(&q) == 0);
    assert(janet_ev_q_pop(&q, NULL, sizeof(int32_t)) == 1);
    janet_ev_q_deinit(&q);
}

static void test_queue_push_head(void) {
    JanetQueue q;
    janet_ev_q_init(&q);
    /* Pushing at the head reverses the order relative to an ordinary push. */
    for (int32_t i = 0; i < 50; i++) {
        assert(janet_ev_q_push_head(&q, &i, sizeof(i)) == 0);
    }
    assert(janet_ev_q_count(&q) == 50);
    for (int32_t i = 49; i >= 0; i--) {
        int32_t out = -1;
        assert(janet_ev_q_pop(&q, &out, sizeof(out)) == 0);
        assert(out == i);
    }
    janet_ev_q_deinit(&q);
}

/* Interleaving pushes and pops walks head and tail around the buffer, so the
 * resize path runs with head > tail and has to move the wrapped segment. */
static void test_queue_wrap_and_resize(void) {
    JanetQueue q;
    janet_ev_q_init(&q);
    int32_t next_in = 0;
    int32_t next_out = 0;

    for (int round = 0; round < 200; round++) {
        for (int i = 0; i < 3; i++) {
            assert(janet_ev_q_push(&q, &next_in, sizeof(next_in)) == 0);
            next_in++;
        }
        for (int i = 0; i < 2; i++) {
            int32_t out = -1;
            assert(janet_ev_q_pop(&q, &out, sizeof(out)) == 0);
            assert(out == next_out);
            next_out++;
        }
        assert(janet_ev_q_count(&q) == next_in - next_out);
    }

    /* Everything still queued comes out in order, unshuffled by any resize. */
    while (next_out < next_in) {
        int32_t out = -1;
        assert(janet_ev_q_pop(&q, &out, sizeof(out)) == 0);
        assert(out == next_out);
        next_out++;
    }
    assert(janet_ev_q_count(&q) == 0);
    janet_ev_q_deinit(&q);
}

/* A head push on a queue that is about to wrap takes the newhead < 0 branch. */
static void test_queue_push_head_wraps(void) {
    JanetQueue q;
    janet_ev_q_init(&q);
    int32_t seed = 0;
    assert(janet_ev_q_push(&q, &seed, sizeof(seed)) == 0);
    assert(q.head == 0);

    int32_t value = 99;
    assert(janet_ev_q_push_head(&q, &value, sizeof(value)) == 0);
    assert(q.head > 0);
    assert(janet_ev_q_count(&q) == 2);

    int32_t out = -1;
    assert(janet_ev_q_pop(&q, &out, sizeof(out)) == 0);
    assert(out == 99);
    assert(janet_ev_q_pop(&q, &out, sizeof(out)) == 0);
    assert(out == 0);
    janet_ev_q_deinit(&q);
}

/* Items larger than a machine word exercise the itemsize arithmetic. */
static void test_queue_large_items(void) {
    typedef struct {
        int64_t a;
        int64_t b;
        char tag[24];
    } Big;

    JanetQueue q;
    janet_ev_q_init(&q);
    for (int i = 0; i < 40; i++) {
        Big item;
        memset(&item, 0, sizeof(item));
        item.a = i;
        item.b = -i;
        snprintf(item.tag, sizeof(item.tag), "item-%d", i);
        assert(janet_ev_q_push(&q, &item, sizeof(item)) == 0);
    }
    for (int i = 0; i < 40; i++) {
        Big out;
        char expected[24];
        memset(&out, 0, sizeof(out));
        assert(janet_ev_q_pop(&q, &out, sizeof(out)) == 0);
        assert(out.a == i);
        assert(out.b == -i);
        snprintf(expected, sizeof(expected), "item-%d", i);
        assert(strcmp(out.tag, expected) == 0);
    }
    janet_ev_q_deinit(&q);
}

/* One slot is always left empty, so a resize happens one item before the
 * buffer is actually full. */
static void test_queue_keeps_a_spare_slot(void) {
    JanetQueue q;
    janet_ev_q_init(&q);
    for (int32_t i = 0; i < 64; i++) {
        assert(janet_ev_q_push(&q, &i, sizeof(i)) == 0);
        assert(janet_ev_q_count(&q) < q.capacity);
    }
    janet_ev_q_deinit(&q);
}

/* ------------------------------------------------------------------- heap */

/* A stand-in for JanetTimeout. The padding and the trailing field make the
 * `when` offset something other than zero and the stride something other than
 * the field size, which is what the kernels' parameters exist to describe. */
typedef struct {
    int32_t marker;
    JanetTimestamp when;
    char payload[12];
} Entry;

#define ENTRY_STRIDE sizeof(Entry)
#define ENTRY_OFFSET offsetof(Entry, when)

static void swap_entries(Entry *heap, size_t a, size_t b) {
    Entry tmp = heap[a];
    heap[a] = heap[b];
    heap[b] = tmp;
}

/* The insertion loop from add_timeout, spelled out against the kernel. */
static void heap_push(Entry *heap, size_t *count, JanetTimestamp when, int32_t marker) {
    size_t index = *count;
    memset(&heap[index], 0, sizeof(Entry));
    heap[index].when = when;
    heap[index].marker = marker;
    *count += 1;
    for (;;) {
        intptr_t parent = janet_ev_heap_sift_up(heap, ENTRY_STRIDE, ENTRY_OFFSET, index);
        if (parent < 0) break;
        swap_entries(heap, index, (size_t) parent);
        index = (size_t) parent;
    }
}

/* The removal loop from pop_timeout, spelled out against the kernel. */
static Entry heap_pop(Entry *heap, size_t *count) {
    Entry top = heap[0];
    *count -= 1;
    heap[0] = heap[*count];
    size_t index = 0;
    for (;;) {
        intptr_t smallest =
            janet_ev_heap_sift_down(heap, ENTRY_STRIDE, ENTRY_OFFSET, *count, index);
        if (smallest < 0) break;
        swap_entries(heap, index, (size_t) smallest);
        index = (size_t) smallest;
    }
    return top;
}

static void test_heap_reports_no_swap_when_ordered(void) {
    Entry heap[3];
    memset(heap, 0, sizeof(heap));
    heap[0].when = 10;
    heap[1].when = 20;
    heap[2].when = 30;

    /* The root is already smallest, and neither child has a parent to rise
     * above. */
    assert(janet_ev_heap_sift_down(heap, ENTRY_STRIDE, ENTRY_OFFSET, 3, 0) == -1);
    assert(janet_ev_heap_sift_up(heap, ENTRY_STRIDE, ENTRY_OFFSET, 0) == -1);
    assert(janet_ev_heap_sift_up(heap, ENTRY_STRIDE, ENTRY_OFFSET, 1) == -1);
    assert(janet_ev_heap_sift_up(heap, ENTRY_STRIDE, ENTRY_OFFSET, 2) == -1);
}

static void test_heap_selects_children(void) {
    Entry heap[3];
    memset(heap, 0, sizeof(heap));

    /* Left child smallest. */
    heap[0].when = 30;
    heap[1].when = 10;
    heap[2].when = 20;
    assert(janet_ev_heap_sift_down(heap, ENTRY_STRIDE, ENTRY_OFFSET, 3, 0) == 1);

    /* Right child smallest. */
    heap[1].when = 20;
    heap[2].when = 10;
    assert(janet_ev_heap_sift_down(heap, ENTRY_STRIDE, ENTRY_OFFSET, 3, 0) == 2);

    /* A tie between the children keeps the left one, which is what the C
     * implementation's strict comparisons produce. */
    heap[1].when = 10;
    heap[2].when = 10;
    assert(janet_ev_heap_sift_down(heap, ENTRY_STRIDE, ENTRY_OFFSET, 3, 0) == 1);

    /* A child equal to the parent does not move: the parent wins ties too. */
    heap[0].when = 10;
    assert(janet_ev_heap_sift_down(heap, ENTRY_STRIDE, ENTRY_OFFSET, 3, 0) == -1);
}

/* Children outside the live count are invisible, which is what makes the
 * shrink in pop_timeout safe. */
static void test_heap_respects_count(void) {
    Entry heap[3];
    memset(heap, 0, sizeof(heap));
    heap[0].when = 30;
    heap[1].when = 10;
    heap[2].when = 20;

    assert(janet_ev_heap_sift_down(heap, ENTRY_STRIDE, ENTRY_OFFSET, 1, 0) == -1);
    assert(janet_ev_heap_sift_down(heap, ENTRY_STRIDE, ENTRY_OFFSET, 2, 0) == 1);
    assert(janet_ev_heap_sift_down(heap, ENTRY_STRIDE, ENTRY_OFFSET, 3, 0) == 1);
}

static void test_heap_sift_up_parent(void) {
    Entry heap[4];
    memset(heap, 0, sizeof(heap));
    heap[0].when = 10;
    heap[1].when = 50;
    heap[2].when = 60;
    heap[3].when = 20;

    /* Index 3's parent is index 1, and 20 < 50, so it rises. */
    assert(janet_ev_heap_sift_up(heap, ENTRY_STRIDE, ENTRY_OFFSET, 3) == 1);
    /* Index 1's parent is the root, and 50 > 10, so it stays. */
    assert(janet_ev_heap_sift_up(heap, ENTRY_STRIDE, ENTRY_OFFSET, 1) == -1);
    /* An equal parent also stays: sift_up compares with <=. */
    heap[3].when = 50;
    assert(janet_ev_heap_sift_up(heap, ENTRY_STRIDE, ENTRY_OFFSET, 3) == -1);
}

/* Driving both kernels through a full heapsort checks the ordering end to end
 * rather than one decision at a time. */
static void test_heap_orders_a_full_sequence(void) {
    static const JanetTimestamp input[] = {
        50, 10, 40, 10, 90, 0, -5, 70, 30, 30, 1, 1000000, -100, 20, 60
    };
    const size_t n = sizeof(input) / sizeof(input[0]);
    Entry heap[sizeof(input) / sizeof(input[0])];
    size_t count = 0;

    for (size_t i = 0; i < n; i++) {
        heap_push(heap, &count, input[i], (int32_t) i);
    }
    assert(count == n);

    JanetTimestamp previous = INT64_MIN;
    for (size_t i = 0; i < n; i++) {
        Entry got = heap_pop(heap, &count);
        assert(got.when >= previous);
        previous = got.when;
    }
    assert(count == 0);
}

/* --------------------------------------------------------------- timestamps */

static void test_ts_delta(void) {
    assert(janet_ev_ts_delta(1000, 0.0) == 1000);
    assert(janet_ev_ts_delta(1000, 1.0) == 2000);
    assert(janet_ev_ts_delta(1000, 0.5) == 1500);
    assert(janet_ev_ts_delta(1000, -0.5) == 500);

    /* Milliseconds are rounded, not truncated. */
    assert(janet_ev_ts_delta(0, 0.0004) == 0);
    assert(janet_ev_ts_delta(0, 0.0006) == 1);
    assert(janet_ev_ts_delta(0, 0.0015) == 2);

    /* A negative infinity is "already due"; a positive one is "never". */
    assert(janet_ev_ts_delta(1234, -INFINITY) == 1234);
    assert(janet_ev_ts_delta(1234, INFINITY) == INT64_MAX);
}

static void test_ts_parts(void) {
    assert(janet_ev_ts_from_parts(0, 0) == 0);
    assert(janet_ev_ts_from_parts(1, 0) == 1000);
    assert(janet_ev_ts_from_parts(0, 1000000) == 1);
    /* Sub-millisecond nanoseconds are dropped rather than rounded. */
    assert(janet_ev_ts_from_parts(0, 999999) == 0);
    assert(janet_ev_ts_from_parts(2, 500000000) == 2500);

    int64_t sec = -1, nsec = -1;
    janet_ev_ts_to_parts(0, &sec, &nsec);
    assert(sec == 0 && nsec == 0);

    janet_ev_ts_to_parts(1500, &sec, &nsec);
    assert(sec == 1 && nsec == 500000000);

    janet_ev_ts_to_parts(1000, &sec, &nsec);
    assert(sec == 1 && nsec == 0);

    janet_ev_ts_to_parts(7, &sec, &nsec);
    assert(sec == 0 && nsec == 7000000);

    /* A round trip through both directions is exact on millisecond values. */
    for (JanetTimestamp ts = 1; ts < 100000; ts += 337) {
        janet_ev_ts_to_parts(ts, &sec, &nsec);
        assert(janet_ev_ts_from_parts(sec, nsec) == ts);
    }
}

static void test_kqueue_interval(void) {
    assert(janet_ev_kqueue_interval(0) == 0);
    assert(janet_ev_kqueue_interval(5) == 5);
    assert(janet_ev_kqueue_interval(INT64_MAX) == INT64_MAX);
    /* A deadline already in the past clamps to the minimum. */
    assert(janet_ev_kqueue_interval(-1) == 0);
    assert(janet_ev_kqueue_interval(INT64_MIN) == 0);
}


/* The Janet-level behaviour these kernels produce — channel ordering across a
 * resize, deadlines firing in time order — is covered by `test/suite-ev.janet`
 * rather than here, and deliberately so.
 *
 * `ev/give`, `ev/take`, and `ev/sleep` all end in `janet_await`, which suspends
 * the calling fiber whether or not the operation could be satisfied
 * immediately. `janet_dostring` runs a source string one top-level form at a
 * time and only drains the event loop once the whole string has been read, so a
 * form that follows a suspending one runs while the earlier form is still
 * parked. An assertion written that way observes an intermediate state: a
 * channel drained by a suspended loop still reports its items, and a print
 * placed after the loop emits before the loop's own output. That is the
 * embedding API behaving as designed, not a defect, but it makes any assertion
 * of this shape meaningless.
 *
 * The suites run under the CLI, which drives the whole program through the
 * scheduler, and they run against whichever implementation the selector chose.
 * That is where the end-to-end coverage for this subsystem belongs. */

int main(void) {
    test_queue_empty();
    test_queue_fifo();
    test_queue_push_head();
    test_queue_wrap_and_resize();
    test_queue_push_head_wraps();
    test_queue_large_items();
    test_queue_keeps_a_spare_slot();

    test_heap_reports_no_swap_when_ordered();
    test_heap_selects_children();
    test_heap_respects_count();
    test_heap_sift_up_parent();
    test_heap_orders_a_full_sequence();

    test_ts_delta();
    test_ts_parts();
    test_kqueue_interval();
    return 0;
}
