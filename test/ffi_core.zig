//! Behavioral contract for the FFI's type system, marshalling, calling
//! machinery and cfunction surface.
//!
//! ## What the Janet suites cannot reach
//!
//! `test/suite-ffi.janet` exercises the type system and `port/probe-16/abi/`
//! drives real calls against real C. Six things have no Janet spelling:
//!
//!  - **The primitive size and alignment table.** `ffi_types.zig`'s `primInfo`
//!    is a restatement of the host's own numbers, and a restatement is a place
//!    two answers can drift apart. Every entry is checked below against the
//!    type it names, which is the same argument `test/ffi_layout.zig` makes
//!    for the struct layout machine.
//!  - **The abstract types' callback sets.** `core/ffi-struct` and
//!    `core/ffi-signature` are `JANET_ATEND_GCMARK`, so a mark callback and
//!    eleven null slots; `core/ffi-native` is `JANET_ATEND_NAME` and has
//!    twelve. From Janet only the *name* is visible, through `(type x)`. That
//!    the `get`, `put`, `call` and `next` slots are null is what makes these
//!    values opaque, and it is invisible from the language.
//!  - **The callback entry with no userdata.** Every callback ends there, and
//!    its first act is to check for a null `userdata` and complain. A Janet
//!    program reaches it only through a C library calling back, which always
//!    passes the pointer it was given, so the null arm is unreachable from the
//!    language and reachable in one line from here.
//!  - **The outgoing half of the frame.** Phase 10 Part 16 added
//!    `arg_stack_count` to `AllocResult` because a Zig caller declares the
//!    outgoing stack words as function parameters and must not count the
//!    by-reference payloads that follow them. Nothing in Janet can observe the
//!    split; the allocators can be asked directly.
//!  - **The rung ceiling.** Past 1024 words of outgoing arguments there is no
//!    function type to call through, and `ffi/signature` reports it. Only
//!    SysV64 can reach it, so the assertion is on the allocator rather than on
//!    a call this host could make.
//!  - **The failure messages.** A raise is asserted here by its *message*,
//!    which Phase 9 Part 11 recorded as the difference between a test and a
//!    tautology.
//!
//! ## What the migration changed
//!
//! **Nothing here reaches a symbol any more.** `test/ffi_core.c` hand-declared
//! the three allocators and the callback entry, because none of the four is in
//! a header; they were exported for a `ffi.c` that no longer exists, and this
//! contract was the last reader of the names. All four are ordinary Zig
//! functions now — see `src/zig/README.md`'s entry for the twelve symbols this
//! increment spent.
//!
//! **The alignment oracle is rebuilt rather than translated.** `ffi_core.c`
//! spelled `ALIGNOF(type)` as `offsetof(struct { char c; type member; },
//! member)` — `alignof` is not in c99 — so it derived alignment from the
//! compiler's *struct layout* rather than asking for it directly.
//! `@alignOf(T)` is the direct question, and it is also the expression
//! `primInfo` itself uses, so a translation would have compared `primInfo`
//! with itself. `alignOfMember` below is the C macro's shape in Zig, and the
//! pairing it checks — this name means this machine type — is what the table
//! actually encodes.

const std = @import("std");
const abi = @import("abi");
const c = abi.c;
const harness = @import("harness.zig");

const subsystems = @import("subsystems");
const ffi_classify = subsystems.ffi_classify;
const ffi_call = subsystems.ffi_call;

const ArgSlot = ffi_classify.ArgSlot;
const AllocResult = ffi_classify.AllocResult;

const assert = std.debug.assert;

const has_dynamic_modules = @hasDecl(c, "JANET_DYNAMIC_MODULES");

var raises_seen: u32 = 0;

/// A refusal, by the message it carried. Reading the message is what
/// distinguishes "it refused" from "it refused for the reason this case is
/// about", and every one of these messages is a line of `ffi_types.zig`,
/// `ffi_marshal.zig` or `ffi_call.zig` that nothing else reaches.
fn expectRaise(function: anytype, args: anytype, message: []const u8) void {
    const raise = harness.raised(function, args) orelse {
        std.debug.panic("ffi_core: expected a raise, got a return: {s}\n", .{message});
    };
    assert(raise.signal == c.JANET_SIGNAL_ERROR);
    assert(raise.says(message));
    raises_seen += 1;
}

