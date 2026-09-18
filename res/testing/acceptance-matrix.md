# Acceptance matrix

*Moved verbatim from the former root `AGENTS.md` on 2026-08-30. Read this before configuring or running `res/testing/matrix.janet`, interpreting its timing and flaky results, or changing its contract population.*

## The acceptance matrix

`res/testing/matrix.janet`. Set `contracts-default` at its head to the increment's own contract
files — that is the only per-increment edit it needs.

**`zig fmt` is `zig fmt src test build.zig`, and not `port/` or `res/`.** The spike
corpora under `port/` are historical sources kept as
they were measured, and they are not `zig fmt` clean; reformatting one edits a
record. `matrix.janet`'s preflight checks the tree the build compiles, which is
the right population.

**Read it per entry before believing its total.** The summary line is
`X wall (Y of work)`, and `Y` is the *sum of per-job wall times* rather than
CPU, so two jobs stalling under `-j2` doubles both numbers and reads like a
systematic slowdown. Phase 13 increment 3b reported 550s against the usual
278s; thirty-two of the thirty-four entries were within a second of the
previous run and the two that were not had been in flight together. Re-running
those two alone gave normal times on a colder cache. Diff the per-entry times
against the last run first.

**A `-D` option the matrix never selects is a configuration nobody has ever
built.** Increment 3a found the poll event-loop backend in exactly that state:
`build.zig` picks epoll on Linux and kqueue on the BSDs and macOS, so poll is
reachable only through `-Dkqueue=false` or `-Depoll=false`, and it did not
compile — five errors, every one of them pre-existing at `HEAD`. That is Phase
11's rule 72 (a comptime-false arm is *unchecked* code, not dead code) at the
scale of a whole subsystem, and the `poll backend` entry is what keeps it read.
When a part touches something a feature flag selects, ask which flag
combinations the matrix actually reaches — the population is `zig build -h`'s
option list, not this file's job list.

**Setting `contracts-default` is not the whole of retargeting the matrix.** Three
increments in a row tripped over the same thing, in three different ways:

  - Part 17d named `pp`, and the printer's contracts are `pp_describe.c`,
    `pp_format.c` and `pp_pretty.c`. Twenty entries failed at once with
    `test/pp.c:1:1: error: CacheCheckFailed`, which names a missing file as
    though it had a compile error in it.
  - Part 17d then named `ev_core`, which `-Dsingle-threaded=true` cannot
    compile, because that configuration has no event loop and `janet.h`
    declares neither the channel API nor `JanetStream`.
  - Part 17e named `peg`, which `-Dpeg=false` cannot compile, because
    `janet_peg_type` does not exist there.

So, per increment: **check every name in `contracts-default` is a real `test/*.zig`**,
and then ask of each reduced configuration whether the types that contract
names still exist there. When one does not, that is what `skip=` is for --
`Job("contracts", "no peg", ["-Dpeg=false"], skip=("peg",))`.

**A *suite* a configuration cannot load is `build.zig`'s to skip, not
`skip=`'s.** `skip=` names contracts. A Janet suite resolves its bindings at
compile time, so one naming a binding the build did not register refuses to
load and takes the whole file with it — there is no per-case skip to reach for.
`build.zig`'s `test_suites` list carries the condition instead: an entry marked
`needs_os = true` is not scheduled under `-Dreduced-os=true`. Seven of the 35
are marked, which is why the `reduced os` entry became a `full` job at Phase 16
Part 4 after years as a `contracts` one — until then every suite there failed
to compile on `test/helper.wattle`'s first line.

**Two more, from Phase 11 Part 20, and the preflight catches neither.**

  - **A contract a configuration does not *compile* fails the same way a
    missing file does, and its name is not the clue.** `-Dreduced-os=true`
    compiles no process subsystem, so naming `os_process` in `contracts-default` got
    `contracts: os_process was not compiled into this binary` and an exit code.
    The preflight checks that every name is a real contract *file*, and this
    one is; only `skip=` fixes it. Ask of each reduced configuration not just
    "do the types this contract names still exist" but "is this contract
    compiled at all".
  - **A contract that owns a fixture anywhere may not be named, not only one
    that writes to the working directory.** `os_surface` writes only under
    `/tmp` — Phase 10 Part 12 moved it there — and still cannot be named,
    because two `contracts` entries run concurrently on the same *host* as well
    as in the same directory, and both would build
    `/tmp/wattle-os-surface-contract`. The rule below is about a shared fixture;
    the working directory is only where one usually is.

