//! Behavioral contract for the bytecode interpreter's main loop.
//!
//! The Janet suites already run every opcode; thirty-eight of them execute for
//! this binary to reach `main`. What they do not pin is what this file is for.
//!
//! The messages the loop raises itself, fourteen of them, are the one part of
//! `runVm` that no Janet program checks and every Janet programmer reads. Each
//! is built by `pp_format.panicf` with a `%v` for a `Janet`, a `%d` for an
//! `int32_t` and a `%s` for a `const char *`, so a formatting mistake produces
//! a plausible wrong message rather than a crash. Every one is compared byte
//! for byte.
//!
//! The signal rather than the message. `vm_entry.continueFiber` returns a
//! signal, and several opcodes exist only to produce a particular one:
//! `JOP_SIGNAL` clamps its operand into the user range, an unknown opcode is
//! how a breakpoint reports itself, and `JOP_PROPAGATE` passes a child's
//! status upward unchanged. A test that only looked at payloads would pass
//! with all three confused.
//!
//! The resume-state decoding at the head of the loop. Five flags decide where
//! a resumed fiber puts the value it was resumed with, whether it re-runs the
//! instruction it stopped on, and whether it pops a native frame first.
//! Nothing else in the tree reads them and the suites reach them only
//! incidentally.
//!
//! The four bounds the loop checks on an instruction's own operands,
//! `"invalid constant"`, `"invalid funcdef"`, `"invalid upvalue index"` and
//! `"invalid upvalue environment"`, cannot come from assembled code: the
//! assembler rejects every instruction that would produce them. The cases
//! reach them by rewriting one operand of a compiled function in place, to the
//! first index past the end.
//!
//! One thing is deliberately not pinned: `JOP_SIGNAL`'s lower clamp, which is
//! unreachable because the assembler declines to encode a negative operand in
//! a one-byte field.
//!
//! ## Two things this contract does differently
//!
//! Nothing counts the errors. `raised` below asserts the signal at each site
//! and stops there, so a case that stopped raising fails where it stands.
//!
//! The assembler sections ask the environment rather than the configuration.
//! `harness.coreOptional("asm")` is the distinction: what these cases need is
//! the `asm` *binding*, and `options` names subsystems.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstract_type = subsystems.abstract_type;
const abstracts = @import("subsystems").value.abstracts;
const args = subsystems.args;
const constants = @import("constants");
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const fibers = @import("subsystems").value.fibers;
const functions = @import("subsystems").value.functions;
const gc_alloc = @import("subsystems").gc_alloc;
const harness = @import("harness.zig");
const pp_describe = @import("subsystems").pp_describe;
const raise = @import("subsystems").raise;
const registry = @import("subsystems").registry;
const repr = @import("repr");
const signal_core = @import("subsystems").signal;
const subsystems = @import("subsystems");
const tables = @import("subsystems").value.tables;
const value = @import("subsystems").value;
const vm_entry = subsystems.vm_entry;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// An abstract whose `put` suspends the fiber doing the put, which is the one
/// way to resume a fiber stopped at `.put` or `.put_index`.
const at_yielding_put = abstract_type.define(anyopaque, .{ .name = "vm-run/yielding-put", .put = &yieldingPut });

/// `JANET_VM_HAS_INTERRUPT`, which decides whether the loop reads
/// `auto_suspend` at all.
const has_interrupt = constants.JANET_VM_HAS_INTERRUPT == 1;

/// Whether this build registered `asm`. The cases that can only be expressed in
/// assembled bytecode ask it first, because an absent binding is a *compile*
/// error inside `eval` rather than the runtime error they are looking for.
var has_assembler = false;
/// The collection count `vmrun/arm-collection` set the interval to.
var armed_at: usize = 0;
var test_env: ?*tables.Table = null;

// ==========================================================================
// Cases
// ==========================================================================

/// Roots whatever it produces and never unroots it: a Janet value in a Zig
/// local is not a root, and these live across calls that compile source and
/// intern keywords.
fn eval(source: [*:0]const u8) repr.Value {
    var out = wrap.fromNil();
    const status = core_env.dostring(test_env.?, source, "vm-run-test", &out);
    if (status != 0) {
        std.debug.print("unexpected error from: {s}\n", .{source});
        std.debug.print("                  got: {s}\n", .{pp_describe.toString(out)});
        expect(false);
    }
    gc_alloc.gcroot(out);
    return out;
}

/// Wrapped in a fiber rather than handed to `env.dostring`, because `dostring`
/// prints a stack trace on the way out: this file expects twenty-five errors
/// and would otherwise bury its own output in them. The fiber masks error and
/// yield, so `vm_entry.continueFiber` reports the signal instead.
fn raised(source: []const u8) repr.Value {
    var buffer: [2048]u8 = undefined;
    const wrapped = std.fmt.bufPrintZ(&buffer, "(fiber/new (fn [] {s}) :ye)", .{source}) catch unreachable;
    const fiberv = eval(wrapped);
    const resumed = vm_entry.continueFiber(wrap.toFiber(fiberv), wrap.fromNil());
    if (resumed.signal != abi.Signal.@"error") {
        std.debug.print("expected an error from: {s}\n", .{source});
        expect(false);
    }
    gc_alloc.gcroot(resumed.value);
    return resumed.value;
}

fn expectError(source: []const u8, message: [*:0]const u8) void {
    const payload = raised(source);
    if (!harness.stringValueIs(payload, message)) {
        std.debug.print("source:   {s}\n", .{source});
        std.debug.print("expected: {s}\n", .{message});
        std.debug.print("     got: {s}\n", .{pp_describe.toString(payload)});
        expect(false);
    }
}

/// `expectError` for a message with two correct spellings.
fn expectErrorEither(source: []const u8, message: [*:0]const u8, other: [*:0]const u8) void {
    const payload = raised(source);
    if (!harness.stringValueIs(payload, message) and !harness.stringValueIs(payload, other)) {
        std.debug.print("source:   {s}\n", .{source});
        std.debug.print("expected: {s}\n", .{message});
        std.debug.print("       or {s}\n", .{other});
        std.debug.print("     got: {s}\n", .{pp_describe.toString(payload)});
        expect(false);
    }
}

/// Compares pretty-printed forms rather than values, because `order.equals` on
/// a mutable collection compares identity: two separately built `![1 2 3]`s are
/// not equal, and most of what the loop constructs is mutable.
fn expectEqual(source: []const u8, expected: []const u8) void {
    var buffer: [2048]u8 = undefined;
    var wanted: [2048]u8 = undefined;
    const got = eval(std.fmt.bufPrintZ(&buffer, "(string/format \"%p\" (do {s}))", .{source}) catch unreachable);
    const want = eval(std.fmt.bufPrintZ(&wanted, "(string/format \"%p\" (do {s}))", .{expected}) catch unreachable);
    if (!harness.equals(got, want)) {
        std.debug.print("source:   {s}\n", .{source});
        std.debug.print("expected: {s}\n", .{wrap.toString(want)});
        std.debug.print("     got: {s}\n", .{wrap.toString(got)});
        expect(false);
    }
}

/// Resume a fiber built in Janet source and report the signal as well as the
/// value, which is what the `JOP_SIGNAL` and `JOP_PROPAGATE`
/// cases.
fn resumeFiber(fiberv: repr.Value, in: repr.Value) vm_entry.Resumed {
    expect(harness.isType(fiberv, repr.Tag.fiber));
    return vm_entry.continueFiber(wrap.toFiber(fiberv), in);
}

