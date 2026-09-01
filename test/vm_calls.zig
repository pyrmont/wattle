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
//! ## What only a contract inside the compilation can do
//!
//! **There is no panic counter**, for the reason `vm_lifecycle` gives: it
//! exists because an `EXPECT_PANIC` macro that silently stops firing looks
//! like a pass, and `harness.raised` answers null instead.
//!
//! **There is no adapter pool.** A `JanetAbstractType`'s `call`, `get` and
//! `tostring` callbacks are Zig's and raising, so C can define none of them
//! and a C contract needs a pool of pre-built tables for all three of this
//! file's abstract types. A Zig contract writes the callback.
//!
//! **The last raise-through-a-fill-loop case stays as one and is a raise.**
//! `loudTostring` raises from inside `fillString`, and the raise returns
//! through the frame rather than jumping past it. The half that drove
//! `fillTable` through a raising `hash` is not reinstated: `hash` is typed
//! non-raising
//! because comparisons must be total, so the callback has no way out.

const std = @import("std");
const abi = @import("abi");
const repr = @import("repr");
const raise = @import("subsystems").raise;
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
const strings = @import("subsystems").value.strings;
const vm_calls = subsystems.vm;
const args_core = subsystems.args;
const abstract_type = subsystems.abstract_type;

const expect = @import("expect.zig").expect;

// ------------------------------------------------------------------ helpers

var test_env: ?*tables.Table = null;

fn kw(name: [*:0]const u8) repr.Value {
    return value.fromBytes(std.mem.span(name), .keyword);
}

fn intv(i: i32) repr.Value {
    return harness.wrapInteger(i);
}

fn isNil(x: repr.Value) bool {
    return harness.isType(x, repr.Tag.nil);
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
fn eval(source: [*:0]const u8) repr.Value {
    var out = wrap.fromNil();
    expect(core_env.dostring(test_env.?, source, "vm-calls-test", &out) == 0);
    gc_alloc.gcroot(out);
    return out;
}

/// A fiber with a run of arguments pushed onto it, in the state `run_vm`
/// leaves before `JOP_CALL`: `stackstart` marks where the arguments begin and
/// `stacktop` where they end.
fn fiberWithArgs(argv: []const repr.Value) raise.Raising(*fibers.Fiber) {
    const fiber = fibers.new(wrap.toFunction(eval("(fn [] nil)")), 32, &.{}) catch unreachable;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    fiber.stackstart = fiber.stacktop;
    for (argv) |arg| try fibers.push(fiber, arg);
    return fiber;
}

// ------------------------------------------------------- cfunction fixtures

fn cfunSum(argv: []repr.Value) raise.Raising(repr.Value) {
    var total: f64 = 0;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) total += try args_core.getNumber(argv, i);
    return wrap.fromNumber(total);
}

/// Returns its arguments as a tuple, so a caller can assert their order.
fn cfunArgs(argv: []repr.Value) raise.Raising(repr.Value) {
    return wrap.fromTuple(tuples.newFrom(argv));
}

const cfuns = [_]abi.Reg{
    .{ .name = "vmcalls/sum", .cfun = raise.stored(&cfunSum), .documentation = null },
    .{ .name = "vmcalls/args", .cfun = raise.stored(&cfunArgs), .documentation = null },
    .{ .name = "vmcalls/contract", .cfun = raise.stored(&cfunContract), .documentation = null },
};

// -------------------------------------------------------- abstract fixtures

/// Callable: its `call` callback answers with its own argument count, so a
/// test can tell it apart from the indexed fallback.
fn callableCall(_: *anyopaque, argv: []repr.Value) raise.Error!repr.Value {
    return harness.wrapInteger(@intCast(argv.len));
}

const at_callable = abstract_type.define(anyopaque, .{ .name = "vm-calls/callable", .call = &callableCall });

/// Indexable: no `call`, so `methodInvoke` falls out of the abstract arm into
/// the arity check and `janet_in`.
fn indexableGet(_: *anyopaque, key: repr.Value) raise.Error!?repr.Value {
    if (!args_core_mod.checkint(key)) return null;
    return harness.wrapInteger(wrap.toInteger(key) * 10);
}

const at_indexable = abstract_type.define(anyopaque, .{ .name = "vm-calls/indexable", .get = &indexableGet });

/// Raises from `tostring`, which `fillString` reaches through
/// `janet_to_string_b`.
fn loudTostring(_: *anyopaque, _: *abi.Buffer) raise.Error!void {
    return raise.panic("tostring raised");
}

const at_loud_string = abstract_type.define(anyopaque, .{ .name = "vm-calls/loud-string", .tostring = &loudTostring });

var callable_value: repr.Value = undefined;
var indexable_value: repr.Value = undefined;
var loud_string_value: repr.Value = undefined;