**Since the hinge, `matrix.janet` refuses to start rather than letting you find
this out one entry at a time.** A preflight checks, in about a second and with
no build at all, that every `contracts-default` name is a real `test/*.zig`, that
every `-D` option every job passes still exists in `build.zig`, and that
`zig fmt --check build.zig src test` is clean; it reports
*all* the problems at once.

**The formatter is enforced there and deliberately not in CI.** Phase 12
increment 4 found fifteen files that had drifted out of `zig fmt` -- eight
under `src/`, seven under `test/` -- because nothing ran it. The drift is
invisible in review, since the diff of a reformat is every line of the hunk,
and it is not a per-configuration question, so it is one run over the tree
before the first build rather than a job. If it refuses, the message names
every file and the one command that fixes them. That is worth stating as a lesson rather than as a
feature: **everything above was already written down here, in prose, and it did
not prevent the mistake.** One session lost two matrix runs to exactly the two
traps this section describes -- `pp` in `contracts-default`, and six selectors the
hinge had deleted -- and each cost minutes to surface because the run
discovered them serially. A check that runs before the first build is worth
more than a paragraph that runs before the first mistake.

The same session added the other half: **a contract that fails to *compile*
aborts the run and names the fix**, because every other entry that compiles it
will say the same thing and the verdict has to be thrown away anyway. A
contract that compiles and then *fails* does not abort -- that is a real
result, and "count the FLAKYs first" below needs the whole picture.

**The matrix is thirty-four entries**, and the twelve that took it from
twenty-one to thirty-three are why this paragraph bites harder than it used
to. The population of configurations is `zig build -h`'s option list -- 39 of
them -- rather than this file's job list: the matrix samples what is worth
*running*, which is a different question from what is worth *compiling*. Two
bugs came from confusing them. A sweep of only what the matrix named would
have transcribed `JANET_VM_HAS_INTERRUPT` as a constant, and a set of
`@hasDecl` probes went silently always-true in exactly the builds nothing here
compiled. So the remaining reduced-feature options and the four cross-compiles
are entries now, build-only, and the hand-rolled sweep that found both bugs
has been folded in rather than kept. 263s at `-j2` for thirty-three, against
186s for twenty-one.

**Do not hand-roll a reduced-configuration sweep beside the matrix.** Phase 11
Parts 7 and 8 each did, over thirteen configurations, and `matrix.janet` covers
twelve of the thirteen. A cold build in a throwaway cache is 11s, so the loop
cost about what the whole matrix costs (172s at `-j2` for twenty-one entries)
and checked strictly less — no suites, no optimize modes, no Rosetta, no
cross-compiles. Set `contracts-default` and run the matrix. Hand-roll a configuration
only when the matrix genuinely lacks it, which so far means `-Ddocstrings=false`
and its successors under `phase_11.md`'s rule 19.

**The cadence is matrix per increment, container at the gate**, and that is
Phase 10's practice rather than a new rule: nineteen matrix runs are recorded
in `src/README.md`, one per increment, against a podman recipe that had run
twice in the project's life. `phase_11.md`'s "What each increment runs" has the
table and the argument for why a configuration failure found late is worse than
it looks -- it is a `harness.zig` change to retrofit, not one contract to fix.

**Run the cheap check before the expensive one, and the cheapest is a
build-only sweep.** The matrix builds every configuration and then tests it; a
loop that only builds them costs a fraction and finds the whole class of
"an arm the host never compiles". The hinge shipped three such faults --
`-Dgc-mark=c` and `-Dabstract-core=c` segfaulting, `-Dev=false` failing to
compile -- and a build-only pass over the matrix's own flag sets found all
three in the time the matrix takes to reach its fifth entry. Do that first,
fix what it names, and spend the matrix once.

