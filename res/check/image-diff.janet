#!/usr/bin/env janet
# Read the core image `zig build image` emits, and compare two of them.
#
# Development instrument in `res/`.
#
#     ./res/check/image-diff.janet                 # build the image; report size and host paths
#     ./res/check/image-diff.janet --paths         # list the absolute host paths it embeds
#     ./res/check/image-diff.janet --save FILE     # build it and keep a copy at FILE
#     ./res/check/image-diff.janet --against FILE  # build it and compare with a saved copy
#
# This script was written for a comparison that no longer exists. It built
# `-Dboot=c` and `-Dboot=zig` and diffed the two images, and that option went
# with the last nfunction-bearing C arm in Phase 10 Part 17g -- so every
# invocation since had failed at the first build, and nothing said so, because
# nothing runs it but a person. Phase 11 Part 19 rewrote it around the two
# questions it can still answer.
#
# **The absolute host paths, which must stay at zero.** The image is not
# reproducible across checkouts if it carries any: a C compiler is handed
# absolute paths, `__FILE__` keeps them, and a core nfunction's source file goes
# into the image. There were twenty-two. A Zig-registered nfunction records a
# repo-relative path instead -- `src/runtime/io.zig` -- so the figure fell by one
# per C file that emptied, and reached zero with the last C source.
#
# **The bytes, against a saved copy.** That is what the reproducibility bullet in
# `phase_11.md` compares, and it is now the artefact rather than something to be
# recovered from C text around it: `--save` on one host, `--against` on the
# other. Part 19 also compared two images across a change to the *emitter* --
# the last C-emitting one and the first byte-emitting one -- and they agree on
# all 324,310 bytes, the C form having carried a 324,311st that was the array
# terminator.

(import ../common :as tools)

(def cache "/tmp/wattle-image-cache")
(def out-prefix "/tmp/wattle-image-out")

# An *absolute* path starts at a `/`. A repo-relative one that happens to
# contain a directory -- `src/runtime/value/tables.zig`, which is what a
# Zig-registered nfunction records -- must not match at its interior slash.
# Without the lookbehind every Zig path is counted as a host path, which
# inflates the figure by exactly the number of Zig-registered subsystems: it
# read nineteen once where eight was the published number and seven the true
# one.
#
# The lookbehind excludes letters and not digits deliberately. A marshalled
# string carries its length in the byte before its first character, and these
# paths are forty to sixty bytes long, so that byte *is* an ASCII digit. Only a
# letter can precede an interior slash in a path this is meant to reject.
#
# The Python original was one regex, `(?<![A-Za-z])/[A-Za-z0-9_./-]+\.(?:c|zig)`,
# and it leaned on something a PEG does not have: `+` is greedy *and* backtracks,
# so the match ends at the last `.c` or `.zig` in the run rather than failing
# when the run swallows one. A PEG's `some` is possessive and would never match
# at all. So the run is captured whole here and the ending is chosen afterwards,
# which is the same answer by construction rather than by resemblance.
(def- run-peg
  (peg/compile
    ~(any (choice
            (sequence (not (look -1 (range "AZ" "az")))
                      (capture (sequence "/" (some (choice (range "AZ" "az" "09")
                                                           (set "_./-"))))))
            1))))

(defn- source-path
  "The longest prefix of `run` that ends in `.c` or `.zig`, or nil."
  [run]
  (var best nil)
  (for i 1 (length run)
    (def rest (slice run i))
    (cond
      (string/has-prefix? ".zig" rest) (set best (+ i 4))
      (string/has-prefix? ".c" rest) (set best (+ i 2))))
  (if best (slice run 0 best)))

(defn absolute-paths [data]
  (def found @{})
  (each run (peg/match run-peg data)
    (when-let [path (source-path run)]
      (put found path true)))
  (sort (keys found)))

