# Janet–Zig interoperation rules

The Phase 2 code uses the following rules until the relevant runtime
subsystems move to Zig:

- Janet owns all Janet values and managed allocations. Zig does not reproduce
  the allocator or garbage collector.
- A Janet value held across a call that may allocate must be visible to the
  collector. The interop test uses `janet_gcroot` and `janet_gcunroot`
  explicitly around a forced collection.
- A Janet `setjmp`/`longjmp` signal must never cross an active Zig frame.
- Any `setjmp` on a hot path must use the `_setjmp` spelling on Darwin, and must
  never become `sigsetjmp` with a non-zero savemask. Darwin's `setjmp` saves the
  signal mask and costs about 104ns per call against 2ns for `_setjmp`; glibc's
  and musl's `setjmp` do not save it, so the split at `janet.h:422-425` is what
  keeps a `setjmp` affordable at call granularity. Getting the spelling wrong is
  a fifty-fold regression on one platform only. Measured in `SPIKE-7.md`.
- Janet callbacks therefore enter through a C trampoline. Zig returns success
  or failure and an out-parameter normally; only after Zig has returned may
  the trampoline call `janet_panicv`.
- Potentially panicking allocation sequences called on Zig's behalf are
  enclosed by `janet_try` in a C helper. Any non-local jump lands inside that
  helper and becomes an ordinary `JanetSignal` before control returns to Zig.
- Zig invokes Janet functions with `janet_pcall`, not `janet_call`, so callback
  signals are resolved in C and returned explicitly.
- Zig exports use the C calling convention and C-compatible parameter types.
  `Janet` values cross Zig export boundaries through pointers/out-parameters;
  C-facing Janet callbacks remain thin C functions returning `Janet` by value.
- Zig errors and panics never cross the C ABI. Expected Janet failures use the
  explicit status-and-payload path; unexpected Zig failures are contained by
  functions that do not expose an error union.
- The simple Zig REPL reader allocates line memory with Zig's C allocator and
  transfers it to the C trampoline, which frees it after copying into a Janet
  buffer.

The C bridge is intentionally small. Later subsystem ports should reuse this
pattern until Janet's signal mechanism is replaced with explicit internal
control flow.

## Mixed-runtime subsystem rules

Phase 3 introduces `src/zig/subsystems/vector.zig` as the first selectable
runtime subsystem. The normal build uses it; pass `-Dvector=c` to use
`src/core/vector.c` instead. Both choices retain the same `janet_v_grow` and
`janet_v_flattenmem` C ABI, so callers do not know which implementation was
linked.

The build owns implementation selection and must add exactly one provider of
each subsystem's exported symbols. The static library, shared library, Zig
client, and comparison C client all receive the same selection. The bootstrap
tool is separate: it runs on the build host and continues to use the C vector
while producing the runtime image.

Subsystems should depend on `abi.zig` for C declarations and expose only a
narrow C-compatible seam. They may call public or deliberately bridged Janet
services, but should not reproduce unrelated private VM layouts. The vector
port depends on Janet's scratch allocator (`janet_srealloc`), ordinary
allocator (`janet_malloc`), and a C OOM bridge. Its two-word `int32_t` prefix
is part of the existing private vector contract shared with `vector.h`; it is
not added to the public Janet API.

The "unrelated" in that rule is load-bearing, and Phase 7 reaches the case it
was reserving. A leaf subsystem that reproduced `JanetVM`'s shape would be
copying a layout it has no business knowing; a port *of* the runtime core has
to know it. See "Owning the thread-local VM state" for where the line moved and
why.

No Janet signal may cross an active Zig frame. The vector allocation failure
bridge invokes the existing fatal `JANET_OUT_OF_MEMORY` policy from C and is
declared not to return; a custom policy must not `longjmp` through the Zig
caller. Later ports with recoverable failures should use the explicit
protected-call pattern described above.

Phase 4 adds three more Zig-default leaf selectors:

- `-Dutilities=c` for hash primitives and table-capacity rounding.
- `-Dint-scan=c` for signed and unsigned 64-bit literal scanning.
- `-Dtext-scan=c` for UTF-8 and symbol-character validation.

The relevant C source remains compiled for its other responsibilities; a
build macro removes only the functions supplied by the selected Zig object.
This keeps the migration seam smaller than the original C file boundary.

Run `zig build subsystem-test` for focused contracts. `zig build test` includes
those contracts plus the ABI, embedding, CLI, native-module, and Janet language
tests. Set any selector to `c` to run the identical graph against its fallback;
for example, use `zig build test -Dutilities=c -Dint-scan=c -Dtext-scan=c` for
the all-C Phase 4 comparison. `zig build test -Dnanbox=false -Dprf=true` covers
tagged values and keyed hashing with the Zig implementations.

## Subsystem index

Every selector defaults to `zig`; passing `c` restores the original
implementation for differential testing. Where a guard macro is listed, the C
file stays in the build and the macro removes only the ported functions;
otherwise the build swaps whole source files.

