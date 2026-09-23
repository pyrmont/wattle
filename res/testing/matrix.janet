#!/usr/bin/env janet
# Acceptance matrix for the Zig port, with a worker pool and two entry shapes.
#
# Development instrument in `res/`. See AGENTS.md, "Builds and
# the Zig cache", for the measurements the design rests on.
#
# Each job gets a throwaway cache and prefix of its own, deleted before and after
# it runs, so concurrency changes nothing about the disk discipline AGENTS.md
# asks for: the cost there is the number of distinct configurations, not how many
# are in flight. Results are collated in the order the jobs were declared, so the
# log does not depend on the scheduling.
#
# Three shapes, because what an entry runs matters more than how many entries run
# at once -- though less than it did. A full `zig build test` was 51 seconds and
# is 24 since Phase 10 Part 11 put every contract in one executable; 14 of those
# are the library and the rest is fifty-eight contracts and thirty-four Janet
# suites, nearly all of which the increment under test did not touch.
#
#   full       zig build test. For the entries where a regression *outside* the
#              increment's own contracts is the point -- a misplaced #endif shows
#              up as a suite failure, not as a contract failure.
#   contracts  The library, a startup smoke, and the increment's own contracts
#              run by name from the driver `zig build` installs. 20 seconds. The
#              shape the reduced-OS entry has always used, because the suites
#              cannot run there.
#   build      The library only. Cross-compiles, which cannot be run here.
#
# Set `contracts-default` to the increment's own contract files when a part lands.
#
# The worker pool is `ev/go` fibers rather than threads. Every job is dominated
# by the subprocesses it waits on, and `os/proc-wait` yields, so one thread
# schedules all of them; what was a `ThreadPoolExecutor` is a channel of jobs and
# `-j` fibers taking from it.

(import ../common :as tools)

