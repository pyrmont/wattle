//! Behavioral contract for the compiler's instruction emitter.
//!
//! The emitter turns a slot, which may be a near register, a far register, an
//! upvalue, a constant or a reference cell, into the one or two or three
//! instructions that move it where an opcode can reach it. Every
//! Janet program exercises the common paths, and none of the suites can aim
//! at a particular one: the emitter is chosen by the *compiler*, from slots
//! the compiler allocated, so a source program that provokes a far-register
//! copy is an accident of register pressure rather than something a test can
//! ask for.
//!
//! So this file builds the slots by hand and asserts the exact word emitted.
//!
//! ## The four failures, and why they are here
//!
//! None is reachable from Janet source without a program too large to put in a
//! suite, needing sixty-five thousand live registers or a function with more
//! than 0xFFFF constants, so the only way to see them is to construct the
//! state.
//!
//! They are *recorded* rather than raised: the compiler keeps the first error
//! and returns, so each case clears the status before the next one, and
//! "jump is too far" deliberately emits the truncated instruction anyway. The
//! compile has already failed and the bytecode is never run.
//!
//! ## The emit entry points do not raise
//!
//! They record into `compiler->result` and return, so this contract reaches
//! them through an ordinary call. Reaching a subject by import is for a
//! raise-capable function and there is none here.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const compiler_primitives = @import("subsystems").compiler_primitives;
const constants = @import("constants");
const emit_core = @import("subsystems").emit_core;
const expect = @import("expect.zig").expect;
const harness = @import("harness.zig");
const repr = @import("repr");
const value = @import("subsystems").value;
const vector = harness.vector;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

var compiler: compiler_primitives.Compiler = undefined;
var scope: compiler_primitives.Scope = undefined;

// ==========================================================================
// Cases
// ==========================================================================

/// A slot built by hand, which is the whole reason this file exists.
fn slot(index: i32, envindex: i32, flags: compiler_primitives.SlotFlags, constant: repr.Value) compiler_primitives.Slot {
    return .{
        .constant = constant,
        .index = index,
        .envindex = envindex,
        .flags = flags,
    };
}

/// A plain near register with no type bits set.
fn near(index: i32) compiler_primitives.Slot {
    return slot(index, -1, .{}, wrap.fromNil());
}

fn constantSlot(val: repr.Value) compiler_primitives.Slot {
    return slot(-1, 0, .{ .constant = true }, val);
}

fn clearError() void {
    compiler.result.status = compiler_primitives.CompileStatus.ok;
    compiler.result.@"error" = null;
}

fn clearEmission() void {
    vector.empty(&compiler.buffer);
    vector.empty(&compiler.mapbuffer);
}

fn emitted(index: usize) u32 {
    return compiler.buffer.items[index];
}

fn emittedCount() i32 {
    return @intCast(vector.count(compiler.buffer));
}

fn failedWith(message: [*:0]const u8) bool {
    return compiler.result.status == compiler_primitives.CompileStatus.@"error" and
        harness.stringIs(compiler.result.@"error".?, message);
}

/// The two allocators the emitter draws from. A far register comes off the
/// scope's own allocator and a near one off the eight temporaries, so the
/// first far register is 0 and the first temporary is 1.
fn theTwoAllocators() void {
    expect(emit_core.allocfar(&compiler) == 0);
    const temporary = emit_core.allocnear(&compiler, constants.RegisterTemp.t2);
    expect(temporary == 1);
    scope.ra.freeTemp(temporary, constants.RegisterTemp.t2);
}

