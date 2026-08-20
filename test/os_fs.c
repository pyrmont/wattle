/* Behavioral contract for basic filesystem host operations, run against
 * whichever implementation the build selected (`-Dos-fs=c` or the Zig
 * default). */

#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <janet.h>

#include "support.h"

int32_t janet_os_getcwd(char *buffer, int32_t size);
int32_t janet_os_mkdir(const char *path);
int32_t janet_os_rmdir(const char *path);
int32_t janet_os_chdir(const char *path);
int32_t janet_os_remove(const char *path);
int32_t janet_os_rename(const char *oldpath, const char *newpath);

static const char direct_dir[] = "janet-zig-os-fs-direct-83c2";
static const char direct_source[] = "janet-zig-os-fs-direct-83c2/source";
static const char direct_dest[] = "janet-zig-os-fs-direct-83c2/dest";
static const char public_dir[] = "janet-zig-os-fs-public-91af";
static const char public_source[] = "janet-zig-os-fs-public-91af/source";
static const char public_dest[] = "janet-zig-os-fs-public-91af/dest";

static void make_file(const char *path) {
    FILE *file = fopen(path, "wb");
    assert(file != NULL);
    assert(fputs("filesystem-contract", file) >= 0);
    assert(fclose(file) == 0);
}

static void clean_paths(void) {
    (void) janet_os_remove(direct_source);
    (void) janet_os_remove(direct_dest);
    (void) janet_os_rmdir(direct_dir);
    (void) janet_os_remove(public_source);
    (void) janet_os_remove(public_dest);
    (void) janet_os_rmdir(public_dir);
}

static void test_kernels(const char *original) {
    char inside[FILENAME_MAX];

    assert(janet_os_mkdir(direct_dir) == 0);
    errno = 0;
    assert(janet_os_mkdir(direct_dir) == -1);
    assert(errno == EEXIST);

    assert(janet_os_chdir(direct_dir) == 0);
    assert(janet_os_getcwd(inside, FILENAME_MAX) == 0);
    assert(strcmp(inside, original));
    make_file("source");
    assert(janet_os_chdir(original) == 0);

    assert(janet_os_rename(direct_source, direct_dest) == 0);
    assert(janet_os_remove(direct_dest) == 0);
    assert(janet_os_rmdir(direct_dir) == 0);
}

static void test_core_functions(const char *original) {
    JanetCFunction cwd_fn = janet_unwrap_cfunction(janet_resolve_core("os/cwd"));
    JanetCFunction mkdir_fn = janet_unwrap_cfunction(janet_resolve_core("os/mkdir"));
    JanetCFunction rmdir_fn = janet_unwrap_cfunction(janet_resolve_core("os/rmdir"));
    JanetCFunction cd_fn = janet_unwrap_cfunction(janet_resolve_core("os/cd"));
    JanetCFunction rename_fn = janet_unwrap_cfunction(janet_resolve_core("os/rename"));
    JanetCFunction remove_fn = janet_unwrap_cfunction(janet_resolve_core("os/rm"));
    Janet args[2];
    Janet result;

    result = janet_contract_call_cfunction(cwd_fn, 0, NULL);
    assert(janet_checktype(result, JANET_STRING));
    assert(!janet_cstrcmp(janet_unwrap_string(result), original));

    args[0] = janet_cstringv(public_dir);
    assert(janet_unwrap_boolean(janet_contract_call_cfunction(mkdir_fn, 1, args)));
    assert(!janet_unwrap_boolean(janet_contract_call_cfunction(mkdir_fn, 1, args)));
    assert(janet_checktype(janet_contract_call_cfunction(cd_fn, 1, args), JANET_NIL));
    make_file("source");

    args[0] = janet_cstringv(original);
    assert(janet_checktype(janet_contract_call_cfunction(cd_fn, 1, args), JANET_NIL));

    args[0] = janet_cstringv(public_source);
    args[1] = janet_cstringv(public_dest);
    assert(janet_checktype(janet_contract_call_cfunction(rename_fn, 2, args), JANET_NIL));
    args[0] = args[1];
    assert(janet_checktype(janet_contract_call_cfunction(remove_fn, 1, args), JANET_NIL));
    args[0] = janet_cstringv(public_dir);
    assert(janet_checktype(janet_contract_call_cfunction(rmdir_fn, 1, args), JANET_NIL));
}

void os_fs_contract(void) {
    char original[FILENAME_MAX];

    assert(janet_os_getcwd(original, FILENAME_MAX) == 0);
    clean_paths();
    test_kernels(original);

    janet_init();
    test_core_functions(original);
    janet_deinit();

    assert(janet_os_chdir(original) == 0);
    clean_paths();
}