/// The same for a message only some of which is reproducible: a refusal that
/// names an abstract renders its address.
fn expectRaisePrefix(function: anytype, args: anytype, prefix: []const u8) void {
    const raise = harness.raised(function, args) orelse {
        std.debug.panic("ffi_core: expected a raise, got a return: {s}\n", .{prefix});
    };
    assert(raise.signal == c.JANET_SIGNAL_ERROR);
    assert(raise.beginsWith(prefix));
    raises_seen += 1;
}

fn eval(source: [*:0]const u8) c.Janet {
    var out = c.janet_wrap_nil();
    const env = c.janet_core_env(null);
    assert(c.janet_dostring(env, source, "ffi_core", &out) == 0);
    return out;
}

/// Whether this host can actually load anything, which is a different question
/// from whether the subsystem was compiled.
///
/// `-Ddynamic-modules` answers the second. Zig links musl targets statically
/// and musl's static `dlopen` is a stub that always fails -- `port/testing.md`
/// records it as the first of its five limitations -- so on
/// `aarch64-linux-musl` the subsystem is present, every binding is registered,
/// and every `ffi/native` raises "Dynamic loading not supported". This is rule
/// 7 one layer down: there it was a subsystem being compiled against a binding
/// being registered, here it is a binding being registered against its working.
/// `options` cannot answer either; the environment answers both.
///
/// Found by Phase 11 Part 24's container run, which is the first time this
/// contract had ever executed anywhere but macOS -- the FFI group migrated in
/// Part 16 and the container had last run in Part 4.
fn dynamicLoadingWorks() bool {
    if (!has_dynamic_modules) return false;
    var out = c.janet_wrap_nil();
    const env = c.janet_core_env(null);
    if (c.janet_dostring(env, "(first (protect (ffi/native)))", "ffi_core", &out) != 0) return false;
    return c.janet_truthy(out) != 0;
}

// ------------------------------------------------------------ registration

/// Every name `janet_lib_ffi` registers. A binding that stops being registered
/// is what this catches, and Phase 9 Part 6 recorded that a registration table
/// is the one place a cfunction can go missing without a link error.
const ffi_bindings = [_][*:0]const u8{
    "ffi/native",              "ffi/lookup", "ffi/close",          "ffi/signature",
    "ffi/call",                "ffi/struct", "ffi/write",          "ffi/read",
    "ffi/size",                "ffi/align",  "ffi/trampoline",     "ffi/jitfn",
    "ffi/malloc",              "ffi/free",   "ffi/pointer-buffer", "ffi/pointer-cfunction",
    "ffi/calling-conventions",
};

fn registration() void {
    assert(ffi_bindings.len == 17);
    // `harness.core` asserts the binding resolves to a cfunction, so reaching
    // the end of the loop is the assertion.
    for (ffi_bindings) |name| _ = harness.core(name);
}

// ------------------------------------------------- the host's own numbers

/// `ALIGNOF` as `ffi.c` spelled it, in Zig: the offset a member of this type
/// takes after one byte. See the header for why it is not `@alignOf`.
fn alignOfMember(comptime T: type) usize {
    return @offsetOf(extern struct { leading: u8, member: T }, "member");
}

const PrimCase = struct { name: [*:0]const u8, size: usize, alignment: usize };

fn primCase(name: [*:0]const u8, comptime T: type) PrimCase {
    return .{ .name = name, .size = @sizeOf(T), .alignment = alignOfMember(T) };
}

