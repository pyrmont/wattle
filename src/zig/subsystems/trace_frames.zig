//! Decoding one stack frame, and printing a stack trace out of the results.
//!
//! `janet_stacktrace_ext` in `src/core/debug.c` was two jobs braided together:
//! a walk over the fiber chain and its frames, and a rendering of each frame
//! into text. Phase 8 took the decoding in between, which is the part that
//! reads a `JanetStackFrame`; its output is `JanetTraceFrame` in
//! `src/core/state.h`, where every string points into a funcdef or the
//! cfunction registry and nothing allocates, holds a Janet value, or can fail.
//!
//! **Phase 10 Part 7 took the other two, and the rendering was the one this
//! header said would stay.** The reason it gave was that `janet_eprintf` is
//! variadic; the reason it turns out to be is narrower. Zig cannot *define* a
//! C variadic on every target this project builds for, but calling one is
//! ordinary, so the rendering goes through `janet_dynprintf` exactly as before.
//! What could not come across is the *second argument*: `stderr` is a macro
//! that translate-c renders three incompatible ways, one of which cannot be
//! referenced at all. `io.c` keeps a one-line `stdio.err` for it.
//!
//! The walk came too, and lost its allocation on the way: the C original
//! collected the fiber chain into a `janet_v_` vector to walk it backwards,
//! where recursing to the deepest child and printing on the way out gives the
//! same innermost-first order with nothing to free. That matters because a
//! `tostring` callback reached through `%v` can still panic through C, and the
//! jump went straight past the C original's `janet_v_free`.
//!
//! **Why this is worth a seam at all.** `debug.c` decodes a stack frame twice,
//! independently: here, and in `doframe`, which builds the table `debug/stack`
//! returns. The two read the same facts through separately written code, and
//! they have already drifted — the version below tests `NULL != reg` before
//! using the registry entry and `doframe` does not, which is a latent null
//! dereference recorded in `FOUND.md`. `doframe` cannot consume this structure
//! yet, because it is `janet_table_put` and `janet_ckeywordv` from end to end
//! and Janet value construction is Phase 8. It becomes the second consumer when
//! that lands, and the duplication ends there.
//!
//! **The one subtlety, which the shape of `JanetTraceFrame` exists to
//! preserve.** The name and the location are classified separately, because the
//! C original classifies them separately. `reg` is set whenever the registry
//! has an entry for the cfunction, but the name is printed only when that entry
//! *also* has a name, while the location is printed whenever the entry has a
//! positive source line. So a registry entry with a null name and a source line
//! prints `<cfunction> on line 42`, and one tag covering both would lose it.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const stdio = @import("stdio.zig");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");
const io_core = @import("io_core.zig");

/// `src/core/util.h`, declared here rather than translated, for the reason
/// `abi.zig` gives: that header reaches `dlfcn.h` on any target it does not
/// recognise as Windows, which breaks the Windows cross-compile of every Zig
/// object at once. `JanetCFunRegistry` itself comes from `state.h` and is
/// translated normally, so no type is being restated here — only the function.
///
/// It cannot raise: a lazy sort of the registry followed by a linear scan and a
/// binary search. It returns null for a cfunction that was never passed through
/// `janet_cfuns`, which is the case the caller below has to handle.
extern fn janet_registry_get(key: c.JanetCFunction) [*c]c.JanetCFunRegistry;

const name_none: u8 = @intCast(c.JANET_TRACE_NAME_NONE);
const name_anonymous: u8 = @intCast(c.JANET_TRACE_NAME_ANONYMOUS);
const name_function: u8 = @intCast(c.JANET_TRACE_NAME_FUNCTION);
const name_cfunction: u8 = @intCast(c.JANET_TRACE_NAME_CFUNCTION);
const name_cfunction_bare: u8 = @intCast(c.JANET_TRACE_NAME_CFUNCTION_BARE);

const loc_none: u8 = @intCast(c.JANET_TRACE_LOC_NONE);
const loc_sourcemap: u8 = @intCast(c.JANET_TRACE_LOC_SOURCEMAP);
const loc_pc: u8 = @intCast(c.JANET_TRACE_LOC_PC);
const loc_cfun_line: u8 = @intCast(c.JANET_TRACE_LOC_CFUN_LINE);

const tailcall: i32 = @intCast(c.JANET_STACKFRAME_TAILCALL);

