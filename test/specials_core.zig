//! Behavioral contract for the thirteen compiler special forms.
//!
//! `quote`, `splice`, `unquote`, `quasiquote`, `do`, `upscope`, `if`, `while`,
//! `break`, `set`, `var`, `def` and `fn`. The suites reach all of them through
//! Janet source and can see what they *compute*; what they cannot see is what
//! they *emit*, or which of them refuses a malformed form before the compiler
//! reaches the emitter at all. A special that produced correct results from
//! three instructions where two would do, or that reported the wrong arity
//! message, would pass every suite in the tree.
//!
//! So the first two-thirds of this file calls each special's `compile`
//! directly, with hand-built arguments and a hand-built scope, and asserts the
//! bytecode and the recorded error. The last third is Janet source, for the
//! cases where the interesting behaviour is a whole compilation: a `while`
//! that closes over its condition, a destructuring `var`, and the five
//! parameter forms of `fn`.
//!
//! ## The callbacks are called directly
//!
//! A `special_type.Special`'s `compile` is a raising Zig function, and this
//! file calls it as one, with `try`. No shim stands between the two, so a
//! raise from a macro or a lint arrives as `error.JanetSignal` and the
//! compiler checks that this file handles it.

// ==========================================================================
// Project imports
// ==========================================================================

const compiler_primitives = @import("subsystems").compiler_primitives;
const config = @import("config");
const constants = @import("constants");
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const harness = @import("harness.zig");
const repr = @import("repr");
const special_type = subsystems.special;
const specials_core = @import("subsystems").specials_core;
const subsystems = @import("subsystems");
const symbols = @import("subsystems").value.symbols;
const tables = @import("subsystems").value.tables;
const tuples = @import("subsystems").value.tuples;
const value = @import("subsystems").value;
const vector = harness.vector;
const maps = @import("subsystems").value.maps;
const vectors = @import("subsystems").value.vectors;
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

/// A special by name, with the raising signature it has.
///
/// There is one description per special, so the lookup gives back the callback
/// itself rather than a storage type to be cast.
fn special(name: [*:0]const u8) *const special_type.Special {
    const found = specials_core.lookupSpecial(symbols.csymbol(name));
    expect(found != null);
    return found.?;
}

/// Compile one form through a special, the way `valueImpl` would. `count` is
/// separate from the slice so that a caller can pass fewer arguments than the
/// array it built has room for.
fn compile(name: [*:0]const u8, options: compiler_primitives.FormOptions, count: i32, arguments: []const repr.Value) !compiler_primitives.Slot {
    return special(name).compile.?(options, arguments[0..@intCast(count)]);
}

fn clearError() void {
    compiler.result.status = compiler_primitives.CompileStatus.ok;
    compiler.result.@"error" = null;
    compiler.recursion_guard = config.recursion_guard;
}

fn failedWith(message: [*:0]const u8) bool {
    return compiler.result.status == compiler_primitives.CompileStatus.@"error" and
        harness.stringIs(compiler.result.@"error".?, message);
}

fn emitted(index: usize) u32 {
    return compiler.buffer.items[index];
}

fn emittedCount() i32 {
    return @intCast(vector.count(compiler.buffer));
}

fn operationOf(word: u32) u32 {
    return word & 0xFF;
}

/// The lookup itself: an unknown name is not a special, which is what lets
/// `valueImpl` fall through to a function call.
fn anUnknownNameIsNotASpecial() void {
    expect(specials_core.lookupSpecial(symbols.csymbol("not-a-special")) == null);
}

