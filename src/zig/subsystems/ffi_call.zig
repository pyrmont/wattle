//! `ffi.c`'s calling machinery: building a signature, placing the arguments
//! and making the call, the callback trampolines, and the JIT's executable
//! pages. Part 16's top layer, and the part Phase 6 recorded as "assembly by
//! nature".
//!
//! ## How the stack arguments are placed, now that there is no `alloca`
//!
//! `SPIKE-16.md` is the long answer. The short one: C writes the stack-class
//! arguments into an `alloca` block and calls a function pointer declared with
//! the *register* arguments only, relying on the block sitting exactly where
//! the callee will look. `janet_ffi_win64` makes the coupling explicit -- it
//! shifts the block down two words and admits in a comment to writing "into 16
//! bytes of unallocated stack memory".
//!
//! Zig has no `alloca`, so the placement comes from the ABI's own rules
//! instead: the stack words are declared as ordinary trailing parameters and
//! the compiler puts them where they go. `@Fn` builds the type at comptime,
//! `@call` fills it. Three things follow.
//!
//!  - **A rung ladder.** `@Fn` needs a comptime parameter count and a
//!    signature's does not exist until runtime, so the outgoing word count is
//!    rounded up to a power of two and every rung is instantiated. Passing
//!    more words than the callee reads is the caller's to push and the
//!    caller's to clean up, so the rounding is invisible. Each convention has
//!    its own ladder, sized to what it can actually generate.
//!  - **A frame that outlives the call.** `JANET_WIN64_STACK_REF` and
//!    `JANET_AAPCS64_GENERAL_REF` store a *pointer* to a payload the caller
//!    wrote, and the outgoing area has no address until the call is under way.
//!    So the frame is ordinary scratch with the offsets the allocators already
//!    compute, the references point into it, and only its outgoing prefix
//!    becomes arguments. The callee gets a copy of that prefix holding
//!    pointers into the live original, which is what `alloca` gave C for free.
//!    `win64`'s `- stack_shift * 8` adjustment dies with the `memmove` it was
//!    compensating for.
//!  - **A ceiling.** 1024 words, which is 8KB of outgoing arguments, because a
//!    rung costs superlinearly to compile and 32KB costs 21 seconds. Only
//!    SysV64 can reach it, and only with a single struct passed *by value*;
//!    Win64 and AAPCS64 pass anything large by reference, so with 32 arguments
//!    neither can generate more than about 128 words. `ffi/signature` reports
//!    it, so it is found once at description time rather than on every call.
//!
//! ## The uninitialized register arrays are not reproduced
//!
//! `FOUND.md` records that C stores an argument narrower than a register into
//! an uninitialized array, so every `:s8`, `:u8`, `:s16` and `:u16` argument
//! reaches its callee with stack residue in the high bits. Reading
//! uninitialized memory is undefined rather than merely wrong, so this phase's
//! rule is to record it and get it right -- the same footing as Part 8's `%x`
//! entry. Every bank and the frame are zeroed here.
//!
//! ## Why this file is jump-transparent
//!
//! Marshalling raises, and so does the argument layer behind `-Dargs-core`. A
//! raise between `janet_smalloc` and `janet_sfree` leaks the frame until the
//! next collection, which is what scratch memory is for and what `ffi.c` did
//! with its own classification scratch. No `defer` may appear until Part 17.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const raise = @import("raise");
const stdio = @import("stdio.zig");
const io_core = @import("io_core.zig");
const pp_format = @import("pp_format.zig");
const types = @import("ffi_types.zig");
const marshal = @import("ffi_marshal.zig");
const arglayer = @import("arglayer.zig");
const containers = @import("containers.zig");
const lifecycle = @import("lifecycle.zig");
const vm_entry = @import("vm_entry.zig");
const abstract_type = @import("abstract_type.zig");

const c = types.c;
const Type = types.Type;
const Struct = types.Struct;
const Mapping = types.Mapping;
const Signature = types.Signature;
const Spec = types.Spec;
const Cc = types.Cc;
const Prim = types.Prim;

const has_ev = @hasDecl(c, "JANET_EV");
const has_jit = @hasDecl(c, "JANET_FFI_JIT");

// ==========================================================================
// The flat forms, which are `-Dffi-classify`'s vocabulary
// ==========================================================================

/// `JanetFFITypeNode`: one node of a type serialized in pre-order.
const TypeNode = extern struct {
    size: u64,
    struct_size: u32,
    prim: u32,
    field_count: u32,
    is_aligned: u32,
    offset: u32,
    array_count: i32,
};

/// `JanetFFIArgSlot`: one argument as a convention sees it.
const ArgSlot = extern struct {
    size: u64,
    prim: u32,
    spec: u32,
    alignment: u32,
    offset: u32,
    offset2: u32,
};

/// `JanetFFIAllocResult`.
///
/// `arg_stack_count` is Part 16's addition and is appended rather than placed
/// where it belongs, so that the field order the two `-Dffi-classify` arms
/// already agree on is left alone. It is the *outgoing* part of the frame in
/// words, where `stack_count` is the whole frame including the by-reference
/// payloads that follow it -- a distinction C never had to draw, because one
/// `alloca` served both purposes and neither half was ever passed as an
/// argument.
const AllocResult = extern struct {
    stack_count: u32,
    variant: u32,
    error_kind: u32,
    error_arg: i32,
    arg_stack_count: u32,
};

