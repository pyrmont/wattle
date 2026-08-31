//! What a Zig contract needs, and the deliberately short list of it.
//!
//! The list is deliberately short. A contract inside the runtime's compilation
//! crosses no boundary, so nothing here is an adapter: an equivalent written
//! for a contract on the far side of a symbol table is nine times this size,
//! and almost all of it exists to move a raise or a cfunction across the C
//! ABI. What is left is a protected scope, which is a real mechanism.
//!
//! ## The scope is not a formality
//!
//! A raise consults `vm.return_reg` to decide where it is going.
//! `janet_signal_plan` answers `TOP_LEVEL` when that pointer is null, and a
//! `TOP_LEVEL` raise ends the process rather than reporting — so a contract
//! that means to *observe* a raise has to open a scope first, even though
//! nothing jumps any more. `janet_try_init` is what points `return_reg` at a
//! payload slot; `janet_restore` puts back what was there.
//!
//! It is worth restating because the natural assumption is the opposite one:
//! that the scope went with the `setjmp`. The `setjmp` was never the scope,
//! only the travel.
//!
//! ## A contract that expects success needs no scope
//!
//! `try` is enough. If such a call raises anyway the process ends with the
//! runtime's own top-level message, which names the panic — a loud failure and
//! an accurate one. Opening a scope to catch a raise the contract did not
//! expect would only replace that message with a less informative assertion.

const std = @import("std");
const types = @import("types");
const repr = @import("repr");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const debug = @import("subsystems").debug;
const value = @import("subsystems").value;
const config = @import("config");
const structs = @import("subsystems").value.structs;
const gc_alloc = @import("subsystems").gc_alloc;
const utils = @import("subsystems").utils;
const order = @import("subsystems").value.order;
const stretchy = @import("subsystems").stretchy;
const core_env = @import("subsystems").env;
const signal_core = @import("subsystems").signal;
const registry = @import("subsystems").registry;
const wrap = @import("subsystems").value.wrap;
const vm_lifecycle = @import("subsystems").lifecycle;
const arrays = @import("subsystems").value.arrays;
const fibers = @import("subsystems").value.fibers;
const vm_entry = @import("subsystems").vm_entry;
const pp_describe = @import("subsystems").pp_describe;
const ev = @import("subsystems").ev;

/// `janet_init`, reached by import rather than through the symbol.
///
/// `vm_lifecycle.init` **raises** -- the core image can fail to unmarshal,
/// which is what a broken bootstrap looks like from here. Through the C ABI
/// that raise became a report with nothing to consume it, so the process died
/// at the next protected scope naming neither the contract nor the cause. Here
/// it is an error, and the `@panic` names both.
///
/// A contract that means to *observe* an init failure should call
/// `vm_lifecycle.init` itself under `raised`; this is for the sixty-four that
/// only need a VM.
pub fn init() void {
    _ = vm_lifecycle.init() catch @panic("harness: janet_init raised");
}

/// `janet_array_push`, on the same rule and for the same reason.
///
/// Thirty-nine sites across the contracts, every one of them pushing onto an
/// array it has just made, where the raise `buffer_array.arrayPush` carries is
/// a capacity overflow no contract is arranging. A contract that means to test
/// *that* should call `arrayPush` itself under `raised`.
pub fn arrayPush(array: *types.JanetArray, val: repr.Value) void {
    arrays.push(array, val) catch @panic("harness: janet_array_push raised");
}

/// `janet_core_env(null)`, likewise, and the same reasoning.
///
/// Answers a non-null table.
pub fn coreEnv() *types.JanetTable {
    return core_env.coreEnv(null) catch @panic("harness: janet_core_env raised");
}

