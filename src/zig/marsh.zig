//! The marshalling protocol: both directions and the three cfunctions over
//! them.
//!
//! One file, because it is one subsystem: nothing else in the tree reaches
//! inside it, and it reaches out only through public entry points. The two
//! directions are one subject; splitting them would buy build combinations and
//! nothing else.
//!
//! ## What the two directions actually share
//!
//! Almost nothing, and that is worth saying because the file reads as though
//! they mirror each other. They share the lead-byte vocabulary, the varint
//! encodings (`pushInt`/`readInt`, `push64`/`read64`), and the *shape* of the
//! reference tables — a growing vector per kind, indices into it on the wire.
//! They do not share a state type, a traversal, or an error discipline. The
//! marshaller walks live objects and appends; the unmarshaller walks bytes it
//! must not trust and allocates. So the file below is two halves with a
//! vocabulary between them rather than one algorithm run backwards.
//!
//! ## Three reference tables, and why they are `janet_v_` vectors
//!
//! `seen` is a `JanetTable` keyed by value, because a marshalled reference is
//! found by asking "have I written this object". `seen_envs` and `seen_defs`
//! are flat vectors scanned linearly, because a funcenv and a funcdef are not
//! Janet values and cannot be table keys — and because the counts are small.
//! Unmarshalling needs no table at all: a reference arrives as an index, so
//! all three of `lookup`, `lookup_envs` and `lookup_defs` are vectors.
//!
//! The vectors are `janet_v_` scratch memory, which the collector releases at
//! the next `janet_try` unwind rather than on the spot. That is what makes the
//! Janet's missing cleanup on a raising path harmless, and it is why this
//! file does not try to improve on it: nothing is freed on the way out of a
//! raise anywhere in this runtime, and a `defer` here would be the only place
//! that was different.
//!
//! ## What can raise through this file
//!
//! Every raise this file *decides* returns an error. Three kinds of call
//! inside the traversal can raise whatever this file does:
//!
//!  - `janet_buffer_push_u8` and its kin, which raise on a buffer that cannot
//!    grow, and are reached from every `push*` below;
//!  - `janet_table_put`, `janet_string`, `janet_abstract` and the other
//!    allocators on the unmarshal side;
//!  - an abstract type's `marshal` and `unmarshal` callbacks, which are
//!    function pointers supplied by `io.c`, `ev.c`, `peg.c` or a native
//!    module, and which raise by jumping whatever language surrounds them.
//!
//! The third is the one that will outlast the others, and it is the same call
//! that keeps `raise.zig`'s own marker on. So the marker here comes off when
//! abstract callbacks stop jumping, not when the last of these subsystems
//! converts.
//!
//! ## The context API is a C perimeter and stays one
//!
//! `janet_marshal_janet`, `janet_unmarshal_int` and the eighteen others are
//! called *from* those callbacks, in the middle of this file's own recursion.
//! `JanetMarshalContext` is public API, the callbacks are C, and none of the
//! signatures has an error channel — so each of these is a `raise.panicking`
//! abi over an error-returning body, and the jump it delivers unwinds the Zig
//! traversal frames underneath it exactly as it did when they were C.

const std = @import("std");
const config = @import("config");
const corefn = @import("corefn.zig");
const raise = @import("raise.zig");
const pp_format = @import("pp/format.zig");
const repr = @import("repr");
const constants = @import("constants");
const vm_lifecycle = @import("vm/lifecycle.zig");
const vm_state = @import("vm/state.zig");
const abstract_type = @import("abstract_type.zig");
const builtin = @import("builtin");
const structs = @import("value/structs.zig");
const tables = @import("value/tables.zig");
const gc_alloc = @import("gc.zig");
const arrays = @import("value/arrays.zig");
const buffers = @import("value/buffers.zig");
const strings = @import("value/strings.zig");
const symbols = @import("value/symbols.zig");
const tuples = @import("value/tuples.zig");
const utils = @import("utils.zig");
const stretchy = @import("stretchy.zig");
const verify = @import("bytecode/verify.zig");
const fibers = @import("value/fibers.zig");
const functions = @import("value/functions.zig");
const registry = @import("registry.zig");
const wrap = @import("value/helpers/wrap.zig");
const args_core = @import("args.zig");
const abstracts = @import("value/abstracts.zig");
const value = @import("value.zig");
const fatal = @import("fatal.zig");
const abi = @import("abi");

/// Whether this build has the event loop, read as a value rather than as a
/// `comptime` condition so the guards below read the same way the C did.
const has_ev = constants.JANET_VM_HAS_EV != 0;

/// The marshalling flag a threaded channel sets to hand ownership across.
///
/// It has the same value as `JANET_MARSHAL_NO_CYCLES`. The aliasing is
/// preserved rather than tidied: the two flags are read by different callers
/// and separating them would change which one a caller gets.
const marshal_decref: c_int = 0x40000;

/// A stack frame's size in `Value` slots. `stackFrame` below is the one place
/// that does the arithmetic.
const frame_size: i32 = constants.JANET_FRAME_SIZE;

/// The three flag bits that live in the marshalled stream rather
/// than in any runtime structure. The first two ride in a fiber's flags word
/// and the third in a stack frame's, and all three are cleared again as they
/// are read back.
/// Two bits the flag word carries **on the wire only**: bits 29 and 30 of
/// `fibers.FiberFlags._wire`, saying that a marshalled fiber is followed by a
/// child and by an environment. A fiber in memory never has them set, which is
/// why they are put in here and taken out again below rather than being fields.
const fiber_flag_haschild: u32 = 1 << 29;
const fiber_flag_hasenv: u32 = 1 << 30;
const stackframe_hasenv: i32 = std.math.minInt(i32);

// ==========================================================================
// The lead bytes
// ==========================================================================

/// The wire vocabulary: the byte that introduces each marshalled value.
///
/// **The numbers are the format.** Each is written out rather than implied by
/// position, and none may move: a stream written by any Janet is read by this
/// one. Non-exhaustive because the lead byte comes off a caller's buffer and
/// may be anything at all -- below 200 it is a small integer, above the last
/// member it is the "unknown byte" error `unmarshalOne` raises.
pub const Lead = enum(u8) {
    real = 200,
    nil = 201,
    false = 202,
    true = 203,
    fiber = 204,
    integer = 205,
    string = 206,
    symbol = 207,
    keyword = 208,
    array = 209,
    tuple = 210,
    table = 211,
    table_proto = 212,
    @"struct" = 213,
    buffer = 214,
    function = 215,
    registry = 216,
    abstract = 217,
    reference = 218,
    funcenv_ref = 219,
    funcdef_ref = 220,
    unsafe_cfunction = 221,
    unsafe_pointer = 222,
    struct_proto = 223,
    _,

    /// The nine whose numbers the configuration decides, which is why they are
    /// constants of this type and not members: an enum's tag values are fixed
    /// where it is declared, and these are not.
    ///
    /// `LB_THREADED_ABSTRACT` and `LB_POINTER_BUFFER` are inside
    /// `#ifdef JANET_EV` in the C original's enum and the seven weak-container
    /// lead bytes that follow them are not. An enum numbers from whatever came
    /// before, so **the weak lead bytes are 226 through 232 in an event-loop
    /// build and 224 through 230 without one**, and a stream written by one
    /// cannot be read by the other.
    ///
    /// That is a defect, it is upstream's, and it is reproduced here rather
    /// than repaired: pinning the numbers would make this implementation
    /// disagree with the C one under `-Dev=false`, which is the one
    /// configuration where the difference shows. `FOUND.md` has the entry and
    /// `test/marsh.zig` pins the arithmetic in both configurations.
    ///
    /// It is also why they cannot be members. Without the event loop
    /// `threaded_abstract` and `table_weakk` are both 224, and an enum with
    /// two members of one value does not compile -- so the collision the
    /// format has is a collision the type would have too.
    pub const threaded_abstract: Lead = @enumFromInt(224);
    pub const pointer_buffer: Lead = @enumFromInt(225);

    const weak_base: u8 = if (has_ev) 226 else 224;

    pub const table_weakk: Lead = @enumFromInt(weak_base + 0);
    pub const table_weakv: Lead = @enumFromInt(weak_base + 1);
    pub const table_weakkv: Lead = @enumFromInt(weak_base + 2);
    pub const table_weakk_proto: Lead = @enumFromInt(weak_base + 3);
    pub const table_weakv_proto: Lead = @enumFromInt(weak_base + 4);
    pub const table_weakkv_proto: Lead = @enumFromInt(weak_base + 5);
    pub const array_weak: Lead = @enumFromInt(weak_base + 6);

    pub inline fn byte(self: Lead) u8 {
        return @intFromEnum(self);
    }

    pub inline fn fromByte(b: u8) Lead {
        return @enumFromInt(b);
    }
};

// ==========================================================================
// Shared helpers
// ==========================================================================

/// The frame header sitting just below a run of locals.
inline fn stackFrame(values: [*]repr.Value) *vm_state.StackFrame {
    return @ptrCast(@alignCast(values - utils.asSize(frame_size)));
}

/// A heap object's memory type, for the containers whose collectable header is
/// their first member.
inline fn gcType(object: anytype) gc_alloc.MemoryType {
    return gc_alloc.memoryTypeOf(&object.gc);
}

/// Abort unless `condition`. Not a raise: a null from an abstract type's
/// `unmarshal` callback is a defect in that callback rather than a program
/// error, so it prints and aborts.
inline fn marshAssert(condition: bool, message: [*:0]const u8) void {
    if (!condition) fatal.fatal(message);
}

/// `JANET_OUT_OF_MEMORY`, which is fatal rather than raising.
inline fn allocated(pointer: ?*anyopaque) ?*anyopaque {
    if (pointer == null) fatal.outOfMemory();
    return pointer;
}

