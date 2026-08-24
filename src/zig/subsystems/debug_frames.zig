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
//! ## What Phase 10 Part 7 added
//!
//! `debug.c`'s remainder, which is everything except the frame decoding
//! `trace_frames.zig` owns: the breakpoint family, and the nine `debug/`
//! cfunctions. A breakpoint is bit 7 of an instruction word, which `run_vm`
//! tests before dispatching; `janet_debug_find` is the search that turns a
//! source position into an instruction to set it on, and its rule is not
//! "nearest" but "the greatest position at or before", with ties going to the
//! funcdef walked last.
//!
//! The stack-trace *printer* went to `-Dtrace-frames` rather than staying with
//! these, because its whole job is to render a `JanetTraceFrame` and that
//! descriptor is the other selector's subject. `cfunDebugStacktrace` reaches
//! it by its C name, which is the same rule the decoder call below follows and
//! for the same reason.
//!
//! ## Raising
//!
//! The breakpoint pair raise: an offset outside the bytecode is a panic, and
//! since Part 7 it is a Zig one. Beyond that nothing here raises deliberately,
//! and everything here allocates. The
//! allocators end a failure in `JANET_OUT_OF_MEMORY`, which exits rather than
//! jumping — checked, not assumed — so the only way out of this frame is the
//! normal one. The marker is present because `janet_table_put` and
//! `janet_array` are ordinary runtime calls and the file holds nothing that
//! would need releasing if one of them ever did jump.

const corefn = @import("corefn");
const abi = @import("abi");
const c = abi.c;
const containers = @import("containers.zig");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");
const arglayer = @import("arglayer.zig");
const trace_frames = @import("trace_frames.zig");
const vm_entry = @import("vm_entry.zig");

