# Resources

Development scripts, tools, benchmarks, shell completions and editor support.
Tools are run manually except for the build integrations below. `zig build`
compiles and runs `check/wasm_imports.zig` against each wasm32-wasi binary it
produces. It also compiles `tools/layout.zig` and `tools/pty.zig` into
`<prefix>/test`. `zig build test` runs the latter through
`test/suite-lineedit.wattle`.

| directory     | contents                                            |
| ------------- | --------------------------------------------------- |
| `check/`      | checked-in inventories, and reports on the tree     |
| `testing/`    | drivers that build and run the runtime              |
| `tools/`      | programs that run the client's line editor          |
| `bench/`      | benchmarks and their corpora                        |
| `repo/`       | chores about the repository rather than the runtime |
| `completion/` | shell completions for the `wattle` command          |
| `editor/`     | editor support: a Tree-sitter grammar, Neovim files |

Scripts share `common.wattle`, which locates the repository root as its parent
directory. It must remain at this level. `STYLE_GUIDE.md` describes comment and
documentation style.

Each script's header describes its design and limitations. Read it before
running or changing the script.

File paths in scripts are checked only when the scripts run. When moving or
deleting a file, search `res/` for its name and update affected scripts in the
same change.

## Checks

### Inventories

Each inventory writes a `.txt` file beside its script. `--check` compares the
tree against the checked-in file and exits non-zero on a difference. Any other
invocation, including one with an unrecognised argument, regenerates the file.

| script              | inventory                               | must be empty |
| ------------------- | --------------------------------------- | ------------- |
| `layouts.wattle`    | `extern` layouts and their evidence     | —             |
| `optionals.wattle`  | `.?` whose null the function also tests | `tested`      |
| `callconv.wattle`   | `src/` definitions with `callconv(.c)`  | `residue`     |
| `orphans.wattle`    | `pub` declarations nothing references   | `orphan`      |
| `references.wattle` | comment identifiers no code declares    | `unresolved`  |
| `docblocks.wattle`  | `///` blocks not on their declaration   | `stranded`    |
| `gates.wattle`      | symbols a configuration does not export | —             |
| `bench-arms.wattle` | whether a corpus's two arms agree       | —             |

Inventory files use the script's name, except for `gates.wattle`, which writes
`gated.txt`. That script builds each configuration from an empty cache.
`optionals.wattle` counts a bare `orelse unreachable` as well as `.?`.
`references.wattle`'s `c-era` class is a bounded backlog. Each `.txt` file's
header defines its classes.

Inventory rows include `file:line`. `layouts`, `callconv`, `orphans` and
`references` compare rows by file and name, so a line number that has moved does
not fail `--check`; regenerate to refresh it.

### Reports

| script                  | reports                                             |
| ----------------------- | --------------------------------------------------- |
| `chronology.sh`         | migration citations, bad `-D` options, dead paths   |
| `swallowed.wattle`      | raises reported across the C ABI and never consumed |
| `comments.wattle`       | comment text for reading against `STYLE_GUIDE.md`   |
| `image-diff.wattle`     | core image size, host paths, and bytes vs a copy    |
| `image-semantic.wattle` | two images compared by meaning, not source position |
| `wasm_imports.zig`      | wasm imports from outside `wasi_snapshot_preview1`  |

`chronology.sh` and `swallowed.wattle` are silent on a clean tree.
`chronology.sh` looks for migration citations and `-D` options `build.zig` does
not declare in shipped source (`src/`, `test/`, `examples/`, `build.zig`), and,
across the whole tree including the top-level documents and `res/`, for the
retired names listed in its header. The retired-name check uses a fixed pattern.
It does not detect other retired paths or check whether every referenced file
exists.

`comments.wattle` extracts every Zig comment and Markdown paragraph to one file
per source under `zig-out/comments`. It enforces no checks.

`image-diff.wattle` counts the absolute host paths the image embeds, which must
be zero; `--save FILE` on one host and `--against FILE` on another compare its
bytes. `image-semantic.wattle` compares each binding's value, docstring and
bytecode, ignoring `:source-map`. Moving an nfunction's registration line
changes image bytes without changing the semantic comparison. `zig build` runs
`wasm_imports.zig` on wasm targets.

## Testing

| script          | what it runs                                          |
| --------------- | ----------------------------------------------------- |
| `contract.sh`   | one or more contracts, one process each               |
| `leaks.sh`      | the leak check over every contract, or the named ones |
| `matrix.wattle` | the acceptance matrix                                 |
| `mutate.wattle` | the mutation sweep                                    |

`contract.sh` and `leaks.sh` run the driver in `zig-out` and do not build it.
`leaks.sh` is macOS only; its expectations are in the script, so a difference is
a non-zero exit.

