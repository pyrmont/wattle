//! The keyword vocabularies of `filewatch.c`, for every platform at once.
//!
//! `filewatch/add` and `filewatch/new` take their options as keywords, and each
//! backend has its own set: inotify names on Linux, `ReadDirectoryChangesW`
//! names on Windows, and kqueue's `NOTE_*` names on the BSDs and macOS. In C
//! each table sits inside the `#ifdef` for its own backend, so on any one host
//! the other two are not merely unreachable but uncompiled. All three are
//! compiled here, on every target, and asserted by `test/filewatch_flags.c`.
//!
//! Only the *names* move. Every flag's value is a host constant — `IN_ATTRIB`,
//! `FILE_NOTIFY_CHANGE_SIZE`, `NOTE_EXTEND` — so C keeps a value array in the
//! same order and indexes it with what the lookup reports. That split is also
//! what lets the BSD table vary: the `NOTE_*` set differs between the BSDs, and
//! C writes a zero for a constant its headers do not define, which the caller
//! reads as the name not existing on this host. The C original reached the same
//! place by leaving the entry out of the table altogether.
//!
//! Nothing here allocates or can fail. A name that matches nothing is reported
//! as `-1`; the panic that follows stays in C, where it can say which keyword
//! was wrong.

const std = @import("std");

// ---------------------------------------------------------------------------
// Platform ordinals
// ---------------------------------------------------------------------------

/// Mirrored by the `JANET_WATCH_PLATFORM_*` macros in `filewatch.c`, which a
/// compile-time assertion beside them pins to these values.
pub const Platform = enum(u32) {
    linux = 0,
    windows = 1,
    kqueue = 2,
};

// ---------------------------------------------------------------------------
// Name tables
// ---------------------------------------------------------------------------

/// The inotify vocabulary, in the order `watcher_flags_linux` lists it.
///
/// The order is the contract with C's value array, so it must not be disturbed;
/// it is also ascending, which is what the original binary search assumed.
const linux_names = [_][:0]const u8{
    "access",
    "all",
    "attrib",
    "close-nowrite",
    "close-write",
    "create",
    "delete",
    "delete-self",
    "ignored",
    "modify",
    "move-self",
    "moved-from",
    "moved-to",
    "open",
    "q-overflow",
    "unmount",
};

/// The `ReadDirectoryChangesW` vocabulary, in the order `watcher_flags_windows`
/// lists it. `recursive` is Janet's own flag rather than one of the platform's:
/// it selects the `bWatchSubtree` argument instead of joining the filter mask.
const windows_names = [_][:0]const u8{
    "all",
    "attributes",
    "creation",
    "dir-name",
    "file-name",
    "last-access",
    "last-write",
    "recursive",
    "security",
    "size",
};

/// The kqueue vocabulary, in the order `watcher_flags_kqueue` lists it.
///
/// This is the superset across the BSDs and macOS. Six of these — `close`,
/// `close-write`, `funlock`, `open`, `read`, and `truncate` — are conditional
/// on the host defining the matching `NOTE_*` constant, and on a host that does
/// not, C stores zero and the lookup's answer is refused there.
const kqueue_names = [_][:0]const u8{
    "all",
    "attrib",
    "close",
    "close-write",
    "delete",
    "extend",
    "funlock",
    "link",
    "open",
    "read",
    "rename",
    "revoke",
    "truncate",
    "write",
};

/// The names `filewatch.c` gives Windows' `FILE_ACTION_*` codes, indexed by the
/// code itself. Entry zero is the placeholder for a code outside the range the
/// API documents.
const windows_action_names = [_][:0]const u8{
    "unknown",
    "added",
    "removed",
    "modified",
    "renamed-old",
    "renamed-new",
};

