//! Behavioral contract for the compiler's primitives — the layer between the
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
//! The order matters. This is one compilation carried from an empty scope to
//! a finished funcdef, and the assertions about `birth_pc`, `death_pc` and
//! the symbol map are assertions about *when* things happened. The sections
//! below are named for readability; they are not independent.
//!
//! ## Why this reaches the `Impl` functions rather than the exports
//!
//! Eight of the primitives are raise-capable — `janetc_value` compiles an
//! arbitrary form, which can reach a macro, a lint at strict level, or an
//! abstract type's `tostring` inside an error message. Each keeps a C face
//! beside it that flattens the raise into a report.
//!
//! A C contract had no choice but the face. This one calls the raising
//! function, which is Part 1's whole argument arriving at the compiler: a
//! raise crosses as `error.JanetSignal`, the compiler checks that this file
//! handles it, and the faces lose their last caller. That is what lets them
//! be deleted in the same increment.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const harness = @import("harness.zig");
const vector = harness.vector;
const primitives = @import("subsystems").compiler_primitives;

/// `util.h` declares this and `abi.zig` deliberately does not translate that
/// header — its dynamic-library section reaches `<dlfcn.h>` and breaks the
/// Windows cross-compile for everything at once. Four subsystems declare it
/// the same way for the same reason.
extern fn janet_def_addflags(definition: *c.JanetFuncDef) callconv(.c) void;

var compiler: c.JanetCompiler = undefined;
var scope: c.JanetScope = undefined;
var child: c.JanetScope = undefined;
var unused: c.JanetScope = undefined;

/// The recursion guard is consulted and decremented by `janetc_value`, so
/// every section that compiles a form resets it the way `janet_compile` does.
const recursion_guard = 1024;

fn emitted(index: usize) u32 {
    return compiler.buffer[index];
}

fn emittedCount() i32 {
    return vector.count(compiler.buffer);
}

/// The opcode in a word, which several assertions here want without the
/// operands.
fn operationOf(word: u32) u32 {
    return word & 0xFF;
}

/// `janetc_fopts_default` describes a form with no expectations: any type is
/// acceptable, no flags are set, and the hint is a nil constant.
fn theDefaultFormOptions() void {
    const options = c.janetc_fopts_default(&compiler);
    std.debug.assert(options.compiler == &compiler);
    std.debug.assert(options.flags == 0);
    std.debug.assert(options.hint.flags == (@as(u32, 1) << c.JANET_NIL) | c.JANET_SLOT_CONSTANT);
    std.debug.assert(harness.isType(options.hint.constant, c.JANET_NIL));
}

/// A constant slot carries the value's type in its low bits, which is what
/// lets the emitter decide whether an immediate will do.
fn aConstantSlotRemembersItsType() void {
    const slot = c.janetc_cslot(c.janet_wrap_true());
    std.debug.assert(slot.flags == (@as(u32, 1) << c.JANET_BOOLEAN) | c.JANET_SLOT_CONSTANT);
    std.debug.assert(slot.index == -1);
    std.debug.assert(slot.envindex == -1);
    std.debug.assert(c.janet_unwrap_boolean(slot.constant) != 0);
}

/// A far slot is handed back when it is freed — unless it has been named, in
/// which case it belongs to a binding and stays taken. That single rule is
/// what keeps a `def`'s register alive for the rest of its scope.
fn aNamedSlotIsNotReclaimed() void {
    var slot = c.janetc_farslot(&compiler);
    std.debug.assert(slot.index == 0);
    std.debug.assert(slot.flags == c.JANET_SLOTTYPE_ANY);
    std.debug.assert(slot.envindex == -1);
    std.debug.assert(harness.isType(slot.constant, c.JANET_NIL));

    c.janetc_freeslot(&compiler, slot);
    std.debug.assert(c.janetc_farslot(&compiler).index == 0);

    slot = c.janetc_farslot(&compiler);
    slot.flags |= c.JANET_SLOT_NAMED;
    c.janetc_freeslot(&compiler, slot);
    std.debug.assert(c.janetc_farslot(&compiler).index == 2);
}

