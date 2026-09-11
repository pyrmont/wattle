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

# Printing to buffers
# d47804d22
(def out-buf @"")
(def err-buf @"")
(with-dyns [:out out-buf :err err-buf]
  (print "Hello")
  (prin "hi")
  (eprint "Sup")
  (eprin "not much."))

(assert (= (string out-buf) "Hello\nhi") "print and prin to buffer 1")
(assert (= (string err-buf) "Sup\nnot much.")
        "eprint and eprin to buffer 1")

# Printing to functions
# 4e263b8c3
(def out-buf :shadow @"")
(defn prepend [x]
  (with-dyns [:out out-buf]
    (prin "> " x)))
(with-dyns [:out prepend]
  (print "Hello world"))

(assert (= (string out-buf) "> Hello world\n")
        "print to buffer via function")

# c2f844157, 3c523d66e
(with [f (file/temp)]
  (assert (= 0 (file/tell f)) "start of file")
  (file/write f "foo\n")
  (assert (= 4 (file/tell f)) "after written string")
  (file/flush f)
  (file/seek f :set 0)
  (assert (= 0 (file/tell f)) "start of file again")
  (assert (= (string (file/read f :all)) "foo\n") "temp files work"))

# issue #1055 - 2c927ea76
(let [b @""]
  (defn dummy [a bb c]
    (+ a bb c))
  (trace dummy)
  (defn errout [arg]
    (buffer/push b arg))
  (assert (= 6 (with-dyns [*err* errout] (dummy 1 2 3)))
          "trace to custom err function")
  (assert (deep= @"trace (dummy 1 2 3)\n" b) "trace buffer correct"))


# xprintf
(def b @"")
(defn to-b [a] (buffer/push b a))
(xprintf to-b "123")
(assert (deep= b @"123\n") "xprintf to buffer")


(assert-error "cannot print to 3" (xprintf 3 "123"))

# Every destination the print families accept.
(def sink @"")
(defn collected [f] (buffer/clear sink) (f) (string sink))

(assert (= "a1\n" (collected |(with-dyns [:out sink] (print "a" 1)))) "print to buffer")
(assert (= "a1" (collected |(with-dyns [:out sink] (prin "a" 1)))) "prin to buffer")
(assert (= "x=2\n" (collected |(with-dyns [:out sink] (printf "x=%d" 2)))) "printf to buffer")
(assert (= "x=2" (collected |(with-dyns [:out sink] (prinf "x=%d" 2)))) "prinf to buffer")
(assert (= "e\n" (collected |(with-dyns [:err sink] (eprint "e")))) "eprint to buffer")
(assert (= "e" (collected |(with-dyns [:err sink] (eprin "e")))) "eprin to buffer")
(assert (= "y=3\n" (collected |(with-dyns [:err sink] (eprintf "y=%d" 3)))) "eprintf to buffer")
(assert (= "y=3" (collected |(with-dyns [:err sink] (eprinf "y=%d" 3)))) "eprinf to buffer")

(assert (= "b\n" (collected |(xprint sink "b"))) "xprint to buffer")
(assert (= "b" (collected |(xprin sink "b"))) "xprin to buffer")
(assert (= "z=4\n" (collected |(xprintf sink "z=%d" 4))) "xprintf to buffer")
(assert (= "z=4" (collected |(xprinf sink "z=%d" 4))) "xprinf to buffer")

# A function destination is handed one buffer with everything already in it
(def calls @[])
(defn record [x] (array/push calls (string x)))
(array/clear calls)
(xprint record "p" "q")
(assert (deep= @["pq\n"] calls) "xprint to function is one call")
(array/clear calls)
(xprinf record "%s-%s" "p" "q")
(assert (deep= @["p-q"] calls) "xprinf to function is one call")

# Values that are neither a byte sequence nor a destination
(assert-error-value "xprint to a number" "cannot print to 3" (xprint 3 "x"))
(assert-error-value "xprin to a number" "cannot print to 3" (xprin 3 "x"))
(assert-error-value "xprinf to a keyword" "cannot print to :k" (xprinf :k "%s" "x"))
(assert-error-value "xprint to nil" "cannot print to nil" (xprint nil "x"))
(assert-error-value "xprintf to nil" "cannot print to nil" (xprintf nil "%s" "x"))

# An abstract that is not a file is silently ignored rather than refused
(assert (nil? (xprint (math/rng) "ignored")) "xprint to a non-file abstract")
(assert (nil? (xprintf (math/rng) "%s" "ignored")) "xprintf to a non-file abstract")

# Values are converted the way `describe` converts them, and a buffer argument
# is written out rather than described
(assert (= "raw1x\n" (collected |(xprint sink @"raw" 1 :x))) "xprint converts")
(assert (= "raw\n" (collected |(with-dyns [:out sink] (print @"raw")))) "print writes a buffer argument")

