//! Behavioral contract for the FFI's type system, marshalling, calling
//! machinery and nfunction surface.
//!
//! ## What the Janet suites cannot reach
//!
//! `test/suite-ffi.wattle` exercises the type system and a spike corpus drives
//! real calls against real C. Six things have no Janet spelling:
//!
//!  - The primitive size and alignment table. `ffi_types.zig`'s `primInfo` is
//!    a restatement of the host's own numbers, and a restatement is a place
//!    two descriptions can drift apart. Every entry is checked below against
//!    the type it names, which is the argument `test/ffi_layout.zig` makes
//!    for the struct layout machine.
//!  - The abstract types' callback sets. `core/ffi-struct` and
//!    `core/ffi-signature` have a mark callback and no other; `core/ffi-native`
//!    has none at all. From Janet only the *name* is visible, through
//!    `(type x)`. That the `get`, `put`, `call` and `next` slots are null is
//!    what makes these values opaque, and it is invisible from the language.
//!  - The callback entry with no userdata. Every callback ends there, and its
//!    first act is to check for a null `userdata` and complain. A Janet
//!    program reaches it only through a C library calling back, which always
//!    passes the pointer it was given, so the null arm is unreachable from
//!    the language and reachable in one line from here.
//!  - The outgoing half of the frame. `AllocResult` has `arg_stack_count`
//!    because a Zig caller declares the outgoing stack words as function
//!    parameters and must not count the by-reference payloads that follow
//!    them. Nothing in Janet can observe the split; the allocators can be
//!    asked directly.
//!  - The rung ceiling. Past 1024 words of outgoing arguments there is no
//!    function type to call through, and `ffi/signature` reports it. Only
//!    SysV64 can reach it, so the assertion is on the allocator rather than
//!    on a call this host could make.
//!  - The failure messages. A raise is asserted here by its *message*, which
//!    is the difference between a test and a tautology.
//!
//! ## Where the oracles come from
//!
//! The alignment oracle is built here rather than borrowed. `alignOfMember`
//! asks what offset a member of the type takes after one byte, which is a
//! question about struct layout. `@alignOf(T)` is the direct question, and it
//! is also the expression `primInfo` itself uses, so asking it here would
//! compare `primInfo` with itself. The pairing `alignOfMember` checks, that
//! this name means this machine type, is what the table encodes.
//!
//! The callees the calling cases use are functions in this file. A contract
//! is compiled into the runtime, so it can hand `ffi/call` the address of one
//! of them and make a real call with no shared library anywhere.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const buffers = @import("subsystems").value.buffers;
const config = @import("config");
const constants = @import("constants");
const core_env = @import("subsystems").env;
const expect = @import("expect.zig").expect;
const ffi_call = subsystems.ffi_call;
const ffi_classify = subsystems.ffi_classify;
const ffi_types = subsystems.ffi_types;
const gc_alloc = @import("subsystems").gc_alloc;
const gc_mark = @import("subsystems").gc_mark;
const harness = @import("harness.zig");
const repr = @import("repr");
const subsystems = @import("subsystems");
const tuples = @import("subsystems").value.tuples;
const utils = @import("subsystems").utils;
const value = @import("subsystems").value;
const vm_lifecycle = @import("subsystems").lifecycle;
const wrap = @import("subsystems").value.wrap;

// ==========================================================================
// Constants
// ==========================================================================

/// Every name `ffi.libFfi` registers. A binding that stops being registered
/// is what this catches: a registration table is the one place an nfunction
/// can go missing without a link error.
const ffi_bindings = [_][*:0]const u8{
    "ffi/native",              "ffi/lookup", "ffi/close",          "ffi/signature",
    "ffi/call",                "ffi/struct", "ffi/write",          "ffi/read",
    "ffi/size",                "ffi/align",  "ffi/trampoline",     "ffi/jitfn",
    "ffi/malloc",              "ffi/free",   "ffi/pointer-buffer", "ffi/pointer-nfunction",
    "ffi/calling-conventions",
};

/// Whether dynamic modules were compiled in. `build.zig` turns them off for
/// every executable that cannot load a library, static musl and WASI, so for
/// any executable the build makes this is also whether loading works.
const has_dynamic_modules = config.dynamic_modules;

/// The `types.PrimType` and `types.Spec` ordinals these cases name, copied
/// out rather than imported so that the assertions have an oracle
/// independent of the enumerations they check.
const prim_int64: u32 = 12;
const prim_struct: u32 = 14;
const sysv64_integer: u32 = 0;
const sysv64_memory: u32 = 8;
const win64_register: u32 = 9;
const aapcs64_general: u32 = 13;
const aapcs64_general_ref: u32 = 15;

/// How many refusals the run has read the message of. Printed at the end, so
/// that a case quietly ceasing to raise is visible.
var raises_seen: u32 = 0;

// ==========================================================================
// Aliased types
// ==========================================================================

const AllocResult = ffi_classify.AllocResult;
const ArgSlot = ffi_classify.ArgSlot;

// ==========================================================================
// Cases
// ==========================================================================

/// A refusal, by the message it reports. Reading the message is what
/// distinguishes "it refused" from "it refused for the reason this case is
/// about", and every one of these messages is a line of `ffi_types.zig`,
/// `ffi_marshal.zig` or `ffi_call.zig` that nothing else reaches.
fn expectRaise(function: anytype, args: anytype, message: []const u8) void {
    const raise = harness.raised(function, args) orelse {
        std.debug.panic("ffi_core: expected a raise, got a return: {s}\n", .{message});
    };
    expect(raise.signal == abi.Signal.@"error");
    expect(raise.says(message));
    raises_seen += 1;
}

