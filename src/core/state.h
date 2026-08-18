/*
* Copyright (c) 2026 Calvin Rose
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

#ifndef JANET_STATE_H_defined
#define JANET_STATE_H_defined

#ifndef JANET_AMALG
#include "features.h"
#include <janet.h>
#include <stdint.h>
#endif

#ifdef JANET_EV
#ifdef JANET_WINDOWS
#include <windows.h>
#else
#include <pthread.h>
#endif
#endif

typedef int64_t JanetTimestamp;

typedef struct JanetScratch {
    JanetScratchFinalizer finalize;
    long long mem[]; /* for proper alignment */
} JanetScratch;

typedef struct {
    JanetGCObject *self;
    JanetGCObject *other;
    int32_t index;
    int32_t index2;
} JanetTraversalNode;

typedef struct {
    int32_t capacity;
    int32_t head;
    int32_t tail;
    void *data;
} JanetQueue;

#ifdef JANET_EV
typedef struct {
    JanetTimestamp when;
    JanetFiber *fiber;
    JanetFiber *curr_fiber;
    uint32_t sched_id;
    int is_error;
    int has_worker;
#ifdef JANET_WINDOWS
    HANDLE worker;
    HANDLE worker_event;
#else
    pthread_t worker;
#endif
} JanetTimeout;
#endif

/* Registry table for C functions - contains metadata that can
 * be looked up by cfunction pointer. All strings here are pointing to
 * static memory not managed by Janet. */
typedef struct {
    JanetCFunction cfun;
    const char *name;
    const char *name_prefix;
    const char *source_file;
    int32_t source_line;
    /* int32_t min_arity; */
    /* int32_t max_arity; */
} JanetCFunRegistry;

struct JanetVM {
    /* Place for user data */
    void *user;

    /* Top level dynamic bindings */
    JanetTable *top_dyns;

    /* Cache the core environment */
    JanetTable *core_env;

    /* How many VM stacks have been entered */
    int stackn;

    /* If this flag is true, suspend on function calls and backwards jumps.
     * When this occurs, this flag will be reset to 0. */
    volatile JanetAtomicInt auto_suspend;

    /* The current running fiber on the current thread.
     * Set and unset by functions in vm.c */
    JanetFiber *fiber;
    JanetFiber *root_fiber;

    /* The current pointer to the inner most jmp_buf. The current
     * return point for panics. */
    jmp_buf *signal_buf;
    Janet *return_reg;
    int coerce_error;

    /* The global registry for c functions. Used to store meta-data
     * along with otherwise bare c function pointers. */
    JanetCFunRegistry *registry;
    size_t registry_cap;
    size_t registry_count;
    int registry_dirty;

    /* Registry for abstract types that can be marshalled.
     * We need this to look up the constructors when unmarshalling. */
    JanetTable *abstract_registry;

    /* Immutable value cache */
    const uint8_t **cache;
    uint32_t cache_capacity;
    uint32_t cache_count;
    uint32_t cache_deleted;
    uint8_t gensym_counter[8];

    /* Garbage collection */
    void *blocks;
    void *weak_blocks;
    size_t gc_interval;
    size_t next_collection;
    size_t block_count;
    int gc_suspend;
    int gc_mark_phase;

    /* GC roots */
    Janet *roots;
    size_t root_count;
    size_t root_capacity;

    /* Scratch memory */
    JanetScratch **scratch_mem;
    size_t scratch_cap;
    size_t scratch_len;

    /* Sandbox flags */
    uint32_t sandbox_flags;

    /* Random number generator */
    JanetRNG rng;

    /* Traversal pointers */
    JanetTraversalNode *traversal;
    JanetTraversalNode *traversal_top;
    JanetTraversalNode *traversal_base;

    /* Thread safe strerror error buffer - for janet_strerror */
#ifndef JANET_WINDOWS
    char strerror_buf[256];
#endif

    /* Event loop and scheduler globals */
#ifdef JANET_EV
    size_t tq_count;
    size_t tq_capacity;
    JanetQueue spawn;
    JanetTimeout *tq;
    JanetRNG ev_rng;
    volatile JanetAtomicInt listener_count; /* used in signal handler, must be volatile */
    JanetTable threaded_abstracts; /* All abstract types that can be shared between threads (used in this thread) */
    JanetTable active_tasks; /* All possibly live task fibers - used just for tracking */
    JanetTable signal_handlers;
#ifdef JANET_WINDOWS
    void **iocp;
    void *connect_ex; /* MSWsock extension if available */
    int connect_ex_loaded;
#elif defined(JANET_EV_EPOLL)
    pthread_attr_t new_thread_attr;
    JanetHandle selfpipe[2];
    int epoll;
    int timerfd;
    int timer_enabled;
#elif defined(JANET_EV_KQUEUE)
    pthread_attr_t new_thread_attr;
    JanetHandle selfpipe[2];
    int kq;
    int timer;
    int timer_enabled;
#else
    JanetStream **streams;
    size_t stream_count;
    size_t stream_capacity;
    pthread_attr_t new_thread_attr;
    JanetHandle selfpipe[2];
    struct pollfd *fds;
#endif
#endif

};

