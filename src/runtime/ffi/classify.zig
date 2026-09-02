//! The FFI's calling conventions: register classification and argument
//! allocation for SysV AMD64, Windows x64, and AAPCS64.
//!
//! It decides, for a given signature, which argument travels in which register
//! and which spills to the stack, and stops where `ffi/call.zig` begins:
//! nothing here touches a Janet value or a trampoline.
//!
//! **All three conventions are compiled and asserted on every target.**
//! Everything here is arithmetic over sizes, alignments and ordinals --
//! nothing about it is architecture-specific except the rules it encodes --
//! and `ffi/call.zig` keeps the conditions that decide which one a build may
//! *call*. The one genuine host divergence, Apple's departure from AAPCS64
//! stack packing, is a parameter rather than a conditional, so both variants
//! are reachable from any machine.
//!
//! **`Type` and `Struct` do not cross into this file**, for the reason
//! `ffi/types.zig` gives: they carry a pointer into a garbage-collected
//! abstract. `ffi/call.zig` serializes the type tree into the flat pre-order
//! array of `TypeNode` below, which holds only scalars. Classification is
//! genuinely structural -- SysV consults each nested struct's own size and
//! alignment, not just its leaves -- so a flattened list of leaves would not
//! do; the tree has to arrive, just without the pointers.
//!
//! **Nothing here raises.** A convention that cannot place an argument reports
//! the position and the reason, and `ffi/call.zig` turns that into a panic.
//!
//! The primitive ordinals mirror enumerations upstream Janet keeps file-local,
//! and `test/ffi_classify.zig` pins them by writing the numbers out rather
//! than by importing these declarations.

const std = @import("std");

/// The machine types, numbered as `ffi/types.zig`'s `PrimType` numbers them.
/// Restated here rather than imported so that this file has no dependency on
/// the FFI's own types: it is pure arithmetic over integers.
const prim_void: u32 = 0;
const prim_bool: u32 = 1;
const prim_ptr: u32 = 2;
const prim_string: u32 = 3;
const prim_float: u32 = 4;
const prim_double: u32 = 5;
const prim_int8: u32 = 6;
const prim_uint8: u32 = 7;
const prim_int16: u32 = 8;
const prim_uint16: u32 = 9;
const prim_int32: u32 = 10;
const prim_uint32: u32 = 11;
const prim_int64: u32 = 12;
const prim_uint64: u32 = 13;
const prim_struct: u32 = 14;

/// Where one argument goes, per convention. Each convention has its own block
/// and the numbers are only compared within one.
const sysv64_integer: u32 = 0;
const sysv64_sse: u32 = 1;
const sysv64_sseup: u32 = 2;
const sysv64_pair_intint: u32 = 3;
const sysv64_pair_intsse: u32 = 4;
const sysv64_pair_sseint: u32 = 5;
const sysv64_pair_ssesse: u32 = 6;
const sysv64_no_class: u32 = 7;
const sysv64_memory: u32 = 8;
const win64_register: u32 = 9;
const win64_stack: u32 = 10;
const win64_register_ref: u32 = 11;
const win64_stack_ref: u32 = 12;
const aapcs64_general: u32 = 13;
const aapcs64_sse: u32 = 14;
const aapcs64_general_ref: u32 = 15;
const aapcs64_stack: u32 = 16;
const aapcs64_stack_ref: u32 = 17;
const aapcs64_none: u32 = 18;

/// Why a convention could not place a signature. `ffi.c` maps these back to the
/// panics the C implementation raised in the same positions.
const err_none: u32 = 0;
const err_unsupported_spec: u32 = 1;
const err_return_too_big: u32 = 2;