/// Every machine type, against the type it names.
fn primTable() void {
    const cases = [_]PrimCase{
        .{ .name = "void", .size = 0, .alignment = 0 },
        primCase("bool", u8),
        primCase("ptr", *anyopaque),
        primCase("pointer", *anyopaque),
        primCase("string", [*c]u8),
        primCase("float", f32),
        primCase("double", f64),
        primCase("int8", i8),
        primCase("uint8", u8),
        primCase("int16", i16),
        primCase("uint16", u16),
        primCase("int32", i32),
        primCase("uint32", u32),
        primCase("int64", i64),
        primCase("uint64", u64),
        // The aliases, which resolve to the same entries.
        primCase("r32", f32),
        primCase("r64", f64),
        primCase("s8", i8),
        primCase("u8", u8),
        primCase("s16", i16),
        primCase("u16", u16),
        primCase("s32", i32),
        primCase("u32", u32),
        primCase("s64", i64),
        primCase("u64", u64),
        primCase("char", i8),
        primCase("short", i16),
        primCase("int", i32),
        primCase("long", i64),
        primCase("byte", u8),
        primCase("uchar", u8),
        primCase("ushort", u16),
        primCase("uint", u32),
        primCase("ulong", u64),
        primCase("size", usize),
        primCase("ssize", usize),
    };
    assert(cases.len == 36);

    const size_of = harness.core("ffi/size");
    const align_of = harness.core("ffi/align");
    for (cases) |case| {
        var arg = c.janet_ckeywordv(case.name);
        const size = size_of(1, &arg) catch @panic("ffi_core: ffi/size raised");
        const alignment = align_of(1, &arg) catch @panic("ffi_core: ffi/align raised");
        assert(c.janet_unwrap_number(size) == @as(f64, @floatFromInt(case.size)));
        assert(c.janet_unwrap_number(alignment) == @as(f64, @floatFromInt(case.alignment)));
    }
}

// ----------------------------------------------------- the abstract types

/// The callback set of the abstract behind `expr`, checked slot by slot. Only
/// `name` is visible from Janet, and only through `(type x)`.
///
/// The stored form is what is read — `janet_abstract_type` on the value, as
/// the C contract did — rather than the `abstract_type.AbstractType` these are
/// declared as. It is the same memory, and it is the view every other reader
/// of an abstract gets.
fn expectShape(
    expr: [*:0]const u8,
    name: [*:0]const u8,
    has_gc: bool,
    has_gcmark: bool,
    has_bytes: bool,
    has_length: bool,
) void {
    const value = eval(expr);
    assert(harness.isType(value, c.JANET_ABSTRACT));
    const at = c.janet_abstract_type(c.janet_unwrap_abstract(value));
    // `strcmp`, not `janet_cstrcmp`: an abstract type's `name` is a plain C
    // string rather than a length-prefixed `JanetString`, and the second reads
    // a header that is not there.
    assert(std.mem.eql(u8, std.mem.span(at.*.name), std.mem.span(name)));
    assert((at.*.gc != null) == has_gc);
    assert((at.*.gcmark != null) == has_gcmark);
    assert((at.*.bytes != null) == has_bytes);
    assert((at.*.length != null) == has_length);
    // Everything else is null in all of these types, which is what makes them
    // opaque: no indexing, no method call, no comparison, no hashing.
    assert(at.*.get == null);
    assert(at.*.put == null);
    assert(at.*.marshal == null);
    assert(at.*.unmarshal == null);
    assert(at.*.tostring == null);
    assert(at.*.compare == null);
    assert(at.*.hash == null);
    assert(at.*.next == null);
    assert(at.*.call == null);
}

fn abstractTypes() void {
    expectShape("(ffi/struct :int32 :double)", "core/ffi-struct", false, true, false, false);
    expectShape("(ffi/signature :none :void :int32)", "core/ffi-signature", false, true, false, false);
    if (dynamicLoadingWorks()) {
        expectShape("(ffi/native)", "core/ffi-native", false, false, false, false);
    }
}

// --------------------------------------------------- the callback entry

/// The null-userdata arm, which no Janet program can produce: a C library
/// always passes back the pointer it was handed. It complains and returns
/// rather than raising, so reaching it at all is the assertion.
fn callbackWithoutUserdata() void {
    ffi_call.callbackEntry(null, null);
}

// ------------------------------------------ the outgoing half of the frame

const prim_int64: u32 = 12;
const prim_struct: u32 = 14;
const sysv64_integer: u32 = 0;
const sysv64_memory: u32 = 8;
const win64_register: u32 = 9;
const aapcs64_general: u32 = 13;
const aapcs64_general_ref: u32 = 15;

