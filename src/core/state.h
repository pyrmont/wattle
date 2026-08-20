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
/* One stack frame decoded into the table debug/stack reports, which is the
 * other consumer of the decoding below. It was `doframe`, a static in debug.c
 * that read a JanetStackFrame independently and had already drifted from the
 * decoder beside it.
 *
 * Provided by src/core/debug.c or src/zig/subsystems/debug_frames.zig. */
Janet janet_debug_frame(JanetStackFrame *frame);

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

/* ------------------------------------------------------------- arguments */

/* Why the argument-extraction layer reports instead of formatting.
 *
 * Every janet_get* and janet_opt* in src/core/capi.c ends a failure in
 * janet_panicf, which allocates a Janet string, and allocation can panic. A
 * non-panicking getter that formatted eagerly would therefore need a
 * panic-free allocator. Reporting a code plus the slot and formatting only at
 * the C boundary avoids that, and it makes the messages identical by
 * construction rather than by inspection: the format strings below stay in one
 * place, in janet_arg_raise.
 *
 * Nothing in JanetArgFault is a Janet value. The slot index is enough for the
 * boundary to recover argv[slot] and render it with "%v", which runs an
 * abstract type's tostring callback and so must not happen on this side.
 *
 * Provided by src/core/capi.c or src/zig/subsystems/args_core.zig. */

/* The literal noun each numeric getter names in its message. A code rather
 * than a string so that the wording cannot drift between implementations;
 * janet_arg_expect_name in capi.c is the only place the words appear. */
typedef enum {
    JANET_ARG_EXPECT_NAT = 0,   /* "non-negative 32 bit signed integer" */
    JANET_ARG_EXPECT_SIZE = 1,  /* "size" */
    JANET_ARG_EXPECT_S32 = 2,   /* "32 bit signed integer" */
    JANET_ARG_EXPECT_U32 = 3,   /* "32 bit unsigned integer" */
    JANET_ARG_EXPECT_S16 = 4,   /* "16 bit signed integer" */
    JANET_ARG_EXPECT_U16 = 5,   /* "16 bit unsigned integer" */
    JANET_ARG_EXPECT_S8 = 6,    /* "8 bit signed integer" */
    JANET_ARG_EXPECT_U8 = 7,    /* "8 bit unsigned integer" */
    JANET_ARG_EXPECT_FLOAT = 8, /* "float number" */
    JANET_ARG_EXPECT_S64 = 9,   /* "64 bit signed integer" */
    JANET_ARG_EXPECT_U64 = 10   /* "64 bit unsigned integer" */
} JanetArgExpect;

typedef enum {
    /* No fault. Every kernel below leaves the descriptor untouched on success,
     * so a caller that tests its return value never reads a stale field. */
    JANET_ARG_OK = 0,
    /* janet_panic_type: "bad slot #%d, expected %T, got %v" over `typeflags`. */
    JANET_ARG_TYPE = 1,
    /* janet_panic_abstract: "bad slot #%d, expected %s, got %v" over `at`. */
    JANET_ARG_ABSTRACT = 2,
    /* "bad slot #%d, expected <expect>, got %v". */
    JANET_ARG_EXPECT = 3,
    /* "%s index %d out of range [%d,%d]" over `which`, `raw`, `lo`, `hi`. */
    JANET_ARG_RANGE_INCLUSIVE = 4,
    /* As above with a half-open interval: "... [%d,%d)". */
    JANET_ARG_RANGE_EXCLUSIVE = 5,
    /* "unexpected flag %c, expected one of \"%s\"" over `raw` and `flags`. */
    JANET_ARG_FLAG = 6,
    /* "bytes contain embedded 0s". Carries nothing. */
    JANET_ARG_ZEROS = 7,
    /* "arity mismatch, expected %d, got %d" over `bound` and `arity`. */
    JANET_ARG_ARITY_FIX = 8,
    /* "arity mismatch, expected at least %d, got %d". */
    JANET_ARG_ARITY_MIN = 9,
    /* "arity mismatch, expected at most %d, got %d". */
    JANET_ARG_ARITY_MAX = 10
} JanetArgFaultKind;

typedef struct {
    uint8_t kind;                 /* JanetArgFaultKind */
    uint8_t expect;               /* JanetArgExpect, for kind EXPECT */
    int32_t slot;                 /* argv index, for the three slot kinds */
    int32_t typeflags;            /* for kind TYPE */
    const JanetAbstractType *at;  /* for kind ABSTRACT */
    const char *which;            /* "start", "end", or a caller's word */
    const char *flags;            /* the permitted set, for kind FLAG */
    /* The C original widens every one of these to int64_t before handing it to
     * a "%d", which is a defect recorded in FOUND.md rather than a design. The
     * width here is the width the format call already uses. */
    int64_t raw;                  /* the index as written, or the flag byte */
    int64_t lo;
    int64_t hi;
    int32_t arity;                /* for the three arity kinds */
    int32_t bound;
} JanetArgFault;

