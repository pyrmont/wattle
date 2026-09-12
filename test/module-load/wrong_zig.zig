//! A native module reporting a compiler version no compiler has, so that the
//! loader's second comparison is the one that refuses it.
//!
//! The bits reported are the host's own, so the comparison before this one
//! passes, and `api` is left at zero, so a refusal naming `api version` is the
//! comparisons running out of order.
//!
//! Loaded by `test/zig-native-refused.janet`. `report.zig` says why a fixture
//! exports the loader symbols itself.

const config = @import("config");
const constants = @import("constants");
const report = @import("report.zig");

comptime {
    report.entry(.{
        .major = config.version_major,
        .minor = config.version_minor,
        .patch = config.version_patch,
        .bits = @intCast(constants.JANET_CURRENT_CONFIG_BITS),
        .zig = report.padded("0.0.0-fixture"),
    });
}
