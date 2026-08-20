//! `ffi.c`'s cfunction surface: the seventeen `ffi/` bindings, the native
//! object a shared library is loaded into, and `janet_lib_ffi`. Part 16's
//! root, and the file the other three are reached from.
//!
//! Nothing decides anything here. The type system is `ffi_types.zig`, the
//! marshalling `ffi_marshal.zig`, and the calling machinery `ffi_call.zig`;
//! this file is arity, sandbox assertions and registration, which is the same
//! division `os_surface.zig` draws over its three.
//!
//! ## Why this file is jump-transparent
//!
//! The argument layer is behind `-Dargs-core`, so every `janet_get*` raises by
//! `longjmp` until Part 17. No `defer` may appear here until then.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const corefn = @import("corefn");
const raise = @import("raise");
const types = @import("ffi_types.zig");
const marshal = @import("ffi_marshal.zig");
const ffi_call = @import("ffi_call.zig");
const arglayer = @import("arglayer.zig");
const clib = @import("dynlib.zig");
const containers = @import("containers.zig");
const lifecycle = @import("lifecycle.zig");
const abstract_type = @import("abstract_type.zig");

const c = types.c;

const has_dynamic_modules = @hasDecl(c, "JANET_DYNAMIC_MODULES");
const windows = types.windows;

/// `util.h` rather than `janet.h`, so `abi.zig` does not translate it.
extern fn janet_registry_put(
    key: c.JanetCFunction,
    name: [*c]const u8,
    name_prefix: [*c]const u8,
    source_file: [*c]const u8,
    source_line: i32,
) callconv(.c) void;

// ==========================================================================
// The native object
// ==========================================================================

const AbstractNative = extern struct {
    lib: clib.Handle,
    closed: c_int,
    is_self: c_int,
};

/// `janet_native_type`. `JANET_ATEND_NAME` leaves every field after `name`
/// null, which the translated structure already defaults them to.
const native_at: abstract_type.AbstractType = .{ .name = "core/ffi-native" };

// ==========================================================================
// The cfunctions
// ==========================================================================

fn rawNative(argc: i32, argv: [*c]const c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FFI_DEFINE);
    try arglayer.arity(argc, 0, 1);
    const path = try arglayer.optCString(argv, argc, 0, null);
    const lib = clib.load(path);
    if (clib.failed(lib)) return raise.panic(clib.lastError());
    const anative: *AbstractNative = @ptrCast(@alignCast(c.janet_abstract(abstract_type.stored(&native_at), @sizeOf(AbstractNative))));
    anative.lib = lib;
    anative.closed = 0;
    anative.is_self = @intFromBool(path == null);
    return c.janet_wrap_abstract(anative);
}

fn nativeLookup(argc: i32, argv: [*c]const c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FFI_DEFINE);
    try arglayer.fixarity(argc, 2);
    const anative: *AbstractNative = @ptrCast(@alignCast(try arglayer.getAbstract(argv, 0, abstract_type.stored(&native_at))));
    const sym = try arglayer.getCString(argv, 1);
    if (anative.closed != 0) return raise.panic("native object already closed");
    const value = try clib.symbol(anative.lib, sym) orelse return c.janet_wrap_nil();
    return c.janet_wrap_pointer(value);
}

fn nativeClose(argc: i32, argv: [*c]const c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FFI_DEFINE);
    try arglayer.fixarity(argc, 1);
    const anative: *AbstractNative = @ptrCast(@alignCast(try arglayer.getAbstract(argv, 0, abstract_type.stored(&native_at))));
    if (anative.closed != 0) return raise.panic("native object already closed");
    if (anative.is_self != 0) return raise.panic("cannot close self");
    anative.closed = 1;
    clib.free(anative.lib);
    return c.janet_wrap_nil();
}

fn ffiStruct(argc: i32, argv: [*c]const c.Janet) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, -1);
    return c.janet_wrap_abstract(try types.buildStruct(argc, argv));
}

fn ffiSize(argc: i32, argv: [*c]const c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const size = types.typeSize(try types.decodeType(argv[0]));
    return c.janet_wrap_number(@floatFromInt(size));
}

fn ffiAlign(argc: i32, argv: [*c]const c.Janet) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const alignment = types.typeAlign(try types.decodeType(argv[0]));
    return c.janet_wrap_number(@floatFromInt(alignment));
}