fn namesFor(platform: u32) ?[]const [:0]const u8 {
    return switch (platform) {
        @intFromEnum(Platform.linux) => &linux_names,
        @intFromEnum(Platform.windows) => &windows_names,
        @intFromEnum(Platform.kqueue) => &kqueue_names,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Lookup
// ---------------------------------------------------------------------------

/// Report the position of a flag name in a platform's table, or -1 for a name
/// the platform does not have.
///
/// The keyword arrives as bytes and a length rather than as a C string, because
/// a Janet keyword is length-prefixed and may contain a zero byte. That is also
/// what `janet_cstrcmp` compared, so a match here means what a match meant
/// before. The search is linear over at most sixteen entries; the original
/// binary search needed the table sorted, and this does not, which removes a
/// standing invariant rather than relying on it.
export fn janet_filewatch_flag_index(platform: u32, name: [*]const u8, len: i32) callconv(.c) i32 {
    const names = namesFor(platform) orelse return -1;
    if (len < 0) return -1;
    const key = name[0..@intCast(len)];
    for (names, 0..) |entry, index| {
        if (std.mem.eql(u8, key, entry)) return @intCast(index);
    }
    return -1;
}

/// The number of flags a platform names. C asserts its value array against this
/// so the two cannot drift apart unnoticed.
export fn janet_filewatch_flag_count(platform: u32) callconv(.c) i32 {
    const names = namesFor(platform) orelse return -1;
    return @intCast(names.len);
}

/// The flag name at a position, or null when the position is out of range.
///
/// C does not need this — it indexes its own array — but the contract does, to
/// assert that both sides agree on the order the index refers to.
export fn janet_filewatch_flag_name(platform: u32, index: i32) callconv(.c) [*c]const u8 {
    const names = namesFor(platform) orelse return null;
    if (index < 0 or index >= names.len) return null;
    return names[@intCast(index)].ptr;
}

/// The keyword name for a Windows `FILE_ACTION_*` code, or null when the code
/// is outside the documented range.
///
/// The C original indexed a six-entry array with the code and had nothing to
/// say about a code beyond it. Reporting null instead lets `filewatch.c` fall
/// back to `unknown` explicitly rather than reading past the array.
export fn janet_filewatch_action_name(action: i32) callconv(.c) [*c]const u8 {
    if (action < 0 or action >= windows_action_names.len) return null;
    return windows_action_names[@intCast(action)].ptr;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn indexOf(platform: Platform, name: []const u8) i32 {
    return janet_filewatch_flag_index(@intFromEnum(platform), name.ptr, @intCast(name.len));
}

test "every table is ascending" {
    // The original searched these tables with `janet_strbinsearch`, so each was
    // required to be sorted. The lookup no longer depends on it, but a table
    // that stopped being sorted would mean the port and the original disagreed
    // about which entries were reachable, so it is worth pinning.
    for ([_][]const [:0]const u8{ &linux_names, &windows_names, &kqueue_names }) |names| {
        for (names[1..], 0..) |entry, i| {
            try std.testing.expect(std.mem.order(u8, names[i], entry) == .lt);
        }
    }
}

test "names resolve to their own positions" {
    for ([_]Platform{ .linux, .windows, .kqueue }) |platform| {
        const names = namesFor(@intFromEnum(platform)).?;
        for (names, 0..) |entry, index| {
            try std.testing.expectEqual(@as(i32, @intCast(index)), indexOf(platform, entry));
        }
    }
}

test "a name belongs only to its own platform" {
    try std.testing.expect(indexOf(.linux, "recursive") < 0);
    try std.testing.expect(indexOf(.windows, "attrib") < 0);
    try std.testing.expect(indexOf(.kqueue, "modify") < 0);
    // `all` is the one name every backend shares.
    try std.testing.expect(indexOf(.linux, "all") >= 0);
    try std.testing.expect(indexOf(.windows, "all") >= 0);
    try std.testing.expect(indexOf(.kqueue, "all") >= 0);
}

test "a partial or extended name matches nothing" {
    try std.testing.expect(indexOf(.linux, "acces") < 0);
    try std.testing.expect(indexOf(.linux, "accessx") < 0);
    try std.testing.expect(indexOf(.linux, "") < 0);
    try std.testing.expect(indexOf(.kqueue, "close-writ") < 0);
    try std.testing.expect(indexOf(.kqueue, "close-writes") < 0);
}

test "a name containing a zero byte matches nothing" {
    try std.testing.expect(indexOf(.linux, "all\x00") < 0);
    try std.testing.expect(indexOf(.linux, "a\x00ll") < 0);
}

test "an unknown platform reports rather than indexes" {
    // Called through the exports with a raw ordinal rather than through
    // `indexOf`: `Platform` has no tag for 3, which is the case being tested.
    const name = "all";
    try std.testing.expectEqual(@as(i32, -1), janet_filewatch_flag_index(3, name.ptr, name.len));
    try std.testing.expectEqual(@as(i32, -1), janet_filewatch_flag_count(3));
    try std.testing.expect(janet_filewatch_flag_name(3, 0) == null);
}

test "counts match the tables" {
    try std.testing.expectEqual(@as(i32, 16), janet_filewatch_flag_count(@intFromEnum(Platform.linux)));
    try std.testing.expectEqual(@as(i32, 10), janet_filewatch_flag_count(@intFromEnum(Platform.windows)));
    try std.testing.expectEqual(@as(i32, 14), janet_filewatch_flag_count(@intFromEnum(Platform.kqueue)));
}

test "action names cover the documented codes" {
    try std.testing.expect(janet_filewatch_action_name(-1) == null);
    try std.testing.expect(janet_filewatch_action_name(6) == null);
    for (windows_action_names, 0..) |expected, code| {
        const got = janet_filewatch_action_name(@intCast(code));
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings(expected, std.mem.span(@as([*:0]const u8, @ptrCast(got))));
    }
}