/// The same for a message only some of which is reproducible: a refusal that
/// names an abstract renders its address.
fn expectRaisePrefix(function: anytype, args: anytype, prefix: []const u8) void {
    const raise = harness.raised(function, args) orelse {
        std.debug.panic("ffi_core: expected a raise, got a return: {s}\n", .{prefix});
    };
    expect(raise.signal == abi.Signal.@"error");
    expect(raise.beginsWith(prefix));
    raises_seen += 1;
}

/// Evaluate `source` in the core environment and give back its value.
fn eval(source: [*:0]const u8) repr.Value {
    var out = wrap.fromNil();
    const env = harness.coreEnv();
    expect(core_env.dostring(env, source, "ffi_core", &out) == 0);
    return out;
}

/// One allocated argument, as a convention reports it.
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

/// Whether `ffi/calling-conventions` names `want`. A convention a build
/// cannot call is still describable, so asking the binding is the only way to
/// tell which one `:default` will resolve to.
fn supports(want: [*:0]const u8) bool {
    const conventions = harness.core("ffi/calling-conventions");
    const listed = conventions(&.{}) catch return false;
    if (!harness.isType(listed, repr.Tag.array)) return false;
    const array = wrap.toArray(listed);
    var i: i32 = 0;
    while (i < array.count) : (i += 1) {
        if (harness.keywordIs(array.slice()[@intCast(i)], want)) return true;
    }
    return false;
}

fn registration() void {
    expect(ffi_bindings.len == 17);
    // `harness.core` asserts the binding resolves to an nfunction, so reaching
    // the end of the loop is the assertion.
    for (ffi_bindings) |name| _ = harness.core(name);
}

/// The offset a member of this type takes after one byte, which is the
/// alignment read off a struct layout rather than asked for directly.
fn alignOfMember(comptime T: type) usize {
    return @offsetOf(extern struct { leading: u8, member: T }, "member");
}

/// One row of the table: the keyword a Janet program writes, and the size and
/// alignment the host gives the type it names.
const PrimCase = struct { name: [*:0]const u8, size: usize, alignment: usize };

/// A row built from the Zig type the keyword stands for, so that the two
/// numbers come from the compiler rather than from `primInfo`.
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
        primCase("string", [*]u8),
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
    expect(cases.len == 36);

    const size_of = harness.core("ffi/size");
    const align_of = harness.core("ffi/align");
    for (cases) |case| {
        var arg = value.fromBytes(std.mem.span(case.name), .keyword);
        const size = size_of((&arg)[0..1]) catch @panic("ffi_core: ffi/size raised");
        const alignment = align_of((&arg)[0..1]) catch @panic("ffi_core: ffi/align raised");
        expect(wrap.toNumber(size) == @as(f64, @floatFromInt(case.size)));
        expect(wrap.toNumber(alignment) == @as(f64, @floatFromInt(case.alignment)));
    }
}

/// The callback set of the abstract behind `expr`, checked slot by slot. Only
/// `name` is visible from Janet, and only through `(type x)`.
///
/// What is read is the stored form, the `type` pointer in the value's own
/// head, rather than the `abstract_type.AbstractType` these are declared as.
/// It is the same memory, and it is the view every other reader of an
/// abstract sees.
fn expectShape(
    expr: [*:0]const u8,
    name: [*:0]const u8,
    has_gc: bool,
    has_gcmark: bool,
    has_bytes: bool,
    has_length: bool,
) void {
    const val = eval(expr);
    expect(harness.isType(val, repr.Tag.abstract));
    const at = abi.abstractHead(wrap.toAbstract(val)).type;
    // `std.mem.eql` over a span, not `utils.cstrcmp`: an abstract type's
    // `name` is a Zig slice and `cstrcmp` takes two sentinel-terminated
    // pointers, so the parameter is spanned and the two compared as slices.
    expect(std.mem.eql(u8, at.name, std.mem.span(name)));
    expect((at.gc != null) == has_gc);
    expect((at.gcmark != null) == has_gcmark);
    expect((at.bytes != null) == has_bytes);
    expect((at.length != null) == has_length);
    // Everything else is null in all of these types, which is what makes them
    // opaque: no indexing, no method call, no comparison, no hashing.
    expect(at.get == null);
    expect(at.put == null);
    expect(at.marshal == null);
    expect(at.unmarshal == null);
    expect(at.tostring == null);
    expect(at.compare == null);
    expect(at.hash == null);
    expect(at.next == null);
    expect(at.call == null);
}

fn abstractTypes() void {
    expectShape("(ffi/struct :int32 :double)", "core/ffi-struct", false, true, false, false);
    expectShape("(ffi/signature :none :void :int32)", "core/ffi-signature", false, true, false, false);
    if (has_dynamic_modules) {
        expectShape("(ffi/native)", "core/ffi-native", false, false, false, false);
    }
}

/// The null-userdata arm, which no Janet program can produce: a C library
/// always passes back the pointer it was handed. It complains and returns
/// rather than raising, so reaching it at all is the assertion.
fn callbackWithoutUserdata() void {
    ffi_call.callbackEntry(null, null);
}

