# The Zig runtime

Janet's runtime, written in Zig. This file is for someone reading or changing
it: what holds, where things are, and which mistakes the tree is shaped to
prevent.

Two other documents have the rest. [`../DESIGN.md`](../DESIGN.md) has the
decisions about what the language is: the value representation, the module
interface, and the pointer conventions.
[`../test/README.md`](../test/README.md) has the test strategy and what a change
owes before it is believed.

## The rules that hold

- There is no C implementation to select, and no Janet C left to call. `src/` is
  88 `.zig` files and four hand-written headers: `host/janet_features.h` and the
  host translations `runtime/os/abi.h`, `runtime/net/abi.h` and
  `runtime/filewatch/abi.h`. Any C a Zig file reaches is libc's, through one of
  seven `@cImport` blocks. "No C in the tree" and "no libc" are different
  claims, and only "no C in the tree" is a goal. Comparison against Janet's C
  runtime is `tools/bench/upstream.sh`, which builds upstream `master` in a
  worktree with a matching toolchain.

- Nothing jumps. No configuration compiles a `setjmp`, `longjmp` or `jmp_buf`,
  and the tree contains none of the three. A raise records its signal in `Vm`'s
  `pending_signal` and returns `error.JanetSignal`. A protected scope is
  `signal.tryInit` and `signal.restore` with the call between them.
  `signal.tryInit` is what points `return_reg` at the scope's payload and
  therefore what makes a raise catchable. The `setjmp` was never the scope, only
  the transfer. `defer` and `errdefer` are legal everywhere.

- A raising function returns `raise.Error!T`, and each caller either
  propagates it or flattens it. Where a caller cannot pass the error union on it
  flattens the raise into a report, and a report nobody consumes ends the
  process at the next protected scope, naming neither the cause nor the caller.
  `tools/check/swallowed.janet` checks that, takes four seconds, and is silent
  on a clean tree.

- A cfunction is Zig's rather than C's. `raise.CFunction` takes `[]Value` and
  returns `error{JanetSignal}!Value` over Zig's own calling convention, so
  `argv[n]` is bounds-checked where in C it read whatever was there.

- Nothing in `src/` exports a `janet_*` symbol. `runtime/capi.zig` has the 85
  definitions a native module can reach and `api/interface.zig` declares the
  `extern struct` of function pointers that reaches them. `runtime/capi.zig`'s
  one initializer fills it, and the compiler type-checks every field against the
  definition it names. The only exports left in `src/` are `module.zig`'s pair
  of loader shims, which belong to a dynamically loaded module rather than to
  the runtime. Everything else a file needs from a neighbour it reaches by
  `@import`, which keeps the error union, allows inlining, and is checked.

- `host/cabi.zig` is what is external: libc and the host, in 161 declarations,
  with no Janet name among them. A module that reached the runtime by symbol
  needed a second declaration of every crossing and a check to compare the two.
  A table needs one declaration, and the check is the compiler's.

- Pointers say what is true. `DESIGN.md` section 7 has the conventions and the
  exceptions: no `[*c]` outside the boundary, a counted byte range is a slice, a
  pointer to one object is `*T` or `?*T` where absence is a state the code
  tests, and a C string is `[*:0]const u8` only where the NUL is demonstrably
  read.

- Configuration comes from the build. `build.zig`'s `janetConfig()` is the one
  derivation. A file reads `options.<name>` or `config`, and never reads what it
  was compiled with out of a translation.

- `root.zig` states which files a configuration compiles, and an instrument has
  to be gated the way its subject is. A comptime-false branch is never analysed,
  so an arm a native build does not select is not analysed at all.

## The source tree

A directory says which compilation includes its files, the one structural fact a
directory states here, and it is the question a module author has to be able to
answer: an author's `.so` compiles `api/` and the two roots, and must never
reach the eighty files beside them.

The directory states the boundary; it does not enforce it. Both package roots
sit at `src/`, so a relative import can cross between the directories and
several do by design: `api/raise.zig` names four runtime files for the arm a
module does not take. What enforces the boundary is `tools/check/exports.janet`,
which builds the author package the way an outside author does, and
`examples/standalone`, which consumes this package by path. Making the split
compiler-enforced would mean `api` as a build module with the runtime imported
back into it by name; that is an option and it is not what is here.