# Flushing a binding that is not a file does nothing at all
(assert (nil? (with-dyns [:out sink] (flush))) "flush a buffer binding")
(assert (nil? (with-dyns [:err 3] (eflush))) "eflush a non-file binding")
(assert (nil? (with-dyns [:out stdout] (flush))) "flush a file binding")

# The file methods, and the order `next` walks them in
(def tmp (file/temp))
(assert (= tmp (:write tmp "method\n")) "method :write returns the file")
(assert (= tmp (:flush tmp)) "method :flush returns the file")
(assert (= 7 (:tell tmp)) "method :tell")
(assert (= tmp (:seek tmp :set 0)) "method :seek returns the file")
(assert (= "method\n" (string (:read tmp :all))) "method :read")
(assert (deep= @[:close :flush :read :seek :tell :write] (keys tmp))
        "file methods are walked in table order")
(assert (nil? (:close tmp)) "method :close")

# What each failure says
(def tmp2 (file/temp))
(assert-error-value "seek keyword" "expected one of :cur, :set, :end, got :middle"
                    (file/seek tmp2 :middle 0))
(assert-error-value "read keyword" "expected one of :all, :line, got :some"
                    (file/read tmp2 :some))
(assert-error-value "negative read" "expected positive integer" (file/read tmp2 -1))
(file/close tmp2)
(assert-error-value "closed read" "file is closed" (file/read tmp2 :all))
(assert-error-value "closed write" "file is closed" (file/write tmp2 "x"))
(assert-error-value "closed seek" "file is closed" (file/seek tmp2 :set 0))
(assert-error-value "closed tell" "file is closed" (file/tell tmp2))
(assert-error-value "closed flush" "file is closed" (file/flush tmp2))
(assert (nil? (file/close tmp2)) "closing twice is nil")

# stdin is not writeable, and stdout is not closeable
(assert-error-value "stdin write" "file is not writeable" (file/write stdin "x"))
(assert-error-value "stdin flush" "file is not writeable" (file/flush stdin))
(assert-error-value "stdout close" "file not closable" (file/close stdout))
(assert (= :core/file (type stdout)) "stdout is a file")
(assert (= :core/file (type stderr)) "stderr is a file")
(assert (= :core/file (type stdin)) "stdin is a file")

# A file in safe mode marshals no better from Janet than from C
(assert-error-value "marshal a file" "cannot marshal file in safe mode" (marshal stdout))

# A read-only file is not writeable and a write-only file is not readable
(def path "janet-suite-io-11")
(defer (os/rm path)
  (spit path "seed")
  (with [f (file/open path :r)]
    (assert-error-value "read mode write" "file is not writeable" (file/write f "x"))
    (assert (= "seed" (string (file/read f :all))) "read mode read"))
  (with [f (file/open path :w)]
    (assert-error-value "write mode read" "file is not readable" (file/read f :all)))
  (assert-error-value "open a directory" "cannot open directory: ." (file/open "." :r))
  (assert (nil? (file/open "janet-suite-io-11-absent" :r)) "a missing file is nil")
  (assert-error "missing file with :n" (file/open "janet-suite-io-11-absent" :rn)))

# Printing to a file takes the other branch of the same conversion: a buffer
# argument is written raw and everything else goes through `describe`
(defer (os/rm path)
  (with [f (file/open path :w)]
    (xprint f @"raw" 1 :x)
    (xprinf f "%d" 5)
    (xprintf f "%s" "fmt"))
  (assert (= "raw1x\n5fmt\n" (string (slurp path))) "xprint and xprintf to a file")
  (with [f (file/open path :r)]
    (assert-error-value "xprint to a read-only file" "file is not writeable" (xprint f "x"))
    (assert-error-value "xprintf to a read-only file" "file is not writeable" (xprintf f "%s" "x"))))

# A closed file reports itself differently to the two families, which is what
# the C original did and is pinned here rather than smoothed over
(def closed (file/temp))
(file/close closed)
(assert-error-value "xprint to a closed file" "file is closed" (xprint closed "x"))
(assert-error-value "xprintf to a closed file" "cannot print to closed file"
                    (xprintf closed "%s" "x"))

# A zero-length read is not an error, and neither is a zero-byte write
(def tmp3 (file/temp))
(file/write tmp3 "abc")
(file/seek tmp3 :set 0)
(assert (nil? (file/read tmp3 0)) "reading zero bytes is nil")
(assert (= "abc" (string (file/read tmp3 :all))) "reading zero bytes consumed nothing")
(assert (= tmp3 (file/write tmp3 "")) "writing zero bytes")
(file/close tmp3)

