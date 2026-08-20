/* Behavioral contract for the collector's mark phase: the traversal, the
 * recursion guard, and `janet_collect`. Run against whichever implementation
 * the build selected (`-Dgc-mark=c` or the Zig default).
 *
 * Marking has no return value and frees nothing, so almost everything here is
 * observed the same way: clear `JANET_MEM_REACHABLE` on the objects under test,
 * mark one value, and ask which headers came back set. That needs the internal
 * headers, which is why they are included -- the bit is the result.
 *
 * Two observations cannot be made that way and use a weak table instead. A
 * collection ends by clearing every `REACHABLE` bit it set, so "was this marked
 * during the collection?" is gone by the time the call returns. A weak-valued
 * table answers it: `janet_sweep` drops exactly the values the mark phase did
 * not reach, so an entry that is still there afterwards was marked. That relies
 * on the sweep, which is C on both sides of this contract, so it is an
 * observation channel rather than part of what is being tested.
 *
 * Nothing here exercises a panicking `gcmark`. SPIKE-8 settled that an abstract
 * callback may not raise, and `SPIKE-8.md` records what the C runtime does when
 * one does anyway.
 */

#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "features.h"
#include <janet.h>

#include "support.h"
#include "state.h"
#include "gc.h"

/* ------------------------------------------------------------------ helpers */

static int reachable(void *p) {
    return (janet_gc_header(p)->flags & JANET_MEM_REACHABLE) != 0;
}

static void unmark(void *p) {
    janet_gc_header(p)->flags &= ~JANET_MEM_REACHABLE;
}

/* The head of whatever `x` refers to, or NULL for a value the collector does
 * not trace. Mirrors the cases `janet_check_liveref` distinguishes. */
static void *head_of(Janet x) {
    switch (janet_type(x)) {
        default:
            return NULL;
        case JANET_ARRAY:
        case JANET_TABLE:
        case JANET_FUNCTION:
        case JANET_BUFFER:
        case JANET_FIBER:
            return janet_unwrap_pointer(x);
        case JANET_STRING:
        case JANET_SYMBOL:
        case JANET_KEYWORD:
            return janet_string_head(janet_unwrap_string(x));
        case JANET_ABSTRACT:
            return janet_abstract_head(janet_unwrap_abstract(x));
        case JANET_TUPLE:
            return janet_tuple_head(janet_unwrap_tuple(x));
        case JANET_STRUCT:
            return janet_struct_head(janet_unwrap_struct(x));
    }
}

static void unmark_value(Janet x) {
    void *h = head_of(x);
    if (h != NULL) unmark(h);
}

static int value_reachable(Janet x) {
    void *h = head_of(x);
    assert(h != NULL);
    return reachable(h);
}

/* Start from a heap with no marks left over from an earlier case. A collection
 * ends by clearing every bit it set, so this is the cheapest way to get one. */
static void fresh_heap(void) {
    janet_collect();
}

/* ------------------------------------------------------------ head layout */

/* Zig cannot ask for `offsetof(JanetStringHead, data)`: translate-c drops
 * flexible array members, so `gc_mark.zig` recovers every head with `@sizeOf`
 * instead. The two agree only where the flexible array needs no padding after
 * the last declared field. That is a property of the C layout, so it is checked
 * here, in C, where both spellings exist -- and it is checked against `c` as
 * well, where it is merely true rather than load-bearing. */
static void test_head_offsets(void) {
    assert(sizeof(JanetStringHead) == offsetof(JanetStringHead, data));
    assert(sizeof(JanetTupleHead) == offsetof(JanetTupleHead, data));
    assert(sizeof(JanetStructHead) == offsetof(JanetStructHead, data));
    assert(sizeof(JanetAbstractHead) == offsetof(JanetAbstractHead, data));
    assert(sizeof(JanetFunction) == offsetof(JanetFunction, envs));
}

/* ----------------------------------------------------------- leaf marking */

