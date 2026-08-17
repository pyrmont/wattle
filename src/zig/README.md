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
