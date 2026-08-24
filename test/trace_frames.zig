//! Behavioral contract for stack frame decoding and the trace it is printed
//! into.
//!
//! What this file guards is a rendering. `janet_stacktrace_ext` prints the
//! trace every Janet user reads, and the decoding under test decides every
//! part of each line except the punctuation. The suites cover the two common
//! shapes — a named Janet function with a source map, and a registered
//! cfunction — and nothing else, because the remaining shapes need a funcdef
//! or a registry entry that the compiler and `janet_cfuns` never produce.
//!
//! So the cases are enumerated here rather than sampled, and the awkward one
//! is the point: **the name and the location are classified separately**, and
//! an entry that fails the name test can still pass the location test.
//! Collapsing the two is the mistake this file exists to catch.
//!
//! ## What the migration changed
//!
//! The C original called `janet_trace_frame` and `janet_stacktrace_ext`, which
//! are the two C faces; each is one line of `raise.reported` over the entry
//! point beside it. This calls `janet_trace_frameImpl` and `stacktraceExt`
//! directly, so a raise from a `tostring` callback reached through `%v` — the
//! only raise either can make — arrives as `error.JanetSignal` rather than as
//! a report nobody consumes. That is rule 13's hazard removed by construction
//! rather than avoided.
//!
//! The two faces stay. `janet_trace_frame` has three callers in
//! `debug_frames.zig` and one in `vm_calls.zig`; `janet_stacktrace_ext` has
//! one in `debug_frames.zig` and is `janet.h`'s public surface besides.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const raise = @import("raise");
const harness = @import("harness.zig");
const tf = @import("subsystems").trace_frames;

const assert = std.debug.assert;

/// The line the registry is told this contract's probe was defined on. It is
/// the contract's number rather than the file's — nothing reads the file — and
/// it is asserted literally below, so it is named once here.
const probe_line: i32 = 41;

var test_env: *c.JanetTable = undefined;

fn compileFunction(source: [*:0]const u8) *c.JanetFunction {
    var out = c.janet_wrap_nil();
    assert(c.janet_dostring(test_env, source, "trace-frames-test", &out) == 0);
    assert(harness.isType(out, c.JANET_FUNCTION));
    c.janet_gcroot(out);
    return c.janet_unwrap_function(out);
}

/// The decoder reads three fields of a frame and nothing else, so a frame can
/// be a plain local rather than four slots carved out of a live fiber's stack.
/// That keeps every case below constructible, including the ones no fiber
/// would ever hold.
fn frameOfFunction(frame: *c.JanetStackFrame, func: *c.JanetFunction, pc_offset: i32) void {
    frame.* = std.mem.zeroes(c.JanetStackFrame);
    frame.func = func;
    frame.pc = if (pc_offset < 0) null else func.def.*.bytecode + @as(usize, @intCast(pc_offset));
}

fn frameOfCfunction(frame: *c.JanetStackFrame, cfun: c.JanetCFunction) void {
    frame.* = std.mem.zeroes(c.JanetStackFrame);
    frame.func = null;
    frame.pc = @ptrFromInt(@intFromPtr(cfun));
}

fn decode(frame: *c.JanetStackFrame) c.JanetTraceFrame {
    var out: c.JanetTraceFrame = undefined;
    // `janet_trace_frameImpl` is `raise.Raising(void)` and never raises: it
    // reads a funcdef and the registry and writes a plain structure. The
    // `catch` is what the type asks for, not a case this contract expects.
    tf.janet_trace_frameImpl(frame, &out) catch unreachable;
    return out;
}

// Three cfunctions used only as registry keys. They are never called; what
// matters is that each is a **distinct address** the registry can be keyed on.
//
// In C these were three `static Janet f(int32_t, Janet *)` with identical
// bodies. Here they have the type a builtin actually has since Phase 10 Part
// 17g — `raise.Raising(Janet)` over Zig's own calling convention — and
// `raise.stored` is the cast into the `JanetCFunRegistry` key, which is still
// C's layout.
//
// **Each returns a different value, and that is load-bearing rather than
// decorative.** Written as three identical `return janet_wrap_nil()` bodies —
// which is what a transcription of the C gives — every optimize mode above
// Debug folds them into one function, so all three keys become one address:
// `janet_registry_get(probeUnregistered)` answers the entry planted for
// `probeNamed`, and `anUnregisteredCfunction` fails. Debug passes, and the
// three `-Doptimize=Release*` entries of the acceptance matrix do not.
//
// Distinct returns are the cheapest way to make the folding illegal, and they
// are free: nothing calls these.

