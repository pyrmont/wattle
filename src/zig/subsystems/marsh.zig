//! The marshalling protocol: `src/core/marsh.c` entire, both directions and
//! the three cfunctions over them. This is Phase 10 Part 8.
//!
//! One selector for one file, because the file is one subsystem. `marsh.c`
//! was already self-contained — nothing else in the tree reaches inside it,
//! and it reaches out only through public API and four internal headers — so
//! Part 4's consolidation rule decides the shape without argument: the two
//! directions convert in the same increment, so splitting them would buy three
//! C bridge functions and eight build combinations and nothing else.
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
//! C original's missing cleanup on a panic path harmless, and it is why this
//! file does not try to improve on it — see "Nothing is freed on the way out"
//! in `src/zig/README.md`.
//!
//! ## Why this file is jump-transparent, and will be for a while
//!
//! Every raise this file *decides* returns an error, which is Phase 10's
//! decision 1 applied as decision 3 requires. But three kinds of call inside
//! the traversal still jump past these frames whatever this file does:
//!
//!  - `janet_buffer_push_u8` and its kin, which raise on a buffer that cannot
//!    grow, and are reached from every `push*` below;
//!  - `janet_table_put`, `janet_string`, `janet_abstract` and the other
//!    allocators on the unmarshal side;
//!  - an abstract type's `marshal` and `unmarshal` callbacks, which are C
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
//! face over an error-returning body, and the jump it delivers unwinds the Zig
//! traversal frames underneath it exactly as it did when they were C.

const std = @import("std");
const abi = @import("abi");
const corefn = @import("corefn");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");
const c = abi.c;
const lifecycle = @import("lifecycle.zig");
const containers = @import("containers.zig");
const arglayer = @import("arglayer.zig");
const abstract_type = @import("abstract_type.zig");

/// `src/core/util.h`, which `abi.zig` deliberately does not translate.
extern fn safe_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void;

/// Whether this build has the event loop. `state_abi.h` restates `JANET_EV` as
/// a valued macro, because translate-c does not surface one defined without a
/// value.
const has_ev = c.JANET_VM_HAS_EV != 0;

/// `JANET_MARSHAL_DECREF` from `src/core/util.h`. A plain integer, so
/// declaring it here rather than translating the header costs nothing and
/// keeps the Windows cross-compile intact.
///
/// It has the same value as `janet.h`'s `JANET_MARSHAL_NO_CYCLES`, and that
/// aliasing is preserved rather than tidied -- see `src/zig/README.md`.
const marshal_decref: c_int = 0x40000;

/// `janet.h`'s frame size. The function-like macros over it do not survive
/// translation and are written out below.
const frame_size: i32 = c.JANET_FRAME_SIZE;

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
/// difference shows. `FOUND.md` has the entry and `test/marsh.c` pins the
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
inline fn stackFrame(values: [*c]c.Janet) *c.JanetStackFrame {
    return @ptrCast(@alignCast(values - asSize(frame_size)));
}

/// `janet_tuple_head` and `janet_struct_head` from `janet.h`. translate-c
/// drops the flexible array member, so the offset is spelled as the size of
/// the head; `test/gc_sweep.c` and `test/string_symbol.c` already assert from
/// C that the two are equal.
inline fn tupleHead(t: [*c]const c.Janet) *c.JanetTupleHead {
    return @ptrFromInt(@intFromPtr(t) -% @sizeOf(c.JanetTupleHead));
}

inline fn structHead(st: [*c]const c.JanetKV) *c.JanetStructHead {
    return @ptrFromInt(@intFromPtr(st) -% @sizeOf(c.JanetStructHead));
}

/// `janet_abstract_head` from `janet.h`.
inline fn abstractHead(a: ?*anyopaque) *c.JanetAbstractHead {
    return @ptrFromInt(@intFromPtr(a) -% @sizeOf(c.JanetAbstractHead));
}

/// `janet_gc_type` from `src/core/gc.h`, for the containers whose collectable
/// header is their first member.
inline fn gcType(object: anytype) i32 {
    return object.*.gc.flags & c.JANET_MEM_TYPEBITS;
}

/// `janet_wrap_integer`, written out rather than called. `janet.h` declares the
/// function beside its macro and `wrap.c` defines it only for the two nanbox
/// layouts, so a tagged build has no such symbol and a Zig caller -- which
/// cannot use the macro -- does not link. `pp_pretty.zig` and `value_access.zig`
/// write it out for the same reason and `FOUND.md` has the defect.
inline fn wrapInteger(x: i32) c.Janet {
    return c.janet_wrap_number(@floatFromInt(x));
}

/// `janet_assert` from `src/core/util.h`, a macro over `JANET_EXIT`. Not a
/// raise: a `NULL` from an abstract type's `unmarshal` callback is a defect in
/// that callback rather than a program error, and the C original prints and
/// calls `abort`.
inline fn marshAssert(condition: bool, message: [*c]const u8) void {
    if (!condition) c.janet_zig_fatal(message);
}

/// `JANET_OUT_OF_MEMORY`, which is fatal rather than raising.
inline fn allocated(pointer: ?*anyopaque) ?*anyopaque {
    if (pointer == null) c.janet_zig_out_of_memory();
    return pointer;
}

// The `janet_v_` vectors of `src/core/vector.h`, whose function-like macros do
// not survive translation. Same three-line shape `compile.c`'s and `emit.c`'s
// ports already carry; the two-word `int32_t` prefix is the existing private
// contract shared with `vector.h`.

const vector_header_size = 2 * @sizeOf(i32);

fn vectorHeader(comptime Element: type, vector: [*c]Element) [*]i32 {
    return @ptrFromInt(@intFromPtr(vector) - vector_header_size);
}

fn vectorCount(comptime Element: type, vector: [*c]Element) i32 {
    return if (vector == null) 0 else vectorHeader(Element, vector)[1];
}

fn vectorCapacity(comptime Element: type, vector: [*c]Element) i32 {
    return vectorHeader(Element, vector)[0];
}

fn pushVector(comptime Element: type, vector_pointer: *[*c]Element, value: Element) void {
    var vector = vector_pointer.*;
    const count = vectorCount(Element, vector);
    if (vector == null or count + 1 >= vectorCapacity(Element, vector)) {
        const grown = c.janet_v_grow(@as(?*anyopaque, @ptrCast(vector)), 1, @sizeOf(Element));
        vector = @ptrCast(@alignCast(grown));
        vector_pointer.* = vector;
    }
    vector[@intCast(count)] = value;
    vectorHeader(Element, vector)[1] = count + 1;
}

fn freeVector(comptime Element: type, vector: [*c]Element) void {
    if (vector != null) c.janet_sfree(vectorHeader(Element, vector));
}

// ==========================================================================
// Environment lookup tables
// ==========================================================================

/// Look inside one entry of an environment, preferring `:value` to `:ref`.
fn entryGetval(env_entry: c.Janet) c.Janet {
    if (c.janet_checktype(env_entry, c.JANET_TABLE) != 0) {
        const entry = c.janet_unwrap_table(env_entry);
        const checkval = c.janet_table_get(entry, c.janet_ckeywordv("value"));
        if (c.janet_checktype(checkval, c.JANET_NIL) != 0) {
            return c.janet_table_get(entry, c.janet_ckeywordv("ref"));
        }
        return checkval;
    } else if (c.janet_checktype(env_entry, c.JANET_STRUCT) != 0) {
        const entry = c.janet_unwrap_struct(env_entry);
        const checkval = c.janet_struct_get(entry, c.janet_ckeywordv("value"));
        if (c.janet_checktype(checkval, c.JANET_NIL) != 0) {
            return c.janet_struct_get(entry, c.janet_ckeywordv("ref"));
        }
        return checkval;
    } else {
        return c.janet_wrap_nil();
    }
}

