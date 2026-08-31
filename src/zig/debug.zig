//! The debugger's view of a running fiber: stack frames, breakpoints, and the
//! trace a signal renders.
//!
//! Two files once, split by which half of Janet's `debug.c` had been ported
//! first rather than by subject: one walks the frame chain and the other
//! renders it, and the second cannot do its job without the first. The four
//! `JANET_TRACE_*` constants below were declared in both, because neither could
//! see the other's. One file now, under the name Janet already uses for the
//! module: `debug`.
const corefn = @import("corefn");
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const raise = @import("raise");
const pp_format = @import("pp/format.zig");
const args_core = @import("args.zig");
const trace_frames = @import("debug.zig");
const vm_entry = @import("vm/entry.zig");
const tables = @import("value/tables.zig");
const strings = @import("value/strings.zig");
const symbols = @import("value/symbols.zig");
const wrap = @import("value/helpers/wrap.zig");
const arrays = @import("value/arrays.zig");
const std = @import("std");
const stdio = @import("stdio.zig");
const vm_state = @import("vm/lifecycle.zig");
const fibers = @import("value/fibers.zig");
const value = @import("value.zig");
const utils = @import("utils.zig");
const pp_describe = @import("pp.zig");
const registry = @import("registry.zig");

// -------------------------------------------------------------------------
// The frame walk -- what `debug_frames.zig` was.
// -------------------------------------------------------------------------

/// `janet.h`'s frame size. `janet_stack_frame` is a function-like macro over it
/// and does not survive translation.
const frame_size: usize = constants.JANET_FRAME_SIZE;

/// `src/core/util.h`, declared here rather than in `cabi.zig`. It is `memcpy`
/// with a zero-length guard, which is what
/// `doframe` needs for a funcdef with no slots.
extern fn safe_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void;

const name_function: u8 = @intCast(constants.JANET_TRACE_NAME_FUNCTION);
const name_cfunction: u8 = @intCast(constants.JANET_TRACE_NAME_CFUNCTION);
const loc_sourcemap: u8 = @intCast(constants.JANET_TRACE_LOC_SOURCEMAP);
const loc_cfun_line: u8 = @intCast(constants.JANET_TRACE_LOC_CFUN_LINE);

/// `janet_ckeywordv` from `janet.h`, which is a macro over `janet_csymbol`:
/// keywords and symbols are interned by the same function and differ only in
/// how they are wrapped.
inline fn kw(name: [*:0]const u8) repr.Value {
    return wrap.fromKeyword(symbols.csymbol(name));
}

/// `janet_wrap_integer` spelled out. The macro is absent from a
/// `-Dnanbox=false` build, which is the defect `FOUND.md` records.
inline fn wrapInteger(n: i32) repr.Value {
    return wrap.fromNumber(@floatFromInt(n));
}

inline fn put(t: *types.JanetTable, name: [*:0]const u8, val: repr.Value) void {
    tables.put(t, kw(name), val);
}

/// `func->envs[i]`. `envs` is a flexible array member and translate-c drops it,
/// so the slot is computed the way `janet_function` allocates it: immediately
/// after the header. `gc_mark.zig` and `vm_run.zig` read the same slots the
/// same way.
inline fn funcEnv(func: *types.JanetFunction, i: u32) *types.JanetFuncEnv {
    return types.envsOf(func)[i].?;
}

