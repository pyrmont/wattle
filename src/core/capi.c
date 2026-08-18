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
#include "util.h"
#endif

#ifndef JANET_SINGLE_THREADED
#ifndef JANET_WINDOWS
#include <pthread.h>
#endif
#endif

#ifdef JANET_WINDOWS
#include <windows.h>
#endif

#ifdef JANET_USE_STDATOMIC
#include <stdatomic.h>
/* We don't need stdatomic on most compilers since we use compiler builtins for atomic operations.
 * Some (TCC), explicitly require using stdatomic.h and don't have any exposed builtins (that I know of).
 * For TCC and similar compilers, one would need -std=c11 or similar then to get access. */
#endif

JANET_NO_RETURN static void janet_top_level_signal(const char *msg) {
#ifdef JANET_TOP_LEVEL_SIGNAL
    JANET_TOP_LEVEL_SIGNAL(msg);
#else
    fputs(msg, stdout);
    if (!(janet_vm.sandbox_flags & JANET_SANDBOX_EXIT)) {
        /* Exit is not forbidden */
        exit(EXIT_FAILURE);
    }
    /* If not able to signal, then select good default behavior - for single threaded programs, we have no
     * choice but to exit. */
# ifdef JANET_SINGLE_THREADED
    exit(EXIT_FAILURE);
# elif defined(JANET_WINDOWS)
    ExitThread(-1);
# else
    /* Other threads will continue as usual */
    pthread_exit(NULL);
# endif
#endif
}

#ifndef JANET_ZIG_SIGNAL_CORE

JanetSignalPlan janet_signal_plan(JanetSignal sig, JanetSignal *out_sig) {
    *out_sig = sig;
    if (janet_vm.return_reg == NULL) return JANET_SIGNAL_PLAN_TOP_LEVEL;
    /* Should match logic in janet_call for coercing everything not ok to an error (no awaits, yields, etc.) */
    if (janet_vm.coerce_error && sig != JANET_SIGNAL_OK) {
#ifdef JANET_EV
        if (NULL != janet_vm.root_fiber && sig == JANET_SIGNAL_EVENT) {
            janet_vm.root_fiber->sched_id++;
        }
#endif
        *out_sig = JANET_SIGNAL_ERROR;
        if (sig != JANET_SIGNAL_ERROR) return JANET_SIGNAL_PLAN_COERCE;
    }
    return JANET_SIGNAL_PLAN_RAISE;
}

void janet_signal_commit(const Janet *message) {
    *janet_vm.return_reg = *message;
    if (NULL != janet_vm.fiber) {
        janet_vm.fiber->flags |= JANET_FIBER_DID_LONGJUMP;
    }
}

#endif /* JANET_ZIG_SIGNAL_CORE */

/* The decision is janet_signal_plan's and the payload is janet_signal_commit's;
 * what stays here is the formatting and the jump, and both stay for a reason.
 * Rendering "%v" runs an abstract type's tostring callback, which can panic, so
 * Zig may not call it. And a longjmp may not cross a Zig frame - this one is the
 * only jump that targets janet_vm.signal_buf, and Phase 10 removes it outright
 * along with the public try perimeter, so it is not worth moving first.
 *
 * The order is the original's. In particular the sched_id bump inside the plan
 * happens before the coercion message is built, so a panic raised by that
 * formatting finds the counter already advanced and the return register not yet
 * written, exactly as before. */
void janet_signalv(JanetSignal sig, Janet message) {
    JanetSignal out_sig = sig;
    JanetSignalPlan plan = janet_signal_plan(sig, &out_sig);
    if (plan == JANET_SIGNAL_PLAN_TOP_LEVEL) {
        const char *str = (const char *)janet_formatc("janet top level signal - %v\n", message);
        janet_top_level_signal(str);
    } else {
        if (plan == JANET_SIGNAL_PLAN_COERCE) {
            message = janet_wrap_string(janet_formatc("%v coerced from %s to error", message, janet_signal_names[sig]));
        }
        janet_signal_commit(&message);
#if defined(JANET_BSD) || defined(JANET_APPLE)
        _longjmp(*janet_vm.signal_buf, out_sig);
#else
        longjmp(*janet_vm.signal_buf, out_sig);
#endif
    }
}

void janet_panicv(Janet message) {
    janet_signalv(JANET_SIGNAL_ERROR, message);
}

void janet_panicf(const char *format, ...) {
    va_list args;
    const uint8_t *ret;
    JanetBuffer buffer;
    int32_t len = 0;
    while (format[len]) len++;
    janet_buffer_init(&buffer, len);
    va_start(args, format);
    janet_formatbv(&buffer, format, args);
    va_end(args);
    ret = janet_string(buffer.data, buffer.count);
    janet_buffer_deinit(&buffer);
    janet_panics(ret);
}

void janet_panic(const char *message) {
    janet_panicv(janet_cstringv(message));
}

void janet_panics(const uint8_t *message) {
    janet_panicv(janet_wrap_string(message));
}

void janet_panic_type(Janet x, int32_t n, int expected) {
    janet_panicf("bad slot #%d, expected %T, got %v", n, expected, x);
}

