//! Behavioral contract for stack frame decoding and the trace it is printed
//! into.
//!
//! What this file guards is a rendering. `debug.stacktraceExt` prints the
//! trace every Janet user reads, and the decoding under test decides every
//! part of each line except the punctuation. The suites cover two common
//! shapes, a named Janet function with a source map and a registered
//! nfunction, and nothing else, because the remaining shapes need a funcdef or
//! a registry entry that the compiler and `registry.nfuns` never produce.
//!
//! So the cases are enumerated here rather than sampled, and the awkward one
//! is what the file exists for: the name and the location are classified
//! separately, and an entry that fails the name test can still pass the
//! location test. Collapsing the two is the mistake this catches.
//!
//! ## The entry points are called by import
//!
//! `debug.traceFrame` and `debug.stacktraceExt` are raise-capable and this
//! calls them directly, so a raise from a `tostring` callback reached through
//! `%v`, which is the only raise either can make, arrives as
//! `error.Signal` rather than as a report nobody consumes.
//!
//! The two abis stay, each having callers inside the runtime that cannot take
//! an error union.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const buffers = @import("subsystems").value.buffers;
const constants = @import("constants");
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const fibers = @import("subsystems").value.fibers;
const functions = @import("subsystems").value.functions;
const gc_alloc = @import("subsystems").gc_alloc;
const harness = @import("harness.zig");
const raise = @import("subsystems").raise;
const registry = @import("subsystems").registry;
const repr = @import("repr");
const tables = @import("subsystems").value.tables;
const tf = @import("subsystems").debug;
const value = @import("subsystems").value;
const vm_entry = @import("subsystems").vm_entry;
const vm_lifecycle = @import("subsystems").lifecycle;
const vm_state = @import("subsystems").vm_state;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// The line the registry is told this contract's probe was defined on. It is
/// the contract's number rather than the file's, nothing reading the file, and
/// it is asserted literally below, so it is named once here.
const probe_line: i32 = 41;
var test_env: *tables.Table = undefined;

// ==========================================================================
// Cases
// ==========================================================================

fn compileFunction(source: [*:0]const u8) *functions.Function {
    var out = wrap.fromNil();
    expect(core_env.dostring(test_env, source, "trace-frames-test", &out) == 0);
    expect(harness.isType(out, repr.Tag.function));
    gc_alloc.gcroot(out);
    return wrap.toFunction(out);
}

/// The decoder reads three fields of a frame and nothing else, so a frame can
/// be a plain local rather than four slots carved out of a live fiber's stack.
/// That keeps every case below constructible, including the ones no fiber
/// would ever produce.
fn frameOfFunction(frame: *vm_state.StackFrame, func: *functions.Function, pc_offset: i32) void {
    frame.* = std.mem.zeroes(vm_state.StackFrame);
    frame.func = func;
    frame.pc = .{ .bytecode = if (pc_offset < 0) null else func.def.?.bytecode.? + @as(usize, @intCast(pc_offset)) };
}

fn frameOfNfunction(frame: *vm_state.StackFrame, nfun: abi.NFunction) void {
    frame.* = std.mem.zeroes(vm_state.StackFrame);
    frame.func = null;
    frame.pc = .{ .nfunction = nfun };
}

/// Three nfunctions used only as registry keys. They are never called; what
/// matters is that each is a distinct address the registry can be keyed on,
/// and each has the type a builtin has.
///
/// Each returns a different value, and that is load-bearing rather than
/// decorative. Three identical bodies would be folded into one function by
/// every optimize mode above Debug, so all three keys would become one
/// address, the registry lookup for `probeUnregistered` would find the entry
/// planted for `probeNamed`, and `anUnregisteredNfunction` would fail in every
/// release build while passing in Debug. Distinct returns make the folding
/// illegal and cost nothing, since nothing calls these.
fn probeNamed(argv: []repr.Value) raise.Error!repr.Value {
    _ = @as(i32, @intCast(argv.len));

    return harness.wrapInteger(1);
}

fn probeUnnamed(argv: []repr.Value) raise.Error!repr.Value {
    _ = @as(i32, @intCast(argv.len));

    return harness.wrapInteger(2);
}

fn probeUnregistered(argv: []repr.Value) raise.Error!repr.Value {
    _ = @as(i32, @intCast(argv.len));

    return harness.wrapInteger(3);
}