# The `pp` trap is retired. It was three C files behind one selector, which
# `contract.sh` expanded by hand and this did not, so naming `pp` here failed
# every `contracts` entry at once with `test/pp.c:1:1: error: CacheCheckFailed`
# -- a compile error in a file that does not exist. Phase 11 Part 5 moved all
# three to the Zig driver, so each is an ordinary name in both tools.
#
# **A contract that creates files in the working directory may not be named
# here.** `contracts` jobs are the ones that do *not* take the suites lock --
# only `full` does, because `zig build test` runs the Janet suites -- so two of
# them run concurrently in the *same* repository working directory. Naming
# `os_fs` would have two entries creating, renaming and deleting
# `wattle-os-fs-public-91af` at once, which is exactly the shared-fixture
# problem the suites lock exists for, one layer down.
#
# The same rule one directory out: `os_surface` and `filewatch_core` write
# nothing to the working tree but each owns a fixture under `/tmp`, which two
# entries would collide on just as surely. That is rule 53 rather than rule 9.
#
# Part 24 is the gate, so this line stopped being an increment's own; every part
(def contracts-default
  # The contracts a `contracts` entry runs by name. Set to what the increment
  # in hand could break, not to a coverage sample; the `full` entries run all
  # sixty-five.
  #
  # These are the assertion conversion's own, because every contract's 5,016
  # assertions became `test/expect.zig`'s `expect` and a `contracts` entry in a
  # release mode is where a compiled-out assertion used to hide:
  #
  #   `utils`        the contract the gate proof was made in, and the one whose
  #                  hash and name-table assertions have no Janet spelling.
  #   `gc_mark`      the collector's frame walk, which the suites now drive as
  #                  well; a walk defect shows here as an unreachable block.
  #   `registry`     the published entry point and the sentinel adapter behind
  #                  it.
  #   `core_env`     the registration surface, which is what says the core
  #                  environment still holds what it held.
  #   `signal_core`  `raise.zig` picks its delivery on `config.native_module`,
  #                  and a reduced build is where the wrong arm shows as a
  #                  wrong signal rather than a compile error.
  #   `args_core`    every fault message, which is the largest single body of
  #                  assertions in the tree.
  #   `os_process`   the Windows declarations and the `pid_t` group.
  #   `value_wrap`   the `abi` namespace and the exact bit layout.
  #
  # (`io_core` and `os_fs` cannot be named: each creates files in the working
  # directory, which two concurrent `contracts` entries share, and `os_surface`
  # and `filewatch_core` each own a `/tmp` fixture for the same reason. The
  # suites cover them in every `full` entry instead.)
  #
  # Phase 15 Part 1 replaced these with its own: the constructors and the three
  # heads (`value_alloc`, `buffer_array`, `tables`, `string_symbol`,
  # `value_order`, `utils`), the compiler's registers (`regalloc`,
  # `emit_core`), the GC header (`gc_mark`, `gc_sweep`, `signal_core`,
  # `value_wrap`) and the widths that travel (`marsh`).
  # Phase 15 Part 3 replaced these with the contracts over the families it
  # converted: the instruction-shape table and both assembler directions
  # (`verify`, `asm_encode`, `asm_decode`, `disasm`), the compile and parse
  # statuses (`compiler_primitives`, `emit_core`, `specials_core`,
  # `parser_core`), the binding vocabulary (`registry`), the frame flag word
  # (`fiber_core`, `trace_frames`, `marsh`) and the integer types
  # (`inttypes`).
  # Phase 15 Part 5 replaced these with the contracts over the platform seam:
  # the retry loops and the `errno` accessor (`filewatch_core`, `ev_loop`,
  # `net_sockets`, `os_process`), the structures that stopped being `extern`
  # (`ev_core`, `os_surface`), the `callconv(.c)` residue in the value layer
  # (`value_alloc`, `string_symbol`, `tables`), and `io.zig`'s handles
  # (`pp_format`, `vm_run`). `io_core` and `os_fs` still cannot be named --
  # each creates files in the working directory two concurrent entries share.
  # `filewatch_core`, `ev_loop`, `net_sockets` and `ev_core` are the part's
  # own subjects and none of them can be named here: the first two own a
  # `/tmp` fixture two concurrent entries would share, and the event-loop pair
  # is not listed at all under `-Dev=false` or `-Dsingle-threaded`, which is
  # the trap the header records three times over. The `full` entries run all
  # 65 and cover them; these twelve are what a `contracts` entry can ask in
  # every configuration.
  #
  # Phase 15 Part 2 replaced these with the contracts over the bodies it
  # rewrote. The part touched 48 files, so this is not "what it changed" but
  # what its four *kinds* of change can break: the loops and the copies over
  # the value types (`value_alloc`, `buffer_array`, `tables`,
  # `string_symbol`), the optionals in the dictionary probe and the ordering
  # (`value_access`, `value_order`), the compiler's loops and scope unwraps
  # (`compiler_primitives`, `emit_core`, `specials_core`), the parser and the
  # marshaller (`parser_core`, `marsh`), and the cast reclassification's own
  # subject (`utils`). `io_core` and `os_fs` still cannot be named -- each
  # creates files in the working directory two concurrent entries share -- and
  # neither can `os_surface` or `filewatch_core`, which own `/tmp` fixtures.
  #
  # Phase 15 Parts 6 and 7 replaced these, and the phase gate ran with them.
  # Part 6 is a rename and Part 7 is prose, so neither has a subject a contract
  # can aim at -- but both carry a *deletion* that does: 22 definitions lost
  # their `callconv(.c)` and 48 unreferenced `pub` declarations went. So these
  # twelve are the contracts over the files those deletions touched: the value
  # layer's abi shims and the constructors (`value_wrap`, `value_alloc`,
  # `string_symbol`, `tables`), the collector and the scratch table
  # (`gc_alloc`, `gc_mark`), the register allocator that became a type with
  # methods (`regalloc`, `emit_core`, `compiler_primitives`), the marshaller
  # whose abi was rewritten (`marsh`), the signal record whose `cRaiseClear`
  # went (`signal_core`), and the binding surface (`registry`). `io_core`,
  # `os_fs`, `os_surface` and `filewatch_core` still cannot be named, for the
  # reasons above.
  #
  # Phase 16 replaced these with the contracts over the subsystems whose
  # behaviour it changed: the marshaller's lead bytes and its new
  # bytes-remaining bound (`marsh`), the peg verifier and matcher (`peg`), the
  # bytecode verifier's terminator mask (`verify`), the parser's error path
  # (`parser_core`), the collector's roots, interval, scratch and sweep
  # (`gc_alloc`, `gc_mark`, `gc_sweep`), the comparison order and the two
  # accessors (`value_order`, `value_access`), the boxed integers' division
  # and shifts (`inttypes`), the varargs tail (`fiber_core`), the registry
  # lookup that became a bisection (`registry`), and the interpreter's shifts
  # and its trace (`vm_run`). `ev_loop`, `gc_stress`, `io_core`, `os_fs`,
  # `os_surface` and `filewatch_core` are subjects that still cannot be named
  # -- the fixture and working-directory reasons above, and `ev_loop` is not
  # listed at all under `-Dev=false` or `-Dsingle-threaded=true`. The `full`
  # entries run all 65 and cover them.
  #
  # Phase 18 replaced these with the contracts over the boundary it moved. The
  # phase rewrote the marshaller's two state structs and every `marshal*` and
  # `unmarshal*` entry point, so `marsh` is the primary subject; the six
  # runtime types that implement the two slots are covered by `inttypes`,
  # `peg` and `math` (`io_core` and the two ev contracts cannot be named --
  # the working-directory and fixture reasons above, and the ev pair is not
  # listed under `-Dev=false` or `-Dsingle-threaded=true`). The `tostring`
  # slot changed its parameter type, so both of `pp.zig`'s dispatch sites are
  # here (`pp_describe`, `pp_pretty`, `pp_format`) along with the contract
  # that raises from one (`vm_calls`). `abstract_core` is the vtable those
  # slots sit in; `registry` is the abstract-type registry the phase
  # published; `gc_mark` is what the new `janet_mark` crossing publishes; and
  # `signal_core` is where a raise flattened through one of the eighteen new
  # reporting shims would show as a wrong signal rather than a compile error.
  # `core_env` says the registration surface still holds what it held. The
  # `full` entries run all 65.
  #
  # Phase 18 Part 7 replaced these with the contracts over the views it
  # published. The part edited no `args.zig` getter and added shims beside
  # them, so what a `contracts` entry can break is the layer underneath: every
  # fault message the getters raise (`args_core`), and the formatter that
  # renders them (`pp_format`); the six aggregates the three views read
  # (`string_symbol`, `buffer_array`, `tables`); the unwraps behind each
  # getter and the `abi` namespace's bit layout (`value_wrap`); the length
  # `getRange` folds against (`value_access`); the file `KV` moved out of and
  # the traversal that walks a table (`marsh`); `abi.zig`'s own restructuring,
  # since `AbstractType` and `AbstractHead` share the file the views moved into
  # (`abstract_core`); and the published boundary (`registry`, `core_env`).
  # `io_core`, `os_fs`, `os_surface` and `filewatch_core` still cannot be
  # named, for the reasons above. The `full` entries run all 65.
  #
  # Phase 18 Part 8 keeps Part 7's list and adds the two the constructors
  # reach: `value_alloc`, because every constructor allocates through the
  # collector, and `gc_mark`, because a composite built by a module is
  # reachable only from the value it answered. `buffer_array`, `tables`,
  # `string_symbol` and `value_access` were already here and are now the
  # constructors' subjects as well as the views'.
  #
  # Phase 18 Part 10 replaced these with the contracts over the boundary check
  # and the two shims. The check went into 65 of `capi.zig`'s 66 entry points
  # and eight `args.zig` shims, so what a `contracts` entry can break is every
  # fault message those shims still raise (`args_core`) and the formatter that
  # renders them (`pp_format`); the probe the check shares with the collector's
  # allocator, which this part extracted into `vm/state.zig` (`gc_alloc`,
  # `vm_state`); the fiber predicate `wake` tests and the entry points around
  # it (`fiber_core`, `vm_entry`); the raise flattening the four new reporting
  # crossings go through (`signal_core`); the unwraps and the `abi` namespace
  # the message packing uses (`value_wrap`); and the published boundary
  # (`registry`, `core_env`). `ev_loop` and `ev_core` are the part's own
  # subjects and neither can be named: the pair is not listed at all under
  # `-Dev=false` or `-Dsingle-threaded=true`, which is the trap this header
  # records four times over. The `full` entries run all 65 and cover them.
  #
  # The `make_vector` increment replaced these with the contracts over the
  # opcode it added and the arms that emit it. An opcode is four tables and
  # one interpreter arm, and each table is a separate way to be wrong: the
  # instruction-shape table (`verify`), the assembler's name table in both
  # directions (`asm_encode`, `asm_decode`, `disasm`), and the optimiser's two
  # (`movopt`, `remove_noops`), which decide whether the instruction writes a
  # register -- a miss there deletes a live one silently. `vm_run` is the arm
  # itself. `compiler_primitives` and `specials_core` are the emitters: the
  # value arm and its constant folding, and the parameter list, the
  # destructuring pattern and quasiquote. `vectors` is the value the arm
  # builds, and `emit_core` the instruction it emits. The three assembler
  # contracts are already in the `no assembler` entry's skip list, which is
  # what makes them safe to name.
  #
  # The parser swap replaced these with the contracts over the language it
  # changed. Step 7 merged the two parser contracts, so `parser_core` is the
  # one parser's one contract and the primary subject here. The positional
  # result became a vector across the library, so the value itself
  # (`vectors`, `maps`) is here with the callers whose returns changed:
  # `math` (`math/frexp`), `string_symbol` (`string/bytes`), `os_process`
  # (`os/pipe`), `net_sockets` (`net/address-unpack`) and `fiber_core` (`&
  # rest` in the frame push). The compiler and the bytecode now build from a
  # vector where they built from a bracket tuple, which is `emit_core`,
  # `compiler_primitives` and `specials_core` (the destructuring pattern and
  # quasiquote), `verify` and `vm_run`, and the assembler in both directions
  # (`asm_encode`, `asm_decode`, `disasm`) -- `disasm` because the decoded
  # instruction is a vector and the breakpoint flag it carried is gone. The
  # printer's notation is settled in `pp_pretty`, `pp_format` and
  # `pp_describe`, a value the pretty printer writes now having to parse.
  # `peg` reads a vector as the combinator its tuple is. `registry` and
  # `core_env` are the published boundary, which `env.zig`'s new paths reach.
  # `net_sockets` is safe to name because the `no net` and `single threaded`
  # entries both skip it, and the three assembler contracts because the `no
  # assembler` entry does; `io_core`, `os_fs`, `os_surface`, `filewatch_core`
  # and the ev pair still cannot be named, for the reasons above. The `full`
  # entries run all of them.
  # The increments of 2026-09-17 to 19 replaced these, and this run is the
  # matrix owed against step 7 as a whole and everything after it, deferred
  # five times. The subjects are the value layer and the printer rather than
  # the parser: the vector became a single block for a short tail and its
  # inline leaf was misaligned on every 32-bit target (`vector`, `vectors`,
  # `value_alloc`), which the collector walks rather than marks through a
  # header (`gc_alloc`, `gc_mark`, `gc_sweep`); the set gained a literal in
  # the writer and edn arrived as `%y` (`pp_format`, `pp_pretty`,
  # `pp_describe`, `maps`); and the map, table and string constructors carry
  # the rest of the value work (`tables`, `string_symbol`, `value_access`,
  # `value_order`, `marsh`). Removing Janet is still under this run, so the
  # parser, the compiler's three and the binding surface stay (`parser_core`,
  # `compiler_primitives`, `emit_core`, `specials_core`, `registry`,
  # `core_env`, `vm_run`).
  #
  # `gc_stress`, `io_core`, `os_fs`, `os_surface`, `filewatch_core` and the
  # ev pair are subjects this cannot name, for the fixture and
  # working-directory reasons above; the `full` entries run all 68.
  #
  # The outstanding-operations increment replaced these with the contracts
  # over what it moved off the fiber. A stream now holds a list of operations
  # per direction and a fiber holds one `ev_op` in place of its three event
  # fields, so the fiber's own layout and its reset are here (`value_alloc`,
  # `fiber_core`, `marsh`), and so is the collector, which traces an operation
  # from the stream rather than from the fiber and no longer frees an
  # event-loop allocation in the sweep (`gc_alloc`, `gc_mark`, `gc_sweep`).
  # Every event callback changed its first parameter, so a raise flattened
  # through one would show as a wrong signal rather than a compile error
  # (`signal_core`), and three stream docstrings changed, which is the
  # published surface (`registry`, `core_env`). `vm_run` is the interpreter
  # the scheduler resumes through.
  #
  # `ev_loop`, `ev_core`, `net_sockets` and `filewatch_core` are the
  # increment's own subjects and none can be named: the ev pair is not listed
  # at all under `-Dev=false` or `-Dsingle-threaded=true`, and the other two
  # own fixtures two concurrent entries would share. The `full` entries run
  # all 68 and cover them.
  ["value_alloc" "fiber_core" "marsh" "gc_alloc" "gc_mark" "gc_sweep"
   "signal_core" "registry" "core_env" "vm_run"])

