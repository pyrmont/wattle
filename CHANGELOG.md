# Changelog

Each release lists what changed since the release before it. The changes made
since the most recent release are under Unreleased.

## Unreleased

- Require Zig 0.17.0. A native module must be built with the same Zig
  version as the runtime, so a module built with 0.16.0 no longer loads.
- Translate the host C headers with the translate-c package, which
  `build.zig.zon` now lists as a dependency, in place of `@cImport`.
- Remove the file watcher: the `filewatch/*` functions, the
  `filewatch/watcher` type and the `-Dfilewatch` build option.

## 0.1.1 (2026-10-05)

- Strip debug information from the Linux release builds. On aarch64 the
  `wattle` executable shrinks from about 11 MB to about 2 MB. The new build
  option `-Dstrip=true` strips the executable in any build.
- Fix a contract test that aborted in optimized builds on glibc.

## 0.1.0 (2026-10-05)

- Initial release.