extern JANET_THREAD_LOCAL JanetVM janet_vm;

/* The view of JanetVM held by whichever implementation owns the state:
 * src/core/state.c, or src/zig/subsystems/vm_state.zig. janet_vm_save and
 * janet_vm_load copy the whole structure, so the owner's size is the length
 * those copies use, and test/vm_state.c compares it against the C compiler's. */
size_t janet_vm_state_size(void);
size_t janet_vm_state_align(void);

/* Janet is built as C99, which has no _Alignof, so the alignment both sides
 * report is the classic offsetof-after-a-char probe. The type is here rather
 * than local to either side so that the contract measures the same thing. */
typedef struct {
    char pad;
    JanetVM vm;
} JanetVMAlignProbe;

/* ---------------------------------------------------------------- signals */

/* What janet_signalv must still do once the decision has been made. The
 * decision is janet_signal_plan's; the formatting and the jump stay in C,
 * because "%v" runs an abstract type's tostring callback and can itself panic,
 * and because a longjmp may not cross a Zig frame.
 *
 * Provided by src/core/capi.c or src/zig/subsystems/signal_core.zig. */
typedef enum {
    /* No return register: nothing to jump to, so report at top level. */
    JANET_SIGNAL_PLAN_TOP_LEVEL = 0,
    /* Store the message and jump with the signal janet_signal_plan reports. */
    JANET_SIGNAL_PLAN_RAISE = 1,
    /* As RAISE, but build the coercion message first. */
    JANET_SIGNAL_PLAN_COERCE = 2
} JanetSignalPlan;

JanetSignalPlan janet_signal_plan(JanetSignal sig, JanetSignal *out_sig);
void janet_signal_commit(const Janet *message);
void janet_signal_inject(JanetFiber *fiber, JanetSignal sig);

/* ----------------------------------------------------------------- traces */

/* How janet_stacktrace_ext names a frame.
 *
 * The name and the location are classified separately because the C original
 * classifies them separately, and no single tag can express the result: `reg`
 * is set whenever the registry has an entry, but the name is printed only when
 * that entry also has a name, so an entry with a null name and a positive
 * source_line prints "<cfunction> on line 42". Collapsing the two would change
 * that line. */
typedef enum {
    /* Neither a function nor a cfunction: the frame contributes no name. */
    JANET_TRACE_NAME_NONE = 0,
    /* A Janet function whose def has no name: "<anonymous>". */
    JANET_TRACE_NAME_ANONYMOUS = 1,
    /* A Janet function with a name, in `name`. */
    JANET_TRACE_NAME_FUNCTION = 2,
    /* A registered cfunction: `name`, and `name_prefix` when it has one. */
    JANET_TRACE_NAME_CFUNCTION = 3,
    /* A cfunction with no registry entry or no name in it: "<cfunction>". */
    JANET_TRACE_NAME_CFUNCTION_BARE = 4
} JanetTraceName;

/* How janet_stacktrace_ext locates a frame. */
typedef enum {
    JANET_TRACE_LOC_NONE = 0,
    /* From the funcdef's source map: `line` and `column`. */
    JANET_TRACE_LOC_SOURCEMAP = 1,
    /* A funcdef without a source map: the bytecode offset in `pc`. */
    JANET_TRACE_LOC_PC = 2,
    /* From the cfunction registry: `line` alone. */
    JANET_TRACE_LOC_CFUN_LINE = 3
} JanetTraceLoc;

/* One stack frame, decoded far enough to be printed and no further. Every
 * string points into a funcdef or the cfunction registry and is owned by
 * neither this structure nor its producer.
 *
 * Provided by src/core/debug.c or src/zig/subsystems/trace_frames.zig. */
typedef struct {
    const char *name;         /* NULL unless name_kind names one */
    const char *name_prefix;  /* NULL unless a registered cfunction has one */
    const char *source;       /* NULL when the frame reports no source */
    int32_t pc;               /* valid for LOC_PC */
    int32_t line;             /* valid for LOC_SOURCEMAP and LOC_CFUN_LINE */
    int32_t column;           /* valid for LOC_SOURCEMAP */
    uint8_t name_kind;        /* JanetTraceName */
    uint8_t loc_kind;         /* JanetTraceLoc */
    uint8_t tail;             /* frame was entered by a tail call */
} JanetTraceFrame;

void janet_trace_frame(JanetStackFrame *frame, JanetTraceFrame *out);

#ifdef JANET_NET
void janet_net_init(void);
void janet_net_deinit(void);
#endif

#ifdef JANET_EV
void janet_ev_init(void);
void janet_ev_deinit(void);
#endif

#endif /* JANET_STATE_H_defined */
