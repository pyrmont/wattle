//! Behavioral contract for `bytecode.assembleValue`: an assembly source turned
//! into a `functions.FuncDef`, and the twenty ways it refuses.
//!
//! `test/suite-asm.janet` runs nine assemblies and checks that they execute.
//! What it cannot check is the *bytecode words*, a wrong operand encoding that
//! happens to run being indistinguishable from a right one, or any of the
//! refusal messages, because `asm` raises and a suite that raises stops.
//!
//! Both are asserted here, and the refusals are the bulk of it. They are worth
//! the space for a reason particular to this subsystem: `assembleValue`
//! reports by filling in an `AssembleResult.error` rather than by raising, so
//! the message is a return value and part of the interface. Changing the
//! wording would change observable behaviour, and nothing else in the tree
//! would notice.
//!
//! ## What the first assembly is for
//!
//! One function with five different operand encodings in it, so that the
//! bytecode assertions below cover the shapes rather than one of them five
//! times: a signed 16-bit immediate (`ldi ... -12` as `0xFFF4`), a signed
//! 8-bit immediate (`addim ... -3` as `0xFD`), a type mask assembled from
//! keywords, a constant index, and a label resolved to a relative jump.
//!
//! It also has a slot *alias*, `(first first-alias)` naming one slot twice,
//! which is the only way to tell that the slot table maps names to indices
//! rather than positions.
//!
//! ## `:closures` and `:defs` are the same key
//!
//! Two spellings, one field; the second is the older one. Both are asserted
//! because dropping either is a silent compatibility break for hand-written
//! assembly.

// ==========================================================================
// Project imports
// ==========================================================================

const bytecode = @import("subsystems").bytecode;
const constants = @import("constants");
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const functions = @import("subsystems").value.functions;
const harness = @import("harness.zig");
const repr = @import("repr");
const tables = @import("subsystems").value.tables;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

var environment: *tables.Table = undefined;

// ==========================================================================
// Cases
// ==========================================================================

/// Evaluate an assembly source and assemble the value it produces.
///
/// `env.dostring` is a protected entry point and returns a status rather than
/// raising, so the quoted structure arrives here without a scope.
fn assemble(source: [*:0]const u8) bytecode.AssembleResult {
    var val: repr.Value = undefined;
    expect(core_env.dostring(environment, source, "asm-encode-test", &val) == 0);
    return bytecode.assembleValue(val, 0);
}

/// Assemble, and assert it was refused with exactly this message.
fn refused(source: [*:0]const u8, message: [*:0]const u8) void {
    const result = assemble(source);
    expect(@intFromEnum(result.status) == 1);
    expect(result.@"error" != null);
    expect(harness.stringIs(result.@"error".?, message));
}

fn accepted(source: [*:0]const u8) *functions.FuncDef {
    const result = assemble(source);
    expect(@intFromEnum(result.status) == 0);
    expect(result.@"error" == null);
    return result.funcdef.?;
}

/// Five operand encodings in one function; see the header comment.
fn theOperandEncodings() void {
    const definition = accepted(
        \\'{:arity 0
        \\  :constants ["constant"]
        \\  :slots [(first first-alias) second]
        \\  :bytecode [(ldi first -12)
        \\             (addim second first-alias -3)
        \\             (tchck first [:nil :number])
        \\             (ldc second 0)
        \\             (jmp :done)
        \\             :done
        \\             (retn)]}
    );

    // A label occupies no instruction, so seven source forms are six words.
    expect(definition.bytecode_length == 6);

    // -12 as a signed 16-bit field.
    expect(definition.instructions()[0] ==
        harness.op(constants.Opcode.load_integer) | (@as(u32, 0) << 8) | (@as(u32, 0xFFF4) << 16));
    // -3 as a signed 8-bit field, and `first-alias` resolving to slot 0.
    expect(definition.instructions()[1] ==
        harness.op(constants.Opcode.add_immediate) | (@as(u32, 1) << 8) | (@as(u32, 0) << 16) | (@as(u32, 0xFD) << 24));
    // Two keywords folded into one type mask.
    // The instruction's operand is the set's sixteen bits, which is the
    // bytecode width `repr.TagSet` is sized to.
    const mask: u32 = repr.TagSet.of(&.{ .nil, .number }).bits();
    expect(definition.instructions()[2] == harness.op(constants.Opcode.typecheck) | (mask << 16));
    expect(definition.instructions()[3] == harness.op(constants.Opcode.load_constant) | (@as(u32, 1) << 8));
    // The label resolved to a relative displacement of one.
    expect(definition.instructions()[4] == harness.op(constants.Opcode.jump) | (@as(u32, 1) << 8));
    expect(constants.Opcode.fromWord(definition.instructions()[5]) == constants.Opcode.return_nil);

    // Two names, two slots: the alias did not create a third.
    expect(definition.slotcount == 2);

    expect(definition.constants_length == 1);
    expect(harness.isType(definition.constantValues()[0], repr.Tag.string));
    expect(harness.stringIs(wrap.toString(definition.constantValues()[0]), "constant"));
}