fn slot(prim: u32, spec: u32, size: u64, alignment: u32) ArgSlot {
    return .{
        .size = size,
        .prim = prim,
        .spec = spec,
        .alignment = alignment,
        .offset = 0,
        .offset2 = 0,
        // Nothing in this file is a homogeneous floating-point aggregate.
        .hfa_members = 0,
    };
}

/// A by-reference payload is part of the frame and is *not* an outgoing
/// argument, and only the split tells a caller how many parameters to declare.
/// Win64 and AAPCS64 both have a payload area; SysV64 has none, and its two
/// counts are therefore equal.
fn outgoingSplit() void {
    var args: [16]ArgSlot = undefined;
    var ret: ArgSlot = undefined;
    var result: AllocResult = undefined;

    // Ten integers on Win64: four in registers, six on the stack, no payloads.
    // The two counts agree because nothing was passed by reference.
    ret = slot(prim_int64, win64_register, 8, 8);
    for (args[0..10]) |*a| a.* = slot(prim_int64, win64_register, 8, 8);
    ffi_classify.allocWin64(&result, &ret, args[0..10]);
    assert(result.error_kind == 0);
    assert(result.arg_stack_count == 6);
    assert(result.stack_count == 6);

    // The same with three oversized aggregates, which Win64 passes by
    // reference: each takes one outgoing word and a payload behind it, so the
    // frame grows and the outgoing count does not.
    ret = slot(prim_int64, win64_register, 8, 8);
    for (args[0..10]) |*a| a.* = slot(prim_int64, win64_register, 8, 8);
    for (args[10..13]) |*a| a.* = slot(prim_struct, win64_register, 64, 8);
    ffi_classify.allocWin64(&result, &ret, args[0..13]);
    assert(result.error_kind == 0);
    assert(result.arg_stack_count == 9);
    assert(result.stack_count > result.arg_stack_count);

    // SysV64 has no payload area at all: an aggregate that does not fit in
    // registers goes onto the stack whole.
    ret = slot(prim_int64, sysv64_integer, 8, 8);
    for (args[0..8]) |*a| a.* = slot(prim_int64, sysv64_integer, 8, 8);
    args[8] = slot(prim_struct, sysv64_memory, 64, 8);
    ffi_classify.allocSysv64(&result, &ret, args[0..9]);
    assert(result.error_kind == 0);
    assert(result.stack_count == result.arg_stack_count);
    assert(result.arg_stack_count == 2 + 8);

    // AAPCS64 counts its frame in bytes and its outgoing half in words.
    ret = slot(prim_int64, aapcs64_general, 8, 8);
    for (args[0..12]) |*a| a.* = slot(prim_int64, aapcs64_general, 8, 8);
    ffi_classify.allocAapcs64(&result, &ret, args[0..12], false, 128);
    assert(result.error_kind == 0);
    assert(result.arg_stack_count == 4);
    assert(result.stack_count == 32);
}

/// The ceiling is 1024 outgoing words, and SysV64 is the only convention that
/// can generate more: it passes a large aggregate by value on the stack where
/// the other two pass a pointer.
fn ceilingIsReachableOnlyOnSysv() void {
    var args: [2]ArgSlot = undefined;
    var ret: ArgSlot = undefined;
    var result: AllocResult = undefined;

    ret = slot(prim_int64, sysv64_integer, 8, 8);
    args[0] = slot(prim_struct, sysv64_memory, 16000, 8);
    ffi_classify.allocSysv64(&result, &ret, args[0..1]);
    assert(result.error_kind == 0);
    assert(result.arg_stack_count == 2000);

    // The same aggregate on AAPCS64 is one word, however large it gets.
    ret = slot(prim_int64, aapcs64_general, 8, 8);
    args[0] = slot(prim_struct, aapcs64_general_ref, 16000, 8);
    ffi_classify.allocAapcs64(&result, &ret, args[0..1], false, 128);
    assert(result.error_kind == 0);
    assert(result.arg_stack_count == 0);
}

// ------------------------------------------------------------- the raises

