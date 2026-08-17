/* Behavioral contract for file-mode parsing and the stream host operations,
 * run against whichever implementation the build selected (`-Dio-core=c` or
 * the Zig default).
 *
 * The kernel section calls the seam directly, because the mode scanner reports
 * sandbox permissions and stop positions that the public `file/open` collapses
 * into a panic or a flag word. The public section then pins what a caller can
 * actually observe, including the repeated-flag handle recorded in FOUND.md. */

#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <janet.h>

#define JANET_IO_MODE_OK 0
#define JANET_IO_MODE_BAD_LENGTH 1
#define JANET_IO_MODE_BAD_FIRST 2
#define JANET_IO_MODE_BAD_LATER 3
#define JANET_IO_MODE_REPEATED 4

int32_t janet_io_scan_mode(const uint8_t *mode, int32_t len, int32_t *flags,
                           uint32_t *sandbox, int32_t *index);
int32_t janet_io_seek_whence(const uint8_t *key, int32_t len);
int32_t janet_io_mode_from_flags(int32_t flags, char *out);
void *janet_io_open(const char *path, const char *mode);
void *janet_io_temp(void);
int32_t janet_io_close(void *file);
int32_t janet_io_flush(void *file);
size_t janet_io_read(void *file, uint8_t *dest, size_t count);
int32_t janet_io_write(void *file, const uint8_t *src, size_t count);
int32_t janet_io_getc(void *file);
int32_t janet_io_putc(void *file, int32_t ch);
int32_t janet_io_error(void *file);
int32_t janet_io_setvbuf(void *file, size_t size);
int32_t janet_io_seek(void *file, int64_t offset, int32_t whence);
int64_t janet_io_tell(void *file);

static const char scratch[] = "janet-zig-io-core-9d24";
static const char missing[] = "janet-zig-io-core-absent-9d24";

static void clean_paths(void) {
    remove(scratch);
    remove("janet-zig-io-core-public-9d24");
}

/* A mode string is scanned as a whole; the caller reads back the flag word, the
 * permissions the accepted prefix implies, and where the scan stopped. */
static int32_t scan(const char *mode, int32_t *flags, uint32_t *sandbox, int32_t *index) {
    return janet_io_scan_mode((const uint8_t *) mode, (int32_t) strlen(mode),
                              flags, sandbox, index);
}

