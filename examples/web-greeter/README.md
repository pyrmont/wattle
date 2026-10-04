# web-greeter

A program that a web page calls with a name and some text. It is the smallest
use of `wattle build web`: input goes in as `args` and `stdin`, and output
comes back as strings.

- `info.edn` declares one `:web` artifact whose `:entry` is `main.wattle`.
- `main.wattle` defines `main`, which the page calls.
- `index.html` is the page.

```sh
cd examples/web-greeter
wattle build web
wattle ../http-server.wattle localhost 8000 zig-out/web/greeter .
```

Open `http://localhost:8000/` to see the resulting page.

## The build

`wattle build web` writes `zig-out/web/greeter/` with four files:

| file                    | content                                 |
| ----------------------- | --------------------------------------- |
| `wattle-<hash>.wasm`    | the runtime                             |
| `greeter-<hash>.wimage` | the compiled program                    |
| `wasi-<hash>.js`        | the WASI support the runtime imports    |
| `greeter.js`            | an ES module that loads the other three |

`<hash>` is the same in the three names. `greeter.js` keeps its name and
fetches the other files from beside itself.

## The server

`examples/http-server.wattle` serves files over HTTP and is used here but any
static file server does the same job, provided it sends a JavaScript type for
`.js` files (a browser refuses an ES module without one).

## The runtime

The runtime is Wattle built for WebAssembly, as a WASI reactor that loads an
image. It is the runtime of the `wattle` command with some parts left out:

- The parser and the compiler. A program should not call `eval`, `parse` or
  `run-context`. Doing so raises the error `this runtime has no compiler or
  parser; it can only load an image`.
- Docstrings and source maps.
- The event loop, threads, FFI, networking, processes and dynamic modules.

The runtime also has no file system, as the limitations below describe.

## The program

The program is an image containing the following function.

```clojure
(defn main [& args]
  (def [_ name] args)
  (print "Hello, " name "! You wrote: " (file/read stdin :all)))
```

`main` receives the strings in `args` via WASI as if being run from the command
line. The first is the program's name, which the page supplies, so the page's input
starts at the second. Standard input is the page's `stdin`, and it reports end of file after
the last byte. `print` writes to standard output and `eprint` to standard
error.

## The page

```js
import { run } from "./greeter.js";

const result = await run({ args: ["greeter", "Matilda"], stdin: "Some text" });
```

`args` is an array of strings. `stdin` is a string or a `Uint8Array`. `run`
returns `{ status, stdout, stderr, error }`:

- `status` is 0 when `main` returns and 1 when it raises.
- `stdout` and `stderr` hold everything the program wrote to each. They are
  returned when `main` returns.
- `error` is always null in this program.

`run` fetches and starts up the runtime on every call. A page that processes
input repeatedly uses `load` instead as demonstrated by `examples/web-counter`.
`examples/web-errors` shows `status` and `error` when `main` does not return
normally.

## Limitations

A program cannot:

- wait for input. `stdin` is complete when `run` is called.
- read or write files, or import a module at run time. There are no preopened
  directories, so `slurp`, `spit` and `import` raise.
- sleep. `os/sleep` returns at once.
- run beside the page. A call runs on the thread that calls `run` until `main`
  returns, so a loop that does not end freezes the tab. Calling `run` from a
  Web Worker keeps the page responsive while a call is running. It does not
  stop a loop that does not end, which the page must do by terminating the
  worker.
