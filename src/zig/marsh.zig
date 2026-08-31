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
const corefn = @import("corefn");
const raise = @import("raise");
const pp_format = @import("pp/format.zig");
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const vm_lifecycle = @import("vm/lifecycle.zig");
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

/// `src/core/util.h`, declared here rather than in `cabi.zig`.
extern fn safe_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void;

/// Whether this build has the event loop, read as a value rather than as a
/// `comptime` condition so the guards below read the same way the C did.
const has_ev = constants.JANET_VM_HAS_EV != 0;

/// `JANET_MARSHAL_DECREF` from `src/core/util.h`. A plain integer, so
/// declaring it here rather than translating the header costs nothing and
/// keeps the Windows cross-compile intact.
///
/// It has the same value as Janet's `JANET_MARSHAL_NO_CYCLES`. The aliasing
/// is preserved rather than tidied: the two flags are read by different
/// callers and separating them would change which one a caller gets.
const marshal_decref: c_int = 0x40000;

/// `janet.h`'s frame size. The function-like macros over it do not survive
/// translation and are written out below.
const frame_size: i32 = constants.JANET_FRAME_SIZE;

/// `marsh.c`'s own three flag bits, which live in the marshalled stream rather
/// than in any runtime structure. The first two ride in a fiber's flags word
/// and the third in a stack frame's, and all three are cleared again as they
/// are read back.
const fiber_flag_haschild: i32 = 1 << 29;
const fiber_flag_hasenv: i32 = 1 << 30;
const stackframe_hasenv: i32 = std.math.minInt(i32);

// ==========================================================================
// The lead bytes
// ==========================================================================

// The wire vocabulary. Written out with their values rather than as an
// increasing enum, because two of them exist only under `JANET_EV` and the C
// original lets the rest renumber around them -- see `weak_base` below.
const lb_real: u8 = 200;
const lb_nil: u8 = 201;
const lb_false: u8 = 202;
const lb_true: u8 = 203;
const lb_fiber: u8 = 204;
const lb_integer: u8 = 205;
const lb_string: u8 = 206;
const lb_symbol: u8 = 207;
const lb_keyword: u8 = 208;
const lb_array: u8 = 209;
const lb_tuple: u8 = 210;
const lb_table: u8 = 211;
const lb_table_proto: u8 = 212;
const lb_struct: u8 = 213;
const lb_buffer: u8 = 214;
const lb_function: u8 = 215;
const lb_registry: u8 = 216;
const lb_abstract: u8 = 217;
const lb_reference: u8 = 218;
const lb_funcenv_ref: u8 = 219;
const lb_funcdef_ref: u8 = 220;
const lb_unsafe_cfunction: u8 = 221;
const lb_unsafe_pointer: u8 = 222;
const lb_struct_proto: u8 = 223;

/// `LB_THREADED_ABSTRACT` and `LB_POINTER_BUFFER` are inside `#ifdef JANET_EV`
/// in the C original's enum, and the seven weak-container lead bytes that
/// follow them are not. An enum numbers from whatever came before, so **the
/// weak lead bytes are 226 through 232 in an event-loop build and 224 through
/// 230 without one**, and a stream written by one cannot be read by the other.
///
/// That is a defect, it is upstream's, and it is reproduced here rather than
/// repaired: pinning the numbers would make this implementation disagree with
/// the C one under `-Dev=false`, which is the one configuration where the
/// difference shows. `FOUND.md` has the entry and `test/marsh.zig` pins the
/// arithmetic in both configurations.
const lb_threaded_abstract: u8 = 224;
const lb_pointer_buffer: u8 = 225;
const weak_base: u8 = if (has_ev) 226 else 224;

const lb_table_weakk: u8 = weak_base + 0;
const lb_table_weakv: u8 = weak_base + 1;
const lb_table_weakkv: u8 = weak_base + 2;
const lb_table_weakk_proto: u8 = weak_base + 3;
const lb_table_weakv_proto: u8 = weak_base + 4;
const lb_table_weakkv_proto: u8 = weak_base + 5;
const lb_array_weak: u8 = weak_base + 6;

// ==========================================================================
// Shared helpers
// ==========================================================================

/// A sign-preserving widening, matching C's `int32_t` to `size_t` conversion
/// in expressions like `fiber->data + fiber->frame`.
inline fn asSize(n: i32) usize {
    return @bitCast(@as(isize, n));
}

/// `janet_stack_frame` from `src/core/fiber.h`.
inline fn stackFrame(values: [*]repr.Value) *types.JanetStackFrame {
    return @ptrCast(@alignCast(values - asSize(frame_size)));
}

/// `janet_gc_type` from `src/core/gc.h`, for the containers whose collectable
/// header is their first member.
inline fn gcType(object: anytype) types.MemoryType {
    return object.*.gc.memoryType();
}

/// `janet_wrap_integer`, written out rather than called. `janet.h` declares the
/// function beside its macro and `wrap.c` defines it only for the two nanbox
/// layouts, so a tagged build has no such symbol and a Zig caller -- which
/// cannot use the macro -- does not link. `pp_pretty.zig` and `value_access.zig`
/// write it out for the same reason and `FOUND.md` has the defect.
inline fn wrapInteger(x: i32) repr.Value {
    return wrap.fromNumber(@floatFromInt(x));
}

