//! The keyword vocabularies of the file watcher, for every platform at once.
//!
//! `filewatch/add` and `filewatch/new` take their options as keywords, and each
//! backend has its own set: inotify names on Linux, `ReadDirectoryChangesW`
//! names on Windows, and kqueue's `NOTE_*` names on the BSDs and macOS. In C
//! each table sat inside the `#ifdef` for its own backend, so on any one host
//! the other two were not merely unreachable but uncompiled. All three are
//! compiled here, on every target, and asserted by `test/filewatch_flags.zig`.
//!
//! Only the *names* are here. Every flag's value is a host constant —
//! `IN_ATTRIB`, `FILE_NOTIFY_CHANGE_SIZE`, `NOTE_EXTEND` — so
//! `filewatch_core.zig` keeps a value array in the same order and indexes it
//! with what the lookup reports. That split is also what lets the BSD table
//! vary: the `NOTE_*` set differs between the BSDs, and the value half writes a
//! zero for a constant its headers do not define, which the caller reads as the
//! name not existing on this host. The C original reached the same place by
//! leaving the entry out of the table altogether.
//!
//! Nothing here allocates or can fail. A name that matches nothing is reported
//! as null; the raise that follows belongs to `filewatch_core.zig`, which is
//! where the keyword and the backend's name are both in hand.
//!
//! ## The vocabularies are reached by import
//!
//! Until Phase 11 Part 21 the four lookups below were `export fn
//! janet_filewatch_flag_*`, and `filewatch_core.zig` declared each of them
//! again as an `extern fn` -- one Zig file calling another through the symbol
//! table, which is the shape `filewatch.c` needed and rule 44's class. The
//! symbols are gone and the `platform_linux`/`platform_windows`/
//! `platform_kqueue` ordinals that stood in for `Platform` on the far side of
//! that seam went with them: a caller names the tag now.

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

fn namesFor(platform: Platform) []const [:0]const u8 {
    return switch (platform) {
        .linux => &linux_names,
        .windows => &windows_names,
        .kqueue => &kqueue_names,
    };
}

// ---------------------------------------------------------------------------
// Lookup
// ---------------------------------------------------------------------------

/// Report the position of a flag name in a platform's table, or null for a
/// name the platform does not have.
///
/// The keyword arrives as bytes rather than as a C string, because a Janet
/// keyword is length-prefixed and may contain a zero byte. That is also what
/// `janet_cstrcmp` compared, so a match here means what a match meant before. The search is linear over at most sixteen entries; the original
/// binary search needed the table sorted, and this does not, which removes a
/// standing invariant rather than relying on it.
pub fn flagIndex(platform: Platform, name: []const u8) ?usize {
    for (namesFor(platform), 0..) |entry, index| {
        if (std.mem.eql(u8, name, entry)) return index;
    }
    return null;
}

/// The number of flags a platform names. `filewatch_core.zig` asserts its
/// value array against this so the two halves cannot drift apart unnoticed.
pub fn flagCount(platform: Platform) usize {
    return namesFor(platform).len;
}

/// The flag name at a position, or null when the position is out of range.
///
/// The value half indexes its own array and does not need this; the contract
/// does, to assert that both halves agree on the order the index refers to,
/// and so does the event decoder, which names the flag it matched.
pub fn flagName(platform: Platform, index: usize) ?[:0]const u8 {
    const names = namesFor(platform);
    if (index >= names.len) return null;
    return names[index];
}

/// The keyword name for a Windows `FILE_ACTION_*` code, or null when the code
/// is outside the documented range.
///
/// The C original indexed a six-entry array with the code and had nothing to
/// say about a code beyond it. Reporting null instead lets the Windows decoder
/// name the fallback explicitly rather than read past the array.
pub fn actionName(action: u32) ?[:0]const u8 {
    if (action >= windows_action_names.len) return null;
    return windows_action_names[action];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn indexOf(platform: Platform, name: []const u8) ?usize {
    return flagIndex(platform, name);
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
        for (namesFor(platform), 0..) |entry, index| {
            try std.testing.expectEqual(@as(?usize, index), indexOf(platform, entry));
        }
    }
}

test "a name belongs only to its own platform" {
    try std.testing.expect(indexOf(.linux, "recursive") == null);
    try std.testing.expect(indexOf(.windows, "attrib") == null);
    try std.testing.expect(indexOf(.kqueue, "modify") == null);
    // `all` is the one name every backend shares.
    try std.testing.expect(indexOf(.linux, "all") != null);
    try std.testing.expect(indexOf(.windows, "all") != null);
    try std.testing.expect(indexOf(.kqueue, "all") != null);
}

test "a partial or extended name matches nothing" {
    try std.testing.expect(indexOf(.linux, "acces") == null);
    try std.testing.expect(indexOf(.linux, "accessx") == null);
    try std.testing.expect(indexOf(.linux, "") == null);
    try std.testing.expect(indexOf(.kqueue, "close-writ") == null);
    try std.testing.expect(indexOf(.kqueue, "close-writes") == null);
}

test "a name containing a zero byte matches nothing" {
    try std.testing.expect(indexOf(.linux, "all\x00") == null);
    try std.testing.expect(indexOf(.linux, "a\x00ll") == null);
}

// There is no "an unknown platform reports rather than indexes" test any more,
// and its absence is the interesting half. The exported form took the ordinal
// as a `u32` and answered -1 for 3, because C had no way to say that only three
// values exist; `Platform` says it, so the case cannot be written. A type
// refusing a mistake is better than a test catching it -- rule 42 -- but the
// assertion it replaces was real, so this note stands where it was.

test "counts match the tables" {
    try std.testing.expectEqual(@as(usize, 16), flagCount(.linux));
    try std.testing.expectEqual(@as(usize, 10), flagCount(.windows));
    try std.testing.expectEqual(@as(usize, 14), flagCount(.kqueue));
}

test "a position outside a table has no name" {
    try std.testing.expect(flagName(.linux, flagCount(.linux)) == null);
    try std.testing.expect(flagName(.windows, flagCount(.windows)) == null);
    try std.testing.expect(flagName(.kqueue, flagCount(.kqueue)) == null);
}

test "action names cover the documented codes" {
    try std.testing.expect(actionName(6) == null);
    for (windows_action_names, 0..) |expected, code| {
        try std.testing.expectEqualStrings(expected, actionName(@intCast(code)).?);
    }
}
