# The event loop's worked example, loaded and exercised.
#
# `zig build test` runs this with the built module's path as its argument,
# which is what makes "a module can schedule work through the loop" a check
# rather than a claim.

(def module-path (get (dyn *args*) 1))

# **An ordinary import, which is how a user reaches a native module.** The path
# is an argument only because `zig build` puts the shared object in its cache
# rather than on `JANET_PATH`; everything after this line is what someone who
# had installed the module would write.
(import* module-path :prefix "digest/")

(defn- refusal
  "The message a call refuses with, or nil if it did not refuse."
  [f & args]
  (def [ok result] (protect (f ;args)))
  (unless ok result))

# **A build with no event loop refuses at `loop()`**, which is the first thing
# the cfunction calls, so the whole of this module is one refusal there and
# nothing below it applies.
(def has-ev (not (nil? (root-env 'ev/go))))

(unless has-ev
  (assert (= "event loop not enabled" (refusal digest/sha256 "abc"))
          "a build without the loop refuses at loop()")
  (print "digest example ok (no event loop)")
  (os/exit 0))

# ------------------------------------------------------------ the answer
#
# The known vectors, so that "it hashes on a thread" is a claim about *where*
# the work happened and not about whether it was done right.

(assert (= "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
           (first (ev/gather (digest/sha256 "abc"))))
        "the SHA-256 of \"abc\"")
(assert (= "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
           (first (ev/gather (digest/sha256 ""))))
        "and of the empty string")
(assert (= (first (ev/gather (digest/sha256 "abc")))
           (first (ev/gather (digest/sha256 @"abc"))))
        "a buffer and a string hash the same, because the view is the same view")

# A wrong argument type is refused by the getter, before any thread starts.
(assert (= "bad slot #0, expected string, symbol, keyword or buffer, got 3"
           (refusal digest/sha256 3))
        "getBytes names the four types it takes")

# --------------------------------------------- it does not block the loop
#
# **This is what the example is for**, and it is the one property the fixture
# in `test/zig-native.janet` cannot show on its own: the loop keeps turning
# while a hash is in flight.

(def big (string/repeat "0123456789abcdef" 524288))   # 8 MiB

# A fiber doing something else keeps running while a hash is in flight, which
# is the same property from the other side and needs no clock to see.
(var ticks 0)
(def [hashed ticked]
  (ev/gather (digest/sha256 big)
             (do (repeat 200 (++ ticks) (ev/sleep 0)) :ticked)))
(assert (= 64 (length hashed)) "the hash answered")
(assert (= :ticked ticked) "and the other fiber finished")
(assert (= 200 ticks) "having run two hundred times underneath it")

# ----------------------------------------------------------- cancellation
#
# `ev/cancel` between the `await` and the wake. The fiber answers the
# cancellation; the wake that arrives afterwards finds a fiber it cannot resume
# and answers false, which is the branch the module unroots its job on.
# Nothing here can observe that unroot -- `test/zig-native.janet` is where the
# false branch is counted -- and this is the same code path in a module someone
# would write.
#
# The ordering is the hash's own length rather than a sleep's: `ev/sleep 0`
# gives the loop one turn, which is enough to start the thread and suspend, and
# the cancel then reaches the loop long before eight megabytes are hashed.
(def gone (ev/chan))
(def victim (ev/go (fiber/new (fn [] (digest/sha256 big)) :ti) nil gone))
(ev/sleep 0)
(ev/cancel victim "cancelled mid-hash")
(def [sig fib] (ev/take gone))
(assert (= :error sig) "a cancelled hash ends in an error")
(assert (= "cancelled mid-hash" (fiber/last-value fib)) "carrying ev/cancel's own value")

# The loop is still healthy afterwards, which is what says the refused wake
# left nothing behind.
(assert (= "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
           (first (ev/gather (digest/sha256 "abc"))))
        "and the next hash still works")

# ------------------------------------------------------- exit mid-hash
#
# `os/exit` tears the runtime down while a hash is in flight. Teardown runs
# the `digest/hash` finalizer, which joins the thread, before it releases the
# loop, so the thread's `janet.post` lands in a loop that is still there. The
# run is a child process because the exit is the thing under test.
#
# The hash is 64 MiB so that it is still running when `os/exit` is reached:
# `ev/sleep 0` gives the loop one turn, which starts the thread and suspends.
#
# **What this pins is that the join finishes**: teardown with a hash in flight
# neither hangs nor crashes. An exit code cannot show that the join happened.
# A detached thread also exits 0 here, because `exit` ends the process before
# the thread posts; the join shows only as the exit waiting for the hash.
#
# **A reduced-OS build has no `os/execute`**, and this is looked up rather
# than named for the reason the `os/clock` guard below gives.

(def execute (get-in root-env ['os/execute :value]))
(when execute
  (def child
    (string/format
      ``(import* %j :prefix "digest/")
        (ev/go (fn [] (digest/sha256 (string/repeat "0123456789abcdef" 4194304))))
        (ev/sleep 0)
        (os/exit 0)``
      module-path))
  (assert (= 0 (execute [(dyn *executable*) "-e" child] :p))
          "exiting while a hash is in flight exits cleanly"))

# ------------------------------------------------- the hashes overlap
#
# The same property with a clock on it: four hashes at once cost about one.
#
# **A reduced-OS build has no `os/clock`**, and this exits before the forms
# that name it for the reason the event-loop guard above exits: Janet compiles
# one top-level form at a time, so a form after this one is never compiled and
# an absent binding is not an unknown symbol there.

(unless (root-env 'os/clock)
  (print "digest example ok (no os/clock; the overlap timing is skipped)")
  (os/exit 0))

(defn- timed [f]
  (def start (os/clock :monotonic))
  (f)
  (- (os/clock :monotonic) start))

# The reference: four hashes one after another, each through its own
# `ev/gather`, best of three so a scheduling hiccup does not become the
# baseline. Each hash pays the same spawn and gather cost as in the concurrent
# run below, so the two differ only in whether the hashes overlap.
#
# The reference was one hash, with four concurrent hashes bound under 2.5
# times it. In ReleaseFast on a three-core `macos-latest` runner that measured
# one 0.004 s and four 0.011 s: with a 4 ms hash, the per-task overhead is a
# large share of `four`, and a bound relative to one hash does not allow for
# it.
(def serial
  (min ;(map (fn [_] (timed (fn [] (repeat 4 (ev/gather (digest/sha256 big))))))
             (range 3))))

# Four at once. Serialised they cost what `serial` does; overlapped on two
# cores or more they cost about half of it or less. The bound is 0.9 of
# `serial` rather than a half, because what is being asserted is that they
# overlap at all, not by how much, and a busy machine must not turn that into
# a failure. On the three-core runner above, four was 0.011 s against four
# times a 0.004 s hash, about 0.7. Best of three, as `serial` is, so that noise
# on either side does not decide the comparison.
(def four
  (min ;(map (fn [_] (timed (fn [] (ev/gather (digest/sha256 big) (digest/sha256 big)
                                              (digest/sha256 big) (digest/sha256 big)))))
             (range 3))))
#
# **The default of 2 is doing work.** `os/cpu-count` answers its default rather
# than a number wherever the platform has no arm in it -- macOS is one, as it
# is upstream -- and skipping the assertion there would leave it unexercised on
# the machine most likely to run it. Two is what to assume when the count is
# unknown; a machine that *reports* one core skips this, which is the only case
# where four hashes really do cost four.
(when (>= (os/cpu-count 2) 2)
  (assert (< four (* 0.9 serial))
          (string/format "four hashes overlap rather than serialise (serial %.3fs, four %.3fs)"
                         serial four)))

(print "digest example ok")
