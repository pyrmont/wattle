#!/bin/sh
# Run one contract from the driver that is currently in `zig-out`.
#
# Development instrument in `res/`.
#
#     ./res/testing/contract.sh marsh             # test/marsh.zig
#     ./res/testing/contract.sh marsh peg io_core # several, stopping at nothing
#
# A name maps to `test/<name>.zig` and there is nothing to compile or link.
# Phase 11 Part 1 put the Zig contracts *inside* a second compilation of the
# runtime -- that is how a contract reaches a raise-capable function without a
# C-ABI abi -- so `zig build` builds the binary and this runs it with the
# contract's name as its argument.
#
# **The C half of this script is gone.** Until Phase 11 Part 22 a name could
# also be `test/<name>.c`, and that route was a `zig cc` of `test/contracts.c`
# plus the one contract plus `wattle-contract-support.o` against
# `zig-out/lib/libwattle.a` -- a shallow link, because a C contract sat on the
# far side of the symbol table and needed the adapter to call or define a
# cfunction. There is no `test/*.c` contract left, so there is no link, no
# `janetconf.h` lookup, and no support object.
#
# This is the narrow iteration loop `AGENTS.md` prescribes -- "`zig build` plus
# the one suite and the one contract your edit could affect".
#
# **Several names here are several processes, and the driver's own several are
# one.** Since Phase 11 Part 27 `wattle-contract-test a b c` runs the three
# in a single process, sharing whatever one leaves in `janet_vm` for the next --
# which is what made a sequence-dependent defect bisectable. This script keeps
# one process per name deliberately: it is the iteration loop, and a contract
# that fails here should fail on its own account rather than because of its
# predecessor. Use the driver directly when the sequence is the subject.
#
# **It does not build anything.** That is deliberate, and it is the trap
# `AGENTS.md` warns about: `zig-out` belongs to whichever configuration was
# built last, and restoring a mutated source does not rebuild it. So this
# prints which driver it is running and how old it is, and you run `zig build`
# yourself when you mean to.
set -e

# This script lives in `res/`; every path below is relative to the
# repository root, one level up.
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

if [ $# -eq 0 ]; then
    echo "usage: res/testing/contract.sh <name> [name ...]   # test/<name>.zig" >&2
    exit 2
fi

# `build.zig` installs this unconditionally for exactly this loop.
driver=zig-out/test/wattle-contract-test
if [ ! -x "$driver" ]; then
    echo "contract.sh: no $driver -- run \`zig build\` first" >&2
    exit 2
fi

echo "running $driver (built $(date -r "$driver" '+%H:%M:%S'))"

status=0
for name in "$@"; do
    if [ ! -f "test/$name.zig" ]; then
        echo "contract.sh: no such contract: test/$name.zig" >&2
        exit 2
    fi
    printf '%-24s ' "$name"
    if out=$("$driver" "$name" 2>&1); then
        echo "${out:-ok}"
    else
        echo "FAILED"
        echo "$out" | tail -20
        status=1
    fi
done
exit $status
