//! The published surface, in one file.
//!
//! **What is published is what a native module reaches by symbol**, and
//! nothing else. `DESIGN.md` section 11 is the decision: the runtime runs
//! Janet code, a native module is written in Zig and loads through
//! `module.zig`, and there is no C API. So this file is the other side of
//! `module.zig`'s `extern fn` list plus the two `janet_zig_*` entry points
//! `raise.zig` reaches when it is compiled *into* a module rather than into
//! the runtime.
//!
//! Everything else a file needs from a neighbour it reaches by `@import`,
//! which keeps the error union, allows inlining, and is checked.
//!
//! **Why the entry points are separate from the definitions.** A slice has no
//! guaranteed in-memory representation, so Zig refuses one in a `callconv(.c)`
//! signature, and `export fn` forces that calling convention. A runtime
//! function that published its own symbol could not take a slice.
//!
//! **Two populations.** An entry point below calls ordinary Zig. The rest are
//! `@export`ed directly, because the thing they name is *already* a dedicated
//! C-ABI shim with no other caller -- `args.zig`'s generated getters, and the
//! `abi` namespace in `value/helpers/wrap.zig`. Those have no second hat to
//! take off, so each carries its signature in the `publish(...)` call.

const std = @import("std");
const config = @import("config");
const repr = @import("repr");
const strings = @import("value/strings.zig");
const abi = @import("abi");
const method_type = @import("method_type.zig");
const tables = @import("value/tables.zig");
const buffers = @import("value/buffers.zig");
const raise = @import("../api/raise.zig");

/// The runtime, in a namespace: a parameter name copied from a
/// definition cannot shadow an import that is not at this level.
/// The check every entry point below but `janet_post` opens with.
///
/// The declaration is `vm/state.zig`'s, because `args.zig`'s generated `*Abi`
/// shims are the other half of the same population and the two files share no
/// other boundary code. `DESIGN.md` section 15 states the rule.
const requireJanetThread = impl.vm_state.requireJanetThread;

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
    /// **Gated the way `root.zig` gates it.** `ev.zig` reaches
    /// `ev/backend.zig`, whose `VmBackend` has fields the VM state does not
    /// carry in a `-Dev=false` build, so importing it there compiles code
    /// against a struct that is not the one the build made.
    pub const ev = if (config.ev) @import("ev.zig") else struct {};
};

/// Export a target directly, stating the signature the symbol publishes.
///
/// **One declaration, so the symbol cannot drift from the assertion.** Taking
/// the pointer rather than the value is what lets one call do both: `@export`
/// needs a pointer to a container-level declaration, and `ptr.*` recovers the
/// type to compare.
fn publish(comptime name: []const u8, comptime ptr: anytype, comptime Signature: type) void {
    if (@TypeOf(ptr.*) != Signature) @compileError(
        "`" ++ name ++ "` publishes `" ++ @typeName(@TypeOf(ptr.*)) ++
            "` but this manifest states `" ++ @typeName(Signature) ++ "`",
    );
    @export(ptr, .{ .name = name });
}

// ==========================================================================
// The entry points
// ==========================================================================

// args.zig
//
pub fn janet_checkint(x: repr.Value) callconv(.c) c_int {
    requireJanetThread();
    return @intFromBool(impl.args.checkint(x));
}
pub fn janet_getmethod(method: [*:0]const u8, methods: [*]const method_type.CMethod, out: *repr.Value) callconv(.c) c_int {
    requireJanetThread();
    return impl.args.getmethod(method, methods, out);
}
pub fn janet_nextmethod(methods: [*]const method_type.CMethod, key: repr.Value) callconv(.c) repr.Value {
    requireJanetThread();
    return impl.args.nextmethod(methods, key);
}

// registry.zig
//
/// Walk a null-name-terminated C table into the installer.
///
/// This is the sentinel adapter `DESIGN.md` section 6 keeps: a boundary that
/// actually receives a table from outside. Internally a registration table is
/// a slice and its length is known at comptime.
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

pub fn janet_cfuns_ext(env: ?*tables.Table, regprefix: ?[*:0]const u8, registrations: [*]const abi.Reg) callconv(.c) void {
    requireJanetThread();
    installSentinel(env, regprefix, registrations);
}
pub fn janet_def(env: *tables.Table, name: [*:0]const u8, val: repr.Value, doc: ?[*:0]const u8) callconv(.c) void {
    requireJanetThread();
    return impl.registry.def(env, name, val, doc);
}
/// Without this a module can write an `unmarshal` callback that nothing ever
/// reaches: `marsh.unmarshalOneAbstract` looks the type up by the name on the
/// wire, and an unregistered type answers `unknown abstract type`.
pub fn janet_register_abstract_type(at: *const abi.AbstractType) callconv(.c) void {
    requireJanetThread();
    return raise.reported(impl.registry.registerAbstractType(at));
}

