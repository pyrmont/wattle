//! Behavioral contract for the compiler's primitives, the layer between the
//! special forms and the emitter.
//!
//! Scopes, slots, symbol resolution, upvalue capture and the funcdef that
//! falls out at the end. Every Janet program drives all of it, and that is
//! exactly why the suites cannot pin any of it: what they observe is the
//! program's *result*, and a compiler that captured an upvalue through a
//! different index, or recorded a symbol's death one instruction late, would
//! produce the same result and a wrong debug image. So this file drives the
//! primitives directly and asserts the intermediate state.
//!
//! The order matters. This is one compilation driven from an empty scope to a
//! finished funcdef, and the assertions about `birth_pc`, `death_pc` and the
//! symbol map are assertions about *when* things happened. The cases below are
//! not independent of each other.
//!
//! ## The raising primitives are reached by import
//!
//! Eight of them are raise-capable, `valueImpl` compiling an arbitrary form
//! that can reach a macro, a lint at strict level, or an abstract type's
//! `tostring` inside an error message. This file calls the raising function
//! rather than the abi beside it, so a raise crosses as `error.Signal`
//! and the compiler checks that this file handles it.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const arrays = @import("subsystems").value.arrays;
const constants = @import("constants");
const expect = @import("expect.zig").expect;
const functions = @import("subsystems").value.functions;
const harness = @import("harness.zig");
const primitives = @import("subsystems").compiler_primitives;
const registry = @import("subsystems").registry;
const repr = @import("repr");
const strings = @import("subsystems").value.strings;
const maps = @import("subsystems").value.maps;
const symbols = @import("subsystems").value.symbols;
const tables = @import("subsystems").value.tables;
const tuples = @import("subsystems").value.tuples;
const value = @import("subsystems").value;
const vector = harness.vector;
const vectors = @import("subsystems").value.vectors;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

var child: primitives.Scope = undefined;
var compiler: primitives.Compiler = undefined;

/// The recursion guard is consulted and decremented by `compiler.valueImpl`,
/// so every section that compiles a form resets it the way `compiler.compile`
/// does.
const recursion_guard = 1024;
var scope: primitives.Scope = undefined;
var unused: primitives.Scope = undefined;

// ==========================================================================
// Cases
// ==========================================================================

fn emitted(index: usize) u32 {
    return compiler.buffer.items[index];
}

fn emittedCount() i32 {
    return @intCast(vector.count(compiler.buffer));
}

/// The opcode in a word, which several assertions here read without the
/// operands.
fn operationOf(word: u32) u32 {
    return word & 0xFF;
}

/// `foptsDefault` describes a form with no expectations: any type is
/// acceptable, no flags are set, and the hint is a nil constant.
fn theDefaultFormOptions() void {
    const options = primitives.foptsDefault(&compiler);
    expect(options.compiler == &compiler);
    expect(std.meta.eql(options.flags, primitives.FormFlags{}));
    expect(@as(u32, @bitCast(options.hint.flags)) ==
        (@as(u32, 1) << @intFromEnum(repr.Tag.nil)) | 0x10000);
    expect(harness.isType(options.hint.constant, repr.Tag.nil));
}

/// A constant slot records the value's type in its low bits, which is what
/// lets the emitter decide whether an immediate will do.
fn aConstantSlotRemembersItsType() void {
    const slot = primitives.cslot(wrap.fromTrue());
    expect(@as(u32, @bitCast(slot.flags)) ==
        (@as(u32, 1) << @intFromEnum(repr.Tag.boolean)) | 0x10000);
    expect(slot.index == -1);
    expect(slot.envindex == -1);
    expect(wrap.toBoolean(slot.constant));
}