fn theRaises() void {
    var argv: [4]c.Janet = undefined;

    const ffi_struct = harness.core("ffi/struct");
    const ffi_size = harness.core("ffi/size");
    const ffi_signature = harness.core("ffi/signature");
    const ffi_call_fn = harness.core("ffi/call");
    const ffi_read = harness.core("ffi/read");
    const ffi_write = harness.core("ffi/write");

    expectRaise(ffi_struct, .{ @as(i32, 0), null }, "arity mismatch, expected at least 1, got 0");
    expectRaise(ffi_size, .{ @as(i32, 0), null }, "arity mismatch, expected 1, got 0");

    argv[0] = c.janet_ckeywordv("nonesuch");
    expectRaise(ffi_size, .{ @as(i32, 1), &argv }, "unknown machine type nonesuch");

    argv[0] = harness.wrapInteger(7);
    expectRaise(ffi_size, .{ @as(i32, 1), &argv }, "bad native type 7");

    argv[0] = eval("@[:int32 1 2]");
    expectRaisePrefix(ffi_size, .{ @as(i32, 1), &argv }, "array type must be of form @[type count], got ");

    // A struct of one void member: the void type has no alignment, which is
    // the `el_align == 0` arm of the layout loop.
    argv[0] = c.janet_ckeywordv("void");
    expectRaise(ffi_struct, .{ @as(i32, 1), &argv }, "bad field type void");

    argv[0] = c.janet_ckeywordv("nonesuch");
    argv[1] = c.janet_ckeywordv("void");
    expectRaise(ffi_signature, .{ @as(i32, 2), &argv }, "unknown calling convention nonesuch");

    // `:none` describes but cannot call.
    {
        argv[0] = c.janet_ckeywordv("none");
        argv[1] = c.janet_ckeywordv("void");
        const sig = ffi_signature(2, &argv) catch @panic("ffi_core: ffi/signature raised");
        var call_argv: [2]c.Janet = undefined;
        call_argv[0] = c.janet_wrap_pointer(@ptrCast(@constCast(&theRaises)));
        call_argv[1] = sig;
        expectRaise(ffi_call_fn, .{ @as(i32, 2), &call_argv }, "calling convention not supported");
    }

    // A callable pointer is a pointer or a jitfn, and nothing else.
    {
        var call_argv: [2]c.Janet = undefined;
        call_argv[0] = harness.wrapInteger(7);
        call_argv[1] = eval("(ffi/signature :none :void)");
        expectRaise(
            ffi_call_fn,
            .{ @as(i32, 2), &call_argv },
            "bad slot #0, expected ffi callable pointer type, got 7",
        );
    }

    // Reading past the end of a byte source.
    argv[0] = c.janet_ckeywordv("int64");
    argv[1] = c.janet_cstringv("abc");
    expectRaise(ffi_read, .{ @as(i32, 2), &argv }, "read out of range");

    // Writing at an index beyond the buffer's own count.
    argv[0] = c.janet_ckeywordv("int32");
    argv[1] = harness.wrapInteger(1);
    argv[2] = c.janet_wrap_buffer(c.janet_buffer(8));
    argv[3] = harness.wrapInteger(4);
    expectRaise(ffi_write, .{ @as(i32, 4), &argv }, "index out of bounds");

    // A struct written with the wrong number of fields, and an array with the
    // wrong length. Both are shape faults the marshaller reports.
    argv[0] = eval("(ffi/struct :int32 :int32)");
    argv[1] = eval("[1 2 3]");
    expectRaise(ffi_write, .{ @as(i32, 2), &argv }, "wrong number of fields in struct, expected 2, got 3");

    argv[0] = eval("@[:int32 3]");
    argv[1] = eval("[1 2]");
    expectRaise(ffi_write, .{ @as(i32, 2), &argv }, "bad array length, expected 3, got 2");

    // `:void` writes only nil.
    argv[0] = c.janet_ckeywordv("void");
    argv[1] = harness.wrapInteger(1);
    expectRaise(ffi_write, .{ @as(i32, 2), &argv }, "expected nil, got 1");

    // A native object closed twice, and the running binary refusing to close.
    //
    // Without dynamic modules there is no native object to have: `util.h`
    // reduces `Clib` to an `int` and `load_clib` to a no-op that answers zero,
    // so `ffi/native` always raises. That arm is the whole of this section in
    // such a build, and it is a real arm — Phase 10 Part 16's matrix caught
    // this contract assuming the other one.
    if (dynamicLoadingWorks()) {
        const self = eval("(ffi/native)");
        c.janet_gcroot(self);
        var self_argv = [_]c.Janet{self};
        expectRaise(harness.core("ffi/close"), .{ @as(i32, 1), &self_argv }, "cannot close self");
        {
            var lookup = [_]c.Janet{ self, c.janet_cstringv("a_symbol_that_does_not_exist") };
            const found = harness.core("ffi/lookup")(2, &lookup) catch
                @panic("ffi_core: ffi/lookup raised");
            assert(harness.isType(found, c.JANET_NIL));
        }
        _ = c.janet_gcunroot(self);
    } else if (!has_dynamic_modules) {
        expectRaise(harness.core("ffi/native"), .{ @as(i32, 0), null }, "dynamic modules not supported");
    } else {
        // Compiled, registered, and unable to load: a statically linked musl
        // build. Asserted rather than skipped, so the arm says what it is --
        // the message comes from `load_clib`, not from the `util.h` reduction
        // the branch above pins, and the two are different refusals.
        expectRaise(harness.core("ffi/native"), .{ @as(i32, 0), null }, "Dynamic loading not supported");
    }
}

