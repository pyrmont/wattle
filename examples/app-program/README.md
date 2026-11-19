# app-program

An application that installs a program and its manual page from an
application script.

- `info.edn` names the application and its group.

- `hooks/init.wattle` defines the `install` hook. The hook calls
  `app/add-bin` for `hello` and `app/add-manpage` for `hello.1`.

- `hello` is the program, a shell script.

- `hello.1` is the manual page.

```sh
mkdir /tmp/prefix
wattle -p /tmp/prefix apps install examples/app-program
/tmp/prefix/bin/hello
wattle -p /tmp/prefix apps remove app-program
```

Installing writes `bin/hello` and `share/man/man1/hello.1` under the prefix,
and the application's own files to
`lib/wattle/apps/org.wattle.examples/app-program/`. Removing deletes each file
that the hooks added.

`wattle-applications(7)` describes the hooks and the installed layout.
`test/suite-apps.wattle` installs, upgrades and removes this application.