/* How janet_getbytes and janet_getcbytes must proceed once the type is known.
 * The abstract case is separated because it runs the type's `bytes` callback,
 * which is third-party code that may panic; the call is made on the C side so
 * that no jump crosses the frame that classified the value. */
typedef enum {
    /* Not byte-viewable: the caller raises the fault the kernel filled in. */
    JANET_ARG_BYTES_FAULT = 0,
    /* String, symbol or keyword: `bytes` and `len` are set. */
    JANET_ARG_BYTES_STRING = 1,
    /* Buffer: `bytes` and `len` are set from its current contents. */
    JANET_ARG_BYTES_BUFFER = 2,
    /* An abstract type with a `bytes` callback the caller must invoke. */
    JANET_ARG_BYTES_ABSTRACT = 3
} JanetArgBytes;

/* Which of janet_getcbytes' three shapes applies, decided without touching the
 * buffer. The two buffer cases both mutate or allocate, so both are carried
 * out by the caller. */
typedef enum {
    JANET_ARG_CBYTES_FAULT = 0,
    /* A buffer that cannot be realloced and is exactly full: copy it with
     * janet_smalloc and terminate the copy. */
    JANET_ARG_CBYTES_COPY = 1,
    /* Any other buffer: push a 0, then drop the count back. */
    JANET_ARG_CBYTES_TERMINATE = 2,
    /* Not a buffer: take an ordinary byte view. */
    JANET_ARG_CBYTES_VIEW = 3
} JanetArgCBytes;

int janet_arg_checktype(const Janet *argv, int32_t n, int32_t type,
                        int32_t typeflags, JanetArgFault *fault);
int janet_arg_isdefault(const Janet *argv, int32_t argc, int32_t n);
int janet_arg_integer(const Janet *argv, int32_t n, int32_t *out, JanetArgFault *fault);
int janet_arg_uinteger(const Janet *argv, int32_t n, uint32_t *out, JanetArgFault *fault);
int janet_arg_integer16(const Janet *argv, int32_t n, int16_t *out, JanetArgFault *fault);
int janet_arg_uinteger16(const Janet *argv, int32_t n, uint16_t *out, JanetArgFault *fault);
int janet_arg_integer8(const Janet *argv, int32_t n, int8_t *out, JanetArgFault *fault);
int janet_arg_uinteger8(const Janet *argv, int32_t n, uint8_t *out, JanetArgFault *fault);
int janet_arg_float(const Janet *argv, int32_t n, float *out, JanetArgFault *fault);
int janet_arg_integer64(const Janet *argv, int32_t n, int64_t *out, JanetArgFault *fault);
int janet_arg_uinteger64(const Janet *argv, int32_t n, uint64_t *out, JanetArgFault *fault);
int janet_arg_size(const Janet *argv, int32_t n, size_t *out, JanetArgFault *fault);
int janet_arg_nat(const Janet *argv, int32_t n, int32_t *out, JanetArgFault *fault);
int janet_arg_abstract(const Janet *argv, int32_t n, const JanetAbstractType *at,
                       void **out, JanetArgFault *fault);
int janet_arg_indexed(const Janet *argv, int32_t n, JanetView *out, JanetArgFault *fault);
int janet_arg_dictionary(const Janet *argv, int32_t n, JanetDictView *out, JanetArgFault *fault);
JanetArgBytes janet_arg_bytes(Janet x, int32_t n, JanetByteView *out, JanetArgFault *fault);
JanetArgCBytes janet_arg_cbytes(const Janet *argv, int32_t n, JanetArgFault *fault);
int janet_arg_zeros(const char *bytes, int32_t len, JanetArgFault *fault);
int janet_arg_halfrange(const Janet *argv, int32_t n, int32_t length, const char *which,
                        int32_t *out, JanetArgFault *fault);
int janet_arg_argindex(const Janet *argv, int32_t n, int32_t length, const char *which,
                       int32_t *out, JanetArgFault *fault);
int janet_arg_flags(const uint8_t *keyw, int32_t klen, const char *flags,
                    uint64_t *out, JanetArgFault *fault);
int janet_arg_fixarity(int32_t arity, int32_t fix, JanetArgFault *fault);
int janet_arg_arity(int32_t arity, int32_t min, int32_t max, JanetArgFault *fault);
int janet_arg_strlike(int32_t type, Janet x, const char *cstring);
int janet_arg_method(const uint8_t *method, const JanetMethod *methods, const JanetMethod **out);
const JanetMethod *janet_arg_nextmethod(const JanetMethod *methods, Janet key);

/* The formatting half. Always raises; never returns. */
JANET_NO_RETURN void janet_arg_raise(const Janet *argv, const JanetArgFault *fault);

