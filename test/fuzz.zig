//! The four fuzz targets: the parser, the compiler, `env.dobytes` and
//! `marsh.unmarshal`.
//!
//! ## Each target calls the raising function rather than the published one
//!
//! Three of the four published entry points are `raise.toAbi` or
//! `raise.panicking(...).abi` wrappers, so a raise leaves a *report* rather
//! than travelling, and `signal.restore` aborts on an outstanding one. A
//! target that opened a protected scope, called a published entry point and
//! closed the scope again would therefore die with
//!
//!     wattle abort: a raise was reported across the C ABI and never consumed
//!
//! on roughly its first interesting input, naming neither the target nor the
//! byte string that got there. A fuzzer's inputs are mostly malformed, so that
//! is most of them.
//!
//! So each target reaches the *raising* function by import and reads the
//! refusal as a value, which is the rule `res/check/swallowed.janet`
//! applies to every caller under `src/`:
//!
//! | target | what this calls |
//! | --- | --- |
//! | parser | `parser_core.consumeChecked`, `parser_core.eofChecked` |
//! | compile | `compiler_primitives.compileLintImpl` |
//! | dobytes | `core_env.dobytesImpl` |
//! | unmarshal | `marsh.unmarshal` |
//!
//! `harness.raised` is the protected scope, the same one the sixty-five
//! contracts open. A raise is the expected outcome here rather than the
//! asserted one, so nothing is asserted about the payload: what a fuzz target
//! looks for is a crash, an unreachable or a leak rather than a wrong result.
//!
//! ## Running them
//!
//!     zig build fuzz          # each target once over its corpus
//!     zig build fuzz --fuzz   # the campaign
//!
//! `zig build test` runs the first, so that every target is executed on an
//! ordinary test run rather than only when a campaign is asked for.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const compiler_primitives = subsystems.compiler_primitives;
const core_env = subsystems.env;
const harness = @import("harness.zig");
const marsh = subsystems.marsh;
const parser_core = subsystems.parser;
const repr = @import("repr");
const strings = @import("subsystems").value.strings;
const subsystems = @import("subsystems");
const tables = @import("subsystems").value.tables;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// The largest input a target is handed.
///
/// `Smith.slice` fills a caller-owned buffer, so the bound is the buffer's.
/// 4 KiB is well past the sizes that reach interesting states in any of the
/// four, and it keeps one input cheap enough that a campaign is dominated by
/// the runtime it drives rather than by the bytes it generates.
const max_input = 4096;

// ==========================================================================
// Private functions
// ==========================================================================

/// Parse untrusted bytes and compile every form they produce.
fn compileBody(env: *tables.Table, data: []const u8) void {
    var parser: parser_core.Parser = undefined;
    parser_core.parserInit(&parser);
    defer parser_core.parserDeinit(&parser);

    const where = strings.cstring("fuzz");

    for (data) |byte| {
        if (parser_core.parserStatus(&parser) == parser_core.ParserStatus.@"error") return;
        _ = harness.raised(parser_core.consumeChecked, .{ &parser, byte });
        while (parser_core.parserHasMore(&parser)) {
            const form = parser_core.parserProduce(&parser);
            // An ordinary compile failure comes back in the result's own
            // error field; the scope is for the refusals that are not
            // ordinary.
            _ = harness.raised(
                compiler_primitives.compileLintImpl,
                .{ form, env, where, null },
            );
        }
    }
}

/// Parse, compile and *run* untrusted bytes.
///
/// The deepest of the four, and the only one that reaches the interpreter.
fn dobytesBody(env: *tables.Table, data: []const u8) void {
    var out: repr.Value = wrap.fromNil();
    _ = harness.raised(core_env.dobytesImpl, .{
        env,
        data,
        "<fuzz>",
        &out,
    });
}

/// Feed untrusted bytes to the parser one at a time.
///
/// Each form that parses is also drained, so that the value constructors are
/// reached rather than left unbuilt inside the parser. `dobytes` is the
/// target that goes on to compile and run what this one only parses.
fn parserBody(env: *tables.Table, data: []const u8) void {
    _ = env;
    var parser: parser_core.Parser = undefined;
    parser_core.parserInit(&parser);
    defer parser_core.parserDeinit(&parser);

    for (data) |byte| {
        switch (parser_core.parserStatus(&parser)) {
            parser_core.ParserStatus.dead, parser_core.ParserStatus.@"error" => return,
            else => {},
        }
        _ = harness.raised(parser_core.consumeChecked, .{ &parser, byte });

        // Drain, so that a form that parses is also *built*: a form left in
        // the parser never reaches the value constructors.
        while (parser_core.parserHasMore(&parser)) _ = parser_core.parserProduce(&parser);
    }

    _ = harness.raised(parser_core.eofChecked, .{&parser});
}

/// Runs `body` over `data` in a runtime of its own.
///
/// One Janet per input is the expensive choice and the right one for a
/// fuzzer: a runtime reused across inputs makes a crash depend on the inputs
/// before it, and a reproducer that needs a history is not a reproducer.
/// `vm_lifecycle.deinit` also frees the heap, so a leak this finds is
/// attributable to the one input.
fn session(comptime body: fn (env: *tables.Table, data: []const u8) void, data: []const u8) void {
    harness.init();
    defer vm_lifecycle.deinit();
    body(harness.coreEnv(), data);
}

/// Deserialize untrusted bytes.
///
/// The deepest reach of the four into what a byte string can ask for:
/// `marsh.zig` reconstructs funcdefs, envs and fibers from a stream, and every
/// length and index it uses comes out of that stream. A registry is looked up
/// and passed because that is what lets a stream name an abstract type or an
/// nfunction, so leaving it out would put those two paths out of reach.
fn unmarshalBody(env: *tables.Table, data: []const u8) void {
    const registry = marsh.envLookup(env);
    var next: [*]const u8 = undefined;
    _ = harness.raised(marsh.unmarshal, .{ data, 0, registry, &next });
}

// ==========================================================================
// Tests
// ==========================================================================

test "compile" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buffer: [max_input]u8 = undefined;
            const length = smith.slice(&buffer);
            session(compileBody, buffer[0..length]);
        }
    }.one, .{});
}

test "dobytes" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buffer: [max_input]u8 = undefined;
            const length = smith.slice(&buffer);
            session(dobytesBody, buffer[0..length]);
        }
    }.one, .{});
}

test "parser" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buffer: [max_input]u8 = undefined;
            const length = smith.slice(&buffer);
            session(parserBody, buffer[0..length]);
        }
    }.one, .{});
}

test "unmarshal" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buffer: [max_input]u8 = undefined;
            const length = smith.slice(&buffer);
            session(unmarshalBody, buffer[0..length]);
        }
    }.one, .{});
}
