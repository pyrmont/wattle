#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "features.h"
#include <janet.h>

#include "support.h"
#include "util.h"
#include "state.h"

/* Phase 10 Part 17f. The half of `src/core/util.c` that owns VM state.
 *
 * Most of this subsystem is reachable from Janet source and is covered by
 * `port/probe-17/util-remainder.janet`, which is diffed between the two arms of
 * `-Dregistry`. What is here is what only a C caller can reach: the registry's
 * own ordering and growth, the four registration entry points as an embedder
 * calls them, `janet_binding_from_entry` on entries the compiler would never
 * build, and the two `janet_core_*` forms.
 *
 * Written against `-Dregistry=c` first, per `AGENTS.md`: "A test written
 * against new Zig code and only ever run there proves the code matches
 * itself." */

/* ------------------------------------------------------------ the registry */

static Janet probe_one(int32_t argc, Janet *argv) {
    (void) argc;
    (void) argv;
    return janet_wrap_integer(1);
}

static Janet probe_two(int32_t argc, Janet *argv) {
    (void) argc;
    (void) argv;
    return janet_wrap_integer(2);
}

static Janet probe_three(int32_t argc, Janet *argv) {
    (void) argc;
    (void) argv;
    return janet_wrap_integer(3);
}

static Janet probe_unregistered(int32_t argc, Janet *argv) {
    (void) argc;
    (void) argv;
    return janet_wrap_nil();
}

static void test_registry(void) {
    JanetCFunRegistry *found;
    size_t before = janet_vm.registry_count;

    janet_register("probe/one", probe_one);
    janet_register("probe/two", probe_two);
    janet_register("probe/three", probe_three);
    assert(janet_vm.registry_count == before + 3);

    /* Registration marks the array dirty; the first lookup sorts it. */
    assert(janet_vm.registry_dirty);
    found = janet_registry_get(probe_two);
    assert(!janet_vm.registry_dirty);
    assert(found != NULL);
    assert(found->cfun == probe_two);
    assert(!strcmp(found->name, "probe/two"));
    /* janet_register passes no prefix and no source location. */
    assert(found->name_prefix == NULL);
    assert(found->source_file == NULL);
    assert(found->source_line == 0);

    found = janet_registry_get(probe_one);
    assert(found != NULL && found->cfun == probe_one);
    found = janet_registry_get(probe_three);
    assert(found != NULL && found->cfun == probe_three);

    /* A cfunction that was never registered answers NULL rather than a
     * neighbouring row, which is the case `doframe` in `debug.c` dereferences
     * without checking -- `FOUND.md` has that one. */
    assert(janet_registry_get(probe_unregistered) == NULL);

    /* The sort is by pointer and the whole array is ordered by it, not just
     * the rows this contract added. That is what the bisection in
     * `janet_registry_get` is written against, and it holds even though the
     * linear scan above it means the bisection never runs. */
    for (size_t i = 1; i < janet_vm.registry_count; i++) {
        assert((void *)(janet_vm.registry[i - 1].cfun) <=
               (void *)(janet_vm.registry[i].cfun));
    }

    /* Registering the same pointer twice appends a second row rather than
     * replacing the first. Reproduced from C: nothing dedupes. */
    before = janet_vm.registry_count;
    janet_register("probe/one-again", probe_one);
    assert(janet_vm.registry_count == before + 1);
    found = janet_registry_get(probe_one);
    assert(found != NULL && found->cfun == probe_one);
}

/* Growth. The floor is 512 entries, which the core alone does not reach, so
 * this is the only place the doubling is exercised at all. */
static Janet filler(int32_t argc, Janet *argv) {
    (void) argc;
    (void) argv;
    return janet_wrap_nil();
}