/// Slot equality, which decides whether a copy emits anything at all.
///
/// The type bits are masked off before comparison, which is what makes the
/// first pair equal despite differing flags, and the constant is compared
/// only for the two slot kinds that have one.
fn slotEquality() void {
    const equal = emit_core.sequal;

    expect(equal(
        slot(3, -1, .{ .types = .one(.number) }, harness.wrapInteger(10)),
        slot(3, -1, .{ .types = .one(.nil) }, harness.wrapInteger(20)),
    ));

    // A non-type flag is not masked off, so mutability distinguishes.
    expect(!equal(
        slot(3, -1, .{ .mutable = true }, wrap.fromNil()),
        slot(3, -1, .{}, wrap.fromNil()),
    ));
    expect(!equal(near(3), near(4)));
    expect(!equal(near(3), slot(3, 0, .{}, wrap.fromNil())));

    // A constant slot compares its value, and so does a reference cell.
    expect(equal(
        constantSlot(harness.wrapInteger(10)),
        constantSlot(harness.wrapInteger(10)),
    ));
    expect(!equal(
        constantSlot(harness.wrapInteger(10)),
        constantSlot(harness.wrapInteger(20)),
    ));
    expect(equal(
        slot(5, -1, .{ .ref = true }, harness.wrapInteger(10)),
        slot(5, -1, .{ .ref = true }, harness.wrapInteger(10)),
    ));
    expect(!equal(
        slot(5, -1, .{ .ref = true }, harness.wrapInteger(10)),
        slot(5, -1, .{ .ref = true }, harness.wrapInteger(20)),
    ));
}

/// Every emitted instruction appends one source-mapping entry, so the two
/// vectors stay the same length. That invariant is what a debugger and a
/// stack trace rest on.
fn theSourceMapKeepsPace() void {
    var index: i32 = 0;
    while (index < 100) : (index += 1) {
        compiler.current_mapping.line = index + 1;
        compiler.current_mapping.column = index * 2;
        emit_core.emit(&compiler, 0x1000 + @as(u32, @intCast(index)));
    }

    expect(emittedCount() == 100);
    expect(vector.count(compiler.mapbuffer) == 100);
    index = 0;
    while (index < 100) : (index += 1) {
        const at: usize = @intCast(index);
        expect(emitted(at) == 0x1000 + @as(u32, @intCast(index)));
        expect(compiler.mapbuffer.items[at].line == index + 1);
        expect(compiler.mapbuffer.items[at].column == index * 2);
    }
}

/// The seven shapes `emit_core.copy` picks between, one per case.
///
/// Which one it picks is decided entirely by the two slots: whether each is
/// near (an index that fits in eight bits), far, an upvalue, a constant, or a
/// reference cell. A source program cannot ask for any particular one.
fn theCopies(reference: repr.Value) void {
    // Near to near is a single move.
    clearEmission();
    emit_core.copy(&compiler, near(3), near(7));
    expect(emittedCount() == 1);
    expect(emitted(0) == harness.op(constants.Opcode.move_near) | (3 << 8) | (7 << 16));

    // A small integer constant is loaded as an immediate rather than interned.
    clearEmission();
    emit_core.copy(&compiler, near(4), constantSlot(wrap.fromNumber(-12)));
    expect(emitted(0) == harness.op(constants.Opcode.load_integer) | (4 << 8) | (0xFFF4 << 16));

    // Anything else goes into the constant pool, and the same value twice
    // interns once.
    clearEmission();
    emit_core.copy(&compiler, near(5), constantSlot(wrap.fromNumber(1.5)));
    emit_core.copy(&compiler, near(6), constantSlot(wrap.fromNumber(1.5)));
    expect(vector.count(scope.consts) == 1);
    expect(emitted(0) == harness.op(constants.Opcode.load_constant) | (5 << 8));
    expect(emitted(1) == harness.op(constants.Opcode.load_constant) | (6 << 8));

    // An upvalue names the environment and the slot within it.
    clearEmission();
    emit_core.copy(&compiler, near(4), slot(2, 1, .{}, wrap.fromNil()));
    expect(emitted(0) ==
        harness.op(constants.Opcode.load_upvalue) | (4 << 8) | (1 << 16) | (2 << 24));

    // A far destination reverses the operand order.
    clearEmission();
    emit_core.copy(&compiler, near(300), near(4));
    expect(emitted(0) == harness.op(constants.Opcode.move_far) | (4 << 8) | (300 << 16));

    // Far to upvalue needs a temporary in between, so it is two instructions.
    clearEmission();
    emit_core.copy(&compiler, slot(2, 1, .{}, wrap.fromNil()), near(300));
    expect(emittedCount() == 2);
    expect(emitted(0) == harness.op(constants.Opcode.move_near) | (1 << 8) | (300 << 16));
    expect(emitted(1) ==
        harness.op(constants.Opcode.set_upvalue) | (1 << 8) | (1 << 16) | (2 << 24));

    // A reference cell is a one-element array in the constant pool, so
    // reading one loads the cell and then indexes it.
    clearEmission();
    emit_core.copy(&compiler, near(4), slot(-1, 0, .{ .ref = true }, reference));
    expect(emittedCount() == 2);
    expect(emitted(0) == harness.op(constants.Opcode.load_constant) | (4 << 8) | (1 << 16));
    expect(emitted(1) == harness.op(constants.Opcode.get_index) | (4 << 8) | (4 << 16));

    // Writing one is the same shape with a put.
    clearEmission();
    emit_core.copy(&compiler, slot(-1, 0, .{ .ref = true }, reference), near(4));
    expect(emittedCount() == 2);
    expect(emitted(0) == harness.op(constants.Opcode.load_constant) | (1 << 8) | (1 << 16));
    expect(emitted(1) == harness.op(constants.Opcode.put_index) | (1 << 8) | (4 << 16));
}

