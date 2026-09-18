#!/usr/bin/env janet
# Rewrites Janet source as Wattle source, one lexical form at a time.
#
# Step 5 of `notes/LANGUAGE.md`'s order: the tree is written in Janet's syntax
# and has to be written in Wattle's before the parser swaps. Run it over a
# `.janet` file and it writes the `.wattle` file beside it and reports every
# site it changed in a way a reader should look at.
#
#     ./res/repo/janet-to-wattle.janet src/boot/boot.janet test/suite-*.janet
#
# `--dry-run` reports without writing. The exit status is non-zero when any
# finding is in the `hand/` class, which is a site the tool could not spell
# and left in Janet's syntax for a person to rewrite.
#
### Why it is a transducer and not a printer
#
# `notes/LANGUAGE.md` describes the converter as Janet's parser output turned
# back into source. A printer loses every comment, every blank line and every
# alignment decision in 16,000 lines that are then meant to be reviewed as
# source, so this scans bytes and substitutes, and the output diffs against
# the input line for line. Janet's parser is still what says whether the
# result is right, at step 6, when the converted tree loads.
#
### What it cannot see
#
# **Meaning.** Every substitution here is lexical. `[a b]` is copied through
# unchanged and stops being a tuple and starts being a vector, which is the
# whole point and is invisible in the diff. The same holds for `{a b}`, and
# for every macro in `boot.janet` that builds code as `['if ...]`.
#
# **Strings.** A Janet form written inside a string literal is data and is
# copied through as data. `test/suite-parse.janet` is most of one file of
# that, so its conversion is a rewrite by hand rather than a run of this.
#
# **Paths.** The `.janet` extension inside a string, in `module/paths` and in
# the suite names the harness spells, is meaning and not syntax. Step 6 has
# them.
#
### The one place a column moves
#
# A raw string's reindentation removes the opening delimiter's indentation
# from every line under it, and the delimiter's own length is not part of
# that -- so a Janet long string opened by one backtick and a Wattle one
# opened by three quotes reindent alike, as long as nothing earlier on the
# line changed length. Only another long string does, and `longstring-column`
# reports one.

### Character classes
#
# Both parsers share `scan.zig`'s symbol table, so a Janet token is a Wattle
# token, and none of the characters this substitutes is a symbol character.
# `@` and `^` are the exceptions: each is an ordinary symbol character in
# both, and each opens nothing in Janet and is refused at the head of a form
# in Wattle.

(def symbol-chars
  (let [t @{}]
    (loop [b :range [0 256]]
      (put t b (or (and (>= b (chr "A")) (<= b (chr "Z")))
                   (and (>= b (chr "a")) (<= b (chr "z")))
                   (and (>= b (chr "0")) (<= b (chr "9")))
                   (>= b 128)
                   (not (nil? (index-of b (string/bytes "!$%&*+-./:<=>?@^_")))))))
    t))

(def whitespace-chars
  (let [t @{}]
    (each b [(chr " ") (chr "\t") (chr "\n") (chr "\r") 0 11 12] (put t b true))
    t))

# Janet's five reader macros. The value each maps to is Wattle's spelling of
# the same form, except `|`, which `emit` decides: Wattle's `#` takes a paren
# form only.
(def prefix-spelling
  {(chr "'") "'"
   (chr ",") "~"
   (chr ";") "|"
   (chr "~") "`"
   (chr "|") "#"})

### Scanning
#
# One pass over the bytes producing `{:kind k :start a :end b}` with `:end`
# exclusive, so the tokens tile the source and the output is their images
# concatenated. `:at-string` and `:at-long` are the `@` of `@"` and of an `@`
# long string alone: the string itself is the token after, which keeps one
# piece of code deciding how a string is spelled.

(defn- run-of
  "How many bytes from `i` in `src` are `b`."
  [src i b]
  (def n (length src))
  (var k i)
  (while (and (< k n) (= (src k) b)) (++ k))
  (- k i))

