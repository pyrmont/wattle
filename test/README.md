# Runtime testing

This document describes the test layers and validation required for runtime
changes. [../src/README.md](../src/README.md) describes implementation rules.
[../res/README.md](../res/README.md) documents the scripts and tools used here.

## Test layers

Validation has six layers. A change must pass the layers relevant to its scope:

- Suites in `test/suite-*.wattle` check behaviour observable by Wattle programs.
  `zig build test` runs them. `suite-lineedit.wattle` observes the REPL through
  a pseudo-terminal, with `res/tools/pty.zig`, whose path `zig build test`
  passes it as an argument. Without the argument, which is the case on Windows
  and under `-Dlineedit=false`, its terminal cases are skipped and its
  plain-reader case still runs.

- Contracts in `test/*.zig` check internal behaviour, with one contract per
  subject. Examples include exact argument-error messages, flag-table order and
  collector block lists. `zig build -Dinstall-tests=true` installs the driver.
  Contracts compile into a second copy of the runtime, call functions by import
  and receive raises as error values.

- In-file `test` blocks check components without runtime initialisation, such as
  classification tables, mode-string parsing and editor layout. `zig build test`
  runs blocks under `src/` as `wattle-runtime-test` and editor blocks under
  `src/client/lineedit/` as `wattle-lineedit-test`.

- The fuzz targets, `test/fuzz.zig`: parser, compiler, marshalling and bytecode,
  run once over their corpora by `zig build test` and as a campaign by
  `zig build fuzz --fuzz`.

- Debug, optimised and sanitizer builds use `res/testing/matrix.wattle`.
  Contracts use `test/expect.zig` so assertions execute in optimised builds.
  `std.debug.assert` uses `unreachable`; in `ReleaseFast` and `ReleaseSmall`,
  the optimiser may remove both that undefined behaviour and its condition.

- Cross-platform builds and container runs, below, plus performance and
  binary-size tracking for central runtime changes.

Changes to specified suite results require a documented decision before the code
changes. Suites specify Wattle's behaviour; upstream behaviour does not
determine their expected results.

## Cross-platform validation

Cross builds require separate build and execution steps. `zig build test` runs
the binaries it builds and cannot run them when the target differs from the
host. Build with `-Dinstall-tests=true` to install contract and fuzz drivers,
the runtime-test executable, native-module fixtures and module-load fixtures
under `<prefix>/test`. Run the installed programs on the target machine.

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
    ...then run every /xb/test/wattle-*-test and every test/suite-*.wattle
       with /xb/bin/wattle...'

rm -rf xbuild/arm
```

### glibc

The glibc recipe uses `-gnu` in place of `-musl` and `debian:trixie` in place of
`alpine:latest`. Run it to check defects detectable only by glibc.

```sh
zig build -Dtarget=aarch64-linux-gnu -Dcpu=baseline \
          -Dinstall-tests=true -p xbuild/gnu --cache-dir /tmp/wattle-xc-gnu

podman run --rm --platform linux/arm64 --tmpfs /work:size=256m \
  -v "$PWD":/src:ro -v "$PWD/xbuild/gnu":/xb:ro debian:trixie sh -c '
    tar -C /src --exclude=.zig-cache --exclude=zig-out --exclude=xbuild \
                --exclude=.git -cf - . | tar -C /work -xf -
    cd /work
    /xb/test/wattle-contract-test         # the driver, all 68 in one process
    for c in $(grep -o "with(list, \"[a-z_0-9]*\"" test/contracts.zig |
               sed "s/.*\"\(.*\)\"/\1/"); do
      /xb/test/wattle-contract-test $c || echo "FAIL $c"
    done
    for s in test/suite-*.wattle; do /xb/bin/wattle $s || echo "FAIL $s"; done'