/// A by-reference payload is part of the frame and is *not* an outgoing
/// argument, and only the split tells a caller how many parameters to
/// declare. Win64 and AAPCS64 both have a payload area; SysV64 has none, and
/// its two counts are therefore equal.
fn outgoingSplit() void {
    var args: [16]ArgSlot = undefined;
    var ret: ArgSlot = undefined;
    var result: AllocResult = undefined;

    // Ten integers on Win64: four in registers, six on the stack, no payloads.
    // The two counts agree because nothing was passed by reference.
    ret = slot(prim_int64, win64_register, 8, 8);
    for (args[0..10]) |*a| a.* = slot(prim_int64, win64_register, 8, 8);
    ffi_classify.allocWin64(&result, &ret, args[0..10]);
    expect(result.error_kind == 0);
    expect(result.arg_stack_count == 6);
    expect(result.stack_count == 6);

    // The same with three oversized aggregates, which Win64 passes by
    // reference: each takes one outgoing word and a payload behind it, so the
    // frame grows and the outgoing count does not.
    ret = slot(prim_int64, win64_register, 8, 8);
    for (args[0..10]) |*a| a.* = slot(prim_int64, win64_register, 8, 8);
    for (args[10..13]) |*a| a.* = slot(prim_struct, win64_register, 64, 8);
    ffi_classify.allocWin64(&result, &ret, args[0..13]);
    expect(result.error_kind == 0);
    expect(result.arg_stack_count == 9);
    expect(result.stack_count > result.arg_stack_count);

    // SysV64 has no payload area at all: an aggregate that does not fit in
    // registers goes onto the stack whole.
    ret = slot(prim_int64, sysv64_integer, 8, 8);
    for (args[0..8]) |*a| a.* = slot(prim_int64, sysv64_integer, 8, 8);
    args[8] = slot(prim_struct, sysv64_memory, 64, 8);
    ffi_classify.allocSysv64(&result, &ret, args[0..9]);
    expect(result.error_kind == 0);
    expect(result.stack_count == result.arg_stack_count);
    expect(result.arg_stack_count == 2 + 8);

    // AAPCS64 counts its frame in bytes and its outgoing half in words.
    ret = slot(prim_int64, aapcs64_general, 8, 8);
    for (args[0..12]) |*a| a.* = slot(prim_int64, aapcs64_general, 8, 8);
    ffi_classify.allocAapcs64(&result, &ret, args[0..12], false, 128);
    expect(result.error_kind == 0);
    expect(result.arg_stack_count == 4);
    expect(result.stack_count == 32);
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
    expect(result.error_kind == 0);
    expect(result.arg_stack_count == 2000);

    // The same aggregate on AAPCS64 is one word, however large it gets.
    ret = slot(prim_int64, aapcs64_general, 8, 8);
    args[0] = slot(prim_struct, aapcs64_general_ref, 16000, 8);
    ffi_classify.allocAapcs64(&result, &ret, args[0..1], false, 128);
    expect(result.error_kind == 0);
    expect(result.arg_stack_count == 0);
}