void janet_panic_abstract(Janet x, int32_t n, const JanetAbstractType *at) {
    janet_panicf("bad slot #%d, expected %s, got %v", n, at->name, x);
}

/* ------------------------------------------------------------------------
 * Argument extraction: the formatting half.
 *
 * Compiled in both configurations. Everything below turns a JanetArgFault
 * back into the exact message the C original raised; the kernels that decide
 * whether there is a fault at all are either the guarded C block further down
 * or src/zig/subsystems/args_core.zig.
 * --------------------------------------------------------------------- */

/* The only place the nouns appear. A getter reports JANET_ARG_EXPECT_S16 and
 * this decides it is spelled "16 bit signed integer", which is what makes the
 * two implementations word-identical without either of them formatting. */
static const char *janet_arg_expect_name(uint8_t expect) {
    switch ((JanetArgExpect) expect) {
        case JANET_ARG_EXPECT_NAT:
            return "non-negative 32 bit signed integer";
        case JANET_ARG_EXPECT_SIZE:
            return "size";
        case JANET_ARG_EXPECT_S32:
            return "32 bit signed integer";
        case JANET_ARG_EXPECT_U32:
            return "32 bit unsigned integer";
        case JANET_ARG_EXPECT_S16:
            return "16 bit signed integer";
        case JANET_ARG_EXPECT_U16:
            return "16 bit unsigned integer";
        case JANET_ARG_EXPECT_S8:
            return "8 bit signed integer";
        case JANET_ARG_EXPECT_U8:
            return "8 bit unsigned integer";
        case JANET_ARG_EXPECT_FLOAT:
            return "float number";
        case JANET_ARG_EXPECT_S64:
            return "64 bit signed integer";
        default:
            return "64 bit unsigned integer";
    }
}

/* `argv` may be NULL for the kinds that do not name a slot - the arity kinds,
 * the range kinds, the flag kind and the embedded-zero kind all render without
 * touching the argument. */
void janet_arg_raise(const Janet *argv, const JanetArgFault *fault) {
    switch ((JanetArgFaultKind) fault->kind) {
        case JANET_ARG_TYPE:
            janet_panic_type(argv[fault->slot], fault->slot, fault->typeflags);
        case JANET_ARG_ABSTRACT:
            janet_panic_abstract(argv[fault->slot], fault->slot, fault->at);
        case JANET_ARG_EXPECT:
            janet_panicf("bad slot #%d, expected %s, got %v", fault->slot,
                         janet_arg_expect_name(fault->expect), argv[fault->slot]);
        /* The three int64_t arguments to "%d" below are the C original's, and
         * "%d" reads an int32_t. That is undefined and is recorded in FOUND.md;
         * it is reproduced here rather than repaired, so that both
         * implementations render the same line on the targets where it works. */
        case JANET_ARG_RANGE_INCLUSIVE:
            janet_panicf("%s index %d out of range [%d,%d]", fault->which,
                         fault->raw, fault->lo, fault->hi);
        case JANET_ARG_RANGE_EXCLUSIVE:
            janet_panicf("%s index %d out of range [%d,%d)", fault->which,
                         fault->raw, fault->lo, fault->hi);
        case JANET_ARG_FLAG:
            janet_panicf("unexpected flag %c, expected one of \"%s\"",
                         (char) fault->raw, fault->flags);
        case JANET_ARG_ZEROS:
            janet_panic("bytes contain embedded 0s");
        case JANET_ARG_ARITY_FIX:
            janet_panicf("arity mismatch, expected %d, got %d", fault->bound, fault->arity);
        case JANET_ARG_ARITY_MIN:
            janet_panicf("arity mismatch, expected at least %d, got %d", fault->bound, fault->arity);
        case JANET_ARG_ARITY_MAX:
            janet_panicf("arity mismatch, expected at most %d, got %d", fault->bound, fault->arity);
        default:
            janet_panic("argument fault with no kind");
    }
}

/* ------------------------------------------------------------------------
 * Argument extraction: the deciding half.
 *
 * Replaced wholesale by src/zig/subsystems/args_core.zig under
 * -Dargs-core=zig. Nothing here allocates, constructs a Janet value, or calls
 * anything that can raise - which is why janet_arg_bytes reports the abstract
 * case instead of running the type's `bytes` callback, and why the two buffer
 * shapes janet_arg_cbytes distinguishes are carried out by its caller.
 * --------------------------------------------------------------------- */

#ifndef JANET_ZIG_ARGS_CORE

int janet_arg_checktype(const Janet *argv, int32_t n, int32_t type,
                        int32_t typeflags, JanetArgFault *fault) {
    if (janet_checktype(argv[n], (JanetType) type)) return 1;
    fault->kind = JANET_ARG_TYPE;
    fault->slot = n;
    fault->typeflags = typeflags;
    return 0;
}

int janet_arg_isdefault(const Janet *argv, int32_t argc, int32_t n) {
    return n >= argc || janet_checktype(argv[n], JANET_NIL);
}