/// The ten emit entry points, one per operand shape, each asserted on the
/// exact word it produced and on the instruction index it returned.
///
/// The index is the contract as much as the word is: a caller keeps it to
/// patch a jump later, and every one of these returns the position of the
/// instruction it appended.
fn theEmitShapes() void {
    clearEmission();
    const three = near(3);
    const seven = near(7);

    expect(emit_core.emitSlot(&compiler, constants.Opcode.@"return", three, 0) == 0);
    expect(emitted(0) == harness.op(constants.Opcode.@"return") | (3 << 8));

    // A jump is a displacement from the instruction *after* the jump, so -2
    // from index 1 encodes as 0xFFFE.
    expect(emit_core.emitSl(&compiler, constants.Opcode.jump_if, three, -2) == 1);
    expect(emitted(1) == harness.op(constants.Opcode.jump_if) | (3 << 8) | (0xFFFE << 16));

    expect(emit_core.emitSt(&compiler, constants.Opcode.push_array, three, 0x1234) == 2);
    expect(emitted(2) == harness.op(constants.Opcode.push_array) | (3 << 8) | (0x1234 << 16));

    expect(emit_core.emitSi(&compiler, constants.Opcode.add_immediate, three, -12, 0) == 3);
    expect(emitted(3) == harness.op(constants.Opcode.add_immediate) | (3 << 8) | (0xFFF4 << 16));

    expect(emit_core.emitSu(&compiler, constants.Opcode.get_index, three, 0xABCD, 0) == 4);
    expect(emitted(4) == harness.op(constants.Opcode.get_index) | (3 << 8) | (0xABCD << 16));

    expect(emit_core.emitSs(&compiler, constants.Opcode.move_far, three, near(300), 0) == 5);
    expect(emitted(5) == harness.op(constants.Opcode.move_far) | (3 << 8) | (300 << 16));

    expect(emit_core.emitSsi(&compiler, constants.Opcode.add_immediate, three, seven, -3, 0) == 6);
    expect(emitted(6) ==
        harness.op(constants.Opcode.add_immediate) | (3 << 8) | (7 << 16) | (0xFD << 24));

    expect(emit_core.emitSsu(&compiler, constants.Opcode.get, three, seven, 250, 0) == 7);
    expect(emitted(7) == harness.op(constants.Opcode.get) | (3 << 8) | (7 << 16) | (250 << 24));

    expect(emit_core.emitSss(&compiler, constants.Opcode.add, three, seven, near(9), 0) == 8);
    expect(emitted(8) == harness.op(constants.Opcode.add) | (3 << 8) | (7 << 16) | (9 << 24));
}