static void test_registry_growth(void) {
    size_t cap = janet_vm.registry_cap;
    size_t count = janet_vm.registry_count;
    /* Every row needs a distinct key, and the key is a function pointer, so
     * the keys have to come from somewhere. Offsetting into a table of
     * distinct pointers is not available in portable C; instead push the
     * *same* pointer, which still grows the array. The lookup contract above
     * is what checks distinct keys. */
    while (janet_vm.registry_count < cap + 1) {
        janet_registry_put(filler, "probe/filler", NULL, NULL, 0);
    }
    assert(janet_vm.registry_cap > cap);
    assert(janet_vm.registry_count > count);
    /* The new capacity is (count + 1) * 2 at the moment of the growth, with a
     * floor of 512. Whatever it is, it must leave room for what is there. */
    assert(janet_vm.registry_cap >= janet_vm.registry_count);
}

/* ------------------------------------------------- the registration entries */

static const JanetReg probe_reg[] = {
    {"one", probe_one, "the first"},
    {"two", probe_two, NULL},
    {NULL, NULL, NULL}
};

static const JanetRegExt probe_reg_ext[] = {
    {"three", probe_three, "the third", "probe.c", 42},
    {NULL, NULL, NULL, NULL, 0}
};

/* The entry a def builds: a table with :value, and :doc and :source-map only
 * when there is something to put in them. */
static void check_entry(JanetTable *env, const char *name, int has_doc, int has_map) {
    Janet entry = janet_table_get(env, janet_csymbolv(name));
    JanetTable *t;
    assert(janet_checktype(entry, JANET_TABLE));
    t = janet_unwrap_table(entry);
    assert(janet_checktype(janet_table_get(t, janet_ckeywordv("value")), JANET_CFUNCTION));
    assert(janet_checktype(janet_table_get(t, janet_ckeywordv("doc")), JANET_NIL) != has_doc);
    assert(janet_checktype(janet_table_get(t, janet_ckeywordv("source-map")), JANET_NIL) != has_map);
}

static void test_cfuns(void) {
    JanetTable *env = janet_table(4);

    janet_cfuns(env, "probe", probe_reg);
    check_entry(env, "one", 1, 0);
    /* A NULL docstring means no :doc key at all rather than a nil value. */
    check_entry(env, "two", 0, 0);

    janet_cfuns_ext(env, "probe", probe_reg_ext);
    check_entry(env, "three", 1, 1);
    {
        Janet entry = janet_table_get(env, janet_csymbolv("three"));
        Janet map = janet_table_get(janet_unwrap_table(entry), janet_ckeywordv("source-map"));
        const Janet *tup;
        assert(janet_checktype(map, JANET_TUPLE));
        tup = janet_unwrap_tuple(map);
        assert(janet_length(map) == 3);
        assert(!janet_cstrcmp(janet_unwrap_string(tup[0]), "probe.c"));
        assert(janet_unwrap_integer(tup[1]) == 42);
        assert(janet_unwrap_integer(tup[2]) == 1);
    }

    /* The registry got the *unprefixed* name and the prefix separately, for
     * all four entry points. The prefix only changes the binding's name. */
    assert(!strcmp(janet_registry_get(probe_three)->name, "three"));
    assert(!strcmp(janet_registry_get(probe_three)->name_prefix, "probe"));
}

static void test_cfuns_prefix(void) {
    JanetTable *env = janet_table(4);

    janet_cfuns_prefix(env, "pre", probe_reg);
    check_entry(env, "pre/one", 1, 0);
    check_entry(env, "pre/two", 0, 0);
    assert(janet_checktype(janet_table_get(env, janet_csymbolv("one")), JANET_NIL));

    janet_cfuns_ext_prefix(env, "pre", probe_reg_ext);
    check_entry(env, "pre/three", 1, 1);

    /* A prefix long enough that the name buffer's 256-byte reserve is not
     * what carries it, so the realloc in `namebuf_name` is exercised. */
    {
        char big[400];
        char expected[420];
        JanetTable *env2 = janet_table(4);
        memset(big, 'p', sizeof(big) - 1);
        big[sizeof(big) - 1] = '\0';
        janet_cfuns_prefix(env2, big, probe_reg);
        snprintf(expected, sizeof(expected), "%s/one", big);
        check_entry(env2, expected, 1, 0);
    }

    /* A NULL environment registers without defining, and must not build a
     * name buffer at all. Every entry point takes it. */
    janet_cfuns(NULL, "probe", probe_reg);
    janet_cfuns_ext(NULL, "probe", probe_reg_ext);
    janet_cfuns_prefix(NULL, "probe", probe_reg);
    janet_cfuns_ext_prefix(NULL, "probe", probe_reg_ext);
}

