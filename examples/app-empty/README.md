# app-empty

A directory that is not an application. `info.edn` names it, but there is no
application script and no `:exes` declaration.

```sh
mkdir /tmp/prefix
wattle -p /tmp/prefix apps install examples/app-empty
```

The installation raises:

```
application must contain hooks.wattle, hooks/init.wattle or an info.edn that declares :exes
```

`test/suite-apps.wattle` checks this error.