# Every command gets a bound. Phase 10 Part 16 lost thirty-six minutes to a
# `zig build test` whose `suite-ev.wattle` parked in `kevent` with an empty
# kqueue: the pool had nothing to time it out, `as_completed` never saw it, and
# the run produced no output at all because the log is written at the end. A
# hang is now a FAIL for that entry and the rest of the matrix continues.
(def build-timeout 900)
# A `zig build test` whose compiling is already done takes about 25 seconds and
# its longest suite about 3, so 300 is generous by an order of magnitude and a
# park is detected in five minutes rather than fifteen.
(def test-timeout 300)
(def run-timeout 300)

# Only one entry may *run* the Janet suites at a time.
#
# Phase 10 Part 16 traced a wedged matrix to this and found three shared
# fixtures, not one: `suite-ev.wattle` binds a fixed port 8761,
# `suite-net.wattle` binds a fixed `/tmp/wattle-suite-net.sock`, and
# `suite-ev.wattle` and `suite-bundle.wattle` create `unique.txt` and
# `tempdir123` **in the repository working directory**, which every concurrent
# entry shares. Two overlapping `full` entries therefore cross-connect: usually
# one of them fails in `net/read`, and occasionally one parks in `kevent` and
# never returns. Measured at 17 failures in 32 two-at-a-time runs -- 8 on one
# arm of the selector under test and 9 on the other, which is what shows it is
# the fixtures rather than the code.
#
# Setting `JANET_TEST_PORT` per slot fixes only the first of the three; the
# other two are cwd- and /tmp-relative and cannot be moved without editing the
# suites. So a `full` entry compiles concurrently -- which is where the time
# goes -- and then takes this lock to run.
#
# **It is a channel and not `ev/lock`, and that is a measurement rather than a
# preference.** `ev/lock` is the obvious translation of Python's
# `threading.Lock` and it is the wrong primitive: it is an OS mutex for
# coordinating *threads*, and its own docstring says it "will block this entire
# thread ... and will not yield to other fibers on this system thread". This
# pool is fibers on one thread. Measured, a second fiber acquires it while the
# first still holds it --
#
#     @[:a-acquired :b-trying :b-acquired :a-releasing]
#
# -- so it excludes nothing. It does not error and it does not deadlock; it is
# simply a no-op here, which is why the matrix passed twice with it in place.
# A channel holding one token is the fiber-level equivalent, and orders the
# same probe correctly: take is acquire, give is release, and both yield.
(def suites-lock (ev/chan 1))

