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
//! cases where the interesting behaviour is a whole compilation — a `while`
//! that closes over its condition, a destructuring `var`, the five parameter
//! forms of `fn`.
//!
//! ## The shim that dies here
//!
//! A `JanetSpecial`'s `compile` has been a raising Zig function since Phase
//! 10's hinge, so a C contract could not call one: `test/support.zig` carried
//! `janet_contract_special_compile` for exactly this file, and nothing else.
//! Here the call is `special.of(...).compile.?(...)` with `try`, so the shim
//! has no caller and goes with the contract — along with the `special` module
//! `build.zig` was building a second time to give it a layout.
//!
//! That is Part 5's lesson again and this is its clearest case: the shim's
//! comment said it existed for `test/specials_core.c`, and it did, and it was
//! the last thing standing between the build and one fewer module.

const std = @import("std");
const config = @import("config");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const harness = @import("harness.zig");
const vector = harness.vector;
const subsystems = @import("subsystems");
const value = @import("subsystems").value;
const tables = @import("subsystems").value.tables;
const symbols = @import("subsystems").value.symbols;
const tuples = @import("subsystems").value.tuples;
const compiler_primitives = @import("subsystems").compiler_primitives;
const core_env = @import("subsystems").env;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const specials_core = @import("subsystems").specials_core;
const primitives = subsystems.compiler_primitives;
const special_type = subsystems.special;

var compiler: types.JanetCompiler = undefined;
var scope: types.JanetScope = undefined;

/// A special by name, with the raising signature it actually has.
///
/// `janetc_special` answers `compile.h`'s `const JanetSpecial *`, which is
/// storage rather than a calling convention; `special.of` is the cast that
/// says what the callback really is.
fn special(name: [*:0]const u8) *const special_type.Special {
    const found = specials_core.lookupSpecial(symbols.csymbol(name));
    std.debug.assert(found != null);
    return special_type.of(found);
}

/// Compile one form through a special, the way `janetc_value` would.
fn compile(name: [*:0]const u8, options: types.JanetFopts, count: i32, arguments: []const types.Janet) !types.JanetSlot {
    return special(name).compile.?(options, count, arguments.ptr);
}

fn clearError() void {
    compiler.result.status = constants.JANET_COMPILE_OK;
    compiler.result.@"error" = null;
    compiler.recursion_guard = config.recursion_guard;
}

fn failedWith(message: [*:0]const u8) bool {
    return compiler.result.status == constants.JANET_COMPILE_ERROR and
        harness.stringIs(compiler.result.@"error".?, message);
}

fn emitted(index: usize) u32 {
    return compiler.buffer.?[index];
}

fn emittedCount() i32 {
    return vector.count(compiler.buffer);
}

fn operationOf(word: u32) u32 {
    return word & 0xFF;
}

/// The lookup itself: an unknown name is not a special, which is what lets
/// `janetc_value` fall through to a function call.
fn anUnknownNameIsNotASpecial() void {
    std.debug.assert(specials_core.lookupSpecial(symbols.csymbol("not-a-special")) == null);
}

/// `quote` answers its argument untouched, and `splice` answers its argument
/// with a flag — but only where the surrounding form said it would accept
/// one. Everywhere else it is an error with a whole sentence of explanation,
/// which is the message users actually meet.
fn theQuotingForms(arguments: []const types.Janet) !void {
    var options = compiler_primitives.foptsDefault(&compiler);

    var result = try compile("quote", options, 1, arguments);
    std.debug.assert(result.flags & constants.JANET_SLOT_CONSTANT != 0);
    std.debug.assert(harness.integerIs(result.constant, 1));

    result = try compile("quote", options, 0, arguments);
    std.debug.assert(harness.isType(result.constant, constants.JANET_NIL));
    std.debug.assert(failedWith("expected 1 argument to quote"));
    clearError();

    result = try compile("splice", options, 1, arguments);
    std.debug.assert(harness.isType(result.constant, constants.JANET_NIL));
    std.debug.assert(failedWith(
        "splice can only be used in function parameters and data constructors, it has no effect here",
    ));
    clearError();

    options.flags |= constants.JANET_FOPTS_ACCEPT_SPLICE;
    result = try compile("splice", options, 1, arguments);
    std.debug.assert(result.flags & constants.JANET_SLOT_CONSTANT != 0);
    std.debug.assert(result.flags & constants.JANET_SLOT_SPLICED != 0);
    std.debug.assert(harness.integerIs(result.constant, 1));
    options.flags = 0;

    // `unquote` is only meaningful inside a quasiquote, and the special is
    // registered so that it can say so rather than resolve as a function.
    result = try compile("unquote", options, 0, arguments);
    std.debug.assert(harness.isType(result.constant, constants.JANET_NIL));
    std.debug.assert(failedWith("cannot use unquote here"));
    clearError();
}

