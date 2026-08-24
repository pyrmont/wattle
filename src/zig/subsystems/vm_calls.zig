//! The callee side of the interpreter: everything `run_vm` delegates to when
//! the thing it is about to call is not a plain Janet function, plus the three
//! loops that fill a collection from the fiber stack. This is Part 2 of Phase
//! 9 and it takes eleven functions from `src/core/vm.c` — `janet_method_invoke`
//! and the five helpers around it, the three `fill_*` loops, and `janet_mcall`,
//! which is the same lookup-and-invoke pair wearing a public name.
//!
//! What is deliberately *not* here is `run_vm` itself, `janet_call`,
//! `janet_step`, and everything holding a `jmp_buf`. Part 3 takes the loop and
//! Part 4 the entry points.
//!
//! ## Why this is one increment
//!
//! Phase 8's first rule says to split by data structure rather than by call
//! graph, and an interpreter has no data structures to split by. The property
//! that groups these eleven instead is that each one answers the same question
//! — *given a callee that is not a function, what does calling it mean* — and
//! that none of them touches `run_vm`'s three registers. They can therefore
//! move a full increment before the loop does, which is the point: Part 3 has
//! enough to do without also porting method dispatch.
//!
//! `method_to_fun` is the one function in the group with no seam of its own. It
//! is `janet_get` with its arguments swapped, both of its callers are here, and
//! a symbol whose whole body is a reordering is a symbol the C build does not
//! need to keep.
//!
//! ## The seam, and five renamed symbols
//!
//! Ten of the eleven were `static` in `vm.c`. Nine of those need external
//! linkage and a declaration both sides can see — the same shape
//! `janet_free_all_scratch` took in Phase 8 Part 3, and it lives in `state.h`
//! beside `janet_trace_frame` and the argument-fault layer. `method_to_fun` is
//! the tenth and needs neither, for the reason above.
//!
//! Five had names too general to put in a library's symbol table: `call_nonfn`,
//! `resolve_method`, and the three `fill_*` loops are now `janet_call_nonfn`,
//! `janet_resolve_method`, `janet_fill_table`, `janet_fill_struct` and
//! `janet_fill_string`. The C originals are renamed with them, so `run_vm`'s
//! call sites read identically under either selector. The other five keep the
//! names they had.
//!
//! Each of the nine is exported with `.visibility = .hidden`, which is what the
//! C build's `-fvisibility=hidden` already gives them. That keeps the two
//! selectors' dynamic symbol sets identical rather than adding nine more entries
//! to the list of Zig exports that widen `libjanet.dylib`; `janet_mcall` is
//! `JANET_API` and is exported normally.
//!
//! ## The file is jump-transparent, and there is nothing left when it is not
//!
//! Every function here raises, and most of them do nothing else. They call
//! third-party cfunctions, an abstract type's `call`, `janet_call` into the
//! interpreter, `janet_get`, `janet_in`, `janet_table_put`, `janet_struct_put`
//! and `janet_to_string_b` — every one of which can panic, several through a
//! callback a native module supplied. Under SPIKE-8's rule they are called
//! directly, in the shape of the C original, and a signal from one jumps
//! straight through the Zig frame that invoked it. `build.zig` enforces that no
//! `defer` exists here to be skipped.
//!
//! `janet_panicf` is called directly too, as `value_access.zig` established:
//! panicking is these functions' contract, so there is nothing for a fault code
//! to buy. Seven messages cross the C variadic ABI with a `Janet` in a `%v` or
//! a `const char *` in a `%s`, and `test/vm_calls.c` asserts every one of them
//! byte for byte under both selectors and both value layouts.
//!
//! ## This increment ended no scope, and the scopes are now gone anyway
//!
//! Phase 7's first rule: a port ends a scope only when it removes the *raise*,
//! not when it moves the *work*. Under `-Dcall-trampoline=true`, `run_vm`
//! wrapped `janet_mcall`, `janet_binop_call`, `janet_unary_call`,
//! `janet_resolve_method`, `janet_call_nonfn` and the three fills in a
//! `scoped_*` setjmp, and it had to: these functions raise, and `run_vm` was
//! still C. Phase 10 Part 17e removed the last of those callees when each
//! started returning its raise, and the hinge spent the selector with the
//! `setjmp` it was the last configuration to compile.

