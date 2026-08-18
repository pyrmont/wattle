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

#ifndef JANET_AMALG
#include "features.h"
#include <janet.h>
#include "state.h"
#include "fiber.h"
#include "gc.h"
#include "symcache.h"
#include "util.h"
#endif

#include <math.h>

/* Virtual registers
 *
 * One instruction word
 * CC | BB | AA | OP
 * DD | DD | DD | OP
 * EE | EE | AA | OP
 */
#define A ((*pc >> 8)  & 0xFF)
#define B ((*pc >> 16) & 0xFF)
#define C (*pc >> 24)
#define D (*pc >> 8)
#define E (*pc >> 16)

/* Signed interpretations of registers */
#define CS (*((int32_t *)pc) >> 24)
#define DS (*((int32_t *)pc) >> 8)
#define ES (*((int32_t *)pc) >> 16)

/* How we dispatch instructions. By default, we use
 * a switch inside an infinite loop. For GCC/clang, we use
 * computed gotos. */
#if defined(__GNUC__) && !defined(__EMSCRIPTEN__)
#define JANET_USE_COMPUTED_GOTOS
#endif

#ifdef JANET_USE_COMPUTED_GOTOS
#define VM_START() { goto *op_lookup[first_opcode];
#define VM_END() }
#define VM_OP(op) label_##op :
#define VM_DEFAULT() label_unknown_op:
#define vm_next() goto *op_lookup[*pc & 0xFF]
#define opcode (*pc & 0xFF)
#else
#define VM_START() uint8_t opcode = first_opcode; for (;;) {switch(opcode) {
#define VM_END() }}
#define VM_OP(op) case op :
#define VM_DEFAULT() default:
#define vm_next() opcode = *pc & 0xFF; continue
#endif

/* Commit and restore VM state before possible longjmp */
#define vm_commit() do { janet_stack_frame(stack)->pc = pc; } while (0)
#define vm_restore() do { \
    stack = fiber->data + fiber->frame; \
    pc = janet_stack_frame(stack)->pc; \
    func = janet_stack_frame(stack)->func; \
} while (0)
#define vm_return(sig, val) do { \
    janet_vm.return_reg[0] = (val); \
    vm_commit(); \
    return (sig); \
} while (0)
#define vm_return_no_restore(sig, val) do { \
    janet_vm.return_reg[0] = (val); \
    return (sig); \
} while (0)

/* Next instruction variations */
#define maybe_collect() do {\
    if (janet_vm.next_collection >= janet_vm.gc_interval) janet_collect(); } while (0)
#define vm_checkgc_next() maybe_collect(); vm_next()
#define vm_pcnext() pc++; vm_next()
#define vm_checkgc_pcnext() maybe_collect(); vm_pcnext()

/* Handle certain errors in main vm loop.
 *
 * Every error the interpreter raises itself goes through vm_raisev or vm_raisef.
 * With JANET_CALL_TRAMPOLINE they return the error out of run_vm instead of
 * jumping past its frame, which is what run_vm needs once it is Zig: a longjmp
 * may not cross an active Zig frame, and these raises are in run_vm's own frame
 * rather than a callee's, so no try scope can catch them. JOP_ERROR at
 * JANET_SIGNAL_ERROR is the existing precedent that the return path works.
 *
 * Neither macro commits the program counter. Each site keeps whatever commit it
 * already had, because that is not uniform: JOP_PUSH_ARRAY never committed,
 * JOP_CALL committed before entering janet_fiber_funcframe so its `stack` is
 * stale afterwards, and JOP_TAILCALL commits to a frame it recomputes. Folding a
 * vm_commit() in here would change a stack trace at the first and write through
 * a stale pointer at the second.
 *
 * The DID_LONGJUMP flag is set exactly as janet_signalv (capi.c) sets it. It is
 * read on resume (below) to pop a C frame and to turn a raise at a tail call
 * into an implicit return, so a raise that skipped it would resume differently
 * from the panic it replaces. */
#ifdef JANET_CALL_TRAMPOLINE
#define vm_raise_signal(sig, v) do { \
    janet_vm.return_reg[0] = (v); \
    if (NULL != janet_vm.fiber) janet_vm.fiber->flags |= JANET_FIBER_DID_LONGJUMP; \
    return (sig); \
} while (0)
#define vm_raisev(v) vm_raise_signal(JANET_SIGNAL_ERROR, (v))
#define vm_raisef(...) vm_raisev(vm_error_string(__VA_ARGS__))
#else
#define vm_raisev(v) janet_panicv(v)
#define vm_raisef(...) janet_panicf(__VA_ARGS__)
#endif

#define vm_throw(e) do { vm_commit(); vm_raisev(janet_cstringv(e)); } while (0)
#define vm_assert(cond, e) do {if (!(cond)) vm_throw((e)); } while (0)
#define vm_assert_type(X, T) do { \
    if (!(janet_checktype((X), (T)))) { \
        vm_commit(); \
        vm_raisef("expected %T, got %v", (1 << (T)), (X)); \
    } \
} while (0)
#define vm_assert_types(X, TS) do { \
    if (!(janet_checktypes((X), (TS)))) { \
        vm_commit(); \
        vm_raisef("expected %T, got %v", (TS), (X)); \
    } \
} while (0)
#ifdef JANET_NO_INTERPRETER_INTERRUPT
#define vm_maybe_auto_suspend(COND)
#else
#define vm_maybe_auto_suspend(COND) do { \
    if ((COND) && janet_atomic_load_relaxed(&janet_vm.auto_suspend)) { \
        fiber->flags |= (JANET_FIBER_RESUME_NO_USEVAL | JANET_FIBER_RESUME_NO_SKIP); \
        vm_return(JANET_SIGNAL_INTERRUPT, janet_wrap_nil()); \
    } \
} while (0)
#endif

#ifdef JANET_CALL_TRAMPOLINE
/* Build the message janet_panicf would have built, without raising it. Kept
 * deliberately identical to janet_panicf (capi.c): the whole point of returning
 * an error rather than jumping is that nothing observable changes. */
static Janet vm_error_string(const char *format, ...) {
    va_list args;
    JanetBuffer buffer;
    int32_t len = 0;
    while (format[len]) len++;
    janet_buffer_init(&buffer, len);
    va_start(args, format);
    janet_formatbv(&buffer, format, args);
    va_end(args);
    JanetString ret = janet_string(buffer.data, buffer.count);
    janet_buffer_deinit(&buffer);
    return janet_wrap_string(ret);
}
#endif

