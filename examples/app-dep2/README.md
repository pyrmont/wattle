# app-dep2

An application whose `install` hook installs one program.

- `info.edn` names the application and its group.

- `hooks/init.wattle` defines the `install` hook, which calls `app/add-bin`
  for `app-dep2`.

- `app-dep2` is the program, a shell script.

```sh
mkdir /tmp/prefix
wattle -p /tmp/prefix apps install examples/app-dep2
/tmp/prefix/bin/app-dep2
```

`test/suite-apps.wattle` installs this application with `examples/app-dep1`
to test listing, upgrading and removing more than one application.