/// `quote` gives back its argument untouched, and `splice` gives it back with
/// a flag, but only where the surrounding form said it would accept one.
/// Everywhere else it is an error with a whole sentence of explanation,
/// which is the message users actually meet.
fn theQuotingForms(arguments: []const repr.Value) !void {
    var options = compiler_primitives.foptsDefault(&compiler);

    var result = try compile("quote", options, 1, arguments);
    expect(result.flags.constant);
    expect(harness.integerIs(result.constant, 1));

    result = try compile("quote", options, 0, arguments);
    expect(harness.isType(result.constant, repr.Tag.nil));
    expect(failedWith("expected 1 argument to quote"));
    clearError();

    result = try compile("splice", options, 1, arguments);
    expect(harness.isType(result.constant, repr.Tag.nil));
    expect(failedWith(
        "splice can only be used in function parameters and data constructors, it has no effect here",
    ));
    clearError();

    options.flags.accept_splice = true;
    result = try compile("splice", options, 1, arguments);
    expect(result.flags.constant);
    expect(result.flags.spliced);
    expect(harness.integerIs(result.constant, 1));
    options.flags = .{};

    // `unquote` is only meaningful inside a quasiquote, and the special is
    // registered so that it can say so rather than resolve as a function.
    result = try compile("unquote", options, 0, arguments);
    expect(harness.isType(result.constant, repr.Tag.nil));
    expect(failedWith("cannot use unquote here"));
    clearError();
}

/// `do` and `upscope` both produce their last form; the difference is that
/// `do` opens a scope and `upscope` does not. Neither leaves one open.
fn theSequencingForms(arguments: []const repr.Value) !void {
    const options = compiler_primitives.foptsDefault(&compiler);

    var result = try compile("do", options, 2, arguments);
    expect(result.flags.constant);
    expect(harness.integerIs(result.constant, 2));
    expect(compiler.scope == null);

    // An empty body is nil rather than an error.
    result = try compile("do", options, 0, arguments);
    expect(result.flags.constant);
    expect(harness.isType(result.constant, repr.Tag.nil));
    expect(compiler.scope == null);

    result = try compile("upscope", options, 2, arguments);
    expect(result.flags.constant);
    expect(harness.integerIs(result.constant, 2));
    expect(compiler.scope == null);
}

/// `break` emits a different instruction depending on what encloses it, and
/// refuses when nothing does.
fn theBreakForm(arguments: []const repr.Value) !void {
    const options = compiler_primitives.foptsDefault(&compiler);

    var result = try compile("break", options, 0, arguments);
    expect(harness.isType(result.constant, repr.Tag.nil));
    expect(failedWith("break must occur in while loop or closure"));
    clearError();

    // In a function it returns.
    compiler_primitives.pushScope(&scope, &compiler, .{ .function = true }, "function");
    result = try compile("break", options, 0, arguments);
    expect(harness.isType(result.constant, repr.Tag.nil));
    expect(emittedCount() == 1);
    expect(emitted(0) == harness.op(constants.Opcode.return_nil));
    try compiler_primitives.popscope(&compiler);

    // In a while loop it jumps, and the displacement is patched later, so the
    // word is the placeholder the loop will overwrite.
    vector.empty(&compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, .{ .while_body = true }, "while");
    result = try compile("break", options, 0, arguments);
    expect(harness.isType(result.constant, repr.Tag.nil));
    expect(emittedCount() == 1);
    expect(emitted(0) == 0x80 | harness.op(constants.Opcode.jump));
    try compiler_primitives.popscope(&compiler);
}

