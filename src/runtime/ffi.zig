//! The FFI cfunction surface: the seventeen `ffi/` bindings, the native object
//! a shared library is loaded into, and the registration below.
//!
//! Nothing decides anything here. The type system is `ffi/types.zig`, the
//! marshalling `ffi/marshal.zig` and the calling machinery `ffi/call.zig`;
//! this file is arity, sandbox assertions and registration.

// ==========================================================================
// Project imports
// ==========================================================================

const abstract_type = @import("../api/abstract_type.zig");
const abstracts = @import("value/abstracts.zig");
const args_core = @import("args.zig");
const buffers = @import("value/buffers.zig");
const clib = @import("dynlib.zig");
const corefn = @import("corefn.zig");
const ffi_call = @import("ffi/call.zig");
const ffi_types = @import("ffi/types.zig");
const marshal = @import("ffi/marshal.zig");
const raise = @import("../api/raise.zig");
const repr = @import("repr");
const tables = @import("value/tables.zig");
const utils = @import("utils.zig");
const vm_lifecycle = @import("vm/lifecycle.zig");
const wrap = @import("value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The loaded-library abstract type. Every field after `name` is null, which
/// the structure already defaults them to.
const native_at = abstract_type.define(AbstractNative, .{ .name = "core/ffi-native" });

// ==========================================================================
// Types
// ==========================================================================

const AbstractNative = extern struct {
    lib: clib.Handle,
    closed: c_int,
    is_self: c_int,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Install the `ffi/` bindings, in upstream Janet's own registration order.
pub fn libFfi(env: *tables.Table) void {
    const table = comptime [_]corefn.Entry{
        corefn.reg("ffi/native", &cfunRawNative, @src(), "(ffi/native &opt path)", "Load a shared object or dll from the given path, and do not extract" ++
            " or run any code from it. This is different than `native`, which will " ++
            "run initialization code to get a module table. If `path` is nil, opens the current running binary. " ++
            "Returns a `core/native`."),
        corefn.reg("ffi/lookup", &cfunNativeLookup, @src(), "(ffi/lookup native symbol-name)", "Lookup a symbol from a native object. All symbol lookups will return a raw pointer " ++
            "if the symbol is found, else nil."),
        corefn.reg("ffi/close", &cfunNativeClose, @src(), "(ffi/close native)", "Free a native object. Dereferencing pointers to symbols in the object will have undefined " ++
            "behavior after freeing."),
        corefn.reg("ffi/signature", &ffi_call.cfunSignature, @src(), "(ffi/signature calling-convention ret-type & arg-types)", "Create a function signature object that can be used to make calls " ++
            "with raw function pointers."),
        corefn.reg("ffi/call", &ffi_call.cfunCall, @src(), "(ffi/call pointer signature & args)", "Call a raw pointer as a function pointer. The function signature specifies " ++
            "how Janet values in `args` are converted to native machine types."),
        corefn.reg("ffi/struct", &cfunFfiStruct, @src(), "(ffi/struct & types)", "Create a struct type definition that can be used to pass structs into native functions. "),
        corefn.reg("ffi/write", &cfunBufferWrite, @src(), "(ffi/write ffi-type data &opt buffer index)", "Append a native type to a buffer such as it would appear in memory. This can be used " ++
            "to pass pointers to structs in the ffi, or send C/C++/native structs over the network " ++
            "or to files. Returns a modified buffer or a new buffer if one is not supplied."),
        corefn.reg("ffi/read", &cfunBufferRead, @src(), "(ffi/read ffi-type bytes &opt offset)", "Parse a native struct out of a buffer and convert it to normal Janet data structures. " ++
            "This function is the inverse of `ffi/write`. `bytes` can also be a raw pointer, although " ++
            "this is unsafe."),
        corefn.reg("ffi/size", &cfunFfiSize, @src(), "(ffi/size type)", "Get the size of an ffi type in bytes."),
        corefn.reg("ffi/align", &cfunFfiAlign, @src(), "(ffi/align type)", "Get the align of an ffi type in bytes."),
        corefn.reg("ffi/trampoline", &ffi_call.cfunTrampoline, @src(), "(ffi/trampoline cc)", "Get a native function pointer that can be used as a callback and passed to C libraries. " ++
            "This callback trampoline has the signature `void trampoline(void \\*ctx, void \\*userdata)` in " ++
            "the given calling convention. This is the only function signature supported. " ++
            "It is up to the programmer to ensure that the `userdata` argument contains a janet function " ++
            "the will be called with one argument, `ctx` which is an opaque pointer. This pointer can " ++
            "be further inspected with `ffi/read`."),
        corefn.reg("ffi/jitfn", &ffi_call.cfunJitfn, @src(), "(ffi/jitfn bytes)", "Create an abstract type that can be used as the pointer argument to `ffi/call`. The content " ++
            "of `bytes` is architecture specific machine code that will be copied into executable memory."),
        corefn.reg("ffi/malloc", &cfunFfiMalloc, @src(), "(ffi/malloc size)", "Allocates memory directly using Wattle's memory allocator. Memory allocated in this way must be freed manually! Returns a raw pointer, or nil if size = 0."),
        corefn.reg("ffi/free", &cfunFfiFree, @src(), "(ffi/free pointer)", "Free memory allocated with `ffi/malloc`. Returns nil."),
        corefn.reg("ffi/pointer-buffer", &cfunPointerBuffer, @src(), "(ffi/pointer-buffer pointer capacity &opt count offset)", "Create a buffer from a pointer. The underlying memory of the buffer will not be " ++
            "reallocated or freed by the garbage collector, allowing unmanaged, mutable memory " ++
            "to be manipulated with buffer functions. Attempts to resize or extend the buffer " ++
            "beyond its initial capacity will raise an error. As with many FFI functions, this is memory " ++
            "unsafe and can potentially allow out of bounds memory access. Returns a new buffer."),
        corefn.reg("ffi/pointer-cfunction", &cfunPointerCfunction, @src(), "(ffi/pointer-cfunction pointer &opt name source-file source-line)", "Raises: a raw pointer names a C function, and a cfunction is not a C " ++
            "function, so there is nothing to hand back. Use `ffi/signature` and `ffi/call`, " ++
            "which describe the calling convention rather than assuming one. " ++
            "The arguments are still checked, so a wrong one is reported as such. Unused: a name and " ++
            "source location for stack traces and debugging."),
        corefn.reg("ffi/calling-conventions", &cfunCallingConventions, @src(), "(ffi/calling-conventions)", "Get an array of all supported calling conventions on the current architecture. Some architectures may have some FFI " ++
            "functionality (ffi/malloc, ffi/free, ffi/read, ffi/write, etc.) but not support " ++
            "any calling conventions. This function can be used to get all supported calling conventions " ++
            "that can be used on this architecture. All architectures support the :none calling " ++
            "convention which is a placeholder that cannot be used at runtime."),
    };
    corefn.install(env, table);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// `(ffi/buffer-read type buffer &opt offset)`.
fn cfunBufferRead(argv: []const repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"ffi_use"}));
    try args_core.arity(argv, 2, 3);
    const ty = try ffi_types.decodeType(argv[0]);
    const offset: usize = @intCast(try args_core.optNat(argv, 2, 0));
    if (repr.checkType(argv[1], repr.Tag.pointer)) {
        const ptr: [*]const u8 = @ptrCast(wrap.toPointer(argv[1]));
        return marshal.readOne(ptr + offset, ty, ffi_types.max_recur);
    }
    const el_size = ffi_types.typeSize(ty);
    const bytes = try args_core.getBytes(argv, 1);
    if (@as(usize, @intCast(bytes.len)) < offset + el_size) return raise.panic("read out of range");
    return marshal.readOne(bytes.bytes.? + offset, ty, ffi_types.max_recur);
}