const alloc_ok: u32 = 0;
const alloc_unsupported_spec: u32 = 1;
const alloc_return_too_big: u32 = 2;

extern fn janet_ffi_sysv64_classify(nodes: [*]const TypeNode, count: u32) callconv(.c) u32;
extern fn janet_ffi_aapcs64_classify(nodes: [*]const TypeNode, count: u32) callconv(.c) u32;
extern fn janet_ffi_win64_alloc(result: *AllocResult, ret: *ArgSlot, args: [*]ArgSlot, arg_count: u32) callconv(.c) void;
extern fn janet_ffi_sysv64_alloc(result: *AllocResult, ret: *ArgSlot, args: [*]ArgSlot, arg_count: u32) callconv(.c) void;
extern fn janet_ffi_aapcs64_alloc(
    result: *AllocResult,
    ret: *ArgSlot,
    args: [*]ArgSlot,
    arg_count: u32,
    apple_abi: c_int,
    max_ret_size: u64,
) callconv(.c) void;

// ==========================================================================
// The return shapes the variant tables name
// ==========================================================================

const Sysv64IntReturn = extern struct { x: u64, y: u64 };
const Sysv64SseReturn = extern struct { x: f64, y: f64 };
const Sysv64IntSseReturn = extern struct { x: u64, y: f64 };
const Sysv64SseIntReturn = extern struct { y: f64, x: u64 };

const Aapcs64ReturnGeneral = extern struct { a: u64, b: u64 };
const Aapcs64ReturnSse = extern struct { a: f64, b: f64, c: f64, d: f64 };
/// The workaround for passing a return-value pointer through `x8`, which is
/// what limits a struct return to 128 bytes.
const Aapcs64ReturnPointer = extern struct { w: [16]u64 };

/// The widest of the three, which is the buffer a return is read out of.
const aapcs64_return_size = @sizeOf(Aapcs64ReturnPointer);

// ==========================================================================
// The reified call
// ==========================================================================

/// `fn (regs..., u64 x nstack) callconv(.c) Ret`, where `regs` names the
/// register parameters in order.
fn VariantType(comptime regs: []const type, comptime nstack: usize, comptime Ret: type) type {
    @setEvalBranchQuota(200_000);
    const n = regs.len + nstack;
    var params: [n]type = undefined;
    for (regs, 0..) |t, i| params[i] = t;
    for (0..nstack) |i| params[regs.len + i] = u64;
    const frozen = params;
    const attrs = [_]std.builtin.Type.Fn.Param.Attributes{.{}} ** n;
    return @Fn(&frozen, &attrs, Ret, .{ .@"callconv" = .c });
}

/// The two-bank shape SysV64 and AAPCS64 share: `ngen` general registers, then
/// `nfp` floating ones, then the stack words.
fn bankedRegs(comptime ngen: usize, comptime nfp: usize) []const type {
    comptime {
        var regs: [ngen + nfp]type = undefined;
        for (0..ngen) |i| regs[i] = u64;
        for (0..nfp) |i| regs[ngen + i] = f64;
        const frozen = regs;
        return &frozen;
    }
}

fn invokeBanked(
    comptime ngen: usize,
    comptime nfp: usize,
    comptime nstack: usize,
    comptime Ret: type,
    ptr: *const anyopaque,
    gen: [ngen]u64,
    fp: [nfp]f64,
    stack: [*]const u64,
) Ret {
    @setEvalBranchQuota(200_000);
    const F = VariantType(bankedRegs(ngen, nfp), nstack, Ret);
    const f: *const F = @ptrCast(@alignCast(ptr));
    var args: std.meta.ArgsTuple(F) = undefined;
    inline for (0..ngen) |i| args[i] = gen[i];
    inline for (0..nfp) |i| args[ngen + i] = fp[i];
    inline for (0..nstack) |i| args[ngen + nfp + i] = stack[i];
    return @call(.auto, f, args);
}

/// Win64's four register slots, each of which is an integer or a vector
/// register according to one bit of the variant. `mask` bit `3 - i` selects
/// slot `i`, which is how `janet_ffi_win64_alloc` accumulates it.
fn win64Regs(comptime mask: u4) []const type {
    comptime {
        var regs: [4]type = undefined;
        for (0..4) |i| {
            const is_float = (mask >> @intCast(3 - i)) & 1 != 0;
            regs[i] = if (is_float) f64 else u64;
        }
        const frozen = regs;
        return &frozen;
    }
}

fn invokeWin64(
    comptime mask: u4,
    comptime nstack: usize,
    comptime Ret: type,
    ptr: *const anyopaque,
    regs: [4]u64,
    stack: [*]const u64,
) Ret {
    @setEvalBranchQuota(200_000);
    const F = VariantType(win64Regs(mask), nstack, Ret);
    const f: *const F = @ptrCast(@alignCast(ptr));
    var args: std.meta.ArgsTuple(F) = undefined;
    inline for (0..4) |i| {
        const is_float = (mask >> @intCast(3 - i)) & 1 != 0;
        args[i] = if (is_float) @as(f64, @bitCast(regs[i])) else regs[i];
    }
    inline for (0..nstack) |i| args[4 + i] = stack[i];
    return @call(.auto, f, args);
}

