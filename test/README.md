# How this runtime is tested

The layers, what each is for, and what a change owes before it is believed.
[../src/README.md](../src/README.md) has the rules the runtime keeps, and
[../tools/README.md](../tools/README.md) has the instruments named below.

## The six layers

Six layers, and a change is believed when the layers it touches pass:

- The Janet suites, `test/suite-*.janet`, run by `zig build test`. What a Janet
  program can observe, asserted the way a Janet program would.
- The contracts, `test/*.zig`, one per subject, run by the driver `zig build`
  installs. What no Janet program can reach: an argument fault's exact message,
  a flag table's order, a collector's block list. Each is compiled into a second
  copy of the runtime, so it calls its subject by import and a raise arrives as
  a value.
- The in-file `test` blocks under `src/`, run by `zig build test` as
  `janet-runtime-test`. Interior facts with no runtime under them: a
  classification table, a mode-string parser.
- The fuzz targets, `test/fuzz.zig`: parser, compiler, marshalling and bytecode,
  run once over their corpora by `zig build test` and as a campaign by
  `zig build fuzz --fuzz`.
- Debug, optimized and sanitizer builds, through `tools/testing/matrix.janet`.
  Optimized builds must keep the contracts' assertions live, and
  `test/expect.zig` is what keeps them: `std.debug.assert` is `unreachable`, and
  in `ReleaseFast` and `ReleaseSmall` that is undefined behaviour the optimizer
  may delete along with the condition.
- Cross-platform builds and container runs, below, plus performance and
  binary-size tracking for central runtime changes.

A compatibility failure should be reduced to a focused regression test before it
is fixed.

## Cross-platform validation without CI

A second platform can be exercised locally, before any public CI exists.  `zig
build test` cannot do this on its own: it runs what it builds, which is
impossible when the target is not the host. Build with `-Dinstall-tests=true`
instead, which adds the runtime-test executable and the native-module and
module-load fixtures to `<prefix>/test`, beside the contract and fuzz drivers
every non-wasm build installs there, then run them on the target machine.

The development recipe uses a container for the target userland:

```sh
zig build -Dtarget=aarch64-linux-musl -Dcpu=baseline \
          -Dinstall-tests=true -p xbuild/arm

podman run --rm --platform linux/arm64 --tmpfs /work:size=256m \
  -v "$PWD":/src:ro -v "$PWD/xbuild/arm":/xb:ro alpine:latest sh -c '
    tar -C /src --exclude=.zig-cache --exclude=zig-out --exclude=xbuild \
                --exclude=.git -cf - . |
      tar -C /work -xf -
    cd /work
    ...then run every /xb/test/janet-*-test and every test/suite-*.janet
       with /xb/bin/janet...'

rm -rf xbuild/arm
```

### The glibc recipe

The glibc recipe was run ad hoc and not written down once, and had to be
reconstructed to diagnose a defect only that libc detects. It is the musl recipe
with two substitutions: `-gnu` for `-musl`, and `debian:trixie` for
`alpine:latest`.

```sh
zig build -Dtarget=aarch64-linux-gnu -Dcpu=baseline \
          -Dinstall-tests=true -p xbuild/gnu --cache-dir /tmp/janet-xc-gnu

podman run --rm --platform linux/arm64 --tmpfs /work:size=256m \
  -v "$PWD":/src:ro -v "$PWD/xbuild/gnu":/xb:ro debian:trixie sh -c '
    tar -C /src --exclude=.zig-cache --exclude=zig-out --exclude=xbuild \
                --exclude=.git -cf - . | tar -C /work -xf -
    cd /work
    /xb/test/janet-zig-contract-test         # the driver, all 65 in one process
    for c in $(grep -o "with(list, \"[a-z_0-9]*\"" test/contracts.zig |
               sed "s/.*\"\(.*\)\"/\1/"); do
      /xb/test/janet-zig-contract-test $c || echo "FAIL $c"
    done
    for s in test/suite-*.janet; do /xb/bin/janet $s || echo "FAIL $s"; done'

rm -rf xbuild/gnu /tmp/janet-xc-gnu
```

### Both libcs

Run both libcs rather than only one. They are not interchangeable, and each has
exposed a defect the other cannot. glibc's allocator checks fastbin chunk
alignment and musl's does not, which is the reason a heap corruption surfaced
there first. musl is what CI tests, because that corruption made the glibc
driver run abort. Run the contract driver with no argument on either libc. It is
the only thing in the tree that initialises and tears the runtime down
sixty-five times in one process, and that is a workload nothing else here has.

