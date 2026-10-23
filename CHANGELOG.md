# Changelog

Each release lists what changed since the release before it. The changes made
since the most recent release are under Unreleased.

## Unreleased

## 0.3.0 (2026-10-23)

- Link the executables that `wattle build exe` builds for a musl target,
  such as `x86_64-linux-musl`, statically, so they start on a host without
  `/lib/ld-musl-<arch>.so.1`. `--no-static` links them dynamically. A static
  executable cannot load a native module at run time other than those whose
  `:for` names it.
- Allow a `:native` lib in `info.edn` to compile C into the module.
  `:c-sources` lists the C files, `:c-includes` the include directories and
  `:c-flags` the flags for the C compiler. `ExecutableNative` in `build.zig`
  has `c_sources`, `c_includes` and `c_flags` fields.
- Fix `wattle apps install` hashing a local directory in full before
  refusing it as not an application. The hash failed when a file under the
  directory was removed during the walk or the tree held a symbolic link.

## 0.2.2 (2026-10-15)

- Strip debug information and the static symbol table from the executables
  that `wattle build exe` builds. `--no-strip` (`-S`) keeps them.
  `ExecutableOptions` in `build.zig` has a `strip` field, false by default.

## 0.2.1 (2026-10-15)

- Strip debug information from the Windows release build and leave
  `wattle.pdb` out of its archive. The archive shrinks from about 4.2 MB to
  about 2.1 MB.
- Fix fetching a `:remote` lib or an application from Git failing at random
  with "No such file or directory" for `.git/objects/maintenance.lock`.
  Git's automatic maintenance ran in the background while the clone was
  removed, and is now turned off for these commands.

## 0.2.0 (2026-10-15)

- Require Zig 0.17.0. A native module must be built with the same Zig
  version as the runtime, so a module built with 0.16.0 no longer loads.
- Declare the host's types, constants and functions in Zig, from Zig's
  standard library where it has them, in place of `@cImport`. (`@cImport`
  was removed in Zig 0.17.0.)
- Build for macOS, Linux with glibc or musl, Windows with mingw, WASI and
  FreeBSD. Code for other platforms is removed.
- Write `ev/lock`, `ev/rwlock` and the channel lock in Zig on every
  platform. Releasing an `ev/lock` from a thread that does not hold it
  raises on Windows, as it already did elsewhere.
- Remove the file watcher: the `filewatch/*` functions, the
  `filewatch/watcher` type and the `-Dfilewatch` build option.
- `wattle build` and `wattle test` run without the event loop. A build
  without processes refuses them with "is not supported without
  processes", and a reduced-OS build with "is not supported with reduced os".
- Replace `wattle pkg` with `wattle apps` and `wattle deps`. `wattle apps`
  has install, upgrade, remove and list, and `wattle deps` has vendor,
  which copies each entry of `:vendored` in `info.edn` into the project.
  The verbs reinstall, update, clean and uninstall are removed. The `pkg/`
  functions become `app/`, `dep/` and `build/` functions, the
  `:uninstall` hook is `:remove`, and the hook script is `hooks.wattle` or
  `hooks/init.wattle`.
- Install an application in `lib/wattle/apps/<group>/<name>` under the
  prefix. `info.edn` needs a `:group`, and a name is unique across groups.
  The manifest records `:rev`, the revision of the installed source.
- Remove package dependencies: `info.edn` no longer takes `:dependencies`,
  and the `:postdeps` hook, `pkg/topolist` and `:auto-remove` are removed.
- Declare what a project builds in the `:exes`, `:libs` and `:docs`
  vectors of `info.edn` in place of `:artifacts` and `:man`. A lib or a
  doc names the exes it belongs to with `:for`. An exe of type `:source`
  is installed as Wattle source and run by `app/run`. A lib of type
  `:remote` is fetched from a Git repository or a tarball and pinned by
  `:hash`.
- Read `info.edn` only from the root of a project, not from `pkg/`.
- A bare import searches the directories of the `:modpath` binding,
  `.wattle` and `zig-out/lib` in a project, and finds only a lib that
  `info.edn` declares. It no longer searches `lib/wattle` under the
  prefix. The `:prefix:` replacement of `module/expand-path`,
  `module/add-prefix`, `app/add-file`, `app/add-directory` and `app/add`
  are removed.
- Add `crypto/hash`, `crypto/hasher`, `crypto/update!`, `crypto/digest`,
  `crypto/hmac` and `crypto/equal?` for SHA-256, SHA-512 and BLAKE3.
- Give each subcommand its own man page, and add wattle-applications(7),
  wattle-dependencies(7) and wattle-projects(7).
- Fix `%w` and `%y` printing one pair of a map twice and omitting another
  when the map contains a larger map.
- Fix `os/execute` and `os/spawn` on Windows dropping an empty-string
  argument, and failing to pass a stream from `os/open` to the child.
- Fix a failed `wattle apps upgrade` not restoring the previous
  application.

## 0.1.1 (2026-10-05)

- Strip debug information from the Linux release builds. On aarch64 the
  `wattle` executable shrinks from about 11 MB to about 2 MB. The new build
  option `-Dstrip=true` strips the executable in any build.
- Fix a contract test that aborted in optimized builds on glibc.

## 0.1.0 (2026-10-05)

- Initial release.