/// The ladders. Each is sized to what its convention can generate: SysV64
/// passes large aggregates by value on the stack and is the only one that can
/// reach a ceiling, while Win64 and AAPCS64 pass anything large by reference
/// and are bounded by `JANET_FFI_MAX_ARGS`.
const sysv64_ladder = [_]usize{ 0, 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024 };
const win64_ladder = [_]usize{ 0, 1, 2, 4, 8, 16, 32, 64 };
const aapcs64_ladder = [_]usize{ 0, 1, 2, 4, 8, 16, 32, 64, 128 };

fn ladderTop(comptime ladder: []const usize) usize {
    return ladder[ladder.len - 1];
}

// ==========================================================================
// The frame
// ==========================================================================

/// The scratch a call places its stack arguments and by-reference payloads in.
///
/// Scratch memory rather than a fixed buffer, because the size is a property
/// of the signature. It is freed at the next collection if a raise skips the
/// release, which is what `janet_smalloc` is for.
/// What an empty frame points at. Never read and never written: a frame is
/// empty exactly when no argument has anywhere to go in it and no outgoing
/// word is passed, so nothing indexes it. It exists so that `base` is an
/// address rather than a null, which keeps every other line of this structure
/// free of a special case.
const no_frame: [2]u64 align(16) = .{ 0, 0 };

/// How much frame a call gets on the caller's own stack before it has to ask
/// the scratch allocator. Sixty-four words covers every signature anyone
/// writes: on AAPCS64 and Win64 nothing larger than a pointer reaches the
/// outgoing area, and on SysV64 it takes a by-value aggregate to exceed it.
const inline_frame_bytes = 512;

const Frame = struct {
    base: [*]u8,
    bytes: usize,
    heap: bool,

    /// C reached for `alloca`, which costs nothing and cannot fail. The two
    /// cases below are what it takes to say the same thing without one.
    ///
    /// A call whose arguments all fit in registers -- which is most calls --
    /// needs no frame at all, and allocating one for it was four operations
    /// `alloca(0)` did not perform: a `janet_malloc`, a push onto the scratch
    /// table, and later a *linear scan* of that table to find the block again.
    /// Measured at forty percent of the cheapest call this subsystem makes.
    ///
    /// A call that does need a frame almost always needs a small one, and the
    /// caller has already reserved `inline_frame_bytes` of its own stack for
    /// exactly that. Scratch is for the signature nobody writes.
    fn init(buf: *align(16) [inline_frame_bytes]u8, bytes: usize) Frame {
        if (bytes == 0) return .{ .base = @ptrCast(@constCast(&no_frame)), .bytes = 0, .heap = false };
        if (bytes <= inline_frame_bytes) {
            @memset(buf[0..bytes], 0);
            return .{ .base = buf, .bytes = bytes, .heap = false };
        }
        const mem: [*]u8 = @ptrCast(c.janet_smalloc(bytes).?);
        @memset(mem[0..bytes], 0);
        return .{ .base = mem, .bytes = bytes, .heap = true };
    }

    fn release(frame: Frame) void {
        if (frame.heap) c.janet_sfree(frame.base);
    }

    fn at(frame: Frame, offset: usize) [*]u8 {
        return frame.base + offset;
    }

    fn words(frame: Frame) [*]const u64 {
        return @ptrCast(@alignCast(frame.base));
    }
};

// ==========================================================================
// Serializing a type for the classifiers
// ==========================================================================

/// `ffi_type_node_count`.
fn nodeCount(ty: Type) u32 {
    var count: u32 = 1;
    if (ty.prim == .@"struct") {
        const st = ty.st.?;
        const members = Struct.fields(st);
        var i: u32 = 0;
        while (i < st.field_count) : (i += 1) count += nodeCount(members[i].type);
    }
    return count;
}

/// `ffi_serialize_type`: `ty` and everything under it, in pre-order.
fn serializeType(nodes: [*]TypeNode, at: u32, ty: Type, offset: u32) u32 {
    const node = &nodes[at];
    node.size = types.typeSize(ty);
    node.prim = @intFromEnum(ty.prim);
    node.offset = offset;
    node.array_count = ty.array_count;
    if (ty.prim != .@"struct") {
        node.struct_size = 0;
        node.field_count = 0;
        node.is_aligned = 1;
        return at + 1;
    }
    const st = ty.st.?;
    node.struct_size = st.size;
    node.field_count = st.field_count;
    node.is_aligned = st.is_aligned;
    const members = Struct.fields(st);
    var next = at + 1;
    var i: u32 = 0;
    while (i < st.field_count) : (i += 1) {
        next = serializeType(nodes, next, members[i].type, @intCast(members[i].offset));
    }
    return next;
}

/// `ffi_classify`. The type is flattened into scratch first, because a
/// classifier is a pure decision and must not see a pointer into a collected
/// abstract.
/// How many nodes a type is flattened into before the classifier needs scratch.
/// A scalar is one node and a struct is one per field at every depth, so this
/// is a struct of thirty-one fields or a nest of the same total width.
const inline_nodes = 32;

fn classify(cc: Cc, ty: Type) Spec {
    const count = nodeCount(ty);
    // `ffi/signature` classifies every argument and the return, so this is the
    // one allocation on that path and it is paid per argument.
    var node_buf: [inline_nodes]TypeNode = undefined;
    const heap = count > inline_nodes;
    const nodes: [*]TypeNode = if (heap)
        @ptrCast(@alignCast(c.janet_smalloc(count * @sizeOf(TypeNode)).?))
    else
        &node_buf;
    _ = serializeType(nodes, 0, ty, 0);
    const spec = if (cc == .aapcs64)
        janet_ffi_aapcs64_classify(nodes, count)
    else
        janet_ffi_sysv64_classify(nodes, count);
    if (heap) c.janet_sfree(nodes);
    return @enumFromInt(spec);
}

