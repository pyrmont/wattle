//! Behavioral contract for the file subsystem: mode-string parsing, the
//! stream host operations, the `core/file` abstract type, the public
//! `JanetFile` entry points, and the cfunction surface over all of them.
//!
//! ## Why this file exists rather than the suite covering it
//!
//! Three things here are unreachable from Janet. The `JanetFile` entry points
//! are C API with no Janet spelling; the abstract type's `marshal` and
//! `unmarshal` callbacks run only under `JANET_MARSHAL_UNSAFE`, which
//! `(marshal f)` never sets; and a `JanetFile` whose flags and whose stream
//! disagree is a thing only an embedder can build, and is the only way into
//! two of the failure paths.
//!
//! ## How the subjects are reached
//!
//! **The kernels are reached by import.** Fifteen `janet_io_*` symbols were
//! hand-declared once, because none of them is in a header. They were exported
//! for a C caller that no longer exists, so fourteen of the fifteen stopped
//! being symbols at all. `janet_io_write` is the exception and stays: it has a
//! real caller in `pp/format.zig`, which reaches it by symbol on purpose so
//! that the printer does not depend on the whole io surface.
//!
//! **The three mode-scan status codes and the five `JANET_IO_MODE_*` values
//! are named rather than restated.** A third copy of numbers two files already
//! agree on is a place they can drift.
//!
//! **The public API half goes through the abis**, deliberately. That section
//! is about the published entry points, and `janet_getjfile` and
//! `janet_getfile` are `raise.reported` wrappers whose report is exactly what
//! a C embedder sees -- so `harness.abiRaised` is the right instrument and
//! `harness.raised` would test something else.

const std = @import("std");
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
const value = @import("subsystems").value;
const strings = @import("subsystems").value.strings;
const core_env = @import("subsystems").env;
const vm_state = @import("subsystems").lifecycle;
const io_core_mod = @import("subsystems").io;
const wrap = @import("subsystems").value.wrap;
const buffers = @import("subsystems").value.buffers;
const abstracts = @import("subsystems").value.abstracts;
const abstract_type = @import("subsystems").abstract_type;
const math = @import("subsystems").math;
const pp_describe = @import("subsystems").pp_describe;
const io_core = subsystems.io;
const marsh = subsystems.marsh;

/// The three standard streams, and the only spelling of them a contract in
/// this tree may use.
///
/// `c.stdout` is an inline *function* in Darwin's headers, a *variable* of
/// opaque type on musl -- which is not callable -- and on mingw a constant
/// whose initializer calls an extern function, which Zig rejects outright as
/// "comptime call of extern function". `stdio.zig` exists for exactly that and
/// names the symbol underneath the macro instead; its header comment has the
/// table. A C contract could write `stdout` and think nothing of it, and the
/// matrix's four cross-compile entries are the only instrument that says so.
const stdio = subsystems.stdio;

/// A translated `FILE *` as the `?*anyopaque` `stdio.zig` deals in. They are
/// the same pointer and not the same Zig type: `io_core.zig` declares its own
/// opaque `FILE` for the same reason, because translate-c renders the
/// structure complete on macOS and opaque on musl and no single spelling
/// compiles on both.
fn asHandle(file: anytype) ?*anyopaque {
    return @ptrCast(@alignCast(file));
}

const assert = std.debug.assert;

/// Six, not seven: `dynprintf`'s "file is not writeable" case is in
/// `test/pp_format.zig`, with its subject.
const expected_raises = 6;
var raises_seen: u32 = 0;

const scratch = "janet-zig-io-core-9d24";
const public = "janet-zig-io-core-public-9d24";

fn cleanPaths() void {
    _ = c.remove(scratch);
    _ = c.remove(public);
}

/// A refusal, by the message it carried. Reading the message is what
/// distinguishes "it refused" from "it refused for the reason this case is
/// about": three mutations inside message literals once survived a whole sweep
/// against a contract that only asked whether something raised.
fn expectRaise(function: anytype, args: anytype, message: []const u8) void {
    const r = harness.raised(function, args) orelse {
        std.debug.print("io_core: expected a raise saying: {s}\n", .{message});
        @panic("io_core: expected a raise, got a return");
    };
    assert(r.signal == types.Signal.@"error");
    if (!r.says(message)) {
        std.debug.print("expected: {s}\n", .{message});
        std.debug.print("     got: {s}\n", .{pp_describe.toString(r.payload)});
        @panic("io_core: the raise carried another message");
    }
    raises_seen += 1;
}

