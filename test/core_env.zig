//! Behavioral contract for the core environment: building it, running source
//! in it, the lookup table the image is unmarshalled against, and the three
//! entry points an embedder reaches that Janet source cannot.
//!
//! `test/suite-corelib.janet` covers the cfunctions, because every one of them
//! has a Janet spelling. What it cannot reach is everything around them:
//!
//!  - `coreEnv`'s `replacements` parameter has no Janet spelling at all.
//!    Nothing in the tree passes it a non-null table, so the substitution it
//!    performs, and the memoization that makes it a one-shot, are reachable
//!    only from inside the runtime.
//!  - `coreLookupTable` is the same table without the unmarshal, and is
//!    reached from `marsh.zig` with a null argument and from nowhere else.
//!  - `env.dobytes` reports a *set of flags* and a value. Janet code sees
//!    neither: `dofile` and the REPL go through `env.dostring`, which drops
//!    the distinction, and the diagnostics go to stderr rather than to a
//!    value. The `len` parameter has no Janet spelling either, `dostring`
//!    computing it, so a stream that stops mid-source is only reachable here.
//!  - `loopFiber` is called by `interop.zig` and by no Janet code.
//!  - `env.zig`'s `native` is behind `(native ...)`, which needs a shared
//!    object on disk to say anything at all. Its failure paths do not.
//!
//! The diagnostics are captured rather than printed. `pp_format.dynprintf`
//! resolves `:err` before falling back to the handle, and at the top level,
//! which is where `dobytes` prints its diagnostics from once the fiber has
//! finished, that lookup goes to `vm.top_dyns`. So binding `:err` to a buffer
//! here both asserts the text and keeps this program's output clean.
//!
//! ## How the subjects are reached
//!
//! Four entry points are called by import rather than through their abis.
//! `coreEnv`, `coreLookupTable`, `dobytes` and `loopFiber` each have a
//! `raise.toAbi` wrapper over a `raise.Raising` implementation, and every one
//! of them can raise. Called directly, a raise is an `error.JanetSignal` the
//! compiler will not let this file ignore.
//!
//! The native loader is called as an abi instead, with `harness.abiRaised`.
//! Its implementation is private and `cfunNative` calls that directly, so the
//! abi has no in-tree caller and exists for an embedder alone, which makes an
//! abi the right thing to test.
//!
//! A refusal is a value here: every one is `harness.abiRaised(...).?`, and the
//! unwrap of a null fails at the site that expected it.

// ==========================================================================
// Standard library imports
// ==========================================================================

const builtin = @import("builtin");
const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const buffers = @import("subsystems").value.buffers;
const c = @import("cabi");
const config = @import("config");
const constants = @import("constants");
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const fibers = @import("subsystems").value.fibers;
const fingerprint = @import("subsystems").fingerprint;
const gc_alloc = @import("subsystems").gc_alloc;
const harness = @import("harness.zig");
const io_core = @import("subsystems").io;
const marsh = @import("subsystems").marsh;
const raise = @import("subsystems").raise;
const repr = @import("repr");
const strings = @import("subsystems").value.strings;
const tables = @import("subsystems").value.tables;
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const vm_state = @import("subsystems").vm_state;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

var errsink: *buffers.Buffer = undefined;

const replacement_key = raise.stored(&replacedGcinterval);

var test_env: *tables.Table = undefined;

// ==========================================================================
// Cases
// ==========================================================================

fn errReset() void {
    errsink.count = 0;
}

fn errText() []const u8 {
    return errsink.slice();
}

fn expectErr(expected: []const u8) void {
    const got = errText();
    if (!std.mem.eql(u8, got, expected)) {
        std.debug.print("expected stderr: {s}\n            got: {s}\n", .{ expected, got });
        @panic("diagnostic mismatch");
    }
}

fn expectErrPrefix(prefix: []const u8) void {
    const got = errText();
    if (!std.mem.startsWith(u8, got, prefix)) {
        std.debug.print("expected stderr prefix: {s}\n                   got: {s}\n", .{ prefix, got });
        @panic("diagnostic prefix mismatch");
    }
}

fn expectString(x: repr.Value, expected: []const u8) void {
    expect(harness.isType(x, repr.Tag.string));
    const s = wrap.toString(x);
    const length: usize = strings.head(s).length;
    if (!std.mem.eql(u8, s[0..length], expected)) {
        std.debug.print("expected value: {s}\n           got: {s}\n", .{ expected, s[0..length] });
        @panic("value mismatch");
    }
}