/// A far slot is handed back when it is freed, unless it has been named, in
/// which case it belongs to a binding and stays taken. That single rule is
/// what keeps a `def`'s register alive for the rest of its scope.
fn aNamedSlotIsNotReclaimed() void {
    var slot = primitives.farslot(&compiler).?;
    expect(slot.index == 0);
    expect(@as(u32, @bitCast(slot.flags)) == 0xFFFF);
    expect(slot.envindex == -1);
    expect(harness.isType(slot.constant, repr.Tag.nil));

    primitives.freeslot(&compiler, slot);
    expect(primitives.farslot(&compiler).?.index == 0);

    slot = primitives.farslot(&compiler).?;
    slot.flags.named = true;
    primitives.freeslot(&compiler, slot);
    expect(primitives.farslot(&compiler).?.index == 2);

    // An upvalue is not this scope's register either, and environment 0 is an
    // environment: freeing one leaves the register its index names taken.
    var upvalue = primitives.farslot(&compiler).?;
    expect(upvalue.index == 3);
    upvalue.envindex = 0;
    primitives.freeslot(&compiler, upvalue);
    expect(primitives.farslot(&compiler).?.index == 4);
}

/// `primitives.defAddflags` derives a funcdef's `HAS*` flags from which of its
/// optional fields are populated, so it must *clear* the ones that are not.
/// A marshalled image trusts those flags to say which sections follow.
fn theFuncdefFlagsAreDerived() void {
    var definition: functions.FuncDef = std.mem.zeroes(functions.FuncDef);
    var nested: *functions.FuncDef = &definition;
    var mapping: functions.SourceMapping = .{ .line = 0, .column = 0 };
    var closure_bits: u32 = 0;
    var environment: i32 = 0;

    definition.flags = .{
        .vararg = true,
        .hasname = true,
        .hassource = true,
        .hasdefs = true,
        .hasenvs = true,
        .hassourcemap = true,
        .hasclobitset = true,
    };
    primitives.defAddflags(&definition);
    // Every claim was false, so only the flag that is not derived survives.
    expect(std.meta.eql(definition.flags, functions.FuncDefFlags{ .vararg = true }));

    definition.name = strings.cstring("name");
    definition.source = strings.cstring("source");
    definition.defs = @ptrCast(&nested);
    definition.environments = @ptrCast(&environment);
    definition.sourcemap = @ptrCast(&mapping);
    definition.closure_bitset = @ptrCast(&closure_bits);
    primitives.defAddflags(&definition);
    expect(definition.flags.vararg);
    expect(definition.flags.hasname);
    expect(definition.flags.hassource);
    expect(definition.flags.hasdefs);
    expect(definition.flags.hasenvs);
    expect(definition.flags.hassourcemap);
    expect(definition.flags.hasclobitset);
}

/// Popping a scope hands its high-water register mark and its symbols up to
/// the parent, and stamps a death instruction on each symbol that has none.
///
/// The stamped `death_pc` is the parent's instruction count at the moment of
/// the pop, which is what a debugger uses to decide a binding is out of
/// scope. Nothing in Janet can observe it except a stack trace.
fn poppingAScopeHandsUpItsSymbols() !void {
    scope.ra.deinit();
    compiler.scope = null;
    primitives.pushScope(&scope, &compiler, .{ .function = true }, "root");
    scope.ra.touch(5);
    vector.push(&compiler.buffer, harness.op(constants.Opcode.noop));

    primitives.pushScope(&child, &compiler, .{ .closure = true }, "child");
    expect(compiler.scope == &child);
    expect(scope.child == &child);
    expect(child.parent == &scope);
    expect(child.bytecode_start == 1);
    // The child inherits the parent's taken registers, so 5 is still taken.
    expect(child.ra.isTaken(5));

    var pair: primitives.SymPair = std.mem.zeroes(primitives.SymPair);
    pair.slot.index = 3;
    pair.slot.envindex = -1;
    pair.sym = symbols.new("local");
    pair.sym2 = pair.sym;
    pair.referenced = true;
    pair.keep = true;
    pair.death_pc = std.math.maxInt(u32);
    vector.push(&child.syms, pair);
    child.ra.touch(8);
    child.ra.max = 8;
    vector.push(&compiler.buffer, harness.op(constants.Opcode.noop));

    try primitives.popscope(&compiler);
    expect(compiler.scope == &scope);
    expect(scope.child == null);
    // A closure scope marks its parent as one too, which is how the parent
    // comes to need an environment.
    expect(scope.flags.closure);
    expect(scope.ra.max >= 8);
    expect(vector.count(scope.syms) == 1);
    // The name is dropped and only `sym2` would survive, and `keep` clears
    // that too, because the slot is being kept rather than the binding.
    expect(scope.syms.items[0].sym == null);
    expect(scope.syms.items[0].sym2 == null);
    expect(scope.syms.items[0].death_pc == 2);
    expect(scope.ra.isTaken(3));
}

