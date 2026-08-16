# Janet–Zig interoperation rules

The Phase 2 code uses the following rules until the relevant runtime
subsystems move to Zig:

- Janet owns all Janet values and managed allocations. Zig does not reproduce
  the allocator or garbage collector.
- A Janet value held across a call that may allocate must be visible to the
  collector. The interop test uses `janet_gcroot` and `janet_gcunroot`
  explicitly around a forced collection.
- A Janet `setjmp`/`longjmp` signal must never cross an active Zig frame.
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