fn bufferWrite(argc: i32, argv: [*c]const c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FFI_USE);
    try arglayer.arity(argc, 2, 4);
    const ty = try types.decodeType(argv[0]);
    const el_size: i32 = @intCast(types.typeSize(ty));
    const buffer = try arglayer.optBuffer(argv, argc, 2, el_size);
    var index = try arglayer.optNat(argv, argc, 3, buffer.*.count);
    const old_count = buffer.*.count;
    if (index > old_count) return raise.panic("index out of bounds");
    // The extension is measured from `index` rather than from the end, so the
    // count moves there and back around it.
    buffer.*.count = index;
    try containers.bufferExtra(buffer, el_size);
    buffer.*.count = old_count;
    @memset(buffer.*.data[@intCast(index)..@intCast(index + el_size)], 0);
    try marshal.writeOne(buffer.*.data + @as(usize, @intCast(index)), argv, 1, ty, types.max_recur);
    index += el_size;
    if (buffer.*.count < index) buffer.*.count = index;
    return c.janet_wrap_buffer(buffer);
}

fn bufferRead(argc: i32, argv: [*c]const c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FFI_USE);
    try arglayer.arity(argc, 2, 3);
    const ty = try types.decodeType(argv[0]);
    const offset: usize = @intCast(try arglayer.optNat(argv, argc, 2, 0));
    if (0 != c.janet_checktype(argv[1], c.JANET_POINTER)) {
        const ptr: [*]const u8 = @ptrCast(c.janet_unwrap_pointer(argv[1]));
        return marshal.readOne(ptr + offset, ty, types.max_recur);
    }
    const el_size = types.typeSize(ty);
    const bytes = try arglayer.getBytes(argv, 1);
    if (@as(usize, @intCast(bytes.len)) < offset + el_size) return raise.panic("read out of range");
    return marshal.readOne(bytes.bytes + offset, ty, types.max_recur);
}

fn ffiMalloc(argc: i32, argv: [*c]const c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FFI_USE);
    try arglayer.fixarity(argc, 1);
    const size = try arglayer.getSize(argv, 0);
    if (size == 0) return c.janet_wrap_nil();
    return c.janet_wrap_pointer(c.janet_malloc(size));
}

fn ffiFree(argc: i32, argv: [*c]const c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FFI_USE);
    try arglayer.fixarity(argc, 1);
    if (0 != c.janet_checktype(argv[0], c.JANET_NIL)) return c.janet_wrap_nil();
    c.janet_free(try arglayer.getPointer(argv, 0));
    return c.janet_wrap_nil();
}

fn pointerBuffer(argc: i32, argv: [*c]const c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FFI_USE);
    try arglayer.arity(argc, 2, 4);
    const pointer: [*]u8 = @ptrCast(try arglayer.getPointer(argv, 0));
    const capacity = try arglayer.getNat(argv, 1);
    const count = try arglayer.optNat(argv, argc, 2, 0);
    const offset = try arglayer.optInteger64(argv, argc, 3, 0);
    // The offset is signed and is added to the pointer the way C adds it:
    // `((uint8_t *) pointer) + offset`, which on a 32-bit target narrows the
    // 64-bit offset rather than refusing it. `@truncate` is that narrowing;
    // `@intCast` would trap on the same input.
    const delta: isize = @truncate(offset);
    const at: [*]u8 = @ptrFromInt(@intFromPtr(pointer) +% @as(usize, @bitCast(delta)));
    return c.janet_wrap_buffer(try containers.pointerBufferUnsafe(at, capacity, count));
}

fn pointerCfunction(argc: i32, argv: [*c]const c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_FFI_USE);
    try arglayer.arity(argc, 1, 4);
    const pointer = try arglayer.getPointer(argv, 0);
    const name = try arglayer.optCString(argv, argc, 1, null);
    const source = try arglayer.optCString(argv, argc, 2, null);
    const line = try arglayer.optInteger(argv, argc, 3, -1);
    const cfun: c.JanetCFunction = @ptrCast(@alignCast(pointer));
    if (name != null or source != null or line != -1) {
        janet_registry_put(cfun, name, null, source, line);
    }
    return c.janet_wrap_cfunction(cfun);
}

fn callingConventions(argc: i32, argv: [*c]const c.Janet) raise.Raising(c.Janet) {
    _ = argv;
    try arglayer.fixarity(argc, 0);
    return ffi_call.supportedConventions();
}

// ==========================================================================
// Registration
// ==========================================================================

