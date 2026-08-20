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
services, but should not reproduce unrelated private VM layouts.

*The "C-compatible seam" clause is narrower since Phase 10 Part 17a, and the
change is the subject of "One module, and the seam that was a link boundary"
below.* Every Zig subsystem is now compiled together, so a call from one to
another is an ordinary Zig call and the C ABI is no longer between them. The
seam that has to stay C-compatible is the one facing **C**: what `src/core/*.c`
still calls, and what an embedder would if the C ABI were not ending in this
phase. A raise-capable function reached from another subsystem should return
`raise.Error` and keep a C face beside it, rather than being written to the C
ABI and jumping. The vector
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
| `-Dutilities=c` | `utils.zig` | `core/util.c`, `core/capi.c` | `JANET_ZIG_UTILS` |
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
| `-Dasm-core=c` | `asm_core.zig` | `core/asm.c` | `JANET_ZIG_ASM_CORE` |
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
| `-Dos-surface=c` | `os_surface.zig`, `os_files.zig`, `os_procs.zig`, `os_calendar.zig` | `core/os.c` | `JANET_ZIG_OS_SURFACE` |
| `-Dev-core=c` | `ev_core.zig` | `core/ev.c` | `JANET_ZIG_EV_CORE` |
| `-Dev-loop=c` | `ev_loop.zig`, `ev_stream.zig`, `ev_channel.zig`, `ev_backend.zig` | `core/ev.c` | `JANET_ZIG_EV_LOOP` |
| `-Dnet-sockets=c` | `net_sockets.zig`, `net_addr.zig` | `core/net.c` | `JANET_ZIG_NET_SOCKETS` |
| `-Dffi-layout=c` | `ffi_layout.zig` | `core/ffi.c` | `JANET_ZIG_FFI_LAYOUT` |
| `-Dffi-classify=c` | `ffi_classify.zig` | `core/ffi.c` | `JANET_ZIG_FFI_CLASSIFY` |
| `-Dffi-core=c` | `ffi_core.zig`, `ffi_types.zig`, `ffi_marshal.zig`, `ffi_call.zig` | `core/ffi.c` | `JANET_ZIG_FFI_CORE` |
| `-Dfilewatch-flags=c` | `filewatch_flags.zig` | `core/filewatch.c` | `JANET_ZIG_FILEWATCH_FLAGS` |
| `-Dfilewatch-core=c` | `filewatch_core.zig` | `core/filewatch.c` | `JANET_ZIG_FILEWATCH_CORE` |
| `-Dvm-state=c` | `vm_state.zig` | `core/state.c`, `core/capi.c` | `JANET_ZIG_VM_STATE` |
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
| `-Dabstract-core=c` | `abstract_core.zig` | `core/abstract.c`, `core/capi.c` | `JANET_ZIG_ABSTRACT_CORE` |
| `-Dvalue-alloc=c` | `value_alloc.zig` | `core/fiber.c`, `core/bytecode.c`, `core/capi.c` | `JANET_ZIG_VALUE_ALLOC` |
| `-Dvalue-wrap=c` | `value_wrap.zig` | `core/wrap.c` | `JANET_ZIG_VALUE_WRAP` |
| `-Dvm-calls=c` | `vm_calls.zig` | `core/vm.c` | `JANET_ZIG_VM_CALLS` |
| `-Dvm-run=c` | `vm_run.zig` | `core/vm.c` | `JANET_ZIG_VM_RUN` |
| `-Dvm-entry=c` | `vm_entry.zig` | `core/vm.c` | `JANET_ZIG_VM_ENTRY` |
| `-Dvm-lifecycle=c` | `vm_lifecycle.zig` | `core/vm.c` | `JANET_ZIG_VM_LIFECYCLE` |
| `-Ddebug-frames=c` | `debug_frames.zig` | `core/debug.c` | `JANET_ZIG_DEBUG_FRAMES` |
| `-Dpp=c` | `pp_describe.zig`, `pp_pretty.zig`, `pp_format.zig` | `core/pp.c` | `JANET_ZIG_PP` |
| `-Dmarsh=c` | `marsh.zig` | `core/marsh.c` | `JANET_ZIG_MARSH` |
| `-Dpeg-engine=c` | `peg.zig` | `core/peg.c` | `JANET_ZIG_PEG_ENGINE` |
| `-Dcore-env=c` | `core_env.zig` | `core/corelib.c`, `core/run.c` | `JANET_ZIG_CORE_ENV` |

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
the selectors and their contracts exist whenever `-Dffi` is left on;
`-Dffi-core` follows the same condition. None of the three follows the
*architecture* gates inside `ffi.c`: all three calling conventions are
classified, allocated and *called* on every target and only their use is
gated, which is discussed below. `-Dfilewatch-flags` follows both `JANET_EV` and
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
mechanism split across `vm.c` and `capi.c`; its guard leaves the `longjmp`, `janet_check_can_resume`, and the whole of
`janet_continue_no_check` in C in both configurations, and since Phase 10 Part 5
it takes the public raise perimeter — `janet_signalv`, `janet_panicv`,
`janet_panic` and `janet_panics` — as well. `janet_panicf` stays in C in both,
being variadic. `-Dtrace-frames` guards
only the decoding: `janet_stacktrace_ext` itself is compiled once and prints
through either implementation. `-Dargs-core` is ungated as well, and spans two
C files for the same reason `-Dsignal-core` does: the numeric predicates and the
view constructors in `util.c` and the getters in `capi.c` are one layer split
across two files. Since Phase 10 Part 5 its guard leaves nothing behind — every
exported `janet_get*` and `janet_opt*`, `janet_arg_raise` and the three view
constructors moved with the kernels, because a raise may now be on the Zig
side. `-Dgc-alloc` is ungated too — there is no build without a
collector — and it takes the first of three bites out of `gc.c`, leaving
marking, sweeping, `janet_collect` and `janet_clear_memory` in C in both
configurations. `-Dpp` is ungated as well: `pp.c` is
compiled in every configuration and nothing in it is conditional. It covers
three Zig sources, on the same rule `-Dbuffer-array` and `-Dstring-symbol`
follow -- a split is worth its seams when the pieces convert in different
increments, and costs them for nothing when they land together. Its guard
leaves four things in C in both arms — `janet_formatc`, `janet_formatb` and
`janet_formatbv`, which are variadic, and the six `va_arg` accessors the Zig
engine pulls its arguments through. See "The formatter, the printer, and the
last of the varargs" below for why that is a toolchain limit rather than a
seam anyone chose.

