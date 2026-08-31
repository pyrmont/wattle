#!/bin/sh
# The leak check, over the contract driver that is currently in `zig-out`.
#
# Development instrument in `tools/`.
#
#     ./tools/testing/leaks.sh                  # every contract, one process each
#     ./tools/testing/leaks.sh args_core marsh  # just these
#
# macOS only: `leaks` is Apple's. There is no Linux equivalent wired up here,
# and `test/README.md` says what the container does instead.
#
# ## Why this does not use `leaks --atExit`
#
# Because `--atExit` cannot measure a contract that forks, and three of the
# sixty-five do. That mode inserts `libLeaksAtExit.dylib`, which interposes
# `_exit` and `abort` with
#
#     kill(getpid(), SIGSTOP); real_exit(status);
#
# -- the stop being how the waiting `leaks` process is told there is a heap to
# scan. A `fork()`ed child carries the dylib in its inherited image and stops
# itself the same way, and nothing ever resumes it, because `leaks` is watching
# the parent. The parent's `waitpid` then blocks forever. Phase 11 Part 24
# recorded that as `os_process`, `os_surface` and `value_alloc` "never
# returning" under the tool and concluded it was not a fork; Part 28 sampled
# the stopped child, found `my__exit` in `libLeaksAtExit.dylib` calling
# `__kill`, and found seven `fork` sites in `os_process` alone.
#
# An `exec`ed child is safe: the dylib's initializer strips itself from
# `DYLD_INSERT_LIBRARIES`, which is why the many `os/spawn` calls in these
# contracts are not the hazard and a raw `fork` is.
#
# So this reaches the same heap by a route with no interposer in it. The driver
# stops *itself* at the end of `main` when `JANET_CONTRACT_PAUSE` is set, this
# script scans the stopped process with `leaks <pid>`, and then resumes it.
# A forked child exits normally, because nothing has been inserted into it.
#
# `MallocStackLogging=lite` is what `--atExit` sets and is what gives each leak
# an allocation stack; without it `leaks` still counts, but every report is an
# address.
set -e

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

driver=zig-out/bin/janet-zig-contract-test
if [ ! -x "$driver" ]; then
    echo "leaks.sh: no $driver -- run \`zig build\` first" >&2
    exit 2
fi

if [ "$(uname -s)" != "Darwin" ]; then
    echo "leaks.sh: macOS only -- \`leaks\` is Apple's" >&2
    exit 2
fi

# `gc_stress` orphans a block on purpose, so it is excluded rather than
# expected: its whole subject is a heap the collector is not allowed to reach.
# The two contracts that leak *and are still measured* are `gc_sweep` and
# `net_sockets`; both pin a defect `FOUND.md` records and both are listed in
# `expected` below, so a change in either count is a signal rather than noise.
excluded="gc_stress"
expected_gc_sweep=8
expected_net_sockets=3

if [ $# -gt 0 ]; then
    names=$*
else
    names=$(sed -n 's/^.*with(list, "\([a-z_0-9]*\)".*$/\1/p' test/contracts.zig)
fi

status=0
for name in $names; do
    for skip in $excluded; do
        if [ "$name" = "$skip" ]; then
            printf '%-24s skipped (leaks on purpose)\n' "$name"
            continue 2
        fi
    done
    if [ ! -f "test/$name.zig" ]; then
        echo "leaks.sh: no such contract: test/$name.zig" >&2
        exit 2
    fi

    log=$(mktemp -t janet-leaks)
    JANET_CONTRACT_PAUSE=1 MallocStackLogging=lite "$driver" "$name" >"$log" 2>&1 &
    pid=$!

    # Wait for the driver to stop itself. `ps -o stat=` reports `T` for a
    # stopped process; anything else means it is still working, or that it
    # died before it got there.
    waited=0
    while [ "$(ps -o stat= -p $pid 2>/dev/null | cut -c1)" != "T" ]; do
        if ! kill -0 $pid 2>/dev/null; then
            printf '%-24s DIED before the pause\n' "$name"
            cat "$log"
            rm -f "$log"
            status=1
            continue 2
        fi
        waited=$((waited + 1))
        if [ $waited -gt 600 ]; then
            printf '%-24s TIMED OUT waiting for the pause\n' "$name"
            kill -9 $pid 2>/dev/null || true
            rm -f "$log"
            status=1
            continue 2
        fi
        # A contract is milliseconds; this is a poll, not a bound.
        /bin/sleep 0.1
    done

    report=$(leaks $pid 2>&1 || true)
    kill -CONT $pid
    wait $pid || true

    count=$(printf '%s\n' "$report" | sed -n 's/^Process [0-9]*: \([0-9]*\) leaks for.*$/\1/p')
    [ -n "$count" ] || count="?"

    eval "want=\${expected_$(printf '%s' "$name" | tr -c 'a-zA-Z0-9' '_'):-0}"
    if [ "$count" = "$want" ]; then
        if [ "$want" = "0" ]; then
            printf '%-24s 0\n' "$name"
        else
            printf '%-24s %s (expected: FOUND.md)\n' "$name" "$count"
        fi
    else
        printf '%-24s %s LEAKS, expected %s\n' "$name" "$count" "$want"
        printf '%s\n' "$report" | sed -n '/^Process .* leaks for/,/^Binary Images/p' | head -60
        status=1
    fi
    rm -f "$log"
done
exit $status