/// The four arithmetic opcodes and their immediate forms take the numeric path
/// only when both operands are numbers, and every other opcode in the group
/// narrows a double to an integer first. The narrowing is what raises.
///
/// Every operand here comes from a function parameter, and that is not
/// stylistic. The compiler folds constant arithmetic, so `(- 2 3)` is a load
/// of -1 and reaches no opcode at all: with constant operands the operands of
/// every binary opcode could be swapped without failing an assertion here. A
/// contract for the interpreter has to keep its operands away from the
/// optimizer.
fn arithmeticTakesTheNumericPath() void {
    expectEqual("(do (defn f [a b] [(+ a b) (- a b) (* a b) (/ a b)]) (f 3 2))", "[5 1 6 1.5]");
    expectEqual("(do (defn f [a b] [(div a b) (mod a b) (% a b)]) (f 7 -2))", "[-4 -1 1]");
    expectEqual("(do (defn f [a b] (mod a b)) (f 7 0))", "7");
    expectEqual("(do (defn f [a b] [(band a b) (bor a b) (bxor a b)]) (f 12 10))", "[8 14 6]");
    expectEqual("(do (defn f [a b] (blshift a b)) (f 3 4))", "48");
    // A shift is a wrapping shift and its count is taken modulo 32. C leaves
    // all three of these undefined, a negative left operand, an overflow into
    // the sign bit and a count at or above the width, and this runtime defines
    // all three, which is what makes them assertable at all. The results are
    // what both supported architectures' shift instructions produce.
    expectEqual("(do (defn f [a b] (blshift a b)) (f -8 1))", "-16");
    expectEqual("(do (defn f [a b] (blshift a b)) (f 1 31))", "-2147483648");
    expectEqual("(do (defn f [a b] (blshift a b)) (f 1 32))", "1");
    expectEqual("(do (defn f [a b] (blshift a b)) (f 1 33))", "2");
    expectEqual("(do (defn f [a b] (brshift a b)) (f -8 33))", "-4");
    expectEqual("(do (defn f [a b] (brushift a b)) (f 4026531840 33))", "2013265920");
    // The unsigned form narrows its left operand to `uint32_t`, so a negative
    // one raises there rather than shifting; only the signed form takes it.
    expectEqual("(do (defn f [a b] (brshift a b)) (f -8 1))", "-4");
    expectEqual("(do (defn f [a b] (brushift a b)) (f 4026531840 1))", "2013265920");
    // The immediate forms, which encode the right operand in the instruction.
    // The negative ones matter on their own: the immediate field is read with
    // an arithmetic shift, and reading it unsigned passes every non-negative
    // test there is.
    expectEqual("(do (defn f [x] [(+ x 3) (- x 3) (* x 3)]) (f 4))", "[7 1 12]");
    expectEqual("(do (defn f [x] [(+ x -3) (* x -3)]) (f 4))", "[1 -12]");
    expectEqual("(do (defn f [x] (blshift x 3)) (f 64))", "512");
    expectEqual("(do (defn f [x] (brshift x 3)) (f -64))", "-8");
    expectEqual("(do (defn f [x] (brushift x 3)) (f 4026531840))", "503316480");
}

fn aBitwiseOperandOutOfRange() void {
    expectError("(band 1e20 1)", "value 1e+20 out of range for 32-bit signed integers");
    expectError("(brushift 1e20 1)", "value 1e+20 out of range for 32-bit unsigned integers");
    // The immediate form narrows the same way.
    expectError("(do (defn f [x] (blshift x 3)) (f 1e20))", "value 1e+20 out of range for 32-bit signed integers");
    expectError("(do (defn f [x] (brushift x 3)) (f 1e20))", "value 1e+20 out of range for 32-bit unsigned integers");
    // A NaN fails the range test rather than the round trip. Produced by
    // dividing at run time, so that the constant folder is out of it and this
    // vector is about the opcode rather than about the emitter; the emitter's
    // own narrowing of a NaN constant is checked, and the literal form below
    // reaches the same message. The quotient is the FPU's default NaN, which
    // has the sign bit set on an x86-64 host, wasmtime's included, and clear
    // on aarch64. The formatter passes it to `snprintf`, which prints the
    // sign under musl and wasi-libc and omits it under Apple's libc. Either
    // spelling is correct.
    expectErrorEither(
        "(do (defn f [a b] (band (/ a b) 1)) (f 0 0))",
        "value nan out of range for 32-bit signed integers",
        "value -nan out of range for 32-bit signed integers",
    );
    expectError("(band math/nan 1)", "value nan out of range for 32-bit signed integers");
    // The range test at its ends: the largest and smallest values an `int32_t`
    // holds are in range, and so is the largest a `uint32_t` holds.
    expectEqual("(do (defn f [a b] (band a b)) [(f 2147483647 -1) (f -2147483648 -1)])", "[2147483647 -2147483648]");
    expectEqual("(do (defn f [a b] (brushift a b)) (f 4294967295 0))", "4294967295");
}

/// The right operand is narrowed to `int32_t` whatever the left was narrowed
/// to, and the whole message is pinned: `%f` renders the operand as the
/// `double` it is, so the digits are the same on every target.
fn aBitwiseRightOperandOutOfRange() void {
    expectError("(band 1 1e20)", "rhs must be valid 32-bit signed integer, got 100000000000000000000.000000");
    expectError("(brushift 1 1e20)", "rhs must be valid 32-bit signed integer, got 100000000000000000000.000000");
    // A count that fits a `uint32_t` and not an `int32_t` is rejected even by
    // the unsigned opcode. That asymmetry is the only well-defined way to tell
    // the two narrowings apart.
    expectError(
        "(do (defn f [a b] (brushift a b)) (f 4 3000000000))",
        "rhs must be valid 32-bit signed integer, got 3000000000.000000",
    );
}

/// Every arithmetic and bitwise opcode falls back to a method when an operand
/// is not a number, and the fallback tries `:op` on the left before `:rop` on
/// the right. `vm_calls` owns the fallback; what is asserted here is that the
/// loop reaches it from both the register and the immediate forms.
fn theOperatorFallbacks() void {
    expectEqual("(do (def t !{:+ (fn [self o] [:plus o])}) (+ t 1))", "[:plus 1]");
    expectEqual("(do (def t !{:r+ (fn [self o] [:rplus o])}) (+ 1 t))", "[:rplus 1]");
    expectEqual("(do (def t !{:& (fn [self o] :and)}) (band t 1))", ":and");
    // `:~` is not a keyword literal: the reader takes `~` for the quasiquote
    // shorthand and leaves the empty keyword behind.
    expectEqual("(do (def t !{(keyword \"~\") (fn [self] :not)}) (bnot t))", ":not");
    // Both shift-right opcodes fall back to the same method name, because C
    // stringified the operator and the signed and unsigned forms share it.
    expectEqual("(do (def t !{:>> (fn [self o] :shr)}) (brshift t 1))", ":shr");
    expectEqual("(do (def t !{:>> (fn [self o] :shr)}) (brushift t 1))", ":shr");
    // The immediate forms reach `mcall` rather than `binopCall`.
    expectEqual("(do (def t !{:+ (fn [self o] [:plus o])})    (defn f [x] (+ x 3)) (f t))", "[:plus 3]");
    expectError("(do (defn f [x] (+ x 3)) (f :kw))", "could not find method :+ for :kw");
}

