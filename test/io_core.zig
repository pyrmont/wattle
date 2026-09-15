//! Behavioral contract for the file subsystem: mode-string parsing, the
//! stream host operations, the `core/file` abstract type, the public
//! `io.File` entry points, and the cfunction surface over all of them.
//!
//! ## Why this file exists rather than the suite covering it
//!
//! Three things here are unreachable from Janet. The `io.File` entry points
//! are C API with no Janet spelling; the abstract type's `marshal` and
//! `unmarshal` callbacks run only under `JANET_MARSHAL_UNSAFE`, which
//! `(marshal f)` never sets; and a `io.File` whose flags and whose stream
//! disagree is a thing only an embedder can build, and is the only way into
//! two of the failure paths.
//!
//! ## How the subjects are reached
//!
//! The fifteen host operations are reached by import, `io.write` included,
//! which is the one with a caller outside its own subsystem, in
//! `pp/format.zig`.
//!
//! The three mode-scan status codes and the five file-mode flags are named
//! rather than restated. A third copy of numbers two files already agree on is
//! a place they can drift.
//!
//! The public API half reaches `io.getjfile` and `io.getfile` as raising
//! functions, so `harness.raised` is the instrument and an argument fault
//! arrives as an error. `expectAbiRaise` below is for a published entry point
//! that reports instead, and has no caller today.

// ==========================================================================
// Standard library imports
// ==========================================================================

const builtin = @import("builtin");
const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abstracts = @import("subsystems").value.abstracts;

/// `boundary` rather than `abi`, which `expectAbiRaise` takes as a parameter
/// name.
const boundary = @import("abi");
const buffers = @import("subsystems").value.buffers;
const c = @import("cabi");
const config = @import("config");
const constants = @import("constants");
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const harness = @import("harness.zig");
const io_core = subsystems.io;
const marsh = subsystems.marsh;
const math = @import("subsystems").math;
const pp_describe = @import("subsystems").pp_describe;
const raise = @import("subsystems").raise;
const repr = @import("repr");

/// The three standard streams, and the only spelling of them a contract in
/// this tree may use.
///
/// `c.stdout` is an inline *function* in Darwin's headers, a *variable* of
/// opaque type on musl, which is not callable, and on mingw a constant
/// whose initializer calls an extern function, which Zig rejects outright as
/// "comptime call of extern function". `stdio.zig` exists for exactly that and
/// names the symbol underneath the macro instead; its header comment has the
/// table, and the matrix's four cross-compile entries are what would catch a
/// contract naming `stdout` directly.
const stdio = subsystems.stdio;
const strings = @import("subsystems").value.strings;
const subsystems = @import("subsystems");
const tables = @import("subsystems").value.tables;
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const vm_state = @import("subsystems").vm_state;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// Six, not seven: `dynprintf`'s "file is not writeable" case is in
/// `test/pp_format.zig`, with its subject.
const expected_raises = 6;
const public = "wattle-io-core-public-9d24";
var raises_seen: u32 = 0;
const scratch = "wattle-io-core-9d24";

// ==========================================================================
// Types
// ==========================================================================

const Scan = struct {
    status: i32,
    flags: i32,
    sandbox: vm_lifecycle.Sandbox,
    index: i32,
};

// ==========================================================================
// Cases
// ==========================================================================

/// A `*host.FILE` as the `?*anyopaque` the stream kernels deal in. The same
/// pointer, a different Zig type.
fn asHandle(file: anytype) ?*anyopaque {
    return @ptrCast(@alignCast(file));
}

fn cleanPaths() void {
    _ = c.remove(scratch);
    _ = c.remove(public);
}

/// A refusal, by the message it came with. Reading the message is what
/// distinguishes "it refused" from "it refused for the reason this case is
/// about": three mutations inside message literals once survived a whole sweep
/// against a contract that only asked whether something raised.
fn expectRaise(function: anytype, args: anytype, message: []const u8) void {
    const r = harness.raised(function, args) orelse {
        std.debug.print("io_core: expected a raise saying: {s}\n", .{message});
        @panic("io_core: expected a raise, got a return");
    };
    expect(r.signal == boundary.Signal.@"error");
    if (!r.says(message)) {
        std.debug.print("expected: {s}\n", .{message});
        std.debug.print("     got: {s}\n", .{pp_describe.toString(r.payload)});
        @panic("io_core: the raise carried another message");
    }
    raises_seen += 1;
}

/// The same for an abi, whose refusal arrives as a report rather than as an
/// error. `null` for a message that is not checked.
fn expectAbiRaise(abi: anytype, args: anytype, message: ?[]const u8) void {
    const r = harness.abiRaised(abi, args) orelse
        @panic("io_core: expected a raise from an abi, got a return");
    expect(r.signal == boundary.Signal.@"error");
    if (message) |text| expect(r.says(text));
    raises_seen += 1;
}

