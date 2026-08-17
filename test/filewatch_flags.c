/* Behavioral contract for the file watcher's keyword vocabularies, run against
 * whichever implementation the build selected (`-Dfilewatch-flags=c` or the Zig
 * default).
 *
 * All three backends' names are asserted here on every target. In `filewatch.c`
 * each table sat inside the `#ifdef` for its own backend, so on any one host the
 * other two were not merely unreachable but uncompiled — a typo in the Windows
 * vocabulary could survive every Linux and macOS build indefinitely. Nothing
 * about a name is host-specific, so all three are compiled and checked
 * everywhere now.
 *
 * Only the names moved. Every flag's *value* is a host constant — `IN_ATTRIB`,
 * `FILE_NOTIFY_CHANGE_SIZE`, `NOTE_EXTEND` — and stays in `filewatch.c` beside
 * the backend that uses it, so this file asserts the order and membership of
 * the vocabularies rather than any mask arithmetic. The two halves are one
 * table split down the middle: the index reported here is what selects a value
 * there, which is why the order below is a contract and not a convenience.
 */

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <janet.h>

/* Declared rather than included from src/core/filewatch.c, so the contract
 * depends only on the internal ABI it exercises. A compile-time assertion in
 * that file pins the ordinals below to the macros they mirror, and the same
 * values are the `Platform` enumeration in the Zig subsystem. */
enum {
    PLATFORM_LINUX = 0,
    PLATFORM_WINDOWS = 1,
    PLATFORM_KQUEUE = 2
};

extern int32_t janet_filewatch_flag_index(uint32_t platform, const uint8_t *name, int32_t len);
extern int32_t janet_filewatch_flag_count(uint32_t platform);
extern const char *janet_filewatch_flag_name(uint32_t platform, int32_t index);
extern const char *janet_filewatch_action_name(int32_t action);

/* The keyword arrives as bytes and a length, never as a C string: a Janet
 * keyword is length-prefixed and may contain a zero byte. */
static int32_t index_of(uint32_t platform, const char *name) {
    return janet_filewatch_flag_index(platform, (const uint8_t *) name, (int32_t) strlen(name));
}

/* The vocabularies, in the order both halves of the split agree on. */
static const char *const linux_names[] = {
    "access", "all", "attrib", "close-nowrite", "close-write", "create",
    "delete", "delete-self", "ignored", "modify", "move-self", "moved-from",
    "moved-to", "open", "q-overflow", "unmount",
};

static const char *const windows_names[] = {
    "all", "attributes", "creation", "dir-name", "file-name", "last-access",
    "last-write", "recursive", "security", "size",
};

static const char *const kqueue_names[] = {
    "all", "attrib", "close", "close-write", "delete", "extend", "funlock",
    "link", "open", "read", "rename", "revoke", "truncate", "write",
};

static const char *const action_names[] = {
    "unknown", "added", "removed", "modified", "renamed-old", "renamed-new",
};

#define COUNT_OF(a) ((int32_t)(sizeof(a) / sizeof((a)[0])))

static void test_each_vocabulary_is_complete(void) {
    assert(janet_filewatch_flag_count(PLATFORM_LINUX) == COUNT_OF(linux_names));
    assert(janet_filewatch_flag_count(PLATFORM_WINDOWS) == COUNT_OF(windows_names));
    assert(janet_filewatch_flag_count(PLATFORM_KQUEUE) == COUNT_OF(kqueue_names));
}

/* The index is what selects a flag value in `filewatch.c`, so a name that moved
 * would silently decode to a different flag. Pinning both directions is what
 * keeps the two halves of the table from drifting apart. */
static void test_names_hold_their_positions(void) {
    for (int32_t i = 0; i < COUNT_OF(linux_names); i++) {
        assert(index_of(PLATFORM_LINUX, linux_names[i]) == i);
        assert(0 == strcmp(janet_filewatch_flag_name(PLATFORM_LINUX, i), linux_names[i]));
    }
    for (int32_t i = 0; i < COUNT_OF(windows_names); i++) {
        assert(index_of(PLATFORM_WINDOWS, windows_names[i]) == i);
        assert(0 == strcmp(janet_filewatch_flag_name(PLATFORM_WINDOWS, i), windows_names[i]));
    }
    for (int32_t i = 0; i < COUNT_OF(kqueue_names); i++) {
        assert(index_of(PLATFORM_KQUEUE, kqueue_names[i]) == i);
        assert(0 == strcmp(janet_filewatch_flag_name(PLATFORM_KQUEUE, i), kqueue_names[i]));
    }
}

/* The original searched each table with `janet_strbinsearch`, which required it
 * to be sorted. Neither implementation depends on that now, but a table that
 * stopped being sorted would mean the port and the original disagreed about
 * which entries were reachable at all. */
