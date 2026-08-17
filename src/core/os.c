/*
* Copyright (c) 2026 Calvin Rose and contributors.
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to
* deal in the Software without restriction, including without limitation the
* rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
* sell copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in
* all copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
* IN THE SOFTWARE.
*/

#ifndef JANET_AMALG
#include "features.h"
#include <janet.h>
#include "util.h"
#include "gc.h"
#endif

#include <stdlib.h>

#ifndef JANET_REDUCED_OS

#include <time.h>
#include <fcntl.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <signal.h>
#include <locale.h>
#include <inttypes.h>

#ifdef JANET_BSD
#include <sys/sysctl.h>
#endif

#ifdef JANET_LINUX
#include <sched.h>
#endif

#ifdef JANET_GNU_HURD
/* Ideally we would try to dynamically allocate */
#define PATH_MAX 8192
#endif

#ifdef JANET_WINDOWS
#include <windows.h>
#include <direct.h>
#include <sys/utime.h>
#include <io.h>
#include <process.h>
#define JANET_SPAWN_CHDIR
#else
#ifndef JANET_PLAN9
#include <spawn.h>
#endif
#include <utime.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/types.h>
#include <sys/wait.h>
#ifdef JANET_APPLE
#include <crt_externs.h>
#define environ (*_NSGetEnviron())
#include <AvailabilityMacros.h>
int chroot(const char *dirname);
#elif !defined(JANET_PLAN9)
extern char **environ;
#endif
#ifdef JANET_THREADS
#include <pthread.h>
#endif
#endif

/* Detect availability of posix_spawn_file_actions_addchdir_np. Since
 * this doesn't seem to follow any standard, just a common extension, we
 * must enumerate supported systems for availability. Define JANET_SPAWN_NO_CHDIR
 * to disable this. */
#ifndef JANET_SPAWN_NO_CHDIR
#ifdef __GLIBC__
#define JANET_SPAWN_CHDIR
#elif defined(JANET_APPLE)
/* The posix_spawn_file_actions_addchdir_np function
 * has only been implemented since macOS 10.15 */
#if defined(MAC_OS_X_VERSION_10_15) && (MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_15)
#define JANET_SPAWN_CHDIR
#else
#define JANET_SPAWN_NO_CHDIR
#endif
#elif defined(__FreeBSD__) /* Not all BSDs work, for example openBSD doesn't seem to support this */
#define JANET_SPAWN_CHDIR
#endif
#endif

/* Not POSIX, but all Unixes but Solaris have this function. */
#if defined(JANET_POSIX) && !defined(__sun)
time_t timegm(struct tm *tm);
#elif defined(JANET_WINDOWS)
#define timegm _mkgmtime
#endif

/* Access to some global variables should be synchronized if not in single threaded mode, as
 * setenv/getenv are not thread safe. */
#ifdef JANET_THREADS
# ifdef JANET_WINDOWS
static CRITICAL_SECTION env_lock;
static void janet_lock_environ(void) {
    EnterCriticalSection(&env_lock);
}
static void janet_unlock_environ(void) {
    LeaveCriticalSection(&env_lock);
}
# else
static pthread_mutex_t env_lock = PTHREAD_MUTEX_INITIALIZER;
static void janet_lock_environ(void) {
    pthread_mutex_lock(&env_lock);
}
static void janet_unlock_environ(void) {
    pthread_mutex_unlock(&env_lock);
}
# endif
#else
static void janet_lock_environ(void) {
}
static void janet_unlock_environ(void) {
}
#endif

#endif /* JANET_REDCUED_OS */

/* Core OS functions */

/* Full OS functions */

#define janet_stringify1(x) #x
#define janet_stringify(x) janet_stringify1(x)

#ifdef JANET_ZIG_OS_PLATFORM

const char *janet_os_name(void);
const char *janet_os_arch(void);
const char *janet_os_compiler(void);
#ifndef JANET_REDUCED_OS
int32_t janet_os_cpu_count(void);
#endif

#else

const char *janet_os_name(void) {
#if defined(JANET_OS_NAME)
    return janet_stringify(JANET_OS_NAME);
#elif defined(JANET_MINGW)
    return "mingw";
#elif defined(JANET_CYGWIN)
    return "cygwin";
#elif defined(JANET_WINDOWS)
    return "windows";
#elif defined(JANET_APPLE)
    return "macos";
#elif defined(__EMSCRIPTEN__)
    return "web";
#elif defined(JANET_LINUX)
    return "linux";
#elif defined(JANET_GNU_HURD)
    return "hurd";
#elif defined(__FreeBSD__)
    return "freebsd";
#elif defined(__NetBSD__)
    return "netbsd";
#elif defined(__OpenBSD__)
    return "openbsd";
#elif defined(__DragonFly__)
    return "dragonfly";
#elif defined(JANET_BSD)
    return "bsd";
#elif defined(JANET_ILLUMOS)
    return "illumos";
#else
    return "posix";
#endif
}

const char *janet_os_arch(void) {
#if defined(JANET_ARCH_NAME)
    return janet_stringify(JANET_ARCH_NAME);
#elif defined(__EMSCRIPTEN__)
    return "wasm";
#elif (defined(__x86_64__) || defined(_M_X64))
    return "x64";
#elif defined(__i386) || defined(_M_IX86)
    return "x86";
#elif defined(_M_ARM64) || defined(__aarch64__)
    return "aarch64";
#elif defined(_M_ARM) || defined(__arm__)
    return "arm";
#elif (defined(__riscv) && (__riscv_xlen == 64))
    return "riscv64";
#elif (defined(__riscv) && (__riscv_xlen == 32))
    return "riscv32";
#elif (defined(__sparc__))
    return "sparc";
#elif (defined(__ppc__))
    return "ppc";
#elif (defined(__ppc64__) || defined(_ARCH_PPC64) || defined(_M_PPC))
    return "ppc64";
#elif (defined(__s390x__))
    return "s390x";
#elif (defined(__s390__))
    return "s390";
#else
    return "unknown";
#endif
}

const char *janet_os_compiler(void) {
#if defined(_MSC_VER)
    return "msvc";
#elif defined(__clang__)
    return "clang";
#elif defined(__GNUC__)
    return "gcc";
#elif defined(JANET_PLAN9)
    return "kencc";
#else
    return "unknown";
#endif
}

#endif /* JANET_ZIG_OS_PLATFORM */

JANET_CORE_FN(os_which,
              "(os/which &opt test)",
              "Check the current operating system. If `test` is nil or unset, Returns one of:\n\n"
              "* :windows\n\n"
              "* :mingw\n\n"
              "* :cygwin\n\n"
              "* :macos\n\n"
              "* :web - Web assembly (emscripten)\n\n"
              "* :linux\n\n"
              "* :hurd\n\n"
              "* :freebsd\n\n"
              "* :openbsd\n\n"
              "* :netbsd\n\n"
              "* :dragonfly\n\n"
              "* :bsd\n\n"
              "* :posix - A POSIX compatible system (default)\n\n"
              "May also return a custom keyword specified at build time. Is `test` is truthy, will check if the current operating system equals `test` and return true if they are the same, false otherwise.") {
    janet_arity(argc, 0, 1);
    if (argc == 1 && janet_truthy(argv[0])) {
        janet_getkeyword(argv, 0); /* Constrain to keywords */
        return janet_wrap_boolean(janet_equals(argv[0], os_which(0, NULL)));
    }
#if defined(JANET_ZIG_OS_PLATFORM) && defined(JANET_OS_NAME)
    return janet_ckeywordv(janet_stringify(JANET_OS_NAME));
#else
    return janet_ckeywordv(janet_os_name());
#endif
}

/* Detect the ISA we are compiled for */
JANET_CORE_FN(os_arch,
              "(os/arch)",
              "Check the ISA that janet was compiled for. Returns one of:\n\n"
              "* :x86\n\n"
              "* :x64\n\n"
              "* :arm\n\n"
              "* :aarch64\n\n"
              "* :riscv32\n\n"
              "* :riscv64\n\n"
              "* :sparc\n\n"
              "* :wasm\n\n"
              "* :s390\n\n"
              "* :s390x\n\n"
              "* :unknown\n") {
    janet_fixarity(argc, 0);
    (void) argv;
    /* Check 64-bit vs 32-bit */
#if defined(JANET_ZIG_OS_PLATFORM) && defined(JANET_ARCH_NAME)
    return janet_ckeywordv(janet_stringify(JANET_ARCH_NAME));
#else
    return janet_ckeywordv(janet_os_arch());
#endif
}

/* Detect the compiler used to build the interpreter */
JANET_CORE_FN(os_compiler,
              "(os/compiler)",
              "Get the compiler used to compile the interpreter. Returns one of:\n\n"
              "* :gcc\n\n"
              "* :clang\n\n"
              "* :msvc\n\n"
              "* :kencc\n\n"
              "* :unknown\n\n") {
    janet_fixarity(argc, 0);
    (void) argv;
    return janet_ckeywordv(janet_os_compiler());
}

#undef janet_stringify1
#undef janet_stringify

JANET_CORE_FN(os_exit,
              "(os/exit &opt x force)",
              "Exit from janet with an exit code equal to x. If x is not an integer, "
              "the exit with status equal the hash of x. If `force` is truthy will exit immediately and "
              "skip cleanup code.") {
    janet_arity(argc, 0, 2);
    janet_sandbox_assert(JANET_SANDBOX_EXIT);
    int status;
    if (argc == 0) {
        status = EXIT_SUCCESS;
    } else if (janet_checkint(argv[0])) {
        status = janet_unwrap_integer(argv[0]);
    } else {
        status = EXIT_FAILURE;
    }
    int force = (argc >= 2 && janet_truthy(argv[1]));
    janet_deinit();
    if (force) {
#ifdef JANET_PLAN9
        exits(nil);
#else
        _Exit(status);
#endif
    } else {
        exit(status);
    }
    return janet_wrap_nil();
}

#ifndef JANET_REDUCED_OS

#ifndef JANET_ZIG_OS_PLATFORM
int32_t janet_os_cpu_count(void) {
#ifdef JANET_WINDOWS
    SYSTEM_INFO info;
    GetSystemInfo(&info);
    return (int32_t) info.dwNumberOfProcessors;
#elif defined(JANET_LINUX)
    cpu_set_t cs;
    CPU_ZERO(&cs);
    sched_getaffinity(0, sizeof(cs), &cs);
    return CPU_COUNT(&cs);
#elif defined(JANET_BSD) && defined(HW_NCPUONLINE)
    const int name[2] = {CTL_HW, HW_NCPUONLINE};
    int result = 0;
    size_t len = sizeof(int);
    if (-1 == sysctl(name, 2, &result, &len, NULL, 0)) return -1;
    return result;
#elif defined(JANET_BSD) && defined(HW_NCPU)
    const int name[2] = {CTL_HW, HW_NCPU};
    int result = 0;
    size_t len = sizeof(int);
    if (-1 == sysctl(name, 2, &result, &len, NULL, 0)) return -1;
    return result;
#elif defined(JANET_ILLUMOS)
    long result = sysconf(_SC_NPROCESSORS_CONF);
    return result < 0 ? -1 : (int32_t) result;
#elif defined(JANET_PLAN9)
    return atoi(getenv("NPROC"));
#else
    return -1;
#endif
}
#endif /* JANET_ZIG_OS_PLATFORM */

JANET_CORE_FN(os_cpu_count,
              "(os/cpu-count &opt dflt)",
              "Get an approximate number of CPUs available on for this process to use. If "
              "unable to get an approximation, will return a default value dflt.") {
    janet_arity(argc, 0, 1);
    (void) argv; /* Prevent unused argument warning */
    int32_t count = janet_os_cpu_count();
    if (count < 0) return argc > 0 ? argv[0] : janet_wrap_nil();
    return janet_wrap_integer(count);
}

#ifndef JANET_NO_PROCESSES

/* How a process ended, as reported by janet_os_wait. The offset that the two
 * signal outcomes carry, and the panic the fourth one raises, stay here. */
#define JANET_OS_WAIT_EXITED 0
#define JANET_OS_WAIT_STOPPED 1
#define JANET_OS_WAIT_SIGNALED 2
#define JANET_OS_WAIT_UNKNOWN 3

#ifdef JANET_ZIG_OS_PROCESS

int32_t janet_os_exec_escape_arg(const char *arg, uint8_t *dest, int32_t cap);
int32_t janet_os_env_key_ok(const uint8_t *key, int32_t len);
void janet_os_env_entry_fill(const uint8_t *key, int32_t klen, const uint8_t *value,
                             int32_t vlen, uint8_t *dest);
int64_t janet_os_getpid(void);
int32_t janet_os_system(const char *command);
#ifndef JANET_WINDOWS
int32_t janet_os_wait(int64_t pid, int32_t *value);
void janet_os_reap(int64_t pid);
int32_t janet_os_kill(int64_t pid, int32_t sig);
int32_t janet_os_pipe(int *fds);
int32_t janet_os_close_fd(int fd);
#ifndef JANET_PLAN9
int64_t janet_os_fork(void);
int32_t janet_os_exec(const char *path, char *const *argv, int32_t search_path);
int32_t janet_os_chroot(const char *path);
#endif
#endif

#else

/* Append one byte of an escaped argument, counting it whether or not there is
 * anywhere to put it. */
static void os_escape_push(uint8_t *dest, size_t limit, size_t *len, uint8_t value) {
    if (dest != NULL && *len < limit) dest[*len] = value;
    (*len)++;
}

static void os_escape_repeat(uint8_t *dest, size_t limit, size_t *len, uint8_t value, size_t count) {
    while (count > 0) {
        os_escape_push(dest, limit, len, value);
        count--;
    }
}

int32_t janet_os_exec_escape_arg(const char *arg, uint8_t *dest, int32_t cap) {
    size_t len = 0;
    size_t limit = (dest != NULL && cap > 0) ? (size_t) cap : 0;

    /* Find first special character */
    const char *first_spec = arg;
    while (*first_spec) {
        if (*first_spec == ' ' || *first_spec == '\t' || *first_spec == '\v' ||
                *first_spec == '\n' || *first_spec == '"') break;
        first_spec++;
    }

    if (*first_spec == '\0') {
        /* No escape needed */
        for (const char *c = arg; *c; c++) os_escape_push(dest, limit, &len, (uint8_t) *c);
    } else {
        /* Escape */
        os_escape_push(dest, limit, &len, '"');
        for (const char *c = arg; ; c++) {
            size_t numBackSlashes = 0;
            while (*c == '\\') {
                c++;
                numBackSlashes++;
            }
            if (*c == '"') {
                /* Escape all backslashes and double quote mark */
                os_escape_repeat(dest, limit, &len, '\\', 2 * numBackSlashes + 1);
                os_escape_push(dest, limit, &len, '"');
            } else if (*c) {
                /* Don't escape backslashes. */
                os_escape_repeat(dest, limit, &len, '\\', numBackSlashes);
                os_escape_push(dest, limit, &len, (uint8_t) *c);
            } else {
                /* we finished Escape all backslashes */
                os_escape_repeat(dest, limit, &len, '\\', 2 * numBackSlashes);
                break;
            }
        }
        os_escape_push(dest, limit, &len, '"');
    }

    if (len > (size_t) INT32_MAX) return -1;
    return (int32_t) len;
}

int32_t janet_os_env_key_ok(const uint8_t *key, int32_t len) {
    if (len < 0) return 0;
    for (int32_t index = 0; index < len; index++) {
        if (key[index] == '\0' || key[index] == '=') return 0;
    }
    return 1;
}

void janet_os_env_entry_fill(const uint8_t *key, int32_t klen, const uint8_t *value,
                             int32_t vlen, uint8_t *dest) {
    size_t k = klen > 0 ? (size_t) klen : 0;
    size_t v = vlen > 0 ? (size_t) vlen : 0;
    memcpy(dest, key, k);
    dest[k] = '=';
    memcpy(dest + k + 1, value, v);
    dest[k + v + 1] = '\0';
}

int64_t janet_os_getpid(void) {
#ifdef JANET_WINDOWS
    return (int64_t) _getpid();
#else
    return (int64_t) getpid();
#endif
}

int32_t janet_os_system(const char *command) {
    return (int32_t) system(command);
}

#ifndef JANET_WINDOWS