fn comparison() void {
    expectEqual("(do (defn f [a b] [(< a b) (<= a b) (> a b) (>= a b)]) (f 1 2))", "[true true false false]");
    expectEqual("(do (defn f [a b] [(< a b) (<= a b) (> a b) (>= a b)]) (f 2 2))", "[false true false true]");
    expectEqual("(do (defn f [a b] [(= a b) (not= a b)]) (f 1 1))", "[true false]");
    expectEqual("(do (defn f [a b] [(= a b) (not= a b)]) (f [1] [1]))", "[true false]");
    expectEqual("(do (defn f [a b] (compare a b)) [(f 1 2) (f 2 2) (f 2 1)])", "[-1 0 1]");
    // The immediate forms, including the negative operand.
    expectEqual("(do (defn f [x] [(< x 3) (> x 3)]) [(f 2) (f 4)])", "[[true false] [false true]]");
    expectEqual("(do (defn f [x] [(< x -3) (> x -3)]) [(f -5) (f 0)])", "[[true false] [false true]]");
    // Equality against an immediate is false for a non-number without
    // unwrapping it. Zero is the operand that distinguishes checking from not
    // checking, because a tagged-layout nil unwraps to 0.0 and a NaN-boxed one
    // unwraps to a NaN.
    expectEqual("(do (defn f [x] (= x 0)) [(f 0) (f nil) (f :kw)])", "[true false false]");
    expectEqual("(do (defn f [x] (not= x 0)) [(f 0) (f nil)])", "[false true]");
    // A non-number operand goes through `order.compare`, which orders across
    // types rather than raising.
    expectEqual("(do (defn f [a b] (< a b)) (f :a :b))", "true");
    expectEqual("(do (defn f [x] (< x 3)) (f :a))", "false");
    // All four through `order.compare`, at the operands that tell them apart:
    // two equal keywords, and the greater one first.
    expectEqual(
        "(do (defn f [a b] [(< a b) (<= a b) (> a b) (>= a b)]) [(f :a :a) (f :b :a)])",
        "[[false true false true] [false false true true]]",
    );
}

/// The arity message is built at `JOP_CALL` and again at `JOP_TAILCALL`, with
/// a `%v` for the callee, two `%d`s and a `%s` for the plural. Both sites
/// and both spellings of the plural are asserted, because they are separate
/// format calls.
fn theCallArityMessage() void {
    // JOP_TAILCALL: a call in tail position, which builds the message after
    // recomputing the frame it commits to.
    expectError("(do (defn f [x] x) (defn g [] (f)) (g))", "<function f> called with 0 arguments, expected 1");
    expectError("(do (defn f [x y] x) (defn g [] (f 1)) (g))", "<function f> called with 1 argument, expected 2");
    // JOP_CALL: the same message from a separate site, which the arithmetic
    // around the call is here to force. Every tail-position case above misses
    // this site entirely, so inverting its plural alone would go unnoticed.
    expectError("(do (defn f [x] x) (defn g [] (+ 1 (f))) (g))", "<function f> called with 0 arguments, expected 1");
    expectError("(do (defn f [x y] x) (defn g [] (+ 1 (f 1))) (g))", "<function f> called with 1 argument, expected 2");
}

fn callingACfunction() void {
    expectEqual("(+ (length ![1 2 3]) 0)", "3");
    // In tail position, which pops two frames rather than one.
    expectEqual("(do (defn f [] (length ![1 2])) (f))", "2");
}

/// A callee that is neither a function nor a cfunction goes to `callNonfn`,
/// which is `vm_calls`'; what is asserted here is that both call opcodes reach
/// it and place the result.
fn callingANonFunction() void {
    expectEqual("(do (def t !{:a 1}) (t :a))", "1");
    expectEqual("(do (def t !{:a 1}) (defn f [] (t :a)) (f))", "1");
    // A keyword callee is a method *name* rather than a key: `JOP_CALL`
    // resolves it against the receiver and then calls whatever it named, with
    // the receiver as the first argument. `(:a !{:a 2})` is consequently nil
    // and not 2: it finds 2 and calls it, and calling a number indexes the
    // receiver by it.
    expectEqual("(:a !{:a 2})", "nil");
    expectEqual("(do (def t !{:go (fn [self x] [:went x])}) (:go t 7))", "[:went 7]");
    // A keyword receiver rather than a table or a map, because `%v` renders
    // both of those by address and an address cannot be compared.
    expectError("(:nope :recv)", "unknown method :nope invoked on :recv");
}

fn stackOverflow() void {
    const fiberv = eval(
        "(do (defn deep [n] (+ 1 (deep (+ n 1))))" ++
            "    (def f (fiber/new (fn [] (deep 0)) :e))" ++
            "    (fiber/setmaxstack f 1000) f)",
    );
    const resumed = resumeFiber(fiberv, wrap.fromNil());
    expect(resumed.signal == abi.Signal.@"error");
    expect(harness.stringValueIs(resumed.value, "stack overflow"));
}

/// `maxstack` is the deepest `stacktop` a call may start from, so a call at
/// exactly the limit runs and one a slot past it overflows. `(debug)` stops the
/// fiber just before the call, where `stacktop` is what the call will measure.
/// Both call opcodes check it, the second of these being a tail call.
fn theStackLimitIsInclusive() void {
    const sources = [_][*:0]const u8{
        "(do (defn g [] 2) (fiber/new (fn [] (debug) (g) 1) :d))",
        "(do (defn g [] 2) (fiber/new (fn [] (debug) (g)) :d))",
    };
    for (sources) |source| {
        for ([_]i32{ 0, 1 }) |short| {
            const fiberv = eval(source);
            expect(resumeFiber(fiberv, wrap.fromNil()).signal == abi.Signal.debug);
            const fiber = wrap.toFiber(fiberv);
            fiber.maxstack = fiber.stacktop - short;
            const resumed = resumeFiber(fiberv, wrap.fromNil());
            if (short == 0) {
                expect(resumed.signal == abi.Signal.ok);
            } else {
                expect(resumed.signal == abi.Signal.@"error");
                expect(harness.stringValueIs(resumed.value, "stack overflow"));
            }
        }
    }
}