/// Merge values from an environment into an existing lookup table.
///
/// No error channel and none needed: nothing here decides to raise. The
/// allocations can, and they jump, which is why the file carries the marker.
export fn janet_env_lookup_into(
    renv: [*c]c.JanetTable,
    env_in: [*c]c.JanetTable,
    prefix: [*c]const u8,
    recurse: c_int,
) callconv(.c) void {
    var env = env_in;
    while (env != null) {
        var i: i32 = 0;
        while (i < env.*.capacity) : (i += 1) {
            const kv = env.*.data[@intCast(i)];
            if (c.janet_checktype(kv.key, c.JANET_SYMBOL) == 0) continue;
            if (prefix != null) {
                const prelen: i32 = @intCast(std.mem.len(@as([*:0]const u8, @ptrCast(prefix))));
                const oldsym = c.janet_unwrap_symbol(kv.key);
                const oldlen = c.janet_string_length(oldsym);
                const symbuf: [*c]u8 = @ptrCast(c.janet_smalloc(asSize(prelen + oldlen)));
                safe_memcpy(symbuf, prefix, asSize(prelen));
                safe_memcpy(symbuf + asSize(prelen), oldsym, asSize(oldlen));
                const s = c.janet_symbolv(symbuf, prelen + oldlen);
                c.janet_sfree(symbuf);
                c.janet_table_put(renv, s, entryGetval(kv.value));
            } else {
                c.janet_table_put(renv, kv.key, entryGetval(kv.value));
            }
        }
        env = if (recurse != 0) env.*.proto else null;
    }
}

/// Make a forward lookup table from an environment, for unmarshalling.
export fn janet_env_lookup(env: [*c]c.JanetTable) callconv(.c) [*c]c.JanetTable {
    const renv = c.janet_table(env.*.count);
    janet_env_lookup_into(renv, env, null, 1);
    return renv;
}

// ==========================================================================
// Marshalling
// ==========================================================================

const MarshalState = struct {
    buf: [*c]c.JanetBuffer,
    seen: c.JanetTable,
    rreg: [*c]c.JanetTable,
    seen_envs: [*c]*c.JanetFuncEnv,
    seen_defs: [*c]*c.JanetFuncDef,
    nextid: i32,
    maybe_cycles: bool,
};

inline fn pushByte(st: *MarshalState, b: u8) raise.Raising(void) {
    try containers.bufferPushU8(st.buf, b);
}

inline fn pushBytes(st: *MarshalState, bytes: [*c]const u8, len: i32) raise.Raising(void) {
    try containers.bufferPushBytes(st.buf, bytes, len);
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
        try pushBytes(st, &intbuf, 2);
    } else {
        const u: u32 = @bitCast(x);
        const intbuf = [5]u8{
            lb_integer,
            @truncate(u >> 24),
            @truncate(u >> 16),
            @truncate(u >> 8),
            @truncate(u),
        };
        try pushBytes(st, &intbuf, 5);
    }
}

fn pushPointer(st: *MarshalState, ptr: ?*const anyopaque) raise.Raising(void) {
    try pushBytes(st, @ptrCast(&ptr), @sizeOf(?*const anyopaque));
}

/// A 64-bit unsigned integer, little endian, length-prefixed above `0xF0`.
fn push64(st: *MarshalState, value: u64) raise.Raising(void) {
    if (value <= 0xF0) {
        try pushByte(st, @intCast(value));
    } else {
        var bytes: [9]u8 = undefined;
        var nbytes: usize = 0;
        var x = value;
        while (x != 0) {
            nbytes += 1;
            bytes[nbytes] = @truncate(x);
            x >>= 8;
        }
        bytes[0] = 0xF0 + @as(u8, @intCast(nbytes));
        try pushBytes(st, &bytes, @intCast(nbytes + 1));
    }
}

/// The recursion guard. `flags` doubles as a depth counter in its low sixteen
/// bits, which is why every recursive call below passes `flags + 1` and why
/// the marshalling flags all live above `0xFFFF`.
inline fn stackCheck(flags: c_int) raise.Raising(void) {
    if ((flags & 0xFFFF) > c.JANET_RECURSION_GUARD) return raise.panic("stack overflow");
}

/// Record `x` as reference number `nextid` so that a later occurrence can be
/// written as `LB_REFERENCE`. `JANET_MARSHAL_NO_CYCLES` turns this off, at
/// which point a cyclic structure recurses until the guard above stops it.
fn markSeen(st: *MarshalState, x: c.Janet) void {
    if (st.maybe_cycles) {
        c.janet_table_put(&st.seen, x, wrapInteger(st.nextid));
        st.nextid += 1;
    }
}

/// A quick check for a fiber that cannot be marshalled. No false positives,
/// possible false negatives -- the full check happens on the way through.
fn fiberCannotBeMarshalled(fiber: [*c]c.JanetFiber) bool {
    if (c.janet_fiber_status(fiber) == c.JANET_STATUS_ALIVE) return true;
    var i = fiber.*.frame;
    while (i > 0) {
        const frame = stackFrame(fiber.*.data + asSize(i));
        if (frame.func == null) return true; // has cfunction on stack
        i = frame.prevframe;
    }
    return false;
}

fn marshalOneEnv(st: *MarshalState, env: [*c]c.JanetFuncEnv, flags: c_int) raise.Raising(void) {
    try stackCheck(flags);
    var i: i32 = 0;
    while (i < vectorCount(*c.JanetFuncEnv, st.seen_envs)) : (i += 1) {
        if (st.seen_envs[@intCast(i)] == env) {
            try pushByte(st, lb_funcenv_ref);
            try pushInt(st, i);
            return;
        }
    }
    _ = c.janet_env_valid(env);
    pushVector(*c.JanetFuncEnv, &st.seen_envs, env);

    if (env.*.offset > 0 and fiberCannotBeMarshalled(env.*.as.fiber)) {
        // Special case for early detachment: the fiber the values live on is
        // not marshallable, so they are written out as though already
        // detached, and the closure bitset says which slots are real.
        try pushInt(st, 0);
        try pushInt(st, env.*.length);
        const values = env.*.as.fiber.*.data + asSize(env.*.offset);
        const bitset = stackFrame(values).func.*.def.*.closure_bitset;
        var k: i32 = 0;
        while (k < env.*.length) : (k += 1) {
            const word = bitset[@intCast(k >> 5)];
            if (1 & (word >> @intCast(k & 0x1F)) != 0) {
                try marshalOne(st, values[@intCast(k)], flags + 1);
            } else {
                try pushByte(st, lb_nil);
            }
        }
    } else {
        c.janet_env_maybe_detach(env);
        try pushInt(st, env.*.offset);
        try pushInt(st, env.*.length);
        if (env.*.offset > 0) {
            // On stack variant
            try marshalOne(st, c.janet_wrap_fiber(env.*.as.fiber), flags + 1);
        } else {
            // Off stack variant
            var k: i32 = 0;
            while (k < env.*.length) : (k += 1) {
                try marshalOne(st, env.*.as.values[@intCast(k)], flags + 1);
            }
        }
    }
}

fn marshalU32s(st: *MarshalState, u32s: [*c]const u32, n: i32) raise.Raising(void) {
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const word = u32s[@intCast(i)];
        try pushByte(st, @truncate(word));
        try pushByte(st, @truncate(word >> 8));
        try pushByte(st, @truncate(word >> 16));
        try pushByte(st, @truncate(word >> 24));
    }
}