/// What a raise carried: the signal it raised with, and the value it left in
/// the enclosing scope's return register.
pub const Raise = struct {
    signal: types.Signal,
    payload: repr.Value,

    /// Whether the payload is the string `expected`. Most panics carry one,
    /// and asserting on the message is what distinguishes "it refused" from
    /// "it refused for the reason this contract is about".
    pub fn says(self: Raise, expected: []const u8) bool {
        if (!isType(self.payload, repr.Tag.string)) return false;
        const message = wrap.toString(self.payload);
        const length: usize = @intCast(types.stringHead(message).length);
        return std.mem.eql(u8, message[0..length], expected);
    }

    /// The same for a message only some of which is reproducible. An abstract
    /// renders as `<type/name 0x...>`, so a refusal that names one is pinned by
    /// its prefix and the address is left out — which is what the C contracts
    /// spelled as a second `EXPECT_PANIC_PREFIX` macro beside the first.
    ///
    /// Every case that needs this is a case about an abstract, so the prefix
    /// always ends where the rendering begins and nothing after it is dropped
    /// silently.
    pub fn beginsWith(self: Raise, expected: []const u8) bool {
        if (!isType(self.payload, repr.Tag.string)) return false;
        const message = wrap.toString(self.payload);
        const length: usize = @intCast(types.stringHead(message).length);
        return std.mem.startsWith(u8, message[0..length], expected);
    }

    /// The mirror of `beginsWith`, for a message whose *head* is the part that
    /// cannot be reproduced.
    ///
    /// It exists for `peg`, where every grammar error renders the form being
    /// compiled through `%p` before it says anything -- so a mutable form
    /// contributes an address, and a nested one contributes a thousand rules.
    pub fn endsWith(self: Raise, expected: []const u8) bool {
        if (!isType(self.payload, repr.Tag.string)) return false;
        const message = wrap.toString(self.payload);
        const length: usize = @intCast(types.stringHead(message).length);
        return std.mem.endsWith(u8, message[0..length], expected);
    }
};

/// Call `function` with `args` under a protected scope, and answer the raise
/// it made — or null if it returned.
///
/// The result is discarded on the returning path. A contract that wants the
/// value calls the function directly with `try`; this one is for the cases
/// where the refusal *is* the behaviour under test.
///
///     const r = harness.raised(subsystems.args.getBytes, .{ argv, 0 }).?;
///     std.debug.assert(r.says("bad slot #0, expected bytes, got nil"));
///
/// The payload is read before `janet_restore` runs, because restoring is what
/// puts the outer scope's return register back.
pub fn raised(function: anytype, args: anytype) ?Raise {
    var state: types.JanetTryState = undefined;
    signal_core.tryInit(&state);
    defer signal_core.restore(&state);
    if (@call(.auto, function, args)) |_| {
        return null;
    } else |_| {
        return .{ .signal = vm_lifecycle.current().pending_signal, .payload = state.payload };
    }
}

/// The VM this thread is running.
///
/// `vm/lifecycle.zig`'s `current()` is the owner's accessor, and a contract is
/// inside the compilation, so it can call it. There is no second view to
/// compare it against: `janet_vm` is not a symbol, so no file reaches the
/// storage through the symbol table and no contract can put two spellings of
/// one address on either side of an `==`.
pub fn vm() *types.Vm {
    return vm_lifecycle.current();
}

/// An abi called and its report consumed, which is what a Zig contract does
/// with a `janet.h` entry point that is still a `raise.reported` wrapper.
///
/// This is the whole protocol from this side: the flag `raise.tookCRaise`
/// reads is the VM's `c_raised`, and a contract inside the compilation can
/// read it directly.
///
/// The report has to be taken **inside** the scope. `janet_restore` aborts on
/// an outstanding one, which is what makes a leaked report surface at a scope
/// boundary rather than at the raise, and it would fire here rather than
/// answering the question asked.
///
/// Reach for `raised` instead wherever the subject is a Zig function.
pub fn abiRaised(abi: anytype, args: anytype) ?Raise {
    var state: types.JanetTryState = undefined;
    signal_core.tryInit(&state);
    defer signal_core.restore(&state);
    // Discarded rather than called bare, because an abi need not return void:
    // on the raising path what it answers is `reportToC`'s zero value rather
    // than anything a contract should read.
    _ = @call(.auto, abi, args);
    if (!raise.tookCRaise()) return null;
    return .{ .signal = vm_lifecycle.current().pending_signal, .payload = state.payload };
}

/// A core cfunction by name, with the calling convention it actually has.
///
/// `janet_resolve_core` answers a `Value` holding a `JanetCFunction`, which is
/// a pointer to a raising Zig function rather than to a C one.
/// `raise.cfunction` is the cast that says so.
pub fn core(name: [*:0]const u8) raise.CFunction {
    const val = registry.resolveCore(name);
    std.debug.assert(isType(val, repr.Tag.cfunction));
    return raise.cfunction(wrap.toCfunction(val));
}

/// Call a core cfunction by name over a slice of arguments.
///
/// This is the `argc`/`argv` split, which a contract otherwise spells at every
/// call from an array it already has.
///
/// It is here rather than in each contract because `net_sockets`,
/// `filewatch_core` and `ev_loop` all drive their whole surface this way. A
/// contract that wants the *value* uses this with `try`;
pub fn callCore(name: [*:0]const u8, argv: []repr.Value) raise.Error!repr.Value {
    return core(name)(argv);
}