/// The same for a `janet.h` abi, whose refusal arrives as a report rather
/// than as an error. `null` for a message that is not checked.
fn expectAbiRaise(abi: anytype, args: anytype, message: ?[]const u8) void {
    const r = harness.abiRaised(abi, args) orelse
        @panic("io_core: expected a raise from an abi, got a return");
    assert(r.signal == types.Signal.@"error");
    if (message) |text| assert(r.says(text));
    raises_seen += 1;
}

/// For the one message that carries an address: `%v` renders a `core/file` by
/// pointer, so only the fixed part can be compared -- and the fixed part is
/// exactly what distinguishes it from the message the other branch produces.
fn expectRaisePrefix(function: anytype, args: anytype, prefix: []const u8) void {
    const r = harness.raised(function, args) orelse
        @panic("io_core: expected a raise, got a return");
    assert(r.signal == types.Signal.@"error");
    assert(r.beginsWith(prefix));
    raises_seen += 1;
}

// ==========================================================================
// The mode scanner
// ==========================================================================

const Scan = struct {
    status: i32,
    flags: i32,
    sandbox: types.Sandbox,
    index: i32,
};

/// A mode string is scanned as a whole; the caller reads back the flag word,
/// the permissions the accepted prefix implies, and where the scan stopped.
fn scan(mode: []const u8) Scan {
    var out: Scan = .{ .status = 0, .flags = 0, .sandbox = .{}, .index = 0 };
    out.status = io_core.scanMode(
        mode.ptr,
        @intCast(mode.len),
        &out.flags,
        &out.sandbox,
        &out.index,
    );
    return out;
}

fn theModeScanning() void {
    // Each leading flag selects one access mode and one permission.
    var r = scan("r");
    assert(r.status == io_core.mode_ok);
    assert(r.flags == constants.JANET_FILE_READ);
    assert(r.sandbox == types.Sandbox.of(&.{"fs_read"}));

    r = scan("w");
    assert(r.status == io_core.mode_ok);
    assert(r.flags == constants.JANET_FILE_WRITE);
    assert(r.sandbox == types.Sandbox.of(&.{"fs_write"}));

    // Appending asks for the whole filesystem permission, not just write.
    r = scan("a");
    assert(r.status == io_core.mode_ok);
    assert(r.flags == constants.JANET_FILE_APPEND);
    assert(r.sandbox == types.Sandbox.fs);

    // Trailing flags accumulate in any order and are independent.
    r = scan("wnb");
    assert(r.status == io_core.mode_ok);
    assert(r.flags == (constants.JANET_FILE_WRITE | constants.JANET_FILE_NONIL | constants.JANET_FILE_BINARY));
    r = scan("wbn");
    assert(r.status == io_core.mode_ok);
    assert(r.flags == (constants.JANET_FILE_WRITE | constants.JANET_FILE_NONIL | constants.JANET_FILE_BINARY));

    // An update flag adds the write permission even to a read mode.
    r = scan("r+");
    assert(r.status == io_core.mode_ok);
    assert(r.flags == (constants.JANET_FILE_READ | constants.JANET_FILE_UPDATE));
    assert(r.sandbox == types.Sandbox.of(&.{ "fs_read", "fs_write" }));

    // The longest accepted mode is ten bytes; eleven is rejected on length
    // alone, before any byte is classified.
    r = scan("");
    assert(r.status == io_core.mode_bad_length);
    assert(r.sandbox == types.Sandbox.none);
    assert(scan("rbnbnbnbnb").status == io_core.mode_repeated);
    r = scan("qqqqqqqqqqq");
    assert(r.status == io_core.mode_bad_length);
    assert(r.sandbox == types.Sandbox.none);

    // An unusable first byte stops the scan before any permission accrues, so
    // the caller reports the bad flag rather than a sandbox violation.
    r = scan("q");
    assert(r.status == io_core.mode_bad_first);
    assert(r.index == 0);
    assert(r.sandbox == types.Sandbox.none);
    assert(scan("+").status == io_core.mode_bad_first);
    assert(scan("R").status == io_core.mode_bad_first);

    // A later bad byte stops there, and the permissions of the prefix are
    // still reported, because the C loop asserted them on the way past.
    r = scan("rq");
    assert(r.status == io_core.mode_bad_later);
    assert(r.index == 1);
    assert(r.sandbox == types.Sandbox.of(&.{"fs_read"}));
    r = scan("r+q");
    assert(r.status == io_core.mode_bad_later);
    assert(r.index == 2);
    assert(r.sandbox == types.Sandbox.of(&.{ "fs_read", "fs_write" }));
    r = scan("rq+");
    assert(r.status == io_core.mode_bad_later);
    assert(r.index == 1);
    assert(r.sandbox == types.Sandbox.of(&.{"fs_read"}));

    // A repeated flag yields a flag word of -1, which the caller then uses as
    // a flag word; see `FOUND.md`.
    r = scan("r++");
    assert(r.status == io_core.mode_repeated);
    assert(r.flags == -1);
    r = scan("rbb");
    assert(r.status == io_core.mode_repeated);
    assert(r.flags == -1);
    assert(r.sandbox == types.Sandbox.of(&.{"fs_read"}));
    r = scan("rnn");
    assert(r.status == io_core.mode_repeated);
    assert(r.flags == -1);

    // A repeat is detected across intervening flags, not only next to itself.
    r = scan("rbnb");
    assert(r.status == io_core.mode_repeated);
    assert(r.flags == -1);

    // A repeat stops the scan, so a bad byte after it is never reached.
    assert(scan("rbbq").status == io_core.mode_repeated);
}

