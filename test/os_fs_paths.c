/* Behavioral contract for directory enumeration, links, timestamps, and
 * canonical paths, run against whichever implementation the build selected
 * (`-Dos-fs-paths=c` or the Zig default).
 *
 * The link and directory kernels do not exist on Windows, where the public
 * functions panic or use the CRT's own enumeration, so those sections are
 * compiled only where the seam exists. */

#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <janet.h>

#ifdef JANET_WINDOWS
#include <direct.h>
#define make_dir(path) _mkdir(path)
#define drop_dir(path) _rmdir(path)
#else
#include <unistd.h>
#define make_dir(path) mkdir((path), 0777)
#define drop_dir(path) rmdir(path)
#endif

#ifndef JANET_WINDOWS
void *janet_os_dir_open(const char *path);
int32_t janet_os_dir_next(void *handle, const char **name);
void janet_os_dir_close(void *handle);
int32_t janet_os_link(const char *oldpath, const char *newpath);
#ifndef JANET_NO_SYMLINKS
int32_t janet_os_symlink(const char *oldpath, const char *newpath);
int64_t janet_os_readlink(const char *path, char *buffer, size_t size);
#endif
#endif
int32_t janet_os_touch(const char *path, int32_t has_times, double actime, double modtime);
#ifndef JANET_NO_REALPATH
char *janet_os_realpath(const char *path);
#endif

static const char direct_dir[] = "janet-zig-os-paths-direct-6b1d";
static const char direct_file[] = "janet-zig-os-paths-direct-6b1d/first";
static const char direct_other[] = "janet-zig-os-paths-direct-6b1d/second";
static const char direct_sub[] = "janet-zig-os-paths-direct-6b1d/inner";
static const char direct_hard[] = "janet-zig-os-paths-direct-6b1d/hard";
static const char direct_soft[] = "janet-zig-os-paths-direct-6b1d/soft";
static const char missing[] = "janet-zig-os-paths-absent-6b1d";

static const char public_dir[] = "janet-zig-os-paths-public-4f70";

static void make_file(const char *path) {
    FILE *file = fopen(path, "wb");
    assert(file != NULL);
    assert(fputs("path-contract", file) >= 0);
    assert(fclose(file) == 0);
}

static void clean_paths(void) {
    remove(direct_hard);
    remove(direct_soft);
    remove(direct_file);
    remove(direct_other);
    drop_dir(direct_sub);
    drop_dir(direct_dir);
    remove("janet-zig-os-paths-public-4f70/link");
    remove("janet-zig-os-paths-public-4f70/soft");
    remove("janet-zig-os-paths-public-4f70/file");
    drop_dir(public_dir);
}

#ifndef JANET_WINDOWS

/* Collect one directory listing, asserting that no entry repeats and that the
 * "." and ".." entries the C loop skipped are absent. */
static int32_t collect(const char *path, char names[16][256]) {
    int32_t count = 0;
    void *handle = janet_os_dir_open(path);
    assert(handle != NULL);
    for (;;) {
        const char *name = NULL;
        int32_t status = janet_os_dir_next(handle, &name);
        assert(status >= 0);
        if (status == 0) break;
        assert(name != NULL);
        assert(strcmp(name, "."));
        assert(strcmp(name, ".."));
        assert(strlen(name) < 256);
        assert(count < 16);
        for (int32_t i = 0; i < count; i++) assert(strcmp(names[i], name));
        snprintf(names[count], 256, "%s", name);
        count++;
    }
    janet_os_dir_close(handle);
    return count;
}

static int32_t index_of(char names[16][256], int32_t count, const char *name) {
    for (int32_t i = 0; i < count; i++) {
        if (!strcmp(names[i], name)) return i;
    }
    return -1;
}

static void test_directories(void) {
    char names[16][256];
    int32_t count;

    assert(make_dir(direct_dir) == 0);
    count = collect(direct_dir, names);
    assert(count == 0);

    make_file(direct_file);
    make_file(direct_other);
    assert(make_dir(direct_sub) == 0);

    count = collect(direct_dir, names);
    assert(count == 3);
    assert(index_of(names, count, "first") >= 0);
    assert(index_of(names, count, "second") >= 0);
    assert(index_of(names, count, "inner") >= 0);

    /* Names are the entry alone, with no directory prefix. */
    assert(index_of(names, count, direct_file) < 0);

    /* A second pass over the same directory produces the same set, so the
     * handle is not shared between iterations. */
    count = collect(direct_dir, names);
    assert(count == 3);

    /* Opening a missing directory reports failure through errno. */
    errno = 0;
    assert(janet_os_dir_open(missing) == NULL);
    assert(errno == ENOENT);

    /* Opening a file rather than a directory fails as well. Which error it
     * reports is the host's choice, so only the failure is pinned. */
    errno = 0;
    assert(janet_os_dir_open(direct_file) == NULL);
    assert(errno != 0);

    assert(drop_dir(direct_sub) == 0);
    assert(remove(direct_other) == 0);
}

