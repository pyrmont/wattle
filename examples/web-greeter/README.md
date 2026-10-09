# web-greeter

A minimal `wattle build web` example. The page passes a name through `args` and
text through `stdin`, then reads the program's output as strings.

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

`wattle build web` writes the following files to `zig-out/web/greeter/`:

| file                    | content                                 |
| ----------------------- | --------------------------------------- |
| `wattle-<hash>.wasm`    | the runtime                             |
| `greeter-<hash>.wimage` | the compiled program                    |
| `wasi-<hash>.js`        | the WASI support the runtime imports    |
| `greeter.js`            | an ES module that loads the other files |

The hashed file names use the same `<hash>`. `greeter.js` has a fixed name
and fetches the other files from the same directory.

## The server

`examples/http-server.wattle` serves the example over HTTP. Any static file
server can be used if it sends a JavaScript content type for `.js` files.
Browsers reject ES modules served with other content types.

## The runtime

The runtime is Wattle built for WebAssembly, as a WASI reactor that loads an
image. It is the runtime of the `wattle` command with some parts left out:

- The parser and the compiler. A program should not call `eval`, `parse` or
  `run-context`. Doing so raises the error
  `this runtime has no compiler or parser; it can only load an image`.

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

`main` receives `args` through WASI, using command-line argument conventions.
The page supplies the program name first and user input from the second
argument. Standard input uses the page's `stdin` and reports end of file after
the last byte. `print` writes to standard output; `eprint` writes to standard
error.

## The page

```js
import { run } from "./greeter.js";

const result = await run({ args: ["greeter", "Matilda"], stdin: "Some text" });
```

`args` is an array of strings. `stdin` is a string or a `Uint8Array`. `run`
returns `{ status, stdout, stderr, error }`:

- `status` is 0 when `main` returns and 1 when it raises.

- `stdout` and `stderr` contain the program's output on each stream, returned
  when `main` returns.

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

- run independently of its calling thread. `run` executes on that thread until
  `main` returns. An infinite loop blocks the tab's main thread. Calling `run`
  from a Web Worker keeps the page responsive; to stop an infinite loop, the
  page must terminate the worker.