fn theTwoSpellingsOfAChildDefinition() void {
    const closures = accepted(
        \\'{:closures [{:name child :bytecode [(retn)]}]
        \\  :bytecode [(clo 0 child) (retn)]}
    );
    expect(closures.defs_length == 1);
    expect(harness.stringIs(closures.subdefs()[0].name.?, "child"));
    expect(constants.Opcode.fromWord(closures.instructions()[0]) == constants.Opcode.closure);

    const defs = accepted(
        \\'{:defs [{:name legacy-child :bytecode [(retn)]}]
        \\  :bytecode [(clo 0 legacy-child) (retn)]}
    );
    expect(defs.defs_length == 1);
    expect(harness.stringIs(defs.subdefs()[0].name.?, "legacy-child"));
}

fn theMetadataFields() void {
    const definition = accepted(
        \\'{:name metadata-fn :arity 2 :min-arity 1 :max-arity 3
        \\  :vararg true :maparg true :namedargs 2
        \\  :source "metadata-source" :bytecode [(retn)]}
    );
    expect(definition.arity == 2);
    expect(definition.min_arity == 1);
    expect(definition.max_arity == 3);
    // Derived rather than declared: `max-arity` 3 needs three slots.
    expect(definition.slotcount == 3);
    expect(definition.named_args_count == 2);
    expect(definition.flags.vararg);
    expect(definition.flags.maparg);
    expect(definition.flags.namedargs);
    expect(harness.stringIs(definition.name.?, "metadata-fn"));
    expect(harness.stringIs(definition.source.?, "metadata-source"));
}

fn theSourceMapAndSymbolMap() void {
    const mapped = accepted("'{:bytecode [(retn)] :sourcemap [[12 34]]}");
    expect(mapped.sourceMappings()[0].line == 12);
    expect(mapped.sourceMappings()[0].column == 34);

    const symbols = accepted(
        \\'{:arity 1 :bytecode [(noop) (retn)]
        \\  :symbolmap [[0 1 0 local]]}
    );
    expect(symbols.symbolmap_length == 1);
    // Present in the flags as well as in the table.
    expect(symbols.flags.hassymbolmap);
    expect(symbols.symbols()[0].birth_pc == 0);
    expect(harness.stringIs(symbols.symbols()[0].symbol.?, "local"));

    // An empty environment list is accepted; an ill-typed one is not.
    const empty = accepted("'{:bytecode [(retn)] :environments []}");
    expect(empty.environments_length == 0);
}