### Two practical traps

- The podman VM does not mount `/tmp`. `-v /tmp/something:/x:ro` fails with
  `statfs: no such file or directory`. Only paths under the machine's shared
  directories, `$PWD` under `/Users` here, can be bind-mounted, so a helper
  script or a name list has to be written inside the repository or generated in
  the container.
- `--platform linux/arm64` is not optional on an Apple-silicon host when the
  image is multi-arch, or the userland and the cross-built binary disagree.

### Which 32-bit targets are reachable

Three 32-bit targets are reachable, and glibc is too. The paragraph below said
one and none, and it was wrong for two phases. The cause was our own include
path: a `features.h` of ours sat on the `-I` path, `-I` beats the system search
path, and it therefore satisfied `#include <features.h>` in every libc header
that used it. (It is `src/host/janet_features.h` now, and the rename is what
closes the hazard.) glibc's `features.h` is what defines `__GLIBC_USE`, so `#if
__GLIBC_USE (IEC_60559_BFP_EXT)` became `0 (...)` and the translation failed
6,662 times. musl's 32-bit headers lost their own feature macros the same way,
and the `__REDIR` declarations named below were the symptom rather than the
cause. Renaming ours to `janet_features.h` opened `x86_64-linux-gnu`,
`aarch64-linux-gnu`, `x86-linux-musl` and `arm-linux-musleabihf` in one change.

The rule generalises beyond the fix, and it is rule 47's family: a failure
recorded as the toolchain's should be re-tested whenever the tree's own include
path changes. This failure was filed against Aro, sat beside two genuine Aro
failures, and was ours all along. What is still genuinely translate-c's is
`x86-windows-gnu`, which fails in mingw's `malloc.h` on `_ALLOCA_S_MARKER`;
`x86_64-windows-gnu` builds.

The eight targets `.github/workflows/test.yml` cross-builds are the current set,
and `wasm32-wasi` is a ninth entry, which runs rather than only building. A
32-bit target belongs in the build set for a narrowed form of the reason the
original paragraph gave: Zig analyses only the branches it selects, and no other
build analyses the Linux host layer at a four-byte pointer.

### The superseded 32-bit paragraph

The superseded text follows, because the measurement in it is what made the
wrong diagnosis plausible.

A 32-bit target is reachable, only one is, and it belongs in the set as a
compile check. Zig 0.16's translate-c front end (Aro) rejects musl's 32-bit
`time64` `__REDIR` declarations, which appear in `sched.h` and `time.h` and are
reached by `abi.zig` through `features.h`. That fails the shared translation, so
on `x86-linux-musl` and `arm-linux-musleabihf` every Zig subsystem fails to
compile at once. `x86-windows-gnu` fails in `malloc.h` and the shipped glibc
headers fail in `libc-header-start.h`. `riscv32-linux-musl` is the target that
translates, because musl's riscv32 port is time64-native and needs no
redirections. It is in the per-increment set as a compile, which is all it needs
to be:

```sh
zig build -Dtarget=riscv32-linux-musl -Dcpu=baseline \
          --cache-dir /tmp/janet-xc-rv -p /tmp/janet-out-rv