/// An unused scope contributes nothing, but `popscope_keepslot` still touches
/// the register its result lives in so the parent does not hand it out again.
fn anUnusedScopeStillKeepsItsResultSlot() !void {
    primitives.pushScope(&unused, &compiler, .{ .unused = true }, "unused");
    var slot: primitives.Slot = std.mem.zeroes(primitives.Slot);
    slot.index = 10;
    slot.envindex = -1;
    try primitives.popscopeKeepslot(&compiler, slot);
    expect(compiler.scope == &scope);
    expect(scope.ra.isTaken(10));
}

/// `compileReturn` marks the slot returned and emits at most once, so a
/// second call on an already-returned slot emits nothing.
fn returningIsIdempotent() void {
    vector.empty(&compiler.buffer);
    var slot = primitives.compileReturn(&compiler, primitives.cslot(wrap.fromNil()));
    expect(slot.flags.returned);
    expect(emittedCount() == 1);
    expect(emitted(0) == harness.op(constants.Opcode.return_nil));
    slot = primitives.compileReturn(&compiler, slot);
    expect(emittedCount() == 1);

    vector.empty(&compiler.buffer);
    slot = std.mem.zeroes(primitives.Slot);
    slot.index = 3;
    slot.envindex = -1;
    slot = primitives.compileReturn(&compiler, slot);
    expect(slot.flags.returned);
    expect(emittedCount() == 1);
    expect(emitted(0) == harness.op(constants.Opcode.@"return") | (3 << 8));
}

/// A hint is honoured only when the hinted register is near. A far hint is
/// refused and a fresh slot allocated instead, because most instructions have
/// eight bits for a destination.
fn aHintIsHonouredOnlyWhenItIsNear() void {
    var options = primitives.foptsDefault(&compiler);
    options.flags = .{ .hint = true };
    options.hint = std.mem.zeroes(primitives.Slot);
    options.hint.index = 7;
    options.hint.envindex = -1;
    expect(primitives.gettarget(options).index == 7);

    options.hint.index = 300;
    const slot = primitives.gettarget(options);
    expect(slot.index >= 0 and slot.index != 300);
    expect(slot.envindex == -1 and std.meta.eql(slot.flags, primitives.SlotFlags{}));
    expect(harness.isType(slot.constant, repr.Tag.nil));

    // "Near" is three tests and each has an end. A hint carries a flag the
    // fresh slot does not, so an honoured hint is told from a fresh register
    // by the flag rather than by the index the allocator happened to give.
    options.hint.flags = .{ .mutable = true };
    options.hint.index = 0;
    const zero = primitives.gettarget(options);
    expect(zero.index == 0 and zero.flags.mutable);

    options.hint.index = 0xFF;
    const last = primitives.gettarget(options);
    expect(last.index == 0xFF and last.flags.mutable);

    // An upvalue is not a register, so a hint in environment 0 is refused
    // however near its index is.
    options.hint.index = 7;
    options.hint.envindex = 0;
    const upvalue = primitives.gettarget(options);
    expect(upvalue.envindex == -1 and !upvalue.flags.mutable);
}

/// A function nothing closed over does not need an environment.
///
/// `theFinishedFuncdef` asserts the flag where it is set, which a compiler
/// that set it always would also pass. This asserts it where it is clear.
fn aPlainFunctionNeedsNoEnvironment() !void {
    var plain: primitives.Scope = undefined;
    primitives.pushScope(&plain, &compiler, .{ .function = true }, "plain");
    compiler.recursion_guard = recursion_guard;
    _ = try primitives.valueImpl(primitives.foptsDefault(&compiler), harness.wrapInteger(1));
    const definition = try primitives.popFuncdef(&compiler);
    expect(!definition.flags.needsenv);
    expect(compiler.scope == null);
}