#define DEFINE_ARG_NUMBER(name, check, EXPECT, type) \
int janet_arg_##name(const Janet *argv, int32_t n, type *out, JanetArgFault *fault) { \
    Janet x = argv[n]; \
    if (!check(x)) { \
        fault->kind = JANET_ARG_EXPECT; \
        fault->expect = JANET_ARG_EXPECT_##EXPECT; \
        fault->slot = n; \
        return 0; \
    } \
    *out = (type) janet_unwrap_number(x); \
    return 1; \
}

DEFINE_ARG_NUMBER(uinteger, janet_checkuint, U32, uint32_t)
DEFINE_ARG_NUMBER(uinteger16, janet_checkuint16, U16, uint16_t)
DEFINE_ARG_NUMBER(float, janet_checkfloat, FLOAT, float)
DEFINE_ARG_NUMBER(size, janet_checksize, SIZE, size_t)

/* janet_getinteger unwraps rather than converting, which differs from every
 * other width: janet_unwrap_integer is a distinct operation under a tagged
 * representation, where the integer is not stored as a double. */
int janet_arg_integer(const Janet *argv, int32_t n, int32_t *out, JanetArgFault *fault) {
    Janet x = argv[n];
    if (!janet_checkint(x)) {
        fault->kind = JANET_ARG_EXPECT;
        fault->expect = JANET_ARG_EXPECT_S32;
        fault->slot = n;
        return 0;
    }
    *out = janet_unwrap_integer(x);
    return 1;
}

int janet_arg_integer16(const Janet *argv, int32_t n, int16_t *out, JanetArgFault *fault) {
    Janet x = argv[n];
    if (!janet_checkint16(x)) {
        fault->kind = JANET_ARG_EXPECT;
        fault->expect = JANET_ARG_EXPECT_S16;
        fault->slot = n;
        return 0;
    }
    *out = (int16_t) janet_unwrap_number(x);
    return 1;
}

/* The two 8-bit getters convert through 16 bits in the C original before the
 * return narrows them again. janet_checkint8 has already established the
 * range, so the intermediate cast cannot change the value; it is kept because
 * a port that quietly tidied it would be changing the code under test. */
int janet_arg_integer8(const Janet *argv, int32_t n, int8_t *out, JanetArgFault *fault) {
    Janet x = argv[n];
    if (!janet_checkint8(x)) {
        fault->kind = JANET_ARG_EXPECT;
        fault->expect = JANET_ARG_EXPECT_S8;
        fault->slot = n;
        return 0;
    }
    *out = (int8_t)(int16_t) janet_unwrap_number(x);
    return 1;
}

int janet_arg_uinteger8(const Janet *argv, int32_t n, uint8_t *out, JanetArgFault *fault) {
    Janet x = argv[n];
    if (!janet_checkuint8(x)) {
        fault->kind = JANET_ARG_EXPECT;
        fault->expect = JANET_ARG_EXPECT_U8;
        fault->slot = n;
        return 0;
    }
    *out = (uint8_t)(uint16_t) janet_unwrap_number(x);
    return 1;
}

int janet_arg_integer64(const Janet *argv, int32_t n, int64_t *out, JanetArgFault *fault) {
    Janet x = argv[n];
    if (!janet_checkint64(x)) {
        fault->kind = JANET_ARG_EXPECT;
        fault->expect = JANET_ARG_EXPECT_S64;
        fault->slot = n;
        return 0;
    }
    *out = (int64_t) janet_unwrap_number(x);
    return 1;
}

int janet_arg_uinteger64(const Janet *argv, int32_t n, uint64_t *out, JanetArgFault *fault) {
    Janet x = argv[n];
    if (!janet_checkuint64(x)) {
        fault->kind = JANET_ARG_EXPECT;
        fault->expect = JANET_ARG_EXPECT_U64;
        fault->slot = n;
        return 0;
    }
    *out = (uint64_t) janet_unwrap_number(x);
    return 1;
}

int janet_arg_nat(const Janet *argv, int32_t n, int32_t *out, JanetArgFault *fault) {
    Janet x = argv[n];
    if (janet_checkint(x)) {
        int32_t ret = janet_unwrap_integer(x);
        if (ret >= 0) {
            *out = ret;
            return 1;
        }
    }
    fault->kind = JANET_ARG_EXPECT;
    fault->expect = JANET_ARG_EXPECT_NAT;
    fault->slot = n;
    return 0;
}

int janet_arg_abstract(const Janet *argv, int32_t n, const JanetAbstractType *at,
                       void **out, JanetArgFault *fault) {
    Janet x = argv[n];
    if (janet_checktype(x, JANET_ABSTRACT)) {
        void *abstractx = janet_unwrap_abstract(x);
        if (janet_abstract_type(abstractx) == at) {
            *out = abstractx;
            return 1;
        }
    }
    fault->kind = JANET_ARG_ABSTRACT;
    fault->slot = n;
    fault->at = at;
    return 0;
}

