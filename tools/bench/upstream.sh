#!/bin/sh
# Measure this tree's Zig runtime against upstream Janet's C one.
#
#     ./tools/bench/upstream.sh [corpus] [layouts]
#     ./tools/bench/upstream.sh tools/bench/interpreter/bench.janet 12
#
# ## Why this exists
#
# Until Phase 10 Part 17g the tree could always build both arms of a subsystem
# and compare them in place, and `janet-c` -- a whole C client -- was an
# ordinary build target. Part 17g spent the last cfunction-bearing `c` arm and
# Part 18 spent the other twenty-nine, so *this tree can no longer build a C
# Janet at all*. `phase_10.md` records that loss and does not replace it.
#
# This is the replacement, and it answers a different question from
# `bench-layout.sh` run over two commits. That one is a regression check --
# did an increment cost anything. This one is the absolute check: how does the
# Zig runtime compare to the C implementation it replaces, which is what the
# project's stated performance tolerance is actually about.
#
# ## The two things that make the comparison honest
#
# **Same compiler backend.** Upstream's Makefile is `CFLAGS?=-O2 -g` with the
# system `cc`; this tree builds ReleaseFast through Zig's LLVM. Comparing those
# directly measures Apple clang against Zig's LLVM as much as it measures C
# against Zig, so master is built here with `CC="zig cc"` and `-O3`. Getting
# this wrong is the failure mode this script exists to prevent: the number
# looks fine and is about the wrong thing.
#
# **Same layout treatment.** Both binaries go through `bench-layout.sh`, for
# the reason Phase 10's rule 16 gives -- `pegmatch` is bimodal in the size of
# the argv and environment block, and no amount of repetition removes it.
#
# ## Reading it
#
# Rule 7 first: **read the control**. If `pegmatch` has moved between two runs
# of the same pairing, nothing under that figure means anything. On this corpus
# treat anything under about 5% as unresolved, and under about 12% on `fib`.
#
# Measured 2026-08-25, at the end of Phase 10: the Zig runtime is **1.14x**
# upstream C on the Phase 9 corpus, against a stated tolerance of sub-10x.
#
# ## What this script gets wrong, and what to do instead
#
# **It builds and then measures immediately.** Both binaries therefore run on a
# machine still settling from `make -j4` and a `zig build`, and both inflate --
# by roughly 70% when this was measured on 2026-08-31, on an otherwise idle
# M4 Pro. The *ratio* survives that better than the absolute times do, but not
# reliably: the run that read 1.37x was a tree whose cold figure was 1.14x.
#
# So do not read a number out of one invocation of this script. Build upstream
# once into a scratch prefix and keep the binary:
#
#     git worktree add --detach /tmp/janet-master master
#     ( cd /tmp/janet-master && make -j4 CC="zig cc" \
#         CFLAGS="-O3 -std=c99 -Wall -Isrc/include -Isrc/conf" )
#
# then build this tree ReleaseFast into another prefix, wait for the machine to
# go quiet, and run `layout.sh` against each. Interleave with
# `tools/bench/interpreter/run.sh` when the question is "did this increment
# cost anything" rather than "how does the tree compare to C".
#
# Taken that way on 2026-08-31: **1.141x** at `3584bece` and **1.151x** after
# Phase 14 increments 2a-2c, with the `pegmatch` control unchanged.
set -eu

CORPUS="${1:-tools/bench/interpreter/bench.janet}"
LAYOUTS="${2:-12}"
WORK="${TMPDIR:-/tmp}/janet-upstream-bench"

cleanup() {
    git worktree remove --force "$WORK/master" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK"

echo "building upstream master with zig cc -O3..."
git worktree add --detach "$WORK/master" master >/dev/null 2>&1
( cd "$WORK/master" && make -j4 CC="zig cc" CFLAGS="-O3 -std=c99 -Wall -Isrc/include -Isrc/conf" ) >"$WORK/master.log" 2>&1 \
    || { echo "upstream build failed; see $WORK/master.log" >&2; exit 1; }

echo "building this tree, ReleaseFast..."
zig build -Doptimize=ReleaseFast --cache-dir "$WORK/cache" -p "$WORK/out" >"$WORK/zig.log" 2>&1 \
    || { echo "zig build failed; see $WORK/zig.log" >&2; exit 1; }

echo "measuring across $LAYOUTS stack layouts..."
./tools/bench/layout.sh "$WORK/master/build/janet" "$CORPUS" "$LAYOUTS" > "$WORK/c.txt"
./tools/bench/layout.sh "$WORK/out/bin/janet" "$CORPUS" "$LAYOUTS" > "$WORK/zig.txt"

python3 - "$WORK/c.txt" "$WORK/zig.txt" <<'PY'
import sys
def read(p):
    d = {}
    for ln in open(p):
        f = ln.split()
        if len(f) == 2:
            try: d[f[0]] = float(f[1])
            except ValueError: pass
    return d
c, z = read(sys.argv[1]), read(sys.argv[2])
keys = [k for k in c if k in z]
# Control first: rule 7.
keys.sort(key=lambda k: (k != "pegmatch", k))
print()
print("%-12s %10s %10s %8s" % ("workload", "C (s)", "zig (s)", "ratio"))
for k in keys:
    note = "  <- control" if k == "pegmatch" else ""
    print("%-12s %10.6f %10.6f %7.2fx%s" % (k, c[k], z[k], z[k] / c[k], note))
print()
print("mean ratio: %.2fx over %d workloads" % (sum(z[k]/c[k] for k in keys)/len(keys), len(keys)))
PY