fn probeNamed(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    _ = argc;
    _ = argv;
    return harness.wrapInteger(1);
}

fn probeUnnamed(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    _ = argc;
    _ = argv;
    return harness.wrapInteger(2);
}

fn probeUnregistered(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    _ = argc;
    _ = argv;
    return harness.wrapInteger(3);
}

fn keyOf(probe: raise.CFunction) c.JanetCFunction {
    return raise.stored(probe);
}

// -------------------------------------------------------- Janet functions

/// A compiled function carries a name, a source, and a source map, which is
/// the shape behind almost every line of a real trace. A `-Dsourcemaps=false`
/// build has no source map to decode and takes the bytecode-offset path below
/// for every Janet frame in the program instead.
fn aNamedFunctionWithASourcemap(named: *c.JanetFunction) void {
    if (named.def.*.sourcemap == null) return;
    assert(named.def.*.name != null);

    var frame: c.JanetStackFrame = undefined;
    frameOfFunction(&frame, named, 0);
    var desc = decode(&frame);

    assert(desc.name_kind == c.JANET_TRACE_NAME_FUNCTION);
    assert(desc.name == @as([*c]const u8, @ptrCast(named.def.*.name)));
    assert(desc.name_prefix == null);
    assert(desc.source == @as([*c]const u8, @ptrCast(named.def.*.source)));
    assert(desc.loc_kind == c.JANET_TRACE_LOC_SOURCEMAP);
    assert(desc.line == named.def.*.sourcemap[0].line);
    assert(desc.column == named.def.*.sourcemap[0].column);
    assert(desc.tail == 0);

    // The offset the program counter reports is an index into the bytecode,
    // not a byte offset, and it selects the mapping.
    if (named.def.*.bytecode_length > 1) {
        frameOfFunction(&frame, named, 1);
        desc = decode(&frame);
        assert(desc.loc_kind == c.JANET_TRACE_LOC_SOURCEMAP);
        assert(desc.line == named.def.*.sourcemap[1].line);
        assert(desc.column == named.def.*.sourcemap[1].column);
    }
}

/// A funcdef with no name renders as `<anonymous>`, and the descriptor says so
/// by kind rather than by handing the caller that string — the caller owns the
/// wording.
fn anAnonymousFunction(anonymous: *c.JanetFunction) void {
    assert(anonymous.def.*.name == null);

    var frame: c.JanetStackFrame = undefined;
    frameOfFunction(&frame, anonymous, 0);
    const desc = decode(&frame);

    assert(desc.name_kind == c.JANET_TRACE_NAME_ANONYMOUS);
    assert(desc.name == null);
    assert(desc.source == @as([*c]const u8, @ptrCast(anonymous.def.*.source)));
}

/// Without a source map the location degrades to the raw bytecode offset. A
/// build compiled with `-Dsourcemaps=false` takes this path for every Janet
/// frame in the program, so it is not an exotic case.
fn aFunctionWithoutASourcemap(named: *c.JanetFunction) void {
    const saved = named.def.*.sourcemap;

    // Already null in a `-Dsourcemaps=false` build; the assignment makes the
    // branch under test the same one in either configuration.
    named.def.*.sourcemap = null;
    var frame: c.JanetStackFrame = undefined;
    frameOfFunction(&frame, named, 1);
    const desc = decode(&frame);
    named.def.*.sourcemap = saved;

    assert(desc.name_kind == c.JANET_TRACE_NAME_FUNCTION);
    assert(desc.loc_kind == c.JANET_TRACE_LOC_PC);
    assert(desc.pc == 1);
    assert(desc.line == 0);
    assert(desc.column == 0);
}

/// A function frame whose program counter is null reports no location at all —
/// not offset zero, and not the registry line a cfunction would report. The C
/// original arrives here by falling out of one branch into another that cannot
/// fire, which is exactly the kind of accident a rewrite tidies away.
fn aFunctionWithoutAPc(named: *c.JanetFunction) void {
    var frame: c.JanetStackFrame = undefined;
    frameOfFunction(&frame, named, -1);
    const desc = decode(&frame);

    assert(desc.name_kind == c.JANET_TRACE_NAME_FUNCTION);
    assert(desc.loc_kind == c.JANET_TRACE_LOC_NONE);
}