fn decode(frame: *vm_state.StackFrame) tf.TraceFrame {
    var out: tf.TraceFrame = undefined;
    // `debug.traceFrame` is `raise.Error!void` and never raises: it reads
    // a funcdef and the registry and writes a plain structure. The
    // `catch` is what the type asks for, not a case this contract expects.
    tf.traceFrame(frame, &out) catch unreachable;
    return out;
}

/// `raise.stored` is the cast from one of the three probes into the `Row` key
/// the registry is indexed by.
fn keyOf(probe: raise.NFunction) abi.NFunction {
    return raise.stored(probe);
}

fn contents(sink: *buffers.Buffer) []const u8 {
    return sink.slice();
}

/// Run the printer with `:err` bound to a buffer, which is how the rendering
/// is read back rather than sent to the harness's stderr.
/// `debug.stacktraceExt` goes through `pp_format.dynprintf`, and that is
/// exactly what the binding redirects.
fn traceInto(
    sink: *buffers.Buffer,
    fiber: *fibers.Fiber,
    err: repr.Value,
    prefix: ?[*:0]const u8,
) raise.Error!void {
    buffers.setcount(sink, 0) catch @panic("trace_frames: setcount raised");
    vm_state.setdyn("err", wrap.fromBuffer(sink));
    defer vm_state.setdyn("err", wrap.fromNil());
    try tf.stacktraceExt(fiber, err, prefix);
}

/// A compiled function has a name, a source and a source map, which is
/// the shape behind almost every line of a real trace. A `-Dsourcemaps=false`
/// build has no source map to decode and takes the bytecode-offset path below
/// for every Janet frame in the program instead.
fn aNamedFunctionWithASourcemap(named: *functions.Function) void {
    if (named.def.?.sourcemap == null) return;
    expect(named.def.?.name != null);

    var frame: vm_state.StackFrame = undefined;
    frameOfFunction(&frame, named, 0);
    var desc = decode(&frame);

    expect(desc.name_kind == constants.trace_name_function);
    expect(desc.name == @as([*]const u8, @ptrCast(named.def.?.name)));
    expect(desc.name_prefix == null);
    expect(desc.source == @as([*]const u8, @ptrCast(named.def.?.source)));
    expect(desc.loc_kind == constants.trace_loc_sourcemap);
    expect(desc.line == named.def.?.sourceMappings()[0].line);
    expect(desc.column == named.def.?.sourceMappings()[0].column);
    expect(desc.tail == 0);

    // The offset the program counter reports is an index into the bytecode,
    // not a byte offset, and it selects the mapping.
    if (named.def.?.bytecode_length > 1) {
        frameOfFunction(&frame, named, 1);
        desc = decode(&frame);
        expect(desc.loc_kind == constants.trace_loc_sourcemap);
        expect(desc.line == named.def.?.sourceMappings()[1].line);
        expect(desc.column == named.def.?.sourceMappings()[1].column);
    }
}

/// A funcdef with no name renders as `<anonymous>`, and the descriptor says so
/// by kind rather than by giving the caller that string, the wording being the
/// caller's.
fn anAnonymousFunction(anonymous: *functions.Function) void {
    expect(anonymous.def.?.name == null);

    var frame: vm_state.StackFrame = undefined;
    frameOfFunction(&frame, anonymous, 0);
    const desc = decode(&frame);

    expect(desc.name_kind == constants.trace_name_anonymous);
    expect(desc.name == null);
    expect(desc.source == @as([*]const u8, @ptrCast(anonymous.def.?.source)));
}

/// Without a source map the location degrades to the raw bytecode offset. A
/// build compiled with `-Dsourcemaps=false` takes this path for every Janet
/// frame in the program, so it is not an exotic case.
fn aFunctionWithoutASourcemap(named: *functions.Function) void {
    const saved = named.def.?.sourcemap;

    // Already null in a `-Dsourcemaps=false` build; the assignment makes the
    // branch under test the same one in either configuration.
    named.def.?.sourcemap = null;
    var frame: vm_state.StackFrame = undefined;
    frameOfFunction(&frame, named, 1);
    const desc = decode(&frame);
    named.def.?.sourcemap = saved;

    expect(desc.name_kind == constants.trace_name_function);
    expect(desc.loc_kind == constants.trace_loc_pc);
    expect(desc.pc == 1);
    expect(desc.line == 0);
    expect(desc.column == 0);
}