/* The types the collector does not trace must be accepted and ignored, and
 * must not disturb the guard: the string marked afterwards proves `depth` came
 * back to where it started. */
static void test_mark_immediates(void) {
    size_t roots = janet_vm.root_count;

    janet_mark(janet_wrap_nil());
    janet_mark(janet_wrap_true());
    janet_mark(janet_wrap_number(3.5));
    janet_mark(janet_wrap_integer(-7));
    janet_mark(janet_wrap_pointer((void *) &roots));

    assert(janet_vm.root_count == roots);

    Janet s = janet_cstringv("after-immediates");
    unmark_value(s);
    janet_mark(s);
    assert(value_reachable(s));
}

static void test_mark_strings(void) {
    Janet s = janet_cstringv("a string");
    Janet k = janet_ckeywordv("a-keyword");
    Janet y = janet_csymbolv("a-symbol");

    unmark_value(s);
    unmark_value(k);
    unmark_value(y);

    janet_mark(s);
    janet_mark(k);
    janet_mark(y);

    assert(value_reachable(s));
    assert(value_reachable(k));
    assert(value_reachable(y));
}

static void test_mark_buffer(void) {
    JanetBuffer *b = janet_buffer(8);
    janet_buffer_push_cstring(b, "contents");
    unmark(b);
    janet_mark(janet_wrap_buffer(b));
    assert(reachable(b));
}

/* ---------------------------------------------------------------- arrays */

static void test_mark_array(void) {
    JanetArray *a = janet_array(2);
    Janet s = janet_cstringv("in an array");
    janet_array_push(a, s);

    unmark(a);
    unmark_value(s);
    janet_mark(janet_wrap_array(a));

    assert(reachable(a));
    assert(value_reachable(s));
}

/* A weak array is marked but not traversed. The type test in `janet_mark_array`
 * is the only thing that distinguishes the two kinds during marking, and it is
 * easy to mistake for a redundant check. */
static void test_mark_array_weak(void) {
    JanetArray *a = janet_array_weak(2);
    Janet s = janet_cstringv("in a weak array");
    janet_array_push(a, s);

    unmark(a);
    unmark_value(s);
    janet_mark(janet_wrap_array(a));

    assert(reachable(a));
    assert(!value_reachable(s));
}

/* ---------------------------------------------------------------- tables */

/* Which half of an entry the mark phase follows is what makes a table weak.
 * All four kinds are checked together because the difference between them is
 * the contract: a weak-keyed table keeps its values alive, a weak-valued table
 * keeps its keys, and one weak in both keeps neither -- the last being the case
 * with no branch of its own in the C original. */
static void test_mark_table_variants(void) {
    struct {
        JanetTable *(*make)(int32_t);
        int keeps_key;
        int keeps_value;
        const char *what;
    } cases[] = {
        { janet_table, 1, 1, "table" },
        { janet_table_weakk, 0, 1, "weak keys" },
        { janet_table_weakv, 1, 0, "weak values" },
        { janet_table_weakkv, 0, 0, "weak both" },
    };

    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        JanetTable *t = cases[i].make(4);
        Janet key = janet_cstringv("the key");
        Janet value = janet_cstringv("the value");
        janet_table_put(t, key, value);

        unmark(t);
        unmark_value(key);
        unmark_value(value);
        janet_mark(janet_wrap_table(t));

        assert(reachable(t));
        assert(value_reachable(key) == cases[i].keeps_key);
        assert(value_reachable(value) == cases[i].keeps_value);
    }
}

/* The prototype chain is followed iteratively, and the reachability test is
 * what terminates a cycle. Both halves are checked here: a three-link chain is
 * marked to its end, and a two-table cycle returns rather than spinning. */