/* Templates for certain patterns in opcodes */
#define vm_binop_immediate(op)\
    {\
        Janet op1 = stack[B];\
        if (!janet_checktype(op1, JANET_NUMBER)) {\
            vm_commit();\
            Janet _argv[2] = { op1, janet_wrap_number(CS) };\
            Janet a;\
            vm_mcall(a, #op, 2, _argv);\
            stack = fiber->data + fiber->frame;\
            stack[A] = a;\
            vm_checkgc_pcnext();\
        } else {\
            double x1 = janet_unwrap_number(op1);\
            stack[A] = janet_wrap_number(x1 op CS);\
            vm_pcnext();\
        }\
    }
#define _vm_bitop_immediate(op, type1, rangecheck, msg)\
    {\
        Janet op1 = stack[B];\
        if (!janet_checktype(op1, JANET_NUMBER)) {\
            vm_commit();\
            Janet _argv[2] = { op1, janet_wrap_number(CS) };\
            Janet a;\
            vm_mcall(a, #op, 2, _argv);\
            stack = fiber->data + fiber->frame;\
            stack[A] = a;\
            vm_checkgc_pcnext();\
        } else {\
            double y1 = janet_unwrap_number(op1);\
            if (!rangecheck(y1)) { vm_commit(); vm_raisef("value %v out of range for " msg, op1); }\
            type1 x1 = (type1) y1;\
            stack[A] = janet_wrap_number((type1) (x1 op CS));\
            vm_pcnext();\
        }\
    }
#define vm_bitop_immediate(op) _vm_bitop_immediate(op, int32_t, janet_checkintrange, "32-bit signed integers");
#define vm_bitopu_immediate(op) _vm_bitop_immediate(op, uint32_t, janet_checkuintrange, "32-bit unsigned integers");
#define _vm_binop(op, wrap)\
    {\
        Janet op1 = stack[B];\
        Janet op2 = stack[C];\
        if (janet_checktype(op1, JANET_NUMBER) && janet_checktype(op2, JANET_NUMBER)) {\
            double x1 = janet_unwrap_number(op1);\
            double x2 = janet_unwrap_number(op2);\
            stack[A] = wrap(x1 op x2);\
            vm_pcnext();\
        } else {\
            vm_commit();\
            Janet a;\
            vm_binop_call(a, #op, "r" #op, op1, op2);\
            stack = fiber->data + fiber->frame;\
            stack[A] = a;\
            vm_checkgc_pcnext();\
        }\
    }
#define vm_binop(op) _vm_binop(op, janet_wrap_number)
#define _vm_bitop(op, type1, rangecheck, msg)\
    {\
        Janet op1 = stack[B];\
        Janet op2 = stack[C];\
        if (janet_checktype(op1, JANET_NUMBER) && janet_checktype(op2, JANET_NUMBER)) {\
            double y1 = janet_unwrap_number(op1);\
            double y2 = janet_unwrap_number(op2);\
            if (!rangecheck(y1)) { vm_commit(); vm_raisef("value %v out of range for " msg, op1); }\
            if (!janet_checkintrange(y2)) { vm_commit(); vm_raisef("rhs must be valid 32-bit signed integer, got %f", op2); }\
            type1 x1 = (type1) y1;\
            int32_t x2 = (int32_t) y2;\
            stack[A] = janet_wrap_number((type1) (x1 op x2));\
            vm_pcnext();\
        } else {\
            vm_commit();\
            Janet a;\
            vm_binop_call(a, #op, "r" #op, op1, op2);\
            stack = fiber->data + fiber->frame;\
            stack[A] = a;\
            vm_checkgc_pcnext();\
        }\
    }
#define vm_bitop(op) _vm_bitop(op, int32_t, janet_checkintrange, "32-bit signed integers")
#define vm_bitopu(op) _vm_bitop(op, uint32_t, janet_checkuintrange, "32-bit unsigned integers")
#define vm_compop(op) \
    {\
        Janet op1 = stack[B];\
        Janet op2 = stack[C];\
        if (janet_checktype(op1, JANET_NUMBER) && janet_checktype(op2, JANET_NUMBER)) {\
            double x1 = janet_unwrap_number(op1);\
            double x2 = janet_unwrap_number(op2);\
            stack[A] = janet_wrap_boolean(x1 op x2);\
            vm_pcnext();\
        } else {\
            vm_commit();\
            int _cmp;\
            vm_compare(_cmp, op1, op2);\
            Janet a = janet_wrap_boolean(_cmp op 0);\
            stack = fiber->data + fiber->frame;\
            stack[A] = a;\
            vm_checkgc_pcnext();\
        }\
    }
#define vm_compop_imm(op) \
    {\
        Janet op1 = stack[B];\
        if (janet_checktype(op1, JANET_NUMBER)) {\
            double x1 = janet_unwrap_number(op1);\
            double x2 = (double) CS; \
            stack[A] = janet_wrap_boolean(x1 op x2);\
            vm_pcnext();\
        } else {\
            vm_commit();\
            int _cmp;\
            vm_compare(_cmp, op1, janet_wrap_integer(CS));\
            Janet a = janet_wrap_boolean(_cmp op 0);\
            stack = fiber->data + fiber->frame;\
            stack[A] = a;\
            vm_checkgc_pcnext();\
        }\
    }

/* Trace a function call.
 * This is a macro to avoid stale argv if janet_eprintf resizes the stack
 */
#define vm_do_trace(func, argc, argv) do { \
    JanetFunction* _func = (func);\
    if (_func->def->name) {\
        janet_eprintf("trace (%S", _func->def->name);\
    } else {\
        janet_eprintf("trace (%p", janet_wrap_function(_func));\
    }\
    int32_t _argc = (argc);\
    for (int32_t i = 0; i < _argc; i++) {\
        janet_eprintf(" %p", (argv)[i]);\
    }\
    janet_eprintf(")\n");\
} while (0)

/* Invoke a method once we have looked it up */
static Janet janet_method_invoke(Janet method, int32_t argc, Janet *argv) {
    switch (janet_type(method)) {
        case JANET_CFUNCTION:
            return (janet_unwrap_cfunction(method))(argc, argv);
        case JANET_FUNCTION: {
            JanetFunction *fun = janet_unwrap_function(method);
            return janet_call(fun, argc, argv);
        }
        case JANET_ABSTRACT: {
            JanetAbstract abst = janet_unwrap_abstract(method);
            const JanetAbstractType *at = janet_abstract_type(abst);
            if (NULL != at->call) {
                return at->call(abst, argc, argv);
            }
        }
        /* fallthrough */
        case JANET_STRING:
        case JANET_BUFFER:
        case JANET_TABLE:
        case JANET_STRUCT:
        case JANET_ARRAY:
        case JANET_TUPLE: {
            if (argc != 1) {
                janet_panicf("%v called with %d arguments, possibly expected 1", method, argc);
            }
            return janet_in(method, argv[0]);
        }
        default: {
            if (argc != 1) {
                janet_panicf("%v called with %d arguments, possibly expected 1", method, argc);
            }
            return janet_in(argv[0], method);
        }
    }
}

/* Call a non function type from a JOP_CALL or JOP_TAILCALL instruction.
 * Assumes that the arguments are on the fiber stack. */
static Janet call_nonfn(JanetFiber *fiber, Janet callee) {
    int32_t argc = fiber->stacktop - fiber->stackstart;
    fiber->stacktop = fiber->stackstart;
    return janet_method_invoke(callee, argc, fiber->data + fiber->stacktop);
}

/* Method lookup could potentially handle tables specially... */
static Janet method_to_fun(Janet method, Janet obj) {
    return janet_get(obj, method);
}

/* Get a callable from a keyword method name and ensure that it is valid. */
static Janet resolve_method(Janet name, JanetFiber *fiber) {
    int32_t argc = fiber->stacktop - fiber->stackstart;
    if (argc < 1) janet_panicf("method call (%v) takes at least 1 argument, got 0", name);
    Janet callee = method_to_fun(name, fiber->data[fiber->stackstart]);
    if (janet_checktype(callee, JANET_NIL))
        janet_panicf("unknown method %v invoked on %v", name, fiber->data[fiber->stackstart]);
    return callee;
}

/* Lookup method on value x */
static Janet janet_method_lookup(Janet x, const char *name) {
    return method_to_fun(janet_ckeywordv(name), x);
}

static Janet janet_unary_call(const char *method, Janet arg) {
    Janet m = janet_method_lookup(arg, method);
    if (janet_checktype(m, JANET_NIL)) {
        janet_panicf("could not find method :%s for %v", method, arg);
    } else {
        Janet argv[1] = { arg };
        return janet_method_invoke(m, 1, argv);
    }
}

/* Call a method first on the righthand side, and then on the left hand side with a prefix */
static Janet janet_binop_call(const char *lmethod, const char *rmethod, Janet lhs, Janet rhs) {
    Janet lm = janet_method_lookup(lhs, lmethod);
    if (janet_checktype(lm, JANET_NIL)) {
        /* Invert order for rmethod */
        Janet lr = janet_method_lookup(rhs, rmethod);
        Janet argv[2] = { rhs, lhs };
        if (janet_checktype(lr, JANET_NIL)) {
            janet_panicf("could not find method :%s for %v or :%s for %v",
                         lmethod, lhs,
                         rmethod, rhs);
        }
        return janet_method_invoke(lr, 2, argv);
    } else {
        Janet argv[2] = { lhs, rhs };
        return janet_method_invoke(lm, 2, argv);
    }
}

/* Fill loops for the collection-constructing opcodes.
 *
 * Lifted out of run_vm so that a try scope can wrap a whole loop rather than
 * each element, and called from both builds so the two configurations run the
 * same code.
 *
 * All three are raise-capable in a way that reads like plain allocation.
 * janet_table_put and janet_struct_put hash and compare every key on the way
 * in, and janet_to_string_b dispatches to an abstract type's tostring, so each
 * can reach a callback supplied by a native module. janet_to_string_b can also
 * raise "buffer overflow" from janet_buffer_ensure without any callback at all.
 */
static void fill_table(JanetTable *table, const Janet *mem, int32_t count) {
    for (int32_t i = 0; i < count; i += 2)
        janet_table_put(table, mem[i], mem[i + 1]);
}

static void fill_struct(JanetKV *st, const Janet *mem, int32_t count) {
    for (int32_t i = 0; i < count; i += 2)
        janet_struct_put(st, mem[i], mem[i + 1]);
}

static void fill_string(JanetBuffer *buffer, const Janet *mem, int32_t count) {
    for (int32_t i = 0; i < count; i++)
        janet_to_string_b(buffer, mem[i]);
}

/* Forward declaration */
static JanetSignal janet_check_can_resume(JanetFiber *fiber, Janet *out, int is_cancel);
static JanetSignal janet_continue_no_check(JanetFiber *fiber, Janet in, Janet *out);

#ifdef JANET_CALL_TRAMPOLINE

/* Phase 7 groundwork, off by default. A try scope per raise-capable call out of
 * run_vm, so that a callee's signal is caught one frame below run_vm instead of
 * jumping past it. This is what run_vm needs once it is Zig: the setjmp and the
 * longjmp must sit in the same C frame, with no Zig frame between them. Measured
 * at about 2ns per scope; SPIKE-7.md has the figures and the reasoning.
 *
 * The spelling below matters. Darwin's setjmp saves the signal mask and costs
 * fifty times more than _setjmp; glibc's and musl's do not. The split at
 * janet.h:422-425 is what keeps this affordable at call granularity, and
 * sigsetjmp with a non-zero savemask would cost 100ns a call on every platform.
 *
 * Deliberately narrower than janet_try_init/janet_restore (vm.c:1909-1928),
 * which save six VM fields:
 *  - stackn is not incremented. Doing it per call would tighten
 *    JANET_RECURSION_GUARD by one level for every C call in a chain.
 *  - gc_suspend and vm_fiber are not saved. They matter only on the error path,
 *    and the signal is handed straight back to the enclosing scope, which
 *    restores them as before.
 *  - coerce_error is left alone. janet_try_init clears it, but ev/give, ev/take
 *    and ev/select read it inside the cfunction (ev.c:1283, :1298, :1323) to
 *    refuse suspension inside janet_call. Clearing it would silently drop that
 *    check. Preserving it also keeps the coercion in janet_signalv correct: the
 *    inner raise coerces exactly as it does today.
 *
 * That leaves the signal buffer and the return register, which are the whole
 * mechanism, plus the jmp_buf and the payload.
 */
typedef struct {
    jmp_buf *old_signal_buf;
    Janet *old_return_reg;
    jmp_buf buf;
    Janet payload;
} JanetVmTryState;

static void vm_scope_enter(JanetVmTryState *st) {
    st->old_signal_buf = janet_vm.signal_buf;
    st->old_return_reg = janet_vm.return_reg;
    janet_vm.signal_buf = &st->buf;
    janet_vm.return_reg = &st->payload;
}

static void vm_scope_leave(JanetVmTryState *st) {
    janet_vm.signal_buf = st->old_signal_buf;
    janet_vm.return_reg = st->old_return_reg;
}

#if defined(JANET_BSD) || defined(JANET_APPLE)
#define vm_scope_setjmp(st) ((JanetSignal) _setjmp((st)->buf))
#else
#define vm_scope_setjmp(st) ((JanetSignal) setjmp((st)->buf))
#endif

/* The body of every scoped wrapper below.
 *
 * Each wrapper is a separate function rather than a macro expanded into run_vm,
 * and that is not a matter of taste. A local of the frame containing the setjmp
 * has an indeterminate value after a longjmp if it was modified in between and
 * is not volatile. run_vm's `stack`, `pc` and `func` are modified constantly and
 * are declared register precisely because the dispatch loop cannot afford to
 * spill them. Putting the setjmp in its own frame is what keeps that true.
 *
 * `out` carries the payload on the error path for every wrapper, including the
 * ones whose helper returns void or int, because that is what the caller must
 * hand to vm_raise_signal. */
#define vm_scope_run(action) \
    JanetVmTryState _st; \
    vm_scope_enter(&_st); \
    JanetSignal _sig = vm_scope_setjmp(&_st); \
    if (_sig == JANET_SIGNAL_OK) { \
        action; \
    } else { \
        *out = _st.payload; \
    } \
    vm_scope_leave(&_st); \
    return _sig

static JanetSignal scoped_cfunction(JanetCFunction cfun, int32_t argc, Janet *argv, Janet *out) {
    vm_scope_run(*out = cfun(argc, argv));
}

static JanetSignal scoped_mcall(const char *name, int32_t argc, Janet *argv, Janet *out) {
    vm_scope_run(*out = janet_mcall(name, argc, argv));
}

static JanetSignal scoped_binop_call(const char *lmethod, const char *rmethod,
                                     Janet lhs, Janet rhs, Janet *out) {
    vm_scope_run(*out = janet_binop_call(lmethod, rmethod, lhs, rhs));
}

static JanetSignal scoped_unary_call(const char *method, Janet arg, Janet *out) {
    vm_scope_run(*out = janet_unary_call(method, arg));
}

static JanetSignal scoped_equals(Janet x, Janet y, int *res, Janet *out) {
    vm_scope_run(*res = janet_equals(x, y));
}

static JanetSignal scoped_compare(Janet x, Janet y, int *res, Janet *out) {
    vm_scope_run(*res = janet_compare(x, y));
}

static JanetSignal scoped_next(Janet ds, Janet key, Janet *out) {
    vm_scope_run(*out = janet_next_impl(ds, key, 1));
}

static JanetSignal scoped_in(Janet ds, Janet key, Janet *out) {
    vm_scope_run(*out = janet_in(ds, key));
}

static JanetSignal scoped_get(Janet ds, Janet key, Janet *out) {
    vm_scope_run(*out = janet_get(ds, key));
}

static JanetSignal scoped_getindex(Janet ds, int32_t index, Janet *out) {
    vm_scope_run(*out = janet_getindex(ds, index));
}

static JanetSignal scoped_lengthv(Janet x, Janet *out) {
    vm_scope_run(*out = janet_lengthv(x));
}

static JanetSignal scoped_put(Janet ds, Janet key, Janet value, Janet *out) {
    vm_scope_run(janet_put(ds, key, value));
}

static JanetSignal scoped_putindex(Janet ds, int32_t index, Janet value, Janet *out) {
    vm_scope_run(janet_putindex(ds, index, value));
}

/* The frame and collection machinery run_vm reaches directly.
 *
 * resolve_method and call_nonfn are the method and non-function call paths at
 * JOP_CALL and JOP_TAILCALL. The janet_fiber_push family each raise
 * "stack overflow" (fiber.c:136-178). The three fill wrappers take the scope
 * around the loop rather than around each element, which is both cheaper and
 * the only placement that can see a partially built collection.
 *
 * Not scoped, checked rather than assumed: janet_fiber_funcframe,
 * janet_fiber_funcframe_tail and janet_check_can_resume contain no janet_panic
 * and report by return value, and janet_gcalloc, janet_tuple_n, janet_array_n,
 * janet_table, janet_struct_begin and janet_buffer end an allocation failure in
 * JANET_OUT_OF_MEMORY, which exits rather than jumping. janet_continue_no_check
 * and janet_continue_signal open a janet_try of their own and already return a
 * signal. */
static JanetSignal scoped_resolve_method(Janet name, JanetFiber *fiber, Janet *out) {
    vm_scope_run(*out = resolve_method(name, fiber));
}

static JanetSignal scoped_call_nonfn(JanetFiber *fiber, Janet callee, Janet *out) {
    vm_scope_run(*out = call_nonfn(fiber, callee));
}

static JanetSignal scoped_fiber_push(JanetFiber *fiber, Janet x, Janet *out) {
    vm_scope_run(janet_fiber_push(fiber, x));
}

static JanetSignal scoped_fiber_push2(JanetFiber *fiber, Janet x, Janet y, Janet *out) {
    vm_scope_run(janet_fiber_push2(fiber, x, y));
}

static JanetSignal scoped_fiber_push3(JanetFiber *fiber, Janet x, Janet y, Janet z, Janet *out) {
    vm_scope_run(janet_fiber_push3(fiber, x, y, z));
}

static JanetSignal scoped_fiber_pushn(JanetFiber *fiber, const Janet *arr, int32_t n, Janet *out) {
    vm_scope_run(janet_fiber_pushn(fiber, arr, n));
}

static JanetSignal scoped_fill_table(JanetTable *table, const Janet *mem, int32_t count, Janet *out) {
    vm_scope_run(fill_table(table, mem, count));
}

static JanetSignal scoped_fill_struct(JanetKV *st, const Janet *mem, int32_t count, Janet *out) {
    vm_scope_run(fill_struct(st, mem, count));
}

static JanetSignal scoped_fill_string(JanetBuffer *buffer, const Janet *mem, int32_t count, Janet *out) {
    vm_scope_run(fill_string(buffer, mem, count));
}

/* Call through a scope and return anything it caught out of run_vm, rather than
 * re-raising it past run_vm's frame. This is the half of the mechanism the spike
 * deferred: the scope stops the jump, and this stops the jump being started
 * again.
 *
 * It is not a change in semantics. The signal is returned unaltered, because
 * janet_signalv already applied every transformation it applies: these scopes
 * leave coerce_error alone, so the raise inside the callee coerced (and bumped
 * root_fiber->sched_id for an EVENT signal) at the point it was raised. A second
 * janet_signalv on the way out would find sig already JANET_SIGNAL_ERROR and do
 * nothing further. capi.c:89 is the only longjmp that targets
 * janet_vm.signal_buf, so there is no other way into this branch that could have
 * skipped that.
 *
 * Nothing after the call runs on the error path, which is what the jump did too:
 * the frame is left unpopped at JOP_CALL, `stack` is left unrefreshed, and
 * JANET_FIBER_RESUME_NO_USEVAL is left set at JOP_PUT. Each of those is
 * observable and each is preserved by returning immediately. */
#define vm_scoped(payload, call) do { \
        JanetSignal _s = (call); \
        if (_s != JANET_SIGNAL_OK) vm_raise_signal(_s, (payload)); \
    } while (0)

#define vm_call_cfunction(cfun, argc, argv, dest) \
    vm_scoped((dest), scoped_cfunction((cfun), (argc), (argv), &(dest)))
#define vm_mcall(dest, name, argc, argv) \
    vm_scoped((dest), scoped_mcall((name), (argc), (argv), &(dest)))
#define vm_binop_call(dest, lmethod, rmethod, lhs, rhs) \
    vm_scoped((dest), scoped_binop_call((lmethod), (rmethod), (lhs), (rhs), &(dest)))
#define vm_unary_call(dest, method, arg) \
    vm_scoped((dest), scoped_unary_call((method), (arg), &(dest)))
#define vm_equals(res, x, y) do { \
        Janet _payload; \
        vm_scoped(_payload, scoped_equals((x), (y), &(res), &_payload)); \
    } while (0)
#define vm_compare(res, x, y) do { \
        Janet _payload; \
        vm_scoped(_payload, scoped_compare((x), (y), &(res), &_payload)); \
    } while (0)
