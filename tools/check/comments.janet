#!/usr/bin/env janet
# Every comment in the Zig and every paragraph in the Markdown, as text.
#
#     ./tools/check/comments.janet                extract the default set
#     ./tools/check/comments.janet --out DIR      write under DIR instead
#     ./tools/check/comments.janet src/module.zig extract these paths only
#
# ## Why this exists
#
# `STYLE_GUIDE.md` states rules a grep cannot. "No metaphor", "a block states a
# fact and evaluates nothing" and "nothing stands in for the subject" are read
# against a sentence rather than matched against a pattern, so the instruments
# beside this one cannot hold them. What can is a model reading the prose with
# the guide open, and that reading needs the prose separated from the code it
# is embedded in.
#
# This is the extraction half of that. It writes one text file per source file,
# each block preceded by the file and line it came from, so a finding can be
# taken back to its site. It reads the tree and writes under `zig-out`, which
# is gitignored; it makes no network call and edits no source.
#
# ## What a block is
#
# In Zig a block is a run of consecutive lines with the same marker, one of
# `//!`, `///` or `//`, at any indentation. The marker and one following space
# are stripped and the rest is kept verbatim, so a fenced example inside a doc
# comment survives. A `///` line with nothing after it stays inside its run,
# because that is how a doc comment separates its paragraphs. A section banner
# is three `//` lines and so is one block under the same rule.
#
# In Markdown a block is a paragraph: consecutive non-blank lines outside a
# fenced block and outside indented code. A heading is a block of its own.
# Table rows and block quotes are not prose of this kind and are skipped.
#
# ## What it does not cover
#
# Janet sources, including the suites under `test/` and the instruments beside
# this one. The two block rules above are Zig's and Markdown's, and Janet's
# comments would need a third.

(import ../common :as tools)

(def default-out "zig-out/comments")

(def skip-dirs
  "Directory names no walk descends into."
  {".git" true ".zig-cache" true "zig-out" true "port" true "notes" true})

(defn- readmes-under
  "Every `README.md` at or below `dir`, sorted, repository-relative."
  [dir]
  (def out @[])
  (defn walk [d]
    (each entry (sort (os/dir d))
      (def path (string d "/" entry))
      (case (os/stat path :mode)
        :directory (unless (skip-dirs entry) (walk path))
        :file (when (= entry "README.md") (array/push out path)))))
  (walk dir)
  out)

(defn- default-paths
  ``The set covered when no path is given.

  The three source trees, the build script and the three top-level documents.
  Walking a source tree reaches its own READMEs; `tools/` is reached for its
  READMEs alone, because its own sources are Janet.``
  []
  (array/concat @["src" "test" "examples" "build.zig"
                  "DESIGN.md" "STYLE_GUIDE.md" "AGENTS.md"]
                (readmes-under "tools")))

(defn- extractable? [path]
  (or (string/has-suffix? ".zig" path) (string/has-suffix? ".md" path)))

(defn- walk-into
  "Every extractable file under `dir`, sorted, repository-relative."
  [dir out]
  (each entry (sort (os/dir dir))
    (def path (string dir "/" entry))
    (case (os/stat path :mode)
      :directory (unless (skip-dirs entry) (walk-into path out))
      :file (when (extractable? entry) (array/push out path)))))

(defn- collect
  "The files `paths` names, expanding a directory and dropping what is absent."
  [paths]
  (def out @[])
  (each p paths
    (case (os/stat p :mode)
      :directory (walk-into p out)
      :file (when (extractable? p) (array/push out p))))
  (def seen @{})
  (filter |(unless (seen $) (put seen $ true) true) out))

### Zig

(defn- marker-of
  "The comment marker on `line`, or nil. Longest marker first."
  [line]
  (def t (string/triml line))
  (cond
    (string/has-prefix? "//!" t) "//!"
    (string/has-prefix? "///" t) "///"
    (string/has-prefix? "//" t) "//"
    nil))

(defn- without-marker
  "`line` after its marker and one following space."
  [line marker]
  (def rest (string/slice (string/triml line) (length marker)))
  (if (string/has-prefix? " " rest) (string/slice rest 1) rest))