/// `janet_def_addflags` derives a funcdef's `HAS*` flags from which of its
/// optional fields are populated, so it must *clear* the ones that are not.
/// A marshalled image trusts those flags to say which sections follow.
fn theFuncdefFlagsAreDerived() void {
    var definition: c.JanetFuncDef = std.mem.zeroes(c.JanetFuncDef);
    var nested: [*c]c.JanetFuncDef = &definition;
    var mapping: c.JanetSourceMapping = .{ .line = 0, .column = 0 };
    var closure_bits: u32 = 0;
    var environment: i32 = 0;

    definition.flags = c.JANET_FUNCDEF_FLAG_VARARG |
        c.JANET_FUNCDEF_FLAG_HASNAME |
        c.JANET_FUNCDEF_FLAG_HASSOURCE |
        c.JANET_FUNCDEF_FLAG_HASDEFS |
        c.JANET_FUNCDEF_FLAG_HASENVS |
        c.JANET_FUNCDEF_FLAG_HASSOURCEMAP |
        c.JANET_FUNCDEF_FLAG_HASCLOBITSET |
        c.JANET_FUNCDEF_FLAG_NAMEDARGS;
    janet_def_addflags(&definition);
    // Every claim was false, so only the flag that is not derived survives.
    std.debug.assert(definition.flags == c.JANET_FUNCDEF_FLAG_VARARG);

    definition.name = c.janet_cstring("name");
    definition.source = c.janet_cstring("source");
    definition.defs = &nested;
    definition.environments = &environment;
    definition.sourcemap = &mapping;
    definition.closure_bitset = &closure_bits;
    definition.named_args_count = 2;
    janet_def_addflags(&definition);
    std.debug.assert(definition.flags & c.JANET_FUNCDEF_FLAG_VARARG != 0);
    std.debug.assert(definition.flags & c.JANET_FUNCDEF_FLAG_HASNAME != 0);
    std.debug.assert(definition.flags & c.JANET_FUNCDEF_FLAG_HASSOURCE != 0);
    std.debug.assert(definition.flags & c.JANET_FUNCDEF_FLAG_HASDEFS != 0);
    std.debug.assert(definition.flags & c.JANET_FUNCDEF_FLAG_HASENVS != 0);
    std.debug.assert(definition.flags & c.JANET_FUNCDEF_FLAG_HASSOURCEMAP != 0);
    std.debug.assert(definition.flags & c.JANET_FUNCDEF_FLAG_HASCLOBITSET != 0);
    std.debug.assert(definition.flags & c.JANET_FUNCDEF_FLAG_NAMEDARGS != 0);
}