#define vm_next_impl(dest, ds, key) \
    vm_scoped((dest), scoped_next((ds), (key), &(dest)))
#define vm_in(dest, ds, key) \
    vm_scoped((dest), scoped_in((ds), (key), &(dest)))
#define vm_get(dest, ds, key) \
    vm_scoped((dest), scoped_get((ds), (key), &(dest)))
#define vm_getindex(dest, ds, index) \
    vm_scoped((dest), scoped_getindex((ds), (index), &(dest)))
#define vm_lengthv(dest, x) \
    vm_scoped((dest), scoped_lengthv((x), &(dest)))
#define vm_put(ds, key, value) do { \
        Janet _payload; \
        vm_scoped(_payload, scoped_put((ds), (key), (value), &_payload)); \
    } while (0)
#define vm_putindex(ds, index, value) do { \
        Janet _payload; \
        vm_scoped(_payload, scoped_putindex((ds), (index), (value), &_payload)); \
    } while (0)
#define vm_resolve_method(dest, name, fiber) \
    vm_scoped((dest), scoped_resolve_method((name), (fiber), &(dest)))
#define vm_call_nonfn(dest, fiber, callee) \
    vm_scoped((dest), scoped_call_nonfn((fiber), (callee), &(dest)))
#define vm_fiber_push(fiber, x) do { \
        Janet _payload; \
        vm_scoped(_payload, scoped_fiber_push((fiber), (x), &_payload)); \
    } while (0)
#define vm_fiber_push2(fiber, x, y) do { \
        Janet _payload; \
        vm_scoped(_payload, scoped_fiber_push2((fiber), (x), (y), &_payload)); \
    } while (0)
#define vm_fiber_push3(fiber, x, y, z) do { \
        Janet _payload; \
        vm_scoped(_payload, scoped_fiber_push3((fiber), (x), (y), (z), &_payload)); \
    } while (0)
#define vm_fiber_pushn(fiber, arr, n) do { \
        Janet _payload; \
        vm_scoped(_payload, scoped_fiber_pushn((fiber), (arr), (n), &_payload)); \
    } while (0)
#define vm_fill_table(table, mem, count) do { \
        Janet _payload; \
        vm_scoped(_payload, scoped_fill_table((table), (mem), (count), &_payload)); \
    } while (0)
#define vm_fill_struct(st, mem, count) do { \
        Janet _payload; \
        vm_scoped(_payload, scoped_fill_struct((st), (mem), (count), &_payload)); \
    } while (0)
