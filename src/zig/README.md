# The Zig runtime

Janet's runtime, written in Zig. This file is for someone reading or changing
it: what holds, where things are, and which mistakes the tree is shaped to
prevent.

Three other documents carry the rest. [`../../DESIGN.md`](../../DESIGN.md) has
the decisions about what the language *is* — the value representation, the
module interface, the pointer conventions. [`../../FOUND.md`](../../FOUND.md)
has the defects inherited from Janet and deliberately kept.
[`../../test/README.md`](../../test/README.md) has the test strategy and what a
change owes before it is believed.

## The rules that hold

- **There is no C implementation to select, and no Janet C left to call.**
  `src/zig` is 88 `.zig` files and four hand-written headers: `janet_features.h`
  and the host translations `os/abi.h`, `net/abi.h` and `filewatch/abi.h`. Any
  C a Zig file reaches is libc's, through one of seven `@cImport` blocks. "No C
  in the tree" and "no libc" are different claims and only the first is a goal.
  Comparison against Janet's C runtime is `tools/bench/upstream.sh`, which
  builds upstream `master` in a worktree with a matching toolchain.

- **Nothing jumps.** No configuration compiles a `setjmp`, `longjmp` or
  `jmp_buf`; there is not one in the tree. A raise records its signal in the
  VM's `pending_signal` and returns `error.JanetSignal`. A protected scope is
  `janet_try_init` and `janet_restore` with the call between them —
  `janet_try_init` is what points `return_reg` at the scope's payload and
  therefore what decides a raise has somewhere to go. The `setjmp` was never
  the scope, only the travel. `defer` and `errdefer` are legal everywhere.

- **A raising function returns `raise.Raising(T)`, and each caller decides.**
  Where a caller cannot carry the error union it flattens the raise into a
  report — and a report nobody consumes kills the process at the next protected
  scope, naming neither the cause nor the caller. `tools/check/swallowed.janet`
  polices exactly that, takes four seconds, and is silent on a clean tree.

- **A cfunction is Zig's, not C's.** `raise.CFunction` takes `[]Value` and
  answers `error{JanetSignal}!Value` over Zig's own calling convention, so
  `argv[n]` is bounds-checked where in C it read whatever was there.

- **One file exports, and it is `capi.zig`.** 27 published names: 17 `@export`s
  and 10 `publish(...)` calls. The only other export in `src/zig` is
  `module.zig`'s pair of loader shims, which belongs to a dynamically loaded
  module rather than to the runtime. Everything else a file needs from a
  neighbour it reaches by `@import`, which keeps the error union, allows
  inlining, and is checked.

- **`cabi.zig` is what is genuinely external**: libc and the host — 161
  declarations. `crossings.zig` holds the 27 a separately compiled module
  reaches by name. `cabi_check.zig` compares every one of `crossings.zig`'s
  against the definition it names, on every build, because an `extern fn` is
  otherwise a promise the compiler believes without reading — and an author's
  `.so` is the one compilation where a disagreement is somebody else's crash.

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

## The source tree

The split rule: **a file exists when it has a name Janet publishes — a type, a
cfunction family, a module — or because the platform differs.** Everything else
goes in the bucket its callers already name. One spelling per function; there
is no facade layer, and the file tree and the namespace are the same thing, so
`value/tables.zig`'s `get` is `tables.get` and is not re-exported anywhere.