static void test_links(void) {
    struct stat before, after;

    /* A hard link makes a second name for the same inode. */
    assert(janet_os_link(direct_file, direct_hard) == 0);
    assert(stat(direct_file, &before) == 0);
    assert(stat(direct_hard, &after) == 0);
    assert(before.st_ino == after.st_ino);
    assert(after.st_nlink == 2);

    /* Linking onto an existing name fails. */
    errno = 0;
    assert(janet_os_link(direct_file, direct_hard) == -1);
    assert(errno == EEXIST);

    /* Linking from a missing source fails. */
    errno = 0;
    assert(janet_os_link(missing, direct_soft) == -1);
    assert(errno == ENOENT);

    assert(remove(direct_hard) == 0);

#ifndef JANET_NO_SYMLINKS
    char buffer[256];
    int64_t len;

    assert(janet_os_symlink("first", direct_soft) == 0);

    /* readlink reports the stored target, without a terminating zero and
     * without resolving it. */
    memset(buffer, '@', sizeof buffer);
    len = janet_os_readlink(direct_soft, buffer, sizeof buffer);
    assert(len == 5);
    assert(!memcmp(buffer, "first", 5));
    assert(buffer[5] == '@');

    /* A buffer shorter than the target truncates rather than failing, which is
     * what the caller's "length reached the buffer size" check detects. */
    len = janet_os_readlink(direct_soft, buffer, 3);
    assert(len == 3);
    assert(!memcmp(buffer, "fir", 3));

    /* The link resolves for stat and does not for lstat. */
    assert(stat(direct_soft, &before) == 0);
    assert(lstat(direct_soft, &after) == 0);
    assert(before.st_ino != after.st_ino);

    /* Reading a link that is not one fails. */
    errno = 0;
    assert(janet_os_readlink(direct_file, buffer, sizeof buffer) == -1);
    assert(errno == EINVAL);

    errno = 0;
    assert(janet_os_symlink("first", direct_soft) == -1);
    assert(errno == EEXIST);

    assert(remove(direct_soft) == 0);
#endif
}

#endif /* JANET_WINDOWS */

static void test_timestamps(void) {
    struct stat info;

    /* Explicit times are set exactly. */
    assert(janet_os_touch(direct_file, 1, 1000000000.0, 1000000123.0) == 0);
    assert(stat(direct_file, &info) == 0);
    assert((int64_t) info.st_atime == 1000000000);
    assert((int64_t) info.st_mtime == 1000000123);

    /* A fractional second is truncated by the conversion, not rounded. */
    assert(janet_os_touch(direct_file, 1, 1000000200.75, 1000000200.75) == 0);
    assert(stat(direct_file, &info) == 0);
    assert((int64_t) info.st_mtime == 1000000200);

    /* Without times the host supplies the current time. */
    assert(janet_os_touch(direct_file, 0, 0, 0) == 0);
    assert(stat(direct_file, &info) == 0);
    assert((int64_t) info.st_mtime > 1672531200);

    errno = 0;
    assert(janet_os_touch(missing, 1, 1000000000.0, 1000000000.0) == -1);
    assert(errno == ENOENT);
}

#ifndef JANET_NO_REALPATH
static void test_realpath(void) {
    char *resolved = janet_os_realpath(direct_dir);
    assert(resolved != NULL);

    /* The result is absolute and ends with the directory's own name. */
    size_t len = strlen(resolved);
    size_t tail = strlen(direct_dir);
    assert(len > tail);
    assert(!strcmp(resolved + len - tail, direct_dir));
#ifdef JANET_WINDOWS
    assert(resolved[1] == ':');
#else
    assert(resolved[0] == '/');
#endif

    /* Redundant path segments are removed. */
    char indirect[512];
    snprintf(indirect, sizeof indirect, "./%s/../%s/.", direct_dir, direct_dir);
    char *again = janet_os_realpath(indirect);
    assert(again != NULL);
    assert(!strcmp(resolved, again));
    janet_free(again);
    janet_free(resolved);

#ifndef JANET_WINDOWS
    /* A missing path fails on POSIX; _fullpath instead succeeds and the public
     * function checks the result separately. */
    errno = 0;
    assert(janet_os_realpath(missing) == NULL);
    assert(errno == ENOENT);
#endif
}
#endif