#define vm_fill_string(buffer, mem, count) do { \
        Janet _payload; \
        vm_scoped(_payload, scoped_fill_string((buffer), (mem), (count), &_payload)); \
    } while (0)

#else

#define vm_call_cfunction(cfun, argc, argv, dest) do { \
        (dest) = (cfun)((argc), (argv)); \
    } while (0)
#define vm_mcall(dest, name, argc, argv) do { \
        (dest) = janet_mcall((name), (argc), (argv)); \
    } while (0)
#define vm_binop_call(dest, lmethod, rmethod, lhs, rhs) do { \
        (dest) = janet_binop_call((lmethod), (rmethod), (lhs), (rhs)); \
    } while (0)
#define vm_unary_call(dest, method, arg) do { \
        (dest) = janet_unary_call((method), (arg)); \
    } while (0)
#define vm_equals(res, x, y) do { (res) = janet_equals((x), (y)); } while (0)
#define vm_compare(res, x, y) do { (res) = janet_compare((x), (y)); } while (0)
#define vm_next_impl(dest, ds, key) do { \
        (dest) = janet_next_impl((ds), (key), 1); \
    } while (0)
#define vm_in(dest, ds, key) do { (dest) = janet_in((ds), (key)); } while (0)
#define vm_get(dest, ds, key) do { (dest) = janet_get((ds), (key)); } while (0)
#define vm_getindex(dest, ds, index) do { \
        (dest) = janet_getindex((ds), (index)); \
    } while (0)
#define vm_lengthv(dest, x) do { (dest) = janet_lengthv((x)); } while (0)
#define vm_put(ds, key, value) do { \
        janet_put((ds), (key), (value)); \
    } while (0)
#define vm_putindex(ds, index, value) do { \
        janet_putindex((ds), (index), (value)); \
    } while (0)
#define vm_resolve_method(dest, name, fiber) do { \
        (dest) = resolve_method((name), (fiber)); \
    } while (0)
#define vm_call_nonfn(dest, fiber, callee) do { \
        (dest) = call_nonfn((fiber), (callee)); \
    } while (0)
#define vm_fiber_push(fiber, x) janet_fiber_push((fiber), (x))
#define vm_fiber_push2(fiber, x, y) janet_fiber_push2((fiber), (x), (y))
#define vm_fiber_push3(fiber, x, y, z) janet_fiber_push3((fiber), (x), (y), (z))
#define vm_fiber_pushn(fiber, arr, n) janet_fiber_pushn((fiber), (arr), (n))
#define vm_fill_table(table, mem, count) fill_table((table), (mem), (count))
#define vm_fill_struct(st, mem, count) fill_struct((st), (mem), (count))
#define vm_fill_string(buffer, mem, count) fill_string((buffer), (mem), (count))

#endif