// ==========================================================================
// Environment lookup tables
// ==========================================================================

/// Look inside one entry of an environment, preferring `:value` to `:ref`.
fn entryGetval(env_entry: repr.Value) repr.Value {
    if (repr.checkType(env_entry, repr.Tag.table)) {
        const entry = wrap.toTable(env_entry);
        const checkval = tables.get(entry, value.fromBytes("value", .keyword));
        if (repr.checkType(checkval, repr.Tag.nil)) {
            return tables.get(entry, value.fromBytes("ref", .keyword));
        }
        return checkval;
    } else if (repr.checkType(env_entry, repr.Tag.@"struct")) {
        const entry = wrap.toStruct(env_entry);
        const checkval = structs.get(entry, value.fromBytes("value", .keyword));
        if (repr.checkType(checkval, repr.Tag.nil)) {
            return structs.get(entry, value.fromBytes("ref", .keyword));
        }
        return checkval;
    } else {
        return wrap.fromNil();
    }
}

/// Merge values from an environment into an existing lookup table.
///
/// No error channel and none needed: nothing here decides to raise. The
/// allocations can, and they jump, which is why the file carries the marker.
pub fn envLookupInto(
    renv: *tables.Table,
    env_in: ?*tables.Table,
    prefix: ?[*:0]const u8,
    recurse: c_int,
) void {
    var env = env_in;
    while (env != null) {
        for (0..env.?.capacity) |i| {
            const kv = env.?.slots()[i];
            if (!repr.checkType(kv.key, repr.Tag.symbol)) continue;
            if (prefix != null) {
                const prelen: i32 = @intCast(std.mem.len(@as([*:0]const u8, @ptrCast(prefix))));
                const oldsym = wrap.toSymbol(kv.key);
                const oldlen = strings.head(oldsym).length;
                const symbuf: [*]u8 = @ptrCast(gc_alloc.smalloc(utils.asSize(prelen + oldlen)));
                utils.safeMemcpy(symbuf, prefix, utils.asSize(prelen));
                utils.safeMemcpy(symbuf + utils.asSize(prelen), oldsym, utils.asSize(oldlen));
                const s = value.fromBytes(symbuf[0..@intCast(prelen + oldlen)], .symbol);
                gc_alloc.sfree(symbuf);
                tables.put(renv, s, entryGetval(kv.value));
            } else {
                tables.put(renv, kv.key, entryGetval(kv.value));
            }
        }
        env = if (recurse != 0) env.?.proto else null;
    }
}

/// Make a forward lookup table from an environment, for unmarshalling.
pub fn envLookup(env: *tables.Table) *tables.Table {
    const renv = tables.new(@intCast(env.count));
    envLookupInto(renv, env, null, 1);
    return renv;
}

// ==========================================================================
// Marshalling
// ==========================================================================

const MarshalState = struct {
    buf: *buffers.Buffer,
    seen: tables.Table,
    rreg: ?*tables.Table,
    seen_envs: stretchy.Vector(*functions.FuncEnv),
    seen_defs: stretchy.Vector(*functions.FuncDef),
    nextid: i32,
    maybe_cycles: bool,
};

inline fn pushByte(st: *MarshalState, b: u8) raise.Raising(void) {
    try buffers.pushU8(st.buf, b);
}

inline fn pushBytes(st: *MarshalState, bytes: []const u8) raise.Raising(void) {
    try buffers.pushBytes(st.buf, bytes);
}

/// A 32-bit integer in one, two or five bytes: small naturals bare, a
/// fourteen-bit signed range with a `0x80` tag, everything else behind
/// `LB_INTEGER` and four big-endian bytes.
fn pushInt(st: *MarshalState, x: i32) raise.Raising(void) {
    if (x >= 0 and x < 128) {
        try pushByte(st, @intCast(x));
    } else if (x <= 8191 and x >= -8192) {
        const u: u32 = @bitCast(x);
        const intbuf = [2]u8{
            @as(u8, @truncate(u >> 8)) & 0x3F | 0x80,
            @truncate(u),
        };
        try pushBytes(st, &intbuf);
    } else {
        const u: u32 = @bitCast(x);
        const intbuf = [5]u8{
            Lead.integer.byte(),
            @truncate(u >> 24),
            @truncate(u >> 16),
            @truncate(u >> 8),
            @truncate(u),
        };
        try pushBytes(st, &intbuf);
    }
}

fn pushPointer(st: *MarshalState, ptr: ?*const anyopaque) raise.Raising(void) {
    try pushBytes(st, std.mem.asBytes(&ptr));
}

/// A 64-bit unsigned integer, little endian, length-prefixed above `0xF0`.
fn push64(st: *MarshalState, val: u64) raise.Raising(void) {
    if (val <= 0xF0) {
        try pushByte(st, @intCast(val));
    } else {
        var bytes: [9]u8 = undefined;
        var nbytes: usize = 0;
        var x = val;
        while (x != 0) {
            nbytes += 1;
            bytes[nbytes] = @truncate(x);
            x >>= 8;
        }
        bytes[0] = 0xF0 + @as(u8, @intCast(nbytes));
        try pushBytes(st, bytes[0..@intCast(nbytes + 1)]);
    }
}

/// The recursion guard. `flags` doubles as a depth counter in its low sixteen
/// bits, which is why every recursive call below passes `flags + 1` and why
/// the marshalling flags all live above `0xFFFF`.
inline fn stackCheck(flags: c_int) raise.Raising(void) {
    if ((flags & 0xFFFF) > config.recursion_guard) return raise.panic("stack overflow");
}

/// Record `x` as reference number `nextid` so that a later occurrence can be
/// written as `LB_REFERENCE`. `JANET_MARSHAL_NO_CYCLES` turns this off, at
/// which point a cyclic structure recurses until the guard above stops it.
fn markSeen(st: *MarshalState, x: repr.Value) void {
    if (st.maybe_cycles) {
        tables.put(&st.seen, x, wrap.fromInteger(st.nextid));
        st.nextid += 1;
    }
}

/// A quick check for a fiber that cannot be marshalled. No false positives,
/// possible false negatives -- the full check happens on the way through.
fn fiberCannotBeMarshalled(fiber: *fibers.Fiber) bool {
    if (fibers.status(fiber) == fibers.FiberStatus.alive) return true;
    var i = fiber.frame;
    while (i > 0) {
        const frame = stackFrame(fiber.data.? + utils.asSize(i));
        if (frame.func == null) return true; // has cfunction on stack
        i = frame.prevframe;
    }
    return false;
}

fn marshalOneEnv(st: *MarshalState, env: *functions.FuncEnv, flags: c_int) raise.Raising(void) {
    try stackCheck(flags);
    for (st.seen_envs.items, 0..) |seen, i| {
        if (seen == env) {
            try pushByte(st, Lead.funcenv_ref.byte());
            try pushInt(st, @intCast(i));
            return;
        }
    }
    _ = functions.envValid(env);
    stretchy.push(&st.seen_envs, env);

    if (env.offset > 0 and fiberCannotBeMarshalled(env.as.fiber.?)) {
        // Special case for early detachment: the fiber the values live on is
        // not marshallable, so they are written out as though already
        // detached, and the closure bitset says which slots are real.
        try pushInt(st, 0);
        try pushInt(st, env.length);
        const values = env.as.fiber.?.data.? + utils.asSize(env.offset);
        const bitset = stackFrame(values).func.?.def.?.closure_bitset;
        // `env.length` keeps its width -- `pushInt` above writes it -- but the
        // walk over the values it counts is a plain index.
        for (0..@as(usize, @intCast(env.length))) |k| {
            const word = bitset.?[k >> 5];
            if (1 & (word >> @intCast(k & 0x1F)) != 0) {
                try marshalOne(st, values[k], flags + 1);
            } else {
                try pushByte(st, Lead.nil.byte());
            }
        }
    } else {
        functions.envMaybeDetach(env);
        try pushInt(st, env.offset);
        try pushInt(st, env.length);
        if (env.offset > 0) {
            // On stack variant
            try marshalOne(st, wrap.fromFiber(env.as.fiber.?), flags + 1);
        } else {
            // Off stack variant
            for (0..@as(usize, @intCast(env.length))) |k| {
                try marshalOne(st, env.as.values.?[k], flags + 1);
            }
        }
    }
}

fn marshalU32s(st: *MarshalState, u32s: []const u32) raise.Raising(void) {
    for (u32s) |word| {
        try pushByte(st, @truncate(word));
        try pushByte(st, @truncate(word >> 8));
        try pushByte(st, @truncate(word >> 16));
        try pushByte(st, @truncate(word >> 24));
    }
}

