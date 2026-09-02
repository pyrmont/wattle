# Mutation sweeps

*Moved verbatim from the former root `AGENTS.md` on 2026-08-30. Read this before running, repairing, or interpreting `tools/testing/mutate.janet` and its artifacts.*

**A bare `./tools/testing/mutate.janet` starts a sweep.** It prints its three known
defects first, which reads like a usage message and is not one. An interrupted
sweep leaves its current mutant in the working tree: `git status` after any
interruption, and restore the file it names before believing a later build.

## Mutation sweeps

**Not per increment** -- a sweep is deferred to a phase gate. The short
version: a sweep tests the tests, not the code, and every defect the rewrite
found came from something cheaper. Do not run one
for an increment unless asked. Everything below applies when you do run one.

### Three things are known wrong with it, and none is fixed

**Fix these before the next full sweep.** Phase 11 Part 29 ported the tool from
Python and deliberately changed nothing else, because each of the three alters
what a verdict *means* and the phase that owns the sweep should own them. The
same list is in the script's header and the script prints it on stderr at the
start of every judging run.

1. **The contract call is bounded at 600 seconds where a suite gets 12.** So a
   mutant that hangs the contract costs fifty times one that hangs a suite, for
   a program that normally returns in well under a second. `ev/backend.zig`
   *is* the event loop, so contract hangs are not the exception there: 186
   sites with even a tenth hanging is over three hours on that source alone.
   This has cost two runs — the Phase 11 gate's sample, which did not finish,
   and Part 29's own verdict probe, killed at ten minutes and leaving the tree
   mutated. `tools/sh` takes `:timeout`, so it is one argument.
2. **A site this configuration does not compile scores SURVIVED rather than as
   no effect.** Three of the gate's nine survivors were `WSAGetLastError` and
   `GetLastError` in Windows arms this host does not compile — 20% of that
   window was noise. Compare the built binary's **text section**, not the file:
   debug info carries line and column numbers, so a mutant that changes a
   line's length yields a different file with identical code, which is exactly
   the case being scored. `phase_11.md`'s rule 74 has the measurement.
3. **Then run `ev/stream.zig` and `ev/backend.zig` to completion**, which no
   sweep has ever done. The 16.4s-a-mutant figure holds only for the first,
   where nothing hung.

**A tool repaired twice and executed zero times has been reviewed, not tested**
— that is this instrument's whole history, and it is why the reminder is in
three places rather than one.

`./tools/testing/mutate.janet`, run from the repository root. Its header has the design;
two rules survive here because they
are about what you do *around* it rather than what it does.

**Never edit the file a sweep is mutating while it runs, and that includes an
edit you did not aim at it.** The harness restores from its own backup and will
silently discard anything else written in the meantime. Worse, an edit that
lands while a build is in flight takes the *mutation* with it, and unmutated
source is then scored as a survivor. Phase 10 Part 10 lost a whole pass that
way and did not notice until a survivor looked implausible and was checked by
hand; the log had both false survivors and false catches in it.

The way this rule actually gets broken is not a deliberate edit to the source.
It is a bulk `sed`, a `grep -l | xargs`, or a global rename whose *file list*
happens to include it — in that case, a one-word fix to three documentation
files, one of which was the Zig source. Reasoning "I am only touching docs" is
exactly the check that passes when it should not. `mutate.janet` now verifies
after every mutant that the file still holds what it wrote and aborts if not,
so the failure is loud rather than silent, but the abort costs you the run.

**Do not add assertions mid-sweep either, even to files it does not touch.** The
harness rebuilds and re-runs the tests for each mutant, so a test added midway
judges the later mutants and not the earlier ones, and the log stops being one
measurement. Let the pass finish, close the holes it found, then re-run over
*just the survivors* — which is also far cheaper than a second full pass, and
which `mutate.janet` prints the `--only` line for.

**Cross-compile before you sweep, not after.** The four targets cost about two
minutes:

```sh
for t in x86_64-linux-musl aarch64-linux-musl riscv32-linux-musl x86_64-windows-gnu; do
    zig build -Dtarget=$t --cache-dir /tmp/janet-xc -p /tmp/janet-out || echo "FAILED $t"
done
rm -rf /tmp/janet-xc /tmp/janet-out
```

A portability fault does not fail a mutant, it fails *every* build the sweep
attempts on that target — and since the sweep only builds for the host, it
fails none of them and the sweep passes clean. You find out from the matrix, at
the end, and then the fix changes the source the sweep was measuring and the
whole pass has to be run again. Phase 10 Part 11 lost about forty minutes that
way: `[*c]c.FILE` compiles on macOS, where `translate-c` renders `FILE` as a
complete structure, and does not on musl, where it is opaque. The same run
rejected `std.c.fstat`, which is `{}` on Linux.

