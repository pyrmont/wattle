# web-repl

Wattle in a web page. The runtime is built for WebAssembly as a wasm32-wasi
reactor. The page fetches it and imports `wasi.js`, a script that supplies the
WASI imports and instantiates the runtime. The page then calls the runtime with
the text a user enters.

- `src/client/web.zig` is the reactor's root. It exports `wattle_web_init`,
  `wattle_web_eval`, `wattle_web_alloc` and `wattle_web_free`. A build made
  with `-Dwasm-image` exports `wattle_web_run_image` in place of
  `wattle_web_eval`.
- `src/client/web/wasi.js` is the `wasi_snapshot_preview1` import object. It is
  hand-written and has no dependencies. Its `start` function instantiates the
  binary and returns an `eval` function for it.
- `index.html` is the page. It has a text area, a run button and an output
  pane.
- `test.js` runs the binary under Node with the same `wasi.js`.
- `test-image.js` runs two images under a `-Dwasm-image` binary. The images are
  made from `hello.wattle` and `echo.wattle`.

Run these from the repository root:

```sh
zig build examples/web-repl
node examples/web-repl/test.js
wattle examples/http-server.wattle localhost 8000 zig-out/web-repl
```

The page is at `http://localhost:8000/`.

## How it works

### A reactor rather than a command

WASI, the WebAssembly System Interface, is how a WebAssembly program calls its
host for things such as reading and writing standard streams. A WASI program
has one of two forms. A command has `_start`, which runs `main` and exits. A
reactor has `_initialize`, which runs wasi-libc's constructors and returns, and
then the functions that the module exports can be called any number of times.
The `web` step in `build.zig` sets `wasi_exec_model = .reactor` on the
executable to make the runtime a reactor.

The form matters because of how the REPL in the `wattle` command-line program
reads input. It reads standard input one line at a time and waits for each
line, and nothing else runs on its thread while it waits. A page cannot do this
on its main thread because the page would freeze. It could do this in a Web
Worker, but that needs `SharedArrayBuffer` and `Atomics.wait`, which require
cross-origin isolation headers that a static host does not always set. A
reactor does not wait for input. The page calls `_initialize` and
`wattle_web_init` once, and then calls `wattle_web_eval` for each submission,
with the whole text. The runtime is the `subsystems` module that the `wattle`
client imports.

### A submission runs as a REPL line

`wattle_web_init` evaluates a short Wattle function, `eval-line`, once.
`wattle_web_eval` calls it with the submitted source. `eval-line` calls
`run-context` as `repl` does. The environment is kept between calls, and
`debugger-on-status` is the same as that used by Wattle's REPL. The value of
each form is printed with `*pretty-format*` and bound to `_`. An error is
printed with its stack trace. `wattle_web_eval` returns 0, or 1 if parsing,
compiling or running failed.

Each submission is one chunk. A form left open is a parse error with no prompt
for closing delimiters.

### The imports

The runtime calls its host through WASI functions. The binary imports them from
the module `wasi_snapshot_preview1`, which is the name of the version of WASI
that wasm32-wasi builds use. `wasi.js` provides every import.

Descriptors 0, 1 and 2 are the only open descriptors. `wasi.js` buffers what
the program writes to 1 and 2. `eval` returns it as strings when the call ends,
and the page displays it. `eval` takes no input, so in this build standard
input is empty and a program that reads it gets nothing. A build made with
`-Dwasm-image` takes standard input as an argument, as described below. There
are no environment variables. The clocks use `Date.now` and `performance.now`.
Random bytes come from `crypto.getRandomValues`.

A program cannot access files, because `wasi.js` gives it no directories.
`slurp`, `spit`, `os/dir` and `import` therefore raise a Wattle error.

`os/sleep` returns at once and does not wait. `os/exit` ends the instance. The
call that exits returns the exit code as `status` (0 for a clean exit) and an
error named `WasiExit` as `error`.