| directory | files | compiled by |
| --- | --- | --- |
| `src/api/` | 6 | a native module's `.so` (`janetModule`) and the runtime |
| `src/host/` | 3 + 1 header | the runtime; the platform's shapes and what libc is asked for |
| `src/runtime/` | 77 + 3 headers | the runtime, as one compilation |
| `src/boot/`, `src/client/` | 5 | the image generator; the `janet` and `quickbin` executables |

`src/root.zig` is the runtime's module root above the three directories: it
names every file this configuration compiles and it reaches all three, so it
belongs to none of them. `src/module.zig` is the author package's root and sits
beside it for the same reason. Zig bounds a module's relative imports by its
root file's directory, so both sit at `src/` rather than inside a tier.

`src/api/` is what a module author reads: `abstract_type.zig`, `raise.zig`,
`interface.zig`, `abi.zig`, `repr.zig` and `constants.zig`, with
`src/module.zig` above them as the package root. That root is the only name an
author writes, because a module imports `janet` and nothing else. `src/host/` is
`host.zig`, `cabi.zig` and the `janet_features.h` the three translations open
with.

### Inside `src/runtime/`

The split rule: a file exists when it has a name Janet publishes, meaning a
type, a cfunction family or a module, or because the platform differs.
Everything else goes in the bucket its callers already name. There is one
spelling per function. There is no facade layer, and the file tree and the
namespace are the same thing, so `value/tables.zig`'s `get` is `tables.get` and
is not re-exported anywhere.