/// Decode `frame` into `out`. Total: every frame produces a descriptor, and a
/// frame that names nothing produces `NAME_NONE` with `LOC_NONE`, which renders
/// as a bare `  in` line exactly as the C original does.
pub fn janet_trace_frameImpl(frame: *c.JanetStackFrame, out: *c.JanetTraceFrame) raise.Raising(void) {
    out.* = .{
        .name = null,
        .name_prefix = null,
        .source = null,
        .pc = 0,
        .line = 0,
        .column = 0,
        .name_kind = name_none,
        .loc_kind = loc_none,
        .tail = @intFromBool(frame.flags & tailcall != 0),
    };

    if (frame.func != null) {
        const def = frame.func.*.def;
        if (def.*.name != null) {
            out.name_kind = name_function;
            out.name = def.*.name;
        } else {
            out.name_kind = name_anonymous;
        }
        out.source = def.*.source;

        // A funcdef frame with a null pc reports no location at all. The C
        // original arrives there by falling out of `frame->func && frame->pc`
        // into an `else if (NULL != reg)` that cannot fire, `reg` being null on
        // every path that has a function.
        if (frame.pc != null) {
            const offset = @divExact(
                @intFromPtr(frame.pc) - @intFromPtr(def.*.bytecode),
                @sizeOf(u32),
            );
            if (def.*.sourcemap != null) {
                const mapping = def.*.sourcemap[offset];
                out.loc_kind = loc_sourcemap;
                out.line = mapping.line;
                out.column = mapping.column;
            } else {
                out.loc_kind = loc_pc;
                out.pc = @intCast(offset);
            }
        }
        return;
    }

    // A cframe stores the cfunction in the pc slot. Nothing else in the runtime
    // reads it as a code pointer, which is why the cast is here and not in
    // `fiber.h` beside the frame accessors.
    const cfun: c.JanetCFunction = @ptrFromInt(@intFromPtr(frame.pc));
    if (cfun == null) return;

    const reg = janet_registry_get(cfun);
    if (reg != null and reg.*.name != null) {
        out.name_kind = name_cfunction;
        out.name = reg.*.name;
        out.name_prefix = reg.*.name_prefix;
        // Only the named branch reports a source. An entry with a source file
        // and no name prints "<cfunction>" and nothing more, and leaving
        // `source` null here is what keeps that true.
        out.source = reg.*.source_file;
    } else {
        out.name_kind = name_cfunction_bare;
    }

    // Deliberately outside the branch above: the location comes from the entry
    // existing, the name from the entry having a name. See the header comment.
    if (reg != null and reg.*.source_line > 0) {
        out.loc_kind = loc_cfun_line;
        out.line = reg.*.source_line;
    }
}

export fn janet_trace_frame(frame: *c.JanetStackFrame, out: *c.JanetTraceFrame) callconv(.c) void {
    raise.reported(janet_trace_frameImpl(frame, out));
}

// ==========================================================================
// Stack traces
// ==========================================================================

/// The handle `janet_dynprintf` falls back to when `:err` is unbound.
///
/// `stderr` cannot be named from Zig portably, and the reason is worth
/// recording because it is not the usual one. Translate-c gives it a
/// different shape on each of this project's three platforms -- an inline
/// function on macOS, a variable of opaque type on musl, and on mingw a
/// container-level constant initialised by a call to an extern function --
/// and the third is not a shape a caller can adapt to: referencing
/// `c.stderr` there fails with "comptime call of extern function" before the
/// value is used for anything. So `io.c` keeps a one-line accessor beside
/// `janet_dynprintf`, which is C for its own reasons until Part 17.
///
/// Found by the cross-compile entries of the acceptance matrix, which is what
/// they are for: all twenty-four native entries passed with the Zig-side
/// version that only handled the first two shapes.

/// `janet_eprintf`, which is a macro in `janet.h` over the C-variadic
/// `janet_dynprintf`. Zig cannot *define* a variadic function on every target
/// this project builds for -- that is the limit Part 4 recorded -- but calling
/// one is ordinary, so the macro is written out here rather than worked
/// around. The dynamic binding `:err` redirects the whole trace, which is what
/// makes this different from writing to the handle directly.
inline fn eprintf(comptime format: [:0]const u8, args: anytype) void {
    // `pp_format.dynprintf` can raise: `(dyn :err)` may be a Janet function, and
    // calling it can. This position cannot carry one -- it is a trace or a
    // diagnostic on the way out -- so the raise is reported exactly as the C
    // face reported it before Part 18 deleted the variadic.
    raise.reported(pp_format.dynprintf("err", @ptrCast(@alignCast(stdio.err())), format, args));
}

