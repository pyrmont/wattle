//! Behavioral contract for the compiler's instruction emitter.
//!
//! `emit.c`'s job is to turn a slot — which may be a near register, a far
//! register, an upvalue, a constant or a reference cell — into the one or two
//! or three instructions that move it where an opcode can reach it. Every
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
//! Each is a `janetc_cerror` call, and none is reachable from Janet source
//! without a program too large to put in a suite -- sixty-five thousand live
//! registers, or a function with more than 0xFFFF constants -- so the only way
//! to see them is to construct the state.
//!
//! They are *recorded* rather than raised: `janetc_error` keeps the first
//! error and returns, so each case clears the status before the next one, and
//! "jump is too far" deliberately emits the truncated instruction anyway. The
//! compile has already failed and the bytecode is never run.
//!
//! ## The emit entry points do not raise
//!
//! They record into `compiler->result` and return, so this contract reaches
//! them through an ordinary call. Reaching a subject by import is for a
//! raise-capable function and there is none here.

const std = @import("std");
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const harness = @import("harness.zig");
const value = @import("subsystems").value;
const compiler_primitives = @import("subsystems").compiler_primitives;
const stretchy = @import("subsystems").stretchy;
const regalloc = @import("subsystems").regalloc;
const emit_core = @import("subsystems").emit_core;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const vector = harness.vector;

var compiler: types.JanetCompiler = undefined;
var scope: types.JanetScope = undefined;

/// A slot built by hand, which is the whole reason this file exists.
fn slot(index: i32, envindex: i32, flags: u32, constant: repr.Value) types.JanetSlot {
    return .{
        .constant = constant,
        .index = index,
        .envindex = envindex,
        .flags = flags,
    };
}

/// A plain near register holding nothing in particular.
fn near(index: i32) types.JanetSlot {
    return slot(index, -1, 0, wrap.fromNil());
}

fn constantSlot(val: repr.Value) types.JanetSlot {
    return slot(-1, 0, constants.JANET_SLOT_CONSTANT, val);
}

fn clearError() void {
    compiler.result.status = constants.JANET_COMPILE_OK;
    compiler.result.@"error" = null;
}

fn clearEmission() void {
    vector.empty(compiler.buffer);
    vector.empty(compiler.mapbuffer);
}

fn emitted(index: usize) u32 {
    return compiler.buffer.?[index];
}

fn emittedCount() i32 {
    return vector.count(compiler.buffer);
}

fn failedWith(message: [*:0]const u8) bool {
    return compiler.result.status == constants.JANET_COMPILE_ERROR and
        harness.stringIs(compiler.result.@"error".?, message);
}

/// The two allocators the emitter draws from. A far register comes off the
/// scope's own allocator and a near one off the eight temporaries, so the
/// first far register is 0 and the first temporary is 1.
fn theTwoAllocators() void {
    std.debug.assert(emit_core.allocfar(&compiler) == 0);
    const temporary = emit_core.allocnear(&compiler, constants.JANETC_REGTEMP_2);
    std.debug.assert(temporary == 1);
    regalloc.regallocFreetemp(&scope.ra, temporary, constants.JANETC_REGTEMP_2);
}

/// Slot equality, which decides whether a copy emits anything at all.
///
/// The type bits are masked off before comparison — that is what makes the
/// first pair equal despite differing flags — and the constant is compared
/// only for the two slot kinds that have one.
fn slotEquality() void {
    const equal = emit_core.sequal;

    std.debug.assert(equal(
        slot(3, -1, 1, harness.wrapInteger(10)),
        slot(3, -1, 2, harness.wrapInteger(20)),
    ) != 0);

    // A non-type flag is not masked off, so mutability distinguishes.
    std.debug.assert(equal(
        slot(3, -1, constants.JANET_SLOT_MUTABLE, wrap.fromNil()),
        slot(3, -1, 0, wrap.fromNil()),
    ) == 0);
    std.debug.assert(equal(near(3), near(4)) == 0);
    std.debug.assert(equal(near(3), slot(3, 0, 0, wrap.fromNil())) == 0);

    // A constant slot compares its value, and so does a reference cell.
    std.debug.assert(equal(
        constantSlot(harness.wrapInteger(10)),
        constantSlot(harness.wrapInteger(10)),
    ) != 0);
    std.debug.assert(equal(
        constantSlot(harness.wrapInteger(10)),
        constantSlot(harness.wrapInteger(20)),
    ) == 0);
    std.debug.assert(equal(
        slot(5, -1, constants.JANET_SLOT_REF, harness.wrapInteger(10)),
        slot(5, -1, constants.JANET_SLOT_REF, harness.wrapInteger(10)),
    ) != 0);
    std.debug.assert(equal(
        slot(5, -1, constants.JANET_SLOT_REF, harness.wrapInteger(10)),
        slot(5, -1, constants.JANET_SLOT_REF, harness.wrapInteger(20)),
    ) == 0);
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

    std.debug.assert(emittedCount() == 100);
    std.debug.assert(vector.count(compiler.mapbuffer) == 100);
    index = 0;
    while (index < 100) : (index += 1) {
        const at: usize = @intCast(index);
        std.debug.assert(emitted(at) == 0x1000 + @as(u32, @intCast(index)));
        std.debug.assert(compiler.mapbuffer.?[at].line == index + 1);
        std.debug.assert(compiler.mapbuffer.?[at].column == index * 2);
    }
}

