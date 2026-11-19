# ffi

Calls into C libraries through the FFI. Each script binds C functions with
`ffi/context` and `ffi/defbind` and then calls them as Wattle functions.

- `test.wattle` compiles `so.c` into a shared library with `cc`, or `cl.exe`
  on Windows, and binds its functions. It round-trips values through
  `ffi/write` and `ffi/read`, calls each function, and asserts the results.
  The functions take and return integers, floats, doubles and structs of
  several layouts, including calls with enough arguments to pass some on
  the stack.

- `so.c` is the library that `test.wattle` builds.

- `gtk.wattle` opens a GTK 3 window with a button whose label changes when it
  is clicked. It loads `/usr/lib/libgtk-3.so` on first use and passes Wattle
  functions to GTK as callbacks through `ffi/trampoline`.

- `win32.wattle` shows a Windows message box from `user32.dll`.

`test.wattle` takes its paths from the repository root:

```sh
wattle res/examples/ffi/test.wattle
```

It writes `res/examples/ffi/so.so`, or `so.dll` on Windows, and prints `Done.`
when every assertion holds.

```sh
wattle res/examples/ffi/gtk.wattle     # Linux with GTK 3
wattle res/examples/ffi/win32.wattle   # Windows
```

`ffi/jitfn` is in `res/examples/jitfn`.