const TraceState = struct {
    prefix: [*c]const u8,
    error_text: [*c]const u8,
    wrote_error: bool,
};

/// Print a fiber chain innermost-first.
///
/// The C original collected the chain into a `janet_v_` vector and walked it
/// backwards. Recursing to the deepest child and printing on the way back out
/// produces the same order with no allocation -- which matters here beyond
/// tidiness: this file is jump-transparent, `eprintf` renders a value through
/// an abstract type's `tostring`, and a panic there jumped straight past the
/// C original's `janet_v_free`.
fn traceChain(fiber: *c.JanetFiber, state: *TraceState) raise.Raising(void) {
    if (fiber.child != null) try traceChain(fiber.child, state);

    var index = fiber.frame;
    while (index > 0) {
        const frame: *c.JanetStackFrame = @ptrCast(@alignCast(fiber.data + @as(usize, @intCast(index)) - @as(usize, c.JANET_FRAME_SIZE)));
        var descriptor: c.JanetTraceFrame = undefined;
        index = frame.prevframe;
        try janet_trace_frameImpl(frame, &descriptor);

        // The error line is printed once, above the first frame -- not before
        // the loop, so that a fiber with no frames prints nothing at all.
        if (!state.wrote_error) {
            const status = c.janet_fiber_status(fiber);
            eprintf("%s%s: %s\n", .{
                if (state.prefix != null) state.prefix else @as([*c]const u8, ""),
                c.janet_status_names[@intCast(status)],
                if (state.error_text != null) state.error_text else c.janet_status_names[@intCast(status)],
            });
            state.wrote_error = true;
        }

        eprintf("  in", .{});

        switch (descriptor.name_kind) {
            c.JANET_TRACE_NAME_ANONYMOUS => eprintf(" %s", .{@as([*c]const u8, "<anonymous>")}),
            c.JANET_TRACE_NAME_FUNCTION => eprintf(" %s", .{descriptor.name}),
            c.JANET_TRACE_NAME_CFUNCTION => if (descriptor.name_prefix != null) {
                eprintf(" %s/%s", .{ descriptor.name_prefix, descriptor.name });
            } else {
                eprintf(" %s", .{descriptor.name});
            },
            c.JANET_TRACE_NAME_CFUNCTION_BARE => eprintf(" <cfunction>", .{}),
            else => {},
        }

        // `source` is null in exactly the cases that printed no source before:
        // an unnamed cfunction, and a frame that names nothing.
        if (descriptor.source != null) eprintf(" [%s]", .{descriptor.source});
        if (descriptor.tail != 0) eprintf(" (tail call)", .{});

        switch (descriptor.loc_kind) {
            c.JANET_TRACE_LOC_SOURCEMAP => eprintf(" on line %d, column %d", .{ descriptor.line, descriptor.column }),
            c.JANET_TRACE_LOC_PC => eprintf(" pc=%d", .{descriptor.pc}),
            // The `long` widening is the original's. Janet's "%d" reads an
            // int32_t, so it is a width mismatch; it is preserved rather than
            // fixed, and recorded in FOUND.md.
            c.JANET_TRACE_LOC_CFUN_LINE => eprintf(" on line %d", .{@as(c_long, descriptor.line)}),
            else => {},
        }
        eprintf("\n", .{});
    }
}

pub fn stacktraceExt(
    fiber: [*c]c.JanetFiber,
    err: c.Janet,
    prefix: [*c]const u8,
) raise.Raising(void) {
    var state = TraceState{
        .prefix = prefix,
        .error_text = @ptrCast(c.janet_to_string(err)),
        // A null prefix means "skip the error line", so it counts as already
        // written.
        .wrote_error = prefix == null,
    };
    const print_color = c.janet_truthy(c.janet_dyn("err-color")) != 0;
    if (print_color) eprintf("\x1b[31m", .{});
    if (fiber != null) try traceChain(fiber, &state);
    if (print_color) eprintf("\x1b[0m", .{});
}

export fn janet_stacktrace_ext(
    fiber: [*c]c.JanetFiber,
    err: c.Janet,
    prefix: [*c]const u8,
) callconv(.c) void {
    raise.reported(stacktraceExt(fiber, err, prefix));
}

export fn janet_stacktrace(fiber: [*c]c.JanetFiber, err: c.Janet) callconv(.c) void {
    // A nil error prints no error line at all; anything else prints one with
    // an empty prefix.
    const prefix: [*c]const u8 = if (c.janet_checktype(err, c.JANET_NIL) != 0) null else "";
    raise.reported(stacktraceExt(fiber, err, prefix));
}