/* Interpreter main loop */
static JanetSignal run_vm(JanetFiber *fiber, Janet in) {

    /* opcode -> label lookup if using clang/GCC */
#ifdef JANET_USE_COMPUTED_GOTOS
    static void *op_lookup[255] = {
        &&label_JOP_NOOP,
        &&label_JOP_ERROR,
        &&label_JOP_TYPECHECK,
        &&label_JOP_RETURN,
        &&label_JOP_RETURN_NIL,
        &&label_JOP_ADD_IMMEDIATE,
        &&label_JOP_ADD,
        &&label_JOP_SUBTRACT_IMMEDIATE,
        &&label_JOP_SUBTRACT,
        &&label_JOP_MULTIPLY_IMMEDIATE,
        &&label_JOP_MULTIPLY,
        &&label_JOP_DIVIDE_IMMEDIATE,
        &&label_JOP_DIVIDE,
        &&label_JOP_DIVIDE_FLOOR,
        &&label_JOP_MODULO,
        &&label_JOP_REMAINDER,
        &&label_JOP_BAND,
        &&label_JOP_BOR,
        &&label_JOP_BXOR,
        &&label_JOP_BNOT,
        &&label_JOP_SHIFT_LEFT,
        &&label_JOP_SHIFT_LEFT_IMMEDIATE,
        &&label_JOP_SHIFT_RIGHT,
        &&label_JOP_SHIFT_RIGHT_IMMEDIATE,
        &&label_JOP_SHIFT_RIGHT_UNSIGNED,
        &&label_JOP_SHIFT_RIGHT_UNSIGNED_IMMEDIATE,
        &&label_JOP_MOVE_FAR,
        &&label_JOP_MOVE_NEAR,
        &&label_JOP_JUMP,
        &&label_JOP_JUMP_IF,
        &&label_JOP_JUMP_IF_NOT,
        &&label_JOP_JUMP_IF_NIL,
        &&label_JOP_JUMP_IF_NOT_NIL,
        &&label_JOP_GREATER_THAN,
        &&label_JOP_GREATER_THAN_IMMEDIATE,
        &&label_JOP_LESS_THAN,
        &&label_JOP_LESS_THAN_IMMEDIATE,
        &&label_JOP_EQUALS,
        &&label_JOP_EQUALS_IMMEDIATE,
        &&label_JOP_COMPARE,
        &&label_JOP_LOAD_NIL,
        &&label_JOP_LOAD_TRUE,
        &&label_JOP_LOAD_FALSE,
        &&label_JOP_LOAD_INTEGER,
        &&label_JOP_LOAD_CONSTANT,
        &&label_JOP_LOAD_UPVALUE,
        &&label_JOP_LOAD_SELF,
        &&label_JOP_SET_UPVALUE,
        &&label_JOP_CLOSURE,
        &&label_JOP_PUSH,
        &&label_JOP_PUSH_2,
        &&label_JOP_PUSH_3,
        &&label_JOP_PUSH_ARRAY,
        &&label_JOP_CALL,
        &&label_JOP_TAILCALL,
        &&label_JOP_RESUME,
        &&label_JOP_SIGNAL,
        &&label_JOP_PROPAGATE,
        &&label_JOP_IN,
        &&label_JOP_GET,
        &&label_JOP_PUT,
        &&label_JOP_GET_INDEX,
        &&label_JOP_PUT_INDEX,
        &&label_JOP_LENGTH,
        &&label_JOP_MAKE_ARRAY,
        &&label_JOP_MAKE_BUFFER,
        &&label_JOP_MAKE_STRING,
        &&label_JOP_MAKE_STRUCT,
        &&label_JOP_MAKE_TABLE,
        &&label_JOP_MAKE_TUPLE,
        &&label_JOP_MAKE_BRACKET_TUPLE,
        &&label_JOP_GREATER_THAN_EQUAL,
        &&label_JOP_LESS_THAN_EQUAL,
        &&label_JOP_NEXT,
        &&label_JOP_NOT_EQUALS,
        &&label_JOP_NOT_EQUALS_IMMEDIATE,
        &&label_JOP_CANCEL,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op,
        &&label_unknown_op
    };
#endif

    /* Interpreter state */
    register Janet *stack;
    register uint32_t *pc;
    register JanetFunction *func;

    if (fiber->flags & JANET_FIBER_RESUME_SIGNAL) {
        JanetSignal sig = (fiber->gc.flags & JANET_FIBER_STATUS_MASK) >> JANET_FIBER_STATUS_OFFSET;
        fiber->gc.flags &= ~JANET_FIBER_STATUS_MASK;
        fiber->flags &= ~(JANET_FIBER_RESUME_SIGNAL | JANET_FIBER_FLAG_MASK);
        janet_vm.return_reg[0] = in;
        return sig;
    }

    vm_restore();

    if (fiber->flags & JANET_FIBER_DID_LONGJUMP) {
        if (janet_fiber_frame(fiber)->func == NULL) {
            /* Inside a c function */
            janet_fiber_popframe(fiber);
            vm_restore();
        }
        /* Check if we were at a tail call instruction. If so, do implicit return */
        if ((*pc & 0xFF) == JOP_TAILCALL) {
            /* Tail call resume */
            int entrance_frame = janet_stack_frame(stack)->flags & JANET_STACKFRAME_ENTRANCE;
            janet_fiber_popframe(fiber);
            if (entrance_frame) {
                fiber->flags &= ~JANET_FIBER_FLAG_MASK;
                vm_return(JANET_SIGNAL_OK, in);
            }
            vm_restore();
        }
    }

    if (!(fiber->flags & JANET_FIBER_RESUME_NO_USEVAL)) stack[A] = in;
    if (!(fiber->flags & JANET_FIBER_RESUME_NO_SKIP)) pc++;

    uint8_t first_opcode = *pc & ((fiber->flags & JANET_FIBER_BREAKPOINT) ? 0x7F : 0xFF);

    fiber->flags &= ~JANET_FIBER_FLAG_MASK;

    /* Main interpreter loop. Semantically is a switch on
     * (*pc & 0xFF) inside of an infinite loop. */
    VM_START();

    VM_DEFAULT();
    fiber->flags |= JANET_FIBER_BREAKPOINT | JANET_FIBER_RESUME_NO_USEVAL | JANET_FIBER_RESUME_NO_SKIP;
    vm_return(JANET_SIGNAL_DEBUG, janet_wrap_nil());

    VM_OP(JOP_NOOP)
    vm_pcnext();

    VM_OP(JOP_ERROR)
    vm_return(JANET_SIGNAL_ERROR, stack[A]);

    VM_OP(JOP_TYPECHECK)
    vm_assert_types(stack[A], E);
    vm_pcnext();

    VM_OP(JOP_RETURN) {
        Janet retval = stack[D];
        int entrance_frame = janet_stack_frame(stack)->flags & JANET_STACKFRAME_ENTRANCE;
        janet_fiber_popframe(fiber);
        if (entrance_frame) vm_return_no_restore(JANET_SIGNAL_OK, retval);
        vm_restore();
        stack[A] = retval;
        vm_checkgc_pcnext();
    }

    VM_OP(JOP_RETURN_NIL) {
        Janet retval = janet_wrap_nil();
        int entrance_frame = janet_stack_frame(stack)->flags & JANET_STACKFRAME_ENTRANCE;
        janet_fiber_popframe(fiber);
        if (entrance_frame) vm_return_no_restore(JANET_SIGNAL_OK, retval);
        vm_restore();
        stack[A] = retval;
        vm_checkgc_pcnext();
    }

    VM_OP(JOP_ADD_IMMEDIATE)
    vm_binop_immediate(+);

    VM_OP(JOP_ADD)
    vm_binop(+);

    VM_OP(JOP_SUBTRACT_IMMEDIATE)
    vm_binop_immediate(-);

    VM_OP(JOP_SUBTRACT)
    vm_binop(-);

    VM_OP(JOP_MULTIPLY_IMMEDIATE)
    vm_binop_immediate(*);

    VM_OP(JOP_MULTIPLY)
    vm_binop(*);

    VM_OP(JOP_DIVIDE_IMMEDIATE)
    vm_binop_immediate( /);

    VM_OP(JOP_DIVIDE)
    vm_binop( /);

    VM_OP(JOP_DIVIDE_FLOOR) {
        Janet op1 = stack[B];
        Janet op2 = stack[C];
        if (janet_checktype(op1, JANET_NUMBER) && janet_checktype(op2, JANET_NUMBER)) {
            double x1 = janet_unwrap_number(op1);
            double x2 = janet_unwrap_number(op2);
            stack[A] = janet_wrap_number(floor(x1 / x2));
            vm_pcnext();
        } else {
            vm_commit();
            Janet a;
            vm_binop_call(a, "div", "rdiv", op1, op2);
            stack = fiber->data + fiber->frame;
            stack[A] = a;
            vm_checkgc_pcnext();
        }
    }

    VM_OP(JOP_MODULO) {
        Janet op1 = stack[B];
        Janet op2 = stack[C];
        if (janet_checktype(op1, JANET_NUMBER) && janet_checktype(op2, JANET_NUMBER)) {
            double x1 = janet_unwrap_number(op1);
            double x2 = janet_unwrap_number(op2);
            if (x2 == 0) {
                stack[A] = janet_wrap_number(x1);
            } else {
                double intres = x2 * floor(x1 / x2);
                stack[A] = janet_wrap_number(x1 - intres);
            }
            vm_pcnext();
        } else {
            vm_commit();
            Janet a;
            vm_binop_call(a, "mod", "rmod", op1, op2);
            stack = fiber->data + fiber->frame;
            stack[A] = a;
            vm_checkgc_pcnext();
        }
    }

    VM_OP(JOP_REMAINDER) {
        Janet op1 = stack[B];
        Janet op2 = stack[C];
        if (janet_checktype(op1, JANET_NUMBER) && janet_checktype(op2, JANET_NUMBER)) {
            double x1 = janet_unwrap_number(op1);
            double x2 = janet_unwrap_number(op2);
            stack[A] = janet_wrap_number(fmod(x1, x2));
            vm_pcnext();
        } else {
            vm_commit();
            Janet a;
            vm_binop_call(a, "%", "r%", op1, op2);
            stack = fiber->data + fiber->frame;
            stack[A] = a;
            vm_checkgc_pcnext();
        }
    }

    VM_OP(JOP_BAND)
    vm_bitop(&);

    VM_OP(JOP_BOR)
    vm_bitop( |);

    VM_OP(JOP_BXOR)
    vm_bitop(^);

    VM_OP(JOP_BNOT) {
        Janet op = stack[E];
        if (janet_checktype(op, JANET_NUMBER)) {
            stack[A] = janet_wrap_integer(~janet_unwrap_integer(op));
            vm_pcnext();
        } else {
            vm_commit();
            Janet a;
            vm_unary_call(a, "~", op);
            stack = fiber->data + fiber->frame;
            stack[A] = a;
            vm_checkgc_pcnext();
        }
    }

    VM_OP(JOP_SHIFT_RIGHT_UNSIGNED)
    vm_bitopu( >>);

    VM_OP(JOP_SHIFT_RIGHT_UNSIGNED_IMMEDIATE)
    vm_bitopu_immediate( >>);

    VM_OP(JOP_SHIFT_RIGHT)
    vm_bitop( >>);

    VM_OP(JOP_SHIFT_RIGHT_IMMEDIATE)
    vm_bitop_immediate( >>);

    VM_OP(JOP_SHIFT_LEFT)
    vm_bitop( <<);

    VM_OP(JOP_SHIFT_LEFT_IMMEDIATE)
    vm_bitop_immediate( <<);

    VM_OP(JOP_MOVE_NEAR)
    stack[A] = stack[E];
    vm_pcnext();

    VM_OP(JOP_MOVE_FAR)
    stack[E] = stack[A];
    vm_pcnext();

    VM_OP(JOP_JUMP)
    vm_maybe_auto_suspend(DS <= 0);
    pc += DS;
    vm_next();

    VM_OP(JOP_JUMP_IF)
    if (janet_truthy(stack[A])) {
        vm_maybe_auto_suspend(ES <= 0);
        pc += ES;
    } else {
        pc++;
    }
    vm_next();

    VM_OP(JOP_JUMP_IF_NOT)
    if (janet_truthy(stack[A])) {
        pc++;
    } else {
        vm_maybe_auto_suspend(ES <= 0);
        pc += ES;
    }
    vm_next();

    VM_OP(JOP_JUMP_IF_NIL)
    if (janet_checktype(stack[A], JANET_NIL)) {
        vm_maybe_auto_suspend(ES <= 0);
        pc += ES;
    } else {
        pc++;
    }
    vm_next();

    VM_OP(JOP_JUMP_IF_NOT_NIL)
    if (janet_checktype(stack[A], JANET_NIL)) {
        pc++;
    } else {
        vm_maybe_auto_suspend(ES <= 0);
        pc += ES;
    }
    vm_next();

    VM_OP(JOP_LESS_THAN)
    vm_compop( <);

    VM_OP(JOP_LESS_THAN_EQUAL)
    vm_compop( <=);

    VM_OP(JOP_LESS_THAN_IMMEDIATE)
    vm_compop_imm( <);

    VM_OP(JOP_GREATER_THAN)
    vm_compop( >);

    VM_OP(JOP_GREATER_THAN_EQUAL)
    vm_compop( >=);

    VM_OP(JOP_GREATER_THAN_IMMEDIATE)
    vm_compop_imm( >);

    VM_OP(JOP_EQUALS) {
        int eq;
        vm_equals(eq, stack[B], stack[C]);
        stack[A] = janet_wrap_boolean(eq);
    }
    vm_pcnext();

    VM_OP(JOP_EQUALS_IMMEDIATE)
    stack[A] = janet_wrap_boolean(janet_checktype(stack[B], JANET_NUMBER) && (janet_unwrap_number(stack[B]) == (double) CS));
    vm_pcnext();

    VM_OP(JOP_NOT_EQUALS) {
        int eq;
        vm_equals(eq, stack[B], stack[C]);
        stack[A] = janet_wrap_boolean(!eq);
    }
    vm_pcnext();

    VM_OP(JOP_NOT_EQUALS_IMMEDIATE)
    stack[A] = janet_wrap_boolean(!janet_checktype(stack[B], JANET_NUMBER) || (janet_unwrap_number(stack[B]) != (double) CS));
    vm_pcnext();

    VM_OP(JOP_COMPARE) {
        int cmp;
        vm_compare(cmp, stack[B], stack[C]);
        Janet a = janet_wrap_integer(cmp);
        stack = fiber->data + fiber->frame;
        stack[A] = a;
    }
    vm_pcnext();

    VM_OP(JOP_NEXT)
    vm_commit();
    {
        Janet temp;
        vm_next_impl(temp, stack[B], stack[C]);
        vm_restore();
        stack[A] = temp;
    }
    vm_pcnext();

    VM_OP(JOP_LOAD_NIL)
    stack[D] = janet_wrap_nil();
    vm_pcnext();

    VM_OP(JOP_LOAD_TRUE)
    stack[D] = janet_wrap_true();
    vm_pcnext();

    VM_OP(JOP_LOAD_FALSE)
    stack[D] = janet_wrap_false();
    vm_pcnext();

    VM_OP(JOP_LOAD_INTEGER)
    stack[A] = janet_wrap_integer(ES);
    vm_pcnext();

    VM_OP(JOP_LOAD_CONSTANT) {
        int32_t cindex = (int32_t)E;
        vm_assert(cindex < func->def->constants_length, "invalid constant");
        stack[A] = func->def->constants[cindex];
        vm_pcnext();
    }

    VM_OP(JOP_LOAD_SELF)
    stack[D] = janet_wrap_function(func);
    vm_pcnext();

    VM_OP(JOP_LOAD_UPVALUE) {
        int32_t eindex = B;
        int32_t vindex = C;
        JanetFuncEnv *env;
        vm_assert(func->def->environments_length > eindex, "invalid upvalue environment");
        env = func->envs[eindex];
        vm_assert(env->length > vindex, "invalid upvalue index");
        vm_assert(janet_env_valid(env), "invalid upvalue environment");
        if (env->offset > 0) {
            /* On stack */
            stack[A] = env->as.fiber->data[env->offset + vindex];
        } else {
            /* Off stack */
            stack[A] = env->as.values[vindex];
        }
        vm_pcnext();
    }

    VM_OP(JOP_SET_UPVALUE) {
        int32_t eindex = B;
        int32_t vindex = C;
        JanetFuncEnv *env;
        vm_assert(func->def->environments_length > eindex, "invalid upvalue environment");
        env = func->envs[eindex];
        vm_assert(env->length > vindex, "invalid upvalue index");
        vm_assert(janet_env_valid(env), "invalid upvalue environment");
        if (env->offset > 0) {
            env->as.fiber->data[env->offset + vindex] = stack[A];
        } else {
            env->as.values[vindex] = stack[A];
        }
        vm_pcnext();
    }

    VM_OP(JOP_CLOSURE) {
        JanetFuncDef *fd;
        JanetFunction *fn;
        int32_t elen;
        int32_t defindex = (int32_t)E;
        vm_assert(defindex < func->def->defs_length, "invalid funcdef");
        fd = func->def->defs[defindex];
        elen = fd->environments_length;
        fn = janet_gcalloc(JANET_MEMORY_FUNCTION, sizeof(JanetFunction) + ((size_t) elen * sizeof(JanetFuncEnv *)));
        fn->def = fd;
        {
            int32_t i;
            for (i = 0; i < elen; ++i) {
                int32_t inherit = fd->environments[i];
                if (inherit == -1 || inherit >= func->def->environments_length) {
                    JanetStackFrame *frame = janet_stack_frame(stack);
                    if (!frame->env) {
                        /* Lazy capture of current stack frame */
                        JanetFuncEnv *env = janet_gcalloc(JANET_MEMORY_FUNCENV, sizeof(JanetFuncEnv));
                        env->offset = fiber->frame;
                        env->as.fiber = fiber;
                        env->length = func->def->slotcount;
                        frame->env = env;
                    }
                    fn->envs[i] = frame->env;
                } else {
                    fn->envs[i] = func->envs[inherit];
                }
            }
        }
        stack[A] = janet_wrap_function(fn);
        vm_checkgc_pcnext();
    }

    VM_OP(JOP_PUSH)
    vm_fiber_push(fiber, stack[D]);
    stack = fiber->data + fiber->frame;
    vm_checkgc_pcnext();

    VM_OP(JOP_PUSH_2)
    vm_fiber_push2(fiber, stack[A], stack[E]);
    stack = fiber->data + fiber->frame;
    vm_checkgc_pcnext();

    VM_OP(JOP_PUSH_3)
    vm_fiber_push3(fiber, stack[A], stack[B], stack[C]);
    stack = fiber->data + fiber->frame;
    vm_checkgc_pcnext();

    VM_OP(JOP_PUSH_ARRAY) {
        const Janet *vals;
        int32_t len;
        if (janet_indexed_view(stack[D], &vals, &len)) {
            vm_fiber_pushn(fiber, vals, len);
        } else {
            vm_raisef("expected %T, got %v", JANET_TFLAG_INDEXED, stack[D]);
        }
    }
    stack = fiber->data + fiber->frame;
    vm_checkgc_pcnext();

    VM_OP(JOP_CALL) {
        vm_maybe_auto_suspend(1);
        Janet callee = stack[E];
        if (fiber->stacktop > fiber->maxstack) {
            vm_throw("stack overflow");
        }
        if (janet_checktype(callee, JANET_KEYWORD)) {
            vm_commit();
            vm_resolve_method(callee, callee, fiber);
        }
        if (janet_checktype(callee, JANET_FUNCTION)) {
            func = janet_unwrap_function(callee);
            if (func->gc.flags & JANET_FUNCFLAG_TRACE) {
                vm_do_trace(func, fiber->stacktop - fiber->stackstart, fiber->data + fiber->stackstart);
            }
            vm_commit();
            if (janet_fiber_funcframe(fiber, func)) {
                int32_t n = fiber->stacktop - fiber->stackstart;
                vm_raisef("%v called with %d argument%s, expected %d",
                          callee, n, n == 1 ? "" : "s", func->def->arity);
            }
            stack = fiber->data + fiber->frame;
            pc = func->def->bytecode;
            vm_checkgc_next();
        } else if (janet_checktype(callee, JANET_CFUNCTION)) {
            vm_commit();
            int32_t argc = fiber->stacktop - fiber->stackstart;
            janet_fiber_cframe(fiber, janet_unwrap_cfunction(callee));
            Janet ret;
            vm_call_cfunction(janet_unwrap_cfunction(callee), argc, fiber->data + fiber->frame, ret);
            janet_fiber_popframe(fiber);
            stack = fiber->data + fiber->frame;
            stack[A] = ret;
            vm_checkgc_pcnext();
        } else {
            vm_commit();
            Janet ret;
            vm_call_nonfn(ret, fiber, callee);
            stack[A] = ret;
            vm_pcnext();
        }
    }

    VM_OP(JOP_TAILCALL) {
        vm_maybe_auto_suspend(1);
        Janet callee = stack[D];
        if (fiber->stacktop > fiber->maxstack) {
            vm_throw("stack overflow");
        }
        if (janet_checktype(callee, JANET_KEYWORD)) {
            vm_commit();
            vm_resolve_method(callee, callee, fiber);
        }
        if (janet_checktype(callee, JANET_FUNCTION)) {
            func = janet_unwrap_function(callee);
            if (func->gc.flags & JANET_FUNCFLAG_TRACE) {
                vm_do_trace(func, fiber->stacktop - fiber->stackstart, fiber->data + fiber->stackstart);
            }
            if (janet_fiber_funcframe_tail(fiber, func)) {
                janet_stack_frame(fiber->data + fiber->frame)->pc = pc;
                int32_t n = fiber->stacktop - fiber->stackstart;
                vm_raisef("%v called with %d argument%s, expected %d",
                          callee, n, n == 1 ? "" : "s", func->def->arity);
            }
            stack = fiber->data + fiber->frame;
            pc = func->def->bytecode;
            vm_checkgc_next();
        } else {
            Janet retreg;
            int entrance_frame = janet_stack_frame(stack)->flags & JANET_STACKFRAME_ENTRANCE;
            vm_commit();
            if (janet_checktype(callee, JANET_CFUNCTION)) {
                int32_t argc = fiber->stacktop - fiber->stackstart;
                janet_fiber_cframe(fiber, janet_unwrap_cfunction(callee));
                vm_call_cfunction(janet_unwrap_cfunction(callee), argc, fiber->data + fiber->frame, retreg);
                janet_fiber_popframe(fiber);
            } else {
                vm_call_nonfn(retreg, fiber, callee);
            }
            janet_fiber_popframe(fiber);
            if (entrance_frame) {
                vm_return_no_restore(JANET_SIGNAL_OK, retreg);
            }
            vm_restore();
            stack[A] = retreg;
            vm_checkgc_pcnext();
        }
    }

    VM_OP(JOP_RESUME) {
        Janet retreg;
        vm_maybe_auto_suspend(1);
        vm_assert_type(stack[B], JANET_FIBER);
        JanetFiber *child = janet_unwrap_fiber(stack[B]);
        if (janet_check_can_resume(child, &retreg, 0)) {
            vm_commit();
            vm_raisev(retreg);
        }
        fiber->child = child;
        JanetSignal sig = janet_continue_no_check(child, stack[C], &retreg);
        stack = fiber->data + fiber->frame;
        if (sig != JANET_SIGNAL_OK && !(child->flags & (1 << sig))) {
            vm_return(sig, retreg);
        }
        fiber->child = NULL;
        stack[A] = retreg;
        vm_checkgc_pcnext();
    }

    VM_OP(JOP_SIGNAL) {
        int32_t s = C;
        if (s > JANET_SIGNAL_USER9) s = JANET_SIGNAL_USER9;
        if (s < 0) s = 0;
        vm_return(s, stack[B]);
    }

    VM_OP(JOP_PROPAGATE) {
        Janet fv = stack[C];
        vm_assert_type(fv, JANET_FIBER);
        JanetFiber *f = janet_unwrap_fiber(fv);
        JanetFiberStatus sub_status = janet_fiber_status(f);
        if (sub_status > JANET_STATUS_USER9) {
            vm_commit();
            vm_raisef("cannot propagate from fiber with status :%s",
                      janet_status_names[sub_status]);
        }
        fiber->child = f;
        vm_return((int) sub_status, stack[B]);
    }

    VM_OP(JOP_CANCEL) {
        Janet retreg;
        vm_assert_type(stack[B], JANET_FIBER);
        JanetFiber *child = janet_unwrap_fiber(stack[B]);
        if (janet_check_can_resume(child, &retreg, 1)) {
            vm_commit();
            vm_raisev(retreg);
        }
        fiber->child = child;
        JanetSignal sig = janet_continue_signal(child, stack[C], &retreg, JANET_SIGNAL_ERROR);
        if (sig != JANET_SIGNAL_OK && !(child->flags & (1 << sig))) {
            vm_return(sig, retreg);
        }
        fiber->child = NULL;
        stack = fiber->data + fiber->frame;
        stack[A] = retreg;
        vm_checkgc_pcnext();
    }

    VM_OP(JOP_PUT)
    vm_commit();
    fiber->flags |= JANET_FIBER_RESUME_NO_USEVAL;
    vm_put(stack[A], stack[B], stack[C]);
    stack = fiber->data + fiber->frame;
    fiber->flags &= ~JANET_FIBER_RESUME_NO_USEVAL;
    vm_checkgc_pcnext();

    VM_OP(JOP_PUT_INDEX)
    vm_commit();
    fiber->flags |= JANET_FIBER_RESUME_NO_USEVAL;
    vm_putindex(stack[A], C, stack[B]);
    stack = fiber->data + fiber->frame;
    fiber->flags &= ~JANET_FIBER_RESUME_NO_USEVAL;
    vm_checkgc_pcnext();

    VM_OP(JOP_IN)
    vm_commit();
    {
        Janet a;
        vm_in(a, stack[B], stack[C]);
        stack = fiber->data + fiber->frame;
        stack[A] = a;
    }
    vm_pcnext();

    VM_OP(JOP_GET)
    vm_commit();
    {
        Janet a;
        vm_get(a, stack[B], stack[C]);
        stack = fiber->data + fiber->frame;
        stack[A] = a;
    }
    vm_pcnext();

    VM_OP(JOP_GET_INDEX)
    vm_commit();
    {
        Janet a;
        vm_getindex(a, stack[B], C);
        stack = fiber->data + fiber->frame;
        stack[A] = a;
    }
    vm_pcnext();

    VM_OP(JOP_LENGTH)
    vm_commit();
    {
        Janet a;
        vm_lengthv(a, stack[E]);
        stack = fiber->data + fiber->frame;
        stack[A] = a;
    }
    vm_pcnext();

    VM_OP(JOP_MAKE_ARRAY) {
        int32_t count = fiber->stacktop - fiber->stackstart;
        Janet *mem = fiber->data + fiber->stackstart;
        stack[D] = janet_wrap_array(janet_array_n(mem, count));
        fiber->stacktop = fiber->stackstart;
        vm_checkgc_pcnext();
    }

    VM_OP(JOP_MAKE_TUPLE)
    /* fallthrough */
    VM_OP(JOP_MAKE_BRACKET_TUPLE) {
        int32_t count = fiber->stacktop - fiber->stackstart;
        Janet *mem = fiber->data + fiber->stackstart;
        const Janet *tup = janet_tuple_n(mem, count);
        if (opcode == JOP_MAKE_BRACKET_TUPLE)
            janet_tuple_flag(tup) |= JANET_TUPLE_FLAG_BRACKETCTOR;
        stack[D] = janet_wrap_tuple(tup);
        fiber->stacktop = fiber->stackstart;
        vm_checkgc_pcnext();
    }

    VM_OP(JOP_MAKE_TABLE) {
        int32_t count = fiber->stacktop - fiber->stackstart;
        Janet *mem = fiber->data + fiber->stackstart;
        if (count & 1) {
            vm_commit();
            vm_raisef("expected even number of arguments to table constructor, got %d", count);
        }
        JanetTable *table = janet_table(count / 2);
        vm_fill_table(table, mem, count);
        stack[D] = janet_wrap_table(table);
        fiber->stacktop = fiber->stackstart;
        vm_checkgc_pcnext();
    }

    VM_OP(JOP_MAKE_STRUCT) {
        int32_t count = fiber->stacktop - fiber->stackstart;
        Janet *mem = fiber->data + fiber->stackstart;
        if (count & 1) {
            vm_commit();
            vm_raisef("expected even number of arguments to struct constructor, got %d", count);
        }
        JanetKV *st = janet_struct_begin(count / 2);
        vm_fill_struct(st, mem, count);
        stack[D] = janet_wrap_struct(janet_struct_end(st));
        fiber->stacktop = fiber->stackstart;
        vm_checkgc_pcnext();
    }

    VM_OP(JOP_MAKE_STRING) {
        int32_t count = fiber->stacktop - fiber->stackstart;
        Janet *mem = fiber->data + fiber->stackstart;
        JanetBuffer buffer;
        janet_buffer_init(&buffer, 10 * count);
        /* A raise inside the loop returns without reaching the deinit below, so
         * the buffer's janet_malloc block is leaked. That is what the longjmp
         * did too; see FOUND.md, "JOP_MAKE_STRING leaks its scratch buffer when
         * a conversion raises". Reproduced deliberately rather than fixed. */
        vm_fill_string(&buffer, mem, count);
        stack[D] = janet_stringv(buffer.data, buffer.count);
        janet_buffer_deinit(&buffer);
        fiber->stacktop = fiber->stackstart;
        vm_checkgc_pcnext();
    }

    VM_OP(JOP_MAKE_BUFFER) {
        int32_t count = fiber->stacktop - fiber->stackstart;
        Janet *mem = fiber->data + fiber->stackstart;
        JanetBuffer *buffer = janet_buffer(10 * count);
        vm_fill_string(buffer, mem, count);
        stack[D] = janet_wrap_buffer(buffer);
        fiber->stacktop = fiber->stackstart;
        vm_checkgc_pcnext();
    }

    VM_END()
}

