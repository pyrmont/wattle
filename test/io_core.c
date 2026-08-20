/* Behavioral contract for `src/core/io.c` -- file-mode parsing, the stream host
 * operations, the `core/file` abstract type, the public `JanetFile` entry
 * points, and the cfunction surface over all of them -- run against whichever
 * implementation the build selected (`-Dio-core=c` or the Zig default).
 *
 * The kernel section calls the seam directly, because the mode scanner reports
 * sandbox permissions and stop positions that the public `file/open` collapses
 * into a panic or a flag word. The public section then pins what a caller can
 * actually observe, including the repeated-flag handle recorded in FOUND.md.
 *
 * Three things here are unreachable from Janet and are the reason this file
 * exists at all rather than the suite covering it. The eight `JanetFile` entry
 * points are C API with no Janet spelling; the abstract type's `marshal` and
 * `unmarshal` callbacks run only under `JANET_MARSHAL_UNSAFE`, which
 * `(marshal f)` never sets; and `janet_dynprintf` is a C variadic. Phase 10's
 * acceptance list asks for the C face and the Zig face of a converted symbol
 * to be tested separately, and for this subsystem the C face is most of the
 * surface area. */

#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "features.h"
#include <janet.h>

#include "support.h"
#include "state.h"

/* Catch a raise from a C caller. Both mechanisms end here while any C caller
 * remains: a Zig implementation returns an error, its C face turns that back
 * into the jump this scope established. */
static int panics_fired = 0;
/* Six, not seven: `test_dynprintf`'s "file is not writeable" case moved to
 * `test/pp_format.zig` with its subject in Phase 10 Part 18. */
#define EXPECTED_PANICS 6

/* The message is checked, not just the fact of a raise. Part 10 recorded that
 * `assert-error` names the test rather than the text, so three mutations
 * inside message literals survived a whole sweep; a contract that only asks
 * "did it raise" has the same hole. */
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
    if ((text) != NULL) { \
        assert(janet_checktype(_state.payload, JANET_STRING)); \
        assert(!janet_cstrcmp(janet_unwrap_string(_state.payload), (text))); \
    } \
    panics_fired++; \
} while (0)

#define EXPECT_PANIC(expr) EXPECT_PANIC_MSG(expr, NULL)

/* For the one message that carries an address: `%v` renders a core/file by
 * pointer, so only the fixed part can be compared -- and the fixed part is
 * exactly what distinguishes it from the message the other branch produces. */
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

/* Call a core cfunction by name, so that a path no Janet program can construct
 * an argument for can still be driven through the cfunction that owns it. */
static Janet call_core(const char *name, int32_t argc, Janet *argv) {
    Janet fun = janet_resolve_core(name);
    assert(janet_checktype(fun, JANET_CFUNCTION));
    return janet_contract_call_cfunction(janet_unwrap_cfunction(fun), argc, argv);
}

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


/* ------------------------------------------------------ the abstract type */

static void test_abstract_type(void) {
    /* The callback set is part of the type's contract: `core/file` has a
     * finalizer, a method getter, a marshal pair and a key walker, and nothing
     * else. A `tostring` in particular would change how every file prints. */
    assert(!strcmp(janet_file_type.name, "core/file"));
    assert(janet_file_type.gc != NULL);
    assert(janet_file_type.gcmark == NULL);
    assert(janet_file_type.get != NULL);
    assert(janet_file_type.put == NULL);
    assert(janet_file_type.marshal != NULL);
    assert(janet_file_type.unmarshal != NULL);
    assert(janet_file_type.tostring == NULL);
    assert(janet_file_type.compare == NULL);
    assert(janet_file_type.hash == NULL);
    assert(janet_file_type.next != NULL);
    assert(janet_file_type.call == NULL);
    assert(janet_file_type.length == NULL);
    assert(janet_file_type.bytes == NULL);
}

/* The method table is scanned linearly and walked in order, so its order is
 * observable through `next` and is part of the contract rather than a
 * tidiness; Part 7 found the same thing about the parser's table. */
static void test_method_order(void) {
    static const char *const expected[] = {
        "close", "flush", "read", "seek", "tell", "write", NULL
    };
    Janet key = janet_wrap_nil();
    int i = 0;
    for (;;) {
        key = janet_contract_at_next(&janet_file_type, NULL, key);
        if (janet_checktype(key, JANET_NIL)) break;
        assert(expected[i] != NULL);
        assert(!janet_cstrcmp(janet_unwrap_keyword(key), expected[i]));
        i++;
    }
    assert(expected[i] == NULL);

    /* The getter answers only keywords, and only names in the table. */
    Janet out = janet_wrap_nil();
    assert(janet_contract_at_get(&janet_file_type, NULL, janet_ckeywordv("read"), &out) == 1);
    assert(janet_checktype(out, JANET_CFUNCTION));
    assert(janet_contract_at_get(&janet_file_type, NULL, janet_ckeywordv("open"), &out) == 0);
    assert(janet_contract_at_get(&janet_file_type, NULL, janet_cstringv("read"), &out) == 0);
}

