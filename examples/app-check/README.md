# app-check

An application whose `check` hook raises.

- `info.edn` names the application and its group.

- `hooks.wattle` defines the `install` hook, which calls `app/add-bin` for
  `app-check`, and a `check` hook that raises `Check failed!`.

- `app-check` is the program, a shell script.

The `check` hook runs only when a check is requested, which `app/install`
does with `:check true`:

```sh
mkdir /tmp/prefix
wattle -p /tmp/prefix -e '(app/install "examples/app-check" :check true)'
```

The installation raises `Check failed!` and leaves nothing installed.
`wattle apps install` requests no check, so it installs the application.
`test/suite-apps.wattle` checks both the error and that no application is
listed after it.
