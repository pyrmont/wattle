# native-abstract

A native Wattle module written in Zig that demonstrates an abstract type.

`numarray.zig` implements the module and imports only `wattle`. Its header
compares the interface with the C original, including the replacement of
unchecked `(num_array *)p` casts and the `JANET_ATEND_*` macro chain.

`zig build test` builds the module and runs
`examples/native-abstract/test/numarray.wattle` against it. The test checks
compilation, loading and module behaviour.

## External builds

The runtime's `build()` compiles this module with access to the private module
graph. It checks that module source needs only one import and no references to
`types`, `raise` or `constants`.

`zig build examples/native-consumer` checks the public build interface from a
separate package. That package's `build.zig.zon` declares Wattle as a
dependency, and its `build.zig` obtains the `wattle` module as follows:

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

### Runtime compatibility

The loader requires three matching properties:

- Configuration bits in `config` determine `Value`'s layout. Loading a module
  built with `-Dnanbox=false` into a NaN-boxed runtime would misinterpret values
  without a link error. Pass the runtime's feature options to the dependency.
  `wattle/config-bits` reports the runtime's configuration bits.

- Zig versions must match because Wattle is a source dependency and Zig does not
  guarantee compatibility across versions. `build.zig.zon` specifies the minimum
  version. The loader compares the complete version string, so release and
  development builds of that version do not match.

- Interface fingerprints must match. The fingerprint hashes all shared
  declarations: the runtime table, `Value`, layouts passed by pointer, the two
  enums and callback signatures. `wattle/api` reports the runtime's fingerprint.

The module exports `_wattle_mod_config` to report these properties. The loader
compares them in the order above and rejects the module at the first mismatch.
The error identifies the differing field and reports Wattle's version. Wattle
versions are not compared, allowing modules to load across releases with
compatible interfaces.

## Module language

Janet's example, `numarray.c`, builds against a public header with `jpm`. Wattle
installs no header and includes no `jpm`. Native modules use the Zig interface
demonstrated here.
