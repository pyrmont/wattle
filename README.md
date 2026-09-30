# Wattle

[![Test Status][icon]][status]

[icon]: https://github.com/pyrmont/wattle/actions/workflows/test.yml/badge.svg
[status]: https://github.com/pyrmont/wattle/actions?query=workflow%3ATest

> [!WARNING]
> Wattle is experimental. It was written primarily using LLM-based coding
> agents.

**Wattle** is a Lisp-like programming language. It reimplements in [Zig][] the
virtual machine, compiler and core library from [Janet][] with a syntax
inspired by [Clojure][].

## Language features

- 600+ functions and macros in the core library
- Parsing expression grammar (PEG) engine
- Macros and compile-time computation
- First-class closures
- Built-in socket networking, threading, subprocesses and file system functions
- Per-thread event loop for efficient IO (epoll/IOCP/kqueue)
- First-class green threads (continuations) as well as OS threads
- Erlang-style supervision trees that integrate with the event loop
- Mutable and immutable indexed sequences (array/vector)
- Mutable and immutable key-value sequences (table/map)
- Mutable and immutable byte sequences (buffer/string)
- Garbage collection
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
  (each cell state (put! cellset cell true))
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
      (buffer/clear! b))
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

The `wattle` CLI utility is documented in the `wattle.1` man page. A brief
overview of the language is in the `wattle.7` man page. Both are generated from
[Predoc][] files that are included in `man/`. The files are installed to
`<prefix>/share/man`.

Documentation about bindings is available in the REPL. Use the `(doc symbol-name)` macro to
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
see "Native modules" below.

### Compilation options

Pass `-p <prefix>` to install somewhere else, and `zig build --help` to see the
feature flags — the runtime can be built without the event loop, networking,
the PEG engine, the assembler, the FFI, integer types, dynamic modules or
docstrings.

```sh
zig build -Doptimize=ReleaseFast          # an optimized build
zig build -Dtarget=aarch64-linux-musl     # cross-compile
zig build -Dtarget=wasm32-wasi            # a WASI command-line build
```

Cross-compilation needs no extra toolchain: Zig ships the C headers and linkers
for every supported target.

### Gotchas

#### musl

A [musl][] build is dynamically linked and loads native modules, and needs the
musl loader (`/lib/ld-musl-<arch>.so.1`, standard on Alpine and installed on
Debian and Ubuntu by the `musl` package) on the machine that runs it.
`-Dlinkage=static` builds a self-contained executable instead. A static musl
executable loads no native module at run time, so that build turns dynamic
modules off, and `-Ddynamic-modules=true` with it is a build error. A native is
then linked in at build time with `wattleExecutable`; see "Extending" below.

#### WASI

The WASI build needs no other flag: the target turns off the event loop, the
FFI, networking, processes and dynamic modules, and builds single-threaded.
Run it under any WASI host:

```sh
wasmtime run --dir . zig-out/bin/wattle.wasm
```

A WASI program sees only the directories which are mapped in, so a script and
everything it reads have to be in this tree.  A plain build has no default
`prefix`, so `import` of an installed module needs `WATTLE_PREFIX` set to a root
whose `lib/wattle` directory is mapped in, here `./lib/wattle`:

```sh
wasmtime run --dir . --env WATTLE_PREFIX=. zig-out/bin/wattle.wasm script.wattle
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

Running `wattle -h` outputs the following:

```
The Wattle programming language.

Options:

 -c, --color            Enable ANSI color output.
 -C, --no-color         Disable ANSI color output.
 -p, --prefix <path>    Set the prefix, the root that lib/wattle, bin and share/man derive from.
 -v, --version          Print the version string and exit.
 -h, --help             Print this usage summary and exit.

Subcommands:

 b, build    Build an artifact from source.
 c, check    Compile a script without running it and report every error.
 p, pkg      Manage installed packages.
 r, run      Run a script, evaluate code or start the REPL.
 t, test     Run the test files in ./test, each in its own process.

Without a subcommand, 'run' is assumed.
```

A REPL is launched when the binary is invoked with no arguments.

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

Individual scripts can be run with `wattle program.wattle`.

## Extending

Wattle can be extended with _native modules_. The native-module interface is
Zig, a C interface is not provided. Native modules are therefore written in
Zig. `examples/native-abstract/` is a working example.

A module records the interface it was built against as a fingerprint, and the
loader refuses to load a module if its fingerprint doees not match.
`wattle/api` is the runtime's fingerprint. The fingerprint is independent of
Wattle's version so that a module built against one release loads into another
provided that the interface is the same.

A module can also be linked into an executable, together with the runtime and
an image of a Wattle program, so that one file cross-compiles and runs with
nothing beside it. `wattle build exe` reads the project's `info.edn`, which
lists the executables to build and the native modules each links in, and makes
the executable with Zig. `wattle build lib` makes each native module as a shared
library. Both need Zig on the `PATH`, and the prefix, `WATTLE_PREFIX` or
`--prefix`, must be a root whose `share/wattle` holds the package, as `zig
build` installs it:

```clojure
{:name "hello"
 :artifacts [{:type :lib :name "greet" :root "greet.zig"}
             {:type :exe :name "hello" :entry "main.wattle" :libs ["greet"]}]}
```

```sh
wattle -p /usr/local build exe --release small
```

`examples/native-consumer/info.edn` is a worked instance, and `zig build
examples/build-exe` builds it this way. `man ./man/wattle.1` describes the file and
the options.

A project that needs more than that, such as other Zig steps or its own build
options, can write a `build.zig` and call the `wattleExecutable` function of the
`wattle` dependency, which is what `wattle build exe` generates. `zig build
examples/native-executable` builds `examples/native-executable/`, which links
`examples/native-events/` in, and `examples/native-consumer/build.zig` calls
`wattleExecutable` from outside the tree.

`zig build` also copies the package's files, `build.zig`, `build.zig.zon`,
`LICENSE`, `README.md` and `src/`, to `<prefix>/share/wattle/`. A project builds
a single-binary executable from that copy by naming it as the `wattle`
dependency with a `.path` relative to the project. Zig does not accept an
absolute `.path`. The copy has no `test/`, and `build.zig` skips the checks that
read it.

## Gum

Gum contains optional Wattle source modules. The modules are in `src/gum/` and
are included in the Wattle source package. `zig build` also copies them to
`<prefix>/share/wattle/src/gum/`. A project copies the modules it uses into its own
source tree and imports them by relative path. For example, with
`args.wattle` copied into `wattle/gum/args.wattle`, a file in `wattle/` uses:

```clojure
(import ./gum/args :as args)
```

Copy `LICENSE.argy-bargy` with `args.wattle`. See
[`src/gum/README.md`](src/gum/README.md) for the module's origin and use.

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
