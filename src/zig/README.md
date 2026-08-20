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
| `-Dargs-core=c` | `args_core.zig` | `core/capi.c`, `core/util.c` | `JANET_ZIG_ARGS_CORE` |
| `-Dgc-alloc=c` | `gc_alloc.zig` | `core/gc.c` | `JANET_ZIG_GC_ALLOC` |
| `-Dgc-mark=c` | `gc_mark.zig` | `core/gc.c` | `JANET_ZIG_GC_MARK` |
| `-Dgc-sweep=c` | `gc_sweep.zig` | `core/gc.c` | `JANET_ZIG_GC_SWEEP` |
| `-Dbuffer-array=c` | `buffer_array.zig` | `core/buffer.c`, `core/array.c` | `JANET_ZIG_BUFFER_ARRAY` |
| `-Dstring-symbol=c` | `string_symbol.zig` | `core/string.c`, `core/symcache.c`, `core/tuple.c` | `JANET_ZIG_STRING_SYMBOL` |
| `-Dstruct-table=c` | `struct_table.zig` | `core/struct.c`, `core/table.c` | `JANET_ZIG_STRUCT_TABLE` |
| `-Dvalue-order=c` | `value_order.zig` | `core/value.c` | `JANET_ZIG_VALUE_ORDER` |
| `-Dvalue-access=c` | `value_access.zig` | `core/value.c` | `JANET_ZIG_VALUE_ACCESS` |
| `-Dabstract-core=c` | `abstract_core.zig` | `core/abstract.c` | `JANET_ZIG_ABSTRACT_CORE` |
| `-Dvalue-alloc=c` | `value_alloc.zig` | `core/fiber.c`, `core/bytecode.c` | `JANET_ZIG_VALUE_ALLOC` |
| `-Dvalue-wrap=c` | `value_wrap.zig` | `core/wrap.c` | `JANET_ZIG_VALUE_WRAP` |
| `-Dvm-calls=c` | `vm_calls.zig` | `core/vm.c` | `JANET_ZIG_VM_CALLS` |
| `-Dvm-run=c` | `vm_run.zig` | `core/vm.c` | `JANET_ZIG_VM_RUN` |
| `-Dvm-entry=c` | `vm_entry.zig` | `core/vm.c` | `JANET_ZIG_VM_ENTRY` |
| `-Dvm-lifecycle=c` | `vm_lifecycle.zig` | `core/vm.c` | `JANET_ZIG_VM_LIFECYCLE` |
| `-Ddebug-frames=c` | `debug_frames.zig` | `core/debug.c` | `JANET_ZIG_DEBUG_FRAMES` |

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
through either implementation. `-Dargs-core` is ungated as well, and spans two
C files for the same reason `-Dsignal-core` does: the numeric predicates in
`util.c` and the getters in `capi.c` are one layer split across two files. Its
guard leaves every exported `janet_get*` and `janet_opt*` in C, because the
raise cannot be on the Zig side, along with the three view constructors, whose
signatures are public and one of which has to run an abstract type's `bytes`
callback itself. `-Dgc-alloc` is ungated too — there is no build without a
collector — and it takes the first of three bites out of `gc.c`, leaving
marking, sweeping, `janet_collect` and `janet_clear_memory` in C in both
configurations.

`-Dboot` is not a subsystem selector either, though it takes the same `c` or
`zig` values. It selects what the *bootstrap image generator* is built from
rather than what the runtime is: `-Dboot=zig` gives `janet-boot` the same
selectors as the runtime and builds a second set of subsystem objects for the
build host, so that `zig build image` can be run both ways and the two images
compared. It defaults to `c`, and Phase 9's gate is where the comparison was
first made — see "Closing the gate on the interpreter" at the end of this file.

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