(defn- build
  "Emit the image into a throwaway prefix and return its bytes.

  `--cache-dir` and `-p` are both throwaway, which is `AGENTS.md`'s rule for
  a one-shot build: `.zig-cache` is never collected and this is not a cache
  anyone iterates in."
  []
  (tools/rm-rf out-prefix)
  (def r (tools/sh (string "zig build image --cache-dir " cache " -p " out-prefix)
                   :timeout 1800))
  (unless (tools/ok? r)
    (tools/die "image-diff.janet: `zig build image` failed\n"
               (if (r :timeout) "timed out" (string/slice (r :err) (max -800 (- (length (r :err))))))))
  (def path (string out-prefix "/wattle-image.bin"))
  (unless (os/stat path)
    (tools/die "image-diff.janet: no wattle-image.bin in " out-prefix))
  # `string`, not the buffer `slurp` hands back. Janet's `=` on two buffers is
  # identity rather than content, so a transliteration of Python's `read()`
  # reports every pair of identical images as different -- which is exactly the
  # question this tool exists to answer. The differential against the Python
  # original is what caught it.
  (string (slurp path)))

(defn- printable-strings [data &opt least]
  (default least 6)
  (def out @[])
  (def run @"")
  (each byte data
    (if (and (<= 32 byte) (< byte 127))
      (buffer/push-byte run byte)
      (do
        (when (>= (length run) least) (array/push out (string run)))
        (buffer/clear run))))
  (when (>= (length run) least) (array/push out (string run)))
  out)

(defn- report-paths [data listing]
  (def paths (absolute-paths data))
  (printf "%d bytes, %d embedded absolute host path%s"
          (length data) (length paths) (if (= 1 (length paths)) "" "s"))
  (when listing
    (each p paths (print "    " p)))
  paths)

(defn- compare-with
  "Diff the built image against a saved one, by strings rather than bytes.

  A byte diff of two marshalled streams says only that they differ. What is
  worth reading is which *strings* are in one and not the other, because a
  real divergence between two hosts or two emitters shows up as a path, a
  docstring or a binding name -- and anything that is not one of those wants
  explaining before it is accepted."
  [data path]
  (def saved (string (try (slurp path)
                     ([e] (tools/die "image-diff.janet: cannot read " path ": " e)))))

  (printf "saved   %7d bytes  %s" (length saved) path)
  (printf "built   %7d bytes" (length data))
  (if (= saved data)
    (do
      (print "\nThe two images are byte-identical.")
      0)
    (do
      (def saved-set @{})
      (each s (printable-strings saved) (put saved-set s true))
      (def built-set @{})
      (each s (printable-strings data) (put built-set s true))
      (def only-saved (sort (seq [s :keys saved-set :when (not (built-set s))] s)))
      (def only-built (sort (seq [s :keys built-set :when (not (saved-set s))] s)))
      (printf "\n%d string%s only in the saved image:"
              (length only-saved) (if (= 1 (length only-saved)) "" "s"))
      (each s only-saved (print "  - " s))
      (printf "%d string%s only in the built image:"
              (length only-built) (if (= 1 (length only-built)) "" "s"))
      (each s only-built (print "  + " s))
      (print "\nEverything above should be a source path. Anything else is a real "
             "divergence\nand wants explaining before the increment lands.")
      1)))

(defn- flag-value [argv name]
  (var found nil)
  (for i 0 (length argv)
    (when (and (= (argv i) name) (< (+ i 1) (length argv)))
      (set found (argv (+ i 1)))))
  found)

(defn main [& argv]
  (os/cd tools/root)
  (def listing (has-value? argv "--paths"))
  (def save-to (flag-value argv "--save"))
  (def against (flag-value argv "--against"))
  (def status
    (defer (do (tools/rm-rf cache) (tools/rm-rf out-prefix))
      (let [data (build)]
        (report-paths data listing)
        (when save-to
          (spit save-to data)
          (print "saved to " save-to))
        (if against (compare-with data against) 0))))
  (os/exit status))