/// `vm_assert_type` and `vm_assert_types` share one message and one formatter,
/// and `%T` renders a bitmask of permitted types rather than a single one. A
/// set that includes both array and tuple is rendered by `%K`, which names
/// them `indexed value`, and so is one that includes both table and map,
/// which it names `dictionary value`.
fn theTypeAssertions() void {
    // JOP_RESUME, JOP_CANCEL and JOP_PROPAGATE all assert a single type.
    expectError("(resume 5)", "expected fiber, got 5");
    expectError("(cancel 5 :x)", "expected fiber, got 5");
    expectError("(propagate :x 5)", "expected fiber, got 5");
    // JOP_TYPECHECK asserts a mask, and the assembler is the only way to emit
    // one the compiler would not.
    if (has_assembler) {
        expectError("((asm '{:arity 1 :bytecode [(tchck 0 :number) (ret 0)]}) :kw)", "expected number, got :kw");
        expectError("((asm '{:arity 1 :bytecode [(tchck 0 :indexed) (ret 0)]}) :kw)", "expected indexed value, got :kw");
        expectError(
            "((asm '{:arity 1 :bytecode [(tchck 0 (:number :indexed)) (ret 0)]}) :kw)",
            "expected number or indexed value, got :kw",
        );
        expectError("((asm '{:arity 1 :bytecode [(tchck 0 :dictionary) (ret 0)]}) :kw)", "expected dictionary value, got :kw");
        expectError(
            "((asm '{:arity 1 :bytecode [(tchck 0 (:indexed :dictionary)) (ret 0)]}) :kw)",
            "expected indexed value or dictionary value, got :kw",
        );
        // A symbol and a keyword share a tag, so a check for either passes
        // both, and the refusal names both.
        expectEqual("((asm '{:arity 1 :bytecode [(tchck 0 :keyword) (ldi 1 7) (ret 1)]}) 'sym)", "7");
        expectError("((asm '{:arity 1 :bytecode [(tchck 0 :symbol) (ret 0)]}) 1)", "expected symbol or keyword, got 1");
        // A map passes a check for a dictionary, and a set does not.
        expectEqual("((asm '{:arity 1 :bytecode [(tchck 0 :dictionary) (ldi 1 7) (ret 1)]}) (hash-map :a 1))", "7");
        expectError("((asm '{:arity 1 :bytecode [(tchck 0 :dictionary) (ret 0)]}) (hash-set 1))", "expected dictionary value, got <core/set 1>");
        // A set naming one of the two is rendered as it always was.
        expectError("((asm '{:arity 1 :bytecode [(tchck 0 :array) (ret 0)]}) :kw)", "expected array, got :kw");
        // A check that passes moves on by one instruction and no further.
        expectEqual("((asm '{:arity 1 :bytecode [(tchck 0 :number) (ldi 1 7) (ret 1)]}) 1)", "7");
    }
    // JOP_PUSH_ARRAY, which is the splice operator.
    expectError("(do (defn f [& xs] xs) (f |5))", "expected indexed value, got 5");
}

/// Numbers handed out in runs of three from one buffer the callback overwrites
/// on every call.
///
/// The buffer is what this fixture is for. A reader holding two runs of one
/// value at once reads the poison rather than the elements it asked for, so
/// `(f |v |v)` fails here and would pass against a type that hands out its own
/// storage. The elements are numbers, so nothing in the buffer has to be
/// marked.
const Runs = struct {
    count: usize,
    buffer: [3]repr.Value,

    /// What a slot holds where the run is shorter than the buffer, and what a
    /// stale run reads back as. No element takes this value.
    const poison = -1;
};

const runs_at = abstract_type.define(Runs, .{
    .name = "vm-run/runs",
    .length = runsLength,
    .chunk = runsChunk,
    .contents = .elements,
});

/// Element `i` is `i * 10`, and the runs are `[0..3)`, `[3..6)` and so on, the
/// last of them short where `count` is not a multiple of three.
fn runsChunk(self: *Runs, index: usize) abstract_type.Chunk {
    const start = index - index % 3;
    const end = @min(start + 3, self.count);
    for (&self.buffer) |*slot| slot.* = wrap.fromInteger(Runs.poison);
    for (self.buffer[0 .. end - start], start..) |*slot, i| {
        slot.* = wrap.fromInteger(@intCast(i * 10));
    }
    return .{ .items = self.buffer[0 .. end - start], .start = start };
}

fn runsLength(self: *Runs, _: usize) raise.Error!usize {
    return self.count;
}

fn cfunRuns(argv: []repr.Value) raise.Error!repr.Value {
    try args.fixarity(argv, 1);
    const count = try args.getInteger(argv, 0);
    const raw = abstracts.newBytes(&runs_at, @sizeOf(Runs));
    const runs: *Runs = @ptrCast(@alignCast(raw));
    runs.* = .{ .count = @intCast(count), .buffer = undefined };
    return wrap.fromAbstract(raw);
}

/// JOP_PUSH_ARRAY reads its operand one run at a time, so an abstract type
/// with a `chunk` callback splices where an array or a tuple does. Every case
/// is checked against a tuple holding the same elements.
///
/// The counts cross a run boundary, end on a short run and end on a full one.
/// The last case grows the stack, which happens before the first run is taken
/// rather than between two of them.
fn spliceReadsAnIndexedAbstract() void {
    const f = "(defn f [& xs] xs) ";
    expectEqual("(do " ++ f ++ "(f |(vmrun/runs 10)))", "(do " ++ f ++ "(f |[0 10 20 30 40 50 60 70 80 90]))");
    expectEqual("(do " ++ f ++ "(f |(vmrun/runs 9)))", "(do " ++ f ++ "(f |[0 10 20 30 40 50 60 70 80]))");
    expectEqual("(do " ++ f ++ "(f |(vmrun/runs 2)))", "(do " ++ f ++ "(f |[0 10]))");
    expectEqual("(do " ++ f ++ "(f |(vmrun/runs 0)))", "(do " ++ f ++ "(f |[]))");
    // Pushes before and after the splice keep their places.
    expectEqual("(do " ++ f ++ "(f :a |(vmrun/runs 4) :b))", "(do " ++ f ++ "(f :a |[0 10 20 30] :b))");
    // One value spliced twice, which is what the reused buffer is here for.
    expectEqual(
        "(do " ++ f ++ "(def v (vmrun/runs 4)) (f |v |v))",
        "(do " ++ f ++ "(f |[0 10 20 30] |[0 10 20 30]))",
    );
    // `apply` reaches the same opcode with its last argument.
    expectEqual("(apply + (vmrun/runs 10))", "450");
    expectEqual("(apply + 5 (vmrun/runs 4))", "65");
    // A splice long enough to grow the fiber's stack.
    expectEqual("(apply + (vmrun/runs 1000))", "(apply + (map #(* $ 10) (range 1000)))");
}

/// A type check whose set includes both array and tuple passes an abstract
/// with a `chunk` callback, and one naming only one of the two does not.
fn aTypeCheckPassesAnIndexedAbstract() void {
    expectEqual("((asm '{:arity 1 :bytecode [(tchck 0 :indexed) (ldi 1 7) (ret 1)]}) (vmrun/runs 2))", "7");
    expectEqual("((asm '{:arity 1 :bytecode [(tchck 0 (:number :indexed)) (ldi 1 7) (ret 1)]}) (vmrun/runs 2))", "7");
    // The refusal renders the abstract with its address, so only its start is
    // compared.
    expectEqual(
        "(string/has-prefix? \"expected array, got <vm-run/runs\" (last (protect ((asm '{:arity 1 :bytecode [(tchck 0 :array) (ret 0)]}) (vmrun/runs 2)))))",
        "true",
    );
}

/// `indexed?` answers true for an abstract with a `chunk` callback, so the
/// functions `boot.janet` writes over it read one.
///
/// Each expected result is written out. These functions reach `tuple/slice`
/// and `indexed?` for a tuple as well, so a result built from a tuple would
/// move with the subject.
fn theBootFunctionsReadAnIndexedAbstract() void {
    expectEqual("(indexed? (vmrun/runs 2))", "true");
    expectEqual("(indexed? 5)", "false");
    expectEqual("(indexed? \"ab\")", "false");
    // `take`, `drop` and their kin go through `slice`, which gives a vector.
    expectEqual("(take 2 (vmrun/runs 5))", "[0 10]");
    expectEqual("(take -2 (vmrun/runs 5))", "[30 40]");
    expectEqual("(drop 3 (vmrun/runs 5))", "[30 40]");
    expectEqual("(take-while #(< $ 25) (vmrun/runs 5))", "[0 10 20]");
    expectEqual("(drop-until #(> $ 25) (vmrun/runs 5))", "[30 40]");
    expectEqual("(partition 2 (vmrun/runs 5))", "![[0 10] [20 30] [40]]");
    expectEqual("(flatten [1 (vmrun/runs 4) 2])", "![1 0 10 20 30 2]");
    expectEqual("(match (vmrun/runs 2) [a b] (+ a b) _ :no)", "10");
    expectEqual("(match (vmrun/runs 3) [a b] (+ a b) _ :no)", "10");
}

