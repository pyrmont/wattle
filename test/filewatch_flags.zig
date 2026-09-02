//! Behavioral contract for the file watcher's keyword vocabularies.
//!
//! All three backends' names are asserted here on every target. In C each
//! table sat inside the `#ifdef` for its own backend, so on any one host the
//! other two were not merely unreachable but uncompiled — a typo in the
//! Windows vocabulary could survive every Linux and macOS build indefinitely.
//! Nothing about a name is host-specific, so all three are compiled and
//! checked everywhere.
//!
//! Only the names are the subject. Every flag's *value* is a host constant —
//! `IN_ATTRIB`, `FILE_NOTIFY_CHANGE_SIZE`, `NOTE_EXTEND` — and lives in
//! `filewatch_core.zig` beside the backend that uses it, so this file asserts
//! the order and membership of the vocabularies rather than any mask
//! arithmetic. The two halves are one table split down the middle: the index
//! reported here is what selects a value there, which is why the order below
//! is a contract and not a convenience. `test/filewatch_core.zig` is where the
//! halves are compared.
//!
//! ## What a type refuses
//!
//! **Two cases cannot be written, and both were about a value the type now
//! excludes.** A flag count for a platform ordinal that names no backend
//! answered -1, and a flag name for a position below the table answered NULL.
//! The parameters are `Platform` and `usize`, so neither call compiles. A type
//! refusing a mistake is better than a contract catching it, but the loss is
//! written here rather than left to be noticed: what survives of the pair is
//! the *upper*-bound case, which is still reachable and still asserted.
//!
//! ## `zig build test` runs these tables too, and that is not a duplication to
//! remove
//!
//! `filewatch.zig` carries `test` blocks over the same orderings. A mutation
//! sweep scores contracts and does not run `zig build test`, so a mutation in
//! the tables is caught by one instrument and not the other.

const std = @import("std");

const subsystems = @import("subsystems");
const flags = subsystems.filewatch;
const Platform = flags.Platform;

const expect = @import("expect.zig").expect;

// ==========================================================================
// The vocabularies, in the order both halves of the split agree on
// ==========================================================================

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

const kqueue_names = [_][]const u8{
    "all",    "attrib",  "close",    "close-write", "delete",
    "extend", "funlock", "link",     "open",        "read",
    "rename", "revoke",  "truncate", "write",
};

const action_names = [_][]const u8{
    "unknown", "added", "removed", "modified", "renamed-old", "renamed-new",
};

fn namesOf(platform: Platform) []const []const u8 {
    return switch (platform) {
        .linux => &linux_names,
        .windows => &windows_names,
        .kqueue => &kqueue_names,
    };
}

// ==========================================================================
// The tables
// ==========================================================================

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

/// Upstream Janet binary-searches each table, which requires it to be
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

/// A Janet keyword may hold a zero byte, so the comparison is by length and
/// bytes rather than by terminator. Such a keyword matches nothing.
fn aNameContainingAZeroByteMatchesNothing() void {
    const trailing = [_]u8{ 'a', 'l', 'l', 0 };
    const embedded = [_]u8{ 'a', 0, 'l', 'l' };
    expect(flags.flagIndex(.linux, &trailing) == null);
    expect(flags.flagIndex(.linux, &embedded) == null);
    // The same bytes without the zero still match.
    expect(flags.flagIndex(.linux, trailing[0..3]) != null);
}

/// The upper half of the C contract's out-of-range pair. The lower half — a
/// negative position — is what the header comment above records as unwritable:
/// the parameter is a `usize`.
fn aPositionPastTheEndHasNoName() void {
    expect(flags.flagName(.linux, linux_names.len) == null);
    expect(flags.flagName(.windows, windows_names.len) == null);
    expect(flags.flagName(.kqueue, kqueue_names.len) == null);
}

/// The C original indexed a six-entry array with Windows' `FILE_ACTION_*` code
/// and had nothing to say about a code beyond it. Both implementations report
/// null there instead, which is what lets the Windows decoder name the
/// fallback explicitly rather than read past the array.
fn actionNamesCoverTheDocumentedCodes() void {
    for (action_names, 0..) |expected, code| {
        expect(std.mem.eql(u8, flags.actionName(@intCast(code)).?, expected));
    }
    expect(flags.actionName(action_names.len) == null);
}

pub fn run() void {
    eachVocabularyIsComplete();
    namesHoldTheirPositions();
    eachVocabularyIsAscending();
    aNameBelongsOnlyToItsOwnBackend();
    aPartialOrExtendedNameMatchesNothing();
    aNameContainingAZeroByteMatchesNothing();
    aPositionPastTheEndHasNoName();
    actionNamesCoverTheDocumentedCodes();

    std.debug.print("filewatch_flags: all tests passed\n", .{});
}