int32_t janet_os_wait(int64_t pid, int32_t *value) {
    int status = 0;
    pid_t result;
    do {
        result = waitpid((pid_t) pid, &status, 0);
    } while (result == -1 && errno == EINTR);
    if (WIFEXITED(status)) {
        *value = (int32_t) WEXITSTATUS(status);
        return JANET_OS_WAIT_EXITED;
    }
    if (WIFSTOPPED(status)) {
        *value = (int32_t) WSTOPSIG(status);
        return JANET_OS_WAIT_STOPPED;
    }
    if (WIFSIGNALED(status)) {
        *value = (int32_t) WTERMSIG(status);
        return JANET_OS_WAIT_SIGNALED;
    }
    *value = (int32_t) status;
    return JANET_OS_WAIT_UNKNOWN;
}

void janet_os_reap(int64_t pid) {
    int status = 0;
    waitpid((pid_t) pid, &status, 0);
}

int32_t janet_os_kill(int64_t pid, int32_t sig) {
    return (int32_t) kill((pid_t) pid, (int) sig);
}

int32_t janet_os_pipe(int *fds) {
    return (int32_t) pipe(fds);
}

int32_t janet_os_close_fd(int fd) {
    return (int32_t) close(fd);
}

#ifndef JANET_PLAN9

int64_t janet_os_fork(void) {
    pid_t result;
    do {
        result = fork();
    } while (result == -1 && errno == EINTR);
    return (int64_t) result;
}

int32_t janet_os_exec(const char *path, char *const *argv, int32_t search_path) {
    int status;
    do {
        if (search_path) {
            status = execvp(path, argv);
        } else {
            status = execv(path, argv);
        }
    } while (status == -1 && errno == EINTR);
    return (int32_t) status;
}

int32_t janet_os_chroot(const char *path) {
    int status;
    do {
        status = chroot(path);
    } while (status == -1 && errno == EINTR);
    return (int32_t) status;
}

#endif /* JANET_PLAN9 */
#endif /* JANET_WINDOWS */

#endif /* JANET_ZIG_OS_PROCESS */

/* Get env for os_execute */
#ifdef JANET_WINDOWS
typedef char *EnvBlock;
#else
typedef char **EnvBlock;
#endif

/* Get env for os_execute */
static EnvBlock os_execute_env(int32_t argc, const Janet *argv) {
    if (argc <= 2) return NULL;
    JanetDictView dict = janet_getdictionary(argv, 2);
#ifdef JANET_WINDOWS
    JanetBuffer *temp = janet_buffer(10);
    for (int32_t i = 0; i < dict.cap; i++) {
        const JanetKV *kv = dict.kvs + i;
        if (!janet_checktype(kv->key, JANET_STRING)) continue;
        if (!janet_checktype(kv->value, JANET_STRING)) continue;
        const uint8_t *keys = janet_unwrap_string(kv->key);
        const uint8_t *vals = janet_unwrap_string(kv->value);
        int32_t klen = janet_string_length(keys);
        int32_t vlen = janet_string_length(vals);
        /* The Windows block accepts every key, including one holding a
         * separator, which is what the C implementation did here. */
        janet_buffer_extra(temp, klen + vlen + 2);
        janet_os_env_entry_fill(keys, klen, vals, vlen, temp->data + temp->count);
        temp->count += klen + vlen + 2;
    }
    /* Windows environment blocks must be double-NULL terminated */
    if (temp->count == 0) janet_buffer_push_u8(temp, '\0');
    janet_buffer_push_u8(temp, '\0');
    char *ret = janet_smalloc(temp->count);
    memcpy(ret, temp->data, temp->count);
    return ret;
#else
    char **envp = janet_smalloc(sizeof(char *) * ((size_t)dict.len + 1));
    int32_t j = 0;
    for (int32_t i = 0; i < dict.cap; i++) {
        const JanetKV *kv = dict.kvs + i;
        if (!janet_checktype(kv->key, JANET_STRING)) continue;
        if (!janet_checktype(kv->value, JANET_STRING)) continue;
        const uint8_t *keys = janet_unwrap_string(kv->key);
        const uint8_t *vals = janet_unwrap_string(kv->value);
        int32_t klen = janet_string_length(keys);
        int32_t vlen = janet_string_length(vals);
        /* Check keys has no embedded 0s or =s. */
        if (!janet_os_env_key_ok(keys, klen)) continue;
        char *envitem = janet_smalloc((size_t) klen + (size_t) vlen + 2);
        janet_os_env_entry_fill(keys, klen, vals, vlen, (uint8_t *) envitem);
        envp[j++] = envitem;
    }
    envp[j] = NULL;
    return envp;
#endif
}

static void os_execute_cleanup(EnvBlock envp, const char **child_argv) {
#ifdef JANET_WINDOWS
    (void) child_argv;
    if (NULL != envp) janet_sfree(envp);
#else
    janet_sfree((void *)child_argv);
    if (NULL != envp) {
        char **envitem = envp;
        while (*envitem != NULL) {
            janet_sfree(*envitem);
            envitem++;
        }
    }
    janet_sfree(envp);
#endif
}

#ifdef JANET_WINDOWS
/* Windows processes created via CreateProcess get only one command line argument string, and
 * must parse this themselves. Each processes is free to do this however they like, but the
 * standard parsing method is CommandLineToArgvW. We need to properly escape arguments into
 * a single string of this format. Returns a buffer that can be cast into a c string. */
static JanetBuffer *os_exec_escape(JanetView args) {
    JanetBuffer *b = janet_buffer(0);
    for (int32_t i = 0; i < args.len; i++) {
        const char *arg = janet_getcstring(args.items, i);

        /* Push leading space if not first */
        if (i) janet_buffer_push_u8(b, ' ');

        /* Measure, make room, then fill: growing the buffer can panic, which
         * may not happen inside the escaping itself. */
        int32_t needed = janet_os_exec_escape_arg(arg, NULL, 0);
        if (needed < 0) janet_panic("command line string too long (max 8191 characters)");
        janet_buffer_extra(b, needed);
        janet_os_exec_escape_arg(arg, b->data + b->count, needed);
        b->count += needed;
    }
    janet_buffer_push_u8(b, 0);
    return b;
}
#endif

/* Process type for when running a subprocess and not immediately waiting */
static const JanetAbstractType ProcAT;
#define JANET_PROC_CLOSED 1
#define JANET_PROC_WAITED 2
#define JANET_PROC_WAITING 4
#define JANET_PROC_ERROR_NONZERO 8
#define JANET_PROC_OWNS_STDIN 16
#define JANET_PROC_OWNS_STDOUT 32
#define JANET_PROC_OWNS_STDERR 64
#define JANET_PROC_ALLOW_ZOMBIE 128
typedef struct {
    int flags;
#ifdef JANET_WINDOWS
    HANDLE pHandle;
    HANDLE tHandle;
#else
    pid_t pid;
#endif
    int return_code;
#ifdef JANET_EV
    JanetStream *in;
    JanetStream *out;
    JanetStream *err;
#else
    JanetFile *in;
    JanetFile *out;
    JanetFile *err;
#endif
} JanetProc;

#ifndef JANET_WINDOWS

/* Wait on a pid and reduce the raw wait status to the value Janet reports.
 * Both the evented and non-evented implementations need this: without it a
 * caller sees the encoded status word rather than an exit code. */
static int proc_get_status(JanetProc *proc) {
    /* Use POSIX shell semantics for interpreting signals */
    int32_t value = 0;
    int32_t outcome = janet_os_wait((int64_t) proc->pid, &value);
    if (outcome == JANET_OS_WAIT_EXITED) return (int) value;
    if (outcome == JANET_OS_WAIT_STOPPED || outcome == JANET_OS_WAIT_SIGNALED) {
        return (int) value + 128;
    }
    /* Could possibly return -1 but for now, just panic */
    janet_panicf("Undefined status code for process termination, %d.", value);
}

#endif /* End windows check */

#ifdef JANET_EV

#ifdef JANET_WINDOWS

static JanetEVGenericMessage janet_proc_wait_subr(JanetEVGenericMessage args) {
    JanetProc *proc = (JanetProc *) args.argp;
    WaitForSingleObject(proc->pHandle, INFINITE);
    DWORD exitcode = 0;
    GetExitCodeProcess(proc->pHandle, &exitcode);
    args.tag = (int32_t) exitcode;
    return args;
}

#else /* windows check */

/* Function that is called in separate thread to wait on a pid */
static JanetEVGenericMessage janet_proc_wait_subr(JanetEVGenericMessage args) {
    JanetProc *proc = (JanetProc *) args.argp;
    args.tag = proc_get_status(proc);
    return args;
}

#endif /* End windows check */

/* Callback that is called in main thread when subroutine completes. */
static void janet_proc_wait_cb(JanetEVGenericMessage args) {
    JanetProc *proc = (JanetProc *) args.argp;
    if (NULL != proc) {
        int status = args.tag;
        proc->return_code = (int32_t) status;
        proc->flags |= JANET_PROC_WAITED;
        proc->flags &= ~JANET_PROC_WAITING;
        janet_gcunroot(janet_wrap_abstract(proc));
        janet_gcunroot(janet_wrap_fiber(args.fiber));
        uint32_t sched_id = (uint32_t) args.argi;
        if (janet_fiber_can_resume(args.fiber) && args.fiber->sched_id == sched_id) {
            if ((status != 0) && (proc->flags & JANET_PROC_ERROR_NONZERO)) {
                JanetString s = janet_formatc("command failed with non-zero exit code %d", status);
                janet_cancel(args.fiber, janet_wrap_string(s));
            } else {
                janet_schedule(args.fiber, janet_wrap_integer(status));
            }
        }
    }
}

#endif /* End ev check */

static int janet_proc_gc(void *p, size_t s) {
    (void) s;
    JanetProc *proc = (JanetProc *) p;
#ifdef JANET_WINDOWS
    if (!(proc->flags & JANET_PROC_CLOSED)) {
        if (!(proc->flags & JANET_PROC_ALLOW_ZOMBIE)) {
            TerminateProcess(proc->pHandle, 1);
        }
        CloseHandle(proc->pHandle);
        CloseHandle(proc->tHandle);
    }
#else
    if (!(proc->flags & (JANET_PROC_WAITED | JANET_PROC_ALLOW_ZOMBIE))) {
        /* Kill and wait to prevent zombies */
        janet_os_kill((int64_t) proc->pid, SIGKILL);
        if (!(proc->flags & JANET_PROC_WAITING)) {
            janet_os_reap((int64_t) proc->pid);
        }
    }
#endif
    return 0;
}

static int janet_proc_mark(void *p, size_t s) {
    (void) s;
    JanetProc *proc = (JanetProc *)p;
    if (NULL != proc->in) janet_mark(janet_wrap_abstract(proc->in));
    if (NULL != proc->out) janet_mark(janet_wrap_abstract(proc->out));
    if (NULL != proc->err) janet_mark(janet_wrap_abstract(proc->err));
    return 0;
}

#ifdef JANET_EV
static JANET_NO_RETURN void
#else
static Janet
#endif
os_proc_wait_impl(JanetProc *proc) {
    if (proc->flags & (JANET_PROC_WAITED | JANET_PROC_WAITING)) {
        janet_panicf("cannot wait twice on a process");
    }
#ifdef JANET_EV
    /* Event loop implementation - threaded call */
    proc->flags |= JANET_PROC_WAITING;
    JanetEVGenericMessage targs;
    memset(&targs, 0, sizeof(targs));
    targs.argp = proc;
    targs.fiber = janet_root_fiber();
    targs.argi = (uint32_t) targs.fiber->sched_id;
    janet_gcroot(janet_wrap_abstract(proc));
    janet_gcroot(janet_wrap_fiber(targs.fiber));
    janet_ev_threaded_call(janet_proc_wait_subr, targs, janet_proc_wait_cb);
    janet_await();
#else
    /* Non evented implementation */
    proc->flags |= JANET_PROC_WAITED;
    int status = 0;
#ifdef JANET_WINDOWS
    WaitForSingleObject(proc->pHandle, INFINITE);
    GetExitCodeProcess(proc->pHandle, &status);
    if (!(proc->flags & JANET_PROC_CLOSED)) {
        proc->flags |= JANET_PROC_CLOSED;
        CloseHandle(proc->pHandle);
        CloseHandle(proc->tHandle);
    }
#else
    status = proc_get_status(proc);
#endif
    proc->return_code = (int32_t) status;
    return janet_wrap_integer(proc->return_code);
#endif
}

JANET_CORE_FN(os_proc_wait,
              "(os/proc-wait proc)",
              "Suspend the current fiber until the subprocess `proc` completes. Once `proc` "
              "completes, return the exit code of `proc`. If called more than once on the same "
              "core/process value, will raise an error. When creating subprocesses using "
              "`os/spawn`, this function should be called on the returned value to avoid zombie "
              "processes.") {
    janet_fixarity(argc, 1);
    JanetProc *proc = janet_getabstract(argv, 0, &ProcAT);
#ifdef JANET_EV
    os_proc_wait_impl(proc);
#else
    return os_proc_wait_impl(proc);
#endif
}

#ifndef JANET_WINDOWS

/* The signal a keyword names, by position in the shared name list. A signal
 * this platform's headers do not define has no number, and -1 stands for it so
 * that the lookup reports the keyword as undefined, exactly as the previous
 * table did by omitting the entry. */
#define JANET_OS_SIGNAL_COUNT 28
static const int os_signal_numbers[JANET_OS_SIGNAL_COUNT] = {
#ifdef SIGKILL
    SIGKILL,
#else
    -1,
#endif
    SIGINT,
    SIGABRT,
    SIGFPE,
    SIGILL,
    SIGSEGV,
#ifdef SIGTERM
    SIGTERM,
#else
    -1,
#endif
#ifdef SIGALRM
    SIGALRM,
#else
    -1,
#endif
#ifdef SIGHUP
    SIGHUP,
#else
    -1,
#endif
#ifdef SIGPIPE
    SIGPIPE,
#else
    -1,
#endif
#ifdef SIGQUIT
    SIGQUIT,
#else
    -1,
#endif
#ifdef SIGUSR1
    SIGUSR1,
#else
    -1,
#endif
#ifdef SIGUSR2
    SIGUSR2,
#else
    -1,
#endif
#ifdef SIGCHLD
    SIGCHLD,
#else
    -1,
#endif
#ifdef SIGCONT
    SIGCONT,
#else
    -1,
#endif
#ifdef SIGSTOP
    SIGSTOP,
#else
    -1,
#endif
#ifdef SIGTSTP
    SIGTSTP,
#else
    -1,
#endif
#ifdef SIGTTIN
    SIGTTIN,
#else
    -1,
#endif
#ifdef SIGTTOU
    SIGTTOU,
#else
    -1,
#endif
#ifdef SIGBUS
    SIGBUS,
#else
    -1,
#endif
#ifdef SIGPOLL
    SIGPOLL,
#else
    -1,
#endif
#ifdef SIGPROF
    SIGPROF,
#else
    -1,
#endif
#ifdef SIGSYS
    SIGSYS,
#else
    -1,
#endif
#ifdef SIGTRAP
    SIGTRAP,
#else
    -1,
#endif
#ifdef SIGURG
    SIGURG,
#else
    -1,
#endif
#ifdef SIGVTALRM
    SIGVTALRM,
#else
    -1,
#endif
#ifdef SIGXCPU
    SIGXCPU,
#else
    -1,
#endif
#ifdef SIGXFSZ
    SIGXFSZ,
#else
    -1,
#endif
};

#ifdef JANET_ZIG_OS_PROCESS

int32_t janet_os_signal_index(const uint8_t *key, int32_t len);

#else

/* The keyword each position stands for. `vtlarm` is a misspelling of the name
 * SIGVTALRM would give; it is recorded in FOUND.md and kept rather than
 * corrected. */
static const char *const os_signal_names[JANET_OS_SIGNAL_COUNT] = {
    "kill",
    "int",
    "abrt",
    "fpe",
    "ill",
    "segv",
    "term",
    "alrm",
    "hup",
    "pipe",
    "quit",
    "usr1",
    "usr2",
    "chld",
    "cont",
    "stop",
    "tstp",
    "ttin",
    "ttou",
    "bus",
    "poll",
    "prof",
    "sys",
    "trap",
    "urg",
    "vtlarm",
    "xcpu",
    "xfsz"
};