/// `ffi_slot_of`.
fn slotOf(ty: Type, spec: Spec) ArgSlot {
    return .{
        .size = types.typeSize(ty),
        .prim = @intFromEnum(ty.prim),
        .spec = @intFromEnum(spec),
        .alignment = @intCast(types.typeAlign(ty)),
        .offset = 0,
        .offset2 = 0,
    };
}

/// `ffi_check_alloc`: a convention's report of a failure, back into the panic
/// the C implementation raised in the same position.
fn checkAlloc(result: *const AllocResult) raise.Error!void {
    switch (result.error_kind) {
        alloc_ok => return,
        alloc_return_too_big => return raise.panic("return value bigger than supported"),
        else => return raise.panic("nyi"),
    }
}

/// The ceiling check, which is Part 16's own and has no C original: past the
/// top rung there is no function type to call through.
fn checkStackCeiling(words: u32, comptime ladder: []const usize) raise.Error!void {
    if (words <= comptime ladderTop(ladder)) return;
    return pp_format.panicf(
        "signature needs %d words of stack arguments, more than the %d this build can place",
        .{ @as(i32, @intCast(words)), @as(i32, @intCast(comptime ladderTop(ladder))) },
    );
}

/// `ffi_apply_slots`: the placements travel back, and the types never left.
fn applySlots(
    sig_ret: *Mapping,
    mappings: [*]Mapping,
    arg_count: u32,
    ret_slot: *const ArgSlot,
    slots: [*]const ArgSlot,
) void {
    sig_ret.spec = @enumFromInt(ret_slot.spec);
    var i: u32 = 0;
    while (i < arg_count) : (i += 1) {
        mappings[i].spec = @enumFromInt(slots[i].spec);
        mappings[i].offset = slots[i].offset;
        mappings[i].offset2 = slots[i].offset2;
    }
}

// ==========================================================================
// ffi/signature
// ==========================================================================

pub fn signature(argc: i32, argv: [*c]const c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 2, -1);
    const arg_count: u32 = @intCast(argc - 2);
    const cc = try types.decodeCc(try arglayer.getKeyword(argv, 0));
    const ret_type = try types.decodeType(argv[1]);

    var ret: Mapping = .{
        .type = ret_type,
        .spec = .sysv64_no_class,
        .offset = 0,
        .offset2 = 0,
    };
    var mappings: [types.max_args]Mapping = undefined;
    for (&mappings) |*m| m.* = Mapping.empty();

    var ret_slot: ArgSlot = undefined;
    var slots: [types.max_args]ArgSlot = undefined;
    var alloc: AllocResult = undefined;
    var variant: u32 = 0;
    var stack_count: u32 = 0;
    var alloc_stack_words: u32 = 0;

    switch (cc) {
        .none => {
            // Unsupported here means "cannot be called", not "cannot be
            // described": the signature is still checked so that the failure
            // arrives at the call.
            var i: u32 = 0;
            while (i < arg_count) : (i += 1) _ = try types.decodeType(argv[i + 2]);
        },
        .win64 => {
            ret_slot = slotOf(ret.type, .win64_register);
            var i: u32 = 0;
            while (i < arg_count) : (i += 1) {
                mappings[i].type = try types.decodeType(argv[i + 2]);
                slots[i] = slotOf(mappings[i].type, .win64_register);
            }
            janet_ffi_win64_alloc(&alloc, &ret_slot, &slots, arg_count);
            try checkAlloc(&alloc);
            try checkStackCeiling(alloc.arg_stack_count, &win64_ladder);
            applySlots(&ret, &mappings, arg_count, &ret_slot, &slots);
            variant = alloc.variant;
            stack_count = alloc.stack_count;
            alloc_stack_words = alloc.arg_stack_count;
        },
        .sysv64 => {
            ret_slot = slotOf(ret.type, classify(cc, ret.type));
            var i: u32 = 0;
            while (i < arg_count) : (i += 1) {
                mappings[i].type = try types.decodeType(argv[i + 2]);
                const spec = classify(cc, mappings[i].type);
                // The void check stays in this loop so that it still fires
                // from the argument that caused it.
                if (spec == .sysv64_no_class) return raise.panic("unexpected void parameter");
                slots[i] = slotOf(mappings[i].type, spec);
            }
            janet_ffi_sysv64_alloc(&alloc, &ret_slot, &slots, arg_count);
            try checkAlloc(&alloc);
            try checkStackCeiling(alloc.arg_stack_count, &sysv64_ladder);
            applySlots(&ret, &mappings, arg_count, &ret_slot, &slots);
            variant = alloc.variant;
            stack_count = alloc.stack_count;
            alloc_stack_words = alloc.arg_stack_count;
        },
        .aapcs64 => {
            ret_slot = slotOf(ret_type, classify(cc, ret_type));
            // The allocator reports an oversized return as well, but the
            // original raised it before any argument was decoded, and this
            // keeps that order.
            if (ret_slot.spec == @intFromEnum(Spec.aapcs64_general_ref) and
                ret_slot.size > aapcs64_return_size)
            {
                return raise.panic("return value bigger than supported");
            }
            var i: u32 = 0;
            while (i < arg_count) : (i += 1) {
                mappings[i].type = try types.decodeType(argv[i + 2]);
                slots[i] = slotOf(mappings[i].type, classify(cc, mappings[i].type));
            }
            janet_ffi_aapcs64_alloc(
                &alloc,
                &ret_slot,
                &slots,
                arg_count,
                @intFromBool(builtin.os.tag.isDarwin()),
                aapcs64_return_size,
            );
            try checkAlloc(&alloc);
            try checkStackCeiling(alloc.arg_stack_count, &aapcs64_ladder);
            applySlots(&ret, &mappings, arg_count, &ret_slot, &slots);
            variant = alloc.variant;
            stack_count = alloc.stack_count;
            alloc_stack_words = alloc.arg_stack_count;
        },
    }

    const abst: *Signature = @ptrCast(@alignCast(c.janet_abstract(abstract_type.stored(&types.signature_at), @sizeOf(Signature))));
    abst.frame_size = 0;
    abst.cc = cc;
    abst.ret = ret;
    abst.arg_count = arg_count;
    abst.variant = variant;
    abst.stack_count = stack_count;
    abst.arg_stack_words = alloc_stack_words;
    abst.args = mappings;
    return c.janet_wrap_abstract(abst);
}

