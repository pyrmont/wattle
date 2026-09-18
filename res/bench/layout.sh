#!/bin/sh
# Measure one binary over a benchmark corpus across several distinct
# initial stack layouts, reporting the minimum per workload.
#
# Development instrument in `res/`.
#
#     ./res/bench/layout.sh ./zig-out/bin/wattle res/bench/interpreter/bench.wattle 12
#
# ## Why this exists
#
# Phase 10 Part 17f measured `pegmatch` -- the Phase 9 corpus's *control* -- at
# +48% and spent an afternoon establishing that no code was responsible. The
# workload is **bimodal in the initial stack layout**: about one environment
# size in twelve puts it in a mode roughly 48% slower, and which sizes are bad
# differs per binary. Measured over twelve environment sizes, the baseline hit
# the slow mode once and the candidate hit it once, at different sizes.
#
# The initial stack pointer is set by the kernel from the size of the argv and
# environment block, so *every run of a given binary from a given shell sees
# the same layout*. That is what makes it so misleading: it is perfectly
# reproducible, it survives taking the minimum over any number of runs, and it
# survives interleaving. Part 17f's first reading was seven runs of each
# binary, minimum per workload, twice -- the recipe `AGENTS.md` prescribes --
# and it reported +48.4% and +47.8%.
#
# The cheapest demonstration, if you ever need to convince yourself again:
#
#     $ ./zig-out/bin/wattle res/bench/interpreter/bench.wattle | grep pegmatch    # zsh
#     pegmatch 0.038912
#     $ bash -c './zig-out/bin/wattle res/bench/interpreter/bench.wattle' | grep pegmatch
#     pegmatch 0.057662
#     $ PAD= bash -c './zig-out/bin/wattle res/bench/interpreter/bench.wattle' | grep pegmatch
#     pegmatch 0.039423
#
# One empty environment variable, 48%. Nothing about the code changed.
#
# ## What this does about it
#
# Varies the environment across `runs` distinct sizes and takes the minimum per
# workload, which marginalises the layout out instead of freezing one. Run it
# for each binary separately and compare afterwards -- interleaving is the
# wrong instrument here for the reason Part 17b established, and it does not
# address layout at all.
#
# It does not make the corpus precise. With the control flat, Part 17f still
# saw ±5% move on the dispatch-heavy workloads between builds that differ only
# in which half of one file is Zig, so treat anything under about 5% on this
# corpus as unresolved rather than as a finding.
#
# ## Discard the first run of a session
#
# There is a second effect on top of the layout one, and taking the minimum is
# what makes it stick. **The first invocation of a session reads low** -- a
# cold machine, nothing else resident -- and because the answer is a minimum,
# that one reading becomes the arm's figure for every comparison made after it.
#
# Measured at Phase 15 Part 1a: the baseline binary's `arithmetic` read
# 0.041967 on the session's first run and 0.044670, 0.045246, 0.044848 and
# 0.045458 on four later runs of the *same binary*. The increment under test
# had no first run, so it was reported at 1.079x on a workload that allocates
# nothing and that the increment does not touch. Two further rounds of each arm
# settled it at 1.00x.
#
# So: discard the first round of a session, or measure the second arm cold as
# well. Two warm rounds per arm is the cheap recipe, and it is what the D4
# figures in the phase records are taken with.
set -e

bin=$1
script=$2
runs=${3:-12}

if [ -z "$bin" ] || [ -z "$script" ]; then
    echo "usage: res/bench/layout.sh <binary> <bench.wattle> [layouts]" >&2
    exit 2
fi

# A missing binary used to produce an empty stream, which the awk below turns
# into no rows at all -- and a caller pasting two of these against each other
# then reads 0.000000 and a tidy -100.0%. Silence that looks like a
# measurement is worse than an error.
if [ ! -x "$bin" ]; then
    echo "bench-layout.sh: no such executable: $bin" >&2
    exit 2
fi
if [ ! -f "$script" ]; then
    echo "bench-layout.sh: no such script: $script" >&2
    exit 2
fi

i=0
while [ "$i" -lt "$runs" ]; do
    pad=$(awk -v n="$i" 'BEGIN { s = ""; for (j = 0; j < n; j++) s = s "x"; print s }')
    PAD="$pad" "$bin" "$script"
    i=$((i + 1))
done | awk '
    { k = $1; t = $2 + 0;
      if (!(k in best) || t < best[k]) best[k] = t;
      if (!(k in seen)) { seen[k] = 1; order[++n] = k } }
    END { for (i = 1; i <= n; i++) printf "%s %.6f\n", order[i], best[order[i]] }'
