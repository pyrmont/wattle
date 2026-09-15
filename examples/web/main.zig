//! The `web` client: the runtime as a wasm32-wasi reactor a page calls into.
//!
//! `build.zig`'s `web` step roots a reactor at this file. A reactor has no
//! `main`: the host calls `_initialize`, which runs wasi-libc's constructors,
//! and then the functions exported here. `janet_web_init` starts the runtime
//! and evaluates `eval_line_source` once, and `janet_web_eval` calls the
//! function that evaluation returned with each submission.
//!
//! A submission runs as a line of the `wattle` REPL runs: through
//! `run-context` in one environment kept across calls, with the REPL's
//! `debugger-on-status`, so a value is printed with `*pretty-format*` and
//! bound to `_`, and an error is printed with its stack trace. Output goes
//! through `fd_write` on descriptors 1 and 2, which the host captures.
//!
//! `janet_web_alloc` and `janet_web_free` are how the host places the source
//! in wasm memory before the call.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const env_core = subsystems.env;
const functions = subsystems.value.functions;
const gc_alloc = subsystems.gc_alloc;
const lifecycle = subsystems.lifecycle;
const raise = subsystems.raise;
const repr = @import("repr");
const subsystems = @import("subsystems");
const value = subsystems.value;
const vm_entry = subsystems.vm_entry;
const wrap = subsystems.value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// The source `janet_web_init` evaluates in the core environment. Its value
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
    \\                 (buffer/push buf src)))
    \\     :on-status (fn [f x]
    \\                  (unless (= :dead (fiber/status f)) (set failed true))
    \\                  (on-status f x))
    \\     :on-compile-error (fn [& args] (set failed true) (bad-compile ;args))
    \\     :on-parse-error (fn [& args] (set failed true) (bad-parse ;args))})
    \\  (flush)
    \\  (eflush)
    \\  (if failed 1 0))
;

// ==========================================================================
// Variables
// ==========================================================================

/// `eval-line`, rooted against collection. Null until `janet_web_init` has
/// succeeded.
var eval_line: ?*functions.Function = null;

// ==========================================================================
// Public functions
// ==========================================================================

/// Starts the runtime and makes `eval-line`, and returns 0 on success.
///
/// The result is 1 when the runtime does not start, 2 when evaluating
/// `eval_line_source` raised or did not return a function, and 0 without
/// doing anything when a previous call succeeded. The host calls
/// `_initialize` first.
export fn janet_web_init() i32 {
    if (eval_line != null) return 0;
    return initRaising() catch 2;
}

/// Evaluates `len` bytes of Janet source at `ptr`, and returns 0, or 1 when
/// the submission failed.
///
/// The value or the error is printed as the REPL prints it. The result is
/// also 1 when `eval-line` itself did not return, and when `janet_web_init`
/// has not succeeded.
export fn janet_web_eval(ptr: [*]const u8, len: usize) i32 {
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

/// Allocates `len` bytes for the host to write source into, or returns null.
export fn janet_web_alloc(len: usize) ?[*]u8 {
    return @ptrCast(std.c.malloc(len));
}

/// Frees what `janet_web_alloc` returned. `len` is the length it was given,
/// which `free` does not need.
export fn janet_web_free(ptr: ?[*]u8, len: usize) void {
    _ = len;
    std.c.free(ptr);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// `janet_web_init`'s work, with a raise left to the caller.
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
