# The Zig runtime

Wattle's runtime is written in Zig. This document describes its source layout,
module dependencies, implementation rules and extension procedures.

[`module.zig`](module.zig) is the native module package's root. It documents
the interface for module authors, including abstract-type callbacks and which
callbacks may raise. [`../test/README.md`](../test/README.md) describes the test
strategy and the checks required for a change.

## Overview

`src/` contains Zig source and no C source. The runtime links libc.
macOS requires `libSystem` for kernel access, and native module loading uses
`dlopen`.

Host types, constants and functions use Zig's standard library declarations
where available: `std.c`, `std.posix`, `std.os.linux` or `std.os.windows`.
Declarations absent from the standard library are written in Zig beside their
callers. The runtime supports macOS, Linux with glibc or musl, Windows with
mingw, WASI and FreeBSD.

The following rules apply throughout the runtime:

- Raises return error unions. The runtime uses no non-local jumps, so `defer`
  and `errdefer` are legal everywhere. See [Raising](#raising).

- Native modules call runtime functions through a table of function pointers.
  Runtime files use `@import` for internal dependencies. See
  [Boundaries](#boundaries).

- Pointer types follow a fixed set of conventions. `[*c]` is restricted to
  the C boundary. A counted byte range is a slice. A pointer to a single object
  is `*T`, or `?*T` when the code tests for absence. A C string uses
  `[*:0]const u8` only when the terminating NUL is read.

- The build supplies configuration through `options.<name>` or `config`.
  See [Configuration](#configuration).

## Source tree

Source files are grouped by compilation. A native module's shared library
compiles `src/api/` and its root files. It must not compile `src/host/` or
`src/runtime/`.

| directory      | compiled by                                      |
| -------------- | ------------------------------------------------ |
| `src/api/`     | a native module's shared library and the runtime |
| `src/host/`    | the runtime                                      |
| `src/runtime/` | the runtime, as a single compilation             |
| `src/boot/`    | the image generator                              |
| `src/client/`  | the `wattle`, executable and web clients         |

`src/gum/` contains optional Wattle source modules distributed with Wattle.
They are not loaded by default, and a project copies the modules it uses into
its own source tree. The one exception is `gum/args.wattle`, which the image
generator evaluates so that `cli-main` in `boot/boot.wattle` can parse the
`wattle` command line. See [`gum/README.md`](gum/README.md).

The REPL's `lineedit` module consists of `src/client/lineedit.zig` and the files
under `src/client/lineedit/`. It imports nothing from the runtime and performs
no terminal I/O. It takes terminal input bytes and returns display bytes.
The client, the `test/lineedit` step, the contract driver and
`res/tools/layout.zig` import it.

`src/client/terminal.zig` implements raw mode and terminal I/O for POSIX and the
Windows console. `src/client/prompt.zig` integrates the terminal and editor with
the runtime. Its `getline` uses the editor when standard input and standard
error are terminals, and the plain reader otherwise.

The line editor's classifier, `lineedit/highlight.zig`, assigns a display class
to each byte. It implements the grammar separately from `runtime/parser.zig`.
Both use the lexical tables in `src/lexicon.zig`, but independently implement
dispatch, `!` lookahead, quote sequences and prefix adjacency. Grammar changes
must be applied to both implementations. `test/highlight.zig` checks their
results against each other.

`-Dlineedit` selects the editor. It is enabled by default, disabled on wasm and
independent of `-Dev`. With the event loop enabled, the editor waits for input
through the loop so other fibers can run during editing. Without the loop,
input reads block. Windows always uses blocking reads because a completion port
cannot wait on a console handle. The Windows event loop does not run while a
line is open.

While a line is open, `runtime/io.zig`'s `divert` redirects every `write` and
`putChar` for standard output or standard error to the editor. The editor
writes the output above the input line and redraws the line below it. The
redirection is thread-local and ends when the line ends. Output goes directly
to the streams when no line is open or the editor is disabled.

`src/root.zig` is the runtime's module root. It specifies the files compiled for
each configuration and imports from `api/`, `host/` and `runtime/`.
`src/module.zig` is the native module package's root. Module authors import only
`wattle`. Zig restricts relative imports to the module root's directory, so both
roots are above the directories they import from. `src/lexicon.zig` defines the
source lexical tables in a separate module imported by the runtime and the line
editor.

`src/api/` contains the interface files for module authors: `abstract_type.zig`,
`abi.zig`, `constants.zig`, `fingerprint.zig`, `interface.zig`, `raise.zig` and
`repr.zig`. `src/host/` contains `host.zig` and `cabi.zig`.

The directory layout does not enforce import restrictions. Both package roots
are at `src/`, so relative imports can cross between directories.
`api/raise.zig`, for example, imports runtime files in a branch excluded
from native module builds. `examples/native-consumer` checks the separation by
consuming the package through a path dependency, as an external module would.
Compiler enforcement would require a separate `api` build module with a named
import of the runtime. The current build does not use that structure.

### Inside `src/runtime/`

Separate files define published types, nfunction families or modules, or
contain platform-specific implementations. Other code belongs in the file
already imported by its callers. Functions have one name and are not
re-exported through a facade. The file layout determines the namespace: `get`
in `value/tables.zig` is called as `tables.get`.

| directory        | contents                                            |
| ---------------- | --------------------------------------------------- |
| `runtime/`       | subsystems with no subdirectory                     |
| `value/`         | a file per Wattle value type                        |
| `value/helpers/` | operations on any value                             |
| `vm/`            | `entry`, `lifecycle`, `state`                       |
| `gc/`            | `mark`, `sweep`                                     |
| `compiler/`      | `specials`, `emit`, `optimize`, `regalloc`          |
| `bytecode/`      | `verify`, `disasm`                                  |
| `os/`            | the host interface                                  |
| `os/fs/`         | the file-system interface                           |
| `ev/`            | `backend`, `stream`, `channel`, `dispatch`, `locks` |
| `net/`           | the host declarations                               |
| `ffi/`           | `types`, `classify`, `marshal`, `call`              |
| `pp/`            | `format`, `pretty`                                  |

Paths below `runtime/` in the table are relative to that directory.

Files directly in `runtime/` implement the parser, PEG engine, marshaller,
argument and arity layers, environment and pretty-printer entry point. The
directory also contains `no_compiler`, the allocator (`gc.zig`), `capi.zig`,
`edn`, `io`, `json`, `math`, `scan` and `signal`.

`value/` implements arrays, buffers, strings, symbols, tuples, tables, fibers,
functions, abstracts, integer types, vectors, maps, sets and transients.
`value/helpers/` contains `wrap`, `access` and `order`.

In `vm/`, `entry.zig` defines the interpreter entry points. `lifecycle.zig`
implements initialisation and teardown. `state.zig` defines `Vm`, its storage
and its accessor. Files in `os/` and `os/fs/` separate platform-specific code.
`os/abi.zig` and `net/abi.zig` declare the subsystems' host interfaces in Zig.

The Windows process CPU clock may read zero. If `GetProcessTimes` fails,
`os.gettime` returns null and `os.gettimeAbi` returns -1. The failed call's
output fields are not read.

### Call frames

Each call frame occupies four `Value` slots below its stack base. Its
`StackFrame` fields are the function, program counter, captured environment,
previous frame index and a 32-bit flag word. In that word bit 0 marks a tail
call, bit 1 marks an entrance, bits 2 to 7 store the argument count saturated
at 63, bits 8 to 30 are reserved, and bit 31 marks an environment in the
marshalled form. The last bit is clear in a live frame. The clause prologue's
`jump_if_not_arity` reads the stored count; its verifier limits the compared
count to 32. The unmarshaller rejects a non-saturated count outside the
function's arity range.

## Module graph

`build.zig` creates the following modules. Each module can import only its
listed dependencies, so the compiler enforces the dependency direction:

```
config  ->  repr  ->  abi, constants;  host  ->  cabi  ->  root;  lexicon  ->  root
```

- `config` defines build settings as comptime values. Native module builds use
  a second copy with `native_module` set.

- `repr` defines the value representation and imports only `config`.
  Dependencies on allocation, tables, `Vm` or the collector would fail to
  compile.

- `abi` defines the types shared by the runtime and separately compiled native
  modules: the abstract-type vtable, registration and method rows, abstract
  head and its recovery offset, signal numbers, build configuration and
  capabilities. It imports only `repr`. `build.zig`'s `wattleModule` supplies
  this module to native module packages so both compilations use the same types.

- `constants` imports `config` and uses `repr` for the tag.

- `host` defines host-dependent types from `std`: `FILE`, the descriptor
  and the thread handle. It is a separate module because `cabi` also uses these
  types and cannot import a file from `root`. Wattle aggregate types are
  declared beside their operations: `tables.Table`, `fibers.Fiber`,
  `functions.FuncDef` and `ev_stream.Stream`.

- `cabi` declares external functions. It imports `config`, `host`, `repr` and
  `constants`.

- `options` defines `Selection` as comptime booleans. Only `root.zig` reads it.

- `lexicon` defines the source lexical tables: whitespace and symbol bytes,
  escapes, hex digits and the UTF-8 check. It imports nothing. Both `root` and
  the line editor import it; the editor cannot import runtime code. A
  compilation containing both uses one `lexicon` module because each file can
  belong to only one module per compilation.

- `root` contains the remaining runtime files, including `api/raise.zig`,
  `runtime/corefn.zig`, `os/abi.zig` and `net/abi.zig`.

`build.zig` compiles this graph for the runtime, the host bootstrap
generator, `test/contracts.zig`, `test/fuzz.zig`, the module-error fixtures and
`wattle-runtime-test` rooted at `root.zig`. Cross builds also compile it
for `zig build examples/native-executable`. That compilation produces a
host client with the target's features to generate the image. All compilations
use the same modules, so test roots use the runtime's types and constants.

Imported declarations are analysed within the same compilation, whether
imported from a module or a file. A subsystem can therefore use
`raise.Error!Value` with the `Error` declaration from `raise`.

Separately compiled objects link through symbols. Calls between those objects
use the C calling convention, which does not support Zig error unions. The
runtime uses a single compilation so internal calls can return error unions.

## Raising

Raises propagate through Zig error unions using ordinary function returns
rather than jumps. Raising records the signal in `Vm.pending_signal` and
returns `error.Signal`.  To establish a protected scope, call `signal.tryInit`
before the protected call and `signal.restore` afterwards. `signal.tryInit`
points `return_reg` at the scope's payload so the caller can catch the raise.

Every event-loop entry runs under a protected scope or terminates the process
on a raise. The source environment and Windows cancellation drain use
unprotected entries. If their loop raises, they write a diagnostic to host
standard error and terminate. A caller with a protected scope receives the
original signal and payload.

The caller must establish a protected scope before calling `ev.loop1`.
`ev.loop1` returns `error.Signal` to that scope, or terminates the process if
no scope exists. An embedder running individual turns can establish a scope,
so a missing scope is reported as a caller error.

The diagnostic identifies the dispatch in progress when the loop raised.
Every callback event that may raise uses `ev/dispatch.zig`'s `dispatch`.
Before calling the callback, `dispatch` records its pointer, event and operation
serial. After a successful call, it restores the previous record. On a raise,
the innermost dispatch record remains available for the diagnostic.

Failures outside callbacks have no dispatch record. These include expired
timeouts, supervisor deliveries and `checkToClose` calls after a callback
returns. A fiber resume that ends on a raise clears the record, preventing a
caught dispatch failure from being reported for a later failure in the same
turn. Callbacks are identified by address because operations store function
pointers, including native module pointers, and the runtime has no name table.

A raising function returns `raise.Error!T`, which is `error{Signal}!T`.
Nfunctions use `raise.NFunction`, which takes `[]Value` and returns
`raise.Error!Value`. Access through `argv[n]` is bounds-checked.

The runtime stores and calls `abi.NFunction` pointers with `callconv(.c)`.
These functions take `argc` and `argv` and return `abi.NResult`, containing a
value and a `raised` flag. `raise.stored` generates the wrapper at compile
time. `raise.call` calls it and returns `error.Signal` if `raised` is set.
Registration and method rows store the result of `raise.stored`, exposed to
module authors as `wattle.nfunction`.

Slices and error unions have no stable layout across compilations, so calls
into native module nfunctions use the C calling convention. Runtime nfunctions
use the same wrappers, avoiding a VM check for the nfunction's origin. Casting
an nfunction pointer into a slot without `raise.stored` compiles but crashes
when called.

An abstract type's raising callbacks use the same wrapper mechanism:
`get`, `put`, `next`, `length`, `call`, `tostring`, `marshal` and `unmarshal`.
These callbacks use `*T` for the abstract value and error unions for raises.
`module.define` generates `callconv(.c)` wrappers that report raises through a
`bool` or an `abi.NResult`, `abi.OptResult`, `abi.SizeResult` or
`abi.PtrResult`. The runtime checks the flag with `raise.unwrap` at each call.

Callers that can propagate errors use `try`. Callers that cannot propagate
errors convert them to reports using the following forms:

| form                     | what it does                                         |
| ------------------------ | ---------------------------------------------------- |
| `raise.toAbi(result)`    | the result, or a determinate zero if it raised       |
| `raise.report(Error)`    | report without a result                              |
| `raise.reportToAbi`      | report without a result at a `callconv(.c)` boundary |
| `raise.panicking(f).abi` | wrap a raising function as a C-ABI function          |

`raise.total(result, site)` aborts through `fatal` if the result is an error.
Use it for an unexpected raise that would leave the runtime inconsistent.

An unconsumed report causes an abort at the next protected scope. The message
identifies neither the cause nor the caller. `res/check/swallowed.wattle`
lists every raising function that reaches a report through a C-ABI function,
and prints "no raising caller reaches a report" on a clean tree. Run it for
every change to raising code.

## Binding documentation

A binding's entry table stores documentation under `:doc` and `:sigs`. `:doc`
contains the docstring prose. `:sigs` contains function signatures, one per
line, such as `(f a)\n(f a b)`. It is absent for bindings without signatures.
`defn` sets both from its arity clauses and docstring. `corefn.reg` sets them
from its `usage` and `doc` arguments. `doc` and the line editor's hint print
`:sigs` before `:doc`. `-Ddocstrings=false` omits both keys.

Each supported arity is documented as a separate signature. For example,
`os/date` has `(os/date)`, `(os/date time)` and `(os/date time local)`.

`doc` highlights argument names and references to other bindings in the
docstring prose. It displays argument names in yellow, matching whole words
against the names in `:sigs`. Those names are the tokens after the function
name on each line, excluding `&`-words and keywords. A docstring author can
reference other bindings by prefixing the binding name with `^`. The name is
printed in cyan without the `^`. With colour disabled, both appear as ordinary
text, with the `^` omitted. The line editor's hint also omits the `^` and does
not colour arguments.

## Boundaries

Native module calls, external declarations and host structures have separate
boundary checks.

### The module table

`api/interface.zig` defines `Runtime`, an `extern struct` of `callconv(.c)`
function pointers. Both the runtime and native modules compile this file.
`runtime/capi.zig` defines the functions and initialises the struct in
`table`.

`runtime/env.zig` passes the table's address to `_wattle_init`. The shim in
`module.zig` stores it in `interface.rt`, which module API calls use. Each
_crossing_ is a field of the table specifying a runtime function callable by a
native module. Its signature is declared once, and the compiler checks the
initialising function against that field.

Each field's type matches its function definition. `nfuns_ext`, `def` and
`buffer_push_bytes` take `abi.Env` or `abi.Render` and cast the parameter on
their first line. The entry points in `runtime/marsh.zig` similarly take
`abi.Marshal`.

`api/fingerprint.zig` hashes a description of every declaration the two
compilations must agree on. `runtime/env.zig`'s `native` refuses a module whose
fingerprint differs from the runtime's.

The description includes `api/fingerprint.zig`'s manually maintained
`semantic_revision`. Increment it when native interface semantics change
incompatibly without a change to the described types. Ordinary bug fixes and
internal changes do not require an increment. The revision changes the
fingerprint without changing `abi.BuildConfig` or the loader's comparison.
A revision change requires recompiling native modules.

The only exports in `src/` are `module.zig`'s pair of loader shims, which are
compiled into dynamically loaded modules.

### External declarations

`host/cabi.zig` contains the runtime's `extern` declarations for libc and the
host.

### Host structures

`os/abi.zig` and `net/abi.zig` declare their subsystems' host structures,
constants and functions under their C names in a `sys` namespace. They use
`std` declarations where the platform's value or layout is available, and
local declarations otherwise, as described in [Overview](#overview). Each
file is used by a single subsystem; host types do not cross subsystem
boundaries.

## Configuration

`build.zig` derives configuration from the `-D` options. `resolveConfig()`
returns `Config`, read by source files as `config.<name>`. `zigSelection()`
derives `Selection` from `Config`. Its booleans determine which files
`root.zig` compiles, through `options.<name>`. Both use a single expression per
setting, preventing inconsistent inclusion under `Config` and `Selection`.

`*prefix*` specifies the root for these directories: `<prefix>/lib/wattle/apps`
for installed applications, `<prefix>/bin` for programs and `<prefix>/share/man`
for man pages. The runtime starts without a prefix. `WATTLE_PREFIX` and
`--prefix` each set a single root directory; neither accepts a list. The flag
and dynamic binding use the name `prefix`. The environment variable adds the
project name as `WATTLE_PREFIX`.

With no prefix, the `apps` commands raise. With an empty prefix, set by
`--prefix ""`, the first `apps` command raises. Both error messages name
`WATTLE_PREFIX` and `--prefix`.

`wattle/libpath`, `wattle/binpath`, `wattle/manpath` and `wattle/srcpath` take
no arguments and return these derived directories: `<prefix>/lib/wattle`,
`<prefix>/bin`, `<prefix>/share/man` and `<prefix>/share/wattle`. They raise if
the prefix is nil or empty. They are functions because `*prefix*` can change
during execution.

The image contains no prefix. A binding cannot set the prefix to nil: a nil
entry in a fiber's environment causes a lookup in the root environment. Only a
runtime started without a prefix has a nil prefix.

Comptime-false branches are not analysed or type-checked. A build without the
event loop can therefore include `if (has_ev) ev.x()`. Changes to an unselected
platform branch require a build for that platform:

```sh
zig build -Dtarget=x86_64-linux-musl --cache-dir /tmp/xc -p /tmp/out
```

Checks must use the same configuration conditions as the code they check.
`res/check/gates.wattle --check` builds configurations and compares
their symbol tables against `res/check/gated.txt`. Reading `root.zig` alone
does not establish which files are compiled. Its comptime block does not list
every file, and declarations in its `pub const` block are analysed only when
used.

This analysis rule also determines which `test` blocks run. Tests in files
listed in the comptime block are compiled into `wattle-runtime-test`. Tests
in files imported only through the `pub const` block or another file's
container-level `const` are not collected. `os/fs/stat.zig` is listed in the
comptime block solely to include its tests.

## Module path

`:modpath` is a dynamic binding that holds a vector of directories. A bare
`(import name)` searches them in order. A relative import does not use it.
The prefix has no shared module directory, so installing software does not make
a module importable by another program. No environment variable or flag sets
`:modpath`.

The command sets `:modpath` before it loads any program. `wattle run` looks for
`info.edn` in the directory of the script: `foo/bar/baz.wattle` uses
`foo/bar/info.edn`, and `foo.wattle` uses `./info.edn`. It does not search the
parent directories. `wattle test` and `wattle build` take no script and look
in the working directory.

`:modpath` is the `deps/` directory of that project, followed by a directory
for material that is not committed, such as built native modules. The second
directory holds a `.gitignore` that excludes its contents. A vendored copy in
`deps/` overrides generated material.

With no `info.edn`, `:modpath` is unset and nothing is printed at start. An
import that fails while `:modpath` is unset reports that there is no `info.edn`
beside the script. A script with no project is not warned about.

A compiled executable uses no module path. `wattle build exe` stores the
program and everything it imported in the executable and links its native
modules.

## Versions

A build's _version label_ is printed by `wattle/version`, `--version` and the
REPL banner. Releases use their release number, such as `0.1.0`. Other builds
use `DEVEL-` followed by the abbreviated commit hash. The suffix `-dirty` is
appended when tracked files differ from that commit. Untracked files, including
`AGENTS.md` and `.agents/`, do not affect the label. Development builds have no
release number because the next number is chosen at release time from the
changes listed in `CHANGELOG.md`.

`res/repo/version.wattle` sets `build.zig`'s `version` to a release number or
`DEVEL`. For `DEVEL`, `versionLabel` runs `git describe` in the build root.
Without `.git`, as in a fetched package or the copy installed under
`share/wattle`, the label is `DEVEL` alone. The label is a `Config` field, so
changing the commit or tracked files' dirty status rebuilds the runtime and
image.

Zig caches the configuration from `build.zig`. It reruns `build.zig` when a
file or directory declared as an input changes. `git describe --dirty` depends
on every tracked file, so `versionLabel` disables configuration caching when
the build root contains `.git`. Every build then reruns `build.zig`. Without
`.git`, caching remains enabled, and the build checks of `src/` and `test/`
declare their inputs.

Version labels are used only in messages. Native module compatibility requires
equal configuration bits, Zig versions and `api` fingerprints.
`abi.BuildConfig` includes the label so an incompatibility error identifies
both builds. `build.zig.zon` requires a semantic version; its `.version` is the
most recent release number. For a release, `res/repo/version.wattle` sets that
number along with the version label. Static and shared library file names have
no version suffix.

## Applications and dependencies

A _project_ is a directory that holds an `info.edn`. An _application_ is a
program that a user runs by name, installed under the prefix. A _dependency_ is
software that a project requires. A dependency is vendored: its source is
copied into the project, and nothing is installed for other projects to import.
`wattle apps` manages applications and `wattle deps` manages the dependencies of
the current project. Functions that the commands call have the prefixes `app/`,
`dep/` and `build/`.

### Installing applications

`wattle apps install [source [ref]]` installs an application. `wattle apps
upgrade [name]` installs the recorded source again, `wattle apps remove name`
removes an application and `wattle apps list` lists the installed
applications. The _source_ argument specifies the location of an application
and is interpreted in this order:

- An existing directory is installed from its current contents.
- A name ending in `.tar` or `.tar.gz` specifies a tarball. `curl` downloads it
  and `tar` unpacks it.
- Any other name specifies a Git repository, copied with `git clone --depth 1`.

Without `source`, the command installs the current directory.

The `info.edn` of an application has a `:group`, a string. By convention it is
a reverse domain, such as `net.inqk`. Installing an application with no `:group`
raises an error that says `info.edn` needs one. `:group` and `:name` are each
one directory name, so neither may be empty, contain a path separator or be
`.` or `..`. A `:name` is unique across groups. Installing an application whose
name is installed in any group raises an error, so `apps upgrade` and `apps
remove` take the name alone.

An application is installed in `<prefix>/lib/wattle/apps/<group>/<name>/`. That
directory holds the manifest, a copy of `info.edn`, the hook script (copied as
`hooks.wattle` or `hooks/`) and, for a `:src` artifact, the copied files. Executables are installed in
`<prefix>/bin` and man pages in `<prefix>/share/man`. `import` does not search
the application directory.

Applications use either an installation script or declarative metadata. If
`hooks.wattle` or `hooks/init.wattle` exists, installation runs only that
script's hooks: `clean`, `build`, `install` and `check`. Removal runs its
`remove` hook. Otherwise, `info.edn` must declare `:artifacts` or `:man`.

Each `:exe` artifact is built by `wattle build exe` in the project root, using
the default release mode, `safe`. The resulting `zig-out/bin/<name>` is
installed in `bin`. Applications requiring another mode must use a script.
Each path in the `:man` vector is installed in `share/man`. The section is the
digit after the file name's last `.`: `man/predoc.1` is installed in `man1`.
A file name without a final `.` and a digit from 1 to 9 causes an error.

`:web` and `:lib` artifacts are not installed. Declaring a `:lib` artifact
without a script, and without a `:src` artifact that names it in `:libs`,
causes an error. An application without a script, `:artifacts` or `:man` is not
installed.

`ref` specifies a Git branch or tag. It is accepted only for Git repositories;
using it with a directory or tarball raises an error. The source name is read
literally. A trailing `?query` is part of the name, so a URL ending in a query
is interpreted as a Git repository.

Downloaded sources are unpacked into a temporary directory under
`<prefix>/lib/wattle`. The directory is removed after installation, including
on failure. If the unpacked tree has a single top-level directory, that
directory becomes the project root. The manifest records the source, the `ref`
and the revision, but not the temporary path. The revision is the commit hash
for a Git repository and a hash of the contents for a tarball or a directory.
`apps upgrade` downloads the recorded source again, or installs from the
recorded directory for local sources.

`curl`, `tar` and `git` are located through `PATH`. If a required tool is
missing, `apps install` names it in the error. A non-zero exit status also
raises an error. The message includes the tool's name and status, followed on
the next line by its standard error output.

Executable builds do not capture output, allowing immediate display and Zig's
terminal progress reporting. Their error messages identify `wattle build exe`
and its exit status. Application scripts run with the caller's privileges.
Application sources are not verified.

### Scripts

A `:src` artifact is a program installed as source. It has a `:name`, an
`:entry`, the Wattle file that defines `main`, and `:files`, a required vector
of paths relative to the project root. `wattle apps install` copies each path,
recursively, into the application directory. A `:src` artifact may have
`:libs`, a vector of the names of `:lib` artifacts. Install builds each with
`wattle build lib` into the application directory, where `:modpath` finds it,
and raises an error if Zig is not on the `PATH`. `apps upgrade` rebuilds them,
because the loader refuses a module built with different configuration bits, a
different Zig version or a different `api` fingerprint.

`wattle run` finds the project beside the script, so in development the entry
file is at the project root. An installed script has no such limit.

For a `:src` artifact, install writes `<prefix>/bin/<name>`, the binscript. It
begins with the line `#!/usr/bin/env wattle` and makes one call to `app/run`
with the group, the name and the entry path. `app/run` finds the application
directory from the `prefix` binding, sets `:modpath` to its `deps/` directory,
loads the entry file into an environment that holds the arguments of the call,
and calls `main` as `wattle run` does. It raises an error that names
`WATTLE_PREFIX` if the prefix is not set. The binscript does not read
`info.edn`.

Running an installed script needs `wattle` on the `PATH` and the prefix set. An
`:exe` contains the runtime, the program and its imports, and needs neither.
Windows has no shebang lines, so installing a `:src` artifact on Windows raises
an error.

### Vendoring dependencies

`wattle deps vendor` reads `info.edn` in the current directory and copies each
entry of `:vendored` into the project. An entry is fetched by the same code as
`apps install`, so `:url` is a directory, a tarball or a Git repository and
`:ref` follows the rule for `ref`. `:prefix` and `:paths` are checked for every
entry before the first fetch, and a path that is absolute or has a `..`
component raises an error. An existing file at a destination is replaced. The
command records the revision of each source it copied. `info.edn` has no
`:dependencies`, and the manifest of an installed application records none.

## Build steps

Run a step with `zig build <step>`. The default step is `install`, so
`zig build` builds and installs the static and shared libraries and client.
No header is installed.

| step            | what it runs                                         |
| --------------- | ---------------------------------------------------- |
| `install`       | libraries, client, man page                          |
| `fuzz`          | each fuzz target once over its corpus                |
| `image`         | core image generation as `<prefix>/wattle-image.bin` |
| `run`           | the client                                           |
| `module-errors` | compilation failures for invalid native modules      |

The `test` step runs all steps under `test/`:

| step              | what it runs                               |
| ----------------- | ------------------------------------------ |
| `test`            | the full test run described below          |
| `test/contracts`  | contracts in a second runtime compilation  |
| `test/subsystems` | an alias of `test/contracts`               |
| `test/runtime`    | in-file `test` blocks rooted at `root.zig` |
| `test/lineedit`   | the line editor's in-file `test` blocks    |

Example build steps are under `examples/`:

| step                         | what it builds                                                   |
| ---------------------------- | ---------------------------------------------------------------- |
| `examples`                   | all examples below                                               |
| `examples/native-executable` | `examples/native-executable` as `<prefix>/bin/native-executable` |
| `examples/native-consumer`   | `examples/native-consumer`, a consumer outside the tree          |
| `examples/web-repl`          | `examples/web-repl`, a WASI reactor, as `<prefix>/web-repl/`     |

`zig build test` runs the contracts, both sets of in-file `test` blocks, fuzz
corpora, module-error fixtures, CLI checks and suites. Native builds also
run `native-executable`.

`test/runtime` and `test/lineedit` each print `All N tests passed.` Add
`--fuzz` to `zig build fuzz` for a fuzzing campaign. `native-executable` builds
`examples/native-executable/main.wattle` with `examples/native-events`
linked in.

`-Dinstall-tests=true` installs the contract driver on every target except wasm,
where the installed driver could not be run. The driver accepts a contract name
or no argument to run all contracts in a single process. The no-argument run
checks repeated runtime initialisation and teardown. It also checks for failures
in contracts outside the intended scope of a change. Run it without arguments
before accepting a change.

`build.zig` rejects these source conditions: an unlisted `test/*.zig` file and
an unused file-scope `const`. Test files must be listed in `test/contracts.zig`
or exempted in `checkContractsListed`'s `exempt` list.

## Extensions

Adding a subsystem, contract or native module crossing requires the following
source and build changes.

### Subsystems

Write `src/runtime/<name>.zig`, or add a file to the subsystem family's existing
directory. Add a `Selection` field and set it in `zigSelection` using the
required feature flags. List the file in `root.zig`'s comptime block under that
condition.

A subsystem used only by another subsystem is imported by that subsystem and
omitted from the root. If the new subsystem has `test` blocks, list it in the
root as well, as described in [Configuration](#configuration). Native module
crossings are declared in `runtime/capi.zig` and `api/interface.zig` only.

### Contracts

Write `test/<name>.zig` with `pub fn run() void`. List it in
`test/contracts.zig` under the same `options` condition used by `build.zig` for
the code under test. Both must be compiled under the same configurations.
The build fails until the contract is listed.

Derive the contract's expected results independently of the implementation.
Testing new code only against results derived from that code cannot establish
correctness. For numeric operations or large input spaces, add a differential
corpus.

### Crossings

Append a field with the exact signature to `api/interface.zig`'s `Runtime`.
Do not insert it among existing fields. Initialise it in `runtime/capi.zig`'s
`table` with an entry point from that file or a subsystem's C-ABI shim. The
compiler checks that the field and function types match. Add the module API
wrapper to `module.zig`.

## Reduced builds

`zig build test` passes with each of these feature flags disabled individually:
`-Dint-types=false`, `-Dassembler=false`, `-Dpeg=false`, `-Dnet=false`,
`-Dev=false`, `-Dprocesses=false`, `-Dffi=false`, `-Ddocstrings=false`,
`-Dsourcemaps=false`, `-Dumask=false`, `-Drealpath=false`, `-Dcryptorand=false`
and `-Ddynamic-modules=false`.

Suites must distinguish omitted bindings from bindings that raise when called.
Using the wrong guard can leave tests unexecuted without reporting an error.

An omitted binding causes a compile error at its use site. It does not resolve
to nil at run time, so `(when-let [x maybe/missing] ...)` cannot guard it.
Use `compwhen`, which resolves at compile time.

A binding that remains defined but raises when called requires a runtime
`when`. `os/realpath`, `os/cryptorand` and `ffi/native` are registered under all
build configurations; only their implementations fail. An expression such as
`compwhen (dyn 'os/realpath)` finds the binding and compiles the guarded code
even when the operation is unavailable.

Guard the regions that require a feature. Skipping a suite reports `0 of 0`,
which appears to be a pass. `suite-ev.wattle` guards network and subprocess
regions separately, allowing channel, fiber and deadline tests to run in both
reduced configurations.

If every test requires the feature, exit immediately after `start-suite`:

```wattle
(compwhen (not (dyn 'some/binding)) (end-suite) (os/exit 0))
```

Wattle compiles and runs each top-level form before compiling the next, so this
exit prevents compilation of the remaining forms.

`-Dreduced-os=true` registers only `os/exit`, `os/which`, `os/arch` and
`os/compiler`. A suite that requires other `os/` bindings throughout is marked
`needs_os` in `build.zig` and is not scheduled in that configuration. A suite
that requires an `os/` binding in a single region uses `compwhen` around that
region. `suite-pp.wattle`, for example, guards `os/setenv` this way.

## Image-only builds

`src/client/web.zig` is the web reactor's root. `src/client/web/wasi.js`
provides its WASI implementation in JavaScript. Both are under `src/` so
packages depending on Wattle can use them.

The public build entry point, `wattleWeb` in `build.zig`, takes a dependency
instantiated for the build machine, a name and a source file. It builds the
reactor for wasm32-wasi using the image-only configuration below. The
dependency's `wattle` client generates the image.

`wattleWeb` then runs `client/web/pack.zig` on the build machine. The packer
copies the runtime, image and `wasi.js` into a directory. Their file names use
a shared hash of their contents. It also writes a loader module referencing
those files. `wattleWeb` returns the directory as a `Web`.

The reactor's `wattle_web_run_image` takes arguments in a buffer of
NUL-terminated strings. `wasi.js` provides standard input. Before each call,
`web.zig` clears the C stream's end-of-file state and buffered input so an
existing instance can read new input.

`wattle build web` generates a `build.zig` that calls `wattleWeb` for each
`:web` artifact in `info.edn`. It disables `docstrings` and `sourcemaps` in the
host dependency to omit both from the program's image.

`-Dwasm-image=true` applies only to `zig build examples/web-repl`. It excludes
`runtime/compiler.zig`, `runtime/compiler/` and `runtime/parser.zig` from the
web reactor, and sets `-Ddocstrings=false` and `-Dsourcemaps=false`. The reactor
exports `wattle_web_run_image` in place of `wattle_web_eval`. Like `wattle -i`,
it unmarshals an image produced by `make-image` and calls the image's `main`.
The step installs the binary and `wasi.js`. It omits the page because the page
submits source for evaluation.

The image generator includes the compiler to compile `boot.wattle`.
`bootConfig` enables `Config.compiler`, so the core image includes every
binding, including compiler-dependent bindings. The image-only runtime has no
implementation of `compile` or the `parser/` functions.
`runtime/no_compiler.zig` registers stubs for those names, allowing the image
to unmarshal. Calling a stub raises an error. Functions built on those
bindings, including `eval`, `run-context` and `parse`, remain in the image and
raise when called. `env.zig`'s `dobytesImpl` prints the same error message and
returns the compile-error flag.

The contract driver and suites compile and run source. They cannot run with
`Config.compiler` disabled.

## Cross-platform constraints

Builds for the development host alone do not check the following constraints.

- The runtime object must be position independent. Both static and shared
  libraries link it, and ELF shared objects require PIC. `makeRuntimeGraph`
  sets `.pic = true`. Mach-O is always position independent, so omitting the
  setting fails only on Linux. It produces tens of thousands of relocation
  errors without identifying the missing setting.

- The bootstrap uses a baseline CPU. `boot_host` preserves the host's
  architecture, OS and ABI but sets `cpu_model = .baseline`. Native CPU
  detection would make image generation depend on the build machine. An
  emulated or unusual host can report a model rejected by the code generator.
  The image generator must run on the build machine, including during cross
  builds.

- `-Dinstall-tests=true` installs the contract and fuzz drivers, runtime-test
  executable, line-editor tools, native-module fixtures and module-load
  fixtures under `<prefix>/test`. These installed programs are used to test
  cross builds. `zig build test` runs the programs it builds and cannot run
  binaries for another target.

- On Windows, `os/execute` and `os/spawn` pass child processes a copy of a
  stream handle from `os/open`. `os/open` uses `FILE_FLAG_OVERLAPPED`, but a
  child's C runtime writes to standard streams without an `OVERLAPPED`
  structure. Such writes fail on character devices such as `NUL`.
  `spawnWindows` reopens character devices without the flag and duplicates
  other handles. It makes the copy inheritable and closes it after
  `CreateProcessA`. The original stream handle is unchanged. `core/file`
  handles and pipes created by `:pipe` are passed directly.

A musl build links dynamically by default and can load native modules on a
machine with the musl loader. CI uses `-Dlinkage=static` for musl, whose static
`dlopen` always fails. The musl CI jobs therefore omit the native-module test.

Emulated x86-64 cannot run NaN-boxed builds. The representation packs pointers
into doubles and depends on an address-space assumption that QEMU does not
honour. Use `-Dnanbox=false` under emulation.
