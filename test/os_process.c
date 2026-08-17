/* Behavioral contract for the process control kernels and host operations, run
 * against whichever implementation the build selected (`-Dos-process=c` or the
 * Zig default).
 *
 * The kernel section calls the seam directly. Command-line escaping has no
 * caller outside Windows, the signal lookup reports a position that
 * `os/proc-kill` turns into a panic, and the wait classification is collapsed
 * into a single number before Janet sees it, so none of the three can be
 * observed from the public functions alone. The public section then pins what
 * a caller does see, including the misspelled signal keyword recorded in
 * FOUND.md. */

#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <janet.h>

#ifndef JANET_WINDOWS
#include <signal.h>
#include <unistd.h>
#endif

#define JANET_OS_WAIT_EXITED 0
#define JANET_OS_WAIT_STOPPED 1
#define JANET_OS_WAIT_SIGNALED 2
#define JANET_OS_WAIT_UNKNOWN 3

int32_t janet_os_exec_escape_arg(const char *arg, uint8_t *dest, int32_t cap);
int32_t janet_os_env_key_ok(const uint8_t *key, int32_t len);
void janet_os_env_entry_fill(const uint8_t *key, int32_t klen, const uint8_t *value,
                             int32_t vlen, uint8_t *dest);
int64_t janet_os_getpid(void);
int32_t janet_os_system(const char *command);

#ifndef JANET_WINDOWS
int32_t janet_os_signal_index(const uint8_t *key, int32_t len);
int32_t janet_os_wait(int64_t pid, int32_t *value);
void janet_os_reap(int64_t pid);
int32_t janet_os_kill(int64_t pid, int32_t sig);
int32_t janet_os_pipe(int *fds);
int32_t janet_os_close_fd(int fd);
int64_t janet_os_fork(void);
int32_t janet_os_exec(const char *path, char *const *argv, int32_t search_path);
#endif

/* Escaping is measured with nowhere to write, then filled into exactly the
 * space it asked for. Both passes must agree, and neither may touch a byte past
 * the reported length. */
static void expect_escape(const char *arg, const char *expected) {
    uint8_t buffer[64];
    int32_t needed = janet_os_exec_escape_arg(arg, NULL, 0);
    assert(needed == (int32_t) strlen(expected));
    assert(needed < (int32_t) sizeof(buffer));
    memset(buffer, '#', sizeof(buffer));
    assert(janet_os_exec_escape_arg(arg, buffer, needed) == needed);
    assert(memcmp(buffer, expected, (size_t) needed) == 0);
    assert(buffer[needed] == '#');
}

static void test_exec_escaping(void) {
    /* An argument the splitter would keep whole is passed through. */
    expect_escape("simple", "simple");
    expect_escape("", "");
    expect_escape("a\\b\\c", "a\\b\\c");
    expect_escape("trailing\\\\", "trailing\\\\");

    /* Each byte the splitter treats as a separator forces quoting. */
    expect_escape("two words", "\"two words\"");
    expect_escape("tab\there", "\"tab\there\"");
    expect_escape("line\nbreak", "\"line\nbreak\"");
    expect_escape("vertical\vtab", "\"vertical\vtab\"");

    /* A quotation mark is escaped, and so is every backslash before it. */
    expect_escape("a\"b", "\"a\\\"b\"");
    expect_escape("\"", "\"\\\"\"");
    expect_escape("a\\\\\"b", "\"a\\\\\\\\\\\"b\"");

    /* Backslashes elsewhere in a quoted argument stand for themselves. */
    expect_escape("a\\\\b c", "\"a\\\\b c\"");

    /* A run at the end meets the closing mark, so it doubles as well. */
    expect_escape("end \\\\", "\"end \\\\\\\\\"");

    /* Writing is refused when the caller offers less room than it asked for,
     * but the length is still reported. */
    uint8_t small[4];
    memset(small, '#', sizeof(small));
    assert(janet_os_exec_escape_arg("two words", small, 0) == 11);
    assert(small[0] == '#');
}

static void test_env_entries(void) {
    /* A key holding a separator or a terminator would be read back as a
     * different name, so it is refused. */
    assert(janet_os_env_key_ok((const uint8_t *) "PATH", 4) == 1);
    assert(janet_os_env_key_ok((const uint8_t *) "", 0) == 1);
    assert(janet_os_env_key_ok((const uint8_t *) "A=B", 3) == 0);
    assert(janet_os_env_key_ok((const uint8_t *) "A\0B", 3) == 0);

    /* Only the reported length is examined, so a separator past it is unseen. */
    assert(janet_os_env_key_ok((const uint8_t *) "A=B", 1) == 1);

    uint8_t entry[16];
    memset(entry, '#', sizeof(entry));
    janet_os_env_entry_fill((const uint8_t *) "K", 1, (const uint8_t *) "V", 1, entry);
    assert(memcmp(entry, "K=V", 4) == 0);
    assert(entry[4] == '#');

    janet_os_env_entry_fill((const uint8_t *) "K", 1, (const uint8_t *) "", 0, entry);
    assert(memcmp(entry, "K=", 3) == 0);

    /* A value may hold anything the key may not. */
    janet_os_env_entry_fill((const uint8_t *) "K", 1, (const uint8_t *) "a=b", 3, entry);
    assert(memcmp(entry, "K=a=b", 6) == 0);
}

