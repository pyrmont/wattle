# Shared machinery for the instruments under `res/`.
#
# This holds what more than one of them needs -- shelling out, the repository
# root, and the small amount of formatting they share. It is imported as
# `tools`, so a call site reads `tools/sh` and `tools/root`, and the file is
# named for what it holds rather than for the directory it sits in.
#
# **It stays at the top of `res/`, and the grouped scripts reach it as
# `(import ../common :as tools)`.** A Janet relative import resolves against
# the importing *file* rather than the working directory, so a script in
# `check/` or `testing/` finds it wherever it is run from.
#
# The instruments run from the repository root and reach the interpreter
# through `#!/usr/bin/env janet`, so which Janet runs them is the PATH's answer
# and the user's to change. It is deliberately *not* the janet a build under
# test produces: `mutate.janet` breaks the runtime on purpose, and a sweep
# whose own driver runs on the mutant scores itself.

### Where the repository is
#
# Every path these tools use -- `build.zig`, `src/`, `test/`, `.zig-cache` --
# is relative to the repository root, which is one level up from this file.
# **That is why this file is not itself in a subdirectory.**

(def root
  (let [self (os/realpath (dyn :current-file))
        parts (string/split "/" self)]
    (string/join (slice parts 0 -3) "/")))

### Running a command, with a bound and with its children

# A hung build is not one process. `zig build test` starts compiler workers and
# a janet running the suites, so killing the shell leaves the interesting part
# alive -- and Phase 10 Part 16 watched a timed-out `zig build test` keep a
# parked `suite-ev.wattle` running for forty-seven minutes, competing for the
# machine and for the `unique.txt` every matrix entry creates in the working
# directory. A timeout that leaves the thing it timed out running poisons every
# entry after it.
#
# `matrix.py` handled this with `start_new_session=True` and `killpg`. Janet's
# `os/spawn` passes no `posix_spawnattr_t`, so a child stays in the driver's own
# process group and killing that group would kill the driver. So the tree is
# walked instead: read every (pid, ppid) pair once, take the descendants of the
# process we started, and kill them leaves-first.

(defn- process-table
  "Every (pid ppid) pair on the host, as a table of pid -> ppid.

  Both pipes are drained and the wait is bounded, for the reason `sh` states
  below: a command that fills one pipe while nothing reads the other deadlocks.
  This one read `:out` alone and had no deadline, and it runs only from
  `kill-tree`, which runs only when a bound has already been exceeded. An
  unbounded wait there turns a run that was over its bound by a second into one
  that never returns. Answering an empty table loses the descendants and kills
  the immediate child alone, which is better than not returning."
  []
  (def out @"")
  (def err @"")
  (def p (os/spawn ["ps" "-Ao" "pid,ppid"] :p {:out :pipe :err :pipe}))
  (try
    (ev/with-deadline 10
      (ev/gather (ev/read (p :out) :all out)
                 (ev/read (p :err) :all err)
                 (os/proc-wait p)))
    ([_] (protect (os/proc-kill p))))
  (def table @{})
  (each line (string/split "\n" (string out))
    (def fields (filter |(not (empty? $)) (string/split " " (string/trim line))))
    (when (= 2 (length fields))
      (def pid (scan-number (fields 0)))
      (def ppid (scan-number (fields 1)))
      (when (and pid ppid) (put table (math/trunc pid) (math/trunc ppid)))))
  table)

(defn kill-tree
  "Kill `pid` and every process descended from it, leaves first.

  Leaves first, because killing a parent first can leave a child reparented to
  init and unfindable a moment later."
  [pid &opt signal]
  (default signal :kill)
  (def parents (process-table))
  (def children @{})
  (eachp [child parent] parents
    (put children parent (array/push (get children parent @[]) child)))
  (defn descend [p]
    (def out @[])
    (each child (get children p @[])
      (array/concat out (descend child)))
    (array/push out p))
  (def victims (map string (descend pid)))
  # `kill` rather than `os/proc-kill`: only the immediate child is a
  # core/process, and the descendants are bare pids. One invocation rather than
  # one each, and `kill` signals its arguments in the order they are given, so
  # the leaves-first ordering above survives the batching.
  (os/execute ["/bin/sh" "-c"
               (string "kill -" (if (= signal :kill) "KILL" "TERM") " "
                       (string/join victims " ") " 2>/dev/null")]
              :p))