`-Dmarsh` is ungated and its guard leaves nothing behind: `marsh.c` is compiled
in every configuration, nothing in it is conditional on a feature flag, and the
Zig object supplies every symbol it used to. What is *inside* it varies with
`JANET_EV`, which decides two lead bytes and renumbers seven more -- see "The
lead bytes renumber without the event loop" below.

`-Dpeg-engine` is the one selector in the table whose name does not match its
subject, and the reason is a collision. `-Dpeg` already exists and is a
*feature* flag: it decides whether PEG support is compiled at all, and
`peg.c` is one `#ifdef JANET_PEG` from its first line to its last. A selector
cannot share the name. `-Dpeg-core` was the other candidate and was rejected
because `core` means something specific here -- `io-core`, `ev-core`,
`asm-core` and `parser-core` all name a kernel with its cfunction surface left
in C -- and this increment moves the surface too.

The feature flag also gates the object rather than only the C body, which is
new: `build.zig` builds `peg.zig` only when `-Dpeg` is on, because `JanetPeg`
and `janet_peg_type` are declared inside `janet.h`'s own `#ifdef JANET_PEG` and
a `-Dpeg=false` build has no types for the Zig file to name. `test/peg.c` is
skipped there for the same reason, the way `test/inttypes.c` is skipped without
integer types. Every other gated selector in the paragraphs above follows a
condition inside the C file; this one follows a condition in the header.

`-Dcore-env` is ungated and its guard leaves nothing behind in either of the two
files it covers: `corelib.c` and `run.c` are compiled in every configuration and
neither has a feature flag around its outer edge. What is *inside* varies a
great deal -- `janet_load_libs` calls a `janet_lib_*` per optional library,
`janet_dobytes` and `janet_loop_fiber` each have an event-loop arm and a
non-event-loop arm, `janet_native` has three dynamic-library vocabularies, and
half of `janet_core_env` exists only in the bootstrap -- and the Zig file reads
those conditions off the translated feature macros rather than having
`build.zig` restate them. Two files under one selector, because Part 4's
consolidation rule asks whether the pieces convert in different increments and
these do not: `corelib.c` builds the core environment and `run.c` is the only
thing in the tree that runs Janet source *in* one.

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
   function there should return `raise.Error` and have a C face beside it
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
> panicking face of two Zig entry points. The diagnostics came too, along with
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