/// Popping a scope hands its high-water register mark and its symbols up to
/// the parent, and stamps a death instruction on each symbol that has none.
///
/// The stamped `death_pc` is the parent's instruction count at the moment of
/// the pop, which is what a debugger uses to decide a binding is out of
/// scope. Nothing in Janet can observe it except a stack trace.
fn poppingAScopeHandsUpItsSymbols() !void {
    c.janetc_regalloc_deinit(&scope.ra);
    compiler.scope = null;
    c.janetc_scope(&scope, &compiler, c.JANET_SCOPE_FUNCTION, "root");
    c.janetc_regalloc_touch(&scope.ra, 5);
    vector.push(&compiler.buffer, harness.op(c.JOP_NOOP));

    c.janetc_scope(&child, &compiler, c.JANET_SCOPE_CLOSURE, "child");
    std.debug.assert(compiler.scope == &child);
    std.debug.assert(scope.child == &child);
    std.debug.assert(child.parent == &scope);
    std.debug.assert(child.bytecode_start == 1);
    // The child inherits the parent's taken registers, so 5 is still taken.
    std.debug.assert(c.janetc_regalloc_check(&child.ra, 5) != 0);

    var pair: c.SymPair = std.mem.zeroes(c.SymPair);
    pair.slot.index = 3;
    pair.slot.envindex = -1;
    pair.sym = c.janet_symbol("local", 5);
    pair.sym2 = pair.sym;
    pair.referenced = 1;
    pair.keep = 1;
    pair.death_pc = std.math.maxInt(u32);
    vector.push(&child.syms, pair);
    c.janetc_regalloc_touch(&child.ra, 8);
    child.ra.max = 8;
    vector.push(&compiler.buffer, harness.op(c.JOP_NOOP));

    try primitives.janetc_popscopeImpl(&compiler);
    std.debug.assert(compiler.scope == &scope);
    std.debug.assert(scope.child == null);
    // A closure scope marks its parent as one too, so the parent knows it
    // needs an environment.
    std.debug.assert(scope.flags & c.JANET_SCOPE_CLOSURE != 0);
    std.debug.assert(scope.ra.max >= 8);
    std.debug.assert(vector.count(scope.syms) == 1);
    // The name is dropped and only `sym2` would survive — and `keep` clears
    // that too, because the slot is being kept rather than the binding.
    std.debug.assert(scope.syms[0].sym == null);
    std.debug.assert(scope.syms[0].sym2 == null);
    std.debug.assert(scope.syms[0].death_pc == 2);
    std.debug.assert(c.janetc_regalloc_check(&scope.ra, 3) != 0);
}

/// An unused scope contributes nothing, but `popscope_keepslot` still touches
/// the register its result lives in so the parent does not hand it out again.
fn anUnusedScopeStillKeepsItsResultSlot() !void {
    c.janetc_scope(&unused, &compiler, c.JANET_SCOPE_UNUSED, "unused");
    var slot: c.JanetSlot = std.mem.zeroes(c.JanetSlot);
    slot.index = 10;
    slot.envindex = -1;
    try primitives.janetc_popscope_keepslotImpl(&compiler, slot);
    std.debug.assert(compiler.scope == &scope);
    std.debug.assert(c.janetc_regalloc_check(&scope.ra, 10) != 0);
}

/// `janetc_return` marks the slot returned and emits at most once, so a
/// second call on an already-returned slot emits nothing.
fn returningIsIdempotent() void {
    vector.empty(compiler.buffer);
    var slot = c.janetc_return(&compiler, c.janetc_cslot(c.janet_wrap_nil()));
    std.debug.assert(slot.flags & c.JANET_SLOT_RETURNED != 0);
    std.debug.assert(emittedCount() == 1);
    std.debug.assert(emitted(0) == harness.op(c.JOP_RETURN_NIL));
    slot = c.janetc_return(&compiler, slot);
    std.debug.assert(emittedCount() == 1);

    vector.empty(compiler.buffer);
    slot = std.mem.zeroes(c.JanetSlot);
    slot.index = 3;
    slot.envindex = -1;
    slot = c.janetc_return(&compiler, slot);
    std.debug.assert(slot.flags & c.JANET_SLOT_RETURNED != 0);
    std.debug.assert(emittedCount() == 1);
    std.debug.assert(emitted(0) == harness.op(c.JOP_RETURN) | (3 << 8));
}

/// A hint is honoured only when the hinted register is near. A far hint is
/// refused and a fresh slot allocated instead, because most instructions have
/// eight bits for a destination.
fn aHintIsHonouredOnlyWhenItIsNear() void {
    var options = c.janetc_fopts_default(&compiler);
    options.flags = c.JANET_FOPTS_HINT;
    options.hint = std.mem.zeroes(c.JanetSlot);
    options.hint.index = 7;
    options.hint.envindex = -1;
    std.debug.assert(c.janetc_gettarget(options).index == 7);

    options.hint.index = 300;
    const slot = c.janetc_gettarget(options);
    std.debug.assert(slot.index >= 0 and slot.index != 300);
    std.debug.assert(slot.envindex == -1 and slot.flags == 0);
    std.debug.assert(harness.isType(slot.constant, c.JANET_NIL));
}