# Every argument is checked before any of them is written, so a bad one leaves
# the file untouched rather than half-written
(def tmp4 (file/temp))
(assert-error "write checks every argument" (file/write tmp4 "kept" 3))
(file/seek tmp4 :set 0)
(assert (= "" (string (file/read tmp4 :all))) "a rejected write wrote nothing")
(file/close tmp4)

# `(flush)` really flushes the file its binding names
(def flushed "janet-suite-io-11-flush")
(defer (os/rm flushed)
  (with [f (file/open flushed :w)]
    (file/write f "buffered")
    (assert (= "" (string (slurp flushed))) "a buffered write is not on disk yet")
    (with-dyns [:out f] (flush))
    (assert (= "buffered" (string (slurp flushed))) "flush flushes the bound file")))

# An explicit buffer size is applied, and a size the C library cannot allocate
# is reported rather than ignored. The mode beside it is honoured: a buffer
# size is a third argument, not a replacement for the second.
(def buffered "janet-suite-io-11-buffered")
(defer (os/rm buffered)
  (spit buffered "sized")
  (each n [0 1 8192]
    (with [f (file/open buffered :r n)]
      (assert (= "sized" (string (file/read f :all))) (string "buffer size " n))))
  (with [f (file/open buffered :w 8192)]
    (file/write f "written"))
  (assert (= "written" (string (slurp buffered))) "a buffer size keeps the write mode")
  (assert-error-value "a mode is scanned beside a buffer size"
                      "invalid flag z, expected w, a, or r"
                      (file/open buffered :zzz 8192))
  # A size the allocator refuses, which needs a `setvbuf` that allocates. The
  # musl stdio wasi-libc is built from records the size and allocates nothing,
  # so no size is refused there and this has no instrument on `:wasm`. The
  # size is also the pointer width, and 2^53-1 is not a size on a 32-bit
  # build at all.
  (when (not= :wasm (os/arch))
    (assert-error-value "unallocatable buffer size" "failed to set buffer size for file"
                        (file/open buffered :r (- (math/pow 2 53) 1)))))

# The whole length message, not a prefix of it
(assert-error-value "empty mode" "file mode must have a length between 1 and 10"
                    (file/open "janet-suite-io-11-absent" (keyword "")))
(assert-error-value "eleven-byte mode" "file mode must have a length between 1 and 10"
                    (file/open "janet-suite-io-11-absent" :rbnbnbnbnbn))

# A file this runtime will close does not survive an exec.
#
# `compwhen` rather than `when`: a `-Dprocesses=false` build has no `os/spawn`
# to *compile* against, and a runtime guard does not stop the compiler
# resolving the symbol inside its body. Exactly the shape of the `peg/find`
# guard in `test/suite-debug.janet`, and found the same way: by a matrix entry
# running `zig build test -Dprocesses=false`.
(compwhen (dyn 'os/spawn)
 (when (os/stat "/dev/fd")
  (defn open-fds []
    (def p (os/spawn [(dyn *executable*) "-e" `(print (length (os/dir "/dev/fd")))`]
                     :p {:out :pipe}))
    (def n (scan-number (string/trim (string (:read (p :out) :all)))))
    (os/proc-wait p)
    n)
  (def held "janet-suite-io-11-cloexec")
  (defer (os/rm held)
    (spit held "x")
    (def before (open-fds))
    (with [f (file/open held :r)]
      (assert (= before (open-fds)) "an opened file is closed on exec")))))

# A stream from os/open is closed on exec as a file is. The child writes its
# count to a file rather than a pipe, and a child that overruns is killed
# with a signal it cannot ignore. The process keeps a stream of its own for
# each file it was given, and those are closed before the next count.
(compwhen (and (dyn 'os/spawn) (dyn 'os/open))
 (when (os/stat "/dev/fd")
  (def count-path "/tmp/janet-suite-io-fds")
  (def held-path "/tmp/janet-suite-io-held")
  (defn fds-in-child []
    (with [out (file/open count-path :w)]
      (with [null (file/open "/dev/null" :w)]
        (def p (os/spawn [(dyn *executable*) "-e" `(print (length (os/dir "/dev/fd")))`]
                         :p {:out out :err null}))
        (unless (first (protect (ev/with-deadline 5 (os/proc-wait p))))
          (os/proc-kill p false :kill))
        (:close (p :out))
        (:close (p :err))))
    (scan-number (string/trim (string (slurp count-path)))))
  (defer (do (protect (os/rm count-path)) (protect (os/rm held-path)))
    (spit held-path "x")
    (def before (fds-in-child))
    (def stream (os/open held-path :r))
    (def during (fds-in-child))
    (:close stream)
    (assert (= before during) "a stream from os/open is closed on exec"))))

(end-suite)