/* ----------------------------------------------------------- the C API */

static void test_public_api(void) {
    FILE *raw = fopen(scratch, "wb");
    assert(raw != NULL);

    /* janet_makejfile hands back the payload; janet_makefile wraps it. The
     * buffer size is the C library's default, which is what `file/open`
     * compares against to decide whether a caller asked for another one. */
    JanetFile *jf = janet_makejfile(raw, JANET_FILE_WRITE);
    assert(jf->file == raw);
    assert(jf->flags == JANET_FILE_WRITE);
    assert(jf->vbufsize == BUFSIZ);

    Janet wrapped = janet_wrap_abstract(jf);
    assert(janet_checkfile(wrapped) == jf);
    assert(janet_checkfile(janet_wrap_nil()) == NULL);
    assert(janet_checkfile(janet_wrap_integer(3)) == NULL);

    int32_t flags = 0;
    assert(janet_unwrapfile(wrapped, &flags) == raw);
    assert(flags == JANET_FILE_WRITE);
    assert(janet_unwrapfile(wrapped, NULL) == raw);

    Janet argv[1] = { wrapped };
    assert(janet_getjfile(argv, 0) == jf);
    flags = 0;
    assert(janet_getfile(argv, 0, &flags) == raw);
    assert(flags == JANET_FILE_WRITE);
    assert(janet_getfile(argv, 0, NULL) == raw);

    /* Closing marks the payload and clears the stream, so a later use is a
     * null dereference rather than a use-after-free. A second close is a
     * no-op, and so is closing a file this runtime only borrowed. */
    assert(janet_file_close(jf) == 0);
    assert(jf->flags & JANET_FILE_CLOSED);
    assert(jf->file == NULL);
    assert(janet_file_close(jf) == 0);

    JanetFile *borrowed = janet_makejfile(stdout, JANET_FILE_APPEND | JANET_FILE_NOT_CLOSEABLE);
    assert(janet_file_close(borrowed) == 0);
    assert(!(borrowed->flags & JANET_FILE_CLOSED));
    assert(borrowed->file == stdout);

    /* A value of the wrong type is an argument fault rather than a null. */
    Janet bad[1] = { janet_wrap_integer(3) };
    EXPECT_PANIC(janet_getjfile(bad, 0));
    EXPECT_PANIC(janet_getfile(bad, 0, NULL));

    remove(scratch);
}

static void test_dynfile(void) {
    /* Outside a fiber the dynamic bindings live in the VM's top-level table,
     * which is what lets this run without one. */
    assert(janet_dynfile("io-core-out", stdout) == stdout);
    assert(janet_dynfile("io-core-out", NULL) == NULL);

    /* Anything that is not a core/file falls back to the default, including
     * another abstract type. */
    janet_setdyn("io-core-out", janet_wrap_integer(3));
    assert(janet_dynfile("io-core-out", stderr) == stderr);
    janet_setdyn("io-core-out", janet_wrap_abstract(janet_abstract(&janet_rng_type, sizeof(JanetRNG))));
    assert(janet_dynfile("io-core-out", stderr) == stderr);

    JanetFile *jf = janet_makejfile(stdout, JANET_FILE_APPEND | JANET_FILE_NOT_CLOSEABLE);
    janet_setdyn("io-core-out", janet_wrap_abstract(jf));
    assert(janet_dynfile("io-core-out", stderr) == stdout);
    janet_setdyn("io-core-out", janet_wrap_nil());
}

/* --------------------------------------------------------- marshalling */

/* A file marshals only under JANET_MARSHAL_UNSAFE, which no Janet caller can
 * ask for, so the whole callback pair is C-only. */
static void test_marshalling(void) {
    FILE *raw = fopen(scratch, "wb");
    assert(raw != NULL);
    Janet file = janet_wrap_abstract(janet_makejfile(raw, JANET_FILE_WRITE));

    JanetBuffer *buf = janet_buffer(0);
    EXPECT_PANIC_MSG(janet_marshal(buf, file, NULL, 0), "cannot marshal file in safe mode");

    buf->count = 0;
    janet_marshal(buf, file, NULL, JANET_MARSHAL_UNSAFE);
    assert(buf->count > 0);

    /* Reading it back in safe mode is refused by the other half of the pair. */
    EXPECT_PANIC_MSG(janet_unmarshal(buf->data, buf->count, 0, NULL, NULL), "cannot unmarshal file in safe mode");

    Janet back = janet_unmarshal(buf->data, buf->count, JANET_MARSHAL_UNSAFE, NULL, NULL);
    JanetFile *copy = janet_checkfile(back);
    assert(copy != NULL);
    assert(copy->flags == JANET_FILE_WRITE);
    assert(copy->vbufsize == BUFSIZ);

    /* The descriptor was duplicated, because the original owns its stream, so
     * the copy is a different FILE * on the same file and closing one leaves
     * the other usable. */
    assert(copy->file != raw);
    assert(janet_file_close(copy) == 0);
    assert(janet_io_write(raw, (const uint8_t *) "kept", 4) == 1);
    assert(janet_file_close(janet_checkfile(file)) == 0);
    remove(scratch);
}

