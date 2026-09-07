//! Registering a core cfunction from Zig.
//!
//! A Zig subsystem owns its cfunctions, and this is the layer that registers
//! them. It is shared like `cabi.zig` and `raise.zig` rather than selected like
//! a subsystem, and for the same reason: it declares no `export`, so every
//! subsystem can import it without a definition appearing twice.
//!
//! Whether a core cfunction has a docstring and a source map depends on
//! whether this is the bootstrap or the runtime and on what the build asked
//! for, and the four combinations are the whole of what this file is for:
//!
//! | build | docstring | source map |
//! | --- | --- | --- |
//! | bootstrap | unless `-Ddocstrings=false` | unless `-Dsourcemaps=false` |
//! | runtime | never | always |
//!
//! The runtime row is not a simplification. A `-Ddocstrings=false` runtime has
//! no docstrings here to drop, and a `-Dsourcemaps=false` runtime still records
//! a source map for every core cfunction. The runtime needs no docstrings
//! because the core environment is unmarshalled from the image, which the
//! bootstrap built with them in place; what the runtime registration adds on
//! top is the binding and the registry entry that a description or a
//! marshalled name is looked up in.
//!
//! `(doc tuple/join)` names the registration table's row rather than the
//! implementation's line. `@src()` is valid only inside a function, so a Zig
//! declaration cannot name its own line. The location recorded is a real
//! location in a real file, one screen from the code.
//!
//! `Method` is not here. It is `method_type.zig`'s, beside the other retyped
//! tables. This file registers core cfunctions and uses neither it nor a
//! method terminator; the subsystems that declare a method table reached the
//! type through the registration layer only because that is where it happened
//! to be written.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const capi = @import("capi.zig");
const config = @import("config");
const raise = @import("../api/raise.zig");
const registry = @import("registry.zig");
const repr = @import("repr");
const tables = @import("value/tables.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The alignment a core cfunction is declared with where it is declared with
/// one. It is not on every cfunction in the tree.
///
/// Under 64-bit nanboxing with a nonzero pointer shift, wrapping a cfunction
/// reuses the low bits of its pointer, and `registry.zig` aborts at
/// registration if they are not clear. `1 << 4` is stated rather than the
/// configured shift so that the build does not thread the number into each
/// object, and over-aligning costs padding measured in bytes. The shift itself
/// is clamped to 0 through 2 in `build.zig`, and the cfunctions that declare no
/// alignment are why: at 3 and 4 the registration check aborts the bootstrap on
/// one of them.
pub const alignment = 16;

/// Whether this compilation is the bootstrap image generator rather than the
/// runtime. A core cfunction table has docstrings in the generator and not in
/// the runtime.
pub const bootstrap = config.bootstrap;

/// The terminating row of a registration table.
///
/// A registration table whose length is fixed at comptime is a slice, and most
/// do not spell their own terminator: `install` appends it, because the two
/// entry points it calls are C-ABI symbols that read a null-name-terminated
/// array.
///
/// It stays `pub` for the tables that are not comptime. `ev.zig` and `os.zig`
/// size theirs from the configuration at run time and fill them row by row, so
/// the terminator is a slot they write rather than one this file can append.
/// `installTerminated` is their entry point and says so in its name.
pub const end: Entry = .{};

/// The prefix that turns `@src().file` into a repo-relative path.
///
/// Zig reports `@src().file` relative to the module root, and this module's
/// root is `src/root.zig`, so a concatenation reconstructs the path at any
/// depth: `runtime/value/helpers/wrap.zig` as readily as `runtime/io.zig`. The
/// one shape it cannot reconstruct is a path that climbs out of the module,
/// which is what `sourcePath` refuses.
///
/// Repo-relative keeps the build machine's directory out of the source map
/// and therefore out of the core image.
/// `tools/check/image-diff.janet` counts what host paths remain.
const source_root = "src/";

/// Whether a registration here records a docstring.
const with_docstrings = bootstrap and config.docstrings;

/// Whether a registration here records a source map.
const with_sourcemaps = !bootstrap or config.sourcemaps;

// ==========================================================================
// Aliased types
// ==========================================================================

/// One registration row. This is `abi.Reg`, under the name this file's callers
/// use.
pub const Entry = abi.Reg;

// ==========================================================================
// Public functions
// ==========================================================================

/// Defines a plain value binding rather than a cfunction.
///
/// `env` is the environment, `name` the binding, `value` the value bound,
/// the caller's `@src()` and `doc` its documentation.
///
/// Both arms are real. The bootstrap defines a documented binding in the
/// environment the image is made of. The runtime calls `registry.coreDefSm`,
/// which drops the documentation and the source map and puts the bare value
/// into the core lookup dictionary, which is not the environment. That
/// dictionary is what the unmarshaller resolves the image's symbol references
/// against, so a value the runtime cannot reconstruct has to be in it.
///
/// The runtime arm is not redundant, though the image already having the
/// binding makes it look so. That is true of `math`'s constants, which are
/// numbers and marshal inline. It is not true of `io`: `stdout`, `stderr`
/// and `stdin` are live `FILE *` handles wrapped in an abstract, they can only
/// come from the running process, and the image refers to them by name.
pub fn def(
    env: *tables.Table,
    comptime name: [:0]const u8,
    value: repr.Value,
    comptime where: std.builtin.SourceLocation,
    comptime doc: [:0]const u8,
) void {
    if (bootstrap) {
        registry.defSm(
            env,
            name.ptr,
            value,
            doc.ptr,
            if (with_sourcemaps) sourcePath(where).ptr else null,
            if (with_sourcemaps) @intCast(where.line) else 0,
        );
    } else {
        registry.coreDefSm(env, name.ptr, value, doc.ptr, null, 0);
    }
}

/// Installs a finished table into the core environment.
///
/// `env` is the environment and `entries` the rows the author wrote, with no
/// terminator: it is a comptime array and the sentinel is appended here, once,
/// where the C-ABI entry point actually reads one.
///
/// The bootstrap defines the binding as well as the registry entry, because it
/// is building the environment the image is made of. The runtime puts only the
/// value and the registry entry, because the binding arrived with the image.
pub fn install(env: *tables.Table, comptime entries: anytype) void {
    const rows = comptime blk: {
        var out: [entries.len + 1]Entry = undefined;
        for (entries, 0..) |row, i| out[i] = row;
        out[entries.len] = end;
        break :blk out;
    };
    installTerminated(env, &rows);
}

/// The same, for a table the caller terminated because its length is a
/// run-time fact.
///
/// `env` is the environment and `entries` a null-name-terminated array. See
/// `end`.
pub fn installTerminated(env: *tables.Table, entries: [*]const Entry) void {
    if (bootstrap) {
        capi.janet_cfuns_ext(@ptrCast(env), null, entries);
    } else {
        registry.coreCfunsExt(env, null, entries);
    }
}

/// Builds one row of a core cfunction table.
///
/// `name` is the binding, `cfun` the implementation, `where` the caller's
/// `@src()`, and `usage` and `doc` the two halves of the docstring. `where` is
/// a parameter rather than something this could work out for itself, because
/// `@src()` reports the line it is written on and taking it here would name
/// this file.
///
/// This is what lets the name, the usage, the documentation and the
/// implementation sit on one line instead of at two ends of the file.
pub fn reg(
    comptime name: [:0]const u8,
    comptime cfun: anytype,
    comptime where: std.builtin.SourceLocation,
    comptime usage: [:0]const u8,
    comptime doc: [:0]const u8,
) Entry {
    return .{
        .name = name.ptr,
        .cfun = raise.stored(cfun),
        .documentation = if (with_docstrings) (usage ++ "\n\n" ++ doc).ptr else null,
        .source_file = if (with_sourcemaps) sourcePath(where).ptr else null,
        .source_line = if (with_sourcemaps) @intCast(where.line) else 0,
    };
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Returns `where`'s file as a repo-relative path.
///
/// `where` is the caller's `@src()`. A path that climbs out of the module is a
/// compile error, because `source_root` no longer reconstructs it.
inline fn sourcePath(comptime where: std.builtin.SourceLocation) [:0]const u8 {
    if (comptime std.mem.startsWith(u8, where.file, "..")) {
        @compileError("corefn: @src().file escapes the module ('" ++ where.file ++
            "'), so source_root no longer reconstructs its path");
    }
    return source_root ++ where.file;
}
