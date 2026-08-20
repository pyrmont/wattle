/* Behavioral contract for the file metadata kernels behind `os/stat` and
 * `os/lstat`, run against whichever implementation the build selected
 * (`-Dos-stat=c` or the Zig default). */

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <janet.h>

#ifdef JANET_WINDOWS
#include <direct.h>
#else
#include <unistd.h>
#endif

const char *janet_os_mode_name(uint32_t mode);
int32_t janet_os_decode_permissions(uint32_t mode);
int32_t janet_os_perm_to_unix(uint32_t mode);
uint32_t janet_os_perm_from_unix(int32_t permissions);
int32_t janet_os_stat_field_count(void);
const char *janet_os_stat_field_name(int32_t index);
int32_t janet_os_stat_field_lookup(const uint8_t *key, int32_t len);

/* The registry's order is also the field identifier the C getters switch on,
 * so both are pinned here. */
static const char *const expected_fields[] = {
    "dev",
    "inode",
    "mode",
    "int-permissions",
    "permissions",
    "uid",
    "gid",
    "nlink",
    "rdev",
    "size",
    "blocks",
    "blocksize",
    "accessed",
    "modified",
    "changed"
};

static const char work_dir[] = "janet-zig-os-stat-4d71";
static const char work_file[] = "janet-zig-os-stat-4d71/file";
static const char work_link[] = "janet-zig-os-stat-4d71/link";

static void expect_mode_name(uint32_t mode, const char *expected) {
    assert(!strcmp(janet_os_mode_name(mode), expected));
}

static void test_mode_names(void) {
#ifdef JANET_WINDOWS
    /* The CRT has no S_IS* macros, and Janet tests the three type bits
     * individually rather than masking first. */
    expect_mode_name(_S_IFREG | 0666, "file");
    expect_mode_name(_S_IFDIR | 0777, "directory");
    expect_mode_name(_S_IFCHR, "character");
    expect_mode_name(0, "other");
    expect_mode_name(0644, "other");
#else
    expect_mode_name(S_IFREG | 0644, "file");
    expect_mode_name(S_IFDIR | 0755, "directory");
    expect_mode_name(S_IFCHR | 0666, "character");
    expect_mode_name(0, "other");
    expect_mode_name(0777, "other");
#ifndef JANET_PLAN9
    expect_mode_name(S_IFIFO | 0644, "fifo");
    expect_mode_name(S_IFBLK | 0644, "block");
    expect_mode_name(S_IFSOCK | 0644, "socket");
    expect_mode_name(S_IFLNK | 0777, "link");
#endif
#endif
}

static void test_permission_bits(void) {
#ifdef JANET_WINDOWS
    assert(janet_os_decode_permissions(_S_IFREG | 0777) == (S_IEXEC | S_IWRITE | S_IREAD));
    assert(janet_os_perm_to_unix(S_IREAD) == 0444);
    assert(janet_os_perm_to_unix(S_IWRITE) == 0222);
    assert(janet_os_perm_to_unix(S_IEXEC) == 0111);
    assert(janet_os_perm_to_unix(S_IREAD | S_IWRITE | S_IEXEC) == 0777);
    /* Windows collapses user, group, and other, so only the reduced value
     * round-trips. */
    assert(janet_os_perm_to_unix(janet_os_perm_from_unix(0777)) == 0777);
#else
    /* Type bits and the setuid/setgid/sticky field are dropped. */
    assert(janet_os_decode_permissions(S_IFREG | 0754) == 0754);
    assert(janet_os_decode_permissions(S_IFDIR | 07777) == 0777);
    assert(janet_os_decode_permissions(0) == 0);

    /* The portable value and the host's mode agree on Unix. */
    for (int32_t mode = 0; mode <= 0777; mode++) {
        assert(janet_os_perm_to_unix((uint32_t) mode) == mode);
        assert(janet_os_perm_from_unix(mode) == (uint32_t) mode);
        assert(janet_os_perm_to_unix(janet_os_perm_from_unix(mode)) == mode);
    }
#endif
}