fn theRaises() void {
    var argv: [4]repr.Value = undefined;

    const ffi_struct = harness.core("ffi/struct");
    const ffi_size = harness.core("ffi/size");
    const ffi_signature = harness.core("ffi/signature");
    const ffi_call_fn = harness.core("ffi/call");
    const ffi_read = harness.core("ffi/read");
    const ffi_write = harness.core("ffi/write");

    expectRaise(ffi_struct, .{&.{}}, "arity mismatch, expected at least 1, got 0");
    expectRaise(ffi_size, .{&.{}}, "arity mismatch, expected 1, got 0");

    argv[0] = value.fromBytes("nonesuch", .keyword);
    expectRaise(ffi_size, .{argv[0..1]}, "unknown machine type nonesuch");

    argv[0] = harness.wrapInteger(7);
    expectRaise(ffi_size, .{argv[0..1]}, "bad native type 7");

    argv[0] = eval("![:int32 1 2]");
    expectRaisePrefix(ffi_size, .{argv[0..1]}, "array type must be of form ![type count], got ");

    // A nested array type is refused rather than flattened. A type has room
    // for one array count, so assigning the outer one over the inner leaves
    // `![![:u8 4] 3]` three bytes wide rather than twelve, a quarter of the
    // size the expression names, and as a struct field that moves every later
    // field's offset. The message names the spelling that works.
    argv[0] = eval("![:u8 4]");
    expect(wrap.toNumber(ffi_size(argv[0..1]) catch @panic("ffi_core: ffi/size raised")) == 4);
    argv[0] = eval("![![:u8 4] 3]");
    expectRaisePrefix(ffi_size, .{argv[0..1]}, "nested array type ");
    // The struct of inner arrays is the working spelling, and it is twelve.
    argv[0] = eval("![[:u8 :u8 :u8 :u8] 3]");
    expect(wrap.toNumber(ffi_size(argv[0..1]) catch @panic("ffi_core: ffi/size raised")) == 12);
    // An inner array of count zero is an array too.
    argv[0] = eval("![![:u8] 3]");
    expectRaisePrefix(ffi_size, .{argv[0..1]}, "nested array type ");

    // `:none` has no trampoline, and naming it is refused rather than read as
    // the default.
    argv[0] = value.fromBytes("none", .keyword);
    expectRaise(harness.core("ffi/trampoline"), .{argv[0..1]}, "calling convention not supported");

    // A raw pointer cannot become an nfunction. Every pointer this can be
    // given is a C function, and an nfunction here takes a `[]Value` over
    // Zig's own calling convention, so no conversion between the two is
    // possible. The argument is still checked, which is what the second case
    // says.
    const pointer_nfunction = harness.core("ffi/pointer-nfunction");
    // The pointer is taken here rather than looked up through `ffi/native`.
    // A release build of this driver need not put its own symbols in the
    // dynamic symbol table, and `ffi/lookup` then gives nil, which would
    // make the case about a nil argument instead. That is what the second
    // case below is for. Any C function's address is the shape the argument
    // is meant to have, and `asS8` is one this file already defines.
    argv[0] = wrap.fromPointer(@ptrCast(@constCast(&asS8)));
    expectRaise(
        pointer_nfunction,
        .{argv[0..1]},
        "a raw pointer cannot become an nfunction; use ffi/signature and ffi/call",
    );
    argv[0] = harness.wrapInteger(7);
    expectRaise(pointer_nfunction, .{argv[0..1]}, "bad slot #0, expected pointer, got 7");

    // A struct of one void member: the void type has no alignment, which is
    // the `el_align == 0` arm of the layout loop.
    argv[0] = value.fromBytes("void", .keyword);
    expectRaise(ffi_struct, .{argv[0..1]}, "bad field type void");

    argv[0] = value.fromBytes("nonesuch", .keyword);
    argv[1] = value.fromBytes("void", .keyword);
    expectRaise(ffi_signature, .{argv[0..2]}, "unknown calling convention nonesuch");

    // `:none` describes but cannot call.
    {
        argv[0] = value.fromBytes("none", .keyword);
        argv[1] = value.fromBytes("void", .keyword);
        const sig = ffi_signature(argv[0..2]) catch @panic("ffi_core: ffi/signature raised");
        var call_argv: [2]repr.Value = undefined;
        call_argv[0] = wrap.fromPointer(@ptrCast(@constCast(&theRaises)));
        call_argv[1] = sig;
        expectRaise(ffi_call_fn, .{call_argv[0..2]}, "calling convention not supported");
    }

    // A callable pointer is a pointer or a jitfn, and nothing else.
    {
        var call_argv: [2]repr.Value = undefined;
        call_argv[0] = harness.wrapInteger(7);
        call_argv[1] = eval("(ffi/signature :none :void)");
        expectRaise(
            ffi_call_fn,
            .{call_argv[0..2]},
            "bad slot #0, expected ffi callable pointer type, got 7",
        );
    }

    // Reading past the end of a byte source.
    argv[0] = value.fromBytes("int64", .keyword);
    argv[1] = value.fromBytes("abc", .string);
    expectRaise(ffi_read, .{argv[0..2]}, "read out of range");

    // Writing at an index beyond the buffer's own count.
    argv[0] = value.fromBytes("int32", .keyword);
    argv[1] = harness.wrapInteger(1);
    argv[2] = wrap.fromBuffer(buffers.new(8));
    argv[3] = harness.wrapInteger(4);
    expectRaise(ffi_write, .{argv[0..4]}, "index out of bounds");

    // A struct written with the wrong number of fields, and an array with the
    // wrong length. Both are shape faults the marshaller reports.
    argv[0] = eval("(ffi/struct :int32 :int32)");
    argv[1] = eval("[1 2 3]");
    expectRaise(ffi_write, .{argv[0..2]}, "wrong number of fields in struct, expected 2, got 3");

    argv[0] = eval("![:int32 3]");
    argv[1] = eval("[1 2]");
    expectRaise(ffi_write, .{argv[0..2]}, "bad array length, expected 3, got 2");

    // `:void` writes only nil.
    argv[0] = value.fromBytes("void", .keyword);
    argv[1] = harness.wrapInteger(1);
    expectRaise(ffi_write, .{argv[0..2]}, "expected nil, got 1");

    // A native object closed twice, and the running binary refusing to close.
    //
    // Without dynamic modules there is no native object to have: `Clib`
    // reduces to an `int` and `load_clib` to a no-op returning zero, so
    // `ffi/native` always raises. That arm is the whole of this section in
    // such a build, and it is a real arm. A static musl build with dynamic
    // modules on, whose loader would refuse with its own message, is a build
    // error rather than a third arm.
    if (has_dynamic_modules) {
        const self = eval("(ffi/native)");
        gc_alloc.gcroot(self);
        var self_argv = [_]repr.Value{self};
        expectRaise(harness.core("ffi/close"), .{self_argv[0..1]}, "cannot close self");
        {
            var lookup = [_]repr.Value{ self, value.fromBytes("a_symbol_that_does_not_exist", .string) };
            const found = harness.core("ffi/lookup")(lookup[0..2]) catch
                @panic("ffi_core: ffi/lookup raised");
            expect(harness.isType(found, repr.Tag.nil));
        }
        _ = gc_alloc.gcunroot(self);
    } else {
        expectRaise(harness.core("ffi/native"), .{&.{}}, "dynamic modules not supported");
    }
}

/// The arity bound, and a deliberate divergence from Janet.
///
/// A `Signature` stores `max_args` mappings, and a builder that fills one per
/// argument for a call with only a lower bound on its arity would run past
/// them, writing off the end of two stack arrays and into its own frame and
/// recording a count in the abstract that no array is large enough for.
/// `ffi/signature`
/// only describes a call, so no native library and no call are needed to
/// reach the guard.
///
/// Thirty-two is written out rather than read from `ffi/types.zig`: the limit
/// is a value a Janet program can observe, and asking the subject how many
/// arguments it accepts would pass whatever it said.
///
/// `:none` rather than `:default`, because the arity check runs before any
/// convention is consulted, so this covers the guard on every host, including
/// one whose only convention is `:none`.
fn theSignatureArityBound() void {
    const signature = harness.core("ffi/signature");
    var argv: [42]repr.Value = undefined;
    argv[0] = value.fromBytes("none", .keyword);
    argv[1] = value.fromBytes("void", .keyword);
    for (argv[2..]) |*a| a.* = value.fromBytes("s64", .keyword);

    // Thirty-two argument types is exactly the structure's room, so the bound
    // admits it. The two leading arguments are the convention and the return
    // type, so the arity the message names is thirty-four.
    const full = signature(argv[0..34]) catch @panic("ffi_core: 32 arguments were refused");
    expect(harness.isType(full, repr.Tag.abstract));

    // One more is refused as an ordinary arity error rather than a corrupted
    // frame, and so is a signature far past the bound.
    expectRaise(signature, .{argv[0..35]}, "arity mismatch, expected at most 34, got 35");
    expectRaise(signature, .{argv[0..42]}, "arity mismatch, expected at most 34, got 42");
}

/// A two-member homogeneous floating-point aggregate, and the two callees the
/// case below calls with it.
const Hfa2 = extern struct { a: f32, b: f32 };