/// The tail-call marker is independent of everything else.
fn theTailCallFlag(named: *c.JanetFunction) void {
    var frame: c.JanetStackFrame = undefined;

    frameOfFunction(&frame, named, 0);
    frame.flags |= c.JANET_STACKFRAME_TAILCALL;
    var desc = decode(&frame);
    assert(desc.tail == 1);
    assert(desc.name_kind == c.JANET_TRACE_NAME_FUNCTION);

    frameOfCfunction(&frame, keyOf(&probeNamed));
    frame.flags |= c.JANET_STACKFRAME_TAILCALL;
    desc = decode(&frame);
    assert(desc.tail == 1);
}

// ------------------------------------------------------------- cfunctions

/// A registered cfunction reports its prefix, its name, its file, and its
/// line. This is every core function that appears in a trace.
fn aRegisteredCfunction() void {
    var frame: c.JanetStackFrame = undefined;
    frameOfCfunction(&frame, keyOf(&probeNamed));
    const desc = decode(&frame);

    assert(desc.name_kind == c.JANET_TRACE_NAME_CFUNCTION);
    assert(std.mem.orderZ(u8, desc.name, "probe") == .eq);
    assert(std.mem.orderZ(u8, desc.name_prefix, "trace") == .eq);
    assert(std.mem.orderZ(u8, desc.source, "trace_frames.zig") == .eq);
    assert(desc.loc_kind == c.JANET_TRACE_LOC_CFUN_LINE);
    assert(desc.line == probe_line);
    assert(desc.pc == 0);
    assert(desc.column == 0);
}

/// A cfunction the registry has never heard of renders as a bare
/// `<cfunction>` with no source and no location. Reaching this from Janet
/// needs a cfunction installed without `janet_cfuns`, which nothing in the
/// core does — and the decoder must not dereference the null the registry
/// returns.
fn anUnregisteredCfunction() void {
    assert(harness.internal.janet_registry_get(keyOf(&probeUnregistered)) == null);

    var frame: c.JanetStackFrame = undefined;
    frameOfCfunction(&frame, keyOf(&probeUnregistered));
    const desc = decode(&frame);

    assert(desc.name_kind == c.JANET_TRACE_NAME_CFUNCTION_BARE);
    assert(desc.name == null);
    assert(desc.name_prefix == null);
    assert(desc.source == null);
    assert(desc.loc_kind == c.JANET_TRACE_LOC_NONE);
}

/// The case the two-field descriptor exists for. A registry entry with no name
/// fails the name test and still passes the location test, so the frame
/// renders as `<cfunction> on line 99` — a bare name with a real location. One
/// tag covering both would have to choose, and either choice changes a line of
/// output the runtime prints today.
fn aRegisteredCfunctionWithoutAName() void {
    const reg = harness.internal.janet_registry_get(keyOf(&probeUnnamed));
    assert(reg != null);
    assert(reg.*.name == null);
    assert(reg.*.source_line == 99);

    var frame: c.JanetStackFrame = undefined;
    frameOfCfunction(&frame, keyOf(&probeUnnamed));
    const desc = decode(&frame);

    assert(desc.name_kind == c.JANET_TRACE_NAME_CFUNCTION_BARE);
    assert(desc.name == null);
    // Not reported, even though the entry has one: a source is printed only in
    // the branch that printed a name.
    assert(desc.source == null);
    assert(desc.loc_kind == c.JANET_TRACE_LOC_CFUN_LINE);
    assert(desc.line == 99);
}

/// A registry entry whose source line is zero or negative reports no location.
/// `janet_cfuns` installs exactly this for every function registered without
/// source information.
fn aRegisteredCfunctionWithoutALine() void {
    const reg = harness.internal.janet_registry_get(keyOf(&probeNamed));
    const saved = reg.*.source_line;
    var frame: c.JanetStackFrame = undefined;

    reg.*.source_line = 0;
    frameOfCfunction(&frame, keyOf(&probeNamed));
    var desc = decode(&frame);
    assert(desc.name_kind == c.JANET_TRACE_NAME_CFUNCTION);
    assert(desc.loc_kind == c.JANET_TRACE_LOC_NONE);

    reg.*.source_line = -1;
    desc = decode(&frame);
    assert(desc.loc_kind == c.JANET_TRACE_LOC_NONE);

    reg.*.source_line = saved;
}