(defn scan
  "The tokens of Janet source `src`, in order and covering every byte."
  [src]
  (def n (length src))
  (def out @[])
  (var i 0)
  (while (< i n)
    (def b (src i))
    (cond
      (whitespace-chars b)
      (do (var j i)
          (while (and (< j n) (whitespace-chars (src j))) (++ j))
          (array/push out {:kind :ws :start i :end j})
          (set i j))

      (= b (chr "#"))
      (do (var j i)
          (while (and (< j n) (not= (src j) (chr "\n"))) (++ j))
          (array/push out {:kind :comment :start i :end j})
          (set i j))

      # A long string is closed by a run of backticks at least as long as the
      # one that opened it; a shorter run is text. `longstringImpl` finishes
      # at the opening length and hands anything past it back.
      (= b (chr "`"))
      (do (def ticks (run-of src i (chr "`")))
          (var j (+ i ticks))
          (var closed nil)
          (while (and (< j n) (nil? closed))
            (if (= (src j) (chr "`"))
              (let [r (run-of src j (chr "`"))]
                (if (>= r ticks) (set closed j) (+= j r)))
              (++ j)))
          (if closed
            (do (array/push out {:kind :longstring :start i :end (+ closed ticks)
                                 :ticks ticks :content [(+ i ticks) closed]})
                (set i (+ closed ticks)))
            (do (array/push out {:kind :bad :start i :end n :why "unterminated long string"})
                (set i n))))

      (= b (chr "\""))
      (do (var j (+ i 1))
          (var closed nil)
          (while (and (< j n) (nil? closed))
            (cond
              (= (src j) (chr "\\")) (+= j 2)
              (= (src j) (chr "\"")) (set closed j)
              (++ j)))
          (if closed
            (do (array/push out {:kind :string :start i :end (+ closed 1)
                                 :content [(+ i 1) closed]})
                (set i (+ closed 1)))
            (do (array/push out {:kind :bad :start i :end n :why "unterminated string"})
                (set i n))))

      (= b (chr "@"))
      (let [c (if (< (+ i 1) n) (src (+ i 1)) -1)]
        (cond
          (index-of c (string/bytes "([{"))
          (do (array/push out {:kind :open :start i :end (+ i 2)
                               :delim (string/from-bytes c) :mutable true})
              (set i (+ i 2)))
          (= c (chr "\""))
          (do (array/push out {:kind :at-string :start i :end (+ i 1)})
              (set i (+ i 1)))
          (= c (chr "`"))
          (do (array/push out {:kind :at-long :start i :end (+ i 1)})
              (set i (+ i 1)))
          (do (var j i)
              (while (and (< j n) (symbol-chars (src j))) (++ j))
              (array/push out {:kind :token :start i :end j})
              (set i j))))

      (prefix-spelling b)
      (do (array/push out {:kind :prefix :start i :end (+ i 1) :char b})
          (set i (+ i 1)))

      (index-of b (string/bytes "([{"))
      (do (array/push out {:kind :open :start i :end (+ i 1)
                           :delim (string/from-bytes b) :mutable false})
          (set i (+ i 1)))

      (index-of b (string/bytes ")]}"))
      (do (array/push out {:kind :close :start i :end (+ i 1)})
          (set i (+ i 1)))

      (symbol-chars b)
      (do (var j i)
          (while (and (< j n) (symbol-chars (src j))) (++ j))
          (array/push out {:kind :token :start i :end j})
          (set i j))

      (do (array/push out {:kind :bad :start i :end (+ i 1) :why "unexpected character"})
          (set i (+ i 1)))))
  out)

(defn form-end
  "The index just past the form `toks` begins at or after `i`, or nil.

  A form is a run of reader macros ending in an atom or a balanced group,
  which is what `|` has to bracket when Wattle's `#` cannot spell it."
  [toks i]
  (def n (length toks))
  (var j i)
  (while (and (< j n) (index-of ((toks j) :kind) [:ws :comment])) (++ j))
  (if (>= j n)
    nil
    (let [kind ((toks j) :kind)]
      (cond
        (index-of kind [:prefix :at-string :at-long]) (form-end toks (+ j 1))
        (= kind :open)
        (do (var depth 0)
            (var k j)
            (var stop nil)
            (while (and (< k n) (nil? stop))
              (case ((toks k) :kind)
                :open (++ depth)
                :close (do (-- depth) (when (= 0 depth) (set stop (+ k 1)))))
              (++ k))
            stop)
        (index-of kind [:token :string :longstring]) (+ j 1)
        nil))))