**The selector-arm sweep is retired.** It was one line per surviving `c` arm,
and Phase 10 Part 18 spent the last twenty-nine along with
`SubsystemImplementation` itself. `zig build -h` reports no `(c or zig)` option
and `src/` holds no `.c` file, so there is no second implementation for a
configuration to select. What the sweep was *for* -- an arm the host never
compiles, which rule 5 says is unanalysed -- is now covered only by the
cross-compiles and the reduced-feature configurations (`-Dev=false`,
`-Dpeg=false`, `-Dnanbox=false` and their kin), which are still real uncompiled
arms and still worth the matrix.

Two diagnostics make this quick. **If the failures partition exactly along
`Job` kind** -- every `full` passing and every `contracts` failing -- it is the
contract list, because that is the only thing the two kinds differ in. And a
contract that cannot compile in a configuration fails at `cc <name>`, before
any assertion runs.

**Use `-j2`.** `zig build` is already parallel and already saturates the
machine, so past two the added contention cancels the added concurrency exactly:

| jobs | 1 | 2 | 3 | 4 |
| --- | --- | --- | --- | --- |
| wall | 188s | 143s | 160s | 155s |

Give each *job* its own cache directory, not each worker slot. A pool hands the
next task to whichever worker frees first, so a slot reused `j` positions later
collides with the job still holding it; the symptom is `failed to rename
compilation results into local cache: FileNotFound`, which names nothing useful.

**A parked entry poisons the rest of the run, so read FLAKY before FAIL.**
A park holds `matrix.janet`'s suites lock for its whole 300-second bound, and the
other worker can only build meanwhile; when the lock finally releases the
queued test steps bunch. Phase 10 Part 17e watched a run with **three** parks
produce two FAILs -- `call trampoline` and `value-wrap=c`, both on
`error: deadline expired`, which is a wall-clock assertion in
`suite-ev.wattle` -- that had passed cleanly in a run with one park an hour
earlier, and passed again in sixteen seconds each when re-run on a quiet
machine.

So: **count the FLAKYs first.** A run with two or more is measuring a disturbed
machine, and a timing-sensitive FAIL in it is not evidence of anything. Re-run
the failing entries alone with `--only` before believing them; it costs
seconds, and it is the difference between a defect and a queueing artefact.

**A zero-FLAKY, zero-FAIL run can still be a disturbed one, and Phase 11 Part
6 found that gap.** That matrix took **1079s against the usual 171s** and
reported nothing: six entries, in three concurrent pairs, ran at about twenty
times their normal cost while the other fifteen were normal. Neither the
300-second test bound nor the 900-second build bound was reached, so no FLAKY
and no FAIL was raised.

The discriminator is the same one used for a suspicious failure, and it costs
seconds: **re-run one slow entry by hand.** `-Dffi=false` was 320.6s in that
matrix and **16.0s** standalone, which settles it as the machine rather than
the code.

So: **read the per-entry times even when every verdict is PASS.** A run whose
wall time has moved by an order of magnitude has not measured what it usually
measures, and the next thing to check is the disk -- `df -h`, then
`du -sh /tmp/wattle-*`, then `tmutil listlocalsnapshots /` -- exactly as for a
FLAKY.

**A zero-FLAKY run is not a quiet run, and Part 17f found the gap.** A FLAKY is
the 300-second hang bound; a suite assertion that fails *fast* is a plain FAIL
and raises no FLAKY at all. That part's matrix reported one FAIL and zero
FLAKYs -- `vm-entry=c` on `error: deadline expired` -- and the entry passed four
times out of four when re-run alone. `deadline expired` is `suite-ev.wattle`
asserting against a wall clock, so it belongs to the same family as the FLAKYs
whatever the count says.

Two rules follow. **Any failure whose message names a clock -- `deadline
expired` above all -- is re-run alone before it is believed**, regardless of the
FLAKY count. And **the tree and the machine are frozen for the duration of a
matrix run.**