/// `dostring`'s shape over `dobytesImpl`: the source is NUL-terminated, so the
/// length is computed the way `dostring` computes it.
fn doString(source: [:0]const u8, path: ?[*:0]const u8, out: ?*repr.Value) raise.Raising(c_int) {
    return core_env.dobytesImpl(test_env, source, path, out);
}

//
// `gcinterval` is the substitution target because nothing in `boot.janet`
// calls it while the image is loading, so replacing it cannot affect anything
// but the one call this file makes.

fn replacedGcinterval(argv: []repr.Value) raise.Raising(repr.Value) {
    _ = @as(i32, @intCast(argv.len));

    return value.fromBytes("replaced", .keyword);
}

fn aCleanRunReportsNoFlags() raise.Raising(void) {
    var out = wrap.fromTrue();
    errReset();
    expect(try doString("(+ 1 2)", "contract", &out) == 0);
    expect(harness.isType(out, repr.Tag.number));
    expect(wrap.toNumber(out) == 3.0);
    expectErr("");

    // The value is the last form's, not the first's.
    expect(try doString("(+ 1 2) (+ 3 4)", "contract", &out) == 0);
    expect(wrap.toNumber(out) == 7.0);

    // An empty source runs nothing and gives nil.
    expect(try doString("", "contract", &out) == 0);
    expect(harness.isType(out, repr.Tag.nil));

    // The out parameter is optional.
    expect(try doString("(+ 1 2)", "contract", null) == 0);
    expectErr("");
}

fn theLengthParameterTruncatesTheSource() raise.Raising(void) {
    var out = wrap.fromNil();
    errReset();
    // Seven bytes is exactly the first form; the second is never seen.
    expect(try core_env.dobytesImpl(test_env, "(+ 1 2) (+ 3 4)"[0..7], "contract", &out) == 0);
    expect(wrap.toNumber(out) == 3.0);
    expectErr("");

    // Cutting a form in half is an EOF in the middle of it, which is a parse
    // error rather than a silent truncation.
    expect(try core_env.dobytesImpl(test_env, "(+ 1 2)"[0..5], "contract", &out) ==
        constants.JANET_DO_ERROR_PARSE);

    // The bound is exclusive. `dostring` always passes a length that stops on
    // a NUL, so only a caller of `dobytes` can tell an off-by-one here from
    // correct behaviour: reading one byte too many turns
    // 1 into 12.
    expect(try core_env.dobytesImpl(test_env, "12"[0..1], "contract", &out) == 0);
    expect(wrap.toNumber(out) == 1.0);

    // And the export does compute that length, which is the one thing it adds.
    // It is an abi, so it is called as one.
    expect(core_env.dostring(test_env, "12", "contract", &out) == 0);
    expect(wrap.toNumber(out) == 12.0);
}

/// Every failure sets `done`, whatever kind it was. The runtime case is below;
/// these are the other two, and each needs a second form after the failing one
/// to have anything to observe.
fn aParseOrCompileFailureStopsTheStream() raise.Raising(void) {
    var out = wrap.fromNil();
    const env = tables.new(4);
    env.proto = test_env;

    errReset();
    var flags = try core_env.dobytesImpl(
        env,
        ")\n(setdyn :contract-parse true)",
        "contract",
        &out,
    );
    expect(flags == constants.JANET_DO_ERROR_PARSE);
    expect(harness.isType(tables.get(env, value.fromBytes("contract-parse", .keyword)), repr.Tag.nil));

    errReset();
    flags = try core_env.dobytesImpl(
        env,
        "(def)\n(setdyn :contract-compile true)",
        "contract",
        &out,
    );
    expect(flags == constants.JANET_DO_ERROR_COMPILE);
    expect(harness.isType(tables.get(env, value.fromBytes("contract-compile", .keyword)), repr.Tag.nil));
}