/// `if` folds when the condition is a constant the compiler can see, and
/// branches when it is not. Folding is what keeps `(if false ...)` from
/// emitting a dead arm.
fn theIfForm(arguments: []repr.Value) !void {
    const options = compiler_primitives.foptsDefault(&compiler);

    var result = try compile("if", options, 1, arguments);
    expect(harness.isType(result.constant, repr.Tag.nil));
    expect(failedWith("expected 2 or 3 arguments to if"));
    clearError();

    // A constant-true condition compiles only the true arm, which here is one
    // instruction rather than a jump, an arm, a jump and an arm.
    vector.empty(&compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, .{ .function = true }, "if-root");
    arguments[0] = wrap.fromTrue();
    arguments[1] = harness.wrapInteger(11);
    arguments[2] = harness.wrapInteger(22);
    result = try compile("if", options, 3, arguments);
    expect(compiler.result.status == compiler_primitives.CompileStatus.ok);
    expect(!result.flags.constant);
    expect(emittedCount() == 1);
    try compiler_primitives.popscope(&compiler);

    // A condition the compiler cannot see through emits a real branch, and
    // the jump displacement is patched to a nonzero value.
    vector.empty(&compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, .{ .function = true }, "if-root");
    {
        const symbol = symbols.csymbol("condition");
        const condition = compiler_primitives.farslot(&compiler).?;
        try compiler_primitives.nameslot(&compiler, symbol, condition, constants.JANET_DEFFLAG_NO_SHADOWCHECK);
        arguments[0] = wrap.fromSymbol(symbol);
    }
    result = try compile("if", options, 3, arguments);
    expect(compiler.result.status == compiler_primitives.CompileStatus.ok);
    expect(!result.flags.constant);
    expect(emittedCount() >= 4);
    expect(operationOf(emitted(0)) == harness.op(constants.Opcode.jump_if_not));
    expect(emitted(0) >> 16 != 0);
    try compiler_primitives.popscope(&compiler);
}

/// `quasiquote` folds to a constant wherever it can, rewrites `unquote` into
/// the value it names, and builds the structure at run time only when it has
/// to.
fn theQuasiquoteForm(arguments: []repr.Value) !void {
    const options = compiler_primitives.foptsDefault(&compiler);

    var result = try compile("quasiquote", options, 0, arguments);
    expect(harness.isType(result.constant, repr.Tag.nil));
    expect(failedWith("expected 1 argument to quasiquote"));
    clearError();

    arguments[0] = harness.wrapInteger(42);
    result = try compile("quasiquote", options, 1, arguments);
    expect(result.flags.constant);
    expect(harness.integerIs(result.constant, 42));

    var tuple = tuples.begin(2);
    tuple[0] = value.fromBytes("unquote", .symbol);
    tuple[1] = harness.wrapInteger(43);
    arguments[0] = wrap.fromTuple(tuples.end(tuple));
    result = try compile("quasiquote", options, 1, arguments);
    expect(result.flags.constant);
    expect(harness.integerIs(result.constant, 43));

    // A quoted tuple is not a constant, because a tuple is built rather than
    // interned, so the last instruction constructs it.
    vector.empty(&compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, .{ .function = true }, "quasiquote-root");
    tuple = tuples.begin(2);
    tuple[0] = harness.wrapInteger(1);
    tuple[1] = harness.wrapInteger(2);
    arguments[0] = wrap.fromTuple(tuples.end(tuple));
    result = try compile("quasiquote", options, 1, arguments);
    expect(!result.flags.constant);
    expect(emittedCount() == 4);
    expect(operationOf(emitted(3)) == harness.op(constants.Opcode.make_tuple));
    try compiler_primitives.popscope(&compiler);

    // A quasiquoted vector is rebuilt the same way, by its own constructor.
    // Before the arm it fell through to `cslot`, so `~[,x]` kept the literal
    // `(unquote x)` as an element.
    vector.empty(&compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, .{ .function = true }, "quasiquote-vector");
    var elements = [2]repr.Value{ harness.wrapInteger(1), harness.wrapInteger(2) };
    arguments[0] = wrap.fromVector(vectors.fromSlice(&elements));
    result = try compile("quasiquote", options, 1, arguments);
    expect(!result.flags.constant);
    expect(operationOf(emitted(@intCast(emittedCount() - 1))) == harness.op(constants.Opcode.make_vector));
    try compiler_primitives.popscope(&compiler);

    // A quasiquoted set is rebuilt too, but by a call rather than an opcode:
    // `notes/LANGUAGE.md` decided on 2026-09-18 against a `make_set`, so the
    // last instruction is `call` on a constant holding `hash-set` itself.
    vector.empty(&compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, .{ .function = true }, "quasiquote-set");
    var set_elements = [2]repr.Value{ harness.wrapInteger(1), harness.wrapInteger(2) };
    arguments[0] = wrap.fromAbstract(maps.build(.set, &set_elements));
    result = try compile("quasiquote", options, 1, arguments);
    expect(!result.flags.constant);
    expect(operationOf(emitted(@intCast(emittedCount() - 1))) == harness.op(constants.Opcode.call));
    expect(compiler.result.status == compiler_primitives.CompileStatus.ok);
    try compiler_primitives.popscope(&compiler);

    // An unquote inside one is compiled, not kept: the element is the form's
    // result rather than the `(unquote 43)` tuple.
    vector.empty(&compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, .{ .function = true }, "quasiquote-unquote");
    tuple = tuples.begin(2);
    tuple[0] = value.fromBytes("unquote", .symbol);
    tuple[1] = harness.wrapInteger(43);
    elements[1] = wrap.fromTuple(tuples.end(tuple));
    arguments[0] = wrap.fromVector(vectors.fromSlice(&elements));
    result = try compile("quasiquote", options, 1, arguments);
    expect(!result.flags.constant);
    expect(operationOf(emitted(@intCast(emittedCount() - 1))) == harness.op(constants.Opcode.make_vector));
    expect(compiler.result.status == compiler_primitives.CompileStatus.ok);
    try compiler_primitives.popscope(&compiler);
}