fn theSeekOrigins() void {
    // The positions are the order the C if-chain tested, and the mapping to
    // the host's `SEEK_*` constants happens behind the seam.
    assert(io_core.seekWhence("cur", 3) == 0);
    assert(io_core.seekWhence("set", 3) == 1);
    assert(io_core.seekWhence("end", 3) == 2);

    // Only whole names match, as `janet_cstrcmp` required.
    assert(io_core.seekWhence("cu", 2) == -1);
    assert(io_core.seekWhence("current", 7) == -1);
    assert(io_core.seekWhence("", 0) == -1);
    assert(io_core.seekWhence("CUR", 3) == -1);
}

fn theModeReconstruction() void {
    var out: [4]u8 = undefined;

    // Reading comes first, and appending replaces writing rather than joining
    // it, because a marshalled descriptor only needs a mode `fdopen` accepts.
    assert(io_core.modeFromFlags(constants.JANET_FILE_READ, &out) == 1);
    assert(std.mem.eql(u8, out[0..2], "r\x00"));
    assert(io_core.modeFromFlags(constants.JANET_FILE_WRITE, &out) == 1);
    assert(std.mem.eql(u8, out[0..2], "w\x00"));
    assert(io_core.modeFromFlags(constants.JANET_FILE_APPEND, &out) == 1);
    assert(std.mem.eql(u8, out[0..2], "a\x00"));
    assert(io_core.modeFromFlags(constants.JANET_FILE_READ | constants.JANET_FILE_WRITE, &out) == 2);
    assert(std.mem.eql(u8, out[0..3], "rw\x00"));
    assert(io_core.modeFromFlags(
        constants.JANET_FILE_READ | constants.JANET_FILE_WRITE | constants.JANET_FILE_APPEND,
        &out,
    ) == 2);
    assert(std.mem.eql(u8, out[0..3], "ra\x00"));

    // The binary, update and no-nil flags are dropped, and an empty result is
    // still terminated.
    assert(io_core.modeFromFlags(
        constants.JANET_FILE_READ | constants.JANET_FILE_BINARY | constants.JANET_FILE_UPDATE,
        &out,
    ) == 1);
    assert(std.mem.eql(u8, out[0..2], "r\x00"));
    assert(io_core.modeFromFlags(constants.JANET_FILE_BINARY, &out) == 0);
    assert(out[0] == 0);
}

// ==========================================================================
// The stream operations
// ==========================================================================