/// A list of values becomes a vector of slots, and a dictionary becomes a
/// flat key-value vector in *sorted key order* — which is what makes a struct
/// literal compile deterministically whatever order it was written in.
fn valuesBecomeSlots() !void {
    var values = [2]c.Janet{ harness.wrapInteger(10), c.janet_wrap_true() };
    compiler.recursion_guard = recursion_guard;
    var slots = try primitives.janetc_toslotsImpl(&compiler, &values, 2);
    std.debug.assert(vector.count(slots) == 2);
    std.debug.assert(slots[0].flags & c.JANET_SLOT_CONSTANT != 0);
    std.debug.assert(harness.integerIs(slots[0].constant, 10));
    std.debug.assert(slots[1].flags & c.JANET_SLOT_CONSTANT != 0);
    std.debug.assert(c.janet_unwrap_boolean(slots[1].constant) != 0);
    c.janetc_freeslots(&compiler, slots);

    const dictionary = c.janet_table(2);
    c.janet_table_put(dictionary, c.janet_ckeywordv("b"), harness.wrapInteger(2));
    c.janet_table_put(dictionary, c.janet_ckeywordv("a"), harness.wrapInteger(1));
    compiler.recursion_guard = recursion_guard;
    slots = try primitives.janetc_toslotskvImpl(&compiler, c.janet_wrap_table(dictionary));
    std.debug.assert(vector.count(slots) == 4);
    std.debug.assert(harness.keywordIs(slots[0].constant, "a"));
    std.debug.assert(harness.integerIs(slots[1].constant, 1));
    std.debug.assert(harness.keywordIs(slots[2].constant, "b"));
    std.debug.assert(harness.integerIs(slots[3].constant, 2));
    c.janetc_freeslots(&compiler, slots);
}