static void test_mark_table_protos(void) {
    JanetTable *a = janet_table(1);
    JanetTable *b = janet_table(1);
    JanetTable *cc = janet_table(1);
    a->proto = b;
    b->proto = cc;

    Janet deep = janet_cstringv("in the last proto");
    janet_table_put(cc, janet_ckeywordv("k"), deep);

    unmark(a);
    unmark(b);
    unmark(cc);
    unmark_value(deep);
    janet_mark(janet_wrap_table(a));

    assert(reachable(a) && reachable(b) && reachable(cc));
    assert(value_reachable(deep));

    JanetTable *x = janet_table(1);
    JanetTable *y = janet_table(1);
    x->proto = y;
    y->proto = x;
    unmark(x);
    unmark(y);
    janet_mark(janet_wrap_table(x));
    assert(reachable(x) && reachable(y));
}

/* --------------------------------------------------------- structs, tuples */

static void test_mark_struct(void) {
    JanetKV *protob = janet_struct_begin(1);
    Janet pvalue = janet_cstringv("in the struct proto");
    janet_struct_put(protob, janet_ckeywordv("p"), pvalue);
    JanetStruct proto = janet_struct_end(protob);

    JanetKV *stb = janet_struct_begin(1);
    Janet key = janet_cstringv("struct key");
    Janet value = janet_cstringv("struct value");
    janet_struct_put(stb, key, value);
    JanetStruct st = janet_struct_end(stb);
    janet_struct_head(st)->proto = proto;

    unmark(janet_struct_head(st));
    unmark(janet_struct_head(proto));
    unmark_value(key);
    unmark_value(value);
    unmark_value(pvalue);

    janet_mark(janet_wrap_struct(st));

    assert(reachable(janet_struct_head(st)));
    assert(reachable(janet_struct_head(proto)));
    assert(value_reachable(key));
    assert(value_reachable(value));
    assert(value_reachable(pvalue));
}

static void test_mark_tuple(void) {
    Janet items[2];
    items[0] = janet_cstringv("tuple element one");
    items[1] = janet_cstringv("tuple element two");
    JanetTuple t = janet_tuple_n(items, 2);

    unmark(janet_tuple_head(t));
    unmark_value(items[0]);
    unmark_value(items[1]);

    janet_mark(janet_wrap_tuple(t));

    assert(reachable(janet_tuple_head(t)));
    assert(value_reachable(items[0]));
    assert(value_reachable(items[1]));
}

/* -------------------------------------------------------------- abstracts */

static int probe_gcmark_calls = 0;
static int probe_saw_mark_phase = -1;
static int probe_roots_on_mark = 0;
static Janet probe_root_value;
static Janet probe_child_value;

static int probe_gcmark(void *data, size_t len) {
    (void) data;
    (void) len;
    probe_gcmark_calls++;
    probe_saw_mark_phase = janet_vm.gc_mark_phase;
    janet_mark(probe_child_value);
    if (probe_roots_on_mark) janet_gcroot(probe_root_value);
    return 0;
}

static const JanetAbstractType at_marked = {
    "gc-mark-test/marked",
    NULL, probe_gcmark, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL
};

static const JanetAbstractType at_plain = {
    "gc-mark-test/plain",
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL
};

/* The callback runs once per collection, not once per reference: the
 * reachability test in front of it is what stops a shared abstract from being
 * walked again by every holder. */
static void test_mark_abstract(void) {
    void *a = janet_abstract(CONTRACT_AT(at_marked), 8);
    probe_child_value = janet_cstringv("reached by gcmark");
    probe_gcmark_calls = 0;

    unmark(janet_abstract_head(a));
    unmark_value(probe_child_value);

    janet_mark(janet_wrap_abstract(a));
    assert(reachable(janet_abstract_head(a)));
    assert(probe_gcmark_calls == 1);
    assert(value_reachable(probe_child_value));

    janet_mark(janet_wrap_abstract(a));
    assert(probe_gcmark_calls == 1);
}