fn marshalOneDef(st: *MarshalState, def: [*c]c.JanetFuncDef, flags: c_int) raise.Raising(void) {
    try stackCheck(flags);
    var i: i32 = 0;
    while (i < vectorCount(*c.JanetFuncDef, st.seen_defs)) : (i += 1) {
        if (st.seen_defs[@intCast(i)] == def) {
            try pushByte(st, lb_funcdef_ref);
            try pushInt(st, i);
            return;
        }
    }
    pushVector(*c.JanetFuncDef, &st.seen_defs, def);

    try pushInt(st, def.*.flags);
    try pushInt(st, def.*.slotcount);
    try pushInt(st, def.*.arity);
    try pushInt(st, def.*.min_arity);
    try pushInt(st, def.*.max_arity);
    try pushInt(st, def.*.constants_length);
    try pushInt(st, def.*.bytecode_length);
    try if (def.*.flags & c.JANET_FUNCDEF_FLAG_NAMEDARGS != 0)
        pushInt(st, def.*.named_args_count);
    try if (def.*.flags & c.JANET_FUNCDEF_FLAG_HASENVS != 0)
        pushInt(st, def.*.environments_length);
    try if (def.*.flags & c.JANET_FUNCDEF_FLAG_HASDEFS != 0)
        pushInt(st, def.*.defs_length);
    try if (def.*.flags & c.JANET_FUNCDEF_FLAG_HASSYMBOLMAP != 0)
        pushInt(st, def.*.symbolmap_length);
    if (def.*.flags & c.JANET_FUNCDEF_FLAG_HASNAME != 0)
        try marshalOne(st, c.janet_wrap_string(def.*.name), flags);
    if (def.*.flags & c.JANET_FUNCDEF_FLAG_HASSOURCE != 0)
        try marshalOne(st, c.janet_wrap_string(def.*.source), flags);

    i = 0;
    while (i < def.*.constants_length) : (i += 1) {
        try marshalOne(st, def.*.constants[@intCast(i)], flags + 1);
    }

    i = 0;
    while (i < def.*.symbolmap_length) : (i += 1) {
        const entry = def.*.symbolmap[@intCast(i)];
        try pushInt(st, @bitCast(entry.birth_pc));
        try pushInt(st, @bitCast(entry.death_pc));
        try pushInt(st, @bitCast(entry.slot_index));
        try marshalOne(st, c.janet_wrap_symbol(entry.symbol), flags + 1);
    }

    try marshalU32s(st, def.*.bytecode, def.*.bytecode_length);

    i = 0;
    while (i < def.*.environments_length) : (i += 1) {
        try pushInt(st, def.*.environments[@intCast(i)]);
    }

    i = 0;
    while (i < def.*.defs_length) : (i += 1) {
        try marshalOneDef(st, def.*.defs[@intCast(i)], flags + 1);
    }

    if (def.*.flags & c.JANET_FUNCDEF_FLAG_HASSOURCEMAP != 0) {
        // Lines are written as deltas, columns absolute.
        var current: i32 = 0;
        i = 0;
        while (i < def.*.bytecode_length) : (i += 1) {
            const map = def.*.sourcemap[@intCast(i)];
            try pushInt(st, map.line -% current);
            try pushInt(st, map.column);
            current = map.line;
        }
    }

    if (def.*.flags & c.JANET_FUNCDEF_FLAG_HASCLOBITSET != 0) {
        try marshalU32s(st, def.*.closure_bitset, (def.*.slotcount + 31) >> 5);
    }
}

fn marshalOneFiber(st: *MarshalState, fiber: [*c]c.JanetFiber, flags: c_int) raise.Raising(void) {
    try stackCheck(flags);
    var fflags = fiber.*.flags;
    if (fiber.*.child != null) fflags |= fiber_flag_haschild;
    if (fiber.*.env != null) fflags |= fiber_flag_hasenv;
    if (c.janet_fiber_status(fiber) == c.JANET_STATUS_ALIVE)
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
        const frame = stackFrame(fiber.*.data + asSize(i));
        if (frame.env != null) frame.flags |= stackframe_hasenv;
        if (frame.func == null) {
            const as_cfun: c.JanetCFunction = @ptrFromInt(@intFromPtr(frame.pc));
            return pp_format.panicf(
                "cannot marshal fiber with c stackframe (%v)",
                .{c.janet_wrap_cfunction(as_cfun)},
            );
        }
        try pushInt(st, frame.flags);
        try pushInt(st, frame.prevframe);
        const pcdiff: i32 = @intCast(@divExact(
            @intFromPtr(frame.pc) - @intFromPtr(frame.func.*.def.*.bytecode),
            @sizeOf(u32),
        ));
        try pushInt(st, pcdiff);
        try marshalOne(st, c.janet_wrap_function(frame.func), flags + 1);
        if (frame.env != null) try marshalOneEnv(st, frame.env, flags + 1);
        var k = i;
        while (k < j) : (k += 1) {
            try marshalOne(st, fiber.*.data[@intCast(k)], flags + 1);
        }
        j = i - frame_size;
        i = frame.prevframe;
    }
    if (fiber.*.env != null) {
        try marshalOne(st, c.janet_wrap_table(fiber.*.env), flags + 1);
    }
    if (fiber.*.child != null) {
        try marshalOne(st, c.janet_wrap_fiber(fiber.*.child), flags + 1);
    }
    try marshalOne(st, fiber.*.last_value, flags + 1);
}

fn marshalOneAbstract(st: *MarshalState, x: c.Janet, flags: c_int) raise.Raising(void) {
    const abstract = c.janet_unwrap_abstract(x);
    if (has_ev) {
        // A threaded abstract crosses a thread boundary as a bare pointer in
        // unsafe mode. The refcount is incremented before the message is sent,
        // which is what prevents a "death in transit" -- the sending thread
        // dropping its reference and collecting while the message is still
        // between the two heaps.
        if ((flags & c.JANET_MARSHAL_UNSAFE) != 0 and
            gcType(abstractHead(abstract)) == c.JANET_MEMORY_THREADED_ABSTRACT)
        {
            _ = c.janet_abstract_incref(abstract);
            try pushByte(st, lb_threaded_abstract);
            try pushBytes(st, @ptrCast(&abstract), @sizeOf(?*anyopaque));
            markSeen(st, x);
            return;
        }
    }
    const at = abstract_type.ofAbstract(abstract);
    if (at.*.marshal) |marshal_fn| {
        try pushByte(st, lb_abstract);
        try marshalOne(st, c.janet_csymbolv(at.*.name), flags + 1);
        var context: c.JanetMarshalContext = .{
            .m_state = st,
            .u_state = null,
            .flags = flags + 1,
            .data = null,
            .at = abstract_type.stored(at),
        };
        try marshal_fn(abstract, &context);
    } else {
        return pp_format.panicf("cannot marshal %p", .{x});
    }
}