rm -rf xbuild/gnu /tmp/wattle-xc-gnu
```

### Both libcs

Run both libcs. Each has exposed defects not detected by the other. For example,
glibc checks fastbin chunk alignment and musl does not, so glibc detected heap
corruption that musl did not report.

CI runs static musl builds on x86-64 and aarch64, and native dynamic glibc
builds on x86-64 through `zig build test`. Run the contract driver without
arguments on both libcs. It is the only check that initialises and tears down
the runtime sixty-five times in one process.

### Container requirements

- The podman VM does not mount `/tmp`. `-v /tmp/something:/x:ro` fails with
  `statfs: no such file or directory`. Only paths under the machine's shared
  directories, `$PWD` under `/Users` here, can be bind-mounted, so a helper
  script or a name list has to be written inside the repository or generated in
  the container.

- `--platform linux/arm64` is not optional on an Apple-silicon host when the
  image is multi-arch, or the userland and the cross-built binary disagree.

### 32-bit targets

Three 32-bit Linux targets build successfully. glibc targets also build. The
include-path defect described below caused failures in `x86_64-linux-gnu`,
`aarch64-linux-gnu`, `x86-linux-musl` and `arm-linux-musleabihf`; it was not an
Aro defect.

A project `features.h` on the `-I` path satisfied `#include <features.h>` in
libc headers, because `-I` takes precedence over system search paths. Without
glibc's `__GLIBC_USE` definition, `#if __GLIBC_USE (IEC_60559_BFP_EXT)` became
`0 (...)`, producing 6,662 translation failures. musl's 32-bit headers also lost
feature macros, causing errors in `__REDIR` declarations. Renaming the project
header to `src/host/wattle_features.h` resolved the collision. The runtime no
longer translates headers, and that file is gone.

Retest failures attributed to the toolchain whenever the repository's include
path changes. This requirement is related to rule 47: the header collision was
reported against Aro alongside two actual Aro failures. `x86-windows-gnu` still
fails in mingw's `malloc.h` on `_ALLOCA_S_MARKER` during translation;
`x86_64-windows-gnu` builds.

`.github/workflows/test.yml` cross-builds eight targets. `wasm32-wasi` is a
ninth entry that also runs tests. Include a 32-bit Linux build to type-check the
Linux host layer with four-byte pointers. Zig analyses only selected branches,
so other targets do not check that code.

### Superseded diagnosis

The following diagnosis is incorrect. It is retained as quoted evidence of the
measurement used to attribute the header collision to the toolchain.

> A 32-bit target is reachable, only one is, and it belongs in the set as a
> compile check. Zig 0.16's translate-c front end (Aro) rejects musl's 32-bit
> `time64` `__REDIR` declarations, which appear in `sched.h` and `time.h` and are
> reached by `abi.zig` through `features.h`. That fails the shared translation, so
> on `x86-linux-musl` and `arm-linux-musleabihf` every Zig subsystem fails to
> compile at once. `x86-windows-gnu` fails in `malloc.h` and the shipped glibc
> headers fail in `libc-header-start.h`. `riscv32-linux-musl` is the target that
> translates, because musl's riscv32 port is time64-native and needs no
> redirections. It is in the per-increment set as a compile, which is all it needs
> to be:

```sh
zig build -Dtarget=riscv32-linux-musl -Dcpu=baseline \
          --cache-dir /tmp/wattle-xc-rv -p /tmp/wattle-out-rv
rm -rf /tmp/wattle-xc-rv /tmp/wattle-out-rv
```

Four targets select the 32-bit NaN-boxed layout and the 32-bit arm of every
pointer-width branch. `riscv32-linux-musl`, `x86-linux-musl` and
`arm-linux-musleabihf` build it, and `wasm32-wasi` builds and runs it. Zig
analyses only the branches it selects, so those four are what type-check that
code.

Alpine provides `qemu-riscv32`. Contracts have passed under it, including the
32-bit NaN-boxing cases in `test/value_wrap.zig`. Emulated execution is excluded
from per-increment validation because it requires a container and emulator;
`wasm32-wasi` runs suites and contracts on the same layout without them.

`-Dinstall-tests=true` installs the contract driver under `<prefix>/test`. Use
the aarch64 recipe above with `apk add qemu-riscv32`, and prefix each binary
command with `qemu-riscv32`.

### riscv32 ABI

