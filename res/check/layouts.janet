#!/usr/bin/env janet
# Every C-compatible layout in the tree, with the evidence that fixes it.
#
# Phase 13 Part 2, increment 2e.  The exit condition asks for every exported
# symbol *and every C-compatible layout* to be classified, and `exports.janet`
# only answers the first half.
#
# ## The compiler is not the oracle here, and that was measured
#
# Stripping `extern` from all 104 declarations and building compiles once 24
# are restored -- Zig refuses a non-extern aggregate in a `callconv(.c)`
# signature, and refuses an `extern struct` with a non-extern field, so those
# two reasons are checked.  The resulting binary then **aborts in the
# bootstrap**, because a third reason is not checked: a layout whose field
# order or in-memory representation something reads directly.  Zig may reorder
# the fields of an ordinary struct, and `std.mem.zeroes`, a `@ptrCast` to
# another view, an `@offsetOf` and a `memcpy` are all silent about it.
#
# So a classification driven by the compiler would be confidently wrong.  This
# collects the evidence for each of the three reasons instead:
#
#   abi     the type, or a pointer to it, is in a `callconv(.c)` signature
#           -- in *code*: the corpus below has its comments stripped first
#   field   it is a by-value field of another `extern` layout
#   repr    something reads its representation -- `@sizeOf`, `@offsetOf`,
#           `@bitCast`, `@ptrCast`, `std.mem.zeroes`, `safe_memcpy`
#   host    its file translates a header, or its name is a foreign structure
#
# A layout with none of the four is migration residue: it is `extern` because
# the C implementation's was, and nothing has reconsidered it.
#
#     ./res/check/layouts.janet           regenerate res/check/layouts.txt
#     ./res/check/layouts.janet --check   fail if the tree disagrees with it

(import ../common :as tools)

(def list-path "res/check/layouts.txt")

# Structures a platform, not this project, defines.  Named rather than
# detected: `OVERLAPPED` is Win32's whatever file spells it.
(def foreign
  {"OVERLAPPED" true "Overlapped" true "OverlappedWatch" true
   "WSABUF" true "FILETIME" true
   "SecurityAttributes" true "ITimerSpec" true "utimbuf" true
   "pthread_attr_t" true "pthread_mutex_t" true
   "Sysv64IntReturn" true "Sysv64SseReturn" true "Sysv64IntSseReturn" true
   "Sysv64SseIntReturn" true "Aapcs64ReturnGeneral" true
   "Aapcs64ReturnSse" true "Aapcs64ReturnPointer" true "JittedFn" true})

# The layouts the *compiler* proves must stay `extern`, from the experiment in
# this file's header: strip `extern` from every layout not listed here, build,
# restore whatever Zig names, repeat.  It converges in three rounds.
#
# **This list cannot be derived by reading the source, and that is the point.**
# `raise.panicking(f).abi`, `args.zig`'s `IndexAbi` and `Boxed(T)` generate
# their `callconv(.c)` signature from a comptime type, so the layout's name
# never appears beside the calling convention anywhere -- no grep can see the
# crossing.  `Range` is the clearest: `raise.zig` returns one from a
# generated abi and `args.zig` says nothing about it.
#
# `./res/check/layouts.janet --verify` re-runs the experiment against this
# list, and first refuses any entry that no longer names an `extern`
# declaration -- the strip skips these names, so a stale one is invisible to it.
#
# ## What the evidence column cannot see
#
# **Evidence is collected per *name*, and four names are declared in more than
# one file.** `Overlapped` is in `ev/stream.zig`, `net.zig` and
# `filewatch/abi.zig`; `OVERLAPPED`, `Method` and `CMethod` in two each. A use
# of the bare identifier anywhere is counted as evidence for every declaration
# that shares the name, so the column over-attributes across those four and a
# genuinely unevidenced one could be rescued by a same-named neighbour. None is
# today: every row involved is fixed by `host` and `field`, which are decided
# from the declaration's own file and members. It is a hole in the `residue`
# class and it is named here rather than hidden, because the row it would hide
# is exactly the row this list exists to show.
(def compiler-fixed
  {"Aapcs64ReturnGeneral" true "Aapcs64ReturnPointer" true
   "Aapcs64ReturnSse" true "AssembleResult" true
   "Binding" true "BuildConfig" true "ByteView" true
   "DictView" true "GenericMessage" true "FuncEnvRef" true
   "GCData" true "GCObject" true "Range" true
   # `Value` is the one comptime-selected declaration in the list, and it was
   # invisible until the strip learned to reach an arm head. `repr.Value` is a
   # parameter and a return type across the C ABI in every representation, so
   # the compiler refuses the stripped form the moment `cabi.zig` is analysed.
   "Value" true})