/// A function frame whose program counter is null reports no location at all:
/// not offset zero, and not the registry line an nfunction would report.
fn aFunctionWithoutAPc(named: *functions.Function) void {
    var frame: vm_state.StackFrame = undefined;
    frameOfFunction(&frame, named, -1);
    const desc = decode(&frame);

    expect(desc.name_kind == constants.trace_name_function);
    expect(desc.loc_kind == constants.trace_loc_none);
}

/// The tail-call marker is independent of everything else.
fn theTailCallFlag(named: *functions.Function) void {
    var frame: vm_state.StackFrame = undefined;

    frameOfFunction(&frame, named, 0);
    frame.flags.tailcall = true;
    var desc = decode(&frame);
    expect(desc.tail == 1);
    expect(desc.name_kind == constants.trace_name_function);

    frameOfNfunction(&frame, keyOf(&probeNamed));
    frame.flags.tailcall = true;
    desc = decode(&frame);
    expect(desc.tail == 1);
}

/// A registered nfunction reports its prefix, its name, its file, and its
/// line. This is every core function that appears in a trace.
fn aRegisteredNfunction() void {
    var frame: vm_state.StackFrame = undefined;
    frameOfNfunction(&frame, keyOf(&probeNamed));
    const desc = decode(&frame);

    expect(desc.name_kind == constants.trace_name_nfunction);
    expect(std.mem.orderZ(u8, desc.name.?, "probe") == .eq);
    expect(std.mem.orderZ(u8, desc.name_prefix.?, "trace") == .eq);
    expect(std.mem.orderZ(u8, desc.source.?, "trace_frames.zig") == .eq);
    expect(desc.loc_kind == constants.trace_loc_nfun_line);
    expect(desc.line == probe_line);
    expect(desc.pc == 0);
    expect(desc.column == 0);
}

/// An nfunction the registry has never heard of renders as a bare
/// `<nfunction>` with no source and no location. Reaching this from Janet
/// needs an nfunction installed without `registry.nfuns`, which nothing in the
/// core does, and the decoder must not dereference the null the registry
/// returns.
fn anUnregisteredNfunction() void {
    expect(registry.registryGet(keyOf(&probeUnregistered)) == null);

    var frame: vm_state.StackFrame = undefined;
    frameOfNfunction(&frame, keyOf(&probeUnregistered));
    const desc = decode(&frame);

    expect(desc.name_kind == constants.trace_name_nfunction_bare);
    expect(desc.name == null);
    expect(desc.name_prefix == null);
    expect(desc.source == null);
    expect(desc.loc_kind == constants.trace_loc_none);
}

/// The case the two-field descriptor exists for. A registry entry with no name
/// fails the name test and still passes the location test, so the frame
/// renders as `<nfunction> on line 99`, a bare name with a real location. One
/// tag covering both would have to choose, and either choice changes a line of
/// output the runtime prints today.
fn aRegisteredNfunctionWithoutAName() void {
    const reg = registry.registryGet(keyOf(&probeUnnamed));
    expect(reg != null);
    expect(reg.?.name == null);
    expect(reg.?.source_line == 99);

    var frame: vm_state.StackFrame = undefined;
    frameOfNfunction(&frame, keyOf(&probeUnnamed));
    const desc = decode(&frame);

    expect(desc.name_kind == constants.trace_name_nfunction_bare);
    expect(desc.name == null);
    // Not reported, even though the entry has one: a source is printed only in
    // the branch that printed a name.
    expect(desc.source == null);
    expect(desc.loc_kind == constants.trace_loc_nfun_line);
    expect(desc.line == 99);
}

/// A registry entry whose source line is zero or negative reports no location.
/// `registry.nfuns` installs exactly this for every function registered
/// without source information.
fn aRegisteredNfunctionWithoutALine() void {
    const reg = registry.registryGet(keyOf(&probeNamed));
    const saved = reg.?.source_line;
    var frame: vm_state.StackFrame = undefined;

    reg.?.source_line = 0;
    frameOfNfunction(&frame, keyOf(&probeNamed));
    var desc = decode(&frame);
    expect(desc.name_kind == constants.trace_name_nfunction);
    expect(desc.loc_kind == constants.trace_loc_none);

    reg.?.source_line = -1;
    desc = decode(&frame);
    expect(desc.loc_kind == constants.trace_loc_none);

    reg.?.source_line = saved;
}

