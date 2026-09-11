//! Behavioral contract for the file watcher's keyword vocabularies.
//!
//! All three backends' names are asserted here on every target. Nothing about
//! a name is host-specific, so all three vocabularies are compiled and checked
//! everywhere rather than only where their backend runs.
//!
//! Only the names are the subject. Every flag's *value* is a host constant,
//! `IN_ATTRIB`, `FILE_NOTIFY_CHANGE_SIZE` and `NOTE_EXTEND` among them, and
//! lives in `filewatch_core.zig` beside the backend that uses it, so this file
//! asserts the order and membership of the vocabularies rather than any mask
//! arithmetic. The two halves are one table split down the middle: the index
//! reported here selects a value there, so the order below is fixed rather
//! than a convenience. `test/filewatch_core.zig` is where the halves are
//! compared.
//!
//! ## Two out-of-range cases the types exclude
//!
//! A flag count for a platform ordinal that names no backend, and a flag name
//! for a position below the table, are both refused by the parameter types:
//! they are `Platform` and `usize`, so neither call compiles. What survives of
//! that pair is the *upper*-bound case, which is still reachable and still
//! asserted.
//!
//! ## `zig build test` runs these tables too
//!
//! `filewatch.zig` has `test` blocks over the same orderings. They are a
//! different instrument from this file rather than a duplicate of it, and both
//! are kept.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const expect = @import("expect.zig").expect;
const flags = subsystems.filewatch;
const subsystems = @import("subsystems");

// ==========================================================================
// Constants
// ==========================================================================

const action_names = [_][]const u8{
    "unknown", "added", "removed", "modified", "renamed-old", "renamed-new",
};

const kqueue_names = [_][]const u8{
    "all",    "attrib",  "close",    "close-write", "delete",
    "extend", "funlock", "link",     "open",        "read",
    "rename", "revoke",  "truncate", "write",
};

const linux_names = [_][]const u8{
    "access",      "all",    "attrib",     "close-nowrite",
    "close-write", "create", "delete",     "delete-self",
    "ignored",     "modify", "move-self",  "moved-from",
    "moved-to",    "open",   "q-overflow", "unmount",
};

const windows_names = [_][]const u8{
    "all",       "attributes",  "creation",   "dir-name",
    "file-name", "last-access", "last-write", "recursive",
    "security",  "size",
};

// ==========================================================================
// Aliased types
// ==========================================================================

const Platform = flags.Platform;

// ==========================================================================
// Cases
// ==========================================================================

fn namesOf(platform: Platform) []const []const u8 {
    return switch (platform) {
        .linux => &linux_names,
        .windows => &windows_names,
        .kqueue => &kqueue_names,
    };
}

fn eachVocabularyIsComplete() void {
    expect(flags.flagCount(.linux) == linux_names.len);
    expect(flags.flagCount(.windows) == windows_names.len);
    expect(flags.flagCount(.kqueue) == kqueue_names.len);
}

/// The index is what selects a flag value in `filewatch_core.zig`, so a name
/// that moved would silently decode to a different flag. Pinning both
/// directions is what keeps the two halves of the table from drifting apart.
fn namesHoldTheirPositions() void {
    for ([_]Platform{ .linux, .windows, .kqueue }) |platform| {
        for (namesOf(platform), 0..) |name, i| {
            expect(flags.flagIndex(platform, name).? == i);
            expect(std.mem.eql(u8, flags.flagName(platform, i).?, name));
        }
    }
}

/// A binary search over one of these tables requires it to be
/// sorted. Neither implementation depends on that now, but a table that
/// stopped being sorted would mean the two disagreed about which entries were
/// reachable at all.
fn eachVocabularyIsAscending() void {
    for ([_]Platform{ .linux, .windows, .kqueue }) |platform| {
        const names = namesOf(platform);
        for (names[1..], 0..) |name, i| {
            expect(std.mem.order(u8, names[i], name) == .lt);
        }
    }
}

fn aNameBelongsOnlyToItsOwnBackend() void {
    expect(flags.flagIndex(.linux, "recursive") == null);
    expect(flags.flagIndex(.linux, "last-write") == null);
    expect(flags.flagIndex(.windows, "attrib") == null);
    expect(flags.flagIndex(.windows, "modify") == null);
    expect(flags.flagIndex(.kqueue, "modify") == null);
    expect(flags.flagIndex(.kqueue, "creation") == null);

    // `all` is the one name every backend shares.
    expect(flags.flagIndex(.linux, "all") != null);
    expect(flags.flagIndex(.windows, "all") != null);
    expect(flags.flagIndex(.kqueue, "all") != null);
}

fn aPartialOrExtendedNameMatchesNothing() void {
    expect(flags.flagIndex(.linux, "acces") == null);
    expect(flags.flagIndex(.linux, "accessx") == null);
    expect(flags.flagIndex(.linux, "") == null);
    expect(flags.flagIndex(.kqueue, "close-writ") == null);
    expect(flags.flagIndex(.kqueue, "close-writes") == null);
}

/// A Janet keyword may contain a zero byte, so the comparison is by length and
/// bytes rather than by terminator. Such a keyword matches nothing.
fn aNameContainingAZeroByteMatchesNothing() void {
    const trailing = [_]u8{ 'a', 'l', 'l', 0 };
    const embedded = [_]u8{ 'a', 0, 'l', 'l' };
    expect(flags.flagIndex(.linux, &trailing) == null);
    expect(flags.flagIndex(.linux, &embedded) == null);
    // The same bytes without the zero still match.
    expect(flags.flagIndex(.linux, trailing[0..3]) != null);
}

/// The upper half of the out-of-range pair. The lower half, a negative
/// position, is what the header records as unwritable:
/// the parameter is a `usize`.
fn aPositionPastTheEndHasNoName() void {
    expect(flags.flagName(.linux, linux_names.len) == null);
    expect(flags.flagName(.windows, windows_names.len) == null);
    expect(flags.flagName(.kqueue, kqueue_names.len) == null);
}

/// The action names are indexed by Windows' `FILE_ACTION_*` code, and a code
/// past the last one reports null rather than reading past the array, which is
/// what lets the Windows decoder name its fallback explicitly.
fn actionNamesCoverTheDocumentedCodes() void {
    for (action_names, 0..) |expected, code| {
        expect(std.mem.eql(u8, flags.actionName(@intCast(code)).?, expected));
    }
    expect(flags.actionName(action_names.len) == null);
}

// ==========================================================================
// Entry
// ==========================================================================

pub fn run() void {
    eachVocabularyIsComplete();
    namesHoldTheirPositions();
    eachVocabularyIsAscending();
    aNameBelongsOnlyToItsOwnBackend();
    aPartialOrExtendedNameMatchesNothing();
    aNameContainingAZeroByteMatchesNothing();
    aPositionPastTheEndHasNoName();
    actionNamesCoverTheDocumentedCodes();
}