/// For the one message with an address in it: `%v` renders a `core/file` by
/// pointer, so only the fixed part can be compared, and the fixed part is
/// exactly what distinguishes it from the message the other branch produces.
fn expectRaisePrefix(function: anytype, args: anytype, prefix: []const u8) void {
    const r = harness.raised(function, args) orelse
        @panic("io_core: expected a raise, got a return");
    expect(r.signal == boundary.Signal.@"error");
    expect(r.beginsWith(prefix));
    raises_seen += 1;
}

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

fn doString(environment: *tables.Table, source: [*:0]const u8) void {
    var result = wrap.fromNil();
    if (core_env.dostring(environment, source, "io-core-contract", &result) != 0) {
        std.debug.print("io_core: {s}\n", .{pp_describe.toString(result)});
        @panic("io_core: a contract form failed");
    }
}

fn theModeScanning() void {
    // Each leading flag selects one access mode and one permission.
    var r = scan("r");
    expect(r.status == io_core.mode_ok);
    expect(r.flags == constants.JANET_FILE_READ);
    expect(r.sandbox == vm_lifecycle.Sandbox.of(&.{"fs_read"}));

    r = scan("w");
    expect(r.status == io_core.mode_ok);
    expect(r.flags == constants.JANET_FILE_WRITE);
    expect(r.sandbox == vm_lifecycle.Sandbox.of(&.{"fs_write"}));

    // Appending asks for the whole filesystem permission, not just write.
    r = scan("a");
    expect(r.status == io_core.mode_ok);
    expect(r.flags == constants.JANET_FILE_APPEND);
    expect(r.sandbox == vm_lifecycle.Sandbox.fs);

    // Trailing flags accumulate in any order and are independent.
    r = scan("wnb");
    expect(r.status == io_core.mode_ok);
    expect(r.flags == (constants.JANET_FILE_WRITE | constants.JANET_FILE_NONIL | constants.JANET_FILE_BINARY));
    r = scan("wbn");
    expect(r.status == io_core.mode_ok);
    expect(r.flags == (constants.JANET_FILE_WRITE | constants.JANET_FILE_NONIL | constants.JANET_FILE_BINARY));

    // An update flag adds the write permission even to a read mode.
    r = scan("r+");
    expect(r.status == io_core.mode_ok);
    expect(r.flags == (constants.JANET_FILE_READ | constants.JANET_FILE_UPDATE));
    expect(r.sandbox == vm_lifecycle.Sandbox.of(&.{ "fs_read", "fs_write" }));

    // The longest accepted mode is ten bytes; eleven is rejected on length
    // alone, before any byte is classified.
    r = scan("");
    expect(r.status == io_core.mode_bad_length);
    expect(r.sandbox == vm_lifecycle.Sandbox.none);
    expect(scan("rbnbnbnbnb").status == io_core.mode_repeated);
    r = scan("qqqqqqqqqqq");
    expect(r.status == io_core.mode_bad_length);
    expect(r.sandbox == vm_lifecycle.Sandbox.none);

    // An unusable first byte stops the scan before any permission accrues, so
    // the caller reports the bad flag rather than a sandbox violation.
    r = scan("q");
    expect(r.status == io_core.mode_bad_first);
    expect(r.index == 0);
    expect(r.sandbox == vm_lifecycle.Sandbox.none);
    expect(scan("+").status == io_core.mode_bad_first);
    expect(scan("R").status == io_core.mode_bad_first);

    // A later bad byte stops there, and the permissions of the prefix are
    // still reported, because the C loop asserted them on the way past.
    r = scan("rq");
    expect(r.status == io_core.mode_bad_later);
    expect(r.index == 1);
    expect(r.sandbox == vm_lifecycle.Sandbox.of(&.{"fs_read"}));
    r = scan("r+q");
    expect(r.status == io_core.mode_bad_later);
    expect(r.index == 2);
    expect(r.sandbox == vm_lifecycle.Sandbox.of(&.{ "fs_read", "fs_write" }));
    r = scan("rq+");
    expect(r.status == io_core.mode_bad_later);
    expect(r.index == 1);
    expect(r.sandbox == vm_lifecycle.Sandbox.of(&.{"fs_read"}));

    // A repeated flag is reported as `mode_repeated` with a flag word of -1.
    // The -1 is what the kernel returns rather than what a caller passes:
    // `checkFlags` raises on the status, because -1 has every bit set and two
    // of them are `file_closed` and `file_not_closeable`.
    r = scan("r++");
    expect(r.status == io_core.mode_repeated);
    expect(r.flags == -1);
    r = scan("rbb");
    expect(r.status == io_core.mode_repeated);
    expect(r.flags == -1);
    expect(r.sandbox == vm_lifecycle.Sandbox.of(&.{"fs_read"}));
    r = scan("rnn");
    expect(r.status == io_core.mode_repeated);
    expect(r.flags == -1);

    // A repeat is detected across intervening flags, not only next to itself.
    r = scan("rbnb");
    expect(r.status == io_core.mode_repeated);
    expect(r.flags == -1);

    // A repeat stops the scan, so a bad byte after it is never reached.
    expect(scan("rbbq").status == io_core.mode_repeated);
}