// ==========================================================================
// The calls
// ==========================================================================

/// Copy a convention's returned value into the buffer `readOne` reads from.
///
/// The quota is raised because Win64 instantiates this once per return variant
/// per rung -- thirty-two by eight -- and the default thousand backwards
/// branches is spent long before the last of them. The host never noticed:
/// it takes the AAPCS64 path, which has three variants.
inline fn storeReturn(buf: [*]u8, value: anytype) void {
    @setEvalBranchQuota(200_000);
    @memcpy(buf[0..@sizeOf(@TypeOf(value))], std.mem.asBytes(&value));
}

/// The return buffer. Every convention's variants write at offset zero, which
/// is what the union in each of the three C originals arranged.
const ReturnBuffer = [aapcs64_return_size]u8;

/// A return that comes back through a caller-supplied pointer rather than in
/// registers. The scratch is separate from the frame because its size is the
/// return type's rather than the signature's.
fn returnScratch(ty: Type) [*]u8 {
    const size = types.typeSize(ty);
    const mem: [*]u8 = @ptrCast(c.janet_smalloc(if (size == 0) 1 else size).?);
    @memset(mem[0..if (size == 0) 1 else size], 0);
    return mem;
}

/// SysV AMD64. Six general registers, eight vector registers, and four
/// variants that differ only in how the return value comes back.
fn callSysv64(sig: *Signature, function_pointer: *const anyopaque, argv: [*c]const c.Janet) raise.Raising(c.Janet) {
    var gen: [6]u64 = @splat(0);
    var fp: [8]u64 = @splat(0);
    var pair: [2]u64 = @splat(0);
    var ret_buf: ReturnBuffer align(16) = @splat(0);

    var ret_mem: [*]u8 = &ret_buf;
    if (sig.ret.spec == .sysv64_memory) {
        ret_mem = returnScratch(sig.ret.type);
        gen[0] = @intFromPtr(ret_mem);
    }

    var frame_buf: [inline_frame_bytes]u8 align(16) = undefined;
    const frame = Frame.init(&frame_buf, @as(usize, sig.stack_count) * @sizeOf(u64));

    var i: u32 = 0;
    while (i < sig.arg_count) : (i += 1) {
        const n: i32 = @intCast(i + 2);
        const arg = sig.args[i];
        switch (arg.spec) {
            .sysv64_integer => try marshal.writeOne(&gen[arg.offset], argv, n, arg.type, types.max_recur),
            .sysv64_sse => try marshal.writeOne(&fp[arg.offset], argv, n, arg.type, types.max_recur),
            .sysv64_memory => try marshal.writeOne(
                frame.at(@as(usize, arg.offset) * @sizeOf(u64)),
                argv,
                n,
                arg.type,
                types.max_recur,
            ),
            // A pair is written whole and then split between the two banks the
            // classifier named. Written out rather than selected by pointer,
            // because the two banks are different lengths and a `*[8]u64` over
            // the six-entry one would be a lie even where nothing indexes past
            // its end.
            .sysv64_pair_intint => {
                try marshal.writeOne(&pair, argv, n, arg.type, types.max_recur);
                gen[arg.offset] = pair[0];
                gen[arg.offset2] = pair[1];
            },
            .sysv64_pair_intsse => {
                try marshal.writeOne(&pair, argv, n, arg.type, types.max_recur);
                gen[arg.offset] = pair[0];
                fp[arg.offset2] = pair[1];
            },
            .sysv64_pair_sseint => {
                try marshal.writeOne(&pair, argv, n, arg.type, types.max_recur);
                fp[arg.offset] = pair[0];
                gen[arg.offset2] = pair[1];
            },
            .sysv64_pair_ssesse => {
                try marshal.writeOne(&pair, argv, n, arg.type, types.max_recur);
                fp[arg.offset] = pair[0];
                fp[arg.offset2] = pair[1];
            },
            else => return raise.panic("nyi"),
        }
    }

    const fps: [8]f64 = @bitCast(fp);
    const stack = frame.words();
    switch (sig.variant) {
        inline 0...3 => |v| {
            const R = switch (v) {
                0 => Sysv64IntReturn,
                1 => Sysv64SseReturn,
                2 => Sysv64IntSseReturn,
                else => Sysv64SseIntReturn,
            };
            inline for (sysv64_ladder) |rung| {
                if (sig.arg_stack_words <= rung) {
                    storeReturn(&ret_buf, invokeBanked(6, 8, rung, R, function_pointer, gen, fps, stack));
                    break;
                }
            }
        },
        // `switch (signature->variant)` in C falls through to no call at all,
        // and then reads the return buffer anyway.
        else => {},
    }

    frame.release();
    return marshal.readOne(ret_mem, sig.ret.type, types.max_recur);
}

