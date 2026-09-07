//! The runtime side of the module table, in one file.
//!
//! What is here is what a native module reaches through `api/interface.zig`,
//! and nothing else. The runtime runs Janet code, a native module is written
//! in Zig and loads through `module.zig`, and there is no C API. So this file
//! is the other side of `module.zig`'s calls, plus the six `raise.zig` reaches
//! when it is compiled into a module rather than into the runtime.
//!
//! Nothing here is exported. `table` at the foot of the file is one `extern
//! struct` of function pointers; `env.zig` hands its address to `_janet_init`
//! and the module calls through it. No `janet_*` name reaches the symbol
//! table, so a module cannot bind to the wrong copy of the runtime and a
//! second copy cannot capture the first's crossings.
//!
//! The initializer is the check. `interface.Runtime`'s field type is the
//! shape, both compilations read it from that file, and the compiler
//! type-checks each `&definition` against the field it fills. A definition
//! that changes shape fails to compile here rather than linking against a
//! declaration that still says the old shape.
//!
//! Everything else a file needs from a neighbour it reaches by `@import`,
//! which keeps the error union, allows inlining, and is checked.
//!
//! The entry points are separate from the definitions because a slice has no
//! guaranteed in-memory representation, so Zig refuses one in a `callconv(.c)`
//! signature: a runtime function that filled a table field directly could not
//! take a slice.
//!
//! There are two populations. An entry point below calls ordinary Zig. The
//! rest of the table's fields point straight at a subsystem's own C-ABI shim,
//! because the thing they name is already dedicated to this boundary and has
//! no other caller: `args.zig`'s generated getters, and the `abi` namespace in
//! `value/helpers/wrap.zig`. Those have no second hat to take off.
// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const buffers = @import("value/buffers.zig");
const config = @import("config");
const interface = @import("../api/interface.zig");
const method_type = @import("method_type.zig");
const module = @import("../module.zig");
const raise = @import("../api/raise.zig");
const repr = @import("repr");
const tables = @import("value/tables.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// Every crossing, as one struct of pointers.
///
/// `env.zig` hands `&table` to `_janet_init` and the module keeps it. It is
/// `const` and lives in the runtime's own image, so a module refers into
/// `libjanet` for as long as it is loaded and there is nothing to free.
///
/// The order is `interface.Runtime`'s and the compiler enforces it: a field
/// initializer names its field, so a row here that drifted from the struct is
/// a missing or a duplicate field rather than a silent shift, and each
/// `&definition` is type-checked against the field's declared signature. No
/// second description of a crossing is kept anywhere, so there is none to fall
/// out of step.
///
/// `size` is the layout guard `module.entry`'s shim tests before it runs any
/// author code.
pub const table: interface.Runtime = .{
    .size = @sizeOf(interface.Runtime),

    // The six `raise.zig` reaches from inside a module's compilation.
    .cstring = &janet_cstring,
    .wrap_string = &impl.value_helpers_wrap.abi.fromString,
    .c_raise_record = &janet_zig_c_raise_record,
    .c_raise_take = &janet_zig_c_raise_take,
    .fatal = &janet_zig_fatal,
    .signal_record = &janet_zig_signal_record,

    .abstract = &janet_abstract,
    .arity = &impl.args.checkArityAbi,
    .array_push_value = &janet_array_push_value,
    .buffer_push_bytes = &janet_buffer_push_bytes,
    .buffer_push_value = &janet_buffer_push_value,
    .bytes_view = &impl.args.bytesViewAbi,
    .call_value = &janet_call_value,
    .calloc = &janet_calloc,
    .cfuns_ext = &janet_cfuns_ext,
    .checkint = &janet_checkint,
    .checktype = &janet_checktype,
    .current_loop = &janet_current_loop,
    .def = &janet_def,
    .dictionary_view = &impl.args.dictionaryViewAbi,
    .fiber_status_value = &janet_fiber_status_value,
    .fixarity = &impl.args.fixArityAbi,
    .free = &janet_free,
    .gcroot = &janet_gcroot,
    .gcunroot = &janet_gcunroot,
    .get = &janet_get,
    .getabstract = &impl.args.getAbstractAbi,
    .getboolean = &impl.args.GetBoolean.abi,
    .getbytes = &impl.args.getBytesAbi,
    .getdictionary = &impl.args.getDictionaryAbi,
    .getindexed = &impl.args.getIndexedAbi,
    .getinteger = &impl.args.GetInteger.abi,
    .getmethod = &janet_getmethod,
    .getnumber = &impl.args.GetNumber.abi,
    .getrange = &impl.args.getRangeAbi,
    .getsize = &impl.args.GetSize.abi,
    .getuinteger = &impl.args.GetUInteger.abi,
    .indexed_view = &impl.args.indexedViewAbi,
    .length = &janet_length,
    .mark = &janet_mark,
    .marshal_abstract = &janet_marshal_abstract,
    .marshal_byte = &janet_marshal_byte,
    .marshal_bytes = &janet_marshal_bytes,
    .marshal_flags = &janet_marshal_flags,
    .marshal_int = &janet_marshal_int,
    .marshal_int64 = &janet_marshal_int64,
    .marshal_janet = &janet_marshal_janet,
    .marshal_ptr = &janet_marshal_ptr,
    .marshal_size = &janet_marshal_size,
    .new_array = &janet_new_array,
    .new_buffer = &janet_new_buffer,
    .new_keyword = &janet_new_keyword,
    .new_string = &janet_new_string,
    .new_struct = &janet_new_struct,
    .new_symbol = &janet_new_symbol,
    .new_table = &janet_new_table,
    .new_tuple = &janet_new_tuple,
    .nextmethod = &janet_nextmethod,
    .pcall_value = &janet_pcall_value,
    .post = &janet_post,
    .put = &janet_put,
    .register_abstract_type = &janet_register_abstract_type,
    .root_fiber_value = &janet_root_fiber_value,
    .truthy = &janet_truthy,
    .unmarshal_abstract = &janet_unmarshal_abstract,
    .unmarshal_abstract_reuse = &janet_unmarshal_abstract_reuse,
    .unmarshal_byte = &janet_unmarshal_byte,
    .unmarshal_bytes = &janet_unmarshal_bytes,
    .unmarshal_ensure = &janet_unmarshal_ensure,
    .unmarshal_flags = &janet_unmarshal_flags,
    .unmarshal_int = &janet_unmarshal_int,
    .unmarshal_int64 = &janet_unmarshal_int64,
    .unmarshal_janet = &janet_unmarshal_janet,
    .unmarshal_ptr = &janet_unmarshal_ptr,
    .unmarshal_remaining = &janet_unmarshal_remaining,
    .unmarshal_size = &janet_unmarshal_size,
    .unwrap_integer = &janet_unwrap_integer,
    .unwrap_number = &janet_unwrap_number,
    .unwrap_pointer = &janet_unwrap_pointer,
    .wake = &janet_wake,
    .wrap_abstract = &impl.value_helpers_wrap.abi.fromAbstract,
    .wrap_boolean = &janet_wrap_boolean,
    .wrap_nil = &impl.value_helpers_wrap.abi.fromNil,
    .wrap_number = &impl.value_helpers_wrap.abi.fromNumber,
    .wrap_pointer = &impl.value_helpers_wrap.abi.fromPointer,
};

// ==========================================================================
// Types
// ==========================================================================

/// The runtime, in a namespace: a parameter name copied from a definition
/// cannot shadow an import that is not at this level.
const impl = struct {
    pub const args = @import("args.zig");
    pub const registry = @import("registry.zig");
    pub const fatal = @import("fatal.zig");
    pub const signal = @import("signal.zig");
    pub const utils = @import("utils.zig");
    pub const gc_mark = @import("gc/mark.zig");
    pub const marsh = @import("marsh.zig");
    pub const value_abstracts = @import("value/abstracts.zig");
    pub const value_buffers = @import("value/buffers.zig");
    pub const value_helpers_wrap = @import("value/helpers/wrap.zig");
    pub const value_strings = @import("value/strings.zig");
    pub const value = @import("value.zig");
    pub const value_tuples = @import("value/tuples.zig");
    pub const value_arrays = @import("value/arrays.zig");
    pub const value_structs = @import("value/structs.zig");
    pub const value_tables = @import("value/tables.zig");
    pub const value_helpers_access = @import("value/helpers/access.zig");
    pub const value_fibers = @import("value/fibers.zig");
    pub const vm_entry = @import("vm/entry.zig");
    pub const gc_alloc = @import("gc.zig");
    pub const pp_format = @import("pp/format.zig");
    pub const vm_state = @import("vm/state.zig");
    /// Gated the way `root.zig` gates it. `ev.zig` reaches `ev/backend.zig`,
    /// whose `VmBackend` has fields the VM state does not have in a
    /// `-Dev=false` build, so importing it there compiles code against a
    /// struct that is not the one the build made.
    pub const ev = if (config.ev) @import("ev.zig") else struct {};
};

/// The two operations that only exist under the loop.
///
/// A build without the loop still publishes both symbols, and neither is
/// reachable, because reaching either needs a `*abi.Loop` and
/// `janet_current_loop` refuses to make one. The refusal here is therefore an
/// assertion about that argument rather than a path a program takes.
const loop_ops = if (config.ev) struct {
    /// What the loop thread runs off the self-pipe, and where the author's two
    /// pointers come back out of the runtime's message.
    ///
    /// The context rides in `argp` and the callback in `argj`. `argp` is the
    /// message's one `?*anyopaque` slot, which is what a context is; the
    /// callback needs a second slot, and `argj` is the only other slot a
    /// pointer fits in without a type lie, since `fiber` is typed
    /// `*fibers.Fiber` and a function pointer is not that. A pointer-tagged
    /// `Value` is what the table's `wrap_pointer` crossing already publishes
    /// for exactly this, and it is inert to the collector, which matters not at
    /// all here because nothing traces a message in flight: `ev.evMark` walks
    /// the spawn list and the timer queue, and an event sitting in the
    /// self-pipe is in neither.
    fn trampoline(msg: impl.ev.GenericMessage) callconv(.c) void {
        const cb: module.PostCallback = @ptrCast(@alignCast(impl.value_helpers_wrap.toPointer(msg.argj)));
        cb(@ptrCast(impl.vm_state.current()), msg.argp.?);
    }

    fn post(l: *abi.Loop, cb: module.PostCallback, ctx: *anyopaque) void {
        var msg: impl.ev.GenericMessage = .{};
        msg.argp = ctx;
        msg.argj = impl.value_helpers_wrap.fromPointer(@constCast(@as(*const anyopaque, @ptrCast(cb))));
        impl.ev.evPostEvent(vmOf(l), trampoline, msg);
    }

    fn wake(w: *abi.Wake, fiber: repr.Value, value: repr.Value) bool {
        // The capability names the VM whose queue this pushes onto, and
        // `ev.schedule` reads the thread's. They are the same VM by
        // construction, since the trampoline above built this `Wake` out of
        // `vm_state.current()` one call frame up, and saying so here is what
        // makes the two types more than a naming convention.
        std.debug.assert(vmOf(w) == impl.vm_state.current());
        if (!repr.checkType(fiber, repr.Tag.fiber)) return false;
        const f = impl.value_helpers_wrap.toFiber(fiber);
        // False exactly where the runtime would drop it, which is two
        // conditions rather than one. `ev.scheduleGeneral` returns without
        // queueing anything for a fiber with the canceled flag set, which
        // `ev.cancel`, behind `ev/cancel`, is what sets; and a fiber that has
        // finished cannot be resumed at all, which is what `fibers.canResume`
        // asks. Either way the module's context is still the module's to free,
        // and the `false` is how the callback learns to free it.
        if (!impl.value_fibers.canResume(f)) return false;
        if (impl.value_fibers.evFlags(f).canceled) return false;
        impl.ev.schedule(f, value);
        return true;
    }
} else struct {
    fn post(l: *abi.Loop, cb: module.PostCallback, ctx: *anyopaque) void {
        _ = .{ l, cb, ctx };
        impl.fatal.fatal("event loop not enabled");
    }

    fn wake(w: *abi.Wake, fiber: repr.Value, value: repr.Value) bool {
        _ = .{ w, fiber, value };
        impl.fatal.fatal("event loop not enabled");
    }
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Allocates an abstract of type `atype` with `size` bytes of payload.
pub fn janet_abstract(atype: *const abi.AbstractType, size: usize) callconv(.c) ?*anyopaque {
    requireJanetThread();
    return impl.value_abstracts.newBytes(atype, size);
}

/// Mutation and access through the `Value` rather than through a heap pointer.
/// Each flattens a raise into a report, which `module.zig` rebuilds with
/// `raise.fromAbi`.
pub fn janet_array_push_value(v: repr.Value, x: repr.Value) callconv(.c) void {
    requireJanetThread();
    return raise.toAbi(impl.value_arrays.pushChecked(v, x));
}

pub fn janet_buffer_push_value(v: repr.Value, bytes: [*]const u8, len: usize) callconv(.c) void {
    requireJanetThread();
    return raise.toAbi(impl.value_buffers.pushBytesChecked(v, bytes[0..len]));
}

pub fn janet_get(ds: repr.Value, key: repr.Value) callconv(.c) repr.Value {
    requireJanetThread();
    return raise.toAbi(impl.value_helpers_access.get(ds, key));
}

pub fn janet_length(x: repr.Value) callconv(.c) i32 {
    requireJanetThread();
    return raise.toAbi(impl.value_helpers_access.length(x));
}

pub fn janet_put(ds: repr.Value, key: repr.Value, val: repr.Value) callconv(.c) void {
    requireJanetThread();
    return raise.toAbi(impl.value_helpers_access.put(ds, key, val));
}

/// The one operation an author has on a `*abi.Render`, which is what a
/// `tostring` callback is handed.
///
/// `buffers.pushBytes` takes a slice and this takes the pointer and the length
/// it is built from, for the reason this file's header gives. `raise.toAbi` is
/// what a hand-written abi is made of: the raise `pushBytes` returns cannot
/// travel a `callconv(.c)` return, so it is recorded and `module.push` rebuilds
/// it with `raise.fromAbi`.
pub fn janet_buffer_push_bytes(render: *abi.Render, bytes: [*]const u8, len: usize) callconv(.c) void {
    requireJanetThread();
    const buffer: *buffers.Buffer = @ptrCast(@alignCast(render));
    return raise.toAbi(impl.value_buffers.pushBytes(buffer, bytes[0..len]));
}

/// `(f ...)`, from a module's frame, raising on anything but a return.
///
/// `vm/entry.zig`'s `call` and `pcall` are published as they stand;
/// `callValue` beside them is what widens `call`'s callee from a
/// `*functions.Function` to any value `(f ...)` calls, and this file is its
/// only caller.
pub fn janet_call_value(f: repr.Value, args: [*]const repr.Value, len: usize) callconv(.c) repr.Value {
    requireJanetThread();
    return raise.toAbi(impl.vm_entry.callValue(f, args[0..len]));
}

/// The allocator for memory the runtime may later free.
pub fn janet_calloc(nmemb: usize, size: usize) callconv(.c) ?*anyopaque {
    requireJanetThread();
    return impl.utils.calloc(nmemb, size);
}

pub fn janet_free(ptr: ?*anyopaque) callconv(.c) void {
    requireJanetThread();
    return impl.utils.free(ptr);
}

/// Registration: a table of cfunctions read to its null-name terminator, and
/// one plain binding.
pub fn janet_cfuns_ext(env: ?*abi.Env, regprefix: ?[*:0]const u8, registrations: [*]const abi.Reg) callconv(.c) void {
    requireJanetThread();
    installSentinel(@ptrCast(@alignCast(env)), regprefix, registrations);
}

pub fn janet_def(env: *abi.Env, name: [*:0]const u8, val: repr.Value, doc: ?[*:0]const u8) callconv(.c) void {
    requireJanetThread();
    return impl.registry.def(@ptrCast(@alignCast(env)), name, val, doc);
}

/// Whether `x` is a number whose value is an exact 32-bit integer.
pub fn janet_checkint(x: repr.Value) callconv(.c) c_int {
    requireJanetThread();
    return @intFromBool(impl.args.checkint(x));
}

/// Whether `x` has tag `t`. A tag outside the vocabulary is reported as no
/// rather than indexed with.
pub fn janet_checktype(x: repr.Value, t: c_uint) callconv(.c) c_int {
    requireJanetThread();
    if (t >= repr.tag_count) return 0;
    return @intFromBool(repr.checkType(x, @enumFromInt(t)));
}

/// Interns a NUL-terminated C string as a Janet string.
pub fn janet_cstring(str: [*:0]const u8) callconv(.c) [*:0]const u8 {
    requireJanetThread();
    return impl.value_strings.cstring(str);
}

/// The loop this thread is running, refusing where the build has none.
///
/// The four loop crossings exist in every build; a build without the loop
/// refuses here, and `post`, `wake` and `await` are unreachable without what
/// this returns.
pub fn janet_current_loop() callconv(.c) *abi.Loop {
    requireJanetThread();
    return raise.toAbi(currentLoop());
}

/// A fiber value's status, reporting where the value is not a fiber.
pub fn janet_fiber_status_value(fiber: repr.Value) callconv(.c) abi.FiberStatus {
    requireJanetThread();
    return raise.toAbi(impl.value_fibers.statusChecked(fiber));
}

/// The precise pair a module keeps a value alive across a call into Janet
/// with. `gc.zig`'s root set is a multiset, so these cross as they stand: one
/// `janet_gcunroot` drops one rooting and reports whether it found one.
pub fn janet_gcroot(v: repr.Value) callconv(.c) void {
    requireJanetThread();
    return impl.gc_alloc.gcroot(v);
}

pub fn janet_gcunroot(v: repr.Value) callconv(.c) bool {
    requireJanetThread();
    return impl.gc_alloc.gcunroot(v);
}

/// Looks `method` up in a method table, for an abstract type's `get` slot.
pub fn janet_getmethod(method: [*:0]const u8, methods: [*]const method_type.CMethod, out: *repr.Value) callconv(.c) c_int {
    requireJanetThread();
    return impl.args.getmethod(method, methods, out);
}

/// Keeps a value reachable for the collection in progress, which is what an
/// abstract type's `gcmark` slot is for. `module.mark` is the author's side;
/// the definition is `gc/mark.zig`'s `mark`, and it cannot raise, so this
/// needs no report.
pub fn janet_mark(x: repr.Value) callconv(.c) void {
    requireJanetThread();
    return impl.gc_mark.mark(x);
}

/// The marshalling capabilities, which an abstract type's `marshal` and
/// `unmarshal` callbacks are handed.
///
/// The capability is the state struct, so nothing here casts: an
/// `*abi.Marshal` is a pointer to `marsh.MarshalState` and an `*abi.Unmarshal`
/// to `marsh.UnmarshalState`, and each `marsh.zig` entry point casts back on
/// its own first line. The runtime's own abstract types call those entry
/// points as ordinary Zig calls and never reach this file.
///
/// Seventeen of the twenty-one flatten a raise into a report, because a
/// `callconv(.c)` return has no room for an error union; `module.zig` rebuilds
/// it with `raise.fromAbi`. The four that cannot fail are the two flag reads,
/// `janet_marshal_abstract` and `janet_unmarshal_remaining`.
pub fn janet_marshal_abstract(m: *abi.Marshal, p: ?*anyopaque) callconv(.c) void {
    requireJanetThread();
    return impl.marsh.marshalAbstract(m, p);
}

pub fn janet_marshal_byte(m: *abi.Marshal, b: u8) callconv(.c) void {
    requireJanetThread();
    return raise.toAbi(impl.marsh.marshalByte(m, b));
}

pub fn janet_marshal_bytes(m: *abi.Marshal, bytes: [*]const u8, len: usize) callconv(.c) void {
    requireJanetThread();
    return raise.toAbi(impl.marsh.marshalBytes(m, bytes[0..len]));
}

pub fn janet_marshal_flags(m: *abi.Marshal) callconv(.c) c_int {
    requireJanetThread();
    return impl.marsh.marshalFlags(m);
}

pub fn janet_marshal_int(m: *abi.Marshal, x: i32) callconv(.c) void {
    requireJanetThread();
    return raise.toAbi(impl.marsh.marshalInt(m, x));
}

pub fn janet_marshal_int64(m: *abi.Marshal, x: i64) callconv(.c) void {
    requireJanetThread();
    return raise.toAbi(impl.marsh.marshalInt64(m, x));
}

pub fn janet_marshal_janet(m: *abi.Marshal, x: repr.Value) callconv(.c) void {
    requireJanetThread();
    return raise.toAbi(impl.marsh.marshalJanet(m, x));
}

pub fn janet_marshal_ptr(m: *abi.Marshal, p: ?*const anyopaque) callconv(.c) void {
    requireJanetThread();
    return raise.toAbi(impl.marsh.marshalPtr(m, p));
}

pub fn janet_marshal_size(m: *abi.Marshal, n: usize) callconv(.c) void {
    requireJanetThread();
    return raise.toAbi(impl.marsh.marshalSize(m, n));
}

pub fn janet_unmarshal_abstract(u: *abi.Unmarshal, size: usize) callconv(.c) ?*anyopaque {
    requireJanetThread();
    return raise.toAbi(impl.marsh.unmarshalAbstract(u, size));
}

pub fn janet_unmarshal_abstract_reuse(u: *abi.Unmarshal, p: ?*anyopaque) callconv(.c) void {
    requireJanetThread();
    return raise.toAbi(impl.marsh.unmarshalAbstractReuse(u, p));
}

pub fn janet_unmarshal_byte(u: *abi.Unmarshal) callconv(.c) u8 {
    requireJanetThread();
    return raise.toAbi(impl.marsh.unmarshalByte(u));
}

pub fn janet_unmarshal_bytes(u: *abi.Unmarshal, dest: [*]u8, len: usize) callconv(.c) void {
    requireJanetThread();
    return raise.toAbi(impl.marsh.unmarshalBytes(u, dest, len));
}

pub fn janet_unmarshal_ensure(u: *abi.Unmarshal, size: usize) callconv(.c) void {
    requireJanetThread();
    return raise.toAbi(impl.marsh.unmarshalEnsure(u, size));
}

pub fn janet_unmarshal_flags(u: *abi.Unmarshal) callconv(.c) c_int {
    requireJanetThread();
    return impl.marsh.unmarshalFlags(u);
}

pub fn janet_unmarshal_int(u: *abi.Unmarshal) callconv(.c) i32 {
    requireJanetThread();
    return raise.toAbi(impl.marsh.unmarshalInt(u));
}

pub fn janet_unmarshal_int64(u: *abi.Unmarshal) callconv(.c) i64 {
    requireJanetThread();
    return raise.toAbi(impl.marsh.unmarshalInt64(u));
}

pub fn janet_unmarshal_janet(u: *abi.Unmarshal) callconv(.c) repr.Value {
    requireJanetThread();
    return raise.toAbi(impl.marsh.unmarshalJanet(u));
}

pub fn janet_unmarshal_ptr(u: *abi.Unmarshal) callconv(.c) ?*anyopaque {
    requireJanetThread();
    return raise.toAbi(impl.marsh.unmarshalPtr(u));
}

pub fn janet_unmarshal_remaining(u: *abi.Unmarshal) callconv(.c) usize {
    requireJanetThread();
    return impl.marsh.unmarshalRemaining(u);
}

pub fn janet_unmarshal_size(u: *abi.Unmarshal) callconv(.c) usize {
    requireJanetThread();
    return raise.toAbi(impl.marsh.unmarshalSize(u));
}

/// The constructors, each returning a `Value`, so that no heap pointer reaches
/// an author.
///
/// The runtime's own constructors give back the aggregate, `strings.new` a
/// string and `arrays.newFrom` an `*Array`, and the wrap happens here, on this
/// side of the boundary, which is what makes the crossing one call instead of
/// two.
pub fn janet_new_array(items: [*]const repr.Value, len: usize) callconv(.c) repr.Value {
    requireJanetThread();
    return impl.value_helpers_wrap.abi.fromArray(impl.value_arrays.newFrom(items[0..len]));
}

pub fn janet_new_buffer(bytes: [*]const u8, len: usize) callconv(.c) repr.Value {
    requireJanetThread();
    return raise.toAbi(newBufferValue(bytes[0..len]));
}

pub fn janet_new_keyword(bytes: [*]const u8, len: usize) callconv(.c) repr.Value {
    requireJanetThread();
    return impl.value.fromBytes(bytes[0..len], .keyword);
}

pub fn janet_new_string(bytes: [*]const u8, len: usize) callconv(.c) repr.Value {
    requireJanetThread();
    return impl.value.fromBytes(bytes[0..len], .string);
}

pub fn janet_new_struct(kvs: [*]const abi.KV, len: usize) callconv(.c) repr.Value {
    requireJanetThread();
    return impl.value_helpers_wrap.abi.fromStruct(impl.value_structs.newFrom(kvs[0..len]));
}

pub fn janet_new_symbol(bytes: [*]const u8, len: usize) callconv(.c) repr.Value {
    requireJanetThread();
    return impl.value.fromBytes(bytes[0..len], .symbol);
}

pub fn janet_new_table(kvs: [*]const abi.KV, len: usize) callconv(.c) repr.Value {
    requireJanetThread();
    return impl.value_helpers_wrap.abi.fromTable(impl.value_tables.newFrom(kvs[0..len]));
}

pub fn janet_new_tuple(items: [*]const repr.Value, len: usize) callconv(.c) repr.Value {
    requireJanetThread();
    return impl.value_helpers_wrap.abi.fromTuple(impl.value_tuples.newFrom(items[0..len]));
}

/// The method after `key`, for an abstract type's `next` slot.
pub fn janet_nextmethod(methods: [*]const method_type.CMethod, key: repr.Value) callconv(.c) repr.Value {
    requireJanetThread();
    return impl.args.nextmethod(methods, key);
}

/// The same call as `janet_call_value` on a fresh fiber, reporting instead of
/// raising.
///
/// The fiber is always fresh. `entry.pcall` can recycle one through its slot
/// parameter; a recycled fiber is an ownership contract nothing else at this
/// boundary has, so the slot is a local here and what comes back is wrapped
/// into `out_fiber`.
///
/// A non-function is reported rather than raised, because this crossing has no
/// other channel: a fiber runs a `functions.Function` and nothing else, which
/// is what makes `(fiber/new <cfunction>)` refuse too. The message is built the
/// way `entry.checkCanResume` builds its status refusal, the one of its three
/// that formats where the other two are fixed strings, and it is safe for the
/// same reason: that renders `%s` of a static status name and this renders
/// `%t` of a static type name, so no user callback runs under a formatter with
/// nothing above it to raise into.
pub fn janet_pcall_value(
    f: repr.Value,
    args: [*]const repr.Value,
    len: usize,
    out_value: *repr.Value,
    out_fiber: *repr.Value,
) callconv(.c) abi.Signal {
    requireJanetThread();
    if (!repr.checkType(f, repr.Tag.function)) {
        out_fiber.* = impl.value_helpers_wrap.fromNil();
        out_value.* = impl.value_helpers_wrap.fromString(raise.total(
            impl.pp_format.formatc("expected function, got %t", .{f}),
            "a pcall callee refusal's message",
        ));
        return abi.Signal.@"error";
    }
    var slot: ?*impl.value_fibers.Fiber = null;
    const resumed = impl.vm_entry.pcall(impl.value_helpers_wrap.toFunction(f), args[0..len], &slot);
    out_value.* = resumed.value;
    out_fiber.* = if (slot) |fiber| impl.value_helpers_wrap.fromFiber(fiber) else impl.value_helpers_wrap.fromNil();
    return resumed.signal;
}

/// Asks the loop thread to run `cb(wake, ctx)` at its next turn.
///
/// This is the one entry point in this file that does not check its thread,
/// because it is the one a thread with no VM may call. It reads no
/// thread-local to do it: `ev.evPostEvent`'s target is a parameter and its
/// `orelse vm_state.current()` is not evaluated when the target is there,
/// which is what a `*abi.Loop` always is. Everything it then touches is on the
/// target VM: the listener count, atomically, and the self-pipe's write
/// descriptor.
///
/// It allocates nothing away from Windows, where the completion-port arm
/// allocates one event with libc per post.
pub fn janet_post(l: *abi.Loop, cb: module.PostCallback, ctx: *anyopaque) callconv(.c) void {
    return loop_ops.post(l, cb, ctx);
}

/// Enters an abstract type in the registry.
///
/// Without this a module can write an `unmarshal` callback that nothing ever
/// reaches: `marsh.unmarshalOneAbstract` looks the type up by the name on the
/// wire, and an unregistered type is an `unknown abstract type` raise.
pub fn janet_register_abstract_type(at: *const abi.AbstractType) callconv(.c) void {
    requireJanetThread();
    return raise.toAbi(impl.registry.registerAbstractType(at));
}

/// The fiber `await` suspends, as a `Value`.
pub fn janet_root_fiber_value() callconv(.c) repr.Value {
    requireJanetThread();
    return raise.toAbi(rootFiberValue());
}

/// Whether `x` is neither nil nor false.
pub fn janet_truthy(x: repr.Value) callconv(.c) bool {
    requireJanetThread();
    return repr.truthy(x);
}

/// Unwraps a number value as a 32-bit integer, reporting where it is not an
/// integer.
pub fn janet_unwrap_integer(x: repr.Value) callconv(.c) i32 {
    requireJanetThread();
    return impl.value_helpers_wrap.toIntegerAbi(x);
}

/// Unwraps a number value as a double.
pub fn janet_unwrap_number(x: repr.Value) callconv(.c) f64 {
    requireJanetThread();
    return impl.value_helpers_wrap.toNumber(x);
}

/// Unwraps a pointer value.
pub fn janet_unwrap_pointer(x: repr.Value) callconv(.c) ?*anyopaque {
    requireJanetThread();
    return impl.value_helpers_wrap.toPointer(x);
}

/// Puts `fiber` back on the run queue with `value`, and reports whether it
/// took.
///
/// It cannot raise: the posted callback it runs inside has no scope above it.
pub fn janet_wake(w: *abi.Wake, fiber: repr.Value, value: repr.Value) callconv(.c) bool {
    requireJanetThread();
    return loop_ops.wake(w, fiber, value);
}

/// A `bool` as a Janet boolean.
pub fn janet_wrap_boolean(b: bool) callconv(.c) repr.Value {
    requireJanetThread();
    return if (b) impl.value_helpers_wrap.abi.fromTrue() else impl.value_helpers_wrap.abi.fromFalse();
}

/// `raise.zig`'s flag protocol and its abort, which a module's own compilation
/// of `raise.zig` reaches.
///
/// Three of these four make no thread check and the fourth does, and what
/// decides them is reachability rather than cost: a check that cannot be the
/// first crossing on a thread guards nothing, because whichever crossing came
/// before it on that thread has already aborted.
///
/// `janet_zig_c_raise_take` and `janet_zig_c_raise_record` are not on the
/// author surface at all, since `module.zig` re-exports no `raise`, so the
/// only way to reach either is `raise.fromAbi`, which reads the flag back on
/// the statement after a crossing that set it. Charging them turned every
/// raising crossing into two checks: `module.getAbstract` is
/// `fromAbi(interface.rt.getabstract(...))`, the getter and the flag read.
///
/// `janet_zig_fatal` is `raise.total`'s abort, reached only where a raise
/// already happened, and `fatal.fatal` reads no VM state at all, so a check
/// there cannot prevent a null read and can only replace the module author's
/// abort message with a different one.
///
/// `janet_zig_signal_record` keeps its check, and that is what makes the rule
/// more than a saving. `module.await` is `raise.signal(.event, nil())`, and
/// `nil` is a published wrap that reads nothing, so `await` from a worker
/// thread would reach this as the first crossing of its life and record a
/// signal into a zeroed VM. It is the one member of this family that can be
/// first.
pub fn janet_zig_c_raise_record() callconv(.c) void {
    return impl.signal.cRaiseRecord();
}

pub fn janet_zig_c_raise_take() callconv(.c) c_int {
    return @intFromBool(impl.signal.cRaiseTake());
}

pub fn janet_zig_fatal(message: [*:0]const u8) callconv(.c) noreturn {
    return impl.fatal.fatal(message);
}

pub fn janet_zig_signal_record(sig: c_uint, message: repr.Value) callconv(.c) void {
    requireJanetThread();
    return impl.signal.signalRecord(abi.Signal.fromWire(sig), message);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// The loop this thread is running, or a refusal where the build has none.
fn currentLoop() raise.Raising(*abi.Loop) {
    if (comptime !config.ev) return raise.panic("event loop not enabled");
    return @ptrCast(impl.vm_state.current());
}

/// Walks a null-name-terminated C table into the installer.
///
/// This is the sentinel adapter the boundary keeps: it is the one place that
/// actually receives a table from outside. Internally a registration table is
/// a slice whose length is a comptime fact.
fn installSentinel(
    env: ?*tables.Table,
    regprefix: ?[*:0]const u8,
    registrations: [*]const abi.Reg,
) void {
    var it = impl.registry.Installer.init(env, regprefix, false);
    defer it.deinit();
    var row = registrations;
    while (row[0].name != null) : (row += 1) it.put(row[0]);
}

/// The one constructor that can raise, so the wrap is inside the raising
/// frame: `raise.toAbi` gives back a determinate zero, and a zeroed `*Buffer`
/// is not something to hand to `fromBuffer` even though no caller may read
/// what comes back.
fn newBufferValue(bytes: []const u8) raise.Raising(repr.Value) {
    return impl.value_helpers_wrap.abi.fromBuffer(try impl.value_buffers.newFrom(bytes));
}

/// The check every entry point below but `janet_post` opens with.
///
/// The declaration is `vm/state.zig`'s, because `args.zig`'s generated `*Abi`
/// shims are the other half of the same population and the two files share no
/// other boundary code.
const requireJanetThread = impl.vm_state.requireJanetThread;

/// The fiber `await` suspends, or a refusal where no fiber is running.
///
/// `vm/state.zig`'s `root_fiber` is the outermost fiber the interpreter is
/// running, which is the fiber the loop resumes: `ev.sleepAwait` sets its
/// timeout on that field and `ev.loop1` schedules what the timeout named.
///
/// The refusal is unreachable from a cfunction, and it is here because the
/// field is optional rather than because a caller can meet it:
/// `vm/entry.zig`'s `continueNoCheck` assigns `root_fiber` before it enters
/// `runVm`, so anything running under the interpreter has one.
fn rootFiberValue() raise.Raising(repr.Value) {
    const fiber = impl.vm_state.current().root_fiber orelse
        return raise.panic("no fiber is running");
    return impl.value_helpers_wrap.fromFiber(fiber);
}

/// The two capabilities are the same pointer, and this is the only place that
/// is written down.
///
/// `abi.Loop` and `abi.Wake` are both `opaque {}` over `vm_state.Vm`. They are
/// two types so that a worker thread with a `Loop` cannot reach `wake`, and
/// the cast is written here, in the one file that has both types, exactly as
/// `Env` and `Render` are.
fn vmOf(capability: anytype) *impl.vm_state.Vm {
    return @ptrCast(@alignCast(capability));
}