fn marshalOneDef(st: *MarshalState, def: *functions.FuncDef, flags: c_int) raise.Raising(void) {
    try stackCheck(flags);
    for (st.seen_defs.items, 0..) |seen, i| {
        if (seen == def) {
            try pushByte(st, Lead.funcdef_ref.byte());
            try pushInt(st, @intCast(i));
            return;
        }
    }
    stretchy.push(&st.seen_defs, def);

    var i: usize = 0;

    // The whole flag word is the format. It has always been the `int32_t` a
    // `JanetFuncDef` carried, and it stays one.
    comptime std.debug.assert(@bitSizeOf(functions.FuncDefFlags) == 32);
    try pushInt(st, @bitCast(def.flags));
    try pushInt(st, def.slotcount);
    try pushInt(st, def.arity);
    try pushInt(st, def.min_arity);
    try pushInt(st, def.max_arity);
    try pushInt(st, @intCast(def.constants_length));
    try pushInt(st, @intCast(def.bytecode_length));
    try if (def.flags.namedargs)
        pushInt(st, def.named_args_count);
    try if (def.flags.hasenvs)
        pushInt(st, @intCast(def.environments_length));
    try if (def.flags.hasdefs)
        pushInt(st, @intCast(def.defs_length));
    try if (def.flags.hassymbolmap)
        pushInt(st, @intCast(def.symbolmap_length));
    if (def.flags.hasname)
        try marshalOne(st, wrap.fromString(def.name.?), flags);
    if (def.flags.hassource)
        try marshalOne(st, wrap.fromString(def.source.?), flags);

    i = 0;
    while (i < def.constants_length) : (i += 1) {
        try marshalOne(st, def.constantValues()[i], flags + 1);
    }

    i = 0;
    while (i < def.symbolmap_length) : (i += 1) {
        const entry = def.symbols()[i];
        try pushInt(st, @bitCast(entry.birth_pc));
        try pushInt(st, @bitCast(entry.death_pc));
        try pushInt(st, @bitCast(entry.slot_index));
        try marshalOne(st, wrap.fromSymbol(entry.symbol.?), flags + 1);
    }

    try marshalU32s(st, def.instructions());

    i = 0;
    while (i < def.environments_length) : (i += 1) {
        try pushInt(st, def.environmentIndices()[i]);
    }

    i = 0;
    while (i < def.defs_length) : (i += 1) {
        try marshalOneDef(st, def.subdefs()[i], flags + 1);
    }

    if (def.flags.hassourcemap) {
        // Lines are written as deltas, columns absolute.
        var current: i32 = 0;
        i = 0;
        while (i < def.bytecode_length) : (i += 1) {
            const map = def.sourceMappings()[i];
            try pushInt(st, map.line -% current);
            try pushInt(st, map.column);
            current = map.line;
        }
    }

    if (def.flags.hasclobitset) {
        try marshalU32s(st, def.closureBits());
    }
}

fn marshalOneFiber(st: *MarshalState, fiber: *fibers.Fiber, flags: c_int) raise.Raising(void) {
    try stackCheck(flags);
    comptime std.debug.assert(@bitSizeOf(fibers.FiberFlags) == 32);
    var fflags: u32 = @bitCast(fiber.flags);
    if (fiber.child != null) fflags |= fiber_flag_haschild;
    if (fiber.env != null) fflags |= fiber_flag_hasenv;
    if (fibers.status(fiber) == fibers.FiberStatus.alive)
        return raise.panic("cannot marshal alive fiber");
    try pushInt(st, @bitCast(fflags));
    try pushInt(st, fiber.frame);
    try pushInt(st, fiber.stackstart);
    try pushInt(st, fiber.stacktop);
    try pushInt(st, fiber.maxstack);

    // Frames, innermost first, each followed by its slots.
    var i = fiber.frame;
    var j = fiber.stackstart - frame_size;
    while (i > 0) {
        const frame = stackFrame(fiber.data.? + utils.asSize(i));
        if (frame.env != null) frame.flags |= stackframe_hasenv;
        if (frame.func == null) {
            const as_cfun: abi.JanetCFunction = @ptrFromInt(@intFromPtr(frame.pc));
            return pp_format.panicf(
                "cannot marshal fiber with c stackframe (%v)",
                .{wrap.fromCfunction(as_cfun)},
            );
        }
        try pushInt(st, frame.flags);
        try pushInt(st, frame.prevframe);
        const pcdiff: i32 = @intCast(@divExact(
            @intFromPtr(frame.pc) - @intFromPtr(frame.func.?.def.?.bytecode),
            @sizeOf(u32),
        ));
        try pushInt(st, pcdiff);
        try marshalOne(st, wrap.fromFunction(frame.func.?), flags + 1);
        if (frame.env) |env| try marshalOneEnv(st, env, flags + 1);
        var k = i;
        while (k < j) : (k += 1) {
            try marshalOne(st, fiber.data.?[@intCast(k)], flags + 1);
        }
        j = i - frame_size;
        i = frame.prevframe;
    }
    if (fiber.env) |env| {
        try marshalOne(st, wrap.fromTable(env), flags + 1);
    }
    if (fiber.child) |child| {
        try marshalOne(st, wrap.fromFiber(child), flags + 1);
    }
    try marshalOne(st, fiber.last_value, flags + 1);
}

fn marshalOneAbstract(st: *MarshalState, x: repr.Value, flags: c_int) raise.Raising(void) {
    const abstract = wrap.toAbstract(x);
    if (has_ev) {
        // A threaded abstract crosses a thread boundary as a bare pointer in
        // unsafe mode. The refcount is incremented before the message is sent,
        // which is what prevents a "death in transit" -- the sending thread
        // dropping its reference and collecting while the message is still
        // between the two heaps.
        if ((flags & constants.JANET_MARSHAL_UNSAFE) != 0 and
            gcType(abi.abstractHead(abstract)) == gc_alloc.MemoryType.threaded_abstract)
        {
            _ = abstracts.incref(abstract);
            try pushByte(st, Lead.threaded_abstract.byte());
            try pushBytes(st, std.mem.asBytes(&abstract));
            markSeen(st, x);
            return;
        }
    }
    const at = abstract_type.ofAbstract(abstract);
    if (at.marshal) |marshal_fn| {
        try pushByte(st, Lead.abstract.byte());
        try marshalOne(st, value.fromBytes(at.name, .symbol), flags + 1);
        var context: abi.JanetMarshalContext = .{
            .m_state = st,
            .u_state = null,
            .flags = flags + 1,
            .data = null,
            .at = at,
        };
        try marshal_fn(abstract, &context);
    } else {
        return pp_format.panicf("cannot marshal %p", .{x});
    }
}

/// The main body of the marshaller, and the entry point of the mutually
/// recursive group above.
fn marshalOne(st: *MarshalState, x: repr.Value, flags: c_int) raise.Raising(void) {
    try stackCheck(flags);
    const vtype = repr.typeOf(x);

    // Simple primitives first: no reference type, so nothing to memoize.
    switch (vtype) {
        repr.Tag.nil => {
            try pushByte(st, Lead.nil.byte());
            return;
        },
        repr.Tag.boolean => {
            try pushByte(st, if (wrap.toBoolean(x)) Lead.true.byte() else Lead.false.byte());
            return;
        },
        repr.Tag.number => {
            const xval = wrap.toNumber(x);
            if (xval >= -2147483648.0 and xval <= 2147483647.0 and
                xval == @as(f64, @floatFromInt(@as(i32, @intFromFloat(xval)))))
            {
                try pushInt(st, @intFromFloat(xval));
                return;
            }
        },
        else => {},
    }

    // A value already written, or one the reverse registry names.
    if (st.maybe_cycles) {
        const check = tables.get(&st.seen, x);
        if (args_core.checkint(check)) {
            try pushByte(st, Lead.reference.byte());
            try pushInt(st, wrap.toInteger(check));
            return;
        }
    }
    if (st.rreg != null) {
        const check = tables.get(st.rreg.?, x);
        if (repr.checkType(check, repr.Tag.symbol)) {
            markSeen(st, x);
            const regname = wrap.toSymbol(check);
            try pushByte(st, Lead.registry.byte());
            try pushInt(st, strings.head(regname).length);
            try pushBytes(st, strings.bytesOf(regname));
            return;
        }
    }

    switch (vtype) {
        repr.Tag.number => {
            var bytes: [8]u8 = @bitCast(wrap.toNumber(x));
            if (big_endian) std.mem.reverse(u8, &bytes);
            try pushByte(st, Lead.real.byte());
            try pushBytes(st, &bytes);
            markSeen(st, x);
        },
        repr.Tag.string, repr.Tag.symbol, repr.Tag.keyword => {
            const str = wrap.toString(x);
            const length = strings.head(str).length;
            markSeen(st, x);
            try pushByte(st, (switch (vtype) {
                repr.Tag.string => Lead.string,
                repr.Tag.symbol => Lead.symbol,
                else => Lead.keyword,
            }).byte());
            try pushInt(st, length);
            try pushBytes(st, str[0..@intCast(length)]);
        },
        repr.Tag.buffer => {
            const buffer = wrap.toBuffer(x);
            markSeen(st, x);
            if (has_ev) {
                // A buffer over memory the runtime does not own travels as its
                // pointer, in unsafe mode only.
                if ((flags & constants.JANET_MARSHAL_UNSAFE) != 0 and
                    (buffer.gc.flags & constants.JANET_BUFFER_FLAG_NO_REALLOC) != 0)
                {
                    try pushByte(st, Lead.pointer_buffer.byte());
                    try pushInt(st, @intCast(buffer.count));
                    try pushInt(st, @intCast(buffer.capacity));
                    try pushPointer(st, buffer.data);
                    return;
                }
            }
            try pushByte(st, Lead.buffer.byte());
            try pushInt(st, @intCast(buffer.count));
            try pushBytes(st, buffer.slice());
        },
        repr.Tag.array => {
            const a = wrap.toArray(x);
            markSeen(st, x);
            try pushByte(st, if (gcType(a) == gc_alloc.MemoryType.array_weak) Lead.array_weak.byte() else Lead.array.byte());
            try pushInt(st, @intCast(a.count));
            for (0..a.count) |i| {
                try marshalOne(st, a.slice()[i], flags + 1);
            }
        },
        repr.Tag.tuple => {
            const tup = wrap.toTuple(x);
            const count = tuples.head(tup).length;
            const flag = tuples.head(tup).gc.flags >> 16;
            try pushByte(st, Lead.tuple.byte());
            try pushInt(st, count);
            try pushInt(st, flag);
            // `count` keeps its `i32` width: `pushInt` above writes it to the
            // stream. The walk over it is a position.
            for (0..@as(usize, @intCast(count))) |i| {
                try marshalOne(st, tup[i], flags + 1);
            }
            // Marked as seen AFTER marshalling: a tuple is immutable and
            // cannot contain itself, so a self-reference would be a forward
            // reference the reader could not resolve.
            markSeen(st, x);
        },
        repr.Tag.table => {
            const t = wrap.toTable(x);
            markSeen(st, x);
            const has_proto = t.proto != null;
            try pushByte(st, (switch (gcType(t)) {
                gc_alloc.MemoryType.table_weakk => if (has_proto) Lead.table_weakk_proto else Lead.table_weakk,
                gc_alloc.MemoryType.table_weakv => if (has_proto) Lead.table_weakv_proto else Lead.table_weakv,
                gc_alloc.MemoryType.table_weakkv => if (has_proto) Lead.table_weakkv_proto else Lead.table_weakkv,
                else => if (has_proto) Lead.table_proto else Lead.table,
            }).byte());
            try pushInt(st, @intCast(t.count));
            if (has_proto) try marshalOne(st, wrap.fromTable(t.proto.?), flags + 1);
            for (0..t.capacity) |i| {
                const kv = t.slots()[i];
                if (repr.checkType(kv.key, repr.Tag.nil)) continue;
                try marshalOne(st, kv.key, flags + 1);
                try marshalOne(st, kv.value, flags + 1);
            }
        },
        repr.Tag.@"struct" => {
            const struct_ = wrap.toStruct(x);
            const head = structs.head(struct_);
            const count = head.length;
            try pushByte(st, if (head.proto != null) Lead.struct_proto.byte() else Lead.@"struct".byte());
            try pushInt(st, count);
            if (head.proto != null) {
                try marshalOne(st, wrap.fromStruct(head.proto.?), flags + 1);
            }
            // `head.capacity` stays `i32` with the rest of `structs.StructHead`;
            // the walk over the slots it counts is a plain index, as in the
            // table case above.
            for (0..@as(usize, @intCast(head.capacity))) |i| {
                const kv = struct_[i];
                if (repr.checkType(kv.key, repr.Tag.nil)) continue;
                try marshalOne(st, kv.key, flags + 1);
                try marshalOne(st, kv.value, flags + 1);
            }
            // Marked as seen AFTER marshalling, for the reason the tuple case
            // gives.
            markSeen(st, x);
        },
        repr.Tag.abstract => {
            try marshalOneAbstract(st, x, flags);
        },
        repr.Tag.function => {
            try pushByte(st, Lead.function.byte());
            const func = wrap.toFunction(x);
            try pushInt(st, @intCast(func.def.?.environments_length));
            // Marked seen before the def is read, so that a function reachable
            // from its own closure resolves.
            markSeen(st, x);
            try marshalOneDef(st, func.def.?, flags);
            for (0..func.def.?.environments_length) |i| {
                try marshalOneEnv(st, funcEnv(func, i).*.?, flags + 1);
            }
        },
        repr.Tag.fiber => {
            markSeen(st, x);
            try pushByte(st, Lead.fiber.byte());
            try marshalOneFiber(st, wrap.toFiber(x), flags + 1);
        },
        repr.Tag.cfunction => {
            if ((flags & constants.JANET_MARSHAL_UNSAFE) == 0) return noRegistry(x);
            markSeen(st, x);
            try pushByte(st, Lead.unsafe_cfunction.byte());
            const cfn = wrap.toCfunction(x);
            try pushBytes(st, std.mem.asBytes(&cfn));
        },
        repr.Tag.pointer => {
            if ((flags & constants.JANET_MARSHAL_UNSAFE) == 0) return noRegistry(x);
            markSeen(st, x);
            try pushByte(st, Lead.unsafe_pointer.byte());
            try pushPointer(st, wrap.toPointer(x));
        },
        // Unreachable: nil and boolean returned from the first switch, and
        // every other type has a case. Reproduced because the C original's
        // `default` is what the two unsafe cases fall through to.
        else => return noRegistry(x),
    }
}