static void test_mark_abstract_without_gcmark(void) {
    void *a = janet_abstract(CONTRACT_AT(at_plain), 8);
    unmark(janet_abstract_head(a));
    janet_mark(janet_wrap_abstract(a));
    assert(reachable(janet_abstract_head(a)));
}

/* ------------------------------------------------------ functions, fibers */

/* Every value a closure can still reach has to be marked through it: the
 * definition, the definition's source name, and the captured environment. The
 * environment is the interesting one -- `janet_mark_funcenv` detaches it from
 * its dead fiber first, so what is marked is the copied-out values rather than
 * the fiber. */
static void test_mark_function(void) {
    JanetTable *env = janet_core_env(NULL);
    Janet out;
    assert(janet_dostring(env, "(let [x \"captured-by-closure\"] (fn [] x))",
                          "gc-mark-test", &out) == 0);
    assert(janet_checktype(out, JANET_FUNCTION));
    janet_gcroot(out);

    JanetFunction *f = janet_unwrap_function(out);
    assert(f->def != NULL);
    assert(f->def->environments_length > 0);

    unmark(f);
    unmark(f->def);
    if (f->def->source) unmark(janet_string_head(f->def->source));
    for (int32_t i = 0; i < f->def->environments_length; i++) {
        unmark(f->envs[i]);
    }

    janet_mark(out);

    assert(reachable(f));
    assert(reachable(f->def));
    if (f->def->source) assert(reachable(janet_string_head(f->def->source)));

    /* The environment is detached by the mark, so its values are off the
     * stack and every one of them must have been marked in place. */
    JanetFuncEnv *fe = f->envs[0];
    assert(reachable(fe));
    assert(fe->offset == 0);
    int found = 0;
    for (int32_t i = 0; i < fe->length; i++) {
        void *h = head_of(fe->as.values[i]);
        if (h == NULL) continue;
        assert(reachable(h));
        found++;
    }
    assert(found > 0);

    janet_gcunroot(out);
}

/* A suspended fiber holds its frames, and each frame holds a function whose
 * only reference may be that frame. The fiber below is stopped inside a call,
 * so `frame->func` is set and the frame walk is what reaches it. */
static void test_mark_fiber(void) {
    JanetTable *env = janet_core_env(NULL);
    Janet out;
    assert(janet_dostring(env, "(fiber/new (fn [] (yield \"suspended\") nil))",
                          "gc-mark-test", &out) == 0);
    assert(janet_checktype(out, JANET_FIBER));
    janet_gcroot(out);

    JanetFiber *f = janet_unwrap_fiber(out);
    Janet resumed;
    janet_continue(f, janet_wrap_nil(), &resumed);
    assert(f->frame > 0);

    JanetStackFrame *frame = (JanetStackFrame *)(f->data + f->frame - JANET_FRAME_SIZE);
    assert(frame->func != NULL);

    JanetTable *dyns = janet_table(1);
    f->env = dyns;
    Janet last = janet_cstringv("the last value");
    f->last_value = last;

    JanetFiber *child = janet_unwrap_fiber(out);
    (void) child;

    unmark(f);
    unmark(frame->func);
    unmark(dyns);
    unmark_value(last);

    janet_mark(out);

    assert(reachable(f));
    assert(reachable(frame->func));
    assert(reachable(dyns));
    assert(value_reachable(last));

    janet_gcunroot(out);
}

/* The child chain is followed iteratively, and a fiber already marked ends it.
 * Built by hand because reaching this state from Janet source needs a fiber
 * suspended inside another one. */
