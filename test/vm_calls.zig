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
const abi = @import("abi");
const c = abi.c;
const raise = @import("raise");
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
const vm_calls = subsystems.vm_calls;
const fiber_core = subsystems.fiber_core;
const args_core = subsystems.args_core;
const abstract_type = subsystems.abstract_type;
const AbstractType = abstract_type.AbstractType;

const assert = std.debug.assert;

// ------------------------------------------------------------------ helpers

var test_env: ?*c.JanetTable = null;

fn kw(name: [*:0]const u8) c.Janet {
    return c.janet_ckeywordv(name);
}

fn intv(i: i32) c.Janet {
    return harness.wrapInteger(i);
}

fn isNil(x: c.Janet) bool {
    return harness.isType(x, c.JANET_NIL);
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
fn eval(source: [*:0]const u8) c.Janet {
    var out = c.janet_wrap_nil();
    assert(c.janet_dostring(test_env, source, "vm-calls-test", &out) == 0);
    c.janet_gcroot(out);
    return out;
}

/// A fiber with a run of arguments pushed onto it, in the state `run_vm`
/// leaves before `JOP_CALL`: `stackstart` marks where the arguments begin and
/// `stacktop` where they end.
fn fiberWithArgs(argv: []const c.Janet) raise.Raising(*c.JanetFiber) {
    const fiber = c.janet_fiber(c.janet_unwrap_function(eval("(fn [] nil)")), 32, 0, null);
    assert(fiber != null);
    c.janet_gcroot(c.janet_wrap_fiber(fiber));
    fiber.*.stackstart = fiber.*.stacktop;
    for (argv) |value| try fiber_core.push(fiber, value);
    return fiber;
}

// ------------------------------------------------------- cfunction fixtures

fn cfunSum(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    var total: f64 = 0;
    var i: i32 = 0;
    while (i < argc) : (i += 1) total += try args_core.getNumber(argv, i);
    return c.janet_wrap_number(total);
}

/// Returns its arguments as a tuple, so a caller can assert their order.
fn cfunArgs(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    return c.janet_wrap_tuple(c.janet_tuple_n(argv, argc));
}

const cfuns = [_]c.JanetReg{
    .{ .name = "vmcalls/sum", .cfun = raise.stored(&cfunSum), .documentation = null },
    .{ .name = "vmcalls/args", .cfun = raise.stored(&cfunArgs), .documentation = null },
    .{ .name = "vmcalls/contract", .cfun = raise.stored(&cfunContract), .documentation = null },
    .{ .name = null, .cfun = null, .documentation = null },
};

// -------------------------------------------------------- abstract fixtures

/// Callable: its `call` callback answers with its own argument count, so a
/// test can tell it apart from the indexed fallback.
fn callableCall(p: ?*anyopaque, argc: i32, argv: [*c]c.Janet) raise.Error!c.Janet {
    _ = p;
    _ = argv;
    return harness.wrapInteger(argc);
}

const at_callable: AbstractType = .{ .name = "vm-calls/callable", .call = &callableCall };

/// Indexable: no `call`, so `methodInvoke` falls out of the abstract arm into
/// the arity check and `janet_in`.
fn indexableGet(p: ?*anyopaque, key: c.Janet, out: [*c]c.Janet) raise.Error!c_int {
    _ = p;
    if (c.janet_checkint(key) == 0) return 0;
    out.* = harness.wrapInteger(c.janet_unwrap_integer(key) * 10);
    return 1;
}

const at_indexable: AbstractType = .{ .name = "vm-calls/indexable", .get = &indexableGet };

/// Raises from `tostring`, which `fillString` reaches through
/// `janet_to_string_b`.
fn loudTostring(p: ?*anyopaque, buffer: [*c]c.JanetBuffer) raise.Error!void {
    _ = p;
    _ = buffer;
    return raise.panic("tostring raised");
}

const at_loud_string: AbstractType = .{ .name = "vm-calls/loud-string", .tostring = &loudTostring };

var callable_value: c.Janet = undefined;
var indexable_value: c.Janet = undefined;
var loud_string_value: c.Janet = undefined;

fn makeAbstracts() void {
    callable_value = c.janet_wrap_abstract(c.janet_abstract(abstract_type.stored(&at_callable), 1));
    indexable_value = c.janet_wrap_abstract(c.janet_abstract(abstract_type.stored(&at_indexable), 1));
    loud_string_value = c.janet_wrap_abstract(c.janet_abstract(abstract_type.stored(&at_loud_string), 1));
    c.janet_gcroot(callable_value);
    c.janet_gcroot(indexable_value);
    c.janet_gcroot(loud_string_value);
}

// ------------------------------------------------------------ methodInvoke

fn invokeACfunction() raise.Raising(void) {
    var argv = [_]c.Janet{ intv(1), intv(2), intv(4) };
    const callee = eval("vmcalls/sum");
    assert(harness.isType(callee, c.JANET_CFUNCTION));
    assert(c.janet_unwrap_number(try vm_calls.methodInvoke(callee, 3, &argv)) == 7);
    // Arity is the callee's business, not this layer's: zero arguments reach
    // the cfunction rather than the arity check below.
    assert(c.janet_unwrap_number(try vm_calls.methodInvoke(callee, 0, null)) == 0);
}

fn invokeAFunction() raise.Raising(void) {
    var argv = [_]c.Janet{ intv(3), intv(4) };
    const callee = eval("(fn [a b] (* a b))");
    assert(harness.isType(callee, c.JANET_FUNCTION));
    assert(c.janet_unwrap_number(try vm_calls.methodInvoke(callee, 2, &argv)) == 12);
}

fn invokeAnAbstractWithACallCallback() raise.Raising(void) {
    var argv = [_]c.Janet{ intv(1), intv(1), intv(1) };
    // The callback answers with argc, so this also shows that the arity check
    // below is not reached: three arguments would have failed it.
    assert(c.janet_unwrap_number(try vm_calls.methodInvoke(callable_value, 3, &argv)) == 3);
    assert(c.janet_unwrap_number(try vm_calls.methodInvoke(callable_value, 0, null)) == 0);
    // One argument is the case that tells the two paths apart by value rather
    // than by arity: the indexed fallback would answer with `janet_in` on an
    // abstract that has no `get`, and the callback answers 1.
    assert(c.janet_unwrap_number(try vm_calls.methodInvoke(callable_value, 1, &argv)) == 1);
}

fn anAbstractWithoutCallFallsThroughToIndexing() raise.Raising(void) {
    var argv = [_]c.Janet{ intv(4), intv(5) };
    assert(c.janet_unwrap_number(try vm_calls.methodInvoke(indexable_value, 1, &argv)) == 40);
    // Having fallen through, it is subject to the arity check the six indexed
    // types share. The message renders an abstract with its address, so this
    // is the one arity refusal not compared whole — `beginsWith` is the
    // C contract's second `EXPECT_PANIC_PREFIX` macro.
    const r = refusal(vm_calls.methodInvoke, .{ indexable_value, 2, @as([*c]c.Janet, &argv) });
    assert(r.beginsWith("<vm-calls/indexable "));
    assert(harness.isType(r.payload, c.JANET_STRING));
    const message = c.janet_unwrap_string(r.payload);
    const length: usize = @intCast(c.janet_string_length(message));
    assert(std.mem.endsWith(u8, message[0..length], " called with 2 arguments, possibly expected 1"));
}

fn invokeEachIndexedType() raise.Raising(void) {
    var key = [_]c.Janet{kw("a")};
    assert(c.janet_unwrap_number(try vm_calls.methodInvoke(eval("@{:a 1}"), 1, &key)) == 1);
    assert(c.janet_unwrap_number(try vm_calls.methodInvoke(eval("{:a 2}"), 1, &key)) == 2);
    key[0] = intv(1);
    assert(c.janet_unwrap_number(try vm_calls.methodInvoke(eval("@[7 8]"), 1, &key)) == 8);
    assert(c.janet_unwrap_number(try vm_calls.methodInvoke(eval("[9 10]"), 1, &key)) == 10);
    assert(c.janet_unwrap_number(try vm_calls.methodInvoke(eval("\"ab\""), 1, &key)) == 'b');
    assert(c.janet_unwrap_number(try vm_calls.methodInvoke(eval("@\"cd\""), 1, &key)) == 'd');
}

fn theIndexedArityCheck() void {
    var argv = [_]c.Janet{ intv(0), intv(0) };
    assert(refusal(vm_calls.methodInvoke, .{ eval("\"ab\""), 2, @as([*c]c.Janet, &argv) })
        .says("\"ab\" called with 2 arguments, possibly expected 1"));
    assert(refusal(vm_calls.methodInvoke, .{ eval("\"ab\""), 0, @as([*c]c.Janet, null) })
        .says("\"ab\" called with 0 arguments, possibly expected 1"));
}

fn theDefaultArmReversesTheLookup() raise.Raising(void) {
    var argv = [_]c.Janet{eval("{:a 11}")};
    // A keyword callee indexes its argument, not the other way round: this is
    // what makes `(:a struct)` work.
    assert(c.janet_unwrap_number(try vm_calls.methodInvoke(kw("a"), 1, &argv)) == 11);
    // Any other unlisted type takes the same arm. A number is not a key of
    // that struct, so the answer is nil rather than a refusal.
    assert(isNil(try vm_calls.methodInvoke(intv(5), 1, &argv)));
    assert(refusal(vm_calls.methodInvoke, .{ kw("a"), 3, @as([*c]c.Janet, &argv) })
        .says(":a called with 3 arguments, possibly expected 1"));
}

// ------------------------------------------------------------ methodLookup

/// Raising since Phase 11 Part 15, which is rule 33's corollary arriving from
/// the runtime side: `methodLookup` reached `janet_get` through the C face,
/// and every one of its four callers is `raise.Raising`, so an abstract's
/// `get` refusing became a report nobody consumed. The three cases here answer
/// rather than raise, so each is a `try`; the refusal that motivated the change
/// is asserted below.
fn methodLookup() raise.Raising(void) {
    const found = try vm_calls.methodLookup(eval("@{:m vmcalls/sum}"), "m");
    assert(harness.isType(found, c.JANET_CFUNCTION));
    assert(isNil(try vm_calls.methodLookup(eval("@{:m 1}"), "other")));
    // A value with no keys at all answers nil rather than raising, which is
    // what lets the operator fallbacks try the other operand.
    assert(isNil(try vm_calls.methodLookup(intv(5), "m")));
}

// -------------------------------------------------------------------- mcall

fn mcall() raise.Raising(void) {
    var argv = [_]c.Janet{ eval("@{:sum (fn [self a b] (+ a b))}"), intv(2), intv(3) };
    // The receiver is passed to the method as its first argument, which is why
    // the method takes three parameters for a two-argument call.
    assert(c.janet_unwrap_number(try vm_calls.mcall("sum", 3, &argv)) == 5);
    argv[0] = intv(7);
    assert(refusal(vm_calls.mcall, .{ "nope", 1, @as([*c]c.Janet, &argv) })
        .says("could not find method :nope for 7"));
    assert(refusal(vm_calls.mcall, .{ "len", 0, @as([*c]c.Janet, null) })
        .says("method :len expected at least 1 argument"));
}

// --------------------------------------------------------- operator methods

fn unaryCall() raise.Raising(void) {
    const receiver = eval("@{:- (fn [self] 42)}");
    assert(c.janet_unwrap_number(try vm_calls.unaryCall("-", receiver)) == 42);
    assert(refusal(vm_calls.unaryCall, .{ "-", intv(5) }).says("could not find method :- for 5"));
}

fn binopCallPrefersTheLeftOperand() raise.Raising(void) {
    const lhs = eval("@{:+ vmcalls/args}");
    const result = try vm_calls.binopCall("+", "r+", lhs, intv(9));
    const tup = c.janet_unwrap_tuple(result);
    assert(c.janet_tuple_length(tup) == 2);
    assert(harness.equals(tup[0], lhs));
    assert(c.janet_unwrap_number(tup[1]) == 9);
}

fn binopCallSwapsForTheRightOperand() raise.Raising(void) {
    const rhs = eval("@{:r+ vmcalls/args}");
    const result = try vm_calls.binopCall("+", "r+", intv(9), rhs);
    const tup = c.janet_unwrap_tuple(result);
    // The right-hand method receives itself first. Asserted rather than
    // assumed: a port that passed them in source order would still return a
    // plausible answer for a commutative operator.
    assert(c.janet_tuple_length(tup) == 2);
    assert(harness.equals(tup[0], rhs));
    assert(c.janet_unwrap_number(tup[1]) == 9);
}

fn binopCallWithNeitherMethod() void {
    assert(refusal(vm_calls.binopCall, .{ "+", "r+", intv(1), intv(2) })
        .says("could not find method :+ for 1 or :r+ for 2"));
}

// ----------------------------------------------------------- resolveMethod

fn resolveMethod() raise.Raising(void) {
    var args = [_]c.Janet{ eval("@{:m vmcalls/sum}"), intv(1) };
    var fiber = try fiberWithArgs(&args);
    const callee = try vm_calls.resolveMethod(kw("m"), fiber);
    assert(harness.isType(callee, c.JANET_CFUNCTION));
    // Resolution reads the receiver and leaves the stack alone: the arguments
    // are still pushed when it returns, because `JOP_CALL` consumes them next.
    assert(fiber.stacktop - fiber.stackstart == 2);
    _ = c.janet_gcunroot(c.janet_wrap_fiber(fiber));

    args[0] = eval("\"abc\"");
    fiber = try fiberWithArgs(args[0..1]);
    assert(refusal(vm_calls.resolveMethod, .{ kw("m"), @as([*c]c.JanetFiber, fiber) })
        .says("unknown method :m invoked on \"abc\""));
    _ = c.janet_gcunroot(c.janet_wrap_fiber(fiber));

    // Unreachable from Janet source — the compiler rejects a zero-argument
    // method call — so only an assembled function or this contract gets here.
    fiber = try fiberWithArgs(&.{});
    assert(refusal(vm_calls.resolveMethod, .{ kw("m"), @as([*c]c.JanetFiber, fiber) })
        .says("method call (:m) takes at least 1 argument, got 0"));
    _ = c.janet_gcunroot(c.janet_wrap_fiber(fiber));
}

// --------------------------------------------------------------- callNonfn

fn callNonfn() raise.Raising(void) {
    // A table callee with one argument is an indexed lookup.
    var args = [_]c.Janet{ kw("a"), intv(6) };
    var fiber = try fiberWithArgs(args[0..1]);
    assert(c.janet_unwrap_number(try vm_calls.callNonfn(fiber, eval("@{:a 3}"))) == 3);
    // The arguments are consumed: `stacktop` is back at `stackstart`, which is
    // what lets the callee push a frame of its own over them.
    assert(fiber.stacktop == fiber.stackstart);
    _ = c.janet_gcunroot(c.janet_wrap_fiber(fiber));

    // A cfunction callee gets the pushed arguments in order.
    args[0] = intv(5);
    fiber = try fiberWithArgs(&args);
    assert(c.janet_unwrap_number(try vm_calls.callNonfn(fiber, eval("vmcalls/sum"))) == 11);
    _ = c.janet_gcunroot(c.janet_wrap_fiber(fiber));

    // Zero pushed arguments reach the arity check rather than reading a stack
    // slot that holds nothing.
    fiber = try fiberWithArgs(&.{});
    assert(refusal(vm_calls.callNonfn, .{ @as([*c]c.JanetFiber, fiber), kw("a") })
        .says(":a called with 0 arguments, possibly expected 1"));
    _ = c.janet_gcunroot(c.janet_wrap_fiber(fiber));
}

// --------------------------------------------------------------- fill loops

fn fillTable() void {
    const table = c.janet_table(4);
    const mem = [_]c.Janet{ kw("a"), intv(1), kw("b"), intv(2) };
    c.janet_gcroot(c.janet_wrap_table(table));
    vm_calls.fillTable(table, &mem, 4);
    assert(table.*.count == 2);
    assert(harness.integerIs(c.janet_table_get(table, kw("a")), 1));
    assert(harness.integerIs(c.janet_table_get(table, kw("b")), 2));
    // A zero count writes nothing and reads nothing.
    vm_calls.fillTable(table, null, 0);
    assert(table.*.count == 2);
    _ = c.janet_gcunroot(c.janet_wrap_table(table));
}

fn fillStruct() void {
    const st = c.janet_struct_begin(2);
    const mem = [_]c.Janet{ kw("a"), intv(1), kw("b"), intv(2) };
    vm_calls.fillStruct(st, &mem, 4);
    const done = c.janet_struct_end(st);
    assert(c.janet_struct_length(done) == 2);
    assert(harness.integerIs(harness.field(done, "a"), 1));
    assert(harness.integerIs(harness.field(done, "b"), 2));
}

fn fillString() raise.Raising(void) {
    const buffer = c.janet_buffer(8);
    const mem = [_]c.Janet{ intv(1), kw("ab"), eval("\"cd\"") };
    c.janet_gcroot(c.janet_wrap_buffer(buffer));
    try vm_calls.fillString(buffer, &mem, 3);
    // Each element is rendered as `string` would render it: a keyword loses
    // its colon and a string loses its quotes.
    assert(buffer.*.count == 5);
    assert(std.mem.eql(u8, buffer.*.data[0..5], "1abcd"));
    try vm_calls.fillString(buffer, null, 0);
    assert(buffer.*.count == 5);
    _ = c.janet_gcunroot(c.janet_wrap_buffer(buffer));
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
    const buffer = c.janet_buffer(8);
    const mem = [_]c.Janet{ intv(1), loud_string_value };

    c.janet_gcroot(c.janet_wrap_buffer(buffer));
    assert(refusal(vm_calls.fillString, .{ buffer, @as([*c]const c.Janet, &mem), 2 })
        .says("tostring raised"));
    // The element before the raising one was already written, and the buffer
    // survives the raise.
    assert(buffer.*.count == 1);
    assert(buffer.*.data[0] == '1');
    _ = c.janet_gcunroot(c.janet_wrap_buffer(buffer));
}

// ------------------------------------------------------------------- entry

fn cfunContract(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    _ = argv;
    try args_core.fixarity(argc, 0);

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

    return c.janet_wrap_nil();
}

pub fn run() void {
    _ = c.janet_init();
    test_env = c.janet_core_env(null);
    c.janet_cfuns(test_env, null, &cfuns);
    makeAbstracts();

    // From Janet source, so that everything above runs with a live fiber under
    // it: `methodInvoke` reaches `callImpl`, which has no meaning without one.
    _ = eval("(vmcalls/contract)");

    c.janet_deinit();
    std.debug.print("vm calls contract ok\n", .{});
}