/// A compile error reports the *form's* position when the compiler supplies
/// one and the parser's otherwise, and the two only differ once the source has
/// more than one line in it.
fn aCompileErrorPrefersTheSourceMapping() raise.Raising(void) {
    var out = wrap.fromNil();
    errReset();
    // The parser has consumed three lines by the time the second form fails,
    // so a position of 2 can only have come from the source mapping.
    expect(try doString("(+ 1 2)\n(def)\n", "contract", &out) == constants.JANET_DO_ERROR_COMPILE);
    expectErrPrefix("contract:2:1: compile error: ");

    // A mapping is used only when both its line and its column are positive.
    // `tuple/setmap` gives a form any mapping, and the compiler takes any whose
    // line is not negative, so a zero at either end reaches this choice and
    // the parser's position is reported instead.
    const macro = "(defmacro contract-mapped [l c] (tuple/setmap (tuple 'def) l c))\n";
    errReset();
    expect(try doString(macro ++ "(contract-mapped 0 5)", "contract", &out) == constants.JANET_DO_ERROR_COMPILE);
    expectErrPrefix("contract:2:21: compile error: ");
    errReset();
    expect(try doString(macro ++ "(contract-mapped 5 0)", "contract", &out) == constants.JANET_DO_ERROR_COMPILE);
    expectErrPrefix("contract:2:21: compile error: ");
}

fn aParseErrorNamesAPosition() raise.Raising(void) {
    var out = wrap.fromNil();
    errReset();
    expect(try doString("(+ 1 2))", "contract", &out) == constants.JANET_DO_ERROR_PARSE);
    expectString(out, "contract:1:8: parse error: unexpected closing delimiter )");
    expectErr("contract:1:8: parse error: unexpected closing delimiter )\n");
}

fn aCompileErrorNamesAPosition() raise.Raising(void) {
    var out = wrap.fromNil();
    errReset();
    expect(try doString("(def)", "contract", &out) == constants.JANET_DO_ERROR_COMPILE);
    expect(harness.isType(out, repr.Tag.string));
    const text = wrap.toString(out);
    const length: usize = strings.head(text).length;
    expect(std.mem.startsWith(u8, text[0..length], "contract:1:1: compile error: "));
    expectErrPrefix("contract:1:1: compile error: ");
}

/// A macro that raises during expansion leaves a fiber behind, and that branch
/// follows the message with a stack trace where the ordinary branch does not.
///
/// Both branches print the same one line, and the context appears once.
/// The trace renders the same string the line does, so printing the context
/// here as well would print it twice; printing it with no separator would run
/// it straight into the trace's own `error: `.
fn aMacroExpansionErrorPrintsATrace() raise.Raising(void) {
    var out = wrap.fromNil();
    errReset();
    expect(try doString(
        "(defmacro contract-boom [] (error :expansion)) (contract-boom)",
        "contract",
        &out,
    ) == constants.JANET_DO_ERROR_COMPILE);
    expectErrPrefix("contract:1:48: compile error: ");
    expect(std.mem.indexOf(u8, errText(), "expansion") != null);
    expect(std.mem.indexOf(u8, errText(), "\n  in contract-boom ") != null);
    // The context appears once, not twice, and the trace begins on its own
    // line rather than against the end of it.
    expect(std.mem.indexOf(u8, errText(), "compile errorerror:") == null);
    expect(std.mem.indexOf(
        u8,
        errText(),
        "compile error: (macro) expansion\nerror: ",
    ) != null);
}

fn aRuntimeErrorReportsTheValue() raise.Raising(void) {
    var out = wrap.fromNil();
    errReset();
    expect(try doString("(error :thrown)", "contract", &out) == constants.JANET_DO_ERROR_RUNTIME);
    expect(harness.isType(out, repr.Tag.keyword));
    expect(harness.stringIs(wrap.toKeyword(out), "thrown"));
    expectErrPrefix("error: thrown\n  in thunk [contract] ");
}

/// Every failure sets `done`, so the flag word only ever has one bit set and
/// the forms after the failing one never run.
fn aFailureStopsTheStream() raise.Raising(void) {
    var out = wrap.fromNil();
    errReset();
    const env = tables.new(4);
    env.proto = test_env;
    const source = "(error :stop) (setdyn :contract-ran true)";
    const flags = try core_env.dobytesImpl(env, source[0..@intCast(source.len)], "contract", &out);
    expect(flags == constants.JANET_DO_ERROR_RUNTIME);
    expect(flags == (flags & -flags));
    expect(harness.isType(tables.get(env, value.fromBytes("contract-ran", .keyword)), repr.Tag.nil));
}