/// One node of a serialized `types.Type`, in pre-order: a struct's fields
/// follow it immediately, each field's own subtree complete before the next
/// begins. `field_count` is zero for everything that is not a struct, which lets
/// one walk skip any subtree without knowing what is in it.
///
/// `size` is `types.typeSize` -- the array count already multiplied in --
/// while `struct_size` is the underlying `types.Struct`'s own size with the array
/// count left out. The two conventions want different ones, and conflating them
/// is the sort of mistake this split exists to prevent.
pub const TypeNode = extern struct {
    size: u64,
    struct_size: u32,
    prim: u32,
    field_count: u32,
    is_aligned: u32,
    /// Byte offset within the enclosing struct; zero at the root.
    offset: u32,
    /// -1 when the type is not an array. Both conventions ignore it: `size`
    /// already has the count multiplied in, which is the only thing a
    /// classifier needs from it.
    array_count: i32,
};

/// One argument, as the conventions see it. `spec` arrives holding the class the
/// matching classifier produced and leaves holding the placement, which is not
/// always the same: an argument that classifies into a register but finds none
/// free is rewritten to a stack or memory spec.
pub const ArgSlot = struct {
    size: u64,
    prim: u32,
    spec: u32,
    alignment: u32,
    offset: u32,
    offset2: u32,
    /// How many vector registers an AAPCS64 homogeneous floating-point
    /// aggregate occupies: **one per member**, which is what §6.8.2 says and
    /// is not the same as one per eight bytes.
    ///
    /// Zero where the caller could not say — every non-SSE argument, a scalar,
    /// and a top-level array of floats, whose extent the conventions ignore
    /// because `size` already has the count multiplied in, so the byte
    /// arithmetic is the right answer for those.
    ///
    /// It has to be a field because the allocator sees an `ArgSlot` and not a
    /// `Type`, and the member count is a fact about the type.
    hfa_members: u32,
};

/// What a convention decided for the signature as a whole.
pub const AllocResult = struct {
    stack_count: u32,
    variant: u32,
    error_kind: u32,
    /// Index of the argument that could not be placed, or -1 when the failure
    /// belongs to the return value or there was none.
    error_arg: i32,
    /// The *outgoing* part of the frame, in words: the stack arguments the
    /// callee will read, without the by-reference payloads that follow them.
    ///
    /// Appended rather than placed where it belongs, so that the field order
    /// is left alone. The distinction has to be drawn because a caller
    /// declares the outgoing words as parameters and so has to know how many
    /// there are -- and must not count the payloads, which is what would make
    /// a large by-reference argument reach a ceiling not meant for it.
    arg_stack_count: u32,
};

/// Where a walk of the node array stopped, and what it concluded.
const Walk = struct {
    class: u32,
    next: usize,
};

/// The index just past `idx`'s subtree. Non-struct nodes have no fields, so this
/// is the single step that ends the recursion.
fn skipSubtree(nodes: []const TypeNode, idx: usize) usize {
    var i = idx + 1;
    var remaining = nodes[idx].field_count;
    while (remaining > 0) : (remaining -= 1) {
        i = skipSubtree(nodes, i);
    }
    return i;
}

// -- SysV AMD64 ------------------------------------------------------------
//
// AMD64 ABI Draft 0.99.7, section 3.2.3, Parameter Passing.

fn sysv64ClassifyExt(nodes: []const TypeNode, idx: usize, shift: u64) Walk {
    const node = nodes[idx];
    return switch (node.prim) {
        prim_ptr, prim_string, prim_bool, prim_int8, prim_int16, prim_int32, prim_int64, prim_uint8, prim_uint16, prim_uint32, prim_uint64 => .{
            .class = sysv64_integer,
            .next = idx + 1,
        },
        prim_double, prim_float => .{ .class = sysv64_sse, .next = idx + 1 },
        prim_struct => sysv64ClassifyStruct(nodes, idx, shift),
        // Every ordinal the enumeration defines is handled above, so this arm
        // stands only because the switch is over an integer rather than over
        // an enumeration.
        else => .{ .class = sysv64_no_class, .next = idx + 1 },
    };
}