/// `do` and `upscope` both answer their last form; the difference is that
/// `do` opens a scope and `upscope` does not. Neither leaves one open.
fn theSequencingForms(arguments: []const types.Janet) !void {
    const options = compiler_primitives.foptsDefault(&compiler);

    var result = try compile("do", options, 2, arguments);
    std.debug.assert(result.flags & constants.JANET_SLOT_CONSTANT != 0);
    std.debug.assert(harness.integerIs(result.constant, 2));
    std.debug.assert(compiler.scope == null);

    // An empty body is nil rather than an error.
    result = try compile("do", options, 0, arguments);
    std.debug.assert(result.flags & constants.JANET_SLOT_CONSTANT != 0);
    std.debug.assert(harness.isType(result.constant, constants.JANET_NIL));
    std.debug.assert(compiler.scope == null);

    result = try compile("upscope", options, 2, arguments);
    std.debug.assert(result.flags & constants.JANET_SLOT_CONSTANT != 0);
    std.debug.assert(harness.integerIs(result.constant, 2));
    std.debug.assert(compiler.scope == null);
}

/// `break` emits a different instruction depending on what encloses it, and
/// refuses when nothing does.
fn theBreakForm(arguments: []const types.Janet) !void {
    const options = compiler_primitives.foptsDefault(&compiler);

    var result = try compile("break", options, 0, arguments);
    std.debug.assert(harness.isType(result.constant, constants.JANET_NIL));
    std.debug.assert(failedWith("break must occur in while loop or closure"));
    clearError();

    // In a function it returns.
    compiler_primitives.pushScope(&scope, &compiler, constants.JANET_SCOPE_FUNCTION, "function");
    result = try compile("break", options, 0, arguments);
    std.debug.assert(harness.isType(result.constant, constants.JANET_NIL));
    std.debug.assert(emittedCount() == 1);
    std.debug.assert(emitted(0) == harness.op(constants.JOP_RETURN_NIL));
    try primitives.janetc_popscopeImpl(&compiler);

    // In a while loop it jumps, and the displacement is patched later — so
    // the word carries the placeholder the loop will overwrite.
    vector.empty(compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, constants.JANET_SCOPE_WHILE, "while");
    result = try compile("break", options, 0, arguments);
    std.debug.assert(harness.isType(result.constant, constants.JANET_NIL));
    std.debug.assert(emittedCount() == 1);
    std.debug.assert(emitted(0) == 0x80 | harness.op(constants.JOP_JUMP));
    try primitives.janetc_popscopeImpl(&compiler);
}