// signal.zig
//
// **Three of these four carry no thread check, and the fourth does.** They are
// the only exemptions from ruling 1 besides `janet_post`, and the rule that
// decides them is reachability rather than cost: a check that cannot be the
// first crossing on a thread guards nothing, because whichever crossing came
// before it on that thread has already aborted.
//
// `janet_zig_c_raise_take` and `janet_zig_c_raise_record` are `raise.zig`'s
// flag protocol and are not on the author surface at all -- `module.zig`
// re-exports no `raise` -- so the only way to reach either is
// `raise.crossing`, which reads the flag back on the statement *after* a
// crossing that set it. Charging them turned every raising crossing into two
// checks: `module.getAbstract` is `crossing(janet_getabstract(...))`, which is
// the getter and the flag read.
//
// `janet_zig_fatal` is `raise.total`'s abort, reached only where a raise
// already happened, and `fatal.fatal` reads no VM state at all -- so a check
// there cannot prevent a null read and can only replace the module author's
// abort message with a different one.
//
// **`janet_zig_signal_record` keeps its check, and that is what makes the rule
// more than a saving.** `module.await` is `raise.signal(.event, nil())`, and
// `nil` is a published wrap that reads nothing -- so `await` from a worker
// thread would reach this as the first crossing of its life and record a
// signal into a zeroed VM. It is the one member of this family that can be
// first.
pub fn janet_zig_c_raise_take() callconv(.c) c_int {
    return @intFromBool(impl.signal.cRaiseTake());
}
pub fn janet_zig_c_raise_record() callconv(.c) void {
    return impl.signal.cRaiseRecord();
}
pub fn janet_zig_fatal(message: [*:0]const u8) callconv(.c) noreturn {
    return impl.fatal.fatal(message);
}
pub fn janet_zig_signal_record(sig: c_uint, message: repr.Value) callconv(.c) void {
    requireJanetThread();
    return impl.signal.signalRecord(abi.Signal.fromWire(sig), message);
}

// utils.zig
//
pub fn janet_calloc(nmemb: usize, size: usize) callconv(.c) ?*anyopaque {
    requireJanetThread();
    return impl.utils.calloc(nmemb, size);
}
pub fn janet_free(ptr: ?*anyopaque) callconv(.c) void {
    requireJanetThread();
    return impl.utils.free(ptr);
}

// value/
//
pub fn janet_abstract(atype: *const abi.AbstractType, size: usize) callconv(.c) ?*anyopaque {
    requireJanetThread();
    return impl.value_abstracts.newBytes(atype, size);
}
/// The one operation an author has on a `*abi.Render`, which is what a
/// `tostring` callback is handed.
///
/// `buffers.pushBytes` takes a slice and this takes the pointer and the length
/// it is built from, for the reason this file's header gives. `raise.reported`
/// is what a hand-written abi is made of: the raise `pushBytes` returns cannot
/// travel a `callconv(.c)` return, so it is recorded and `module.push` rebuilds
/// it with `raise.crossing`.
pub fn janet_buffer_push_bytes(buffer: *buffers.Buffer, bytes: [*]const u8, len: usize) callconv(.c) void {
    requireJanetThread();
    return raise.reported(impl.value_buffers.pushBytes(buffer, bytes[0..len]));
}
/// Keep a value reachable for the collection in progress, which is what an
/// abstract type's `gcmark` slot is for. `module.mark` is the author's side;
/// the definition is `gc/mark.zig`'s `mark`, and it cannot raise, so this
/// carries no report.
pub fn janet_mark(x: repr.Value) callconv(.c) void {
    requireJanetThread();
    return impl.gc_mark.mark(x);
}
pub fn janet_cstring(str: [*:0]const u8) callconv(.c) [*:0]const u8 {
    requireJanetThread();
    return impl.value_strings.cstring(str);
}
pub fn janet_checktype(x: repr.Value, t: c_uint) callconv(.c) c_int {
    requireJanetThread();
    if (t >= repr.tag_count) return 0;
    return @intFromBool(repr.checkType(x, @enumFromInt(t)));
}
pub fn janet_unwrap_integer(x: repr.Value) callconv(.c) i32 {
    requireJanetThread();
    return impl.value_helpers_wrap.toIntegerAbi(x);
}
pub fn janet_unwrap_keyword(x: repr.Value) callconv(.c) strings.Keyword {
    requireJanetThread();
    return impl.value_helpers_wrap.toKeyword(x);
}
pub fn janet_unwrap_number(x: repr.Value) callconv(.c) f64 {
    requireJanetThread();
    return impl.value_helpers_wrap.toNumber(x);
}