(defn sh
  "Run `cmd` through `/bin/sh`, capturing both streams, with a bound.

  Returns `{:out :err :code :timeout}`. On a timeout `:code` is nil, `:timeout`
  is true, and `:out`/`:err` hold whatever the command had produced before it
  was killed -- which is usually the useful part.

  The wait runs in a fiber of its own rather than under the deadline, and the
  deadline is on a take from the channel it reports through. Cancelling
  `os/proc-wait` itself leaves the process permanently unwaitable -- the flag
  that says a wait is in flight is never cleared -- so the process would leak as
  a zombie for the rest of the run. Killing the tree and then letting the
  original wait complete reaps it."
  [cmd &named timeout]
  (default timeout 300)
  (def p (os/spawn ["/bin/sh" "-c" cmd] :p {:out :pipe :err :pipe}))
  (def out @"")
  (def err @"")
  (def done (ev/chan 1))
  # Both pipes are drained concurrently: a command that fills one while nothing
  # reads the other deadlocks, and `zig build` fills both.
  # The `try` is what the timeout path needs: cancelling this fiber injects the
  # cancellation as an error, and an uncaught error in a task Janet supervises
  # is reported to stderr in the middle of the tool's own output.
  (def readers (ev/go (fn [] (try (ev/gather (ev/read (p :out) :all out)
                                             (ev/read (p :err) :all err))
                               ([_] nil)))))
  (ev/go (fn [] (ev/give done (os/proc-wait p))))
  (var code nil)
  (var timed-out false)
  (try
    (set code (ev/with-deadline timeout (ev/take done)))
    ([_]
      (set timed-out true)
      (kill-tree (p :pid))
      # The waiter now completes on its own, which reaps. The readers may still
      # be held open by a descendant that outlived the signal, so they get a
      # short bound of their own rather than the command's.
      (try (ev/with-deadline 10 (ev/take done)) ([_] nil))
      (try (ev/with-deadline 10 (ev/cancel readers "timed out")) ([_] nil))))
  # Bounded for the same reason as the two waits above: this is the last step
  # of a path that only runs when a bound was already exceeded, and it is the
  # one step of it that had no bound of its own.
  (try (ev/with-deadline 10 (protect (os/proc-close p))) ([_] nil))
  {:out (string out) :err (string err) :code code :timeout timed-out})

(defn ok?
  "Whether a `sh` result ran to completion with status zero."
  [r]
  (and (not (r :timeout)) (= 0 (r :code))))

(defn both
  "A `sh` result's two streams, in the order a reader wants them."
  [r]
  (string (r :out) (r :err)))

### Files

(defn rm-rf
  "Remove `path` and anything under it. Silent if it is not there.

  `os/lstat` rather than `os/stat`, so a symlink to a directory is unlinked
  rather than descended into."
  [path]
  (def mode (try (os/lstat path :mode) ([_] nil)))
  (cond
    (nil? mode) nil
    (= mode :directory)
    (do
      (each entry (try (os/dir path) ([_] []))
        (rm-rf (string path "/" entry)))
      (try (os/rmdir path) ([_] nil)))
    (try (os/rm path) ([_] nil))))

(defn- wildcard?
  "Whether `name` matches `pattern`, where `*` matches any run of characters."
  [pattern name]
  (cond
    (empty? pattern) (empty? name)
    (= (pattern 0) (chr "*"))
    (or (wildcard? (slice pattern 1) name)
        (and (not (empty? name)) (wildcard? pattern (slice name 1))))
    (and (not (empty? name)) (= (pattern 0) (name 0)))
    (wildcard? (slice pattern 1) (slice name 1))
    false))