fn aNullSourcePathIsNamedUnknown() raise.Raising(void) {
    var out = wrap.fromNil();
    errReset();
    expect(try doString("(+ 1 2))", null, &out) == constants.JANET_DO_ERROR_PARSE);
    expectString(out, "<unknown>:1:8: parse error: unexpected closing delimiter )");
}

fn loopFiberReportsAStatus() raise.Raising(void) {
    var out = wrap.fromNil();
    errReset();
    expect(try doString("(fiber/new (fn [] 42))", "contract", &out) == 0);
    expect(harness.isType(out, repr.Tag.fiber));
    expect(try core_env.loopFiber(wrap.toFiber(out)) == @intFromEnum(fibers.FiberStatus.dead));

    expect(try doString("(fiber/new (fn [] (error :in-fiber)))", "contract", &out) == 0);
    errReset();
    expect(try core_env.loopFiber(wrap.toFiber(out)) == @intFromEnum(fibers.FiberStatus.@"error"));
}

/// The image is `@embedFile`d, and this unmarshals it against the same length
/// the runtime uses and asks where the stream stopped.
///
/// The two numbers agreeing is the assertion. A generated image with a
/// terminator byte on the end, or a length taken from an array's size rather
/// than from the stream, would leave slack that nothing else here would
/// notice, since nothing reads past the last value.
fn theImageIsConsumedExactly() raise.Raising(void) {
    const image = core_env.core_image;
    var next: [*]const u8 = undefined;
    const out = try marsh.unmarshal(image[0..@intCast(image.len)], 0, try core_env.coreLookupTable(null), &next);
    expect(harness.isType(out, repr.Tag.table));
    expect(@intFromPtr(next) == @intFromPtr(image) + image.len);
}

fn theLookupTableIsKeyedBySymbol() raise.Raising(void) {
    const dict = try core_env.coreLookupTable(null);
    expect(harness.isType(tables.get(dict, value.fromBytes("gcinterval", .symbol)), repr.Tag.cfunction));
    // A keyword of the same name is not the key.
    expect(harness.isType(tables.get(dict, value.fromBytes("gcinterval", .keyword)), repr.Tag.nil));
    // Every `loadLibs` entry the configuration has is in it, not only
    // corelib's.
    expect(harness.isType(tables.get(dict, value.fromBytes("string/slice", .symbol)), repr.Tag.cfunction));
    expect(harness.isType(tables.get(dict, value.fromBytes("marshal", .symbol)), repr.Tag.cfunction));
    // `peg/match` is registered only when the engine is compiled, and the
    // question to ask is the environment rather than `options`: what is missing
    // under `-Dpeg=false` is a registration.
    if (harness.coreOptional("peg/match") != null) {
        expect(harness.isType(tables.get(dict, value.fromBytes("peg/match", .symbol)), repr.Tag.cfunction));
    }
}

fn theLookupTableTakesReplacements() raise.Raising(void) {
    const replacements = tables.new(2);
    tables.put(
        replacements,
        value.fromBytes("gcinterval", .symbol),
        wrap.fromCfunction(replacement_key),
    );
    tables.put(replacements, value.fromBytes("contract/added", .symbol), value.fromBytes("added", .keyword));

    const dict = try core_env.coreLookupTable(replacements);
    expect(wrap.toCfunction(
        tables.get(dict, value.fromBytes("gcinterval", .symbol)),
    ) == replacement_key);
    // A key the core does not define is added rather than rejected.
    expect(harness.isType(tables.get(dict, value.fromBytes("contract/added", .symbol)), repr.Tag.keyword));
    // A nil-keyed slot in the replacement table's storage is skipped, which is
    // what the walk over `capacity` rather than `count` is for.
    expect(dict.count > replacements.count);
}

//
// `(getline)` reads through `(dyn :in)` and writes its prompt through
// `(dyn :out)`, both of which `io.dynfile` resolves and both of which fall
// back to the process handles. The Janet suites cannot bind either without a
// file to bind it to, and cannot assert what was read without controlling what
// is on the other end, so the whole cfunction is exercised here.