/* ----------------------------------------------------------- def and var */

static void test_def_and_var(void) {
    JanetTable *env = janet_table(4);
    Janet entry;
    JanetTable *t;

    janet_def(env, "d", janet_wrap_integer(7), "doc for d");
    entry = janet_table_get(env, janet_csymbolv("d"));
    t = janet_unwrap_table(entry);
    assert(janet_unwrap_integer(janet_table_get(t, janet_ckeywordv("value"))) == 7);
    assert(janet_checktype(janet_table_get(t, janet_ckeywordv("ref")), JANET_NIL));

    janet_var(env, "v", janet_wrap_integer(8), NULL);
    entry = janet_table_get(env, janet_csymbolv("v"));
    t = janet_unwrap_table(entry);
    /* A var's value is in a one-element array under :ref, and there is no
     * :value key at all. */
    assert(janet_checktype(janet_table_get(t, janet_ckeywordv("value")), JANET_NIL));
    {
        Janet ref = janet_table_get(t, janet_ckeywordv("ref"));
        JanetArray *a;
        assert(janet_checktype(ref, JANET_ARRAY));
        a = janet_unwrap_array(ref);
        assert(a->count == 1);
        assert(janet_unwrap_integer(a->data[0]) == 8);
    }

    /* A source line of zero suppresses the map even when the file is given,
     * because the file alone locates nothing. */
    janet_def_sm(env, "nomap", janet_wrap_nil(), NULL, "f.c", 0);
    t = janet_unwrap_table(janet_table_get(env, janet_csymbolv("nomap")));
    assert(janet_checktype(janet_table_get(t, janet_ckeywordv("source-map")), JANET_NIL));

    janet_var_sm(env, "vmap", janet_wrap_nil(), NULL, "f.c", 9);
    t = janet_unwrap_table(janet_table_get(env, janet_csymbolv("vmap")));
    assert(!janet_checktype(janet_table_get(t, janet_ckeywordv("source-map")), JANET_NIL));
}

/* ------------------------------------------------------ reading a binding */

static JanetBinding binding_of(JanetTable *entry) {
    return janet_binding_from_entry(janet_wrap_table(entry));
}

