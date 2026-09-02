# How this runtime is tested

*The layers, what each is for, and what a change owes before it is believed.
[../DESIGN.md](../DESIGN.md) section 12 has the Janet behaviours this runtime
kept and the ones it changed; [../src/zig/README.md](../src/zig/README.md) the
rules the runtime holds itself to; [../tools/README.md](../tools/README.md) the
instruments named below.*

Six layers, and a change is believed when the ones it touches pass:

- **The Janet suites**, `test/suite-*.janet`, run by `zig build test`. What a
  Janet program can observe, asserted the way a Janet program would.
- **The contracts**, `test/*.zig`, one per subject, run by the driver
  `zig build` installs. What no Janet program can reach: an argument fault's
  exact message, a flag table's order, a collector's block list. Each is
  compiled *into* a second copy of the runtime, so it calls its subject by
  import and a raise arrives as a value.
- **The in-file `test` blocks** under `src/zig`, run by `zig build test` as
  `janet-runtime-test`. Interior facts with no runtime under them — a
  classification table, a mode-string parser.
- **The fuzz targets**, `test/fuzz.zig`: parser, compiler, marshalling and
  bytecode, run once over their corpora by `zig build test` and as a campaign
  by `zig build fuzz --fuzz`.
- **Debug, optimized and sanitizer builds**, through
  `tools/testing/matrix.janet`. Optimized builds must keep the contracts'
  assertions live, which is what `test/expect.zig` is for: `std.debug.assert`
  is `unreachable`, and in `ReleaseFast` and `ReleaseSmall` that is undefined
  behaviour the optimizer may delete along with the condition.
- **Cross-platform builds and container runs**, below, plus performance and
  binary-size tracking for central runtime changes.

A compatibility failure should be reduced to a focused regression test before
it is fixed.

### Cross-platform validation without CI

A second platform can be exercised locally, before any public CI exists.  `zig
build test` cannot do this on its own: it runs what it builds, which is
impossible when the target is not the host. Build with `-Dinstall-tests=true`
instead, which installs the contract, fuzz and runtime test executables and the
dynamic native module into `<prefix>/test`, then run them on the target
machine.

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

**The glibc recipe.** It was run ad hoc and not written down once, and had to
be reconstructed to diagnose a defect only that libc detects. It is the musl
recipe with two substitutions — `-gnu` for `-musl`, `debian:trixie` for
`alpine:latest`:

```sh
zig build -Dtarget=aarch64-linux-gnu -Dcpu=baseline \
          -Dinstall-tests=true -p xbuild/gnu --cache-dir /tmp/janet-xc-gnu

podman run --rm --platform linux/arm64 --tmpfs /work:size=256m \
  -v "$PWD":/src:ro -v "$PWD/xbuild/gnu":/xb:ro debian:trixie sh -c '
    tar -C /src --exclude=.zig-cache --exclude=zig-out --exclude=xbuild \
                --exclude=.git -cf - . | tar -C /work -xf -
    cd /work
    /xb/bin/janet-zig-contract-test          # the driver, all 65 in one process
    for c in $(grep -o "with(list, \"[a-z_0-9]*\"" test/contracts.zig |
               sed "s/.*\"\(.*\)\"/\1/"); do
      /xb/bin/janet-zig-contract-test $c || echo "FAIL $c"
    done
    for s in test/suite-*.janet; do /xb/bin/janet $s || echo "FAIL $s"; done'

rm -rf xbuild/gnu /tmp/janet-xc-gnu
```

**Run both libcs, not one.** They are not interchangeable and each has found
something the other cannot see. glibc's allocator checks fastbin chunk
alignment and musl's does not, which is the whole reason a heap corruption
surfaced there first; musl is what CI tests, because that corruption made the
glibc driver run abort. The contract driver with **no argument** is
the interesting invocation on either — it is the only thing in the tree that
initialises and tears the runtime down sixty-five times in one process, and
that is a workload nothing else here has.

Two practical traps, both cost a cycle to rediscover:

- **The podman VM does not mount `/tmp`.** `-v /tmp/something:/x:ro` fails with
  `statfs: no such file or directory`. Only paths under the machine's shared
  directories — `$PWD` under `/Users` here — can be bind-mounted, so a helper
  script or a name list has to be written inside the repository or generated
  in the container.
- **`--platform linux/arm64` is not optional** on an Apple-silicon host when
  the image is multi-arch, or the userland and the cross-built binary disagree.

**Three 32-bit targets are reachable, and glibc is too. The paragraph below
said one and none, and it was wrong for two phases.** The cause was our own
include path: a `features.h` of ours sat on the `-I` path, `-I` beats the system
search path, and it therefore answered `#include <features.h>` for **every libc
header that asked**. (It is `src/zig/janet_features.h` now, and the rename is
what closes the hazard.) glibc's `features.h` is what defines
`__GLIBC_USE`, so `#if __GLIBC_USE (IEC_60559_BFP_EXT)` became `0 (...)` and the
translation failed 6,662 times; musl's 32-bit headers lost their own feature
macros the same way, and the `__REDIR` declarations named below were the
symptom rather than the cause. Renaming ours to `janet_features.h` opened
`x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86-linux-musl` and
`arm-linux-musleabihf` in one change.

The rule is worth more than the fix, and it is rule 47's family: **a failure
recorded as the toolchain's should be re-tested whenever your own include path
changes.** This one was filed against Aro, sat beside two genuine Aro failures,
and was ours all along. What is still genuinely translate-c's is
`x86-windows-gnu`, which fails in mingw's `malloc.h` on `_ALLOCA_S_MARKER`;
`x86_64-windows-gnu` builds.

The eight targets `.github/workflows/test.yml` builds are the current set. A
32-bit one still belongs in it as a **compile**, for the reason the original
paragraph gave: Zig analyses only the branches it selects, so nothing else
type-checks `JANET_NANBOX_32`.

*The superseded text follows, because the measurement in it is what made the
wrong diagnosis plausible.*

**A 32-bit target is reachable, only one is, and it belongs in the set as a
compile check.** Zig 0.16's translate-c front
end (Aro) rejects musl's 32-bit `time64` `__REDIR` declarations, which appear in
`sched.h` and `time.h` and are reached by `abi.zig` through `features.h`. That
fails the shared translation, so on `x86-linux-musl` and `arm-linux-musleabihf`
*every* Zig subsystem fails to compile at once. `x86-windows-gnu` fails in
`malloc.h` and the shipped glibc headers fail in `libc-header-start.h`.
`riscv32-linux-musl` is the one that translates, because musl's riscv32 port is
time64-native and needs no redirections. It is in the per-increment set as a
**compile**, which is all it needs to be:

```sh
zig build -Dtarget=riscv32-linux-musl -Dcpu=baseline \
          --cache-dir /tmp/janet-xc-rv -p /tmp/janet-out-rv
rm -rf /tmp/janet-xc-rv /tmp/janet-out-rv
```

That is not a formality. It is the only target that selects the 32-bit
NaN-boxed layout and the 32-bit arm of every pointer-width branch, and Zig
analyses only the branches it selects — so this build is the only thing anywhere
that type-checks that code.

The binaries *can* be run: Alpine ships `qemu-riscv32`, and the contracts passed
under it on 2026-08-20, which is how the 32-bit NaN-boxing arm of
`test/value_wrap.zig` was validated. **That is deliberately not part of the
per-increment set.** It costs a `-Dinstall-tests=true` prefix, a container and
an emulator, and what it buys over the compile is one arm of one contract. The
recipe is the `-Dinstall-tests=true` one above under the aarch64 example, with
`apk add qemu-riscv32` and `qemu-riscv32` in front of each binary.

*One riscv32 hazard is closed rather than open, and it is worth not
rediscovering.* Zig 0.16 and clang disagree about how many argument registers an
eight-byte union consumes under riscv32 ILP32D, so a value passed by value
across a Zig-to-C call displaced every argument behind it. That was measured in
isolation and it constrained every such call. **Removing the C dissolved it:**
what breaks is a disagreement between *two* compilers, not an inconsistency
inside Zig, and with no clang at the boundary every call is Zig-to-Zig and both
sides agree with each other — whether or not they agree with the psABI.