/// `janet_lib_ffi`. The order is the C original's exactly.
export fn janet_lib_ffi(env: *c.JanetTable) callconv(.c) void {
    const table = comptime [_]corefn.Entry{
        corefn.reg("ffi/native", &rawNative, @src(), "(ffi/native &opt path)", "Load a shared object or dll from the given path, and do not extract" ++
            " or run any code from it. This is different than `native`, which will " ++
            "run initialization code to get a module table. If `path` is nil, opens the current running binary. " ++
            "Returns a `core/native`."),
        corefn.reg("ffi/lookup", &nativeLookup, @src(), "(ffi/lookup native symbol-name)", "Lookup a symbol from a native object. All symbol lookups will return a raw pointer " ++
            "if the symbol is found, else nil."),
        corefn.reg("ffi/close", &nativeClose, @src(), "(ffi/close native)", "Free a native object. Dereferencing pointers to symbols in the object will have undefined " ++
            "behavior after freeing."),
        corefn.reg("ffi/signature", &ffi_call.signature, @src(), "(ffi/signature calling-convention ret-type & arg-types)", "Create a function signature object that can be used to make calls " ++
            "with raw function pointers."),
        corefn.reg("ffi/call", &ffi_call.call, @src(), "(ffi/call pointer signature & args)", "Call a raw pointer as a function pointer. The function signature specifies " ++
            "how Janet values in `args` are converted to native machine types."),
        corefn.reg("ffi/struct", &ffiStruct, @src(), "(ffi/struct & types)", "Create a struct type definition that can be used to pass structs into native functions. "),
        corefn.reg("ffi/write", &bufferWrite, @src(), "(ffi/write ffi-type data &opt buffer index)", "Append a native type to a buffer such as it would appear in memory. This can be used " ++
            "to pass pointers to structs in the ffi, or send C/C++/native structs over the network " ++
            "or to files. Returns a modified buffer or a new buffer if one is not supplied."),
        corefn.reg("ffi/read", &bufferRead, @src(), "(ffi/read ffi-type bytes &opt offset)", "Parse a native struct out of a buffer and convert it to normal Janet data structures. " ++
            "This function is the inverse of `ffi/write`. `bytes` can also be a raw pointer, although " ++
            "this is unsafe."),
        corefn.reg("ffi/size", &ffiSize, @src(), "(ffi/size type)", "Get the size of an ffi type in bytes."),
        corefn.reg("ffi/align", &ffiAlign, @src(), "(ffi/align type)", "Get the align of an ffi type in bytes."),
        corefn.reg("ffi/trampoline", &ffi_call.trampoline, @src(), "(ffi/trampoline cc)", "Get a native function pointer that can be used as a callback and passed to C libraries. " ++
            "This callback trampoline has the signature `void trampoline(void \\*ctx, void \\*userdata)` in " ++
            "the given calling convention. This is the only function signature supported. " ++
            "It is up to the programmer to ensure that the `userdata` argument contains a janet function " ++
            "the will be called with one argument, `ctx` which is an opaque pointer. This pointer can " ++
            "be further inspected with `ffi/read`."),
        corefn.reg("ffi/jitfn", &ffi_call.jitfn, @src(), "(ffi/jitfn bytes)", "Create an abstract type that can be used as the pointer argument to `ffi/call`. The content " ++
            "of `bytes` is architecture specific machine code that will be copied into executable memory."),
        corefn.reg("ffi/malloc", &ffiMalloc, @src(), "(ffi/malloc size)", "Allocates memory directly using the janet memory allocator. Memory allocated in this way must be freed manually! Returns a raw pointer, or nil if size = 0."),
        corefn.reg("ffi/free", &ffiFree, @src(), "(ffi/free pointer)", "Free memory allocated with `ffi/malloc`. Returns nil."),
        corefn.reg("ffi/pointer-buffer", &pointerBuffer, @src(), "(ffi/pointer-buffer pointer capacity &opt count offset)", "Create a buffer from a pointer. The underlying memory of the buffer will not be " ++
            "reallocated or freed by the garbage collector, allowing unmanaged, mutable memory " ++
            "to be manipulated with buffer functions. Attempts to resize or extend the buffer " ++
            "beyond its initial capacity will raise an error. As with many FFI functions, this is memory " ++
            "unsafe and can potentially allow out of bounds memory access. Returns a new buffer."),
        corefn.reg("ffi/pointer-cfunction", &pointerCfunction, @src(), "(ffi/pointer-cfunction pointer &opt name source-file source-line)", "Create a C Function from a raw pointer. Optionally give the cfunction a name and " ++
            "source location for stack traces and debugging."),
        corefn.reg("ffi/calling-conventions", &callingConventions, @src(), "(ffi/calling-conventions)", "Get an array of all supported calling conventions on the current architecture. Some architectures may have some FFI " ++
            "functionality (ffi/malloc, ffi/free, ffi/read, ffi/write, etc.) but not support " ++
            "any calling conventions. This function can be used to get all supported calling conventions " ++
            "that can be used on this architecture. All architectures support the :none calling " ++
            "convention which is a placeholder that cannot be used at runtime."),
        corefn.end,
    };
    corefn.install(env, &table);
}