// ------------------------------------------------ homogeneous float aggregates

/// A two-member HFA and the two directions it travels.
///
/// These are the callee. A Zig contract is compiled into the runtime, so it can
/// hand `ffi/call` the address of a function in this file and make a real call
/// with no shared library anywhere — which is what `port/probe-16/abi/` needs a
/// `zig cc` and a `.dylib` to do.
const Hfa2 = extern struct { a: f32, b: f32 };

fn hfa2Weighted(s: Hfa2) callconv(.c) f64 {
    return @as(f64, s.a) * 1 + @as(f64, s.b) * 2;
}

fn hfa2Build(seed: f32) callconv(.c) Hfa2 {
    return .{ .a = seed, .b = seed + 1 };
}

/// AAPCS64 §6.8.2 passes a homogeneous floating-point aggregate in one vector
/// register per member. `FOUND.md` records the C implementation sizing it by
/// bytes instead, which agrees only for a member exactly eight bytes wide — so
/// an aggregate of `double` was right by coincidence and one of `float` was
/// given half the registers, with two members packed into the first.
///
/// The entry describes the outgoing direction only. **The return is the same
/// defect read backwards** and had no entry until Phase 11 Part 18: each member
/// comes back in its own register, so a two-float aggregate arrived as
/// `(1.5 0)`.
///
/// Gated on the convention rather than on `builtin`, because what matters is
/// which convention `:default` resolves to — rule 7, and the same question
/// `harness.coreOptional` asks about a binding.
fn homogeneousFloatAggregates() void {
    if (!supports("aapcs64")) return;

    const ffi_struct = harness.core("ffi/struct");
    const ffi_signature = harness.core("ffi/signature");
    const ffi_call_fn = harness.core("ffi/call");

    var pair = [_]c.Janet{ c.janet_ckeywordv("float"), c.janet_ckeywordv("float") };
    const hfa = ffi_struct(2, &pair) catch @panic("ffi_core: ffi/struct raised");

    // Outgoing: 1.5 in the first vector register and 2.5 in the second, so the
    // callee's weighted sum is 1.5 + 5. Sized by bytes it was one register,
    // the second member was never written, and the sum was 1.5.
    {
        var types = [_]c.Janet{ c.janet_ckeywordv("default"), c.janet_ckeywordv("double"), hfa };
        const sig = ffi_signature(3, &types) catch @panic("ffi_core: ffi/signature raised");

        const members = c.janet_tuple_begin(2);
        members[0] = c.janet_wrap_number(1.5);
        members[1] = c.janet_wrap_number(2.5);
        var args = [_]c.Janet{
            c.janet_wrap_pointer(@ptrCast(@constCast(&hfa2Weighted))),
            sig,
            c.janet_wrap_tuple(c.janet_tuple_end(members)),
        };
        const answer = ffi_call_fn(3, &args) catch @panic("ffi_core: ffi/call raised");
        assert(harness.isType(answer, c.JANET_NUMBER));
        assert(c.janet_unwrap_number(answer) == 6.5);
    }

    // Returning: each member arrives in its own register, eight bytes apart,
    // and the type's own layout is four. Read without gathering, the second
    // member is the first register's unused half.
    {
        var types = [_]c.Janet{ c.janet_ckeywordv("default"), hfa, c.janet_ckeywordv("float") };
        const sig = ffi_signature(3, &types) catch @panic("ffi_core: ffi/signature raised");

        var args = [_]c.Janet{
            c.janet_wrap_pointer(@ptrCast(@constCast(&hfa2Build))),
            sig,
            c.janet_wrap_number(1.5),
        };
        const answer = ffi_call_fn(3, &args) catch @panic("ffi_core: ffi/call raised");
        assert(harness.isType(answer, c.JANET_TUPLE));
        const built = c.janet_unwrap_tuple(answer);
        assert(c.janet_tuple_length(built) == 2);
        assert(c.janet_unwrap_number(built[0]) == 1.5);
        assert(c.janet_unwrap_number(built[1]) == 2.5);
    }
}

