//! jump-transparent
//!
//! `debug/stack`'s view of a stack frame: the table `doframe` builds in
//! `src/core/debug.c`. This is the second half of Part 5 of Phase 9, and it is
//! the consequence Phase 8 left available here.
//!
//! ## What this closes
//!
//! `debug.c` decoded a stack frame twice, independently: once for
//! `janet_stacktrace_ext`, which Phase 8 moved to `trace_frames.zig`, and once
//! in `doframe`. Written separately, they had drifted — `janet_trace_frame`
//! tests `NULL != reg` before reading the cfunction registry entry and
//! `doframe` did not, which is a null dereference `FOUND.md` records and which
//! `debug/stack` reaches for any cframe whose function was never passed through
//! `janet_cfuns`. `janet_call`'s dirty-stack placeholder is one such frame.
//!
//! `janet_trace_frame` is now called from here, so the registry lookup, the
//! name classification, and the source-map read happen once in the tree and the
//! null check comes with them. `trace_frames.zig` said this would happen "when
//! Janet value construction is Zig"; it is, since Phase 8.
//!
//! The call goes through the symbol table rather than through an import, which
//! is Part 4's rule and has the same benefit: `-Dtrace-frames=c` is honoured by
//! the linker, so the two selectors stay independent and the C decoder can
//! still answer for `debug/stack`.
//!
//! ## What the descriptor deliberately does not carry
//!
//! `JanetTraceFrame` exists to print one line of a stack trace, and
//! `debug/stack` wants more than a line. Three things are read from the funcdef
//! directly, and each is a place the two consumers genuinely differ rather than
//! a gap in the descriptor:
//!
//!  - **`:pc`.** `doframe` reports the bytecode offset for every frame that has
//!    a function and a program counter. The descriptor carries `pc` only when
//!    there is no source map, because a stack trace prints one *or* the other.
//!  - **`:slots` and `:locals`.** Neither has anything to do with printing a
//!    line, and both need the funcdef's symbol map and the frame's registers.
//!  - **`:source` for a Janet frame.** `doframe` emits it only inside the
//!    `func && pc` branch; the descriptor sets it for any frame with a
//!    function. Reproduced as `doframe` has it.
//!
//! Two more differences are in the other direction, and both are preserved by
//! reading the descriptor's *kind* rather than its fields. A registry entry with
//! a source line and no name gives the descriptor `LOC_CFUN_LINE`, and a stack
//! trace prints `<cfunction> on line 42`; `doframe` puts the line inside the
//! named branch and reports nothing for that frame, so the check here is on
//! `NAME_CFUNCTION` first. And `doframe` hard-codes `:source-column` to 1 for a
//! cfunction, which is not a column the descriptor has or could have.
//!
//! ## Raising
//!
//! Nothing here raises deliberately, and everything here allocates. The
//! allocators end a failure in `JANET_OUT_OF_MEMORY`, which exits rather than
//! jumping — checked, not assumed — so the only way out of this frame is the
//! normal one. The marker is present because `janet_table_put` and
//! `janet_array` are ordinary runtime calls and the file holds nothing that
//! would need releasing if one of them ever did jump.

const abi = @import("abi");
const c = abi.c;

/// `janet.h`'s frame size. `janet_stack_frame` is a function-like macro over it
/// and does not survive translation.
const frame_size: usize = c.JANET_FRAME_SIZE;

/// Provided by `src/core/debug.c` or `src/zig/subsystems/trace_frames.zig`,
/// whichever `-Dtrace-frames` selects. Declared through `abi.zig`'s types, so
/// the `JanetStackFrame` handed over is the same Zig type on both sides.
extern fn janet_trace_frame(frame: *c.JanetStackFrame, out: *c.JanetTraceFrame) callconv(.c) void;

/// `src/core/util.h`, declared here rather than translated, for the reason
/// `abi.zig` gives. It is `memcpy` with a zero-length guard, which is what
/// `doframe` needs for a funcdef with no slots.
extern fn safe_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void;

const name_function: u8 = @intCast(c.JANET_TRACE_NAME_FUNCTION);
const name_cfunction: u8 = @intCast(c.JANET_TRACE_NAME_CFUNCTION);
const loc_sourcemap: u8 = @intCast(c.JANET_TRACE_LOC_SOURCEMAP);
const loc_cfun_line: u8 = @intCast(c.JANET_TRACE_LOC_CFUN_LINE);

/// `janet_ckeywordv` from `janet.h`, which is a macro over `janet_csymbol`:
/// keywords and symbols are interned by the same function and differ only in
/// how they are wrapped.
inline fn kw(name: [*c]const u8) c.Janet {
    return c.janet_wrap_keyword(c.janet_csymbol(name));
}

/// `janet_wrap_integer` spelled out. The macro is absent from a
/// `-Dnanbox=false` build, which is the defect `FOUND.md` records against
/// `wrap.c`; `value_wrap_extern.zig` writes it the same way and for the same
/// reason.
inline fn wrapInteger(n: i32) c.Janet {
    return c.janet_wrap_number(@floatFromInt(n));
}

inline fn put(t: [*c]c.JanetTable, name: [*c]const u8, value: c.Janet) void {
    c.janet_table_put(t, kw(name), value);
}