(defn- declaration-end
  "The index of the last line of the declaration opening at line `i`: the
  first `;` seen at brace depth zero."
  [lines i]
  (var depth 0)
  (var j i)
  (var done false)
  (while (and (not done) (< j (length lines)))
    (def line (lines j))
    (var k 0)
    (while (< k (length line))
      (case (line k)
        (chr "{") (++ depth)
        (chr "}") (-- depth)
        (chr ";") (when (<= depth 0) (set done true)))
      (if done (set k (length line)) (++ k)))
    (if done (break) (++ j)))
  (min j (dec (length lines))))

(defn- arm-head?
  "Whether `line` opens one arm of a comptime-selected layout.  An arm head
  names `extern struct`/`extern union` with nothing but the selection in front
  of it -- `} else extern struct {`, `.nanbox_64 => extern union {`, or the
  tail of the declaring line.  A nested declaration (`pub const x = extern
  struct {}` inside a namespace arm) and a field whose type is written out
  (`foo: extern struct {`) are both excluded, because neither is this
  declaration's own layout."
  [line]
  (var answer false)
  (each needle ["extern struct" "extern union"]
    (when (def k (string/find needle line))
      (def before (string/trimr (string/slice line 0 k)))
      (when (and (not (string/find "const " before))
                 (not (string/has-suffix? ":" before)))
        (set answer true))))
  answer)

(defn- declarations
  "`[{:file :line :name}]` for every `extern struct`/`extern union` declared
  with a name, in source order.

  **A conditional declaration counts once, under its name.**  `Janet`,
  `JanetFiber`, `Timeout`, `NetStateAccept`, `Vm`'s `VmEv` and its
  `VmBackend` each select an `extern` layout with a comptime `if` or `switch`,
  so the arms have no names of their own -- and until Phase 13 increment 3a
  this function saw none of the six, because it required `= extern` on the
  declaring line.  That is `NITS.md`'s Part 2 item 3, closed for the naming
  half: the row is the name, and the arm count is not a column because a
  configuration compiles exactly one of them."
  []
  (def out @[])
  (each path (tools/src-files)
    (def lines (string/split "\n" (slurp path)))
    (loop [i :range [0 (length lines)]]
      (def m (peg/match ~(* (thru "const ") (<- (some (+ :w "_"))) " = " (<- (thru -1)))
                        (lines i)))
      (when m
        (def [name rest] m)
        (def direct (peg/match ~(* "extern " (+ "struct" "union")) rest))
        (def conditional
          (and (not direct)
               (peg/match ~(+ "if (" "switch (" "(if (") rest)
               (do (var found false)
                   (def stop (declaration-end lines i))
                   (loop [j :range [i (inc stop)]]
                     (when (arm-head? (lines j))
                       (set found true)
                       (break)))
                   found)))
        (when (or direct conditional)
          (array/push out {:file (string/replace "src/" "" path)
                           :line (inc i)
                           :name (string name)})))))
  out)

(defn- corpus []
  (def out @{})
  # **Comments stripped, because prose is not evidence.**  The scan below
  # decides `abi` by finding `callconv(.c)` or `extern fn` near an occurrence
  # of the name, and a comment that merely *mentions* a layout beside an
  # `extern fn` declaration satisfied that.  Five of the 63 rows carried
  # evidence they did not have -- `Method` from a sentence in the module's
  # declaration file naming `abi.Method` above an `extern fn` block, three
  # `OVERLAPPED` rows
  # the same way, and `ffi/types.Layout`, which is used only inside its own
  # file and was `fixed` by a paragraph containing the words "extern fn".
  # Found at Phase 17 Part 2f, when rewriting one of those sentences moved a
  # row.  `strip-comments` keeps string literals, so a name inside an
  # `@export(.{ .name = "..." })` still counts.
  (each path (tools/src-files)
    (put out path (tools/strip-comments (slurp path))))
  out)

