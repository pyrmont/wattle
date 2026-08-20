#ifndef JANET_ZIG_STATE_ABI_H
#define JANET_ZIG_STATE_ABI_H

/* Janet's internal VM state header, prepared for Zig's translate-c.
 *
 * `src/core/state.h` is internal, and this is the only place that hands it to
 * Zig. From Phase 7 onward the ports are runtime-core work, so Zig sees
 * `JanetVM` by its real per-configuration layout and reaches `janet_vm` by
 * name, exactly as a core C file does. There is no mirror structure to drift
 * out of date and no accessor function per field.
 *
 * One spelling has to change on the way in. `janet.h` expands
 * JANET_THREAD_LOCAL to GCC's `__thread`, and Aro — the translate-c front end
 * in Zig 0.16 — does not accept that keyword: it parses as an ordinary
 * identifier, and the declaration of `janet_vm` fails with an implicit-int
 * error. C11's `_Thread_local` names the same storage class and Aro does
 * accept it, so the macro is redefined here, for translation only. A
 * single-threaded build has no thread-local storage at all — `janet.h` defines
 * the macro empty — and is left alone.
 */

#include "features.h"

/* Aro -- the translate-c front end in Zig 0.16 -- predefines `__unix__`,
 * `unix` and `__unix` for the mingw targets as well as `_WIN32`, and
 * `janet.h` tests its Unix chain *before* its Windows one. So the translation
 * of `janet.h` for `x86_64-windows-gnu` defines `JANET_POSIX` where the
 * compilation of the same header for the same target defines `JANET_WINDOWS`,
 * and every type that varies by platform -- `JanetHandle` above all, which is
 * `void *` on Windows and `int` elsewhere -- comes out describing the wrong
 * operating system. Nothing detected it until a Zig subsystem first needed
 * one of those types, in Phase 10 Part 12.
 *
 * The correction belongs here rather than in `janet.h`: it is a fact about
 * the tool, the C build is already right, and this file exists to make
 * exactly this kind of translation-only adjustment. `FOUND.md` records it.
 */
#if defined(_WIN32) || defined(WIN32)
#undef __unix__
#undef unix
#undef __unix
#endif

#include <janet.h>

#ifndef JANET_SINGLE_THREADED
#undef JANET_THREAD_LOCAL
#define JANET_THREAD_LOCAL _Thread_local
#endif

#include "state.h"

/* Whether `janet_vm` has thread-local storage in this configuration. Zig reads
 * this rather than the storage class, which translate-c does not surface. */
#ifdef JANET_SINGLE_THREADED
#define JANET_VM_THREAD_LOCAL 0
#else
#define JANET_VM_THREAD_LOCAL 1
#endif

/* Whether this build has the event loop. `janet_signalv` bumps the root
 * fiber's `sched_id` only under JANET_EV, and translate-c does not surface a
 * macro defined with no value, so the condition is restated as one that does.
 */
#ifdef JANET_EV
#define JANET_VM_HAS_EV 1
#else
#define JANET_VM_HAS_EV 0
#endif

/* Whether this build has the socket layer. `janet_init` and `janet_deinit` call
 * `janet_net_init` and `janet_net_deinit` only under JANET_NET, and translate-c
 * does not surface a macro defined with no value, so the condition is restated
 * as one that does. The declarations themselves are inside the same guard in
 * `state.h`, so a Zig branch on this has to be comptime-false rather than
 * merely untaken. */
#ifdef JANET_NET
#define JANET_VM_HAS_NET 1
#else
#define JANET_VM_HAS_NET 0
#endif

/* Whether this build checks for an interpreter interrupt between instructions.
 * `run_vm` compiles the check out entirely without it, and translate-c does not
 * surface a macro defined with no value, so the condition is restated as one
 * that does. */
#ifdef JANET_NO_INTERPRETER_INTERRUPT
#define JANET_VM_HAS_INTERRUPT 0
#else
#define JANET_VM_HAS_INTERRUPT 1
#endif

/* `JANET_OS_NAME` and `JANET_ARCH_NAME` are build-time overrides that name the
 * keyword `os/which` and `os/arch` report. Both are *bare tokens* -- `os.c`
 * stringifies them with the preprocessor -- so a Zig caller cannot recover the
 * text: translate-c surfaces a macro's value, and an identifier is not one.
 * Stringifying them here is the only place that can be done, and it is the
 * same kind of restatement as the flags above. Neither is set by this
 * project's build; a user's `janetconf.h` is where they would come from. */
#define JANET_ZIG_STRINGIFY1(x) #x
#define JANET_ZIG_STRINGIFY(x) JANET_ZIG_STRINGIFY1(x)
#ifdef JANET_OS_NAME
#define JANET_ZIG_OS_NAME JANET_ZIG_STRINGIFY(JANET_OS_NAME)
#endif
#ifdef JANET_ARCH_NAME
#define JANET_ZIG_ARCH_NAME JANET_ZIG_STRINGIFY(JANET_ARCH_NAME)
#endif

#endif /* JANET_ZIG_STATE_ABI_H */