/// A type with `chunk` and neither `get` nor `next` is read by key from its
/// runs: `get`, `in`, the destructuring opcode and `next`, and what is built
/// on them.
fn getAndNextAreDerivedFromTheRuns() void {
    expectEqual("(get (vmrun/runs 5) 4)", "40");
    expectEqual("(get (vmrun/runs 5) 5)", "nil");
    expectEqual("(get (vmrun/runs 5) -1)", "nil");
    expectEqual("(get (vmrun/runs 5) :x)", "nil");
    expectEqual("(get (vmrun/runs 5) 1.5)", "nil");
    expectEqual("(in (vmrun/runs 5) 3)", "30");
    expectEqual(
        "(string/has-prefix? \"key 5 not found in <vm-run/runs\" (last (protect (in (vmrun/runs 5) 5))))",
        "true",
    );
    // Destructuring reads through the get-index opcode.
    expectEqual("(do (def [a b c] (vmrun/runs 5)) [a b c])", "[0 10 20]");
    expectEqual("(do (def [a b] (vmrun/runs 1)) [a b])", "[0 nil]");
    expectEqual("(next (vmrun/runs 2) nil)", "0");
    expectEqual("(next (vmrun/runs 2) 0)", "1");
    expectEqual("(next (vmrun/runs 2) 1)", "nil");
    expectEqual("(next (vmrun/runs 0) nil)", "nil");
    expectEqual("(next (vmrun/runs 2) :x)", "nil");
    expectEqual("(keys (vmrun/runs 4))", "![0 1 2 3]");
    expectEqual("(map inc (vmrun/runs 4))", "![1 11 21 31]");
    expectEqual("(do (var acc 0) (each x (vmrun/runs 7) (+= acc x)) acc)", "210");
    // Two readers of one value, each copying an element out before the other
    // reads, which the reused buffer would expose otherwise.
    expectEqual("(do (def v (vmrun/runs 7)) (map + v v))", "![0 20 40 60 80 100 120]");
}

fn theCollectionConstructors() void {
    expectEqual("![1 2 3]", "![1 2 3]");
    expectEqual("[1 2 3]", "[1 2 3]");
    expectEqual("!{:a 1}", "!{:a 1}");
    expectEqual("{:a 1}", "{:a 1}");
    expectEqual("(string \"a\" 1 :b)", "\"a1b\"");
    expectEqual("(buffer \"a\" 1 :b)", "!\"a1b\"");
    // A tuple is `( )` and nothing else, and `[ ]` builds a vector through its
    // own opcode. `mkbtp` went with the bracket flag, so `mktup` is the only
    // tuple constructor the assembler can reach.
    expectEqual("(type '(1 2))", ":tuple");
    expectEqual("(type '[1 2])", ":vector");
    if (has_assembler) {
        expectEqual(
            "(type ((asm '{:arity 0 :constants [1]  :bytecode [(ldc 0 0) (push 0) (mkvec 1) (ret 1)]})))",
            ":vector",
        );
        expectEqual(
            "(type ((asm '{:arity 0 :constants [1]  :bytecode [(ldc 0 0) (push 0) (mktup 1) (ret 1)]})))",
            ":tuple",
        );
    }
}

/// The two constructors that reject an odd argument count do it at run time,
/// and the compiler counts literal arguments before they get there, so the
/// assembler is again the only route.
fn anOddConstructorArgumentCount() void {
    expectError(
        "((asm '{:arity 0 :bytecode [(ldi 0 1) (push 0) (mktab 0) (ret 0)]}))",
        "expected even number of arguments to table constructor, got 1",
    );
    expectError(
        "((asm '{:arity 0 :bytecode [(ldi 0 1) (push 0) (mkmap 0) (ret 0)]}))",
        "expected even number of arguments to map constructor, got 1",
    );
}

/// `JOP_SIGNAL` clamps its operand into the user range. The upper clamp is
/// reachable; the lower is not, because the assembler will not encode a
/// negative one-byte operand.
fn theSignalOpcode() void {
    var fiberv = eval(
        "(fiber/new (asm '{:arity 0 :constants [:payload]" ++
            "  :bytecode [(ldc 0 0) (sig 1 0 30) (ret 1)]}) :i0123456789)",
    );
    var resumed = resumeFiber(fiberv, wrap.fromNil());
    expect(resumed.signal == abi.Signal.user9);
    expect(harness.keywordIs(resumed.value, "payload"));

    fiberv = eval(
        "(fiber/new (asm '{:arity 0 :constants [:payload]" ++
            "  :bytecode [(ldc 0 0) (sig 1 0 5) (ret 1)]}) :i0123456789)",
    );
    resumed = resumeFiber(fiberv, wrap.fromNil());
    // The operand is the signal number, not the user index: 5 is USER1.
    expect(resumed.signal == abi.Signal.user1);
    expect(harness.keywordIs(resumed.value, "payload"));
}

/// `JOP_ERROR` returns the slot as an error signal without formatting it,
/// which is the precedent the whole return-rather-than-jump path was built on.
fn theErrorOpcode() void {
    const fiberv = eval("(fiber/new (fn [] (error [1 2])) :e)");
    const resumed = resumeFiber(fiberv, wrap.fromNil());
    expect(resumed.signal == abi.Signal.@"error");
    expect(harness.isIndexed(resumed.value));
    expect(harness.elems(resumed.value).len == 2);
}

/// `JOP_PROPAGATE` hands a child's status upward as the parent's signal, and
/// refuses a status above the user range with the only message in the loop
/// that takes a `%s` from a static table.
fn thePropagateOpcode() void {
    const fiberv = eval(
        "(do (def child (fiber/new (fn [] (yield :inner)) :y))" ++
            "    (resume child)" ++
            "    (fiber/new (fn [] (propagate :outer child)) :y))",
    );
    const resumed = resumeFiber(fiberv, wrap.fromNil());
    expect(resumed.signal == abi.Signal.yield);
    expect(harness.keywordIs(resumed.value, "outer"));

    // `user9` is the last status the check lets through, and the one `:await`
    // leaves. Propagating from it passes the signal up rather than refusing.
    const awaited = eval(
        "(do (def child (fiber/new (fn [] (signal :await :waiting)) :9))" ++
            "    (resume child)" ++
            "    (fiber/new (fn [] (propagate :outer child)) :9))",
    );
    const passed = resumeFiber(awaited, wrap.fromNil());
    expect(passed.signal == abi.Signal.user9);
    expect(harness.keywordIs(passed.value, "outer"));

    // Only `:new` and `:alive` sit above the user signals, so an unstarted
    // child is the reachable half of the check and a dead one propagates fine.
    expectError("(propagate :x (fiber/new (fn [] 1) :y))", "cannot propagate from fiber with status :new");
}