(defn- word-hits
  "Every path whose text names `word` as a whole identifier."
  [text word]
  (def out @[])
  (var at 0)
  (while (def i (string/find word text at))
    (def before (if (zero? i) nil (text (dec i))))
    (def after (get text (+ i (length word))))
    (when (and (or (nil? before) (not (tools/word-byte? before)))
               (or (nil? after) (not (tools/word-byte? after))))
      (array/push out i))
    (set at (+ i (length word))))
  out)

(defn- matching-close
  "The index of the `}` closing the `{` at `open`, or the end of `text`."
  [text open]
  (var depth 0)
  (var k open)
  (def n (length text))
  (while (< k n)
    (def ch (get text k))
    (when (= ch (chr "{")) (++ depth))
    (when (= ch (chr "}"))
      (-- depth)
      (when (= depth 0) (break)))
    (++ k))
  k)

(defn- container-is-extern
  "Whether the aggregate enclosing byte `i` was declared `extern`.  Read by
  finding the nearest aggregate opening before `i`, which is what decides
  whether a field of this type is a field of an `extern` layout.  The
  enclosure is checked: an opening whose matching close falls before `i` does
  not enclose it and is passed over."
  [text i]
  (var best -1)
  (var answer false)
  (each needle ["struct {" "union {"]
    (var at 0)
    (while (def k (string/find needle text at))
      (if (< k i)
        (do (when (and (> k best)
                       (< i (matching-close text (+ k (length needle) -1))))
              (set best k)
              (set answer (and (>= k 7) (= "extern " (string/slice text (- k 7) k)))))
            (set at (+ k 1)))
        (break))))
  (and (>= best 0) answer))

(defn- crosses-c
  "Whether the occurrence at `i` is inside a `callconv(.c)` signature: scan
  forward to the first `{` or `;` and see which comes first."
  [text i]
  (def brace (or (string/find "{" text i) (length text)))
  (def semi (or (string/find ";" text i) (length text)))
  (def stop (min brace semi))
  (def cc (string/find "callconv(.c)" text i))
  (def parens (string/find-all "(" (string/slice text 0 i)))
  (def open-paren (if (empty? parens) 0 (last parens)))
  (def head (string/slice text (max 0 (- open-paren 60)) i))
  (or (and cc (< cc stop)) (string/find "extern fn" head)))

(defn- line-around [text i]
  (def lo (or (last (string/find-all "\n" (string/slice text (max 0 (- i 400)) i))) 0))
  (def start (+ (max 0 (- i 400)) lo))
  (def end (or (string/find "\n" text i) (length text)))
  (string/slice text start end))

