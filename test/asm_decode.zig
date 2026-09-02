//! Behavioral contract for `bytecode/disasm.zig`'s `asmDecodeInstruction`: one
//! bytecode word turned back into the tuple the assembler would have written.
//!
//! `disasm` reaches this for every instruction of a function, so the Janet
//! suites exercise it heavily and observe almost nothing about it — a
//! disassembly that decoded an operand wrongly still looks like a
//! disassembly. What is pinned here is the *shape* each instruction type
//! produces, and in particular the three ways an operand byte can be read.
//!
//! ## The three readings of the same bits
//!
//! An operand is not just a number, and the whole point of the instruction
//! table is to say which of these each field is:
//!
//!   - **unsigned**, as a slot index or a constant index;
//!   - **signed**, as a jump displacement or a small integer literal, where
//!     `0xFFFFFE` in the top three bytes is -2 rather than 16,777,214;
//!   - **unsigned again in a field that looks signed**, which
//!     `JOP_SHIFT_RIGHT_UNSIGNED_IMMEDIATE` is: its 8-bit immediate reads as
//!     253 where `JOP_ADD_IMMEDIATE`'s reads as -3 from the identical byte.
//!
//! That last pair is the assertion worth having. The two instructions differ
//! only in their table row, so a row shifted by one turns 253 into -3 and
//! nothing else notices.
//!
//! ## The two edges
//!
//! An unknown opcode decodes to the raw word as a *number* rather than to a
//! tuple, which is how a disassembly of corrupt bytecode stays printable. And
//! bit 7 of the word is the breakpoint flag: it is not part of the opcode, and
//! it comes back as the tuple's bracket-constructor flag rather than as an
//! operand.

const repr = @import("repr");
const constants = @import("constants");
const harness = @import("harness.zig");
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const disasm = @import("subsystems").disasm;
const tuples = @import("subsystems").value.tuples;
const expect = @import("expect.zig").expect;

/// Decode, and assert the instruction is the named one with `length` fields.
fn decoded(instruction: u32, length: i32, name: [*:0]const u8) [*]const repr.Value {
    const val = disasm.asmDecodeInstruction(instruction);
    expect(harness.isType(val, repr.Tag.tuple));
    const tuple = wrap.toTuple(val);
    expect(tuples.head(tuple).length == length);
    expect(harness.symbolIs(tuple[0], name));
    return tuple;
}

fn anUnknownOpcodeStaysANumber() void {
    // 0x7F is not an opcode, so this word has no row to decode against.
    const val = disasm.asmDecodeInstruction(0x1234567F);
    expect(harness.isType(val, repr.Tag.number));
    expect(@as(u32, @bitCast(wrap.toInteger(val))) == 0x1234567F);
}

fn theOperandShapes() void {
    // No operands.
    const noop = decoded(harness.op(constants.Opcode.noop), 1, "noop");
    expect((harness.gcBits(tuples.head(noop).gc.flags) & constants.JANET_TUPLE_FLAG_BRACKETCTOR) == 0);

    // One unsigned 24-bit field.
    const err = decoded(harness.op(constants.Opcode.@"error") | (@as(u32, 0x123456) << 8), 2, "err");
    expect(harness.integerIs(err[1], 0x123456));

    // One *signed* 24-bit field: the same bit width, read the other way.
    const jmp = decoded(harness.op(constants.Opcode.jump) | (@as(u32, 0xFFFFFE) << 8), 2, "jmp");
    expect(harness.integerIs(jmp[1], -2));

    // A slot and an unsigned 16-bit field.
    const movn = decoded(
        harness.op(constants.Opcode.move_near) | (@as(u32, 7) << 8) | (@as(u32, 300) << 16),
        3,
        "movn",
    );
    expect(harness.integerIs(movn[1], 7));
    expect(harness.integerIs(movn[2], 300));

    // A slot and a signed 16-bit field.
    const ldi = decoded(
        harness.op(constants.Opcode.load_integer) | (@as(u32, 5) << 8) | (@as(u32, 0xFFF4) << 16),
        3,
        "ldi",
    );
    expect(harness.integerIs(ldi[1], 5));
    expect(harness.integerIs(ldi[2], -12));

    // Three slots.
    const add = decoded(
        harness.op(constants.Opcode.add) | (@as(u32, 3) << 8) | (@as(u32, 7) << 16) | (@as(u32, 9) << 24),
        4,
        "add",
    );
    expect(harness.integerIs(add[1], 3));
    expect(harness.integerIs(add[2], 7));
    expect(harness.integerIs(add[3], 9));
}

/// The pair that distinguishes one table row from its neighbour. Identical
/// words, identical final byte, opposite readings.
fn theSignedAndUnsignedImmediatesAgreeOnNothing() void {
    const word = (@as(u32, 3) << 8) | (@as(u32, 7) << 16) | (@as(u32, 0xFD) << 24);

    const addim = decoded(harness.op(constants.Opcode.add_immediate) | word, 4, "addim");
    expect(harness.integerIs(addim[3], -3));

    const sruim = decoded(harness.op(constants.Opcode.shift_right_unsigned_immediate) | word, 4, "sruim");
    expect(harness.integerIs(sruim[3], 253));
}

/// Bit 7 is the breakpoint flag rather than part of the opcode, and it is
/// reported out of band: the tuple is still `(noop)`, and the flag rides on
/// the tuple itself.
fn aBreakpointIsAFlagRatherThanAnOperand() void {
    const tuple = decoded(harness.op(constants.Opcode.noop) | @as(u32, 0x80), 1, "noop");
    expect((harness.gcBits(tuples.head(tuple).gc.flags) & constants.JANET_TUPLE_FLAG_BRACKETCTOR) != 0);
}

pub fn run() void {
    harness.init();
    anUnknownOpcodeStaysANumber();
    theOperandShapes();
    theSignedAndUnsignedImmediatesAgreeOnNothing();
    aBreakpointIsAFlagRatherThanAnOperand();
    vm_lifecycle.deinit();
}
