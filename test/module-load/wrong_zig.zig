//! A native module reporting a compiler version no compiler has, so that the
//! loader's second comparison is the one that refuses it.
//!
//! The bits reported are the host's own, so the comparison before this one
//! passes, and `api` is left at zero, so a refusal naming `api version` is the
//! comparisons running out of order.
//!
//! Loaded by `test/zig-native-refused.wattle`. `report.zig` says why a fixture
//! exports the loader symbols itself.

const constants = @import("constants");
const report = @import("report.zig");

comptime {
    report.entry(.{
        .bits = @intCast(constants.current_config_bits),
        .zig = report.padded(32, "0.0.0-fixture"),
        .label = report.padded(64, "fixture"),
    });
}