Zig 0.16 and clang use different numbers of argument registers for an eight-byte
union under riscv32 ILP32D. An isolated measurement showed that passing such a
value from Zig to C displaced subsequent arguments. Calls between Zig-compiled
functions use consistent conventions, regardless of psABI conformance. Removing
the C implementation eliminated this runtime's exposure to the compiler
disagreement.

### 32-bit coverage

CI runs suites and registered contracts on the 32-bit NaN-boxed layout under
wasmtime, in Debug and ReleaseSmall. `riscv32-linux-musl`, `x86-linux-musl` and
`arm-linux-musleabihf` are build jobs. These builds check code excluded from
other targets:

- Zig type-checks only selected comptime branches. The first riscv32 build
  checked three previously unchecked branches: 32-bit NaN-boxing, `lengthv` in
  the access layer and pointer hashing in the comparison layer. All three passed
  type-checking.

- Only 32-bit Linux builds check the Linux host layer with four-byte pointers.
  WASI disables the event loop, networking and FFI, excluding the epoll and
  socket branches in `runtime/ev/stream.zig` and `runtime/net.zig`.

### ABI reproducer

An upstream fix is not required for runtime builds. The tree compiles no C, and
no C function receives `Value` by value.

An upstream report would require recreating the removed `probe-8/unionabi.zig`
reproducer. It used a Zig object exporting `callconv(.c)` functions with three
parameter shapes: a `Value` alone, a `Value` followed by a scalar and a `Value`
followed by another `Value`. Each function returned its input directly. An
output pointer would add a parameter and prevent testing the working
single-`Value` case. The probes isolated parameter passing; returning a `Value`
by value was not isolated.

### Install prefix

Keep the prefix inside the repository and delete it after the run.
`-Dinstall-tests=true` installs the runtime-test executable, seven fixture
libraries and contract and fuzz drivers, all unstripped. A Debug installation
measured 40MB: 29MB under `test/` and about 5MB each under `bin/` and `lib/`.
Repeated installations at `../xbuild-arm` filled the parent directory because
that path was outside `.gitignore` and had no cleanup step. `/xbuild` is
ignored, and the recipe's `tar` command excludes it from the container's
size-capped `/work`.

### Container copy

Exclude build caches and cap the destination size. `.zig-cache` can reach tens
of gigabytes and fill the podman VM during a copy. A full VM prevents podman
from writing deletion metadata, removing the incomplete container or starting
its API service. Recovery requires freeing space manually. A size-capped
`--tmpfs` destination fails the copy before the VM disk fills.

`build.zig` builds and runs `wattle-boot` on the build host. Its image is
architecture-neutral, allowing cross-compilation. Driver scripts must check how
many binaries and suites ran as well as their exit status. Exit status alone
does not distinguish a skipped test from a passing test.

### Coverage

| Platform             | Method                            | Coverage                                                                                                                                                |
|----------------------|-----------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| macOS ARM64          | native                            | Full: four optimize modes, every feature flag, both value layouts                                                                                       |
| Linux aarch64 musl | cross-compile, native container | All 68 contracts, 49 in-file tests and 36 of 36 suites, with one assertion skipped as described below. Default NaN-boxed representation. This target provides the second host for image comparison and recorded Zig contract execution outside macOS. |
| Linux x86-64 musl | cross-compile, emulated container | Tagged representation only. Contracts run by name because `peg` terminates the process under emulation. `peg`, `vm_run`, `ffi_core` and `suite-peg` fail. An `x86_64-macos` build with the same representation passes all four under Rosetta. Establishing the cause requires x86-64 hardware. |
| Windows x86-64 | native | `zig build test` runs every suite and contract on `windows-latest`; `suite-ev` reports 892 of 892. Two blocks requiring a parked socket write are excluded because overlapped sends to loopback peers do not park. `x86_64-windows-gnu` remains a build-only matrix entry. |
| Linux riscv32 musl | cross-compile | Build-only, along with `x86-linux-musl` and `arm-linux-musleabihf`. These three targets compile 32-bit NaN-boxing and pointer-width branches against musl's 32-bit headers, including the Linux host layer with four-byte pointers. `wasm32-wasi` provides 32-bit execution coverage. |
| wasm32-wasi | cross-compile, wasmtime | CI runs `zig build test` in Debug and ReleaseSmall, including every suite and 59 registered contracts. Uses the 32-bit NaN-boxed layout and a single thread. The event loop, networking, FFI and processes are disabled, leaving seven contracts unregistered. Guards skip fork cases in `value_alloc` and `os_surface`. |
| Linux glibc, x86-64 and aarch64 | cross-compile, native container | The driver exits 0 without arguments and passes 68 of 68 contracts by name. All 49 in-file tests and 36 of 36 suites pass, with the same assertion skipped as on musl. glibc's allocator detected a fixed contract defect: a runtime call after deinit caused an abort in `malloc_consolidate`. CI runs `zig build test` natively on x86-64 glibc. |