// marsh.zig
//
// **The capability is the state struct**, so nothing here casts: an
// `*abi.Marshal` is a pointer to `marsh.MarshalState` and an `*abi.Unmarshal`
// to `marsh.UnmarshalState`, and each `marsh.zig` entry point casts back on
// its own first line. The runtime's own abstract types call those entry
// points as ordinary Zig calls and never reach this file.
//
// Seventeen of the twenty-one flatten a raise into a report, because a
// `callconv(.c)` return cannot carry an error union; `module.zig` rebuilds it
// with `raise.crossing`. The four that cannot fail are the two flag reads,
// `janet_marshal_abstract` and `janet_unmarshal_remaining`.
pub fn janet_marshal_size(m: *abi.Marshal, n: usize) callconv(.c) void {
    requireJanetThread();
    return raise.reported(impl.marsh.marshalSize(m, n));
}
pub fn janet_marshal_int(m: *abi.Marshal, x: i32) callconv(.c) void {
    requireJanetThread();
    return raise.reported(impl.marsh.marshalInt(m, x));
}
pub fn janet_marshal_int64(m: *abi.Marshal, x: i64) callconv(.c) void {
    requireJanetThread();
    return raise.reported(impl.marsh.marshalInt64(m, x));
}
pub fn janet_marshal_byte(m: *abi.Marshal, b: u8) callconv(.c) void {
    requireJanetThread();
    return raise.reported(impl.marsh.marshalByte(m, b));
}
pub fn janet_marshal_bytes(m: *abi.Marshal, bytes: [*]const u8, len: usize) callconv(.c) void {
    requireJanetThread();
    return raise.reported(impl.marsh.marshalBytes(m, bytes[0..len]));
}
pub fn janet_marshal_janet(m: *abi.Marshal, x: repr.Value) callconv(.c) void {
    requireJanetThread();
    return raise.reported(impl.marsh.marshalJanet(m, x));
}
pub fn janet_marshal_abstract(m: *abi.Marshal, p: ?*anyopaque) callconv(.c) void {
    requireJanetThread();
    return impl.marsh.marshalAbstract(m, p);
}
pub fn janet_marshal_ptr(m: *abi.Marshal, p: ?*const anyopaque) callconv(.c) void {
    requireJanetThread();
    return raise.reported(impl.marsh.marshalPtr(m, p));
}
pub fn janet_marshal_flags(m: *abi.Marshal) callconv(.c) c_int {
    requireJanetThread();
    return impl.marsh.marshalFlags(m);
}
pub fn janet_unmarshal_size(u: *abi.Unmarshal) callconv(.c) usize {
    requireJanetThread();
    return raise.reported(impl.marsh.unmarshalSize(u));
}
pub fn janet_unmarshal_int(u: *abi.Unmarshal) callconv(.c) i32 {
    requireJanetThread();
    return raise.reported(impl.marsh.unmarshalInt(u));
}
pub fn janet_unmarshal_int64(u: *abi.Unmarshal) callconv(.c) i64 {
    requireJanetThread();
    return raise.reported(impl.marsh.unmarshalInt64(u));
}
pub fn janet_unmarshal_byte(u: *abi.Unmarshal) callconv(.c) u8 {
    requireJanetThread();
    return raise.reported(impl.marsh.unmarshalByte(u));
}
pub fn janet_unmarshal_bytes(u: *abi.Unmarshal, dest: [*]u8, len: usize) callconv(.c) void {
    requireJanetThread();
    return raise.reported(impl.marsh.unmarshalBytes(u, dest, len));
}
pub fn janet_unmarshal_janet(u: *abi.Unmarshal) callconv(.c) repr.Value {
    requireJanetThread();
    return raise.reported(impl.marsh.unmarshalJanet(u));
}
pub fn janet_unmarshal_abstract(u: *abi.Unmarshal, size: usize) callconv(.c) ?*anyopaque {
    requireJanetThread();
    return raise.reported(impl.marsh.unmarshalAbstract(u, size));
}
pub fn janet_unmarshal_abstract_reuse(u: *abi.Unmarshal, p: ?*anyopaque) callconv(.c) void {
    requireJanetThread();
    return raise.reported(impl.marsh.unmarshalAbstractReuse(u, p));
}
pub fn janet_unmarshal_ptr(u: *abi.Unmarshal) callconv(.c) ?*anyopaque {
    requireJanetThread();
    return raise.reported(impl.marsh.unmarshalPtr(u));
}
pub fn janet_unmarshal_ensure(u: *abi.Unmarshal, size: usize) callconv(.c) void {
    requireJanetThread();
    return raise.reported(impl.marsh.unmarshalEnsure(u, size));
}
pub fn janet_unmarshal_remaining(u: *abi.Unmarshal) callconv(.c) usize {
    requireJanetThread();
    return impl.marsh.unmarshalRemaining(u);
}
pub fn janet_unmarshal_flags(u: *abi.Unmarshal) callconv(.c) c_int {
    requireJanetThread();
    return impl.marsh.unmarshalFlags(u);
}