# A name somebody will type that is not a file. `pp` was three translation
# units behind one selector: `contract.sh` expanded it and this did not, so
# naming it here failed every `contracts` entry at once with
# `test/pp.c:1:1: error: CacheCheckFailed` -- a compile error in a file that
# does not exist.
#
# Phase 11 Part 5 moved all three to the Zig driver and deleted `contract.sh`'s
# expansion with them, so `pp` is now wrong in *both* tools rather than in one.
# The entry stays: the habit outlived the mechanism twice already, and one line
# here turns it into a sentence before the first build instead of twenty
# failures seven minutes in.
(def not-a-file {"pp" ["pp_describe" "pp_pretty" "pp_format"]})

(defn- job [kind name flags &opt skip]
  # `skip` names contracts that do not apply to this configuration.
  # `test/inttypes.zig` names types a `-Dint-types=false` build does not define,
  # and `build.zig` skips it there for the same reason.
  {:kind kind :name name :flags flags :skip (or skip [])})

(defn- preflight
  "Every check that needs no build, run before the first one starts.

  Two classes of harness mistake account for every wasted matrix run this
  phase: a contract entry that is not a `test/*.zig`, and a `-D` option a
  selector no longer has. Both are visible from `build.zig` and the
  filesystem, and both used to surface one entry at a time, minutes apart,
  as what looked like a compile error or a build failure. AGENTS.md warned
  about both in prose and the prose did not prevent either.

  So they are a check now, they run in about a second, and they report
  *every* problem at once rather than the first -- because the failure mode
  being fixed is precisely a slow serial discovery of a list.

  `zig fmt --check` is the third, added in Phase 12 increment 4, and it is
  here rather than in CI on purpose. Fifteen files had drifted out of the
  formatter -- eight under `src/`, seven under `test/` -- because nothing
  ran it, and the drift is invisible in review: the diff of a reformat is
  every line of the hunk. The matrix is the instrument this project actually
  runs per increment, so it is where a whole-tree property gets enforced. It
  is *not* a per-configuration question and so is not a job: one run over the
  tree, before the first build starts, costing about a second."
  [jobs contracts]
  (def problems @{})

  # `zig fmt --check` names each unformatted file on stdout and exits
  # non-zero. Reported as one problem listing all of them rather than one
  # per file, so the message stays a sentence and still says what to fix.
  (def fmt (tools/sh "zig fmt --check build.zig src test" :timeout 120))
  (unless (zero? (or (fmt :code) 1))
    (def files (filter |(not (empty? $)) (string/split "\n" (string/trim (fmt :out)))))
    (put problems
         (if (empty? files)
           (string/format "`zig fmt --check` failed and named no file: %s"
                          (tools/head (string/trim (tools/both fmt)) 200))
           (string/format "%d file%s not `zig fmt` clean -- run `zig fmt build.zig src test`:\n    %s"
                          (length files) (if (= 1 (length files)) " is" "s are")
                          (string/join (sort files) "\n    ")))
         true))

  (each t contracts
    (if-let [alternatives (not-a-file t)]
      (put problems (string/format "contracts names %j, which is not a file: use %s"
                                   t (string/join alternatives ", "))
           true)
      (unless (os/stat (string "test/" t ".zig"))
        (put problems (string/format "contracts names %j but there is no test/%s.zig" t t)
             true))))

  (def help-text ((tools/sh "zig build -h" :timeout 120) :out))
  (def known @{})
  (each line (string/split "\n" help-text)
    (when-let [flag (peg/match ~(sequence (some (set " \t"))
                                          (capture (sequence "-D" (some (choice :w "-")))))
                               line)]
      (put known (first flag) true)))
  (if (empty? known)
    (put problems "could not read the option list from `zig build -h`" true)
    (each j jobs
      (each flag (j :flags)
        (def name (first (string/split "=" flag)))
        # A `-f` flag is the compiler's own rather than one of `build.zig`'s
        # options, so the option list says nothing about it: `-fwasmtime` is
        # what runs a wasm artifact under wasmtime.
        (unless (or (string/has-prefix? "-f" name) (known name))
          (put problems (string/format "job %j passes %s, which build.zig no longer has"
                                       (j :name) name)
               true)))))

  (unless (empty? problems)
    (tools/die "matrix.janet: refusing to start --\n  "
               (string/join (sort (keys problems)) "\n  "))))