### Linux assertion skip

No suite fails on Linux. One assertion is skipped there, on both libcs:

- `suite-io.wattle:246`, one assertion of 88. It asserts that `file/open` with a
  buffer size of `2^53 - 1` raises `failed to set buffer size for file`. The
  runtime passes `setvbuf` the size and no buffer. Darwin's `setvbuf` refuses a
  size it cannot allocate. glibc's and musl's ignore the size when handed no
  buffer: glibc allocates its default buffer and musl keeps its own. No size is
  refused, so the expected error cannot be tested on Linux. The assertion is
  also skipped on `wasm`: wasi-libc uses musl's stdio, and four-byte pointers
  cannot represent `2^53 - 1` as a size.

The skip is keyed on `(os/which)` rather than on the libc because both Linux
libcs behave alike. In `debian:trixie`, glibc 2.41 and a static musl build both
returned 0 from `setvbuf(f, NULL, _IOFBF, size)` for every size up to
`SIZE_MAX`, and the buffer in place stayed at 4,096 and 1,024 bytes. musl's
`setvbuf.c` uses a buffer only when one is passed.

## Line endings

A process on Windows writes each newline on its standard output and standard
error as `\r\n`, because the C library opens those streams in text mode. A file
opened with `file/open` is binary on every platform and is not translated.
`.gitattributes` sets `eol=lf` on the sources.

A test that compares what a child process wrote to a standard stream spells each
newline as `line-end`. `test/helper.wattle` defines it, and every suite imports
it. A step in `build.zig` that compares a stream uses `streamEol`. Neither
normalises the text, so a `\r` that appears on another platform fails the test.

A value that a program builds is not translated. An error message, a string
before it is written, and the text of a file read in binary mode all have `\n`,
so a test of such a value spells the newline `\n`. `pkg-run` replaces `\r\n`
with `\n` in what a tool wrote to its standard error, so that the message it
raises is the same on every platform.

## Limitations

Five platform and configuration limitations affect validation:

1. A static musl build cannot load a native module, because musl's static
   `dlopen` is a stub that always fails, so `-Dlinkage=static` turns dynamic
   modules off. CI's musl jobs build static, since the runner image has no musl
   loader, so CI runs the native-module test on glibc only. The container recipe
   above builds dynamic, and `alpine:latest` has the loader, so the
   native-module test runs there.

2. Emulated x86-64 cannot run a NaN-boxed build. The NaN-boxed layout packs
   pointers into doubles, which assumes the OS maps user memory inside the low
   47 bits; QEMU user-mode on an ARM64 host does not honour that, and the
   runtime segfaults while hashing its first symbol. A tagged build
   (`-Dnanbox=false`) runs normally. NaN-boxed x86-64 needs real hardware.

   In measurements, QEMU gave the x86-64 guest the ARM64 host's address space:
   the static image loads low, every allocation lands at `0xffff8…` with bit 47
   set, and the payload mask is `0x00007FFFFFFFFFFF`, so every unwrap discards
   that bit. The tag survives, so the type test still reports "symbol", the loss
   is undetected, and the first dereference faults. A probe printed
   `in=0xffff88d00010 out=0x7fff88d00010`, and the faulting address has the same
   shape every run, differing only where the mmap region moves.

   Two controls attribute the failure to emulation. A build with no Zig object
   in the process crashed in the same hash and dictionary lookup. A
   `-Dnanbox=false` build ran Wattle code under the same emulator and printed a
   live pointer with bit 47 set. These results distinguish the failure from the
   riscv32 ABI disagreement described above.

   Two limits remain on this evidence. Correct NaN-boxed execution on real
   x86-64 is inferred from Linux user mappings below 2^47 with 4-level paging;
   it has not been observed. `QEMU_RESERVED_VA` cannot force a low guest address
   space because the vsyscall page is outside any reservation. The
   `-Dnanbox=false` build is therefore an indirect control.

   An emulated run takes about a minute. Writing a core dump after each crash
   can increase this to ten minutes. Pass `--ulimit core=0` to podman.