const std = @import("std");
const abi = @import("abi");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");
const c = abi.c;
const printer = @import("printer.zig");
const access = @import("access.zig");
const vm_entry = @import("vm_entry.zig");
const abstract_type = @import("abstract_type.zig");

/// A sign-preserving widening, matching C's `int32_t` to `size_t` conversion
/// in `fiber->data + fiber->stacktop`. The two operands are fiber stack
/// indices the fiber itself maintains, so neither is negative in practice.
inline fn asSize(n: i32) usize {
    return @bitCast(@as(isize, n));
}

inline fn isNil(x: c.Janet) bool {
    return c.janet_checktype(x, c.JANET_NIL) != 0;
}

// -------------------------------------------------------------- invocation

/// The arity check and indexed access shared by `janet_method_invoke`'s last
/// two arms. `method_is_ds` picks which operand is the data structure, which is
/// the only thing that differs between them.
///
/// `argv` is passed rather than `argv[0]`, and that ordering is load-bearing:
/// the C reads `argv[0]` only after the arity check has passed, so a
/// zero-argument call must not touch it. Reading it eagerly would be a read of
/// whatever the previous frame left in that stack slot.
inline fn invokeIndexed(method: c.Janet, argc: i32, argv: [*c]c.Janet, method_is_ds: bool) raise.Error!c.Janet {
    if (argc != 1) {
        return pp_format.panicf("%v called with %d arguments, possibly expected 1", .{ method, argc });
    }
    return if (method_is_ds) try access.in(method, argv[0]) else try access.in(argv[0], method);
}

/// `janet_method_invoke`. Calls a value that has already been resolved to a
/// callee, dispatching on what kind of thing it turned out to be.
///
/// The C original reaches its indexed arm two ways: by falling out of the
/// `JANET_ABSTRACT` case when the abstract type has no `call` callback, and by
/// listing the six indexable types beside it. Zig has no fallthrough, so the
/// abstract arm calls `invokeIndexed` itself. The order of operations is
/// unchanged — `at->call` is consulted first, and only its absence reaches the
/// arity check.
///
/// The default arm is the one that reverses the operands: calling a keyword
/// looks the *keyword* up in its argument, which is what makes `(:key struct)`
/// work, while calling a table looks the *argument* up in the table.
pub fn methodInvoke(method: c.Janet, argc: i32, argv: [*c]c.Janet) raise.Error!c.Janet {
    switch (c.janet_type(method)) {
        c.JANET_CFUNCTION => return raise.cfunction(c.janet_unwrap_cfunction(method))(argc, argv),
        c.JANET_FUNCTION => {
            const fun = c.janet_unwrap_function(method);
            return try vm_entry.callImpl(fun, argc, argv);
        },
        c.JANET_ABSTRACT => {
            const abst = c.janet_unwrap_abstract(method);
            const at = abstract_type.ofAbstract(abst);
            if (at.call) |call| return try call(abst, argc, argv);
            return try invokeIndexed(method, argc, argv, true);
        },
        c.JANET_STRING,
        c.JANET_BUFFER,
        c.JANET_TABLE,
        c.JANET_STRUCT,
        c.JANET_ARRAY,
        c.JANET_TUPLE,
        => return try invokeIndexed(method, argc, argv, true),
        else => return try invokeIndexed(method, argc, argv, false),
    }
}

/// `call_nonfn`, renamed. The `JOP_CALL` and `JOP_TAILCALL` path for a callee
/// that is not a `JanetFunction`, with the arguments already pushed onto the
/// fiber stack.
///
/// It resets `stacktop` to `stackstart` *before* invoking, so the callee sees
/// an unpushed stack and the arguments it reads live above the new top. That is
/// not tidiness: `janet_method_invoke` can reach `janet_call`, which pushes a
/// frame of its own, and it would push it over these arguments if the top were
/// still where the caller left it.
pub fn callNonfn(fiber: [*c]c.JanetFiber, callee: c.Janet) raise.Error!c.Janet {
    const argc = fiber.*.stacktop - fiber.*.stackstart;
    fiber.*.stacktop = fiber.*.stackstart;
    return methodInvoke(callee, argc, fiber.*.data + asSize(fiber.*.stacktop));
}