fn noRegistry(x: repr.Value) raise.Error {
    return pp_format.panicf("no registry value and cannot marshal %p", .{x});
}

/// `func->envs[i]` as an lvalue.
inline fn funcEnv(func: *functions.Function, index: usize) *?*functions.FuncEnv {
    return &functions.envsOf(func)[index];
}

const big_endian = (builtin.cpu.arch.endian() == .big);

pub fn marshal(
    buf: *buffers.Buffer,
    x: repr.Value,
    rreg: ?*tables.Table,
    flags: c_int,
) raise.Raising(void) {
    var st: MarshalState = .{
        .buf = buf,
        .seen = undefined,
        .rreg = rreg,
        .seen_envs = .empty,
        .seen_defs = .empty,
        .nextid = 0,
        .maybe_cycles = (flags & constants.JANET_MARSHAL_NO_CYCLES) == 0,
    };
    _ = tables.init(&st.seen, 0);
    try marshalOne(&st, x, flags);
    tables.deinit(&st.seen);
    stretchy.free(&st.seen_envs);
    stretchy.free(&st.seen_defs);
}

pub const marshalAbi = raise.panicking(marshal).abi;

// ------------------------------------------------- the marshal context API

inline fn marshalState(ctx: *abi.JanetMarshalContext) *MarshalState {
    return @ptrCast(@alignCast(ctx.m_state));
}

/// `size_t` is not 64 bits everywhere -- `riscv32-linux` is one of this
/// project's cross-compile targets -- so the C original's `(int64_t) value`
/// widens before it reinterprets, and `(size_t)` on the way back truncates.
/// Zig's `@bitCast` refuses a width change, which is what makes the two steps
/// visible here and invisible there.
pub fn marshalSize(ctx: *abi.JanetMarshalContext, val: usize) raise.Raising(void) {
    return marshalInt64(ctx, @bitCast(@as(u64, val)));
}

pub fn marshalInt64(ctx: *abi.JanetMarshalContext, val: i64) raise.Raising(void) {
    try push64(marshalState(ctx), @bitCast(val));
}

pub fn marshalInt(ctx: *abi.JanetMarshalContext, val: i32) raise.Raising(void) {
    try pushInt(marshalState(ctx), val);
}

/// Only meaningful in unsafe mode; a pointer means nothing to another process.
pub fn marshalPtr(ctx: *abi.JanetMarshalContext, ptr: ?*const anyopaque) raise.Raising(void) {
    if ((ctx.flags & constants.JANET_MARSHAL_UNSAFE) == 0) {
        return raise.panic("can only marshal pointers in unsafe mode");
    }
    try pushPointer(marshalState(ctx), ptr);
}

pub fn marshalByte(ctx: *abi.JanetMarshalContext, val: u8) raise.Raising(void) {
    try pushByte(marshalState(ctx), val);
}

pub fn marshalBytes(ctx: *abi.JanetMarshalContext, bytes: []const u8) raise.Raising(void) {
    const st = marshalState(ctx);
    if (bytes.len > std.math.maxInt(i32)) return raise.panic("size_t too large to fit in buffer");
    try pushBytes(st, bytes);
}

pub fn marshalJanet(ctx: *abi.JanetMarshalContext, x: repr.Value) raise.Raising(void) {
    return marshalOne(marshalState(ctx), x, ctx.flags + 1);
}

pub fn marshalAbstract(ctx: *abi.JanetMarshalContext, abstract: ?*anyopaque) void {
    markSeen(marshalState(ctx), wrap.fromAbstract(abstract));
}

pub fn marshalFlags(ctx: *abi.JanetMarshalContext) c_int {
    return ctx.flags;
}

/// `janet_marshal_bytes(ctx, bytes, len)`, whose C signature spreads one
/// slice into a pair. `raise.panicking` copies its parameter types into a
/// `callconv(.c)` abi, and a slice is not allowed in one, so this abi is
/// written out -- `raise.panickingArgv` is the same accommodation for the
/// `(argc, argv)` order.
pub fn marshalBytesAbi(
    ctx: *abi.JanetMarshalContext,
    bytes: ?[*]const u8,
    len: usize,
) void {
    return marshalBytes(ctx, if (bytes) |p| p[0..len] else &.{}) catch raise.reportToC(void);
}

// ==========================================================================
// Unmarshalling
// ==========================================================================

/// The C original's first field is a `jmp_buf err` that nothing ever writes to
/// or jumps through: this subsystem reports failure by raising, and always
/// did. It is dropped rather than transcribed.
const UnmarshalState = struct {
    lookup: stretchy.Vector(repr.Value),
    reg: ?*tables.Table,
    lookup_envs: stretchy.Vector(*functions.FuncEnv),
    lookup_defs: stretchy.Vector(*functions.FuncDef),
    start: [*]const u8,
    end: [*]const u8,
};

/// What every `unmarshal*` below answers: the value it decoded, and the
/// position the reader reached. Neither half is an answer on its own -- a
/// cursor with no value decodes nothing, and a value with no cursor leaves
/// the next read nowhere to start -- so the pair is one returned struct.
fn Decoded(comptime T: type) type {
    return struct { value: T, next: [*]const u8 };
}

/// `MARSH_EOS`. The address is computed rather than the pointer, because two
/// call sites below check `data - 1 + len` with a length that may be zero, and
/// wrapping arithmetic is what the C original does there.
inline fn eosAddr(st: *UnmarshalState, addr: usize) raise.Raising(void) {
    if (addr >= @intFromPtr(st.end)) return raise.panic("unexpected end of source");
}

inline fn eos(st: *UnmarshalState, data: [*]const u8) raise.Raising(void) {
    return eosAddr(st, @intFromPtr(data));
}

/// The offset a diagnostic reports, which is a position in the input rather
/// than an address.
inline fn indexOf(st: *UnmarshalState, data: [*]const u8) i32 {
    return @intCast(@intFromPtr(data) - @intFromPtr(st.start));
}