static void test_binding_from_entry(void) {
    JanetTable *entry;
    JanetBinding b;

    /* Anything that is not a table is NONE with a nil value. */
    b = janet_binding_from_entry(janet_wrap_nil());
    assert(b.type == JANET_BINDING_NONE);
    assert(janet_checktype(b.value, JANET_NIL));
    assert(b.deprecation == JANET_BINDING_DEP_NONE);
    b = janet_binding_from_entry(janet_wrap_integer(3));
    assert(b.type == JANET_BINDING_NONE);

    /* A plain def. */
    entry = janet_table(2);
    janet_table_put(entry, janet_ckeywordv("value"), janet_wrap_integer(1));
    b = binding_of(entry);
    assert(b.type == JANET_BINDING_DEF);
    assert(janet_unwrap_integer(b.value) == 1);

    /* A ref makes it a var, and the binding's value is the array rather than
     * its contents -- dereferencing is `janet_resolve`'s job. */
    entry = janet_table(2);
    janet_table_put(entry, janet_ckeywordv("ref"), janet_wrap_array(janet_array(1)));
    b = binding_of(entry);
    assert(b.type == JANET_BINDING_VAR);
    assert(janet_checktype(b.value, JANET_ARRAY));

    /* :redef only means anything with a valid ref. */
    entry = janet_table(2);
    janet_table_put(entry, janet_ckeywordv("value"), janet_wrap_integer(1));
    janet_table_put(entry, janet_ckeywordv("redef"), janet_wrap_true());
    b = binding_of(entry);
    assert(b.type == JANET_BINDING_DEF);

    entry = janet_table(2);
    janet_table_put(entry, janet_ckeywordv("ref"), janet_wrap_array(janet_array(1)));
    janet_table_put(entry, janet_ckeywordv("redef"), janet_wrap_true());
    b = binding_of(entry);
    assert(b.type == JANET_BINDING_DYNAMIC_DEF);

    /* A macro, and the dynamic macro the same :redef produces. */
    entry = janet_table(2);
    janet_table_put(entry, janet_ckeywordv("value"), janet_wrap_integer(1));
    janet_table_put(entry, janet_ckeywordv("macro"), janet_wrap_true());
    b = binding_of(entry);
    assert(b.type == JANET_BINDING_MACRO);
    assert(janet_unwrap_integer(b.value) == 1);

    entry = janet_table(3);
    janet_table_put(entry, janet_ckeywordv("value"), janet_wrap_integer(1));
    janet_table_put(entry, janet_ckeywordv("ref"), janet_wrap_array(janet_array(1)));
    janet_table_put(entry, janet_ckeywordv("redef"), janet_wrap_true());
    janet_table_put(entry, janet_ckeywordv("macro"), janet_wrap_true());
    b = binding_of(entry);
    assert(b.type == JANET_BINDING_DYNAMIC_MACRO);
    assert(janet_checktype(b.value, JANET_ARRAY));

    /* A macro with a ref but no :redef keeps the plain :value, which is the
     * one combination where the two keys disagree about which is read. */
    entry = janet_table(3);
    janet_table_put(entry, janet_ckeywordv("value"), janet_wrap_integer(5));
    janet_table_put(entry, janet_ckeywordv("ref"), janet_wrap_array(janet_array(1)));
    janet_table_put(entry, janet_ckeywordv("macro"), janet_wrap_true());
    b = binding_of(entry);
    assert(b.type == JANET_BINDING_MACRO);
    assert(janet_unwrap_integer(b.value) == 5);
}

static void test_deprecation(void) {
    JanetTable *entry;
    JanetBinding b;
    struct {
        const char *kw;
        int expect;
    } cases[] = {
        {"relaxed", JANET_BINDING_DEP_RELAXED},
        {"normal", JANET_BINDING_DEP_NORMAL},
        {"strict", JANET_BINDING_DEP_STRICT},
        /* An unrecognised keyword is NONE, not NORMAL: the keyword arm runs
         * and matches nothing, and the field keeps its initial value. */
        {"nonsense", JANET_BINDING_DEP_NONE},
    };
    size_t i;

    for (i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        entry = janet_table(2);
        janet_table_put(entry, janet_ckeywordv("value"), janet_wrap_nil());
        janet_table_put(entry, janet_ckeywordv("deprecated"), janet_ckeywordv(cases[i].kw));
        b = binding_of(entry);
        assert(b.deprecation == cases[i].expect);
    }

    /* A non-keyword that is not nil is NORMAL, whatever it is -- including
     * `false`, which is not nil. */
    entry = janet_table(2);
    janet_table_put(entry, janet_ckeywordv("value"), janet_wrap_nil());
    janet_table_put(entry, janet_ckeywordv("deprecated"), janet_wrap_false());
    b = binding_of(entry);
    assert(b.deprecation == JANET_BINDING_DEP_NORMAL);

    entry = janet_table(2);
    janet_table_put(entry, janet_ckeywordv("value"), janet_wrap_nil());
    janet_table_put(entry, janet_ckeywordv("deprecated"), janet_wrap_integer(1));
    b = binding_of(entry);
    assert(b.deprecation == JANET_BINDING_DEP_NORMAL);
}

/* ---------------------------------------------------------- resolution */