(defn glob
  "Paths matching `pattern`, whose last component may hold `*`.

  Enough for the debris lists; not a general glob. A pattern with no wildcard is
  returned when it exists, which is how a plain filename is handled."
  [pattern]
  (def parts (string/split "/" pattern))
  (def dir (if (= 1 (length parts)) "." (string/join (slice parts 0 -2) "/")))
  (def leaf (last parts))
  (if (string/find "*" leaf)
    (seq [entry :in (try (os/dir dir) ([_] []))
          :when (wildcard? leaf entry)]
      (if (= dir ".") entry (string dir "/" entry)))
    (if (os/lstat pattern) [pattern] [])))

(defn dir-bytes
  "Total size of every regular file under `path`."
  [path]
  (var total 0)
  (defn walk [p]
    (def mode (try (os/lstat p :mode) ([_] nil)))
    (cond
      (= mode :directory) (each entry (try (os/dir p) ([_] [])) (walk (string p "/" entry)))
      (= mode :file) (+= total (or (try (os/lstat p :size) ([_] 0)) 0))))
  (walk path)
  total)

(defn free-gb
  "Gigabytes available on the volume holding `path`.

  `df -k` rather than a `statvfs` binding, because Janet has none. This reads
  the same number Python's `shutil.disk_usage` did, with the same macOS caveat
  `mutate.janet`'s `min-free-gb` records: it knows nothing about purgeable
  space."
  [path]
  (def r (sh (string "df -k " path) :timeout 30))
  (def lines (string/split "\n" (string/trim (r :out))))
  (if (< (length lines) 2)
    0
    (let [fields (filter |(not (empty? $)) (string/split " " (last lines)))]
      # Filesystem, 1024-blocks, Used, Available, ...
      (if (< (length fields) 4)
        0
        (/ (or (scan-number (fields 3)) 0) (* 1024 1024))))))

### Reporting

(defn head
  "The first `n` characters of `s`, the way Python's `s[:n]` reads."
  [s n]
  (if (> (length s) n) (string/slice s 0 n) (string s)))

(defn tail
  "The last `n` characters of `s`, the way Python's `s[-n:]` reads."
  [s n]
  (if (> (length s) n) (string/slice s (- n)) (string s)))

(defn die
  "Print to stderr and exit non-zero, the way `sys.exit(str)` did."
  [& parts]
  (eprint ;parts)
  (os/exit 1))

### Reading Zig without reading its comments
#
# Phase 12's rule 26: source is not a string. Within one increment a script
# edited a comment, a user-visible docstring inside a string literal, and
# matched `c.janet_vm` inside `c.janet_vm_alloc` -- three instances of the
# same bug, and the compiler could only see the third. `seam.janet` had
# already learned to strip comments, because rule 6 cost it a count; the rule
# says the stripper belongs here rather than in the one tool that learned it,
# so that the next tool reaches for it instead of re-deriving it.

(defn code-spans
  "The `[start end)` ranges of `line` that are Zig code.

  Before any `//` comment or `\\` multiline string literal, both of which run
  to the end of the line -- which is what makes this tractable without a
  lexer, because Zig has no block comments.

  `keep-literals` decides what a quoted string or character literal counts as,
  and the answer differs by what the caller is doing. A caller that **edits**
  source wants them excluded, so that a name inside a docstring is not
  rewritten -- rule 26's invisible instance. A caller that **reads** source
  often wants them included, because `@export(&f, .{ .name = \"janet_f\" })`
  puts the symbol it is looking for inside one. Default is to exclude."
  [line &opt keep-literals]
  (def out @[])
  (def n (length line))
  (var i 0)
  (var start 0)
  (var state :code)
  (var done false)
  (defn leave [at] (unless keep-literals (array/push out [start at])))
  (while (and (< i n) (not done))
    (def ch (line i))
    (def next (if (< (+ i 1) n) (line (+ i 1)) 0))
    (case state
      :code
      (cond
        (= ch (chr "\"")) (do (leave i) (set state :string) (+= i 1))
        (= ch (chr "'")) (do (leave i) (set state :char) (+= i 1))
        (and (= ch (chr "/")) (= next (chr "/"))) (do (array/push out [start i]) (set done true))
        (and (= ch (chr "\\")) (= next (chr "\\"))) (do (array/push out [start i]) (set done true))
        (+= i 1))
      # An escape consumes the next byte whatever it is, so a literal `\"`
      # does not close the string and `'\''` does not close the character.
      :string
      (cond
        (= ch (chr "\\")) (+= i 2)
        (= ch (chr "\"")) (do (+= i 1) (unless keep-literals (set start i)) (set state :code))
        (+= i 1))
      :char
      (cond
        (= ch (chr "\\")) (+= i 2)
        (= ch (chr "'")) (do (+= i 1) (unless keep-literals (set start i)) (set state :code))
        (+= i 1))))
  (when (and (not done) (= state :code)) (array/push out [start n]))
  out)