/// Read a 32-bit integer written by `pushInt`.
fn readInt(st: *UnmarshalState, atdata: *[*]const u8) raise.Raising(i32) {
    var data = atdata.*;
    var ret: i32 = undefined;
    try eos(st, data);
    if (data[0] < 128) {
        ret = data[0];
        data += 1;
    } else if (data[0] < 192) {
        try eos(st, data + 1);
        var uret: u32 = (@as(u32, data[0] & 0x3F) << 8) + data[1];
        // Sign extend the 18 most significant bits.
        if ((uret >> 13) != 0) uret |= 0xFFFFC000;
        ret = @bitCast(uret);
        data += 2;
    } else if (data[0] == Lead.integer.byte()) {
        try eos(st, data + 4);
        const ui: u32 = (@as(u32, data[1]) << 24) |
            (@as(u32, data[2]) << 16) |
            (@as(u32, data[3]) << 8) |
            @as(u32, data[4]);
        ret = @bitCast(ui);
        data += 5;
    } else {
        return pp_format.panicf("expected integer, got byte %x at index %d", .{
            @as(u64, data[0]),
            indexOf(st, data),
        });
    }
    atdata.* = data;
    return ret;
}

/// Read a natural number, which is a `readInt` that refuses a negative.
///
/// **This one stays `i32` on purpose.** Its callers are the fields the port
/// measured and decided to keep signed -- `JanetFuncDef`'s `slotcount` and
/// three arities, and `JanetFiber`'s `frame`, `stackstart`, `stacktop`,
/// `maxstack` and `prevframe` -- plus `JanetFuncEnv.offset`, which is
/// *negated* on the untrusted-input path (`env.offset = -offset`) and so is a
/// quantity that really can be negative. A caller reading a **count** wants
/// `readCount` below.
fn readNat(st: *UnmarshalState, atdata: *[*]const u8) raise.Raising(i32) {
    const ret = try readInt(st, atdata);
    if (ret < 0) return pp_format.panicf("expected integer >= 0, got %d", .{ret});
    return ret;
}

/// The same read, as the count it becomes.
///
/// `Signal.fromWire` is the precedent: one place where a wire integer becomes
/// a domain value, named for the domain it enters. The distinction is not a
/// convenience -- it tracks a recorded decision, so the *call site* says which
/// kind of quantity this is where a width could not. `readNat` means "this
/// lands in something the port kept signed"; `readCount` means "this is a
/// count", and its readers then carry no cast at all.
///
/// **The wire encoding is unchanged.** Both read the same bytes through
/// `readInt`, and the refusal message is `readNat`'s single implementation
/// because the message text is behaviour contract. This only refuses to hand
/// the result to something signed.
fn readCount(st: *UnmarshalState, atdata: *[*]const u8) raise.Raising(usize) {
    return @intCast(try readNat(st, atdata));
}

/// Read a 64-bit unsigned integer written by `push64`.
fn read64(st: *UnmarshalState, atdata: *[*]const u8) raise.Raising(u64) {
    const data = atdata.*;
    try eos(st, data);
    if (data[0] <= 0xF0) {
        atdata.* = data + 1;
        return data[0];
    }
    const nbytes: i32 = @as(i32, data[0]) - 0xF0;
    if (nbytes > 8) return raise.panic("invalid 64 bit integer");
    try eos(st, data + utils.asSize(nbytes));
    var ret: u64 = 0;
    var i = nbytes;
    while (i > 0) : (i -= 1) {
        ret = (ret << 8) + data[@intCast(i)];
    }
    atdata.* = data + utils.asSize(nbytes) + 1;
    return ret;
}

fn assertType(x: repr.Value, t: repr.Tag) raise.Raising(void) {
    if (!repr.checkType(x, t)) {
        return pp_format.panicf("expected type %T, got %v", .{ repr.TagSet.one(t), x });
    }
}

fn unmarshalOneEnv(
    st: *UnmarshalState,
    data_in: [*]const u8,
    flags: c_int,
) raise.Raising(Decoded(*functions.FuncEnv)) {
    var data = data_in;
    try eos(st, data);
    if (data[0] == Lead.funcenv_ref.byte()) {
        data += 1;
        const index = try readInt(st, &data);
        if (index < 0 or @as(usize, @intCast(index)) >= st.lookup_envs.items.len)
            return pp_format.panicf("invalid funcenv reference %d", .{index});
        return .{ .value = st.lookup_envs.items[@intCast(index)], .next = data };
    }

    const env = gc_alloc.gcalloc(functions.FuncEnv, .funcenv);
    env.length = 0;
    env.offset = 0;
    env.as.values = null;
    stretchy.push(&st.lookup_envs, env);
    const offset = try readNat(st, &data);
    // `readNat`, and the loop below stays signed with it: both land in
    // `JanetFuncEnv`, whose `length` and `offset` the port kept `i32` --
    // and `offset` is *negated* on the untrusted-input path.
    const length = try readNat(st, &data);
    if (offset > 0) {
        // On stack variant
        const fiberv = try unmarshalOne(st, data, flags);
        data = fiberv.next;
        try assertType(fiberv.value, repr.Tag.fiber);
        env.as.fiber = wrap.toFiber(fiberv.value);
        // A negative offset marks the environment as coming from untrusted
        // input, which is what stops the runtime treating it as live stack.
        env.offset = -offset;
    } else {
        // Off stack variant
        if (length == 0) return raise.panic("invalid funcenv length");
        env.as.values = @ptrCast(@alignCast(allocated(
            utils.malloc(@sizeOf(repr.Value) * utils.asSize(length)),
        )));
        env.offset = 0;
        var i: i32 = 0;
        while (i < length) : (i += 1) {
            const slot = try unmarshalOne(st, data, flags);
            env.as.values.?[@intCast(i)] = slot.value;
            data = slot.next;
        }
    }
    env.length = length;
    return .{ .value = env, .next = data };
}

fn unmarshalU32s(
    st: *UnmarshalState,
    data_in: [*]const u8,
    into: [*]u32,
    n: usize,
) raise.Raising([*]const u8) {
    var data = data_in;
    for (0..n) |i| {
        try eos(st, data + 3);
        into[i] = @as(u32, data[0]) |
            (@as(u32, data[1]) << 8) |
            (@as(u32, data[2]) << 16) |
            (@as(u32, data[3]) << 24);
        data += 4;
    }
    return data;
}

fn unmarshalOneDef(
    st: *UnmarshalState,
    data_in: [*]const u8,
    flags: c_int,
) raise.Raising(Decoded(*functions.FuncDef)) {
    var data = data_in;
    try eos(st, data);
    if (data[0] == Lead.funcdef_ref.byte()) {
        data += 1;
        const index = try readInt(st, &data);
        if (index < 0 or @as(usize, @intCast(index)) >= st.lookup_defs.items.len)
            return pp_format.panicf("invalid funcdef reference %d", .{index});
        return .{ .value = st.lookup_defs.items[@intCast(index)], .next = data };
    }

    // Initialised with values that will not break garbage collection if
    // unmarshalling fails partway.
    const def = gc_alloc.gcalloc(functions.FuncDef, .funcdef);
    def.environments_length = 0;
    def.defs_length = 0;
    def.constants_length = 0;
    def.bytecode_length = 0;
    def.name = null;
    def.source = null;
    def.closure_bitset = null;
    def.defs = null;
    def.environments = null;
    def.constants = null;
    def.bytecode = null;
    def.sourcemap = null;
    def.symbolmap = null;
    def.symbolmap_length = 0;
    def.named_args_count = 0;
    stretchy.push(&st.lookup_defs, def);

    var environments_length: usize = 0;
    var defs_length: usize = 0;
    var symbolmap_length: usize = 0;

    comptime std.debug.assert(@bitSizeOf(functions.FuncDefFlags) == 32);
    def.flags = @bitCast(try readInt(st, &data));
    def.slotcount = try readNat(st, &data);
    def.arity = try readNat(st, &data);
    def.min_arity = try readNat(st, &data);
    def.max_arity = try readNat(st, &data);

    const constants_length = try readCount(st, &data);
    const bytecode_length = try readCount(st, &data);
    if (def.flags.namedargs)
        def.named_args_count = try readNat(st, &data);
    if (def.flags.hasenvs)
        environments_length = try readCount(st, &data);
    if (def.flags.hasdefs)
        defs_length = try readCount(st, &data);
    if (def.flags.hassymbolmap)
        symbolmap_length = try readCount(st, &data);

    if (def.flags.hasname) {
        const x = try unmarshalOne(st, data, flags + 1);
        data = x.next;
        try assertType(x.value, repr.Tag.string);
        def.name = wrap.toString(x.value);
    }
    if (def.flags.hassource) {
        const x = try unmarshalOne(st, data, flags + 1);
        data = x.next;
        try assertType(x.value, repr.Tag.string);
        def.source = wrap.toString(x.value);
    }

    if (constants_length != 0) {
        const pool: [*]repr.Value = @ptrCast(@alignCast(allocated(
            utils.malloc(@sizeOf(repr.Value) * constants_length),
        )));
        def.constants = pool;
        // The length is declared after the fill, so `constantValues()` is
        // empty throughout this loop and the writer works over what it just
        // allocated. That order is not incidental: the def is collectable
        // and `unmarshalOne` allocates, so a length set early would have the
        // mark walk read uninitialised memory.
        const values = pool[0..constants_length];
        for (values) |*slot| {
            const constant = try unmarshalOne(st, data, flags + 1);
            slot.* = constant.value;
            data = constant.next;
        }
    } else {
        def.constants = null;
    }
    def.constants_length = constants_length;

    if (def.flags.hassymbolmap) {
        const map: [*]functions.SymbolMap = @ptrCast(@alignCast(allocated(
            utils.malloc(@sizeOf(functions.SymbolMap) * symbolmap_length),
        )));
        def.symbolmap = map;
        for (map[0..symbolmap_length]) |*entry| {
            entry.birth_pc = @bitCast(try readInt(st, &data));
            entry.death_pc = @bitCast(try readInt(st, &data));
            entry.slot_index = @bitCast(try readInt(st, &data));
            const val = try unmarshalOne(st, data, flags + 1);
            data = val.next;
            if (!repr.checkType(val.value, repr.Tag.symbol)) {
                return pp_format.panicf(
                    "corrupted symbolmap when unmarshalling debug info, got %v",
                    .{val.value},
                );
            }
            entry.symbol = wrap.toSymbol(val.value);
        }
        def.symbolmap_length = symbolmap_length;
    }

    def.bytecode = @ptrCast(@alignCast(allocated(
        utils.malloc(@sizeOf(u32) * bytecode_length),
    )));
    data = try unmarshalU32s(st, data, def.bytecode.?, bytecode_length);
    def.bytecode_length = bytecode_length;

    if (def.flags.hasenvs) {
        const envs: [*]i32 = @ptrCast(@alignCast(allocated(
            utils.calloc(1, @sizeOf(i32) * environments_length),
        )));
        def.environments = envs;
        for (envs[0..environments_length]) |*slot| {
            slot.* = try readInt(st, &data);
        }
    } else {
        def.environments = null;
    }
    def.environments_length = environments_length;

    if (def.flags.hasdefs) {
        const nested: [*]*functions.FuncDef = @ptrCast(@alignCast(allocated(
            utils.calloc(1, @sizeOf(*functions.FuncDef) * defs_length),
        )));
        def.defs = nested;
        for (nested[0..defs_length]) |*slot| {
            const nested_def = try unmarshalOneDef(st, data, flags + 1);
            slot.* = nested_def.value;
            data = nested_def.next;
        }
    } else {
        def.defs = null;
    }
    def.defs_length = defs_length;

    if (def.flags.hassourcemap) {
        def.sourcemap = @ptrCast(@alignCast(allocated(
            utils.malloc(@sizeOf(functions.SourceMapping) * bytecode_length),
        )));
        var current: i32 = 0;
        var i: usize = 0;
        while (i < bytecode_length) : (i += 1) {
            current +%= try readInt(st, &data);
            def.sourceMappings()[@intCast(i)].line = current;
            def.sourceMappings()[@intCast(i)].column = try readInt(st, &data);
        }
    } else {
        def.sourcemap = null;
    }

    if (def.flags.hasclobitset) {
        const n = (def.slotcount + 31) >> 5;
        def.closure_bitset = @ptrCast(@alignCast(allocated(
            utils.malloc(@sizeOf(u32) * utils.asSize(n)),
        )));
        data = try unmarshalU32s(st, data, def.closure_bitset.?, utils.asSize(n));
    }

    if (verify.verify(def) != .ok) return raise.panic("funcdef has invalid bytecode");

    return .{ .value = def, .next = data };
}

