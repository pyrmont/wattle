# Wattle

[![Test Status][icon]][status]

[icon]: https://github.com/pyrmont/wattle/actions/workflows/test.yml/badge.svg
[status]: https://github.com/pyrmont/wattle/actions?query=workflow%3ATest

> [!WARNING]
> Wattle is experimental. It was written primarily using LLM-based coding
> agents.

**Wattle** is a runtime for the [Janet](https://janet-lang.org) programming
language, written in [Zig](https://ziglang.org). Janet is a language for system
scripting and expressive automation. It has more built-in functionality and a
richer core language than Lua, but is smaller than GNU Guile or Python.

Wattle runs Janet source identically to the [C
implementation](https://github.com/janet-lang/janet). What differs is the
runtime underneath, how it is built, and how native modules are written. Wattle
is also the base for a dialect of its own: `.wattle` source, with the syntax of
[Claret](https://github.com/pyrmont/claret), is planned to run beside `.janet`
source on the same virtual machine.

There is a REPL for trying out the language, as well as the ability to run
script files. Try Janet in your browser at <https://janet-lang.org>.

## Examples

See the examples directory for all provided example programs.

### Game of Life

```janet
# John Conway's Game of Life

(def- window
  (seq [x :range [-1 2]
        y :range [-1 2]
        :when (not (and (zero? x) (zero? y)))]
       [x y]))

(defn- neighbors
  [[x y]]
  (map (fn [[x1 y1]] [(+ x x1) (+ y y1)]) window))

(defn tick
  "Get the next state in the Game Of Life."
  [state]
  (def cell-set (frequencies state))
  (def neighbor-set (frequencies (mapcat neighbors state)))
  (seq [coord :keys neighbor-set
         :let [count (get neighbor-set coord)]
         :when (or (= count 3) (and (get cell-set coord) (= count 2)))]
      coord))

(defn draw
  "Draw cells in the game of life from (x1, y1) to (x2, y2)"
  [state x1 y1 x2 y2]
  (def cellset @{})
  (each cell state (put cellset cell true))
  (loop [x :range [x1 (+ 1 x2)]
         :after (print)
         y :range [y1 (+ 1 y2)]]
    (file/write stdout (if (get cellset [x y]) "X " ". ")))
  (print))

# Print the first 20 generations of a glider
(var *state* '[(0 0) (-1 0) (1 0) (1 1) (0 2)])
(for i 0 20
  (print "generation " i)
  (draw *state* -7 -7 7 7)
  (set *state* (tick *state*)))
```

### TCP Echo Server

```janet
# A simple TCP echo server using the built-in socket networking and event loop.

(defn handler
  "Simple handler for connections."
  [stream]
  (defer (:close stream)
    (def id (gensym))
    (def b @"")
    (print "Connection " id "!")
    (while (:read stream 1024 b)
      (printf " %v -> %v" id b)
      (:write stream b)
      (buffer/clear b))
    (printf "Done %v!" id)
    (ev/sleep 0.5)))

(net/server "127.0.0.1" "8000" handler)
```

### FFI Hello, World!

```janet
# Use the FFI to call into the C library - no C compiler required

(ffi/context)

(ffi/defbind strlen :size [s :string])

(print (strlen "Hello, World!"))
```

## Language Features

* 600+ functions and macros in the core library
* Built-in socket networking, threading, subprocesses, and file system functions
* Parsing Expression Grammars (PEG) engine as a more robust regex alternative
* Macros and compile-time computation
* Per-thread event loop for efficient IO (epoll/IOCP/kqueue)
* First-class green threads (continuations) as well as OS threads
* Erlang-style supervision trees that integrate with the event loop
* First-class closures
* Garbage collection
* Python-style generators (implemented as a plain macro)
* Mutable and immutable arrays (array/tuple)
* Mutable and immutable hashtables (table/struct)
* Mutable and immutable strings (buffer/string)
* Tail recursion
* Native modules written in Zig and loaded dynamically
* Built-in C FFI for calling shared libraries without writing a native module
* REPL development with debugger and inspectable runtime

## Documentation

* For a quick tutorial, see the
  [introduction](https://janet-lang.org/docs/index.html) for more details.
* For the full API for all functions in the core library, see the [core API
  doc](https://janet-lang.org/api/index.html).

Documentation is also available locally in the REPL. Use the `(doc
symbol-name)` macro to get API documentation for symbols in the core library.

For example:

```janet
(doc apply)
```

shows documentation for the `apply` function.

To get a list of all bindings in the default environment, use the
`(all-bindings)` function. You can also use the `(doc)` macro with no arguments
if you are in the REPL to show bound symbols.

## Building

Wattle is built with [Zig](https://ziglang.org). The version is pinned in
`.zigversion` and is currently **0.16.0**.

```sh
git clone https://github.com/pyrmont/wattle
cd wattle
zig build              # the executable and the libraries
zig build test         # the contracts and the Janet test suites
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

A musl build is dynamically linked and loads native modules, and needs the musl
loader (`/lib/ld-musl-<arch>.so.1`, standard on Alpine and installed on Debian
and Ubuntu by the `musl` package) on the machine that runs it.
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
wasmtime run --dir . --env WATTLE_PATH=./lib zig-out/bin/wattle.wasm script.janet
```

`zig build examples/web` builds `examples/web/`, Wattle in a web page: the runtime as a
WASI reactor, with the page and its JavaScript host, into `zig-out/web`.

### Supported platforms

| platform               | state                                                         |
| ---------------------- | ------------------------------------------------------------- |
| macOS arm64 and x86-64 | built and fully tested                                        |
| Linux, musl            | built and fully tested; dynamic by default, needs musl loader |
| Linux, glibc           | built and fully tested                                        |
| Windows                | cross-compiles; binaries have never been executed             |
| wasm32-wasi            | built and fully tested under wasmtime, without the event loop |
| 32-bit (riscv32)       | compiles only; wasm32-wasi is the 32-bit target that runs     |

## Installing

If you just want to try out the language, you don't need to install anything.
In this case you can also move the `wattle` executable wherever you want on your
system and run it. However, for a fuller setup, please see the
[Introduction](https://janet-lang.org/docs/index.html) for more details.

## Using

A REPL is launched when the binary is invoked with no arguments. Pass the `-h`
flag to display the usage information. Individual scripts can be run with
`./wattle myscript.janet`.

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
$ wattle -h
usage: wattle [options] script args...
Options are:
  --help (-h)             : Show this help
  --version (-v)          : Print the version string
  --stdin (-s)            : Use raw stdin instead of getline like functionality
  --eval (-e) code        : Execute a string of janet
  --expression (-E) code arguments... : Evaluate an expression as a short-fn with arguments
  --debug (-d)            : Set the debug flag in the REPL
  --repl (-r)             : Enter the REPL after running all scripts
  --noprofile (-R)        : Disables loading profile.janet when WATTLE_PROFILE is present
  --persistent (-p)       : Keep on executing if there is a top-level error (persistent)
  --quiet (-q)            : Hide logo (quiet)
  --flycheck (-k)         : Compile scripts but do not execute (flycheck)
  --syspath (-m) syspath  : Set system path for loading global modules
  --compile (-c) source output : Compile janet source code into an image
  --image (-i)            : Load the script argument as an image file instead of source code
  --nocolor (-n)          : Disable ANSI color output in the REPL
  --color (-N)            : Enable ANSI color output in the REPL
  --library (-l) lib      : Use a module before processing more arguments
  --lint-warn (-w) level  : Set the lint warning level - default is "normal"
  --lint-error (-x) level : Set the lint error level - default is "none"
  --install (-b) dirpath  : Install a bundle from a directory
  --reinstall (-B) name   : Reinstall a bundle by bundle name
  --uninstall (-u) name   : Uninstall a bundle by bundle name
  --update-all (-U)       : Reinstall all installed bundles
  --prune (-P)            : Uninstall all bundles that are orphaned
  --list (-L)             : List all installed bundles
  --                      : Stop handling options
```

The manual page `wattle.1` is in the repository root. It is generated from
`wattle.1.predoc` by [Predoc](https://github.com/pyrmont/predoc): edit the
source and run `predoc wattle.1.predoc`. `zig build` does not install it;
`man ./wattle.1` reads it in place.

## Extending

Wattle can be extended with _native modules_.  **The native-module interface is
Zig.** `src/module.zig` is what a module imports. `examples/numarray/` is a
worked example. A C program cannot define a cfunction for this runtime: a
cfunction returns an error union over Zig's own calling convention, so no C
body can have that type and no C caller can invoke one. The same applies to a
`JanetAbstractType`'s callbacks. Native modules are therefore written in Zig.

A module records the interface it was built against as a fingerprint, and the
loader refuses to load this unless that fingerprint, the configuration bits and
the Zig version all match the runtime's own. `janet/api` is the runtime's
fingerprint. Wattle's version is not compared, so a module built against one
release loads into another whose interface is the same.

A module can also be linked into an executable, together with the runtime and
an image of a Janet program, so that one file cross-compiles and runs with
nothing beside it. `zig build examples/quickbin` builds `examples/quickbin/`, which links
`examples/digest/` in, and `build.zig`'s `quickbin` function builds one from
outside the tree (`examples/standalone/`).

**No header is installed, and there is no amalgamated `janet.c`.** The client
does not link against the library either: it imports the runtime as a Zig
module.

## Contributing

Wattle can be hacked on with pretty much any environment you like. VSCode, Vim,
Emacs and Atom each have syntax packages for the Janet language, and any editor
with Zig support will do for the runtime itself.

`res/README.md` explains the development instruments used in porting — the
acceptance matrix, the leak check and the checked inventories.

## License

Wattle is licensed under the MIT License. See [LICENSE](LICENSE) for more
details.