**A 32-bit target is a deferred goal rather than a non-goal**, so the deferral
is split deliberately rather than taken wholesale. Two costs behave differently
and only one of them grows while nothing is done:

- **Code that is never analysed grows, and that is checked continuously.** Zig
  analyses only the comptime branches it selects, so on a 64-bit host every
  32-bit path in the tree is not merely untested but *never compiled* — a typo
  in one builds clean forever. Three were first type-checked on 2026-08-20 by
  the first riscv32 build ever run against this tree: the 32-bit NaN-boxing
  branch in the representation, the 32-bit arm of `lengthv` in the access layer,
  and the pointer-hash else-branch in the comparison layer. All three were
  correct, and nobody knew. That is why **`riscv32-linux-musl` is in the
  per-increment cross-compile set** — a compile, on the same footing and for
  the same reason as the Windows one.
- **Behavioural verification does not grow, so it waits.** Running anything
  there needs the ABI disagreement resolved, which no amount of work in this
  tree achieves, so deferring it costs nothing that doing it later would not
  cost anyway. No emulation, no `qemu-riscv32` in the per-increment set.

**Deferred, deliberately, on 2026-08-20: reporting the ABI disagreement
upstream.** This is the one cost that cannot be compressed later — an upstream
fix has a lead time of months, and a 32-bit Claret needs one, so filing it late
means waiting while blocked. The minimal reproducer was `probe-8/unionabi.zig`
and went with that directory, so filing now starts by rewriting it: a Zig object
exporting `callconv(.c)` functions that take a `Janet` by value in three shapes
— alone, followed by a scalar, followed by a second `Janet` — each *returning*
what it received rather than writing through an out-pointer, since an
out-pointer is itself a second argument and would hide the lone-`Janet` case
that works. The measurements above are what it printed.

What is *not* measured is the `Janet`-by-value **return**. Every probe here
covers parameters. Returns appear sound — a riscv32 build with only
`-Dvalue-wrap=zig` ran dozens of `Janet`-returning Zig calls before its first
failure, which was a two-argument predicate — but that is evidence rather than
isolation, and it belongs with the deferred behavioural work.

**Delete the prefix when the run is done, and keep it inside the repository.**
An `-Dinstall-tests=true` prefix is about 2.5GB, because it installs an
unstripped binary for every contract test. Earlier revisions of this recipe put
it at `../xbuild-arm`, outside the checkout, where `.gitignore` could not see
it and no cleanup step ever ran; several sessions' worth accumulated in the
parent directory and filled the disk. `/xbuild` is now gitignored, and the
`tar` above excludes it so an in-tree prefix is not copied into the container's
size-capped `/work`.

Copy the tree selectively, and cap the destination. `.zig-cache` reaches tens
of gigabytes in an ordinary development checkout, and copying it fills the
podman VM's disk partway through. That failure is worse than it looks: once the
VM is full, podman cannot write the metadata it needs to delete anything, so it
can neither remove the half-written container nor start its own API service
until space is freed by hand. A size-capped `--tmpfs` destination makes the
copy fail immediately and harmlessly instead.

Cross-compiling works because `build.zig` already builds `janet-boot` for the
build host and runs it there; the image it emits is architecture-neutral. Any
driver script should assert the number of binaries and suites it ran, not
merely its exit status — a test that never executes otherwise looks identical
to one that passed.

Current coverage:

| Platform             | Method                            | Coverage                                                                                                                                                |
|----------------------|-----------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| macOS ARM64          | native                            | Full: four optimize modes, every feature flag, both value layouts                                                                                       |
| Linux aarch64 musl   | cross-compile, native container   | **All 65 contracts, all 42 in-file tests, and 32 of 34 suites**, NaN-boxed default -- the two are named below. Also the second host for the image comparison, and the only thing that has ever executed a Zig contract off macOS   |
| Linux x86-64 musl    | cross-compile, emulated container | Tagged representation only; `asm_decode` segfaults under emulation, so individual contracts are run rather than the sweep                               |
| Windows x86-64 MinGW | cross-compile                     | **Builds**, and is a matrix entry. Binaries have never been executed                                                                                    |
| Linux riscv32 musl   | cross-compile                     | Builds only. One of **three** 32-bit targets -- `x86-linux-musl` and `arm-linux-musleabihf` build too -- which are what compile the 32-bit NaN-boxing and pointer-width branches; binaries deliberately unexecuted, see below |
| Linux glibc, x86-64 and aarch64 | cross-compile, native container | **Builds and runs**: the driver at exit 0 with no argument *and* 65 of 65 by name, all 42 in-file tests, 32 of 34 suites -- the same two as musl. The no-argument abort in `malloc_consolidate` this row carried for two phases was diagnosed and fixed: a contract called into the runtime after its deinit, and glibc was the allocator that noticed. Run at a phase gate rather than in CI, which tests Linux against musl |


**The two suites that do not pass on Linux, and why they are not a gap.** They
are the same two under musl and under glibc, so neither is a libc difference:

- `suite-io.janet:236`, one assertion of 85. It asserts that `file/open` with a
  buffer size of `2^53 - 1` raises `failed to set buffer size for file`. Linux's
  `setvbuf` accepts the size where macOS refuses it, so the suite is asserting a
  refusal only one platform makes.
- `suite-filewatch.janet`, six assertions of 77, all of them inotify event
  *ordering*: the suite asserts `:create` and `:close-write` as separate events
  in order, and under the container's filesystem they coalesce and the previous
  subtest's events are still queued when the next reads them. The 71 covering
  argument handling, flag decoding and the watcher's life cycle pass.

Fixing either means deciding what the suite should assert on a host that behaves
differently, which is a change to a test's subject rather than to the runtime.

Five limitations constrain this, none of which are Janet defects:

1. Zig links musl targets statically by default, and musl's static `dlopen` is a
   stub that always fails. The native-module test therefore cannot run this way;
   dynamic loading needs a dynamically linked build or a real target machine.
2. Emulated x86-64 cannot run a NaN-boxed build. Janet packs pointers into
   doubles, which assumes the OS maps user memory inside the low 47 bits; QEMU
   user-mode on an ARM64 host does not honor that, and the runtime segfaults
   while hashing its first symbol. A tagged build (`-Dnanbox=false`) runs
   normally. NaN-boxed x86-64 needs real hardware.

   Measured on 2026-08-20, after the note above proved too vague to recognise
   from a stack trace. QEMU hands the x86-64 guest the ARM64 host's address
   space: the static image loads low, every allocation lands at `0xffff8…` with
   bit 47 set, and the payload mask is `0x00007FFFFFFFFFFF`, so every unwrap
   discards that bit. The *tag* survives — the type test still answers "symbol" —
   so nothing detects the loss and the first dereference faults. A probe printed
   `in=0xffff88d00010 out=0x7fff88d00010`, and the faulting address has the same
   shape every run, differing only where the mmap region moves.

   **Two controls make this the emulator rather than the port.** A build with
   no Zig object in the process at all crashed identically, through the same
   hash and dictionary lookup. And a `-Dnanbox=false` build runs Janet code
   correctly under the same emulator, printing a live pointer with bit 47 set.
   So this is *not* an x86-64 twin of the riscv32 ABI disagreement in the
   section below; that reading is closed rather than open.

   Two things stay unmeasured. Whether the NaN-boxed binary is sound on real
   x86-64 is inferred from Linux keeping user mappings below 2^47 under 4-level
   paging, not observed. And `QEMU_RESERVED_VA` cannot be used to force a low
   guest address space, because the vsyscall page falls outside any reservation
   — so `-Dnanbox=false` is the substitute control rather than the direct one.

   One practical note: an emulated run takes about a minute, not the ten it
   appears to. The difference is the core dump each crash writes; pass
   `--ulimit core=0` to podman.