The rule generalises past this project's targets: **the host compiles a great
deal that `std.c` does not promise**, and a construct whose *translation* is
per-platform is invisible until something else translates it.

Phase 10 Part 16 added a form that is not about translation at all: **a
comptime budget can be per-target.** `@setEvalBranchQuota` defaults to a
thousand backwards branches, and the FFI's calling machinery instantiates its
rung ladder once per return variant -- three on AAPCS64 and thirty-two on
Win64. The host never came near the limit and `x86_64-windows-gnu` failed
immediately, in `std.mem.asBytes`, naming a file that has nothing to do with
the cause. A build that is *bigger* on another target, not merely different, is
a thing only a cross-compile finds.

Phase 10 Part 14 added the third form this takes, and it is the quietest.
**A declaration can survive translation with its contents removed.** Windows'
`struct sockaddr_in6` ends in an anonymous union, and translate-c demotes any
record holding one to `opaque {}` -- so the type is there, the pointer to it
type-checks, and the failure arrives as "does not support field access" at the
use site rather than as a missing symbol at the declaration. `@hasDecl` says
yes. The same pass demoted `_IOW`, and with it `FIONBIO`, to a
`@compileError` that only fires if something names it. So a cross-compile is
the only thing that finds either, and the fix is a restatement in Zig with a
`comptime` assertion on `@offsetOf` to keep it honest -- `src/zig/net/abi.zig`
has both.

That file is one of the tree's three *host* translations, with `os/abi.h` and
`filewatch/abi.h`. The rule for adding one is in `os/abi.h` and has not
changed: a further translation is right when nothing it declares crosses a
subsystem boundary, and wrong when it does. `abi.zig`, the shared translation
of Janet's own headers those three were measured against, went with `janet.h`
at Phase 12 increment 5f.

**Phase 10 Part 16 added a third instrument, and on this machine it is the
strongest of them: Rosetta.** An `x86_64-macos` build *runs* on Apple silicon,
suites and contracts and all, so `zig build -Dtarget=x86_64-macos` followed by
`zig build test` executes a second architecture rather than merely compiling
one. That is how SysV64's calling convention stopped being unvalidated here --
`src/zig/README.md` had recorded for four parts that "end-to-end SysV calls
remain unvalidated here" -- and it costs about 46 seconds an entry. Use it
whenever the thing under test is architecture-specific and not merely
platform-specific. It does not replace the musl and Windows cross-compiles: it
reaches a second *ABI*, not a second libc.

**A cross-compile is not the only instrument that reaches unbuilt code, and
Phase 10 Part 15 is where the matrix caught what four cross-compiles could
not.** `-Dnanbox=false` failed to link `janet_wrap_integer`, because `janet.h`
declared the function beside the macro and `wrap.c` defined it only for the two
nanbox layouts. Every target compiles that call happily; only the tagged
*configuration* does not. So run the cross-compiles first, because they are two
minutes -- and then run the matrix before believing the increment is done,
because a configuration is as much an uncompiled arm as a platform is.

**Phase 10 Part 17g added the case the matrix cannot reach by design.** The
matrix samples *one selector per layer* -- deliberately, because sixty-odd full
entries is an hour -- so a selector that is not the sample is not built at all.
17g removed twenty-five `c` arms and broke a twenty-sixth, `-Ddisasm=c`, which
stopped linking because `asm_core.zig` imports `disasm.zig` by path and nothing
was left to select the C disassembler instead. Nothing in the matrix would have
said so.

The instrument is a sweep: `zig build -D<sel>=c` for every surviving selector,
one at a time, each with a throwaway cache. Thirty-nine of them is twenty-five
minutes, which is too much per increment and right for an increment that
*changes what a selector may be*. The arms it did not spend are the ones whose
neighbours just moved.

**An out-of-band report needs a scope-boundary assertion, or it costs days.**
The hinge gave the abis a flag — `janet_vm.c_raised` — because the
remaining C callers cannot take an error. A report that nobody consumes then
surfaces as a blank value or a jump with no scope, arbitrarily far from where
it was made; three separate hunts over three days failed to localise one. What
worked was ten lines: assert in `janet_try_init` and in `janet_restore` that no
report is outstanding. That brackets the leak to a single scope and names it in
one run. Every subsequent instance -- `janet_zig_ev_protect`, the contract's
`catching` helper, `cfunUnmarshal` reaching an abi instead of its
implementation -- was found first time. Both scopes are Zig now and both
assertions are still there; they go when the abis do.

