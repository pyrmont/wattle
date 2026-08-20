#ifndef JANET_TEST_SUPPORT_H
#define JANET_TEST_SUPPORT_H

#include <janet.h>

/* What a C contract needs now that a cfunction is not a C function.
 *
 * Phase 10 Part 17g gave a cfunction the type `raise.CFunction`: it returns
 * `error{JanetSignal}!Janet` with Zig's own calling convention, so C can
 * neither call one nor be one. `test/support.zig` implements these three and
 * is linked into the contract binary alone; its header comment has the whole
 * argument. */

/* Invoke a cfunction. A raise arrives as the jump `janet_try` catches. */
Janet janet_contract_call_cfunction(JanetCFunction fun, int32_t argc, Janet *argv);

/* Adapt a contract's own C cfunction into one the runtime can call. The same
 * input always yields the same pointer, so identity assertions still work:
 * `janet_unwrap_cfunction(x) == janet_contract_cfunction(probe)`. */
JanetCFunction janet_contract_cfunction(Janet (*fun)(int32_t argc, Janet *argv));

/* The same, over every row of a registration or method table, in place. Both
 * stop at the terminating null name. */
void janet_contract_adapt_regs(JanetReg *table);
void janet_contract_adapt_methods(JanetMethod *table);

/* Adapt a contract's own C abstract type into one the runtime can dispatch.
 * Idempotent by identity, so address comparisons still hold. */
const JanetAbstractType *janet_contract_abstract_type(const JanetAbstractType *from);
#define CONTRACT_AT(x) janet_contract_abstract_type(&(x))

/* Run a C body under a protected scope and report the signal it raised. Was
 * janet_zig_ev_protect in src/core/ev.c, which went with the second setjmp. */
JanetSignal janet_contract_protect(void (*body)(void *), void *ctx, Janet *payload);

/* Asserting that something raised, without a jump. See test/support.zig. */
void janet_contract_arm(void);
int janet_contract_raised(void);
JanetSignal janet_contract_signal(void);
Janet janet_contract_payload(void);

/* Whether a raise is outstanding, without consuming it. A C callback the
 * runtime invokes uses this to stop early and leave the report standing. */
int janet_contract_raising(void);

/* Invoking an abstract type's callback from C. The callbacks are raising Zig
 * functions since the hinge, so a contract cannot call one directly. */
void janet_contract_at_tostring(const JanetAbstractType *at, void *p, JanetBuffer *buffer);
Janet janet_contract_at_next(const JanetAbstractType *at, void *p, Janet key);
int janet_contract_at_get(const JanetAbstractType *at, void *p, Janet key, Janet *out);
/* `gc` and `gcmark` need no shim: the hinge typed them non-raising, so they
 * keep the C signature and a contract calls `at->gc(...)` directly. */

/* Invoking a compiler special's `compile` from C. Declared behind the same
 * guard the contract uses, because `JanetSpecial` and `JanetFopts` live in
 * `compile.h` rather than in `janet.h`. */
#ifdef JANET_COMPILE_H
JanetSlot janet_contract_special_compile(const JanetSpecial *s, JanetFopts options,
                                         int32_t argc, const Janet *argv);
#endif

#endif
