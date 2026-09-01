# Development instruments

Everything here is run by hand. None of it is a build step, and `zig build`
reaches none of it.

They are grouped by the question they answer:

| directory | the question |
| --- | --- |
| [`check/`](#check) | **has the tree changed?** — inventories compared against a checked-in copy |
| [`testing/`](#testing) | **does it still work?** — the drivers that build and run things |
| [`bench/`](#bench) | **how fast is it?** — the benchmarks and their corpora |
| [`repo/`](#repo) | chores about the repository rather than the runtime |

`common.janet` at the top is not a tool: it is the module the Janet scripts
share. It stays out of the subdirectories because it is what tells them where
the repository root is, and it finds that by counting one directory up from
itself.

**A script is part of a deletion, and twice now one has not been.** A Janet
string is not a compile error, so a tool that names a file which has moved
keeps working until somebody runs it — and these are run by hand, sometimes
phases apart. Grep this directory for the name of anything you delete or move,
and make the result part of the same change.

Every script has its reasoning in its own header. Read that before changing or
running one; the point of them is that the measurements a change owes are made
the same way every time.

## check

Each of these compares the tree against something recorded and fails on a
disagreement. `--check` is the ratcheting form; run without it, four of them
rewrite the file they compare against.

| script | what it measures |
| --- | --- |
| `exports.janet` | what the shared library publishes, classified → `exports.txt` |
| `layouts.janet` | the fixed C-compatible layouts and their residue → `layouts.txt` |
| `seam.janet` | every `c.janet_*` name the tree spells and what publishes it, plus the sweep for an `extern fn janet*` declared outside `cabi.zig` → `seam.txt` |
| `counters.janet` | every signed loop counter that indexes a container, classified by what it is signed *for* → `counters.txt`. It exists because Zig catches none of this: a mixed-signedness comparison compiles, `for (0..x)` accepts an `i32` bound, and a same-width `@intCast` is a legal no-op. Class `e` is residue and must be empty |
| `gates.janet` | which symbols a configuration does not export, by building thirteen of them and reading their symbol tables → `gated.txt`. About two minutes, and it exists because the question cannot be *read*: `root.zig`'s comptime block does not name every file it compiles |
| `swallowed.janet` | raising functions that reach a raise through an abi, where the report has no consumer. Four seconds, silent on a clean tree |
| `image-diff.janet` | the core image's size, the absolute host paths it embeds, and its bytes against a saved copy (`--save` on one host, `--against` on the other) |
| `chronology.sh` | every comment in `src/zig`, `test/` and `build.zig` that cites the migration -- a phase, a part, a retired file name, a `-D` option no build offers -- rather than the code. Silent is clean. Not a build check, deliberately: a prose rule is reviewed, not compiled |
| `image-semantic.janet` | the same two images compared by what they *mean* — every binding's value, docstring and bytecode, with `:source-map` set aside. The byte diff is the right oracle for a marshal width and the wrong one for a pass that edits files: the image records the line each cfunction was registered on, so any change to a file's length moves it |

`layouts.txt`'s rows carry line numbers, so a deletion above a fixed layout
moves one and the file is regenerated. The other three are insensitive to where
in a file something sits.

## testing

| script | what it runs |
| --- | --- |
| `contract.sh` | build and run one contract against whatever is in `zig-out` |
| `leaks.sh` | the leak check, all 65 contracts in about 42 seconds. It does **not** use `leaks --atExit`, because that mode hangs on a contract that forks — its header has the mechanism. The expectations are in the script, so a difference is a non-zero exit |
| `matrix.janet` | the acceptance matrix: 34 entries over configurations, optimize modes and cross-compiles. Set `contracts-default` at its head to the change's own contracts. [`acceptance-matrix.md`](acceptance-matrix.md) has the operational detail |
| `mutate.janet` | the mutation sweep. **A bare invocation starts one** — it prints its three known defects, which reads like a usage message and is not one, and an interrupted sweep leaves its current mutant in the working tree. [`mutation.md`](mutation.md) first |
| `afl/` | the AFL fuzzing harness, inherited from upstream Janet and separate from `zig build fuzz` |

## bench

`layout.sh` runs one binary over a corpus across N stack layouts and reports
the minimum per workload; `upstream.sh` does that for this tree against
upstream Janet's C, same compiler backend and same layout sweep.

The corpora are beside them: `interpreter/` is the general workload, `value/`
the value-access one, and `hashbench/` a hash-specific one from upstream.

## repo

Chores, run occasionally and by hand: `gendoc.janet` builds the HTML
documentation, `tm_lang_gen.janet` emits the TextMate grammar,
`removecr.janet` strips carriage returns, `update_copyright.janet` bumps the
years, and `msi/` is the Windows installer's source.