That second rule is not only about load, and Part 17f broke it twice in one
afternoon to find out. Running a `wc` and a `grep` during one matrix produced
the spurious `deadline expired` above. Then, during the *next* matrix, editing
three source files produced three FAILs -- `filewatch-core=c`,
`value-access=c`, `buffer-array=c` -- which were nothing but half-applied
edits: **`matrix.janet` builds from the working tree as it goes**, so an edit
landing mid-run gives some entries the old sources and some the new, and the
whole run is void.

**`deadline expired` has a rate, and it is about one per matrix.** Part 17f ran
the 53-entry matrix three times and saw it three times, on a *different* entry
each run -- `vm-entry=c`, `registry=c`, `call trampoline` -- with zero FLAKYs
each time. Every one passed four times out of four when re-run alone. It is
`suite-ev.wattle` asserting against a wall clock while two entries compete at
`-j2`, and it attaches to whichever entry happens to be running, which is
exactly why it reads as a finding about that entry.

So a 53-entry run at `-j2` that reports one `deadline expired` and nothing else
**has passed**, once the entry is confirmed alone. Two or more, or any failure
that is not a clock, is a different matter.

So: finish and save every edit before starting a run, and then touch nothing --
no edits, no `wc`, no `grep`, no second build. If something has to change while
one is running, kill the run and say the result is void rather than reading it.
When a run does fail, the first question is "did I touch anything while it
ran?", because that failure looks exactly like a real one and costs the same
seven minutes to disprove.

**A host that has slept is a disturbed host, and it stays disturbed for a
while.** Phase 13 increment 6e's matrix reported **1694.2s** against the usual
278s, with one FLAKY and six PASSes between 328s and 395s; `df` showed 61 GiB
free and nothing was above 5% CPU when it finished. Every slow entry was
normal alone — `no event loop` 324.4s in the run and **16.2s** with `--only` —
and a full re-run was clean but still took 1017.3s. The machine had slept
earlier in the session and had not settled.

Two things follow. **A benchmark that spanned a sleep is a benchmark to
re-take**: 6d read `arithmetic` at +2.98% and then -0.93% on two passes of the
same binary, which is the same rule as "the tree and the machine are frozen
for the duration of a run" arriving from the machine's side rather than
yours. And **a run's wall time and its verdict answer different questions** —
record the verdict you got and say the host was loaded, rather than re-running
until the clock looks familiar.

**A FLAKY entry is a disk question before it is a code question.** Phase 10
Part 17e saw two entries hit the 300-second hang bound in sixteen -- against a
known park that Part 16 characterised at twice in about a hundred -- and spent
a while suspecting the increment, which had just changed how a builtin raises.
It was not the increment. The volume was at **94% capacity**, with 5.6 GB of
that day's own throwaway caches still in `/tmp`, and a matrix at `-j2` deposits
about 100 MB per entry on top.

So when an entry hangs, in order: `df -h`, then `du -sh /tmp/wattle-*`, then
`tmutil listlocalsnapshots /`, and only then the code. The reason this ordering
is worth writing down is that the code hypothesis is the interesting one and
therefore the tempting one -- 17e had *already* found a real hang that morning,
which made a second one look like a pattern.

What actually distinguishes them is cheap: **a mechanism bug reproduces
serially.** Twenty-four suite runs, eight contract runs, three full
`zig build test` runs on the suspect selector and six concurrent pairs all came
back clean, which is not what a broken raise protocol looks like.

**Every command in an entry is bounded, and results print as they land.**
Added in Phase 10 Part 16, which lost thirty-six minutes to neither: a
`zig build test` in the *default* configuration parked in `kevent` with an
empty kqueue -- `suite-ev.wattle` waiting on a task nothing could complete --
and because `as_completed` had nothing to time it out and the log was written
only at the end, the run produced no output at all. A hang is now a FAIL for
that entry, at 900 seconds for a build and 300 for anything else, and every
verdict is printed as it arrives. **A matrix that prints nothing is not a
matrix that is working.**

**Only one entry runs the Janet suites at a time, and that is not an
optimisation.** The suites share three fixtures with every other concurrent
run: `suite-ev.wattle` binds a fixed port 8761, `suite-net.wattle` binds a fixed
`/tmp/wattle-suite-net.sock`, and `suite-ev.wattle` and `suite-bundle.wattle`
create `unique.txt` and `tempdir123` **in the repository working directory**.
Two overlapping `full` entries therefore cross-connect. Usually one fails in
`net/read`; occasionally one parks in `kevent` and never returns, which is the
hang that cost Part 16 its first matrix run.

