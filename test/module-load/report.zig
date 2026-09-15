//! What a load-refusal fixture exports: the two loader symbols, over an
//! `abi.BuildConfig` the fixture chooses rather than the one it was built
//! with.
//!
//! `src/module.zig`'s `entry` reports what the module was built with, so a
//! module written that way is always compatible with the runtime that built
//! it and cannot exercise a refusal. A fixture writes the two symbols through
//! `entry` here instead, and passes the report to be made as its argument.
//!
//! `wrong_bits.zig`, `wrong_zig.zig` and `wrong_api.zig` are the three
//! fixtures, one per field the loader compares, and
//! `test/zig-native-refused.janet` loads each of them.

const std = @import("std");

const abi = @import("abi");

/// Exports `_wattle_mod_config` and `_wattle_init`, reporting `reported`.
///
/// A fixture calls this in a `comptime` block at container level, as a module
/// calls `module.entry`. `_wattle_init` does nothing, because the loader
/// refuses this module before it looks the symbol up.
pub fn entry(comptime reported: abi.BuildConfig) void {
    const Shim = struct {
        fn modConfig(out: *abi.BuildConfig, size: usize) callconv(.c) usize {
            const mine = @sizeOf(abi.BuildConfig);
            const written = @min(size, mine);
            const answer = reported;
            @memcpy(
                @as([*]u8, @ptrCast(out))[0..written],
                std.mem.asBytes(&answer)[0..written],
            );
            return mine;
        }
        fn modInit(env: *anyopaque, rt: *const anyopaque) callconv(.c) void {
            _ = env;
            _ = rt;
        }
    };
    @export(&Shim.modConfig, .{ .name = "_wattle_mod_config" });
    @export(&Shim.modInit, .{ .name = "_wattle_init" });
}

/// A version string in the fixed-width, NUL-padded field
/// `abi.BuildConfig.zig` gives it.
pub fn padded(comptime text: []const u8) [32]u8 {
    comptime {
        var out: [32]u8 = std.mem.zeroes([32]u8);
        @memcpy(out[0..text.len], text);
        return out;
    }
}