/// A registered cfunction with no prefix reports a null prefix rather than an
/// empty string, because the caller branches on it to choose between `%s/%s`
/// and `%s`.
fn aRegisteredCfunctionWithoutAPrefix() void {
    const reg = harness.internal.janet_registry_get(keyOf(&probeNamed));
    const saved = reg.*.name_prefix;
    var frame: c.JanetStackFrame = undefined;

    reg.*.name_prefix = null;
    frameOfCfunction(&frame, keyOf(&probeNamed));
    const desc = decode(&frame);
    assert(desc.name_kind == c.JANET_TRACE_NAME_CFUNCTION);
    assert(desc.name_prefix == null);
    assert(std.mem.orderZ(u8, desc.name, "probe") == .eq);

    reg.*.name_prefix = saved;
}

/// Neither a function nor a cfunction: the frame contributes a bare `  in`
/// line. A cframe pushed with a null cfunction produces this, and `janet_call`
/// pushes one whenever it has to clear a dirty stack.
fn anEmptyFrame() void {
    var frame: c.JanetStackFrame = undefined;
    frameOfCfunction(&frame, null);
    const desc = decode(&frame);

    assert(desc.name_kind == c.JANET_TRACE_NAME_NONE);
    assert(desc.name == null);
    assert(desc.name_prefix == null);
    assert(desc.source == null);
    assert(desc.loc_kind == c.JANET_TRACE_LOC_NONE);
    assert(desc.tail == 0);
}

// ------------------------------------------------------------ whole traces

fn contents(sink: *c.JanetBuffer) []const u8 {
    return sink.data[0..@intCast(sink.count)];
}

/// Run the printer with `:err` bound to a buffer, which is how the rendering
/// is read back rather than sent to the harness's stderr.
/// `janet_stacktrace_ext` goes through `janet_dynprintf`, and that is exactly
/// what the binding redirects.
fn traceInto(
    sink: *c.JanetBuffer,
    fiber: [*c]c.JanetFiber,
    err: c.Janet,
    prefix: [*c]const u8,
) raise.Raising(void) {
    c.janet_buffer_setcount(sink, 0);
    c.janet_setdyn("err", c.janet_wrap_buffer(sink));
    defer c.janet_setdyn("err", c.janet_wrap_nil());
    try tf.stacktraceExt(fiber, err, prefix);
}

/// The `%s/%s` branch, which no suite can reach: it is taken only when a
/// registered cfunction has a *prefix*, and every core registration passes
/// null for one. A native module calling `janet_cfuns_prefix` gets one, and so
/// does the registry entry this file plants by hand.
fn aPrefixedCfunctionRenders() raise.Raising(void) {
    const sink = c.janet_buffer(256);
    c.janet_gcroot(c.janet_wrap_buffer(sink));
    defer _ = c.janet_gcunroot(c.janet_wrap_buffer(sink));

    // A fiber whose only frame is a cframe for the prefixed cfunction. The
    // frame is written directly because there is no way to stop a real fiber
    // inside a cfunction that does not itself error.
    const fiber = c.janet_fiber(compileFunction("(fn [] nil)"), 32, 0, null);
    assert(fiber != null);
    c.janet_gcroot(c.janet_wrap_fiber(fiber));
    defer _ = c.janet_gcunroot(c.janet_wrap_fiber(fiber));
    fiber.*.frame = c.JANET_FRAME_SIZE;
    fiber.*.stackstart = c.JANET_FRAME_SIZE;
    fiber.*.stacktop = c.JANET_FRAME_SIZE;
    const frame: *c.JanetStackFrame = @ptrCast(@alignCast(fiber.*.data));
    frameOfCfunction(frame, keyOf(&probeNamed));
    frame.prevframe = 0;

    try traceInto(sink, fiber, c.janet_cstringv("prefixed"), "P");
    assert(std.mem.indexOf(u8, contents(sink), "  in trace/probe [trace_frames.zig] on line 41\n") != null);
    // The error line is printed once, above the first frame, as
    // `<prefix><status>: <message>`. The status is the fiber's, which for a
    // frame written by hand rather than reached by running is "new".
    assert(std.mem.startsWith(u8, contents(sink), "Pnew: prefixed\n"));

    // A null prefix suppresses the error line and keeps the frames.
    try traceInto(sink, fiber, c.janet_cstringv("prefixed"), null);
    assert(std.mem.indexOf(u8, contents(sink), "prefixed") == null);
    assert(std.mem.indexOf(u8, contents(sink), "  in trace/probe [") != null);

    // `:err-color` wraps the whole rendering.
    c.janet_setdyn("err-color", c.janet_wrap_true());
    try traceInto(sink, fiber, c.janet_cstringv("prefixed"), "P");
    c.janet_setdyn("err-color", c.janet_wrap_nil());
    assert(std.mem.startsWith(u8, contents(sink), "\x1b[31m"));
    assert(std.mem.endsWith(u8, contents(sink), "\x1b[0m"));
}