/// `while` with a constant condition is either nothing at all or an infinite
/// loop, and with a real condition it is a test, a body and a back-jump. All
/// three displacements are asserted, because a loop that jumps one instruction
/// wrong still terminates and still computes the wrong result.
fn theWhileForm(arguments: []repr.Value) !void {
    const options = compiler_primitives.foptsDefault(&compiler);

    var result = try compile("while", options, 0, arguments);
    expect(harness.isType(result.constant, repr.Tag.nil));
    expect(failedWith("expected at least 1 argument to while"));
    clearError();

    // A constant-false condition emits nothing.
    vector.empty(&compiler.buffer);
    arguments[0] = wrap.fromFalse();
    result = try compile("while", options, 1, arguments);
    expect(harness.isType(result.constant, repr.Tag.nil));
    expect(emittedCount() == 0);
    expect(compiler.scope == null);

    // A constant-true one emits the back-jump and nothing else.
    arguments[0] = wrap.fromTrue();
    result = try compile("while", options, 1, arguments);
    expect(harness.isType(result.constant, repr.Tag.nil));
    expect(emittedCount() == 1);
    expect(operationOf(emitted(0)) == harness.op(constants.Opcode.jump));
    expect(compiler.scope == null);

    // A real condition with a `break` in the body: test, break-jump,
    // back-jump. The break jumps two forward, past the back-jump.
    vector.empty(&compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, .{ .function = true }, "while-root");
    {
        const symbol = symbols.csymbol("while-condition");
        const condition = compiler_primitives.farslot(&compiler).?;
        try compiler_primitives.nameslot(&compiler, symbol, condition, constants.JANET_DEFFLAG_NO_SHADOWCHECK);
        arguments[0] = wrap.fromSymbol(symbol);
        const tuple = tuples.begin(1);
        tuple[0] = value.fromBytes("break", .symbol);
        arguments[1] = wrap.fromTuple(tuples.end(tuple));
    }
    result = try compile("while", options, 2, arguments);
    expect(harness.isType(result.constant, repr.Tag.nil));
    expect(emittedCount() == 3);
    expect(operationOf(emitted(0)) == harness.op(constants.Opcode.jump_if_not));
    expect(emitted(0) >> 16 == 3);
    expect(operationOf(emitted(1)) == harness.op(constants.Opcode.jump));
    expect(emitted(1) >> 8 == 2);
    expect(operationOf(emitted(2)) == harness.op(constants.Opcode.jump));
    try compiler_primitives.popscope(&compiler);
}