int32_t janet_os_signal_index(const uint8_t *key, int32_t len) {
    if (len < 0) return -1;
    for (int32_t signal = 0; signal < JANET_OS_SIGNAL_COUNT; signal++) {
        const char *name = os_signal_names[signal];
        int32_t index;
        for (index = 0; index < len; index++) {
            uint8_t k = ((const uint8_t *) name)[index];
            if (key[index] != k) goto next;
            if (k == '\0') break;
        }
        if (name[index] == '\0') return signal;
next:
        ;
    }
    return -1;
}

#endif /* JANET_ZIG_OS_PROCESS */

static int get_signal_kw(const Janet *argv, int32_t n) {
    JanetKeyword signal_kw = janet_getkeyword(argv, n);
    int32_t index = janet_os_signal_index(signal_kw, janet_string_length(signal_kw));
    if (index >= 0 && os_signal_numbers[index] >= 0) {
        return os_signal_numbers[index];
    }
    janet_panicf("undefined signal %v", argv[n]);
}
#endif

JANET_CORE_FN(os_proc_kill,
              "(os/proc-kill proc &opt wait signal)",
              "Kill the subprocess `proc` by sending SIGKILL to it on POSIX systems, or by closing "
              "the process handle on Windows. If `proc` has already completed, raise an error. If "
              "`wait` is truthy, will wait for `proc` to complete and return the exit code (this "
              "will raise an error if `proc` is being waited for). Otherwise, return `proc`. If "
              "`signal` is provided, send it instead of SIGKILL. Signal keywords are named after "
              "their C counterparts but in lowercase with the leading SIG stripped. `signal` is "
              "ignored on Windows.") {
    janet_arity(argc, 1, 3);
    JanetProc *proc = janet_getabstract(argv, 0, &ProcAT);
    if (proc->flags & JANET_PROC_WAITED) {
        janet_panicf("cannot kill process that has already finished");
    }
#ifdef JANET_WINDOWS
    if (proc->flags & JANET_PROC_CLOSED) {
        janet_panicf("cannot close process handle that is already closed");
    }
    proc->flags |= JANET_PROC_CLOSED;
    TerminateProcess(proc->pHandle, 1);
    CloseHandle(proc->pHandle);
    CloseHandle(proc->tHandle);
#else
    int signal = -1;
    if (argc == 3) {
        signal = get_signal_kw(argv, 2);
    }
    int status = janet_os_kill((int64_t) proc->pid, signal == -1 ? SIGKILL : signal);
    if (status) {
        janet_panic(janet_strerror(errno));
    }
#endif
    /* After killing process we wait on it. */
    if (argc > 1 && janet_truthy(argv[1])) {
#ifdef JANET_EV
        os_proc_wait_impl(proc);
#else
        return os_proc_wait_impl(proc);
#endif
    } else {
        return argv[0];
    }
}

JANET_CORE_FN(os_proc_close,
              "(os/proc-close proc)",
              "Close pipes created for subprocess `proc` by `os/spawn` if they have not been "
              "closed. Then, if `proc` is not being waited for, wait. If this function waits, when "
              "`proc` completes, return the exit code of `proc`. Otherwise, return nil.") {
    janet_fixarity(argc, 1);
    JanetProc *proc = janet_getabstract(argv, 0, &ProcAT);
#ifdef JANET_EV
    if (proc->flags & JANET_PROC_OWNS_STDIN) janet_stream_close(proc->in);
    if (proc->flags & JANET_PROC_OWNS_STDOUT) janet_stream_close(proc->out);
    if (proc->flags & JANET_PROC_OWNS_STDERR) janet_stream_close(proc->err);
#else
    if (proc->flags & JANET_PROC_OWNS_STDIN) janet_file_close(proc->in);
    if (proc->flags & JANET_PROC_OWNS_STDOUT) janet_file_close(proc->out);
    if (proc->flags & JANET_PROC_OWNS_STDERR) janet_file_close(proc->err);
#endif
    proc->flags &= ~(JANET_PROC_OWNS_STDIN | JANET_PROC_OWNS_STDOUT | JANET_PROC_OWNS_STDERR);
    if (proc->flags & (JANET_PROC_WAITED | JANET_PROC_WAITING)) {
        return janet_wrap_nil();
    }
#ifdef JANET_EV
    os_proc_wait_impl(proc);
#else
    return os_proc_wait_impl(proc);
#endif
}

JANET_CORE_FN(os_proc_getpid,
              "(os/getpid)",
              "Get the process ID of the current process.") {
    janet_sandbox_assert(JANET_SANDBOX_SUBPROCESS);
    janet_fixarity(argc, 0);
    (void) argv;
    return janet_wrap_number((double) janet_os_getpid());
}

static void swap_handles(JanetHandle *handles) {
    JanetHandle temp = handles[0];
    handles[0] = handles[1];
    handles[1] = temp;
}

static void close_handle(JanetHandle handle) {
#ifdef JANET_WINDOWS
    CloseHandle(handle);
#else
    janet_os_close_fd(handle);
#endif
}

#ifdef JANET_EV

#ifndef JANET_WINDOWS
static void janet_signal_callback(JanetEVGenericMessage msg) {
    int sig = msg.tag;
    if (msg.argi) janet_interpreter_interrupt_handled(NULL);
    Janet handlerv = janet_table_get(&janet_vm.signal_handlers, janet_wrap_integer(sig));
    if (!janet_checktype(handlerv, JANET_FUNCTION)) {
        /* Let another thread/process try to handle this */
        sigset_t set;
        sigemptyset(&set);
        sigaddset(&set, sig);
#ifdef JANET_THREADS
        pthread_sigmask(SIG_BLOCK, &set, NULL);
#else
        sigprocmask(SIG_BLOCK, &set, NULL);
#endif
        raise(sig);
        return;
    }
    JanetFunction *handler = janet_unwrap_function(handlerv);
    JanetFiber *fiber = janet_fiber(handler, 64, 0, NULL);
    janet_schedule_soon(fiber, janet_wrap_nil(), JANET_SIGNAL_OK);
}

static void janet_signal_trampoline_no_interrupt(int sig) {
    /* Do not interact with global janet state here except for janet_ev_post_event, unsafe! */
    JanetEVGenericMessage msg;
    memset(&msg, 0, sizeof(msg));
    msg.tag = sig;
    janet_ev_post_event(&janet_vm, janet_signal_callback, msg);
}

static void janet_signal_trampoline(int sig) {
    /* Do not interact with global janet state here except for janet_ev_post_event, unsafe! */
    JanetEVGenericMessage msg;
    memset(&msg, 0, sizeof(msg));
    msg.tag = sig;
    msg.argi = 1;
    janet_interpreter_interrupt(NULL);
    janet_ev_post_event(&janet_vm, janet_signal_callback, msg);
}
#endif

JANET_CORE_FN(os_sigaction,
              "(os/sigaction which &opt handler interrupt-interpreter)",
              "Add a signal handler for a given action. Use nil for the `handler` argument to remove a signal handler. "
              "All signal handlers are the same as supported by `os/proc-kill`.") {
    janet_sandbox_assert(JANET_SANDBOX_SIGNAL);
    janet_arity(argc, 1, 3);
#ifdef JANET_WINDOWS
    (void) argv;
    janet_panic("unsupported on this platform");
#else
    /* TODO - per thread signal masks */
    int rc;
    int sig = get_signal_kw(argv, 0);
    JanetFunction *handler = janet_optfunction(argv, argc, 1, NULL);
    int can_interrupt = janet_optboolean(argv, argc, 2, 0);
    Janet oldhandler = janet_table_get(&janet_vm.signal_handlers, janet_wrap_integer(sig));
    if (!janet_checktype(oldhandler, JANET_NIL)) {
        janet_gcunroot(oldhandler);
    }
    if (NULL != handler) {
        Janet handlerv = janet_wrap_function(handler);
        janet_gcroot(handlerv);
        janet_table_put(&janet_vm.signal_handlers, janet_wrap_integer(sig), handlerv);
    } else {
        janet_table_put(&janet_vm.signal_handlers, janet_wrap_integer(sig), janet_wrap_nil());
    }
    struct sigaction action;
    sigset_t mask;
    sigaddset(&mask, sig);
    memset(&action, 0, sizeof(action));
    action.sa_flags |= SA_RESTART;
    if (can_interrupt) {
#ifdef JANET_NO_INTERPRETER_INTERRUPT
        janet_panic("interpreter interrupt not enabled");
#else
        action.sa_handler = janet_signal_trampoline;
#endif
    } else {
        action.sa_handler = janet_signal_trampoline_no_interrupt;
    }
    action.sa_mask = mask;
    RETRY_EINTR(rc, sigaction(sig, &action, NULL));
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, sig);
#ifdef JANET_THREADS
    pthread_sigmask(SIG_UNBLOCK, &set, NULL);
#else
    sigprocmask(SIG_UNBLOCK, &set, NULL);
#endif
    return janet_wrap_nil();
#endif
}

#endif

/* Create piped file for os/execute and os/spawn. Need to be careful that we mark
   the error flag if we can't create pipe and don't leak handles. *handle will be cleaned
   up by the calling function. If everything goes well, *handle is owned by the calling function,
   (if it is set) and the returned handle owns the other end of the pipe, which will be closed
   on GC or fclose. */
static JanetHandle make_pipes(JanetHandle *handle, int reverse, int *errflag) {
    JanetHandle handles[2];
#ifdef JANET_EV

    /* non-blocking pipes */
    if (janet_make_pipe(handles, reverse ? 2 : 1)) goto error;
    if (reverse) swap_handles(handles);
#ifdef JANET_WINDOWS
    if (!SetHandleInformation(handles[0], HANDLE_FLAG_INHERIT, 0)) goto error;
#endif
    *handle = handles[1];
    return handles[0];

#else

    /* Normal blocking pipes */
#ifdef JANET_WINDOWS
    SECURITY_ATTRIBUTES saAttr;
    memset(&saAttr, 0, sizeof(saAttr));
    saAttr.nLength = sizeof(saAttr);
    saAttr.bInheritHandle = TRUE;
    if (!CreatePipe(handles, handles + 1, &saAttr, 0)) goto error;
    if (reverse) swap_handles(handles);
    /* Don't inherit the side of the pipe owned by this process */
    if (!SetHandleInformation(handles[0], HANDLE_FLAG_INHERIT, 0)) goto error;
    *handle = handles[1];
    return handles[0];
#else
    if (janet_os_pipe(handles)) goto error;
    if (reverse) swap_handles(handles);
    *handle = handles[1];
    return handles[0];
#endif

#endif
error:
    *errflag = 1;
    return JANET_HANDLE_NONE;
}

static const JanetMethod proc_methods[] = {
    {"wait", os_proc_wait},
    {"kill", os_proc_kill},
    {"close", os_proc_close},
    /* dud methods for janet_proc_next */
    {"in", NULL},
    {"out", NULL},
    {"err", NULL},
    {NULL, NULL}
};

static int janet_proc_get(void *p, Janet key, Janet *out) {
    JanetProc *proc = (JanetProc *)p;
    if (janet_keyeq(key, "in")) {
        *out = (NULL == proc->in) ? janet_wrap_nil() : janet_wrap_abstract(proc->in);
        return 1;
    }
    if (janet_keyeq(key, "out")) {
        *out = (NULL == proc->out) ? janet_wrap_nil() : janet_wrap_abstract(proc->out);
        return 1;
    }
    if (janet_keyeq(key, "err")) {
        *out = (NULL == proc->err) ? janet_wrap_nil() : janet_wrap_abstract(proc->err);
        return 1;
    }
#ifndef JANET_WINDOWS
    if (janet_keyeq(key, "pid")) {
        *out = janet_wrap_number(proc->pid);
        return 1;
    }
#endif
    if ((-1 != proc->return_code) && janet_keyeq(key, "return-code")) {
        *out = janet_wrap_integer(proc->return_code);
        return 1;
    }
    if (!janet_checktype(key, JANET_KEYWORD)) return 0;
    return janet_getmethod(janet_unwrap_keyword(key), proc_methods, out);
}

static Janet janet_proc_next(void *p, Janet key) {
    (void) p;
    return janet_nextmethod(proc_methods, key);
}

static const JanetAbstractType ProcAT = {
    "core/process",
    janet_proc_gc,
    janet_proc_mark,
    janet_proc_get,
    NULL, /* put */
    NULL, /* marshal */
    NULL, /* unmarshal */
    NULL, /* tostring */
    NULL, /* compare */
    NULL, /* hash */
    janet_proc_next,
    JANET_ATEND_NEXT
};

static JanetHandle janet_getjstream(Janet *argv, int32_t n, void **orig) {
#ifdef JANET_EV
    JanetStream *stream = janet_checkabstract(argv[n], &janet_stream_type);
    if (stream != NULL) {
        if (stream->flags & JANET_STREAM_CLOSED)
            janet_panic("stream is closed");
        *orig = stream;
        return stream->handle;
    }
#endif
    JanetFile *f = janet_checkabstract(argv[n], &janet_file_type);
    if (f != NULL) {
        if (f->flags & JANET_FILE_CLOSED) {
            janet_panic("file is closed");
        }
        *orig = f;
#ifdef JANET_WINDOWS
        return (HANDLE) _get_osfhandle(_fileno(f->file));
#else
        return fileno(f->file);
#endif
    }
    janet_panicf("expected file|stream, got %v", argv[n]);
}

#ifdef JANET_EV
static JanetStream *get_stdio_for_handle(JanetHandle handle, void *orig, int iswrite) {
    if (orig == NULL) {
        return janet_stream(handle, iswrite ? JANET_STREAM_WRITABLE : JANET_STREAM_READABLE, NULL);
    } else if (janet_abstract_type(orig) == &janet_file_type) {
        JanetFile *jf = (JanetFile *)orig;
        uint32_t flags = 0;
        if (jf->flags & JANET_FILE_WRITE) {
            flags |= JANET_STREAM_WRITABLE;
        }
        if (jf->flags & JANET_FILE_READ) {
            flags |= JANET_STREAM_READABLE;
        }
        /* duplicate handle when converting file to stream */
#ifdef JANET_WINDOWS
        HANDLE prochandle = GetCurrentProcess();
        HANDLE newHandle = INVALID_HANDLE_VALUE;
        if (!DuplicateHandle(prochandle, handle, prochandle, &newHandle, 0, FALSE, DUPLICATE_SAME_ACCESS)) {
            return NULL;
        }
#else
        int newHandle = dup(handle);
        if (newHandle < 0) {
            return NULL;
        }
#endif
        return janet_stream(newHandle, flags, NULL);
    } else {
        return orig;
    }
}
#else
static JanetFile *get_stdio_for_handle(JanetHandle handle, void *orig, int iswrite) {
    if (NULL != orig) return (JanetFile *) orig;
#ifdef JANET_WINDOWS
    int fd = _open_osfhandle((intptr_t) handle, iswrite ? _O_WRONLY : _O_RDONLY);
    if (-1 == fd) return NULL;
    FILE *f = _fdopen(fd, iswrite ? "w" : "r");
    if (NULL == f) {
        _close(fd);
        return NULL;
    }
#else
    FILE *f = fdopen(handle, iswrite ? "w" : "r");
    if (NULL == f) return NULL;
#endif
    return janet_makejfile(f, iswrite ? JANET_FILE_WRITE : JANET_FILE_READ);
}
#endif

typedef enum {
    JANET_EXECUTE_EXECUTE,
    JANET_EXECUTE_SPAWN,
    JANET_EXECUTE_EXEC
} JanetExecuteMode;