fn theSeekOrigins() void {
    // The positions are the order the C if-chain tested, and the mapping to
    // the host's `SEEK_*` constants happens behind the seam.
    expect(io_core.seekWhence("cur", 3) == 0);
    expect(io_core.seekWhence("set", 3) == 1);
    expect(io_core.seekWhence("end", 3) == 2);

    // Only whole names match, which is `utils.cstrcmp`'s rule.
    expect(io_core.seekWhence("cu", 2) == -1);
    expect(io_core.seekWhence("current", 7) == -1);
    expect(io_core.seekWhence("", 0) == -1);
    expect(io_core.seekWhence("CUR", 3) == -1);

    // The length bounds the walk, so the byte after the key is not read: a
    // key taken from the front of a longer word still matches.
    expect(io_core.seekWhence("curr", 3) == 0);
    expect(io_core.seekWhence("setx", 3) == 1);
}

fn theModeReconstruction() void {
    var out: [4]u8 = undefined;

    // Reading comes first, and appending replaces writing rather than joining
    // it, because a marshalled descriptor only needs a mode `fdopen` accepts.
    expect(io_core.modeFromFlags(constants.JANET_FILE_READ, &out) == 1);
    expect(std.mem.eql(u8, out[0..2], "r\x00"));
    expect(io_core.modeFromFlags(constants.JANET_FILE_WRITE, &out) == 1);
    expect(std.mem.eql(u8, out[0..2], "w\x00"));
    expect(io_core.modeFromFlags(constants.JANET_FILE_APPEND, &out) == 1);
    expect(std.mem.eql(u8, out[0..2], "a\x00"));
    expect(io_core.modeFromFlags(constants.JANET_FILE_READ | constants.JANET_FILE_WRITE, &out) == 2);
    expect(std.mem.eql(u8, out[0..3], "rw\x00"));
    expect(io_core.modeFromFlags(
        constants.JANET_FILE_READ | constants.JANET_FILE_WRITE | constants.JANET_FILE_APPEND,
        &out,
    ) == 2);
    expect(std.mem.eql(u8, out[0..3], "ra\x00"));

    // The binary, update and no-nil flags are dropped, and an empty result is
    // still terminated.
    expect(io_core.modeFromFlags(
        constants.JANET_FILE_READ | constants.JANET_FILE_BINARY | constants.JANET_FILE_UPDATE,
        &out,
    ) == 1);
    expect(std.mem.eql(u8, out[0..2], "r\x00"));
    expect(io_core.modeFromFlags(constants.JANET_FILE_BINARY, &out) == 0);
    expect(out[0] == 0);
}

fn theStreamOperations() void {
    var buffer: [32]u8 = undefined;

    // A missing file is reported by a null stream, not a raise.
    expect(io_core.open("wattle-io-core-absent-9d24", "rb") == null);

    var file = io_core.open(scratch, "wb").?;

    // A write is one item of n bytes, so success is 1 and the byte count is
    // not reported back.
    expect(io_core.write(file, "hello", 5) == 1);
    expect(io_core.putChar(file, '\n') == '\n');
    expect(io_core.write(file, "second", 6) == 1);
    expect(io_core.tell(file) == 12);
    expect(io_core.flush(file) == 0);
    expect(io_core.close(file) == 0);

    file = io_core.open(scratch, "rb").?;

    // A short read is not an error; the caller distinguishes end of file from
    // failure with `err`.
    expect(io_core.read(file, &buffer, buffer.len) == 12);
    expect(io_core.err(file) == 0);
    expect(std.mem.eql(u8, buffer[0..12], "hello\nsecond"));
    expect(io_core.read(file, &buffer, buffer.len) == 0);
    expect(io_core.err(file) == 0);

    // Seeking uses the positions the whence lookup returns.
    expect(io_core.seek(file, 6, 1) == 0);
    expect(io_core.tell(file) == 6);
    expect(io_core.getChar(file) == 's');
    expect(io_core.seek(file, 2, 0) == 0);
    expect(io_core.tell(file) == 9);
    expect(io_core.seek(file, -3, 2) == 0);
    expect(io_core.tell(file) == 9);
    expect(io_core.getChar(file) == 'o');

    // Reading to the end returns EOF without setting the error indicator.
    expect(io_core.seek(file, 0, 2) == 0);
    expect(io_core.getChar(file) == c.EOF);
    expect(io_core.err(file) == 0);
    expect(io_core.close(file) == 0);

    // Both buffering modes are accepted, and an unbuffered stream reaches the
    // filesystem without a flush.
    file = io_core.open(scratch, "wb").?;
    expect(io_core.setBufferSize(file, 0) == 0);
    expect(io_core.write(file, "unbuffered", 10) == 1);
    {
        const reader = io_core.open(scratch, "rb").?;
        expect(io_core.read(reader, &buffer, buffer.len) == 10);
        expect(std.mem.eql(u8, buffer[0..10], "unbuffered"));
        expect(io_core.close(reader) == 0);
    }
    expect(io_core.close(file) == 0);

    file = io_core.open(scratch, "wb").?;
    expect(io_core.setBufferSize(file, 4096) == 0);
    expect(io_core.close(file) == 0);

    // A temporary stream is readable and writable and needs no path.
    file = io_core.temp().?;
    expect(io_core.write(file, "temp", 4) == 1);
    expect(io_core.seek(file, 0, 1) == 0);
    expect(io_core.read(file, &buffer, buffer.len) == 4);
    expect(std.mem.eql(u8, buffer[0..4], "temp"));
    expect(io_core.close(file) == 0);

    _ = c.remove(scratch);
}

