[![Join the chat](https://img.shields.io/badge/zulip-join_chat-brightgreen.svg)](https://janet.zulipchat.com)
&nbsp;
[![builds.sr.ht status](https://builds.sr.ht/~bakpakin/janet/commits/master/freebsd.yml.svg)](https://builds.sr.ht/~bakpakin/janet/commits/master/freebsd.yml?)
[![builds.sr.ht status](https://builds.sr.ht/~bakpakin/janet/commits/master/openbsd.yml.svg)](https://builds.sr.ht/~bakpakin/janet/commits/master/openbsd.yml?)
[![Actions Status](https://github.com/janet-lang/janet/actions/workflows/test.yml/badge.svg)](https://github.com/janet-lang/janet/actions/workflows/test.yml)

<img src="https://raw.githubusercontent.com/janet-lang/janet/master/assets/janet-w200.png" alt="Janet logo" width=200 align="left">

**Janet** is a programming language for system scripting, expressive automation, and
extending programs written in C or C++ with user scripting capabilities.

Janet makes a good system scripting language, or a language to embed in other programs.
It's like Lua and GNU Guile in that regard. It has more built-in functionality and a richer core language than
Lua, but smaller than GNU Guile or Python. However, it is much easier to embed and port than Python or Guile.

There is a REPL for trying out the language, as well as the ability
to run script files. This client program is separate from the core runtime, so
Janet can be embedded in other programs. Try Janet in your browser at
<https://janet-lang.org>.

<br>

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

### Windows FFI Hello, World!

```janet
# Use the FFI to popup a Windows message box - no C required

(ffi/context "user32.dll")

(ffi/defbind MessageBoxA :int
  [w :ptr text :string cap :string typ :int])

(MessageBoxA nil "Hello, World!" "Test" 0)
```

## Language Features

* 600+ functions and macros in the core library
* Built-in socket networking, threading, subprocesses, and file system functions.
* Parsing Expression Grammars (PEG) engine as a more robust Regex alternative
* Macros and compile-time computation
* Per-thread event loop for efficient IO (epoll/IOCP/kqueue)
* First-class green threads (continuations) as well as OS threads
* Erlang-style supervision trees that integrate with the event loop
* First-class closures
* Garbage collection
* Distributed as janet.c and janet.h for embedding into a larger program.
* Python-style generators (implemented as a plain macro)
* Mutable and immutable arrays (array/tuple)
* Mutable and immutable hashtables (table/struct)
* Mutable and immutable strings (buffer/string)
* Tail recursion
* Interface with C functions and dynamically load plugins ("natives").
* Built-in C FFI for when the native bindings are too much work
* REPL development with debugger and inspectable runtime

## Documentation

* For a quick tutorial, see [the introduction](https://janet-lang.org/docs/index.html) for more details.
* For the full API for all functions in the core library, see [the core API doc](https://janet-lang.org/api/index.html).

Documentation is also available locally in the REPL.
Use the `(doc symbol-name)` macro to get API
documentation for symbols in the core library. For example,
```
(doc apply)
```
shows documentation for the `apply` function.

To get a list of all bindings in the default
environment, use the `(all-bindings)` function. You
can also use the `(doc)` macro with no arguments if you are in the REPL
to show bound symbols.

## Source

You can get the source on [GitHub](https://github.com/janet-lang/janet) or
[SourceHut](https://git.sr.ht/~bakpakin/janet). While the GitHub repo is the official repo,
the SourceHut mirror is actively maintained.

## Spork and JPM

Spork and JPM are two companion projects to Janet. They are optional, especially in an embedding use case.

Spork is a collection of common utility modules, and several packaged scripts
like `janet-format` for code formatting, `janet-netrepl` for a socket-based
REPL, and `janet-pm` for a comprehensive Janet project manager tool. The
modules in `spork` are less stable than the interfaces in core Janet, although
we try to prevent breaking changes to existing modules, with a preference to
add new modules and functions. Spork requires a C compiler to build and install
various extenstion components such as miniz and JSON utilities. Many spork
sub-modules, for example spork/path, are independent and can be manually
vendored in programmer projects without fully installing spork.

When install Spork, scripts will be installed to $JANET_PATH/bin/ on POSIX systems by default.
This likely needs to be added to the path to use these scripts.

JPM is the older, more opinionated, project manager tool, which has it's pros
and cons. It does not require a C compiler to build and install, but is less
flexible and is not receiving many changes and improvements going forward. It
may also be harder to configure correctly on new systems. In that sense, it may
be more stable.

JPM will install to /usr/local/bin/ on posix systems by default, which may or
may not be on your PATH.

## Building

When building from source, for stability, please use the latest tagged release. For
example, run `git checkout $(git describe --tags --abbrev=0)` after cloning but
before building. For the latest development, build directly on the master
branch. The master branch is not-necessarily stable as most Janet development
happens directly on the master branch.

Janet is built with [Zig](https://ziglang.org). The version is pinned in
`.zigversion` and is currently **0.16.0**; that is the only prerequisite.

```sh
cd somewhere/my/projects/janet
zig build              # the executable and the libraries
zig build test         # the contracts and the Janet test suites
zig build run          # a REPL
```

Artifacts are installed under `zig-out`: the executable in `zig-out/bin` and
the static and shared libraries in `zig-out/lib`. **No header is installed** —
see "Embedding" below. Pass `-p <prefix>` to install somewhere else, and
`zig build --help` to see the feature flags — the runtime can be built without
the event loop, networking, the PEG engine, the assembler, the FFI, integer
types, dynamic modules or docstrings.

```sh
zig build -Doptimize=ReleaseFast          # an optimized build
zig build -Dtarget=aarch64-linux-musl     # cross-compile
```

Cross-compilation needs no extra toolchain: Zig ships the C headers and linkers
for every supported target.

### Supported platforms

| platform | state |
| --- | --- |
| macOS arm64 and x86-64 | built and fully tested |
| Linux, musl | built and fully tested; a musl target links statically |
| Linux, glibc | built and tested in a container at each phase gate, not in CI |
| Windows | cross-compiles; binaries have never been executed |
| 32-bit (riscv32) | compiles only, and is the only target that type-checks the 32-bit paths |

`.github/workflows/test.yml` is what actually runs, and is the honest statement
of what is covered.

### Where the old build systems went

`make`, `meson`, `plan9.mk` and `build_win.bat` are gone. All four named the
fifty C sources this runtime replaced, so none of them could build anything;
they were removed rather than left as instructions that cannot work.


## Development

Janet can be hacked on with pretty much any environment you like. VSCode, Vim,
Emacs and Atom each have syntax packages for the Janet language, and any editor
with Zig support will do for the runtime itself.

`AGENTS.md` at the repository root describes how to work in this tree, and
`tools/README.md` the development instruments beside it — the acceptance
matrix, the leak check and the checked inventories.

## Installation

If you just want to try out the language, you don't need to install anything.
In this case you can also move the `janet` executable wherever you want on
your system and run it.  However, for a fuller setup, please see the
[Introduction](https://janet-lang.org/docs/index.html) for more details.

## Usage

A REPL is launched when the binary is invoked with no arguments. Pass the `-h` flag
to display the usage information. Individual scripts can be run with `./janet myscript.janet`.

If you are looking to explore, you can print a list of all available macros, functions, and constants
by entering the command `(all-bindings)` into the REPL.

```
$ janet
Janet 1.7.1-dev-951e10f  Copyright (C) 2017-2020 Calvin Rose
janet:1:> (+ 1 2 3)
6
janet:2:> (print "Hello, World!")
Hello, World!
nil
janet:3:> (os/exit)
$ janet -h
usage: janet [options] script args...
Options are:
  -h : Show this help
  -v : Print the version string
  -s : Use raw stdin instead of getline like functionality
  -e code : Execute a string of janet
  -E code arguments... : Evaluate an expression as a short-fn with arguments
  -d : Set the debug flag in the REPL
  -r : Enter the REPL after running all scripts
  -R : Disables loading profile.janet when JANET_PROFILE is present
  -p : Keep on executing if there is a top-level error (persistent)
  -q : Hide logo (quiet)
  -k : Compile scripts but do not execute (flycheck)
  -m syspath : Set system path for loading global modules
  -c source output : Compile janet source code into an image
  -i : Load the script argument as an image file instead of source code
  -n : Disable ANSI color output in the REPL
  -l lib : Use a module before processing more arguments
  -w level : Set the lint warning level - default is "normal"
  -x level : Set the lint error level - default is "none"
  -- : Stop handling options
```

If installed, you can also run `man janet` to get usage information.

## Embedding

`zig build` produces `zig-out/lib/libjanet.a` and `zig-out/lib/libjanet.so`
(or `.dylib`). The library exports 434 C symbols, and `src/zig/capi.zig` is the
one file that publishes them: every entry point there states the signature it
publishes, and the compiler checks it.

**No header is installed, and there is no amalgamated `janet.c`.** Janet's
`janet.h` declared this surface with nothing comparing a declaration against
its definition, so shipping it would promise less than the tree keeps. What a C
caller sees is `capi.zig`; a generated header is not written yet.

**The native-module interface is Zig.** `src/zig/module.zig` is what a module
imports, and `examples/numarray/` is the worked example. A C program cannot
define a cfunction for this runtime: a cfunction returns an error union over
Zig's own calling convention, so no C body can have that type and no C caller
can invoke one. The same applies to a `JanetAbstractType`'s callbacks.

Native modules are therefore written in Zig. `examples/numarray/numarray.zig`
imports `janet` and nothing else, which is the whole of the interface.

## Discussion

Feel free to ask questions and join the discussion on the [Janet Zulip Instance](https://janet.zulipchat.com/)

## FAQ

### How fast is it?

It is about the same speed as most interpreted languages without a JIT compiler. Tight, critical
loops should probably be written in C or C++ . Programs tend to be a bit faster than
they would be in a language like Python due to the discouragement of slow Object-Oriented abstraction
with lots of hash-table lookups, and making late-binding explicit. All values are boxed in an 8-byte
representation by default and allocated on the heap, with the exception of numbers, nils and booleans. The
PEG engine is a specialized interpreter that can efficiently process string and buffer data.

The GC is simple and stop-the-world, but GC knobs are exposed in the core library and separate threads
have isolated heaps and garbage collectors. Data that is shared between threads is reference counted.

YMMV.

### Where is (favorite feature from other language)?

It may exist, it may not. If you want to propose a major language feature, go ahead and open an issue, but
it will likely be closed as "will not implement". Often, such features make one usecase simpler at the expense
of 5 others by making the language more complicated.

### Is there a language spec?

There is not currently a spec besides the documentation at <https://janet-lang.org>.

### Is this Scheme/Common Lisp? Where are the cons cells?

Nope. There are no cons cells here.

### Is this a Clojure port?

No. It's similar to Clojure superficially because I like Lisps and I like the aesthetics.
Internally, Janet is not at all like Clojure, Scheme, or Common Lisp.

### Are the immutable data structures (tuples and structs) implemented as hash tries?

No. They are immutable arrays and hash tables. Don't try and use them like Clojure's vectors
and maps, instead they work well as table keys or other identifiers.

### Can I do object-oriented programming with Janet?

To some extent, yes. However, it is not the recommended method of abstraction, and performance may suffer.
That said, tables can be used to make mutable objects with inheritance and polymorphism, where object
methods are implemented with keywords.

```clj
(def Car @{:honk (fn [self msg] (print "car " self " goes " msg)) })
(def my-car (table/setproto @{} Car))
(:honk my-car "Beep!")
```

### Why can't we add (feature from Clojure) into the core?

Usually, one of a few reasons:
- Often, it already exists in a different form and the Clojure port would be redundant.
- Clojure programs often generate a lot of garbage and rely on the JVM to clean it up.
  Janet does not run on the JVM and has a more primitive garbage collector.
- We want to keep the Janet core small. With Lisps, a feature can usually be added as a library
  without feeling "bolted on", especially when compared to ALGOL-like languages. Adding features
  to the core also makes it a bit more difficult to keep Janet maximally portable.

### Can I bind to Rust/Zig/Go/Java/Nim/C++/D/Pascal/Fortran/Odin/Jai/(Some new "Systems" Programming Language)?

Probably, if that language has a good interface with C. But the programmer may need to do
some extra work to map Janet's internal memory model to that of the bound language. Janet
also uses `setjmp`/`longjmp` for non-local returns internally. This
approach is out of favor with many programmers now and doesn't always play well with other languages
that have exceptions or stack-unwinding.

### Why is my terminal spitting out junk when I run the REPL?

Make sure your terminal supports ANSI escape codes. Most modern terminals will
support these, but some older terminals, Windows consoles, or embedded terminals
will not. If your terminal does not support ANSI escape codes, run the REPL with
the `-n` flag, which disables color output. You can also try the `-s` flag if further issues
ensue.

## Why is it called "Janet"?

Janet is named after the almost omniscient and friendly artificial being in [The Good Place](https://en.wikipedia.org/wiki/The_Good_Place).