The general form: **when a mechanism is not type-checked, buy back the check
with an invariant at the nearest boundary, before you start hunting.**

Phase 10 Part 12 added the sharper case, and it is about the *translation*
rather than a declaration. **A `JANET_*` macro derived from the compiler's own
predefines is not reliable through `@cImport`.** Aro predefines `__unix__` for
`x86_64-windows-gnu` and `janet.h` tests its Unix chain before its Windows
one, so the translation of that header for that target says `JANET_POSIX`
where the *compilation* of it says `JANET_WINDOWS` -- and `JanetHandle`, which
is `void *` on one and `int` on the other, follows it. Test the platform with
`builtin.os.tag`; read the build's own answer out of `@import("config")`.

That header is gone with `janet.h` at Phase 12 increment 5f, and the hazard is
not: the three host headers still `#include` system headers that read the same
predefines, and clang does not set them where Aro does. All three carry the
`#undef __unix__` correction, in the same words. **The general form is worth
more than the instance: a `@cImport` and a compilation of the same target are
two front ends, and anything one predefines and the other does not is a silent
disagreement about every header below it.** Ordering a platform chain's Windows
arm first is a second defence and not a substitute.

**A `Janet` in a C local is not a root, and a contract is where that matters.**
The collector scans the VM and the fiber stacks, and a cfunction's arguments
are on one of those, so nothing written *in Janet* ever has to think about it.
A contract holds its values in C locals, and any allocation between two calls
can collect what the first one returned. Phase 10 Part 15 lost its contract's
first run to this: a `filewatch/watcher` was collected, its `JanetStream`
finalizer closed the kqueue, and the symptom arrived three calls later as
"failed to listen: Bad file descriptor" -- nowhere near the allocation that
caused it. `janet_gcroot` anything a contract keeps across a call that can
allocate, and `janet_gcunroot` it at the end.

**A contract cannot see its selector.** The `JANET_ZIG_*` macros go to the
library module; `test/*.c` is a separate module that gets `JANET_BOOTSTRAP` and
nothing else. `test/vm_lifecycle.c` has an `#ifdef JANET_ZIG_DEBUG_FRAMES`
region that no configuration has ever compiled, and its header comment claims
the opposite. Until the build is fixed, a contract that needs to reach one
implementation's symbol needs that symbol compiled under *both* arms --
`janet_zig_os_stat_read` is the worked example -- or a runtime discriminator.

**A sweep gets its own cache and prunes it after every mutant.** Every mutant is
a distinct source *content*, so each deposits a fresh object set. Unbounded that
reached 116GB and filled a 460GB disk, after which builds fail for reasons
unrelated to any mutation and those failures are recorded as verdicts too.

Pruning, not wiping: `mutate.janet` builds the *unmutated* source once per stage
before it starts, snapshots the cache, and after each mutant deletes everything
outside that snapshot. The cache then sits at one baseline plus at most one
mutant — measured at 6.0GB steady and 10.9GB peak for the escalating judge, or
1.28GB and 1.68GB when only the default stage runs — and nothing cold-rebuilds,
so a mutant costs 2-3 seconds of relinking instead of a minute.

Two cheaper discriminators are wrong and were measured to be wrong. **Age**
fails because Zig stamps entries on cache *hits* as well as on creation, so
mtime pruning deletes the shared objects. **Delta size** fails because a
`zig build test` run relinked forty-odd contract executables against the
mutated library: a per-mutant delta there is *large*, and treating large deltas
as shared infrastructure grew the cache 4.5GB per mutant, 1.8GB to 28GB over
six. That relink is one executable now rather than forty-odd, which shrinks the
delta without changing the conclusion -- size still cannot tell this mutant's
garbage from the objects worth keeping.
Only a baseline from unmutated source separates the two exactly.

The warm-up pays for itself twice, because a stage that fails on unmutated
source means the tree is not green — and **a sweep against a failing baseline
measures nothing.** Better to learn that in the first minute than from two
hundred meaningless verdicts.

**A contract that leaves a child behind is scored as a hang, whatever it
decided.** `mutate.janet` runs the contract through `tools/sh`, which reads
both pipes to `:all`, and that blocks until every writer to the pipe closes --
including a grandchild the contract spawned and did not reap. It was
`capture_output=True` in the Python and the hazard is unchanged by the port. Phase 10 Part 12's contract spawns
`/bin/sleep 30`, so an aborting run left an orphan holding the pipe for the
whole twenty-second bound and the mutant was logged "contract (hang)" rather
than "contract". That much is only a mislabelled catch. The channel that
matters is the other one: a mutant whose contract *passed* but which broke
`os/proc-kill` left seven orphans, timed out on the pipe, and **was recorded as
caught by a test that had not caught it**. That is Part 8's "label the catcher"
rule arriving from the other direction, and it is why the first run of that
part's sweep -- 302 mutants, 294 caught, 234 of them by hanging -- had to be
discarded.