static void run(JanetTable *env, const char *source) {
    Janet result;
    assert(janet_dostring(env, source, "os-fs-paths-contract", &result) == 0);
}

static void test_core_functions(void) {
    JanetTable *env = janet_core_env(NULL);

    run(env,
        "(os/mkdir \"janet-zig-os-paths-public-4f70\")\n"
        "(spit \"janet-zig-os-paths-public-4f70/file\" \"path-contract\")\n");

    /* os/dir lists entry names only, and appends to a supplied array. */
    run(env,
        "(def entries (os/dir \"janet-zig-os-paths-public-4f70\"))\n"
        "(assert (array? entries))\n"
        "(assert (= 1 (length entries)))\n"
        "(assert (= \"file\" (first entries)))\n"
        "(def supplied @[:kept])\n"
        "(def same (os/dir \"janet-zig-os-paths-public-4f70\" supplied))\n"
        "(assert (= same supplied))\n"
        "(assert (= 2 (length supplied)))\n"
        "(assert (= :kept (first supplied)))\n"
        "(assert (not (first (protect (os/dir \"janet-zig-os-paths-absent-6b1d\")))))\n");

#ifndef JANET_NO_SYMLINKS
    /* os/link makes a hard link by default and a symbolic link when asked;
     * os/symlink is the same as passing true. */
    run(env,
        "(os/link \"janet-zig-os-paths-public-4f70/file\" \"janet-zig-os-paths-public-4f70/link\")\n"
        "(assert (= 2 ((os/stat \"janet-zig-os-paths-public-4f70/link\") :nlink)))\n"
        "(os/symlink \"file\" \"janet-zig-os-paths-public-4f70/soft\")\n"
        "(assert (= :link ((os/lstat \"janet-zig-os-paths-public-4f70/soft\") :mode)))\n"
        "(assert (= :file ((os/stat \"janet-zig-os-paths-public-4f70/soft\") :mode)))\n"
        "(assert (= \"file\" (os/readlink \"janet-zig-os-paths-public-4f70/soft\")))\n"
        "(assert (not (first (protect (os/readlink \"janet-zig-os-paths-public-4f70/file\")))))\n"
        "(assert (not (first (protect (os/link \"janet-zig-os-paths-public-4f70/file\""
        " \"janet-zig-os-paths-public-4f70/link\")))))\n"
        "(os/rm \"janet-zig-os-paths-public-4f70/soft\")\n"
        "(os/rm \"janet-zig-os-paths-public-4f70/link\")\n");
#endif

    /* os/touch sets both times, defaults the modification time to the access
     * time, and defaults both to now. */
    run(env,
        "(os/touch \"janet-zig-os-paths-public-4f70/file\" 1000000000 1000000123)\n"
        "(def stats (os/stat \"janet-zig-os-paths-public-4f70/file\"))\n"
        "(assert (= 1000000000 (stats :accessed)))\n"
        "(assert (= 1000000123 (stats :modified)))\n"
        "(os/touch \"janet-zig-os-paths-public-4f70/file\" 1000000200)\n"
        "(def stats (os/stat \"janet-zig-os-paths-public-4f70/file\"))\n"
        "(assert (= 1000000200 (stats :accessed)))\n"
        "(assert (= 1000000200 (stats :modified)))\n"
        "(os/touch \"janet-zig-os-paths-public-4f70/file\")\n"
        "(assert (> ((os/stat \"janet-zig-os-paths-public-4f70/file\") :modified) 1672531200))\n"
        "(assert (not (first (protect (os/touch \"janet-zig-os-paths-absent-6b1d\")))))\n");

#ifndef JANET_NO_REALPATH
    run(env,
        "(assert (= (os/realpath \".\") (os/cwd)))\n"
        "(def resolved (os/realpath \"janet-zig-os-paths-public-4f70\"))\n"
        "(assert (string? resolved))\n"
        "(assert (= resolved (os/realpath \"./janet-zig-os-paths-public-4f70/.\")))\n"
        "(assert (not (first (protect (os/realpath \"janet-zig-os-paths-absent-6b1d\")))))\n");
#endif

    run(env,
        "(os/rm \"janet-zig-os-paths-public-4f70/file\")\n"
        "(os/rmdir \"janet-zig-os-paths-public-4f70\")\n");
}

int main(void) {
    clean_paths();

#ifndef JANET_WINDOWS
    test_directories();
    test_links();
#else
    assert(make_dir(direct_dir) == 0);
    make_file(direct_file);
#endif
    test_timestamps();
#ifndef JANET_NO_REALPATH
    test_realpath();
#endif

    janet_init();
    test_core_functions();
    janet_deinit();

    clean_paths();
    return 0;
}
