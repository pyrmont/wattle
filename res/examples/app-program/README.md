# app-program

An application that installs a source program and its manual page from the
declarations in its info file.

- `info.edn` names the application and its group. `:exes` declares `hello`, a
  source executable whose entry is `main.wattle`, and `:docs` declares
  `man/hello.1` as its manual page.

- `main.wattle` defines `main`, which prints `hello`.

- `man/hello.1` is the manual page.

```sh
mkdir /tmp/prefix
wattle -p /tmp/prefix apps install res/examples/app-program
WATTLE_PREFIX=/tmp/prefix /tmp/prefix/bin/hello
wattle -p /tmp/prefix apps remove app-program
```

Installing copies `main.wattle` to
`lib/wattle/apps/org.wattle.examples/app-program/` under the prefix, writes a
wrapper to `bin/hello` and copies the manual page to
`share/man/man1/hello.1`. The wrapper runs `main.wattle` with the `wattle` on
the PATH. Removing deletes each of these files. Source executables cannot be
installed on Windows.

`wattle-applications(7)` describes installation and `wattle-projects(7)` the
declarations. `test/suite-apps.wattle` installs, upgrades and removes this
application.