int janet_arg_indexed(const Janet *argv, int32_t n, JanetView *out, JanetArgFault *fault) {
    Janet x = argv[n];
    if (janet_checktype(x, JANET_ARRAY)) {
        out->items = janet_unwrap_array(x)->data;
        out->len = janet_unwrap_array(x)->count;
        return 1;
    } else if (janet_checktype(x, JANET_TUPLE)) {
        out->items = janet_unwrap_tuple(x);
        out->len = janet_tuple_length(janet_unwrap_tuple(x));
        return 1;
    }
    fault->kind = JANET_ARG_TYPE;
    fault->slot = n;
    fault->typeflags = JANET_TFLAG_INDEXED;
    return 0;
}

int janet_arg_dictionary(const Janet *argv, int32_t n, JanetDictView *out, JanetArgFault *fault) {
    Janet x = argv[n];
    if (janet_checktype(x, JANET_TABLE)) {
        out->kvs = janet_unwrap_table(x)->data;
        out->cap = janet_unwrap_table(x)->capacity;
        out->len = janet_unwrap_table(x)->count;
        return 1;
    } else if (janet_checktype(x, JANET_STRUCT)) {
        out->kvs = janet_unwrap_struct(x);
        out->cap = janet_struct_capacity(janet_unwrap_struct(x));
        out->len = janet_struct_length(janet_unwrap_struct(x));
        return 1;
    }
    fault->kind = JANET_ARG_TYPE;
    fault->slot = n;
    fault->typeflags = JANET_TFLAG_DICTIONARY;
    return 0;
}

/* The abstract case is reported rather than taken. Running `bytes` here would
 * put third-party code below a frame that must not be jumped through once this
 * function is Zig. */
JanetArgBytes janet_arg_bytes(Janet x, int32_t n, JanetByteView *out, JanetArgFault *fault) {
    JanetType t = janet_type(x);
    if (t == JANET_STRING || t == JANET_SYMBOL || t == JANET_KEYWORD) {
        out->bytes = janet_unwrap_string(x);
        out->len = janet_string_length(janet_unwrap_string(x));
        return JANET_ARG_BYTES_STRING;
    } else if (t == JANET_BUFFER) {
        out->bytes = janet_unwrap_buffer(x)->data;
        out->len = janet_unwrap_buffer(x)->count;
        return JANET_ARG_BYTES_BUFFER;
    } else if (t == JANET_ABSTRACT) {
        void *abst = janet_unwrap_abstract(x);
        if (NULL != janet_abstract_type(abst)->bytes) {
            return JANET_ARG_BYTES_ABSTRACT;
        }
    }
    fault->kind = JANET_ARG_TYPE;
    fault->slot = n;
    fault->typeflags = JANET_TFLAG_BYTES;
    return JANET_ARG_BYTES_FAULT;
}

JanetArgCBytes janet_arg_cbytes(const Janet *argv, int32_t n, JanetArgFault *fault) {
    Janet x = argv[n];
    if (janet_checktype(x, JANET_BUFFER)) {
        JanetBuffer *b = janet_unwrap_buffer(x);
        if ((b->gc.flags & JANET_BUFFER_FLAG_NO_REALLOC) && b->count == b->capacity) {
            return JANET_ARG_CBYTES_COPY;
        }
        return JANET_ARG_CBYTES_TERMINATE;
    }
    (void) fault;
    return JANET_ARG_CBYTES_VIEW;
}

int janet_arg_zeros(const char *bytes, int32_t len, JanetArgFault *fault) {
    if (strlen(bytes) == (size_t) len) return 1;
    fault->kind = JANET_ARG_ZEROS;
    return 0;
}

int janet_arg_halfrange(const Janet *argv, int32_t n, int32_t length, const char *which,
                        int32_t *out, JanetArgFault *fault) {
    int32_t raw;
    if (!janet_arg_integer(argv, n, &raw, fault)) return 0;
    int32_t not_raw = raw;
    if (not_raw < 0) not_raw += length + 1;
    if (not_raw < 0 || not_raw > length) {
        fault->kind = JANET_ARG_RANGE_INCLUSIVE;
        fault->which = which;
        fault->raw = (int64_t) raw;
        fault->lo = -(int64_t) length - 1;
        fault->hi = (int64_t) length;
        return 0;
    }
    *out = not_raw;
    return 1;
}

int janet_arg_argindex(const Janet *argv, int32_t n, int32_t length, const char *which,
                       int32_t *out, JanetArgFault *fault) {
    int32_t raw;
    if (!janet_arg_integer(argv, n, &raw, fault)) return 0;
    int32_t not_raw = raw;
    if (not_raw < 0) not_raw += length;
    if (not_raw < 0 || not_raw > length) {
        fault->kind = JANET_ARG_RANGE_EXCLUSIVE;
        fault->which = which;
        fault->raw = (int64_t) raw;
        fault->lo = -(int64_t) length;
        fault->hi = (int64_t) length;
        return 0;
    }
    *out = not_raw;
    return 1;
}

/* The 64-flag ceiling is the C original's and is a silent truncation rather
 * than an error: a `flags` string longer than 64 characters has its tail
 * ignored, so a keyword naming one of those characters reports it as
 * unexpected. Preserved, not repaired. */