3. Emulation also misreports the host CPU, so `-Dcpu=baseline` is required.
4. `-Dreduced-os=true` runs **28 of the 35 suites**, and the seven it does not
   are named in `build.zig`'s `test_suites` list with `needs_os = true`. That
   build registers four `os` bindings — `os/exit`, `os/which`, `os/arch` and
   `os/compiler` — and a Janet file resolves its bindings at *compile* time, so
   a suite naming one it does not have refuses to load rather than skipping a
   case. `suite-os` is about the OS library and the other six build fixtures
   with the filesystem, the environment or a subprocess.

   `test/helper.janet` asks `compif` for `os/getenv` and `os/clock` for the
   same reason, and its `rmrf` raises rather than reporting a clean removal
   where there is no filesystem to remove from. The matrix's `reduced os` entry
   is a `full` job because of this; it was a `contracts` job while every suite
   there failed to compile.

5. **No Windows binary has ever been executed**, here or anywhere.
   `x86_64-windows-gnu` is a `build` entry of `tools/testing/matrix.janet` and it
   passes, so the target compiles and links an `.exe`; nothing has run one.
   Treat Windows as compile-checked and untested.

   This item used to say the opposite — that the Windows cross-compile could
   not build at all, because the translation failed on MinGW's bounds-checked
   `wchar.h` inlines — and it stayed on the list after a Zig release fixed it
   and after two increments had recorded an `.exe` coming out. **A
   limitation that has quietly stopped being one is silent in exactly the way a
   broken instrument is**, and the tell is the same: an answer nobody re-read
   is not an answer that stopped moving.

**The leak check is `tools/testing/leaks.sh`, and it deliberately does not use
`leaks --atExit`.** That mode cannot report on a contract that forks, and three
of the sixty-five do: `os_process`, `os_surface` and `value_alloc` hang under
it, where each completes in under 0.2s unmeasured. `--atExit` inserts
`libLeaksAtExit.dylib`, which interposes `_exit` and `abort` with
`kill(getpid(), SIGSTOP)` followed by the real one — the stop being how the
waiting `leaks` process is told there is a heap to scan. A `fork()`ed child
carries the dylib in its inherited image and stops itself the same way, and
nothing resumes it, because `leaks` is watching the parent; the parent's
`waitpid` never returns. An `exec`ed child is safe, because the same dylib's
initializer strips itself out of `DYLD_INSERT_LIBRARIES` — so `os/spawn` is not
the hazard and a raw `fork` is.

`tools/testing/leaks.sh` reaches the same heap by a route with no interposer in it: the
contract driver stops *itself* at the end of `main` when `JANET_CONTRACT_PAUSE`
is set, and the script scans the stopped process with `leaks <pid>` and then
resumes it. It expects zero everywhere, with no exclusions and no exceptions: `gc_sweep`'s
eight, `net_sockets`' three and `gc_stress`'s deliberate orphan were each a
defect and each is fixed, so a non-zero count anywhere is a non-zero exit rather
than a number for a person to compare.

    ./tools/testing/leaks.sh                  # all 65, about 42 seconds
    ./tools/testing/leaks.sh args_core marsh  # just these

**All 65 are measured.** macOS only: `leaks` is Apple's, and the container
checks below are what the second platform gets instead.

*This section said for a while that the hang was "not a fork", on the evidence
of a process count. The count is three rather than two, and the third process is
in state `T`.*

Because of (2), predictions about x86-64 trap behaviour remain inferred rather
than observed. They should be confirmed on real hardware before any decision
rests on them.

Introducing a second platform immediately found two `build.zig` defects that a
macOS-only build could not expose, both fixed:

- The Zig subsystem objects were not position-independent, so the shared library
  failed to link on ELF targets with tens of thousands of relocation errors.
  Mach-O is always position independent.
- The bootstrap inherited the host's detected CPU model, which is a portability
  hazard and made image generation depend on the build machine. It now pins a
  baseline CPU while keeping the host's architecture, OS, and ABI.