static Janet os_execute_impl(int32_t argc, Janet *argv, JanetExecuteMode mode) {
    janet_sandbox_assert(JANET_SANDBOX_SUBPROCESS);
    janet_arity(argc, 1, 3);

    /* Get flags */
    int is_spawn = mode == JANET_EXECUTE_SPAWN;
    uint64_t flags = 0;
    if (argc > 1) {
        flags = janet_getflags(argv, 1, "epxd");
    }

    /* Get environment */
    int use_environ = !janet_flag_at(flags, 0);
    EnvBlock envp = os_execute_env(argc, argv);

    /* Get arguments */
    JanetView exargs = janet_getindexed(argv, 0);
    if (exargs.len < 1) {
        janet_panic("expected at least 1 command line argument");
    }

    /* Optional stdio redirections */
    JanetAbstract orig_in = NULL, orig_out = NULL, orig_err = NULL;
    JanetHandle new_in = JANET_HANDLE_NONE, new_out = JANET_HANDLE_NONE, new_err = JANET_HANDLE_NONE;
    JanetHandle pipe_in = JANET_HANDLE_NONE, pipe_out = JANET_HANDLE_NONE, pipe_err = JANET_HANDLE_NONE;
    int stderr_is_stdout = 0;
    int pipe_errflag = 0; /* Track errors setting up pipes */
    int pipe_owner_flags = (is_spawn && (flags & 0x8)) ? JANET_PROC_ALLOW_ZOMBIE : 0;

    /* Get optional redirections */
    if (argc > 2 && (mode != JANET_EXECUTE_EXEC)) {
        JanetDictView tab = janet_getdictionary(argv, 2);
        Janet maybe_stdin = janet_dictionary_get(tab.kvs, tab.cap, janet_ckeywordv("in"));
        Janet maybe_stdout = janet_dictionary_get(tab.kvs, tab.cap, janet_ckeywordv("out"));
        Janet maybe_stderr = janet_dictionary_get(tab.kvs, tab.cap, janet_ckeywordv("err"));
        if (is_spawn && janet_keyeq(maybe_stdin, "pipe")) {
            new_in = make_pipes(&pipe_in, 1, &pipe_errflag);
            pipe_owner_flags |= JANET_PROC_OWNS_STDIN;
        } else if (!janet_checktype(maybe_stdin, JANET_NIL)) {
            new_in = janet_getjstream(&maybe_stdin, 0, &orig_in);
        }
        if (is_spawn && janet_keyeq(maybe_stdout, "pipe")) {
            new_out = make_pipes(&pipe_out, 0, &pipe_errflag);
            pipe_owner_flags |= JANET_PROC_OWNS_STDOUT;
        } else if (!janet_checktype(maybe_stdout, JANET_NIL)) {
            new_out = janet_getjstream(&maybe_stdout, 0, &orig_out);
        }
        if (is_spawn && janet_keyeq(maybe_stderr, "pipe")) {
            new_err = make_pipes(&pipe_err, 0, &pipe_errflag);
            pipe_owner_flags |= JANET_PROC_OWNS_STDERR;
        } else if (janet_keyeq(maybe_stderr, "out")) {
            stderr_is_stdout = 1;
        } else if (!janet_checktype(maybe_stderr, JANET_NIL)) {
            new_err = janet_getjstream(&maybe_stderr, 0, &orig_err);
        }
    }

    /* Optional working directory. Available for both os/execute and os/spawn. */
    const char *chdir_path = NULL;
    if (argc > 2) {
        JanetDictView tab = janet_getdictionary(argv, 2);
        Janet workdir = janet_dictionary_get(tab.kvs, tab.cap, janet_ckeywordv("cd"));
        if (janet_checktype(workdir, JANET_STRING)) {
            chdir_path = (const char *) janet_unwrap_string(workdir);
#ifndef JANET_SPAWN_CHDIR
            janet_panicf(":cd argument not supported on this system - %s", chdir_path);
#endif
        } else if (!janet_checktype(workdir, JANET_NIL)) {
            janet_panicf("expected string for :cd argumnet, got %v", workdir);
        }
    }

    /* Clean up if any of the pipes have any issues */
    if (pipe_errflag) {
        if (pipe_in != JANET_HANDLE_NONE) close_handle(pipe_in);
        if (pipe_out != JANET_HANDLE_NONE) close_handle(pipe_out);
        if (pipe_err != JANET_HANDLE_NONE) close_handle(pipe_err);
        janet_panic("failed to create pipes");
    }

#ifdef JANET_WINDOWS

    HANDLE pHandle, tHandle;
    SECURITY_ATTRIBUTES saAttr;
    PROCESS_INFORMATION processInfo;
    STARTUPINFO startupInfo;
    LPCSTR lpCurrentDirectory = NULL;
    memset(&saAttr, 0, sizeof(saAttr));
    memset(&processInfo, 0, sizeof(processInfo));
    memset(&startupInfo, 0, sizeof(startupInfo));
    startupInfo.cb = sizeof(startupInfo);
    startupInfo.dwFlags |= STARTF_USESTDHANDLES;
    saAttr.nLength = sizeof(saAttr);

    JanetBuffer *buf = os_exec_escape(exargs);
    if (buf->count > 8191) {
        if (pipe_in != JANET_HANDLE_NONE) CloseHandle(pipe_in);
        if (pipe_out != JANET_HANDLE_NONE) CloseHandle(pipe_out);
        if (pipe_err != JANET_HANDLE_NONE) CloseHandle(pipe_err);
        janet_panic("command line string too long (max 8191 characters)");
    }
    const char *path = (const char *) janet_unwrap_string(exargs.items[0]);

    if (chdir_path != NULL) {
        lpCurrentDirectory = chdir_path;
    }

    /* Do IO redirection */

    if (pipe_in != JANET_HANDLE_NONE) {
        startupInfo.hStdInput = pipe_in;
    } else if (new_in != JANET_HANDLE_NONE) {
        startupInfo.hStdInput = new_in;
    } else {
        startupInfo.hStdInput = (HANDLE) _get_osfhandle(_fileno(stdin));
    }

    if (pipe_out != JANET_HANDLE_NONE) {
        startupInfo.hStdOutput = pipe_out;
    } else if (new_out != JANET_HANDLE_NONE) {
        startupInfo.hStdOutput = new_out;
    } else {
        startupInfo.hStdOutput = (HANDLE) _get_osfhandle(_fileno(stdout));
    }

    if (pipe_err != JANET_HANDLE_NONE) {
        startupInfo.hStdError = pipe_err;
    } else if (new_err != NULL) {
        startupInfo.hStdError = new_err;
    } else if (stderr_is_stdout) {
        startupInfo.hStdError = startupInfo.hStdOutput;
    } else {
        startupInfo.hStdError = (HANDLE) _get_osfhandle(_fileno(stderr));
    }

    int cp_failed = 0;
    DWORD cp_error_code = 0;
    if (!CreateProcess(janet_flag_at(flags, 1) ? NULL : path,
                       (char *) buf->data, /* Single CLI argument */
                       &saAttr, /* no proc inheritance */
                       &saAttr, /* no thread inheritance */
                       TRUE, /* handle inheritance */
                       0, /* flags */
                       use_environ ? NULL : envp, /* pass in environment */
                       lpCurrentDirectory,
                       &startupInfo,
                       &processInfo)) {
        cp_failed = 1;
        cp_error_code = GetLastError();
    }

    if (pipe_in != JANET_HANDLE_NONE) CloseHandle(pipe_in);
    if (pipe_out != JANET_HANDLE_NONE) CloseHandle(pipe_out);
    if (pipe_err != JANET_HANDLE_NONE) CloseHandle(pipe_err);

    os_execute_cleanup(envp, NULL);

    if (cp_failed)  {
        char msgbuf[256];
        msgbuf[0] = '\0';
        FormatMessage(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
                      NULL,
                      cp_error_code,
                      MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
                      msgbuf,
                      sizeof(msgbuf),
                      NULL);
        if (!*msgbuf) snprintf(msgbuf, sizeof(msgbuf), "%" PRIu32, (uint32_t) cp_error_code);
        char *c = msgbuf;
        while (*c) {
            if (*c == '\n' || *c == '\r') {
                *c = '\0';
                break;
            }
            c++;
        }
        janet_panicf("failed to create process: %s", janet_cstringv(msgbuf));
    }

    pHandle = processInfo.hProcess;
    tHandle = processInfo.hThread;

#else

    /* Result */
    int status = 0;

    const char **child_argv = janet_smalloc(sizeof(char *) * ((size_t) exargs.len + 1));
    for (int32_t i = 0; i < exargs.len; i++)
        child_argv[i] = janet_getcstring(exargs.items, i);
    child_argv[exargs.len] = NULL;
    /* Coerce to form that works for spawn. I'm fairly confident no implementation
     * of posix_spawn would modify the argv array passed in. */
    char *const *cargv = (char *const *)child_argv;

    if (use_environ) {
        janet_lock_environ();
    }

    /* exec mode */
    if (mode == JANET_EXECUTE_EXEC) {
        /* Only a failure returns, and the panic reads errno rather than the
         * result, so the result is deliberately discarded. */
#ifdef JANET_PLAN9
        (void) exec(cargv[0], cargv);
#else
        if (!use_environ) {
            environ = envp;
        }
        (void) janet_os_exec(cargv[0], cargv, janet_flag_at(flags, 1) ? 1 : 0);
#endif
        janet_panicf("%p: %s", cargv[0], janet_strerror(errno ? errno : ENOENT));
    }

#ifndef JANET_NO_SPAWN
    /* Use posix_spawn to spawn new process */

    /* Posix spawn setup */
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
#ifdef JANET_SPAWN_CHDIR
    if (chdir_path != NULL) {
#ifdef JANET_SPAWN_CHDIR_NO_NP
        posix_spawn_file_actions_addchdir(&actions, chdir_path);
#else
        posix_spawn_file_actions_addchdir_np(&actions, chdir_path);
#endif
    }
#endif
    if (pipe_in != JANET_HANDLE_NONE) {
        posix_spawn_file_actions_adddup2(&actions, pipe_in, 0);
        posix_spawn_file_actions_addclose(&actions, pipe_in);
    } else if (new_in != JANET_HANDLE_NONE && new_in != 0) {
        posix_spawn_file_actions_adddup2(&actions, new_in, 0);
        if (new_in != new_out && new_in != new_err)
            posix_spawn_file_actions_addclose(&actions, new_in);
    }
    if (pipe_out != JANET_HANDLE_NONE) {
        posix_spawn_file_actions_adddup2(&actions, pipe_out, 1);
        posix_spawn_file_actions_addclose(&actions, pipe_out);
    } else if (new_out != JANET_HANDLE_NONE && new_out != 1) {
        posix_spawn_file_actions_adddup2(&actions, new_out, 1);
        if (new_out != new_err)
            posix_spawn_file_actions_addclose(&actions, new_out);
    }
    if (pipe_err != JANET_HANDLE_NONE) {
        posix_spawn_file_actions_adddup2(&actions, pipe_err, 2);
        posix_spawn_file_actions_addclose(&actions, pipe_err);
    } else if (new_err != JANET_HANDLE_NONE && new_err != 2) {
        posix_spawn_file_actions_adddup2(&actions, new_err, 2);
        posix_spawn_file_actions_addclose(&actions, new_err);
    } else if (stderr_is_stdout) {
        posix_spawn_file_actions_adddup2(&actions, 1, 2);
    }

    pid_t pid;
    if (janet_flag_at(flags, 1)) {
        status = posix_spawnp(&pid,
                              child_argv[0], &actions, NULL, cargv,
                              use_environ ? environ : envp);
    } else {
        status = posix_spawn(&pid,
                             child_argv[0], &actions, NULL, cargv,
                             use_environ ? environ : envp);
    }

    posix_spawn_file_actions_destroy(&actions);

    if (pipe_in != JANET_HANDLE_NONE) close(pipe_in);
    if (pipe_out != JANET_HANDLE_NONE) close(pipe_out);
    if (pipe_err != JANET_HANDLE_NONE) close(pipe_err);

    if (use_environ) {
        janet_unlock_environ();
    }

    os_execute_cleanup(envp, child_argv);
    if (status) {
        /* correct for macos bug where errno is not set */
        janet_panicf("%p: %s", argv[0], janet_strerror(errno ? errno : ENOENT));
    }

#endif
#endif
#ifndef JANET_NO_SPAWN
    JanetProc *proc = janet_abstract(&ProcAT, sizeof(JanetProc));
    proc->return_code = -1;
#ifdef JANET_WINDOWS
    proc->pHandle = pHandle;
    proc->tHandle = tHandle;
#else
    proc->pid = pid;
#endif
    proc->in = NULL;
    proc->out = NULL;
    proc->err = NULL;
    proc->flags = pipe_owner_flags;
    if (janet_flag_at(flags, 2)) {
        proc->flags |= JANET_PROC_ERROR_NONZERO;
    }
    if (is_spawn) {
        /* Only set up pointers to stdin, stdout, and stderr if os/spawn. */
        if (new_in != JANET_HANDLE_NONE) {
            proc->in = get_stdio_for_handle(new_in, orig_in, 1);
            if (NULL == proc->in) janet_panic("failed to construct proc");
        }
        if (new_out != JANET_HANDLE_NONE) {
            proc->out = get_stdio_for_handle(new_out, orig_out, 0);
            if (NULL == proc->out) janet_panic("failed to construct proc");
        }
        if (new_err != JANET_HANDLE_NONE) {
            proc->err = get_stdio_for_handle(new_err, orig_err, 0);
            if (NULL == proc->err) janet_panic("failed to construct proc");
        }
        return janet_wrap_abstract(proc);
    } else {
#ifdef JANET_EV
        os_proc_wait_impl(proc);
#else
        return os_proc_wait_impl(proc);
#endif
    }
#endif
}

JANET_CORE_FN(os_execute,
              "(os/execute args &opt flags env)",
              "Execute a program on the system and return the exit code. `args` is an array/tuple "
              "of strings. The first string is the name of the program and the remainder are "
              "arguments passed to the program. `flags` is a keyword made from the following "
              "characters that modifies how the program executes:\n"
              "* :e - enables passing an environment to the program. Without 'e', the "
              "current environment is inherited.\n"
              "* :p - allows searching the current PATH for the program to execute. "
              "Without this flag, the first element of `args` must be an absolute path.\n"
              "* :x - raises error if exit code is non-zero.\n"
              "* :d - prevents the garbage collector terminating the program (if still running) "
              "and calling the equivalent of `os/proc-wait` (allows zombie processes).\n"
              "`env` is a table/struct mapping environment variables to values. It can also "
              "contain the keys :in, :out, and :err, which allow redirecting stdio in the "
              "subprocess. :in, :out, and :err should be core/file or core/stream values. "
              "If core/stream values are used, the caller is responsible for ensuring pipes do not "
              "cause the program to block and deadlock.") {
    return os_execute_impl(argc, argv, JANET_EXECUTE_EXECUTE);
}

JANET_CORE_FN(os_spawn,
              "(os/spawn args &opt flags env)",
              "Execute a program on the system and return a core/process value representing the "
              "spawned subprocess. Takes the same arguments as `os/execute` but does not wait for "
              "the subprocess to complete. Unlike `os/execute`, the value `:pipe` can be used for "
              ":in, :out and :err keys in `env`. If used, the returned core/process will have a "
              "writable stream in the :in field and readable streams in the :out and :err fields. "
              "On non-Windows systems, the subprocess PID will be in the :pid field. The caller is "
              "responsible for waiting on the process (e.g. by calling `os/proc-wait` on the "
              "returned core/process value) to avoid creating zombie process. After the subprocess "
              "completes, the exit value is in the :return-code field. If `flags` includes 'x', a "
              "non-zero exit code will cause a waiting fiber to raise an error. The use of "
              "`:pipe` may fail if there are too many active file descriptors. The caller is "
              "responsible for closing pipes created by `:pipe` (either individually or using "
              "`os/proc-close`). Similar to `os/execute`, the caller is responsible for ensuring "
              "pipes do not cause the program to block and deadlock. As a special case, the stream passed to `:err` "
              "can be the keyword `:out` to redirect stderr to stdout in the subprocess.") {
    return os_execute_impl(argc, argv, JANET_EXECUTE_SPAWN);
}

JANET_CORE_FN(os_posix_exec,
              "(os/posix-exec args &opt flags env)",
              "Use the execvpe or execve system calls to replace the current process with an interface similar to os/execute. "
              "However, instead of creating a subprocess, the current process is replaced. Is not supported on Windows, and "
              "does not allow redirection of stdio.") {
#ifdef JANET_WINDOWS
    (void) argc;
    (void) argv;
    janet_panic("not supported on Windows");
#else
    return os_execute_impl(argc, argv, JANET_EXECUTE_EXEC);
#endif
}