/* ------------------------------------------------ interpreter callees */

/* The callee side of the interpreter: what run_vm delegates to when the thing
 * it is about to call is not a plain Janet function, plus the three loops that
 * fill a collection from the fiber stack.
 *
 * Every one of these raises, and most of them do nothing else: they reach
 * third-party cfunctions, an abstract type's call callback, janet_call,
 * janet_get, janet_in, janet_table_put, janet_struct_put and
 * janet_to_string_b. A caller that cannot afford a longjmp has to place a
 * scope of its own; run_vm does exactly that under JANET_CALL_TRAMPOLINE.
 *
 * Five of these were statics in vm.c whose names were too general to put in a
 * library's symbol table, and carry a janet_ prefix here that the C original
 * did not have: janet_call_nonfn, janet_resolve_method, and the three fills.
 *
 * Provided by src/core/vm.c or src/zig/subsystems/vm_calls.zig. */
Janet janet_method_invoke(Janet method, int32_t argc, Janet *argv);
Janet janet_call_nonfn(JanetFiber *fiber, Janet callee);
Janet janet_resolve_method(Janet name, JanetFiber *fiber);
Janet janet_method_lookup(Janet x, const char *name);
Janet janet_unary_call(const char *method, Janet arg);
Janet janet_binop_call(const char *lmethod, const char *rmethod, Janet lhs, Janet rhs);
void janet_fill_table(JanetTable *table, const Janet *mem, int32_t count);
void janet_fill_struct(JanetKV *st, const Janet *mem, int32_t count);
void janet_fill_string(JanetBuffer *buffer, const Janet *mem, int32_t count);

/* ------------------------------------------------ the interpreter loop */

/* run_vm, and the two functions it reaches that vm.c used to keep private.
 *
 * janet_run_vm was `run_vm`. Both it and janet_vm_error_string are renamed for
 * the same reason the five callees above were: a static's name becomes a
 * library symbol the moment the definition moves to another translation unit,
 * and `run_vm` is too general a name to put there.
 *
 * janet_check_can_resume and janet_continue_no_check kept their names and
 * merely lost `static`.
 *
 * Provided by src/core/vm.c or src/zig/subsystems/vm_run.zig. */
JanetSignal janet_run_vm(JanetFiber *fiber, Janet in);

/* The gate every resume passes through, and the one function on this path that
 * is not selectable at all.
 *
 * janet_check_can_resume moved to the entry points in Part 4 and is provided by
 * src/core/vm.c or src/zig/subsystems/vm_entry.zig. janet_continue_no_check is
 * always src/core/vm.c: Phase 7's fourth rule keeps it there because it holds
 * the jmp_buf every fiber resume re-establishes. That makes it the hinge of a
 * seam that runs in both directions — it calls janet_run_vm downward and
 * janet_continue sideways, and either may be the Zig side. */
JanetSignal janet_check_can_resume(JanetFiber *fiber, Janet *out, int is_cancel);
JanetSignal janet_continue_no_check(JanetFiber *fiber, Janet in, Janet *out);

/* Always src/core/vm.c, whichever selector provides the loop.
 *
 * janet_vm_trace is vm.c's vm_do_trace as a function. It takes the fiber
 * rather than a pointer into its stack because janet_eprintf can resize that
 * stack between elements, which is why the C original is a macro.
 *
 * janet_vm_trace_argv is the same macro over an argv the caller owns, which is
 * what janet_call has. Both can re-enter the interpreter through janet_eprintf,
 * which is the subject of a FOUND.md entry. */
void janet_vm_trace(JanetFunction *func, int32_t argc, JanetFiber *fiber);
void janet_vm_trace_argv(JanetFunction *func, int32_t argc, const Janet *argv);

#ifdef JANET_CALL_TRAMPOLINE
/* The other direction: a setjmp scope in a C frame around an action a Zig
 * frame chose. `context` points at the caller's frame and carries both the
 * arguments and the result; it is read only when JANET_SIGNAL_OK is returned.
 * Exists only in a trampoline build, which since Phase 9 Part 3 is not the
 * default under either selector; PLAN.md's Phase 9 section has the reversal.
 *
 * janet_vm_error_string builds the message janet_panicf would have built
 * without raising it, and is variadic for the same reason janet_panicf is: the
 * caller's format string and arguments have to arrive unaltered for the
 * message to be identical. */
typedef void (*JanetVmAction)(void *context);
JanetSignal janet_vm_scoped(JanetVmAction action, void *context, Janet *out);
Janet janet_vm_error_string(const char *format, ...);
#endif

#ifdef JANET_NET
void janet_net_init(void);
void janet_net_deinit(void);
#endif

#ifdef JANET_EV
void janet_ev_init(void);
void janet_ev_deinit(void);
#endif

#endif /* JANET_STATE_H_defined */