static void test_each_vocabulary_is_ascending(void) {
    for (int32_t i = 1; i < COUNT_OF(linux_names); i++) {
        assert(strcmp(linux_names[i - 1], linux_names[i]) < 0);
    }
    for (int32_t i = 1; i < COUNT_OF(windows_names); i++) {
        assert(strcmp(windows_names[i - 1], windows_names[i]) < 0);
    }
    for (int32_t i = 1; i < COUNT_OF(kqueue_names); i++) {
        assert(strcmp(kqueue_names[i - 1], kqueue_names[i]) < 0);
    }
}

static void test_a_name_belongs_only_to_its_own_backend(void) {
    assert(index_of(PLATFORM_LINUX, "recursive") < 0);
    assert(index_of(PLATFORM_LINUX, "last-write") < 0);
    assert(index_of(PLATFORM_WINDOWS, "attrib") < 0);
    assert(index_of(PLATFORM_WINDOWS, "modify") < 0);
    assert(index_of(PLATFORM_KQUEUE, "modify") < 0);
    assert(index_of(PLATFORM_KQUEUE, "creation") < 0);

    /* `all` is the one name every backend shares. */
    assert(index_of(PLATFORM_LINUX, "all") >= 0);
    assert(index_of(PLATFORM_WINDOWS, "all") >= 0);
    assert(index_of(PLATFORM_KQUEUE, "all") >= 0);
}

static void test_a_partial_or_extended_name_matches_nothing(void) {
    assert(index_of(PLATFORM_LINUX, "acces") < 0);
    assert(index_of(PLATFORM_LINUX, "accessx") < 0);
    assert(index_of(PLATFORM_LINUX, "") < 0);
    assert(index_of(PLATFORM_KQUEUE, "close-writ") < 0);
    assert(index_of(PLATFORM_KQUEUE, "close-writes") < 0);
}

/* A Janet keyword may hold a zero byte, so the comparison is by length and
 * bytes rather than by terminator. Such a keyword matches nothing. */
static void test_a_name_containing_a_zero_byte_matches_nothing(void) {
    static const uint8_t trailing[] = { 'a', 'l', 'l', 0 };
    static const uint8_t embedded[] = { 'a', 0, 'l', 'l' };
    assert(janet_filewatch_flag_index(PLATFORM_LINUX, trailing, 4) < 0);
    assert(janet_filewatch_flag_index(PLATFORM_LINUX, embedded, 4) < 0);
    /* The same bytes without the zero still match. */
    assert(janet_filewatch_flag_index(PLATFORM_LINUX, trailing, 3) >= 0);
}

static void test_an_unknown_backend_reports_rather_than_indexes(void) {
    assert(index_of(3, "all") < 0);
    assert(janet_filewatch_flag_count(3) < 0);
    assert(janet_filewatch_flag_name(3, 0) == NULL);
}

static void test_an_out_of_range_position_reports(void) {
    assert(janet_filewatch_flag_name(PLATFORM_LINUX, -1) == NULL);
    assert(janet_filewatch_flag_name(PLATFORM_LINUX, COUNT_OF(linux_names)) == NULL);
    assert(janet_filewatch_flag_name(PLATFORM_WINDOWS, COUNT_OF(windows_names)) == NULL);
    assert(janet_filewatch_flag_name(PLATFORM_KQUEUE, COUNT_OF(kqueue_names)) == NULL);
    assert(janet_filewatch_flag_index(PLATFORM_LINUX, (const uint8_t *) "all", -1) < 0);
}

/* The C original indexed a six-entry array with Windows' `FILE_ACTION_*` code
 * and had nothing to say about a code beyond it. Both implementations report
 * NULL there instead, which is what lets `filewatch.c` name the fallback
 * explicitly rather than read past the array. */
static void test_action_names_cover_the_documented_codes(void) {
    for (int32_t code = 0; code < COUNT_OF(action_names); code++) {
        const char *got = janet_filewatch_action_name(code);
        assert(got != NULL);
        assert(0 == strcmp(got, action_names[code]));
    }
    assert(janet_filewatch_action_name(-1) == NULL);
    assert(janet_filewatch_action_name(COUNT_OF(action_names)) == NULL);
}

int main(void) {
    test_each_vocabulary_is_complete();
    test_names_hold_their_positions();
    test_each_vocabulary_is_ascending();
    test_a_name_belongs_only_to_its_own_backend();
    test_a_partial_or_extended_name_matches_nothing();
    test_a_name_containing_a_zero_byte_matches_nothing();
    test_an_unknown_backend_reports_rather_than_indexes();
    test_an_out_of_range_position_reports();
    test_action_names_cover_the_documented_codes();

    printf("filewatch_flags: all tests passed\n");
    return 0;
}