/// `set` takes a symbol or a tuple; the first is a register write and the
/// second a `put` into a data structure.
fn theSetForm(arguments: []repr.Value) !void {
    const options = compiler_primitives.foptsDefault(&compiler);

    var result = try compile("set", options, 1, arguments);
    expect(harness.isType(result.constant, repr.Tag.nil));
    expect(failedWith("expected 2 arguments to set"));
    clearError();

    arguments[0] = harness.wrapInteger(1);
    result = try compile("set", options, 2, arguments);
    expect(harness.isType(result.constant, repr.Tag.nil));
    expect(failedWith("expected symbol or tuple for l-value to set"));
    clearError();

    // A mutable local is written in place, so the result is the same slot.
    vector.empty(&compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, .{ .function = true }, "set-root");
    {
        const symbol = symbols.csymbol("mutable");
        var slot = compiler_primitives.farslot(&compiler).?;
        slot.flags.mutable = true;
        try compiler_primitives.nameslot(&compiler, symbol, slot, constants.JANET_DEFFLAG_NO_SHADOWCHECK);
        arguments[0] = wrap.fromSymbol(symbol);
        arguments[1] = harness.wrapInteger(7);
        result = try compile("set", options, 2, arguments);
        expect(compiler.result.status == compiler_primitives.CompileStatus.ok);
        expect(result.index == slot.index);
    }
    try compiler_primitives.popscope(&compiler);

    // A tuple l-value is a field write.
    vector.empty(&compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, .{ .function = true }, "set-field-root");
    {
        const table = tables.new(1);
        const tuple = tuples.begin(2);
        tuple[0] = wrap.fromTable(table);
        tuple[1] = value.fromBytes("key", .keyword);
        arguments[0] = wrap.fromTuple(tuples.end(tuple));
        arguments[1] = harness.wrapInteger(8);
        result = try compile("set", options, 2, arguments);
        expect(compiler.result.status == compiler_primitives.CompileStatus.ok);
        expect(emittedCount() > 0);
        expect(operationOf(emitted(@intCast(emittedCount() - 1))) == harness.op(constants.Opcode.put));
    }
    try compiler_primitives.popscope(&compiler);
}

/// The two binding forms and the function literal, each on its arity check,
/// and `fn` on the state it must leave behind when it refuses.
///
/// That last part is the one worth having: `fn` opens a scope before it
/// validates its parameters, so a refusal that forgot to close it would leave
/// the compiler one scope deep and corrupt every form after it. The assertion
/// is `compiler.scope == &scope`.
fn theBindingForms(arguments: []repr.Value) !void {
    const options = compiler_primitives.foptsDefault(&compiler);

    var result = try compile("var", options, 1, arguments);
    expect(harness.isType(result.constant, repr.Tag.nil));
    expect(failedWith("expected at least 2 arguments to var"));
    clearError();

    result = try compile("def", options, 1, arguments);
    expect(harness.isType(result.constant, repr.Tag.nil));
    expect(failedWith("expected at least 2 arguments to def"));
    clearError();

    vector.empty(&compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, .{ .function = true }, "fn-root");
    result = try compile("fn", options, 0, arguments);
    expect(harness.isType(result.constant, repr.Tag.nil));
    expect(failedWith("expected at least 1 argument to function literal"));
    expect(compiler.scope == &scope);
    clearError();

    arguments[0] = harness.wrapInteger(1);
    result = try compile("fn", options, 1, arguments);
    expect(harness.isType(result.constant, repr.Tag.nil));
    expect(failedWith("expected function parameters"));
    expect(compiler.scope == &scope);
    clearError();

    // An empty parameter list is a whole function: one funcdef on the parent
    // scope, and a closure instruction to make it.
    const tuple = tuples.begin(0);
    arguments[0] = wrap.fromTuple(tuples.end(tuple));
    result = try compile("fn", options, 1, arguments);
    expect(compiler.result.status == compiler_primitives.CompileStatus.ok);
    expect(!result.flags.constant);
    expect(vector.count(scope.defs) == 1);
    expect(scope.defs.items[0].arity == 0);
    expect(scope.defs.items[0].min_arity == 0);
    expect(scope.defs.items[0].max_arity == 0);
    expect(scope.defs.items[0].bytecode_length == 1);
    expect(operationOf(scope.defs.items[0].instructions()[0]) == harness.op(constants.Opcode.return_nil));
    expect(operationOf(emitted(@intCast(emittedCount() - 1))) == harness.op(constants.Opcode.closure));
    try compiler_primitives.popscope(&compiler);
}