(defn- error-lines
  "The lines of a result worth reading, capped the way the log is."
  [r]
  (def text (tools/both r))
  (def wanted (seq [line :in (string/split "\n" text)
                    :when (or (string/find "error:" line) (string/find "assert" line))]
                line))
  (def joined (string/join wanted "\n"))
  (if (> (length joined) 1500) (string/slice joined 0 1500) joined))

(defn- run-job [j slot contracts]
  (def cache (string "/tmp/wattle-mx-" slot))
  (def prefix (string "/tmp/wattle-mx-out-" slot))
  (each p [cache prefix] (tools/rm-rf p))
  (def started (os/clock))
  (defn secs [] (- (os/clock) started))

  (defn build-cmd [target]
    (string "JANET_TEST_PORT=" (+ 8761 slot) " zig build " target
            " --cache-dir " cache " -p " prefix " "
            (string/join (j :flags) " ")))

  (defn build [target]
    (tools/sh (build-cmd target)
              :timeout (if (= target "") build-timeout test-timeout)))

  # The detail names the command that hung, not the target -- a bound with no
  # subject tells the reader nothing about which of the two builds it was.
  (defn hung [target]
    [j "FAIL" (string/format "hung after %ds: %s"
                             (if (= target "") build-timeout test-timeout)
                             (tools/head (build-cmd target) 200))
     (secs)])

  (defer (each p [cache prefix] (tools/rm-rf p))
    (label done
      # Compile first, outside the lock, because that is where the time goes.
      (def r (build ""))
      (when (r :timeout) (return done (hung "")))
      (unless (= 0 (r :code))
        (return done [j "FAIL" (string "build\n" (error-lines r)) (secs)]))

      (when (= (j :kind) "full")
        # A hang here is retried once, and the retry's verdict is reported
        # as FLAKY rather than as PASS. Phase 10 Part 16 found a rare park
        # in `suite-ev.wattle` -- `kevent` with an empty kqueue, twice in
        # about a hundred runs -- that is nothing to do with the selector
        # under test. Retrying keeps one such park from costing a whole
        # matrix; naming it FLAKY keeps the retry from hiding it.
        (var was-hung false)
        (var test-result nil)
        (each attempt [1 2]
          (when (nil? test-result)
            (def tr (defer (ev/give suites-lock true)
                      (do (ev/take suites-lock) (build "test"))))
            (if (tr :timeout)
              (if (= attempt 2)
                (return done (hung "test"))
                (set was-hung true))
              (set test-result tr))))
        (unless (= 0 (test-result :code))
          (return done [j "FAIL" (string "test\n" (error-lines test-result)) (secs)]))
        (when was-hung
          (return done [j "FLAKY" "passed on retry after one hang" (secs)])))

      (when (= (j :kind) "contracts")
        # A startup smoke first: it costs nothing, needs no helper -- which
        # is what lets the reduced-OS entry run it -- and separates a
        # broken link from a broken contract.
        (def smoke (tools/sh (string prefix "/bin/wattle -e '(print (+ 1 2))'")
                             :timeout run-timeout))
        (when (or (not (tools/ok? smoke)) (not= "3" (string/trim (smoke :out))))
          (return done [j "FAIL"
                        (string "smoke: "
                                (let [text (if (empty? (smoke :err)) (smoke :out) (smoke :err))]
                                  (if (> (length text) 400) (string/slice text 0 400) text)))
                        (secs)]))
        (each t contracts
          (unless (has-value? (j :skip) t)
            # There is nothing to compile and nothing to link. Phase 11
            # Part 1 put the Zig contracts inside a second compilation of
            # the runtime -- which is how one reaches a raise-capable
            # function with no C-ABI abi between them -- and Part 22 took
            # the last C contract, so every name here is a `test/*.zig`
            # already inside the driver `build.zig` installs
            # unconditionally. This runs it by name, which is what
            # `res/testing/contract.sh` does too.
            (def run (tools/sh (string prefix "/test/wattle-contract-test " t)
                               :timeout run-timeout))
            (unless (tools/ok? run)
              (return done [j "FAIL"
                            (string/format "run %s\n%s" t
                                           (tools/tail (if (empty? (run :err)) (run :out) (run :err)) 400))
                            (secs)])))))
      [j "PASS" "" (secs)])))