static void test_mark_fiber_children(void) {
    JanetTable *env = janet_core_env(NULL);
    Janet parent_v, child_v;
    assert(janet_dostring(env, "(fiber/new (fn [] nil))", "gc-mark-test", &parent_v) == 0);
    assert(janet_dostring(env, "(fiber/new (fn [] nil))", "gc-mark-test", &child_v) == 0);
    janet_gcroot(parent_v);
    janet_gcroot(child_v);

    JanetFiber *parent = janet_unwrap_fiber(parent_v);
    JanetFiber *child = janet_unwrap_fiber(child_v);
    JanetFiber *saved = parent->child;
    parent->child = child;

    Janet held = janet_cstringv("held by the child fiber");
    child->last_value = held;

    unmark(parent);
    unmark(child);
    unmark_value(held);

    janet_mark(parent_v);

    assert(reachable(parent));
    assert(reachable(child));
    assert(value_reachable(held));

    parent->child = saved;
    janet_gcunroot(child_v);
    janet_gcunroot(parent_v);
}

/* ---------------------------------------------------------- recursion guard */

/* Build a chain of `n` single-element arrays, each holding the next. Collection
 * is suspended for the duration: nothing roots the chain until it is finished,
 * and it is long enough that building it would otherwise trigger one. */
static void build_chain(int32_t n, JanetArray **out) {
    int handle = janet_gclock();
    out[0] = janet_array(1);
    for (int32_t i = 1; i < n; i++) {
        out[i] = janet_array(1);
        janet_array_push(out[i - 1], janet_wrap_array(out[i]));
    }
    janet_gcunlock(handle);
}

/* The guard is exact, and where it stops is the contract. Marking a chain one
 * link longer than `JANET_RECURSION_GUARD` marks every link up to the limit and
 * roots the one after it -- rooting rather than recursing is what keeps the
 * traversal off the C stack, and rooting rather than dropping is what keeps the
 * rest of the graph from being collected. */
static void test_depth_guard_roots_the_overflow(void) {
    const int32_t n = JANET_RECURSION_GUARD + 2;
    JanetArray **chain = malloc(sizeof(JanetArray *) * (size_t) n);
    assert(chain != NULL);
    build_chain(n, chain);

    Janet head = janet_wrap_array(chain[0]);
    janet_gcroot(head);

    for (int32_t i = 0; i < n; i++) unmark(chain[i]);
    size_t roots = janet_vm.root_count;

    janet_mark(head);

    assert(janet_vm.root_count == roots + 1);
    assert(janet_unwrap_pointer(janet_vm.roots[roots]) == (void *) chain[JANET_RECURSION_GUARD]);
    assert(reachable(chain[JANET_RECURSION_GUARD - 1]));
    assert(!reachable(chain[JANET_RECURSION_GUARD]));
    assert(!reachable(chain[JANET_RECURSION_GUARD + 1]));

    /* Drop the root the guard added, then the chain itself. */
    janet_vm.root_count = roots;
    janet_gcunroot(head);
    free(chain);
}

/* What the guard defers, `janet_collect` finishes. The chain below is three
 * times the guard's depth, and the only reference to its last link is through
 * every link before it; if the drain loop stopped early or dropped what it
 * popped, the weak table would lose the entry in the sweep. */
static void test_collect_finishes_deep_graphs(void) {
    const int32_t n = 3 * JANET_RECURSION_GUARD;
    JanetArray **chain = malloc(sizeof(JanetArray *) * (size_t) n);
    assert(chain != NULL);
    build_chain(n, chain);

    Janet head = janet_wrap_array(chain[0]);
    janet_gcroot(head);

    JanetTable *witness = janet_table_weakv(2);
    Janet witness_v = janet_wrap_table(witness);
    janet_gcroot(witness_v);
    Janet key = janet_ckeywordv("tail");
    Janet tail = janet_wrap_array(chain[n - 1]);
    janet_table_put(witness, key, tail);

    size_t roots = janet_vm.root_count;
    janet_collect();

    assert(janet_vm.root_count == roots);
    assert(janet_equals(janet_table_get(witness, key), tail));

    janet_gcunroot(witness_v);
    janet_gcunroot(head);
    free(chain);
}

/* ------------------------------------------------------------- collection */

/* A root added while the collection is running is consumed by it: marked, and
 * removed. Only the roots that predate the collection survive it. */