fn makeAbstracts() void {
    callable_value = wrap.fromAbstract(abstracts.newBytes(&at_callable, 1));
    indexable_value = wrap.fromAbstract(abstracts.newBytes(&at_indexable, 1));
    loud_string_value = wrap.fromAbstract(abstracts.newBytes(&at_loud_string, 1));
    gc_alloc.gcroot(callable_value);
    gc_alloc.gcroot(indexable_value);
    gc_alloc.gcroot(loud_string_value);
}

// ------------------------------------------------------------ methodInvoke

fn invokeACfunction() raise.Raising(void) {
    var argv = [_]repr.Value{ intv(1), intv(2), intv(4) };
    const callee = eval("vmcalls/sum");
    expect(harness.isType(callee, repr.Tag.cfunction));
    expect(wrap.toNumber(try vm_calls.methodInvoke(callee, argv[0..3])) == 7);
    // Arity is the callee's business, not this layer's: zero arguments reach
    // the cfunction rather than the arity check below.
    expect(wrap.toNumber(try vm_calls.methodInvoke(callee, &.{})) == 0);
}

fn invokeAFunction() raise.Raising(void) {
    var argv = [_]repr.Value{ intv(3), intv(4) };
    const callee = eval("(fn [a b] (* a b))");
    expect(harness.isType(callee, repr.Tag.function));
    expect(wrap.toNumber(try vm_calls.methodInvoke(callee, argv[0..2])) == 12);
}

fn invokeAnAbstractWithACallCallback() raise.Raising(void) {
    var argv = [_]repr.Value{ intv(1), intv(1), intv(1) };
    // The callback answers with argc, so this also shows that the arity check
    // below is not reached: three arguments would have failed it.
    expect(wrap.toNumber(try vm_calls.methodInvoke(callable_value, argv[0..3])) == 3);
    expect(wrap.toNumber(try vm_calls.methodInvoke(callable_value, &.{})) == 0);
    // One argument is the case that tells the two paths apart by value rather
    // than by arity: the indexed fallback would answer with `janet_in` on an
    // abstract that has no `get`, and the callback answers 1.
    expect(wrap.toNumber(try vm_calls.methodInvoke(callable_value, argv[0..1])) == 1);
}

fn anAbstractWithoutCallFallsThroughToIndexing() raise.Raising(void) {
    var argv = [_]repr.Value{ intv(4), intv(5) };
    expect(wrap.toNumber(try vm_calls.methodInvoke(indexable_value, argv[0..1])) == 40);
    // Having fallen through, it is subject to the arity check the six indexed
    // types share. The message renders an abstract with its address, so this
    // is the one arity refusal not compared whole — `beginsWith` is the
    // C contract's second `EXPECT_PANIC_PREFIX` macro.
    const r = refusal(vm_calls.methodInvoke, .{ indexable_value, argv[0..2] });
    expect(r.beginsWith("<vm-calls/indexable "));
    expect(harness.isType(r.payload, repr.Tag.string));
    const message = wrap.toString(r.payload);
    const length: usize = strings.head(message).length;
    expect(std.mem.endsWith(u8, message[0..length], " called with 2 arguments, possibly expected 1"));
}

fn invokeEachIndexedType() raise.Raising(void) {
    var key = [_]repr.Value{kw("a")};
    expect(wrap.toNumber(try vm_calls.methodInvoke(eval("@{:a 1}"), key[0..1])) == 1);
    expect(wrap.toNumber(try vm_calls.methodInvoke(eval("{:a 2}"), key[0..1])) == 2);
    key[0] = intv(1);
    expect(wrap.toNumber(try vm_calls.methodInvoke(eval("@[7 8]"), key[0..1])) == 8);
    expect(wrap.toNumber(try vm_calls.methodInvoke(eval("[9 10]"), key[0..1])) == 10);
    expect(wrap.toNumber(try vm_calls.methodInvoke(eval("\"ab\""), key[0..1])) == 'b');
    expect(wrap.toNumber(try vm_calls.methodInvoke(eval("@\"cd\""), key[0..1])) == 'd');
}

fn theIndexedArityCheck() void {
    var argv = [_]repr.Value{ intv(0), intv(0) };
    expect(refusal(vm_calls.methodInvoke, .{ eval("\"ab\""), argv[0..2] })
        .says("\"ab\" called with 2 arguments, possibly expected 1"));
    expect(refusal(vm_calls.methodInvoke, .{ eval("\"ab\""), &.{} })
        .says("\"ab\" called with 0 arguments, possibly expected 1"));
}