/// The main body of the marshaller, and the entry point of the mutually
/// recursive group above.
fn marshalOne(st: *MarshalState, x: c.Janet, flags: c_int) raise.Raising(void) {
    try stackCheck(flags);
    const vtype = c.janet_type(x);

    // Simple primitives first: no reference type, so nothing to memoize.
    switch (vtype) {
        c.JANET_NIL => {
            try pushByte(st, lb_nil);
            return;
        },
        c.JANET_BOOLEAN => {
            try pushByte(st, if (c.janet_unwrap_boolean(x) != 0) lb_true else lb_false);
            return;
        },
        c.JANET_NUMBER => {
            const xval = c.janet_unwrap_number(x);
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
        const check = c.janet_table_get(&st.seen, x);
        if (c.janet_checkint(check) != 0) {
            try pushByte(st, lb_reference);
            try pushInt(st, c.janet_unwrap_integer(check));
            return;
        }
    }
    if (st.rreg != null) {
        const check = c.janet_table_get(st.rreg, x);
        if (c.janet_checktype(check, c.JANET_SYMBOL) != 0) {
            markSeen(st, x);
            const regname = c.janet_unwrap_symbol(check);
            try pushByte(st, lb_registry);
            try pushInt(st, c.janet_string_length(regname));
            try pushBytes(st, regname, c.janet_string_length(regname));
            return;
        }
    }

    switch (vtype) {
        c.JANET_NUMBER => {
            var bytes: [8]u8 = @bitCast(c.janet_unwrap_number(x));
            if (big_endian) std.mem.reverse(u8, &bytes);
            try pushByte(st, lb_real);
            try pushBytes(st, &bytes, 8);
            markSeen(st, x);
        },
        c.JANET_STRING, c.JANET_SYMBOL, c.JANET_KEYWORD => {
            const str = c.janet_unwrap_string(x);
            const length = c.janet_string_length(str);
            markSeen(st, x);
            try pushByte(st, switch (vtype) {
                c.JANET_STRING => lb_string,
                c.JANET_SYMBOL => lb_symbol,
                else => lb_keyword,
            });
            try pushInt(st, length);
            try pushBytes(st, str, length);
        },
        c.JANET_BUFFER => {
            const buffer = c.janet_unwrap_buffer(x);
            markSeen(st, x);
            if (has_ev) {
                // A buffer over memory the runtime does not own travels as its
                // pointer, in unsafe mode only.
                if ((flags & c.JANET_MARSHAL_UNSAFE) != 0 and
                    (buffer.*.gc.flags & c.JANET_BUFFER_FLAG_NO_REALLOC) != 0)
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
            try pushBytes(st, buffer.*.data, buffer.*.count);
        },
        c.JANET_ARRAY => {
            const a = c.janet_unwrap_array(x);
            markSeen(st, x);
            try pushByte(st, if (gcType(a) == c.JANET_MEMORY_ARRAY_WEAK) lb_array_weak else lb_array);
            try pushInt(st, a.*.count);
            var i: i32 = 0;
            while (i < a.*.count) : (i += 1) {
                try marshalOne(st, a.*.data[@intCast(i)], flags + 1);
            }
        },
        c.JANET_TUPLE => {
            const tup = c.janet_unwrap_tuple(x);
            const count = c.janet_tuple_length(tup);
            const flag = tupleHead(tup).gc.flags >> 16;
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
        c.JANET_TABLE => {
            const t = c.janet_unwrap_table(x);
            markSeen(st, x);
            const has_proto = t.*.proto != null;
            try pushByte(st, switch (gcType(t)) {
                c.JANET_MEMORY_TABLE_WEAKK => if (has_proto) lb_table_weakk_proto else lb_table_weakk,
                c.JANET_MEMORY_TABLE_WEAKV => if (has_proto) lb_table_weakv_proto else lb_table_weakv,
                c.JANET_MEMORY_TABLE_WEAKKV => if (has_proto) lb_table_weakkv_proto else lb_table_weakkv,
                else => if (has_proto) lb_table_proto else lb_table,
            });
            try pushInt(st, t.*.count);
            if (has_proto) try marshalOne(st, c.janet_wrap_table(t.*.proto), flags + 1);
            var i: i32 = 0;
            while (i < t.*.capacity) : (i += 1) {
                const kv = t.*.data[@intCast(i)];
                if (c.janet_checktype(kv.key, c.JANET_NIL) != 0) continue;
                try marshalOne(st, kv.key, flags + 1);
                try marshalOne(st, kv.value, flags + 1);
            }
        },
        c.JANET_STRUCT => {
            const struct_ = c.janet_unwrap_struct(x);
            const head = structHead(struct_);
            const count = head.length;
            try pushByte(st, if (head.proto != null) lb_struct_proto else lb_struct);
            try pushInt(st, count);
            if (head.proto != null) {
                try marshalOne(st, c.janet_wrap_struct(head.proto), flags + 1);
            }
            var i: i32 = 0;
            while (i < head.capacity) : (i += 1) {
                const kv = struct_[@intCast(i)];
                if (c.janet_checktype(kv.key, c.JANET_NIL) != 0) continue;
                try marshalOne(st, kv.key, flags + 1);
                try marshalOne(st, kv.value, flags + 1);
            }
            // Marked as seen AFTER marshalling, for the reason the tuple case
            // gives.
            markSeen(st, x);
        },
        c.JANET_ABSTRACT => {
            try marshalOneAbstract(st, x, flags);
        },
        c.JANET_FUNCTION => {
            try pushByte(st, lb_function);
            const func = c.janet_unwrap_function(x);
            try pushInt(st, func.*.def.*.environments_length);
            // Marked seen before the def is read, so that a function reachable
            // from its own closure resolves.
            markSeen(st, x);
            try marshalOneDef(st, func.*.def, flags);
            var i: i32 = 0;
            while (i < func.*.def.*.environments_length) : (i += 1) {
                try marshalOneEnv(st, funcEnv(func, i).*, flags + 1);
            }
        },
        c.JANET_FIBER => {
            markSeen(st, x);
            try pushByte(st, lb_fiber);
            try marshalOneFiber(st, c.janet_unwrap_fiber(x), flags + 1);
        },
        c.JANET_CFUNCTION => {
            if ((flags & c.JANET_MARSHAL_UNSAFE) == 0) return noRegistry(x);
            markSeen(st, x);
            try pushByte(st, lb_unsafe_cfunction);
            const cfn = c.janet_unwrap_cfunction(x);
            try pushBytes(st, @ptrCast(&cfn), @sizeOf(c.JanetCFunction));
        },
        c.JANET_POINTER => {
            if ((flags & c.JANET_MARSHAL_UNSAFE) == 0) return noRegistry(x);
            markSeen(st, x);
            try pushByte(st, lb_unsafe_pointer);
            try pushPointer(st, c.janet_unwrap_pointer(x));
        },
        // Unreachable: nil and boolean returned from the first switch, and
        // every other type has a case. Reproduced because the C original's
        // `default` is what the two unsafe cases fall through to.
        else => return noRegistry(x),
    }
}

fn noRegistry(x: c.Janet) raise.Error {
    return pp_format.panicf("no registry value and cannot marshal %p", .{x});
}

/// `func->envs[i]` as an lvalue. `envs` is a flexible array member and
/// translate-c drops it, so the slot is computed the way `janet_function`
/// allocates it: immediately after the header.
inline fn funcEnv(func: [*c]c.JanetFunction, index: i32) *[*c]c.JanetFuncEnv {
    const base: [*][*c]c.JanetFuncEnv = @ptrFromInt(@intFromPtr(func) +% @sizeOf(c.JanetFunction));
    return &base[@intCast(index)];
}

const big_endian = @hasDecl(c, "JANET_BIG_ENDIAN");

pub fn marshal(
    buf: [*c]c.JanetBuffer,
    x: c.Janet,
    rreg: [*c]c.JanetTable,
    flags: c_int,
) raise.Raising(void) {
    var st: MarshalState = .{
        .buf = buf,
        .seen = undefined,
        .rreg = rreg,
        .seen_envs = null,
        .seen_defs = null,
        .nextid = 0,
        .maybe_cycles = (flags & c.JANET_MARSHAL_NO_CYCLES) == 0,
    };
    _ = c.janet_table_init(&st.seen, 0);
    try marshalOne(&st, x, flags);
    c.janet_table_deinit(&st.seen);
    freeVector(*c.JanetFuncEnv, st.seen_envs);
    freeVector(*c.JanetFuncDef, st.seen_defs);
}

const marshalFace = raise.panicking(marshal).face;

comptime {
    @export(&marshalFace, .{ .name = "janet_marshal" });
}

// ------------------------------------------------- the marshal context API

inline fn marshalState(ctx: [*c]c.JanetMarshalContext) *MarshalState {
    return @ptrCast(@alignCast(ctx.*.m_state));
}

/// `size_t` is not 64 bits everywhere -- `riscv32-linux` is one of this
/// project's cross-compile targets -- so the C original's `(int64_t) value`
/// widens before it reinterprets, and `(size_t)` on the way back truncates.
/// Zig's `@bitCast` refuses a width change, which is what makes the two steps
/// visible here and invisible there.
export fn janet_marshal_size(ctx: [*c]c.JanetMarshalContext, value: usize) callconv(.c) void {
    raise.reported(marshalInt64(ctx, @bitCast(@as(u64, value))));
}

pub fn marshalInt64(ctx: [*c]c.JanetMarshalContext, value: i64) raise.Raising(void) {
    try push64(marshalState(ctx), @bitCast(value));
}

export fn janet_marshal_int64(ctx: [*c]c.JanetMarshalContext, value: i64) callconv(.c) void {
    raise.reported(marshalInt64(ctx, value));
}

pub fn marshalInt(ctx: [*c]c.JanetMarshalContext, value: i32) raise.Raising(void) {
    try pushInt(marshalState(ctx), value);
}

export fn janet_marshal_int(ctx: [*c]c.JanetMarshalContext, value: i32) callconv(.c) void {
    raise.reported(marshalInt(ctx, value));
}

/// Only meaningful in unsafe mode; a pointer means nothing to another process.
pub fn marshalPtr(ctx: [*c]c.JanetMarshalContext, ptr: ?*const anyopaque) raise.Raising(void) {
    if ((ctx.*.flags & c.JANET_MARSHAL_UNSAFE) == 0) {
        return raise.panic("can only marshal pointers in unsafe mode");
    }
    try pushPointer(marshalState(ctx), ptr);
}

pub fn marshalByte(ctx: [*c]c.JanetMarshalContext, value: u8) raise.Raising(void) {
    try pushByte(marshalState(ctx), value);
}

export fn janet_marshal_byte(ctx: [*c]c.JanetMarshalContext, value: u8) callconv(.c) void {
    raise.reported(marshalByte(ctx, value));
}

fn marshalBytes(ctx: [*c]c.JanetMarshalContext, bytes: [*c]const u8, len: usize) raise.Raising(void) {
    const st = marshalState(ctx);
    if (len > std.math.maxInt(i32)) return raise.panic("size_t too large to fit in buffer");
    try pushBytes(st, bytes, @intCast(len));
}

pub fn marshalJanet(ctx: [*c]c.JanetMarshalContext, x: c.Janet) raise.Raising(void) {
    return marshalOne(marshalState(ctx), x, ctx.*.flags + 1);
}

export fn janet_marshal_abstract(ctx: [*c]c.JanetMarshalContext, abstract: ?*anyopaque) callconv(.c) void {
    markSeen(marshalState(ctx), c.janet_wrap_abstract(abstract));
}

export fn janet_marshal_flags(ctx: [*c]c.JanetMarshalContext) callconv(.c) c_int {
    return ctx.*.flags;
}

const marshalPtrFace = raise.panicking(marshalPtr).face;
const marshalBytesFace = raise.panicking(marshalBytes).face;
const marshalJanetFace = raise.panicking(marshalJanet).face;

comptime {
    @export(&marshalPtrFace, .{ .name = "janet_marshal_ptr" });
    @export(&marshalBytesFace, .{ .name = "janet_marshal_bytes" });
    @export(&marshalJanetFace, .{ .name = "janet_marshal_janet" });
}

// ==========================================================================
// Unmarshalling
// ==========================================================================

/// The C original's first field is a `jmp_buf err` that nothing ever writes to
/// or jumps through: this subsystem reports failure by raising, and always
/// did. It is dropped rather than transcribed.
const UnmarshalState = struct {
    lookup: [*c]c.Janet,
    reg: [*c]c.JanetTable,
    lookup_envs: [*c]*c.JanetFuncEnv,
    lookup_defs: [*c]*c.JanetFuncDef,
    start: [*c]const u8,
    end: [*c]const u8,
};

/// `MARSH_EOS`. The address is computed rather than the pointer, because two
/// call sites below check `data - 1 + len` with a length that may be zero, and
/// wrapping arithmetic is what the C original does there.
inline fn eosAddr(st: *UnmarshalState, addr: usize) raise.Raising(void) {
    if (addr >= @intFromPtr(st.end)) return raise.panic("unexpected end of source");
}

inline fn eos(st: *UnmarshalState, data: [*c]const u8) raise.Raising(void) {
    return eosAddr(st, @intFromPtr(data));
}

/// The offset a diagnostic reports, which is a position in the input rather
/// than an address.
inline fn indexOf(st: *UnmarshalState, data: [*c]const u8) i32 {
    return @intCast(@intFromPtr(data) - @intFromPtr(st.start));
}

/// Read a 32-bit integer written by `pushInt`.
fn readInt(st: *UnmarshalState, atdata: *[*c]const u8) raise.Raising(i32) {
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
fn readNat(st: *UnmarshalState, atdata: *[*c]const u8) raise.Raising(i32) {
    const ret = try readInt(st, atdata);
    if (ret < 0) return pp_format.panicf("expected integer >= 0, got %d", .{ret});
    return ret;
}

/// Read a 64-bit unsigned integer written by `push64`.
fn read64(st: *UnmarshalState, atdata: *[*c]const u8) raise.Raising(u64) {
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

fn assertType(x: c.Janet, t: c.JanetType) raise.Raising(void) {
    if (c.janet_checktype(x, t) == 0) {
        return pp_format.panicf("expected type %T, got %v", .{ @as(c_int, 1) << @intCast(t), x });
    }
}

fn unmarshalOneEnv(
    st: *UnmarshalState,
    data_in: [*c]const u8,
    out: [*c][*c]c.JanetFuncEnv,
    flags: c_int,
) raise.Raising([*c]const u8) {
    var data = data_in;
    try eos(st, data);
    if (data[0] == lb_funcenv_ref) {
        data += 1;
        const index = try readInt(st, &data);
        if (index < 0 or index >= vectorCount(*c.JanetFuncEnv, st.lookup_envs))
            return pp_format.panicf("invalid funcenv reference %d", .{index});
        out.* = st.lookup_envs[@intCast(index)];
        return data;
    }

    const env: [*c]c.JanetFuncEnv = @ptrCast(@alignCast(c.janet_gcalloc(
        c.JANET_MEMORY_FUNCENV,
        @sizeOf(c.JanetFuncEnv),
    )));
    env.*.length = 0;
    env.*.offset = 0;
    env.*.as.values = null;
    pushVector(*c.JanetFuncEnv, &st.lookup_envs, env);
    const offset = try readNat(st, &data);
    const length = try readNat(st, &data);
    if (offset > 0) {
        // On stack variant
        var fiberv: c.Janet = undefined;
        data = try unmarshalOne(st, data, &fiberv, flags);
        try assertType(fiberv, c.JANET_FIBER);
        env.*.as.fiber = c.janet_unwrap_fiber(fiberv);
        // A negative offset marks the environment as coming from untrusted
        // input, which is what stops the runtime treating it as live stack.
        env.*.offset = -offset;
    } else {
        // Off stack variant
        if (length == 0) return raise.panic("invalid funcenv length");
        env.*.as.values = @ptrCast(@alignCast(allocated(
            c.janet_malloc(@sizeOf(c.Janet) * asSize(length)),
        )));
        env.*.offset = 0;
        var i: i32 = 0;
        while (i < length) : (i += 1) {
            data = try unmarshalOne(st, data, &env.*.as.values[@intCast(i)], flags);
        }
    }
    env.*.length = length;
    out.* = env;
    return data;
}

fn unmarshalU32s(
    st: *UnmarshalState,
    data_in: [*c]const u8,
    into: [*c]u32,
    n: i32,
) raise.Raising([*c]const u8) {
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
    data_in: [*c]const u8,
    out: [*c][*c]c.JanetFuncDef,
    flags: c_int,
) raise.Raising([*c]const u8) {
    var data = data_in;
    try eos(st, data);
    if (data[0] == lb_funcdef_ref) {
        data += 1;
        const index = try readInt(st, &data);
        if (index < 0 or index >= vectorCount(*c.JanetFuncDef, st.lookup_defs))
            return pp_format.panicf("invalid funcdef reference %d", .{index});
        out.* = st.lookup_defs[@intCast(index)];
        return data;
    }

    // Initialised with values that will not break garbage collection if
    // unmarshalling fails partway.
    const def: [*c]c.JanetFuncDef = @ptrCast(@alignCast(c.janet_gcalloc(
        c.JANET_MEMORY_FUNCDEF,
        @sizeOf(c.JanetFuncDef),
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
    pushVector(*c.JanetFuncDef, &st.lookup_defs, def);

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
    if (def.*.flags & c.JANET_FUNCDEF_FLAG_NAMEDARGS != 0)
        def.*.named_args_count = try readNat(st, &data);
    if (def.*.flags & c.JANET_FUNCDEF_FLAG_HASENVS != 0)
        environments_length = try readNat(st, &data);
    if (def.*.flags & c.JANET_FUNCDEF_FLAG_HASDEFS != 0)
        defs_length = try readNat(st, &data);
    if (def.*.flags & c.JANET_FUNCDEF_FLAG_HASSYMBOLMAP != 0)
        symbolmap_length = try readNat(st, &data);

    if (def.*.flags & c.JANET_FUNCDEF_FLAG_HASNAME != 0) {
        var x: c.Janet = undefined;
        data = try unmarshalOne(st, data, &x, flags + 1);
        try assertType(x, c.JANET_STRING);
        def.*.name = c.janet_unwrap_string(x);
    }
    if (def.*.flags & c.JANET_FUNCDEF_FLAG_HASSOURCE != 0) {
        var x: c.Janet = undefined;
        data = try unmarshalOne(st, data, &x, flags + 1);
        try assertType(x, c.JANET_STRING);
        def.*.source = c.janet_unwrap_string(x);
    }

    if (constants_length != 0) {
        def.*.constants = @ptrCast(@alignCast(allocated(
            c.janet_malloc(@sizeOf(c.Janet) * asSize(constants_length)),
        )));
        var i: i32 = 0;
        while (i < constants_length) : (i += 1) {
            data = try unmarshalOne(st, data, &def.*.constants[@intCast(i)], flags + 1);
        }
    } else {
        def.*.constants = null;
    }
    def.*.constants_length = constants_length;

    if (def.*.flags & c.JANET_FUNCDEF_FLAG_HASSYMBOLMAP != 0) {
        def.*.symbolmap = @ptrCast(@alignCast(allocated(
            c.janet_malloc(@sizeOf(c.JanetSymbolMap) * asSize(symbolmap_length)),
        )));
        var i: i32 = 0;
        while (i < symbolmap_length) : (i += 1) {
            const entry = &def.*.symbolmap[@intCast(i)];
            entry.birth_pc = @bitCast(try readInt(st, &data));
            entry.death_pc = @bitCast(try readInt(st, &data));
            entry.slot_index = @bitCast(try readInt(st, &data));
            var value: c.Janet = undefined;
            data = try unmarshalOne(st, data, &value, flags + 1);
            if (c.janet_checktype(value, c.JANET_SYMBOL) == 0) {
                return pp_format.panicf(
                    "corrupted symbolmap when unmarshalling debug info, got %v",
                    .{value},
                );
            }
            entry.symbol = c.janet_unwrap_symbol(value);
        }
        def.*.symbolmap_length = symbolmap_length;
    }

    def.*.bytecode = @ptrCast(@alignCast(allocated(
        c.janet_malloc(@sizeOf(u32) * asSize(bytecode_length)),
    )));
    data = try unmarshalU32s(st, data, def.*.bytecode, bytecode_length);
    def.*.bytecode_length = bytecode_length;

    if (def.*.flags & c.JANET_FUNCDEF_FLAG_HASENVS != 0) {
        def.*.environments = @ptrCast(@alignCast(allocated(
            c.janet_calloc(1, @sizeOf(i32) * asSize(environments_length)),
        )));
        var i: i32 = 0;
        while (i < environments_length) : (i += 1) {
            def.*.environments[@intCast(i)] = try readInt(st, &data);
        }
    } else {
        def.*.environments = null;
    }
    def.*.environments_length = environments_length;

    if (def.*.flags & c.JANET_FUNCDEF_FLAG_HASDEFS != 0) {
        def.*.defs = @ptrCast(@alignCast(allocated(
            c.janet_calloc(1, @sizeOf([*c]c.JanetFuncDef) * asSize(defs_length)),
        )));
        var i: i32 = 0;
        while (i < defs_length) : (i += 1) {
            data = try unmarshalOneDef(st, data, &def.*.defs[@intCast(i)], flags + 1);
        }
    } else {
        def.*.defs = null;
    }
    def.*.defs_length = defs_length;

    if (def.*.flags & c.JANET_FUNCDEF_FLAG_HASSOURCEMAP != 0) {
        def.*.sourcemap = @ptrCast(@alignCast(allocated(
            c.janet_malloc(@sizeOf(c.JanetSourceMapping) * asSize(bytecode_length)),
        )));
        var current: i32 = 0;
        var i: i32 = 0;
        while (i < bytecode_length) : (i += 1) {
            current +%= try readInt(st, &data);
            def.*.sourcemap[@intCast(i)].line = current;
            def.*.sourcemap[@intCast(i)].column = try readInt(st, &data);
        }
    } else {
        def.*.sourcemap = null;
    }

    if (def.*.flags & c.JANET_FUNCDEF_FLAG_HASCLOBITSET != 0) {
        const n = (def.*.slotcount + 31) >> 5;
        def.*.closure_bitset = @ptrCast(@alignCast(allocated(
            c.janet_malloc(@sizeOf(u32) * asSize(n)),
        )));
        data = try unmarshalU32s(st, data, def.*.closure_bitset, n);
    }

    if (c.janet_verify(def) != 0) return raise.panic("funcdef has invalid bytecode");

    out.* = def;
    return data;
}

fn unmarshalOneFiber(
    st: *UnmarshalState,
    data_in: [*c]const u8,
    out: [*c][*c]c.JanetFiber,
    flags: c_int,
) raise.Raising([*c]const u8) {
    var data = data_in;

    // A new fiber with collector-friendly defaults: it enters the reference
    // table before any of its fields are read, so a failure partway leaves
    // something the collector can walk.
    const fiber: [*c]c.JanetFiber = @ptrCast(@alignCast(c.janet_gcalloc(
        c.JANET_MEMORY_FIBER,
        @sizeOf(c.JanetFiber),
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
    fiber.*.last_value = c.janet_wrap_nil();
    if (has_ev) {
        fiber.*.sched_id = 0;
        fiber.*.supervisor_channel = null;
        fiber.*.ev_state = null;
        fiber.*.ev_callback = null;
        fiber.*.ev_stream = null;
    }

    pushVector(c.Janet, &st.lookup, c.janet_wrap_fiber(fiber));

    var fiber_flags = try readInt(st, &data);
    const frame = try readNat(st, &data);
    const fiber_stackstart = try readNat(st, &data);
    const fiber_stacktop = try readNat(st, &data);
    const fiber_maxstack = try readNat(st, &data);
    var fiber_env: [*c]c.JanetTable = null;

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
        c.janet_malloc(@sizeOf(c.Janet) * asSize(fiber.*.capacity)),
    )));
    var i: i32 = 0;
    while (i < fiber.*.capacity) : (i += 1) {
        fiber.*.data[@intCast(i)] = c.janet_wrap_nil();
    }

    var stack = frame;
    var stacktop = fiber_stackstart - frame_size;
    while (stack > 0) {
        var env: [*c]c.JanetFuncEnv = null;
        var frameflags = try readInt(st, &data);
        const prevframe = try readNat(st, &data);
        const pcdiff = try readNat(st, &data);

        const framestack = fiber.*.data + asSize(stack);
        const framep = stackFrame(framestack);

        var funcv: c.Janet = undefined;
        data = try unmarshalOne(st, data, &funcv, flags + 1);
        try assertType(funcv, c.JANET_FUNCTION);
        const func = c.janet_unwrap_function(funcv);
        const def = func.*.def;

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
            data = try unmarshalOne(st, data, &fiber.*.data[@intCast(i)], flags + 1);
        }

        framep.env = env;
        framep.pc = def.*.bytecode + asSize(pcdiff);
        framep.prevframe = prevframe;
        framep.flags = frameflags;
        framep.func = func;

        stacktop = stack - frame_size;
        stack = prevframe;
    }
    if (stack < 0) return raise.panic("fiber has too many stackframes");

    if (fiber_flags & fiber_flag_hasenv != 0) {
        var envv: c.Janet = undefined;
        fiber_flags &= ~fiber_flag_hasenv;
        data = try unmarshalOne(st, data, &envv, flags + 1);
        try assertType(envv, c.JANET_TABLE);
        fiber_env = c.janet_unwrap_table(envv);
    }

    if (fiber_flags & fiber_flag_haschild != 0) {
        var fiberv: c.Janet = undefined;
        fiber_flags &= ~fiber_flag_haschild;
        data = try unmarshalOne(st, data, &fiberv, flags + 1);
        try assertType(fiberv, c.JANET_FIBER);
        fiber.*.child = c.janet_unwrap_fiber(fiberv);
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

    const status = c.janet_fiber_status(fiber);
    if (status < 0 or status > c.JANET_STATUS_ALIVE) {
        return raise.panic("invalid fiber status");
    }

    out.* = fiber;
    return data;
}

// ----------------------------------------------- the unmarshal context API

inline fn unmarshalState(ctx: [*c]c.JanetMarshalContext) *UnmarshalState {
    return @ptrCast(@alignCast(ctx.*.u_state));
}

fn unmarshalEnsure(ctx: [*c]c.JanetMarshalContext, size: usize) raise.Raising(void) {
    return eosAddr(unmarshalState(ctx), @intFromPtr(ctx.*.data) +% size);
}

pub fn unmarshalInt(ctx: [*c]c.JanetMarshalContext) raise.Raising(i32) {
    return readInt(unmarshalState(ctx), &ctx.*.data);
}

pub fn unmarshalSize(ctx: [*c]c.JanetMarshalContext) raise.Raising(usize) {
    return @truncate(@as(u64, @bitCast(try unmarshalInt64(ctx))));
}

pub fn unmarshalInt64(ctx: [*c]c.JanetMarshalContext) raise.Raising(i64) {
    return @bitCast(try read64(unmarshalState(ctx), &ctx.*.data));
}

pub fn unmarshalPtr(ctx: [*c]c.JanetMarshalContext) raise.Raising(?*anyopaque) {
    if ((ctx.*.flags & c.JANET_MARSHAL_UNSAFE) == 0) {
        return raise.panic("can only unmarshal pointers in unsafe mode");
    }
    const st = unmarshalState(ctx);
    try eosAddr(st, @intFromPtr(ctx.*.data) +% @sizeOf(?*anyopaque) -% 1);
    var ptr: ?*anyopaque = undefined;
    @memcpy(@as([*]u8, @ptrCast(&ptr))[0..@sizeOf(?*anyopaque)], ctx.*.data[0..@sizeOf(?*anyopaque)]);
    ctx.*.data += @sizeOf(?*anyopaque);
    return ptr;
}

pub fn unmarshalByte(ctx: [*c]c.JanetMarshalContext) raise.Raising(u8) {
    const st = unmarshalState(ctx);
    try eos(st, ctx.*.data);
    const value = ctx.*.data[0];
    ctx.*.data += 1;
    return value;
}

fn unmarshalBytes(ctx: [*c]c.JanetMarshalContext, dest: [*c]u8, len: usize) raise.Raising(void) {
    const st = unmarshalState(ctx);
    try eosAddr(st, @intFromPtr(ctx.*.data) +% len -% 1);
    safe_memcpy(dest, ctx.*.data, len);
    ctx.*.data += len;
}

pub fn unmarshalJanet(ctx: [*c]c.JanetMarshalContext) raise.Raising(c.Janet) {
    var ret: c.Janet = undefined;
    ctx.*.data = try unmarshalOne(unmarshalState(ctx), ctx.*.data, &ret, ctx.*.flags);
    return ret;
}

/// Enter an already-allocated abstract into the reference table, and mark the
/// context as having done so. `at` is the flag: `unmarshalOneAbstract` checks
/// that it was cleared, which is how a callback that forgets is caught.
fn unmarshalAbstractReuse(ctx: [*c]c.JanetMarshalContext, p: ?*anyopaque) raise.Raising(void) {
    if (ctx.*.at == null) {
        return raise.panic("janet_unmarshal_abstract called more than once");
    }
    pushVector(c.Janet, &unmarshalState(ctx).lookup, c.janet_wrap_abstract(p));
    ctx.*.at = null;
}

pub fn unmarshalAbstract(ctx: [*c]c.JanetMarshalContext, size: usize) raise.Raising(?*anyopaque) {
    const p = c.janet_abstract(ctx.*.at, size);
    try unmarshalAbstractReuse(ctx, p);
    return p;
}

/// Always raises. `JANET_THREADS` is defined by nothing in this tree, so the
/// C original's other arm has never been compiled -- see `FOUND.md`.
pub fn unmarshalAbstractThreaded(ctx: [*c]c.JanetMarshalContext, size: usize) raise.Raising(?*anyopaque) {
    _ = ctx;
    _ = size;
    return raise.panic("threaded abstracts not supported");
}

export fn janet_unmarshal_flags(ctx: [*c]c.JanetMarshalContext) callconv(.c) c_int {
    return ctx.*.flags;
}

const unmarshalEnsureFace = raise.panicking(unmarshalEnsure).face;
const unmarshalIntFace = raise.panicking(unmarshalInt).face;
const unmarshalSizeFace = raise.panicking(unmarshalSize).face;
const unmarshalInt64Face = raise.panicking(unmarshalInt64).face;
const unmarshalPtrFace = raise.panicking(unmarshalPtr).face;
const unmarshalByteFace = raise.panicking(unmarshalByte).face;
const unmarshalBytesFace = raise.panicking(unmarshalBytes).face;
const unmarshalJanetFace = raise.panicking(unmarshalJanet).face;
const unmarshalAbstractReuseFace = raise.panicking(unmarshalAbstractReuse).face;
const unmarshalAbstractFace = raise.panicking(unmarshalAbstract).face;
const unmarshalAbstractThreadedFace = raise.panicking(unmarshalAbstractThreaded).face;

comptime {
    @export(&unmarshalEnsureFace, .{ .name = "janet_unmarshal_ensure" });
    @export(&unmarshalIntFace, .{ .name = "janet_unmarshal_int" });
    @export(&unmarshalSizeFace, .{ .name = "janet_unmarshal_size" });
    @export(&unmarshalInt64Face, .{ .name = "janet_unmarshal_int64" });
    @export(&unmarshalPtrFace, .{ .name = "janet_unmarshal_ptr" });
    @export(&unmarshalByteFace, .{ .name = "janet_unmarshal_byte" });
    @export(&unmarshalBytesFace, .{ .name = "janet_unmarshal_bytes" });
    @export(&unmarshalJanetFace, .{ .name = "janet_unmarshal_janet" });
    @export(&unmarshalAbstractReuseFace, .{ .name = "janet_unmarshal_abstract_reuse" });
    @export(&unmarshalAbstractFace, .{ .name = "janet_unmarshal_abstract" });
    @export(&unmarshalAbstractThreadedFace, .{ .name = "janet_unmarshal_abstract_threaded" });
}

fn unmarshalOneAbstract(
    st: *UnmarshalState,
    data_in: [*c]const u8,
    out: [*c]c.Janet,
    flags: c_int,
) raise.Raising([*c]const u8) {
    var key: c.Janet = undefined;
    const data = try unmarshalOne(st, data_in, &key, flags + 1);
    const stored_at = c.janet_get_abstract_type(key);
    if (stored_at == null) return raise.panic("unknown abstract type");
    const at = abstract_type.of(stored_at);
    if (at.unmarshal) |unmarshal_fn| {
        var context: c.JanetMarshalContext = .{
            .m_state = null,
            .u_state = st,
            .flags = flags,
            .data = data,
            .at = stored_at,
        };
        const abst = try unmarshal_fn(&context);
        marshAssert(abst != null, "null pointer abstract");
        out.* = c.janet_wrap_abstract(abst);
        if (context.at != null) return raise.panic("janet_unmarshal_abstract not called");
        return context.data;
    }
    return raise.panic("invalid abstract type - no unmarshal function pointer");
}

/// The main body of the unmarshaller.
fn unmarshalOne(
    st: *UnmarshalState,
    data_in: [*c]const u8,
    out: [*c]c.Janet,
    flags: c_int,
) raise.Raising([*c]const u8) {
    var data = data_in;
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
                if ((flags & c.JANET_MARSHAL_UNSAFE) == 0) {
                    return pp_format.panicf(
                        "unsafe flag not given, will not unmarshal raw pointer at index %d",
                        .{indexOf(st, data)},
                    );
                }
                var ptr: ?*anyopaque = undefined;
                @memcpy(@as([*]u8, @ptrCast(&ptr))[0..@sizeOf(?*anyopaque)], data[0..@sizeOf(?*anyopaque)]);
                data += @sizeOf(?*anyopaque);
                const buffer = try containers.pointerBufferUnsafe(ptr, capacity, count);
                out.* = c.janet_wrap_buffer(buffer);
                pushVector(c.Janet, &st.lookup, out.*);
                return data;
            },
            lb_threaded_abstract => {
                try eos(st, data + @sizeOf(?*anyopaque));
                data += 1;
                if ((flags & c.JANET_MARSHAL_UNSAFE) == 0) {
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
                    _ = c.janet_abstract_decref(ptr);
                    out.* = c.janet_wrap_nil();
                } else {
                    out.* = c.janet_wrap_abstract(ptr);
                    const check = c.janet_table_get(&c.janet_vm.threaded_abstracts, out.*);
                    if (c.janet_checktype(check, c.JANET_NIL) != 0) {
                        // Transfers the reference from the channel's buffer to
                        // this heap.
                        c.janet_table_put(&c.janet_vm.threaded_abstracts, out.*, c.janet_wrap_false());
                    } else {
                        // The heap reference is already accounted for, so the
                        // channel's is released.
                        _ = c.janet_abstract_decref(ptr);
                    }
                }
                pushVector(c.Janet, &st.lookup, out.*);
                return data;
            },
            else => {},
        }
    }

    switch (lead) {
        lb_nil => {
            out.* = c.janet_wrap_nil();
            return data + 1;
        },
        lb_false => {
            out.* = c.janet_wrap_false();
            return data + 1;
        },
        lb_true => {
            out.* = c.janet_wrap_true();
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
            out.* = c.janet_wrap_number_safe(@bitCast(bytes));
            pushVector(c.Janet, &st.lookup, out.*);
            return data + 9;
        },
        lb_string, lb_symbol, lb_buffer, lb_keyword, lb_registry => {
            data += 1;
            const len = try readNat(st, &data);
            try eosAddr(st, @intFromPtr(data) -% 1 +% asSize(len));
            switch (lead) {
                lb_string => out.* = c.janet_wrap_string(c.janet_string(data, len)),
                lb_symbol => out.* = c.janet_wrap_symbol(c.janet_symbol(data, len)),
                lb_keyword => out.* = c.janet_wrap_keyword(c.janet_keyword(data, len)),
                lb_registry => {
                    if (st.reg != null) {
                        out.* = c.janet_table_get(st.reg, c.janet_symbolv(data, len));
                    } else {
                        out.* = c.janet_wrap_nil();
                    }
                },
                else => {
                    const buffer = c.janet_buffer(len);
                    buffer.*.count = len;
                    safe_memcpy(buffer.*.data, data, asSize(len));
                    out.* = c.janet_wrap_buffer(buffer);
                },
            }
            pushVector(c.Janet, &st.lookup, out.*);
            return data + asSize(len);
        },
        lb_fiber => {
            var fiber: [*c]c.JanetFiber = undefined;
            data = try unmarshalOneFiber(st, data + 1, &fiber, flags + 1);
            out.* = c.janet_wrap_fiber(fiber);
            return data;
        },
        lb_function => {
            data += 1;
            const len = try readNat(st, &data);
            if (len > 255) {
                return pp_format.panicf("invalid function - too many environments (%d)", .{len});
            }
            const func: [*c]c.JanetFunction = @ptrCast(@alignCast(c.janet_gcalloc(
                c.JANET_MEMORY_FUNCTION,
                @sizeOf(c.JanetFunction) + asSize(len) * @sizeOf([*c]c.JanetFuncEnv),
            )));
            func.*.def = null;
            var i: i32 = 0;
            while (i < len) : (i += 1) funcEnv(func, i).* = null;
            out.* = c.janet_wrap_function(func);
            pushVector(c.Janet, &st.lookup, out.*);
            var def: [*c]c.JanetFuncDef = undefined;
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
                    c.janet_array_weak(len)
                else
                    c.janet_array(len);
                array.*.count = len;
                out.* = c.janet_wrap_array(array);
                pushVector(c.Janet, &st.lookup, out.*);
                var i: i32 = 0;
                while (i < len) : (i += 1) {
                    data = try unmarshalOne(st, data, &array.*.data[@intCast(i)], flags + 1);
                }
            } else if (lead == lb_tuple) {
                const tup = c.janet_tuple_begin(len);
                const flag = try readInt(st, &data);
                // The cast avoids a left shift of a negative value.
                tupleHead(tup).gc.flags |= @bitCast(@as(u32, @bitCast(flag)) << 16);
                var i: i32 = 0;
                while (i < len) : (i += 1) {
                    data = try unmarshalOne(st, data, &tup[@intCast(i)], flags + 1);
                }
                out.* = c.janet_wrap_tuple(c.janet_tuple_end(tup));
                pushVector(c.Janet, &st.lookup, out.*);
            } else if (lead == lb_struct or lead == lb_struct_proto) {
                const struct_ = c.janet_struct_begin(len);
                if (lead == lb_struct_proto) {
                    var proto: c.Janet = undefined;
                    data = try unmarshalOne(st, data, &proto, flags + 1);
                    try assertType(proto, c.JANET_STRUCT);
                    structHead(struct_).proto = c.janet_unwrap_struct(proto);
                }
                var i: i32 = 0;
                while (i < len) : (i += 1) {
                    var key: c.Janet = undefined;
                    var value: c.Janet = undefined;
                    data = try unmarshalOne(st, data, &key, flags + 1);
                    data = try unmarshalOne(st, data, &value, flags + 1);
                    c.janet_struct_put(struct_, key, value);
                }
                out.* = c.janet_wrap_struct(c.janet_struct_end(struct_));
                pushVector(c.Janet, &st.lookup, out.*);
            } else if (lead == lb_reference) {
                if (len >= vectorCount(c.Janet, st.lookup)) {
                    return pp_format.panicf("invalid reference %d", .{len});
                }
                out.* = st.lookup[@intCast(len)];
            } else {
                const t = switch (lead) {
                    lb_table_weakk_proto, lb_table_weakk => c.janet_table_weakk(len),
                    lb_table_weakv_proto, lb_table_weakv => c.janet_table_weakv(len),
                    lb_table_weakkv_proto, lb_table_weakkv => c.janet_table_weakkv(len),
                    else => c.janet_table(len),
                };
                out.* = c.janet_wrap_table(t);
                pushVector(c.Janet, &st.lookup, out.*);
                switch (lead) {
                    lb_table_proto,
                    lb_table_weakk_proto,
                    lb_table_weakv_proto,
                    lb_table_weakkv_proto,
                    => {
                        var proto: c.Janet = undefined;
                        data = try unmarshalOne(st, data, &proto, flags + 1);
                        try assertType(proto, c.JANET_TABLE);
                        t.*.proto = c.janet_unwrap_table(proto);
                    },
                    else => {},
                }
                var i: i32 = 0;
                while (i < len) : (i += 1) {
                    var key: c.Janet = undefined;
                    var value: c.Janet = undefined;
                    data = try unmarshalOne(st, data, &key, flags + 1);
                    data = try unmarshalOne(st, data, &value, flags + 1);
                    c.janet_table_put(t, key, value);
                }
            }
            return data;
        },
        lb_unsafe_pointer => {
            try eos(st, data + @sizeOf(?*anyopaque));
            data += 1;
            if ((flags & c.JANET_MARSHAL_UNSAFE) == 0) {
                return pp_format.panicf(
                    "unsafe flag not given, will not unmarshal raw pointer at index %d",
                    .{indexOf(st, data)},
                );
            }
            var ptr: ?*anyopaque = undefined;
            @memcpy(@as([*]u8, @ptrCast(&ptr))[0..@sizeOf(?*anyopaque)], data[0..@sizeOf(?*anyopaque)]);
            data += @sizeOf(?*anyopaque);
            out.* = c.janet_wrap_pointer(ptr);
            pushVector(c.Janet, &st.lookup, out.*);
            return data;
        },
        lb_unsafe_cfunction => {
            try eos(st, data + @sizeOf(c.JanetCFunction));
            data += 1;
            if ((flags & c.JANET_MARSHAL_UNSAFE) == 0) {
                return pp_format.panicf(
                    "unsafe flag not given, will not unmarshal function pointer at index %d",
                    .{indexOf(st, data)},
                );
            }
            var cfn: c.JanetCFunction = undefined;
            @memcpy(
                @as([*]u8, @ptrCast(&cfn))[0..@sizeOf(c.JanetCFunction)],
                data[0..@sizeOf(c.JanetCFunction)],
            );
            data += @sizeOf(c.JanetCFunction);
            out.* = c.janet_wrap_cfunction(cfn);
            pushVector(c.Janet, &st.lookup, out.*);
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
    bytes: [*c]const u8,
    len: usize,
    flags: c_int,
    reg: [*c]c.JanetTable,
    next: [*c][*c]const u8,
) raise.Raising(c.Janet) {
    var st: UnmarshalState = .{
        .start = bytes,
        .end = bytes + len,
        .lookup_defs = null,
        .lookup_envs = null,
        .lookup = null,
        .reg = reg,
    };
    var out: c.Janet = undefined;
    const nextbytes = try unmarshalOne(&st, bytes, &out, flags);
    if (next != null) next.* = nextbytes;
    freeVector(*c.JanetFuncDef, st.lookup_defs);
    freeVector(*c.JanetFuncEnv, st.lookup_envs);
    freeVector(c.Janet, st.lookup);
    return out;
}

const unmarshalFace = raise.panicking(unmarshal).face;

comptime {
    @export(&unmarshalFace, .{ .name = "janet_unmarshal" });
}

// ==========================================================================
// The cfunction surface
// ==========================================================================

fn cfunEnvLookup(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const env = try arglayer.getTable(argv, 0);
    return c.janet_wrap_table(janet_env_lookup(env));
}

fn cfunMarshal(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 4);
    var rreg: [*c]c.JanetTable = null;
    var flags: c_int = 0;
    if (argc > 1) rreg = try arglayer.getTable(argv, 1);
    const buffer = if (argc > 2) try arglayer.getBuffer(argv, 2) else c.janet_buffer(10);
    if (argc > 3 and c.janet_truthy(argv[3]) != 0) flags |= c.JANET_MARSHAL_NO_CYCLES;
    try marshal(buffer, argv[0], rreg, flags);
    return c.janet_wrap_buffer(buffer);
}

fn cfunUnmarshal(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_UNMARSHAL);
    try arglayer.arity(argc, 1, 2);
    const view = try arglayer.getBytes(argv, 0);
    const reg: [*c]c.JanetTable = if (argc > 1) try arglayer.getTable(argv, 1) else null;
    return unmarshal(view.bytes, asSize(view.len), 0, reg, null);
}

export fn janet_lib_marsh(env: *c.JanetTable) callconv(.c) void {
    const entries = [_]corefn.Entry{
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
        corefn.end,
    };
    corefn.install(env, &entries);
}
