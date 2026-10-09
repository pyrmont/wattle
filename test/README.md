# Runtime testing

This document describes the test layers and validation required for runtime
changes. [../src/README.md](../src/README.md) describes implementation rules.
[../res/README.md](../res/README.md) documents the scripts and tools used here.

## Test layers

A change must pass the validation layers relevant to its scope:

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
    /xb/test/wattle-contract-test         # all contracts in one process
    for c in $(grep -o "with(list, \"[a-z_0-9]*\"" test/contracts.zig |
               sed "s/.*\"\(.*\)\"/\1/"); do
      /xb/test/wattle-contract-test $c || echo "FAIL $c"
    done
    for s in test/suite-*.wattle; do /xb/bin/wattle $s || echo "FAIL $s"; done'

rm -rf xbuild/gnu /tmp/wattle-xc-gnu
```

### Both libcs

Run both libcs because their allocator checks differ. For example, glibc
checks fastbin chunk alignment and musl does not.

CI runs static musl builds on x86-64 and aarch64, and native dynamic glibc
builds on x86-64 through `zig build test`. Run the contract driver without
arguments on both libcs. It is the only check that initialises and tears down
the runtime repeatedly in one process.

### Container requirements

- The podman VM does not mount `/tmp`. `-v /tmp/something:/x:ro` fails with
  `statfs: no such file or directory`. Only paths under the machine's shared
  directories, `$PWD` under `/Users` here, can be bind-mounted, so a helper
  script or a name list has to be written inside the repository or generated in
  the container.

- `--platform linux/arm64` is not optional on an Apple-silicon host when the
  image is multi-arch, or the userland and the cross-built binary disagree.

### 32-bit coverage

Include a 32-bit Linux build to check the Linux host layer with four-byte
pointers. Zig analyses only selected comptime branches. These builds also
check 32-bit NaN-boxing, value access and pointer hashing.

CI runs suites and registered contracts under wasmtime in Debug and
ReleaseSmall. WASI uses the 32-bit NaN-boxed layout, but disables the event
loop, networking and FFI. It cannot check the Linux epoll and socket branches
in `runtime/ev/stream.zig` and `runtime/net.zig`.

CI also runs `riscv32-linux-musl` under QEMU, with static linkage and FFI
disabled. This configuration tests the 32-bit layout with the event loop.
Build-only jobs check riscv32 with FFI enabled, `x86-linux-musl` and
`arm-linux-musleabihf`.

A riscv32 compile check can use a temporary cache and prefix:

```sh
zig build -Dtarget=riscv32-linux-musl -Dcpu=baseline \
          --cache-dir /tmp/wattle-xc-rv -p /tmp/wattle-out-rv