/// Five flags at the head of the loop decide what a resumed fiber does with
/// the value it was resumed with. Nothing else in the tree reads them.
fn aResumedFiberReceivesItsValue() void {
    const fiberv = eval("(fiber/new (fn [] [(yield 1) (yield 2)]) :y)");

    var resumed = resumeFiber(fiberv, wrap.fromNil());
    expect(resumed.signal == abi.Signal.yield);
    expect(harness.integerIs(resumed.value, 1));

    resumed = resumeFiber(fiberv, value.fromBytes("first", .keyword));
    expect(resumed.signal == abi.Signal.yield);
    expect(harness.integerIs(resumed.value, 2));

    resumed = resumeFiber(fiberv, value.fromBytes("second", .keyword));
    expect(resumed.signal == abi.Signal.ok);
    expect(harness.isIndexed(resumed.value));
    expect(harness.keywordIs(harness.elems(resumed.value)[0], "first"));
    expect(harness.keywordIs(harness.elems(resumed.value)[1], "second"));
}

/// A fiber that has not started yet takes its resume value as its first
/// argument rather than into a slot, which happens above the loop, but the
/// loop still has to skip the instruction it would otherwise re-run.
fn aNewFiberReceivesItsValueAsAnArgument() void {
    const fiberv = eval("(fiber/new (fn [x] [:got x]) :y)");
    const resumed = resumeFiber(fiberv, value.fromBytes("in", .keyword));
    expect(resumed.signal == abi.Signal.ok);
    expect(harness.keywordIs(harness.elems(resumed.value)[1], "in"));

    // With no fixed parameter and a rest parameter, the value is the one
    // element of the rest tuple. Arity zero is the edge between the two arms.
    const variadic = eval("(fiber/new (fn [& xs] xs) :y)");
    const rest = resumeFiber(variadic, value.fromBytes("in", .keyword));
    expect(rest.signal == abi.Signal.ok);
    expect(harness.isIndexed(rest.value));
    expect(harness.elems(rest.value).len == 1);
    expect(harness.keywordIs(harness.elems(rest.value)[0], "in"));
}

/// After a raise the fiber has `FiberFlags.did_raise` set, which the head of
/// the loop reads to pop a C frame and to turn a raise at a tail call into an
/// implicit return. The signal-injection path sets it too, and travels in
/// `gc.flags` rather than in `flags`.
fn aFiberResumedAfterARaise() void {
    const fiberv = eval("(fiber/new (fn [] (error :boom)) :ey)");
    const resumed = resumeFiber(fiberv, wrap.fromNil());
    expect(resumed.signal == abi.Signal.@"error");
    expect(harness.keywordIs(resumed.value, "boom"));
    // And is refused a second time, by `checkCanResume` rather than by the
    // loop, which is the boundary `vm_entry` owns.
    expectError(
        "(do (def f (fiber/new (fn [] (error :boom)) :ey)) (resume f) (resume f))",
        "cannot resume fiber with status :error",
    );
}

/// A raise inside a cfunction leaves a C frame on the fiber, which the head of
/// the loop pops before it can restore anything.
fn aFiberResumedAfterARaiseInsideACfunction() void {
    const fiberv = eval("(fiber/new (fn [] (yield (length 5))) :ey)");
    const resumed = resumeFiber(fiberv, wrap.fromNil());
    expect(resumed.signal == abi.Signal.@"error");
    expect(harness.isType(resumed.value, repr.Tag.string));
}

/// An injected signal is delivered instead of resuming, and is read back out
/// of `gc.flags` where `signal.signalInject` put it.
fn anInjectedSignal() void {
    const fiberv = eval("(fiber/new (fn [] (yield 1) :never) :y)");
    var resumed = resumeFiber(fiberv, wrap.fromNil());
    expect(resumed.signal == abi.Signal.yield);

    signal_core.signalInject(wrap.toFiber(fiberv), abi.Signal.user3);
    resumed = resumeFiber(fiberv, value.fromBytes("injected", .keyword));
    expect(resumed.signal == abi.Signal.user3);
    expect(harness.keywordIs(resumed.value, "injected"));

    // A resumable signal delivered the same way is delivered once, and the
    // resume after it runs the fiber on from its `yield`.
    const again = eval("(fiber/new (fn [] (yield 1) :ran-on) :y)");
    resumed = resumeFiber(again, wrap.fromNil());
    expect(resumed.signal == abi.Signal.yield);
    signal_core.signalInject(wrap.toFiber(again), abi.Signal.user5);
    resumed = resumeFiber(again, value.fromBytes("injected", .keyword));
    expect(resumed.signal == abi.Signal.user5);
    resumed = resumeFiber(again, value.fromBytes("resumed", .keyword));
    expect(resumed.signal == abi.Signal.ok);
    expect(harness.keywordIs(resumed.value, "ran-on"));
}

/// An opcode the loop does not recognise returns `abi.Signal.debug` and sets
/// three flags, so that the resume re-runs the instruction with the breakpoint
/// bit masked off. Bit 7 of the instruction word is how a breakpoint is set,
/// and `vm_entry.step` sets a temporary one.
fn aBreakpointReachesTheUnknownOpcodeArm() raise.Error!void {
    var out = wrap.fromNil();
    const fiberv = eval("(fiber/new (fn [] (+ 1 2) (+ 3 4) :done) :dy)");
    const fiber = wrap.toFiber(fiberv);
    var sig = try vm_entry.step(fiber, wrap.fromNil(), &out);
    expect(sig == abi.Signal.debug);
    expect(fibers.status(fiber) == fibers.FiberStatus.debug);
    // Stepping again makes progress rather than repeating, which is what the
    // RESUME_NO_SKIP and RESUME_NO_USEVAL flags are for.
    sig = try vm_entry.step(fiber, wrap.fromNil(), &out);
    expect(sig == abi.Signal.debug);
    // And letting it run finishes.
    const resumed = vm_entry.continueFiber(fiber, wrap.fromNil());
    expect(resumed.signal == abi.Signal.ok);
    expect(harness.keywordIs(resumed.value, "done"));
}

/// `vm_entry.step`'s breakpoints are temporary: it restores the instruction
/// words on the way out, so the resume never re-reads one with bit 7 set. A
/// breakpoint set with `debug/fbreak` stays, and resuming from it is the only
/// state in which the mask the loop applies to its first opcode does anything.
fn aPermanentBreakpoint() void {
    const fiberv = eval(
        "(do (defn g [x] (+ x 1))" ++
            "    (def f (fiber/new (fn [] (g 1) (g 2) :done) :dy))" ++
            "    (debug/fbreak g 0) f)",
    );
    const fiber = wrap.toFiber(fiberv);
    var resumed = vm_entry.continueFiber(fiber, wrap.fromNil());
    expect(resumed.signal == abi.Signal.debug);
    expect(fiber.flags.breakpoint);
    // Resuming re-runs the breakpointed instruction with bit 7 masked off, so
    // the second call reaches the same breakpoint rather than the loop
    // reporting the same one forever.
    resumed = vm_entry.continueFiber(fiber, wrap.fromNil());
    expect(resumed.signal == abi.Signal.debug);
    resumed = vm_entry.continueFiber(fiber, wrap.fromNil());
    expect(resumed.signal == abi.Signal.ok);
    expect(harness.keywordIs(resumed.value, "done"));
    // The resume clears the flag, so a later resume does not mask the first
    // instruction it runs.
    expect(!fiber.flags.breakpoint);
}