/// The same call under a protected scope, answering the raise it made -- or
/// null if it returned. `raised` with the resolution and the split folded in.
pub fn coreRaised(name: [*:0]const u8, argv: []repr.Value) ?Raise {
    return raised(core(name), .{argv});
}

/// Whether this build compiled the event loop, which decides how a form that
/// waits gets driven. `janet.h` guards `janet_schedule` and `janet_loop` with
/// `#ifdef JANET_EV`, so this is the same input the declarations are behind
/// rather than a second belief about the configuration.
pub const has_ev = config.ev;

/// One Janet form, run in a fiber of its own and driven to completion.
///
/// `janet_dostring` evaluates each *top level* form in its own fiber and does
/// not drive the event loop, so a form that spawns a process and then waits on
/// it can outlive the wait that follows: the spawn is scheduled, the wait
/// suspends, `dostring` returns, and the next form runs against a fiber that
/// has not finished. Wrapping the whole source in `(fn [] ...)` makes it one
/// form, and scheduling that one fiber and running the loop is what makes
/// "the source finished" mean what it says.
///
/// It is here because two contracts need it: `os_process` and `os_surface`,
/// the two whose subjects spawn.
/// The fiber is rooted for the length of the run: it is reachable from the
/// scheduler while it is queued, but not between `janet_fiber` and
/// `janet_schedule`, and the compile of the *next* contract's source is an
/// allocation that can collect.
pub fn inFiber(environment: *types.JanetTable, source: []const u8) void {
    var buffer: [16384]u8 = undefined;
    const wrapped = std.fmt.bufPrintZ(&buffer, "(fn [] {s})", .{source}) catch
        @panic("harness.inFiber: source does not fit");

    var val = wrap.fromNil();
    if (core_env.dostring(environment, wrapped, "contract", &val) != 0) {
        std.debug.print("harness.inFiber: could not compile\n{s}\n", .{source});
        std.debug.print("             got: {s}\n", .{pp_describe.toString(val)});
        @panic("harness.inFiber: compile failed");
    }
    std.debug.assert(isType(val, repr.Tag.function));

    const fiber = fibers.new(wrap.toFunction(val), 64, 0, null).?;
    fiber.*.env = environment;

    if (has_ev) {
        const wrapped_fiber = wrap.fromFiber(fiber);
        gc_alloc.gcroot(wrapped_fiber);
        defer _ = gc_alloc.gcunroot(wrapped_fiber);
        ev.schedule(fiber, wrap.fromNil());
        raise.reported(ev.loop());
        if (fibers.status(fiber) != types.FiberStatus.dead) {
            std.debug.print("harness.inFiber: did not finish\n{s}\n", .{source});
            @panic("harness.inFiber: fiber is not dead");
        }
    } else {
        var result = wrap.fromNil();
        const signal = vm_entry.continueFiber(fiber, wrap.fromNil(), &result);
        if (signal != types.Signal.ok) {
            raise.reported(debug.stacktraceExt(fiber, result, ""));
            std.debug.print("harness.inFiber: raised\n{s}\n", .{source});
            @panic("harness.inFiber: unexpected signal");
        }
    }
}

/// `janet_checktype` as a predicate.
///
/// It answers `c_int` because `janet.h` declares it for C, and every contract
/// in the tree uses it as a condition. One `!= 0` here rather than several
/// hundred at the sites.
pub inline fn isType(val: repr.Value, want: anytype) bool {
    return repr.checkType(val, want);
}

/// `janet_equals` as a predicate, for the same reason as `isType`.
pub inline fn equals(left: repr.Value, right: repr.Value) bool {
    return order.equals(left, right) != 0;
}

/// `janet_u64(x)`: the sixty-four bits of payload, which is the one Janet macro
/// whose *spelling* changes with the value representation -- `(x).u64` under
/// either NaN-boxed layout, where the value is a union, and `(x).as.u64` under
/// the tagged one, where it is a struct wrapping one.
///
/// It has no function form, so unlike `janet_checktype` a Zig caller has to
/// write it out. It is here rather than in each contract because two need it:
/// `value_wrap` for "same value" and for its bit-layout section, `value_order`
/// for the pointer hash.
///
/// The layout is read off `repr.Value` rather than from a `JANET_NANBOX_*`
/// macro: a macro derived from the compiler's predefines is not reliable
/// through a translation, and the build states the representation outright.
pub inline fn u64Of(x: repr.Value) u64 {
    return if (comptime config.value_repr != .tagged) @field(x, "u64") else @field(x.as, "u64");
}

