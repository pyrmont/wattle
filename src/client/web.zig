//! The `web` client: the runtime as a wasm32-wasi reactor a page calls into.
//!
//! `build.zig`'s `webRuntime` roots a reactor at this file. A reactor has no
//! `main`: the host calls `_initialize`, which runs wasi-libc's constructors,
//! and then the functions exported here. `wattle_web_init` starts the runtime
//! and evaluates `eval_line_source` once, and `wattle_web_eval` calls the
//! function that evaluation returned with each submission.
//!
//! A submission runs as a line of the `wattle` REPL runs: through
//! `run-context` in one environment kept across calls, with the REPL's
//! `debugger-on-status`, so a value is printed with `*pretty-format*` and
//! bound to `_`, and an error is printed with its stack trace. Output goes
//! through `fd_write` on descriptors 1 and 2, which the host captures.
//!
//! `wattle_web_alloc` and `wattle_web_free` are how the host places the source
//! in wasm memory before the call.
//!
//! A build with `-Dwasm-image` has no parser or compiler, so it cannot run
//! source. It exports `wattle_web_run_image` in place of `wattle_web_eval`.
//! `wattle_web_init` starts the runtime and keeps the core environment, and
//! `wattle_web_run_image` calls the core function `run-image` on the bytes of
//! an image made by `make-image` and on an array of the arguments the host
//! gives it, as `wattle -i` does. The image is unmarshalled and its `main` is
//! called. The instance stays usable afterwards, so the host can call it
//! again.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const arrays = value.arrays;
const config = @import("config");
const debug = subsystems.debug;
const env_core = subsystems.env;
const fibers = value.fibers;
const functions = subsystems.value.functions;
const gc_alloc = subsystems.gc_alloc;
const lifecycle = subsystems.lifecycle;
const raise = subsystems.raise;
const stdio = subsystems.stdio;
const repr = @import("repr");
const subsystems = @import("subsystems");
const tables = value.tables;
const value = subsystems.value;
const vm_entry = subsystems.vm_entry;
const wrap = subsystems.value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// The source `wattle_web_init` evaluates in the core environment. Its value
/// is `eval-line`.
///
/// `eval-line` takes the source of one submission and returns 0, or 1 when
/// parsing, compiling or running it failed. `run-context` reads the whole
/// submission as one chunk and reaches end of input on the next, so a form
/// left open is reported as a parse error rather than waited for. The three
/// callbacks are the REPL's with a flag set in front of the failing cases;
/// `bad-compile` and `bad-parse` are `run-context`'s defaults.
const eval_line_source =
    \\(def env (make-env))
    \\(fn eval-line [src]
    \\  (var failed false)
    \\  (var sent false)
    \\  (def on-status (debugger-on-status env 1 true))
    \\  (run-context
    \\    {:env env
    \\     :source :repl
    \\     :chunks (fn [buf p]
    \\               (unless sent
    \\                 (set sent true)
    \\                 (buffer/push! buf src)))
    \\     :on-status (fn [f x]
    \\                  (unless (= :dead (fiber/status f)) (set failed true))
    \\                  (on-status f x))
    \\     :on-compile-error (fn [& args] (set failed true) (bad-compile |args))
    \\     :on-parse-error (fn [& args] (set failed true) (bad-parse |args))})
    \\  (flush)
    \\  (eflush)
    \\  (if failed 1 0))
;

// ==========================================================================
// Variables
// ==========================================================================

/// `eval-line`, rooted against collection. Null until `wattle_web_init` has
/// succeeded, and always null in a build without the compiler.
var eval_line: ?*functions.Function = null;

/// `run-image`, rooted against collection. Null until `wattle_web_init` has
/// succeeded, and always null in a build with the compiler.
var run_image: ?*functions.Function = null;

// ==========================================================================
// Public functions
// ==========================================================================

/// Starts the runtime and makes `eval-line`, and returns 0 on success.
///
/// The result is 1 when the runtime does not start, 2 when evaluating
/// `eval_line_source` raised or did not return a function, and 0 without
/// doing anything when a previous call succeeded. The host calls
/// `_initialize` first.
export fn wattle_web_init() i32 {
    if (eval_line != null or run_image != null) return 0;
    return (if (config.compiler) initRaising() else initImageRaising()) catch 2;
}

/// Evaluates `len` bytes of Wattle source at `ptr`, and returns 0, or 1 when
/// the submission failed.
///
/// The value or the error is printed as the REPL prints it. The result is
/// also 1 when `eval-line` itself did not return, and when `wattle_web_init`
/// has not succeeded.
fn wattleWebEval(ptr: [*]const u8, len: usize) callconv(.c) i32 {
    const function = eval_line orelse return 1;
    const source = value.fromBytes(ptr[0..len], .string);
    // Rooted until `pcall` has copied it onto the fiber's stack, since
    // making the fiber allocates.
    gc_alloc.gcroot(source);
    defer _ = gc_alloc.gcunroot(source);
    const resumed = vm_entry.pcall(function, &.{source}, null);
    if (resumed.signal != abi.Signal.ok) return 1;
    if (!repr.checkType(resumed.value, repr.Tag.number)) return 1;
    return if (wrap.toNumber(resumed.value) == 0) 0 else 1;
}

