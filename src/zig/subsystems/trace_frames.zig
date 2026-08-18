//! Decoding one stack frame far enough to print a line of a stack trace.
//!
//! `janet_stacktrace_ext` in `src/core/debug.c` is two jobs braided together: a
//! walk over the fiber chain and its frames, and a rendering of each frame into
//! text. The rendering stays in C — `janet_eprintf` is variadic, formats Janet
//! values, and writes to a stream taken from a dynamic binding, so it can panic,
//! and Phase 5's third rule keeps exact diagnostics on that side of the line.
//! The walk stays in C too, because it is four lines and one of them is
//! `janet_v_push`.
//!
//! What moves is the decoding in between, which is the part that reads a
//! `JanetStackFrame` — the structure Part 7 made Zig's business. The output is
//! `JanetTraceFrame` in `src/core/state.h`: every string in it points into a
//! funcdef or the cfunction registry, and nothing here allocates, holds a Janet
//! value, or can fail.
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
export fn janet_trace_frame(frame: *c.JanetStackFrame, out: *c.JanetTraceFrame) callconv(.c) void {
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