JANET_CORE_FN(os_posix_fork,
              "(os/posix-fork)",
              "Make a `fork` system call and create a new process. Return nil if in the new process, otherwise a core/process object (as returned by os/spawn). "
              "Not supported on all systems (POSIX and Plan 9 only).") {
    janet_sandbox_assert(JANET_SANDBOX_SUBPROCESS);
    janet_fixarity(argc, 0);
    (void) argv;
#ifdef JANET_WINDOWS
    janet_panic("not supported on Windows");
#else
    pid_t result;
#ifdef JANET_PLAN9
    result = fork();
#else
    result = (pid_t) janet_os_fork();
#endif
    if (result == -1) {
        janet_panic(janet_strerror(errno));
    }
    if (result) {
        JanetProc *proc = janet_abstract(&ProcAT, sizeof(JanetProc));
        memset(proc, 0, sizeof(JanetProc));
        proc->pid = result;
        proc->flags = JANET_PROC_ALLOW_ZOMBIE;
        return janet_wrap_abstract(proc);
    }
    return janet_wrap_nil();
#endif
}

JANET_CORE_FN(os_posix_chroot,
              "(os/posix-chroot dirname)",
              "Call `chroot` to change the root directory to `dirname`. "
              "Not supported on all systems (POSIX only).") {
    janet_sandbox_assert(JANET_SANDBOX_CHROOT);
    janet_fixarity(argc, 1);
#if defined(JANET_WINDOWS) || defined(JANET_PLAN9)
    (void) argv;
    janet_panic("not supported on Windows or Plan 9");
#else
    const char *root = janet_getcstring(argv, 0);
    int result = janet_os_chroot(root);
    if (result == -1) {
        janet_panic(janet_strerror(errno));
    }
    return janet_wrap_nil();
#endif
}

#ifdef JANET_EV
/* Runs in a separate thread */
static JanetEVGenericMessage os_shell_subr(JanetEVGenericMessage args) {
    int stat = janet_os_system((const char *) args.argp);
    janet_free(args.argp);
    if (args.argi) {
        args.tag = JANET_EV_TCTAG_INTEGER;
    } else {
        args.tag = JANET_EV_TCTAG_BOOLEAN;
    }
    args.argi = stat;
    return args;
}
#endif

JANET_CORE_FN(os_shell,
              "(os/shell str)",
              "Pass a command string str directly to the system shell.") {
    janet_sandbox_assert(JANET_SANDBOX_SUBPROCESS);
    janet_arity(argc, 0, 1);
    const char *cmd = argc
                      ? janet_getcstring(argv, 0)
                      : NULL;
#ifdef JANET_EV
    char *cmd_copy = NULL;
    if (cmd != NULL) {
        size_t cmdlen = strlen(cmd);
        cmd_copy = janet_malloc(cmdlen + 1);
        memcpy(cmd_copy, cmd, cmdlen);
        cmd_copy[cmdlen] = '\0';
    }
    janet_ev_threaded_await(os_shell_subr, 0, argc, cmd_copy);
#else
    int stat = janet_os_system(cmd);
    return argc
           ? janet_wrap_integer(stat)
           : janet_wrap_boolean(stat);
#endif
}

#endif /* JANET_NO_PROCESSES */

#ifdef JANET_ZIG_OS_ENVIRON

int32_t janet_os_environ_count(char *const *env);
int32_t janet_os_environ_separator(const char *entry);
const char *janet_os_getenv(const char *name);
int32_t janet_os_setenv(const char *name, const char *value);

#else

int32_t janet_os_environ_count(char *const *env) {
    int32_t count = 0;
    while (env[count]) count++;
    return count;
}

int32_t janet_os_environ_separator(const char *entry) {
    const char *separator = strchr(entry, '=');
    return separator ? (int32_t)(separator - entry) : -1;
}

const char *janet_os_getenv(const char *name) {
    return getenv(name);
}

int32_t janet_os_setenv(const char *name, const char *value) {
#ifdef JANET_WINDOWS
    return value ? _putenv_s(name, value) : _putenv_s(name, "");
#elif defined(JANET_PLAN9)
    if (value) putenv(name, value);
    else unsetenv(name);
    return 0;
#else
    return value ? setenv(name, value, 1) : unsetenv(name);
#endif
}

#endif /* JANET_ZIG_OS_ENVIRON */

#ifndef JANET_PLAN9
JANET_CORE_FN(os_environ,
              "(os/environ)",
              "Get a copy of the OS environment table.") {
    janet_sandbox_assert(JANET_SANDBOX_ENV);
    (void) argv;
    janet_fixarity(argc, 0);
    janet_lock_environ();
    int32_t nenv = janet_os_environ_count(environ);
    JanetTable *t = janet_table(nenv);
    for (int32_t i = 0; i < nenv; i++) {
        char *e = environ[i];
        int32_t separator = janet_os_environ_separator(e);
        if (separator < 0) {
            janet_unlock_environ();
            janet_panic("no '=' in environ");
        }
        char *v = e + separator + 1;
        int32_t val_len = (int32_t) strlen(v);
        janet_table_put(
            t,
            janet_stringv((const uint8_t *)e, separator),
            janet_stringv((const uint8_t *)v, val_len)
        );
    }
    janet_unlock_environ();
    return janet_wrap_table(t);
}
#endif

JANET_CORE_FN(os_getenv,
              "(os/getenv variable &opt dflt)",
              "Get the string value of an environment variable.") {
    janet_sandbox_assert(JANET_SANDBOX_ENV);
    janet_arity(argc, 1, 2);
    const char *cstr = janet_getcstring(argv, 0);
    janet_lock_environ();
    const char *res = janet_os_getenv(cstr);
    Janet ret = res
                ? janet_cstringv(res)
                : argc == 2
                ? argv[1]
                : janet_wrap_nil();
    janet_unlock_environ();
    return ret;
}

JANET_CORE_FN(os_setenv,
              "(os/setenv variable value)",
              "Set an environment variable.") {
    janet_sandbox_assert(JANET_SANDBOX_ENV);
    janet_arity(argc, 1, 2);
    const char *ks = janet_getcstring(argv, 0);
    const char *vs = janet_optcstring(argv, argc, 1, NULL);
    janet_lock_environ();
    (void) janet_os_setenv(ks, vs);
    janet_unlock_environ();
    return janet_wrap_nil();
}

#ifdef JANET_ZIG_OS_TIME

double janet_os_time_now(void);
void janet_os_sleep(double seconds);

#else

double janet_os_time_now(void) {
    return (double)(time(NULL));
}

void janet_os_sleep(double delay) {
#ifdef JANET_WINDOWS
    Sleep((DWORD)(delay * 1000));
#else
    int rc;
    struct timespec ts;
    ts.tv_sec = (time_t) delay;
    ts.tv_nsec = (delay <= UINT32_MAX)
                 ? (long)((delay - ((uint32_t)delay)) * 1000000000)
                 : 0;
    RETRY_EINTR(rc, nanosleep(&ts, &ts));
#endif
}

#endif /* JANET_ZIG_OS_TIME */

JANET_CORE_FN(os_time,
              "(os/time)",
              "Get the current time expressed as the number of whole seconds since "
              "January 1, 1970, the Unix epoch. Returns a real number.") {
    janet_fixarity(argc, 0);
    (void) argv;
    return janet_wrap_number(janet_os_time_now());
}

JANET_CORE_FN(os_clock,
              "(os/clock &opt source format)",
              "Return the current time of the requested clock source.\n\n"
              "The `source` argument selects the clock source to use, when not specified the default "
              "is `:realtime`:\n"
              "- :realtime: Return the real (i.e., wall-clock) time. This clock is affected by discontinuous "
              "  jumps in the system time\n"
              "- :monotonic: Return the number of whole + fractional seconds since some fixed point in "
              "  time. The clock is guaranteed to be non-decreasing in real time.\n"
              "- :cputime: Return the CPU time consumed by this process  (i.e. all threads in the process)\n"
              "The `format` argument selects the type of output, when not specified the default is `:double`:\n"
              "- :double: Return the number of seconds + fractional seconds as a double\n"
              "- :int: Return the number of seconds as an integer\n"
              "- :tuple: Return a 2 integer tuple [seconds, nanoseconds]\n") {
    enum JanetTimeSource source;
    janet_sandbox_assert(JANET_SANDBOX_HRTIME);
    janet_arity(argc, 0, 2);

    JanetKeyword sourcestr = janet_optkeyword(argv, argc, 0, NULL);
    if (sourcestr == NULL || janet_cstrcmp(sourcestr, "realtime") == 0) {
        source = JANET_TIME_REALTIME;
    } else if (janet_cstrcmp(sourcestr, "monotonic") == 0) {
        source = JANET_TIME_MONOTONIC;
    } else if (janet_cstrcmp(sourcestr, "cputime") == 0) {
        source = JANET_TIME_CPUTIME;
    } else {
        janet_panicf("expected :realtime, :monotonic, or :cputime, got %v", argv[0]);
    }

    struct timespec tv;
    if (janet_gettime(&tv, source)) janet_panic("could not get time");

    JanetKeyword formatstr = janet_optkeyword(argv, argc, 1, NULL);
    if (formatstr == NULL || janet_cstrcmp(formatstr, "double") == 0) {
        double dtime = (double)(tv.tv_sec + (tv.tv_nsec / 1E9));
        return janet_wrap_number(dtime);
    } else if (janet_cstrcmp(formatstr, "int") == 0) {
        return janet_wrap_number((double)(tv.tv_sec));
    } else if (janet_cstrcmp(formatstr, "tuple") == 0) {
        Janet tup[2] = {janet_wrap_number((double)tv.tv_sec),
                        janet_wrap_number((double)tv.tv_nsec)
                       };
        return janet_wrap_tuple(janet_tuple_n(tup, 2));
    } else {
        janet_panicf("expected :double, :int, or :tuple, got %v", argv[1]);
    }
}

JANET_CORE_FN(os_sleep,
              "(os/sleep n)",
              "Suspend the program for `n` seconds. `n` can be a real number. Returns "
              "nil.") {
    janet_fixarity(argc, 1);
    double delay = janet_getnumber(argv, 0);
    if (delay < 0) janet_panic("invalid argument to sleep");
    janet_os_sleep(delay);
    return janet_wrap_nil();
}

JANET_CORE_FN(os_isatty,
              "(os/isatty &opt file)",
              "Returns true if `file` is a terminal. If `file` is not specified, "
              "it will default to standard output.") {
    janet_arity(argc, 0, 1);
    FILE *f = (argc == 1) ? janet_getfile(argv, 0, NULL) : stdout;
#ifdef JANET_WINDOWS
    int fd = _fileno(f);
    if (fd == -1) janet_panic("not a valid stream");
    return janet_wrap_boolean(_isatty(fd));
#else
    int fd = fileno(f);
    if (fd == -1) janet_panic(janet_strerror(errno));
    return janet_wrap_boolean(isatty(fd));
#endif
}

#ifdef JANET_ZIG_OS_FS

int32_t janet_os_getcwd(char *buffer, int32_t size);
int32_t janet_os_mkdir(const char *path);
int32_t janet_os_rmdir(const char *path);
int32_t janet_os_chdir(const char *path);
int32_t janet_os_remove(const char *path);
int32_t janet_os_rename(const char *oldpath, const char *newpath);

#else

int32_t janet_os_getcwd(char *buffer, int32_t size) {
#ifdef JANET_WINDOWS
    return _getcwd(buffer, size) ? 0 : -1;
#else
    return getcwd(buffer, (size_t) size) ? 0 : -1;
#endif
}

int32_t janet_os_mkdir(const char *path) {
#ifdef JANET_WINDOWS
    return _mkdir(path);
#else
    return mkdir(path, S_IRUSR | S_IWUSR | S_IXUSR | S_IRGRP | S_IWGRP | S_IXGRP | S_IROTH | S_IXOTH);
#endif
}

int32_t janet_os_rmdir(const char *path) {
#ifdef JANET_WINDOWS
    return _rmdir(path);
#elif defined(JANET_PLAN9)
    return remove(path);
#else
    return rmdir(path);
#endif
}

int32_t janet_os_chdir(const char *path) {
#ifdef JANET_WINDOWS
    return _chdir(path);
#else
    return chdir(path);
#endif
}

int32_t janet_os_remove(const char *path) {
    return remove(path);
}

int32_t janet_os_rename(const char *oldpath, const char *newpath) {
    return rename(oldpath, newpath);
}

#endif /* JANET_ZIG_OS_FS */

JANET_CORE_FN(os_cwd,
              "(os/cwd)",
              "Returns the current working directory.") {
    janet_fixarity(argc, 0);
    (void) argv;
    char buf[FILENAME_MAX];
    if (janet_os_getcwd(buf, FILENAME_MAX)) janet_panic("could not get current directory");
    return janet_cstringv(buf);
}

JANET_CORE_FN(os_cryptorand,
              "(os/cryptorand n &opt buf)",
              "Get or append `n` bytes of good quality random data provided by the OS. Returns a new buffer or `buf`.") {
    JanetBuffer *buffer;
    janet_arity(argc, 1, 2);
    int32_t offset;
    int32_t n = janet_getinteger(argv, 0);
    if (n < 0) janet_panic("expected positive integer");
    if (argc == 2) {
        buffer = janet_getbuffer(argv, 1);
        offset = buffer->count;
    } else {
        offset = 0;
        buffer = janet_buffer(n);
    }
    /* We could optimize here by adding setcount_uninit */
    janet_buffer_setcount(buffer, offset + n);

    if (janet_cryptorand(buffer->data + offset, n) != 0)
        janet_panic("unable to get sufficient random data");

    return janet_wrap_buffer(buffer);
}

/* Helper function to get given or current time as local or UTC struct tm.
 * - arg n+0: optional time_t to be converted, uses current time if not given
 * - arg n+1: optional truthy to indicate the convnersion uses local time */
static struct tm *time_to_tm(const Janet *argv, int32_t argc, int32_t n, struct tm *t_infos) {
    time_t t;
    if (argc > n && !janet_checktype(argv[n], JANET_NIL)) {
        int64_t integer = janet_getinteger64(argv, n);
        t = (time_t) integer;
    } else {
        time(&t);
    }
    struct tm *t_info = NULL;
    if (argc > n + 1 && janet_truthy(argv[n + 1])) {
        /* local time */
#ifdef JANET_WINDOWS
        _tzset();
        localtime_s(t_infos, &t);
        t_info = t_infos;
#elif defined(JANET_PLAN9)
        t_info = localtime(&t);
#else
        tzset();
        t_info = localtime_r(&t, t_infos);
#endif
    } else {
        /* utc time */
#ifdef JANET_WINDOWS
        gmtime_s(t_infos, &t);
        t_info = t_infos;
#elif defined(JANET_PLAN9)
        t_info = gmtime(&t);
#else
        t_info = gmtime_r(&t, t_infos);
#endif
    }
    return t_info;
}

JANET_CORE_FN(os_date,
              "(os/date &opt time local)",
              "Returns the given time as a date struct, or the current time if `time` is not given. "
              "Date is given in UTC unless `local` is truthy, in which case the date is formatted for "
              "the local timezone. Returns a struct with following key values. Note that all numbers are 0-indexed.\n\n"
              "* :seconds - number of seconds [0-61]\n\n"
              "* :minutes - number of minutes [0-59]\n\n"
              "* :hours - number of hours [0-23]\n\n"
              "* :month-day - day of month [0-30]\n\n"
              "* :month - month of year [0, 11]\n\n"
              "* :year - years since year 0 (e.g. 2019)\n\n"
              "* :week-day - day of the week [0-6]\n\n"
              "* :year-day - day of the year [0-365]\n\n"
              "* :dst - if Day Light Savings is in effect\n\n"
              "You can set local timezone by setting TZ environment variable. "
              "See tzset(<time.h>) or _tzset(<time.h>) for further details.") {
    janet_arity(argc, 0, 2);
    (void) argv;
    struct tm t_infos;
    struct tm *t_info = time_to_tm(argv, argc, 0, &t_infos);
    JanetKV *st = janet_struct_begin(9);
    janet_struct_put(st, janet_ckeywordv("seconds"), janet_wrap_number(t_info->tm_sec));
    janet_struct_put(st, janet_ckeywordv("minutes"), janet_wrap_number(t_info->tm_min));
    janet_struct_put(st, janet_ckeywordv("hours"), janet_wrap_number(t_info->tm_hour));
    janet_struct_put(st, janet_ckeywordv("month-day"), janet_wrap_number(t_info->tm_mday - 1));
    janet_struct_put(st, janet_ckeywordv("month"), janet_wrap_number(t_info->tm_mon));
    janet_struct_put(st, janet_ckeywordv("year"), janet_wrap_number(t_info->tm_year + 1900));
    janet_struct_put(st, janet_ckeywordv("week-day"), janet_wrap_number(t_info->tm_wday));
    janet_struct_put(st, janet_ckeywordv("year-day"), janet_wrap_number(t_info->tm_yday));
    janet_struct_put(st, janet_ckeywordv("dst"), janet_wrap_boolean(t_info->tm_isdst));
    return janet_wrap_struct(janet_struct_end(st));
}