/// An opcode widened to the `u32` a bytecode word is.
///
/// `janet.h`'s `JOP_*` are enumeration constants, so translate-c gives them
/// type `c_int`, and `c.JOP_JUMP | (@as(u32, 0xFFFFFE) << 8)` is a `c_int`
/// expression that cannot hold its own value:
///
///     error: type 'c_int' cannot represent integer value '4294966784'
///
/// Every contract that builds a bytecode word by hand meets this -- five did
/// on the day this was written -- and the fix is a widening cast that has to
/// go somewhere. Here, once, rather than at each of the sites.
pub inline fn op(operation: anytype) u32 {
    return @intCast(operation);
}

/// The same opcode narrowed to the `u8` an emit entry point takes.
///
/// There are two of these because a bytecode word and an emit parameter are
/// different widths: `janetc_emit_s` and its nine siblings take the operation
/// as a `u8`, and the word they build carries it in the low byte of a `u32`.
/// A contract that both emits an instruction and then asserts on the word it
/// produced needs each in turn, and neither cast reads as obviously correct
/// at the site, so both are named here.
pub inline fn opcode(operation: anytype) u8 {
    return @intCast(operation);
}

/// Whether `value` is the number `expected`, which is the assertion a contract
/// over bytecode or a decoded structure makes most often. Both halves matter:
/// a value of the wrong *type* unwraps to something arbitrary rather than
/// failing, so checking the type first is what makes the comparison mean
/// anything.
pub fn integerIs(val: repr.Value, expected: i32) bool {
    return isType(val, repr.Tag.number) and wrap.toInteger(val) == expected;
}

/// The same for the three string-like types, which a contract has to tell
/// apart: `janet_unwrap_string` will happily read a keyword.
pub fn stringValueIs(val: repr.Value, expected: [*:0]const u8) bool {
    return isType(val, repr.Tag.string) and stringIs(wrap.toString(val), expected);
}

pub fn symbolIs(val: repr.Value, expected: [*:0]const u8) bool {
    return isType(val, repr.Tag.symbol) and stringIs(wrap.toSymbol(val), expected);
}

pub fn keywordIs(val: repr.Value, expected: [*:0]const u8) bool {
    return isType(val, repr.Tag.keyword) and stringIs(wrap.toKeyword(val), expected);
}

/// A struct's field by keyword name. Every contract that reads a structure the
/// runtime built spells this, and spelling it once keeps the `ckeywordv` out
/// of the assertions.
pub fn field(structure: types.JanetStruct, name: [*:0]const u8) repr.Value {
    return structs.get(structure, value.fromBytes(std.mem.span(name), .keyword));
}

/// `janet_wrap_integer`, written out rather than called.
///
/// **The one `janet_wrap_*` a Zig contract may not call**, and the reason is
/// worth having in one place because every contract that builds an integer
/// argument would otherwise meet it. `janet.h` declares
/// Janet declares `JANET_API Value janet_wrap_integer(int32_t)` beside a macro
/// of the same name, and defines the *function* only inside
/// `#if defined(JANET_NANBOX_32) || defined(JANET_NANBOX_64)`. C callers get
/// the macro; a Zig caller links everywhere except `-Dnanbox=false`, where the
/// symbol does not exist.
///
/// Four subsystems write these three lines out with the reason at the site,
/// and `FOUND.md` has the entry. It is here so that a contract does not become
/// the eighth.
pub inline fn wrapInteger(x: i32) repr.Value {
    return wrap.fromNumber(@floatFromInt(x));
}

/// The same, for a function a reduced build may not register at all.
///
/// A contract that covers one section of a subsystem the configuration
/// compiled out has two ways to skip it: read a condition out of `options`, or
/// ask the environment. Asking is better where the two would say the same
/// thing, because `options` names *subsystems* and what is missing here is a
/// *registration* -- `os/cpu-count` is absent from a reduced-OS build while
/// `os_platform` itself is compiled either way, so no field of `Selection`
/// answers the question directly.
pub fn coreOptional(name: [*:0]const u8) ?raise.CFunction {
    const val = registry.resolveCore(name);
    if (!isType(val, repr.Tag.cfunction)) return null;
    return raise.cfunction(wrap.toCfunction(val));
}

/// `janet_cstrcmp` as a predicate, which is how every contract wants it.
pub fn stringIs(string: types.JanetString, expected: [*:0]const u8) bool {
    return utils.cstrcmp(string, expected) == 0;
}

