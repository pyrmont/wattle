//! Behavioral contract for the callee side of the interpreter: method
//! invocation, the operator fallbacks, method resolution, the non-function
//! call path, and the three collection fill loops.
//!
//! Eleven functions, and they are one contract because they are one decision
//! made in stages. `run_vm` hands a callee to `callNonfn` or a name to
//! `resolveMethod`; both end in `methodInvoke`, which decides what calling that
//! value even means. Testing any of them alone would pin a stage without
//! pinning the handover.
//!
//! Four properties get more attention than their size suggests.
//!
//! **The whole battery runs inside a real fiber.** `methodInvoke` reaches
//! `callImpl` for a function callee, which requires a current fiber and a frame
//! to push onto. Rather than installing one by hand, `run` registers a
//! cfunction and calls it from Janet source, so every assertion below runs
//! where `run_vm` would have made the same call.
//!
//! **The seven refusal messages.** Each is built by `janet_panicf` with a
//! `Janet` in a `%v`, a `const char *` in a `%s` and an `int32_t` in a `%d`,
//! and a mismatch there produces a plausible wrong message rather than a
//! crash, so every message is compared byte for byte. The values chosen for
//! those messages are numbers, keywords and strings, because `%v` renders a
//! table or a tuple with its address and an address cannot be compared.
//!
//! **Argument order is asserted, not assumed.** `binopCall`'s right-hand
//! fallback swaps its operands — a `:r+` method receives its own receiver
//! first — and `methodInvoke`'s default arm reverses the lookup, indexing the
//! argument by the callee rather than the other way round. Both are invisible
//! to a test that only checks that something came back.
//!
//! ## What the migration changed
//!
//! **The panic counter is gone**, for the reason `vm_lifecycle` gives: it
//! existed because an `EXPECT_PANIC` macro that silently stopped firing looked
//! like a pass, and `harness.raised` answers null instead.
//!
//! **`CONTRACT_AT` is gone and nothing replaced it.** The C contract needed
//! `janet_contract_abstract_type` for all three of its abstract types, because
//! a `JanetAbstractType`'s `call`, `get` and `tostring` callbacks are
//! Zig-ABI-and-raising since Phase 10 Part 17g and C cannot define one. A Zig
//! contract writes the callback, which is Part 10's lesson 27 arriving again:
//! the shims that made this group look expensive are exactly the part that
//! costs nothing.
//!
//! **The last raise-through-a-fill-loop case stays as one and is a raise.**
//! `loudTostring` panics from inside `fillString`, which under the C driver
//! was a `longjmp` crossing a Zig frame and is now `error.JanetSignal`
//! returning through it. The half that drove `fillTable` through a raising
//! `hash` went at the hinge and is not reinstated: `hash` is typed non-raising
//! because comparisons must be total, so the callback has no way out.

const std = @import("std");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
const value = @import("subsystems").value;
const structs = @import("subsystems").value.structs;
const tables = @import("subsystems").value.tables;
const gc_alloc = @import("subsystems").gc_alloc;
const tuples = @import("subsystems").value.tuples;
const core_env = @import("subsystems").env;
const wrap = @import("subsystems").value.wrap;
const args_core_mod = @import("subsystems").args;
const vm_lifecycle = @import("subsystems").lifecycle;
const buffers = @import("subsystems").value.buffers;
const abstracts = @import("subsystems").value.abstracts;
const fibers = @import("subsystems").value.fibers;
const registry = @import("subsystems").registry;
const vm_calls = subsystems.vm;
const args_core = subsystems.args;
const abstract_type = subsystems.abstract_type;
const AbstractType = abstract_type.AbstractType;

const assert = std.debug.assert;

// ------------------------------------------------------------------ helpers

var test_env: ?*types.JanetTable = null;

fn kw(name: [*:0]const u8) types.Janet {
    return value.fromBytes(std.mem.span(name), .keyword);
}

fn intv(i: i32) types.Janet {
    return harness.wrapInteger(i);
}