What replaces it is that a converted symbol keeps **two faces**: the C-ABI face
its unported C callers still link against, which catches the error and delivers
it as a jump, and the Zig face that returns the error. Those are each other's
differential for as long as any C caller remains, and the last one disappearing
is what Part 17 means.

### What makes the jump safe while both are live

The claim, demonstrated in `probe-10/bridge/` and not merely asserted: a Zig
error is **fully unwound before any jump happens**. A C face catches in its own
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

### Two faces, and where the `catch` has to be

Each converted function has a C-ABI face beside it, and the faces are generated
rather than written:

```zig
pub const callNonfnPanicking = raise.panicking(callNonfn).face;
```

`raise.panicking` is in `raise.zig` rather than here, because this phase applies
the pattern to every exported function that raises, which is most of them. Two
lines each is not much until it is three hundred of them, and a hand-written
face that drifts from the implementation it wraps is a silent ABI change rather
than a compile error.

The `@export` block now exports these faces under the original `janet_*` names,
`janet_mcall` included. A C caller cannot consume a Zig error, so the public
entry is the face and not the implementation.

The position of the `catch` is the entire safety argument and not a style
choice. It is inside the face, one frame below the implementation, so by the
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
vacuous: a parameter's `noalias`, and variadics, which have no face at all.

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
`raise.Error!JanetSignal`, and `janet_run_vm` is `raise.panicking(runVm).face`.
Ninety-three `try` sites.

Much less of this was new than the file's size suggests. `run_vm` **already had**
an error-returning shape under `-Dcall-trampoline=true`, where a raise sets the
return register and the fiber flag and returns the signal rather than jumping;
Phase 9 built it, kept it in the acceptance matrix, and it has been passing ever
since. What changed is the carrier, not the structure, and the comment on
`vm_raise_signal` about which sites commit and which do not was already written
for a raise that returns.

`vm_entry.zig` has exactly two functions that raise — `janet_step` and
`janet_call` — and both are `JANET_API`, so the exported names became faces and
the implementations are reached only from Zig. `janet_continue`,
`janet_continue_signal`, `janet_pcall` and `janet_check_can_resume` need no face
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
`janet_call` swallowing a non-OK signal from the loop, and a face returning a
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
jump underneath it needed no bridge, no C face, and changed nothing a caller can
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
functions, two `#define`s, a panicking face on the JDN seam, eight build
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
three selectors that forced `janet_zig_pp_jdn_impl` to be a panicking face — an
error union cannot cross the C ABI, so `%j` refusing a value meant a `longjmp`
through the formatter's own frames. **Folding the three layers under one
selector is what removes that.** `pp_format.zig` now `try`s `pretty.jdnImpl`,
the error propagates as an error, and the only jump left in this subsystem is
the one a C caller asks for at the perimeter.

The files still carry the `//! jump-transparent` marker, because
`raise.panicf` renders its own message through `janet_formatc` — the C face of
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

### There is no separate Zig face to test yet, and that is worth saying

This phase's first acceptance check is that a converted symbol's C face and Zig
face are tested separately, because the C one is the one that disappears and so
the one that rots. It does not bite here, and the reason is not that the check
was skipped.

Every symbol this increment exports is a C face: `janet_formatbv`,
`janet_buffer_format`, `janet_pretty`, `janet_jdn`, `janet_to_string_b` and
their kin are what C callers link against. The error-returning implementations
behind them — `formatbv`, `bufferFormat`, `jdnImpl` — are reached only from
inside the one object the three layers fold into. `jdnImpl` does now have a
Zig caller, `pp_format.zig`, which is what folding bought; it has no *second*
face, because `janet_jdn` is the C face and there is nothing else to be
differential against. The three contract files drive the C faces, which is the
whole of what exists.

The second face appears when a Zig *caller* converts. `raise.panicf` is the
obvious first one: it builds its message through `janet_formatc` today, which is
this engine's C face reached through the C variadic ABI, and a converted
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

`raise.panicking(f).face` builds a C face by catching an error union and
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

which makes the face read as what it is:

```zig
export fn janet_panicv(message: c.Janet) callconv(.c) noreturn {
    raise.deliver(raise.panicv(message));
}
```

The parameter is unused by construction — everything the jump needs was written
into `janet_vm` by the raise before it returned — and the point is that the
error is *passed* rather than discarded, so the face cannot drift into calling
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
C-ABI face beside it for as long as C callers remain. That is what "the C face
and the Zig face are each other's differential" means here, and it is why the
existing contract is worth what it is: every `janet_opt*` case in
`test/args_core.c` drives the Zig face of the getter beneath it and the C face
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