fn hfa2Weighted(s: Hfa2) callconv(.c) f64 {
    return @as(f64, s.a) * 1 + @as(f64, s.b) * 2;
}

fn hfa2Build(seed: f32) callconv(.c) Hfa2 {
    return .{ .a = seed, .b = seed + 1 };
}

/// An aggregate of one float, which travels in one vector register like the
/// scalar it holds.
const Hfa1 = extern struct { a: f32 };

fn hfa1Twice(s: Hfa1) callconv(.c) f64 {
    return @as(f64, s.a) * 2;
}

/// The double arrives in the register after the aggregate's two.
fn hfa2ThenDouble(s: Hfa2, d: f64) callconv(.c) f64 {
    return @as(f64, s.a) + @as(f64, s.b) * 2 + d * 4;
}

/// AAPCS64 passes a homogeneous floating-point aggregate in one vector
/// register per member. Sizing it by bytes agrees with that only for a member
/// exactly eight bytes wide, so an aggregate of `double` comes out right by
/// coincidence and one of `float` is given half the registers, with two
/// members packed into the first.
///
/// The return is the same question read backwards: each member comes back in
/// its own register, so a two-float aggregate gathered by bytes arrives as
/// `(1.5 0)`. Both directions are asserted here.
///
/// Gated on the convention rather than on `builtin`, because what matters is
/// which convention `:default` resolves to.
fn homogeneousFloatAggregates() void {
    if (!supports("aapcs64")) return;

    const ffi_struct = harness.core("ffi/struct");
    const ffi_signature = harness.core("ffi/signature");
    const ffi_call_fn = harness.core("ffi/call");

    var pair = [_]repr.Value{ value.fromBytes("float", .keyword), value.fromBytes("float", .keyword) };
    const hfa = ffi_struct(pair[0..2]) catch @panic("ffi_core: ffi/struct raised");

    // Outgoing: 1.5 in the first vector register and 2.5 in the second, so the
    // callee's weighted sum is 1.5 + 5. Sized by bytes it was one register,
    // the second member was never written, and the sum was 1.5.
    {
        var argtypes = [_]repr.Value{ value.fromBytes("default", .keyword), value.fromBytes("double", .keyword), hfa };
        const sig = ffi_signature(argtypes[0..3]) catch @panic("ffi_core: ffi/signature raised");

        const members = tuples.begin(2);
        members[0] = wrap.fromNumber(1.5);
        members[1] = wrap.fromNumber(2.5);
        var args = [_]repr.Value{
            wrap.fromPointer(@ptrCast(@constCast(&hfa2Weighted))),
            sig,
            wrap.fromTuple(tuples.end(members)),
        };
        const answer = ffi_call_fn(args[0..3]) catch @panic("ffi_core: ffi/call raised");
        expect(harness.isType(answer, repr.Tag.number));
        expect(wrap.toNumber(answer) == 6.5);
    }

    // Returning: each member arrives in its own register, eight bytes apart,
    // and the type's own layout is four. Read without gathering, the second
    // member is the first register's unused half.
    {
        var argtypes = [_]repr.Value{ value.fromBytes("default", .keyword), hfa, value.fromBytes("float", .keyword) };
        const sig = ffi_signature(argtypes[0..3]) catch @panic("ffi_core: ffi/signature raised");

        var args = [_]repr.Value{
            wrap.fromPointer(@ptrCast(@constCast(&hfa2Build))),
            sig,
            wrap.fromNumber(1.5),
        };
        const answer = ffi_call_fn(args[0..3]) catch @panic("ffi_core: ffi/call raised");
        expect(harness.isIndexed(answer));
        const built = harness.elems(answer);
        expect(built.len == 2);
        expect(wrap.toNumber(built[0]) == 1.5);
        expect(wrap.toNumber(built[1]) == 2.5);
    }

    // One member is written straight into its register, with nothing to
    // scatter.
    {
        var one = [_]repr.Value{value.fromBytes("float", .keyword)};
        const hfa1 = ffi_struct(one[0..1]) catch @panic("ffi_core: ffi/struct raised");
        var argtypes = [_]repr.Value{ value.fromBytes("default", .keyword), value.fromBytes("double", .keyword), hfa1 };
        const sig = ffi_signature(argtypes[0..3]) catch @panic("ffi_core: ffi/signature raised");

        const members = tuples.begin(1);
        members[0] = wrap.fromNumber(1.5);
        var args = [_]repr.Value{
            wrap.fromPointer(@ptrCast(@constCast(&hfa1Twice))),
            sig,
            wrap.fromTuple(tuples.end(members)),
        };
        const answer = ffi_call_fn(args[0..3]) catch @panic("ffi_core: ffi/call raised");
        expect(wrap.toNumber(answer) == 3);
    }

    // A scalar behind a two-float aggregate takes the third vector register,
    // because the aggregate takes one per member.
    {
        var argtypes = [_]repr.Value{
            value.fromBytes("default", .keyword),
            value.fromBytes("double", .keyword),
            hfa,
            value.fromBytes("double", .keyword),
        };
        const sig = ffi_signature(argtypes[0..4]) catch @panic("ffi_core: ffi/signature raised");

        const members = tuples.begin(2);
        members[0] = wrap.fromNumber(1.5);
        members[1] = wrap.fromNumber(2.5);
        var args = [_]repr.Value{
            wrap.fromPointer(@ptrCast(@constCast(&hfa2ThenDouble))),
            sig,
            wrap.fromTuple(tuples.end(members)),
            wrap.fromNumber(10),
        };
        const answer = ffi_call_fn(args[0..4]) catch @panic("ffi_core: ffi/call raised");
        expect(wrap.toNumber(answer) == 1.5 + 5 + 40);
    }
}