fn getlineReadsALineThroughTheDyn() raise.Raising(void) {
    // Two handles, not one. Interleaving reads and writes on a single `FILE *`
    // without a seek between them is undefined, and `(getline)` does exactly
    // that when `:in` and `:out` name the same file.
    const in = io_core.temp();
    const out_file = io_core.temp();
    expect(in != null and out_file != null);
    _ = c.fputs("first line\nsecond", in);
    _ = c.fflush(in);
    c.rewind(in);

    const in_handle = io_core.makefile(in, constants.JANET_FILE_READ | constants.JANET_FILE_WRITE);
    const out_handle = io_core.makefile(out_file, constants.JANET_FILE_WRITE);
    gc_alloc.gcroot(in_handle);
    gc_alloc.gcroot(out_handle);
    // Into the environment table rather than through `vm_state.setdyn`. A
    // dynamic binding is fiber-local, `dobytes` gives each form a fiber whose
    // env is this table, and `setdyn` at the top level, where there is no
    // fiber, writes to `vm.top_dyns` instead, which the cfunction
    // never looks at. That split is why `:err` above is set the other way:
    // those diagnostics are printed after the fiber has finished.
    tables.put(test_env, value.fromBytes("in", .keyword), in_handle);
    tables.put(test_env, value.fromBytes("out", .keyword), out_handle);

    var result = wrap.fromNil();
    // The newline is part of what is returned.
    expect(try doString("(getline)", "contract", &result) == 0);
    expect(harness.isType(result, repr.Tag.buffer));
    {
        const b = wrap.toBuffer(result);
        expect(b.count == 11);
        expect(std.mem.eql(u8, b.slice()[0..11], "first line\n"));
    }

    // A supplied buffer is reused: the same object comes back rather than a
    // copy, and its previous contents are dropped. The last line has no
    // newline, so this also covers the EOF exit.
    expect(try doString(
        "(let [b @\"seed\"] [(= b (getline \"P>\" b)) b])",
        "contract",
        &result,
    ) == 0);
    {
        const pair = wrap.toTuple(result);
        const b = wrap.toBuffer(pair[1]);
        expect(repr.truthy(pair[0]));
        expect(b.count == 6);
        expect(std.mem.eql(u8, b.slice()[0..6], "second"));
    }

    // At EOF it gives an empty buffer rather than failing.
    expect(try doString("(getline)", "contract", &result) == 0);
    expect(wrap.toBuffer(result).count == 0);

    // A one-argument call writes its prompt too: the prompt is guarded by
    // `argc >= 1` and the buffer by `argc >= 2`, and only a call with exactly
    // one argument tells the two guards apart.
    expect(try doString("(getline \"Q>\")", "contract", &result) == 0);
    expect(harness.isType(result, repr.Tag.buffer));

    // Both prompts went to `(dyn :out)`, in order, and nothing else did.
    _ = c.fflush(out_file);
    c.rewind(out_file);
    {
        var written: [8]u8 = @splat(0);
        expect(c.fread(&written, 1, written.len - 1, out_file) == 4);
        expect(std.mem.eql(u8, written[0..4], "P>Q>"));
    }

    // A zero byte is data, not a terminator: the read stops at a newline or at
    // end of file and at nothing else.
    {
        const nul = io_core.temp();
        expect(nul != null);
        _ = c.fwrite("a\x00b\n", 1, 4, nul);
        _ = c.fflush(nul);
        c.rewind(nul);
        const nul_handle = io_core.makefile(nul, constants.JANET_FILE_READ | constants.JANET_FILE_WRITE);
        gc_alloc.gcroot(nul_handle);
        tables.put(test_env, value.fromBytes("in", .keyword), nul_handle);
        expect(try doString("(getline)", "contract", &result) == 0);
        const b = wrap.toBuffer(result);
        expect(b.count == 4);
        expect(std.mem.eql(u8, b.slice()[0..4], "a\x00b\n"));
        tables.put(test_env, value.fromBytes("in", .keyword), in_handle);
        _ = gc_alloc.gcunroot(nul_handle);
    }

    // A read that fails short of the end of the stream stops the line too. A
    // stream open only for writing fails every read with its error indicator
    // set and its end-of-file indicator clear.
    {
        // `/dev/null` is the write-only stream everywhere there is one. WASI
        // has no device files, so there this contract writes its own and
        // unlinks it, the file staying open behind the name for as long as the
        // handle does.
        const write_only_path = "janet-zig-core-env-write-only";
        const write_only = if (builtin.os.tag == .wasi)
            c.fopen(write_only_path, "w")
        else
            c.fopen("/dev/null", "w");
        expect(write_only != null);
        if (builtin.os.tag == .wasi) expect(c.unlink(write_only_path) == 0);
        const write_only_handle = io_core.makefile(write_only, constants.JANET_FILE_WRITE);
        gc_alloc.gcroot(write_only_handle);
        tables.put(test_env, value.fromBytes("in", .keyword), write_only_handle);
        expect(try doString("(getline)", "contract", &result) == 0);
        expect(wrap.toBuffer(result).count == 0);
        tables.put(test_env, value.fromBytes("in", .keyword), in_handle);
        _ = gc_alloc.gcunroot(write_only_handle);
    }

    // The third parameter is part of the interface rather than of this
    // implementation: a client that reads lines with completion binds its own
    // `getline` over this one and honours the env, and the core reader accepts
    // the argument and ignores it.
    c.rewind(in);
    expect(try doString("(getline \"\" @\"\" :not-a-table)", "contract", &result) == 0);
    expect(wrap.toBuffer(result).count == 11);
    // A fourth is a plain arity error.
    errReset();
    expect(try doString("(getline \"\" @\"\" :a :b)", "contract", &result) ==
        constants.JANET_DO_ERROR_RUNTIME);

    tables.put(test_env, value.fromBytes("in", .keyword), wrap.fromNil());
    tables.put(test_env, value.fromBytes("out", .keyword), wrap.fromNil());
    _ = gc_alloc.gcunroot(in_handle);
    _ = gc_alloc.gcunroot(out_handle);
}