fn sysv64ClassifyStruct(nodes: []const TypeNode, idx: usize, shift: u64) Walk {
    const node = nodes[idx];
    if (node.struct_size > 16 or node.is_aligned == 0) {
        return .{ .class = sysv64_memory, .next = skipSubtree(nodes, idx) };
    }

    var clazz = sysv64_no_class;
    var child = idx + 1;
    var remaining = node.field_count;

    if (node.struct_size > 8) {
        // Two eightbytes: decide each half separately, then name the pair.
        var has_int_lo: u32 = 0;
        var has_int_hi: u32 = 0;
        var any_memory = false;
        while (remaining > 0) : (remaining -= 1) {
            const field = nodes[child];
            const walk = sysv64ClassifyExt(nodes, child, shift +% field.offset);
            child = walk.next;
            switch (walk.class) {
                sysv64_integer => {
                    if (shift +% field.offset +% field.size <= 8) {
                        has_int_lo = 1;
                    } else {
                        has_int_hi = 2;
                    }
                },
                sysv64_pair_intint => {
                    has_int_lo = 1;
                    has_int_hi = 2;
                },
                sysv64_pair_intsse => has_int_lo = 1,
                sysv64_pair_sseint => has_int_hi = 2,
                // **A field that classifies as memory forces the whole
                // aggregate to memory**, which is the AMD64 ABI §3.2.3
                // post-merger rule and what the eight-byte-or-under merge
                // below already does. Discarding it here would make the same
                // field decide the argument at one size and count for nothing
                // at another: a packed nested struct sends any aggregate to
                // memory regardless of size, so `[:s64 [:u8 :pack :u32]]`
                // would travel in a register pair the callee reads from the
                // stack.
                sysv64_memory => any_memory = true,
                else => {},
            }
        }
        clazz = if (any_memory) sysv64_memory else switch (has_int_hi + has_int_lo) {
            0 => sysv64_pair_ssesse,
            1 => sysv64_pair_intsse,
            2 => sysv64_pair_sseint,
            else => sysv64_pair_intint,
        };
    } else {
        while (remaining > 0) : (remaining -= 1) {
            const field_offset = nodes[child].offset;
            const walk = sysv64ClassifyExt(nodes, child, shift +% field_offset);
            child = walk.next;
            if (walk.class != clazz) {
                if (clazz == sysv64_no_class) {
                    clazz = walk.class;
                } else if (clazz == sysv64_memory or walk.class == sysv64_memory) {
                    clazz = sysv64_memory;
                } else if (clazz == sysv64_integer or walk.class == sysv64_integer) {
                    clazz = sysv64_integer;
                } else {
                    clazz = sysv64_sse;
                }
            }
        }
    }

    return .{ .class = clazz, .next = child };
}

pub fn classifySysv64(nodes: []const TypeNode) u32 {
    if (nodes.len == 0) return sysv64_no_class;
    return sysv64ClassifyExt(nodes, 0, 0).class;
}

// -- AAPCS64 ---------------------------------------------------------------
//
// Procedure Call Standard for the Arm 64-bit Architecture, 2023Q3, section
// 6.8.2, Parameter passing rules.

fn aapcs64Classify(nodes: []const TypeNode, idx: usize) Walk {
    const node = nodes[idx];
    return switch (node.prim) {
        prim_ptr, prim_string, prim_bool, prim_int8, prim_int16, prim_int32, prim_int64, prim_uint8, prim_uint16, prim_uint32, prim_uint64 => .{
            .class = aapcs64_general,
            .next = idx + 1,
        },
        prim_double, prim_float => .{ .class = aapcs64_sse, .next = idx + 1 },
        prim_struct => blk: {
            const end = skipSubtree(nodes, idx);

            // A homogeneous floating-point aggregate travels in the vector
            // registers. An empty struct is reachable through the empty tuple
            // type, so the field count is tested before a first field is read:
            // the guard below is deliberate, not a transcription slip.
            if (node.field_count > 0 and node.field_count <= 4) {
                const first = idx + 1;
                if (aapcs64Classify(nodes, first).class == aapcs64_sse) {
                    var is_hfa = true;
                    var child = skipSubtree(nodes, first);
                    for (1..node.field_count) |_| {
                        if (nodes[first].prim != nodes[child].prim) {
                            is_hfa = false;
                            break;
                        }
                        child = skipSubtree(nodes, child);
                    }
                    if (is_hfa) break :blk Walk{ .class = aapcs64_sse, .next = end };
                }
            }

            if (node.size > 16) break :blk Walk{ .class = aapcs64_general_ref, .next = end };
            break :blk Walk{ .class = aapcs64_general, .next = end };
        },
        // As in the SysV classifier: an ordinal the enumeration cannot
        // produce, and the switch is over an integer.
        else => .{ .class = aapcs64_none, .next = idx + 1 },
    };
}

