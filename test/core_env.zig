//! Behavioral contract for the core environment: building it, running source
//! in it, the lookup table the image is unmarshalled against, and the three
//! entry points an embedder reaches that Janet source cannot.
//!
//! `test/suite-corelib.janet` covers the cfunctions, because every one of them
//! has a Janet spelling. What it cannot reach is everything around them:
//!
//!  - `coreEnv`'s `replacements` parameter has no Janet spelling at all.
//!    Nothing in the tree passes it a non-null table, so the substitution it
//!    performs — and the memoization that makes it a one-shot — are reachable
//!    only from inside the runtime.
//!  - `coreLookupTable` is the same table without the unmarshal, and is
//!    reached from `marsh.zig` with a null argument and from nowhere else.
//!  - `janet_dobytes` reports a *set of flags* and a value. Janet code sees
//!    neither: `dofile` and the REPL go through `janet_dostring`, which drops
//!    the distinction, and the diagnostics go to stderr rather than to a
//!    value. The `len` parameter has no Janet spelling either — `janet_dostring`
//!    computes it — so a stream that stops mid-source is only reachable here.
//!  - `loopFiber` is called by `interop.zig` and by no Janet code.
//!  - `janet_native` is behind `(native ...)`, which needs a shared object on
//!    disk to say anything at all. Its failure paths do not.
//!
//! The diagnostics are captured rather than printed. `janet_dynprintf`
//! resolves `:err` before falling back to the handle, and at the top level —
//! which is where `janet_dobytes` prints its diagnostics from, after the fiber
//! has finished — that lookup goes to `vm.top_dyns`. So binding `:err`
//! to a buffer here both asserts the text and keeps this program's output
//! clean.
//!
//! ## How the subjects are reached
//!
//! **Four entry points are called by import rather than through their abis.**
//! `janet_core_env`, `janet_core_lookup_table`, `janet_dobytes` and
//! `janet_loop_fiber` are each one line of `raise.reported` over a
//! `raise.Raising` implementation. Every one of them can raise, so a contract
//! on the far side of a symbol table has to arm a flag to see it, where here
//! it is an `error.JanetSignal` the compiler will not let the file ignore.
//!
//! **`janet_native` is still called as an abi**, with `harness.abiRaised`, and
//! that is deliberate: its implementation is private and `cfunNative` calls it
//! directly, so the abi has no in-tree caller and exists for an embedder
//! alone. Testing an abi as an abi is the right shape for a thing whose only
//! users are outside the tree.
//!
//! **No panic counter.** Every refusal is `harness.abiRaised(...).?`, and the
//! unwrap of a null is the same failure a counter would produce.
//!
//! **No adapter pool.** A cfunction is a Zig function, so C cannot define one
//! at all; `replacedGcinterval` below is an ordinary declaration.

const std = @import("std");
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const corefn = @import("corefn");
const harness = @import("harness.zig");
const value = @import("subsystems").value;

const core_env = @import("subsystems").env;
const marsh = @import("subsystems").marsh;
const tables = @import("subsystems").value.tables;
const gc_alloc = @import("subsystems").gc_alloc;
const vm_state = @import("subsystems").lifecycle;
const io_core = @import("subsystems").io;
const wrap = @import("subsystems").value.wrap;
const buffers = @import("subsystems").value.buffers;

const assert = std.debug.assert;

var test_env: *types.JanetTable = undefined;
var errsink: *types.JanetBuffer = undefined;

// ------------------------------------------------------- captured stderr

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
    assert(harness.isType(x, repr.Tag.string));
    const s = wrap.toString(x);
    const length: usize = @intCast(types.stringHead(s).length);
    if (!std.mem.eql(u8, s[0..length], expected)) {
        std.debug.print("expected value: {s}\n           got: {s}\n", .{ expected, s[0..length] });
        @panic("value mismatch");
    }
}