#define SIZETIMEFMT 250

JANET_CORE_FN(os_strftime,
              "(os/strftime fmt &opt time local)",
              "Format the given time as a string, or the current time if `time` is not given. "
              "The time is formatted according to the same rules as the ISO C89 function strftime(). "
              "The time is formatted in UTC unless `local` is truthy, in which case the date is formatted for "
              "the local timezone. You can set local timezone by setting TZ environment variable. "
              "See tzset(<time.h>) or _tzset(<time.h>) for further details.") {
    janet_arity(argc, 1, 3);
    const char *fmt = janet_getcstring(argv, 0);
    /* ANSI X3.159-1989, section 4.12.3.5 "The strftime function" */
    static const char *valid = "aAbBcdHIjmMpSUwWxXyYZ%";
    const char *p = fmt;
    while (*p) {
        if (*p++ == '%') {
            if (!*p) {
                janet_panic("invalid conversion specifier");
            }
            if (!strchr(valid, *p)) {
                janet_panicf("invalid conversion specifier '%%%c'", *p);
            }
            p++;
        }
    }
    struct tm t_infos;
    struct tm *t_info = time_to_tm(argv, argc, 1, &t_infos);
    char buf[SIZETIMEFMT];
    (void)strftime(buf, sizeof(buf), fmt, t_info);
    return janet_cstringv(buf);
}

static int entry_getdst(Janet env_entry) {
    Janet v;
    if (janet_checktype(env_entry, JANET_TABLE)) {
        JanetTable *entry = janet_unwrap_table(env_entry);
        v = janet_table_get_keyword(entry, "dst");
    } else if (janet_checktype(env_entry, JANET_STRUCT)) {
        const JanetKV *entry = janet_unwrap_struct(env_entry);
        v = janet_struct_get(entry, janet_ckeywordv("dst"));
    } else {
        v = janet_wrap_nil();
    }
    if (janet_checktype(v, JANET_NIL)) {
        return -1;
    } else {
        return janet_truthy(v);
    }
}

#ifdef JANET_WINDOWS
typedef int32_t timeint_t;
#else
typedef int64_t timeint_t;
#endif

static timeint_t entry_getint(Janet env_entry, char *field) {
    Janet i;
    if (janet_checktype(env_entry, JANET_TABLE)) {
        JanetTable *entry = janet_unwrap_table(env_entry);
        i = janet_table_get_keyword(entry, field);
    } else if (janet_checktype(env_entry, JANET_STRUCT)) {
        const JanetKV *entry = janet_unwrap_struct(env_entry);
        i = janet_struct_get(entry, janet_ckeywordv(field));
    } else {
        return 0;
    }

    if (janet_checktype(i, JANET_NIL)) {
        return 0;
    }

#ifdef JANET_WINDOWS
    if (!janet_checkint(i)) {
        janet_panicf("bad slot #%s, expected 32 bit signed integer, got %v",
                     field, i);
    }
#else
    if (!janet_checkint64(i)) {
        janet_panicf("bad slot #%s, expected 64 bit signed integer, got %v",
                     field, i);
    }
#endif

    return (timeint_t)janet_unwrap_number(i);
}

JANET_CORE_FN(os_mktime,
              "(os/mktime date-struct &opt local)",
              "Get the broken down date-struct time expressed as the number "
              "of seconds since January 1, 1970, the Unix epoch. "
              "Returns a real number. "
              "Date is given in UTC unless `local` is truthy, in which case the "
              "date is computed for the local timezone.\n\n"
              "Inverse function to os/date.") {
    janet_arity(argc, 1, 2);
    time_t t;
    struct tm t_info;

    /* Use memset instead of = {0} to silence paranoid warning in macos */
    memset(&t_info, 0, sizeof(t_info));

    if (!janet_checktype(argv[0], JANET_TABLE) &&
            !janet_checktype(argv[0], JANET_STRUCT))
        janet_panic_type(argv[0], 0, JANET_TFLAG_DICTIONARY);

    t_info.tm_sec = entry_getint(argv[0], "seconds");
    t_info.tm_min = entry_getint(argv[0], "minutes");
    t_info.tm_hour = entry_getint(argv[0], "hours");
    t_info.tm_mday = entry_getint(argv[0], "month-day") + 1;
    t_info.tm_mon = entry_getint(argv[0], "month");
    t_info.tm_year = entry_getint(argv[0], "year") - 1900;
    t_info.tm_isdst = entry_getdst(argv[0]);

    if (argc >= 2 && janet_truthy(argv[1])) {
        /* local time */
        t = mktime(&t_info);
    } else {
        /* utc time */
#ifdef JANET_NO_UTC_MKTIME
        janet_panic("os/mktime UTC not supported on this platform");
#else
        t = timegm(&t_info);
#endif
    }

    if (t == (time_t) -1) {
        janet_panicf("%s", janet_strerror(errno));
    }

    return janet_wrap_number((double)t);
}

#ifdef JANET_ZIG_OS_FS_PATHS

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

#else

#ifndef JANET_WINDOWS

void *janet_os_dir_open(const char *path) {
    return opendir(path);
}

/* Report the next entry that is neither "." nor "..", returning 1 with a
 * borrowed name, 0 at the end of the stream, or -1 with errno set. */
int32_t janet_os_dir_next(void *handle, const char **name) {
    for (;;) {
        errno = 0;
        struct dirent *dp = readdir((DIR *) handle);
        if (dp == NULL) return errno ? -1 : 0;
        if (!strcmp(dp->d_name, ".") || !strcmp(dp->d_name, "..")) continue;
        *name = dp->d_name;
        return 1;
    }
}

void janet_os_dir_close(void *handle) {
    closedir((DIR *) handle);
}

int32_t janet_os_link(const char *oldpath, const char *newpath) {
    return link(oldpath, newpath);
}

#ifndef JANET_NO_SYMLINKS

int32_t janet_os_symlink(const char *oldpath, const char *newpath) {
    return symlink(oldpath, newpath);
}

int64_t janet_os_readlink(const char *path, char *buffer, size_t size) {
    return readlink(path, buffer, size);
}

#endif /* JANET_NO_SYMLINKS */
#endif /* JANET_WINDOWS */

int32_t janet_os_touch(const char *path, int32_t has_times, double actime, double modtime) {
    struct utimbuf timebuf;
    if (!has_times) return utime(path, NULL);
    timebuf.actime = (time_t) actime;
    timebuf.modtime = (time_t) modtime;
    return utime(path, &timebuf);
}

#ifndef JANET_NO_REALPATH
char *janet_os_realpath(const char *path) {
#ifdef JANET_WINDOWS
    return _fullpath(NULL, path, _MAX_PATH);
#else
    return realpath(path, NULL);
#endif
}
#endif

#endif /* JANET_ZIG_OS_FS_PATHS */

#ifdef JANET_NO_SYMLINKS
#define j_symlink janet_os_link
#else
#define j_symlink janet_os_symlink
#endif

#ifndef JANET_NO_LOCALES
JANET_CORE_FN(os_setlocale,
              "(os/setlocale &opt locale category)",
              "Set the system locale, which affects how dates and numbers are formatted. "
              "Passing nil to locale will return the current locale. Category can be one of:\n\n"
              " * :all (default)\n"
              " * :collate\n"
              " * :ctype\n"
              " * :monetary\n"
              " * :numeric\n"
              " * :time\n\n"
              "Returns the new locale if set successfully, otherwise nil. Note that this will affect "
              "other functions such as `os/strftime` and even `printf`.") {
    janet_arity(argc, 0, 2);
    const char *locale_name = janet_optcstring(argv, argc, 0, NULL);
    int category_int = LC_ALL;
    if (argc > 1 && !janet_checktype(argv[1], JANET_NIL)) {
        if (janet_keyeq(argv[1], "all")) {
            category_int = LC_ALL;
        } else if (janet_keyeq(argv[1], "collate")) {
            category_int = LC_COLLATE;
        } else if (janet_keyeq(argv[1], "ctype")) {
            category_int = LC_CTYPE;
        } else if (janet_keyeq(argv[1], "monetary")) {
            category_int = LC_MONETARY;
        } else if (janet_keyeq(argv[1], "numeric")) {
            category_int = LC_NUMERIC;
        } else if (janet_keyeq(argv[1], "time")) {
            category_int = LC_TIME;
        } else {
            janet_panicf("expected one of :all, :collate, :ctype, :monetary, :numeric, or :time, got %v", argv[1]);
        }
    }
    const char *old = setlocale(category_int, locale_name);
    if (old == NULL) return janet_wrap_nil();
    return janet_cstringv(old);
}
#endif

JANET_CORE_FN(os_link,
              "(os/link oldpath newpath &opt symlink)",
              "Create a link at newpath that points to oldpath and returns nil. "
              "Iff symlink is truthy, creates a symlink. "
              "Iff symlink is falsey or not provided, "
              "creates a hard link. Does not work on Windows or Plan 9.") {
    janet_sandbox_assert(JANET_SANDBOX_FS_WRITE);
    janet_arity(argc, 2, 3);
#if defined(JANET_WINDOWS) || defined(JANET_PLAN9)
    (void) argc;
    (void) argv;
    janet_panic("not supported on Windows or Plan 9");
#else
    const char *oldpath = janet_getcstring(argv, 0);
    const char *newpath = janet_getcstring(argv, 1);
    int res = ((argc == 3 && janet_truthy(argv[2])) ? j_symlink : janet_os_link)(oldpath, newpath);
    if (-1 == res) janet_panicf("%s: %s -> %s", janet_strerror(errno), oldpath, newpath);
    return janet_wrap_nil();
#endif
}

JANET_CORE_FN(os_symlink,
              "(os/symlink oldpath newpath)",
              "Create a symlink from oldpath to newpath, returning nil. Same as `(os/link oldpath newpath true)`.") {
    janet_sandbox_assert(JANET_SANDBOX_FS_WRITE);
    janet_fixarity(argc, 2);
#if defined(JANET_WINDOWS) || defined(JANET_PLAN9)
    (void) argc;
    (void) argv;
    janet_panic("not supported on Windows or Plan 9");
#else
    const char *oldpath = janet_getcstring(argv, 0);
    const char *newpath = janet_getcstring(argv, 1);
    int res = j_symlink(oldpath, newpath);
    if (-1 == res) janet_panicf("%s: %s -> %s", janet_strerror(errno), oldpath, newpath);
    return janet_wrap_nil();
#endif
}

#undef j_symlink

JANET_CORE_FN(os_mkdir,
              "(os/mkdir path)",
              "Create a new directory. The path will be relative to the current directory if relative, otherwise "
              "it will be an absolute path. Returns true if the directory was created, false if the directory already exists, and "
              "errors otherwise.") {
    janet_sandbox_assert(JANET_SANDBOX_FS_WRITE);
    janet_fixarity(argc, 1);
    const char *path = janet_getcstring(argv, 0);
    int res = janet_os_mkdir(path);
    if (res == 0) return janet_wrap_true();
    if (errno == EEXIST) return janet_wrap_false();
    janet_panicf("%s: %s", janet_strerror(errno), path);
}

JANET_CORE_FN(os_rmdir,
              "(os/rmdir path)",
              "Delete a directory. The directory must be empty to succeed.") {
    janet_sandbox_assert(JANET_SANDBOX_FS_WRITE);
    janet_fixarity(argc, 1);
    const char *path = janet_getcstring(argv, 0);
    int res = janet_os_rmdir(path);
    if (-1 == res) janet_panicf("%s: %s", janet_strerror(errno), path);
    return janet_wrap_nil();
}

JANET_CORE_FN(os_cd,
              "(os/cd path)",
              "Change current directory to path. Returns nil on success, errors on failure.") {
    janet_sandbox_assert(JANET_SANDBOX_FS_READ);
    janet_fixarity(argc, 1);
    const char *path = janet_getcstring(argv, 0);
    int res = janet_os_chdir(path);
    if (-1 == res) janet_panicf("%s: %s", janet_strerror(errno), path);
    return janet_wrap_nil();
}

JANET_CORE_FN(os_touch,
              "(os/touch path &opt actime modtime)",
              "Update the access time and modification times for a file. By default, sets "
              "times to the current time.") {
    janet_sandbox_assert(JANET_SANDBOX_FS_WRITE);
    janet_arity(argc, 1, 3);
    const char *path = janet_getcstring(argv, 0);
    double actime = 0;
    double modtime = 0;
    if (argc >= 2) {
        actime = janet_getnumber(argv, 1);
        modtime = (argc >= 3) ? janet_getnumber(argv, 2) : actime;
    }
    int res = janet_os_touch(path, argc >= 2, actime, modtime);
    if (-1 == res) janet_panic(janet_strerror(errno));
    return janet_wrap_nil();
}

JANET_CORE_FN(os_remove,
              "(os/rm path)",
              "Delete a file. Returns nil.") {
    janet_fixarity(argc, 1);
    const char *path = janet_getcstring(argv, 0);
    int status = janet_os_remove(path);
    if (-1 == status) janet_panicf("%s: %s", janet_strerror(errno), path);
    return janet_wrap_nil();
}

#ifndef JANET_NO_SYMLINKS
JANET_CORE_FN(os_readlink,
              "(os/readlink path)",
              "Read the contents of a symbolic link. Does not work on Windows.\n") {
    janet_fixarity(argc, 1);
#ifdef JANET_WINDOWS
    (void) argc;
    (void) argv;
    janet_panic("not supported on Windows");
#else
    char buffer[PATH_MAX];
    const char *path = janet_getcstring(argv, 0);
    int64_t len = janet_os_readlink(path, buffer, sizeof buffer);
    if (len < 0 || (size_t)len >= sizeof buffer)
        janet_panicf("%s: %s", janet_strerror(errno), path);
    return janet_stringv((const uint8_t *)buffer, len);
#endif
}
#endif

#ifdef JANET_WINDOWS

typedef struct _stat jstat_t;
typedef unsigned short jmode_t;

#else

typedef struct stat jstat_t;
typedef mode_t jmode_t;

#endif

#ifdef JANET_ZIG_OS_STAT

const char *janet_os_mode_name(uint32_t mode);
int32_t janet_os_decode_permissions(uint32_t mode);
int32_t janet_os_perm_to_unix(uint32_t mode);
uint32_t janet_os_perm_from_unix(int32_t permissions);

#elif defined(JANET_WINDOWS)

const char *janet_os_mode_name(uint32_t m) {
    const char *str = "other";
    if (m & _S_IFREG) str = "file";
    else if (m & _S_IFDIR) str = "directory";
    else if (m & _S_IFCHR) str = "character";
    return str;
}

int32_t janet_os_decode_permissions(uint32_t mode) {
    return (int32_t)(mode & (S_IEXEC | S_IWRITE | S_IREAD));
}

int32_t janet_os_perm_to_unix(uint32_t m) {
    int32_t ret = 0;
    if (m & S_IEXEC) ret |= 0111;
    if (m & S_IWRITE) ret |= 0222;
    if (m & S_IREAD) ret |= 0444;
    return ret;
}

uint32_t janet_os_perm_from_unix(int32_t x) {
    uint32_t m = 0;
    if (x & 111) m |= S_IEXEC;
    if (x & 222) m |= S_IWRITE;
    if (x & 444) m |= S_IREAD;
    return m;
}

#else

