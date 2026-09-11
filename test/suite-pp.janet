# Copyright (c) 2026 Calvin Rose & contributors
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

# Appending buffer to self
# 6b76ac3d1
(with-dyns [:out @""]
  (prin "abcd")
  (prin (dyn :out))
  (prin (dyn :out))
  (assert (deep= (dyn :out) @"abcdabcdabcdabcd") "print buffer to self"))

# Buffer self blitting, check for use after free
# bbcfaf128
(def buf1 @"1234567890")
(buffer/blit buf1 buf1 -1)
(buffer/blit buf1 buf1 -1)
(buffer/blit buf1 buf1 -1)
(buffer/blit buf1 buf1 -1)
(assert (= (string buf1) (string/repeat "1234567890" 16))
        "buffer blit against self")

# Check for bugs with printing self with buffer/format
# bbcfaf128
(def buftemp @"abcd")
(assert (= (string (buffer/format buftemp "---%p---" buftemp))
           `abcd---@"abcd"---`) "buffer/format on self 1")
(def buftemp2 @"abcd")
(assert (= (string (buffer/format buftemp2 "---%p %p---" buftemp2 buftemp2))
           `abcd---@"abcd" @"abcd"---`) "buffer/format on self 2")

# 5c364e0
(defn check-jdn [x]
  (assert (deep= (parse (string/format "%j" x)) x) "round trip jdn"))

(check-jdn 0)
(check-jdn nil)
(check-jdn [])
(check-jdn @[[] [] 1231 9.123123 -123123 0.1231231230001])
(check-jdn -0.123123123123)
(check-jdn 12837192371923)
(check-jdn "a string")
(check-jdn @"a buffer")

# Issue 1737
(assert (deep= "@[]" (string/format "%M" @[])))
(assert (deep= " @[]" (string/format " %M" @[])))
(assert (deep= "  @[]" (string/format "  %M" @[])))
(assert (deep= "   @[]" (string/format "   %M" @[])))
(assert (deep= "    @[]" (string/format "    %M" @[])))
(assert (deep= "     @[]" (string/format "     %M" @[])))
(assert (deep= "@[1]" (string/format "%m" @[1])))
(assert (deep= " @[2]" (string/format " %m" @[2])))
(assert (deep= "  @[3]" (string/format "  %m" @[3])))
(assert (deep= "   @[4]" (string/format "   %m" @[4])))
(assert (deep= "    @[5]" (string/format "    %m" @[5])))
(assert (deep= "     @[6]" (string/format "     %m" @[6])))