/// `method_to_fun`. Kept as a Zig-private inline rather than a symbol: it is
/// `janet_get` with its operands swapped, and both of its callers are here.
///
/// Raising, since Phase 11 Part 15. It reached `janet_get` — the C face, which
/// is `raise.panicking` over `access.get` — from inside a chain every one of
/// whose callers is `raise.Raising`, so an abstract's `get` callback refusing
/// became a report nobody consumed. `(+ (int/s64 1) {})` killed the process
/// instead of raising a catchable error, because the binop fallback looks
/// `:r+` up on the right operand and that lookup is this function.
inline fn methodToFun(method: c.Janet, obj: c.Janet) raise.Raising(c.Janet) {
    return access.get(obj, method);
}

/// `resolve_method`, renamed. Turns the keyword of a method call into the
/// callee it names, reading the receiver from the bottom of the pushed
/// arguments.
///
/// The zero-argument branch cannot be reached from Janet source — the compiler
/// rejects a method call with no receiver outright — so `asm` is the only route
/// to it, and `test/vm_calls.c` takes that route.
pub fn resolveMethod(name: c.Janet, fiber: [*c]c.JanetFiber) raise.Error!c.Janet {
    const argc = fiber.*.stacktop - fiber.*.stackstart;
    if (argc < 1) {
        return pp_format.panicf("method call (%v) takes at least 1 argument, got 0", .{name});
    }
    const receiver = fiber.*.data[asSize(fiber.*.stackstart)];
    const callee = try methodToFun(name, receiver);
    if (isNil(callee)) {
        return pp_format.panicf("unknown method %v invoked on %v", .{ name, receiver });
    }
    return callee;
}

/// `janet_method_lookup`. Looks a method up by C string, which is how the
/// operator fallbacks and `janet_mcall` name theirs.
///
/// `janet_ckeywordv` interns the name on every call. The C original does the
/// same, and the symbol cache makes the second and later calls a lookup rather
/// than an allocation.
///
/// The `callconv(.c)` this carried was a translation artefact: nothing exports
/// it and nothing takes its address, so `janet_method_lookup` has not been a
/// symbol since the seam closed. It went with the conversion above, because a
/// C calling convention cannot carry an error union.
pub fn methodLookup(x: c.Janet, name: [*c]const u8) raise.Raising(c.Janet) {
    return methodToFun(c.janet_ckeywordv(name), x);
}

/// `janet_unary_call`. The operator fallback for a one-operand opcode whose
/// operand is not a number — `JOP_BNOT` is the only one that reaches it.
pub fn unaryCall(method: [*c]const u8, arg: c.Janet) raise.Error!c.Janet {
    const m = try methodLookup(arg, method);
    if (isNil(m)) {
        return pp_format.panicf("could not find method :%s for %v", .{ method, arg });
    }
    var argv = [_]c.Janet{arg};
    return methodInvoke(m, 1, &argv);
}

/// `janet_binop_call`. The operator fallback for a two-operand opcode where at
/// least one operand is not a number: `(+ x y)` on a non-number tries `:+` on
/// the left operand and then `:r+` on the right.
///
/// The right-hand attempt swaps the arguments, so a `:r+` method receives its
/// own receiver first. Both `argv` arrays are built before the nil check the
/// way the C does, which matters only in that the panic path never reads them.
pub fn binopCall(lmethod: [*c]const u8, rmethod: [*c]const u8, lhs: c.Janet, rhs: c.Janet) raise.Error!c.Janet {
    const lm = try methodLookup(lhs, lmethod);
    if (isNil(lm)) {
        const lr = try methodLookup(rhs, rmethod);
        var argv = [_]c.Janet{ rhs, lhs };
        if (isNil(lr)) {
            return pp_format.panicf(
                "could not find method :%s for %v or :%s for %v",
                .{ lmethod, lhs, rmethod, rhs },
            );
        }
        return methodInvoke(lr, 2, &argv);
    } else {
        var argv = [_]c.Janet{ lhs, rhs };
        return methodInvoke(lm, 2, &argv);
    }
}