fn isNil(x: types.Janet) bool {
    return harness.isType(x, constants.JANET_NIL);
}

/// The refusal a call made. Named rather than spelled at each site so that the
/// `.?` — "it must have refused" — is in one place.
fn refusal(function: anytype, args: anytype) harness.Raise {
    return harness.raised(function, args).?;
}

/// Roots whatever it produces and never unroots it. The values these tests
/// hold live across calls that intern keywords and compile source, either of
/// which can collect, and a Janet value in a Zig local is not a root. The
/// process is short enough that never releasing them costs nothing.
fn eval(source: [*:0]const u8) types.Janet {
    var out = wrap.fromNil();
    assert(core_env.dostring(test_env.?, source, "vm-calls-test", &out) == 0);
    gc_alloc.gcroot(out);
    return out;
}

/// A fiber with a run of arguments pushed onto it, in the state `run_vm`
/// leaves before `JOP_CALL`: `stackstart` marks where the arguments begin and
/// `stacktop` where they end.
fn fiberWithArgs(argv: []const types.Janet) raise.Raising(*types.JanetFiber) {
    const fiber = fibers.new(wrap.toFunction(eval("(fn [] nil)")), 32, 0, null).?;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    fiber.*.stackstart = fiber.*.stacktop;
    for (argv) |arg| try fibers.push(fiber, arg);
    return fiber;
}

// ------------------------------------------------------- cfunction fixtures

fn cfunSum(argv: []types.Janet) raise.Raising(types.Janet) {
    var total: f64 = 0;
    var i: i32 = 0;
    while (i < @as(i32, @intCast(argv.len))) : (i += 1) total += try args_core.getNumber(argv, i);
    return wrap.fromNumber(total);
}

/// Returns its arguments as a tuple, so a caller can assert their order.
fn cfunArgs(argv: []types.Janet) raise.Raising(types.Janet) {
    return wrap.fromTuple(tuples.newFrom(argv.ptr, @as(i32, @intCast(argv.len))));
}

const cfuns = [_]types.JanetReg{
    .{ .name = "vmcalls/sum", .cfun = raise.stored(&cfunSum), .documentation = null },
    .{ .name = "vmcalls/args", .cfun = raise.stored(&cfunArgs), .documentation = null },
    .{ .name = "vmcalls/contract", .cfun = raise.stored(&cfunContract), .documentation = null },
    .{ .name = null, .cfun = null, .documentation = null },
};

// -------------------------------------------------------- abstract fixtures

/// Callable: its `call` callback answers with its own argument count, so a
/// test can tell it apart from the indexed fallback.
fn callableCall(p: ?*anyopaque, argc: i32, argv: [*]types.Janet) raise.Error!types.Janet {
    _ = p;
    _ = argv;

    return harness.wrapInteger(argc);
}

const at_callable: AbstractType = .{ .name = "vm-calls/callable", .call = &callableCall };

/// Indexable: no `call`, so `methodInvoke` falls out of the abstract arm into
/// the arity check and `janet_in`.
fn indexableGet(p: ?*anyopaque, key: types.Janet, out: *types.Janet) raise.Error!c_int {
    _ = p;
    if (args_core_mod.checkint(key) == 0) return 0;
    out.* = harness.wrapInteger(wrap.toInteger(key) * 10);
    return 1;
}

const at_indexable: AbstractType = .{ .name = "vm-calls/indexable", .get = &indexableGet };

/// Raises from `tostring`, which `fillString` reaches through
/// `janet_to_string_b`.
fn loudTostring(p: ?*anyopaque, buffer: *types.JanetBuffer) raise.Error!void {
    _ = p;
    _ = buffer;
    return raise.panic("tostring raised");
}

const at_loud_string: AbstractType = .{ .name = "vm-calls/loud-string", .tostring = &loudTostring };

var callable_value: types.Janet = undefined;
var indexable_value: types.Janet = undefined;
var loud_string_value: types.Janet = undefined;

