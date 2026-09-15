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

(def janet (dyn :executable))
(def run (filter next (string/split " " (os/getenv "SUBRUN" ""))))

# OS Date test
# 719f7ba0c
(assert (deep= {:year-day 0
                :minutes 30
                :month 0
                :dst false
                :seconds 0
                :year 2014
                :month-day 0
                :hours 20
                :week-day 3}
               (os/date 1388608200)) "os/date")

# OS mktime test
# 3ee43c3ab
(assert (= 1388608200 (os/mktime {:year-day 0
                                  :minutes 30
                                  :month 0
                                  :dst false
                                  :seconds 0
                                  :year 2014
                                  :month-day 0
                                  :hours 20
                                  :week-day 3})) "os/mktime")

(def now (os/time))
(assert (= (os/mktime (os/date now)) now) "UTC os/mktime")
(assert (= (os/mktime (os/date now true) true) now) "local os/mktime")
(assert (= (os/mktime {:year 1970}) 0) "os/mktime default values")

# OS strftime test
# 5cd729c4c
(assert (= (os/strftime "%Y-%m-%d %H:%M:%S" 0) "1970-01-01 00:00:00")
        "strftime UTC epoch")
(assert (= (os/strftime "%Y-%m-%d %H:%M:%S" 1388608200)
           "2014-01-01 20:30:00")
        "strftime january 2014")
(assert (= (try (os/strftime "%%%d%t") ([err] err))
           "invalid conversion specifier '%t'")
        "invalid conversion specifier 1")
(assert (= (try (os/strftime "%H:%M:%") ([err] err))
           "invalid conversion specifier")
        "invalid conversion specifier 2")

# 07db4c530
(os/setenv "TESTENV1" "v1")
(os/setenv "TESTENV2" "v2")
(assert (= (os/getenv "TESTENV1") "v1") "getenv works")
(def environ (os/environ))
(assert (= [(environ "TESTENV1") (environ "TESTENV2")] ["v1" "v2"])
        "environ works")

# Ensure randomness puts n of pred into our buffer eventually
# 0ac5b243c
(defn cryptorand-check
  [n pred]
  (def max-attempts 10000)
  (var attempts 0)
  (while (not= attempts max-attempts)
    (def cryptobuf (os/cryptorand 10))
    (when (= n (count pred cryptobuf))
      (break))
    (++ attempts))
  (not= attempts max-attempts))

# os/cryptorand still exists without JANET_CRYPTORAND, but raises when called,
# so this is a runtime check rather than a compwhen on the binding.
(def has-cryptorand (first (protect (os/cryptorand 1))))

(when has-cryptorand
  (def v (math/rng-int (math/rng (os/time)) 100))
  (assert (cryptorand-check 0 |(= $ v)) "cryptorand skips value sometimes")
  (assert (cryptorand-check 1 |(= $ v)) "cryptorand has value sometimes")

  (def buf (buffer/new-filled 1))
  (os/cryptorand 1 buf)
  (assert (= (in buf 0) 0) "cryptorand doesn't overwrite buffer")
  (assert (= (length buf) 2) "cryptorand appends to buffer")

  # The one Janet path that could reach `buffers.setcount` with a negative
  # count. The check is here now that the parameter is a count.
  (assert-error-value "negative cryptorand" "expected positive integer"
                      (os/cryptorand -1)))

(assert-no-error "realtime clock" (os/clock))
(assert-no-error "realtime clock" (os/clock nil))
(assert-no-error "realtime clock" (os/clock nil nil))

# 80db68210
(assert-no-error "realtime clock" (os/clock :realtime))
(assert-no-error "cputime clock" (os/clock :cputime))
(assert-no-error "monotonic clock" (os/clock :monotonic))

(assert-no-error "realtime clock double output" (os/clock nil :double))
(assert-no-error "realtime clock int output" (os/clock nil :int))
(assert-no-error "realtime clock tuple output" (os/clock nil :tuple))

(assert-error "invalid clock" (os/clock :a))
(assert-error "invalid output" (os/clock :realtime :b))
(assert-error "invalid clock and output" (os/clock :a :b))

(def before (os/clock :monotonic))
(def after (os/clock :monotonic))
(assert (>= after before) "monotonic clock is monotonic")