fn theAbstractType() void {
    // The callback set is part of the type's contract: `core/file` has a
    // finalizer, a method getter, a marshal pair and a key walker, and nothing
    // else. A `tostring` in particular would change how every file prints.
    const at = &io_core.fileType;
    expect(std.mem.eql(u8, at.name, "core/file"));
    expect(at.gc != null);
    expect(at.gcmark == null);
    expect(at.get != null);
    expect(at.put == null);
    expect(at.marshal != null);
    expect(at.unmarshal != null);
    expect(at.tostring == null);
    expect(at.compare == null);
    expect(at.hash == null);
    expect(at.next != null);
    expect(at.call == null);
    expect(at.length == null);
    expect(at.bytes == null);
}

/// The method table is scanned linearly and walked in order, so its order is
/// observable through `next` and is part of the contract rather than a
/// tidiness.
fn theMethodOrder() raise.Error!void {
    const at = &io_core.fileType;
    const expected = [_][*:0]const u8{ "close", "flush", "read", "seek", "tell", "write" };

    // `next` and `get` ignore the payload, reading the method table instead,
    // so what is passed here stands in for a file without being one.
    // The runtime cannot: a dispatch starts from a live abstract's header, so
    // the payload is always a real `io.File`. Both the typed callback and the
    // erased slot say so, so the contract supplies one.
    var borrowed: io_core.File = std.mem.zeroes(io_core.File);
    const payload: *anyopaque = &borrowed;

    var key = wrap.fromNil();
    var i: usize = 0;
    while (true) : (i += 1) {
        key = try at.next.?(payload, key);
        if (harness.isType(key, repr.Tag.nil)) break;
        expect(i < expected.len);
        expect(harness.keywordIs(key, expected[i]));
    }
    expect(i == expected.len);

    // The getter accepts only keywords, and only names in the table.
    const out = (try at.get.?(payload, value.fromBytes("read", .keyword))).?;
    expect(harness.isType(out, repr.Tag.cfunction));
    expect((try at.get.?(payload, value.fromBytes("open", .keyword))) == null);
    expect((try at.get.?(payload, value.fromBytes("read", .string))) == null);
}