pub fn classifyAapcs64(nodes: []const TypeNode) u32 {
    if (nodes.len == 0) return aapcs64_none;
    return aapcs64Classify(nodes, 0).class;
}

// -- Argument allocation ---------------------------------------------------

fn isFloating(prim: u32) bool {
    return prim == prim_float or prim == prim_double;
}

/// Round `value` up to the next multiple of `alignment`, which is always a power
/// of two here.
fn alignUp(value: u32, alignment: u32) u32 {
    return (value +% (alignment -% 1)) & ~(alignment -% 1);
}

/// Windows x64. Four register slots, everything that is not exactly one, two,
/// four, or eight bytes wide passed by reference, and a `variant` whose bits say
/// which of the first four arguments are floating point so the trampoline knows
/// to load the vector registers as well.
pub fn allocWin64(
    result: *AllocResult,
    ret: *ArgSlot,
    args: []ArgSlot,
) void {
    result.* = .{ .stack_count = 0, .variant = 0, .error_kind = err_none, .error_arg = -1, .arg_stack_count = 0 };

    var stack_count: u32 = 0;
    var ref_stack_count: u32 = 0;
    var next_register: u32 = 0;

    ret.spec = win64_register;
    const ret_size = ret.size;
    if (ret_size != 0 and ret_size != 1 and ret_size != 2 and ret_size != 4 and ret_size != 8) {
        ret.spec = win64_register_ref;
        next_register += 1;
    } else if (isFloating(ret.prim)) {
        result.variant +%= 16;
    }

    for (args) |*arg| {
        const el_size = arg.size;
        const is_register_sized = el_size == 1 or el_size == 2 or el_size == 4 or el_size == 8;
        if (next_register < 4) {
            arg.offset = next_register;
            if (is_register_sized) {
                arg.spec = win64_register;
                if (isFloating(arg.prim)) {
                    result.variant +%= @as(u32, 1) << @intCast(3 - next_register);
                }
            } else {
                arg.spec = win64_register_ref;
                arg.offset2 = ref_stack_count;
                ref_stack_count +%= @truncate((el_size +% 15) / 16);
            }
            next_register += 1;
        } else {
            arg.offset = stack_count;
            stack_count +%= 1;
            if (is_register_sized) {
                arg.spec = win64_stack;
            } else {
                arg.spec = win64_stack_ref;
                arg.offset2 = ref_stack_count;
                ref_stack_count +%= @truncate((el_size +% 15) / 16);
            }
        }
    }

    result.arg_stack_count = stack_count;
    stack_count +%= 2 *% ref_stack_count;
    if (stack_count & 1 != 0) stack_count +%= 1;

    // The reference area sits above the stack arguments and is addressed from
    // the top, so the offsets recorded above are inverted now that the total is
    // known.
    for (args) |*arg| {
        if (arg.spec == win64_stack_ref or arg.spec == win64_register_ref) {
            const size = (arg.size +% 15) & ~@as(u64, 0xF);
            arg.offset2 = stack_count -% arg.offset2 -% @as(u32, @truncate(size / 8));
        }
    }

    result.stack_count = stack_count;
}