/// The callees. Each widens its own narrow parameter, so what it returns is
/// what the *register* contained for the width the signature declared.
fn asS8(x: i8) callconv(.c) f64 {
    return @floatFromInt(x);
}

fn asU8(x: u8) callconv(.c) f64 {
    return @floatFromInt(x);
}

fn asS16(x: i16) callconv(.c) f64 {
    return @floatFromInt(x);
}

fn asU16(x: u16) callconv(.c) f64 {
    return @floatFromInt(x);
}

fn asBool(x: bool) callconv(.c) f64 {
    return if (x) 1 else 0;
}

/// An integer narrower than a register is extended into it.
///
/// Both AAPCS64 and the SysV ABI make extension the caller's job: a callee
/// declaring `int8_t` may read the whole register without masking. Writing
/// the value at its own width sets one byte and leaves the other seven as
/// they were, so `:s8` of -1 arrives as 255 where the bank is zeroed and as
/// stack residue where it is not. A callee that masks its own argument is
/// correct either way, which is what lets the defect survive casual testing;
/// these five do not mask.
fn narrowIntegerArgumentsAreExtended() void {
    const ffi_signature = harness.core("ffi/signature");
    const ffi_call_fn = harness.core("ffi/call");

    const Case = struct {
        callee: *const anyopaque,
        argtype: [*:0]const u8,
        given: repr.Value,
        want: f64,
    };
    const cases = [_]Case{
        .{ .callee = @ptrCast(&asS8), .argtype = "s8", .given = wrap.fromNumber(-1), .want = -1 },
        .{ .callee = @ptrCast(&asS8), .argtype = "s8", .given = wrap.fromNumber(127), .want = 127 },
        .{ .callee = @ptrCast(&asU8), .argtype = "u8", .given = wrap.fromNumber(255), .want = 255 },
        .{ .callee = @ptrCast(&asS16), .argtype = "s16", .given = wrap.fromNumber(-1), .want = -1 },
        .{ .callee = @ptrCast(&asS16), .argtype = "s16", .given = wrap.fromNumber(-32768), .want = -32768 },
        .{ .callee = @ptrCast(&asU16), .argtype = "u16", .given = wrap.fromNumber(65535), .want = 65535 },
        .{ .callee = @ptrCast(&asBool), .argtype = "bool", .given = wrap.fromTrue(), .want = 1 },
        .{ .callee = @ptrCast(&asBool), .argtype = "bool", .given = wrap.fromFalse(), .want = 0 },
    };

    for (cases) |case| {
        var argtypes = [_]repr.Value{
            value.fromBytes("default", .keyword),
            value.fromBytes("double", .keyword),
            value.fromBytes(std.mem.span(case.argtype), .keyword),
        };
        const sig = ffi_signature(argtypes[0..3]) catch @panic("ffi_core: ffi/signature raised");
        var args = [_]repr.Value{
            wrap.fromPointer(@constCast(case.callee)),
            sig,
            case.given,
        };
        const answer = ffi_call_fn(args[0..3]) catch @panic("ffi_core: ffi/call raised");
        expect(harness.isType(answer, repr.Tag.number));
        expect(wrap.toNumber(answer) == case.want);
    }
}

/// Nine integers exhaust the general registers and put one word on the stack,
/// so the aggregate behind them is passed by reference with its pointer slot
/// at a *nonzero* stack offset. That is the whole condition: at offset zero a
/// byte offset and the same number read as a word index agree by accident,
/// and only a nonzero offset separates the two readings.
///
/// The weighted sum comes back as a `double` rather than an `int64` so that
/// the case reads it with `wrap.toNumber`. `ints.unwrapS64` is compiled only
/// with integer types, and `-Dint-types=false` is a matrix entry. Nothing
/// here is about the return: every weight is small and exact in a `double`.
const Large24 = extern struct { x: i64, y: i64, z: i64 };

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

/// The pointer to a by-reference payload goes at a stack offset counted in
/// words, and this case is the one that can tell that from an offset counted
/// in bytes. With no stack argument ahead of the aggregate the offset is zero
/// and the two readings agree, so the aggregate is put behind a stack
/// argument and the offset is not zero.
fn anAggregateBehindAStackArgument() void {
    if (!supports("aapcs64")) return;

    const ffi_struct = harness.core("ffi/struct");
    const ffi_signature = harness.core("ffi/signature");
    const ffi_call_fn = harness.core("ffi/call");

    var members = [_]repr.Value{
        value.fromBytes("int64", .keyword),
        value.fromBytes("int64", .keyword),
        value.fromBytes("int64", .keyword),
    };
    const large = ffi_struct(members[0..3]) catch @panic("ffi_core: ffi/struct raised");

    var argtypes: [12]repr.Value = undefined;
    argtypes[0] = value.fromBytes("default", .keyword);
    argtypes[1] = value.fromBytes("double", .keyword);
    for (argtypes[2..11]) |*t| t.* = value.fromBytes("int64", .keyword);
    argtypes[11] = large;
    const sig = ffi_signature(argtypes[0..12]) catch @panic("ffi_core: ffi/signature raised");

    const payload = tuples.begin(3);
    payload[0] = harness.wrapInteger(11);
    payload[1] = harness.wrapInteger(22);
    payload[2] = harness.wrapInteger(33);

    var args: [12]repr.Value = undefined;
    args[0] = wrap.fromPointer(@ptrCast(@constCast(&stackRefWeighted)));
    args[1] = sig;
    for (args[2..11], 1..) |*a, n| a.* = harness.wrapInteger(@intCast(n));
    args[11] = wrap.fromTuple(tuples.end(payload));

    const answer = ffi_call_fn(args[0..12]) catch @panic("ffi_core: ffi/call raised");
    // The nine integers weighted 1..9 are the sum of the squares, 285; the
    // three members weighted 10..12 are 110 + 242 + 396.
    expect(harness.isType(answer, repr.Tag.number));
    expect(wrap.toNumber(answer) == 285 + 748);
}

