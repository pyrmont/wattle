# native-executable

A Wattle program, runtime and native module compiled into one executable. The
example supports cross-compilation.

`main.wattle` imports the module from `examples/native-events`, hashes one
string and prints the result:

```clojure
(import digest)

(defn main [& args]
  (print (digest/sha256 "abc")))
```

Build from the repository root:

    zig build examples/native-executable                                          # zig-out/bin/native-executable
    zig build examples/native-executable -Dtarget=aarch64-linux-musl -Dlinkage=static  # a static Linux binary
    zig build examples/native-executable -Dtarget=x86_64-macos                    # runs under Rosetta

`zig build test` runs the executable on native builds and checks its output. The
binary requires no `WATTLE_PREFIX`, shared object or external image file.

## Executable structure

The executable embeds the runtime, program image and native module.

### Embedded components

The runtime is the `subsystems` module also imported by the `wattle` client. The
program is a marshalled image of `main.wattle`'s environment, embedded like the
core image. `digest.zig` is compiled into the binary, with nfunction addresses
resolved by the linker. None of these components is read from an external file
at run time.

### Module registration

An nfunction has no wire form. `marshal` writes one only when the dictionary it
is given maps the value to a name, and `unmarshal` reads a name back only when
its dictionary maps the name to a value. `make-image` and `load-image` use the
two dictionaries the core builds for its own functions. Module functions must be
registered separately in both dictionaries.

The image generator and executable register the module under the same name
before generating or loading the image. Registration puts the module's
environment in `module/cache` under that name, so `(import digest)` finds it
without a path, and adds `digest/sha256` to both dictionaries. When the image is
made, `digest/sha256` is written as the name. When the executable starts, the
module's entry point has run, the name is in the dictionary, and the image
resolves to the function linked in.

The build specifies the module's name and uses the same string in both
compilations. Registering it on only one side causes unresolved names to
unmarshal as nil, matching the C runtime's behaviour. No error is reported.

### Image generation

An image is architecture-neutral, so it is made once by a client that runs on
the build machine and embedded into a binary for the target. On a native build
that client is the `wattle` this tree builds. On a cross build the build makes a
second, host-targeted client for the purpose. Either way the module is loaded
into that client as a shared object, registered under its name, and `-c` writes
the image.

### Entry points

Dynamically loaded modules export `_wattle_init` and `_wattle_mod_config`.
Statically linked modules need distinct symbol names to avoid conflicts.
`wattle.entry` uses a build setting to generate symbols based on the module's
registered name. The module source requires no changes: the same `digest.zig`
tested by dynamic loading is compiled again as an object and linked into the
executable.

Before calling the entry point, the executable compares the module's
configuration bits, Zig version and interface fingerprint with its own. The
shared-object loader performs the same check. For this static build, the values
cannot differ and the check has no runtime cost.

### Startup

The executable builds the core environment as the `wattle` client does, then
calls `run-image` with the image, the argument vector and one loader per module.
`run-image` registers each module under its name, loads the image, puts the
arguments in its environment and calls `main`. `wattle -i` performs the same
operations with an image file. The argument vector uses the program name in
place of the image path. The event loop determines the exit status. The
executable does not read `WATTLE_PREFIX` because all required components are
embedded.

### Comparison with `jpm quickbin`

`jpm` generates a C file containing the image as a byte array, an `extern`
declaration for each native function and a `main` that registers functions and
unmarshals the image. Wattle's build function performs these steps through the
Zig interface. It generates no C or `main` function because the runtime has no C
interface. A generated Zig file lists the modules so the executable's source
does not need their names.

## Tests

The checks depend on the build target:

- Native builds check that the executable prints the SHA-256 of `"abc"` and
  exits 0.

- Cross builds check that the executable links. `test/README.md` has the container recipe
  that runs an `aarch64-linux-musl` binary.

`digest` schedules its work through the event loop, so this executable needs a
build with the loop. Under `-Dev=false` the hash raises
`event loop not enabled`, as `examples/native-events/test/digest.wattle` shows.

## External builds

`examples/native-consumer` builds an executable with its own module through the
public build function from its `build.zig`. Run
`zig build examples/native-consumer` from the repository root to check that
build.