| directory | files | what is in it |
| --- | --- | --- |
| `runtime/` | 33 | the subsystems that have no interior: the parser, the PEG engine, the marshaller, the argument layer, the environment, the pretty printer's entry, `io`, `math`, `scan`, `signal` |
| `runtime/value/` | 11 | one file per Janet value type: arrays, buffers, strings, symbols, tuples, tables, structs, fibers, functions, abstracts, integer types |
| `runtime/value/helpers/` | 3 | the operations that are about values in general rather than one type: `wrap`, `access`, `order` |
| `runtime/vm/` | 3 | `entry.zig` (the interpreter's entry points), `lifecycle.zig` (init and teardown) and `state.zig` (the `Vm` type, its storage and the one accessor) |
| `runtime/gc/` | 2 | `mark.zig` and `sweep.zig`; the allocator itself is `gc.zig` |
| `runtime/compiler/` | 4 | `specials`, `emit`, `optimize`, `regalloc` |
| `runtime/bytecode/` | 2 | `verify.zig` and `disasm.zig` |
| `runtime/os/`, `os/fs/` | 7 | the host interface, split where the platform differs; `os/abi.zig` is the header translation |
| `runtime/ev/` | 4 | `backend`, `stream`, `channel`, `locks` |
| `runtime/net/`, `filewatch/` | 2 | the two host-header translations, `abi.zig` each |
| `runtime/ffi/` | 4 | `types`, `classify`, `marshal`, `call` |
| `runtime/pp/` | 2 | `format.zig` and `pretty.zig` |

Nine files outside the subsystems are named here:

| file | what it is |
| --- | --- |
| `root.zig` | the module root: a comptime block naming every file this configuration compiles |
| `runtime/capi.zig` | the 85 definitions a native module can call, and the one initializer that fills the table with them |
| `host/cabi.zig` | every `extern` declaration the runtime makes, all of them libc's |
| `api/interface.zig` | the `extern struct` of function pointers a module reaches the runtime through, and the `rt` it is stored in |
| `host/host.zig`, `api/constants.zig`, `api/repr.zig` | the host's own shapes, the constants, and the value representation, each its own build module |
| `api/abi.zig` | the declarations a separately compiled module and the runtime must agree on, and nothing else |
| `api/raise.zig` | the error union, the flattening forms, and the cfunction type |

## The module graph

`build.zig` builds eight modules and the compiler enforces the direction. The
import list of a module is the whole of what it may reach:

```
config  ->  repr  ->  abi, constants;  host  ->  cabi  ->  root
```

- `config` is what the build set, as comptime values.
- `repr` imports `config` and nothing else. That import list is what makes "the
  representation module does not reach allocation, tables, the `Vm` or the
  collector" a build error rather than a review comment.
- `abi` is what a separately compiled module and the runtime must agree on, and
  nothing else: the abstract-type vtable, the registration and method rows, the
  abstract head and the subtraction that recovers it, the signal numbering, the
  build config, and the six capabilities. Its import list is `repr` alone. It is
  the module an author's package gets, and `build.zig`'s `janetModule` returns
  it, so the runtime and an author's `.so` agree by construction rather than by
  review.
- `constants` reaches up to `repr` for the tag, and imports nothing else.
- `host` is the six shapes the host determines: `FILE`, the descriptor, the
  three pthread types and Windows' critical section. It takes the pthread types
  from libc, because `std.c` declares glibc's `pthread_attr_t` and musl's is a
  different size, which `Vm` embeds. It is a module rather than a file of `root`
  because `cabi` names the same six and a file of `root` cannot be imported by
  `cabi`. Every Janet aggregate lives with the operations over it instead,
  giving `tables.Table`, `fibers.Fiber`, `functions.FuncDef` and
  `ev_stream.Stream`, which is `DESIGN.md` section 11.
- `cabi` is the external declarations.
- `options` is the `Selection` as comptime booleans, and `root.zig` is its only
  reader.
- `root` is the runtime, and everything else is a file of it: `api/raise.zig`,
  `runtime/corefn.zig` and the three host-header translations.

The graph is built six times over: once for the runtime, once for the bootstrap
generator on the host, once each with `test/contracts.zig` and `test/fuzz.zig`
as the root, once for the module-error fixtures, and once as
`janet-runtime-test` rooted at `root.zig` itself. A cross build builds it once
more for `zig build quickbin`, on the host under the target's features, for the
client that makes the image. Each spells the same types and
the same constants the runtime does; a module the runtime has and a test root
does not would be a call-site rewrite that stops at the `src/` boundary.

A module boundary is not a compile barrier. `raise.Error` is declared in the
`raise` module and a subsystem writes `raise.Error!Value` across the import; the
compiler sees through a module the way it sees through a file. What it cannot
see through is a compilation boundary, where the only thing joining two objects
is a symbol in a symbol table. That means a calling convention, which means C's,
and Zig will not put an error union on a C calling convention. The runtime is
one compilation for that reason.

## What crosses a boundary

Three things do, and they are checked differently.

### The module table

`api/interface.zig`'s `Runtime` is one `extern struct` of 85 `callconv(.c)`
function pointers, and both compilations import that file. `runtime/capi.zig`'s
`table` fills it from the runtime's definitions and `runtime/env.zig` passes its
address to `_janet_init`; `module.zig`'s shim stores it in `table.rt` and every
crossing an author makes is a call through that pointer. There is one
description of each crossing rather than two, so the compiler checks it at the
initializer and nothing has to be compared afterwards. A `size` field is
`@sizeOf(Runtime)` and the shim refuses a mismatch before any author code runs.

The three definitions that were typed on a runtime aggregate, being `cfuns_ext`,
`def` and `buffer_push_bytes`, now take `abi.Env` and `abi.Render` and cast on
their own first line, the way `runtime/marsh.zig`'s entry points already took
`abi.Marshal`. So every field's type and its definition's type are the same
type, and no substitution table stands between them.

### Declarations of things outside

`host/cabi.zig`'s 161 `extern fn`, all libc's. `tools/check/seam.janet --check`
fails if an `extern fn janet*` appears anywhere in `src/` at all: the runtime
publishes no such name for a declaration to resolve to.

### Host structures

`os/abi.h`, `net/abi.h` and `filewatch/abi.h`, each opening with
`janet_features.h`, each keeping what it declares inside one subsystem. They
exist because what they declare depends on the host's headers and cannot be
written in Zig without guessing. After changing a header, clear `.zig-cache`
before trusting the result. Zig may otherwise reuse an object built against the
old imported layout and produce a silent offset mismatch.

## Raising

`raise.Error!T` is `error{JanetSignal}!T`. A caller that can propagate it
writes `try`; a caller that cannot flattens it, and there are four spellings:

| form | what it does |
| --- | --- |
| `raise.toAbi(result)` | the value the call produced, or a determinate zero if it raised |
| `raise.report(Error)` | report without a result |
| `reportToAbi` | the same, at a `callconv(.c)` boundary |
| `raise.panicking(f).abi` | wrap a raising function as a C-ABI function |

`raise.total(result, site)` is not among those four spellings. It is a fatal
abort, `janet_zig_fatal`, for a raise that cannot happen and would leave the
runtime inconsistent if it did.

A report that nobody consumes is the failure this design has: the process dies
at the next protected scope naming neither cause nor caller. Every raising
function that reaches a raise through an abi is therefore listed by
`tools/check/swallowed.janet`, which is silent on a clean tree and takes four
seconds. Run it per increment.

## Configuration, and what "unchecked" means

`build.zig` derives two things from the `-D` options: `Config`, the comptime
facts a file reads as `config.<name>`, and `Selection`, the per-file booleans
`root.zig` gates on as `options.<name>`. Both come from one expression per fact,
so a file cannot be compiled under `Config` and left out of `Selection`.

A comptime-false branch is never analysed, so `if (has_ev) ev.x()` is safe in a
build with no event loop and an arm the host does not select receives no type
checking at all. A change to a platform arm is unchecked until something builds
it:

```sh
zig build -Dtarget=x86_64-linux-musl --cache-dir /tmp/xc -p /tmp/out
```

`tools/check/gates.janet --check` builds thirteen configurations and compares
their symbol tables against `tools/check/gated.txt`. It exists because the
question cannot be settled by reading: `root.zig`'s comptime block does not name
every file it compiles, and its `pub const` block is lazy and compiles nothing.

That laziness is also what controls whether a `test` block runs. A `test` in a
file the comptime block names is compiled into `janet-runtime-test`; a `test` in
a file reached only through the `pub const` block, or only through another
file's container-level `const`, is not collected. `os/fs/stat.zig` is named
there for that reason and no other.

## Build steps

| step | what it runs |
| --- | --- |
| `zig build` | the static and shared libraries, the client, the contract driver, the fuzz artifact |
| `zig build test` | the contracts, the in-file `test` blocks, the fuzz targets over their corpora, the module-error fixtures, the CLI checks and the 34 Janet suites |
| `zig build zig-contract-test` | the 65 contracts, which live in a second compilation of the runtime |
| `zig build subsystem-test` | the same thing under an older name |
| `zig build runtime-test` | the in-file `test` blocks, rooted at `root.zig`; it prints `All N tests passed.` |
| `zig build fuzz` | each fuzz target once over its corpus. Add `--fuzz` for the campaign |
| `zig build image` | the core image, written to `<prefix>/janet-image.bin` |
| `zig build run` | the client |
| `zig build quickbin` | `examples/quickbin/main.janet` with `examples/digest` linked in, as `<prefix>/bin/quickbin`; `zig build test` runs it on a native build |

No header is installed and no `janet_*` symbol is exported. What a native module
reaches is `api/interface.zig`'s struct, and nothing else describes it.

The contract driver is installed unconditionally and takes one contract name, or
no name for all 65 in a single process. Running it with no name is the only
thing in the tree that initialises and tears the runtime down 65 times in a row,
and the only instrument that catches an edit through a contract the author was
not thinking about. Run it with no argument before believing an increment.

`build.zig` also refuses to build on two hygiene failures: a `test/*.zig` that
`test/contracts.zig` does not list and `checkContractsListed`'s `exempt` does
not name, and a file-scope `const` that its own file never uses.

## Adding things

### A subsystem

Write `src/runtime/<name>.zig`, or a file under the directory its family already
has. Add a `Selection` field, set it in `zigSelection` gated on whatever feature
flags it depends on, and name it in `root.zig`'s comptime block under that
field. A subsystem reached only through another subsystem is imported by that
file instead and does not appear in the root, but if it has `test` blocks it has
to be named there anyway, for the reason above. If it publishes a crossing a
native module can make, that goes in `runtime/capi.zig` and `api/interface.zig`
and nowhere else.

### A contract

`test/<name>.zig` with `pub fn run() void`, listed in `test/contracts.zig` under
the same `options` condition `build.zig` applies to its subject, so a contract
exists exactly when its subject does, and the two cannot drift. The build fails
until it is listed.

### A contract's oracle

A contract's oracle must be independently derived. A test written against the
new code and only ever run against it proves the code matches itself. For
anything numeric or with a large input space, add a differential corpus.

### A crossing

Add the field to `api/interface.zig`'s `Runtime` with the exact signature,
append it rather than inserting it, and fill it in `runtime/capi.zig`'s `table`,
either with an entry point declared in that file or with a subsystem's own C-ABI
shim. The compiler checks the two agree, so there is nothing else to state. Then
give `module.zig` the author-side wrapper.

## Reduced builds

`zig build test` passes with each feature flag turned off individually:
`-Dint-types=false`, `-Dassembler=false`, `-Dpeg=false`, `-Dnet=false`,
`-Dev=false`, `-Dprocesses=false`, `-Dfilewatch=false`, `-Dffi=false`,
`-Ddocstrings=false`, `-Dsourcemaps=false`, `-Dumask=false`, `-Drealpath=false`,
`-Dcryptorand=false` and `-Ddynamic-modules=false`.

Two different mechanisms guard a suite, and choosing the wrong mechanism fails
quietly.

A binding the build omits entirely is a compile error at its use site rather
than a nil value at run time, so `(when-let [x maybe/missing] ...)` cannot guard
it. Those need `compwhen`, which resolves at compile time.

A binding that still exists but raises when called needs an ordinary runtime
`when` instead. `os/realpath`, `os/cryptorand` and `ffi/native` are registered
whatever the build options say, and only their bodies fail, so `compwhen (dyn
'os/realpath)` sees a live binding and compiles the code anyway.

Prefer guarding regions to skipping a suite. An unrun suite reports `0 of 0` and
is indistinguishable from a passing suite. `suite-ev.janet` guards its network
and subprocess regions separately, so its channel, fiber and deadline tests
still run in both reduced configurations. Where a whole suite does depend on the
feature it leaves early, immediately after `start-suite`, with `(compwhen (not
(dyn 'some/binding)) (end-suite) (os/exit 0))`. That works because Janet
compiles and runs a file one top-level form at a time.

`-Dreduced-os=true` is a known gap and is deliberately not guarded. It leaves
only `os/exit`, `os/which`, `os/arch` and `os/compiler`, which breaks
`test/helper.janet` itself, so every suite fails before reaching its own code.
Guarding it would mean skipping `suite-os` wholesale along with much of
`suite-ev` and `suite-bundle`, giving a run that passes while testing
substantially less than it appears to. Revisit only with a plan for what the
suites should still assert.

## Cross-platform constraints

Invisible when building only for the development host:

- The runtime object is position independent. It is linked into the shared
  library as well as into the static library, and ELF shared objects require
  PIC. `makeRuntimeGraph` sets `.pic = true`. Mach-O is always position
  independent, so omitting it fails only on Linux, with tens of thousands of
  relocation errors that do not name the cause.

- The bootstrap pins a baseline CPU. `boot_host` keeps the host's architecture,
  OS and ABI but sets `cpu_model = .baseline`. Native detection would make image
  generation depend on the build machine, and an emulated or unusual host can
  report a model the code generator rejects. It is also why cross-compiling
  works at all: the generator has to run here.

- `-Dinstall-tests=true` adds the runtime-test executable and the native-module
  and module-load fixtures to `<prefix>/test`, beside the contract and fuzz
  drivers every non-wasm build installs there. That is how a cross-compiled
  build gets tested: `zig build test` runs what it builds, and cannot when the
  target is not the host.

Two limitations qualify any result. Zig links musl targets statically, and
musl's static `dlopen` is a stub that always fails, so the native-module test
cannot run that way. And emulated x86-64 cannot run a NaN-boxed build, because
Janet packs pointers into doubles and QEMU does not honour the address-space
assumption that relies on. Use `-Dnanbox=false` there, and treat NaN-boxed
x86-64 as untested until it runs on real hardware.

## Where the history went

This file was 17,772 lines until 2026-08-31: a record of the migration, written
increment by increment, over 101 sections of which its own preamble said 97
cited a working document that does not survive it. It described build options no
build offers, directories that contain nothing, and a public header that was
deleted.

The reasoning kept is above, re-derived from the tree rather than copied
forward. The narrative is in Git.