/// A pair of doubles, which SysV64 classifies as two vector halves.
const Pair = extern struct { a: f64, b: f64 };

fn sixThenPair(d0: f64, d1: f64, d2: f64, d3: f64, d4: f64, d5: f64, p: Pair) callconv(.c) f64 {
    return d0 + d1 * 2 + d2 * 3 + d3 * 4 + d4 * 5 + d5 * 6 + p.a * 7 + p.b * 8;
}

/// Where the AMD64 ABI puts a pair that finds one vector register left: the
/// seven doubles in the first seven, the last unused, and the pair's halves in
/// the first two stack words. The parameters spell that out rather than take a
/// `Pair`, because Zig 0.16 lowers a `Pair` in this position as its first half
/// in the last vector register and its second on the stack, where a C
/// compiler reads both from the stack.
fn sevenThenPairOnTheStack(
    d0: f64,
    d1: f64,
    d2: f64,
    d3: f64,
    d4: f64,
    d5: f64,
    d6: f64,
    unused: f64,
    a: f64,
    b: f64,
) callconv(.c) f64 {
    _ = unused;
    return d0 + d1 * 2 + d2 * 3 + d3 * 4 + d4 * 5 + d5 * 6 + d6 * 7 + a * 8 + b * 9;
}

/// Behind six doubles the pair takes the last two vector registers, and
/// behind seven, with one left, it goes to the stack whole. `:sysv64` is
/// refused where the target does not enable it, so these calls run on x86-64
/// alone; `ffi_classify` asserts the placement on every target.
fn aVectorPairWithOneRegisterLeft() void {
    if (!supports("sysv64")) return;
    const ffi_call_fn = harness.core("ffi/call");
    const out = eval(
        \\[(ffi/signature :sysv64 :double |(array/new-filled 6 :double) [:double :double])
        \\ (ffi/signature :sysv64 :double |(array/new-filled 7 :double) [:double :double])
        \\ [7 8]
        \\ [8 9]]
    );
    gc_alloc.gcroot(out);
    defer _ = gc_alloc.gcunroot(out);
    const parts = harness.elems(out);

    var args: [10]repr.Value = undefined;
    for (args[2..9], 1..) |*a, n| a.* = wrap.fromNumber(@floatFromInt(n));

    args[0] = wrap.fromPointer(@ptrCast(@constCast(&sixThenPair)));
    args[1] = parts[0];
    args[8] = parts[2];
    const six = ffi_call_fn(args[0..9]) catch @panic("ffi_core: ffi/call raised");
    // 1 + 4 + ... + 36 is 91, and 7 * 7 + 8 * 8 is 113.
    expect(wrap.toNumber(six) == 91 + 113);

    args[0] = wrap.fromPointer(@ptrCast(@constCast(&sevenThenPairOnTheStack)));
    args[1] = parts[1];
    args[8] = wrap.fromNumber(7);
    args[9] = parts[3];
    const seven = ffi_call_fn(args[0..10]) catch @panic("ffi_core: ffi/call raised");
    // 1 + 4 + ... + 49 is 140, and 8 * 8 + 9 * 9 is 145.
    expect(wrap.toNumber(seven) == 140 + 145);
}

/// Whether this build can call through any convention, which is what a
/// signature needs before it records its arguments' types.
fn hasCallableConvention() bool {
    return supports("aapcs64") or supports("sysv64") or supports("win64");
}

fn reachable(head: *abi.AbstractHead) bool {
    return harness.gcBits(head.gc.flags) & constants.mem_reachable != 0;
}

fn unmark(head: *abi.AbstractHead) void {
    head.gc.flags = @bitCast(harness.gcBits(head.gc.flags) & ~@as(u32, constants.mem_reachable));
}

/// A struct type and a signature each mark the struct types they hold. The
/// inner struct is reachable only through the outer value, so its bit is set
/// by the outer value's mark callback or not at all.
fn theMarkCallbacksReachNestedStructs() void {
    const outer = eval("(ffi/struct :u8 (ffi/struct :u8 :u32))");
    gc_alloc.gcroot(outer);
    defer _ = gc_alloc.gcunroot(outer);
    const st: *ffi_types.Struct = @ptrCast(@alignCast(wrap.toAbstract(outer)));
    const inner = utils.abstractHead(ffi_types.Struct.fields(st)[1].type.st);
    expect(!reachable(inner));
    gc_mark.mark(outer);
    expect(reachable(inner));
    unmark(inner);
    unmark(utils.abstractHead(st));

    // A `:none` signature records no argument types, so there is nothing for
    // it to mark.
    if (!hasCallableConvention()) return;
    const sigv = eval("(ffi/signature :default :void :u8 (ffi/struct :u8 :u32))");
    gc_alloc.gcroot(sigv);
    defer _ = gc_alloc.gcunroot(sigv);
    const sig: *ffi_types.Signature = @ptrCast(@alignCast(wrap.toAbstract(sigv)));
    const held = utils.abstractHead(sig.args[1].type.st);
    expect(!reachable(held));
    gc_mark.mark(sigv);
    expect(reachable(held));
    unmark(held);
    unmark(utils.abstractHead(sig));
}

