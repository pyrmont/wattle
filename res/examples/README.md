# Examples

Programs written in Wattle, and projects that build, install or embed it. A
script is run from the repository root, and its first comment says what it
shows and how to run it. A directory has a README of its own.

## The language

| example                                          | what it shows                                     |
| ------------------------------------------------ | ------------------------------------------------- |
| [`hello.wattle`](hello.wattle)                   | printing a line                                   |
| [`fizzbuzz.wattle`](fizzbuzz.wattle)             | `loop` with a `:let` modifier                     |
| [`primes.wattle`](primes.wattle)                 | the primes below 100 by trial division            |
| [`3sum.wattle`](3sum.wattle)                     | 3SUM with a table of indices                      |
| [`maxtriangle.wattle`](maxtriangle.wattle)       | the largest path sum in a triangle, with `reduce` |
| [`life.wattle`](life.wattle)                     | Conway's Game of Life                             |
| [`colors.wattle`](colors.wattle)                 | ANSI terminal colours                             |
| [`lazyseqs.wattle`](lazyseqs.wattle)             | lazy sequences built from a macro and closures    |
| [`weak-tables.wattle`](weak-tables.wattle)       | tables with weak keys and weak values             |
| [`assembly.wattle`](assembly.wattle)             | a function written in bytecode assembly           |
| [`urlloader.wattle`](urlloader.wattle)           | a module loader that imports from a URL           |
| [`error.wattle`](error.wattle)                   | the stack trace of a runtime error                |
| [`debug.wattle`](debug.wattle)                   | the debug REPL and breakpoints                    |
| [`rtest.wattle`](rtest.wattle)                   | the distribution of `math/random`                 |
| [`marshal-stress.wattle`](marshal-stress.wattle) | the time to marshal large nested tables           |

## Fibers, threads and the event loop

| example                                                | what it shows                              |
| ------------------------------------------------------ | ------------------------------------------ |
| [`iterate-fiber.wattle`](iterate-fiber.wattle)         | iterating over a fiber with `each`         |
| [`evsleep.wattle`](evsleep.wattle)                     | fibers that sleep with `ev/sleep`          |
| [`channel.wattle`](channel.wattle)                     | a channel with one writer and many readers |
| [`select.wattle`](select.wattle)                       | `ev/rselect` over several channels         |
| [`select2.wattle`](select2.wattle)                     | `ev/rselect` with reads and a write        |
| [`threaded-channels.wattle`](threaded-channels.wattle) | a channel between threads                  |
| [`evlocks.wattle`](evlocks.wattle)                     | locks and read-write locks across threads  |

## The operating system

| example                                        | what it shows                              |
| ---------------------------------------------- | ------------------------------------------ |
| [`lineloop.wattle`](lineloop.wattle)           | reading standard input line by line        |
| [`async-execute.wattle`](async-execute.wattle) | subprocesses that run at the same time     |
| [`posix-exec.wattle`](posix-exec.wattle)       | replacing the process with `os/posix-exec` |
| [`sigaction.wattle`](sigaction.wattle)         | a signal handler set with `os/sigaction`   |

## Networking

The servers and clients are in pairs, and a server is started before its
client.

| example                                                      | what it shows                             |
| ------------------------------------------------------------ | ----------------------------------------- |
| [`tcpserver.wattle`](tcpserver.wattle)                       | a TCP echo server                         |
| [`tcpclient.wattle`](tcpclient.wattle)                       | a client for `tcpserver.wattle`           |
| [`udpserver.wattle`](udpserver.wattle)                       | a UDP echo server                         |
| [`udpclient.wattle`](udpclient.wattle)                       | a client for `udpserver.wattle`           |
| [`chatserver.wattle`](chatserver.wattle)                     | a chat server for clients such as `nc`    |
| [`abstract-unix-socket.wattle`](abstract-unix-socket.wattle) | an abstract Unix domain socket, on Linux  |
| [`http-server.wattle`](http-server.wattle)                   | a static file server for the web examples |

## The FFI

| example           | what it shows                                     |
| ----------------- | ------------------------------------------------- |
| [`ffi`](ffi/)     | binding and calling C functions                   |
| [`jitfn`](jitfn/) | calling machine code from a byte string, on Linux |

## Applications

| example                       | what it shows                                       |
| ----------------------------- | --------------------------------------------------- |
| [`app-program`](app-program/) | an application that installs a program and its page |
| [`app-empty`](app-empty/)     | a directory that is not an application              |

## Native modules

| example                                   | what it shows                                         |
| ----------------------------------------- | ----------------------------------------------------- |
| [`native-function`](native-function/)     | a Zig module that reads built-in types through views  |
| [`native-abstract`](native-abstract/)     | a Zig module that defines an abstract type            |
| [`native-events`](native-events/)         | a Zig module that schedules work on the event loop    |
| [`native-consumer`](native-consumer/)     | a separate package that builds a module and a program |
| [`native-executable`](native-executable/) | a program, the runtime and a module in one executable |

## Wattle on the web

Each page is served with `http-server.wattle`. `web-greeter` is the
introduction, and `web-counter` and `web-errors` extend it.

| example                       | what it shows                                    |
| ----------------------------- | ------------------------------------------------ |
| [`web-greeter`](web-greeter/) | a program called once from a page with `run`     |
| [`web-counter`](web-counter/) | a program called repeatedly with `load`          |
| [`web-errors`](web-errors/)   | what `run` returns when a program fails or exits |
| [`web-repl`](web-repl/)       | a REPL in a page                                 |