### There is a Zig face now, and the existing contract already drives it

Part 4 recorded that its subsystem had no separate Zig face to test, because
nothing in Zig called it. That is no longer true one layer down, and the
coverage came free. `janet_optnumber` is a Zig function that calls the Zig
`GetNumber.get` and returns what it returns; `janet_getcstring` reaches
`getCBytes` and then `getBytes`; `janet_getflags` goes through
`GetKeyword.get`; `janet_getslice` goes through `startRange`, `endRange` and
`halfRange`. Each of those is an error crossing a Zig frame rather than a jump
leaving one, and `test/args_core.c` drives all of them — thirty-two `janet_opt*`
calls and thirty-one through the four composite getters — while asking only
about the C face it called.

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
Phase 10's first decision retires that, and the pair are now the panicking face
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
The traversal now returns errors, so `janet_marshal`'s face could free before
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
the family has an error channel. Each is therefore a `raise.panicking` face
over an error-returning body, and the jump it delivers unwinds the Zig
traversal frames underneath it exactly as it did when they were C frames.

Eight of the twenty need no face at all, because nothing in them decides to
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
and delivers it in a two-line C face, which is the shape Part 9 settled.
Twelve of the thirty-six are written that way. The other twenty-four make no
such decision — `(describe x)` cannot fail on its own account — and are written
as the plain `JanetCFunction` they are. Giving those an error union they never
return would be ceremony rather than shape, and the file says so rather than
being uniform for its own sake.

`(signal what x)` is the one place where the mechanism is visible from Janet.
The C original called `janet_signalv`, which records the decision and then
jumps; the port `return`s `raise.signal(...)`, and the cfunction's C face turns
that back into the jump its caller is waiting for. Nothing else changes, because
`janet_zig_signal_record` is shared between the two deliveries — which is what
Part 2 built it for.

`core_env.zig` is nevertheless **jump-transparent**, and will be for the rest of
the phase. `janet_arity`, `janet_getstring` and their thirty relatives are
`-Dargs-core`'s C faces, `janet_panic_type` is another, and a call to one from
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
two-line C face:

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
relatives, which are `-Dargs-core`'s C faces; `janet_buffer_format`, which is
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
an `Impl` returning `raise.Raising(Janet)` behind a two-line C face. The other
two are `flush` and `eflush`, which cannot fail at all — `janet_flusher`'s
three arms are "flush it", "flush the default handle", and "do nothing" — and
giving them an error union they never return would be ceremony rather than
shape.

Twenty faces is not twenty pieces of boilerplate. The sixteen members of the
print families are generated from four comptime specialisations, so each face
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
own `const FILE = opaque {}`, every extern and every public face speaks
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
acceptance list asks for — "the C face and the Zig face of a converted symbol
are tested separately", and here the C face is a whole function that stayed
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
two faces separately.

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
about testing the two faces separately, applied to eight seams at once: the C
face is the one that disappears, so it is the one that rots.

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
  - **The C face of every symbol this increment converted.** While both
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
behaviour rather than about Zig and so outlive the C faces Part 17 deletes.

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

**Phase 10's two-faces check is vacuous here and the contract says so.** This
increment converts no raise-capable *exported* symbol: every one of `net.c`'s
raises is inside a cfunction, and a cfunction is a C face already.

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
configuration nothing else builds, and it is the C face Phase 10's acceptance
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

**Phase 10's two-faces check is vacuous for this increment**, as it was for
Part 14, and the contract says so: every raise here is inside a cfunction, and
a cfunction is a C face already. `Face(...).cfun` catches the error and calls
`raise.deliverToC()`, so calling the registered cfunction pointer -- which is
what `call_core` does -- is the C face, and there is no second one to drift
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

**Phase 10's two-faces check is vacuous for this increment**, as it was for
Parts 14 and 15: every raise is inside a cfunction and a cfunction is a C face
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
the two-faces pattern, the `_extern.zig` shims.

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

### Both faces, and a hole that predated the change

Phase 10's acceptance list says the C face and the Zig face of a converted
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