/// AAPCS64 returns a struct wider than sixteen bytes through a buffer of 128
/// bytes. 128 is described and 129 is refused, before any argument is
/// decoded, so the refusal is the return's and not the bad argument's.
fn theAapcs64ReturnBound() void {
    if (!supports("aapcs64")) return;
    const signature = harness.core("ffi/signature");
    var argv: [3]repr.Value = undefined;
    argv[0] = value.fromBytes("aapcs64", .keyword);

    argv[1] = eval("[![:u8 24]]");
    const narrow = signature(argv[0..2]) catch @panic("ffi_core: a 24-byte return was refused");
    expect(harness.isType(narrow, repr.Tag.abstract));

    argv[1] = eval("[![:u8 128]]");
    const widest = signature(argv[0..2]) catch @panic("ffi_core: a 128-byte return was refused");
    expect(harness.isType(widest, repr.Tag.abstract));

    argv[1] = eval("[![:u8 129]]");
    argv[2] = value.fromBytes("nonesuch", .keyword);
    expectRaise(signature, .{argv[0..3]}, "return value bigger than supported");
}

/// Sixty-four bytes, which AAPCS64 passes by reference.
const Big64 = extern struct { w: [8]u64 };

/// The scratch table's length while a callee below was running.
var scratch_during: usize = 0;

fn eightBig(a: Big64, b: Big64, c: Big64, d: Big64, e: Big64, f: Big64, g: Big64, h: Big64) callconv(.c) f64 {
    scratch_during = harness.vm().scratch.items.len;
    const total = a.w[7] + b.w[7] + c.w[7] + d.w[7] + e.w[7] + f.w[7] + g.w[7] + h.w[7];
    return @floatFromInt(total);
}

fn nineBig(a: Big64, b: Big64, c: Big64, d: Big64, e: Big64, f: Big64, g: Big64, h: Big64, i: Big64) callconv(.c) f64 {
    scratch_during = harness.vm().scratch.items.len;
    const total = a.w[7] + b.w[7] + c.w[7] + d.w[7] + e.w[7] + f.w[7] + g.w[7] + h.w[7] + i.w[7];
    return @floatFromInt(total);
}

/// A frame of up to 512 bytes is on the caller's stack and a larger one is a
/// scratch block, released when the call returns. Eight 64-byte copies behind
/// the eight general registers are exactly 512 bytes; a ninth puts its
/// pointer on the stack and makes the frame 592.
fn theFrameIsScratchOnlyPastTheInlineSize() void {
    if (!supports("aapcs64")) return;
    const ffi_call_fn = harness.core("ffi/call");
    const out = eval(
        \\(do
        \\  (def big (ffi/struct |(array/new-filled 8 :u64)))
        \\  [(ffi/signature :aapcs64 :double |(array/new-filled 8 big))
        \\   (ffi/signature :aapcs64 :double |(array/new-filled 9 big))
        \\   (tuple |(range 1 9))])
    );
    gc_alloc.gcroot(out);
    defer _ = gc_alloc.gcunroot(out);
    const parts = harness.elems(out);

    var args: [11]repr.Value = undefined;
    for (args[2..]) |*a| a.* = parts[2];
    const before = harness.vm().scratch.items.len;

    args[0] = wrap.fromPointer(@ptrCast(@constCast(&eightBig)));
    args[1] = parts[0];
    const eight = ffi_call_fn(args[0..10]) catch @panic("ffi_core: ffi/call raised");
    expect(wrap.toNumber(eight) == 64);
    expect(scratch_during == before);
    expect(harness.vm().scratch.items.len == before);

    args[0] = wrap.fromPointer(@ptrCast(@constCast(&nineBig)));
    args[1] = parts[1];
    const nine = ffi_call_fn(args[0..11]) catch @panic("ffi_core: ffi/call raised");
    expect(wrap.toNumber(nine) == 72);
    expect(scratch_during == before + 1);
    expect(harness.vm().scratch.items.len == before);
}

/// Apple lays a spilled aggregate at its own size, so twenty aggregates of
/// four doubles need 72 words of stack: two fill the vector registers and
/// eighteen follow at 32 bytes each. The ceiling is the top rung, 128.
fn aSignatureOf72StackWordsIsDescribed() void {
    if (!supports("aapcs64") or !builtin.os.tag.isDarwin()) return;
    const sigv = eval("(ffi/signature :aapcs64 :void |(array/new-filled 20 [:double :double :double :double]))");
    const sig: *ffi_types.Signature = @ptrCast(@alignCast(wrap.toAbstract(sigv)));
    expect(sig.arg_stack_words == 72);
}

/// An array of count zero takes no general register and writes nothing, so
/// the `:s8` behind it arrives in the first.
fn aZeroCountArrayArgumentWritesNothing() void {
    if (!supports("aapcs64")) return;
    const sig = eval("(ffi/signature :aapcs64 :double ![:u8 0] :s8)");
    var args = [_]repr.Value{
        wrap.fromPointer(@ptrCast(@constCast(&asS8))),
        sig,
        wrap.fromTuple(tuples.end(tuples.begin(0))),
        wrap.fromNumber(-1),
    };
    const answer = harness.core("ffi/call")(args[0..4]) catch @panic("ffi_core: ffi/call raised");
    expect(wrap.toNumber(answer) == -1);
}

// ==========================================================================
// Entry
// ==========================================================================

pub fn run() void {
    harness.init();

    registration();
    primTable();
    abstractTypes();
    callbackWithoutUserdata();
    outgoingSplit();
    ceilingIsReachableOnlyOnSysv();
    theRaises();
    theSignatureArityBound();
    homogeneousFloatAggregates();
    narrowIntegerArgumentsAreExtended();
    anAggregateBehindAStackArgument();
    aVectorPairWithOneRegisterLeft();
    theMarkCallbacksReachNestedStructs();
    theAapcs64ReturnBound();
    theFrameIsScratchOnlyPastTheInlineSize();
    aSignatureOf72StackWordsIsDescribed();
    aZeroCountArrayArgumentWritesNothing();

    std.debug.print("ffi_core raises: {d}\n", .{raises_seen});
    vm_lifecycle.deinit();
}