/// The four kinds `janetc_value` distinguishes: a self-evaluating atom, a
/// structure it can fold to a constant, one it has to build at run time, and
/// a call.
fn theFourKindsOfForm() !void {
    compiler.current_mapping.line = 12;
    compiler.current_mapping.column = 34;
    compiler.recursion_guard = recursion_guard;
    var options = c.janetc_fopts_default(&compiler);

    // An atom compiles to a constant and disturbs neither the guard nor the
    // source position, which is what makes those two safe to read afterwards.
    var slot = try primitives.janetc_valueImpl(options, harness.wrapInteger(55));
    std.debug.assert(slot.flags & c.JANET_SLOT_CONSTANT != 0);
    std.debug.assert(harness.integerIs(slot.constant, 55));
    std.debug.assert(compiler.recursion_guard == recursion_guard);
    std.debug.assert(compiler.current_mapping.line == 12);
    std.debug.assert(compiler.current_mapping.column == 34);

    // A struct of constants folds, so nothing is built at run time.
    const constructed = c.janet_struct_begin(1);
    c.janet_struct_put(constructed, c.janet_ckeywordv("key"), harness.wrapInteger(9));
    var folded = c.janet_wrap_struct(c.janet_struct_end(constructed));
    slot = try primitives.janetc_valueImpl(options, folded);
    std.debug.assert(slot.flags & c.JANET_SLOT_CONSTANT != 0);
    std.debug.assert(harness.isType(slot.constant, c.JANET_STRUCT));
    std.debug.assert(emittedCount() == 1);

    // A mutable structure cannot fold, so it is pushed and constructed.
    const array = c.janet_array(2);
    c.janet_array_push(array, harness.wrapInteger(4));
    c.janet_array_push(array, harness.wrapInteger(5));
    vector.empty(compiler.buffer);
    compiler.recursion_guard = recursion_guard;
    slot = try primitives.janetc_valueImpl(options, c.janet_wrap_array(array));
    std.debug.assert(slot.flags & c.JANET_SLOT_CONSTANT == 0);
    std.debug.assert(emittedCount() == 4);
    std.debug.assert(operationOf(emitted(2)) == harness.op(c.JOP_PUSH_2));
    std.debug.assert(operationOf(emitted(3)) == harness.op(c.JOP_MAKE_ARRAY));
    c.janetc_freeslot(&compiler, slot);

    // A tuple is a call, and in tail position it is a tail call.
    var call = c.janet_tuple_begin(2);
    call[0] = c.janet_ckeywordv("key");
    call[1] = folded;
    folded = c.janet_wrap_tuple(c.janet_tuple_end(call));
    vector.empty(compiler.buffer);
    compiler.recursion_guard = recursion_guard;
    options = c.janetc_fopts_default(&compiler);
    slot = try primitives.janetc_valueImpl(options, folded);
    std.debug.assert(slot.flags & c.JANET_SLOT_CONSTANT == 0);
    std.debug.assert(operationOf(emitted(@intCast(emittedCount() - 1))) == harness.op(c.JOP_CALL));
    c.janetc_freeslot(&compiler, slot);

    vector.empty(compiler.buffer);
    compiler.recursion_guard = recursion_guard;
    options = c.janetc_fopts_default(&compiler);
    options.flags |= c.JANET_FOPTS_TAIL;
    slot = try primitives.janetc_valueImpl(options, folded);
    std.debug.assert(slot.flags & c.JANET_SLOT_RETURNED != 0);
    std.debug.assert(operationOf(emitted(@intCast(emittedCount() - 1))) == harness.op(c.JOP_TAILCALL));

    // A one-element call whose head is not callable is a compile error rather
    // than a raise: the compiler records it and answers a nil constant.
    call = c.janet_tuple_begin(1);
    call[0] = c.janet_ckeywordv("key");
    vector.empty(compiler.buffer);
    compiler.recursion_guard = recursion_guard;
    options = c.janetc_fopts_default(&compiler);
    slot = try primitives.janetc_valueImpl(options, c.janet_wrap_tuple(c.janet_tuple_end(call)));
    std.debug.assert(slot.flags & c.JANET_SLOT_CONSTANT != 0);
    std.debug.assert(harness.isType(slot.constant, c.JANET_NIL));
    std.debug.assert(compiler.result.status == c.JANET_COMPILE_ERROR);
    std.debug.assert(compiler.result.@"error" != null);
    compiler.result.status = c.JANET_COMPILE_OK;
    compiler.result.@"error" = null;
    compiler.recursion_guard = recursion_guard;
}

/// Pushing arguments picks the widest instruction that fits, and a splice
/// forces the one-at-a-time form — which is what the negative arity means.
fn theArgumentPush() void {
    var slots: [*c]c.JanetSlot = null;
    var slot: c.JanetSlot = std.mem.zeroes(c.JanetSlot);
    slot.envindex = -1;
    for ([_]i32{ 1, 2, 3 }) |index| {
        slot.index = index;
        vector.push(&slots, slot);
    }

    vector.empty(compiler.buffer);
    std.debug.assert(c.janetc_pushslots(&compiler, slots) == 3);
    std.debug.assert(emittedCount() == 1);
    std.debug.assert(emitted(0) ==
        harness.op(c.JOP_PUSH_3) | (1 << 8) | (2 << 16) | (3 << 24));

    // A spliced argument makes the arity a minimum rather than an exact
    // count, which the caller reads from the sign.
    slots[1].flags |= c.JANET_SLOT_SPLICED;
    vector.empty(compiler.buffer);
    std.debug.assert(c.janetc_pushslots(&compiler, slots) == -3);
    std.debug.assert(emittedCount() == 3);
    std.debug.assert(emitted(0) == harness.op(c.JOP_PUSH) | (1 << 8));
    std.debug.assert(emitted(1) == harness.op(c.JOP_PUSH_ARRAY) | (2 << 8));
    std.debug.assert(emitted(2) == harness.op(c.JOP_PUSH) | (3 << 8));
    vector.free(slots);
}