/// SysV AMD64. Six general registers, eight vector registers, and a `variant`
/// that tells the trampoline how to read the return value back out.
pub fn allocSysv64(
    result: *AllocResult,
    ret: *ArgSlot,
    args: []ArgSlot,
) void {
    result.* = .{ .stack_count = 0, .variant = 0, .error_kind = err_none, .error_arg = -1, .arg_stack_count = 0 };

    switch (ret.spec) {
        sysv64_sse => result.variant = 1,
        sysv64_pair_intsse => result.variant = 2,
        sysv64_pair_sseint => result.variant = 3,
        else => {},
    }

    const max_regs: u32 = 6;
    const max_fp_regs: u32 = 8;
    var next_register: u32 = 0;
    var next_fp_register: u32 = 0;
    var stack_count: u32 = 0;

    // A return value in memory is written through a pointer the caller passes in
    // the first integer register, so that register is not available to arguments.
    if (ret.spec == sysv64_memory) next_register = 1;

    for (args, 0..) |*arg, i| {
        arg.offset = 0;
        const el_size: u32 = @truncate((arg.size +% 7) / 8);

        switch (arg.spec) {
            sysv64_integer => {
                if (next_register < max_regs) {
                    arg.offset = next_register;
                    next_register += 1;
                } else {
                    arg.spec = sysv64_memory;
                    arg.offset = stack_count;
                    stack_count +%= el_size;
                }
            },
            sysv64_sse => {
                if (next_fp_register < max_fp_regs) {
                    arg.offset = next_fp_register;
                    next_fp_register += 1;
                } else {
                    arg.spec = sysv64_memory;
                    arg.offset = stack_count;
                    stack_count +%= el_size;
                }
            },
            sysv64_memory => {
                arg.offset = stack_count;
                stack_count +%= el_size;
            },
            sysv64_pair_intint => {
                if (next_register + 1 < max_regs) {
                    arg.offset = next_register;
                    arg.offset2 = next_register + 1;
                    next_register += 2;
                } else {
                    arg.spec = sysv64_memory;
                    arg.offset = stack_count;
                    stack_count +%= el_size;
                }
            },
            sysv64_pair_intsse => {
                if (next_register < max_regs and next_fp_register < max_fp_regs) {
                    arg.offset = next_register;
                    next_register += 1;
                    arg.offset2 = next_fp_register;
                    next_fp_register += 1;
                } else {
                    arg.spec = sysv64_memory;
                    arg.offset = stack_count;
                    stack_count +%= el_size;
                }
            },
            sysv64_pair_sseint => {
                if (next_register < max_regs and next_fp_register < max_fp_regs) {
                    arg.offset = next_fp_register;
                    next_fp_register += 1;
                    arg.offset2 = next_register;
                    next_register += 1;
                } else {
                    arg.spec = sysv64_memory;
                    arg.offset = stack_count;
                    stack_count +%= el_size;
                }
            },
            sysv64_pair_ssesse => {
                if (next_fp_register < max_fp_regs) {
                    arg.offset = next_fp_register;
                    arg.offset2 = next_fp_register + 1;
                    next_fp_register += 2;
                } else {
                    arg.spec = sysv64_memory;
                    arg.offset = stack_count;
                    stack_count +%= el_size;
                }
            },
            else => {
                result.error_kind = err_unsupported_spec;
                result.error_arg = @intCast(i);
                return;
            },
        }
    }

    result.stack_count = stack_count;
    result.arg_stack_count = stack_count;
}