/// `janet.h`'s frame size. `janet_stack_frame` is a function-like macro over it
/// and does not survive translation.
const frame_size: usize = c.JANET_FRAME_SIZE;

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
/// `wrap.c`; `value_wrap_extern.zig` wrote it the same way and for the same
/// reason until Phase 11 Part 26 deleted it.
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
/// `janet_debug_frame` was the C-ABI face over this, exported with hidden
/// visibility because it is declared in `state.h` rather than in `janet.h`.
/// Phase 11 Part 12 retired it: `cfunStack` below already called the
/// implementation, so the face's only caller was `test/vm_lifecycle.c`, and
/// the migrated contract reaches this by import.
pub fn debugFrameImpl(frame: *c.JanetStackFrame) raise.Raising(c.Janet) {
    var desc: c.JanetTraceFrame = undefined;
    try trace_frames.janet_trace_frameImpl(frame, &desc);

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
                put(t, "name", c.janet_wrap_string(try pp_format.formatc("%s/%s", .{ desc.name_prefix, desc.name })));
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

// ==========================================================================
// Breakpoints
//
// A breakpoint is bit 7 of an instruction word. `run_vm` tests it before
// dispatching and raises a nil signal, which is what `debug/step` and the
// REPL's debugger resume from.
// ==========================================================================

fn janet_debug_breakImpl(definition: *c.JanetFuncDef, pc: i32) raise.Raising(void) {
    if (pc >= definition.bytecode_length or pc < 0) return raise.panic("invalid bytecode offset");
    definition.bytecode[@intCast(pc)] |= 0x80;
}

export fn janet_debug_break(definition: *c.JanetFuncDef, pc: i32) callconv(.c) void {
    raise.reported(janet_debug_breakImpl(definition, pc));
}

fn janet_debug_unbreakImpl(definition: *c.JanetFuncDef, pc: i32) raise.Raising(void) {
    if (pc >= definition.bytecode_length or pc < 0) return raise.panic("invalid bytecode offset");
    definition.bytecode[@intCast(pc)] &= ~@as(u32, 0x80);
}

export fn janet_debug_unbreak(definition: *c.JanetFuncDef, pc: i32) callconv(.c) void {
    raise.reported(janet_debug_unbreakImpl(definition, pc));
}

/// Find the instruction to break on for a source position, by scanning every
/// funcdef on the heap.
///
/// The choice rule is the C original's and is worth stating because it is not
/// "nearest": among instructions at or before the requested position, it takes
/// the one with the greatest line, and among those the greatest column. `>=`
/// on the line rather than `>` is what lets a later funcdef win a tie, so with
/// two definitions mapped to the same position the last one walked is the one
/// that gets the breakpoint -- and the walk order is the heap list, which is
/// allocation order reversed.
fn janet_debug_findImpl(
    definition_out: *[*c]c.JanetFuncDef,
    pc_out: *i32,
    source: [*c]const u8,
    source_line: i32,
    source_column: i32,
) raise.Raising(void) {
    var best_index: i32 = -1;
    var best_line: i32 = -1;
    var best_column: i32 = -1;
    var best_definition: [*c]c.JanetFuncDef = null;

    var current: [*c]c.JanetGCObject = @ptrCast(@alignCast(c.janet_vm.blocks));
    while (current != null) : (current = current.*.data.next) {
        if (current.*.flags & c.JANET_MEM_TYPEBITS != c.JANET_MEMORY_FUNCDEF) continue;
        const definition: [*c]c.JanetFuncDef = @ptrCast(@alignCast(current));
        if (definition.*.sourcemap == null or definition.*.source == null) continue;
        if (c.janet_string_compare(source, definition.*.source) != 0) continue;
        var index: i32 = 0;
        while (index < definition.*.bytecode_length) : (index += 1) {
            const mapping = definition.*.sourcemap[@intCast(index)];
            if (mapping.line <= source_line and mapping.line >= best_line) {
                if (mapping.column <= source_column and
                    (mapping.line > best_line or mapping.column > best_column))
                {
                    best_line = mapping.line;
                    best_column = mapping.column;
                    best_index = index;
                    best_definition = definition;
                }
            }
        }
    }

    if (best_definition == null) return raise.panic("could not find breakpoint");
    definition_out.* = best_definition;
    pc_out.* = best_index;
}

export fn janet_debug_find(
    definition_out: *[*c]c.JanetFuncDef,
    pc_out: *i32,
    source: [*c]const u8,
    source_line: i32,
    source_column: i32,
) callconv(.c) void {
    raise.reported(janet_debug_findImpl(definition_out, pc_out, source, source_line, source_column));
}

// ==========================================================================
// The cfunction surface
// ==========================================================================

/// `(debug/break source line col)`'s three arguments, resolved to a location.
fn findBySource(argc: i32, argv: [*c]c.Janet, definition: *[*c]c.JanetFuncDef, pc: *i32) raise.Raising(void) {
    try arglayer.fixarity(argc, 3);
    const source = try arglayer.getString(argv, 0);
    const line = try arglayer.getInteger(argv, 1);
    const column = try arglayer.getInteger(argv, 2);
    try janet_debug_findImpl(definition, pc, source, line, column);
}

/// `(debug/fbreak fun &opt pc)`'s arguments. The offset is not range-checked
/// here; `janet_debug_break` does it.
fn findByFunction(argc: i32, argv: [*c]c.Janet, definition: *[*c]c.JanetFuncDef, pc: *i32) raise.Raising(void) {
    try arglayer.arity(argc, 1, 2);
    const function = try arglayer.getFunction(argv, 0);
    pc.* = if (argc == 2) try arglayer.getInteger(argv, 1) else 0;
    definition.* = function.*.def;
}

fn cfunDebugBreak(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    var definition: [*c]c.JanetFuncDef = undefined;
    var pc: i32 = undefined;
    try findBySource(argc, argv, &definition, &pc);
    try janet_debug_breakImpl(definition, pc);
    return c.janet_wrap_nil();
}

fn cfunDebugUnbreak(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    var definition: [*c]c.JanetFuncDef = undefined;
    var pc: i32 = 0;
    try findBySource(argc, argv, &definition, &pc);
    try janet_debug_unbreakImpl(definition, pc);
    return c.janet_wrap_nil();
}

fn cfunDebugFbreak(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    var definition: [*c]c.JanetFuncDef = undefined;
    var pc: i32 = 0;
    try findByFunction(argc, argv, &definition, &pc);
    try janet_debug_breakImpl(definition, pc);
    return c.janet_wrap_nil();
}

fn cfunDebugUnfbreak(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    var definition: [*c]c.JanetFuncDef = undefined;
    var pc: i32 = undefined;
    try findByFunction(argc, argv, &definition, &pc);
    try janet_debug_unbreakImpl(definition, pc);
    return c.janet_wrap_nil();
}

fn cfunDebugLineage(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    var fiber = try arglayer.getFiber(argv, 0);
    const array = c.janet_array(0);
    while (fiber != null) : (fiber = fiber.*.child) {
        try containers.arrayPush(array, c.janet_wrap_fiber(fiber));
    }
    return c.janet_wrap_array(array);
}

fn cfunDebugStack(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const fiber = try arglayer.getFiber(argv, 0);
    const array = c.janet_array(0);
    var index = fiber.*.frame;
    while (index > 0) {
        const frame: *c.JanetStackFrame = @ptrCast(@alignCast(fiber.*.data + @as(usize, @intCast(index)) - frame_size));
        try containers.arrayPush(array, try debugFrameImpl(frame));
        index = frame.prevframe;
    }
    return c.janet_wrap_array(array);
}

fn cfunDebugStacktrace(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 3);
    const fiber = try arglayer.getFiber(argv, 0);
    const err = if (argc == 1) c.janet_wrap_nil() else argv[1];
    const prefix = try arglayer.optCString(argv, argc, 2, null);
    try trace_frames.stacktraceExt(fiber, err, prefix);
    return argv[0];
}