static void test_collect_drains_roots_added_during_marking(void) {
    fresh_heap();

    void *a = janet_abstract(CONTRACT_AT(at_marked), 8);
    Janet abstract_v = janet_wrap_abstract(a);
    janet_gcroot(abstract_v);

    probe_child_value = janet_cstringv("marked by gcmark");
    probe_root_value = janet_cstringv("rooted by gcmark");
    probe_roots_on_mark = 1;
    probe_gcmark_calls = 0;
    probe_saw_mark_phase = -1;

    JanetTable *witness = janet_table_weakv(2);
    Janet witness_v = janet_wrap_table(witness);
    janet_gcroot(witness_v);
    Janet key = janet_ckeywordv("rooted");
    janet_table_put(witness, key, probe_root_value);

    size_t roots = janet_vm.root_count;
    janet_collect();

    assert(probe_gcmark_calls == 1);
    assert(janet_vm.root_count == roots);
    assert(janet_equals(janet_table_get(witness, key), probe_root_value));

    probe_roots_on_mark = 0;
    janet_gcunroot(witness_v);
    janet_gcunroot(abstract_v);
}

/* The flag is set for the duration of the traversal and clear once it is over.
 * A `gcmark` callback is the only thing that can see it set. */
static void test_collect_mark_phase_flag(void) {
    void *a = janet_abstract(CONTRACT_AT(at_marked), 8);
    Janet abstract_v = janet_wrap_abstract(a);
    janet_gcroot(abstract_v);
    probe_child_value = janet_wrap_nil();
    probe_saw_mark_phase = -1;

    assert(janet_vm.gc_mark_phase == 0);
    janet_collect();
    assert(probe_saw_mark_phase == 1);
    assert(janet_vm.gc_mark_phase == 0);

    janet_gcunroot(abstract_v);
}

/* A locked collector does nothing at all -- not even the bookkeeping at the end
 * of a collection, which is how the early return is told apart from a
 * collection that found nothing to do. */
static void test_collect_respects_the_lock(void) {
    fresh_heap();

    int handle = janet_gclock();
    janet_vm.next_collection = 4242;
    size_t blocks = janet_vm.block_count;

    janet_collect();

    assert(janet_vm.next_collection == 4242);
    assert(janet_vm.block_count == blocks);

    janet_gcunlock(handle);
    janet_collect();
    assert(janet_vm.next_collection == 0);
}

/* The interval heuristic keeps a large heap from being collected on every
 * allocation. It runs before the sweep, so it is sized by the block count going
 * in, and it only ever raises the interval. */
static void test_collect_interval_heuristic(void) {
    size_t saved = janet_vm.gc_interval;

    janet_vm.gc_interval = 0;
    size_t blocks = janet_vm.block_count;
    janet_collect();
    assert(janet_vm.gc_interval == blocks * sizeof(JanetGCObject));

    size_t high = SIZE_MAX / 2;
    janet_vm.gc_interval = high;
    janet_collect();
    assert(janet_vm.gc_interval == high);

    janet_vm.gc_interval = saved;
}

void gc_mark_contract(void) {
    janet_init();

    test_head_offsets();

    test_mark_immediates();
    test_mark_strings();
    test_mark_buffer();

    test_mark_array();
    test_mark_array_weak();

    test_mark_table_variants();
    test_mark_table_protos();

    test_mark_struct();
    test_mark_tuple();

    test_mark_abstract();
    test_mark_abstract_without_gcmark();

    test_mark_function();
    test_mark_fiber();
    test_mark_fiber_children();

    test_depth_guard_roots_the_overflow();
    test_collect_finishes_deep_graphs();

    test_collect_drains_roots_added_during_marking();
    test_collect_mark_phase_flag();
    test_collect_respects_the_lock();
    test_collect_interval_heuristic();

    janet_deinit();
    printf("gc mark contract ok\n");
}
