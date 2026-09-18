#!/bin/sh
# Measure Wattle against C Janet over one benchmark corpus, reporting the
# ratio per workload.
#
# Development instrument in `res/`.
#
#     ./res/bench/yardstick.sh ./zig-out/bin/wattle ../janet/build/janet interpreter/bench
#
# `corpus` is a stem under `res/bench/`, which resolves to the two arms:
# `<stem>.wattle` run by the Wattle binary and `<stem>.janet` run by the Janet
# one. Both are `layout.sh`'d first, so each arm is already the minimum over
# twelve initial stack layouts before the division happens.
#
# ## Why there are two files per corpus
#
# C Janet cannot read a `.wattle` file, so a comparison needs the workload in
# both syntaxes. The `.janet` side is the original and the `.wattle` side is
# what `res/repo/janet-to-wattle.janet` made from it, which is what lets
# `res/check/bench-arms.janet` *derive* that the two arms are the same program
# rather than assert it. Run that check before believing a number from here.
#
# ## What the ratio is
#
# Wattle's time over C Janet's, so 1.00 is parity, above one is slower and
# below one is faster. It is not a percentage and it is not signed: a corpus
# that reads 1.15 is taking fifteen percent longer.
#
# ## What this cannot tell you
#
# Only the corpora exercising types both runtimes have mean anything here. The
# collections, maps and vectors corpora exercise a vector, a map or a set, none
# of which C Janet has, so their `.janet` arms measure whatever the conversion
# left rather than the same work. `notes/LANGUAGE.md` records which corpora
# compare under the performance yardstick.
#
# The layout sweep marginalises the stack layout out of each arm separately. It
# does nothing about the two binaries being different programs with different
# code layouts, which `notes/PERF.md` records as a band of about twelve percent
# on the dispatch-heavy workloads. A single workload moving a few percent
# between runs of this script is that band, not a change.

set -eu

wattle_bin=${1:-}
janet_bin=${2:-}
corpus=${3:-}
runs=${4:-12}

if [ -z "$wattle_bin" ] || [ -z "$janet_bin" ] || [ -z "$corpus" ]; then
    echo "usage: res/bench/yardstick.sh <wattle> <janet> <corpus-stem> [layouts]" >&2
    echo "   eg: res/bench/yardstick.sh ./zig-out/bin/wattle ../janet/build/janet value/bench" >&2
    exit 2
fi

here=$(dirname "$0")
wattle_arm="$here/$corpus.wattle"
janet_arm="$here/$corpus.janet"

for f in "$wattle_arm" "$janet_arm"; do
    if [ ! -f "$f" ]; then
        echo "yardstick.sh: no such arm: $f" >&2
        exit 2
    fi
done

w_out=$(mktemp)
j_out=$(mktemp)
trap 'rm -f "$w_out" "$j_out"' EXIT

"$here/layout.sh" "$wattle_bin" "$wattle_arm" "$runs" > "$w_out"
"$here/layout.sh" "$janet_bin" "$janet_arm" "$runs" > "$j_out"

# `layout.sh` refuses a missing binary rather than emitting nothing, because a
# caller dividing two empty streams reads a tidy and entirely fictional
# result. The same hazard one level up is the workload *names* drifting apart:
# `paste` would happily align `strings` against `compiler` and the ratio would
# be a comparison of two different workloads. So the two name columns are
# compared before anything is divided.
w_names=$(awk '{print $1}' "$w_out")
j_names=$(awk '{print $1}' "$j_out")
if [ "$w_names" != "$j_names" ]; then
    echo "yardstick.sh: the two arms do not report the same workloads, in the same order." >&2
    echo "  $wattle_arm: $(echo "$w_names" | tr '\n' ' ')" >&2
    echo "  $janet_arm: $(echo "$j_names" | tr '\n' ' ')" >&2
    echo "Run res/check/bench-arms.janet --check; the arms have diverged." >&2
    exit 1
fi

printf '%-14s %10s %10s %7s\n' workload janet wattle 'W/C'
paste "$j_out" "$w_out" | awk '
    { printf "%-14s %10.6f %10.6f %7.2f\n", $1, $2, $4, $4 / $2 }
    { sum += $4 / $2; n += 1 }
    END { if (n > 0) printf "%-14s %10s %10s %7.2f\n", "(mean)", "", "", sum / n }'
