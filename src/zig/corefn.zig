//! Registering a core cfunction from Zig.
//!
//! Phase 10 Part 6 is the first increment in which a Zig subsystem owns a
//! cfunction rather than a kernel one calls, and this is the layer that made
//! that possible. It is shared like `abi.zig` and `raise.zig` rather than
//! selected like a subsystem, and for the same reason: it holds no `export` at
//! all, so every subsystem can import it without the definitions appearing
//! once per object.
//!
//! ## What `JANET_CORE_FN` actually decides
//!
//! The C original spells a core cfunction with one macro that expands
//! differently in four dimensions, and reproducing the expansion faithfully is
//! most of what this file is for. `src/core/util.h` picks between
//! `JANET_FN` and `JANET_FN_S` on `JANET_BOOTSTRAP`, and `janet.h` then picks
//! between four `JANET_FN*` forms on `JANET_NO_DOCSTRINGS` and
//! `JANET_NO_SOURCEMAPS`. The table below is what falls out:
//!
//! | build | docstring | source map |
//! | --- | --- | --- |
//! | bootstrap | unless `JANET_NO_DOCSTRINGS` | unless `JANET_NO_SOURCEMAPS` |
//! | runtime | never | always |
//!
//! The runtime row is not a simplification. `JANET_CORE_FN` resolves to
//! `JANET_FN_S` outside the bootstrap whatever the config says, so a
//! `-Ddocstrings=false` runtime drops nothing here — the docstrings were never
//! in it — and a `-Dsourcemaps=false` runtime still records a source map for
//! every core cfunction. Both are reproduced rather than tidied.
//!
//! The runtime has no docstrings because it does not need them: the core
//! environment is unmarshalled from the image, which the bootstrap built with
//! them in place. What the runtime registration adds on top is the binding and
//! the registry entry that `janet_description_b` and `marsh.c` look names up
//! in.
//!
//! ## Two things the C macro gets for free and Zig has to ask for
//!
//! **`__LINE__`.** `@src()` is only valid inside a function, so a Zig
//! declaration cannot name its own line the way `JANET_FN_S` does. The
//! location recorded here is therefore the row in the registration table
//! rather than the line of the implementation, which is a real location in a
//! real file and one screen from the code. `src/zig/README.md` records the
//! visible consequence: `(doc tuple/join)` names a different line than it did,
//! and a different file.
//!
//! **`JANET_CFUNCTION_ALIGN`.** Under 64-bit nanboxing with a nonzero pointer
//! shift, `janet_wrap_cfunction` reuses the low bits of the pointer, and
//! `janet_check_pointer_align` asserts at registration that they are clear.
//! The C original attaches `__attribute__((aligned(1 << SHIFT)))` to every
//! cfunction; `alignment` below is the Zig equivalent and is the maximum the
//! shift may take rather than the configured value, so that it satisfies every
//! setting `-Dnanbox-pointer-shift` accepts without the build having to thread
//! the number into each object. Over-aligning costs padding measured in bytes.

const std = @import("std");
const abi = @import("abi");
const raise = @import("raise");
const c = abi.c;

/// Compiled into the bootstrap image generator rather than into the runtime.
/// `build.zig` adds the macro to the Zig subsystem objects it builds for
/// `-Dboot=zig`; before Part 6 no Zig object had any reason to care.
pub const bootstrap = @hasDecl(c, "JANET_BOOTSTRAP");

const with_docstrings = bootstrap and !@hasDecl(c, "JANET_NO_DOCSTRINGS");
const with_sourcemaps = !bootstrap or !@hasDecl(c, "JANET_NO_SOURCEMAPS");

/// The alignment every core cfunction is declared with. See the note above:
/// `-Dnanbox-pointer-shift` accepts 0 through 4, and 1 << 4 satisfies all of
/// them.
pub const alignment = 16;

/// Every module `corefn` is attached to is a subsystem object rooted at one
/// file in this directory, so `@src().file` -- which Zig reports relative to
/// the module root, and which is therefore a bare basename here -- is one
/// concatenation away from a path that means something. `sourcePath` checks
/// the assumption rather than trusting it: a subsystem that grew a second
/// source file would report a subpath and fail to compile here instead of
/// quietly recording a location nobody can find.
///
/// The result is repo-relative where C's `__FILE__` is absolute, because
/// `build.zig` passes absolute paths to the C compiler. That is an improvement
/// and a small one: `PLAN.md` records that the image embeds twenty-two
/// absolute host paths, which is why it is not yet reproducible across
/// checkouts, and this removes them one subsystem at a time.
const subsystem_dir = "src/zig/subsystems/";