fn theStreamOperations() void {
    var buffer: [32]u8 = undefined;

    // A missing file is reported by a null stream, not a raise.
    assert(io_core.open("janet-zig-io-core-absent-9d24", "rb") == null);

    var file = io_core.open(scratch, "wb").?;

    // A write is one item of n bytes, so success is 1 and the byte count is
    // not reported back.
    assert(io_core.write(file, "hello", 5) == 1);
    assert(io_core.putChar(file, '\n') == '\n');
    assert(io_core.write(file, "second", 6) == 1);
    assert(io_core.tell(file) == 12);
    assert(io_core.flush(file) == 0);
    assert(io_core.close(file) == 0);

    file = io_core.open(scratch, "rb").?;

    // A short read is not an error; the caller distinguishes end of file from
    // failure with `err`.
    assert(io_core.read(file, &buffer, buffer.len) == 12);
    assert(io_core.err(file) == 0);
    assert(std.mem.eql(u8, buffer[0..12], "hello\nsecond"));
    assert(io_core.read(file, &buffer, buffer.len) == 0);
    assert(io_core.err(file) == 0);

    // Seeking uses the positions the whence lookup returns.
    assert(io_core.seek(file, 6, 1) == 0);
    assert(io_core.tell(file) == 6);
    assert(io_core.getChar(file) == 's');
    assert(io_core.seek(file, 2, 0) == 0);
    assert(io_core.tell(file) == 9);
    assert(io_core.seek(file, -3, 2) == 0);
    assert(io_core.tell(file) == 9);
    assert(io_core.getChar(file) == 'o');

    // Reading to the end returns EOF without setting the error indicator.
    assert(io_core.seek(file, 0, 2) == 0);
    assert(io_core.getChar(file) == c.EOF);
    assert(io_core.err(file) == 0);
    assert(io_core.close(file) == 0);

    // Both buffering modes are accepted, and an unbuffered stream reaches the
    // filesystem without a flush.
    file = io_core.open(scratch, "wb").?;
    assert(io_core.setBufferSize(file, 0) == 0);
    assert(io_core.write(file, "unbuffered", 10) == 1);
    {
        const reader = io_core.open(scratch, "rb").?;
        assert(io_core.read(reader, &buffer, buffer.len) == 10);
        assert(std.mem.eql(u8, buffer[0..10], "unbuffered"));
        assert(io_core.close(reader) == 0);
    }
    assert(io_core.close(file) == 0);

    file = io_core.open(scratch, "wb").?;
    assert(io_core.setBufferSize(file, 4096) == 0);
    assert(io_core.close(file) == 0);

    // A temporary stream is readable and writable and needs no path.
    file = io_core.temp().?;
    assert(io_core.write(file, "temp", 4) == 1);
    assert(io_core.seek(file, 0, 1) == 0);
    assert(io_core.read(file, &buffer, buffer.len) == 4);
    assert(std.mem.eql(u8, buffer[0..4], "temp"));
    assert(io_core.close(file) == 0);

    _ = c.remove(scratch);
}

// ==========================================================================
// The abstract type
// ==========================================================================

fn theAbstractType() void {
    // The callback set is part of the type's contract: `core/file` has a
    // finalizer, a method getter, a marshal pair and a key walker, and nothing
    // else. A `tostring` in particular would change how every file prints.
    const at = &io_core.fileType;
    assert(std.mem.eql(u8, at.name, "core/file"));
    assert(at.gc != null);
    assert(at.gcmark == null);
    assert(at.get != null);
    assert(at.put == null);
    assert(at.marshal != null);
    assert(at.unmarshal != null);
    assert(at.tostring == null);
    assert(at.compare == null);
    assert(at.hash == null);
    assert(at.next != null);
    assert(at.call == null);
    assert(at.length == null);
    assert(at.bytes == null);
}

/// The method table is scanned linearly and walked in order, so its order is
/// observable through `next` and is part of the contract rather than a
/// tidiness.
fn theMethodOrder() raise.Raising(void) {
    const at = &io_core.fileType;
    const expected = [_][*:0]const u8{ "close", "flush", "read", "seek", "tell", "write" };

    // `next` and `get` ignore the payload -- they read the method table -- and
    // a C contract could pass `null` for it, because the slot was `void *`.
    // The runtime cannot: a dispatch starts from a live abstract's header, so
    // the payload is always a real `JanetFile`. The typed callback says so and
    // the erased shim asserts it, so the contract supplies one.
    var borrowed: types.JanetFile = std.mem.zeroes(types.JanetFile);
    const payload: ?*anyopaque = &borrowed;

    var key = wrap.fromNil();
    var i: usize = 0;
    while (true) : (i += 1) {
        key = try at.next.?(payload, key);
        if (harness.isType(key, repr.Tag.nil)) break;
        assert(i < expected.len);
        assert(harness.keywordIs(key, expected[i]));
    }
    assert(i == expected.len);

    // The getter answers only keywords, and only names in the table.
    var out = wrap.fromNil();
    assert(try at.get.?(payload, value.fromBytes("read", .keyword), &out) == 1);
    assert(harness.isType(out, repr.Tag.cfunction));
    assert(try at.get.?(payload, value.fromBytes("open", .keyword), &out) == 0);
    assert(try at.get.?(payload, value.fromBytes("read", .string), &out) == 0);
}

// ==========================================================================
// The public C API
// ==========================================================================