rm -rf /tmp/wattle-xc-rv /tmp/wattle-out-rv
```

Local per-increment validation does not require emulated riscv32 execution.
WASI provides execution coverage for the same value layout without QEMU or a
container.

For container execution, Alpine provides `qemu-riscv32`. Build with
`-Dinstall-tests=true` and use the aarch64 recipe above with
`apk add qemu-riscv32`. Prefix each binary command with `qemu-riscv32`.

Retest failures attributed to the toolchain whenever the repository's include
path changes. Project headers on an `-I` path can shadow libc headers.

### Install prefix

Keep the prefix inside the repository and delete it after the run.
`-Dinstall-tests=true` installs the runtime-test executable, fixture
libraries and contract and fuzz drivers, all unstripped.
`/xbuild` is ignored, and the recipe's `tar` command excludes it from the
container's size-capped `/work`.

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

| Platform                        | Method                            | Coverage                                                                                                                                                                                                                                                                                                          |
| ------------------------------- | --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| macOS ARM64                     | native                            | All optimize modes, every feature flag, both value layouts                                                                                                                                                                                                                                                        |
| Linux aarch64 musl              | cross-compile, native container   | Contracts, in-file tests and suites, with the assertion skip described below. Default NaN-boxed representation. This target provides a second host for image comparison.                                                                                                                                          |
| Linux x86-64 musl               | cross-compile, emulated container | Tagged representation only. Contracts run by name because `peg` terminates the process under emulation. `peg`, `vm_run`, `ffi_core` and `suite-peg` fail. These emulated failures require verification on native x86-64 hardware.                                                                                 |
| Windows x86-64                  | native                            | `zig build test` runs every suite and contract on `windows-latest`. Cases requiring a parked socket write are excluded because overlapped sends to loopback peers do not park. `x86_64-windows-gnu` remains a build-only matrix entry.                                                                            |
| Linux riscv32 musl              | cross-compile, QEMU               | CI runs suites and contracts with static linkage and FFI disabled. A separate build checks the FFI configuration. Includes the 32-bit NaN-boxed layout and Linux host layer with four-byte pointers.                                                                                                              |
| wasm32-wasi                     | cross-compile, wasmtime           | CI runs `zig build test` in Debug and ReleaseSmall, including suites and registered contracts. Uses the 32-bit NaN-boxed layout and a single thread. The event loop, networking, FFI and processes are disabled, so their contracts are not registered. Guards skip fork cases in `value_alloc` and `os_surface`. |
| Linux glibc, x86-64 and aarch64 | cross-compile, native container   | Contracts, in-file tests and suites, with the same assertion skipped as on musl. CI runs `zig build test` natively on x86-64 glibc.                                                                                                                                                                               |

### Linux assertion skip

Both Linux libcs skip the following assertion:

- `suite-io.wattle` asserts that `file/open` with a
  buffer size of `2^53 - 1` raises `failed to set buffer size for file`. The
  runtime passes `setvbuf` the size and no buffer. Darwin's `setvbuf` refuses a
  size it cannot allocate. glibc's and musl's ignore the size when handed no
  buffer: glibc allocates its default buffer and musl keeps its own. No size is
  refused, so the expected error cannot be tested on Linux. The assertion is
  also skipped on `wasm`: wasi-libc uses musl's stdio, and four-byte pointers
  cannot represent `2^53 - 1` as a size.

The skip is keyed on `(os/which)` rather than on the libc because both Linux
libcs behave alike. Both return success from `setvbuf` without changing the
buffer size when no buffer is passed.

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

The following platform and configuration limitations affect validation:

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

   QEMU allocations can have bit 47 set. Unwrapping a NaN-boxed pointer
   discards that bit, producing an invalid address. `QEMU_RESERVED_VA` cannot
   force a low guest address space because the vsyscall page is outside any
   reservation. A tagged build is an indirect control; it does not verify
   NaN-boxed execution.

   Core dumps slow emulated runs. Pass `--ulimit core=0` to podman.

3. Emulation misreports the host CPU. Use `-Dcpu=baseline`.

4. `-Dreduced-os=true` skips suites with `needs_os = true` in `build.zig`'s
   `test_suites`. This build registers only the following `os` bindings:
   `os/exit`, `os/which`, `os/arch` and `os/compiler`. Wattle resolves bindings
   at compile time, so suites referencing omitted bindings cannot load.
   `suite-os` tests the OS library; other excluded suites build fixtures
   requiring filesystems, environment variables or subprocesses.

   `test/helper.wattle` uses `compif` for `os/getenv` and `os/clock`. Its `rmrf`
   raises when filesystem operations are unavailable. The matrix's `reduced os`
   entry runs a `full` job to check suite compilation as well as contracts.

5. Cases that need a parked socket write in `suite-ev` do not run on Windows. An
   overlapped send to a loopback peer does not park: the transport accepts the
   bytes with the peer having read none of them, so cases that need a parked
   socket write are guarded off. `suite-net` records the same behaviour when
   flooding a socket. Everything else in the suites and the contracts runs
   there.

   CI executes the Windows binary as well as cross-compiling it.

Emulated runs do not establish NaN-boxed x86-64 trap behaviour. Confirm it on
real hardware before using it as the basis for a decision.

## Leak checks

`res/testing/leaks.sh` avoids `leaks --atExit` because that mode hangs on
contracts that fork: `os_process`, `os_surface` and `value_alloc`. `--atExit`
inserts `libLeaksAtExit.dylib`, which interposes `_exit` and `abort` with
`kill(getpid(), SIGSTOP)` followed by the real function, the stop being the
signal to the waiting `leaks` process that there is a heap to scan. A `fork()`ed
child has the dylib in its inherited image and stops itself the same way, and
nothing resumes it, because `leaks` is watching the parent; the parent's
`waitpid` never returns. An `exec`ed child is safe, because the same dylib's
initializer strips itself out of `DYLD_INSERT_LIBRARIES`, so `os/spawn` is not
the hazard and a raw `fork` is.

With `WATTLE_CONTRACT_PAUSE` set, the contract driver stops at the end of
`main`. `res/testing/leaks.sh` scans it with `leaks <pid>` and resumes it. This
requires no interposer. Every contract must report zero leaks; any non-zero
count causes a non-zero exit. There are no exemptions.

    ./res/testing/leaks.sh                  # all contracts
    ./res/testing/leaks.sh args_core marsh  # just these

The script measures all contracts. It requires macOS and Apple's `leaks`. Use
the container runs above for second-platform validation.

## Cross-platform build requirements

Two build requirements are not detectable by macOS-only testing:

- Zig subsystem objects must be position independent. Otherwise, ELF shared
  libraries fail to link with relocation errors. Mach-O is
  always position independent.

- The bootstrap must use a baseline CPU while preserving the host's
  architecture, OS and ABI. Using the detected CPU model makes image generation
  depend on the build machine and can fail on other hosts.