/// Opcodes with no message and no signal of their own, grouped because each is
/// one line and a missing one is invisible.
fn theRemainingOpcodes() void {
    // Jumps, in both polarities, and both nil tests.
    expectEqual("(do (defn f [x] (if x :t :f)) [(f true) (f false) (f nil)])", "[:t :f :f]");
    expectEqual("(do (defn f [x] (if (nil? x) :n :s)) [(f nil) (f false)])", "[:n :s]");
    // Upvalues, read and written, on the stack and off it.
    expectEqual("(do (var v 0) (defn f [] (set v (+ v 1)) v) [(f) (f) v])", "[1 2 2]");
    // A closure over a frame captured lazily.
    expectEqual("(do (defn outer [x] (fn [] x)) ((outer 9)))", "9");
    // Self reference, which is how a named function calls itself.
    expectEqual("(do (defn fact [n] (if (< n 2) 1 (* n (fact (- n 1))))) (fact 5))", "120");
    // Keyed and indexed access, and their in-place writers.
    expectEqual("(do (def t !{:a 1}) [(get t :a) (get t :b) (in [10 20] 1)])", "[1 nil 20]");
    expectEqual("(do (def a ![1 2]) (put a 0 :x) a)", "![:x 2]");
    expectEqual("(do (def t !{}) (put t :k :v) t)", "!{:k :v}");
    expectEqual("(length \"abcd\")", "4");
    // `next`, which restores all three registers rather than just the stack.
    expectEqual("(do (def t !{:a 1}) (next t nil))", ":a");
    expectEqual("(seq [[k v] :pairs {:a 1}] [k v])", "![[:a 1]]");
    // `next` over a fiber resumes it, and the opcode asks for the
    // interpreter's handling of a signal the child's mask does not catch:
    // re-signalled, so an escaping yield stays a yield. Called from C it would
    // become an error instead, which is the same function's other argument.
    expectEqual(
        "(do (def child (fiber/new (fn [] (yield 1)) :d))" ++
            "    (def outer (fiber/new (fn [] (next child nil)) :yd))" ++
            "    [(resume outer) (fiber/status outer)])",
        "[1 :pending]",
    );
    // Constants, integers, booleans and nil.
    expectEqual("(do (defn f [] [nil true false 7 :kw]) (f))", "[nil true false 7 :kw]");
    // The two opcodes nothing else in this tree reaches, because the compiler
    // cannot emit either. A count of every dispatch made by thirty-five suites
    // and fifty-five contracts found exactly these two at zero; the assembler
    // is the only way to execute them at all.
    //
    // JOP_NOOP is written by the dead-write optimizer and then deleted by
    // no-op removal before the function is ever run, so no compiled function
    // contains one. JOP_MAKE_STRING has no emitter anywhere in the compiler:
    // `(string ...)` compiles to a call of the `string` cfunction.
    if (has_assembler) {
        expectEqual("((asm '{:arity 0 :bytecode [(noop) (ldi 0 7) (noop) (ret 0)]}))", "7");
        expectEqual(
            "((asm '{:arity 0 :constants [\"ab\" :cd]" ++
                "  :bytecode [(ldc 0 0) (push 0) (ldc 0 1) (push 0)" ++
                "             (mkstr 0) (ret 0)]}))",
            "\"abcd\"",
        );
    }

    // Register moves, near and far.
    expectEqual("(do (defn f [a b c d e g h] [a h]) (f 1 2 3 4 5 6 7))", "[1 7]");
    // Resume and cancel of a child fiber.
    expectEqual("(do (def c (fiber/new (fn [] (yield 1) 2) :y)) [(resume c) (resume c)])", "[1 2]");
    expectEqual(
        "(do (def c (fiber/new (fn [] (yield 1)) :ye))    (resume c) (try (cancel c :stop) ([e] e)))",
        ":stop",
    );
    // A cancel whose error the child does not trap goes on up through the
    // fiber that cancelled, the same as a resume's.
    expectError("(do (def c (fiber/new (fn [] (yield 1)) :y)) (resume c) (cancel c \"boom\"))", "boom");
}

/// A fiber marked as a task is refused by both opcodes, each with its own
/// wording. `vm_entry` pins the two messages through the entry points; these
/// are the opcodes' own arguments to the same check.
fn theOpcodesRefuseARootFiber() void {
    const rooted = eval("(fiber/new (fn [] 1))");
    harness.gcSetBits(&wrap.toFiber(rooted).gc.flags, constants.JANET_FIBER_FLAG_ROOT);
    registry.def(test_env.?, "vmrun-rooted", rooted, null);
    expectError(
        "(resume vmrun-rooted)",
        if (harness.has_ev) "cannot resume root fiber, use ev/go" else "cannot resume root fiber",
    );
    expectError(
        "(cancel vmrun-rooted \"x\")",
        if (harness.has_ev) "cannot cancel root fiber, use ev/cancel" else "cannot cancel root fiber",
    );
}

/// Resume with `auto_suspend` held at one for the length of the resume.
fn resumeInterrupted(fiberv: repr.Value) vm_entry.Resumed {
    harness.vm().auto_suspend = 1;
    defer harness.vm().auto_suspend = 0;
    return resumeFiber(fiberv, wrap.fromNil());
}

/// With `auto_suspend` set, an interrupting build leaves the loop with
/// `Signal.interrupt` at every call, tail call and resume, and at a taken jump
/// whose offset is zero or negative. Resuming the fiber runs the interrupted
/// instruction again and discards the value it is resumed with.
fn anInterrupt() void {
    if (!has_interrupt) return;

    // Each of these fibers stops first at the call, the tail call or the
    // resume, and would otherwise finish.
    const first_stops = [_][*:0]const u8{
        "(do (defn g [] 2) (fiber/new (fn [] (g) 1)))",
        "(do (defn g [] 2) (fiber/new (fn [] (g))))",
        "(do (def c (fiber/new (fn [] 2))) (fiber/new (fn [] (resume c) 1)))",
    };
    for (first_stops) |source| {
        expect(resumeInterrupted(eval(source)).signal == abi.Signal.interrupt);
    }

    if (!has_assembler) return;

    // A loop stopped at its backward jump runs on from the jump. The resume
    // value must not land in the condition register and the jump must not be
    // skipped; either ends the loop after one pass.
    const loop = eval(
        "(fiber/new (asm '{:arity 0 :bytecode [(ldi 0 0) (ldi 1 3) :top (addim 0 0 1)" ++
            " (lt 2 0 1) (jmpif 2 :top) (ret 0)]}))",
    );
    expect(resumeInterrupted(loop).signal == abi.Signal.interrupt);
    const resumed = resumeFiber(loop, wrap.fromNil());
    expect(resumed.signal == abi.Signal.ok);
    expect(harness.integerIs(resumed.value, 3));

    // A jump to itself is a loop with nothing in it, and an interrupt is the
    // only way out. Each conditional form is taken here.
    const self_jumps = [_][*:0]const u8{
        "(fiber/new (asm '{:arity 0 :bytecode [(ldt 0) :here (jmpif 0 :here) (retn)]}))",
        "(fiber/new (asm '{:arity 0 :bytecode [(ldf 0) :here (jmpno 0 :here) (retn)]}))",
        "(fiber/new (asm '{:arity 0 :bytecode [(ldn 0) :here (jmpni 0 :here) (retn)]}))",
        "(fiber/new (asm '{:arity 0 :bytecode [(ldt 0) :here (jmpnn 0 :here) (retn)]}))",
    };
    for (self_jumps) |source| {
        expect(resumeInterrupted(eval(source)).signal == abi.Signal.interrupt);
    }
}

fn yieldingPut(_: *anyopaque, _: repr.Value, _: repr.Value) raise.Error!void {
    return raise.signal(abi.Signal.yield, value.fromBytes("paused", .keyword));
}