static void test_mode_scanning(void) {
    int32_t flags = 0;
    uint32_t sandbox = 0;
    int32_t index = 0;

    /* Each leading flag selects one access mode and one permission. */
    assert(scan("r", &flags, &sandbox, &index) == JANET_IO_MODE_OK);
    assert(flags == JANET_FILE_READ);
    assert(sandbox == JANET_SANDBOX_FS_READ);

    assert(scan("w", &flags, &sandbox, &index) == JANET_IO_MODE_OK);
    assert(flags == JANET_FILE_WRITE);
    assert(sandbox == JANET_SANDBOX_FS_WRITE);

    /* Appending asks for the whole filesystem permission, not just write. */
    assert(scan("a", &flags, &sandbox, &index) == JANET_IO_MODE_OK);
    assert(flags == JANET_FILE_APPEND);
    assert(sandbox == JANET_SANDBOX_FS);

    /* Trailing flags accumulate in any order and are independent. */
    assert(scan("wnb", &flags, &sandbox, &index) == JANET_IO_MODE_OK);
    assert(flags == (JANET_FILE_WRITE | JANET_FILE_NONIL | JANET_FILE_BINARY));
    assert(scan("wbn", &flags, &sandbox, &index) == JANET_IO_MODE_OK);
    assert(flags == (JANET_FILE_WRITE | JANET_FILE_NONIL | JANET_FILE_BINARY));

    /* An update flag adds the write permission even to a read mode. */
    assert(scan("r+", &flags, &sandbox, &index) == JANET_IO_MODE_OK);
    assert(flags == (JANET_FILE_READ | JANET_FILE_UPDATE));
    assert(sandbox == (JANET_SANDBOX_FS_READ | JANET_SANDBOX_FS_WRITE));

    /* The longest accepted mode is ten bytes; eleven is rejected on length
     * alone, before any byte is classified. */
    assert(scan("", &flags, &sandbox, &index) == JANET_IO_MODE_BAD_LENGTH);
    assert(sandbox == 0);
    assert(scan("rbnbnbnbnb", &flags, &sandbox, &index) == JANET_IO_MODE_REPEATED);
    assert(scan("qqqqqqqqqqq", &flags, &sandbox, &index) == JANET_IO_MODE_BAD_LENGTH);
    assert(sandbox == 0);

    /* An unusable first byte stops the scan before any permission accrues, so
     * the caller reports the bad flag rather than a sandbox violation. */
    assert(scan("q", &flags, &sandbox, &index) == JANET_IO_MODE_BAD_FIRST);
    assert(index == 0);
    assert(sandbox == 0);
    assert(scan("+", &flags, &sandbox, &index) == JANET_IO_MODE_BAD_FIRST);
    assert(scan("R", &flags, &sandbox, &index) == JANET_IO_MODE_BAD_FIRST);

    /* A later bad byte stops there, and the permissions of the prefix are
     * still reported, because the C loop asserted them on the way past. */
    assert(scan("rq", &flags, &sandbox, &index) == JANET_IO_MODE_BAD_LATER);
    assert(index == 1);
    assert(sandbox == JANET_SANDBOX_FS_READ);
    assert(scan("r+q", &flags, &sandbox, &index) == JANET_IO_MODE_BAD_LATER);
    assert(index == 2);
    assert(sandbox == (JANET_SANDBOX_FS_READ | JANET_SANDBOX_FS_WRITE));
    assert(scan("rq+", &flags, &sandbox, &index) == JANET_IO_MODE_BAD_LATER);
    assert(index == 1);
    assert(sandbox == JANET_SANDBOX_FS_READ);

    /* A repeated flag yields a flag word of -1, which the caller uses as a flag
     * word; see FOUND.md. */
    assert(scan("r++", &flags, &sandbox, &index) == JANET_IO_MODE_REPEATED);
    assert(flags == -1);
    assert(scan("rbb", &flags, &sandbox, &index) == JANET_IO_MODE_REPEATED);
    assert(flags == -1);
    assert(sandbox == JANET_SANDBOX_FS_READ);
    assert(scan("rnn", &flags, &sandbox, &index) == JANET_IO_MODE_REPEATED);
    assert(flags == -1);

    /* A repeat is detected across intervening flags, not only next to itself. */
    assert(scan("rbnb", &flags, &sandbox, &index) == JANET_IO_MODE_REPEATED);
    assert(flags == -1);

    /* A repeat stops the scan, so a bad byte after it is never reached. */
    assert(scan("rbbq", &flags, &sandbox, &index) == JANET_IO_MODE_REPEATED);
}

static void test_seek_whence(void) {
    /* The positions are the order the C if-chain tested, and the mapping to
     * the host's SEEK_* constants happens behind the seam. */
    assert(janet_io_seek_whence((const uint8_t *) "cur", 3) == 0);
    assert(janet_io_seek_whence((const uint8_t *) "set", 3) == 1);
    assert(janet_io_seek_whence((const uint8_t *) "end", 3) == 2);

    /* Only whole names match, as janet_cstrcmp required. */
    assert(janet_io_seek_whence((const uint8_t *) "cu", 2) == -1);
    assert(janet_io_seek_whence((const uint8_t *) "current", 7) == -1);
    assert(janet_io_seek_whence((const uint8_t *) "", 0) == -1);
    assert(janet_io_seek_whence((const uint8_t *) "CUR", 3) == -1);
}