/// A vector in the two binding positions: a parameter list and a
/// destructuring pattern.
///
/// The parser cannot emit a vector yet and no suite can reach these, so this
/// is the whole check on them. Before the arms, a vector parameter list was
/// refused with "expected function parameters" and a vector pattern with
/// "unexpected type in destructuring".
fn theVectorBindingForms(arguments: []repr.Value) !void {
    const options = compiler_primitives.foptsDefault(&compiler);
    // Naming a parameter runs the shadow check, which reads the environment.
    // The cases above bind nothing, so this is the first to need one.
    compiler.env = tables.new(0);
    var parameters = [2]repr.Value{
        value.fromBytes("x", .symbol),
        value.fromBytes("y", .symbol),
    };

    // A vector of symbols is a parameter list, and its length is the arity.
    vector.empty(&compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, .{ .function = true }, "vector-fn-root");
    arguments[0] = wrap.fromVector(vectors.fromSlice(&parameters));
    arguments[1] = value.fromBytes("x", .symbol);
    var result = try compile("fn", options, 2, arguments);
    expect(compiler.result.status == compiler_primitives.CompileStatus.ok);
    expect(!result.flags.constant);
    expect(vector.count(scope.defs) == 1);
    expect(scope.defs.items[0].arity == 2);
    expect(scope.defs.items[0].min_arity == 2);
    expect(scope.defs.items[0].max_arity == 2);
    try compiler_primitives.popscope(&compiler);

    // A vector is a destructuring pattern, read by position as a tuple is:
    // one `get_index` per element.
    vector.empty(&compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, .{ .function = true }, "vector-def-root");
    arguments[0] = wrap.fromVector(vectors.fromSlice(&parameters));
    arguments[1] = harness.wrapInteger(7);
    result = try compile("def", options, 2, arguments);
    expect(compiler.result.status == compiler_primitives.CompileStatus.ok);
    var reads: i32 = 0;
    for (0..@intCast(emittedCount())) |index| {
        if (operationOf(emitted(index)) == harness.op(constants.Opcode.get_index)) reads += 1;
    }
    expect(reads == 2);
    try compiler_primitives.popscope(&compiler);
}