/* ------------------------------------------------------- janet_dynprintf */

/* `test_dynprintf` stood here and is in `test/pp_format.zig` now. Part 18
 * deleted the C variadic and `dynprintf` moved to `pp_format.zig`, beside the
 * other three entry points that surface used to hold; its format string is a
 * `comptime` parameter, so the caller instantiates it and no C contract can
 * reach it. What it asserts -- the four destinations a dynamic binding can
 * name -- is unchanged, and it is the same file that now asserts the message
 * those destinations receive. */

/* ------------------------------------- what only a mismatched handle reaches */

/* A `JanetFile`'s flags and its stream can disagree, which nothing in Janet can
 * arrange and which is the only way into two of the failure paths. Both are
 * reachable by an embedder, since `janet_makejfile` takes the flag word from
 * its caller and never consults the stream. */
static void test_mismatched_handles(void) {
    void *writer = janet_io_open(scratch, "wb");
    assert(writer != NULL);
    Janet claims_readable = janet_wrap_abstract(
        janet_makejfile((FILE *) writer, JANET_FILE_READ));

    /* The readability check passes on the flags and `fread` then fails, which
     * is the branch that separates a short read from a broken one. */
    Janet read_args[2] = { claims_readable, janet_wrap_integer(10) };
    EXPECT_PANIC_MSG(call_core("file/read", 2, read_args), "could not read file");
    assert(janet_file_close(janet_checkfile(claims_readable)) == 0);

    void *reader = janet_io_open(scratch, "rb");
    assert(reader != NULL);
    Janet claims_writeable = janet_wrap_abstract(
        janet_makejfile((FILE *) reader, JANET_FILE_WRITE));

    /* `xprint` has no default handle, so a failed write names the destination
     * rather than reporting a bare byte count. */
    Janet print_args[2] = { claims_writeable, janet_wrap_string(janet_cstring("text")) };
    EXPECT_PANIC_PREFIX(call_core("xprint", 2, print_args), "cannot print 4 bytes to ");
    assert(janet_file_close(janet_checkfile(claims_writeable)) == 0);

    remove(scratch);
}

/* --------------------------------- the buffer size survives a marshal */

/* The recorded buffer size is restored by a real `setvbuf` on the way back in,
 * which is only visible if it is not the default: an unbuffered stream reaches
 * the filesystem with no flush and a buffered one does not. */
static void test_marshalled_buffer_size(void) {
    void *stream = janet_io_open(scratch, "wb");
    assert(stream != NULL);
    JanetFile *jf = janet_makejfile((FILE *) stream, JANET_FILE_WRITE);
    jf->vbufsize = 0;
    Janet file = janet_wrap_abstract(jf);

    JanetBuffer *buf = janet_buffer(0);
    janet_marshal(buf, file, NULL, JANET_MARSHAL_UNSAFE);
    JanetFile *copy = janet_checkfile(
        janet_unmarshal(buf->data, buf->count, JANET_MARSHAL_UNSAFE, NULL, NULL));
    assert(copy != NULL);
    assert(copy->vbufsize == 0);

    assert(janet_io_write(copy->file, (const uint8_t *) "now", 3) == 1);
    {
        uint8_t seen[8];
        void *check = janet_io_open(scratch, "rb");
        assert(check != NULL);
        assert(janet_io_read(check, seen, sizeof(seen)) == 3);
        assert(!memcmp(seen, "now", 3));
        assert(janet_io_close(check) == 0);
    }
    assert(janet_file_close(copy) == 0);
    assert(janet_file_close(jf) == 0);
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
        "(assert (= \"file mode must have a length between 1 and 10\" (why (keyword \"\"))))\n"
        "(assert (= \"file mode must have a length between 1 and 10\" (why :rbnbnbnbnbn)))\n"
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

void io_core_contract(void) {
    clean_paths();

    test_mode_scanning();
    test_seek_whence();
    test_mode_from_flags();
    test_stream_operations();

    janet_init();
    /* The abstract type has to be in the registry before anything marshals a
     * file, and the registration is `janet_lib_io`'s. Building the core
     * environment first is also what the public section needs, and it is
     * memoized, so the two share one. */
    janet_core_env(NULL);
    test_abstract_type();
    test_method_order();
    test_public_api();
    test_dynfile();
    test_marshalling();
    test_marshalled_buffer_size();
    test_mismatched_handles();
    test_core_functions();
    assert(panics_fired == EXPECTED_PANICS);
    janet_deinit();

    clean_paths();
}
