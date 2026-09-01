# numarray

A native Janet module written in Zig, and the worked example of `DESIGN.md`
sections 5 and 6.

`numarray.zig` is the whole module. It imports `janet` and nothing else, and
its header comment says what the interface takes away from the C original it
replaces — the unchecked `(num_array *)p` cast at the top of every callback,
and the `JANET_ATEND_*` macro chain.

    zig build test

builds it and runs `test/numarray.janet` against it, which is what makes "a
sample module compiles and loads" a check rather than a claim.

## Building one outside this repository

This module is compiled by the runtime's own `build()`, with the private module
graph in hand. That proves the *source* experience -- one import, and the
module never names `types`, `raise` or `constants` -- and it does **not** prove
that an outside package can obtain the `janet` module at all.

`examples/standalone` is that proof, and `zig build standalone` runs it. A
consumer's `build.zig.zon` names this package as a dependency and its
`build.zig` asks for one module:

```zig
const janet = @import("janet");

const mod = b.createModule(.{
    .root_source_file = b.path("mymodule.zig"),
    .target = target,
    .optimize = optimize,
});
mod.addImport("janet", janet.janetModule(
    b.dependency("janet", .{ .target = target, .optimize = optimize }),
    target,
    optimize,
));

const lib = b.addLibrary(.{ .name = "mymodule", .linkage = .dynamic, .root_module = mod });
// The runtime supplies every `janet_*` symbol at load time.
lib.linker_allow_shlib_undefined = true;
```

**Two things must match the runtime the module is loaded into, and neither is
checked for you.**

  - **The Zig version.** `janet` is a source dependency, not an ABI. Zig makes
    no promise across versions, so a module and the runtime it loads into are
    built with the same one. `build.zig.zon` records the minimum.
  - **The configuration.** `config` decides `Value`'s layout, so a module built
    with `-Dnanbox=false` and loaded into a NaN-boxed runtime is not a link
    error -- it is wrong values, silently. Pass the same feature options to the
    dependency that the runtime was built with.

The `janet_mod_config` symbol the module exports is the runtime's own check of
the second of these at load time, and it covers the representation and the
threading model rather than every option.

## Why this is Zig and not C

Janet's own sample of this module is `numarray.c`, built against a public
header with `jpm`. Claret installs no header and ships no `jpm`, so there is
nothing for a C version of this file to include or be built by; the module
interface is the Zig one and this is what an author writes against.