/// A far slot in an instruction that has only eight bits for it is moved into
/// a temporary, operated on, and, when the caller asks for a write-back,
/// moved out again. Three instructions where the caller wrote one.
fn theWriteBack() void {
    clearEmission();
    expect(emit_core.emitSi(
        &compiler,
        constants.Opcode.add_immediate,
        near(300),
        7,
        1,
    ) == 1);
    expect(emittedCount() == 3);
    expect(emitted(0) == harness.op(constants.Opcode.move_near) | (1 << 8) | (300 << 16));
    expect(emitted(1) == harness.op(constants.Opcode.add_immediate) | (1 << 8) | (7 << 16));
    expect(emitted(2) == harness.op(constants.Opcode.move_far) | (1 << 8) | (300 << 16));
}

/// The same for a constant operand: it is loaded into a register first, so the
/// returned index is the second instruction rather than the first.
fn aConstantOperandIsLoadedFirst() void {
    clearEmission();
    expect(emit_core.emitSlot(
        &compiler,
        constants.Opcode.@"return",
        constantSlot(wrap.fromNumber(1.5)),
        0,
    ) == 1);
    expect(emittedCount() == 2);
    expect(emitted(0) == harness.op(constants.Opcode.load_constant) | (1 << 8));
    expect(emitted(1) == harness.op(constants.Opcode.@"return") | (1 << 8));

    expect(emittedCount() == vector.count(compiler.mapbuffer));
}

/// Writing to a constant slot, which is the emitter's own type error.
fn aConstantCannotBeWritten() void {
    clearError();
    emit_core.copy(
        &compiler,
        slot(-1, -1, .{ .constant = true }, harness.wrapInteger(7)),
        near(0),
    );
    expect(failedWith("cannot write to constant"));
}

/// A jump whose displacement does not fit in the signed sixteen bits the
/// instruction has room for, in both directions, and the boundary that does.
fn aJumpMayBeTooFar() void {
    clearError();
    clearEmission();
    emit_core.emit(&compiler, harness.op(constants.Opcode.noop));
    _ = emit_core.emitSl(&compiler, constants.Opcode.jump_if, near(0), 0x7FFFF);
    expect(failedWith("jump is too far"));
    // Emitted anyway: the compile has failed and the bytecode is never run.
    expect(emittedCount() == 2);

    clearError();
    clearEmission();
    emit_core.emit(&compiler, harness.op(constants.Opcode.noop));
    _ = emit_core.emitSl(&compiler, constants.Opcode.jump_if, near(0), -0x7FFFF);
    expect(failedWith("jump is too far"));

    // A displacement that only just fits reports nothing. It is measured from
    // the instruction after the jump, so the NOOP is what makes it reachable.
    // Both ends, because each end is its own comparison.
    clearError();
    clearEmission();
    emit_core.emit(&compiler, harness.op(constants.Opcode.noop));
    _ = emit_core.emitSl(&compiler, constants.Opcode.jump_if, near(0), std.math.maxInt(i16));
    expect(compiler.result.status == compiler_primitives.CompileStatus.ok);

    clearError();
    clearEmission();
    emit_core.emit(&compiler, harness.op(constants.Opcode.noop));
    _ = emit_core.emitSl(&compiler, constants.Opcode.jump_if, near(0), std.math.minInt(i16));
    expect(compiler.result.status == compiler_primitives.CompileStatus.ok);
}