Measured at **17 failures in 32 two-at-a-time runs, 8 on one arm of the
selector under test and 9 on the other** -- and that even split is the whole
argument, because it is what distinguishes a shared fixture from a defect in
the code being tested. A one-armed failure would have been the port's; an even
one cannot be. `matrix.janet` now compiles concurrently, which is where the time
goes, and takes a lock to run. `JANET_TEST_PORT` is also set per slot, but that
fixes only the first of the three -- the other two are cwd- and /tmp-relative
and cannot move without editing the suites.

**What each entry runs matters more than how many run at once.** A full
`zig build test` entry is 24s, of which 14 are the library; library plus the
increment's own contracts is 20s. `matrix.janet` keeps the full `test` for the four
entries where catching a regression *outside* those contracts is the point — the
default, every selector `c`, and one release mode — because a misplaced
`#endif` shows up as a suite failure, not a contract failure. (`-Dboot=zig` was
a fourth until Phase 10 Part 17g removed `-Dboot` altogether; the generator has
no other arm now.)
`--all-full` restores the old behaviour for every entry except reduced-OS, whose
suites cannot run. Together with `-j2` that took Part 5's twenty-one entries
from 13m35s to 5m22s.

**Read the control before reading the workloads.** Phase 10 Part 16's first
benchmark run reported +39.5% on one FFI workload against a control of -11.0%,
and the control was the more important number: an eleven-point floor meant the
corpus could not resolve anything, and five workloads sat under it unreadable.
Fixing what the outlier pointed at -- an allocation on every call -- moved the
control to +0.2% as a side effect of changing the code layout, and *then* two
further regressions became visible that had been invisible before, one of them
at +17.7%.

So a corpus whose control is large has not measured its workloads yet, whatever
they say. Report the control first, and treat a workload that moves a long way
between runs of the same corpus -- Part 16 had one read +10.3%, +5.8% and
+13.3% -- as layout rather than as a property of the code.

**Phase 10 Part 17b sharpened that into something cheaper and stricter: run the
harness against itself.** A control workload measures a different code path and
tells you the floor only by inference; passing the *same binary* as both
arguments measures the harness, and the answer is the floor directly:

    ./res/bench/value/run.sh ./zig-out/bin/wattle ./zig-out/bin/wattle 5     # should be zeros

On a corpus of 30-60ms workloads that run reported **-5.2% on one workload and
+3.7% on another, comparing a binary with itself.** Every reading 17b had taken
from that corpus -- including two that agreed in direction across both pairings
and looked like findings -- was inside it.

The cause is ordering: `run.sh` runs base then candidate within each round, and
taking the minimum over five rounds does not cancel a bias that is present in
every round. Interleaving was introduced to cancel thermal drift and it does;
it does not cancel this.

**For a short-workload corpus, measure each binary alone instead.** Seven runs
of each, minimum per workload, compared afterwards:

    for i in $(seq 7); do ./base/janet bench.wattle; done | ...min per workload
    for i in $(seq 7); do ./cand/janet bench.wattle; done | ...min per workload

That is what settled 17b: `threearg` read +5.3% and +6.4% interleaved and
**+0.0% alone** -- 57.087ms against 57.090ms, three microseconds apart.

**And underneath both of those: sweep the initial stack layout.** Phase 10 Part
17f measured the Phase 9 corpus's *control* at +48% and found no code
responsible. The kernel derives the initial stack pointer from the size of the
argv and environment block, and `pegmatch` is bimodal in that alignment: about
one environment size in twelve is ~48% slower, and both the baseline and the
candidate hit it once across twelve sizes.

    $ ./janet res/bench/interpreter/bench.wattle | grep pegmatch          # zsh
    pegmatch 0.038912
    $ bash -c './janet res/bench/interpreter/bench.wattle' | grep pegmatch
    pegmatch 0.057662
    $ PAD= bash -c './janet res/bench/interpreter/bench.wattle' | grep pegmatch
    pegmatch 0.039423

