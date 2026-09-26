# Wattle

[![Test Status][icon]][status]

[icon]: https://github.com/pyrmont/wattle/actions/workflows/test.yml/badge.svg
[status]: https://github.com/pyrmont/wattle/actions?query=workflow%3ATest

> [!WARNING]
> Wattle is experimental. It was written primarily using LLM-based coding
> agents.

**Wattle** is a Lisp-like programming language. It reimplements the virtual
machine, compiler and core library from the [Janet][] programming language in
[Zig][] with a syntax inspired by [Clojure][].

## Language features

- 700+ functions and macros in the core library
- Built-in socket networking, threading, subprocesses and file system functions
- Parsing Expression Grammars (PEG) engine
- Macros and compile-time computation
- Per-thread event loop for efficient IO (epoll/IOCP/kqueue)
- First-class green threads (continuations) as well as OS threads
- Erlang-style supervision trees that integrate with the event loop
- First-class closures
- Mutable and immutable indexed sequences (array/vector)
- Mutable and immutable key-value sequences (table/map)
- Mutable and immutable byte sequences (buffer/string)
- Persistent immutable data structures (vector, map, set)
- Garbage collection
- Python-style generators (implemented as a plain macro)
- Tail recursion
- Native modules written in Zig and loaded dynamically
- Built-in C FFI for calling C ABI-compatible shared libraries
- REPL development with debugger and inspectable runtime

## Syntax

Wattle has a syntax inspired by Clojure's:

| source      | value                   | source        | value                |
| ----------- | ----------------------- | ------------- | -------------------- |
| `(f x)`     | tuple, the call form    | `#{a b}`      | set                  |
| `[a b]`     | vector                  | `![a b]`      | array                |
| `{:a 1}`    | map                     | `!{:a 1}`     | table                |
| `"ab"`      | string                  | `!"ab"`       | buffer               |
| `"""ab"""`  | string, raw             | `!"""ab"""`   | buffer, raw          |
| `'x`        | quote                   | `~x`          | unquote              |
| `` `x ``    | quasiquote              | `\|x`         | splice               |
| `:ab`       | keyword                 | `#(+ $ 1)`    | short function       |
| `;`         | comment                 |               |                      |

A raw string is closed by a run of quotes as long as the one that opened it.
Its first and last line breaks are dropped and the opening delimiter's
indentation is removed from each line, so it can sit inside indented code
without carrying that indentation into its value.

## Examples

See the `examples/` directory for all provided example programs.

### Game of Life

```clojure
; A game of life implementation

(def- window
  (seq [x :range [-1 2]
        y :range [-1 2]
          :when (not (and (zero? x) (zero? y)))]
    [x y]))

(defn- neighbors
  [[x y]]
  (map (fn [[x1 y1]] [(+ x x1) (+ y y1)]) window))

(defn tick
  """
  Get the next state in the Game of Life
  """
  [state]
  (def cell-set (frequencies state))
  (def neighbor-set (frequencies (mapcat neighbors state)))
  (seq [coord :keys neighbor-set
         :let [ncount (get neighbor-set coord)]
         :when (or (= ncount 3) (and (get cell-set coord) (= ncount 2)))]
      coord))

(defn draw
  """
  Draw cells in the game of life from (x1, y1) to (x2, y2)
  """
  [state x1 y1 x2 y2]
  (def cellset !{})
  (each cell state (put cellset cell true))
  (loop [x :range [x1 (+ 1 x2)]
         :after (print)
         y :range [y1 (+ 1 y2)]]
    (file/write stdout (if (get cellset [x y]) "X " ". ")))
  (print))

;
; Run the example
;

(var *state* '[[0 0] [-1 0] [1 0] [1 1] [0 2]])

(for i 0 20
  (print "generation " i)
  (draw *state* -7 -7 7 7)
  (set *state* (tick *state*)))
```

### TCP Echo Server

```clojure
(defn handler
  """
  Simple handler for connections
  """
  [stream]
  (defer (:close stream)
    (def id (gensym))
    (def b !"")
    (print "Connection " id "!")
    (while (:read stream 1024 b)
      (printf " %v -> %v" id b)
      (:write stream b)
      (buffer/clear b))
    (printf "Done %v!" id)
    (ev/sleep 0.5)))

(net/server "127.0.0.1" "8000" handler)
```

### FFI

```clojure
; Use the FFI to call into the C library - no C compiler required

(ffi/context)

(ffi/defbind strlen :size [s :string])

(print (strlen "Hello, World!"))
```

## Documentation

Wattle does not yet have a written manual.

Documentation is available in the REPL. Use the `(doc symbol-name)` macro to
get API documentation for symbols in the core library.

At the REPL

```clojure
(doc apply)
```

shows documentation for the `apply` function.

To get a list of all bindings in the default environment, use the
`(all-bindings)` function. You can also use the `(doc)` macro with no arguments
if you are in the REPL to show bound symbols.

## Building

Wattle is built with [Zig][]. The version is pinned in
`.zigversion` and is currently **0.16.0**.