/// `janet/config-bits` is janet.h's `JANET_CURRENT_CONFIG_BITS`, which a
/// module and the runtime compare at load. janet.h's bits are 0x1 for a
/// NaN-boxed value, 0x2 for a single-threaded build, and `0x4 << shift` for a
/// 64-bit NaN box whose pointers are shifted. A NaN-boxed value is eight bytes
/// and the tagged one sixteen, so the layout says which this build has.
fn theConfigBitsAreJanetHs() raise.Raising(void) {
    const nanboxed = @sizeOf(repr.Value) == 8;
    const shift: u5 = @intCast(config.nanbox_pointer_shift);
    const shifted = nanboxed and @sizeOf(usize) == 8 and shift != 0;
    const want: i32 = (if (nanboxed) 0x1 else 0) |
        (if (config.single_threaded) 0x2 else 0) |
        (if (shifted) @as(i32, 0x4) << shift else 0);
    var out = wrap.fromNil();
    expect(try doString("janet/config-bits", "contract", &out) == 0);
    expect(wrap.toNumber(out) == @as(f64, @floatFromInt(want)));
}

/// `janet/api` is `api/fingerprint.zig`'s number, spelled as sixteen
/// lowercase hexadecimal digits. A module and the runtime compare the number
/// at load, and the binding is how a Janet program reads the runtime's own.
///
/// The oracle reads the number back out of the digits rather than spelling
/// the number again, so the two sides of the comparison are the text and the
/// number and not one function called twice.
fn theApiVersionIsTheFingerprint() raise.Raising(void) {
    var out = wrap.fromNil();
    expect(try doString("janet/api", "contract", &out) == 0);
    expect(harness.isType(out, repr.Tag.string));
    const spelled = wrap.toString(out);
    const digits = spelled[0..strings.head(spelled).length];
    expect(digits.len == 16);
    for (digits) |ch| expect((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'));
    expect((std.fmt.parseInt(u64, digits, 16) catch unreachable) == fingerprint.api);
}

fn nativeReportsALoaderError() void {
    var err: ?strings.String = null;
    const init = core_env.nativeAbi("./contract-no-such-module.so", &err);
    expect(init == null);
    expect(err != null);
    expect(strings.head(err.?).length > 0);
}

/// Every capability `(sandbox ...)` applies is permanent for the VM, so this
/// runs last and the suites cannot run it at all. What it pins is that the
/// argument walk visits every argument and accumulates a flag per capability,
/// which is invisible from Janet, there being no way to read the flag word
/// back.
fn sandboxAccumulatesEveryCapability() raise.Raising(void) {
    var out = wrap.fromNil();
    expect(!harness.vm().sandbox_flags.intersects(vm_lifecycle.Sandbox.of(&.{"hrtime"})));
    expect(!harness.vm().sandbox_flags.intersects(vm_lifecycle.Sandbox.of(&.{"threads"})));

    // No arguments changes nothing.
    var before = harness.vm().sandbox_flags;
    expect(try doString("(sandbox)", "contract", &out) == 0);
    expect(harness.vm().sandbox_flags == before);

    // Two capabilities in one call set two bits, which is what the walk over
    // `argc` is for; a repeat is idempotent.
    expect(try doString("(sandbox :hrtime :threads :hrtime)", "contract", &out) == 0);
    expect(harness.vm().sandbox_flags.intersects(vm_lifecycle.Sandbox.of(&.{"hrtime"})));
    expect(harness.vm().sandbox_flags.intersects(vm_lifecycle.Sandbox.of(&.{"threads"})));

    // An unknown capability rejects the whole call, including the ones before
    // it in the same argument list.
    before = harness.vm().sandbox_flags;
    expect(try doString("(sandbox :env :nope)", "contract", &out) == constants.JANET_DO_ERROR_RUNTIME);
    expect(harness.vm().sandbox_flags == before);
    expect(!harness.vm().sandbox_flags.intersects(vm_lifecycle.Sandbox.of(&.{"env"})));
}

/// Irreversible, so it goes last.
fn nativeIsBehindTheSandbox() void {
    var err: ?strings.String = null;
    vm_lifecycle.sandbox(vm_lifecycle.Sandbox.of(&.{"dynamic_modules"})) catch @panic("core_env: janet_sandbox raised");
    const refusal = harness.abiRaised(
        core_env.nativeAbi,
        .{ @as([*:0]const u8, "./contract-no-such-module.so"), &err },
    ).?;
    expect(refusal.signal == abi.Signal.@"error");
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() raise.Raising(void) {
    // `coreEnv` memoizes into `vm.core_env`, so the replacement table
    // has to arrive on the very first call or it is ignored. That one-shot is
    // itself the contract below.
    const replacements = tables.new(2);
    tables.put(
        replacements,
        value.fromBytes("gcinterval", .symbol),
        wrap.fromCfunction(replacement_key),
    );
    test_env = try core_env.coreEnv(replacements);
    gc_alloc.gcroot(wrap.fromTable(test_env));

    errsink = buffers.new(256);
    gc_alloc.gcroot(wrap.fromBuffer(errsink));
    vm_state.setdyn("err", wrap.fromBuffer(errsink));

    // The substitution reached the unmarshalled environment: the image refers
    // to a core cfunction by name through the lookup table, so replacing the
    // name replaces the binding.
    {
        var out = wrap.fromNil();
        expect(try doString("(gcinterval)", "contract", &out) == 0);
        expect(harness.isType(out, repr.Tag.keyword));
        expect(harness.stringIs(wrap.toKeyword(out), "replaced"));
    }

    // And the second call ignores both its argument and the work.
    {
        const again = tables.new(1);
        tables.put(again, value.fromBytes("gcinterval", .symbol), wrap.fromNil());
        expect(try core_env.coreEnv(again) == test_env);
        expect(try core_env.coreEnv(null) == test_env);
    }

    try aCleanRunReportsNoFlags();
    try theLengthParameterTruncatesTheSource();
    try aParseOrCompileFailureStopsTheStream();
    try aCompileErrorPrefersTheSourceMapping();
    try aParseErrorNamesAPosition();
    try aCompileErrorNamesAPosition();
    try aMacroExpansionErrorPrintsATrace();
    try aRuntimeErrorReportsTheValue();
    try aFailureStopsTheStream();
    try aNullSourcePathIsNamedUnknown();
    try loopFiberReportsAStatus();
    try theImageIsConsumedExactly();
    try theLookupTableIsKeyedBySymbol();
    try theLookupTableTakesReplacements();
    try getlineReadsALineThroughTheDyn();
    try theConfigBitsAreJanetHs();
    try theApiVersionIsTheFingerprint();
    nativeReportsALoaderError();
    try sandboxAccumulatesEveryCapability();
    nativeIsBehindTheSandbox();
}

pub fn run() void {
    harness.init();
    body() catch @panic("core_env: an entry point raised unexpectedly");
    vm_lifecycle.deinit();
}
