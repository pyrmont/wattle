# app-alias

An application whose script is `hooks.wattle` rather than
`hooks/init.wattle`.

- `info.edn` names the application and its group.

- `hooks.wattle` defines the `install` hook, which calls `app/add-bin` for
  `app-alias`.

- `app-alias` is the program, a shell script.

```sh
mkdir /tmp/prefix
wattle -p /tmp/prefix apps install examples/app-alias
/tmp/prefix/bin/app-alias
```

An application uses one of the two names. When both exist,
`hooks/init.wattle` is used. `test/suite-apps.wattle` installs this
application to check that a `hooks.wattle` script runs.