| Selector | Zig source | C origin | Guard macro |
| --- | --- | --- | --- |
| `-Dvector=c` | `vector.zig` | `core/vector.c` | whole file |
| `-Dutilities=c` | `utils.zig` | `core/util.c` | `JANET_ZIG_UTILS` |
| `-Dint-scan=c` | `intscan.zig` | `core/strtod.c` | `JANET_ZIG_INTSCAN` |
| `-Dtext-scan=c` | `textscan.zig` | `core/util.c` | `JANET_ZIG_TEXTSCAN` |
| `-Dregalloc=c` | `regalloc.zig` | `core/regalloc.c` | whole file |
| `-Dverify=c` | `verify.zig` | `core/bytecode.c` | `JANET_ZIG_VERIFY` |
| `-Dremove-noops=c` | `remove_noops.zig` | `core/bytecode.c` | `JANET_ZIG_REMOVE_NOOPS` |
| `-Dmovopt=c` | `movopt.zig` | `core/bytecode.c` | `JANET_ZIG_MOVOPT` |
| `-Demit-core=c` | `emit_core.zig` | `core/emit.c` | `JANET_ZIG_EMIT_CORE` |
| `-Dasm-encode=c` | `asm_encode.zig` | `core/asm.c` | `JANET_ZIG_ASM_ENCODE` |
| `-Dasm-decode=c` | `asm_decode.zig` | `core/asm.c` | `JANET_ZIG_ASM_DECODE` |
| `-Ddisasm=c` | `disasm.zig` | `core/asm.c` | `JANET_ZIG_DISASM` |
| `-Dcompiler-primitives=c` | `compiler_primitives.zig` | `core/compile.c` | `JANET_ZIG_COMPILER_PRIMITIVES` |
| `-Dparser-core=c` | `parser_core.zig` | `core/parse.c` | `JANET_ZIG_PARSER_CORE` |
| `-Dspecials-core=c` | `specials_core.zig` | `core/specials.c` | `JANET_ZIG_SPECIALS_CORE` |
| `-Dbuiltin-optimizers=c` | `builtin_optimizers.zig` | `core/cfuns.c` | `JANET_ZIG_BUILTIN_OPTIMIZERS` |
| `-Dnumber-scan=c` | `numscan.zig` | `core/strtod.c` | `JANET_ZIG_NUMSCAN` |
| `-Dmath-core=c` | `math.zig` | `core/math.c` | `JANET_ZIG_MATH_CORE` |
| `-Dint-types-core=c` | `inttypes.zig` | `core/inttypes.c` | `JANET_ZIG_INT_TYPES_CORE` |
| `-Dos-permissions=c` | `os_permissions.zig` | `core/os.c` | `JANET_ZIG_OS_PERMISSIONS` |
| `-Dos-platform=c` | `os_platform.zig` | `core/os.c` | `JANET_ZIG_OS_PLATFORM` |
| `-Dos-environ=c` | `os_environ.zig` | `core/os.c` | `JANET_ZIG_OS_ENVIRON` |
| `-Dos-fs=c` | `os_fs.zig` | `core/os.c` | `JANET_ZIG_OS_FS` |
| `-Dos-stat=c` | `os_stat.zig` | `core/os.c` | `JANET_ZIG_OS_STAT` |
| `-Dos-time=c` | `os_time.zig` | `core/util.c`, `core/os.c` | `JANET_ZIG_OS_TIME` |
| `-Dos-fs-paths=c` | `os_fs_paths.zig` | `core/os.c` | `JANET_ZIG_OS_FS_PATHS` |
| `-Dio-core=c` | `io_core.zig` | `core/io.c` | `JANET_ZIG_IO_CORE` |
| `-Dos-process=c` | `os_process.zig` | `core/os.c` | `JANET_ZIG_OS_PROCESS` |
| `-Dev-core=c` | `ev_core.zig` | `core/ev.c` | `JANET_ZIG_EV_CORE` |
| `-Dffi-layout=c` | `ffi_layout.zig` | `core/ffi.c` | `JANET_ZIG_FFI_LAYOUT` |
| `-Dffi-classify=c` | `ffi_classify.zig` | `core/ffi.c` | `JANET_ZIG_FFI_CLASSIFY` |
| `-Dfilewatch-flags=c` | `filewatch_flags.zig` | `core/filewatch.c` | `JANET_ZIG_FILEWATCH_FLAGS` |
| `-Dvm-state=c` | `vm_state.zig` | `core/state.c` | `JANET_ZIG_VM_STATE` |
| `-Dfiber-core=c` | `fiber_core.zig` | `core/fiber.c` | `JANET_ZIG_FIBER_CORE` |
| `-Dsignal-core=c` | `signal_core.zig` | `core/vm.c`, `core/capi.c` | `JANET_ZIG_SIGNAL_CORE` |
| `-Dtrace-frames=c` | `trace_frames.zig` | `core/debug.c` | `JANET_ZIG_TRACE_FRAMES` |