fn thePublicApi() raise.Error!void {
    const raw = io_core.open(scratch, "wb").?;

    // `io.makejfile` hands back the payload; `io.makefile` wraps it. The
    // buffer size is the C library's default, which is what `file/open`
    // compares against to decide whether a caller asked for another one.
    const jf = io_core.makejfile(@ptrCast(@alignCast(raw)), constants.JANET_FILE_WRITE);
    expect(@as(?*anyopaque, @ptrCast(jf.file)) == @as(?*anyopaque, raw));
    expect(jf.flags == constants.JANET_FILE_WRITE);
    expect(jf.vbufsize == c.BUFSIZ);

    const wrapped = wrap.fromAbstract(jf);
    expect(io_core.checkfile(wrapped) == @as(?*anyopaque, jf));
    expect(io_core.checkfile(wrap.fromNil()) == null);
    expect(io_core.checkfile(harness.wrapInteger(3)) == null);

    var flags: i32 = 0;
    expect(@as(?*anyopaque, @ptrCast(io_core.unwrapfile(wrapped, &flags))) == @as(?*anyopaque, raw));
    expect(flags == constants.JANET_FILE_WRITE);
    expect(@as(?*anyopaque, @ptrCast(io_core.unwrapfile(wrapped, null))) == @as(?*anyopaque, raw));

    // The reporting halves of these two are `capi.zig`'s, which is where a
    // boundary that builds a slice out of an index belongs. What is left takes
    // the slice.
    var argv = [_]repr.Value{wrapped};
    expect(try io_core.getjfile(argv[0..1], 0) == jf);
    flags = 0;
    expect(@as(?*anyopaque, @ptrCast(try io_core.getfile(argv[0..1], 0, &flags))) == @as(?*anyopaque, raw));
    expect(flags == constants.JANET_FILE_WRITE);
    expect(@as(?*anyopaque, @ptrCast(try io_core.getfile(argv[0..1], 0, null))) == @as(?*anyopaque, raw));

    // Closing marks the payload and clears the stream, so a later use is a
    // null dereference rather than a use-after-free. A second close is a
    // no-op, and so is closing a file this runtime only borrowed.
    expect(io_core.fileClose(jf) == 0);
    expect(jf.flags & constants.JANET_FILE_CLOSED != 0);
    expect(jf.file == null);
    expect(io_core.fileClose(jf) == 0);

    const borrowed = io_core.makejfile(
        stdio.out(),
        constants.JANET_FILE_APPEND | constants.JANET_FILE_NOT_CLOSEABLE,
    );
    expect(io_core.fileClose(borrowed) == 0);
    expect(borrowed.flags & constants.JANET_FILE_CLOSED == 0);
    expect(asHandle(borrowed.file) == asHandle(stdio.out()));

    // A value of the wrong type is an argument fault rather than a null. It
    // arrives as an error rather than as a report: neither getter has a
    // reporting half any more.
    var bad = [_]repr.Value{harness.wrapInteger(3)};
    expectRaisePrefix(io_core.getjfile, .{ bad[0..1], @as(i32, 0) }, "bad slot #0");
    expectRaisePrefix(io_core.getfile, .{ bad[0..1], @as(i32, 0), null }, "bad slot #0");

    _ = c.remove(scratch);
}

fn theDynamicFile() void {
    // Outside a fiber the dynamic bindings live in the VM's top-level table,
    // which is what lets this run without one.
    expect(asHandle(io_core.dynfile("io-core-out", stdio.out())) == asHandle(stdio.out()));
    expect(asHandle(io_core.dynfile("io-core-out", null)) == null);

    // Anything that is not a `core/file` falls back to the default, including
    // another abstract type.
    vm_state.setdyn("io-core-out", harness.wrapInteger(3));
    expect(asHandle(io_core.dynfile("io-core-out", stdio.err())) == asHandle(stdio.err()));
    vm_state.setdyn("io-core-out", wrap.fromAbstract(
        abstracts.newFor(math.Rng, &math.rngType),
    ));
    expect(asHandle(io_core.dynfile("io-core-out", stdio.err())) == asHandle(stdio.err()));

    const jf = io_core.makejfile(
        stdio.out(),
        constants.JANET_FILE_APPEND | constants.JANET_FILE_NOT_CLOSEABLE,
    );
    vm_state.setdyn("io-core-out", wrap.fromAbstract(jf));
    expect(asHandle(io_core.dynfile("io-core-out", stdio.err())) == asHandle(stdio.out()));
    vm_state.setdyn("io-core-out", wrap.fromNil());
}

fn marshalled(buffer: *buffers.Buffer, val: repr.Value, flags: c_int) raise.Error!void {
    return marsh.marshal(buffer, val, null, flags);
}

fn unmarshalled(buffer: *buffers.Buffer, flags: c_int) raise.Error!repr.Value {
    return marsh.unmarshal(buffer.slice(), flags, null, null);
}

/// A file marshals only under `JANET_MARSHAL_UNSAFE`, which no Janet caller
/// can ask for, so the whole callback pair is unreachable from the language.
fn theMarshalling() raise.Error!void {
    const raw = io_core.open(scratch, "wb").?;
    const file = wrap.fromAbstract(io_core.makejfile(@ptrCast(@alignCast(raw)), constants.JANET_FILE_WRITE));

    const buffer = buffers.new(0);
    expectRaise(marshalled, .{ buffer, file, @as(c_int, 0) }, "cannot marshal file in safe mode");

    // A marshalled closeable file owns a descriptor of its own, which takes a
    // `dup`. WASI has none, so there the callback raises and the round trip
    // below has nothing to make.
    if (builtin.os.tag == .wasi) {
        buffer.count = 0;
        expectRaise(
            marshalled,
            .{ buffer, file, constants.JANET_MARSHAL_UNSAFE },
            "cannot marshal a closeable file on WASI",
        );
        expect(io_core.fileClose(@ptrCast(@alignCast(io_core.checkfile(file)))) == 0);
        _ = c.remove(scratch);
        return;
    }

    buffer.count = 0;
    try marshalled(buffer, file, constants.JANET_MARSHAL_UNSAFE);
    expect(buffer.count > 0);

    // Reading it back in safe mode is refused by the other half of the pair.
    expectRaise(unmarshalled, .{ buffer, @as(c_int, 0) }, "cannot unmarshal file in safe mode");

    const back = try unmarshalled(buffer, constants.JANET_MARSHAL_UNSAFE);
    const copy = io_core.checkfile(back);
    expect(copy != null);
    const copyf: *io_core.File = @ptrCast(@alignCast(copy));
    expect(copyf.flags == constants.JANET_FILE_WRITE);
    expect(copyf.vbufsize == c.BUFSIZ);

    // The descriptor was duplicated, because the original owns its stream, so
    // the copy is a different stream on the same file and closing one leaves
    // the other usable.
    expect(@as(?*anyopaque, @ptrCast(copyf.file)) != @as(?*anyopaque, raw));
    expect(io_core.fileClose(copyf) == 0);
    expect(io_core.write(raw, "kept", 4) == 1);
    expect(io_core.fileClose(@ptrCast(@alignCast(io_core.checkfile(file)))) == 0);
    _ = c.remove(scratch);
}