# Test multiline pretty specifiers
(let [tup [:keyword "string" @"buffer"]
      tab @{true (table/setproto @{:bar tup
                                   :baz 42}
                                 @{:_name "Foo"})}]
  (set (tab tup) tab)
  (assert (= (string/format "%67m" {tup @[tup tab] 'symbol tup})
          `
{symbol (:keyword "string" @"buffer")
 (:keyword
  "string"
  @"buffer") @[(:keyword "string" @"buffer")
               @{true @Foo{:bar (:keyword "string" @"buffer")
                           :baz 42}
                 (:keyword "string" @"buffer") <cycle 2>}]}`))
  (assert (= (string/format "%67p" {(freeze (zipcoll (range 42)
                                                     (range -42 0))) tab})
             `
{{0 -42
  1 -41
  2 -40
  3 -39
  4 -38
  5 -37
  6 -36
  7 -35
  8 -34
  9 -33
  10 -32
  11 -31
  12 -30
  13 -29
  14 -28
  15 -27
  16 -26
  17 -25
  18 -24
  19 -23
  20 -22
  21 -21
  22 -20
  23 -19
  24 -18
  25 -17
  26 -16
  27 -15
  28 -14
  29 -13
  ...} @{true @Foo{:bar (:keyword "string" @"buffer") :baz 42}
         (:keyword "string" @"buffer") <cycle 1>}}`)))

# Issue 1737
# The (??) debug pattern is a peg feature, absent without JANET_PEG.
(compwhen (dyn 'peg/match)
  (def capture-buf @"")
  (with-dyns [*err* capture-buf]
    (peg/match ~(* (constant @[]) (??)) "a"))
  (assert (deep= ```
                 ?? at [a] (index 0)
                 stack [1]:
                   [0]: @[]

                 ```
                 (string capture-buf))))

(assert (=
         (string/format "?? at [bc] (index 2)\nstack [5]:\n  [0]: %m\n  [1]: %m\n  [2]: %m\n  [3]: %m\n  [4]: %m\n" "a" 1 true {} @[])
         "?? at [bc] (index 2)\nstack [5]:\n  [0]: \"a\"\n  [1]: 1\n  [2]: true\n  [3]: {}\n  [4]: @[]\n")
        "pretty format should not eat explicit newlines")

# Phase 20 batch 2d found these unmeasured. Each block names what it pins.

# `%j` refuses a value it cannot write as data, and the refusal has to travel
# out of whatever container the value was found in. Each of the five below
# reaches a different arm of the jdn printer, and none of them was asked for.
(assert-error "could not print to jdn format" (string/format "%j" (/ 0 0)))
(assert-error "could not print to jdn format" (string/format "%j" print))
(assert-error "could not print to jdn format" (string/format "%j" @{:a print}))
(assert-error "could not print to jdn format" (string/format "%j" @[print]))
(assert-error "could not print to jdn format" (string/format "%j" [print]))
(assert-error "could not print to jdn format" (string/format "%j" {:a print}))

# The jdn printer spends one frame of the build's recursion budget per level,
# so a level short of it is written and the budget itself is refused. Both ends
# are asserted, because a budget spent twice as fast still refuses the far end.
#
# The budget is 1024 everywhere but wasm, where it is 512: a wasm host's call
# stack is smaller than a native thread's, and a budget the stack cannot hold
# is not a guard. `build.zig` is where that is derived.
#
# The budget is spent in three places — an array's items, a tuple's, and a
# dictionary's keys and values — and each has to be asserted through its own
# container, because a budget spent twice as fast in one of them is spent at
# the right rate in the other two.
(do
  (defn nest-arr [n] (var d @[]) (repeat n (set d @[d])) d)
  (defn nest-tup [n] (var d []) (repeat n (set d [d])) d)
  (defn nest-tab [n] (var d @{}) (repeat n (set d @{:k d})) d)
  (def budget (if (= :wasm (os/arch)) 512 1024))
  (def within (- budget 1))
  (assert-no-error "a level short of the budget prints an array as jdn"
                   (string/format "%j" (nest-arr within)))
  (assert-error "could not print to jdn format" (string/format "%j" (nest-arr budget)))
  (assert-no-error "a level short of the budget prints a tuple as jdn"
                   (string/format "%j" (nest-tup within)))
  (assert-error "could not print to jdn format" (string/format "%j" (nest-tup budget)))
  (assert-no-error "a level short of the budget prints a table as jdn"
                   (string/format "%j" (nest-tab within)))
  (assert-error "could not print to jdn format" (string/format "%j" (nest-tab budget))))

# A key that has no jdn form fails the dictionary, exactly as a value does.
(assert-error "could not print to jdn format" (string/format "%j" @{print :a}))
(assert-error "could not print to jdn format" (string/format "%j" {print :a}))

# A symbol that reads back as a number has no jdn form, and a keyword does,
# because a keyword may begin with a digit and a symbol may not.
(assert-error "could not print to jdn format" (string/format "%j" (symbol "1abc")))
# Both ends of the digit range, which is where the two comparisons differ.
(assert-error "could not print to jdn format" (string/format "%j" (symbol "0abc")))
(assert-error "could not print to jdn format" (string/format "%j" (symbol "9abc")))
(assert (= "abc" (string/format "%j" (symbol "abc"))) "an ordinary symbol has one")
(assert (= ":1abc" (string/format "%j" (keyword "1abc"))) "and a keyword may begin with a digit")

# `%p` breaks lines and elides a long dictionary; both are defaults rather
# than something the caller asks for.
(do
  (def big (table ;(mapcat |[(keyword "k" $) $] (range 40))))
  (assert (string/find "\n" (string/format "%p" big))
          "%p breaks a long dictionary across lines")
  (assert (string/has-suffix? "...}" (string/format "%q" big))
          "and elides it past thirty entries")
  # Thirty entries is the limit itself and is printed whole; thirty-one is
  # the first that elides.
  (defn tab [n] (table ;(mapcat |[(keyword "k" $) $] (range n))))
  (assert (not (string/has-suffix? "...}" (string/format "%q" (tab 30))))
          "a dictionary of exactly thirty entries is printed whole")
  (assert (string/has-suffix? "...}" (string/format "%q" (tab 31)))
          "and thirty-one is the first that elides"))

# The integer printer counts its digits by powers of ten, negating first so
# that the most negative integer has a magnitude to count.
(assert (= "0" (string/format "%q" 0)) "zero prints as one digit")
(assert (= "-9" (string/format "%q" -9)) "and each power of ten is its own arm")
(assert (= "-99" (string/format "%q" -99)))
(assert (= "-999" (string/format "%q" -999)))
(assert (= "-9999" (string/format "%q" -9999)))
(assert (= "-99999" (string/format "%q" -99999)))
# Each power of ten itself, which is the value the arm above it compares to.
(assert (= "-10" (string/format "%q" -10)))
(assert (= "-100" (string/format "%q" -100)))
(assert (= "-1000" (string/format "%q" -1000)))
(assert (= "-10000" (string/format "%q" -10000)))
(assert (= "99999" (string/format "%q" 99999)) "as is the positive side")

# A precision on `%j` is the depth budget, and it is read as a decimal number
# from a three-byte field. A precision of one is one level, not the default.
(assert-error "could not print to jdn format" (string/format "%.1j" [[1]]))
(assert (= "(((1)))" (string/format "%.10j" [[[1]]]))
        "a two-digit precision is read as both its digits")
(assert (= "(1)" (string/format "%.2j" [1])) "and a small one bounds the depth")

# `%%` is one literal per cent sign and consumes nothing after it.
(assert (= "%x" (string/format "%%x")) "%% writes one per cent and no more")
(assert (= "%" (string/format "%%")) "and it may end the format")

# The three shapes the pretty printer takes, asserted as whole strings rather
# than by a property: `%p` breaks and indents, `%q` collapses every break to
# one space, and `%P` writes colour escapes around each value. Each is a
# separate flag on the same walk, and the walk measures its own columns.
(assert (= "@[@[1 2]\n  @[3 4]]" (string/format "%p" @[@[1 2] @[3 4]]))
        "%p breaks a nested collection and indents the continuation")
(assert (= "@[@[1 2] @[3 4]]" (string/format "%q" @[@[1 2] @[3 4]]))
        "%q writes the same collection on one line")
(assert (= "@[\e[32m1\e[0m \e[35m\"a\"\e[0m]" (string/format "%P" @[1 "a"]))
        "%P wraps each value in its own colour")
(assert (= "@{}" (string/format "%p" @{})) "an empty dictionary needs no break at all")

# A buffer printed into itself is copied first, so the text being appended is
# what the buffer held rather than what it is holding as the append proceeds.
(do
  (def b @"a")
  (buffer/format b "%v" b)
  (assert (= "a@\"a\"" (string b)) "a buffer formatted into itself reads its old contents"))

(end-suite)