/// `(ffi/buffer-write type value &opt buffer offset)`.
fn cfunBufferWrite(argv: []const repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"ffi_use"}));
    try args_core.arity(argv, 2, 4);
    const ty = try ffi_types.decodeType(argv[0]);
    const el_size = ffi_types.typeSize(ty);
    const buffer = try args_core.optBuffer(argv, 2, ffi_types.typeSize(ty));
    var index: usize = @intCast(try args_core.optNat(argv, 3, @intCast(buffer.count)));
    const old_count = buffer.count;
    if (index > old_count) return raise.panic("index out of bounds");
    // The extension is measured from `index` rather than from the end, so the
    // count moves there and back around it.
    buffer.count = index;
    try buffers.extra(buffer, el_size);
    buffer.count = old_count;
    @memset(buffer.reserved()[index .. index + el_size], 0);
    try marshal.writeOne(buffer.data.? + index, argv, 1, ty, ffi_types.max_recur);
    index += el_size;
    if (buffer.count < index) buffer.count = index;
    return wrap.fromBuffer(buffer);
}

/// `(ffi/calling-conventions)`, which lists the conventions this build can
/// call.
fn cfunCallingConventions(argv: []const repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 0);
    return ffi_call.supportedConventions();
}

/// `(ffi/align type)`.
fn cfunFfiAlign(argv: []const repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const alignment = ffi_types.typeAlign(try ffi_types.decodeType(argv[0]));
    return wrap.fromNumber(@floatFromInt(alignment));
}

/// `(ffi/free pointer)`.
fn cfunFfiFree(argv: []const repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"ffi_use"}));
    try args_core.fixarity(argv, 1);
    if (repr.checkType(argv[0], repr.Tag.nil)) return wrap.fromNil();
    utils.free(try args_core.getPointer(argv, 0));
    return wrap.fromNil();
}