fn thePublicApi() raise.Raising(void) {
    const raw = io_core.open(scratch, "wb").?;

    // `janet_makejfile` hands back the payload; `janet_makefile` wraps it. The
    // buffer size is the C library's default, which is what `file/open`
    // compares against to decide whether a caller asked for another one.
    const jf = io_core_mod.makejfile(@ptrCast(@alignCast(raw)), constants.JANET_FILE_WRITE);
    assert(@as(?*anyopaque, @ptrCast(jf.*.file)) == @as(?*anyopaque, raw));
    assert(jf.*.flags == constants.JANET_FILE_WRITE);
    assert(jf.*.vbufsize == c.BUFSIZ);

    const wrapped = wrap.fromAbstract(jf);
    assert(io_core_mod.checkfile(wrapped) == @as(?*anyopaque, jf));
    assert(io_core_mod.checkfile(wrap.fromNil()) == null);
    assert(io_core_mod.checkfile(harness.wrapInteger(3)) == null);

    var flags: i32 = 0;
    assert(@as(?*anyopaque, @ptrCast(io_core_mod.unwrapfile(wrapped, &flags))) == @as(?*anyopaque, raw));
    assert(flags == constants.JANET_FILE_WRITE);
    assert(@as(?*anyopaque, @ptrCast(io_core_mod.unwrapfile(wrapped, null))) == @as(?*anyopaque, raw));

    // The reporting halves of these two are `capi.zig`'s, which is where a
    // boundary that builds a slice out of an index belongs. What is left takes
    // the slice.
    var argv = [_]repr.Value{wrapped};
    assert(try io_core_mod.getjfile(argv[0..1], 0) == jf);
    flags = 0;
    assert(@as(?*anyopaque, @ptrCast(try io_core_mod.getfile(argv[0..1], 0, &flags))) == @as(?*anyopaque, raw));
    assert(flags == constants.JANET_FILE_WRITE);
    assert(@as(?*anyopaque, @ptrCast(try io_core_mod.getfile(argv[0..1], 0, null))) == @as(?*anyopaque, raw));

    // Closing marks the payload and clears the stream, so a later use is a
    // null dereference rather than a use-after-free. A second close is a
    // no-op, and so is closing a file this runtime only borrowed.
    assert(io_core_mod.fileClose(jf) == 0);
    assert(jf.*.flags & constants.JANET_FILE_CLOSED != 0);
    assert(jf.*.file == null);
    assert(io_core_mod.fileClose(jf) == 0);

    const borrowed = io_core_mod.makejfile(
        @ptrCast(@alignCast(stdio.out())),
        constants.JANET_FILE_APPEND | constants.JANET_FILE_NOT_CLOSEABLE,
    );
    assert(io_core_mod.fileClose(borrowed) == 0);
    assert(borrowed.*.flags & constants.JANET_FILE_CLOSED == 0);
    assert(asHandle(borrowed.*.file) == stdio.out());

    // A value of the wrong type is an argument fault rather than a null. It
    // arrives as an error rather than as a report, because the reporting half
    // of both getters is in `capi.zig` -- which is where an entry point that
    // has to build a slice out of an index belongs.
    var bad = [_]repr.Value{harness.wrapInteger(3)};
    expectRaisePrefix(io_core_mod.getjfile, .{ bad[0..1], @as(i32, 0) }, "bad slot #0");
    expectRaisePrefix(io_core_mod.getfile, .{ bad[0..1], @as(i32, 0), null }, "bad slot #0");

    _ = c.remove(scratch);
}

fn theDynamicFile() void {
    // Outside a fiber the dynamic bindings live in the VM's top-level table,
    // which is what lets this run without one.
    assert(asHandle(io_core_mod.dynfile("io-core-out", @ptrCast(@alignCast(stdio.out())))) == stdio.out());
    assert(asHandle(io_core_mod.dynfile("io-core-out", null)) == null);

    // Anything that is not a `core/file` falls back to the default, including
    // another abstract type.
    vm_state.setdyn("io-core-out", harness.wrapInteger(3));
    assert(asHandle(io_core_mod.dynfile("io-core-out", @ptrCast(@alignCast(stdio.err())))) == stdio.err());
    vm_state.setdyn("io-core-out", wrap.fromAbstract(
        abstracts.new(&math.rngType, @sizeOf(types.JanetRNG)),
    ));
    assert(asHandle(io_core_mod.dynfile("io-core-out", @ptrCast(@alignCast(stdio.err())))) == stdio.err());

    const jf = io_core_mod.makejfile(
        @ptrCast(@alignCast(stdio.out())),
        constants.JANET_FILE_APPEND | constants.JANET_FILE_NOT_CLOSEABLE,
    );
    vm_state.setdyn("io-core-out", wrap.fromAbstract(jf));
    assert(asHandle(io_core_mod.dynfile("io-core-out", @ptrCast(@alignCast(stdio.err())))) == stdio.out());
    vm_state.setdyn("io-core-out", wrap.fromNil());
}