Two rules follow. **A contract must not let a spawned child inherit its
stdio**; redirect it to a file, and the orphan then holds that instead. And
**a contract must assert the effect it is testing rather than rely on the
harness noticing**: asserting that a killed process reports 128 plus its
signal is what turns that mutant into a real catch. A sweep whose catches are
mostly timeouts is a sweep to distrust before it is a sweep to report.

**A sweep that is killed leaves the source mutated, and it compiles.**
`mutate.janet` restores from its own backup after each verdict, so a run that
dies between the write and the restore leaves a live mutation in the tree. It
will not announce itself: a mutation is a *behaviour* change, so `zig build`
is clean and only the tests notice. Phase 10 Part 12 hit this by starting the
sweep with `nohup ... &` inside a command that then polled in a loop -- the
poll timed out, the process group went with it, and `statOrLstat`'s keyword
check was left inverted in the working tree.

Two habits fix it. Launch a long sweep from a command that *returns
immediately* -- `nohup ./tools/testing/mutate.janet ... &` and nothing else -- and poll from a
separate one; chaining the poll onto the launch means a timeout on the poll
kills the sweep with it. (`setsid` is not available on macOS, so the detach is
`nohup` plus a short command.) And after any sweep that did not print its own
summary, **`git diff` the file it was mutating** before trusting anything built
from it. `zig build` succeeding is not evidence.

**Debris from a failing suite is caught by the next mutant.** The Janet suites
create files in the working tree and delete them again when they pass. A mutant
that makes one *fail* leaves the file behind, and every mutant after it then
fails the same suite for a reason unrelated to its own mutation. Phase 10 Part
12 lost a whole phase to this: a mutated `os/open` mode created `unique.txt`
with permissions 0000, `test/suite-ev.janet` could never reopen it, and
**fifty-seven of seventy-four mutants were recorded as caught by
`suite-ev.janet (fail)`**. `mutate.janet` now clears a `debris` list before every
judged run. What gave it away was the attribution column -- a file-writing
suite has no business catching mutations in a permission parser -- which is
Part 8's "label the catcher" rule paying for itself a second time. **Read the
attribution distribution, not just the totals.**

**A test that kills a child must use a signal that cannot be ignored.** An
ignored disposition is inherited across `fork` and `exec`. The sweep is
launched with `nohup`, `nohup` ignores SIGHUP, `/bin/sleep` inherits that, and
`(os/proc-kill p true :hup)` therefore waits forever -- which aborted two
sweeps in their warm-up and never reproduced interactively, because an
interactive shell does not ignore SIGHUP. SIGKILL is the only signal that
cannot be caught or ignored. Test the *lookup* if the signal table is the
subject; use SIGKILL if death is.

**And do not send a core-dumping signal to a child on macOS.** `:abrt`,
`:fpe`, `:ill` and `:segv` wake `ReportCrash`, which took one contract from
milliseconds to seconds and made it fail intermittently under `zig build test`.

**A sweep stops before the disk does, and the floor is the weaker of its two
guards.** Under `min-free-gb` free it prunes, and if that is not enough it
aborts. An ENOSPC in the middle of a build is indistinguishable from a mutant
that failed to compile, and gets recorded as one.

That floor *predicts*, and on macOS it predicts badly: `statvfs` reports what is
free now and knows nothing about purgeable space, which the OS hands back the
moment a writer needs it. Phase 10 Part 13 measured **28.2GB by `statvfs`
against 143.3GB available for important usage** on the same volume at the same
moment, and lost two sweeps to the difference -- one aborting at mutant 0 with
over a hundred gigabytes really available. The floor is now 10GB and is a coarse
backstop.

The guard that does the work is `refuse_if_disk_full`, which every judged build
passes through: it looks for the volume-full message in the build output and
raises, so the sweep aborts where the failure actually happens instead of
guessing beforehand. Detecting beats predicting, and it is portable where the
purgeable notion is not.

**Mutants that only one configuration compiles need a judge that builds it.**
Half of `core_env.zig` exists only in the image generator, so a default `zig
build` cannot see a mutation in it at all and reports it as surviving.
`mutate.janet` escalates — plain build, then the whole `zig build test` graph —
so cheap mutants die cheaply and the expensive judge runs only for what needs
it. (There was a `-Dboot=zig` stage between the two; Phase 10 Part 17g removed
the option by removing the C generator, and Part 19 removed the stage.)