(defn- evidence [decls texts]
  (def out @{})
  (each d decls
    (def name (d :name))
    (def tags @{})
    (when (get foreign name) (put tags "host" true))
    # The three host-header translations are the `abi.zig` files inside the
    # runtime -- `os/`, `net/`, `filewatch/`. `api/abi.zig` is the module
    # boundary and is not one of them, so the suffix alone is not the test.
    (when (and (string/has-prefix? "runtime/" (d :file))
               (string/has-suffix? "/abi.zig" (d :file)))
      (put tags "host" true))
    (when (get compiler-fixed name) (put tags "abi" true))
    # A layout with a member typed out of the file's `@cImport` is the
    # platform's whatever its own name is: `net.zig`'s `OptValue` holds a
    # `struct_ip_mreq` and its bytes go to `setsockopt`.
    (let [text (get texts (string "src/" (d :file)) "")
          at (string/find (string "const " name " = extern") text)]
      (when at
        (def close (or (string/find "\n};" text at) (length text)))
        (def body (string/slice text at close))
        (when (peg/match ~(* (thru (* ":" :s* (+ "h." "c."))) (thru -1)) body)
          (put tags "host" true))))
    (eachp [path text] texts
      (each i (word-hits text name)
        # The declaration is not evidence about itself.  Skipping it is the
        # whole difference between "104 layouts, 0 residue" and a measurement.
        (def decl (string/slice text (max 0 (- i 12)) (min (length text) (+ i (length name) 10))))
        (unless (and (string/find "const " decl) (string/find " = extern" decl))
          (def line (line-around text i))
          # A parameter is found by scanning forward to the first `{`; a
          # *return* type is on the same line as the convention, because
          # `) callconv(.c) T {` puts them together.
          # An `extern fn` declaration is a C-ABI crossing that never spells
          # the convention, so the literal is not enough to look for.
          (when (or (string/find "callconv(.c)" line)
                    (string/find "extern fn" line)
                    (crosses-c text i))
            (put tags "abi" true))
          (when (or (string/find (string "@sizeOf(" name ")") text)
                    (string/find (string "@offsetOf(" name) text)
                    (string/find (string "zeroes(" name ")") text)
                    (string/find "@ptrCast" line)
                    (string/find "@bitCast" line)
                    (string/find "memcpy" line))
            (put tags "repr" true))
          (when (and (peg/match ~(* :s* (some (+ :w "_")) ":" :s* (thru -1)) line)
                     (container-is-extern text i))
            (put tags "field" true)))))
    (put out name (sort (keys tags))))
  out)

(defn classify []
  (def decls (declarations))
  (def ev (evidence decls (corpus)))
  (map (fn [d]
         (def tags (get ev (d :name) @[]))
         (merge d {:tags tags
                   :class (if (empty? tags) "residue" "fixed")}))
       decls))

(defn render [rows]
  (def out @"")
  (def residue (count |(= ($ :class) "residue") rows))
  (buffer/push out
    "# Every C-compatible layout, with the evidence that fixes it.\n"
    "# Generated by `./res/check/layouts.janet`; do not edit.\n"
    "#\n"
    "# `abi`   the type, or a pointer to it, is in a `callconv(.c)` signature\n"
    "# `field` it is a by-value field of another `extern` layout\n"
    "# `repr`  something reads its representation -- `@sizeOf`, `@offsetOf`,\n"
    "#         `@bitCast`, `@ptrCast`, `std.mem.zeroes`, a `memcpy`\n"
    "# `host`  its file translates a header, or a platform defines the name\n"
    "#\n"
    "# A row with no evidence is migration residue: `extern` because the C\n"
    "# implementation's was.  **The compiler checks only `abi` and `field`** --\n"
    "# stripping `extern` from all of them builds once those are restored, and\n"
    "# the binary then aborts in the bootstrap.  See this tool's header.\n"
    "#\n"
    (string/format "# layouts  %d\n# residue  %d\n#\n" (length rows) residue)
    "# columns: class  name  file:line  evidence\n\n")
  # Sorted by name *and* file, because the sort is not stable and several names
  # carry more than one row -- `Overlapped` has three, `SignedHead` four. Keyed
  # on the name alone those rows permuted between two runs over an unchanged
  # tree, so a diff of this file reported churn that was the sort's and not the
  # tree's.
  (each r (sort-by |(string ($ :name) "\0" ($ :file)) rows)
    (buffer/push out (string/format "%-8s %-28s %-34s %s\n"
                                    (r :class) (r :name)
                                    (string (r :file) ":" (r :line))
                                    (string/join (r :tags) ","))))
  (string out))

(defn parse
  ``A rendered list as `{"name file" -> {:class :tags}}`.

  **Keyed without the line number, and comparing the evidence.** The key was
  `name file:line`, so a comment gaining a line above a declaration retired one
  row and introduced another with the same class -- noise that had to be
  eyeballed every time, and noise is where a real change hides. `Overlapped`
  is declared in three files and `Method`, `CMethod` and `OVERLAPPED` in two
  each, so the file stays in the key and only the line leaves it.

  The `evidence` column was written and never read back, which is the same hole
  the export inventory's `audience` column had.``
  [text]
  (def out @{})
  (each line (string/split "\n" text)
    (def t (string/trim line))
    (unless (or (empty? t) (string/has-prefix? "#" t))
      (def f (filter |(not (empty? $)) (string/split " " t)))
      (def loc (get f 2))
      (def file (first (string/split ":" loc)))
      (put out (string (get f 1) " " file)
           {:class (get f 0) :tags (string/join (slice f 3) " ")})))
  out)