| directory | files | what is in it |
| --- | --- | --- |
| `src/zig/` | 44 | the roots and the subsystems that have no interior: the parser, the PEG engine, the marshaller, the argument layer, the environment, the pretty printer's entry, `io`, `math`, `scan`, `signal` |
| `src/zig/value/` | 11 | one file per Janet value type — arrays, buffers, strings, symbols, tuples, tables, structs, fibers, functions, abstracts, integer types |
| `src/zig/value/helpers/` | 3 | the operations that are about values in general rather than one type: `wrap`, `access`, `order` |
| `src/zig/vm/` | 3 | `entry.zig` (the interpreter's entry points), `lifecycle.zig` (init and teardown) and `state.zig` (the VM type, its storage and the one accessor) |
| `src/zig/gc/` | 2 | `mark.zig` and `sweep.zig`; the allocator itself is `gc.zig` |
| `src/zig/compiler/` | 4 | `specials`, `emit`, `optimize`, `regalloc` |
| `src/zig/bytecode/` | 2 | `verify.zig` and `disasm.zig` |
| `src/zig/os/`, `os/fs/` | 7 | the host interface, split where the platform differs; `os/abi.zig` is the header translation |
| `src/zig/ev/` | 4 | `backend`, `stream`, `channel`, `locks` |
| `src/zig/net/`, `filewatch/` | 2 | the two host-header translations, `abi.zig` each |
| `src/zig/ffi/` | 4 | `types`, `classify`, `marshal`, `call` |
| `src/zig/pp/` | 2 | `format.zig` and `pretty.zig` |

Eight files at the top are not subsystems and are worth naming:

| file | what it is |
| --- | --- |
| `root.zig` | the module root: a comptime block naming every file this configuration compiles |
| `capi.zig` | the export manifest — every published symbol, and the signature it publishes |
| `cabi.zig` | every `extern` declaration the runtime makes |
| `cabi_check.zig` | the comparison of each of those against its definition |
| `crossings.zig` | the 27 runtime symbols a separately compiled module reaches by name, and the only other file allowed to declare one |
| `host.zig`, `constants.zig`, `repr.zig` | the host's own shapes, the constants, and the value representation, each its own build module |
| `abi.zig` | the declarations a separately compiled module and the runtime must agree on, and nothing else |
| `raise.zig` | the error union, the flattening forms, and the cfunction type |

## The module graph

`build.zig` builds eight modules and the compiler enforces the direction. The
import list of a module is the whole of what it may reach:

```
config  ->  repr  ->  abi, constants;  host  ->  cabi  ->  root
```

- `config` is what the build decided, as comptime values.
- `repr` imports `config` and nothing else. That import list is what makes "the
  representation module does not reach allocation, tables, the VM or the
  collector" a build error rather than a review comment.
- `abi` is what a separately compiled module and the runtime must agree on, and
  nothing else: the abstract-type vtable, the registration and method rows, the
  abstract head and the subtraction that recovers it, the signal numbering, the
  build config, and opaque `Table` and `Buffer` handles. Its import list is
  `repr` alone. **It is the module an author's package gets** —
  `build.zig`'s `janetModule` hands out this one — so the runtime and an
  author's `.so` agree by construction rather than by review.
- `constants` reaches *up* to `repr` for the tag, and imports nothing else.
- `host` is the six shapes the host decides — `FILE`, the descriptor, the three
  pthread types and Windows' critical section. It takes the pthread types from
  libc, because `std.c` carries glibc's `pthread_attr_t` and musl's is a
  different size, which `Vm` embeds. It is a module rather than a file of `root`
  because `cabi` names the same six and a file of `root` cannot be imported by
  `cabi`. Every Janet aggregate lives with the operations over it instead —
  `tables.Table`, `fibers.Fiber`, `functions.FuncDef`, `ev_stream.Stream` —
  which is `DESIGN.md` section 14.
- `cabi` is the external declarations.
- `options` is the `Selection` as comptime booleans, and `root.zig` is its only
  reader.
- `root` is the runtime, and everything else — `raise.zig`, `corefn.zig`, the
  three host-header translations — is a file of it.

The graph is built six times over: once for the runtime, once for the
bootstrap generator on the *host*, once each with `test/contracts.zig` and
`test/fuzz.zig` as the root, once for the module-error fixtures, and once as
`janet-runtime-test` rooted at `root.zig` itself. Each spells the same types and
the same constants the runtime does; a module the runtime has and a test root
does not would be a call-site rewrite that stops at the `src/` boundary.

**A module boundary is not a compile barrier.** `raise.Error` is declared in
the `raise` module and a subsystem writes `raise.Error!Value` across the
import; the compiler sees through a module the way it sees through a file. What
it cannot see through is a *compilation* boundary, where the only thing joining
two objects is a symbol in a symbol table — which means a calling convention,
which means C's, and Zig will not put an error union on one. The runtime is one
compilation for that reason.

## What crosses a boundary

Three things do, and they are checked differently.

**Published symbols.** `capi.zig` holds all 27 of them. 17 are `@export`s of an
entry point declared in that file, so the published signature is written there
and the compiler checks the forwarding call. The other 10 export a target
directly and carry a `publish(symbol, target, Signature)` assertion beside the
`@export` — because an `@export` states no signature at all, and whatever the
target happens to be declared as becomes the ABI.

**Declarations of things outside.** `cabi.zig`'s 161 `extern fn`, and
`crossings.zig`'s 27 — the module side of the same boundary, which `raise.zig`
and `module.zig` call. `tools/check/seam.janet --check` fails if an
`extern fn janet*` appears anywhere else. `cabi_check.zig` compares each of
`crossings.zig`'s 27 and the twelve libc-side pairs against the definition it
names, by exact type equality — not compatibility, with one declared exception:
`abi.Table` and `abi.Buffer` are opaque handles standing for `tables.Table` and
`buffers.Buffer`, and only the pointee is substituted. The comparison has found
a `noreturn` declared against a `void` definition, a missing sentinel, four lost
nullabilities and a method row declared as the wrong one of two layouts, none of
which any test could reach.

**Host structures.** `os/abi.h`, `net/abi.h` and `filewatch/abi.h`, each
opening with `janet_features.h`, each keeping what it declares inside one
subsystem. They exist because the answer depends on the host's headers and
cannot be written in Zig without guessing. **After changing one, clear
`.zig-cache` before trusting the result** — Zig may otherwise reuse an object
built against the old imported layout and produce a silent offset mismatch.

## Raising

`raise.Raising(T)` is `error{JanetSignal}!T`. A caller that can carry it writes
`try`; a caller that cannot flattens it, and there are four spellings:

| form | what it does |
| --- | --- |
| `raise.reported(result)` | turn a raise into the out-of-band report |
| `raise.report(Error)` | report without a result |
| `reportToC` | the same, at a `callconv(.c)` boundary |
| `raise.panicking(f).abi` | wrap a raising function as a C-ABI one |

`raise.total(result, site)` is not one of these. It is a **fatal abort** —
`janet_zig_fatal` — for a raise that cannot happen and would leave the runtime
inconsistent if it did.

A report that nobody consumes is the failure this design has: the process dies
at the next protected scope naming neither cause nor caller. Every raising
function that reaches a raise through an abi is therefore listed by
`tools/check/swallowed.janet`, which is silent on a clean tree and takes four
seconds. Run it per increment.

## Configuration, and what "unchecked" means

`build.zig` derives two things from the `-D` options: `Config`, the comptime
facts a file reads as `config.<name>`, and `Selection`, the per-file booleans
`root.zig` gates on as `options.<name>`. Both come from one expression per
fact, so a file cannot be compiled in one and left out of the other.

**A comptime-false branch is never analysed.** That is what makes `if (has_ev)
ev.x()` safe in a build with no event loop, and it is also why an arm the host
does not select receives no type checking at all. A change to a platform arm is
unchecked until something builds it:

```sh
zig build -Dtarget=x86_64-linux-musl --cache-dir /tmp/xc -p /tmp/out
```

`tools/check/gates.janet --check` builds thirteen configurations and compares
their symbol tables against `tools/check/gated.txt`. It exists because the
question cannot be *read*: `root.zig`'s comptime block does not name every file
it compiles, and its `pub const` block is lazy and compiles nothing.

**That laziness is also what decides whether a `test` block runs.** A `test` in
a file the comptime block names is compiled into `janet-runtime-test`; one in a
file reached only through the `pub const` block, or only through another file's
container-level `const`, is not collected. `os/fs/stat.zig` is named there for
that reason and no other.

## Build steps

| step | what it runs |
| --- | --- |
| `zig build` | the static and shared libraries, the client, the contract driver, the fuzz artifact |
| `zig build test` | the contracts, the in-file `test` blocks, the fuzz targets over their corpora, the module-error fixtures, the CLI checks and the 35 Janet suites |
| `zig build zig-contract-test` | the 65 contracts, which live in a second compilation of the runtime |
| `zig build subsystem-test` | the same thing under an older name |
| `zig build runtime-test` | the in-file `test` blocks, rooted at `root.zig`; it prints `All N tests passed.` |
| `zig build fuzz` | each fuzz target once over its corpus — add `--fuzz` for the campaign |
| `zig build image` | the core image, written to `<prefix>/janet-image.bin` |
| `zig build run` | the client |

No header is installed. What a native module reaches by symbol is `capi.zig`,
and nothing else describes it.

The contract driver is installed unconditionally and takes one contract name,
or none for all 65 in a single process — which is the only thing in the tree
that initialises and tears the runtime down 65 times in a row, and the only
instrument that catches an edit through a contract you were not thinking about.
**Run it with no argument before believing an increment.**

`build.zig` also refuses to build on two hygiene failures: a `test/*.zig` that
`test/contracts.zig` does not list and `checkContractsListed`'s `exempt` does
not name, and a file-scope `const` that its own file never uses.

## Adding things

**A subsystem.** Write `src/zig/<name>.zig`, or a file under the directory its
family already has. Add a `Selection` field, answer it in `zigSelection` gated
on whatever feature flags it depends on, and name it in `root.zig`'s comptime
block under that field. A subsystem reached only through another one is imported
by that file instead and does not appear in the root — but if it carries `test`
blocks it has to be named there anyway, for the reason above. If it publishes a
symbol, that goes in `capi.zig` and nowhere else.

**A contract.** `test/<name>.zig` with `pub fn run() void`, listed in
`test/contracts.zig` under the same `options` condition `build.zig` applies to
its subject — so a contract exists exactly when its subject does, and the two
cannot drift. The build fails until it is listed.

**A contract's oracle must be independently derived.** A test written against
the new code and only ever run against it proves the code matches itself. For
anything numeric or with a large input space, add a differential corpus.

**An export.** Declare the entry point in `capi.zig` with the signature you
intend to publish and `@export` it there. If you export a target directly,
state its signature with `publishes(...)` under the same gate — an `@export`
without one publishes whatever the target happened to be.

## Reduced builds

`zig build test` passes with each feature flag turned off individually:
`-Dint-types=false`, `-Dassembler=false`, `-Dpeg=false`, `-Dnet=false`,
`-Dev=false`, `-Dprocesses=false`, `-Dfilewatch=false`, `-Dffi=false`,
`-Ddocstrings=false`, `-Dsourcemaps=false`, `-Dumask=false`,
`-Drealpath=false`, `-Dcryptorand=false` and `-Ddynamic-modules=false`.

Two different mechanisms guard a suite, and choosing the wrong one fails
quietly.

A binding the build omits entirely is a *compile* error at its use site, not a
nil value at run time, so `(when-let [x maybe/missing] ...)` cannot guard one.
Those need `compwhen`, which decides at compile time.

A binding that still exists but raises when called needs the opposite: an
ordinary runtime `when`. `os/realpath`, `os/cryptorand` and `ffi/native` are
registered whatever the build options say, and only their bodies fail, so
`compwhen (dyn 'os/realpath)` sees a live binding and compiles the code anyway.

**Prefer guarding regions to skipping a suite.** An unrun suite reports `0 of
0` and looks just like a passing one. `suite-ev.janet` guards its network and
subprocess regions separately, so its channel, fiber and deadline tests still
run in both reduced configurations. Where a whole suite really does depend on
the feature it leaves early, immediately after `start-suite`, with `(compwhen
(not (dyn 'some/binding)) (end-suite) (os/exit 0))` — which works because Janet
compiles and runs a file one top-level form at a time.

`-Dreduced-os=true` is a **known gap** and is deliberately not guarded. It
leaves only `os/exit`, `os/which`, `os/arch`, `os/compiler` and `os/isatty`,
which breaks `test/helper.janet` itself, so every suite fails before reaching
its own code. Guarding it would mean skipping `suite-os` wholesale along with
much of `suite-ev` and `suite-bundle` — a run that passes while testing
substantially less than it appears to. Revisit only with a plan for what the
suites should still assert.

## Cross-platform constraints

Invisible when building only for the development host:

- **The runtime object is position independent.** It is linked into the shared
  library as well as the static one, and ELF shared objects require PIC.
  `makeRuntimeGraph` sets `.pic = true`. Mach-O is always position independent,
  so omitting it fails only on Linux — with tens of thousands of relocation
  errors, not an obvious diagnostic.

- **The bootstrap pins a baseline CPU.** `boot_host` keeps the host's
  architecture, OS and ABI but sets `cpu_model = .baseline`. Native detection
  would make image generation depend on the build machine, and an emulated or
  unusual host can report a model the code generator rejects. It is also why
  cross-compiling works at all: the generator has to run here.

- **`-Dinstall-tests=true`** installs the contract, fuzz and runtime test
  executables and the native module into `<prefix>/test`, which is how a
  cross-compiled build gets tested:
  `zig build test` runs what it builds, and cannot when the target is not the
  host.

Two limitations are worth knowing before trusting a result. Zig links musl
targets statically, and musl's static `dlopen` is a stub that always fails, so
the native-module test cannot run that way. And emulated x86-64 cannot run a
NaN-boxed build, because Janet packs pointers into doubles and QEMU does not
honour the address-space assumption that relies on — use `-Dnanbox=false`
there, and treat NaN-boxed x86-64 as untested until it runs on real hardware.

## Where the history went

This file was 17,772 lines until 2026-08-31: a record of the migration, written
increment by increment, over 101 sections of which its own preamble said 97
cited a working document that does not survive it. It described build options
no build offers, directories that hold nothing, and a public header that was
deleted.

The reasoning worth keeping is above, re-derived from the tree rather than
copied forward. The narrative is in Git.
