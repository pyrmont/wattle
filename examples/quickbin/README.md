# quickbin

A Janet program, the runtime and a native module in one executable, and the
worked example of a build that cross-compiles it.

`main.janet` is the whole program. It imports `examples/digest`, hashes one
string and prints the result:

```janet
(import digest)

(defn main [& args]
  (print (digest/sha256 "abc")))
```

    zig build quickbin                               # zig-out/bin/quickbin
    zig build quickbin -Dtarget=aarch64-linux-musl   # a static Linux binary
    zig build quickbin -Dtarget=x86_64-macos         # runs under Rosetta

builds it, and `zig build test` runs it on a native build and checks the
output. The binary needs no `JANET_PATH`, no shared object and no image file
beside it.

## What it shows

### What the executable contains

Three things, and nothing is read at run time. The runtime is the same
`subsystems` module the `janet` client imports. The program is a marshalled
image of `main.janet`'s environment, embedded the way the core image is. The
module is `digest.zig` compiled into the same binary, so its cfunctions are
addresses the linker resolved rather than symbols a loader looks up.

### The image names the module rather than containing it

A cfunction has no wire form. `marshal` writes one only when the dictionary it
is given maps the value to a name, and `unmarshal` reads a name back only when
its dictionary maps the name to a value. `make-image` and `load-image` use the
two dictionaries the core builds for its own functions. A module's functions are
not in either.

Both sides therefore register the module under one name before touching the
image. Registration puts the module's environment in `module/cache` under that
name, so `(import digest)` finds it without a path, and adds `digest/sha256` to
both dictionaries. When the image is made, `digest/sha256` is written as the
name. When the executable starts, the module's entry point has run, the name is
in the dictionary, and the image resolves to the function linked in.

The name is the contract. It is chosen by the build, not by the module, and the
same string is used on both sides. A name registered on one side only fails
silently: an unregistered name unmarshals as nil, which is what the C runtime
does with it too.

### Making the image is a host step

An image is architecture-neutral, so it is made once by a client that runs on
the build machine and embedded into a binary for the target. On a native build
that client is the `janet` this tree builds. On a cross build the build makes a
second, host-targeted client for the purpose. Either way the module is loaded
into that client as a shared object, registered under its name, and `-c` writes
the image.

### One entry point per module

A module built to be loaded exports `_janet_init` and `_janet_mod_config`, and
the loader finds them by name. Two modules linked into one binary cannot both
export those, so a module built to be linked exports the same two under its
registered name instead. `janet.entry` does this on a build setting, and the
module's source is unchanged: `digest.zig` is the file `zig build test` loads
dynamically, compiled a second time as an object of its own and linked in.

The configuration check is the same one. Before the entry point runs, the
executable compares the module's configuration bits, Zig version and interface
fingerprint with its own, as the loader does for a shared object. In a static
link they cannot differ, and the check costs nothing.

### What happens at start-up

The executable builds the core environment as the `janet` client does, then
calls `run-image` with the image, the argument vector and one loader per
module. `run-image` registers each module under its name, loads the image, puts
the arguments in its environment and calls `main`, which is what `janet -i`
does with an image file. The program name stands where the image path would,
and the exit status is the event loop's. What the executable does not do is
read `JANET_PATH` or `JANET_PROFILE`: there is nothing on the path it needs.

### What differs from `jpm quickbin`

`jpm` writes a C file: the image as a byte array, one `extern` declaration per
native, a `main` that registers each and unmarshals. Here the build function is
that file. There is no C, and no generated `main`, because the runtime has no C
interface to generate against. What is generated is one small Zig file that
lists the modules, so that the executable's source does not have to spell
their names.

## What the test asserts

- On a native build, that the executable prints the SHA-256 of `"abc"` and
  exits 0.
- On a cross build, that it links. `test/README.md` has the container recipe
  that runs an `aarch64-linux-musl` binary.

`digest` schedules its work through the event loop, so this executable needs
a build with the loop. Under `-Dev=false` the hash raises `event loop not
enabled`, as `examples/digest/test/digest.janet` shows.

## Building one outside this repository

`examples/standalone` does it, with its own module rather than `digest`. Its
`build.zig` calls the one public function this build offers for the purpose,
and `zig build standalone` at the repository root runs that build.