One empty environment variable, 48%. **This is not noise and no amount of
repetition removes it**: it is fixed for a given binary launched from a given
shell, so it survives the minimum over any number of runs, it survives
interleaving, and it survived the "measure each binary alone" recipe above --
which reported it twice, at +48.4% and +47.8%, stable to three digits.

    ./res/bench/layout.sh ./base/janet res/bench/interpreter/bench.wattle 12
    ./res/bench/layout.sh ./cand/janet res/bench/interpreter/bench.wattle 12

That varies the environment across twelve sizes and takes the minimum per
workload. With it the control returned to +0.8%, -0.0%, -0.6% across three
passes. What remains is resolution rather than precision: on that corpus,
**treat anything under about 5% as unresolved** -- 17f saw ±5% move on the
dispatch-heavy workloads between builds that differ only in which half of one
file is Zig.

**And the hinge measured `fib` above that, at up to +12%, from code placement
alone.** Three passes read +8.7%, +12.1% and +9.0% against a control sitting at
-0.7%, -0.6%, -0.2% -- stable, well clear of the ±5% floor, and on the
corpus's purest call workload. It was not a regression. Bisecting the commit
put the whole of it in a group whose changed lines are `janet_unmarshal_*`
callbacks for the int64 and RNG abstracts and the stack-trace chain walker,
**none of which `(fib 28)` can reach**. Unreachable code cannot cost 8%; only
where the linker put everything else can.

Two things follow, and the first is the useful one. **`fib`'s placement
sensitivity is ~9%, not ~5%, and it does not correlate with what the change
touched** -- so on that workload the 5% rule is too generous, and a reading
under about 12% is worth confirming before it is believed. The second is how
to confirm it cheaply: **ask what the changed lines are reachable from.** That
is faster and stronger than any number of re-runs, and it is what settled this
in one step after a perturbation experiment had already failed to. Appending an
inert exported function to `vm_run.zig` moved `fib` by -0.5%, which looked like
evidence that the workload was placement-*insensitive* and was simply one
sample of a lottery.

**There is no C in the tree any more, and two habits go with that.** The
deletion that ended it took 44 files and 38,558 lines out of `src/`; the last
`.c` under `test/` went with the suites a phase later.

The first habit is a *measurement*: when asking what C is left, ask the
archive rather than the files. `ar x zig-out/lib/libwattle.a` then `nm -gU` on
each member says what actually defines a symbol; a live-line count over the
sources says something much larger and much less useful, because most of what
survives a spent guard is *declarations* of Zig-defined symbols. Part 18 opened
against "519 live lines across thirteen files" and the archive said "eight
objects, forty symbols".

The second is a *warning*: **do not carve regions out of a C file by line
range.** It swallows `#if`/`#endif` pairs, and it did so twice in one session --
once in `strtod.c`, once in `asm.c`, which had to be restored from git and
redone by removing function bodies only. `phase_10.md` says Part 18 deletes
whole files rather than regions inside them, and this is why.

**Linux is a `podman run`, not a cross-compile, and until 2026-08-25 nobody had
made the distinction.** Every cross-platform instrument in this tree compiles:
five cross-compiles per increment, and a matrix that samples *configurations*.
Phase 10's exit gate says "on macOS and Linux" and `test/README.md` has carried
the recipe throughout; the first time it was run it found three failures, all of
them pre-existing and one of them present in the C arm too.

The cost is small enough that there is no excuse for skipping it:

    zig build -Dtarget=aarch64-linux-musl -Dcpu=baseline -Dinstall-tests=true -p xbuild/arm

That is 226 MB of throwaway cache and an 89 MB prefix, of which **13 MB — the
`wattle` binary — is what goes into the container.** `AGENTS.md`'s warning about
filling the podman VM is about copying `.zig-cache` in, which the recipe's
`--exclude` list exists to prevent. A 10 GiB VM is not the constraint.

Run it whenever an increment adds a platform-selected branch. Part 18 added
four — `statx`, `encodeDev`, `stdio.zig`'s glibc/musl arm and `os_locks.zig`'s
pthread arm — and *none of them had ever executed* before that run.