The Zig face needed a different route, because it is reachable only through
`run_vm`. `JOP_PUSH_ARRAY` is the one push whose count comes from a value
rather than from the instruction, so an array claiming `INT32_MAX` elements
drives `pushn` past its bound from inside the loop. Nothing dereferences the
claim — `janet_indexed_view` copies the pointer and the count, and `pushn`
checks the count first — but the collector would, so the array exists only
inside a `janet_gclock`, and the lock is released by `janet_restore` on the
unwind exactly as `janet_call`'s is. What that observes and the C-face test
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
faces — a `raise.Raising(T)` implementation and a `raise.panicking` wrapper
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
C-ABI function that now raises into an `Impl` and a face, then follow the error
union outward by reading `zig build`'s own diagnostics. It is a working file
rather than a scratch script because Parts 17c, 17d and 17e do the same job to
different layers, and its header records the three ways it gets things wrong.

The result: 656 call sites converted, **zero** argument-layer crossings left,
and 232 C-ABI faces where there were 83.

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
rejected because the C face returns plain `void`.

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

### Both faces, and why no new contract

Phase 10's acceptance list wants the C face and the Zig face of a converted
symbol tested separately, and this is the increment where that check is met
without a line of new test code — which is worth stating rather than leaving
the reader to wonder, as the phase's sixth rule asks.

Nothing about the *exported* symbols changed here. `janet_getstring` and its
sixty relatives are still `raise.panicking(get).face`, still exported under the
same names, and `test/args_core.c` still drives every one of them through
`EXPECT_PANIC` — seventy panics asserted by message. That is the C face, and it
is the face that disappears in Part 17f, so it is the one that rots.

What changed is who calls the *implementation*. Before this part nothing did
outside `args_core.zig`; now every cfunction in the runtime does, which means
the Zig face is exercised by every Janet suite in the tree — 4,813 assertions
across forty-one suites, reaching it two or three times per cfunction call. The two faces are
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

17b had it easy and did not look it. The argument layer had carried two faces
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
  - **Two guards on the splitter.** It must not split a `noreturn` face, and it
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
most of what it found was a subsystem raising through the C face **when it
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
Zig returns except the 145 public C faces, and Phase 7's trampoline is gone.

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
capture — and **zero** call a face directly. All three go through
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
tail changed nothing, so it is not struct layout. Rebuilding with the 193 faces
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
cfunction pointer ... and **zero** call a face directly."

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
same Impl-plus-face shape `math.zig` and `ev_loop.zig` already had.

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

### 203 faces, deleted rather than converted

The tree held **203** declarations wearing `align(corefn.alignment)
callconv(.c) c.Janet` and now holds none. 196 of them were this:

```zig
fn cfunArrayNew(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) callconv(.c) c.Janet {
    return cfunArrayNewImpl(argc, argv) catch raise.raised(c.Janet);
}
```

There is nothing to convert: the implementation *is* the cfunction, so the face
is deleted and the `Impl` suffix comes off. Ten generators went the same way —
`Face(impl).cfun` in seven subsystems and `face(impl)` in `fiber_core.zig` and
`asm_core.zig`, both of which Part 17f had written three weeks' worth of
increments after the comment saying they were "not shared because the objects
share no module" stopped being true. Rule 9 again, and this time the answer was
to delete them rather than to share them.

**Seven cfunctions had no face and gained an error union anyway.** Three in
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
declared. Keeping a C-ABI face beside the Zig one was the first plan and it is
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
commit before the type change, so what is measured is the 203 deleted faces and
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
face itself — a builtin was two functions, and at `ReleaseFast` some of those
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
`janet_run_vm` C face: `JOP_RESUME` reaches the hinge by name, the hinge reaches
the loop by name, and `raise.Error` crosses both ways.

### A `noreturn` face is a lie the header tells the caller

Twenty-two exported faces were `JANET_NO_RETURN`: the four `janet_panic*`
entries, `janet_signalv`, the two slot diagnostics, `janet_await`,
`janet_sleep_await`, `janet_async_start`, `janet_ev_threaded_await`, and the
eleven `janet_ev_*` read and write entries by which a fiber suspends. None can
be `noreturn` without a jump — the only way to tell a C caller without
returning *was* the jump — so each became a reporting face over `raise.report`.

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

Eleven call sites in six files could not take an error: a C-ABI face, or an
internal result type whose error channel is a message pointer rather than an
error union. They are rule 11's population — a raise converts as far as the
nearest fixed boundary and stops there — and they go through
`pp_format.formatcReported`, which is `raise.reported` over `formatc`. That is
what the variadic shell already did, since `janet_zig_formatbv` was a panicking
face; what changes is that the site says so. Rule 19 names what retires them,
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
