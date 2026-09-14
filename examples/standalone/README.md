# standalone

A native module and an executable that links it in, both built the way an
author outside this repository builds them.

`examples/numarray` is the module an author reads: one import, and it never
names `types`, `raise` or `constants`. `examples/quickbin` is the executable an
author reads. Both are compiled by this repository's `build()`, with the private
`RuntimeGraph`, the generated configuration and the internal modules already
available. So they prove the source experience and do not fail when the
published build surface stops working.

This package does fail. It is a package of its own with its own `build.zig.zon`,
it depends on `janet` by path, and it reaches the runtime only through the two
public functions `janet.janetModule` and `janet.quickbin`. Nothing private is
available to it.

    zig build examples/standalone      # from the repository root
    zig build test            # from this directory

`greet.zig` is deliberately small: one cfunction, one abstract type, one
registration. Its job is to fail when the interface changes, rather than to
demonstrate anything `numarray` demonstrates better. It is built twice here: as
the shared object `libgreet`, and linked into the executable `hello`.

`main.janet` is the program inside `hello`. It imports `greet`, which needs no
file because the module is linked in, and prints the name of the abstract type
`(greet/hello)` returns. `zig build test` in this directory runs the executable
and checks that line.

A real consumer writes a URL and a hash where `build.zig.zon` here writes `.path
= "../.."`. Nothing else differs. `examples/numarray/README.md` has the two
requirements that are not checked: the Zig version and the build configuration
must match the runtime the module is loaded into. The executable has neither
requirement, because the module and the runtime inside it are one build.

## The executable's two dependencies

`build.zig` instantiates the `janet` dependency twice. The first is built for
the target and is what `hello` links. The second is built for the machine
running the build, and its client is what makes the image of `main.janet`. An
image is architecture-neutral, so it is made once on the build machine and
embedded into a binary for any target. On a native build both instances are
built for the same machine. `examples/quickbin/README.md` explains what the
image contains and how the module is registered on both sides.