fn makeAbstracts() void {
    callable_value = wrap.fromAbstract(abstracts.new(abstract_type.stored(&at_callable), 1));
    indexable_value = wrap.fromAbstract(abstracts.new(abstract_type.stored(&at_indexable), 1));
    loud_string_value = wrap.fromAbstract(abstracts.new(abstract_type.stored(&at_loud_string), 1));
    gc_alloc.gcroot(callable_value);
    gc_alloc.gcroot(indexable_value);
    gc_alloc.gcroot(loud_string_value);
}

// ------------------------------------------------------------ methodInvoke

fn invokeACfunction() raise.Raising(void) {
    var argv = [_]types.Janet{ intv(1), intv(2), intv(4) };
    const callee = eval("vmcalls/sum");
    assert(harness.isType(callee, constants.JANET_CFUNCTION));
    assert(wrap.toNumber(try vm_calls.methodInvoke(callee, argv[0..3])) == 7);
    // Arity is the callee's business, not this layer's: zero arguments reach
    // the cfunction rather than the arity check below.
    assert(wrap.toNumber(try vm_calls.methodInvoke(callee, &.{})) == 0);
}

fn invokeAFunction() raise.Raising(void) {
    var argv = [_]types.Janet{ intv(3), intv(4) };
    const callee = eval("(fn [a b] (* a b))");
    assert(harness.isType(callee, constants.JANET_FUNCTION));
    assert(wrap.toNumber(try vm_calls.methodInvoke(callee, argv[0..2])) == 12);
}

fn invokeAnAbstractWithACallCallback() raise.Raising(void) {
    var argv = [_]types.Janet{ intv(1), intv(1), intv(1) };
    // The callback answers with argc, so this also shows that the arity check
    // below is not reached: three arguments would have failed it.
    assert(wrap.toNumber(try vm_calls.methodInvoke(callable_value, argv[0..3])) == 3);
    assert(wrap.toNumber(try vm_calls.methodInvoke(callable_value, &.{})) == 0);
    // One argument is the case that tells the two paths apart by value rather
    // than by arity: the indexed fallback would answer with `janet_in` on an
    // abstract that has no `get`, and the callback answers 1.
    assert(wrap.toNumber(try vm_calls.methodInvoke(callable_value, argv[0..1])) == 1);
}

fn anAbstractWithoutCallFallsThroughToIndexing() raise.Raising(void) {
    var argv = [_]types.Janet{ intv(4), intv(5) };
    assert(wrap.toNumber(try vm_calls.methodInvoke(indexable_value, argv[0..1])) == 40);
    // Having fallen through, it is subject to the arity check the six indexed
    // types share. The message renders an abstract with its address, so this
    // is the one arity refusal not compared whole — `beginsWith` is the
    // C contract's second `EXPECT_PANIC_PREFIX` macro.
    const r = refusal(vm_calls.methodInvoke, .{ indexable_value, argv[0..2] });
    assert(r.beginsWith("<vm-calls/indexable "));
    assert(harness.isType(r.payload, constants.JANET_STRING));
    const message = wrap.toString(r.payload);
    const length: usize = @intCast(types.stringHead(message).length);
    assert(std.mem.endsWith(u8, message[0..length], " called with 2 arguments, possibly expected 1"));
}

fn invokeEachIndexedType() raise.Raising(void) {
    var key = [_]types.Janet{kw("a")};
    assert(wrap.toNumber(try vm_calls.methodInvoke(eval("@{:a 1}"), key[0..1])) == 1);
    assert(wrap.toNumber(try vm_calls.methodInvoke(eval("{:a 2}"), key[0..1])) == 2);
    key[0] = intv(1);
    assert(wrap.toNumber(try vm_calls.methodInvoke(eval("@[7 8]"), key[0..1])) == 8);
    assert(wrap.toNumber(try vm_calls.methodInvoke(eval("[9 10]"), key[0..1])) == 10);
    assert(wrap.toNumber(try vm_calls.methodInvoke(eval("\"ab\""), key[0..1])) == 'b');
    assert(wrap.toNumber(try vm_calls.methodInvoke(eval("@\"cd\""), key[0..1])) == 'd');
}