/// `janet_dostring` on the implementation rather than the abi: the source is
/// NUL-terminated, so the length is computed the way the export computes it.
fn doString(source: [:0]const u8, path: ?[*:0]const u8, out: ?*repr.Value) raise.Raising(c_int) {
    return core_env.dobytesImpl(test_env, source, path, out);
}

// ----------------------------------------------------- the replacement cfun
//
// `gcinterval` is the substitution target because nothing in `boot.janet`
// calls it while the image is loading, so replacing it cannot affect anything
// but the one call this file makes.

fn replacedGcinterval(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    _ = @as(i32, @intCast(argv.len));

    return value.fromBytes("replaced", .keyword);
}

const replacement_key = raise.stored(&replacedGcinterval);

// ---------------------------------------------------------- the flag words

fn aCleanRunReportsNoFlags() raise.Raising(void) {
    var out = wrap.fromTrue();
    errReset();
    assert(try doString("(+ 1 2)", "contract", &out) == 0);
    assert(harness.isType(out, repr.Tag.number));
    assert(wrap.toNumber(out) == 3.0);
    expectErr("");

    // The value is the last form's, not the first's.
    assert(try doString("(+ 1 2) (+ 3 4)", "contract", &out) == 0);
    assert(wrap.toNumber(out) == 7.0);

    // An empty source runs nothing and answers nil.
    assert(try doString("", "contract", &out) == 0);
    assert(harness.isType(out, repr.Tag.nil));

    // The out parameter is optional.
    assert(try doString("(+ 1 2)", "contract", null) == 0);
    expectErr("");
}

fn theLengthParameterTruncatesTheSource() raise.Raising(void) {
    var out = wrap.fromNil();
    errReset();
    // Seven bytes is exactly the first form; the second is never seen.
    assert(try core_env.dobytesImpl(test_env, "(+ 1 2) (+ 3 4)"[0..7], "contract", &out) == 0);
    assert(wrap.toNumber(out) == 3.0);
    expectErr("");

    // Cutting a form in half is an EOF in the middle of it, which is a parse
    // error rather than a silent truncation.
    assert(try core_env.dobytesImpl(test_env, "(+ 1 2)"[0..5], "contract", &out) ==
        constants.JANET_DO_ERROR_PARSE);

    // The bound is exclusive. `janet_dostring` always passes a length that
    // stops on a NUL, so only a caller of `janet_dobytes` can tell an
    // off-by-one here from correct behaviour: reading one byte too many turns
    // 1 into 12.
    assert(try core_env.dobytesImpl(test_env, "12"[0..1], "contract", &out) == 0);
    assert(wrap.toNumber(out) == 1.0);

    // And the export does compute that length, which is the one thing it adds.
    // It is an abi, so it is called as one.
    assert(core_env.dostring(test_env, "12", "contract", &out) == 0);
    assert(wrap.toNumber(out) == 12.0);
}

/// Every failure sets `done`, whatever kind it was. The runtime case is below;
/// these are the other two, and each needs a second form after the failing one
/// to have anything to observe.
fn aParseOrCompileFailureStopsTheStream() raise.Raising(void) {
    var out = wrap.fromNil();
    const env = tables.new(4);
    env.*.proto = test_env;

    errReset();
    var flags = try core_env.dobytesImpl(
        env,
        ")\n(setdyn :contract-parse true)",
        "contract",
        &out,
    );
    assert(flags == constants.JANET_DO_ERROR_PARSE);
    assert(harness.isType(tables.get(env, value.fromBytes("contract-parse", .keyword)), repr.Tag.nil));

    errReset();
    flags = try core_env.dobytesImpl(
        env,
        "(def)\n(setdyn :contract-compile true)",
        "contract",
        &out,
    );
    assert(flags == constants.JANET_DO_ERROR_COMPILE);
    assert(harness.isType(tables.get(env, value.fromBytes("contract-compile", .keyword)), repr.Tag.nil));
}