### Unbounded recursion

The `web` step builds with a Wattle stack ceiling of 1000000 slots. The default
in `wattle.wasm` is 0x7fffffff. `-Dstack-max` overrides the ceiling.

At the default, `(defn f [n] (+ 1 (f (inc n)))) (f 0)` exhausts wasm32's heap
before the ceiling is reached, prints `wattle out of memory` and traps.
`wattle.wasm` under wasmtime does the same. A trap leaves the instance
unusable, so every definition made in the page is lost. With a ceiling of
1000000 slots the same call raises `error: stack overflow`, and the instance
keeps its state.

If a trap or `os/exit` ends the instance, the page reports it and starts a new
instance with a new environment.

### What is not there

The WASI target has no event loop, threads, FFI, networking, processes or
dynamic modules. A submission runs on the page's main thread until it returns.
A loop that does not end freezes the page.

## Loading an image without the compiler

```sh
zig build examples/web-repl -Dwasm-image=true
wattle build img examples/web-repl/hello.wattle /tmp/hello.wimage
wattle build img examples/web-repl/echo.wattle /tmp/echo.wimage
node examples/web-repl/test-image.js zig-out/web-repl/wattle-web.wasm /tmp/hello.wimage /tmp/echo.wimage
```

`-Dwasm-image` builds the reactor without the parser, the compiler, docstrings
and source maps.  `wattle build web` builds such a runtime for a project that
defines a `:web` artifact, as demonstrated in `examples/web-greeter`. The
installed directory holds `wattle-web.wasm` and `wasi.js` but no page. The user
must create this.

When built this way, `start` in `wasi.js` returns an object with
`runImage(bytes, { args, stdin })` in place of `eval(source)`. `bytes` is the
content of a file that `wattle build img` or `make-image` produced. `runImage`
unmarshals the image and calls its `main` with the strings in `args`, unchanged.
Consistent with how the main entry function works when `wattle` is read as the
command line, the first argument is by convention the program's name. Standard
input is `stdin`, a string or a `Uint8Array`, and returns EOF after the last
byte. `args` and `stdin` both default to nothing. `runImage` returns `{ status,
stdout, stderr, error }`, as `eval` does. The same instance can run another
image or the same image again. On a small image under Node, a call takes about
0.01 milliseconds on a loaded instance and about a millisecond on a new one. A
raise while loading the image or in `main` is printed to standard error with
its stack trace, and the status is 1. The instance can still be used.

The core image still contains functions named `eval`, `run-context` and the
other functions that need the compiler. However, if the `main` function of an
image calls one, the error is `this runtime has no compiler or parser; it can
only load an image`.

## What the test asserts

`node examples/web-repl/test.js [path]` loads `zig-out/web-repl/wattle-web.wasm`,
or `path`, and checks that:

- every import is from `wasi_snapshot_preview1` and is provided by `wasi.js`,
  and `wasi.js` provides nothing that no build imports. A ReleaseSmall or
  ReleaseFast build imports 26 functions, and a Debug or ReleaseSafe build
  imports 32. `res/check/wasm_imports.zig`, which also checks `wattle.wasm`,
  makes the same check when the binary is built;
- the exports are the four functions, `_initialize`, `memory` and
  `__stack_pointer`;
- `(+ 1 2)` prints `3`, and `(def x 40)` followed by `(+ x 2)` prints `42`;
- `print` and `eprint` write to standard output and standard error;
- `(error "boom")` and an unclosed form return 1 with the error on standard
  error, and `x` is still defined afterwards;
- unbounded recursion returns 1 with `error: stack overflow`, the instance is
  not stopped, and `(+ x 2)` still prints `42`.

The test exits 1 on the first mismatch. It needs Node 22.7 or later, which runs
a `.js` file written as an ES module without a `package.json`. The `wasi` CI
jobs run it after `zig build examples/web-repl` in both of their optimize
modes.