/// A registered nfunction with no prefix reports a null prefix rather than an
/// empty string, because the caller branches on it to choose between `%s/%s`
/// and `%s`.
fn aRegisteredNfunctionWithoutAPrefix() void {
    const reg = registry.registryGet(keyOf(&probeNamed));
    const saved = reg.?.name_prefix;
    var frame: vm_state.StackFrame = undefined;

    reg.?.name_prefix = null;
    frameOfNfunction(&frame, keyOf(&probeNamed));
    const desc = decode(&frame);
    expect(desc.name_kind == constants.trace_name_nfunction);
    expect(desc.name_prefix == null);
    expect(std.mem.orderZ(u8, desc.name.?, "probe") == .eq);

    reg.?.name_prefix = saved;
}

/// Neither a function nor an nfunction: the frame contributes a bare `  in`
/// line. A cframe pushed with a null nfunction produces this, and
/// `vm_entry.call` pushes one whenever it has to clear a dirty stack.
fn anEmptyFrame() void {
    var frame: vm_state.StackFrame = undefined;
    frameOfNfunction(&frame, null);
    const desc = decode(&frame);

    expect(desc.name_kind == constants.trace_name_none);
    expect(desc.name == null);
    expect(desc.name_prefix == null);
    expect(desc.source == null);
    expect(desc.loc_kind == constants.trace_loc_none);
    expect(desc.tail == 0);
}

/// The `%s/%s` branch, which no suite can reach: it is taken only when a
/// registered nfunction has a *prefix*, and every core registration passes
/// null for one. A native module registering with a prefix gets one, and so
/// does the registry entry this file plants by hand.
fn aPrefixedNfunctionRenders() raise.Error!void {
    const sink = buffers.new(256);
    gc_alloc.gcroot(wrap.fromBuffer(sink));
    defer _ = gc_alloc.gcunroot(wrap.fromBuffer(sink));

    // A fiber whose only frame is a cframe for the prefixed nfunction. The
    // frame is written directly because there is no way to stop a real fiber
    // inside an nfunction that does not itself error.
    const fiber = fibers.new(compileFunction("(fn [] nil)"), 32, &.{}) catch unreachable;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    defer _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));
    fiber.frame = constants.frame_size;
    fiber.stackstart = constants.frame_size;
    fiber.stacktop = constants.frame_size;
    const frame: *vm_state.StackFrame = @ptrCast(@alignCast(fiber.data));
    frameOfNfunction(frame, keyOf(&probeNamed));
    frame.prevframe = 0;

    try traceInto(sink, fiber, value.fromBytes("prefixed", .string), "P");
    expect(std.mem.indexOf(u8, contents(sink), "  in trace/probe [trace_frames.zig] on line 41\n") != null);
    // The error line is printed once, above the first frame, as
    // `<prefix><status>: <message>`. The status is the fiber's, which for a
    // frame written by hand rather than reached by running is "new".
    expect(std.mem.startsWith(u8, contents(sink), "Pnew: prefixed\n"));

    // A null prefix suppresses the error line and keeps the frames.
    try traceInto(sink, fiber, value.fromBytes("prefixed", .string), null);
    expect(std.mem.indexOf(u8, contents(sink), "prefixed") == null);
    expect(std.mem.indexOf(u8, contents(sink), "  in trace/probe [") != null);

    // `:err-color` wraps the whole rendering.
    vm_state.setdyn("err-color", wrap.fromTrue());
    try traceInto(sink, fiber, value.fromBytes("prefixed", .string), "P");
    vm_state.setdyn("err-color", wrap.fromNil());
    expect(std.mem.startsWith(u8, contents(sink), "\x1b[31m"));
    expect(std.mem.endsWith(u8, contents(sink), "\x1b[0m"));
}