/// Extract info from one stack frame.
///
/// This is reached by import. `janet_debug_frame` was an abi over it, exported
/// with hidden visibility because Janet declares it in an internal header
/// rather than in its public one; nothing needs it.
pub fn debugFrame(frame: *types.JanetStackFrame) raise.Raising(repr.Value) {
    var desc: types.JanetTraceFrame = undefined;
    try trace_frames.traceFrame(frame, &desc);

    const t = tables.new(3);
    var def: ?*types.JanetFuncDef = null;

    if (frame.func) |func| {
        put(t, "function", wrap.fromFunction(func));
        def = func.def;
        if (desc.name_kind == name_function) {
            put(t, "name", wrap.fromString(desc.name.?));
        }
    } else {
        if (desc.name_kind == name_cfunction) {
            if (desc.name_prefix != null) {
                put(t, "name", wrap.fromString(try pp_format.formatc("%s/%s", .{ desc.name_prefix, desc.name })));
            } else {
                put(t, "name", value.fromBytes(std.mem.span(desc.name.?), .string));
            }
            if (desc.source != null) {
                put(t, "source", value.fromBytes(std.mem.span(desc.source.?), .string));
            }
            // Inside the named branch, which is where doframe has it. The
            // descriptor classifies the location independently of the name; a
            // stack trace uses that and debug/stack does not.
            if (desc.loc_kind == loc_cfun_line) {
                put(t, "source-line", wrapInteger(desc.line));
                put(t, "source-column", wrapInteger(1));
            }
        }
        put(t, "c", wrap.fromTrue());
    }

    if (desc.tail != 0) {
        put(t, "tail", wrap.fromTrue());
    }

    if (frame.func == null or frame.pc == null) return wrap.fromTable(t);

    // The registers begin one frame header above the frame itself.
    const stack: [*]repr.Value = @as([*]repr.Value, @ptrCast(@alignCast(frame))) + frame_size;

    const offset: i32 = @intCast(@divExact(
        @intFromPtr(frame.pc) - @intFromPtr(def.?.bytecode),
        @sizeOf(u32),
    ));
    put(t, "pc", wrapInteger(offset));
    if (desc.loc_kind == loc_sourcemap) {
        put(t, "source-line", wrapInteger(desc.line));
        put(t, "source-column", wrapInteger(desc.column));
    }
    if (def.?.source) |source| {
        put(t, "source", wrap.fromString(source));
    }

    // Add stack arguments.
    const slots = arrays.new(def.?.slotcount);
    safe_memcpy(slots.*.data, stack, @sizeOf(repr.Value) *% @as(usize, @intCast(def.?.slotcount)));
    slots.*.count = def.?.slotcount;
    put(t, "slots", wrap.fromArray(slots));

    // Add local bindings.
    if (def.?.symbolmap != null) {
        const local_bindings = tables.new(0);
        var i: i32 = def.?.symbolmap_length - 1;
        while (i >= 0) : (i -= 1) {
            const jsm = def.?.symbols()[@intCast(i)];
            var val = wrap.fromNil();
            const pc: u32 = @intCast(offset);
            if (jsm.birth_pc == 0xFFFFFFFF) {
                // death_pc has secondary meaning here: it encodes the
                // environment index.
                if (jsm.death_pc < @as(u32, @intCast(def.?.environments_length))) {
                    const env = funcEnv(frame.func.?, jsm.death_pc);
                    if (jsm.slot_index < @as(u32, @intCast(env.*.length))) {
                        if (env.*.offset > 0) {
                            // On stack.
                            val = env.*.as.fiber.?.data.?[@intCast(env.*.offset + @as(i32, @intCast(jsm.slot_index)))];
                        } else {
                            // Off stack.
                            val = env.*.as.values.?[jsm.slot_index];
                        }
                    }
                }
            } else if (pc >= jsm.birth_pc and pc < jsm.death_pc) {
                if (jsm.slot_index < @as(u32, @intCast(def.?.slotcount))) {
                    val = stack[jsm.slot_index];
                }
            }
            tables.put(local_bindings, wrap.fromSymbol(jsm.symbol.?), val);
        }
        put(t, "locals", wrap.fromTable(local_bindings));
    }

    return wrap.fromTable(t);
}

// ==========================================================================
// Breakpoints
//
// A breakpoint is bit 7 of an instruction word. `run_vm` tests it before
// dispatching and raises a nil signal, which is what `debug/step` and the
// REPL's debugger resume from.
// ==========================================================================

fn debugBreak(definition: *types.JanetFuncDef, pc: i32) raise.Raising(void) {
    if (pc >= definition.bytecode_length or pc < 0) return raise.panic("invalid bytecode offset");
    definition.instructions()[@intCast(pc)] |= 0x80;
}

pub fn debugBreakAbi(definition: *types.JanetFuncDef, pc: i32) void {
    raise.reported(debugBreak(definition, pc));
}

fn debugUnbreak(definition: *types.JanetFuncDef, pc: i32) raise.Raising(void) {
    if (pc >= definition.bytecode_length or pc < 0) return raise.panic("invalid bytecode offset");
    definition.instructions()[@intCast(pc)] &= ~@as(u32, 0x80);
}