3. Emulation misreports the host CPU. Use `-Dcpu=baseline`.

4. `-Dreduced-os=true` runs 29 of 36 suites. The seven excluded suites have
   `needs_os = true` in `build.zig`'s `test_suites`. This build registers four
   `os` bindings: `os/exit`, `os/which`, `os/arch` and `os/compiler`. Wattle
   resolves bindings at compile time, so suites referencing omitted bindings
   cannot load. `suite-os` tests the OS library; the other six build fixtures
   requiring filesystems, environment variables or subprocesses.

   `test/helper.wattle` uses `compif` for `os/getenv` and `os/clock`. Its `rmrf`
   raises when filesystem operations are unavailable. The matrix's `reduced os`
   entry runs a `full` job to check suite compilation as well as contracts.

5. Two blocks in `suite-ev` do not run on Windows. An overlapped send to a
   loopback peer does not park: the transport accepts the bytes with the peer
   having read none of them, so the two blocks that need a parked socket write
   are guarded off. `suite-net` records the same behaviour for two 32MB floods.
   Everything else in the suites and the contracts runs there.

   Windows cross-compilation and native execution are both available. Zig
   supports translation of MinGW's bounds-checked `wchar.h` inlines, and CI
   executes the Windows binary.

Because of limitation 2, x86-64 trap behaviour remains inferred. Confirm it on
real hardware before using it as the basis for a decision.

## Leak checks

`res/testing/leaks.sh` avoids `leaks --atExit` because that mode hangs on
contracts that fork. Three of the sixty-five contracts are affected:
`os_process`, `os_surface` and `value_alloc`. Each completes in under 0.2s
without leak measurement. `--atExit` inserts `libLeaksAtExit.dylib`, which
interposes `_exit` and `abort` with `kill(getpid(), SIGSTOP)` followed by the
real function, the stop being the signal to the waiting `leaks` process that
there is a heap to scan. A `fork()`ed child has the dylib in its inherited image
and stops itself the same way, and nothing resumes it, because `leaks` is
watching the parent; the parent's `waitpid` never returns. An `exec`ed child is
safe, because the same dylib's initializer strips itself out of
`DYLD_INSERT_LIBRARIES`, so `os/spawn` is not the hazard and a raw `fork` is.

With `WATTLE_CONTRACT_PAUSE` set, the contract driver stops at the end of
`main`. `res/testing/leaks.sh` scans it with `leaks <pid>` and resumes it. This
requires no interposer. Every contract must report zero leaks; any non-zero
count causes a non-zero exit. Fixed defects account for the eight leaks in
`gc_sweep`, three in `net_sockets` and deliberate orphan in `gc_stress`. None is
exempted.

    ./res/testing/leaks.sh                  # all 68, about 42 seconds
    ./res/testing/leaks.sh args_core marsh  # just these

The script measures all 68 contracts. It requires macOS and Apple's `leaks`. Use
the container runs above for second-platform validation.

A hanging `leaks --atExit` run has three processes, not two. The third is a
forked child in state `T`, stopped while `leaks` monitors the parent.

## Cross-platform build requirements

Two build requirements are not detectable by macOS-only testing:

- Zig subsystem objects must be position independent. Otherwise, ELF shared
  libraries fail to link with tens of thousands of relocation errors. Mach-O is
  always position independent.

- The bootstrap must use a baseline CPU while preserving the host's
  architecture, OS and ABI. Using the detected CPU model makes image generation
  depend on the build machine and can fail on other hosts.