/// `janet_mcall`. The public entry for calling a method by name, and the one
/// function here that was never `static`. `value.c` calls it for `:length` on
/// an abstract type, and `run_vm` reaches it from the immediate-operand
/// arithmetic opcodes.
pub fn mcall(name: [*c]const u8, argc: i32, argv: [*c]c.Janet) raise.Error!c.Janet {
    if (argc < 1) {
        return pp_format.panicf("method :%s expected at least 1 argument", .{name});
    }
    const method = try methodLookup(argv[0], name);
    if (isNil(method)) {
        return pp_format.panicf("could not find method :%s for %v", .{ name, argv[0] });
    }
    return methodInvoke(method, argc, argv);
}

// ------------------------------------------------------------- fill loops

/// `fill_table`, renamed. `JOP_MAKE_TABLE` over a run of key/value pairs on the
/// fiber stack.
///
/// `janet_table_put` hashes and compares every key on the way in, so an
/// abstract key with a `hash` or `compare` callback can raise from inside this
/// loop, or run the collector while the table being filled is unrooted.
/// `FOUND.md` has the second of those; it predates the port and is unaffected
/// by it.
pub fn fillTable(table: [*c]c.JanetTable, mem: [*c]const c.Janet, count: i32) callconv(.c) void {
    var i: i32 = 0;
    while (i < count) : (i += 2) {
        c.janet_table_put(table, mem[asSize(i)], mem[asSize(i + 1)]);
    }
}

/// `fill_struct`, renamed. `JOP_MAKE_STRUCT`, over a struct still under
/// construction: `janet_struct_put` writes into the buckets `janet_struct_begin`
/// allocated, and the caller calls `janet_struct_end` afterwards.
pub fn fillStruct(st: [*c]c.JanetKV, mem: [*c]const c.Janet, count: i32) callconv(.c) void {
    var i: i32 = 0;
    while (i < count) : (i += 2) {
        c.janet_struct_put(st, mem[asSize(i)], mem[asSize(i + 1)]);
    }
}

/// `fill_string`, renamed. `JOP_MAKE_STRING` and `JOP_MAKE_BUFFER`, which
/// stringify each element in turn.
///
/// This is the loop that reaches an abstract type's `tostring` callback, and
/// `janet_to_string_b` can also raise `buffer overflow` from `janet_buffer_ensure`
/// with no callback involved at all. `JOP_MAKE_STRING`'s scratch buffer is
/// `janet_malloc`ed and invisible to the collector, so a raise from here leaks
/// it — recorded in `FOUND.md`, reproduced rather than repaired, and the reason
/// the trampoline build takes one scope around this loop rather than one per
/// element.
/// **This raises, and it used to be reached through a face that did not.**
/// Phase 11 Part 12: `janet_fill_string` was `raise.reported` over this
/// implementation, and `vm_run.zig`'s `JOP_MAKE_STRING` and `JOP_MAKE_BUFFER`
/// arms called the *face* from inside `runVm`, which is itself raising. A
/// `tostring` refusal was therefore flattened into a report nobody consumed:
/// the loop went on to build a string out of a half-filled buffer, and the
/// outstanding report killed the process at the next scope boundary with
/// `a raise was reported to a C caller and never consumed` — arbitrarily far
/// from the cause. Under the C original the same refusal was a `longjmp` and
/// propagated. The face is gone and the callers use `try`, which is rule 13's
/// family: an ordinary import away from not needing the face at all.
pub fn fillString(buffer: [*c]c.JanetBuffer, mem: [*c]const c.Janet, count: i32) raise.Raising(void) {
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        try printer.toStringB(buffer, mem[asSize(i)]);
    }
}

// ------------------------------------------------------------- the one face

// There were nine C-ABI faces here, hidden exactly as the C build hid them,
// because `state.h` declared all nine and C callers cannot consume a Zig
// error. Phase 11 Part 12 spent eight of them: every remaining caller reaches
// this file by import, and the last C caller of each was `test/vm_calls.c`.
// The `state.h` block went with them.
//
// `janet_mcall` stays, and the reason is the same one Part 10 and Part 11
// recorded for eleven other names: it is `janet.h`'s public surface. It has no
// in-tree caller at all now — `value_access.zig` reaches `mcall` by import —
// and it is what an embedder calls to invoke a method.

pub const mcallPanicking = raise.panicking(mcall).face;

comptime {
    @export(&mcallPanicking, .{ .name = "janet_mcall" });
}
