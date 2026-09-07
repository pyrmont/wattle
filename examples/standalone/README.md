# standalone

A native module built the way an author outside this repository builds a
module.

`examples/numarray` is the module an author reads: one import, and it never
names `types`, `raise` or `constants`. It is compiled by this repository's
`build()`, with the private `RuntimeGraph`, the generated configuration and the
internal modules already available. So it proves the source experience and does
not fail when the published build surface stops working.

This package does fail. It is a package of its own with its own `build.zig.zon`,
it depends on `janet` by path, and it reaches the runtime only through the one
public function `janet.janetModule`. Nothing private is available to it.

    zig build standalone      # from the repository root
    zig build                 # from this directory

`greet.zig` is deliberately small: one cfunction, one abstract type, one
registration. Its job is to fail when the interface changes, rather than to
demonstrate anything `numarray` demonstrates better.

A real consumer writes a URL and a hash where `build.zig.zon` here writes `.path
= "../.."`. Nothing else differs. `examples/numarray/README.md` has the two
requirements that are not checked: the Zig version and the build configuration
must match the runtime the module is loaded into.
