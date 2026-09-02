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
disagreement. `--check` is the ratcheting form; run without it, six of them
rewrite the file they compare against.

| script | what it measures |
| --- | --- |
| `exports.janet` | what the shared library publishes, classified → `exports.txt` |
| `layouts.janet` | the fixed C-compatible layouts and their residue → `layouts.txt` |
| `seam.janet` | every `c.janet_*` name the tree spells and what publishes it, plus the sweep for an `extern fn janet*` declared outside `cabi.zig` → `seam.txt` |
| — (no script) | **A loop on a hot path is measured before it is converted.** Phase 15 Part 2a rewrote `value.zig`'s hash probe from an index loop to `for (buckets[start..]) |*kv|` — correct, idiomatic, and a compile-time no-op — and it cost 1–4% on `methods`, because a Zig `for` over a sub-slice with a pointer capture keeps both the element pointer and the counter live and so carries three induction updates per iteration where an index carries two. Nothing in the tree can see this: it is not a type error, not a contract failure, not a divergence, and the ten-workload corpus cannot resolve it either (its control moved 3% in the series that showed the effect). The instruments that can are an isolated benchmark for the one function and `otool -tV` on the two binaries |
| `counters.janet` | every signed loop counter that indexes a container, classified by what it is signed *for* → `counters.txt`. It exists because Zig catches none of this: a mixed-signedness comparison compiles, `for (0..x)` accepts an `i32` bound, and a same-width `@intCast` is a legal no-op. Class `e` is residue and must be empty. **It reported four of sixteen until Phase 15 Part 1b**: the bound was captured with `(to ")")`, which stops at the first one, so every bound containing a call — `head(t).length`, `@as(i32, @intCast(argv.len))` — failed to match and was silently absent. An inventory that undercounts is worse than none, because it reads as clean; the capture runs to `") : ("` now |
| `optionals.janet` | every non-null assertion whose null the *same function* also tests, classified → `optionals.txt`. A function that tests `x` for null in one place and writes `x.?` in another is contradicting itself, and which of the two is wrong is decidable by reading one function — which is what makes it a check rather than a taste. Class `tested` must be empty. Two things about it are load-bearing: it counts a **bare** `orelse unreachable` as well as `.?`, because a class counting one spelling can be emptied by respelling every row rather than resolving one, and **an instrument you can satisfy without doing the work is worse than no instrument**; and class `accumulator` exempts a local `var x: ?T = null` whose null test is its own "first pass yet" state, decided by the declaration's shape rather than by a hand-maintained list, because such a list is a place to hide a row. It cannot see a null tested by the *callers* rather than in the same function; that population is 521 lines and is Phase 15's hand-off |
| `gates.janet` | which symbols a configuration does not export, by building thirteen of them and reading their symbol tables → `gated.txt`. About two minutes, and it exists because the question cannot be *read*: `root.zig`'s comptime block does not name every file it compiles |
| `swallowed.janet` | raising functions that reach a raise through an abi, where the report has no consumer. Four seconds, silent on a clean tree |
| `image-diff.janet` | the core image's size, the absolute host paths it embeds, and its bytes against a saved copy (`--save` on one host, `--against` on the other) |
| `chronology.sh` | **two questions with different scopes.** In shipped source -- `src/zig`, `src/boot`, `test/`, `examples/`, `build.zig` -- every comment citing the migration: a phase, a part, a retired file name, a `-D` option no build offers. Anywhere in the tree, `DESIGN.md` and `tools/` included, a name for a **file** that does not exist. The second question is wide and the first is not, because a decision record stating "measured at Phase 14 increment 4a" and an instrument's header stating why it has the shape it has are the citations the repository rules ask *for*; asking the first question of those files returns hundreds of lines of which almost none is a finding. A retired *file* can be checked by looking, which is what makes it the half that generalises. Silent is clean. Not a build check, deliberately: a prose rule is reviewed, not compiled |
| `callconv.janet` | every **definition** in `src/zig` carrying `callconv(.c)`, classified by what reaches it that way → `callconv.txt`. `DESIGN.md`'s D7 says a definition carries the convention only if it is exported, called back by libc or the loader, or fills an erased slot; Phase 15 Part 5 met that clause **by reading** and this asks it mechanically. The three shapes that spell `callconv(.c)` are an `extern fn` declaration, a function-pointer *type* and a definition, and only the last is the population. Classes are `export`, `slot`, `callback` and `residue`, decided by what takes the address rather than by what the author meant; **`residue` must be empty**. On its first run it was 22 of 78 |
| `orphans.janet` | every `pub` declaration in `src/zig` that nothing in `src/zig`, `test/`, `examples/` or `build.zig` references → `orphans.txt`. `build.zig` refuses an unused file-scope `const`, but a `pub` one is invisible to it — `pub` says another file *may* use this and the build cannot ask whether one does — and so is any declaration inside a container. Three populations of that shape were found by *reading* in Phase 15 (eighteen orphaned constants, five dead head accessors, one dead handle type) before this was written; on its first run it found 48 more. Classes are `surface` (`abi.zig`, `module.zig`, `capi.zig` — published by symbol, so no in-tree reference is expected), `namespace` (`root.zig`'s `@import` block, which is the runtime's namespace rather than a list of consumers) and `orphan`, which **must be empty** |
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