fn unmarshalOneFiber(
    st: *UnmarshalState,
    data_in: [*]const u8,
    flags: c_int,
) raise.Raising(Decoded(*fibers.Fiber)) {
    var data = data_in;

    // A new fiber with collector-friendly defaults: it enters the reference
    // table before any of its fields are read, so a failure partway leaves
    // something the collector can walk.
    const fiber = gc_alloc.gcalloc(fibers.Fiber, .fiber);
    fiber.flags = .{};
    fiber.frame = 0;
    fiber.stackstart = 0;
    fiber.stacktop = 0;
    fiber.capacity = 0;
    fiber.maxstack = 0;
    fiber.data = null;
    fiber.child = null;
    fiber.env = null;
    fiber.last_value = wrap.fromNil();
    if (has_ev) {
        fiber.sched_id = 0;
        fiber.supervisor_channel = null;
        fiber.ev_state = null;
        fiber.ev_callback = null;
        fiber.ev_stream = null;
    }

    stretchy.push(&st.lookup, wrap.fromFiber(fiber));

    comptime std.debug.assert(@bitSizeOf(fibers.FiberFlags) == 32);
    var fiber_flags: u32 = @bitCast(try readInt(st, &data));
    const frame = try readNat(st, &data);
    const fiber_stackstart = try readNat(st, &data);
    const fiber_stacktop = try readNat(st, &data);
    const fiber_maxstack = try readNat(st, &data);
    var fiber_env: ?*tables.Table = null;

    if (frame +% frame_size > fiber_stackstart or
        fiber_stackstart > fiber_stacktop or
        fiber_stacktop > fiber_maxstack)
    {
        return raise.panic("fiber has incorrect stack setup");
    }

    // Extra capacity avoids an immediate realloc when arguments are pushed; it
    // is a convenience rather than a requirement, which is what the saturating
    // branch relies on.
    fiber.capacity = if (fiber_stacktop < std.math.maxInt(i32) - 10)
        fiber_stacktop + 10
    else
        std.math.maxInt(i32);
    fiber.data = @ptrCast(@alignCast(allocated(
        utils.malloc(@sizeOf(repr.Value) * utils.asSize(fiber.capacity)),
    )));
    // `fiber.capacity` keeps its width with the rest of the fiber's stack
    // fields; the fill over the slots it counts is a plain index.
    for (0..utils.asSize(fiber.capacity)) |i| {
        fiber.data.?[i] = wrap.fromNil();
    }

    var stack = frame;
    var stacktop = fiber_stackstart - frame_size;
    while (stack > 0) {
        var env: ?*functions.FuncEnv = null;
        var frameflags = try readInt(st, &data);
        const prevframe = try readNat(st, &data);
        const pcdiff = try readNat(st, &data);

        const framestack = fiber.data.? + utils.asSize(stack);
        const framep = stackFrame(framestack);

        const funcv = try unmarshalOne(st, data, flags + 1);
        data = funcv.next;
        try assertType(funcv.value, repr.Tag.function);
        const func = wrap.toFunction(funcv.value);
        const def = func.def.?;

        if (frameflags & stackframe_hasenv != 0) {
            frameflags &= ~stackframe_hasenv;
            const frame_env = try unmarshalOneEnv(st, data, flags + 1);
            env = frame_env.value;
            data = frame_env.next;
        }

        if (def.slotcount != stacktop - stack) {
            return raise.panic("fiber stackframe size mismatch");
        }
        if (pcdiff >= def.bytecode_length) {
            return raise.panic("fiber stackframe has invalid pc");
        }
        if (prevframe +% frame_size > stack) {
            return raise.panic("fiber stackframe does not align with previous frame");
        }

        // Signed: this walks the frame's slot range, whose bounds are the
        // fiber's `i32` stack fields.
        var i: i32 = stack;
        while (i < stacktop) : (i += 1) {
            const slot = try unmarshalOne(st, data, flags + 1);
            fiber.data.?[@intCast(i)] = slot.value;
            data = slot.next;
        }

        framep.env = env;
        framep.pc = def.bytecode.? + utils.asSize(pcdiff);
        framep.prevframe = prevframe;
        framep.flags = frameflags;
        framep.func = func;

        stacktop = stack - frame_size;
        stack = prevframe;
    }
    if (stack < 0) return raise.panic("fiber has too many stackframes");

    if (fiber_flags & fiber_flag_hasenv != 0) {
        fiber_flags &= ~fiber_flag_hasenv;
        const envv = try unmarshalOne(st, data, flags + 1);
        data = envv.next;
        try assertType(envv.value, repr.Tag.table);
        fiber_env = wrap.toTable(envv.value);
    }

    if (fiber_flags & fiber_flag_haschild != 0) {
        fiber_flags &= ~fiber_flag_haschild;
        const fiberv = try unmarshalOne(st, data, flags + 1);
        data = fiberv.next;
        try assertType(fiberv.value, repr.Tag.fiber);
        fiber.child = wrap.toFiber(fiberv.value);
    }

    const last_value = try unmarshalOne(st, data, flags + 1);
    fiber.last_value = last_value.value;
    data = last_value.next;

    // Only now is the fiber valid, so only now are the fields the runtime
    // reads filled in.
    fiber.frame = frame;
    fiber.flags = @bitCast(fiber_flags);
    fiber.stackstart = fiber_stackstart;
    fiber.stacktop = fiber_stacktop;
    fiber.maxstack = fiber_maxstack;
    fiber.env = fiber_env;

    // The one status that arrives from outside this tree. `statusOf` reads
    // six bits and the vocabulary is sixteen values, so the bit pattern an
    // image carries may name none of them -- which is why this is a validation
    // of the *stored* number rather than of the enum.
    const stored = fiber.flags.status;
    if (stored > @intFromEnum(fibers.FiberStatus.alive)) {
        return raise.panic("invalid fiber status");
    }

    return .{ .value = fiber, .next = data };
}

// ----------------------------------------------- the unmarshal context API

inline fn unmarshalState(ctx: *abi.JanetMarshalContext) *UnmarshalState {
    return @ptrCast(@alignCast(ctx.u_state));
}

pub fn unmarshalEnsure(ctx: *abi.JanetMarshalContext, size: usize) raise.Raising(void) {
    return eosAddr(unmarshalState(ctx), @intFromPtr(ctx.data) +% size);
}

pub fn unmarshalInt(ctx: *abi.JanetMarshalContext) raise.Raising(i32) {
    var cursor = ctx.data.?;
    defer ctx.data = cursor;
    return readInt(unmarshalState(ctx), &cursor);
}

pub fn unmarshalSize(ctx: *abi.JanetMarshalContext) raise.Raising(usize) {
    return @truncate(@as(u64, @bitCast(try unmarshalInt64(ctx))));
}

pub fn unmarshalInt64(ctx: *abi.JanetMarshalContext) raise.Raising(i64) {
    var cursor = ctx.data.?;
    defer ctx.data = cursor;
    return @bitCast(try read64(unmarshalState(ctx), &cursor));
}