/// The recorded buffer size is restored by a real `setvbuf` on the way back
/// in, which is only visible if it is not the default: an unbuffered stream
/// reaches the filesystem with no flush and a buffered one does not.
fn theMarshalledBufferSize() raise.Error!void {
    // The round trip needs a marshalled closeable file, which WASI cannot
    // make; `theMarshalling` is where that is pinned.
    if (builtin.os.tag == .wasi) return;

    const stream = io_core.open(scratch, "wb").?;
    const jf = io_core.makejfile(@ptrCast(@alignCast(stream)), constants.JANET_FILE_WRITE);
    jf.vbufsize = 0;
    const file = wrap.fromAbstract(jf);

    const buffer = buffers.new(0);
    try marshalled(buffer, file, constants.JANET_MARSHAL_UNSAFE);
    const copy = io_core.checkfile(try unmarshalled(buffer, constants.JANET_MARSHAL_UNSAFE));
    expect(copy != null);
    const copyf: *io_core.File = @ptrCast(@alignCast(copy));
    expect(copyf.vbufsize == 0);

    expect(io_core.write(@ptrCast(copyf.file), "now", 3) == 1);
    {
        var seen: [8]u8 = undefined;
        const check = io_core.open(scratch, "rb").?;
        expect(io_core.read(check, &seen, seen.len) == 3);
        expect(std.mem.eql(u8, seen[0..3], "now"));
        expect(io_core.close(check) == 0);
    }
    expect(io_core.fileClose(copyf) == 0);
    expect(io_core.fileClose(jf) == 0);
    _ = c.remove(scratch);
}

/// A descriptor that no longer exists unmarshals as a closed file with no
/// stream. A borrowed file is written with its own descriptor, so closing the
/// stream before the unmarshal is what frees it. The recorded buffer size is
/// not the default, and there is no stream to apply it to.
fn theUnreopenableDescriptor() raise.Error!void {
    // The closed descriptor is what makes `fdopen` fail, and on WASI it does
    // not: wasi-libc's `fdopen` does not ask the host whether the descriptor
    // is open, so the reopened file comes back usable and this path has
    // nothing to report. Measured under wasmtime: the copy came back with the
    // flags it was marshalled with and a stream of its own.
    if (builtin.os.tag == .wasi) return;

    const stream = io_core.open(scratch, "wb").?;
    const jf = io_core.makejfile(
        @ptrCast(@alignCast(stream)),
        constants.JANET_FILE_WRITE | constants.JANET_FILE_NOT_CLOSEABLE,
    );
    jf.vbufsize = 0;
    const buffer = buffers.new(0);
    try marshalled(buffer, wrap.fromAbstract(jf), constants.JANET_MARSHAL_UNSAFE);
    expect(io_core.close(stream) == 0);

    const copy = io_core.checkfile(try unmarshalled(buffer, constants.JANET_MARSHAL_UNSAFE));
    expect(copy != null);
    const copyf: *io_core.File = @ptrCast(@alignCast(copy));
    expect(copyf.flags == constants.JANET_FILE_CLOSED);
    expect(copyf.file == null);
    _ = c.remove(scratch);
}