/// A global `def` resolves to its value, a global `var` to a reference cell.
///
/// The difference is the whole of Janet's mutable-binding representation: a
/// `var` is a one-element array in the environment and every read is an
/// index into it, which is why the slot is `REF | NAMED | MUTABLE` and not
/// `CONSTANT`.
fn theGlobalBindings() !void {
    c.janet_def(compiler.env, "global-def", harness.wrapInteger(42), null);
    var symbol = c.janet_symbol("global-def", 10);
    std.debug.assert(c.janetc_shadowcheck(&compiler, symbol) == c.JANETC_SHADOW_LOCAL_HIDES_GLOBAL);
    var slot = try primitives.janetc_resolveImpl(&compiler, symbol);
    std.debug.assert(slot.flags & c.JANET_SLOT_CONSTANT != 0);
    std.debug.assert(harness.integerIs(slot.constant, 42));

    c.janet_var(compiler.env, "global-var", harness.wrapInteger(7), null);
    symbol = c.janet_symbol("global-var", 10);
    slot = try primitives.janetc_resolveImpl(&compiler, symbol);
    std.debug.assert(slot.flags & c.JANET_SLOT_REF != 0);
    std.debug.assert(slot.flags & c.JANET_SLOT_NAMED != 0);
    std.debug.assert(slot.flags & c.JANET_SLOT_MUTABLE != 0);
    std.debug.assert(slot.flags & c.JANET_SLOT_CONSTANT == 0);
}

/// A local binding, and then the capture of it by a nested function.
///
/// Resolving a local from an inner function scope is what turns it into an
/// upvalue: the outer scope gains `JANET_SCOPE_ENV`, the symbol is marked
/// `keep`, its register is reserved in the outer *upvalue* allocator, and the
/// inner scope gains an environment reference. Five separate pieces of state,
/// all of which a wrong port could get individually wrong while still
/// producing a working closure.
fn aLocalIsCaptured() !c.JanetString {
    const symbol = c.janet_symbol("captured", 8);
    std.debug.assert(c.janetc_shadowcheck(&compiler, symbol) == c.JANETC_SHADOW_NONE);

    var slot: c.JanetSlot = std.mem.zeroes(c.JanetSlot);
    slot.index = 4;
    slot.envindex = -1;
    try primitives.janetc_nameslotImpl(&compiler, symbol, slot, c.JANET_DEFFLAG_NO_SHADOWCHECK);
    std.debug.assert(vector.count(scope.syms) == 2);
    std.debug.assert(scope.syms[1].sym == symbol);
    std.debug.assert(scope.syms[1].sym2 == symbol);
    std.debug.assert(scope.syms[1].slot.flags & c.JANET_SLOT_NAMED != 0);
    std.debug.assert(scope.syms[1].birth_pc == 2);
    std.debug.assert(scope.syms[1].death_pc == std.math.maxInt(u32));
    std.debug.assert(c.janetc_shadowcheck(&compiler, symbol) == c.JANETC_SHADOW_LOCAL_HIDES_LOCAL);

    // Resolving it in its own scope marks it used and leaves it local.
    slot = try primitives.janetc_resolveImpl(&compiler, symbol);
    std.debug.assert(slot.index == 4 and slot.envindex == -1);
    std.debug.assert(scope.syms[1].referenced != 0);

    // Resolving it from inside a function scope captures it.
    c.janetc_scope(&child, &compiler, c.JANET_SCOPE_FUNCTION, "capture");
    slot = try primitives.janetc_resolveImpl(&compiler, symbol);
    std.debug.assert(slot.index == 4 and slot.envindex == 0);
    std.debug.assert(scope.flags & c.JANET_SCOPE_ENV != 0);
    std.debug.assert(scope.syms[1].keep != 0);
    std.debug.assert(c.janetc_regalloc_check(&scope.ua, 4) != 0);
    std.debug.assert(vector.count(child.envs) == 1);
    std.debug.assert(child.envs[0].envindex == -1);
    std.debug.assert(child.envs[0].scope == &scope);

    try primitives.janetc_popscopeImpl(&compiler);
    std.debug.assert(compiler.scope == &scope);
    return symbol;
}