// ==========================================================================
// Construction, and mutation through the `Value`
// ==========================================================================
//
// **Each answers a `Value`, so no heap pointer reaches an author.** The
// runtime's own constructors answer the aggregate -- `strings.new` a string,
// `arrays.newFrom` an `*Array` -- and the wrap happens here, on this side of
// the boundary, which is what makes the crossing one call instead of two.
// `DESIGN.md` section 15 is the rule.

pub fn janet_wrap_boolean(b: bool) callconv(.c) repr.Value {
    requireJanetThread();
    return if (b) impl.value_helpers_wrap.abi.fromTrue() else impl.value_helpers_wrap.abi.fromFalse();
}
pub fn janet_truthy(x: repr.Value) callconv(.c) bool {
    requireJanetThread();
    return repr.truthy(x);
}
pub fn janet_unwrap_pointer(x: repr.Value) callconv(.c) ?*anyopaque {
    requireJanetThread();
    return impl.value_helpers_wrap.toPointer(x);
}
pub fn janet_new_string(bytes: [*]const u8, len: usize) callconv(.c) repr.Value {
    requireJanetThread();
    return impl.value.fromBytes(bytes[0..len], .string);
}
pub fn janet_new_symbol(bytes: [*]const u8, len: usize) callconv(.c) repr.Value {
    requireJanetThread();
    return impl.value.fromBytes(bytes[0..len], .symbol);
}
pub fn janet_new_keyword(bytes: [*]const u8, len: usize) callconv(.c) repr.Value {
    requireJanetThread();
    return impl.value.fromBytes(bytes[0..len], .keyword);
}
pub fn janet_new_tuple(items: [*]const repr.Value, len: usize) callconv(.c) repr.Value {
    requireJanetThread();
    return impl.value_helpers_wrap.abi.fromTuple(impl.value_tuples.newFrom(items[0..len]));
}
pub fn janet_new_array(items: [*]const repr.Value, len: usize) callconv(.c) repr.Value {
    requireJanetThread();
    return impl.value_helpers_wrap.abi.fromArray(impl.value_arrays.newFrom(items[0..len]));
}
/// The one constructor that can raise, so the wrap is inside the raising
/// frame: `raise.reported` answers a determinate zero, and a zeroed `*Buffer`
/// is not something to hand to `fromBuffer` even though no caller may read
/// what comes back.
fn newBufferValue(bytes: []const u8) raise.Raising(repr.Value) {
    return impl.value_helpers_wrap.abi.fromBuffer(try impl.value_buffers.newFrom(bytes));
}
pub fn janet_new_buffer(bytes: [*]const u8, len: usize) callconv(.c) repr.Value {
    requireJanetThread();
    return raise.reported(newBufferValue(bytes[0..len]));
}
pub fn janet_new_struct(kvs: [*]const abi.KV, len: usize) callconv(.c) repr.Value {
    requireJanetThread();
    return impl.value_helpers_wrap.abi.fromStruct(impl.value_structs.newFrom(kvs[0..len]));
}
pub fn janet_new_table(kvs: [*]const abi.KV, len: usize) callconv(.c) repr.Value {
    requireJanetThread();
    return impl.value_helpers_wrap.abi.fromTable(impl.value_tables.newFrom(kvs[0..len]));
}
pub fn janet_get(ds: repr.Value, key: repr.Value) callconv(.c) repr.Value {
    requireJanetThread();
    return raise.reported(impl.value_helpers_access.get(ds, key));
}
pub fn janet_put(ds: repr.Value, key: repr.Value, val: repr.Value) callconv(.c) void {
    requireJanetThread();
    return raise.reported(impl.value_helpers_access.put(ds, key, val));
}
pub fn janet_length(x: repr.Value) callconv(.c) i32 {
    requireJanetThread();
    return raise.reported(impl.value_helpers_access.length(x));
}
pub fn janet_array_push_value(v: repr.Value, x: repr.Value) callconv(.c) void {
    requireJanetThread();
    return raise.reported(impl.value_arrays.pushChecked(v, x));
}
pub fn janet_buffer_push_value(v: repr.Value, bytes: [*]const u8, len: usize) callconv(.c) void {
    requireJanetThread();
    return raise.reported(impl.value_buffers.pushBytesChecked(v, bytes[0..len]));
}