int janet_arg_flags(const uint8_t *keyw, int32_t klen, const char *flags,
                    uint64_t *out, JanetArgFault *fault) {
    uint64_t ret = 0;
    int32_t flen = (int32_t) strlen(flags);
    if (flen > 64) {
        flen = 64;
    }
    for (int32_t j = 0; j < klen; j++) {
        int32_t i;
        for (i = 0; i < flen; i++) {
            if (((uint8_t) flags[i]) == keyw[j]) {
                ret |= 1ULL << i;
                break;
            }
        }
        if (i == flen) {
            fault->kind = JANET_ARG_FLAG;
            fault->raw = (int64_t) keyw[j];
            fault->flags = flags;
            return 0;
        }
    }
    *out = ret;
    return 1;
}

int janet_arg_fixarity(int32_t arity, int32_t fix, JanetArgFault *fault) {
    if (arity == fix) return 1;
    fault->kind = JANET_ARG_ARITY_FIX;
    fault->arity = arity;
    fault->bound = fix;
    return 0;
}

int janet_arg_arity(int32_t arity, int32_t min, int32_t max, JanetArgFault *fault) {
    if (min >= 0 && arity < min) {
        fault->kind = JANET_ARG_ARITY_MIN;
        fault->arity = arity;
        fault->bound = min;
        return 0;
    }
    if (max >= 0 && arity > max) {
        fault->kind = JANET_ARG_ARITY_MAX;
        fault->arity = arity;
        fault->bound = max;
        return 0;
    }
    return 1;
}

int janet_arg_strlike(int32_t type, Janet x, const char *cstring) {
    if (janet_type(x) != (JanetType) type) return 0;
    return !janet_cstrcmp(janet_unwrap_string(x), cstring);
}

int janet_arg_method(const uint8_t *method, const JanetMethod *methods, const JanetMethod **out) {
    while (methods->name) {
        if (!janet_cstrcmp(method, methods->name)) {
            *out = methods;
            return 1;
        }
        methods++;
    }
    return 0;
}

/* Returns the entry whose name the caller should wrap as a keyword, or the
 * terminating entry - the one with a null name - when the walk runs off the
 * end. Constructing the keyword is the caller's job because it allocates. */
const JanetMethod *janet_arg_nextmethod(const JanetMethod *methods, Janet key) {
    if (!janet_checktype(key, JANET_NIL)) {
        while (methods->name) {
            if (janet_keyeq(key, methods->name)) {
                methods++;
                break;
            }
            methods++;
        }
    }
    return methods;
}

#undef DEFINE_ARG_NUMBER

#endif /* JANET_ZIG_ARGS_CORE */

/* ------------------------------------------------------------------------
 * Argument extraction: the exported surface.
 *
 * Each of these is a kernel call and, on failure, a janet_arg_raise. Compiled
 * in both configurations, because the raise cannot be on the Zig side.
 * --------------------------------------------------------------------- */

void janet_fixarity(int32_t arity, int32_t fix) {
    JanetArgFault fault;
    if (!janet_arg_fixarity(arity, fix, &fault)) janet_arg_raise(NULL, &fault);
}

void janet_arity(int32_t arity, int32_t min, int32_t max) {
    JanetArgFault fault;
    if (!janet_arg_arity(arity, min, max, &fault)) janet_arg_raise(NULL, &fault);
}

#define DEFINE_GETTER(name, NAME, type) \
type janet_get##name(const Janet *argv, int32_t n) { \
    JanetArgFault fault; \
    if (!janet_arg_checktype(argv, n, JANET_##NAME, JANET_TFLAG_##NAME, &fault)) { \
        janet_arg_raise(argv, &fault); \
    } \
    return janet_unwrap_##name(argv[n]); \
}

#define DEFINE_OPT(name, NAME, type) \
type janet_opt##name(const Janet *argv, int32_t argc, int32_t n, type dflt) { \
    if (janet_arg_isdefault(argv, argc, n)) return dflt; \
    return janet_get##name(argv, n); \
}

#define DEFINE_OPTLEN(name, NAME, type) \
type janet_opt##name(const Janet *argv, int32_t argc, int32_t n, int32_t dflt_len) { \
    if (janet_arg_isdefault(argv, argc, n)) return janet_##name(dflt_len); \
    return janet_get##name(argv, n); \
}

#define DEFINE_ARG_GETTER(name, type) \
type janet_get##name(const Janet *argv, int32_t n) { \
    type out; \
    JanetArgFault fault; \
    if (!janet_arg_##name(argv, n, &out, &fault)) janet_arg_raise(argv, &fault); \
    return out; \
}

int janet_getmethod(const uint8_t *method, const JanetMethod *methods, Janet *out) {
    const JanetMethod *found;
    if (!janet_arg_method(method, methods, &found)) return 0;
    *out = janet_wrap_cfunction(found->cfun);
    return 1;
}

Janet janet_nextmethod(const JanetMethod *methods, Janet key) {
    const JanetMethod *found = janet_arg_nextmethod(methods, key);
    if (found->name) {
        return janet_ckeywordv(found->name);
    } else {
        return janet_wrap_nil();
    }
}

