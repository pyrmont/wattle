# Changelog

Each release lists what changed since the release before it. The changes made
since the most recent release are under Unreleased.

## Unreleased

- Require Zig 0.17.0. A native module must be built with the same Zig
  version as the runtime, so a module built with 0.16.0 no longer loads.
- Declare the host's types, constants and functions in Zig, from Zig's
  standard library where it has them, in place of `@cImport`. The runtime
  has no C headers and `build.zig.zon` lists no dependency.
- Build for macOS, Linux with glibc or musl, Windows with mingw, WASI and
  FreeBSD. Code for other platforms is removed.
- Write `ev/lock`, `ev/rwlock` and the channel lock in Zig on every
  platform. Releasing an `ev/lock` from a thread that does not hold it
  raises on Windows, as it already did elsewhere.
- Remove the file watcher: the `filewatch/*` functions, the
  `filewatch/watcher` type and the `-Dfilewatch` build option.

## 0.1.1 (2026-10-05)

- Strip debug information from the Linux release builds. On aarch64 the
  `wattle` executable shrinks from about 11 MB to about 2 MB. The new build
  option `-Dstrip=true` strips the executable in any build.
- Fix a contract test that aborted in optimized builds on glibc.

## 0.1.0 (2026-10-05)

- Initial release.
