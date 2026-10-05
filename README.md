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

`zig build examples/web-repl` builds `examples/web-repl/`, Wattle in a web page: the runtime as a
WASI reactor, with the page and its JavaScript host, into `zig-out/web-repl`.

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

 b, build    Build an artifact from source.
 c, check    Compile a script without running it and report every error.
 g, gum      Copy Gum modules into a project, or list them.
 p, pkg      Manage installed packages.
 r, run      Run a script, evaluate code or start the REPL.
 t, test     Run the test files in ./test, each in its own process.

Without a subcommand, 'run' is assumed.
```

A REPL is launched when the binary is invoked with no arguments.

```
$ wattle
Wattle 0.1.1 macos/aarch64/zig - '(doc)' for help
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
Zig. `examples/native-abstract/` is a worked example.

A module records the interface it was built against as a fingerprint. This is
important at runtime as the module loader will refuse to load a module if the
fingerprint of the runtime and the fingerprint of the module do not match. The
fingerprint is independent of Wattle's version so that a module built against
one release can load into another provided that the interface is the same.

A module can also be linked together with the runtime and an image of a Wattle
program to create a standalone executable. `wattle build exe` will create the
executable artifacts specified in the project's `info.edn`. `wattle build lib`
makes each native module as a shared library. Both need Zig on the `PATH`, and
the prefix, `WATTLE_PREFIX` or `--prefix`. `<prefix>/share/wattle` must point
to a copy of the Wattle source. An example `info.edn` file could look like
this:

```clojure
{:name "hello"
 :url "https://example.org/hello"
 :artifacts [{:type :lib :name "greet" :root "greet.zig"}
             {:type :exe :name "hello" :entry "main.wattle" :libs ["greet"]}]}
```

A user could then build this for their system using:

```sh
wattle build exe --release small
```

`examples/native-consumer/info.edn` is a worked example. More details are in
the man page.

`wattle build web` builds a program for a browser. An artifact of type `:web`
has a `:name` and an `:entry`, and the command writes `zig-out/web/<name>/`
with `wattle-<hash>.wasm`, `<name>-<hash>.wimage`, `wasi-<hash>.js` and
`<name>.js`. The three hashes are one hash, taken from the contents of the three
files, so files with the same hash belong together. The `.wasm` is the
runtime without its parser and compiler, so it loads the image and nothing
else, and `<name>.js` exports `load`, which fetches and compiles the two files once and
returns an object whose `run({ args, stdin })` runs the program and returns its
output. `run` reuses one instance of the runtime between calls, so a page can
call it for each new input. `examples/web-greeter/`, `examples/web-counter/` and
`examples/web-errors/` are worked examples.

```clojure
{:artifacts [{:type :web :name "hello" :entry "main.wattle"}]}
```

A project that needs more than that, such as other Zig packages or its own
build options, can write a `build.zig` and call the `wattleExecutable` function
of the `wattle` dependency, or `wattleWeb` for a web program. `zig build examples/native-executable` builds
`examples/native-executable/`, which links `examples/native-events/` in, and
`examples/native-consumer/build.zig` calls `wattleExecutable` from outside the
tree.

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

Where there is no Wattle support, a Clojure mode is the closest fit for
`.wattle` source. Any editor with Zig support will do for runtime development.

## License

Wattle is licensed under the MIT License. See [LICENSE](LICENSE) for more
details.

[Clojure]: https://clojure.org
[Janet]: https://janet-lang.org
[Predoc]: https://pyrmont.github.io/predoc
[releases]: https://github.com/pyrmont/wattle/releases
[Zig]: https://ziglang.org