/// The last register an instruction can name, which is 0xFFFF, and which both
/// allocators must hand out rather than refuse.
///
/// `theRegisterCeiling` marks every register taken and so measures the first
/// register past the ceiling. This measures the last one below it, which is
/// the value the comparison is written against.
fn theLastRegisterIsUsable() void {
    var last: compiler_primitives.Scope = .{ .name = "last" };
    last.flags = compiler_primitives.ScopeFlags{ .function = true };
    last.ra = .{};
    defer last.ra.deinit();

    last.ra.touch(0xFFFF);
    for (last.ra.chunks.items) |*chunk| chunk.* = 0xFFFFFFFF;
    last.ra.free(0xFFFF);
    compiler.scope = &last;
    defer compiler.scope = &scope;

    clearError();
    expect(emit_core.allocfar(&compiler) == 0xFFFF);
    expect(compiler.result.status == compiler_primitives.CompileStatus.ok);

    last.ra.free(0xFFFF);
    clearError();
    const far = compiler_primitives.farslot(&compiler).?;
    expect(far.index == 0xFFFF);
    expect(compiler.result.status == compiler_primitives.CompileStatus.ok);
}

/// The register that just fits in eight bits, which is 0xFF, on each of the
/// four tests that ask whether a slot is near.
///
/// A copy picks its shape from the destination first and the source second,
/// and an operand picks whether it needs a temporary at all, so 0xFF is
/// asserted once per test rather than once.
fn theBoundariesOfNear(reference: repr.Value) void {
    // A destination of 0xFF is near, so the copy is one move rather than a
    // reversed one.
    clearEmission();
    emit_core.copy(&compiler, near(0xFF), near(4));
    expect(emittedCount() == 1);
    expect(emitted(0) == harness.op(constants.Opcode.move_near) | (0xFF << 8) | (4 << 16));

    // A source of 0xFF is near, so a far destination is written in one.
    clearEmission();
    emit_core.copy(&compiler, near(300), near(0xFF));
    expect(emittedCount() == 1);
    expect(emitted(0) == harness.op(constants.Opcode.move_far) | (0xFF << 8) | (300 << 16));

    // So is a source of 0, which is the other end of the same test.
    clearEmission();
    emit_core.copy(&compiler, near(300), near(0));
    expect(emittedCount() == 1);
    expect(emitted(0) == harness.op(constants.Opcode.move_far) | (0 << 8) | (300 << 16));

    // An upvalue in environment 0 is not a register, whatever its index, so
    // it goes through a temporary.
    clearEmission();
    emit_core.copy(&compiler, near(300), slot(2, 0, .{}, wrap.fromNil()));
    expect(emittedCount() == 2);
    expect(emitted(0) ==
        harness.op(constants.Opcode.load_upvalue) | (1 << 8) | (0 << 16) | (2 << 24));
    expect(emitted(1) == harness.op(constants.Opcode.move_far) | (1 << 8) | (300 << 16));

    // Writing 0xFF into an upvalue reads the register directly.
    clearEmission();
    emit_core.copy(&compiler, slot(2, 1, .{}, wrap.fromNil()), near(0xFF));
    expect(emittedCount() == 1);
    expect(emitted(0) ==
        harness.op(constants.Opcode.set_upvalue) | (0xFF << 8) | (1 << 16) | (2 << 24));

    // And an operand of 0xFF is emitted where it stands. The shape has to be
    // one of the four with an eight-bit slot field: `emitSlot` has sixteen
    // bits for its slot and asks a different question of it.
    clearEmission();
    expect(emit_core.emitSt(&compiler, constants.Opcode.push_array, near(0xFF), 0x1234) == 0);
    expect(emittedCount() == 1);
    expect(emitted(0) ==
        harness.op(constants.Opcode.push_array) | (0xFF << 8) | (0x1234 << 16));

    _ = reference;
}