/// The funcdef that falls out of the finished scope, including the debug
/// image a stack trace reads.
fn theFinishedFuncdef(captured: c.JanetString) !void {
    const options = c.janetc_fopts_default(&compiler);
    compiler.recursion_guard = recursion_guard;
    try primitives.janetc_throwawayImpl(options, harness.wrapInteger(99));
    // A thrown-away value emits nothing new, and leaves the scope where it
    // found it.
    std.debug.assert(compiler.scope == &scope);
    std.debug.assert(emittedCount() == 3);

    const definition = try primitives.janetc_pop_funcdefImpl(&compiler);
    std.debug.assert(compiler.scope == null);
    std.debug.assert(definition.*.slotcount == scope.ra.max + 1);
    std.debug.assert(definition.*.bytecode_length == 3);
    std.debug.assert(definition.*.bytecode[0] == harness.op(c.JOP_PUSH) | (1 << 8));
    std.debug.assert(definition.*.bytecode[1] == harness.op(c.JOP_PUSH_ARRAY) | (2 << 8));
    std.debug.assert(definition.*.bytecode[2] == harness.op(c.JOP_PUSH) | (3 << 8));
    std.debug.assert(definition.*.constants_length > 0);
    std.debug.assert(definition.*.defs_length == 0);
    std.debug.assert(definition.*.environments_length == 0);
    // The scope was captured from, so the function needs an environment and
    // records which of its registers are closed over.
    std.debug.assert(definition.*.flags & c.JANET_FUNCDEF_FLAG_NEEDSENV != 0);
    std.debug.assert(definition.*.flags & c.JANET_FUNCDEF_FLAG_HASSYMBOLMAP != 0);
    std.debug.assert(definition.*.closure_bitset != null);
    std.debug.assert(definition.*.closure_bitset[0] & (@as(u32, 1) << 4) != 0);
    // The symbol map is what `(debug/stack)` reads.
    std.debug.assert(definition.*.symbolmap_length == 1);
    std.debug.assert(definition.*.symbolmap[0].birth_pc == 2);
    std.debug.assert(definition.*.symbolmap[0].death_pc == 3);
    std.debug.assert(definition.*.symbolmap[0].slot_index == 4);
    std.debug.assert(definition.*.symbolmap[0].symbol == captured);
    // The compiler's buffer was moved into the funcdef rather than copied.
    std.debug.assert(emittedCount() == 0);
}

/// An unresolvable symbol is a recorded error rather than a raise, and the
/// first error is the one that is kept.
fn theFirstErrorIsKept() !void {
    const symbol = c.janet_symbol("missing", 7);
    const slot = try primitives.janetc_resolveImpl(&compiler, symbol);
    std.debug.assert(slot.flags & c.JANET_SLOT_CONSTANT != 0);
    std.debug.assert(harness.isType(slot.constant, c.JANET_NIL));
    std.debug.assert(compiler.result.status == c.JANET_COMPILE_ERROR);
    std.debug.assert(compiler.result.@"error" != null);

    const first = compiler.result.@"error";
    c.janetc_cerror(&compiler, "replacement error");
    std.debug.assert(compiler.result.@"error" == first);
}

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
    theArgumentPush();
    try theGlobalBindings();
    const captured = try aLocalIsCaptured();
    try theFinishedFuncdef(captured);
    try theFirstErrorIsKept();
}

pub fn run() void {
    _ = c.janet_init();

    compiler = std.mem.zeroes(c.JanetCompiler);
    scope = std.mem.zeroes(c.JanetScope);
    compiler.env = c.janet_table(0);
    compiler.scope = &scope;
    c.janetc_regalloc_init(&scope.ra);

    body() catch @panic("compiler_primitives: a kernel raised unexpectedly");

    vector.free(compiler.buffer);
    c.janet_deinit();
}