(defn strip-comments
  "`text` with `//` comments and `\\\\` literals blanked, newlines preserved.

  What a *reader* of Zig source wants: the code, at the line numbers it
  actually occupies. Non-code bytes become spaces rather than vanishing, so a
  column is still a column.

  `keep-literals` decides whether a quoted string or character literal counts
  as code, and defaults to true. A caller asking *whether a name is written
  anywhere* wants false: a name inside a docstring, a registration string or an
  `@import` path is prose or a path rather than a use of the declaration, and
  counting one hides a dead declaration behind its own mention.

  Moved here from `seam.janet` for rule 26, unchanged in what it counts --
  verified line by line over the runtime source and `test/` before the swap.
  That tool counted a reference inside a comment as a call until rule 6, and
  the check that says the stripper works is that a comment-only reference
  scores as absent."
  [text &opt keep-literals]
  (default keep-literals true)
  (def out @"")
  (def lines (string/split "\n" text))
  (for k 0 (length lines)
    (def line (lines k))
    (def blank (buffer/new-filled (length line) (chr " ")))
    (each [s e] (code-spans line keep-literals)
      (buffer/blit blank line s s e))
    (buffer/push out blank)
    (when (< k (- (length lines) 1)) (buffer/push out "\n")))
  (string out))

(def src-dirs
  ``The three directories the runtime's Zig lives in, in the order a tool
  should walk them.

  A directory says which compilation includes its files: `src/api` is compiled
  into a native module's `.so` as well as the runtime, `src/host` is the
  platform's shapes and what libc is asked for, and `src/runtime` is the
  runtime as one compilation. The two package roots sit above all three at the
  top of `src/`: `root.zig`, which the runtime compiles, and `module.zig`,
  which a native module's `.so` compiles. `src-files` walks both with the
  directories.

  Every instrument walks this rather than naming a directory of its own, so
  one edit here changes the population every inventory measures.``
  ["src/api" "src/host" "src/runtime"])

(def outside-runtime-root
  "The files under `src/` that are not part of the `subsystems` module.

  This set had a shorter name while the subsystems sat in a directory of their
  own: it was \"not under that directory\", and half a dozen tools tested the
  prefix. The directory was carrying the distinction, and flattening it spent
  that -- so the knowledge is written down here instead, which is where it
  should have been.

  `boot`, `boot_tests`, `cli`, `interop` and `native_module` are their own
  compilations and reach a subsystem through the linker; giving one an
  `@import` of a subsystem puts the same file in two modules, which Zig
  refuses outright (`convert.janet` found that by doing it to `raise.zig`).
  `cabi`, `constants`, `types`, `raise` and `corefn` are shared modules
  beneath the subsystems.

  **Phase 12 increment 5f took six entries out of this set, and four of them
  had already gone stale.** `abi.zig`, `abi_test.zig`, `types_check.zig` and
  `constants_check.zig` were deleted with `janet.h`, which is what those last
  three existed to compare against. `runtime.zig` had been gone since 6h and
  the three `*_abi.zig` since 6f -- the docstring here said they would leave
  the set at 6f's optional-features batch, and 6f moved the files without
  coming back for the list. A stale key is inert rather than wrong, which is
  why nothing said so; rule 23's shape in a tool's data.

  **Phase 14 increment 4a put an `abi.zig` back, and it is not that one.** The
  deleted file translated `janet.h`; this one holds what the runtime and a
  separately compiled module must agree on, and it is a module root of its own
  for that reason."
  {"src/api/abi.zig" true
   "src/host/cabi.zig" true
   "src/api/constants.zig" true
   "src/runtime/corefn.zig" true
   "src/runtime/native_module.zig" true
   "src/api/raise.zig" true})

