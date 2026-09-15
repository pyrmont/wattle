#!/bin/sh
# Interleave two binaries over the cfunction-entry corpus and report the
# minimum each reaches per workload, with the second as a percentage of the
# first. Interleaved so thermal drift lands on both; minimum because the noise
# is one-sided.
#
#   res/bench/value/run.sh <baseline> <candidate> [rounds]
set -e
base=$1
cand=$2
rounds=${3:-5}
script="$(dirname "$0")/bench.janet"

round=1
while [ "$round" -le "$rounds" ]; do
    "$base" "$script" | sed 's/^/base /'
    "$cand" "$script" | sed 's/^/cand /'
    round=$((round + 1))
done | awk '
    { key = $2; t = $3 + 0;
      if (!((key, $1) in best) || t < best[key, $1]) best[key, $1] = t;
      if (!(key in seen)) { seen[key] = 1; order[++n] = key } }
    END {
        printf "%-12s %10s %10s %8s\n", "workload", "base", "cand", "delta";
        for (i = 1; i <= n; i++) {
            k = order[i]; b = best[k, "base"]; c = best[k, "cand"];
            printf "%-12s %10.4f %10.4f %+7.1f%%\n", k, b, c, (c / b - 1) * 100;
        }
    }'
