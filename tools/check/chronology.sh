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
# **A `-D` option the build does not have** is the third question, and it is
# derived rather than listed. `build.zig`'s own `b.option` calls are the set of
# options that exist, plus `target`, `cpu` and `optimize`, which Zig declares
# for it. Anything else a shipped file spells after `-D` names a switch nobody
# can pass. A hard-coded list of retired suffixes was what this asked before,
# and it fired on nothing: the retired options are named `-Dboot`,
# `-Dvalue-wrap`, `-Dgc-mark` and their kin, and no list written once keeps up
# with the next one.
#
# It is asked of the **shipped source** only, for the reason the chronology
# question is. A retired *file* can be checked by looking; a retired *command*
# may be a log saying what was run, and rewriting one falsifies the record
# rather than repairing it. `tools/testing/acceptance-matrix.md` and
# `tools/testing/mutation.md` are exactly that, and they stay out.
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
# section 13 decides that `types.zig` does not exist, and it has to be able to
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

if grep -rnE 'Phase [0-9]+|increment [0-9]+[a-z]?|Part [0-9]+[a-z]?|batch [0-9]|SPIKE-?[0-9]+|PLAN\.md|NAMESPACES\.md|phase_1[0-9]\.md|the hinge|selector|src/core/|janet\.h|util\.h|what `[a-z_]+\.zig` was|[a-z_]+_(core|surface|files|time|stat|loop|stream|sockets|pretty|access|alloc|symbol|array|table|frames|flags)\.zig' \
    --exclude-dir=.zig-cache --exclude-dir=zig-out \
    src test examples build.zig |
  grep -vE '^[^:]+:[0-9]+:.*(test/[a-z_0-9]+\.zig|@import\("[a-z_0-9]+\.zig"\)|host_stat\.zig|trace_frames\.zig|filewatch_flags\.zig|filewatch_core\.zig)'
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

# ------------------------------------- a `-D` option this build does not have

live_options=$(
  {
    grep -oE 'b\.option\([^,]*, "[a-z0-9-]+"' build.zig | sed 's/.*"\(.*\)"/\1/'
    # Zig declares these three for every build script.
    printf '%s\n' target cpu optimize
  } | sort -u
)

# `awk` reads the set from the environment: `-v` does not take a newline, and
# `-e` rather than `--` because `--` would end option parsing before the two
# `--exclude-dir`s.
export live_options

retired_options=$(
  grep -rnE --exclude-dir=.zig-cache --exclude-dir=zig-out \
      -e '-D[a-z0-9]' \
      src test examples build.zig |
  grep -vE 'does not exist|There is no' |
  awk '
    BEGIN {
      n = split(ENVIRON["live_options"], a, "\n")
      for (i = 1; i <= n; i++) have[a[i]] = 1
    }
    {
      rest = $0
      while (match(rest, /-D[a-z0-9][a-z0-9-]*/)) {
        name = substr(rest, RSTART + 2, RLENGTH - 2)
        if (!(name in have)) { print; break }
        rest = substr(rest, RSTART + RLENGTH)
      }
    }'
)

if [ -n "$retired_options" ]; then
  printf '%s\n' "$retired_options"
  echo "chronology.sh: the lines above name a -D option this build does not have." >&2
  status=1
fi

exit $status