fn theDefaultArmReversesTheLookup() raise.Raising(void) {
    var argv = [_]repr.Value{eval("{:a 11}")};
    // A keyword callee indexes its argument, not the other way round: this is
    // what makes `(:a struct)` work.
    expect(wrap.toNumber(try vm_calls.methodInvoke(kw("a"), argv[0..1])) == 11);
    // Any other unlisted type takes the same arm. A number is not a key of
    // that struct, so the answer is nil rather than a refusal.
    expect(isNil(try vm_calls.methodInvoke(intv(5), argv[0..1])));
    var three = [_]repr.Value{ argv[0], argv[0], argv[0] };
    expect(refusal(vm_calls.methodInvoke, .{ kw("a"), &three })
        .says(":a called with 3 arguments, possibly expected 1"));
}

// ------------------------------------------------------------ methodLookup

/// Raising, and it must be: `methodLookup` reaching `janet_get` through the
/// abi makes an abstract's `get` refusing into a report nobody consumes, and
/// every one of its four callers is `raise.Raising`. The three cases here
/// answer rather than raise, so each is a `try`; the refusal that motivated
/// the change is asserted below.
fn methodLookup() raise.Raising(void) {
    const found = try vm_calls.methodLookup(eval("@{:m vmcalls/sum}"), "m");
    expect(harness.isType(found, repr.Tag.cfunction));
    expect(isNil(try vm_calls.methodLookup(eval("@{:m 1}"), "other")));
    // A value with no keys at all answers nil rather than raising, which is
    // what lets the operator fallbacks try the other operand.
    expect(isNil(try vm_calls.methodLookup(intv(5), "m")));
}

// -------------------------------------------------------------------- mcall

fn mcall() raise.Raising(void) {
    var argv = [_]repr.Value{ eval("@{:sum (fn [self a b] (+ a b))}"), intv(2), intv(3) };
    // The receiver is passed to the method as its first argument, which is why
    // the method takes three parameters for a two-argument call.
    expect(wrap.toNumber(try vm_calls.mcall("sum", argv[0..3])) == 5);
    argv[0] = intv(7);
    expect(refusal(vm_calls.mcall, .{ "nope", argv[0..1] })
        .says("could not find method :nope for 7"));
    expect(refusal(vm_calls.mcall, .{ "len", &.{} })
        .says("method :len expected at least 1 argument"));
}

// --------------------------------------------------------- operator methods

fn unaryCall() raise.Raising(void) {
    const receiver = eval("@{:- (fn [self] 42)}");
    expect(wrap.toNumber(try vm_calls.unaryCall("-", receiver)) == 42);
    expect(refusal(vm_calls.unaryCall, .{ "-", intv(5) }).says("could not find method :- for 5"));
}

fn binopCallPrefersTheLeftOperand() raise.Raising(void) {
    const lhs = eval("@{:+ vmcalls/args}");
    const result = try vm_calls.binopCall("+", "r+", lhs, intv(9));
    const tup = wrap.toTuple(result);
    expect(tuples.head(tup).length == 2);
    expect(harness.equals(tup[0], lhs));
    expect(wrap.toNumber(tup[1]) == 9);
}

fn binopCallSwapsForTheRightOperand() raise.Raising(void) {
    const rhs = eval("@{:r+ vmcalls/args}");
    const result = try vm_calls.binopCall("+", "r+", intv(9), rhs);
    const tup = wrap.toTuple(result);
    // The right-hand method receives itself first. Asserted rather than
    // assumed: a port that passed them in source order would still return a
    // plausible answer for a commutative operator.
    expect(tuples.head(tup).length == 2);
    expect(harness.equals(tup[0], rhs));
    expect(wrap.toNumber(tup[1]) == 9);
}

fn binopCallWithNeitherMethod() void {
    expect(refusal(vm_calls.binopCall, .{ "+", "r+", intv(1), intv(2) })
        .says("could not find method :+ for 1 or :r+ for 2"));
}

// ----------------------------------------------------------- resolveMethod

fn resolveMethod() raise.Raising(void) {
    var args = [_]repr.Value{ eval("@{:m vmcalls/sum}"), intv(1) };
    var fiber = try fiberWithArgs(&args);
    const callee = try vm_calls.resolveMethod(kw("m"), fiber);
    expect(harness.isType(callee, repr.Tag.cfunction));
    // Resolution reads the receiver and leaves the stack alone: the arguments
    // are still pushed when it returns, because `JOP_CALL` consumes them next.
    expect(fiber.stacktop - fiber.stackstart == 2);
    _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));

    args[0] = eval("\"abc\"");
    fiber = try fiberWithArgs(args[0..1]);
    expect(refusal(vm_calls.resolveMethod, .{ kw("m"), @as(*fibers.Fiber, fiber) })
        .says("unknown method :m invoked on \"abc\""));
    _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));

    // Unreachable from Janet source — the compiler rejects a zero-argument
    // method call — so only an assembled function or this contract gets here.
    fiber = try fiberWithArgs(&.{});
    expect(refusal(vm_calls.resolveMethod, .{ kw("m"), @as(*fibers.Fiber, fiber) })
        .says("method call (:m) takes at least 1 argument, got 0"));
    _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));
}