// ==========================================================================
// Calling back into Janet
// ==========================================================================
//
// **The runtime's two shapes, published as they stand.** `vm/entry.zig`'s
// `call` and `pcall` are not edited here; `callValue` beside them is what
// widens `call`'s callee from a `*functions.Function` to any value `(f ...)`
// calls, and this file is its only caller.

/// `(f ...)`, from a module's frame, raising on anything but a return.
pub fn janet_call_value(f: repr.Value, args: [*]const repr.Value, len: usize) callconv(.c) repr.Value {
    requireJanetThread();
    return raise.reported(impl.vm_entry.callValue(f, args[0..len]));
}

/// The same call on a fresh fiber, reporting instead of raising.
///
/// **The fiber is always fresh.** `entry.pcall` can recycle one through its
/// slot parameter; a recycled fiber is an ownership contract nothing else at
/// this boundary has, so the slot is a local here and what comes back is
/// wrapped into `out_fiber`.
///
/// **A non-function is reported, not raised**, because this crossing has no
/// other channel: a fiber runs a `functions.Function` and nothing else, which
/// is why `(fiber/new <cfunction>)` refuses too. The message is built the way
/// `entry.checkCanResume` builds its *status* refusal -- the one of its three
/// that formats, where the other two are fixed strings -- and for the same
/// reason it is safe to: that renders `%s` of a static status name and this
/// renders `%t` of a static type name, so no user callback runs under a
/// formatter that has nothing above it to raise into.
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

pub fn janet_fiber_status_value(fiber: repr.Value) callconv(.c) abi.FiberStatus {
    requireJanetThread();
    return raise.reported(impl.value_fibers.statusChecked(fiber));
}

// The precise pair a module holds a value across a call into Janet with.
// `gc.zig`'s root set is a multiset, so these are published as they stand: one
// `janet_gcunroot` drops one rooting and answers whether it found one.
pub fn janet_gcroot(v: repr.Value) callconv(.c) void {
    requireJanetThread();
    return impl.gc_alloc.gcroot(v);
}
pub fn janet_gcunroot(v: repr.Value) callconv(.c) bool {
    requireJanetThread();
    return impl.gc_alloc.gcunroot(v);
}

// ==========================================================================
// Scheduling work through the event loop
// ==========================================================================
//
// **Four entry points over three runtime functions, none of them edited.**
// `ev.evPostEvent` already takes its target VM explicitly, `ev.schedule` is
// `scheduleGeneral` with the `.ok` signal, and `vm/state.zig` answers the VM
// and the fiber. What this file adds is the shim that packs a module author's
// callback into the runtime's own event message and unpacks it on the loop
// thread -- so that `ev.GenericMessage` never crosses and `abi.zig` gains no
// layout.
//
// **`janet_post` is the one entry point in this file with no thread check**,
// and its doc says why: it is the only one a thread with no VM may call.

/// The two capabilities are the same pointer, and this is the only place that
/// is written down.
///
/// `abi.Loop` and `abi.Wake` are both `opaque {}` over `vm_state.Vm`. They are
/// two types so that a worker thread holding a `Loop` cannot reach `wake` --
/// `DESIGN.md` section 15 -- and the substitution is asserted rather than
/// assumed, in `cabi_check.zig`'s `capabilityFor`, exactly as `Env` and
/// `Render` are.
fn vmOf(capability: anytype) *impl.vm_state.Vm {
    return @ptrCast(@alignCast(capability));
}

/// The loop this thread is running, refusing where the build has none.
///
/// **This is ruling 2 of `DESIGN.md` section 15's event-loop rule.** The four
/// functions exist in every build; a build without the loop refuses here, and
/// `post`, `wake` and `await` are unreachable without what this answers.
fn currentLoop() raise.Raising(*abi.Loop) {
    if (comptime !config.ev) return raise.panic("event loop not enabled");
    return @ptrCast(impl.vm_state.current());
}

pub fn janet_current_loop() callconv(.c) *abi.Loop {
    requireJanetThread();
    return raise.reported(currentLoop());
}