/// The seven shapes `janetc_copy` picks between, one per case.
///
/// Which one it picks is decided entirely by the two slots: whether each is
/// near (an index that fits in eight bits), far, an upvalue, a constant, or a
/// reference cell. A source program cannot ask for any particular one.
fn theCopies(reference: repr.Value) void {
    // Near to near is a single move.
    clearEmission();
    emit_core.copy(&compiler, near(3), near(7));
    std.debug.assert(emittedCount() == 1);
    std.debug.assert(emitted(0) == harness.op(constants.JOP_MOVE_NEAR) | (3 << 8) | (7 << 16));

    // A small integer constant is loaded as an immediate rather than interned.
    clearEmission();
    emit_core.copy(&compiler, near(4), constantSlot(wrap.fromNumber(-12)));
    std.debug.assert(emitted(0) == harness.op(constants.JOP_LOAD_INTEGER) | (4 << 8) | (0xFFF4 << 16));

    // Anything else goes into the constant pool, and the same value twice
    // interns once.
    clearEmission();
    emit_core.copy(&compiler, near(5), constantSlot(wrap.fromNumber(1.5)));
    emit_core.copy(&compiler, near(6), constantSlot(wrap.fromNumber(1.5)));
    std.debug.assert(vector.count(scope.consts) == 1);
    std.debug.assert(emitted(0) == harness.op(constants.JOP_LOAD_CONSTANT) | (5 << 8));
    std.debug.assert(emitted(1) == harness.op(constants.JOP_LOAD_CONSTANT) | (6 << 8));

    // An upvalue names the environment and the slot within it.
    clearEmission();
    emit_core.copy(&compiler, near(4), slot(2, 1, 0, wrap.fromNil()));
    std.debug.assert(emitted(0) ==
        harness.op(constants.JOP_LOAD_UPVALUE) | (4 << 8) | (1 << 16) | (2 << 24));

    // A far destination reverses the operand order.
    clearEmission();
    emit_core.copy(&compiler, near(300), near(4));
    std.debug.assert(emitted(0) == harness.op(constants.JOP_MOVE_FAR) | (4 << 8) | (300 << 16));

    // Far to upvalue needs a temporary in between, so it is two instructions.
    clearEmission();
    emit_core.copy(&compiler, slot(2, 1, 0, wrap.fromNil()), near(300));
    std.debug.assert(emittedCount() == 2);
    std.debug.assert(emitted(0) == harness.op(constants.JOP_MOVE_NEAR) | (1 << 8) | (300 << 16));
    std.debug.assert(emitted(1) ==
        harness.op(constants.JOP_SET_UPVALUE) | (1 << 8) | (1 << 16) | (2 << 24));

    // A reference cell is a one-element array in the constant pool, so
    // reading one loads the cell and then indexes it.
    clearEmission();
    emit_core.copy(&compiler, near(4), slot(-1, 0, constants.JANET_SLOT_REF, reference));
    std.debug.assert(emittedCount() == 2);
    std.debug.assert(emitted(0) == harness.op(constants.JOP_LOAD_CONSTANT) | (4 << 8) | (1 << 16));
    std.debug.assert(emitted(1) == harness.op(constants.JOP_GET_INDEX) | (4 << 8) | (4 << 16));

    // Writing one is the same shape with a put.
    clearEmission();
    emit_core.copy(&compiler, slot(-1, 0, constants.JANET_SLOT_REF, reference), near(4));
    std.debug.assert(emittedCount() == 2);
    std.debug.assert(emitted(0) == harness.op(constants.JOP_LOAD_CONSTANT) | (1 << 8) | (1 << 16));
    std.debug.assert(emitted(1) == harness.op(constants.JOP_PUT_INDEX) | (1 << 8) | (4 << 16));
}