/// Win64. Four register slots that are integer or vector according to the
/// variant, one register for the return, and everything wider than a word
/// passed by reference.
fn callWin64(sig: *Signature, function_pointer: *const anyopaque, argv: [*c]const c.Janet) raise.Raising(c.Janet) {
    var regs: [4]u64 = @splat(0);
    var ret_buf: ReturnBuffer align(16) = @splat(0);

    var ret_mem: [*]u8 = &ret_buf;
    if (sig.ret.spec == .win64_register_ref) {
        ret_mem = returnScratch(sig.ret.type);
        regs[0] = @intFromPtr(ret_mem);
    }

    var frame_buf: [inline_frame_bytes]u8 align(16) = undefined;
    const frame = Frame.init(&frame_buf, @as(usize, sig.stack_count) * @sizeOf(u64));

    var i: u32 = 0;
    while (i < sig.arg_count) : (i += 1) {
        const n: i32 = @intCast(i + 2);
        const arg = sig.args[i];
        switch (arg.spec) {
            .win64_stack => try marshal.writeOne(
                frame.at(@as(usize, arg.offset) * @sizeOf(u64)),
                argv,
                n,
                arg.type,
                types.max_recur,
            ),
            // The payload goes in the frame and the slot gets its address.
            // C subtracted two words here to undo a `memmove` this port does
            // not make.
            .win64_stack_ref => {
                const payload = frame.at(@as(usize, arg.offset2) * @sizeOf(u64));
                try marshal.writeOne(payload, argv, n, arg.type, types.max_recur);
                const slot: *align(1) u64 = @ptrCast(frame.at(@as(usize, arg.offset) * @sizeOf(u64)));
                slot.* = @intFromPtr(payload);
            },
            .win64_register_ref => {
                const payload = frame.at(@as(usize, arg.offset2) * @sizeOf(u64));
                try marshal.writeOne(payload, argv, n, arg.type, types.max_recur);
                regs[arg.offset] = @intFromPtr(payload);
            },
            else => try marshal.writeOne(&regs[arg.offset], argv, n, arg.type, types.max_recur),
        }
    }

    const stack = frame.words();
    // The variant's low four bits say which register slots are vector
    // registers and bit four says the return is a double.
    switch (sig.variant) {
        inline 0...31 => |v| {
            const mask: u4 = @truncate(v);
            const R = if (v >= 16) f64 else u64;
            inline for (win64_ladder) |rung| {
                if (sig.arg_stack_words <= rung) {
                    storeReturn(&ret_buf, invokeWin64(mask, rung, R, function_pointer, regs, stack));
                    break;
                }
            }
        },
        else => return pp_format.panicf("unknown variant %d", .{@as(i32, @bitCast(sig.variant))}),
    }

    frame.release();
    return marshal.readOne(ret_mem, sig.ret.type, types.max_recur);
}

/// AAPCS64. Eight general registers, eight vector registers, a stack measured
/// in bytes rather than words, and three return variants.
fn callAapcs64(sig: *Signature, function_pointer: *const anyopaque, argv: [*c]const c.Janet) raise.Raising(c.Janet) {
    var gen: [8]u64 = @splat(0);
    var fp: [8]u64 = @splat(0);
    var ret_buf: ReturnBuffer align(16) = @splat(0);
    const ret_mem: [*]u8 = &ret_buf;

    var frame_buf: [inline_frame_bytes]u8 align(16) = undefined;
    const frame = Frame.init(&frame_buf, aapcs64FrameBytes(sig));

    var i: u32 = 0;
    while (i < sig.arg_count) : (i += 1) {
        const n: i32 = @intCast(i + 2);
        const arg = sig.args[i];
        const to: [*]u8 = switch (arg.spec) {
            .aapcs64_general => @ptrCast(&gen[arg.offset]),
            .aapcs64_sse => @ptrCast(&fp[arg.offset]),
            .aapcs64_general_ref => blk: {
                const payload = frame.at(arg.offset2);
                gen[arg.offset] = @intFromPtr(payload);
                break :blk payload;
            },
            .aapcs64_stack => frame.at(arg.offset),
            .aapcs64_stack_ref => blk: {
                const payload = frame.at(arg.offset2);
                // `(uint64_t *) stack + arg.offset` in C, where `arg.offset`
                // is already a byte offset -- see `FOUND.md`. Reproduced, with
                // the frame grown to keep the write inside it.
                const slot: *align(1) u64 = @ptrCast(frame.at(@as(usize, arg.offset) * @sizeOf(u64)));
                slot.* = @intFromPtr(payload);
                break :blk payload;
            },
            else => return raise.panic("nyi"),
        };
        try marshal.writeOne(to, argv, n, arg.type, types.max_recur);
    }

    const fps: [8]f64 = @bitCast(fp);
    const stack = frame.words();
    switch (sig.variant) {
        inline 0...2 => |v| {
            const R = switch (v) {
                0 => Aapcs64ReturnGeneral,
                1 => Aapcs64ReturnSse,
                else => Aapcs64ReturnPointer,
            };
            inline for (aapcs64_ladder) |rung| {
                if (sig.arg_stack_words <= rung) {
                    storeReturn(&ret_buf, invokeBanked(8, 8, rung, R, function_pointer, gen, fps, stack));
                    break;
                }
            }
        },
        else => {},
    }

    frame.release();
    return marshal.readOne(ret_mem, sig.ret.type, types.max_recur);
}