DEFINE_GETTER(number, NUMBER, double)
DEFINE_GETTER(array, ARRAY, JanetArray *)
DEFINE_GETTER(tuple, TUPLE, const Janet *)
DEFINE_GETTER(table, TABLE, JanetTable *)
DEFINE_GETTER(struct, STRUCT, const JanetKV *)
DEFINE_GETTER(string, STRING, const uint8_t *)
DEFINE_GETTER(keyword, KEYWORD, const uint8_t *)
DEFINE_GETTER(symbol, SYMBOL, const uint8_t *)
DEFINE_GETTER(buffer, BUFFER, JanetBuffer *)
DEFINE_GETTER(fiber, FIBER, JanetFiber *)
DEFINE_GETTER(function, FUNCTION, JanetFunction *)
DEFINE_GETTER(cfunction, CFUNCTION, JanetCFunction)
DEFINE_GETTER(boolean, BOOLEAN, int)
DEFINE_GETTER(pointer, POINTER, void *)

DEFINE_OPT(number, NUMBER, double)
DEFINE_OPT(tuple, TUPLE, const Janet *)
DEFINE_OPT(struct, STRUCT, const JanetKV *)
DEFINE_OPT(string, STRING, const uint8_t *)
DEFINE_OPT(keyword, KEYWORD, const uint8_t *)
DEFINE_OPT(symbol, SYMBOL, const uint8_t *)
DEFINE_OPT(fiber, FIBER, JanetFiber *)
DEFINE_OPT(function, FUNCTION, JanetFunction *)
DEFINE_OPT(cfunction, CFUNCTION, JanetCFunction)
DEFINE_OPT(boolean, BOOLEAN, int)
DEFINE_OPT(pointer, POINTER, void *)

DEFINE_OPTLEN(buffer, BUFFER, JanetBuffer *)
DEFINE_OPTLEN(table, TABLE, JanetTable *)
DEFINE_OPTLEN(array, ARRAY, JanetArray *)

const char *janet_optcstring(const Janet *argv, int32_t argc, int32_t n, const char *dflt) {
    if (janet_arg_isdefault(argv, argc, n)) return dflt;
    return janet_getcstring(argv, n);
}

#undef DEFINE_GETTER
#undef DEFINE_OPT
#undef DEFINE_OPTLEN

const char *janet_getcstring(const Janet *argv, int32_t n) {
    JanetArgFault fault;
    if (!janet_arg_checktype(argv, n, JANET_STRING, JANET_TFLAG_STRING, &fault)) {
        janet_arg_raise(argv, &fault);
    }
    return janet_getcbytes(argv, n);
}

/* The two buffer shapes are carried out here rather than in the kernel: one
 * pushes a byte and one calls janet_smalloc, and both can panic. */
const char *janet_getcbytes(const Janet *argv, int32_t n) {
    JanetArgFault fault;
    const char *cstr;
    int32_t len;
    switch (janet_arg_cbytes(argv, n, &fault)) {
        case JANET_ARG_CBYTES_COPY: {
            JanetBuffer *b = janet_unwrap_buffer(argv[n]);
            /* Make a copy with janet_smalloc in the rare case we have a buffer that
             * cannot be realloced and pushing a 0 byte would panic. */
            char *new_string = janet_smalloc(b->count + 1);
            memcpy(new_string, b->data, b->count);
            new_string[b->count] = 0;
            cstr = new_string;
            len = b->count;
            break;
        }
        case JANET_ARG_CBYTES_TERMINATE: {
            JanetBuffer *b = janet_unwrap_buffer(argv[n]);
            /* Ensure trailing 0 */
            janet_buffer_push_u8(b, 0);
            b->count--;
            cstr = (const char *) b->data;
            len = b->count;
            break;
        }
        default: {
            JanetByteView view = janet_getbytes(argv, n);
            cstr = (const char *) view.bytes;
            len = view.len;
            break;
        }
    }
    if (!janet_arg_zeros(cstr, len, &fault)) janet_arg_raise(argv, &fault);
    return cstr;
}

const char *janet_optcbytes(const Janet *argv, int32_t argc, int32_t n, const char *dflt) {
    if (janet_arg_isdefault(argv, argc, n)) return dflt;
    return janet_getcbytes(argv, n);
}

DEFINE_ARG_GETTER(nat, int32_t)
DEFINE_ARG_GETTER(integer, int32_t)
DEFINE_ARG_GETTER(uinteger, uint32_t)
DEFINE_ARG_GETTER(integer16, int16_t)
DEFINE_ARG_GETTER(uinteger16, uint16_t)
DEFINE_ARG_GETTER(integer8, int8_t)
DEFINE_ARG_GETTER(uinteger8, uint8_t)
DEFINE_ARG_GETTER(float, float)
DEFINE_ARG_GETTER(size, size_t)

#undef DEFINE_ARG_GETTER

#ifdef JANET_INT_TYPES
/* With integer types enabled these accept an int/s64 or int/u64 abstract as
 * well as a number, and janet_unwrap_s64 raises its own message. There is no
 * fault for a kernel to report, so the whole body stays here. */