fn cfunDebugArgstack(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const fiber = try arglayer.getFiber(argv, 0);
    const array = c.janet_array(fiber.*.stacktop - fiber.*.stackstart);
    const count: usize = @intCast(array.*.capacity);
    if (count != 0) {
        @memcpy(
            array.*.data[0..count],
            (fiber.*.data + @as(usize, @intCast(fiber.*.stackstart)))[0..count],
        );
    }
    array.*.count = array.*.capacity;
    return c.janet_wrap_array(array);
}

fn cfunDebugStep(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 2);
    const fiber = try arglayer.getFiber(argv, 0);
    var out = c.janet_wrap_nil();
    _ = try vm_entry.stepImpl(fiber, if (argc == 1) c.janet_wrap_nil() else argv[1], &out);
    return out;
}

export fn janet_lib_debug(env: *c.JanetTable) callconv(.c) void {
    const entries = [_]corefn.Entry{
        corefn.reg("debug/break", &cfunDebugBreak, @src(), "(debug/break source line col)", "Sets a breakpoint in `source` at a given line and column. " ++
            "Will throw an error if the breakpoint location " ++
            "cannot be found. For example\n\n" ++
            "\t(debug/break \"core.janet\" 10 4)\n\n" ++
            "will set a breakpoint at line 10, 4th column of the file core.janet."),
        corefn.reg("debug/unbreak", &cfunDebugUnbreak, @src(), "(debug/unbreak source line column)", "Remove a breakpoint with a source key at a given line and column. " ++
            "Will throw an error if the breakpoint " ++
            "cannot be found."),
        corefn.reg("debug/fbreak", &cfunDebugFbreak, @src(), "(debug/fbreak fun &opt pc)", "Set a breakpoint in a given function. pc is an optional offset, which " ++
            "is in bytecode instructions. fun is a function value. Will throw an error " ++
            "if the offset is too large or negative."),
        corefn.reg("debug/unfbreak", &cfunDebugUnfbreak, @src(), "(debug/unfbreak fun &opt pc)", "Unset a breakpoint set with debug/fbreak."),
        corefn.reg("debug/arg-stack", &cfunDebugArgstack, @src(), "(debug/arg-stack fiber)", "Gets all values currently on the fiber's argument stack. Normally, " ++
            "this should be empty unless the fiber signals while pushing arguments " ++
            "to make a function call. Returns a new array."),
        corefn.reg("debug/stack", &cfunDebugStack, @src(), "(debug/stack fib)", "Gets information about the stack as an array of tables. Each table " ++
            "in the array contains information about a stack frame. The top-most, current " ++
            "stack frame is the first table in the array, and the bottom-most stack frame " ++
            "is the last value. Each stack frame contains some of the following attributes:\n\n" ++
            "* :c - true if the stack frame is a c function invocation\n\n" ++
            "* :source-column - the current source column of the stack frame\n\n" ++
            "* :function - the function that the stack frame represents\n\n" ++
            "* :source-line - the current source line of the stack frame\n\n" ++
            "* :name - the human-friendly name of the function\n\n" ++
            "* :pc - integer indicating the location of the program counter\n\n" ++
            "* :source - string with the file path or other identifier for the source code\n\n" ++
            "* :slots - array of all values in each slot\n\n" ++
            "* :tail - boolean indicating a tail call"),
        corefn.reg("debug/stacktrace", &cfunDebugStacktrace, @src(), "(debug/stacktrace fiber &opt err prefix)", "Prints a nice looking stacktrace for a fiber. Can optionally provide " ++
            "an error value to print the stack trace with. If `prefix` is nil or not " ++
            "provided, will skip the error line. Returns the fiber."),
        corefn.reg("debug/lineage", &cfunDebugLineage, @src(), "(debug/lineage fib)", "Returns an array of all child fibers from a root fiber. This function " ++
            "is useful when a fiber signals or errors to an ancestor fiber. Using this function, " ++
            "the fiber handling the error can see which fiber raised the signal. This function should " ++
            "be used mostly for debugging purposes."),
        corefn.reg("debug/step", &cfunDebugStep, @src(), "(debug/step fiber &opt x)", "Run a fiber for one virtual instruction of the Janet machine. Can optionally " ++
            "pass in a value that will be passed as the resuming value. Returns the signal value, " ++
            "which will usually be nil, as breakpoints raise nil signals."),
        corefn.end,
    };
    corefn.install(env, &entries);
}