/// A compile error reports the *form's* position when the compiler supplies
/// one and the parser's otherwise, and the two only differ once the source has
/// more than one line in it.
fn aCompileErrorPrefersTheSourceMapping() raise.Raising(void) {
    var out = wrap.fromNil();
    errReset();
    // The parser has consumed three lines by the time the second form fails,
    // so a position of 2 can only have come from the source mapping.
    assert(try doString("(+ 1 2)\n(def)\n", "contract", &out) == constants.JANET_DO_ERROR_COMPILE);
    expectErrPrefix("contract:2:1: compile error: ");
}

fn aParseErrorNamesAPosition() raise.Raising(void) {
    var out = wrap.fromNil();
    errReset();
    assert(try doString("(+ 1 2))", "contract", &out) == constants.JANET_DO_ERROR_PARSE);
    expectString(out, "contract:1:8: parse error: unexpected closing delimiter )");
    expectErr("contract:1:8: parse error: unexpected closing delimiter )\n");
}

fn aCompileErrorNamesAPosition() raise.Raising(void) {
    var out = wrap.fromNil();
    errReset();
    assert(try doString("(def)", "contract", &out) == constants.JANET_DO_ERROR_COMPILE);
    assert(harness.isType(out, repr.Tag.string));
    const text = wrap.toString(out);
    const length: usize = @intCast(types.stringHead(text).length);
    assert(std.mem.startsWith(u8, text[0..length], "contract:1:1: compile error: "));
    expectErrPrefix("contract:1:1: compile error: ");
}

/// A macro that raises during expansion leaves a fiber behind, and that branch
/// prints the context *without* a newline and follows it with a stack trace,
/// where the ordinary branch prints the whole message with one.
fn aMacroExpansionErrorPrintsATrace() raise.Raising(void) {
    var out = wrap.fromNil();
    errReset();
    assert(try doString(
        "(defmacro contract-boom [] (error :expansion)) (contract-boom)",
        "contract",
        &out,
    ) == constants.JANET_DO_ERROR_COMPILE);
    // The context is printed with `%s` and no separator, so it runs straight
    // into the first line of the trace. `FOUND.md` records that; it is pinned
    // here because it is the whole difference between this branch and the
    // ordinary one.
    expectErrPrefix("contract:1:48: compile errorerror: contract:1:48: compile error: ");
    assert(std.mem.indexOf(u8, errText(), "expansion") != null);
    assert(std.mem.indexOf(u8, errText(), "\n  in contract-boom ") != null);
}

fn aRuntimeErrorReportsTheValue() raise.Raising(void) {
    var out = wrap.fromNil();
    errReset();
    assert(try doString("(error :thrown)", "contract", &out) == constants.JANET_DO_ERROR_RUNTIME);
    assert(harness.isType(out, repr.Tag.keyword));
    assert(harness.stringIs(wrap.toKeyword(out), "thrown"));
    expectErrPrefix("error: thrown\n  in thunk [contract] ");
}

/// Every failure sets `done`, so the flag word only ever holds one bit and the
/// forms after the failing one never run.
fn aFailureStopsTheStream() raise.Raising(void) {
    var out = wrap.fromNil();
    errReset();
    const env = tables.new(4);
    env.*.proto = test_env;
    const source = "(error :stop) (setdyn :contract-ran true)";
    const flags = try core_env.dobytesImpl(env, source[0..@intCast(source.len)], "contract", &out);
    assert(flags == constants.JANET_DO_ERROR_RUNTIME);
    assert(flags == (flags & -flags));
    assert(harness.isType(tables.get(env, value.fromBytes("contract-ran", .keyword)), repr.Tag.nil));
}

fn aNullSourcePathIsNamedUnknown() raise.Raising(void) {
    var out = wrap.fromNil();
    errReset();
    assert(try doString("(+ 1 2))", null, &out) == constants.JANET_DO_ERROR_PARSE);
    expectString(out, "<unknown>:1:8: parse error: unexpected closing delimiter )");
}

// --------------------------------------------------------------- loopFiber