const char *janet_os_mode_name(uint32_t m) {
    const char *str = "other";
    if (S_ISREG(m)) str = "file";
    else if (S_ISDIR(m)) str = "directory";
#ifndef JANET_PLAN9
    else if (S_ISFIFO(m)) str = "fifo";
    else if (S_ISBLK(m)) str = "block";
    else if (S_ISSOCK(m)) str = "socket";
    else if (S_ISLNK(m)) str = "link";
    else if (S_ISCHR(m)) str = "character";
#endif
    return str;
}

int32_t janet_os_decode_permissions(uint32_t mode) {
    return (int32_t)(mode & 0777);
}

int32_t janet_os_perm_to_unix(uint32_t m) {
    return (int32_t) m;
}

uint32_t janet_os_perm_from_unix(int32_t x) {
    return (uint32_t) x;
}

#endif

#ifdef JANET_ZIG_OS_PERMISSIONS

int32_t janet_os_parse_permissions(const uint8_t *perm);
void janet_os_format_permissions(int32_t permissions, uint8_t *out);

#else

int32_t janet_os_parse_permissions(const uint8_t *perm) {
    int32_t m = 0;
    if (perm[0] == 'r') m |= 0400;
    if (perm[1] == 'w') m |= 0200;
    if (perm[2] == 'x') m |= 0100;
    if (perm[3] == 'r') m |= 0040;
    if (perm[4] == 'w') m |= 0020;
    if (perm[5] == 'x') m |= 0010;
    if (perm[6] == 'r') m |= 0004;
    if (perm[7] == 'w') m |= 0002;
    if (perm[8] == 'x') m |= 0001;
    return m;
}

void janet_os_format_permissions(int32_t permissions, uint8_t *bytes) {
    bytes[0] = (permissions & 0400) ? 'r' : '-';
    bytes[1] = (permissions & 0200) ? 'w' : '-';
    bytes[2] = (permissions & 0100) ? 'x' : '-';
    bytes[3] = (permissions & 0040) ? 'r' : '-';
    bytes[4] = (permissions & 0020) ? 'w' : '-';
    bytes[5] = (permissions & 0010) ? 'x' : '-';
    bytes[6] = (permissions & 0004) ? 'r' : '-';
    bytes[7] = (permissions & 0002) ? 'w' : '-';
    bytes[8] = (permissions & 0001) ? 'x' : '-';
}

#endif /* JANET_ZIG_OS_PERMISSIONS */

static Janet os_make_permstring(int32_t permissions) {
    uint8_t bytes[9];
    janet_os_format_permissions(permissions, bytes);
    return janet_stringv(bytes, sizeof(bytes));
}

static int32_t os_get_unix_mode(const Janet *argv, int32_t n) {
    int32_t unix_mode;
    if (janet_checkint(argv[n])) {
        /* Integer mode */
        int32_t x = janet_unwrap_integer(argv[n]);
        if (x < 0 || x > 0777) {
            janet_panicf("bad slot #%d, expected integer in range [0, 8r777], got %v", n, argv[n]);
        }
        unix_mode = x;
    } else {
        /* Bytes mode */
        JanetByteView bytes = janet_getbytes(argv, n);
        if (bytes.len != 9) {
            janet_panicf("bad slot #%d: expected byte sequence of length 9, got %v", n, argv[n]);
        }
        unix_mode = janet_os_parse_permissions(bytes.bytes);
    }
    return unix_mode;
}

static jmode_t os_getmode(const Janet *argv, int32_t n) {
    return (jmode_t) janet_os_perm_from_unix(os_get_unix_mode(argv, n));
}

/* Getters */
static Janet os_stat_dev(jstat_t *st) {
    return janet_wrap_number(st->st_dev);
}
static Janet os_stat_inode(jstat_t *st) {
    return janet_wrap_number(st->st_ino);
}
static Janet os_stat_mode(jstat_t *st) {
    return janet_wrap_keyword(janet_ckeyword(janet_os_mode_name(st->st_mode)));
}
static Janet os_stat_int_permissions(jstat_t *st) {
    return janet_wrap_integer(janet_os_perm_to_unix(janet_os_decode_permissions(st->st_mode)));
}
static Janet os_stat_permissions(jstat_t *st) {
    return os_make_permstring(janet_os_perm_to_unix(janet_os_decode_permissions(st->st_mode)));
}
static Janet os_stat_uid(jstat_t *st) {
    return janet_wrap_number(st->st_uid);
}
static Janet os_stat_gid(jstat_t *st) {
    return janet_wrap_number(st->st_gid);
}
static Janet os_stat_nlink(jstat_t *st) {
    return janet_wrap_number(st->st_nlink);
}
static Janet os_stat_rdev(jstat_t *st) {
    return janet_wrap_number(st->st_rdev);
}
static Janet os_stat_size(jstat_t *st) {
    return janet_wrap_number(st->st_size);
}
static Janet os_stat_accessed(jstat_t *st) {
    return janet_wrap_number((double) st->st_atime);
}
static Janet os_stat_modified(jstat_t *st) {
    return janet_wrap_number((double) st->st_mtime);
}
static Janet os_stat_changed(jstat_t *st) {
    return janet_wrap_number((double) st->st_ctime);
}
#ifdef JANET_WINDOWS
static Janet os_stat_blocks(jstat_t *st) {
    (void) st;
    return janet_wrap_number(0);
}
static Janet os_stat_blocksize(jstat_t *st) {
    (void) st;
    return janet_wrap_number(0);
}
#else
static Janet os_stat_blocks(jstat_t *st) {
    return janet_wrap_number(st->st_blocks);
}
static Janet os_stat_blocksize(jstat_t *st) {
    return janet_wrap_number(st->st_blksize);
}
#endif

/* Field identifiers. The registry below lists the same fields in this order,
 * so an identifier is also the index of its name. */
enum JanetOsStatField {
    JANET_OS_STAT_DEV,
    JANET_OS_STAT_INODE,
    JANET_OS_STAT_MODE,
    JANET_OS_STAT_INT_PERMISSIONS,
    JANET_OS_STAT_PERMISSIONS,
    JANET_OS_STAT_UID,
    JANET_OS_STAT_GID,
    JANET_OS_STAT_NLINK,
    JANET_OS_STAT_RDEV,
    JANET_OS_STAT_SIZE,
    JANET_OS_STAT_BLOCKS,
    JANET_OS_STAT_BLOCKSIZE,
    JANET_OS_STAT_ACCESSED,
    JANET_OS_STAT_MODIFIED,
    JANET_OS_STAT_CHANGED,
    JANET_OS_STAT_FIELD_COUNT
};

#ifdef JANET_ZIG_OS_STAT

int32_t janet_os_stat_field_count(void);
const char *janet_os_stat_field_name(int32_t index);
int32_t janet_os_stat_field_lookup(const uint8_t *key, int32_t len);

#else