/// `func->envs[i]`. `envs` is a flexible array member and translate-c drops it,
/// so the slot is computed the way `janet_function` allocates it: immediately
/// after the header. `gc_mark.zig` and `vm_run.zig` read the same slots the
/// same way.
inline fn funcEnv(func: [*c]c.JanetFunction, i: u32) [*c]c.JanetFuncEnv {
    const base = @intFromPtr(func) +% @sizeOf(c.JanetFunction);
    const slot: *[*c]c.JanetFuncEnv = @ptrFromInt(base +% @as(usize, i) *% @sizeOf(*c.JanetFuncEnv));
    return slot.*;
}

/// Extract info from one stack frame.
///
/// Exported with hidden visibility, which is what the C build's
/// `-fvisibility=hidden` already gives it: it is declared in `state.h` rather
/// than in `janet.h`, so a plain `export` would widen the shared library's
/// symbol set relative to the other selector. Part 4 met the same thing with
/// `janet_check_can_resume`.
fn debugFrame(frame: *c.JanetStackFrame) callconv(.c) c.Janet {
    var desc: c.JanetTraceFrame = undefined;
    janet_trace_frame(frame, &desc);

    const t = c.janet_table(3);
    var def: [*c]c.JanetFuncDef = null;

    if (frame.func != null) {
        put(t, "function", c.janet_wrap_function(frame.func));
        def = frame.func.*.def;
        if (desc.name_kind == name_function) {
            put(t, "name", c.janet_wrap_string(desc.name));
        }
    } else {
        if (desc.name_kind == name_cfunction) {
            if (desc.name_prefix != null) {
                put(t, "name", c.janet_wrap_string(c.janet_formatc("%s/%s", desc.name_prefix, desc.name)));
            } else {
                put(t, "name", c.janet_cstringv(desc.name));
            }
            if (desc.source != null) {
                put(t, "source", c.janet_cstringv(desc.source));
            }
            // Inside the named branch, which is where doframe has it. The
            // descriptor classifies the location independently of the name; a
            // stack trace uses that and debug/stack does not.
            if (desc.loc_kind == loc_cfun_line) {
                put(t, "source-line", wrapInteger(desc.line));
                put(t, "source-column", wrapInteger(1));
            }
        }
        put(t, "c", c.janet_wrap_true());
    }

    if (desc.tail != 0) {
        put(t, "tail", c.janet_wrap_true());
    }

    if (frame.func == null or frame.pc == null) return c.janet_wrap_table(t);

    // The registers begin one frame header above the frame itself.
    const stack: [*c]c.Janet = @as([*c]c.Janet, @ptrCast(@alignCast(frame))) + frame_size;

    const offset: i32 = @intCast(@divExact(
        @intFromPtr(frame.pc) - @intFromPtr(def.*.bytecode),
        @sizeOf(u32),
    ));
    put(t, "pc", wrapInteger(offset));
    if (desc.loc_kind == loc_sourcemap) {
        put(t, "source-line", wrapInteger(desc.line));
        put(t, "source-column", wrapInteger(desc.column));
    }
    if (def.*.source != null) {
        put(t, "source", c.janet_wrap_string(def.*.source));
    }

    // Add stack arguments.
    const slots = c.janet_array(def.*.slotcount);
    safe_memcpy(slots.*.data, stack, @sizeOf(c.Janet) *% @as(usize, @intCast(def.*.slotcount)));
    slots.*.count = def.*.slotcount;
    put(t, "slots", c.janet_wrap_array(slots));

    // Add local bindings.
    if (def.*.symbolmap != null) {
        const local_bindings = c.janet_table(0);
        var i: i32 = def.*.symbolmap_length - 1;
        while (i >= 0) : (i -= 1) {
            const jsm = def.*.symbolmap[@intCast(i)];
            var value = c.janet_wrap_nil();
            const pc: u32 = @intCast(offset);
            if (jsm.birth_pc == 0xFFFFFFFF) {
                // death_pc has secondary meaning here: it encodes the
                // environment index.
                if (jsm.death_pc < @as(u32, @intCast(def.*.environments_length))) {
                    const env = funcEnv(frame.func, jsm.death_pc);
                    if (jsm.slot_index < @as(u32, @intCast(env.*.length))) {
                        if (env.*.offset > 0) {
                            // On stack.
                            value = env.*.as.fiber.*.data[@intCast(env.*.offset + @as(i32, @intCast(jsm.slot_index)))];
                        } else {
                            // Off stack.
                            value = env.*.as.values[jsm.slot_index];
                        }
                    }
                }
            } else if (pc >= jsm.birth_pc and pc < jsm.death_pc) {
                if (jsm.slot_index < @as(u32, @intCast(def.*.slotcount))) {
                    value = stack[jsm.slot_index];
                }
            }
            c.janet_table_put(local_bindings, c.janet_wrap_symbol(jsm.symbol), value);
        }
        put(t, "locals", c.janet_wrap_table(local_bindings));
    }

    return c.janet_wrap_table(t);
}

comptime {
    @export(&debugFrame, .{ .name = "janet_debug_frame", .visibility = .hidden });
}