static void test_resolve(void) {
    JanetTable *env = janet_table(4);
    Janet out = janet_wrap_true();
    JanetArray *ref = janet_array(1);
    JanetTable *entry;

    /* An unbound symbol answers NONE and writes nil, rather than leaving the
     * caller's value alone. */
    assert(janet_resolve(env, janet_csymbol("missing"), &out) == JANET_BINDING_NONE);
    assert(janet_checktype(out, JANET_NIL));

    janet_def(env, "d", janet_wrap_integer(3), NULL);
    assert(janet_resolve(env, janet_csymbol("d"), &out) == JANET_BINDING_DEF);
    assert(janet_unwrap_integer(out) == 3);

    /* A plain var resolves to the ref *array*, not to its contents: only the
     * two dynamic types are dereferenced. So `janet_resolve` and
     * `janet_resolve_ext` agree here, and differ only below. */
    janet_var(env, "v", janet_wrap_integer(4), NULL);
    assert(janet_resolve(env, janet_csymbol("v"), &out) == JANET_BINDING_VAR);
    assert(janet_checktype(out, JANET_ARRAY));
    assert(janet_unwrap_integer(janet_unwrap_array(out)->data[0]) == 4);
    assert(janet_checktype(janet_resolve_ext(env, janet_csymbol("v")).value, JANET_ARRAY));

    /* A dynamic def dereferences to the array's last element. */
    janet_array_push(ref, janet_wrap_integer(5));
    entry = janet_table(2);
    janet_table_put(entry, janet_ckeywordv("ref"), janet_wrap_array(ref));
    janet_table_put(entry, janet_ckeywordv("redef"), janet_wrap_true());
    janet_table_put(env, janet_csymbolv("dd"), janet_wrap_table(entry));
    assert(janet_resolve(env, janet_csymbol("dd"), &out) == JANET_BINDING_DYNAMIC_DEF);
    assert(janet_unwrap_integer(out) == 5);
    janet_array_push(ref, janet_wrap_integer(6));
    assert(janet_resolve(env, janet_csymbol("dd"), &out) == JANET_BINDING_DYNAMIC_DEF);
    assert(janet_unwrap_integer(out) == 6);
}

static void test_core_resolution(void) {
    /* `janet_resolve_core` and `janet_get_core_table` reach the core
     * environment rather than one the caller built. */
    Janet f = janet_resolve_core("string/find");
    assert(janet_checktype(f, JANET_CFUNCTION));
    assert(janet_checktype(janet_resolve_core("no-such-binding-17f"), JANET_NIL));

    assert(janet_get_core_table("module/cache") != NULL);
    assert(janet_get_core_table("no-such-binding-17f") == NULL);
    /* Bound, but not to a table. */
    assert(janet_get_core_table("string/find") == NULL);
}

/* -------------------------------------------------- the abstract registry */

static const JanetAbstractType probe_at = {
    "registry/probe", NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL
};

static const JanetAbstractType probe_at_same_name = {
    "registry/probe", NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL
};

static void test_abstract_registry(void) {
    janet_register_abstract_type(CONTRACT_AT(probe_at));
    assert(janet_get_abstract_type(janet_csymbolv("registry/probe")) == CONTRACT_AT(probe_at));

    /* Registering the same type twice is a no-op rather than an error. */
    janet_register_abstract_type(CONTRACT_AT(probe_at));
    assert(janet_get_abstract_type(janet_csymbolv("registry/probe")) == CONTRACT_AT(probe_at));

    /* An unregistered name answers NULL, which is what `janet_unmarshal`
     * turns into "unknown abstract type". */
    assert(janet_get_abstract_type(janet_csymbolv("registry/never")) == NULL);
    assert(janet_get_abstract_type(janet_wrap_nil()) == NULL);

    /* A *different* type under a name already taken raises. This is the one
     * raise in what was `util.c`, and the reason `janet_register_abstract_type`
     * has a C face over an error-returning implementation. */
    {
        JanetTryState tstate;
        janet_try_init(&tstate);
        janet_contract_arm();
            janet_register_abstract_type(CONTRACT_AT(probe_at_same_name));
        if (janet_contract_raised()) {
            assert(janet_contract_signal() == JANET_SIGNAL_ERROR);
            assert(janet_checktype(tstate.payload, JANET_STRING));
            assert(strstr((const char *)janet_unwrap_string(tstate.payload),
                          "a type with the same name exists") != NULL);
        } else {
            assert(0 && "expected a panic");
        }
        janet_restore(&tstate);
    }

    /* The failed registration left the first type in place. */
    assert(janet_get_abstract_type(janet_csymbolv("registry/probe")) == CONTRACT_AT(probe_at));
}