(defn runtime-file?
  "Whether `path` is one of the files the `subsystems` module compiles.

  The test a tool wants when it asks \"may I rewrite this\": everything under
  one of `src-dirs` except `outside-runtime-root`."
  [path]
  (and (some |(string/has-prefix? (string $ "/") path) src-dirs)
       (not (outside-runtime-root path))))

(defn zig-files
  "Every `.zig` file under `dir`, sorted, as repository-relative paths."
  [dir]
  (def out @[])
  (defn walk [d]
    (each entry (sort (os/dir d))
      (def path (string d "/" entry))
      (case (os/stat path :mode)
        :directory (walk path)
        :file (when (string/has-suffix? ".zig" entry) (array/push out path)))))
  (walk dir)
  out)

(defn src-files
  ``Every `.zig` file of the runtime's own source, repo-relative.

  The two package roots -- `src/root.zig` and `src/module.zig` -- plus
  everything under `src-dirs`. This is the population every inventory under
  `res/check` measures, and leaving a root out of it silently shrinks every
  one of them.``
  []
  (def out @["src/module.zig" "src/root.zig"])
  (each d src-dirs (array/concat out (zig-files d)))
  out)

(defn word-byte?
  "Whether `b` may appear inside a Zig identifier."
  [b]
  (or (and (>= b (chr "a")) (<= b (chr "z")))
      (and (>= b (chr "A")) (<= b (chr "Z")))
      (and (>= b (chr "0")) (<= b (chr "9")))
      (= b (chr "_"))))

(defn path-dot?
  ``Whether the byte before `i` in `line` is a `.` that continues a path.

  The guard a whole-identifier-path match needs on its left: `abi.c` and
  `.{ .c = 1 }` both put a `.` before `c` and neither is a fresh identifier,
  so both are refused. **The second dot of `..` is not one of them.** Zig
  spells a range `0..c.JANET_COUNT_TYPES`, and reading that dot as a path dot
  skips the site -- which is what `alias.janet` did to two sites in
  `test/value_wrap.zig` in Phase 12 increment 5g, and what the build then
  said. Every rewriter here wants the same answer, so it lives here rather
  than in the tool that learned it.``
  [line i]
  (and (> i 0)
       (= (line (- i 1)) (chr "."))
       (not (and (> i 1) (= (line (- i 2)) (chr "."))))))

(defn rewrite-code
  "`text` with each key of `subs` replaced by its value, in code only.

  `subs` maps a source spelling to its replacement. A match must be a whole
  identifier path: the byte before it may not be part of an identifier and may
  not be a path `.` (see `path-dot?`), and the byte after it may not be part
  of an identifier. That is what keeps `c.janet_vm` out of `c.janet_vm_alloc`
  and `&c.janet_vm.field` from losing its `&` -- rule 26's two
  compiler-visible instances.

  Returns `[text' count]`. Longest key first, so `c.janet_table_get_ex` is not
  eaten by `c.janet_table_get`."
  [text subs]
  (def keys-by-length (sort-by |(- (length $)) (keys subs)))
  (def out @"")
  (var total 0)
  (def lines (string/split "\n" text))
  (for k 0 (length lines)
    (def line (lines k))
    (def spans (code-spans line))
    (var cursor 0)
    (each [s e] spans
      (buffer/push out (string/slice line cursor s))
      (var i s)
      (while (< i e)
        (var hit nil)
        (def before (if (> i 0) (line (- i 1)) 0))
        (unless (or (word-byte? before) (path-dot? line i))
          (each key keys-by-length
            (when (nil? hit)
              (def j (+ i (length key)))
              (when (and (<= j e) (= key (string/slice line i j))
                         (or (>= j (length line)) (not (word-byte? (line j)))))
                (set hit key)))))
        (if hit
          (do (buffer/push out (subs hit)) (+= i (length hit)) (++ total))
          (do (buffer/push out (string/slice line i (+ i 1))) (+= i 1))))
      (set cursor e))
    (buffer/push out (string/slice line cursor))
    (when (< k (- (length lines) 1)) (buffer/push out "\n")))
  [(string out) total])