### Spelling a string
#
# Janet has two string forms and Wattle has one, classified by the length of
# its opening run. A backtick run becomes a quote run long enough that no run
# inside the content closes it; a content that begins or ends with a quote has
# no raw spelling at all, since the run would join the delimiter, and becomes
# an ordinary escaped string instead.

(defn- longest-quote-run
  "The longest run of `\"` in `body`."
  [body]
  (var best 0)
  (var current 0)
  (loop [k :range [0 (length body)]]
    (if (= (body k) (chr "\""))
      (do (++ current) (when (> current best) (set best current)))
      (set current 0)))
  best)

(defn- escaped
  "`body` with the two characters an ordinary string reads as syntax escaped."
  [body]
  (string/replace-all "\"" "\\\"" (string/replace-all "\\" "\\\\" body)))

(defn- unlined
  "`body` without the newline bytes Janet's ordinary string drops."
  [body]
  (string/replace-all "\r" "" (string/replace-all "\n" "" body)))

### Positions

(defn- line-of
  "The 1-based line `i` is on in `src`."
  [src i]
  (var line 1)
  (loop [k :range [0 i]] (when (= (src k) (chr "\n")) (++ line)))
  line)

(defn- column-of
  "The 1-based column `i` is at in `src`."
  [src i]
  (var j i)
  (while (and (> j 0) (not= (src (- j 1)) (chr "\n"))) (-- j))
  (+ 1 (- i j)))

### Converting

(defn convert
  "Wattle source for the Janet source `src`, and what a reader should see.

  Returns `[text findings]`. A finding is `{:class c :line l :column c :text
  t}`; a `hand/` class is a site left in Janet's syntax because Wattle has no
  spelling for it."
  [src]
  (def toks (scan src))
  (def n (length toks))
  (def out @"")
  (def findings @[])
  # A `)` owed after the token at this index, for each `|` that had to be
  # written as a call. `||4` owes two.
  (def closers @{})

  (defn note [class i text]
    (array/push findings @{:class class :line (line-of src i)
                           :column (column-of src i) :text text}))

  (defn text-of [t] (string/slice src (t :start) (t :end)))

  # A long string is the only form whose image is a different length from its
  # source, so it is the only thing that can move a later long string's
  # opening column and change how it reindents. `@` becomes `!` and `,`
  # becomes `~`; every other substitution is one byte for one byte.
  (defn length-changer-before? [x]
    (var y (- x 1))
    (var found false)
    (var stop false)
    (while (and (>= y 0) (not stop))
      (def u (toks y))
      (when (= (u :kind) :longstring) (set found true))
      (when (and (= (u :kind) :ws)
                 (string/find "\n" (string/slice src (u :start) (u :end))))
        (set stop true))
      (-- y))
    found)

  (defn emit-longstring [x t]
    (def [a b] (t :content))
    (def body (string/slice src a b))
    (def multiline (not (nil? (string/find "\n" body))))
    (def starts-quote (and (> b a) (= (src a) (chr "\""))))
    (def ends-quote (and (> b a) (= (src (- b 1)) (chr "\""))))
    (cond
      # An empty raw string cannot be written: the closing run would join the
      # opening one. Two quotes are the empty string.
      (= a b) (buffer/push out "\"\"")

      (or starts-quote ends-quote)
      (if multiline
        (do (note "hand/longstring-unspellable" (t :start)
                  "raw string begins or ends with a quote and spans lines")
            (buffer/push out (text-of t)))
        (do (note "changed/longstring-escaped" (t :start)
                  (string "raw string became an escaped string: " (describe body)))
            (buffer/push out "\"" (escaped body) "\"")))

      (do
        (def m (max 3 (+ 1 (longest-quote-run body))))
        (def delimiter (string/repeat "\"" m))
        (when (and multiline (length-changer-before? x))
          (note "hand/longstring-column" (t :start)
                "a length-changing form precedes it on its line, so it reindents differently"))
        (buffer/push out delimiter body delimiter))))

  (loop [x :range [0 n]]
    (def t (toks x))
    (def kind (t :kind))
    (case kind
      :ws (buffer/push out (text-of t))

      # `#!` at byte zero is the shebang, which Wattle reads as a comment
      # where it reads `#` as dispatch everywhere else. A banner written as a
      # run of `#` becomes a run of `;` of the same length: everything after
      # the first character is text, and the run is what makes it a banner.
      :comment
      (if (and (= 0 (t :start)) (string/has-prefix? "#!" (text-of t)))
        (buffer/push out (text-of t))
        (let [hashes (run-of src (t :start) (chr "#"))]
          (buffer/push out (string/repeat ";" hashes)
                       (string/slice src (+ hashes (t :start)) (t :end)))))

      :token
      (do (def text (text-of t))
          (when (= (chr "@") (src (t :start)))
            (note "hand/at-symbol" (t :start)
                  (string "a symbol beginning with @ is refused: " text)))
          (when (= (chr "^") (src (t :start)))
            (note "hand/caret-symbol" (t :start)
                  (string "a symbol beginning with ^ is refused: " text)))
          (buffer/push out text))

      :string
      (let [[a b] (t :content)
            body (string/slice src a b)]
        (if (or (string/find "\n" body) (string/find "\r" body))
          (do (note "changed/string-joined" (t :start)
                    "a string spanning lines became one line, which is the value Janet gave it")
              (buffer/push out "\"" (unlined body) "\""))
          (buffer/push out (text-of t))))

      :longstring (emit-longstring x t)

      :at-string (buffer/push out "!")
      :at-long (buffer/push out "!")

      :open (buffer/push out (if (t :mutable) "!" "") (t :delim))
      :close (buffer/push out (text-of t))

      :prefix
      (if (not= (t :char) (chr "|"))
        (buffer/push out (prefix-spelling (t :char)))
        # Wattle's `#` opens a short function on a paren form and on nothing
        # else, and it takes no whitespace before that paren. Anything else
        # `|` was written on is spelled as the call the reader would have
        # built.
        (let [next (if (< (+ x 1) n) (toks (+ x 1)) nil)]
          (if (and next (= (next :kind) :open) (= (next :delim) "(")
                   (not (next :mutable)))
            (buffer/push out "#")
            (let [stop (form-end toks (+ x 1))]
              (if (nil? stop)
                (do (note "hand/short-fn" (t :start) "| with no form after it")
                    (buffer/push out (text-of t)))
                (do (note "changed/short-fn" (t :start)
                          "| on a form Wattle's # cannot open became (short-fn ...)")
                    (put closers (- stop 1) (+ 1 (get closers (- stop 1) 0)))
                    (buffer/push out "(short-fn ")))))))

      :bad
      (do (note "hand/scan" (t :start) (t :why))
          (buffer/push out (text-of t))))

    (loop [_ :range [0 (get closers x 0)]] (buffer/push out ")")))

  [(string out) findings])