// ==========================================================================
// Marshalling
// ==========================================================================

fn marshalled(buffer: *types.JanetBuffer, val: repr.Value, flags: c_int) raise.Raising(void) {
    return marsh.marshal(buffer, val, null, flags);
}

fn unmarshalled(buffer: *types.JanetBuffer, flags: c_int) raise.Raising(repr.Value) {
    return marsh.unmarshal(buffer.slice(), flags, null, null);
}

/// A file marshals only under `JANET_MARSHAL_UNSAFE`, which no Janet caller
/// can ask for, so the whole callback pair is unreachable from the language.
fn theMarshalling() raise.Raising(void) {
    const raw = io_core.open(scratch, "wb").?;
    const file = wrap.fromAbstract(io_core_mod.makejfile(@ptrCast(@alignCast(raw)), constants.JANET_FILE_WRITE));

    const buffer = buffers.new(0);
    expectRaise(marshalled, .{ buffer, file, @as(c_int, 0) }, "cannot marshal file in safe mode");

    buffer.*.count = 0;
    try marshalled(buffer, file, constants.JANET_MARSHAL_UNSAFE);
    assert(buffer.*.count > 0);

    // Reading it back in safe mode is refused by the other half of the pair.
    expectRaise(unmarshalled, .{ buffer, @as(c_int, 0) }, "cannot unmarshal file in safe mode");

    const back = try unmarshalled(buffer, constants.JANET_MARSHAL_UNSAFE);
    const copy = io_core_mod.checkfile(back);
    assert(copy != null);
    const copyf: *types.JanetFile = @ptrCast(@alignCast(copy));
    assert(copyf.flags == constants.JANET_FILE_WRITE);
    assert(copyf.vbufsize == c.BUFSIZ);

    // The descriptor was duplicated, because the original owns its stream, so
    // the copy is a different stream on the same file and closing one leaves
    // the other usable.
    assert(@as(?*anyopaque, @ptrCast(copyf.file)) != @as(?*anyopaque, raw));
    assert(io_core_mod.fileClose(copyf) == 0);
    assert(io_core.write(raw, "kept", 4) == 1);
    assert(io_core_mod.fileClose(@ptrCast(@alignCast(io_core_mod.checkfile(file)))) == 0);
    _ = c.remove(scratch);
}

/// The recorded buffer size is restored by a real `setvbuf` on the way back
/// in, which is only visible if it is not the default: an unbuffered stream
/// reaches the filesystem with no flush and a buffered one does not.
fn theMarshalledBufferSize() raise.Raising(void) {
    const stream = io_core.open(scratch, "wb").?;
    const jf = io_core_mod.makejfile(@ptrCast(@alignCast(stream)), constants.JANET_FILE_WRITE);
    jf.*.vbufsize = 0;
    const file = wrap.fromAbstract(jf);

    const buffer = buffers.new(0);
    try marshalled(buffer, file, constants.JANET_MARSHAL_UNSAFE);
    const copy = io_core_mod.checkfile(try unmarshalled(buffer, constants.JANET_MARSHAL_UNSAFE));
    assert(copy != null);
    const copyf: *types.JanetFile = @ptrCast(@alignCast(copy));
    assert(copyf.vbufsize == 0);

    assert(io_core.write(@ptrCast(copyf.file), "now", 3) == 1);
    {
        var seen: [8]u8 = undefined;
        const check = io_core.open(scratch, "rb").?;
        assert(io_core.read(check, &seen, seen.len) == 3);
        assert(std.mem.eql(u8, seen[0..3], "now"));
        assert(io_core.close(check) == 0);
    }
    assert(io_core_mod.fileClose(copyf) == 0);
    assert(io_core_mod.fileClose(jf) == 0);
    _ = c.remove(scratch);
}

// ==========================================================================
// What only a mismatched handle reaches
// ==========================================================================