rm -rf /tmp/janet-xc-rv /tmp/janet-out-rv
```

Four targets select the 32-bit NaN-boxed layout and the 32-bit arm of every
pointer-width branch. `riscv32-linux-musl`, `x86-linux-musl` and
`arm-linux-musleabihf` build it, and `wasm32-wasi` builds and runs it. Zig
analyses only the branches it selects, so those four are what type-check that
code.

The binaries can be run: Alpine ships `qemu-riscv32`, and the contracts have
passed under it, which is how the 32-bit NaN-boxing arm of
`test/value_wrap.zig` was validated. Running them is deliberately not part of
the per-increment set. It costs a container and an emulator, and `wasm32-wasi`
runs the suites and the contracts on the same 32-bit layout without either. The
contract driver needs no build option: every non-wasm build installs it under
`<prefix>/test`. The recipe is the aarch64 example above, with `apk add
qemu-riscv32` and `qemu-riscv32` in front of each binary.

### The riscv32 ABI hazard

One riscv32 hazard is closed rather than open, and is recorded so that it is not
rediscovered. Zig 0.16 and clang disagree about how many argument registers an
eight-byte union consumes under riscv32 ILP32D, so a value passed by value
across a Zig-to-C call displaced every argument behind it. The displacement was
measured in isolation and it constrained every such call. Removing the C ended
it. What breaks is a disagreement between two compilers rather than an
inconsistency inside Zig, and with no clang at the boundary every call is
Zig-to-Zig and both sides agree with each other, whether or not they agree with
the psABI.

### The 32-bit position

A 32-bit target is verified rather than deferred. `wasm32-wasi` runs the suites
and the registered contracts on the 32-bit NaN-boxed layout under wasmtime, in
Debug and in ReleaseSmall, in CI. `riscv32-linux-musl`, `x86-linux-musl` and
`arm-linux-musleabihf` are build jobs, and three things keep them there:

- Code that no configuration analyses is unchecked rather than untested. Zig
  analyses only the comptime branches it selects, so a typo in such a path
  builds clean forever. Three were first type-checked by the first riscv32
  build ever run against this tree: the 32-bit NaN-boxing branch in the
  representation, the 32-bit arm of `lengthv` in the access layer, and the
  pointer-hash else-branch in the comparison layer. All three were correct, and
  nobody knew.
- The Linux host layer at a four-byte pointer is theirs alone. A WASI build
  turns off the event loop, networking, the FFI and the file watcher, so the
  epoll, socket and inotify arms in `runtime/ev/stream.zig`, `runtime/net.zig`
  and `runtime/filewatch.zig` are analysed at 32 bits only by a 32-bit Linux
  build.
- musl's own 32-bit headers are translated only there, which is what the
  translate-c failure above was about.

### Reporting the ABI disagreement upstream

Filing the disagreement upstream is not a blocker. No C function takes a `Janet`
by value here, because the tree compiles no C, so no build of this runtime waits
on a fix. What is left is a disagreement between two compilers that nothing here
exercises.

Filing it would start by rewriting the minimal reproducer, which went with
`probe-8/unionabi.zig`. It is a Zig object exporting `callconv(.c)` functions
that take a `Janet` by value in three shapes, alone, followed by a scalar, and
followed by a second `Janet`, each returning what it received rather than
writing through an out-pointer, since an out-pointer is itself a second argument
and would hide the lone-`Janet` case that works. Every probe covered parameters,
so the `Janet`-by-value return was never isolated.

### The install prefix

Delete the prefix when the run is done, and keep it inside the repository. An
`-Dinstall-tests=true` prefix holds the runtime-test executable, the seven
fixture libraries and the contract and fuzz drivers, all unstripped. In Debug it
measured 40MB, of which `test/` is 29MB and `bin/` and `lib/` about 5MB each.
Earlier revisions of this recipe put it at `../xbuild-arm`, outside the
checkout, where `.gitignore` could not see it and no cleanup step ever ran;
several sessions' worth accumulated in the parent directory and filled the disk.
`/xbuild` is now gitignored, and the `tar` above excludes it so an in-tree
prefix is not copied into the container's size-capped `/work`.

### Copying the tree into the container

Copy the tree selectively, and cap the destination. `.zig-cache` reaches tens of
gigabytes in an ordinary development checkout, and copying it fills the podman
VM's disk partway through. Once the VM is full, podman cannot write the metadata
it needs to delete anything, so it can neither remove the half-written container
nor start its own API service until space is freed by hand. A size-capped
`--tmpfs` destination makes the copy fail immediately and harmlessly instead.

Cross-compiling works because `build.zig` already builds `janet-boot` for the
build host and runs it there; the image it emits is architecture-neutral. Any
driver script should assert the number of binaries and suites it ran, rather
than its exit status, because a test that never executes otherwise looks
identical to a test that passed.

### Current coverage

| Platform             | Method                            | Coverage                                                                                                                                                |
|----------------------|-----------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| macOS ARM64          | native                            | Full: four optimize modes, every feature flag, both value layouts                                                                                       |
| Linux aarch64 musl   | cross-compile, native container   | All 65 contracts, all 42 in-file tests, and 33 of 34 suites, NaN-boxed default. The 34th is named below. Also the second host for the image comparison, and the only thing that has ever executed a Zig contract off macOS   |
| Linux x86-64 musl    | cross-compile, emulated container | Tagged representation only, and each contract is run by name, because `peg` ends the process under emulation. `peg`, `vm_run` and `ffi_core` fail there, and `suite-peg` with them. An `x86_64-macos` build with the same representation passes all four under Rosetta. The cause is not established without x86-64 hardware |
| Windows x86-64 MinGW | cross-compile                     | Builds, and is a matrix entry. Binaries have never been executed                                                                                    |
| Linux riscv32 musl   | cross-compile                     | Builds only, with `x86-linux-musl` and `arm-linux-musleabihf`. Those three compile the 32-bit NaN-boxing and pointer-width branches against musl's 32-bit headers, and the Linux host layer at a four-byte pointer. `wasm32-wasi` is the 32-bit target that runs |
| wasm32-wasi          | cross-compile, wasmtime           | `zig build test` runs every suite and the 56 contracts this configuration registers, in Debug and in ReleaseSmall, in CI. 32-bit NaN-boxed layout, single-threaded, no event loop; networking, the FFI, the file watcher and processes are off with it, which is what leaves nine contracts unregistered. The fork cases in `value_alloc` and `os_surface` are skipped by their own guards |
| Linux glibc, x86-64 and aarch64 | cross-compile, native container | Builds and runs: the driver at exit 0 with no argument and 65 of 65 by name, all 42 in-file tests, 33 of 34 suites, the same one as musl. The no-argument abort in `malloc_consolidate` this row had for two phases was diagnosed and fixed: a contract called into the runtime after its deinit, and glibc's allocator is the check that detected it. Run at a phase gate rather than in CI, which tests Linux against musl |

### The suite that does not pass on Linux

It is not a gap. It fails the same way under musl and under glibc, so it is not
a libc difference:

- `suite-io.janet:241`, one assertion of 88. It asserts that `file/open` with a
  buffer size of `2^53 - 1` raises `failed to set buffer size for file`. Linux's
  `setvbuf` accepts the size where macOS refuses it, so the suite is asserting a
  refusal only one platform makes. The suite skips the same assertion on `wasm`:
  wasi-libc's stdio, which comes from musl, records the size and allocates
  nothing, so no size is refused there, and `2^53 - 1` is not a size at a
  four-byte pointer width.

Fixing it means deciding what the suite should assert on a host that behaves
differently, which is a change to a test's subject rather than to the runtime.

`suite-filewatch.janet` was listed here too, failing six assertions of 79 on
Linux. Those failures were the suite's, not inotify's or the container's. The
probe watcher shared its channel with the event subtests. Removing its watch
queued an `:ignored` event, the next `filewatch/listen` posted it to the
channel, and the first Linux subtest read it in place of `:create`, leaving
every later read one event behind. The probe watcher has its own channel since
the fix at `:118`, and the suite passes 79 of 79. In the container, the runtime
matched C Janet event for event, C Janet failed the same six assertions, and
inotify never merges `:create` and `:close-write`, which differ in mask.

## Five limitations

Five limitations constrain this, none of which are Janet defects:

1. A static musl build cannot load a native module, because musl's static
   `dlopen` is a stub that always fails, so `-Dlinkage=static` turns dynamic
   modules off. CI's Linux jobs build static, since the runner image has no
   musl loader, so CI does not run the native-module test on musl. The
   container recipe above builds dynamic, and `alpine:latest` has the loader,
   so the native-module test runs there.
2. Emulated x86-64 cannot run a NaN-boxed build. Janet packs pointers into
   doubles, which assumes the OS maps user memory inside the low 47 bits; QEMU
   user-mode on an ARM64 host does not honour that, and the runtime segfaults
   while hashing its first symbol. A tagged build (`-Dnanbox=false`) runs
   normally. NaN-boxed x86-64 needs real hardware.

   This was measured after the note above proved too vague to recognise from a
   stack trace. QEMU gives the x86-64 guest the ARM64 host's address
   space: the static image loads low, every allocation lands at `0xffff8…` with
   bit 47 set, and the payload mask is `0x00007FFFFFFFFFFF`, so every unwrap
   discards that bit. The tag survives, so the type test still reports "symbol",
   nothing detects the loss, and the first dereference faults. A probe printed
   `in=0xffff88d00010 out=0x7fff88d00010`, and the faulting address has the same
   shape every run, differing only where the mmap region moves.

   Two controls make this the emulator rather than the port. A build with no Zig
   object in the process at all crashed identically, through the same hash and
   dictionary lookup. And a `-Dnanbox=false` build runs Janet code correctly
   under the same emulator, printing a live pointer with bit 47 set. So this is
   not an x86-64 twin of the riscv32 ABI disagreement in the section above; that
   reading is closed rather than open.

   Two things stay unmeasured. Whether the NaN-boxed binary is sound on real
   x86-64 is inferred from Linux keeping user mappings below 2^47 under 4-level
   paging, not observed. And `QEMU_RESERVED_VA` cannot be used to force a low
   guest address space, because the vsyscall page falls outside any reservation.
   So `-Dnanbox=false` is the substitute control rather than a direct control.

   One practical note: an emulated run takes about a minute, not the ten minutes
   it appears to. The difference is the core dump each crash writes; pass
   `--ulimit core=0` to podman. 3. Emulation also misreports the host CPU, so
   `-Dcpu=baseline` is required. 4. `-Dreduced-os=true` runs 27 of the 34
   suites, and the seven it does not are named in `build.zig`'s `test_suites`
   list with `needs_os = true`. That build registers four `os` bindings,
   `os/exit`, `os/which`, `os/arch` and `os/compiler`, and a Janet file resolves
   its bindings at compile time, so a suite naming a binding it does not have
   refuses to load rather than skipping a case. `suite-os` is about the OS
   library and the other six build fixtures with the filesystem, the environment
   or a subprocess.

   `test/helper.janet` asks `compif` for `os/getenv` and `os/clock` for the same
   reason, and its `rmrf` raises rather than reporting a clean removal where
   there is no filesystem to remove from. The matrix's `reduced os` entry is a
   `full` job because of this; it was a `contracts` job while every suite there
   failed to compile.

5. No Windows binary has ever been executed, here or anywhere.
   `x86_64-windows-gnu` is a `build` entry of `tools/testing/matrix.janet` and
   it passes, so the target compiles and links an `.exe`; nothing has run one.
   Treat Windows as compile-checked and untested.

   This item used to say the opposite, that the Windows cross-compile could not
   build at all, because the translation failed on MinGW's bounds-checked
   `wchar.h` inlines. It stayed on the list after a Zig release fixed it and
   after two increments had recorded an `.exe` coming out. A limitation that has
   quietly stopped being a limitation gives no signal, as a broken instrument
   gives none, and the sign is the same: a finding nobody re-read is not
   evidence that nothing changed.

Because of (2), predictions about x86-64 trap behaviour remain inferred rather
than observed. They should be confirmed on real hardware before any decision
rests on them.

## The leak check

The leak check is `tools/testing/leaks.sh`, and it deliberately does not use
`leaks --atExit`. That mode cannot report on a contract that forks, and three of
the sixty-five do: `os_process`, `os_surface` and `value_alloc` hang under it,
where each completes in under 0.2s unmeasured. `--atExit` inserts
`libLeaksAtExit.dylib`, which interposes `_exit` and `abort` with
`kill(getpid(), SIGSTOP)` followed by the real function, the stop being the
signal to the waiting `leaks` process that there is a heap to scan. A `fork()`ed
child has the dylib in its inherited image and stops itself the same way, and
nothing resumes it, because `leaks` is watching the parent; the parent's
`waitpid` never returns. An `exec`ed child is safe, because the same dylib's
initializer strips itself out of `DYLD_INSERT_LIBRARIES`, so `os/spawn` is not
the hazard and a raw `fork` is.

`tools/testing/leaks.sh` reaches the same heap by a route with no interposer in
it: the contract driver stops itself at the end of `main` when
`JANET_CONTRACT_PAUSE` is set, and the script scans the stopped process with
`leaks <pid>` and then resumes it. It expects zero everywhere, with no
exclusions and no exceptions: `gc_sweep`'s eight, `net_sockets`' three and
`gc_stress`'s deliberate orphan were each a defect and each is fixed, so a
non-zero count anywhere is a non-zero exit rather than a number for a person to
compare.

    ./tools/testing/leaks.sh                  # all 65, about 42 seconds
    ./tools/testing/leaks.sh args_core marsh  # just these

All 65 are measured. macOS only: `leaks` is Apple's, and the container runs
above are what the second platform gets instead.

This section said for a while that the hang was "not a fork", on the evidence of
a process count. The count is three rather than two, and the third process is in
state `T`.

## What the second platform exposed

Introducing a second platform immediately found two `build.zig` defects that a
macOS-only build could not expose, both fixed:

- The Zig subsystem objects were not position-independent, so the shared library
  failed to link on ELF targets with tens of thousands of relocation errors.
  Mach-O is always position independent.
- The bootstrap inherited the host's detected CPU model, which is a portability
  hazard and made image generation depend on the build machine. It now pins a
  baseline CPU while keeping the host's architecture, OS, and ABI.