inline fn sourcePath(comptime where: std.builtin.SourceLocation) [:0]const u8 {
    if (comptime std.mem.indexOfScalar(u8, where.file, '/') != null) {
        @compileError("corefn: @src().file is a subpath ('" ++ where.file ++
            "'), so this subsystem is no longer one file and " ++
            "subsystem_dir no longer reconstructs its path");
    }
    return subsystem_dir ++ where.file;
}

pub const Entry = c.JanetRegExt;

/// `JanetMethod`, with the cfunction typed as Phase 10 Part 17g types it.
///
/// The layout is `janet.h`'s exactly -- a name and a pointer -- and the
/// pointer is the same pointer. What differs is the *declared* type of the
/// function it points at, which since 17g is `raise.CFunction` rather than
/// `JanetCFunction`, so that a method table is checked the way a registration
/// table is. Where one of these arrays meets a signature C still declares --
/// `janet_getmethod`, `janet_nextmethod`, `JanetStream.methods` -- it is cast,
/// because a layout is all those need.
pub const Method = extern struct {
    name: [*c]const u8,
    cfun: ?raise.CFunction,
};

/// `JANET_REG_END` for a method table.
pub const method_end: Method = .{ .name = null, .cfun = null };

/// `JANET_REG_END`. A table is terminated by a null name, not by its length.
pub const end: Entry = .{
    .name = null,
    .cfun = null,
    .documentation = null,
    .source_file = null,
    .source_line = 0,
};

/// One row of a core cfunction table: `JANET_CORE_FN` and `JANET_CORE_REG`
/// together, which is what lets the name, the usage, the documentation and the
/// implementation sit on one line instead of at two ends of the file.
///
/// `where` is the caller's `@src()`. It is a parameter rather than something
/// this could work out for itself because `@src()` reports the line it is
/// written on, so taking it here would name this file.
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

/// Install a finished table into the core environment.
///
/// The bootstrap defines the binding as well as the registry entry, because it
/// is building the environment the image is made of; the runtime only puts the
/// value and the registry entry, because the binding arrived with the image.
/// `util.h` spells that as a `#define` of one name onto the other, which is
/// why there is a choice to make here at all.
pub fn install(env: *c.JanetTable, entries: []const Entry) void {
    if (bootstrap) {
        c.janet_cfuns_ext(env, null, entries.ptr);
    } else {
        janet_core_cfuns_ext(env, null, entries.ptr);
    }
}

/// `src/core/util.h`, which `abi.zig` does not translate, and which does not
/// exist in a bootstrap build at all.
extern fn janet_core_cfuns_ext(
    env: *c.JanetTable,
    regprefix: [*c]const u8,
    cfuns: [*c]const Entry,
) callconv(.c) void;

/// `JANET_CORE_DEF`: a plain value binding rather than a cfunction.
///
/// Both arms are real, and Part 6 got that wrong. The bootstrap defines a
/// documented binding in the environment the image is made of; the runtime
/// calls `janet_core_def_sm`, which throws the documentation and the source map
/// away and puts the bare value into `janet_core_lookup_table`'s dictionary --
/// which is *not* the environment. That dictionary is what `janet_unmarshal`
/// resolves the image's symbol references against, so a value the runtime
/// cannot reconstruct has to be in it.
///
/// Part 6 read the runtime arm as redundant and compiled it out, on the
/// grounds that the image already carries the binding. That held for `math.c`,
/// whose constants are numbers and marshal inline. It does not hold for
/// `io.c`: `stdout`, `stderr` and `stdin` are live `FILE *` handles wrapped in
/// an abstract, they can only come from the running process, and the image
/// refers to them by name. Phase 10 Part 11 is the increment that needed the
/// other half.
pub fn def(
    env: *c.JanetTable,
    comptime name: [:0]const u8,
    value: c.Janet,
    comptime where: std.builtin.SourceLocation,
    comptime doc: [:0]const u8,
) void {
    if (bootstrap) {
        c.janet_def_sm(
            env,
            name.ptr,
            value,
            doc.ptr,
            if (with_sourcemaps) sourcePath(where).ptr else null,
            if (with_sourcemaps) @intCast(where.line) else 0,
        );
    } else {
        janet_core_def_sm(env, name.ptr, value, doc.ptr, null, 0);
    }
}

/// `src/core/util.h`, like `janet_core_cfuns_ext` above: declared directly
/// rather than translated, and absent from a bootstrap build.
extern fn janet_core_def_sm(
    env: *c.JanetTable,
    name: [*c]const u8,
    x: c.Janet,
    p: ?*const anyopaque,
    sf: ?*const anyopaque,
    sl: i32,
) callconv(.c) void;