/// AAPCS64. Eight general registers, eight vector registers, and a stack whose
/// packing rules differ on Apple platforms: the generic standard rounds every
/// stack argument up to eight bytes, while Apple packs them at their natural
/// alignment. `apple` carries that difference so both are reachable from any
/// build. `max_ret_size` is the width of the trampoline's return buffer, which
/// is a host fact and so arrives from the caller.
pub fn allocAapcs64(
    result: *AllocResult,
    ret: *ArgSlot,
    args: []ArgSlot,
    apple: bool,
    max_ret_size: u64,
) void {
    result.* = .{ .stack_count = 0, .variant = 0, .error_kind = err_none, .error_arg = -1, .arg_stack_count = 0 };

    if (ret.spec == aapcs64_sse) {
        result.variant = 1;
    } else if (ret.spec == aapcs64_general_ref) {
        if (ret.size > max_ret_size) {
            result.error_kind = err_return_too_big;
            result.error_arg = -1;
            return;
        }
        result.variant = 2;
    } else {
        result.variant = 0;
    }

    var next_general_reg: u32 = 0;
    var next_fp_reg: u32 = 0;
    var stack_offset: u32 = 0;
    var ref_stack_offset: u32 = 0;

    for (args, 0..) |*arg, i| {
        const arg_size: u32 = @truncate(arg.size);

        switch (arg.spec) {
            aapcs64_general => {
                const needed_registers = (arg_size +% 7) / 8;
                if (next_general_reg + needed_registers <= 8) {
                    arg.offset = next_general_reg;
                    next_general_reg += needed_registers;
                } else {
                    // A struct on the stack is aligned as a word regardless of
                    // what its fields would demand.
                    const arg_align: u32 = if (arg.prim == prim_struct) 8 else arg.alignment;
                    arg.spec = aapcs64_stack;
                    stack_offset = alignUp(stack_offset, if (apple) arg_align else 8);
                    arg.offset = stack_offset;
                    stack_offset +%= if (apple) arg_size else @max(arg_size, 8);
                    next_general_reg = 8;
                }
            },
            aapcs64_general_ref => {
                if (next_general_reg < 8) {
                    arg.offset = next_general_reg;
                    next_general_reg += 1;
                } else {
                    arg.spec = aapcs64_stack_ref;
                    stack_offset = alignUp(stack_offset, 8);
                    arg.offset = stack_offset;
                    stack_offset +%= 8;
                }
                ref_stack_offset = alignUp(ref_stack_offset, 8);
                arg.offset2 = ref_stack_offset;
                ref_stack_offset +%= arg_size;
            },
            aapcs64_sse => {
                // One register per member for an aggregate, one for a scalar.
                // Sizing this by bytes gives a four-float HFA two registers
                // where the callee reads four, and writes its members two to a
                // register.
                const needed_registers = if (arg.hfa_members != 0)
                    arg.hfa_members
                else
                    (arg_size +% 7) / 8;
                if (next_fp_reg + needed_registers <= 8) {
                    arg.offset = next_fp_reg;
                    next_fp_reg += needed_registers;
                } else {
                    arg.spec = aapcs64_stack;
                    stack_offset = alignUp(stack_offset, 8);
                    arg.offset = stack_offset;
                    stack_offset +%= if (apple) arg_size else 8;
                }
            },
            else => {
                result.error_kind = err_unsupported_spec;
                result.error_arg = @intCast(i);
                return;
            },
        }
    }

    stack_offset = alignUp(stack_offset, 16);
    ref_stack_offset = alignUp(ref_stack_offset, 16);
    result.stack_count = stack_offset +% ref_stack_offset;
    // This convention's offsets are bytes; the outgoing count is words.
    result.arg_stack_count = (stack_offset +% 7) / 8;

    // The by-reference area follows the stack arguments, so its offsets are
    // relative until the stack area's final size is known.
    for (args) |*arg| {
        if (arg.spec == aapcs64_general_ref or arg.spec == aapcs64_stack_ref) {
            arg.offset2 = stack_offset +% arg.offset2;
        }
    }
}

// -- Tests -----------------------------------------------------------------

fn leaf(prim: u32, size: u64, offset: u32) TypeNode {
    return .{
        .size = size,
        .struct_size = 0,
        .prim = prim,
        .field_count = 0,
        .is_aligned = 1,
        .offset = offset,
        .array_count = -1,
    };
}

fn structNode(size: u32, field_count: u32, offset: u32) TypeNode {
    return .{
        .size = size,
        .struct_size = size,
        .prim = prim_struct,
        .field_count = field_count,
        .is_aligned = 1,
        .offset = offset,
        .array_count = -1,
    };
}

test "sysv64 classifies scalars" {
    const int_node = [_]TypeNode{leaf(prim_int32, 4, 0)};
    try std.testing.expectEqual(sysv64_integer, classifySysv64(&int_node));

    const double_node = [_]TypeNode{leaf(prim_double, 8, 0)};
    try std.testing.expectEqual(sysv64_sse, classifySysv64(&double_node));

    const void_node = [_]TypeNode{leaf(prim_void, 0, 0)};
    try std.testing.expectEqual(sysv64_no_class, classifySysv64(&void_node));
}