fn theIndexedArityCheck() void {
    var argv = [_]types.Janet{ intv(0), intv(0) };
    assert(refusal(vm_calls.methodInvoke, .{ eval("\"ab\""), argv[0..2] })
        .says("\"ab\" called with 2 arguments, possibly expected 1"));
    assert(refusal(vm_calls.methodInvoke, .{ eval("\"ab\""), &.{} })
        .says("\"ab\" called with 0 arguments, possibly expected 1"));
}

fn theDefaultArmReversesTheLookup() raise.Raising(void) {
    var argv = [_]types.Janet{eval("{:a 11}")};
    // A keyword callee indexes its argument, not the other way round: this is
    // what makes `(:a struct)` work.
    assert(wrap.toNumber(try vm_calls.methodInvoke(kw("a"), argv[0..1])) == 11);
    // Any other unlisted type takes the same arm. A number is not a key of
    // that struct, so the answer is nil rather than a refusal.
    assert(isNil(try vm_calls.methodInvoke(intv(5), argv[0..1])));
    var three = [_]types.Janet{ argv[0], argv[0], argv[0] };
    assert(refusal(vm_calls.methodInvoke, .{ kw("a"), &three })
        .says(":a called with 3 arguments, possibly expected 1"));
}

// ------------------------------------------------------------ methodLookup

/// Raising since Phase 11 Part 15, which is rule 33's corollary arriving from
/// the runtime side: `methodLookup` reached `janet_get` through the abi,
/// and every one of its four callers is `raise.Raising`, so an abstract's
/// `get` refusing became a report nobody consumed. The three cases here answer
/// rather than raise, so each is a `try`; the refusal that motivated the change
/// is asserted below.
fn methodLookup() raise.Raising(void) {
    const found = try vm_calls.methodLookup(eval("@{:m vmcalls/sum}"), "m");
    assert(harness.isType(found, constants.JANET_CFUNCTION));
    assert(isNil(try vm_calls.methodLookup(eval("@{:m 1}"), "other")));
    // A value with no keys at all answers nil rather than raising, which is
    // what lets the operator fallbacks try the other operand.
    assert(isNil(try vm_calls.methodLookup(intv(5), "m")));
}

// -------------------------------------------------------------------- mcall

fn mcall() raise.Raising(void) {
    var argv = [_]types.Janet{ eval("@{:sum (fn [self a b] (+ a b))}"), intv(2), intv(3) };
    // The receiver is passed to the method as its first argument, which is why
    // the method takes three parameters for a two-argument call.
    assert(wrap.toNumber(try vm_calls.mcall("sum", argv[0..3])) == 5);
    argv[0] = intv(7);
    assert(refusal(vm_calls.mcall, .{ "nope", argv[0..1] })
        .says("could not find method :nope for 7"));
    assert(refusal(vm_calls.mcall, .{ "len", &.{} })
        .says("method :len expected at least 1 argument"));
}

// --------------------------------------------------------- operator methods

fn unaryCall() raise.Raising(void) {
    const receiver = eval("@{:- (fn [self] 42)}");
    assert(wrap.toNumber(try vm_calls.unaryCall("-", receiver)) == 42);
    assert(refusal(vm_calls.unaryCall, .{ "-", intv(5) }).says("could not find method :- for 5"));
}

fn binopCallPrefersTheLeftOperand() raise.Raising(void) {
    const lhs = eval("@{:+ vmcalls/args}");
    const result = try vm_calls.binopCall("+", "r+", lhs, intv(9));
    const tup = wrap.toTuple(result);
    assert(types.tupleHead(tup).length == 2);
    assert(harness.equals(tup[0], lhs));
    assert(wrap.toNumber(tup[1]) == 9);
}

