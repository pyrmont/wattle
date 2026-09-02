# Copyright (c) 2026 Calvin Rose
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to
# deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.

(import ./helper :prefix "" :exit true)
(start-suite)

# 7e46ead2f
(assert (not false) "false literal")
(assert true "true literal")
(assert (not nil) "nil literal")

(assert (= '(1 2 3) (quote (1 2 3)) (tuple 1 2 3)) "quote shorthand")

# String literals
# 45f8db0
(assert (= "abcd" "\x61\x62\x63\x64") "hex escapes")
(assert (= "\e" "\x1B") "escape character")
(assert (= "\x09" "\t") "tab character")

# Long strings
# 7e6342720
(assert (= "hello, world" `hello, world`) "simple long string")
(assert (= "hello, \"world\"" `hello, "world"`)
        "long string with embedded quotes")
(assert (= "hello, \\\\\\ \"world\"" `hello, \\\ "world"`)
        "long string with embedded quotes and backslashes")

# The reindent helper below uses peg/replace-all, which is absent from a
# build without JANET_PEG, and an absent binding is a compile error rather
# than a runtime one.
(compwhen (dyn 'peg/replace-all)
  #
  # Longstring indentation
  #
  # 7aa4241
  (defn reindent
    "Reindent the contents of a longstring as the Janet parser would.
    This include removing leading and trailing newlines."
    [text indent]

    # Detect minimum indent
    (var rewrite true)
    (each index (string/find-all "\n" text)
      (for i (+ index 1) (+ index indent 1)
        (case (get text i)
          nil (break)
          (chr "\r") (if-not (= (chr "\n") (get text (inc i)))
                       (set rewrite false))
          (chr "\n") (break)
          (chr " ") nil
          (set rewrite false))))

    # Only re-indent if no dedented characters.
    (def str
      (if rewrite
        (peg/replace-all ~(* '(* (? "\r") "\n") (between 0 ,indent " "))
                        (fn [_mtch eol] eol) text)
        text))

    (def first-eol (cond
                     (string/has-prefix? "\r\n" str) :crlf
                     (string/has-prefix? "\n" str) :lf))
    (def last-eol (cond
                    (string/has-suffix? "\r\n" str) :crlf
                    (string/has-suffix? "\n" str) :lf))
    (string/slice str (case first-eol :crlf 2 :lf 1 0) (case last-eol :crlf -3 :lf -2)))

  (defn reindent-reference
    "Same as reindent but use parser functionality. Useful for
    validating conformance."
    [text indent]
    (if (empty? text) (break text))
    (def source-code
      (string (string/repeat " " indent) "``````"
              text
              "``````"))
    (parse source-code))

  (var indent-counter 0)
  (defn check-indent
    [text indent]
    (++ indent-counter)
    (let [a (reindent text indent)
          b (reindent-reference text indent)]
      (assert (= a b)
              (string/format "reindent: %q, parse: %q (indent-test #%d with indent of %d)" a b indent-counter indent)
              )))

  # Unix EOLs
  (check-indent "" 0)
  (check-indent "\n" 0)
  (check-indent "\n" 1)
  (check-indent "\n\n" 0)
  (check-indent "\n\n" 1)
  (check-indent "\nHello, world!" 0)
  (check-indent "\nHello, world!" 1)
  (check-indent "Hello, world!" 0)
  (check-indent "Hello, world!" 1)
  (check-indent "\n    Hello, world!" 4)
  (check-indent "\n    Hello, world!\n" 4)
  (check-indent "\n    Hello, world!\n   " 4)
  (check-indent "\n    Hello, world!\n    " 4)
  (check-indent "\n    Hello, world!\n   dedented text\n    " 4)
  (check-indent "\n    Hello, world!\n    indented text\n    " 4)
  # Windows EOLs
  (check-indent "\r\n" 0)
  (check-indent "\r\n" 1)
  (check-indent "\r\n\r\n" 0)
  (check-indent "\r\n\r\n" 1)
  (check-indent "\r\nHello, world!" 0)
  (check-indent "\r\nHello, world!" 1)
  (check-indent "\r\n    Hello, world!\r\n   " 4)
  (check-indent "\r\n    Hello, world!\r\n    " 4)
  (check-indent "\r\n    Hello, world!\r\n   dedented text\r\n    " 4)
  (check-indent "\r\n    Hello, world!\r\n    indented text\r\n    " 4))

# Symbols with @ character
# d68eae9
(def @ 1)
(assert (= @ 1) "@ symbol")
(def @-- 2)
(assert (= @-- 2) "@-- symbol")
(def @hey 3)
(assert (= @hey 3) "@hey symbol")

# Parser clone
# 43520ac67
(def p0 (parser/new))
(assert (= 7 (parser/consume p0 "(1 2 3 ")) "parser 1")
(def p2 (parser/clone p0))
(parser/consume p2 ") 1 ")
(parser/consume p0 ") 1 ")
(assert (deep= (parser/status p0) (parser/status p2)) "parser 2")
(assert (deep= (parser/state p0) (parser/state p2)) "parser 3")

# Parser errors
# 976dfc719
(defn parse-error [input]
  (def p (parser/new))
  (parser/consume p input)
  (parser/error p))

# Invalid utf-8 sequences
(assert (not= nil (parse-error @"\xc3\x28")) "reject invalid utf-8 symbol")
(assert (not= nil (parse-error @":\xc3\x28")) "reject invalid utf-8 keyword")

# Parser line and column numbers
# 77b79e989
(defn parser-location [input &opt location]
  (def p (parser/new))
  (parser/consume p input)
  (if location
    (parser/where p ;location)
    (parser/where p)))

(assert (= [1 7] (parser-location @"(+ 1 2)")) "parser location 1")
(assert (= [5 7] (parser-location @"(+ 1 2)" [5])) "parser location 2")
(assert (= [10 10] (parser-location @"(+ 1 2)" [10 10])) "parser location 3")

# Issue #861 - should be valgrind clean
# 39c6be7cb
(def step1 "(a b c d)\n")
(def step2 "(a b)\n")
(def p1 (parser/new))
(parser/state p1)
(parser/consume p1 step1)
(loop [_ :iterate (parser/produce p1)])
(parser/state p1)
(def p3 (parser/clone p1))
(parser/state p3)
(parser/consume p3 step2)
(loop [_ :iterate (parser/produce p3)])
(parser/state p3)

# parser delimiter errors
(defn test-error [delim fmt]
  (def p (parser/new))
  (parser/consume p delim)
  (parser/eof p)
  (def msg (string/format fmt delim))
  (assert (= (parser/error p) msg) "delimiter error"))
(each c [ "(" "{" "[" "\"" "``" ]
  (test-error c "unexpected end of source, %s opened at line 1, column 1"))

# parser/insert
(def p (parser/new))
(parser/consume p "(")
(parser/insert p "hello")
(parser/consume p ")")
(assert (= (parser/produce p) ["hello"]))

(def p4 (parser/new))
(parser/consume p4 `("hel`)
(parser/insert p4 `lo`)
(parser/consume p4 `")`)
(assert (= (parser/produce p4) ["hello"]))

# Hex floats
(assert (= math/pi +0x1.921fb54442d18p+0001))
(assert (= math/int-max +0x1.ffff_ffff_ffff_ffp+0052))
(assert (= math/int-min -0x1.ffff_ffff_ffff_ffp+0052))
(assert (= 1 0x1P0))
(assert (= 2 0x1P1))
(assert (= -2 -0x1p1))
(assert (= -0.5 -0x1p-1))

# `parser/state` is called for its side effects above and never for its content;
# what follows asks about the content.

# :delimiters, one byte per open form, outermost first. The characters are
# built on the parser's own buffer and the count put back, so a second call
# has to give the same answer.
(def pd (parser/new))
(parser/consume pd `(1 [2 {3 "ab`)
(assert (= `([{"` (parser/state pd :delimiters)) "delimiters")
(assert (= `([{"` (parser/state pd :delimiters)) "delimiters again")
(def pl (parser/new))
(parser/consume pl "```abc")
(assert (= "```" (parser/state pl :delimiters)) "long-string delimiters count backticks")

# :frames, innermost last, with the arguments each container has collected.
(def pf (parser/new))
(parser/consume pf `(1 2 [3`)
(def frames (parser/state pf :frames))
(assert (deep= @[:root :tuple :tuple :token] (map |(get $ :type) frames)) "frame types")
(assert (deep= @[1 2] (get (get frames 1) :args)) "frame arguments")
(assert (= 1 (get (last frames) :line)) "frame line")

# The buffer-carrying frame types report what they have read so far.
(def ps (parser/new))
(parser/consume ps `"partial`)
(assert (= "partial" (get (last (parser/state ps :frames)) :buffer)) "string frame buffer")
(def pt (parser/new))
(parser/consume pt "sym")
(assert (= :token (get (last (parser/state pt :frames)) :type)) "token frame")
(def pc (parser/new))
(parser/consume pc "# note")
(assert (= :comment (get (last (parser/state pc :frames)) :type)) "comment frame")

# Reader macros name themselves.
(defn reader-frame-type [text]
  (def rp (parser/new))
  (parser/consume rp text)
  (get (last (parser/state rp :frames)) :type))
(assert (= :quote (reader-frame-type "'")) "quote frame")
(assert (= :unquote (reader-frame-type ",")) "unquote frame")
(assert (= :splice (reader-frame-type ";")) "splice frame")
(assert (= :quasiquote (reader-frame-type "~")) "quasiquote frame")
(assert (= :at (reader-frame-type "@")) "at frame")

# A keyless call gives both, and an unknown key is an error.
(assert (deep= @[:delimiters :frames] (sorted (keys (parser/state pd)))) "state keys")
(assert-error "unexpected keyword :nope" (parser/state pd :nope))

# parser/status over all four states.
(assert (= :root (parser/status (parser/new))) "status root")
(def pp1 (parser/new))
(parser/consume pp1 "(")
(assert (= :pending (parser/status pp1)) "status pending")
(def pp2 (parser/new))
(parser/consume pp2 ")")
(assert (= :error (parser/status pp2)) "status error")
(def pp3 (parser/new))
(parser/eof pp3)
(assert (= :dead (parser/status pp3)) "status dead")

# A dead or unread-error parser refuses more input.
(assert-error "parser is dead, cannot consume" (parser/consume pp3 "x"))
(assert-error "parser is dead, cannot consume" (parser/eof pp3))
(assert-error "parser is dead, cannot consume" (parser/consume pp2 "x"))

# parser/where sets as well as reads, and rejects out-of-range values.
(def pw (parser/new))
(assert (= [10 3] (parser/where pw 10 3)) "where sets line and column")
(assert (= [10 3] (parser/where pw)) "where reads back")
(assert-error "invalid line number 0" (parser/where (parser/new) 0))
(assert-error "invalid column number -1" (parser/where (parser/new) 1 -1))

# parser/consume's optional start index, and its return value.
(def po (parser/new))
(assert (= 3 (parser/consume po "xxx(1)" 3)) "consume from an offset")
(assert (= [1] (parser/produce po)) "and parses from there")
(assert-error "invalid offset 9 out of range [0,3]" (parser/consume (parser/new) "abc" 9))
(assert-error "invalid offset -1 out of range [0,3]" (parser/consume (parser/new) "abc" -1))
# A parse error stops the loop, and the count includes the byte that stopped it.
(def pe (parser/new))
(assert (= 1 (parser/consume pe ")abc")) "consume stops at an error")

# parser/byte takes the low eight bits.
(def pb (parser/new))
(each b [40 49 41] (parser/byte pb b))
(assert (= [1] (parser/produce pb)) "byte stream")

# parser/produce with a wrapper, for source mapping.
(def pv (parser/new))
(parser/consume pv "  hello")
(parser/eof pv)
(assert (= 'hello (first (parser/produce pv true))) "wrapped produce")

# parser/flush drops the queue.
(def pq (parser/new))
(parser/consume pq "(1 2)")
(parser/flush pq)
(assert (not (parser/has-more pq)) "flush empties the queue")

# parser/error interns whatever message the parser is holding, and takes it:
# a second call has nothing to answer with. Both kinds of message go the same
# way -- a literal one, and one the parser built from a format.
(def pm (parser/new))
(parser/consume pm ")")
(assert (= "unexpected closing delimiter )" (parser/error pm)) "a literal message")
(assert (nil? (parser/error pm)) "the message is taken, not copied")
(def pg (parser/new))
(parser/consume pg "(")
(parser/eof pg)
(assert (= "unexpected end of source, ( opened at line 1, column 1" (parser/error pg))
        "a generated message")
(assert (nil? (parser/error pg)) "a generated message is taken too")
(assert (nil? (parser/error (parser/new))) "no error is nil")

# parser/insert into a string frame, into a token frame, and at the top level.
(def pi1 (parser/new))
(parser/insert pi1 :top)
(assert (= :top (parser/produce pi1)) "insert at the root")
(def pi2 (parser/new))
(parser/consume pi2 "tok")
(parser/insert pi2 :after)
(assert (= 'tok (parser/produce pi2)) "insert terminates a token")
(assert (= :after (parser/produce pi2)) "and queues the inserted value")
(def pi3 (parser/new))
(parser/consume pi3 "@")
(assert-error "cannot insert value into parser" (parser/insert pi3 1))

# The methods on the abstract type reach the same functions.
(def pmeth (parser/new))
(:consume pmeth "(9)")
(assert (:has-more pmeth) "method has-more")
(assert (= [9] (:produce pmeth)) "method produce")
(assert (= :root (:status pmeth)) "method status")
(assert (= "core/parser" (string (type pmeth))) "abstract type name")

# A clone carries the state forward independently of the original.
(def pc1 (parser/new))
(parser/consume pc1 "(1 2")
(def pc2 (parser/clone pc1))
(parser/consume pc2 " 3)")
(parser/consume pc1 ")")
(assert (= [1 2 3] (parser/produce pc2)) "clone continues independently")
(assert (= [1 2] (parser/produce pc1)) "original is unaffected")

# The two delimiter mismatch messages.
(def pmm (parser/new))
(parser/consume pmm "(]")
(assert (= "mismatched delimiter ], ( opened at line 1, column 1" (parser/error pmm))
        "mismatched delimiter")
(def pud (parser/new))
(parser/consume pud ")")
(assert (= "unexpected closing delimiter )" (parser/error pud))
        "unexpected closing delimiter")
(def pod (parser/new))
(parser/consume pod "{1}")
(assert (= "struct and table literals expect even number of arguments" (parser/error pod))
        "odd struct literal")

# A parse error that is *not* a delimiter error leaves the parser alive but
# holding an unread message, and the two states report differently. This is the
# only way to reach the second of the two checks that guard input.
(def pun (parser/new))
(parser/consume pun "\x01")
(assert (= :error (parser/status pun)) "an unexpected character is an error")
(assert-error "parser has unchecked error, cannot consume" (parser/consume pun "x"))
(assert-error "parser has unchecked error, cannot consume" (parser/eof pun))
# Reading the error clears it, and the parser accepts input again.
(assert (= "unexpected character" (parser/error pun)) "the literal message")
(parser/consume pun "1")
(parser/eof pun)
(assert (= 1 (parser/produce pun)) "and parsing continues")

# :delimiters builds its answer on the parser's own buffer and has to put the
# count back, which is only visible through a frame that reports a buffer.
(def pbuf (parser/new))
(parser/consume pbuf "(\"abc")
(assert (= `("` (parser/state pbuf :delimiters)) "delimiters with a string open")
(assert (deep= @[[:root nil] [:tuple nil] [:string "abc"]]
               (map |[(get $ :type) (get $ :buffer)] (parser/state pbuf :frames)))
        "the delimiters scan leaves the buffer as it found it")

# Each container frame owns its own arguments, which the frame walk has to
# apportion from one shared array.
(def pargs (parser/new))
(parser/consume pargs "(1 (2 3 (4")
(assert (deep= @[@[] @[1] @[2 3] @[] nil]
               (map |(get $ :args) (parser/state pargs :frames)))
        "arguments belong to the frame that collected them")

# A buffer literal's frame says buffer, not string.
(def pbl (parser/new))
(parser/consume pbl "@\"ab")
(assert (= :buffer (get (last (parser/state pbl :frames)) :type)) "buffer frame")

# parser/insert terminates a token with a space and un-counts it, so the column
# still points at the value that was inserted.
(def pins (parser/new))
(parser/consume pins "(tok")
(assert (deep= [1 4] (parser/where pins)) "column before the insert")
(parser/insert pins :v)
(assert (deep= [1 4] (parser/where pins)) "the terminating space is not counted")

# Every method on the abstract type resolves, and the table's order is the
# order `next` reports -- lookup scans linearly, but iteration does not sort.
(def pall (parser/new))
(each m [:byte :clone :consume :eof :error :flush :has-more :insert :produce
         :state :status :where]
  (assert (= :cfunction (type (pall m))) (string "method " m)))
(assert-error "key :not-a-method not found in" (pall :not-a-method))
(assert (deep= @[:byte :clone :consume :eof :error :flush :has-more :insert
                 :produce :state :status :where]
               (keys pall))
        "methods are iterated in the order the table is written")

# A generated message is a Janet string the parser holds a reference to, so it
# survives a collection; a literal one is not traced because it is not one.
(def pgc (parser/new))
(parser/consume pgc "(]")
(gccollect)
(assert (= "mismatched delimiter ], ( opened at line 1, column 1" (parser/error pgc))
        "a generated message survives a collection")

(end-suite)