/// Unmarshals `image_len` bytes of image at `image_ptr` and calls its `main`
/// with the strings in the buffer at `args_ptr`, and returns 0, or 1 when the
/// image did not load or `run-image` raised.
///
/// The image is the bytes `make-image` returns. The buffer holds `args_len`
/// bytes in which each argument is followed by a NUL, so an empty buffer is no
/// arguments and the buffer `a\0b\0` is two. `main` receives the arguments as
/// they are and `*args*` is bound to them, as `wattle -i` does, so the first
/// is the program's name by that convention. A raise, from loading the image or
/// from `main`, is printed to standard error with its stack trace, as a
/// submission's is. Standard output and standard error are flushed before the
/// call returns. The result is also 1 when `wattle_web_init` has not
/// succeeded.
fn wattleWebRunImage(image_ptr: [*]const u8, image_len: usize, args_ptr: [*]const u8, args_len: usize) callconv(.c) i32 {
    const function = run_image orelse return 1;
    const image = value.fromBytes(image_ptr[0..image_len], .string);
    const array = arrays.new(0);
    const args = wrap.fromArray(array);
    // Rooted until `fibers.new` has copied them onto the fiber's stack, since
    // making the fiber allocates.
    gc_alloc.gcroot(image);
    gc_alloc.gcroot(args);
    defer _ = gc_alloc.gcunroot(image);
    defer _ = gc_alloc.gcunroot(args);
    defer _ = fflush(null);
    // A previous call that read standard input to its end left the stream at
    // end of file, and one that stopped early left bytes buffered. The host has
    // given this call new input, so the stream starts over.
    _ = fflush(stdio.in());
    clearerr(stdio.in());
    var rest = args_ptr[0..args_len];
    while (std.mem.indexOfScalar(u8, rest, 0)) |end| {
        const argument = value.fromBytes(rest[0..end], .string);
        // The array is rooted and the string is not until it is in the array.
        gc_alloc.gcroot(argument);
        defer _ = gc_alloc.gcunroot(argument);
        arrays.push(array, argument) catch return 1;
        rest = rest[end + 1 ..];
    }
    // `fibers.new` refuses only on an arity mismatch, and `run-image` takes
    // two to three arguments and is given two.
    const fiber = fibers.new(function, 64, &.{ image, args }) catch return 1;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    defer _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));
    const resumed = vm_entry.continueFiber(fiber, wrap.fromNil());
    if (resumed.signal == abi.Signal.ok) return 0;
    debug.stacktraceExt(fiber, resumed.value, "") catch {};
    return 1;
}

comptime {
    if (config.compiler) {
        @export(&wattleWebEval, .{ .name = "wattle_web_eval" });
    } else {
        @export(&wattleWebRunImage, .{ .name = "wattle_web_run_image" });
    }
}

/// Allocates `len` bytes for the host to write source into, or returns null.
export fn wattle_web_alloc(len: usize) ?[*]u8 {
    return @ptrCast(std.c.malloc(len));
}

/// Frees what `wattle_web_alloc` returned. `len` is the length it was given,
/// which `free` does not need.
export fn wattle_web_free(ptr: ?[*]u8, len: usize) void {
    _ = len;
    std.c.free(ptr);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// The C library's flush. A null stream flushes every open one, and an input
/// stream discards what it has buffered.
extern fn fflush(stream: ?*anyopaque) callconv(.c) c_int;

/// The C library's reset of a stream's end-of-file and error flags.
extern fn clearerr(stream: ?*anyopaque) callconv(.c) void;

/// `wattle_web_init`'s work in a build without the compiler: starts the
/// runtime and finds `run-image` in the core environment.
fn initImageRaising() raise.Error!i32 {
    if (try lifecycle.init() != 0) return 1;
    const env = try env_core.coreEnv(null);
    const binding = tables.get(env, value.fromBytes("run-image", .symbol));
    if (!repr.checkType(binding, repr.Tag.table)) return 2;
    const function = tables.getKeyword(wrap.toTable(binding), "value");
    if (!repr.checkType(function, repr.Tag.function)) return 2;
    gc_alloc.gcroot(function);
    run_image = wrap.toFunction(function);
    return 0;
}

/// `wattle_web_init`'s work, with a raise left to the caller.
fn initRaising() raise.Error!i32 {
    if (try lifecycle.init() != 0) return 1;
    const env = try env_core.coreEnv(null);
    var result = wrap.fromNil();
    const flags = try env_core.dobytesImpl(env, eval_line_source, "web", &result);
    if (flags != 0 or !repr.checkType(result, repr.Tag.function)) return 2;
    gc_alloc.gcroot(result);
    eval_line = wrap.toFunction(result);
    return 0;
}
