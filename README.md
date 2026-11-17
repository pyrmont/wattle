# Wattle

[![Latest Release][release-icon]][release-page]
[![Test Status][icon]][status]

[release-icon]: https://img.shields.io/github/v/release/pyrmont/wattle
[release-page]: https://github.com/pyrmont/wattle/releases/latest
[icon]: https://github.com/pyrmont/wattle/actions/workflows/test.yml/badge.svg
[status]: https://github.com/pyrmont/wattle/actions?query=workflow%3ATest

> [!WARNING]
> Wattle is experimental. It was written primarily using LLM-based coding
> agents.

**Wattle** is a Lisp-like programming language. It reimplements in [Zig][] the
virtual machine, compiler and core library from [Janet][] with a syntax
inspired by [Clojure][].

A central use case of Wattle is producing delightful standalone executables.

## Language features

- Core library of functions and macros
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

See the [`examples/`](examples/) directory for all provided example programs.

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

(var *state* [[0 0] [-1 0] [1 0] [1 1] [0 2]])

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

The `wattle` CLI utility is documented in the `wattle.1` man page, and each
subcommand in a page of its own, such as `wattle-build.1`. A brief overview of
the language is in the `wattle.7` man page. All are generated from [Predoc][]
files that are included in `man/man1/` and `man/man7/`. The files are installed
to `<prefix>/share/man`.

Documentation about bindings is available in the REPL. Use the `(doc
symbol-name)` macro to get API documentation for symbols in the core library.

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
`.zigversion` and is currently **0.17.1**.

```sh
git clone https://github.com/pyrmont/wattle
cd wattle
zig build              # the executable and the libraries
zig build test         # the contracts and the test suites
zig build run          # a REPL
```

Artifacts are installed under `zig-out`: the executable in `zig-out/bin` and
the static and shared libraries in `zig-out/lib`. **No header is installed** —
see "Extending" below.

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

### Compilation options

Use `zig build --help` to see full list of feature flags. To give you a sense,
the Wattle runtime can be built without the event loop, networking, the PEG
engine, the assembler, the FFI, integer types, dynamic modules or docstrings.

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
then linked in at build time with `wattleExecutable`; see "Custom builds" below.

#### WASI

The WASI build needs no other flag: the target turns off the event loop, the
FFI, networking, processes and dynamic modules, and builds single-threaded.
Run it under any WASI host:

```sh
wasmtime run --dir . zig-out/bin/wattle.wasm
```

A WASI program sees only the directories which are mapped in, so a script and
everything it reads have to be in this tree. A plain build has no default
`prefix`. A script imports vendored modules by a relative path, and
`wattle run` finds the libs of a project through the `info.edn` beside the
script, so neither needs a prefix:

```sh
wasmtime run --dir . zig-out/bin/wattle.wasm script.wattle
```

`zig build examples/web-repl` builds
[`examples/web-repl/`](examples/web-repl/), Wattle in a web page: the runtime
as a WASI reactor, with the page and its JavaScript host, into
`zig-out/web-repl`.

## Installing

If you just want to try out the language, you don't need to install anything:
build the tree and run `zig-out/bin/wattle` where it is.

Each [release][releases] has an archive for macOS on aarch64, Linux on x86-64
and aarch64, and Windows on x86-64. An archive is an installation prefix, with
the `wattle` executable under `bin/`. [CHANGELOG.md](CHANGELOG.md) lists the
changes in each release.

A build from the repository between releases reports its version as `DEVEL`
and the abbreviated hash of its commit, such as `DEVEL-3c31337`, with `-dirty`
appended when a tracked file has uncommitted changes.

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

 a, apps     Manage installed applications.
 b, build    Build an artifact from source.
 c, check    Compile a script without running it and report every error.
 d, deps     Manage the dependencies of the current project.
 g, gum      Copy Gum modules into a project, or list them.
 r, run      Run a script, evaluate code or start the REPL.
 t, test     Run the test files in ./test, each in its own process.

