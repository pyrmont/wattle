# digest

A native Janet module written in Zig, and the worked example of **scheduling
work through the event loop** — `DESIGN.md` section 15's last section.

`examples/numarray` is the example of a module that *owns* something and
`examples/url` of one that only reads. This one does neither: it does **work**,
on a thread of its own, and hands the answer back through the loop. That is the
shape of every module that wraps a library with its own threads, its own poll
or its own sockets.

`digest.zig` is the whole module, and it has one cfunction:

```janet
(import digest)

(digest/sha256 "abc")
# -> "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
```

    zig build test

builds it and runs `test/digest.janet` against it. That file is an ordinary
`import*` of the built shared object — the path is an argument only because
`zig build` leaves the object in its cache rather than on `JANET_PATH`, and
everything after the import is what someone who had installed the module would
write.

## What it shows

**Everything the loop does is one sentence: when something happens, resume a
fiber with a value.** A module brings its own source of "something happens" and
needs three operations to take part.

| operation | what it does | where it may be called |
| --- | --- | --- |
| `await()` | suspends the fiber this cfunction is running on | a cfunction |
| `post(loop, cb, ctx)` | asks the loop thread to run `cb(wake, ctx)` | **any thread**, including one with no VM |
| `wake(w, fiber, value)` | puts the fiber back on the run queue | inside a posted callback |

`loop()` and `rootFiber()` are what a cfunction reads before it suspends.

**The thread discipline is in the types.** `Loop` and `Wake` are both
`opaque {}` and both are the same pointer underneath, and they are two types on
purpose: a worker thread holds a `Loop` and `post` is the only thing that takes
one, so resuming a fiber from a thread with no VM is unspellable rather than
merely discouraged. `Wake` arrives as the posted callback's first parameter and
is good for that call.

**The order in the cfunction is the contract.**

```zig
const bytes = try janet.getBytes(argv, 0);   // read
const l = try janet.loop();                  // the loop, carried to the thread
const fiber = try janet.rootFiber();         // the fiber, carried to the callback
janet.gcroot(fiber);                         // protect both across the wait
janet.gcroot(argv[0]);
_ = try std.Thread.spawn(...);               // start the work
return janet.await();                        // then suspend
```

**Starting the thread before the suspend is not a race.** The loop is
single-threaded, so an event the worker posts before the cfunction has returned
is not processed until the fiber has suspended. There is no window and nothing
to synchronise.

**The worker thread touches nothing in `janet.*` but `post`.** Every other
function on the surface finds the VM through a thread-local a worker thread
does not have, and calling one from such a thread aborts with `called from a
thread that is not running Janet` rather than reading null state. `post` is
safe because it takes the loop as an argument: it reads no thread-local,
allocates nothing, and writes one fixed-size event into the loop's self-pipe.

**Rooting is the module's, and the wait is a re-entry like any other.** The
fiber and the argument are both `Value`s the module holds across a span in
which Janet code runs, so both are `gcroot`ed before `await` and `gcunroot`ed
in the callback. The slice the thread hashes points at the string's own
storage, and the root is what keeps that storage there.

**A `false` from `wake` is a state to clean up after, not a failure to
report.** `ev/cancel` may have moved the fiber on, or it may have finished; the
runtime would have dropped the resume. The context is the module's either way,
which is why the callback unroots and frees on both branches. A module that
cleaned up only under the `true` branch would leak exactly the cancelled case —
and `test/digest.janet` cancels a hash in flight for that reason.

**The callback is short and cannot raise.** It runs on the loop thread between
two fibers; its job is to build the value and wake, not to do work. Building a
`Value` inside it is allowed — allocating through the collector is fatal on
failure rather than a raise, and no safe point runs between fibers there.

**How long a view stays valid is still the getter's rule.** A string's, a
symbol's and a keyword's bytes are stable while the value is reachable, which
is what the root buys. A *buffer's* are `data[0..count]`, and a push from
another fiber may move them, so hashing a buffer that another fiber can write
to while this one waits is the caller's to avoid. That is the same rule
`examples/url` states, met at the point where the wait makes it bite.

## What the test asserts

- the digest of two known inputs, and that a buffer and a string hash alike;
- that four hashes under `ev/gather` **overlap rather than serialise**, timed
  generously, which is what says the loop is not blocked;
- that a fiber doing something else runs two hundred times underneath a hash;
- that a hash cancelled with `ev/cancel` answers the cancellation, and that the
  loop is healthy afterwards.

`test/zig-native.janet` is where `wake`'s `false` branch is *counted*; nothing
a Janet program can see says a module freed its own memory.

## What is deliberately not offered

The runtime's thread pool, its timers, its streams and async listeners, and its
channels. A module brings its own thread and posts, which is what a C library
with a loop of its own already does. `DESIGN.md` section 15 says why each
waits.

## Building one outside this repository

The same way `numarray` does, and `examples/numarray/README.md` has the
`build.zig.zon` and `build.zig` an outside package needs. `zig build standalone`
is the proof that it works.
