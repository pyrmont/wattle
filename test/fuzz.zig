//! The four fuzz targets, and Phase 11 Part 23's migration of
//! `test/fuzzers/*.c`.
//!
//! ## What they were
//!
//! Four `LLVMFuzzerTestOneInput` entry points over `janet.h`: the parser, the
//! compiler, `janet_dobytes` and `janet_unmarshal`. **No build system in this
//! tree ever named one.** Not `build.zig`, not `Makefile`, not `meson.build`,
//! and nothing in `port/` — they were built, if at all, by a `clang
//! -fsanitize=fuzzer` somebody typed elsewhere. So this is not a port of a
//! working instrument; it is the first time these targets have been reachable
//! from `zig build`.
//!
//! ## Why a translation would abort on almost every input
//!
//! Each C original opens a `janet_try_init` scope, calls its entry point, and
//! calls `janet_restore`. That is right for C and wrong here, and the reason
//! is the whole shape of Phase 10's hinge: three of the four entry points are
//! `raise.reported` or `raise.panicking(...).face` wrappers, so a raise leaves
//! a *report* rather than travelling, and `janet_restore` aborts on an
//! outstanding one. A fuzzer's inputs are mostly malformed, so a faithful
//! translation would die with
//!
//!     janet abort: a raise was reported to a C caller and never consumed
//!
//! on roughly its first interesting input, naming neither the target nor the
//! byte string that got there.
//!
//! So each target reaches the *raising* function by import and reads the
//! refusal as a value, which is `swallowed.py`'s rule applied to a caller that
//! did not exist yet:
//!
//! | target | the face a translation would call | what this calls |
//! | --- | --- | --- |
//! | parser | `janet_parser_consume`, `janet_parser_eof` | `parser_core.consumeChecked`, `parser_core.eofChecked` |
//! | compile | `janet_compile` → `janet_compile_lint` | `compiler_primitives.janet_compile_lintImpl` |
//! | dobytes | `janet_dobytes` | `core_env.janet_dobytesImpl` |
//! | unmarshal | `janet_unmarshal` | `marsh.unmarshal` |
//!
//! `harness.raised` is the protected scope, unchanged from what sixty-five
//! contracts use it for. A raise is the expected outcome here rather than the
//! asserted one, so nothing is asserted about the payload: what a fuzz target
//! is looking for is a crash, an unreachable, or a leak — not a wrong answer.
//!
//! ## Running them
//!
//!     zig build fuzz            # each target once over its corpus: a smoke check
//!     zig build fuzz --fuzz     # the actual campaign
//!
//! The first is what `zig build test` runs, and it is there for the reason the
//! C originals died of: a fuzz target nothing executes is a file, not an
//! instrument.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
const parser_core = subsystems.parser_core;
const compiler_primitives = subsystems.compiler_primitives;
const core_env = subsystems.core_env;
const marsh = subsystems.marsh;

/// The largest input a target is handed.
///
/// The C originals took whatever libFuzzer gave them. `Smith.slice` fills a
/// caller-owned buffer, so the bound is here instead; 4 KiB is well past the
/// sizes that reach interesting states in any of the four and keeps one input
/// cheap enough that a campaign is dominated by the runtime it drives rather
/// than by the bytes it generates.
const max_input = 4096;

/// One Janet per input, which is what the C originals did.
///
/// It is the expensive choice and it is the right one for a fuzzer: a runtime
/// carried across inputs makes a crash depend on the inputs before it, and a
/// reproducer that needs a history is not a reproducer. `janet_deinit` also
/// frees the heap, so a leak this finds is attributable to the one input.
fn session(comptime body: fn (env: *c.JanetTable, data: []const u8) void, data: []const u8) void {
    _ = c.janet_init();
    defer c.janet_deinit();
    body(c.janet_core_env(null).?, data);
}

// ------------------------------------------------------------------- parser

/// Feed untrusted bytes to the parser one at a time.
///
/// The original is `fuzz_dostring.c`, whose name says `dostring` and whose
/// body and comment both say parser. The name is not carried across: what it
/// does is what it is called here, and `dobytes` below is the target the old
/// name suggests.
fn parserBody(env: *c.JanetTable, data: []const u8) void {
    _ = env;
    var parser: c.JanetParser = undefined;
    c.janet_parser_init(&parser);
    defer c.janet_parser_deinit(&parser);

    for (data) |byte| {
        switch (c.janet_parser_status(&parser)) {
            c.JANET_PARSE_DEAD, c.JANET_PARSE_ERROR => return,
            else => {},
        }
        _ = harness.raised(parser_core.consumeChecked, .{ &parser, byte });

        // Drain, so that a form that parses is also *built*. The C original
        // left them in the parser, which meant the value constructors were
        // never reached for this target at all.
        while (c.janet_parser_has_more(&parser) != 0) _ = c.janet_parser_produce(&parser);
    }

    _ = harness.raised(parser_core.eofChecked, .{&parser});
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

// ------------------------------------------------------------------ compile

/// Parse untrusted bytes and compile every form they produce.
fn compileBody(env: *c.JanetTable, data: []const u8) void {
    var parser: c.JanetParser = undefined;
    c.janet_parser_init(&parser);
    defer c.janet_parser_deinit(&parser);

    const where = c.janet_cstring("fuzz");

    for (data) |byte| {
        if (c.janet_parser_status(&parser) == c.JANET_PARSE_ERROR) return;
        _ = harness.raised(parser_core.consumeChecked, .{ &parser, byte });
        while (c.janet_parser_has_more(&parser) != 0) {
            const form = c.janet_parser_produce(&parser);
            // The result carries its own error field for an ordinary compile
            // failure; the scope is for the refusals that are not ordinary.
            _ = harness.raised(
                compiler_primitives.janet_compile_lintImpl,
                .{ form, env, where, null },
            );
        }
    }
}

test "compile" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buffer: [max_input]u8 = undefined;
            const length = smith.slice(&buffer);
            session(compileBody, buffer[0..length]);
        }
    }.one, .{});
}

// ------------------------------------------------------------------ dobytes

/// Parse, compile and *run* untrusted bytes.
///
/// The deepest of the four, and the only one that reaches the interpreter.
fn dobytesBody(env: *c.JanetTable, data: []const u8) void {
    var out: c.Janet = c.janet_wrap_nil();
    _ = harness.raised(core_env.janet_dobytesImpl, .{
        env,
        data.ptr,
        @as(i32, @intCast(data.len)),
        "<fuzz>",
        &out,
    });
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

// ---------------------------------------------------------------- unmarshal

/// Deserialize untrusted bytes.
///
/// The target with the most to say: `marsh.zig` reconstructs funcdefs, envs
/// and fibers from a byte stream, and `FOUND.md` already carries three defects
/// found by reading it. A registry is looked up because the C original did —
/// it is what lets a stream name an abstract type or a cfunction.
fn unmarshalBody(env: *c.JanetTable, data: []const u8) void {
    const registry = c.janet_env_lookup(env);
    var next: [*c]const u8 = null;
    _ = harness.raised(marsh.unmarshal, .{ data.ptr, data.len, 0, registry, &next });
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
