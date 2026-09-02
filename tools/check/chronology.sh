#!/bin/sh
# Every comment in the shipped tree that cites the migration rather than the
# code, and every name anywhere in it for a thing that does not exist.
# Silent is clean.
#
#     ./tools/check/chronology.sh
#
# ## Two questions, and they have different scopes
#
# **Chronology** — a phase, part, increment or batch number; a working document
# under `port/`; the section banners of the form `-- what X.zig was`; and this
# project's own retired header. Each is prose that was true while something was
# being moved and is false or meaningless now that it has been. Asked of the
# **shipped source**: `src`, `test`, `examples`, `build.zig`.
#
# It is *not* asked of `DESIGN.md` or `tools/`, and that is a decision rather
# than an omission. A decision record that says "decided 2026-08-31, measured at
# Phase 14 increment 4a" is stating its evidence; an instrument's header that
# says "it reported four of sixteen until Phase 15 Part 1b" is stating why the
# instrument has the shape it has. Those are the citations the repository rules
# ask *for*. Asking this question of those files returns hundreds of lines of
# which almost none is a finding, and an instrument whose output is almost all
# noise is one nobody reads.
#
# **A name for a file or directory that does not exist** — a retired
# `types.zig`, `stretchy.zig`, `NAMESPACES.md`, and `src/zig`, which Phase 17
# split into `src/api`, `src/host` and `src/runtime`. This one is asked
# **everywhere**, the top-level documents, `DESIGN.md` and `tools/` included,
# because a document naming a path that is not there is wrong wherever it sits
# and a reader cannot check it.
#
# A retired **`-D<x>-core` selector option** is deliberately *not* in the wide
# question, although it looks like the same thing. A retired *file* can be
# checked by looking; a retired *command* may be a log saying what was run, and
# rewriting one falsifies the record rather than repairing it. The option stays
# in the shipped-source question above, where a live file naming one is wrong.
#
# Both questions skip `.zig-cache` and `zig-out`. `examples/standalone` builds
# a cache of its own inside the tree, and a compiler cache is full of `std`
# file names that match either pattern.
#
# ## Five exclusions, and they are the whole of the difficulty
#
# **`ffi/types.zig` exists.** The deleted catalogue sat at the top of the
# runtime source;
# the FFI's own type module is live and named on twelve lines. The pattern
# refuses a `types.zig` with a `/` before it, and refuses `src/runtime/ffi/`
# outright -- a file in that directory writes `@import("types.zig")` for its
# own neighbour, with no path to distinguish it by.
#
# **`translate-c` is not chronology.** The three host headers -- `os/abi.h`,
# `net/abi.h`, `filewatch/abi.h` -- are read by translate-c on every build, and
# the comments explaining what it does and does not carry across are the reason
# each hand-written declaration beside them exists. The pattern does not name
# it.
#
# **The retired file names are live under `test/`.** The contracts really are
# `io_core.zig`, `filewatch_flags.zig`, `os_stat.zig` and their kin, so a
# source file naming one is naming a file that exists. The second `grep` drops
# those, and only those: a bare `io_core.zig` with no `test/` in front of it is
# still a finding.
#
# **A line saying the file is gone is not a reference to it.** `DESIGN.md`
# section 14 decides that `types.zig` does not exist, and it has to be able to
# say so. A line containing "does not exist" or "There is no" is dropped, which
# is decidable by shape rather than by a list of exempt lines.
#
# **`src/core/` and `janet.h` name upstream C.** `DESIGN.md` compares against
# `janet.h`'s declarations, which is the subject rather than a stale reference.
# They stay in the shipped-source question, where this project having had its
# own `janet.h` is what makes a mention wrong.
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

status=0

# ------------------------------------------------- chronology, shipped source

if grep -rnE 'Phase [0-9]+|increment [0-9]+[a-z]?|Part [0-9]+[a-z]?|batch [0-9]|SPIKE-?[0-9]+|PLAN\.md|NAMESPACES\.md|phase_1[0-9]\.md|the hinge|selector|-D[a-z]+-(core|engine|loop|sockets|access|alloc|primitives|trampoline|encode)|src/core/|janet\.h|util\.h|what `[a-z_]+\.zig` was|[a-z_]+_(core|surface|files|time|stat|loop|stream|sockets|pretty|access|alloc|symbol|array|table|frames|flags)\.zig' \
    --exclude-dir=.zig-cache --exclude-dir=zig-out \
    src test examples build.zig |
  grep -vE 'test/[a-z_0-9]+\.zig|@import\("[a-z_0-9]+\.zig"\)|host_stat\.zig|trace_frames\.zig|filewatch_flags\.zig|filewatch_core\.zig'
then
  echo "chronology.sh: the lines above cite the migration rather than the code." >&2
  status=1
fi

# ------------------------------- a name for a thing that does not exist, anywhere

if grep -rnE '(^|[^/a-z_])types\.zig|stretchy\.zig|NAMESPACES\.md|src/zig' \
    --exclude-dir=.zig-cache --exclude-dir=zig-out \
    src test examples build.zig tools DESIGN.md AGENTS.md README.md \
    CONTRIBUTING.md 2>/dev/null |
  grep -vE '\.zig-cache|ffi_types\.zig|^src/runtime/ffi/|^tools/check/chronology\.sh' |
  grep -vE 'does not exist|There is no'
then
  echo "chronology.sh: the lines above name a file or directory that does not exist." >&2
  status=1
fi

exit $status