/*
 * Execute a single instruction in the fiber. Does this by inspecting
 * the fiber, setting a breakpoint at the next instruction, executing, and
 * resetting breakpoints to how they were prior. Yes, it's a bit hacky.
 */
JanetSignal janet_step(JanetFiber *fiber, Janet in, Janet *out) {
    /* No finished or currently alive fibers. */
    JanetFiberStatus status = janet_fiber_status(fiber);
    if (status == JANET_STATUS_ALIVE ||
            status == JANET_STATUS_DEAD ||
            status == JANET_STATUS_ERROR) {
        janet_panicf("cannot step fiber with status :%s", janet_status_names[status]);
    }

    /* Get PC for setting breakpoints */
    uint32_t *pc = janet_stack_frame(fiber->data + fiber->frame)->pc;

    /* Check current opcode (sans debug flag). This tells us where the next or next two candidate
     * instructions will be. Usually it's the next instruction in memory,
     * but for branching instructions it is also the target of the branch. */
    uint32_t *nexta = NULL, *nextb = NULL, olda = 0, oldb = 0;

    /* Set temporary breakpoints */
    switch (*pc & 0x7F) {
        default:
            nexta = pc + 1;
            break;
        /* These we just ignore for now. Supporting them means
         * we could step into and out of functions (including JOP_CALL). */
        case JOP_RETURN_NIL:
        case JOP_RETURN:
        case JOP_ERROR:
        case JOP_TAILCALL:
            break;
        case JOP_JUMP:
            nexta = pc + DS;
            break;
        case JOP_JUMP_IF:
        case JOP_JUMP_IF_NOT:
            nexta = pc + 1;
            nextb = pc + ES;
            break;
    }
    if (nexta) {
        olda = *nexta;
        *nexta |= 0x80;
    }
    if (nextb) {
        oldb = *nextb;
        *nextb |= 0x80;
    }

    /* Go */
    JanetSignal signal = janet_continue(fiber, in, out);

    /* Restore */
    if (nexta) *nexta = olda;
    if (nextb) *nextb = oldb;

    return signal;
}