/// How many bytes AAPCS64's frame needs.
///
/// `stack_count` is the answer C allocated, and it is not always enough: the
/// `JANET_AAPCS64_STACK_REF` arm indexes a byte offset as though it were a
/// word index, so the pointer it stores can land up to eight times further out
/// than the allocator planned for. The defect is reproduced rather than
/// repaired, which means the frame has to cover where it writes -- in C that
/// write went past the `alloca` block and into the caller's own frame, which
/// is undefined and so is not something a port has to imitate exactly.
fn aapcs64FrameBytes(sig: *Signature) usize {
    var bytes: usize = sig.stack_count;
    var i: u32 = 0;
    while (i < sig.arg_count) : (i += 1) {
        if (sig.args[i].spec != .aapcs64_stack_ref) continue;
        const end = (@as(usize, sig.args[i].offset) + 1) * @sizeOf(u64);
        if (end > bytes) bytes = end;
    }
    return bytes;
}

// ==========================================================================
// The callback trampolines
// ==========================================================================

/// `janet_ffi_trampoline`.
///
/// One signature, in each calling convention, rather than runtime code
/// generation -- which is prohibited on many platforms, often buggy, and
/// generally complicated. Every callback eventually arrives here.
export fn janet_ffi_trampoline(ctx: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
    if (userdata == null) {
        // `janet_eprintf` is a variadic macro and does not survive
        // translation; `io.c`'s `stdio.err` is how a Zig source names
        // the stream it defaults to.
        raise.reported(pp_format.dynprintf("err", @ptrCast(@alignCast(stdio.err())), "no userdata found for janet callback", .{}));
        return;
    }
    var context = c.janet_wrap_pointer(ctx);
    const fun: *c.JanetFunction = @ptrCast(@alignCast(userdata));
    _ = raise.reported(vm_entry.callImpl(fun, 1, &context));
}


/// The three exist so that each convention hands out a pointer of its own,
/// which is the only thing that distinguishes them.
fn sysv64Callback(ctx: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
    janet_ffi_trampoline(ctx, userdata);
}

fn win64Callback(ctx: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
    janet_ffi_trampoline(ctx, userdata);
}

fn aapcs64Callback(ctx: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
    janet_ffi_trampoline(ctx, userdata);
}

pub fn trampoline(argc: i32, argv: [*c]const c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 0, 1);
    var cc = types.default_cc;
    if (argc >= 1) cc = try types.decodeCc(try arglayer.getKeyword(argv, 0));
    return switch (cc) {
        .win64 => if (types.win64_enabled)
            c.janet_wrap_pointer(@ptrCast(@constCast(&win64Callback)))
        else
            raise.panic("calling convention not supported"),
        .sysv64 => if (types.sysv64_enabled)
            c.janet_wrap_pointer(@ptrCast(@constCast(&sysv64Callback)))
        else
            raise.panic("calling convention not supported"),
        .aapcs64 => if (types.aapcs64_enabled)
            c.janet_wrap_pointer(@ptrCast(@constCast(&aapcs64Callback)))
        else
            raise.panic("calling convention not supported"),
        .none => raise.panic("calling convention not supported"),
    };
}

// ==========================================================================
// The JIT
// ==========================================================================

const JittedFn = extern struct {
    function_pointer: ?*anyopaque,
    size: usize,
};

extern fn VirtualAlloc(addr: ?*anyopaque, size: usize, alloc_type: u32, protect: u32) callconv(.c) ?*anyopaque;
extern fn VirtualProtect(addr: *anyopaque, size: usize, protect: u32, old: *u32) callconv(.c) c_int;
extern fn VirtualFree(addr: *anyopaque, size: usize, free_type: u32) callconv(.c) c_int;

const MEM_COMMIT: u32 = 0x1000;
const MEM_RESERVE: u32 = 0x2000;
const MEM_RELEASE: u32 = 0x8000;
const PAGE_READWRITE: u32 = 0x04;
const PAGE_EXECUTE_READ: u32 = 0x20;

fn jitfnGc(p: ?*anyopaque, s: usize) callconv(.c) c_int {
    _ = s;
    const fun: *JittedFn = @ptrCast(@alignCast(p));
    const ptr = fun.function_pointer orelse return 0;
    if (has_jit) {
        if (types.windows) {
            _ = VirtualFree(ptr, fun.size, MEM_RELEASE);
        } else {
            _ = std.c.munmap(@ptrCast(@alignCast(ptr)), fun.size);
        }
    }
    return 0;
}

