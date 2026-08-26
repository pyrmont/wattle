# The Zig runtime

Notes on Janet's Zig implementation, and the narrative of the C-to-Zig port
that produced it.

**Read this part first, and read the rest as history.** Everything from
"Raising out of `run_vm`" downwards is a record of the migration, written
increment by increment as each one landed. It stops at Phase 12 increment 5g by
decision: from 2026-08-28 an increment's record goes in `port/phase_*.md`, and
anything meant to outlive the port goes in `DESIGN.md`. So those sections do
not describe the tree as it stands, and 97 of this file's 101 sections cite a
phase number, a rule number, or a `port/` document — none of which survives the
migration. **The file is owed a rewrite for a reader who was not here.**

What follows immediately is the part that is not history.

## The rules that hold

- **There is no C implementation to select, and no Janet C left to call.**
  `src/` is 88 `.zig` files and four hand-written headers: `janet_features.h`,
  and the host translations `os/abi.h`, `net/abi.h` and `filewatch/abi.h`. Any
  C a Zig file reaches is libc's, through `@cImport` — Phase 10's decision 4 is
  that "no C in the tree" and "no libc" are different claims and only the first
  is a goal. Comparison against the C runtime is `port/bench-upstream.sh`,
  which builds upstream `master` in a worktree with a matching toolchain.
- **Nothing jumps.** No configuration compiles a `setjmp`, `longjmp` or
  `jmp_buf`. A raise records its signal in `janet_vm.pending_signal` and
  returns `error.JanetSignal`; a protected scope is `janet_try_init` and
  `janet_restore` with the call between them, because `janet_try_init` is what
  points `janet_vm.return_reg` at the scope's payload and therefore what
  decides a raise has somewhere to go. The `setjmp` was never the scope, only
  the travel. `defer` and `errdefer` are legal everywhere, and the
  `//! jump-transparent` markers and the build check behind them are gone.
- **A raising function returns `raise.Raising(T)`, and each caller decides.**
  Where a caller cannot carry the error union it flattens the raise into a
  report — and a report nobody consumes kills the process at the next protected
  scope, naming neither the cause nor the caller. `./port/swallowed.janet`
  polices exactly that, takes four seconds, and is silent on a clean tree.
- **A cfunction is Zig's, not C's.** `raise.CFunction` takes `[]Janet` and
  answers `error{JanetSignal}!Janet` over Zig's own calling convention, so
  `argv[n]` is bounds-checked where it used to read whatever was there.
- **One file exports, and it is `src/zig/capi.zig`.** No other file under
  `src/zig` uses `export fn`, `@export`, `export const` or `export var`, with
  two exceptions: `native_module.zig`, which is a dynamically loaded module
  rather than the runtime, and `janet_vm`, whose storage class follows
  `-Dsingle-threaded` — `export` cannot be applied conditionally to a
  declaration and a thread-local's address is not comptime-known, so no other
  spelling exists. Everything else a file needs from a neighbour it reaches by
  `@import`, which keeps the error union, allows inlining, and is checked.
- **`cabi.zig` is what is genuinely external**: libc, and the few crossings a
  caller wants for their behaviour rather than by accident. `cabi_check.zig`
  compares every declaration in it against the definition it names, on every
  build, because an `extern fn` is otherwise a promise the compiler believes.
- **Pointers say what is true.** `DESIGN.md` section 9 has the conventions and
  the exceptions: no `[*c]` outside the boundary, a counted byte range is a
  slice, a pointer to one object is `*T` or `?*T` where absence is a state the
  code tests, and a C string is `[*:0]const u8` only where the NUL is
  demonstrably read.
- **Configuration comes from the build.** `build.zig`'s `janetConfig()` is the
  one derivation; a file reads `options.<name>` or `config` and never asks a
  translation what it was compiled with.
- **`root.zig` states which files a configuration compiles**, and an instrument
  has to be gated the way its subject is: a comptime-false branch is never
  analysed, so a native build has no opinion at all about an arm it does not
  select.

## Build steps

| step | what it runs |
| --- | --- |
| `zig build` | the static and shared libraries, the client, the contract driver, the fuzz artifact |
| `zig build test` | the contracts and the Janet suites |
| `zig build zig-contract-test` | the contracts, which live in a second compilation of the runtime |
| `zig build subsystem-test` | the same thing; the name is kept for the documents that cite it |
| `zig build fuzz` | each fuzz target once over its corpus — add `--fuzz` for the campaign |
| `zig build image` | the core image, written to `<prefix>/janet-image.bin` |
| `zig build run` | the client |

The contract driver is installed unconditionally and takes one contract name,
or none for all sixty-five in a single process — which is the only thing in the
tree that initialises and tears the runtime down sixty-five times in a row, and
the only instrument that catches an edit through a contract you were not
thinking about.

## What has expired in the sections below

They are kept because the reasoning in them is why the tree has the shape it
has. Four things they describe are gone, and they appear on nearly every page:

- **The selectors.** Every subsystem could be built from C or from Zig, one
  `-D<name>=c` each, and an index stood here listing sixty-four of them with
  their C origins and `JANET_ZIG_*` guard macros. Phase 10 Part 18 spent the
  last of them and deleted the fifty `.c` files they chose between; `build.zig`
  offers no `=c` value now, and no guard macro is defined.
- **`src/core/`, `src/include/` and `janet.h`,** with `src/conf`, the nine
  internal headers, and the two C programs that included them. Phase 12
  increment 5f.
- **`abi.zig`** — the `@cImport` of that header — and the three oracles that
  held Zig against it. Also 5f. What `c` names now is `cabi.zig`.
- **`src/zig/subsystems/`.** Dissolved at Phase 12 increment 6f, so a path in
  the sections below is usually one directory deeper than the tree's.

## Raising out of `run_vm` instead of jumping past it

`-Dcall-trampoline=true` is not a subsystem selector: there is no Zig source
behind it, and it is off by default. It is the mechanism Phase 7 needs, built
under a flag so that both behaviours stay comparable while `run_vm` is still C.

### Two mechanics that are easy to get backwards

Both are cheap to state and expensive to get wrong, and everything in this
section and the three that follow depends on them.

**`longjmp` carries panics, not yields.** `vm_return` (`core/vm.c:82-86`) is an
ordinary `return` out of `run_vm`, and a fiber's stack is a heap-allocated array
of `Janet` values (`janet.h:995`), not a machine stack. Yield and resume are
normal returns and calls; Janet fibers are not stackful coroutines in the
machine-stack sense. The single `longjmp` at `capi.c:89-92` exists only to unwind
a panic out of a deep C call chain to the nearest `janet_try`. Porting fibers
therefore never required taking stack switching over from libc, because libc was
never doing it.

**`signal_buf` is VM-global, not fiber state** (`core/state.h`). `janet_try_init`
and `janet_restore` push and pop it as a stack of try scopes, and the `jmp_buf`
itself lives in the caller's `JanetTryState` on the *native* stack — so a jump
target is bound to a native frame. Every fiber resume opens a fresh scope, which
is why a fiber may be resumed later from a different native frame than the one it
suspended under. Any replacement has to preserve that per-resume
re-establishment; the Part 8 port does, by leaving `janet_continue_no_check` in C
entirely.

### Why the flag exists

It exists because placement stops working. Once `run_vm` is Zig it sits between
the try scope at `vm.c:2002` and every signal a callee raises, so the rule above
— a signal must never cross an active Zig frame — can no longer be satisfied by
keeping Zig at the leaves. Third-party cfunctions cannot be recompiled to return
a result instead, so a `setjmp` in the same C frame as the call is required for
as long as the C API is supported. Under the flag, no signal reaches `run_vm`'s
frame by jumping: every one arrives as a return value.

Two halves, and they are separable:

**Signals raised by a callee** go through a scope: `vm_scope_enter`,
`vm_scope_setjmp` and `vm_scope_leave` in `core/vm.c`, wrapped by
`vm_scope_run`, which is the body of every `scoped_*` function there. Each
catches the jump one frame below `run_vm` and hands the signal and payload back
as ordinary values, which the matching `vm_*` macro then returns out of
`run_vm`. The signal is returned unaltered rather than re-raised through
`janet_signalv`: because these scopes leave `coerce_error` alone, coercion and
the `sched_id` bump for an `EVENT` signal already happened at the raise, and a
second pass would find the signal already `JANET_SIGNAL_ERROR` and do nothing.
`capi.c:89` is the only `longjmp` that targets `janet_vm.signal_buf`, so nothing
can enter this path having skipped that.

Every `scoped_*` wrapper is a separate function rather than a macro expanded
into `run_vm`, and that is structural rather than stylistic. A local of the
frame holding the `setjmp` has an indeterminate value after a `longjmp` if it
was modified in between and is not `volatile`; `run_vm`'s `stack`, `pc` and
`func` are modified constantly and are declared `register` because the dispatch
loop cannot afford to spill them. The `setjmp` has to live in a frame of its
own.

Everything `run_vm` can reach is scoped, in three groups. The cfunction call
itself, at `JOP_CALL` and `JOP_TAILCALL`. The raise-capable value helpers
`run_vm` calls directly: `janet_in`, `janet_get`, `janet_getindex`, `janet_put`,
`janet_putindex`, `janet_lengthv`, `janet_next_impl`, `janet_equals`,
`janet_compare`, `janet_mcall`, `janet_binop_call` and `janet_unary_call` — the
last three are the operator method fallbacks and sit behind a number fast path,
so they are reached only when an operand is not a number. And the frame and
collection machinery: `resolve_method` and `call_nonfn` at both call opcodes,
`janet_fiber_push`, `janet_fiber_push2`, `janet_fiber_push3` and
`janet_fiber_pushn` at the four push opcodes, and the fill loops of
`JOP_MAKE_TABLE`, `JOP_MAKE_STRUCT`, `JOP_MAKE_STRING` and `JOP_MAKE_BUFFER`.

The property that closes is worth stating exactly, because Phase 9 depends on
it: **nothing reached from `run_vm` raises by jumping past `run_vm`'s frame.**

The four fill loops take one scope around the loop rather than one per element.
That is cheaper, and it is also the only placement that can see a partially
built collection, which makes two things decidable that were not before. Both
were decided to reproduce rather than repair, and both are in `FOUND.md`:
`JOP_MAKE_STRING`'s scratch `JanetBuffer` is `janet_malloc`ed and invisible to
the collector, so a raise mid-loop leaks it — measured at 754MB of resident set
over 100,000 raises — and a loop-wide scope is the first construct positioned to
run its `deinit` on the error path. `JOP_MAKE_TABLE` and `JOP_MAKE_STRUCT` sit
on the "dictionary builder can collect the dictionary it is filling" entry, but
only its collection half: a *panic* from `hash` or `compare` abandons a
collector-owned allocation rather than freeing it early, so the scope neither
worsens nor fixes that, and it is left alone.

Three things do not need a scope, checked rather than assumed.
`janet_fiber_funcframe`, `janet_fiber_funcframe_tail` and
`janet_check_can_resume` contain no `janet_panic` and report by return value.
`janet_gcalloc`, `janet_tuple_n`, `janet_array_n`, `janet_table`,
`janet_struct_begin` and `janet_buffer` end an allocation failure in
`JANET_OUT_OF_MEMORY`, which exits rather than jumping. `janet_continue_no_check`
and `janet_continue_signal` open a `janet_try` of their own and already return a
signal.

**Signals `run_vm` raises itself** go through `vm_raisev` and `vm_raisef`, which
return instead of calling `janet_panicv`. These cannot use a scope at all: they
are raised in `run_vm`'s own frame, not a callee's, so there is nothing below to
catch them. `JOP_ERROR` returning `JANET_SIGNAL_ERROR` is the precedent that the
return path is equivalent.

Five properties are deliberate and are not free to change:

- The scope saves `signal_buf` and `return_reg` only, not the six fields
  `janet_try_init` saves. `stackn` in particular must not be incremented per
  call, which would tighten `JANET_RECURSION_GUARD` for every C call in a chain.
- It leaves `coerce_error` alone. `janet_try_init` clears it, but `ev/give`,
  `ev/take` and `ev/select` read it inside the cfunction to refuse suspension
  inside `janet_call`. `test/suite-ev.janet` covers all three, asserting on the
  message: if the check is skipped, two of the three still raise, but from
  `janet_await` as a coerced `:await` signal, which `assert-error` alone cannot
  distinguish from the guard.
- Every return path sets `JANET_FIBER_DID_RAISE`, exactly as `janet_signalv`
  does. The flag is read on the next resume to pop a C frame and to turn a raise
  at a tail call into an implicit return, so a signal that returned without it
  would resume differently from the panic it replaces.
- Nothing pops a frame that the jump would have left standing. The return skips
  the same `janet_fiber_popframe` the jump skipped, so stack traces are
  unchanged.
- `vm_raisev` and `vm_raisef` do not commit the program counter. Commit is not
  uniform across the raise sites — `JOP_PUSH_ARRAY` never committed, `JOP_CALL`'s
  `stack` is already stale when its arity error fires, and `JOP_TAILCALL` commits
  to a frame it recomputes — so each site keeps the commit it had. Folding one
  into the macro changes a stack trace at the first site and writes through a
  stale pointer at the second.

A scope costs about 2.5ns on macOS arm64, which is the figure `SPIKE-7.md`
measured for the cfunction call and holds for the helpers too. What changed with
the helpers is what that buys against: a cfunction call is expensive enough that
2.5ns is a few per cent, and a data-access opcode is not. Measured against the
same tree with the flag off, per opcode in a loop that does nothing else:
`length` +35%, `in` on an array +28%, `putindex` +27%, `equals` +25%, `compare`
+22%, `next` +18%, `get` on a table or struct +16%, `put` +15%.

The push scopes moved the figure again, and by more, because a push is the
cheapest opcode there is and there is one per argument of every call. With every
group routed, `ReleaseFast`, minimum of five interleaved rounds:

| workload | delta | ns |
|---|---|---|
| empty loop (control) | +3.8% | +0.17 |
| zero-argument call (control) | −0.9% | −0.13 |
| one-argument call | +10.8% | +1.69 |
| two-argument call | +10.8% | +1.74 |
| three-argument call | +10.9% | +1.78 |
| spread call | +9.1% | +1.84 |
| `@{:a i :b i}` | +10.8% | +6.68 |
| `{:a i :b i}` | +10.7% | +8.39 |
| method call | +16.2% | +3.93 |
| calling a table | +25.6% | +4.67 |

The deltas compose exactly as the scope count predicts: a table constructor pays
two push scopes and one fill scope, a method call pays a push and a
`resolve_method`, and a zero-argument call pays nothing and measures nothing.

On real programs the same binaries give +18% on a table-building and iteration
workload, +15% on naive recursive `fib`, +17% on a method-dispatch loop, +1% on
the compiler front end, −0.4% on a peg match, and +0.4% over the whole test
corpus. The call-heavy figures are the ones that grew: everything that calls a
Janet function now pays a scope per argument.

The cost is the scope, not the return: the return paths add nothing to a
signal-free run.

Almost all of the above is temporary. A scope exists only where a C callee might
`longjmp`; once that callee is Zig returning an explicit result, the scope goes
with it. Do not spend effort recovering it here.

**One prediction in that paragraph was wrong, and Part 7 is where it came due.**
This section used to say the per-argument push cost "ends with `fiber.c`", on the
reasoning that `janet_fiber_push*` belongs to that file. Porting them did not end
it. The kernels are Zig and return a result, but the *symbol* `janet_fiber_push`
is still a C wrapper that raises — `run_vm` is C, and `janet_panic` has to be
called from somewhere — so `vm.c` still needs a scope around it. The scope ends
when `run_vm` itself is Zig and can consume the kernel's return value directly,
which is Phase 9; `call_nonfn` and `resolve_method` are `vm.c`'s own statics and
end with the same increment.

The rule to carry forward, and the one that governs every remaining estimate of
when a scaffold cost expires: **a port ends a scope only when it removes the
*raise*, not when it moves the *work*.**

`janet_equals` and `janet_compare` pay the most for the least. Neither can raise
from Janet source at all — the only route is an abstract type's `compare`
callback, and no in-tree abstract type panics from one. They are scoped because
the C API permits a native module to, and the guard cannot be narrowed by
checking operand types, since both recurse into arrays and tuples that may hold
an abstract anywhere.

They keep their scopes anyway. The alternative was to narrow the contract and
declare that `compare` may not panic, and that was declined on 2026-08-18: the
endpoint of this work removes the jumps rather than restricting who may start
one, so buying back 25% on two opcodes by narrowing a published API would be
paying a permanent cost for a temporary gain. Looking for that argument did turn
up something separate and real — an abstract type's `hash` or `compare` callback
can run the collector while a struct or table is being built and unrooted, which
frees it under the builder. That is recorded in `FOUND.md`; it predates the port
and is unaffected by it.

### Verifying a routed raise site

Most of these sites cannot be reached from Janet source, so "the suites pass" is
not evidence about them. The differential probe that established equivalence is
worth describing, because the next session will want the same shape.

The probe registers abstract types whose `hash`, `compare`, `tostring` and
`call` callbacks panic, then drives each site and prints the signal, the
payload, and every stack frame. Three things it has to do that are easy to miss:

- **Two distinct instances, one hash.** `janet_compare_abstract` short-circuits
  on pointer equality, so the same abstract used as a key twice never reaches
  the `compare` callback. The probe's compare type carries a constant `hash`
  callback so that two different instances collide.
- **The assembler, not the compiler.** `JOP_MAKE_STRING` is never emitted, and
  `JOP_MAKE_BUFFER` only for a constant buffer literal. The compiler also
  rejects a zero-argument method call outright, so `resolve_method`'s arity
  branch is reachable only from `asm`.
- **Assert that each probe fired.** The output prints `:did-not-fire` for a
  fiber that came back alive, and the run counts them. A probe that silently
  succeeds looks exactly like one that passed — three of them did, at first.

22 probes, 16 of them raise sites and 6 controls, byte-identical between the two
configurations after normalising addresses. The probe sources and the build
recipe are in `probe-7/`.

The `janet_fiber_push` family is the exception: its only panic is at `INT32_MAX`,
a 32GB fiber stack, so no input reaches it. Those four were verified against a
temporarily instrumented `fiber.c` that panics on demand, with a distinct
message per function so the probe output shows which one fired, built in both
configurations. Eight probes, all fired, identical.

## Owning the thread-local VM state

Phase 7 Part 6, and the first Zig code in the runtime core. `-Dvm-state=c`
restores the C implementation; Zig is the default.

The port itself is seven small functions. What it establishes is the seam every
later runtime port depends on, and that decision is the substance here.

### Zig sees `JanetVM` as C does

`src/zig/state_abi.h` hands `src/core/state.h` to `@cImport`, so `abi.zig`'s `c`
namespace carries the real `JanetVM` — translated per configuration, from the
same header the C files compile — along with `janet_vm` itself. Zig core code
reads and writes VM fields by name. There is no mirror structure to drift out of
date and no accessor function per field.

That is a deliberate reversal of the Phase 3 rule about not exposing private
structures, and the reason it is right here is that the rule's condition no
longer holds. Phase 3 said to prefer narrow bridge functions "where layout
access is not an intended long-term interface". From Phase 7 onward the ports
*are* the runtime core, and `JanetVM` is something Zig ends up owning outright,
so layout access is exactly the intended interface. The alternative costs more
than it saves: `fiber.c` alone reaches `next_collection`, `fiber` and
`root_fiber`, `gc.c` reaches sixteen fields including the hot allocation
counter, and an accessor per field would be both a call on the allocation path
and a second copy of the structure's shape to keep in step.

Two consequences follow, and neither is optional:

- **The ABI module stays single.** Two `@cImport` blocks over the same header
  produce distinct, incompatible Zig types, so `state_abi.h` goes into
  `abi.zig` rather than into a module of its own. Every module that reaches
  `abi.zig` — directly, or through `cli.zig`, `interop.zig` or
  `native_module.zig` — therefore needs `src/core` on its include path;
  `addAbiIncludePath` in `build.zig` is the one place that says so. Contract
  tests deliberately do not get it unless, like `test/vm_state.c`, they
  exercise an internal header themselves.
- **`__thread` has to be respelled.** `janet.h` expands `JANET_THREAD_LOCAL` to
  GCC's `__thread`, and Aro — the translate-c front end in Zig 0.16 — does not
  accept that keyword: it parses as an ordinary identifier and the declaration
  of `janet_vm` fails with an implicit-int error. C11's `_Thread_local` is the
  same storage class and Aro accepts it, so `state_abi.h` redefines the macro
  for translation only. A single-threaded build has no thread-local storage at
  all and is left alone.

### Zig owns the storage, not just the functions

`janet_vm` is *defined* in `vm_state.zig` when the selector is `zig`, which is
why the guard in `state.c` covers the variable as well as the functions. C's
`extern JANET_THREAD_LOCAL JanetVM janet_vm` binds to it: same address, same
per-thread instance, same zero initialisation, confirmed on Mach-O ARM64 and on
ELF aarch64 and x86-64.

The storage class is chosen at compile time from `JANET_VM_THREAD_LOCAL`, which
`state_abi.h` derives from `JANET_SINGLE_THREADED` because translate-c does not
surface a storage class. The variable therefore lives inside a container picked
by an `if`, rather than being exported with `@export`: Zig 0.16 cannot
`@export` a thread-local at all, because the address of one is not
comptime-known, so `export threadlocal var` is the only spelling available.

One difference follows from that. `export` carries default visibility, so
`janet_vm` becomes an exported dynamic symbol of `libjanet`, where the C
build's `-fvisibility=hidden` kept it internal. Nothing public references it —
it appears nowhere in `janet.h` — so this widens the shared library's symbol
set without changing anything that already linked, and the `c` selector
restores the original.

For `janet_vm` itself this is not repairable in Zig 0.16, because it is a
thread-local and `@export` cannot take the address of one. **But the same
widening applies to every function a Zig subsystem exports that `janet.h` does
not declare `JANET_API`, and for a function it is repairable** —
`@export(&f, .{ .name = "f", .visibility = .hidden })` instead of `export fn`.
Four such symbols exist so far, one per increment that took an internal
function: `janet_free_all_scratch` (Part 3), `janet_symbol_deinit` (Part 6b),
`janet_trace_frame` (Phase 7 Part 8) and `janet_next_impl` (Part 8 Part 7b).
Each is visible in `nm` on the Zig build's `libjanet.dylib` and hidden in the
`c` build's. None is referenced from outside the library and none changes what
already linked, so this is a symbol-set difference rather than a behavioural
one — but it is a difference between the two selectors, and unlike `janet_vm`
it has a one-line fix. Left as it is because fixing it belongs to a single
pass over all four rather than to whichever increment noticed.

### Ownership and lifetime rules

These are the rules the rest of Phase 7 and Phase 8 inherit.

1. **One VM per thread, and its storage outlives every pointer to it.**
   `janet_local_vm()` returns the calling thread's VM and never fails. The
   pointer is stable for the life of the thread. A pointer handed to another
   thread — which is what `janet_interpreter_interrupt` is for — is only valid
   while that thread lives.
2. **The VM is a plain aggregate.** Nothing in `vm_state.zig` allocates, frees
   or traces anything the VM points at. `janet_init` and `janet_deinit` in
   `vm.c` own the fields' contents, and they are the only things that do.
3. **A save is shallow.** `janet_vm_save` copies the structure and nothing
   below it, so every snapshot names the same tables, the same fiber, the same
   root array and the same blocks list. Two snapshots differ only in the
   scalars written between them, and freeing one frees the structure alone.
4. **`janet_vm_alloc` returns uninitialised memory,** exactly as the C
   implementation did. It is a destination for `janet_vm_save`, never a VM in
   its own right; reading a field of a fresh one is a caller error.
5. **`auto_suspend` is a counter, not a flag.** Nested interrupts need the same
   number of `janet_interpreter_interrupt_handled` calls to clear, and the
   increment and decrement keep `janet_atomic_inc`'s and `janet_atomic_dec`'s
   orderings rather than choosing new ones.

Rules 3 and 4 describe established behaviour rather than a design: nothing in
the tree calls `janet_vm_alloc`, `janet_vm_save` or `janet_vm_load`. They are
public API for embedders, and the port reproduces them as they were.

### The contract

`test/vm_state.c` is the only contract that includes `state.h`. It has to: what
is under test is the storage of `janet_vm` itself, and a stand-in structure
would test the stand-in. It never calls `janet_init`, which is what lets the
later cases write whatever they like into the VM.

It checks that the owner's `sizeof` and alignment match the compiler's, that
`janet_local_vm()` and `&janet_vm` are one object, that a save copies fields at
both ends of the structure and not one byte past it, that two snapshots restore
independently, that the interrupt counter nests, and — where the build has
threads — that a second thread gets its own zero-initialised VM without
disturbing the first.

Three mutations confirm it is not vacuous: reporting a size eight bytes short,
returning a decoy from `janet_local_vm`, and dropping `threadlocal` from the
storage each fail it.

Running that contract across every configuration that changes the structure's
shape found something unrelated to the port, in C, and in a configuration this
selector does not touch: `-Dinterpreter-interrupt=false` hung
`test/suite-ev.janet` forever, because `ev/deadline` accepted its interrupt flag
and then did nothing, where `os/sigaction` panics for the same reason. Fixed by
agreement using the guard `os/sigaction` already had, and recorded in `FOUND.md`
with what the fix costs — the ordinary half of the deadline did work in that
configuration, so a program that passed the flag and cooperated now gets an error
instead. Both `ev` suites gained the capability probe that `zig build test
-Dinterpreter-interrupt=false` needed in order to complete at all.

### What this cost

Nothing measurable. Access is unchanged on both sides — Darwin's `__thread` and
Zig's `threadlocal` are the same TLV mechanism, and ELF general-dynamic likewise
— and the five `probe-7/work.janet` workloads differ by under a percent in
either direction between the selectors at `ReleaseFast`. The `-Dvm-state=c`
fallback exists for differential testing, not to recover speed.

## Owning the fiber's stack frames

Phase 7 Part 7. `-Dfiber-core=c` restores the C implementation; Zig is the
default.

Zig owns the machinery a call goes through on its way onto and off a fiber's
value stack: `janet_fiber_setcapacity` and the growth policy behind it, the four
`janet_fiber_push*` kernels, `janet_fiber_funcframe`,
`janet_fiber_funcframe_tail`, `janet_fiber_cframe`, `janet_fiber_popframe`, the
environment detach and validate pair, and the four inspectors
(`janet_fiber_status`, `janet_fiber_can_resume`, `janet_current_fiber`,
`janet_root_fiber`). It reaches `janet_vm` by name and reads and writes
`JanetFiber`, `JanetStackFrame` and `JanetFuncEnv` directly — all three are
public in `janet.h`, so nothing private is exposed to get here. `abi.zig` now
also translates `fiber.h` and `util.h`, which are internal headers on the same
footing as `state.h`: from Phase 7 onward the ports *are* the runtime core.

### Nothing in Zig may raise, so two things stayed in C

Both exceptions are the same rule — `janet_panic` is a `longjmp`, and a
`longjmp` may not cross a Zig frame — and they are the whole design of the
increment.

**The stack-overflow panic is reported, not raised.** The push family's only
recoverable failure is a stack that has reached `INT32_MAX`. The kernels return
nonzero and thin wrappers in `fiber.c` call `janet_panic("stack overflow")`
after the Zig frame has returned. Allocation failure is different and needs no
wrapper: `JANET_OUT_OF_MEMORY` is fatal by policy, so `janet_zig_out_of_memory`
is called directly, exactly as the vector port does.

**Zig reports where the variadic tail goes; C builds it.** Packing a `&` or
`&keys` tail means `janet_tuple_n` or `janet_struct_put`, and
`janet_struct_put` hashes the caller's keys — which runs an abstract type's
`hash` callback, which can panic. So the funcframe kernels stop at the slot
index and the count, and `janet_fiber_fill_varargs` in `fiber.c` constructs and
stores the value. This is the scan/allocate/fill split from Phase 5, and it
costs nothing: the packing was already a call.

That second rule is what shapes `janet_fiber_funcframe_tail`. A tail call moves
its arguments down over the frame it is replacing, and the move copies the
tail's slot along with them, so the tail's value has to exist *before* the move
rather than after it. The kernel is therefore in two halves —
`janet_zig_fiber_funcframe_tail_begin` and `..._finish` — with C packing between
them. `janet_fiber_funcframe` needs only one call, because there the packing is
the last thing the function does.

### What stayed in C, and why it is not an oversight

`janet_fiber`, `janet_fiber_reset` and `fiber_alloc` are fiber *allocation*:
`janet_gcalloc` plus the collector's byte budget. That is Phase 8's subject, and
splitting it from this increment keeps each port's dependency on the collector
explicit. `make_struct_n` stays for the reason above. The ten cfunctions stay
because they are argument extraction and `janet_panicf`, which is the layer
Phase 7 still owes and the one that blocked three Phase 6 bullets.

`janet_fiber_did_resume` is not in this file at all — it lives in `ev.c` under
`JANET_EV`, and belongs to the event loop rather than to frame management.

### The contract

`test/fiber_core.c` includes `fiber.h` and `state.h`, because the frame macros
and the collector's byte budget are what the machinery manipulates.

Almost everything here is exercised constantly by the Janet suites — every
function call in the language goes through `janet_fiber_funcframe` — so the
contract is aimed at the edges the suites reach only by accident: both arity
boundaries and the requirement that a rejection leave the fiber untouched, an
empty variadic tail against a non-empty one, a tail call whose arguments have to
move down over a frame with a different slot count, the growth policy at the
exact point a fiber fills up, a zero-length `pushn` with a null array, and the
environment validator, whose whole job is to reject input the suites never
produce — so its three checks are defeated one at a time rather than only
satisfied together.

Two cases do not use `janet_init` at all. `janet_fiber_setcapacity` resizes a
plain allocation and charges the collector's budget, and testing it against a
hand-made `JanetFiber` keeps the arithmetic visible — including the refund on
shrink, which the C original expresses as an unsigned wraparound rather than a
subtraction. The second is the reason the whole increment can trust Part 6: a
child thread charges its *own* VM's budget, which is the one property that could
be wrong while everything else still linked and passed.

Seven mutations confirm the contract is not vacuous: dropping the nil fill in
`funcframe`, growing by `needed` instead of `2 * needed`, ignoring the closure
bitset, dropping the slot-count check in `janet_env_valid`, an off-by-one in the
tail call's `stacksize`, charging the budget the new total instead of the
difference, and leaving `stackstart` behind in `popframe`. Each fails it.

### What this cost

Measured at `ReleaseFast`, interleaving the two selectors rep by rep and keeping
the minimum of twenty-one:

| Workload | Zig | C | Delta |
| --- | --- | --- | --- |
| naive recursive `fib 30` | 0.0724 | 0.0652 | **+11.0%** |
| method-dispatch loop | 0.0190 | 0.0186 | +2.2% |
| table and struct building | 0.1178 | 0.1168 | +0.9% |
| compiler front end | 0.0732 | 0.0729 | +0.4% |
| peg match | 0.1433 | 0.1431 | +0.1% |

Everything except the call-heavy workload is at the noise floor. `fib` is the
figure that matters, and a third build attributes it: with the push family kept
in C and only the funcframe pair wrapped, the same workload costs +9.6%, so
nearly all of it is `janet_fiber_funcframe` and only about a point and a half is
the four pushes.

That is one extra call per Janet function call, worth about 2.3ns here, and it
is **inherent to the wrapper rather than to the port**. `janet_fiber_funcframe`
cannot be the Zig symbol while `run_vm` is C, because building the variadic tail
can raise and only C may do that; and the wrapper cannot be inlined into
`vm.c`'s call site, which was already a cross-object call before the port. It
ends when `run_vm` is Zig and calls the kernel directly — Phase 9, the same
increment that removes the trampoline's scopes.

One micro-optimisation is available and was not taken: the kernels report the
variadic slot and count through out-parameters, and both could be encoded in the
return value instead, since C can derive the slot from the frame it already has.
That would remove some spill traffic but not the call, so it addresses a point
or so of a figure that is going to zero anyway, at the cost of a less obvious
seam. `PLAN.md`'s rule about not spending effort recovering scaffold costs
applies.

### Two defects found, both recorded and neither fixed

`make_struct_n` reads one slot past its arguments when the tail length is odd,
so a `&keys` call with an even argument count binds its last key to whatever the
previous frame left on the stack. `janet_env_detach` dereferences the null that
`janet_env_valid` installs when it rejects an environment, which a fiber
unmarshalled from crafted bytes can reach. Both are in `FOUND.md` with
reproducers; both are shared by the two selectors, since the code in question
stays in C either way.

## Owning the try scope and the decision to raise

Phase 7 Part 8. `-Dsignal-core=c` restores the C implementation; Zig is the
default.

Zig owns `janet_try_init` and `janet_restore`, the decision half of
`janet_signalv` (`janet_signal_plan` and `janet_signal_commit`), and the signal
injection behind `janet_continue_signal` (`janet_signal_inject`). The three new
names are declared in `src/core/state.h`, which is where a seam goes when both
implementations must agree on a type as well as a signature — `JanetSignalPlan`
is the type in question, and `janet_vm_state_size` set the precedent.

### The rule is Part 7's, and it decides three splits

**Nothing in Zig may raise, and nothing in Zig jumps.** Applied to control flow
rather than to frames, that settles what could otherwise look arbitrary.

**The `longjmp` stays in C.** This is a choice rather than a constraint: Zig can
call `_longjmp`, and `janet_signalv`'s own frame is the raise site rather than an
intermediate one, so jumping out of it would not violate the letter of the rule.
It stays in C for two other reasons. A jump out of a Zig frame is the shape this
phase exists to remove, and adopting it here would set a precedent Phase 9 has to
unpick. And Phase 10 deletes this jump outright along with the public `janet_try`
perimeter, so porting it is work with a known expiry — whereas the decision it
guards is not, because a tagged signal-and-payload result still has to make every
one of those choices.

**The coercion message stays in C.** `janet_formatc("%v coerced from %s to
error", ...)` renders a Janet value, which runs an abstract type's `tostring`
callback, which can panic. So `janet_signal_plan` reports `JANET_SIGNAL_PLAN_COERCE`
and stops; `capi.c` builds the message and hands it to `janet_signal_commit`.
That is the report-rather-than-format rule from Phase 5, and the ordering it
produces is the C original's exactly — including the case that matters, where the
formatting itself panics and the re-entrant raise must find `sched_id` already
bumped and the return register not yet written.

**`janet_try_init` does not `setjmp`, and cannot.** Zig has no `setjmp`, and the
buffer must be filled in the frame that will be jumped *to*. The `janet_try` macro
in `janet.h` still expands to `janet_try_init(state)` followed by
`_setjmp((state)->buf)` in the caller's own frame; Zig owns only the field
shuffling in front of it.

### What that leaves in C, and why none of it is an oversight

`janet_continue_no_check` stays in C **in its entirety**, and this is the finding
of the increment rather than a deferral. It *is* the frame that holds the
`jmp_buf` for every fiber resume. A Zig function cannot hold one, so the fiber
resume path cannot move until Phase 10 removes the perimeter — not in Phase 8,
and not in Phase 9. Anyone reading Phase 7's bullet as "port fibers" should read
this paragraph first.

`janet_check_can_resume` stays because its three failure paths build diagnostics
as Janet strings — the report-rather-than-format layer Phase 7 still owes, and
the same one that blocked three Phase 6 bullets. `janet_call` open-codes the same
coercion decision on its own return path and was left alone: it is not a second
caller of `janet_signalv` but a parallel implementation, and folding the two
together would be a behavioural change rather than a port.

### The contract

`test/signal_core.c` runs against either implementation. The suites exercise
these paths constantly and observe almost none of them — every `try` opens a
scope and every `error` raises through the plan, but all a Janet program can see
afterwards is the payload. So the contract checks the things that are invisible
from the language: that `stackn` is saved before it is incremented and restored
exactly, that `coerce_error` is cleared inside the scope and restored outside it,
that scopes nest with the inner one's saved fields being the outer one's live
fields, which of the fourteen signals coerce and which do not, that the `EVENT`
`sched_id` bump is gated on all three of its conditions, and that an injected
signal reaches the *innermost* fiber of a chain and travels in `gc.flags` while
the resume flag travels in `flags`.

Three mutations of the Zig side confirm it is not vacuous: pre-incrementing
`stackn`, leaving `coerce_error` set, and writing the injected signal into
`flags` instead of `gc.flags` each fail it.

### A flag aliasing that is preserved rather than tidied

`janet_signal_inject` writes the signal into `gc.flags`, not `flags`, and clears
`JANET_FIBER_STATUS_MASK` there first. That looks wrong twice over and is right
both times: `run_vm` reads the signal back out of `gc.flags` and clears it there
(`vm.c:1026-1029`), so the two halves agree, and the fiber's real status stays
untouched in `flags` meanwhile.

What is genuinely uncomfortable is that the mask covers bits 16 through 21 of
`gc.flags`, and `JANET_FIBER_EV_FLAG_CANCELED`, `..._SUSPENDED` and
`JANET_FIBER_FLAG_ROOT` are bits 16, 17 and 18 of that same word. Clearing the
mask clears all three. Nothing observable depends on it — `janet_schedule_general`
re-sets `FLAG_ROOT` on every schedule, and the fiber is running between the clear
and the next schedule, so nothing else can look — and a probe driving `ev/cancel`
twice against a live task fiber confirms it. It is recorded here because a port
that "fixed" the field or narrowed the mask would change the carrier, and the
suites would not notice.

### What this cost

Measured at `ReleaseFast`, interleaving the two selectors rep by rep and keeping
the minimum. The five `probe-7/work.janet` workloads show nothing — the deltas
sit between −3.1% and +2.8% and change sign between runs — and that is not a
result, it is the absence of one: none of those workloads resumes a fiber in a
loop, raises in a loop, or prints a trace, so none of them touches this code
often enough to say anything. Workloads that do:

| Workload | Zig | C | Delta |
| --- | --- | --- | --- |
| one fiber, resumed 1,000,000 times | 0.0370 | 0.0339 | **+9.1%** |
| 200,000 fibers, allocated and resumed | 0.0497 | 0.0476 | +4.4% |
| 200,000 `try`/`error` round trips | 0.0417 | 0.0412 | +1.2% |
| 20,000 `debug/stacktrace` calls | 0.0131 | 0.0129 | +1.6% |

The first is the honest figure and the rest are it, diluted. **+3.10ns per
resume**, which is two cross-object calls: the C build can inline `janet_try_init`
and `janet_restore` into `janet_continue_no_check` inside `vm.c`, and a Zig
implementation cannot be inlined into a C caller. Same mechanism as Part 7's
`janet_fiber_funcframe`, and the same size per call.

**This one does not end at Phase 9, and that is worth stating because Part 7's
did.** The scope's cost ends when its caller can consume the kernel directly, and
the caller here is `janet_continue_no_check`, which holds the `jmp_buf` and
therefore cannot be Zig until Phase 10 removes the public `janet_try` perimeter.
At that point the try scope is replaced by the tagged signal-and-payload result
rather than ported, and these two functions stop existing in this shape. So the
figure is a scaffold cost like the trampoline's, but on a longer lease.

It is also worth keeping in proportion: a resume already costs about 34ns, and a
resume-in-a-loop is generator-style code rather than anything on an ordinary hot
path. `PLAN.md`'s rule about not spending effort recovering scaffold costs
applies, and no attempt was made to.

## Decoding a stack frame

Phase 7 Part 8. `-Dtrace-frames=c` restores the C implementation; Zig is the
default.

`janet_stacktrace_ext` is two jobs braided together: a walk over the fiber chain
and its frames, and a rendering of each frame into text. Zig takes the decoding
in between; the walk and the rendering both stay in C. The rendering has to —
`janet_eprintf` is variadic, formats Janet values, and writes to a stream taken
from a dynamic binding, so it can panic, and Phase 5's third rule keeps exact
diagnostics on that side. The walk stays because it is four lines and one of
them is `janet_v_push`, which is already a Zig subsystem.

The seam is `JanetTraceFrame` in `src/core/state.h`. Every string in it points
into a funcdef or the cfunction registry; nothing in `trace_frames.zig`
allocates, holds a Janet value, or can fail.

### Why a seam here is worth drawing at all

`debug.c` decodes a stack frame **twice**, independently: in
`janet_stacktrace_ext`, and in `doframe`, which builds the table `debug/stack`
returns. The two read the same facts — name, source, tail-call flag, bytecode
offset, source mapping, registry entry — through separately written code, and
they have already drifted: the trace version tests `NULL != reg` before using the
registry entry and `doframe` does not, which is a latent null dereference now in
`FOUND.md`. This port makes one of them a caller of a shared decoder. `doframe`
cannot be the other yet, because it is `janet_table_put` and `janet_ckeywordv`
end to end and Janet value construction is Phase 8's subject; it becomes the
second consumer when that lands, and the duplication ends there.

### Two classifications, not one

The awkward part, and the reason `JanetTraceFrame` has the shape it has. **The
name and the location are classified separately**, because the C original
classifies them separately:

- `reg` is set whenever the registry has an entry for the cfunction.
- The name is printed only when that entry *also* has a name.
- The location is printed whenever that entry has a positive source line.

So a registry entry with a null name and a source line renders as `<cfunction> on
line 42` — it fails the name test and passes the location test. A single kind tag
covering both would have to choose, and either choice changes a line the C
implementation prints today. Hence `JanetTraceName` and `JanetTraceLoc` as
independent fields.

Three smaller cases fall out of the same reading and are easy to lose:

- A funcdef frame with a null `pc` reports *no* location — not offset zero. The C
  original arrives there by falling out of `frame->func && frame->pc` into an
  `else if (NULL != reg)` that cannot fire, `reg` being null on every path that
  has a function.
- An unnamed cfunction reports no source even when its registry entry has one,
  because the original prints a source only in the branch that printed a name.
- A frame with neither a function nor a cfunction renders as a bare `  in` line.

### The contract

`test/trace_frames.c` runs against either implementation and enumerates the
cases rather than sampling them, because the suites reach only two of them. A
frame is a plain local rather than four slots of a live fiber's stack — the
decoder reads three fields and nothing else — which is what makes the shapes no
fiber would ever hold constructible at all. The registry cases are built with
`janet_registry_put` directly, including the unnamed entry that no `janet_cfuns`
call produces.

Three mutations confirm it is not vacuous: folding the location test into the
named branch, reporting a source for an unnamed cfunction, and treating a null
`pc` as offset zero each fail it. The first of those is exactly the
simplification the two-field descriptor exists to forbid.

The contract also drives `janet_stacktrace_ext` over a real fiber stopped at an
error, with and without a prefix. That checks the descriptor and the loop that
consumes it agree about a live stack; it does not inspect the text, which belongs
to the suites and to the harness.

## Reporting an argument fault instead of formatting one

Phase 8 Part 1. `-Dargs-core=c` restores the C implementation; Zig is the
default.

This is the layer Phase 7's fifth rule named and did not build. It blocked three
Phase 6 bullets, it is why `fiber.c`'s ten cfunctions and `janet_check_can_resume`
stayed in C in Phase 7, and until it existed neither the core native functions
nor `peg.c` nor `marsh.c` could be touched at all: those files are argument
extraction and Janet value construction end to end.

**The rule that shapes it.** `janet_panicf` allocates a Janet string and
allocation can panic, so a non-panicking getter that formatted eagerly would
need a panic-free allocator. Reporting a code plus the slot and formatting only
at the boundary avoids that — and it makes the messages identical between the
two implementations by construction rather than by inspection, because the
format strings then live in exactly one place. `JanetArgFault` in
`src/core/state.h` is the report; `janet_arg_raise` in `capi.c` is that place.

Nothing in `JanetArgFault` is a Janet value. The slot index is enough for the
boundary to recover `argv[slot]` and render it with `%v`, and `%v` runs an
abstract type's `tostring` callback. Same reasoning as `JanetTraceFrame`, and
the same reasoning that kept the coercion message in C in Phase 7 Part 8.

### The nouns are a code, not a string

Eleven numeric getters name what they wanted — "size", "16 bit signed integer",
"non-negative 32 bit signed integer". Zig reports `JanetArgExpect` and
`janet_arg_expect_name` in `capi.c` decides the words. Handing the string across
instead would have worked and would have been one field shorter; the code is
what makes a wording change impossible to make on one side only.

### Three things are classified rather than done

Each is the same sentence — nothing Zig calls may raise — applied to a different
caller.

**`janet_arg_bytes` reports the abstract case.** A byte view of an abstract runs
the type's `bytes` callback, which is third-party code and may panic. So the
kernel classifies into string, buffer, abstract-with-a-callback, or fault, and
the two callers that can raise — `janet_getbytes` in `capi.c` and
`janet_bytes_view` in `util.c` — make the call themselves. This is the first
increment to hit the panicking-callback problem, and it is settled here by
placement rather than by mechanism; SPIKE-8 decides the general case before the
GC, which cannot avoid it.

**`janet_arg_cbytes` decides which of three shapes applies and stops.** Two of
them mutate or allocate: one pushes a zero byte onto the buffer, one calls
`janet_smalloc` because pushing would panic on a buffer that cannot realloc.
Both are carried out by the caller, which is also where the embedded-zero test
then happens.

**`janet_arg_nextmethod` returns the entry, not the keyword.** `janet_ckeywordv`
allocates.

### What stayed in C, and why none of it is an oversight

Every exported `janet_get*` and `janet_opt*`, because the raise cannot be on the
Zig side — the same shape as every C wrapper in Phases 5 through 7. The three
view constructors, because their signatures are public and cannot report
"a callback is needed" to a third-party caller. `janet_getinteger64` and
`janet_getuinteger64` in a build with integer types, because there they accept an
`int/s64` abstract and `janet_unwrap_s64` raises its own message: there is no
fault for a kernel to report, so there is no seam to draw.

### Where the two implementations genuinely differ

One place, and it is recorded in `FOUND.md` rather than smoothed over.
`janet_checksize` casts a double to `size_t` *before* testing whether the
conversion means anything, which is undefined for a negative, infinite or
enormous value and reachable from Janet source as `(gcsetinterval -1)`. On the
supported targets the conversion saturates and the answer comes out right; a
Debug build traps it and aborts.

Zig cannot reproduce that. `@intFromFloat` outside the destination's range is
checked illegal behavior, not a saturating cast, so `args_core.zig` tests first
and converts second. So `-Dargs-core=c` aborts on `(gcsetinterval -1)` in a Debug
build and the Zig default raises `bad slot #0, expected size, got -1`; they agree
in every release mode and on every other input. `test/args_core.c` exercises only
the defined half of that domain, under this phase's rule that reproduced
undefined behavior gets no contract.

### Two defects reproduced rather than repaired, and both pinned

`janet_checkfloat` tests `>= FLT_MIN`, the smallest positive *normal* float
rather than the most negative finite one, so `janet_getfloat` rejects zero, every
negative value, and every subnormal. Nothing in the core calls it — it exists for
native modules — which is why no suite has ever noticed. `janet_getflags` clamps
a permitted set longer than 64 characters and then reports a character past the
ceiling as `unexpected flag`, quoting the full oversized set back in the message.
Both are defined behavior rather than undefined, so unlike `janet_checksize` both
are pinned by the contract: a later fix has to change the test deliberately.

The range faults also widen three operands to `int64_t` before handing them to a
`%d` that Janet's formatter reads as an `int32_t`. That is the existing `%d`
entry in `FOUND.md`, and the widening is preserved on both sides so the rendering
matches on the targets where it works.

### The contract

`test/args_core.c` runs against either implementation. What it guards is a set of
decisions and a set of messages, and it checks them separately because the port
separates them: every case drives an exported getter through a try scope and
compares the payload byte for byte, which is the only way to show that a fault
code plus a slot really does reconstruct the message the C original raised.

The suites reach almost none of this. A Janet program that calls a cfunction with
a wrong argument sees one message and stops, so the common shapes are covered
incidentally and the rest are not reached at all: every width of integer at both
its boundaries, both range foldings, the flag ceiling, the three `cbytes` shapes,
the abstract-with-a-`bytes`-callback path, and the eleven expectation nouns. The
panic count is asserted rather than floored, because a case that stopped raising
would otherwise be a silent subtraction.

Three mutations confirm it is not vacuous: folding the half range against
`length` instead of `length + 1`, reporting `S16` as `U16`, and giving a full
no-realloc buffer the terminating shape instead of the copying one. The last of
those is the one that matters — it fails with `buffer cannot reallocate foreign
memory`, which is precisely the panic the copying shape exists to avoid, and it
is unreachable from Janet source.

### The callback question this increment postponed

`janet_arg_bytes` settles the abstract case by placement — the classifier is a
leaf, so its C caller can make the call. Nothing later in Phase 8 is a leaf, and
the collector cannot use placement at all: the mutator's try scope is
arbitrarily far away, so a jump from `gcmark` crosses every Zig mark frame
regardless of where the callback is invoked.

`SPIKE-8.md` settled the general case, and the rule it produced governs Parts 3
onward: **an abstract type's callbacks may not raise, and a signal from one that
does may jump straight through the Zig frames that invoked it.** That document is
no longer in the tree, so this paragraph is the rule's home; `build.zig` points
here when it rejects a `defer` in a jump-transparent file. Phase 9 Part 3 made
the rule load-bearing for `run_vm` itself.

 Zig calls
`gcmark`, the finalizers, `compare`, `hash`, `get`, `put`, `next` and `length`
directly. Not one of the fifteen in-tree abstract types can raise from any of
them, so this restricts third-party modules only, and the fork breaks those by
design.

A `longjmp` through a Zig frame is mechanically harmless — Zig has no
destructors, and a probe crosses eight nested frames without complaint. The one
thing it breaks is `defer`, skipped silently. So a subsystem on such a path
declares `//! jump-transparent` at its head, and `checkJumpTransparency` in
`build.zig` fails the build if that file contains a `defer` or `errdefer`:

```text
src/zig/subsystems/remove_noops.zig:15: 'defer' in a jump-transparent source.
A Janet signal may jump through these frames, which skips it silently.
```

Eight `defer`s exist across the subsystems today and none of those files is
jump-transparent. Two of them are `defer c.janet_gcunlock(gc_lock)`, in
`asm_decode.zig` and `disasm.zig`; a skipped `janet_gcunlock` wedges the
collector permanently rather than leaking, and both are safe only because the
regions they guard can exhaust memory and exit but cannot jump.

Part 1 itself is *not* jump-transparent and does not carry the marker: it keeps
the abstract `bytes` call on the C side, which was the cheaper answer for a leaf
and remains correct.

## The collector's memory, without the collector

Phase 8 Part 3. `-Dgc-alloc=c` restores the C implementation; Zig is the
default. `gc_alloc.zig` owns thirteen functions from `gc.c`: `janet_gcalloc`
and `janet_gcpressure`, the four root-set functions, `janet_gclock` and
`janet_gcunlock`, and the whole scratch allocator including
`janet_free_all_scratch`.

### The split is by data structure, not by call graph

`gc.c` is three things wearing one file: the memory the collector manages, the
traversal that decides what is live, and the sweep that acts on the decision.
Part 3 takes the first, and the boundary is worth stating because it is not
where a reader would draw it from the call graph — `janet_collect` calls
`janet_free_all_scratch`, and `janet_gcalloc` moves the counter that eventually
triggers `janet_collect`, so the three parts are mutually recursive at the level
of who calls whom.

They are not recursive at the level of who *owns* what, which is the boundary
that matters for a port. Nothing in Part 3 traverses an object. `janet_gcalloc`
writes a type tag into a header and pushes the block onto a list; it never looks
at what the caller puts there, and it is the caller's job to make the block
well-formed before anything can collect. The heap lists are touched at one end
only, and by exactly one function each: this file prepends, `janet_sweep`
unlinks. Marking and sweeping can therefore move independently, in either order,
and Parts 4 and 5 inherit no decision from this one.

Two thread-locals stay behind because they belong to the traversal rather than
to the memory: `depth`, the recursion guard `janet_mark` decrements, and
`orig_rootcount`, which `janet_collect` uses to tell roots that existed when the
collection began from roots added by a `gcmark` callback while it ran. Both move
with Part 4.

### One seam, and why it is a declaration rather than a bridge

`janet_free_all_scratch` was `static` in `gc.c` and had two callers there,
`janet_collect` and `janet_clear_memory`, both of which stay in C for this
increment. Moving the scratch allocator without them means the symbol has to
cross the file boundary, so it is now declared in `gc.h`:

```c
void janet_free_all_scratch(void);
```

That is the whole seam. It is not public API, it takes no arguments, and it
needs no wrapper — which is the point. The previous seam this phase drew,
`JanetArgFault`, existed because the two sides could not agree on who was
allowed to raise. Here they agree completely: releasing scratch memory is the
same operation on either side of the boundary, so dropping `static` is the
entire cost of making it selectable. A seam that needs more than this is a sign
the split is in the wrong place.

`gc.h` also joined `abi.zig`'s single translation, for `enum JanetMemoryType`.
Its function-like macros over `JanetGCObject` — `janet_gc_settype`,
`janet_gc_mark`, `janet_gc_reachable` — do not survive translate-c and are
written out in Zig where they are used, which for this increment is one
assignment to `flags`.

### The file is jump-transparent, and for one call

`freeOneScratch` invokes a `JanetScratchFinalizer` that an embedder installed
through `janet_sfinalizer`. That is third-party code on a Zig frame, so SPIKE-8's
rule applies and the file carries `//! jump-transparent`; `build.zig` enforces
that it holds no `defer`.

It is worth being precise about how thin this is. No in-tree caller of
`janet_sfinalizer` exists — the API has none, in any of `src/core`, and the
scratch blocks the runtime allocates are all released by `janet_sfree` or by the
collection that follows. So the marker guards a path that only an embedding
reaches, and only one that installs a finalizer that raises, which the rule
already forbids. It is carried anyway because the alternative is a file whose
safety depends on nobody using a public API.

If such a finalizer does raise, `scratch_len` is left unreduced and the block is
re-finalized at the next collection. That is exactly what the C original does,
for the same reason — the counter is zeroed after the loop, not during it — so
the port does not diverge, and the failure mode is the abstract-finalizer one
`FOUND.md` already records rather than a new one.

### Three pieces of arithmetic reproduced rather than repaired

All three are in `FOUND.md`, and the first is the only one a caller can observe:

- **`janet_gcunrootall` removes `floor(n / 2)` of `n` rootings.** It fills the
  vacated slot from the top and then advances, so the root it moved down is
  never examined. It returns 1 either way, so a caller cannot tell. Nothing in
  the tree calls it. `test/gc_alloc.c` pins the halving for n of 1, 2, 3, 4, 5
  and 8 against both selectors, which is what stops a later cleanup from
  "fixing" one side into a silent divergence.
- **The scratch table is sized by `sizeof(JanetScratch)` where its elements are
  `JanetScratch *`.** The header is a function pointer followed by a flexible
  array, so it is never smaller than a pointer and the table is over-allocated
  rather than short — exact on 64-bit, double on 32-bit. Reproduced so the two
  selectors request the same byte counts.
- **`janet_smalloc` and `janet_srealloc` add the header size without checking
  for wraparound.** Zig would trap where C wraps, so the additions here are
  written `+%`. No in-tree caller can approach `SIZE_MAX`; every one derives its
  size from an `int32_t` count.

One further difference is a Zig artifact rather than a C defect. `janet_gcroot`
stores the `realloc` result before testing it, so a failed grow leaves
`janet_vm.roots` null on its way to `exit(1)`. That store is preserved rather
than tidied into a temporary, because the two selectors should be
indistinguishable under a debugger as well as under a test.

### The contract

`test/gc_alloc.c` includes `state.h` and `gc.h`, for the same reason
`test/vm_state.c` includes `state.h`: every operation under test is a mutation
of `janet_vm`'s collection fields, and the fields are the observable result.
There is no public accessor for `block_count` or `scratch_len`, and an accessor
invented for the test would be the thing the test proves correct.

Twenty-two cases, in four groups. The heap-list cases allocate a block, check
the list it landed on, the header it was given, and the three counters, then
*unlink it themselves* and restore the counters — so no synthetic block ever
reaches `janet_sweep`, and the contract stays independent of Parts 4 and 5. The
weak boundary is enumerated over all four weak types and five strong ones rather
than sampled at the edge, because the split is a numeric comparison against
`JANET_MEMORY_TABLE_WEAKK` and a table of types would pass a sampled test.

The root cases cover pointer identity, the three immediate types that compare
equal to anything of their own type, the swap-from-top that leaves the root set
unordered, capacity growth, and the `gcunrootall` halving. The scratch cases
cover registration and the header offset the whole allocator depends on,
zeroing, reallocation preserving both the bytes and the finalizer and the table
slot, the swap-from-top on free, and growth to `2 * cap + 2` with every held
block's contents checked across the move.

Two paths are described in the file rather than run: `janet_srealloc` and
`janet_sfree` on a pointer this allocator never handed out, both of which abort
the process.

Four mutations of the Zig side were run against it, and all four were caught by
a named assertion. The one that matters is repairing `janet_gcunrootall` to
remove every rooting — the contract exists to hold the two implementations to
the same defect, so a mutation that improves one of them has to fail.

### What this cost

Thirteen functions, 296 lines of Zig against 203 lines of C. The ratio is
the usual one for this project and comes from the same place: the module
comment, the per-function documentation, and the comments naming each preserved
defect at the line that preserves it. No behaviour was added.

## The mark phase, and the collection that drives it

Phase 8 Part 4. `-Dgc-mark=c` restores the C implementation; Zig is the default.
`gc_mark.zig` owns the whole traversal — `janet_mark` and the fifteen static
helpers beneath it — the recursion guard, and `janet_collect`. It exports
exactly two symbols, because everything between them is `static` in the C
original and stays private here.

### Nothing in it frees anything

That is the boundary, stated as a property rather than as a list of functions.
The traversal reads the object graph and writes one bit per object,
`JANET_MEM_REACHABLE`, into a header it did not allocate and will not release.
Part 3 allocates those headers and Part 5 releases them, so the three parts
touch the same objects at three disjoint moments and none of them has to know
how the others do it.

The one place the walk does more than set a bit is a threaded abstract, which is
recorded in `janet_vm.threaded_abstracts` instead of being marked. That is a
table write, so it can allocate, which makes it the only step of the traversal
that can fail — and it fails before anything has been marked rather than
half-way through.

### `janet_collect` moved with marking, and that is why there is no seam

`PLAN.md` had it in Part 5, with sweeping. Moving it here was the whole design
decision of the increment, and the argument is short: `janet_collect` is the
only reader of `depth` and `orig_rootcount`, the two thread-locals `gc.c` keeps
outside `janet_vm`. Leaving it in C would have meant either exporting a
thread-local across the language boundary — where a single-threaded build and a
Zig `threadlocal` disagree about what storage class even means — or adding a
function whose only job is to reset a counter.

Putting it in Part 4 costs nothing. Everything it calls outward is already
declared for reasons that predate the port: `janet_sweep` and `janet_collect`
are public API in `janet.h`, `janet_free_all_scratch` was declared in `gc.h` by
Part 3, and `janet_ev_mark` lives in `util.h`, which `abi.zig` does not
translate and which this file therefore declares directly — the case `abi.zig`'s
comment describes, a function whose parameters are all primitive.

So **this increment added no seam at all**. Part 3 needed one declaration; Part
4 needed none; Part 5 will inherit none. That is worth more than it sounds,
because a seam is the part of a port that has to be unpicked later, and Phase 10
deletes the C side entirely.

### The guard is a contract, not a safety net

`janet_mark` decrements a budget on the way in and restores it on the way out.
When the budget is gone it *roots* the value instead of traversing it, and
`janet_collect`'s second loop drains those roots and marks each one from a fresh
budget. So a graph deeper than `JANET_RECURSION_GUARD` is marked completely, in
slices — not truncated, and not paid for in C stack.

Both halves are pinned. `test_depth_guard_roots_the_overflow` marks a chain one
link longer than the guard and asserts that link 1023 is marked, link 1024 is
not, and the root set grew by exactly one whose pointer is link 1024.
`test_collect_finishes_deep_graphs` takes a chain three times the guard's depth
and asserts the last link survives a collection, observed through a weak-valued
table — which is how a mark that has already been cleared can still be seen.

The drain loop's other consequence is easy to miss and is pinned too: a root
added *during* a collection is consumed by that collection. A `gcmark` callback
that calls `janet_gcroot` does not leave a root behind.

### Three things reproduced rather than repaired

All three are in `FOUND.md`. Two are arithmetic in `janet_collect` — a
`uint32_t` counter walking a `size_t` root count, and the collection-interval
heuristic multiplying without a guard — and both are reproduced with wrapping
operators so that the two selectors agree rather than one of them trapping.
Neither is reachable on a heap that fits in an address space.

The third is not a defect: `janet_mark_array` marks a weak array's header but
not its elements, and the type test that decides this reads like a redundant
check. `test_mark_array_weak` pins it so that a later reader who removes it gets
a failure instead of a silently strengthened weak array.

### What translate-c cannot give us

The C macros recover an object's header by subtracting
`offsetof(Head, data)` — and `data` is a flexible array member, which
translate-c drops entirely, so `@offsetOf` does not compile. All five head
recoveries use `@sizeOf` instead, which is the same number exactly when the
flexible array needs no padding after the last declared field.

Rather than assert that in Zig, where the field does not exist,
`test/gc_mark.c` compares `sizeof` against `offsetof` for all five heads in C,
where both spellings do. It runs under the `c` selector as well, where the
equality is merely true rather than load-bearing — which is the cheapest way to
notice if a future field ever breaks it. Part 3 has the same assumption for
`JanetScratch` and records it the same way.

### The file is jump-transparent

Two calls reach code this runtime does not own: an abstract type's `gcmark`, and
a root fiber's `ev_callback`. Under SPIKE-8's rule neither may raise, and a
signal from one jumps straight out through every frame of the walk. Those frames
own nothing, `build.zig` checks that they do not, and the check was confirmed to
cover this file by planting a `defer` and watching the build fail.

What a jump costs is exactly what the C original costs: a half-marked heap, no
sweep, `next_collection` not reset. The port does not diverge there, and
`SPIKE-8.md` records the baseline.

### What this cost

Seventeen functions, 460 lines of Zig against 311 lines of C, and two exported
symbols. The ratio is the usual one and comes from the same place: the module
comment, the per-function documentation, and the comments naming each preserved
defect where it is preserved.

One acceptance check does not pass, and it is not the port's doing.
`-Doptimize=ReleaseSafe` traps inside `janet_init` in the new test binary,
before any code under test runs, because the thread-local `janet_vm` lands
4-byte-aligned in that image and ReleaseSafe traps on the misaligned load.
It reproduces with `-Dgc-mark=c`, does not reproduce in a minimal program
against the same library, and is recorded in `FOUND.md` with the two fixes that
were tried and did not move it.

## The sweep, the weak heap, and the teardown

Phase 8 Part 5, and the end of `gc.c`. `-Dgc-sweep=c` restores the C
implementation; Zig is the default. `gc_sweep.zig` owns `janet_sweep`,
`janet_clear_memory`, and the two static functions beneath them,
`janet_deinit_block` and `janet_check_liveref`. It exports two symbols, and
with this increment `gc.c` contains no C the port has not taken.

### Everything here frees, and nothing here traverses

That is Part 4's boundary read backwards, and it is what makes a three-way split
of one file hold together. The mark phase reads the object graph and writes one
bit per object; the sweep reads that bit and never follows a pointer the bit
does not justify.

The single place the two touch is `checkLiveref`, which reads the mark of a
value a weak container refers to. That is a read of one header, not a walk, and
it is the reason a weak reference is dropped in the sweep rather than skipped in
the walk: the walk cannot know whether anything *else* will reach the value, and
by the time the sweep runs, everything that will reach it already has.

### Three increments, no seam between any of them

Part 3 needed one declaration — `janet_free_all_scratch` lost its `static`.
Parts 4 and 5 needed none at all. `janet_sweep` and `janet_clear_memory` are
public API in `janet.h`; `janet_deinit_block` and `janet_check_liveref` were
`static` with no caller outside the region that moved with them; and the one
symbol this file reaches for that is neither public API nor already declared for
Zig is `janet_symbol_deinit`, which takes a `const uint8_t *` and is therefore
declared directly under the same rule `gc_mark.zig` uses for `janet_ev_mark`.

`nm` on the object is the whole interface:

```text
T _janet_clear_memory     T _janet_sweep
U _janet_abstract_decref_maybe_free   U _janet_buffer_deinit
U _janet_ev_dec_refcount              U _janet_free
U _janet_free_all_scratch             U _janet_symbol_deinit
...
```

Two defined, and every undefined name either public API, Part 3's one
declaration, or the runtime bridge.

### The weak heap is walked twice, and the order is the contract

The first pass visits every *surviving* weak container and nils out the entries
whose weak half died. The second pass frees the weak containers that did not
survive. Doing them in one pass, or in the other order, would mean reading the
header of a block that had already been freed — the test for a dead weak
reference is a read of the mark bit in the very object being dropped.

That makes the ordering a property a sanitizer sees rather than one an assertion
can catch, so `test_weak_entry_and_its_target_die_together` asserts what it can:
the container survives, the entry is gone, and the block count fell by exactly
the blocks that should have died.

The variants are pinned exactly, because which half is checked here has to
mirror which half the mark phase skipped. A weak-keyed table keeps an entry
whose value is otherwise unreferenced — the walk marked that value — and drops
one whose key is; a weak-valued table is the mirror; a table weak in both keeps
neither. `test_weak_table_variants` builds all four kinds, including a strong
control, and checks each one. Swapping the two predicates fails it.

There is one consequence of the mirror worth naming, because it looks like a
bug and is not: a weak table's key outlives the entry by one collection. The
walk reaches the keyword through the entry and marks it, and the sweep then
drops the entry — so the key is freed by the *next* collection. That is the one
collection of lag a weak container costs, and the test asserts both halves of
it.

### Finalization, and what "exactly once" rests on

`janet_deinit_block` runs a type's `gcperthread` and then its `gc`, in that
order, and both before the block is unlinked. Each of those is a contract:

- The order is not incidental. `gcperthread` releases what belongs to this
  interpreter and `gc` releases what the value owns outright, so reversing them
  would let `gc` free memory `gcperthread` still reads.
- The finalizer is driven by reachability, not by the sweep visiting the block:
  a survivor is not finalized, and a block is not finalized twice.
- Running *before* the unlink is the C original's order, and it is what makes a
  panicking finalizer poison the heap permanently — the block is still on the
  list, so the next collection finds it unreachable again. That is in
  `FOUND.md`, measured by the Phase 8 probes, and reproduced here rather than
  quietly repaired.

A threaded abstract is on neither heap list, so its fate is decided through
`janet_vm.threaded_abstracts` instead. The table is a per-collection visit
record: the mark phase writes true for every threaded abstract it reaches, and
the sweep reads the entry, drops this interpreter's reference if it is still
false, and resets it to false for next time. Whichever interpreter takes the
refcount to zero is the one that runs the type's `gc`, which is what makes the
finalizer run once across all of them.

### Freeing is mostly invisible, and the contract says so

A freed block cannot be read, and a `janet_free` that does not happen leaves
nothing to observe from inside the process. `test/gc_sweep.c` therefore leans on
three channels that survive the free: `janet_vm.block_count`, which falls
exactly once per block; an abstract type's finalizers, which can count
themselves on the way out; and `janet_vm.cache_count`, which falls when a symbol
leaves the symbol cache — the one external obligation an immutable block has,
and the only reason `janet_deinit_block` has a `JANET_MEMORY_SYMBOL` case at
all.

What that leaves uncovered is stated in the test rather than papered over: the
`janet_free` calls for an array's, a table's, a fiber's or a funcdef's payload
are leaks when omitted and double frees when duplicated, and neither is visible
from inside a process. A leak checker sees the first; the repeated init/deinit
cycle at the end of the file is what would catch the second.

Eight mutations of the Zig were checked against the contract and each failed a
different named assertion: ignoring `JANET_MEM_DISABLED`, leaving the mark set
on survivors, swapping the two weak predicates, skipping the symbol cache,
reversing the two finalizers, not resetting the threaded-abstract visit record,
never freeing the weak list, and skipping `janet_deinit_block` at teardown.

### One defect reproduced, and asserted as a defect

`janet_clear_memory` walks `janet_vm.blocks` and never `janet_vm.weak_blocks`,
so every weak container alive at `janet_deinit` leaks its block and its data
array — 32KB per teardown for a 4096-element weak array, measured against a
strong-array control. `janet_init` then nulls the
list head, so the memory is unrecoverable rather than merely retained.

The port reproduces it by walking the same single list, and the contract asserts
its signature:

```c
janet_deinit();
assert(janet_vm.blocks == NULL);
assert(janet_vm.weak_blocks != NULL);
```

That asserts the defect rather than a guarantee, deliberately. It holds for both
selectors today and fails for whichever one is fixed first, which is exactly the
reminder the other one needs. `FOUND.md` has the entry and the measurement.

### The file is jump-transparent

Three calls reach code this runtime does not own, and they are all finalizers:
an abstract type's `gc` and `gcperthread` from `janet_deinit_block`, and
`gcperthread` again from the threaded-abstract sweep. This is the increment
SPIKE-8's rule was written for, since a finalizer is the callback most likely to
be doing something an author thinks is worth raising about. Under that rule none
of them may raise; the frames own nothing, `build.zig` checks it, and the check
was confirmed to cover this file by planting a `defer` and watching the build
fail.

### What this cost

Eight functions plus eleven inline helpers where the C original has four
functions and a handful of macros, 439 lines of Zig against 240 lines of C, and
two exported symbols. The extra functions are not decomposition for its own
sake: `dropDeadElements`, `dropDeadEntries` and `freeUnreachable` are lifted out
of `janet_sweep`'s body, and `freeUnreachable` in particular is the C original's
two identical loops over the two heap lists written once and called twice.

This increment passes every acceptance check, including `-Doptimize=ReleaseSafe`,
where the only failing binary in the build is Part 4's `janet-gc-mark-test` —
still failing for the `janet_vm` alignment reason recorded in `FOUND.md`, and
still not the port's doing. That the new binary passes the same check in the
same build is one more piece of evidence for that entry's diagnosis: what
decides it is which library objects a binary pulls out of the archive.

## Adding a subsystem

Each port touches five places in `build.zig`, one in the module root, and one
in the C source. Missing any of them fails quietly rather than loudly, so work
through all of them:

1. Add `src/zig/subsystems/<name>.zig`. Import `abi` for the C declarations.
   Export C-compatible functions for anything a C caller still reaches; a
   neighbouring subsystem reaches it as ordinary Zig, so a raise-capable
   function there should return `raise.Error` and have an abi beside it
   rather than being written to the C ABI. See "One module, and the seam that
   was a link boundary".
2. Add a field to `BuildOptions` and to `Selection`.
3. Answer it in `zigSelection`, gated on any feature flag the subsystem depends
   on. That expression is the only place the condition is written: both the
   guard macro and the import are derived from it.
4. Read the option in `readOptions` with `orelse .zig`.
5. In `addRuntimeSources`, add the guard macro — or a `switch` over whole
   source files if the port replaces a file outright. There is no `addObject`
   to add any more; there is one object and it is already there.
6. Import it in `src/zig/subsystems/root.zig`, under its `options` field. A
   subsystem reached only through another one — the way `os_files.zig` is
   reached through `os_surface.zig` — is imported by that file instead and does
   not appear in the root.
7. Guard the C original with `#ifdef JANET_ZIG_<NAME>` so exactly one
   implementation is compiled.

Then add `test/<name>.c`, registered with `test_c_flags` (see "C test
compilation"), linked against the static library, and attached to
`subsystem_step`. Add `addIncludePath(b.path("src/core"))` if it needs private
headers.

Two verification steps are worth doing every time, because both failure modes
look like success:

```sh
# Exactly one provider of each exported symbol.
zig build && nm -o zig-out/lib/libjanet.a | grep "T _janet_<symbol>"

# The contract passes against the C original, before trusting it against Zig.
zig build subsystem-test -D<name>=c
```

Run the contract against `c` *first*. A test written against the new Zig code
and only ever run against it proves the code matches itself. Establishing the
vectors against the C baseline is what makes the comparison meaningful, and is
also how several `FOUND.md` entries were discovered.

For anything numeric or with a large input space, add a differential corpus as
well: build two prefixes (`zig build -p out-zig` and `zig build -p out-c
-D<name>=c`), run the same generated inputs through both, and diff the output
byte for byte. The number scanner, math kernels, and integer kernels each have
one; they caught nothing, which is the point.

## Reduced builds

`zig build test` passes with each of Janet's feature flags turned off
individually: `-Dint-types=false`, `-Dassembler=false`, `-Dpeg=false`,
`-Dnet=false`, `-Dev=false`, `-Dprocesses=false`, `-Dfilewatch=false`,
`-Dffi=false`, `-Ddocstrings=false`, `-Dsourcemaps=false`, `-Dumask=false`,
`-Drealpath=false`, `-Dcryptorand=false`, and `-Ddynamic-modules=false`.

Two different mechanisms are needed, and choosing the wrong one fails quietly.

A binding the build omits entirely is a *compile* error at its use site, not a
nil value at run time, so `(when-let [x maybe/missing] ...)` cannot guard one.
Those need `compwhen`, which decides at compile time.

A binding that still exists but raises when called needs the opposite: an
ordinary runtime `when`. `os/realpath`, `os/cryptorand`, and `ffi/native` are
registered whatever the build options say, and only their bodies fail, so
`compwhen (dyn 'os/realpath)` sees a live binding and compiles the code anyway.
`test/suite-os.janet` and `test/suite-bundle.janet` probe these with
`(protect ...)` instead.

**Prefer guarding regions to skipping a suite.** A whole-suite skip is only
correct when every test in the suite genuinely depends on the feature, and that
has to be checked rather than assumed: an unrun suite reports `0 of 0` and looks
just like a passing one. `suite-ev.janet` guards its network and subprocess
regions separately, so its channel, fiber, and deadline tests still run in both
reduced configurations — 687 of 737 assertions survive `-Dprocesses=false`.
`suite-net.janet`, `suite-peg.janet`, and `suite-filewatch.janet` each keep one
feature-independent test above their guard for the same reason.

Where a whole suite really does depend on the feature — `suite-inttypes`,
`suite-asm`, `suite-ev2`, `regalloc-bytecode` — it leaves early, immediately
after `start-suite`, with `(compwhen (not (dyn 'some/binding)) (end-suite)
(os/exit 0))`. That works because Janet compiles and runs a file one top-level
form at a time, so nothing after the exit reaches the compiler. `suite-ev.janet`
uses the same shape for `-Dev=false`, where it matters for a second reason: its
subprocess tests block forever without the event loop rather than failing.

`-Dreduced-os=true` is a **known gap** and is deliberately not guarded. It
leaves only `os/exit`, `os/which`, `os/arch`, `os/compiler`, and `os/isatty`,
which breaks `test/helper.janet` itself, so every suite fails before reaching
its own code. Guarding it would mean skipping `suite-os` wholesale along with
much of `suite-ev` and `suite-bundle` — a run that passes while testing
substantially less than it appears to. Since that configuration exists to
remove the host interface, running Janet's host-facing suites against it has
little value. Revisit only with a plan for what the suites should still assert.

## C test compilation

The C contract tests are compiled with `test_c_flags`, not `common_c_flags`.
The only difference is `-UNDEBUG`, and it is load-bearing: Zig defines `NDEBUG`
for C sources in `ReleaseFast` and `ReleaseSmall`, which turns `assert` into a
no-op that does not evaluate its argument. Because these tests call the code
under test from inside their assertions, losing `assert` does not merely stop
checking results — it removes the calls, so the surviving sequence exercises the
subsystem in a state the test never set up. Any new C test must use
`test_c_flags` for the same reason.

## Cross-platform constraints

Two rules follow from targets other than macOS, and both are invisible when
building only for the development host:

- **Subsystem objects must be position independent.** They are linked into the
  shared library as well as the static one, and ELF shared objects require PIC.
  `makeZigSubsystemObject` sets `.pic = true` for this reason. Mach-O is always
  position independent, so omitting it fails only on Linux — with tens of
  thousands of relocation errors, not an obvious diagnostic.
- **The bootstrap pins a baseline CPU.** It keeps the host's architecture, OS,
  and ABI but does not inherit the detected CPU model. Native detection makes
  image generation depend on the build machine, and an unusual or emulated host
  can report a model the code generator rejects.
- **A header added to `abi.zig` is added to every subsystem, on every target.**
  Phase 7 Part 7 needed one function from `src/core/util.h` and translated the
  whole header to get it. That header's dynamic-library section falls through to
  `#include <dlfcn.h>` unless `JANET_WINDOWS` is defined, and it is not defined
  in the translation, so the MinGW cross-compile failed on every Zig object at
  once — including with the new selector set to `c`, since `abi.zig` is shared.
  Declare the function directly instead when it takes primitive parameters; no
  Janet type crosses, so the single-translation rule is not at stake. The
  failure is invisible on the development host, so run the Windows
  cross-compile before believing a port that touched `abi.zig`.

`-Dinstall-tests=true` installs the C contract executables and the native module
into `<prefix>/test`, which is how a cross-compiled build gets tested: `zig
build test` runs what it builds, and cannot when the target is not the host.
PLAN.md, under "Cross-platform validation without CI", has the full recipe and
the current coverage table. Copy the source tree into that container
selectively: `.zig-cache` grows to tens of gigabytes here, and copying it fills
the container VM's disk, which leaves podman unable to write the metadata it
needs to clean up after itself.

Two limitations there are worth knowing before trusting a result:

- Zig links musl targets statically, and musl's static `dlopen` is a stub that
  always fails, so the native-module test cannot run that way.
- Emulated x86-64 cannot run a NaN-boxed build, because Janet packs pointers
  into doubles and QEMU does not honor the address-space assumption that
  relies on. Use `-Dnanbox=false` there, and treat NaN-boxed x86-64 as
  untested until it runs on real hardware.

## Compiler front end

Phase 5 begins with the compiler register allocator in
`subsystems/regalloc.zig`. It replaces `regalloc.c` as a whole in target
runtime artifacts and preserves the private `regalloc.h` ABI. Pass
`-Dregalloc=c` for the C fallback. The host bootstrap continues using C, so
the target compiler component remains independent of bootstrap execution and
cross-build concerns.

The allocator uses Janet's ordinary allocator and the fatal C bridge for the
same non-recoverable allocation and invariant failures as the C version. It
does not handle Janet values or invoke compiler panic paths. Components with
recoverable parser or compiler errors need an explicit result boundary before
they can safely move to Zig.

`test/regalloc.c` exercises allocator state directly, while
`test/regalloc-bytecode.janet` fixes the compiler-visible register assignment,
slot count, and decoded bytecode for a representative function. Both are part
of `zig build test` for either implementation.

Bytecode verification is the second Phase 5 component. The default
`subsystems/verify.zig` implementation validates the existing `JanetFuncDef`
layout and preserves result codes 0 through 14; use `-Dverify=c` for the
original function in `bytecode.c`. `test/verify.c` exercises every outcome
against either provider. Because verification is read-only, allocation-free,
and result-returning, it introduces no additional error bridge.

The third Phase 5 component is bytecode no-op removal in
`subsystems/remove_noops.zig`, selectable with `-Dremove-noops=c`. It preserves
the compiler pass's relative-jump and debug-metadata rewrites while continuing
to use Janet scratch allocation. `test/remove_noops.c` compares bytecode,
source maps, local and upvalue symbol maps, and the empty symbol-map case under
both implementations.

The paired dead-write optimizer lives in `subsystems/movopt.zig` and is
selectable with `-Dmovopt=c`. It uses the selected register allocator through
the unchanged compiler-private C ABI. `test/movopt.c` covers iterative
removal, live and closure-captured slots, and instructions whose side effects
prevent removal. Together, `movopt.zig` and `remove_noops.zig` now implement
the compiler's complete post-emission bytecode optimization sequence.

Emission follows in `subsystems/emit_core.zig`, selectable with
`-Demit-core=c`: far and near register allocation, instruction emission, slot
comparison and copying, value-aware constant interning, and the nine
instruction templates. It reaches `JanetCompiler`, its current lexical scope,
and the paired instruction and source-map vectors, so it preserves the private
two-`int32_t` vector header the C front end shares through `vector.h` until
that abstraction is replaced.

Register, constant-pool, and jump-distance failures return to thin C wrappers,
which record them through `janetc_cerror`. Those wrappers are not there to defer
a `longjmp` — a compiler error sets the compile result rather than jumping —
but to keep diagnostics byte-for-byte stable and to keep representation-
sensitive constant construction in C. That distinction matters when reading the
code: a C wrapper around a Zig function means either "a signal could otherwise
cross a Zig frame" or "this constructs a Janet value", and the two call for
different care.

> *Retired by Phase 10 Part 7.* Those wrappers are gone and `emit.c` is empty.
> The reason they were needed was the seam, not the diagnostics: an error union
> cannot cross the C ABI, so the five emit shapes went through one status code
> and a C wrapper turned it back into a message. With the callers in Zig there
> is no seam to cross.

Assembly uses three independent selectors so all combinations can be tested.
`-Dasm-decode=c` covers operand decoding, sign extension, and breakpoint tuple
flags; `-Ddisasm=c` covers the metadata projections behind `disasm`, including
nested definitions; `-Dasm-encode=c` covers construction. The decoder and the
projections lock Janet's collector while Zig locals hold newly allocated
symbols and tuples, and representation-dependent wrapping stays in hidden C
helpers. The lexicographically ordered opcode table remains the single source
of instruction names in C.

The encoder is where the no-jump rule is most visible. Janet's assembler
reports errors by `longjmp`, so Zig returns an explicit result and only then
does the C driver enter the established indexed or preformatted error path.
Allocation follows a scan/allocate/fill split: Zig scans the input and reports
what is needed, C allocates (which may jump), and Zig fills the buffer.
Bytecode, constants, source maps, symbol maps, and function headers all use
that shape, and the recursive assembly call and definition-array growth stay in
C so a nested assembler jump cannot cross a Zig frame.

`subsystems/compiler_primitives.zig` (`-Dcompiler-primitives=c`) holds the
compiler layer: slots and scopes, argument lowering, return and target
selection, symbol resolution and closure capture, dead-code rollback, recursive
value dispatch, function-definition finalization, call emission, compiler error
state, and the public compilation lifecycle. It also decides macro expansion and
call policy — recognizing macro and special forms, enforcing the expansion
limit, and validating arity, `&keys`/`&named` parity, and named keys. C keeps
what it must: variadic lint and error formatting, the missing-symbol handler,
and macro-fiber execution.

> *Retired by Phase 10 Part 7.* All three came across and `compile.c` is empty.
> The lint entry point stopped being variadic rather than being ported as one,
> which is where Part 4's rule turned out to have a scope: it binds where the
> variadic *signature* is the contract, and `janetc_lintf` was internal.

Special-form bodies are in `subsystems/specials_core.zig`
(`-Dspecials-core=c`), which owns every form from `quote` through `fn` along
with the sorted name registry and its binary lookup. The C special table stays
the authoritative registry and selects C or Zig callbacks at build time, so a
name added on one side and not the other fails the lookup-parity contract.

> *Retired by Phase 10 Part 7.* `janetc_special` is exported from
> `specials_core.zig` now; the C table is behind the selector like any other C
> body. The parity contract still runs against whichever side is selected.

`subsystems/parser_core.zig` (`-Dparser-core=c`) owns the parser lifecycle,
result queue, cloning, status and error recovery, the streaming loop, stack
management, container assembly, and string, escape, Unicode, and long-string
decoding. Public `janet_parser_consume` and `janet_parser_eof` remain C
trampolines that reject a dead or unchecked-error parser before entering Zig,
and formatted delimiter and EOF diagnostics stay in C because they construct
Janet-owned strings.

> *Retired by Phase 10 Part 7.* The trampolines were there because a Zig frame
> could not raise, which Phase 10's first decision ended; they are now the
> panicking abi of two Zig entry points. The diagnostics came too, along with
> the parser's abstract type and its thirteen cfunctions, and `parse.c` is
> empty.

`subsystems/builtin_optimizers.zig` (`-Dbuiltin-optimizers=c`) holds the
builtin-function optimizer registry, arity gates, reducers, comparison chains,
indexed mutation, apply lowering, signals, and propagation. Only the
representation-sensitive construction of nil, boolean, and integer Janet values
stays in narrow C helpers.

> *Retired by Phase 10 Part 7.* Those three helpers existed because this
> subsystem translated only `compile.h` and `emit.h` and so had no
> `janet_wrap_*` of its own. Joining `abi.zig`'s single translation removed the
> detour, and `cfuns.c` — which was nothing but the three — is empty.

## Platform and standard-library services

Sixteen increments moved this layer. Four rules decided where each boundary
fell, and they are worth stating once before the increments that apply them:

- **A host structure stays in C.** Where a layout varies by platform, libc, or
  word size, Zig does not declare it, and what crosses is scalars. This kept
  `jstat_t`, `struct timespec`, `struct _finddata_t`,
  `posix_spawn_file_actions_t`, `struct sigaction`, `STARTUPINFO`, and
  `JanetTimeout` behind, and it is why several of these ports are shaped as
  kernels plus syscall wrappers rather than as whole functions. Two exceptions
  show the rule's shape rather than break it: `struct utimbuf` is declared in
  Zig because it is two `time_t` values that never cross, and a `FILE *` crosses
  freely because `FILE` is opaque by definition and so has no layout to depend
  on.

  > *Amended by Phase 10 Part 12, which is the increment decision 4 was taken
  > for.* The rule now reads: **a host structure stays in C only when
  > translate-c cannot give it to us.** Where the header translates completely
  > the structure is still libc's and Zig may name it, provided it does not
  > cross a subsystem boundary. `struct tm`, `posix_spawn_file_actions_t`,
  > `struct sigaction`, `sigset_t`, `struct _finddata_t`, `STARTUPINFO`,
  > `PROCESS_INFORMATION` and `SECURITY_ATTRIBUTES` all moved on those terms,
  > through the second translation in `src/zig/os_abi.h`. `jstat_t` and
  > `struct timespec` did not, and the reason is measured rather than assumed:
  > musl declares `timespec` with a bitfield, translate-c demotes any structure
  > holding one to `opaque {}`, and `struct stat` embeds three. `JanetTimeout`
  > stays behind on the original rule -- it is Janet's own structure, not
  > libc's -- and awaits Part 13.
- **Zig reports a position; C maps it to a value.** A name is portable and a
  host constant is not. The signal table, the `os/stat` field registry, the
  `file/seek` origins, the file watcher's three vocabularies, and the timeout
  heap's swap index all cross as an index into something C holds. This is what
  lets a table compile on every target while the values it selects stay
  `#ifdef`-gated beside the code that uses them.
- **A pointer into a garbage-collected abstract must not cross.** Established
  when `JanetFFIType` reached the layout kernels, and satisfied in the
  classifier by flattening the type tree into pointer-free nodes in scratch
  memory first. Mirroring a Janet-owned structure in Zig would be safe on layout
  grounds, so this rule is about keeping the collector's roots a C concern, not
  about representation.
- **Panic order is observable and must be replayed.** Where C interleaved
  computing, asserting, and raising, the kernel reports all three separately and
  C replays them in the original order. The file mode scanner is the clearest
  case; the FFI classifier duplicates one check in C ahead of its argument loop
  for the same reason.

Two consequences run through the whole phase. Compiling `#ifdef`-gated tables on
every target is where these ports add coverage rather than move it — the FFI's
three conventions and the file watcher's three backends were each compiled on
one host in three before — but what gains coverage is the *names*, not the
values, and saying so precisely is part of the claim. And where C left a
conversion undefined, Zig cannot: `os/sleep`, `os/touch`, the event loop's
timestamp delta, and `INT64_MIN / -1` each reproduce what the development
target's hardware already produced. That is a decision these ports make rather
than inherit, which is why no contract pins any of them.

Phase 6 begins with number scanning in `subsystems/numscan.zig`, selectable with
`-Dnumber-scan=c`. It completes `strtod.c`: Phase 4 already took
`janet_scan_int64` and `janet_scan_uint64` into `subsystems/intscan.zig`, and
this increment takes `janet_scan_number_base`, `janet_scan_number`,
`janet_scan_numeric`, and the arbitrary-precision mantissa the converter is
built on. The scanner holds no Janet values, allocates only through
`janet_realloc`, and has no non-local control flow, so it needs no signal
bridge.

Two boundaries stay in C. Wrapping a scanned value as a `Janet` is
representation-sensitive, so `janet_scan_numeric` calls hidden
`janet_c_numscan_wrap_*` helpers. And `janet_buffer_dtostr` splits along the
same reserve-in-C/fill-in-Zig line the assembler uses: `janet_buffer_extra` can
panic, so C reserves the 32 bytes and Zig formats into them.

`test/numscan.c` fixes the scanner's contract — radix prefixes and explicit
bases, hexadecimal floats, the `&` exponent, separators, denormals and
overflow, the input-length cutoff, the `:s`/`:u`/`:n` suffixes, and double
formatting — and runs against either implementation. Two of Janet's rounding
and syntax quirks are pinned there deliberately: ties round away from zero
rather than to even, and `&` exponent digits are read in the mantissa's radix.

Porting this component surfaced two defects in the C implementation, both
recorded in `FOUND.md` and neither fixed: `janet_scan_number_base` does not
validate its radix argument, and `janet_scan_numeric` wraps an indeterminate
double on the failure path.

The second Phase 6 component is the random number generator and the math
kernels, in `subsystems/math.zig` and selectable with `-Dmath-core=c`. Zig owns
the four public generator functions — `janet_rng_seed`, `janet_rng_longseed`,
`janet_rng_u32`, and `janet_rng_double` — plus `math/gcd`, `math/lcm`, the
rejection loop behind `math/rng-int`, and the byte fill behind
`math/rng-buffer`. Generator state is marshalled, so the port is bit-exact by
construction; `test/math.c` fixes exact state and output sequences rather than
statistical properties, and covers the 16-draw seed warmup, the XOR fold for
seeds longer than sixteen bytes, the all-zero correction that forces `a` to 1,
and a marshal round trip.

The `math/` C functions themselves stay in C. Their bodies are argument
extraction that panics on an arity or type mismatch, and a Janet signal must not
unwind across a Zig frame; moving them would add more bridge than logic. They
become Zig-ownable once Phase 7 replaces Janet's `setjmp`/`longjmp` control
flow. `janet_default_rng` also stays in C because it reaches into the
thread-local `JanetVM`, which is Phase 7 work, as do the generator's abstract
type, marshalling callbacks, and registration. `math/rng-buffer` uses the same
reserve-in-C/fill-in-Zig split as the number formatter.

Writing this component's contract exposed an unrelated pre-existing defect in
the C emitter, recorded in `FOUND.md`: `janetc_loadconst` casts a NaN constant
to `int32_t`. The Zig emitter ported in Phase 5 is unaffected.

The third Phase 6 component is the numeric kernels behind `int/s64` and
`int/u64`, in `subsystems/inttypes.zig` and selectable with
`-Dint-types-core=c`. Zig owns the abstract types' hash and comparison
callbacks, the polymorphic comparisons that mix 64-bit integers with doubles
and with each other, decimal formatting, and floored division and modulo. The
mixed comparisons are the substantive part: neither `int64_t` nor `uint64_t`
fits in a double without rounding, and neither integer range contains the
other, so each comparison has to choose which operand to convert after
separating out NaN, the infinities, and the out-of-range cases.

The arithmetic C functions stay in C. They unwrap Janet values, allocate
abstracts, and panic on a type mismatch or a division by zero, so they are
Phase 7 work along with the rest of the signal boundary. Formatting uses the
established reserve-in-C/fill-in-Zig split.

This port surfaced a fourth defect, recorded in `FOUND.md` and not fixed: the
`div`, `rdiv`, `mod`, and `rmod` methods do not guard `INT64_MIN` divided by
-1, though `/`, `r/`, `%`, and `r%` do. Zig cannot leave that division
undefined, so the port reproduces the development target's two's-complement
result; `test/inttypes.c` and the differential corpus both skip the case rather
than pin an outcome that is not yet decided.

The first operating-system increment is the permission conversion kernel in
`subsystems/os_permissions.zig`, selectable with `-Dos-permissions=c`. Zig
owns conversion between Janet's nine-character `rwx` form and the portable
nine-bit Unix permission value. The C wrappers retain argument validation,
Janet string allocation, and conversion between the portable value and the
host's `mode_t`; the same kernel is therefore shared by `os/stat`, `os/chmod`,
`os/umask`, `os/open`, `os/perm-string`, and `os/perm-int` without allowing a
Janet panic to cross a Zig frame.

The next OS increment is platform introspection in
`subsystems/os_platform.zig`, selectable with `-Dos-platform=c`. Zig owns the
target-derived OS, architecture, and compiler names and the result-returning
CPU-count kernel. C retains arity and keyword checks, Janet value construction,
custom `JANET_OS_NAME` and `JANET_ARCH_NAME` overrides, and the caller-provided
CPU fallback. CPU discovery is intentionally limited to the target families
where the C implementation already attempts it; in particular, macOS continues
returning the fallback rather than silently gaining new behavior. Cygwin has no
Zig 0.16 target ABI and therefore remains available only through the C
fallback, while `windows-gnu` preserves Janet's `:mingw` classification.

Environment handling follows in `subsystems/os_environ.zig`, selectable with
`-Dos-environ=c`. Zig owns environment-vector counting, splitting entries at
their first `=`, and the host `getenv`, set, and unset operations. C retains
sandbox and argument checks, the environment mutex, Janet string/table
allocation, and the caller-provided `os/getenv` fallback. In particular, C
keeps the mutex locked while it copies the borrowed `getenv` result into a
Janet string. The scanner preserves empty values, values containing `=`, and
Windows drive entries whose first byte is `=`.

Basic filesystem host operations are in `subsystems/os_fs.zig`, selectable
with `-Dos-fs=c`. Zig owns the result-returning calls behind `os/cwd`,
`os/mkdir`, `os/rmdir`, `os/cd`, `os/rename`, and `os/rm`. C retains sandbox
and argument checks, Janet value construction, `errno` diagnostics,
`os/mkdir`'s created/already-exists distinction, and all panic paths. Directory iteration, timestamps, links, and canonical path
allocation are separate boundaries, taken by `-Dos-fs-paths` below.

File metadata follows in `subsystems/os_stat.zig`, selectable with
`-Dos-stat=c`. Zig owns the classification of a host mode word into `:file`,
`:directory`, `:fifo`, `:block`, `:socket`, `:link`, `:character`, or `:other`,
the conversion between the host's permission bits and Janet's portable nine-bit
value, and the `os/stat` field registry with its keyword lookup. That registry's
order is the field identifier the C getters switch on, so `test/os_stat.c` pins
every name and index; a reordering on either side fails there rather than
silently mislabeling a field.

The `stat` and `lstat` calls themselves stay in C, along with `jstat_t` and
every getter, because the host structure's layout differs by platform and libc
and because each getter constructs a Janet value. Reproducing that layout in Zig
would duplicate a definition the C headers already provide, for no logic. This
increment does take the host `mode_t` conversion that `-Dos-permissions`
deliberately left in C, so the Windows permission collapse is now Zig-owned.

That conversion is where the port found a seventh defect, recorded in `FOUND.md`
and not fixed: the Windows direction of `janet_perm_from_unix` tests decimal
111, 222, and 444 rather than octal. Zig reproduces the decimal masks so both
implementations stay observationally identical; the effect is Windows-only and
remains unexecuted.

Host clock services are in `subsystems/os_time.zig`, selectable with
`-Dos-time=c`. Zig owns the platform clock shim behind `janet_gettime`, the
wall-clock reading behind `os/time`, and the host wait behind `os/sleep`,
including the `EINTR` retry that resumes a signalled sleep with the remaining
time. This is the first subsystem the event loop depends on: `ev.c` calls
`janet_gettime` for every deadline, so `suite-ev` and `suite-ev2` exercise it
as heavily as `os/clock` does.

Times cross the boundary as separate seconds and nanoseconds rather than as a
`struct timespec`, because that structure's layout varies by platform, libc, and
word size; `janet_gettime` stays in C as a four-line wrapper that fills the
caller's structure. This is the same reasoning that keeps `jstat_t` in C, and it
is worth preferring to redeclaring a host layout in Zig whenever the C side can
absorb the conversion. Zig still builds a `timespec` internally for its own
`nanosleep` call, using the target-specific definition in `std.c`.

Clocks cannot be pinned to fixed vectors, so `test/os_time.c` fixes invariants
instead: nanosecond ranges, real-time agreement with `os/time`, monotonic
ordering, cputime advancing, the real-time fallback for an unrecognized source,
and a sleep actually advancing a monotonic clock. On macOS the port targets
`clock_gettime`, which has been available since 10.12; the mach fallback for
older SDKs remains reachable only through `-Dos-time=c`.

Porting `os/sleep` surfaced an eighth defect, recorded in `FOUND.md` and not
fixed: `(os/sleep math/nan)` converts a NaN to `time_t`, which is undefined and
traps in a sanitized build. Zig clamps toward zero, matching what the
development target's hardware conversion already produced.

The filesystem operations that `-Dos-fs` left behind are in
`subsystems/os_fs_paths.zig`, selectable with `-Dos-fs-paths=c`: directory
enumeration for `os/dir`, the links behind `os/link`, `os/symlink`, and
`os/readlink`, the timestamps behind `os/touch`, and the canonical path behind
`os/realpath`. Each of them iterates, borrows host memory, or allocates, which
is why they needed their own boundaries.

Directory enumeration crosses as an explicit iterator — open, next, close —
rather than a callback, because C constructs a Janet string for every entry and
pushes it onto a Janet array. Both can collect, and neither may run inside a Zig
frame. `janet_os_dir_next` reports one borrowed name at a time, skipping `.` and
`..` as the C loop did, and returns 0 at the end of the stream against -1 for a
failure, since `readdir` distinguishes them only through `errno`.

Three parts of this subsystem stay in C:

- Windows directory enumeration. `_findfirst` fills a `struct _finddata_t`
  whose layout depends on the CRT's `time_t` configuration, so it falls under
  the same rule as `jstat_t` and `struct timespec`.

  > *Falsified by Phase 10 Part 12.* The rule was the right one and this was
  > the wrong structure to apply it to: mingw resolves `_finddata_t` to
  > `_finddata64i32_t` in the header, translate-c renders it completely, and
  > the `_findfirst`, `_findnext` and `_findclose` aliases come through with
  > it. The enumeration is in `os_files.zig` and is compiled on every target.
- `os/realpath`'s result release. The host allocates the path and C frees it,
  unchanged, including the POSIX/Windows difference described in `FOUND.md`.
- The link functions on Windows, which panic before reaching the host.

`struct utimbuf` is the one exception to the host-layout rule: Zig declares it,
because `utime` needs one and the structure is two `time_t` values whose type
`std.c` already defines per target. It is never shared across the boundary — C
passes the two times as doubles, and the structure lives only for the length of
the call.

A build that defines `JANET_NO_SYMLINKS` by hand should select
`-Dos-fs-paths=c`: the C fallback compiles its symbolic-link functions away,
while the Zig object always references `symlink` and `readlink`.

Porting `os/touch` found a ninth defect and reviewing `os/realpath` a tenth,
both recorded in `FOUND.md` and unfixed. The first is `os/sleep`'s undefined
conversion reached through a different argument path; establishing that Zig
reproduced the hardware's result corrected the shared saturating helper, which
had been sending a NaN to the low bound rather than to zero. `os/sleep` could
not tell the two apart, but a timestamp can.

The file layer moves next, in `subsystems/io_core.zig`, selectable with
`-Dio-core=c`. It covers two portable kernels — the `file/open` mode scanner
and the `file/seek` origin lookup — and the stream calls behind `file/open`,
`file/temp`, `file/read`, `file/write`, `file/seek`, `file/tell`,
`file/flush`, and `file/close`, along with the writes that `print`, `printf`,
and `janet_dynprintf` make to a file. C retains the abstract type and its
`JanetFile` payload, argument extraction, Janet value construction, buffer
growth, `errno` formatting, and every panic path.

`FILE` is opaque by definition, so a stream crosses as a handle rather than a
structure. That is what separates this subsystem from `jstat_t`, `struct
timespec`, and `struct _finddata_t`: nothing here depends on a host layout, and
the two host constants that do vary — `_IONBF` and the `SEEK_*` origins — stay
inside the Zig side, which is why the boundary carries a position in the
keyword list rather than a `whence` value.

The mode scanner is the one place where the boundary shape was forced by
something other than allocation. `checkflags` interleaved three effects:
accumulating flags, asserting sandbox permissions, and panicking. Only the
first is portable, and a sandbox assertion panics, so it cannot run inside a
Zig frame. `janet_io_scan_mode` therefore reports all three separately — the
flag word, the permissions the accepted prefix implies, and where the scan
stopped — and C replays them in the original order:

```c
if (status == JANET_IO_MODE_BAD_LENGTH) janet_panic(...);
if (status == JANET_IO_MODE_BAD_FIRST) janet_panicf(...);
janet_sandbox_assert(sandbox);
if (status == JANET_IO_MODE_BAD_LATER) janet_panicf(...);
```

The ordering is observable. Under a sandbox forbidding writes, `:r+q` raises
the sandbox error because the `+` asserted before the loop reached `q`, while
`:rq+` raises the invalid-flag error because it never reached the `+`. The
permissions are accumulated only over the bytes the C loop would have passed,
which is what makes a single assertion before the later-byte panic equivalent
to asserting as it went. All four sandbox permissions crossed with two dozen
mode strings produce identical output from both implementations.

Three parts stay in C. The directory check after a successful `fopen` uses
`struct stat` and falls under the host-layout rule that kept `stat` and `lstat`
in C for `-Dos-stat`. The marshalling path reaches into a
`JanetMarshalContext`, and its `dup`/`fdopen` pair has a Plan 9 spelling that
Zig has no target for; only the mode-string reconstruction it needs moved.
Buffer growth stays in C for the usual reason — `janet_buffer_extra` can
panic — so `file/read` uses the same scan/allocate/fill split as the assembler,
with `janet_io_read` filling space C has already reserved.

This port found an eleventh defect and writing its contract found a twelfth,
both recorded in `FOUND.md` and not fixed. A repeated mode flag makes
`checkflags` return -1, which its caller uses as a flag word; every bit is set,
including the closed and not-closeable bits, so `(file/open path :r++)` returns
a handle that refuses every operation while its descriptor leaks. Separately,
`file/open` reads its mode only when it has exactly two arguments, so supplying
the documented buffer size replaces the mode with read-only and skips the mode
scan entirely. Neither is inside the seam; the port reproduces the first
exactly and does not touch the second.

### Process control

`subsystems/os_process.zig`, selectable with `-Dos-process=c`, holds three
portable kernels and the scalar host calls behind `os/execute`, `os/spawn`,
`os/proc-wait`, `os/proc-kill`, `os/getpid`, `os/posix-fork`, `os/posix-exec`,
`os/posix-chroot`, and `os/shell`. This is the first increment where the host
structures, not the Janet values, decide the boundary.

Every structure stays in C. `posix_spawn` drives a
`posix_spawn_file_actions_t`, the Windows spawn drives `STARTUPINFO`,
`PROCESS_INFORMATION`, and `SECURITY_ATTRIBUTES`, and `os/sigaction` drives a
`struct sigaction` and a `sigset_t`; all fall under the rule that kept
`jstat_t`, `struct timespec`, and `struct _finddata_t` behind.

> *Retired by Phase 10 Part 12.* All five are still libc's and none of them is
> in C any more: `os_procs.zig` names them through `src/zig/os_abi.h`, and none
> crosses a boundary. What this subsystem still owns is what it always owned --
> the scalar host calls, the wait-status classification, the command-line
> escaping and the environment entry rules -- and the surface above it calls
> them across this seam exactly as `os.c` did. What crosses is
a pid, a signal number, a descriptor, and bytes. The port is therefore
deliberately shaped as kernels plus syscall wrappers rather than as whole
functions, and `os_execute_impl` still reads exactly as it did.

A wait status is the one host encoding the subsystem decodes. It is a scalar
rather than a structure, and `std.c.W` transcribes the same platform
definitions `WIFEXITED` and friends expand to, so it is read in Zig.
`janet_os_wait` reports a classification and the number that goes with it — an
exit code, a stop signal, or a terminating signal — and C adds the 128 offset
to the two signal cases and panics on the fourth outcome, because a panic may
not cross a Zig frame. The classification order is the C order: exited,
stopped, signaled, then undefined.

The signal table splits the same way. Zig holds the names and reports a
position; C maps a position to a number. The C table was `#ifdef`-gated per
signal, so a name the platform does not define was simply absent and the lookup
reported it undefined. The mapping array reproduces that with a `-1` sentinel,
which is what makes `:poll` still report `undefined signal :poll` on macOS
while resolving on Linux. `janet_os_signal_index` reproduces `janet_cstrcmp`,
including its treatment of a key whose own bytes end in NUL, exactly as
`janet_io_seek_whence` and `janet_os_stat_field_lookup` do.

Windows command-line escaping is compiled and tested on every platform even
though only the Windows spawn calls it. The rule it implements belongs to
`CommandLineToArgvW`, not to the host running the build, so a POSIX machine can
check it; leaving it Windows-only would have left the increment's largest
kernel with no coverage. It uses the measure-then-fill split, because
`janet_buffer_extra` can panic. Where the C implementation could overflow its
own `int32_t` length arithmetic, `janet_os_exec_escape_arg` returns -1 and C
raises the command-line-length panic it already had; that regime needs a
gigabyte-long argument and is unreachable in practice.

The environment kernels are split rather than unified on purpose. The POSIX
block drops a key holding `=` or NUL and the Windows block does not, so
`janet_os_env_key_ok` is called only where C called it, and
`janet_os_env_entry_fill` supplies the `key=value` layout to both. Unifying
them would have made the Windows block newly reject keys it currently accepts.

The collector's reaping wait is `janet_os_reap` rather than `janet_os_wait`,
because the C it replaces did not retry on interruption and discarded the
status; routing it through the classifying call would have added a retry the
original did not have. A failed `waitpid` is not reported either: the C
implementation ignored the result and decoded the untouched status word, which
classifies as a zero exit, and `test/os_process.c` pins that.

This port found a thirteenth defect and writing its contract found a
fourteenth and a fifteenth, all recorded in `FOUND.md` and not fixed. The
signal keyword for `SIGVTALRM` is misspelled `:vtlarm`, so the documented name
fails and the misspelling works; `signal_names` carries the misspelling
deliberately. `os/shell` given a command aborts under the event loop, because
`os_shell_subr` frees the copied command without clearing the pointer and the
default threaded callback frees it again — so the contract exercises only the
no-argument form. `os/execute` accepts the `:x` flag and ignores it without the
event loop, because the only reader of the flag is a callback that
configuration does not compile, so the contract asserts the raising behaviour
under `JANET_EV` and the ignoring behaviour otherwise.

Three things the subsystem exports are compiled but not exercised here.
`janet_os_chroot` needs privileges no test should assume, the Windows spawn
path is cross-compiled only, and the Plan 9 spellings of `fork` and `exec`
remain in C because Zig has no target for them.

### Event loop

`subsystems/ev_core.zig`, selectable with `-Dev-core=c`, is the first increment
inside `ev.c` and takes only its portable kernels: the generic queue behind
every channel and the scheduler's run list, the timeout min-heap's ordering
decisions, and the timestamp arithmetic the POSIX backends share. None of the
backends move. Nothing here holds a Janet value, touches a host structure, or
has non-local control flow; the only failure is an allocation failure, which
routes through the same fatal `janet_zig_out_of_memory` bridge the vector port
uses.

The queue is the straightforward part — a circular buffer of fixed-size items
addressed by `void *` and a stride, which is already representation-neutral. It
keeps one slot empty so that a full queue stays distinguishable from an empty
one, and its resize moves the wrapped second segment to sit against the new end.
The C originals were `static`; they are now ordinary definitions under the
shared `janet_ev_q_*` names so that exactly one of the two implementations is
compiled and `test/ev_core.c` can reach either.

The heap is where the boundary needed a decision. `JanetTimeout` carries a
`pthread_t` on POSIX and two `HANDLE`s on Windows, so it falls under the rule
that kept `jstat_t` and `struct timespec` in C, and it cannot cross. Rather than
declare it, the two kernels take a base pointer, a stride, and the offset of the
`when` field, and report an index to swap with or -1 when the heap property
already holds. C keeps the array, the `janet_vm` fields it lives in, the
`janet_realloc` that grows it, and every element move. This is the same split as
the process signal table, where Zig reports a position and C maps it: the
ordering logic is the portable content, and the structure never leaves C.
`test/ev_core.c` exercises the kernels through a local element type with padding
either side of `when`, which is what proves the stride and offset parameters are
actually load-bearing.

`janet_ev_ts_from_parts` is the millisecond conversion each of the epoll,
kqueue, and poll backends previously spelled out after calling `janet_gettime`;
sharing it is the one place this increment reduces duplication rather than
merely relocating it. `janet_ev_kqueue_interval` and `janet_ev_ts_to_parts` are
compiled and tested on every platform even though only the kqueue backend calls
them, for the same reason the Windows command-line escaping is: the rules belong
to kqueue's interface rather than to the host running the build. `timestamp2timespec`
stays in C as a two-line wrapper that fills the caller's `struct timespec` from
the parts, exactly as `janet_gettime` does for `-Dos-time`.

`janet_ev_ts_delta` separates the two infinities — negative means "already due"
and yields the timestamp unchanged, positive means "never" and yields
`INT64_MAX`. The remaining conversion is undefined in C for a NaN or an
out-of-range delay, which is the same hole `os/sleep` and `os/touch` have; the
port saturates toward zero, reproducing what the development target's hardware
already produced, and no contract pins it.

The contract covers the kernels directly and stops there. Channel ordering and
deadline ordering are covered by `test/suite-ev.janet`, which runs under the CLI
against whichever implementation the selector chose — 737 assertions, unchanged
between the two. They are deliberately *not* asserted from `test/ev_core.c`:
`ev/give`, `ev/take`, and `ev/sleep` all end in `janet_await`, and
`janet_dostring` runs a source string one top-level form at a time, draining the
event loop only after the last one. A form following a suspending form therefore
runs while the earlier one is still parked, so a channel emptied by a suspended
loop still reports its items and a trailing print emits before the loop's own
output. That is the embedding API working as designed, but it makes assertions
of that shape meaningless, and writing some was how the distinction was found.

### FFI type layout

`subsystems/ffi_layout.zig`, selectable with `-Dffi-layout=c`, is the first
increment inside `ffi.c` and takes only the type system's portable kernels: the
machine-type and calling-convention name tables, the array extent, and the
struct layout machine that assigns every field its offset. None of the calling
machinery moves — no register classification, no argument marshalling, no
trampolines. Nothing here holds a Janet value, allocates, or can fail: an
unknown name is *reported* rather than raised, so every panic stays in C and no
Janet signal crosses a Zig frame.

Neither `JanetFFIType` nor `JanetFFIStruct` crosses. Unlike `jstat_t` these are
Janet's own structures, so mirroring their layout would be safe, but each
carries a pointer into a garbage-collected abstract; keeping Zig away from that
pointer keeps the collector's roots a purely C concern. *That rule expired in
Part 16, which made the roots Zig's; the flat node form it forced did not, and
"The FFI" below says why.* C dispatches on the type
and passes the scalars that result, which is why `type_size` and `type_align`
stay in C as three-line dispatchers while the arithmetic underneath them moves.
`janet_ffi_type_info` stays in C for a different reason: it is built from the
host's `sizeof` and an `alignof` macro, so it is a host fact rather than a
portable one, and it reaches the kernels as the `el_size` and `el_align`
arguments the way the timeout heap receives a stride and an offset.

The layout machine is a running state — bytes placed, strictest alignment
demanded, and whether every field so far landed on its natural boundary —
advanced one field at a time and rounded up at the end. C holds the
`JanetFFIStruct` and writes each offset the machine reports. Splitting it this
way is what lets `test/ffi_layout.c` check the result against `offsetof` on
real C structures the host compiler laid out itself: the contract says the
machine reproduces the platform ABI, not merely its own past output. Two sweeps
over combinations of sizes and alignments then check the rules that must hold
whatever the inputs — each field on its own boundary, never before the previous
field ends, never further past it than its alignment requires — rather than a
stored expectation for each case.

Decoding a name is not the same question as whether the build can *call* that
convention, and separating the two is where this increment adds coverage rather
than moving it. `decode_ffi_cc` previously wrapped each of `win64`, `sysv64`,
and `aapcs64` in the `#ifdef` for the architecture that enables it, so on any
one host two of the three names were not merely unusable but uncompiled. The
Zig table decodes all four everywhere and `ffi_cc_enabled` in `ffi.c` — still
`#ifdef`-gated — decides which the build accepts, so behavior is unchanged while
the table itself is now asserted on every target. `default` never reaches the
table: it resolves to whichever convention the build enables, which is a
property of the target, so C maps it first.

Both enumerations the ordinals mirror are file-local to `ffi.c` and cannot be
imported, so a compile-time assertion beside them pins the ordinals to the
values the Zig port uses. Reordering either enumeration without mirroring the
change fails to compile rather than silently decoding to the wrong type.

The differential corpus generates random type trees — nested structs, arrays,
`:pack` and `:pack-all`, and a trailing `:pack` that names no member — and
compares `ffi/size`, `ffi/align`, and the exact byte image `ffi/write` produces.
The byte image is what pins the offsets: `ffi/write` zeroes the destination
before filling the fields, so the padding is visible in the output. It found no
difference between the two selectors, and two pre-existing defects recorded in
`FOUND.md`: packed struct fields are read and written through misaligned
pointers, and a nested array type silently discards the inner count. The first
is why the byte-image half of the corpus runs in ReleaseFast — under the
sanitizer the misaligned store aborts before the comparison can happen.

### FFI calling conventions

`subsystems/ffi_classify.zig`, selectable with `-Dffi-classify=c`, is the second
increment inside `ffi.c` and takes the part of the calling machinery that is
pure decision: for each of the three conventions, which class a type belongs to
and which register or stack slot each argument lands in. Marshalling and the
trampolines stay in C. Nothing here holds a Janet value, allocates, or raises —
an argument the convention cannot place is *reported*, and `ffi.c` panics.

The classifier needs to walk a type tree, and `JanetFFIType` carries a pointer
into a garbage-collected abstract, which by the rule established in the layout
increment must not cross. So C flattens the tree first: `ffi_serialize_type`
writes it into a pre-order array of `JanetFFITypeNode`, each node a few integers
and no pointers, in scratch memory that is freed as soon as the classifier
returns. A flat list of *leaves* would have been simpler and is not enough —
SysV classification consults each nested struct's own `size` and `is_aligned`,
not just the primitives underneath it — so the shape has to survive, and it
survives as a field count per node plus a `skipSubtree` walk.

Allocation follows the pattern the other host-facing subsystems use: Zig reports
a position and C maps it. Each convention's allocator fills a
`JanetFFIAllocResult` — the stack word count, the trampoline variant, and an
error kind with the offending argument's index — and `ffi_check_alloc` turns the
error kinds into the panics they were. Panic *order* is preserved deliberately
rather than incidentally: the SysV void-parameter check stays inside the C
decode loop so it still fires from the argument that caused it, and the AAPCS64
oversized-return check is duplicated in C ahead of the argument loop because the
original raised it before decoding anything. The allocator's own copy of that
check remains, unreachable in practice, asserted by the contract.

The coverage this adds is the same kind the layout increment added to the name
tables, and larger. In C each convention sits inside `#ifdef
JANET_FFI_{WIN64,SYSV64,AAPCS64}_ENABLED`, so on any one machine two of the
three were never compiled, let alone tested — a change to the SysV classifier
made on an ARM64 machine was not even syntax-checked. All three now compile
everywhere and `test/ffi_classify.c` asserts all three on every target;
`ffi.c` keeps the `#ifdef`s, which now decide only which convention may be
*called*. Apple's AAPCS64 divergence — stack arguments packed at natural
alignment rather than rounded up to eight — was a compile-time `#if
defined(JANET_APPLE)` and is now an `apple_abi` parameter, so both variants are
reachable and asserted from any host.

`JanetFFIWordSpec` is file-local to `ffi.c` like the type enumerations before
it, so a second compile-time assertion pins all nineteen of its ordinals beside
the declaration. Reordering it without mirroring the change fails to compile.

This increment found five defects, all recorded in `FOUND.md`, all pre-existing,
and the most serious set the migration has produced. `ffi/signature` fills a
fixed 32-entry array with no upper arity check, so a signature built from a
computed list overruns the frame and kills a release build, with no native call
anywhere in reach. AAPCS64 sizes a homogeneous float aggregate by bytes rather
than by members. Integer arguments narrower than a register are stored at their
own width into an uninitialized array, so every `:s8`, `:u8`, `:s16`, and `:u16`
argument reaches its callee with stack residue in the high bits. AAPCS64
classification reads the first field of a struct that may have none. And SysV
pair classification drops a field that classified as memory, where the merge
rule one branch over propagates it. Only the fourth is inside the kernels this
increment took, and it is guarded here with a documented divergence; the rest
are in the marshalling layer or the signature builder, both of which stay in C.

Beyond the contract, the conventions were checked by calling real C. A shared
library of forty deliberately awkward signatures — register exhaustion in both
banks, narrow integers, small and large and nested aggregates, homogeneous
float aggregates, struct returns, and a by-reference return competing with a
full register file — folds each function's arguments into one position-weighted
number, so a misplaced argument shows up as a wrong number rather than a crash.
Twenty-nine of the thirty-two results are deterministic and byte-identical
across the pristine C at `HEAD`, the `c` selector, and the `zig` selector. The
other three are nondeterministic on `HEAD` too, which is itself a finding: they
are the float-HFA case recorded in `FOUND.md`, where the ABI wants one register
per member and the allocator gives one per eight bytes, leaving a register
unwritten. The baseline was taken against a `git worktree` at `HEAD` rather than
against the `c` selector alone, because the serializer is shared by both
selectors and a bug in it would cancel out of a Zig-versus-C diff.

The AAPCS64 path is exercised by real calls on the development host; the SysV
path is not, since nothing on this machine can call it. It runs its contract
under emulated x86_64 Linux, which is the first time that classifier has
executed at all, but end-to-end SysV calls remain unvalidated here.

*Superseded by Part 16.* An `x86_64-macos` build runs under Rosetta on Apple
silicon, so the whole runtime -- suites, contracts and real FFI calls --
executes SysV64 on this machine now. "The FFI" below has it, and two matrix
entries drive it.

### File watcher vocabularies

`subsystems/filewatch_flags.zig`, selectable with `-Dfilewatch-flags=c`, holds
the keyword vocabularies that `filewatch/new` and `filewatch/add` accept: the
inotify names on Linux, the `ReadDirectoryChangesW` names on Windows, and
kqueue's `NOTE_*` names on the BSDs and macOS.

Only the names moved. Every flag's value is a host constant, so `filewatch.c`
keeps a value array per backend in the same order and indexes it with what the
lookup reports. The two halves are one table split down the middle, joined by
the index, which is why the order is a contract asserted from both sides rather
than a convenience. Nothing in the subsystem allocates or can fail; a name that
matches nothing is reported as `-1` and the panic stays in C, where it can say
which keyword was wrong.

The coverage this adds is the same kind the FFI conventions added. In C each
table sat inside the `#ifdef` for its own backend, so on any one host the other
two were not merely unreachable but uncompiled — a typo in the Windows
vocabulary could survive every Linux and macOS build indefinitely. All three now
compile everywhere, and `test/filewatch_flags.c` asserts all three on every
target. It is worth being exact about what that buys: the *names* are checked
everywhere now, the *values* still only where their backend compiles.

The split is also what lets the C fallback exist. A `-Dfilewatch-flags=c` build
implements the same four functions over three name tables which, being strings
rather than host constants, likewise compile everywhere. Without separating
names from values there would be nothing for the `c` selector to answer with on
a host whose headers lack the other backends' macros.

Two conventions are worth noting. The BSDs do not all define the same `NOTE_*`
set, and where the original omitted an entry from the table, C now stores a zero
that the decoder refuses for that name — the same answer by different means.
And Windows' `FILE_ACTION_*` lookup reports absence for a code outside the
documented range instead of indexing a six-entry array with whatever arrived,
so `filewatch.c` names the `unknown` fallback explicitly.

Both reverse lookups — the ones that turn an event mask back into a keyword —
moved to the same tables. The Linux one gained an explicit zero check, because
it matches with `(mask & flag) == flag` and a zero under the absent-constant
convention would match every mask rather than none. Every inotify constant is
defined, so this changes no behavior on any host; it keeps the convention from
becoming a trap if one ever is not.


## The growable containers

Phase 8 Part 6a. `-Dbuffer-array=c` restores the C implementation; Zig is the
default. `buffer_array.zig` owns the data-structure core of `core/buffer.c` and
`core/array.c`: the constructors, the capacity policy, and the push and pop
primitives. Twenty-three exported symbols, 385 lines of Zig against 265 lines
of C.

### Why buffer and array are one increment, and where Part 6 splits

Part 6 is "the containers", which is about a thousand lines of C across seven
files — too much to take in one step, and the collector had already shown what
a good split looks like. Parts 3 to 5 divided `gc.c` by data structure rather
than by call graph, and the parts came out independent because each data
structure was touched at one end by exactly one of them. The same test applied
to the containers gives three groups:

  - **Buffer and array**, this increment: one data structure with two element
    types. Both are a `JanetGCObject` header followed by `count`, `capacity`
    and `data`, both keep the payload in a separate `janet_malloc` block that
    grows in place, and neither calls the other.
  - **String, symbol and the symbol cache, and tuple**: the immutable
    head-allocated sequences, where the payload is part of the block, the hash
    is computed once at construction, and `janet_symbol` interns through
    `janet_vm.cache`.
  - **Struct and table**: the key/value containers, which share the `JanetKV`
    layout and the Robin Hood probing over it.

The last group is one increment rather than two because struct and table are
mutually recursive — `janet_struct_to_table` calls `janet_table_put`, and
`janet_table_to_struct` calls `janet_struct_begin`, `janet_struct_put` and
`janet_struct_end` — so no boundary can be drawn between them. That is a
correction to the grouping `PLAN.md` used to suggest, which paired tuple with
struct and left table alone; the pairing that survives contact with the call
graph is the one above.

### The standard-library half of each file stays in C

Every one of these files is two files stapled together: a data-structure core,
and a block of `JANET_CORE_FN` bodies that expose it to Janet. Only the core
moves. That is not a new decision — no Zig subsystem in the tree exports a
cfun-shaped function, and `io.c` and `os.c` were guarded the same way — but
Part 6 is the first time the two halves live in the same short file, so it is
worth naming. The cfuns reach the ported code through the same public API an
embedder uses, and Phase 8's exit gate is about value construction rather than
about the standard library.

### One seam, and it is a declaration

`cfun_buffer_trim` calls `janet_buffer_can_realloc`, which was `static` in
`buffer.c` and belongs to the half that moved. So it is exported from
`buffer_array.zig` and declared in `util.h`, beside `janet_buffer_push_types`
and `janet_buffer_dtostr` — the cross-file buffer helpers that already live
there. Three words, the same shape as Part 3's `janet_free_all_scratch`.

The alternative was to leave a private copy in C and write a second one in Zig.
It is four lines, so the duplication would have been cheap, and it was still
the wrong call: the function is a policy — *a buffer that does not own its
memory may not be reallocated* — and a policy in two places is a policy that
drifts. Nothing else crossed. `safe_memcpy` is declared directly under the
standing `util.h` rule, and everything else the file reaches for is public API,
`janet_vm`, or the `janet_zig_out_of_memory` bridge.

### The first subsystem that panics for ordinary reasons

`buffer_array.zig` is jump-transparent, and unlike the three collector files it
is not an exotic case. Three functions call `janet_panic` directly — the
realloc guard, `janet_pointer_buffer_unsafe`'s argument checks, and
`janet_buffer_extra`'s overflow check — and `janet_gcalloc` can trigger a
collection, which runs finalizers, which SPIKE-8 permits to raise. A signal
from any of them unwinds through these frames.

What makes that safe is a property of where the panics are rather than of the
frames themselves: **every panic here happens before the allocation it guards**.
`janet_buffer_can_realloc` runs before the `janet_realloc` it protects, and
`janet_buffer_extra` checks for overflow in its first statement. So no frame
below ever holds a raw block between acquiring it and storing it somewhere the
collector can see, which is the one shape a skipped cleanup turns into a leak.
`build.zig` still checks for `defer`, and planting one produces the expected
refusal.

### Part 5 frees what Part 6a allocates

`janet_deinit_block` in `gc_sweep.zig` calls `janet_buffer_deinit` from this
file for a buffer, and frees an array's `data` directly. So the two increments
form a round trip inside Zig: this file allocates the payload, that one releases
it, and the C originals are no longer involved on either end. The contract test
drives one collection over ten of each container to exercise it in both
directions.

### The capacity policy is a contract, not an implementation detail

Both containers overshoot by a caller-supplied growth factor, and the resulting
capacity is observable — `array/ensure` puts it in the hands of Janet code. So
`test/buffer_array.c` asserts exact capacities rather than lower bounds, along
with three differences between the two files that look like oversights and are
preserved as-is:

  - The buffer has a capacity floor of four bytes and the array has none, so
    `janet_array(0)` really does have a null payload.
  - `janet_buffer_ensure` charges GC pressure before its `janet_realloc` and
    `janet_array_ensure` charges it after.
  - `janet_array_n` charges no pressure for the payload it allocates.

None of the three is a defect — both `ensure` variants exit on allocation
failure, so nothing observes the ordering — but all three are observable, and
pinning them is what stops the two selectors drifting on an accounting term
nothing else would catch.

### What the growth factor does when it is not positive

`FOUND.md` gained an entry here, and it is the first one in Phase 8 that is
reachable from pure Janet with no embedding involved. `cfun_array_ensure`
validates its count and passes its growth factor through untouched, and
`janet_array_ensure` guards only the top of the range:

```c
int64_t new_capacity = ((int64_t) capacity) * growth;
if (new_capacity > INT32_MAX) new_capacity = INT32_MAX;
capacity = (int32_t) new_capacity;
newData = janet_realloc(old, capacity * sizeof(Janet));
```

A growth of zero frees the backing store and leaves `count` alone, so every
element the array claims to hold becomes a read of freed memory — silently, with
the value still circulating. A negative growth converts to a `size_t` near the
top of the range, fails to allocate, and ends the process through
`JANET_OUT_OF_MEMORY`, which is not a Janet error and which `protect` cannot
catch. Both are left unfixed under the standing rule and reproduced exactly.

Reproducing them is why the arithmetic in this file uses wrapping operators and
an explicit `asSize` conversion rather than `@intCast`. C converts a negative
`int32_t` to `size_t` silently and then dies in the allocator; Zig would trap
one statement earlier, on the conversion, which is a different failure in a
different place. Replacing `asSize` with `@intCast` is one of the mutations the
contract test catches, and it catches it exactly there.

The zero case turned out to be platform-dependent, which is why the test probes
before asserting it: `realloc(p, 0)` returns a minimal block on macOS and NULL
on glibc, and the second answer reaches `JANET_OUT_OF_MEMORY` like the negative
case. The negative case is not covered by any test on any platform — it dies
inside the allocator on the next line — and the test file says so rather than
implying otherwise.


## The immutable head-allocated sequences

Phase 8 Part 6b. `-Dstring-symbol=c` restores the C implementation; Zig is the
default. `string_symbol.zig` owns the data-structure core of `core/string.c`,
the whole of `core/symcache.c`, and the three constructors in `core/tuple.c`.
Sixteen exported symbols, 468 lines of Zig against 285 lines of C.

### One allocation strategy, three types

A buffer or an array is a fixed-size block pointing at a payload that can be
reallocated. A string, a symbol or a tuple is a header and its payload in a
single `janet_gcalloc`, sized once and never resized — which is what
"immutable" means to the runtime, and what gives all three the same three
properties:

  - **The head is recovered by pointer arithmetic.** The value Janet passes
    around is the address of the payload, so every operation subtracts the
    header size. `gc_sweep.zig` already did this on the free path; this file
    does it on the construction path, and `test/string_symbol.c` pins
    `sizeof == offsetof(…, data)` for both heads from C, which is the assumption
    the Zig cannot state for itself.
  - **The hash is written once, at the end of construction.** `janet_string_begin`
    and `janet_tuple_begin` leave it uninitialised; `janet_string_end` and
    `janet_tuple_end` fill it in. A value observed between the two has an
    indeterminate hash, and the port does not helpfully zero it.
  - **Symbols are interned**, which is `janet_string` plus a lookup in
    `janet_vm.cache`.

Tuples ride along rather than forming a group of their own: `tuple.c`'s core is
three functions and twenty-five lines, each of them the string pattern with
`Janet` in place of `uint8_t`.

### No seam at all

6b is the first increment since Part 4 to need nothing. Every function that
moved is either public API in `janet.h` or declared in `symcache.h`, and every
`static` in the three files moved with its callers — `symcache.c` moved whole,
so its five statics and its tombstone never crossed anything. No header
changed, and the C diff is three `#ifndef`s.

Four `util.h` functions are declared directly, and one of them widens the
standing rule enough to say so. `safe_memcpy`, `janet_string_calchash` and
`janet_tablen` take primitive parameters, which is the usual justification.
`janet_array_calchash` takes a `const Janet *`. The single-translation rule is
still satisfied — the `c.Janet` in the declaration is the shared translation's
type, not a second one — but the reason usually given, that no Janet type
crosses, no longer applies. What applies instead is that hashing belongs to
`value.c` and moves in Part 7; until then this is the only way to reach it.

### The symbol cache is the collector's one external obligation

Everything else the collector frees is self-contained. A symbol is not: it is
registered in `janet_vm.cache` at construction, and freeing it without removing
it would leave the cache pointing at released memory for the next symbol that
hashed to that bucket to compare against. So `janet_deinit_block` in
`gc_sweep.zig` calls `janet_symbol_deinit` — which is why Part 5 needed a
declaration for it, and why that declaration now resolves to Zig at both ends.

The cache is open-addressed with tombstones, and two of its properties are worth
naming because neither is obvious and both are pinned by the contract test:

  - **A successful lookup rewrites the table.** If the key is found *after* a
    tombstone, it is moved back into the tombstone's slot and its old slot
    becomes one. Without it, a table that has churned degrades toward a full
    scan per lookup. The test finds a colliding pair of names rather than
    assuming one, so it can watch a symbol change position while keeping its
    address.
  - **Tombstones count toward the load factor.** A symbol created and
    immediately collected leaves the live count where it was, so counting only
    live entries would let tombstones accumulate without bound until no empty
    slot remained.

The tombstone itself is compared by address and never dereferenced.
`symcache_deleted` is declared `var` rather than `const` for that reason: a
single zero byte is exactly the sort of object a linker may merge with an
identical constant elsewhere in the image, and a merged tombstone would alias
something that is not one.

### What is reproduced rather than repaired

`janet_cache_resize` re-inserts the old entries and `break`s out if one reports
the key was already present or returns no bucket. Neither can happen, and the
recovery is worse than the condition — it abandons every remaining entry while
still freeing the old table. Preserved as written.

The second is a new `FOUND.md` entry, and it is reachable. `janet_symcache_findmem`
aborts the process when the table is full, and the load factor that is supposed
to prevent that permits `capacity / 2 + 1` entries — below capacity for every
capacity of four or more, and *equal* to it at two. A rehash chooses a capacity
of two when `cache_count` is zero, and `janet_init` leaves it at zero, because
the core environment is built lazily by `janet_core_env` rather than at
initialization.

A probe reached it: 513 transient symbols — the exact maximum
the load factor allows, which is why a fixed count usually misses — then one
collection, then three more symbols.

```text
after a collection: count=0 deleted=513 capacity=1024
interning survivor-0 ...
  ok: count=1 deleted=0 capacity=2
interning survivor-1 ...
  ok: count=2 deleted=0 capacity=2
interning survivor-2 ...
janet abort at src/core/symcache.c:113: symcache failed to get memory
```

`janet_assert` expands to `JANET_EXIT`, so this is an `abort()` rather than a
Janet error and `protect` does not see it. Loading the core environment hides it
completely, which is why the `janet` binary is unaffected and a host using
Janet's data structures without its standard library is not. Left unfixed, and
the port reproduces both the policy and the exit. The contract test does not
assert this one — the assertion would have to end the test process.

### What the contract test had to be rebuilt around

Three assertions in the first draft passed for the wrong reason, and mutation
testing is what found them. They are worth recording because the same traps sit
in front of Part 6c.

**A terminator on a fresh block.** `janet_string_begin` writes a zero one byte
past the length, and asserting `s[length] == 0` on a freshly allocated block
proves nothing if the block arrived zeroed. Whether it does is a property of the
C library rather than of Janet: macOS zeroes small allocations and leaves large
ones alone; glibc leaves both. The test now fills the free list with 0xFF blocks,
*checks whether they come back that way*, and asserts only when the answer makes
the assertion mean something.

**A rejection that never reached the clause being tested.** `janet_string_equalconst`
checks the hash, then the length, then the bytes — but the hash mixes the length
in, so almost every mismatched argument is rejected by the hash before the other
two run. Both were dead code that no test distinguished. They are reachable
through the public API, though, which is what the test now does: pass the hash
`lhs` actually has, and vary only the thing under test.

**A test that set up its own precondition.** The gensym odometer test resets
`janet_vm.gensym_counter` so the sequence is predictable, which also overwrote
the only observable evidence of what `janet_symcache_init` puts there. A
separate test now runs first, before the reset.

One mutation was equivalent rather than surviving: moving `inc_gensym`'s loop
to start one position later changes the counter's last byte, which is never part
of a name — the name is the first seven of eight bytes and the eighth is
overwritten by the terminator. Twenty-nine others were each caught by a named
assertion.

## The key/value containers

Phase 8 Part 6c. `-Dstruct-table=c` restores the C implementation; Zig is the
default. `struct_table.zig` owns the data-structure core of `core/struct.c` and
`core/table.c`, including the three weak table variants. Twenty-nine exported
symbols, 716 lines of Zig against 430 lines of C.

### Struct and table are one increment because nothing separates them

The grouping this part inherited from the plan was "tuple and struct, table",
and the call graph does not support it. `janet_struct_to_table` calls
`janet_table_put`; `janet_table_to_struct` calls `janet_struct_begin`,
`janet_struct_put` and `janet_struct_end`. They are mutually recursive across
the file boundary, they share the `JanetKV` bucket layout, and each is the
other's conversion target. Tuple has nothing in common with struct beyond
immutability, which is why it went to 6b with the other head-allocated
sequences.

### One layout, two probing disciplines

It is tempting to read "struct" as "immutable table" and expect one probe loop.
They are not the same algorithm, and that is why `janet_struct_find` exists
beside `janet_dict_find` rather than calling it.

  - **A table probes linearly and carries tombstones.** A removal leaves a nil
    key with a *false* value, and `janet_dict_find` stops only where key and
    value are both nil. The hole therefore does not truncate a probe run
    through it. Table layout depends on deletion history as well as insertion
    order, and nothing observable depends on table layout.
  - **A struct probes Robin Hood and has no tombstones.** Nothing is ever
    removed, and the ordering rule makes the final layout a function of the
    *set* of pairs rather than of the order they arrived in. That is not an
    optimisation: `janet_struct_end` hashes the bucket array, so two structs
    built from the same pairs in different orders must lay out identically or
    `{1 2 3 4}` would not equal `{3 4 1 2}`.

So `janet_struct_find` is the simpler loop despite the harder insert — with no
tombstones, the first nil key really is the end.

### The tiebreak chain is three deep, and the last link leaves the file

Displacement, then full hash, then `janet_compare` on the keys. The first two
are cheap to believe; the third is the one worth naming, because it is what
makes the order *total* and therefore what makes the layout well defined.

Two keys reach it whenever they want the same bucket, sit at the same
displacement, and have the same 32-bit hash. That is not exotic: `janet_hash`
reads only the bytes for all three string-like types, so `:tie` and `"tie"`
have the same hash and are not equal. Without `janet_compare` the two would
compare as duplicates and the second would be silently dropped.

This also makes 6c the increment SPIKE-8 was written for. Every other Phase 8
increment inherited the spike's decision without exercising it; this one calls
`janet_compare` and `janet_equals` on arbitrary keys, either of which reaches a
third-party abstract type's callback. Under SPIKE-8 such a callback may not
raise, and if one does the signal jumps straight through these frames. There is
no `defer` in the file and `build.zig` checks that there is not.

One consequence is worth naming rather than leaving to be found.
`janet_table_rehash` publishes the new bucket array into `t->data` before it
re-inserts, and holds the old one only in a local, so a signal raised out of a
key comparison during that loop leaks the old array and leaves the table
holding a partially populated new one. The C does the same. Nothing is
restructured to survive it, because surviving it is not the promise.

### The count lives in the hash field during construction

`janet_struct_begin` sets `hash` to zero and every `janet_struct_put` that
fills an empty slot increments it. The field is a running count until
`janet_struct_end` overwrites it with the real hash, which is also how `put`
enforces the declared length — it returns early once the count reaches
`length`, so a struct built with more pairs than it was begun with silently
drops the surplus. A struct observed between `begin` and `end` has a hash that
is a count, and the port preserves that rather than helpfully separating the
two.

### Two seams, and both are declarations that should already have existed

`janet_struct_put_ext` and `janet_table_proto_flatten` are not `static`, and
neither has ever been declared in a header. Each was reached from the
`JANET_CORE_FN` half of its own file, below its own definition, so C never
needed one. Once the definition moves to Zig the call site has nothing to
resolve against, so both are now declared in `util.h` beside
`janet_table_get_keyword` — the same shape as Part 6a's
`janet_buffer_can_realloc`.

Everything else that moved is public API in `janet.h`, and the four statics
(`janet_memalloc_empty_local`, `janet_table_init_impl`, `janet_table_rehash`,
`janet_table_put_no_overwrite`) moved with every one of their callers.

Six functions are declared directly rather than imported, which is more than
any previous increment: `safe_memcpy`, `janet_tablen`, `janet_kv_calchash`,
`janet_dict_find`, `janet_dict_find_keyword`, `janet_memempty` and
`janet_memalloc_empty`. Three of them take a `JanetKV *` or a `Janet`, widening
the rule the same way Part 6b's `janet_array_calchash` did. The reason not to
move them is that they belong to files this increment does not open:
`janet_dict_find` is also `value.c`'s indexing helper and goes with Part 7, and
the last two live in `wrap.c` beside the representation-dependent constructors.

### What is reproduced rather than repaired

Four entries, all in `FOUND.md`, and three of them were found by the contract
test on its first run against the C original.

**A zero-capacity table cannot be looked up in.** `janet_maphash` masks with
`capacity - 1`, all ones here, so `janet_dict_find` uses the whole hash as a
bucket index and both its loops are bounded by that rather than by the
capacity. Only a hash of exactly zero survives. `janet_table(-1)` is the only
way to reach it, so it needs a C API caller. `FOUND.md` has it.

**`janet_table_proto_flatten` does not bound the prototype chain**, where every
other walk in the file uses `JANET_MAX_PROTO_DEPTH`, so `(table/proto-flatten
t)` on a cycle spins forever. Reachable from Janet source with no embedding,
and confirmed identical under `-Dstruct-table=c`.

**The tombstone-retiring branch in `janet_table_put` is dead.**
`janet_dict_find` prefers a truly empty bucket and returns a remembered
tombstone only when there is none, and the load factor guarantees one exists.
So a rehash is the only thing that ever reclaims a tombstone, and re-inserting
a key that was just removed leaves its hole behind and takes the next slot.

**`janet_table_clone` uses plain `memcpy`** where `safe_memcpy` exists for
exactly this case. The port departs here and uses `safe_memcpy`, on the same
grounds as `janet_checksize`: Zig cannot form a zero-length slice from a null
pointer without going out of its way to reintroduce undefined behaviour that
has no observable effect.

### What the contract test had to be built around

Two traps, and both are worth carrying forward.

**Order-independence does not pin the direction of the displacement rule.**
Inverting the comparison consistently still produces a layout that is a
function of the pair set, so the obvious test — build the same struct three
ways, compare — passes against a reversed implementation. Mutation testing
caught it. What pins the direction is a run of keys that all want the same
bucket, where every displacement comparison ties and the full hash decides: the
larger hash keeps the earlier slot. The keys are searched for rather than
hard-coded, because the integer hash changes outright under `-Dprf`.

**`memcmp` is not available for a layout comparison.** Under `-Dnanbox=false` a
`Janet` is a struct with an eight-byte union and a four-byte type tag, so it
carries four bytes of tail padding that nothing ever writes. Two identical
values compare equal and differ byte for byte. The first draft used `memcmp`
throughout, passed under the NaN-boxed default, and failed on allocator garbage
under tagged values. `same_layout` compares position by position instead.

Twenty-one mutations were run against the Zig side; twenty were caught by a
named assertion. The survivor is equivalent rather than surviving: sizing
`janet_table_to_struct`'s result from the table's capacity rather than its
count produces an identical struct, because `janet_struct_end` rebuilds
whenever the pairs that landed do not fill the declared length. It costs one
extra allocation and changes nothing observable.

### What this cost

No new C beyond two header declarations, and 430 lines of C guarded out. Both
selectors pass every suite and contract on macOS ARM64 across four optimize
modes, tagged values, keyed hashing, single-threaded, `-Dcall-trampoline=true`,
and seventeen feature flags disabled individually; both cross-compile for
aarch64 and x86-64 Linux musl and Windows x86-64 MinGW; and both run 45
contract binaries and 34 suites natively on aarch64 Linux musl.

## Hashing, equality and ordering

Phase 8 Part 7a. `-Dvalue-order=c` restores the C implementation; Zig is the
default. `value_order.zig` owns `janet_hash`, `janet_equals` and
`janet_compare` from `core/value.c`, together with the non-recursive traversal
stack the last two share. Three exported symbols, 540 lines of Zig against 297
lines of C.

### Three functions, one contract

Not because they read alike — `janet_hash` is a flat switch with no traversal
in it at all. They are one increment because they are one contract. A hash
table needs `janet_hash` and `janet_equals` to agree; a struct needs
`janet_compare` to totally order whatever `janet_hash` collides. Part 6c is the
proof: its Robin Hood insert breaks a displacement tie by full hash and then by
`janet_compare` on the keys, and that last link is load-bearing rather than
defensive, because `janet_hash` reads only the bytes for all three string-like
types — so `:tie` and `"tie"` collide and are not equal. Splitting these three
across increments would produce a configuration in which half of that agreement
is Zig and half is C, which is a differential test whose failures point
nowhere.

### Where `value.c` splits, and why the guard has two regions

Part 7b takes the rest: `janet_next` and `janet_next_impl`, and the indexed and
keyed accessors from `getter_checkint` down. The split costs nothing to make,
because every helper in the file is `static` and every one of them is used by
exactly one half. `push_traversal_node`, `traversal_next`,
`janet_compare_abstract` and `murmur64` belong to this increment;
`getter_checkint` belongs to the accessors. Both halves are closed over their
own privates.

`janet_next` sits physically between them, which is why `value.c` carries two
`JANET_ZIG_VALUE_ORDER` regions rather than one. Nothing was moved to make them
contiguous. A reordered C file is a permanent diff against upstream that buys
only tidiness, and the guard is not confusing when it is two `#ifndef` blocks
with a function between them.

### No seam at all

The third increment in the phase to need none, after Parts 4 and 5, and for the
same reason 6b needed none: everything that moved is already public API. The
four helpers are `static` and left the file with their callers.

### The traversal stack is the shape, not an optimisation

`janet_equals` and `janet_compare` are written as a loop over an explicit stack
in `janet_vm`, not as recursion, because a tuple or struct may nest to any
depth a parser will accept and a C stack overflow is not a catchable error.
That constraint applies to the port unchanged, so the port keeps the shape
rather than the meaning: same stack, same growth policy, same node layout, same
four return codes. A Zig rewrite as recursion with a depth guard would be a
different function with different limits.

Three things about that stack are easy to misread and all three are
load-bearing:

  - **The stack pointer addresses the top element, and the base slot is never
    used.** `push_traversal_node` pre-increments before storing and
    `traversal_next` walks while `t > traversal_base`. One slot at the bottom
    is permanently dead, which is also what makes the empty test cheap.
  - **Neither entry point pops what it pushed.** Each resets `traversal` to
    `traversal_base` on entry and leaves whatever it pushed behind on an early
    return. The stack is scratch owned by whichever comparison is running,
    never state that survives one — which is why an early return needs no
    unwinding, and why these two may not be re-entered.
  - **The prototype hop rewrites the top of the stack rather than pushing.**
    When a struct's buckets are exhausted and both sides have prototypes,
    `traversal_next` sets `traversal = t - 1` and hands the two prototypes back
    as the next pair; the caller's own loop pushes a fresh node for them.
    Written as a push it would grow the stack by one per level of prototype
    chain for no reason. `test/value_order.c` pins this on the array's
    *capacity* after comparing two five-hundred-level chains, because a
    successful comparison ends with the pointer back at the base and the depth
    afterwards says nothing.

### SPIKE-8 applies directly, and twice over

Both entry points reach a third-party abstract type's `compare` callback
through `janet_compare_abstract`, and `janet_hash` reaches its `hash` callback.
Under SPIKE-8 such a callback may not raise, and a signal from one that does
jumps straight through these frames. There is no `defer` here and `build.zig`
checks that there is not. What a jump would strand is the traversal array's
*contents*, never the array itself: the array belongs to `janet_vm` and the
next comparison resets the pointer over whatever was left. That is the reason
the reset lives at the top of each entry point rather than at the bottom.

These three are also on the VM call path — `run_vm` calls `janet_equals` and
`janet_compare` directly — which is the constraint `-Dcall-trampoline` stays
off for through this phase, rather than an independent one.

### What is reproduced rather than repaired

**A re-entrant `compare` callback corrupts the comparison that called it.**
There is one traversal stack per VM and both entry points reset it, so a
callback that compares anything — or looks anything up, since
`janet_table_get` reaches `janet_equals` through `janet_dict_find` — destroys
the state of the comparison that invoked it. The outer `janet_compare` then
sees an empty stack, takes it for a finished traversal, and returns
`status - 2`, which is zero: two values that differ are reported equal. No
sanitizer fires and nothing crashes. `FOUND.md` records it, with the
demonstration. `janet_equals` has the same hole and is shielded
from it in practice, because it compares stored hashes before pushing anything
and so only ever traverses values that are equal. Nothing in the tree
re-enters, so this needs an embedder or a native module with a comparator.

**`janet_compare` is not an ordering on NaN.** Both `==` and `<` are false, so
it returns 1 whichever way round the arguments are. The C comment above the
function says "excepts NaNs" and this is what that means. Pinned by the
contract test rather than repaired.

`traversal_next`'s key-returning branch is written in the C original as a `for`
loop whose body returns unconditionally on its first iteration, so the
induction variable is read once as a bound and never incremented. It is an `if`
spelled as a `for`. The port writes the `if`: reproducing a typo is not
reproducing a behaviour, and the contract test pins that the two are the same
function of the same inputs. That branch also walks every *bucket* of the
struct rather than every entry, so nil keys of empty buckets are compared
alongside real ones. That is correct rather than sloppy, for a reason Part 6c
established — a struct's layout is a function of the set of pairs — and
`janet_compare` has already rejected a capacity mismatch before any node is
pushed.

`janet_hash`'s pointer fallback reads the raw payload word through `janet_u64`,
whose spelling differs per value representation: `x.u64` for both NaN-boxed
layouts, where `Janet` is a union, and `x.as.u64` for the tagged one, where it
is a struct. `janetU64` selects on whether the translated type has the field
directly, which gets all three without restating the `#ifdef`. The consequence
is deliberate in the original and preserved: a pointer's hash is not the same
number across representations, because the NaN-boxed word carries the type tag
and the tagged one does not.

### What the contract test had to be built around

**`janet_equals` almost never traverses.** It compares the stored hashes of two
tuples or two structs before it pushes anything, and for values that differ
those essentially always disagree. So the only inputs that get `janet_equals`
into the traversal are ones that are *equal*, which then run to completion.
Every observation about a partly-consumed stack is therefore made through
`janet_compare`, which has no such exit because an ordering cannot stop at
"different". The first draft asserted a stack depth after a failed
`janet_equals` and got zero.

**Three checks in `janet_equals` sit behind that hash comparison** and are
unreachable while the hashes disagree: the tuple length, the struct length, and
the struct prototype-presence pair. They are not dead code — a 32-bit hash
collides, and when it does these are what stop the traversal from reading a
bucket array off the end of itself or reporting two different values equal. A
collision cannot be constructed to order, so the test forges one by
overwriting a head hash after construction, which is exactly the state a
collision produces. Mutation testing is what found this: all three survived
until the forged-collision tests existed.

**The number hashes are pinned as exact constants.** A struct's bucket array is
part of the language contract, and the layout is a function of `janet_hash`, so
the hash of a double is observable through every struct with a numeric key. It
does not vary with the target or with `-Dprf`. Taking the low word of the
`murmur64` mix instead of the high one would be just as good a hash and a
different language, and nothing else in the suite would have noticed.

**The traversal-capacity assertions are order-dependent** and that is the one
place in the file where the order of `main` matters. The array only ever grows,
so every test that asserts a capacity has to run before the ones that grow it
past the 128-node floor.

### What this cost

No new C at all, and 297 lines of C guarded out. Both selectors pass every
suite and contract on macOS ARM64 across four optimize modes, tagged values,
keyed hashing, single-threaded, `-Dcall-trampoline=true`, and all seven earlier
Phase 8 selectors set to `c` at once; both cross-compile for aarch64 and x86-64
Linux musl and Windows x86-64 MinGW; and both run 46 contract binaries and 34
suites natively on aarch64 Linux musl.

Seventeen feature flags were disabled individually. Sixteen of them run the
whole of `zig build test`. `-Dreduced-os=true` runs the contract binaries only,
because `test/helper.janet` opens with `os/getenv` and a reduced-OS build does
not have it — every Janet suite fails to compile there, identically under both
selectors and for a reason that predates this increment.

## Indexed and keyed access

Phase 8 Part 7b. `-Dvalue-access=c` restores the C implementation; Zig is the
default. `value_access.zig` owns the rest of `core/value.c`: `janet_next` and
`janet_next_impl`, and the seven accessors beneath `getter_checkint` —
`janet_in`, `janet_get`, `janet_getindex`, `janet_length`, `janet_lengthv`,
`janet_putindex` and `janet_put`. Nine exported symbols, 730 lines of Zig
against 484 lines of C. With Part 7a beside it, `value.c` holds no C the port
has not taken.

### No seam, and two guarded regions

Like 7a this needs no seam at all — the fourth increment in the phase to need
none. `getter_checkint` is the file's only remaining `static` and every one of
its callers moved with it, so both halves stay closed over their own privates.
`janet_next` sits physically between 7a's two regions, so `value.c` carries two
`JANET_ZIG_VALUE_ACCESS` regions as well as two `JANET_ZIG_VALUE_ORDER` ones.
Nothing was moved to make either pair contiguous; a reordered C file is a
permanent diff against upstream that buys only tidiness.

### Three lookups that answer the same question differently

`janet_in`, `janet_get` and `janet_getindex` read the same containers and
differ only in what a failure is, and the differences run all the way down:

|  | bad key type | index out of range | not a container | abstract with no `get` | abstract `get` reports absence | fiber, key ≠ 0 |
|---|---|---|---|---|---|---|
| `janet_in` | panic | panic | panic | panic | panic | panic |
| `janet_get` | nil | nil | nil | nil | nil | nil |
| `janet_getindex` | n/a | nil | panic | panic | nil | nil |

`janet_getindex` has no bad-key-type column because it takes an `int32_t`; what
it has instead is a panic on a negative one. The row that matters most is the
last column but one: an abstract `get` that runs and reports absence is an
error to `janet_in` and a nil to `janet_getindex`, and that is not a
simplification anyone would arrive at by deriving one function from the other.
They are written out separately here for the same reason they are separate in
C. Factoring them into one function with a policy flag would put a branch on
the VM's hot path to save thirty lines.

`test/value_access.c` runs the same failing inputs through all three and
asserts each answer against the others, rather than testing each in isolation.

### Zig calls `janet_panicf` through the C variadic ABI

This is the first subsystem to do that, and Part 1 went the other way, so the
difference is worth stating. `capi.c`'s getters report a `JanetArgFault` code
and let C format it because a getter must not raise, and a formatter that
allocates can. These accessors are under no such constraint: panicking *is*
their contract, and the file is jump-transparent, so a `longjmp` out of
`janet_panicf` strands nothing. A fault-code seam here would add a translation
layer to twelve messages whose only job is to be identical to the C original's.

What the direct call costs is an ABI assumption. `%v` passes a `Janet` by value
through `...` — eight bytes as a union under nanboxing, sixteen as a struct
under `-Dnanbox=false`, which is exactly the size class where the
classification rules diverge — and `%T`, `%d` and `%u` pass a type-flag mask,
an `int32_t` and a `size_t` where the formatter reads `int`, `int32_t` and
`uint64_t`. An ABI mismatch in any of those produces a plausible wrong message
rather than a crash. So the contract test asserts the rendered text of all
forty-nine panics byte for byte, and that check runs under both selectors,
under both value layouts, and on every platform in the acceptance matrix. The
ABI is a tested fact here rather than an assumed one.

### The two callbacks that are allowed to raise

Six of the nine functions reach a third-party abstract type's `get`, `put`,
`next` or `length` callback, and `janet_next_impl` resumes an arbitrary fiber
through `janet_continue`. SPIKE-8 governs all of it: they are called directly,
in the shape of the C original, and a signal from one jumps straight through
the Zig frame that invoked it.

One piece of state has to survive such a jump, and the C original handles it by
hand rather than by scope. `janet_next_impl` parks the child fiber in
`janet_vm.fiber->child` across the resume and has to clear it again. It clears
the slot *before* `janet_panicv` on the C API path and deliberately does **not**
clear it before `janet_signalv` on the interpreter's path, because the
interpreter unwinds through the fiber chain and needs the link. That asymmetry
is reproduced exactly; written as a `defer` it would be both a
jump-transparency violation and wrong.

The link is what `debug/lineage` walks and what puts a resumed fiber's frames
into a stack trace, and it is only observable while the child is running — so
the contract test has the child observe it, from inside itself.

### What is reproduced rather than repaired

Three of `FOUND.md`'s new entries are here, and it carries the evidence for two
of them.

`janet_next` on a fiber writes `janet_vm.fiber->child` before it resumes
anything, and `janet_vm.fiber` is null outside a running fiber. `janet_next` —
as opposed to `janet_next_impl(ds, key, 1)`, which is all `run_vm` ever calls —
has no in-tree caller at all, so the one caller it exists for is exactly the
one with no fiber running.

`janet_next_impl` and `janet_putindex` each add one to an `int32_t` that may be
`INT32_MAX`. Both are written here with `+%`, which is the rule the other
wrapping defects in `FOUND.md` follow: the port does what the C does when the
sanitizer is not watching, rather than trapping where the C would not. That
makes the selectors disagree under a sanitizer and agree without one, and the
probe records both columns. The alternative — Zig's checked `+` — would match
the sanitized C and introduce illegal behaviour in ReleaseFast, where the C
merely wraps.

`janet_length` and `janet_lengthv` render an abstract type's `size_t` with
`%u`, which the formatter reads as a `uint64_t`. The two agree only where
`size_t` is 64 bits, which is every target here; the widening is preserved
rather than corrected so the rendering is identical where it works.

The fourth entry is not a defect in behaviour but in linkage.
`janet_wrap_integer` is declared in `janet.h` beside the twenty-one other
`janet_wrap_*` functions and defined by `wrap.c` only inside the nanbox block,
so it does not exist in a `-Dnanbox=false` build. Every Zig subsystem is a
consumer that cannot expand C macros — translate-c keeps the declaration in
preference to the macro — so this file writes the macro out in a one-line
`wrapInteger` helper rather than depending on a symbol that is not always
there. It is the first subsystem to need an integer wrapped, which is why it is
the first to find this.

### What the contract test had to be built around

Three things shaped `test/value_access.c` more than the functions did.

**The fiber arm cannot be reached from the top level.** Every fiber case needs
`janet_vm.fiber` non-null, so the tests that touch one are driven from Janet
source through cfunctions registered for the purpose. That is also the only way
to exercise `janet_next` itself, since nothing in the tree calls it.

**`is_interpreter` is not observable from either side alone.** The flag decides
whether an untrapped signal from the resumed fiber reaches the caller as that
signal or as a plain error. The payload survives both ways, so the test runs
the same fiber through `next` and through the C API entry point and compares
the resulting *fiber statuses* — `:user5` against `:error`.

**The two length bounds are different bounds.** `janet_length` stops at
`INT32_MAX` and `janet_lengthv` at `JANET_INTMAX_INT64`, so there is a wide
band in which one panics and the other succeeds. An implementation that used
one bound for both passes every test that does not look inside it, so the test
has abstract types whose lengths are `INT32_MAX + 1` and `JANET_INTMAX_INT64`
exactly.

Forty-eight mutations were run against the finished contract. Forty-six were
caught. The two survivors are equivalent rather than missed: reading a buffer's
`count` through `janet_unwrap_array` reads the same bytes, because `JanetArray`
and `JanetBuffer` have identical layouts up to that field; and zeroing a
buffer's gap one byte short leaves only the byte the next statement overwrites
with the value. Four assertions were added because a mutation survived them —
a negative index on a string in `janet_get`, an append at exactly the current
count in `janet_putindex`, a buffer byte with its high bit set through
`janet_put`, and the fiber-chain link, which nothing had observed at all.

## Abstract values

Phase 8 Part 8. `-Dabstract-core=c` restores the C implementation; Zig is the
default. `abstract_core.zig` owns all of `core/abstract.c` except the mutex and
rwlock shims: `janet_abstract_begin`, `janet_abstract_end` and
`janet_abstract`; `janet_abstract_begin_threaded`,
`janet_abstract_end_threaded` and `janet_abstract_threaded`; and
`janet_abstract_incref`, `janet_abstract_decref` and
`janet_abstract_decref_maybe_free`. Nine exported symbols, 260 lines of Zig
against 61 lines of C.

### No seam, and three guarded regions

The fifth increment in the phase to need no seam. Every function that moved is
public API in `janet.h` and `abstract.c` has no `static` at all, so there was
nothing private to expose and nothing to declare.

Three guarded regions rather than one, because the twelve shims sit between the
threaded constructors and the refcount primitives. Nothing was moved to make
them contiguous, for the reason Part 7a gives: a reordered C file is a permanent
diff against upstream that buys only tidiness.

### What stays in C, and by which rule

`janet_os_mutex_*` and `janet_os_rwlock_*` stay behind under the rule that keeps
`struct tm` and `jstat_t` in C. Each is a cast onto a host structure —
`pthread_mutex_t`, `pthread_rwlock_t`, `CRITICAL_SECTION`, `SRWLOCK` — whose
layout the platform owns and whose size Janet republishes through
`janet_os_mutex_size` and `janet_os_rwlock_size`. Porting them would move the
cast without moving the structure, and would make Zig's translation of
`<pthread.h>` a build dependency of the runtime core for nothing. They are also
the only functions in the file with no connection to abstract values; the
comment that files them under "Refcounting primitives and sync primitives" is
the only thing that groups them.

### Two allocators, one head

A plain abstract and a threaded abstract share `JanetAbstractHead` and share
nothing else.

|  | plain | threaded |
| --- | --- | --- |
| allocator | `janet_gcalloc` | `janet_malloc` |
| heap list | `janet_vm.blocks` | neither |
| lifetime decided by | reachability | `gc.data.refcount` |
| recorded in | the heap list | `janet_vm.threaded_abstracts` |
| freed by | `janet_sweep` | `janet_abstract_decref_maybe_free` |

So the threaded path does by hand the three things `janet_gcalloc` would have
done: write the type tag, clear the union, and charge the block against
`janet_vm.next_collection`. The charge is worth stating because it is written
differently on the two paths and has to come to the same number:
`janet_abstract_begin` asks `janet_gcalloc` for `sizeof(JanetAbstractHead) +
size` and `janet_gcalloc` charges what it was asked for, while the threaded path
charges `size + sizeof(JanetAbstractHead)` itself. `test/abstract_core.c`
asserts both against `janet_vm.next_collection`, and has to net out the visit
table's own charge when the new entry makes it rehash — `janet_memalloc_empty`
bills its bucket array to the same counter.

Clearing the union before storing the refcount is the one write with no
behavioural consequence at all. `gc_alloc.zig` never clears it, because the
heap-list link overwrites the whole word immediately; here the word holds a
four-byte refcount, and the C original's comment says what the clear is for —
the address sanitizers. It is reproduced for that reason and not because
anything reads it.

### The two-step protocol protects the sweep, not the traversal

`janet_abstract_begin` allocates with `JANET_MEMORY_NONE` and
`janet_abstract_end` writes `JANET_MEMORY_ABSTRACT` over it, and the block is on
`janet_vm.blocks` — visible to the collector — for the whole window in between,
with an uninitialised payload. What makes that safe is `janet_deinit_block`,
which has no case for `JANET_MEMORY_NONE`: a collection in the window frees the
block without calling a finalizer on it and without reading a field of it. An
abstract type whose `gc` releases a pointer it has not been given yet is the
crash this prevents, and it is why an embedder that cannot fill the payload in
one expression uses the pair rather than `janet_abstract`.

It is the sweep the tag protects and not the traversal, which is easy to get
backwards — the first draft of the contract test asserted the opposite and
failed against the C original, which is what the rule about verifying a contract
against the `c` selector first is for. The mark phase dispatches on the type of
the `Janet` it is handed, never on the block's memory tag, so an embedder that
wraps and roots the block *before* filling it in gets `gcmark` called on an
uninitialised payload. Nothing prevents that and nothing should; the contract is
that the caller roots the value after `janet_abstract_end`. Both halves are
pinned, so a port that "fixed" the second by tagging early would be caught.

`janet_gc_settype` is an or and not a store, and the plain path is where that
matters: a block already marked `JANET_MEM_REACHABLE` by a collection inside the
window must still be marked when `janet_abstract_end` returns, or the sweep
frees a block the caller is about to use. On the threaded path the same or is a
no-op, because `janet_abstract_begin_threaded` has already written the tag —
which is why `janet_abstract_end_threaded` is an identity function that the
contract pins as one.

### SPIKE-8, and the block that is briefly owned by nobody

Two calls here reach code this runtime does not own.
`janet_abstract_decref_maybe_free` runs the type's `gc` finalizer, and
`janet_abstract_begin_threaded` calls `janet_table_put`, which hashes an
abstract key and so may run the type's own `hash` callback. Both are called
directly, in the shape of the C original; there is no `defer` in the file and
`build.zig` checks that there is not.

One frame does hold a raw block across such a call, and it is the exception to
Part 6a's observation that every panic in a container port happens before the
allocation it guards. `janet_abstract_begin_threaded` has a `janet_malloc`ed
header in hand when it calls `janet_table_put`; a signal out of that call leaks
the header, because nothing has recorded it yet — not a heap list, not the visit
table, not the caller. The C original leaks it identically and the port does not
diverge. It is reachable only through the raising `hash` callback SPIKE-8
forbids, so it is recorded here rather than in `FOUND.md`.

The finalizer is the other way round. By the time it runs the refcount is
already zero and no other thread can reach the block, so a signal out of it
leaks a block that was about to be freed and nothing else.

### What the contract test had to be built around

Three things shaped `test/abstract_core.c` more than the functions did.

**Almost nothing here has an interesting return value.** Six of the nine
functions return their argument or a pointer the caller already has, so the
contract is entirely in state the caller cannot see: `head->size`,
`head->type`, the raw `gc.flags` word, membership of `janet_vm.blocks`,
`janet_vm.block_count`, `janet_vm.next_collection`, and
`janet_vm.threaded_abstracts`. The flags word is the only place
`janet_gc_settype`'s or is distinguishable from a store, and nothing else in the
tree reads it that way.

**Dropping a threaded reference by hand is not the same as letting the sweep do
it.** Calling `janet_abstract_decref_maybe_free` down to zero frees the block
while `janet_vm.threaded_abstracts` still keys on it, and the next collection
then reads a freed header — the first draft segfaulted on exactly that. The
sweep removes the entry and then decrements, so every threaded test here ends
through a helper that does the same. That ordering is a property of the API's
contract rather than a defect: the reference the creating interpreter holds
belongs to the visit table, and an embedder is only ever supposed to drop a
reference it took itself.

**The finalizer's arguments are not observable from its return value.**
`janet_abstract_decref_maybe_free` calls `head->type->gc(head->data,
head->size)`, and the header is one word from the payload, so handing over the
header instead — or a zero length — changes nothing any caller can see. Two
mutations survived the first draft for that reason; the probe now records both
arguments and the test asserts them against a payload it filled with a sentinel.

Thirty-four mutations were run against the finished contract. Thirty were
caught. The four survivors are equivalent or out of reach rather than missed:

- **Dropping the `0xFF` mask in `janet_gc_settype`.** Every value in
  `enum JanetMemoryType` is at most 17, so the mask never removes a bit.
- **Skipping the union clear on the threaded path.** It is a write with no
  reader; MSan is the tool that sees it, and it is not available on the
  development target.
- **Skipping `janet_abstract_end_threaded` inside `janet_abstract_threaded`.**
  Equivalent by construction, since the tag is already written. The contract
  pins that the function is a no-op, which is the same fact from the other side.
- **Omitting `janet_free` in `janet_abstract_decref_maybe_free`.** A leak is
  invisible in-process, the same gap `test/gc_sweep.c` records for
  `janet_deinit_block`. This one is reachable from outside, though:
  `leaks --atExit` reports zero leaks for the contract as it stands and eleven
  for the mutant, so the mutation is caught by the platform's leak checker even
  though the assertions cannot see it.

### What this cost

No seam, three guarded regions, one new selector, and one new contract test.
The suites pass with `-Dabstract-core` set both ways, with every Phase 8
selector set to `c` together, and under ReleaseSafe, ReleaseFast, ReleaseSmall,
`-Dnanbox=false`, `-Dprf=true`, `-Dsingle-threaded=true`, `-Dev=false`,
`-Dsourcemaps=false`, `-Ddocstrings=false` and `-Dcall-trampoline=true`. The
`x86_64-linux-musl` and `x86_64-windows-gnu` cross-compiles build, and the
static and shared artifacts each contain exactly one provider of all nine
symbols.

`-Dev=false` is the configuration this increment adds a shape for rather than
inherits one: six of the nine functions do not exist without the event loop, so
they are declared as ordinary functions and `@export`ed inside a `comptime`
block that tests `JANET_VM_HAS_EV`. Zig analyses a function only when something
references it, so the bodies that reach `janet_vm.threaded_abstracts` are never
compiled in a build where that field does not exist. `os_fs_paths.zig` uses the
same shape for its non-Windows half.

## The remaining collectable constructors

Phase 8 Part 9. `-Dvalue-alloc=c` restores the C implementation; Zig is the
default. `value_alloc.zig` owns `fiber_alloc`, `janet_fiber` and
`janet_fiber_reset` from `core/fiber.c` together with `janet_funcdef_alloc` and
`janet_thunk` from `core/bytecode.c`: four exported symbols and two file-local
helpers, 286 lines of Zig against a hundred lines of C.

### Two files, one increment

The two files are one increment because they are one gap rather than two. After
Parts 6 and 8 every other collectable kind can be built from Zig; fiber,
function and funcdef were what remained, and these are the last `janet_gcalloc`
call sites outside `vm.c` and `marsh.c`. Splitting them would have produced two
selectors and two contract tests that each covered half of the same sentence.

Both files already carried selectors, so neither needed a new guard convention —
only a new region.

### A second region in `fiber.c`, and why not the first

`fiber_alloc` and its two callers sit physically *above* the
`JANET_ZIG_FIBER_CORE` region, and Phase 7 left them there deliberately: the
code below that `#ifndef` is the frame machinery, and the code above it is
allocation, which is this phase's subject rather than that one's. So `fiber.c`
now carries two guarded regions belonging to two different selectors, and the
boundary between them is the one this phase has drawn everywhere else — who owns
the memory, not who uses it.

The two selectors are independent, and that is checked rather than assumed:
`-Dvalue-alloc=zig -Dfiber-core=c` and `-Dvalue-alloc=c -Dfiber-core=c` both
build and both pass the suites. Everything crossing between the two regions is a
public entry point — this file calls `janet_fiber_setcapacity` and
`janet_fiber_funcframe` by name and does not care which selector answered.

### Two allocations, one of them collectable

A fiber is two allocations. The block comes from `janet_gcalloc`, which charges
it against `janet_vm.next_collection` and prepends it to `janet_vm.blocks`; the
value stack is a plain `janet_malloc` that the collector learns about only
through `janet_deinit_block`, so its bytes are charged here by hand. That is the
same split `janet_fiber_setcapacity` maintains in `fiber_core.zig`, and the two
have to agree — a fiber allocated here and grown there must be charged once for
its initial capacity and once per resize, never twice and never not at all.
`test/value_alloc.c` checks the initial charge against the same arithmetic
`test/fiber_core.c` checks the resize against.

The 32-slot floor is applied before the capacity is written and before the stack
is allocated, so a request for 0 produces a fiber whose `capacity` reads 32 and
whose charge is 32 slots. A negative request lands on the same floor rather than
wrapping into an enormous allocation, which is the only reason the widening to
`usize` in `janetBytes` is safe.

### The only vantage point on a newborn fiber

`fiber_reset` writes eleven fields, or sixteen under the event loop, and nothing
that survives a successful call: `janet_fiber_reset` runs
`janet_fiber_funcframe` immediately afterwards, which overwrites `frame`,
`stackstart` and `stacktop` before returning. A test that only ever built
working fibers could not see most of what this function does.

So the contract reads the newborn state through a *rejected* call. A callee
whose arity turns the argument count down makes `janet_fiber_reset` return NULL
after `fiber_reset` has run and before anything has run over it, and every field
is then exactly as `fiber_reset` left it. The same vantage point makes the
argument block visible: arguments are written before the arity is checked, so a
rejected three-argument call still shows where the three values landed.

The fields are dirtied before each call rather than merely asserted afterwards.
A fresh block reads as whatever the allocator returned, which is usually zero,
and zero is what most of a newborn fiber looks like — so an assertion over an
untouched block would pass whether or not the store happened.

### Jump transparency, and the one call that needs it

The file is marked `//! jump-transparent` and `build.zig` enforces it.
`janet_fiber_reset` calls `janet_fiber_funcframe`, which packs a variadic tail
when the callee takes one, which for a `JANET_FUNCDEF_FLAG_STRUCTARG` function
means `janet_struct_put`, which hashes the caller's arguments and so may run an
abstract type's `hash` callback. Under SPIKE-8 that callback may not raise, but
if it does the `longjmp` goes straight through the Zig frame, so there is no
`defer` in the file.

Nothing is stranded when that happens. The fiber is on `janet_vm.blocks` from
the moment `janet_gcalloc` returns, so the collector owns it whether or not the
function returns, and its value stack is freed with it. The half-built frame the
signal leaves behind is exactly what C leaves behind, because C runs the same
statements in the same order.

### What the mutation sweep could and could not see

Fifty-five mutations were run against the finished contract. Forty-four were
caught. The survivors fall into two groups, and only the second is a limit of
the test.

Three are equivalent:

- **`setStatus` not clearing the status bits before writing them.** The C macro
  clears first, and so does the port, but every caller here assigns `flags`
  immediately beforehand, so the bits are already zero.
- **Storing `JANET_STACKFRAME_ENTRANCE` rather than or-ing it.**
  `janet_fiber_funcframe` leaves `flags` at 0, so the two coincide. The contract
  asserts `frame->flags == JANET_STACKFRAME_ENTRANCE`, which pins the same fact
  from the other side.
- **Dropping the second `supervisor_channel = NULL`.** `fiber_reset` has already
  cleared it and nothing in between writes it, so the store in the C original is
  redundant. Reproduced rather than dropped, because a port is not the place to
  decide that.

The rest are the same mutation repeated across eight fields: *removing a store
whose correct value is zero*. On the development target these cannot be caught
in-process at all, and the reason is the platform rather than the contract —
macOS zeroes a block when it is freed, so a recycled block reads exactly like a
correctly emptied one, and an uninitialised field is indistinguishable from an
initialised one. `max_arity` is the single field in `janet_funcdef_alloc` whose
right answer is not zero, and its mutants are caught.

This was worth establishing rather than assuming: the contract originally
carried two tests that poisoned a block, freed it, took it back from the
allocator and read the fields over the garbage. They passed, and they proved
nothing — first because a plain `memset` before a `free` is a dead store that
the compiler removes, and then, once the poison was written through a volatile
pointer, because the allocator zeroed it anyway. Both tests were removed rather
than left in place looking like coverage. The tools that would see this class are
MSan, or any allocator that does not zero on free; `test/gc_sweep.c` records the
same shape of gap for leaks.

One survivor was closed rather than explained. `janet_thunk`'s refusal to wrap a
funcdef that needs upvalues is fatal — `janet_assert` on the C side,
`janet_zig_fatal` on the Zig side — and a fatal path needs a child process to
observe. The contract forks, builds a def with `environments_length` set, and
checks that the child died of `SIGABRT`. It is guarded for non-Windows the same
way `test/fiber_core.c` guards its pthread half. Without it, deleting the check
outright was invisible, and a caller that got such a thunk back would read
`envs[0]` off the end of a 24-byte allocation.

`leaks --atExit`, which Part 8 used as a channel for the one mutation its
assertions could not see, is not available here: it does not compose with a test
that forks, and stalls instead of reporting. It would have had nothing to find —
the only plain allocation this file makes is a fiber's value stack, and freeing
that belongs to `janet_deinit_block`, which `test/gc_sweep.c` covers.

### What this cost

Two guarded regions in two files, one new selector, one new contract test. The
suites pass with `-Dvalue-alloc` set both ways, with `-Dfiber-core` set both
ways against it, with every Phase 8 selector set to `c` together, and under
ReleaseSafe, ReleaseFast, ReleaseSmall, `-Dnanbox=false`, `-Dprf=true`,
`-Dsingle-threaded=true`, `-Dev=false`, `-Dsourcemaps=false`,
`-Ddocstrings=false` and `-Dcall-trampoline=true`. The `x86_64-linux-musl` and
`x86_64-windows-gnu` cross-compiles build, and the static and shared artifacts
each contain exactly one provider of all four symbols.

`sizeof(JanetFunction)` is the second and last flexible array member the port
has to size around. translate-c drops `envs[]` entirely, so `@sizeOf` in Zig is
the number C's `sizeof` produces — true here, and asserted from the C side in
`test/value_alloc.c` the same way `test/abstract_core.c` asserts it for
`JanetAbstractHead`.

## The value representation

Phase 8 Part 10, and the last increment of the phase. `-Dvalue-wrap=c` restores
the C implementation; Zig is the default. `value_wrap.zig` owns the whole of
`core/wrap.c`: the four macro fills over the type tag and truthiness, the
sixteen unwrap entry points, the nineteen wrap entry points, the per-layout
nanbox helpers `janet.h` declares beside them, and `janet_memalloc_empty` and
`janet_memempty`. One guarded region, from the includes to the end of the file.

Porting this moves the representation. It does not change it, which is guiding
principle 7 applied to the one file where the distinction is easy to lose.

### Three implementations behind one set of signatures

`wrap.c` is the only file in the phase whose *content* changes shape per target.
`JANET_NANBOX_64`, `JANET_NANBOX_32` and the tagged fallback are three different
implementations, and which one a build gets is decided by `janet.h` from the
target's pointer width and architecture rather than by a build option alone.
`-Dnanbox=false` reaches the third; nothing reaches the second on a 64-bit host.

None of those three macros is defined with a value, so none survives
translate-c. Restating the `#ifdef` chain in `state_abi.h` the way
`JANET_VM_HAS_EV` restates `JANET_EV` was available and was not needed, because
the *shape of the translated `Janet`* already separates all three:

| layout            | translated `Janet`                          | test |
| ----------------- | ------------------------------------------- | ---- |
| `JANET_NANBOX_64` | union of `u64`, `i64`, `number`, `pointer`  | neither field below |
| `JANET_NANBOX_32` | union whose first member is `tagged`        | `@hasField(c.Janet, "tagged")` |
| tagged fallback   | *struct* of `as` and `type`                 | `@hasField(c.Janet, "as")` |

`value_order.zig` already selected on `@hasField(c.Janet, "u64")` to spell
`janet_u64`; this is that test carried to its conclusion. The advantage over a
restated macro is not brevity — it is that a layout and the type it produces
cannot disagree.

### The exported set differs per layout, three ways

This is the second increment in the phase whose functions do not all exist in
every configuration, and where Part 8 had one condition this has three. Twenty-
four symbols are common. A NaN-boxed build adds the eighteen wrappers `janet.h`
provides as macros, plus five nanbox-64 helpers or two nanbox-32 ones; the
tagged build defines its wrappers outright and defines every one of them except
`janet_wrap_integer`.

Forty-seven symbols under nanbox-64, forty-four under nanbox-32, forty-one under
the tagged layout, and `nm` reports the same set for both selectors in each. The
conditional ones are exported from `comptime` blocks rather than declared
`export fn`, which is Part 8's pattern for `JANET_EV` and is needed here for the
same reason: a body naming `x.tagged` must not be analysed in a build where
`Janet` has no such field.

`janet_wrap_integer`'s absence under the tagged layout is the defect `FOUND.md`
records against `wrap.c`, reproduced rather than repaired under the standing
rule. It is one `if (is_nanbox)` in the export block, and `test/value_wrap.c`
references the symbol behind the same condition — so the contract compiles under
the tagged layout only because it does not name a symbol that is not there.

### What the contract can and cannot say

Three channels, and the increment is unusual in that the obvious one is the
weakest.

The **layout-independent** assertions are the bulk: a wrapper's tag, a round
trip through the matching unwrapper, the full thirteen-by-thirteen
`janet_checktype` matrix rather than its diagonal, truthiness, and the fact that
one address under two tags is two values. These say the representation is *a*
working one.

The **macro-versus-function** channel is the one `wrap.c` exists for — the file
is there so that a language binding which cannot expand macros can call a
function — and C's rule that a parenthesised name is not expanded is what lets
one test call both. It is weaker than it looks: under either NaN-boxed layout
the macro bottoms out in `janet_nanbox_from_bits` and friends, which this
increment also ports, so the comparison is between two paths through the same
implementation. It catches a wrapper wired to the wrong helper and nothing more.

The **exact bit patterns** are what catch the helpers, and they are computed
from `janet.h`'s own constants rather than from either implementation: the tag
word for nil, true and false; a double stored unchanged; a pointer's payload
equal to the address shifted by `JANET_NANBOX_64_POINTER_SHIFT` and its tag
bits equal to `janet_nanbox_tag`; under nanbox-32 the raw type field and the
`JANET_DOUBLE_OFFSET` bias; under the tagged layout the `as.u64 = 0` that
`JANET_WRAP_DEFINE` performs before the narrower store. Without these a port
that shifted every tag by one would pass everything above.

### The nanbox-32 layout is compiled, run, and only half covered

The phase's plan said the contract has to run under all three representations
rather than sample one. It does, and getting there turned up a wall.

`riscv32-linux-musl` is the only 32-bit target Zig 0.16's translate-c can
handle — musl's 32-bit `time64` `__REDIR` declarations are rejected by Aro on
x86 and arm, which fails `abi.zig` and so fails every Zig subsystem at once —
and the whole tree cross-compiles for it. Alpine ships `qemu-riscv32`, so the
binaries run:

```sh
zig build -Dtarget=riscv32-linux-musl -Dcpu=baseline -Dinstall-tests=true \
          --cache-dir /tmp/janet-xc-rv -p xbuild/rv
podman run --rm -v "$PWD/xbuild/rv":/xb:ro alpine:latest sh -c '
  apk add --no-cache -q qemu-riscv32
  qemu-riscv32 /xb/test/janet-value-wrap-test'
rm -rf /tmp/janet-xc-rv xbuild/rv
```

**With every selector set to `c`, `janet-value-wrap-test` passes there**, which
is what validates the nanbox-32 arm of the bit-layout assertions above. Set
`-Dvalue-wrap=zig` and it fails, and the failure is not in `value_wrap.zig`.

Zig 0.16 and clang disagree about how many argument registers an eight-byte
union consumes under riscv32 ILP32D. A probe measured it in isolation, and the
result is sharper than "unions do not cross": a lone `Janet`
parameter arrives intact, and every argument *behind* a by-value `Janet` arrives
displaced. The first parameter is right every time; the rest are shifted.

That is exactly the failure the runtime shows. `janet_type(Janet)` and
`janet_truthy(Janet)` answer correctly, because their `Janet` is the only
parameter. `janet_checktype(Janet, JanetType)` reads a garbage type tag and so
answers a constant.

The wall is older than this increment. `janet_equals(Janet, Janet)` from Part 7a
reads a garbage second value and so returns 0 for two *identical* arguments,
which is why an all-Zig riscv32 build dies inside `janet_init` registering
`core/rng`, long before any of this file runs — shown by setting every selector
to `c` except `-Dvalue-order=zig`, which fails the same way on its own. Nothing
in Phase 8 can move it. `PLAN.md` carries it as a toolchain constraint.

### What the mutation sweep found, and it was in the contract

Fifteen mutants of `value_wrap.zig`, run by the cheap recipe in `AGENTS.md` —
`zig build`, then one `zig cc` of the contract against the freshly built
`libjanet.a`. Eleven died on the first pass. The interesting result is the three
that did not, because two of them exposed the trap this file is uniquely prone
to.

**Most of the contract was testing `janet.h`, not the library.** `janet_truthy`
and `janet_checktype` are macros under all three layouts, so
`assert(janet_truthy(janet_wrap_false()))` never calls anything this increment
ported. Dropping the boolean arm of `truthy` survived, and so did dropping the
second arm of `janet_nanbox_isnumber` — the one that recognizes a canonical NaN
by its type nibble reading as `JANET_NUMBER`, which is the arm every NaN takes
and no other double does. The function forms were only reached by
`test_macro_and_function_agree`, whose sample was one value per type: `2.5` for
a number and `true` for a boolean, both of which take the ordinary arm of every
predicate.

The fix is a second value set — NaN, both infinities, both zeroes, `false`,
`boolean(0)`, `boolean(3)`, a null pointer — run through the same agreement
helper, plus direct function-form assertions in the truthiness and NaN tests.
Both mutants die against it, and so does a third that had failed to build.

The last survivor is not a survivor: removing the pointer-alignment shift is a
no-op on the development target, because `janet.h` sets
`JANET_NANBOX_64_POINTER_SHIFT` to 0 on Apple aarch64 and to 2 elsewhere. Under
`-Dnanbox-pointer-shift=2` it dies, and so does its counterpart in
`janet_nanbox_to_pointer`. Fifteen mutants, fourteen killed, one equivalent
under the default configuration and killed under the flag that makes it
meaningful.

### What this cost

One guarded region in one file, one new selector, one new contract test, and no
seam at all — the seventh increment in the phase to need none. Everything that
moved is `JANET_API` except `janet_memalloc_empty` and `janet_memempty`, which
were already declared in `util.h` for `struct.c` and `table.c` and which
`struct_table.zig` has been calling by declaration since Part 6c. Those two are
the fifth and sixth symbols to pick up default visibility from `export fn` where
the C build's `-fvisibility=hidden` kept them internal; the one-line fix belongs
to a single pass over all six rather than to this increment.

The suites pass with `-Dvalue-wrap` set both ways, under both value layouts,
with every subsystem selector set to `c` together, and under ReleaseSafe,
ReleaseFast, ReleaseSmall, `-Dnanbox-pointer-shift=2`, `-Dprf=true`,
`-Dsingle-threaded=true`, `-Dev=false`, `-Dsourcemaps=false`,
`-Ddocstrings=false` and `-Dcall-trampoline=true`. The `x86_64-linux-musl`,
`aarch64-linux-musl`, `x86_64-windows-gnu` and `riscv32-linux-musl`
cross-compiles build, and the static and shared artifacts each contain exactly
one provider of every symbol the increment exports, under all three layouts.

`riscv32-linux-musl` is new to that list as of this increment and is there for a
reason the other three do not share: it is the only target that selects
`JANET_NANBOX_32`, and Zig analyses only the comptime branches it selects, so
without it the 73-line `nanbox32` half of this file is never compiled anywhere.
The same is true of two branches that predate it — the `@hasDecl(c, "JANET_32")`
arm of `janet_lengthv` and the pointer-hash else-branch in `value_order.zig` —
which this build type-checked for the first time. All three were correct.
`PLAN.md` has the standing of the target and why its binaries are not run.

One thing this increment fixed rather than reproduced, and it is in `build.zig`
rather than in Janet. `src/zig/runtime_bridge.c` supplies
`janet_zig_out_of_memory` and `janet_zig_fatal`, and it was compiled only when
one of ten named subsystems was Zig. Nineteen subsystems call one of the two, so
ten were missing from the list; nothing noticed, because the default build turns
every subsystem on and one of the named few was always among them. Only a build
selecting a single unnamed subsystem — which is what a differential test is —
failed to link, and `-Dvalue-wrap=zig` on its own is the configuration that
found it. The condition is now `hasZigSubsystem`, reflection over the selector
fields, which cannot go stale.

## Closing the gate

Phase 8 Part 11, and the only increment in the phase that ports nothing. Every
file the phase named was done at Part 10; what was left was the exit gate's
testing clauses. `test/gc_stress.c` is the first contract in the tree with no
`-D` of its own, because what it tests is the collector as a whole rather than
any function in it, and `build.zig` gained the sanitizer configuration the tree
had been getting by accident.

### A GC callback may not keep what it allocates

SPIKE-8 established that an abstract type's callbacks may not *raise*. The
stress work establishes a second prohibition beside it, written down nowhere
before, and the two halves fail differently.

From `gcmark`, an allocation is freed by the collection that ran the callback.
The mark phase reaches objects from the root set rather than by walking
`janet_vm.blocks`, so a block prepended during marking is never marked, and the
sweep in the same `janet_collect` frees it and runs its finalizer.

From a finalizer, it depends on where the dying block sits. `janet_sweep` saves
`next` before running the callback and restores the list head from it after, so
a prepend made by the finalizer is discarded whenever the block being finalized
is the head — orphaned permanently, never finalized, not freed by
`janet_deinit`, and counted by `janet_vm.block_count` forever. Mid-list, with a
non-null predecessor, the same allocation is correct and is collected on the
next cycle.

Both are in `FOUND.md` with the measurements, both are reproduced identically
under either selector, and both are pinned by the contract. A leak is
deterministic and observable, which is what makes it pinnable where undefined
behaviour is not.

### The cross-thread half asserts what only threads can show

Threaded abstracts are the cross-thread facility this phase owns; channels and
the event loop belong to the standard library. Three properties: the refcount
survives four threads taking and dropping a reference two thousand times each,
each thread's heap is its own, and the last reference finalizes exactly once.

The middle one is the reason to write it. A port that reached a process-wide
`janet_vm` rather than the thread-local one would pass every other test in the
tree — the damage is invisible until two runtimes exist at once, and then it is
heap corruption rather than a wrong answer.

### The sanitizer configuration, and what it is not

`sanitize_c` is now set explicitly and per optimize mode: `.full` in Debug and
ReleaseSafe, `.off` in ReleaseFast and ReleaseSmall. Setting it unconditionally
was tried first and rejected on measurement — it puts the UBSan runtime inside
ReleaseFast, and a ReleaseFast build then reports on `(gcsetinterval -1)` where
the same build without it does not. The gate wants the check named, not the
shipping artifact changed.

`-Dsanitize-thread` exists and is wired, including the two exclusions a working
build needs: the bootstrap compiler, which is built for the host whatever
`-Dtarget` says and whose TSan link fails on macOS SDK headers; and the shared
library and native-module fixture, whose links `ld.lld` rejects because TSan
gives its thread-locals the initial-exec model. With those in place the build
succeeds for `aarch64-linux-musl` — and the binaries then segfault before
reaching any assertion, where the same build without TSan passes. On macOS it
never builds at all. `PLAN.md` carries it as deferred to Phase 10 beside ASan,
which is the same conclusion by a different route.

### What the leak checker found

`leaks --atExit` was run over all fifty-one contract binaries rather than
sampled, which is what turns "the gate has to name which contracts it covers"
into a list. It is macOS-only and documentary rather than a build step, in the
same way the container recipes are:

```sh
zig build -Dinstall-tests=true --cache-dir /tmp/janet-lk -p /tmp/janet-lk-out
for t in /tmp/janet-lk-out/test/janet-*-test; do
    case $(basename "$t") in
        janet-gc-stress-test|janet-gc-sweep-test) continue ;;     # known leaks
        janet-value-alloc-test|janet-os-process-test) continue ;; # fork, stall
    esac
    leaks --atExit -- "$t" | grep -q "0 leaks for 0" || echo "LEAKS: $t"
done
rm -rf /tmp/janet-lk /tmp/janet-lk-out
```

The loop deliberately does *not* skip `janet-args-core-test`, so it reports one
line today. That line is the open item below, and it should keep appearing until
someone diagnoses it rather than being silenced by a fifth `continue`. Forty-six are clean. Two stall, and both fork — Part 9 found this
against `test/value_alloc.c` and Part 11 confirms it is about forking rather
than about that contract. `test/gc_stress.c` leaks forty-eight bytes on purpose,
being the contract that pins the orphaned block.

The other two are the interesting ones. `test/gc_sweep.c` leaks eight blocks,
and the stacks are `janet_array_weak` and `janet_table_weakv` — the
`janet_clear_memory` weak-heap leak Part 5 recorded, rediscovered independently
by a channel that had no knowledge of it. That is the clearest argument for
naming the check.

And `test/args_core.c` leaks eighty-six blocks, which is **not diagnosed**. It
is identical under both selectors, so it is not a port defect. Three things are
ruled out: it is not one block per panic, whether the raise comes from
`janet_panic` or from `janet_getcstring` on a bad slot; it is not
`janet_core_env`; and no isolated reproducer has been found. `leaks` prints one
stack for eighty-six leaks even under `MallocStackLogging=1`, so the single
panic-path stack it does print may be a red herring. `PLAN.md` records it as
open, with the mechanical next step, rather than excluding it quietly.

## Dispatching without a computed goto

Phase 9 Part 1, and the only increment in the phase that ports nothing. Phase 7
closed with one cost unmeasured and assigned here — Zig has no computed goto,
and whether its labelled `switch` produces comparable dispatch on `run_vm`'s
loop was unknown. `SPIKE-9.md` has the method and the tables; the two results
that govern the rest of the phase are these.

**A labelled `switch` with `continue :sw` in every arm is the technique, not an
approximation of it.** Each arm ends in its own indirect jump — fifteen of them
in a twelve-opcode skeleton, against clang's twelve for the same interpreter
written with computed gotos — and it lands within 1.3% of C at both ends of a
bracket built to exaggerate the difference: a perfectly predicted loop and a
straight line of pseudo-randomly chosen opcodes.

**Dispatch shape is worth at most 3% of anything real.** `-Dcomputed-gotos=false`
is a new build option that forces the C `run_vm` onto its switch — 20 indirect
branches become 1 — and over `probe-9/bench/`'s seven workloads six move less
than the noise and the seventh, the most dispatch-dense of them, is 8% *faster*
that way. So the interpreter's time is in what the opcodes do rather than in
reaching them, and Part 3 is free to write the loop the way that reads best.

`-Dcomputed-gotos` stays in the tree as the C-side control for later dispatch
comparisons. It is not a supported configuration, and `zig build test` passes
both ways.

## The callee side of the interpreter

Phase 9 Part 2. `-Dvm-calls=c` restores the C implementation; Zig is the
default. `vm_calls.zig` owns eleven functions from `vm.c`: `janet_method_invoke`
and the five helpers around it, the three `fill_*` loops, and `janet_mcall`.

### What groups them, since it is not a data structure

Phase 8's first rule says to split by data structure rather than by call graph,
and an interpreter has none to split by. What groups these eleven is that they
answer one question in stages — *given a callee that is not a function, what
does calling it mean* — and that none of them touches `run_vm`'s three
registers. That is what lets them move a full increment ahead of the loop.

`vm.c` keeps two guarded regions rather than one, because `janet_mcall` sits
eight hundred lines below the rest and nothing was moved to make them
contiguous. `value.c` set that precedent in Phase 8 Part 7.

**This increment ends no scope**, which Phase 7's first rule predicts: a port
ends a scope only when it removes the *raise*, not when it moves the work. These
eleven raise directly — SPIKE-8's rule covers it, the file is jump-transparent,
and panicking is what these functions are for — so `run_vm` still needs every
scope it needed before. The reporting layer the plan had expected here was not
needed for the same reason.

### Five renamed symbols, and one that needed no seam

Ten of the eleven were `static`. Nine of those now have external linkage and a
declaration in `state.h`, beside `janet_trace_frame` and the argument-fault
layer; five of the nine had names too general for a library's symbol table and
are renamed on both sides, so `run_vm`'s call sites read identically under
either selector:

| was | is |
| --- | --- |
| `call_nonfn` | `janet_call_nonfn` |
| `resolve_method` | `janet_resolve_method` |
| `fill_table` | `janet_fill_table` |
| `fill_struct` | `janet_fill_struct` |
| `fill_string` | `janet_fill_string` |

`method_to_fun` is the tenth and stays a Zig-private inline. It is `janet_get`
with its operands swapped and both of its callers moved with it, so there is
nothing for a symbol to be.

### The first subsystem to export hidden

The nine internal symbols are exported with `.visibility = .hidden`, which is
what the C build's `-fvisibility=hidden` already gave them. That is the
one-line fix the cross-platform section lists as open for four earlier
subsystems, applied here at the point of writing rather than added to the debt:
the two selectors' dynamic symbol sets are byte-identical, 706 symbols each,
and the nine do not appear in either. `janet_mcall` is `JANET_API` and is
exported normally. Hidden visibility is invisible to a contract test, which
links the static archive.

### Jump transparency, and the two tests that depend on it

Every function here raises and most do nothing else, so the file carries
`//! jump-transparent` and `build.zig` enforces that it holds no `defer`. It
calls third-party cfunctions, an abstract type's `call`, `janet_call`,
`janet_get`, `janet_in`, `janet_table_put`, `janet_struct_put` and
`janet_to_string_b` directly, in the shape of the C original, and a signal from
any of them jumps straight through the Zig frame that invoked it.

`test/vm_calls.c` drives two of those on purpose: an abstract type whose
`tostring` panics, through `janet_fill_string`, and one whose `hash` panics,
through `janet_fill_table`. Both assert what survives the jump — the buffer
holds the element written before the raise, the table holds nothing — and they
are the only tests in the file that would notice if jump transparency stopped
being true. Neither is reachable from Janet source; no in-tree abstract type
raises from either callback.

`janet_panicf` is called through the C variadic ABI, as `value_access.zig`
established. Seven messages cross it, and the contract compares all seven byte
for byte. The values in them are numbers, keywords and strings rather than
tables or tuples, because `%v` renders a container with its address.

### What the contract had to be built around

**A live fiber under everything.** `janet_method_invoke` reaches `janet_call`
for a function callee, which needs a current fiber and a frame to push onto. The
contract therefore registers a cfunction and calls it from Janet source, so
every assertion runs where `run_vm` would have made the same call, rather than
installing a fiber by hand.

**Order, not just outcome.** Two of these functions reverse their operands and
both reversals are invisible to a test that only checks that something came
back. `janet_binop_call`'s right-hand fallback passes `{rhs, lhs}`, so a `:r+`
method receives its own receiver first; `janet_method_invoke`'s default arm
indexes the *argument* by the callee, which is what makes `(:key struct)` work.
The contract asserts both through a cfunction that returns its arguments as a
tuple.

**Rooting every evaluated value.** The helper that compiles a Janet expression
roots its result and never releases it. These tests hold values across calls
that intern keywords and compile source, either of which can collect, and a
`Janet` in a C local is not a root.

### What the mutation sweep found

Twelve mutations, all caught, and one of them found a hole first. The abstract
arm's `call` callback was tested at three arguments and at zero, and the
mutation that consults the indexed fallback *before* the callback survived both
— because it changes behaviour only at exactly one argument, where the arity
check would not have fired anyway. The contract gained that case.

One mechanical note for the next sweep, which cost a rerun here: the harness
splits its mutation table on `|`, which is also Zig's capture syntax, so a
mutation whose text contains `|call|` is silently mangled and reports as caught
at build time rather than at runtime. A mutation "caught (build)" is not caught;
it is a mutation that never ran. The sweep also restores the source but leaves
the last mutant's library in `zig-out`, so rebuild before trusting anything
measured afterwards.

### What this cost, and what Part 3 should do about it

`methods`, the one workload in `probe-9/bench/` that is almost entirely method
dispatch, is **2.4% to 3.4% slower** with the Zig implementation, reproduced
across two independent runs. Everything else in the corpus is inside ±1.2%.

The cause is not codegen but the translation-unit boundary, and the
disassembly says so exactly. With the C selector, `run_vm` inlines
`janet_resolve_method`, `janet_call_nonfn` and all three `fill_*` loops outright
— it calls none of them, only `janet_method_invoke` and `janet_binop_call`.
With the Zig selector it calls all six across an object boundary.

That is worth stating as a constraint on Part 3 rather than as a regression to
chase now. When `run_vm` becomes Zig, it recovers this only if the helpers are
`@import`ed as a module it can inline into, not if they stay a separately
compiled object linked beside it. The alternative is to accept a call at each
of those six sites permanently. It is also worth keeping in proportion: the
per-call scopes that Part 3 removes cost 16.2% on this same workload, which is
five times what this increment gave up.

## The interpreter loop

Phase 9 Part 3. `-Dvm-run=c` restores the C implementation; Zig is the default.
This is the increment that first puts a Zig frame on the VM call path, and it
takes `run_vm` whole: the dispatch loop, its seventy-eight opcode bodies, and
the resume-state decoding at its head.

What stayed in `vm.c` is everything above the loop or holding a `jmp_buf`:
`janet_call`, `janet_step`, `janet_continue`, `janet_continue_signal`,
`janet_pcall`, `janet_check_can_resume` and `janet_continue_no_check`. The first
six went in Part 4, below; the last is beyond this phase by Phase 7's fourth
rule.

### The loop dispatches with a labelled switch, as Part 1 settled

`sw: switch (opcode)` with `continue :sw` at the end of every arm, which is
Zig's equivalent of the computed goto and which Part 1 measured rather than
assumed. Nothing in the delivered loop revisits that decision, and nothing
needed to.

The one place the shape shows through is `JOP_MAKE_TUPLE` and
`JOP_MAKE_BRACKET_TUPLE`, which C reaches by falling through one label into the
next and then testing `opcode` to tell them apart. Zig has no fallthrough, so
the two share a prong and the switch's own capture supplies the discriminator —
which is the same runtime load and compare the C makes. Three other C
fallthrough-or-shared bodies went the other way: `JOP_RETURN`/`JOP_RETURN_NIL`,
`JOP_LOAD_UPVALUE`/`JOP_SET_UPVALUE` and `JOP_EQUALS`/`JOP_NOT_EQUALS` are
separate prongs calling one `inline fn` with a `comptime` parameter, so neither
opcode pays a branch to discover which one it is.

### Two subsystems are imported rather than linked, and one of them had to be

Part 2 ended by predicting that a Zig `run_vm` recovers its lost inlining "only
if the helpers are `@import`ed as a module it can inline into". That turned out
to be true and badly understated, because the same problem exists one layer
down and is an order of magnitude larger.

In C, `janet_checktype`, `janet_unwrap_number`, `janet_wrap_number` and
`janet_truthy` are macros in `janet.h`. `run_vm` pays a shift and a compare for
a type check. Zig sees the *functions* the same header declares, and the first
working version of this loop reached all of them through the symbol table:

```text
workload           C run_vm   Zig run_vm    delta
arithmetic           0.0514       0.0973   +89.3%
fib                  0.0282       0.0381   +35.3%
methods              0.0304       0.0384   +26.4%
tables               0.0779       0.0955   +22.6%
```

An interpreter that pays a call to ask what a value is spends more time asking
than acting. So `value_wrap.zig` grew a `pub const ops` namespace — the same
operations, as `inline fn`s over the layout code the exports already use, not a
second copy — and `vm_run.zig` imports it. `vm_calls.zig` arrives the same way.

`build.zig` chooses what each import resolves to, and that is what keeps the
selectors honest: `vm_calls.zig` or `vm_calls_extern.zig`, `value_wrap.zig` or
`value_wrap_extern.zig`, the `*_extern.zig` shims being nothing but declarations
of the C symbols behind the same decl names. `-Dvm-calls=c` and `-Dvalue-wrap=c`
therefore still answer for the loop, out of line, and that cost is charged to
the selector rather than hidden by a silent substitution.

Folding an implementation in folds its `@export`s in with it, so `build.zig`
stops building those two as objects of their own in the folded configuration.
Two objects defining `janet_wrap_number` is a duplicate symbol, not a choice.
`makeVmRunObject` is the one place in the build that assembles a Zig object from
more than one source, and it shares a single `abi` module across all three, for
the reason `abi.zig` states at the top: two translations of one header produce
two incompatible `JanetFiber` types.

### Phase 7's trampoline decision, reversed

Phase 7 closed a decision that `-Dcall-trampoline` would flip to default-*on* in
this increment. Part 3 reverses it. The scopes stay implemented, stay selectable,
and stay in the acceptance matrix; they are no longer the default under either
selector.

The measurement that prompted the question separates cleanly into three, because
the trampoline can be turned on for the C loop as well:

```text
the scopes alone, C run_vm with and without them
  fib +11.6%   methods +21.1%   tables +13.9%   strings +6.4%

the port alone, C run_vm against Zig run_vm, both with the scopes
  fib  +5.1%   methods  +1.7%   tables  +4.0%   strings -0.8%

both, C run_vm as it ships against Zig run_vm as it now ships
  fib  -8.9%   methods -10.2%   tables  -1.8%   strings +0.5%
```

The port is nearly free. The scopes are the whole of the difference. But
performance is the smallest of the three reasons to reverse, and it is worth
recording the other two, because a future increment that wants the scopes back
should have to answer them.

**The scope machinery is C written to serve a Zig caller.** `janet_vm_scoped`,
`janet_vm_error_string`, `JanetVmTryState`, `vm_scope_enter` and
`vm_scope_leave` exist for no other reason. Defaulting them on would have the
increment that moves the interpreter into Zig add C underneath it, which is the
wrong direction for a project measured in how much C is left.

**They would make `run_vm` an exception to a rule the runtime already relies
on.** SPIKE-8 established that a Zig frame carrying no `defer` may be abandoned
by a passing `longjmp`, and Phase 8 shipped on exactly that: `janet_in`,
`janet_get`, `janet_equals`, `janet_compare`, `janet_lengthv` and
`janet_next_impl` are all Zig, all called directly by `run_vm`, and all raise
through their own Zig frames today. Scoping `run_vm` would not remove a single
one of those jumps; it would only add a mechanism beside them.

And neither setting is closer to the end state, which has no `setjmp` *and* no
`longjmp` — raises become returns threaded through the callees, which is work on
`janet_get` and `janet_table_put` and the cfunctions rather than on the loop.
The call-site shape that end state needs is present either way, because the
difference between the two mechanisms is confined to `scoped` and `raiseSignal`,
about ten lines, and every one of the seventy-eight arms reads the same under
both: make the call, check the signal, propagate it.

Phase 7's exit gate is unaffected in substance and worth restating precisely. No
`longjmp` crosses a Zig frame that has anything to release, which is what the
gate was protecting; `run_vm` now joins the Phase 8 subsystems in relying on
jump transparency to say so, and `build.zig` enforces the "nothing to release"
half by rejecting `defer` and `errdefer` in any file carrying the marker.

### The seam

Six symbols, in both directions.

| symbol | direction | was |
| --- | --- | --- |
| `janet_run_vm` | Zig provides | `static run_vm` in `vm.c` |
| `janet_check_can_resume` | C provides | `static` in `vm.c` |
| `janet_continue_no_check` | C provides | `static` in `vm.c` |
| `janet_vm_trace` | C provides | the `vm_do_trace` macro |
| `janet_vm_scoped` | C provides | twenty-five `scoped_*` wrappers |
| `janet_vm_error_string` | C provides | `static vm_error_string` |

`run_vm` is renamed for the reason Part 2 renamed five of its callees: a
static's name becomes a library symbol the moment its definition moves to
another translation unit, and `run_vm` is too general a name to put in one. The
export is hidden, as Part 2's nine are, so the two selectors' dynamic symbol
sets stay identical.

`janet_vm_trace` takes the *fiber* rather than a pointer into its stack, and
that is the whole reason the C original is a macro rather than a function:
`janet_eprintf` can resize the stack, so `fiber->data + fiber->stackstart` has to
be recomputed for every element traced. Handing Zig a pointer would freeze it at
the first. It is compiled under both selectors so that the two archives hold the
same symbols.

`janet_vm_scoped` is the interesting one. The `setjmp` has to live in a C frame,
so that much cannot move; what moves is the choice of *what* runs inside it,
which belongs with the interpreter. `vm.c` spells that choice as twenty-five
`scoped_*` wrappers, one per callee — an enumeration of the call graph, which is
exactly what Phase 8's first rule warns against. The Zig side needs one C symbol
and a `comptime` thunk per call site, and the thunk is written by the compiler
from the argument tuple. Measured, the extra indirect call is invisible: with
the scopes on, the Zig loop is +1.7% against the C loop's twenty-five direct
wrappers on the most call-dense workload in the corpus.

### What the contract was built around

`test/vm_run.c` is not an opcode-by-opcode reimplementation of the Janet suites,
which already run every instruction — thirty-eight of them execute before this
binary reaches `main`. It pins the three things they do not.

**The fifteen messages the loop raises itself**, byte for byte. These are the one
part of `run_vm` no Janet program checks and every Janet programmer reads, and
under the Zig selector every one crosses the C variadic ABI, where a mismatch
produces a plausible wrong message rather than a crash.

**The signal rather than the payload.** `JOP_SIGNAL` clamps its operand into the
user range, `JOP_PROPAGATE` passes a child's status upward unchanged, and an
unknown opcode is how a breakpoint reports itself. A contract that only looked at
payloads would pass with all three confused, so these assert what
`janet_continue` returned.

**The resume-state decoding at the head of the loop.** Five flags decide where a
resumed fiber puts its value, whether it re-runs the instruction it stopped on,
and whether it pops a C frame first. Nothing else in the tree reads them.

Four things are deliberately not pinned, all under Phase 8's sixth rule:
`"rhs must be valid 32-bit signed integer, got %f"`, whose tail is undefined and
differs between the two behavioral targets; the three left-shift cases C leaves
undefined; and `"invalid constant"`, `"invalid funcdef"` and the two invalid-upvalue
messages, which the assembler refuses to encode — they belong to the verifier
rather than to the loop. `JOP_SIGNAL`'s lower clamp is unreachable for the same
reason.

### What the mutation sweep found, which was a great deal

Twenty-seven mutations. The first pass caught eighteen and **missed eight**,
which is the worst first-pass result of any contract in this project and the most
useful. Two findings account for most of it.

**The compiler folds constant arithmetic, so a contract written with literal
operands does not test the interpreter at all.** `(- 2 3)` is a load of -1. Every
arithmetic and comparison assertion in the first draft was written that way, and
the sweep proved it by swapping the operands of every binary opcode without
failing a single one. Every operand in the contract now comes from a function
parameter. This generalises past this file: a contract for anything the optimizer
can see through has to keep its inputs away from it.

**A call in tail position is a different opcode.** All four arity-message
assertions were written as `(defn g [] (f))`, which is `JOP_TAILCALL`, so
`JOP_CALL`'s identical-looking message — a separate format call in both
implementations — was never reached. Inverting one plural survived. The contract
now forces a non-tail call with arithmetic around it.

The remaining six were ordinary gaps: no negative immediate operand anywhere, so
reading the signed field unsigned survived; no permanent breakpoint, so the mask
the loop applies to its first opcode was never exercised (`janet_step` restores
the instruction words, so only `debug/fbreak` reaches it); no `next` over a fiber
whose signal escapes its mask, which is the only thing `janet_next_impl`'s
`is_interpreter` argument changes; and no shift count above `INT32_MAX`, which is
the one well-defined way to tell the two operand narrowings apart.

The final pass is **25 caught, 0 that never ran, 2 missed**, and both survivors
are equivalences rather than holes:

- *The type check in `JOP_EQUALS_IMMEDIATE`* is redundant under either NaN-boxed
  layout, because every non-number unwraps to a NaN and a NaN compares false
  against everything. Removing it is caught under `-Dnanbox=false`, where a
  tagged nil unwraps to `0.0` and `(= nil 0)` becomes true — verified by hand,
  since the sweep builds one configuration.
- *`JANET_FIBER_RESUME_NO_USEVAL` and `JANET_FIBER_RESUME_NO_SKIP`* cannot be
  told apart by any reachable state. Every site that sets one sets the other,
  except `JOP_PUT` and `JOP_PUT_INDEX`, which set `NO_USEVAL` alone and clear it
  three lines later; escaping that window needs a raise, after which the fiber is
  `:error` and cannot be resumed.

One harness note, and it has now cost this project twice. **A mutation sweep must
bound the mutant's run time.** "Resumed fiber re-runs its instruction" turns the
interpreter into an infinite loop, and without a timeout the sweep wedges and
leaves a process spinning at 100% until somebody notices — two such processes
from Phase 8's sweep were still running, ten hours of CPU each, when this
increment started. The harness now kills a mutant after twenty seconds and counts
the hang as caught, which it is.

### What this cost

Measured with `probe-9/bench/run.sh`, five interleaved rounds at
`-Doptimize=ReleaseFast`, minimum per workload. Baseline is `-Dvm-run=c` as it
ships; candidate is the Zig loop as it now ships.

```text
workload           base       cand    delta
arithmetic       0.0503     0.0488     -2.8%
fib              0.0275     0.0267     -2.6%
methods          0.0300     0.0278     -7.3%
tables           0.0764     0.0742     -2.9%
strings          0.0553     0.0547     -1.0%
compiler         0.0573     0.0567     -0.9%
pegmatch         0.0377     0.0370     -2.0%
```

All seven are faster, `methods` by enough to be worth believing and the rest by
one to three percent, which is at the edge of what this corpus resolves. An
earlier run of the same comparison, taken before two runaway processes from
Phase 8's mutation sweep were noticed and killed, put `methods` at -10.2% and
`fib` at -8.9%; the direction agreed and the magnitudes did not, which is a
reminder to check what else is on the machine before quoting a number.

Almost none of this is the loop: the same comparison with the trampoline forced on for both sides
puts the Zig loop within ±5% everywhere, so what the corpus is showing is mostly
Part 2's inlining recovered plus the scopes never switched on.

Two costs are worth naming rather than leaving in the delta. The value layer had
to be imported before any of this was true — through the symbol table the
arithmetic workload was 89% slower, and that number is the reason `ops` exists.
And `-Dvalue-wrap=c` now carries that cost by design: it is the only
configuration in the matrix where anybody pays a call for a type check, and it is
the price of asking a C-selected value layer to answer for a Zig loop.

The `methods` regression Part 2 recorded is gone. `-Dvm-calls=c` still has it, for
the same reason it had it before, which is now visible as a selector cost rather
than as a port cost.


## The entry points

Phase 9 Part 4. `-Dvm-entry=c` restores the C implementation; Zig is the
default. Six functions, all of them above `run_vm`: `janet_step`, `janet_call`,
`janet_pcall`, `janet_continue`, `janet_continue_signal` and
`janet_check_can_resume`. Five are public API and keep their names; the sixth
lost `static` in Part 3 and is declared in `state.h`.

`janet_continue_no_check` did not move and does not move in this phase. Phase
7's fourth rule keeps it in C because it holds the `jmp_buf` that every fiber
resume re-establishes.

### The seam now runs in both directions

Part 3's seam was one-directional: a Zig `run_vm` called down into C. Part 4
puts Zig on the other side of the same C function, and `janet_continue_no_check`
becomes the hinge. It calls `janet_run_vm` downward and `janet_continue`
sideways, and under the default selectors both of those are Zig. Nothing had to
be added to make that work — a static's name became a library symbol in Part 3
and the calls resolve at link time either way — but it is the first place in the
project where a C function sits *between* two Zig ones, and it is worth naming
because the next phase removes it.

### Not a folded module, and why that is the right answer here

Part 3's rule is that a subsystem the interpreter touches on every instruction
is `@import`ed rather than linked, because a translation-unit boundary on the
value layer cost the arithmetic workload 89%. None of these six is on that path.
`janet_call` runs once per C-to-Janet call, against a `janet_fiber_pushn`, a
`janet_fiber_funcframe` and the whole of `run_vm`; `janet_step` runs once per
debugger step and installs two breakpoints while it is at it.

So `vm_entry.zig` is an ordinary object that reaches the value layer through the
symbol table, which has the pleasant consequence that `-Dvalue-wrap` is honoured
by the linker rather than by a shim. The rule is about the per-instruction path,
not about Zig objects in general, and applying it here would have bought nothing
and coupled two selectors.

### One thing stayed in C, and it needed a second signature

`janet_call`'s trace line. `vm_do_trace` is a macro over `janet_eprintf`, which
is itself a variadic macro over `janet_dynprintf` and does not survive
translation. Part 3 met this and exposed the macro as `janet_vm_trace`, taking
the *fiber* rather than a pointer into its stack, because `janet_eprintf` can
move that stack between elements and the address has to be recomputed each time.

That signature cannot serve `janet_call`, which traces the array its own caller
passed. So `vm.c` gained `janet_vm_trace_argv`, the same macro over a
caller-owned `argv`, defined under either selector so the two archives hold the
same symbols.

The hazard the fiber-taking signature exists to survive is real, and looking for
it here turned up where it does bite. `janet_dynprintf`'s `JANET_FUNCTION` case
calls the `:err` handler through `janet_call`, so every `janet_eprintf` inside a
trace re-enters the interpreter on the same fiber. The macro recomputes `argv`
and survives that; `vm_commit()` writes through `run_vm`'s own local `stack`
pointer and does not. `FOUND.md` has the reproduction — a traced call in
non-tail position with a stack-growing `:err` handler traces twice, the second
time with the return value where the first argument was, and then aborts. Both
selectors fail identically, which is the port reproducing the original rather
than diverging from it.

### `janet_check_can_resume` is exported hidden

It is declared in `state.h` rather than in `janet.h`, so the C build hides it
under `-fvisibility=hidden`. A plain `export fn` does not, and the first build
of this increment widened the shared library by exactly one symbol. Written as
`@export(&checkCanResume, .{ .visibility = .hidden })` instead, both artifacts
carry the same 1209 archive symbols and the same 706 dylib symbols under either
selector. This is the fifth subsystem to need it and the first where the two
selectors would otherwise have disagreed, which is what makes it worth checking
per increment rather than per phase.

### Jump transparency, and what `janet_call` does not hold

`vm_entry.zig` carries the marker. Under the default every panic below
`janet_run_vm` is a `longjmp` to the `setjmp` in `janet_continue_no_check`, so
`janet_call`'s frame is abandoned along with the loop's — and nothing in it is
lost. `janet_gclock`'s handle and the `stackn` bump are both restored by
`janet_restore` on the way out, which is why the C original does not release
them on that path either, and the guard frame a dirty stack gets belongs to a
fiber the jump has already unwound. `build.zig` enforces the other half by
rejecting `defer` in a file carrying the marker.

Under `-Dcall-trampoline` the shape changes and the file does not: `janet_run_vm`
returns the signal instead of jumping, the teardown runs, and `janet_panicv` at
the end raises from this frame rather than from a deeper one. Both are the C
behaviour and neither needed a branch here.

### What the contract was built around

`test/vm_entry.c`, seven panics and ten reports, verified against `-Dvm-entry=c`
before it was trusted against Zig.

The organising question is *which mechanism* each refusal uses, because the same
message delivered the wrong way turns a recoverable error into an abort. Four of
the six only ever return a `JanetSignal` and two raise, and the split is not
where a reader would guess: `janet_step` raises for a fiber it will not step
while `janet_continue` reports for a fiber it will not resume, and `janet_pcall`
reports even the arity failure that `janet_call` raises three different messages
for.

The rest is state that no return value shows. `janet_check_can_resume` marks the
fiber errored for one of its three refusals and not the other two.
`janet_pcall` writes its out-parameter before it decides whether it failed, so a
caller reusing a fiber sees it cleared rather than stale. `janet_call` restores
`stackn`, the collector lock and a dirty stack on the way out, and the dirty-stack
case is set up deliberately from a cfunction because nothing in the tree
produces one. And `janet_step` writes breakpoints into the funcdef every fiber
over that function shares, so each stepping test ends by running the same
function normally and checking it still works.

Three things needed a running fiber underneath them — the root-fiber refusals,
the arity messages, the dirty stack — and get it from a registered cfunction
rather than from a fixture, which is the same idiom `test/vm_calls.c` uses.

The coercion message is the one that took arranging. `janet_call` sets
`coerce_error`, so a signal the loop *returns* rather than raises becomes an
error naming the signal it came from. Reaching it needs a Janet function entered
through `janet_call` rather than through `JOP_CALL`, and the binary operator
fallback is the way in: `(+ t 1)` on a table looks `:+` up as a method, and
`janet_method_invoke` calls `janet_call` for a Janet function. A `yield` in that
method comes back as `"5 coerced from yield to error"`.

### What the mutation sweep found

Thirty-four mutations, all caught, none vacuous. The two that had to be repaired
before that was true are the interesting ones, and only one of them was a
mutation problem.

`the gate admits the running fiber` did not compile: `JANET_STATUS_SUSPENDED`
does not exist without the event loop. Rewritten to drop the `ALIVE` term
instead. A mutation that will not compile never ran, which is the rule Part 3
established and the harness still prints in those words.

`step skips an instruction` — `nexta = pc + 2` — was missed, and it was the
contract's fault. Stepping was asserted with `steps > 1` and `steps > 6`, which
is a scalar summary of something structural: a stepper that visits every other
instruction still terminates, still produces the right answer, and still takes
more than one step. **Assert the structure, not a summary of it.** The
straight-line case now asserts that the offsets stopped at are exactly
`1..bytecode_length-1`, in order, and the branching case scans the funcdef for
the conditional jump and asserts that stepping stopped at *both* of its
successors. That second assertion is what pins `nextb`, which is the only reason
`janet_step` is more than four lines, and the step count would have caught it
only by accident — nineteen with the branch target breakpoint and fifteen
without, a difference that says nothing about why.

### What this cost

Measured with `probe-9/bench/run.sh`, seven interleaved rounds at
`-Doptimize=ReleaseFast`, minimum per workload. Baseline is `-Dvm-entry=c`;
candidate is Zig. Both sides have the Zig `run_vm`, so this isolates the six
entry points.

```text
workload           base       cand    delta
arithmetic       0.0488     0.0488     -0.0%
fib              0.0265     0.0266     +0.5%
methods          0.0276     0.0280     +1.3%
tables           0.0754     0.0761     +0.9%
strings          0.0552     0.0545     -1.2%
compiler         0.0563     0.0575     +2.0%
pegmatch         0.0373     0.0373     -0.1%
```

That table is not the measurement, and saying so is the point. **No workload in
the corpus enters the interpreter through `janet_call`.** `fib` and `methods`
look like they should — they are the call-heavy pair — but a Janet function
called from Janet goes through `JOP_CALL`, and a keyword method is resolved and
then called the same way. What the corpus establishes is the negative result
worth having: moving the entry points costs nothing anywhere else, and every
figure above is inside the ±2% this corpus resolves.

For the path this increment actually owns, two loops reach `janet_call`. The
binary operator fallback does — `(+ t 1)` on a table looks `:+` up and
`janet_method_invoke` enters a Janet function through `janet_call` — and so does
a PEG capture whose constant is a function, which `peg.c` calls once per match.
Nine interleaved rounds, same optimize mode:

```text
workload           base       cand    delta
opfallback       0.0203     0.0208     +2.3%
pegcall          0.0323     0.0327     +1.4%
```

Run with the roles swapped as a control, the C side comes out 0.9% and 2.4%
ahead, so the direction is stable across three pairings and the magnitude is
one to three percent. It is a real cost rather than noise, and it is charged to
the C-to-Janet call boundary rather than to anything a Janet program does in a
loop.

Two things were ruled out rather than assumed. Binding `&c.janet_vm` to a local
once instead of re-reading it at every use — the C original re-reads it through
a macro, and `janet_vm` is `_Thread_local` — made it *worse*, so the thread-local
lookup is not where the time goes. And the folded-module treatment Part 3 needed
is not the answer either: the value operations `janet_call` performs on its hot
path amount to one `janet_wrap_nil`, against a `janet_fiber_pushn`, a
`janet_fiber_funcframe`, a `janet_gclock` and the whole of `run_vm`.

The machine was not quiet for these runs — a system media-indexing daemon held a
core throughout — which is why the swapped control is here. Interleaving puts
the drift on both sides and the minimum is the right statistic under one-sided
noise, but the rule from Part 3 stands: check what else is running before
quoting a figure, and say so when it was not clean.

## The runtime's lifecycle, and the second reader of a stack frame

Phase 9 Part 5. Two subjects and two selectors, because the increment has two
and the acceptance matrix has to be able to revert them separately:
`-Dvm-lifecycle=c` restores the C `janet_init`, `janet_deinit`, `janet_sandbox`
and `janet_sandbox_assert`; `-Ddebug-frames=c` restores the C `doframe`. Zig is
the default for both.

### `janet_init` is a transcription, and the order in it is load-bearing twice

Thirty-odd assignments in the same order as the original, which matters in two
places and nowhere else. `janet_symcache_init` runs after the collector's fields
and before anything allocates. The abstract registry is created and rooted after
the root set exists — it is the first allocation of the process and the first
thing rooted, so `janet_init` leaves `block_count` at one and `root_count` at
one rather than at zero.

What `janet_init` does *not* touch is the part worth stating, because a port is
tempted to tidy it. `signal_buf`, `return_reg` and `coerce_error` belong to
`janet_try`; `gc_suspend` to `janet_gclock`; the symbol cache's four fields to
`janet_symcache_init`; `rng` to `janet_rng_seed`. Zeroing them here would be a
change to established behaviour dressed as thoroughness.

The sandbox is four lines, and the one-way property is the whole of it:
`janet_sandbox` calls `janet_sandbox_assert(JANET_SANDBOX_SANDBOX)` on itself
before widening the flags, so a sandbox that has forbidden sandboxing cannot be
widened again — including with an empty set. That is pinned directly rather than
through a standard-library function that happens to check a flag.

### `doframe` becomes the second consumer, three years of duplication later

`debug.c` decoded a stack frame twice, independently: once for
`janet_stacktrace_ext`, which Phase 7 Part 8 moved to `trace_frames.zig`, and
once in `doframe`, which builds the table `debug/stack` returns. Written
separately, they had drifted. `janet_trace_frame` tests `NULL != reg` before
reading a cfunction registry entry; `doframe` did not, and `debug/stack` on a
cframe holding a cfunction that never went through `janet_cfuns` dereferences
null. That is `FOUND.md`'s entry, and its own text predicted this increment as
its expiry.

`debug_frames.zig` calls `janet_trace_frame` — through the symbol table, which
is Part 4's rule and keeps `-Dtrace-frames` independent of `-Ddebug-frames` — so
the registry lookup, the name classification and the source-map read happen once
in the tree and the null check comes with them. Measured, decoding a cframe with
an unregistered cfunction:

```text
-Ddebug-frames=c   thread panic: member access within null pointer of type
                   'JanetCFunRegistry'  (src/core/debug.c:378)
default (zig)      decoded: <table 0x600003891C50>
```

The C side is untouched, so it still segfaults; that is the control, not an
oversight.

**What the descriptor deliberately does not carry**, and why this is a second
consumer rather than a merge. `JanetTraceFrame` exists to print one line of a
stack trace, and `debug/stack` wants more than a line. Three things come from
the funcdef directly — `:pc`, which `doframe` reports for every frame with a
program counter while the descriptor carries it only when there is *no* source
map; `:slots` and `:locals`, which have nothing to do with printing a line; and
`:source` for a Janet frame, which `doframe` emits only inside its
`func && pc` branch. Two more differences go the other way and are preserved by
reading the descriptor's *kind* rather than its fields: a registry entry with a
source line and no name gives `LOC_CFUN_LINE`, and a stack trace prints
`<cfunction> on line 42` where `debug/stack` prints nothing, so the check here is
on `NAME_CFUNCTION` first. And `doframe` hard-codes `:source-column` to 1 for a
cfunction, which is not a column the descriptor has or could have.

None of those is a gap in the descriptor. They are two consumers of one decoding
that legitimately want different things, which is exactly why the decoding is
worth sharing and the presentation is not.

### `janet_debug_frame` is exported hidden, for the second time in two parts

Declared in `state.h` rather than in `janet.h`, so the C build hides it under
`-fvisibility=hidden` and a plain `export fn` does not. The first build of this
increment widened the shared library by exactly one symbol, which is what Part 4
found with `janet_check_can_resume` and is now the second time in two
increments. Written as `@export(&debugFrame, .{ .visibility = .hidden })`
instead, both selectors carry the same 1210 archive symbols and the same 706
dylib symbols. The check belongs in the per-increment list rather than the
per-phase one, and both of these would have shipped without it.

### One test module gets a selector macro, and it is the first

`test/vm_lifecycle.c` has one assertion that cannot run under
`-Ddebug-frames=c`, because what it pins is a null dereference the C original has
and the port does not. `build.zig` gives that module `JANET_ZIG_DEBUG_FRAMES`;
every other assertion in the file runs under both selectors, and no other test
module in the tree is given a selector macro. The alternative was to leave the
fix unpinned, which would have made the increment's whole point untestable.

### What the contract was built around

Four panics, and two subjects.

For the lifecycle, the organising idea is that **`janet_init` assigns rather
than assumes**. Every field it sets is scribbled on before it is called, so the
post-init assertions are about what `janet_init` wrote rather than about what a
freshly zeroed `janet_vm` already held. Three fields — `next_collection`,
`weak_blocks`, `block_count` — are invisible without that, and the mutation
sweep proved it: removing `root_count = 0` from `janet_init` survived a contract
that did not scribble, because `janet_deinit` happens to leave it at zero. A
teardown that leaks looks identical to one that does not until something reuses
the runtime, so two full cycles run afterwards, each doing real work.

For the frames, the subject is the table's keys, and the geometry is written
down rather than checked for type. A source map that swapped line for column
passes any assertion that only checks both are numbers, so the probe function is
laid out in the contract with its line and column stated — `(debug/stack` opens
at line 4, column 11 — and both are pinned. The register file is checked for
contents as well as length, for the same reason.

The local bindings needed the most care. `:locals` is built with
`janet_table_put`, and **a table with a nil value is a table without the key**,
so a binding wrongly reported as live but holding nil is indistinguishable from
one correctly left out. The probe therefore carries a `let`-scoped binding that
goes out of scope while its register still holds a value: reported live, it
shows up holding a fiber, which is visible. Both branches of the captured-binding
case are covered too, and the difference between them is one pair of parentheses
— a closure called in tail position loses its enclosing frame and reads its
capture out of a detached environment, while the same closure called in
non-tail position reads it off the stack.

### What the mutation sweep found

Forty mutations, all caught, none vacuous — after four repairs to the contract
and one to a mutation.

Three of the four contract repairs are the lessons above: the scribble, the
`let`-scoped dead binding, and the register contents. The fourth is a reminder
that a contract can be strengthened by *changing the fixture rather than the
assertion*. Dropping the name prefix from a cfunction frame survived the first
sweep, because every core cfunction is registered with its qualified name in
`name` and a null `name_prefix` — so `debug/stack`, the only cfunction the
contract had looked at, could not tell a dropped prefix from a kept one. The
contract now registers its own cfunction through `janet_cfuns` with a prefix,
and that fixture also pins the two keys a registry entry with no source file and
no source line must not produce.

The mutation that had to be repaired is the familiar one: `} else if (false) {`
left `pc` unused and would not compile. Rewritten as a condition that is always
false at run time and uses its operands, it is caught.

### What this cost

Nothing measurable, and nothing measurable was expected. `janet_init` and
`janet_deinit` run once per process; `janet_sandbox_assert` is a mask and a
branch on a field the branch predictor sees constantly; `janet_debug_frame` runs
when a program asks where it is. The benchmark corpus is unchanged within noise
and is not reproduced here, because a table of seven flat numbers for an
increment that touches nothing in a loop would be noise dressed as evidence.
Part 4's note applies: check that the corpus reaches the increment before
reading its numbers.

## Closing the gate on the interpreter

Phase 9 Part 6, and the second increment in the project that ports nothing.
Everything the phase set out to move was Zig at Part 5 — save
`janet_continue_no_check`, which holds a `jmp_buf` and which Phase 7's fourth
rule puts beyond this phase — and what was left was the exit
gate — the bootstrap image, the full corpus, the benchmark corpus against the
Phase 8 baseline, and the cross-compiles. Three of those four turned out to have
a hole in them, the cross-compiles were the one clean clause, and a fifth finding
came out of a check the gate added rather than inherited. The holes are the
interesting part.

### The bootstrap image had never been generated by the Zig runtime

`janet-boot` was built from C in every configuration, including the ones where
every selector said `zig`. So the image the Zig runtime embeds — the whole core
library, compiled and marshalled — had been produced by the C implementation in
every phase up to this one. Nothing was wrong with that, and nothing had checked
it either.

`-Dboot=<c|zig>` gives the image generator the same selectors as the runtime,
and `zig build image` writes the generator's output on its own rather than
linking something against it. The two agree byte for byte:

```
-Dboot=c     b187b036…8666
-Dboot=zig   b187b036…8666      324,831 image bytes
```

That is the most discriminating single comparison in the tree. The image is the
output of the parser, the compiler, the interpreter and the marshaller run over
the 5,147 lines of `boot.janet`, and a difference anywhere in any of them moves
the bytes.

**Both halves of "identical" were checked.** A comparison that passes because
nothing changed is worth nothing, so: the `-Dboot=zig` binary carries 98 `.zig`
symbol references where the C one carries none, and a one-line mutation to
`movopt.zig` — return before eliminating any dead write — changes the image.
The comparison is sensitive to the Zig path rather than merely to the file.

Two smaller things came with it. `build()`'s 224-line subsystem literal became
`makeSubsystems`, which is the name `makeVmRunObject`'s doc comment had already
been using for a function that did not exist; the bootstrap needs a set of its
own because it runs on the build machine, whatever `-Dtarget` says. And
`addRuntimeSources` now takes an optional image, because the bootstrap compiler
is the one runtime built without one: it is what produces it.

**`-Dboot` defaults to `c`.** Phase 9's gate is a measurement of the Zig
generator, not an adoption of it; making the image generator's selectors follow
the runtime's would double the subsystem objects on every cross build for no
gain until Phase 10, whose plan owns the bootstrap clause.

### The benchmark corpus did not reach the phase

Part 4 recorded the lesson and then let the evidence go. No workload in
`probe-9/bench/` enters the interpreter through `janet_call` — `fib` and
`methods` are call-heavy, but a Janet function called from Janet goes through
`JOP_CALL` — so the entry points were measured with two loops built for the
occasion and thrown away afterwards. A gate should not have to re-derive them.

Three workloads are now permanent, and the corpus is ten:

- `opfallback` — `JOP_ADD` meets a value it cannot add, and `janet_binop_call`
  enters the method through `janet_call`.
- `pegcall` — a PEG capture holding a Janet closure. The PEG engine is C, so
  the only way back into Janet is an entry point.
- `fibers` — 150,000 create-resume-resume cycles, which is `janet_continue` and
  the resume check.

### Two opcodes had never been executed by anything

`test/vm_run.c` is built on the premise that the Janet suites already run every
instruction, and the phase's plan asks for every opcode to be tested directly.
Neither had been measured, and `nextOp` makes measuring it easy: every
`continue :sw` in the loop goes through that one function, so a tally there and
one on the opcode the loop is entered with counts every dispatch exactly once.

Across 35 suites and 55 contracts, 75 of 77 opcodes execute. The two that never
did are unreachable from the compiler by construction rather than by omission:

- **`JOP_NOOP`** is *written* by the dead-write optimizer and then deleted by
  no-op removal before the function is ever run. The pipeline guarantees that no
  compiled function contains one.
- **`JOP_MAKE_STRING`** has no emitter anywhere in the compiler. `(string ...)`
  compiles to a call of the `string` cfunction; the opcode exists in the loop and
  only the assembler can produce it.

The second one is the sharper finding, because **it was already written down in
this file.** SPIKE-8's probe notes say it — "The assembler, not the compiler.
`JOP_MAKE_STRING` is never emitted" — as an aside about how to reach a callback,
in a section three thousand lines above the one you are reading. The fact was
known, it was recorded, and it never became a test. That is what a census is for:
knowing which opcodes the compiler cannot emit is not the same as executing
them, and only one of the two is checkable by a machine.

Both are now assembled directly in `test/vm_run.c`, and `disasm` confirms the
assembler leaves the `noop`s in place rather than optimizing them away. The
census reads 77 of 77. `probe-9/census/` has the harness, which is a temporary
source instrumentation rather than a build option, and the README there has the
recipe.

### A contract that could not be built without the assembler

`-Dassembler=false` was not in Parts 3 to 5's matrices, and it fails: nine
fixtures across `test/vm_run.c` and `test/vm_lifecycle.c` call `asm`, an absent
binding is a *compile* error rather than a runtime one, and it surfaces as an
assertion inside `eval` with the message buried. `test/suite-asm.janet` has
guarded against exactly this since the Phase 8 commit that fixed the suites'
guards, but no C contract had ever needed one, so the pattern had not reached
the Phase 9 contracts.

They are guarded now, and the two expected-count constants are conditional with
them — 25 errors against 21, four panics against three. A count that is not
adjusted with its guard turns a skipped assertion into a failure, which is the
same class of mistake one level down.

### What the leak sweep and the second platform say

Phase 8's gate ran `leaks --atExit` over every contract binary rather than a
sample, and left the loop and its four exclusions behind as a recipe. Re-run
here, now that the interpreter, its entry points and the runtime's lifecycle are
Zig: the loop's four exclusions leave **51 of the tree's 55 contract binaries
checked, 50 of them clean, and the one remaining line is
`janet-args-core-test`** — the same open item Phase 8 left, unchanged and still
unsilenced. Phase 8 checked 47 of 51 on the same terms. The four contracts this
phase added leak nothing.

The container recipe puts the aarch64 numbers at **55 contracts and 35 suites,
none failing**, up from Phase 8's 47 and 34. That build runs a host-generated
image on another architecture, which is the only evidence anywhere that the
image is architecture-neutral; it has never been run on a 32-bit target, whose
binaries are deliberately not executed for the ABI reason `PLAN.md` records.

### What the phase cost, measured end to end

The gate's benchmark is the one this project has been building toward: Phase 8's
binary, whose `vm.c` is entirely C, against HEAD, whose interpreter loop, callee
side, entry points and lifecycle are all Zig. Both at `-Doptimize=ReleaseFast`,
interleaved, minimum per workload over five rounds.

The machine could not be made quiet — macOS's Spotlight and media-analysis
daemons were running throughout and the one-minute load average never fell below
about 3.5 — so the comparison was run with the roles swapped as well, which is
what `PLAN.md` says to do when it cannot. A delta that keeps its direction
across both pairings is real; one that flips is not.

| workload   | Phase 8 → HEAD | swapped | verdict                |
|------------|----------------|---------|------------------------|
| arithmetic | −5.9%          | +4.0%   | **Zig faster, ~5%**    |
| fibers     | −2.8%          | +2.6%   | **Zig faster, ~2.7%**  |
| fib        | −2.0%          | +2.8%   | **Zig faster, ~2.4%**  |
| tables     | −1.4%          | +1.6%   | **Zig faster, ~1.5%**  |
| strings    | −1.2%          | +1.3%   | **Zig faster, ~1.2%**  |
| compiler   | −0.1%          | +0.5%   | flat                   |
| pegmatch   | −0.2%          | +0.3%   | flat, as designed      |
| opfallback | +0.8%          | −1.2%   | **Zig slower, ~1%**    |
| methods    | −0.7%          | −2.3%   | direction flips — noise|
| pegcall    | +0.8%          | +0.5%   | direction flips — noise|

Three things in that table are worth saying out loud.

**The interpreter is faster, and the most dispatch-dense workload is the one it
gains most on.** That is the same shape Part 3 measured for `run_vm` alone, and
it survives the whole phase being stacked on top of it.

**`pegmatch` is the control and it did not move.** It spends its time inside
`peg.c`, which this phase did not touch. A corpus where the control drifts is
measuring the machine rather than the change, and this one does not.

**The one real regression is where Part 4 said it would be.** `opfallback` is
the binary operator fallback, which is `janet_call`, which is Part 4's subject —
and Part 4 measured 1.4% to 3.3% there against a purpose-built loop. About 1%
survives at the phase level. It is the cost of an entry point that used to be
inlined into `vm.c` and is now an object boundary, it is paid only by calls that
enter the interpreter from C, and it is not worth an import folding of the kind
Part 3 needed: nothing on the per-instruction path goes through it.

`methods` and `pegcall` flip direction between the pairings and are reported as
what they are. Both are short — `pegcall` is the shortest workload in the corpus
at seven milliseconds — and on a machine under this much background load, a
sub-1% figure over seven milliseconds is not a measurement.

### The Zig build exports 257 symbols the C build hides

The per-increment symbol rule compares the increment's *own* selector: build
with `-Dvm-entry=c` and with `-Dvm-entry=zig`, and check that the archives and
the shared library carry the same names. That is what caught
`janet_check_can_resume` in Part 4 and `janet_debug_frame` in Part 5, and it is
the right check for the question it asks. It is not the right check for the
question nobody had asked, which is what the *whole* scaffold does to the shared
library's surface.

Default against every one of the fifty-three selectors set to `c`:

```
libjanet.dylib   zig 706   c 449   257 names in the Zig build and not the C one
                                     0 names in the C build and not the Zig one
```

It is purely additive, and **not one of the 257 is public API** — every name is
checked against `janet.h` and none appears there. They are internal helpers:
27 `janet_arg_*`, 27 `janet_os_*`, 21 `janetc_*`, the `janet_zig_*` families,
and — the one worth naming on its own — `janet_vm`, the thread-local VM state
itself.

The cause is a one-line asymmetry the tree has carried since Phase 3. C sources
are compiled with `-fvisibility=hidden`, so anything not marked `JANET_API` is
hidden in the shared library; a plain Zig `export fn` takes default visibility
and is not. Parts 4 and 5 each fixed one instance by hand with
`@export(..., .visibility = .hidden)`, and both times the note said this was the
second occurrence in two increments. It was the two hundred and fifty-sixth and
seventh.

**Recorded rather than fixed, and the reason is not that it is large.** The cost
of leaving it is bounded and mostly theoretical here: the ABI surface is
migration scaffold that Phase 10 removes, and macOS's two-level namespace makes
intra-library calls direct regardless. What is *unmeasured* is ELF, where an
exported symbol is preemptible and a `janet_vm` that could have been local-exec
TLS may not be — a cost this project's benchmarks, all taken on macOS, are
structurally unable to see.

The fix is also not the obvious one. Marking 257 exports hidden by hand is a
change to fifty files, but the central version — an exported-symbols list on the
shared library link, generated from `janet.h`'s `JANET_API` set — is one place in
`build.zig` and would be *better*. It is deferred because it requires deciding
what the finished runtime's exported surface is, which is Phase 10's question
and not this phase's, and because changing the shipping artifact is not
something a gate increment should do on its own initiative.

What the gate does change is the rule. A per-increment symbol comparison against
the adjacent configuration cannot see anything that is already wrong in both, so
**the phase-level check compares against a fully C build** and is now written
down that way.

### The matrix the gate ran

Twenty-six configurations, of which twenty-three run the whole corpus and three
are cross-compiles: the default; every one of the fifty-three selectors set to
`c` together; the five Phase 9 selectors set to `c`; `-Dboot=zig`; both raise
mechanisms under both selectors; all four optimize modes, with `ReleaseFast`
also run against the C interpreter; tagged values; `-Dnanbox-pointer-shift=2`;
keyed hashing; single-threaded; and the eight reduced builds — no event loop, no
source maps, no docstrings, no interpreter interrupt, no computed gotos, no
assembler (twice, once against the C selectors), no PEG, no FFI. Then
`x86_64-linux-musl`, `aarch64-linux-musl` and `riscv32-linux-musl`.

Earlier increments in this phase ran smaller matrices, each plus the same three
cross-compiles: twenty-three configurations for Part 3, seventeen for Part 4,
nineteen for Part 5. They grew by inheritance, which is the blind spot the
assembler row exposed and `PLAN.md`'s sixth rule for this phase records.

`-Dreduced-os=true` is still not among them, for the reason Part 3 recorded:
`test/helper.janet` calls `os/getenv`, so the Janet suites do not compile in a
build that omits it. That is a property of the harness rather than of the port,
and the contracts themselves pass there.

## Raising by returning

Phase 10 Part 2's mechanism. Everything before this point in the document
describes a runtime where a raise is a `longjmp` and the whole discipline around
it — jump transparency, the ban on `defer`, the three subsystem splits Phase 7
made around "nothing here may raise" — exists to keep that jump safe. This
increment starts replacing it.

`src/zig/raise.zig` is the new file and it holds no `export`. That is not a
detail: it is imported into every subsystem object, and a definition in it would
appear once per object. It offers `Error`, which has one member; `signal`,
`panic`, `panicv` and `panicf`, which raise; `pendingSignal` and
`pendingPayload`, which read what a raise published; and `deliverToC`, which is
the bridge.

### The decision is shared and only the delivery differs

`janet_signalv` was one function that planned, coerced, committed and jumped.
It is now a record and a delivery:

- `janet_zig_signal_record` does the plan, the coercion message, the commit into
  the return register, the fiber flag, and publishes the chosen signal in
  `janet_vm.pending_signal`. It lives with the rest of the signal decision,
  under `-Dsignal-core`, so it has a C implementation to be differential
  against — `capi.c` keeps one and `signal_core.zig` has the other.
- `janet_zig_signal_deliver` is the jump. Three lines in `capi.c`, always C,
  deleted in Part 17 with the `setjmp` it targets.
- A Zig caller calls neither: `raise.signal` records and returns
  `error.JanetSignal`.

`janet_signalv` is now the two called in order, which is what a C caller still
sees.

The point of the split is that the two deliveries cannot drift. Under the jump
the signal travelled as `longjmp`'s second argument and was never stored
anywhere; a Zig error carries no payload, so it needs a home, and giving both
deliveries the *same* home is what makes them the same mechanism rather than two
implementations of one idea. `janet_vm.pending_signal` is that home, added
beside `signal_buf` and `return_reg`, and `test/signal_core.c` asserts that the
value `setjmp` returns is the value the record published.

### What moved languages, and why it could

The coercion message. Through Phase 9 `janet_signal_plan` reported that a
message was needed and *stopped*, because building it renders `%v`, which runs
an abstract type's `tostring` callback, which can panic — and Phase 7's rule was
that no Zig frame may be jumped through. Phase 8 replaced that rule with jump
transparency and nobody revisited the split it had forced. Part 2 did, which is
`PLAN.md`'s Phase 9 rule 2 working as intended rather than an oversight being
found. `JANET_SIGNAL_PLAN_COERCE` stays in the interface because
`-Dsignal-core=c` still answers with it.

### Why there is no `-Draise`

Every other mechanism in this rewrite got a selector. This one cannot have a
useful one. The "C implementation" of an error return is the jump, and the two
cannot coexist inside a single function body — a `-Draise=c` would have to be
spelled at every converted call site, in both shapes, forever.

What replaces it is that a converted symbol keeps **two abis**: the abi
its unported C callers still link against, which catches the error and delivers
it as a jump, and the Zig implementation that returns the error. Those are each other's
differential for as long as any C caller remains, and the last one disappearing
is what Part 17 means.

### What makes the jump safe while both are live

The claim, demonstrated in `probe-10/bridge/` and not merely asserted: a Zig
error is **fully unwound before any jump happens**. An abi catches in its own
frame and only then calls `deliverToC`, so every `errdefer` between the raise
and that frame has already run and the frame the jump leaves owns nothing. The
`ReleaseFast` disassembly shows the cleanup's store and then the branch.

That is the inverse of the arrangement Phases 7 to 9 lived with, where the jump
started deep inside and crossed everything on the way out. It is what lets
`build.zig`'s `defer` ban be retired one file at a time, as each file's callers
convert, rather than all at once at the end of the phase.

`raise.zig` is itself still jump-transparent, for exactly one call:
`janet_formatc` can panic through C. Part 4 takes `pp.c` and that stops being
true.

*It did not.* Part 4 landed and the marker stayed, because the jump is not the
formatter's — it is the abstract `tostring` callback the formatter invokes to
render `%v`, and that is a C function pointer whatever language surrounds it.
See "The formatter, the printer, and the last of the varargs" at the end of
this file.

### The contract, and what the fixture had to have

`test/signal_core.c` gains three tests, and all three are about the field that
is new rather than about the decision, which the existing tests already cover.
The ordinary case checks that a non-coercing signal and its message both arrive
unaltered; the coercing case checks that the signal becomes `ERROR` *and* the
message becomes the coercion string, because forwarding the message unchanged
while coercing the signal is the plausible slip and no suite would see it; and
the third checks that `janet_try` returns what the record published.

One fixture detail is load-bearing, under this phase's inherited rule that the
fixture rather than the assertion is what discriminates: every test scribbles
`JANET_SIGNAL_USER9` into `pending_signal` first. Without that, a record that
never writes the field passes whenever the field already held the wanted value,
which for `JANET_SIGNAL_ERROR` is most of the time.

Four mutants, all caught: publishing `sig` instead of `out_sig`, forwarding the
original message instead of the coercion string, skipping the commit, and never
writing `pending_signal` at all. The sweep found the trap `AGENTS.md` warns
about first — `zig-out/test` is only populated under `-Dinstall-tests=true`, so
the first run of every mutant executed a stale binary and all four "survived".

### The matrix

Eleven configurations plus the three cross-compiles: the default and
`-Dsignal-core=c`, which is the selector this increment changes; single-threaded;
no event loop; tagged values; `ReleaseFast`; `-Dcall-trampoline=true`, because
the trampoline is the other raise path and would otherwise rot; and
`x86_64-linux-musl`, `aarch64-linux-musl` and `riscv32-linux-musl`. The last
matters more than usual here, because this increment adds a field to `JanetVM`.

### The callee side converts first

`vm_calls.zig` is the first subsystem to raise by returning. Six of its
functions — `invokeIndexed`, `methodInvoke`, `callNonfn`, `resolveMethod`,
`unaryCall`, `binopCall` and `mcall` — now return `raise.Error!Janet` and reach
`raise.panicf` instead of `janet_panicf`. `methodLookup` and the three fill
loops are unchanged: nothing in their own bodies raises, and converting a
function that cannot raise buys a signature and nothing else.

The callee layer converts before the loop for a reason that is not sequencing
convenience. These functions call *each other* — `methodInvoke` from four of
them, `invokeIndexed` from `methodInvoke` — so converting them together removes
real jumps immediately, inside the file, rather than only preparing for a later
increment.

### Two abis, and where the `catch` has to be

Each converted function has an abi beside it, and the abis are generated
rather than written:

```zig
pub const callNonfnPanicking = raise.panicking(callNonfn).abi;
```

`raise.panicking` is in `raise.zig` rather than here, because this phase applies
the pattern to every exported function that raises, which is most of them. Two
lines each is not much until it is three hundred of them, and a hand-written
abi that drifts from the implementation it wraps is a silent ABI change rather
than a compile error.

The `@export` block now exports these abis under the original `janet_*` names,
`janet_mcall` included. A C caller cannot consume a Zig error, so the public
entry is the abi and not the implementation.

The position of the `catch` is the entire safety argument and not a style
choice. It is inside the abi, one frame below the implementation, so by the
time control reaches it the error has returned normally through every frame
between the raise and there and the jump leaves a frame that owns nothing. A
mutant that replaces `deliverToC()` with `undefined` *inside the generator* is
caught by `test/vm_calls.c` — the bridge itself under test, rather than the
functions on either side of it.

`raise.panicking` still switches on arity, and that is not a shortcoming of the
generator. A Zig function body cannot be written generically over an arbitrary
parameter list, only over an arbitrary type, so the body has to name its
parameters. Zig 0.16 replaced `@Type` with per-kind builtins and `@Fn` is the
one for function types — `@Fn(params, param_attributes, return_type,
attributes)` — but it constructs the *type*, which inference already gives once
the body exists. Two limits are dropped rather than checked, both currently
vacuous: a parameter's `noalias`, and variadics, which have no abi at all.

### What the loop still does, and what that costs

`vm_run.zig` is unconverted and still reaches these through `scoped`, which
needs a plain return type — so its call sites moved from `vm_calls.callNonfn` to
`vm_calls.callNonfnPanicking` and nothing else about the loop changed. That is
one word at eight sites, and it is the seam the next increment removes: a
converted `run_vm` calls `try vm_calls.callNonfn(...)` and the `Panicking`
spelling survives only for C callers.

`vm_calls_extern.zig` carries both spellings for the same reason, and its
error-returning half is the honest shape of `-Dvm-calls=c`: the C body jumps, so
the error is declared and never returned. A caller written to `try` it compiles
and behaves exactly as it does today, which is what keeps that selector a
selector rather than a second dialect the loop has to know about.

Measured on the Phase 9 corpus at `ReleaseFast`, interleaved, five rounds, and
then again with the roles swapped because the machine could not be made quiet.
Every one of the ten workloads flips direction between the two pairings, `methods`
and `opfallback` — the two that actually reach this layer — included. By this
project's rule for a noisy machine that means none of the deltas are real, and
the honest statement is that the conversion costs nothing measurable rather than
that it costs 0.8%.

### The file is still jump-transparent

Converting these functions' *own* raises does not stop them being jumped
through. They still call `janet_call`, `janet_in`, `janet_get`,
`janet_table_put`, `janet_to_string_b` and third-party cfunctions, every one of
which raises by jumping, and several through a callback a native module
supplied. The marker stays and `build.zig` still rejects `defer` here. It comes
off when the functions in that list have converted, which is what "one file at a
time" means in practice.

### The loop and its front door

`vm_run.zig` and `vm_entry.zig` convert together, which completes Part 2's
subject. The loop no longer jumps: `raiseSignal`, `raisev`, `raisef` and `throw`
return `raise.Error!JanetSignal`, the fifteen helpers that reported "leaving the
loop" as `?JanetSignal` return `raise.Error!?JanetSignal`, `runVm` returns
`raise.Error!JanetSignal`, and `janet_run_vm` is `raise.panicking(runVm).abi`.
Ninety-three `try` sites.

Much less of this was new than the file's size suggests. `run_vm` **already had**
an error-returning shape under `-Dcall-trampoline=true`, where a raise sets the
return register and the fiber flag and returns the signal rather than jumping;
Phase 9 built it, kept it in the acceptance matrix, and it has been passing ever
since. What changed is the carrier, not the structure, and the comment on
`vm_raise_signal` about which sites commit and which do not was already written
for a raise that returns.

`vm_entry.zig` has exactly two functions that raise — `janet_step` and
`janet_call` — and both are `JANET_API`, so the exported names became abis and
the implementations are reached only from Zig. `janet_continue`,
`janet_continue_signal`, `janet_pcall` and `janet_check_can_resume` need no abi
at all: they report a signal rather than raising, which is what makes them the
boundary a caller can already handle.

### One path deliberately not converted

`-Dcall-trampoline=true` keeps its existing bodies. The two paths are not
equivalent in a way that matters here: the trampoline catches a callee's signal
through a C `setjmp` in `scoped` and then calls `raiseSignal` with the signal it
caught, and `raiseSignal` under that flag does *not* re-plan it. Routing that
through `raise.signal`, which does plan, would coerce a signal that had already
been coerced. Converting the non-trampoline path only leaves both correct, and
the trampoline is not the shipping path under either selector.

That flag now describes less than its name suggests, and it will keep shrinking:
a callee that returns an error needs no scope around it, so `-Dcall-trampoline`
becomes vestigial one callee at a time rather than being removed in one step.

### `raise.zig` is under the ban it exists to lift

The file can be jumped through — `janet_zig_signal_record` renders a coercion
message with `%v`, which runs an abstract type's `tostring` callback, which can
still panic through C — so it carries `//! jump-transparent` and `build.zig`
checks it like any other source. It was not checked when it was written, which
is the kind of omission the marker exists to prevent, and the check was verified
to fire by adding a `defer` to it and watching the build fail.

Nothing else can drop the marker yet. `vm_run.zig` still calls `janet_in`,
`janet_get`, `janet_fiber_push` and third-party cfunctions, every one of which
raises by jumping. The per-file retirement `PLAN.md` asks for needs no new
machinery — `checkJumpTransparency` already keys on the marker, so removing the
line *is* the retirement — but no file qualifies until the functions it calls
have converted.

### What the sweep found, including a hole that is not this increment's

Five mutants, three caught: `janet_call` dropping its arity-mismatch raise,
`janet_call` swallowing a non-OK signal from the loop, and an abi returning a
value instead of delivering.

The two that survived are worth recording rather than passing over. Removing
`self.commit()` from `vm_throw` is caught by **nothing in the tree** — not
`test/vm_run.c`, not `test/vm_entry.c`, not the Janet suites. That commit
publishes the program counter so a stack trace names the failing instruction
rather than its predecessor, and nothing anywhere asserts which instruction a
trace names for a `vm_assert` failure. The gap predates this increment — the
call was there before the conversion and was equally untested — but it is a gap,
and it is exactly the shape Phase 9's fifth rule warns about: the rationale for
`test/vm_run.c` leans on the suites executing every instruction, which is true
and is not the same as observing what they report.

### The matrix

Nineteen configurations plus the three cross-compiles: the default; all
fifty-three selectors set to `c` together; `-Dvm-entry=c`, `-Dvm-run=c`,
`-Dvm-calls=c` and `-Dsignal-core=c` individually; both raise mechanisms;
`-Dcomputed-gotos=false` and `-Dinterpreter-interrupt=false`, the two flags that
change the loop's own shape; `-Dassembler=false`; tagged values;
single-threaded; no event loop; and all four optimize modes.

Measured on the Phase 9 corpus at `ReleaseFast`, interleaved, five rounds, both
pairings. Nine of the ten workloads sit inside ±1.4% and flip direction between
pairings; `fib` reads -1.4% and -3.9%, keeping its direction, which on a machine
this noisy is suggestive and not a claim. The honest statement is that removing
the jump from the interpreter costs nothing measurable.

## The first jump to go

Phase 10 Part 3. `asm.c`'s `setjmp` is gone, and it is the first of the three to
go rather than the last because it was never a Janet signal at all: a private
escape in `janet_asm1`, reached from anywhere inside one assembly, whose only
job was to abandon a half-built funcdef and report a message. `janet_asm`
already returned a `JanetAssembleResult` rather than raising, so removing the
jump underneath it needed no bridge, no abi, and changed nothing a caller can
see.

The error set is local — `AsmError`, one member — rather than `raise.Error`.
Nothing in `asm_core.zig` publishes a signal or touches `janet_vm`, and
borrowing the runtime's error would have said otherwise.

### The parent chain collapses, and takes a dead branch with it

A `:defs` entry is `janet_asm1` calling itself with the outer assembler as
parent. In C the child's failure jumped *into the parent's handler*, having
first copied its message across — which made the parent's own check on the
child's result, `if (subres.status != JANET_ASSEMBLE_OK) janet_asm_errorv(...)`,
unreachable whenever a parent existed, which is the only case that branch runs
in. Two mechanisms where one would do, and the reachable one was the jump.

Here the child returns its result and the parent's check is the live path. Same
message, same status, and the message reaches the top by being handed up one
frame at a time.

### The seam did not move

`asm_encode.zig` reaches an assembler through `?*anyopaque` and fourteen
accessors, which is the boundary Phase 5 drew. `asm_core.zig` reimplements those
accessors over a Zig `Assembler` and the encode layer is untouched — not one
line changed there. That is the whole reason this increment is 350 lines rather
than a rewrite of the assembler.

`-Dasm-core=zig` does require `-Dasm-encode=zig`, and `hasAsmCore` in
`build.zig` expresses it: the Zig driver calls the `janet_zig_asm_*` entry
points directly and has no path to the C instruction reader, whose arguments are
resolved by `doarg` against a `jmp_buf` this subsystem does not have. Asking for
the first without the second selects C rather than failing, the shape
`hasProcesses` already uses. The reverse — `-Dasm-encode=zig -Dasm-core=c` — is
what every phase before this one shipped.

### `defer`, not `errdefer`, and what it still does not buy

The four tables are released on every path in the C, so `defer` is the faithful
spelling. What the port buys is that `janet_asm_deinit` was called from three
places — success, nested error, top-level error — and is called from one here.

It does not make the file jump-proof, and the marker is absent deliberately
rather than by oversight. A Janet panic can still cross these frames:
`janet_formatc` renders `%v`, which runs an abstract type's `tostring`, and
`janet_table_put` hashes a key that may be abstract. Such a jump skips the
`defer` and strands the four tables — which is exactly what it does to
`janet_asm_deinit` in the C original. The leak is reproduced, not introduced,
and it closes when the formatter and the containers convert.

### 129 lines that are not ported because nothing calls them

`doarg` and `doarg_1` resolve instruction arguments, and every one of their call
sites is inside the `#ifndef JANET_ZIG_ASM_ENCODE` block. They have been
compiled and never called since Phase 5, in every shipping configuration. They
are guarded out here with the rest of the driver rather than translated, and
they go for good with `-Dasm-encode=c` in Phase 11.

### A pre-existing link failure, found by widening the matrix

`-Dasm-decode=c` did not build, at HEAD as well as here, and had evidently never
been in an acceptance matrix. `janet_c_asm_wrap_integer` is defined in `asm.c`
under `#ifdef JANET_ZIG_ASM_DECODE`, but `asm_encode.zig` calls it too, so
selecting the C decoder while keeping the Zig encoder left it undefined. The
guard is now `defined(JANET_ZIG_ASM_DECODE) || defined(JANET_ZIG_ASM_ENCODE)`.

This is Phase 9's sixth rule collecting again: a matrix that grows by
inheritance tests the increment that assembled it. The fix was three lines; not
knowing was the cost.

### What the sweep found

Three mutants. Dropping the error-index suffix and never resetting `errindex` to
-1 were both caught by `test/asm_encode.c`. **Ignoring a nested assembly failure
was caught by nothing** — not the contracts, not `suite-asm.janet` — which is
the one path whose mechanism this increment changed. The mutant makes the
assembler store a null funcdef and carry on.

`test/suite-asm.janet` gains three assertions for it, and the count went from six
to nine. Worth noting how the hole survived: the branch was *unreachable* in C,
so there was nothing to write a test against, and it became reachable and
untested in the same edit.

### The matrix

Sixteen configurations plus the three cross-compiles: the default; all
fifty-four selectors set to `c` together; `-Dasm-core=c`, `-Dasm-encode=c`,
`-Dasm-decode=c` and `-Ddisasm=c` individually, which is the first time all four
assembler selectors have been exercised apart; `-Dassembler=false`; tagged
values; single-threaded; no event loop; and all four optimize modes.

## The formatter, the printer, and the last of the varargs

Phase 10 Part 4. `pp.c` moves to Zig in three files behind one selector, and
what is left behind is not a subsystem but a calling convention: three variadic
functions and six `va_arg` accessors, kept for a reason that has nothing to do
with Janet.

The three files are `pp_describe.zig`, which renders one value as text;
`pp_pretty.zig`, which lays a structure of them out on a page and writes JDN;
and `pp_format.zig`, which parses a format specifier and drives the other two.
They are the file's three natural layers rather than three arbitrary cuts: only
the second has a width, a depth, a cycle table and a backtracking pass, and only
the third has a grammar.

**They were three selectors first, and that was wrong.** The rule this
codebase already follows is visible in `-Dbuffer-array`, `-Dstring-symbol` and
`-Dstruct-table`, each of which covers several C files under one selector: a
split is worth its seams when the pieces convert in *different* increments, and
costs them for nothing when they land together. `os.c` earns eight selectors
because it moved across eight increments; `gc.c` earns three because it moved in
three bites. `pp.c` moved in one, and three selectors bought three C bridge
functions, two `#define`s, a panicking abi on the JDN seam, eight build
combinations instead of two, and exactly one bug — a guard-placement mistake
that could not have existed under a single selector. The section below on seams
is what that cost; it is kept because the reasoning generalises to the next
part that is tempted to split.

### Where the shared statics went, and why folding removed the seams entirely

`pp.c` has eighteen static functions, and under three selectors the split was
only cheap if they landed on one side each. Three of them look like they cross,
and only one does.

`contains_bad_chars` sits in the escaping section, beside
`janet_escape_string_b`, and reads like part of the describe layer. Its only
caller is `print_jdn_one`. `integer_to_string_b` and its `count_dig10` helper
sit with the number formatting and are called only by `janet_pretty_one`, for
the digits of a `<cycle N>` marker. All three moved to `pp_pretty.zig`, where
their callers are, and cost nothing.

`janet_escape_string_impl` genuinely crosses: `janet_escape_string_b` and
`janet_escape_buffer_b` need it and so does `janet_pretty_one`, for the one
case where a buffer is printed into itself. It is the one new seam between the
first two subsystems, and it has to be a seam rather than a duplicate because
the pretty printer needs its *return value* — the column width of what it wrote
— which is exactly what `janet_description_b` does not report.

Between the pretty printer and the formatter the seams are `janet_pretty_` and
`janet_jdn_`, which are static in C only because both of their callers are in
the same file. They carry the start length and the lookback barrier that
`janet_pretty` and `janet_jdn` fix, which is the whole reason `%p` in the middle
of a format string behaves differently from `janet_pretty` on a fresh buffer.

Under three selectors that meant three C-ABI seams and a non-static bridge for
each in whichever arm kept the C body — and `-Dpp-pretty=c` with
`-Dpp-describe=zig` was the combination that caught the one placement mistake,
`contains_bad_chars` left inside the describe guard where a C pretty printer
could not see it.

**One selector deletes all of that.** The three layers are folded into one
object by `makePpObject`, on the `makeVmRunObject` pattern: `pp_format.zig`
imports `pp_pretty.zig`, which imports `pp_describe.zig`, sharing one `abi` and
one `raise` module. The calls between them are ordinary Zig, so there is no
seam to bridge, no guard to place on either side of one, and no arm of `pp.c`
that has to expose a static. Either the whole file is C or the whole file is
Zig.

One C name survives, and it is a test's rather than a caller's:
`janet_zig_pp_escape_string`. `test/pp_describe.c` asserts the column width the
escape returns, nothing else in the tree observes it, and a width consistently
wrong would show up only as slightly wrong wrapping in output no test compares.
Both arms export it; it is three lines in the C one.

### Zig 0.16 cannot name a `va_list` on `aarch64-linux`

This is the fact the increment is shaped around, and it was found by probing
before anything was designed rather than by a cross-compile failing at the end.

```zig
.aarch64, .aarch64_be => switch (builtin.os.tag) {
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos, .windows => *u8,
    else => switch (builtin.zig_backend) {
        else => VaListAarch64,
        .stage2_llvm => @compileError("disabled due to miscompilations"),
    },
},
```

`std.builtin.VaList` is that `@compileError` under the LLVM backend, which is
the backend this project uses, and `aarch64-linux-musl` is one of its three
cross-compile targets. `@cVaStart` returns the same type, so Zig can neither
*define* a variadic function nor *consume* a `va_list` there. macOS aarch64 is
unaffected, because Darwin spells `va_list` as `*u8`; `x86_64-linux-musl` and
`riscv32-linux-musl` are unaffected too. A probe that compiled and ran on the
development machine and cross-compiled to two of the three targets would have
looked like a complete answer.

So `janet_formatc`, `janet_formatb` and `janet_formatbv` keep C bodies, and the
engine reaches their arguments by **pulling** rather than by receiving:

```c
int32_t janet_zig_va_next_i32(va_list *ap) { return va_arg(*ap, int32_t); }
```

`janet_zig_formatbv` takes the `va_list` as an opaque pointer it never
dereferences and asks for the next argument of whatever type the specifier it
has just parsed calls for. The order is forced rather than chosen: only the
engine knows what comes next, because only the engine has parsed the format
string, and only C can execute the `va_arg`.

One detail in the shim is load-bearing and looks like defensiveness:

```c
void janet_formatbv(JanetBuffer *b, const char *format, va_list args) {
    va_list copy;
    va_copy(copy, args);
    janet_zig_formatbv(b, format, &copy);
    va_end(copy);
}
```

On the System V AMD64 ABI `va_list` is an array of one struct, so the parameter
`args` has already decayed to a pointer and `&args` is the address of *that
pointer* rather than of the cursor. `va_copy` into a local gives an object whose
address is the cursor's on every ABI, which is what the accessors dereference.
Passing `&args` would work on Darwin arm64 and corrupt every argument on
x86-64.

These forty lines are scaffold in the exact sense "Target" gives the word. A
*Zig* caller never needs them: `janet_buffer_format` takes a `Janet` array and
moved whole, and a converted caller wanting a formatted message will take a
tuple rather than a `...`. They go with the last C caller of `janet_panicf`, in
Part 17, exactly as `janet_zig_signal_deliver` does.

### An error union cannot cross a subsystem seam, and that decides two shapes

A selector exists so that either implementation can answer, which means every
seam between two selectable subsystems is the C ABI. A Zig error union is not a
C type, so it stops at the seam, and each of this increment's two internal
seams had to pick a side.

The rule the increment settled on is that **the seam does what the C original
did across the same boundary**. `print_jdn_one` already *reported* failure
upwards as a flag and `janet_jdn_` turned the flag into a panic, so the flag
stays a flag, the recursion carries no error union, and the message is written
once.

`janet_jdn_` itself *raised* across the boundary its callers sit on, and under
three selectors that forced `janet_zig_pp_jdn_impl` to be a panicking abi — an
error union cannot cross the C ABI, so `%j` refusing a value meant a `longjmp`
through the formatter's own frames. **Folding the three layers under one
selector is what removes that.** `pp_format.zig` now `try`s `pretty.jdnImpl`,
the error propagates as an error, and the only jump left in this subsystem is
the one a C caller asks for at the perimeter.

The files still carry the `//! jump-transparent` marker, because
`raise.panicf` renders its own message through `janet_formatc` — the abi of
this very engine — and an abstract `tostring` callback can still panic through
any of them. They hold nothing but stack arrays, so it costs nothing.

### Part 2 predicted this would retire `raise.zig`'s marker, and it does not

`raise.zig` says, in a comment written in Part 2, that it is jump-transparent
"for exactly one call: `janet_formatc` can panic through C. Part 4 takes `pp.c`
and that stops being true."

It does not stop being true, and the reason is worth keeping because it is a
mistake about *which* call is the problem. Rendering a coercion message with
`%v` reaches `janet_description_b`, which runs an abstract type's `tostring`
callback. That callback is a C function pointer supplied by `abstract.c` or by
a native module, and it raises by jumping whatever language the formatter is
written in. Moving the formatter moves the jump one frame down; it does not
remove it. The marker comes off when abstract callbacks stop jumping, which is
not this part's subject.

The same correction applies to `asm_core.zig`'s claim that its stranded tables
"close when the formatter and the containers convert". The formatter has
converted and they have not closed.

### Three defects reproduced rather than repaired

All three are in `FOUND.md` with reproductions, and all three are pinned by a
contract so that a later tidy shows up as a failure rather than as a silent
behavior change.

`%D` and `%I` have entries in the integer-widening table and are never reached
by it, because `scanformat` consults the table only for the characters in
`FMT_REPLACE_INTTYPES`, which are lower case. The specifier reaches `snprintf`
unrewritten while the argument beside it has been read as an `int64_t`, so what
prints depends on the host libc: macOS accepts `%D` as a BSD synonym and
renders `%I` as a literal `I`, and glibc and musl recognise neither.
`intMapping` in `pp_format.zig` therefore has six cases where the C table has
eight, with a comment saying so.

`janet_escape_buffer_b` pushes its `@` marker and *then* reads `bx->count`, so
a buffer described into itself escapes the marker as part of its own contents —
`(buffer/format b "%v" b)` on `@"a"` gives `a@"a@"`. The pretty printer does
not have the bug, because it escapes `bufstartlen` bytes recorded before
printing started.

And the negative-width branch of the pretty conversions cannot be taken: the
width field is filled only from digits, and a leading `-` is consumed as a flag
first. `PrettyOpts.decode` keeps the branch with a comment naming it as dead.

### One thing the port got wrong, and the contract caught it on its first run

`%d` and `%i` read an `int32_t` and their specifier has been rewritten to a
64-bit one, so the C widens explicitly before rendering:

```c
int64_t n = (int64_t) va_arg(args, int32_t);
nb = snprintf(item, MAX_ITEM, form, n);
```

The first Zig version passed the `i32` straight to `snprintf`, which then read
64 bits for a `%lld` and found half of the next slot. `-2000000000` printed as
`2294967296`. Nothing in the Janet suites saw it, because `string/format` goes
through the *other* loop, where the value arrives as an `int64_t` already; the
only conversions affected are the ones only C reaches. `test/pp_format.c` puts
seven argument widths in one `janet_formatc` call precisely so that a mis-read
shows up in the arguments after it as well as in its own, and that is the
assertion that failed.

### What the contracts had to be built around

Half of this file has no Janet caller at all, and that is the organising fact
for all three test files.

`janet_formatbv` and `janet_buffer_format` are two loops over two argument
sources and `string/format` reaches only the second. `%S` and `%T` exist only in
the first — there is no Janet syntax for a type *set*, and `%T`'s "a, b or c"
joining is in every argument-fault message Janet prints and was asserted by
nothing. `janet_pretty`'s null-buffer branch has no caller in the tree, and
neither does `janet_jdn`, which is declared in no header and reached from no C
file. The three parameters `janet_pretty` fixes — the width, the start length
and the lookback barrier — are never varied from Janet, and the last two exist
precisely so that printing into text that is already there differs from
printing into an empty buffer.

Two assertions are worth naming because they look arbitrary and are not.
`test/pp_format.c` formats `%.99f` of `1e155`, which needs exactly 256 bytes:
the item scratch is 256, `snprintf` wrote 255 and a terminator and reported
256, and a check spelled `>` rather than `>=` accepts that and pushes a stray
zero byte. Only that one length shows it. And `test/pp_pretty.c` asserts that
a *nested* value does not reflow at its outer level whatever the width, which
is not an oversight in the printer but a consequence of `leaf_align` being left
at the inner level — pinning it means a change to that test fails rather than
producing quietly nicer output.

Every panic each file expects is counted against a fixed total, on the rule
Part 2's contracts established: a case that silently stopped panicking would
otherwise look exactly like one that passed.

### What the mutation sweep found

Twenty-four mutants, twenty-three caught, and three of the catches were added
in response to the sweep rather than being there already.

The three holes were all in the formatter, and all three were places where a
mutant produced *plausible* output rather than obviously wrong output. The item
overflow boundary is the one described above. `%M` losing its no-truncation
flag was invisible because the contract exercised `%m` and `%n` but never the
upper-case spelling that carries colour *and* the flag. And `%j` falling
through to the pretty printer instead of the JDN writer was invisible because
the two agree on every value that has both forms and differ only on the values
that have one — so nothing short of asserting that `%j` *refuses* a function
could tell them apart.

The one survivor is worth recording as a survivor rather than as a hole.
Removing `S.keysort_start = ks_start` at the end of `prettyEntries` changes no
output at all: each nesting level takes the slice of the key-sort scratch above
the level below it and reads back through its own base, so a level that never
restores the cursor is still self-consistent and only makes the scratch grow.
The line is a memory economy, not a correctness invariant, and no test can see
it. It would take an input large enough to push `len + keysort_start` past
`INT32_MAX` before the difference became observable, at which point it appears
as spurious truncation.

### There is no separate Zig implementation to test yet, and that is worth saying

This phase's first acceptance check is that a converted symbol's abi and Zig
abi are tested separately, because the C one is the one that disappears and so
the one that rots. It does not bite here, and the reason is not that the check
was skipped.

Every symbol this increment exports is an abi: `janet_formatbv`,
`janet_buffer_format`, `janet_pretty`, `janet_jdn`, `janet_to_string_b` and
their kin are what C callers link against. The error-returning implementations
behind them — `formatbv`, `bufferFormat`, `jdnImpl` — are reached only from
inside the one object the three layers fold into. `jdnImpl` does now have a
Zig caller, `pp_format.zig`, which is what folding bought; it has no *second*
abi, because `janet_jdn` is the abi and there is nothing else to be
differential against. The three contract files drive the abis, which is the
whole of what exists.

The second abi appears when a Zig *caller* converts. `raise.panicf` is the
obvious first one: it builds its message through `janet_formatc` today, which is
this engine's abi reached through the C variadic ABI, and a converted
`janet_panicf` in Part 5 will want a tuple-driven entry beside it that returns
the error instead. That entry is deliberately not built here — nothing would
use it, and `PLAN.md`'s warning about accidental redesign applies to speculative
interfaces as much as to representation changes.

### The fuzz found the one thing the contracts could not

Four thousand random values through random specifiers, printed by both
implementations and diffed. Values were generated to a random depth over every
type the printer distinguishes, including buffers with high bytes and strings
with interior zeros; specifiers were assembled from a random flag set, a random
two-digit width and precision, and every conversion character.

Twenty-two of the twenty-three conversions agreed on every case. `%j`
disagreed, and the useful part is how it was diagnosed: **the same binary
disagreed with itself across two runs more often than the two implementations
disagreed with each other**. JDN walks a dictionary in storage order rather
than sorted order, and a key hashed by pointer — a buffer, an array, a table —
puts entries in slots that depend on an allocation address. `%q` on the same
value prints identically every time; `%j` does not.

That is pre-existing behavior rather than anything this port introduced, and it
is in `FOUND.md` because a serialisation format that is not byte-reproducible
is worth someone deciding about. With `%j` excluded the two implementations
agree on all four thousand cases.

### The suites have never run under `-Dreduced-os=true`, and still cannot

Widening this increment's matrix past what it inherited turned up a
configuration that has never been tested and is not made testable here.
`zig build test -Dreduced-os=true` fails before any suite starts:
`test/helper.janet` is shared by all thirty-four of them and names `os/getenv`,
`os/clock`, `os/exit`, `os/lstat`, `os/dir`, `os/rmdir` and `os/rm`, none of
which a reduced-OS build defines — and an unknown symbol is a compile error, so
the reference alone is fatal whether or not the branch runs.

It looked like a two-line fix and is not one. Resolving the names at run time
fixes `os/getenv`; the timing and the exit status need real substitutes, and
`rmrf` cannot be given one at all, because the suites that call it are testing
the filesystem that build removes. Deciding which suites even *apply* to a
reduced-OS build is a piece of work of its own and it is not this part's.

What is established is the part that matters for this increment: the library
builds under `-Dreduced-os=true` and all three `pp` contracts pass against it.
The matrix entry says so rather than claiming a suite run it did not do. This
is Phase 9's sixth rule collecting for the second phase running — a matrix that
grows by inheritance tests the increment that assembled it — and the cost of
not knowing was one configuration nobody had ever exercised.

### The matrix

Sixteen configurations. The default; all fifty-five selectors set to `c`
together; `-Dpp=c`; tagged values; single-threaded; no event loop; `-Dcall-trampoline=true`; `-Dboot=zig`,
so that the bootstrap image generator is itself built from the ported
formatter; all four optimize modes; and `x86_64-linux-musl`,
`aarch64-linux-musl`, `riscv32-linux-musl` and `x86_64-windows-gnu` as
cross-compiles.

`aarch64-linux-musl` is the one that matters most here and it is the reason the
variadic entry points stayed in C. It builds, which is the whole point: a Zig
`janet_formatc` would not have.

`-Dreduced-os=true` is the one entry that is not a suite run. The library builds
and the three `pp` contracts pass against it; the Janet suites cannot run there
for a reason that predates this increment and is recorded above.

The matrix shrank from twenty-one entries to sixteen when the three selectors
became one, and that is the honest accounting for the split: five of those
twenty-one existed only to test combinations of a scaffold against itself, and
the single bug they found was one the scaffold had created.

### What this cost

Ten `janet_panic` call sites left C, which is the phase's monotone measure:
375 compiled call sites before this increment and 365 after, counted by
preprocessing every `src/core/*.c` with all fifty-three `JANET_ZIG_*` guards
defined and attributing each surviving line back to its own file. `pp.c`
contributes none.

`src/core/pp.c` goes from 1,195 live lines to 112, counted the way the Phase 10
inventory table counts: non-blank source lines, comments included, with every
`JANET_ZIG_*` guard defined. Most of what is left is the licence header, the
includes, and the comments explaining why the rest is there; the code is three
variadic functions and six accessors. The three Zig files are roughly 1,100
lines together, including their comments.

## The public perimeter, and the end of `capi.c`

Phase 10 Part 5 takes the rest of `src/core/capi.c` — the panic family, the
whole argument-extraction layer, the dynamic bindings, the delayed thunk, the
atomic refcount primitives and the four out-of-line head accessors — plus the
three view constructors from `util.c` that the argument layer is built on.
`capi.c` goes from **378 live lines to 24**, and what is left is three
functions.

**No new selector.** Every piece went to the subsystem that already owns its
subject: the argument layer to `-Dargs-core`, whose guard now opens all the
way; the panic family to `-Dsignal-core`, which already held the decision half
of a raise; the dynamic bindings to `-Dvm-state`, the delayed thunk to
`-Dvalue-alloc`, the atomics to `-Dabstract-core` and the heads to
`-Dutilities`. The count stays at fifty-five, which is Part 4's rule applied
before the fact rather than after it: a split is worth its seams only when the
pieces convert in different increments, and a file is not a subject.

### The fault descriptor outlives the reason it was invented

Phase 7 split the argument layer in two because of a constraint that Phase 10
removes. A getter that built its own message would allocate, allocation can
panic, and through Phase 9 no Zig frame could be jumped through — so the
kernels reported a code plus a slot index and `janet_arg_raise` in `capi.c`
turned that into the message. A panic is now a returned error, and a frame that
holds nothing may be jumped through anyway. Neither half of the reason
survives.

The split does. `janet_checkabstract` answers NULL for a value of the wrong
type, and the three view constructors answer 0; all four are public API with
that signature, and none of them may raise. A kernel that raised would need a
non-raising twin for each of them, where a kernel that reports serves both and
keeps the wording in one place. What changed is that the boundary is now
internal to `args_core.zig` instead of being the C ABI.

Two of the three consequences the descriptor forced are unchanged and one has
gone. `janet_arg_bytes` still classifies the abstract case instead of taking
it, and `janet_arg_cbytes` still decides which of three shapes applies and
stops, because `janet_bytes_view` needs both classifications and may not raise.
`janet_arg_nextmethod` still returns the entry rather than the keyword, but
`janet_nextmethod` now wraps it four lines away rather than across a language
boundary.

### The two slot diagnostics went with the arguments, not with the panics

`janet_panic_type` and `janet_panic_abstract` are declared beside
`janet_panicv` in `janet.h` and read as part of the panic family. They are
under `-Dargs-core` instead, and the seam is what decides it: `raiseFault`
needs the *error* rather than the jump, and an error union cannot cross the C
ABI between two selectable subsystems — Part 4's rule, applied to a case where
following the family would have cost the whole increment its point. Their two
format strings are the only ones the argument layer shares with anything else,
and keeping them here keeps them in one place.

### `raise.deliver`, and why `raise.panicking` does not apply

`raise.panicking(f).abi` builds an abi by catching an error union and
delivering the jump. It does not fit anything at this perimeter.
`janet_panicv`, `janet_panic`, `janet_panics`, `janet_signalv`,
`janet_arg_raise` and the two slot diagnostics are all `JANET_NO_RETURN`, and
the Zig entry points they wrap return the bare error *set* rather than an error
union — there is no payload to come back with, so there is nothing to `catch`,
and Zig rejects `_ = <an error>` outright.

`raise.zig` gained a second delivery for it:

```zig
pub inline fn deliver(_: Error) noreturn {
    deliverToC();
}
```

which makes the abi read as what it is:

```zig
export fn janet_panicv(message: c.Janet) callconv(.c) noreturn {
    raise.deliver(raise.panicv(message));
}
```

The parameter is unused by construction — everything the jump needs was written
into `janet_vm` by the raise before it returned — and the point is that the
error is *passed* rather than discarded, so the abi cannot drift into calling
the jump without the raise.

### The getter surface, generated rather than macro-expanded

`capi.c` wrote the getter surface with five C macros: `DEFINE_GETTER` fourteen
times, `DEFINE_OPT` eleven, `DEFINE_OPTLEN` three, `DEFINE_ARG_GETTER` nine and
`DEFINE_ARG_OPT` six. The Zig side is the same shape with `comptime` in place of
the preprocessor, and one thing it buys that the macros could not: the payload
type is read off the unwrap function rather than written out fourteen times.

```zig
fn TypeGetter(comptime unwrap: anytype, comptime janet_type: anytype, comptime typeflags: anytype) type {
    return struct {
        pub const Value = @typeInfo(@TypeOf(unwrap)).@"fn".return_type.?;
        ...
```

That matters more than it looks. `-Dnanbox=false` changes what several of these
unwraps return, and a hand-written signature that disagreed with `janet.h`
would be a silent ABI change rather than a compile error. `Value` is also what
`Opt` and `OptLen` take their default parameter and their return type from, so
the eleven optional forms cannot disagree with the getters they fall through
to.

The fall-through is the increment's actual subject:

```zig
pub fn get(argv: [*c]const c.Janet, argc: i32, n: i32, dflt: G.Value) raise.Raising(G.Value) {
    if (janet_arg_isdefault(argv, argc, n) != 0) return dflt;
    return G.get(argv, n);
}
```

`janet_optnumber` used to be a C function that called a C function that jumped.
It is now a Zig function that returns an error the caller can see, with a
abi beside it for as long as C callers remain. That is what "the abi
and the Zig implementation are each other's differential" means here, and it is why the
existing contract is worth what it is: every `janet_opt*` case in
`test/args_core.c` drives the Zig implementation of the getter beneath it and the abi
of the optional itself, in one call.

### The port got one thing wrong, and the contract caught it on the first run

`raiseFault` read `fault.slot` at the top, before the switch. Four of the eleven
fault kinds — the two arity kinds, the flag kind and the embedded-zero kind —
name no slot at all, and their callers pass `argv` as null; `janet_arg_fixarity`
deliberately leaves `slot` alone. The C original reads the field only inside the
three branches that use it, and reproducing that as one eager read at the head
turned every arity mismatch into a read of an uninitialised field and, in a safe
build, a trap. `test/args_core.c` hit it on `janet_fixarity(1, 2)`, which is the
first assertion it makes.

The lesson is the same one Part 4's `%d` gave: the fault descriptor's
*unwritten* fields are part of its contract, and nothing about the type says so.

### What is left of `capi.c`

Three functions, and each stays for a reason already recorded:

  - `janet_zig_signal_deliver`, the `longjmp` itself. Part 17 deletes it along
    with the `setjmp` it targets.
  - `janet_top_level_signal`, which ends the process or the thread when there is
    no scope to raise into. It is the one place an embedder's
    `JANET_TOP_LEVEL_SIGNAL` macro is honoured, and a function-like config macro
    is not something a Zig implementation can call.
  - `janet_panicf`, which is C-variadic. Part 4 established that this is the one
    shape that cannot be ported at all: Zig 0.16 can neither define a variadic
    function nor, on `aarch64-linux`, name a `va_list`. It goes with its last
    caller in Part 17.

The rest of the file is the licence header, the includes, and the comments
saying where everything went.

### There is a Zig implementation now, and the existing contract already drives it

Part 4 recorded that its subsystem had no separate Zig implementation to test, because
nothing in Zig called it. That is no longer true one layer down, and the
coverage came free. `janet_optnumber` is a Zig function that calls the Zig
`GetNumber.get` and returns what it returns; `janet_getcstring` reaches
`getCBytes` and then `getBytes`; `janet_getflags` goes through
`GetKeyword.get`; `janet_getslice` goes through `startRange`, `endRange` and
`halfRange`. Each of those is an error crossing a Zig frame rather than a jump
leaving one, and `test/args_core.c` drives all of them — thirty-two `janet_opt*`
calls and thirty-one through the four composite getters — while asking only
about the abi it called.

Only one of the fifty-seven `EXPECT_PANIC` cases raises *through* a
`janet_opt*`, which is worth knowing rather than glossing: the error return is
covered densely and the error *propagation* through the defaulting layer is
covered once. The mutation sweep is what carries the rest of that weight — the
inverted-default and wrong-capacity mutants are both caught, and neither could
be by a case that never fails inside an optional.

What is not tested at all is a Zig caller of `janet_get*` outside this file,
because there is not one yet. Part 6 converts the container cfunction surfaces,
which is where those callers appear.

### The differential

1,037 cases: twenty-four probes reaching a different getter each, across
forty-three values chosen to land on different branches, plus five arity
shapes. Run under `-Dargs-core=zig` and `-Dargs-core=c` and diffed, the
messages are byte-identical once the addresses that `%v` prints for a mutable
container are masked. 843 of the cases raise.

The masking is the only interesting part. A message that embeds a buffer, an
array, a table, a function or a fiber renders it as `<array 0x...>`, so the two
runs disagree on every one of those lines for a reason that has nothing to do
with the implementation — the same shape of noise Part 4's `%j` finding turned
out to be, met here as an expected nuisance rather than as a discovery.

### What the mutation sweep found

Twenty-four slips: an off-by-one in a slot index, a swapped arity bound, an
inverted default, a dropped terminator, a head computed forwards. Twenty-two
could be evaluated and **all twenty-two are caught**, but one of them only after
a case was written for it.

The survivor is worth keeping. `janet_panics` takes a `JanetString`, which
carries its own length; a mutant that re-interned it with `janet_cstring` first
passed every contract and every suite, because every message raised anywhere in
the tree is NUL-free and `janet_cstring` of a NUL-free string is an equal
string. `test/signal_core.c` now raises a message with an embedded zero, which
is the only input that can tell the two apart.

The two that could not be evaluated are the other result. Both were the
"ignores a parameter" slip — `janet_optbuffer` dropping its capacity,
`janet_signalv` forcing an error — and Zig rejects both at compile time under
its unused-parameter rule. That class of mistake does not need a test here,
which is worth knowing before writing one.

### What this cost

`args_core.zig` goes from 553 lines to 1,179, and `capi.c` from 378 live lines
to 24; `util.c` goes from 630 to 594. The four subsystems that took the residue
grew by 32 to 38 lines each, comments included, and five contract files grew by
316 lines between them. The selector count does not move: fifty-five before and
fifty-five after.

Twenty-one matrix entries, all passing: the default, each of the six touched
selectors set to `c` on its own, every selector set to `c`, tagged values, a
single-threaded build, a build with no event loop, a reduced-OS build, the call
trampoline, three optimize modes, `-Dboot=zig`, and four cross-compiles.

The matrix itself changed shape at the end of this part, and the reasoning is in
`AGENTS.md`. Four entries still run the full `zig build test`, because a
misplaced `#endif` shows up as a suite failure rather than as a contract
failure and that is what those entries are for; the other thirteen build the
library and run this increment's six contracts against it, which is what the
reduced-OS entry always did. With two jobs in flight the twenty-one entries take
5m22s where they took 13m35s, and the concurrency is the smaller half of that:
two jobs is worth 1.32x on twelve cores and three is worth less than two,
because `zig build` already saturates the machine on its own.

## The cfunction surfaces, and the first Zig-registered core function

Phase 10 Part 6 takes the standard-library surface over the value and container
cores: `tuple.c`, `struct.c`, `table.c`, `array.c`, `buffer.c`, `string.c`,
`math.c` and `inttypes.c`. **1,944 live lines to 47**, a hundred and one
cfunctions and forty-five registration entries, and **no new selector** — each
surface went to the subsystem that already owned its data structure, so the
count is fifty-five before and after.

Phase 8 left these in C on a rule it stated plainly: *the standard-library
surface is not value construction*. That was a boundary of convenience over a
constraint of substance — every one of these functions raises, and through
Phase 9 no Zig frame could be jumped through. Jump transparency removed half of
that and Part 5's argument layer removed the other half. The surfaces move now
because the reason they stayed has gone, not because the rule was wrong.

### A cfunction cannot return an error, and that is not a limitation to fix

Everything Part 5 built is about raising by returning, and none of it applies
here. `JanetCFunction` is `Janet (*)(int32_t, Janet *)`: there is no error
channel in the signature, so a cfunction that fails has to deliver the jump its
caller is waiting for whichever language it is written in. Each of these files
already carried `//! jump-transparent`, and that marker is doing more work than
it was: a hundred and one frames may now be jumped out of, and not one of them
may hold anything.

That constraint shows up as a shape rather than as a rule. `array/concat`
cannot cache `array->data` across `janet_array_ensure` — not because of the
jump, but because the reallocation invalidates it — and the C original writes
the reserve-and-retake dance out at both call sites, so `appendIndexed` does
too. `string/replace-all` cannot use `defer` to release its KMP lookup table,
which is exactly why the C original leaks it when a substitution function
panics.

### `corefn.zig`, and what `JANET_CORE_FN` actually decides

The interesting part of this increment is not any of the hundred and one
bodies. It is that registering a core cfunction is a *declaration*, and the C
macro that spells it expands four ways.

`src/core/util.h` picks between `JANET_FN` and `JANET_FN_S` on
`JANET_BOOTSTRAP`, and `janet.h` then picks between four `JANET_FN*` forms on
`JANET_NO_DOCSTRINGS` and `JANET_NO_SOURCEMAPS`. What falls out is:

| build | docstring | source map |
| --- | --- | --- |
| bootstrap | unless `JANET_NO_DOCSTRINGS` | unless `JANET_NO_SOURCEMAPS` |
| runtime | never | always |

The runtime row is not a simplification of the other. `JANET_CORE_FN` resolves
to `JANET_FN_S` outside the bootstrap whatever the configuration says, so a
`-Ddocstrings=false` runtime drops nothing — the docstrings were never in it,
because the core environment is unmarshalled from an image the bootstrap built
with them in place — and a `-Dsourcemaps=false` runtime still records a source
map for every core cfunction. `corefn.zig` reproduces both rather than tidying
either, and the matrix gained an entry for each.

The consequence for the build is that **`JANET_BOOTSTRAP` now reaches the Zig
objects**, through a `boot_options` copy in `build.zig`. The comment there said
it never would:

> `JANET_BOOTSTRAP` reaches only the C registration layer … No Zig subsystem
> defines a global or registers a cfunction, so none of them needs the macro or
> changes shape under it.

Both halves of that were true when written and neither is now.

### Two things the preprocessor gives C for free

**`__LINE__`.** `@src()` is only valid inside a function, so a Zig declaration
cannot name its own line the way `JANET_FN_S` does. A per-function accessor
would work — a three-line struct with a `fn at() { return @src(); }` — and at a
hundred and one functions that is three hundred lines of noise for a line
number. The registration table is itself a function body, so `@src()` there
names the *row*, which is a real location one screen from the code and puts the
Janet name, the usage, the docstring and the implementation on one line:

```zig
corefn.reg("tuple/join", &cfunTupleJoin, @src(),
    "(tuple/join & parts)",
    "Create a tuple by joining together other tuples and arrays."),
```

The path is repo-relative where C's `__FILE__` is absolute, for a reason
recorded below.

**`JANET_CFUNCTION_ALIGN`.** Under 64-bit nanboxing with a nonzero pointer
shift, `janet_wrap_cfunction` reuses the low bits of the pointer and
`janet_check_pointer_align` asserts at registration that they are clear. The C
original attaches `__attribute__((aligned(1 << SHIFT)))` to every cfunction.
Zig has `align()` on functions, and each of these carries `align(16)` — the
maximum the shift may take, so that one constant satisfies every setting
`-Dnanbox-pointer-shift` accepts and the build does not have to thread the
configured number into each object. Over-aligning costs padding measured in
bytes. The default shift is 2 on aarch64 Linux and 0 elsewhere, so this was
never exercised before; `-Dnanbox-pointer-shift=3` is now a matrix entry.

### Two records of where a cfunction lives, and they can disagree

A ported cfunction's location is written down twice, by different code, at
different times, and a single build can report both. Phase 10 Part 13 found
this the confusing way round -- the same binding naming a `.c` file to `(doc
...)` and a `.zig` file in a stack trace:

| what reads it | where it comes from | what selects it |
| --- | --- | --- |
| a stack trace, `janet_description_b` | `janet_vm.registry`, filled by `janet_cfuns_ext` when `janet_lib_*` runs at startup | the subsystem's own selector, e.g. `-Dev-loop` |
| `(doc ...)`, a binding's `:source-map` | the core image, built by the bootstrap | `-Dboot` |

So on a default build -- `-Dboot=c` with every subsystem Zig -- `ev/sleep`
reports `src/zig/subsystems/ev_loop.zig` when it appears in a trace and
`src/core/ev.c` when asked through the environment. Neither is wrong: the
registry follows what was *compiled* and the image follows what *generated the
image*, and they part company for exactly as long as `-Dboot=c` is the default.

### The two images diverge, deliberately

The core image records each cfunction's source file and line, because the
bootstrap defines the bindings with `janet_def_sm`. So a binding that used to
say `src/core/tuple.c` now says `src/zig/subsystems/string_symbol.zig`, and
`-Dboot=c` and `-Dboot=zig` stop producing identical images:

```text
boot=c   324831 bytes
boot=zig 324801 bytes
src/core/tuple.c       c=1 zig=0
string_symbol.zig      c=0 zig=1
```

They differ in the eight paths this part moved and in nothing beside. Phase 9's
gate compared the two byte for byte and Phase 11 repeats the observation; that
property retires here, and it was always a statement about a transitional
arrangement rather than a requirement.

### The image is not reproducible, and that is this project's own defect

Looking at the image to answer the question above turned up something else.
It embeds twenty-two **absolute** source paths:

```text
/Users/pyrmont/Developer/Janet/janet/src/core/array.c
/Users/pyrmont/Developer/Janet/janet/src/core/asm.c
… twenty more
```

`__FILE__` is the path as the compiler was given it, and `build.zig` hands
`zig cc` absolute paths where upstream's Makefile hands it relative ones. So
the core image cannot be reproduced from another checkout or another machine,
which is a thing Phase 11 requires of it. This is not in `FOUND.md`, because
`FOUND.md` is for defects in the C implementation and this one is ours.

The fix is one flag — `-fmacro-prefix-map=<root>=.`, confirmed to rewrite
`__FILE__` under `zig cc` without touching debug info the way
`-ffile-prefix-map` would — and it is a separate change, because it moves the
image bytes for reasons that have nothing to do with this part. What this part
does contribute is that the paths Zig records are already repo-relative:
`@src().file` is relative to the module root, and `corefn.zig` checks that
assumption at compile time rather than trusting it.

### Generated where the C was macro-generated, and no further

`math.c` defines thirty-three one-argument operations with two macros and
`inttypes.c` defines thirty-odd methods with six. Those are `comptime`
functions here, for the reason Part 5's getter surface was: the table and the
implementations are written once, so they cannot drift. The math table names
the libm function directly —

```zig
.{ .janet_name = "log2", .fop = &c.log2, .doc = "Returns the log base 2 of x." },
```

— and calls it rather than reaching for Zig's `@log2`, because `-Dmath-core=c`
and the default have to agree bit for bit and the only way to guarantee that is
for both to reach the same implementation.

`inttypes.c`'s arithmetic keeps the detour the C original documents: signed
overflow is undefined in C and unsigned wraparound is not, so both operands are
cast to `uint64_t` and the result cast back. Zig has wrapping operators and
would not need it, but taking the same route produces the same bits by a path a
reader of both files can check.

Nothing else is generated. The twenty-five hand-written buffer and string
functions are written out, because a generator over bodies that differ is a
generator nobody can read.

### One translation fix the port forced

`janet.h` includes `<math.h>`, but inside `#ifdef JANET_NANBOX_64`. So the
shared `c` namespace gained and lost every libm declaration according to
`-Dnanbox`, which `math.zig` discovered by failing to find `acos` under the
tagged layout. `abi.zig` now includes it directly, as `math.c` always did.

### What the mutation sweep found, and why it took two runs

Twenty-five plausible slips: an inverted default, a swapped byte order, an
off-by-one in a fold, a method wired to the wrong library function.
**Twenty-four are caught and one survives**, and the first run of the same
twenty-five caught only sixteen.

The eight that got away the first time are the interesting output, because none
of them was a hole in the *port* — every one was a hole in the coverage the
port inherited:

  - `table/setproto` with an explicit nil, which clears the prototype. Nothing
    in the suites passed nil.
  - `string/split`'s `start` and `limit` arguments. Every existing case passed
    both defaults.
  - Twenty-two of the thirty-three unary `math/` operations, which no test
    named at all — so a `log2` wired to `log10` was invisible.
  - `math/frexp` and `math/ldexp`, likewise.
  - The `r`-prefixed `int/` methods for subtraction, division and remainder.
    The commuting operations were covered and the inverting ones were not.
  - `int/to-number`'s 2^53 range check.

Those are now sixty-odd assertions across `suite-table.janet`,
`suite-string.janet`, `suite-math.janet` and `suite-inttypes.janet`. The point
is not that the port needed them — it passed without them — but that the C
implementation had the same holes, and a sweep is the only thing here that
looks for a test that does not exist.

Two of the eight are not suite material.

**The runtime's source map** is written by `janet_registry_put` and read by a
stack trace, and by nothing else: a binding's `:source-map` comes from the
image, so a runtime that recorded nothing would still answer `(doc)` correctly
and only a traceback would go blank. `test/string_symbol.c` now looks the
registry entry up directly for eight core cfunctions across the four
subsystems and asserts that the file and line are there.

**The runtime carrying docstrings it should not** survives, and is left
surviving deliberately. `janet_core_cfuns_ext` ignores the `documentation`
field entirely, so the only consequence is a few kilobytes of strings in a
binary that never reads them. There is no behaviour to assert. It is recorded
here rather than papered over with a test that measures the wrong thing.

### One process mistake worth recording

Two mutation sweeps ran at once, on one source tree, because a wait loop
matched `SWEEP DONE` in the *previous* run's log and returned immediately —
so the "second" sweep's results were read before it had started, and it then
raced the first. The output was nonsense in a way that took a moment to see:
every mutant reported "caught by `suite-boot.janet`", one anchor had already
been mutated by the other run, and a mutant in `inttypes.zig` was reported
caught by `string_symbol.c`.

`AGENTS.md` already says never to edit the file a sweep is mutating while it
runs, and this is the same rule from the other side. It also left one mutation
stranded in the tree — `tuple/brackets` not setting its flag — which the
anchor check found immediately afterwards. The check exists because this is not
the first time.

### The matrix

Twenty-four entries, all passing. Five of the six touched selectors set to `c`
one at a time; every selector set to `c`; tagged values; a single-threaded
build; no event loop; reduced OS; the call trampoline; three optimize modes;
`-Dboot=zig`; four cross-compiles; and four that Part 6 made load-bearing:

  - **`-Dnanbox-pointer-shift=2`**, because a Zig-registered cfunction now has
    to carry the alignment `janet_check_pointer_align` demands.
  - **`-Ddocstrings=false`** and **`-Dsourcemaps=false`**, because `corefn.zig`
    reads both macros to decide what a table row holds.
  - **`-Dint-types=false`**, because `inttypes.zig` is now most of that
    configuration's absence rather than a little of it.

The pointer-shift entry failed on its first run, and `FOUND.md` has the reason:
shifts of 3 and 4 do not work, in the pure C build as much as the Zig one, at
the commit before this part as much as after it. The entry is pinned at 2, the
largest that works and the aarch64-Linux default.

### What this cost

The nine C files go from 1,944 live lines to 47. The five Zig subsystems gain
2,726 lines between them — `string_symbol.zig` 729, `buffer_array.zig` 775,
`inttypes.zig` 608, `math.zig` 381, `struct_table.zig` 250 — and `corefn.zig`
is 150 more, shared by all five. Four suites and one contract gained about
seventy assertions.

Fifty-five selectors before and fifty-five after, which is the number worth
watching: this part moved more C than any before it and invented no new way to
choose between implementations.

## The compiler front end, and the end of the seams

Phase 10 Part 7. Seven files — `compile.c`, `specials.c`, `emit.c`, `cfuns.c`,
`parse.c`, `debug.c` and `bytecode.c` — go from **1,664 live lines to nothing
at all**. Every one of them compiles zero lines when the selectors are `zig`.

That is a larger drop than the count suggests, because a third of those lines
were not code anybody ran. They are the increment's first result and worth
separating from the rest.

### Most of what was left was already dead

`specials.c` measured 364 live lines and `parse.c` 597, and the port was
supposed to be most of that work. It was not. Phase 7 had already moved
`destructure`, `handleattr`, `namelocal`, `varleaf`, `defleaf`,
`janetc_make_sourcemap`, `janetc_addfuncdef` and the parser's `root`, `atsign`,
`comment`, `is_whitespace` and `to_hex` into Zig — and left the C bodies
unguarded, because each was `static` and so provoked no duplicate-symbol error
to notice. They compiled into every build and nothing called them.

**A guard that removes code and a guard that chooses code look the same to a
line counter, and a `static` function with no callers looks like neither.**
`PLAN.md` records the first half of that lesson from the phase-opening
measurement, which counted both arms of every paired `#ifdef`. This is the
second half: the measurement counts what the compiler *compiles*, and that is
still not the same as what the program *runs*. Roughly 570 of this part's 1,664
lines were of that kind. They were removed by wrapping them in the guard their
neighbours already had, which is a smaller change than porting them and a
better one — nothing about the running program moves.

The way to find them was to guard a region and see whether the link still
succeeded. `dohead_destructure` was the one case needing more care, because it
is the only one with external linkage; its callers turned out to be two lines
of `specials.c` that the guard already removed.

### An error union cannot cross a seam, and Part 7 is where the seams end

Part 4 established the rule: **an error union cannot cross a subsystem seam,
because a selector's seam is the C ABI.** Its consequence, everywhere the
compiler front end was half-ported, was a small C function that turned a
returned status code back into a message.

`emit.c` was the clearest case. Five emit shapes were squeezed through one
`int`-returning entry point, selected by an enum invented for the purpose:

```c
enum { JANET_ZIG_EMIT_S, JANET_ZIG_EMIT_1S, JANET_ZIG_EMIT_SS,
       JANET_ZIG_EMIT_2S, JANET_ZIG_EMIT_SSS };

static int32_t janetc_emit_template(JanetCompiler *c, int kind, uint8_t op, ...) {
    int32_t label = 0;
    int status = janet_zig_emit_template(c, kind, op, s1, s2, s3, rest, wr, &label);
    if (status == 1) janetc_cerror(c, "too many constants");
    else if (status == 2) janetc_cerror(c, "ran out of internal registers");
    return label;
}
```

With the callers in Zig there is no seam, so there is no status code and no
kind enum. The ten `janetc_emit_*` entry points call the five kernels directly
and the error-to-message mapping is nine lines next to the code that raises it.
The same collapse removed `janetc_allocfar`, `janetc_copy` and
`janetc_farslot`'s C halves, `compile.c`'s nine-way `janet_c_compiler_*` shim
family, `parse.c`'s eleven push/pop/close forwarders, and
`specials.c`'s `janetc_special`.

**A numbered `kind` argument is what a seam looks like when it has outlived its
reason.** `janet_c_compiler_call_diagnostic` took an `int kind` from 0 to 8 and
switched on it to pick one of nine messages; every one of those nine call sites
is now the message it means. That is the shape to look for in the parts that
remain.

### The variadic rule has a scope, and this is where it shows

Part 4 established the other rule: **a variadic entry point is the one shape
that cannot be ported at all**, because Zig 0.16 cannot name a `va_list` on
`aarch64-linux` — `std.builtin.VaList` is `@compileError("disabled due to
miscompilations")` there. `janet_panicf` (Part 5) and `janet_dynprintf` (Part
11) are both parked on it.

`janetc_lintf` is a fourth instance of the shape and it is *not* parked,
because the rule binds where the variadic **signature is the contract**.
`janet_panicf` is public API and an embedder's existing call has to keep
compiling. `janetc_lintf` is declared in `compile.h`, is called only from the
compiler front end, and after this increment every one of those callers is Zig.
So it does not have to stay variadic — it has to stop being called from C, and
then the argument list can be an ordinary Zig tuple:

```zig
fn lintf(compiler: *c.JanetCompiler, level: LintLevel,
         comptime format: [:0]const u8, args: anytype) void {
    if (compiler.lints == null) return;
    record(compiler, level, @call(.auto, c.janet_formatc,
                                  .{@as([*c]const u8, format)} ++ args));
}
```

`compile.h` now declares a non-variadic `janetc_lint` for the one caller in
another subsystem object, and `janetc_lintf` is `static`.

**Zig cannot define a C variadic, but calling one is ordinary.** That is the
distinction the rule was always making and it had not needed stating before.
`janet_formatc` still renders `%q`, `%v` and `%.4q`, so the messages are
unchanged; the argument *count* is now checked by the compiler instead of by
the format string.

The `lints == null` test stays in front of the formatting rather than inside
`record`, for the reason it was in front of it in C: `janet_formatc` allocates,
an allocation can collect, and a build that asked for no lints should pay for
none of it.

### `stderr` cannot be named from Zig, and three platforms disagree three ways

`janet_stacktrace_ext` prints through `janet_eprintf`, a macro over the
variadic `janet_dynprintf`, whose second argument is the `FILE *` to fall back
to when `(dyn :err)` is unbound. Calling the variadic is fine. Producing the
argument is not.

Translate-c renders `stderr` differently on each of this project's platforms,
and they are not variations on a theme:

| target | `c.stderr` is | usable? |
| --- | --- | --- |
| macOS | `pub inline fn stderr() ...` | yes, called |
| musl / glibc | a variable of **opaque** `FILE` | only as `?*FILE`, never `[*c]FILE` |
| mingw | `pub const stderr = __acrt_iob_func(2)` | **no** |

The third is not a shape a caller can adapt to. It is a container-level
constant whose initializer calls an extern function, so merely referencing
`c.stderr` fails with `comptime call of extern function` before the value is
used for anything.

So `io.c` keeps a one-line accessor beside the variadic it belongs to:

```c
FILE *janet_zig_stderr(void) { return stderr; }
```

That is scaffold in the same sense as `pp.c`'s six `va_arg` accessors — no C
caller uses it — and it goes with `janet_dynprintf` in Part 17.

**The acceptance matrix is what found this, and it is what the cross-compile
entries are for.** All twenty-four native entries passed against a version that
handled only the macOS and glibc shapes. All four cross-compiles failed.

### The fiber chain, and a `defer` that was never running

`janet_stacktrace_ext` collected the fiber chain into a `janet_v_` vector and
walked it backwards, because it prints innermost-first and the chain is linked
outermost-first. Recursing to the deepest child and printing on the way out
gives the same order with no allocation:

```zig
fn traceChain(fiber: *c.JanetFiber, state: *TraceState) void {
    if (fiber.child != null) traceChain(fiber.child, state);
    // ... print this fiber's frames
}
```

That matters beyond tidiness. `eprintf` renders values through an abstract
type's `tostring`, which can still panic through C, and a panic jumped straight
past the C original's `janet_v_free`. The recursion has nothing to free. Its
depth is bounded by the fiber nesting depth, which is already bounded by the C
stack that `janet_continue` consumes per level.

`compiler_primitives.zig` gained the `//! jump-transparent` marker this part,
and `build.zig` immediately rejected a `defer` that had been sitting in
`janetc_toslotskv` since Phase 7. **The marker did not create the problem; it
made an existing one visible.** `janetc_value` reaches a lint, an error message
and `%v` even before this part, so a jump could always skip that `defer`.
Nothing leaked either way — the block is `janet_smalloc` scratch, which the
next collection reclaims, which is why it is allocated that way — but the
function has one exit and now says so.

### Where the leftovers went, and no new selector

Three pieces belonged to no subsystem that obviously claimed them:

- **`janet_instructions`**, `bytecode.c`'s last definition, went to `-Dverify`.
  Both assembler directions and the disassembler read it too, but `-Dverify` is
  the one selector whose C original is `bytecode.c`; the others are `asm.c`'s.
  Putting it there empties a file rather than splitting one.
- **The breakpoint family** — `janet_debug_break`, `janet_debug_unbreak`,
  `janet_debug_find` — and the whole `debug/` cfunction surface went to
  `-Ddebug-frames`, the only `debug.c` selector left.
- **The stack-trace printer** went to `-Dtrace-frames` rather than to
  `-Ddebug-frames`, because its whole job is to render a `JanetTraceFrame` and
  that descriptor is `-Dtrace-frames`'s subject. The two were written together
  and the descriptor is the interface between them.

Fifty-five selectors before, fifty-five after. That is now three parts running.

The instruction table is the one place the port is deliberately *not* a
transcription. The C original is seventy-seven bare initialisers with the
opcode named in a trailing comment, so an opcode inserted into the middle of
`JanetOpCode` shifts every row after it and nothing but a comment says
otherwise. The Zig table names the opcode in each row and a comptime loop
places it, refusing to compile if any opcode is missed or written twice. It
costs nothing at run time — the array is built at comptime and lands in
read-only data — and a differential dump of all seventy-seven entries against
`-Dverify=c` is identical.

### The parser's raise perimeter

`janet_parser_consume` and `janet_parser_eof` were C functions that checked and
panicked before calling the Zig engine, because a Zig frame could not raise.
Phase 10's first decision retires that, and the pair are now the panicking abi
of two Zig entry points:

```zig
fn checkDead(parser: *c.JanetParser) raise.Raising(void) {
    if (parser.flag != 0) return raise.panic("parser is dead, cannot consume");
    if (parser.@"error" != null) return raise.panic("parser has unchecked error, cannot consume");
}
```

`parser_core.zig` also gained the parser's abstract type, its twelve methods and
its thirteen cfunctions, which is what removes the last of `parse.c`.

### Twelve subsystems joined the single translation

The enabling step for all of this was not a port. `corefn.zig` and `raise.zig`
are built on `abi.zig`'s translation, and a subsystem that registers a
cfunction or raises has to share it. The compiler front end did not: twelve
subsystems predating `abi.zig` each had their own `@cImport`.

Adding `emit.h` and `vector.h` to `abi.zig` — which transitively brings
`compile.h` and `regalloc.h` — and pointing all twelve at it was a mechanical
change that built and passed on the first try. It was also *required* rather
than tidy: with `abi.zig` translating `compile.h`, a subsystem keeping its own
`@cImport` over the same header is exactly the duplicate translation the
single-translation rule exists to prevent.

Three one-line C shims died as a side effect. `janet_c_funopt_wrap_nil`,
`janet_c_compiler_wrap_nil` and `janet_c_specials_wrap_keyword` existed only
because those subsystems translated `compile.h` and `emit.h` and so had no
`janet_wrap_*` of their own. `cfuns.c` was nothing but those three and is now
empty.

### What the mutation sweep found

Sixty-six mutants across four passes. **Fifty-eight caught, five survived, and
three had to be rewritten before they would compile at all.**

The first pass caught only thirty-three of sixty-three, which is a much worse
first showing than any previous part and says something true about the tree
rather than about the port. These subsystems were ported in Phase 7 with
contracts aimed at the kernels, and the cfunction surfaces on top of them are
new here; the twenty-seven survivors were almost all inherited holes. Closing
them took about a hundred and thirty assertions across three suites and three
contracts:

  - **The four emit failures** — "too many constants", "ran out of internal
    registers", "jump is too far", "cannot write to constant" — had no test at
    all, which is unsurprising: none is reachable from Janet source without a
    program too large for a suite. `test/emit_core.c` now reaches all four,
    which for the constant-pool one means filling the pool to 0xFFFF by growing
    the vector once and setting its count, because filling it honestly is
    quadratic.
  - **A lint's position** was checked for being *numbers*, not for being the
    right numbers in the right order. Asserting them needs a form whose
    position is known independently of where in the suite the test sits, which
    is what building it through a parser with `parser/where` gives.
  - **The parser's second guard.** A delimiter error sets the dead flag, so
    "parser is dead, cannot consume" is what every obvious probe produces and
    "parser has unchecked error" is unreachable that way. It needs an error
    that `delim_error` did not raise — `(parser/consume p "\x01")` — and it
    needs the error left *unread*, because `parser/error` clears it.
  - **`debug/break` by source position** was tested only for failing. Its two
    bounds — the source name and the column — are each an `if` that no test
    distinguished.
  - **`%s/%s` for a prefixed cfunction** is unreachable from Janet entirely:
    every core registration passes a null prefix, and only a native module
    calling `janet_cfuns_prefix` gets one. `test/trace_frames.c` already plants
    such an entry by hand, so the test that was missing was of the *rendering*,
    with `:err` bound to a buffer — which is also how the whole printer became
    readable rather than being sent to the harness's stderr.

One survivor turned into a correction rather than a test. "The method table is
not searched in order" survived a mutation that swapped two rows, and the
reason is that `janet_getmethod` scans **linearly** — the comment this part
wrote claiming a binary search was simply wrong. The order does matter, but for
`janet_nextmethod`, which is what `(keys p)` and `next` walk. The comment says
that now and the suite asserts the iteration order.

**Three mutants would not compile**, all of the "ignores an input" kind that
Zig's unused-variable rule rejects outright — the same class Part 5 recorded.
Rewritten as inverted tests rather than deleted ones, two were caught
immediately and one survived.

**Five deliberate survivors**, each recorded rather than papered over:

  - *The lint entry interns its message before testing whether anyone is
    listening.* Same result; only a wasted allocation differs, and Janet
    exposes no way to see it.
  - *`error_mapping.line == 0` is reported rather than omitted.* Unreachable:
    the mapping is -1 when there is none and at least 1 when there is, because
    `parser/where` rejects line 0.
  - *A generated parser message is re-interned.* Both paths produce a string of
    the same content, and Janet strings compare by content and have no exposed
    identity.
  - *`debug/arg-stack` takes its count before the copy.* The argument stack is
    empty in every state a Janet program can reach — the compiler evaluates
    arguments into slots and pushes them together — so `capacity` is zero
    either way. Reaching it needs an embedder pushing arguments and signalling
    between pushes.
  - *The GC lock around the `:missing-symbol` handler is released early.* It
    survives three thousand allocations at `(gcsetinterval 1)`, because
    `janet_continue` makes the fiber the VM's current fiber and therefore a
    root. The lock is defensive in the C original too; it is reproduced because
    it is what the C does, not because it was shown to matter.

### The matrix

Twenty-eight entries, all passing. Eight of the touched selectors set to `c`
one at a time, plus one entry with the whole front end on the C side at once —
the combination that would expose a seam only half-collapsed. Then every selector `c`; tagged
values; single-threaded; no event loop; reduced OS; the call trampoline; three
optimize modes; `-Dboot=zig`; the pointer shift; both documentation macros; and
four cross-compiles.

**The cross-compiles are what earned their place this time.** All twenty-four
native entries passed against the first version of the stack-trace printer.
All four cross-compiles failed, on the one line that named `stderr`.

### What this cost

Seven C files go from 1,664 live lines to zero. About 570 of those were already
dead and were removed by guarding rather than porting. The Zig subsystems gain
1,644 lines between them — `parser_core.zig` 547, `compiler_primitives.zig`
361, `debug_frames.zig` 258, `emit_core.zig` 165, `trace_frames.zig` 138,
`verify.zig` 136, `specials_core.zig` 24 and `builtin_optimizers.zig` 15 — and
`io.c` gains one line it will lose again in Part 17. The tests gain about five
hundred: `test/suite-parse.janet` 215, `test/suite-debug.janet` 147,
`test/verify.c` 92 and `test/trace_frames.c` 62, plus `test/suite-compile.janet`
and `test/emit_core.c`.

Twelve subsystems moved onto `abi.zig`'s translation, which is the change that
made the rest possible and which touched no behaviour at all.

Fifty-five selectors before and fifty-five after, for the third part running.

## The marshalling protocol

Phase 10 Part 8. `src/core/marsh.c` goes from 1,583 live lines to zero:
`marsh.zig` holds both directions, the twenty-function context API, the two
environment-lookup entry points and the three cfunctions. **Sixty `janet_panic`
call sites left C — 290 before this increment and 230 after** — which is the
largest single drop of the phase so far and reflects what the file is: a reader
of untrusted bytes, where nearly every branch is a refusal.

**One new selector, `-Dmarsh`, and the count goes from fifty-five to
fifty-six.** The three previous parts each added none, and the difference is
not a change of rule but a change of subject: Parts 5, 6 and 7 moved code into
subsystems that already existed, and this one moves a subsystem that had no
Zig at all. Part 4's consolidation rule decides the rest without argument —
both directions convert in the same increment, so splitting the reader from the
writer would buy three C bridge functions and eight build combinations and
nothing else.

### The two directions share a vocabulary and nothing else

The file reads as though the reader mirrors the writer, and it does not. They
share the lead bytes, the two varint codecs (`pushInt`/`readInt` and
`push64`/`read64`), and the shape of the reference tables. They share no state
type, no traversal, and no error discipline. The writer walks live objects and
appends to a buffer that can always grow; the reader walks bytes it must not
trust and allocates structures the collector will walk before they are
finished. That asymmetry is why the reader is two thirds of the file and why
almost all of the panics are on its side.

The three reference tables are shaped by the same asymmetry. Marshalling needs
`seen`, a `JanetTable` keyed by *value*, because writing a back reference means
asking "have I already written this object"; unmarshalling needs no table at
all, because a reference arrives as an index. `seen_envs` and `seen_defs` are
flat vectors scanned linearly in both directions, because a `JanetFuncEnv` and
a `JanetFuncDef` are not Janet values and cannot be table keys.

### The lead bytes renumber without the event loop

The most surprising thing in the file, and it is upstream's rather than the
port's. `marsh.c`'s lead-byte vocabulary is one anonymous enum, two of whose
members are inside `#ifdef JANET_EV` and seven of whose members follow them
without being. So `LB_TABLE_WEAKK` is 226 in an event-loop build and 224 in a
reduced one, and the whole weak group moves with it.

```zig
const lb_threaded_abstract: u8 = 224;
const lb_pointer_buffer: u8 = 225;
const weak_base: u8 = if (has_ev) 226 else 224;
```

A stream is therefore not portable between the two configurations in either
direction, and the core image is a marshalled stream. `FOUND.md` has the
demonstration and the reason it is reproduced rather than repaired: pinning the
numbers would make this implementation disagree with the C one under
`-Dev=false`, which is the only configuration where the difference shows.

It also decides a shape. The two conditional lead bytes cannot be switch prongs
here, because without `JANET_EV` their values collide with the weak group's;
they are tested before the switch, inside `if (has_ev)`, which Zig does not
analyse when the condition is comptime false. That is the same mechanism
`abstract_core.zig` uses for the threaded-abstract family and for the same
reason.

### Nothing is freed on the way out, and that is deliberate

`janet_marshal` and `janet_unmarshal` each end by freeing their `janet_v_`
vectors and, on the writing side, deinitialising the `seen` table. Neither
cleanup runs when the traversal raises. That is the C original's arrangement
and the port keeps it: the vectors are scratch memory, which the collector
releases at the next `janet_try` unwind rather than on the spot, so the leak is
bounded by the protected scope rather than by the process.

It is worth stating because Phase 10 makes the alternative *look* available.
The traversal now returns errors, so `janet_marshal`'s abi could free before
it delivers the jump. It would be freeing on some paths and not others:
`janet_buffer_push_u8` raises by jumping, from inside every `push*` in the
file, and no `errdefer` in a jump-transparent file can catch that. Half a
cleanup is worse than none, because it makes the arrangement look intentional
in a way that would not survive the next raise added to a `push` helper.

### The file is jump-transparent, and will be after the others are not

Three kinds of call inside the traversal jump past these frames whatever this
file does: the buffer pushes, the allocators on the reading side, and an
abstract type's `marshal` and `unmarshal` callbacks. The third is the one that
outlasts the others. It is a C function pointer supplied by `io.c`, `ev.c`,
`peg.c` or a native module, and it is the same call that keeps `raise.zig`'s
own marker on. So the marker comes off here when abstract callbacks stop
jumping — Part 4 predicted that for the formatter and was wrong for the same
reason — and not when the last of `io.c`, `ev.c` and `peg.c` converts.

### The context API is a C perimeter and stays one

`janet_marshal_janet`, `janet_unmarshal_int` and the eighteen others are called
*from* those callbacks, in the middle of this file's own recursion.
`JanetMarshalContext` is public API, the callbacks are C, and no signature in
the family has an error channel. Each is therefore a `raise.panicking` abi
over an error-returning body, and the jump it delivers unwinds the Zig
traversal frames underneath it exactly as it did when they were C frames.

Eight of the twenty need no abi at all, because nothing in them decides to
raise: the four `janet_marshal_*` writers whose only failure is the buffer's,
`janet_marshal_abstract`, and the two flag accessors. `janet_env_lookup_into`
and `janet_env_lookup` are the same case one level up.

### Two portability faults the matrix found and the host could not

**`size_t` is not sixty-four bits everywhere.** `janet_marshal_size` is
`janet_marshal_int64(ctx, (int64_t) value)` in C, and the cast is a widening
one on a 32-bit target and a reinterpretation on a 64-bit one. Zig's `@bitCast`
refuses a width change, so the two steps have to be spelled separately —
`@bitCast(@as(u64, value))` out and `@truncate(@as(u64, @bitCast(...)))` back.
The riscv32 cross-compile is the entry that says so; every native entry passed.

**`janet_wrap_integer` again.** `janet.h` declares the function beside its
macro and `wrap.c` defines it only for the two nanbox layouts, so a Zig caller
under `-Dnanbox=false` does not link. `pp_pretty.zig` and `value_access.zig`
already write it out and `FOUND.md` already has the defect; this is the third
subsystem to meet it, and the `tagged values` matrix entry is what catches it
every time.

### What the contract had to be built around

`test/marsh.c` exists because `marshal` and `unmarshal` use a strict subset of
the subsystem. Four things are unreachable from Janet entirely:

  - **`JANET_MARSHAL_UNSAFE` has no Janet spelling.** `cfun_marshal` never sets
    it and `cfun_unmarshal` passes a hard zero, so raw pointers, cfunctions,
    pointer-backed buffers and threaded abstracts — five of the twenty-nine
    lead bytes — have no test without a C caller.
  - **The context API has no Janet caller.** It is reached only from an
    abstract type's callbacks, and the core types that have them exercise four
    of the twenty entry points between them. The contract defines a probe type
    whose `marshal` and `unmarshal` drive all twenty, and five more types that
    each break the protocol in one way.
  - **`janet_env_lookup_into`'s `prefix` and `recurse` are both fixed** by
    `janet_env_lookup`, which is what `env-lookup` calls.
  - **`janet_unmarshal`'s `next` out-parameter is dropped** by
    `cfun_unmarshal`, so nothing in Janet can see where a value ended — which
    is the whole point of concatenating two of them.

The wire format is the other reason, and it changes how the assertions are
written. A marshalled stream is a file format: its bytes are the contract
rather than an implementation detail, so `test_the_three_integer_encodings`
asserts literal bytes at both boundaries of all three encodings rather than
asserting that an integer survives a round trip. The same goes for the weak
lead bytes, which the contract computes from `#ifdef JANET_EV` and checks in
whichever configuration it was built for.

Two assertions had to be built rather than written. The funcenv and funcdef
reference tables have no Janet-visible effect — sharing is preserved rather
than observed — so reaching them at all means constructing a value that shares:
two closures over one variable for the first, two instances of one `fn` for the
second. The contract then asserts that the stream contains **exactly one**
occurrence of the reference lead byte before patching its index, so that a
change in the compiler makes the test fail rather than quietly stop testing.

One assertion is deliberately asserting undefined behaviour. `%x` reads a
64-bit argument and both of `marsh.c`'s call sites pass an `int`; the C arm of
the contract asserts the message that a platform with a zero upper half
produces, which is what should fail on a platform without one. `FOUND.md` has
the entry.

### What the mutation sweep found

**Ninety-one mutants, ninety-one caught, none survived.** Two would not compile
at first — both of the "ignores an input" kind that Zig's unused-parameter rule
rejects outright, the same class Parts 5 and 7 recorded — and both were
restated as inverted tests and caught.

That is the best first showing of the phase, and the reason is worth being
suspicious of rather than pleased about. **The core image is itself an
unmarshalled stream**, so a mutation on the reading side stops the interpreter
starting at all, and a sweep that only asks "did the suite pass" records a
catch that no test performed. The sweep therefore labels its catcher: the
interpreter's own startup first, then the contract, then the suite. Of the
ninety-one:

  - **six were caught by startup alone** — three in `readInt`, and three where
    the reference table or the registry lookup is wrong in a way the image
    exercises within its first few hundred bytes;
  - **forty-four by `test/marsh.c`**, which is the number that says the
    contract earned its place: every one of the unsafe-mode mutants, every
    integer-encoding boundary, and all four environment-lookup mutants;
  - **forty-one by `test/suite-marsh.janet`**, which is the number that says
    the suite was already good — the fiber, funcdef and closure mutants are
    almost all its.

No mutant needed a new test written for it, which has not happened before in
this phase and reflects that `suite-marsh.janet` is an unusually thorough
upstream suite rather than anything this increment did.

### The differential corpus

Thirty seeds through `marshfuzz.janet`, twelve thousand cases each, comparing
`-Dmarsh=c` against the Zig default byte for byte: **360,000 cases, no
disagreement.** Three shapes per seed — two thousand random values marshalled
and re-marshalled after a round trip, four thousand random byte strings fed to
`unmarshal`, and four thousand valid streams with one to three bytes flipped,
which is the shape that reaches the reader's interior rather than bouncing off
its first lead byte.

Two lessons about what such a corpus may compare, and both are Part 4's `%j`
lesson arriving again. **A dictionary is walked in storage order**, so a key
hashed by pointer makes the marshalled bytes depend on an allocation address:
the generator restricts dictionary keys to content-hashed scalars, and without
that restriction the same binary disagreed with itself on about fifty lines in
twelve thousand. And the mutation half compares **the reader's decision** —
which error fired, or what type came out — rather than the value, because
rendering an arbitrary unmarshalled table has the same exposure. An earlier
version compared values and produced exactly one differing line out of twelve
thousand, which was a table's printed order and not a divergence at all.

### Three defects reproduced rather than repaired

All three are in `FOUND.md` and all three are pinned.

  - **The weak lead bytes renumber with `JANET_EV`**, described above. Pinned
    by `test/marsh.c` in both configurations and by two matrix entries.
  - **`janet_unmarshal_abstract_threaded` is compiled out of every build there
    is.** `JANET_THREADS` is defined nowhere in the tree — six occurrences,
    all of them `#ifdef`s — so the only arm that has ever been compiled raises.
    Its one caller is `ev.c`'s channel unmarshaller, which means a threaded
    channel can be marshalled and can never be read back:
    `(unmarshal (marshal (ev/thread-chan 4)))` fails and
    `(unmarshal (marshal (ev/chan 4)))` does not. Pinned in the contract and,
    since it is reachable from Janet, in `suite-marsh.janet` as well.
  - **`%x` is handed a 32-bit argument by a conversion that reads 64.** The
    only one of the three the port cannot reproduce, because it cannot
    reproduce undefined behaviour; it passes the width the engine reads.

One more thing was dropped rather than reproduced, and it is not a defect.
`marsh.c` carries about forty lines behind `#ifdef JANET_MARSHAL_DEBUG` — a
double-`MARK_SEEN` check and a reference-table dump. No build in this tree
defines that macro, so the code has never been compiled by anything, and Zig
does not analyse the body of a comptime-false branch, which means transcribing
it would produce something even less checked than what it replaced. It is
recorded here rather than carried.

`UnmarshalState`'s first field went the same way. It is a `jmp_buf err` that
nothing writes to and nothing jumps through — a fourth `setjmp` site that never
existed — and it is dropped rather than transcribed. That leaves the phase's
count of live jumps where it was: `asm.c`'s died in Part 3, and `ev.c`'s and
`vm.c`'s are still ahead.

### The matrix

Twenty-eight entries, all passing. Five shapes: the four full entries this
phase always runs, plus `-Dmarsh=c` as a fifth full one — a marshalled stream
is what the core image is, so a regression here shows up in every suite rather
than only in this increment's contract. Then the seven selectors whose data
structures the protocol walks, one at a time; the tagged layout; the two
documentation macros; the four feature reductions; the pointer shift; three
optimize modes; `-Dboot=zig`; and four cross-compiles.

**`-Dev=false` is a full entry here and is run twice**, once per selector,
because it is the configuration in which the two implementations have to
renumber *together*. That pair is the only place in the matrix where a passing
entry is asserting agreement about a defect.

The two entries that failed first were both invisible on the development host:
the tagged layout, on `janet_wrap_integer`, and riscv32, on a 32-bit `size_t`.
That is the second part running in which a cross-compile caught something no
native entry could.

### What this cost

`marsh.c` goes from 1,583 live lines to zero — it compiles nothing but its
licence header — and `marsh.zig` is 1,960 lines, of which about 250 are
comment. No C body survives the guard: unlike Parts 4 and 7 there is no
variadic entry point and nothing that cannot be named from Zig, so `marsh.c`
gains three lines of `#ifndef` and loses everything inside them.
`test/marsh.c` is 886 lines and `test/suite-marsh.janet` gains three
assertions.

Measured at `ReleaseFast` on a nested structure of tables, tuples and strings,
887 marshalled bytes, interleaving the two selectors and taking medians of
seven: **marshalling is 1.19x the C, unmarshalling 1.05x.** The reading side is
within noise of the original and the writing side is not, which is the shape
Part 1's measurement predicts — the writer makes far more small raise-capable
calls per byte than the reader does, and `marshalOne` is recursive and
therefore never inlined. It is well inside what this project trades for
legibility, and it is the first increment where the raise mechanism's cost is
visible at all outside a probe.

## Parsing expression grammars

Phase 10 Part 9. `src/core/peg.c` goes from 1,924 live lines to zero: `peg.zig`
holds the matcher, the compiler that feeds it, the bytecode verifier that
guards the unmarshalled form, and the six cfunctions over all three.
**Thirty-one `janet_panic` call sites left C — 230 before this increment and
199 after.** Thirty of those thirty-one are one macro, `down1`, expanded at
every recursive rule; the file has six panic *sites* in its source and
thirty-five after the preprocessor.

**One new selector, and the count goes from fifty-six to fifty-seven.** Its
name is the only one in the index that does not match its subject, and the
reason is in "The selector could not be called `-Dpeg`" above: the plain name
is a feature flag. Part 4's consolidation rule decides the rest — the compiler
emits the bytecode the matcher runs and the verifier accepts, so the three
share a private instruction encoding that appears in no header and has no other
consumer, and a split would put a C bridge in the middle of one instruction
set.

### The bytecode is a file format, and that is what the contract is for

`test/suite-peg.janet` has 366 assertions and every one is about what a pattern
*matches*. That is a good test of the engine as a whole and no test at all of
the thing this increment had to preserve: a compiled peg is an abstract value
with `marshal` and `unmarshal` callbacks, so its instruction words are stored,
shipped and read back. A change made consistently in the compiler and the
matcher is invisible from Janet and invalidates every stored peg.

So `test/peg.c` asserts literal instruction words, one line per special:

```c
    CHECK_BYTECODE("'(some 1)", RULE_BETWEEN, 1, UINT32_MAX, 4, RULE_NCHAR, 1);
    CHECK_BYTECODE("'(int 4)", RULE_READINT, 0x14u, 0);
```

This is the same argument Part 8 made for writing `test/marsh.c` against literal
bytes rather than round trips, arrived at from the other end: there the wire
format was the subject, here it is a consequence of the subject being an
abstract type. Two other things the contract can see and Janet cannot: the
single allocation `make_peg` packs the header, the bytecode and the constants
into — which `peg_unmarshal` must reproduce exactly, because it writes through
pointers the compiler never sees — and the shape of `janet_peg_type`, which is
public API, so which callbacks are null is a contract an embedder relies on.

### Crafted bytecode is most of what the verifier exists for

`peg_unmarshal` is the untrusted entry point, and nearly everything it must
reject cannot be produced by the compiler at all: an opcode outside the
vocabulary, a rule operand pointing past the end, a constant index past the
constants, an operand pointing into the middle of another instruction. The
contract builds those streams by hand, which is eleven bytes of marshal framing
and then one byte per word:

```c
#define PEG_HEADER 217, 207, 8, 'c', 'o', 'r', 'e', '/', 'p', 'e', 'g'
    EXPECT_REJECTED(4, 0, RULE_NOT, 1, RULE_NCHAR, 1);
```

The verifier's rule is stricter than a depth-first walk and deliberately so: it
records per word whether that word is referenced as an operand (`0x01`) and
whether it is an instruction start (`0x02`), and rejects any word that is the
first without being the second. A word that is an instruction nothing refers to
is allowed. Unreachable bytecode is therefore fine and mis-aligned bytecode is
not, which is the right way round — the matcher never bounds-checks a rule
index, so it trusts that walk completely.

Five of this increment's eight defects are in that walk. Four are things it
lets through; the fifth is something it wrongly rejects.

### Two recursions, two counters, and they are not the same counter

`PegState.depth` bounds the matcher and is reset per attempt by
`peg_call_reset`, so `peg/find` gets a fresh budget at every offset it tries.
`Builder.depth` bounds the compiler and is not reset. Both start at
`JANET_RECURSION_GUARD`, and they count in opposite directions in the source:
`down1` pre-decrements and compares against zero, `peg_compile1` post-decrements
and compares the value before. That off-by-one is preserved rather than tidied,
because it decides which message a grammar exactly 1024 deep produces.

Only the compiler's two are asserted. Reaching the matcher's needs a recursive
grammar and about a thousand live `peg_rule` frames, and the C implementation
overflows the stack at 806 of them in an unoptimised build — which is a defect
in its own right, and the reason a test for it would crash the implementation
the contract is verified against. `FOUND.md` has it.

### The specials table is checked at compile time now

`peg_specials` is fifty-seven `{name, function}` pairs that
`janet_strbinsearch` binary-searches, and the C original keeps it in order by
saying so in a comment:

```c
/* Keep in lexical order (vim :sort works well) */
```

The Zig table carries a `comptime` block that walks it and refuses to compile if
any neighbour is out of order. That is not a behaviour change — a table out of
order compiles in C too and silently fails to find half its entries — but it
does mean a mutation that reorders the table is a compile error rather than a
survivor, which is the same outcome Part 7 reached for the parser's method table
by a different route.

The search itself is written out rather than calling `janet_strbinsearch`,
because that helper reads a `const char *` from the first word of each element
and the Zig table is a struct of a slice and a function pointer. The comparison
is still `janet_cstrcmp`, whose treatment of an embedded NUL a re-implementation
would have had to reproduce anyway.

### Where the port had to be deliberately unsafe

Two places, both because the C behaviour is defined and reproducing it is the
rule:

```zig
inline fn extraAt(extrav: [*c]const c.Janet, index: i32) c.Janet {
    const offset = @as(usize, @bitCast(@as(isize, index))) *% @sizeOf(c.Janet);
    ...
}
```

`(argument n)` takes a non-negative index from the compiler and crafted
bytecode does not go through the compiler. Writing `extrav[@intCast(index)]`
would turn a silent out-of-bounds read into a Zig panic in a checked build and
into something worse in a fast one, so the address is computed instead. And in
`pegUnmarshal`, every one of the size computations is `*%` and `+%` rather than
the checked operators Zig would otherwise use, because `bytecode_len` comes off
the wire and C's `size_t` arithmetic wraps.

The second of those is the one disagreement the differential corpus found, and
it is worth being precise about what "reproduce, do not repair" bought here: the
C behaviour is a heap buffer overflow, and the port now has it too. Both are in
`FOUND.md`, and neither is exercised by a test — the contract stops the stream
one byte before the first out-of-bounds write.

### The file is jump-transparent, and the reason will outlast the others

Every raise this file decides returns an error. Three kinds of call inside the
matcher still jump past these frames whatever the file does: `janet_array_push`
and `janet_buffer_push_u8`, reached from `pushcap` on almost every capturing
rule; the allocators the compiler reaches; and `janet_call` or a raw
`JanetCFunction`, which `(cmt ...)` and `(/ ...)` invoke with the captures so
far. The third is arbitrary Janet code running in the middle of the matcher's
own recursion, and it is not going away with a later increment: a matchtime
function is user code, and user code raises.

### What the mutation sweep found

131 mutants, **131 caught, none survived**, and the number needs less
qualification than Part 8's did. Three would not compile as first written —
Zig's unused-variable rule again, which is the third part running to meet it —
and were restated so that the variable stays used and the behaviour still
changes: `capLoad` became `capLoadKeept` rather than being deleted, `captured <
lo` became `captured + 1 < lo` rather than `captured < 0`, and a `til` whose
terminus never matches was made to succeed rather than have its result thrown
away.

The catcher is recorded per mutant, because Part 8 established that it has to
be:

| caught by | count |
| --- | --- |
| the C contract | 31 |
| `suite-peg.janet` | 98 |
| hanging rather than failing | 2 |
| interpreter startup | 0 |

**That last row is the interesting one, and it is Part 8's lesson coming out the
other way.** Marshalling had six mutants caught by the interpreter failing to
start, because the core image is a marshalled stream and a bad reader stops the
bootstrap. Nothing in the image is a compiled peg, so nothing here is caught
before the tests run, and every catch is a test performing it. A sweep over a
subsystem the runtime bootstraps *through* has to separate the three; a sweep
over one it does not can be read straight — but only after checking, which is
the same check either way.

The two hangs are honest catches with a caveat worth stating: both are
mutations that remove a forward-progress guarantee — `(any "")` losing its
empty-match guard, and `split` losing its check that a chunk advanced — and
what the harness observed was a 120-second timeout rather than an assertion.
A test that loops forever is a test that failed, but it is a slower and less
specific signal than a mismatch, and neither the suite nor the contract can say
what went wrong.

### The differential corpus

Forty seeds of twelve thousand cases — **480,000, one disagreement** — in three
shapes: a random pattern over random text, comparing what `peg/match`,
`peg/find-all` and `peg/replace-all` return; a compiled peg marshalled and read
back; and the bytecode of a *valid* peg mutated a byte at a time, which is the
shape that reaches the verifier's interior. A random first word is almost
always an opcode outside the vocabulary and is rejected on the first
instruction, so generating streams from scratch tests one branch over and over.

Part 4's `%j` lesson arrived once more, in a new place: accumulating a group
renders the group with `janet_to_string_b`, which prints an array by address.
The comparison strips `0x...` from both sides, which is the same fix Part 8
used and is worth keeping as the default posture rather than something to
rediscover.

The one disagreement was seed 31, and it was the port's fault and a real one:
Zig's checked multiplication trapped where C's `size_t` wrapped, in the size
computation `peg_unmarshal` performs on a length it took from the stream.
Fixing it meant reproducing a heap buffer overflow. That is what a differential
corpus is for — no test would have written that case, because writing it
requires already knowing the arithmetic overflows.

### Eight defects reproduced rather than repaired

The largest haul of the phase, and the shape of it is not an accident: five of
the eight are in the bytecode verifier, which is the only part of this file
whose whole job is to distrust its input.

The one that writes: **`bytecode_len` is multiplied by four without a check**,
so a length of 2^62 wraps the byte count to zero, the peg is allocated at the
size of its header, and the loop that fills the bytecode array writes as many
words past the end as the stream carries. The three that read: **`(argument)`
reaches `extrav[-1]`**, because the verifier does not look at the operand and
the matcher's bounds test is one-sided; **a program with no instructions is
accepted**, and the matcher then runs the constants array as bytecode, which a
crafted constant chooses; and **`OVERFLOW_CHECK` is wrong twice**, underflowing
for short programs and off by one for `RULE_LITERAL`, which reads past the
array before rejecting it anyway.

The fifth verifier defect is not a memory problem but is the most likely to be
noticed: **the readint width check tests the whole packed operand**, which also
carries the signedness and endianness bits, against the maximum width. So
`(int 4)` emits `0x14`, which is 20, which is greater than 8 — and three of the
four readint specials compile fine and are rejected by the verifier that reads
them back. Anything that stores a compiled peg is affected.

The other three are in the matcher and the compiler: **`(lenprefix ...)` leaves
the capture mode changed when its length pattern fails**, so an accumulation
around a failed lenprefix collects nothing; **the matcher's recursion guard
does not prevent a stack overflow** in an unoptimised build, which is where the
two implementations visibly disagree because the port's frames are smaller; and
**`(constant)` checks its arity with `janet_arity`** rather than `peg_arity`,
so one grammar error in fifty-seven arrives without naming its form.

All eight are in `FOUND.md` with reproducers. Six are pinned by tests; the
stack overflow is not, for the reason above, and the out-of-bounds *write* is
pinned only up to the byte before it happens.

### The matrix

Twenty-nine entries, all passing, 469 seconds at `-j2`. Six full: the four this
phase always runs, plus `-Dpeg-engine=c` and `-Dpeg=false`. Then the eight
selectors this engine is built out of, one at a time; the tagged layout; the
two documentation macros; the four feature reductions; the pointer shift; three
optimize modes; and four cross-compiles.

**`-Dpeg=false` is full for a reason no other entry has.** It is the one
configuration where the Zig object is not built at all, so what it has to prove
is not that the engine behaves but that nothing else in the tree reaches for
it — which shows up as a link failure or a missing binding, never as a contract
failure. `build.zig` skips `test/peg.c` there, the way it already skips
`test/inttypes.c` without integer types.

**And that entry failed on the first run, on something two increments old.**
`test/suite-debug.janet` gained an assertion in Part 7 that matches a stack
trace with `peg/find`, unguarded, and no matrix entry had run `zig build test
-Dpeg=false` until this one — Part 7's matrix had no reason to, and Part 8's
either. The assertion now carries a `compwhen`. Worth recording as a limit of
the acceptance matrix rather than a defect in it: the matrix tests the
configurations the increment gives it reason to test, so a configuration
nothing has touched for two parts is a configuration nothing has checked for
two parts.

### What this cost

`peg.c` goes from 1,924 live lines to zero — it compiles nothing but its
licence header — and `peg.zig` is 2,314 lines, of which 266 are comment. No C
body survives the guard: there is no variadic entry point and nothing that
cannot be named from Zig, so `peg.c` gains two lines of `#ifndef` and loses
everything inside them. `test/peg.c` is 716 lines, `test/suite-peg.janet` gains
seven assertions, and `test/suite-debug.janet` gains a guard it should have had
in Part 7.

Measured at `ReleaseFast`, interleaving the two selectors and taking medians of
seven:

| | C | Zig | |
| --- | --- | --- | --- |
| compiling a fourteen-rule grammar | 3.80us | 4.50us | 1.18x |
| a capture pattern over 8,800 bytes | 103.5us | 110.3us | 1.07x |
| a JSON-ish grammar over 14,000 bytes | 112.4us | 113.5us | 1.01x |

The shape matches Part 8's and for the same reason. The compiler is the slow
one because it makes many small raise-capable calls per rule and its recursion
never inlines, which is what Part 1's measurement predicts; the matcher is
within noise of the original, and it is the matcher that runs a thousand times
for every compile. `Raising(?[*]const u8)` — an error union over an optional
pointer, returned from the hottest recursive function in the file — costs about
as much as the C original's bare `const uint8_t *`, which is the first evidence
in this phase that the idiomatic shape is affordable in a hot path and not only
at a perimeter.


## The core environment, and the last of the library registration

Phase 10 Part 10 moves `src/core/corelib.c` and `src/core/run.c` to
`src/zig/subsystems/core_env.zig` behind `-Dcore-env`. **Both files compile
nothing but their licence headers afterwards**: `corelib.c`'s 1,263 live lines
and `run.c`'s 123 go to zero together. Thirty-six cfunctions, the
native-module loader, the bootstrap's inline assembler, the registration that
every other `janet_lib_*` hangs off, and the three entry points that run Janet
source moved in one increment. **Fifteen `janet_panic` call sites left C: 198
before this increment and 183 after**, all fifteen of them `corelib.c`'s, which
now contributes none.

That count is taken by preprocessing every `src/core/*.c` with all fifty-six
`JANET_ZIG_*` macros defined and counting `janet_panic`, `janet_panicv`,
`janet_panicf` and `janet_panics` calls attributed to a `.c` file. Re-running it
on Part 9's tree gives 198 where Part 9 recorded 199 — the same one-site
counting difference Part 5 recorded against Part 4, and the delta is the measure
either way.

### Two files, one selector, and the rule that decided it

Part 4's consolidation rule asks whether the pieces convert in different
increments, and these do not. They are also one subject rather than two that
happened to land together. `corelib.c` builds the core environment;
`janet_dobytes` reads a `JanetTable *env` and is the only thing in the tree that
runs Janet source *in* one without being handed a fiber first. A split would
have put a C bridge between `janet_core_env` and its only non-embedder caller
and bought nothing else. Part 5's rule settles the naming: a selector's subject
is a subsystem, not a file.

The count goes fifty-seven to fifty-eight, for Part 8's reason rather than
against Part 5's: this is a subsystem that had no Zig at all, not code moving
into one that did.

### The half that only one configuration compiles

`janet_core_env` has two implementations in the C original, chosen by
`JANET_BOOTSTRAP`. The generator assembles the environment out of thirteen
hand-written bytecode thunks, two assembly templates and a table of `janet_def`
calls; the runtime unmarshals it from the image and memoizes the result. Both
are in the Zig file, behind `corefn.bootstrap`, and **Zig does not analyse the
branch it does not take** — so the inline assembler is type-checked by
`-Dboot=zig` and by nothing else.

That is the same exposure Part 8 recorded for the forty lines behind
`JANET_MARSHAL_DEBUG`, with one difference that matters: there *is* a
configuration that compiles this, and the acceptance matrix runs it three times.
`-Dboot=zig` on its own, and paired with `-Ddocstrings=false` and
`-Dsourcemaps=false` — because `corefn.reg` decides its docstring and its source
map on `JANET_BOOTSTRAP` crossed with those two flags, and the arms that drop
them exist only in the generator. Before this part no entry had ever taken those
crossings.

The image the two generators emit still differs, deliberately, on the terms Part
6 set: a core cfunction records its source file, so thirty-six bindings that
said `/Users/…/src/core/corelib.c` now say `src/zig/subsystems/core_env.zig`.
Nothing else moved — the string sets of the two images differ in exactly those
paths — and the count of embedded absolute host paths in the `-Dboot=zig` image
goes from nine to eight.

### Feature gates come from the translated macros

`janet_load_libs` calls seven `janet_lib_*` functions that exist only in some
configurations, and `janet_dobytes`, `janet_loop_fiber` and `janet_native` each
branch on a feature too. This file asks `@hasDecl(c, "JANET_PEG")` and its kin
rather than having `build.zig` restate each condition as a macro with a value.

`state_abi.h` restates four macros on the stated grounds that "translate-c does
not surface a macro defined with no value". **Under Zig 0.16 it does** — as a
zero-length string constant, which `@hasDecl` finds and which a probe over
`JANET_PEG`, `JANET_EV`, `JANET_NET`, `JANET_FFI`, `JANET_ASSEMBLER`,
`JANET_INT_TYPES`, `JANET_FILEWATCH` and `JANET_DYNAMIC_MODULES` confirms one at
a time. The restatements in `state_abi.h` are left alone, because their call
sites want a *value* and not a presence test, and because moving them is a
change to every subsystem that reads them. A new gate does not need one.

### Where a raise appears, and where it deliberately does not

A cfunction that decides to raise returns `raise.Error` from an `Impl` function
and delivers it in a two-line abi, which is the shape Part 9 settled.
Twelve of the thirty-six are written that way. The other twenty-four make no
such decision — `(describe x)` cannot fail on its own account — and are written
as the plain `JanetCFunction` they are. Giving those an error union they never
return would be ceremony rather than shape, and the file says so rather than
being uniform for its own sake.

`(signal what x)` is the one place where the mechanism is visible from Janet.
The C original called `janet_signalv`, which records the decision and then
jumps; the port `return`s `raise.signal(...)`, and the cfunction's abi turns
that back into the jump its caller is waiting for. Nothing else changes, because
`janet_zig_signal_record` is shared between the two deliveries — which is what
Part 2 built it for.

`core_env.zig` is nevertheless **jump-transparent**, and will be for the rest of
the phase. `janet_arity`, `janet_getstring` and their thirty relatives are
`-Dargs-core`'s abis, `janet_panic_type` is another, and a call to one from
this object crosses the C ABI and therefore raises by jumping. That is Part 4's
seam rule — an error union cannot cross a subsystem seam — and not something
this increment could have avoided. Every frame between such a call and the
fiber's try scope holds nothing: the one scratch allocation in the file is
`janet_smalloc`'s, inside `module/expand-path`, and the collector releases it on
the unwind.

### Two things that had to stay in C, and one that could not

`stdin` and `stdout` join `stderr` in `io.c` as three-line accessors. Part 7
found that translate-c renders the three handles a different way on each of this
project's platforms — an inline function on macOS, a variable of opaque type on
musl, a container-level constant initialised by a call to an extern function on
mingw, which Zig rejects at the reference rather than at the use — so
`janet_zig_stdin` and `janet_zig_stdout` are scaffold in the sense "Target"
gives the word, and go out with `janet_zig_stderr` and `janet_dynprintf` in Part
17. `(getline)` is their only caller.

`janet_eprintf` is a variadic macro over `janet_dynprintf`, which translate-c
cannot render at all, so `janet_dobytes` writes the macro out — the same three
lines `trace_frames.zig` carries, for the same reason. Part 7's distinction is
what makes that legal: Zig cannot *define* a C variadic on every target this
project builds for, but calling one is ordinary.

What could not stay is the dynamic-library vocabulary. `util.h` picks between
three of them — `dlopen`/`dlsym` macros, real Windows functions in `util.c`, and
a pair of stubs when `JANET_NO_DYNAMIC_MODULES` — and `abi.zig` deliberately
does not translate `util.h`, because its `#include <dlfcn.h>` fallback breaks
the Windows cross-compile for every subsystem at once. So `core_env.zig`
reproduces the switch itself: `std.c.dlopen` and `std.c.dlsym` on POSIX, the
`util.c` functions declared directly on Windows, and constants in the third
case. `error_clib` and `get_processed_name` stay in `util.c` in all three,
declared directly as the `abi.zig` note allows.

One thing the C original leaves implicit and the port had to write out:
`dlerror` answers NULL when nothing has failed, and `janet_native` hands its
result straight to `janet_cstring`, which would walk from address zero. It is
unreachable — the only call is on the branch a failed `dlopen` took — but Zig's
type says otherwise, so there is a fallback string there.

### What the contract is for, and what it could not be for

`test/suite-corelib.janet` covers the cfunctions, because every one of them has
a Janet spelling; this increment added 174 assertions to it, mostly around
`module/expand-path`'s six template replacements and its normalization pass,
which had none, and around the thirty-four assembled functions the section
below explains nothing was running. `test/core_env.c` covers everything around them, and all
of it is C-only:

- `janet_core_env`'s `replacements` parameter has no Janet spelling. Nothing in
  the tree passes a non-NULL table, so both the substitution — a name in the
  lookup table is what the image resolves a core cfunction *through*, so
  replacing the name replaces the binding — and the memoization that makes it a
  one-shot are reachable only from C.
- `janet_dobytes` answers with a *set of flags* and a value, and Janet code sees
  neither. Its `len` parameter has no Janet spelling either, so a stream that
  stops mid-source is reachable only here.
- `janet_loop_fiber` is called by `shell.c` and by no Janet code.
- `janet_native`'s failure paths need no shared object; its success path needs
  one, and `test/zig-native.janet` already had it.

The diagnostics are captured rather than printed. `janet_dynprintf` resolves
`:err` before falling back to its handle, and `janet_dobytes` prints its
diagnostics from the top level — after the fiber has finished — where that
lookup goes to `janet_vm.top_dyns`. Binding `:err` to a buffer therefore both
asserts the text and keeps the contract's own output clean.

**The one thing no test in this tree can pin is the `memcmp` offset overflow.**
Signed overflow is undefined, so Part 8's rule applies rather than Part 9's:
there is nothing to reproduce, the port takes the sum wide and answers
correctly, and an assertion either way would fail against the other
implementation — against the C one by aborting the whole suite, since this
project compiles C with `-fsanitize=undefined`. `FOUND.md` records it with the
sanitizer's output.

### The compiler inlines the bootstrap's own functions, so nothing ran them

The mutation sweep's most useful result, and it is about the tests rather than
about the port. `janet_core_env` assembles thirty-four functions out of
bytecode by hand — thirteen through `janet_quick_asm`, thirteen variadic
operators, six comparators — and **the compiler inlines every one of them when
it sees the name in call position.** `(+ 1 2)` becomes `JOP_ADD` and never
enters the thunk; that is what the `JANET_FUN_ADD` flag on the funcdef is
*for*. So the 1,565 assertions of `suite-boot.janet`, and every other
assertion in the tree, exercise the opcodes and leave the assembled bodies
unrun.

Inverting the `<` comparator's result changes nothing observable:

```
$ janet -e '(print (< 1 2)) (print (apply < [1 2]))'   # with invert flipped
true
false
```

Reaching the bodies takes passing the function as a value, which
`test/suite-corelib.janet` now does for all thirty-four, at each arity and on
both exits of every comparator. Two mutants — the `invert` flag on `<` and on
`>=` — survived a full `zig build test -Dboot=zig` before that and are caught
after it.

This is the sharpest form of a rule the phase already had. Part 7 found roughly
570 lines that a build *compiled* and nothing ran; this is code that a build
compiles, a test suite calls by name, and nothing runs, because the call was
optimised away before it reached the callee.

### `assert-error` checks that something was raised, not what

The second finding of the same kind. `test/helper.janet` has two macros and the
difference is easy to miss:

```janet
(defmacro assert-error [msg & forms] ...)              # msg is the label
(defmacro assert-error-value [msg errval & forms] ...) # errval is compared
```

`assert-error` takes its first argument as the *test name*. Writing the
expected message there — which reads naturally, and which the suite already did
in places — asserts only that some error was raised. Three mutations inside
message literals survived every pass because of it: `"expected base between 2
and 36"` becoming `"...2 or 36"` fails nothing. The seventeen assertions this
increment added where the text is a contract use `assert-error-value`.

### The sweep, and what its first pass cost

189 mutants over `core_env.zig`, **161 caught, one uncompilable, 27
deliberate survivors**, in three passes: a default build, then
`zig build test -Dboot=zig` over the survivors of that, then a third pass over
the survivors of *that* after the holes above were closed.

The two-stage judge is what made the second pass affordable. Half this file is
compiled only by the image generator and the rest of the survivors were in
`janet_native`, whose success path only `test/zig-native.janet` reaches — so
the judge builds `-Dboot=zig` first, which fails or fails to boot for anything
wrong in the assembler, and escalates to the whole `zig build test` graph only
for what survives that. Most mutants never reach the expensive stage.

**The first pass had to be thrown away, and the reason is in `AGENTS.md`
already.** Two edits were made to `core_env.zig` while it ran. The harness
restores from its own backup, so the edits were lost — but a `sed` that rewrites
the file between the harness's write and the build it judges can also lose the
*mutation*, and the result is a build of unmutated source recorded as a
survivor. It cut both ways: mutants that the suite plainly catches were logged
as surviving, and mutants that nothing can catch were logged as caught. The
rule is not only about tests added mid-sweep; it is about the file, and the
failure is silent.

A second discipline the sweep needed: **it gets a cache directory of its own
and wipes it periodically.** Every mutant is a distinct source *content*, and
`.zig-cache` is never garbage collected, so the first attempt deposited about
1.4GB per mutant and filled a 460GB disk after eighty-five of them — after
which builds fail for reasons that have nothing to do with the mutation, and
those failures are recorded as verdicts too.

The 27 survivors, classified:

| how many | why |
| --- | --- |
| 8 | comptime-dead on this host: the Windows and no-dynamic-modules arms of `clib` and `isPathSep`, and the non-event-loop arm of `janet_loop_fiber`. The matrix covers these, the sweep cannot. |
| 3 | need a deliberately mismatched shared object: the `dlopen` mode, and the two `or`s in the version comparison, which agree with `and` whenever the module matches. |
| 6 | arithmetically equivalent: over-allocating one byte, clamping zero to zero, the `INT32_MAX` range boundary that would need a two-gigabyte allocation to reach, two loops that read a slot past `argc` which the callee ignores, and the unprint in `normalizePath` — whose `print -= 1` and `print -= 2` both land on the same separator, because the walk-back loop that follows finds it either way. Checked by hand rather than assumed. |
| 2 | read one past a bucket array without observable effect. |
| 3 | visible only to the collector, at one instant, under pressure no test applies. |
| 3 | the compile-error position: telling them apart needs a compile error whose source mapping is absent, and every path that produces one supplies it. |
| 1 | the event-loop entry guard: `janet_vm.stackn` is zero everywhere a caller can reach `janet_dobytes` from. |
| 1 | `feof` and a negative `fgetc` are both true at end of file and both false before it. |

### The matrix, and what it is asked to prove

**Thirty-seven entries, all passing**: thirty-three native and four
cross-compiles. Nine are full `zig build test` runs rather than
library-plus-contract, which is more than any previous part, and the reason is
that every Janet suite runs *inside* the environment this increment builds — a
regression here shows up as a suite failure long before it shows up as a
contract failure.

Three of the nine are `-Dboot=zig`, alone and crossed with
`-Ddocstrings=false` and `-Dsourcemaps=false`. Those two crossings had never
been taken by any entry: `corefn.reg` decides its docstring and its source map
on `JANET_BOOTSTRAP` crossed with those flags, and the arms that drop them
exist only in the generator. Six entries turn off one optional library each —
`-Dpeg`, `-Dassembler`, `-Dint-types`, `-Dnet`, `-Dffi`, `-Dfilewatch` — because
`janet_load_libs` calls a `janet_lib_*` per feature and what those ask is
whether the environment still links and still starts without one.
`-Ddynamic-modules=false` is there for the third arm of `janet_native`'s
library switch, which no other configuration compiles.

### What it costs

Nothing measurable. At `ReleaseFast`, medians of seven interleaved, run in both
directions on a quiet machine: every one of the ten workloads changes sign
between the two pairings, which is `PLAN.md`'s test for a delta that is not
real. The largest movement in either direction is `fib` at +3.7% and then
−1.4%, and `fib` is the internal control — it is arithmetic and recursion and
cannot touch this increment at all — so about ±4% is the noise floor here and
nothing in the corpus is outside it.

The corpus does reach the code: `strings` calls `(string ...)` two hundred
thousand times and `tables` calls it sixty thousand more, which is
`janet_core_string` in both cases. That check matters more than the numbers,
for the reason Part 4 recorded — a flat corpus that never enters the increment
is a negative result about everything else.

## Files

Phase 10 Part 11 moves `src/core/io.c` to `src/zig/subsystems/io_core.zig`,
behind the `-Dio-core` selector that already held its two kernels. The
`core/file` abstract type and its five callbacks, twenty-two cfunctions, the
eight public `JanetFile` entry points and the registration moved together.
**`io.c` goes from 769 live lines to 68**, and what is left is one C variadic,
the three stream handles it needs, a five-line directory test, and the licence
header. **Thirty-five
`janet_panic` call sites left C: 183 before this increment and 148 after**, and
`io.c` now contributes none.

Two figures there need their method stated. The panic count is `panics.py`'s,
which preprocesses every `src/core/*.c` with all fifty-eight `JANET_ZIG_*`
macros defined and counts the calls attributed to a `.c` file. The live-line
count is the same preprocessor, counting non-blank lines instead; re-measuring
the phase-opening table's `io.c` row that way gives 624 rather than the 769 it
records. That is the third counting difference this phase has found — Part 5
against Part 4, Part 10 against Part 9, and now this — and as before the delta
is the measure either way: 68 lines is what a build compiles today, and every
one of them is named below.

### No new selector, and a name that has stopped describing itself

`-Dio-core` was Phase 6's, for "file mode parsing and the stream host
operations": two portable kernels and fifteen result-returning calls on a
`FILE *`, with the abstract type, the argument extraction and every panic path
left in C. Part 5's rule — a selector's subject is a subsystem, not a file —
and Part 6's application of it decide where the surface goes, and it is the
selector that already owns the kernel. The count stays at fifty-eight.

What that leaves is a name whose `core` suffix meant "kernel only, surface
still in C" and no longer means anything here. Four other selectors carry it
with that sense. Renaming would move every matrix entry, every acceptance table
and every `JANET_ZIG_*` guard for no behavioural reason, so it stays and this
paragraph is the note.

### What cannot move, and the one symbol the remainder needs

`janet_dynprintf` is a C variadic and public API. Part 4 established that a
variadic *entry point* is the one shape that cannot be ported at all — Zig can
call a C variadic but cannot define one — and Part 7 sharpened the rule to say
that it binds where the variadic signature is the contract. It is here. So
`janet_dynprintf` keeps its C body, and with it the three handles that
`translate-c` renders three incompatible ways across this project's targets:

```c
FILE *janet_zig_stderr(void) { return stderr; }
FILE *janet_zig_stdin(void)  { return stdin; }
FILE *janet_zig_stdout(void) { return stdout; }
```

Those four functions and the directory test two sections down are the 68
lines. The variadic and the three handles go in Part 17 with `janet_panicf`;
the directory test goes with the platform layer.

The C body needs one thing it cannot do for itself. Its `JANET_ABSTRACT` case
asserts that the file is writeable, and that assertion raises — so it is in
Zig with every other raise in this subsystem, and `io.c` reaches it through a
two-line abi:

```zig
export fn janet_zig_io_assert_writeable(iof: *c.JanetFile) callconv(.c) void {
    assertWriteable(iof) catch raise.deliverToC();
}
```

with `#define io_assert_writeable janet_zig_io_assert_writeable` on the Zig arm
so that the body reads the same under both selectors. That is what keeps the
file at zero `janet_panic` call sites rather than two.

### The file becomes jump-transparent, which is the opposite of the usual direction

Phase 10's acceptance list asks that a file which *stops* being
jump-transparent say so in the same commit. This one starts. Before this
increment `io_core.zig` made no raise-capable call at all: the mode scanners
are pure and the host operations report failure by returning, which is exactly
what let the seam be drawn where Phase 6 drew it. The surface calls
`janet_arity`, `janet_getabstract`, `janet_getbytes` and eight of their
relatives, which are `-Dargs-core`'s abis; `janet_buffer_format`, which is
`-Dpp`'s; and `janet_sandbox_assert`, which is `-Dvm-lifecycle`'s. Each crosses
the C ABI, and Part 4's seam rule is why an error union cannot come back across
it: a raise inside one of them is a `longjmp` through these frames.

The consequence is visible in one place and is a reproduction rather than a
regression. `printfImplX` builds a scratch buffer, formats into it, and frees
its backing store by hand:

```zig
buf.*.count = 0;
buf.*.capacity = 0;
c.janet_free(buf.*.data);
buf.*.data = null;
```

A bad conversion inside `janet_buffer_format` jumps past that in C and jumps
past it here. It is exactly the `defer` the marker forbids, and writing one
would have been the silent behaviour change the check exists to catch.

### The raise shape, cfunction by cfunction

Part 10's finding applies without restatement: not every cfunction gets an
error union. Of the twenty-two here, twenty decide to raise and are written as
an `Impl` returning `raise.Raising(Janet)` behind a two-line abi. The other
two are `flush` and `eflush`, which cannot fail at all — `janet_flusher`'s
three arms are "flush it", "flush the default handle", and "do nothing" — and
giving them an error union they never return would be ceremony rather than
shape.

Twenty abis is not twenty pieces of boilerplate. The sixteen members of the
print families are generated from four comptime specialisations, so each abi
is written once and instantiated four times.

The four families are comptime specialisations rather than four bodies:

```zig
fn Print(comptime newline: bool, comptime name: [:0]const u8, comptime handle: anytype) type
fn XPrint(comptime newline: bool) type
fn Printf(comptime newline: bool, comptime name: [:0]const u8, comptime handle: anytype) type
fn XPrintf(comptime newline: bool) type
```

`handle` is a function rather than a value because `janet_zig_stdout` has to be
*called*: the C original names `stdout` in a registration table, and a Zig
table entry cannot, for the reason the three handles exist.

### `corefn.def` had only half of `JANET_CORE_DEF`, and this is the increment that noticed

`JANET_CORE_DEF` expands two ways. The bootstrap defines a documented binding
in the environment the image is made of. The runtime calls
`janet_core_def_sm`, which drops the documentation and the source map and puts
the bare value — into `janet_core_lookup_table`'s dictionary, which is **not**
the environment. That dictionary is what `janet_unmarshal` resolves the image's
symbol references against.

Part 6 read the runtime arm as redundant and compiled it out, on the grounds
that the image already carries the binding:

```zig
pub fn def(...) void {
    if (!bootstrap) return;
    c.janet_def_sm(...);
}
```

That held for `math.c`, which was its only user: `math/pi` is a number and
marshals inline, so nothing ever looked it up by name. It does not hold for
`io.c`. `stdout`, `stderr` and `stdin` are live `FILE *` handles wrapped in an
abstract; they can only come from the running process, and the image refers to
them by name. With the runtime arm missing, the interpreter does not start:

```
error: bad slot #0, expected core/file, got nil
  in os/isatty [src/core/os.c] on line 2116
  in cli-main [boot.janet] on line 4835, column 7
```

which is `boot.janet` asking whether `stdout` is a terminal and being handed
the nil that `stdout` now resolves to. The fix is the missing branch, and the
lesson is narrower than "check both arms": **a macro with a bootstrap arm and a
runtime arm has two behaviours, and the runtime one can be invisible for as
long as its only user is a value the marshaller can reconstruct.**

### `FILE` is opaque on musl and complete on macOS, and the cross-compiles found it

`FILE` is opaque by definition — the standard says so, and that is what let
Phase 6 draw this subsystem's seam as a `void *` handle rather than as a
structure. `translate-c` does not agree with the standard, because it renders
what the *platform header* says: macOS spells out `struct __sFILE`, and musl
leaves `struct _IO_FILE` incomplete. So `JanetFile.file` translates to a `[*c]`
C pointer on one and an optional pointer on the other, `[*c]c.FILE` is a
compile error on musl — "indexable pointer to opaque type not allowed" — and
**no single spelling of the translated type compiles on both**.

The fix is to stop naming the translated type at all. This file declares its
own `const FILE = opaque {}`, every extern and every public abi speaks
`?*FILE`, and the conversion happens in two three-line functions at the
`JanetFile.file` field:

```zig
inline fn streamOf(iof: *c.JanetFile) ?*FILE { return @ptrCast(iof.file); }
inline fn setStreamOf(iof: *c.JanetFile, file: ?*FILE) void {
    iof.file = @ptrCast(@alignCast(file));
}
```

The `@alignCast` is what the complete-structure spelling asks for and what the
opaque one ignores.

**Twenty-nine native matrix entries passed against the version that named
`c.FILE`; three of the four cross-compiles failed.** That is the second time in
this phase the cross-compile entries have been the only thing to catch
something, after Part 7's three spellings of `stderr`, and it is the same shape
of fault: a C construct whose *translation* is per-platform, invisible on the
host.

While the streams were being retyped they also became optional throughout. A
closed `JanetFile` holds a null, two of the paths below can be reached with
one, and the C library gives both a meaning — `fflush(NULL)` flushes every
output stream in the process, `setvbuf(NULL, ...)` is undefined. Reproducing
either requires the null to travel as a null rather than through a checked
cast, which is why each host operation is now written once over `?*FILE` and
exported once over the seam's `void *`.

### The one host structure that could not move, and why it is not `FILE`

`file/open` rejects a directory by `fstat`ing the descriptor it has just
opened. That needs `struct stat`, and Zig cannot ask for one portably:
`std.c.fstat` is `{}` on Linux and `std.c.Stat` has no Linux arm at all,
because glibc did not export `fstat` before 2.33 and Zig declines to choose
between `__fxstat` and a raw `statx` syscall on the caller's behalf. The two
things a Zig frame could do instead are both refused elsewhere in this tree: a
second `@cImport` over `<sys/stat.h>` is the duplicate translation
`abi.zig`'s single-translation rule exists to prevent, and a hand-written
layout per platform is exactly what `os_stat.zig` declined to do when it left
`jstat_t` in C.

So the test stays in C, as a five-line `janet_zig_io_isdir`, and it is the
third kind of scaffold this file now holds — after the variadic and the three
stream handles. It is `io.c`'s five remaining lines beyond those, and it goes
with the platform layer rather than with `janet_panicf`.

The first attempt did move it, using `std.c.Stat` and `std.c.S.ISDIR`, and
passed every native entry. **The Linux cross-compiles are what said no**, in
the same run that rejected `c.FILE`. Recording that is worth more than the
five lines: the host compiles a great deal that `std.c` does not actually
promise, and "it builds on macOS" is not evidence about `std.c` at all.

### What the contract is for, and what only it can reach

Three things in this subsystem have no Janet spelling at all, and they are most
of what `test/io_core.c` grew to cover.

The eight `JanetFile` entry points are C API. `janet_makefile`,
`janet_makejfile`, `janet_getfile`, `janet_getjfile`, `janet_checkfile`,
`janet_unwrapfile`, `janet_dynfile` and `janet_file_close` are what `os.c` and
`ev.c` use to hand a subprocess's pipe or an event-loop stream to Janet as a
file, and no Janet program can call one.

The abstract type's `marshal` and `unmarshal` callbacks run only under
`JANET_MARSHAL_UNSAFE`, and `(marshal f)` never sets it — the Janet-reachable
path is the *refusal*, which is the one line of the pair a suite can see. The
contract drives both directions with the flag set, and checks the thing that
makes the pair worth having: a closeable file's descriptor is duplicated, so
the unmarshalled copy is a different `FILE *` on the same file and closing one
leaves the other writable.

And `janet_dynprintf` is the C variadic. Its four destinations are the same
four the print families take, so testing it is also the differential the
acceptance list asks for — "the abi and the Zig implementation of a converted symbol
are tested separately", and here the abi is a whole function that stayed
behind.

One thing the contract does that the suites cannot, and that Part 10's lesson
asks for directly: it checks the *message*, not the fact of a raise.
`EXPECT_PANIC_MSG` compares `_state.payload` against a literal, because Part 10
found three mutations inside message strings surviving a whole sweep on the
strength of `assert-error` naming the test rather than the text.

### The method table's order is the contract

`janet_getmethod` scans linearly and `janet_nextmethod` walks in table order, so
`(keys f)` reports `[:close :flush :read :seek :tell :write]` and a reordering
is observable. Part 7 found exactly this about the parser's method table when a
reordering mutation survived, and corrected a comment that claimed a binary
search. The contract pins the whole walk and the suite pins the array.

### What the mutation sweep found

**116 mutants, 112 caught, one uncompilable, three deliberate survivors.**
Attribution: eighty-five by the contract, two of those by hanging rather than
failing; nineteen by `suite-io.janet`; and six by interpreter startup alone.
That last figure is Part 8's caveat arriving somewhere other than the
marshaller — `stdout`, `stderr` and `stdin` are bindings the image resolves, so
a mutation in the registration stops the runtime before any test runs, and a
sweep that only asks "did something fail" would record six catches no test
performed.

The uncompilable one is `const windows = builtin.os.tag == .windows` inverted,
which makes a macOS build reference `_fseeki64`, `_fdopen` and their kin and
fail to link. That is the fourth part running to meet a mutant Zig refuses
rather than a test catching it.

An earlier pass over the same file, before the portability rework, caught 101
of 116 and left fourteen survivors. **Ten of the fourteen were holes**, and
three of them are worth the space.

Two needed a handle no Janet program can build. A `JanetFile`'s flags and its
stream can disagree, because `janet_makejfile` takes the flag word from its
caller and never consults the stream, and that is the only way to reach the two
branches where a host call fails on a file whose flags say it should not:
`file/read` distinguishing a short read from a broken one, and `xprint` naming
its destination when a write fails. The contract resolves the cfunction by name
and calls it with the mismatched handle, which is a thing only a C caller can
do and exactly the kind of coverage the acceptance list means by testing the
two abis separately.

The third took reading this increment's own `FOUND.md` entry the other way
round. A mutation of `file/open`'s buffer-size test survived because **an
explicit buffer size can never reach a writable file at all** — the third
argument replaces the mode with read-only, which `FOUND.md` already recorded —
so the size has no observable effect on buffering. What it does have is a
failure mode: a size the C library cannot allocate raises, and the mutant
silently does not. `(file/open path :r (- (math/pow 2 53) 1))` is the
assertion.

The three that remain cannot be caught by anything, and saying why is the
point of listing them. One is a comptime equivalence, `!windows and !plan9`
where both operands are compile-time constants and both true on every target
this builds. One is a defensive `len < 0` on a value `janet_string_length`
cannot produce. The third is `cstrequal`'s loop bound: reading one byte past
the length reaches the NUL that every `JanetString` carries, so the answer does
not change — which is worth knowing about the function rather than worth
asserting.

### The differential corpus

220 hand-written observations, and fifteen seeds of ten thousand random cases:
**150,000 cases, no disagreement.** The hand-written half covers every one- and
two-byte mode string over the full flag alphabet, every destination the four
print families accept, and each behaviour `FOUND.md` records. The random half
fuzzes mode strings up to eleven bytes over an alphabet including a NUL and a
high byte, and every format specifier the formatter has against every atom
type.

Nothing here needed Part 4's `%j` precaution, and it is worth saying why not:
this subsystem renders values only through `janet_to_string_b` and
`janet_buffer_format`, both of which the pretty printer already made
reproducible. The probe prints results rather than containers.

### The matrix

**Thirty-six entries, all passing**: thirty-two native and four
cross-compiles, nine of them full `zig build test` runs. Both arms of
`-Dio-core` are full rather than shallow, which is new for an increment's own
selector and follows from what `io.c` is: `print` is called by thirty-four
suites and by `test/helper.janet` itself, and the three standard handles are
bindings every one of them resolves, so a regression here surfaces as a suite
failure long before it surfaces as a contract failure.

**Three of the four cross-compiles failed on the first run**, which is what
those entries are for and the second time this phase they have been the only
thing to catch something. Both faults are above: `[*c]c.FILE` does not compile
where `translate-c` leaves `FILE` incomplete, and `std.c.fstat` does not exist
on Linux.

Eleven entries turn one selector back to `c`. They are the subsystems this one
calls across the C ABI, and `marsh` and `pp` lead because their seams are the
ones this increment newly depends on: the abstract type's marshal pair is the
only way into `-Dmarsh` from an abstract's side, and `janet_buffer_format` is
what the whole `printf` family is.

### What it costs

The corpus that reaches this code says nothing. Seven io workloads at
`ReleaseFast`, medians of seven interleaved and run in both directions: five of
the seven change sign between the pairings, and the two that do not agree at
+0.2% and +0.1%. The largest single figure anywhere is `readall` at 3.3%, and
it is one of the five that flips.

The Phase 9 corpus is the more interesting reading, because it does *not*
reach this code and moves anyway. It reports the `-Dio-core=zig` binary
consistently 1–3% slower across nine of ten workloads — and **`fib`, which is
arithmetic and recursion and cannot touch a file, is the worst at 6–8%.** That
is the control moving more than anything it controls for, which is the
signature of code layout rather than of this increment; the Zig binary is
22,832 bytes larger. Part 10 recorded the same shape and drew the same
conclusion. What can be said positively is narrower than "no cost": the
workloads that enter the new code show nothing above 1.5%, and the increment
cannot be shown to be responsible for what the ones that do not enter it show.

## The OS surface

Phase 10 Part 12 moves the rest of `src/core/os.c` into four Zig sources behind
one new selector, `-Dos-surface`: `os_surface.zig` holds the platform,
environment, clock and miscellaneous cfunctions and assembles `janet_lib_os`;
`os_files.zig` holds the filesystem family, `os/stat` and the permission
conversions; `os_procs.zig` holds the `core/process` abstract type and the
eleven cfunctions that make or manage a subprocess; and `os_calendar.zig` holds
`os/date`, `os/strftime` and `os/mktime`. Forty-eight cfunctions moved.

**`os.c` goes from 1,402 live lines to 96**, and what is left is one function,
a `jstat_t` typedef, a field-identifier enum, the includes those need and the
licence header. **Fifty `janet_panic` call sites left C: 148 before this
increment and 98 after** — the phase's second-largest single drop after Part
8's sixty, and the first time the count has fallen below a hundred. `os.c` now
contributes none, where it contributed more than any other file.

Both figures are `panics.py`'s preprocessor, the live-line one counting
non-blank lines instead of calls. The phase-opening table records 1,931 for
this row; re-measuring it the same way gives 1,402. That is the fourth counting
difference this phase has recorded — Part 5 against Part 4, Part 10 against
Part 9, Part 11 against the table, and now this — and as before the delta is
the measure either way.

### This is the increment decision 4 was taken for

Phase 10's fourth decision overturned a judgment `PLAN.md` had recorded as
permanent: process control and the calendar were parked as forever-C because
they work through `posix_spawn_file_actions_t`, `struct sigaction`,
`STARTUPINFO`, `PROCESS_INFORMATION` and `struct tm`, and a host structure's
layout is the platform header's. The decision keeps that reasoning for the
*structures* and drops it for the *language*: they are still libc's, and Zig
reaches them through a second translation, `src/zig/os_abi.h`.

That is a real amendment to the first of this document's four platform rules,
and the amended rule is worth stating. **A host structure stays in C only when
translate-c cannot give it to us.** Where the header translates completely, the
structure is libc's and Zig may name it — provided it does not cross a
subsystem boundary, which none of these do: a `struct tm` lives for the length
of one cfunction and a `posix_spawn_file_actions_t` for the length of one
spawn. "No C in the tree" and "no libc" are different claims and only the first
is a goal.

Two of this document's existing notes are falsified by that and are corrected
here rather than left standing. Under `-Dos-fs-paths`, Windows directory
enumeration was said to stay in C because `_findfirst` fills a `struct
_finddata_t` "whose layout depends on the CRT's `time_t` configuration": mingw
resolves `_finddata_t` to `_finddata64i32_t` in the header, translate-c renders
it completely, and the three `_find*` aliases come through with it. And under
`-Dos-process`, "every structure stays in C" is now "every structure is still
libc's".

### `struct stat` is the one it cannot reach, and that is measured

`os_files.zig` has the measurement. musl declares `struct timespec` with a
bitfield — padding written as
`int :8*(sizeof(time_t)-sizeof(long))*(__BYTE_ORDER==4321)` — and translate-c
demotes any structure holding a bitfield to `opaque {}`. `struct stat` embeds
three `timespec`s, so it is demoted after it, and Zig can neither size one nor
place one on the stack. macOS and mingw translate both completely, which is
exactly what makes it easy to miss; all three musl targets do not.

So `os.c` keeps `janet_zig_os_stat_read`, which stats a path and copies out the
mode word and one `double` per numeric field. Every Janet value `os/stat`
produces is built in Zig and the fifteen getters are gone. Two details of that
seam are worth recording. The array is **zeroed before it is filled**, because
Part 5's lesson applies to it exactly — a descriptor's unwritten fields are
part of its contract and nothing about the type says so — and three of its
fifteen slots are never written by any platform while two more are never
written by Windows. And the function is **compiled under both arms of
`-Dos-surface`**, which is forty lines nothing calls in the C arm and is the
price of `test/os_surface.c` being able to exercise it at all: a contract
cannot see a selector macro, which is a trap `test/vm_lifecycle.c` had already
fallen into and `FOUND.md` now records.

### One selector, because the registration is indivisible

Part 6's rule sends a cfunction surface to the subsystem that already owns its
data structure, and it cannot be applied here. `os.c` registers every `os/`
binding from a single `janet_lib_os` and its cfunctions are `static`, so a
build with `-Dos-fs=c` and `-Dos-process=zig` would have no way to produce one
registration table — a Zig table cannot name a C static. Part 4's rule then
decides the rest from the other side: a split is worth its seams only when the
pieces convert in *different* increments, and these convert in one because they
are registered in one. **The count goes fifty-eight to fifty-nine.**

`core` was not available as a suffix, for the reason Part 9 rejected
`-Dpeg-core`: in four other selectors it means "a kernel whose cfunction
surface is still in C", and this is the surface.

The eight `-Dos-*` kernel selectors are untouched and still mean what they
meant. This object calls them across the C ABI exactly as `os.c` did, so
`-Dos-fs=c` still swaps the `getcwd` wrapper under a Zig `os/cwd`, and the
matrix has an entry for each of the eight. That is Phase 10's acceptance rule
about testing the two abis separately, applied to eight seams at once: the C
abi is the one that disappears, so it is the one that rots.

Four sources behind one selector is `-Dpp`'s shape, and folding them into one
object buys the same thing it bought there. `os_get_unix_mode` raises, and five
cfunctions in three different `-Dos-*` subjects call it — `os/perm-string`,
`os/perm-int`, `os/chmod`, `os/umask` and `os/open`. Across a selector seam
that could not have been an error union; inside one object it is an ordinary
Zig call, and a bad permission argument propagates as a `raise.Error` instead
of being delivered as a jump through the spawn's frames.

### The signal table stops being split

`-Dos-process` holds the signal *names* and reports a position; `os.c` held a
`#ifdef`-gated array mapping a position to a number, with `-1` for a signal the
platform does not define. That split existed because a name is portable and a
host constant is not. The constants are now reachable, so the mapping is
`@hasDecl` per signal instead of `#ifdef` per signal, and it is **compiled on
every target** rather than only on the host — the same coverage gain the FFI's
three conventions and the file watcher's three backends made, and for the same
reason. The `-1` sentinel and its consequence are preserved exactly: `:poll`
still reports `undefined signal :poll` on macOS and resolves on Linux.

### `JANET_THREADS` is defined by nothing, and this is where it shows

`FOUND.md` recorded that in Part 8. Here it decides three things. The
environment lock is two empty functions in every build this tree can produce,
so `os_abi.zig` supplies them as named no-ops and records the `pthread_mutex_t`
and `CRITICAL_SECTION` arms rather than writing them — Part 8's rule about a
branch no configuration compiles. `os/sigaction` manipulates its mask with
`sigprocmask` rather than `pthread_sigmask`. And `janet_lib_os`'s Windows
critical-section initialisation is dead in the same way.

The lock's *call sites* are kept even though the lock is nothing, because they
are the contract: `os/getenv` holds it across the copy of a borrowed `getenv`
result rather than only across the call, and `os/execute` holds it across the
spawn. Those are what a future threaded build would need.

### What the cross-compiles caught, for the third increment running

Three portability faults, none of them visible on the host, and the first is
much the most serious.

**`janet.h`'s platform macros come out wrong in the translation.** Aro — Zig
0.16's translate-c front end — predefines `__unix__`, `unix` and `__unix` for
`x86_64-windows-gnu` alongside `_WIN32`, and `janet.h` tests its Unix chain
first. So `@cImport` for that target defines `JANET_POSIX` where `zig cc`
compiling the same header for the same target defines `JANET_WINDOWS`, and
every platform-varying type follows it — `JanetHandle` above all, which is
`void *` on Windows and `int` elsewhere. No Zig subsystem had ever needed one:
they all test the platform with `builtin.os.tag` and read only `janetconf.h`'s
macros through `@hasDecl`. `os/open` and `os/spawn` are the first to name
`JanetHandle` and the cross-compile failed immediately. The correction is three
`#undef`s in `state_abi.h` and `os_abi.h`, which exist to prepare C for
translate-c; `FOUND.md` has it, along with the rule it leaves behind.

**`struct sigaction`'s handler member has three spellings.** POSIX allows
`sa_handler` to be a macro over a union member and every libc takes that up
differently: `__sigaction_u.__sa_handler` on macOS, `__sa_handler.sa_handler`
on musl, `__sigaction_handler.sa_handler` on glibc. `setHandler` looks the path
up by name from a candidate list rather than by position, so a fourth spelling
fails to compile rather than writing into the wrong member.

**mingw declares `localtime_s` and does not export it.** The header maps it
onto the CRT's `_localtime64_s`, so calling the declared name compiles and
fails to link. `_environ` is the same shape — a macro over `__p__environ()`,
and only the accessor is a symbol. The `64` in those names is a `time_t` width,
so a comptime assertion makes a narrow `time_t` a compile error rather than a
silent mismatch.

That is the third increment running in which the cross-compiles were the only
thing to catch something, and the first in which one of the faults was a
*translation* rather than a missing declaration.

### A build defect this increment had to fix to run its own matrix

`-Dboot=zig` did not compile once this object existed, and the reason is one
line in `build.zig`. The bootstrap objects were built for a target assembled
from the host's arch, OS tag and ABI with the **OS version dropped**, which
resolves to `aarch64-macos-none`. Without a version the macOS SDK's
availability macros expand differently, `<spawn.h>` drags in the mach headers,
and `mach_msg_type_descriptor_t` — another bitfield structure — is demoted to
opaque, at which point the header's own `_Static_assert` on its size fails the
translation. Starting from the host's own target query instead keeps the
version and still pins the CPU model, which is what the pin was for. Only a
subsystem that translates a system header notices, and this is the first one
that does.

### The one behaviour this increment changes on purpose

Every other departure from `os.c` in this part is a reproduction or a
recording. One is a fix. `os/rm` asserted no sandbox permission, while
`os/mkdir`, `os/rmdir`, `os/cd`, `os/rename`, `os/touch`, `os/chmod`,
`os/umask`, `os/link` and `os/symlink` all assert `JANET_SANDBOX_FS_WRITE` —
so a program under `(sandbox :fs-write)` could still delete any file the
process could reach.

Two things about how it was done are the general points. **Both arms carry the
fix**, `src/core/os.c` as well as `os_files.zig`: two implementations that
disagree make every differential result in this project meaningless, so a
behaviour change is never a change to one of them. And **the assertion goes
before the arity check**, matching its neighbours, because the order is
observable — `(os/rm)` with no arguments reports the sandbox error rather than
the arity error, exactly as `(os/mkdir)` does.

`FOUND.md` keeps the entry in full rather than replacing it with the fix,
because the defect is upstream Janet's and is worth reporting there.
`os/readlink` has the same shape — it reads a link target with `:fs-read`
forbidden — and is deliberately left alone, because only `os/rm` was agreed.

### What the mutation sweep cost, and what it was worth

Four runs, of which the first three measured nothing. That is worth recording
in full, because each failure was silent and each produced a number that looked
better than the truth.

**Run 1: 302 mutants, 294 caught, no survivors — and worthless.** `mutate.py`
runs a contract with `capture_output=True`, which blocks until every writer to
the pipe closes. This contract spawns `/bin/sleep 30`, and an orphan left by an
aborting run held the pipe for the harness's entire twenty-second bound. 234 of
the 294 "catches" were therefore timeouts rather than decisions — and worse, a
mutant whose contract *passed* but which broke `os/proc-kill` left seven
orphans, timed out on the pipe, and was recorded as caught by a test that had
not caught it. The fix is two-sided: a spawned child is given an explicit
stdout and stderr so it cannot hold the harness's pipe, and the kill is
*asserted* — a signal that terminates makes Janet report 128 plus its number —
so the mutant fails an assertion instead of relying on the harness noticing.

**Run 2 aborted in its warm-up, and the reason is about signals.** The fix
above killed children with `:hup`, and the sweep is launched with `nohup`.
`nohup` ignores SIGHUP; an ignored disposition is *inherited across `fork` and
`exec`*; `/bin/sleep` therefore ignored it too and `(os/proc-kill p true :hup)`
waited forever. It never reproduced interactively, because an interactive shell
does not ignore SIGHUP — twenty-one clean runs by hand said the tree was green
while the sweep said it was not. SIGKILL is the only signal that cannot be
caught or ignored, so the contract now tests the *lookup* where the table is
the subject and uses SIGKILL where death is. (The four core-dumping signals had
to go too: sending `:segv` to a child on macOS wakes `ReportCrash`.)

**Run 3 was valid for two files and then poisoned itself.** A mutated
`os/open` mode created `unique.txt` in the working tree with permissions 0000.
`test/suite-ev.janet` writes and re-reads that file, could no longer open it,
and **fifty-seven of seventy-four `os_files` mutants were recorded as caught by
`suite-ev.janet`**. What gave it away was the attribution column: a
file-writing suite has no business catching mutations in a permission parser.
`mutate.py` now clears a debris list before every judged run.

The generalisation is one line long and belongs to every sweep after this one:
**read the attribution distribution, not the total.** A sweep whose catches are
mostly timeouts, or mostly one suite that has nothing to do with the subject,
is a sweep to distrust before it is a sweep to report. It is Part 8's rule
about labelling the catcher — which was written about the bootstrap catching
marshaller mutants — arriving twice more from directions it did not anticipate.

**Run 4: 302 mutants, 192 caught, 8 uncompilable, 102 deliberate survivors**,
in two passes. The first pass caught 159 and left 135, much the worst first
showing of the phase, and it was correct. The survivors clustered in three
places this contract had not looked at: `os/open`'s flag scanner, the
optional-argument branch of half the surface, and the parts of `os/spawn` only
a redirection reaches. Closing them took about a hundred and thirty assertions
and caught 33 more.

The 102 that remain are four kinds, and none of them is a hole a test on this
host could close. Roughly half are Windows arms — comptime-false here, so Zig
does not even analyse them, and the cross-compile is the only thing that checks
them. A quarter need a host call to fail: `pipe`, `dup`, `fdopen`, `chroot`, or
a `sigaction` interrupted by another signal. A dozen are unobservable by
construction, the clearest being the length of the slice `corefn.install`
passes, which nothing reads because `janet_cfuns_ext` walks to a null name
instead. The rest need a process state not worth building — a *stopped* child,
a redirection onto file descriptor 0, `os/shell` with a command.

One is an honest gap rather than an impossibility. `os/exit`'s `force` argument
picks `_Exit` over `exit`, and the only visible difference is whether stdio
buffers are flushed — which only a child process can be asked. A contract has
no interpreter to spawn: `(dyn :executable)` is set by `src/mainclient/shell.c`
and a contract builds its environment with `janet_core_env`, which is the core
library and not the client. Forking in C and redirecting through a pipe would
work; two mutants did not justify it.

### What it costs

Ten `os/` workloads at `ReleaseFast`, medians of seven interleaved and run in
both directions. Unlike Parts 10 and 11, most of these do *not* change sign
between the pairings, so most of them are real:

| workload | delta | reading |
| --- | --- | --- |
| `perms` | +5.6% | real, and the one to expect |
| `environs` | +3.5% / -2.8% | real, ~3% |
| `clocks` | +3.3% / -2.2% | real, ~2.7% |
| `dates` | +2.7% / -2.2% | real, ~2.5% |
| `strftimes` | -3.9% / +3.1% | real, ~3.5% *faster* |
| `stats`, `getenvs`, `mktimes`, `statfield`, `dirs` | ±1.8% | sign flips; noise |

`perms` is the one to believe. It is 512,000 round trips through
`os/perm-string` and `os/perm-int`, two cfunctions that do almost nothing but
convert nine bits, so nearly all of it is call overhead — which is exactly what
Part 1 measured the raise mechanism costing, and the first time in the phase
that a workload has been dominated enough by it to show.

The Phase 9 corpus is the counterweight and reads the other way. It cannot
reach any of this code, and it reports the Zig binary **0.4-5.3% faster**, with
`fib` — arithmetic and recursion, the internal control — the most improved of
the ten. That is the control moving more than anything it controls for, which
is the signature of code layout rather than of this increment; `libjanet.a` is
47,856 bytes larger. Parts 10 and 11 saw the same shape with the sign the other
way round and drew the same conclusion.


## The event loop

Phase 10 Part 13 moves `src/core/ev.c` into four Zig sources behind one new
selector, `-Dev-loop`: `ev_loop.zig` holds the scheduler, the timeout heap, the
main loop, the threaded-call machinery and the registration; `ev_stream.zig`
holds the `core/stream` abstract type, the read and write state machines and
the pipe constructor; `ev_channel.zig` holds `core/channel`; and
`ev_backend.zig` holds the Windows completion port and the `epoll`, `kqueue`
and `poll` backends. Thirty cfunctions moved.

**`ev.c` goes from 2,166 live lines to 24**, and what is left is one function,
`janet_zig_ev_protect`, its comment, and the licence header. **Twenty
`janet_panic` call sites left C: 98 before this increment and 78 after**, and
`ev.c` now contributes none.

Both figures are `panics.py`'s preprocessor, the live-line one counting
non-blank lines instead of calls. The phase-opening table records 2,932 for
this row; re-measuring it the same way gives 2,166. That is the fifth counting
difference this phase has recorded, and as before the delta is the measure
either way.

### The second `setjmp` does not die here, and the reason is a rule

Phase 10's increment list said this part deletes it. It does not, and what
replaces that expectation is worth more than it would have been:

> A protected scope can stop being a `setjmp` only when every raise that can
> reach it is already a Zig error.

The scope is the one `ev/thread`'s child interpreter runs under. Inside it,
`janet_go_thread_subr` unmarshals the abstract registry, the supervisor, the
fiber and the resume value — four calls to `janet_unmarshal`, any of which can
raise on a stream the child cannot resolve. `janet_unmarshal` belongs to
another subsystem, behind `-Dmarsh`, and Part 4 established that **an error
union cannot cross a subsystem seam, because a selector's seam is the C ABI**.
So its raise arrives here as a `longjmp` whichever arm of `-Dmarsh` is
compiled, and the only thing that can catch a `longjmp` is a `setjmp`.

Deleting the scope would therefore not remove a jump. It would remove the
*catcher* — and the catch is load-bearing: it is what turns a failed thread
start into an `:error` message on the supervisor channel, or into the parent's
`ev/thread` call raising, instead of into a top-level signal that ends the
process.

What is left is nine lines:

```c
JanetSignal janet_zig_ev_protect(void (*body)(void *), void *ctx, Janet *payload) {
    JanetTryState tstate;
    JanetSignal signal = janet_try(&tstate);
    if (!signal) body(ctx);
    janet_restore(&tstate);
    if (signal) *payload = tstate.payload;
    return signal;
}
```

`body` is a Zig function reached through a C function pointer, and a raise from
inside it is delivered by the ordinary bridge rather than by anything special:
by the time `raise.deliverToC` runs, every Zig frame between the raise and it
has already returned, which is the inversion `SPIKE-10.md` demonstrated and the
whole reason the `defer` ban can be retired per file.

It is compiled under **both** arms of `-Dev-loop`, unused by the C loop.
`AGENTS.md` has the rule: a contract cannot see its selector, because
`test/*.c` is a separate module that gets `JANET_BOOTSTRAP` and nothing else,
so a function behind a `JANET_ZIG_*` guard is one no contract can name.
`janet_zig_os_stat_read` is Part 12's worked example.

This generalises to the third `setjmp` as well, which is why `PLAN.md`'s "three
jumps" section now says the two of them go together in Part 17.

### One module with four files, which is not what `-Dpp` and `-Dos-surface` do

Those two fold sources into one object by making each a module and importing
one from another. That shape needs a directed acyclic graph. This subsystem
does not have one, and the cycle is not incidental:

  - the backend steps a stream's callbacks;
  - a stream's callbacks schedule a fiber;
  - the scheduler polls the backend;
  - a channel wakes a fiber that a stream is waiting on;
  - and `janet_stream_close` unregisters from the backend, which the backend
    itself calls after every event it delivers.

`ev.c` is one translation unit for exactly that reason. Zig allows **file**
imports inside one module to be cyclic where module imports may not, so the
object is one module rooted at `ev_loop.zig`, and the other three are reached
with `@import("ev_stream.zig")` and its kin. `corefn.reg`'s `sourcePath`
assertion still holds — it requires `@src().file` to be a bare basename, which
it is, because the module root's directory is `src/zig/subsystems/`.

`build.zig` runs `checkJumpTransparency` over all four sources rather than over
the root, because that check is about a *source*: the root is the only file the
build names, and three quarters of the object would otherwise go unlooked at.

### Four backends, one compiled, and the selection follows the translation

`state.h` lays `JanetVM` out differently per backend — `iocp` and `connect_ex`
on Windows, `epoll` and `timerfd` on Linux, `kq` and `timer` on the BSDs,
`streams` and `fds` otherwise. Which arm it took is decided before Zig sees the
structure, so the backend this object compiles has to be the same one, or every
field it names is at the wrong offset.

So the selection reads the translation's own answer:

```zig
pub const selected: Backend = if (windows)
    .iocp
else if (@hasDecl(c, "JANET_EV_EPOLL"))
    .epoll
else if (@hasDecl(c, "JANET_EV_KQUEUE"))
    .kqueue
else
    .poll;
```

with a `comptime` check that `builtin.os.tag == .windows` and
`@hasDecl(c, "JANET_WINDOWS")` agree. Part 12's rule — test the platform with
`builtin.os.tag`, read only `janetconf.h`'s macros through `@hasDecl` — applies
to the Windows arm, which is the one Aro's predefines used to get wrong; the
two POSIX arms are read from the translation because agreeing with the
translated `JanetVM` is the property that matters.

Each backend is a `struct` namespace. Zig analyses a container's declarations
only when something references them, so exactly one is compiled and the other
three cost nothing — `#elif` without the property Part 7 warned about, that a
file which compiles is not a file that runs.

### `-Dkqueue=false`, and the quarter of this increment nothing was compiling

macOS takes kqueue, Linux takes epoll, Windows takes the completion port. Across
this project's host and its four cross-compile targets, **nothing selects the
`poll` backend at all**. It is not dead code — a `-Depoll=false` Linux build or
any platform that is neither uses it — but no configuration in the matrix
reached it, so nothing had type-checked it, let alone run it.

Two entries fix that: `-Dkqueue=false` natively, which is a full `zig build
test` and runs every suite through the poll backend, and
`-Dtarget=x86_64-linux-musl -Depoll=false` as a build. The native one failed on
its first run, on two `janet_realloc` calls over `JanetStream **`.

This is Part 9's `-Dpeg=false` lesson in a new place. **The matrix tests the
configurations the increment gives it reason to test**, and a backend nothing
compiles is a backend nothing has checked.

### What the cross-compiles caught, for the fourth increment running

Four faults, none visible on the host:

  - **`FILE` is incomplete on musl.** `janet_dynprintf` takes a `FILE *`, and
    the obvious spelling — `[*c]c.FILE`, which is what `translate-c` gives the
    declaration — does not compile there, because Zig will not make an
    indexable pointer to an opaque type. `?*c.FILE` does. Part 11 met exactly
    this in `io_core.zig`, and the note there is why `janet_zig_stderr` is a
    function rather than a variable in the first place.
  - **Zig 0.16's `std.os.windows` no longer declares `OVERLAPPED`.** So
    `JanetOverlapped` — which lives in `src/core/util.h`, the header `abi.zig`
    deliberately does not translate — has its layout restated in Zig. The C
    original spells it as a union of `OVERLAPPED` and `WSAOVERLAPPED`; the two
    have the same layout and only one arm is ever used, so the union is not
    reproduced.
  - **`janet_vm.iocp` is declared `void **`.** Every Windows call wants the
    handle, so the field is a double pointer at every use, and
    `ev.iocpHandle()` is the one cast.
  - **`InterlockedIncrement` is a mingw compiler intrinsic, not a symbol its
    import library exports.** An `extern` declaration of it links on no target
    at all. `@atomicRmw` is the same operation; the only thing to be careful
    about is that `InterlockedIncrement` reports the *incremented* value.

### The Android arm is recorded rather than written

`handle_timeout_worker` cancels a deadline's worker thread with
`pthread_cancel`, which does not exist on Android; the C original sends
`SIGUSR1` there instead, and the worker installs a handler for it before
sleeping. The `pthread_kill`/`pthread_exit` half is ported, because neither
needs a host layout. The `sigaction` install is not.

That is Part 8's rule: **Zig does not analyse a comptime-false branch**, and
`android` is comptime-false for every target this project builds, so writing
the install would produce something even less checked than the C it replaced.
`os_abi.zig` made the same call for `JANET_THREADS`, and for the same reason.

### The contract found its first defect by hanging

`test/ev_loop.c` was written against `-Dev-loop=c` first, as the rule at the
end of `AGENTS.md` requires. It never finished. The case was three lines:

```c
janet_ev_post_event(NULL, NULL, msg);
janet_loop();
```

`janet_ev_post_event` raises `listener_count` unconditionally, because the loop
must not decide it is done while an event is in flight. The POSIX self-pipe
handler lowers it again *inside* `if (NULL != response.cb)`. So an event posted
with no callback is delivered and the reference is never given back, and
`janet_loop_done` answers false for ever. The Windows completion port lowers it
outside the test and does not have this.

`janet_loop1_interrupt` is the in-tree caller that posts a null callback, so
this is on its own path rather than on an unused one. Both behaviours are
reproduced, `FOUND.md` has the entry, and the contract pins both — one turn of
the loop rather than a call to `janet_loop`, and the count put back by hand on
POSIX.

Two things follow for how a contract over an event loop should be written. It
**does not drive the polling backend**: `janet_loop1_impl` blocks until a
descriptor is ready or a timeout expires, and a contract that waits on the
kernel is a contract that hangs when it is wrong. What it checks instead is
everything either side of the poll — the loop's exit condition, the heap's
ordering, and the self-pipe round trip, which `janet_loop1` performs without
entering the backend at all. And where it needs a fiber, it attaches a
supervisor channel by hand, so that a cancelled task's error goes to the
channel the test reads rather than to a stack trace on stderr.

### What the contract is for, and what only it can reach

`test/suite-ev.janet` has 742 assertions and every one goes through the thirty
`ev/` bindings. Six areas have no Janet spelling:

  - **The embedder's channel API.** `janet_channel_make`, `janet_channel_give`
    and `janet_channel_take` are the non-blocking mode (`mode == 2`) of the
    push and the pop, which `ev/give` and `ev/take` never select. The only
    other thing that reaches it is the loop's own supervisor push, and then
    only on a fiber that has already failed.
  - **`janet_stream_ext`.** Type-punning a stream — a larger allocation and a
    caller-supplied method table — is what `net.c` does and what no Janet
    program can ask for.
  - **`janet_make_pipe`'s four modes.** Janet reaches mode 1 through `os/spawn`
    and nothing else, and the descriptor flags each mode sets are invisible
    from Janet even then. The contract pins all sixteen: which of the two ends
    gets `FD_CLOEXEC` and which gets `O_NONBLOCK`, per mode.
  - **`janet_ev_default_threaded_callback`'s nine tags.** `ev/thread` uses two.
  - **The abi of every symbol this increment converted.** While both
    mechanisms are live, an exported symbol raises by `longjmp` for its C
    callers and returns an error to its Zig ones. `catching()` in the contract
    is `janet_zig_ev_protect`, which is how a jump is asserted on.
  - **`janet_zig_ev_protect` itself**, which is why it is compiled under both
    arms.

### Three defects reproduced rather than repaired, and one that cannot be

`FOUND.md` has all four in full.

**`janet_ev_post_event` with a null callback leaks a listener reference** on
POSIX and not on Windows — the entry above.

**A threaded channel unmarshals as an unthreaded one.**
`janet_chanat_unmarshal` reads `is_threaded` back off the wire and uses it to
choose between `janet_unmarshal_abstract_threaded` and
`janet_unmarshal_abstract`, so the allocation is right; it then calls
`janet_chan_init(abst, limit, 0)` with the flag hard-coded off. The result
lives on the threaded heap and takes none of its locks.

**`janet_ev_default_threaded_callback` frees a string literal.** Its cleanup
switch shares one statement between `default` and the two `*_STRINGF` cases it
names, so every tag frees `argp` — and `janet_go_thread_subr` sets
`JANET_EV_TCTAG_ERR_STRING` with `"failed to start thread"`.

The fourth is undefined rather than defined, so Part 8's rule applies instead
of Part 9's: **`janet_stream_tostring` hands a `JanetHandle` to a `%d`**, which
is exact away from Windows and a mismatched vararg width there. There is
nothing to reproduce; the port truncates explicitly so that the low half of the
handle prints.

### The differential corpus

134 observations across the whole `ev/` surface — channel construction and
shape, give and take, `select` and `rselect`, closed channels, the argument
errors of every cfunction, tasks and supervisors, deadlines, streams, pipes,
`ev/to-file`, both lock families, threads, and the marshalling of a channel —
run under both arms of `-Dev-loop` and diffed.

**The two implementations differ on exactly one line**, and it is the source
path a stack trace records for `ev/sleep`: `src/core/ev.c` under the C
selector, `src/zig/subsystems/ev_loop.zig` under the Zig one. That is Part 6's
documented consequence of `corefn.reg` recording the row of the registration
table rather than the line of the definition, and `-Dboot=c` and `-Dboot=zig`
have differed that way since.

Writing the probe met the trap `differential.sh` warns about twice. A `select`
result carries the channel, and an abstract renders by address; and three
argument-layer messages quote the value they rejected, which is an abstract in
each case. Scrubbing hex addresses out of the text was the fix — dropping the
cases would have dropped the interesting half.

### What the mutation sweep cost, and what it was worth

Two of the four sources were swept to completion and two were not:

| source | sites | caught | survived | note |
| --- | --- | --- | --- | --- |
| `ev_loop.zig` | 172 | 114 (93 by tests) | 56 | 2 uncompilable |
| `ev_channel.zig` | 139 | 95 | 44 | |
| `ev_stream.zig` | 197 | — | — | aborted at mutant 108 |
| `ev_backend.zig` | 185 | — | — | aborted at mutant 0 |

Both aborts were disk, not the code; the entry below has the measurement. The
gap is recorded rather than hidden, and closing it is queued for the phase
gate.

The first pass over `ev_loop` caught 89 of 172 and the second 114, after the
tests grew by ninety assertions. The survivors it drove out clustered exactly
where Part 12's did -- in the places the contract had not looked -- and three
are worth naming because each was a defect in a *test* rather than in the code:

  - `ev/all-tasks` was checked before the scheduler had run the task, so only
    the half of the bookkeeping that *adds* was ever exercised;
  - `janet_schedule_signal` was paired with `janet_schedule_soon`, which cannot
    tell appending from prepending -- with both prepending the order comes out
    the same;
  - nothing anywhere held a task's *resume value* across a collection, because
    `ev/go` copies it into the fiber's stack and so roots it twice.

**Twenty-one of `ev_loop`'s catches are `startup`.** The interpreter enters
`janet_loop` on the way up, so a mutation in the scheduler stops it before any
test runs; that is a catch no test performed, and the figure to report is 93.
`ev_channel` has none at all -- nothing in the core image is a channel -- which
is Part 9's `peg.c` result arriving again and settles that the rule is a check
to perform either way rather than a caveat that always applies.

### The sweep found nothing wrong with the port

Worth stating plainly, because it bears on how much the practice is worth.
Every porting defect this increment had was found by something cheaper:

| defect | found by |
| --- | --- |
| `janet_ev_mark` crashing on a null spawn queue | `zig build test` |
| `[*c]c.FILE` will not compile on musl | cross-compile |
| `std.os.windows.OVERLAPPED` gone in Zig 0.16 | cross-compile |
| `janet_vm.iocp` is declared `void **` | cross-compile |
| `InterlockedIncrement` is a mingw intrinsic | cross-compile |
| two `janet_realloc` casts in the poll backend | the `-Dkqueue=false` build |
| the null-callback refcount leak | `test/ev_loop.c`, first run |

A mutation sweep cannot find these, by construction: it does not test the code,
it tests the tests. Its return is the ninety assertions, which are about Janet
behaviour rather than about Zig and so outlive the abis Part 17 deletes.

Three of its costs here were waste. About a third of the 691 sites are in arms
this host never compiles -- Zig analyses a container's declarations lazily, so
a mutation inside the three unselected backends does not even reach codegen and
survives meaninglessly. A second pass to confirm hole-closing repeats work the
*next* increment's sweep does anyway. And code that exists only to serve the C
ABI is deleted in Part 17 and is not worth mutating. The first of those is
fixable by hashing the built artifact and reporting an identical one as **no
effect** rather than as a survivor; that is queued.

### What it costs

Ten workloads at `ReleaseFast`, medians of seven interleaved, run in **both**
pairings -- and this is the increment where the second pairing stopped being a
formality. Taking the half-difference of the two orderings removes the additive
per-position bias:

| workload | C first | Zig first | real |
| --- | --- | --- | --- |
| `rendezvous` | +3.9% | -3.6% | **+3.8%** |
| `chans` | +3.5% | -3.7% | **+3.6%** |
| `locks` | +3.3% | -3.0% | **+3.2%** |
| `sleeps` | +2.7% | +0.9% | +0.9% |
| `selects` | -0.8% | -2.4% | +0.8% |
| `spawns` | -0.2% | -0.3% | +0.1% |
| `counts` | +2.6% | +3.0% | -0.2% |
| `pipes` | -0.4% | +1.8% | -1.1% |
| `deadlines` | -0.5% | +2.4% | -1.5% |
| `fib` (control) | +3.0% | +2.5% | **+0.25%** |

The control is what makes the table readable. `fib` is arithmetic and recursion
and cannot reach the event loop, yet it reads +3.0% and +2.5% raw -- as large
as anything else in the corpus -- and +0.25% once the orderings are combined.
So a single pairing carries two to three points of noise, and the formula
earlier parts used, "the sign changes between pairings, so it is noise", was
discarding real signal along with it. Parts 10 through 12 should be re-read
with that in mind.

What survives is coherent and is what Part 1 predicts. The three workloads that
are nearly all call overhead -- two scheduler round trips, a give/take pair, an
acquire/release pair -- are 3.2 to 3.8 percent slower, and the workloads that do
real work per call show nothing. `libjanet.a` grows by about seventeen
kilobytes.

## Sockets

Phase 10 Part 14 moves `src/core/net.c` into two Zig sources behind one new
selector, `-Dnet-sockets`: `net_sockets.zig` holds socket creation, the connect
and accept state machines, the seventeen `net/` cfunctions, the socket-option
table, the stream method table and `janet_lib_net`; `net_addr.zig` holds the
`core/socket-address` abstract type, the two keyword vocabularies, the
`getaddrinfo` wrapper and the address decoder, plus the four cfunctions built
on them.

**`net.c` goes from 696 live lines to none, and nothing is left behind.** That
is the difference from Part 13, and the reason is one sentence: this file opens
no protected scope, so there is no `setjmp` for a raise to be caught by and
nothing that has to stay until Part 17. `ev.c` kept nine lines;
`#ifdef JANET_NET` here now wraps `#ifndef JANET_ZIG_NET_SOCKETS` and the whole
body inside it.

**Twenty-nine `janet_panic` call sites left C: 78 before this increment and 49
after.** `net.c` was the largest remaining contributor and now contributes
none. `ffi.c` is the largest, at 27.

The phase-opening table records 985 live lines for this row against the 696
`panics.py`'s preprocessor gives on this host; that is the sixth counting
difference this phase has recorded, and as before the delta is the measure
either way. The two counts differ by the Windows arms, which are a third of the
file and which no macOS preprocessor takes.

### Two files, two modules, and the tree's third translation of host headers

`net_addr.zig` is reached with `@import("net_addr")` and nothing goes back, so
the two are **modules folded into one object** -- the shape `-Dpp` and
`-Dos-surface` use -- rather than the cyclic file imports `-Dev-loop` needs. An
address knows nothing about the socket it was looked up for, which is what
makes the graph acyclic; `ev.c`'s four parts each know about the other three.

`src/zig/net_abi.h` is the third translation of host headers in the tree, after
`abi.zig` and `os_abi.zig`, and it is here for the reason `os_abi.h` gives for
the second: nothing it declares crosses a subsystem boundary. A `struct
addrinfo` lives for the length of one cfunction, and the one socket address
that outlives its call is `janet_address_type`'s abstract, which is a byte
buffer both sides already treat as opaque -- `ev.c` and `ev_stream.zig` pass it
as `void *`. Adding `<netdb.h>` and `<winsock2.h>` to `abi.zig` would put them
into the translation every Zig object in the tree shares, to serve two files.

It includes `<janet.h>` for three *platform* names and nothing else --
`JANET_BSD`, `JANET_ILLUMOS` and `JANET_GNU_HURD`, which the two restatements
at the bottom of the header test exactly as `net.c` does. Restating those
chains would have been the alternative and is the duplication these ports exist
to remove.

### The Windows headers are translated, where `ev_stream.zig` did the opposite

Part 13 declared `WSARecvFrom` and its kin by hand because what it needed was
four calls and one structure. What `net.c` needs from Winsock is forty integer
constants whose values differ from the POSIX ones -- `SOL_SOCKET` is `0xffff`
against Linux's `1`, `AF_INET6` is 23 against 30 on macOS and 10 on Linux --
and forty hand-copied magic numbers on a platform this project builds but does
not run is a worse bet than a translation the matrix compiles.

The bet held, and the exceptions are the interesting part. Measured on
2026-08-23, every declaration these two files name survives the translation for
`x86_64-windows-gnu` except four:

  - **`WSAID_CONNECTEX`** is a brace initializer, which translate-c renders as
    `@compileError`. Restated as a Zig `GUID` literal.
  - **`FIONBIO`** is `_IOW('f', 126, u_long)`, and `_IOW`'s body contains a
    `sizeof`, which the macro translator cannot parse. `IOC_IN` and
    `IOCPARM_MASK` both survive, so `net_abi.zig` writes the same expression
    rather than the number it evaluates to.
  - **`struct sockaddr_un`** does not exist there at all, and a Zig *field
    type* is analysed whether or not the code around it is. `SockAddrUn` is
    `opaque {}` on Windows, which is what lets `AddrInfo` name the pointer on
    every target while the unix branch stays comptime-false.
  - **`struct sockaddr_in6`** survives with its fields dissolved. Windows'
    declaration ends in an anonymous union -- `sin6_scope_id` against a
    `SCOPE_ID` -- and translate-c demotes any record holding one to
    `opaque {}`. `sockaddr_in6_old` is the same structure without that union,
    so its four members sit at the same offsets as the first four of the modern
    one, and the two this project reads are inside them. Two `comptime`
    assertions on `@offsetOf` are what make that a checked claim.

The third and fourth generalise, and they are new in kind. Part 13's lesson was
that a declaration can *disappear* from a Zig or system header between
versions. This one is that a declaration can **survive translation with its
contents removed** -- and the failure then arrives as "does not support field
access" at the use site rather than as a missing symbol at the declaration.

### What the cross-compiles caught, for the fifth increment running

Four faults, and the host caught none of them.

  - **`struct sockaddr` is 2-aligned on Linux and 1-aligned on macOS**, because
    `sa_family_t` is `unsigned short` there and `__uint8_t` here. `@ptrCast`
    from the `void *` the C keeps its address in compiles on the host and is
    rejected on musl as "increases pointer alignment". The fix is not
    `@alignCast`: it is to give the variable the type it always had, `[*c]const
    struct sockaddr`, so that neither end needs a cast. This is AGENTS.md's
    rule -- "a construct whose *translation* is per-platform is invisible until
    something else translates it" -- arriving through an alignment rather than
    through a missing declaration.
  - The three Windows translation faults above, all four of which were found by
    `-Dtarget=x86_64-windows-gnu` and none of which any native entry can reach.

The fourth is `LPFN_CONNECTEX` needing a `@constCast` on the way into
`janet_vm.connect_ex`, which is a one-line difference between two translations
of the same type and is only worth recording as the fifth thing the host could
not have told us.

### Five defects, four reproduced and one that cannot be

`FOUND.md` has all five with reproducers. Two of them are worth naming here
because of *how* they were found.

**A failed `net/connect` closes a file descriptor twice.** `cfun_net_connect`
wraps the socket in a `JanetStream` before it connects, and the failing path
then closes the handle by hand and raises, leaving a stream whose `CLOSED` flag
was never set holding the same number. The collector closes it a second time
later, by which point the kernel may have given it to something else. That is
not theoretical and needs no race:

```janet
(protect (net/connect :unix "/tmp/no-such-socket-xyzzy"))
(def f (file/open "/tmp/probe.txt" :w))
(gccollect)
(pp (protect (do (file/write f "hello") (file/flush f) :wrote)))
```

reports `(false "could not flush file")` on both selectors, and writes and
reads back `@"hello"` without the first line. Closing a valid descriptor is
defined, so the port reproduces the sequence.

**`net/connect` releases a unix domain address with `freeaddrinfo`.**
`janet_get_addrinfo` returns two different things behind one pointer -- a
`getaddrinfo` chain, or a `janet_calloc`ed `struct sockaddr_un` -- and seven of
its eight callers remember which. The eighth reads `ai_canonname` and `ai_next`
out of the bytes that hold `sun_path` and frees whatever it finds. Whether that
survives depends on how long the path is: eleven characters returns the error
message, twenty-six aborts. Passing an invalid pointer to `free` is undefined,
so `PLAN.md`'s rule applies and the port releases it correctly. **The two
implementations differ here by design**, which is the first such divergence
since Part 9.

The *shape* is what made it findable. `AddrInfo` carries the discriminant with
the pointer and releases through one method, so eight call sites that each had
to remember became one that cannot forget.

The other three: `net/address` leaks the unix domain address it built, on both
of its return paths; `net/address` reads `argv[3]` after checking `argc >= 3`,
so a three-argument call returns an array or not depending on what the fiber
stack holds; and `janet_so_getname` reports an IPv6 decoding failure with the
word "ipv4". All three are defined behaviour and all three are reproduced, with
comments.

### What the contract is for, and what only it can reach

`test/net_sockets.c`: fifty-three assertions, eleven of them raises checked
by their message. Five things have no Janet spelling:

  - **A socket address this machine cannot produce.** The decoder switches on
    `sa_family`, and a Janet program can only hand it a family the host
    actually gave it. A machine with no IPv6 route never reaches the
    `AF_INET6` arm, nothing reaches the "unknown address family" arm, and a
    macOS host cannot construct Linux's abstract unix address, whose leading
    NUL is what selects the `'@'` branch. All of them are a `memset` and a
    `janet_abstract` away from C -- which is possible only because
    `janet_address_type` is `JANET_ATEND_NAME`, with no callbacks at all.
  - **`janet_address_type` as a symbol**, which is one of the four things these
    two files export.
  - **The order of `net_stream_methods`.** `JanetStream` is public and its
    `methods` member is the table, so the fourteen rows can be read back in
    order.
  - **A `sun_path` longer than the structure**, where the truncating copy is
    invisible from Janet.
  - **Failure paths asserted by their message** rather than by their existence,
    which Part 11 recorded as the difference between a test and a tautology.

It does not open a connection: `net/connect` and `net/accept` end by suspending
the calling fiber, so driving either from C means running the loop, and a
contract that waits on the kernel is a contract that hangs when it is wrong.

**The contract found the `freeaddrinfo` defect by aborting**, on its first run
and against the *C* selector, which is the arm the rule says to verify first.
It now uses an eleven-character path so that it can be run under both arms, and
says why in a comment -- a contract cannot see its selector, so it cannot
simply assert the divergence.

**Phase 10's two-abis check is vacuous here and the contract says so.** This
increment converts no raise-capable *exported* symbol: every one of `net.c`'s
raises is inside a cfunction, and a cfunction is an abi already.

### The suite goes from two assertions to forty-three

`test/suite-net.janet` had two, and one of them was `(assert true)`. The rest of
the `net/` surface was reached only by the forty-odd `net/` calls inside
`test/suite-ev.janet`, all of them TCP echo servers -- so the datagram path, the
option table, the address vocabulary, every failure message and the method
table had no Janet-level test at all.

It now has forty-three, including the datagram round trip, the unix domain
round trip, path truncation, and the method table read back in order through
`(seq [k :keys stream] k)`. Every one of them passes under both arms, which is
the rule the conventions state and the reason the suite was written against
`-Dnet-sockets=c` first.

### The differential corpus

`port/probe-14/net-surface.janet`, 94 observations over the whole surface --
every cfunction, every failure message, a TCP round trip both directly and
through `net/accept-loop`, a UDP round trip, a unix domain round trip, both
timeouts, and every call again on a closed stream. **The two implementations
are identical on every line.** Part 13's single difference was a stack-trace
source path; this probe reports through `protect`, so no path is printed.

Two things it normalises rather than avoids, on the trap `differential.sh`
warns about. A kernel-assigned port differs between runs of the *same* binary,
so nothing prints one -- what is printed is the host and whether the port is
positive. And three messages quote the stream they rejected, which an abstract
renders by address, so the probe scrubs hex runs.

One thing is deliberately absent, and its absence is the point:
`(net/connect :unix <long path> :stream <bindhost> <port>)` aborts the C
implementation, and a script that aborts stops early, which would report every
later line as missing. The short-path form of the same call is there and is the
one both arms answer.

### The matrix

**Fifty-four entries.** Fifty-three passed on the first run; the one failure
was an assertion this increment had just written -- `os/getpid` does not exist
in a `-Dprocesses=false` build, and an absent binding is a compile error rather
than a runtime one. That is the shape Part 12 met and Part 13 met again, and it
is why the entry exists.

Two entries are new and both were earned by this subject. `-Dipv6=false`
removes four rows from the socket option table and the `AF_INET6` arm of the
address decoder -- a quarter of `net_addr.zig`, and the only configuration that
compiles the `INET_ADDRSTRLEN` sizing of the decode buffer. Its cross-compiled
twin, `-Dtarget=x86_64-linux-musl -Dipv6=false`, is there because the first one
runs on a host whose `sockaddr_un` is 106 bytes and the second on one where it
is 110.

Both arms of `-Dnet-sockets` are full `zig build test` runs rather than
shallow, and so is `-Dev-loop=c`: a Zig socket layer on the C event loop is a
configuration nothing else builds, and it is the abi Phase 10's acceptance
list asks to be tested separately. `-Dargs-core=c` was promoted from shallow to
full for the same reason: the argument layer's raise is the `longjmp` that
keeps both of these sources jump-transparent, and a suite failure is how a
mistake there shows up. `-Dos-surface=c` went the other way, to shallow --
`os.c` builds streams and pipes, which mattered to Part 13 and does not to
this one.

### What it costs

Eleven workloads at `ReleaseFast`, minimums of twenty-five interleaved rounds,
run in both pairings, and the half-difference of the two orderings taken --
Part 13's correction, which removes the additive per-position bias.

| workload | C first | Zig first | real |
| --- | --- | --- | --- |
| `connects` | -11.2% | +7.5% | **-9.4%** |
| `echoes` | +2.9% | -1.4% | +2.2% |
| `unpacks` | +0.0% | -1.5% | +0.8% |
| `localnames` | +0.4% | -1.0% | +0.7% |
| `sockopts` | +0.9% | -0.5% | +0.7% |
| `addresses` | +0.8% | -0.2% | +0.5% |
| `sockopts-last` | +1.1% | +0.1% | +0.5% |
| `flushes` | -0.1% | +0.1% | -0.1% |
| `sockets` | -0.7% | +0.1% | -0.4% |
| `datagrams` | +0.2% | +1.0% | -0.4% |
| `fib` (control) | +7.5% | -4.6% | **+6.1%** |

**The control is the result.** `fib` is arithmetic and recursion and cannot
reach a socket, and it reads +6.1% after the correction -- larger than every
socket workload in the table. So the honest reading is that this corpus cannot
resolve anything below about six points on this machine, and nothing in it
except `connects` is outside that.

Run on its own, with nothing else in the process, the same control reads
**+3.1%**. Two things follow. Half of the six points is *position*: `fib` runs
last, after ten workloads that have left the heap and the collector in
different states in the two binaries, and Part 13's correction removes a bias
that is additive per position rather than one that comes from a different
starting state. The other half is **code layout** -- an object of this size
changes where `run_vm` lands, which is the effect Part 13 named and did not
have to quantify because its control came out at +0.25%.

That +3.1% is worth stating plainly rather than dismissing: this increment adds
about 39 kilobytes to `libjanet.a` at `ReleaseFast`, and on this machine that
is enough to move an unrelated interpreter loop by three percent in either
direction. It is not a cost of the port's *code*, and the way to tell is that
`connects` -- the workload with the most socket work per iteration -- moved the
other way.

What the corpus does establish is a negative and a useful one: **no socket
workload is measurably slower.** The three that are nearly pure cfunction
overhead over an open socket (`sockopts`, `sockopts-last`, `flushes`) are
within a point, which is what Part 1 predicts for a raise mechanism that
inlines; the three address workloads are within a point of that; and the three
that drive real traffic are dominated by the kernel.

## The file watcher

Phase 10 Part 15 moves `src/core/filewatch.c` into one Zig source behind one
new selector, `-Dfilewatch-core`: `filewatch_core.zig` holds the three
backends and the fourth that has none, the `filewatch/watcher` abstract type
and its mark callback, the flag decoder over `-Dfilewatch-flags`'
vocabularies, the five `filewatch/` cfunctions and `janet_lib_filewatch`.

**274 live lines go to eight, and the eight belong to the other selector.**
What stays is the platform ordinals, the compile-time assertion that pins them,
and the four `extern` declarations of the name lookups -- the half of one table
that `-Dfilewatch-flags` already owned. Nothing is left behind for this
increment's own sake: like `net.c` and unlike `ev.c`, this file opens no
protected scope, so there is no `setjmp` for a raise to be caught by and
nothing that has to survive until Part 17.

**Nine `janet_panic` call sites left C: 49 before this increment and 40
after.** `filewatch.c` now contributes none. `ffi.c` is the largest remaining
contributor at 27, and after it `fiber.c` at 7.

The phase-opening table records 839 live lines for this row against the 274
`panics.py`'s preprocessor gives on this host, and that is the seventh counting
difference this phase has recorded. Two things make it up rather than one. The
Linux and Windows backends are about half the file and no macOS preprocessor
takes either, which is the difference Part 14 met. The other half is new:
`JANET_CORE_FN` expands to a single output line, and the two docstrings in this
file are 74 and 21 source lines each, so a measure taken after the preprocessor
loses them. Both are the measure being what it is rather than being wrong; what
matters is that the same measure is used at both ends.

### One selector, and the count goes sixty-one to sixty-two

One source and one object, on `makeZigSubsystemObject`'s shape plus one extra
module. `-Dfilewatch-flags` is untouched and still means what it meant: this
object reaches all four name lookups across the C ABI exactly as `filewatch.c`
did, so `-Dfilewatch-flags=c` runs a Zig watcher over the C vocabularies and
the matrix builds it.

That split was made in Phase 10 Part 12 for a reason this increment is the
proof of. Every flag's *value* is a host constant -- `IN_ATTRIB`,
`FILE_NOTIFY_CHANGE_SIZE`, `NOTE_EXTEND` -- so the value tables have to sit
inside the backend that uses them and only one of the three compiles on any
target. A *name* is a string, so all three name tables compile everywhere.
Splitting the table down that line is what lets `test/filewatch_flags.c` assert
the Windows vocabulary on macOS, and it is the only part of this file that is
checked on a host that does not run it.

*The selector table above was three rows short when this increment started.*
`-Dev-loop` and `-Dnet-sockets` were added to the build in Parts 13 and 14 and
not to the index, so the table read fifty-nine where the prose read sixty-one.
All three rows are there now.

### Four backends, one compiled, and the fourth compiled anyway

The C original selects with an `#ifdef` chain and compiles exactly one arm:
inotify on Linux, `ReadDirectoryChangesW` on Windows, kqueue on the BSDs and
macOS, and for everything else a fourth whose every entry point raises
"filewatch not supported on this platform". The chain is a host fact, so it
stays in the preprocessor -- `filewatch_abi.h` reduces it to one integer and
`filewatch_abi.zig` to one enumeration -- and `const be = switch (backend)`
resolves at compile time. Zig analyses a container's declarations lazily, so
the arms this target does not select are not merely unreachable but unanalysed,
which is the same position C is in.

The fourth arm is the exception, and it is worth the six lines it takes:

```zig
comptime {
    if (backend != .none) {
        _ = &unsupported.decode;
        ...
    }
}
```

Nothing in it is host-specific -- seven functions that raise one message -- so
there is no reason for it to be the one implementation no configuration this
project builds ever compiles, which is what it is in C. A plain
`_ = unsupported` does not reach a function body; taking each function's
address does, and that was checked by breaking one on purpose and watching the
host build fail.

The arm was also *selected* once, by forcing `JANET_ZIG_WATCH_BACKEND` to
`NONE` in the header and building for the host. It compiles, and
`(filewatch/new (ev/chan 4))` answers "filewatch not supported on this
platform". That run is what found the one place the fourth backend would
otherwise have failed to build: `assertTableIsWhole` names `be.values`, which
does not exist in that arm, and Zig analyses both branches of a runtime `if`
however unreachable one of them is. The unwrap is `if (comptime be_platform)`
for that reason, and the comment there says so.

### The tree's fourth translation of host headers

`src/zig/filewatch_abi.h` joins `abi.zig`, `os_abi.h` and `net_abi.h`, and it
meets the rule `os_abi.h` states and `net_abi.h` repeats: a second translation
is right when nothing it declares crosses a subsystem boundary. Nothing here
does. A `struct inotify_event` is decoded inside one event callback, a `struct
kevent` is filled and passed to `kevent(2)` in one function, and a
`FILE_NOTIFY_INFORMATION` is read out of a buffer that belongs to the watch it
arrived for. The only things that outlive a call are a `JanetStream *` and a
`JanetChannel *`, and both come from `abi.zig`, which every Zig object shares.
Adding `<sys/inotify.h>` and `<sys/event.h>` to `abi.zig` would put a backend's
headers into the translation the whole tree shares, to serve one file.

Four spellings do not survive translation and are restated in
`filewatch_abi.zig`. `S_ISDIR` and `EV_SET` are function-like macros, which is
the shape `net_abi.zig` met in `_IOW`; `OVERLAPPED` and `JanetOverlapped` come
from `src/core/util.h`, which `abi.zig` deliberately does not translate and
which `ev_stream.zig` and `net_sockets.zig` restate for the same reason; and
`INVALID_HANDLE_VALUE` is a cast of -1 to a pointer that the mingw headers
render inconsistently.

The header also carries the aro correction that `os_abi.h`, `state_abi.h` and
`net_abi.h` all carry, and here it decides which backend the *translation*
selects rather than which structure a field is read out of. Without the three
`#undef`s, `janet.h` would report `JANET_POSIX` for `x86_64-windows-gnu` and
this file would translate the inotify arm for a Windows build.

### What the cross-compiles caught, for the sixth increment running

Two of the three backends are compiled by no host build, and the cross-compiles
are the only thing that compiles them at all -- which is exactly the position
`filewatch.c` is in, and the argument for the vocabulary split restated as a
build fact. Four faults, two in each arm, and the host caught none:

  - `@ptrCast` with no known result type, where the inotify decoder takes the
    name out of the read buffer. The host never analyses that line.
  - `janet_async_start_fiber`'s state parameter, which the inotify backend
    hands a `*?*anyopaque` -- the C original's "Gross" one-pointer allocation.
  - `janet_table_remove` returns a `Janet`, and the Windows backend discards it
    at two call sites. Zig refuses an ignored non-void value; C does not.
  - The same, in the completion callback's `JANET_ASYNC_EVENT_CLOSE` arm.

None of the four is deep and that is the point: they are the ordinary errors
anyone makes in code they cannot run, and without the matrix they would have
shipped into an arm nothing in this project compiles.

### Two defects reproduced, one that cannot be, and a fourth that hangs

Four entries for `FOUND.md`, and three of them were found by writing the port
rather than by running it.

**`filewatch/remove` retries a call that succeeded.** Both of
`janet_watcher_remove`'s retry loops are inverted -- `while (result != -1 &&
errno == EINTR)` -- so a stale `EINTR` in `errno` repeats a *successful*
`close(2)` or `inotify_rm_watch(2)`, and the second attempt fails and raises.
This is the same fault in the same shape as the one Part 13 found in
`janet_ev_init`'s kqueue arm, one file away. It is defined behaviour, so the
port reproduces it and `test/filewatch_core.c` pins it; the second `close(2)`
is the dangerous half, because in a threaded program the number may already
belong to something else.

**`filewatch/unlisten` leaves the watcher unusable.** It closes the watcher's
own descriptor -- the inotify instance, or the kqueue -- and sets `is_watching`
back to zero, so both `filewatch/listen` and `filewatch/add` will accept the
watcher afterwards and both are then working against a closed descriptor. `add`
raises; `listen` reports success, starts a fiber on a closed stream, delivers
nothing ever again, and holds the event loop open so the script may not exit.
This one was found by a probe that hung for two minutes, which is how the third
defect this phase has found by hanging arrived.

**The kqueue watcher never closes the descriptors it watches with.** One
`open(2)` per `filewatch/add`, closed only by `filewatch/remove`; fifty
watch-and-unwatch cycles leak fifty descriptors. Linux is not affected, because
an inotify watch belongs to the instance rather than to a descriptor of its
own.

**The kqueue watcher's cookie starts from uninitialised memory**, and this is
the one that cannot be reproduced. `janet_watcher_listen` allocates its state
with `janet_malloc` and sets one of the two fields; the callback's first act is
`state->cookie += 6700417`. Reading an uninitialised object is undefined, so
Phase 8's sixth rule applies -- nothing pins it, and the port starts from zero.
The two happen to agree on this host, where the allocation comes back zeroed,
and `port/probe-15/filewatch-surface.janet` prints every other key of an event
and not this one.

### What the contract is for, and what only it can reach

`test/filewatch_core.c` has twenty-seven raises checked by their message and
about sixty assertions. Five things have no Janet spelling at all.

**The abstract type's callback set.** `JANET_ATEND_GCMARK` means a mark
callback and nothing else, and that the `get`, `put`, `marshal`, `unmarshal`,
`tostring`, `compare`, `hash`, `next`, `call`, `length` and `bytes` slots are
all null is what makes a watcher opaque. From Janet only the name is visible.

**The mark callback on an incompletely initialised watcher.** `janet_abstract`
does not zero and `janet_watcher_init` fills the structure field by field, so
`janet_filewatch_mark` opens by asking whether the channel is set. Nothing in
Janet can hand the collector a watcher in that state; a `memset` and a
`janet_abstract` can.

**A stale `errno`**, which is what the first `FOUND.md` entry above needs and
which no Janet program can arrange across a cfunction entry.

**The two halves of the flag table.** Only C can ask the name lookup and the
value decoder the same question and compare the answers, which the contract
does for every row of this platform's vocabulary and then for every row of
another platform's that this one does not share.

**A `janet_gcroot` the language gives for free.** This is the trap the contract
hit on its first run, and it is worth recording because it is not about
`filewatch.c` at all: a `Janet` in a C local is *not* a root. The collector
scans the VM and the fiber stacks, and a cfunction's arguments are on one of
those, so a Janet caller never has to think about it. A contract that holds a
watcher across an allocation does, and the symptom is not a crash but a later
call failing on a descriptor the test still believes it owns -- "failed to
listen: Bad file descriptor", three calls away from the collection that caused
it.

**Phase 10's two-abis check is vacuous for this increment**, as it was for
Part 14, and the contract says so: every raise here is inside a cfunction, and
a cfunction is an abi already. `Abi(...).cfun` catches the error and calls
`raise.deliverToC()`, so calling the registered cfunction pointer -- which is
what `call_core` does -- is the abi, and there is no second one to drift
from it.

### The suite goes from twenty-three assertions to forty-nine

`test/suite-filewatch.janet` opened with `(assert true)`, a GC check, and then
went straight to driving real events over a real directory. That is the half
that matters and it was the only half there was: every failure message in the
file, every arity, the flag vocabulary, the watcher's type and the whole shape
of its life had no Janet-level test at all.

Twenty-six assertions were added before the event tests, on a directory of
their own, and they were written against `-Dfilewatch-core=c` first, on the
rule at the end of `AGENTS.md`. Three of them needed the answer looking up
rather than guessing: `(get watcher :stream)` returns nil rather than raising,
because an abstract with no `get` callback answers nil; `(< watcher watcher)`
does not raise either, because two abstracts compare by address; and the
backend word in "unknown %s flag" is the one part of that message that differs
between platforms, so the suite computes it from `(os/which)` the way the rest
of the file already does.

### The differential corpus

`port/probe-15/filewatch-surface.janet`, run under both arms and diffed:
**identical over 92 lines of output**, covering the registration, every arity
and argument fault, every flag-decoding message, all forty rows of the three
vocabularies asked of this host, the watcher's type and printed form, the life
cycle and one round of real events.

Four things are normalised rather than avoided. The watcher and the channel are
abstracts, which render by address; `:wd` is a watch descriptor on Linux and a
file descriptor on the BSDs and neither is stable; the directory is a fixed
name rather than `randdir`'s, so the two runs watch the same path; and
`:cookie` is left out for the reason the fourth `FOUND.md` entry gives.

### The matrix

Fifty-two entries. Two are new and both were earned. `-Dfilewatch-flags=c` is
a Zig watcher over the C vocabularies -- the configuration that proves the
index one half of the table reports still selects the value the other half
holds -- and its cross-compiled twin on `x86_64-linux-musl` puts the same
question to the four `extern` declarations on a second platform, where the
inotify backend is the one being linked.

Two entries changed shape rather than being added. `-Dgc-mark=c` moved from
shallow to full, because the watcher's whole reason to be an abstract is its
mark callback and the event callback marks as well; `-Dfilewatch=false` moved
from shallow to full, because it compiles this entire object out and what it
asks is whether anything else in the tree still reaches for it. Unlike Part
14's `-Dnet=false`, that entry needs no `skip`: the contract names no symbol of
this object's, so its outer `#if defined(JANET_EV) && defined(JANET_FILEWATCH)`
reduces it to one line of output instead.

**Fifty-one passed on the first run, and the one failure was a real defect in
this increment's code** -- the first time this phase the matrix rather than a
cross-compile or a contract has caught one. `-Dnanbox=false` reported
`undefined symbol: _janet_wrap_integer`: `janet.h` declares the function beside
the macro, `wrap.c` defines it only for the two nanbox layouts, and a tagged
build therefore has the declaration and no symbol. Nine subsystems have met
this and each writes the call out as `janet_wrap_number(@floatFromInt(x))`;
this is the tenth. Re-running the four affected entries after the fix passed
all four.

### What it costs

Six workloads and a control at `ReleaseFast`, minimums of twenty-five
interleaved rounds, run in both pairings, and the half-difference of the two
orderings taken -- Part 13's correction, which removes the additive
per-position bias.

| workload | C first | Zig first | real |
| --- | --- | --- | --- |
| `addremoves` | +1.6% | -0.7% | +1.2% |
| `flaghit` | +1.0% | -1.1% | +1.1% |
| `flagmiss` | +1.2% | -0.3% | +0.8% |
| `watcherflags` | -0.3% | -0.0% | -0.2% |
| `watchers` | +0.0% | +0.8% | -0.4% |
| `events` | -3.8% | -0.5% | -1.7% |
| `fib` (control) | -3.4% | +4.5% | **-4.0%** |

**The control is the result, for the second increment running.** `fib` is
arithmetic and recursion and cannot reach a file watcher, and it reads -4.0%
after the correction -- larger in magnitude than every real workload in the
table. So this corpus cannot resolve anything below about four points on this
machine, and nothing in it is outside that.

This increment adds about **23 kilobytes** to `libjanet.a` at `ReleaseFast`,
against Part 14's 39, and that is enough to move an unrelated interpreter loop
by four percent. Part 14 measured the same effect with the opposite sign and
named it; this is the confirmation, and the useful part of the confirmation is
that the sign is arbitrary. Code layout is not a cost of the port's *code*, and
a corpus whose control moves further than its subject cannot say anything about
the subject.

What the corpus does establish is a negative and a useful one: **no watcher
workload is measurably slower.** `flagmiss` and `flaghit` are nearly pure
cfunction overhead -- an argument check, a linear scan across the C ABI into
`-Dfilewatch-flags`, and a raise -- and they read +0.8% and +1.1%, which is
what Part 1 predicts for a raise mechanism that inlines. `watchers` and
`watcherflags` build a real watcher each iteration and are inside a point.
`addremoves` and `events` reach the kernel and are dominated by it.

The corpus is also smaller than Part 14's for a reason worth stating: **there
is very little of this subsystem a program can run in a tight loop.** A watcher
costs a descriptor, `filewatch/add` leaks one (see `FOUND.md`), and everything
else waits on the kernel. `flagmiss` and `flaghit` exist because the decoder is
the one part that is pure computation, and they reach it through the raise
rather than through a successful `filewatch/new` precisely so that no
descriptor is opened.


## The FFI

Phase 10 Part 16 moves the rest of `src/core/ffi.c` into four Zig sources
behind one new selector, `-Dffi-core`. `ffi_core.zig`, `ffi_types.zig`,
`ffi_marshal.zig` and `ffi_call.zig` are the third and last increment inside
that file and take everything the first two left: the machine-type
representation, the four abstract types, the marshaller, all three
conventions' calling machinery, the callback trampolines, the JIT's executable
pages and the seventeen `ffi/` cfunctions. **965 live lines go to 110**, and
the 110 that stay are the shared vocabulary the other two selectors need --
three enumerations, the flat node and slot forms their kernels speak, and the
two compile-time assertions that pin the ordinals. `ffi.c` now contributes no
`janet_panic` call site; **27 left C, 40 before this increment and 13 after**,
which is the largest single drop this phase and leaves `fiber.c` as the last
substantial contributor at seven.

**One selector over four sources, on the `-Dev-loop` precedent rather than the
`-Dos-surface` one -- and then the other way round.** `ev.c`'s 3812 lines became
one selector because a C-ABI seam between its parts would have turned every
internal raise into a jump; the same argument applies here and more sharply,
because `ffi.c` was the densest remaining raise site in the tree. But where
`ev.c` needed *file* imports for a cyclic graph, this one is a directed acyclic
graph and uses four modules: `ffi_core.zig` registers and needs the other
three, `ffi_call.zig` reaches `ffi_marshal.zig` to place each argument, and both
reach `ffi_types.zig`. Nothing goes back.

`-Dffi-layout` and `-Dffi-classify` are untouched and still mean what they
meant. Their kernels are reached across the C ABI exactly as `ffi.c` reached
them, so `-Dffi-layout=c` runs a C struct-layout machine under a Zig type
system and `-Dffi-classify=c` a C register classifier under a Zig caller. The
count goes sixty-two to sixty-three.

**A rule from those two increments expired here, and saying which is the
point.** Both were written under the constraint that `JanetFFIType` carries a
pointer into a garbage-collected abstract, so Zig had to be kept away from it
and C dispatched on the type and passed the resulting scalars. The roots are
Zig's now -- this increment defines both abstract types and their mark
callbacks -- so the pointer stays inside one language again and `typeSize` and
`typeAlign` are three lines each. What did *not* expire is the flat
`JanetFFITypeNode` form: a classifier is still reached across a selector seam,
so a type is still serialized into scratch before it crosses. Phase 9's second
rule, that a closed decision expires when the rule it rested on is replaced,
applied for the second time.

### There is no `alloca`, and that decided the shape

`SPIKE-16.md` is the long answer and `port/probe-16/call/` the evidence. The
short version: `janet_ffi_sysv64` writes its stack-class arguments into an
`alloca` block and then calls a function pointer declared with the *register*
arguments only, relying on the block sitting exactly where the callee will
look. `janet_ffi_win64` makes the coupling explicit -- it shifts the block down
two words and admits in a comment to writing "into 16 bytes of unallocated
stack memory". Zig has no `alloca` and a fixed-size local is not guaranteed to
sit at the outgoing-argument position.

So the placement comes from the ABI's own rules instead: the stack words are
declared as ordinary trailing parameters and the compiler puts them where they
go. Zig 0.16 splits `@Type` into `@Fn`, `@Struct`, `@Union` and `@Enum`, and
`@Fn` builds the type at comptime from a parameter list; `@call` with
`std.meta.ArgsTuple` fills it. The probe establishes that passing more words
than the callee reads is invisible, and that `u64` parameters -- eight bytes at
eight-byte alignment -- reproduce Apple's AAPCS64 byte packing as well as
everyone else's word rounding, so one word type serves all three conventions.

Three things follow, and each is a real difference from the C.

  - **A rung ladder.** `@Fn` needs a comptime parameter count, so the outgoing
    word count is rounded up to a power of two and every rung is instantiated.
    The ladders are per-convention because the conventions differ in what they
    can generate: SysV64 passes large aggregates by value on the stack and gets
    twelve rungs to 1024 words, while Win64 and AAPCS64 pass anything large by
    reference and cannot exceed about 128 words with `JANET_FFI_MAX_ARGS` at
    32.
  - **A frame that outlives the call.** `JANET_WIN64_STACK_REF` and
    `JANET_AAPCS64_GENERAL_REF` store a *pointer* to a payload the caller
    wrote, and the outgoing area has no address until the call is under way.
    So the frame is ordinary scratch with the offsets the allocators already
    compute, the references point into it, and only its outgoing prefix becomes
    arguments -- which needed `arg_stack_count`, a new field on
    `JanetFFIAllocResult` reported by both arms of `-Dffi-classify`. The callee
    receives a copy of that prefix holding pointers into the live original,
    which is what `alloca` gave C for free. `win64`'s `- stack_shift * 8`
    adjustment dies with the `memmove` it was compensating for.
  - **A ceiling, which is this increment's own and has no C original.** 1024
    words. Past it `ffi/signature` raises, at description time rather than on
    every call. A rung costs superlinearly to compile -- 8KB adds about a
    second and 32KB adds twenty-one, against a fourteen-second build -- and
    only SysV64 can reach it, and only with a single struct passed by value.
    C's behaviour there is an `alloca` of the same size, fine at 8KB and a
    stack overflow somewhere above it; an overflowing `alloca` is undefined, so
    there is nothing to reproduce.

The rejected alternative is worth recording because it explains why the ceiling
exists. One `extern struct` parameter instead of N words would make the ceiling
free: on SysV a struct that size is classified MEMORY and pushed onto the
outgoing area, so one parameter stands in for a whole rung. It works on
`x86_64-macos` and fails on `aarch64-macos`, because AAPCS64 passes large
aggregates *by reference* -- the one convention where the cheap mechanism works
is the one that needs a large ceiling. Taking it would mean two placement
mechanisms for a ceiling nothing reaches.

### SysV64 is executed here for the first time

Part 12 recorded that "the AAPCS64 path is exercised by real calls on the
development host; the SysV path is not, since nothing on this machine can call
it", and that "end-to-end SysV calls remain unvalidated here". That is no
longer true. An `x86_64-macos` build runs under Rosetta on Apple silicon, so
the whole runtime -- suites, contracts and real FFI calls -- executes a second
calling convention, and `zig build test` drives it. Two matrix entries do this
and `port/probe-16/abi/run.sh` does the differential.

`port/probe-16/abi/` is that differential: a shared library of deliberately
awkward signatures -- register exhaustion in each bank and both, integers
narrower than a register, aggregates on both sides of every by-value threshold,
homogeneous float aggregates, the three return shapes, and a by-reference
return competing with a full register file -- each folding its arguments into
one position-weighted number, so a misplaced argument is a wrong number rather
than a crash. Twenty-seven observations across four builds, one of which is the
callback trampoline end to end -- `ffi/trampoline` hands out a pointer with one
fixed signature and nothing in libc is shaped for it, so that path had no
coverage anywhere before this increment.

**On SysV64 the two implementations are identical on every line but one**, and
that one is the ceiling. **On AAPCS64 they differ on one line too**, and that
one is `hfa2`, where C reads a vector register its allocator never wrote: it
answers 1 four times and 123223 on the fifth, and the port answers 1 every
time.

### Two defects found, and one recorded rather than reproduced

**AAPCS64 reads a by-reference argument's slot at eight times its offset.** The
allocator measures this convention's stack in bytes and
`JANET_AAPCS64_STACK_REF` reads `(uint64_t *) stack + arg.offset`, which
addresses byte `8 * arg.offset`. Every other arm of the same `switch` treats
that field as bytes, including the `JANET_AAPCS64_STACK` case three lines
above. The pointer lands past the `alloca` block, the callee reads zero, and
dereferencing it segfaults.

It hides behind an accident: the offset is only wrong when it is nonzero, and
the *first* stack argument is at offset zero, where `8 * 0` and `0` agree. So
an aggregate that is the first thing to land on the stack works and one with
any stack argument ahead of it crashes -- which is why the corpus has both, and
why `large_after_stack_arg` puts nine integers ahead of a 24-byte struct. Both
implementations now crash at the same instruction on the same input. Where C's
write leaves its block and lands in the caller's frame, which is undefined and
not something a port can imitate exactly, `aapcs64FrameBytes` grows the frame
to cover it so the wrong slot is written inside memory the call owns.

**The argument registers are read before they are written.** All three
conventions declare `uint64_t regs[6]` and `double fp_regs[8]` uninitialized
and then write each argument at its own width, so every byte the argument does
not fill reaches the callee as stack residue. This is the existing "integer
arguments narrower than a register" entry seen from the other side, and it has
a second reachable form: AAPCS64 sizes a homogeneous float aggregate by bytes
rather than by members, so a two-float HFA is given one vector register where
the ABI wants two, and the second is never written at all. Reading
uninitialized memory is undefined rather than merely wrong, so this phase's
rule is to record and get it right -- the same footing as Part 8's `%x` entry.
Both banks and the frame are zeroed, which is the one AAPCS64 differential
difference and the direction of it is that the port is deterministic where C is
not. It does not fix the allocator defect underneath, which is a separate
decision.

### The contract, and what only it can reach

Twenty-eight assertions and fifteen raises checked by their message, over six
things with no Janet spelling. The primitive size and alignment table is the
first and the most valuable: `janet_ffi_type_info` is built from the host's
`sizeof` and an `alignof` macro and the port restates it with `@sizeOf` and
`@alignOf`, so all thirty-six names are checked against the real C type, which
is the same argument `test/ffi_layout.c` makes for the layout machine. Then the
four abstract types' callback sets, where from Janet only the name is visible;
`janet_ffi_trampoline` with a null `userdata`, which a C library calling back
can never produce; the outgoing/frame split, which nothing in Janet can
observe; and the ceiling, asserted on the allocator rather than on a call this
host could make.

**Phase 10's two-abis check is vacuous for this increment**, as it was for
Parts 14 and 15: every raise is inside a cfunction and a cfunction is an abi
already. `janet_ffi_trampoline` is the one exported non-cfunction and does not
raise on its own account.

### What the rest of the instruments say
**Forty-eight matrix entries, all passing.** Nine are new. Two of them run
under Rosetta and are the only entries that execute a second calling
convention; `-Ddynamic-modules=false` caught this increment's own contract
assuming a native object a build without dynamic modules cannot have; and the
three combinations of `-Dffi-layout` and `-Dffi-classify` are what prove a Zig
caller still drives C kernels across the seam. An earlier run of the same
matrix reported one entry FLAKY, having met the `suite-ev` park recorded in
`FOUND.md`; that is nothing to do with the FFI, and the harness now reports it
rather than wedging on it.

**`image-diff.py` differs only in source paths** -- `core/ffi.c` out,
`subsystems/ffi_core.zig` in. That is the check on the seventeen docstrings
this increment retyped, because a wrong character would show up there as a
string present in one image and absent from the other.

**The differential over the type system finds nothing**: 205 observations,
identical. It runs at `ReleaseFast` for the same reason the layout increment's
corpus does -- a packed field is written through a misaligned pointer, so the
sanitizer aborts the C arm inside `ffi/write` before it can print a line.

**The benchmark corpus found two allocations and then stopped resolving
anything.** Eight workloads and a control at `ReleaseFast`, twenty-five
interleaved rounds in both pairings, half-difference taken.

The first run read **+39.5%** on `callreg` -- a call whose arguments all fit in
registers -- against a control of **-11.0%**. Both were the finding.
`Frame.init` called `janet_smalloc` on every call, including the common one
that needs no frame at all: a `janet_malloc`, a push onto the scratch table,
and later a *linear scan* of that table to find the block, where C's
`alloca(0)` did nothing. Removing that took `callreg` to +3.1% and the control
to **+0.2%** -- and the control mattered more, because an eleven-point floor
had been hiding everything beneath it.

With single digits resolvable, two more allocations of the same shape showed
up: the frame on any call with stack arguments, and `classify`'s node array,
which `ffi/signature` pays *per argument*. Both now take a fixed on-stack
buffer with a scratch fallback -- 512 bytes and 32 nodes, sized so that only a
signature nobody writes reaches the allocator. Final numbers: `callreg`
**+1.2%**, `callstack` **+1.2%** where it had been +17.7%, and `signatures`
**-25.5%** -- the port faster than C, not merely recovered, because
`ffi_classify` in C still allocates once per argument.

What remains is at or near the floor: `sizemiss` +1.4%, `writes` +3.0%,
`reads` +5.5%, `structs` +6.4%, against a control of +3.5%. **`sizes` read
+10.3%, +5.8% and +13.3% across three runs of the same corpus**, which is code
layout rather than a property of the code -- the effect Parts 14 and 15 both
measured, here large enough to swamp the workload it is attached to.

The sequence is the lesson worth keeping: **the control is the measurement.**
The first run's real result was not +39.5% on one workload, it was that the
corpus could not resolve anything, and the fix that made `callreg` fast is also
what made every other number mean something.

## One module, and the seam that was a link boundary

Phase 10 Part 17a. The first of the six parts the hinge turned out to need, and
the one that makes the other five possible: **every Zig subsystem this
configuration answers is now one translation unit.**

### Module, compilation, object — three things C spells one way

Worth stating before the rest, because "translation unit" is C's word and does
not fit. A Zig **module** is a root file plus everything it reaches by relative
`@import("foo.zig")`: a namespace and a settings scope, not a compile barrier.
A **compilation** is one `zig build-obj` run, and it can hold several modules.
This one holds eight — the root, `abi`, `raise`, `corefn`, `options` and the
three host-header translations — in a single invocation:

```text
zig build-obj --dep abi --dep options --dep raise --dep corefn --dep os_abi ...
  -Mroot=src/zig/subsystems/root.zig  -Mabi=src/zig/abi.zig
  -Mraise=src/zig/raise.zig  -Mcorefn=src/zig/corefn.zig  ...
```

So the modules did not go away and were never the obstacle. The tree proved
that before this part existed: `raise.Error` is declared in the `raise` module
and `vm_calls.zig` has always written `raise.Error!c.Janet` across the import.
The compiler sees through a module the way it sees through a file.

| | modules | compilations | objects |
| --- | --- | --- | --- |
| before | ~4 per object — subsystem, `abi`, `raise`, `corefn` — times 63 | 63 | 63 |
| after | 8 | 1 | 1 |

The middle column is what changed, and the third column is where the 181 MB
came from: `abi.zig`'s translation was compiled fresh into each of the
sixty-three, because each was its own compilation.

### The rule that held for thirteen increments, and what it rested on

Part 4 established it and every increment after quoted it: *an error union
cannot cross a subsystem seam, because a selector's seam is the C ABI.* It is
true, and it shaped a great deal of the tree — the status codes `fiber.c`
turned back into panics, the `kind` enum `emit.c` squeezed five shapes through,
the two-abis pattern, the `_extern.zig` shims.

What went unexamined is *why* there was a seam. Each of the sixty-three
selectors was its own `b.addObject` — its own *compilation*, not merely its own
module — so a call from one subsystem to another was resolved by the linker, so
it was a C-ABI call, and Zig says what it says about those:

```text
error: return type 'error{X}!i32' not allowed in function with calling
convention 'aarch64_aapcs_darwin'
```

The seam was a consequence of one line in `build.zig`, not a fact about Zig.
Thirteen increments read it as the second, because it had never been the thing
under examination — and this is the entry `PLAN.md`'s ninth rule generalises:
a rule that has held across many increments is the one least likely to be
re-examined, and its premise is what to check.

Part 17 forced the check, because it cannot be done otherwise. Deleting the
third `setjmp` means no raise that can reach it is still a jump, and when this
part opened there were on the order of a thousand crossings that were —
`janet_fixarity` at 154 sites, `janet_arity` at 113, `janet_getbytes` at 42,
`janet_getcstring` at 35, 729 in the argument layer alone. Every one of them
was Zig calling Zig through a C-ABI symbol.

### What replaced sixty-three objects

`src/zig/subsystems/root.zig`, which imports the subsystems this configuration
selected and nothing else, and `makeZigRuntimeObject`, which builds it. The
selectors did not go away and their meanings did not change; what changed is
where they are answered. `build.zig` computes a `Selection` — one bool per
selector, the same expressions as before — and that single value is read twice:
by `addRuntimeSources`, which defines the `JANET_ZIG_*` macro that guards the C
original off, and by `@import("options")` in the root, which decides what to
import. They were two lists before and could disagree; a subsystem could be
compiled without being guarded off, or the reverse.

Three source-level imports became comptime choices for the same reason. The
loop's `vm_calls` and `value_wrap`, and now `fiber_core`, pick between the
subsystem and an `_extern.zig` shim:

```zig
const fiber_core = if (options.fiber_core)
    @import("fiber_core.zig") else @import("fiber_core_extern.zig");
```

`build.zig` used to make that choice by naming a file. It cannot any more —
there is one module, so both files are reachable from it — and a comptime-false
branch is not analysed, which is what keeps the unselected shim out of the
build.

**Six special constructors went with it.** `makeVmRunObject`, `makePpObject`,
`makeOsSurfaceObject`, `makeFfiCoreObject`, `makeEvLoopObject` and
`makeNetSocketsObject` each existed to fold *some* modules together so a
`raise.Error` could cross between them — the printer's three layers, the OS
surface's four files, the FFI's four. Folding is the default now and there is
nothing left to arrange: the import graph lives in the sources.

`build.zig` is 795 lines shorter for it: 1,230 removed against 435 added. Most
of what went was the `RuntimeSubsystems` struct, the sixty-three-arm
`makeSubsystems` literal, and six near-identical constructors that each rebuilt
`abi`, `raise` and `corefn` for their own object.

### The proof, and why it was `fiber.c`

An architecture change wants a case that exercises it end to end, and
`fiber.c`'s remainder was the clearest instance in the tree of C that exists
only to hold a raise:

```c
int janet_zig_fiber_push(JanetFiber *fiber, const Janet *x);

void janet_fiber_push(JanetFiber *fiber, Janet x) {
    if (janet_zig_fiber_push(fiber, &x)) janet_panic("stack overflow");
}
```

Four of those, over four Zig kernels that had been reporting a nonzero status
because they could not raise one. They raise now — `raise.panic("stack
overflow")`, returned — and `run_vm` reaches them as `try fiber_core.push(...)`
where it used to go through `scoped`, the trampoline's `setjmp` wrapper. That
is the first raise in the runtime to cross what used to be a selector boundary
as a value.

The second boundary in this file's header went with it. `make_struct_n` and the
varargs fill were in `fiber.c` because packing a variadic tail calls
`janet_struct_put`, which hashes the caller's keys, which runs an abstract
type's `hash` callback, which can panic. They are here now, so
`janet_fiber_funcframe` and `janet_fiber_funcframe_tail` are whole again
instead of a kernel in two halves with a C packing step between them. Neither
*raises* — an arity mismatch is still reported as 1, which is what `run_vm`
branches on — but both can be jumped *through*, so `fiber_core.zig` carries
`//! jump-transparent` now and `build.zig` checks it like any other source.

`fiber.c` loses 51 live lines and four of its seven panic sites. The tree's
`janet_panic` count compiled into C goes **13 to 9**.

### Both abis, and a hole that predated the change

Phase 10's acceptance list says the abi and the Zig implementation of a converted
symbol are tested separately, and here neither had ever been tested at all.
The overflow guard fires when `stacktop` reaches `INT32_MAX`, which honestly
needs a sixteen-gigabyte fiber stack, so nothing in the tree — not
`test/fiber_core.c`, not a suite — had ever observed a "stack overflow" from
any of the four pushes in either implementation. The mechanism changed
underneath a raise nothing was watching.

Setting `stacktop` by hand reaches it in a few instructions, and it is safe
because all four check their bound *before* touching `fiber->data`: the raise
happens without a single write through the poisoned top. Each push has its own
bound and they are off by one from each other, so the four are tested at four
values rather than at a common one.

The Zig implementation needed a different route, because it is reachable only through
`run_vm`. `JOP_PUSH_ARRAY` is the one push whose count comes from a value
rather than from the instruction, so an array claiming `INT32_MAX` elements
drives `pushn` past its bound from inside the loop. Nothing dereferences the
claim — `janet_indexed_view` copies the pointer and the count, and `pushn`
checks the count first — but the collector would, so the array exists only
inside a `janet_gclock`, and the lock is released by `janet_restore` on the
unwind exactly as `janet_call`'s is. What that observes and the C-abi test
cannot: the raise leaves `run_vm`'s Zig frame as a returned error, crosses the
loop, and arrives at `janet_pcall` as a signal. Before this part there was no
such path.

Both assertions were checked against a mutant — `pushn`'s bound replaced with
`if (false)` — and both fail without it. The contract passes under
`-Dfiber-core=c` as well, which is the convention: verify against the C
selector before trusting it against Zig.

### What the fold cost, which was nothing, and what it gave back

`ReleaseFast` is where the shipping artifact lives and it did not move:
1,580,152 bytes to 1,583,928, **+0.24%**. Nothing here is a code-generation
result, and no benchmark claim is made — the corpus is Part 17b's business,
once there is a converted call site hot enough to measure.

The build is a different story, and the cause is one thing: each of the
sixty-three objects carried its own copy of `abi.zig`'s translation, with its
debug info.

| | 63 objects | one object |
| --- | --- | --- |
| cold `zig build` | 15.7s | 7.6s |
| CPU for that build | 69.3s | 16.4s |
| `libjanet.a` | 181 MB | 7.8 MB |
| `janet`, Debug | 89.3 MB | 6.0 MB |
| `.zig-cache` for one configuration | 965 MB | 98 MB |

The last row is the one that matters most, and `AGENTS.md` has a section about
why: the cache is never garbage collected, every distinct configuration
deposits a full object set, and differential testing and mutation sweeps have
twice filled the disk. An order of magnitude off the per-configuration cost is
worth more than it looks.

### The differential, and what it had to be built around

`port/probe-17/fiber-pushes.janet`, sixty lines of output, **identical** across
`-Dfiber-core=c` and `-Dfiber-core=zig`. It drives the four pushes by varying a
call's arity from zero to eleven, `JOP_PUSH_ARRAY` by splicing arrays of six
lengths, and both funcframes through fixed, optional, variadic and `&keys`
callees in both the ordinary and the tail-call order — the last of which is the
half that changed languages, since `make_struct_n` moved here with it.

One thing had to be worked around and it is worth knowing before writing
another corpus on this path. **Janet's compiler checks the arity of a call
whose callee it can see**, so `(fixed2 1)` is a compile error and never reaches
`janet_fiber_funcframe` at all — the arm the corpus exists to exercise. Every
refusal therefore goes through a helper that takes the function as a parameter:

```janet
(defn- indirect [f & args] (protect (f ;args)))
```

The second trap was self-inflicted and cost a run: a loop enumerating tail-call
shapes from zero included a zero-argument call to a callee needing one, which
raised outside any `protect` and stopped the script. `differential.sh`'s header
warns about exactly this — an aborting script reports every later line as
missing — and it is worth reading the *first* diverging line rather than the
count.

### The benchmark corpus

The Phase 9 corpus at `ReleaseFast`, interleaved, five rounds, both pairings.
The control is `pegmatch`, at **-0.3%** and **+0.2%**.

| workload | fold vs HEAD | HEAD vs fold |
| --- | --- | --- |
| arithmetic | -0.3% | -0.2% |
| fib | +0.0% | +2.1% |
| methods | +0.2% | -0.2% |
| tables | -1.0% | -1.1% |
| strings | +1.1% | +1.1% |
| compiler | +0.3% | -0.3% |
| pegmatch *(control)* | -0.3% | +0.2% |
| opfallback | +1.0% | +0.1% |
| pegcall | +0.2% | -0.7% |
| fibers | -0.2% | +0.0% |

Every workload sits inside ±1.1% but one, and `fib`'s +2.1% appears in one
pairing and +0.0% in the other, so by this project's rule for a noisy machine
it is not a reading. `strings` is the instructive one: it reads +1.1% in *both*
pairings, which means the second run says the opposite of the first — that is
what a symmetric measurement looks like when the effect is zero.

**The honest statement is that the fold costs nothing measurable, and gains
nothing measurable either.** The second half is the interesting one, because
folding sixty-three objects into one lets the optimizer inline across
boundaries it could not before, and Part 2 measured that boundary at 89% on
arithmetic in the other direction. The reason it does not show up is that the
two subsystems on the hot path — `vm_calls.zig` and `value_wrap.zig` — were
*already* folded into the loop's object by Part 3, for exactly that reason. The
seams this part removed were the cold ones. What it bought is not speed; it is
that a raise can cross them.

### The matrix

Forty-nine configurations, and the entries are different in kind from every
part before this one. Those matrices asked whether one new subsystem behaved
under every configuration; this one asks whether *every* subsystem still does,
because what changed is how all of them are compiled and linked. The failure
modes are a missing symbol, a duplicate one, and an arm no configuration
imports any more — none of which the default build can see.

So: the default and every selector `c`, which are the all-on and all-off
corners; all four optimize modes; both arms of `-Dfiber-core`; the three
selectors the sources now resolve themselves; the rest of the interpreter's
selectors; one from each other layer; `-Dboot=zig`, which is the second folded
object; the eleven feature gates that decide whether a subsystem is imported at
all; `x86_64-macos` under Rosetta; and the four cross-compiles, which matter
more here than usual because the fold changed which files are analysed
together.

## The argument layer, and 656 crossings

Phase 10 Part 17b. The second of the hinge's six parts, and the one that
converts the largest single population of jumps in the tree.

### Why this layer first

Every cfunction in the runtime opens the same way: an arity check, then a
getter per argument. `janet_fixarity` had 154 call sites, `janet_arity` 113,
`janet_getbytes` 42, `janet_getcstring` 35 — 656 in all, spread over
twenty-eight subsystems. Until this part every one of them was a C-ABI call
that raised by `longjmp`, and each is a customer of the third `setjmp`.

The layer was ready for it and had been since Part 5. Every getter has had two
abis — a `raise.Raising(T)` implementation and a `raise.panicking` wrapper
under the public C name — and the implementations were `private` only because
nothing outside `args_core.zig` could reach them: a subsystem in another
*compilation* had the symbol table and nothing else. Part 17a removed that.
This part is mostly the consequence.

### Three pieces of machinery, then a sweep

**`raise.declared`, the inverse of `raise.panicking`.** It puts the Zig
signature on a C symbol that raises by jumping:

```zig
pub const getString = raise.declared(c.janet_getstring).call;
```

The error is declared and never returned — the C body jumps from the inside, so
the Zig frame that called it is jumped through rather than returned to. That is
what lets `-Dargs-core=c` go on answering after its callers have converted, and
it is what `args_core_extern.zig` is made of. The signature is *derived* from
the C declaration rather than restated: sixty-odd declarations that must match
`janet.h` exactly are sixty-odd chances to drift, and a drifted one is a silent
ABI mismatch rather than a compile error. That is `panicking`'s own argument,
from the other side.

**`arglayer.zig`, the façade.** One file that picks between the implementation
and the shim on the selector, rather than twenty-eight copies of the same
two-line conditional import. `vm_run.zig` resolves `vm_calls` and `value_wrap`
at its own head, which is right for two importers and wrong for twenty-eight.

It cannot be a *module* in `build.zig`'s sense, which would be the obvious
answer: `args_core.zig` is already in the root module — the root imports it for
its `export`s — and a second module instance over the same file would compile
it twice and define every `janet_get*` twice. One module, one instance, and the
façade is a plain re-export inside it.

**`port/convert.py`, the sweep.** Three stages: rewrite the crossings, split any
C-ABI function that now raises into an `Impl` and an abi, then follow the error
union outward by reading `zig build`'s own diagnostics. It is a working file
rather than a scratch script because Parts 17c, 17d and 17e do the same job to
different layers, and its header records the three ways it gets things wrong.

The result: 656 call sites converted, **zero** argument-layer crossings left,
and 232 abis where there were 83.

### What the conversion being *checked* actually bought

`PLAN.md`'s fifth decision rests on a claim that the fold makes the conversion
compiler-enforced, where the alternative — an out-of-band flag — would make a
forgotten check a silent read of a garbage value. This part is the first
evidence, and it is better evidence than expected.

The tooling got it wrong about a dozen times, always the same way: a `try`
landed on a *use* rather than on the initialiser that produced the error union.
`var state = findsetup(...)` followed by `state.next()` reports the use, because
that is where the type is wrong, and stage 3 cannot see the declaration from
the diagnostic. Every one of those produced a compile error — either a `try` on
something that is not an error union, or an unconverted declaration whose next
use failed the same way. **Not one of them could have reached a running
binary.** Under the flag scheme each would have been a live read of an
uninitialised value, in exactly the place a `longjmp` had been safe.

The same is true of the two `try`s that were wrong in *kind* rather than in
placement: `c.janet_stream_flags` is an event-loop crossing, not an
argument-layer one, and it belongs to Part 17d. It reached the sweep because
the name list was derived by a heuristic before the façade existed; it was
rejected because the abi returns plain `void`.

### The cross-compiles found what the host could not, again

`net_sockets.zig`'s `net/shutdown` retries on `EINTR`, and the retry loop is
inside `if (windows) ... else ...` — so the host compiles one arm and
`x86_64-windows-gnu` the other. Stage 3 never saw the Windows arm, because Zig
does not analyse a comptime-false branch, so `zig build` had nothing to say
about it. This is Phase 10's fifth rule and it is now the seventh increment
running that a cross-compile has caught something.

Worth recording is what it led to rather than what it was. The Windows error
named one line; fixing it revealed that the file had *eighteen* uses of one
shape — `const stream = getStream(argv, 0)` with `try stream` at every use —
which the cascade had been converting one build at a time. A layer's worth of
one mistake is cheaper to find from a single instance than to grind through.

### The benchmark, and a corpus that turned out to measure the harness

The Phase 9 corpus cannot see this increment: nine of its ten workloads are
interpreter dispatch and the tenth is a PEG match. What 17b changed is the
first two or three instructions of a *cfunction*. So
`port/probe-17/bench/` is a second corpus, seven workloads chosen for the
opposite property — as little work per call as possible, so entry cost is the
largest share of it — plus a PEG control.

Its first readings looked like findings. `threearg` read **+5.3%** and then
**+6.4%** across two runs of the same pairing, and `abstract` read -4.9% and
+3.5% in the two pairings, which is the same direction twice and therefore the
shape of a real effect.

Neither was real, and the way to see that is cheaper than either: **pass the
same binary as both arguments.**

```
workload           base       cand    delta
twoarg           0.0520     0.0539    +3.7%
threearg         0.0576     0.0546    -5.2%
```

That is one binary compared with itself. The harness has a ±5% floor on
workloads this short, and every reading above was inside it. `run.sh` runs base
then candidate within each round, and taking the minimum of five rounds does
not cancel a bias present in every round — interleaving cancels thermal drift,
which is what it was built for, and not this.

Measured properly — seven runs of each binary alone, minimum per workload — the
answer is that nothing moved:

| workload | HEAD | 17a+17b | delta |
| --- | --- | --- | --- |
| onearg | 0.026723 | 0.026724 | +0.0% |
| twoarg | 0.051748 | 0.052518 | +1.5% |
| threearg | 0.057087 | 0.057090 | +0.0% |
| buffered | 0.054849 | 0.055014 | +0.3% |
| optional | 0.034802 | 0.035279 | +1.4% |
| abstract | 0.029693 | 0.029723 | +0.1% |
| variadic | 0.159772 | 0.158910 | -0.5% |
| control | 0.004334 | 0.004221 | -2.6% |

`threearg` differs by three microseconds in fifty-seven milliseconds. The Phase
9 corpus agrees at its own precision: control at +0.3%, +0.1% and -1.5% across
three runs, everything else inside that, and `fib` reading -10.4%, -2.3% and
+2.2% across three runs of one corpus, which is the layout effect Parts 14, 15
and 16 all recorded.

**So: 656 crossings converted, and no measurable cost.** The generalisation is
in `AGENTS.md` and it is Part 16's rule made cheaper — a control workload tells
you the floor by inference, and running the harness against itself tells you the
floor directly.

### Both abis, and why no new contract

Phase 10's acceptance list wants the abi and the Zig implementation of a converted
symbol tested separately, and this is the increment where that check is met
without a line of new test code — which is worth stating rather than leaving
the reader to wonder, as the phase's sixth rule asks.

Nothing about the *exported* symbols changed here. `janet_getstring` and its
sixty relatives are still `raise.panicking(get).abi`, still exported under the
same names, and `test/args_core.c` still drives every one of them through
`EXPECT_PANIC` — seventy panics asserted by message. That is the abi, and it
is the abi that disappears in Part 17f, so it is the one that rots.

What changed is who calls the *implementation*. Before this part nothing did
outside `args_core.zig`; now every cfunction in the runtime does, which means
the Zig implementation is exercised by every Janet suite in the tree — 4,813 assertions
across forty-one suites, reaching it two or three times per cfunction call. The two abis are
each other's differential exactly as the rule intends, and
`port/probe-17/arg-layer.janet` is what compares them directly.

### Six lines of incidental churn, and why they stayed

`port/convert.py`'s splitter double-indented the closing brace of a nested
`fn`, which `zig fmt` fixes — and reaching for `zig fmt src/zig/` was a mistake
worth recording, because **the tree has never been formatted**. It reformatted
twenty-odd files this increment has nothing to do with; `value_wrap.zig`,
`emit_core.zig`, `trace_frames.zig` and `specials_core.zig` were reverted for
that reason.

Six changes stayed, inside files this part already converted, and they are not
whitespace: Zig 0.16's formatter canonicalises `@constCast(@ptrCast(x))` into
`@ptrCast(@constCast(x))`. Semantically identical, and `git diff -w` does not
hide them. They stayed because any future `zig fmt` on those files
reintroduces them, but they are the increment's churn rather than its subject
and are named here rather than left to be found.

### The differential

`port/probe-17/arg-layer.janet`, fifty-nine lines of output, **identical**
across `-Dargs-core=c` and `-Dargs-core=zig`. It reaches every fault kind the
layer can report — arity below and above, fourteen type refusals, the numeric
range checks, the optional default path and the optional refusal path, all
three slice messages, `getflags`' offending character, the embedded-zero
refusal — and then reaches them again from `peg/match`, `marshal`, `os/date`
and `int/s64`, which are four more callers in four more subsystems.

Two things it had to be built around. **A message that names a container names
its address**, and the same binary disagrees with itself between runs; the
addresses are scrubbed with a PEG rather than avoided, because several of these
messages are only reachable by handing a container to a getter that wants
something else. And **`os/exit` is deliberately absent**: it takes the process
with it, and a corpus that aborts reports every later line as missing.

## The value layer, and the end of the trampoline

Phase 10 Part 17c. The third of the hinge's six parts, and the first to touch
the interpreter's hot path.

### A different kind of work from 17b

17b had it easy and did not look it. The argument layer had carried two abis
since Part 5 — an implementation returning `raise.Raising(T)` and a
`raise.panicking` wrapper — so converting its callers was the whole job.

The value layer had no such thing. `value_access.zig` raises by calling
`janet_panicf` **through the C variadic ABI**, which was deliberate and is
recorded at the head of that file: a getter must not raise, so `capi.c`'s
report a fault code and let C format it, but these accessors are under no such
constraint. Panicking *is* their contract — `janet_in` raises on a key that is
wrong for its container, `janet_length` on a value with no length — and the
file was jump-transparent, so a `longjmp` out of `janet_panicf` stranded
nothing.

So this part had to convert the raises themselves before it could convert a
single caller: twenty-one `c.janet_panicf` calls became `raise.panicf` returns,
which meant repacking each one's variadic argument list into a tuple. The two
that mattered most are the shared ones. `getterCheckInt` is the bounds check
all seven accessors run, and `badKey` is the message it produces; both became
error-returning, and `badKey` answers with the bare error set rather than an
error union — the shape `raise.panicf` itself has — so a caller writes
`return badKey(...)` and the compiler knows the path ends there.

The container kernels were the same story with fewer sites. `janet_array_push`,
`janet_buffer_extra`, the five `janet_buffer_push_*` and the two foreign-memory
guards raise on exactly two failures: a container that has reached `INT32_MAX`,
and a buffer whose payload the runtime may not reallocate.

### The trampoline is down to one callee

`run_vm` reached this layer through `scoped`, the wrapper Phase 7 built: a
direct call under the default, a `setjmp` scope under `-Dcall-trampoline`.
Seven opcodes went that way — `JOP_IN`, `JOP_GET`, `JOP_GET_INDEX`, `JOP_PUT`,
`JOP_PUT_INDEX`, `JOP_LENGTH` and `JOP_NEXT` — and each now calls the Zig
implementation with `try`:

```zig
c.JOP_IN => {
    self.commit();
    const value = try access.in(self.stack[fB(self.pc)], self.stack[fC(self.pc)]);
    self.reload();
    self.stack[fA(self.pc)] = value;
```

against five lines and a signal check before it.

**Four more went with them, and those were free.** `vm_calls.zig`'s
`mcall`, `callNonfn`, `resolveMethod`, `unaryCall` and `binopCall` have
returned `raise.Error` since Part 2; the loop could not reach them because
`scoped` needs a plain return type, so Part 2's own notes record it calling the
`Panicking` spelling and predict that "the next increment removes it". That was
three increments ago and this is where it happened. `janet_equals`,
`janet_compare` and the three fill loops lost their scopes too — none of them
raises on its own account.

`scoped` now has **one** callee, `invokeCFunction`, which is Part 17e's
subject. `-Dcall-trampoline` has been shrinking one callee at a time exactly as
Part 2 said it would.

### Three places the conversion had to stop, and they are all one shape

Each is a function pointer whose type is not ours to change, and naming the
shape is worth more than the three instances:

- **The parser's state consumers.** `JanetParseState.consumer` is a C function
  pointer in `janet.h`'s struct, so `janet_zig_parser_root` cannot return an
  error union. `closeDelimiter` catches and delivers there.
- **The event loop's async callbacks.** `ev_callback_read` has a fixed `void`
  signature. It already caught at the boundary, so the arms above it convert
  freely — and the Windows arm had to be given the same signature as the posix
  one, which is what the cross-compile found.
- **A table of getters.** `parserStateDelimiters` now declares an error it never
  returns, which Phase 10's fourth rule would normally forbid. It is right here
  because two getters of different shapes share one array and the other one
  genuinely raises; the alternative is a tagged union over two function types,
  which is more machinery than the fact deserves. The declaration says so.

The general rule this suggests, and which Parts 17d and 17e will test: **a raise
converts as far as the nearest function pointer whose type is fixed elsewhere,
and stops there with a `catch`.** Every jump left in the tree is now at one of
those boundaries or at a cfunction.

### What the tooling learned

`port/convert.py` took five corrections, every one from a case 17b never met,
and they are in its header:

  - **String and character literals** in both scanners. `parser_core.zig`
    passes a literal containing a bracket, and `'{'` appears wherever a source
    names a delimiter; an unaware scan runs off the end of the file counting
    punctuation that is not code.
  - **Multi-line signatures.** The compiler reports the line holding the
    closing paren and the return type, which is enough, but the pattern only
    matched a signature on one line.
  - **Explicit C names in the façade.** `janet_getcstring` is the lowercase of
    `getCString`; `janet_buffer_push_u8` is not the lowercase of anything. A
    trailing `// janet_buffer_push_u8` on the declaration says so. Getting it
    wrong is not dangerous — the name matches nothing and the crossing is left
    alone — but it is silent, so an unconverted crossing after a sweep is the
    thing to check.
  - **Two guards on the splitter.** It must not split a `noreturn` abi, and it
    must not split a body that already *delivers*. `signal_core.zig`'s
    `janet_signalv` reads `raise.deliver(raise.signal(...))`, which matched the
    "this body raises" test and came back as `raise.Raising(noreturn)` — not a
    type.

One failure mode survives and is documented rather than fixed: the cascade puts
`try` on a `switch` **statement** when the fault is in one arm. Four
occurrences, all fixed by hand, all loud.

### The differential

`port/probe-17/value-layer.janet`, fifty-five lines, **identical** across
`-Dvalue-access=c`/`zig` and across `-Dbuffer-array=c`/`zig`. It reaches `in`
on all six container types and its four refusals, `get`'s five nil answers,
`put` and `put-index` on both the mutable and the immutable types, `length`'s
three refusals, the iteration protocol, and the container kernels' growth
paths.

Two of its messages name a container, which means they name an *address*, and
the same binary disagrees with itself between runs; they are scrubbed with a
PEG rather than avoided, because those messages are only reachable by handing a
container to something that wants a scalar.

### The benchmark

`port/probe-17/bench/access.janet`: one opcode per workload, with a control of
arithmetic that reaches none of them. Measured each binary alone, seven runs,
minimum — which is 17b's rule, and this corpus is why it matters twice over.

The loop counts had to be resized. Written against the Debug build they put
every workload between ten and twenty-four milliseconds at `ReleaseFast`, which
is inside the harness noise 17b measured; twenty million iterations puts them
between a tenth of a second and a third of one.

| workload | HEAD | 17a-c | delta | repeat |
| --- | --- | --- | --- | --- |
| in-tuple | 0.118506 | 0.118550 | +0.0% | -0.1% |
| in-table | 0.224672 | 0.226087 | +0.6% | -0.2% |
| get-table | 0.219408 | 0.220917 | +0.7% | -0.3% |
| get-index | 0.208368 | 0.207654 | -0.3% | -0.3% |
| put-table | 0.240185 | 0.241802 | +0.7% | +0.4% |
| put-index | 0.108332 | 0.107538 | -0.7% | +0.1% |
| lengths | 0.107348 | 0.106756 | -0.6% | -0.7% |
| iterate | 0.116488 | 0.118500 | +1.7% | -1.3% |
| control | 0.185315 | 0.185904 | +0.3% | -0.5% |

`iterate` is the only workload above one percent and it flips direction on the
repeat, which is the definition of noise here. **Nothing measurable**, which is
the answer 17a and 17b also gave and is more interesting this time: the seven
opcodes lost a wrapper *and* the C calling convention on the call beneath it,
and Part 1 measured 1.86x for an `extern union` parameter against a native one.
That the difference does not show says the parameter cost is not where these
opcodes spend their time — the hash lookup and the bounds check are.

The baseline is HEAD, which is before 17a, so the comparison covers all three
sub-parts. 17a and 17b each measured flat on their own corpora, so a delta here
would have been 17c's; there is no delta.

## The library surfaces, and the last raise in Zig that jumps

Phase 10 Part 17d. The fourth of the hinge's six parts, and the one after which
**only three `c.janet_panic*` calls remain anywhere in Zig** — two of them the
`-Dargs-core=c` shim doing its job, and one a cfunction that Part 17e takes.

### Four populations, and only one of them was a crossing

17b and 17c each converted a layer's callers. This part is a different shape:
most of what it found was a subsystem raising through the abi **when it
could simply have returned**.

  - **Forty-six of its own raises.** `buffer_array.zig`, `inttypes.zig`,
    `string_symbol.zig`, `struct_table.zig`, `debug_frames.zig`,
    `ev_backend.zig`, `ev_channel.zig`, `ev_stream.zig` and `parser_core.zig`
    all called `c.janet_panicf` from inside their own bodies. That was correct
    when each was its own compilation and there was nothing else it could do.
    Since 17a there was, and nothing had gone back for them.
  - **`janet_sandbox_assert`, fifty-eight crossings.** Every `os/`, `io/`,
    `net/` and `ffi/` cfunction opens with it before it looks at an argument,
    which makes it the most-called raise in the runtime after the argument
    layer's. `subsystems/lifecycle.zig` presents it.
  - **The marshalling context, the printer and the event loop**, fifty-two
    between them, behind three more façades: `marshalling.zig` for the five
    entry points an abstract type's `marshal` and `unmarshal` callbacks use,
    `printer.zig` for `(string x)` and `(describe x)`, and `evloop.zig` for the
    stream, channel and cancellation calls.

Seven façades exist now, and the pattern has settled: one per selector, named
for the layer rather than the file, `// janet_the_c_name` on any declaration
whose C spelling is not the lowercase of its Zig one.

### One interface across four backends

`ev_backend.zig` holds `iocp`, `epoll`, `kqueue` and `poll`, and **the host
compiles exactly one of them**, so `epoll`'s and `iocp`'s raises were invisible
to every cascade run on this machine. That is Phase 10's fifth rule and by now
routine; what was not routine is that the obvious fix does not work.

`try impl.edgeTriggered(s)` needs the `try` on `epoll` and must *not* have it
on `kqueue`, and one source line cannot be both. So the backends now wear one
interface: `init`, `register`, `unregister`, `edgeTriggered` and
`levelTriggered` return `raise.Raising(void)` on all four, and `kqueue` and
`poll` declare an error they never return.

That is the second deliberate exception to Phase 10's fourth rule in two parts,
after `parserStateDelimiters`, and the two are the same shape: **a rule that
says "do not declare what you cannot do" has to yield where several
implementations share one call site.** Both say so at the declaration.

### Where SPIKE-8's rule stopped me, and the compiler would not have

Widening the backend interface pushed an error union up `filewatch_core.zig`'s
`eachWatch`, a comptime-generic walk over a watcher's descriptors. Two callers:
`unlisten`, which closes streams and genuinely raises, and `mark`, which is an
abstract type's `gcmark` callback.

The clever version — one walk, generic over the body's error set — compiles.
The correct version is two walks, because **SPIKE-8 says a `gcmark` callback
may not raise**, and a single raise-capable `eachWatch` would have put an error
union on the mark path. Nothing in the type system objects to the clever
version; the rule is what objects, and the rule is only written down.

### A zero-arity hole that only a `c` selector could find

`raise.declared` and `raise.panicking` switch on arity, and neither had a case
for **zero**. Nothing had needed one: every raise-capable symbol converted
before this part takes at least one argument. `janet_init`, `janet_ev_init` and
`janet_clear_memory` take none, and their shims are compiled *only* under
`-Dvm-lifecycle=c` and `-Dev-loop=c`.

So the default build was green, all five cross-compiles were green, and the
gap surfaced when a differential run built the C arm. It is the same lesson
Part 15 recorded from the other direction — "a configuration is as much an
uncompiled arm as a platform is" — and it is why every `c` arm this part added
is a `full` matrix entry rather than a shallow one.

### Two working-file corrections

`port/convert.py` grew **`--target`**, which is no longer a convenience: 17d
needed three separate cascades — host, `x86_64-linux-musl` for `epoll`, and
`x86_64-windows-gnu` for `iocp` — and the errors in each are invisible to the
other two.

It also learned to pass **`-p`** with its own prefix. A `--target` cascade
installs into `zig-out` like any other build, and a Windows `janet` sitting
there reports `exec format error` several minutes later, from a command that
has nothing to do with the build. `AGENTS.md` has warned that "`zig-out`
belongs to whichever configuration was built last" since Phase 8; this is the
first time a *tool* in `port/` was the one that broke it.

### The differential

`port/probe-17/library-surfaces.janet`, thirty-three lines, **identical**
across `-Dmarsh`, `-Dpp`, `-Dev-loop`, `-Dvm-lifecycle` and `-Dfilewatch-core`,
both arms of each. It marshals eight shapes and round-trips them, refuses three
malformed images, renders eleven values through both renderers, and turns the
sandbox on and watches two cfunctions refuse and one carry on.

The sandbox section has to be last and has to be in its own paragraph of the
file, because the sandbox is one-way: every line after it runs in a restricted
interpreter, and a corpus that turned it on early would be measuring a
different runtime from that point down.

### The benchmark, and a workload deliberately absent

The Phase 9 corpus, each binary alone, seven runs, minimum. Control `pegmatch`
at **-0.3%** and **-0.9%** across two runs with the measurement order reversed;
everything else inside ±1.7%. `fib` read **+5.5%** and then **+1.2%**, a swing
of more than four points between two runs of the same comparison, which is what
this session has learned to call noise rather than a reading — it is the
shortest workload in the corpus at sixteen milliseconds.

**There is deliberately no workload for the sandbox check**, and the reason is
worth keeping. Every cfunction that pays the check also makes a system call:
`(os/cwd)` runs at five microseconds an iteration against forty nanoseconds for
`probe-17/bench`'s `onearg`, so the check is three orders of magnitude beneath
the noise of the cheapest thing that performs it. A corpus that cannot resolve
what it is aimed at should not pretend to. The honest statement is that the
conversion turned a predicted-not-taken branch on a VM field into the same
branch, and nothing in the tree can see the difference.

## The cfunction boundary, and the first regression this phase has measured

Phase 10 Part 17e. The fifth of the hinge's six parts. After it, every raise in
Zig returns except the 145 public abis, and Phase 7's trampoline is gone.

### Three call sites, counted rather than assumed

A `JanetCFunction` is a *builtin* — a function callable from Janet but written
in the host language — and there are about three hundred and twenty of them.
The name is 2017's, when the host language was C; they are all Zig now.

`janet.h` fixes the signature at `Janet (*)(int32_t, Janet *)`, so a builtin
that raises has no error union to return. That is rule 11's shape exactly: the
conversion reaches a function pointer whose type is fixed elsewhere and stops.
What it does instead is record the raise in `janet_vm.raising` and return an
unspecified value, and whoever invoked the pointer tests that and turns it back
into `error.JanetSignal`.

The whole safety of that rests on one number, so it was measured rather than
assumed: **three** places in the tree invoke a cfunction pointer — `run_vm`'s
`JOP_CALL` and `JOP_TAILCALL`, `janet_method_invoke`, and the PEG engine's
capture — and **zero** call an abi directly. All three go through
`raise.callCFunction`, so a fourth site cannot forget the test.

The value returned on a raise is *zeroed* rather than `undefined`, deliberately.
An unspecified value that is nonetheless determinate makes a mistake
reproducible: a caller that forgets the test gets nil every time rather than
whatever was in the register.

### The flag's weakness, demonstrated twice in one afternoon

A flag in VM state is worse than a value in the signature, and this part
demonstrated it twice before the day was out.

**Once by hanging.** The flag was set in `raise.raised`, which is right, *and*
in `janet_zig_signal_record`, which is not: `record` runs for every raise
including the ones still delivered by jump, so a `longjmp` left the flag
standing and the next cfunction to return normally was read as having raised.
The symptom was `test/suite-net.janet` **hanging rather than failing** — a
socket read reported a raise it had not made, the fiber never resumed, the
event loop waited on it forever. It was found by `zig build test` blowing
through a ten-minute timeout, which is not a diagnostic.

**Once by lying.** `-Dvm-run=c` compiles the C interpreter, which called
cfunctions and ignored the new flag entirely, so
`(protect (string/slice "abc" 99))` answered `(true 0)` — the zeroed value,
reported as a success. Three C sites needed the check: `vm.c`'s
`vm_call_cfunction`, `janet_method_invoke`, and `peg.c`'s capture.

Both are the same defect: **a flag has a validity window and a signature does
not.** `PLAN.md`'s 17f entry records the decision that follows — the type
becomes ours when `util.c`'s registry moves, and

```zig
pub const CFunction = *const fn (i32, [*c]Janet) raise.Error!Janet;
```

retires `janet_vm.raising`, `raise.raised`, `raise.tookRaise` and
`raise.callCFunction` together. A C-compatible struct return was considered as
a waypoint and rejected: two changes to reach what one change reaches.

### Phase 7's trampoline is gone

`scoped` had thirteen callees when Part 17 began. Every one of them now returns
its raise, so there was nothing left for a `setjmp` scope to catch, and the
forty-nine lines went. `janet_vm_scoped` and the `JanetVmTryState` behind it are
`src/core/vm.c`'s last customers of the second `setjmp`, and go with it in 17f.

### The first measurable regression of the phase

Every part of this phase has reported "nothing measurable" and meant it. This
one does not, and the corpus that shows it is `port/probe-17/bench/`, built in
17b to isolate cfunction entry — the thing nine of the Phase 9 corpus's ten
workloads cannot see.

Measured each binary alone, seven runs, minimum, against HEAD before 17a:

| workload | HEAD | 17a-e | delta | reversed |
| --- | --- | --- | --- | --- |
| onearg | 0.141953 | 0.153442 | **+8.1%** | +10.9% |
| abstract | 0.213074 | 0.227949 | **+7.0%** | +8.4% |
| buffered | 0.177676 | 0.187517 | **+5.5%** | +5.4% |
| optional | 0.183969 | 0.187299 | +1.8% | +3.8% |
| twoarg | 0.193062 | 0.198608 | +2.9% | +2.2% |
| threearg | 0.211009 | 0.213192 | +1.0% | -6.5% |
| variadic | 0.199569 | 0.197375 | -1.1% | -0.0% |
| control | 0.163272 | 0.163829 | +0.3% | +1.1% |

The control is flat, the direction holds when the measurement order is
reversed, and the pattern is coherent: **the cheaper the builtin, the larger
the cost**, which is what a fixed per-call overhead looks like.

Two experiments narrow it. Moving `raising` from the middle of `JanetVM` to its
tail changed nothing, so it is not struct layout. Rebuilding with the 193 abis
delivering by jump again — the caller's flag test left in place — takes
`onearg` from +6.6% to **+4.8%**, so **17e accounts for about two points and
the other five predate it.**

The remaining five are most plausibly 17b's: the argument layer's getters
return `raise.Raising(T)` where they used to be C-ABI calls returning a plain
value, and `SPIKE-10.md` priced that at **1.51x of the call overhead where it
does not inline**. `onearg` is `(math/floor 1.5)` — one arity check, one
getter, one instruction of work — so it is very nearly pure call overhead. That
attribution is reasoned rather than measured, and it is the one thing this part
leaves for the gate to settle.

The Phase 9 corpus still reports nothing across 17a-e, which is not a
contradiction: it measures programs, and this measures the cheapest possible
builtin in a loop. Both are true, and the phase's tolerance — sub-10x, prefer
idiomatic Zig, measure to inform rather than to decide — accommodates a figure
this size. It is recorded rather than buried because a percentage nobody writes
down is a percentage nobody can find later.

### The differential

`port/probe-17/cfunction-raises.janet`, twenty-two lines, **identical** across
`-Dvm-run`, `-Dvm-calls`, `-Dpeg-engine` and `-Dcore-env`, both arms of each.
It is organised by invocation path rather than by subsystem — a builtin raising
in argument position, the same builtin in tail position, a method, and a PEG
capture — and then checks that the raise still unwinds the same frames, by
asserting what `debug/stack` names, and that it is still catchable by `try`, by
`protect`, by a fiber and by a nested fiber.

## `util.c`'s remainder, and a fourth cfunction call site

Phase 10 Part 17f. The sixth of the hinge's nine parts, and the largest single
port left in the phase: 594 live lines, which is more than the next three files
together. It is separated from 17g and 17h precisely so that it is only a port
— no mechanism changes, no decision, and the `setjmp` untouched.

After it, `src/core/util.c` is **empty on every target** — not merely zero
live lines on this one.

### Two selectors, because `util.c` is not one subsystem

Phase 10's rule 2 says a selector's subject is a subsystem and not a file, and
`util.c` is the file in the tree that most needed the rule applied to it. What
was left in it divides cleanly along one line: whether the code owns any of the
runtime's state.

`utils.zig` grew by the half that owns none. The collection hashes, the
dictionary probe every table and struct lookup goes through, `janet_cstrcmp`
and `janet_strbinsearch`, `janet_sorted_keys`, `safe_memcpy`, and the four host
services `util.c` kept beside them — `janet_strerror`, `janet_cryptorand`,
`get_processed_name`, the allocator wrappers, and the four static tables --
`janet_type_names`, `janet_signal_names`, `janet_status_names` and
`janet_base64` -- that eleven Zig files read. `-Dutilities` went from eight
exported symbols to twenty-eight, none of which raises, so the file needs no
jump-transparent marker and `defer` stays legal in it.

`registry.zig` is new, under a new `-Dregistry`, and has the half that does:
`janet_vm.registry` and its three operations, the four `janet_cfuns*`
registration entry points and the two `janet_core_*` forms beside them,
`janet_def`/`janet_var` and their source-mapped twins,
`janet_vm.abstract_registry`, `janet_binding_from_entry` and the three
resolvers over it, and `janet_text_substitution`. The selector count goes
**63 to 64**.

The clock went to `-Dos-time`, which already owned `janet_os_gettime`, and
this is where Phase 10's rule 3 earned itself again. `os_time.zig`'s header
said `struct timespec` "cannot be named from Zig", which is true of the
*translated* one -- musl declares its padding as a bitfield and translate-c
demotes the structure -- and false of `std.c.timespec`, which the same file was
already using for `clock_gettime`. So `janet_gettime` is four lines of Zig and
`util.c`'s last live region went with it. `test/os_time.c` calls it directly,
including with a source value outside the enum, so the `c_uint` the enum is
passed as is checked rather than assumed.

### What the four registration entry points actually differ in

`janet_cfuns`, `janet_cfuns_ext`, `janet_cfuns_prefix` and
`janet_cfuns_ext_prefix` are ninety lines of C written out four times. They
differ in exactly two things — whether the table carries source locations, and
whether each name gets the registration prefix — so the port writes the loop
once under two comptime flags:

```zig
fn Register(comptime Entry: type, comptime prefixed: bool) type
```

That is not tidying for its own sake. The four have drifted before: only the
prefixed pair builds a `NameBuf`, only the `Ext` pair passes a source file, and
every one of them passes the *unprefixed* name to the registry while defining
the prefixed one — which is easy to get wrong in the fourth copy and which
`test/registry.c` now asserts for all four.

### The zero-capacity probe is the seventh entry a port does not reproduce

`janet_dict_find` masks the hash with `cap - 1`, and `FOUND.md`'s "A
zero-capacity table cannot be looked up in" records what a capacity of zero
does to that: the mask becomes the identity and both loops are bounded by the
whole 32-bit hash rather than by the array.

That entry has said "reproduced in both selectors" since Phase 8 Part 6c, and
the reason was that `janet_dict_find` had not moved — both selectors ran the
same C. It has moved now, and the port does not reproduce it, because C's
behaviour here is *undefined* rather than merely wrong. Phase 10's acceptance
rule draws the line: "defined C behavior is reproduced even when it is a bug;
undefined behavior is recorded instead." So the Zig probe indexes naturally and
a safety-checked build traps where C reads two gigabytes below the null page.

The entry was revised rather than left standing, which is the part worth
recording as a habit: **an increment that moves a function invalidates every
`FOUND.md` entry that said the two selectors shared it.**

### A fourth place that invokes a cfunction pointer

Part 17e's whole safety argument rests on one number, and it recorded the
number as measured rather than assumed: "**three** places in the tree invoke a
cfunction pointer ... and **zero** call an abi directly."

There is a fourth, and this part found it by having to port it.
`janet_text_substitution` runs the substitution a `string/replace` or
`peg/replace` was given, and when that substitution is a builtin it calls the
pointer directly:

```c
return to_byte_view(janet_unwrap_cfunction(*subst)(argc, argv));
```

17e patched the three C sites it knew about — `vm.c`'s `vm_call_cfunction`,
`janet_method_invoke`, and `peg.c`'s capture — and missed this one. The count
was taken over Zig, and this site was in C.

**What it costs is visible but not obvious**, which is why nothing caught it.
The raise is not lost: the flag stays set, the substitution silently yields nil,
the loop substitutes the remaining matches with nil too, and the *enclosing*
builtin's return is then read as the raise. So `(protect (string/replace "a"
string/find "banana"))` answers with the right message for the wrong reason, and
every test that only checks the message passes. What is wrong is the attribution
and the work done after the raise.

Both arms were fixed rather than only the port: `registry.zig` calls through
`raise.callCFunction`, and `src/core/util.c`'s arm got the same three-line test
the other C sites carry, so the differential still compares like with like. The
C arm dies in 17h regardless; leaving it wrong would have meant a differential
that diverges for a reason unrelated to the port.

The general form is 17e's own lesson turned on itself: **a count taken over one
language is a count of that language.** Part 17e's rule that a flag has a
validity window and a signature does not is what 17g fixes; until then, the
population that has to be right is "every call through a `JanetCFunction`
pointer anywhere", and `grep` over `src/zig` was never that.

### `strerror_r` is two functions with one name

`janet_strerror` has three implementations in the C original, picked by
`#ifdef`: Windows calls `strerror`, glibc calls a `strerror_r` that returns
`char *` and may never touch the buffer, and everyone else calls an XSI
`strerror_r` that fills the buffer and returns `int`.

Zig cannot declare one symbol twice, so the port declares the XSI signature and
reaches the GNU one through a function-pointer cast selected by
`builtin.target.isGnuLibC()`. Both arms exist in the source and only one is
analysed per target, which is Phase 10's rule 5 again: the glibc arm is
type-checked by the Linux cross-compile and by nothing on this host.

The first attempt declared both as `extern` with different signatures and
different Zig names, which compiles and then fails at link with `undefined
symbol: _strerror_r_xsi` — an `extern` declaration's Zig name *is* the symbol
name, and there is no rename.

### `janet_cryptorand`'s Linux arm is compiled by nothing here

Three implementations again — `rand_s` on Windows, `arc4random_buf` on BSD and
macOS, and `/dev/urandom` with `RETRY_EINTR` loops everywhere else. The third is
the one this host never compiles, and it is thirty lines with three retry loops
in it. The Linux cross-compile is the only thing that has ever looked at it.

### What the instruments say

### The Win32 loader, which the live-line measure could not see

`util.c`'s last section is the dynamic-library loader, and on POSIX there is
nothing in it: `util.h` defines `load_clib`, `symbol_clib` and `free_clib` as
macros onto `dlopen`, `dlsym` and `dlclose`, and `error_clib` onto `dlerror`.
On Windows all four are real functions — about forty-five lines, including a
`FormatMessageA` over `GetLastError` and a walk across every module the process
has loaded.

They are invisible to the live-line measure, which counts what *this host*
compiles, and visible to the exit gate, which says no C source file remains. So
they were nearly left for Part 18 to discover. They are `dynlib.zig` now, under
`-Dutilities` with the rest of `util.c`'s substrate.

**One of them raises**, which is the only reason this is more than a
transcription. `symbol_clib`, asked for a symbol in the process rather than in
a library, panics if `EnumProcessModules` fails. Its two callers are
`ffi_core.zig` and `core_env.zig`, both already raise-capable, so `symbol`
returns `raise.Raising(?*anyopaque)` — on every platform, while only the
Windows arm can ever return the error. That is rule 12's exception, the same
one `ev_backend.zig`'s four backends take: one source line, `try
dynlib.symbol(...)`, cannot need a `try` on Windows and not on Linux.

**And the two copies became one.** `ffi_core.zig` and `core_env.zig` each
carried this block, and one of them explained why: "the two are not shared
because the objects share no module." That was true when it was written, and
**Part 17a made it false** — there is one module now, so a shared file is an
ordinary import. Nobody went back to check. It is rule 9 again, at a smaller
scale than the rule's own example: a premise that stopped holding when the
build changed, in a comment that went on asserting it. The duplication had
already drifted, too — one copy's `Handle` carried a redundant branch and only
one had `free`. Eighty-seven lines became one file of forty.

The Windows arm is compiled by `x86_64-windows-gnu` and executed by nothing,
which is what the whole of it buys: type-checking. The POSIX arm is the one
under test, and `suite-ffi.janet` and the native-module tests exercise it.

**And type-checking was enough to earn its keep, in the other Windows-only
port this part made.** `janet_gettime` was written as

```zig
export fn janet_gettime(spec: *std.c.timespec, source: c_uint) callconv(.c) c_int
```

which is right on every POSIX target and does not compile for Windows:
`std.c.time_t` is `void` there, because `std.c` describes a libc Windows does
not have, so the struct's fields have no type and `@intCast` fails with
`expected integer or vector, found 'void'`. The host build, the two other
Linux cross-compiles and the riscv32 one were all green. Phase 10's rule 5,
for the eighth increment running: the arm this host does not select is not
merely unreachable but unchecked.

The fix names mingw-w64's own declaration, `{ __int64 tv_sec; long tv_nsec; }`
with `long` at 32 bits. The POSIX arm keeps `std.c.timespec`, which is the type
`janet_os_gettime` in the same file already hands to `clock_gettime`, so
nothing new is exposed to the musl-layout question that the original C comment
raised.

### One defect, found by reading

`error_clib` does not check what `FormatMessageA` returned:

```c
error_clib_buf[strlen(error_clib_buf) - 1] = '\0';
```

The call writes nothing when it cannot format the code, the buffer is still
zeroed, `strlen` is 0, and the index is `(size_t) -1` — a write one byte before
a static array. On a second failure it is worse in a quieter way: the buffer
still holds the *previous* message, so the caller gets that, one character
shorter each time. `FOUND.md` has it, and the port does not reproduce it, on
the same rule as the zero-capacity probe above: a write outside an object is
undefined, so it is recorded rather than copied.

**Live lines.** `src/core/util.c` goes **594 to 0** -- it is the twelfth file
to reach zero and the largest -- and the tree goes 1,629 to 1,035. It is the
biggest single reduction of the phase.

Reaching zero took two things the plan's list for this part did not name, and
both were found by measuring rather than by reading the list: the four static
tables above, and `janet_gettime`. An earlier reading of this increment
reported `util.c` at zero when it was at 65, because the per-file measurement
was skimmed at its head and its tail and `util.c` had moved to the middle.

**`janet_panic` sites in C: 9 to 8.** The one was
`janet_register_abstract_type`'s, which is the only raise in what was `util.c`.
`fiber.c` (3), `asm.c` (2), `capi.c` (2) and `abstract.c` (1) are what is left.

**Crossings converted: 12.** Nine `janet_register_abstract_type` and three
`janet_text_substitution`. Small next to 17b's 656, and that is the point of the
split: this part is a port, and the conversions in it are incidental.

Three `janet_lib_*` functions had to gain an error-returning half to hold their
`try` — `janet_lib_io`, `janet_lib_inttypes` and `janet_lib_peg` — which is the
same Impl-plus-abi shape `math.zig` and `ev_loop.zig` already had.

**Contracts.** `test/registry.c` is new, 544 lines, and `test/utils.c` grew from
95 to 341. Both were run against their `c` arm before being trusted against Zig,
and the registry one caught its own bug that way: it asserted that
`janet_resolve` dereferences a var, and it does not — only the two *dynamic*
binding types are dereferenced, and a plain var resolves to the ref array.

**The differential.** `port/probe-17/util-remainder.janet`, 146 lines of
output, **identical** across both arms of `-Dutilities` and both arms of
`-Dregistry`.

**The benchmark, and a control that was lying about the machine rather than
the code.** This part's benchmark is the reason it took an afternoon longer
than it should have, and what it found is worth more than the increment.

The Phase 9 corpus reported `pegmatch` at **+48.4%**, and `pegmatch` is that
corpus's designated control — its own comment says "the work happens inside
`peg.c`, so this is the control. A dispatch change that moves this number is
measuring something else." By rule 7 the corpus had therefore measured nothing
and the outlier had to be explained before any workload could be read.

It was not the code. `peg/match` in a loop by itself showed no change; the
whole corpus with only `pegmatch` enabled showed no change; forcing a
collection between workloads changed nothing. What finally separated it was
running the identical command from a different shell:

```text
$ ./janet port/probe-9/bench/bench.janet | grep pegmatch      # zsh
pegmatch 0.038912
$ bash -c './janet port/probe-9/bench/bench.janet' | grep pegmatch
pegmatch 0.057662
$ PAD= bash -c './janet port/probe-9/bench/bench.janet' | grep pegmatch
pegmatch 0.039423
```

**One empty environment variable, 48%.** The kernel derives the initial stack
pointer from the size of the argv and environment block, so the environment's
*size* fixes the alignment of everything below it, and this workload is bimodal
in that alignment. Swept over twelve environment sizes, **both** binaries hit
the slow mode exactly once — the baseline at one size, the candidate at
another. Roughly one layout in twelve, for any binary.

What makes it dangerous is that it is not noise. It is perfectly reproducible
for a given binary from a given shell, so it survives taking the minimum over
any number of runs, and it survives interleaving. Part 17b's recipe — seven
runs of each binary alone, minimum per workload — reported it twice, at +48.4%
and +47.8%, and both readings were stable to three digits.

`port/bench-layout.sh` is the answer: vary the environment across N sizes and
take the minimum, which marginalises the layout out rather than freezing one.
With that, the control comes back to **+0.8%, -0.0%, -0.6%** across three
passes and the corpus is measuring again:

| workload | pass 1 | pass 2 | pass 3 | final |
| --- | --- | --- | --- | --- |
| pegmatch *(control)* | +0.8% | -0.0% | -0.6% | +0.0% |
| opfallback | +8.0% | +8.6% | +6.4% | +5.3% |
| methods | +5.0% | +6.3% | +5.4% | +6.0% |
| fib | +9.1% | +3.9% | +3.4% | +7.1% |
| compiler | -3.9% | -3.6% | -3.2% | -3.7% |
| tables | -1.5% | -1.2% | -1.3% | -0.8% |

The "final" column is the whole increment including the loader, measured the
same way; the first three predate it.

**And the residue is not attributable either.** Building with `-Dutilities=c`
and with `-Dregistry=c` puts half of this part's new Zig in each, and *both*
halves move `fib` and `opfallback` by about as much as the whole does — while
`-Dutilities=c` also moves `arithmetic` by +4.5%, a workload that is pure
dispatch and cannot reach a dictionary probe or a registry. That is the
signature of code placement rather than of any ported function.

So the honest statement is: **no attributable regression, and this corpus
cannot resolve better than about ±5% on the dispatch-heavy workloads for a
change that adds six hundred lines to the single Zig object.** The
cfunction-entry corpus agrees — control -3.1%, nothing outside ±5% of it,
no consistent direction.

The finding generalises past this part, which is why it is a rule in `PLAN.md`
and a script in `port/` rather than a paragraph here. Part 16 recorded one
workload reading +10.3%, +5.8% and +13.3% across runs of the same corpus and
attributed it to layout; this is the mechanism, and it is measurable.

**The matrix**, 53 entries including the four cross-compiles, with
`-Dutilities=c` promoted from a shallow entry to a full one and `-Dregistry=c`
added as a full one. **52 pass and one is the wall clock**: the final run
failed `call trampoline` on `error: deadline expired`, which passed four times
out of four re-run alone.

It took three runs to get a clean reading, and the two discarded ones are the
useful part.

The **first** reported `vm-entry=c` on `deadline expired` — while I had `wc`
and `grep` going on the same machine. The **second** reported three FAILs that
were nothing but my own edits: `matrix.py` builds from the working tree as it
goes, and I was editing `ffi_core.zig`, `core_env.zig` and `util.c` while it
ran, so some entries got the old sources and some the new. Both runs were void
and neither said so. `AGENTS.md` now carries the rule in its strong form: **for
the duration of a matrix, the tree and the machine are frozen.**

The **third** and fourth runs found the real thing — the Windows cross-compile
failure above — and then the residue, which has a rate worth knowing:
`deadline expired` appeared in all three completed runs, on a *different* entry
each time, with **zero** FLAKYs each time. It is `suite-ev.janet` asserting
against a wall clock while two entries compete at `-j2`, and it attaches to
whoever is running. A FLAKY is the 300-second hang bound, so an assertion that
fails fast raises none — which is why "count the FLAKYs first" does not catch
this one, and why the rule is now "any failure naming a clock is re-run alone,
whatever the FLAKY count".

## The cfunction type, and twenty-five arms spent at once

Phase 10 Part 17g. `PLAN.md` called this part "small" and gave the reason:
"with the tables in Zig, `pub const CFunction = *const fn (i32, [*c]Janet)
raise.Error!Janet;` and `janet_vm.raising`, `raise.raised`, `raise.tookRaise`
and `raise.callCFunction` all retire together." The type change is small. What
it costs is not, and the cost is the part worth writing down.

### The change

```zig
pub const CFunction = *const fn (i32, [*c]c.Janet) Error!c.Janet;
```

A builtin returns its raise now, the way everything else in the runtime has
returned it since Part 2. Part 17e could not do that because `janet.h` fixed
the signature at `Janet (*)(int32_t, Janet *)` and a C function cannot return
an error union, so a raising builtin recorded the raise in `janet_vm.raising`,
returned a zero, and four call sites tested the flag on the next statement.
That flag, `raise.raised`, `raise.tookRaise` and `raise.callCFunction` are all
gone. Forgetting the test is a compile error again, which is decision 5's
argument reaching the one interface it could not reach until Part 17f put the
registration tables in Zig.

What replaces `callCFunction` is a cast rather than a protocol:

```zig
pub inline fn cfunction(slot: c.JanetCFunction) CFunction {
    return @ptrCast(slot.?);
}
```

The pointer is unchanged. What still holds one is still typed by C — a
`Janet`'s union member, a `JanetRegExt` row, a `JanetCFunRegistry` key, a C
stack frame's `pc` — because those are the C ABI's *layout*, and a layout is
all they need. Part 18 is where they go. The five call sites read
`try raise.cfunction(...)(argc, argv)` and the cast is in one place.

`corefn.Method` is the one type that did move. A method table row was
`c.JanetMethod`, and it is now an `extern struct` with the same two fields and
`?raise.CFunction` in the second, so that the seventy rows across nine
subsystems are checked the way a registration row is. Where one of those arrays
meets `janet_getmethod`, `janet_nextmethod` or `JanetStream.methods` it is
cast, for the same reason.

### 203 abis, deleted rather than converted

The tree held **203** declarations wearing `align(corefn.alignment)
callconv(.c) c.Janet` and now holds none. 196 of them were this:

```zig
fn cfunArrayNew(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) callconv(.c) c.Janet {
    return cfunArrayNewImpl(argc, argv) catch raise.raised(c.Janet);
}
```

There is nothing to convert: the implementation *is* the cfunction, so the abi
is deleted and the `Impl` suffix comes off. Ten generators went the same way —
`Abi(impl).cfun` in seven subsystems and `abi(impl)` in `fiber_core.zig` and
`asm_core.zig`, both of which Part 17f had written three weeks' worth of
increments after the comment saying they were "not shared because the objects
share no module" stopped being true. Rule 9 again, and this time the answer was
to delete them rather than to share them.

**Seven cfunctions had no abi and gained an error union anyway.** Three in
`core_env.zig`, one in `string_symbol.zig` and the four `ev/` stream ones: none
of them can raise. Part 10's rule 4 says a cfunction that cannot raise should
not pretend it can, and that rule is now narrower than it was — it governs an
*implementation's* signature, not a fixed function-pointer type. Rule 12 is the
one that applies here: a uniform interface across implementations may declare
what a particular one never does. The two rules disagreed for one increment and
`PLAN.md` records which won and why.

### What it costs, measured

**Twenty-five `c` arms, and `-Dboot`.** Selectors go **64 to 39**. Twenty
selectors' C *defined* a cfunction; three more — `vm-run`, `vm-calls` and
`registry` — *invoked* one, which is the same disqualification from the other
side and the one the live-line measure cannot see. `asm-encode` and `disasm`
went with `asm-core`, because the Zig assembler driver reaches the Zig encoder
and disassembler directly and has no path to the C ones.

`-Dboot=c` went with them, and it is the largest single loss. The image
generator registers the whole core environment, so it needed every C cfunction
there is. What goes with it is the byte-equality check between the two
generators, which was the only differential this phase had *above* the
subsystems.

**17,476 lines of `src/core` can no longer be compiled by any configuration.**
Live lines are unchanged at **839**, and both numbers are true: 17g moves no C,
it makes C unreachable. `janet_panic` call sites compiled into C stay at
**3** — `capi.c` 2, `abstract.c` 1 — for the same reason.

The differential that has been this phase's main instrument is now available
for thirty-nine subsystems instead of sixty-four, and for none of the ones with
a cfunction surface. Decision 5 priced that and 17a bought seven months of it;
this is where the bill arrives.

### Three things the suites found that reading did not

**`janet.h`'s four cfunctions had to go.** `janet_cfun_stream_close` and its
three neighbours were `JANET_API`, and they were the only cfunctions the header
declared. Keeping an abi beside the Zig one was the first plan and it is
worse than deleting them: a native module that puts `janet_cfun_stream_read`
into its own `JanetMethod` table installs a C-ABI function where the runtime
now makes a Zig-ABI call, and the header would be handing out the gun. They are
deleted, `ev_stream.zig` keeps the implementations under Zig names, and
`test/ev_loop.c` asserts through the `ev/` bindings instead of against the C
symbols — which is slightly the stronger assertion.

**`suite-zig-interop.janet` failed with `arity mismatch, expected 1, got
1868075192`.** That is decision 2 arriving as a test failure. Two objects
outside the runtime supply cfunctions: `src/zig/interop_bridge.c`, which gives
the Zig client its five `zig/*` builtins, and `src/zig/native_bridge.c`, which
is the loadable-module fixture Phase 3 built to prove a `.so` can define one.
Both were C. Both now define their cfunctions in Zig — `src/zig/interop.zig`
and `src/zig/native_module.zig` — with the C keeping only what has to stay C:
the try scope in one, and `JANET_MODULE_ENTRY` in the other, because the loader
looks that symbol up by name.

That fix is worth reading twice, because **it changes what the link rests on**.
Those objects are separate compilations, so they cannot import `raise` and
spell the type out instead. What joins them to the runtime is no longer the C
calling convention but Zig's `.auto`, which is deterministic for a compiler
version and target and is not a documented ABI. That is exactly what decision 2
means by `janet.h` ceasing to be a native-module interface, and it is now a
property of the build rather than a sentence in a plan.

`FOUND.md` records the casualty nothing tested: **`ffi/pointer-cfunction`**
takes a raw pointer out of a shared object and wraps it as a cfunction, and
every pointer it can be given is a C function. It cannot work any more. No
suite calls what it returns, so the change landed green; Phase 11 decides
between deleting it, making it raise, and giving it a thunk.

**Twenty-nine contracts define a cfunction in C, and eight call one.** This is
the part 17h was expected to reach and 17g could not avoid, because a contract
that cannot define a builtin cannot test the interpreter that calls one.
`test/support.zig` is the answer and is linked into the contract binary alone,
so nothing test-only reaches the runtime:

  - `janet_contract_call_cfunction` invokes one with the right convention and
    turns a returned raise into the jump `janet_try` already catches.
  - `janet_contract_cfunction` adapts a C probe into a Zig-ABI cfunction from a
    pool of sixty-four thunks, idempotent by identity in both directions, so
    `janet_unwrap_cfunction(x) == janet_contract_cfunction(probe)` means what
    `== probe` used to mean.

Seventeen contracts changed and none of their assertions did. 17h's
protected-call shim now has a place to live and a precedent for living there.

**And one selector broke in a way only a sweep finds.** `-Ddisasm=c` linked
against `_janet_c_disasm_keyword` and four of its neighbours, because
`asm_core.zig` imports `disasm.zig` by path and `asm-core` no longer has an arm
that would have picked the C disassembler instead. The matrix would not have
caught it: it samples one selector per layer, and `disasm` is not the sample.
What caught it was building all thirty-nine surviving arms one at a time, which
takes twenty-five minutes and is worth doing in the increment that removes
twenty-five of them. Rule 5's shape, one level up: an *arm* nothing selects is
not merely unreachable but unchecked.

### The benchmark, and the first regression this phase has given back

Two corpora, `ReleaseFast`, twelve stack layouts each with the minimum per
workload, each binary measured alone — rule 16's recipe. The baseline is the
commit before the type change, so what is measured is the 203 deleted abis and
the deleted per-call branch, not the twelve cfunctions 17g moved to Zig before
them.

**The Phase 9 corpus sees nothing**, which is what it is for: ten workloads
between +1.8% and −2.4% with the control at −1.0%. Seven of the ten lean
negative and so does the control, by the same amount, which is an offset rather
than an effect. Under the ±5% floor, so: no attributable change.

**The cfunction-entry corpus sees it.** This is `probe-17/bench`, built by 17b
for workloads that do as little work per call as possible, and it is the corpus
that caught 17e's regression when the Phase 9 one could not.

| workload | first reading | reversed | 
| --- | --- | --- |
| onearg | −4.3% | −2.6% |
| twoarg | −2.4% | −0.7% |
| threearg | −1.7% | −1.6% |
| **buffered** | **−10.0%** | **−8.3%** |
| optional | −0.3% | −0.5% |
| abstract | −4.2% | −3.5% |
| variadic | −2.3% | −1.3% |
| **control** | −0.4% | +0.2% |

**Seven of seven move the same way, twice, with the control flat both times.**
Five of the seven are inside the ±5% floor and prove nothing alone; what is
being read is the uniformity against a flat control, which is rule 7. Only
`buffered` is individually resolvable, and it is the workload with the highest
call density in the tree — two cfunctions per iteration, ten million
iterations, twenty million calls, and almost no work in either body.

Twenty million calls and about 18ms is **roughly a nanosecond per call**, three
or four cycles. Two things were deleted and both are in that range. The smaller
is 17e's protocol: a load and a test of `janet_vm.raising` after every
cfunction return, on every call, taken or not. The larger is more likely the
abi itself — a builtin was two functions, and at `ReleaseFast` some of those
wrappers inlined and some did not, so deleting all 203 removes a call layer
from an unknown fraction of them.

Part 17e measured **+5 to +8%** on the cheapest builtins on this same corpus
and attributed about two points to itself. 17g gives that back and a little
more, which is the first time this phase has recovered a regression it had
previously measured rather than merely failing to add one. It is also the
cleanest confirmation available that the flag was a cost and not just an
inelegance — which is what 17e claimed when it recorded the flag as a temporary
shape rather than a design.

## The hinge, and the end of the jump

Phase 10 Part 17h and 17i, which are one increment. They were separated so the
decision about the contracts would be visible rather than buried under a
`setjmp` deletion, and the separation did not survive contact: a contract
cannot stop using `setjmp` until nothing reachable from an assertion jumps, and
nothing stops jumping until the last fixed function-pointer types convert.

**The jump is gone.** No `setjmp`, no `longjmp`, no `jmp_buf` is compiled by
any configuration, and `raise.deliverToC` — which existed to turn a returned
error back into a jump — has no callers and no definition.

| | at 17h | now |
| --- | --- | --- |
| `setjmp` sites compiled | 2 | **0** |
| `longjmp` sites | 1 | **0** |
| `raise.deliverToC` sites | 1 | **0** |
| `//! jump-transparent` files | 62 | **0** |

### The mechanism was `janet_try_init` with nothing after it

Both remaining scopes were the same shape, and both dissolved the same way.
`janet_zig_ev_protect` was nine lines of `ev.c` holding the scope `ev/thread`'s
child interpreter runs under; `janet_continue_no_check` was the one every fiber
resume re-establishes, and it had stayed in `src/core/vm.c` since Phase 7
because it held the `jmp_buf` and a Zig function cannot hold one.

What replaced them is nothing:

```zig
var tstate: c.JanetTryState = undefined;
c.janet_try_init(&tstate);
const sig = vm_run.runVm(fiber, in) catch c.janet_vm.pending_signal;
c.janet_restore(&tstate);
```

**`janet_try_init` was always the scope; the `setjmp` was only travel.** It is
what points `janet_vm.return_reg` at `tstate.payload`, and therefore what makes
`janet_signal_plan` answer `RAISE` instead of `TOP_LEVEL`. The signal a raise
carries is in `janet_vm.pending_signal`, which is where `longjmp`'s second
argument used to put it and where `janet_zig_signal_record` has written it since
Part 2. Both readings are unchanged. Only the travel is gone — and the travel
was the part that skipped `defer`.

`vm_run.zig` and `vm_entry.zig` now import each other, which Zig allows because
Part 17a made them one module. That import is the whole of what replaced the
`janet_run_vm` abi: `JOP_RESUME` reaches the hinge by name, the hinge reaches
the loop by name, and `raise.Error` crosses both ways.

### A `noreturn` abi is a lie the header tells the caller

Twenty-two exported abis were `JANET_NO_RETURN`: the four `janet_panic*`
entries, `janet_signalv`, the two slot diagnostics, `janet_await`,
`janet_sleep_await`, `janet_async_start`, `janet_ev_threaded_await`, and the
eleven `janet_ev_*` read and write entries by which a fiber suspends. None can
be `noreturn` without a jump — the only way to tell a C caller without
returning *was* the jump — so each became a reporting abi over `raise.report`.

**Converting the Zig definitions built silently, and that is the finding.**
`@cImport` reads `janet.h`, so Zig went on compiling every caller against
`JANET_NO_RETURN`: the code after `c.janet_ev_recv(...)` was unreachable, the
missing `return` was not an error, and `try raise.crossing(c.janet_panics(...))`
type-checked because nothing after the call was analysed. The build was green
with five cfunctions falling off the end of a `Raising(Janet)`.

Stripping `JANET_NO_RETURN` from the twenty-two declarations turned that into
six compile errors naming their own sites. The rule generalises past this
increment:

> **A `callconv(.c)` signature has two halves in two languages, and Zig
> believes the header.** Changing the Zig definition of an exported symbol
> without changing its C declaration is not a partial change; it is a silent
> one, and `noreturn` is the attribute where silence is total.

The eleven `janet_ev_*` entries then stopped being crossings at all.
`net_sockets.zig` had been reaching `ev_stream.zig`'s read and write state
machines through their exported C symbols — eleven calls whose raise was a jump
even though both sides were Zig and both were in one module since 17a. They are
`try ev_stream.readGeneric(...)` now, which is rule 19 once more: the fix for a
crossing is not a check, it is an import.

### `-Dcall-trampoline` was the last configuration that compiled a `setjmp`

Not a selector this increment expected to spend. Phase 7 built the trampoline —
a per-call `setjmp` scope so that a callee's signal was caught one frame below
`run_vm` rather than jumping past it — and Part 17e removed the last of its
thirteen callees when each began returning its raise. What nobody checked
afterwards is what the flag still *compiled*: `JanetVmTryState`, `vm_scope_enter`,
`vm_scope_leave` and `vm_scope_setjmp` sit in `src/core/vm.c` outside the
`JANET_ZIG_VM_RUN` guard, so `-Dcall-trampoline=true` still built them.
`nm` on that binary showed an undefined `__setjmp`.

So the arm could not survive the exit gate however green it was, and it went
the way 17g's twenty-five went. Its Zig side — the `if (!trampoline)` branches
in `raiseSignal` and `raisef`, and `janet_vm_error_string` behind them — went
with it.

**This is rule 9 from the other end.** That rule says a long-held rule is the
one least likely to be re-examined. This is the same about a *configuration*: a
flag that selects nothing still compiles something, and "it builds and passes"
is not evidence that it selects anything. The build-only sweep is what would
have caught it earlier, and it is cheap — 29 arms, about eight minutes.

### The contracts, and a test the type system retired

The cascade reached `test/` as predicted: 26 `EXPECT_PANIC` macros across 16
files and 9 hand-written scopes in `test/signal_core.c`. All of them were
already dual — `janet_try` for a jumped raise, `janet_contract_arm` /
`janet_contract_raised` for a reported one — so the rewrite deleted the jumped
half and kept the reported one. `janet_contract_protect` in `test/support.zig`
replaces the deleted `ev.c` shim, which `test/ev_loop.c` had been naming
directly.

One test did not survive, and it is worth recording as a behaviour change
rather than a repair. `test/vm_calls.c` drove `janet_fill_table` through an
abstract whose `hash` callback called `janet_panic`, and asserted the table was
left empty. It worked because the jump left `janet_table_put` from inside a
callback whose signature had no way to report failure. The hinge typed `hash`
non-raising — `abstract_type.zig` gives the reason, which is that `hash` is
reached from comparisons that must be total — so with the jump gone the
callback has no way out at all. The case is not a behaviour this runtime has
any more. It is deleted, with the reason at the site, and `EXPECTED_PANICS`
went 13 to 12.

> **A type that says a callback cannot fail also says a test cannot make it
> fail.** Rule 12's converse: narrowing a signature retires the tests that
> depended on the width, and they should be deleted with their reason rather
> than adapted into testing something else.

### One rename, and one deletion deferred on purpose

`JANET_FIBER_DID_LONGJUMP` is `JANET_FIBER_DID_RAISE`. The flag means "a raise
unwound past here" — it is read on the next resume to pop a C frame and to turn
a raise at a tail call into an implicit return — and it outlived the mechanism
it was named after by exactly one increment. `fiber.h` records the old name at
the definition, because that is where someone reading a Janet 1.x diff will
look for it.

The `setjmp` *text* in `asm.c` and the unused `jmp_buf` field in `marsh.c` are
deliberately still there. Neither is compiled by any configuration — `asm.c`'s
selector went in 17g — and the exit gate's "anywhere in the tree" clause does
reach them, but they go **with their files** rather than on their own. The
decision behind that is wider than this increment: the goal is that no `.c`
file survives the phases, so the dead C is deleted wholesale in Part 18 rather
than region by region as each selector is spent.

### What the matrix caught that nothing else did

One defect, and it is a good advertisement for the instrument. `continueNoCheck`
transcribes the C original's `JOP_NEXT` arm, which uses `janet_wrap_integer(0)`
— and `janet_wrap_integer` is the one declared `janet_wrap_*` with no definition
under `-Dnanbox=false`. `janet.h` defines it as a macro unconditionally, so no C
caller ever references the symbol and `wrap.c` never noticed; `@cImport` cannot
use a function-like macro, so Zig gets the declaration and calls it.

The default build was green, all 34 suites were green, all 29 selector arms
built, and all five cross-compiles passed. Only `-Dnanbox=false` failed to link.
`value_access.zig` had already met this and written the macro out with the whole
account attached; `FOUND.md` has the defect. The port reproduces the gap rather
than fixing it, because `-Dvalue-wrap` still has both arms and the two must have
the same symbol set.

### What it measured

`panics.py` is **unchanged at 3**, and that is honest rather than
disappointing: this increment removed the jump, not the remaining C. The three
are two in `capi.c` — inside `janet_panicf`, which is a C-variadic shell Zig
0.16 cannot define — and one in `abstract.c`.

The Phase 9 corpus, both binaries measured alone across twelve stack layouts,
minimum per workload, control read first:

| workload | base | hinge | |
| --- | --- | --- | --- |
| **pegmatch (control)** | 0.039098 | 0.038635 | **−1.2%** |
| **fibers** | 0.028032 | 0.025409 | **−9.4%** |
| arithmetic | 0.047283 | 0.047914 | +1.3% |
| compiler | 0.045196 | 0.044467 | −1.6% |
| fib | 0.016413 | 0.016389 | −0.2% |
| methods | 0.018568 | 0.018724 | +0.8% |
| opfallback | 0.016167 | 0.016318 | +0.9% |
| pegcall | 0.006525 | 0.006407 | −1.8% |
| strings | 0.050967 | 0.050181 | −1.5% |
| tables | 0.055543 | 0.055428 | −0.2% |

The control at −1.2% says the corpus resolved. One workload clears rule 16's
±5% floor and it is an improvement: `fibers`, at −9.4%, on exactly the path
this increment changed. Every fiber resume used to establish a `setjmp` in
`janet_continue_no_check` and no longer does. Rule 16's cheap confirmation —
ask what the changed lines are reachable from — holds it up without a re-run.

The acceptance matrix is **50 PASS, 1 FLAKY, 0 FAIL**, the FLAKY being
`x86_64-macos` hanging once and passing on retry, with 37 GB free and no
snapshots. The build-only sweep over all 29 surviving `c` arms is clean.

## The variadic surface, and the first Zig contract

*Phase 10 Part 18, in part. The gate's deletion is what this increment cleared
the way for; what it did itself is remove the four C variadic functions and the
`va_list` machinery under them.*

### What was actually left

Part 17's hinge ended the phase's headline risk and left 637 live lines of C
under `src/core`. Reading them rather than counting them showed the residue was
not spread evenly: most of it was *declarations* of Zig-defined symbols, and
the genuine C definitions clustered on one thing.

| function | site | live C callers | Zig call sites |
| --- | --- | --- | --- |
| `janet_panicf` | `capi.c` | 0 | 0 |
| `janet_formatc` | `pp.c` | 0 | 37 |
| `janet_formatb` | `pp.c` | 0 | 3 |
| `janet_dynprintf` | `io.c` | 8, in `vm.c`'s trace pair | 5 |

Around them: `janet_formatbv`'s `va_copy` shim, six three-line
`janet_zig_va_next_*` accessors, and `janet_zig_std{in,out,err}`. `pp.c`'s own
comment stated the constraint precisely and had done since Part 4 — Zig 0.16
cannot name a `va_list` on `aarch64-linux`, where `std.builtin.VaList` is a
`@compileError("disabled due to miscompilations")` under the LLVM backend, and
it cannot define a variadic function without `@cVaStart`, which returns the same
type. Measured across the six targets this project builds for, a
`@cVaStart` definition compiles on four and is refused on `aarch64-linux` and
`x86_64-windows`.

So the shells could not be ported. The observation this increment rests on is
that they did not need to be: **every caller was a Zig caller already, and every
one of them was carrying a tuple and flattening it into C's calling convention
on the last line.**

```zig
pub fn panicf(comptime format: [*c]const u8, args: anytype) Error {
    const message = @call(.auto, c.janet_formatc, .{format} ++ args);
```

`raise.panicf`, `compiler_primitives.lintf`, `peg.pegPanicf`,
`core_env.eprintf` and `trace_frames`' copy of it all had that shape. The
`va_list` was a round trip that started and ended in Zig.

### Indexing instead of pulling

`pp_format.zig` had to **pull** its arguments: `janet_zig_formatbv` took the
`va_list` as an opaque pointer it never dereferenced and asked C for the next
argument of whatever type the specifier it had just parsed called for. That
order was forced, and the file said so — only the engine knows what type comes
next, because only the engine has parsed the format string.

A tuple can be indexed, and the index has to be comptime, so the parse moves to
comptime too. `compileFormat` walks the format string once and returns a list of
steps:

```zig
const Op = union(enum) {
    literal: []const u8,
    conversion: struct { spec: Specifier, conversion: u8, arg: usize },
};
```

`formatTuple` then `inline for`s over them. `formatc`, `formatb`, `panicf` and
`dynprintf` sit on top, and the six accessors, the `va_copy` shim and the four C
functions are gone. **`pp.c` has no live line left.**

### The check was the point, and it found two defects

Every conversion coerces with `@as`, so the specifier and the value are checked
against each other at the call site. `FOUND.md` carried four entries that were
all the same mistake — a caller passing a type the conversion does not read —
and `raise.panicf`'s own doc comment had warned about it: *"It is not
type-checked: `%d` takes an `int32_t` and `%v` takes a `Janet`, and passing the
wrong width is undefined rather than merely wrong."*

Two of them stopped compiling.

**`vm_run.zig`'s `_vm_bitop` message.** `"rhs must be valid 32-bit signed
integer, got %f"` was passed `op2`, a `Janet`, where `%f` reads a `double`.
`FOUND.md` had measured it printing `0.000000` on x86-64 — the System V
classification sends the union through a general-purpose register while
`va_arg(double)` reads the SSE save area — and had named `y2` as the value the
message wants. Reachable as `(band 1 1e20)`. Part 8's rule decides it: undefined
behaviour has nothing to reproduce, so the port gets it right.

**`args_core.zig`'s three `int64_t` indices to `%d`.** The comment there said
they were "reproduced here rather than repaired". They no longer are, and the
reason is worth keeping: **the narrow read was the `va_list`'s, not the
conversion's.** `scanFormat` had always rewritten `%d` to `%lld`, so the
specifier asked `snprintf` for 64 bits; C's `janet_formatbv` pulled an `int32_t`
and widened it because that is what its `va_arg` said. With no `va_list` there
is nothing to mismatch, and `%d` renders `@as(i64, arg)`.

`dynprintf` also picked up a `defer` that closes two buffer leaks C could not
have closed in place — one of them left through the `longjmp` decision 1
replaced.

### Where the raise cannot go

Eleven call sites in six files could not take an error: an abi, or an
internal result type whose error channel is a message pointer rather than an
error union. They are rule 11's population — a raise converts as far as the
nearest fixed boundary and stops there — and they go through
`pp_format.formatcReported`, which is `raise.reported` over `formatc`. That is
what the variadic shell already did, since `janet_zig_formatbv` was a panicking
abi; what changes is that the site says so. Rule 19 names what retires them,
and it is an ordinary import rather than a report.

### The first Zig contract, and why there had to be one

`test/pp_format.c` asserted 53 cases against `janet_formatc`. Its subject no
longer has a C name: `formatTuple`'s format string is a `comptime` parameter, so
a caller does not call it, a caller **instantiates** it.

That is the same position a subsystem was in before Part 17a, and it has the
same answer — be inside the compilation. A Zig contract is its own module rooted
at `test/<name>.zig`, importing the subsystem under test as `subject`. What
keeps it honest is the `options` module `build.zig` gives it, in which **every
selector is `false`**:

- the neighbours resolve to their `_extern.zig` shims and bind to the real
  `libjanet.a` — `printer` is `pp_extern.zig`, `containers` is
  `buffer_array_extern.zig`;
- the subsystem's own `@export`s are suppressed, so nothing collides with the
  library's definitions.

That second half needed five `export fn` declarations in `pp_pretty.zig` and
`pp_describe.zig` to become gated `@export`s in a `comptime` block. It is the
correct shape independently: `root.zig` already gates the *import* on
`options.pp`, and now the exports follow the same flag.

Only generic code compiles locally, because only generic code has to. The
exception is stated in the contract's header: `pp_format.zig` reaches
`pp_pretty.zig` by path rather than through a façade, because the internal seam
carrying width, start length and barrier has no C name — so the pretty
conversions run a local copy that shares its source with the runtime's and its
state through `janet_vm`. What is untested there is a link, not a behaviour.

### Six assertions that became compile errors

The C contract asserted seven refusals this file cannot: `"%z"`, `"%5z"`,
`"%ld"`, `"%-+ #0-d"`, `"%123d"` and `"%.123f"` were runtime panics out of
`scanFormat`, and against a `comptime` format string `comptimeScan` raises them
with `@compileError`. The case cannot be written down.

They are not lost, and where they went is the useful part. **Every one is still
reachable through `bufferFormat`**, which keeps the runtime parser because
`string/format` takes its format string from Janet source — and that is the loop
a user can actually reach them on. `theGrammarFaults` asserts all six there.
The comptime half is covered by construction.

Three other contracts touched the deleted symbols and did not need to move
wholesale:

- **`test/io_core.c`'s `test_dynprintf`** moved into the Zig contract with its
  subject. `dynprintf` left `io_core.zig` for `pp_format.zig` in the same
  step — it is one of the four entry points that surface held, and keeping it
  in `io_core.zig` would have meant compiling the whole io surface into the
  contract's module. It takes three symbols from there through the C ABI:
  `janet_zig_io_assert_writeable`, `janet_io_write` and `janet_file_type`.
- **`test/signal_core.c`'s one `janet_panicf`** moved beside the engine that
  builds its message.
- **`test/pp_pretty.c` stayed C**, with a one-line change. Its `pretty_width`
  helper builds a format string at *runtime* from a width and a flag set, so it
  cannot reach `formatTuple` at all — but the loop that takes a runtime format
  string is the array one, and `janet_buffer_format` is `string/format`'s own.
  The two loops share `renderPretty` outright and set the start length and
  barrier the same way, which the Zig contract asserts directly.

`port/contract.sh` and `port/matrix.py` each learned one thing: when
`test/<name>.zig` exists, link `janet-contract-<name>.o` instead of compiling
`test/<name>.c`. `build.zig` installs it beside `janet-contract-support.o`, for
the same reason that one is installed.

### What went with it

`src/mainclient/shell.c`, the `janet-c` target and the `run-c` step.
`PLAN.md` had it down to be deleted rather than ported, and this is where it
became unavoidable: the shell was `janet_dynprintf`'s last caller outside the
runtime. There has been nothing to compare it against since Part 17g anyway —
a cfunction is a Zig function, so no configuration builds a C client.
`vm.c`'s `vm_do_trace` and the two functions over it went too, to `vm_run.zig`
as `traceFiber` and `traceArgv`; there are two of them for the reason C's
comment gave, which is that `janet_eprintf` can resize a fiber's stack, so
`fiber->data + fiber->stackstart` is recomputed per element.

`janet.h` lost five declarations and the `janet_printf`/`janet_eprintf` macros;
`state.h` lost two.

### Instruments

34 suites pass and so does `zig build test`; five cross-compiles are clean; the
build-only sweep over all 29 surviving `c` arms is clean; `panics.py` reads
**3 → 1**, the one that remains being `abstract.c`'s. The acceptance matrix is
**26 PASS, 0 FLAKY, 0 FAIL** in 205.8s.

It took two runs, and the first is the interesting one. `tagged values` failed
at `cc pp_format` on an undefined `janet_wrap_integer` — `janet.h` declares it
beside its macro and `wrap.c` defines it only for the two nanbox layouts, which
`value_access.zig`, `filewatch_core.zig` and two others already write out by
hand with the reason at the site. The contract had called the declaration.

The symbol is not the lesson. **A C contract reaches `janet.h`'s macros; a Zig
one reaches its declarations** — so moving a contract to Zig acquires every
`@cImport` hazard a subsystem has, and owes rule 13's matrix entry for the same
reason a subsystem does. Nothing cheaper would have found it: the default build,
`zig build test`, the contract run and all five cross-compiles were green, and
it is a *configuration* rather than a target.

The benchmark corpus is not run. Rule 16's cheap confirmation applies instead —
ask what the changed lines are reachable from — and no workload in the Phase 9
corpus formats a string or takes a raise. What is at stake is code placement,
which that rule says a re-run cannot settle anyway.

## The last of the C, and the end of the selectors

*Phase 10 Part 18, the rest of it. The variadic surface went first; this is
what followed, and it ends with no `.c` file under `src/`.*

### Forty symbols, not forty-four files

The instinct was to start deleting files. The useful measurement was the
opposite one — `ar x` the archive and ask `nm` what each object actually
*defines*:

| object | symbols |
| --- | --- |
| `asm.o` | 15 |
| `abstract.o` | 12 |
| `strtod.o` | 4 |
| `io.o` | 4 |
| `runtime_bridge.o` | 2 |
| `os.o`, `math.o`, `capi.o` | 1 each |

**Eight objects, forty symbols.** The other thirty-six `src/core/*.c` files
contributed nothing at all: everything in them was already behind a spent
guard, and what looked like 519 live lines was mostly *declarations* of
Zig-defined symbols. That reframed the work from "port a subsystem" to "port
forty functions", and every one of them turned out to be small.

### What each of the forty was, and why it had been C

Four groups, and none of the reasons survived contact.

**Wrappers over a macro.** Twenty-six of the forty. `asm.c` kept fourteen
one-line `janet_c_asm_*` and `janet_c_disasm_*` wraps, `strtod.c` three, and
they existed because a selector's `c` arm had to share the runtime's own
`janet_wrap_*` macros. Every one of those is an ordinary exported function as
well as a macro — except `janet_wrap_integer`, which four subsystems already
write out in three lines and which `FOUND.md` has an entry for. So the wraps
are one line of Zig each.

`asm.c` also carried a **second copy of the entire opcode table**, for the
reverse lookup disassembly needs. `asm_encode.zig` has had that table since
Phase 5 — it is what the assembler matches names against — so the duplicate
went and the lookup is a walk over the original.

**Host structures.** `abstract.c`'s twelve lock entry points are
`os_locks.zig` now. `abi.zig`'s translation of `janet.h` already reaches
`<pthread.h>`, so `pthread_mutex_t`, `pthread_rwlock_t`,
`pthread_mutexattr_t` and `PTHREAD_MUTEX_RECURSIVE` are all nameable; the
Windows arm is four `kernel32` calls over a `CRITICAL_SECTION` and an
`SRWLOCK`. `janet_os_mutex_unlock` was **the last `janet_panic` call site
compiled into C anywhere in the tree**, and it is a returned raise now.
`panics.py` reads **0**.

**Macros translate-c cannot render.** `io.c`'s three standard handles were the
clearest case in the tree of a constraint that had stopped being examined.
`stderr` is a macro rendered three incompatible ways — an inline function on
macOS, an opaque-typed variable on musl, a container-level constant calling an
extern function on mingw, which Zig rejects outright. All three are facts about
the *translation*. Underneath the macro every one of these libcs has an
ordinary extern object or function, and `stdio.zig` names those:
`__stdoutp` on Darwin and the BSDs, `stdout` on glibc and musl,
`__acrt_iob_func(1)` on the UCRT. Verified on all six targets and by writing
through the handle on the host. Rule 3 is what this is — *a host structure
stays in C only when translate-c cannot give it to us* — and the answer was to
stop asking translate-c.

`JANET_MODULE_ENTRY` and `JANET_OUT_OF_MEMORY` are the same shape and went the
same way, into `native_module.zig` and `fatal.zig`.

**`struct stat`, which is the one real exception.** Part 12 measured it and was
right: musl declares `struct timespec` with a bitfield, translate-c demotes any
record holding one to `opaque {}`, and `struct stat` embeds three. macOS and
mingw translate it completely, which is what makes it easy to miss.

Zig's own standard library was checked before anything was written, and does
not supply a replacement: `std.posix.Stat` is `void` on Linux and Windows,
`std.posix.fstat` and `fstatat` do not exist in 0.16, `std.os.linux.Stat` was
removed, and `std.Io.File.Stat` carries nine fields where `os/stat` reports
fifteen — no `dev`, `uid`, `gid`, `rdev` or `blocks`, and `std.Io` has setters
for owner but no getter anywhere. What Zig *does* supply on Linux is
`std.os.linux.Statx`, which has every field.

So `host_stat.zig` is `statx` on Linux and `@cImport` elsewhere, and it is the
tree's fifth translation of host headers. One value in it is computed rather
than copied — `statx` reports the device as a major and a minor, so `dev` and
`rdev` are recombined with the kernel's `new_encode_dev`, which is what
glibc's `makedev` and musl's both produce. `test/os_stat.c` checks it by the
property a program relies on rather than by pinning the number: two files on
the same filesystem report the same `dev`.

### Then the selectors, and then the files

With the forty gone, every `src/core/*.c` file defined nothing, and the only
remaining reason to compile one was a `-D<sel>=c` arm. **Twenty-nine spent at
once**, along with `SubsystemImplementation` itself — `zig build -h` reports no
`(c or zig)` option at all. Then `core_sources` left `build.zig`, and then the
files: **44 files, 38,558 lines.**

`src/boot/boot.c` and its five smoke tests went too, to `src/zig/boot.zig` and
`boot_tests.zig`; `boot.c` held the last `main` written in C anywhere under
`src/`. They live beside `cli.zig` rather than in `src/boot/` because a module's
imports resolve beside its root — `src/boot/` holds the bootstrap *script*,
which is what its name was always about.

**The Zig generator emits a byte-identical image.** `phase_11.md` asks for a
second thing to be reproducible against, since Part 17g spent the C generator
and left the image with nothing to compare to. Two cached `janet-image.c` from
either side of this change are identical, 2,007,197 bytes, which is that
differential recovered for free.

Last out was `src/zig/interop_bridge.c`, which had survived since Phase 2 on
two reasons that had both expired: `janet_wrap_integer` is a macro a Zig caller
could not use, and a protected scope was a `setjmp`. The hinge replaced the
second and four subsystems had already written out the first.

### What the contracts caught

Two, and both were real.

**`test/os_surface.c` on the zeroing order.** The C zeroes the `numbers` array
*after* the syscall succeeds; the port zeroed before, so a failed stat wrote
zeros where the C left the caller's buffer untouched — which that contract
asserts explicitly. Zeroing first is the obvious way to write it and is wrong.

**The Windows `struct stat` pairing**, from the cross-compile. mingw has no
`struct__stat` in the translation; `struct_stat` and `struct__stat64i32` are
the same 48 bytes and translate-c declares `stat` and `fstat` directly, so
Windows goes through the translation rather than the `@extern` name table
Darwin needs for `stat$INODE64`. Nothing else would have found it.

### One more the matrix caught, and it is the better example

`-Dev=false` did not build. `os_locks.zig` reached `pthread_mutex_t` through
`abi.zig`, and `abi.zig` sees `<pthread.h>` only because `janet.h` includes it
*for the threaded event loop*. A probe on the host had confirmed the types were
reachable, and it was right — for that configuration.

Five cross-compiles, `zig build test` and ten contracts were green. Rule 13 is
the one that names it: **a configuration is as much an uncompiled arm as a
platform is**, and only the matrix samples configurations. The fix is a sixth
translation of host headers, `<pthread.h>` alone, kept inside `os_locks.zig`
under rule 3 — every caller passes a `JanetOSMutex *`, which `janet.h` declares
opaque, so nothing it declares crosses a boundary.

The other failure was mine rather than the code's: `asm_decode` and `disasm`
cannot compile without an assembler, which is what `skip=` is for. Rather than
fix the one the matrix named and rediscover the rest a run later, all twelve
contracts were compiled against all four reduced configurations by hand — four
builds, forty-eight invocations, two minutes — which returned the whole list at
once. `phase_10.md`'s rule 31 has it.

### The gate

No `.c` file remains under `src/`. No `setjmp`, `longjmp` or `jmp_buf` appears
in any code — the 76 remaining occurrences are prose in this file, recording
why the rule existed. `panics.py` is 0, 34 suites pass, `zig build test`
passes, five cross-compiles are clean, the `x86_64-macos` build runs under
Rosetta with `os/stat` and the directory test agreeing with the native one, and
the acceptance matrix is **21 PASS / 0 FLAKY / 0 FAIL**.

## A contract inside the compilation

*Phase 11 Part 1.* The phase that takes `test/`'s C opens with the question of
what a Zig contract *is*, and the answer is worth more than the nine files that
came with it, because the remaining fifty-three are all shaped by it.

### Two readings of "the contracts are Zig"

`phase_11.md`'s clause pairs two things: migrate the contracts, and delete the
reporting abis. It is one piece of work because a C contract reaches a
raise-capable function through its abi and reads the result with
`janet_contract_raised`, so neither half moves alone.

The straightforward reading — translate each `test/*.c` into a `test/*.zig`
that links `libjanet.a` — reaches the gate and nothing else. Part 17a's
argument does not care which language the caller is written in:

```text
error: return type 'error{X}!i32' not allowed in function with calling
convention 'aarch64_aapcs_darwin'
```

A caller on the far side of a symbol table gets a symbol, a symbol has a
calling convention, and the raise still has to travel out of band. The abis
would have survived the migration in full.

So a Zig contract is compiled *into* the runtime instead. `makeRuntimeGraph` —
the module graph `makeZigRuntimeObject` used to build inline — is now built
twice: once wrapped in the object the library and the client link, and once
with `test/contracts.zig` as the root and the subsystems as a named import. A
contract reaches its subject with `@import("subsystems")`, and a raise crosses
as `error.JanetSignal`, checked.

What that costs is one more compilation of the runtime, about eight seconds,
against sixty-odd C translation units it will eventually replace.

### What was rejected had already shipped

Part 18 built `test/pp_format.zig` a different way: its own module beside
`libjanet.a` with every selector `false`, so the subject's neighbours resolved
to their `_extern.zig` shims and its own `@export`s were suppressed. That
worked, and two things made it wrong to generalise.

It has an entry price. A subject whose exports are `export fn` declarations
cannot be used until they become gated `@export`s in a `comptime` block — which
is why, in the increment that introduced it, the mechanism reached exactly one
file.

And what it compiles is a **local copy**. `pp_format.zig` imports
`pp_pretty.zig` by path, so `%q` and its seven siblings ran a second instance
of the pretty printer, sharing the runtime's state through `janet_vm` and its
source through the file system but not its code. The comment in that file said
so and called it "a link, not a behaviour", which was true of a
`comptime`-generic subject with no symbol either way. It is not true of a
collector or an interpreter.

`pp_format` moved onto the new driver in the same increment and `includeZig`
is gone, so the tree carries one kind of Zig contract rather than two — and
that contract now tests the printer the rest of the binary runs.

### The scope is not a formality, restated from the other side

`test/support.zig` worked this out for C and `test/harness.zig` needs it again:
`janet_signal_plan` answers `TOP_LEVEL` when `janet_vm.return_reg` is null, and
a `TOP_LEVEL` raise ends the process rather than reporting. So `harness.raised`
brackets the call in `janet_try_init` and `janet_restore` even though nothing
jumps. **The `setjmp` was never the scope; it was only the travel** — and the
converse, that removing the jump removed the scope, is the mistake this note
exists to prevent.

Everything else in `support.zig` does go: the cfunction adapter pool, the
abstract-type pool, the four callback shims and the `arm`/`raised` protocol are
all machinery for moving a raise or a Zig-ABI function pointer across the C
ABI, and there is no C ABI to cross. `harness.zig` is a ninth of its size and
most of what remains is convenience — `isType`, `equals`, `stringIs` — rather
than mechanism.

### The two things the driver had to be taught

**Nothing referenced the runtime, so the link failed on `janet_init`.**
`root.zig` emits every subsystem's exports from a container-level `comptime`
block, and a module nothing references is never analysed. `test/contracts.zig`
carries `comptime { _ = @import("subsystems"); }` for exactly that.

**The namespace beside it must stay lazy.** `root.zig` gained a flat block of
`pub const <subsystem> = @import("<subsystem>.zig");`, and a `pub const` at
container scope is analysed only when something references it. That is what
lets `-Dpeg=false`, `-Dffi=false` and `-Dev=false` go on building: the
`comptime` block skips the import, no contract names `subsystems.peg`, and the
declaration is never looked at. A `comptime { _ = ... }` over that block would
make every name eager and break three configurations at once.

### What the instruments found

The build-only sweep, which `AGENTS.md` prescribes as the cheap check before
the matrix, earned its place on the first run. `-Dnanbox=false` failed to link
`janet_wrap_integer` in `os_environ` and `os_permissions` — `janet.h` declares
it beside a macro of the same name and the runtime defines the function only
under the two nanbox layouts, so C callers get the macro and `@cImport` prefers
the function. This is the third time that symbol has done it and the second in
a contract; `harness.wrapInteger` now holds the three lines and the argument.
The general form is already written down for the previous occurrence: **a
contract that moves to Zig acquires the whole `@cImport` hazard list.**

Nothing else failed. Four cross-compiles, twelve reduced configurations and the
tagged build's contracts are clean, and the acceptance matrix is **21 PASS / 0
FLAKY / 0 FAIL** in 184.7s wall.

### One guard added

Migrating a contract is five edits across four files — delete `test/<name>.c`,
drop its line from `build.zig` and from `test/contracts.h`, write
`test/<name>.zig`, add its line to `test/contracts.zig`. Forget the last and
**the tree is green with a contract that never runs**: the C driver no longer
compiles it and the Zig driver never heard of it.

`checkContractsListed` in `build.zig` reads `test/` at configure time and
refuses to build when a `.zig` file there is not named in the driver. It is
deliberately crude — a substring search, in the manner of the retired
`checkJumpTransparency` — because what it looks for is a file nobody has
mentioned at all. Fifty-three migrations remain; this is the mistake that would
otherwise be made silently in one of them.

### The nine

Eight moved from C and one — `pp_format` — moved driver, which is why `test/`
lost eight `.c` files rather than nine. `vector`, `intscan`, `textscan`, `regalloc`, `movopt` and `remove_noops` are
leaf subjects reached by symbol, and they are close translations. `os_environ`,
`os_permissions` and `pp_format` are where the arrangement shows: each calls
core cfunctions directly with `try`, and the first two gained a `theRefusals`
section their C originals did not have — a refusal was reachable in C only
through the flag protocol, or, in `os_permissions.c`, by compiling a Janet
closure with `janet_dostring` and calling it under `janet_pcall` "so they stay
off stderr". Three lines and a wrapper per case in C; one line here. **Migrating
is not transcription**, and the contracts that come out of it assert more than
the ones going in.

## The bytecode group

*Phase 11 Part 2.* The first ordinary increment of the migration. Part 1
decided what a Zig contract is; this one spends that decision on four
contracts and settles the vocabulary the rest will use.

The four are one subject seen from four sides — `asm_encode` produces
bytecode, `asm_decode` reads a word back, `disasm` renders a whole function,
`verify` decides whether a function is legal at all — and three of them share
the `-Dassembler` condition, which is what makes them a group rather than four
files that happened to be adjacent in a list. It also means the increment
exercises the driver's conditional gating: `-Dassembler=false` has to drop
three of the four and keep `verify`.

### One `c_int` that would have been found forty times

All four build bytecode words by hand, and all four failed the same way on the
first build:

```text
error: type 'c_int' cannot represent integer value '4294966784'
    const jmp = decoded(c.JOP_JUMP | (@as(u32, 0xFFFFFE) << 8), 2, "jmp");
```

`janet.h`'s `JOP_*` are enumeration constants, so translate-c gives them
`c_int`, and mixing one with a `u32` shift yields a `c_int` expression that
cannot hold its own value. Five sites in one build — and `vm_run`,
`vm_calls`, `emit_core` and `compiler_primitives` are all still to come.

`harness.op` is the widening cast, written once with the reason at it. The
general point is not about that constant: **a group is the right place to
discover the shared surface, and the first group is the right group**, because
the alternative is finding it in the fortieth file and going back through
thirty-nine. The same increment moved `integerIs`, `symbolIs`, `keywordIs`,
`stringValueIs` and `field` into the harness; each had been a `static` helper
copy-pasted into every C contract that needed it.

### What the C contracts could not say, and these do

`asm_encode` keeps all eighteen refusal messages verbatim, and that is a
deliberate call rather than transcription. `janet_asm` reports by filling in
`JanetAssembleResult.error` rather than by raising, so **the message is a
return value and part of the interface** — a port that reworded one would be
changing observable behaviour and nothing else in the tree would notice.

`verify`'s fifteen numbered refusals are the same kind of thing: a caller
distinguishes them by number, so the numbering is contract. Neither of these
needed the new mechanism — both subjects are non-raising C-ABI exports — which
is worth saying plainly: **most of the remaining migrations will not need it
either.** The mechanism exists for the ones that do, and the abis
cannot go while any contract still needs them.

### The sweep grew a step

Part 1's build-only sweep established that twelve reduced configurations
compile. Part 2 ran the contract binary in each of them, which costs seconds
and asks a different question — `-Dnanbox=false` compiling says nothing about
whether the tagged layout answers the same values as the boxed one. Nothing
failed. The upgrade is cheap enough that it should not have waited for
something to fail, and it is now the standing shape.

### Verified to be capable of failing

Both intricate contracts were perverted and re-run before being believed: one
refusal number changed in `verify.zig`, one refusal message in
`asm_encode.zig`. Each failed naming its own line. This is worth doing here in
particular because `asm_encode` asserts eighteen exact strings through a single
`refused` helper — if that helper were subtly wrong, all eighteen would pass
vacuously and the file would look like unusually thorough coverage.

Four cross-compiles, eight reduced configurations run rather than built, 41
suites, and the acceptance matrix at **21 PASS / 0 FLAKY / 0 FAIL** in 170.5s.

## The OS group

*Phase 11 Part 3.* `os_platform`, `os_time` and `os_fs`. Two of the three
translated straightforwardly; the third could not be translated at all without
becoming circular, and that is the part worth reading.

### An oracle a migration can lose

`test/os_platform.c` computed what the platform *ought* to be from a
seventy-line chain of `#if defined(JANET_APPLE)` and its kin — the C
preprocessor's view of the target — and compared that with what
`os_platform.zig` derives from Zig's `builtin`. Two independent descriptions of
one fact, which is what a contract is for.

That oracle is unavailable here, and by rule rather than by inconvenience.
`AGENTS.md`: *test the platform with `builtin.os.tag`; read only what the build
wrote into `janetconf.h` with `@hasDecl`* — because a `JANET_*` macro derived
from the compiler's own predefines is unreliable through `@cImport`. Aro
predefines `__unix__` for `x86_64-windows-gnu`, so the *translation* of
`janet.h` says `JANET_POSIX` where the *compilation* of it says
`JANET_WINDOWS`. A Zig contract reading those macros would be checking a
description already known to be wrong.

So the straightforward translation of this file asserts `builtin` against
`builtin`. It passes, it is fast, and it establishes nothing — the worst
possible outcome, because it *looks* like coverage.

**`uname` is the replacement, and on the platforms this project runs it is the
better oracle.** It describes the machine the process is executing on rather
than either compiler's belief about the target, so it catches the failure that
actually matters — a build that thinks it is Linux while running on macOS — and
it stays correct under Rosetta, where an `x86_64-macos` binary genuinely is an
x86_64 process. Where it cannot speak, the assertion is **skipped rather than
faked**: an unrecognised sysname returns null and the check is passed over, and
`janet_os_compiler` has no external oracle at all, which the file says out loud
instead of inventing one.

Verified by mutation, which matters more here than usual: changing the table's
`Darwin → macos` row to `Darwin → linux` failed at the expected line. Without
that step there would be no evidence the oracle was connected to anything.

The general rule, now in `phase_11.md`: **when a translation would make a
contract circular, say so at the site and find a different oracle or drop the
assertion.** Never let it become an assertion that cannot fail.

### Rule 5 paid for itself on its first outing

Part 2 changed the reduced-configuration sweep from "build these twelve" to
"build them and *run* the contracts". The first run of the new form found a
real failure: `-Dreduced-os=true` compiled cleanly and then died on

```text
os-time-contract:1:18: compile error: unknown symbol os/clock
```

The gate was `options.os_time`, which is `hasGettime` and therefore **true**
under `-Dreduced-os=true` — the event loop needs `janet_gettime` whether or not
`os/clock` is registered. **A subsystem being compiled and a core function
being registered are different facts**, and no field of `Selection` answers the
second. `os/cpu-count` had needed the same distinction an hour earlier in
`os_platform`, which is what put `harness.coreOptional` there to be reached
for.

Worth being precise about what would have happened without the upgrade: a
build-only sweep passes this, and the matrix's `reduced os` entry runs only the
contracts named in `CONTRACTS`. It would have shipped.

### A hazard that predates the migration

`matrix.py`'s `contracts` jobs do not take the SUITES lock — only `full` does,
because that is what runs the Janet suites — so two of them execute
concurrently in the **same repository working directory**. Any contract that
creates files there has two entries fighting over one fixture, which is
precisely the shared-fixture problem the SUITES lock exists to solve, one layer
down.

`os_fs` is kept out of `CONTRACTS` for that reason. It is not a new problem:
`test/os_fs.c` behaved identically and could have been named there at any point
in the last four phases. It is written down now because `os_fs_paths`,
`os_stat`, `os_process` and `io_core` are all still to migrate and each is the
same trap.

### The other two

`os_time` is invariants rather than vectors — a clock cannot be pinned to fixed
values — so what it asserts is ranges, orderings, the fallback for an
unrecognised source, and that a sleep advances a monotonic clock. Every bound
is deliberately loose, because this runs under a matrix at `-j2` and a tight
one fails for scheduling reasons; the lower bound is the contract and the upper
bound only catches a sleep that multiplied its argument by the wrong factor.

`os_fs` gained a refusal section: the kernels answer a status and set `errno`
where the Janet functions raise, and `os/mkdir` answers *false* for an existing
directory rather than raising — a return value a suite would have to know to
look for.

Four cross-compiles, eight reduced configurations run rather than built, 41
suites, and the acceptance matrix at **21 PASS / 0 FLAKY / 0 FAIL** in 171.0s.

## The filesystem group

*Phase 11 Part 4.* `os_stat` and `os_fs_paths` — and the first Linux run this
project has done since Phase 10's gate, which is where the increment's value
turned out to be.

### The first contract that needed the mechanism for something other than a raise

Every migration up to here would have worked under the arrangement Part 1
rejected: translate the `.c` in place, link `libjanet.a`, call exported
symbols. `os_fs_paths` would not have.

It needs `st_ino`, `st_nlink` and the timestamps to observe what
`janet_os_link` and `janet_os_touch` did — and `sys/stat.h` is deliberately
absent from `abi.zig`'s translation, for the reason `os_abi.h` records. A
contract outside the compilation has to translate `struct stat` a second time
and read the fields out of its own copy, which is a fifth translation of a host
header in a tree that has carefully limited itself to four.

Inside the compilation there is no copy: `subsystems.host_stat` exposes
`statRead` and `Field`, the same reader and the same index `os/stat` uses.
Using one kernel to observe another is not circular — reading metadata and
writing it are different code — and what *would* be circular, checking
`statRead` with `statRead`, is not done here or in `os_stat`.

### The container run, and what a driver's abort hides

`port/testing.md` has carried a podman recipe throughout and it had been run
exactly once, at Phase 10's gate. Part 4 ran it again because this is the
filesystem group and `host_stat`'s Linux arm goes through `statx` where macOS
goes through `stat`.

It found two failures. Neither is a regression — both reproduce identically at
`be120a4a`, checked by building that commit in a worktree and running the same
container — and **neither was in `FOUND.md`**, whose Linux entry named a
different contract entirely.

The reason is worth more than the failures. **The C driver runs contracts in
declaration order and aborts at the first one that fails.** `os_surface` comes
before `pp_format`, so `os_surface`'s abort hid it, and the entry recorded
"three suites and one contract" when the truth was three suites and three
contracts. Running each by name in a loop — `janet-zig-contract-test <name>` —
separates them in one pass. The Zig driver has exactly the same property.

`FOUND.md`'s third claim did not survive re-testing either: `test/remove_noops.c`
**passes** on `aarch64-linux-musl` at the baseline. It is left recorded rather
than deleted, with what is now established written beside it.

### A contract asserting what `FOUND.md` calls undefined

The `pp_format` failure is the interesting one, because the defect behind it
was already documented and the *contract* was the thing at fault.

`%D` reaches `snprintf` unrewritten — `format_mappings` carries `D` and `I`
entries that `FMT_REPLACE_INTTYPES` never consults — so what it prints is
whatever the host libc makes of an unrecognised conversion. macOS accepts it as
a BSD synonym for `%ld`; musl prints nothing. `FOUND.md` says of the C original
that it "pins only that the mapping does *not* happen, which is the part that
is the same everywhere".

Part 18's Zig rewrite pinned the *rendering* instead, and put it inside
`everyArgumentWidthInOneCall` — so a well-defined assertion about seven
argument widths failed on musl for a reason that had nothing to do with widths,
and took the whole driver down with it. The width case now uses `%d`, which
maps to `PRId64` on every host; the host-specific behaviour is
`theUnmappedIntegerConversions`, guarded to macOS and pointing at the entry.
Nothing is lost on macOS and all eighteen contracts now pass on Linux.

The rule: **where a divergence is recorded and deliberately unfixed, the
contract asserts the part that is common and quarantines the rest.**

### The rest

`os_stat`'s field registry is the assertion worth having: `field_name(i)` and
`field_lookup(name)` are inverses, and the index they agree on is what the
getters switch on — so the order of the fifteen names is load-bearing and
nothing in Janet can see an index. The preserved `janet_cstrcmp` quirk is
asserted too: a key whose own bytes end in NUL still matches, so
`lookup("dev\0", 4)` is 0.

Both contracts write fixture directories into the working tree, so both are
kept out of `matrix.py`'s `CONTRACTS` under Part 3's rule. `os_stat` *was*
named there through Part 18, which makes that hazard a live one rather than a
hypothetical.

Four cross-compiles, eight reduced configurations run rather than built, 41
suites, the acceptance matrix at **21 PASS / 0 FLAKY / 0 FAIL** in 171.1s, and
eighteen contracts passing on `aarch64-linux-musl` under Alpine.

## The printer

*Phase 11 Part 5.* `pp_describe` and `pp_pretty`, which complete a trio whose
third member has been Zig since Part 18 — and the first increment where the
*second* half of Phase 11's migration clause landed. Two abis died with
these contracts.

### Both abis claimed to have no callers, and both were wrong by one

`janet_zig_pp_escape_string` was built for `pp.c` under the old selector.
`janet_jdn` carried a comment saying, in as many words, "nothing in the tree
calls it — it is declared in no header and reached from no C file, and has been
dead since it was added. It is ported anyway… it goes with the export surface
in Phase 11."

Each had exactly one caller: its own C contract, which hand-declared the symbol
because no header carries it. `test/pp_describe.c` needed the escape function's
returned column width and could not take a `raise.Raising(i32)`;
`test/pp_pretty.c` needed `janet_jdn` for the same reason.

That generalises into something practical. **The way to find a dead abi is to
migrate its contract and then delete it**, not to grep for callers — a grep
over `src/` says "no callers" for both of these, and a grep over the whole tree
says "one, in a test", which reads as "keep it" rather than "it is waiting for
this migration".

### Deleting an abi found a defect in the runtime

`pp_pretty.zig`'s `prettyLeaf` computed its alignment with

```zig
S.align_col += 1 + describe.escapeString(S.buffer, S.buffer.data, S.bufstartlen);
```

`escapeString` was the `raise.reported` wrapper. `prettyLeaf` is itself
`raise.Raising`. So a raise inside the escape became a report **nobody
consumed**: the blank width was used as though it were real, and the
outstanding report surfaced at the next scope boundary's assertion, arbitrarily
far from the cause — which is the exact failure mode the hinge spent three days
hunting before it added those assertions.

Nothing found it, because the code compiled and the raise is only reachable on
allocation failure. Removing the abi turned it into a compile error naming its
own line, and the fix is one word:

```zig
S.align_col += 1 + try describe.escapeStringImpl(S.buffer, S.buffer.data, S.bufstartlen);
```

`raise.crossing`'s own note describes this family — 140 of them found when the
jump was removed — and says each is "an ordinary import away from not needing
this at all". This one was, and nothing had made it look at itself until the
abi went away.

### What the contracts stopped needing

`test/pp_pretty.c` spelled each expected panic as a fourteen-line
`EXPECT_PANIC` macro over `janet_try_init`, `janet_contract_arm`,
`janet_contract_raised` and `janet_contract_signal`, and kept a running count
of how many fired, because "a case that silently stopped panicking would look
exactly like one that passed". All of that is `harness.raised` and
`Raise.says` now, and the count is unnecessary: a refusal that stops happening
is a `null` where the contract asked for a value.

`test/pp_describe.c` built a `JanetAbstractType` and pushed it through
`test/support.zig`'s adapter pool to test the 32-byte title truncation, because
the runtime dispatches raising Zig callbacks and C cannot define one. It is an
`AbstractType` literal with no callbacks at all here.

### The `pp` alias is retired from both tools

`pp` was three C files behind one selector. `contract.sh` expanded the name and
`matrix.py` did not, so naming it in `CONTRACTS` failed twenty entries at once
with `test/pp.c:1:1: error: CacheCheckFailed` — a compile error in a file that
has never existed. `AGENTS.md` records it happening twice.

All three layers are ordinary names now and the expansion is gone.
`matrix.py`'s `NOT_A_FILE` entry stays as a preflight diagnostic: the habit
outlived the mechanism twice, so one line that turns it into a sentence before
the first build is worth keeping after the mechanism is gone.

### One process note

`zig build zig-contract-test` does not build the C driver, so a half-applied
migration — a `build.zig` line still naming a `.c` that has been deleted —
passes it and fails a full `zig build`. That happened here, and the full build
is what caught it. Run it before believing a migration is done.

Four cross-compiles, eight reduced configurations run rather than built, 41
suites, and the acceptance matrix at **21 PASS / 0 FLAKY / 0 FAIL** in 171.2s.

## The numbers

*Phase 11 Part 6.* `numscan`, `math` and `inttypes` — 875 lines of C, and the
first group since Part 2 where nothing writes to the working directory, so all
three could go into `matrix.py`'s `CONTRACTS` without tripping Part 3's rule.

### Where the mechanism is the wrong tool

`inttypes` asserts that `(div (int/s64 1) (int/s64 0))` raises. The obvious
move, after five increments of it, is `harness.core("div")` — and it fails,
loudly, on the type assertion inside that helper.

`div` is not a cfunction. It is a *Janet* function that dispatches to the
abstract type's `div` method, so there is no `raise.CFunction` to call and no
`error.JanetSignal` to catch: the raise happens inside the interpreter, and a
protected call is the instrument for that. `janet_pcall` was right in the C
contract and is still right here.

That is worth writing down because the migration has a pull toward using the
new mechanism everywhere. **The import is for reaching a raise-capable Zig
function. A protected call is for a raise that happens inside Janet.** The two
are not interchangeable and the second is not a leftover.

It also argues for the assertion in `harness.core`. `janet_resolve_core`
answers a `Janet`; without the type check the contract would have cast a
non-cfunction to a function pointer and jumped into it.

### An abstract type reached as itself

`janet_s64_type`'s `tostring` raises, so `test/inttypes.c` went through
`test/support.zig`'s `janet_contract_at_tostring` — one of three shims that
exist so C can invoke a raising Zig callback. The Zig contract declares the
type `extern` with the runtime's own `AbstractType` and calls the callback with
`try`.

**The shim does not die here.** `test/ev_loop.c` and `test/io_core.c` still use
it, so it goes when the last of the three moves. Said in the file rather than
implied, because the tempting summary — "the contract no longer needs the
shim" — reads as "the shim is gone".

### A matrix that passed and measured nothing

Part 6's acceptance matrix reported **21 PASS / 0 FLAKY / 0 FAIL** in
**1079 seconds**, against 171 for each of the five before it.

Six entries — three concurrent pairs — ran at about twenty times their usual
cost; the other fifteen were normal. Nothing tripped: the test bound is 300
seconds and the build bound 900, and no entry reached either.

The check took one command. `-Dffi=false` was 320.6s inside the matrix and
**16.0s** run by hand immediately afterwards, in a throwaway cache, on the same
tree. Twenty to one, so it is the machine and not the code.

`AGENTS.md` already had two rules of this shape — treat a FLAKY as a disk
question first, and re-run a clock-named failure alone before believing it —
and neither fires when everything passes. The third is now beside them:
**read the per-entry times even when every verdict is PASS.** The verdict here
stands; what would not have stood is a conclusion drawn from the timing.

Four cross-compiles, eight reduced configurations run rather than built, 41
suites, all three contracts verified capable of failing, and the acceptance
matrix at 21 PASS / 0 FLAKY / 0 FAIL.

## The front end

*Phase 11 Part 7.* `parser_core`, `emit_core`, `compiler_primitives` and
`specials_core` — 1,290 lines of C, and the largest abi harvest of the phase:
**ten** exported names died with them, against Part 5's two.

### The abis were the point, and there were ten of them

Part 5 established that an abi dies when its last C caller does, and that the
last caller is often the contract. The compiler is where that pays, because
`compile.h` is an *internal* header: nothing outside the runtime ever had a
reason to call `janetc_value` or `janetc_popscope`, so once the two C contracts
stopped, eight abis had no caller in the tree at all.

    janetc_lint      janetc_nameslot   janetc_pop_funcdef  janetc_popscope
    janetc_resolve   janetc_throwaway  janetc_toslots      janetc_value

Each was `raise.reported(janetc_*Impl(...))` — the raise flattened into a
report because C could not hold an error union. The migrated contracts call
the `Impl` functions with `try`, which is Part 1's argument arriving at the
compiler, and the abis went with their declarations in `compile.h`.

`nm -gU libjanet.dylib` counts 773 exported symbols before and 763 after. All
ten are `janetc_*`, which is one of the four families the phase's
exported-symbol-surface bullet names, so its count of 257 internal names is now
247.

### Deleting an abi found two Zig callers using it as one

The other two of the ten are the interesting ones, and they are Part 5's
lesson 13 repeating exactly.

`janetc_popscope_keepslot` sat beside `janetc_popscope` and did the same
`raise.reported`. Its one caller is `specials_core.zig`'s `do`, which is itself
`raise.Raising` — so a raise from the pop became a report nobody consumed, the
compile carried on with a scope it thought it had closed, and the leak would
have surfaced at the next scope boundary's assertion arbitrarily far from the
cause.

`janetc_toslotskv` is the same shape one level down: two
`raise.reported(janetc_valueImpl(...))` calls inside it, and its only caller
`makeDictionary` inside `janetc_valueImpl`'s own raising chain. Every struct
and table literal in every Janet program goes through it.

Both are now `pub fn ...Impl` returning `raise.Raising`, reached by import.
Neither has an abi any more and neither has a `compile.h` declaration.

**The general form: when an abi's last C caller goes, do not only delete the
abi — look at what is still calling it, because a Zig caller that was using a
abi as an abi is a report with nowhere to go.** `raise.crossing`'s own
comment says each of these is "an ordinary import away from not needing this at
all"; the way to find them is to remove the alternative.

### `Impl` now means nothing, and that is deliberate for one more part

Every surviving `janetc_*Impl` is the only function of its name. The suffix
distinguished it from an abi that no longer exists, so it is stale vocabulary
of exactly the kind this project keeps flagging. It is left alone: thirty-seven
contracts remain and later parts will spend more abis, so one sweep at the end
— with the exported-symbol-surface bullet, which asks the same question — is
cheaper and clearer than eight renames now.

### A refusal must leave the compiler where it found it

`fn` opens a scope before it validates its parameters. Both of its arity
refusals therefore have to close it, and a port that returned early from either
would leave the compiler one scope deep and corrupt every form after it —
without failing anywhere near the mistake.

`std.debug.assert(compiler.scope == &scope)` after each refusal is the whole
check, and it is inherited from the C contract rather than invented here. It is
called out because it is the assertion in this group most likely to be dropped
as noise by someone translating: the interesting-looking line is the error
message, and the load-bearing one is the scope.

### The vector vocabulary, established where three contracts needed it

`janet_v_push`, `janet_v_count`, `janet_v_empty` and `janet_v_free` are
function-like macros over a two-word `int32_t` prefix, so `@cImport` does not
translate them. Six subsystems already carry a private copy each; Part 7 is the
first increment where three *contracts* need one at once, so `harness.vector`
holds it — the same argument that put `harness.op` there in Part 2, and the
same rule: **establish the shared vocabulary on the group that needs it rather
than retrofitting it.**

`harness.opcode` joins `harness.op` beside it. An emit entry point takes its
operation as a `u8` and the word it builds carries it in the low byte of a
`u32`; `emit_core` needs each in turn, and neither cast reads as obviously
correct at the site.

### Two refusals the C contract could not reach

`janet_parser_consume` and `janet_parser_eof` are abis over `consumeChecked`
and `eofChecked`, which panic on a parser that has already finished or is
holding an unread error. From C those are a jump with nowhere to go, so the C
contract simply never fed a dead parser and the two messages had no test at
all. Here each is one line.

The distinction they draw is the parser's whole error policy and is worth
having asserted: a *parse* error is data and goes into `parser->error` for the
caller to read; a *use* error is a panic, because there is no value to answer
with. A port could keep one half and lose the other invisibly.

Neither abi dies — `janet.h` documents both and the fuzzers use them — which
is worth saying because the harvest above makes "migrate the contract, delete
the abi" sound automatic. It is not: the question is who else calls it.

### Where the import is wrong and the plain call is right

`emit_core`'s ten entry points do not raise. They record into
`compiler->result` and return, so the contract reaches them through `c.janetc_*`
exactly as the C one did. Part 6 wrote down that the import is for a
raise-capable Zig function and a protected call is for a raise inside Janet;
this is the third case, and the smallest: **a function that cannot raise is
reached by whatever call is in front of you.** `specials_core` uses all three
in one file — the import for a special's `compile`, the plain call for
`janetc_scope`, and `janet_dostring` for the six whole-program cases at the
foot.

### The instruments

`zig build test` with all 41 suites; four cross-compiles; a **run** sweep over
thirteen reduced configurations rather than a build-only one — including
`-Ddocstrings=false`, which is not a matrix entry and was added because
`specials_core` asserts that a docstring reaches the binding table; all four
contracts verified capable of failing by mutating their subjects; and the
acceptance matrix at **21 PASS / 0 FLAKY / 0 FAIL in 178.0s**, against the 171s
that is normal for it.

A benchmark *was* owed here and is not usually. The migration alone cannot
reach the runtime, but converting `janetc_popscope_keepslot` and
`janetc_toslotskv` touches the compile path for every `do` form and every
struct or table literal. Compiling 4,000 forms built to exercise both, five
passes, three runs each: 0.2508 / 0.2492 / 0.2496s before and 0.2502 / 0.2510 /
0.2498s after. Inside run-to-run variance, and it is the compile path rather
than the VM's execution loop either way.

## The collector

*Phase 11 Part 8.* `gc_alloc`, `gc_mark`, `gc_sweep` and `gc_stress` — 2,277
lines of C, the largest group of the phase so far, and the first one where the
migration would have destroyed something rather than merely moved it.

### An oracle that could not come along, and did not belong here either

`test/gc_mark.c` and `test/gc_sweep.c` each opened with the same block:

```c
assert(sizeof(JanetStringHead) == offsetof(JanetStringHead, data));
```

— five of them, for the four value heads and `JanetFunction`'s environment
array. `gc_mark.zig`'s own comment names those files as where the assumption
is checked, and the assumption is load-bearing: **`@cImport` drops flexible
array members**, so `@offsetOf(JanetStringHead, "data")` does not compile and
every header recovery in the runtime is spelled `@sizeOf` instead. The two
numbers agree only where the flexible array needs no padding after the last
declared field.

Translating the five lines into Zig would have compared `@sizeOf(X)` with
`@sizeOf(X)`. It compiles, it passes, and it cannot fail — Part 3's rule
arriving for the second time: *a translation that would make a contract
circular must find a different oracle or drop the assertion.*

**The first answer was wrong in an instructive way.** This increment built a
run-time oracle — allocate a value, compare the pointer the runtime handed back
against the block the allocator had just recorded — and put it in
`test/gc_mark.zig` as *the* replacement. It works, and then the question "what
exactly did the C version compare?" gave a better answer: C's `offsetof`
against C's `sizeof`, which is a fact about **`janet.h`**, not about the
collector. It has a natural home already, and that home is `test/abi.c`, whose
whole job is C's view of `janet.h`'s layout and which can hold the five lines
unchanged as `_Static_assert`s that cost nothing to run.

So both exist now, and they are not redundant:

| | what it would catch |
| --- | --- |
| `test/abi.c` | a `janet.h` edit that pads a header before its flexible array |
| `test/gc_mark.zig` | a runtime that computes an offset one way and allocates another |

Neither implies the other, and until this part the tree had only the first.
Each was verified by breaking it: adding `char abi_probe_pad;` to
`JanetStringHead` makes `abi.c` refuse to compile and name the field, and
skewing the funcenv slot by eight bytes makes `gc_mark` fail.

**One string is attached and is recorded in `phase_11.md` rather than only
here.** `abi.c` is one of the nine non-contract `.c` files that phase is still
deciding about — rewrite in Zig against the module interface, or delete as a
check on something this fork no longer promises. That decision now carries this
oracle with it. Rewriting `abi.c` in Zig would lose the five assertions exactly
the way migrating `gc_mark.c` would have.

### The general form, restated

Part 3 said it about `uname`. Saying it twice is the point:

> **When a migration would make an assertion circular, ask what the two sides
> of the original comparison actually were.** The answer names the replacement,
> and it may name a different file.

`os_platform` compared two compilers' beliefs about the target, and the
replacement asks the machine. `gc_mark` compared two of one compiler's
computations over one declaration, and the replacement is the same comparison
somewhere it still compiles.

### A shim that was already dead

`test/support.zig`'s `janet_contract_adapt_methods` had **zero** callers at
`HEAD` — not orphaned by Part 7, not orphaned by this part, just stale. It went
here because the sweep for orphaned scaffold happened to run.

Part 7's lesson was to read an abi's remaining callers when its last C caller
goes. The corollary: **the adapter pool deserves that sweep on a schedule, not
only when something forces it.** A dead abi announces itself by being deleted;
a dead *shim* announces nothing at all, because the file it lives in still
compiles and its neighbours still have users. The count is worth reading each
increment — `janet_contract_adapt_regs` is down to four users,
`janet_contract_protect` and `janet_contract_at_tostring` to one each, and each
of those dies with a single named contract.

### What the abstract types stopped needing

Twelve C contracts reach `CONTRACT_AT`, which is `janet_contract_abstract_type`
— the adapter pool that exists because a `JanetAbstractType`'s callbacks have
been Zig-ABI since the hinge and C can define none of them. Three of the twelve
were the collector's, and in Zig there is nothing to adapt: these contracts
need `gc`, `gcmark` and `gcperthread`, all three of which the hinge typed
**non**-raising, so they are ordinary `callconv(.c)` functions and the table is
the runtime's own `AbstractType`.

That is the adapter pool losing a quarter of its users to a change that
required no thought at all, which is the cheapest kind of progress this phase
has.

### `pthread` became `std.Thread`, and the guard shrank

`test/gc_stress.c` reached its cross-thread half through three `#ifdef`s and an
`#include <pthread.h>`; the Zig version reaches it through
`std.Thread.spawn` and one comptime `const`. It is the one place in the whole
migration where a contract came out materially *shorter*.

The condition needed a translation of its own, and it is Part 3's lesson 7
again: `options` names **subsystems**, so there is no `options.ev` to read.
`options.ev_core` is set to `hasEv(options)` by `build.zig` and is therefore
the same condition in the vocabulary the module has.

### Verified to be capable of failing, and one mutation that was not

Four subject mutations, all caught: the weak-heap boundary moved
(`gc_alloc`), a weak array traversed during marking (`gc_mark`),
`gcperthread` skipped (`gc_sweep`), and **a non-atomic `janet_abstract_incref`**
(`gc_stress`, three runs out of three) — which is precisely the failure that
file's header says "a non-atomic implementation would still pass every
single-threaded test with".

The first mutation tried for `gc_stress` was **not** caught, and it is worth
recording why: repairing the head-orphan defect by re-reading
`current.*.data.next` after the finalizer changes nothing, because the
finalizer's prepend moves `janet_vm.blocks`, not the dying block's `next`
field. The mutation was a no-op and the "NOT CAUGHT" was correct. **A mutation
that fails to provoke is not evidence about the contract**; check that the
mutation is real before drawing a conclusion from it.

### The instruments

`zig build test` with all 41 suites; four cross-compiles; the contracts *run*
in thirteen reduced configurations rather than merely built; four subject
mutations and one abi-header mutation, each caught; and the acceptance matrix
at **21 PASS / 0 FLAKY / 0 FAIL in 172.6s**, against the 171s that is normal.

No benchmark is owed. Unlike Part 7 this increment touched no runtime source —
the only non-test edits are five static assertions in `test/abi.c` and the
deletion of a shim nothing called.
## The data structures

*Phase 11 Part 9.* `buffer_array`, `abstract_core`, `string_symbol` and
`struct_table` — 3,023 lines of C for 3,109 of Zig, the largest group of the
phase and the one where the previous part had already paid for the hardest
part of it.

### Part 8 pre-paid for three of the four

Every one of `abstract_core`, `string_symbol` and `struct_table` opened with a
head-layout assertion:

```c
assert(sizeof(JanetAbstractHead) == offsetof(JanetAbstractHead, data));
```

Four such lines across the three files, for the abstract, string, tuple and
struct heads. Part 8 met exactly this in `gc_mark.c` and `gc_sweep.c` and
answered it twice over: the static assertions went to `test/abi.c`, which is C
and can still spell `offsetof`, and a run-time oracle derived from the
allocator went into `test/gc_mark.zig`. **Both replacements already cover all
four heads**, so this part deleted four assertions and wrote none.

That is worth recording because it looks like a loss and is not. The temptation
was to build a third thing — a local `@sizeOf` comparison in each migrated file
— which would have compiled, passed, and been unable to fail. Part 3's rule and
Part 8's sharpening of it both say to ask what the two sides of the original
comparison were; here the answer was *already sitting in two other files*, and
the work was to check that rather than to write something.

Each migrated file says so at the top, so a reader looking for the assertion it
used to have finds where it went.

### The refusals got cheaper, and the tally went with them

`buffer_array.c` reached its six refusals through a twenty-line `EXPECT_PANIC`
macro — open a scope, `janet_contract_arm`, call the abi, `janet_contract_raised`,
`janet_contract_signal`, `janet_restore`, compare the payload — and then
asserted `panics_fired == 6` at the foot, because with a macro that big it is
worth proving all six ran.

In Zig each is one line and the tally is gone. A refusal that does not happen
now fails at the call that expected it rather than in a count at the end, which
is a better failure and not merely a shorter one. This is Part 1's lesson 2
arriving in the group where it saves the most.

### The adapter pool lost its second-largest user

`abstract_core.c` reached every abstract type through `CONTRACT_AT`, which is
`test/support.zig`'s `janet_contract_abstract_type`: a pool of pre-built tables
that exists because a `JanetAbstractType`'s callbacks have been Zig-ABI since
Phase 10's hinge and C can define none of them.

It needs `gc`, `gcmark` and `gcperthread` — the three the hinge typed
**non**-raising, for the reason `abstract_type.zig` sets out at length. So
there is nothing to adapt: they are ordinary `callconv(.c)` functions and the
table is the runtime's own `AbstractType`. `CONTRACT_AT` is down from twelve
users to eight, and four of those four went for free.

### One abi, and it was the one the C contract's own comment named

`janet_buffer_can_realloc` is gone. `test/buffer_array.c` said of it:

> This is the increment's one seam: `janet_buffer_can_realloc` was static in
> `buffer.c` and is now shared, because `cfun_buffer_trim` still calls it from
> the half of the file that stays in C.

That half of the file has not existed since Phase 10 Part 18. `cfunBufferTrim`
is Zig and calls `canRealloc` directly; `util.h` was the only header that
declared the abi; and after the contract moved, a grep found **no caller
anywhere in the tree**. Part 5's lesson 12 exactly: the way to find a dead abi
is to migrate its contract and then look.

Part 7's lesson 17 — read the remaining callers before deleting — found nothing
to worry about here, because there were none.

### What the deletion did find: eleven stranded selector shims

`janet_buffer_can_realloc` had one nominal mention left, in
`src/zig/subsystems/buffer_array_extern.zig`, reached only through
`containers.zig`'s `if (options.buffer_array) ... else ...`. That condition has
been comptime-`true` since Part 18 spent the last selector, so the `else`
branch is never analysed and a dangling name in it would never be diagnosed.

There are **eleven** such files — `args_core_extern.zig`, `buffer_array_extern.zig`,
`ev_loop_extern.zig`, `fiber_core_extern.zig`, `marsh_extern.zig`,
`pp_extern.zig`, `registry_extern.zig`, `value_access_extern.zig`,
`value_wrap_extern.zig`, `vm_calls_extern.zig` and `vm_lifecycle_extern.zig` —
each named by an `if (options.X)` whose condition is a constant. They are
`PLAN.md`'s "whatever the deletion stranded", and they are a part of their own
rather than a detail of this one. This increment took only the two lines that
named the abi it deleted.

### Verified to be capable of failing, and one mutation that did not compile

Four subject mutations, all caught: `janet_gc_settype` written as a store
rather than an or (`abstract_core`), `janet_buffer_extra` reserving exactly what
was asked rather than doubling it (`buffer_array`), `janet_string_equalconst`
dropping its length check (`string_symbol`), and the Robin Hood hash tiebreak
deciding the other way round (`struct_table`).

The `string_symbol` one was reported **NOT CAUGHT** on its first attempt, and
the reason is new. Deleting the length comparison left `const llen` unused,
which is a Zig *compile error*; the build failed, `zig-out` still held the
previous binary, and the contract ran against an unmutated runtime and passed.

Part 8 established that a mutation which fails to provoke is not evidence. This
is the same rule one step earlier: **a mutation that fails to compile is not
evidence either, and it is the more dangerous of the two**, because a mutation
sweep that does not check the build's exit status scores it exactly as a
mutation the contract caught. `AGENTS.md` already warns twice about trusting a
stale `zig-out`; this is that trap wearing a mutation sweep's clothes. The
replacement kept `llen` used — `llen < 0` in place of `llen != rlen` — and was
caught.

### The shim sweep found a second dead one

Rule 22 says to read `test/support.zig`'s user counts every increment rather
than waiting to be forced. `janet_contract_payload` had **zero** callers, and
`git grep` over the last eight commits says it had none at Part 4 either — so,
like Part 8's `janet_contract_adapt_methods`, it was stale rather than orphaned
by anything recent. It is deleted.

Two consecutive scheduled sweeps, two dead shims neither of which announced
itself. That is the argument for the schedule.

### The instruments

`zig build test` with all 41 suites; every Zig contract run by name in a loop
rather than trusting the driver's abort-at-first-failure (rule 10) — 35 PASS;
four subject mutations, each caught, plus the one that had to be rewritten
before it meant anything; the acceptance matrix with `CONTRACTS` retargeted to
this increment's four, at **21 PASS / 0 FLAKY / 0 FAIL in 232.6s** with every
per-entry time at its usual cost; and two configurations by hand that the
matrix does not carry.

Those two are rule 19's, and one of them is the rule's clearest case so far.
`-Ddocstrings=false` is the standing entry. **`-Dprf=true` is named by two of
this part's contracts in their own prose**: `janet_hash` changes outright under
it, which is precisely why `struct_table.zig` *searches* for colliding integer
keys instead of hard-coding a pair and why `string_symbol.zig` asserts only
that a stored hash matches the one the hash function returns. Both pass, so
nothing changed — but a configuration a contract's comments spend a paragraph
defending against is one worth actually running once.

No benchmark is owed by the migration itself, and the one runtime edit —
deleting `janet_buffer_can_realloc` — removes a wrapper nothing called rather
than changing a function on any path. That is the other side of Part 7's
lesson 18: read what the increment touched, and a deletion with no callers
touches no path.

## The value core

*Phase 11 Part 10.* `value_wrap`, `value_alloc`, `value_order` and
`value_access` — 3,786 lines of C for 3,735 of Zig, and the group where the
migration lost an oracle it could not replace from outside the port.

### The oracle that had no analogue, and the one the port had already built

`wrap.c` exists to provide a *function* form of what `janet.h` provides as a
*macro*. So `test/value_wrap.c` had a channel available nowhere else in the
phase: for every entry point with both spellings, call each and compare, using
C's rule that a parenthesised name is not macro-expanded — `(janet_truthy)(v)`
against `janet_truthy(v)`, in the same file, on the same value.

**A Zig contract cannot reach the macro at all.** `janet.h` declares
`janet_checktype`, `janet_truthy`, `janet_wrap_integer` and their kin as
functions *beside* macros of the same name, and `@cImport` prefers the
function — which is `harness.wrapInteger`'s note from Part 1, arriving from the
other direction. Both spellings become one thing here, so a translated
`agree_on` would have compared a function with itself: Part 3's rule 8, an
assertion that cannot fail and looks thorough.

Rules 20 and 24 say to ask what the two sides of the original comparison
actually were, and then to ask where that comparison already lives. The two
sides were *the operation a caller gets inlined* and *the operation the library
exports* — and this runtime has that pair, for a reason that has nothing to do
with testing. `value_wrap.zig`'s `ops` namespace exists because `run_vm`
measured **+89%** on the arithmetic workload when it reached these through the
symbol table. Twenty-one operations have both spellings, and a disagreement
would make the interpreter answer differently from the C API about the same
value.

Everything else called the exported symbol until Phase 12 increment 5d, which
is a separate story with the same measurement behind it -- see *The wraps, and
who was paying for them* below. The pair this contract watches is unchanged:
one side is still what a caller gets inlined, the other is still what the
library exports.

`theTwoSpellingsAgree` is that channel. It is the C original's claim carried
over rather than a new one, and it is weak in exactly the same way the original
was and for the reason the original's header gave: both spellings bottom out in
`repr`, so it catches an operation wired to the wrong helper and nothing more.
The absolute bit patterns are what catch the helper.

**It is load-bearing, and that was measured rather than asserted.** Making
`ops.wrapNil` build nil with a different payload bit — a divergence the tag
never sees — leaves `zig build` green, the REPL working, and
`suite-value`, `suite-table`, `suite-marsh` and `suite-struct` all passing.
Only `value_wrap` fails. That is a mutation nothing else in the tree can see.

### The wraps, and who was paying for them

Phase 12 increment 5d. `janet.h` spells every wrap as a *macro* under both
NaN-boxed layouts:

```c
#define janet_wrap_nil() janet_nanbox_from_payload(JANET_NIL, 1)
#define janet_wrap_array(s) janet_nanbox_wrap_((s), JANET_ARRAY)
```

and declares the function form for the tagged layout and for the ABI. So a C
caller pays nothing to wrap a value. The Zig tree reached the same names
through `cabi.zig`'s `pub extern fn` and paid a call **on every layout** --
1,530 references, `janet_wrap_nil` alone 480. The number that says how much was
already in the tree: `run_vm` measured +89% on the arithmetic workload reaching
this layer through the symbol table, which is why `ops` exists. One file
escaped; the other ninety did not.

The file has two layers now, and the split is forced rather than chosen:

```zig
pub inline fn wrapArray(x: [*c]c.JanetArray) c.Janet {
    return repr.wrapPointer(x, c.JANET_ARRAY);
}
// and, in `abi`:
pub fn wrapArray(x: [*c]c.JanetArray) callconv(.c) c.Janet {
    return outer.wrapArray(x);
}
```

**`@export` needs an address and an `inline fn` has none.** That is the whole
reason for `abi`, and it decides which layer gets the readable name: an abi is
spelled twice, in its own definition and in the `@export` beside it, while
`wrapArray` is spelled at 121 call sites.

`ops` stays, holding what the container cannot spell -- `truthy` returning
`bool` where the export returns `c_int`, `checkType` where the export is
`checktype` -- and its wraps are one-line delegates, which makes its own doc
comment true for the first time. It had claimed each member was "the body of
the identically named export rather than a second copy of it"; for six of them
it had been a second copy.

**`janet_wrap_boolean` keeps the header's `c_int`.** Zig's `bool` is the better
type and the wrong one here: the 41 call sites hold `@intFromBool(...)`,
`isatty(fd)`, `tm_isdst`. `ops.wrapBoolean` is the `bool` spelling, for the
caller that has one.

`test/value_wrap.zig` was left alone deliberately. It compares the exported
symbol against `ops` member by member, so converting it would have put the same
function on both sides -- and those surviving references are what keep the
`cabi.zig` declarations alive, which is what lets `cabi_check.zig` compare
`@TypeOf(c.janet_wrap_nil)` against `@TypeOf(d.abi.wrapNil)`. **The contract
pays for the declaration, and the declaration pays for the check.**

### Two assertions that had already moved, and none that had to

Rule 24's case, twice more. `test/value_alloc.c` opened with
`sizeof(JanetFunction) == offsetof(JanetFunction, envs)`, which is what makes
`janet_thunk`'s `@sizeOf(JanetFunction)` the right size for a function with no
environments. `@cImport` drops a flexible array member, so a translation would
have compared `@sizeOf` with itself.

Part 8 put that exact line in `test/abi.c` when it moved the four head-offset
assertions there — **before anything needed it here**, on the general argument
that the property is about `janet.h` and C is the only side that can spell both
halves. So this part deleted an assertion and wrote none, and
`value_alloc.zig`'s own comment now points at where it went.

### The abstract fixtures cost nothing, twice over

`value_order.c` and `value_access.c` between them held **twenty-one** of the
twenty-nine `CONTRACT_AT` uses in the tree, and every one of them is gone.

The two files need opposite halves of `abstract_type.zig`'s split and both are
free. `value_order`'s types supply `compare` and `hash`, which the hinge typed
**non**-raising because they are called from inside comparisons that must be
total — so they are ordinary `callconv(.c)` functions and the table is the
runtime's own `AbstractType`. `value_access`'s types supply `get`, `put`,
`next` and `length`, which the hinge typed **raising** — which is precisely why
C could not define them and needed `test/support.zig`'s pool of pre-built
tables, and why in Zig they are ordinary functions returning `raise.Error!T`.

`CONTRACT_AT` is down from eight users to six.

### The tally went with the macro, for the third time

`value_access.c` reached its refusals through a twenty-line `EXPECT_PANIC`
macro and asserted `panics_fired == 49` at the foot, because with a macro that
big it is worth proving all forty-nine ran. In Zig each is one line and the
tally is gone: a refusal that stops happening now fails at the call that
expected it. Part 9 recorded the same thing for `buffer_array`'s six; this is
Part 1's lesson 2 at eight times the scale.

`EXPECT_PANIC_PREFIX` became `harness.Raise.beginsWith`, the one piece of new
shared vocabulary this part added beside `harness.u64Of` and
`harness.heap.reachable`. Every case that needs a prefix is a case about an
abstract, which renders with its address.

### No abi died, and the grep says something else instead

Rule 12 says the way to find a dead abi is to migrate its contract and then
look. Looked: `janet_memalloc_empty`, `janet_memempty`, the seven
`janet_nanbox*` helpers, `janet_thunk_delay`, `janet_fiber_reset` and the nine
accessor exports all still have callers, and nothing was deleted.

What the sweep *did* turn up belongs to a different bullet. `janet_next`,
`janet_next_impl`, `janet_in`, `janet_get`, `janet_getindex`, `janet_length`,
`janet_lengthv`, `janet_put` and `janet_putindex` now have **zero in-tree
callers**: the Zig contract reaches `value_access.zig`'s `pub fn`s directly and
the C contract that used to cross the ABI is gone. Their doc comments already
said as much — "Nothing in the tree calls it… It exists for embedders" — and
they are `janet.h`'s public surface, so they stay. That is data for the
exported-symbol-surface bullet rather than a deletion this part could make.

### Verified to be capable of failing, and two mutations that were not evidence

Four subject mutations, all caught: `janet_wrap_number_safe` no longer
canonicalising a NaN (`value_wrap`), the fiber capacity floor applied one slot
late (`value_alloc`), `janet_hash` no longer normalising negative zero
(`value_order`), and `getterCheckInt` letting index −1 through
(`value_access`). Plus the `ops.wrapNil` payload-bit divergence above, which is
what makes the replacement oracle a measurement rather than an argument.

**Two earlier attempts were discarded, and the reason extends Part 9's rule
23.** That rule says a mutation which fails to *compile* is not evidence, and
to assert the build's exit status before running the contract. These two
compiled. They broke the **bootstrap**: `ops.truthy` and `janet_truthy` are
both on the image generator's path, so `zig build` failed at `run exe
janet-boot` with

    boot.janet:3165:9: compile error: the first element of `catch` must be a
    tuple or array

— a diagnostic naming `boot.janet` and a Janet macro, in a run whose only
change was four tokens in `value_wrap.zig`. `zig-out` still held the previous
binary, so a sweep that looked only at whether the contract failed would have
scored both as **caught**.

So rule 23's check is right and its stated cause is too narrow: a mutation can
fail the build at *any* step, and the most confusing one is the step that
consumes the runtime rather than the step that compiles it. The exit status is
still the whole test; what changes is that the message will not name the file
you mutated.

### The instruments

`zig build test` with all 35 suites and 4,813 of 4,813 tests; every Zig
contract run by name in a loop rather than trusting the driver's
abort-at-first-failure (rule 10) — **39 PASS**, up from 35; five subject
mutations, each caught, plus two that had to be discarded before they meant
anything; two configurations by hand under rule 19 — `-Ddocstrings=false`, the
standing entry, and `-Dprf=true`, which `value_order.zig`'s
`theExactNumberHashes` spends a paragraph arguing it is *insensitive* to and is
therefore worth running once; and the acceptance matrix with `CONTRACTS`
retargeted to this increment's four, at **21 PASS / 0 FLAKY / 0 FAIL in
175.0s**, every per-entry time at its usual cost.

No benchmark is owed. The only runtime edits are three comment corrections —
two in `value_alloc.zig` naming a file that no longer exists, one tense fix in
`value_wrap.zig` — and a comment touches no path.

## The fibers and signals

*Phase 11 Part 11.* `fiber_core`, `signal_core` and `trace_frames` — 1,932
lines of C for 1,903 of Zig, four abis retired, and the first migration
whose failure was found by the acceptance matrix rather than by the contract.

### Four abis, and the arithmetic that decided which

Rule 12 says the way to find a dead abi is to migrate its contract and then
look. Looked, and four were dead:

| abi | declared in | who was left |
| --- | --- | --- |
| `janet_fiber_push2` | `fiber.h` | nobody |
| `janet_fiber_push3` | `fiber.h` | nobody |
| `janet_fiber_pushn` | `fiber.h` | nobody |
| `janet_signal_commit` | `state.h` | its own file |

The push abis are Part 7's argument arriving at a different header. `run_vm`
and `janet_call` reach `push2`, `push3` and `pushn` by import — `fiber_core.
push2(fiber, …)`, not `c.janet_fiber_push2(…)` — so the only caller of any of
the three exports was `test/fiber_core.c`, and `fiber.h` is internal rather
than `janet.h`. Nothing outside the runtime ever had a reason to call one.

`janet_signal_commit` is the other shape: `janet_zig_signal_record` calls it
from three lines away in the same file, so the *export* had one caller outside
`signal_core.zig` and it was the contract. It is `pub fn signalCommit` now,
with the `state.h` declaration gone, and `test/signal_core.zig` reaches it by
import.

**`janet_fiber_push` survives, and only just.** `test/vm_calls.c` and
`test/vm_entry.c` still call it, so it goes when they do. That leaves the push
family with one abi where it had four, which is worth being explicit about
because the C contract tested each push *twice over* and said why: "the abi
is the one that disappears, so it is the one that rots." It disappeared. Three
of the four kernels are now reached by import alone and the fourth is tested
through `harness.abiRaised` for exactly as long as the two remaining C
contracts keep it alive.

### The assertion that became a definition

`test/signal_core.c`'s `test_jump_delivers_the_recorded_signal` was the one
case in that file with two independent transports: `janet_signalv` recorded
the raise and then jumped, and the value `setjmp` returned had to equal the
signal the record had published. "If these ever disagree the mechanism has
forked, and every other test here would still pass."

There is one transport now. `raise.signal` calls `janet_zig_signal_record` and
returns `error.JanetSignal`; the abi is `raise.report` over exactly that
expression, and `report`'s entire body is setting a flag. Asserting that the
two agree is asserting that a definition holds — rule 8's assertion that
cannot fail and looks thorough.

So it is **dropped, and said so in the file's header** rather than translated.
What takes its place is narrower and true: `janet_vm.pending_signal` is where
a Zig caller reads the signal, so every raising case in the migrated contract
reads it back through `harness.raised` instead of assuming the value it passed
in. That is not a replacement oracle in rules 20 and 24's sense — there was
none to find — it is the honest remainder of a claim that lost half its
subject.

### Two public abis with no in-tree caller, which is now a pattern

Part 10 found nine `value.c` exports with zero in-tree callers that stay
because they are `janet.h`'s public surface. This part adds two:
`janet_signalv` and `janet_panics` had exactly one caller each — the C
contract — and neither has another anywhere in the tree. `janet_panicv` and
`janet_panic` do (`interop.zig` and `native_module.zig` reach them through the
C ABI), which is what makes the pair interesting rather than uniform.

All four stay, and all four are still tested here. A public entry point with
no in-tree caller is precisely the kind that rots without anything saying so,
and `harness.abiRaised` makes each one line. That is data for the
exported-symbol-surface bullet from the other direction: the question is not
only "who exports too much" but "what is the surface *for*", and two of these
four exist solely for an embedder.

### `harness.abiRaised`, and where the shim went

The C contracts read a raise with `janet_contract_arm`, then the call, then
`janet_contract_raised` and `janet_contract_signal` — three shims in
`test/support.zig` over `janet_vm.c_raised`. A contract inside the compilation
reads that flag directly, so the whole protocol is `raise.tookCRaise`:

```zig
pub fn abiRaised(abi: anytype, args: anytype) ?Raise {
    var state: c.JanetTryState = undefined;
    c.janet_try_init(&state);
    defer c.janet_restore(&state);
    @call(.auto, abi, args);
    if (!raise.tookCRaise()) return null;
    return .{ .signal = c.janet_vm.pending_signal, .payload = state.payload };
}
```

It went to `test/harness.zig` under rule 6 rather than staying local, because
two contracts in this one increment needed it: `signal_core` for the four
public abis and the two slot diagnostics, `fiber_core` for the one surviving
push abi. The report has to be taken **inside** the scope — `janet_restore`
aborts on an outstanding one, which is Part 17h's assertion — so the ordering
is load-bearing and is written down at the definition rather than at each use.

Reach for `harness.raised` instead wherever the subject is a Zig function.
That is rule 15 with a second door: `raised` is for a raise that arrives as an
error, `abiRaised` for one that arrives as a report, and which you get is
decided by whether you spelled the import or the symbol.

### An identical function body is not a distinct address

**The failure this part is worth remembering for.** `test/trace_frames.c`
carried three cfunctions used only as registry keys — `probe_named`,
`probe_unnamed`, `probe_unregistered` — each `{ (void) argc; (void) argv;
return janet_wrap_nil(); }`. The contract's whole subject is that the registry
answers differently for the three, so their being three *addresses* is the
premise of every assertion in the file.

Translated as three identical Zig functions, they are one address. Every
optimize mode above Debug folds identical function bodies, so
`janet_registry_get(probeUnregistered)` returns the entry planted for
`probeNamed` and `anUnregisteredCfunction` fails — as
`panic: reached unreachable code` under `-Doptimize=ReleaseSafe` and as a
segfault under `ReleaseFast` and `ReleaseSmall`.

Three things about how it was found:

- **`zig build test`, `port/contract.sh` and every contract run by name all
  passed.** The narrow loop is Debug, and Debug does not fold. Nothing in the
  per-increment routine except the matrix builds another optimize mode.
- **The matrix found it in its first three entries**, and the report — `test /
  error: process terminated with signal ABRT` — named neither the file nor the
  contract. Finding which of forty-two contracts had died took building
  `-Doptimize=ReleaseSafe` by hand and running the driver with no argument, so
  that it printed the thirty-nine that passed before it.
- **The C original had the same three identical bodies and never met this**,
  because `test/contracts.c` is compiled by a separate `zig cc` at the
  matrix's own flags rather than folded into the runtime's compilation. So
  this is a hazard the Part 1 mechanism *introduced*, not one it inherited.

The fix is one token per probe: each returns a different integer. Nothing
calls them, so the values are never read; what they buy is that the fold is
illegal. The comment at the site says so, because the next contract that needs
distinct cfunction addresses will otherwise write the C shape again.

**The general form: when a contract's premise is that two things are
different, ask what makes them different to the *compiler*.** Two Zig
functions are distinct values and identical machine code, and only the first
of those is what a registry key means.

This is also the strongest evidence yet for `phase_11.md`'s argument that the
matrix belongs per increment rather than at the gate. Nine parts of contract
migration had not needed an optimize mode to catch anything; this one did, and
a Debug-only routine would have shipped it.

### An oracle that did not move, and a `%s/%s` no suite can reach

`trace_frames` needed no replacement oracle and lost nothing. It reads a
`JanetStackFrame` a contract wrote by hand, which is as constructible in Zig as
in C, and the registry entries it plants are `harness.internal.janet_registry_
put` — a line added to the `util.h` block Part 9 established, exactly as that
rule intended.

What it does keep is the case the suites cannot reach at all. `%s/%s` is taken
only when a registered cfunction has a **prefix**, and every core registration
passes null for one; a native module calling `janet_cfuns_prefix` gets one, and
so does the entry this contract plants. So `aPrefixedCfunctionRenders` builds a
fiber whose only frame is a cframe, binds `:err` to a buffer, and reads the
line back — `  in trace/probe [trace_frames.zig] on line 41`.

The migration made one improvement there for free. The C contract called
`janet_stacktrace_ext` and `janet_trace_frame`, which are `raise.reported` over
the entry points beside them, so a raise from a `tostring` callback reached
through `%v` would have become a report nobody consumed — rule 13's family. The
Zig contract calls `stacktraceExt` and `janet_trace_frameImpl` with `try`, and
the hazard is gone by construction rather than by care.

### A dead `extern fn`, found by looking at who calls an abi

Rule 17 says to read a surviving abi's remaining callers rather than assuming.
`janet_trace_frame` has three mentions in `debug_frames.zig`, and reading them
turned up an `extern fn janet_trace_frame(...)` declaration with **no caller in
that file**: `doframe` was converted to `trace_frames.janet_trace_frameImpl` at
some point and the declaration stayed. Zig does not analyse an unreferenced
container-level declaration, so it compiled and said nothing.

That is Part 9's rule 22 one directory over — a dead abi announces itself, a
dead *declaration* does not — and it is the same blindness the eleven stranded
`*_extern.zig` shims have. Deleted.

It also means `janet_trace_frame`'s only remaining caller in the tree is
`test/vm_lifecycle.c`. It is a fifth abi waiting on a contract.

### The shim sweep, and nothing dead this time

Read per AGENTS.md, and the counts moved without anything reaching zero:
`arm`, `raised` and `signal` at **twelve** each, down from fifteen;
`call_cfunction` five; `CONTRACT_AT` five, down from six; `adapt_regs` three;
`cfunction` two; `at_get` and `at_next` two; `protect`, `at_tostring` and
`raising` one each. Two consecutive parts found a stale shim and this one found
none, which is the sweep working rather than the sweep being unnecessary.

### Verified to be capable of failing

Three subject mutations, each caught, each checked against rules 21, 23 and 26
before being believed — the build's exit status asserted first, and no
candidate taken from the image generator's path:

- `envValid` no longer comparing the frame function's `slotcount` with the
  environment's `length`, so an unmarshalled environment with the wrong slot
  count validates (`fiber_core`);
- `janet_signal_inject` writing the injected signal into `flags` instead of
  `gc.flags` — the "tidied into one word" mutation the contract's own comment
  names (`signal_core`);
- the cfunction location test gaining `reg.*.name != null`, which collapses the
  two classifications the descriptor exists to keep apart (`trace_frames`).

### The instruments

`zig build test` with 4,813 of 4,813 tests; every Zig contract run by name in a
loop rather than trusting the driver's abort-at-first-failure (rule 10) —
**42 PASS**, up from 39; three subject mutations, each caught; two
configurations by hand under rule 19 — `-Ddocstrings=false`, the standing
entry, and `-Dsourcemaps=false`, which `trace_frames` names in two cases and
the matrix does not have; and the acceptance matrix with `CONTRACTS` retargeted
to this increment's three, at **21 PASS / 0 FLAKY / 0 FAIL in 175.0s**, every
per-entry time at its usual cost. The first run of that matrix was
**3 FAIL**, which is the increment's main finding and is above.

A benchmark **is** owed and was taken, because `janet_signal_commit` losing its
export is a linkage change on the raise path and rule 18 says to read what the
increment touched rather than what it was about. Two `ReleaseFast` binaries,
`HEAD` in a worktree against this tree, twelve stack layouts each on the Phase
9 corpus, minimum per workload:

| | before | after |
| --- | --- | --- |
| arithmetic | 0.046208 | 0.046861 |
| fib | 0.016398 | 0.016406 |
| methods | 0.018082 | 0.018082 |
| tables | 0.053885 | 0.054219 |
| strings | 0.048577 | 0.049729 |
| compiler | 0.043632 | 0.043616 |
| pegmatch | 0.040121 | 0.040678 |
| opfallback | 0.015614 | 0.016536 |
| fibers | 0.025294 | 0.025413 |

Every workload inside `bench-layout.sh`'s own ±5% resolution but `opfallback`
at +5.9%, on the smallest workload in the corpus and the one furthest from
anything this part touched. No finding.

## The VM

*Phase 11 Part 12.* `vm_state`, `vm_lifecycle`, `vm_entry`, `vm_calls` and
`vm_run` — 2,838 lines of C for 2,976 of Zig, **fourteen abis retired**,
one `test/support.zig` shim spent, and a defect the port had introduced and
nothing else could have found.

Five contracts rather than the four the pace had settled at, because the group
is five and `vm_run` is almost entirely Janet source: it drives the loop
through `janet_dostring` and compares messages, so the migration is a
transcription of the strings with a different `snprintf`.

### The defect: a raise the loop swallowed

**`JOP_MAKE_STRING` and `JOP_MAKE_BUFFER` dropped a `tostring` refusal on the
floor, and had since the hinge.**

`vm_calls.zig` had `fillStringImpl`, which is `raise.Raising(void)`, and
`fillString`, which was `raise.reported` over it — the abi `state.h`
declared as `janet_fill_string`. `vm_run.zig`'s two constructor arms called the
**abi**, from inside `runVm`, which is itself raising. So an abstract's
`tostring` raising mid-loop became a report nobody consumed: the loop went on
to build a string out of a half-filled buffer, kept interpreting, and the
outstanding report killed the process at the next scope boundary with

    a raise was reported to a C caller and never consumed

— arbitrarily far from the cause, in a function that had nothing to do with it.
Under the C original the same refusal was a `longjmp` out to `janet_continue`
and propagated correctly.

This is rule 13's family and rule 17's, and it is the *third* instance:
Part 5 found `prettyLeaf` calling `describe.escapeString` from inside a raising
function, Part 7 found `janetc_popscope_keepslot` and `janetc_toslotskv` doing
it on the compile path. What is new is how it was found. There the abi was
deleted and the compiler named the site; here **the migrated contract would not
compile**, because `harness.raised` demands an error union and `fillString` did
not return one. The C contract could not have found it — it called the abi
deliberately and read the report with `janet_contract_raised`, which is the
correct way to test an abi. It tested the abi and the abi was right; the
caller was wrong, and only a caller-shaped instrument sees that.

The fix is the shape rule 13 predicts: `fillString` *is* the raising function
now, `janet_fill_string` is gone, and `vm_run.zig` writes `try`.

**How reachable it was.** Not from compiled Janet source: `(string ...)` and
`(buffer ...)` compile to calls of the `string` and `buffer` cfunctions —
`disasm` confirms — so neither opcode is emitted by the compiler at all, and
`test/vm_run.zig` reaches them through `asm`. Reaching the swallowed raise
needs an assembled `mkstr` or `mkbuf` over an abstract whose `tostring` raises,
which means a native module. So it was a live defect with no in-tree
reproduction, which is exactly the kind a contract exists for.

### Fourteen abis, and why only three of them were symbols

Rule 12 again: migrate, then look. Fourteen were dead, which is the largest
harvest of the phase — Part 7's ten was the previous high.

| abi | declared in | why it went |
| --- | --- | --- |
| `janet_method_invoke` | `state.h` | `run_vm` reaches `vm_calls` by import |
| `janet_call_nonfn` | `state.h` | ditto |
| `janet_resolve_method` | `state.h` | ditto |
| `janet_method_lookup` | `state.h` | ditto |
| `janet_unary_call` | `state.h` | ditto |
| `janet_binop_call` | `state.h` | ditto |
| `janet_fill_table` | `state.h` | ditto |
| `janet_fill_struct` | `state.h` | ditto |
| `janet_fill_string` | `state.h` | ditto, and see above |
| `janet_debug_frame` | `state.h` | `cfunStack` already used the impl |
| `janet_check_can_resume` | `state.h` | `vm_run.zig` was using it as an abi |
| `janet_fiber_push` | `fiber.h` | Part 11's fourth push, on schedule |
| `janet_vm_state_size` | `state.h` | its only reader was the contract |
| `janet_vm_state_align` | `state.h` | ditto, with `JanetVMAlignProbe` |

Nine of the fourteen are one `state.h` block — the whole "interpreter callees"
section, which is what `run_vm` delegates to. It went in one edit because
`vm_run.zig` had already converted every call to an import; the exports were
kept alive by `test/vm_calls.c` alone.

`janet_check_can_resume` is the one that needed rule 17's second half. Its two
C callers were the contracts, but `vm_run.zig`'s `JOP_RESUME` and `JOP_CANCEL`
arms were reaching it as `c.janet_check_can_resume` — a symbol-table round trip
inside the runtime's own compilation. Unlike Part 7's two, this one is
*harmless*: it reports a signal rather than raising, so there was no flattened
raise to leak. It is `pub fn checkCanResume` now and the call is an import.
**The sweep is worth running even when what it finds is only a round trip.**

**And the export surface moved by three, not fourteen.** Eleven of these
carried `.visibility = .hidden`, because they are declared in `state.h` and
`fiber.h` rather than in `janet.h` and the C build's `-fvisibility=hidden` hid
them. Only `janet_vm_state_size`, `janet_vm_state_align` and
`janet_fiber_push` were plain `export fn`s, and the shared library goes from
758 exported symbols to 755. So the phase's running "242 internal names" figure
becomes **239**, and the two counts — abis retired and symbols shed — are
different currencies. An abi harvest is a *header* cleanup first and a linker
question second.

### The oracle whose second side was the C implementation

Rules 8, 20, 24 and 25 are about an oracle lost in translation and a
replacement found somewhere — in `uname`, in `test/abi.c`, in a duplication the
port introduced. `vm_state` lost one with no replacement anywhere, and the
reason is worth separating from the others.

`test/vm_state.c` opened with

    assert(janet_vm_state_size() == sizeof(JanetVM));
    assert(janet_vm_state_align() == offsetof(JanetVMAlignProbe, vm));

Two compilers' views of `src/core/state.h`: the C build's, and the Zig build's
through `@cImport`. `janet_vm_save` copies the whole structure using the
owner's length, so a disagreement would truncate or overrun a copy and neither
would be a compile error. That was real for as long as C files read
`janet_vm.field`.

Phase 10 deleted the last of those. There is one view now — `@sizeOf(c.JanetVM)`
is what `janet_vm_alloc` allocates, what `janet_vm_save` copies, and what
`janet_vm_state_size` returned — so a Zig contract asserting the equality
asserts a definition. The guard-page case ("a save must copy no further than
the end of the structure") is the same claim from the other end and goes with
it: `janet_vm_save` is `into.* = currentVm().*`, and a whole-struct assignment
writing past the struct is not a behaviour Zig has.

So the section is dropped rather than translated, and the three declarations it
was the only reader of go with it. **The tell that this is the right call
rather than laziness is that the deletion is possible at all**: an oracle with a
live second side has a second reader, and these had none.

What is *kept* from that section, because it is still two independently
produced things: `janet_local_vm()` must answer the address of the object every
translation unit reaches as `c.janet_vm`. One side is what the function
computes, the other where the linker put the symbol `state.h` declares.

### `@hasField` is a better question than `#ifdef`

`test_save_spans_the_structure` scribbles on fields at both ends of `JanetVM`
and checks a save carried them. The last field is configuration-dependent, and
the C original found it through a four-deep cascade — `JANET_EV`,
`JANET_WINDOWS`, `JANET_EV_EPOLL`, `JANET_EV_KQUEUE` — asking four
configuration questions in order to learn one structural fact.

The Zig contract asks the structure: `if (comptime @hasField(c.JanetVM,
"timer_enabled"))`. Shorter, and a better question in two ways. A configuration
that gains a backend needs no branch here, and a field that is *renamed* fails
to compile rather than dropping silently out of the sweep — which is what the
`#ifdef` cascade would have done, and nothing would have said so.

The other translation note in that file is smaller and went the other way:
`traversal_base` is a typed pointer, so `@ptrFromInt(0x5555)` does not compile
and the witness value is `0x5550`. Zig rejecting an unaligned literal is the
same family as Part 10's `intmax_int64_fits_in_a_length` — the compiler
refusing a constant the C original cast silently.

### A contract that tests an abi is not a caller of it

`janet_fiber_push` was the last of the four push abis, and Part 11 predicted
exactly when it would go: "it survives because `test/vm_calls.c` and
`test/vm_entry.c` still call it, and it goes when they do." They went here.

What Part 11 did not predict is that deleting it would break
**`test/fiber_core.zig`**, the Zig contract it had written one part earlier.
That file kept a case reaching the abi by symbol through `harness.abiRaised`,
beside three reaching the kernels by import, and said so in its header: "the C
abi is the one that disappears, so it is the one that rots." It was the last
caller of `janet_fiber_push` in the whole tree.

So the rule that falls out is narrow and worth stating: **an abi whose only
remaining caller is the contract that tests it has no callers.** The test is
not a use. The case is deleted and the header now says why, which is the
second half of rule 30 — say in the file which half of a two-sided claim
survived, because the next reader will look for the other half.

### Three counters that the type system already holds

`vm_lifecycle`, `vm_entry`, `vm_calls` and `vm_run` each counted the refusals
they expected and compared a total at the end, with `EXPECTED_PANICS` and
`EXPECTED_REPORTS` maintained by hand — and in two files with a second value in
an `#ifdef` arm, because a build without the assembler expects four fewer. All
of it is gone.

The reason it existed is `EXPECT_PANIC`'s shape: a macro whose failure to fire
is a statement that did nothing, and a case that silently stopped raising was
indistinguishable from one that passed. `harness.raised` answers `?Raise` and
every site unwraps it, so a refusal that stops arriving fails on its own line.

`vm_entry`'s pair is the interesting one, because the two counters were holding
a *distinction* rather than a total: "the same refusal delivered by the wrong
mechanism would still carry the right message". Four of the six entry points
report a `JanetSignal` and two raise, and getting that backwards turns a
recoverable error into an abort. In Zig that distinction is in the type —
`janet_pcall` and `janet_continue` return `JanetSignal`, `stepImpl` and
`callImpl` return `raise.Error!T`, and `harness.raised` will not compile
against anything else. A refusal that changed mechanism would not build.

### `harness.frame`, and the guard that disappeared

One addition to the shared vocabulary, on the group that first needed it:
`harness.frame.at` and `harness.frame.current`, which are `fiber.h`'s
`janet_stack_frame` and `janet_fiber_frame` — macros `@cImport` does not
translate. Three of the five contracts need them at once. `test/fiber_core.zig`
predates this and keeps a private copy beside two other `fiber.h` macros
nothing else needs, which is the same call `harness.heap` records.

And one guard that is simply gone. `test/vm_lifecycle.c`'s
unregistered-cfunction case ran only under `JANET_ZIG_DEBUG_FRAMES`, because
the C implementation read a cfunction registry entry without checking it for
null and dereferenced null for a function `janet_cfuns` never saw — `FOUND.md`
has it, and `build.zig` passed that file a macro so the case could be pinned
where it was defined and skipped where it was not. There is one implementation
now. The case is unconditional and the macro is one fewer thing `build.zig`
defines.

### Verified to be capable of failing

Five subject mutations, one per contract, each caught, each checked against
rules 21, 23 and 26 — the build's exit status asserted before the contract ran,
and no candidate taken from the image generator's path:

- `janet_interpreter_interrupt_handled` incrementing instead of decrementing,
  so the interrupt counter never balances (`vm_state`);
- `sandbox` no longer asserting `JANET_SANDBOX_SANDBOX` against itself, which
  is the whole one-way property (`vm_lifecycle`);
- `callImpl`'s arity cascade saying "at most" where it means "at least", which
  is the branch that reads plausibly when wrong (`vm_entry`);
- `binopCall`'s right-hand fallback passing its operands in source order rather
  than swapped, which a commutative operator would hide (`vm_calls`);
- `JOP_CALL`'s plural inverted, `argument` for `arguments`, which is the
  mutation the C contract's own comment records finding a gap with (`vm_run`).

### The instruments

`zig build test`, green; every contract run by name in a loop rather than
trusting either driver's abort-at-first-failure (rule 10) — **47 Zig PASS**, up
from 42, and **17 C PASS**, down from 22; five subject mutations, each caught;
two configurations by hand under rule 19 — `-Ddocstrings=false`, the standing
entry, and `-Dsourcemaps=false`, which `vm_lifecycle` names in the source-map
half of its Janet-frame case; and the acceptance matrix with `CONTRACTS`
retargeted to this increment's five, at **21 PASS / 0 FLAKY / 0 FAIL in
176.7s**, every per-entry time at its usual cost.

One note on the C loop, which is rule 10's trap one level up and cost a
misreading: **a plain `zig build` does not install `janet-contract-test`.** It
goes through `installTest`, which returns early without `-Dinstall-tests=true`,
so `zig-out/bin/janet-contract-test` does not exist and a by-name loop over it
reports every C contract as failing. `janet-zig-contract-test` is installed
unconditionally, which is why the Zig half of the loop needs nothing.

A benchmark is owed under rule 18 and was taken: this increment edits `runVm`.
Two `ReleaseFast` binaries, `HEAD` in a worktree against this tree, twelve
stack layouts each on the Phase 9 corpus, minimum per workload, run twice:

| | before | after | run 2 |
| --- | --- | --- | --- |
| arithmetic | 0.047923 | 0.048179 | +0.8% |
| fib | 0.016416 | 0.016182 | −0.4% |
| methods | 0.017830 | 0.019086 | **+5.2%** |
| tables | 0.055510 | 0.055890 | +1.5% |
| strings | 0.051615 | 0.051586 | −0.5% |
| compiler | 0.044968 | 0.044906 | +0.6% |
| pegmatch | 0.040856 | 0.040976 | −0.8% |
| opfallback | 0.016654 | 0.016558 | +0.9% |
| pegcall | 0.006963 | 0.006920 | −0.1% |
| fibers | 0.026277 | 0.026080 | +1.1% |

Everything inside `bench-layout.sh`'s ±5% resolution except **`methods`**, at
+7.0% and +5.2% over two passes — reproducing in the same direction while the
control and every other workload stay flat.

It was probed rather than shrugged at, per rule 16's discipline. The obvious
suspect is the eight `@export`s this part removed from `vm_calls.zig`, since
`methods` is `(:bump obj 1)` four hundred thousand times and therefore the most
`JOP_CALL`-dense workload in the corpus. Restoring `janet_method_invoke`,
`janet_resolve_method` and `janet_method_lookup` and rebuilding gives 0.018902
against the final tree's 0.019180 and the baseline's 0.018235 — about a third of
the gap, so **the exports are not the explanation**.

What is left is codegen. `runVm` is one enormous function, and the fix above
adds two error-propagation points to its dispatch switch where there were none;
`bench-layout.sh` marginalises *stack* layout and does nothing about *code*
layout, which its own header records as worth ±5% on the dispatch-heavy
workloads between builds differing in one file. So: recorded, not resolved, and
accepted — five percent on one workload is the price of a raise that no longer
disappears.

## The registry and arguments

*Phase 11 Part 13.* `utils`, `registry`, `core_env` and `args_core` — 2,187
lines of C for 2,441 of Zig, **one** abi retired, and a live defect in
the layer every cfunction opens with.

The group's headline number is the small one. Twelve parts of contract
migration have retired thirty-one abis, and this group — which contains the
largest abi family in the tree by an order of magnitude — retires exactly one.
That is not a disappointing result; it is the answer to the question the
exported-symbol-surface bullet keeps asking, and it arrives from the opposite
side of every previous part.

### The defect: `(string/format "%d" "x")` killed the process

`args_core.zig`'s `Wide` builds `getInteger64` and `getUInteger64`, and with
integer types enabled those two do not fill in a `JanetArgFault` at all: they
delegate to the conversion in `inttypes.zig`, which raises a message of its own.
The delegation was written as

```zig
const int_types_enabled = @hasDecl(c, "janet_unwrap_s64");
...
if (int_types_enabled) return unwrap(argv[@intCast(n)]);
```

with `unwrap` bound to `c.janet_unwrap_s64` — **the abi**, which is
`raise.reported` over `inttypes.unwrapS64`. So a refusal inside a
`raise.Raising` function became a report nobody consumed: the getter answered
`reportToC`'s zero, its caller carried on with a value the user never supplied,
and the outstanding report killed the process at the next scope boundary.

```
$ janet -e '(try (string/format "%d" "x") ([e] (print "caught: " e)))'
janet abort: a raise was reported to a C caller and never consumed
```

Seven call sites are affected — `pp_format.zig`'s `%d`/`%x`/`%o`/`%u`,
`io_core.zig`'s seek offset, `buffer_array.zig`'s `buffer/push-uint64`,
`os_calendar.zig`, `ffi_marshal.zig` and `ffi_core.zig` — and the C original
propagated correctly, because `janet_getinteger64` called `janet_unwrap_s64`
and that `longjmp`ed. It is a regression the port introduced against the C
baseline rather than a defect in the C implementation, so `FOUND.md` and
guiding principle 8 do not reach it and the fix is taken here. `inttypes.zig`
gained the two Zig entry points the rest of the tree already has a name for —
`unwrapS64` and `unwrapU64` — and `Wide` calls those.

```
$ janet -e '(try (string/format "%d" "x") ([e] (print "caught: " e)))'
caught: can not convert string "x" to 64 bit signed integer
```

**How it was found is the part worth keeping.** Not by a grep and not by a
type: by translating a *skip*. The C contract carries

```c
#ifndef JANET_INT_TYPES
    EXPECT_PANIC(janet_getinteger64(argv, 1), "bad slot #1, expected 64 bit signed integer, got 1.5");
#endif
```

and its expected-panic count is 70 with integer types and 74 without. A
transcription would have carried the `#ifndef` across unexamined; asking *why*
those two cases are skipped in the default configuration is what turned up the
answer — because there the refusal is not a fault the layer renders — and
asking how it raises instead is what found the abi. This is Part 12's lesson
with a different trigger. There, `harness.raised` demanded an error union and
the subject did not return one, so the compiler asked the question. Here
nothing failed to compile: **the question came from a conditional the C
contract had no reason to explain.**

The two cases are now asserted in *both* configurations rather than skipped in
one, which is the assertion the C contract could not make and the reason there
is no expected-panic counter in the migrated file.

### One abi, seventy names, and what that says about the export surface

`janet_text_substitution` is the whole harvest. It is declared in `util.h`
alone, its only in-tree caller reaches `registration.textSubstitution` by
import, and its last C caller was `test/registry.c` — rule 12's shape exactly.
It was a plain `@export` with no `.visibility`, so the shared library went from
**755 exported symbols to 754**: rule 34 in the other direction, where the one
abi that dies is one symbol shed.

Nothing else could go, and the reason is the finding. `args_core.zig` exports
**fifty-one** `raise.panicking` abis — `janet_getnumber` through
`janet_optcstring`, `janet_fixarity`, `janet_arity` — and every one of them is
what `janet.h` promises an embedder writing a native module. The runtime does
not call any of them: it reaches the layer through `arglayer.zig`, so the only
Zig callers left are `interop.zig` and `native_module.zig`, and both wrap each
call in `raise.crossing` deliberately. The same is true of `janet_var`,
`janet_var_sm`, `janet_register`, `janet_resolve_core`, `janet_cfuns_prefix`,
`janet_cfuns_ext_prefix`, `janet_native` and `janet_core_lookup_table`.

Counted rather than asserted, over `src/**.zig` with comments stripped:
**sixty-five of `args_core.zig`'s eighty public exports**, seven of
`registry.zig`'s fourteen and three of `core_env.zig`'s six have no caller
anywhere in `src/` — seventy-five names. Two exclusions keep the number honest.
`janet_register_abstract_type` is left out because `test/marsh.c` still calls
it. And `utils.zig`'s four head accessors are left out although the same grep
flags them, because `@cImport` translates `janet_string_length` and its kin
into inline functions that call the *prototype*: every one of the runtime's
hundreds of `c.janet_string_length` calls is an indirect call to
`janet_string_head`, and a name search does not see it. That is worth
remembering the next time this bullet is measured.

So the count of public exports with no in-tree caller, which Parts 10, 11 and
12 grew to eighteen, is now **ninety-three** — and the shape of the remaining
decision is clear in a way it was not before. It is not a list of names to
prune one at a time. It is a question about `janet.h`, and this group is most
of the answer.

**The grep found one thing beside that**, and it belongs to the same bullet
rather than to this migration: the **twenty-eight `janet_arg_*` kernels** in
`args_core.zig` are plain `export fn`s with no caller outside their own file.
They are declared in `state.h`, they exist because the C arm of `-Dargs-core`
called them across the seam, and that arm has been gone since Phase 10 Part 18.
Twenty-eight symbols, each removable by deleting the word `export`. Left alone
here on purpose — the phase's bullet says the central fix is an
exported-symbols list on the link rather than hand-edited visibilities, and
twenty-eight by hand is exactly the thing that argument is against.

`janet_get_core_table` is a third case and a smaller one: an internal export
whose only remaining user is the contract that tests it. Rule 33 says not to
count the contract, so it has none — but it is an implementation rather than a
abi, and deleting it would delete behaviour, so it is recorded rather than
taken.

### The oracle the head accessors lost, and the two that already existed

`test/utils.c` opened by comparing each of the four head accessors with the
macro of the same name:

```c
assert((janet_string_head)(s) == janet_string_head(s));
```

`janet.h` declares both, C callers get the macro and an embedder linking the
shared library gets the function, and the port has to keep them the same
pointer. **`@cImport` prefers the prototype**, so there is one spelling in Zig
and a translation would compare `c.janet_string_head` with itself — rule 25's
shape, met for the third time this phase.

Rule 24 says to ask where the comparison already lives before building a third
one, and both halves of this one were already built. `test/abi.c` carries
`sizeof(Head) == offsetof(Head, data)` for all five heads as static assertions,
which is C's view of `janet.h`'s layout and the only place the flexible array
member is visible at all — Part 8 moved them there for this reason.
`test/gc_mark.zig` carries the run-time half, that the runtime's own `@sizeOf`
arithmetic agrees with what the allocator did.

What is left for the migrated file is a real question rather than a
consolation: **the four accessors in `utils.zig` recover what four other files
wrote.** A string's length goes in through `string_symbol.zig`'s private
`stringHead` and comes out through `utils.zig`'s `headOf`; a struct's through
`struct_table.zig`'s. So each case builds a value with a constructor and reads
its head back with the accessor, plus one assertion that the accessor moved by
exactly `@sizeOf(Head)` — the Zig side of the equality `abi.c` pins from the C
side.

### A contract's premise can be about data, and then `const` is the wrong word

Rule 28 says a contract whose premise is "these two things differ" must ask
what makes them differ *to the compiler*, and Part 11 met it as three identical
cfunction bodies folding into one address. **Part 13 met the same rule in
data.**

`test/registry.c` declares two abstract types with the same name, because the
section is about the registry refusing a second type under a name that is
taken:

```c
static const JanetAbstractType probe_at = { "registry/probe", NULL, ... };
static const JanetAbstractType probe_at_same_name = { "registry/probe", NULL, ... };
```

Transcribed as two `const`s, their initialisers are identical and every
optimize mode above Debug merges them into one address. Registering the
"different" type then registers the *same* pointer, which is the no-op case
asserted three lines earlier, so no refusal happens and `harness.raised(...).?`
unwraps a null. The matrix reported

```
FAIL  ReleaseSafe   test / error: process terminated with signal ABRT
FAIL  ReleaseFast   test / error: process terminated with signal ABRT
FAIL  ReleaseSmall  test / error: process terminated with signal TRAP
```

with `zig build test`, `port/contract.sh` and every by-name run — all Debug —
green. That is rule 29 exactly, and the diagnosis followed its recipe: build
`-Doptimize=ReleaseSafe` by hand, run the driver with no argument, and read
which contract the list stops after.

The fix is one word: `var` rather than `const`, since two mutable objects must
have distinct addresses and nothing writes to either. The premise is now also
*asserted* at the head of the section, so a future merge fails by name instead
of as a null unwrap three assertions later.

**So rule 28 generalises past function bodies.** Identical function bodies fold;
identical constant initialisers merge. The question is the same one — is this
contract's premise a premise the compiler shares — and the answer has to be
made true rather than assumed in both.

### The registry finally gets distinct keys

The C original's growth section says its own limitation out loud: "every row
needs a distinct key, and the key is a function pointer, so the keys have to
come from somewhere. Offsetting into a table of distinct pointers is not
available in portable C." It settles for pushing the *same* pointer 513 times,
so the ordering assertion beside it — that the whole registry is sorted by
pointer — ran over three distinct rows and five hundred identical ones.

A comptime family gives as many distinct probes as are asked for, and each
returns a different integer so that rule 28's fold is illegal. Sixteen of them
are registered and each is looked up afterwards, so a sort that loses or
duplicates a row is caught rather than merely ordered. The capacity fill stays
as it was, with a repeated pointer, because what it tests is the `realloc` and
neither the growth nor the new capacity reads the key.

### `harness.abiRaised` learns that an abi can return something

One harness edit, and it is the kind rule 22's neighbourhood produces:
`abiRaised` called its abi as a bare statement, which every previous user
could afford because every previous abi returned `void`. `janet_native`
answers a `JanetModule`, so the call is now discarded with `_ =`. What it
answers on the raising path is `reportToC`'s zero rather than anything a
contract should read, and the declaration says so.

`harness.internal` gained seven `util.h` declarations — `janet_hash_mix`,
`safe_memcpy`, `janet_strbinsearch`, the two dictionary probes,
`janet_binding_from_entry` and `janet_get_core_table` — under the block's
standing reason rather than a new one.

### Three shims emptied, and none of them retired

`CONTRACT_AT` went from four users to one, `janet_contract_cfunction` from two
to one, and the `arm`/`raised`/`signal` trio from nine to six. Nothing reached
zero: `test/marsh.c` is the last `CONTRACT_AT` user and `test/ev_loop.c` the
last `janet_contract_cfunction` user, and each dies with a contract this phase
already plans to migrate. Rule 22's sweep ran and found nothing already stale.

### Verified to be capable of failing

Four mutations, one per contract, each built successfully before the contract
ran (rule 23) and each caught:

- `janet_sorted_keys` stops skipping tombstones, so an empty dictionary sorts
  to `cap` rather than to nothing (`utils`);
- `janet_registry_put` stops setting `registry_dirty`, so the sort never runs —
  which the runtime survives, because the linear scan in `janet_registry_get`
  makes the bisection dead code (`registry`);
- a parse failure reports `JANET_DO_ERROR_COMPILE` (`core_env`);
- `checkRange`'s upper bound becomes exclusive, so every width rejects its own
  maximum (`args_core`).

### The instruments

`zig build test`, green. Every contract run by name rather than trusting either
driver's abort-at-first-failure (rule 10) — **51 Zig PASS**, up from 47, and
**13 C PASS**, down from 17. Part 12's note about the C loop needs one more
word: `-Dinstall-tests=true` puts `janet-contract-test` under
`<prefix>/test/`, not `<prefix>/bin/`, and a loop pointed at `bin/` reports all
thirteen as failing — rule 10's trap for the third time, and it costs a minute
every time because the symptom is a clean sweep of failures rather than an
error. Four subject mutations, each caught. Two
configurations by hand under rule 19: `-Ddocstrings=false`, the standing entry,
which `registry` names because `checkEntry` asserts a `:doc` key; and
**`-Dprf=true`**, which `utils` names because `janet_string_calchash` has two
implementations and the configuration picks one. The matrix has no `prf` entry
and neither did anything else, so the half-SipHash constants in that branch had
never been run in this project's life. They pass.

The acceptance matrix with `CONTRACTS` retargeted to this increment's four, at
**21 PASS / 0 FLAKY / 0 FAIL in 177.4s**, every per-entry time at its usual
cost — after the `const`-merge failure above, which is what the first run was
for.

A benchmark is owed under rule 18, because the defect fix edits the argument
layer. Two `ReleaseFast` binaries, `HEAD` in a worktree against this tree, over
two million `(string/format "%d" i)` calls — the densest `getInteger64`
workload the tree can express — at 0.23/0.24s before and 0.23/0.24s after. The
change replaces a C-ABI call with a direct one, so a regression would have been
a surprise; the point of measuring was that the call is on a hot path at all.

`panics.py` is 0 and stays 0.

## The marshalling and PEG group

*Phase 11 Part 14.* `marsh` and `peg` — 1,635 lines of C for 1,651 of Zig,
**zero** abis retired, **two `test/support.zig` shims retired outright**,
one live defect fixed, and seven more of the same defect found by a sweep that
had never been run.

Two contracts rather than four, because the group is two. It is also the group
that finally empties something: `janet_contract_abstract_type` — the
`CONTRACT_AT` macro and the sixty-four-entry adapter pool under it — and
`janet_contract_raising` both went to zero users here, the first shims a single
increment has emptied since Part 12's `janet_contract_adapt_regs`.

### The defect: `janet_marshal_size` had no raising twin

`marsh.zig` exposes the marshal context API twice: a `pub fn` that raises and a
`raise.reported` abi over it, so that a Zig caller reaches the first and a
native module the second. Twenty of the twenty-one entry points have both.
`janet_marshal_size` had only the abi:

```zig
export fn janet_marshal_size(ctx: [*c]c.JanetMarshalContext, value: usize) callconv(.c) void {
    raise.reported(marshalInt64(ctx, @bitCast(@as(u64, value))));
}
```

and `marshalling.zig`'s header said, in the list of what it deliberately left
out, that `janet_marshal_size` was "reached from inside the subsystem". It was
not. `peg.zig`'s `pegMarshal` and `io_core.zig`'s `fileMarshal` are both
`raise.Raising` callbacks and both called the abi, so a refusal inside it
became a report nobody consumed — the callback carried on writing, and the
outstanding report killed the process at the next scope boundary.

What can refuse there is a buffer that will not grow. `marshalInt64` reaches
`bufferExtra`, which raises `buffer overflow` past `INT32_MAX` and
`buffer cannot reallocate foreign memory` on a pointer-backed one; `marshal`
takes a target buffer as its third argument and `ffi/pointer-buffer` makes a
foreign one, so the whole path is spellable from Janet:

```
$ janet -e '(def b (ffi/pointer-buffer (ffi/malloc 64) 11 0))
            (try (marshal (peg/compile "a") @{} b) ([e] (print "caught: " e)))'
janet abort: a raise was reported to a C caller and never consumed
```

Eleven is not arbitrary, and sweeping the capacity is what pins the diagnosis
to one call rather than to the subsystem:

| capacity | 9 | 10 | **11** | 12 | 13 | 14 | 16 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| before | raises | raises | **abort** | raises | raises | raises | fits |
| after | raises | raises | raises | raises | raises | raises | fits |

`LB_ABSTRACT` plus the eleven bytes of `core/peg` fill exactly eleven, so
capacity 11 is the one where the *first* write that overflows is
`janet_marshal_size`. At every other capacity the overflow lands in a call that
already raised properly, which is why nothing had ever seen this.

`marsh.marshalSize` is the twin, `janet_marshal_size` is now
`raise.reported` over it, and both callbacks `try` it. This is a regression the
port introduced against the C baseline rather than a defect in the C
implementation — `janet_marshal_size` `longjmp`ed there — so `FOUND.md` and
guiding principle 8 do not reach it, and the fix is taken here. That is Part
12's and Part 13's reasoning for the third time.

### The sweep this one deserves, and the seven it found

Parts 12, 13 and 14 have each found this defect a different way — a type that
would not unify, a `#ifdef` with no stated reason, a callback written out in
full. All three are accidents of what the increment happened to be doing, and
the class is mechanically enumerable:

  1. every `export fn janet_*` whose body contains `raise.reported`;
  2. every `c.janet_*` call site of one in `src/zig`;
  3. whether the *enclosing* function's return type is `raise.Raising`.

Seventy-nine reporting abis, twenty-nine call sites, **nine raising callers** —
two of them in `ev_loop_extern.zig`, which is one of the eleven stranded
`_extern.zig` files nothing analyses, so they are noise. The other seven are
live and are the same defect:

| abi | raising caller |
| --- | --- |
| `janet_stream` | `filewatch_core.zig`'s `init` (twice) and `add`, `os_files.zig`'s `openImpl` |
| `janet_loop` | `core_env.zig`'s `janet_dobytesImpl` and `loopFiber` |
| `janet_compile_lint` | `compiler_primitives.zig`'s `cfunCompile` |

Each is one line. **None is taken here**, and the reason is scope rather than
doubt: every one belongs to a subsystem whose contract has not migrated —
`filewatch_core`, `io_core`, `ev_loop`, `core_env`, `compiler_primitives` —
and turning a contract migration into seven runtime edits across five
subsystems is how an increment stops being reviewable. `phase_11.md` carries
them as an item of their own.

The sweep itself is the more useful output. It costs seconds, it is the third
increment in a row to want it, and it should be run per increment from here
rather than waited for.

### `BAIL_IF_RAISING`, and what a shim count hides

`test/marsh.c` could not define an abstract type. The hinge typed
`JanetAbstractType`'s `marshal` and `unmarshal` as raising Zig functions, so a
C contract's callbacks had to go through `janet_contract_abstract_type`, which
wrapped each in a thunk that turned a standing report back into an error. What
that cost inside the callback is the part worth keeping:

```c
#define BAIL_IF_RAISING(value) do { if (janet_contract_raising()) return (value); } while (0)

static void *probe_unmarshal(JanetMarshalContext *ctx) {
    Probe *probe = janet_unmarshal_abstract(ctx, sizeof(Probe));
    BAIL_IF_RAISING(NULL);
    probe->i32 = janet_unmarshal_int(ctx);
    BAIL_IF_RAISING(probe);
    ...
```

Eight reads, eight tests after them, and they were not defensive: the
truncation section cuts the stream at every offset in turn, so each one really
is reached, and a callback that carried on would read past the end of the
source. In Zig every one of them is `try`, and `janet_contract_raising` — which
existed for this file alone — goes with the file.

The pool went the same way. Eight contracts used `CONTRACT_AT`; all eight have
migrated, and a Zig contract writes `abstract_type.AbstractType` with raising
callbacks directly. So the entry price the pool existed to pay is not paid
differently — it is not paid. That is rule 27 again: the shims that made this
group look expensive are exactly the part that cost nothing.

### An oracle that could not be written where it was wanted

`test/peg.c` asserted the shape of `janet_peg_type` — thirteen callbacks, each
present or absent — through `janet.h`'s `JanetAbstractType`. The Zig runtime
defines the same object as an `abstract_type.AbstractType`, which is the same
layout with seven callbacks typed as raising. **Two descriptions of one table,
and comparing them is rule 25's shape**: a duplication the port introduced,
wanting the contract the old pair had.

The migrated contract reads both, and both agree. What would not compile into
an assertion is that they are the *same object*:

```zig
assert(@as(*const anyopaque, @ptrCast(&peg.janet_peg_type)) ==
       @as(*const anyopaque, @ptrCast(&c.janet_peg_type)));   // fails
```

It fails, and the addresses are equal. `nm` says so —

```
00000001004d7608 (__DATA,__const) external     _janet_peg_type
00000001004d7608 (__DATA,__const) non-external _peg.janet_peg_type
```

— and a `std.debug.print` of the two `@intFromPtr`s prints one number twice.
**Zig compares the addresses of two distinct declarations at comptime, and two
distinct declarations are not equal**, whatever the linker later does with the
`export`. Sameness here is a link-time fact and the comparison never reaches
run time.

Two things came out of that, and neither is where the assertion started.

**The layout claim went to `abstract_type.zig`**, which is rule 20's answer:
ask what the two sides of the comparison were, and the answer may name a file
the increment was not otherwise touching. That file already asserted
`@sizeOf(AbstractType) == @sizeOf(c.JanetAbstractType)` at comptime, which is
weak — every field is pointer-sized, so a field inserted into one mirror and
removed from the other leaves the size alone and shifts every later slot, which
is a `marshal` that dispatches to `unmarshal`. It now walks the two field lists
together and compares names and `@offsetOf`. A `@compileError` reaches every
build rather than one contract, and the claim is about the two types rather
than about the PEG engine.

**The identity claim went through the registry.** `janet_get_abstract_type`
answers a pointer it was handed at registration, from the import side; comparing
*that* with `&c.janet_peg_type` is a run-time comparison of a run-time value,
so nothing folds it. Two lines, and together they say what one line could not.

### Asking the wrong thing, and rule 35's limit

`test/marsh.c` chose the weak-container lead bytes with `#ifdef JANET_EV`,
because `LB_THREADED_ABSTRACT` and `LB_POINTER_BUFFER` sit inside that guard in
the lead-byte enum and the seven weak bytes after them do not — so the weak
bytes are 226..232 with an event loop and 224..230 without. That is upstream's
defect and `FOUND.md` has it.

Rule 35 says to ask the thing rather than the build that produced it, so the
first translation asked the enumeration:
`if (@hasDecl(c, "LB_POINTER_BUFFER")) 226 else 224`. It compiled, and it was
wrong by two, because **the lead-byte enum is private to the subsystem and is
in no header at all** — `@hasDecl` answered false in a build that has an event
loop. The contract died on its first weak assertion.

So rule 35 has a precondition: the thing has to be askable. What the contract
asks instead is `c.JANET_VM_HAS_EV`, which is the config header's — the same
input `marsh.zig`'s own `has_ev` reads, and the same one `#ifdef JANET_EV` was.
What it must *not* read is `marsh.zig`'s `weak_base`, which is the arithmetic
under test; that would be rule 8's circularity one import away, and it is the
mistake that was available here.

### Zero abis, and twenty-one more names

Every entry point these two contracts reach is declared in `janet.h`:
`janet_marshal` and `janet_unmarshal`, the twenty-one context functions,
`janet_env_lookup` and `janet_env_lookup_into`, `janet_register_abstract_type`,
`janet_peg_type`. None may go, for Part 13's reason exactly — they are what a
native module writing a marshallable abstract type calls — so the library stays
at **754 exported symbols** and this is the second increment running to retire
nothing.

What it adds is to the other side of the ledger. Twenty-one of them now have no
caller anywhere in `src/`: `janet_marshal_size` (whose two callers this
increment moved to the import), the six other `janet_marshal_*`, the eleven
`janet_unmarshal_*`, the two `janet_env_lookup*`, and
`janet_register_abstract_type` — which Part 13 had excluded from its count
precisely because `test/marsh.c` still called it. Ninety-three becomes
**114**. `janet_marshal` and `janet_unmarshal` are held out on the same rule
Part 13 used, because `test/ev_loop.c` and `test/io_core.c` still call them;
they make it 116 when those go.

Three abis keep a runtime caller and are not on the list:
`janet_marshal_abstract`, `janet_marshal_flags` and `janet_unmarshal_flags`.
All three are field reads or a table insert — none can raise — which is why
they were never the defect above and why nothing wants a raising twin for them.

### Verified to be capable of failing

Two mutations, one per contract, each built successfully before the contract
ran:

- `marshalPtr`'s unsafe gate inverted, so safe mode writes a pointer and unsafe
  mode refuses (`marsh`) — caught;
- `verifyBytecode`'s final pass tests `op_flags[i] == 0x03` rather than `0x01`,
  so a rule operand pointing into the middle of another instruction is no
  longer rejected (`peg`) — caught.

**The first `peg` mutation is rule 23's trap for the third time.** Setting
`peg.has_backref = 0` in `pegUnmarshal` left the local it replaced unused, Zig
rejected the build, `zig-out` still held the previous binary, and the contract
passed against an unmutated runtime. The exit-status check is what turned a
confident wrong answer into a discarded attempt.

### The instruments

`zig build test`, green. Every contract run by name rather than trusting either
driver's abort-at-first-failure (rule 10) — **53 Zig PASS**, up from 51, and
**11 C PASS**, down from 13. Two subject mutations, both caught, and one
discarded under rule 23. The full build after the migration, because
`zig build zig-contract-test` does not build the C driver (rule 14).

The acceptance matrix with `CONTRACTS` retargeted to `marsh` and `peg`, at
**21 PASS / 0 FLAKY / 0 FAIL in 178.7s** against a usual 171s, every per-entry
time at its usual cost. No hand-rolled configuration sweep beside it: the two
entries these contracts name are both matrix entries — `no event loop` for
`marsh`'s weak lead bytes, `no int types` for `peg`'s readint width — and `no
peg` already carried the `skip` this contract needs.

A benchmark is owed under rule 18, because the fix edits `pegMarshal`. Two
`ReleaseFast` binaries, `HEAD` in a worktree against this tree, over 200,000
`(marshal peg)` round trips — the densest `janet_marshal_size` workload the
tree can express — at a minimum of 0.0573s before and 0.0582s after, with
identical output byte counts. That is +1.5% on a corpus whose floor is about
5%, so it is unresolved rather than a regression; the point of measuring was
that a C-ABI call became a direct one on a path a contract now exercises.

`panics.py` is 0 and stays 0.

## The swallowed raises, and the sweep that had to be written three times

*Phase 11 Part 15.* Not a contract migration. **Thirteen call sites across
seven subsystems where a `raise.Raising` function reached a raise through a
abi**, so the refusal became a report nobody consumed and the process
died at an unrelated scope boundary. `port/swallowed.py` is the increment's
real output; the fixes are what it found.

### Why a script rather than an eleventh finding

Three consecutive increments met this defect three different ways:

| | how it was found | what it cost |
| --- | --- | --- |
| Part 12 | `harness.raised` demanded an error union and `vm_calls.fillString` did not return one | a compile error, free |
| Part 13 | an `#ifndef JANET_INT_TYPES` in a C contract with no stated reason | a question nobody had to ask |
| Part 14 | writing an abstract type's `marshal` callback out in full | a capacity sweep to localise |

Every one of those is an accident of what the increment happened to be doing,
and the symptom is the least informative message in the runtime:

```
janet abort: a raise was reported to a C caller and never consumed
```

It names neither the abi nor the file, and it fires at the next protected
scope rather than at the call. Meanwhile the class is mechanically
enumerable, which is `phase_11.md`'s rule 40 and is what this part carries out.

### The script, and the three times it was wrong

Worth recording because each correction changed the answer, and the first
version would have been published as complete.

**First: `raise.reported` is not the only abi constructor.** The hand-rolled
version in Part 14 looked for `export fn janet_*` whose body contains
`raise.reported`, and found seventy-nine abis and seven live sites. But
`raise.panicking(f).abi` ends in `reportToC` too, and those are `@export`ed
from a `comptime` block rather than written as `export fn`. Counting both:
**119 abis**, not 79.

**Second: the caller is often not the raising function.** `net_sockets.zig`'s
`makeStream` is a *non-raising helper* around `janet_stream` with four raising
callers, and `vm_calls.zig`'s `methodToFun` sits two levels under `binopCall`.
So a function that reaches an abi and cannot itself propagate is an abi in
turn, to a fixpoint — **88 such helpers**.

**Third, and the one that actually hid a defect: a call site need not spell a
abi at all.** `inttypes.zig` has

```zig
const unwrap = if (T == i64) janet_unwrap_s64 else janet_unwrap_u64;
...
var acc: u64 = @bitCast(Box(T).unwrap(argv[0]));
```

Nothing there is a `c.janet_*` call. The abi is a bare identifier in the file
that defines it, bound through a comptime alias, and read at the call site as a
struct member. `grep c.janet_unwrap_s64 src/zig` reports the file clean. All
three spellings are matched now.

The counterweight is recognising a *legitimate* call, and there are three
spellings of that too — `try raise.crossing(abi(...))` wrapping it,
`_ = try raise.crossing({})` on the following line, and an alias built through
`raise.declared(...).call`. Getting that wrong is the difference between a
report worth reading and six sites of which five are correct code.

**Verified capable of failing**, which is rule 21 applied to a tool rather than
to a mutation: re-introducing four of the fixed defects makes it name five
sites (`inttypes` has two), and restoring them makes it silent again.

### What it found

Thirteen sites, of which eleven were found by the script and two more by
reading the file it pointed at. Several are reachable from ordinary Janet
source; the rest are the same shape on a path that needs a failing syscall.

| abi | raising callers |
| --- | --- |
| `janet_stream` | `filewatch_core.zig`'s `init` ×2 and `add`, `os_files.zig`'s `openImpl`, `net_sockets.zig`'s `makeStream` (four cfunctions under it, plus both accept callbacks) |
| `janet_loop` | `core_env.zig`'s `janet_dobytesImpl` and `loopFiber`, `ev_loop.zig`'s `goThreadBodyImpl` |
| `janet_compile_lint` | `compiler_primitives.zig`'s `cfunCompile` |
| `janet_get` | `vm_calls.zig`'s `methodToFun`, under `resolveMethod`, `unaryCall`, `binopCall` and `mcall` |
| `janet_unwrap_s64` / `janet_unwrap_u64` | every arithmetic method of `int/s64` and `int/u64`, through `Box(T).unwrap` |

The last is the one that matters most, and it is **Part 13's defect in the file
Part 13 fixed it for.** That part gave `inttypes.zig` the `unwrapS64` and
`unwrapU64` entry points because `args_core.zig`'s `Wide` was reaching the abi
from a raising caller. It did not look at `inttypes.zig`'s *own* callers, and
`Box`'s alias kept every boxed-integer operator on the abi:

```
$ janet -e '(print (try (+ (int/s64 1) {}) ([e] (string "caught: " e))))'
janet abort: a raise was reported to a C caller and never consumed

$ janet -e '(print (try (+ (int/s64 1) {}) ([e] (string "caught: " e))))'   # after
caught: can not convert struct {} to 64 bit signed integer
```

Any arithmetic between a boxed 64-bit integer and a value that will not convert
— a table, a struct, a tuple, a string that does not scan, a keyword — killed
the process instead of raising. `(+ (int/s64 1) "x")`, `(* (int/u64 2) [1])`,
`(band (int/u64 1) :nope)` and the whole `r`-prefixed family with the operands
the other way round.

**Finding it needed a trace rather than the sweep**, because the sweep's third
correction did not exist yet. `janet_zig_c_raise_record` with a
`dumpCurrentStackTrace` in it names the reporting site directly, which is worth
knowing: the abort's own trace names `janet_restore` and tells you nothing.

### The two sites that looked like a design decision and were not

`net_sockets.zig`'s remaining callers of `janet_stream` are **event-loop
callbacks** — `acceptPosix` and `schedAcceptImpl` — and they were held back
from the conversion on the reasoning that a callback has no scope above it to
raise into. That is `abstract_type.zig`'s argument for typing `gc` and `gcmark`
non-raising, and it is the right argument for *those* two. Their behaviour was
worse than a swallowed report, which is what made the question feel like it
needed answering rather than deferring: `raise.reported` answers `blank(T)`,
and `blank` of a `*JanetStream` is a **null pointer**, so a refused
registration left both dereferencing null on top of the outstanding report.

**The argument does not survive reading the file.** `ev_callback.EVCallback`
is

```zig
pub const EVCallback = *const fn ([*c]c.JanetFiber, c.JanetAsyncEvent) raise.Error!void;
```

— the hinge typed it raising exactly as it typed `JanetCFunction`. And ten
lines from the site being excused, `acceptWindows` is *already*
`raise.Raising(void)`, already reports a failed accept with
`try evloop.cancel(fiber, ...)` and `janet_async_end(fiber)`, and the shared
dispatcher already `try`s it. Only the POSIX half had been left non-raising.

So there was no decision to take: the file had already made it, and the fix is
the same conversion as the other ten. `acceptPosix` becomes raising and
`schedAcceptImpl` too — the latter keeping its own `err`/`true` protocol for
the two failures `janet_ev_lasterr` genuinely describes, and using `try` for
the registration, which carries its own message. `swallowed.py`'s `ALLOW` list
is empty, with the reason recorded beside it.

**The general lesson is about where to look for a policy**, and it is cheap:
before treating a conversion as a design question, read the sibling that does
the same job on the other platform. Half of `#ifdef`-split code has already
answered the question the other half is asking.

**And the Windows arm needed a cross-compile to find its second caller.**
`schedAcceptImpl` has two, one of them inside `acceptWindows`, which the host
never compiles — so `zig build` was green with the conversion half applied.
That is `AGENTS.md`'s standing warning, and it also turned up the *other*
Windows failure this tree already carries: `test/ev_loop.c`'s three
`INVALID_HANDLE_VALUE`s, which reproduce at the Part 14 commit and are owed to
no recent increment.

### Two things the type system now enforces

`evloop.zig` gained `makeStream`, `makeStreamExt` and `loop`, which were
missing from the façade rather than excluded from it — its header had said the
loop's absent entry points "cannot raise", and all three can. A caller that
reaches for the façade now gets the raising form by default.

And the `inttypes` fix is **compiler-enforced**, which came out of trying to
mutate it. Every `Box(T).unwrap(...)` call site is now `try Box(T).unwrap(...)`,
so rebinding the alias to the abi does not compile: `try` on a non-error value
is an error. That is a stronger guard than any contract, and it is worth
reaching for wherever an abi and its twin differ only in a binding.

### Contract coverage, and rule 23 a fourth time

`test/inttypes.zig` gained `anUnconvertibleOperandRefusesCatchably`: six
expressions through `janet_pcall`, each asserted to answer `JANET_SIGNAL_ERROR`
*and* to carry the conversion's own message, which is what says the refusal
travelled rather than being manufactured downstream. `test/vm_calls.zig`'s
`methodLookup` section became raising, which is rule 33's corollary arriving
from the runtime side — a signature change edits a contract that landed three
parts ago.

The first mutation for that coverage **failed to build**, and the reason is the
paragraph above: reverting the alias leaves nine `try`s on a non-error value.
Rule 23 says a mutation that fails to compile is not evidence, and here the
failure is the point rather than an accident. The replacement — the conversion
returning `0` instead of raising — compiles and is caught.

### The instruments

`zig build test`, green. **53 Zig contracts PASS and 11 C contracts PASS**, each
run by name. `port/swallowed.py` silent, and verified capable of failing.
`suite-net` at 43/43 and `suite-ev` at 832/832 run alone, because
`net_sockets.zig` changed shape. The four cross-compiles by hand rather than
only through the matrix, because this increment converts a function whose
second caller is inside `acceptWindows` — `x86_64-windows-gnu` with
`-Dinstall-tests=true` is the only thing that compiles it, and it caught the
half-applied conversion. `panics.py` 0.

The acceptance matrix with `CONTRACTS` retargeted to the six whose subjects
changed — `inttypes`, `vm_calls`, `core_env`, `compiler_primitives`, `marsh`,
`peg` — at **21 PASS / 0 FLAKY / 0 FAIL in 178.8s**, every per-entry time at
its usual cost.

### The benchmark, and a corpus that had to be rebuilt twice

Rule 18 applies and hard: this increment converts `Box(T).unwrap`, which every
boxed-integer operator reads twice per operation, and `methodToFun`, which the
binop fallback and every keyword-callee `JOP_CALL` reach.

**Ask what the changed lines are reachable from — of the benchmark, not only of
the code.** The first corpus had a `length` on a buffer as its
`methodToFun` workload. Probing it — a `std.debug.print` in each converted
function, five iterations, count the lines — gives:

| workload | `methodToFun` hits | `unwrapS64` hits |
| --- | --- | --- |
| `(length @"abcdefgh")` ×5 | **0** | **0** |
| `(+ (int/s64 x) one)` ×5 | 5 | 12 |
| `(:m t)` ×5 | 5 | 0 |

`length` on a buffer is `JOP_LENGTH` handled in the interpreter; `janet_mcall`
is only reached for an abstract without a `length` callback. So that row
measured nothing this increment touched, and it became the **control**. The
probe also earned the arithmetic row its place: `(+ (int/s64 a) b)` is not one
converted path but both, at about one `methodToFun` and two-and-a-half
`unwrapS64` per iteration.

**And then the control said the corpus was not measuring.** At 400,000
iterations the workloads ran 2–14ms, and a layout-swept control read
**−6.1%** — larger than any workload. That is `AGENTS.md`'s rule exactly: a
corpus whose control is large has not measured its workloads, whatever they
say. Scaling the loops twenty-fold, to 300ms workloads and a 43ms control:

| | pass 1 | pass 2 |
| --- | --- | --- |
| `s64arith` | −0.8% | +0.6% |
| `u64arith` | −0.5% | −1.6% |
| `method` | +0.9% | +2.0% |
| **control** | **−1.5%** | **−1.2%** |

Two `ReleaseFast` binaries, the Part 14 commit in a worktree against this tree,
each swept over twelve initial stack layouts with the minimum per workload.
Every sign flips between passes and no workload clears its own control, so the
floor is about 2% and **nothing here is resolvable** — which is the answer a
conversion that strictly removes a C-ABI indirection should give. What the
measurement establishes is the absence of a regression on two hot paths, not a
win.

## The FFI group, and a seam that outlived both its ends

*Phase 11 Part 16.* `ffi_layout`, `ffi_classify` and `ffi_core` — 1,966 lines
of C for 1,906 of Zig, **twelve exported symbols retired**, and the largest
move the library's export count has made in this phase: **754 to 742**.

Three contracts, no shim emptied, and one finding that is not about the
contracts at all. The FFI group is where the migration stopped being a way to
kill *abis* and became a way to find a **seam** — a C-ABI boundary between two
subsystems that were both Zig, kept because nothing had ever asked it to
justify itself.

### What the contracts were the last readers of

`test/ffi_layout.c` opened with six hand-written declarations:

```c
/* Declared rather than included from src/core/ffi.c, so the contract depends
 * only on the internal ABI it exercises. */
int32_t janet_ffi_decode_prim(const uint8_t *name, int32_t len);
```

`test/ffi_classify.c` had five more and `test/ffi_core.c` four. None of the
twelve is declared in `janet.h`, `state.h`, or any other header — they were
`export fn`s reached by a hand-written `extern fn` at the one place that
called them, which is what `ffi.c` needed when the type system was C and the
kernels were the first Zig inside it.

Phase 10 Part 18 made both ends Zig and nothing changed, because there was
nothing to change: an `extern fn` declaration compiles forever, a symbol that
resolves says nothing, and the calls kept working. `ffi_types.zig` was reaching
`ffi_layout.zig` through the symbol table; `ffi_call.zig` was reaching
`ffi_classify.zig` the same way. **The seam was invisible for two phases and it
took a contract to ask about it**, because a Zig contract wants the same import
its subject's caller wants, and writing the import is what makes the export's
last reason visible.

So the sequence is rule 12's, one level up. Rule 12 says the way to find a dead
abi is to migrate its contract and then delete it. Here the abis were *not*
dead — each had exactly one caller — and the right move was to convert the
caller. The twelve:

| file | symbols | caller that was crossing |
| --- | --- | --- |
| `ffi_layout.zig` | `janet_ffi_decode_prim`, `janet_ffi_decode_cc`, `janet_ffi_type_extent`, `janet_ffi_layout_init`, `janet_ffi_layout_place`, `janet_ffi_layout_finish` | `ffi_types.zig` |
| `ffi_classify.zig` | `janet_ffi_sysv64_classify`, `janet_ffi_aapcs64_classify`, `janet_ffi_win64_alloc`, `janet_ffi_sysv64_alloc`, `janet_ffi_aapcs64_alloc` | `ffi_call.zig` |
| `ffi_call.zig` | `janet_ffi_trampoline` | its own three convention wrappers |

All twelve were plain `export fn`s with no header, so all twelve were rule 34's
*other* case: every one of them moved the number. Part 12 retired fourteen
abis for three symbols; this one retired twelve for twelve.

### Six copies of three structures, compared by nothing

The seam cost more than the symbols. A C-ABI call between two Zig files needs
the argument types spelled at both ends, so `TypeNode`, `ArgSlot` and
`AllocResult` each existed **three** times — in `ffi_classify.zig`, in
`ffi_call.zig`, and in `test/ffi_classify.c` — and `Layout` three times, in
`ffi_layout.zig`, `ffi_types.zig` and `test/ffi_layout.c`. Nothing compared any
pair of them.

That is rule 38's hazard without rule 38's defence: `abstract_type.zig` mirrors
`janet.h`'s `JanetAbstractType` and walks the two field lists together on names
and `@offsetOf` as a `@compileError`, precisely because a pointer-sized field
inserted on one side and removed on the other leaves `@sizeOf` alone. These
mirrors had neither the walk nor the `@sizeOf`. And the risk was not
hypothetical — Phase 10 Part 16 *appended* `arg_stack_count` to `AllocResult`,
by hand, in two files, and the field's own comment records that it was appended
rather than placed where it belongs "so that the field order the two arms of
this selector already agree on is left alone". The arms have been gone since
Part 18; the constraint they imposed outlived them by five parts.

After the conversion there is one definition of each and the caller imports it.
The count that used to be a `u32` parameter beside a `[*]ArgSlot` is a slice's
own, and `packed_field: c_int` is a `bool`.

### What the contracts should import, and what they must not

The migration's one real judgement, and it goes both ways in the same file.

`test/ffi_classify.c` declared its own copies of the three structures **and**
its own copies of the primitive and word-spec ordinals, for one reason: both
were file-local to `ffi.c` and a C contract could not reach either. Translating
that faithfully would keep both copies; translating it lazily would import
both. Neither is right.

- **The structures should be imported.** What the C contract's copy bought was
  a fourth unchecked mirror. One type shared by subject and contract cannot
  drift, which is strictly stronger than a copy nothing compares.
- **The ordinals must not be.** They are the *values* the classifier and
  `ffi_call.zig`'s `Spec` enumeration agree on, and either end can be wrong
  about them. `assert(decodePrim("void") == @intFromEnum(PrimType.void))` is an
  assertion that cannot fail; `assert(decodePrim("void") == 0)` is the one the
  C contract was making. Both files write the numbers out, with the reason at
  the top.

The distinction generalises and is `phase_11.md`'s rule 46: **import the thing
whose identity matters, write out the thing whose value matters.**

### The alignment oracle, rebuilt rather than translated

`test/ffi_core.c` spelled its own alignment macro, because `alignof` is not in
c99:

```c
#define ALIGNOF(type) offsetof(struct { char c; type member; }, member)
```

That is alignment derived from the compiler's *struct layout*. `@alignOf(T)` is
the direct question — and it is also the expression `ffi_types.zig`'s `primInfo`
uses, so a translation reaching for it would have compared `primInfo` with
itself for all thirty-six entries. `alignOfMember` in the migrated file is the
C macro's shape in Zig:

```zig
fn alignOfMember(comptime T: type) usize {
    return @offsetOf(extern struct { leading: u8, member: T }, "member");
}
```

Rules 8, 20, 24 and 25 ask what the two sides of the original comparison were.
Here the answer was cheap, and asking is what kept the section from becoming
thirty-six tautologies. The same question in `test/ffi_layout.zig` has the same
shape and the same answer: the host-ABI section compared `janet_ffi_layout_*`
against `offsetof` on three real C structures, and `extern struct` with
`@offsetOf` is the same claim asked of the same ABI by a different
implementation of it — Zig's, rather than this hand-written machine's.

### What the migration added

Lesson 2 again, and it is one line. Both classifiers open with a guard for a
walk of no nodes:

```zig
if (nodes.len == 0) return sysv64_no_class;
```

Nothing had ever reached either guard. A zero-length array is not something
`test/ffi_classify.c` could spell, and `ffi_call.zig` always serializes at
least the root of a type. In Zig an empty slice is `&.{}`.

### Verified to be capable of failing

One mutation per contract, each after a build whose exit status was asserted —
rule 23, and rule 26's reminder that a failure need not look like a compile
error:

| contract | mutation | result |
| --- | --- | --- |
| `ffi_layout` | `.{ "ulong", .uint64 }` → `.uint32` in the name table | caught |
| `ffi_classify` | `node.struct_size > 16` → `>= 16` in the SysV struct rule | caught |
| `ffi_core` | `result.arg_stack_count` assigned *after* the payload words are added | caught |

The third is the one worth keeping. It collapses the outgoing/frame split that
Phase 10 Part 16 added the field for — and **`ffi_classify` does not catch it**,
checked by running that contract against the same mutant. The group's three
contracts are not three views of one subject: `ffi_classify` asserts where each
argument lands, and only `ffi_core` asserts how many of the resulting words are
*parameters*.

### The instruments

`zig build test`, green. **56 Zig contracts and 8 C contracts PASS**, each run
by name. `port/swallowed.py` silent, at 118 abis rather than 119 —
`janet_ffi_trampoline` is an abi by its shape and was correctly not a finding,
because a callback entered from a C library has no scope above it to raise
into, which is `abstract_type.zig`'s argument for `gc` and `gcmark`. `suite-ffi`
11/11. `nm -gU zig-out/lib/libjanet.dylib | wc -l` at **742**, measured rather
than subtracted. `panics.py` 0.

The acceptance matrix with `CONTRACTS` set to this increment's three, at
**21 PASS / 0 FLAKY / 0 FAIL in 178.2s** — the same wall time as Part 15's
178.8s, with every per-entry time at its usual cost. Two entries earn their
place here: `no dynamic modules`, which is the arm `ffi_core` takes when there
is no native object to have, and the three optimize modes, which are where
rules 28 and 36 would have fired if this group had carried a premise the
compiler is allowed to break. It does not — nothing here needs two things to
differ.

### The benchmark

Rule 18 applies: the increment converted four call sites in `ffi_types.zig` and
`ffi_call.zig`, which is a runtime edit however test-shaped the reason for it.
Nothing it touched is reachable from the Phase 9 corpus — the FFI is not on the
interpreter's path — so the corpus is a new one, three workloads over exactly
what changed and a control that no changed line is reachable from.

Two `ReleaseFast` binaries, `HEAD` in a worktree against this tree, each swept
over twelve initial stack layouts with the minimum per workload. Positive is
slower:

| | pass 1 | pass 2 |
| --- | --- | --- |
| `names` (`ffi/size`, `ffi/align`) | +1.5% | −1.7% |
| `layout` (`ffi/struct`) | +0.3% | +1.6% |
| `signatures` (`ffi/signature`) | −1.0% | −1.2% |
| **control** (arithmetic) | **+1.1%** | **+1.0%** |

Two of the three flip sign between passes and the third does not clear its own
control, so the floor is about 1–2% and **nothing here is resolvable** — which
is again the answer a conversion that strictly removes a C-ABI indirection
should give. The measurement establishes the absence of a regression, not a
win.

## The arity bound, three phases after it was agreed

*Phase 11 Part 17.* One line in `ffi_call.zig` and one section in
`test/ffi_core.zig`. Not a port and not a migration: `FOUND.md`'s only
agreed-but-unmade fix, taken as a deliberate divergence from upstream.

`ffi/signature` stores `max_args` argument mappings and checked only the lower
bound of its arity, so the loop that fills `mappings` and `slots` ran for
however many types the caller passed:

```zig
try arglayer.arity(argc, 2, -1);
const arg_count: u32 = @intCast(argc - 2);
```

Past the thirty-second argument that writes off the end of two stack arrays,
into the builder's own frame and then its caller's — a safety trap in a checked
build, a silent overrun in `ReleaseFast`, and upstream C's behaviour exactly.
It needs no native library and no call, because `ffi/signature` only *describes*
a call, so a binding generator building a signature from a computed list of
types reaches it with nothing unsafe-looking anywhere in the program.

The repair is the upper bound:

```zig
try arglayer.arity(argc, 2, @intCast(types.max_args + 2));
```

**Spelled `max_args + 2` rather than `34`**, because the bound is on `argc` and
the first two arguments are the calling convention and the return type. The two
numbers are the same limit counted from different ends, and the literal invites
the question every reader will ask.

### What the original write-up missed

`FOUND.md` described the overrun as a write past `mappings` in the builder's
frame. It is also a *call*-path defect: `abst.arg_count = arg_count` recorded
the same unbounded count into the abstract, and `callSysv64` walks
`while (i < sig.arg_count)` over a `sig.args` of exactly `max_args`. So a
signature that survived being built would have been read out of bounds later,
at every call. One bound closes both.

### Why not Part 16, which had the file open

Because Part 16's evidence is that nothing observable changed — three
mutations, a matrix, a benchmark against its own parent commit — and a
behavioural divergence inside that increment would make all of it harder to
read. That is guiding principle 8's separation of compatibility work from
design changes, applied to a change whose *decision* had already been taken
three phases earlier. The trigger this fix had been waiting for fired twice
without being noticed; what it needed at the end was not another trigger but an
increment of its own, however small.

### Verified to be capable of failing

`test/ffi_core.zig` pins thirty-two argument types accepted, the thirty-third
refused, and one far past the bound refused the same way — by message, so the
case distinguishes the arity error from any other refusal. Restoring the `-1`
makes the contract fail, checked rather than assumed. The limit is written out
as a literal there rather than read from `types.max_args`: rule 46, since what
a Janet program can observe is a value, and asking the subject how many
arguments it accepts would pass whatever it answered.

`zig build test` green, `ffi_core` at **17 raises** rather than 15, and the
acceptance matrix at **21 PASS / 0 FLAKY / 0 FAIL**.

## The FFI divergences, and a defect read backwards

*Phase 11 Part 18.* Three deliberate divergences from upstream, taken together
so that the FFI is one decision rather than three spread across the phase: the
homogeneous float aggregate sized by bytes, its unrecorded mirror image on the
return path, and the by-reference slot written eight times too far out. The
first two are below; the third is at the end and is the only one that was a
crash.

AAPCS64 §6.8.2 passes a homogeneous floating-point
aggregate in **one vector register per member**. The C implementation sized it
by bytes, which agrees with the ABI exactly when a member is eight bytes wide —
so an aggregate of `double` was right by coincidence, and one of `float` got
half the registers the callee reads with two members packed into the first.
`FOUND.md` had the entry; this is the increment that took it.

### It is three changes, not one

The entry predicted one: "count members rather than bytes for the `SSE` case".
That is where the defect starts and not where it ends.

**The allocator counts members.** `ArgSlot` gained `hfa_members`, filled by
`slotOf` from the aggregate's `field_count` and left zero wherever the caller
cannot say — a scalar, and a top-level array whose extent both conventions
ignore for a reason `FOUND.md` records separately. The byte arithmetic still
stands there, which is where it was always right.

Worth noting what that field cost: **one edit**. Part 16 collapsed three copies
of `ArgSlot` into one; before that this was three hand-edits with nothing
comparing them, and the compiler would have said nothing if one had been
missed. Here it said something useful instead — adding the field broke both
contracts' slot builders, which is the collapse paying its first dividend.

**The outgoing members are dealt out one to a register.** Counting was not
enough. `marshal.writeOne` lays a struct out at its *natural* offsets, so two
floats still went into the first register whatever the allocator had reserved
behind it. The aggregate is marshalled to scratch and scattered eight bytes
apart.

**The returned members are gathered back**, and this half had no entry
anywhere. Each member returns in its own vector register, so `Aapcs64ReturnSse`
lands them at a stride of eight where the type's own layout is four:

```
ret_hfa2  (1.5 0)        want (1.5 2.5)
ret_hfa3  (1.5 2.5)  ->  (1.5 0 2.5)
```

It was found by asking whether the defect had a mirror image — the entry
describes an *argument* defect throughout, and "allocation" in its title hides
that the same bank is read on the way back. **When a defect is about a
direction, ask what the other direction does**; a register bank has two ends and
an entry written from one of them will not mention the other.

### A placement mistake worth recording

The return gather went into `callSysv64` first, because the edit was anchored on
`frame.release()` and that string appears in all three conventions. It compiled
and every AAPCS64 case passed, because the code was in a function this host's
probe never reaches. It would have corrupted a `{float, float}` SysV return.

Nothing caught it — the probe on this machine runs AAPCS64, and there is no
contract for a SysV struct return. What caught it was re-reading the diff for
where it had landed. **An anchor that appears in three sibling functions is not
an anchor**, and the check is one `grep` for the inserted line.

### Verified to be capable of failing

Each half separately, which is the point: they are two changes and a single
mutation would not have distinguished them.

| reverted | caught by |
| --- | --- |
| the allocator's member count | `test/ffi_classify.zig` |
| the return gather | `test/ffi_core.zig` |
| the by-reference slot's word index | `test/ffi_core.zig` |

**And the contract is a better instrument than the probe here.** A Zig contract
is compiled into the runtime, so it can define the callee itself and make a
real `ffi/call` against a function in the same binary — `hfa2Weighted` and
`hfa2Build` are eight lines, and they run under `zig build test` on every
AAPCS64 host. `port/probe-16/abi/` needs a `zig cc`, a `.dylib` and a driver
script to say the same thing. It keeps its place as the cross-convention
instrument and gains `ret_hfa2`; `hfa2` there goes from 1 to 5.

The section is gated on `ffi/calling-conventions` naming `aapcs64` rather than
on `builtin.cpu.arch`, because what the case needs to know is which convention
`:default` will resolve to — rule 7's question, one subsystem over.

### The third one, where the repair is a deletion

`AAPCS64_STACK_REF` read a byte offset as a word index, so the pointer to a
by-reference payload was written eight times further out than the allocator
planned — past the `alloca` block in C, and into the wrong slot here.
`large_after_stack_arg` in the probe exited 134 because of it.

It hid behind an accident worth stating, because it is why the defect survived
a whole phase of FFI work: the offset is only wrong when it is *nonzero*, so a
by-reference aggregate that is the first thing on the stack works, and one with
any stack argument ahead of it crashes.

The fix is one expression:

```zig
- const slot: *align(1) u64 = @ptrCast(frame.at(@as(usize, arg.offset) * @sizeOf(u64)));
+ const slot: *align(1) u64 = @ptrCast(frame.at(arg.offset));
```

and then `aapcs64FrameBytes` has no callers. That function existed only to grow
the frame far enough that the misplaced write still landed in memory the call
owned; with the write in the right place it is dead, and leaving it would be
rule 31's trap. **The repaired version is sixteen lines shorter than the
reproduction** — which is the answer to "what is the simplest way to handle
this": the simplest and the smallest are the same edit here, because a
workaround for a defect goes with the defect.

**And the edit has to be scoped by hand, for the third time in this
increment.** The identical expression appears in `callSysv64` and
`callWin64`, and in both it is *correct*: those allocators assign `arg.offset`
as a word index and count `stack_count` in words, where this convention counts
bytes throughout. A file-wide replace breaks two working conventions and
neither has a contract that would notice. That is the same hazard the misplaced
`gatherHfaReturn` above demonstrated, met twice in one afternoon in the same
three functions — so it is worth stating as a property of this file rather than
as an anecdote: **`callSysv64`, `callWin64` and `callAapcs64` are three
near-identical bodies over three different units, and no edit to one of them
may be anchored on a string.**

`large_after_stack_arg` now answers 1033, which is the right number and not
merely a non-crashing one: nine integers weighted one to nine are the sum of
the squares, 285, and `[11 22 33]` weighted ten to twelve is 748.

`test/ffi_core.zig` has the case, built to defeat the accident — nine integers
to exhaust the general bank and put one word on the stack, so the pointer slot
lands at a nonzero offset where the two readings finally disagree. Verified by
restoring both lines.

**And the matrix earned its place again on the way in.** The first version of
that case read its answer with `janet_unwrap_s64`, which `janet.h` declares
only under `JANET_INT_TYPES`; `zig build test`, the contract by name and the
probe were all green, and `-Dint-types=false` did not compile. The case returns
a `double` now, because nothing in it is about the return type. This is rule
3's family for the fourth time in the phase — **a contract that moves to Zig
reaches `janet.h`'s declarations rather than its macros, and a declaration
guarded by a feature is a configuration failure waiting for the sweep** — and
it is the second time a *contract* has broken a reduced configuration rather
than a subsystem.

### One thing not taken, and why it is written down

The same `SSE` arm does not set `next_fp_reg = 8` when an aggregate spills,
where the `general` arm sets `next_general_reg = 8`. §6.8.2's C.4 says an HFA
that does not fit exhausts the bank, so a later scalar float may not backfill
the register it skipped. That looks like a defect of the same family and it is
one line — but it has no entry, no reproduction, and no failing case on this
host, and inventing all three inside an increment that already changes
behaviour is how a fix arrives without evidence. Recorded here for whoever
takes the `STACK_REF` decision, since both are §6.8.2 and want reading
together.

## The image stops being C, and the flags for compiling C run out of users

*Phase 11 Part 19.* Not a port and not a contract migration. The bootstrap
image was emitted as a C source file, compiled by a C compiler, and linked into
every binary this tree produces; it is a marshalled byte stream reached with
`@embedFile` now. That is the last C translation unit out of the product, and
it is the item `phase_11.md` scheduled ahead of the remaining contract groups
on the grounds that it needs no decision and is cheaper the earlier it lands.

### What was actually being compiled

`src/boot/boot.janet` printed the image as C text:

```janet
(print "static const unsigned char janet_core_image_bytes[] = {")
(loop [line :in (partition 16 image)]
  (prin "  ")
  (each b line (prinf "0x%.2X, " b))
  (print))
(print "  0\n};\n")
(print "const unsigned char *janet_core_image = janet_core_image_bytes;")
(print "size_t janet_core_image_size = sizeof(janet_core_image_bytes);")
```

`build.zig` captured stdout as `janet-image.c` and handed it to
`addCSourceFile` four times over: the static library, the shared library, the
client, and the Zig contract driver. **2,007,197 bytes of file carrying 324,310
bytes of image** — 84% of it hex text for a C compiler to parse, once per
module, in every one of the matrix's twenty-one entries.

`PLAN.md` counted zero `.c` files under `src/` while this was true, which is
the sense in which it falsified the phase's own gate: the file is generated
rather than checked in, so no `wc` over the tree ever saw it.

**It is not a build-time argument, and that is worth measuring rather than
assuming**, because 2,007,197 bytes of hex text invites one. `zig cc -c -O2` on
that file is 0.19s with the cache busted, four modules take it, and a cold
`zig build` is 7.6s. Three quarters of a second. The reason to do this is the
gate and the C compiler in the pipeline, not the clock.

### The generator was already Zig; only its output was not

Worth stating because the two are easy to run together. Phase 10 Part 17g
removed `-Dboot=c` — the image generator registers the whole core environment,
so a C generator needed every C cfunction there is, and a cfunction stopped
being a C function at the hinge. Part 18 then ported `src/boot/boot.c` to
`src/zig/boot.zig`, the last `main` in C anywhere under `src/`. So for two
parts the pipeline has been a Zig program emitting C for a C compiler to hand
back to Zig.

### The change

The generator writes to a path rather than to stdout:

```zig
generate_image.addArg("image-out");
const image_source = generate_image.addOutputFileArg("janet-image.bin");
```

and `boot.janet` `spit`s the bytes there, `spit` defaulting to `:wb` — which
matters now that the payload is binary and did not while it was C text. A byte
stream through a captured stdout is one text-mode host away from a translated
`0x0A`, and this is a build-time tool that runs on whatever host is building.

The image reaches the runtime as a module import rather than as a symbol:

```zig
if (image_source) |image| module.addAnonymousImport("janet_image", .{ .root_source_file = image });
```

added to the subsystems module inside `makeRuntimeGraph`, which is what makes
one change serve both graphs — the runtime object and the Zig contract driver's
second copy of it. `core_env.zig` replaces two `extern const`s with
`@embedFile("janet_image")`.

**`makeRuntimeGraph` takes the image as an optional and the bootstrap passes
null**, because the generator is the one runtime built without an image: it is
what produces one. Nothing needs guarding for that beyond the optional.
`corefn.bootstrap` is comptime, so `imageCoreEnv` is not analysed in that
build, and a container-level declaration nothing references is never resolved.
That is the same laziness the `extern` relied on, one step earlier — it used to
be the linker that was never asked.

The ordering in `build()` changes with it. `zig_runtime` was the first thing
built and is now built after the generator, because the object *contains* the
image instead of being linked beside it.

### One byte, and the assertion that settles it

`janet_core_image_size` was `sizeof(janet_core_image_bytes)`, and that array
ended in a `0` the emitter appended so it had a terminator. So the runtime has
been handing `unmarshal` **324,311 bytes for a 324,310-byte image** for as long
as there has been an image. `@embedFile`'s `.len` is the file's, so the length
is now the image's.

That is only safe if nothing read the extra byte, which was an assumption
nobody had checked. `test/core_env.zig` checks it:

```zig
const image = core_env.core_image;
var next: [*c]const u8 = null;
const out = try marsh.unmarshal(image, image.len, 0, try core_env.coreLookupTable(null), &next);
assert(harness.isType(out, c.JANET_TABLE));
assert(@intFromPtr(next) == @intFromPtr(image) + image.len);
```

`unmarshal`'s fifth parameter reports where the stream stopped, and nothing in
the tree passed it a non-null pointer for the core image. The stream ends
exactly where the file does, so there was no slack the longer length was
covering for.

### `common_c_flags` had no users left, and nothing said so

Two lines below the image in `addRuntimeSources`:

```zig
if (!sel.vector) module.addCSourceFiles(.{ .files = &.{"src/core/vector.c"}, .flags = common_c_flags });
if (!sel.regalloc) module.addCSourceFiles(.{ .files = &.{"src/core/regalloc.c"}, .flags = common_c_flags });
```

`zigSelection` has said `.vector = true` and `.regalloc = true` **literally**
since Phase 10 Part 18 deleted both files. Neither branch could be taken and
each named a source that is not there. `build.zig` is an ordinary Zig program,
so the branch compiles and the string is just a string — rule 31's blindness in
the build script rather than in a subsystem, and rule 22's in a file nobody
thinks of as code.

Removing the image and those two lines left `common_c_flags` — the flag set for
C compiled *into the product* — with **no user at all**, which Zig does not
diagnose either, because an unreferenced container declaration is not an error.
It is gone. `test_c_flags` remains and the name is now the whole distinction:
every C flag in `build.zig` is a flag for something under `test/`.

That is this increment's own evidence for its claim. "No C is compiled into the
product" is otherwise a thing to be checked by reading; "the C flags have no
users" is a thing the file says. The archive says it too — `ar t
zig-out/lib/libjanet.a` lists **one object**, `janet-zig.o`, where it listed
two. `boot.zig`'s header comment used to end "and the reason `janet-image.o` is
in the archive".

### The amalgamation went with it, having been dead for a phase

The emitter above was the tail of one function that also produced the
amalgamated `janet.c`: a `feature-header`, nine `local-headers` and fifty
`core-sources`, each `slurp`ed and printed. Every one of the fifty is a
`src/core/*.c` that Phase 10 Part 18 deleted, so `janet.c` has been
unproducible for a phase and nothing in the tree asks for it. `Makefile` and
`meson.build` name the same missing sources and are in the same state, which
`phase_11.md` already records as a deletion rather than a decision.

### `image-diff.py` had been unrunnable since Part 17g

It built `-Dboot=c` and `-Dboot=zig` and diffed the two images. That option went
with the last cfunction-bearing C arm, so every invocation since has failed at
the first build — and nothing said so, because nothing runs it but a person.
The same silence as a stranded `_extern.zig`, one directory over.

Rewritten around the two questions it can still answer: the absolute host paths
the image embeds, and the bytes against a saved copy (`--save` on one host,
`--against` on the other), which is what the reproducibility bullet compares now
that the artefact is the bytes rather than something to be recovered from C text
around them.

### And it was one of four

Rule 47's own prescription is to grep `port/` for a build option an increment
deletes. Two were deleted — `-Dboot` in Phase 10 Part 17g, `-D<selector>=c|zig`
in Part 18 — and four scripts still passed one of them:

| script | | |
| --- | --- | --- |
| `image-diff.py` | `-Dboot=c`, `-Dboot=zig` | repaired |
| `differential.sh` | `-D<sel>=c`, `-D<sel>=zig` | **deleted** — there is no second arm to diff |
| `panics.py` | globs `src/core/*.c` | **deleted** — the directory holds no `.c` |
| `mutate.py` | `-Dboot=zig`, two of three stages | **repaired** |

The last is the one that mattered, and it is worse than silence. The mutation
sweep is a queued gate item; a sweep that reached the `boot` stage would have
failed its build for a reason having nothing to do with the mutant, and
`judge_boot` scores a failed build as **caught**. Every mutant would have come
back caught and the sweep would have read as a perfect result. That is rule 23 —
"a mutation that fails to compile is not evidence" — pre-armed in the tool
rather than met one mutant at a time.

**The `boot` stage went with its reason rather than being rewired.** It existed
because `janet_core_env`'s bootstrap half was compiled only by the image
generator and the generator was C by default, so a mutation to the Zig
bootstrap half was not compiled by `default` at all. Part 17g removed the C
generator; every `zig build` now builds `janet-boot` from these sources, because
that is the only thing that can emit an image. `default` therefore reaches what
`boot` was added for — and Part 10's lesson 26 is the evidence, two
`value_wrap.zig` mutations having broken the bootstrap under a plain
`zig build`. Two stages now, `default` and `full`.

The repair is smoke-tested rather than assumed, which is the whole point of the
finding: `./port/mutate.py --only 4` runs its two baselines — `zig build` ok in
11s, `zig build test` ok in 8s — where the previous code would have died at
`zig build -Dboot=zig` before reaching a mutant. The one site chosen came back
`uncompilable`, which is the verdict rule 23 asks for and is exactly the
distinction the broken stage would have destroyed: a build that fails for a
reason unrelated to the mutant must not be scored as a catch.

`differential.sh` and `panics.py` are the harmless kind and are deleted rather
than repaired. `panics.py` counts `janet_panic` call sites surviving the
preprocessor in `src/core/*.c` and can report nothing but 0 for the rest of the
project; `differential.sh` runs one Janet script under both arms of a selector
and there is no selector. **A gate check that can only report a constant is not
a check**, and `phase_11.md`'s gate list carried the first of them as one.

**And the first thing it reported is that the twenty-two absolute paths are
zero.** Phase 10 Part 6 found the image is not reproducible across checkouts,
because `build.zig` hands the C compiler absolute paths, `__FILE__` keeps them,
and a core cfunction's source file goes into the image. A Zig-registered
cfunction records a repo-relative path — `src/zig/subsystems/io_core.zig` — so
the figure fell by one per C file an increment emptied and reached zero when
Part 18 took the last of them. Every source path in the image today is
repo-relative; `/Users` and `/private` appear nowhere in it. **Nobody knew,
because the instrument that would have said so could not run.** That is half of
the reproducibility bullet arriving as a measurement rather than as work.

### Verified to be capable of failing

Three mutations, all in the emitter, because that is where the new failure
modes are.

**A truncated image.** `(spit image-out (slice image 0 1000))` builds cleanly —
`zig build` is green and the library links — and every runtime then dies with
`unexpected end of source`. `zig build test` fails at seventeen `run exe janet`
steps. Worth recording as a property rather than only as a check: **a plain
`zig build` does not exercise the image at all**, and did not when it was C
either. The link is not the test.

**A trailing byte.** `(spit image-out (buffer image 0))` restores exactly what
the C array had, and the new assertion fails at its own line with `next` one
short of the end. Checked by running the mutated binary out of the cache rather
than `zig-out`, because the build failed at the *run* step and `zig-out` still
held the previous binary — rule 23's trap, arriving unprompted.

**Both restored, and the image compared.** The bytes the byte-emitter writes
are identical to the bytes the C emitter's array held, all 324,310 of them, the
C form having carried a 324,311th that was the terminator. Two runs of the new
generator agree with each other as well, which is same-host reproducibility and
the cheap half of that bullet.

### The instruments

`zig build test` green. `core_env` and `marsh` by name through
`port/contract.sh`. A build-only sweep over twenty-two configurations — the
matrix's twenty-one flag sets plus `-Ddocstrings=false`, rule 19 — all PASS,
which is where `-Dreduced-os=true` was settled: the generator now calls `spit`,
so `file/open` has to be registered in every configuration that builds an
image, and `io_core` is unconditional. `port/swallowed.py` silent. The acceptance matrix
with `CONTRACTS` set to `core_env` and `marsh`: **21 PASS / 0 FLAKY / 0 FAIL**
in 177.9s, against the usual 171s, which is rule 16's check passing rather than
a figure worth reporting.

## The OS and IO remainder, and thirty-four symbols between two Zig files

Phase 11 Part 20. `test/os_process.c`, `test/io_core.c` and `test/os_surface.c`
— 2,133 lines — become `test/os_process.zig`, `test/io_core.zig` and
`test/os_surface.zig`, 2,082 lines in the Zig driver. Five contracts remain in
C and all five are the event-loop group.

The migration itself was the second-cheapest of the phase, for Part 16's
reason: two of the three subjects are scalar kernels over bytes and integers,
and the third is mostly Janet source driven through the interpreter. What the
part cost is the thing beside it, and that is rule 44 at four times the scale
Part 16 found it.

### Thirty-four exported symbols, none of which had a caller outside Zig

Part 16's grep is "`extern fn` inside `src/zig` naming something defined inside
`src/zig`", and this group answered it four times:

| declared in | reached | how many |
| --- | --- | --- |
| `os_procs.zig` | `os_process.zig` | 14 |
| `os_files.zig` | `os_stat.zig` | 3 |
| `io_core.zig` | `host_stat.zig` | 1 |
| — | `io_core.zig`'s own kernels | 15 |

The first three are the same shape Part 16 described: a symbol that existed
because one end was C, kept after both ends became Zig, and silent about it,
because an `extern fn` declaration compiles forever and a symbol that resolves
says nothing. The fourth is the shape *without* a caller at all — fifteen
`janet_io_*` kernels whose only reader was `io.c` and then this contract.

`nm -gU zig-out/lib/libjanet.dylib | wc -l` is **708**, from 742. Rule 34's
figure, read rather than subtracted.

**One symbol was kept on purpose and that is the interesting one.**
`janet_io_write` stays, because `pp_format.zig` reaches it by symbol
deliberately — the note beside that declaration says importing `io_core.zig`
would make the printer depend on the whole io surface. Part 20 did not overrule
it. So the rule is not "an `extern fn` between two Zig files is a defect"; it
is "an `extern fn` between two Zig files is a *claim*, and most of them turn
out to be nobody's." Fifteen of sixteen here were nobody's and the sixteenth
had an argument.

### An abi whose last caller went two phases ago

`janet_io_set_cloexec` was the handle-taking abi over `setCloexecStream`, and
its only caller was `io.c`. Phase 10 Part 18 deleted `io.c`. Nothing announced
it: an `@export` with no caller links forever, its neighbours in the same
`comptime` block still had callers, and the *internal* half of the pair is
still used, so even a reader of the file sees a live function one line below a
dead one. It is deleted, and this is Part 9's lesson about a dead file, one
declaration down.

### A check that had silently stopped skipping

`test/os_surface.c` ran its source-map order check only under `-Dboot=zig`, and
explained why: the C bootstrap recorded `src/core/os.c` for every one of these
bindings however the surface was compiled, so under `-Dboot=c` the loop was a
presence check that skipped.

`-Dboot` was deleted in Phase 10 Part 17g. What is worth recording is the shape
of the gate rather than the staleness: it was never a `#ifdef`. The contract
tested the source-map path at **run time** —

    int from_zig = janet_string_length(file) > 8 &&
                   memcmp(file, "src/zig/", 8) == 0;

— so it self-gated on data, correctly, whatever the build did. The comment
above it is the part that named the option, and the *data* changed under both:
Part 18 emptied the last C source, so every path in the image became
`src/zig/`-relative and the check silently went from skipping to running. It
has been a real assertion for two phases and the file said it was a presence
check.

This is rule 47 arriving from `test/` rather than from `port/`. That rule was
written about scripts passing a flag the build no longer defines; the same
question — **what did this condition depend on, and does that still exist?** —
is worth asking of a contract's own conditions, and it is Part 13's lesson
about `#ifndef JANET_INT_TYPES` from the other side. Part 13 asked what a skip
claimed about the subject and found a defect. This one asked what a skip
depended on and found that the skip had stopped happening.

### The hazard a migrated contract acquires, found only by cross-compiling

`test/io_core.c` wrote `stdout`. The translation of it does not survive being
written in Zig: `c.stdout` is an inline **function** in Darwin's headers, a
**variable** of opaque type on musl — which is not callable — and on mingw a
container-level constant whose initializer calls an extern function, which Zig
rejects outright as `comptime call of extern function`. `stdio.zig` exists for
exactly this and its header comment has the table; the runtime has not named
`c.stdout` since Phase 10.

The migrated contract named it anyway, compiled on the host, passed, and failed
**four cross-compile entries of the matrix** — three musl targets on the
callability and mingw on the comptime call. Nothing on macOS could have said
so.

Two things worth keeping. This is the general form of Part 1's
`janet_wrap_integer` lesson — *a contract that moves to Zig acquires the whole
`@cImport` hazard list* — with the strongest instance yet, because the C
spelling is a single word that any C programmer would write without thinking.
And the matrix's four **build-only** entries earned their place here: they are
not a compile check that happens to run, they are the only instrument in the
tree that sees this class.

### What the contracts stopped restating

Three blocks of numbers went. `test/os_process.c` carried
`#define JANET_OS_WAIT_EXITED 0` and its three siblings; `test/io_core.c`
carried `JANET_IO_MODE_OK` and its four. Each was a third copy of a value two
files already agreed on, kept because a C contract could not see a `const`
inside the subject. Both sets are `pub const` on the subject now and the
contracts name them, so a renumbering is a compile error rather than a passing
assertion against a stale literal.

The third is `janet_contract_at_next` and `janet_contract_at_get`, which called
a raising abstract-type callback on C's behalf and flattened the error into a
report. `janet_file_type` is an `abstract_type.AbstractType` — the mirror whose
`get` and `next` are typed raising — so `test/io_core.zig` calls the callbacks
and handles the error. Both shims now have one user, `test/ev_loop.c`, and
`janet_contract_call_cfunction` has two.

### Some of `os_process` is asserted twice, deliberately

`os_process.zig` carries `test` blocks over the escaping, the signal lookup and
the environment rule, and `zig build test` runs them; the C contract asserted
the same things because C could not reach a `zig test`. The duplication is kept
and the migrated contract does not shrink to avoid it, for one reason:
**`port/mutate.py` scores contracts and does not run `zig build test`**, so a
mutation in `escapeArgument` is caught by one of the two instruments and not
the other. Which of two overlapping tests the sweep can see is a property of
the sweep, not of the tests.

### `harness.inFiber`, and why it is in the harness

`janet_dostring` evaluates each *top level* form in its own fiber and does not
drive the event loop, so a form that spawns a process and then waits on it can
outlive the wait that follows. Both `os_process.c` and `os_surface.c` solved
that identically — wrap the whole source in `(fn [] ...)`, make one fiber,
root it, schedule it, run the loop, assert it is dead — in eleven lines under
an `#ifdef JANET_EV`, twice.

Two contracts in one increment needing the same idiom is the harness rule, so
it went to `test/harness.zig` with `harness.has_ev` beside it. It is the first
thing in the Zig driver that drives the loop at all.

### Rule 9, one directory further out

`os_surface` writes nothing to the working tree — Phase 10 Part 12 moved its
fixtures to `/tmp` after a mutant left a mode-0000 file in the repository root
— and it still may not be named in `matrix.py`'s `CONTRACTS`, because it builds
`/tmp/janet-os-surface-contract` and expects to own it. Two `contracts` entries
run concurrently in the same working directory *and* on the same host, so the
rule is about a **shared fixture** rather than about the working directory; the
path is only where the shared fixture usually is. `io_core` is excluded by the
rule as written and `os_process` writes nothing anywhere, so `CONTRACTS` is
`("os_process",)`.

And `os_process` needed the other half of the matrix's per-increment edit:
`-Dreduced-os=true` compiles no process subsystem, so the contract does not
exist there and the driver says so with an exit code. That is `skip=`, which
AGENTS.md documents for `-Dpeg=false` — and it is worth noting that the
preflight cannot catch this one, because the name *is* a real contract file.

### Verified to be capable of failing

Three mutations, one per contract, each in the subject rather than in the
contract.

**`envKeyOk` stops rejecting `=`.** `test/os_process.zig` asserts that a key
holding the separator is refused; caught.

**`whence_names` reordered**, so `:cur` and `:set` exchange positions. Caught —
and re-run after the `stdio.zig` fix, because the contract file had changed
under it.

**`os/clock` registered as `os/clocks`.** Caught twice over: the expected
binding is absent, and the environment holds an `os/` symbol the list does not
name. Worth recording that this one *built* — `os/clock` is not on the image
generator's path, so rule 23's bootstrap trap did not fire.

### The instruments

`zig build` green, `zig build test` green, all fifty-nine Zig contracts green
in one driver run. The three migrated contracts by name through
`port/contract.sh`. `port/swallowed.py` silent. No benchmark is owed: the
runtime edits are import-for-symbol substitutions and four deletions, none of
which changes what is computed.

The acceptance matrix with `CONTRACTS = ("os_process",)`: **21 PASS / 0 FLAKY /
0 FAIL**, after a first run of 16 PASS / 5 FAIL that found both faults above —
one `skip=` and four cross-compiles — in 177.4s, and a 34.7s re-run of the five.
Reporting the first run's verdict rather than only the second is the point of
running it.

## The event loop's kernels and the watcher's vocabularies, and seventeen more symbols between two Zig files

Phase 11 Part 21. `test/ev_core.c`, `test/filewatch_flags.c`,
`test/filewatch_core.c` and `test/net_sockets.c` — 1,671 lines — become
`test/ev_core.zig`, `test/filewatch_flags.zig`, `test/filewatch_core.zig` and
`test/net_sockets.zig`, 1,650 lines in the Zig driver. **One contract remains
in C**, and it is `test/ev_loop.c`.

The group boundary is not where the line count would have drawn it. This file's
estimate said the event-loop group was five contracts and one or two parts; the
split taken is four and one, and the reason is the shims. `janet_contract_arm`,
`janet_contract_raised`, `janet_contract_signal` and
`janet_contract_call_cfunction` had exactly two users each —
`test/net_sockets.c` and `test/filewatch_core.c` — so taking those two retires
four shims, and the other five (`at_get`, `at_next`, `at_tostring`,
`cfunction`, `protect`) are on `test/ev_loop.c` alone and cannot go until it
does. Rule 22 says a shim's user count decides when it dies; here it decided
where the part ended.

### Seventeen exported symbols, and the same seam twice

Rule 44's grep — an `extern fn` inside `src/zig` whose target is defined inside
`src/zig` — answered twice in this group, and the larger answer wore a disguise
Part 20's did not:

| declared in | reached | how many |
| --- | --- | --- |
| `ev_loop.zig` | `ev_core.zig` | 13 |
| `filewatch_core.zig` | `filewatch_flags.zig` | 4 |

**The `ev_core` half is the form to watch for, because the declaration is a
namespace.** `ev_loop.zig` did not merely declare the thirteen kernels; it
declared them `pub`, and `ev_channel.zig` and `ev_backend.zig` then reached
them as `ev.janet_ev_q_pop` and `ev.janet_ev_ts_to_parts`. Twenty-nine of the
fifty-two call sites are in those two files, so the seam looked from every
caller like an ordinary import of a neighbour — the symbol table was doing the
work of a `pub const`, and only the one file holding the `extern` block could
see it. Part 20's instances were a file calling a symbol; this one is a file
*re-exporting* symbols, which is the same defect with a better hiding place.

`nm -gU zig-out/lib/libjanet.dylib | wc -l` is **691**, from 708. Rule 34's
figure, read rather than subtracted. None of the seventeen is in any header —
the C contracts hand-declared every one — so unlike Part 12's fourteen abis
for three symbols, all seventeen counted.

### Two mirrors went with them, which is rule 45 arriving on time

Rule 45 says to count the mirrors before counting the symbols, because a C-ABI
call between two Zig files needs its argument types spelled at both ends and
nothing compares them. Both ends of both seams had one.

`ev_core.zig` kept a private `Queue` — a four-field `extern struct` mirroring
`state.h`'s `JanetQueue` — while `ev_loop.zig` passed `*c.JanetQueue`, and the
two met as a pointer at a symbol. There was a *third* copy in `test/ev_core.c`.
The kernels take `*c.JanetQueue` now, which is the type the `janet_vm` fields
are declared with, so the mirror is not merely deleted but unrepresentable.

`filewatch_core.zig` kept `platform_linux`, `platform_windows` and
`platform_kqueue` as bare `u32`s beside a comment saying they mirror
`filewatch_flags.zig`'s `Platform` enumeration. They existed because a `u32`
was the only thing that could cross the seam; the lookups take `Platform` now
and a caller names the tag. `test/filewatch_flags.c` and
`test/filewatch_core.c` had a fourth and fifth copy of the same three numbers.

### Three assertions the type refused, and where they went

Rule 42 says a type refusing a regression beats a contract catching it. Rule 30
says an assertion that loses half its subject should say which half survived.
This increment is the first where both apply to the same edits, and the answer
is to write the loss down at the site rather than to let a reader find an
absence.

**The distinction that matters is whether the subject's branch went with the
assertion.** In two of the three cases it did, and that is the whole of why
the loss is acceptable: what was a run-time refusal is a compile error at the
call site, and the deleted assertion has a deleted branch to match. In the
third the subject never had a branch, and what is lost is a *detection
technique* rather than a check.


- **`janet_ev_q_pop(&q, NULL, sizeof(int32_t))`.** The C contract passed a null
  destination so that a write on the empty-queue path would be a segfault
  rather than a wrong value. `qPop` takes `*anyopaque`; there is no null to
  pass. **`ev_core.zig` never had a guard for it** — nothing was deleted from
  the subject — so what replaces it is the sentinel the same C function also
  carried: `out = 12345`, the pop reports 1, `out` is still 12345. That is
  weaker by exactly the difference between "wrote anything" and "wrote
  something other than 12345", and it is the one place in this increment where
  coverage genuinely thinned.
- **`janet_filewatch_flag_count(3)`, `janet_filewatch_flag_name(3, 0)` and
  `janet_filewatch_flag_index(3, "all")`.** The ordinal was a `u32` and each
  lookup answered -1 or NULL for a platform naming no backend. The parameter
  is `Platform` now, so the call does not compile — **and `namesFor`'s
  `else => null` arm and the three `orelse return -1` guards are gone from the
  subsystem with it.** Every caller names a tag, so the deleted branch has no
  way in; the only route back would be `@enumFromInt` on an untrusted ordinal,
  which nothing does and which is checked illegal behaviour in Debug and
  ReleaseSafe anyway. The subsystem's own `test` block for the case is gone
  too, replaced by the note saying why.
- **`janet_filewatch_flag_name(PLATFORM_LINUX, -1)`.** A position below the
  table. The parameter is `usize`, so the `index < 0` half of that guard is
  gone from the subject. The `index >= names.len` half remains and is asserted,
  in both the contract and the subsystem's tests.

None of the three is a case anyone would rather have back as a test. What would
be wrong is to delete them silently, because the next reader of either file
will go looking for the pair.

### `net_sockets` builds its addresses from `std.posix`, and that is an oracle rather than a convenience

`test/net_sockets.c` included `<netinet/in.h>` and `<sys/un.h>` and laid down a
`struct sockaddr_in` by hand. The decoder under test reads one described by
`net_abi.h`'s translation of those same headers — so the bytes the contract
wrote and the bytes the subject read came from one description, and a contract
comparing a description with itself is rule 8's circularity with a network
stack in the middle.

The migrated file uses `std.posix.sockaddr.in`, `.in6`, `.un` and `.storage`,
whose layouts `std` states per platform and independently, and parses the
textual addresses with `std.Io.net.Ip4Address.parse` rather than `inet_pton`.
Two descriptions again, and the port field is `std.mem.nativeToBig` rather than
`htons` for the same reason. It also keeps the contract module free of a fourth
`@cImport` of the socket headers, which is the practical half.

One detail is deliberately unchanged: each structure is zeroed and then has its
family, port and address set, which is what the C contract's `memset` produced.
macOS's `sin_len` is therefore zero in both, and the decoder does not read it.

### The backend a contract believes in

`test/filewatch_core.c` chose its vocabulary with `#if defined(JANET_LINUX)`
… `#elif defined(JANET_APPLE) || defined(JANET_BSD)`, which is exactly the
cascade `filewatch_abi.h` uses to set `JANET_ZIG_WATCH_BACKEND`. Two
descriptions of one fact, agreeing by construction.

Asking the subject — `filewatch_core.zig`'s `backend` — would have collapsed
them into one, which is what rule 8 warns about. The migrated contract reads
`builtin.os.tag` instead: Zig's view of the target rather than the C
preprocessor's, and a genuinely different input. If the two ever disagree the
contract fails, which is what an oracle is for.

### `zig build test` runs the vocabularies too, and the duplication stays

`filewatch_flags.zig` carries `test` blocks over the same orderings the
contract asserts. Rule 52 settled this in Part 20 and it applies unchanged:
`port/mutate.py` scores contracts and does not run `zig build test`, so a
mutation in the tables is caught by one instrument and not the other. Deleting
the "redundant" half would be invisible until the queued gate sweep ran.

### `harness.callCore` and `harness.coreRaised`

Two contracts in one increment needed the same thing, which is this file's rule
for putting an idiom in the harness rather than in each subject. Every C
contract whose subject is a cfunction surface wrote the same `call_core`
static:

    static Janet call_core(const char *name, int32_t argc, Janet *argv) {
        Janet fun = janet_resolve_core(name);
        assert(janet_checktype(fun, JANET_CFUNCTION));
        return janet_contract_call_cfunction(janet_unwrap_cfunction(fun), argc, argv);
    }

In Zig the shim is gone and what is left is the `argc`/`argv` split, which a
contract otherwise spells at every call from an array it already has.
`harness.callCore` is that with `try`; `harness.coreRaised` is the same call
under a protected scope, answering the raise. `test/ev_loop.zig` will want
both.

Each contract keeps its own `expectRaise` wrapper, because that one carries the
file's name, its message comparison and its raise counter — the parts that are
not shared.

### What was not taken, and why

**`janet_address_type` is still a `pub extern const` in `ev_loop.zig`**, naming
what `net_addr.zig` defines: rule 44's class, in this group, found by this
increment. It is not taken here. `ev_stream.zig` reaches it through that
declaration and compiles whenever the event loop does, while `net_addr.zig`
exists only under `-Dnet`, so the conversion is a question about what
`-Dnet=false` leaves reachable rather than a substitution. It belongs with
`ev_loop`'s own migration, which is the increment that has to answer it anyway.

**The heap kernels still take a base pointer, a stride and a field offset.**
That interface exists because `JanetTimeout` could not cross a C ABI — it
carries a `pthread_t` on POSIX and two `HANDLE`s on Windows — and with both
ends Zig a comptime element type and field name would say the same thing and
check it. Not taken, for Part 16's reason: `test/ev_loop.c` is the oracle over
those callers until Part 22 migrates it, and a design change inside a migration
puts a behavioural edit in an increment whose whole evidence rests on nothing
observable having changed. The note is at the site.

### Verified to be capable of failing

Four mutations, one per contract, each in the subject rather than in the
contract, and each with the build's exit status asserted first — rule 23.

**`heapSiftUp` compares with `<` rather than `<=`.** A parent equal to the
child then reports a swap, which is the tie case `test/ev_core.zig` asserts in
two places. Caught.

**`q-overflow` renamed in the inotify table.** Caught by the position
assertion, which is the one that matters: the index is what selects a flag
value in the other half.

**`"expected keyword, got %v"` reworded.** Caught by the message comparison in
`test/filewatch_core.zig`, not merely by the fact of a raise.

**`"unknown socket option %q"` reworded.** Caught, and worth quoting because it
is what a message assertion buys:

    expected: unknown socket option :so-nonsense
         got: unknown sockopt :so-nonsense
    thread 61225633 panic: net_sockets: the raise carried another message
    test/net_sockets.zig:489:20: in theStreamFaults

### The instruments

`zig build` green, `zig build test` green, all sixty-three Zig contracts green
in one driver run. The four migrated contracts by name. `port/swallowed.py`
silent — 118 abis now, one fewer than Part 20 saw. The `port/` grep for a
deleted build option found nothing, because this increment deletes none.

The acceptance matrix with `CONTRACTS = ("ev_core", "filewatch_flags",
"net_sockets")`: **21 PASS / 0 FLAKY / 0 FAIL** in 178.2s wall, which is the
usual figure and therefore satisfies rule 16 as well as its own verdict.
`filewatch_core` is held out of `CONTRACTS` on rule 53 rather than rule 9 — it
writes nothing to the working tree and owns `/tmp/janet-filewatch-contract`,
which is `os_surface`'s shape exactly — and the `full` entries run it, because
`zig build test` runs the whole Zig driver.

**No benchmark is owed, and the reasoning is worth stating because it is not
Part 20's.** Part 20 declined on the grounds that import-for-symbol
substitution changes nothing that is computed, which is true here too: a call
through the symbol table becomes a direct call, and a direct call cannot be the
slower of the two. But this increment touched the *event loop's* hot path —
`qPush` and `qPop` run per channel operation — so rule 18's "read what the
increment touched" points at code the standing corpus does not execute at all.
`port/probe-9/bench/bench.janet` is a VM and PEG corpus. Running it would have
produced a number about something else, and reporting that number as evidence
would be worse than reporting none.

## The last C contract, the driver that ran it, and an alias that was a copy

Phase 11 Part 22. `test/ev_loop.c` — 1,062 lines — becomes `test/ev_loop.zig`,
1,095 lines in the Zig driver, and **`test/contracts.c`, `test/contracts.h`,
`test/support.h` and `test/support.zig` go with it**: 364 further lines, the C
driver's `build.zig` target, its second `abi` translation, the `raise` and
`abstract_type` modules built on that, and the unconditional install of
`janet-contract-support.o`. `build.zig` is 104 lines shorter.

**There is no C contract left in the tree.** `test/` holds `abi.c` and
`embed.c` beside the suites and six files in subdirectories, and none of the
eight is a contract — they are the endgame's question, which is whether this
fork still owes a C program anything.

### What the five shims were, and what replaced each

`test/support.zig` existed because Phase 10 Part 17g gave `JanetCFunction` the
type `raise.CFunction`: a raising Zig function with Zig's calling convention,
which C can neither call nor be. Eleven shims were written over that gap and
this increment spent the last five:

| shim | what a Zig contract does instead |
| --- | --- |
| `janet_contract_protect` | `harness.raised` — the same scope, without the C body |
| `janet_contract_at_get` | `janet_stream_type.get.?(...)` with `try` |
| `janet_contract_at_next` | `janet_stream_type.next.?(...)` with `try` |
| `janet_contract_at_tostring` | `janet_stream_type.tostring.?(...)` with `try` |
| `janet_contract_cfunction` | a cfunction written in Zig, stored with `raise.stored` |

The right-hand column is the argument for Part 1's decision, restated at the
end of the phase it opened: none of these is an *adapter* any more, because
there is no boundary to adapt across. A contract compiled into the runtime
calls what a subsystem calls.

**One section had a shim as its subject, and it did not simply go.**
`test_protect_scope` tested `janet_contract_protect` — three claims about a
scope: a returning body reports nothing, a raising body reports the signal and
publishes the payload, and scopes nest. That is test-only code, so the obvious
move is to delete the section with the shim. But the three claims are true of
`harness.raised`, which is the mechanism **sixty-four contracts rest on and
nothing else asserts directly**, so they are kept and pointed there. The
nesting case is the one that earns its keep: `janet_restore` has to put back
what `janet_try_init` displaced rather than null, and only a nested scope can
tell the difference.

### The Windows arm compiles now, and the gap closed itself exactly as predicted

`phase_11.md` recorded that `zig build -Dtarget=x86_64-windows-gnu
-Dinstall-tests=true` failed on three `INVALID_HANDLE_VALUE`s in
`test/ev_loop.c`, that it reproduced at Part 9's `HEAD`, and that no standing
instrument could see it: `janet-contract-test` went through `installTest`,
which returns early unless `-Dinstall-tests=true`, and the matrix's four
build-only entries do not pass it. **So the matrix cross-compiled the Zig
contracts and never the C ones.**

`janet-zig-contract-test` is installed unconditionally, so the four
cross-compile entries compile this file. Checked directly rather than inferred
from a green matrix: a `-Dtarget=x86_64-windows-gnu` build emits
`janet-zig-contract-test.exe`, and `test/ev_loop.zig` is inside it. What the C
file could not spell is one function —

    fn invalidHandle() c.JanetHandle {
        return if (windows) @ptrFromInt(std.math.maxInt(usize)) else -1;
    }

— which is the value half of rule 46. `ev_stream.zig` has the same two lines
privately, and importing them would have made the contract unable to notice the
subject holding the wrong constant.

### An alias of a `const` is a copy, and this increment shipped that defect for an hour

Four subsystems declared `extern const janet_stream_type` or
`extern const janet_channel_type` — `ev_loop.zig`, `net_addr.zig`,
`net_sockets.zig` — while **already importing the file that defines it**.
`ev_loop.zig`'s two sat 1,545 lines below its own `pub const stream =
@import("ev_stream.zig")`. That is rule 31's blindness with the alternative in
plain sight, and the conversion looks like a one-line substitution:

    const janet_stream_type = stream.janet_stream_type;   // compiles; wrong

It compiles, it resolves, and `&janet_stream_type` is **the address of this
file's copy**. `janet_abstract` stores the address the *creating* file used, so
`getAbstract` compared two different pointers and `net/localname` died with

    bad slot #0, expected core/stream, got <core/stream [fd=7]>

— a message that reads as impossible, because the value is exactly the type it
was refused for. The fix is to name the module at each use site.

The mechanism was verified rather than assumed, which took six lines and a
`zig run`: a `const` aliasing another file's `const` prints an address sixteen
bytes from the original's. This is rule 36 from the other side — that one is
about two identical constants being *merged* into one address, this one is
about one constant being *copied* into two — and both say the same thing about
Zig, which is that a `const`'s identity is a property of the declaration and
not of the value.

**What caught it is the driver, not the contract.** Every contract passed by
name, including `net_sockets`; the failure needs `janet-zig-contract-test` with
no argument, which runs all sixty-four in one process. The reason is ordinary
and worth writing down: the by-name path had not been re-run for the contract
that broke, because the increment's own contract was `ev_loop` and that one was
green. **Run the driver with no argument before believing an increment**, which
costs two seconds and is the only instrument that sees a subsystem edit through
a contract the increment was not thinking about.

### `port/mutate.py` was armed with rule 47's trap, in the same file as last time

`judge_default` linked the contract with

    zig cc ... test/contracts.c test/<name>.c ... libjanet.a -o /tmp/janet-mutant-contract

and scores a failed link as `("caught", "contract (build)")`. After this
deletion that link fails for **every mutant**, so a sweep would have reported a
perfect score and measured nothing — the mutation sweep being a queued gate
item, this is the second time the same file has been found waiting to lie in
the direction that looks like success. Part 19 found it passing a deleted
`-Dboot=zig`; this one is a deleted *file*, which is a different trigger for
rule 47 and the same consequence.

Repaired to run `janet-zig-contract-test <name>`, which also removes the
"fails to link" hazard the comment there warned about: a Zig contract cannot
fail to link, and a configuration that cannot compile one fails `zig build`
above, where the sweep already calls it `uncompilable`.

### One more symbol, and the last of this seam

`janet_make_pipe` was an `export fn` in `ev_stream.zig` declared again as an
`extern fn` by `os_procs.zig` and `ev_backend.zig` — rule 44's class, `util.h`
its only header, no caller outside the runtime. It is `pub fn makePipe` now and
the symbol is gone: **690**, from 691.

### Verified to be capable of failing

Two mutations, both in the subject and both with the build's exit status
asserted first.

**`janet_schedule_soon` made to append**, by passing `false` where it passes
`true`. Caught at `theScheduleSoonOrder`, which is the assertion whose whole
point is that one prepends and the other does not.

**`makePipe`'s mode 3 made to skip the write end's `FD_CLOEXEC`.** Caught at
`thePipeModes` — the section that exists because nothing in Janet can observe a
descriptor flag, and the one that exercises the function this increment
converted from a symbol to an import.

### The instruments

`zig build` green, `zig build test` green, all **sixty-four** contracts green
in one driver run, and the four migrated in Part 21 plus this one by name
through `port/contract.sh` — which is a shorter script now: no `zig cc`, no
`janetconf.h` lookup, no support object. `port/swallowed.py` silent. The
`port/` grep for a deleted flag found no *flag*, which is why the deleted
*file* in `mutate.py` needed a second look; rule 47's sweep is about anything a
script names that the tree no longer has.

The acceptance matrix with `CONTRACTS = ("ev_loop",)`: **21 PASS / 0 FLAKY / 0
FAIL** in 175.7s, the usual wall time.

No benchmark is owed. The runtime edits are three seam conversions and a
`pub` — `janet_make_pipe` and the two abstract types stop being reached through
the symbol table, which removes an indirection and computes nothing new. Rule
54's second half applies as it did in Part 21: what this touched is the event
loop, and the standing corpus does not execute it.

## The six files no build step named, and a gate counted over two directories

Phase 11 Part 23. Six of the eight `.c` files left in `test/` go — `amalg/main.c`,
`c/test-gc-pcall.c` and the four fuzzers — and the two that stay, `abi.c` and
`embed.c`, stay because they are the `janet.h` question rather than this one.
`test/` holds two `.c` files and no subdirectory of them.

**None of the six was named by any build system.** Not `build.zig`, not
`Makefile`, not `meson.build`, and nothing in `port/`. `test/amalg/main.c` was
already recorded as an orphan; the other five were not, and the reason nobody
had noticed is the same in all five cases — a `.c` file nothing compiles is
exactly as silent as a dead shim, a dead `extern fn` and a stranded
`_extern.zig`. That is rule 22's blindness in its fourth home, and it is the
one where the file can be *read* without the question arising, because reading
it tells you what it does and not whether anything does it.

### The gate had never been counted over the tree

The exit gate says **no `.c` file remains anywhere in the tree**. Twenty did.
Eight in `test/`, which every count in `phase_11.md` and `PLAN.md` tracks, and
twelve that no planning document mentions at all:

| where | count | what |
| --- | --- | --- |
| `test/` | 8 | the endgame bullet's own list |
| `tools/` | 1 | `symcharsgen.c`, an orphan nothing in the tree references |
| `examples/` | 2 | `ffi/so.c` and `numarray/numarray.c` |
| `port/probe-9`, `-10`, `-16` | 9 | the three spikes' corpora |

`grep -n 'examples/\|tools/\|symcharsgen' port/*.md AGENTS.md` returned
nothing.

This is rule 48 inverted and it is worth writing down in that form. Rule 48
says a *generated* artefact is in no count taken over the tree, and the fix is
to ask the build rather than `ls`. Here `ls` was never asked: the counts were
taken over `src/` and `test/`, which is where the work was, and a clause
saying "anywhere" was read against them for eleven parts.

**The gate is narrowed rather than the files deleted**, and that is a decision
rather than a discovery — see `phase_11.md`. It means `src/` and `test/`: the
implementation and its tests. `examples/` and `tools/` are documentation and
dev tooling and `port/probe-*/` is measurement input, none of which the
runtime compiles or the suites run.

### A regression test that had never run, for a fix that is live

`test/c/test-gc-pcall.c` is 143 lines and its header comment opens with the
word **Bug**. `janet_collect` marks `janet_vm.root_fiber` and the chain of
`child` pointers under it. A fiber entered by `janet_pcall` from inside a
cfunction is neither: `continueNoCheck` sets `root_fiber` only when it is null,
and `janet_pcall` never sets `child`, because `child` is what `janet_resume`
and `JOP_RESUME` maintain for a *Janet* nesting. So the fiber is in no root
set, is running, and owns the stack every frame above it executes on.

`continueNoCheck` roots it by hand for exactly that reason, and the comment
beside the line says so. The file is that line's regression test.

**It could not have run even if something had built it.** It registers its
cfunction with `janet_wrap_cfunction` over a C function, and a
`JanetCFunction` has been a raising Zig function since Phase 10 Part 17g. That
is the measurement `phase_11.md`'s `janet.h` bullet already carries — the
registration succeeds and the call segfaults — arriving at a file that was
written to catch a collector bug. So the fix has been unguarded for the whole
rewrite, in a tree that has a contract for the mark phase, one for the sweep,
one for allocation and one for stress.

`test/gc_pcall.zig` is the sixty-fifth contract and it keeps both of the
original's stress programs unchanged in substance: 200 rounds each at
`(gcsetinterval 1024)`, single and deep nesting, every allocation made from
Janet source because `janet_gcalloc` does not itself collect and the VM loop's
check is what does.

### What the migration added, and the difference is diagnosability rather than strength

The stress programs infer the fiber's survival from the answers coming back
right. They cannot *name* the mechanism: they hope a collection lands while the
nested fiber is live. `directCase` makes it land — a cfunction called from
Janet source running on the nested fiber, which calls `janet_collect` and then
asserts the fiber's block is still on `janet_vm.blocks`.

Both halves catch the defect, and rebuilding with `const fiber_rooted = false;`
is how that was established rather than assumed. They read nothing like each
other:

| | where it dies |
| --- | --- |
| `directCase` | `test/gc_pcall.zig:137`, `harness.heap.onList` after the collect |
| the stress cases | `vm_run.zig`'s `self.stack[fA(self.pc)] = value` — a null store in the interpreter loop, naming neither a collector nor a fiber |

So the direct case is not a stronger check. It is a diagnosable one, which is
rule 36's second half arriving in a file that had no assertion to attach it to.

**One assertion was written, run and found to be unwritable.** The first
version asserted the mark bit after the collection — `harness.heap.reachable`
— on the reasoning that a block which survived by being *marked* is a
different claim from one the sweep missed. It fails, and the runtime is right:
`gc_sweep.zig` clears `JANET_MEM_REACHABLE` on every survivor so the next mark
phase starts from a clean heap, so that assertion answers false for every live
block in the process. It is rule 8's circularity in its other form — an
assertion that cannot *succeed* rather than one that cannot fail — and rule 21's
discipline is what caught it: check the claim before believing the failure.

What replaced it reads the root set directly, which is the mechanism itself:
`continueNoCheck`'s `janet_gcroot` is the only thing that makes the fiber
reachable, so a survival with that false would be a survival by accident.

**And the contract asserts its own premise.** `assertNested` walks
`root_fiber`'s whole `child` chain and asserts the running fiber is not on it.
If `janet_pcall` ever maintained `child`, `markFiber` would reach the fiber on
its own, the rooting line could be deleted, and every assertion here would
still pass. That is rule 36 at a pointer rather than at an address.

### The four fuzzers, and why a faithful translation aborts

`test/fuzzers/*.c` are four `LLVMFuzzerTestOneInput` entry points over
`janet.h`: the parser, the compiler, `janet_dobytes` and `janet_unmarshal`.
Each opens a `janet_try_init` scope, calls its entry point, and calls
`janet_restore`.

That is right for C and wrong here, and the reason is the whole shape of Phase
10's hinge. Three of the four entry points are `raise.reported` or
`raise.panicking(...).abi` wrappers, so a raise leaves a *report* rather than
travelling, and `janet_restore` aborts on an outstanding one. A fuzzer's
inputs are mostly malformed. A translated fuzzer would die with

    janet abort: a raise was reported to a C caller and never consumed

on roughly its first interesting input, naming neither the target nor the bytes
that got there.

So each target reaches the raising function by import:

| target | the abi a translation would call | what `test/fuzz.zig` calls |
| --- | --- | --- |
| parser | `janet_parser_consume`, `janet_parser_eof` | `parser_core.consumeChecked`, `parser_core.eofChecked` |
| compile | `janet_compile` → `janet_compile_lint` | `compiler_primitives.janet_compile_lintImpl` |
| dobytes | `janet_dobytes` | `core_env.janet_dobytesImpl` |
| unmarshal | `janet_unmarshal` | `marsh.unmarshal` |

`harness.raised` is the scope, unchanged from what sixty-five contracts use it
for. This is `swallowed.py`'s rule reaching a caller that did not exist yet:
the script polices `raise.Raising` functions in `src/zig` that reach a raise
through an abi, and a fuzz target is not one — it is a *new* caller, and the
question the script asks is the question writing one asks first.

Two things the C originals did that are not carried across. `fuzz_dostring.c`
fuzzes the parser — its body and its own comment both say so — so the target
is called `parser` and `dobytes` is the one the old name suggested. And the
compile target now drains the parser rather than leaving forms in it, so the
value constructors are reached at all.

### They are in `zig build` for the first time

`std.testing.fuzz` resolves through `@import("root").fuzz`, which exists only
in a test root, so a fuzz target cannot be a contract and `test/fuzz.zig`
needs its own artifact — a third compilation of the runtime.

    zig build fuzz            # each target once over its corpus
    zig build fuzz --fuzz     # the campaign

The first is what `zig build test` runs, and it is there for the reason the C
originals died of: **a fuzz target nothing executes is a file, not an
instrument.** Verified capable of failing rather than assumed — a `@panic` in
one target's body reports `3/4 tests passed (1 crashed)` and fails the step,
which is rule 41's discipline pointed at a new instrument.

The costs, measured cold in throwaway caches:

| | before | after |
| --- | --- | --- |
| `zig build`, wall | 11.1s | 11.2s |
| `zig build`, CPU | 13.2s | 16.2s |
| `zig build`, cache | 160 MB | 189 MB |
| `zig build test`, wall | 19.9s | 19.3s |
| `zig build test`, CPU | 20.5s | 23.3s |
| `zig build test`, cache | 177 MB | 205 MB |

Wall time is unchanged in both, because the third compilation runs beside the
other two rather than after them. That is what decided the artifact is
installed unconditionally, the way `janet-zig-contract-test` is: rule 51 says
the matrix's four build-only entries are the only instrument that sees the
`@cImport` hazard class for a file that has just moved into Zig, and a plain
`zig build -Dtarget=X` builds only what the install step reaches.
`-Dtarget=x86_64-windows-gnu` emits `janet-fuzz-test.exe`, checked directly.

### What ran

`zig build test`, all sixty-five contracts by name and again with no argument,
`./port/swallowed.py` (silent), a `grep` of `port/` for anything naming the
deleted files (nothing), and `port/matrix.py -j2` with `CONTRACTS =
("gc_pcall",)` at **21 PASS / 0 FLAKY / 0 FAIL** in 182.4s wall, 355.3s of
work — the usual figures.

The mutation is rule 21's and it is the one this increment was built around:
`const fiber_rooted = false;` in `vm_entry.zig`'s `continueNoCheck`, built
successfully (rule 23) and caught three ways over — by the direct case, by the
single-nesting stress program and by the deep one. Restored and verified
identical to `HEAD` before anything else ran.

Two instruments were themselves verified rather than assumed, which is rule
41's discipline arriving twice in one part. `zig build fuzz` was checked
capable of failing with a `@panic` in one target's body: `3/4 tests passed (1
crashed)`, step fails. And a first version of the direct case's third
assertion — the mark bit after the collect — was checked against the sweep
before being believed, which is where rule 60 came from.

No benchmark is owed. Nothing under `src/zig` changed: this increment's edits
are `test/`, `build.zig` and the planning documents. `nm -gU
zig-out/lib/libjanet.dylib | wc -l` is **690**, unmoved, and expected to be —
the part adds tests and retires no symbol.

## The gate: six Darwin-shaped assertions, one byte of image, and an instrument that had never run

Phase 11 Part 24. Not a port — the phase's exit gate, run clause by clause the
way Phase 10's was. `port/phase_11.md` has the reading and rules 63 through 67;
this is the narrative and the numbers.

### The container is the only instrument that executes a second platform, and it had run twice

Everything else this project has for cross-platform confidence is a *compile*:
four cross-compile entries in the matrix, and `riscv32-linux-musl` for the
32-bit branches Zig would otherwise never analyse. The podman recipe in
`port/testing.md` is the one thing that runs a binary somewhere else, and before
this increment it had run at Phase 10's gate and at Phase 11 Part 4.

Parts 5 through 23 migrated **forty-seven further contracts** in between. So
`ffi_core` (Part 16), `os_surface` (Part 20), `filewatch_core` (Part 21) and
`ev_loop` (Part 22) had never executed anywhere but macOS, and the gate found
what that cost: four contracts failing and six assertions behind them.

| contract | assertion | why macOS was the wrong witness |
| --- | --- | --- |
| `filewatch_core` | `flagName(platform, 0) == "all"` | `windows_names` and `kqueue_names` open with `all`; `linux_names` is alphabetical, so `access` sorts ahead of it |
| `ffi_core` | guarded on `has_dynamic_modules` | that says the subsystem was **compiled**. Zig links musl statically and musl's static `dlopen` is a stub, so every binding registers and every `ffi/native` raises |
| `os_surface` | `(= 7 (os/cpu-count 7))` | asserts the **fallback**, which is reached only where the count is unavailable — `janet_os_cpu_count` has no macOS arm at all and returns -1 |
| `os_surface` | `(not= (os/date 0) (os/date 0 true))` | UTC against local, which coincide when the zone is UTC |
| `os_surface` | `(not= (os/mktime … :dst true) (… :dst false))` | the `:dst` slot is observable only in a zone that has a daylight rule |
| `os_surface` | `os/spawn ["/usr/bin/true"]` | Alpine is busybox and puts it at `/bin/true` |

**Every replacement is stronger than what it replaced**, which is the part worth
remembering, because the instinct when a test fails on a second platform is to
weaken it. `(= (os/cpu-count 7) (or (os/cpu-count) 7))` says the fallback is
used *exactly* when the count is missing — a claim the original could not make.
Epoch zero pinned absolutely (`[1970 0 0 0 0 0]`) beats epoch zero compared with
itself in another zone, and `os/strftime "%H"` cross-checks the local branch
against a second renderer rather than against itself. And a POSIX `TZ` string —
`EST5EDT,M3.2.0,M11.1.0`, which musl and Darwin both parse without tzdata —
turns "these differ" into "these differ by exactly 3600 seconds", on every host.

`os_surface` had to be fixed four times, each fix revealing the next assertion
behind it, because a contract aborts at its first failure exactly as the driver
does. Rule 63. The cheap defence is to read the file for the whole class at
once: one `grep -n '"/'` found both `/usr/bin/true` sites and proved `/bin/sh`,
`/bin/sleep`, `/bin/cat`, `/bin/echo` and `/dev/null` were fine.

**All 65 contracts now pass on `aarch64-linux-musl`, and so does the driver run
with no argument.** First time in this project's life. 32 of 34 suites pass and
both failures are `FOUND.md`'s, reproducing exactly as recorded.

### The one that is not a contract defect

`test/ev_loop.zig` failed with `janet top level signal - "No such file or
directory"` and no stack. `strace` named it in one run:

    dup(7)                                = 9
    epoll_ctl(5, EPOLL_CTL_ADD, 7, {…})   = 0
    epoll_ctl(5, EPOLL_CTL_DEL, 9, NULL)  = -1 ENOENT

`janet_marshal` with `JANET_MARSHAL_UNSAFE` duplicates a stream's descriptor and
clears `JANET_STREAM_NODUPS`; epoll keys registration by *descriptor*, so the
`dup` was never added under its own number, and closing the unmarshalled stream
takes the deregistering path and raises. The reason macOS is silent is in the
other half of the same file:

```zig
// kqueue                          // epoll
_ = apply(kevs[0..length]);        if (status == -1) return raise.panicv(…);
```

kqueue throws the status away — "the status might be -1 on the BSDs for
subprocesses" — and epoll raises it. Both reproduce upstream `ev.c`. Recorded in
`FOUND.md` and quarantined in the contract behind
`unregister_of_an_unregistered_handle_is_quiet`, because the two candidate
repairs are opposite answers to which half of the split is right, and a gate is
not where a behavioural change to the event loop belongs.

### The image is reproducible across hosts, and the proof is a control rather than a match

The last outstanding half of the bootstrap bullet. `zig build image` on macOS
arm64, and again natively under Alpine on `aarch64-linux-musl` with the same
Zig 0.16.0: **324,310 bytes each, differing in exactly one byte** — offset
220093, `0x01` against `0x11`.

That byte is the value of `janet/config-bits`, and `0x10` is `0x4 << 2`, so
`JANET_NANBOX_64_POINTER_SHIFT` is 2 on one host and unset on the other. The
image is recording a genuinely different build, in the one field designed to
vary.

What makes that an answer rather than a story is the control: rebuilding the
macOS image with `-Dnanbox-pointer-shift=2` produces a file byte-identical to
the Linux one, same sha256 across all 324,310 bytes. **The image is a function
of the configuration and of nothing else about the host.** A cross-host diff is
worth nothing until the configurations are known to agree, and the fastest way
to know is to make them agree and re-measure.

### The sweep that had been repaired twice and never run

Phase 10's gate deferred the mutation sweep and did not run one. `mutate.py` was
then repaired in Part 19 (it passed a deleted `-Dboot=zig` at two of three
stages) and again in Part 22 (its judge linked a deleted `test/contracts.c`) —
twice fixed, never executed, which is rule 41's own discipline unapplied to the
tool that most needs it.

Fifteen mutants of `ev_stream.zig`, sites 108 through 122, the exact index the
original run aborted at:

| | |
| --- | --- |
| wall | 246s, 16.4s a mutant |
| SURVIVED | 9 |
| caught | 6, **all six by `suite-ev.janet`** |
| caught by the `ev_loop` contract | **0** |

Three of the nine — `WSAGetLastError` and `GetLastError` in Windows arms this
host does not compile — cannot change the binary and are not survivors. That is
the **first of the two items Phase 10 queued for this sweep**, priced: a fifth
of one window is noise, so hashing the artifact and reporting a byte-identical
one as *no effect* is worth doing before the full run, not after.

The other six are real, consecutive, and all in the stream write path —
`is_buffer`, `sendto`, the `EINTR` retry. A sweep tests the tests, and this one
named the file and the function.

**The second sample did not finish, and that is the more useful half.** Fifteen
mutants of `ev_backend.zig` from index 0 — the source whose original run aborted
at mutant 0, so it has never been swept at all. Mutant 6 turns the self-pipe
drain's `while (true)` into `while (false)` and `judge_default` sat on it for
over five minutes against a `BOUND` of twelve seconds. One argument explains it:

```python
def sh(cmd, timeout=BOUND):   # 12s -- what every suite run gets
...
r = sh("%s/bin/janet-zig-contract-test %s" % (PREFIX, CONTRACT), timeout=600)
```

A mutant that hangs a suite costs 12 seconds; one that hangs the contract costs
600, for a program that normally returns in well under a second. It is scored
correctly in the end, as `contract (hang)`. But `ev_backend.zig` *is* the event
loop, so contract hangs are not the exception there, and the 16.4s-a-mutant
figure from `ev_stream.zig` does not transfer.

That is the third thing wrong with this instrument, found while it has still
never completed a run: a deleted flag in Part 19, a deleted file in Part 22, and
now a bound that does not bind. **A tool repaired twice and executed zero times
has been reviewed, not tested.** Rule 41 says to verify a sweep the way a
contract is verified; running it is the only thing that does that, and two
samples found more than two reviews had.

### What ran

The clean-checkout build from `git archive HEAD` (build, bootstrap, test,
install, embed, native-module load — 11.3s cold). `zig build test`. All 65
contracts by name and again with no argument, on macOS and in the container.
`port/matrix.py -j2` at **21 PASS / 0 FLAKY / 0 FAIL twice** — 185.7s/361.7s
over the state the gate found and 185.5s/361.9s over the state it left, four
contracts having changed in between — with `CONTRACTS` widened from one name to
twenty-three because a gate asks whether each reduced configuration passes what
it compiles rather than whether one increment's contracts survived. `port/swallowed.py`, silent. Rule
47's sweep of `port/`, clean — six hits, all prose. `leaks --atExit` over 61
contracts. `port/image-diff.py --save` and the container comparison.
`port/mutate.py` twice, as samples.

No benchmark is owed, and nothing under `src/` changed at all: the edits are
four contracts in `test/`, `port/matrix.py`'s `CONTRACTS` line, and the planning
documents. `nm -gU zig-out/lib/libjanet.dylib | wc -l` is **690**, unmoved, and
expected to be — a gate retires no symbol.

## The build wrappers, the CI that had never run, and a header shadowing libc's

Phase 11 Part 25. The ship half of the gate: `port/phase_11.md`'s Make-versus-
Meson bullet, the documentation bullet, and — unplanned — the first build this
project has ever made against glibc.

### Five wrappers and every CI job in the tree were dead

`Makefile` and `meson.build` each named forty files under `src/core`, none of
which had existed since Phase 10 Part 18; `plan9.mk` globbed the same directory
and named `src/boot/boot.c` and `src/mainclient/shell.c`, and `src/mainclient/`
is not a directory any more. So was every configuration that drove them:

| | |
| --- | --- |
| `.github/workflows/test.yml` | eleven jobs, all `make`, `build_win` or `meson` |
| `.github/workflows/release.yml` | `make`, `build_win all`, cosmo |
| `.github/workflows/codeql.yml` | `language: [cpp]` — analysing a language the tree no longer holds |
| `.github/cosmo/build`, `setup` | `make -j CC=…cosmo-cc` |
| `.builds/{linux,openbsd,freebsd}.yml` | meson and gmake — **and `sources:` is `git.sr.ht/~bakpakin/janet`**, so they built upstream and had never tested this fork at all |

That last row is worth its own sentence. A CI file that checks out somebody
else's repository is *green*, forever, whatever you do to yours. It is rule
58's silence with a status badge on it.

`README.md` meanwhile documented `make` as the way to build on macOS and Unix,
and the Zig build as "experimental… compiles the **unchanged C runtime**" —
backwards twice, since it is the only build and there is no C runtime. The
"build from a clean checkout using only documented prerequisites" bullet was
met by `zig build` and failed on the documented prerequisites.

### The header that answered for libc's

The CI work turned up something much larger. Writing a Linux job meant asking
what a runner actually does, and GitHub's Ubuntu runners are glibc — which this
tree had **never** been built against. It does not build:

    /…/generic-glibc/bits/libc-header-start.h:74:17: error: cannot call non function type 'long'
    #if __GLIBC_USE (IEC_60559_BFP_EXT) || __GLIBC_USE (ISOC23)

6,662 of those. `__GLIBC_USE` is defined in glibc's `features.h`; `build.zig`
puts `src/core` on the `-I` path so `src/zig/state_abi.h` can say
`#include "features.h"`; `-I` outranks the system search path. **Every libc
header that asked for `<features.h>` got ours.** In a `#if`, an undefined
identifier is `0`, so `__GLIBC_USE (X)` is `0 (X)`.

One command settles it, and finding that command is most of the work:

```sh
printf '#include <math.h>\n' > probe.c
zig translate-c -target aarch64-linux-gnu -lc probe.c              # clean
zig translate-c -target aarch64-linux-gnu -lc -I src/core probe.c  # 195 errors
```

Renamed to `janet_features.h`, eleven includers updated. A rename rather than
`-idirafter`, because a rename removes the ambiguity and an ordering makes
correctness depend on it.

**Then the rename opened three more targets.** `port/testing.md` had recorded,
for two phases, that Aro rejects musl's 32-bit `time64` `__REDIR` declarations
and that `x86-linux-musl` and `arm-linux-musleabihf` therefore cannot build.
They build. So do both glibc targets. The cross-compile set went from four to
**eight**, and the 32-bit set — the only thing anywhere that type-checks
`JANET_NANBOX_32` — from one target to three. Nothing about Aro changed; the
note had been filed against the toolchain, sat beside two genuine Aro failures,
and was ours. Rule 69.

What is genuinely translate-c's, checked at the same time: `x86-windows-gnu`
fails in mingw's `malloc.h` on `_ALLOCA_S_MARKER`. `x86_64-windows-gnu` builds.

### Six socket calls glibc does not declare with a pointer

The second glibc obstacle, and a different kind. Under `_GNU_SOURCE` glibc
declares `bind`, `connect`, `accept`, `accept4`, `getsockname` and
`getpeername` with `__SOCKADDR_ARG`: a union of every `sockaddr_*` pointer
marked `__attribute__((__transparent_union__))`, which the C ABI passes exactly
as the pointer inside it. `translate-c` has no rendering for the attribute and
produces a real Zig union.

`net_abi.zig` takes all six by symbol with `@extern`, guarded to glibc so
Windows keeps its own Winsock declarations. What is bypassed is glibc's
*prototype*, not its implementation — the plain-pointer signature is the ABI on
every POSIX target, which is the whole point of the attribute.

The six were **enumerated from `sys/socket.h`** after the first two were found
by building. That is rule 40 at a header instead of at a sweep, and it turned
four more build cycles into one.

### What glibc found that nothing else can see

All 65 contracts pass by name on `aarch64-linux-gnu`, and 32 of 34 suites — the
two failures being `FOUND.md`'s existing entries, which this confirms are *not*
musl-specific. But the driver run with **no argument** aborts:

    pp format contract ok
    malloc_consolidate(): unaligned fastbin chunk detected

Latent heap corruption. Plain glibc aborts at contract 9; under valgrind the
same binary reaches contract 64 — so the detection point is allocator-dependent
and the corrupting write is earlier. musl and macOS have no equivalent check
and pass. The socket shim is not implicated: `net_sockets` is contract 70.

Recorded in `FOUND.md`, not diagnosed. It is the concrete subject the "Settle
ASan and ThreadSanitizer" bullet has never had. *(Written as "and Part 26's".
Part 26 took the stranded shims instead; the corruption is still the next
subject that bullet has, and still undiagnosed.)*

### The workflow, and what could not be checked

`.github/workflows/test.yml` is five job groups: `zig build test` on two macOS
runners, Linux tested against **musl** on x86-64 and aarch64 (because of the
corruption above), a glibc build-only job so the glibc build cannot rot again,
three optimize modes, and eight cross-compiles.

**A workflow is the one instrument that cannot be verified where it is
written.** Every *command* in it was run — `zig build test` on macOS, all eight
cross-compiles locally, the contract loop against the real driver (65 ran, 3
non-contract `test/*.zig` correctly skipped, 0 failures), the musl and glibc
artifacts under podman. The YAML around them — runner labels, the action, the
expression syntax — is verified by the first run and by nothing else. The file
says so at the top. Rule 71.

### What ran

`zig build` and `zig build test` on macOS, all 65 contracts by name and with no
argument, all eight cross-compile targets, and the glibc and musl artifacts
under podman on Debian and Alpine — musl unchanged at 65 of 65 with the driver
clean, glibc 65 of 65 by name.

`port/matrix.py -j2` at **21 PASS / 0 FLAKY / 0 FAIL**, 185.7s wall and 362.2s
of work — the third consecutive run within half a second of the other two, so
the rename, the socket shim and the deletions cost nothing measurable.
`./port/swallowed.py` silent. `nm -gU zig-out/lib/libjanet.dylib | wc -l` is
**690**, unmoved.

No benchmark is owed. The runtime changes are a header rename and six socket
calls taken by symbol instead of through a prototype; neither alters what is
computed, and `port/probe-9/bench/bench.janet` does not reach the socket path
anyway — rule 54.

## The eleven stranded shims, and a file that had not compiled for fourteen parts

Phase 11 Part 26. `port/phase_11.md` listed these as "one part, mechanical" —
eleven `*_extern.zig` files reached only through an `if (options.X)` that has
been comptime-`true` since Phase 10 Part 18 spent the last selector, and Zig
never analyses the untaken branch of a comptime-known `if`. Part 9 found
`buffer_array_extern.zig` still naming an abi it had just deleted, said the
class was worth a sweep, and nothing swept it again for seventeen parts.

The deletion is mechanical. What was inside them is not.

### Ten of the eleven conditions were comptime-`true`. One was not

`phase_11.md` said all eleven were, and that is the first thing to correct.
`zigSelection` in `build.zig` answers `.ev_loop = hasEv(options)`, so
`-Dev=false` and `-Dsingle-threaded=true` selected `ev_loop_extern.zig` **for
real**. Those configurations build today and built before, and the reason is
not that the shim was fine: it is that nothing in such a build references a
declaration in `evloop.zig`, and Zig analyses a container-level `const` only
when something reads it. A selected file and an analysed file are different
things.

The other ten are `true` unconditionally, so their shims were unreachable on
every target in every configuration.

### `vm_calls_extern.zig` had not compiled since Part 12

Two probes, both cheap, and each finds what the other cannot.

**The symbol sweep.** Every `c.janet_*` reference and every `extern fn` name
under `src/zig`, checked against `nm zig-out/lib/libjanet.a`. 134 symbols from
the shims, 276 `extern fn` names from the tree. Eight names are defined
nowhere:

| | |
| --- | --- |
| `janet_call_nonfn`, `janet_resolve_method`, `janet_unary_call`, `janet_binop_call`, `janet_fill_table`, `janet_fill_struct`, `janet_fill_string` | `vm_calls_extern.zig` — retired by **Part 12** |
| `janet_text_substitution` | `registry_extern.zig` — retired by **Part 13** |

**The forced-analysis probe.** A temporary `comptime` block in `root.zig`
walking each shim's decls with `@field`, one build per shim. Ten compile. One
does not:

    src/zig/subsystems/vm_calls_extern.zig:26:33: error: root source file
    struct 'cimport' has no member named 'janet_call_nonfn'

That is the sharper half of the finding. A dead `extern fn` is a *link* error
waiting to happen, and `registry_extern.zig` is one of those. But
`vm_calls_extern.zig` reaches its seven through `c.`, and no header declares
them any more, so it is a **compile** error — the file has not been valid Zig
since Part 12 retired the abis, fourteen parts and fourteen acceptance
matrices and one phase gate ago, and nothing in the tree could say so.

### The same file contradicts its own reason for existing

Worth reading rather than only deleting. `vm_calls_extern.zig`'s header says it
exists so that

> `-Dvm-calls=c` would not silently keep answering with Zig for every call the
> interpreter makes, which is the one thing a differential selector may not do.

and five of its thirteen declarations are

    pub inline fn mcall(...) raise.Error!c.Janet {
        return try vm_calls.mcall(name, argc, argv);
    }

— straight to `vm_calls.zig`, the Zig implementation. They were added for
converted callers, which needed the Zig signature, and taking it from the Zig
body was the path of least resistance. Under the selector this file existed to
honour, it would have done the one thing it was written to prevent. Nothing
said so, because nothing read it.

### One directory over: `dynlib.zig`'s four

The sweep of `extern fn` names found the same mechanism outside the eleven.
`dynlib.zig` had

    const use_zig = options.utilities;

which is comptime-`true`, and four branches of the form
`if (use_zig) loadClib(name) else load_clib(name)` reaching `extern fn`
declarations of `error_clib`, `load_clib`, `free_clib` and `symbol_clib` —
`util.c`'s Win32 loader, deleted with `util.c` in Phase 10 Part 18. Four
`extern fn`s naming nothing, on a branch no build takes. Rule 31's class, found
by a sweep rather than by anything forcing it.

`raise.declared` went with them. It was the inverse of `raise.panicking` — the
Zig signature over a C symbol that raised by jumping — and its users were eight
of the eleven shims and `dynlib.zig`'s `symbol_clib`. There is no C function
left in the tree for it to wrap.

### The change compiles to the same code, and that is checkable

A pure deletion should leave the artifact's *code* untouched, and saying so is
cheaper than a benchmark. Built before and after into separate prefixes:

| | before | after |
| --- | --- | --- |
| exported symbols in `libjanet.dylib` | 690 | **690**, and the two lists `diff` clean |
| `__TEXT,__text` | 2,789,788 bytes | **2,789,788 bytes** |
| `shasum` of the binary | — | **differs** |

The last row is the useful one and it bears on a queued gate item. Phase 10's
first mutation-sweep prerequisite is "hash the built artifact and report a
byte-identical one as *no effect*"; a **file** hash will not do that, because
debug info carries line and column numbers and this increment moved comments.
Compare the text section, not the file.

### What ran

`zig build` and `zig build test` on macOS — 34 suites, 65 contracts, 4 fuzz
targets, the native-module load, all clean. Fifteen contracts by name through
`port/contract.sh`: the subjects behind every façade this increment collapsed.
`-Dev=false`, `-Dsingle-threaded=true`, `-Dnet=false` and `-Dfilewatch=false`
built directly, because `ev_loop` is the one selector that genuinely reached a
shim. `./port/swallowed.py` silent at 118 abis and 84 helpers.

`port/matrix.py -j2` at **21 PASS / 0 FLAKY / 0 FAIL**, 189.1s wall and 369.0s of work — up from Part 25's 185.7s and 362.2s by about the cost of nine more contracts per entry, with `CONTRACTS` widened by nine —
`args_core`, `registry`, `core_env`, `fiber_core`, `vm_entry`, `vm_lifecycle`,
`vm_calls`, `pp_describe` and `pp_pretty`, each compiled by every configuration
because the `options` field behind it is comptime-`true`, which is the fact
this increment is about.

No benchmark is owed and rule 18 is why: the increment deleted declarations
nothing analysed and collapsed thirteen comptime `if`s onto the branch already
taken. The `__text` measurement above is stronger evidence than a timing would
be.

No mutation is owed either. Rule 21 asks a *migrated contract* to prove it
provokes; no contract changed here.

## The heap corruption, and a teardown that freed two things and cleared neither

Phase 11 Part 27. Part 25 found that `janet-zig-contract-test` with no argument
aborts on `aarch64-linux-gnu` in `malloc_consolidate` with an unaligned fastbin
chunk, recorded it, and did not diagnose it. `phase_11.md`'s "Settle ASan and
ThreadSanitizer" bullet had been open since Phase 9 waiting for exactly such a
subject.

**It was diagnosed without a sanitizer, and the bullet is still open.** What the
bug wanted was not an instrument that could *observe* the corruption but one
that could *narrow* it.

### The driver could not run a subset, and that was the whole obstacle

Every contract opens with `janet_init` and closes with `janet_deinit`, so the
no-argument run is sixty-five teardowns and re-initialisations in one process.
All 65 pass individually. So the failure needs the sequence, and a driver that
takes one name or all of them cannot bisect a sequence.

`test/contracts.zig` now takes several names and runs them in order in one
process. Six lines, and everything below follows from them:

| | |
| --- | --- |
| prefix of 8 | passes |
| prefix of 9 | aborts |
| any 8 of those 9, dropping one | **still aborts, except when the one dropped is `remove_noops`** |
| `remove_noops` alone, or with any one other | passes |

Necessary and not sufficient is the signature of a stray write rather than a bad
free: it damages the heap, and something else has to be allocated beside the
damage before the allocator notices. That is also why the abort point moves
under valgrind and why `MALLOC_PERTURB_` does nothing.

### The mechanism, and whose defect it is

`janet_clear_memory` ends:

```c
janet_free_all_scratch();          /* sets scratch_len = 0 */
janet_free(janet_vm.scratch_mem);  /* frees the table */
```

`scratch_mem` is left dangling and `scratch_cap` at its old value, so the next
`janet_smalloc` finds `scratch_len != scratch_cap`, skips the growth path, and
writes `scratch_mem[0] = s` **through the pointer just freed**.

`test/remove_noops.zig` called `janet_bytecode_remove_noops` — which opens with
`janet_smalloc` for its pc map — with **no `janet_init` at all**, after an
earlier contract had already torn the runtime down.

**The first write-up of this called it an upstream defect and that was wrong.**
The code shape is upstream's verbatim, which is what made it plausible. But
upstream cannot reach it: `janet_init` assigns all three fields, nothing after
`clearMemory` in `janet_deinit` uses scratch, every scratch caller in the
runtime runs inside an initialised VM, and upstream has no analogue of a
single-process driver that cycles the runtime sixty-five times. Upstream builds
and runs on glibc constantly.

The experiment that settles it is one build: **revert your own fix, fix only
your side, and see whether it passes.** With `clearMemory` exactly as upstream
has it and the contract initialising, the no-argument run exits 0. The contract
was the bug. Rule 76.

### The audit found a second field, and the correct pattern in the same function

`scratch_mem` is not special; it is one of the things teardown frees. Asking
what else teardown frees:

| freed at teardown | cleared after? |
| --- | --- |
| `roots` | yes |
| `registry` | yes |
| the symbol cache's four, in `janet_symcache_deinit` | yes |
| `scratch_mem` | **no** |
| `traversal_base`, `traversal`, `traversal_top` | **no** |

`traversal_base` is arguably worse than the scratch table. `value_order.zig`
decides whether to grow the traversal stack with `traversal_base == null`, so a
dangling one takes the *grow* path and hands `janet_realloc` a pointer that is
already free — a bad free rather than a stray write. It is reachable the same
way, by `janet_equals` or `janet_compare` between a teardown and the next
`janet_init`.

Both are cleared now, all three traversal fields rather than only the base,
because `janet_init` assigns all three and the point is that teardown should
match it. Thirty-two bytes of text for the scratch half, in a function called
once per teardown that already walks and frees the whole heap.

### The hardening makes the path correct, not loud

Worth stating because this file said the opposite first. With all three scratch
fields cleared, the next `janet_smalloc` finds `scratch_len == scratch_cap == 0`,
takes the growth path and allocates a fresh table. It does not trap. So the
nulling removes the corruption and does **not** diagnose the caller — which is
why the contract fix is the fix and this is defence in depth behind it.

### Nine other contracts never initialise, and a verified detector cleared them

`remove_noops` was one of ten contracts that never call `janet_init`. Reading
nine files would have been a guess, so the class was enumerated instead: a
temporary live-VM flag set by `janet_init` and cleared at the end of
`janet_deinit`, with a check in `janet_smalloc` and in the traversal stack's
growth.

It was verified capable of firing before it was believed — 2 hits on the
un-fixed `remove_noops`, 0 with the fix, which is rule 41's discipline — and
then run over all 65 contracts standalone. **Zero hits.** `ev_core`,
`ffi_classify`, `ffi_layout`, `filewatch_flags`, `intscan`, `movopt`,
`regalloc`, `textscan` and `verify` genuinely need no VM. The probe is reverted.

### The contract that should have caught this was written from the implementation

`test/vm_lifecycle.zig`'s `whatDeinitClears` asserted every field `janet_deinit`
assigns. That is a list derived from the code it is testing, so it agreed with
it by construction and was silent about the two fields teardown freed and never
assigned. Its sibling `scribbleOverTheVm` *does* cover `scratch_mem` and all
three traversal fields — on the `janet_init` side, where the implementation
assigns them.

It now asserts the invariant rather than the assignments: **anything teardown
frees, teardown clears.** Both allocations are forced first — a `janet_smalloc`
and a nested `janet_equals` — because without that the new assertions hold
vacuously, which is exactly how the omission survived. Rule 75.

### What ran

`zig build` and `zig build test` on macOS, clean. All 65 contracts by name and
the driver with no argument, on macOS, on `aarch64-linux-musl` under Alpine and
on `aarch64-linux-gnu` under Debian — **the glibc no-argument run exits 0 for
the first time in this project's life.** 32 of 34 suites on musl, the two
failures being `FOUND.md`'s existing entries, reproducing exactly.

`port/matrix.py -j2` at **21 PASS / 0 FLAKY / 0 FAIL**, 181.1s wall and 353.6s
of work, with `CONTRACTS` set to the increment's own five.
`./port/swallowed.py` silent at 118 abis and 84 helpers. `nm -gU
zig-out/lib/libjanet.dylib | wc -l` is **690**, unmoved.

`port/testing.md` gains the glibc recipe, which had never been written down:
Part 25 ran it ad hoc and Part 27 had to reconstruct it to reproduce the bug it
was diagnosing.

No benchmark is owed, and rule 54 is why rather than rule 18 being waived. The
increment touches runtime source — three stores in `clearMemory`, three in
`deinit` — but both run once per teardown, and the corpus is a Janet script the
`janet` binary runs, which initialises and tears down exactly once per process.
The corpus cannot reach it. What can be measured instead is the code: the
scratch half is **32 bytes of `__TEXT,__text`**, added to a function that
already walks and frees the entire heap.

## The leak check, a severed heap list, and an instrument that stops what it scans

Phase 11 Part 28. Part 24's gate ran `leaks --atExit` over the contracts and
left two findings rather than one: **three contracts leak** — `args_core` at 88
blocks, `gc_sweep` at 8, `net_sockets` at 3 — and **three more never return
under the tool at all**, so the check covered 61 of the 65. Rule 65 wrote the
second down as a gap and, on the evidence of a process count, said it was not a
fork.

It is a fork. And of the three leaks, one was real, one is `FOUND.md`'s, and
one is `FOUND.md`'s.

### The eighty-eight blocks were one severed list

`leaks` reported them as a chain: one ROOT LEAK with eighty-seven descendants,
each the `next` of the last. That is `janet_vm.blocks`, and `janet_clear_memory`
walks exactly that list at `janet_deinit`, so the question was never *which
allocation leaked* — it was how a segment of the heap list stopped being on it.

Two probes answered it. A count in `clearMemory` said **113 blocks live and 29
freed**; a check in `janet_gcalloc` comparing the list's length to
`block_count` fired at the first allocation after the divergence, with a stack:

    args_core.cbytesCopiesAFullNoReallocBuffer   ← between here
    args_core.theAbstractGettersAndTheBytesCallback ← and here

The contract builds a full, no-realloc buffer like this:

```zig
const b = c.janet_buffer(0);        // collectable: prepended to janet_vm.blocks
c.janet_buffer_deinit(b);
_ = c.janet_buffer_init(b, 0);      // ← this
```

`janet_buffer_init` is for a buffer the *caller* owns, and it says so in one
line of its own body:

```zig
export fn janet_buffer_init(buffer: *c.JanetBuffer, capacity: i32) callconv(.c) *c.JanetBuffer {
    _ = bufferInitImpl(buffer, capacity);
    buffer.gc.data.next = null;
    buffer.gc.flags = mem_disabled;
    return buffer;
}
```

`b` was the head of `janet_vm.blocks`. `buffer.gc.data.next = null` therefore
severed the list behind it, and the eighty-four blocks allocated before that
point were never freed by anything. The two lines are upstream's verbatim and
upstream is right: the function is documented for a buffer that is not on a
heap list, and every other caller in this tree — `pp_format`, `pp_describe`,
`vm_run`, `string_symbol`, `ev_channel`, `ev_loop` — passes either a local or a
`janet_malloc`ed block. Only the contract passed a collectable one.

The repair is a deletion: `janet_buffer_deinit` alone frees the payload, nulls
the pointer, and leaves both the list and the block's type intact. **88 leaks
and 6,928 bytes to 0.**

The block is now on the heap list with nothing on the Zig stack rooting it, so
it is `janet_gcroot`ed for the window — `AGENTS.md`'s rule about a `Janet` in a
local. Nothing between the two points allocates a collectable block today; the
root is what keeps that from being load-bearing.

### The other two leaks are recorded defects, and both were already asserted

`gc_sweep`'s 8 are `janet_clear_memory` never walking `janet_vm.weak_blocks` —
`FOUND.md`'s entry, reproduced deliberately, and the contract's
`clearMemoryFinalizesEverything` already asserts `weak_blocks != null` after
`janet_deinit` so that whichever implementation is fixed first says so. Four
weak containers survive teardown across the file (one weak table, three weak
arrays) and each leaks its block and its data array: 4 × 2 = 8.

`net_sockets`'s 3 are `FOUND.md`'s `net/address` unix-domain leak, one 112-byte
`janet_calloc` per call at three call sites in `theUnixAddressLookup`.

So of the three "leaks" the gate found, **one was a defect in a contract and
two are defects the contracts exist to pin.** The number that was actually
undiagnosed was the first, and it had been carried since Part 1.

### `leaks --atExit` cannot measure a process that forks

`os_process`, `os_surface` and `value_alloc` hang under it, each finishing in
under 0.2s unmeasured. Rule 65 checked the process count and concluded it was
not a fork. The count is three, not two, and one of the three is in state `T`:

    80947 80945 S    leaks --atExit -- .../janet-zig-contract-test os_process
    80948 80947 S    .../janet-zig-contract-test os_process
    80953 80948 T    .../janet-zig-contract-test os_process

`sample` on each says the rest. The parent is in `__wait4` inside
`os_process.wait`; the child is here:

    750 os_process.theHostOperations
      750 my__exit  (in libLeaksAtExit.dylib)
        750 __kill  (in libsystem_kernel.dylib)

And `libLeaksAtExit.dylib` is thirty instructions long:

    _my__exit:  getpid(); kill(pid, 17); _exit(status)
    _my_abort:  getpid(); kill(pid, 17); abort()

Signal 17 is `SIGSTOP` on macOS. **The stop is the protocol**: it is how the
waiting `leaks` process is told there is a heap to scan, and `leaks` resumes
the process afterwards. A `fork()`ed child carries the dylib in its inherited
image and stops itself the same way — but `leaks` is watching the parent, so
nothing ever resumes it, and the parent's `waitpid` never returns.

An `exec`ed child is safe, and for a reason that is in the same dylib:
`___library_initializer` calls `_resetDyldInsertLibraries`, which strips
`libLeaksAtExit.dylib` out of `DYLD_INSERT_LIBRARIES`. So `os/spawn` is not the
hazard and a raw `fork` is. `os_process` has seven fork sites, `value_alloc`
one, and `os_surface` reaches one through `os/posix-fork` — which is exactly
the three.

### The fix is to stop using `--atExit`

`port/leaks.sh` reaches the same heap by a route with no interposer in it. The
driver stops *itself* at the end of `main` when `JANET_CONTRACT_PAUSE` is set;
the script scans the stopped process with `leaks <pid>` and then resumes it. A
forked child exits normally, because nothing was inserted into it.

That is six lines in `test/contracts.zig` and a script. It also turns an
ad-hoc command line into an instrument with an expectation in it:

    args_core                0
    gc_sweep                 8 (expected: FOUND.md)
    gc_stress                skipped (leaks on purpose)
    net_sockets              3 (expected: FOUND.md)

`gc_stress` is excluded rather than expected, because its whole subject is a
heap the collector is not allowed to reach. Every other contract is measured
and expected to be zero, and the two `FOUND.md` counts are written down, so a
fourth leak — or a change in either of those two — fails the run instead of
being read off a report by a person.

**64 of 65 measured, 1 excluded on purpose, 42 seconds, exit 0.** It was 61 of
65 with three counts nobody had explained.

### Verified capable of failing

Rule 41. The `args_core` repair was reverted, the tree rebuilt, and the script
run: `args_core 88 LEAKS, expected 0`, exit 1, with the allocation stack. The
byte total under `leaks <pid>` is 6,928 — the figure the gate recorded — where
`--atExit` reported 5,904 for the same eighty-eight blocks, because the two
scan at different points and `MallocStackLogging` changes the bucket sizes.

### What ran

`zig build` and `zig build test` on macOS, clean — 34 suites, 65 contracts, 4
fuzz targets. All 65 contracts by name through `port/contract.sh` and the
driver with no argument, exit 0. `./port/leaks.sh` over all 65.

`port/matrix.py -j2` at **21 PASS / 0 FLAKY / 0 FAIL**, 179.8s wall and 351.2s
of work, with `CONTRACTS` set to the increment's own four. `./port/swallowed.py` silent at 118 abis and 84 helpers.
`nm -gU zig-out/lib/libjanet.dylib | wc -l` is **690**, unmoved — nothing under
`src/` changed.

No benchmark is owed, and not by rule 54's argument but by a simpler one: the
increment touches no runtime source at all. `test/args_core.zig`,
`test/contracts.zig`, `port/leaks.sh` and `port/matrix.py`'s `CONTRACTS`.

## The Python tooling becomes Janet, and three ways a transliteration lies

Phase 11 Part 29. Five Python scripts sat in `port/`; four are Janet now and
the fifth is deleted. Development depends on no Python.

This is not a port of the runtime and nothing under `src/` changed. It is here
because the instruments are how every other increment is judged, and because
rewriting four of them at once was an unusually clean natural experiment in
what a transliteration silently changes.

### Why Janet rather than Zig

Zig was the other candidate and it is the smaller dependency: the toolchain is
already required to build, where Janet is one more binary on the PATH. Three
things decided it the other way.

The two things this tooling is made of are **pattern matching** and **timed
subprocesses**, and Zig's standard library has neither. There is no regex and
no PEG, so `swallowed`'s ten patterns and `mutate`'s fourteen become hand-rolled
`std.mem.indexOf` scanning. And `std.process.Child.run` — the capture
convenience — no longer exists in 0.16; `wait` takes an `Io`, and there is no
child timeout at all. You would compose one from `io.async`, `io.sleep` and
cancellation, which means writing the tooling against **`std.Io`** — an
interface this phase has an open, deliberately deferred decision about. Doing
that in a tooling increment would answer a runtime question sideways.

Janet does both as builtins. Capture, exit status, timeout, and *partial output
from the killed child*, measured at 0.41s against a 0.40s deadline:

```
(0 "hi")
(:timeout "partial")
elapsed 0.41s
```

And the tree already self-hosts — `boot.janet` emits the image, the suites are
`.janet` — so a janet on the PATH is not a new class of dependency the way
Python was. Which janet is the PATH's answer and the user's to change. It is
deliberately not the one a build under test produces: `mutate.janet` breaks the
runtime on purpose, and a sweep whose driver runs on the mutant scores itself.

### `convert.py` was deleted rather than ported, because it was dead

Its `split` stage emits `X catch raise.deliverToC()`. `raise.deliverToC` has
not existed since Phase 10 Part 17h — the only occurrences left in the tree are
three prose comments describing its removal — so the stage had emitted
uncompilable Zig for a phase and a half. Nothing said so, because nothing runs
it but a person.

Rule 47's sweep did not catch it, and the reason is worth keeping: that sweep
greps `port/` for a deleted **build option**, and this was a deleted
**function**. Fourth instance of the class, after a dead shim, a dead
`extern fn` and a stranded `_extern.zig`.

### Four constructions that read the same in both languages and are not

Each compiled, ran, and printed a plausible answer. The differential against
the Python found the first three; reading the code found none of them; and the
fourth is one no differential could have found.

**`slurp` returns a buffer, and `=` on two buffers is identity.** Python's
`read()` gives immutable bytes compared by value. So `image-diff --against`,
whose entire job is *are these two images the same*, reported a file compared
with itself as different — and printed "0 strings only in the saved image, 0
strings only in the built image" underneath, which is the shape of a program
that knows the answer and says the opposite. `(string ...)` or `deep=`.

**A PEG's `some` is possessive where a regex's `+` backtracks.** The host-path
pattern is `(?<![A-Za-z])/[A-Za-z0-9_./-]+\.(?:c|zig)`, and the character class
contains `.`, so the `+` swallows the extension and the regex *backtracks* to
find it again — ending the match at the **last** `.c` or `.zig` in the run. A
PEG cannot express that and would never match at all. The run is captured whole
and the ending chosen afterwards, which is the same answer by construction
rather than by resemblance; a synthetic corpus pins the three cases that
distinguish them (`/a.c.zig`, `/tmp/x.czz`, `/q/w.zig/e.txt`).

**Closing a Janet channel discards what is buffered in it**, where draining a
Python queue does not. The matrix's worker pool was fed by filling a channel
and closing it; every worker took nil immediately and the run reported every
entry as "did not run", exit 0. The queue is an index now — safe because
`ev/go` fibers are cooperatively scheduled and nothing between the read and the
increment yields.

**`ev/lock` excludes nothing between fibers on one thread**, and it is the
obvious translation of Python's `threading.Lock`. Its own docstring says it
"will block this entire thread ... and will not yield to other fibers on this
system thread" — it is an OS mutex for coordinating *threads*, and the pool is
fibers on one. Measured:

```
ev/lock       @[:a-acquired :b-trying :b-acquired :a-releasing]
one-token chan @[:a-acquired :b-trying :a-releasing :b-acquired]
```

B acquires while A still holds it. So the suites lock — which exists to stop
two `full` entries running the Janet suites against three shared fixtures at
once — was a no-op. It is a capacity-1 channel now: take is acquire, give is
release, and both yield.

This one is not like the other three, and rule 84 is why: **a differential
cannot see it, because both sides pass.** The matrix ran 21 PASS / 0 FLAKY /
0 FAIL *twice* with the lock excluding nothing, since whether two overlapping
entries actually collide is probabilistic. What found it was reading the
primitive's documentation and a four-line probe.

It is also worth saying how it was found, because the route was wrong. One
matrix run came in at 278.1s against the usual 186s and `ev/lock` looked like
the cause. It was not: rule 16's check — re-run a slow entry standalone —
settled it as machine noise (`no filewatch` 94.1s in the matrix and **20.3s**
alone; `no peg` 83.5s and **11.8s**), and the next two runs came in at 180.5s
and 181.0s with the lock untouched. A wrong hypothesis about a real anomaly
led to a real defect the anomaly had nothing to do with.

A fifth is performance rather than meaning, and it cost the first run of
`swallowed.janet`, which did not finish: **a PEG handed to a matcher as a
structure is compiled on every call.** Python's `re` caches by pattern string,
so the transliterated inner loop — 118 symbols across every function body, per
fixpoint pass — looked identical and was not. Compiled once and kept, it is
**4.0s against the Python's 9.0s**.

### Killing a hung build means killing a tree, and Janet has no `killpg`

`matrix.py` used `start_new_session=True` and `os.killpg`. Janet's `os/spawn`
passes no `posix_spawnattr_t`, so a child stays in the driver's own process
group and killing that group would kill the driver.

`tools.janet` reads every `(pid, ppid)` pair once, takes the descendants of the
process it started, and kills them leaves-first in a single `kill` — leaves
first because killing a parent first can leave a child reparented to init and
unfindable a moment later. Verified against a `sh -c` holding a `cat /dev/zero`
grandchild: 0.52s to the deadline, partial output preserved, no survivor.

One rough edge found on the way, which is why the wait runs in its own fiber
rather than under the deadline: **cancelling `os/proc-wait` leaves the process
permanently unwaitable.** The flag saying a wait is in flight is never cleared,
so a second wait raises "cannot wait twice" and the finalizer declines to reap —
a zombie per timeout. Killing the tree and letting the *original* wait complete
reaps it.

### What each differential actually proved

Rule 82: agreement on a clean tree is nearly worthless, so each tool was given
a planted failure.

| tool | exhaustive | planted failure |
| --- | --- | --- |
| `swallowed` | output byte-identical, 118 abis / 84 helpers | a `c.janet_buffer_ensure` call added inside raising `bufferSetcount`; both name `buffer_array.zig:212` and exit 1 |
| `image-diff` | path scan identical on a synthetic corpus; image identical at 324,310 bytes | one byte patched in a saved image; both list `buffer/pusX-uint16` and exit 1 |
| `matrix` | logs byte-identical on build-only, contracts, preflight and failure entries | `@compileError` in `raise.zig`; both extract the same three error lines, exit 1 |
| `mutate` | site enumeration over 8 source-and-flag combinations; **all 280 mutant texts** of two files, 15MB, byte-identical | four verdict kinds sampled — `uncompilable`, `SURVIVED`, caught-by-contract, caught-by-startup — identical including the `by:` tally |

`mutate` is the one whose port has no full oracle, because the Python had never
completed a run. Rule 83.

### The sweep's known defect bit again, during the port

Three sites were picked for the verdict comparison without checking what they
mutate. Two of them mutate `peekTimeout` — the event loop's timer peek — which
hangs the `ev_loop` contract, and the contract call is bounded at **600
seconds** where a suite gets 12. The probe was killed at ten minutes and left
the tree mutated, because a killed sweep never reaches its restore.

That bound has now cost two runs, the gate's and this one. It is deliberately
**not** fixed here, along with the text-section comparison rule 74 asks for:
both change what a verdict *means*, and the phase that owns the sweep should
own them. What the port does provide is the mechanism — `ev/with-deadline`
makes the fix one argument rather than a redesign.

### What ran

`zig build` and `zig build test` on macOS, clean — 34 suites, 65 contracts, 4
fuzz targets. `./port/swallowed.janet` silent at 118 abis and 84 helpers.
`nm -gU zig-out/lib/libjanet.dylib | wc -l` is **690**, unmoved — nothing under
`src/` changed, and the only non-`port/` edits are comments in `build.zig`.

`port/matrix.janet -j2` at **21 PASS / 0 FLAKY / 0 FAIL**, 181.0s wall and
353.9s of work, with `contracts-default` at Part 28's four — this increment
migrated no contract. That is the third full run of the day; the first reported
278.1s and was machine noise, which rule 16's standalone check settled and the
second and third runs (180.5s, 181.0s) confirmed.

Each replaced script was also run against the Python it replaces, which is the
increment's real check and is tabulated above. No benchmark is owed: the
increment touches no runtime source.

## The configuration stops coming out of the header

*Phase 12 increment 1.* The runtime learned its own configuration by asking the
`@cImport` — `@hasDecl(c, "JANET_PEG")` and ninety more like it. That made
`janet.h` not merely the declaration surface but the place the configuration
was *resolved*, and the header cannot be retired while that is true. It is
`@import("config")` now, a `Config` struct in `build.zig` reflected through
`b.addOptions()` the way `makeSelectionModule` already did for
`@import("options")`.

**The derivation moved, not just the reads.** `makeConfigHeader` only ever
emitted negatives — `JANET_NO_PEG`, `JANET_EV_NO_EPOLL` — because `#ifndef` is
the only tool a config header has. `janet.h` derived the positives from the
absence of the negatives with the platform folded in: `JANET_NET` wants
`JANET_EV` and not emscripten, `JANET_EV_EPOLL` wants Linux, `JANET_FFI_JIT`
wants `JANET_FFI`. `janetConfig()` reproduces that block clause for clause,
each line citing the clause it mirrors, and it has to be exact — the C types
this runtime still uses are declared inside those same `#ifdef`s, so a `Config`
that disagreed would compile Zig against a struct the header had not declared.
Eight reduced-configuration builds are what check it, and they are cheaper than
reasoning about it.

**Four facts went to `@import("builtin")` instead**, because they are
properties of the target rather than decisions: `JANET_32`/`JANET_64`,
`JANET_BIG_ENDIAN`, `JANET_WINDOWS`, `JANET_PLAN9`. `janet.h` recovers these by
testing a hand-maintained list of architecture macros, and its endianness check
*assumes big-endian* when it recognises nothing.

**The sharpest case was the value representation.** `value_wrap.zig` decided
which of the three layouts it had compiled by asking whether the *translated*
`Janet` carried an `as` or a `tagged` field, and `value_order.zig` asked
whether it carried a `u64`. Configuration read off an artefact is configuration
decided by that artefact; both read `config.value_repr` now. `test/value_alloc.zig`
had written the reasoning down — "a `JANET_*` macro is not reliable through
`@cImport` — so the question is put to the translated type, which is where the
answer actually is" — and the premise was removed rather than worked around.

**Two capabilities existed only through the header and now have options.**
`JANET_OS_NAME` and `JANET_ARCH_NAME` were bare tokens a user set in a
hand-written `janetconf.h`; `src/zig/state_abi.h` carried a `JANET_ZIG_STRINGIFY`
block solely because translate-c cannot recover an identifier's text. They are
`-Dos-name` and `-Darch-name`, and the block is deleted.

**Three things the increment found.** The site count was 91, not the 57 the
phase file predicted, because the sweep had been scoped to `src/zig` and
`test/` holds thirty-seven more — a contract compiled *into* the runtime has to
agree with it about what was compiled, so of course it asks the same questions.
Five macros the runtime reads are defined by *nothing* in this tree
(`JANET_NO_SPAWN`, `JANET_NO_SYMLINKS`, `JANET_NO_LOCALES`, `JANET_DEBUG`,
`JANET_PLAN9`), which is rule 72's class: comptime-false, so never analysed.
And a contract refused a mechanical substitution — `JANET_64` became
`@sizeOf(usize) == 8` everywhere until `test/ffi_layout.zig` stopped compiling,
its doc comment insisting on "the same input the subject reads … rather than
`@sizeOf(usize)`, which is a different question that happens to agree here".
The comment was the instrument; the build error was an unused import and named
nothing about the mistake.

The acceptance matrix is 21 PASS / 0 FLAKY / 0 FAIL, the core image is the
recorded 324,310 bytes exactly, and the library still exports 690 symbols. No
benchmark is owed: no runtime logic changed, only where its comptime conditions
come from.

## The seam is counted, and three earlier counts were greps

*Phase 12 increment 2.* No source under `src/` or `test/` changed. What landed
is `port/seam.janet` and the list it writes, `port/seam.txt`: every `c.janet_*`
name the tree spells, what publishes it, and which header declares it.

**349 names, of which 331 resolve to a definition published in `src/zig` and 18
are `janet.h` macros, across 8,448 references.** The phase file predicted 249.
Every name resolves — nothing here spells a `c.janet_*` that is neither a symbol
Zig publishes nor a macro `janet.h` defines — and the tool fails if one ever
does.

**The seam is worth a sentence of its own, because it is easy to read the
number and not the thing.** `janet_table_get` is defined in Zig at
`struct_table.zig:546` and called from Zig as `c.janet_table_get(...)`, which
resolves through `janet.h:1870` and lands back in the compilation it left. The
runtime leaves Zig, goes out through a C header, and comes back, for a function
that was never C. That is 7,703 call sites, and the cost is not stylistic: a
`callconv(.c)` boundary cannot carry an error union — which is the whole
subject of `swallowed.janet` and thirteen repaired sites — cannot inline, and
is checked against the header rather than against the definition.

**Three figures for this population have been published and all three were
greps.** The Part 24 gate read 3,795 references across 373 names; `phase_12.md`
re-read it as 3,440 across 269. Both were wrong in both directions at once, and
the reasons generalise past this tree.

**A grep counts prose, and a long rewrite makes that worse over time.** Five of
the 269 names occur only inside comments, and three name abis that no longer
exist: `janet_run_vm` and `janet_formatc` were retired in Phase 10 Part 18, and
`janet_` is a wildcard in a sentence about `c.janet_*_head`. The more history
the comments carry, the more retired names they spell, and nothing in the
output distinguishes a call from a note about a call that used to be there. So
the tool strips comments — and the check that says the stripper works is that a
comment-only reference scores as absent, which was verified rather than
assumed.

**A grep over `src/zig` is half the tree.** `test/` holds 5,018 of the 8,448
references — more than the runtime itself — across 289 names, 85 of which appear
nowhere in `src/zig`. Phase 11 Part 1 decided a contract is compiled *into* a
second copy of the runtime, so it reaches its subject exactly as the runtime
does and spells exactly the same seam. Increment 1 found the same thing about
`@hasDecl` sites one increment earlier. When a population is defined by *how
the runtime is reached*, `test/` is in it by construction.

**And one grep cannot see the population anyway.** A symbol reaches a Zig
definition three ways — `export fn`, `@export(&f, .{ .name = "…" })`, and
`export const`/`var` for the data — and an `export fn` sweep scores 261 of the
331. Part 21's `pub extern` finding from the other side: the mechanism a symbol
is published by is not visible at the call site.

**The headers needed stripping too, and that one changed an answer rather than
a count.** Reading `janet.h` and `src/core/*.h` for `janet_*` tokens without
stripping C comments files `janet_vm` as public, because `janet.h` mentions it
three times in prose while `state.h` is what declares it. `janet_vm` is the
heaviest name in the list at 574 references, and public-versus-internal is the
*only* distinction item 3 draws — so the unstripped read puts the largest entry
on the wrong side of the one question being asked.

**What the measurement overturned is item 2's own premise.** It opened with
"each retirement pays down item 3 as a side effect". **300 of the 331 names are
`janet.h`'s**, so the symbol stays exported however its call sites are
rewritten; only 31 internal-header names can leave with their last caller. The
seam and item 3's harvest population are in fact disjoint — every seam name is
in some header, necessarily, since `c.` *is* the `@cImport` namespace, and the
104 harvestable names are in none. This does not move the increment order,
which decision 1 had already fixed on the `callconv(.c)` blind-spot argument.
It is a second, independent reason for it.

**`--check` is a ratchet, not a diff.** A name leaving the list is the work, so
departures and changed weights are reported and pass; a name *arriving* is a
new C-ABI call written where a direct Zig one would do, and it fails. Verified
capable of failing on a new name, on an unresolved name, and — in the other
direction — on correctly ignoring a comment-only reference.

The acceptance matrix is 21 PASS / 0 FLAKY / 0 FAIL in 559.2s wall,
`swallowed.janet` is silent, and **no `.zig` file, no header and no
`build.zig` changed** — which is the claim that matters for an increment whose
deliverable is an instrument. This file is the one thing under `src/` it
touches.

## The types become Zig's, and a layout oracle that had to be attacked

**Phase 12 increment 3.** `src/zig/types.zig` — 113 declarations, the Janet
types owned by Zig rather than translated out of `janet.h` — with
`src/zig/types_check.zig` holding it to the `@cImport` while both exist.

**Not on the phase's list, and the same shape as increment 1.** That one found
the build's *configuration* had to move before the header could go; this one
finds the types must, and for a harder reason: 4,815 `c.Janet*` references have
nowhere to resolve the moment `janet.h` leaves the translation. `phase_12.md`
sequences "retire the header" before "the type flag day", and that order cannot
be run — retiring the header *is* the flag day, or at least cannot precede it.

### The definitions are translate-c's output, not a reading of the header

Every declaration was extracted from the translation Zig already generates, for
four configurations — native nanbox-64, `-Dnanbox=false`, `x86_64-windows-gnu`
and `riscv32-linux-musl` — and diffed against one another. That is also what
established how little varies: of 99 extracted declarations only `Janet`,
`JanetHandle`, `JanetAtomicInt` and `JanetVM` differ at all, and the rest of the
diff is translate-c renumbering its anonymous unions per configuration.

`[*c]` is kept deliberately. It is translate-c's rendering of `T *`, and
replacing it with `[*]`, `?*` or a slice is a per-site judgement about
nullability and count. This increment changes ownership and nothing else, which
is what lets the core image stay byte-identical across it.

### An oracle that has not been attacked has not been tested

The first `types_check` compared size, alignment and field offsets, passed
cleanly, and was **wrong**. Changing `JanetTable.deleted` from `i32` to `i64`
left the struct's size and every one of its offsets unchanged — padding absorbs
it — so a layout check that looks only at layout cannot see a type substitution
that layout hides.

The version that ships recurses into fields and compares size, alignment, kind
and signedness, stopping at pointers because `JanetTable.proto` is a
`*JanetTable` and recursion would not terminate. **Verified capable of failing
three ways**: a wrong field width (`JanetTable.deleted: size 4 vs 8`), a flipped
signedness (`JanetTable.count: signedness`), and a kind mismatch — which is how
`pthread_t` was caught during development.

It has a fixed lifetime and dies with the header, because after that there is
nothing to compare against. What inherits the job is weaker and indirect: the
byte-identical core image, and `DESIGN.md` §7's tagged layout. Neither would
notice a wrong field offset in a struct the image never marshals.

### `std.c` is not the platform, and macOS would never have said so

`std.c.pthread_attr_t` carries **glibc's** layout — 56 bytes of storage plus a
`c_long` of alignment. musl's is 56 bytes *total* on 64-bit and 36 on 32-bit.
`JanetVM` embeds one, so taking `std.c`'s definition moves every field after
`new_thread_attr` on every Linux target while remaining correct on Darwin.
`types_check` reported it as `pthread_attr_t: size 56 vs 64` on
`aarch64-linux-musl` and `36 vs 60` on `riscv32-linux-musl`, and only because
the cross-compile targets run.

The pthread types come from a libc `@cImport` now. That is not the dependency
this phase removes: Phase 10's decision 4 draws the line explicitly — "no C in
the tree" and "no libc" are different claims, and only the first is a goal.
What matters is that the size comes from the platform rather than from a table
somebody maintains by hand.

A second one went with it. **glibc types `pthread_t` as `c_ulong`** where musl
and Darwin make it a pointer, so `worker: pthread_t = null` is a compile error
on exactly one of the eight targets.

### Nesting an `extern struct` is not layout-transparent

Zig 0.16 removed `@Type`, so a conditional field list cannot be assembled at
comptime, and `JanetVM` has two guarded regions — `strerror_buf` is absent on
Windows and the event-loop block has four mutually exclusive backend arms that
vanish without `JANET_EV`. Nesting each guarded region in its own `extern
struct` compiles and reads far better.

It is also wrong, and the check that "verified" it was too simple: a nested pair
of `i32` fields does have the same offsets as the flat four. An inner struct
pads to *its own* alignment, so a backend arm ending in `timer_enabled: c_int`
rounds up to 16 where flat C packs `timer_enabled` and `c_raised` into one
eight-byte slot. `types_check` reported `JanetVM: size 848 vs 840`.

So the six combinations are written out in full. While the `@cImport` spelling
and this one coexist, a size disagreement on `janet_vm` is memory corruption
rather than a cosmetic difference.

### `janet.h` enters through six back doors

Removing `@cInclude("state_abi.h")` from `abi.zig` cost **20 names**, not the
several hundred expected, because `fiber.h`, `gc.h`, `emit.h`, `vector.h`,
`interop.h` and `runtime.h` each `#include <janet.h>` themselves. Retiring the
header means those six stop including it too. No planning document says so.

With all seven gone the translation is `math.h` alone, and every one of the 448
resulting errors is `has no member named 'X'` — 53 distinct names per batch,
each naming exactly what to define. The compiler is the work queue.

### What ran

Eighteen configurations build with the oracle live: nine targets — including
all three 32-bit ones and both glibc and musl — plus the tagged layout and
eight reduced-feature builds. The feature guards in `types_check` were found by
sweeping every boolean option and diffing the translation's type list, after
three separate builds had each surfaced one of them; that is `phase_12.md`'s
rule 1 for the fourth time.

**690** exported symbols, unchanged. The core image is **324,310** bytes, the
recorded figure exactly. All 65 contracts pass with no argument, `zig build
test` and `zig build abi-test` are clean, `./port/seam.janet --check` agrees
with `port/seam.txt`, and `./port/swallowed.janet` is silent.

Nothing switched over. `types.zig` is reached only by its own oracle, which is
why the image and the export count could not have moved — and is the whole
reason this is a separate increment from the one that spends it.

## Phase 12 increment 4: the constants become Zig's

`src/zig/constants.zig` — 500 declarations — and `src/zig/constants_check.zig`,
which holds them to the `@cImport` and holds `Config` to the header's own
derivation. The companion to increment 3: that one took the types out of the
translation, this one takes the values, and between them they are what has to
exist before the seven `@cInclude`s can go.

### The extraction is a build step now

`abi.zig`'s block is a `@cImport`, which leaves no artefact a script can read.
`zig build translate` runs `addTranslateC` over the same headers, the same
include paths and the same generated `janetconf.h`, and installs the result as
`zig-out/translated.zig`. Three seconds a configuration, against a minute or
more for a full build, which is what made a **31-configuration** extraction
worth doing instead of a four-configuration one.

That matters more than it sounds. The presence of a constant, its type and its
value are all per-configuration facts, and the guards `constants_check` needs
are exactly "which configurations declare this". Increment 3 found its guards
one failing build at a time and then swept for the rest — `phase_12.md`'s rule
14. Here the sweep came first.

### 490 of the 500 are the same everywhere

Same value, same type, in all 31. The other ten are the interesting ones,
and they are not constants at all — they are the build's configuration wearing
a constant's clothes:

    JANET_VM_HAS_EV  JANET_VM_HAS_NET  JANET_VM_HAS_INTERRUPT  JANET_VM_THREAD_LOCAL
    JANET_NANBOX_BIT  JANET_SINGLE_THREADED_BIT  JANET_NANBOX_64_POINTER_SHIFT
    JANET_NANBOX_POINTER_SHIFT_BITS  JANET_CURRENT_CONFIG_BITS  JANET_HANDLE_NONE

The first four are `src/zig/state_abi.h`'s, and that header says why it exists:
"translate-c does not surface a macro defined with no value", so it restates
`#ifdef JANET_EV` as `#define JANET_VM_HAS_EV 1`. It is a configuration channel
built on purpose — and increment 1, which swept for `@hasDecl(c, "JANET_*")`,
could not see it. Twelve sites read `c.JANET_VM_HAS_EV != 0`. They are computed
from `@import("config")` here, along with the ten `janetconf.h` values —
the version quintet, `JANET_BUILD`, and the four limits — that the runtime had
also been reading back out of the translation.

### The half that found something

`janetConfig` reproduces `janet.h`'s derivation clause for clause and says so
in its own comment. Nothing checked it. `constants_check.verify` now compares
every clause against the translated header, and the first run reported

    JANET_NANBOX_64_POINTER_SHIFT: value 2 vs 0

`janet.h` gives aarch64 a two-bit pointer shift **unless** the target is Apple,
because aarch64 macOS has the same 47-bit userland address space as amd64:

    #if (defined(_M_ARM64) || defined(__aarch64__)) && !defined(JANET_APPLE)

`build.zig` had `apple and target.result.cpu.arch == .aarch64` — the inverse.

What made that harmful rather than merely wrong is two lines in `registry.zig`:

    if (config.value_repr != .nanbox_64 or config.nanbox_pointer_shift == 0) return;
    const mask: usize = (@as(usize, 1) << c.JANET_NANBOX_64_POINTER_SHIFT) - 1;

One fact, two sources, adjacent. Before increment 1 both read the header and
agreed. After it, on aarch64 Linux the guard returned early and the cfunction
alignment check was **off on the only targets that shift a pointer at all**;
on aarch64 macOS it ran with a zero mask and so checked nothing. Both platforms
lost the check and every build stayed green.

### The oracle was attacked

`types_check`'s rule 12 — an oracle that has not been attacked has not been
tested — applied to values rather than layouts. Six attacks, six diagnoses:

| attack | what it says |
| --- | --- |
| `JOP_ADD` 6 → 7 | `JOP_ADD: value 7 vs 6` |
| `JANET_SANDBOX_ALL` `c_uint` → `c_int` | `value -1 vs 4294967295` |
| `JANET_SIGNAL_OK` `c_int` → `c_uint`, value unchanged | `signedness c_uint vs c_int` |
| `JANET_SIGNAL_OK` `c_int` → `c_long`, value unchanged | `width c_long vs c_int` |
| the `RULE_` guard narrowed to `false` | `RULE_LITERAL: the header declares it here and constants.zig's guard says it should not` |
| the inverted shift clause restored | `JANET_NANBOX_64_POINTER_SHIFT: value 2 vs 0` |

The third and fourth are why the check is not a value comparison. `c_int` and
`c_uint` agree on every value both can hold, and disagree on the comparisons
and the masks written against them — the value domain's version of increment
3's finding that a layout check cannot see a type substitution padding hides.

Presence is compared **in both directions**. A guard that is too narrow and one
that is too wide both fail, which is what keeps the seven guard families honest
as the header changes underneath them.

### Two earlier populations were short, and for the same reason

`Shadowing` is `compile.h`'s enum, spelled `c.Shadowing` at two sites. Increment
3 swept `c.Janet*`, so it collected `Consumer` and `SymPair` — which are Janet
types that are not `Janet`-prefixed, caught only because something else named
them — and missed this one. It is in `types.zig` now.

`port/seam.txt` was **37 names and 347 references short**: `seam.janet` matched
`c.janet_`, and the compiler's own abis are `janetc_*`. Every one of the 37 is
an `export fn` reached across the C ABI in `emit_core.zig`, `regalloc.zig` and
`compiler_primitives.zig` — precisely what the tool enumerates. The seam is
**386 names across 8,795 references**, and because none of the 37 is declared in
`janet.h`, the population that can leave the export surface before the header
does went from 31 names to **68**.

Both are the same mistake: a population named by a prefix gets measured over
the prefix. Enumerating `c.<anything>` and sorting into buckets found both, and
cost one grep more than the wrong answer did.

### What ran

**Thirty configurations** build with both oracles live: ten targets — including
all three 32-bit ones and both glibc and musl — the tagged layout, and eleven
reduced-feature builds. 30 pass, 0 fail.

**690** exported symbols, unchanged. The core image is **324,310** bytes, the
recorded figure exactly — both re-measured against a clean `zig-out` after the
cross-compile sweep had left another target's artefacts in it, which is the
only way either number means anything. All 65 contracts pass with no argument,
`zig build test` and `zig build abi-test` are clean, `./port/seam.janet --check`
agrees with the regenerated `port/seam.txt`, and `./port/swallowed.janet` is
silent.

Nothing switched over. `constants.zig` is reached only by its own oracle, which
is why the image and the export count could not have moved — the same shape as
increment 3, and for the same reason.

### The tree is `zig fmt` clean, and the matrix keeps it that way

Fifteen files were not: eight under `src/zig`, seven under `test/`, none of
them this increment's. "Six lines of incidental churn, and why they stayed"
above is why — a Phase 10 increment reached for `zig fmt src/zig/`, found it
reformatting twenty-odd unrelated files, and reverted them, because **the tree
had never been formatted**. Every increment since had the same good local
reason not to be the one that paid for it.

Two checks made paying it safe. For each of the thirteen files this increment
did not otherwise edit, `zig fmt` applied to the HEAD version is **byte-
identical** to the file as it now stands — so the reformat contains nothing of
this increment's. And Zig 0.16's formatter is not purely cosmetic: the entry
above records it canonicalising `@constCast(@ptrCast(x))` into
`@ptrCast(@constCast(x))`, which `git diff -w` does not hide. The diff was
grepped for every `@*Cast` and holds none.

`port/matrix.janet`'s preflight now runs `zig fmt --check build.zig src/zig
test` before the first build and refuses to start otherwise, naming every
offending file and the one command that fixes them. Not CI, and not a matrix
*job*: whether the tree is formatted is a whole-tree fact rather than a
per-configuration one, and the matrix is the instrument that actually runs per
increment.

## Phase 12 increment 5b: `c` becomes Zig

`src/zig/cabi.zig` is what `abi.zig` re-exports as `c`. The `@cImport` beside it
is `raw`, it has three users left — `types_check.zig`, `constants_check.zig` and
`abi_test.zig` — and all three die with the header. **No declaration the runtime
calls reaches it through `janet.h` any more.**

### The planned increment did not survive its first build

It was going to be a rename: `c.Janet` to `types.Janet`, 4,926 sites, atomic
because the two are layout-identical but distinct types. That flag day compiled
exactly far enough to say

    error: expected type '[*c]cimport.struct_JanetTable', found '*types.JanetTable'

**A declaration carries its types.** While `janet_table_get` is declared by the
translation it takes `cimport.struct_JanetTable`, so every rewritten call site
met an unrewritten signature. The rename is downstream of the declarations, not
the way into them — which is why this increment replaces `c` wholesale instead,
and why the rename is now optional cosmetics rather than a flag day.

### Generated, not transcribed

Same method as increments 3 and 4: `zig build translate` per configuration, then
the `pub extern fn`, `pub extern const` and `pub inline fn` lines for the names
the tree actually spells, with Janet type spellings rewritten to `types.`. 90
type aliases, 473 constant aliases, 10 data declarations, 413 function
declarations, 22 macros, and `BUFSIZ`/`EOF` from a libc `@cImport` — which Phase
10's decision 4 permits by name.

The ten data symbols are **declared**, not aliased. Phase 11's rule 56: an alias
of a `const` is a copy, and seven call sites take the address of an abstract
type and compare it.

### `janet_vm` is `c.vm()`

The one name that could not be a declaration. Its storage class follows
`-Dsingle-threaded`; a container-level declaration cannot be conditional; Zig
0.16 removed `usingnamespace`, so two variants of this file cannot share a
common one; and an alias of a variable is a copy. `@extern` takes
`is_thread_local` as a runtime-known option *inside a function*:

    pub inline fn vm() *types.JanetVM {
        return @extern(*types.JanetVM, .{
            .name = "janet_vm",
            .is_thread_local = !config.single_threaded,
        });
    }

Probed against a real `threadlocal var` before adoption — same address. 597 call
sites changed; `c.vm().blocks` reads like `c.janet_vm.blocks` did, because Zig
auto-dereferences a single-item pointer.

### Six configuration probes, five of them silent

`test/ffi_layout.zig` aborted on the first run: `prim("size")` decoded 32-bit.

    const is_64_bit = @hasDecl(abi.c, "JANET_64");

Increment 4 put `JANET_64` in `@import("builtin")` where it belongs, so
`cabi.zig` does not declare it. Sweeping for the general form found five more,
all asking whether a **function** exists as a proxy for `JANET_INT_TYPES`:

    @hasDecl(c, "janet_scan_numeric")   numscan.zig, parser_core.zig
    @hasDecl(c, "janet_unwrap_s64")     test/peg.zig, test/args_core.zig ×2

Increment 1's sweep was `grep '@hasDecl(c, "JANET_'`, so the first escaped on the
namespace spelling and the other five on the name. **The five failed silently**:
`cabi.zig` declares those functions unconditionally, so all five became
permanently true and a `-Dint-types=false` build would have believed int types
were on. All six read `config` now.

### What ran

**Thirty configurations** build, 0 fail — and the reduced-feature ones are the
point, because that is where the five silent probes were wrong. Matrix **21 PASS
/ 0 FLAKY / 0 FAIL**. 65 contracts, `zig build test`, `zig build abi-test`,
`seam.janet --check`, `zig fmt --check` all clean. **690** exported symbols,
unchanged.

The core image is **324,310** bytes and **byte-identical to the previous
commit's** with `-Dsourcemaps=false` — the form rule 21 prescribes, and the
strongest statement available that a change of this size moved no behaviour.

`port/seam.txt` is 385 names across 7,476 references, down from 386/8,050 with
`janet_vm`'s 574. What it measures has changed meaning, though: these are still
C-ABI calls, but they are declared in Zig now — a list of calls that *could* be
direct, rather than calls that *must* go through a header.

### What this does not buy

Checking. An `extern fn` declaration is a promise Zig believes, exactly as the
header was, so a signature that disagrees with the `export fn` it names is
undiagnosed. `subsystems/root.zig` can reach both sides and `port/seam.txt`
carries every definition site, so one comptime `@TypeOf` comparison per name
would close it for all 367 at once. That is the next increment, and it comes
before converting any call site — otherwise each conversion is hopeful rather
than verified.

## Phase 12 increment 5c: the declarations get a checker

`src/zig/subsystems/cabi_check.zig` compares **294 declarations** in
`cabi.zig` against the `export fn` each one names, across 44 files, on every
build. 5b moved the declarations into Zig; it did not move the checking, because
an `extern fn` is a promise the compiler believes exactly as `janet.h` was.

It lives under `subsystems/` because that is the only module that can see both
halves. 287 definitions became `pub export fn` so it can name them — Zig
visibility and not the symbol table, **690 exports either side** — and that is
also what 5d needs, since a direct call cannot import what is not `pub`.

### 139 of 294 disagreed, and the header was the lossy one

Every one was `[*c]T` against `*T`. translate-c writes `[*c]` because C's `T *`
says nothing about null or count; the definitions say `*JanetArray`. So for 139
abis **every call site has been checked against a weaker claim than the code
makes**. `types.zig` had already deferred replacing `[*c]` as a per-site
judgement; this is that pass, measured. The check normalises pointer flavour —
`pointee()` and `compatible()` — and compares calling convention, arity, and
each parameter and return.

### Seven were real, and five were one cause

    janet_dynfile janet_getfile janet_makefile janet_makejfile janet_unwrapfile
        declared ?*types.FILE, defined ?*io_core.FILE

`io_core.zig` had `pub const FILE = opaque {}` of its own beside
`types.FILE`, so the tree held **two `FILE` types** and those five abis
declared one and defined the other. Both opaque, so ABI-identical and harmless
— and nothing had ever compared the two halves, which is the whole point.
`io_core` uses `types.FILE` now.

The other two are corrected in `cabi.zig` *against the definition*, because the
definition is the truth and the header only ever approximated it:
`janet_table_get_ex` takes a pointer to an **optional** table pointer, which
`janet.h` cannot say; and `janet_vm_load` promises `*const`, where the header
says `JanetVM *`.

### The gate, and rule 72 backwards

The first version imported all 44 files unconditionally. Green by default, and:

    ev_backend.zig:148:41: error: no field named 'selfpipe' in struct 'types.JanetVM'

under `-Dev=false` and `-Dsingle-threaded=true`. **An `export fn` is emitted
because its file is in the compilation, not because something calls it** —
which is exactly why `root.zig` writes `if (options.ev_loop) _ = @import(...)`.
Rule 72 says a comptime-false branch is never analysed and so never checked, and
the tree treats that as a gap to close with cross-compiles; the mirror is that
an instrument reaching past the gates does not close the gap, it breaks builds
nobody runs by default. The gating mirrors `root.zig` file by file now, with the
three `ev_*` files on `ev_loop`'s gate and `pp_describe` on `pp`'s.

Verified capable of failing on a dropped parameter, a wrong integer width, a
pointer to the wrong type, and — separately — on a declaration inside a *gated*
file, since a wrong gate would silently disable thirty-odd checks rather than
erroring.

### What is not checked

**73 of the 367**, named rather than glossed: 59 published by `@export`, where
the symbol and the Zig identifier differ and the mapping is not mechanical; 10
`export data`; 4 defined in `interop.zig`, which belongs to the client module.

`port/seam.txt` excludes this file. Its 294 `@TypeOf` references are the
instrument watching the calls rather than calls, and counting them added exactly
one to every row — the ordering right and every number wrong.

### What ran

Thirty configurations, 0 fail. Matrix **21 PASS / 0 FLAKY / 0 FAIL**. 65
contracts, `zig build test`, `abi-test`, `seam.janet --check`,
`swallowed.janet`, `zig fmt --check` all clean. **690** exports and a
**324,310**-byte image, both unchanged — the check is comptime and emits
nothing.

## Phase 12 increment 5d — the seam, converted

`c.janet_table_get(t, key)` is `struct_table.tableGet(t, key)`. **37 files,
461 definitions renamed**, the seam **367 names / 7,476 references → 168 /
3,087**, `cabi.zig` **413 declarations → 222**, `cabi_check.zig` **294 rows →
102**. `port/convert.janet` does a file at a time.

Every subsystem `root.zig` imports unconditionally is done. The gated ones the
tool refuses on rule 28, and rightly — an `@import` forces analysis where the
linker did not, so converting them means carrying the gate to each caller.

### The name

Decided 2026-08-27 with the user, before the first batch, as `phase_12.md`
required. **Strip `janet_` or `janetc_`, then camelCase the underscores.**

```zig
pub export fn janet_table_get(t: *c.JanetTable, key: c.Janet) callconv(.c) c.Janet {
```
becomes
```zig
pub fn tableGet(t: *c.JanetTable, key: c.Janet) callconv(.c) c.Janet {
...
comptime {
    @export(&tableGet, .{ .name = "janet_table_get" });
}
```

`export fn` fuses the Zig identifier to the linker symbol; `@export` splits
them, with the same default visibility and the same name. **690 exports either
side.** The alternatives were keeping the C spelling — which leaves 298 of them
in Zig permanently, and cannot be used at all for the 59 names already
published by `@export` — and curating a name per function, which is 298
judgements and collides where one file owns two families. The mechanical rule
needs none, so a batch reads as a diff.

`callconv(.c)` stays on the definition. Dropping it would need a second
`callconv(.c)` shim per name, because `@export` does not change a calling
convention — and choosing the honest signature for each is the `[*c]` pass
`types.zig` deferred and 5c priced, which is its own increment and not this
one.

### What the rule found

Of the tree's 507 `export fn`, **53 already have their camelCase name as a
container declaration in the same file**, and it is almost always the
implementation the abi wraps: `janet_init` beside
`pub fn init() raise.Raising(c_int)`. The rule rediscovers a split rather than
colliding with an unrelated name.

Those are held, and not because they are awkward. The implementation *raises*,
so pointing `c.janet_init()` at `vm_lifecycle.init()` obliges that caller to
`try` — a decision about the caller, which is exactly what `port/swallowed.janet`
exists to police. They are the next pass, and the valuable one, because that is
where the error union actually crosses.

Nine more are shadowed by a function-local of the same name, which Zig forbids,
and two land on a Zig keyword — `janetc_error`, `janetc_return`.

### Twelve unchecked nulls, three of them visible here

`filewatch_core.zig` and `specials_core.zig` pass `?*JanetTable` where the
definition says `*JanetTable`. Through the declaration this was silent:
`cabi.zig` said `[*c]types.JanetTable`, which accepts an optional pointer and
hands the callee a null to dereference. Increment 5c measured that looseness at
139 of 294 declarations; this is the first time it was met at a call site.

All twelve are provably non-null and **provable only from a different
variable** — `watch_descriptors` is `janet_table(0)` in each backend's `init`
and never assigned null; `attributes` is null exactly when `handleAttributes`
reported a compile error, which the line above the call already tests. No type
can see either, which is why both files were already writing `.?` at
neighbouring sites. The twelve are `.?` now.

**Three compile on macOS.** `x86_64-linux-musl` adds one, `x86_64-windows-gnu`
four. Four backend arms, three never analysed at home — `phase_11.md`'s rule 72,
arriving as an ordinary type error.

### The tool

Eleven defects, every one found by running it and not by reading it. Six are
the same shape, which `phase_12.md` records as rules 29 through 39.

- **A module root cannot import a subsystem.** `src/zig/raise.zig` is the
  `raise` module's root; adding `@import("subsystems/string_symbol.zig")` to it
  gives `file exists in modules 'root' and 'raise'`. The rewrite population is
  `src/zig/subsystems/` and `test/` and nothing else.
- **`cabi.zig` calls its own declarations by bare name.** Its eighteen
  `pub inline fn` macros are the callers a `c.`-prefixed sweep cannot see —
  `janet_string_length` is `janet_string_head(s).*.length`.
- **`cabi_check.zig` names every declaration through `c.` on purpose**, so the
  same sweep reported all of them live. `port/seam.txt` had already excluded
  the file for that reason; the tool had not inherited it.
- **The gate is `root.zig`'s**, not the file name's: `utils.zig` is reached
  under `options.utilities`.
- **The rule can land on a Zig keyword** — and "reserved" in Zig is two lists
  and a shape: keywords (`error`, `return`), primitive type names (`type`,
  which `janet_type` strips to), and the arbitrary-width integer types, where
  `u7` is a type as surely as `u8` is.
- **The import the tool adds is a declaration in somebody else's file.**
  `vector.zig` met five files with locals or **function parameters** named
  `vector` — 26 errors, none about a renamed function. Parameters are declared
  in the signature, where a scan of the body never sees them.
- **A prefix match on an import path is a different import.** The alias
  detector matched `const ops = @import("subsystems").value_wrap` and ignored
  the trailing `.ops`.

Definition lines are rewritten **by line number**, not by spelling: four files
carry a doc comment naming an `export fn janet_*`, and `raise.zig`'s stands
above the definition it describes, so a text match would have edited the
comment and left the definition alone. Everything else goes through
`tools/rewrite-code`, which `phase_12.md`'s rule 26 put in the library.

### The already-split names, and the two that stayed

Rule 30's population: 53 names whose camelCase form was already the
implementation the abi wraps. `janet_init` beside
`pub fn init() raise.Raising(c_int)` — the abi flattens that raise into a
report, and a report nobody consumes kills the process at the next protected
scope naming neither cause nor caller.

It was **203 references**, not 53 judgements, because the batches before it had
already converted everything the runtime could reach: 178 in contracts, 23 in
`boot.zig` / `boot_tests.zig` / `interop.zig`, 2 in `registry.zig`. Sixty-four
sites were spelled `_ = c.janet_init();` character for character and 67 were
`c.janet_core_env(null)`, so three `test/harness.zig` helpers took 170 of them
and eight went inline.

**The last two stayed, and stayed for a reason.** `resolveCore` and
`getCoreTable` are `@export`ed abis — `janet_resolve_core` is declared
in `janet.h` — so neither can carry an error union, and reaching
`core_env.coreEnv` from inside one would mean catching the error and
re-reporting it, which is exactly what the abi does. An abi is not debt
everywhere it appears; the seam is calls that *could* be direct.

### The calling convention, which is the finding that would have hurt

`export fn` supplies a calling convention and `pub fn` does not. Measured on
this host:

```text
export fn f(x: i32) i32           ->  .aarch64_aapcs_darwin
pub fn f(x: i32) i32              ->  .auto
pub fn f(x: i32) callconv(.c) i32 ->  .aarch64_aapcs_darwin
```

**97 `export fn` in this tree never spelled it**, because `export` was
spelling it for them. Renaming one to `pub fn` + `@export` keeps the symbol's
name and address and changes its ABI, and no in-tree caller could notice
because every in-tree caller is Zig.

It is a build failure and not a silent break, and only because Zig refuses:
`@export` on an `.auto` function is `extern function must specify calling
convention`. 28 definitions needed the convention written out, twelve of them
with signatures spanning several lines. The tool does it now.

### Two repairs that were worse than the fault

Both were name-to-name substitutions whose *source* side meant more than one
thing.

Undoing the `janetc_return` rename rewrote **76 `return` statements** — the
rewriter matches whole identifiers, correctly, and `return` is one. Exactly
reversible, because the function is `janetc_return(` with a paren and the
keyword never is.

The second was not so cheap. Having mis-detected `ops` as the alias for
`value_wrap` (rule 38), repointing `ops.X` → `value_wrap.X` also rewrote **32
sites that were genuinely `ops.`** — the namespace this file carries because
`run_vm` measured +89% reaching those operations through the symbol table, and
which `test/value_wrap.zig` compares against the symbol on purpose. After the
repair, `assert(ops.truthy(x) == c.janet_truthy(x))` compared a function with
itself: green, and testing nothing.

The fix was to rebuild the contract from `HEAD` applying only the conversion
this increment was entitled to, and to check the count of the spelling *not*
being converted — `grep -c 'ops\.'`, 32 before and 32 after.

### What ran

Matrix **33 PASS / 0 FLAKY / 0 FAIL**, 259.8s, `MATRIX DONE` present. 65
contracts with no argument, `zig build test` exit 0 over 38 suites, **six
cross-targets** — both glibc, Windows, RISC-V, both 32-bit — `seam.janet
--check`, `swallowed.janet` and `zig fmt --check` clean. **690** exports and a
**324,310**-byte core image, both unchanged, read off a `rm -rf zig-out`
rebuild whose artefact was `file`d first. Seam: **165 names / 2,909
references**, from 367 / 7,476.

## Phase 12 increment 6a — the namespace, batch 1

`struct_table.tableGet(t, key)` is `tables.get(t, key)`. The first of
`port/NAMESPACES.md`'s four batches, and the one that had to prove the whole
shape at the smallest size: a split, a rename, plural namespaces, and `new`
against `init`.

`struct_table.zig` is `src/zig/subsystems/value/tables.zig` and
`value/structs.zig`. **656 member call sites and 143 seam call sites across 49
files**, **690** exports unchanged, the core image **324,310 → 324,345** and
predicted to the byte.

### Why the file was two nouns

`src/core` holds 0 `.c` files and 18 headers, and every subsystem file is still
named after a C file that no longer exists. `struct_table.zig` held 17 `table*`
functions and 8 `struct*` ones, and the name was two nouns because C had two
files — which is how `struct_table.tableNew(0)` came to read the way it does. A
module cannot carry the noun when it holds two of them.

The taxonomy the split follows is `janet.h`'s own, and deriving it rather than
inventing one is the point: `janet_indexed_view`, `janet_bytes_view` and
`janet_dictionary_view` group the value types into indexed, bytes and
dictionary, and table and struct are the dictionary pair. It is defensible to a
reader who knows Janet and not this port.

### The two shapes of leaf

A **type leaf** takes a plural noun and its functions drop the type:
`tables.new(0)`, `tables.init(t, cap)`, `tables.get`, `tables.put`,
`tables.deinit`. An **operation leaf** takes a present participle —
`wrapping`, `typing`, `ordering` — and arrives in batches 3 and 4. Neither is
idiomatic Zig and both are deliberate; `NAMESPACES.md` records them as choices
rather than oversights.

`new` allocates and `init` initialises in place. Zig's own convention is
`Type.init` returning a `Type` **by value** with allocation left to the caller,
and it does not apply here: these allocate from Janet's GC heap and return a
pointer, so pretending otherwise would describe the function wrongly.

### What the batch dissolved

The largest block left on the seam after increment 5d was item (d) — **561
references shadowed** by a local or a parameter, because a name like
`janet_table` strips to `table` and 32 files bind that word. `janet_table` alone
was 152 of them, and it had been held for two increments as a name needing a
per-case judgement.

It needed a namespace. The function is `new`, the alias is `tables`, and the
plural collides in **0** files of 180. `janet_table` went **152 references →
6**, all six in the three modules outside the runtime root, and the seam went
**1,268 → 1,122**. The rule generalises: **a name that cannot be spelled is
sometimes a fact about the namespace rather than about the name.**

### Circular imports, and what Phase 8 was working around

`structs.zig` calls `tables.put`; `tables.zig` calls `structs.begin`,
`structs.put` and `structs.end`. The files import each other and Zig does not
care.

The old file's head gave exactly this as the reason the two could not be
separated — "they are mutually recursive across the file boundary" — which was
true of C and inherited without being re-asked. Phase 10 Part 17a had already
changed it, when sixty-three compilations became one. Same shape as rule 69: **a
limitation recorded as the language's should be re-tested when the language
changes.**

### The image moves, and a split is not a move

`corefn.zig` records a repo-relative `source_file` per cfun, so a file that
moves changes the image. `NAMESPACES.md` measured that on a throwaway move and
had the delta as the path-length change; a **split** adds a term, because the
path is interned and every later mention is a backreference. One string and
N-1 backreferences become two strings and N-2. Predicted +35, measured +35 —
and the backreference cost is fitted from one observation, which is why batch 2
is where it is confirmed or corrected.

### What ran

Matrix **33 PASS / 0 FLAKY / 0 FAIL**, 267.3s, `MATRIX DONE` present, with
`contracts-default` retargeted to `struct_table`, `value_access`, `registry`
and `marsh` — the subject and the three heaviest callers, since the subject was
rewritten by hand and the callers by a tool. 65 contracts with no argument,
`zig build test` exit 0 over 38 suites, `seam.janet --check`, `swallowed.janet`
and `zig fmt --check` clean. **690** exports and a **324,345**-byte core image,
read off a `rm -rf zig-out` rebuild. Seam: **154 names / 1,122 references**,
from 154 / 1,268.

## Phase 12 increment 6b — the namespace, batch 2

The two cross-grain splits. `buffer_array.zig` is `value/arrays.zig` and
`value/buffers.zig`; `string_symbol.zig` is `value/strings.zig`,
`value/symbols.zig` and `value/tuples.zig`. **410 member call sites and 189 seam
call sites across 76 files**, **690** exports unchanged, the seam **1,122 → 933
references**.

`port/NAMESPACES.md`'s survey found both by counting rather than by reading, and
both held up. `buffer_array.zig` held 13 `buffer*` functions and 7 `array*`
ones, which is a merge across the grain of Janet's own taxonomy — a buffer is
**bytes** and an array is **indexed**, and `janet_bytes_view` and
`janet_indexed_view` have drawn that line since long before the port.
`string_symbol.zig` held three `tuple*` functions under a name with `string` in
it.

### What a build found that the design had not

Batch 1 was mechanical throughout. This one was not, twice, and both departures
arrived as compile errors.

**`janet_array_n` strips to `n`**, which shadowed `asSize`'s parameter and a
local in `array/insert` immediately. Rule 2's collision check was
member-against-member; this is member-against-*local*, and a one-letter
container declaration loses that fight in any file.

The replacement took two goes. `newN` compiled and was still wrong: beside
`new(capacity)` it reads as "new, of size N", and that is how it was read one
increment later — `new(4)` reserves four slots and holds nothing, while this
allocates four and copies four elements in. It is `newFrom` now, with
`tuples.newFrom`. **A compile error tells you a name is impossible, never that
it is wrong.**

**`janet_buffer_push_cstring`'s abi and its raising kernel differed by one
letter's case** — `bufferPushCstring` against `bufferPushCString`. Under the
namespace they would have sat in one scope as `pushCstring` and `pushCString`,
where choosing wrongly silently swallows a raise. The abi is `pushCstringAbi`,
after the convention increment 5d already established for an abi over a raising
implementation.

Both pairs had been in the tree for an increment or more. **The namespace does
not create these collisions; it makes them visible.**

### A head accessor may not be duplicated

A symbol is a string with an entry in `janet_vm.cache`, so `symbols.zig` needs a
string's head. Batch 1's line decided it — a leaf may duplicate a private
predicate, never a definition anything else can observe — so `strings.zig`
exports `head` and `data` as `pub` and `symbols.zig` calls them. Copying them
would have made item 4a's population 22 and 23 rather than 21, which is the
increment this one must not make harder. `asSize` was duplicated four more times
on the same rule, because two copies of it cannot disagree observably and two
copies of a pointer offset can.

### The image check stopped being a prediction

Batch 1 fitted a three-byte backreference cost to its own measurement and
predicted +35 exactly. Batch 2 predicted +67 and measured **+69**, and no
constant reconciles them, because a backreference carries a variable-width
index.

Line numbers were ruled out rather than assumed — `corefn.reg` records
`@src().line`, so two blank lines went in at the top of `tuples.zig` and the
image was rebuilt at **324,414 either way** — and so was any change to the
entries, since the 68 `corefn.reg` names are identical across the split.

What replaced the model is exact and cheaper:

    strings -n 8 zig-out/janet-image.bin | grep 'src/zig/subsystems'

27 paths, each appearing once, each prefixed by a byte holding its length. Six
sit under `value/`, and `value/symbols.zig` is **not** among them: that file
registers no cfun, because `symbol/slice` and `keyword/slice` are registered by
`libString` and the registration site is what the image records. The arithmetic
hid that. The listing states it.

### What ran

Matrix **33 PASS / 0 FLAKY / 0 FAIL**, 275.6s, `MATRIX DONE` present, with
`contracts-default` retargeted to `buffer_array`, `string_symbol`,
`value_access` and `utils`. 65 contracts with no argument, `zig build test` exit
0 over 38 suites, `seam.janet --check`, `swallowed.janet` and `zig fmt --check`
clean. **690** exports and a **324,414**-byte core image, read off a
`rm -rf zig-out` rebuild. Seam: **154 names / 933 references**, from 154 / 1,122.

## Phase 12 increment 6c — the namespace, batch 3

The remaining five value subsystems, and the first batch with a *merge*.
`abstract_core.zig` is `value/abstracts.zig`, `value_order.zig` is
`value/ordering.zig`, `value_access.zig` is `value/accessing.zig`, and
`fiber_core.zig` and `value_alloc.zig` are `value/fibers.zig` and
`value/functions.zig`. **475 member call sites and 184 seam call sites across
65 files**, 690 exports unchanged, the seam **933 → 749 references** and
**154 → 151 names**: `janet_abstract` (72), `janet_hash` (64) and
`janet_fiber_reset` (6) retired, `janet_fiber` 43 → 1.

`port/NAMESPACES.md` has the scheme and this does not repeat it.

### A merge asks a question a split does not

A split asks where each name goes. A merge asks whether two files that each
carried a private copy of something agree about it, and **both pairs here did
not.**

`value_alloc.zig`'s `janetBytes` is `@as(usize, @intCast(n)) *% @sizeOf(c.Janet)`
and traps on a negative `n`; `fiber_core.zig`'s is
`@bitCast(@as(isize, n) *% @as(isize, @sizeOf(c.Janet)))` and wraps one into an
enormous `size_t`. The wrap is load-bearing — `janet_fiber_setcapacity`
reproduces C by failing the allocation rather than trapping — and each file's
doc comment argues correctly for its own version over its own callers.
`setStatus` differed too, in its parameter type and in where the shift happens.
The merged file keeps the general one of each pair, both being identical over
the inputs the other's callers pass.

Batch 1's rule needed its sharper form for this. It allowed `asSize` in two
files because two copies cannot disagree observably. **A size computation has a
domain, and two copies can disagree on it** — the test is whether the two
answers can differ for any input either caller can produce, not whether the
helper is small.

### The funcenv trio is where the merge and the split pull against each other

`NAMESPACES.md` sends `janet_env_valid` and `janet_env_maybe_detach` to
`functions.zig`, because a funcenv is a *closure's* captured environment.
Validating one means walking the frames of the fiber it names, so `functions.zig`
asks `fibers` for the geometry — `fibers.stackFrame`, `fibers.janetBytes`,
`fibers.finished` — rather than keeping a second copy, which is batch 2's
`strings.head` line applied to a pointer offset.

It goes both ways, and the compiler said so: `envDetach` is what
`fibers.popframe` and `fibers.funcframeTail` run over a frame's environment as
they drop it. So `functions.zig` owns it and `fibers.zig` calls it, and the two
import each other — the second circular pair in `value/` after batch 1's
`tables`/`structs`.

`isFinished` improved on the way. The C original carried its seven-case status
list twice, once per caller; the split separates those callers, so it is
`fibers.finished(f)` and neither leaf holds the list a third time.

### Three names, and the population a collision check must cover

**`fiberReset` and `janet_fiber_reset` both strip to `reset`** — C told them
apart by the prefix this scheme removes. The private one is `resetState`. The
general form is worth a grep before the next batch: **a `static` and its
`janet_`-prefixed neighbour are a collision waiting for the strip.**

**`accessing.get` hit three locals and only one was a `var`.** The other two
were `if (at.*.get) |get|`. A capture is a local declaration and shadows exactly
as a `var` does, and a survey that greps for `var` and `const` sees neither.
Batch 2 stated the member-against-local rule after `janet_array_n` stripped to
`n`; this is the missing third of it.

**`fibers.status` collided with a parameter named `status`** in two private
helpers, one from each merged file.

`janet_hash` cost exactly what the note predicted — one rename of the local
`var hash: i32 = 0;` inside the function being converted — and 64 references
stopped being `c.janet_hash`.

### The image formula came back, because this batch interns no new path

27 interned paths before and 27 after: a merge and four renames add no distinct
path string, so there is no split term and the image moves by the path-length
delta alone. **324,414 → 324,416**, which is
`len("value/fibers.zig") - len("fiber_core.zig")` exactly.

Seven paths sit under `value/` now. `abstracts`, `ordering`, `accessing` and
`functions` appear in no entry at all — they register no cfun, joining
`symbols.zig` from batch 2. The listing states that and no arithmetic could.

### A return type found a C defect

`janet_fiber` answers null when the callee's arity rejects the argument count,
and `net.c`'s accept callback dereferences the result without looking — so a
`net/server` whose handler takes the wrong number of arguments segfaults on its
first connection. `janet.h` declares `JanetFiber *`, `@cImport` renders it
`[*c]JanetFiber`, and a `[*c]` pointer dereferences without a word; the Zig
`?*JanetFiber` does not compile until the caller says what it means.
`port/FOUND.md` has it. This is increment 5c's finding at a call site for the
second time, and the more interesting of the two — batch 2's was a spelling,
this one is a missing check.

**The Windows arm is the same defect and only the matrix sees it.** The first
matrix run was 32/1 on `x86_64-windows-gnu (build only)`: the other accept
callback, plus `filewatch_core.zig`'s watcher, deref the same fresh fiber under
`#ifdef` arms no host build compiles. The two are not the same claim.
`net_sockets`'s `.?` is *because C does not check*; `filewatch_core`'s is
*because the null is impossible* — its callee is `janet_thunk_delay`'s funcdef,
`min_arity` 0 and `max_arity` `INT32_MAX`, so the arity check cannot reject the
zero arguments it passes. The comments say which is which.

Twelve contracts lost an `assert(fiber != null)` that the unwrap now makes
statically, which is the good version of the same change.

### What ran

Matrix **33 PASS / 0 FLAKY / 0 FAIL**, 154.6s, `MATRIX DONE` present — on the
second run; the first was 32/1 on the Windows cross-build. `contracts-default`
retargeted to `fiber_core`, `value_alloc`, `value_access` and `vm_run`. 65 contracts with no argument at exit 0, `zig build test` exit 0
over 38 suites, `seam.janet --check`, `swallowed.janet` and `zig fmt --check`
clean. **690** exports and a **324,416**-byte core image, read off a
`rm -rf zig-out` rebuild, with the 27 interned paths listed out of the image.
Seam: **151 names / 749 references**, from 154 / 933.

## Phase 12 increment 6e — the namespace, batch 4

`value_wrap.zig` is `value/wrapping.zig` and `value/typing.zig`. **2,701 member
call sites and 68 seam call sites across 110 files** — more than the three
earlier batches together — 690 exports unchanged, the seam **749 → 681
references** with `janet_type` **95 → 27**, and the core image unchanged byte
for byte at 324,416.

**`value/` is fourteen leaves.** `port/NAMESPACES.md` has the scheme; the value
layer is finished and what follows it is that note's open question 1.

### The largest batch was the least eventful, and that was the ordering working

The note put this one last because it is the biggest rename and because the
tool would have been exercised four times by then. It had, and had been
corrected three times, so the biggest population in the tree went through as a
table plus a diff. Everything batch 4 found was *inside* the file being split —
which is the half no tool touches.

### A file with a private implementation cannot be renamed by pattern

`value_wrap.zig` holds three private layout structs — `nanbox64`, `nanbox32`,
`tagged` — each with its own `wrapPointer`, `unwrapNumber` and `typeOf`. Those
are the *implementation* of the representation, not the namespace's surface,
and a blanket `wrapPointer` → `fromPointer` renamed both: `nanbox64` ended up
with two members called `fromPointer`. Loud, and the good case. The layout
section was restored verbatim from the commit and the rename applied to the
surface only.

The subtler half compiled. **A struct member does not shadow a container
declaration in Zig; it makes the unqualified name ambiguous** — which is why
the file already carried the `outer.` idiom for `abi` and `ops` reaching the
container from inside a struct. Renaming the container's `wrapPointer` made
`nanbox64`'s own bare `fromPointer` calls ambiguous, pointing the other way.
Both directions of the rule now live in one file.

**Rule 26 keeps the rewriter out of a qualified self-reference.**
`tools/rewrite-code` will not match an identifier preceded by `.`, so
`outer.wrapNil()` in the twenty `abi` bodies and `&abi.wrapNil` in the export
block were untouched and repaired by hand. Both were compile errors, so nothing
was at risk — but a file that reaches itself through a qualified name needs a
pass the batch tool does not do, which the `os_*` reorganisation should expect.

### `janet_type` was the largest name left on the seam

95 references, spelled `c.janet_type` for two increments because nothing could
spell it in Zig. `NAMESPACES.md` rule 7 — a reserved name takes the tree's own
word — and the three layout structs had had an `inline fn typeOf` each since
Phase 8. It is `typing.typeOf` now, 95 → 27, and the 27 left are in the modules
outside the runtime root plus the exempt contract.

The nineteen `janet_wrap_*` names look like more of the same and are not: every
surviving reference is in `boot.zig`, `boot_tests.zig`, `interop.zig`,
`native_module.zig`, `raise.zig`, `cabi.zig` — or in `test/value_wrap.zig`,
which is `CONVERSION-EXEMPT` *because* comparing the exported symbol against
the inline surface is what it is for.

### The layout is shared, not copied

All four inspection names are answered by the representation and the
representation stays in `wrapping.zig`, so `repr` is `pub` for exactly one
reader — with the declaration saying so — and the three questions `typing.zig`
asks are `pub` inside each layout struct. Nothing else is.

*(The two files are `value/helpers/wrap.zig` and `value/helpers/kind.zig`
since increment 6f retired the gerunds. The arrangement is unchanged: `repr` is
still `pub` for that one reader, and the fold that would have retired it was
reversed.)* This is batch 2's
line where it matters most: **a second copy of the bit patterns is the one
duplication that could disagree with the values themselves.** Forwarder
functions on `wrapping` would have put two spellings of `typeOf` in one
subtree, which is what the note exists to prevent.

### What the split did not change, deliberately

`typing.checkType` still answers `c_int`, because 218 of its 228 call sites
carry an explicit `!= 0` or `== 0` and a `bool` return is a change to every one
of them the split does not need. `wrapping.ops` already holds the `bool`
spelling for the interpreter.

`ops` survives with a smaller reason than it had: since 5d(c) the container's
wraps are `pub inline fn`, so its +89% measurement is about the symbol table
and no longer distinguishes `ops.fromNil()` from `fromNil()`. Nineteen of
twenty-one members are pure aliases now. Retiring it means converging three
signatures over about three hundred call sites — a decision, not a rename.

### Three `extern fn` declarations went with the file

Increment 6a recorded six declarations in `tables.zig` and `structs.zig` for
functions that are already Zig, and named the repair it could not make: *"a
two-file edit in files this batch does not open."* Batch 4 opens
`value_wrap.zig` to destroy it, so `memallocEmpty` and `memempty` became `pub`
at no cost and three declarations went. The four left are `utils.zig`'s. The
rule: **when a batch opens a file, check what the tree has recorded as blocked
on that file being open.**

### What ran

Matrix **33 PASS / 0 FLAKY / 0 FAIL**, `MATRIX DONE` present, with
`contracts-default` retargeted to `value_wrap`, `vm_run`, `value_access` and
`value_order`. 65 contracts with no argument at exit 0, `zig build test` exit 0
over 38 suites, `seam.janet --check`, `swallowed.janet` and `zig fmt --check`
clean. **690** exports and a **324,416**-byte core image — unchanged, because
`value_wrap.zig` registered no cfun and so was never one of the 27 interned
paths. Seam: **151 names / 681 references**, from 151 / 749.

## Phase 12 increment 6f — decision 3, carried out and then revised

*Increments 6d, 6g, 6i, 6j and the earlier batches of 6f are recorded in
`port/phase_12.md` and not here; this file's per-increment narrative has been
behind the phase file since batch 4. What follows is the last piece of 6f.*

**Where it ended up.** `value/` is eleven type leaves — the types Janet
publishes — beside `value/helpers/{access,order,kind,wrap}.zig`, the four
operations defined over an arbitrary `Janet`, with `value.zig` the bucket
holding the hashing and dictionary machinery. 91 `.zig` files under `src/`,
**690** exports, a **324,052**-byte image over 27 interned paths.

**How it got there was a round trip**, and the round trip is the finding.
Decision 3 said the four operations go *into* the bucket, on the grounds that
an operation over every Janet value is not a leaf of a type taxonomy. That was
carried out in full and then reversed the same day. Both halves are worth
recording because between them they price a structural choice against its
alternative, which is not something this project usually gets to do.

### The fold: one leaf at a time, because a scripted merge was not

A four-way scripted merge was tried first and did not converge — 1 error, then
7, then 63 — and was reverted. The reason is `phase_12.md`'s rule 59: the
destination declares `length`, `hash`, `next`, `get`, `put`, `compare` and
`equals` to 2,400 lines written when it did not, so the shadowing arrives as a
*series* rather than a list, and the total is never visible in advance.

Taken in four steps instead, each built, each given a matrix:

    step  leaf        call sites  files   what it cost
    1     accessing          183      6   nothing -- clean at the first build
    2     ordering           176     20   14 locals named `hash`; 3 duplicate helpers
    3     typing             427     57   91 lines of code against 57 files
    4     wrapping         2,465    108   one ambiguous reference

Rule 59 asked for one measurement before starting — count each short public
name across the merged set — and that measurement was right: step 2's `hash`
was the only word that cost anything, at fourteen sites.

**Step 4's collision was between step 3's half and step 4's.**
`nanbox64.truthy` called its own struct's `checkType` unqualified, which
resolved to the nearer declaration until `typing`'s `checkType` arrived at
container level one step earlier. Zig then reports `ambiguous reference` — a
build failure, not a silent change. Two things follow, and both are rule 60: a
four-way fold's collisions are **not pairwise**, so they cannot be read off
either file against the destination; and a language that preferred the inner
declaration would have compiled this and changed which function the interpreter
calls under one of three value layouts.

### The reversal: what the fold actually measured

The concern that reopened it was file size, and **it did not survive
measurement** — which is rule 62 and the most reusable thing here. The folded
file was 2,901 lines and read as the largest in the tree; it was **1,530 code,
1,146 comment, 225 blank**, and third by code behind `peg.zig` at 1,833 and
`marsh.zig` at 1,603. The comment was the four merged prose blocks, which had
to exist wherever the code did. This tree comments heavily on purpose, so the
raw line count is a systematically bad proxy here and worst right after a
merge.

So the decision turned on two other numbers, both real and pointing opposite
ways:

  - the four are a strict DAG — `wrap ← kind ← order ← access` — checked by the
    compiler on every build, and one file dissolves it into a namespace where
    anything may call anything;
  - of the 107 files that use these names, **61 want two or more** — 47 want
    two, 13 want three, one wants all four — so a split makes the majority pay
    in imports for a layering they cannot see.

The layering won. `phase_12.md`'s decision 3 carries both figures so the next
reader does not find only the one that suits them.

**The option neither the decision nor `STRUCTURE.md` had considered** is the
one that landed: both framed it as bucket-or-sibling, and the middle term was
missing. *Not being a type leaf is a reason not to be their sibling; it is not
by itself a reason to be in the bucket.* `value/helpers/` keeps the two
populations apart without flattening either — and it has **no bucket of its
own**, because a subdirectory that exists only to group siblings is served by
the parent's. That distinction is now in `STRUCTURE.md`'s "THE TWO SHAPES".

### The `value` identifier, and then `kind`

Increment 6i freed `value` as a local or parameter across the 58 files that
clashed *then*. The fold re-created the clash **twelve times** in files 6i
never had to look at — `saturatingCast`'s parameter in `os.zig`, `ev.zig` and
`os/fs.zig`, `environSet`'s, `whenAt`'s local, five captures across four
contracts — because a file gains the clash the moment a pass gives it the
import. Rule 61.

The reversal then charged the same tax on `kind`, seven times:
`bytecode.zig`'s `kind: i32` twice (now `failure`), `compiler/specials.zig`'s
four `kind: BindingKind` parameters (now `binding_kind`), `parser.zig`'s local
(now `type_name`). A language runtime makes `kind` an ordinary word.

### Three `saturatingCast`s, and this is not where they get fixed

`os.zig`, `ev.zig` and `os/fs.zig` each hold a byte-identical copy, found only
because all three shadowed `value` on the same parameter during the fold. That
is `wrapInteger`'s family — five copies with a `FOUND.md` entry — and the fs
batch already ruled that the small platform shims are copied rather than
shared. **A rename pass is not where a duplication is consolidated.**

### Two tool findings

**The dot guard was right twice and cost a pass each time.**
`tools/rewrite-code` refuses a match whose preceding byte is `.`, which is what
keeps `c.janet_vm` out of `&c.janet_vm.field`. It therefore skipped all 74
`@import("subsystems").value.wrapping` spellings in `test/`, because `value`
there is itself preceded by a dot. The working key is `.value.wrapping`, with
the leading dot *inside* it. Increment 6j found the first half of this; the
rule is that **the key must start at a byte the guard will accept**, which for
a member access means starting at the dot.

**`port/move.janet` misses two shapes**, both rule 63. A `value/` leaf imports
its siblings by bare name — `@import("typing.zig")` — so the tool repaired
sixty-odd import paths and left twenty-three; that is the same blind spot
increment 6i's sweep had, in the same directory. And a moved file's own `../`
imports to files that did *not* move are one level too shallow at the
destination. Neither is fixed: an instrument is not repaired in the middle of
the increment using it.

### Three `_impl` aliases retired, which the fold was supposed to do

`ordering_impl`, `typing_impl` and `wrapping_impl` were increment 6j's, kept to
get a build green and described there as "the category of name this increment
exists to remove", with the expectation that 6f's merge would dissolve them.
They dissolved in the *reversal* instead: `value.zig` had two declarations of
the same import, one `pub` for the barrel and one private for its own use, and
one `pub const` serves both. **So the thing 6j called temporary by construction
was not waiting on the fold** — it was waiting on somebody noticing that a `pub
const` is readable from inside the file that declares it.

### What ran

Per fold step and again after the reversal: `zig build`, `zig fmt --check`, the
65 contracts with no argument at exit 0, `zig build test`, `seam.janet --check`
(**151 / 680**, unchanged), `swallowed.janet` clean, an eight-configuration
build-only sweep, and the three 32-bit targets — `nanbox32` being the one
layout struct a default build never analyses.

**Five acceptance matrices, 33 PASS / 0 FLAKY / 0 FAIL each.** The final one
ran in 273.0s with `contracts-default` on `value_wrap`, `value_access`,
`value_order` and `utils`. The oracle for the reversal is that it is a pure
move: 91 files, 690 exports and a 324,052-byte image over 27 interned paths,
all three identical to the commit before the fold, read rather than assumed.

## Phase 12 increment 6h — the last two splits, and a count that was one too many

*The file structure is finished here.* `src/` holds **91** `.zig` files, which
is `port/TREE.md`'s destination; `runtime.zig` is deleted and
`method_type.zig` created, so the increment is one file each way and the net is
zero.

### `method_type.zig`, the fourth retyped table

`corefn.zig` declared `Method` and never used it. Nine subsystems keep a method
table — `parser.zig`, `io.zig`, `peg.zig`, `net.zig`, `math.zig`,
`ev/stream.zig`, `ev/channel.zig`, `value/ints.zig`, `os/process.zig` — and
each reached the type through the registration layer only because that is where
it happened to be written. It sits beside `abstract_type.zig`,
`callback_type.zig` and `special_type.zig` now, which is what the suffix is
for: the four scatter alphabetically, and a reader who finds one should see the
others.

**`method_end` did not go with it.** `JANET_REG_END` for a method table had
never been referenced — all twelve tables in the tree spell
`.{ .name = null, .cfun = null }` inline — so it is deleted rather than moved.

**And the `of()`/`stored()` pair the other three carry is deliberately absent.**
The nineteen `@ptrCast` sites cast a Zig `Method` array *to* the C layout,
because `args_core.getmethod` and `nextmethod` are `callconv(.c)` over
`[*c]const c.JanetMethod`. Naming that cast is a decision about those two
signatures, which is increment 5h's; a split that also rewrote nineteen call
sites would have taken it by accident.

**The image is the oracle and it is exact.** Nine files gained one import line,
so every registration below it records a line one further down: **324,052 bytes
either side, the same 27 interned paths, no string difference, and 116
differing bytes whose delta histogram is `{+1: 116}`.**

### `interop.zig` is two files, and the division was not where the line was

`port/STRUCTURE.md` split the file at line 202 and called everything below it
the CLI. That line is a provenance marker — *"Everything below was
`src/zig/interop_bridge.c`"* — and a correction recorded later is what actually
divides the file: `make_rooted`, `wrap_integer` and `unwrap_function` are
called by `dispatch`, a dozen lines *above* the marker.

So only `janet_zig_cli_run` moved. `cli.zig` is 53 lines rather than the
predicted 110, and `interop.zig` is 297 rather than 200 — it **grew**, because
26 lines of code left and a head note arrived. Both predictions came from
reading the marker as a subject boundary.

**Moving it deleted three things rather than relocating one**, as planned: the
`janet_zig_cli_run` export, its declaration in `interop.h`, and the argv
marshalling in `main`, which existed only to hand C pointers across an ABI that
is no longer there. `run` takes the `[]const [:0]const u8` that
`std.process.Init` already has.

**Then all nine exports went.** Having divided the file by who calls what, the
answer was the same for every one of them: caller and callee are in this file
or one import away, so none needs a C symbol. They are plain Zig functions
named for the module rather than for the C prefix — `interop.register`,
`interop.lineGetterValue` — which is increment 6a's rule (`janet_table` became
`tables.new`) rather than 5d's mechanical camelCase. 5d's rule exists to avoid
per-name judgement across 461 definitions; at nine, inside the file that *is*
the namespace the prefix names, `interop.zigInteropRegister` is the worse
answer.

`interop.h` is down to the `JanetZigLine` typedef, `cabi.zig` lost four
declarations, and the seam is **147 names across 676 references**, from 151 and
680.

### The out-parameter was the ABI's, and the compiler said so twice

`wrapInteger` and `unwrapFunction` did not compile as Zig calls. `argv` is
`[*c]const Janet`, so `&argv[0]` is `*allowzero const Janet`, and the only
thing that had been accepting it for a `*const Janet` was the `[*c]`
declaration in `cabi.zig`.

The repair is not a cast: both pointer shapes were the bridge's rather than the
function's — this file's own comment said so about the first, *"this
out-parameter shape is what the C bridge existed to provide"*. `wrapInteger`
returns a `Janet` and `unwrapFunction` takes one. That is increment 5h's
population meeting a caller for the second time, and a third form of 5d's note:
a `[*c]` that becomes a real pointer finds a caller passing null, a test
asserting it will not, **or a parameter that should never have been a pointer
at all**.

### Two smaller things

**`runtime.h` is `fatal.h`**, and it was three lines rather than the predicted
two: `build.zig`'s `translate` step names the same seven headers as `abi.zig`,
which is the drift that step exists to make visible. The header declares
`fatal.zig`'s two `@export`s and never had anything to do with `runtime.zig`,
which exported nothing.

**`janet_zig_interop_defs` camelCases onto `defs`, and `defs` is the local
array inside it.** Zig refuses the shadowing, so the function is `define`. That
is increment 5d's population (d) — the nine `export fn` shadowed by a local —
met at the one name this increment had to choose.

### What ran

`zig build`, `zig fmt --check`, the 65 contracts with no argument at exit 0,
`zig build test` including `suite-zig-interop.janet`'s 30 assertions,
`zig build abi-test`, `zig build translate`, `seam.janet --check`, and
`swallowed.janet` clean. The client by hand for the two paths no contract
reaches: `-e` with trailing arguments, and a piped REPL for `getline`.

**Acceptance matrix 33 PASS / 0 FLAKY / 0 FAIL** in 270.4s, `contracts-default`
on `parser_core`, `math`, `inttypes` and `peg`. **690 exports, unchanged** —
nothing retired here was ever in `libjanet`, because `interop.zig` compiles
into the client alone.

**And `port/TREE.md`'s destination was 91, not 92.** It listed `runtime.zig`
among its destination files and totalled them, while `STRUCTURE.md` and the 6h
entry both said that file dissolves. `PLAN.md` inherited the 92 and read the
gap as `method_type.zig` alone. Diffing the destination list against `find src
-name '*.zig'` takes seconds, names exactly this, and is now what closes the
structural half.

## Phase 12 increment 5g — the aliases, spent

`cabi.zig` held 565 lines of the form `pub const Janet = types.Janet;` and
`pub const JANET_NUMBER = constants.JANET_NUMBER;`. They were there so that
increment 5b, which moved the declarations out of `janet.h`, could change no
call site — and they are the flattening Zig removed `usingnamespace` to
discourage. **8,577 references across 130 files spell `types.` and
`constants.` directly now, and the 565 lines are gone.** `cabi.zig` is 975
lines to 397, and everything left in it is the seam: 205 `extern fn`, 16
macros beside `vm()`, and 10 `extern const`.

`port/alias.janet` did it, five batches and a build each: `value/`, the
compiler and the bytecode, the gated subsystems, the rest of `src/zig`, and
`test/`. **690 exports and a 324,052-byte image, unmoved through all five and
through the deletion** — which is the whole of what a rename of two namespaces
should do.

### The three files it had to refuse

`types_check.zig`, `constants_check.zig` and `abi_test.zig` bind `c` to
`@import("abi").raw` — the `@cImport` — rather than to `@import("cabi")`. They
exist to assert that `types.JanetTable` has the header's size, alignment and
field offsets. Converting their `c.JanetTable` to `types.JanetTable` would
have compared a type with itself and passed forever: increment 5d's rule 39 at
a second pair of spellings.

Nothing at a call site distinguishes the two populations — `c.JanetTable`
reads identically in both — so the tool tests the binding at the head of each
file rather than trusting a list.

### The one pass whose misses are not compile errors

Every earlier rename here deleted the old spelling, so a site the rewriter
skipped stopped compiling at that site. This one leaves `c.Janet` and
`types.Janet` both legal until the aliases are deleted at the end, so a miss
stays green.

There were two, both `for (0..c.JANET_COUNT_TYPES)` in `test/value_wrap.zig`.
The rewriters here refuse a match whose left neighbour is `.`, so that
`abi.c.Janet` does not lose its `abi.` — and the second dot of Zig's `..`
range reads the same to that guard. It surfaced only when `cabi.zig` lost the
alias and the build answered `has no member named 'JANET_COUNT_TYPES'`. The
fix is one line and it went into `tools/path-dot?`, because
`tools/rewrite-code` carried the same blind spot through every pass since it
was written and nothing had been able to expose it.

### `ev.zig` was a facade at one name

The tool inserts its imports above `const c = @import("cabi");`. `ev.zig`
spells that line `pub const c = @import("cabi");`, so the substring matched
four bytes in and the insert landed between `pub ` and `const c` — publishing
`ev.types` and privatising `ev.c`. It compiled, because **nothing in the tree
names either**.

That is the interesting half. `ev.zig`'s `pub const c` was a second spelling of
a module already reachable by name — the facade shape increments 6d and 6g
spent — surviving because it is a line rather than a file and so appeared in no
file count. It is `const` now and the build is the proof it was dead. The
anchor is a whole line now, in both spellings.

### Five files bound the identifier

`types` and `constants` are ordinary identifiers and Zig forbids a local that
shadows a container-level declaration. Eight locals across five files were
renamed first, and two of them were badly named to begin with:
`bytecode.zig`'s `const constants = scanConstants(a, source)` holds a result
rather than the constants and is `scanned`, and `pp/format.zig`'s `var types`
is a bitmask being shifted and is `remaining`. `peg.zig` also has a *field* and
a *parameter* called `constants`, neither of which shadows anything — so the
check has to distinguish binding from naming.

### What ran

`zig build` after each batch and after the deletion, `zig fmt --check`, `zig
build test` — every suite and every contract — `alias.janet --check` clean,
`seam.janet --check` unchanged at 165 names and 676 references (this increment
converts no seam entry), and `swallowed.janet` clean.

**Acceptance matrix 33 PASS / 0 FLAKY / 0 FAIL** in 270.6s. `contracts-default`
is eight contracts spanning the layers rather than naming a subject, because
the subject is every file. **The oracles are what actually check this
increment and they are not contracts**: `types_check.zig` and
`constants_check.zig` compile in all thirty-three entries and hold `types.zig`
and `constants.zig` against the `@cImport`, so a `types.X` that is not the
header's X is a compile error everywhere rather than a test failure somewhere.