/// The write-back argument each emit entry point passes, read through the
/// instruction count: a far operand costs two instructions without a
/// write-back and three with one.
fn theWriteBackArguments() void {
    clearEmission();
    _ = emit_core.emitSl(&compiler, constants.Opcode.jump_if, near(300), 0);
    expect(emittedCount() == 2);

    clearEmission();
    _ = emit_core.emitSt(&compiler, constants.Opcode.push_array, near(300), 0x1234);
    expect(emittedCount() == 2);

    clearEmission();
    _ = emit_core.emitSu(&compiler, constants.Opcode.get_index, near(300), 0xABCD, 0);
    expect(emittedCount() == 2);

    clearEmission();
    _ = emit_core.emitSu(&compiler, constants.Opcode.get_index, near(300), 0xABCD, 1);
    expect(emittedCount() == 3);
}

/// Far registers past the sixteen bits an instruction has for one.
///
/// `RegisterAllocator.allocate` hands out the whole 32-bit range and takes the
/// lowest free bit, so the ceiling is the emitter's to enforce and reaching it
/// means marking everything below it as taken.
fn theRegisterCeiling() void {
    var full: compiler_primitives.Scope = .{ .name = "full" };
    full.flags = compiler_primitives.ScopeFlags{ .function = true };
    full.ra = .{};
    defer full.ra.deinit();

    full.ra.touch(0xFFFF);
    for (full.ra.chunks.items) |*chunk| chunk.* = 0xFFFFFFFF;
    compiler.scope = &full;
    defer compiler.scope = &scope;

    clearError();
    expect(emit_core.allocfar(&compiler) > 0xFFFF);
    expect(failedWith("ran out of internal registers"));

    // The same ceiling through `farslot`, which lives in
    // `compiler_primitives` and reports the same message.
    clearError();
    // Nothing comes back as well as the report, so a caller cannot read a
    // register the allocator never produced.
    expect(compiler_primitives.farslot(&compiler) == null);
    expect(failedWith("ran out of internal registers"));
}

/// "too many constants" is reported when the function's constant pool is
/// full, which is 0xFFFF entries.
///
/// Filling it honestly is quadratic, the pool being searched linearly on every
/// insert, so the vector is grown once and its count set directly, with every
/// entry a distinct value so that the search finds no match and tries to
/// append.
fn theConstantPoolFills() void {
    var full: compiler_primitives.Scope = .{ .name = "full" };
    full.flags = compiler_primitives.ScopeFlags{ .function = true };
    full.ra = .{};
    defer full.ra.deinit();

    // `harness.vector`'s `setCount` reserves the room and then claims it, which
    // is what fills the pool without the quadratic cost of pushing 0xFFFF
    // constants one at a time.
    vector.setCount(&full.consts, 0xFFFF);
    for (full.consts.items, 0..) |*constant, index| {
        constant.* = wrap.fromNumber(1000.0 + @as(f64, @floatFromInt(index)));
    }
    defer vector.free(&full.consts);

    compiler.scope = &full;
    defer compiler.scope = &scope;

    clearError();
    clearEmission();
    _ = emit_core.emitSlot(
        &compiler,
        constants.Opcode.@"return",
        constantSlot(wrap.fromNumber(2.5)),
        0,
    );
    expect(failedWith("too many constants"));
}

// ==========================================================================
// Entry
// ==========================================================================

pub fn run() void {
    harness.init();

    compiler = .{};
    scope = .{ .name = "" };
    compiler.scope = &scope;
    scope.flags = compiler_primitives.ScopeFlags{ .function = true };
    scope.ra = .{};

    const reference = value.fromBytes("reference-cell", .string);

    theTwoAllocators();
    slotEquality();
    theSourceMapKeepsPace();
    theCopies(reference);
    theEmitShapes();
    theWriteBack();
    aConstantOperandIsLoadedFirst();
    aConstantCannotBeWritten();
    aJumpMayBeTooFar();
    theRegisterCeiling();
    theLastRegisterIsUsable();
    theBoundariesOfNear(reference);
    theWriteBackArguments();
    theConstantPoolFills();

    vector.free(&compiler.buffer);
    vector.free(&compiler.mapbuffer);
    vector.free(&scope.consts);
    scope.ra.deinit();
    vm_lifecycle.deinit();
}