test "sysv64 sends anything over sixteen bytes to memory" {
    const nodes = [_]TypeNode{
        structNode(24, 3, 0),
        leaf(prim_int64, 8, 0),
        leaf(prim_int64, 8, 8),
        leaf(prim_int64, 8, 16),
    };
    try std.testing.expectEqual(sysv64_memory, classifySysv64(&nodes));
}

test "sysv64 names the pair of a two-eightbyte struct" {
    // { int64; double } occupies one integer eightbyte then one SSE eightbyte.
    const nodes = [_]TypeNode{
        structNode(16, 2, 0),
        leaf(prim_int64, 8, 0),
        leaf(prim_double, 8, 8),
    };
    try std.testing.expectEqual(sysv64_pair_intsse, classifySysv64(&nodes));

    // { double; int64 } is the mirror image.
    const mirrored = [_]TypeNode{
        structNode(16, 2, 0),
        leaf(prim_double, 8, 0),
        leaf(prim_int64, 8, 8),
    };
    try std.testing.expectEqual(sysv64_pair_sseint, classifySysv64(&mirrored));

    // { double; double } stays in the vector registers.
    const both = [_]TypeNode{
        structNode(16, 2, 0),
        leaf(prim_double, 8, 0),
        leaf(prim_double, 8, 8),
    };
    try std.testing.expectEqual(sysv64_pair_ssesse, classifySysv64(&both));
}

test "sysv64 merges a small struct into a single class" {
    // { float; float } fits one eightbyte and stays SSE.
    const floats = [_]TypeNode{
        structNode(8, 2, 0),
        leaf(prim_float, 4, 0),
        leaf(prim_float, 4, 4),
    };
    try std.testing.expectEqual(sysv64_sse, classifySysv64(&floats));

    // Mixing an integer in makes the whole eightbyte an integer.
    const mixed = [_]TypeNode{
        structNode(8, 2, 0),
        leaf(prim_int32, 4, 0),
        leaf(prim_float, 4, 4),
    };
    try std.testing.expectEqual(sysv64_integer, classifySysv64(&mixed));
}

test "sysv64 sends a misaligned struct to memory" {
    var nodes = [_]TypeNode{
        structNode(9, 2, 0),
        leaf(prim_uint8, 1, 0),
        leaf(prim_uint64, 8, 1),
    };
    nodes[0].is_aligned = 0;
    try std.testing.expectEqual(sysv64_memory, classifySysv64(&nodes));
}

test "aapcs64 recognises a homogeneous floating-point aggregate" {
    const hfa = [_]TypeNode{
        structNode(16, 4, 0),
        leaf(prim_float, 4, 0),
        leaf(prim_float, 4, 4),
        leaf(prim_float, 4, 8),
        leaf(prim_float, 4, 12),
    };
    try std.testing.expectEqual(aapcs64_sse, classifyAapcs64(&hfa));

    // A fifth member takes it out of the homogeneous case, and twenty bytes is
    // then too wide for the registers.
    const too_many = [_]TypeNode{
        structNode(20, 5, 0),
        leaf(prim_float, 4, 0),
        leaf(prim_float, 4, 4),
        leaf(prim_float, 4, 8),
        leaf(prim_float, 4, 12),
        leaf(prim_float, 4, 16),
    };
    try std.testing.expectEqual(aapcs64_general_ref, classifyAapcs64(&too_many));

    // Mixed element types are not homogeneous either.
    const mixed = [_]TypeNode{
        structNode(16, 2, 0),
        leaf(prim_float, 4, 0),
        leaf(prim_double, 8, 8),
    };
    try std.testing.expectEqual(aapcs64_general, classifyAapcs64(&mixed));
}

test "aapcs64 treats an empty struct as an ordinary aggregate" {
    // The field count is tested first, so no first field is read.
    const empty = [_]TypeNode{structNode(0, 0, 0)};
    try std.testing.expectEqual(aapcs64_general, classifyAapcs64(&empty));
}

