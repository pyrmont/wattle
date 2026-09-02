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

(assert true)

# File watching can be disabled on its own, and it is also built on the event
# loop, so this suite needs both. An absent binding is a compile error rather
# than a runtime one, and Janet compiles and runs a file one top-level form at
# a time, so leaving here keeps the rest of the suite from reaching the
# compiler at all.
(compwhen (or (not (dyn 'ev/chan)) (not (dyn 'filewatch/new)))
  (end-suite)
  (os/exit 0))

(def chan (ev/chan 1000))
(var is-win (or (= :mingw (os/which)) (= :windows (os/which))))
(var is-linux (= :linux (os/which)))
(def bsds [:freebsd :macos :openbsd :bsd :dragonfly :netbsd])
(var is-kqueue (index-of (os/which) bsds))

# If not supported, exit early
(def [supported msg] (protect (filewatch/new chan)))
(when (and (not supported) (string/find "filewatch not supported" msg))
  (end-suite)
  (quit))

# Test GC
(assert-no-error "filewatch/new" (filewatch/new chan))
(gccollect)

#
# The surface: arities, argument types, flag decoding and the watcher's own
# life cycle. Without this the suite goes straight from `(assert true)` to
# driving real events, leaving every failure message in the file untested.
#

(defn- errmsg
  "The message a form raises, or nil if it does not raise."
  [f]
  (def [ok result] (protect (f)))
  (if ok nil result))

(assert (= "arity mismatch, expected at least 1, got 0" (errmsg |(filewatch/new)))
        "filewatch/new arity")
(assert (= "bad slot #0, expected core/channel, got 7" (errmsg |(filewatch/new 7)))
        "filewatch/new wants a channel")
(assert (= "arity mismatch, expected at least 2, got 1" (errmsg |(filewatch/add 1)))
        "filewatch/add arity")
(assert (= "arity mismatch, expected 2, got 1" (errmsg |(filewatch/remove 1)))
        "filewatch/remove arity")
(assert (= "arity mismatch, expected 1, got 2" (errmsg |(filewatch/listen 1 2)))
        "filewatch/listen arity")
(assert (= "arity mismatch, expected 1, got 0" (errmsg |(filewatch/unlisten)))
        "filewatch/unlisten arity")
(assert (string/has-prefix? "bad slot #0, expected filewatch/watcher, got "
                            (errmsg |(filewatch/listen chan)))
        "filewatch/listen wants a watcher")

# A flag that is not a keyword is refused before any vocabulary is consulted,
# so this message is the same on every backend.
(assert (= "expected keyword, got \"all\"" (errmsg |(filewatch/new chan "all")))
        "a flag must be a keyword")
(assert (= "expected keyword, got 3" (errmsg |(filewatch/new chan 3)))
        "a number is not a flag")

# An unknown one names the backend, and that word is the only part of the
# message that differs between them.
(def backend-word (cond is-win "windows filewatch" is-linux "linux" "bsd"))
(assert (= (string "unknown " backend-word " flag :not-a-flag")
           (errmsg |(filewatch/new chan :not-a-flag)))
        "an unknown flag names the backend")
(assert (= (string "unknown " backend-word " flag :not-a-flag")
           (errmsg |(filewatch/new chan :all :not-a-flag)))
        "the decoder reports the flag that failed, not the first one")

# `:all` is the one name every backend has, and it is the union of the rest.
(assert-no-error "every backend has :all" (filewatch/new chan :all))

# A name from another backend's vocabulary is refused here. The three tables
# share only `:all`, which is what makes the split a split.
(def foreign (cond is-win :attrib is-linux :recursive :modify))
(assert (string/has-prefix? "unknown " (errmsg |(filewatch/new chan foreign)))
        "a foreign backend's flag is refused")

# The abstract type is opaque: it has a name and a mark callback and nothing
# else, so it answers to `type` and to nothing that indexes or compares.
(def probe-watcher (filewatch/new chan))
(assert (= :filewatch/watcher (type probe-watcher)) "watcher type name")
(assert (nil? (get probe-watcher :stream)) "a watcher has no fields to index")
(assert (nil? (next probe-watcher)) "a watcher has no keys to walk")
(assert (string/has-prefix? "<filewatch/watcher " (string probe-watcher))
        "a watcher prints as its type and address")

# The life cycle, on a directory of its own. `filewatch/add` answers with the
# watcher rather than with a descriptor, which is what lets the calls thread.
(def probe-dir (randdir))
(rmrf probe-dir)
(os/mkdir probe-dir)
(assert (= probe-watcher (filewatch/add probe-watcher probe-dir :all))
        "filewatch/add returns the watcher")