pub fn unmarshalPtr(ctx: *abi.JanetMarshalContext) raise.Raising(?*anyopaque) {
    if ((ctx.flags & constants.JANET_MARSHAL_UNSAFE) == 0) {
        return raise.panic("can only unmarshal pointers in unsafe mode");
    }
    const st = unmarshalState(ctx);
    try eosAddr(st, @intFromPtr(ctx.data) +% @sizeOf(?*anyopaque) -% 1);
    var ptr: ?*anyopaque = undefined;
    @memcpy(@as([*]u8, @ptrCast(&ptr))[0..@sizeOf(?*anyopaque)], ctx.data.?[0..@sizeOf(?*anyopaque)]);
    ctx.data.? += @sizeOf(?*anyopaque);
    return ptr;
}

pub fn unmarshalByte(ctx: *abi.JanetMarshalContext) raise.Raising(u8) {
    const st = unmarshalState(ctx);
    try eos(st, ctx.data.?);
    const val = ctx.data.?[0];
    ctx.data.? += 1;
    return val;
}

pub fn unmarshalBytes(ctx: *abi.JanetMarshalContext, dest: [*]u8, len: usize) raise.Raising(void) {
    const st = unmarshalState(ctx);
    try eosAddr(st, @intFromPtr(ctx.data) +% len -% 1);
    utils.safeMemcpy(dest, ctx.data.?, len);
    ctx.data.? += len;
}

pub fn unmarshalJanet(ctx: *abi.JanetMarshalContext) raise.Raising(repr.Value) {
    const decoded = try unmarshalOne(unmarshalState(ctx), ctx.data.?, ctx.flags);
    ctx.data = decoded.next;
    return decoded.value;
}

/// Enter an already-allocated abstract into the reference table, and mark the
/// context as having done so. `at` is the flag: `unmarshalOneAbstract` checks
/// that it was cleared, which is how a callback that forgets is caught.
pub fn unmarshalAbstractReuse(ctx: *abi.JanetMarshalContext, p: ?*anyopaque) raise.Raising(void) {
    if (ctx.at == null) {
        return raise.panic("janet_unmarshal_abstract called more than once");
    }
    stretchy.push(&unmarshalState(ctx).lookup, wrap.fromAbstract(p));
    ctx.at = null;
}

pub fn unmarshalAbstract(ctx: *abi.JanetMarshalContext, size: usize) raise.Raising(?*anyopaque) {
    const p = abstracts.newBytes(ctx.at.?, size);
    try unmarshalAbstractReuse(ctx, p);
    return p;
}

/// Always raises. `JANET_THREADS` is defined by nothing in this tree, so the
/// C original's other arm has never been compiled -- see `FOUND.md`.
pub fn unmarshalAbstractThreaded(ctx: *abi.JanetMarshalContext, size: usize) raise.Raising(?*anyopaque) {
    _ = ctx;
    _ = size;
    return raise.panic("threaded abstracts not supported");
}

pub fn unmarshalFlags(ctx: *abi.JanetMarshalContext) c_int {
    return ctx.flags;
}

fn unmarshalOneAbstract(
    st: *UnmarshalState,
    data_in: [*]const u8,
    flags: c_int,
) raise.Raising(Decoded(repr.Value)) {
    const key = try unmarshalOne(st, data_in, flags + 1);
    const data = key.next;
    const stored_at = registry.getAbstractType(key.value);
    if (stored_at == null) return raise.panic("unknown abstract type");
    const at = stored_at.?;
    if (at.unmarshal) |unmarshal_fn| {
        var context: abi.JanetMarshalContext = .{
            .m_state = null,
            .u_state = st,
            .flags = flags,
            .data = data,
            .at = stored_at,
        };
        const abst = try unmarshal_fn(&context);
        marshAssert(abst != null, "null pointer abstract");
        const decoded = wrap.fromAbstract(abst);
        if (context.at != null) return raise.panic("janet_unmarshal_abstract not called");
        return .{ .value = decoded, .next = context.data.? };
    }
    return raise.panic("invalid abstract type - no unmarshal function pointer");
}