/// The fiber `await` suspends, as a `Value`.
///
/// `vm/state.zig`'s `root_fiber` is the outermost fiber the interpreter is
/// running, which is the one the loop resumes: `ev.sleepAwait` sets its
/// timeout on that field and `ev.loop1` schedules what the timeout named.
///
/// **The refusal is unreachable from a cfunction**, and it is here because the
/// field is optional rather than because a caller can meet it:
/// `vm/entry.zig`'s `continueNoCheck` assigns `root_fiber` before it enters
/// `runVm`, so anything running under the interpreter observes one.
fn rootFiberValue() raise.Raising(repr.Value) {
    const fiber = impl.vm_state.current().root_fiber orelse
        return raise.panic("no fiber is running");
    return impl.value_helpers_wrap.fromFiber(fiber);
}

pub fn janet_root_fiber_value() callconv(.c) repr.Value {
    requireJanetThread();
    return raise.reported(rootFiberValue());
}

/// The two operations that only exist under the loop.
///
/// A build without one still publishes both symbols -- ruling 2 -- and neither
/// is reachable, because reaching either needs a `*abi.Loop` and
/// `janet_current_loop` refuses to make one. The refusal here is therefore an
/// assertion about that argument rather than a path a program takes.
const loop_ops = if (config.ev) struct {
    /// What the loop thread runs off the self-pipe, and where the author's two
    /// pointers come back out of the runtime's message.
    ///
    /// **The context rides in `argp` and the callback in `argj`.** `argp` is
    /// the message's one `?*anyopaque` slot, which is what a context is; the
    /// callback needs a second slot and `argj` is the only other one that can
    /// hold a pointer without a type lie -- `fiber` is typed `*fibers.Fiber`
    /// and a function pointer is not one. A pointer-tagged `Value` is what
    /// `janet_wrap_pointer` already publishes for exactly this, and it is
    /// inert to the collector, which matters not at all here because nothing
    /// traces a message in flight: `ev.evMark` walks the spawn list and the
    /// timer queue, and an event sitting in the self-pipe is in neither.
    fn trampoline(msg: impl.ev.GenericMessage) callconv(.c) void {
        const cb: abi.PostCallback = @ptrCast(@alignCast(impl.value_helpers_wrap.toPointer(msg.argj)));
        cb(@ptrCast(impl.vm_state.current()), msg.argp.?);
    }

    fn post(l: *abi.Loop, cb: abi.PostCallback, ctx: *anyopaque) void {
        var msg: impl.ev.GenericMessage = .{};
        msg.argp = ctx;
        msg.argj = impl.value_helpers_wrap.fromPointer(@constCast(@as(*const anyopaque, @ptrCast(cb))));
        impl.ev.evPostEvent(vmOf(l), trampoline, msg);
    }

    fn wake(w: *abi.Wake, fiber: repr.Value, value: repr.Value) bool {
        // The capability names the VM whose queue this pushes onto, and
        // `ev.schedule` reads the *thread's*. They are the same VM by
        // construction -- the trampoline above built this `Wake` out of
        // `vm_state.current()` one call frame up -- and saying so here is what
        // makes the two types more than a naming convention.
        std.debug.assert(vmOf(w) == impl.vm_state.current());
        if (!repr.checkType(fiber, repr.Tag.fiber)) return false;
        const f = impl.value_helpers_wrap.toFiber(fiber);
        // **False exactly where the runtime would drop it**, which is two
        // conditions and not one. `ev.scheduleGeneral` returns without
        // queueing anything when the fiber carries the canceled flag, which
        // `ev.cancel` -- `ev/cancel` -- is what sets; and a fiber that has
        // finished cannot be resumed at all, which is what `fibers.canResume`
        // asks. Either way the module's context is still the module's to free,
        // and the `false` is how the callback learns to free it.
        if (!impl.value_fibers.canResume(f)) return false;
        if (impl.value_fibers.evFlags(f).canceled) return false;
        impl.ev.schedule(f, value);
        return true;
    }
} else struct {
    fn post(l: *abi.Loop, cb: abi.PostCallback, ctx: *anyopaque) void {
        _ = .{ l, cb, ctx };
        impl.fatal.fatal("event loop not enabled");
    }

    fn wake(w: *abi.Wake, fiber: repr.Value, value: repr.Value) bool {
        _ = .{ w, fiber, value };
        impl.fatal.fatal("event loop not enabled");
    }
};