(assert-error "a path that cannot be opened is refused"
              (filewatch/add probe-watcher (string probe-dir "/no-such-entry") :all))
(assert-error "a path that was never added cannot be removed"
              (filewatch/remove probe-watcher (string probe-dir "/never-added")))
(assert (= probe-watcher (filewatch/remove probe-watcher probe-dir))
        "filewatch/remove returns the watcher")

# Listening twice is refused; unlistening twice is not.
(filewatch/add probe-watcher probe-dir :all)
(assert-no-error "listen once" (filewatch/listen probe-watcher))
(assert (= "already watching" (errmsg |(filewatch/listen probe-watcher)))
        "listening twice is refused")
(assert-no-error "unlisten once" (filewatch/unlisten probe-watcher))
(assert-no-error "unlisten twice" (filewatch/unlisten probe-watcher))

# And the watcher is closed after that: `filewatch/unlisten` closes the
# watcher's own descriptor and nothing reopens it. All three calls say so, and
# the one that matters is `listen` -- without the refusal it reported success,
# started a fiber on a closed stream, delivered nothing ever after, and kept
# the event loop from finishing.
(when (not is-win)
  (assert (= "watcher is closed" (errmsg |(filewatch/add probe-watcher probe-dir :all)))
          "a closed watcher cannot be added to")
  (assert (= "watcher is closed" (errmsg |(filewatch/listen probe-watcher)))
          "a closed watcher cannot listen")
  (assert (= "watcher is closed" (errmsg |(filewatch/remove probe-watcher probe-dir)))
          "a closed watcher cannot be removed from"))

# The descriptors a kqueue watcher opens are its own, and it closes them: one
# per `filewatch/add`, returned on unlisten and at collection. On Linux and
# Windows there are none to count, so the assertion is about the platform that
# has them.
(when (and (not is-win) (= :macos (os/which)))
  (defn- nfds [] (length (os/dir "/dev/fd")))
  (def fd-dir "janet-suite-filewatch-fds")
  (os/mkdir fd-dir)
  (defer (rmrf fd-dir)
    (gccollect)
    (def before (nfds))
    # No binding for the watcher: a `def` in the loop body leaves the last
    # one reachable, and one uncollected watcher is two descriptors -- its own
    # kqueue and the path it watched.
    (loop [_ :range [0 20]]
      (filewatch/add (filewatch/new (ev/chan 4)) fd-dir :all))
    (gccollect)
    # The bound is `before + 2` rather than `before`: the loop's last watcher
    # can still be reachable from an interpreter stack slot, and one watcher is
    # two descriptors -- its own kqueue and the one path it watched. What this
    # rules out is the leak, which is proportional: twenty watchers that never
    # close what they opened are forty descriptors.
    (assert (<= (nfds) (+ before 2))
            "a collected watcher returns the descriptors it opened")))
(gccollect)
(rmrf probe-dir)

(defn- expect
  [key value & more-kvs]
  (ev/with-deadline
    1
    (def event (ev/take chan))
    (when is-verbose (pp event))
    (assert event "check event")
    (assert (= value (get event key)) (string/format "got %p, expected %p" (get event key) value))
    (when (next more-kvs)
      (each [k v] (partition 2 more-kvs)
        (assert (= v (get event k)) (string/format "got %p, expected %p" (get event k) v))))))

(defn- expect-empty
  []
  (assert (zero? (ev/count chan)) "channel check empty")
  (ev/sleep 0) # turn the event loop
  (assert (zero? (ev/count chan)) "channel check empty")
  # Drain if not empty, help with failures after this
  (while (pos? (ev/count chan)) (printf "extra: %p" (ev/take chan))))

(defn- expect-maybe
  "On wine + mingw, we get an extra event. This is a wine peculiarity."
  [key value]
  (ev/with-deadline
    1
    (ev/sleep 0)
    (when (pos? (ev/count chan))
      (def event (ev/take chan))
      (when is-verbose (pp event))
      (assert event "check event")
      (assert (= value (get event key)) (string/format "got %p, expected %p" (get event key) value)))))

(defn spit-file
  [dir name]
  (def path (string dir "/" name))
  (spit path "test text"))

# Different operating systems report events differently. While it would be nice to
# normalize this, each system has very large limitations in what can be reported when
# compared with other systems. As such, the maximum subset of common functionality here
# is quite small. Instead, test the capabilities of each system.

