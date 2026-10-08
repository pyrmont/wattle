# native-consumer

A separate package that builds a native module and an executable through
Wattle's public build interface.

`examples/native-abstract` demonstrates module source with one import and no
references to `types`, `raise` or `constants`. `examples/native-executable`
demonstrates executable source. Both use this repository's `build()`, with
access to the private `RuntimeGraph`, generated configuration and internal
modules. They do not test whether an external package can use the public build
interface.

This package has its own `build.zig.zon` and a path dependency on `wattle`. It
uses only `wattle.wattleModule` and `wattle.wattleExecutable`, without access to
private declarations. Its build checks the interface available to external
packages.

    zig build examples/native-consumer      # from the repository root
    zig build test            # from this directory

`greet.zig` defines one nfunction, one abstract type and one registration to
check interface changes. It is built twice: as the shared object `libgreet` and
linked into the executable `hello`. See `numarray` for a fuller example of an
abstract type.

`main.wattle` is the program inside `hello`. It imports `greet`, which needs no
file because the module is linked in, and prints the name of the abstract type
`(greet/hello)` returns. `zig build test` in this directory runs the executable
and checks that line.

An external consumer replaces `.path = "../.."` in `build.zig.zon` with a URL
and hash. The rest of the build is unchanged.
`examples/native-abstract/README.md` describes two requirements this example
does not test: the module's Zig version and build configuration must match the
runtime that loads it. The executable needs no separate compatibility check for
those settings because its module and runtime are built together.

## Build dependencies

`build.zig` instantiates the `wattle` dependency twice. `hello` links the
instance built for the target. The second instance runs on the build machine;
its client generates the image of `main.wattle`. Images are
architecture-neutral, so the image can be generated on the build machine and
embedded in a binary for any target. Native builds use the same target for both
instances. `examples/native-executable/README.md` describes the image's contents
and module registration in both builds.