static Janet void_cfunction(int32_t argc, Janet *argv) {
    (void) argc;
    (void) argv;
    janet_panic("placeholder");
}

Janet janet_call(JanetFunction *fun, int32_t argc, const Janet *argv) {
    /* Check entry conditions */
    if (!janet_vm.fiber)
        janet_panic("janet_call failed because there is no current fiber");
    if (janet_vm.stackn >= JANET_RECURSION_GUARD)
        janet_panic("C stack recursed too deeply");

    /* Dirty stack */
    int32_t dirty_stack = janet_vm.fiber->stacktop - janet_vm.fiber->stackstart;
    if (dirty_stack) {
        janet_fiber_cframe(janet_vm.fiber, void_cfunction);
    }

    /* Tracing */
    if (fun->gc.flags & JANET_FUNCFLAG_TRACE) {
        janet_vm.stackn++;
        vm_do_trace(fun, argc, argv);
        janet_vm.stackn--;
    }

    /* Push frame */
    janet_fiber_pushn(janet_vm.fiber, argv, argc);
    if (janet_fiber_funcframe(janet_vm.fiber, fun)) {
        int32_t min = fun->def->min_arity;
        int32_t max = fun->def->max_arity;
        Janet funv = janet_wrap_function(fun);
        if (min == max && min != argc)
            janet_panicf("arity mismatch in %v, expected %d, got %d", funv, min, argc);
        if (min >= 0 && argc < min)
            janet_panicf("arity mismatch in %v, expected at least %d, got %d", funv, min, argc);
        janet_panicf("arity mismatch in %v, expected at most %d, got %d", funv, max, argc);
    }
    janet_fiber_frame(janet_vm.fiber)->flags |= JANET_STACKFRAME_ENTRANCE;

    /* Set up */
    int32_t oldn = janet_vm.stackn++;
    int handle = janet_gclock();

    /* Run vm */
    janet_vm.fiber->flags |= JANET_FIBER_RESUME_NO_USEVAL | JANET_FIBER_RESUME_NO_SKIP;
    int old_coerce_error = janet_vm.coerce_error;
    janet_vm.coerce_error = 1;
    JanetSignal signal = run_vm(janet_vm.fiber, janet_wrap_nil());
    janet_vm.coerce_error = old_coerce_error;

    /* Teardown */
    janet_vm.stackn = oldn;
    janet_gcunlock(handle);
    if (dirty_stack) {
        janet_fiber_popframe(janet_vm.fiber);
        janet_vm.fiber->stacktop += dirty_stack;
    }

    if (signal != JANET_SIGNAL_OK) {
        /* Should match logic in janet_signalv */
#ifdef JANET_EV
        if (janet_vm.root_fiber != NULL && signal == JANET_SIGNAL_EVENT) {
            janet_vm.root_fiber->sched_id++;
        }
#endif
        if (signal != JANET_SIGNAL_ERROR) {
            *janet_vm.return_reg = janet_wrap_string(janet_formatc("%v coerced from %s to error", *janet_vm.return_reg, janet_signal_names[signal]));
        }
        janet_panicv(*janet_vm.return_reg);
    }

    return *janet_vm.return_reg;
}

static JanetSignal janet_check_can_resume(JanetFiber *fiber, Janet *out, int is_cancel) {
    /* Check conditions */
    JanetFiberStatus old_status = janet_fiber_status(fiber);
    if (janet_vm.stackn >= JANET_RECURSION_GUARD) {
        janet_fiber_set_status(fiber, JANET_STATUS_ERROR);
        *out = janet_cstringv("C stack recursed too deeply");
        return JANET_SIGNAL_ERROR;
    }
    /* If a "task" fiber is trying to be used as a normal fiber, detect that. See bug #920.
     * Fibers must be marked as root fibers manually, or by the ev scheduler. */
    if (janet_vm.fiber != NULL && (fiber->gc.flags & JANET_FIBER_FLAG_ROOT)) {
#ifdef JANET_EV
        *out = janet_cstringv(is_cancel
                              ? "cannot cancel root fiber, use ev/cancel"
                              : "cannot resume root fiber, use ev/go");
#else
        *out = janet_cstringv(is_cancel
                              ? "cannot cancel root fiber"
                              : "cannot resume root fiber");
#endif
        return JANET_SIGNAL_ERROR;
    }
    if (old_status == JANET_STATUS_ALIVE ||
            old_status == JANET_STATUS_DEAD ||
            (old_status >= JANET_STATUS_USER0 && old_status <= JANET_STATUS_USER4) ||
            old_status == JANET_STATUS_ERROR) {
        const uint8_t *str = janet_formatc("cannot resume fiber with status :%s",
                                           janet_status_names[old_status]);
        *out = janet_wrap_string(str);
        return JANET_SIGNAL_ERROR;
    }
    return JANET_SIGNAL_OK;
}

#ifndef JANET_ZIG_SIGNAL_CORE