# One directory per invocation, so two runs cannot share a scratch tree and a
# crashed run cannot poison the next one. The live tree is never written.
(def workdir
  (string "/tmp/janet-layouts-" (os/getpid) "-" (math/floor (os/clock :monotonic))))

(defn verify
  ``Strip `extern` from every layout this file does *not* list as
  compiler-fixed, and build.

  It first checks the list for **staleness**, which the strip cannot: a name
  in `compiler-fixed` is skipped, so an entry naming a type that has been
  deleted or has already lost its `extern` is never exercised again.

  Two outcomes and they mean different things.  **No compile diagnostic** means
  `compiler-fixed` is complete: Zig would have refused a non-extern aggregate
  in a `callconv(.c)` signature or as a field of an `extern` one.  A build that
  then fails *downstream* -- at `wattle-boot`, with an abort rather than a
  diagnostic -- is the finding this file exists for, not a defect in the list:
  a layout whose field order or representation something reads is `extern` for
  a reason no compiler checks.

  **It never writes the live tree.** It copies the repository into a scratch
  directory of its own, strips there and builds there. An earlier version
  edited the working tree in place and restored it from a fixed `/tmp` backup
  through
  a `defer`, which covered ordinary control flow and nothing else: a killed or
  crashed run left the tree stripped or, worse, half-restored, and two
  concurrent runs shared one backup. The tree is normally dirty mid-increment,
  so what was at risk was uncommitted work.

  `.git`, `.zig-cache` and `zig-out` are excluded from the copy -- the rest of
  the repository is about 13MB and the build needs all of it, because a build
  reads `build.zig`, `test/` and `examples/` as well as `src/`.``
  []
  (tools/rm-rf workdir)
  (def copy (tools/sh (string "mkdir -p " workdir " && tar -c "
                              "--exclude=./.git --exclude=./.zig-cache "
                              "--exclude=./zig-out --exclude=./.cache "
                              ". | tar -x -C " workdir)
                      :timeout 300))
  (unless (zero? (copy :code))
    (tools/rm-rf workdir)
    (tools/die "could not copy the repository into " workdir))
  # An entry that no longer names an `extern` declaration is dead weight the
  # strip below cannot see: it skips names in `compiler-fixed`, so a stale one
  # is silently "fixed" for ever. Phase 14 Part 4b found eleven at once --
  # three types that had been deleted and eight whose `extern` had come off
  # without the compiler objecting -- and `--verify` had passed throughout,
  # because completeness and staleness are different questions.
  (def declared (tabseq [d :in (declarations)] (d :name) true))
  (def stale (sort (seq [name :keys compiler-fixed :when (not (get declared name))] name)))
  (unless (empty? stale)
    (tools/rm-rf workdir)
    (eprint "`compiler-fixed` names " (length stale)
            " layout(s) that no longer exist or are no longer `extern`:")
    (each name stale (eprint "  " name))
    (eprint "drop them from the list in this file; the strip cannot check them.")
    (os/exit 1))

  (var stripped 0)
  (var built nil)
  # No early exit inside this block: a `defer` does not run through `os/exit`,
  # and leaving the scratch tree behind fills /tmp a gigabyte at a time.
  (def decls (declarations))
  (defer (tools/rm-rf workdir)
    (each path (tools/zig-files (string workdir "/src"))
      (def text (slurp path))
      (def lines (string/split "\n" text))
      (var touched false)
      (each d decls
        (when (and (= (string workdir "/src/" (d :file)) path)
                   (not (get compiler-fixed (d :name))))
          (def i (dec (d :line)))
          (def a (string "const " (d :name) " = extern "))
          (if (string/find a (lines i))
            # A direct declaration: one `extern` on the declaring line.
            (do (put lines i (string/replace a (string "const " (d :name) " = ")
                                             (lines i)))
                (set touched true)
                (++ stripped))
            # A comptime-selected declaration: `extern` sits on each arm head
            # instead, and every arm has to lose it or the ones left keep the
            # fixing this is trying to remove. This is `NITS.md`'s Part 2 item 3
            # second half -- the naming half closed at increment 3a, and until
            # this the strip experiment still could not reach a conditional arm.
            (let [stop (declaration-end lines i)]
              (loop [j :range [i (inc stop)]]
                (when (arm-head? (lines j))
                  (put lines j (string/replace-all "extern " "" (lines j)))
                  (set touched true)
                  (++ stripped)))))))
      (when touched (spit path (string/join lines "\n"))))
    (set built (tools/sh (string "cd " workdir " && zig build "
                                 "--cache-dir " workdir "/.zig-cache "
                                 "-p " workdir "/zig-out")
                         :timeout 900)))
  (print "stripped " stripped " layouts the list does not fix")
  (def output (string (built :out) (built :err)))
  (def diagnostics
    (filter |(peg/match ~(* (thru ".zig:") (some :d) ":" (some :d) ": error:") $)
            (string/split "\n" output)))
  (cond
    (not (empty? diagnostics))
    (do (eprint "the compiler still refuses -- `compiler-fixed` is missing:")
        (each d (take 20 diagnostics) (eprint "  " (string/trim d)))
        (os/exit 1))

    (zero? (or (built :code) 1))
    (do (print "the compiler accepts every one, and so does the build.")
        (print "**That is a finding**: nothing left in `res/check/layouts.txt` is")
        (print "held by anything this build exercises.")
        (os/exit 0))

    (do (print "the compiler accepts every one -- `compiler-fixed` is complete.")
        (print "the build then fails downstream, which is why `repr` and `host`")
        (print "are columns: a layout can be `extern` for a reason no compiler")
        (print "checks. The first failing step:")
        (each line (take 6 (filter |(string/find "error:" $) (string/split "\n" output)))
          (print "  " (string/trim line)))
        (os/exit 0))))

