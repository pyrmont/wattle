//! A native module reporting configuration bits no build sets, so that the
//! loader's first comparison is the one that refuses it.
//!
//! Bit `0x40000000` names no option. `constants.JANET_CURRENT_CONFIG_BITS`
//! with that bit added therefore differs from the host's bits whatever this
//! build was configured with, and the fields the loader compares after `bits`
//! are the host's own, so a refusal naming either of those two is the
//! comparisons running out of order.
//!
//! Loaded by `test/zig-native-refused.janet`. `report.zig` says why a fixture
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
        .bits = @intCast(constants.JANET_CURRENT_CONFIG_BITS | 0x40000000),
        .zig = report.padded(builtin.zig_version_string),
    });
}