fn binopCallSwapsForTheRightOperand() raise.Raising(void) {
    const rhs = eval("@{:r+ vmcalls/args}");
    const result = try vm_calls.binopCall("+", "r+", intv(9), rhs);
    const tup = wrap.toTuple(result);
    // The right-hand method receives itself first. Asserted rather than
    // assumed: a port that passed them in source order would still return a
    // plausible answer for a commutative operator.
    assert(types.tupleHead(tup).length == 2);
    assert(harness.equals(tup[0], rhs));
    assert(wrap.toNumber(tup[1]) == 9);
}

fn binopCallWithNeitherMethod() void {
    assert(refusal(vm_calls.binopCall, .{ "+", "r+", intv(1), intv(2) })
        .says("could not find method :+ for 1 or :r+ for 2"));
}

// ----------------------------------------------------------- resolveMethod

fn resolveMethod() raise.Raising(void) {
    var args = [_]types.Janet{ eval("@{:m vmcalls/sum}"), intv(1) };
    var fiber = try fiberWithArgs(&args);
    const callee = try vm_calls.resolveMethod(kw("m"), fiber);
    assert(harness.isType(callee, constants.JANET_CFUNCTION));
    // Resolution reads the receiver and leaves the stack alone: the arguments
    // are still pushed when it returns, because `JOP_CALL` consumes them next.
    assert(fiber.stacktop - fiber.stackstart == 2);
    _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));

    args[0] = eval("\"abc\"");
    fiber = try fiberWithArgs(args[0..1]);
    assert(refusal(vm_calls.resolveMethod, .{ kw("m"), @as(*types.JanetFiber, fiber) })
        .says("unknown method :m invoked on \"abc\""));
    _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));

    // Unreachable from Janet source — the compiler rejects a zero-argument
    // method call — so only an assembled function or this contract gets here.
    fiber = try fiberWithArgs(&.{});
    assert(refusal(vm_calls.resolveMethod, .{ kw("m"), @as(*types.JanetFiber, fiber) })
        .says("method call (:m) takes at least 1 argument, got 0"));
    _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));
}

// --------------------------------------------------------------- callNonfn

fn callNonfn() raise.Raising(void) {
    // A table callee with one argument is an indexed lookup.
    var args = [_]types.Janet{ kw("a"), intv(6) };
    var fiber = try fiberWithArgs(args[0..1]);
    assert(wrap.toNumber(try vm_calls.callNonfn(fiber, eval("@{:a 3}"))) == 3);
    // The arguments are consumed: `stacktop` is back at `stackstart`, which is
    // what lets the callee push a frame of its own over them.
    assert(fiber.stacktop == fiber.stackstart);
    _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));

    // A cfunction callee gets the pushed arguments in order.
    args[0] = intv(5);
    fiber = try fiberWithArgs(&args);
    assert(wrap.toNumber(try vm_calls.callNonfn(fiber, eval("vmcalls/sum"))) == 11);
    _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));

    // Zero pushed arguments reach the arity check rather than reading a stack
    // slot that holds nothing.
    fiber = try fiberWithArgs(&.{});
    assert(refusal(vm_calls.callNonfn, .{ @as(*types.JanetFiber, fiber), kw("a") })
        .says(":a called with 0 arguments, possibly expected 1"));
    _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));
}

// --------------------------------------------------------------- fill loops

fn fillTable() void {
    const table = tables.new(4);
    const mem = [_]types.Janet{ kw("a"), intv(1), kw("b"), intv(2) };
    gc_alloc.gcroot(wrap.fromTable(table));
    vm_calls.fillTable(table, &mem, 4);
    assert(table.*.count == 2);
    assert(harness.integerIs(tables.get(table, kw("a")), 1));
    assert(harness.integerIs(tables.get(table, kw("b")), 2));
    // A zero count writes nothing and reads nothing.
    vm_calls.fillTable(table, null, 0);
    assert(table.*.count == 2);
    _ = gc_alloc.gcunroot(wrap.fromTable(table));
}

