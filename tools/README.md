# Development instruments

Everything here is run by hand. None of it is a build step, and `zig build`
reaches none of it.

They are grouped by the question for each directory:

| directory | the question |
| --- | --- |
| [`check/`](#check) | has the tree changed? Inventories compared against a checked-in copy |
| [`testing/`](#testing) | does it still work? The drivers that build and run things |
| [`bench/`](#bench) | how fast is it? The benchmarks and their corpora |
| [`repo/`](#repo) | chores about the repository rather than the runtime |

`common.janet` at the top is not a tool. It is the module the Janet scripts
share. It stays out of the subdirectories because it resolves the repository
root, and it does that by counting one directory up from itself.

A script is part of a deletion, and twice now a script has not been. A Janet
string is not a compile error, so a tool that names a file which has moved keeps
working until somebody runs it, and these are run by hand, sometimes phases
apart. Grep this directory for the name of anything deleted or moved, and make
the result part of the same change.

Every script has its reasoning in its own header. Read that before changing or
running a script. They exist so that the measurements a change owes are made the
same way every time.

## check

Each of these compares the tree against something recorded and fails on a
disagreement, except `comments.janet`, which extracts rather than compares.
`--check` is the ratcheting form; run without it, six of them rewrite the file
they compare against.

| script | what it measures |
| --- | --- |
| `exports.janet` | what the shared library publishes, classified, written to `exports.txt` |
| `layouts.janet` | the fixed C-compatible layouts and their residue, written to `layouts.txt` |
| `seam.janet` | every `c.janet_*` name the tree spells and what publishes it, plus the sweep for an `extern fn janet*` declared outside `host/cabi.zig`, written to `seam.txt` |
| (no script) | A loop on a hot path is measured before it is converted. Phase 15 Part 2a rewrote `runtime/value.zig`'s hash probe from an index loop to `for (buckets[start..]) \|*kv\|`. The rewrite is correct, idiomatic and a compile-time no-op, and it cost 1–4% on `methods`. A Zig `for` over a sub-slice with a pointer capture keeps both the element pointer and the counter live, so it has three induction updates per iteration where an index has two. Nothing in the tree can see this: it is not a type error, not a contract failure, not a divergence, and the ten-workload corpus cannot resolve it either (its control moved 3% in the series that showed the effect). The instruments that can see it are an isolated benchmark for that one function and `otool -tV` on the two binaries |
| `counters.janet` | every signed loop counter that indexes a container, classified by what it is signed for, written to `counters.txt`. It exists because Zig catches none of this: a mixed-signedness comparison compiles, `for (0..x)` accepts an `i32` bound, and a same-width `@intCast` is a legal no-op. Class `e` is residue and must be empty. It reported four of sixteen until Phase 15 Part 1b. The bound was captured with `(to ")")`, which stops at the first `)`, so every bound containing a call failed to match and was silently absent: `head(t).length` and `@as(i32, @intCast(argv.len))` are two of them. An inventory that undercounts is worse than no inventory, because it reads as clean. The capture runs to `") : ("` now |
| `optionals.janet` | every non-null assertion whose null the same function also tests, classified, written to `optionals.txt`. A function that tests `x` for null in one place and writes `x.?` in another is contradicting itself, and which of the two is wrong is decidable by reading one function, which is what makes this a check rather than a taste. Class `tested` must be empty. Two things about it are load-bearing. It counts a bare `orelse unreachable` as well as `.?`, because a class counting one spelling can be emptied by respelling every row rather than resolving a row, and an instrument satisfied without doing the work is worse than no instrument. Class `accumulator` exempts a local `var x: ?T = null` whose null test is its own "first pass yet" state, decided by the declaration's shape rather than by a hand-maintained list, because such a list is a place to hide a row. It cannot see a null tested by the callers rather than in the same function; that population is 521 lines and is Phase 15's hand-off |
| `gates.janet` | which symbols a configuration does not export, by building thirteen configurations and reading their symbol tables, written to `gated.txt`. About two minutes, and it exists because the question cannot be settled by reading: `root.zig`'s comptime block does not name every file it compiles |
| `swallowed.janet` | raising functions that reach a raise through an abi, where the report has no consumer. Four seconds, silent on a clean tree |
| `image-diff.janet` | the core image's size, the absolute host paths it embeds, and its bytes against a saved copy (`--save` on one host, `--against` on the other) |
| `chronology.sh` | three questions with different scopes. In shipped source, meaning `src/`, `test/`, `examples/` and `build.zig`, every comment citing the migration: a phase, a part, a retired file name. In shipped source again, a `-D` option this build does not have, derived from `build.zig`'s own `b.option` calls plus the three Zig declares, because the hard-coded list of retired suffixes it asked before fired on nothing. Anywhere in the tree, `DESIGN.md` and `tools/` included, a name for a file that does not exist. The second question is wide and the first is not. A decision record stating "measured at Phase 14 increment 4a" and an instrument's header stating why it has the shape it has are the citations the repository rules ask for, and asking the first question of those files returns hundreds of lines of which almost none is a finding. A retired file can be checked by looking, and that is what makes it the question that generalises. Its exemptions match against the line's content rather than the whole `grep -rn` row: matching the row exempted every file whose path contained an exempt name, which silently took all 69 top-level `test/*.zig` out of the first question. A silent instrument reads as a clean tree. Not a build check, deliberately: a prose rule is reviewed rather than compiled |
| `callconv.janet` | every definition in `src/` with `callconv(.c)`, classified by what reaches it that way, written to `callconv.txt`. A definition has the convention only if it is exported, called back by libc or the loader, or fills an erased slot; `DESIGN.md` section 9 has the boundary decision behind that rule. Phase 15 Part 5 met that clause by reading, and this asks it mechanically. The three shapes that spell `callconv(.c)` are an `extern fn` declaration, a function-pointer type and a definition, and only a definition is the population. Classes are `export`, `slot`, `callback` and `residue`, decided by what takes the address rather than by what the author meant. `residue` must be empty. On its first run it was 22 of 78 |
| `orphans.janet` | every `pub` declaration in `src/` that nothing in `src/`, `test/`, `examples/` or `build.zig` references in code, written to `orphans.txt`. A string literal is not code for this: `pub const date = @import("runtime/os/date.zig")` names `date` twice on its own line, so counting literals made `root.zig`'s namespace block exempt itself, and `debug.stacktrace` read as referenced because `corefn.reg` registers `"debug/stacktrace"` beside it when nothing calls it. `build.zig` refuses an unused file-scope `const`, but a `pub` file-scope `const` is invisible to it, and so is any declaration inside a container: `pub` says another file may use this declaration, and the build cannot ask whether a file does. Three populations of that shape were found by reading in Phase 15, being eighteen orphaned constants, five dead head accessors and one dead handle type, before this was written; on its first run it found 48 more. Classes are `surface` (`api/abi.zig`, `module.zig`, `runtime/capi.zig`, published by symbol, so no in-tree reference is expected), `namespace` (`root.zig`'s `@import` block, which is the runtime's namespace rather than a list of consumers) and `orphan`, which must be empty |
| `references.janet` | every identifier a comment in `src/` or `test/` names that the tree does not declare, resolved against every Zig file in the repository with comments and string literals stripped, written to `references.txt`. A literal is not code here for `orphans.janet`'s reason: `janet_addtimeout` and `janet_addtimeout_nil` resolved against a contract-only docstring that was the only place either was written. A comment describing the code beneath it does not drift. A comment naming another declaration does, because nothing binds the name in the prose to the name in the code, and a rename leaves every mention behind with no build, test or instrument reporting it. Measured at Phase 17 Part 2b: 239 of 262 camelCase names in comments resolved and 24 of 305 `janet_*` names resolved. That is one un-propagated rename, C to Zig, rather than a decay rate. Two shapes are gated because both are this tree's own: `camelCase` (Zig's function convention) and `janet_*` with `janetc_*` (the C-era symbols, `janetc_*` being the compiler's own family, ungated with the rest of `snake_case` until seven were found by reading). `SCREAMING_CASE`, `snake_case` and `Capitalized` are not gated, because a comment naming a C macro, a libc type or a std name is doing its job. Gating them costs 393 rows of which almost all are legitimate, measured before the file was written rather than assumed. A `std.`-qualified span is skipped for the same reason, and so is a span whose last component is a source suffix, which is a file name rather than a qualified declaration: `janet_features.h` split into a header that exists and a `janet_*` name that does not. `test/` is the larger half, at 328 rows to `src/`'s 262, and `harness.zig` is the worst of it, teaching the protected-scope API to every contract author using two names the tree does not have, four lines above a `defer` that calls the real function. Classes are `c-era`, a bounded backlog that reaches zero when the prose pass does, and `unresolved`, where the gate is that no row is new. The header counts each per directory so that finishing `src/` stays visible while `test/` has not started. Five of its rows were found by reading in the session that wrote it, and all five had survived a pass whose whole subject was the comments |
| `docblocks.janet` | every `///` block that a blank line or a `//` line separates from the declaration it documents, written to `docblocks.txt`. A doc comment attaches to the next declaration however far away it is, so an inserted section between a block and its subject silently moves the documentation onto whatever follows the gap. Nothing else in the tree can see that: `zig fmt` leaves it where it is, `build.zig` does not check it, and `references.janet` asks whether the names in a comment resolve, which they still do. The sentence is true and attached to the wrong declaration. Written at Phase 18 Part 8 because Part 7b had introduced a stranded block: `getRange`'s doc ended up on `bytesView` and survived a build, a full gate and a second session's review of that block's prose, exposed two parts later only by an unrelated name collision. A scan then found two more, one benign and one a real misattribution, and all three are the same shape, which is the argument for gating on shape rather than on a reading. One class, `stranded`, which must be empty. It was empty on the first run because both known sites were fixed first. It reads shape rather than meaning, so a block correctly adjacent to the wrong declaration stays invisible |
| `comments.janet` | every comment in the Zig and every paragraph in the Markdown, extracted to one text file per source file under `zig-out/comments`, which is gitignored. It records nothing and gates nothing; it writes extracts and reads the tree. It exists because `STYLE_GUIDE.md` states rules a grep cannot hold: "no metaphor", "a block states a fact and evaluates nothing" and "nothing stands in for the subject" are read against a sentence rather than matched against a pattern, so the reading is a model's with the guide open and this is the extraction half of it. A Zig block is a run of consecutive lines with the same marker, `//!`, `///` or `//`, with the marker and one following space stripped and the rest kept verbatim, so a fenced example inside a doc comment survives. A Markdown block is a paragraph outside a fence and outside indented code, with a heading a block of its own and table rows and block quotes skipped. Each block is preceded by its file and line, so a finding goes back to its site. Janet sources are out of scope, because their comments would need a third block rule |
| `image-semantic.janet` | the same two images compared by meaning: every binding's value, docstring and bytecode, with `:source-map` set aside. The byte diff is the right oracle for a marshal width and the wrong oracle for a pass that edits files, because the image records the line each cfunction was registered on, so any change to a file's length moves that line |

`layouts.txt`'s rows include line numbers, so a deletion above a fixed layout
moves a row and the file is regenerated. The other three are insensitive to
where in a file something sits. `docblocks.txt` has line numbers too and for the
same reason: a stranded block is identified by where it is.

## testing

| script | what it runs |
| --- | --- |
| `contract.sh` | build and run one contract against whatever is in `zig-out` |
| `leaks.sh` | the leak check, all 65 contracts in about 42 seconds. It does not use `leaks --atExit`, because that mode hangs on a contract that forks. Its header has the mechanism. The expectations are in the script, so a difference is a non-zero exit |
| `matrix.janet` | the acceptance matrix: 34 entries over configurations, optimize modes and cross-compiles. Set `contracts-default` at its head to the change's own contracts. [`acceptance-matrix.md`](acceptance-matrix.md) has the operational detail |
| `mutate.janet` | the mutation sweep. A bare invocation starts a sweep. It prints its three known defects, which reads like a usage message and is not a usage message, and an interrupted sweep leaves its current mutant in the working tree. Read [`mutation.md`](mutation.md) first |
| `afl/` | the AFL fuzzing harness, inherited from upstream Janet and separate from `zig build fuzz` |

## bench

`layout.sh` runs one binary over a corpus across N stack layouts and reports the
minimum per workload; `upstream.sh` does that for this tree against upstream
Janet's C, same compiler backend and same layout sweep.

The corpora are beside them: `interpreter/` is the general workload, `value/` is
the value-access workload, and `hashbench/` is a hash-specific workload from
upstream.

## repo

Chores, run occasionally and by hand: `gendoc.janet` builds the HTML
documentation, `tm_lang_gen.janet` emits the TextMate grammar, `removecr.janet`
strips carriage returns, `update_copyright.janet` bumps the years, and `msi/` is
the Windows installer's source.