#ifndef JANET_WINDOWS

static void test_signal_lookup(void) {
    assert(janet_os_signal_index((const uint8_t *) "kill", 4) == 0);
    assert(janet_os_signal_index((const uint8_t *) "int", 3) == 1);
    assert(janet_os_signal_index((const uint8_t *) "segv", 4) == 5);
    assert(janet_os_signal_index((const uint8_t *) "xfsz", 4) == 27);

    /* Only whole names match. */
    assert(janet_os_signal_index((const uint8_t *) "kil", 3) == -1);
    assert(janet_os_signal_index((const uint8_t *) "killer", 6) == -1);
    assert(janet_os_signal_index((const uint8_t *) "", 0) == -1);
    assert(janet_os_signal_index((const uint8_t *) "nosuch", 6) == -1);

    /* A key whose own bytes end in a terminator matches the shorter name, which
     * is what janet_cstrcmp did here. */
    assert(janet_os_signal_index((const uint8_t *) "int\0x", 5) == 1);

    /* The table misspells the name SIGVTALRM would give, so the documented
     * spelling is the one that fails. See FOUND.md. */
    assert(janet_os_signal_index((const uint8_t *) "vtlarm", 6) == 25);
    assert(janet_os_signal_index((const uint8_t *) "vtalrm", 6) == -1);
}

static void test_host_operations(void) {
    assert(janet_os_getpid() > 0);
    assert(janet_os_system("exit 0") == 0);
    assert(janet_os_system("exit 5") != 0);

    /* A pipe carries bytes from its write end to its read end. */
    int fds[2];
    char byte = 0;
    assert(janet_os_pipe(fds) == 0);
    assert(write(fds[1], "x", 1) == 1);
    assert(read(fds[0], &byte, 1) == 1);
    assert(byte == 'x');
    assert(janet_os_close_fd(fds[0]) == 0);
    assert(janet_os_close_fd(fds[1]) == 0);

    /* An ordinary exit is classified by its code. */
    int32_t value = -1;
    int64_t pid = janet_os_fork();
    assert(pid >= 0);
    if (pid == 0) _exit(3);
    assert(janet_os_wait(pid, &value) == JANET_OS_WAIT_EXITED);
    assert(value == 3);

    /* A process that ends on a signal is classified by that signal, without the
     * offset the caller adds. */
    value = -1;
    pid = janet_os_fork();
    assert(pid >= 0);
    if (pid == 0) {
        raise(SIGTERM);
        _exit(0);
    }
    assert(janet_os_wait(pid, &value) == JANET_OS_WAIT_SIGNALED);
    assert(value == SIGTERM);

    /* The same holds for a signal sent from outside. */
    value = -1;
    pid = janet_os_fork();
    assert(pid >= 0);
    if (pid == 0) {
        pause();
        _exit(0);
    }
    assert(janet_os_kill(pid, SIGKILL) == 0);
    assert(janet_os_wait(pid, &value) == JANET_OS_WAIT_SIGNALED);
    assert(value == SIGKILL);

    /* Collecting a process reports nothing, and a later wait on it finds
     * nothing to report. The untouched status word then classifies as a zero
     * exit, which is what the C implementation did by ignoring waitpid's
     * result. */
    pid = janet_os_fork();
    assert(pid >= 0);
    if (pid == 0) _exit(9);
    janet_os_reap(pid);
    value = -1;
    assert(janet_os_wait(pid, &value) == JANET_OS_WAIT_EXITED);
    assert(value == 0);

    /* Replacing a process by absolute path, and by a name found on the path. */
    value = -1;
    pid = janet_os_fork();
    assert(pid >= 0);
    if (pid == 0) {
        char *const args[] = {(char *) "/bin/sh", (char *) "-c", (char *) "exit 5", NULL};
        janet_os_exec("/bin/sh", args, 0);
        _exit(70);
    }
    assert(janet_os_wait(pid, &value) == JANET_OS_WAIT_EXITED);
    assert(value == 5);

    value = -1;
    pid = janet_os_fork();
    assert(pid >= 0);
    if (pid == 0) {
        char *const args[] = {(char *) "sh", (char *) "-c", (char *) "exit 6", NULL};
        janet_os_exec("sh", args, 1);
        _exit(70);
    }
    assert(janet_os_wait(pid, &value) == JANET_OS_WAIT_EXITED);
    assert(value == 6);

    /* A failed replacement returns instead of ending the process. */
    value = -1;
    pid = janet_os_fork();
    assert(pid >= 0);
    if (pid == 0) {
        char *const args[] = {(char *) "/janet-zig-os-process-absent-4f81", NULL};
        _exit(janet_os_exec("/janet-zig-os-process-absent-4f81", args, 0) == -1 ? 71 : 72);
    }
    assert(janet_os_wait(pid, &value) == JANET_OS_WAIT_EXITED);
    assert(value == 71);
}