/* ------------------------------------------------------ text substitution */

static void test_text_substitution(void) {
    Janet subst;
    JanetByteView view;
    static const uint8_t matched[] = {'a', 'b'};

    /* A value that is already bytes is used as-is, and the caller's slot is
     * left alone. */
    subst = janet_cstringv("X");
    view = janet_text_substitution(&subst, matched, 2, NULL);
    assert(view.len == 1 && view.bytes[0] == 'X');
    assert(janet_checktype(subst, JANET_STRING));

    /* A value that is not bytes is printed once and the caller's slot is
     * *overwritten* with the string, which is what "memoize" means here: the
     * second call must see a string rather than print again. */
    subst = janet_wrap_integer(42);
    view = janet_text_substitution(&subst, matched, 2, NULL);
    assert(view.len == 2 && !memcmp(view.bytes, "42", 2));
    assert(janet_checktype(subst, JANET_STRING));
    view = janet_text_substitution(&subst, matched, 2, NULL);
    assert(view.len == 2 && !memcmp(view.bytes, "42", 2));

    /* A cfunction is called with the matched text. */
    subst = janet_wrap_cfunction(janet_unwrap_cfunction(janet_resolve_core("string/ascii-upper")));
    view = janet_text_substitution(&subst, matched, 2, NULL);
    assert(view.len == 2 && !memcmp(view.bytes, "AB", 2));
    /* The slot is *not* memoized for a callable: it must be called again for
     * the next match. */
    assert(janet_checktype(subst, JANET_CFUNCTION));

    /* A raising cfunction. Since Part 17e a builtin records its raise and
     * returns, and this is the fourth place in the tree that invokes a
     * cfunction pointer -- the one 17e's count of three missed. Without the
     * test the raise is carried past this frame. */
    {
        JanetTryState tstate;
        janet_try_init(&tstate);
        janet_contract_arm();
            Janet finder = janet_resolve_core("string/find");
        janet_text_substitution(&finder, matched, 2, NULL);
        if (janet_contract_raised()) {
            assert(janet_contract_signal() == JANET_SIGNAL_ERROR);
            assert(strstr((const char *)janet_unwrap_string(tstate.payload),
                          "arity mismatch") != NULL);
        } else {
            assert(0 && "expected a panic");
        }
        janet_restore(&tstate);
    }

    /* Extra captures are appended after the matched text. `string/slice` with
     * a start index proves the second argument arrived. */
    {
        JanetArray *extra = janet_array(1);
        static const uint8_t four[] = {'a', 'b', 'c', 'd'};
        janet_array_push(extra, janet_wrap_integer(2));
        subst = janet_resolve_core("string/slice");
        view = janet_text_substitution(&subst, four, 4, extra);
        assert(view.len == 2 && !memcmp(view.bytes, "cd", 2));
    }
}

/* ------------------------------------------------------------------ entry */

void registry_contract(void) {
    janet_init();

    test_registry();
    test_registry_growth();
    test_cfuns();
    test_cfuns_prefix();
    test_def_and_var();
    test_binding_from_entry();
    test_deprecation();
    test_resolve();
    test_core_resolution();
    test_abstract_registry();
    test_text_substitution();

    janet_deinit();
    printf("registry contract ok\n");
}
