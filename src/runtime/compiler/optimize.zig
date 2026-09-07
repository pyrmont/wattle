//! The three bytecode-to-bytecode passes the compiler runs after emission.
//!
//! Constant folding over the builtin table, `mov` elimination and `noop`
//! removal are three walks over the same `functions.FuncDef` bytecode, run in
//! sequence by one caller. None publishes a Janet name and none exists because
//! a platform differs, so they are one file and the sequence is visible in one
//! place.
//!
//! `funopt` is the folding half's entry: it looks a funcdef's tag up in
//! `optimizers` and gives back the pair of an arity predicate and a form
//! builder. `bytecodeMovopt` and `bytecodeRemoveNoops` are the other two
//! passes, each taking the funcdef and rewriting its bytecode in place.
//!
//! The opcode accessor is `opcodeOf` rather than `opcode`, because four
//! parameters in the constant-folding half are named `opcode` and a
//! container-level declaration of that name would shadow them.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const args_core = @import("../args.zig");
const compiler_primitives = @import("../compiler.zig");
const constants = @import("constants");
const emit_core = @import("emit.zig");
const fatal = @import("../fatal.zig");
const functions = @import("../value/functions.zig");
const gc_alloc = @import("../gc.zig");
const regalloc = @import("regalloc.zig");
const repr = @import("repr");
const utils = @import("../utils.zig");
const wrap = @import("../value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The builtin table, indexed by a funcdef's tag less one. Each row pairs the
/// arity a form accepts with the code that emits it.
const optimizers = [_]compiler_primitives.FunctionOptimizer{
    .{ .can_optimize = maxarity1, .optimize = doDebug },
    .{ .can_optimize = fixarity1, .optimize = doError },
    .{ .can_optimize = minarity2, .optimize = doApply },
    .{ .can_optimize = maxarity1, .optimize = doYield },
    .{ .can_optimize = arity1or2, .optimize = doResume },
    .{ .can_optimize = fixarity2, .optimize = doIn },
    .{ .can_optimize = fixarity3, .optimize = doPut },
    .{ .can_optimize = fixarity1, .optimize = doLength },
    .{ .can_optimize = null, .optimize = doAdd },
    .{ .can_optimize = null, .optimize = doSub },
    .{ .can_optimize = null, .optimize = doMul },
    .{ .can_optimize = null, .optimize = doDiv },
    .{ .can_optimize = null, .optimize = doBand },
    .{ .can_optimize = null, .optimize = doBor },
    .{ .can_optimize = null, .optimize = doBxor },
    .{ .can_optimize = null, .optimize = doLshift },
    .{ .can_optimize = null, .optimize = doRshift },
    .{ .can_optimize = null, .optimize = doRshiftu },
    .{ .can_optimize = fixarity1, .optimize = doBnot },
    .{ .can_optimize = null, .optimize = doGt },
    .{ .can_optimize = null, .optimize = doLt },
    .{ .can_optimize = null, .optimize = doGte },
    .{ .can_optimize = null, .optimize = doLte },
    .{ .can_optimize = null, .optimize = doEq },
    .{ .can_optimize = null, .optimize = doNeq },
    .{ .can_optimize = fixarity2, .optimize = doPropagate },
    .{ .can_optimize = arity2or3, .optimize = doGet },
    .{ .can_optimize = arity1or2, .optimize = doNext },
    .{ .can_optimize = null, .optimize = doModulo },
    .{ .can_optimize = null, .optimize = doRemainder },
    .{ .can_optimize = fixarity2, .optimize = doCmp },
    .{ .can_optimize = fixarity2, .optimize = doCancel },
    .{ .can_optimize = null, .optimize = doDivf },
};

// ==========================================================================
// Types
// ==========================================================================

/// The immediate-operand form of one argument, where the opcode has one and
/// the argument fits in it.
///
/// The two are one question rather than two, because an immediate encoding
/// needs both halves: the opcode that has an immediate form, and an argument
/// that fits in it.
const ImmediateForm = struct {
    opcode: constants.Opcode,
    operand: i8,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Eliminates `mov` instructions whose source and destination are the same
/// register, repeating until a pass changes nothing.
pub fn bytecodeMovopt(definition: *functions.FuncDef) void {
    var repeat = true;
    while (repeat) {
        var registers: regalloc.RegisterAllocator = .{};
        defer registers.deinit();

        if (definition.closure_bitset != null) {
            for (0..@as(usize, @intCast(definition.slotcount))) |slot| {
                const index = slot >> 5;
                const bit: u5 = @intCast(slot & 31);
                if (definition.closureBits()[index] & (@as(u32, 1) << bit) != 0) {
                    registers.touch(@intCast(slot));
                }
            }
        }

        for (definition.instructions()) |instruction| {
            markReads(&registers, instruction);
        }

        repeat = false;
        for (definition.instructions()) |*instruction| {
            const candidate: ?i32 = switch (opcodeOf(instruction.*)) {
                constants.Opcode.load_nil,
                constants.Opcode.load_true,
                constants.Opcode.load_false,
                constants.Opcode.load_self,
                constants.Opcode.make_array,
                constants.Opcode.make_tuple,
                constants.Opcode.make_bracket_tuple,
                => fieldD(instruction.*),

                constants.Opcode.move_far => fieldE(instruction.*),

                constants.Opcode.move_near,
                constants.Opcode.get_index,
                constants.Opcode.load_integer,
                constants.Opcode.load_constant,
                constants.Opcode.load_upvalue,
                constants.Opcode.closure,
                => fieldA(instruction.*),

                else => null,
            };
            if (candidate) |written_slot| {
                if (!registers.isTaken(@intCast(written_slot))) {
                    instruction.* = constants.Opcode.noop.number();
                    repeat = true;
                }
            }
        }
    }
}

/// Removes every `noop` instruction and repoints every jump that crossed one.
pub fn bytecodeRemoveNoops(definition: *functions.FuncDef) void {
    const old_length = definition.bytecode_length;
    const map_length: usize = @intCast(old_length + 1);
    const map_size = map_length * @sizeOf(u32);
    const pc_map: [*]u32 = @ptrCast(@alignCast(gc_alloc.smalloc(map_size)));
    defer gc_alloc.sfree(pc_map);

    var new_length: u32 = 0;
    for (definition.instructions()[0..@intCast(old_length)], 0..) |instruction, index| {
        pc_map[index] = new_length;
        if (opcodeOf(instruction) != constants.Opcode.noop) new_length += 1;
    }
    pc_map[@intCast(old_length)] = new_length;

    // Both counters are positions in the bytecode array. The jump arithmetic
    // inside stays signed, because an encoded offset is `target - here` and
    // may be negative, so `here` is where the two meet.
    var destination_index: usize = 0;
    for (0..@as(usize, @intCast(old_length))) |source_index| {
        var instruction = definition.instructions()[source_index];
        const shift: ?u5 = switch (opcodeOf(instruction)) {
            constants.Opcode.noop => continue,
            constants.Opcode.jump => 8,
            constants.Opcode.jump_if, constants.Opcode.jump_if_nil, constants.Opcode.jump_if_not, constants.Opcode.jump_if_not_nil => 16,
            else => null,
        };
        if (shift) |field_shift| {
            const here: i32 = @intCast(source_index);
            const old_target = here + signedField(instruction, field_shift);
            if (old_target < 0 or old_target >= old_length) fatal.fatal("bounds");
            const new_target: i32 = @intCast(pc_map[@intCast(old_target)]);
            const adjustment = new_target - old_target + (here - @as(i32, @intCast(destination_index)));
            instruction +%= @as(u32, @bitCast(adjustment)) << field_shift;
        }
        definition.instructions()[destination_index] = instruction;
        if (definition.sourcemap != null) {
            definition.sourceMappings()[destination_index] = definition.sourceMappings()[source_index];
        }
        destination_index += 1;
    }

    if (definition.symbolmap_length > 0) {
        for (definition.symbols()) |*symbol| {
            if (symbol.birth_pc < std.math.maxInt(u32)) {
                symbol.birth_pc = pc_map[symbol.birth_pc];
                symbol.death_pc = pc_map[symbol.death_pc];
            }
        }
    }

    definition.bytecode_length = @intCast(new_length);
    const resized = utils.realloc(definition.bytecode, @as(usize, new_length) * @sizeOf(u32));
    definition.bytecode = @ptrCast(@alignCast(resized));
}

/// The optimizer for a funcdef's tag, or null where the tag names none.
///
/// The tag is a `JANET_FUN_*` number and zero means an ordinary definition, so
/// the table is indexed by `tag - 1`.
pub fn funopt(flags: functions.FuncDefFlags) ?*const compiler_primitives.FunctionOptimizer {
    const tag = flags.tag;
    if (tag == 0) return null;
    const index = tag - 1;
    if (index >= optimizers.len) return null;
    return &optimizers[index];
}

// ==========================================================================
// Private functions
// ==========================================================================

/// How many arguments a form was given.
fn argumentCount(args: []const compiler_primitives.Slot) i32 {
    return @intCast(args.len);
}

/// The arity predicates the table pairs with a form builder. Each is called
/// before the builder and decides whether the builtin can be folded at all;
/// a false result leaves an ordinary call.
fn arity1or2(_: compiler_primitives.FormOptions, args: []const compiler_primitives.Slot) bool {
    const count = argumentCount(args);
    return count == 1 or count == 2;
}

fn arity2or3(_: compiler_primitives.FormOptions, args: []const compiler_primitives.Slot) bool {
    const count = argumentCount(args);
    return count == 2 or count == 3;
}

fn fixarity1(_: compiler_primitives.FormOptions, args: []const compiler_primitives.Slot) bool {
    return argumentCount(args) == 1;
}

fn fixarity2(_: compiler_primitives.FormOptions, args: []const compiler_primitives.Slot) bool {
    return argumentCount(args) == 2;
}

fn fixarity3(_: compiler_primitives.FormOptions, args: []const compiler_primitives.Slot) bool {
    return argumentCount(args) == 3;
}

fn maxarity1(_: compiler_primitives.FormOptions, args: []const compiler_primitives.Slot) bool {
    return argumentCount(args) <= 1;
}

fn minarity2(_: compiler_primitives.FormOptions, args: []const compiler_primitives.Slot) bool {
    return argumentCount(args) >= 2;
}

/// The comparison chain `<`, `<=`, `>`, `>=`, `=` and `not=` fold to.
///
/// Fewer than two arguments folds to a constant. Otherwise each adjacent pair
/// is compared into the same target and a false result jumps to the end, which
/// is what makes the chain short-circuit.
fn compareReduce(options: compiler_primitives.FormOptions, args: []const compiler_primitives.Slot, opcode: constants.Opcode, immediate_opcode: ?constants.Opcode, invert: bool) compiler_primitives.Slot {
    const count = argumentCount(args);
    if (count < 2) return compiler_primitives.cslot(wrapBoolean(!invert));
    const target = compiler_primitives.gettarget(options);
    const first_instruction = options.compiler.here();
    for (args[1..], 1..) |right, index| {
        if (immediateForm(immediate_opcode, right)) |immediate| {
            _ = emit_core.emitSsi(options.compiler, immediate.opcode, target, args[index - 1], immediate.operand, 1);
        } else {
            _ = emit_core.emitSss(options.compiler, opcode, target, args[index - 1], right, 1);
        }
        if (index != args.len - 1) {
            _ = emit_core.emitSi(options.compiler, if (invert) constants.Opcode.jump_if else constants.Opcode.jump_if_not, target, 0, 1);
        }
    }
    const end = options.compiler.here();
    const region = options.compiler.buffer.items[@intCast(first_instruction)..@intCast(end)];
    for (region, 0..) |*instruction, offset| {
        const opcode_byte = opcodeOf(instruction.*);
        if (opcode_byte == .jump_if or opcode_byte == .jump_if_not) {
            instruction.* |= @as(u32, @intCast(region.len - offset)) << 16;
        }
    }
    return target;
}

/// The builtins that fold to one `opReduce`, `compareReduce`, `genericSS`,
/// `genericSSI` or `opFunction` call, with the opcode and the identity values
/// each needs.
fn doAdd(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return opReduce(o, a, constants.Opcode.add, constants.Opcode.add_immediate, wrap.fromInteger(0), wrap.fromInteger(0));
}

fn doBand(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return opReduce(o, a, constants.Opcode.band, null, wrap.fromInteger(-1), wrap.fromInteger(-1));
}

fn doBnot(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return genericSS(o, constants.Opcode.bnot, a[0]);
}

fn doBor(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return opReduce(o, a, constants.Opcode.bor, null, wrap.fromInteger(0), wrap.fromInteger(0));
}

fn doBxor(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return opReduce(o, a, constants.Opcode.bxor, null, wrap.fromInteger(0), wrap.fromInteger(0));
}

fn doCancel(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return opFunction(o, a, constants.Opcode.cancel, wrapNil());
}

fn doCmp(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return opReduce(o, a, constants.Opcode.compare, null, wrapNil(), wrapNil());
}

fn doDiv(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return opReduce(o, a, constants.Opcode.divide, constants.Opcode.divide_immediate, wrap.fromInteger(1), wrap.fromInteger(1));
}

fn doDivf(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return opReduce(o, a, constants.Opcode.divide_floor, null, wrap.fromInteger(1), wrap.fromInteger(1));
}

fn doEq(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return compareReduce(o, a, constants.Opcode.equals, constants.Opcode.equals_immediate, false);
}

fn doGt(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return compareReduce(o, a, constants.Opcode.greater_than, constants.Opcode.greater_than_immediate, false);
}

fn doGte(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return compareReduce(o, a, constants.Opcode.greater_than_equal, null, false);
}

fn doLength(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return genericSS(o, constants.Opcode.length, a[0]);
}

fn doLshift(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return opReduce(o, a, constants.Opcode.shift_left, constants.Opcode.shift_left_immediate, wrap.fromInteger(1), wrap.fromInteger(1));
}

fn doLt(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return compareReduce(o, a, constants.Opcode.less_than, constants.Opcode.less_than_immediate, false);
}

fn doLte(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return compareReduce(o, a, constants.Opcode.less_than_equal, null, false);
}

fn doModulo(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return opReduce(o, a, constants.Opcode.modulo, null, wrap.fromInteger(0), wrap.fromInteger(1));
}

fn doMul(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return opReduce(o, a, constants.Opcode.multiply, constants.Opcode.multiply_immediate, wrap.fromInteger(1), wrap.fromInteger(1));
}

fn doNeq(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return compareReduce(o, a, constants.Opcode.not_equals, constants.Opcode.not_equals_immediate, true);
}

fn doNext(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return opFunction(o, a, constants.Opcode.next, wrapNil());
}

fn doRemainder(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return opReduce(o, a, constants.Opcode.remainder, null, wrap.fromInteger(0), wrap.fromInteger(1));
}

fn doResume(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return opFunction(o, a, constants.Opcode.@"resume", wrapNil());
}

fn doRshift(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return opReduce(o, a, constants.Opcode.shift_right, constants.Opcode.shift_right_immediate, wrap.fromInteger(1), wrap.fromInteger(1));
}

fn doRshiftu(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return opReduce(o, a, constants.Opcode.shift_right_unsigned, constants.Opcode.shift_right_unsigned_immediate, wrap.fromInteger(1), wrap.fromInteger(1));
}

fn doSub(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return opReduce(o, a, constants.Opcode.subtract, constants.Opcode.subtract_immediate, wrap.fromInteger(0), wrap.fromInteger(0));
}

fn doYield(o: compiler_primitives.FormOptions, a: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return genericSSI(o, constants.Opcode.signal, if (argumentCount(a) == 0) nilSlot() else a[0], 3);
}

/// `apply`, which pushes its middle arguments three at a time and its last
/// one as an array before the call. A tail position emits `.tailcall` and
/// returns a slot already marked returned.
fn doApply(options: compiler_primitives.FormOptions, args: []const compiler_primitives.Slot) compiler_primitives.Slot {
    const count = argumentCount(args);
    var index: i32 = 1;
    while (index < count - 3) : (index += 3) {
        _ = emit_core.emitSss(options.compiler, constants.Opcode.push_3, args[@intCast(index)], args[@intCast(index + 1)], args[@intCast(index + 2)], 0);
    }
    if (index == count - 3) {
        _ = emit_core.emitSs(options.compiler, constants.Opcode.push_2, args[@intCast(index)], args[@intCast(index + 1)], 0);
    } else if (index == count - 2) {
        _ = emit_core.emitSlot(options.compiler, constants.Opcode.push, args[@intCast(index)], 0);
    }
    _ = emit_core.emitSlot(options.compiler, constants.Opcode.push_array, args[@intCast(count - 1)], 0);
    if (options.flags.tail) {
        _ = emit_core.emitSlot(options.compiler, constants.Opcode.tailcall, args[0], 0);
        var target = nilSlot();
        target.flags.returned = true;
        return target;
    }
    const target = compiler_primitives.gettarget(options);
    _ = emit_core.emitSs(options.compiler, constants.Opcode.call, target, args[0], 1);
    return target;
}

/// `debug`, which emits a `.signal` of `abi.Signal.debug` with an optional
/// payload.
fn doDebug(options: compiler_primitives.FormOptions, args: []const compiler_primitives.Slot) compiler_primitives.Slot {
    const target = compiler_primitives.gettarget(options);
    const source = if (argumentCount(args) == 1) args[0] else nilSlot();
    _ = emit_core.emitSsu(options.compiler, constants.Opcode.signal, target, source, @intFromEnum(abi.Signal.debug), 1);
    return target;
}

/// `error`, which emits `.error` and yields a nil slot: nothing after it runs.
fn doError(options: compiler_primitives.FormOptions, args: []const compiler_primitives.Slot) compiler_primitives.Slot {
    _ = emit_core.emitSlot(options.compiler, constants.Opcode.@"error", args[0], 0);
    return nilSlot();
}

/// `get`, which at three arguments emits the lookup, then a jump over a copy
/// of the default.
///
/// Where the target and the default are the same slot the default is copied
/// aside first, because the lookup writes the target before the jump reads the
/// default.
fn doGet(options: compiler_primitives.FormOptions, args: []const compiler_primitives.Slot) compiler_primitives.Slot {
    if (argumentCount(args) != 3) return opReduce(options, args, constants.Opcode.get, null, wrapNil(), wrapNil());
    const target = compiler_primitives.gettarget(options);
    const target_is_default = emit_core.sequal(target, args[2]);
    var default_slot = args[2];
    if (target_is_default) {
        default_slot = compiler_primitives.farslot(options.compiler) orelse nilSlot();
        emit_core.copy(options.compiler, default_slot, target);
    }
    _ = emit_core.emitSss(options.compiler, constants.Opcode.get, target, args[0], args[1], 1);
    const label = emit_core.emitSi(options.compiler, constants.Opcode.jump_if_not_nil, target, 0, 0);
    emit_core.copy(options.compiler, target, default_slot);
    if (target_is_default) compiler_primitives.freeslot(options.compiler, default_slot);
    const current = options.compiler.here();
    options.compiler.buffer.items[@intCast(label)] |= @as(u32, @intCast(current - label)) << 16;
    return target;
}

/// `in`, the lookup that raises rather than defaulting.
fn doIn(options: compiler_primitives.FormOptions, args: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return opReduce(options, args, constants.Opcode.in, null, wrapNil(), wrapNil());
}

/// `propagate`, which re-signals a fiber's result.
fn doPropagate(options: compiler_primitives.FormOptions, args: []const compiler_primitives.Slot) compiler_primitives.Slot {
    return opReduce(options, args, constants.Opcode.propagate, null, wrapNil(), wrapNil());
}

/// `put`, which emits the indexed form where the key is a small integer.
///
/// In drop position it writes through the argument and yields nil; otherwise
/// it copies the data structure into the target first, so that the form has a
/// value.
fn doPut(options: compiler_primitives.FormOptions, args: []const compiler_primitives.Slot) compiler_primitives.Slot {
    const immediate = slotImmediate(args[1]);
    if (options.flags.drop) {
        if (immediate) |index| {
            _ = emit_core.emitSsi(options.compiler, constants.Opcode.put_index, args[0], args[2], index, 0);
        } else {
            _ = emit_core.emitSss(options.compiler, constants.Opcode.put, args[0], args[1], args[2], 0);
        }
        return nilSlot();
    }
    const target = compiler_primitives.gettarget(options);
    emit_core.copy(options.compiler, target, args[0]);
    if (immediate) |index| {
        _ = emit_core.emitSsi(options.compiler, constants.Opcode.put_index, target, args[2], index, 0);
    } else {
        _ = emit_core.emitSss(options.compiler, constants.Opcode.put, target, args[1], args[2], 0);
    }
    return target;
}

/// The instruction word's operand fields, unsigned. `fieldD` and `fieldE` are
/// the wide forms that overlap the narrow ones.
fn fieldA(instruction: u32) i32 {
    return @intCast((instruction >> 8) & 0xff);
}

fn fieldB(instruction: u32) i32 {
    return @intCast((instruction >> 16) & 0xff);
}

fn fieldC(instruction: u32) i32 {
    return @intCast(instruction >> 24);
}

fn fieldD(instruction: u32) i32 {
    return @intCast(instruction >> 8);
}

fn fieldE(instruction: u32) i32 {
    return @intCast(instruction >> 16);
}

/// `op target source`, into a fresh target.
fn genericSS(options: compiler_primitives.FormOptions, opcode: constants.Opcode, source: compiler_primitives.Slot) compiler_primitives.Slot {
    const target = compiler_primitives.gettarget(options);
    _ = emit_core.emitSs(options.compiler, opcode, target, source, 1);
    return target;
}

/// `op target source immediate`, into a fresh target.
fn genericSSI(options: compiler_primitives.FormOptions, opcode: constants.Opcode, source: compiler_primitives.Slot, immediate: i8) compiler_primitives.Slot {
    const target = compiler_primitives.gettarget(options);
    _ = emit_core.emitSsi(options.compiler, opcode, target, source, immediate, 1);
    return target;
}

/// The immediate form of `slot`, where `immediate_opcode` exists and the slot
/// is a constant that fits in eight signed bits.
fn immediateForm(
    immediate_opcode: ?constants.Opcode,
    slot: compiler_primitives.Slot,
) ?ImmediateForm {
    const op = immediate_opcode orelse return null;
    return .{ .opcode = op, .operand = slotImmediate(slot) orelse return null };
}

/// An `i32` as a constant slot.
fn integerSlot(val: i32) compiler_primitives.Slot {
    return compiler_primitives.cslot(wrap.fromInteger(val));
}

/// Marks every register `instruction` reads as taken, so that `bytecodeMovopt`
/// does not eliminate a move into one.
///
/// Listed rather than reached through an `else`: an opcode added later has to
/// state which of its fields are reads, and defaulting to none is the
/// dangerous half.
fn markReads(registers: *regalloc.RegisterAllocator, instruction: u32) void {
    switch (opcodeOf(instruction)) {
        constants.Opcode.jump,
        constants.Opcode.noop,
        constants.Opcode.return_nil,
        constants.Opcode.load_integer,
        constants.Opcode.load_constant,
        constants.Opcode.load_upvalue,
        constants.Opcode.closure,
        constants.Opcode.load_nil,
        constants.Opcode.load_true,
        constants.Opcode.load_false,
        constants.Opcode.load_self,
        => {},

        constants.Opcode.make_array,
        constants.Opcode.make_buffer,
        constants.Opcode.make_string,
        constants.Opcode.make_struct,
        constants.Opcode.make_table,
        constants.Opcode.make_tuple,
        constants.Opcode.make_bracket_tuple,
        constants.Opcode.@"return",
        constants.Opcode.push,
        constants.Opcode.push_array,
        constants.Opcode.tailcall,
        => touch(registers, fieldD(instruction)),

        constants.Opcode.@"error",
        constants.Opcode.typecheck,
        constants.Opcode.jump_if,
        constants.Opcode.jump_if_not,
        constants.Opcode.jump_if_nil,
        constants.Opcode.jump_if_not_nil,
        constants.Opcode.set_upvalue,
        constants.Opcode.move_far,
        => touch(registers, fieldA(instruction)),

        constants.Opcode.signal,
        constants.Opcode.add_immediate,
        constants.Opcode.subtract_immediate,
        constants.Opcode.multiply_immediate,
        constants.Opcode.divide_immediate,
        constants.Opcode.shift_left_immediate,
        constants.Opcode.shift_right_immediate,
        constants.Opcode.shift_right_unsigned_immediate,
        constants.Opcode.greater_than_immediate,
        constants.Opcode.less_than_immediate,
        constants.Opcode.equals_immediate,
        constants.Opcode.not_equals_immediate,
        constants.Opcode.get_index,
        => touch(registers, fieldB(instruction)),

        constants.Opcode.move_near,
        constants.Opcode.length,
        constants.Opcode.bnot,
        constants.Opcode.call,
        => touch(registers, fieldE(instruction)),

        constants.Opcode.put_index => {
            touch(registers, fieldA(instruction));
            touch(registers, fieldB(instruction));
        },

        constants.Opcode.push_2 => {
            touch(registers, fieldA(instruction));
            touch(registers, fieldE(instruction));
        },

        constants.Opcode.propagate,
        constants.Opcode.band,
        constants.Opcode.bor,
        constants.Opcode.bxor,
        constants.Opcode.add,
        constants.Opcode.subtract,
        constants.Opcode.multiply,
        constants.Opcode.divide,
        constants.Opcode.divide_floor,
        constants.Opcode.modulo,
        constants.Opcode.remainder,
        constants.Opcode.shift_left,
        constants.Opcode.shift_right,
        constants.Opcode.shift_right_unsigned,
        constants.Opcode.greater_than,
        constants.Opcode.less_than,
        constants.Opcode.equals,
        constants.Opcode.compare,
        constants.Opcode.in,
        constants.Opcode.get,
        constants.Opcode.greater_than_equal,
        constants.Opcode.less_than_equal,
        constants.Opcode.not_equals,
        constants.Opcode.cancel,
        constants.Opcode.@"resume",
        constants.Opcode.next,
        => {
            touch(registers, fieldB(instruction));
            touch(registers, fieldC(instruction));
        },

        constants.Opcode.put, constants.Opcode.push_3 => {
            touch(registers, fieldA(instruction));
            touch(registers, fieldB(instruction));
            touch(registers, fieldC(instruction));
        },

        else => fatal.fatal("unhandled instruction"),
    }
}

/// Nil as a constant slot.
fn nilSlot() compiler_primitives.Slot {
    return compiler_primitives.cslot(wrapNil());
}

/// A two-operand builtin whose second argument defaults, emitted as
/// `op target arg0 arg1`.
fn opFunction(options: compiler_primitives.FormOptions, args: []const compiler_primitives.Slot, opcode: constants.Opcode, default_value: repr.Value) compiler_primitives.Slot {
    const target = compiler_primitives.gettarget(options);
    const second = if (argumentCount(args) == 1) compiler_primitives.cslot(default_value) else args[1];
    _ = emit_core.emitSss(options.compiler, opcode, target, args[0], second, 1);
    return target;
}

/// The left fold `+`, `*`, `-` and their neighbours share.
///
/// No arguments is the nullary identity and one argument folds against the
/// unary one, except for `-`, which negates through a multiply. Two or more
/// fold left into the target, taking the immediate encoding for any argument
/// that fits it.
fn opReduce(
    options: compiler_primitives.FormOptions,
    args: []const compiler_primitives.Slot,
    opcode: constants.Opcode,
    immediate_opcode: ?constants.Opcode,
    nullary: repr.Value,
    unary: repr.Value,
) compiler_primitives.Slot {
    const count = argumentCount(args);
    if (count == 0) return compiler_primitives.cslot(nullary);
    if (count == 1) {
        const target = compiler_primitives.gettarget(options);
        if (opcode == constants.Opcode.subtract) {
            _ = emit_core.emitSsi(options.compiler, constants.Opcode.multiply_immediate, target, args[0], -1, 1);
        } else {
            _ = emit_core.emitSss(options.compiler, opcode, target, compiler_primitives.cslot(unary), args[0], 1);
        }
        return target;
    }
    const target = compiler_primitives.gettarget(options);
    if (immediateForm(immediate_opcode, args[1])) |immediate| {
        _ = emit_core.emitSsi(options.compiler, immediate.opcode, target, args[0], immediate.operand, 1);
    } else {
        _ = emit_core.emitSss(options.compiler, opcode, target, args[0], args[1], 1);
    }
    for (args[2..]) |arg| {
        if (immediateForm(immediate_opcode, arg)) |immediate| {
            _ = emit_core.emitSsi(options.compiler, immediate.opcode, target, target, immediate.operand, 1);
        } else {
            _ = emit_core.emitSss(options.compiler, opcode, target, target, arg, 1);
        }
    }
    return target;
}

/// The opcode an instruction word has. Bit 7 is the breakpoint bit and is
/// masked off here as it is in `runVm`, so this gives the operation the
/// optimizer is reasoning about rather than whether a debugger stopped on it.
fn opcodeOf(instruction: u32) constants.Opcode {
    return @enumFromInt(@as(u8, @intCast(instruction & 0x7f)));
}

/// A signed instruction field, as an arithmetic right shift of the word
/// reinterpreted as a signed 32-bit integer.
fn signedField(instruction: u32, shift: u5) i32 {
    return @as(i32, @bitCast(instruction)) >> shift;
}

/// `slot` as an eight-bit signed immediate, or null where it is not a constant
/// that fits.
fn slotImmediate(slot: compiler_primitives.Slot) ?i8 {
    if (!slot.flags.constant or !args_core.checkint(slot.constant)) return null;
    const integer: i32 = @intFromFloat(wrap.toNumber(slot.constant));
    if (integer < -128 or integer > 127) return null;
    return @intCast(integer);
}

/// Marks one register taken in `registers`.
fn touch(registers: *regalloc.RegisterAllocator, slot: i32) void {
    registers.touch(@intCast(slot));
}

/// The constants this file builds slots out of.
inline fn wrapBoolean(val: bool) repr.Value {
    return wrap.fromBoolean(val);
}

inline fn wrapNil() repr.Value {
    return wrap.fromNil();
}
