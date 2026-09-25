//! The debugger's view of a running fiber: stack frames, breakpoints, and the
//! trace a signal renders.
//!
//! `debugFrame` turns one stack frame into a table for `debug/stack`,
//! `traceFrame` decodes one into a `TraceFrame` descriptor, and
//! `stacktraceExt` renders a whole fiber chain to `(dyn :err)`. `libDebug`
//! installs the `debug/` nfunctions.
//!
//! The frame walk and the trace render are one file because the second cannot
//! do its job without the first, and the `JANET_TRACE_*` constants below are
//! what they agree on.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const args_core = @import("args.zig");
const arrays = @import("value/arrays.zig");
const constants = @import("constants");
const corefn = @import("corefn.zig");
const fibers = @import("value/fibers.zig");
const functions = @import("value/functions.zig");
const gc_alloc = @import("gc.zig");
const pp_describe = @import("pp.zig");
const pp_format = @import("pp/format.zig");
const raise = @import("../api/raise.zig");
const registry = @import("registry.zig");
const repr = @import("repr");
const stdio = @import("stdio.zig");
const strings = @import("value/strings.zig");
const symbols = @import("value/symbols.zig");
const tables = @import("value/tables.zig");
const utils = @import("utils.zig");
const value = @import("value.zig");
const vm_entry = @import("vm/entry.zig");
const vm_state = @import("vm/state.zig");
const wrap = @import("value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// A stack frame's size in `Value` slots, which is what separates a frame's
/// header from its locals.
const frame_size: usize = constants.frame_size;

/// How a `TraceFrame` locates the code it describes: an nfunction's registered
/// line, no location at all, a bytecode offset, or a line and column from a
/// funcdef's source map.
const loc_nfun_line: u8 = @intCast(constants.trace_loc_nfun_line);
const loc_none: u8 = @intCast(constants.trace_loc_none);
const loc_pc: u8 = @intCast(constants.trace_loc_pc);
const loc_sourcemap: u8 = @intCast(constants.trace_loc_sourcemap);

/// What a `TraceFrame` names: an anonymous function, a registered nfunction, an
/// nfunction with no registry entry, a named function, or nothing.
const name_anonymous: u8 = @intCast(constants.trace_name_anonymous);
const name_nfunction: u8 = @intCast(constants.trace_name_nfunction);
const name_nfunction_bare: u8 = @intCast(constants.trace_name_nfunction_bare);
const name_function: u8 = @intCast(constants.trace_name_function);
const name_none: u8 = @intCast(constants.trace_name_none);

// ==========================================================================
// Types
// ==========================================================================

/// A place a breakpoint goes: the definition with the instruction in it, and
/// the instruction's offset into that definition's bytecode. Neither half
/// locates anything alone, so the two finders report both at once.
const Breakpoint = struct {
    definition: *functions.FuncDef,
    pc: i32,
};

/// One stack frame, decoded for rendering: what it is named, where it is, and
/// whether it was reached by a tail call.
///
/// `name_kind` is one of the `name_*` constants and `loc_kind` one of the
/// `loc_*` constants, and each says which of the other fields are filled in.
pub const TraceFrame = struct {
    name: ?[*:0]const u8 = null,
    name_prefix: ?[*:0]const u8 = null,
    source: ?[*:0]const u8 = null,
    pc: i32 = 0,
    line: i32 = 0,
    column: i32 = 0,
    name_kind: u8 = 0,
    loc_kind: u8 = 0,
    tail: u8 = 0,
};

/// What `traceChain` passes down a fiber chain: the caller's prefix, the
/// rendered error text, and whether the error line has been printed yet.
const TraceState = struct {
    prefix: ?[*:0]const u8,
    error_text: ?[*:0]const u8,
    wrote_error: bool,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Extracts the information `debug/stack` reports from one stack frame, as a
/// table.
///
/// Reached by import: nothing exports it and nothing takes its address.
pub fn debugFrame(frame: *vm_state.StackFrame) raise.Error!repr.Value {
    var desc: TraceFrame = undefined;
    try traceFrame(frame, &desc);

    const t = tables.new(3);
    var def: ?*functions.FuncDef = null;

    if (frame.func) |func| {
        put(t, "function", wrap.fromFunction(func));
        def = func.def;
        if (desc.name_kind == name_function) {
            put(t, "name", wrap.fromString(desc.name.?));
        }
    } else {
        if (desc.name_kind == name_nfunction) {
            if (desc.name_prefix != null) {
                put(t, "name", wrap.fromString(try pp_format.formatc("%s/%s", .{ desc.name_prefix, desc.name })));
            } else {
                put(t, "name", value.fromBytes(std.mem.span(desc.name.?), .string));
            }
            if (desc.source) |source| {
                put(t, "source", value.fromBytes(std.mem.span(source), .string));
            }
            // Inside the named branch. The descriptor classifies the location
            // independently of the name; a stack trace uses that and
            // `debug/stack` does not.
            if (desc.loc_kind == loc_nfun_line) {
                put(t, "source-line", wrap.fromInteger(desc.line));
                put(t, "source-column", wrap.fromInteger(1));
            }
        }
        put(t, "native", wrap.fromTrue());
    }

    if (desc.tail != 0) {
        put(t, "tail", wrap.fromTrue());
    }

    const func = frame.func orelse return wrap.fromTable(t);
    if (frame.pc.bytecode == null) return wrap.fromTable(t);

    // The registers begin one frame header above the frame itself.
    const stack: [*]repr.Value = @as([*]repr.Value, @ptrCast(@alignCast(frame))) + frame_size;

    const offset: i32 = @intCast(@divExact(
        @intFromPtr(frame.pc.bytecode) - @intFromPtr(def.?.bytecode),
        @sizeOf(u32),
    ));
    put(t, "pc", wrap.fromInteger(offset));
    if (desc.loc_kind == loc_sourcemap) {
        put(t, "source-line", wrap.fromInteger(desc.line));
        put(t, "source-column", wrap.fromInteger(desc.column));
    }
    if (def.?.source) |source| {
        put(t, "source", wrap.fromString(source));
    }

    // Add stack arguments.
    const slotcount: usize = @intCast(def.?.slotcount);
    const slots = arrays.new(slotcount);
    if (slotcount != 0) @memcpy(slots.reserved()[0..slotcount], stack[0..slotcount]);
    slots.count = slotcount;
    put(t, "slots", wrap.fromArray(slots));

    // Add local bindings.
    if (def.?.symbolmap != null) {
        const local_bindings = tables.new(0);
        var i: i32 = @as(i32, @intCast(def.?.symbolmap_length)) - 1;
        while (i >= 0) : (i -= 1) {
            const jsm = def.?.symbols()[@intCast(i)];
            var val = wrap.fromNil();
            const pc: u32 = @intCast(offset);
            if (jsm.birth_pc == 0xFFFFFFFF) {
                // death_pc has secondary meaning here: it encodes the
                // environment index.
                if (jsm.death_pc < @as(u32, @intCast(def.?.environments_length))) {
                    const env = funcEnv(func, jsm.death_pc);
                    if (jsm.slot_index < @as(u32, @intCast(env.length))) {
                        if (env.offset > 0) {
                            // On stack.
                            val = env.as.fiber.?.data.?[@intCast(env.offset + @as(i32, @intCast(jsm.slot_index)))];
                        } else {
                            // Off stack.
                            val = env.as.values.?[jsm.slot_index];
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

/// Installs the `debug/` nfunctions into `env`.
pub fn libDebug(env: *tables.Table) void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("debug/break", &nfunDebugBreak, @src(), "(debug/break source line col)", "Sets a breakpoint in `source` at a given line and column. " ++
            "Will throw an error if the breakpoint location " ++
            "cannot be found. For example\n\n" ++
            "\t(debug/break \"core.wattle\" 10 4)\n\n" ++
            "will set a breakpoint at line 10, 4th column of the file core.wattle."),
        corefn.reg("debug/unbreak", &nfunDebugUnbreak, @src(), "(debug/unbreak source line column)", "Remove a breakpoint with a source key at a given line and column. " ++
            "Will throw an error if the breakpoint " ++
            "cannot be found."),
        corefn.reg("debug/fbreak", &nfunDebugFbreak, @src(), "(debug/fbreak fun [pc])", "Set a breakpoint in a given function. pc is an optional offset, which " ++
            "is in bytecode instructions. fun is a function value. Will throw an error " ++
            "if the offset is too large or negative."),
        corefn.reg("debug/unfbreak", &nfunDebugUnfbreak, @src(), "(debug/unfbreak fun [pc])", "Unset a breakpoint set with debug/fbreak."),
        corefn.reg("debug/arg-stack", &nfunDebugArgstack, @src(), "(debug/arg-stack fiber)", "Gets all values currently on the fiber's argument stack. Normally, " ++
            "this should be empty unless the fiber signals while pushing arguments " ++
            "to make a function call. Returns a new array."),
        corefn.reg("debug/stack", &nfunDebugStack, @src(), "(debug/stack fib)", "Gets information about the stack as an array of tables. Each table " ++
            "in the array contains information about a stack frame. The top-most, current " ++
            "stack frame is the first table in the array, and the bottom-most stack frame " ++
            "is the last value. Each stack frame contains some of the following attributes:\n\n" ++
            "* :native - true if the stack frame is an nfunction invocation\n\n" ++
            "* :source-column - the current source column of the stack frame\n\n" ++
            "* :function - the function that the stack frame represents\n\n" ++
            "* :source-line - the current source line of the stack frame\n\n" ++
            "* :name - the human-friendly name of the function\n\n" ++
            "* :pc - integer indicating the location of the program counter\n\n" ++
            "* :source - string with the file path or other identifier for the source code\n\n" ++
            "* :slots - array of all values in each slot\n\n" ++
            "* :tail - boolean indicating a tail call"),
        corefn.reg("debug/stacktrace", &nfunDebugStacktrace, @src(), "(debug/stacktrace fiber [err [prefix]])", "Prints a nice looking stacktrace for a fiber. Can optionally provide " ++
            "an error value to print the stack trace with. If `prefix` is nil or not " ++
            "provided, will skip the error line. Returns the fiber."),
        corefn.reg("debug/lineage", &nfunDebugLineage, @src(), "(debug/lineage fib)", "Returns an array of all child fibers from a root fiber. This function " ++
            "is useful when a fiber signals or errors to an ancestor fiber. Using this function, " ++
            "the fiber handling the error can see which fiber raised the signal. This function should " ++
            "be used mostly for debugging purposes."),
        corefn.reg("debug/step", &nfunDebugStep, @src(), "(debug/step fiber [x])", "Run a fiber for one virtual instruction of the Wattle machine. Can optionally " ++
            "pass in a value that will be passed as the resuming value. Returns the signal value, " ++
            "which will usually be nil, as breakpoints raise nil signals."),
    };
    corefn.install(env, entries);
}

/// Prints a stack trace for `fiber` and its children, innermost first.
///
/// `err` is the error value and `prefix` what goes in front of the error line,
/// or null to skip that line. A null `fiber` prints nothing but the colour
/// escapes.
pub fn stacktraceExt(
    fiber: ?*fibers.Fiber,
    err: repr.Value,
    prefix: ?[*:0]const u8,
) raise.Error!void {
    var state = TraceState{
        .prefix = prefix,
        .error_text = @ptrCast(pp_describe.toString(err)),
        // A null prefix means "skip the error line", so it counts as already
        // written.
        .wrote_error = prefix == null,
    };
    const print_color = repr.truthy(vm_state.dyn("err-color"));
    if (print_color) try eprintf("\x1b[31m", .{});
    if (fiber) |f| try traceChain(f, &state);
    if (print_color) try eprintf("\x1b[0m", .{});
}

/// Decodes `frame` into `out`.
///
/// Total: every frame produces a descriptor, and a frame that names nothing
/// produces no name and no location, which renders as a bare `  in` line.
pub fn traceFrame(frame: *vm_state.StackFrame, out: *TraceFrame) raise.Error!void {
    out.* = .{
        .name = null,
        .name_prefix = null,
        .source = null,
        .pc = 0,
        .line = 0,
        .column = 0,
        .name_kind = name_none,
        .loc_kind = loc_none,
        .tail = @intFromBool(frame.flags.tailcall),
    };

    if (frame.func) |func| {
        const def = func.def.?;
        if (def.name != null) {
            out.name_kind = name_function;
            out.name = def.name;
        } else {
            out.name_kind = name_anonymous;
        }
        out.source = def.source;

        // A funcdef frame with a null pc reports no location at all.
        if (frame.pc.bytecode != null) {
            const offset = @divExact(
                @intFromPtr(frame.pc.bytecode) - @intFromPtr(def.bytecode),
                @sizeOf(u32),
            );
            if (def.sourcemap != null) {
                const mapping = def.sourceMappings()[offset];
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

    // A cframe stores the nfunction in the pc slot, which is why that slot is
    // a union; `vm/state.zig`'s `FramePc` has the reasoning.
    const nfun = frame.pc.nfunction;
    if (nfun == null) return;

    const reg = registry.registryGet(nfun) orelse {
        out.name_kind = name_nfunction_bare;
        return;
    };
    if (reg.name) |name| {
        out.name_kind = name_nfunction;
        out.name = name;
        out.name_prefix = reg.name_prefix;
        // Only the named branch reports a source. An entry with a source file
        // and no name prints "<nfunction>" and nothing more, and leaving
        // `source` null here is what keeps that true.
        out.source = reg.source_file;
    } else {
        out.name_kind = name_nfunction_bare;
    }

    // Deliberately outside the branch above: the location comes from the entry
    // existing, the name from the entry having a name. See the header comment.
    if (reg.source_line > 0) {
        out.loc_kind = loc_nfun_line;
        out.line = reg.source_line;
    }
}

// ==========================================================================
// Private functions
// ==========================================================================

/// `debug/arg-stack`: the values on the fiber's argument stack, as an array.
fn nfunDebugArgstack(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const fiber = try args_core.getFiber(argv, 0);
    const array = arrays.new(@intCast(fiber.stacktop - fiber.stackstart));
    const count: usize = @intCast(array.capacity);
    // Into `reserved()`, then the count: `slice()` is `count` long, and the
    // count is 0 until the elements are written.
    if (count != 0) {
        @memcpy(
            array.reserved()[0..count],
            (fiber.data.? + @as(usize, @intCast(fiber.stackstart)))[0..count],
        );
    }
    array.count = array.capacity;
    return wrap.fromArray(array);
}

/// `debug/break`: a breakpoint set at a source position.
fn nfunDebugBreak(argv: []repr.Value) raise.Error!repr.Value {
    const found = try findBySource(argv);
    try debugBreak(found.definition, found.pc);
    return wrap.fromNil();
}

/// `debug/fbreak`: a breakpoint set at a bytecode offset into a function.
fn nfunDebugFbreak(argv: []repr.Value) raise.Error!repr.Value {
    const found = try findByFunction(argv);
    try debugBreak(found.definition, found.pc);
    return wrap.fromNil();
}

/// `debug/lineage`: a fiber and every child under it, as an array.
fn nfunDebugLineage(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    var fiber: ?*fibers.Fiber = try args_core.getFiber(argv, 0);
    const array = arrays.new(0);
    while (fiber) |f| : (fiber = f.child) {
        try arrays.push(array, wrap.fromFiber(f));
    }
    return wrap.fromArray(array);
}

/// `debug/stack`: one table per stack frame, innermost first.
fn nfunDebugStack(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const fiber = try args_core.getFiber(argv, 0);
    const array = arrays.new(0);
    var index = fiber.frame;
    while (index > 0) {
        const frame: *vm_state.StackFrame = @ptrCast(@alignCast(fiber.data.? + @as(usize, @intCast(index)) - frame_size));
        try arrays.push(array, try debugFrame(frame));
        index = frame.prevframe;
    }
    return wrap.fromArray(array);
}

/// `debug/stacktrace`: the fiber's stack trace printed to `(dyn :err)`.
fn nfunDebugStacktrace(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 3);
    const fiber = try args_core.getFiber(argv, 0);
    const err = if (argv.len == 1) wrap.fromNil() else argv[1];
    const prefix = try args_core.optCString(argv, 2, null);
    try stacktraceExt(fiber, err, prefix);
    return argv[0];
}

/// `debug/step`: one virtual instruction of the fiber, and the signal it ended
/// on.
fn nfunDebugStep(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, 2);
    const fiber = try args_core.getFiber(argv, 0);
    var out = wrap.fromNil();
    _ = try vm_entry.step(fiber, if (argv.len == 1) wrap.fromNil() else argv[1], &out);
    return out;
}

/// `debug/unbreak`: the breakpoint at a source position removed.
fn nfunDebugUnbreak(argv: []repr.Value) raise.Error!repr.Value {
    const found = try findBySource(argv);
    try debugUnbreak(found.definition, found.pc);
    return wrap.fromNil();
}

/// `debug/unfbreak`: the breakpoint at a bytecode offset removed.
fn nfunDebugUnfbreak(argv: []repr.Value) raise.Error!repr.Value {
    const found = try findByFunction(argv);
    try debugUnbreak(found.definition, found.pc);
    return wrap.fromNil();
}

/// Sets the breakpoint bit on one instruction of `definition`, raising where
/// `pc` is out of range.
fn debugBreak(definition: *functions.FuncDef, pc: i32) raise.Error!void {
    if (pc >= definition.bytecode_length or pc < 0) return raise.panic("invalid bytecode offset");
    definition.instructions()[@intCast(pc)] |= 0x80;
}

/// Finds the instruction to break on for a source position, by scanning every
/// funcdef on the heap.
///
/// The choice rule is worth stating because it is not "nearest": among
/// instructions at or before the requested position, it takes the one with the
/// greatest line, and among those the greatest column. `>=` on the line rather
/// than `>` is what lets a later funcdef win a tie, so with two definitions
/// mapped to the same position the last one walked gets the breakpoint, and
/// the walk order is the heap list, which is allocation order reversed.
fn debugFindImpl(
    source: [*:0]const u8,
    source_line: i32,
    source_column: i32,
) raise.Error!Breakpoint {
    var best_index: i32 = -1;
    var best_line: i32 = -1;
    var best_column: i32 = -1;
    var best_definition: ?*functions.FuncDef = null;

    var current = vm_state.current().gc.blocks;
    while (current) |block| : (current = block.data.next) {
        if (gc_alloc.memoryTypeOf(block) != .funcdef) continue;
        const definition: *functions.FuncDef = @ptrCast(@alignCast(current));
        if (definition.sourcemap == null) continue;
        const definition_source = definition.source orelse continue;
        if (strings.compare(source, definition_source) != 0) continue;
        for (definition.sourceMappings(), 0..) |mapping, index| {
            if (mapping.line <= source_line and mapping.line >= best_line) {
                if (mapping.column <= source_column and
                    (mapping.line > best_line or mapping.column > best_column))
                {
                    best_line = mapping.line;
                    best_column = mapping.column;
                    best_index = @intCast(index);
                    best_definition = definition;
                }
            }
        }
    }

    const found = best_definition orelse return raise.panic("could not find breakpoint");
    return .{ .definition = found, .pc = best_index };
}

/// Clears the breakpoint bit on one instruction of `definition`, raising where
/// `pc` is out of range.
fn debugUnbreak(definition: *functions.FuncDef, pc: i32) raise.Error!void {
    if (pc >= definition.bytecode_length or pc < 0) return raise.panic("invalid bytecode offset");
    definition.instructions()[@intCast(pc)] &= ~@as(u32, 0x80);
}

/// Prints to `(dyn :err)`, falling back to the standard error handle.
///
/// The dynamic binding redirects the whole trace, and that is what makes this
/// different from writing to the handle directly. `stdio.err()` is a function
/// rather than a variable for the reason `stdio.zig` gives.
inline fn eprintf(comptime format: [:0]const u8, args: anytype) raise.Error!void {
    // `pp/format.dynprintf` can raise: `(dyn :err)` may be a Janet function,
    // and calling it can. Every caller here is raising, so the raise is
    // returned.
    return pp_format.dynprintf("err", stdio.err(), format, args);
}

/// `(debug/fbreak fun [pc])`'s arguments, resolved to a location. The
/// offset is not range-checked here; `debugBreak` does it.
fn findByFunction(argv: []repr.Value) raise.Error!Breakpoint {
    try args_core.arity(argv, 1, 2);
    const function = try args_core.getFunction(argv, 0);
    const pc = if (argv.len == 2) try args_core.getInteger(argv, 1) else 0;
    return .{ .definition = function.def.?, .pc = pc };
}

/// `(debug/break source line col)`'s three arguments, resolved to a location.
fn findBySource(argv: []repr.Value) raise.Error!Breakpoint {
    try args_core.fixarity(argv, 3);
    const source = try args_core.getString(argv, 0);
    const line = try args_core.getInteger(argv, 1);
    const column = try args_core.getInteger(argv, 2);
    return debugFindImpl(source, line, column);
}

/// A function's `i`th captured environment. They follow the header
/// immediately, as the allocator lays them out; `gc/mark.zig` and `vm.zig`
/// read the same slots the same way.
inline fn funcEnv(func: *functions.Function, i: u32) *functions.FuncEnv {
    return functions.envsOf(func)[i].?;
}

/// A keyword from a literal. Keywords and symbols are interned by the same
/// function and differ only in how they are wrapped.
inline fn kw(name: [*:0]const u8) repr.Value {
    return wrap.fromKeyword(symbols.ckeyword(name));
}

/// Binds `name`, as a keyword, to `val` in `t`.
inline fn put(t: *tables.Table, name: [*:0]const u8, val: repr.Value) void {
    tables.put(t, kw(name), val);
}

/// Prints a fiber chain innermost-first.
///
/// Recursing to the deepest child and printing on the way back out is what
/// gives the order, with no allocation to release. That matters beyond
/// tidiness: `eprintf` renders a value through an abstract type's `tostring`,
/// and a raise there returns through these frames with nothing outstanding.
fn traceChain(fiber: *fibers.Fiber, state: *TraceState) raise.Error!void {
    if (fiber.child) |child| try traceChain(child, state);

    var index = fiber.frame;

    // The error line is printed once, above the first frame, and before the
    // walk rather than on its first iteration, because the walk is the part
    // that breaks: a corrupted frame chain would otherwise take the message
    // down with it, leaving a collector that frees live locals with no symptom
    // but a silent exit.
    //
    // `index > 0` is what the loop would otherwise supply. A fiber with no
    // frames prints nothing at all and a fiber with frames prints the error
    // line above the first `  in`, so the output is the same either way and
    // producing it asks `traceFrame` for nothing first.
    if (!state.wrote_error and index > 0) {
        const status = fibers.status(fiber);
        try eprintf("%s%s: %s\n", .{
            if (state.prefix != null) state.prefix else @as([*]const u8, ""),
            utils.statusNames[@intFromEnum(status)],
            if (state.error_text != null) state.error_text else utils.statusNames[@intFromEnum(status)],
        });
        state.wrote_error = true;
    }

    while (index > 0) {
        const frame: *vm_state.StackFrame = @ptrCast(@alignCast(fiber.data.? + @as(usize, @intCast(index)) - @as(usize, constants.frame_size)));
        var descriptor: TraceFrame = undefined;
        index = frame.prevframe;
        try traceFrame(frame, &descriptor);

        try eprintf("  in", .{});

        switch (descriptor.name_kind) {
            constants.trace_name_anonymous => try eprintf(" %s", .{@as([*]const u8, "<anonymous>")}),
            constants.trace_name_function => try eprintf(" %s", .{descriptor.name}),
            constants.trace_name_nfunction => if (descriptor.name_prefix != null) {
                try eprintf(" %s/%s", .{ descriptor.name_prefix, descriptor.name });
            } else {
                try eprintf(" %s", .{descriptor.name});
            },
            constants.trace_name_nfunction_bare => try eprintf(" <nfunction>", .{}),
            else => {},
        }

        // `source` is null in exactly the cases that printed no source before:
        // an unnamed nfunction, and a frame that names nothing.
        if (descriptor.source != null) try eprintf(" [%s]", .{descriptor.source});
        if (descriptor.tail != 0) try eprintf(" (tail call)", .{});

        switch (descriptor.loc_kind) {
            constants.trace_loc_sourcemap => try eprintf(" on line %d, column %d", .{ descriptor.line, descriptor.column }),
            constants.trace_loc_pc => try eprintf(" pc=%d", .{descriptor.pc}),
            // The widening is deliberate: `%d` renders the 64 bits the
            // specifier asks for, so the digits are the same for every
            // line number this runtime can produce.
            constants.trace_loc_nfun_line => try eprintf(" on line %d", .{@as(c_long, descriptor.line)}),
            else => {},
        }
        try eprintf("\n", .{});
    }
}