void janet_try_init(JanetTryState *state) {
    state->stackn = janet_vm.stackn++;
    state->gc_handle = janet_vm.gc_suspend;
    state->vm_fiber = janet_vm.fiber;
    state->vm_jmp_buf = janet_vm.signal_buf;
    state->vm_return_reg = janet_vm.return_reg;
    state->coerce_error = janet_vm.coerce_error;
    janet_vm.return_reg = &(state->payload);
    janet_vm.signal_buf = &(state->buf);
    janet_vm.coerce_error = 0;
}

void janet_restore(JanetTryState *state) {
    janet_vm.stackn = state->stackn;
    janet_vm.gc_suspend = state->gc_handle;
    janet_vm.fiber = state->vm_fiber;
    janet_vm.signal_buf = state->vm_jmp_buf;
    janet_vm.return_reg = state->vm_return_reg;
    janet_vm.coerce_error = state->coerce_error;
}

/* The signal travels in gc.flags rather than in flags. That is not a slip: the
 * resume path above (see JANET_FIBER_RESUME_SIGNAL) reads it back out of
 * gc.flags and clears it there, leaving the fiber's real status in flags
 * untouched in between. */
void janet_signal_inject(JanetFiber *fiber, JanetSignal sig) {
    JanetFiber *child = fiber;
    while (child->child) child = child->child;
    child->gc.flags &= ~JANET_FIBER_STATUS_MASK;
    child->gc.flags |= sig << JANET_FIBER_STATUS_OFFSET;
    child->flags |= JANET_FIBER_RESUME_SIGNAL;
}

#endif /* JANET_ZIG_SIGNAL_CORE */

static JanetSignal janet_continue_no_check(JanetFiber *fiber, Janet in, Janet *out) {

    JanetFiberStatus old_status = janet_fiber_status(fiber);

#ifdef JANET_EV
    janet_fiber_did_resume(fiber);
#endif

    /* Clear last value */
    fiber->last_value = janet_wrap_nil();

    /* Continue child fiber if it exists */
    if (fiber->child) {
        if (janet_vm.root_fiber == NULL) janet_vm.root_fiber = fiber;
        JanetFiber *child = fiber->child;
        uint32_t instr = (janet_stack_frame(fiber->data + fiber->frame)->pc)[0];
        janet_vm.stackn++;
        JanetSignal sig = janet_continue(child, in, &in);
        janet_vm.stackn--;
        if (janet_vm.root_fiber == fiber) janet_vm.root_fiber = NULL;
        if (sig != JANET_SIGNAL_OK && !(child->flags & (1 << sig))) {
            *out = in;
            janet_fiber_set_status(fiber, sig);
            fiber->last_value = child->last_value;
            return sig;
        }
        /* Check if we need any special handling for certain opcodes */
        switch (instr & 0x7F) {
            default:
                break;
            case JOP_NEXT: {
                if (sig == JANET_SIGNAL_OK ||
                        sig == JANET_SIGNAL_ERROR ||
                        sig == JANET_SIGNAL_USER0 ||
                        sig == JANET_SIGNAL_USER1 ||
                        sig == JANET_SIGNAL_USER2 ||
                        sig == JANET_SIGNAL_USER3 ||
                        sig == JANET_SIGNAL_USER4) {
                    in = janet_wrap_nil();
                } else {
                    in = janet_wrap_integer(0);
                }
                break;
            }
        }
        fiber->child = NULL;
    }

    /* Handle new fibers being resumed with a non-nil value */
    if (old_status == JANET_STATUS_NEW && !janet_checktype(in, JANET_NIL)) {
        Janet *stack = fiber->data + fiber->frame;
        JanetFunction *func = janet_stack_frame(stack)->func;
        if (func) {
            if (func->def->arity > 0) {
                stack[0] = in;
            } else if (func->def->flags & JANET_FUNCDEF_FLAG_VARARG) {
                stack[0] = janet_wrap_tuple(janet_tuple_n(&in, 1));
            }
        }
    }

    /* If this is a nested continue (root_fiber already set), root the fiber
     * so it survives GC. janet_collect only marks root_fiber, so without
     * this a nested fiber (e.g., from janet_pcall in a C function) would be
     * invisible to GC and could be collected while actively running. */
    int fiber_rooted = (janet_vm.root_fiber != NULL);
    if (fiber_rooted) {
        janet_gcroot(janet_wrap_fiber(fiber));
    }

    /* Save global state */
    JanetTryState tstate;
    JanetSignal sig = janet_try(&tstate);
    if (!sig) {
        /* Normal setup */
        if (janet_vm.root_fiber == NULL) janet_vm.root_fiber = fiber;
        janet_vm.fiber = fiber;
        janet_fiber_set_status(fiber, JANET_STATUS_ALIVE);
        sig = run_vm(fiber, in);
    }

    /* Restore */
    if (janet_vm.root_fiber == fiber) janet_vm.root_fiber = NULL;
    janet_fiber_set_status(fiber, sig);
    janet_restore(&tstate);
    if (fiber_rooted) {
        janet_gcunroot(janet_wrap_fiber(fiber));
    }
    fiber->last_value = tstate.payload;
    *out = tstate.payload;

    return sig;
}

/* Enter the main vm loop */
JanetSignal janet_continue(JanetFiber *fiber, Janet in, Janet *out) {
    /* Check conditions */
    JanetSignal tmp_signal = janet_check_can_resume(fiber, out, 0);
    if (tmp_signal) return tmp_signal;
    return janet_continue_no_check(fiber, in, out);
}

/* Enter the main vm loop but immediately raise a signal */
JanetSignal janet_continue_signal(JanetFiber *fiber, Janet in, Janet *out, JanetSignal sig) {
    JanetSignal tmp_signal = janet_check_can_resume(fiber, out, sig != JANET_SIGNAL_OK);
    if (tmp_signal) return tmp_signal;
    if (sig != JANET_SIGNAL_OK) {
        janet_signal_inject(fiber, sig);
    }
    return janet_continue_no_check(fiber, in, out);
}

JanetSignal janet_pcall(
    JanetFunction *fun,
    int32_t argc,
    const Janet *argv,
    Janet *out,
    JanetFiber **f) {
    JanetFiber *fiber;
    if (f && *f) {
        fiber = janet_fiber_reset(*f, fun, argc, argv);
    } else {
        fiber = janet_fiber(fun, 64, argc, argv);
    }
    if (f) *f = fiber;
    if (NULL == fiber) {
        *out = janet_cstringv("arity mismatch");
        return JANET_SIGNAL_ERROR;
    }
    return janet_continue(fiber, janet_wrap_nil(), out);
}

Janet janet_mcall(const char *name, int32_t argc, Janet *argv) {
    /* At least 1 argument */
    if (argc < 1) {
        janet_panicf("method :%s expected at least 1 argument", name);
    }
    /* Find method */
    Janet method = janet_method_lookup(argv[0], name);
    if (janet_checktype(method, JANET_NIL)) {
        janet_panicf("could not find method :%s for %v", name, argv[0]);
    }
    /* Invoke method */
    return janet_method_invoke(method, argc, argv);
}

/* Setup VM */
int janet_init(void) {

    /* Garbage collection */
    janet_vm.blocks = NULL;
    janet_vm.weak_blocks = NULL;
    janet_vm.next_collection = 0;
    janet_vm.gc_interval = 0x400000;
    janet_vm.block_count = 0;
    janet_vm.gc_mark_phase = 0;

    janet_symcache_init();

    /* Initialize gc roots */
    janet_vm.roots = NULL;
    janet_vm.root_count = 0;
    janet_vm.root_capacity = 0;

    /* Scratch memory */
    janet_vm.user = NULL;
    janet_vm.scratch_mem = NULL;
    janet_vm.scratch_len = 0;
    janet_vm.scratch_cap = 0;

    /* Sandbox flags */
    janet_vm.sandbox_flags = 0;

    /* Initialize registry */
    janet_vm.registry = NULL;
    janet_vm.registry_cap = 0;
    janet_vm.registry_count = 0;
    janet_vm.registry_dirty = 0;

    /* Initialize abstract registry */
    janet_vm.abstract_registry = janet_table(0);
    janet_gcroot(janet_wrap_table(janet_vm.abstract_registry));

    /* Traversal */
    janet_vm.traversal = NULL;
    janet_vm.traversal_base = NULL;
    janet_vm.traversal_top = NULL;

    /* Core env */
    janet_vm.core_env = NULL;

    /* Auto suspension */
    janet_vm.auto_suspend = 0;

    /* Dynamic bindings */
    janet_vm.top_dyns = NULL;

    /* Seed RNG */
    janet_rng_seed(janet_default_rng(), 0);

    /* Fibers */
    janet_vm.fiber = NULL;
    janet_vm.root_fiber = NULL;
    janet_vm.stackn = 0;

#ifdef JANET_EV
    janet_ev_init();
#endif
#ifdef JANET_NET
    janet_net_init();
#endif
    return 0;
}

/* Disable some features at runtime with no way to re-enable them */
void janet_sandbox(uint32_t flags) {
    janet_sandbox_assert(JANET_SANDBOX_SANDBOX);
    janet_vm.sandbox_flags |= flags;
}

void janet_sandbox_assert(uint32_t forbidden_flags) {
    if (forbidden_flags & janet_vm.sandbox_flags) {
        janet_panic("operation forbidden by sandbox");
    }
}

/* Clear all memory associated with the VM */
void janet_deinit(void) {
    janet_clear_memory();
    janet_symcache_deinit();
    janet_free(janet_vm.roots);
    janet_vm.roots = NULL;
    janet_vm.root_count = 0;
    janet_vm.root_capacity = 0;
    janet_vm.abstract_registry = NULL;
    janet_vm.core_env = NULL;
    janet_vm.top_dyns = NULL;
    janet_vm.user = NULL;
    janet_free(janet_vm.traversal_base);
    janet_vm.fiber = NULL;
    janet_vm.root_fiber = NULL;
    janet_free(janet_vm.registry);
    janet_vm.registry = NULL;
#ifdef JANET_EV
    janet_ev_deinit();
#endif
#ifdef JANET_NET
    janet_net_deinit();
#endif
}