pub fn debugUnbreakAbi(definition: *types.JanetFuncDef, pc: i32) void {
    raise.reported(debugUnbreak(definition, pc));
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
fn debugFindImpl(
    definition_out: *?*types.JanetFuncDef,
    pc_out: *i32,
    source: [*:0]const u8,
    source_line: i32,
    source_column: i32,
) raise.Raising(void) {
    var best_index: i32 = -1;
    var best_line: i32 = -1;
    var best_column: i32 = -1;
    var best_definition: ?*types.JanetFuncDef = null;

    var current: ?*types.JanetGCObject = @ptrCast(@alignCast(vm_state.current().gc.blocks));
    while (current) |block| : (current = block.data.next) {
        if (block.memoryType() != .funcdef) continue;
        const definition: *types.JanetFuncDef = @ptrCast(@alignCast(current));
        if (definition.*.sourcemap == null or definition.*.source == null) continue;
        if (strings.compare(source, definition.*.source.?) != 0) continue;
        var index: i32 = 0;
        while (index < definition.*.bytecode_length) : (index += 1) {
            const mapping = definition.*.sourceMappings()[@intCast(index)];
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

pub fn debugFind(
    definition_out: *?*types.JanetFuncDef,
    pc_out: *i32,
    source: [*:0]const u8,
    source_line: i32,
    source_column: i32,
) callconv(.c) void {
    raise.reported(debugFindImpl(definition_out, pc_out, source, source_line, source_column));
}

// ==========================================================================
// The cfunction surface
// ==========================================================================

/// `(debug/break source line col)`'s three arguments, resolved to a location.
fn findBySource(argv: []repr.Value, definition: *?*types.JanetFuncDef, pc: *i32) raise.Raising(void) {
    try args_core.fixarity(argv, 3);
    const source = try args_core.getString(argv, 0);
    const line = try args_core.getInteger(argv, 1);
    const column = try args_core.getInteger(argv, 2);
    try debugFindImpl(definition, pc, source, line, column);
}

/// `(debug/fbreak fun &opt pc)`'s arguments. The offset is not range-checked
/// here; `janet_debug_break` does it.
fn findByFunction(argv: []repr.Value, definition: *?*types.JanetFuncDef, pc: *i32) raise.Raising(void) {
    try args_core.arity(argv, 1, 2);
    const function = try args_core.getFunction(argv, 0);
    pc.* = if (@as(i32, @intCast(argv.len)) == 2) try args_core.getInteger(argv, 1) else 0;
    definition.* = function.*.def.?;
}

fn cfunDebugBreak(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    var definition: ?*types.JanetFuncDef = undefined;
    var pc: i32 = undefined;
    try findBySource(argv, &definition, &pc);
    try debugBreak(definition.?, pc);
    return wrap.fromNil();
}

fn cfunDebugUnbreak(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    var definition: ?*types.JanetFuncDef = undefined;
    var pc: i32 = 0;
    try findBySource(argv, &definition, &pc);
    try debugUnbreak(definition.?, pc);
    return wrap.fromNil();
}

fn cfunDebugFbreak(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    var definition: ?*types.JanetFuncDef = undefined;
    var pc: i32 = 0;
    try findByFunction(argv, &definition, &pc);
    try debugBreak(definition.?, pc);
    return wrap.fromNil();
}

fn cfunDebugUnfbreak(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    var definition: ?*types.JanetFuncDef = undefined;
    var pc: i32 = undefined;
    try findByFunction(argv, &definition, &pc);
    try debugUnbreak(definition.?, pc);
    return wrap.fromNil();
}

fn cfunDebugLineage(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    var fiber: ?*types.JanetFiber = try args_core.getFiber(argv, 0);
    const array = arrays.new(0);
    while (fiber) |f| : (fiber = f.child) {
        try arrays.push(array, wrap.fromFiber(f));
    }
    return wrap.fromArray(array);
}

fn cfunDebugStack(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const fiber = try args_core.getFiber(argv, 0);
    const array = arrays.new(0);
    var index = fiber.*.frame;
    while (index > 0) {
        const frame: *types.JanetStackFrame = @ptrCast(@alignCast(fiber.*.data.? + @as(usize, @intCast(index)) - frame_size));
        try arrays.push(array, try debugFrame(frame));
        index = frame.prevframe;
    }
    return wrap.fromArray(array);
}

fn cfunDebugStacktrace(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, 3);
    const fiber = try args_core.getFiber(argv, 0);
    const err = if (@as(i32, @intCast(argv.len)) == 1) wrap.fromNil() else argv[1];
    const prefix = try args_core.optCString(argv, 2, null);
    try trace_frames.stacktraceExt(fiber, err, prefix);
    return argv[0];
}

fn cfunDebugArgstack(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const fiber = try args_core.getFiber(argv, 0);
    const array = arrays.new(fiber.*.stacktop - fiber.*.stackstart);
    const count: usize = @intCast(array.*.capacity);
    if (count != 0) {
        @memcpy(
            array.*.slice()[0..count],
            (fiber.*.data.? + @as(usize, @intCast(fiber.*.stackstart)))[0..count],
        );
    }
    array.*.count = array.*.capacity;
    return wrap.fromArray(array);
}

fn cfunDebugStep(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, 2);
    const fiber = try args_core.getFiber(argv, 0);
    var out = wrap.fromNil();
    _ = try vm_entry.step(fiber, if (@as(i32, @intCast(argv.len)) == 1) wrap.fromNil() else argv[1], &out);
    return out;
}

pub fn libDebug(env: *types.JanetTable) void {
    const entries = comptime [_]corefn.Entry{
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
    };
    corefn.install(env, entries);
}

// -------------------------------------------------------------------------
// The trace render -- what `trace_frames.zig` was.
// -------------------------------------------------------------------------

const name_none: u8 = @intCast(constants.JANET_TRACE_NAME_NONE);
const name_anonymous: u8 = @intCast(constants.JANET_TRACE_NAME_ANONYMOUS);
const name_cfunction_bare: u8 = @intCast(constants.JANET_TRACE_NAME_CFUNCTION_BARE);

const loc_none: u8 = @intCast(constants.JANET_TRACE_LOC_NONE);
const loc_pc: u8 = @intCast(constants.JANET_TRACE_LOC_PC);

const tailcall: i32 = @intCast(constants.JANET_STACKFRAME_TAILCALL);

/// Decode `frame` into `out`. Total: every frame produces a descriptor, and a
/// frame that names nothing produces `NAME_NONE` with `LOC_NONE`, which renders
/// as a bare `  in` line exactly as the C original does.
pub fn traceFrame(frame: *types.JanetStackFrame, out: *types.JanetTraceFrame) raise.Raising(void) {
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

    if (frame.func) |func| {
        const def = func.def.?;
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
                const mapping = def.*.sourceMappings()[offset];
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
    const cfun: types.JanetCFunction = @ptrFromInt(@intFromPtr(frame.pc));
    if (cfun == null) return;

    const reg = registry.registryGet(cfun);
    if (reg != null and reg.?.name != null) {
        out.name_kind = name_cfunction;
        out.name = reg.?.name;
        out.name_prefix = reg.?.name_prefix;
        // Only the named branch reports a source. An entry with a source file
        // and no name prints "<cfunction>" and nothing more, and leaving
        // `source` null here is what keeps that true.
        out.source = reg.?.source_file;
    } else {
        out.name_kind = name_cfunction_bare;
    }

    // Deliberately outside the branch above: the location comes from the entry
    // existing, the name from the entry having a name. See the header comment.
    if (reg != null and reg.?.source_line > 0) {
        out.loc_kind = loc_cfun_line;
        out.line = reg.?.source_line;
    }
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
/// value is used for anything. So the accessor is a function rather than a
/// variable.
///
/// Found by the cross-compile entries of the acceptance matrix, which is what
/// they are for: every native entry passed with a version that handled only
/// the first two shapes.
/// `janet_eprintf`, which Janet spells as a variadic macro over
/// `janet_dynprintf`. Zig cannot *define* a variadic function on every target
/// this project builds for, but calling one is ordinary, so the macro is
/// written out here rather than worked around. The dynamic binding `:err`
/// redirects the whole trace, which is what makes this different from writing
/// to the handle directly.
/// around. The dynamic binding `:err` redirects the whole trace, which is what
/// makes this different from writing to the handle directly.
inline fn eprintf(comptime format: [:0]const u8, args: anytype) void {
    // `pp/format.dynprintf` can raise: `(dyn :err)` may be a Janet function, and
    // calling it can. This position cannot carry one -- it is a trace or a
    // diagnostic on the way out -- so the raise is reported.
    raise.reported(pp_format.dynprintf("err", @ptrCast(@alignCast(stdio.err())), format, args));
}

const TraceState = struct {
    prefix: ?[*:0]const u8,
    error_text: ?[*:0]const u8,
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
fn traceChain(fiber: *types.JanetFiber, state: *TraceState) raise.Raising(void) {
    if (fiber.child) |child| try traceChain(child, state);

    var index = fiber.frame;
    while (index > 0) {
        const frame: *types.JanetStackFrame = @ptrCast(@alignCast(fiber.data.? + @as(usize, @intCast(index)) - @as(usize, constants.JANET_FRAME_SIZE)));
        var descriptor: types.JanetTraceFrame = undefined;
        index = frame.prevframe;
        try traceFrame(frame, &descriptor);

        // The error line is printed once, above the first frame -- not before
        // the loop, so that a fiber with no frames prints nothing at all.
        if (!state.wrote_error) {
            const status = fibers.status(fiber);
            eprintf("%s%s: %s\n", .{
                if (state.prefix != null) state.prefix else @as([*]const u8, ""),
                utils.statusNames[@intFromEnum(status)],
                if (state.error_text != null) state.error_text else utils.statusNames[@intFromEnum(status)],
            });
            state.wrote_error = true;
        }

        eprintf("  in", .{});

        switch (descriptor.name_kind) {
            constants.JANET_TRACE_NAME_ANONYMOUS => eprintf(" %s", .{@as([*]const u8, "<anonymous>")}),
            constants.JANET_TRACE_NAME_FUNCTION => eprintf(" %s", .{descriptor.name}),
            constants.JANET_TRACE_NAME_CFUNCTION => if (descriptor.name_prefix != null) {
                eprintf(" %s/%s", .{ descriptor.name_prefix, descriptor.name });
            } else {
                eprintf(" %s", .{descriptor.name});
            },
            constants.JANET_TRACE_NAME_CFUNCTION_BARE => eprintf(" <cfunction>", .{}),
            else => {},
        }

        // `source` is null in exactly the cases that printed no source before:
        // an unnamed cfunction, and a frame that names nothing.
        if (descriptor.source != null) eprintf(" [%s]", .{descriptor.source});
        if (descriptor.tail != 0) eprintf(" (tail call)", .{});

        switch (descriptor.loc_kind) {
            constants.JANET_TRACE_LOC_SOURCEMAP => eprintf(" on line %d, column %d", .{ descriptor.line, descriptor.column }),
            constants.JANET_TRACE_LOC_PC => eprintf(" pc=%d", .{descriptor.pc}),
            // The `long` widening is the original's. Janet's "%d" reads an
            // int32_t, so it is a width mismatch; it is preserved rather than
            // fixed, and recorded in FOUND.md.
            constants.JANET_TRACE_LOC_CFUN_LINE => eprintf(" on line %d", .{@as(c_long, descriptor.line)}),
            else => {},
        }
        eprintf("\n", .{});
    }
}

pub fn stacktraceExt(
    fiber: ?*types.JanetFiber,
    err: repr.Value,
    prefix: ?[*:0]const u8,
) raise.Raising(void) {
    var state = TraceState{
        .prefix = prefix,
        .error_text = @ptrCast(pp_describe.toString(err)),
        // A null prefix means "skip the error line", so it counts as already
        // written.
        .wrote_error = prefix == null,
    };
    const print_color = repr.truthy(vm_state.dyn("err-color"));
    if (print_color) eprintf("\x1b[31m", .{});
    if (fiber) |f| try traceChain(f, &state);
    if (print_color) eprintf("\x1b[0m", .{});
}

pub fn stacktraceExtAbi(
    fiber: *types.JanetFiber,
    err: repr.Value,
    prefix: ?[*:0]const u8,
) callconv(.c) void {
    raise.reported(stacktraceExt(fiber, err, prefix));
}

pub fn stacktrace(fiber: *types.JanetFiber, err: repr.Value) void {
    // A nil error prints no error line at all; anything else prints one with
    // an empty prefix.
    const prefix: ?[*:0]const u8 = if (repr.checkType(err, repr.Tag.nil)) null else "";
    raise.reported(stacktraceExt(fiber, err, prefix));
}