(defn- all-jobs []
  @[
    # Phase 10 Part 17b converted 656 call sites across twenty-eight
    # subsystems, so this matrix is asked the same question 17a's was and
    # for a second reason: every nfunction in the runtime opens with two or
    # three calls into the layer that changed, so a configuration that
    # compiles an nfunction nothing else compiles is the only thing that
    # checks those. Phase 10's fifth rule is the whole argument -- a
    # comptime-false branch is not analysed, so an arm this host does not
    # take was never seen by the conversion at all. The Windows
    # cross-compile found exactly that in `net_sockets.zig`.
    (job "full" "default" [])
    # "every selector c" stood here, and so did nine entries naming one
    # selector each. Phase 10 Part 18 spent the last twenty-nine `c` arms,
    # so there is no second implementation for a configuration to choose
    # and there are no `-D<sel>=c` flags left to pass. What replaced the
    # differential is what was always underneath it: the contracts, and the
    # Janet suites.
    (job "full" "ReleaseSafe" ["-Doptimize=ReleaseSafe"])
    (job "full" "ReleaseFast" ["-Doptimize=ReleaseFast"])
    (job "full" "ReleaseSmall" ["-Doptimize=ReleaseSmall"])

    # Feature gates, which decide whether a subsystem is imported at all.
    # `zigSelection` is the single place that answers, and a wrong answer
    # here is a subsystem compiled with nothing to compile against.
    (job "full" "no event loop" ["-Dev=false"])
    # **The poll backend, and this entry is why it exists.** `build.zig`
    # chooses epoll on Linux, kqueue on the BSDs and macOS, and poll on
    # anything else -- so poll is reachable only by turning the host's own
    # backend off, which nothing in this matrix did. Phase 13 increment 3a
    # built it for the first time and it did not compile: three indexings of
    # an optional many-pointer that increment 5h's `.?` pass never saw, an
    # ignored error union, and a fiber dereference. Phase 11's rule 72 is the
    # class -- a comptime-false arm is not dead code, it is *unchecked* code --
    # and this entry is what checks it.
    #
    # **Both flags, so the name is true on either Unix family.** With
    # `-Dkqueue=false` alone this job selected poll on macOS and the BSDs and
    # *epoll* on Linux, where it then reported itself as the poll backend and
    # left the repaired arm outside the ratchet on the one host most likely to
    # run it in CI. Turning off a backend a build does not have costs nothing,
    # so both are passed unconditionally rather than derived from the host.
    (job "full" "poll backend" ["-Dkqueue=false" "-Depoll=false"])
    (job "full" "no ffi" ["-Dffi=false"])
    # The watcher is selected as `cfg.ev and cfg.filewatch`, so neither of the
    # watcher's contracts is compiled here. This entry is `full`, so it
    # runs the whole Zig driver rather than the contract list by name and
    # needs no skip; the single-threaded entry below is where that bites.
    (job "full" "no filewatch" ["-Dfilewatch=false"])
    (job "contracts" "no net" ["-Dnet=false"] ["net_sockets"])

    # `-Dpeg=false` leaves the tree without `Peg` or `janet_peg_type`,
    # so `test/peg.zig` cannot compile here -- the same shape as the ev
    # contracts under `-Dsingle-threaded=true`. Part 17e is the first
    # increment whose own contracts include `peg`, and it found this the
    # way the ev one was found: by failing. Phase 11 Part 14 moved the
    # contract to the Zig driver, where `test/contracts.zig` gates it on
    # `options.peg_engine`; the skip is still needed, because a name in the
    # contract list is run by name and this build has no `peg` to run.
    (job "contracts" "no peg" ["-Dpeg=false"] ["peg"])
    # There is no `AssembleResult` without the assembler.
    (job "contracts" "no assembler" ["-Dassembler=false"]
         ["asm_encode" "asm_decode" "disasm"])
    (job "contracts" "no int types" ["-Dint-types=false"] ["inttypes"])
    (job "contracts" "no dynamic modules" ["-Ddynamic-modules=false"])
    # `Config.ev` folds in `-Dsingle-threaded` and the target, so the two ev
    # contracts cannot be compiled here -- neither the channel API nor
    # `JanetStream` is declared. The comment above this entry has said
    # so since Part 16; Part 17d is the first increment whose own contracts
    # include one, and it had to learn that the skip the comment names
    # was never actually passed.
    (job "contracts" "single threaded" ["-Dsingle-threaded=true"]
         ["ev_core" "ev_loop" "net_sockets" "filewatch_flags" "filewatch_core"])
    # `build.zig` sets `.os_fs = !options.reduced_os`, so the skip list has to
    # name all four contracts `test/contracts.zig` gates on `options.os_fs`.
    # It named only `os_stat` until increment 8b picked `os_fs` as a subject
    # and the entry failed with `os_fs was not compiled into this binary` --
    # a harness gap that had simply never been selected for.
    #
    # **A `full` entry since Phase 16 Part 4.** It was `contracts` because the
    # suites could not run at all here -- `test/helper.wattle` named `os/getenv`
    # and an unknown symbol is a compile error, so every suite refused to load.
    # The harness asks `compif` now and `build.zig` does not schedule the seven
    # suites whose fixtures need the OS, so the other 28 run.
    (job "full" "reduced os" ["-Dreduced-os=true"]
         ["os_fs" "os_stat" "os_fs_paths" "os_permissions"
          "os_environ" "os_time" "os_process"])
    (job "contracts" "tagged values" ["-Dnanbox=false"])
    (job "full" "nanbox pointer shift 2" ["-Dnanbox-pointer-shift=2"])

    # Every fiber's stack moved on every frame push, so that a pointer kept
    # across one is a use-after-free the allocator can see.
    #
    # A `full` entry rather than a `build` one because compiling it is not the
    # question: the arm is four lines and it is what happens to the *rest* of
    # the runtime when the stack address changes under it that this asks about.
    # Twenty seconds, and it is the only configuration in the matrix that
    # invalidates a stack pointer deliberately.
    #
    # It exists at all because it was `Config.debug`, pinned false, guarding an
    # arm that no configuration compiled -- and which had a slice of an optional
    # many-pointer with no `.?` in it. A comptime-false constant is unchecked
    # code, and this is the entry that checks it.
    (job "full" "fiber stack shuffle" ["-Dfiber-stack-shuffle=true"])

    # x86_64 macOS, build-only. Running it needs Rosetta, which is not
    # installed on every Apple silicon Mac and stops being general-purpose
    # after macOS 27, so an entry that ran it would fail on the machine rather
    # than on the code. What it still checks is that the target compiles.
    (job "build" "x86_64-macos" ["-Dtarget=x86_64-macos"])

    # wasm32-wasi, which *runs* rather than only building: `-fwasmtime` runs
    # each artifact under wasmtime, which preopens the working directory and
    # nothing else. It is the only 32-bit entry that runs the suites, and the
    # target derives its own configuration -- no event loop, no FFI, no
    # processes, single-threaded -- so it needs no other flag.
    (job "full" "wasm32-wasi" ["-Dtarget=wasm32-wasi" "-fwasmtime"])

    # The four cross-compiles. They matter more here than usual: the fold
    # changed which files are analysed together, and Phase 10's fifth rule
    # is that a comptime-false branch is not analysed at all.
    (job "build" "x86_64-linux-musl" ["-Dtarget=x86_64-linux-musl"])
    (job "build" "aarch64-linux-musl" ["-Dtarget=aarch64-linux-musl"])
    (job "build" "riscv32-linux-musl" ["-Dtarget=riscv32-linux-musl"])
    (job "build" "x86_64-windows-gnu" ["-Dtarget=x86_64-windows-gnu"])
    # The reduced-configuration remainder. The population of configurations is
    # `zig build -h`'s option list, not this file's job list -- the matrix
    # samples what is worth *running*, which is a different question from what
    # is worth *compiling*. A sweep of only what this file already named would
    # have transcribed `JANET_VM_HAS_INTERRUPT` as a constant, and a set of
    # `@hasDecl` probes went silently always-true in exactly the builds nothing
    # here compiled. Build-only, because what they check is that
    # the configuration compiles at all.
    (job "build" "prf" ["-Dprf=true"])
    (job "build" "no docstrings" ["-Ddocstrings=false" "-Dsourcemaps=false"])
    (job "build" "no ipv6" ["-Dipv6=false"])
    (job "build" "no cryptorand" ["-Dcryptorand=false"])
    (job "build" "no interpreter interrupt" ["-Dinterpreter-interrupt=false"])
    (job "build" "no processes" ["-Dprocesses=false"])
    (job "build" "no umask" ["-Dumask=false"])
    (job "build" "no realpath" ["-Drealpath=false"])

    # The four cross-compiles Part 25 added and this file never gained: both
    # glibc targets, and the two further 32-bit ones. `PLAN.md` records the
    # 32-bit set as three targets, and only one of them was here.
    (job "build" "x86_64-linux-gnu" ["-Dtarget=x86_64-linux-gnu"])
    (job "build" "aarch64-linux-gnu" ["-Dtarget=aarch64-linux-gnu"])
    (job "build" "x86-linux-musl" ["-Dtarget=x86-linux-musl"])
    (job "build" "arm-linux-musleabihf" ["-Dtarget=arm-linux-musleabihf"])
  ])