/// `popscopeKeepslot` keeps one register alive in the parent scope, and an
/// upvalue is not a register: one in environment 0 leaves the parent alone.
fn anUpvalueIsNotKeptAsARegister() !void {
    var parent: primitives.Scope = undefined;
    primitives.pushScope(&parent, &compiler, .{ .function = true }, "keep-parent");
    var inner: primitives.Scope = undefined;
    primitives.pushScope(&inner, &compiler, .{}, "keep-child");

    var upvalue = std.mem.zeroes(primitives.Slot);
    upvalue.index = 5;
    upvalue.envindex = 0;
    try primitives.popscopeKeepslot(&compiler, upvalue);
    expect(compiler.scope == &parent);
    expect(!parent.ra.isTaken(5));
    try primitives.popscope(&compiler);
}

/// A list of values becomes a vector of slots, and a dictionary becomes a
/// flat key-value vector in *sorted key order*, which is what makes a struct
/// literal compile deterministically whatever order it was written in.
fn valuesBecomeSlots() !void {
    var values = [2]repr.Value{ harness.wrapInteger(10), wrap.fromTrue() };
    compiler.recursion_guard = recursion_guard;
    var slots = try primitives.toslots(&compiler, &values, 2);
    expect(vector.count(slots) == 2);
    expect(slots.items[0].flags.constant);
    expect(harness.integerIs(slots.items[0].constant, 10));
    expect(slots.items[1].flags.constant);
    expect(wrap.toBoolean(slots.items[1].constant));
    primitives.freeslots(&compiler, slots);

    const dictionary = tables.new(2);
    tables.put(dictionary, value.fromBytes("b", .keyword), harness.wrapInteger(2));
    tables.put(dictionary, value.fromBytes("a", .keyword), harness.wrapInteger(1));
    compiler.recursion_guard = recursion_guard;
    slots = try primitives.toslotskv(&compiler, wrap.fromTable(dictionary));
    expect(vector.count(slots) == 4);
    expect(harness.keywordIs(slots.items[0].constant, "a"));
    expect(harness.integerIs(slots.items[1].constant, 1));
    expect(harness.keywordIs(slots.items[2].constant, "b"));
    expect(harness.integerIs(slots.items[3].constant, 2));
    primitives.freeslots(&compiler, slots);
}