fn jitfnGetBytes(p: ?*anyopaque, s: usize) callconv(.c) c.JanetByteView {
    _ = s;
    const fun: *JittedFn = @ptrCast(@alignCast(p));
    return .{ .bytes = @ptrCast(fun.function_pointer), .len = @intCast(fun.size) };
}

fn jitfnLength(p: ?*anyopaque, s: usize) raise.Raising(usize) {
    _ = s;
    const fun: *JittedFn = @ptrCast(@alignCast(p));
    return fun.size;
}

/// `janet_type_ffijit`.
pub const jit_at: abstract_type.AbstractType = .{
    .name = "ffi/jitfn",
    .gc = &jitfnGc,
    .bytes = &jitfnGetBytes,
    .length = &jitfnLength,
};

/// A quick hack to align to a page boundary; we should query the OS. FIXME
const page_mask: usize = 0xFFF;

pub fn jitfn(argc: i32, argv: [*c]const c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FFI_JIT);
    try arglayer.fixarity(argc, 1);
    const bytes = try arglayer.getBytes(argv, 0);

    if (!has_jit) return raise.panic("ffi/jitfn not available on this platform");

    const alloc_size = (@as(usize, @intCast(bytes.len)) + page_mask) & ~page_mask;
    const fun: *JittedFn = @ptrCast(@alignCast(if (has_ev)
        c.janet_abstract_threaded(abstract_type.stored(&jit_at), @sizeOf(JittedFn))
    else
        c.janet_abstract(abstract_type.stored(&jit_at), @sizeOf(JittedFn))));
    fun.function_pointer = null;
    fun.size = 0;

    const writable: [*]u8 = blk: {
        if (types.windows) {
            const ptr = VirtualAlloc(null, alloc_size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE) orelse
                return raise.panic("failed to allocate writable memory");
            break :blk @ptrCast(ptr);
        }
        const ptr = std.c.mmap(
            null,
            alloc_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        if (ptr == std.c.MAP_FAILED) return raise.panic("failed to memory map writable memory");
        break :blk @ptrCast(ptr);
    };

    @memcpy(writable[0..@intCast(bytes.len)], bytes.bytes[0..@intCast(bytes.len)]);

    if (types.windows) {
        var old: u32 = 0;
        if (0 == VirtualProtect(writable, alloc_size, PAGE_EXECUTE_READ, &old)) {
            return raise.panic("failed to make mapped memory executable");
        }
    } else {
        if (-1 == std.c.mprotect(@ptrCast(@alignCast(writable)), alloc_size, .{ .READ = true, .EXEC = true })) {
            return raise.panic("failed to make mapped memory executable");
        }
    }

    fun.size = alloc_size;
    fun.function_pointer = writable;
    return c.janet_wrap_abstract(fun);
}

// ==========================================================================
// ffi/call
// ==========================================================================

/// `janet_ffi_get_callable_pointer`.
fn callablePointer(argv: [*c]const c.Janet, n: i32) raise.Raising(*const anyopaque) {
    switch (c.janet_type(argv[@intCast(n)])) {
        c.JANET_POINTER => {
            if (c.janet_unwrap_pointer(argv[@intCast(n)])) |p| return p;
        },
        c.JANET_ABSTRACT => {
            if (null != c.janet_checkabstract(argv[@intCast(n)], abstract_type.stored(&jit_at))) {
                const fun: *JittedFn = @ptrCast(@alignCast(c.janet_unwrap_abstract(argv[@intCast(n)])));
                if (fun.function_pointer) |p| return p;
            }
        },
        else => {},
    }
    return pp_format.panicf(
        "bad slot #%d, expected ffi callable pointer type, got %v",
        .{ n, argv[@intCast(n)] },
    );
}

pub fn call(argc: i32, argv: [*c]const c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FFI_USE);
    try arglayer.arity(argc, 2, -1);
    const function_pointer = try callablePointer(argv, 0);
    const sig: *Signature = @ptrCast(@alignCast(try arglayer.getAbstract(argv, 1, abstract_type.stored(&types.signature_at))));
    try arglayer.fixarity(argc - 2, @bitCast(sig.arg_count));
    return switch (sig.cc) {
        .win64 => if (types.win64_enabled)
            callWin64(sig, function_pointer, argv)
        else
            raise.panic("calling convention not supported"),
        .sysv64 => if (types.sysv64_enabled)
            callSysv64(sig, function_pointer, argv)
        else
            raise.panic("calling convention not supported"),
        .aapcs64 => if (types.aapcs64_enabled)
            callAapcs64(sig, function_pointer, argv)
        else
            raise.panic("calling convention not supported"),
        .none => raise.panic("calling convention not supported"),
    };
}

/// `cfun_ffi_supported_calling_conventions`. Every architecture supports
/// `:none`, which is a placeholder that cannot be used at runtime.
pub fn supportedConventions() raise.Raising(c.Janet) {
    const array = c.janet_array(4);
    if (types.win64_enabled) try containers.arrayPush(array, c.janet_ckeywordv("win64"));
    if (types.sysv64_enabled) try containers.arrayPush(array, c.janet_ckeywordv("sysv64"));
    if (types.aapcs64_enabled) try containers.arrayPush(array, c.janet_ckeywordv("aapcs64"));
    try containers.arrayPush(array, c.janet_ckeywordv("none"));
    return c.janet_wrap_array(array);
}