static void test_mode_from_flags(void) {
    char out[4];

    /* Reading comes first, and appending replaces writing rather than joining
     * it, because a marshalled descriptor only needs a mode fdopen accepts. */
    assert(janet_io_mode_from_flags(JANET_FILE_READ, out) == 1);
    assert(!strcmp(out, "r"));
    assert(janet_io_mode_from_flags(JANET_FILE_WRITE, out) == 1);
    assert(!strcmp(out, "w"));
    assert(janet_io_mode_from_flags(JANET_FILE_APPEND, out) == 1);
    assert(!strcmp(out, "a"));
    assert(janet_io_mode_from_flags(JANET_FILE_READ | JANET_FILE_WRITE, out) == 2);
    assert(!strcmp(out, "rw"));
    assert(janet_io_mode_from_flags(JANET_FILE_READ | JANET_FILE_WRITE | JANET_FILE_APPEND, out) == 2);
    assert(!strcmp(out, "ra"));

    /* The binary, update, and no-nil flags are dropped, and an empty result is
     * still terminated. */
    assert(janet_io_mode_from_flags(JANET_FILE_READ | JANET_FILE_BINARY | JANET_FILE_UPDATE, out) == 1);
    assert(!strcmp(out, "r"));
    assert(janet_io_mode_from_flags(JANET_FILE_BINARY, out) == 0);
    assert(out[0] == '\0');
}

static void test_stream_operations(void) {
    void *file;
    uint8_t buffer[32];
    size_t nread;

    /* A missing file is reported by a null stream, not a panic. */
    assert(janet_io_open(missing, "rb") == NULL);

    file = janet_io_open(scratch, "wb");
    assert(file != NULL);

    /* A write is one item of n bytes, so success is 1 and the byte count is
     * not reported back. */
    assert(janet_io_write(file, (const uint8_t *) "hello", 5) == 1);
    assert(janet_io_putc(file, '\n') == '\n');
    assert(janet_io_write(file, (const uint8_t *) "second", 6) == 1);
    assert(janet_io_tell(file) == 12);
    assert(janet_io_flush(file) == 0);
    assert(janet_io_close(file) == 0);

    file = janet_io_open(scratch, "rb");
    assert(file != NULL);

    /* A short read is not an error; the caller distinguishes end of file from
     * failure with janet_io_error. */
    nread = janet_io_read(file, buffer, sizeof(buffer));
    assert(nread == 12);
    assert(janet_io_error(file) == 0);
    assert(!memcmp(buffer, "hello\nsecond", 12));
    nread = janet_io_read(file, buffer, sizeof(buffer));
    assert(nread == 0);
    assert(janet_io_error(file) == 0);

    /* Seeking uses the positions the whence lookup returns. */
    assert(janet_io_seek(file, 6, 1) == 0);
    assert(janet_io_tell(file) == 6);
    assert(janet_io_getc(file) == 's');
    assert(janet_io_seek(file, 2, 0) == 0);
    assert(janet_io_tell(file) == 9);
    assert(janet_io_seek(file, -3, 2) == 0);
    assert(janet_io_tell(file) == 9);
    assert(janet_io_getc(file) == 'o');

    /* Reading to the end returns EOF without setting the error indicator. */
    assert(janet_io_seek(file, 0, 2) == 0);
    assert(janet_io_getc(file) == EOF);
    assert(janet_io_error(file) == 0);
    assert(janet_io_close(file) == 0);

    /* Both buffering modes are accepted, and an unbuffered stream reaches the
     * filesystem without a flush. */
    file = janet_io_open(scratch, "wb");
    assert(file != NULL);
    assert(janet_io_setvbuf(file, 0) == 0);
    assert(janet_io_write(file, (const uint8_t *) "unbuffered", 10) == 1);
    {
        void *reader = janet_io_open(scratch, "rb");
        assert(reader != NULL);
        assert(janet_io_read(reader, buffer, sizeof(buffer)) == 10);
        assert(!memcmp(buffer, "unbuffered", 10));
        assert(janet_io_close(reader) == 0);
    }
    assert(janet_io_close(file) == 0);

    file = janet_io_open(scratch, "wb");
    assert(file != NULL);
    assert(janet_io_setvbuf(file, 4096) == 0);
    assert(janet_io_close(file) == 0);

    /* A temporary stream is readable and writable and needs no path. */
    file = janet_io_temp();
    assert(file != NULL);
    assert(janet_io_write(file, (const uint8_t *) "temp", 4) == 1);
    assert(janet_io_seek(file, 0, 1) == 0);
    assert(janet_io_read(file, buffer, sizeof(buffer)) == 4);
    assert(!memcmp(buffer, "temp", 4));
    assert(janet_io_close(file) == 0);

    remove(scratch);
}

