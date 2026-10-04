# web-errors

A page that shows what `run` returns when `main` finishes, prints to standard
error, raises and exits. It builds on `examples/web-greeter` and
`examples/web-counter`.

```sh
wattle build web
wattle ../http-server.wattle localhost 8000 zig-out/web/errors .
```

See the resulting page at `http://localhost:8000/`.

## The program

```clojure
(defn main [& args]
  (def [_ mode] args)
  (cond
    (= mode "ok") (print "finished")
    (= mode "eprint") (do (print "to stdout") (eprint "to stderr"))
    (= mode "raise") (error "raised by main")
    (= mode "exit") (os/exit 3)
    (error (string "unknown mode: " mode))))
```

## The result

`run` returns `{ status, stdout, stderr, error }`.

| mode     | `status` | `stdout`      | `stderr`                      | `error`                         |
| -------- | -------- | ------------- | ----------------------------- | ------------------------------- |
| `ok`     | 0        | `finished\n`  | empty                         | null                            |
| `eprint` | 0        | `to stdout\n` | `to stderr\n`                 | null                            |
| `raise`  | 1        | empty         | the error and its stack trace | null                            |
| `exit`   | 3        | empty         | empty                         | `{ name: "WasiExit", code: 3 }` |
| `bogus`  | 1        | empty         | the error and its stack trace | null                            |

`run` does not throw when the program fails. The page reads `status`.

`status` is 0 when `main` returns, 1 when it raises, and the exit code when it
calls `os/exit`. A raise from `main` is printed to `stderr` and leaves `error`
null. The instance is not affected, so the next call runs in it.

`error` is set when the instance is lost. `os/exit` ends the instance, so
`error` is a `WasiExit` with `code` set to the exit code.

## The instance

After a call with `error` set, the `run` that `load` returns starts a new
instance for the next call. A trap also leaves no usable instance. The runtime
is not fetched or compiled again, and anything the old instance held is gone.

`fresh: true` starts a new instance for that call regardless of whether the
last one was lost. The page's checkbox sets it.