/// The seven runs inside a `functions.FuncDef`, each a pointer whose length is
/// a different field, and each giving back the empty slice when the run is
/// absent.
///
/// Two of the pairings are not derivable from the field names and are what
/// these accessors exist to state: `sourcemap` is as long as the *bytecode*,
/// and `closure_bitset` is a bit per slot rounded up to a word. The empty half
/// matters because a funcdef with no bytecode at all is reachable:
/// `unmarshalOneDef` builds one before it fills anything, and the compiler
/// leaves `bytecode` null for a zero-length body.
fn theSevenRunsOfAFuncdef() void {
    var empty: functions.FuncDef = .{};
    expect(empty.constantValues().len == 0);
    expect(empty.instructions().len == 0);
    expect(empty.environmentIndices().len == 0);
    expect(empty.subdefs().len == 0);
    expect(empty.symbols().len == 0);
    expect(empty.sourceMappings().len == 0);
    expect(empty.closureBits().len == 0);

    // A real one, so that an accessor which always gave back empty would fail.
    const def = accepted("'{:bytecode [(noop) (retn)] :constants [7 :k] :sourcemap [[1 2] [3 4]]}");
    expect(def.instructions().len == 2);
    expect(def.constantValues().len == 2);

    // The pairing: one source mapping per *instruction*, with no length field
    // of its own anywhere in the structure.
    expect(def.sourceMappings().len == def.instructions().len);
    expect(def.sourceMappings()[0].line == 1);
    expect(def.sourceMappings()[1].column == 4);

    // A funcdef with a sourcemap pointer but a zero bytecode length gives back
    // empty rather than trapping, which is the state `unmarshalOneDef` passes
    // through.
    var truncated = def.*;
    truncated.bytecode_length = 0;
    expect(truncated.sourceMappings().len == 0);
    expect(truncated.instructions().len == 0);

    // And the bitset is a bit per slot, rounded up: thirty-three slots is two
    // words, not one.
    var bits = [_]u32{ 0, 0 };
    var closure: functions.FuncDef = .{ .closure_bitset = &bits, .slotcount = 33 };
    expect(closure.closureBits().len == 2);
    closure.slotcount = 32;
    expect(closure.closureBits().len == 1);
    closure.closure_bitset = null;
    expect(closure.closureBits().len == 0);
}

/// The twenty refusals, and their exact wording. See the header comment for
/// why the wording is the contract rather than an implementation detail.
fn theRefusals() void {
    // A source map has to cover the bytecode exactly.
    refused(
        "'{:bytecode [(retn)] :sourcemap []}",
        "sourcemap must have the same length as the bytecode",
    );
    refused("'{:bytecode [(retn)] :sourcemap [:bad]}", "expected tuple or vector");
    refused(
        "'{:arity 1 :bytecode [(retn)] :symbolmap [[0 1 0 :bad]]}",
        "expected symbol",
    );
    refused("'{:bytecode [(retn)] :environments [:bad]}", "expected integer");

    // The header fields.
    refused("'{:arity -1 :bytecode [(retn)]}", "arity must be non-negative, instruction 0");
    refused(
        "'{:arity 1 :max-arity 0 :bytecode [(retn)]}",
        "max-arity must be greater than or equal to arity, instruction 0",
    );
    refused(
        "'{:arity 1 :min-arity 2 :bytecode [(retn)]}",
        "min-arity must be less than or equal to arity, instruction 0",
    );
    refused(
        "'{:slots [0] :bytecode [(retn)]}",
        "slot names must be symbols or tuple of symbols, instruction 0",
    );
    refused(
        "'{:slots [(good 0)] :bytecode [(retn)]}",
        "slot names must be symbols, instruction 0",
    );

    // The instructions themselves.
    refused("'{:bytecode [(retn 1)]}", "expected 0 arguments: (op), instruction 0");
    refused(
        "'{:bytecode [(ldi 0 40000)]}",
        "instruction argument 40000 is too large, must be 2 bytes",
    );
    refused(
        "'{:bytecode [(sruim 0 0 -1)]}",
        "instruction argument -1 is too small, must be 1 byte",
    );
    refused("'{:bytecode [(ldi 0 1.5)]}", "error parsing instruction argument 1.5");
    refused("'{:bytecode [(ldi missing 1)]}", "unknown name missing");
    refused("'{:bytecode [(tchck 0 :not-a-type)]}", "unknown type :not-a-type");
    refused("'{:bytecode [(not-an-opcode)]}", "unknown instruction not-an-opcode");
    refused(
        "'{:bytecode [(1)]}",
        "expected symbol in assembly instruction, instruction 0",
    );
    refused("'{:bytecode [123]}", "expected assembly instruction, instruction 0");

    // The source as a whole.
    refused("'{}", "bytecode expected, instruction 0");
    refused(
        "'not-an-assembly",
        "expected dictionary for assembly source, instruction 0",
    );
}

// ==========================================================================
// Entry
// ==========================================================================

pub fn run() void {
    harness.init();
    environment = harness.coreEnv();

    theOperandEncodings();
    theTwoSpellingsOfAChildDefinition();
    theMetadataFields();
    theSourceMapAndSymbolMap();
    theSevenRunsOfAFuncdef();
    theRefusals();

    vm_lifecycle.deinit();
}