/// The four kinds `valueImpl` distinguishes: a self-evaluating atom, a
/// structure it can fold to a constant, one it has to build at run time, and
/// a call.
fn theFourKindsOfForm() !void {
    compiler.current_mapping.line = 12;
    compiler.current_mapping.column = 34;
    compiler.recursion_guard = recursion_guard;
    var options = primitives.foptsDefault(&compiler);

    // An atom compiles to a constant and disturbs neither the guard nor the
    // source position, which is what makes those two safe to read afterwards.
    var slot = try primitives.valueImpl(options, harness.wrapInteger(55));
    expect(slot.flags.constant);
    expect(harness.integerIs(slot.constant, 55));
    expect(compiler.recursion_guard == recursion_guard);
    expect(compiler.current_mapping.line == 12);
    expect(compiler.current_mapping.column == 34);

    // A struct of constants folds, so nothing is built at run time.
    var folded = wrap.fromMap(maps.build(.map, &.{
        value.fromBytes("key", .keyword), harness.wrapInteger(9),
    }));
    slot = try primitives.valueImpl(options, folded);
    expect(slot.flags.constant);
    expect(harness.isType(slot.constant, repr.Tag.map));
    expect(emittedCount() == 1);

    // A mutable structure cannot fold, so it is pushed and constructed.
    const array = arrays.new(2);
    harness.arrayPush(array, harness.wrapInteger(4));
    harness.arrayPush(array, harness.wrapInteger(5));
    vector.empty(&compiler.buffer);
    compiler.recursion_guard = recursion_guard;
    slot = try primitives.valueImpl(options, wrap.fromArray(array));
    expect(!slot.flags.constant);
    expect(emittedCount() == 4);
    expect(operationOf(emitted(2)) == harness.op(constants.Opcode.push_2));
    expect(operationOf(emitted(3)) == harness.op(constants.Opcode.make_array));
    primitives.freeslot(&compiler, slot);

    // A tuple is a call, and in tail position it is a tail call.
    var call = tuples.begin(2);
    call[0] = value.fromBytes("key", .keyword);
    call[1] = folded;
    folded = wrap.fromTuple(tuples.end(call));
    vector.empty(&compiler.buffer);
    compiler.recursion_guard = recursion_guard;
    options = primitives.foptsDefault(&compiler);
    slot = try primitives.valueImpl(options, folded);
    expect(!slot.flags.constant);
    expect(operationOf(emitted(@intCast(emittedCount() - 1))) == harness.op(constants.Opcode.call));
    primitives.freeslot(&compiler, slot);

    vector.empty(&compiler.buffer);
    compiler.recursion_guard = recursion_guard;
    options = primitives.foptsDefault(&compiler);
    options.flags.tail = true;
    slot = try primitives.valueImpl(options, folded);
    expect(slot.flags.returned);
    expect(operationOf(emitted(@intCast(emittedCount() - 1))) == harness.op(constants.Opcode.tailcall));

    // A one-element call whose head is not callable is a compile error rather
    // than a raise: the compiler records it and returns a nil constant.
    call = tuples.begin(1);
    call[0] = value.fromBytes("key", .keyword);
    vector.empty(&compiler.buffer);
    compiler.recursion_guard = recursion_guard;
    options = primitives.foptsDefault(&compiler);
    slot = try primitives.valueImpl(options, wrap.fromTuple(tuples.end(call)));
    expect(slot.flags.constant);
    expect(harness.isType(slot.constant, repr.Tag.nil));
    expect(compiler.result.status == primitives.CompileStatus.@"error");
    expect(compiler.result.@"error" != null);
    compiler.result.status = primitives.CompileStatus.ok;
    compiler.result.@"error" = null;
    compiler.recursion_guard = recursion_guard;
}

/// A vector in a syntax tree is a literal, not a call and not a constant
/// holding the symbols the user wrote.
///
/// The parser cannot yet emit one, so this is the only place the two arms are
/// exercised: a vector of constants folds to a constant vector, and one
/// holding a form is built at run time by `make_vector`. Before the arm
/// existed both fell through to `cslot`, which compiled `[x]` to a constant
/// vector of the *symbol* `x` and said nothing.
fn aVectorIsALiteral() !void {
    compiler.recursion_guard = recursion_guard;
    const options = primitives.foptsDefault(&compiler);

    // Constants fold: nothing is emitted, and the constant is a vector of the
    // elements rather than of the forms.
    var elements = [2]repr.Value{ harness.wrapInteger(4), harness.wrapInteger(5) };
    vector.empty(&compiler.buffer);
    var slot = try primitives.valueImpl(options, wrap.fromVector(vectors.fromSlice(&elements)));
    expect(slot.flags.constant);
    expect(harness.isType(slot.constant, repr.Tag.vector));
    expect(harness.integerIs(vectors.at(wrap.toVector(slot.constant), 0), 4));
    expect(emittedCount() == 0);

    // A form inside one does not: the elements are pushed and the vector is
    // constructed, as an array literal is.
    const call = tuples.begin(2);
    call[0] = value.fromBytes("key", .keyword);
    call[1] = harness.wrapInteger(9);
    elements[1] = wrap.fromTuple(tuples.end(call));
    vector.empty(&compiler.buffer);
    compiler.recursion_guard = recursion_guard;
    slot = try primitives.valueImpl(options, wrap.fromVector(vectors.fromSlice(&elements)));
    expect(!slot.flags.constant);
    expect(operationOf(emitted(@intCast(emittedCount() - 1))) == harness.op(constants.Opcode.make_vector));
    primitives.freeslot(&compiler, slot);
    compiler.recursion_guard = recursion_guard;
}