/// A `io.File`'s flags and its stream can disagree, which nothing in Janet
/// can arrange and which is the only way into two of the failure paths. Both
/// are reachable by an embedder, since `io.makejfile` takes the flag word from
/// its caller and never consults the stream.
fn theMismatchedHandles() void {
    const writer = io_core.open(scratch, "wb").?;
    const claims_readable = wrap.fromAbstract(
        io_core.makejfile(@ptrCast(@alignCast(writer)), constants.JANET_FILE_READ),
    );

    // The readability check passes on the flags and the read then fails, which
    // is the branch that separates a short read from a broken one.
    var read_args = [_]repr.Value{ claims_readable, harness.wrapInteger(10) };
    expectRaise(harness.core("file/read"), .{read_args[0..2]}, "could not read file");
    expect(io_core.fileClose(@ptrCast(@alignCast(io_core.checkfile(claims_readable)))) == 0);

    const reader = io_core.open(scratch, "rb").?;
    const claims_writeable = wrap.fromAbstract(
        io_core.makejfile(@ptrCast(@alignCast(reader)), constants.JANET_FILE_WRITE),
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
    expect(io_core.fileClose(@ptrCast(@alignCast(io_core.checkfile(claims_writeable)))) == 0);

    _ = c.remove(scratch);
}

fn theCoreFunctions() void {
    const env = harness.coreEnv();

    // A file opens, round-trips its contents, and reports positions.
    doString(env,
        \\(def f (file/open "wattle-io-core-public-9d24" :wb))
        \\(file/write f "first line\n" "second")
        \\(assert (= 17 (file/tell f)))
        \\(file/flush f)
        \\(file/close f)
        \\(def f (file/open "wattle-io-core-public-9d24" :rb))
        \\(assert (= "first line\n" (string (file/read f :line))))
        \\(assert (= "second" (string (file/read f :all))))
        \\(assert (nil? (file/read f :line)))
        \\(file/close f)
    );

    // Seeking accepts each origin keyword and rejects anything else.
    doString(env,
        \\(def f (file/open "wattle-io-core-public-9d24" :rb))
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
        \\(def f (file/open "wattle-io-core-public-9d24" :rb))
        \\(assert (= "first line\nsecond" (string (file/read f 100))))
        \\(assert (nil? (file/read f 4)))
        \\(assert (= "" (string (file/read f :all))))
        \\(file/close f)
    );

    // Appending preserves the existing contents; writing truncates.
    doString(env,
        \\(def f (file/open "wattle-io-core-public-9d24" :ab))
        \\(file/write f "!")
        \\(file/close f)
        \\(assert (= "first line\nsecond!" (string (slurp "wattle-io-core-public-9d24"))))
        \\(def f (file/open "wattle-io-core-public-9d24" :wb))
        \\(file/close f)
        \\(assert (= "" (string (slurp "wattle-io-core-public-9d24"))))
    );

    // A closed file rejects every operation, and closing twice is harmless.
    doString(env,
        \\(def f (file/open "wattle-io-core-public-9d24" :rb))
        \\(file/close f)
        \\(assert (nil? (file/close f)))
        \\(assert (not (first (protect (file/read f :all)))))
        \\(assert (not (first (protect (file/write f "x")))))
        \\(assert (not (first (protect (file/tell f)))))
    );

    // A file opened for reading is not writeable, and one opened for writing
    // is not readable, unless the update flag is present.
    doString(env,
        \\(def f (file/open "wattle-io-core-public-9d24" :rb))
        \\(assert (not (first (protect (file/write f "x")))))
        \\(assert (not (first (protect (file/flush f)))))
        \\(file/close f)
        \\(def f (file/open "wattle-io-core-public-9d24" :wb))
        \\(assert (not (first (protect (file/read f :all)))))
        \\(file/close f)
        \\(def f (file/open "wattle-io-core-public-9d24" :w+b))
        \\(file/write f "update")
        \\(file/seek f :set 0)
        \\(assert (= "update" (string (file/read f :all))))
        \\(file/close f)
    );

    // A missing file is nil, or an error when the mode asks for one.
    doString(env,
        \\(assert (nil? (file/open "wattle-io-core-absent-9d24" :r)))
        \\(assert (not (first (protect (file/open "wattle-io-core-absent-9d24" :rn)))))
    );

    // Malformed modes are rejected by position, and each names the byte that
    // stopped the scan.
    doString(env,
        \\(defn why [mode] (last (protect (file/open "wattle-io-core-public-9d24" mode))))
        \\(assert (= "file mode must have a length between 1 and 10" (why (keyword ""))))
        \\(assert (= "file mode must have a length between 1 and 10" (why :rbnbnbnbnbn)))
        \\(assert (= "invalid flag q, expected w, a, or r" (why :q)))
        \\(assert (= "invalid flag +, expected w, a, or r" (why (keyword "+"))))
        \\(assert (= "invalid flag q, expected +, b, or n" (why :rq)))
        \\(assert (= "invalid flag q, expected +, b, or n" (why :r+q)))
        \\# A repeat gets its own message: naming `+` among the flags expected
        \\# while refusing a `+` would be no diagnosis at all.
        \\(assert (= "repeated flag + in file mode" (why :r++)))
        \\(assert (= "repeated flag b in file mode" (why :rbb)))
        \\(assert (= "repeated flag n in file mode" (why :rnn)))
        \\# Across intervening flags, not only next to itself.
        \\(assert (= "repeated flag b in file mode" (why :rbnb)))
    );

    // A repeated flag opens nothing. The -1 the scan reports is not a flag
    // word: every bit set includes `file_closed` and `file_not_closeable`, so
    // the handle would report itself closed, refuse every operation, refuse to
    // be closed, and keep its descriptor past collection. The descriptor count
    // is what says the refusal happens before the open rather than after it.
    //
    // The count is `os/dir` over `/dev/fd`, and `-Dreduced-os=true` registers
    // no `os/dir`, so this case has no instrument there rather than a
    // weaker one. WASI has no `/dev` at all, which leaves it without the
    // instrument for the same reason. The refusal itself is asserted above in
    // every configuration; what is gated is the leak check behind it.
    if (!config.reduced_os and builtin.os.tag != .wasi) {
        doString(env,
            \\(defn nfds [] (length (os/dir "/dev/fd")))
            \\(def before (nfds))
            \\(repeat 50 (protect (file/open "wattle-io-core-public-9d24" :r++)))
            \\(gccollect)
            \\(assert (= before (nfds)))
        );
    }

    // A buffer size does not replace the mode. Reading the mode only at
    // exactly two arguments leaves a three-argument call unscanned and
    // read-only, so `:wb 8192` would neither truncate nor write and `:zzz`
    // would be accepted where the two-argument form refuses it.
    doString(env,
        \\(spit "wattle-io-core-public-9d24" "buffered")
        \\(def f (file/open "wattle-io-core-public-9d24" :wb 8192))
        \\(assert (= :core/file (type f)))
        \\(file/write f "x")
        \\(file/close f)
        \\(assert (= "x" (string (slurp "wattle-io-core-public-9d24"))))
        \\(assert (= "invalid flag z, expected w, a, or r"
        \\           (last (protect (file/open "wattle-io-core-public-9d24" :zzz 0)))))
        \\# The read mode is still the default when no mode is given at all.
        \\(def f (file/open "wattle-io-core-public-9d24"))
        \\(assert (= "x" (string (file/read f :all))))
        \\(file/close f)
    );

    // A write-only file refuses all three reads alike. `:line` reads with
    // `getc` rather than through `readChunk`, so a readability test that lives
    // only in `readChunk` leaves `:line` giving nil, and that nil is
    // `getc` on a stream opened for writing, which is undefined rather than an
    // empty line.
    doString(env,
        \\(def f (file/open "wattle-io-core-public-9d24" :w))
        \\(each form [:all :line 3]
        \\  (assert (= "file is not readable" (last (protect (file/read f form))))))
        \\(file/close f)
    );

    // A closed file has no stream to hand out. `os/isatty` reaches one
    // through `getfile`, which is outside this file's own closed-flag tests,
    // and `fileno` of a null stream has no defined result.
    //
    // `-Dreduced-os=true` registers no `os/isatty`, `boot.janet` substituting
    // a macro that is true where the binding is absent, so the getfile
    // half is gated on the binding being the runtime's. The flusher half below
    // reaches the same closed stream by another route and runs everywhere.
    if (!config.reduced_os) {
        doString(env,
            \\(def f (file/temp))
            \\(file/close f)
            \\(assert (= "file is closed" (last (protect (os/isatty f)))))
        );
    }
    // Flushing through a closed file flushes nothing rather than every stream
    // in the process, which is what `fflush(NULL)` does.
    doString(env,
        \\(def f (file/temp))
        \\(file/close f)
        \\(assert (nil? (with-dyns [:out f] (flush))))
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
        \\(def f (file/open "wattle-io-core-public-9d24" :wb))
        \\(xprint f "printed")
        \\(xprin f "tail")
        \\(xprinf f "%d" 42)
        \\(xprintf f "%d" 7)
        \\(file/close f)
        \\(assert (= "printed\ntail427\n" (string (slurp "wattle-io-core-public-9d24"))))
    );

    // The scratch file is removed by `cleanPaths` rather than by `os/rm`, so
    // this contract still runs in a reduced-OS build.
}

// ==========================================================================
// Entry
// ==========================================================================

pub fn run() void {
    cleanPaths();

    theModeScanning();
    theSeekOrigins();
    theModeReconstruction();
    theStreamOperations();

    harness.init();
    // The abstract type has to be in the registry before anything marshals a
    // file, and the registration is `io.libIo`'s. Building the core
    // environment first is also what the public section needs, and it is
    // memoized, so the two share one.
    _ = harness.coreEnv();

    theAbstractType();
    theMethodOrder() catch @panic("io_core: the method table raised");
    thePublicApi() catch @panic("io_core: the public API raised");
    theDynamicFile();
    theMarshalling() catch @panic("io_core: marshalling raised");
    theMarshalledBufferSize() catch @panic("io_core: the buffer size raised");
    theUnreopenableDescriptor() catch @panic("io_core: an unreopenable descriptor raised");
    theMismatchedHandles();
    theCoreFunctions();

    expect(raises_seen == expected_raises);
    vm_lifecycle.deinit();

    cleanPaths();
    std.debug.print("io_core raises: {d}\n", .{raises_seen});
}
