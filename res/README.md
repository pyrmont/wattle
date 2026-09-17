# Resources

The development instruments, and the shell completions. Every instrument is run
by hand, with one exception: `zig build` compiles `check/wasm_imports.zig` and
runs it against each wasm32-wasi binary it produces.

| directory     | contents                                            |
| ------------- | --------------------------------------------------- |
| `check/`      | checked-in inventories, and reports on the tree     |
| `testing/`    | drivers that build and run the runtime              |
| `bench/`      | benchmarks and their corpora                        |
| `repo/`       | chores about the repository rather than the runtime |
| `completion/` | shell completions for the `wattle` command          |

`common.janet` is the module the Janet scripts share. It finds the repository
root as the directory above its own, so it stays at this level.
`STYLE_GUIDE.md` holds the rules for comments and documentation prose.

Each script's header records why the script has its shape and what it cannot
see. Read the header before running or changing a script.

A path spelled inside a script is a string, so a script naming a file that has
moved fails only when it is next run. When a change moves or deletes a file,
grep `res/` for the name and update the scripts in the same change.

## check

### Inventories

Each inventory writes a `.txt` file beside its script. `--check` compares the
tree against the checked-in file and exits non-zero on a difference. Any other
invocation, including one with an unrecognised argument, regenerates the file.

| script             | inventory                               | must be empty |
| ------------------ | --------------------------------------- | ------------- |
| `exports.janet`    | symbols the shared library exports      | —             |
| `layouts.janet`    | `extern` layouts and their evidence     | —             |
| `seam.janet`       | `c.janet_*` names and their publisher   | see below     |
| `counters.janet`   | signed counters that index a container  | `e`           |
| `optionals.janet`  | `.?` whose null the function also tests | `tested`      |
| `callconv.janet`   | `src/` definitions with `callconv(.c)`  | `residue`     |
| `orphans.janet`    | `pub` declarations nothing references   | `orphan`      |
| `references.janet` | comment identifiers no code declares    | `unresolved`  |
| `docblocks.janet`  | `///` blocks not on their declaration   | `stranded`    |
| `gates.janet`      | symbols a configuration does not export | —             |

The file is named after the script, except that `gates.janet` writes
`gated.txt`; it builds every configuration it compares and takes about two
minutes. `seam.janet` reports a name no mechanism publishes, and any
`extern fn janet*` declared outside `host/cabi.zig`, as a finding.
`optionals.janet` counts a bare `orelse unreachable` as well as `.?`.
`references.janet`'s `c-era` class is a bounded backlog. Each `.txt` file's
header defines its classes.

Rows print `file:line`. `layouts`, `callconv`, `orphans` and `references`
compare rows by file and name, so a line number that has moved does not fail
`--check`; regenerate to refresh it.

### Reports

| script                 | reports                                             |
| ---------------------- | --------------------------------------------------- |
| `chronology.sh`        | migration citations, bad `-D` options, dead paths   |
| `swallowed.janet`      | raises reported across the C ABI and never consumed |
| `comments.janet`       | comment text for reading against `STYLE_GUIDE.md`   |
| `image-diff.janet`     | core image size, host paths, and bytes vs a copy    |
| `image-semantic.janet` | two images compared by meaning, not source position |
| `wasm_imports.zig`     | wasm imports from outside `wasi_snapshot_preview1`  |

`chronology.sh` and `swallowed.janet` are silent on a clean tree.
`chronology.sh` looks for migration citations and `-D` options `build.zig` does
not declare in shipped source (`src/`, `test/`, `examples/`, `build.zig`), and
for names of files that do not exist anywhere in the tree. `comments.janet`
extracts every Zig comment and Markdown paragraph to one file per source under
`zig-out/comments` and gates nothing.

`image-diff.janet` counts the absolute host paths the image embeds, which must
be zero; `--save FILE` on one host and `--against FILE` on another compare its
bytes. `image-semantic.janet` compares each binding's value, docstring and
bytecode with `:source-map` ignored, so a change that moves a cfunction's
registration line changes the bytes and not this comparison. `zig build` runs
`wasm_imports.zig` on wasm targets.

## testing

| script         | what it runs                                          |
| -------------- | ----------------------------------------------------- |
| `contract.sh`  | one or more contracts, one process each               |
| `leaks.sh`     | the leak check over every contract, or the named ones |
| `matrix.janet` | the acceptance matrix                                 |
| `mutate.janet` | the mutation sweep                                    |

`contract.sh` and `leaks.sh` run the driver in `zig-out` and do not build it.
`leaks.sh` is macOS only; its expectations are in the script, so a difference
is a non-zero exit.

`matrix.janet` covers configurations, optimize modes and cross-compiles. Set
`contracts-default` at its head to the change's own contracts.
[`acceptance-matrix.md`](testing/acceptance-matrix.md) has the operational
detail.

`mutate.janet --src <file>` is repeatable and sweeps the sources in order under
one warm-up and one log; `--all` sweeps every source under `src/` and takes
about thirty hours. A bare invocation prints its usage. An interrupted sweep
leaves its current mutant in the working tree. Read
[`mutation.md`](testing/mutation.md) first.

## bench

`layout.sh` runs one binary over a corpus across N stack layouts and reports the
minimum per workload.

The goal is to run within 10% of the C implementation. Running `layout.sh` over
this tree's binary and over a C Janet binary measures that goal, and running it
over two builds of this tree measures a change. A change that touches an
interpreter or value hot path is measured before it is accepted. Read the header
before reading a result: it names the control workload, the size a difference
needs before it counts, and why the first round of a session is discarded.

Rewriting a loop on a hot path counts as such a change, even when the rewrite is
a compile-time no-op. A Zig `for` over a sub-slice with a pointer capture keeps
both the element pointer and the counter live, so each iteration has three
induction updates where an index loop has two; converting `runtime/value.zig`'s
hash probe that way cost 1–4% on `methods`. The corpus cannot resolve a
difference that small. An isolated benchmark of the one function and
`otool -tV` on both binaries can.

The corpora are beside the scripts: `interpreter/` is the general workload,
`value/` is the value-access workload, `collections/` reads a collection's
elements, `maps/` measures small persistent maps against structs, and
`hashbench/` is a hash workload from upstream. A corpus is
written for the increment that needed it and says so in its header, so reach
for the one whose subject the change touches rather than the newest.

## repo

Chores, run occasionally and by hand: `tm_lang_gen.janet` emits the TextMate
grammar, and `removecr.janet` strips carriage returns.