/// `if` folds when the condition is a known constant, and branches when it is
/// not. Folding is what keeps `(if false ...)` from emitting a dead arm.
fn theIfForm(arguments: []types.Janet) !void {
    const options = compiler_primitives.foptsDefault(&compiler);

    var result = try compile("if", options, 1, arguments);
    std.debug.assert(harness.isType(result.constant, constants.JANET_NIL));
    std.debug.assert(failedWith("expected 2 or 3 arguments to if"));
    clearError();

    // A constant-true condition compiles only the true arm, which here is one
    // instruction rather than a jump, an arm, a jump and an arm.
    vector.empty(compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, constants.JANET_SCOPE_FUNCTION, "if-root");
    arguments[0] = wrap.fromTrue();
    arguments[1] = harness.wrapInteger(11);
    arguments[2] = harness.wrapInteger(22);
    result = try compile("if", options, 3, arguments);
    std.debug.assert(compiler.result.status == constants.JANET_COMPILE_OK);
    std.debug.assert(result.flags & constants.JANET_SLOT_CONSTANT == 0);
    std.debug.assert(emittedCount() == 1);
    try primitives.janetc_popscopeImpl(&compiler);

    // A condition the compiler cannot see through emits a real branch, and
    // the jump displacement is patched to a nonzero value.
    vector.empty(compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, constants.JANET_SCOPE_FUNCTION, "if-root");
    {
        const symbol = symbols.csymbol("condition");
        const condition = compiler_primitives.farslot(&compiler);
        try primitives.janetc_nameslotImpl(&compiler, symbol, condition, constants.JANET_DEFFLAG_NO_SHADOWCHECK);
        arguments[0] = wrap.fromSymbol(symbol);
    }
    result = try compile("if", options, 3, arguments);
    std.debug.assert(compiler.result.status == constants.JANET_COMPILE_OK);
    std.debug.assert(result.flags & constants.JANET_SLOT_CONSTANT == 0);
    std.debug.assert(emittedCount() >= 4);
    std.debug.assert(operationOf(emitted(0)) == harness.op(constants.JOP_JUMP_IF_NOT));
    std.debug.assert(emitted(0) >> 16 != 0);
    try primitives.janetc_popscopeImpl(&compiler);
}

/// `quasiquote` folds to a constant wherever it can, rewrites `unquote` into
/// the value it names, and builds the structure at run time only when it has
/// to.
fn theQuasiquoteForm(arguments: []types.Janet) !void {
    const options = compiler_primitives.foptsDefault(&compiler);

    var result = try compile("quasiquote", options, 0, arguments);
    std.debug.assert(harness.isType(result.constant, constants.JANET_NIL));
    std.debug.assert(failedWith("expected 1 argument to quasiquote"));
    clearError();

    arguments[0] = harness.wrapInteger(42);
    result = try compile("quasiquote", options, 1, arguments);
    std.debug.assert(result.flags & constants.JANET_SLOT_CONSTANT != 0);
    std.debug.assert(harness.integerIs(result.constant, 42));

    var tuple = tuples.begin(2);
    tuple[0] = value.fromBytes("unquote", .symbol);
    tuple[1] = harness.wrapInteger(43);
    arguments[0] = wrap.fromTuple(tuples.end(tuple));
    result = try compile("quasiquote", options, 1, arguments);
    std.debug.assert(result.flags & constants.JANET_SLOT_CONSTANT != 0);
    std.debug.assert(harness.integerIs(result.constant, 43));

    // A quoted tuple is not a constant, because a tuple is built rather than
    // interned — so the last instruction constructs it.
    vector.empty(compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, constants.JANET_SCOPE_FUNCTION, "quasiquote-root");
    tuple = tuples.begin(2);
    tuple[0] = harness.wrapInteger(1);
    tuple[1] = harness.wrapInteger(2);
    arguments[0] = wrap.fromTuple(tuples.end(tuple));
    result = try compile("quasiquote", options, 1, arguments);
    std.debug.assert(result.flags & constants.JANET_SLOT_CONSTANT == 0);
    std.debug.assert(emittedCount() == 4);
    std.debug.assert(operationOf(emitted(3)) == harness.op(constants.JOP_MAKE_TUPLE));
    try primitives.janetc_popscopeImpl(&compiler);
}