`matrix.wattle` checks configurations, optimize modes and cross builds. Set
`contracts-default` at the start of the script to the contracts affected by the
change. [`acceptance-matrix.md`](testing/acceptance-matrix.md) has the
operational detail.

`mutate.wattle --src <file>` runs a repeatable mutation sweep in source order,
using a warm-up and a log. `--all` sweeps every source under `src/` and
can take many hours. A bare invocation prints its usage. An interrupted
sweep leaves its current mutant in the working tree. Read
[`mutation.md`](testing/mutation.md) first.

## Tools

`layout.zig` is installed by `-Dinstall-tests=true` as
`<prefix>/test/wattle-layout` on every target except wasm. It reads a buffer
from standard input and prints the editor's layout as bracketed terminal rows.
Placement uses only `layout.position`:

```sh
printf '(defn f [x]\n  (+ x 1))\n' | zig-out/test/wattle-layout -w 20 -p 9 -o 11
```

It imports the editor's `lineedit` module and runs without a terminal or
runtime. Its header documents the flags and output format. The layout's `test`
blocks use the same display format through `picture.draw`.

`pty.zig` is installed by `-Dinstall-tests=true` as `<prefix>/test/wattle-pty`
on every target except wasm and Windows. It runs a command in a pseudo-terminal,
sends input and prints the command's output bytes. With `-s`, it prints the
resulting screen:

```sh
zig-out/test/wattle-pty -s -w 'repl:1:> ' -i '(+ 1 2)\r' -- zig-out/bin/wattle -q -C
```

Input synchronises on output text using `-w` or `\m{text}` within the input.
Fixed delays are insufficient because input sent before raw mode is enabled can
be discarded. The harness uses an independent terminal model without importing
`lineedit`, allowing tests to check the editor's output independently. Its
header documents the flags, input escapes and supported terminal operations.

## Benchmarks

`layout.sh` runs a binary over a corpus across N stack layouts and reports the
minimum time per workload. `yardstick.sh` runs `layout.sh` for Wattle and C
Janet and computes their ratio. It checks workload names before dividing to
reject corpora with mismatched workloads.

The goal is to run within 10% of the C implementation. Running `layout.sh` over
this tree's binary and over a C Janet binary measures that goal, and running it
over two builds of this tree measures a change. A change that touches an
interpreter or value hot path requires measurement before acceptance. The script
header documents the control workload, significance threshold and reason for
discarding the first round of a session. Read it before interpreting results.

Hot-path loop rewrites require measurement even when expected to compile
identically. A Zig `for` over a sub-slice with a pointer capture keeps both the
element pointer and the counter live, adding induction updates compared with
an index loop. Such changes can affect performance below the corpus's
resolution. Use an isolated function benchmark and compare `otool -tV` output
from both binaries.

Every corpus has two arms, a `.janet` for the C Janet binary and a `.wattle` for
Wattle. `res/check/bench-arms.wattle` checks that both implement the same
program. The corpora are beside the scripts: `interpreter/` is the general
workload, `value/` is the value-access workload, `collections/` reads a
collection's elements, `maps/` measures small persistent maps, `vectors/`
measures persistent vectors against tuples and arrays, and `hashbench/` is a
hash workload from upstream. Each corpus header records the increment for which
it was written. Choose the corpus relevant to the code being changed.

## Repository scripts

Scripts in `res/repo/` run manually to prepare releases or convert source files.

### Release versions

`version.wattle` sets a release version or restores `DEVEL`. The release
process in [RELEASING.md](../RELEASING.md) uses both commands:

```sh
wattle res/repo/version.wattle 0.1.0
wattle res/repo/version.wattle DEVEL
```

Both commands update the version in `build.zig` and the man page sources, then
regenerate the man pages using `predoc` from `PATH`. A release number also
updates `build.zig.zon` and the banner in `README.md`. It replaces the
Unreleased heading in `CHANGELOG.md` with the release number and date.
`DEVEL` adds an Unreleased section if it is absent.

The script prepares all file changes before writing them. It stops if a line
selected for replacement is missing or occurs more than once.

### Source conversion

`janet-to-wattle.wattle FILE.janet ...` writes a `.wattle` file beside each
input and reports changes requiring review. `--dry-run` reports without writing.
`--keep-lines` preserves multiline strings instead of joining them. The command
exits non-zero if a form has no Wattle equivalent.

Conversion replaces individual lexical forms and copies other text unchanged,
allowing a line-by-line diff. Conversion handles lexical syntax only.
It leaves `.janet` paths inside strings and macros constructing code such as
`['if ...]` unchanged.

### Script runtime

Wattle scripts under `res/` use the installed `wattle` on `PATH`. They must run
independently of the build under test because mutation testing modifies that
build. Scripts using newer language features require an updated installation.
Benchmark corpora are the exception: the build under test runs the `.wattle`
program, and C Janet runs the corresponding `.janet` program.