static void test_field_registry(void) {
    int32_t count = janet_os_stat_field_count();
    assert(count == (int32_t)(sizeof(expected_fields) / sizeof(expected_fields[0])));

    for (int32_t index = 0; index < count; index++) {
        const char *name = janet_os_stat_field_name(index);
        assert(name != NULL);
        assert(!strcmp(name, expected_fields[index]));
        assert(janet_os_stat_field_lookup((const uint8_t *) name, (int32_t) strlen(name)) == index);
    }

    /* Out-of-range indices report absence rather than reading past the table. */
    assert(janet_os_stat_field_name(-1) == NULL);
    assert(janet_os_stat_field_name(count) == NULL);

    /* Lookup matches whole names only. */
    assert(janet_os_stat_field_lookup((const uint8_t *) "de", 2) == -1);
    assert(janet_os_stat_field_lookup((const uint8_t *) "device", 6) == -1);
    assert(janet_os_stat_field_lookup((const uint8_t *) "", 0) == -1);
    assert(janet_os_stat_field_lookup((const uint8_t *) "dev", -1) == -1);
    assert(janet_os_stat_field_lookup((const uint8_t *) "Dev", 3) == -1);
    assert(janet_os_stat_field_lookup((const uint8_t *) "int-permission", 14) == -1);

    /* `janet_cstrcmp`, which this lookup replaced, stops at a NUL the key and
     * the name share, so a key whose own bytes end in NUL still matches. That
     * quirk is preserved deliberately. */
    assert(janet_os_stat_field_lookup((const uint8_t *) "dev\0", 4) == 0);
}

static void run(JanetTable *env, const char *source) {
    Janet result;
    assert(janet_dostring(env, source, "os-stat-contract", &result) == 0);
}

static void test_core_functions(void) {
    JanetTable *env = janet_core_env(NULL);

    run(env,
        "(os/mkdir \"janet-zig-os-stat-4d71\")\n"
        "(spit \"janet-zig-os-stat-4d71/file\" \"0123456789\")\n"
        "(os/chmod \"janet-zig-os-stat-4d71/file\" 8r640)\n");

    /* A whole-table result carries every registry field, in the registry's
     * own names. */
    run(env,
        "(def st (os/stat \"janet-zig-os-stat-4d71/file\"))\n"
        "(assert (table? st))\n"
        "(assert (= 15 (length st)))\n"
        "(each key [:dev :inode :mode :int-permissions :permissions :uid :gid\n"
        "           :nlink :rdev :size :blocks :blocksize :accessed :modified :changed]\n"
        "  (assert (not= nil (st key))))\n");

    /* Classification, size, and both permission projections. */
    run(env,
        "(def st (os/stat \"janet-zig-os-stat-4d71/file\"))\n"
        "(assert (= :file (st :mode)))\n"
        "(assert (= 10 (st :size)))\n"
        "(assert (= :directory (get (os/stat \"janet-zig-os-stat-4d71\") :mode)))\n");
#ifndef JANET_WINDOWS
    run(env,
        "(def st (os/stat \"janet-zig-os-stat-4d71/file\"))\n"
        "(assert (= 8r640 (st :int-permissions)))\n"
        "(assert (= \"rw-r-----\" (st :permissions)))\n");
#endif

    /* A keyword selects one field; an unknown keyword raises. */
    run(env,
        "(assert (= :file (os/stat \"janet-zig-os-stat-4d71/file\" :mode)))\n"
        "(assert (= 10 (os/stat \"janet-zig-os-stat-4d71/file\" :size)))\n"
        "(assert (= :directory (os/stat \"janet-zig-os-stat-4d71\" :mode)))\n"
        "(assert (not (first (protect (os/stat \"janet-zig-os-stat-4d71/file\" :nope)))))\n"
        "(assert (not (first (protect (os/stat \"janet-zig-os-stat-4d71/file\" :de)))))\n");

    /* A supplied table is filled and returned. */
    run(env,
        "(def tab @{:seed true})\n"
        "(assert (= tab (os/stat \"janet-zig-os-stat-4d71/file\" tab)))\n"
        "(assert (= 16 (length tab)))\n"
        "(assert (= :file (tab :mode)))\n");

    /* A missing path is nil rather than an error. */
    run(env, "(assert (nil? (os/stat \"janet-zig-os-stat-4d71/missing\")))\n");

#if !defined(JANET_WINDOWS) && !defined(JANET_NO_SYMLINKS)
    /* `os/lstat` reports the link itself, `os/stat` its target. */
    run(env,
        "(os/symlink \"file\" \"janet-zig-os-stat-4d71/link\")\n"
        "(assert (= :link (os/lstat \"janet-zig-os-stat-4d71/link\" :mode)))\n"
        "(assert (= :file (os/stat \"janet-zig-os-stat-4d71/link\" :mode)))\n"
        "(assert (= 10 (os/stat \"janet-zig-os-stat-4d71/link\" :size)))\n");
#endif
}

static void clean_paths(void) {
    (void) remove(work_link);
    (void) remove(work_file);
#ifdef JANET_WINDOWS
    (void) _rmdir(work_dir);
#else
    (void) rmdir(work_dir);
#endif
}

void os_stat_contract(void) {
    test_mode_names();
    test_permission_bits();
    test_field_registry();

    clean_paths();
    janet_init();
    test_core_functions();
    janet_deinit();
    clean_paths();
}