/// `while` with a constant condition is either nothing at all or an infinite
/// loop, and with a real condition it is a test, a body and a back-jump —
/// with the three displacements asserted, because a loop that jumps one
/// instruction wrong still terminates and still gives the wrong answer.
fn theWhileForm(arguments: []types.Janet) !void {
    const options = compiler_primitives.foptsDefault(&compiler);

    var result = try compile("while", options, 0, arguments);
    std.debug.assert(harness.isType(result.constant, constants.JANET_NIL));
    std.debug.assert(failedWith("expected at least 1 argument to while"));
    clearError();

    // A constant-false condition emits nothing.
    vector.empty(compiler.buffer);
    arguments[0] = wrap.fromFalse();
    result = try compile("while", options, 1, arguments);
    std.debug.assert(harness.isType(result.constant, constants.JANET_NIL));
    std.debug.assert(emittedCount() == 0);
    std.debug.assert(compiler.scope == null);

    // A constant-true one emits the back-jump and nothing else.
    arguments[0] = wrap.fromTrue();
    result = try compile("while", options, 1, arguments);
    std.debug.assert(harness.isType(result.constant, constants.JANET_NIL));
    std.debug.assert(emittedCount() == 1);
    std.debug.assert(operationOf(emitted(0)) == harness.op(constants.JOP_JUMP));
    std.debug.assert(compiler.scope == null);

    // A real condition with a `break` in the body: test, break-jump,
    // back-jump. The break jumps two forward, past the back-jump.
    vector.empty(compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, constants.JANET_SCOPE_FUNCTION, "while-root");
    {
        const symbol = symbols.csymbol("while-condition");
        const condition = compiler_primitives.farslot(&compiler);
        try primitives.janetc_nameslotImpl(&compiler, symbol, condition, constants.JANET_DEFFLAG_NO_SHADOWCHECK);
        arguments[0] = wrap.fromSymbol(symbol);
        const tuple = tuples.begin(1);
        tuple[0] = value.fromBytes("break", .symbol);
        arguments[1] = wrap.fromTuple(tuples.end(tuple));
    }
    result = try compile("while", options, 2, arguments);
    std.debug.assert(harness.isType(result.constant, constants.JANET_NIL));
    std.debug.assert(emittedCount() == 3);
    std.debug.assert(operationOf(emitted(0)) == harness.op(constants.JOP_JUMP_IF_NOT));
    std.debug.assert(emitted(0) >> 16 == 3);
    std.debug.assert(operationOf(emitted(1)) == harness.op(constants.JOP_JUMP));
    std.debug.assert(emitted(1) >> 8 == 2);
    std.debug.assert(operationOf(emitted(2)) == harness.op(constants.JOP_JUMP));
    try primitives.janetc_popscopeImpl(&compiler);
}

/// `set` takes a symbol or a tuple; the first is a register write and the
/// second a `put` into a data structure.
fn theSetForm(arguments: []types.Janet) !void {
    const options = compiler_primitives.foptsDefault(&compiler);

    var result = try compile("set", options, 1, arguments);
    std.debug.assert(harness.isType(result.constant, constants.JANET_NIL));
    std.debug.assert(failedWith("expected 2 arguments to set"));
    clearError();

    arguments[0] = harness.wrapInteger(1);
    result = try compile("set", options, 2, arguments);
    std.debug.assert(harness.isType(result.constant, constants.JANET_NIL));
    std.debug.assert(failedWith("expected symbol or tuple for l-value to set"));
    clearError();

    // A mutable local is written in place, so the result is the same slot.
    vector.empty(compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, constants.JANET_SCOPE_FUNCTION, "set-root");
    {
        const symbol = symbols.csymbol("mutable");
        var slot = compiler_primitives.farslot(&compiler);
        slot.flags |= constants.JANET_SLOT_MUTABLE;
        try primitives.janetc_nameslotImpl(&compiler, symbol, slot, constants.JANET_DEFFLAG_NO_SHADOWCHECK);
        arguments[0] = wrap.fromSymbol(symbol);
        arguments[1] = harness.wrapInteger(7);
        result = try compile("set", options, 2, arguments);
        std.debug.assert(compiler.result.status == constants.JANET_COMPILE_OK);
        std.debug.assert(result.index == slot.index);
    }
    try primitives.janetc_popscopeImpl(&compiler);

    // A tuple l-value is a field write.
    vector.empty(compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, constants.JANET_SCOPE_FUNCTION, "set-field-root");
    {
        const table = tables.new(1);
        const tuple = tuples.begin(2);
        tuple[0] = wrap.fromTable(table);
        tuple[1] = value.fromBytes("key", .keyword);
        arguments[0] = wrap.fromTuple(tuples.end(tuple));
        arguments[1] = harness.wrapInteger(8);
        result = try compile("set", options, 2, arguments);
        std.debug.assert(compiler.result.status == constants.JANET_COMPILE_OK);
        std.debug.assert(emittedCount() > 0);
        std.debug.assert(operationOf(emitted(@intCast(emittedCount() - 1))) == harness.op(constants.JOP_PUT));
    }
    try primitives.janetc_popscopeImpl(&compiler);
}