/// Whether `ffi/calling-conventions` names `want`. A convention a build cannot
/// call is still describable, so asking the binding is the only way to know
/// which one `:default` will resolve to.
fn supports(want: [*:0]const u8) bool {
    const conventions = harness.core("ffi/calling-conventions");
    const listed = conventions(0, null) catch return false;
    if (!harness.isType(listed, c.JANET_ARRAY)) return false;
    const array = c.janet_unwrap_array(listed);
    var i: i32 = 0;
    while (i < array.*.count) : (i += 1) {
        if (harness.keywordIs(array.*.data[@intCast(i)], want)) return true;
    }
    return false;
}

// ------------------------------------------- an aggregate behind a stack argument

const Large24 = extern struct { x: i64, y: i64, z: i64 };

/// Nine integers exhaust the general registers and put one word on the stack,
/// so the aggregate behind them is passed by reference with its pointer slot at
/// a *nonzero* stack offset. That is the whole condition: at offset zero the
/// byte offset and the same number read as a word index agree by accident.
/// The weighted sum comes back as a `double` rather than an `int64` so that
/// the case reads its answer with `janet_unwrap_number`. `janet_unwrap_s64` is
/// declared only under `JANET_INT_TYPES`, and `-Dint-types=false` is a matrix
/// entry — which is where the first version of this case failed to compile.
/// Nothing here is about the return: every weight is small and exact in a
/// `double`.
fn stackRefWeighted(
    p0: i64,
    p1: i64,
    p2: i64,
    p3: i64,
    p4: i64,
    p5: i64,
    p6: i64,
    p7: i64,
    p8: i64,
    s: Large24,
) callconv(.c) f64 {
    const total = p0 * 1 + p1 * 2 + p2 * 3 + p3 * 4 + p4 * 5 + p5 * 6 + p6 * 7 +
        p7 * 8 + p8 * 9 + s.x * 10 + s.y * 11 + s.z * 12;
    return @floatFromInt(total);
}