static const char *const os_stat_field_names[JANET_OS_STAT_FIELD_COUNT] = {
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

int32_t janet_os_stat_field_count(void) {
    return (int32_t) JANET_OS_STAT_FIELD_COUNT;
}

const char *janet_os_stat_field_name(int32_t index) {
    if (index < 0 || index >= (int32_t) JANET_OS_STAT_FIELD_COUNT) return NULL;
    return os_stat_field_names[index];
}

int32_t janet_os_stat_field_lookup(const uint8_t *key, int32_t len) {
    if (len < 0) return -1;
    for (int32_t field = 0; field < (int32_t) JANET_OS_STAT_FIELD_COUNT; field++) {
        const char *name = os_stat_field_names[field];
        int32_t index;
        for (index = 0; index < len; index++) {
            uint8_t k = ((const uint8_t *) name)[index];
            if (key[index] != k) goto next;
            if (k == '\0') break;
        }
        if (name[index] == '\0') return field;
next:
        ;
    }
    return -1;
}

#endif /* JANET_ZIG_OS_STAT */

static Janet os_stat_field(int32_t field, jstat_t *st) {
    switch (field) {
        default:
            return janet_wrap_nil();
        case JANET_OS_STAT_DEV:
            return os_stat_dev(st);
        case JANET_OS_STAT_INODE:
            return os_stat_inode(st);
        case JANET_OS_STAT_MODE:
            return os_stat_mode(st);
        case JANET_OS_STAT_INT_PERMISSIONS:
            return os_stat_int_permissions(st);
        case JANET_OS_STAT_PERMISSIONS:
            return os_stat_permissions(st);
        case JANET_OS_STAT_UID:
            return os_stat_uid(st);
        case JANET_OS_STAT_GID:
            return os_stat_gid(st);
        case JANET_OS_STAT_NLINK:
            return os_stat_nlink(st);
        case JANET_OS_STAT_RDEV:
            return os_stat_rdev(st);
        case JANET_OS_STAT_SIZE:
            return os_stat_size(st);
        case JANET_OS_STAT_BLOCKS:
            return os_stat_blocks(st);
        case JANET_OS_STAT_BLOCKSIZE:
            return os_stat_blocksize(st);
        case JANET_OS_STAT_ACCESSED:
            return os_stat_accessed(st);
        case JANET_OS_STAT_MODIFIED:
            return os_stat_modified(st);
        case JANET_OS_STAT_CHANGED:
            return os_stat_changed(st);
    }
}

static Janet os_stat_or_lstat(int do_lstat, int32_t argc, Janet *argv) {
    janet_sandbox_assert(JANET_SANDBOX_FS_READ);
    janet_arity(argc, 1, 2);
    const char *path = janet_getcstring(argv, 0);
    JanetTable *tab = NULL;
    const uint8_t *key = NULL;
    if (argc == 2) {
        if (janet_checktype(argv[1], JANET_KEYWORD)) {
            key = janet_getkeyword(argv, 1);
        } else {
            tab = janet_gettable(argv, 1);
        }
    } else {
        tab = janet_table(0);
    }

    /* Build result */
    jstat_t st;
#ifdef JANET_WINDOWS
    (void) do_lstat;
    int res = _stat(path, &st);
#elif defined(JANET_PLAN9)
    (void)do_lstat;
    int res = stat(path, &st);
#else
    int res;
    if (do_lstat) {
        res = lstat(path, &st);
    } else {
        res = stat(path, &st);
    }
#endif
    if (-1 == res) {
        return janet_wrap_nil();
    }

    if (NULL == key) {
        /* Put results in table */
        int32_t count = janet_os_stat_field_count();
        for (int32_t field = 0; field < count; field++) {
            janet_table_put(tab, janet_ckeywordv(janet_os_stat_field_name(field)), os_stat_field(field, &st));
        }
        return janet_wrap_table(tab);
    } else {
        /* Get one result */
        int32_t field = janet_os_stat_field_lookup(key, janet_string_length(key));
        if (field < 0) janet_panicf("unexpected keyword %v", janet_wrap_keyword(key));
        return os_stat_field(field, &st);
    }
}

JANET_CORE_FN(os_stat,
              "(os/stat path &opt tab|key)",
              "Gets information about a file or directory. Returns a table unless the second argument is a keyword, "
              "in which case it returns only that field/value from stat. If the file or directory does not exist, returns nil."
              "The keys are:\n\n"
              "* :dev - the device that the file is on\n\n"
              "* :mode - the type of file, one of :file, :directory, :block, :character, :fifo, :socket, :link, or :other\n\n"
              "* :int-permissions - A Unix permission integer like 8r744\n\n"
              "* :permissions - A Unix permission string like \"rwxr--r--\"\n\n"
              "* :uid - File uid\n\n"
              "* :gid - File gid\n\n"
              "* :nlink - number of links to file\n\n"
              "* :rdev - Real device of file. 0 on Windows\n\n"
              "* :size - size of file in bytes\n\n"
              "* :blocks - number of blocks in file. 0 on Windows\n\n"
              "* :blocksize - size of blocks in file. 0 on Windows\n\n"
              "* :accessed - timestamp when file last accessed\n\n"
              "* :changed - timestamp when file last changed (permissions changed)\n\n"
              "* :modified - timestamp when file last modified (content changed)\n") {
    return os_stat_or_lstat(0, argc, argv);
}

JANET_CORE_FN(os_lstat,
              "(os/lstat path &opt tab|key)",
              "Like os/stat, but don't follow symlinks.\n") {
    return os_stat_or_lstat(1, argc, argv);
}

JANET_CORE_FN(os_chmod,
              "(os/chmod path mode)",
              "Change file permissions, where `mode` is a permission string as returned by "
              "`os/perm-string`, or an integer as returned by `os/perm-int`. "
              "When `mode` is an integer, it is interpreted as a Unix permission value, best specified in octal, like "
              "8r666 or 8r400. Windows will not differentiate between user, group, and other permissions, and thus will combine all of these permissions. Returns nil."
              "Unsupported on plan9.") {
    janet_sandbox_assert(JANET_SANDBOX_FS_WRITE);
    janet_fixarity(argc, 2);
#ifdef JANET_PLAN9
    janet_panic("not supported on Plan 9");
#else
    const char *path = janet_getcstring(argv, 0);
#ifdef JANET_WINDOWS
    int res = _chmod(path, os_getmode(argv, 1));
#else
    int res = chmod(path, os_getmode(argv, 1));
#endif
    if (-1 == res) janet_panicf("%s: %s", janet_strerror(errno), path);
    return janet_wrap_nil();
#endif
}

#ifndef JANET_NO_UMASK
JANET_CORE_FN(os_umask,
              "(os/umask mask)",
              "Set a new umask, returns the old umask.") {
    janet_sandbox_assert(JANET_SANDBOX_FS_WRITE);
    janet_fixarity(argc, 1);
    int mask = (int) os_getmode(argv, 0);
#ifdef JANET_WINDOWS
    int res = _umask(mask);
#else
    int res = umask(mask);
#endif
    return janet_wrap_integer(janet_os_perm_to_unix((uint32_t) res));
}
#endif

JANET_CORE_FN(os_dir,
              "(os/dir dir &opt array)",
              "Iterate over files and subdirectories in a directory. Returns an array of paths parts, "
              "with only the file name or directory name and no prefix.") {
    janet_sandbox_assert(JANET_SANDBOX_FS_READ);
    janet_arity(argc, 1, 2);
    const char *dir = janet_getcstring(argv, 0);
    JanetArray *paths = (argc == 2) ? janet_getarray(argv, 1) : janet_array(0);
#ifdef JANET_WINDOWS
    /* Read directory items with FindFirstFile / FindNextFile / FindClose */
    struct _finddata_t afile;
    char pattern[MAX_PATH + 1];
    if (strlen(dir) > (sizeof(pattern) - 3))
        janet_panicf("path too long: %s", dir);
    snprintf(pattern, sizeof(pattern), "%s/*", dir);
    intptr_t res = _findfirst(pattern, &afile);
    if (-1 == res) janet_panicv(janet_cstringv(janet_strerror(errno)));
    do {
        if (strcmp(".", afile.name) && strcmp("..", afile.name)) {
            janet_array_push(paths, janet_cstringv(afile.name));
        }
    } while (_findnext(res, &afile) != -1);
    _findclose(res);
#else
    /* Read directory items with opendir / readdir / closedir */
    void *dfd = janet_os_dir_open(dir);
    if (dfd == NULL) janet_panicf("cannot open directory %s: %s", dir, janet_strerror(errno));
    for (;;) {
        const char *name;
        int32_t status = janet_os_dir_next(dfd, &name);
        if (status < 0) {
            int olderr = errno;
            janet_os_dir_close(dfd);
            janet_panicf("failed to read directory %s: %s", dir, janet_strerror(olderr));
        }
        if (status == 0) break;
        janet_array_push(paths, janet_cstringv(name));
    }
    janet_os_dir_close(dfd);
#endif
    return janet_wrap_array(paths);
}

JANET_CORE_FN(os_rename,
              "(os/rename oldname newname)",
              "Rename a file on disk to a new path. Returns nil.") {
    janet_sandbox_assert(JANET_SANDBOX_FS_WRITE);
    janet_fixarity(argc, 2);
    const char *src = janet_getcstring(argv, 0);
    const char *dest = janet_getcstring(argv, 1);
    int status = janet_os_rename(src, dest);
    if (status) {
        janet_panic(janet_strerror(errno));
    }
    return janet_wrap_nil();
}

JANET_CORE_FN(os_realpath,
              "(os/realpath path)",
              "Get the absolute path for a given path, following ../, ./, and symlinks. "
              "Returns an absolute path as a string.") {
    janet_sandbox_assert(JANET_SANDBOX_FS_READ);
    janet_fixarity(argc, 1);
    const char *src = janet_getcstring(argv, 0);
#ifdef JANET_NO_REALPATH
    janet_panic("os/realpath not enabled for this platform");
#else
    char *dest = janet_os_realpath(src);
    if (NULL == dest) janet_panicf("%s: %s", janet_strerror(errno), src);
    Janet ret = janet_cstringv(dest);
#ifdef JANET_WINDOWS
    DWORD attrib = GetFileAttributes(dest);
    free(dest); /* if janet_malloc is redefined, still use free to correspond with _fullpath */
    if (attrib == INVALID_FILE_ATTRIBUTES) {
        janet_panicf("path does not exist: %v", ret);
    }
#else
    janet_free(dest);
#endif
    return ret;
#endif
}

JANET_CORE_FN(os_permission_string,
              "(os/perm-string int)",
              "Convert a Unix octal permission value from a permission integer as returned by `os/stat` "
              "to a human readable string, that follows the formatting "
              "of Unix tools like `ls`. Returns the string as a 9-character string of r, w, x and - characters. Does not "
              "include the file/directory/symlink character as rendered by `ls`.") {
    janet_fixarity(argc, 1);
    return os_make_permstring(os_get_unix_mode(argv, 0));
}

JANET_CORE_FN(os_permission_int,
              "(os/perm-int bytes)",
              "Parse a 9-character permission string and return an integer that can be used by chmod.") {
    janet_fixarity(argc, 1);
    return janet_wrap_integer(os_get_unix_mode(argv, 0));
}

#ifdef JANET_EV

/*
 * Define a few functions on streams the require JANET_EV to be defined.
 */

static jmode_t os_optmode(int32_t argc, const Janet *argv, int32_t n, int32_t dflt) {
    if (argc > n) return os_getmode(argv, n);
    return (jmode_t) janet_os_perm_from_unix(dflt);
}

JANET_CORE_FN(os_open,
              "(os/open path &opt flags mode)",
              "Create a stream from a file, like the POSIX open system call. Returns a new stream. "
              "`mode` should be a file mode as passed to `os/chmod`, but only if the create flag is given. "
              "The default mode is 8r666. "
              "Allowed flags are as follows:\n\n"
              "  * :r - open this file for reading\n"
              "  * :w - open this file for writing\n"
              "  * :c - create a new file (O\\_CREATE)\n"
              "  * :e - fail if the file exists (O\\_EXCL)\n"
              "  * :t - shorten an existing file to length 0 (O\\_TRUNC)\n\n"
              "  * :a - append to a file (O\\_APPEND on posix, FILE_APPEND_DATA on windows)\n"
              "Posix-only flags:\n\n"
              "  * :x - O\\_SYNC\n"
              "  * :C - O\\_NOCTTY\n\n"
              "  * :N - Turn off O\\_NONBLOCK and disable ev reading/writing\n\n"
              "Windows-only flags:\n\n"
              "  * :R - share reads (FILE\\_SHARE\\_READ)\n"
              "  * :W - share writes (FILE\\_SHARE\\_WRITE)\n"
              "  * :D - share deletes (FILE\\_SHARE\\_DELETE)\n"
              "  * :H - FILE\\_ATTRIBUTE\\_HIDDEN\n"
              "  * :O - FILE\\_ATTRIBUTE\\_READONLY\n"
              "  * :F - FILE\\_ATTRIBUTE\\_OFFLINE\n"
              "  * :T - FILE\\_ATTRIBUTE\\_TEMPORARY\n"
              "  * :d - FILE\\_FLAG\\_DELETE\\_ON\\_CLOSE\n"
              "  * :V - Turn off FILE\\_FLAG\\_OVERLAPPED and disable ev reading/writing\n"
              "  * :I - set bInheritHandle on the created file so it can be passed to other processes.\n"
              "  * :b - FILE\\_FLAG\\_NO\\_BUFFERING\n") {
    janet_arity(argc, 1, 3);
    const char *path = janet_getcstring(argv, 0);
    const uint8_t *opt_flags = janet_optkeyword(argv, argc, 1, (const uint8_t *) "r");
    jmode_t mode = os_optmode(argc, argv, 2, 0666);
    uint32_t stream_flags = 0;
    int disable_stream_mode = 0;
    JanetHandle fd;
#ifdef JANET_WINDOWS
    (void) mode;
    int inherited_handle = 0;
    DWORD desiredAccess = 0;
    DWORD shareMode = 0;
    DWORD creationDisp = 0;
    DWORD fileFlags = FILE_FLAG_OVERLAPPED;
    DWORD fileAttributes = 0;
    /* We map unix-like open flags to the creationDisp parameter */
    int creatUnix = 0;
#define OCREAT 1
#define OEXCL 2
#define OTRUNC 4
    for (const uint8_t *c = opt_flags; *c; c++) {
        switch (*c) {
            default:
                break;
            case 'r':
                desiredAccess |= GENERIC_READ;
                stream_flags |= JANET_STREAM_READABLE;
                janet_sandbox_assert(JANET_SANDBOX_FS_READ);
                break;
            case 'w':
                desiredAccess |= GENERIC_WRITE;
                stream_flags |= JANET_STREAM_WRITABLE;
                janet_sandbox_assert(JANET_SANDBOX_FS_WRITE);
                break;
            case 'a':
                desiredAccess |= FILE_APPEND_DATA;
                stream_flags |= JANET_STREAM_WRITABLE;
                janet_sandbox_assert(JANET_SANDBOX_FS_WRITE);
                break;
            case 'c':
                creatUnix |= OCREAT;
                janet_sandbox_assert(JANET_SANDBOX_FS_WRITE);
                break;
            case 'e':
                creatUnix |= OEXCL;
                break;
            case 't':
                creatUnix |= OTRUNC;
                janet_sandbox_assert(JANET_SANDBOX_FS_WRITE);
                break;
            /* Windows only flags */
            case 'D':
                shareMode |= FILE_SHARE_DELETE;
                break;
            case 'R':
                shareMode |= FILE_SHARE_READ;
                break;
            case 'W':
                shareMode |= FILE_SHARE_WRITE;
                break;
            case 'H':
                fileAttributes |= FILE_ATTRIBUTE_HIDDEN;
                break;
            case 'O':
                fileAttributes |= FILE_ATTRIBUTE_READONLY;
                break;
            case 'F':
                fileAttributes |= FILE_ATTRIBUTE_OFFLINE;
                break;
            case 'T':
                fileAttributes |= FILE_ATTRIBUTE_TEMPORARY;
                break;
            case 'd':
                fileFlags |= FILE_FLAG_DELETE_ON_CLOSE;
                break;
            case 'b':
                fileFlags |= FILE_FLAG_NO_BUFFERING;
                break;
            case 'I':
                inherited_handle = 1;
                break;
            case 'V':
                fileFlags &= ~FILE_FLAG_OVERLAPPED;
                disable_stream_mode = 1;
                break;
                /* we could potentially add more here -
                 * https://docs.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilea
                 */
        }
    }
    switch (creatUnix) {
        default:
            janet_panic("invalid creation flags");
        case 0:
            creationDisp = OPEN_EXISTING;
            break;
        case OCREAT:
            creationDisp = OPEN_ALWAYS;
            break;
        case OCREAT + OEXCL:
            creationDisp = CREATE_NEW;
            break;
        case OCREAT + OTRUNC:
            creationDisp = CREATE_ALWAYS;
            break;
        case OTRUNC:
            creationDisp = TRUNCATE_EXISTING;
            break;
    }
    if (fileAttributes == 0) {
        fileAttributes = FILE_ATTRIBUTE_NORMAL;
    }
    SECURITY_ATTRIBUTES saAttr;
    memset(&saAttr, 0, sizeof(saAttr));
    saAttr.nLength = sizeof(saAttr);
    if (inherited_handle) {
        saAttr.bInheritHandle = TRUE; /* Needed to do interesting things with file */
    }
    fd = CreateFileA(path, desiredAccess, shareMode, &saAttr, creationDisp, fileFlags | fileAttributes, NULL);
    if (fd == INVALID_HANDLE_VALUE) janet_panicv(janet_ev_lasterr());
#else
    int open_flags = O_NONBLOCK;
#ifdef JANET_LINUX
    open_flags |= O_CLOEXEC;
#endif
    int read_flag = 0;
    int write_flag = 0;
    for (const uint8_t *c = opt_flags; *c; c++) {
        switch (*c) {
            default:
                break;
            case 'r':
                read_flag = 1;
                stream_flags |= JANET_STREAM_READABLE;
                janet_sandbox_assert(JANET_SANDBOX_FS_READ);
                break;
            case 'w':
                write_flag = 1;
                stream_flags |= JANET_STREAM_WRITABLE;
                janet_sandbox_assert(JANET_SANDBOX_FS_WRITE);
                break;
            case 'c':
                open_flags |= O_CREAT;
                janet_sandbox_assert(JANET_SANDBOX_FS_WRITE);
                break;
            case 'e':
                open_flags |= O_EXCL;
                break;
            case 't':
                open_flags |= O_TRUNC;
                janet_sandbox_assert(JANET_SANDBOX_FS_WRITE);
                break;
            /* posix only */
            case 'x':
                open_flags |= O_SYNC;
                break;
            case 'C':
                open_flags |= O_NOCTTY;
                break;
            case 'a':
                open_flags |= O_APPEND;
                break;
            case 'N':
                open_flags &= ~O_NONBLOCK;
                disable_stream_mode = 1;
                break;
        }
    }
    /* If both read and write, fix up to O_RDWR */
    if (read_flag && !write_flag) {
        open_flags |= O_RDONLY;
    } else if (write_flag && !read_flag) {
        open_flags |= O_WRONLY;
    } else {
        open_flags |= O_RDWR;
    }

    do {
        fd = open(path, open_flags, mode);
    } while (fd == -1 && errno == EINTR);
    if (fd == -1) janet_panicv(janet_ev_lasterr());
#endif
    return janet_wrap_abstract(janet_stream(fd, disable_stream_mode ? 0 : stream_flags, NULL));
}

JANET_CORE_FN(os_pipe,
              "(os/pipe &opt flags)",
              "Create a readable stream and a writable stream that are connected. Returns a two-element "
              "tuple where the first element is a readable stream and the second element is the writable "
              "stream. `flags` is a keyword set of flags to disable non-blocking settings on the ends of the pipe. "
              "This may be desired if passing the pipe to a subprocess with `os/spawn`.\n\n"
              "* :W - sets the writable end of the pipe to a blocking stream.\n"
              "* :R - sets the readable end of the pipe to a blocking stream.\n\n"
              "By default, both ends of the pipe are non-blocking for use with the `ev` module.") {
    (void) argv;
    janet_arity(argc, 0, 1);
    JanetHandle fds[2];
    int flags = 0;
    if (argc > 0 && !janet_checktype(argv[0], JANET_NIL)) {
        flags = (int) janet_getflags(argv, 0, "WR");
    }
    if (janet_make_pipe(fds, flags)) janet_panicv(janet_ev_lasterr());
    JanetStream *reader = janet_stream(fds[0], (flags & 2) ? 0 : JANET_STREAM_READABLE, NULL);
    JanetStream *writer = janet_stream(fds[1], (flags & 1) ? 0 : JANET_STREAM_WRITABLE, NULL);
    Janet tup[2] = {janet_wrap_abstract(reader), janet_wrap_abstract(writer)};
    return janet_wrap_tuple(janet_tuple_n(tup, 2));
}

#endif

#endif /* JANET_REDUCED_OS */

/* Module entry point */
void janet_lib_os(JanetTable *env) {
#if !defined(JANET_REDUCED_OS) && defined(JANET_WINDOWS) && defined(JANET_THREADS)
    /* During start up, the top-most abstract machine (thread)
     * in the thread tree sets up the critical section. */
    static volatile long env_lock_initializing = 0;
    static volatile long env_lock_initialized = 0;
    if (!InterlockedExchange(&env_lock_initializing, 1)) {
        InitializeCriticalSection(&env_lock);
        InterlockedOr(&env_lock_initialized, 1);
    } else {
        while (!InterlockedOr(&env_lock_initialized, 0)) {
            Sleep(0);
        }
    }

#endif
#ifndef JANET_NO_PROCESSES
#endif
    JanetRegExt os_cfuns[] = {
        JANET_CORE_REG("os/exit", os_exit),
        JANET_CORE_REG("os/which", os_which),
        JANET_CORE_REG("os/arch", os_arch),
        JANET_CORE_REG("os/compiler", os_compiler),
#ifndef JANET_REDUCED_OS

        /* misc (un-sandboxed) */
        JANET_CORE_REG("os/cpu-count", os_cpu_count),
        JANET_CORE_REG("os/cwd", os_cwd),
        JANET_CORE_REG("os/cryptorand", os_cryptorand),
        JANET_CORE_REG("os/perm-string", os_permission_string),
        JANET_CORE_REG("os/perm-int", os_permission_int),
        JANET_CORE_REG("os/mktime", os_mktime),
        JANET_CORE_REG("os/time", os_time), /* not high resolution */
        JANET_CORE_REG("os/date", os_date), /* not high resolution */
        JANET_CORE_REG("os/strftime", os_strftime),
        JANET_CORE_REG("os/sleep", os_sleep),
        JANET_CORE_REG("os/isatty", os_isatty),
#ifndef JANET_NO_LOCALES
        JANET_CORE_REG("os/setlocale", os_setlocale),
#endif

        /* env functions */
#ifndef JANET_PLAN9
        JANET_CORE_REG("os/environ", os_environ),
#endif
        JANET_CORE_REG("os/getenv", os_getenv),
        JANET_CORE_REG("os/setenv", os_setenv),

        /* fs read */
        JANET_CORE_REG("os/dir", os_dir),
        JANET_CORE_REG("os/stat", os_stat),
        JANET_CORE_REG("os/lstat", os_lstat),
        JANET_CORE_REG("os/chmod", os_chmod),
        JANET_CORE_REG("os/touch", os_touch),
        JANET_CORE_REG("os/realpath", os_realpath),
        JANET_CORE_REG("os/cd", os_cd),
#ifndef JANET_NO_UMASK
        JANET_CORE_REG("os/umask", os_umask),
#endif
#ifndef JANET_NO_SYMLINKS
        JANET_CORE_REG("os/readlink", os_readlink),
#endif

        /* fs write */
        JANET_CORE_REG("os/mkdir", os_mkdir),
        JANET_CORE_REG("os/rmdir", os_rmdir),
        JANET_CORE_REG("os/rm", os_remove),
        JANET_CORE_REG("os/link", os_link),
        JANET_CORE_REG("os/rename", os_rename),
#ifndef JANET_NO_SYMLINKS
        JANET_CORE_REG("os/symlink", os_symlink),
#endif

        /* processes */
#ifndef JANET_NO_PROCESSES
        JANET_CORE_REG("os/execute", os_execute),
        JANET_CORE_REG("os/spawn", os_spawn),
        JANET_CORE_REG("os/shell", os_shell),
        JANET_CORE_REG("os/posix-fork", os_posix_fork),
        JANET_CORE_REG("os/posix-exec", os_posix_exec),
        JANET_CORE_REG("os/posix-chroot", os_posix_chroot),
        /* no need to sandbox process management if you can't create processes
         * (allows for limited functionality if use exposes C-functions to create specific processes) */
        JANET_CORE_REG("os/proc-wait", os_proc_wait),
        JANET_CORE_REG("os/proc-kill", os_proc_kill),
        JANET_CORE_REG("os/proc-close", os_proc_close),
        JANET_CORE_REG("os/getpid", os_proc_getpid),
#ifdef JANET_EV
        JANET_CORE_REG("os/sigaction", os_sigaction),
#endif
#endif

        /* high resolution timers */
        JANET_CORE_REG("os/clock", os_clock),

#ifdef JANET_EV
        JANET_CORE_REG("os/open", os_open), /* fs read and write */
        JANET_CORE_REG("os/pipe", os_pipe),
#endif
#endif
        JANET_REG_END
    };
    janet_core_cfuns_ext(env, NULL, os_cfuns);
}