/// The two binding forms and the function literal, each on its arity check,
/// and `fn` on the state it must leave behind when it refuses.
///
/// That last part is the one worth having: `fn` opens a scope before it
/// validates its parameters, so a refusal that forgot to close it would leave
/// the compiler one scope deep and corrupt every form after it. The assertion
/// is `compiler.scope == &scope`.
fn theBindingForms(arguments: []types.Janet) !void {
    const options = compiler_primitives.foptsDefault(&compiler);

    var result = try compile("var", options, 1, arguments);
    std.debug.assert(harness.isType(result.constant, constants.JANET_NIL));
    std.debug.assert(failedWith("expected at least 2 arguments to var"));
    clearError();

    result = try compile("def", options, 1, arguments);
    std.debug.assert(harness.isType(result.constant, constants.JANET_NIL));
    std.debug.assert(failedWith("expected at least 2 arguments to def"));
    clearError();

    vector.empty(compiler.buffer);
    compiler_primitives.pushScope(&scope, &compiler, constants.JANET_SCOPE_FUNCTION, "fn-root");
    result = try compile("fn", options, 0, arguments);
    std.debug.assert(harness.isType(result.constant, constants.JANET_NIL));
    std.debug.assert(failedWith("expected at least 1 argument to function literal"));
    std.debug.assert(compiler.scope == &scope);
    clearError();

    arguments[0] = harness.wrapInteger(1);
    result = try compile("fn", options, 1, arguments);
    std.debug.assert(harness.isType(result.constant, constants.JANET_NIL));
    std.debug.assert(failedWith("expected function parameters"));
    std.debug.assert(compiler.scope == &scope);
    clearError();

    // An empty parameter list is a whole function: one funcdef on the parent
    // scope, and a closure instruction to make it.
    const tuple = tuples.begin(0);
    arguments[0] = wrap.fromTuple(tuples.end(tuple));
    result = try compile("fn", options, 1, arguments);
    std.debug.assert(compiler.result.status == constants.JANET_COMPILE_OK);
    std.debug.assert(result.flags & constants.JANET_SLOT_CONSTANT == 0);
    std.debug.assert(vector.count(scope.defs) == 1);
    std.debug.assert(scope.defs.?[0].*.arity == 0);
    std.debug.assert(scope.defs.?[0].*.min_arity == 0);
    std.debug.assert(scope.defs.?[0].*.max_arity == 0);
    std.debug.assert(scope.defs.?[0].*.bytecode_length == 1);
    std.debug.assert(operationOf(scope.defs.?[0].*.bytecode.?[0]) == harness.op(constants.JOP_RETURN_NIL));
    std.debug.assert(operationOf(emitted(@intCast(emittedCount() - 1))) == harness.op(constants.JOP_CLOSURE));
    try primitives.janetc_popscopeImpl(&compiler);
}