/// `AAPCS64_STACK_REF` read a byte offset as a word index, so the pointer to
/// the payload was written eight times further out than the allocator planned
/// — past the frame in C, and into the wrong slot here. The callee then
/// dereferenced whatever was at the right offset, which on this host is zero.
///
/// It hid behind an accident, and this case is built to defeat it: with no
/// stack argument ahead of the aggregate the offset is zero and both readings
/// agree.
fn anAggregateBehindAStackArgument() void {
    if (!supports("aapcs64")) return;

    const ffi_struct = harness.core("ffi/struct");
    const ffi_signature = harness.core("ffi/signature");
    const ffi_call_fn = harness.core("ffi/call");

    var members = [_]c.Janet{
        c.janet_ckeywordv("int64"),
        c.janet_ckeywordv("int64"),
        c.janet_ckeywordv("int64"),
    };
    const large = ffi_struct(3, &members) catch @panic("ffi_core: ffi/struct raised");

    var types: [12]c.Janet = undefined;
    types[0] = c.janet_ckeywordv("default");
    types[1] = c.janet_ckeywordv("double");
    for (types[2..11]) |*t| t.* = c.janet_ckeywordv("int64");
    types[11] = large;
    const sig = ffi_signature(12, &types) catch @panic("ffi_core: ffi/signature raised");

    const payload = c.janet_tuple_begin(3);
    payload[0] = harness.wrapInteger(11);
    payload[1] = harness.wrapInteger(22);
    payload[2] = harness.wrapInteger(33);

    var args: [12]c.Janet = undefined;
    args[0] = c.janet_wrap_pointer(@ptrCast(@constCast(&stackRefWeighted)));
    args[1] = sig;
    for (args[2..11], 1..) |*a, n| a.* = harness.wrapInteger(@intCast(n));
    args[11] = c.janet_wrap_tuple(c.janet_tuple_end(payload));

    const answer = ffi_call_fn(12, &args) catch @panic("ffi_core: ffi/call raised");
    // The nine integers weighted 1..9 are the sum of the squares, 285; the
    // three members weighted 10..12 are 110 + 242 + 396.
    assert(harness.isType(answer, c.JANET_NUMBER));
    assert(c.janet_unwrap_number(answer) == 285 + 748);
}

// ------------------------------------------------- the signature arity bound

/// The one-line repair `FOUND.md` carried as its only agreed-but-unmade fix,
/// taken in Phase 11 Part 17 and a deliberate divergence from upstream.
///
/// A `Signature` stores `max_args` mappings and the builder filled them for
/// every argument passed, with only a lower bound on the arity. Past the
/// thirty-second the writes went off the end of two stack arrays and into the
/// builder's own frame — a safety trap in a checked build and a silent overrun
/// in `ReleaseFast` — and the count recorded in the abstract was one no array
/// could hold, so a later `ffi/call` read past the end as well. No native
/// library and no call were needed to reach it: `ffi/signature` only describes
/// a call.
///
/// **Thirty-two is written out rather than read from `types.max_args`**, on
/// rule 46: the limit is a value a Janet program can observe, and asking the
/// subject how many arguments it accepts would pass whatever it answered.
///
/// `:none` rather than `:default` because the arity check runs before any
/// convention is consulted, so this covers the guard on every host — including
/// one whose only convention is `:none`.
fn theSignatureArityBound() void {
    const signature = harness.core("ffi/signature");
    var argv: [42]c.Janet = undefined;
    argv[0] = c.janet_ckeywordv("none");
    argv[1] = c.janet_ckeywordv("void");
    for (argv[2..]) |*a| a.* = c.janet_ckeywordv("s64");

    // Thirty-two argument types is exactly what the structure holds, so the
    // bound admits it. The two leading arguments are the convention and the
    // return type, which is why the arity the message names is thirty-four.
    const full = signature(34, &argv) catch @panic("ffi_core: 32 arguments were refused");
    assert(harness.isType(full, c.JANET_ABSTRACT));

    // One more is refused as an ordinary arity error rather than a corrupted
    // frame, and so is a signature far past the bound.
    expectRaise(signature, .{ @as(i32, 35), &argv }, "arity mismatch, expected at most 34, got 35");
    expectRaise(signature, .{ @as(i32, 42), &argv }, "arity mismatch, expected at most 34, got 42");
}

pub fn run() void {
    _ = c.janet_init();

    registration();
    primTable();
    abstractTypes();
    callbackWithoutUserdata();
    outgoingSplit();
    ceilingIsReachableOnlyOnSysv();
    theRaises();
    theSignatureArityBound();
    homogeneousFloatAggregates();
    anAggregateBehindAStackArgument();

    std.debug.print("ffi_core contract ok ({d} raises)\n", .{raises_seen});
    c.janet_deinit();
}