# Create a file watcher on two test directories
(def fw (filewatch/new chan))
(def td1 (randdir))
(def td2 (randdir))
(def td3 (randdir))
(rmrf td1)
(rmrf td2)
(os/mkdir td1)
(os/mkdir td2)
(os/mkdir td3)
(spit-file td3 "file3.txt")
(when is-win
  (filewatch/add fw td1 :last-write :last-access :file-name :dir-name :size :attributes :recursive)
  (filewatch/add fw td2 :last-write :last-access :file-name :dir-name :size :attributes))
(when is-linux
  (filewatch/add fw (string td3 "/file3.txt") :close-write :create :delete)
  (filewatch/add fw td1 :close-write :create :delete)
  (filewatch/add fw td2 :close-write :create :delete :ignored))
(when is-kqueue
  (filewatch/add fw (string td3 "/file3.txt") :all)
  (filewatch/add fw td1 :all)
  (filewatch/add fw td2 :all))
(assert-no-error "filewatch/listen no error" (filewatch/listen fw))

#
# Windows file writing
#

(when is-win
  (spit-file td1 "file1.txt")
  (expect :type :added :file-name "file1.txt" :dir-name td1)
  (expect :type :modified)
  (expect-maybe :type :modified) # for mingw + wine
  (gccollect)
  (spit-file td1 "file1.txt")
  (expect :type :modified)
  (expect :type :modified)
  (expect-empty)
  (gccollect)

  # Check td2
  (spit-file td2 "file2.txt")
  (expect :type :added)
  (expect :type :modified)
  (expect-maybe :type :modified)

  # Remove a file, then wait for remove event
  (rmrf (string td1 "/file1.txt"))
  (expect :type :removed)
  (expect-empty)

  # Unlisten to some events
  (filewatch/remove fw td2)

  # Check that we don't get anymore events from test directory 2
  (spit-file td2 "file2.txt")
  (expect-empty)

  # Repeat and things should still work with test directory 1
  (spit-file td1 "file1.txt")
  (expect :type :added)
  (expect :type :modified)
  (expect-maybe :type :modified)
  (gccollect)
  (spit-file td1 "file1.txt")
  (expect :type :modified)
  (expect :type :modified)
  (expect-maybe :type :modified)
  (gccollect))

#
# Linux file writing
#

(when is-linux
  (spit-file td1 "file1.txt")
  (expect :type :create :file-name "file1.txt" :dir-name td1)
  (expect :type :close-write)
  (expect-empty)
  (gccollect)
  (spit-file td1 "file1.txt")
  (expect :type :close-write)
  (expect-empty)
  (gccollect)

  # Check file3.txt
  (spit-file td3 "file3.txt")
  (expect :type :close-write :file-name "file3.txt" :dir-name td3)
  (expect-empty)

  # Check td2
  (spit-file td2 "file2.txt")
  (expect :type :create)
  (expect :type :close-write)
  (expect-empty)

  # Remove a file, then wait for remove event
  (rmrf (string td1 "/file1.txt"))
  (expect :type :delete)
  (expect-empty)

  # Unlisten to some events
  (filewatch/remove fw td2)
  (expect :type :ignored)
  (expect-empty)

  # Check that we don't get anymore events from test directory 2
  (spit-file td2 "file2.txt")
  (expect-empty)

  # Repeat and things should still work with test directory 1
  (spit-file td1 "file1.txt")
  (expect :type :create)
  (expect :type :close-write)
  (expect-empty)
  (gccollect)
  (spit-file td1 "file1.txt")
  (expect :type :close-write)
  (expect-empty)
  (gccollect))

#
# Macos and BSD file writing
#

# TODO - kqueue capabilities here are a bit more limited than inotify and windows by default.
# This could be ammended with some heavier-weight functionality in userspace, though.
(when is-kqueue
  (spit-file td1 "file1.txt")
  (expect :wd-path td1 :type :write)
  (expect-empty)
  (gccollect)
  (spit-file td1 "file1.txt")
  # Currently, only operations that modify the parent vnode do anything
  (expect-empty)
  (gccollect)
  # Check that we don't get anymore events from test directory 2
  (spit-file td2 "file2.txt")
  (expect :wd-path td2 :type :write)
  (expect-empty)
  # Remove a file, then wait for remove event
  (rmrf (string td1 "/file1.txt"))
  (expect :type :write) # a "write" to the vnode
  (expect-empty))

(assert-no-error "filewatch/unlisten no error" (filewatch/unlisten fw))
(assert-no-error "cleanup 1" (rmrf td1))
(assert-no-error "cleanup 2" (rmrf td2))
(assert-no-error "cleanup 3" (rmrf td3))

(end-suite)