`-Dint-scan` and `-Dint-types-core` are only offered when integer types are
enabled, the three assembly selectors only when the assembler is, and
`-Dos-permissions`, `-Dos-environ`, `-Dos-fs`, `-Dos-stat`, and
`-Dos-fs-paths` only in a full OS build. `-Dos-time` follows `JANET_GETTIME`,
which `util.h` defines unless the build is both reduced-OS and single-threaded.
`-Dos-process` needs a full OS build *and* `-Dprocesses=true`, which is what
`hasProcesses` in `build.zig` expresses; the process functions are compiled
only under both conditions, so the subsystem and its contract exist only there.
`-Dio-core` is ungated: `core/io.c` is compiled in every configuration,
reduced-OS included, so the selector and its contract apply there too.
`-Dev-core` follows `JANET_EV`, which `features.h` defines unless the build
disables the event loop or is single-threaded; `hasEv` in `build.zig` expresses
the same condition, and everything in `ev.c` — the subsystem and its contract
included — exists only there. `-Dffi-layout` and `-Dffi-classify` both follow
`JANET_FFI`, which `janet.h` defines unless the build sets `JANET_NO_FFI`, so
the selectors and their contracts exist whenever `-Dffi` is left on. Neither
follows the *architecture* gates inside `ffi.c`: all three calling conventions
are compiled on every target and only their use is `#ifdef`-ed, which is
discussed below. `-Dfilewatch-flags` follows both `JANET_EV` and
`JANET_FILEWATCH`, which is what `hasFilewatch` in `build.zig` expresses:
`filewatch.c` is wrapped in both, so the subsystem and its contract exist only
where the file watcher does. Like the FFI conventions, it does not follow the
*backend* gates inside that file — all three vocabularies are compiled on every
target, and the `#ifdef`s decide only which backend a build actually runs.
`-Dvm-state` is ungated: `state.c` is compiled in every configuration, and the
selector covers the storage of `janet_vm` as well as the functions over it, so
its guard macro removes the variable too. `-Dfiber-core` is ungated for the same
reason — there is no build without fibers — and its guard leaves `fiber.c`'s
cfunctions, its fiber allocation, and its variadic-tail builder in C in both
configurations. `-Dsignal-core` and `-Dtrace-frames` are ungated as well: try
scopes, raising, and stack traces exist in every build. `-Dsignal-core` spans two
C files rather than one, because the try scope and the raise it catches are one
mechanism split across `vm.c` and `capi.c`; its guard leaves the `longjmp`, the
coercion message, `janet_check_can_resume`, and the whole of
`janet_continue_no_check` in C in both configurations. `-Dtrace-frames` guards
only the decoding: `janet_stacktrace_ext` itself is compiled once and prints
through either implementation.

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
- Every return path sets `JANET_FIBER_DID_LONGJUMP`, exactly as `janet_signalv`
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

One difference follows from that and is not repairable in Zig 0.16. `export`
carries default visibility, so `janet_vm` becomes an exported dynamic symbol of
`libjanet`, where the C build's `-fvisibility=hidden` kept it internal. Nothing
public references it — it appears nowhere in `janet.h` — so this widens the
shared library's symbol set without changing anything that already linked, and
the `c` selector restores the original. Worth knowing when reading a symbol
diff; not worth working around with a linker script.

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

## Adding a subsystem

Each port touches five places in `build.zig` and one in the C source. Missing
any of them fails quietly rather than loudly, so work through all of them:

1. Add `src/zig/subsystems/<name>.zig`. Import `abi` for the C declarations and
   export only C-compatible functions.
2. Add a field to `BuildOptions` and to `RuntimeSubsystems`.
3. Construct the object with `makeZigSubsystemObject` in the `subsystems`
   literal, gated on any feature flag the subsystem depends on.
4. Read the option in `readOptions` with `orelse .zig`.
5. In `addRuntimeSources`, add the guard macro and `addObject` — or a
   `switch` over whole source files if the port replaces a file outright.
6. Guard the C original with `#ifdef JANET_ZIG_<NAME>` so exactly one
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

Special-form bodies are in `subsystems/specials_core.zig`
(`-Dspecials-core=c`), which owns every form from `quote` through `fn` along
with the sorted name registry and its binary lookup. The C special table stays
the authoritative registry and selects C or Zig callbacks at build time, so a
name added on one side and not the other fails the lookup-parity contract.

`subsystems/parser_core.zig` (`-Dparser-core=c`) owns the parser lifecycle,
result queue, cloning, status and error recovery, the streaming loop, stack
management, container assembly, and string, escape, Unicode, and long-string
decoding. Public `janet_parser_consume` and `janet_parser_eof` remain C
trampolines that reject a dead or unchecked-error parser before entering Zig,
and formatted delimiter and EOF diagnostics stay in C because they construct
Janet-owned strings.

`subsystems/builtin_optimizers.zig` (`-Dbuiltin-optimizers=c`) holds the
builtin-function optimizer registry, arity gates, reducers, comparison chains,
indexed mutation, apply lowering, signals, and propagation. Only the
representation-sensitive construction of nil, boolean, and integer Janet values
stays in narrow C helpers.

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
`jstat_t`, `struct timespec`, and `struct _finddata_t` behind. What crosses is
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
pointer keeps the collector's roots a purely C concern. C dispatches on the type
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
made on an ARM64 laptop was not even syntax-checked. All three now compile
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