(defn main [& argv]
  (os/cd tools/root)
  (when (has-value? argv "--verify") (verify))
  (def check (has-value? argv "--check"))
  (def rows (classify))
  (def text (render rows))
  (if check
    (do
      (def old (parse (slurp list-path)))
      (def new (parse text))
      (var bad 0)
      (each n (sort (keys new))
        (def was (get old n))
        (def is (get new n))
        (cond
          (nil? was) (do (++ bad) (eprint "NEW LAYOUT  " n " (" (is :class) ")"))
          (not= (was :class) (is :class))
          (do (++ bad)
              (eprint "RECLASSED   " n "  " (was :class) " -> " (is :class)))
          (not= (was :tags) (is :tags))
          (do (++ bad)
              (eprint "EVIDENCE    " n "  "
                      (if (empty? (was :tags)) "(none)" (was :tags)) " -> "
                      (if (empty? (is :tags)) "(none)" (is :tags))))))
      # **Disappearance is a failure.** A required fixed layout changed from
      # `extern` to an ordinary one simply leaves the population, and this used
      # to pass. `residue` is the one class that may go quietly: a row with no
      # evidence is `extern` only because the C implementation's was, which is
      # the definition of removable.
      (each n (sort (keys old))
        (unless (get new n)
          (def was (get old n))
          (if (= (was :class) "residue")
            (print "retired     " n "  (residue)")
            (do (++ bad)
                (eprint "REMOVED     " n "  (" (was :class) ", "
                        (was :tags) ") -- a fixed layout may not vanish. "
                        "If it is no longer `extern`, say why here first.")))))
      (if (zero? bad)
        (print "the tree and " list-path " agree -- " (length rows) " layouts")
        (eprint bad " layout(s) disagree"))
      (os/exit (if (zero? bad) 0 1)))
    (do
      (spit list-path text)
      (print "wrote " list-path " -- " (length rows) " layouts")
      (os/exit 0))))