fn loopFiberReportsAStatus() raise.Raising(void) {
    var out = wrap.fromNil();
    errReset();
    assert(try doString("(fiber/new (fn [] 42))", "contract", &out) == 0);
    assert(harness.isType(out, repr.Tag.fiber));
    assert(try core_env.loopFiber(wrap.toFiber(out)) == @intFromEnum(types.FiberStatus.dead));

    assert(try doString("(fiber/new (fn [] (error :in-fiber)))", "contract", &out) == 0);
    errReset();
    assert(try core_env.loopFiber(wrap.toFiber(out)) == @intFromEnum(types.FiberStatus.@"error"));
}

// ------------------------------------------------------- the embedded image

/// The image is `@embedFile`d, and the length the runtime hands `unmarshal` is
/// one byte shorter than it was. A generated C array declared the bytes with a
/// trailing `0` so that it had a terminator, and `janet_core_image_size` was
/// that array's `sizeof` -- so the runtime described the image as 324,311
/// bytes when it was 324,310.
///
/// That was harmless because nothing read the extra byte, which is an
/// assumption rather than an observation. This is the observation: unmarshal
/// against the same length the runtime uses and ask where it stopped. The
/// stream ends exactly where the file does, so there was no slack the longer
/// length was covering for -- and if an emitter ever leaves some, this says so
/// rather than the next reader having to re-derive why the two numbers differ.
fn theImageIsConsumedExactly() raise.Raising(void) {
    const image = core_env.core_image;
    var next: [*]const u8 = undefined;
    const out = try marsh.unmarshal(image[0..@intCast(image.len)], 0, try core_env.coreLookupTable(null), &next);
    assert(harness.isType(out, repr.Tag.table));
    assert(@intFromPtr(next) == @intFromPtr(image) + image.len);
}

// ------------------------------------------------------- the lookup table