/// The cases where the interesting behaviour is a whole compilation, driven
/// from Janet source because that is what they are about.
///
/// A protected call is the instrument here and always was: what raises is
/// inside the interpreter, not inside a Zig function this file could import.
/// Part 6 wrote that distinction down and this is the other half of it — the
/// same file uses the import for a special's `compile` and `janet_dostring`
/// for a whole program, and neither could be substituted for the other.
fn theWholeCompilations() void {
    const environment = harness.coreEnv();
    var output: types.Janet = undefined;

    // A `while` whose body closes over the condition: the loop variable has
    // to be kept alive across iterations rather than reused.
    std.debug.assert(core_env.dostring(
        environment,
        "(fn [condition] (while condition (fn [] condition) (break)))",
        "specials-core-test",
        &output,
    ) == 0);
    std.debug.assert(harness.isType(output, constants.JANET_FUNCTION));

    // The same shape, run rather than only compiled, with a `set` in it.
    std.debug.assert(core_env.dostring(
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
    std.debug.assert(harness.integerIs(output, 1));

    // Destructuring `var`, including a rest binding, and a `set` on one of
    // the destructured names.
    std.debug.assert(core_env.dostring(
        environment,
        "(do " ++
            "  (var [binding-a binding-b & binding-rest] [1 2 3 4]) " ++
            "  (set binding-a 5) " ++
            "  [binding-a binding-b binding-rest])",
        "specials-core-test",
        &output,
    ) == 0);
    std.debug.assert(harness.isType(output, constants.JANET_TUPLE));
    {
        const result = wrap.toTuple(output);
        std.debug.assert(types.tupleHead(result).length == 3);
        std.debug.assert(harness.integerIs(result[0], 5));
        std.debug.assert(harness.integerIs(result[1], 2));
        const rest = wrap.toTuple(result[2]);
        std.debug.assert(types.tupleHead(rest).length == 2);
        std.debug.assert(harness.integerIs(rest[0], 3));
        std.debug.assert(harness.integerIs(rest[1], 4));
    }

    // Destructuring a struct by key.
    std.debug.assert(core_env.dostring(
        environment,
        "(do (def {:x binding-x} {:x 9}) binding-x)",
        "specials-core-test",
        &output,
    ) == 0);
    std.debug.assert(harness.integerIs(output, 9));

    // A docstring between the name and the value, which `def` moves into the
    // binding's table rather than treating as the value.
    std.debug.assert(core_env.dostring(
        environment,
        "(def binding-with-doc \"binding documentation\" 10)",
        "specials-core-test",
        &output,
    ) == 0);
    {
        const binding = tables.get(environment, value.fromBytes("binding-with-doc", .symbol));
        const doc = tables.get(wrap.toTable(binding), value.fromBytes("doc", .keyword));
        std.debug.assert(harness.stringValueIs(doc, "binding documentation"));
    }

    // The five parameter forms: destructured, optional, rest, named, and a
    // self-referential name for recursion.
    std.debug.assert(core_env.dostring(
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
    std.debug.assert(harness.isType(output, constants.JANET_TUPLE));
    {
        const results = wrap.toTuple(output);
        std.debug.assert(types.tupleHead(results).length == 5);
        std.debug.assert(harness.integerIs(results[0], 5));

        const optional = wrap.toTuple(results[1]);
        std.debug.assert(harness.integerIs(optional[0], 1));
        std.debug.assert(harness.isType(optional[1], constants.JANET_NIL));

        const rest = wrap.toTuple(results[2]);
        std.debug.assert(types.tupleHead(rest).length == 2);
        std.debug.assert(harness.integerIs(rest[0], 2));
        std.debug.assert(harness.integerIs(rest[1], 3));

        const named = wrap.toTuple(results[3]);
        std.debug.assert(harness.integerIs(named[0], 1));
        std.debug.assert(harness.integerIs(named[1], 2));

        std.debug.assert(harness.integerIs(results[4], 3));
    }
}

fn body() !void {
    anUnknownNameIsNotASpecial();

    compiler = std.mem.zeroes(types.JanetCompiler);
    compiler.recursion_guard = config.recursion_guard;
    var arguments = [3]types.Janet{
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

    vector.free(compiler.buffer);
    theWholeCompilations();
}

pub fn run() void {
    harness.init();
    body() catch @panic("specials_core: a kernel raised unexpectedly");
    vm_lifecycle.deinit();
}
