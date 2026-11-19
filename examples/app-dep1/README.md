# app-dep1

An application whose `install` hook installs one program.

- `info.edn` names the application and its group.

- `hooks/init.wattle` defines the `install` hook, which calls `app/add-bin`
  for `app-dep1`.

- `app-dep1` is the program, a shell script.

```sh
mkdir /tmp/prefix
wattle -p /tmp/prefix apps install examples/app-dep1
/tmp/prefix/bin/app-dep1
```

`test/suite-apps.wattle` installs this application with `examples/app-dep2`
to test listing, upgrading and removing more than one application. It also
checks that the program is written to `bin/` under the prefix and not to the
prefix itself.
