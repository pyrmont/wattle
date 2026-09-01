#!/bin/sh
# Every comment in the shipped tree that cites the migration rather than the
# code, printed one per line. Silent is clean.
#
#     ./tools/check/chronology.sh
#
# ## What it looks for
#
# A phase, part, increment or batch number; a working document under `port/`; a
# `-D` option no build offers; a retired file name; a public header or a
# `src/core/` path that no longer exists; and the section banners of the form
# `-- what X.zig was`. Each is prose that was true while something was being
# moved and is false or meaningless now that it has been.
#
# ## Two exclusions, and they are the whole of the difficulty
#
# **`translate-c` is not chronology.** The three host headers -- `os/abi.h`,
# `net/abi.h`, `filewatch/abi.h` -- are read by translate-c on every build, and
# the comments explaining what it does and does not carry across are the reason
# each hand-written declaration beside them exists. The pattern below does not
# name it.
#
# **The retired file names are live under `test/`.** The contracts really are
# `io_core.zig`, `filewatch_flags.zig`, `os_stat.zig` and their kin, so a source
# file naming one is naming a file that exists. The second `grep` drops those,
# and only those: a bare `io_core.zig` with no `test/` in front of it is still a
# finding.
#
# ## Why this is a script and not a build check
#
# `build.zig` had one, `checkNoScaffoldCitations`, which refused any shipped
# file citing `port/…`. It was removed on 2026-08-31 at the user's direction and
# is deliberately not reintroduced: a prose rule is reviewed, not compiled, and
# a compiled one refuses the honest citation along with the stale one. This is
# the same question asked by hand, so that asking it is cheap rather than
# automatic.
set -eu

cd "$(dirname "$0")/../.."

grep -rnE 'Phase [0-9]+|increment [0-9]+[a-z]?|Part [0-9]+[a-z]?|batch [0-9]|SPIKE-?[0-9]+|PLAN\.md|NAMESPACES\.md|phase_1[0-9]\.md|the hinge|selector|-D[a-z]+-(core|engine|loop|sockets|access|alloc|primitives|trampoline|encode)|src/core/|janet\.h|util\.h|what `[a-z_]+\.zig` was|[a-z_]+_(core|surface|files|time|stat|loop|stream|sockets|pretty|access|alloc|symbol|array|table|frames|flags)\.zig' \
    src/zig test build.zig |
  grep -vE 'test/[a-z_0-9]+\.zig|@import\("[a-z_0-9]+\.zig"\)|host_stat\.zig|trace_frames\.zig|filewatch_flags\.zig|filewatch_core\.zig' ||
  exit 0

echo "chronology.sh: the lines above cite the migration rather than the code." >&2
exit 1