### The command

(defn- convert-file
  "Converts `path` to the `.wattle` file beside it. Returns its findings."
  [path dry-run]
  (def src (slurp path))
  (def [text findings] (convert src))
  (def target (string (string/slice path 0 (- (length path) (length ".janet")))
                      ".wattle"))
  (unless dry-run (spit target text))
  (each f findings (put f :file path))
  findings)

(defn main [& argv]
  (def args (slice argv 1))
  (def dry-run (not (nil? (index-of "--dry-run" args))))
  (def paths (filter |(not (string/has-prefix? "--" $)) args))
  (when (empty? paths)
    (eprint "usage: janet-to-wattle.janet [--dry-run] FILE.janet ...")
    (os/exit 2))
  (def all @[])
  (each path paths
    (unless (string/has-suffix? ".janet" path)
      (eprintf "%s: not a .janet file" path)
      (os/exit 2))
    (array/concat all (convert-file path dry-run)))

  (def by-class @{})
  (each f all
    (put by-class (f :class) (array/push (get by-class (f :class) @[]) f)))
  (each class (sorted (keys by-class))
    (def rows (by-class class))
    (printf "\n%s (%d)" class (length rows))
    (each f rows
      (printf "  %s:%d:%d  %s" (f :file) (f :line) (f :column) (f :text))))
  (printf "\n%d file(s), %d finding(s)" (length paths) (length all))
  (when (some |(string/has-prefix? "hand/" ($ :class)) all)
    (eprint "\nsites left in Janet's syntax; each is a rewrite by hand")
    (os/exit 1)))