/// Pushing arguments picks the widest instruction that fits, and a splice
/// forces the one-at-a-time form, which is what the negative arity means.
fn theArgumentPush() void {
    var slots: harness.Vector(primitives.Slot) = .empty;
    var slot: primitives.Slot = std.mem.zeroes(primitives.Slot);
    slot.envindex = -1;
    for ([_]i32{ 1, 2, 3 }) |index| {
        slot.index = index;
        vector.push(&slots, slot);
    }

    vector.empty(&compiler.buffer);
    expect(primitives.pushslots(&compiler, slots.items) == 3);
    expect(emittedCount() == 1);
    expect(emitted(0) ==
        harness.op(constants.Opcode.push_3) | (1 << 8) | (2 << 16) | (3 << 24));

    // A spliced argument makes the arity a minimum rather than an exact
    // count, which the caller reads from the sign.
    slots.items[1].flags.spliced = true;
    vector.empty(&compiler.buffer);
    expect(primitives.pushslots(&compiler, slots.items) == -3);
    expect(emittedCount() == 3);
    expect(emitted(0) == harness.op(constants.Opcode.push) | (1 << 8));
    expect(emitted(1) == harness.op(constants.Opcode.push_array) | (2 << 8));
    expect(emitted(2) == harness.op(constants.Opcode.push) | (3 << 8));
    vector.free(&slots);
}

/// A global `def` resolves to its value, a global `var` to a reference cell.
///
/// The difference is the whole of Janet's mutable-binding representation: a
/// `var` is a one-element array in the environment and every read is an
/// index into it, so the slot is `REF | NAMED | MUTABLE` rather than
/// `CONSTANT`.
fn theGlobalBindings() !void {
    registry.def(compiler.env.?, "global-def", harness.wrapInteger(42), null);
    var symbol = symbols.new("global-def");
    expect(primitives.shadowcheck(&compiler, symbol) == primitives.Shadowing.local_hides_global);
    var slot = try primitives.resolve(&compiler, symbol);
    expect(slot.flags.constant);
    expect(harness.integerIs(slot.constant, 42));

    registry.defVarAbi(compiler.env.?, "global-var", harness.wrapInteger(7), null);
    symbol = symbols.new("global-var");
    slot = try primitives.resolve(&compiler, symbol);
    expect(slot.flags.ref);
    expect(slot.flags.named);
    expect(slot.flags.mutable);
    expect(!slot.flags.constant);
}

/// A local binding, and then the capture of it by a nested function.
///
/// Resolving a local from an inner function scope is what turns it into an
/// upvalue: the outer scope gains `ScopeFlags.env`, the symbol is marked
/// `keep`, its register is reserved in the outer *upvalue* allocator, and the
/// inner scope gains an environment reference. Five separate pieces of state,
/// all of which a wrong port could get individually wrong while still
/// producing a working closure.
fn aLocalIsCaptured() !strings.String {
    const symbol = symbols.new("captured");
    expect(primitives.shadowcheck(&compiler, symbol) == primitives.Shadowing.none);

    var slot: primitives.Slot = std.mem.zeroes(primitives.Slot);
    slot.index = 4;
    slot.envindex = -1;
    try primitives.nameslot(&compiler, symbol, slot, constants.defflag_no_shadowcheck);
    expect(vector.count(scope.syms) == 2);
    expect(scope.syms.items[1].sym == symbol);
    expect(scope.syms.items[1].sym2 == symbol);
    expect(scope.syms.items[1].slot.flags.named);
    expect(scope.syms.items[1].birth_pc == 2);
    expect(scope.syms.items[1].death_pc == std.math.maxInt(u32));
    expect(primitives.shadowcheck(&compiler, symbol) == primitives.Shadowing.local_hides_local);

    // Resolving it in its own scope marks it used and leaves it local.
    slot = try primitives.resolve(&compiler, symbol);
    expect(slot.index == 4 and slot.envindex == -1);
    expect(scope.syms.items[1].referenced);

    // Resolving it from inside a function scope captures it.
    primitives.pushScope(&child, &compiler, .{ .function = true }, "capture");
    slot = try primitives.resolve(&compiler, symbol);
    expect(slot.index == 4 and slot.envindex == 0);
    expect(scope.flags.env);
    expect(scope.syms.items[1].keep);
    expect(scope.ua.isTaken(4));
    expect(vector.count(child.envs) == 1);
    expect(child.envs.items[0].envindex == -1);
    expect(child.envs.items[0].scope == &scope);

    try primitives.popscope(&compiler);
    expect(compiler.scope == &scope);
    return symbol;
}

