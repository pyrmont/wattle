# Changelog

Each release lists what changed since the release before it. The changes made
since the most recent release are under Unreleased.

## 0.1.1 (2026-10-05)

- Strip debug information from the Linux release builds. On aarch64 the
  `wattle` executable shrinks from about 11 MB to about 2 MB. The new build
  option `-Dstrip=true` strips the executable in any build.
- Fix a contract test that aborted in optimized builds on glibc.

## 0.1.0 (2026-10-05)

- Initial release.
