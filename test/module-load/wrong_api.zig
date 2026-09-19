//! A native module reporting an interface fingerprint that is not this
//! build's, so that the loader's third comparison is the one that refuses it.
//!
//! The bits and the compiler version reported are the host's own, so the two
//! comparisons before this one pass. The fingerprint is a fixed number rather
//! than the real one altered, because a fixture cannot compute the real one:
//! `api/fingerprint.zig` is a file of the module a real author imports, and a
//! fixture imports neither that module nor the runtime.
//!
//! Loaded by `test/zig-native-refused.wattle`. `report.zig` says why a fixture
//! exports the loader symbols itself.

const builtin = @import("builtin");

const config = @import("config");
const constants = @import("constants");
const report = @import("report.zig");

comptime {
    report.entry(.{
        .major = config.version_major,
        .minor = config.version_minor,
        .patch = config.version_patch,
        .bits = @intCast(constants.current_config_bits),
        .zig = report.padded(builtin.zig_version_string),
        .api = 0x0123456789abcdef,
    });
}