/// The compiler's growable vector, spelled the way a contract wants it.
///
/// The arithmetic is `src/zig/stretchy.zig`'s; this is the element type
/// inferred from the pointer, so that a contract writes
/// `harness.vector.push(&v, x)` rather than naming the element at every call.
///
/// **`test/vector.zig` does not use this**, and must not: it is the contract
/// *on* that arithmetic, so both sides of its comparison have to come from
/// different files. It restates the prefix itself.
///
/// A vector is `?[*]Element` and may be null, which is what an empty one is.
pub const vector = struct {
    fn Element(comptime Pointer: type) type {
        const info = @typeInfo(Pointer);
        const target = if (info == .optional) info.optional.child else Pointer;
        return @typeInfo(target).pointer.child;
    }

    pub fn count(v: anytype) i32 {
        return stretchy.count(Element(@TypeOf(v)), v);
    }

    pub fn capacity(v: anytype) i32 {
        return stretchy.capacity(Element(@TypeOf(v)), v);
    }

    /// `janet_v_push`. Takes the vector *variable* rather than its value,
    /// because growing it moves the allocation.
    pub fn push(v: anytype, val: Element(@TypeOf(v.*))) void {
        stretchy.push(Element(@TypeOf(v.*)), v, val);
    }

    /// `janet_v_empty`: the count goes to zero and the allocation stays.
    pub fn empty(v: anytype) void {
        stretchy.setCount(Element(@TypeOf(v)), v, 0);
    }

    /// The count written directly, which `test/emit_core.zig` needs to fill a
    /// constant pool that would take quadratic time to fill honestly. Nothing
    /// but a contract has a reason to do this.
    pub fn setCount(v: anytype, n: i32) void {
        stretchy.setCount(Element(@TypeOf(v)), v, n);
    }

    /// `janet_v_free`, which is `janet_sfree` on the raw prefix. A vector
    /// belongs to the scratch allocator rather than to the collector.
    pub fn free(v: anytype) void {
        stretchy.free(Element(@TypeOf(v)), v);
    }
};

/// Declarations a contract needs and no module publishes.
///
/// A caller declares what it needs. Six subsystems write the declaration they
/// need at the head of their own file, and a contract does the same; what goes
/// here is the reason, once, so that the next contract adds a line instead of
/// re-deriving it.
///
/// Two of these take a `Value` or a `JanetKV *`, which the usual justification
/// ("no Janet type crosses, so there is no second spelling of one") does not
/// cover. It still holds: the `types.JanetKV` in these signatures **is** the
/// tree's one spelling rather than a second.
pub const internal = struct {
    // util.h
    pub extern fn janet_tablen(n: i32) callconv(.c) i32;
    pub extern fn janet_string_calchash(str: ?[*]const u8, len: i32) callconv(.c) i32;
    pub extern fn janet_array_calchash(array: ?[*]const repr.Value, len: i32) callconv(.c) i32;
    pub extern fn janet_kv_calchash(kvs: ?[*]const types.JanetKV, len: i32) callconv(.c) i32;
    pub extern fn janet_struct_put_ext(st: [*]types.JanetKV, key: repr.Value, val: repr.Value, replace: c_int) callconv(.c) void;
    pub extern fn janet_table_get_keyword(t: *types.JanetTable, keyword: [*:0]const u8) callconv(.c) repr.Value;
    pub extern fn janet_table_proto_flatten(t: *types.JanetTable) callconv(.c) *types.JanetTable;
    pub extern fn janet_registry_get(key: types.JanetCFunction) callconv(.c) ?*types.JanetCFunRegistry;
    // `janet_hash_mix`, `safe_memcpy`, `janet_strbinsearch` and the two
    // dictionary probes have no published declaration, so `test/utils.zig` is
    // their only caller outside the runtime and each is one line here rather
    // than a private block at the head of that file.
    pub extern fn janet_hash_mix(input: u32, more: u32) callconv(.c) u32;
    pub extern fn safe_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void;
    pub extern fn janet_strbinsearch(
        tab: ?*const anyopaque,
        tabcount: usize,
        itemsize: usize,
        key: [*:0]const u8,
    ) callconv(.c) ?*const anyopaque;
    pub extern fn janet_dict_find(
        buckets: [*]const types.JanetKV,
        cap: i32,
        key: repr.Value,
    ) callconv(.c) ?*const types.JanetKV;
    pub extern fn janet_dict_find_keyword(
        buckets: [*]const types.JanetKV,
        cap: i32,
        cstr: [*]const u8,
        cstr_len: i32,
    ) callconv(.c) ?*const types.JanetKV;
    pub extern fn janet_binding_from_entry(entry: repr.Value) callconv(.c) types.JanetBinding;
    pub extern fn janet_get_core_table(name: [*:0]const u8) callconv(.c) ?*types.JanetTable;

    pub extern fn janet_registry_put(
        key: types.JanetCFunction,
        name: ?[*:0]const u8,
        name_prefix: ?[*:0]const u8,
        source_file: ?[*:0]const u8,
        source_line: i32,
    ) callconv(.c) void;

    // util.h, again: the two allocators every dictionary's bucket array comes
    // from. `value_wrap.zig` defines them and `test/value_wrap.zig` is the only
    // caller outside the containers.
    pub extern fn janet_memalloc_empty(count: i32) callconv(.c) ?*anyopaque;
    pub extern fn janet_memempty(mem: [*]types.JanetKV, count: i32) callconv(.c) void;

    // symcache.h
    pub extern fn janet_symbol_deinit(sym: [*:0]const u8) callconv(.c) void;
};