int64_t janet_getinteger64(const Janet *argv, int32_t n) {
    return janet_unwrap_s64(argv[n]);
}

uint64_t janet_getuinteger64(const Janet *argv, int32_t n) {
    return janet_unwrap_u64(argv[n]);
}
#else
int64_t janet_getinteger64(const Janet *argv, int32_t n) {
    int64_t out;
    JanetArgFault fault;
    if (!janet_arg_integer64(argv, n, &out, &fault)) janet_arg_raise(argv, &fault);
    return out;
}

uint64_t janet_getuinteger64(const Janet *argv, int32_t n) {
    uint64_t out;
    JanetArgFault fault;
    if (!janet_arg_uinteger64(argv, n, &out, &fault)) janet_arg_raise(argv, &fault);
    return out;
}
#endif

JanetAbstract janet_checkabstract(Janet x, const JanetAbstractType *at) {
    void *out;
    JanetArgFault fault;
    if (!janet_arg_abstract(&x, 0, at, &out, &fault)) return NULL;
    return out;
}

int janet_keyeq(Janet x, const char *cstring) {
    return janet_arg_strlike(JANET_KEYWORD, x, cstring);
}

int janet_streq(Janet x, const char *cstring) {
    return janet_arg_strlike(JANET_STRING, x, cstring);
}

int janet_symeq(Janet x, const char *cstring) {
    return janet_arg_strlike(JANET_SYMBOL, x, cstring);
}

int32_t janet_gethalfrange(const Janet *argv, int32_t n, int32_t length, const char *which) {
    int32_t out;
    JanetArgFault fault;
    if (!janet_arg_halfrange(argv, n, length, which, &out, &fault)) janet_arg_raise(argv, &fault);
    return out;
}

int32_t janet_getstartrange(const Janet *argv, int32_t argc, int32_t n, int32_t length) {
    if (janet_arg_isdefault(argv, argc, n)) return 0;
    return janet_gethalfrange(argv, n, length, "start");
}

int32_t janet_getendrange(const Janet *argv, int32_t argc, int32_t n, int32_t length) {
    if (janet_arg_isdefault(argv, argc, n)) return length;
    return janet_gethalfrange(argv, n, length, "end");
}

int32_t janet_getargindex(const Janet *argv, int32_t n, int32_t length, const char *which) {
    int32_t out;
    JanetArgFault fault;
    if (!janet_arg_argindex(argv, n, length, which, &out, &fault)) janet_arg_raise(argv, &fault);
    return out;
}

JanetView janet_getindexed(const Janet *argv, int32_t n) {
    JanetView view;
    JanetArgFault fault;
    if (!janet_arg_indexed(argv, n, &view, &fault)) janet_arg_raise(argv, &fault);
    return view;
}

/* The abstract branch runs the type's `bytes` callback, which is third-party
 * code and may panic, so it runs here and not in the kernel. */
JanetByteView janet_getbytes(const Janet *argv, int32_t n) {
    JanetByteView view;
    JanetArgFault fault;
    switch (janet_arg_bytes(argv[n], n, &view, &fault)) {
        case JANET_ARG_BYTES_STRING:
        case JANET_ARG_BYTES_BUFFER:
            return view;
        case JANET_ARG_BYTES_ABSTRACT: {
            void *abst = janet_unwrap_abstract(argv[n]);
            return janet_abstract_type(abst)->bytes(abst, janet_abstract_size(abst));
        }
        default:
            janet_arg_raise(argv, &fault);
    }
}

JanetDictView janet_getdictionary(const Janet *argv, int32_t n) {
    JanetDictView view;
    JanetArgFault fault;
    if (!janet_arg_dictionary(argv, n, &view, &fault)) janet_arg_raise(argv, &fault);
    return view;
}

void *janet_getabstract(const Janet *argv, int32_t n, const JanetAbstractType *at) {
    void *out;
    JanetArgFault fault;
    if (!janet_arg_abstract(argv, n, at, &out, &fault)) janet_arg_raise(argv, &fault);
    return out;
}

JanetRange janet_getslice(int32_t argc, const Janet *argv) {
    janet_arity(argc, 1, 3);
    JanetRange range;
    int32_t length = janet_length(argv[0]);
    range.start = janet_getstartrange(argv, argc, 1, length);
    range.end = janet_getendrange(argv, argc, 2, length);
    if (range.end < range.start)
        range.end = range.start;
    return range;
}

Janet janet_dyn(const char *name) {
    if (!janet_vm.fiber) {
        if (!janet_vm.top_dyns) return janet_wrap_nil();
        return janet_table_get(janet_vm.top_dyns, janet_ckeywordv(name));
    }
    if (janet_vm.fiber->env) {
        return janet_table_get_keyword(janet_vm.fiber->env, name);
    } else {
        return janet_wrap_nil();
    }
}

void janet_setdyn(const char *name, Janet value) {
    if (!janet_vm.fiber) {
        if (!janet_vm.top_dyns) janet_vm.top_dyns = janet_table(10);
        janet_table_put(janet_vm.top_dyns, janet_ckeywordv(name), value);
    } else {
        if (!janet_vm.fiber->env) {
            janet_vm.fiber->env = janet_table(1);
        }
        janet_table_put(janet_vm.fiber->env, janet_ckeywordv(name), value);
    }
}

