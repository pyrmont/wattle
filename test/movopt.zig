//! Behavioral contract for `janet_bytecode_movopt`, the dead-store pass that
//! runs over a `JanetFuncDef` after compilation.
//!
//! The pass rewrites instructions in place to `JOP_NOOP`, and there is no way
//! to see that from Janet: the suites can observe that a program still
//! computes the right answer, which is true whether the pass fired or not.
//! What is asserted here is which instructions it removes and — the more
//! important half — which it must leave alone.
//!
//! Each case is one hand-assembled function body rather than compiled source,
//! because the point is the shape of the bytecode and not the shape of the
//! program that produced it. A `JanetFuncDef` is zeroed and given three
//! fields, which is everything the pass reads.

const std = @import("std");
const movopt = @import("subsystems").optimize;
const types = @import("types");
const constants = @import("constants");

/// A definition holding nothing but the bytecode under test. Zeroed rather
/// than partially initialised, because the pass reads `closure_bitset` and a
/// stray pointer there is the difference between a dead store and a captured
/// one.
fn definitionFor(bytecode: []u32, slots: i32) types.JanetFuncDef {
    var definition: types.JanetFuncDef = std.mem.zeroes(types.JanetFuncDef);
    definition.bytecode = bytecode.ptr;
    definition.bytecode_length = @intCast(bytecode.len);
    definition.slotcount = slots;
    return definition;
}

/// A slot written and never read is a dead store.
fn aDeadLoadIsRemoved() void {
    var bytecode = [_]u32{ constants.JOP_LOAD_NIL, constants.JOP_RETURN_NIL };
    var definition = definitionFor(&bytecode, 1);
    movopt.bytecodeMovopt(&definition);
    std.debug.assert(bytecode[0] == constants.JOP_NOOP);
}

/// Removing one dead store can make its source dead in turn, so the pass has
/// to reach a fixed point rather than sweep once.
fn theRemovalCascades() void {
    var bytecode = [_]u32{
        constants.JOP_LOAD_NIL,
        constants.JOP_MOVE_NEAR | (@as(u32, 1) << 8),
        constants.JOP_RETURN_NIL,
    };
    var definition = definitionFor(&bytecode, 2);
    movopt.bytecodeMovopt(&definition);
    std.debug.assert(bytecode[0] == constants.JOP_NOOP);
    std.debug.assert(bytecode[1] == constants.JOP_NOOP);
}

/// The three things that make a store live, which matter more than the two
/// above: each is a case where removing the instruction would change what the
/// function does.
fn aLiveLoadIsKept() void {
    // Read by the return.
    var returned = [_]u32{ constants.JOP_LOAD_NIL, constants.JOP_RETURN };
    var definition = definitionFor(&returned, 1);
    movopt.bytecodeMovopt(&definition);
    std.debug.assert(returned[0] == constants.JOP_LOAD_NIL);

    // Captured by a closure. Nothing in the bytecode reads slot 0, so only
    // `closure_bitset` says this store is live -- and a pass that ignored it
    // would compile a correct program into a wrong one.
    var captured = [_]u32{ constants.JOP_LOAD_NIL, constants.JOP_RETURN_NIL };
    var closure_bits = [_]u32{1};
    definition = definitionFor(&captured, 1);
    definition.closure_bitset = &closure_bits;
    movopt.bytecodeMovopt(&definition);
    std.debug.assert(captured[0] == constants.JOP_LOAD_NIL);

    // Allocating. The destination is dead, but the instruction is not: it
    // allocates, and the collector's timing is observable.
    var effectful = [_]u32{ constants.JOP_MAKE_BUFFER, constants.JOP_RETURN_NIL };
    definition = definitionFor(&effectful, 1);
    movopt.bytecodeMovopt(&definition);
    std.debug.assert(effectful[0] == constants.JOP_MAKE_BUFFER);
}

pub fn run() void {
    aDeadLoadIsRemoved();
    theRemovalCascades();
    aLiveLoadIsKept();
}