/// The main body of the unmarshaller.
fn unmarshalOne(
    st: *UnmarshalState,
    data_in: [*]const u8,
    flags: c_int,
) raise.Raising(Decoded(repr.Value)) {
    var data: [*]const u8 = data_in;
    var out: repr.Value = undefined;
    try stackCheck(flags);
    try eos(st, data);
    const lead = Lead.fromByte(data[0]);
    if (data[0] < Lead.real.byte()) {
        const immediate = wrap.fromInteger(try readInt(st, &data));
        return .{ .value = immediate, .next = data };
    }

    // The two event-loop lead bytes are tested before the switch rather than
    // inside it: without `JANET_EV` their numbers belong to the weak
    // containers, which is the renumbering `weak_base` documents.
    if (has_ev) {
        switch (lead) {
            Lead.pointer_buffer => {
                data += 1;
                // `readNat`, not `readCount`: these two go straight to
                // `buffers.pointerUnsafe`, whose `i32` is not residue -- its
                // other caller is the FFI surface, where the values come from
                // a Janet program and `count < 0` is live and pinned by
                // `test/buffer_array.zig`.
                const count = try readNat(st, &data);
                const capacity = try readNat(st, &data);
                try eos(st, data + @sizeOf(?*anyopaque));
                if ((flags & constants.JANET_MARSHAL_UNSAFE) == 0) {
                    return pp_format.panicf(
                        "unsafe flag not given, will not unmarshal raw pointer at index %d",
                        .{indexOf(st, data)},
                    );
                }
                var ptr: ?*anyopaque = undefined;
                @memcpy(@as([*]u8, @ptrCast(&ptr))[0..@sizeOf(?*anyopaque)], data[0..@sizeOf(?*anyopaque)]);
                data += @sizeOf(?*anyopaque);
                const buffer = try buffers.pointerUnsafe(ptr, capacity, count);
                out = wrap.fromBuffer(buffer);
                stretchy.push(&st.lookup, out);
                return .{ .value = out, .next = data };
            },
            Lead.threaded_abstract => {
                try eos(st, data + @sizeOf(?*anyopaque));
                data += 1;
                if ((flags & constants.JANET_MARSHAL_UNSAFE) == 0) {
                    return pp_format.panicf(
                        "unsafe flag not given, will not unmarshal threaded abstract pointer at index %d",
                        .{indexOf(st, data)},
                    );
                }
                var ptr: ?*anyopaque = undefined;
                @memcpy(@as([*]u8, @ptrCast(&ptr))[0..@sizeOf(?*anyopaque)], data[0..@sizeOf(?*anyopaque)]);
                data += @sizeOf(?*anyopaque);

                if ((flags & marshal_decref) != 0) {
                    // Decrement immediately rather than putting it on the heap.
                    _ = abstracts.decref(ptr);
                    out = wrap.fromNil();
                } else {
                    out = wrap.fromAbstract(ptr);
                    const check = tables.get(&vm_state.current().ev.threaded_abstracts, out);
                    if (repr.checkType(check, repr.Tag.nil)) {
                        // Transfers the reference from the channel's buffer to
                        // this heap.
                        tables.put(&vm_state.current().ev.threaded_abstracts, out, wrap.fromFalse());
                    } else {
                        // The heap reference is already accounted for, so the
                        // channel's is released.
                        _ = abstracts.decref(ptr);
                    }
                }
                stretchy.push(&st.lookup, out);
                return .{ .value = out, .next = data };
            },
            else => {},
        }
    }

    switch (lead) {
        Lead.nil => return .{ .value = wrap.fromNil(), .next = data + 1 },
        Lead.false => return .{ .value = wrap.fromFalse(), .next = data + 1 },
        Lead.true => return .{ .value = wrap.fromTrue(), .next = data + 1 },
        Lead.integer => {
            try eos(st, data + 4);
            const ui: u32 = @as(u32, data[4]) |
                (@as(u32, data[3]) << 8) |
                (@as(u32, data[2]) << 16) |
                (@as(u32, data[1]) << 24);
            return .{ .value = wrap.fromInteger(@bitCast(ui)), .next = data + 5 };
        },
        Lead.real => {
            try eos(st, data + 8);
            var bytes: [8]u8 = undefined;
            @memcpy(&bytes, data[1..9]);
            if (big_endian) std.mem.reverse(u8, &bytes);
            out = wrap.fromNumberSafe(@bitCast(bytes));
            stretchy.push(&st.lookup, out);
            return .{ .value = out, .next = data + 9 };
        },
        Lead.string, Lead.symbol, Lead.buffer, Lead.keyword, Lead.registry => {
            data += 1;
            const len = try readCount(st, &data);
            try eosAddr(st, @intFromPtr(data) -% 1 +% len);
            switch (lead) {
                Lead.string => out = wrap.fromString(strings.new(data[0..len])),
                Lead.symbol => out = wrap.fromSymbol(symbols.new(data[0..len])),
                Lead.keyword => out = value.fromBytes(data[0..len], .keyword),
                Lead.registry => {
                    if (st.reg != null) {
                        out = tables.get(st.reg.?, value.fromBytes(data[0..len], .symbol));
                    } else {
                        out = wrap.fromNil();
                    }
                },
                else => {
                    const buffer = buffers.new(@intCast(len));
                    buffer.count = len;
                    utils.safeMemcpy(buffer.data, data, len);
                    out = wrap.fromBuffer(buffer);
                },
            }
            stretchy.push(&st.lookup, out);
            return .{ .value = out, .next = data + len };
        },
        Lead.fiber => {
            const fiber = try unmarshalOneFiber(st, data + 1, flags + 1);
            return .{ .value = wrap.fromFiber(fiber.value), .next = fiber.next };
        },
        Lead.function => {
            data += 1;
            const len = try readCount(st, &data);
            if (len > 255) {
                return pp_format.panicf("invalid function - too many environments (%d)", .{@as(i64, @intCast(len))});
            }
            const func = gc_alloc.gcallocWithPayload(
                functions.Function,
                .function,
                len *% @sizeOf(*functions.FuncEnv),
            );
            func.def = null;
            for (0..len) |i| funcEnv(func, i).* = null;
            out = wrap.fromFunction(func);
            stretchy.push(&st.lookup, out);
            const def = try unmarshalOneDef(st, data, flags + 1);
            data = def.next;
            func.def = def.value;
            for (0..len) |i| {
                const env = try unmarshalOneEnv(st, data, flags + 1);
                funcEnv(func, i).* = env.value;
                data = env.next;
            }
            return .{ .value = out, .next = data };
        },
        Lead.abstract => {
            return unmarshalOneAbstract(st, data + 1, flags);
        },
        Lead.reference,
        Lead.array,
        Lead.array_weak,
        Lead.tuple,
        Lead.@"struct",
        Lead.struct_proto,
        Lead.table,
        Lead.table_proto,
        Lead.table_weakk,
        Lead.table_weakv,
        Lead.table_weakkv,
        Lead.table_weakk_proto,
        Lead.table_weakv_proto,
        Lead.table_weakkv_proto,
        => {
            // Everything that opens with a count.
            data += 1;
            const len = try readCount(st, &data);
            // A denial-of-service check: a count far larger than the input
            // cannot be honest, and allocating for it first would be the
            // damage.
            if (lead != Lead.reference) {
                try eosAddr(st, @intFromPtr(data) -% 1 +% len);
            }
            if (lead == Lead.array or lead == Lead.array_weak) {
                const array = if (lead == Lead.array_weak)
                    arrays.weak(@intCast(len))
                else
                    arrays.new(@intCast(len));
                array.count = len;
                out = wrap.fromArray(array);
                stretchy.push(&st.lookup, out);
                for (0..len) |i| {
                    const item = try unmarshalOne(st, data, flags + 1);
                    array.slice()[i] = item.value;
                    data = item.next;
                }
            } else if (lead == Lead.tuple) {
                const tup = tuples.begin(@intCast(len));
                const flag = try readInt(st, &data);
                // The cast avoids a left shift of a negative value.
                tuples.head(tup).gc.flags |= @bitCast(@as(u32, @bitCast(flag)) << 16);
                for (0..len) |i| {
                    const item = try unmarshalOne(st, data, flags + 1);
                    tup[i] = item.value;
                    data = item.next;
                }
                out = wrap.fromTuple(tuples.end(tup));
                stretchy.push(&st.lookup, out);
            } else if (lead == Lead.@"struct" or lead == Lead.struct_proto) {
                const struct_ = structs.begin(@intCast(len));
                if (lead == Lead.struct_proto) {
                    const proto = try unmarshalOne(st, data, flags + 1);
                    data = proto.next;
                    try assertType(proto.value, repr.Tag.@"struct");
                    structs.head(struct_).proto = wrap.toStruct(proto.value);
                }
                for (0..len) |_| {
                    const key = try unmarshalOne(st, data, flags + 1);
                    const val = try unmarshalOne(st, key.next, flags + 1);
                    data = val.next;
                    structs.put(struct_, key.value, val.value);
                }
                out = wrap.fromStruct(structs.end(struct_));
                stretchy.push(&st.lookup, out);
            } else if (lead == Lead.reference) {
                // No `len < 0` arm: `readCount` refused a negative at the
                // seam, which is the whole point of it being a separate
                // function from `readNat`.
                if (len >= st.lookup.items.len) {
                    return pp_format.panicf("invalid reference %d", .{@as(i64, @intCast(len))});
                }
                out = st.lookup.items[len];
            } else {
                const t = switch (lead) {
                    Lead.table_weakk_proto, Lead.table_weakk => tables.weakk(@intCast(len)),
                    Lead.table_weakv_proto, Lead.table_weakv => tables.weakv(@intCast(len)),
                    Lead.table_weakkv_proto, Lead.table_weakkv => tables.weakkv(@intCast(len)),
                    else => tables.new(@intCast(len)),
                };
                out = wrap.fromTable(t);
                stretchy.push(&st.lookup, out);
                switch (lead) {
                    Lead.table_proto,
                    Lead.table_weakk_proto,
                    Lead.table_weakv_proto,
                    Lead.table_weakkv_proto,
                    => {
                        const proto = try unmarshalOne(st, data, flags + 1);
                        data = proto.next;
                        try assertType(proto.value, repr.Tag.table);
                        t.proto = wrap.toTable(proto.value);
                    },
                    else => {},
                }
                for (0..len) |_| {
                    const key = try unmarshalOne(st, data, flags + 1);
                    const val = try unmarshalOne(st, key.next, flags + 1);
                    data = val.next;
                    tables.put(t, key.value, val.value);
                }
            }
            return .{ .value = out, .next = data };
        },
        Lead.unsafe_pointer => {
            try eos(st, data + @sizeOf(?*anyopaque));
            data += 1;
            if ((flags & constants.JANET_MARSHAL_UNSAFE) == 0) {
                return pp_format.panicf(
                    "unsafe flag not given, will not unmarshal raw pointer at index %d",
                    .{indexOf(st, data)},
                );
            }
            var ptr: ?*anyopaque = undefined;
            @memcpy(@as([*]u8, @ptrCast(&ptr))[0..@sizeOf(?*anyopaque)], data[0..@sizeOf(?*anyopaque)]);
            data += @sizeOf(?*anyopaque);
            out = wrap.fromPointer(ptr);
            stretchy.push(&st.lookup, out);
            return .{ .value = out, .next = data };
        },
        Lead.unsafe_cfunction => {
            try eos(st, data + @sizeOf(abi.JanetCFunction));
            data += 1;
            if ((flags & constants.JANET_MARSHAL_UNSAFE) == 0) {
                return pp_format.panicf(
                    "unsafe flag not given, will not unmarshal function pointer at index %d",
                    .{indexOf(st, data)},
                );
            }
            var cfn: abi.JanetCFunction = undefined;
            @memcpy(
                @as([*]u8, @ptrCast(&cfn))[0..@sizeOf(abi.JanetCFunction)],
                data[0..@sizeOf(abi.JanetCFunction)],
            );
            data += @sizeOf(abi.JanetCFunction);
            out = wrap.fromCfunction(cfn);
            stretchy.push(&st.lookup, out);
            return .{ .value = out, .next = data };
        },
        else => {
            return pp_format.panicf("unknown byte %x at index %d", .{
                @as(u64, data[0]),
                indexOf(st, data),
            });
        },
    }
}

pub fn unmarshal(
    bytes: []const u8,
    flags: c_int,
    reg: ?*tables.Table,
    next: ?*[*]const u8,
) raise.Raising(repr.Value) {
    var st: UnmarshalState = .{
        .start = bytes.ptr,
        .end = bytes.ptr + bytes.len,
        .lookup_defs = .empty,
        .lookup_envs = .empty,
        .lookup = .empty,
        .reg = reg,
    };
    const decoded = try unmarshalOne(&st, bytes.ptr, flags);
    if (next) |slot| slot.* = decoded.next;
    stretchy.free(&st.lookup_defs);
    stretchy.free(&st.lookup_envs);
    stretchy.free(&st.lookup);
    return decoded.value;
}

/// `janet_unmarshal(bytes, len, flags, reg, next)`. Written out for the same
/// reason as `marshalBytesAbi` above.
pub fn unmarshalAbi(
    bytes: ?[*]const u8,
    len: usize,
    flags: c_int,
    reg: ?*tables.Table,
    next: ?*[*]const u8,
) repr.Value {
    return unmarshal(if (bytes) |p| p[0..len] else &.{}, flags, reg, next) catch raise.reportToC(repr.Value);
}

// ==========================================================================
// The cfunction surface
// ==========================================================================

fn cfunEnvLookup(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.fixarity(argv, 1);
    const env = try args_core.getTable(argv, 0);
    return wrap.fromTable(envLookup(env));
}

fn cfunMarshal(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try args_core.arity(argv, 1, 4);
    var rreg: ?*tables.Table = null;
    var flags: c_int = 0;
    if (argv.len > 1) rreg = try args_core.getTable(argv, 1);
    const buffer = if (argv.len > 2) try args_core.getBuffer(argv, 2) else buffers.new(10);
    if (argv.len > 3 and repr.truthy(argv[3])) flags |= constants.JANET_MARSHAL_NO_CYCLES;
    try marshal(buffer, argv[0], rreg, flags);
    return wrap.fromBuffer(buffer);
}

fn cfunUnmarshal(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"unmarshal"}));
    try args_core.arity(argv, 1, 2);
    const view = try args_core.getBytes(argv, 0);
    const reg: ?*tables.Table = if (argv.len > 1) try args_core.getTable(argv, 1) else null;
    return unmarshal(args_core.viewBytes(view), 0, reg, null);
}

pub fn libMarsh(env: *tables.Table) void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("marshal", &cfunMarshal, @src(), "(marshal x &opt reverse-lookup buffer no-cycles)", "Marshal a value into a buffer and return the buffer. The buffer " ++
            "can then later be unmarshalled to reconstruct the initial value. " ++
            "Optionally, one can pass in a reverse lookup table to not marshal " ++
            "aliased values that are found in the table. Then a forward " ++
            "lookup table can be used to recover the original value when " ++
            "unmarshalling."),
        corefn.reg("unmarshal", &cfunUnmarshal, @src(), "(unmarshal buffer &opt lookup)", "Unmarshal a value from a buffer. An optional lookup table " ++
            "can be provided to allow for aliases to be resolved. Returns the value " ++
            "unmarshalled from the buffer."),
        corefn.reg("env-lookup", &cfunEnvLookup, @src(), "(env-lookup env)", "Creates a forward lookup table for unmarshalling from an environment. " ++
            "To create a reverse lookup table, use the invert function to swap keys " ++
            "and values in the returned table."),
    };
    corefn.install(env, entries);
}