/* Create a function that when called, returns X. Trivial in Janet, a pain in C. */
JanetFunction *janet_thunk_delay(Janet x) {
    static const uint32_t bytecode[] = {
        JOP_LOAD_CONSTANT,
        JOP_RETURN
    };
    JanetFuncDef *def = janet_funcdef_alloc();
    def->arity = 0;
    def->min_arity = 0;
    def->max_arity = INT32_MAX;
    def->flags = JANET_FUNCDEF_FLAG_VARARG;
    def->slotcount = 1;
    def->bytecode = janet_malloc(sizeof(bytecode));
    def->bytecode_length = (int32_t)(sizeof(bytecode) / sizeof(uint32_t));
    def->constants = janet_malloc(sizeof(Janet));
    def->constants_length = 1;
    def->name = NULL;
    if (!def->bytecode || !def->constants) {
        JANET_OUT_OF_MEMORY;
    }
    def->constants[0] = x;
    memcpy(def->bytecode, bytecode, sizeof(bytecode));
    janet_def_addflags(def);
    /* janet_verify(def); */
    return janet_thunk(def);
}

uint64_t janet_getflags(const Janet *argv, int32_t n, const char *flags) {
    const uint8_t *keyw = janet_getkeyword(argv, n);
    uint64_t out;
    JanetArgFault fault;
    if (!janet_arg_flags(keyw, janet_string_length(keyw), flags, &out, &fault)) {
        janet_arg_raise(argv, &fault);
    }
    return out;
}

#define DEFINE_ARG_OPT(name, type) \
type janet_opt##name(const Janet *argv, int32_t argc, int32_t n, type dflt) { \
    if (janet_arg_isdefault(argv, argc, n)) return dflt; \
    return janet_get##name(argv, n); \
}

DEFINE_ARG_OPT(nat, int32_t)
DEFINE_ARG_OPT(integer, int32_t)
DEFINE_ARG_OPT(integer64, int64_t)
DEFINE_ARG_OPT(size, size_t)
DEFINE_ARG_OPT(uinteger, uint32_t)
DEFINE_ARG_OPT(uinteger64, uint64_t)

#undef DEFINE_ARG_OPT

void *janet_optabstract(const Janet *argv, int32_t argc, int32_t n, const JanetAbstractType *at, void *dflt) {
    if (janet_arg_isdefault(argv, argc, n)) return dflt;
    return janet_getabstract(argv, n, at);
}

/* Atomic refcounts */

JanetAtomicInt janet_atomic_inc(JanetAtomicInt volatile *x) {
#ifdef _MSC_VER
    return _InterlockedIncrement(x);
#elif defined(JANET_USE_STDATOMIC)
    return atomic_fetch_add_explicit(x, 1, memory_order_relaxed) + 1;
#elif defined(JANET_PLAN9)
    return aincl((void *)x, 1);
#else
    return __atomic_add_fetch(x, 1, __ATOMIC_RELAXED);
#endif
}

JanetAtomicInt janet_atomic_dec(JanetAtomicInt volatile *x) {
#ifdef _MSC_VER
    return _InterlockedDecrement(x);
#elif defined(JANET_USE_STDATOMIC)
    return atomic_fetch_add_explicit(x, -1, memory_order_acq_rel) - 1;
#elif defined(JANET_PLAN9)
    return aincl((void *)x, -1);
#else
    return __atomic_add_fetch(x, -1, __ATOMIC_ACQ_REL);
#endif
}

JanetAtomicInt janet_atomic_load(JanetAtomicInt volatile *x) {
#ifdef _MSC_VER
    return _InterlockedOr(x, 0);
#elif defined(JANET_PLAN9)
    return agetl((void *)x);
#elif defined(JANET_USE_STDATOMIC)
    return atomic_load_explicit(x, memory_order_acquire);
#else
    return __atomic_load_n(x, __ATOMIC_ACQUIRE);
#endif
}

JanetAtomicInt janet_atomic_load_relaxed(JanetAtomicInt volatile *x) {
#ifdef _MSC_VER
    return _InterlockedOr(x, 0);
#elif defined(JANET_PLAN9)
    return agetl((void *)x);
#elif defined(JANET_USE_STDATOMIC)
    return atomic_load_explicit(x, memory_order_relaxed);
#else
    return __atomic_load_n(x, __ATOMIC_RELAXED);
#endif
}

/* Some definitions for function-like macros */

JANET_API JanetStructHead *(janet_struct_head)(JanetStruct st) {
    return janet_struct_head(st);
}

JANET_API JanetAbstractHead *(janet_abstract_head)(const void *abstract) {
    return janet_abstract_head(abstract);
}

JANET_API JanetStringHead *(janet_string_head)(JanetString s) {
    return janet_string_head(s);
}

JANET_API JanetTupleHead *(janet_tuple_head)(JanetTuple tuple) {
    return janet_tuple_head(tuple);
}
