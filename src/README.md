# The Zig runtime

Wattle's runtime, written in Zig. This file is for a reader who is reading or
changing the runtime: where things are, the rules the tree follows, and how to
add to it.

Two other documents cover the rest. [`module.zig`](module.zig) is the author
package's root and documents what a native module sees: the interface, the
abstract-type callbacks and which of them may raise.
[`../test/README.md`](../test/README.md) has the test strategy and what a
change must pass before it is accepted.

## Overview

`src/` is 110 `.zig` files and four hand-written headers. There is no C
implementation to select and no upstream Janet C to call. Any C that a Zig
file reaches is libc's, through one of seven `@cImport` blocks. "No C in the
tree" and "no libc" are different claims, and only the first is a goal.

The rules that apply across the tree, each covered in its own section below:

- Nothing jumps. A raise returns an error union, and `defer` and `errdefer` are
  legal everywhere. See [Raising](#raising).

- The runtime exports no `janet_*` symbol. A native module reaches the runtime
  through a table of function pointers, and a file reaches its neighbours by
  `@import`. See [Boundaries](#boundaries).

- Pointers state what is true, with one set of conventions and no exceptions
  outside them: no `[*c]` outside the boundary, a counted byte range is a
  slice, a pointer to a single object is `*T`, or `?*T` where absence is a state
  the code tests, and a C string is `[*:0]const u8` only where the NUL is
  demonstrably read.

- Configuration comes from the build. A file reads `options.<name>` or
  `config`, and never reads its compilation settings out of a C translation.
  See [Configuration](#configuration).

## Source tree

A directory states which compilation includes its files. This matters most to a
module author: an author's `.so` compiles `src/api/` and the two root files, and
must never reach `src/host/` or `src/runtime/`.

| directory      | files | compiled by                             |
| -------------- | ----- | --------------------------------------- |
| `src/api/`     | 7     | a native module's `.so` and the runtime |
| `src/host/`    | 2     | the runtime                             |
| `src/runtime/` | 80    | the runtime, as a single compilation    |
| `src/boot/`    | 2     | the image generator                     |
| `src/client/`  | 16    | the `wattle` and `quickbin` executables |

The counts are of `.zig` files. `src/host/` also has one header and
`src/runtime/` has three.

Thirteen of the sixteen files in `src/client/` are the REPL's line editor.
`src/client/lineedit.zig` and the ten files under `src/client/lineedit/` are a
module named `lineedit`, which imports nothing from the runtime and never reads
or writes the terminal: it takes the bytes a terminal sends and returns the
bytes to draw. The client, the `test/lineedit` step, the contract driver and
`res/tools/layout.zig` import it. `src/client/terminal.zig` is the terminal
itself, raw mode and the reads and writes, for POSIX and the Windows console.
`src/client/prompt.zig` connects the two to the runtime: `getline` reads through
the editor when standard input and standard error are a terminal, and through
the plain reader otherwise.

The line editor's classifier, `lineedit/highlight.zig`, gives each byte of a
line the class it is drawn in, and is a second description of the grammar
`runtime/parser.zig` reads. The two share the lexical tables in
`src/lexicon.zig`. Each describes dispatch, the `!` lookahead, the run of
quotes and the adjacency of a prefix on its own, so a change to that grammar
in the parser is made in the classifier too. `test/highlight.zig` is the
contract between them.

`-Dlineedit`, on by default and off on wasm, selects the editor. It is
independent of `-Dev`. With the event loop the editor waits on the loop for
input, so other fibers run while a line is being edited; without the loop it
reads with a blocking read. Windows reads with the blocking read whether or
not the loop is compiled, because a console handle cannot be waited on through
a completion port, so on Windows the loop does not run while a line is open.

While a line is open, `runtime/io.zig`'s `divert` passes every `write` and
`putChar` to standard output or standard error to the editor, which writes
the output above the line and draws the line again beneath it. The diversion
is thread-local and is removed when the line ends, so a build without the
editor, and a moment with no line open, write to the streams directly.

Three files sit at `src/` itself. `src/root.zig` is the runtime's module root.
It names every file the configuration compiles and reaches all three
directories. `src/module.zig` is the root of the author package, and is the only
name an author writes: a module imports `wattle` and nothing else. Zig limits a
module's relative imports to the directory of its root file, so both roots sit
above the directories they reach. `src/lexicon.zig` is the lexical tables of
source, a module of its own that the runtime and the line editor both import.

`src/api/` is what a module author reads: `abstract_type.zig`, `abi.zig`,
`constants.zig`, `fingerprint.zig`, `interface.zig`, `raise.zig` and `repr.zig`.
`src/host/` is `host.zig`, `cabi.zig` and `wattle_features.h`, which each of the
three host-header translations includes first.

The directories state the boundary but do not enforce it. Both package roots sit
at `src/`, so a relative import can cross between directories, and several do
by design: `api/raise.zig` names four runtime files for the branch that a module
build does not take. Two things enforce the boundary instead.
`res/check/exports.janet` builds the author package the way an outside author
does, and `examples/standalone` consumes the package by path. A
compiler-enforced split would make `api` a build module with the runtime
imported back into it by name. That is possible, and not what the tree does.

### Inside `src/runtime/`

A file exists when it has a name Wattle publishes (a type, an nfunction family or
a module), or because the platform differs. Everything else goes in the file
its callers already name. Each function has one spelling. There is no facade
layer: the file tree and the namespace are the same, so `value/tables.zig`'s
`get` is `tables.get` and is not re-exported anywhere.

| directory        | files | contents                                            |
| ---------------- | ----- | --------------------------------------------------- |
| `runtime/`       | 33    | subsystems with no subdirectory                     |
| `value/`         | 13    | a file per Wattle value type                        |
| `value/helpers/` | 3     | operations on any value                             |
| `vm/`            | 3     | `entry`, `lifecycle`, `state`                       |
| `gc/`            | 2     | `mark`, `sweep`                                     |
| `compiler/`      | 4     | `specials`, `emit`, `optimize`, `regalloc`          |
| `bytecode/`      | 2     | `verify`, `disasm`                                  |
| `os/`            | 4     | the host interface                                  |
| `os/fs/`         | 3     | the file-system interface                           |
| `ev/`            | 5     | `backend`, `stream`, `channel`, `dispatch`, `locks` |
| `net/`           | 1     | the host-header translation                         |
| `filewatch/`     | 1     | the host-header translation                         |
| `ffi/`           | 4     | `types`, `classify`, `marshal`, `call`              |
| `pp/`            | 2     | `format`, `pretty`                                  |

Every directory below `runtime/` is relative to it.

The files directly in `runtime/` are the parser, the PEG engine, the
marshaller, the argument and arity layers, the environment, the pretty
printer's entry point, the allocator (`gc.zig`), `capi.zig`, `io`, `math`,
`scan` and `signal`.
`value/` has arrays, buffers, strings, symbols, tuples, tables, fibers,
functions, abstracts, integer types, vectors, maps and sets, and transients. `value/helpers/` is `wrap`, `access` and `order`.

In `vm/`, `entry.zig` is the interpreter's entry points, `lifecycle.zig` is
init and teardown, and `state.zig` is the `Vm` type, its storage and its
accessor. `os/` and `os/fs/` are split where the platform differs.
`os/abi.zig`, `net/abi.zig` and `filewatch/abi.zig` are the three host-header
translations.

## Module graph

`build.zig` builds each of the following as a separate module. A module's
import list is everything it can reach, so the compiler enforces the direction:

```
config  ->  repr  ->  abi, constants;  host  ->  cabi  ->  root;  lexicon  ->  root
```

- `config` is the build's settings, as comptime values. A module build gets a
  second copy with `native_module` set.
- `repr` is the value representation. It imports `config` and nothing else, so
  a representation that reached allocation, tables, the `Vm` or the collector
  would be a build error.
- `abi` is what a separately compiled module and the runtime must agree on, and
  nothing else: the abstract-type vtable, the registration and method rows, the
  abstract head and the offset to recover it, the signal numbering, the build
  config and the six capabilities. It imports only `repr`. `build.zig`'s
  `wattleModule` gives an author's package this module, so the runtime and an
  author's `.so` use the same types.
- `constants` imports `config`, and `repr` for the tag.
- `host` is the six shapes the host determines: `FILE`, the descriptor, the
  three pthread types and Windows' critical section. The pthread types come
  from libc, because `std.c` declares glibc's `pthread_attr_t`, musl's is a
  different size, and `Vm` embeds it. `host` is a module rather than a file of
  `root` because `cabi` names the same six shapes, and `cabi` cannot import a
  file of `root`. Every Wattle aggregate is declared with the operations on it
  instead (`tables.Table`, `fibers.Fiber`, `functions.FuncDef`,
  `ev_stream.Stream`).
- `cabi` is the external declarations. It imports `config`, `host`, `repr` and
  `constants`.
- `options` is the `Selection` as comptime booleans, and `root.zig` is its only
  reader.
- `lexicon` is the lexical tables of source: the whitespace and symbol bytes,
  the escapes, the hex digits and the UTF-8 check. It imports nothing. `root`
  imports it, and so does the line editor's module, which may import nothing
  from the runtime. A compilation with both in it has one `lexicon`, because
  a file may belong to only one module in a compilation.
- `root` is the runtime. Everything else is a file of it, including
  `api/raise.zig`, `runtime/corefn.zig` and the three host-header translations.

`build.zig` builds this graph six times: for the runtime, for the bootstrap
generator on the host, with `test/contracts.zig` as the root, with
`test/fuzz.zig` as the root, for the module-error fixtures, and as
`wattle-runtime-test` rooted at `root.zig`. A cross build builds it a seventh
time for `zig build examples/quickbin`: on the host, under the target's features, for the
client that makes the image. Every build has the same modules, so a test root
spells the same types and constants as the runtime.

A module boundary is not a compilation boundary. `raise.Error` is declared in
the `raise` module, and a subsystem writes `raise.Error!Value` across the
import; a declaration imported from another module is analysed the same as one
imported from a file. Across a compilation boundary, the only link between two
objects is a symbol. A call through a symbol needs a calling convention, which
means C's, and Zig does not allow an error union in the C calling convention.
For that reason the runtime is a single compilation.

## Raising

No configuration compiles a `setjmp`, `longjmp` or `jmp_buf`. A raise records
its signal in `Vm`'s `pending_signal` and returns `error.Signal`. A
protected scope is `signal.tryInit` and `signal.restore` with the call between
them. `signal.tryInit` points `return_reg` at the scope's payload, which is what
makes a raise catchable.

Every loop entry runs under a protected scope or ends the process on a raise.
The source environment and the Windows cancellation drain are unprotected
entries. They write a host-stderr diagnostic and end the process when their
loop raises. A caller with a scope receives the original signal and payload.

A single turn is the caller's to protect. `ev.loop1` returns `error.Signal`
to the scope its caller opened and ends the process when there is none,
rather than applying a policy of its own. A caller driving turns one at a
time is an embedder, which can open a scope, so a missing one is a mistake
to report and not a case to handle.

The diagnostic names the dispatch the turn was in. Every event a callback may
raise from goes through `ev/dispatch.zig`'s `dispatch`, which records the
callback, the event and the operation serial before the call and puts back the
record it found when the call returns. So a raise leaves the record of the
innermost dispatch that made it, and a failure outside a callback -- an
expired timeout, a supervisor delivery, the `checkToClose` after a callback
returned -- leaves none and is reported without one. A record lasts only as
long as the raise: a fiber resume that ends on one clears it, so a dispatch
failure a program caught cannot name the next failure of that turn. The
callback is its address: an operation carries a function pointer, including
one a native module supplied, and the runtime has no table of names to look
it up in.

A failure a callback cannot raise is scheduled instead. `ev.cancel` refuses a
fiber the loop has never scheduled, `root` being set only by
`ev.scheduleGeneral`, and a file watcher's fiber is one: `filewatch.zig` builds
it and hands it to `asyncStartFiber` without scheduling it.
`ev.scheduleSignal` with the `error` signal reaches the same resume without
that precondition. The three filewatch backends report a failed read that way
and end the watch, so a watcher that dies is something a program learns about
rather than a channel that goes quiet.

A raising function returns `raise.Error!T`, which is `error{Signal}!T`.
An nfunction is a Zig function: `raise.NFunction` takes `[]Value` and returns
`raise.Error!Value` in Zig's calling convention, so `argv[n]` is bounds-checked.

A caller that can propagate the error writes `try`. A caller that cannot
flattens it into a report, in one of four forms:

| form                     | what it does                                   |
| ------------------------ | ---------------------------------------------- |
| `raise.toAbi(result)`    | the result, or a determinate zero if it raised |
| `raise.report(Error)`    | report without a result                        |
| `raise.reportToAbi`      | the same, at a `callconv(.c)` boundary         |
| `raise.panicking(f).abi` | wrap a raising function as a C-ABI function    |

`raise.total(result, site)` is not a flattening form. It aborts through
`fatal`, and is for a raise that cannot happen and would leave the
runtime inconsistent if it did.

A report that nothing consumes aborts the process at the next protected scope,
and the message names neither the cause nor the caller.
`res/check/swallowed.janet` lists every raising function that reaches a
report through a C-ABI function, and prints "no raising caller reaches a report"
on a clean tree. Run it for every change that touches a raise.

## Boundaries

Three things cross a boundary, and each is checked differently.

### The module table

Nothing in `src/` exports a `janet_*` symbol. `api/interface.zig`'s `Runtime` is
an `extern struct` of 83 `callconv(.c)` function pointers, and both the runtime
and a module compile that file. `runtime/capi.zig` has the 83 definitions, and
its `table` fills the struct with them. `runtime/env.zig` passes the table's
address to `_wattle_init`; `module.zig`'s shim stores it in `interface.rt`, and
every call an author makes goes through that pointer. Each crossing is
described once, and the compiler checks every field against the definition it
names in the initializer.

Every field has the same type as its definition. `nfuns_ext`, `def` and
`buffer_push_bytes` take `abi.Env` or `abi.Render` and cast on their first line,
as `runtime/marsh.zig`'s entry points take `abi.Marshal`.

`api/fingerprint.zig` hashes a description of every declaration the two
compilations must agree on. `runtime/env.zig`'s `native` refuses a module whose
fingerprint differs from the runtime's.

The only exports in `src/` are `module.zig`'s pair of loader shims, which are
part of a dynamically loaded module rather than of the runtime.

### External declarations

`host/cabi.zig` has the runtime's `extern` declarations, for libc and the host,
with no Janet name among them. `res/check/seam.janet --check` fails if an
`extern fn janet*` appears anywhere in `src/`.

### Host structures

`os/abi.h`, `net/abi.h` and `filewatch/abi.h` each include `wattle_features.h`
first, and each is used by a single subsystem. They exist because what they
declare depends on the host's headers and cannot be written in Zig without
guessing. After changing a header, clear `.zig-cache` before trusting the
result. Zig may otherwise reuse an object built against the old layout and
produce a silent offset mismatch.

## Configuration

`build.zig` derives two things from the `-D` options. `resolveConfig()` returns
`Config`, the comptime facts a file reads as `config.<name>`, and
`zigSelection()` derives `Selection` from it: the per-file booleans `root.zig`
gates on as `options.<name>`. Both come from a single expression per fact, so a
file cannot be compiled under `Config` and left out of `Selection`.

A comptime-false branch is never analysed. `if (has_ev) ev.x()` is therefore
safe in a build with no event loop, and a branch the host does not select gets
no type checking at all. A change to a platform branch is unchecked until
something builds it:

```sh
zig build -Dtarget=x86_64-linux-musl --cache-dir /tmp/xc -p /tmp/out
```

An instrument must be gated the same way as its subject.
`res/check/gates.janet --check` builds thirteen configurations and compares
their symbol tables against `res/check/gated.txt`. The check exists because
reading `root.zig` cannot settle which files a configuration compiles: its
comptime block does not name every file, and its `pub const` block is lazy and
compiles nothing by itself.

The same laziness determines which `test` blocks run. A `test` in a file that
the comptime block names is compiled into `wattle-runtime-test`. A `test` in a
file reached only through the `pub const` block, or only through another file's
container-level `const`, is not collected. `os/fs/stat.zig` is named in the
comptime block for that reason only.

## Build steps

| step                | what it runs                                        |
| ------------------- | --------------------------------------------------- |
| `install`           | libraries, client, contract driver, fuzz artifact   |
| `fuzz`              | each fuzz target once over its corpus               |
| `image`             | the core image, as `<prefix>/wattle-image.bin`       |
| `run`               | the client                                          |
| `module-errors`     | each wrong native module fails at its definition    |

The tests are steps under `test/`, with `test` running them all:

| step                | what it runs                                        |
| ------------------- | --------------------------------------------------- |
| `test`              | the full test run, described below                  |
| `test/contracts`    | the 68 contracts, in a second runtime compilation   |
| `test/subsystems`   | an alias of `test/contracts`                        |
| `test/runtime`      | the in-file `test` blocks, rooted at `root.zig`     |
| `test/lineedit`     | the line editor's in-file `test` blocks             |

The examples have steps of their own, named under `examples/`:

| step                  | what it builds                                      |
| --------------------- | --------------------------------------------------- |
| `examples`            | the three below                                     |
| `examples/quickbin`   | `examples/quickbin` as `<prefix>/bin/quickbin`      |
| `examples/standalone` | `examples/standalone`, a consumer outside the tree  |
| `examples/web`        | `examples/web`, a WASI reactor, as `<prefix>/web/`  |

A step is run as `zig build <step>`, and `install` is the default, so
`zig build` alone runs it. `install` builds the static and shared libraries.

`zig build test` runs the contracts, both sets of in-file `test` blocks, the
fuzz targets over their corpora, the module-error fixtures, the CLI checks and
the 37 suites. On a native build it also runs `quickbin`.

`test/runtime` and `test/lineedit` each print `All N tests passed.` Add
`--fuzz` to `zig build fuzz` for a campaign. `quickbin` builds
`examples/quickbin/main.wattle` with `examples/digest` linked in.

No header is installed.

The contract driver is installed on every target but wasm, where none of its
readers could run the file they would find. It takes a contract name, or no
name to run all 68 in a single process. Running it with no name is the only
thing in the tree that initialises and tears down the runtime 68 times in a
row, and the only instrument that catches an edit breaking a contract the
author was not thinking about. Run it with no argument before accepting a
change.

`build.zig` refuses to build on two hygiene failures: a `test/*.zig` that
`test/contracts.zig` does not list and `checkContractsListed`'s `exempt` does
not name, and a file-scope `const` that its own file never uses.

## Adding things

### A subsystem

Write `src/runtime/<name>.zig`, or a file under the directory its family already
has. Add a `Selection` field, set it in `zigSelection` gated on the feature
flags it depends on, and name the file in `root.zig`'s comptime block under that
field. A subsystem reached only through another subsystem is imported by that
file instead and does not appear in the root. If it has `test` blocks, name it
in the root anyway, for the reason given in [Configuration](#configuration). A
crossing that a native module can make goes in `runtime/capi.zig` and
`api/interface.zig` and nowhere else.

### A contract

Write `test/<name>.zig` with `pub fn run() void`, and list it in
`test/contracts.zig` under the same `options` condition that `build.zig` applies
to its subject. A contract then exists exactly when its subject does. The build
fails until the contract is listed.

A contract's oracle must be derived independently. A test written against new
code and only ever run against it proves only that the code matches itself. For
anything numeric or with a large input space, add a differential corpus.

### A crossing

Append the field to `api/interface.zig`'s `Runtime` with the exact signature;
do not insert it. Fill it in `runtime/capi.zig`'s `table`, either with an entry
point declared in that file or with a subsystem's own C-ABI shim. The compiler
checks that the two match. Then add the author-side wrapper to `module.zig`.

## Reduced builds

`zig build test` passes with each of these feature flags turned off on its own:
`-Dint-types=false`, `-Dassembler=false`, `-Dpeg=false`, `-Dnet=false`,
`-Dev=false`, `-Dprocesses=false`, `-Dfilewatch=false`, `-Dffi=false`,
`-Ddocstrings=false`, `-Dsourcemaps=false`, `-Dumask=false`, `-Drealpath=false`,
`-Dcryptorand=false` and `-Ddynamic-modules=false`.

A suite guards a missing feature in one of two ways, and the wrong choice fails
without an error.

A binding the build omits entirely is a compile error at its use site rather
than a nil value at run time, so `(when-let [x maybe/missing] ...)` cannot guard
it. It needs `compwhen`, which resolves at compile time.

A binding that exists but raises when called needs an ordinary runtime `when`.
`os/realpath`, `os/cryptorand` and `ffi/native` are registered whatever the
build options are, and only their bodies fail, so `compwhen (dyn 'os/realpath)`
sees a live binding and compiles the guarded code anyway.

Guard regions rather than skipping a suite. A suite that does not run reports
`0 of 0`, which looks the same as a pass. `suite-ev.wattle` guards its network
and subprocess regions separately, so its channel, fiber and deadline tests
still run in both reduced configurations. Where a whole suite depends on the
feature, it exits immediately after `start-suite` with `(compwhen (not (dyn
'some/binding)) (end-suite) (os/exit 0))`. This works because Wattle compiles
and runs a file one top-level form at a time.

`-Dreduced-os=true` is a known gap and is deliberately not guarded. It leaves
only `os/exit`, `os/which`, `os/arch` and `os/compiler`, which breaks
`test/helper.wattle` itself, so every suite fails before reaching its own code.
Guarding it would mean skipping `suite-os` entirely along with much of
`suite-ev` and `suite-bundle`, and the run would pass while testing much less
than it appears to. Revisit it only with a plan for what the suites should
still assert.

## Cross-platform constraints

These constraints are invisible when building only for the development host.

- The runtime object is position independent. It is linked into the shared
  library as well as the static library, and ELF shared objects require PIC.
  `makeRuntimeGraph` sets `.pic = true`. Mach-O is always position independent,
  so omitting the setting fails only on Linux, with tens of thousands of
  relocation errors that do not name the cause.

- The bootstrap pins a baseline CPU. `boot_host` keeps the host's architecture,
  OS and ABI but sets `cpu_model = .baseline`. Native detection would make image
  generation depend on the build machine, and an emulated or unusual host can
  report a model the code generator rejects. The generator must run on the build
  machine, so this is also what makes cross-compiling work.

- `-Dinstall-tests=true` adds the runtime-test executable and the native-module
  and module-load fixtures to `<prefix>/test`, beside the contract and fuzz
  drivers that every non-wasm build installs there. A cross-compiled build is
  tested this way, because `zig build test` runs what it builds and cannot run a
  binary for another target.

Two limitations qualify any result. A musl build links dynamically by default
and loads native modules on a machine with the musl loader, but CI's musl jobs
build with `-Dlinkage=static`, and musl's static `dlopen` is a stub that always
fails, so CI does not run the native-module test on musl. Emulated x86-64
cannot run a NaN-boxed build, because the NaN-boxed layout packs pointers into
doubles and QEMU does not honour the address-space assumption that relies on.
Use `-Dnanbox=false` there, and treat NaN-boxed x86-64 as untested until it
runs on real hardware.