fn fillStruct() void {
    const st = structs.begin(2);
    const mem = [_]types.Janet{ kw("a"), intv(1), kw("b"), intv(2) };
    vm_calls.fillStruct(st, &mem, 4);
    const done = structs.end(st);
    assert(types.structHead(done).length == 2);
    assert(harness.integerIs(harness.field(done, "a"), 1));
    assert(harness.integerIs(harness.field(done, "b"), 2));
}

fn fillString() raise.Raising(void) {
    const buffer = buffers.new(8);
    const mem = [_]types.Janet{ intv(1), kw("ab"), eval("\"cd\"") };
    gc_alloc.gcroot(wrap.fromBuffer(buffer));
    try vm_calls.fillString(buffer, &mem, 3);
    // Each element is rendered as `string` would render it: a keyword loses
    // its colon and a string loses its quotes.
    assert(buffer.*.count == 5);
    assert(std.mem.eql(u8, buffer.*.data.?[0..5], "1abcd"));
    try vm_calls.fillString(buffer, null, 0);
    assert(buffer.*.count == 5);
    _ = gc_alloc.gcunroot(wrap.fromBuffer(buffer));
}

/// A raise from inside the fill loop, which is the one thing about these three
/// that a Janet-level test cannot reach: the callback that raises belongs to
/// an abstract type no in-tree module defines.
///
/// There were two halves here until the hinge, and the second is gone rather
/// than fixed. It drove `fillTable` through an abstract whose `hash` called
/// `janet_panic`, and it worked because `janet_panic` was a `longjmp`: the jump
/// left `janet_table_put` from inside a callback whose signature had no way to
/// say it had failed. The hinge typed `hash` non-raising — see
/// `src/zig/subsystems/abstract_type.zig` — because `hash` is reached from
/// comparisons that must be total, so a raise there has no caller that could
/// act on it. With the jump gone the callback has no way out, so the case is
/// not a behaviour this runtime has any more. `tostring` is raising and is what
/// this keeps.
fn aRaiseFromInsideAFillLoop() void {
    const buffer = buffers.new(8);
    const mem = [_]types.Janet{ intv(1), loud_string_value };

    gc_alloc.gcroot(wrap.fromBuffer(buffer));
    assert(refusal(vm_calls.fillString, .{ buffer, @as([*]const types.Janet, &mem), 2 })
        .says("tostring raised"));
    // The element before the raising one was already written, and the buffer
    // survives the raise.
    assert(buffer.*.count == 1);
    assert(buffer.*.data.?[0] == '1');
    _ = gc_alloc.gcunroot(wrap.fromBuffer(buffer));
}

// ------------------------------------------------------------------- entry

fn cfunContract(argv: []types.Janet) raise.Raising(types.Janet) {
    try args_core.fixarity(argv, 0);

    try invokeACfunction();
    try invokeAFunction();
    try invokeAnAbstractWithACallCallback();
    try anAbstractWithoutCallFallsThroughToIndexing();
    try invokeEachIndexedType();
    theIndexedArityCheck();
    try theDefaultArmReversesTheLookup();

    try methodLookup();
    try mcall();

    try unaryCall();
    try binopCallPrefersTheLeftOperand();
    try binopCallSwapsForTheRightOperand();
    binopCallWithNeitherMethod();

    try resolveMethod();
    try callNonfn();

    fillTable();
    fillStruct();
    try fillString();
    aRaiseFromInsideAFillLoop();

    return wrap.fromNil();
}

pub fn run() void {
    harness.init();
    test_env = harness.coreEnv();
    registry.cfuns(test_env, null, &cfuns);
    makeAbstracts();

    // From Janet source, so that everything above runs with a live fiber under
    // it: `methodInvoke` reaches `callImpl`, which has no meaning without one.
    _ = eval("(vmcalls/contract)");

    vm_lifecycle.deinit();
    std.debug.print("vm calls contract ok\n", .{});
}