test "win64 passes the first four arguments in registers" {
    var ret = ArgSlot{ .size = 8, .prim = prim_int64, .spec = 0, .alignment = 8, .offset = 0, .offset2 = 0, .hfa_members = 0 };
    var args = [_]ArgSlot{
        .{ .size = 8, .prim = prim_int64, .spec = 0, .alignment = 8, .offset = 0, .offset2 = 0, .hfa_members = 0 },
        .{ .size = 8, .prim = prim_double, .spec = 0, .alignment = 8, .offset = 0, .offset2 = 0, .hfa_members = 0 },
    };
    var result: AllocResult = undefined;
    allocWin64(&result, &ret, &args);

    try std.testing.expectEqual(win64_register, args[0].spec);
    try std.testing.expectEqual(@as(u32, 0), args[0].offset);
    try std.testing.expectEqual(win64_register, args[1].spec);
    try std.testing.expectEqual(@as(u32, 1), args[1].offset);
    // The second argument is floating point, so bit (3 - 1) is set.
    try std.testing.expectEqual(@as(u32, 4), result.variant);
    try std.testing.expectEqual(err_none, result.error_kind);
}

test "sysv64 spills past the sixth integer register" {
    var ret = ArgSlot{ .size = 0, .prim = prim_void, .spec = sysv64_no_class, .alignment = 1, .offset = 0, .offset2 = 0, .hfa_members = 0 };
    var args: [8]ArgSlot = undefined;
    for (&args) |*a| {
        a.* = .{ .size = 8, .prim = prim_int64, .spec = sysv64_integer, .alignment = 8, .offset = 0, .offset2 = 0, .hfa_members = 0 };
    }
    var result: AllocResult = undefined;
    allocSysv64(&result, &ret, &args);

    for (args[0..6], 0..) |a, i| {
        try std.testing.expectEqual(sysv64_integer, a.spec);
        try std.testing.expectEqual(@as(u32, @intCast(i)), a.offset);
    }
    try std.testing.expectEqual(sysv64_memory, args[6].spec);
    try std.testing.expectEqual(@as(u32, 0), args[6].offset);
    try std.testing.expectEqual(sysv64_memory, args[7].spec);
    try std.testing.expectEqual(@as(u32, 1), args[7].offset);
    try std.testing.expectEqual(@as(u32, 2), result.stack_count);
}

test "aapcs64 packs the stack differently on Apple platforms" {
    // Nine one-byte arguments: the first eight take the general registers and
    // the ninth goes to the stack, where the two variants disagree on width.
    for ([_]bool{ false, true }) |apple| {
        var ret = ArgSlot{ .size = 0, .prim = prim_void, .spec = aapcs64_none, .alignment = 1, .offset = 0, .offset2 = 0, .hfa_members = 0 };
        var args: [9]ArgSlot = undefined;
        for (&args) |*a| {
            a.* = .{ .size = 1, .prim = prim_uint8, .spec = aapcs64_general, .alignment = 1, .offset = 0, .offset2 = 0, .hfa_members = 0 };
        }
        var result: AllocResult = undefined;
        allocAapcs64(&result, &ret, &args, apple, 128);

        try std.testing.expectEqual(aapcs64_stack, args[8].spec);
        try std.testing.expectEqual(@as(u32, 0), args[8].offset);
        // Apple advances by the argument's own size, the generic standard by a
        // whole word; both then round the total up to sixteen.
        try std.testing.expectEqual(@as(u32, 16), result.stack_count);
    }
}

test "aapcs64 refuses a return value wider than the trampoline buffer" {
    var ret = ArgSlot{ .size = 256, .prim = prim_struct, .spec = aapcs64_general_ref, .alignment = 8, .offset = 0, .offset2 = 0, .hfa_members = 0 };
    var args: [0]ArgSlot = undefined;
    var result: AllocResult = undefined;
    allocAapcs64(&result, &ret, &args, false, 128);

    try std.testing.expectEqual(err_return_too_big, result.error_kind);
    try std.testing.expectEqual(@as(i32, -1), result.error_arg);
}
