# jitfn

Calls machine code from a byte string through the FFI. `ffi/jitfn` copies the
bytes into executable memory, and `ffi/call` calls them as a function that
takes no arguments and returns nothing.

- `hello.nasm` is x86-64 assembly that writes `Hello, world!` to standard
  output with the `write` system call and returns.

- `hello.bin` is `hello.nasm` assembled.

- `jitfn.wattle` reads `hello.bin`, calls it, and prints the bytes.

The system call numbers are Linux's, so the example runs only on x86-64 Linux.
`jitfn.wattle` reads `hello.bin` from the current directory:

```sh
cd examples/jitfn
nasm hello.nasm -o hello.bin   # only after editing hello.nasm
wattle jitfn.wattle
```