(defn- option
  "The value of `--name X` or `--name=X` (or `-jN`), or nil."
  [argv name]
  (var found nil)
  (for i 0 (length argv)
    (def arg (argv i))
    (cond
      (and (= arg name) (< (+ i 1) (length argv))) (set found (argv (+ i 1)))
      (string/has-prefix? (string name "=") arg) (set found (string/slice arg (+ 1 (length name))))
      (and (= 2 (length name)) (string/has-prefix? name arg) (> (length arg) 2))
      (set found (string/slice arg 2))))
  found)

(defn main [& argv]
  (os/cd tools/root)
  (def workers (math/trunc (or (scan-number (or (option argv "-j") "2")) 2)))
  (def log-path (or (option argv "--log") "/tmp/wattle-matrix.log"))
  (def only (option argv "--only"))
  (def contracts (filter |(not (empty? $))
                         (string/split "," (or (option argv "--contracts")
                                               (string/join contracts-default ",")))))

  (var jobs (all-jobs))
  (when (has-value? argv "--all-full")
    (set jobs (map (fn [j]
                     (if (= (j :kind) "contracts") (merge j {:kind "full"}) j))
                   jobs)))
  (when only
    (def wanted (string/split "," only))
    (set jobs (filter (fn [j] (some |(string/find $ (j :name)) wanted)) jobs)))

  (preflight jobs contracts)

  # The suites lock starts held-by-nobody: one token in the channel.
  (ev/give suites-lock true)

  (def results @{})
  (def wall-started (os/clock))
  # The work queue is an index rather than a channel: closing a Janet channel
  # discards whatever is still buffered in it, so a channel would have to be
  # kept open and drained by sentinel. Reading and bumping `next-job` cannot
  # race, because `ev/go` fibers are cooperatively scheduled on one thread and
  # nothing between those two lines yields.
  (var next-job 0)

  # The slot is the job index, not `index % j`. A pool hands the next
  # queued task to whichever worker frees up first, so a slot reused `j`
  # positions later collides with the job still holding it -- the symptom
  # is "failed to rename compilation results into local cache:
  # FileNotFound", which names nothing useful. A directory per job costs
  # nothing: each is removed as soon as its job ends either way.
  (def worker-count (min workers (length jobs)))
  (def finished (ev/chan worker-count))
  (for _ 0 worker-count
    (ev/go
      (fn []
        (while true
          (def i next-job)
          (when (>= i (length jobs)) (break))
          (++ next-job)
          (def j (jobs i))
          (def [_ status detail secs] (run-job j i contracts))
          (put results (j :name) [status detail secs])
          # Printed as it lands, not only at the end. A run that is killed --
          # or wedged -- is then still worth what it had reached.
          (printf "%-4s %-38s %5.1fs  (%d/%d)"
                  status (j :name) secs (length results) (length jobs))
          (when (not (empty? detail))
            (print "      " (string/replace-all "\n" "\n      " detail)))
          (:flush stdout))
        (ev/give finished :done))))
  (for _ 0 worker-count (ev/take finished))

  (def wall (- (os/clock) wall-started))

  (def kind-label {"build" " (build only)" "contracts" " (library + contracts)" "full" ""})
  (each j jobs
    (unless (kind-label (j :kind))
      (tools/die (string/format "matrix.janet: unknown job kind %j for %j" (j :kind) (j :name)))))
  (def log @"")
  (buffer/format log "-j%d, %d contracts\n" workers (length contracts))
  (each j jobs
    (def name (string (j :name) (kind-label (j :kind))))
    (if-let [entry (results (j :name))]
      (let [[status detail secs] entry]
        (buffer/format log "%s  %-38s %5.1fs\n" status name secs)
        (when (not (empty? detail))
          (buffer/push log "      " (string/replace-all "\n" "\n      " detail) "\n")))
      (buffer/format log "----  %-38s        did not run\n" name)))
  (buffer/format log "MATRIX DONE in %.1fs wall (%.1fs of work)\n"
                 wall (sum (map |($ 2) (values results))))
  (spit log-path log)
  (prin log)
  (os/exit (if (all |(has-value? ["PASS" "FLAKY"] ($ 0)) (values results)) 0 1)))