/* Each contract runs as one function so that a form which waits on the event
 * loop finishes before the next contract starts. janet_dostring evaluates each
 * top level form in its own fiber and does not drive the loop, which would let
 * a spawn outlive the wait that follows it. */
static void run(JanetTable *env, const char *source) {
    char wrapped[4096];
    int written = snprintf(wrapped, sizeof(wrapped), "(fn [] %s)", source);
    assert(written > 0 && written < (int) sizeof(wrapped));

    Janet fnv = janet_wrap_nil();
    assert(janet_dostring(env, wrapped, "os-process-contract", &fnv) == 0);
    assert(janet_checktype(fnv, JANET_FUNCTION));

    JanetFiber *fiber = janet_fiber(janet_unwrap_function(fnv), 64, 0, NULL);
    fiber->env = env;
#ifdef JANET_EV
    janet_gcroot(janet_wrap_fiber(fiber));
    janet_schedule(fiber, janet_wrap_nil());
    janet_loop();
    assert(janet_fiber_status(fiber) == JANET_STATUS_DEAD);
    janet_gcunroot(janet_wrap_fiber(fiber));
#else
    Janet result = janet_wrap_nil();
    JanetSignal signal = janet_continue(fiber, janet_wrap_nil(), &result);
    if (signal != JANET_SIGNAL_OK) janet_stacktrace_ext(fiber, result, "");
    assert(signal == JANET_SIGNAL_OK);
#endif
}

static void test_core_functions(void) {
    JanetTable *env = janet_core_env(NULL);

    /* An exit code reaches the caller unchanged, whether the program is named
     * by path or found on it. */
    run(env,
        "(assert (= 0 (os/execute [\"/bin/sh\" \"-c\" \"exit 0\"])))\n"
        "(assert (= 7 (os/execute [\"/bin/sh\" \"-c\" \"exit 7\"])))\n"
        "(assert (= 3 (os/execute [\"sh\" \"-c\" \"exit 3\"] :p)))\n");

    /* The :x flag turns a non-zero code into an error — but only where the
     * event loop is compiled in. The flag is read in the wait callback, which
     * does not exist otherwise, so a build without the event loop accepts the
     * flag and ignores it. That is recorded in FOUND.md and left unfixed, so
     * the contract pins each configuration as it stands. */
    run(env,
        "(assert (= 0 (os/execute [\"/bin/sh\" \"-c\" \"exit 0\"] :x)))\n"
#ifdef JANET_EV
        "(assert (not (first (protect (os/execute [\"/bin/sh\" \"-c\" \"exit 1\"] :x)))))\n"
#else
        "(assert (= 1 (os/execute [\"/bin/sh\" \"-c\" \"exit 1\"] :x)))\n"
#endif
    );

    /* A supplied environment reaches the child, and a key holding a separator
     * is dropped rather than passed as a different name. */
    run(env,
        "(assert (= 0 (os/execute [\"/bin/sh\" \"-c\" \"[ \\\"$FOO\\\" = bar ]\"] :e"
        " {\"FOO\" \"bar\"})))\n"
        "(assert (= 0 (os/execute [\"/bin/sh\" \"-c\" \"[ -z \\\"$A\\\" ]\"] :e"
        " {\"A=B\" \"C\" \"FOO\" \"bar\"})))\n");

    /* A process ended by a signal reports that signal offset by 128. */
    run(env,
        "(def p (os/spawn [\"/bin/sh\" \"-c\" \"sleep 10\"]))\n"
        "(assert (= 143 (os/proc-kill p true :term)))\n");

    /* Signal keywords are looked up whole, and the table's misspelling of
     * SIGVTALRM is the spelling that resolves. See FOUND.md. */
    run(env,
        "(def p (os/spawn [\"/bin/sh\" \"-c\" \"sleep 10\"]))\n"
        "(assert (not (first (protect (os/proc-kill p false :vtalrm)))))\n"
        "(assert (not (first (protect (os/proc-kill p false :kil)))))\n"
        "(os/proc-kill p false :vtlarm)\n"
        "(assert (>= (os/proc-wait p) 129))\n");

    /* Waiting twice on the same process is an error. */
    run(env,
        "(def p (os/spawn [\"/bin/sh\" \"-c\" \"exit 4\"]))\n"
        "(assert (= 4 (os/proc-wait p)))\n"
        "(assert (not (first (protect (os/proc-wait p)))))\n");

    /* The remaining process functions report the host directly.
     *
     * os/shell is called without a command, which is the only form that
     * survives: passing one aborts the process under the event loop, because
     * the subroutine frees the copied command and the default callback frees
     * it again. That is recorded in FOUND.md and left unfixed, so the contract
     * cannot exercise it. */
    run(env,
        "(assert (> (os/getpid) 0))\n"
        "(assert (boolean? (os/shell)))\n");
}

#endif /* JANET_WINDOWS */

int main(void) {
    test_exec_escaping();
    test_env_entries();
#ifndef JANET_WINDOWS
    test_signal_lookup();
    test_host_operations();

    janet_init();
    test_core_functions();
    janet_deinit();
#endif
    return 0;
}