static void run(JanetTable *env, const char *source) {
    Janet result;
    assert(janet_dostring(env, source, "io-core-contract", &result) == 0);
}

static void test_core_functions(void) {
    JanetTable *env = janet_core_env(NULL);

    /* A file opens, round-trips its contents, and reports positions. */
    run(env,
        "(def f (file/open \"janet-zig-io-core-public-9d24\" :wb))\n"
        "(file/write f \"first line\\n\" \"second\")\n"
        "(assert (= 17 (file/tell f)))\n"
        "(file/flush f)\n"
        "(file/close f)\n"
        "(def f (file/open \"janet-zig-io-core-public-9d24\" :rb))\n"
        "(assert (= \"first line\\n\" (string (file/read f :line))))\n"
        "(assert (= \"second\" (string (file/read f :all))))\n"
        "(assert (nil? (file/read f :line)))\n"
        "(file/close f)\n");

    /* Seeking accepts each origin keyword and rejects anything else. */
    run(env,
        "(def f (file/open \"janet-zig-io-core-public-9d24\" :rb))\n"
        "(file/seek f :set 11)\n"
        "(assert (= 11 (file/tell f)))\n"
        "(assert (= \"sec\" (string (file/read f 3))))\n"
        "(file/seek f :cur -3)\n"
        "(assert (= 11 (file/tell f)))\n"
        "(file/seek f :end -6)\n"
        "(assert (= 11 (file/tell f)))\n"
        "(assert (not (first (protect (file/seek f :middle 0)))))\n"
        "(file/close f)\n");

    /* Reading a byte count stops at the end of the file and then reports nil. */
    run(env,
        "(def f (file/open \"janet-zig-io-core-public-9d24\" :rb))\n"
        "(assert (= \"first line\\nsecond\" (string (file/read f 100))))\n"
        "(assert (nil? (file/read f 4)))\n"
        "(assert (= \"\" (string (file/read f :all))))\n"
        "(file/close f)\n");

    /* Appending preserves the existing contents; writing truncates. */
    run(env,
        "(def f (file/open \"janet-zig-io-core-public-9d24\" :ab))\n"
        "(file/write f \"!\")\n"
        "(file/close f)\n"
        "(assert (= \"first line\\nsecond!\" (string (slurp \"janet-zig-io-core-public-9d24\"))))\n"
        "(def f (file/open \"janet-zig-io-core-public-9d24\" :wb))\n"
        "(file/close f)\n"
        "(assert (= \"\" (string (slurp \"janet-zig-io-core-public-9d24\"))))\n");

    /* A closed file rejects every operation, and closing twice is harmless. */
    run(env,
        "(def f (file/open \"janet-zig-io-core-public-9d24\" :rb))\n"
        "(file/close f)\n"
        "(assert (nil? (file/close f)))\n"
        "(assert (not (first (protect (file/read f :all)))))\n"
        "(assert (not (first (protect (file/write f \"x\")))))\n"
        "(assert (not (first (protect (file/tell f)))))\n");

    /* A file opened for reading is not writeable, and one opened for writing
     * is not readable, unless the update flag is present. */
    run(env,
        "(def f (file/open \"janet-zig-io-core-public-9d24\" :rb))\n"
        "(assert (not (first (protect (file/write f \"x\")))))\n"
        "(assert (not (first (protect (file/flush f)))))\n"
        "(file/close f)\n"
        "(def f (file/open \"janet-zig-io-core-public-9d24\" :wb))\n"
        "(assert (not (first (protect (file/read f :all)))))\n"
        "(file/close f)\n"
        "(def f (file/open \"janet-zig-io-core-public-9d24\" :w+b))\n"
        "(file/write f \"update\")\n"
        "(file/seek f :set 0)\n"
        "(assert (= \"update\" (string (file/read f :all))))\n"
        "(file/close f)\n");

    /* A missing file is nil, or an error when the mode asks for one. */
    run(env,
        "(assert (nil? (file/open \"janet-zig-io-core-absent-9d24\" :r)))\n"
        "(assert (not (first (protect (file/open \"janet-zig-io-core-absent-9d24\" :rn)))))\n");

    /* Malformed modes are rejected by position, and each names the byte that
     * stopped the scan. */
    run(env,
        "(defn why [mode] (last (protect (file/open \"janet-zig-io-core-public-9d24\" mode))))\n"
        "(assert (string/has-prefix? \"file mode\" (why (keyword \"\"))))\n"
        "(assert (string/has-prefix? \"file mode\" (why :rbnbnbnbnbn)))\n"
        "(assert (= \"invalid flag q, expected w, a, or r\" (why :q)))\n"
        "(assert (= \"invalid flag +, expected w, a, or r\" (why (keyword \"+\"))))\n"
        "(assert (= \"invalid flag q, expected +, b, or n\" (why :rq)))\n"
        "(assert (= \"invalid flag q, expected +, b, or n\" (why :r+q)))\n");

    /* A repeated flag produces a handle with every flag bit set, which reports
     * itself as closed while its descriptor stays open. FOUND.md records this;
     * the port reproduces it rather than fixing it. */
    run(env,
        "(def f (file/open \"janet-zig-io-core-public-9d24\" :r++))\n"
        "(assert (= :core/file (type f)))\n"
        "(assert (not (first (protect (file/read f :all)))))\n"
        "(assert (nil? (file/close f)))\n");

    /* Supplying a buffer size replaces the requested mode with read-only and
     * skips the mode scan entirely, so a write mode neither truncates nor
     * writes and a nonsense mode is accepted. FOUND.md records this; it is
     * outside the seam, and the port leaves it alone. */
    run(env,
        "(spit \"janet-zig-io-core-public-9d24\" \"buffered\")\n"
        "(def f (file/open \"janet-zig-io-core-public-9d24\" :wb 8192))\n"
        "(assert (= :core/file (type f)))\n"
        "(assert (not (first (protect (file/write f \"x\")))))\n"
        "(assert (= \"buffered\" (string (file/read f :all))))\n"
        "(file/close f)\n"
        "(assert (= \"buffered\" (string (slurp \"janet-zig-io-core-public-9d24\"))))\n"
        "(def f (file/open \"janet-zig-io-core-public-9d24\" :zzz 0))\n"
        "(assert (= :core/file (type f)))\n"
        "(assert (= \"buffered\" (string (file/read f :all))))\n"
        "(file/close f)\n");

    /* file/temp is anonymous, readable, and writable. */
    run(env,
        "(def f (file/temp))\n"
        "(file/write f \"scratch\")\n"
        "(file/seek f :set 0)\n"
        "(assert (= \"scratch\" (string (file/read f :all))))\n"
        "(file/close f)\n");

    /* Printing to a file goes through the same write path, newline included. */
    run(env,
        "(def f (file/open \"janet-zig-io-core-public-9d24\" :wb))\n"
        "(xprint f \"printed\")\n"
        "(xprin f \"tail\")\n"
        "(xprinf f \"%d\" 42)\n"
        "(xprintf f \"%d\" 7)\n"
        "(file/close f)\n"
        "(assert (= \"printed\\ntail427\\n\" (string (slurp \"janet-zig-io-core-public-9d24\"))))\n");

    /* The scratch file is removed by clean_paths rather than os/rm, so this
     * contract still runs in a reduced-OS build. */
}

int main(void) {
    clean_paths();

    test_mode_scanning();
    test_seek_whence();
    test_mode_from_flags();
    test_stream_operations();

    janet_init();
    test_core_functions();
    janet_deinit();

    clean_paths();
    return 0;
}