/// The decoder is one half of a printer, so run the printer too — over a real
/// fiber that has stopped at an error, which is the only check here that the
/// descriptor and the loop that consumes it agree about the frames of a live
/// stack.
///
/// `:err-color` is bound explicitly for the reason `test/suite-debug.janet`
/// gives at `trace-of`: a truthy binding wraps the whole trace in escapes, and
/// an assertion on the leading bytes then depends on ambient state. It is nil
/// here because a contract runs no `cli-main`, which is precisely the kind of
/// thing that is true until it is not.
fn aStacktraceOverARealFiber(failing: *c.JanetFunction) raise.Raising(void) {
    const fiber = c.janet_fiber(failing, 32, 0, null);
    assert(fiber != null);
    c.janet_gcroot(c.janet_wrap_fiber(fiber));
    defer _ = c.janet_gcunroot(c.janet_wrap_fiber(fiber));

    const sink = c.janet_buffer(0);
    c.janet_gcroot(c.janet_wrap_buffer(sink));
    defer _ = c.janet_gcunroot(c.janet_wrap_buffer(sink));

    var out = c.janet_wrap_nil();
    assert(c.janet_continue(fiber, c.janet_wrap_nil(), &out) == c.JANET_SIGNAL_ERROR);

    c.janet_setdyn("err-color", c.janet_wrap_nil());
    try traceInto(sink, fiber, out, "trace-frames-test");
    assert(sink.*.count > 0);
    assert(std.mem.indexOf(u8, contents(sink), "trace-frames-testerror: from a fiber") != null);

    // And with no prefix, which suppresses the error line entirely.
    try traceInto(sink, fiber, out, null);
    assert(sink.*.count > 0);
    assert(std.mem.indexOf(u8, contents(sink), "error: from a fiber") == null);
}

// ------------------------------------------------------------------- main

fn body() raise.Raising(void) {
    test_env = c.janet_core_env(null);
    c.janet_gcroot(c.janet_wrap_table(test_env));

    // The line numbers here are the contract's, not the file's: they are what
    // the registry reports back, and the cases above assert them literally.
    harness.internal.janet_registry_put(keyOf(&probeNamed), "probe", "trace", "trace_frames.zig", probe_line);
    harness.internal.janet_registry_put(keyOf(&probeUnnamed), null, null, "unnamed.zig", 99);

    const named = compileFunction("(defn traced-function [] nil) traced-function");
    const anonymous = compileFunction("(fn [] nil)");
    const failing = compileFunction("(fn [] (error \"from a fiber\"))");

    aNamedFunctionWithASourcemap(named);
    anAnonymousFunction(anonymous);
    aFunctionWithoutASourcemap(named);
    aFunctionWithoutAPc(named);
    theTailCallFlag(named);

    aRegisteredCfunction();
    anUnregisteredCfunction();
    aRegisteredCfunctionWithoutAName();
    aRegisteredCfunctionWithoutALine();
    aRegisteredCfunctionWithoutAPrefix();
    anEmptyFrame();

    try aPrefixedCfunctionRenders();
    try aStacktraceOverARealFiber(failing);
}

pub fn run() void {
    _ = c.janet_init();
    body() catch @panic("trace_frames: a trace raised unexpectedly");
    c.janet_deinit();

    std.debug.print("trace frames contract ok\n", .{});
}