fn theLookupTableIsKeyedBySymbol() raise.Raising(void) {
    const dict = try core_env.coreLookupTable(null);
    assert(harness.isType(tables.get(dict, value.fromBytes("gcinterval", .symbol)), repr.Tag.cfunction));
    // A keyword of the same name is not the key.
    assert(harness.isType(tables.get(dict, value.fromBytes("gcinterval", .keyword)), repr.Tag.nil));
    // Every `loadLibs` entry the configuration has is in it, not only
    // corelib's.
    assert(harness.isType(tables.get(dict, value.fromBytes("string/slice", .symbol)), repr.Tag.cfunction));
    assert(harness.isType(tables.get(dict, value.fromBytes("marshal", .symbol)), repr.Tag.cfunction));
    // `peg/match` is registered only when the engine is compiled, and the
    // question to ask is the environment rather than `options`: what is missing
    // under `-Dpeg=false` is a registration.
    if (harness.coreOptional("peg/match") != null) {
        assert(harness.isType(tables.get(dict, value.fromBytes("peg/match", .symbol)), repr.Tag.cfunction));
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
    assert(wrap.toCfunction(
        tables.get(dict, value.fromBytes("gcinterval", .symbol)),
    ) == replacement_key);
    // A key the core does not define is added rather than rejected.
    assert(harness.isType(tables.get(dict, value.fromBytes("contract/added", .symbol)), repr.Tag.keyword));
    // A nil-keyed slot in the replacement table's storage is skipped, which is
    // what the walk over `capacity` rather than `count` is for.
    assert(dict.count > replacements.*.count);
}

// ------------------------------------------------------------------ getline
//
// `(getline)` reads through `(dyn :in)` and writes its prompt through
// `(dyn :out)`, both of which `janet_dynfile` resolves and both of which fall
// back to the process handles. The Janet suites cannot bind either without a
// file to bind it to, and cannot assert what was read without controlling what
// is on the other end, so the whole cfunction is exercised here.

fn getlineReadsALineThroughTheDyn() raise.Raising(void) {
    // Two handles, not one. Interleaving reads and writes on a single `FILE *`
    // without a seek between them is undefined, and `(getline)` does exactly
    // that when `:in` and `:out` name the same file.
    const in = c.tmpfile();
    const out_file = c.tmpfile();
    assert(in != null and out_file != null);
    _ = c.fputs("first line\nsecond", in);
    _ = c.fflush(in);
    c.rewind(in);

    const in_handle = io_core.makefile(in, constants.JANET_FILE_READ | constants.JANET_FILE_WRITE);
    const out_handle = io_core.makefile(out_file, constants.JANET_FILE_WRITE);
    gc_alloc.gcroot(in_handle);
    gc_alloc.gcroot(out_handle);
    // Into the environment table rather than through `janet_setdyn`. A dynamic
    // binding is fiber-local, `janet_dobytes` gives each form a fiber whose
    // env is this table, and `janet_setdyn` at the top level -- where there is
    // no fiber -- writes to `vm.top_dyns` instead, which the cfunction
    // never looks at. That split is why `:err` above is set the other way:
    // those diagnostics are printed after the fiber has finished.
    tables.put(test_env, value.fromBytes("in", .keyword), in_handle);
    tables.put(test_env, value.fromBytes("out", .keyword), out_handle);

    var result = wrap.fromNil();
    // The newline is part of what is returned.
    assert(try doString("(getline)", "contract", &result) == 0);
    assert(harness.isType(result, repr.Tag.buffer));
    {
        const b = wrap.toBuffer(result);
        assert(b.*.count == 11);
        assert(std.mem.eql(u8, b.*.slice()[0..11], "first line\n"));
    }

    // A supplied buffer is reused -- the same object comes back, not a copy --
    // and its previous contents are dropped. The last line has no newline, so
    // this also covers the EOF exit.
    assert(try doString(
        "(let [b @\"seed\"] [(= b (getline \"P>\" b)) b])",
        "contract",
        &result,
    ) == 0);
    {
        const pair = wrap.toTuple(result);
        const b = wrap.toBuffer(pair[1]);
        assert(repr.truthy(pair[0]));
        assert(b.*.count == 6);
        assert(std.mem.eql(u8, b.*.slice()[0..6], "second"));
    }

    // At EOF it answers an empty buffer rather than failing.
    assert(try doString("(getline)", "contract", &result) == 0);
    assert(wrap.toBuffer(result).*.count == 0);

    // A one-argument call writes its prompt too: the prompt is guarded by
    // `argc >= 1` and the buffer by `argc >= 2`, and only a call with exactly
    // one argument tells the two guards apart.
    assert(try doString("(getline \"Q>\")", "contract", &result) == 0);
    assert(harness.isType(result, repr.Tag.buffer));

    // Both prompts went to `(dyn :out)`, in order, and nothing else did.
    _ = c.fflush(out_file);
    c.rewind(out_file);
    {
        var written: [8]u8 = @splat(0);
        assert(c.fread(&written, 1, written.len - 1, out_file) == 4);
        assert(std.mem.eql(u8, written[0..4], "P>Q>"));
    }

    // A zero byte is data, not a terminator: the read stops at a newline or at
    // end of file and at nothing else.
    {
        const nul = c.tmpfile();
        assert(nul != null);
        _ = c.fwrite("a\x00b\n", 1, 4, nul);
        _ = c.fflush(nul);
        c.rewind(nul);
        const nul_handle = io_core.makefile(nul, constants.JANET_FILE_READ | constants.JANET_FILE_WRITE);
        gc_alloc.gcroot(nul_handle);
        tables.put(test_env, value.fromBytes("in", .keyword), nul_handle);
        assert(try doString("(getline)", "contract", &result) == 0);
        const b = wrap.toBuffer(result);
        assert(b.*.count == 4);
        assert(std.mem.eql(u8, b.*.slice()[0..4], "a\x00b\n"));
        tables.put(test_env, value.fromBytes("in", .keyword), in_handle);
        _ = gc_alloc.gcunroot(nul_handle);
    }

    // The documented third parameter is accepted and ignored: `getline` never
    // looks at `argv[2]`. `FOUND.md` has it.
    c.rewind(in);
    assert(try doString("(getline \"\" @\"\" :not-a-table)", "contract", &result) == 0);
    assert(wrap.toBuffer(result).*.count == 11);
    // A fourth is a plain arity error.
    errReset();
    assert(try doString("(getline \"\" @\"\" :a :b)", "contract", &result) ==
        constants.JANET_DO_ERROR_RUNTIME);

    tables.put(test_env, value.fromBytes("in", .keyword), wrap.fromNil());
    tables.put(test_env, value.fromBytes("out", .keyword), wrap.fromNil());
    _ = gc_alloc.gcunroot(in_handle);
    _ = gc_alloc.gcunroot(out_handle);
}

// ------------------------------------------------------------ janet_native

fn nativeReportsALoaderError() void {
    var err: ?types.JanetString = null;
    const init = core_env.nativeAbi("./contract-no-such-module.so", &err);
    assert(init == null);
    assert(err != null);
    assert(types.stringHead(err.?).length > 0);
}

// ------------------------------------------------------------------ sandbox
//
// Every capability `(sandbox ...)` applies is permanent for the VM, so this
// runs last and the suites cannot run it at all. What it pins is that the
// argument walk visits every argument and accumulates a flag per capability,
// which is invisible from Janet: there is no way to read the flag word back.

fn sandboxAccumulatesEveryCapability() raise.Raising(void) {
    var out = wrap.fromNil();
    assert(!harness.vm().sandbox_flags.intersects(types.Sandbox.of(&.{"hrtime"})));
    assert(!harness.vm().sandbox_flags.intersects(types.Sandbox.of(&.{"threads"})));

    // No arguments changes nothing.
    var before = harness.vm().sandbox_flags;
    assert(try doString("(sandbox)", "contract", &out) == 0);
    assert(harness.vm().sandbox_flags == before);

    // Two capabilities in one call set two bits, which is what the walk over
    // `argc` is for; a repeat is idempotent.
    assert(try doString("(sandbox :hrtime :threads :hrtime)", "contract", &out) == 0);
    assert(harness.vm().sandbox_flags.intersects(types.Sandbox.of(&.{"hrtime"})));
    assert(harness.vm().sandbox_flags.intersects(types.Sandbox.of(&.{"threads"})));

    // An unknown capability rejects the whole call, including the ones before
    // it in the same argument list.
    before = harness.vm().sandbox_flags;
    assert(try doString("(sandbox :env :nope)", "contract", &out) == constants.JANET_DO_ERROR_RUNTIME);
    assert(harness.vm().sandbox_flags == before);
    assert(!harness.vm().sandbox_flags.intersects(types.Sandbox.of(&.{"env"})));
}

/// Irreversible, so it goes last.
fn nativeIsBehindTheSandbox() void {
    var err: ?types.JanetString = null;
    vm_state.sandbox(types.Sandbox.of(&.{"dynamic_modules"})) catch @panic("core_env: janet_sandbox raised");
    const refusal = harness.abiRaised(
        core_env.nativeAbi,
        .{ @as([*:0]const u8, "./contract-no-such-module.so"), &err },
    ).?;
    assert(refusal.signal == types.Signal.@"error");
}

// ------------------------------------------------------------------- entry

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
        assert(try doString("(gcinterval)", "contract", &out) == 0);
        assert(harness.isType(out, repr.Tag.keyword));
        assert(harness.stringIs(wrap.toKeyword(out), "replaced"));
    }

    // And the second call ignores both its argument and the work.
    {
        const again = tables.new(1);
        tables.put(again, value.fromBytes("gcinterval", .symbol), wrap.fromNil());
        assert(try core_env.coreEnv(again) == test_env);
        assert(try core_env.coreEnv(null) == test_env);
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
    nativeReportsALoaderError();
    try sandboxAccumulatesEveryCapability();
    nativeIsBehindTheSandbox();
}

pub fn run() void {
    harness.init();
    body() catch @panic("core_env: an entry point raised unexpectedly");
    vm_state.deinit();

    std.debug.print("core env contract ok\n", .{});
}
