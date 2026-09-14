# Janet

[![Test Status][icon]][status]

[icon]: https://github.com/pyrmont/janet/actions/workflows/test.yml/badge.svg
[status]: https://github.com/pyrmont/janet/actions?query=workflow%3ATest

> [!WARNING]
> This is an experimental attempt to implement the Janet programming language in Zig.
> It was written primarily using LLM-based coding agents.

**Janet** is a programming language for system scripting and expressive
automation. It has more built-in functionality and a richer core language than
Lua, but is smaller than GNU Guile or Python.

This repository is an implementation of Janet in [Zig](https://ziglang.org).
The Zig imlementation aims to run Janet source identically to the [C
implementation](https://github.com/janet-lang/janet). What differs is the
runtime underneath, how it is built, and how native modules are written.

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

Janet is built with [Zig](https://ziglang.org). The version is pinned in
`.zigversion` and is currently **0.16.0**.

```sh
git clone https://github.com/pyrmont/janet
cd janet
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
wasmtime run --dir . zig-out/bin/janet.wasm
```

A WASI program sees only the directories which are mapped in, so a script and
everything it reads have to be in this tree.  The default `syspath` is
`/usr/local/lib/janet`, so `import` needs that name mapped — `--dir
<host-dir>::/usr/local/lib/janet` — or `JANET_PATH` set to a directory that is:

```sh
wasmtime run --dir . --env JANET_PATH=./lib zig-out/bin/janet.wasm script.janet
```

### Supported platforms

| platform               | state                                                         |
| ---------------------- | ------------------------------------------------------------- |
| macOS arm64 and x86-64 | built and fully tested                                        |
| Linux, musl            | built and fully tested; dynamic by default, needs musl loader |
| Linux, glibc           | built and tested in a container at each phase gate, not in CI |
| Windows                | cross-compiles; binaries have never been executed             |
| wasm32-wasi            | built and fully tested under wasmtime, without the event loop |
| 32-bit (riscv32)       | compiles only; wasm32-wasi is the 32-bit target that runs     |

## Installing

If you just want to try out the language, you don't need to install anything.
In this case you can also move the `janet` executable wherever you want on your
system and run it. However, for a fuller setup, please see the
[Introduction](https://janet-lang.org/docs/index.html) for more details.

## Using

A REPL is launched when the binary is invoked with no arguments. Pass the `-h`
flag to display the usage information. Individual scripts can be run with
`./janet myscript.janet`.

If you are looking to explore, you can print a list of all available macros,
functions, and constants by entering the command `(all-bindings)` into the
REPL.

```
$ janet
Janet 1.41.3-dev-zig macos/aarch64/zig - '(doc)' for help
repl:1:> (+ 1 2 3)
6
repl:2:> (print "Hello, World!")
Hello, World!
nil
repl:3:> (os/exit)
$ janet -h
usage: janet [options] script args...
Options are:
  --help (-h)             : Show this help
  --version (-v)          : Print the version string
  --stdin (-s)            : Use raw stdin instead of getline like functionality
  --eval (-e) code        : Execute a string of janet
  --expression (-E) code arguments... : Evaluate an expression as a short-fn with arguments
  --debug (-d)            : Set the debug flag in the REPL
  --repl (-r)             : Enter the REPL after running all scripts
  --noprofile (-R)        : Disables loading profile.janet when JANET_PROFILE is present
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

The manual page `janet.1` is in the repository root. `zig build` does not
install it; `man ./janet.1` reads it in place.

## Extending

Janet can be extended with _native modules_.  **The native-module interface is
Zig.** `src/module.zig` is what a module imports. `examples/numarray/` is a
worked example. A C program cannot define a cfunction for this runtime: a
cfunction returns an error union over Zig's own calling convention, so no C
body can have that type and no C caller can invoke one. The same applies to a
`JanetAbstractType`'s callbacks. Native modules are therefore written in Zig.

A module records the interface it was built against as a fingerprint, and the
loader refuses to load this unless that fingerprint, the configuration bits and
the Zig version all match the runtime's own. `janet/api` is the runtime's
fingerprint. Janet's version is not compared, so a module built against one
release loads into another whose interface is the same.

A module can also be linked into an executable, together with the runtime and
an image of a Janet program, so that one file cross-compiles and runs with
nothing beside it. `zig build quickbin` builds `examples/quickbin/`, which links
`examples/digest/` in, and `build.zig`'s `quickbin` function builds one from
outside the tree (`examples/standalone/`).

**No header is installed, and there is no amalgamated `janet.c`.** The client
does not link against the library either: it imports the runtime as a Zig
module.

## Contributing

Janet can be hacked on with pretty much any environment you like. VSCode, Vim,
Emacs and Atom each have syntax packages for the Janet language, and any editor
with Zig support will do for the runtime itself.

`tools/README.md` explains the development instruments used in porting — the
acceptance matrix, the leak check and the checked inventories.

## FAQ

### How fast is it?

It is about the same speed as most interpreted languages without a JIT
compiler, and this implementation is benchmarked against the C implementation
to stay close to it. Tight, critical loops should probably be written in a
native module. Programs tend to be a bit faster than they would be in a
language like Python due to the discouragement of slow object-oriented
abstractions with lots of hash-table lookups and by making late-binding
explicit.

On x86-64, aarch64 and riscv64, and on 32-bit targets, a value is 8 bytes;
numbers, nils and booleans are held in the value itself and everything else is
allocated on the heap. The PEG engine is a specialized interpreter that can
efficiently process string and buffer data.

The GC is simple and stop-the-world, but GC knobs are exposed in the core
library and separate threads have isolated heaps and garbage collectors. Data
that is shared between threads is reference counted.

### Where is (favorite feature from other language)?

It may exist, it may not. If you want to propose a major language feature, go
ahead and open an issue, but it will likely be closed as "will not implement".
Often, such features make one usecase simpler at the expense of 5 others by
making the language more complicated.

### Is there a language spec?

There is not currently a spec besides the documentation at
<https://janet-lang.org>.

### Is this Scheme/Common Lisp? Where are the cons cells?

Nope. There are no cons cells here.

### Is this a Clojure port?

No. It's similar to Clojure superficially because I like Lisps and I like the
aesthetics.  Internally, Janet is not at all like Clojure, Scheme, or Common
Lisp.

### Are the immutable data structures (tuples and structs) implemented as hash tries?

No. They are immutable arrays and hash tables. Don't try and use them like
Clojure's vectors and maps, instead they work well as table keys or other
identifiers.

### Can I do object-oriented programming with Janet?

To some extent, yes. However, it is not the recommended method of abstraction,
and performance may suffer. That said, tables can be used to make mutable
objects with inheritance and polymorphism, where object methods are implemented
with keywords.

```janet
(def Car @{:honk (fn [self msg] (print "car " self " goes " msg)) })
(def my-car (table/setproto @{} Car))
(:honk my-car "Beep!")
```

### Why can't we add (feature from Clojure) into the core?

Usually, one of a few reasons:
- Often, it already exists in a different form and the Clojure port would be
  redundant.
- Clojure programs often generate a lot of garbage and rely on the JVM to clean
  it up.  Janet does not run on the JVM and has a more primitive garbage
  collector.
- We want to keep the Janet core small. With Lisps, a feature can usually be
  added as a library without feeling "bolted on", especially when compared to
  ALGOL-like languages. Adding features to the core also makes it a bit more
  difficult to keep Janet maximally portable.

### Can I bind to Rust/Zig/Go/Java/Nim/C++/D/Pascal/Fortran/Odin/Jai/(Some new
"Systems" Programming Language)?

Zig, yes: native modules are written in Zig (see "Native modules"). For other
languages, calling into a C library from Janet is what the FFI is for. Defining
a cfunction in another language is not possible, because a cfunction returns an
error union over Zig's own calling convention. A raise is a Zig error return
rather than a `setjmp`/`longjmp` jump, so no non-local jump crosses a frame of
foreign code.

### Why is my terminal spitting out junk when I run the REPL?

Make sure your terminal supports ANSI escape codes. Most modern terminals will
support these, but some older terminals, Windows consoles, or embedded
terminals will not. If your terminal does not support ANSI escape codes, run
the REPL with the `-n` flag, which disables color output. You can also try the
`-s` flag if further issues ensue.

## Why is it called "Janet"?

Janet is named after the almost omniscient and friendly artificial being in
[The Good Place](https://en.wikipedia.org/wiki/The_Good_Place).
