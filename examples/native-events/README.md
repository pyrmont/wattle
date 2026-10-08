# native-events

A native Wattle module written in Zig that demonstrates event-loop scheduling.

The module computes a hash on a worker thread and returns the result through the
event loop. An abstract value manages the thread; its `gc` callback joins it.
Modules wrapping libraries with their own threads, polling or sockets use this
pattern. `examples/native-abstract` demonstrates resource management, and
`examples/native-function` demonstrates argument access without resource
management.

`digest.zig` implements the module and defines one nfunction:

```clojure
(import digest)

(digest/sha256 "abc")
; -> "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
```

`zig build test` builds the module and runs
`examples/native-events/test/digest.wattle` against it. The test loads the
shared object with `import*`. Its path is passed as an argument because the
build places it in Zig's cache, outside `WATTLE_PREFIX`. After the import, the
test uses the same calls as an installed module.

## Event-loop interface

Modules provide an event source and use the loop to resume fibers with results.
Three operations support this interaction.

### Operations

| operation | what it does | where it may be called |
| --- | --- | --- |
| `wattle.await()` | suspends the fiber this nfunction is running on | an nfunction |
| `wattle.post(loop, cb, ctx)` | asks the loop thread to run `cb(wake, ctx)` | any thread, including a thread that is not running Wattle |
| `wattle.wake(w, fiber, value)` | puts the fiber back on the run queue | inside a posted callback |

Before suspending, the nfunction calls `wattle.loop()` and `wattle.rootFiber()`
to obtain the loop and fiber.

### Thread restrictions

`Loop` and `Wake` are distinct `opaque {}` types with the same underlying
pointer. Worker threads receive a `Loop`, accepted only by `wattle.post`. They
cannot use it to resume a fiber directly. The posted callback receives `Wake` as
its first parameter, valid only during that call.

### Operation order

The nfunction must perform these operations in order.

```zig
const bytes = try wattle.getBytes(argv, 0); // read
const l = try wattle.loop();                // the loop, passed to the thread
const fiber = try wattle.rootFiber();       // the fiber, passed to the callback
const job = wattle.new(Hash, &hash_type, null); // the job, owning the thread
wattle.gcroot(fiber);                       // protect all three across the wait
wattle.gcroot(argv[0]);
wattle.gcroot(wattle.abstract(job));
job.thread = try std.Thread.spawn(...);    // start the work
return wattle.await();                      // then suspend
```

### Thread startup

The thread starts before the fiber suspends. The loop is single-threaded and
cannot process a posted event until the nfunction returns and the fiber
suspends. This ordering requires no additional synchronisation.

### Worker calls

The worker thread calls only `wattle.post` from `wattle.*`. Other module API
functions use thread-local runtime state, which is absent on worker threads.
Calling them there aborts with
`called from a thread that is not running Wattle`. `wattle.post` takes the loop
explicitly, reads no thread-local state and allocates no memory. It writes a
fixed-size event to the loop's self-pipe.

### GC roots

The module must root values retained while other Wattle code runs. It calls
`wattle.gcroot` for the fiber, argument and job's abstract value before
`wattle.await`, then `wattle.gcunroot` in the callback. The worker hashes a
slice of the string's storage, so the argument root prevents that storage from
being collected. The job root prevents finalisation while the worker writes its
result.

### Cancelled fibers

`wattle.wake` returns `false` if the resume is discarded, for example when
`ev/cancel` has changed the fiber's state or the fiber has finished. The
callback must remove the module's roots regardless of the return value. Removing
them only when `wattle.wake` returns `true` would leak cancelled jobs.
`examples/native-events/test/digest.wattle` checks cancellation during hashing.

### Thread cleanup

`*Loop` remains valid until runtime shutdown. Calling `wattle.post` afterwards
would access released state. Worker threads receive no shutdown notification, so
the module must join them before the loop is released.

The job is a `digest/hash` abstract value. Its `gc` callback joins the thread
unless the posted callback has already joined it. Teardown runs all finalizers
before releasing the loop, so the join completes while `*Loop` is valid.
Normally, the posted callback joins the worker after it posts the event. The
join waits only for the worker to return from `wattle.post`; the finalizer has
no remaining thread to join. At shutdown, an unfinished hash delays exit until
hashing completes.

### Callback execution

The posted callback cannot raise. It runs on the loop thread between fibers to
construct the result `Value` and wake the waiting fiber. Computation belongs on
the worker thread. Collector allocation is allowed; allocation failure is fatal.
No safe point runs during the callback.

### Result lifetimes

String, symbol and keyword bytes remain stable while their values are reachable.
Rooting preserves that reachability. Buffer bytes are `data[0..count]`; a push
from another fiber can move the storage. Callers must prevent mutation of a
buffer during hashing. `examples/native-function` describes the same getter
lifetime requirements.

## Tests

The test checks:

- Digests for two known inputs and equal results for a buffer and string.

- Four concurrent hashes under `ev/gather`, with timing tolerance to check that
  hashing does not block the loop.

- Another fiber running two hundred times while a hash is computed.

- A cancellation result from a hash cancelled through `ev/cancel`, followed by
  successful loop operation.

- Exit status 0 from a child calling `os/exit` during hashing.

`test/zig-native.wattle` is where `wattle.wake`'s `false` branch is counted.

## API scope

The module API does not expose the runtime's thread pool, timers, streams, async
listeners or channels. Exposing these requires further design decisions. Modules
provide their own threads and post results, including when wrapping a C library
with its own loop.

## External builds

Use the `numarray` build procedure in `examples/native-abstract/README.md` for
an external package's `build.zig.zon` and `build.zig`.
`zig build examples/native-consumer` checks that build interface.