/// A `JanetFile`'s flags and its stream can disagree, which nothing in Janet
/// can arrange and which is the only way into two of the failure paths. Both
/// are reachable by an embedder, since `janet_makejfile` takes the flag word
/// from its caller and never consults the stream.
fn theMismatchedHandles() void {
    const writer = io_core.open(scratch, "wb").?;
    const claims_readable = wrap.fromAbstract(
        io_core_mod.makejfile(@ptrCast(@alignCast(writer)), constants.JANET_FILE_READ),
    );

    // The readability check passes on the flags and the read then fails, which
    // is the branch that separates a short read from a broken one.
    var read_args = [_]repr.Value{ claims_readable, harness.wrapInteger(10) };
    expectRaise(harness.core("file/read"), .{read_args[0..2]}, "could not read file");
    assert(io_core_mod.fileClose(@ptrCast(@alignCast(io_core_mod.checkfile(claims_readable)))) == 0);

    const reader = io_core.open(scratch, "rb").?;
    const claims_writeable = wrap.fromAbstract(
        io_core_mod.makejfile(@ptrCast(@alignCast(reader)), constants.JANET_FILE_WRITE),
    );

    // `xprint` has no default handle, so a failed write names the destination
    // rather than reporting a bare byte count.
    var print_args = [_]repr.Value{
        claims_writeable,
        wrap.fromString(strings.cstring("text")),
    };
    expectRaisePrefix(
        harness.core("xprint"),
        .{print_args[0..2]},
        "cannot print 4 bytes to ",
    );
    assert(io_core_mod.fileClose(@ptrCast(@alignCast(io_core_mod.checkfile(claims_writeable)))) == 0);

    _ = c.remove(scratch);
}

// ==========================================================================
// What a Janet caller sees
// ==========================================================================

fn doString(environment: *types.JanetTable, source: [*:0]const u8) void {
    var result = wrap.fromNil();
    if (core_env.dostring(environment, source, "io-core-contract", &result) != 0) {
        std.debug.print("io_core: {s}\n", .{pp_describe.toString(result)});
        @panic("io_core: a contract form failed");
    }
}

