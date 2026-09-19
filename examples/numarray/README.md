# numarray

A native Wattle module written in Zig, and the worked example of an abstract
type.

`numarray.zig` is the whole module. It imports `wattle` and nothing else, and its
header comment says what the interface takes away from the C original it
replaces: the unchecked `(num_array *)p` cast at the top of every callback, and
the `JANET_ATEND_*` macro chain.

    zig build test

builds it and runs `examples/numarray/test/numarray.wattle` against it, which is
what makes "a sample module compiles and loads" a check rather than a claim.

## Building a module outside this repository

This module is compiled by the runtime's own `build()`, with the private module
graph available to it. That proves the source experience: one import, and the
module never names `types`, `raise` or `constants`. It does not prove that an
outside package can obtain the `wattle` module at all.

`examples/standalone` is that proof, and `zig build examples/standalone` runs it. A
consumer's `build.zig.zon` names this package as a dependency and its
`build.zig` asks for one module:

```zig
const wattle = @import("wattle");

const mod = b.createModule(.{
    .root_source_file = b.path("mymodule.zig"),
    .target = target,
    .optimize = optimize,
});
mod.addImport("wattle", wattle.wattleModule(
    b.dependency("wattle", .{ .target = target, .optimize = optimize }),
    target,
    optimize,
));

const lib = b.addLibrary(.{
    .name = "mymodule",
    .linkage = .dynamic,
    .root_module = mod,
});
// The module resolves no runtime symbol. The loading process supplies the
// symbols left undefined.
lib.linker_allow_shlib_undefined = true;
```

### What must match the runtime the module is loaded into

Three things must match, and the loader checks all three.

  - The configuration bits. `config` determines `Value`'s layout, so a module
    built with `-Dnanbox=false` and loaded into a NaN-boxed runtime would be
    wrong values rather than a link error. Pass the same feature options to
    the dependency that the runtime was built with.
    `wattle/config-bits` is the runtime's own set.
  - The Zig version. `wattle` is a source dependency rather than an ABI. Zig
    makes no promise across versions, so a module and the runtime it loads
    into are built with the same Zig version. `build.zig.zon` records the
    minimum. The whole version string is compared, so a release and a
    development build of that release do not match.
  - The interface fingerprint. It is a hash of every declaration the module
    and the runtime share: the runtime table, `Value`, the layouts that cross
    by pointer, the two enums and the callback signatures.
    `wattle/api` is the runtime's own.

The `_wattle_mod_config` symbol the module exports reports all three, and the
loader compares them in the order above. The first difference is a refusal
naming the field, and the module does not load. Wattle's version is reported in
that message and is not compared, so a module built against one release loads
into another whose interface is the same.

## Why this is Zig and not C

Janet's own sample of this module is `numarray.c`, built against a public header
with `jpm`. This runtime installs no header and ships no `jpm`, so there is
nothing for a C version of this file to include or be built by. The module
interface is Zig's, and this is what an author writes against.