/// An nfunction the registry cannot name prints as `<nfunction>`, with the
/// line when the registry has one and nothing more when it has no entry.
/// The frames are written by hand, as in `aPrefixedNfunctionRenders`.
fn aBareNfunctionRenders() raise.Error!void {
    const sink = buffers.new(256);
    gc_alloc.gcroot(wrap.fromBuffer(sink));
    defer _ = gc_alloc.gcunroot(wrap.fromBuffer(sink));

    const fiber = fibers.new(compileFunction("(fn [] nil)"), 32, &.{}) catch unreachable;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    defer _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));
    fiber.frame = constants.frame_size;
    fiber.stackstart = constants.frame_size;
    fiber.stacktop = constants.frame_size;
    const frame: *vm_state.StackFrame = @ptrCast(@alignCast(fiber.data));

    frameOfNfunction(frame, keyOf(&probeUnregistered));
    frame.prevframe = 0;
    try traceInto(sink, fiber, value.fromBytes("bare", .string), null);
    expect(std.mem.eql(u8, contents(sink), "  in <nfunction>\n"));

    frameOfNfunction(frame, keyOf(&probeUnnamed));
    frame.prevframe = 0;
    try traceInto(sink, fiber, value.fromBytes("bare", .string), null);
    expect(std.mem.eql(u8, contents(sink), "  in <nfunction> on line 99\n"));
}

/// The decoder is one half of a printer, so the printer runs too, over a real
/// fiber that has stopped at an error. It is the only check here that the
/// descriptor and the loop that consumes it agree about the frames of a live
/// stack.
///
/// `:err-color` is bound explicitly for the reason `test/suite-debug.wattle`
/// gives at `trace-of`: a truthy binding wraps the whole trace in escapes, and
/// an assertion on the leading bytes then depends on ambient state. It is nil
/// here because a contract runs no `cli-main`, which is precisely the kind of
/// thing that is true until it is not.
fn aStacktraceOverARealFiber(failing: *functions.Function) raise.Error!void {
    const fiber = fibers.new(failing, 32, &.{}) catch unreachable;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    defer _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));

    const sink = buffers.new(0);
    gc_alloc.gcroot(wrap.fromBuffer(sink));
    defer _ = gc_alloc.gcunroot(wrap.fromBuffer(sink));

    const resumed = vm_entry.continueFiber(fiber, wrap.fromNil());
    expect(resumed.signal == abi.Signal.@"error");

    vm_state.setdyn("err-color", wrap.fromNil());
    try traceInto(sink, fiber, resumed.value, "trace-frames-test");
    expect(sink.count > 0);
    expect(std.mem.indexOf(u8, contents(sink), "trace-frames-testerror: from a fiber") != null);
    // The failing function is anonymous, and the printer supplies the word.
    expect(std.mem.indexOf(u8, contents(sink), "  in <anonymous> [trace-frames-test] ") != null);

    // And with no prefix, which suppresses the error line entirely.
    try traceInto(sink, fiber, resumed.value, null);
    expect(sink.count > 0);
    expect(std.mem.indexOf(u8, contents(sink), "error: from a fiber") == null);
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() raise.Error!void {
    test_env = harness.coreEnv();
    gc_alloc.gcroot(wrap.fromTable(test_env));

    // The line numbers here are the contract's, not the file's: they are what
    // the registry reports back, and the cases above assert them literally.
    registry.registryPut(keyOf(&probeNamed), "probe", "trace", "trace_frames.zig", probe_line);
    registry.registryPut(keyOf(&probeUnnamed), null, null, "unnamed.zig", 99);

    const named = compileFunction("(defn traced-function [] nil) traced-function");
    const anonymous = compileFunction("(fn [] nil)");
    const failing = compileFunction("(fn [] (error \"from a fiber\"))");

    aNamedFunctionWithASourcemap(named);
    anAnonymousFunction(anonymous);
    aFunctionWithoutASourcemap(named);
    aFunctionWithoutAPc(named);
    theTailCallFlag(named);

    aRegisteredNfunction();
    anUnregisteredNfunction();
    aRegisteredNfunctionWithoutAName();
    aRegisteredNfunctionWithoutALine();
    aRegisteredNfunctionWithoutAPrefix();
    anEmptyFrame();

    try aPrefixedNfunctionRenders();
    try aBareNfunctionRenders();
    try aStacktraceOverARealFiber(failing);
}

pub fn run() void {
    harness.init();
    body() catch @panic("trace_frames: a trace raised unexpectedly");
    vm_lifecycle.deinit();
}