/// The cases where the interesting behaviour is a whole compilation, driven
/// from Janet source because that is what they are about.
///
/// A protected call is the instrument here and always was: what raises is
/// inside the interpreter, not inside a Zig function this file could import.
/// The same file uses the import for a special's `compile` and `env.dostring`
/// for a whole program, and neither could be substituted for
/// the other.
fn theWholeCompilations() void {
    const environment = harness.coreEnv();
    var output: repr.Value = undefined;

    // A `while` whose body closes over the condition: the loop variable has
    // to be kept alive across iterations rather than reused.
    expect(core_env.dostring(
        environment,
        "(fn [condition] (while condition (fn [] condition) (break)))",
        "specials-core-test",
        &output,
    ) == 0);
    expect(harness.isType(output, repr.Tag.function));

    // The same shape, run rather than only compiled, with a `set` in it.
    expect(core_env.dostring(
        environment,
        "(do (var while-result 0) " ++
            "((fn [condition] " ++
            "   (while condition " ++
            "     (fn [] condition) " ++
            "     (set while-result 1) " ++
            "     (break))) true) " ++
            "while-result)",
        "specials-core-test",
        &output,
    ) == 0);
    expect(harness.integerIs(output, 1));

    // Destructuring `var`, including a rest binding, and a `set` on one of
    // the destructured names.
    expect(core_env.dostring(
        environment,
        "(do " ++
            "  (var [binding-a binding-b & binding-rest] [1 2 3 4]) " ++
            "  (set binding-a 5) " ++
            "  [binding-a binding-b binding-rest])",
        "specials-core-test",
        &output,
    ) == 0);
    expect(harness.isType(output, repr.Tag.tuple));
    {
        const result = wrap.toTuple(output);
        expect(tuples.head(result).length == 3);
        expect(harness.integerIs(result[0], 5));
        expect(harness.integerIs(result[1], 2));
        const rest = wrap.toTuple(result[2]);
        expect(tuples.head(rest).length == 2);
        expect(harness.integerIs(rest[0], 3));
        expect(harness.integerIs(rest[1], 4));
    }

    // Destructuring a struct by key.
    expect(core_env.dostring(
        environment,
        "(do (def {:x binding-x} {:x 9}) binding-x)",
        "specials-core-test",
        &output,
    ) == 0);
    expect(harness.integerIs(output, 9));

    // A docstring between the name and the value, which `def` moves into the
    // binding's table rather than treating as the value.
    expect(core_env.dostring(
        environment,
        "(def binding-with-doc \"binding documentation\" 10)",
        "specials-core-test",
        &output,
    ) == 0);
    {
        const binding = tables.get(environment, value.fromBytes("binding-with-doc", .symbol));
        const doc = tables.get(wrap.toTable(binding), value.fromBytes("doc", .keyword));
        expect(harness.stringValueIs(doc, "binding documentation"));
    }

    // The five parameter forms: destructured, optional, rest, named, and a
    // self-referential name for recursion.
    expect(core_env.dostring(
        environment,
        "[ ((fn [[a b]] (+ a b)) [2 3]) " ++
            "  ((fn [a &opt b] [a b]) 1) " ++
            "  ((fn [a & rest] rest) 1 2 3) " ++
            "  ((fn [&named x y] [x y]) :y 2 :x 1) " ++
            "  ((fn recur [n] " ++
            "     (if (zero? n) 0 (+ 1 (recur (- n 1))))) 3) ]",
        "specials-core-test",
        &output,
    ) == 0);
    expect(harness.isType(output, repr.Tag.tuple));
    {
        const results = wrap.toTuple(output);
        expect(tuples.head(results).length == 5);
        expect(harness.integerIs(results[0], 5));

        const optional = wrap.toTuple(results[1]);
        expect(harness.integerIs(optional[0], 1));
        expect(harness.isType(optional[1], repr.Tag.nil));

        const rest = wrap.toTuple(results[2]);
        expect(tuples.head(rest).length == 2);
        expect(harness.integerIs(rest[0], 2));
        expect(harness.integerIs(rest[1], 3));

        const named = wrap.toTuple(results[3]);
        expect(harness.integerIs(named[0], 1));
        expect(harness.integerIs(named[1], 2));

        expect(harness.integerIs(results[4], 3));
    }
}

// ==========================================================================
// Entry
// ==========================================================================

fn body() !void {
    anUnknownNameIsNotASpecial();

    compiler = .{};
    compiler.recursion_guard = config.recursion_guard;
    var arguments = [3]repr.Value{
        harness.wrapInteger(1),
        harness.wrapInteger(2),
        wrap.fromNil(),
    };

    try theQuotingForms(&arguments);
    try theSequencingForms(&arguments);
    try theBreakForm(&arguments);
    try theIfForm(&arguments);
    try theQuasiquoteForm(&arguments);
    try theWhileForm(&arguments);
    try theSetForm(&arguments);
    try theBindingForms(&arguments);
    try theVectorBindingForms(&arguments);

    vector.free(&compiler.buffer);
    theWholeCompilations();
}

pub fn run() void {
    harness.init();
    body() catch @panic("specials_core: a kernel raised unexpectedly");
    vm_lifecycle.deinit();
}
