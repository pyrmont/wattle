#!/usr/bin/env janet
# What the runtime publishes, classified.  Writes `tools/check/exports.txt`.
#
# Phase 13 Part 2, increment 2a.  The exit condition asks for every exported
# symbol to be classified as published, compatibility-only or internal
# residue, and a classification arrived at by reading is not one anybody can
# check.  This is the instrument.
#
# ## `JANET_API` is the classifier, and it is not ours
#
# `src/include/janet.h` went at Phase 12 increment 5f and Git still has it.
# Every declaration it meant as public carries `JANET_API`, which expands to
# `__attribute__((visibility("default")))` -- so the C implementation had
# already partitioned this surface, and the Zig build simply stopped honouring
# the partition: `export fn` and `@export` publish by default and nothing sets
# `.visibility`.
#
# **The header is read from a fixed commit and will not move.**  `janet.h`'s
# last version is `17b3f8c4:src/include/janet.h`, and the nine internal headers
# beside it are read from the same tree.  A replay script's baseline is a
# commit and the user commits between turns -- `AGENTS.md` -- so this one names
# the commit rather than `HEAD^` or a tag.
#
# ## Three classes
#
#   published    `src/zig/module.zig` declares it.  Part 1 decided this set;
#                it is the interface a native-module author writes against,
#                and every name in it was `JANET_API` too.
#   compat       `JANET_API`, and nothing declares it now.  No caller can
#                reach one: the header is not installed and a Zig caller would
#                use `module.zig`.  Retained pending a decision about an
#                embedding interface, which Parts 3 and 5 have to come first.
#   residue      never `JANET_API`.  `src/core/*.h`'s, or in no header at all.
#                The C build did not export these.
#   linker       the linker's own, not ours.
#
# The `audience` column is orthogonal to the class and is what says whether a
# name can simply go: it lists every place in this tree that reaches the
# symbol *through the symbol table* rather than by import.
#
#     ./tools/check/exports.janet           regenerate tools/check/exports.txt
#     ./tools/check/exports.janet --check   fail if the tree disagrees with it

(import ../common :as tools)

(def list-path "tools/check/exports.txt")
(def cache "/tmp/janet-exports-cache")
(def prefix "/tmp/janet-exports-out")

# The commit `janet.h` and the internal headers are read from.  Phase 12
# increment 5f deleted them in `d0c1b0e1`; this is its parent.
(def header-commit "17b3f8c4")
(def internal-headers
  ["compile.h" "emit.h" "fiber.h" "gc.h" "regalloc.h"
   "state.h" "symcache.h" "util.h" "vector.h"])

(defn- run [cmd &opt timeout]
  (def res (tools/sh cmd :timeout (or timeout 900)))
  (unless (zero? (or (res :code) 1))
    (tools/die cmd " failed\n" (string (res :err))))
  (string (res :out)))

(defn- janet-idents
  "Every lowercase `janet…` identifier in `text`, in order."
  [text]
  (map string (peg/match ~(any (+ (<- (* "janet" (some (+ :w "_")))) 1)) text)))

(defn- api-names
  "The names `janet.h` marks `JANET_API`.  The first lowercase `janet…`
  identifier after the marker is the declared one: a return type spells
  `JanetTable` or `JANET_THREAD_LOCAL`, neither of which matches."
  [header]
  (def out @{})
  (each piece (drop 1 (string/split "JANET_API" header))
    (def ends (filter identity [(string/find ";" piece) (string/find "{" piece)]))
    (def decl (if (empty? ends) piece (string/slice piece 0 (min ;ends))))
    (def ids (janet-idents decl))
    (unless (empty? ids) (put out (first ids) true)))
  out)

(defn- strip-c-comments
  "`text` with `/* … */` and `// …` removed.  A comment about a symbol is not
  a declaration of it, and both headers are full of prose that names one --
  `janet.h` mentions `janet_vm` three times and declares it nowhere."
  [text]
  (string (peg/replace-all ~(+ (* "/*" (thru "*/")) (* "//" (thru "\n"))) " " text)))

