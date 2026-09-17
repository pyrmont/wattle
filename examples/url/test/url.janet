# The built-in types' worked example, loaded and exercised.
#
# `zig build test` runs this with the built module's path as its argument,
# which is what makes "a module can be written against the getters" a check
# rather than a claim.

(def module-path (get (dyn *args*) 1))

# **An ordinary import, which is how a user reaches a native module.** The path
# is an argument only because `zig build` puts the shared object in its cache
# rather than on `WATTLE_PATH`; everything after this line is what someone who
# had installed the module would write.
#
# `cfuns` passes its prefix to the *registry*, for stack traces, and leaves the
# binding unprefixed -- so `url/` in front of these names comes from the
# `:prefix` here, exactly as it would from `(import url)`.
(import* module-path :prefix "url/")

(defn- refusal
  "The message a call refuses with, or nil if it did not refuse."
  [f & args]
  (def [ok result] (protect (f ;args)))
  (unless ok result))

# --------------------------------------------------------------- getBytes
#
# Every type `getBytes` reads, because it reads them the same way: a string, a
# symbol and a keyword carry their own terminator, and a buffer does not.

(assert (= "Hello-World" (url/slug "Hello, World!")) "a string argument")
(assert (= "Hello-World" (url/slug @"Hello, World!")) "a buffer argument")
(assert (= "hello" (url/slug 'hello)) "a symbol argument")
(assert (= "hello" (url/slug :hello)) "a keyword argument")
(assert (= "" (url/slug "")) "an empty string is the empty slice, not a trap")
(assert (= "" (url/slug "!!!")) "and so is a title with nothing to keep")
(assert (= "a-b-c" (url/slug "  a  b  c  ")) "runs of punctuation collapse to one separator")

# ------------------------------------------------------------- getIndexed
#
# Both types again, and the two refusals the module raises itself.

(assert (= "hello-world" (url/slug "Hello World" [:lower])) "a tuple of options")
(assert (= "hello-world" (url/slug "Hello World" @[:lower])) "an array of options")
(assert (= "Hello-World" (url/slug "Hello World" [])) "an empty options tuple")
(assert (= "HELLO_WORLD" (url/slug "Hello World" [:upper :underscore])) "options compose")
(assert (= "unknown option :bogus" (refusal url/slug "x y" [:bogus]))
        "an unknown option is refused by name, which is panicFormat")
(assert (= "option 1 is not a keyword" (refusal url/slug "x y" [:lower 3]))
        "and a non-keyword element by position")

# ---------------------------------------------------------- getDictionary
#
# All three types, and the walk `Dictionary` gives. The order is the hash
# order, so the assertions sort.

(defn- parts [s] (sort (string/split "&" s)))

(assert (deep= @["a=1" "b=2"] (parts (url/query {:a 1 :b 2}))) "a struct")
(assert (deep= @["a=1" "b=2"] (parts (url/query @{:a 1 :b 2}))) "a table")
(assert (deep= @["a=1" "b=2"] (parts (url/query (hash-map :a 1 :b 2)))) "a map")
(assert (= "" (url/query {})) "an empty struct has no entries to walk")
(assert (= "" (url/query @{})) "and neither does an empty table")
(assert (deep= @["name=ada" "tag=x"] (parts (url/query {:name "ada" :tag :x})))
        "a value may be text as well as a number")
(assert (= "every query key must be a keyword" (refusal url/query {"a" 1}))
        "a string key is refused")
(assert (= "the value of :a is neither a number nor text" (refusal url/query {:a [1]}))
        "and so is a value that is neither")

# ---------------------------------------------------------------- a range
#
# The three rules are Janet's own, because `getRange` is the code every core
# builtin taking a slice already uses.

(assert (= "abcde" (url/cut "abcde")) "an absent range is the whole text")
(assert (= "cde" (url/cut "abcde" 2)) "an absent end runs to the length")
(assert (= "bc" (url/cut "abcde" 1 3)) "both ends given")
(assert (= (string/slice "abcde" -3 -1) (url/cut "abcde" -3 -1))
        "a negative index folds exactly as string/slice does")
(assert (= "" (url/cut "abcde" 3 1)) "an end below the start clamps up to it")
(assert (= "start index 9 out of range [-6,5]" (refusal url/cut "abcde" 9))
        "and an index past the length is the runtime's own refusal")

# ----------------------------------------------------------- construction
#
# `parse-query` is `query`'s inverse, and the first thing here that returns a
# composite rather than a string. The constructors take exactly what the
# getters return, which is why the pairs are built from the slice `getBytes`
# returns with nothing copied.

(assert (deep= {:a "1" :b "2"} (url/parse-query "a=1&b=2")) "a query string parses to a struct")
(assert (deep= {} (url/parse-query "")) "an empty query is an empty struct")
(assert (deep= {:a "2"} (url/parse-query "a=1&a=2")) "a repeated key keeps the last")
(assert (deep= {:a ""} (url/parse-query "a=")) "an empty value is the empty string")
(assert (= :struct (type (url/parse-query "a=1"))) "and the answer really is a struct")
(assert (= "field 0 has no '='" (refusal url/parse-query "nope"))
        "a field with no separator is refused by name")

# The round trip, which is what says the two are inverses.
(assert (deep= {:a "1" :b "2"} (url/parse-query (url/query {:a 1 :b 2})))
        "query and parse-query round-trip")

# ------------------------------------------------- the runtime's refusals
#
# A wrong argument type is refused by the getter, with the message a C module
# got for the same mistake. The module wrote none of these.

(assert (= "bad slot #0, expected string, symbol, keyword or buffer, got 3"
           (refusal url/slug 3))
        "getBytes names the four types it takes")
(assert (= "bad slot #1, expected indexed value, got :lower" (refusal url/slug "x" :lower))
        "getIndexed names the protocol it reads")
(assert (= "bad slot #0, expected dictionary value, got \"x\"" (refusal url/query "x"))
        "and getDictionary names the protocol it reads")

(print "url example ok")