/// `fiber.h`'s frame macros, which `@cImport` does not translate.
///
/// `janet_stack_frame` is the cast from a stack slot back to the header that
/// precedes it, and `janet_fiber_frame` is that composed with the fiber's
/// current frame index. Three contracts need them: `vm_lifecycle` to build a
/// frame to decode, `vm_entry` to read the program counter a step stopped at,
/// and `vm_calls` to place arguments where `JOP_CALL` would have left them.
///
/// `test/fiber_core.zig` predates this and keeps a private copy beside two
/// other `fiber.h` macros it needs and nothing else does. Retrofitting it
/// would change a contract that is verified capable of failing in order to
/// change nothing, which is the same call `heap` records one declaration up.
pub const frame = struct {
    /// `janet_stack_frame(fiber->data + index)`.
    pub fn at(fiber: *types.JanetFiber, index: i32) *types.JanetStackFrame {
        const base = fiber.data.? + @as(usize, @intCast(index));
        return @ptrCast(@alignCast(base - @as(usize, @intCast(constants.JANET_FRAME_SIZE))));
    }

    /// `janet_fiber_frame(fiber)`: the frame the fiber is stopped in.
    pub fn current(fiber: *types.JanetFiber) *types.JanetStackFrame {
        return at(fiber, fiber.frame);
    }
};

/// The collector's two heap lists, as a contract reads them.
///
/// `janet_gc_header`, `janet_gc_type` and their kin are function-like macros
/// over `JanetGCObject`, which no translation carries across; `types.zig` owns
/// the head arithmetic for all of them. Four contracts need the same three
/// lines to answer the same two questions: what memory type did the
/// constructor stamp, and which list did that put the block on. Those two
/// questions are how a container contract sees the collector at all.
///
/// The collector's own four contracts predate this and keep private copies;
/// each uses `headerOf` for more than walking a list, and retrofitting them
/// would change four contracts that are verified capable of failing in order
/// to change nothing.
pub const heap = struct {
    /// Every collectable block begins with its `JanetGCObject`, so the block
    /// pointer *is* the header. `janet_gc_header` is that cast and nothing
    /// else.
    pub fn headerOf(block: ?*anyopaque) *types.JanetGCObject {
        return @ptrCast(@alignCast(block.?));
    }

    /// `janet_gc_type`: the low byte of the flags word, which is what decides
    /// which of `janet_deinit_block`'s cases will eventually free the block
    /// and which of the two lists it is on.
    pub fn memoryType(block: ?*anyopaque) types.MemoryType {
        return headerOf(block).memoryType();
    }

    /// `janet_gc_reachable`: the mark bit, which the sweep reads and which a
    /// freshly allocated block must not have set — an allocation that arrived
    /// pre-marked would survive one collection it had no right to.
    pub fn reachable(block: ?*anyopaque) bool {
        return (headerOf(block).flags & constants.JANET_MEM_REACHABLE) != 0;
    }

    /// Whether `block` is on the list headed by `list`. Only ever called for a
    /// block known to be alive, so nothing freed is dereferenced.
    pub fn onList(list: ?*anyopaque, block: ?*anyopaque) bool {
        var current = list;
        while (current != null) {
            if (current == block) return true;
            current = @ptrCast(headerOf(current).data.next);
        }
        return false;
    }
};
