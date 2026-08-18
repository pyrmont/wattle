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

#endif /* JANET_ZIG_STATE_ABI_H */
