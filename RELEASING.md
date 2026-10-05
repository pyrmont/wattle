# Releasing Wattle

Wattle releases are prepared locally, built by GitHub Actions and then
published from the draft GitHub release that the release workflow creates.

Between releases the version in `build.zig` is `DEVEL`, and a build reports
`DEVEL-` and the abbreviated hash of its commit, with `-dirty` appended when a
tracked file differs from that commit. A release commit sets the version to the
release's number. `src/README.md` describes the version label.

The commands below use `0.1.0` as the example version. They need `janet` and
`predoc` on the PATH.

## 1. Check the development branch

Ensure all intended changes have been committed, and push `master`:

```console
$ git status
$ git push origin master
```

Wait for the test workflow on GitHub Actions to pass before preparing the
release commit.

## 2. Choose the number

Read the Unreleased section of `CHANGELOG.md`, and choose the number from the
changes it lists: after 0.1.0, 0.1.1 for a patch-level release and 0.2.0 for a
minor-level one. Edit the section until it describes the release.

## 3. Prepare the release commit

Pass the version without its `v` prefix to the version script:

```console
$ janet res/repo/version.janet 0.1.0
```

The script sets the version in `build.zig`, `build.zig.zon`, the two man page
sources and the REPL banner in `README.md`, regenerates the man pages, and
replaces the Unreleased heading of `CHANGELOG.md` with the number and the date.
Review and test the result:

```console
$ git diff
$ git diff --check
$ zig build test
$ zig-out/bin/wattle --version
```

The last command prints `0.1.0`. Stage only the version-related files:

```console
$ git add build.zig build.zig.zon CHANGELOG.md README.md
$ git add man/wattle.1 man/wattle.1.predoc man/wattle.7 man/wattle.7.predoc
$ git commit -m "Prepare for v0.1.0 release"
$ git push origin master
```

Wait for the test workflow to pass again.

## 4. Tag the release

Wattle uses lightweight Git tags. Add the `v` prefix when creating the tag:

```console
$ git tag v0.1.0
$ git push origin v0.1.0
```

## 5. Build the release archives

Run the `release` workflow with the tag as its version input:

```console
$ gh workflow run release.yml -f version=v0.1.0
```

Alternatively, open GitHub Actions, select the `Release` workflow, choose
**Run workflow**, and enter `v0.1.0`.

The workflow checks out the tag, runs the tests, builds an archive for macOS
on aarch64, Linux on x86-64 and aarch64, and Windows on x86-64, and creates a
draft GitHub release with the archives attached and the release's section of
`CHANGELOG.md` as its notes. A build whose `wattle --version` is not the tag's
number fails. When the workflow succeeds, review the draft release and
publish it.

## 6. Return to development

After publishing the release, return the version to `DEVEL`:

```console
$ janet res/repo/version.janet DEVEL
```

This sets `build.zig` and the man page sources to `DEVEL`, regenerates the man
pages, and adds an empty Unreleased section to `CHANGELOG.md`. `build.zig.zon`
and the banner in `README.md` keep the release's number.

Commit the reset and push `master`:

```console
$ git add build.zig CHANGELOG.md
$ git add man/wattle.1 man/wattle.1.predoc man/wattle.7 man/wattle.7.predoc
$ git commit -m "Reset version to DEVEL"
$ git push origin master
```

From then on, each change worth recording adds a line to the Unreleased
section of `CHANGELOG.md`.