(defn- header-sets
  "`{name -> header}` over `janet.h` and the nine internal headers, plus the
  `JANET_API` set.  A name is attributed to `janet.h` only when `JANET_API`
  declares it; everything else there is a macro, a prose mention, or a type."
  []
  (def public (strip-c-comments
                (run (string "git show " header-commit ":src/include/janet.h"))))
  (def api (api-names public))
  (def where @{})
  (each n (keys api) (put where n "janet.h"))
  (each h internal-headers
    (def text (strip-c-comments
                (run (string "git show " header-commit ":src/core/" h))))
    (each n (janet-idents text)
      (unless (get where n) (put where n (string "core/" h)))))
  [api where])

(defn- exported
  "The shared library's exported symbols.  Built into its own prefix, because
  `zig-out` belongs to whichever configuration was built last and the export
  count then lies -- `AGENTS.md`."
  []
  (run (string "zig build -Dinstall-tests=true --cache-dir " cache " -p " prefix))
  (def lib (find |(os/stat $ :mode)
                 [(string prefix "/lib/libjanet.dylib")
                  (string prefix "/lib/libjanet.so")]))
  (unless lib (tools/die "built no shared library under " prefix "/lib"))
  (def text (run (string "nm -gU " lib
                         " | awk '$2 ~ /^[TDSBR]$/ {print $3}' | sed 's/^_//' | sort -u")
                 120))
  (filter |(not (empty? $)) (string/split "\n" (string/trim text))))

(defn- native-needs
  "The symbols a native module actually requires, measured rather than read.

  A `.so` built against the `janet` module is linked with
  `linker_allow_shlib_undefined`, so its undefined symbols are exactly what it
  expects the client to publish -- which is the falsifiable form of \"what is
  the published surface\".  It is **not** `module.zig`'s declaration list:
  `raise.zig` reaches `janet_zig_c_raise_take` and `janet_zig_signal_record`
  through `cabi`, and a module that defines a cfunction needs both.  Increment
  2b found that by hiding them and watching `dlopen` refuse the module.

  `build.zig` installs both modules under `<prefix>/test` when
  `-Dinstall-tests=true`, which is why the build above passes it."
  []
  (def out @{})
  (each f (tools/glob (string prefix "/test/*"))
    (when (or (string/has-suffix? ".dylib" f) (string/has-suffix? ".so" f))
      (def text (run (string "nm -u " f " | sed 's/^ *//;s/^_//' | sort -u") 120))
      (each n (string/split "\n" (string/trim text))
        (when (string/has-prefix? "janet" n) (put out n true)))))
  out)

(defn- decl-names
  "Every symbol `paths` reach through the symbol table rather than by import:
  an `extern fn`, `extern const` or `extern var` declaration, and the name an
  `@extern` builtin asks the linker for.  The second form was added for
  `cabi.zig`'s `vm()`, which asked the linker for `janet_vm` without declaring
  it; Phase 13 increment 4e removed both the accessor and the export, and the
  form is kept because it is the one an `@export`ed variable is reached by."
  [paths]
  (def out @{})
  (each p paths
    (when (os/stat p :mode)
      (def text (slurp p))
      (each m (peg/match ~(any (+ (* "extern " (+ "fn " "const " "var ")
                                     (<- (some (+ :w "_"))))
                                  1))
                         text)
        (put out (string m) true))
      (each m (peg/match ~(any (+ (* "@extern(" (to ".name") ".name"
                                     :s* "=" :s* `"` (<- (some (+ :w "_"))) `"`)
                                  1))
                         text)
        (put out (string m) true))))
  out)

(defn- runtime-decl-paths
  "Every `.zig` under `src/zig` except the manifest itself, `cabi.zig` and
  `module.zig`, which get tags of their own.

  **This has to be the whole tree, and increment 2b found out the hard way.**
  The first version read `cabi.zig`, `module.zig` and `test/` only, on the
  belief that a runtime file reaches the seam as `c.janet_x`. Forty-nine
  symbols are reached by a bare `extern fn` written in the subsystem itself --
  `env.zig` declares thirteen `janet_lib_*`, `pp/format.zig` declares
  `janet_io_write` -- which `tools/check/seam.txt` does not count either, because it
  counts the `c.` spelling. Phase 11 Part 16's grep is the general form: an
  `extern fn` inside `src/zig` naming something defined inside `src/zig`."
  []
  (def skip {"src/zig/capi.zig" true "src/zig/cabi.zig" true "src/zig/module.zig" true})
  (filter |(not (get skip $)) (tools/zig-files "src/zig")))