/// `janet_assert` from `src/core/util.h`, a macro over `JANET_EXIT`. Not a
/// raise: a `NULL` from an abstract type's `unmarshal` callback is a defect in
/// that callback rather than a program error, and the C original prints and
/// calls `abort`.
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
    renv: *types.JanetTable,
    env_in: ?*types.JanetTable,
    prefix: ?[*:0]const u8,
    recurse: c_int,
) callconv(.c) void {
    var env = env_in;
    while (env != null) {
        var i: i32 = 0;
        while (i < env.?.capacity) : (i += 1) {
            const kv = env.?.slots()[@intCast(i)];
            if (!repr.checkType(kv.key, repr.Tag.symbol)) continue;
            if (prefix != null) {
                const prelen: i32 = @intCast(std.mem.len(@as([*:0]const u8, @ptrCast(prefix))));
                const oldsym = wrap.toSymbol(kv.key);
                const oldlen = types.stringHead(oldsym).length;
                const symbuf: [*]u8 = @ptrCast(gc_alloc.smalloc(asSize(prelen + oldlen)));
                safe_memcpy(symbuf, prefix, asSize(prelen));
                safe_memcpy(symbuf + asSize(prelen), oldsym, asSize(oldlen));
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
pub fn envLookup(env: *types.JanetTable) *types.JanetTable {
    const renv = tables.new(env.*.count);
    envLookupInto(renv, env, null, 1);
    return renv;
}

// ==========================================================================
// Marshalling
// ==========================================================================

const MarshalState = struct {
    buf: *types.JanetBuffer,
    seen: types.JanetTable,
    rreg: ?*types.JanetTable,
    seen_envs: ?[*]*types.JanetFuncEnv,
    seen_defs: ?[*]*types.JanetFuncDef,
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
            lb_integer,
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
        tables.put(&st.seen, x, wrapInteger(st.nextid));
        st.nextid += 1;
    }
}

/// A quick check for a fiber that cannot be marshalled. No false positives,
/// possible false negatives -- the full check happens on the way through.
fn fiberCannotBeMarshalled(fiber: *types.JanetFiber) bool {
    if (fibers.status(fiber) == types.FiberStatus.alive) return true;
    var i = fiber.*.frame;
    while (i > 0) {
        const frame = stackFrame(fiber.*.data.? + asSize(i));
        if (frame.func == null) return true; // has cfunction on stack
        i = frame.prevframe;
    }
    return false;
}

fn marshalOneEnv(st: *MarshalState, env: *types.JanetFuncEnv, flags: c_int) raise.Raising(void) {
    try stackCheck(flags);
    var i: i32 = 0;
    while (i < stretchy.count(*types.JanetFuncEnv, st.seen_envs)) : (i += 1) {
        if (st.seen_envs.?[@intCast(i)] == env) {
            try pushByte(st, lb_funcenv_ref);
            try pushInt(st, i);
            return;
        }
    }
    _ = functions.envValid(env);
    stretchy.push(*types.JanetFuncEnv, &st.seen_envs, env);

    if (env.*.offset > 0 and fiberCannotBeMarshalled(env.*.as.fiber.?)) {
        // Special case for early detachment: the fiber the values live on is
        // not marshallable, so they are written out as though already
        // detached, and the closure bitset says which slots are real.
        try pushInt(st, 0);
        try pushInt(st, env.*.length);
        const values = env.*.as.fiber.?.data.? + asSize(env.*.offset);
        const bitset = stackFrame(values).func.?.def.?.closure_bitset;
        var k: i32 = 0;
        while (k < env.*.length) : (k += 1) {
            const word = bitset.?[@intCast(k >> 5)];
            if (1 & (word >> @intCast(k & 0x1F)) != 0) {
                try marshalOne(st, values[@intCast(k)], flags + 1);
            } else {
                try pushByte(st, lb_nil);
            }
        }
    } else {
        functions.envMaybeDetach(env);
        try pushInt(st, env.*.offset);
        try pushInt(st, env.*.length);
        if (env.*.offset > 0) {
            // On stack variant
            try marshalOne(st, wrap.fromFiber(env.*.as.fiber.?), flags + 1);
        } else {
            // Off stack variant
            var k: i32 = 0;
            while (k < env.*.length) : (k += 1) {
                try marshalOne(st, env.*.as.values.?[@intCast(k)], flags + 1);
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

fn marshalOneDef(st: *MarshalState, def: *types.JanetFuncDef, flags: c_int) raise.Raising(void) {
    try stackCheck(flags);
    var i: i32 = 0;
    while (i < stretchy.count(*types.JanetFuncDef, st.seen_defs)) : (i += 1) {
        if (st.seen_defs.?[@intCast(i)] == def) {
            try pushByte(st, lb_funcdef_ref);
            try pushInt(st, i);
            return;
        }
    }
    stretchy.push(*types.JanetFuncDef, &st.seen_defs, def);

    try pushInt(st, def.*.flags);
    try pushInt(st, def.*.slotcount);
    try pushInt(st, def.*.arity);
    try pushInt(st, def.*.min_arity);
    try pushInt(st, def.*.max_arity);
    try pushInt(st, def.*.constants_length);
    try pushInt(st, def.*.bytecode_length);
    try if (def.*.flags & constants.JANET_FUNCDEF_FLAG_NAMEDARGS != 0)
        pushInt(st, def.*.named_args_count);
    try if (def.*.flags & constants.JANET_FUNCDEF_FLAG_HASENVS != 0)
        pushInt(st, def.*.environments_length);
    try if (def.*.flags & constants.JANET_FUNCDEF_FLAG_HASDEFS != 0)
        pushInt(st, def.*.defs_length);
    try if (def.*.flags & constants.JANET_FUNCDEF_FLAG_HASSYMBOLMAP != 0)
        pushInt(st, def.*.symbolmap_length);
    if (def.*.flags & constants.JANET_FUNCDEF_FLAG_HASNAME != 0)
        try marshalOne(st, wrap.fromString(def.*.name.?), flags);
    if (def.*.flags & constants.JANET_FUNCDEF_FLAG_HASSOURCE != 0)
        try marshalOne(st, wrap.fromString(def.*.source.?), flags);

    i = 0;
    while (i < def.*.constants_length) : (i += 1) {
        try marshalOne(st, def.*.constantValues()[@intCast(i)], flags + 1);
    }

    i = 0;
    while (i < def.*.symbolmap_length) : (i += 1) {
        const entry = def.*.symbols()[@intCast(i)];
        try pushInt(st, @bitCast(entry.birth_pc));
        try pushInt(st, @bitCast(entry.death_pc));
        try pushInt(st, @bitCast(entry.slot_index));
        try marshalOne(st, wrap.fromSymbol(entry.symbol.?), flags + 1);
    }

    try marshalU32s(st, def.*.instructions());

    i = 0;
    while (i < def.*.environments_length) : (i += 1) {
        try pushInt(st, def.*.environmentIndices()[@intCast(i)]);
    }

    i = 0;
    while (i < def.*.defs_length) : (i += 1) {
        try marshalOneDef(st, def.*.subdefs()[@intCast(i)], flags + 1);
    }

    if (def.*.flags & constants.JANET_FUNCDEF_FLAG_HASSOURCEMAP != 0) {
        // Lines are written as deltas, columns absolute.
        var current: i32 = 0;
        i = 0;
        while (i < def.*.bytecode_length) : (i += 1) {
            const map = def.*.sourceMappings()[@intCast(i)];
            try pushInt(st, map.line -% current);
            try pushInt(st, map.column);
            current = map.line;
        }
    }

    if (def.*.flags & constants.JANET_FUNCDEF_FLAG_HASCLOBITSET != 0) {
        try marshalU32s(st, def.*.closureBits());
    }
}

fn marshalOneFiber(st: *MarshalState, fiber: *types.JanetFiber, flags: c_int) raise.Raising(void) {
    try stackCheck(flags);
    var fflags = fiber.*.flags;
    if (fiber.*.child != null) fflags |= fiber_flag_haschild;
    if (fiber.*.env != null) fflags |= fiber_flag_hasenv;
    if (fibers.status(fiber) == types.FiberStatus.alive)
        return raise.panic("cannot marshal alive fiber");
    try pushInt(st, fflags);
    try pushInt(st, fiber.*.frame);
    try pushInt(st, fiber.*.stackstart);
    try pushInt(st, fiber.*.stacktop);
    try pushInt(st, fiber.*.maxstack);

    // Frames, innermost first, each followed by its slots.
    var i = fiber.*.frame;
    var j = fiber.*.stackstart - frame_size;
    while (i > 0) {
        const frame = stackFrame(fiber.*.data.? + asSize(i));
        if (frame.env != null) frame.flags |= stackframe_hasenv;
        if (frame.func == null) {
            const as_cfun: types.JanetCFunction = @ptrFromInt(@intFromPtr(frame.pc));
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
            try marshalOne(st, fiber.*.data.?[@intCast(k)], flags + 1);
        }
        j = i - frame_size;
        i = frame.prevframe;
    }
    if (fiber.*.env) |env| {
        try marshalOne(st, wrap.fromTable(env), flags + 1);
    }
    if (fiber.*.child) |child| {
        try marshalOne(st, wrap.fromFiber(child), flags + 1);
    }
    try marshalOne(st, fiber.*.last_value, flags + 1);
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
            gcType(types.abstractHead(abstract)) == types.MemoryType.threaded_abstract)
        {
            _ = abstracts.incref(abstract);
            try pushByte(st, lb_threaded_abstract);
            try pushBytes(st, std.mem.asBytes(&abstract));
            markSeen(st, x);
            return;
        }
    }
    const at = abstract_type.ofAbstract(abstract);
    if (at.*.marshal) |marshal_fn| {
        try pushByte(st, lb_abstract);
        try marshalOne(st, value.fromBytes(at.*.name, .symbol), flags + 1);
        var context: types.JanetMarshalContext = .{
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
            try pushByte(st, lb_nil);
            return;
        },
        repr.Tag.boolean => {
            try pushByte(st, if (wrap.toBoolean(x)) lb_true else lb_false);
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
        if (args_core.checkint(check) != 0) {
            try pushByte(st, lb_reference);
            try pushInt(st, wrap.toInteger(check));
            return;
        }
    }
    if (st.rreg != null) {
        const check = tables.get(st.rreg.?, x);
        if (repr.checkType(check, repr.Tag.symbol)) {
            markSeen(st, x);
            const regname = wrap.toSymbol(check);
            try pushByte(st, lb_registry);
            try pushInt(st, types.stringHead(regname).length);
            try pushBytes(st, strings.bytesOf(regname));
            return;
        }
    }

    switch (vtype) {
        repr.Tag.number => {
            var bytes: [8]u8 = @bitCast(wrap.toNumber(x));
            if (big_endian) std.mem.reverse(u8, &bytes);
            try pushByte(st, lb_real);
            try pushBytes(st, &bytes);
            markSeen(st, x);
        },
        repr.Tag.string, repr.Tag.symbol, repr.Tag.keyword => {
            const str = wrap.toString(x);
            const length = types.stringHead(str).length;
            markSeen(st, x);
            try pushByte(st, switch (vtype) {
                repr.Tag.string => lb_string,
                repr.Tag.symbol => lb_symbol,
                else => lb_keyword,
            });
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
                    (buffer.*.gc.flags & constants.JANET_BUFFER_FLAG_NO_REALLOC) != 0)
                {
                    try pushByte(st, lb_pointer_buffer);
                    try pushInt(st, buffer.*.count);
                    try pushInt(st, buffer.*.capacity);
                    try pushPointer(st, buffer.*.data);
                    return;
                }
            }
            try pushByte(st, lb_buffer);
            try pushInt(st, buffer.*.count);
            try pushBytes(st, buffer.*.slice());
        },
        repr.Tag.array => {
            const a = wrap.toArray(x);
            markSeen(st, x);
            try pushByte(st, if (gcType(a) == types.MemoryType.array_weak) lb_array_weak else lb_array);
            try pushInt(st, a.*.count);
            var i: i32 = 0;
            while (i < a.*.count) : (i += 1) {
                try marshalOne(st, a.*.slice()[@intCast(i)], flags + 1);
            }
        },
        repr.Tag.tuple => {
            const tup = wrap.toTuple(x);
            const count = types.tupleHead(tup).length;
            const flag = types.tupleHead(tup).gc.flags >> 16;
            try pushByte(st, lb_tuple);
            try pushInt(st, count);
            try pushInt(st, flag);
            var i: i32 = 0;
            while (i < count) : (i += 1) {
                try marshalOne(st, tup[@intCast(i)], flags + 1);
            }
            // Marked as seen AFTER marshalling: a tuple is immutable and
            // cannot contain itself, so a self-reference would be a forward
            // reference the reader could not resolve.
            markSeen(st, x);
        },
        repr.Tag.table => {
            const t = wrap.toTable(x);
            markSeen(st, x);
            const has_proto = t.*.proto != null;
            try pushByte(st, switch (gcType(t)) {
                types.MemoryType.table_weakk => if (has_proto) lb_table_weakk_proto else lb_table_weakk,
                types.MemoryType.table_weakv => if (has_proto) lb_table_weakv_proto else lb_table_weakv,
                types.MemoryType.table_weakkv => if (has_proto) lb_table_weakkv_proto else lb_table_weakkv,
                else => if (has_proto) lb_table_proto else lb_table,
            });
            try pushInt(st, t.*.count);
            if (has_proto) try marshalOne(st, wrap.fromTable(t.*.proto.?), flags + 1);
            var i: i32 = 0;
            while (i < t.*.capacity) : (i += 1) {
                const kv = t.*.slots()[@intCast(i)];
                if (repr.checkType(kv.key, repr.Tag.nil)) continue;
                try marshalOne(st, kv.key, flags + 1);
                try marshalOne(st, kv.value, flags + 1);
            }
        },
        repr.Tag.@"struct" => {
            const struct_ = wrap.toStruct(x);
            const head = types.structHead(struct_);
            const count = head.length;
            try pushByte(st, if (head.proto != null) lb_struct_proto else lb_struct);
            try pushInt(st, count);
            if (head.proto != null) {
                try marshalOne(st, wrap.fromStruct(head.proto.?), flags + 1);
            }
            var i: i32 = 0;
            while (i < head.capacity) : (i += 1) {
                const kv = struct_[@intCast(i)];
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
            try pushByte(st, lb_function);
            const func = wrap.toFunction(x);
            try pushInt(st, func.*.def.?.environments_length);
            // Marked seen before the def is read, so that a function reachable
            // from its own closure resolves.
            markSeen(st, x);
            try marshalOneDef(st, func.*.def.?, flags);
            var i: i32 = 0;
            while (i < func.*.def.?.environments_length) : (i += 1) {
                try marshalOneEnv(st, funcEnv(func, i).*.?, flags + 1);
            }
        },
        repr.Tag.fiber => {
            markSeen(st, x);
            try pushByte(st, lb_fiber);
            try marshalOneFiber(st, wrap.toFiber(x), flags + 1);
        },
        repr.Tag.cfunction => {
            if ((flags & constants.JANET_MARSHAL_UNSAFE) == 0) return noRegistry(x);
            markSeen(st, x);
            try pushByte(st, lb_unsafe_cfunction);
            const cfn = wrap.toCfunction(x);
            try pushBytes(st, std.mem.asBytes(&cfn));
        },
        repr.Tag.pointer => {
            if ((flags & constants.JANET_MARSHAL_UNSAFE) == 0) return noRegistry(x);
            markSeen(st, x);
            try pushByte(st, lb_unsafe_pointer);
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
inline fn funcEnv(func: *types.JanetFunction, index: i32) *?*types.JanetFuncEnv {
    return &types.envsOf(func)[@intCast(index)];
}

const big_endian = (builtin.cpu.arch.endian() == .big);

pub fn marshal(
    buf: *types.JanetBuffer,
    x: repr.Value,
    rreg: ?*types.JanetTable,
    flags: c_int,
) raise.Raising(void) {
    var st: MarshalState = .{
        .buf = buf,
        .seen = undefined,
        .rreg = rreg,
        .seen_envs = null,
        .seen_defs = null,
        .nextid = 0,
        .maybe_cycles = (flags & constants.JANET_MARSHAL_NO_CYCLES) == 0,
    };
    _ = tables.init(&st.seen, 0);
    try marshalOne(&st, x, flags);
    tables.deinit(&st.seen);
    stretchy.free(*types.JanetFuncEnv, st.seen_envs);
    stretchy.free(*types.JanetFuncDef, st.seen_defs);
}

pub const marshalAbi = raise.panicking(marshal).abi;

// ------------------------------------------------- the marshal context API

inline fn marshalState(ctx: *types.JanetMarshalContext) *MarshalState {
    return @ptrCast(@alignCast(ctx.*.m_state));
}

/// `size_t` is not 64 bits everywhere -- `riscv32-linux` is one of this
/// project's cross-compile targets -- so the C original's `(int64_t) value`
/// widens before it reinterprets, and `(size_t)` on the way back truncates.
/// Zig's `@bitCast` refuses a width change, which is what makes the two steps
/// visible here and invisible there.
pub fn marshalSize(ctx: *types.JanetMarshalContext, val: usize) raise.Raising(void) {
    return marshalInt64(ctx, @bitCast(@as(u64, val)));
}

pub fn marshalSizeAbi(ctx: *types.JanetMarshalContext, val: usize) void {
    raise.reported(marshalSize(ctx, val));
}

pub fn marshalInt64(ctx: *types.JanetMarshalContext, val: i64) raise.Raising(void) {
    try push64(marshalState(ctx), @bitCast(val));
}

pub fn marshalInt64Abi(ctx: *types.JanetMarshalContext, val: i64) void {
    raise.reported(marshalInt64(ctx, val));
}

pub fn marshalInt(ctx: *types.JanetMarshalContext, val: i32) raise.Raising(void) {
    try pushInt(marshalState(ctx), val);
}

pub fn marshalIntAbi(ctx: *types.JanetMarshalContext, val: i32) void {
    raise.reported(marshalInt(ctx, val));
}

/// Only meaningful in unsafe mode; a pointer means nothing to another process.
pub fn marshalPtr(ctx: *types.JanetMarshalContext, ptr: ?*const anyopaque) raise.Raising(void) {
    if ((ctx.*.flags & constants.JANET_MARSHAL_UNSAFE) == 0) {
        return raise.panic("can only marshal pointers in unsafe mode");
    }
    try pushPointer(marshalState(ctx), ptr);
}

pub fn marshalByte(ctx: *types.JanetMarshalContext, val: u8) raise.Raising(void) {
    try pushByte(marshalState(ctx), val);
}

pub fn marshalByteAbi(ctx: *types.JanetMarshalContext, val: u8) void {
    raise.reported(marshalByte(ctx, val));
}

pub fn marshalBytes(ctx: *types.JanetMarshalContext, bytes: []const u8) raise.Raising(void) {
    const st = marshalState(ctx);
    if (bytes.len > std.math.maxInt(i32)) return raise.panic("size_t too large to fit in buffer");
    try pushBytes(st, bytes);
}

pub fn marshalJanet(ctx: *types.JanetMarshalContext, x: repr.Value) raise.Raising(void) {
    return marshalOne(marshalState(ctx), x, ctx.*.flags + 1);
}

pub fn marshalAbstract(ctx: *types.JanetMarshalContext, abstract: ?*anyopaque) void {
    markSeen(marshalState(ctx), wrap.fromAbstract(abstract));
}

pub fn marshalFlags(ctx: *types.JanetMarshalContext) c_int {
    return ctx.*.flags;
}

pub const marshalPtrAbi = raise.panicking(marshalPtr).abi;

/// `janet_marshal_bytes(ctx, bytes, len)`, whose C signature spreads one
/// slice into a pair. `raise.panicking` copies its parameter types into a
/// `callconv(.c)` abi, and a slice is not allowed in one, so this abi is
/// written out -- `raise.panickingArgv` is the same accommodation for the
/// `(argc, argv)` order.
pub fn marshalBytesAbi(
    ctx: *types.JanetMarshalContext,
    bytes: ?[*]const u8,
    len: usize,
) callconv(.c) void {
    return marshalBytes(ctx, if (bytes) |p| p[0..len] else &.{}) catch raise.reportToC(void);
}
pub const marshalJanetAbi = raise.panicking(marshalJanet).abi;

// ==========================================================================
// Unmarshalling
// ==========================================================================

/// The C original's first field is a `jmp_buf err` that nothing ever writes to
/// or jumps through: this subsystem reports failure by raising, and always
/// did. It is dropped rather than transcribed.
const UnmarshalState = struct {
    lookup: ?[*]repr.Value,
    reg: ?*types.JanetTable,
    lookup_envs: ?[*]*types.JanetFuncEnv,
    lookup_defs: ?[*]*types.JanetFuncDef,
    start: [*]const u8,
    end: [*]const u8,
};

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
    } else if (data[0] == lb_integer) {
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
fn readNat(st: *UnmarshalState, atdata: *[*]const u8) raise.Raising(i32) {
    const ret = try readInt(st, atdata);
    if (ret < 0) return pp_format.panicf("expected integer >= 0, got %d", .{ret});
    return ret;
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
    try eos(st, data + asSize(nbytes));
    var ret: u64 = 0;
    var i = nbytes;
    while (i > 0) : (i -= 1) {
        ret = (ret << 8) + data[@intCast(i)];
    }
    atdata.* = data + asSize(nbytes) + 1;
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
    out: *?*types.JanetFuncEnv,
    flags: c_int,
) raise.Raising([*]const u8) {
    var data = data_in;
    try eos(st, data);
    if (data[0] == lb_funcenv_ref) {
        data += 1;
        const index = try readInt(st, &data);
        if (index < 0 or index >= stretchy.count(*types.JanetFuncEnv, st.lookup_envs))
            return pp_format.panicf("invalid funcenv reference %d", .{index});
        out.* = st.lookup_envs.?[@intCast(index)];
        return data;
    }

    const env: *types.JanetFuncEnv = @ptrCast(@alignCast(gc_alloc.gcalloc(
        types.MemoryType.funcenv,
        @sizeOf(types.JanetFuncEnv),
    )));
    env.*.length = 0;
    env.*.offset = 0;
    env.*.as.values = null;
    stretchy.push(*types.JanetFuncEnv, &st.lookup_envs, env);
    const offset = try readNat(st, &data);
    const length = try readNat(st, &data);
    if (offset > 0) {
        // On stack variant
        var fiberv: repr.Value = undefined;
        data = try unmarshalOne(st, data, &fiberv, flags);
        try assertType(fiberv, repr.Tag.fiber);
        env.*.as.fiber = wrap.toFiber(fiberv);
        // A negative offset marks the environment as coming from untrusted
        // input, which is what stops the runtime treating it as live stack.
        env.*.offset = -offset;
    } else {
        // Off stack variant
        if (length == 0) return raise.panic("invalid funcenv length");
        env.*.as.values = @ptrCast(@alignCast(allocated(
            utils.malloc(@sizeOf(repr.Value) * asSize(length)),
        )));
        env.*.offset = 0;
        var i: i32 = 0;
        while (i < length) : (i += 1) {
            data = try unmarshalOne(st, data, &env.*.as.values.?[@intCast(i)], flags);
        }
    }
    env.*.length = length;
    out.* = env;
    return data;
}

fn unmarshalU32s(
    st: *UnmarshalState,
    data_in: [*]const u8,
    into: [*]u32,
    n: i32,
) raise.Raising([*]const u8) {
    var data = data_in;
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        try eos(st, data + 3);
        into[@intCast(i)] = @as(u32, data[0]) |
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
    out: **types.JanetFuncDef,
    flags: c_int,
) raise.Raising([*]const u8) {
    var data = data_in;
    try eos(st, data);
    if (data[0] == lb_funcdef_ref) {
        data += 1;
        const index = try readInt(st, &data);
        if (index < 0 or index >= stretchy.count(*types.JanetFuncDef, st.lookup_defs))
            return pp_format.panicf("invalid funcdef reference %d", .{index});
        out.* = st.lookup_defs.?[@intCast(index)];
        return data;
    }

    // Initialised with values that will not break garbage collection if
    // unmarshalling fails partway.
    const def: *types.JanetFuncDef = @ptrCast(@alignCast(gc_alloc.gcalloc(
        types.MemoryType.funcdef,
        @sizeOf(types.JanetFuncDef),
    )));
    def.*.environments_length = 0;
    def.*.defs_length = 0;
    def.*.constants_length = 0;
    def.*.bytecode_length = 0;
    def.*.name = null;
    def.*.source = null;
    def.*.closure_bitset = null;
    def.*.defs = null;
    def.*.environments = null;
    def.*.constants = null;
    def.*.bytecode = null;
    def.*.sourcemap = null;
    def.*.symbolmap = null;
    def.*.symbolmap_length = 0;
    def.*.named_args_count = 0;
    stretchy.push(*types.JanetFuncDef, &st.lookup_defs, def);

    var environments_length: i32 = 0;
    var defs_length: i32 = 0;
    var symbolmap_length: i32 = 0;

    def.*.flags = try readInt(st, &data);
    def.*.slotcount = try readNat(st, &data);
    def.*.arity = try readNat(st, &data);
    def.*.min_arity = try readNat(st, &data);
    def.*.max_arity = try readNat(st, &data);

    const constants_length = try readNat(st, &data);
    const bytecode_length = try readNat(st, &data);
    if (def.*.flags & constants.JANET_FUNCDEF_FLAG_NAMEDARGS != 0)
        def.*.named_args_count = try readNat(st, &data);
    if (def.*.flags & constants.JANET_FUNCDEF_FLAG_HASENVS != 0)
        environments_length = try readNat(st, &data);
    if (def.*.flags & constants.JANET_FUNCDEF_FLAG_HASDEFS != 0)
        defs_length = try readNat(st, &data);
    if (def.*.flags & constants.JANET_FUNCDEF_FLAG_HASSYMBOLMAP != 0)
        symbolmap_length = try readNat(st, &data);

    if (def.*.flags & constants.JANET_FUNCDEF_FLAG_HASNAME != 0) {
        var x: repr.Value = undefined;
        data = try unmarshalOne(st, data, &x, flags + 1);
        try assertType(x, repr.Tag.string);
        def.*.name = wrap.toString(x);
    }
    if (def.*.flags & constants.JANET_FUNCDEF_FLAG_HASSOURCE != 0) {
        var x: repr.Value = undefined;
        data = try unmarshalOne(st, data, &x, flags + 1);
        try assertType(x, repr.Tag.string);
        def.*.source = wrap.toString(x);
    }

    if (constants_length != 0) {
        const pool: [*]repr.Value = @ptrCast(@alignCast(allocated(
            utils.malloc(@sizeOf(repr.Value) * asSize(constants_length)),
        )));
        def.*.constants = pool;
        // The length is declared after the fill, so `constantValues()` is
        // empty throughout this loop and the writer works over what it just
        // allocated. That order is not incidental: the def is collectable
        // and `unmarshalOne` allocates, so a length set early would have the
        // mark walk read uninitialised memory.
        const values = pool[0..asSize(constants_length)];
        for (values) |*slot| {
            data = try unmarshalOne(st, data, slot, flags + 1);
        }
    } else {
        def.*.constants = null;
    }
    def.*.constants_length = constants_length;

    if (def.*.flags & constants.JANET_FUNCDEF_FLAG_HASSYMBOLMAP != 0) {
        const map: [*]types.JanetSymbolMap = @ptrCast(@alignCast(allocated(
            utils.malloc(@sizeOf(types.JanetSymbolMap) * asSize(symbolmap_length)),
        )));
        def.*.symbolmap = map;
        for (map[0..asSize(symbolmap_length)]) |*entry| {
            entry.birth_pc = @bitCast(try readInt(st, &data));
            entry.death_pc = @bitCast(try readInt(st, &data));
            entry.slot_index = @bitCast(try readInt(st, &data));
            var val: repr.Value = undefined;
            data = try unmarshalOne(st, data, &val, flags + 1);
            if (!repr.checkType(val, repr.Tag.symbol)) {
                return pp_format.panicf(
                    "corrupted symbolmap when unmarshalling debug info, got %v",
                    .{val},
                );
            }
            entry.symbol = wrap.toSymbol(val);
        }
        def.*.symbolmap_length = symbolmap_length;
    }

    def.*.bytecode = @ptrCast(@alignCast(allocated(
        utils.malloc(@sizeOf(u32) * asSize(bytecode_length)),
    )));
    data = try unmarshalU32s(st, data, def.*.bytecode.?, bytecode_length);
    def.*.bytecode_length = bytecode_length;

    if (def.*.flags & constants.JANET_FUNCDEF_FLAG_HASENVS != 0) {
        const envs: [*]i32 = @ptrCast(@alignCast(allocated(
            utils.calloc(1, @sizeOf(i32) * asSize(environments_length)),
        )));
        def.*.environments = envs;
        for (envs[0..asSize(environments_length)]) |*slot| {
            slot.* = try readInt(st, &data);
        }
    } else {
        def.*.environments = null;
    }
    def.*.environments_length = environments_length;

    if (def.*.flags & constants.JANET_FUNCDEF_FLAG_HASDEFS != 0) {
        const nested: [*]*types.JanetFuncDef = @ptrCast(@alignCast(allocated(
            utils.calloc(1, @sizeOf(*types.JanetFuncDef) * asSize(defs_length)),
        )));
        def.*.defs = nested;
        for (nested[0..asSize(defs_length)]) |*slot| {
            data = try unmarshalOneDef(st, data, slot, flags + 1);
        }
    } else {
        def.*.defs = null;
    }
    def.*.defs_length = defs_length;

    if (def.*.flags & constants.JANET_FUNCDEF_FLAG_HASSOURCEMAP != 0) {
        def.*.sourcemap = @ptrCast(@alignCast(allocated(
            utils.malloc(@sizeOf(types.JanetSourceMapping) * asSize(bytecode_length)),
        )));
        var current: i32 = 0;
        var i: i32 = 0;
        while (i < bytecode_length) : (i += 1) {
            current +%= try readInt(st, &data);
            def.*.sourceMappings()[@intCast(i)].line = current;
            def.*.sourceMappings()[@intCast(i)].column = try readInt(st, &data);
        }
    } else {
        def.*.sourcemap = null;
    }

    if (def.*.flags & constants.JANET_FUNCDEF_FLAG_HASCLOBITSET != 0) {
        const n = (def.*.slotcount + 31) >> 5;
        def.*.closure_bitset = @ptrCast(@alignCast(allocated(
            utils.malloc(@sizeOf(u32) * asSize(n)),
        )));
        data = try unmarshalU32s(st, data, def.*.closure_bitset.?, n);
    }

    if (verify.verify(def) != 0) return raise.panic("funcdef has invalid bytecode");

    out.* = def;
    return data;
}

fn unmarshalOneFiber(
    st: *UnmarshalState,
    data_in: [*]const u8,
    out: *?*types.JanetFiber,
    flags: c_int,
) raise.Raising([*]const u8) {
    var data = data_in;

    // A new fiber with collector-friendly defaults: it enters the reference
    // table before any of its fields are read, so a failure partway leaves
    // something the collector can walk.
    const fiber: *types.JanetFiber = @ptrCast(@alignCast(gc_alloc.gcalloc(
        types.MemoryType.fiber,
        @sizeOf(types.JanetFiber),
    )));
    fiber.*.flags = 0;
    fiber.*.frame = 0;
    fiber.*.stackstart = 0;
    fiber.*.stacktop = 0;
    fiber.*.capacity = 0;
    fiber.*.maxstack = 0;
    fiber.*.data = null;
    fiber.*.child = null;
    fiber.*.env = null;
    fiber.*.last_value = wrap.fromNil();
    if (has_ev) {
        fiber.*.sched_id = 0;
        fiber.*.supervisor_channel = null;
        fiber.*.ev_state = null;
        fiber.*.ev_callback = null;
        fiber.*.ev_stream = null;
    }

    stretchy.push(repr.Value, &st.lookup, wrap.fromFiber(fiber));

    var fiber_flags = try readInt(st, &data);
    const frame = try readNat(st, &data);
    const fiber_stackstart = try readNat(st, &data);
    const fiber_stacktop = try readNat(st, &data);
    const fiber_maxstack = try readNat(st, &data);
    var fiber_env: ?*types.JanetTable = null;

    if (frame +% frame_size > fiber_stackstart or
        fiber_stackstart > fiber_stacktop or
        fiber_stacktop > fiber_maxstack)
    {
        return raise.panic("fiber has incorrect stack setup");
    }

    // Extra capacity avoids an immediate realloc when arguments are pushed; it
    // is a convenience rather than a requirement, which is what the saturating
    // branch relies on.
    fiber.*.capacity = if (fiber_stacktop < std.math.maxInt(i32) - 10)
        fiber_stacktop + 10
    else
        std.math.maxInt(i32);
    fiber.*.data = @ptrCast(@alignCast(allocated(
        utils.malloc(@sizeOf(repr.Value) * asSize(fiber.*.capacity)),
    )));
    var i: i32 = 0;
    while (i < fiber.*.capacity) : (i += 1) {
        fiber.*.data.?[@intCast(i)] = wrap.fromNil();
    }

    var stack = frame;
    var stacktop = fiber_stackstart - frame_size;
    while (stack > 0) {
        var env: ?*types.JanetFuncEnv = null;
        var frameflags = try readInt(st, &data);
        const prevframe = try readNat(st, &data);
        const pcdiff = try readNat(st, &data);

        const framestack = fiber.*.data.? + asSize(stack);
        const framep = stackFrame(framestack);

        var funcv: repr.Value = undefined;
        data = try unmarshalOne(st, data, &funcv, flags + 1);
        try assertType(funcv, repr.Tag.function);
        const func = wrap.toFunction(funcv);
        const def = func.*.def.?;

        if (frameflags & stackframe_hasenv != 0) {
            frameflags &= ~stackframe_hasenv;
            data = try unmarshalOneEnv(st, data, &env, flags + 1);
        }

        if (def.*.slotcount != stacktop - stack) {
            return raise.panic("fiber stackframe size mismatch");
        }
        if (pcdiff >= def.*.bytecode_length) {
            return raise.panic("fiber stackframe has invalid pc");
        }
        if (prevframe +% frame_size > stack) {
            return raise.panic("fiber stackframe does not align with previous frame");
        }

        i = stack;
        while (i < stacktop) : (i += 1) {
            data = try unmarshalOne(st, data, &fiber.*.data.?[@intCast(i)], flags + 1);
        }

        framep.env = env;
        framep.pc = def.*.bytecode.? + asSize(pcdiff);
        framep.prevframe = prevframe;
        framep.flags = frameflags;
        framep.func = func;

        stacktop = stack - frame_size;
        stack = prevframe;
    }
    if (stack < 0) return raise.panic("fiber has too many stackframes");

    if (fiber_flags & fiber_flag_hasenv != 0) {
        var envv: repr.Value = undefined;
        fiber_flags &= ~fiber_flag_hasenv;
        data = try unmarshalOne(st, data, &envv, flags + 1);
        try assertType(envv, repr.Tag.table);
        fiber_env = wrap.toTable(envv);
    }

    if (fiber_flags & fiber_flag_haschild != 0) {
        var fiberv: repr.Value = undefined;
        fiber_flags &= ~fiber_flag_haschild;
        data = try unmarshalOne(st, data, &fiberv, flags + 1);
        try assertType(fiberv, repr.Tag.fiber);
        fiber.*.child = wrap.toFiber(fiberv);
    }

    data = try unmarshalOne(st, data, &fiber.*.last_value, flags + 1);

    // Only now is the fiber valid, so only now are the fields the runtime
    // reads filled in.
    fiber.*.frame = frame;
    fiber.*.flags = fiber_flags;
    fiber.*.stackstart = fiber_stackstart;
    fiber.*.stacktop = fiber_stacktop;
    fiber.*.maxstack = fiber_maxstack;
    fiber.*.env = fiber_env;

    // The one status that arrives from outside this tree. `statusOf` reads
    // six bits and the vocabulary is sixteen values, so the bit pattern an
    // image carries may name none of them -- which is why this is a validation
    // of the *stored* number rather than of the enum.
    const stored = (fiber.*.flags & constants.JANET_FIBER_STATUS_MASK) >> constants.JANET_FIBER_STATUS_OFFSET;
    if (stored < 0 or stored > @intFromEnum(types.FiberStatus.alive)) {
        return raise.panic("invalid fiber status");
    }

    out.* = fiber;
    return data;
}

// ----------------------------------------------- the unmarshal context API

inline fn unmarshalState(ctx: *types.JanetMarshalContext) *UnmarshalState {
    return @ptrCast(@alignCast(ctx.*.u_state));
}

pub fn unmarshalEnsure(ctx: *types.JanetMarshalContext, size: usize) raise.Raising(void) {
    return eosAddr(unmarshalState(ctx), @intFromPtr(ctx.*.data) +% size);
}

pub fn unmarshalInt(ctx: *types.JanetMarshalContext) raise.Raising(i32) {
    var cursor = ctx.*.data.?;
    defer ctx.*.data = cursor;
    return readInt(unmarshalState(ctx), &cursor);
}

pub fn unmarshalSize(ctx: *types.JanetMarshalContext) raise.Raising(usize) {
    return @truncate(@as(u64, @bitCast(try unmarshalInt64(ctx))));
}

pub fn unmarshalInt64(ctx: *types.JanetMarshalContext) raise.Raising(i64) {
    var cursor = ctx.*.data.?;
    defer ctx.*.data = cursor;
    return @bitCast(try read64(unmarshalState(ctx), &cursor));
}

pub fn unmarshalPtr(ctx: *types.JanetMarshalContext) raise.Raising(?*anyopaque) {
    if ((ctx.*.flags & constants.JANET_MARSHAL_UNSAFE) == 0) {
        return raise.panic("can only unmarshal pointers in unsafe mode");
    }
    const st = unmarshalState(ctx);
    try eosAddr(st, @intFromPtr(ctx.*.data) +% @sizeOf(?*anyopaque) -% 1);
    var ptr: ?*anyopaque = undefined;
    @memcpy(@as([*]u8, @ptrCast(&ptr))[0..@sizeOf(?*anyopaque)], ctx.*.data.?[0..@sizeOf(?*anyopaque)]);
    ctx.*.data.? += @sizeOf(?*anyopaque);
    return ptr;
}

pub fn unmarshalByte(ctx: *types.JanetMarshalContext) raise.Raising(u8) {
    const st = unmarshalState(ctx);
    try eos(st, ctx.*.data.?);
    const val = ctx.*.data.?[0];
    ctx.*.data.? += 1;
    return val;
}

pub fn unmarshalBytes(ctx: *types.JanetMarshalContext, dest: [*]u8, len: usize) raise.Raising(void) {
    const st = unmarshalState(ctx);
    try eosAddr(st, @intFromPtr(ctx.*.data) +% len -% 1);
    safe_memcpy(dest, ctx.*.data.?, len);
    ctx.*.data.? += len;
}

pub fn unmarshalJanet(ctx: *types.JanetMarshalContext) raise.Raising(repr.Value) {
    var ret: repr.Value = undefined;
    ctx.*.data = try unmarshalOne(unmarshalState(ctx), ctx.*.data.?, &ret, ctx.*.flags);
    return ret;
}

/// Enter an already-allocated abstract into the reference table, and mark the
/// context as having done so. `at` is the flag: `unmarshalOneAbstract` checks
/// that it was cleared, which is how a callback that forgets is caught.
pub fn unmarshalAbstractReuse(ctx: *types.JanetMarshalContext, p: ?*anyopaque) raise.Raising(void) {
    if (ctx.*.at == null) {
        return raise.panic("janet_unmarshal_abstract called more than once");
    }
    stretchy.push(repr.Value, &unmarshalState(ctx).lookup, wrap.fromAbstract(p));
    ctx.*.at = null;
}

pub fn unmarshalAbstract(ctx: *types.JanetMarshalContext, size: usize) raise.Raising(?*anyopaque) {
    const p = abstracts.new(ctx.*.at.?, size);
    try unmarshalAbstractReuse(ctx, p);
    return p;
}

/// Always raises. `JANET_THREADS` is defined by nothing in this tree, so the
/// C original's other arm has never been compiled -- see `FOUND.md`.
pub fn unmarshalAbstractThreaded(ctx: *types.JanetMarshalContext, size: usize) raise.Raising(?*anyopaque) {
    _ = ctx;
    _ = size;
    return raise.panic("threaded abstracts not supported");
}

pub fn unmarshalFlags(ctx: *types.JanetMarshalContext) c_int {
    return ctx.*.flags;
}

pub const unmarshalEnsureAbi = raise.panicking(unmarshalEnsure).abi;
pub const unmarshalIntAbi = raise.panicking(unmarshalInt).abi;
pub const unmarshalSizeAbi = raise.panicking(unmarshalSize).abi;
pub const unmarshalInt64Abi = raise.panicking(unmarshalInt64).abi;
pub const unmarshalPtrAbi = raise.panicking(unmarshalPtr).abi;
pub const unmarshalByteAbi = raise.panicking(unmarshalByte).abi;
pub const unmarshalBytesAbi = raise.panicking(unmarshalBytes).abi;
pub const unmarshalJanetAbi = raise.panicking(unmarshalJanet).abi;
pub const unmarshalAbstractReuseAbi = raise.panicking(unmarshalAbstractReuse).abi;
pub const unmarshalAbstractAbi = raise.panicking(unmarshalAbstract).abi;
pub const unmarshalAbstractThreadedAbi = raise.panicking(unmarshalAbstractThreaded).abi;

fn unmarshalOneAbstract(
    st: *UnmarshalState,
    data_in: [*]const u8,
    out: *repr.Value,
    flags: c_int,
) raise.Raising([*]const u8) {
    var key: repr.Value = undefined;
    const data = try unmarshalOne(st, data_in, &key, flags + 1);
    const stored_at = registry.getAbstractType(key);
    if (stored_at == null) return raise.panic("unknown abstract type");
    const at = stored_at.?;
    if (at.unmarshal) |unmarshal_fn| {
        var context: types.JanetMarshalContext = .{
            .m_state = null,
            .u_state = st,
            .flags = flags,
            .data = data,
            .at = stored_at,
        };
        const abst = try unmarshal_fn(&context);
        marshAssert(abst != null, "null pointer abstract");
        out.* = wrap.fromAbstract(abst);
        if (context.at != null) return raise.panic("janet_unmarshal_abstract not called");
        return context.data.?;
    }
    return raise.panic("invalid abstract type - no unmarshal function pointer");
}

/// The main body of the unmarshaller.
fn unmarshalOne(
    st: *UnmarshalState,
    data_in: [*]const u8,
    out: *repr.Value,
    flags: c_int,
) raise.Raising([*]const u8) {
    var data: [*]const u8 = data_in;
    try stackCheck(flags);
    try eos(st, data);
    const lead = data[0];
    if (lead < lb_real) {
        out.* = wrapInteger(try readInt(st, &data));
        return data;
    }

    // The two event-loop lead bytes are tested before the switch rather than
    // inside it: without `JANET_EV` their numbers belong to the weak
    // containers, which is the renumbering `weak_base` documents.
    if (has_ev) {
        switch (lead) {
            lb_pointer_buffer => {
                data += 1;
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
                out.* = wrap.fromBuffer(buffer);
                stretchy.push(repr.Value, &st.lookup, out.*);
                return data;
            },
            lb_threaded_abstract => {
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
                    out.* = wrap.fromNil();
                } else {
                    out.* = wrap.fromAbstract(ptr);
                    const check = tables.get(&vm_lifecycle.current().ev.threaded_abstracts, out.*);
                    if (repr.checkType(check, repr.Tag.nil)) {
                        // Transfers the reference from the channel's buffer to
                        // this heap.
                        tables.put(&vm_lifecycle.current().ev.threaded_abstracts, out.*, wrap.fromFalse());
                    } else {
                        // The heap reference is already accounted for, so the
                        // channel's is released.
                        _ = abstracts.decref(ptr);
                    }
                }
                stretchy.push(repr.Value, &st.lookup, out.*);
                return data;
            },
            else => {},
        }
    }

    switch (lead) {
        lb_nil => {
            out.* = wrap.fromNil();
            return data + 1;
        },
        lb_false => {
            out.* = wrap.fromFalse();
            return data + 1;
        },
        lb_true => {
            out.* = wrap.fromTrue();
            return data + 1;
        },
        lb_integer => {
            try eos(st, data + 4);
            const ui: u32 = @as(u32, data[4]) |
                (@as(u32, data[3]) << 8) |
                (@as(u32, data[2]) << 16) |
                (@as(u32, data[1]) << 24);
            out.* = wrapInteger(@bitCast(ui));
            return data + 5;
        },
        lb_real => {
            try eos(st, data + 8);
            var bytes: [8]u8 = undefined;
            @memcpy(&bytes, data[1..9]);
            if (big_endian) std.mem.reverse(u8, &bytes);
            out.* = wrap.fromNumberSafe(@bitCast(bytes));
            stretchy.push(repr.Value, &st.lookup, out.*);
            return data + 9;
        },
        lb_string, lb_symbol, lb_buffer, lb_keyword, lb_registry => {
            data += 1;
            const len = try readNat(st, &data);
            try eosAddr(st, @intFromPtr(data) -% 1 +% asSize(len));
            switch (lead) {
                lb_string => out.* = wrap.fromString(strings.new(data[0..@intCast(len)])),
                lb_symbol => out.* = wrap.fromSymbol(symbols.new(data[0..@intCast(len)])),
                lb_keyword => out.* = value.fromBytes(data[0..@intCast(len)], .keyword),
                lb_registry => {
                    if (st.reg != null) {
                        out.* = tables.get(st.reg.?, value.fromBytes(data[0..@intCast(len)], .symbol));
                    } else {
                        out.* = wrap.fromNil();
                    }
                },
                else => {
                    const buffer = buffers.new(len);
                    buffer.*.count = len;
                    safe_memcpy(buffer.*.data, data, asSize(len));
                    out.* = wrap.fromBuffer(buffer);
                },
            }
            stretchy.push(repr.Value, &st.lookup, out.*);
            return data + asSize(len);
        },
        lb_fiber => {
            var fiber: ?*types.JanetFiber = undefined;
            data = try unmarshalOneFiber(st, data + 1, &fiber, flags + 1);
            out.* = wrap.fromFiber(fiber.?);
            return data;
        },
        lb_function => {
            data += 1;
            const len = try readNat(st, &data);
            if (len > 255) {
                return pp_format.panicf("invalid function - too many environments (%d)", .{len});
            }
            const func: *types.JanetFunction = @ptrCast(@alignCast(gc_alloc.gcalloc(
                types.MemoryType.function,
                types.function_envs + asSize(len) * @sizeOf(*types.JanetFuncEnv),
            )));
            func.*.def = null;
            var i: i32 = 0;
            while (i < len) : (i += 1) funcEnv(func, i).* = null;
            out.* = wrap.fromFunction(func);
            stretchy.push(repr.Value, &st.lookup, out.*);
            var def: *types.JanetFuncDef = undefined;
            data = try unmarshalOneDef(st, data, &def, flags + 1);
            func.*.def = def;
            i = 0;
            while (i < len) : (i += 1) {
                data = try unmarshalOneEnv(st, data, funcEnv(func, i), flags + 1);
            }
            return data;
        },
        lb_abstract => {
            return unmarshalOneAbstract(st, data + 1, out, flags);
        },
        lb_reference,
        lb_array,
        lb_array_weak,
        lb_tuple,
        lb_struct,
        lb_struct_proto,
        lb_table,
        lb_table_proto,
        lb_table_weakk,
        lb_table_weakv,
        lb_table_weakkv,
        lb_table_weakk_proto,
        lb_table_weakv_proto,
        lb_table_weakkv_proto,
        => {
            // Everything that opens with a count.
            data += 1;
            const len = try readNat(st, &data);
            // A denial-of-service check: a count far larger than the input
            // cannot be honest, and allocating for it first would be the
            // damage.
            if (lead != lb_reference) {
                try eosAddr(st, @intFromPtr(data) -% 1 +% asSize(len));
            }
            if (lead == lb_array or lead == lb_array_weak) {
                const array = if (lead == lb_array_weak)
                    arrays.weak(len)
                else
                    arrays.new(len);
                array.*.count = len;
                out.* = wrap.fromArray(array);
                stretchy.push(repr.Value, &st.lookup, out.*);
                var i: i32 = 0;
                while (i < len) : (i += 1) {
                    data = try unmarshalOne(st, data, &array.*.slice()[@intCast(i)], flags + 1);
                }
            } else if (lead == lb_tuple) {
                const tup = tuples.begin(len);
                const flag = try readInt(st, &data);
                // The cast avoids a left shift of a negative value.
                types.tupleHead(tup).gc.flags |= @bitCast(@as(u32, @bitCast(flag)) << 16);
                var i: i32 = 0;
                while (i < len) : (i += 1) {
                    data = try unmarshalOne(st, data, &tup[@intCast(i)], flags + 1);
                }
                out.* = wrap.fromTuple(tuples.end(tup));
                stretchy.push(repr.Value, &st.lookup, out.*);
            } else if (lead == lb_struct or lead == lb_struct_proto) {
                const struct_ = structs.begin(len);
                if (lead == lb_struct_proto) {
                    var proto: repr.Value = undefined;
                    data = try unmarshalOne(st, data, &proto, flags + 1);
                    try assertType(proto, repr.Tag.@"struct");
                    types.structHead(struct_).proto = wrap.toStruct(proto);
                }
                var i: i32 = 0;
                while (i < len) : (i += 1) {
                    var key: repr.Value = undefined;
                    var val: repr.Value = undefined;
                    data = try unmarshalOne(st, data, &key, flags + 1);
                    data = try unmarshalOne(st, data, &val, flags + 1);
                    structs.put(struct_, key, val);
                }
                out.* = wrap.fromStruct(structs.end(struct_));
                stretchy.push(repr.Value, &st.lookup, out.*);
            } else if (lead == lb_reference) {
                if (len >= stretchy.count(repr.Value, st.lookup)) {
                    return pp_format.panicf("invalid reference %d", .{len});
                }
                out.* = st.lookup.?[@intCast(len)];
            } else {
                const t = switch (lead) {
                    lb_table_weakk_proto, lb_table_weakk => tables.weakk(len),
                    lb_table_weakv_proto, lb_table_weakv => tables.weakv(len),
                    lb_table_weakkv_proto, lb_table_weakkv => tables.weakkv(len),
                    else => tables.new(len),
                };
                out.* = wrap.fromTable(t);
                stretchy.push(repr.Value, &st.lookup, out.*);
                switch (lead) {
                    lb_table_proto,
                    lb_table_weakk_proto,
                    lb_table_weakv_proto,
                    lb_table_weakkv_proto,
                    => {
                        var proto: repr.Value = undefined;
                        data = try unmarshalOne(st, data, &proto, flags + 1);
                        try assertType(proto, repr.Tag.table);
                        t.*.proto = wrap.toTable(proto);
                    },
                    else => {},
                }
                var i: i32 = 0;
                while (i < len) : (i += 1) {
                    var key: repr.Value = undefined;
                    var val: repr.Value = undefined;
                    data = try unmarshalOne(st, data, &key, flags + 1);
                    data = try unmarshalOne(st, data, &val, flags + 1);
                    tables.put(t, key, val);
                }
            }
            return data;
        },
        lb_unsafe_pointer => {
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
            out.* = wrap.fromPointer(ptr);
            stretchy.push(repr.Value, &st.lookup, out.*);
            return data;
        },
        lb_unsafe_cfunction => {
            try eos(st, data + @sizeOf(types.JanetCFunction));
            data += 1;
            if ((flags & constants.JANET_MARSHAL_UNSAFE) == 0) {
                return pp_format.panicf(
                    "unsafe flag not given, will not unmarshal function pointer at index %d",
                    .{indexOf(st, data)},
                );
            }
            var cfn: types.JanetCFunction = undefined;
            @memcpy(
                @as([*]u8, @ptrCast(&cfn))[0..@sizeOf(types.JanetCFunction)],
                data[0..@sizeOf(types.JanetCFunction)],
            );
            data += @sizeOf(types.JanetCFunction);
            out.* = wrap.fromCfunction(cfn);
            stretchy.push(repr.Value, &st.lookup, out.*);
            return data;
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
    reg: ?*types.JanetTable,
    next: ?*[*]const u8,
) raise.Raising(repr.Value) {
    var st: UnmarshalState = .{
        .start = bytes.ptr,
        .end = bytes.ptr + bytes.len,
        .lookup_defs = null,
        .lookup_envs = null,
        .lookup = null,
        .reg = reg,
    };
    var out: repr.Value = undefined;
    const nextbytes = try unmarshalOne(&st, bytes.ptr, &out, flags);
    if (next) |slot| slot.* = nextbytes;
    stretchy.free(*types.JanetFuncDef, st.lookup_defs);
    stretchy.free(*types.JanetFuncEnv, st.lookup_envs);
    stretchy.free(repr.Value, st.lookup);
    return out;
}

/// `janet_unmarshal(bytes, len, flags, reg, next)`. Written out for the same
/// reason as `marshalBytesAbi` above.
pub fn unmarshalAbi(
    bytes: ?[*]const u8,
    len: usize,
    flags: c_int,
    reg: ?*types.JanetTable,
    next: ?*[*]const u8,
) callconv(.c) repr.Value {
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
    var rreg: ?*types.JanetTable = null;
    var flags: c_int = 0;
    if (@as(i32, @intCast(argv.len)) > 1) rreg = try args_core.getTable(argv, 1);
    const buffer = if (@as(i32, @intCast(argv.len)) > 2) try args_core.getBuffer(argv, 2) else buffers.new(10);
    if (@as(i32, @intCast(argv.len)) > 3 and repr.truthy(argv[3])) flags |= constants.JANET_MARSHAL_NO_CYCLES;
    try marshal(buffer, argv[0], rreg, flags);
    return wrap.fromBuffer(buffer);
}

fn cfunUnmarshal(argv: []repr.Value) align(corefn.alignment) raise.Raising(repr.Value) {
    try vm_lifecycle.sandboxAssert(types.Sandbox.of(&.{"unmarshal"}));
    try args_core.arity(argv, 1, 2);
    const view = try args_core.getBytes(argv, 0);
    const reg: ?*types.JanetTable = if (@as(i32, @intCast(argv.len)) > 1) try args_core.getTable(argv, 1) else null;
    return unmarshal(args_core.viewBytes(view), 0, reg, null);
}

pub fn libMarsh(env: *types.JanetTable) void {
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