fn theCoreFunctions() void {
    const env = harness.coreEnv();

    // A file opens, round-trips its contents, and reports positions.
    doString(env,
        \\(def f (file/open "janet-zig-io-core-public-9d24" :wb))
        \\(file/write f "first line\n" "second")
        \\(assert (= 17 (file/tell f)))
        \\(file/flush f)
        \\(file/close f)
        \\(def f (file/open "janet-zig-io-core-public-9d24" :rb))
        \\(assert (= "first line\n" (string (file/read f :line))))
        \\(assert (= "second" (string (file/read f :all))))
        \\(assert (nil? (file/read f :line)))
        \\(file/close f)
    );

    // Seeking accepts each origin keyword and rejects anything else.
    doString(env,
        \\(def f (file/open "janet-zig-io-core-public-9d24" :rb))
        \\(file/seek f :set 11)
        \\(assert (= 11 (file/tell f)))
        \\(assert (= "sec" (string (file/read f 3))))
        \\(file/seek f :cur -3)
        \\(assert (= 11 (file/tell f)))
        \\(file/seek f :end -6)
        \\(assert (= 11 (file/tell f)))
        \\(assert (not (first (protect (file/seek f :middle 0)))))
        \\(file/close f)
    );

    // Reading a byte count stops at the end of the file and then reports nil.
    doString(env,
        \\(def f (file/open "janet-zig-io-core-public-9d24" :rb))
        \\(assert (= "first line\nsecond" (string (file/read f 100))))
        \\(assert (nil? (file/read f 4)))
        \\(assert (= "" (string (file/read f :all))))
        \\(file/close f)
    );

    // Appending preserves the existing contents; writing truncates.
    doString(env,
        \\(def f (file/open "janet-zig-io-core-public-9d24" :ab))
        \\(file/write f "!")
        \\(file/close f)
        \\(assert (= "first line\nsecond!" (string (slurp "janet-zig-io-core-public-9d24"))))
        \\(def f (file/open "janet-zig-io-core-public-9d24" :wb))
        \\(file/close f)
        \\(assert (= "" (string (slurp "janet-zig-io-core-public-9d24"))))
    );

    // A closed file rejects every operation, and closing twice is harmless.
    doString(env,
        \\(def f (file/open "janet-zig-io-core-public-9d24" :rb))
        \\(file/close f)
        \\(assert (nil? (file/close f)))
        \\(assert (not (first (protect (file/read f :all)))))
        \\(assert (not (first (protect (file/write f "x")))))
        \\(assert (not (first (protect (file/tell f)))))
    );

    // A file opened for reading is not writeable, and one opened for writing
    // is not readable, unless the update flag is present.
    doString(env,
        \\(def f (file/open "janet-zig-io-core-public-9d24" :rb))
        \\(assert (not (first (protect (file/write f "x")))))
        \\(assert (not (first (protect (file/flush f)))))
        \\(file/close f)
        \\(def f (file/open "janet-zig-io-core-public-9d24" :wb))
        \\(assert (not (first (protect (file/read f :all)))))
        \\(file/close f)
        \\(def f (file/open "janet-zig-io-core-public-9d24" :w+b))
        \\(file/write f "update")
        \\(file/seek f :set 0)
        \\(assert (= "update" (string (file/read f :all))))
        \\(file/close f)
    );

    // A missing file is nil, or an error when the mode asks for one.
    doString(env,
        \\(assert (nil? (file/open "janet-zig-io-core-absent-9d24" :r)))
        \\(assert (not (first (protect (file/open "janet-zig-io-core-absent-9d24" :rn)))))
    );

    // Malformed modes are rejected by position, and each names the byte that
    // stopped the scan.
    doString(env,
        \\(defn why [mode] (last (protect (file/open "janet-zig-io-core-public-9d24" mode))))
        \\(assert (= "file mode must have a length between 1 and 10" (why (keyword ""))))
        \\(assert (= "file mode must have a length between 1 and 10" (why :rbnbnbnbnbn)))
        \\(assert (= "invalid flag q, expected w, a, or r" (why :q)))
        \\(assert (= "invalid flag +, expected w, a, or r" (why (keyword "+"))))
        \\(assert (= "invalid flag q, expected +, b, or n" (why :rq)))
        \\(assert (= "invalid flag q, expected +, b, or n" (why :r+q)))
    );

    // A repeated flag produces a handle with every flag bit set, which reports
    // itself as closed while its descriptor stays open. `FOUND.md` records
    // this; it is reproduced rather than fixed.
    doString(env,
        \\(def f (file/open "janet-zig-io-core-public-9d24" :r++))
        \\(assert (= :core/file (type f)))
        \\(assert (not (first (protect (file/read f :all)))))
        \\(assert (nil? (file/close f)))
    );

    // Supplying a buffer size replaces the requested mode with read-only and
    // skips the mode scan entirely, so a write mode neither truncates nor
    // writes and a nonsense mode is accepted. `FOUND.md` records this; it is
    // reproduced rather than fixed.
    doString(env,
        \\(spit "janet-zig-io-core-public-9d24" "buffered")
        \\(def f (file/open "janet-zig-io-core-public-9d24" :wb 8192))
        \\(assert (= :core/file (type f)))
        \\(assert (not (first (protect (file/write f "x")))))
        \\(assert (= "buffered" (string (file/read f :all))))
        \\(file/close f)
        \\(assert (= "buffered" (string (slurp "janet-zig-io-core-public-9d24"))))
        \\(def f (file/open "janet-zig-io-core-public-9d24" :zzz 0))
        \\(assert (= :core/file (type f)))
        \\(assert (= "buffered" (string (file/read f :all))))
        \\(file/close f)
    );

    // `file/temp` is anonymous, readable, and writable.
    doString(env,
        \\(def f (file/temp))
        \\(file/write f "scratch")
        \\(file/seek f :set 0)
        \\(assert (= "scratch" (string (file/read f :all))))
        \\(file/close f)
    );

    // Printing to a file goes through the same write path, newline included.
    doString(env,
        \\(def f (file/open "janet-zig-io-core-public-9d24" :wb))
        \\(xprint f "printed")
        \\(xprin f "tail")
        \\(xprinf f "%d" 42)
        \\(xprintf f "%d" 7)
        \\(file/close f)
        \\(assert (= "printed\ntail427\n" (string (slurp "janet-zig-io-core-public-9d24"))))
    );

    // The scratch file is removed by `cleanPaths` rather than by `os/rm`, so
    // this contract still runs in a reduced-OS build.
}

pub fn run() void {
    cleanPaths();

    theModeScanning();
    theSeekOrigins();
    theModeReconstruction();
    theStreamOperations();

    harness.init();
    // The abstract type has to be in the registry before anything marshals a
    // file, and the registration is `janet_lib_io`'s. Building the core
    // environment first is also what the public section needs, and it is
    // memoized, so the two share one.
    _ = harness.coreEnv();

    theAbstractType();
    theMethodOrder() catch @panic("io_core: the method table raised");
    thePublicApi() catch @panic("io_core: the public API raised");
    theDynamicFile();
    theMarshalling() catch @panic("io_core: marshalling raised");
    theMarshalledBufferSize() catch @panic("io_core: the buffer size raised");
    theMismatchedHandles();
    theCoreFunctions();

    assert(raises_seen == expected_raises);
    vm_state.deinit();

    cleanPaths();
    std.debug.print("io_core contract ok ({d} raises)\n", .{raises_seen});
}