(defn- audiences
  "`{name -> @[tag …]}` for every symbol something here reaches by symbol."
  []
  (def out @{})
  (defn note [name tag]
    (put out name (array/push (or (get out name) @[]) tag)))
  (eachp [tag paths]
         {"module" ["src/zig/module.zig"]
          "cabi" ["src/zig/cabi.zig"]
          "src" (runtime-decl-paths)
          "test" (tools/glob "test/*.zig")
          "example" (tools/glob "examples/*/*.zig")}
    (each n (keys (decl-names paths)) (note n tag)))
  out)

(defn- conditional-exports
  ``Symbols the default build does not export but some configuration does.

  **The default native build is not the population.** `exported` above builds
  one configuration and reads its symbol table, so a symbol that exists only
  under another target or another `-D` option was outside both the inventory
  and its ratchet -- `janet_nanbox32_from_tagi` and `janet_nanbox32_from_tagp`
  are `JANET_API` functions an `x86-linux-musl` build publishes and this one
  never sees.

  Rather than build thirteen configurations here, which would make a check that
  runs every increment cost what `gates.janet` costs, this reads the knowledge
  `gates.janet` has already written down. `gated.txt` is the union over every
  configuration with, per symbol, the configurations that do *not* export it --
  so a row naming `default` among them is exactly a symbol the build above
  cannot see, and the remaining configurations are the ones that produce it.

  That makes the inventory's completeness only as good as `gated.txt`'s
  freshness, which is the honest trade and is stated in the generated header.``
  []
  (def path "tools/check/gated.txt")
  (def out @{})
  (unless (os/stat path :mode) (break out))
  (def all-tags @[])
  (each line (string/split "\n" (slurp path))
    (def t (string/trim line))
    (when (peg/match ~(sequence "#   " (some (choice :w "-"))) t)
      (array/push all-tags (first (string/split " " (string/trim (string/slice t 1)))))))
  (each line (string/split "\n" (slurp path))
    (def t (string/trim line))
    (unless (or (empty? t) (string/has-prefix? "#" t))
      (def f (filter |(not (empty? $)) (string/split " " t)))
      (def name (first f))
      (def missing (slice f 1))
      (when (has-value? missing "default")
        (put out name (sort (filter |(not (has-value? missing $)) all-tags))))))
  out)

(defn classify []
  # The build comes first: `native-needs` reads what it installs.
  (def names (exported))
  (def [api where] (header-sets))
  (def needed (native-needs))
  (def pub-set (merge (tabseq [n :in (keys (decl-names ["src/zig/module.zig"]))] n true)
                      needed))
  (def aud (audiences))
  (eachp [n _] needed
    (put aud n (array/push (or (get aud n) @[]) "native")))
  (def conditional (conditional-exports))
  (def rows @[])
  (each name (sort (distinct (array/concat @[] names (keys conditional))))
    (def cls
      (cond
        (or (= name "__dso_handle") (= name "_mh_dylib_header")) "linker"
        (get pub-set name) "published"
        (get api name) "compat"
        "residue"))
    (def where-built (get conditional name))
    (array/push rows
                {:name name
                 :class cls
                 :header (or (get where name) "-")
                 # A symbol this build cannot see states the configurations
                 # that do produce it, in place of an audience it has no build
                 # to measure.
                 :audience (if where-built
                             (string "only:" (string/join where-built ","))
                             (string/join (sort (distinct (or (get aud name) @[]))) ","))}))
  (sort-by |($ :name) rows))