```sh
git clone https://github.com/pyrmont/wattle
cd wattle
zig build              # the executable and the libraries
zig build test         # the contracts and the test suites
zig build run          # a REPL
```

Artifacts are installed under `zig-out`: the executable in `zig-out/bin` and
the static and shared libraries in `zig-out/lib`. **No header is installed** —
see "Native modules" below. Pass `-p <prefix>` to install somewhere else, and `zig
build --help` to see the feature flags — the runtime can be built without the
event loop, networking, the PEG engine, the assembler, the FFI, integer types,
dynamic modules or docstrings.

```sh
zig build -Doptimize=ReleaseFast          # an optimized build
zig build -Dtarget=aarch64-linux-musl     # cross-compile
zig build -Dtarget=wasm32-wasi            # a WASI command-line build
```

Cross-compilation needs no extra toolchain: Zig ships the C headers and linkers
for every supported target.

A [musl][] build is dynamically linked and loads native modules, and needs the
musl loader (`/lib/ld-musl-<arch>.so.1`, standard on Alpine and installed on
Debian and Ubuntu by the `musl` package) on the machine that runs it.
`-Dlinkage=static` builds a self-contained executable instead. A static musl
executable loads no native module at run time, so that build turns dynamic
modules off, and `-Ddynamic-modules=true` with it is a build error. A native is
then linked in at build time with `quickbin`; see "Extending" below.

The WASI build needs no other flag: the target turns off the event loop, the
FFI, networking, processes and dynamic modules, and builds single-threaded.
Run it under any WASI host:

```sh
wasmtime run --dir . zig-out/bin/wattle.wasm
```

A WASI program sees only the directories which are mapped in, so a script and
everything it reads have to be in this tree.  The default `syspath` is
`/usr/local/lib/wattle`, so `import` needs that name mapped — `--dir
<host-dir>::/usr/local/lib/wattle` — or `WATTLE_PATH` set to a directory that is:

```sh
wasmtime run --dir . --env WATTLE_PATH=./lib zig-out/bin/wattle.wasm script.wattle
```

`zig build examples/web` builds `examples/web/`, Wattle in a web page: the runtime as a
WASI reactor, with the page and its JavaScript host, into `zig-out/web`.

### Supported platforms

| platform         | state                                                          |
| ---------------- | -------------------------------------------------------------- |
| macOS arm64      | built and fully tested                                         |
| macOS x86-64     | compiles only; not executed since the Intel runner was dropped |
| Linux, musl      | built and fully tested; dynamic by default, needs musl loader  |
| Linux, glibc     | built and fully tested                                         |
| Windows          | built and fully tested                                         |
| wasm32-wasi      | built and fully tested under wasmtime, without the event loop  |
| 32-bit (riscv32) | built and tested under QEMU, without the FFI                   |

## Installing

If you just want to try out the language, you don't need to install anything:
build the tree and run `zig-out/bin/wattle` where it is. The executable is
self-contained and can be moved wherever you want on your system.

## Using

A REPL is launched when the binary is invoked with no arguments. Pass the `-h`
flag to display the usage information. Individual scripts can be run with
`./wattle program.wattle`.

If you are looking to explore, you can print a list of all available macros,
functions, and constants by entering the command `(all-bindings)` into the
REPL.

```
$ wattle
Wattle 0.1.0-dev macos/aarch64/zig - '(doc)' for help
repl:1:> (+ 1 2 3)
6
repl:2:> (print "Hello, World!")
Hello, World!
nil
repl:3:> (os/exit)
$
```

The man page `wattle.1` is in the repository root. It is generated from
`wattle.1.predoc` by [Predoc][]. Read it in place with `man ./wattle.1`.

## Extending

Wattle can be extended with _native modules_. The native-module interface is
Zig. `examples/numarray/` is a worked example. A C program cannot define an
nfunction for this runtime: an nfunction returns an error union over Zig's own
calling convention, so no C body can have that type and no C caller can invoke
one. The same applies to an `AbstractType`'s callbacks. Native modules are
therefore written in Zig.

A module records the interface it was built against as a fingerprint, and the
loader refuses to load this unless that fingerprint, the configuration bits and
the Zig version all match the runtime's own. `wattle/api` is the runtime's
fingerprint. Wattle's version is not compared, so a module built against one
release loads into another whose interface is the same.

A module can also be linked into an executable, together with the runtime and
an image of a Wattle program, so that one file cross-compiles and runs with
nothing beside it. `zig build examples/quickbin` builds `examples/quickbin/`,
which links `examples/digest/` in, and `build.zig`'s `quickbin` function builds
one from outside the tree (`examples/standalone/`).

## Contributing

Wattle can be hacked on with pretty much any environment you like. No editor
yet has a syntax package for Wattle; a Clojure mode is the closest fit for
`.wattle` source. Any editor with Zig support will do for runtime development.

## License

Wattle is licensed under the MIT License. See [LICENSE](LICENSE) for more
details.

[Clojure]: https://clojure.org
[Janet]: https://janet-lang.org
[Predoc]: https://pyrmont.github.io/predoc
[Zig]: https://ziglang.org