(defn- zig-blocks
  "Every comment block in `text`, as `{:line n :body s}` in source order."
  [text]
  (def lines (string/split "\n" text))
  (def out @[])
  (var i 0)
  (while (< i (length lines))
    (def marker (marker-of (lines i)))
    (if marker
      (do
        (def start i)
        (def body @[])
        (while (and (< i (length lines)) (= marker (marker-of (lines i))))
          (array/push body (without-marker (lines i) marker))
          (++ i))
        (array/push out {:line (inc start) :body (string/join body "\n")}))
      (++ i)))
  out)

### Markdown

(defn- fence? [line] (string/has-prefix? "```" (string/triml line)))

(defn- md-blocks
  "Every paragraph and heading in `text`, as `{:line n :body s}`.

  A heading closes any open paragraph and is emitted alone. A table row, a
  block quote and a fenced block close one and are skipped. Four leading
  spaces are indented code only where no paragraph is open, so a deeply
  indented list continuation stays with the item it belongs to."
  [text]
  (def lines (string/split "\n" text))
  (def out @[])
  (var open nil)
  (var start 0)
  (var in-fence false)
  (defn close []
    (when open
      (array/push out {:line start :body (string/join open "\n")})
      (set open nil)))
  (for i 0 (length lines)
    (def line (lines i))
    (cond
      (fence? line) (do (close) (set in-fence (not in-fence)))
      in-fence nil
      (empty? (string/trim line)) (close)
      (string/has-prefix? "|" line) (close)
      (string/has-prefix? ">" line) (close)
      (and (nil? open) (string/has-prefix? "    " line)) nil
      (string/has-prefix? "#" line)
      (do (close) (array/push out {:line (inc i) :body line}))
      (do
        (when (nil? open) (set open @[]) (set start (inc i)))
        (array/push open line))))
  (close)
  out)

### Writing

(defn- mkdirs
  "Create `path` and every directory above it."
  [path]
  (def parts (string/split "/" path))
  (var so-far nil)
  (each part parts
    (set so-far (if so-far (string so-far "/" part) part))
    (unless (empty? so-far) (os/mkdir so-far))))

(defn- render
  "The extract for one file: each block under a `-- path:line` line."
  [path blocks]
  (def out @"")
  (each b blocks
    (buffer/push out (string/format "-- %s:%d\n%s\n\n" path (b :line) (b :body))))
  (string out))

(defn main [& argv]
  (os/cd tools/root)
  (var out-dir default-out)
  (def paths @[])
  # `argv` opens with the script's own path, which is not an argument.
  (var i 1)
  (while (< i (length argv))
    (def a (argv i))
    (cond
      (= a "--out")
      (do
        (unless (< (inc i) (length argv)) (tools/die "--out needs a directory"))
        (set out-dir (argv (inc i)))
        (+= i 2))
      (string/has-prefix? "-" a)
      (tools/die "unrecognised argument: " a "\n"
                 "usage: ./tools/check/comments.janet [--out DIR] [PATH ...]")
      (do (array/push paths a) (++ i))))

  (def files (collect (if (empty? paths) (default-paths) paths)))
  (when (empty? files)
    (tools/die "no .zig or .md files in: " (string/join (if (empty? paths) (default-paths) paths) " ")))

  (def index @[])
  (var total 0)
  (each path files
    (def text (slurp path))
    (def blocks (if (string/has-suffix? ".zig" path) (zig-blocks text) (md-blocks text)))
    (def target (string out-dir "/" path ".txt"))
    (def parts (string/split "/" target))
    (mkdirs (string/join (slice parts 0 -2) "/"))
    (spit target (render path blocks))
    (array/push index {:count (length blocks) :path target})
    (+= total (length blocks)))

  (def idx @"")
  (each row index
    (buffer/push idx (string/format "%6d  %s\n" (row :count) (row :path))))
  (spit (string out-dir "/INDEX.txt") (string idx))

  (print (length files) " files, " total " blocks, written to " out-dir)
  (os/exit 0))