/// The funcdef that falls out of the finished scope, including the debug
/// image a stack trace reads.
fn theFinishedFuncdef(captured: strings.String) !void {
    const options = primitives.foptsDefault(&compiler);
    compiler.recursion_guard = recursion_guard;
    try primitives.throwaway(options, harness.wrapInteger(99));
    // A thrown-away value emits nothing new, and leaves the scope where it
    // found it.
    expect(compiler.scope == &scope);
    expect(emittedCount() == 3);

    const definition = try primitives.popFuncdef(&compiler);
    expect(compiler.scope == null);
    expect(definition.slotcount == scope.ra.max + 1);
    expect(definition.bytecode_length == 3);
    expect(definition.instructions()[0] == harness.op(constants.Opcode.push) | (1 << 8));
    expect(definition.instructions()[1] == harness.op(constants.Opcode.push_array) | (2 << 8));
    expect(definition.instructions()[2] == harness.op(constants.Opcode.push) | (3 << 8));
    expect(definition.constants_length > 0);
    expect(definition.defs_length == 0);
    expect(definition.environments_length == 0);
    // The scope was captured from, so the function needs an environment and
    // records which of its registers are closed over.
    expect(definition.flags.needsenv);
    expect(definition.flags.hassymbolmap);
    expect(definition.closure_bitset != null);
    expect(definition.closureBits()[0] & (@as(u32, 1) << 4) != 0);
    // The symbol map is what `(debug/stack)` reads.
    expect(definition.symbolmap_length == 1);
    expect(definition.symbols()[0].birth_pc == 2);
    expect(definition.symbols()[0].death_pc == 3);
    expect(definition.symbols()[0].slot_index == 4);
    expect(definition.symbols()[0].symbol == captured);
    // The compiler's buffer was moved into the funcdef rather than copied.
    expect(emittedCount() == 0);
}

/// An unresolvable symbol is a recorded error rather than a raise, and the
/// first error is the one that is kept.
fn theFirstErrorIsKept() !void {
    const symbol = symbols.new("missing");
    const slot = try primitives.resolve(&compiler, symbol);
    expect(slot.flags.constant);
    expect(harness.isType(slot.constant, repr.Tag.nil));
    expect(compiler.result.status == primitives.CompileStatus.@"error");
    expect(compiler.result.@"error" != null);

    const first = compiler.result.@"error";
    primitives.cerror(&compiler, "replacement error");
    expect(compiler.result.@"error" == first);
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() !void {
    theDefaultFormOptions();
    aConstantSlotRemembersItsType();
    aNamedSlotIsNotReclaimed();
    theFuncdefFlagsAreDerived();
    try poppingAScopeHandsUpItsSymbols();
    try anUnusedScopeStillKeepsItsResultSlot();
    returningIsIdempotent();
    aHintIsHonouredOnlyWhenItIsNear();
    try valuesBecomeSlots();
    try theFourKindsOfForm();
    try aVectorIsALiteral();
    theArgumentPush();
    try theGlobalBindings();
    const captured = try aLocalIsCaptured();
    try theFinishedFuncdef(captured);
    try aPlainFunctionNeedsNoEnvironment();
    try anUpvalueIsNotKeptAsARegister();
    try theFirstErrorIsKept();
}

pub fn run() void {
    harness.init();

    compiler = .{};
    scope = .{ .name = "" };
    compiler.env = tables.new(0);
    compiler.scope = &scope;
    scope.ra = .{};

    body() catch @panic("compiler_primitives: a kernel raised unexpectedly");

    vector.free(&compiler.buffer);
    vm_lifecycle.deinit();
}
