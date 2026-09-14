# web

Janet in a web page: the runtime built as a wasm32-wasi reactor, a page that
calls into it, and the JavaScript that supplies WASI in its place.

- `main.zig` is the reactor's root. It exports `janet_web_init`,
  `janet_web_eval`, `janet_web_alloc` and `janet_web_free`.
- `wasi.js` is the `wasi_snapshot_preview1` import object, hand-written and
  without dependencies, and `start`, which instantiates the binary and
  returns an `eval` over it.
- `index.html` is the page: a text area, a run button and an output pane.
- `test.js` runs the binary under Node with the same `wasi.js`.

```sh
zig build web                         # zig-out/web, ReleaseSmall
node examples/web/test.js             # from the repository root
cd zig-out/web && python3 -m http.server
```

then open `http://localhost:8000/`. The installed directory holds
`janet-web.wasm`, `index.html` and `wasi.js`, and is servable on its own. A
browser will not fetch the binary from a `file://` page, which is why a
server is needed.

**The page has not been opened in a browser in this repository's
verification.** What is checked is `test.js`, which runs the `wasi.js` the page
loads, under Node. Open the page to see it work.

## What it shows

### A reactor rather than a command

The `janet` client reads standard input one line at a time and blocks between
lines. A page cannot block: waiting for input would need a Web Worker,
`SharedArrayBuffer` and `Atomics.wait`, and those need cross-origin isolation
headers a static host does not always set. So the page drives the runtime
instead.

A WASI *command* has `_start`, which runs `main` and exits. A *reactor* has
`_initialize`, which runs wasi-libc's constructors and returns, and then
whatever functions the module exports. `build.zig`'s `web` step sets
`wasi_exec_model = .reactor` on the executable. The page calls `_initialize`
and `janet_web_init` once, and `janet_web_eval` for each submission. The
runtime is the same `subsystems` module the `janet` client imports, unchanged.

### A submission runs as a REPL line

`janet_web_init` evaluates a short Janet function, `eval-line`, once, and
`janet_web_eval` calls it with the submitted source. `eval-line` calls
`run-context` as `repl` does, with the environment kept between calls and the
REPL's `debugger-on-status`. Each form's value is printed with
`*pretty-format*` and bound to `_`, and an error is printed with its stack
trace. `janet_web_eval` returns 0, or 1 when parsing, compiling or running
failed. Written in Janet, the REPL's printing is reused rather than repeated
in Zig, and the Zig side is a call.

The whole submission is one chunk, so a form left open is a parse error
rather than a prompt for more.

### The imports

The binary imports only from `wasi_snapshot_preview1`, which the build checks
with the same `tools/check/wasm_imports.zig` that checks `janet.wasm`. A
ReleaseSmall or ReleaseFast build imports 26 functions, and a Debug or
ReleaseSafe build 32. `wasi.js` provides the 32, and `test.js` fails if the
binary imports one it does not.

Descriptors 0, 1 and 2 are the only open ones. Output on 1 and 2 is collected
in JavaScript and returned by `eval` when the call ends, rather than written
to the page per write. Standard input is at end of file, there are no
environment variables, the clocks come from `Date.now` and `performance.now`,
and random bytes from `crypto.getRandomValues`.

There are no preopened directories. `fd_prestat_get` must say so with `EBADF`:
wasi-libc's constructor, run by `_initialize`, treats any other error as fatal
and exits with status 71. With no preopens, wasi-libc fails every path before
reaching a `path_*` import, so `slurp`, `spit`, `os/dir` and `import` raise a
Janet error.

`poll_oneoff` returns at once, so `os/sleep` does not wait. `proc_exit` throws,
so `os/exit` ends the instance.

### Unbounded recursion

The `web` step builds with a Janet stack ceiling of 1000000 slots, where
`janet.wasm` has the default 0x7fffffff. `-Dstack-max` overrides it.

At the default, `(defn f [n] (+ 1 (f (inc n)))) (f 0)` exhausts wasm32's heap
before reaching the ceiling, prints `janet out of memory` and traps.
`janet.wasm` under wasmtime does the same. A trap leaves the instance
unusable, so every definition made in the page would be lost. At 1000000
slots the same call raises `error: stack overflow`, and the instance keeps its
state.

The cost is the stack trace, which lists every frame: 111,112 lines, 3.9 MB
and 555,557 calls to `fd_write` on a ReleaseSmall build, in about 0.2 seconds
under Node. The page shows the first 200 lines of each stream and a line
saying how many more there were.

If a trap or `os/exit` does stop the instance, the page says so and starts a
new one, with a new environment.

### What is not there

The WASI target has no event loop, threads, FFI, networking, processes or
dynamic modules, as `janet.wasm` has none. A submission runs on the page's
main thread until it returns, and nothing interrupts it, so a loop that does
not end freezes the tab.

## What the test asserts

`node examples/web/test.js [path]` loads `zig-out/web/janet-web.wasm`, or
`path`, and checks:

- that every import is from `wasi_snapshot_preview1` and provided by
  `wasi.js`, and that `wasi.js` provides nothing no build imports;
- that the exports are the four functions, `_initialize` and `memory`;
- that `(+ 1 2)` prints `3`, and that `(def x 40)` followed by `(+ x 2)`
  prints `42`;
- that `print` and `eprint` reach standard output and standard error;
- that `(error "boom")` and an unclosed form return 1 with the error on
  standard error, and that `x` is still defined afterwards;
- that unbounded recursion returns 1 with `error: stack overflow`, without
  stopping the instance, and that `(+ x 2)` still prints `42`.

It exits 1 on the first mismatch. It needs Node 22.7 or later, which runs a
`.js` file written as an ES module without a `package.json`. The `wasi` CI
jobs run it after `zig build web` in both of their optimize modes.
