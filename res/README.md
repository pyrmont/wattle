# Resources

The development instruments, and the shell completions. Every instrument is run
by hand, with three exceptions: `zig build` compiles `check/wasm_imports.zig`
and runs it against each wasm32-wasi binary it produces, it compiles
`tools/layout.zig` into `<prefix>/test`, and it compiles `tools/pty.zig` into
`<prefix>/test`, which `zig build test` runs through
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
| `bench-arms.janet` | whether a corpus's two arms agree       | —             |

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
not declare in shipped source (`src/`, `test/`, `examples/`, `build.zig`), and,
across the whole tree including the top-level documents and `res/`, for the
four retired names its header lists. That third question is a fixed
alternation rather than a derived one: its scope is the whole tree, but it is
silent on any path retired since the list was written, and it is not the
general question of whether a named file exists.

`comments.janet` extracts every Zig comment and Markdown paragraph to one file
per source under `zig-out/comments` and gates nothing.

`image-diff.janet` counts the absolute host paths the image embeds, which must
be zero; `--save FILE` on one host and `--against FILE` on another compare its
bytes. `image-semantic.janet` compares each binding's value, docstring and
bytecode with `:source-map` ignored, so a change that moves an nfunction's
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

## tools

`layout.zig` is built as `<prefix>/test/wattle-layout` on every target but
wasm. It reads a buffer on standard input and prints the line editor's layout
of it as a picture, one bracketed row per terminal row, placed by
`layout.position` alone:

```sh
printf '(defn f [x]\n  (+ x 1))\n' | zig-out/test/wattle-layout -w 20 -p 9 -o 11
```

It imports the `lineedit` module rather than a copy of it, so it runs the code
the editor runs, without a terminal and without the runtime. Its header has the
flags and the output format. The layout's `test` blocks use the same picture,
through `picture.draw`.

`pty.zig` is built as `<prefix>/test/wattle-pty` on every target but wasm and
Windows. It runs a command behind a pseudo-terminal, types at it, and prints
the bytes the command wrote, or with `-s` the screen those bytes draw:

```sh
zig-out/test/wattle-pty -s -w 'repl:1:> ' -i '(+ 1 2)\r' -- zig-out/bin/wattle -q -n -R
```

Input waits for text in the output, with `-w` and with `\m{text}` inside the
input, rather than for a duration, because an editor that has not yet set raw
mode discards what it is sent. The screen is a model of a terminal written for
the harness, and it does not import the `lineedit` module, so a case compares
the editor against a separate account of what its bytes draw. Its header has
the flags, the input escapes and what the model applies.

## bench

`layout.sh` runs one binary over a corpus across N stack layouts and reports the
minimum per workload. `yardstick.sh` is what produces the ratio against C
Janet: it drives `layout.sh` once per arm and divides, comparing the name
columns before dividing anything, so a corpus whose two arms report different
workloads is caught rather than silently aligned.

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

Every corpus has two arms, a `.janet` for the C Janet binary and a `.wattle`
for ours, and `res/check/bench-arms.janet` derives that the two are the same
program. The corpora are beside the scripts: `interpreter/` is the general
workload, `value/` is the value-access workload, `collections/` reads a
collection's elements, `maps/` measures small persistent maps, `vectors/`
measures persistent vectors against tuples and arrays, and `hashbench/` is a
hash workload from upstream. A corpus is written for the increment that needed
it and says so in its header, so reach for the one whose subject the change
touches rather than the newest.

## repo

Chores, run occasionally and by hand: `tm_lang_gen.janet` emits the TextMate
grammar, `removecr.janet` strips carriage returns, and
`janet-to-wattle.janet` rewrites Janet source as Wattle source.

**The instruments here stay Janet.** They run on whatever `janet` is on the
PATH, never on the build under test, and nothing here is loaded by Wattle, so
the parser swap does not reach them. `bench/`'s corpora are the exception: each
has a `.wattle` arm the wattle binary runs, beside the `.janet` arm C Janet
runs.

`janet-to-wattle.janet FILE.janet ...` writes the `.wattle` file beside each
and reports every site it changed in a way a reader should look at; `--dry-run`
reports without writing, and the exit status is non-zero where a site had no
Wattle spelling at all. It substitutes one lexical form at a time and copies
everything else through, so its output diffs against its input line for line.
It converts syntax and not meaning: a `.janet` path inside a string, and a
macro that builds code as `['if ...]`, are untouched. `notes/LANGUAGE.md` says
what it converts and what it leaves.