# Perm strings
# a0d61e45d
(assert (= (os/perm-int "rwxrwxrwx") 8r777) "perm 1")
(assert (= (os/perm-int "rwxr-xr-x") 8r755) "perm 2")
(assert (= (os/perm-int "rw-r--r--") 8r644) "perm 3")

(assert (= (band (os/perm-int "rwxrwxrwx") 8r077) 8r077) "perm 4")
(assert (= (band (os/perm-int "rwxr-xr-x") 8r077) 8r055) "perm 5")
(assert (= (band (os/perm-int "rw-r--r--") 8r077) 8r044) "perm 6")

(assert (= (os/perm-string 8r777) "rwxrwxrwx") "perm 7")
(assert (= (os/perm-string 8r755) "rwxr-xr-x") "perm 8")
(assert (= (os/perm-string 8r644) "rw-r--r--") "perm 9")

# Pipes
# os/pipe is part of the event loop, absent without JANET_EV.
(compwhen (dyn 'os/pipe)
  (assert-no-error (os/pipe))
  (assert-no-error (os/pipe :RW))
  (assert-no-error (os/pipe :R))
  (assert-no-error (os/pipe :W)))

# os/execute is absent from a build without JANET_PROCESSES, and an absent
# binding is a compile error rather than a runtime one.
(compwhen (dyn 'os/execute)
  # os/execute with environment variables
  # issue #636 - 7e2c433ab
  (assert (= 0 (os/execute [;run janet "-e" "(+ 1 2 3)"] :pe
                           (merge (os/environ) {"HELLO" "WORLD"})))
          "os/execute with env")

  # os/execute with empty environment
  # pr #1686
  # native MinGW can't find system DLLs without PATH, SystemRoot, etc. and so fails
  # Also fails for address sanitizer builds on windows.
  (def result (os/execute [;run janet "-e" "(+ 1 2 3)"] :pe {}))
  (assert (or (= result -1073741515) (= result 0))
          "os/execute with minimal env")

  # os/execute regressions
  # 427f7c362
  (for i 0 10
    (assert (= i (os/execute [;run janet "-e"
                              (string/format "(os/exit %d)" i)] :p))
            (string "os/execute " i)))

  # os/open is part of the event loop, absent without JANET_EV.
  (compwhen (dyn 'os/open)
    # os/execute IO redirection
    (assert-no-error "IO redirection"
                     (defn devnull []
                       (def os (os/which))
                       (def path (if (or (= os :mingw) (= os :windows))
                                   "NUL"
                                   "/dev/null"))
                       (os/open path :w))
                     (with [dn (devnull)]
                       (os/execute [;run janet
                                    "-e"
                                    "(print :foo) (eprint :bar)"]
                                   :px
                                   {:out dn :err dn}))))

  # os/open is part of the event loop, absent without JANET_EV.
  (compwhen (dyn 'os/open)
    # os/execute IO redirection with more windows flags
    (assert-no-error "IO redirection more windows flags"
                     (defn devnull []
                       (def os (os/which))
                       (def path (if (or (= os :mingw) (= os :windows))
                                   "NUL"
                                   "/dev/null"))
                       (os/open path (if (= os :windows) :wWI :wW)))
                     (with [dn (devnull)]
                       (os/execute [;run janet
                                    "-e"
                                    "(print :foo) (eprint :bar)"]
                                   :px
                                   {:out dn :err dn})))))

# Issue 16922
(assert-error "os/realpath errors when path does not exist"
              (os/realpath "abc123def456"))

# os/which changes
(assert (os/which (os/which)) "os/which 1 arg")
(assert (not (os/which :gobbledegook)) "os/which 2")

# The process surface as a program sees it. A build without processes has
# none of these bindings, and a missing binding is a compile error.
(compwhen (dyn 'os/spawn)
  (defn child [code &opt flags env]
    (def p (os/spawn [;run janet "-e" code] (or flags :p)
                     (merge {:out :pipe} (or env {}))))
    (def out (string (:read (p :out) :all)))
    [(os/proc-wait p) out])

  # An exit flushes what the child printed, and a forced exit skips the
  # flush, so output still in the buffer is lost.
  (assert (= [0 "x"] (child `(prin "x") (os/exit 0)`)) "an exit flushes stdout")
  (assert (= [0 ""] (child `(prin "x") (os/exit 0 true)`))
          "a forced exit does not flush stdout")

  # Each redirection reaches the descriptor it names and no other. The child
  # reports a descriptor by the inode behind it.
  (when (os/stat "/dev/fd")
    (assert (= [0 "false"]
               (child `(prin (= (os/stat "/dev/fd/1" :inode) (os/stat "/dev/fd/2" :inode)))`))
            "a child given a pipe for stdout keeps its own stderr")
    (def path "/tmp/wattle-suite-os-redirect")
    (def err-path "/tmp/wattle-suite-os-redirect-err")
    (spit path "abc")
    (defer (do (os/rm path) (protect (os/rm err-path)))
      (with [f (file/open path :r)]
        (assert (= [0 (string (os/stat path :inode))]
                   (child `(prin (os/stat "/dev/fd/0" :inode))` :p {:in f}))
                "a file for stdin is descriptor 0"))
      (assert (= [0 (string/format "%j" (os/stat "/dev/fd/0" :inode))]
                 (child `(prinf "%j" (os/stat "/dev/fd/0" :inode))` :p {:in stdin}))
              "stdin given as itself stays open")
      (def own-out (os/stat "/dev/fd/1" :inode))
      (assert (= 0 (os/execute [;run janet "-e"
                                (string/format `(os/exit (if (= %j (os/stat "/dev/fd/1" :inode)) 0 1))`
                                               own-out)]
                               :p {:out stdout}))
              "stdout given as itself stays open")
      (with [f (file/open path :r+)]
        (assert (= 0 (os/execute [;run janet "-e" "nil"] :p {:in f :out f}))
                "one file may be stdin and stdout")
        (assert (= 0 (os/execute [;run janet "-e" "nil"] :p {:in f :err f :out stdout}))
                "one file may be stdin and stderr"))
      (with [f (file/open err-path :w)]
        (os/execute [;run janet "-e" `(eprin "e")`] :p {:err f}))
      (assert (= "e" (string (slurp err-path))) "a file for stderr is descriptor 2")))

  # Only os/spawn makes pipes; os/execute refuses the keyword.
  (assert (= "expected file|stream, got :pipe"
             (in (protect (os/execute [;run janet "-e" "nil"] :p {:in :pipe})) 1))
          "os/execute refuses :pipe")

  # A file given to os/spawn becomes a stream the process keeps, readable or
  # writable as the file was opened.
  (compwhen (dyn 'ev/to-file)
    (with [rf (file/open "/dev/null" :r)]
      (with [wf (file/open "/dev/null" :w)]
        (def p (os/spawn ["/bin/sh" "-c" "exit 0"] :p {:in rf :out wf}))
        (os/proc-wait p)
        (assert (= :core/stream (type (p :in))) "a file for stdin is kept as a stream")
        (assert (= :core/stream (type (p :out))) "and so is a file for stdout")
        (def in-file (ev/to-file (p :in)))
        (def out-file (ev/to-file (p :out)))
        (assert in-file "the stream from a file opened for reading reads")
        (assert out-file "the stream from a file opened for writing writes")
        (when in-file (file/close in-file))
        (when out-file (file/close out-file))
        (:close (p :in))
        (:close (p :out)))))

  # A refused chroot raises: as a user for the privilege, and as root for the
  # path, which does not exist.
  (assert-error "os/posix-chroot is refused"
                (os/posix-chroot "/wattle-suite-os-absent"))

  # A failed exec names the reason the host gave for it.
  (assert (= "/: Permission denied" (in (protect (os/posix-exec ["/"])) 1))
          "os/posix-exec of a directory is refused")

  # A failed spawn names its own reason, and not the last one an earlier call
  # left behind.
  (protect (os/rmdir "/"))
  (assert (string/has-suffix? "No such file or directory"
                              (in (protect (os/spawn ["/wattle-suite-os-absent"])) 1))
          "a failed os/spawn names why it failed")

  # The client starts under whatever environment it is handed. os/spawn gives
  # an empty name as `=x`, and the child reads it back.
  (assert (= [0 "x"] (child `(prin (get (os/environ) ""))` :pe {"" "x"}))
          "a child is started with an empty name in its environment")

  # A process collected without being waited for is killed and reaped, and
  # one spawned with :d is left alone. `kill -0` asks whether a pid is still a
  # process, which a zombie is.
  (defn alive? [pid]
    (= 0 (os/execute ["/bin/sh" "-c" (string "kill -0 " pid " 2>/dev/null")])))
  (with [null (file/open "/dev/null" :w)]
    (defn sleeper [flags]
      ((os/spawn ["/bin/sh" "-c" "exec sleep 10"] flags {:out null :err null}) :pid))
    (def dropped (sleeper :p))
    (def kept (sleeper :pd))
    (gccollect)
    (def dropped-alive (alive? dropped))
    (def kept-alive (alive? kept))
    (each pid [dropped kept]
      (os/execute ["/bin/sh" "-c" (string "kill -9 " pid " 2>/dev/null")]))
    (assert (not dropped-alive) "a collected process is killed and reaped")
    (assert kept-alive "a process spawned with :d is not"))

  # A file given to os/spawn stays open in this process as the process's own
  # stream, and that stream is closed on exec. Three spawns with the same file
  # for stderr, each process kept, see the same number of descriptors. Where
  # the build has the event loop, a child that overruns is killed with a
  # signal it cannot ignore.
  (when (os/stat "/dev/fd")
    (with [null (file/open "/dev/null" :w)]
      (def kept-procs @[])
      (def counts @[])
      (repeat 3
        (def p (os/spawn [;run janet "-e" `(print (length (os/dir "/dev/fd")))`]
                         :p {:out :pipe :err null}))
        (array/push kept-procs p)
        (defn read-count []
          (def n (scan-number (string/trim (string (:read (p :out) :all)))))
          (os/proc-wait p)
          n)
        (def counted
          (protect (compif (dyn 'ev/with-deadline)
                     (ev/with-deadline 5 (read-count))
                     (read-count))))
        (unless (first counted) (os/proc-kill p false :kill))
        (array/push counts (counted 1)))
      (each p kept-procs
        (:close (p :out))
        (:close (p :err)))
      (assert (and (number? (first counts)) (= 1 (length (distinct counts))))
              "a file given to os/spawn does not reach the next child")))

  # The ends of a pipe this process keeps are closed on exec, with or without
  # the event loop. A child whose three streams are pipes, with an os/pipe held
  # here where the build has one, sees as many descriptors as a child whose
  # stdout alone is a pipe.
  (when (os/stat "/dev/fd")
    (defn count-in-child [streams]
      (def p (os/spawn [;run janet "-e" `(print (length (os/dir "/dev/fd")))`] :p streams))
      (def n (string/trim (string (:read (p :out) :all))))
      (os/proc-wait p)
      (each k [:in :out :err] (when (p k) (:close (p k))))
      n)
    (def alone (count-in-child {:out :pipe}))
    (def held (compif (dyn 'os/pipe) (os/pipe) []))
    (def piped (count-in-child {:in :pipe :out :pipe :err :pipe}))
    (each s held (:close s))
    (assert (= alone piped) "the ends of a pipe kept here do not reach the child"))

  # :cd starts the child in the directory it names. The posix_spawn action it
  # needs exists on macOS and glibc, and this runtime refuses :cd elsewhere.
  (compwhen (= :macos (os/which))
    (assert (= 0 (os/execute ["/bin/sh" "-c" `test "$(pwd -P)" = /`] :p {:cd "/"}))
            "a child starts in the directory :cd names")))

# An entry with no `=` cannot come from os/spawn, so posix_spawn is called
# through the FFI with the entries as written. The FFI needs its context
# before the bindings below are compiled, which is why it is a form of its own.
(def has-ffi
  (compif (dyn 'ffi/native)
    (truthy? (first (protect (ffi/context))))
    false))
(compwhen (and has-ffi (not= :windows (os/which)))
  (ffi/defbind posix_spawn :int [pid :ptr path :string actions :ptr attr :ptr argv :ptr envp :ptr])
  (ffi/defbind waitpid :int [pid :int status :ptr options :int])
  (defn strings [xs] (ffi/write (ffi/struct ;(map (fn [_] :string) xs) :ptr) [;xs nil]))
  (def spawn-pid (buffer/new-filled 4 0))
  (def spawn-status (buffer/new-filled 4 0))
  (def spawned
    (posix_spawn spawn-pid janet nil nil
                 (strings [janet "-e" `(os/exit (if (= "1" (os/getenv "A")) 0 1))`])
                 (strings ["=x" "NOEQUALS" "A=1"])))
  (when (= 0 spawned) (waitpid (ffi/read :int spawn-pid) spawn-status 0))
  (assert (and (= 0 spawned) (= 0 (ffi/read :int spawn-status)))
          "a child is started with an empty name and an entry with no ="))

(end-suite)