/// Ask the loop thread to run `cb(wake, ctx)` at its next turn.
///
/// **This is the one entry point in this file that does not check its thread**,
/// because it is the one a thread with no VM may call. It reads no
/// thread-local to do it: `ev.evPostEvent`'s target is a parameter and its
/// `orelse vm_state.current()` is not evaluated when the target is there,
/// which is what a `*abi.Loop` always is. Everything it then touches is on the
/// target VM -- the listener count, atomically, and the self-pipe's write
/// descriptor.
///
/// It allocates nothing away from Windows, where the completion-port arm
/// allocates one event with libc per post.
pub fn janet_post(l: *abi.Loop, cb: abi.PostCallback, ctx: *anyopaque) callconv(.c) void {
    return loop_ops.post(l, cb, ctx);
}

/// Put `fiber` back on the run queue with `value`, answering whether it took.
///
/// It cannot raise: the posted callback it runs inside has no scope above it.
pub fn janet_wake(w: *abi.Wake, fiber: repr.Value, value: repr.Value) callconv(.c) bool {
    requireJanetThread();
    return loop_ops.wake(w, fiber, value);
}

// ==========================================================================
// The manifest
// ==========================================================================

comptime {
    @export(&janet_checkint, .{ .name = "janet_checkint" });
    @export(&janet_getmethod, .{ .name = "janet_getmethod" });
    @export(&janet_nextmethod, .{ .name = "janet_nextmethod" });
    @export(&janet_cfuns_ext, .{ .name = "janet_cfuns_ext" });
    @export(&janet_def, .{ .name = "janet_def" });
    @export(&janet_register_abstract_type, .{ .name = "janet_register_abstract_type" });
    @export(&janet_zig_c_raise_take, .{ .name = "janet_zig_c_raise_take" });
    @export(&janet_zig_c_raise_record, .{ .name = "janet_zig_c_raise_record" });
    @export(&janet_zig_fatal, .{ .name = "janet_zig_fatal" });
    @export(&janet_zig_signal_record, .{ .name = "janet_zig_signal_record" });
    @export(&janet_calloc, .{ .name = "janet_calloc" });
    @export(&janet_free, .{ .name = "janet_free" });
    @export(&janet_abstract, .{ .name = "janet_abstract" });
    @export(&janet_buffer_push_bytes, .{ .name = "janet_buffer_push_bytes" });
    @export(&janet_mark, .{ .name = "janet_mark" });
    @export(&janet_cstring, .{ .name = "janet_cstring" });
    @export(&janet_checktype, .{ .name = "janet_checktype" });
    @export(&janet_unwrap_integer, .{ .name = "janet_unwrap_integer" });
    @export(&janet_unwrap_keyword, .{ .name = "janet_unwrap_keyword" });
    @export(&janet_unwrap_number, .{ .name = "janet_unwrap_number" });
    @export(&janet_wrap_boolean, .{ .name = "janet_wrap_boolean" });
    @export(&janet_truthy, .{ .name = "janet_truthy" });
    @export(&janet_unwrap_pointer, .{ .name = "janet_unwrap_pointer" });
    @export(&janet_new_string, .{ .name = "janet_new_string" });
    @export(&janet_new_symbol, .{ .name = "janet_new_symbol" });
    @export(&janet_new_keyword, .{ .name = "janet_new_keyword" });
    @export(&janet_new_tuple, .{ .name = "janet_new_tuple" });
    @export(&janet_new_array, .{ .name = "janet_new_array" });
    @export(&janet_new_buffer, .{ .name = "janet_new_buffer" });
    @export(&janet_new_struct, .{ .name = "janet_new_struct" });
    @export(&janet_new_table, .{ .name = "janet_new_table" });
    @export(&janet_get, .{ .name = "janet_get" });
    @export(&janet_put, .{ .name = "janet_put" });
    @export(&janet_length, .{ .name = "janet_length" });
    @export(&janet_array_push_value, .{ .name = "janet_array_push_value" });
    @export(&janet_buffer_push_value, .{ .name = "janet_buffer_push_value" });
    @export(&janet_marshal_size, .{ .name = "janet_marshal_size" });
    @export(&janet_marshal_int, .{ .name = "janet_marshal_int" });
    @export(&janet_marshal_int64, .{ .name = "janet_marshal_int64" });
    @export(&janet_marshal_byte, .{ .name = "janet_marshal_byte" });
    @export(&janet_marshal_bytes, .{ .name = "janet_marshal_bytes" });
    @export(&janet_marshal_janet, .{ .name = "janet_marshal_janet" });
    @export(&janet_marshal_abstract, .{ .name = "janet_marshal_abstract" });
    @export(&janet_marshal_ptr, .{ .name = "janet_marshal_ptr" });
    @export(&janet_marshal_flags, .{ .name = "janet_marshal_flags" });
    @export(&janet_unmarshal_size, .{ .name = "janet_unmarshal_size" });
    @export(&janet_unmarshal_int, .{ .name = "janet_unmarshal_int" });
    @export(&janet_unmarshal_int64, .{ .name = "janet_unmarshal_int64" });
    @export(&janet_unmarshal_byte, .{ .name = "janet_unmarshal_byte" });
    @export(&janet_unmarshal_bytes, .{ .name = "janet_unmarshal_bytes" });
    @export(&janet_unmarshal_janet, .{ .name = "janet_unmarshal_janet" });
    @export(&janet_unmarshal_abstract, .{ .name = "janet_unmarshal_abstract" });
    @export(&janet_unmarshal_abstract_reuse, .{ .name = "janet_unmarshal_abstract_reuse" });
    @export(&janet_unmarshal_ptr, .{ .name = "janet_unmarshal_ptr" });
    @export(&janet_unmarshal_ensure, .{ .name = "janet_unmarshal_ensure" });
    @export(&janet_unmarshal_remaining, .{ .name = "janet_unmarshal_remaining" });
    @export(&janet_unmarshal_flags, .{ .name = "janet_unmarshal_flags" });
    @export(&janet_call_value, .{ .name = "janet_call_value" });
    @export(&janet_pcall_value, .{ .name = "janet_pcall_value" });
    @export(&janet_fiber_status_value, .{ .name = "janet_fiber_status_value" });
    @export(&janet_gcroot, .{ .name = "janet_gcroot" });
    @export(&janet_gcunroot, .{ .name = "janet_gcunroot" });
    @export(&janet_current_loop, .{ .name = "janet_current_loop" });
    @export(&janet_root_fiber_value, .{ .name = "janet_root_fiber_value" });
    @export(&janet_post, .{ .name = "janet_post" });
    @export(&janet_wake, .{ .name = "janet_wake" });

    publish("janet_fixarity", &impl.args.fixArityAbi, fn (i32, i32) callconv(.c) void);
    publish("janet_arity", &impl.args.checkArityAbi, fn (i32, i32, i32) callconv(.c) void);
    publish("janet_getnumber", &impl.args.GetNumber.abi, fn ([*]const repr.Value, i32) callconv(.c) f64);
    publish("janet_getinteger", &impl.args.GetInteger.abi, fn ([*]const repr.Value, i32) callconv(.c) i32);
    publish("janet_getsize", &impl.args.GetSize.abi, fn ([*]const repr.Value, i32) callconv(.c) usize);
    publish("janet_getuinteger", &impl.args.GetUInteger.abi, fn ([*]const repr.Value, i32) callconv(.c) u32);
    publish("janet_getboolean", &impl.args.GetBoolean.abi, fn ([*]const repr.Value, i32) callconv(.c) bool);
    publish("janet_getbytes", &impl.args.getBytesAbi, fn ([*]const repr.Value, i32) callconv(.c) abi.ByteView);
    publish("janet_getindexed", &impl.args.getIndexedAbi, fn ([*]const repr.Value, i32) callconv(.c) abi.IndexedView);
    publish("janet_getdictionary", &impl.args.getDictionaryAbi, fn ([*]const repr.Value, i32) callconv(.c) abi.DictView);
    publish("janet_getrange", &impl.args.getRangeAbi, fn ([*]const repr.Value, i32, i32, i32) callconv(.c) abi.Range);
    publish("janet_bytes_view", &impl.args.bytesViewAbi, fn (repr.Value, *abi.ByteView) callconv(.c) bool);
    publish("janet_indexed_view", &impl.args.indexedViewAbi, fn (repr.Value, *abi.IndexedView) callconv(.c) bool);
    publish("janet_dictionary_view", &impl.args.dictionaryViewAbi, fn (repr.Value, *abi.DictView) callconv(.c) bool);
    publish("janet_getabstract", &impl.args.getAbstractAbi, fn ([*]const repr.Value, i32, *const abi.AbstractType) callconv(.c) ?*anyopaque);
    publish("janet_wrap_nil", &impl.value_helpers_wrap.abi.fromNil, fn () callconv(.c) repr.Value);
    publish("janet_wrap_number", &impl.value_helpers_wrap.abi.fromNumber, fn (f64) callconv(.c) repr.Value);
    publish("janet_wrap_string", &impl.value_helpers_wrap.abi.fromString, fn ([*:0]const u8) callconv(.c) repr.Value);
    publish("janet_wrap_abstract", &impl.value_helpers_wrap.abi.fromAbstract, fn (?*anyopaque) callconv(.c) repr.Value);
    publish("janet_wrap_pointer", &impl.value_helpers_wrap.abi.fromPointer, fn (?*anyopaque) callconv(.c) repr.Value);
}