// --------------------------------------------------------------- callNonfn

fn callNonfn() raise.Raising(void) {
    // A table callee with one argument is an indexed lookup.
    var args = [_]repr.Value{ kw("a"), intv(6) };
    var fiber = try fiberWithArgs(args[0..1]);
    expect(wrap.toNumber(try vm_calls.callNonfn(fiber, eval("@{:a 3}"))) == 3);
    // The arguments are consumed: `stacktop` is back at `stackstart`, which is
    // what lets the callee push a frame of its own over them.
    expect(fiber.stacktop == fiber.stackstart);
    _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));

    // A cfunction callee gets the pushed arguments in order.
    args[0] = intv(5);
    fiber = try fiberWithArgs(&args);
    expect(wrap.toNumber(try vm_calls.callNonfn(fiber, eval("vmcalls/sum"))) == 11);
    _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));

    // Zero pushed arguments reach the arity check rather than reading a stack
    // slot that holds nothing.
    fiber = try fiberWithArgs(&.{});
    expect(refusal(vm_calls.callNonfn, .{ @as(*fibers.Fiber, fiber), kw("a") })
        .says(":a called with 0 arguments, possibly expected 1"));
    _ = gc_alloc.gcunroot(wrap.fromFiber(fiber));
}

// --------------------------------------------------------------- fill loops

fn fillTable() void {
    const table = tables.new(4);
    const mem = [_]repr.Value{ kw("a"), intv(1), kw("b"), intv(2) };
    gc_alloc.gcroot(wrap.fromTable(table));
    vm_calls.fillTable(table, &mem, 4);
    expect(table.count == 2);
    expect(harness.integerIs(tables.get(table, kw("a")), 1));
    expect(harness.integerIs(tables.get(table, kw("b")), 2));
    // A zero count writes nothing and reads nothing.
    vm_calls.fillTable(table, null, 0);
    expect(table.count == 2);
    _ = gc_alloc.gcunroot(wrap.fromTable(table));
}

fn fillStruct() void {
    const st = structs.begin(2);
    const mem = [_]repr.Value{ kw("a"), intv(1), kw("b"), intv(2) };
    vm_calls.fillStruct(st, &mem, 4);
    const done = structs.end(st);
    expect(structs.head(done).length == 2);
    expect(harness.integerIs(harness.field(done, "a"), 1));
    expect(harness.integerIs(harness.field(done, "b"), 2));
}

fn fillString() raise.Raising(void) {
    const buffer = buffers.new(8);
    const mem = [_]repr.Value{ intv(1), kw("ab"), eval("\"cd\"") };
    gc_alloc.gcroot(wrap.fromBuffer(buffer));
    try vm_calls.fillString(buffer, &mem);
    // Each element is rendered as `string` would render it: a keyword loses
    // its colon and a string loses its quotes.
    expect(buffer.count == 5);
    expect(std.mem.eql(u8, buffer.slice()[0..5], "1abcd"));
    try vm_calls.fillString(buffer, &.{});
    expect(buffer.count == 5);
    _ = gc_alloc.gcunroot(wrap.fromBuffer(buffer));
}

/// A raise from inside the fill loop, which is the one thing about these three
/// that a Janet-level test cannot reach: the callback that raises belongs to
/// an abstract type no in-tree module defines.
///
/// There were two halves here and the second is gone rather than fixed. It
/// drove `fillTable` through an abstract whose `hash` raised, from inside a
/// callback whose signature had no way to say it had failed. `hash` is typed
/// non-raising — see `src/zig/abstract_type.zig` — because it is reached from
/// comparisons that must be total, so a raise there has no caller that could
/// act on it, and the callback now has no way to produce one. `tostring` is
/// raising and is what this keeps.
fn aRaiseFromInsideAFillLoop() void {
    const buffer = buffers.new(8);
    const mem = [_]repr.Value{ intv(1), loud_string_value };

    gc_alloc.gcroot(wrap.fromBuffer(buffer));
    expect(refusal(vm_calls.fillString, .{ buffer, @as([]const repr.Value, mem[0..2]) })
        .says("tostring raised"));
    // The element before the raising one was already written, and the buffer
    // survives the raise.
    expect(buffer.count == 1);
    expect(buffer.slice()[0] == '1');
    _ = gc_alloc.gcunroot(wrap.fromBuffer(buffer));
}

// ------------------------------------------------------------------- entry

fn cfunContract(argv: []repr.Value) raise.Raising(repr.Value) {
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