/// `(ffi/malloc size)`.
fn cfunFfiMalloc(argv: []const repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"ffi_use"}));
    try args_core.fixarity(argv, 1);
    const size = try args_core.getSize(argv, 0);
    if (size == 0) return wrap.fromNil();
    return wrap.fromPointer(utils.malloc(size));
}

/// `(ffi/size type)`.
fn cfunFfiSize(argv: []const repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    const size = ffi_types.typeSize(try ffi_types.decodeType(argv[0]));
    return wrap.fromNumber(@floatFromInt(size));
}

/// `(ffi/struct & types)`.
fn cfunFfiStruct(argv: []const repr.Value) raise.Error!repr.Value {
    try args_core.arity(argv, 1, -1);
    return wrap.fromAbstract(try ffi_types.buildStruct(argv));
}

/// `(ffi/close native)`.
fn cfunNativeClose(argv: []const repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"ffi_define"}));
    try args_core.fixarity(argv, 1);
    const anative: *AbstractNative = try args_core.getAbstract(AbstractNative, argv, 0, &native_at);
    if (anative.closed != 0) return raise.panic("native object already closed");
    if (anative.is_self != 0) return raise.panic("cannot close self");
    anative.closed = 1;
    clib.free(anative.lib);
    return wrap.fromNil();
}

/// `(ffi/lookup native name)`.
fn cfunNativeLookup(argv: []const repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"ffi_define"}));
    try args_core.fixarity(argv, 2);
    const anative: *AbstractNative = try args_core.getAbstract(AbstractNative, argv, 0, &native_at);
    const sym = try args_core.getCString(argv, 1);
    if (anative.closed != 0) return raise.panic("native object already closed");
    const val = try clib.symbol(anative.lib, sym) orelse return wrap.fromNil();
    return wrap.fromPointer(val);
}

/// `(ffi/pointer-buffer pointer capacity &opt count offset)`.
fn cfunPointerBuffer(argv: []const repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"ffi_use"}));
    try args_core.arity(argv, 2, 4);
    const pointer: [*]u8 = @ptrCast(try args_core.getPointer(argv, 0));
    const capacity = try args_core.getNat(argv, 1);
    const count = try args_core.optNat(argv, 2, 0);
    const offset = try args_core.optInteger64(argv, 3, 0);
    // The offset is signed and is added to the pointer the way C adds it:
    // `((uint8_t *) pointer) + offset`, which on a 32-bit target narrows the
    // 64-bit offset rather than refusing it. `@truncate` is that narrowing;
    // `@intCast` would trap on the same input.
    const delta: isize = @truncate(offset);
    const at: [*]u8 = @ptrFromInt(@intFromPtr(pointer) +% @as(usize, @bitCast(delta)));
    // Both getters have already refused a negative, which is where the range
    // check belongs; the widths meet here.
    return wrap.fromBuffer(try buffers.pointerUnsafe(at, @intCast(capacity), @intCast(count)));
}

/// `(ffi/pointer-cfunction pointer)`, which refuses rather than wrapping.
///
/// Every pointer this can be given is a C function: it comes from a shared
/// object built by a C toolchain, usually straight out of `ffi/lookup`. A
/// cfunction in this runtime is not a C function: it takes a `[]Value`,
/// returns an error union, and travels over Zig's own calling convention. So
/// wrapping such a pointer as a cfunction would be a claim the interpreter
/// believes and the callee does not honour, and calling it would read the
/// argument count and the argument pointer out of the wrong registers.
///
/// `ffi/lookup` and `ffi/signature` are how a C function is called, and they
/// describe the convention rather than assuming one.
fn cfunPointerCfunction(argv: []const repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"ffi_use"}));
    try args_core.arity(argv, 1, 4);
    _ = try args_core.getPointer(argv, 0);
    return raise.panic(
        "a raw pointer cannot become a cfunction; use ffi/signature and ffi/call",
    );
}

/// `(ffi/native &opt path)`.
fn cfunRawNative(argv: []const repr.Value) raise.Error!repr.Value {
    try vm_lifecycle.sandboxAssert(vm_lifecycle.Sandbox.of(&.{"ffi_define"}));
    try args_core.arity(argv, 0, 1);
    const path = try args_core.optCString(argv, 0, null);
    const lib = clib.load(path);
    if (clib.failed(lib)) return raise.panic(clib.lastError());
    const anative: *AbstractNative = abstracts.newFor(AbstractNative, &native_at);
    anative.lib = lib;
    anative.closed = 0;
    anative.is_self = @intFromBool(path == null);
    return wrap.fromAbstract(anative);
}