/// The ten emit entry points, one per operand shape, each asserted on the
/// exact word it produced and on the instruction index it answered.
///
/// The index is the contract as much as the word is: a caller keeps it to
/// patch a jump later, and every one of these returns the position of the
/// instruction it appended.
fn theEmitShapes() void {
    clearEmission();
    const three = near(3);
    const seven = near(7);

    std.debug.assert(emit_core.emitSlot(&compiler, harness.opcode(constants.JOP_RETURN), three, 0) == 0);
    std.debug.assert(emitted(0) == harness.op(constants.JOP_RETURN) | (3 << 8));

    // A jump is a displacement from the instruction *after* the jump, so -2
    // from index 1 encodes as 0xFFFE.
    std.debug.assert(emit_core.emitSl(&compiler, harness.opcode(constants.JOP_JUMP_IF), three, -2) == 1);
    std.debug.assert(emitted(1) == harness.op(constants.JOP_JUMP_IF) | (3 << 8) | (0xFFFE << 16));

    std.debug.assert(emit_core.emitSt(&compiler, harness.opcode(constants.JOP_PUSH_ARRAY), three, 0x1234) == 2);
    std.debug.assert(emitted(2) == harness.op(constants.JOP_PUSH_ARRAY) | (3 << 8) | (0x1234 << 16));

    std.debug.assert(emit_core.emitSi(&compiler, harness.opcode(constants.JOP_ADD_IMMEDIATE), three, -12, 0) == 3);
    std.debug.assert(emitted(3) == harness.op(constants.JOP_ADD_IMMEDIATE) | (3 << 8) | (0xFFF4 << 16));

    std.debug.assert(emit_core.emitSu(&compiler, harness.opcode(constants.JOP_GET_INDEX), three, 0xABCD, 0) == 4);
    std.debug.assert(emitted(4) == harness.op(constants.JOP_GET_INDEX) | (3 << 8) | (0xABCD << 16));

    std.debug.assert(emit_core.emitSs(&compiler, harness.opcode(constants.JOP_MOVE_FAR), three, near(300), 0) == 5);
    std.debug.assert(emitted(5) == harness.op(constants.JOP_MOVE_FAR) | (3 << 8) | (300 << 16));

    std.debug.assert(emit_core.emitSsi(&compiler, harness.opcode(constants.JOP_ADD_IMMEDIATE), three, seven, -3, 0) == 6);
    std.debug.assert(emitted(6) ==
        harness.op(constants.JOP_ADD_IMMEDIATE) | (3 << 8) | (7 << 16) | (0xFD << 24));

    std.debug.assert(emit_core.emitSsu(&compiler, harness.opcode(constants.JOP_GET), three, seven, 250, 0) == 7);
    std.debug.assert(emitted(7) == harness.op(constants.JOP_GET) | (3 << 8) | (7 << 16) | (250 << 24));

    std.debug.assert(emit_core.emitSss(&compiler, harness.opcode(constants.JOP_ADD), three, seven, near(9), 0) == 8);
    std.debug.assert(emitted(8) == harness.op(constants.JOP_ADD) | (3 << 8) | (7 << 16) | (9 << 24));
}

/// A far slot in an instruction that has only eight bits for it is moved into
/// a temporary, operated on, and — when the caller asks for a write-back —
/// moved out again. Three instructions where the caller wrote one.
fn theWriteBack() void {
    clearEmission();
    std.debug.assert(emit_core.emitSi(
        &compiler,
        harness.opcode(constants.JOP_ADD_IMMEDIATE),
        near(300),
        7,
        1,
    ) == 1);
    std.debug.assert(emittedCount() == 3);
    std.debug.assert(emitted(0) == harness.op(constants.JOP_MOVE_NEAR) | (1 << 8) | (300 << 16));
    std.debug.assert(emitted(1) == harness.op(constants.JOP_ADD_IMMEDIATE) | (1 << 8) | (7 << 16));
    std.debug.assert(emitted(2) == harness.op(constants.JOP_MOVE_FAR) | (1 << 8) | (300 << 16));
}

/// The same for a constant operand: it is loaded into a register first, so the
/// answered index is the second instruction rather than the first.
fn aConstantOperandIsLoadedFirst() void {
    clearEmission();
    std.debug.assert(emit_core.emitSlot(
        &compiler,
        harness.opcode(constants.JOP_RETURN),
        constantSlot(wrap.fromNumber(1.5)),
        0,
    ) == 1);
    std.debug.assert(emittedCount() == 2);
    std.debug.assert(emitted(0) == harness.op(constants.JOP_LOAD_CONSTANT) | (1 << 8));
    std.debug.assert(emitted(1) == harness.op(constants.JOP_RETURN) | (1 << 8));

    std.debug.assert(emittedCount() == vector.count(compiler.mapbuffer));
}

/// Writing to a constant slot, which is the emitter's own type error.
fn aConstantCannotBeWritten() void {
    clearError();
    emit_core.copy(
        &compiler,
        slot(-1, -1, constants.JANET_SLOT_CONSTANT, harness.wrapInteger(7)),
        near(0),
    );
    std.debug.assert(failedWith("cannot write to constant"));
}