/// `.put` and `.put_index` mark the fiber so that a resume does not write its
/// value into the instruction's first register, which for these two holds the
/// container rather than a result.
fn aSuspendedPutKeepsItsContainer() void {
    const container = wrap.fromAbstract(abstracts.newBytes(&at_yielding_put, 1));
    gc_alloc.gcroot(container);
    const sources = [_][*:0]const u8{
        "(fiber/new (fn [o] (put o :k :v) o) :y)",
        "(fiber/new (fn [o] (put o 0 :v) o) :y)",
    };
    for (sources) |source| {
        const fiberv = eval(source);
        var resumed = resumeFiber(fiberv, container);
        expect(resumed.signal == abi.Signal.yield);
        expect(harness.keywordIs(resumed.value, "paused"));
        // The yield was raised, not returned, and the resume after it clears
        // the flag that says so.
        expect(wrap.toFiber(fiberv).flags.did_raise);
        resumed = resumeFiber(fiberv, value.fromBytes("resumed", .keyword));
        expect(resumed.signal == abi.Signal.ok);
        expect(harness.equals(resumed.value, container));
        expect(!wrap.toFiber(fiberv).flags.did_raise);
    }
    _ = gc_alloc.gcunroot(container);
}

/// The first instruction in `func` whose opcode is `operation`.
fn instructionOf(func: *functions.Function, operation: constants.Opcode) *u32 {
    for (func.def.?.instructions()) |*word| {
        if (word.* & 0xFF == harness.op(operation)) return word;
    }
    @panic("vm_run: the function has no such instruction");
}

/// The error `func` raises when it runs on a fiber of its own.
fn raisedByRunning(func: *functions.Function) repr.Value {
    const fiber = fibers.new(func, 64, &.{}) catch unreachable;
    gc_alloc.gcroot(wrap.fromFiber(fiber));
    const resumed = vm_entry.continueFiber(fiber, wrap.fromNil());
    expect(resumed.signal == abi.Signal.@"error");
    gc_alloc.gcroot(resumed.value);
    return resumed.value;
}

/// Each operand bound at the first index past the end of its table, which is
/// where `<` and `<=` part.
fn anOperandPastItsTable() void {
    // `.load_constant` in a function with one constant, asked for index 1.
    var func = wrap.toFunction(eval("(fn [] :only)"));
    var word = instructionOf(func, .load_constant);
    word.* = (word.* & 0xFFFF) | (@as(u32, @intCast(func.def.?.constants_length)) << 16);
    expect(harness.stringValueIs(raisedByRunning(func), "invalid constant"));

    // `.closure` in a function with one nested definition, asked for index 1.
    func = wrap.toFunction(eval("(fn [] (fn [] 1))"));
    word = instructionOf(func, .closure);
    word.* = (word.* & 0xFFFF) | (@as(u32, @intCast(func.def.?.defs_length)) << 16);
    expect(harness.stringValueIs(raisedByRunning(func), "invalid funcdef"));

    // `.load_upvalue` with the environment index one past the function's
    // environments, and then with the value index one past the environment's
    // values.
    func = wrap.toFunction(eval("((fn [] (var x 1) (fn [] x)))"));
    word = instructionOf(func, .load_upvalue);
    word.* = (word.* & ~@as(u32, 0xFF << 16)) | (@as(u32, @intCast(func.def.?.environments_length)) << 16);
    expect(harness.stringValueIs(raisedByRunning(func), "invalid upvalue environment"));

    func = wrap.toFunction(eval("((fn [] (var x 1) (fn [] x)))"));
    word = instructionOf(func, .load_upvalue);
    const env = functions.envsOf(func)[0].?;
    word.* = (word.* & 0x00FF_FFFF) | (@as(u32, @intCast(env.length)) << 24);
    expect(harness.stringValueIs(raisedByRunning(func), "invalid upvalue index"));

    // `.closure`'s inherited environment at the same edge. An index equal to
    // the parent's environment count names the parent's own frame, as -1
    // does, so the closure it builds reads that frame's value.
    func = wrap.toFunction(eval("(fn [] (var x 5) (fn [] x))"));
    func.def.?.subdefs()[0].environmentIndices()[0] = @intCast(func.def.?.environments_length);
    const made = vm_entry.pcall(func, &.{}, null);
    expect(made.signal == abi.Signal.ok);
    gc_alloc.gcroot(made.value);
    const read = vm_entry.pcall(wrap.toFunction(made.value), &.{}, null);
    expect(read.signal == abi.Signal.ok);
    expect(harness.integerIs(read.value, 5));
}

/// The collector runs when the bytes allocated since the last collection
/// reach the interval, not only when they pass it. The first cfunction sets
/// the interval to exactly that count and allocates nothing, the call opcode
/// checks the two on its return, and the second cfunction reads the count.
fn theCollectionThresholdIsInclusive() void {
    const saved = harness.vm().gc.interval;
    const after = eval("(do (vmrun/arm-collection) (vmrun/allocated))");
    harness.vm().gc.interval = saved;
    expect(armed_at > 0);
    expect(harness.integerIs(after, 0));
}

fn cfunArmCollection(argv: []repr.Value) raise.Error!repr.Value {
    _ = argv;
    armed_at = harness.vm().gc.next_collection;
    harness.vm().gc.interval = armed_at;
    return wrap.fromNil();
}

fn cfunAllocated(argv: []repr.Value) raise.Error!repr.Value {
    _ = argv;
    return wrap.fromNumber(@floatFromInt(harness.vm().gc.next_collection));
}

const cfuns = [_]abi.Reg{
    .{ .name = "vmrun/arm-collection", .cfun = raise.stored(&cfunArmCollection), .documentation = null },
    .{ .name = "vmrun/allocated", .cfun = raise.stored(&cfunAllocated), .documentation = null },
    .{ .name = "vmrun/runs", .cfun = raise.stored(&cfunRuns), .documentation = null },
};

// ==========================================================================
// Entry
// ==========================================================================

fn body() raise.Error!void {
    test_env = harness.coreEnv();
    registry.cfuns(test_env, null, &cfuns);
    has_assembler = harness.coreOptional("asm") != null;

    arithmeticTakesTheNumericPath();
    aBitwiseOperandOutOfRange();
    aBitwiseRightOperandOutOfRange();
    theOperatorFallbacks();

    comparison();

    theCallArityMessage();
    callingACfunction();
    callingANonFunction();
    stackOverflow();
    theStackLimitIsInclusive();

    theTypeAssertions();
    spliceReadsAnIndexedAbstract();
    if (has_assembler) aTypeCheckPassesAnIndexedAbstract();
    theBootFunctionsReadAnIndexedAbstract();
    getAndNextAreDerivedFromTheRuns();
    theCollectionConstructors();
    if (has_assembler) {
        anOddConstructorArgumentCount();
        theSignalOpcode();
    }
    theErrorOpcode();
    thePropagateOpcode();

    aResumedFiberReceivesItsValue();
    aNewFiberReceivesItsValueAsAnArgument();
    aFiberResumedAfterARaise();
    aFiberResumedAfterARaiseInsideACfunction();
    anInjectedSignal();

    try aBreakpointReachesTheUnknownOpcodeArm();
    aPermanentBreakpoint();
    theRemainingOpcodes();

    theOpcodesRefuseARootFiber();
    anInterrupt();
    aSuspendedPutKeepsItsContainer();
    anOperandPastItsTable();
    theCollectionThresholdIsInclusive();
}

pub fn run() void {
    harness.init();
    body() catch @panic("vm_run: an operation raised unexpectedly");
    vm_lifecycle.deinit();
}