Without a subcommand, 'run' is assumed.
```

A REPL is launched when the binary is invoked with no arguments.

```
$ wattle
Wattle 0.4.0 macos/aarch64/zig - '(doc)' for help
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

Wattle can be extended with _native modules_ written in Zig. `src/module.zig`
describes the interface and
[`examples/native-abstract/`](examples/native-abstract/) is a worked example.

A module records the interface it was built against as a fingerprint, and the
loader refuses a module if its fingerprint does not match the runtime's. The
fingerprint is independent of Wattle's version, so a module built against one
release loads into another if the interface is the same.

## Distributing

The `wattle build` subcommands read the project's `info.edn` and need Zig on
the `PATH` and the Wattle source under `<prefix>/share/wattle`. The
`wattle-build.1` man page has the details.

### Standalone executables

`wattle build exe` links the Wattle runtime, the program and the native modules
declared for it into a standalone executable:

```clojure
{:name "hello"
 :url "https://example.org/hello"
 :exes [{:type :native :name "hello" :entry "main.wattle"}]
 :libs [{:type :native :name "greet" :root "greet.zig" :for ["hello"]}]}
```

```sh
wattle build exe --release small
```

[`examples/native-consumer/`](examples/native-consumer/) is a worked example.

### Web programs

`wattle build web` builds a program for a browser. It writes the runtime as a
`.wasm` file, the program as an image and a JavaScript module that exports
`load`, which returns an object with a `run({ args, stdin })` method:

```clojure
{:exes [{:type :web :name "hello" :entry "main.wattle"}]}
```

[`examples/web-greeter/`](examples/web-greeter/),
[`examples/web-counter/`](examples/web-counter/) and
[`examples/web-errors/`](examples/web-errors/) are worked examples.

### Custom builds

A project that needs other Zig packages or its own build options can write a
`build.zig` that calls the `wattleExecutable` function of the `wattle`
dependency, or `wattleWeb` for a web program.
[`examples/native-consumer/build.zig`](examples/native-consumer/build.zig) is
a worked example, and `zig build examples/native-executable` builds
[`examples/native-executable/`](examples/native-executable/), which links in
[`examples/native-events/`](examples/native-events/).

## Miscellaney

### Gum

Gum is a collection of optional Wattle source modules that is included in the
`src/gum/` directory. `zig build` copies them to
`<prefix>/share/wattle/src/gum/`. A project copies the modules it uses into its
own source tree and imports them by relative path. `wattle gum` with no
arguments lists the modules. See [`src/gum/README.md`](src/gum/README.md) for
each module's origin and use.

### Editors

`res/editor/` holds support for reading and writing `.wattle` source. `zig
build` does not build it.

- [`res/editor/tree-sitter/`](res/editor/tree-sitter/README.md) is a
  Tree-sitter grammar with highlight and fold queries. An editor that loads
  Tree-sitter grammars can use it.
- [`res/editor/nvim/`](res/editor/nvim/README.md) is a Neovim runtime path. It
  sets the filetype, the comment string and Lisp indenting, and starts
  Tree-sitter with the grammar above. It also has the settings that vim-sexp
  needs to move by Wattle's delimiters.
- [`res/editor/textmate/`](res/editor/textmate/README.md) is a TextMate
  grammar with the scope name `source.wattle`. An editor or highlighter that
  loads TextMate grammars can use it.

Where there is no Wattle support, a Clojure mode is the closest fit for
`.wattle` source. Any editor with Zig support will do for runtime development.

## License

Wattle is licensed under the MIT License. See [LICENSE](LICENSE) for more
details.

[Clojure]: https://clojure.org
[Janet]: https://janet-lang.org
[musl]: https://musl.libc.org
[Predoc]: https://pyrmont.github.io/predoc
[releases]: https://github.com/pyrmont/wattle/releases
[Zig]: https://ziglang.org