/// A jump whose displacement does not fit in the signed sixteen bits the
/// instruction carries, in both directions — and the boundary that does.
fn aJumpMayBeTooFar() void {
    clearError();
    clearEmission();
    emit_core.emit(&compiler, harness.op(constants.JOP_NOOP));
    _ = emit_core.emitSl(&compiler, harness.opcode(constants.JOP_JUMP_IF), near(0), 0x7FFFF);
    std.debug.assert(failedWith("jump is too far"));
    // Emitted anyway: the compile has failed and the bytecode is never run.
    std.debug.assert(emittedCount() == 2);

    clearError();
    clearEmission();
    emit_core.emit(&compiler, harness.op(constants.JOP_NOOP));
    _ = emit_core.emitSl(&compiler, harness.opcode(constants.JOP_JUMP_IF), near(0), -0x7FFFF);
    std.debug.assert(failedWith("jump is too far"));

    // A displacement that only just fits reports nothing. It is measured from
    // the instruction after the jump, which is why the NOOP matters.
    clearError();
    clearEmission();
    emit_core.emit(&compiler, harness.op(constants.JOP_NOOP));
    _ = emit_core.emitSl(&compiler, harness.opcode(constants.JOP_JUMP_IF), near(0), std.math.maxInt(i16));
    std.debug.assert(compiler.result.status == constants.JANET_COMPILE_OK);
}

/// Far registers past the sixteen bits an instruction has for one.
///
/// `janetc_regalloc_1` hands out the whole 32-bit range and takes the lowest
/// free bit, so the ceiling is the emitter's to enforce and reaching it means
/// marking everything below it as taken.
fn theRegisterCeiling() void {
    var full: types.JanetScope = std.mem.zeroes(types.JanetScope);
    full.flags = constants.JANET_SCOPE_FUNCTION;
    regalloc.regallocInit(&full.ra);
    defer regalloc.regallocDeinit(&full.ra);

    regalloc.regallocTouch(&full.ra, 0xFFFF);
    var chunk: i32 = 0;
    while (chunk < full.ra.count) : (chunk += 1) {
        full.ra.chunks.?[@intCast(chunk)] = 0xFFFFFFFF;
    }
    compiler.scope = &full;
    defer compiler.scope = &scope;

    clearError();
    std.debug.assert(emit_core.allocfar(&compiler) > 0xFFFF);
    std.debug.assert(failedWith("ran out of internal registers"));

    // The same ceiling through `janetc_farslot`, which lives in
    // `compiler_primitives` and reports the same message.
    clearError();
    _ = compiler_primitives.farslot(&compiler);
    std.debug.assert(failedWith("ran out of internal registers"));
}

/// "too many constants" is reported when the function's constant pool is
/// full, which is 0xFFFF entries.
///
/// Filling it honestly is quadratic — the pool is searched linearly on every
/// insert — so the vector is grown once and its count set directly, with every
/// entry a distinct value so that the search finds no match and tries to
/// append.
fn theConstantPoolFills() void {
    var full: types.JanetScope = std.mem.zeroes(types.JanetScope);
    full.flags = constants.JANET_SCOPE_FUNCTION;
    regalloc.regallocInit(&full.ra);
    defer regalloc.regallocDeinit(&full.ra);

    var index: i32 = 0;
    while (index < 8) : (index += 1) {
        vector.push(&full.consts, wrap.fromNumber(1000.0 + @as(f64, @floatFromInt(index))));
    }
    full.consts = @ptrCast(@alignCast(stretchy.vGrow(full.consts, 0xFFFF, @sizeOf(repr.Value))));
    index = 0;
    while (index < 0xFFFF) : (index += 1) {
        full.consts.?[@intCast(index)] = wrap.fromNumber(1000.0 + @as(f64, @floatFromInt(index)));
    }
    vector.setCount(full.consts, 0xFFFF);
    defer vector.free(full.consts);

    compiler.scope = &full;
    defer compiler.scope = &scope;

    clearError();
    clearEmission();
    _ = emit_core.emitSlot(
        &compiler,
        harness.opcode(constants.JOP_RETURN),
        constantSlot(wrap.fromNumber(2.5)),
        0,
    );
    std.debug.assert(failedWith("too many constants"));
}

pub fn run() void {
    harness.init();

    compiler = std.mem.zeroes(types.JanetCompiler);
    scope = std.mem.zeroes(types.JanetScope);
    compiler.scope = &scope;
    scope.flags = constants.JANET_SCOPE_FUNCTION;
    regalloc.regallocInit(&scope.ra);

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
    theConstantPoolFills();

    vector.free(compiler.buffer);
    vector.free(compiler.mapbuffer);
    vector.free(scope.consts);
    regalloc.regallocDeinit(&scope.ra);
    vm_lifecycle.deinit();
}
