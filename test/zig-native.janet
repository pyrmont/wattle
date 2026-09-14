# The native module that sets all fourteen abstract-type slots, loaded and
# exercised.
#
# `zig build test` runs this with the built module's path as its argument.
# `examples/numarray` is the worked example an author reads; this file carries
# the slots a numeric array has no use for, and is what makes "all fourteen are
# writable" a check rather than a sentence in `DESIGN.md` section 13.

(def module-path (get (dyn *args*) 1))
(def module-env @{})
(native module-path module-env)
(defn- from-module [name] ((module-env name) :value))

(def identity (from-module 'identity))
(assert (= {:loaded :from-zig} (identity {:loaded :from-zig})))

(def keep (from-module 'keep))
(def kept (from-module 'kept))
(def mark-count (from-module 'mark-count))
(def finalized-count (from-module 'finalized-count))
(def greeting (from-module 'greeting))
(def unsafe-seen (from-module 'unsafe-seen))

(def k (keep @[1 2 3] 7))

# `bytes`: the abstract answers bytes, so anything taking a byte sequence takes
# it. `string/join` is the shortest such call.
(assert (= "keeper" (string/join [k])) "the bytes slot answers bytes")

# `length`, `call`, `get` (both arms), `next` and `put`.
(assert (= 6 (length k)) "the length slot")
(assert (deep= @[1 2 3] (k)) "the call slot answers what the keeper holds")
# `(k 0)` would reach `call`, not `get`: a type with a `call` slot is called
# rather than indexed. `get` is what `(get x k)` and `(:method x)` reach.
(assert (= 107 (get k 0)) "the get slot indexes the bytes")
(assert (nil? (get k 99)) "an index past the end is a miss, not a refusal")
(assert (= 114 (get k 5)) "the last byte of the text is the last index")
(assert (nil? (get k 6)) "and the first index past it is a miss")
(assert (deep= @[1 2 3] (:kept k)) "the get slot's keyword arm reaches a method")
(assert (= 7 (:rank k)) "and the other method")
(assert (deep= @[:kept :rank] (keys k)) "the next slot walks the method table")
(put k :rank 9)
(assert (= 9 (:rank k)) "the put slot")

# `tostring`, through both of the pretty-printer's dispatch sites.
(assert (= "keeper#9@1" (string k)) "the tostring slot")
(assert (= "<zig-native/keeper keeper#9@1>" (describe k)) "and the described form")

# `compare` and `hash`: two keepers order and key by their rank.
(def low (keep :a 1))
(def high (keep :a 2))
(assert (< low high) "the compare slot orders by rank")
(assert (= 2 (length (distinct @[low high (keep :b 1)])))
        "the hash slot keys equal ranks together")
# `keep` stamps each keeper with the next serial number, and `low` is the
# second keeper made.
(assert (= "keeper#1@2" (string low)) "serial numbers count the keepers made")

# `marshal` and `unmarshal`, through the two capabilities. The type has to be
# registered for this to work at all -- an abstract carries its type's *name*
# on the wire -- and `defs` is where the module does that.
(def round (unmarshal (marshal k)))
(assert (= "keeper#9@1" (string round)) "a keeper survives a round trip")
(assert (deep= @[1 2 3] (kept round)) "and so does the value it holds")

# `gcmark` and `gc`: the collector reaches both, and the value the payload
# holds is still there afterwards. The counters are what make "the slot ran" an
# assertion rather than an inference -- a module cannot otherwise observe a
# traversal or a sweep it did not start.
(def marks-before (mark-count))
(def finalized-before (finalized-count))
(repeat 50 (keep @[:garbage]))
(gccollect)
(assert (> (mark-count) marks-before) "the collector reached the gcmark slot")
(assert (> (finalized-count) finalized-before) "and the gc slot")
(assert (deep= @[1 2 3] (kept k)) "the marked value survived the collection")

# And each counts once: a collection marks each live keeper once, so five more
# live keepers are five more marks, and five keepers dropped are five
# finalized.
(gccollect)
(def marks-a (mark-count))
(gccollect)
(def marks-alone (- (mark-count) marks-a))
(var five (seq [_ :range [0 5]] (keep :five)))
(def marks-b (mark-count))
(gccollect)
(assert (= (+ marks-alone 5) (- (mark-count) marks-b)) "one mark per live keeper per collection")
(def finalized-a (finalized-count))
(set five nil)
(gccollect)
(assert (= 5 (- (finalized-count) finalized-a)) "one finalization per keeper collected")

# `isUnsafe` on both capabilities. It answers false everywhere a Janet program
# can reach -- `marshal` exposes only the no-cycles flag -- so the value this
# asserts is zero; what the calls above prove is that the comptime dispatch
# instantiates for a *Marshal and for an *Unmarshal alike.
(assert (= 0 (unsafe-seen)) "no reachable marshal runs in unsafe mode")

# A cfunction returning a string, which is `janet.cstring`.
(assert (= "hello from a module" (greeting)) "a module can build a string")

# ==========================================================================
# The getters, the range and the tag tests
# ==========================================================================

(def markup (from-module 'markup))
(def tally (from-module 'tally))
(def cut (from-module 'cut))
(def wrap (from-module 'wrap))
(def classify (from-module 'classify))
(def named (from-module 'named))
(def peek (from-module 'peek))

(defn- refusal
  "The message a call refuses with, or nil if it did not refuse."
  [f & args]
  (def [ok result] (protect (f ;args)))
  (unless ok result))

# `getBytes` and `getIndexed`, on both members of each pair. A module of
# markable's shape reads a string argument and a tuple of keywords; it must
# read a buffer and an array just as well, because the getter answers the same
# slice for both members of a pair.
(assert (= "<0>hi</0>" (markup "hi")) "getBytes reads a string")
(assert (= "<0>hi</0>" (markup @"hi")) "and a buffer")
(assert (= "<0></0>" (markup "")) "an empty argument is the empty slice, not a trap")
(assert (= "<5>hi</5>" (markup "hi" [:sourcepos :smart])) "getIndexed reads a tuple")
(assert (= "<5>hi</5>" (markup "hi" @[:sourcepos :smart])) "and an array")
(assert (= "<0>hi</0>" (markup "hi" [])) "an empty tuple is the empty slice")
(assert (= "<15>x</15>" (markup "x" [:sourcepos :hardbreaks :smart :footnotes]))
        "every option composes")

# The formatted refusal, which is `panicFormat`, and the module's own message
# rather than the runtime's -- an unknown keyword is not a type error.
(assert (= "invalid option :bogus" (refusal markup "x" [:bogus]))
        "an unknown option is refused by name")
# `panicFormat` formats up to 255 bytes on the stack and anything longer on the
# heap. A 240-byte name makes the refusal exactly 256 bytes.
(def long-name (string/repeat "a" 240))
(assert (= (string "invalid option :" long-name) (refusal markup "x" [(keyword long-name)]))
        "a 256-byte refusal arrives whole")
(assert (= "option 1 is not a keyword" (refusal markup "x" [:smart 3]))
        "and a non-keyword element by position")
# `getBoolean`, which is what turns the refusal off.
(assert (= "<0>x</0>" (markup "x" [:bogus] false)) "getBoolean reads the strict flag")
(assert (= "bad slot #2, expected boolean, got 3" (refusal markup "x" [] 3))
        "and refuses a non-boolean with the runtime's own message")

# The wrong type, on each of the three getters. The message is `args.zig`'s,
# which is the same one a C module got for the same mistake.
(assert (= "bad slot #0, expected string, symbol, keyword or buffer, got 3"
           (refusal markup 3))
        "getBytes refuses a number")
(assert (= "bad slot #1, expected array or tuple, got 3" (refusal markup "x" 3))
        "getIndexed refuses a number")
(assert (= "bad slot #0, expected table or struct, got \"x\"" (refusal tally "x"))
        "getDictionary refuses a string")

# `getDictionary`, on both members of its pair. The walk is `Pairs`, whose
# `next` answers one pair at a time, and the fixture refuses if its own count
# disagrees with the `len` it was given.
(assert (= 6 (tally {:a 1 :b 2 :c 3})) "getDictionary reads a struct")
(assert (= 6 (tally @{:a 1 :b 2 :c 3})) "and a table")
(assert (= 0 (tally {})) "an empty struct walks to zero")
(assert (= 0 (tally @{})) "and an empty table")
(assert (= 3 (tally {:a 1 :b :two :c 2})) "a non-numeric value is skipped, not refused")

# `getRange`: a negative index, an absent slot and the clamp are the ones
# every core builtin taking a slice already has.
(assert (= "abcde" (cut "abcde")) "an absent range is the whole slice")
(assert (= "cde" (cut "abcde" 2)) "an absent end runs to the length")
(assert (= "bc" (cut "abcde" 1 3)) "both ends given")
(assert (= "e" (cut "abcde" -2)) "a negative start counts from the end")
(assert (= (string/slice "abcde" -3 -1) (cut "abcde" -3 -1))
        "and folds exactly as string/slice does, because it is the same code")
(assert (= "" (cut "abcde" 3 1)) "an end below the start clamps up to it")
(assert (= "bc" (cut @"abcde" 1 3)) "and the source may be a buffer")
(assert (= "start index 9 out of range [-6,5]" (refusal cut "abcde" 9))
        "an index past the length is the runtime's own refusal")
# The module copies into 256 bytes and terminates the copy, so 255 is the
# longest slice it gives back.
(assert (= 255 (length (cut (string/repeat "x" 255)))) "a slice of 255 bytes fits")
(assert (= "slice does not fit" (refusal cut (string/repeat "x" 256)))
        "and one of 256 is refused by the module")

# `getUInteger`, which is a wrap column and not a size: the refusal names the
# width it wanted.
(assert (= "abc" (wrap "abcde" 3)) "getUInteger reads a width")
(assert (= "abcde" (wrap "abcde" 99)) "a width past the length is the whole slice")
(assert (= 255 (length (wrap (string/repeat "x" 300) 300)))
        "and a width past the module's 255 bytes is clamped to them")
(assert (= "bad slot #1, expected 32 bit unsigned integer, got -1"
           (refusal wrap "abcde" -1))
        "and refuses a negative one")

# The twelve tag tests, each on a value of its own type.
(assert (= "nil" (classify nil)))
(assert (= "boolean" (classify true)))
(assert (= "number" (classify 1)))
# The one value a Janet program can build a raw pointer from is an FFI symbol
# lookup, and a build without FFI has none -- so this arm is reached only where
# there is something to reach it with. The symbol is libc's, because the
# runtime publishes none: a native module reaches it through the table
# `_janet_init` is handed, so `nm` on the process finds no `janet_*` at all.
(def ffi-lookup (get-in (curenv) ['ffi/lookup :value]))
(def ffi-native (get-in (curenv) ['ffi/native :value]))
(when (and ffi-lookup ffi-native)
  (assert (= "pointer" (classify (ffi-lookup (ffi-native nil) "malloc")))))
(assert (= "string" (classify "s")))
(assert (= "symbol" (classify 'sym)))
(assert (= "keyword" (classify :kw)))
(assert (= "buffer" (classify @"b")))
(assert (= "tuple" (classify [1])))
(assert (= "array" (classify @[1])))
(assert (= "struct" (classify {})))
(assert (= "table" (classify @{})))
(assert (= "function" (classify (fn [] nil))) "a function is the thirteenth")
(assert (= "other" (classify classify)) "a cfunction is none of the thirteen")

# The tag-specific unwraps, which answer a NUL-terminated slice where the
# predicates answer a bool. Each takes one tag: the buffer holding the same
# bytes is a miss rather than a refusal, because a buffer carries no
# terminator.
(assert (= "abc" (named "abc")) "toString reads a string")
(assert (= "abc" (named 'abc)) "toSymbol a symbol")
(assert (= "abc" (named :abc)) "toKeyword a keyword")
(assert (= "" (named "")) "and an empty string, whose terminator is all it has")
(assert (nil? (named @"abc")) "a buffer has no terminator and is not one of the three")
(assert (nil? (named 3)) "nor is a number, and that is not a refusal")

# `toAbstract`: a keeper read out of an aggregate, the case with no slot for
# `getAbstract` to read. The test is on the abstract type's identity, so
# another module type in the same position is a refusal rather than a read of
# its payload.
(assert (deep= @[1 2 3] (peek [k] 0)) "toAbstract reads a keeper out of a tuple")
(assert (deep= @[1 2 3] (peek @[:x k] 1)) "and out of an array, at an index")
(assert (= "element 0 is not a keeper" (refusal peek [:x] 0))
        "a value that is not an abstract is refused by the module, not the runtime")
(assert (= "index 1 is past the end" (refusal peek [k] 1))
        "and the first index past the end is refused")
# The other half of that test -- an abstract of this module's *other* type --
# is asserted where `odd` is defined, further down.

# The three `Value`-form getters, which read a value that came out of an
# aggregate rather than an argument slot.
# Each answers nothing rather than raising, on both members of its pair.
(def viewed (from-module 'viewed))

(assert (= "bytes 3" (viewed "abc")) "bytesView on a string")
(assert (= "bytes 3" (viewed @"abc")) "and on a buffer")
(assert (= "bytes 3" (viewed :abc)) "and on a keyword")
(assert (= "bytes 0" (viewed "")) "and on an empty one")
(assert (= "indexed 2" (viewed [1 2])) "indexedView on a tuple")
(assert (= "indexed 2" (viewed @[1 2])) "and on an array")
(assert (= "indexed 0" (viewed @[])) "and on an empty array, whose data pointer is null")
(assert (= "dictionary 2" (viewed {:a 1 :b 2})) "dictionaryView on a struct")
(assert (= "dictionary 2" (viewed @{:a 1 :b 2})) "and on a table")
(assert (= "dictionary 0" (viewed @{})) "an empty table has entries, and none of them")
(assert (= "dictionary 0" (viewed {})) "and so does an empty struct")
(assert (= "none" (viewed 3)) "no *View function reads a number, and that is not a refusal")
(assert (= "none" (viewed nil)) "nor does nil")
(assert (= "bytes 6" (viewed k)) "a byte-like abstract answers through its bytes callback")

# ==========================================================================
# Construction, and mutation through the Value
# ==========================================================================

(def built (from-module 'built))
(def pointer-value (from-module 'pointer-value))
(def mutate (from-module 'mutate))
(def fetch (from-module 'fetch))

# Every composite, round-tripped through Janet's own equality. The module
# built each from the slice `getBytes` returned, which is the symmetry the
# rule predicts: a constructor takes what the getter of the same type returns.
(assert (deep= [true false "xy" 'xy :xy [1 2] @[1 2] @"xy" {:a 1 :b 2} @{:a 1 :b 2}]
               (built "xy"))
        "every constructor round-trips")
(assert (deep= (built "xy") (built @"xy")) "and the seed may be a buffer")
# An empty seed. The empty symbol and the empty keyword have no reader syntax,
# so they are named by interning them the same way the module did.
(def empty-built (built ""))
(assert (= "" (empty-built 2)) "an empty seed builds the empty string")
(assert (= (symbol "") (empty-built 3)) "and the empty symbol")
(assert (= (keyword "") (empty-built 4)) "and the empty keyword")
(assert (= 0 (length (empty-built 7))) "and an empty buffer")

# The types are what they claim, not just equal to something that prints alike.
(def parts (built "xy"))
(assert (= :boolean (type (parts 0))) "boolean")
(assert (= :string (type (parts 2))) "string")
(assert (= :symbol (type (parts 3))) "symbol")
(assert (= :keyword (type (parts 4))) "keyword")
(assert (= :tuple (type (parts 5))) "tuple")
(assert (= :array (type (parts 6))) "array")
(assert (= :buffer (type (parts 7))) "buffer")
(assert (= :struct (type (parts 8))) "struct")
(assert (= :table (type (parts 9))) "table")

# Interning: a symbol and a keyword the module made are the same object as the
# ones this file writes, which is what `symbol` and `keyword` promise.
(assert (= 'xy (parts 3)) "a symbol interns to the same object")
(assert (= :xy (parts 4)) "and so does a keyword")

# A raw pointer, whose round trip the module checked on its own side because
# `toPointer` is the only way to read one back.
(assert (= :pointer (type (pointer-value))) "pointer answers a pointer")
(assert (= (pointer-value) (pointer-value)) "and the same address twice")

# Mutation, on values handed in: nothing crossed but the Value.
(def arr @[1 2])
(def tab @{:x 1})
(def buf @"ab")
(assert (= 3 (mutate arr tab buf)) "length answers the array's new count")
(assert (deep= @[1 2 99] arr) "arrayPush appended")
(assert (= true (tab :added)) "put wrote through the Value")
(assert (= "ab!" (string buf)) "bufferPush appended")

# The wrong-type refusals, each the runtime's own message.
# A table renders as its address in a refusal, so this one matches a prefix
# where the others match the whole message.
(assert (string/has-prefix? "expected array, got <table " (refusal mutate @{} @{} @""))
        "arrayPush refuses a table")
(assert (= "expected buffer, got \"ab\"" (refusal mutate @[] @{} "ab"))
        "bufferPush refuses a string")
(assert (= "expected array, table or buffer, got 3" (refusal mutate @[] 3 @""))
        "put refuses a number, with Janet's own message")

# `get` is Janet's own: a miss is nil and so is a value with no indexed
# access. It does not refuse, which is what separates it from `put`.
(assert (= 1 (fetch @{:x 1} :x)) "get reads a table")
(assert (= 1 (fetch {:x 1} :x)) "and a struct")
(assert (= 2 (fetch [1 2 3] 1)) "and a tuple by index")
(assert (nil? (fetch @{:x 1} :missing)) "a miss is nil")
(assert (nil? (fetch 3 :x)) "and so is a number, which get does not refuse")
(assert (= 1 (fetch (get (built "xy") 8) :a)) "get reads a struct the module built")

# `length` refuses what has none, and refuses a negative answer.
(def size (from-module 'size))
(def odd (from-module 'odd))

(assert (= 3 (size "abc")) "length of a string")
(assert (= 2 (size @[1 2])) "of an array")
(assert (= 1 (size @{:a 1})) "of a table")
(assert (= 6 (size k)) "and of an abstract with a length slot")
(assert (= "expected string, symbol, keyword, array, tuple, table, struct or buffer, got 3"
           (refusal size 3))
        "length refuses a number with the runtime's own message")

# The one path where a runtime call re-enters Janet code: an abstract with no
# `length` slot resolves `:length` as a Janet method. A method may answer a
# negative, and the runtime refuses it. This is the only place in the tree that
# reaches the method arm at all.
# Two ways for a method to answer something that is not a length, and both
# spellings of the question must refuse both. `length` and `lengthv` used to
# disagree here -- one checked its method's answer and the other did not -- and
# each half of that was found by running it.
(assert (= -1 (:length (odd 0))) "the method really does answer -1")
(assert (= "not a number at all" (:length (odd 1))) "and really does answer a string")

(assert (= "invalid integer length -1" (refusal size (odd 0)))
        "the module's length refuses a negative")
(assert (= "invalid integer length -1" (refusal length (odd 0)))
        "and so does Janet's own, through the other entry point")
(assert (= "invalid integer length \"not a number at all\"" (refusal size (odd 1)))
        "the module's length refuses a non-number")
(assert (= "invalid integer length \"not a number at all\"" (refusal length (odd 1)))
        "and so does Janet's own -- the two agree on every arm but the bound")

# `toAbstract` tests the abstract type's identity rather than the tag: an
# `odd` unwraps to a valid pointer into a payload that is not a keeper's, and
# reading it as one would fail silently.
(assert (= "element 0 is not a keeper" (refusal peek [(odd 0)] 0))
        "an abstract of the module's other type is not a keeper")

# ==========================================================================
# Calling back into Janet
# ==========================================================================
#
# `call` raises on anything but a return and `pcall` reports; the pair below is
# the same Janet code through both, which is the whole of the difference.

(def apply-fn (from-module 'apply))
(def attempt (from-module 'attempt))
(def status-of (from-module 'status-of))
(def sorted (from-module 'sorted))
(def kept-across (from-module 'kept-across))
(def unkept-across (from-module 'unkept-across))

(defn attempted
  "`attempt`, with the fiber replaced by its status, so an answer compares whole."
  [f & args]
  (def [sig val fib] (attempt f ;args))
  [sig val (if fib (status-of fib))])

# A return, through both.
(assert (= 7 (apply-fn (fn [a b] (+ a b)) 3 4)) "call runs a Janet function")
(assert (= 0 (apply-fn (fn [] 0))) "and one with no arguments")
(assert (deep= [:ok 7 :dead] (attempted (fn [a b] (+ a b)) 3 4))
        "pcall reports the return, and the fiber it ran on is spent")

# `f` is whatever Janet calls, not only a function: a cfunction, and the
# indexable types, which index their one argument rather than call it.
(assert (= true (apply-fn < 1 2)) "call runs a cfunction")
(assert (= 1 (apply-fn {:a 1} :a)) "a struct called is a lookup, as in Janet")
(assert (= 1 (apply-fn :a {:a 1})) "and a keyword reverses the operands")

# `pcall` is narrower, and by the callee's nature rather than by a decision
# here: a fiber runs a function and nothing else.
(assert (deep= [:error "expected function, got table" nil] (attempted @{:a 1} :a))
        "pcall reports a non-function and makes no fiber")

# An error. `call` raises it and `pcall` reports it, with one payload.
(assert (= "boom" (refusal apply-fn (fn [] (error "boom"))))
        "call raises the error Janet code raised")
(assert (deep= [:error "boom" :error] (attempted (fn [] (error "boom"))))
        "pcall reports it instead, and the fiber carries the status")

# A yield. `call` refuses it with the message the runtime coerces it into;
# `pcall` reports `:yield` with the yielded value and a resumable fiber.
(assert (= "5 coerced from yield to error" (refusal apply-fn (fn [] (yield 5) :after)))
        "call refuses a yield with the runtime's coercion message")
(def [sig val fib] (attempt (fn [] (yield 5) :after)))
(assert (= :yield sig) "pcall reports the signal")
(assert (= 5 val) "and the yielded value")
(assert (= :pending (status-of fib)) "and a fiber that is pending")
(assert (= :pending (fiber/status fib)) "which is the status Janet reports too")
(assert (= :after (resume fib)) "and it resumes to the value after the yield")
(assert (= :dead (status-of fib)) "and is spent once it has")

# A debug signal is a signal like any other: `call` coerces it and `pcall`
# reports it.
(assert (= "1 coerced from debug to error" (refusal apply-fn (fn [] (debug 1))))
        "call refuses a debug signal with the same coercion")

# `fiberStatus` over every status a fixture can produce, including the two the
# signal vocabulary has no name for.
(assert (= :new (status-of (fiber/new (fn [] 1)))) "new, before it has run")
(assert (= :alive (apply-fn (fn [] (status-of (fiber/current)))))
        "alive, asked of the fiber that is running")
(assert (= "expected fiber, got 3" (refusal status-of 3))
        "and it refuses a non-fiber with the runtime's own message")

# Nesting: a module calling into Janet which calls the module again, which is
# what the runtime's recursion guard exists for.
#
# **The guard's own refusal is not asserted here, and the reason is a
# measurement rather than a preference.** It fires at `stackn ==
# config.recursion_guard`, which is 1024, and one level of this loop costs
# about 24KB of C stack in a debug build against upstream's 8KB -- so a debug
# binary on an 8MB main thread exhausts the stack at depth 348 and never
# reaches the guard. All three release modes reach it at 1022, exactly as
# upstream does, each one measured rather than inferred; asserting the message
# would therefore pass in three of the matrix's four optimize modes and crash
# the process in the fourth. `port/phase_18/part_09.md` carries the figures.
# What is asserted is the depth this nesting is actually good for.
(var reached 0)
(defn recurse [n] (++ reached) (if (< n 100) (apply-fn recurse (inc n)) :bottom))
(assert (= :bottom (recurse 0)) "call nests a hundred deep and returns")
(assert (= 101 reached) "and every level ran")

# The shape that justifies the part: a comparator passed to a sort.
(assert (deep= @[1 2 3 5 9] (sorted < @[5 1 9 2 3])) "a cfunction comparator")
(assert (deep= @[9 5 3 2 1] (sorted > [5 1 9 2 3])) "and over a tuple")
(assert (deep= @[9 5 3 2 1] (sorted (fn [a b] (> a b)) @[5 1 9 2 3]))
        "and a Janet function")
(assert (deep= @[] (sorted < @[])) "the empty case")
(assert (deep= @[1] (sorted < @[1])) "and the one-element case")
(assert (= "boom" (refusal sorted (fn [a b] (error "boom")) @[2 1]))
        "a comparator that raises raises through the sort")
(assert (deep= @[1 2 3 5 9] (sorted (fn [a b] (gccollect) (< a b)) @[5 1 9 2 3]))
        "and the working array survives a collection inside the comparator")

# Forwarding a cfunction's own `argv` is the shortest thing a module does with
# `call`, and those arguments are a slice of the fiber's own stack -- so the
# push that copies them is the one that would read a freed block, because
# growing the stack reallocates it. This is the test of `fibers.pushn`'s growth
# branch, which re-derives its source across that move. A *sum* is what catches
# a failure and a length is not: a corrupted argument changes the sum and
# leaves the arity alone. With the re-derivation removed this reports 25 wrong
# answers out of 399, the first at n=25, and no crash.
(defn- total [& xs] (sum xs))
(var miscopied 0)
(for n 1 400
  (unless (= (sum (range n)) (apply-fn total ;(range n))) (++ miscopied)))
(assert (= 0 miscopied)
        "call forwards a cfunction's own argv across the push that grows the stack")

# The GC pin. `kept-across` builds a table, roots it, calls a function that
# collects, unroots it and answers it intact.
(assert (deep= @{:kept "across a collection"} (kept-across (fn [] (gccollect))))
        "a rooted value survives a collection under a call")
(assert (deep= @{:kept "across a collection"} (kept-across (fn [] 1)))
        "and the root is balanced, so a second call behaves the same")

# The same sequence with no root is *not* asserted to fail: a collection
# freeing a value the module still holds is undefined behaviour, not a testable
# outcome. It is called so that the arm compiles and runs, and its answer is
# deliberately not examined.
(unkept-across (fn [] 1))

# ------------------------------------------ scheduling work from a thread
#
# The three shapes the loop offers a module: one thread waking one fiber,
# several posting at once, and a fiber cancelled before its wake arrives.
# Everything below runs under `ev/go` and `ev/gather`, because a fiber that
# suspends with `await` is resumed by the loop and by nothing else.

(def loop-available (from-module 'loop-available))
(def has-ev (not (nil? (root-env 'ev/go))))

# **A build without the loop reaches exactly this assertion.** The four
# functions are published in every build and `loop()` is the one that refuses,
# so a module asking for the capability is where the refusal shows up.
(assert (= has-ev (loop-available))
        "loop() answers a capability exactly where the build has an event loop")

# **The exit keeps the rest of this file out of a no-loop build's *compiler*,
# not only out of its run.** Janet compiles and runs one top-level form at a
# time, so a form after this one is never compiled and `ev/gather` below is not
# an unknown symbol there. A `when` around the section would not do: the body
# of one is compiled either way.
(unless has-ev
  (print "zig-native ok (no event loop)")
  (os/exit 0))

(def later (from-module 'later))
(def stampede (from-module 'stampede))
(def abandoned (from-module 'abandoned))
(def release-abandoned (from-module 'release-abandoned))
(def wake-refused (from-module 'wake-refused))
(def refused-freed (from-module 'refused-freed))

# One thread, one fiber, one wake. The value is the thread's, computed after
# the fiber suspended.
(assert (= 9 (first (ev/gather (later 4))))
        "a fiber suspended with await is woken with the thread's value")

# Three fibers each waiting on a thread of their own.
(assert (deep= @[3 5 7] (ev/gather (later 1) (later 2) (later 3)))
        "three fibers wait on three threads at once")

# The same shape under `ev/go` rather than `ev/gather`, through a supervisor
# channel so the answer comes back as an event rather than as a return.
(def chan (ev/chan))
(ev/go (fiber/new (fn [] (later 10)) :ti) nil chan)
(def [sig fib] (ev/take chan))
(assert (= :ok sig) "await under ev/go ends in a return")
(assert (= 21 (fiber/last-value fib)) "and carries the woken value")

# Several threads posting at once. **Nothing is asserted about their order**,
# which is the one thing the loop does not promise; what is asserted is that
# every post arrived, counted by the callbacks themselves. The counter needs no
# lock because posted callbacks run one at a time on the loop thread.
(assert (= 8 (first (ev/gather (stampede 8))))
        "eight threads post at once and every wake arrives")
(assert (= 1 (first (ev/gather (stampede 1))))
        "and one thread is the same shape")
(assert (= 32 (first (ev/gather (stampede 32))))
        "thirty-two threads is the most it takes")
(assert (= "stampede wants 1 to 32 threads" (refusal stampede 33))
        "and thirty-three is refused before any thread starts")

# A fiber cancelled between its `await` and its wake. The thread is held at a
# gate so the ordering is the test's rather than a sleep's: suspend, cancel,
# then release.
(def before-refused (wake-refused))
(def before-freed (refused-freed))
(def gone (ev/chan))
(def victim (ev/go (fiber/new (fn [] (abandoned)) :ti) nil gone))
(ev/sleep 0)
(ev/cancel victim "abandoned")
(def [cancel-sig _] (ev/take gone))
(assert (= :error cancel-sig) "ev/cancel ends the waiting fiber")
(release-abandoned)
# The callback runs on the loop's next turn once the post lands. Bounded rather
# than open, so a failure is a failed assertion and not a hang.
(var turns 0)
(while (and (= before-refused (wake-refused)) (< turns 400))
  (ev/sleep 0.005)
  (++ turns))
(assert (= (inc before-refused) (wake-refused))
        "wake answers false for a fiber ev/cancel has moved on")
(assert (= (inc before-freed) (refused-freed))
        "and the callback frees its context on that branch")

# The loop is not starved while a module's thread is working: a fiber doing
# something else keeps running underneath the wait.
(var ticks 0)
(def [waited _] (ev/gather (later 100) (do (repeat 50 (++ ticks) (ev/sleep 0)) :ticked)))
(assert (= 201 waited) "the wait answers its thread's value")
(assert (= 50 ticks) "and another fiber ran fifty times while it waited")