(defn render [rows]
  (def counts @{})
  (each r rows (put counts (r :class) (inc (or (get counts (r :class)) 0))))
  (def free (count |(and (= ($ :class) "residue") (empty? ($ :audience))) rows))
  (def out @"")
  (buffer/push out
    "# The exported surface, classified.  Generated by `./tools/check/exports.janet`;\n"
    "# do not edit.\n"
    "#\n"
    "# `class` is decided by two facts and no reading: whether a built native\n"
    "# module requires the symbol, and whether the retired `janet.h` marked\n"
    "# the declaration `JANET_API`.  `published` is what `module.zig` declares\n"
    "# **plus what a module's undefined-symbol set actually names**, which is\n"
    "# not the same list -- `raise.zig` reaches two `janet_zig_*` symbols\n"
    "# through `cabi` and a module that defines a cfunction needs both;\n"
    "# `compat` is the rest of `JANET_API`, retained while whether\n"
    "# Claret publishes an embedding interface is undecided; `residue` was\n"
    "# never public even in C, because `-fvisibility=hidden` and an internal\n"
    "# header are what the C build said about it.\n"
    "#\n"
    "# A row whose `audience` reads `only:<tags>` is a **conditional export**:\n"
    "# the default native build does not publish it and the configurations\n"
    "# named do. That population is read from `tools/check/gated.txt` rather\n"
    "# than measured here, so it is as fresh as the last `gates.janet` run.\n"
    "#\n"
    "# `header` is where the name was declared; `audience` is every place in\n"
    "# this tree that reaches the symbol through the symbol table rather than\n"
    "# by import.  A residue row with an empty audience has no caller of any\n"
    "# kind and is what increment 2b retires.\n"
    "#\n"
    (string/format "# headers read from  %s\n#\n" header-commit))
  (each c ["published" "compat" "residue" "linker"]
    (buffer/push out (string/format "# %-12s %5d\n" c (or (get counts c) 0))))
  (buffer/push out
    (string/format "# %-12s %5d\n" "total" (length rows))
    (string/format "#\n# residue with no audience at all  %d\n#\n" free)
    "# columns: class  name  header  audience\n\n")
  # Trailing whitespace on a row an empty final column produced is reported by
  # `git show --check` even though the generator's own gate was silent about
  # it, so each row is trimmed on the right. The padding still aligns the
  # columns that are there.
  (each r rows
    (buffer/push out (string/trimr (string/format "%-10s %-40s %-16s %s"
                                                  (r :class) (r :name)
                                                  (r :header) (r :audience)))
                  "\n"))
  (string out))

(defn- describe-column
  "An empty column reads as nothing at all in a diff line, so name it."
  [v]
  (if (or (nil? v) (empty? v)) "(empty)" v))

(defn parse
  ``A rendered list as `{name -> {:class :header :audience}}`.

  **Every column, not just the class.** `--check` compared classes and wrote
  the other three; a column that is written and never read back is a column
  nothing polices, and `janet_getfile` lost its `src` audience at some
  unknown earlier point with nothing saying so.``
  [text]
  (def out @{})
  (each line (string/split "\n" text)
    (def t (string/trim line))
    (unless (or (empty? t) (string/has-prefix? "#" t))
      (def f (filter |(not (empty? $)) (string/split " " t)))
      (put out (get f 1) {:class (get f 0)
                          :header (get f 2)
                          :audience (string/join (slice f 3) " ")})))
  out)

(defn main [& argv]
  (os/cd tools/root)
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
          (nil? was) (do (++ bad) (eprint "NEW EXPORT  " n " (" (is :class) ")"))
          (not= (was :class) (is :class))
          (do (++ bad)
              (eprint "RECLASSED   " n "  " (was :class) " -> " (is :class)))
          (do
            # The other two columns are evidence for the class, so a silent
            # change to either makes the class unaudited.
            (each col [:header :audience]
              (unless (= (get was col) (get is col))
                (++ bad)
                (eprint "CHANGED     " n "  " col "  "
                        (describe-column (get was col)) " -> "
                        (describe-column (get is col))))))))
      # **Disappearance is a failure.** An accidentally deleted published or
      # compatibility export used to pass this check, because a name simply
      # absent from the tree was reported and forgiven. The one class that may
      # go quietly is `residue`, which is the class whose whole definition is
      # "removable".
      (each n (sort (keys old))
        (unless (get new n)
          (def was (get old n))
          (if (= (was :class) "residue")
            (print "retired     " n "  (residue)")
            (do (++ bad)
                (eprint "REMOVED     " n "  (" (was :class)
                        ") -- a " (was :class) " export may not vanish. "
                        "Reclassify it as residue first, or restore it.")))))
      (if (zero? bad)
        (print "the tree and " list-path " agree -- " (length rows) " symbols")
        (eprint bad " symbol(s) disagree"))
      (os/exit (if (zero? bad) 0 1)))
    (do
      (spit list-path text)
      (print "wrote " list-path " -- " (length rows) " symbols")
      (os/exit 0))))
