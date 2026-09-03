//! Every runtime symbol a separately compiled module reaches by name.
//!
//! **This file exists so `raise.zig` can be compiled into a module without
//! `cabi.zig`.** A module's `raise` has to record a signal, build a message,
//! take the C-raise flag and abort; those are calls into the runtime's own
//! `.so`, and the only way a separate compilation makes one is by symbol.
//! `raise.zig` reached them through `cabi` because `cabi` is where every
//! `extern fn` lives — which meant an author's module took **163 libc and
//! runtime declarations to obtain six**, and with them `FILE`, `host.Handle`
//! and the two `pthread` types. Six declarations of its own is the whole cost
//! of not doing that.
//!
//! Every one is under `if (comptime in_module)` in `raise.zig`. Inside the
//! runtime the same six are ordinary Zig calls to `signal.zig` and
//! `fatal.zig`, so nothing here is reached from a `root` build at all; this is
//! the module side of a fork `raise.zig` already had.
//!
//! `cabi.zig` declares the same six for the runtime's own compilation and
//! `cabi_check.zig` compares each against its definition, so the two spellings
//! cannot drift without the build saying so.

const repr = @import("repr");
const abi = @import("abi");
const method_type = @import("../runtime/method_type.zig");

const Value = repr.Value;

/// `janet_cstring` — interns a NUL-terminated message as a Janet string.
/// `raise.panic` builds its payload with this, and the sentinel is what the
/// callee walks.
pub extern fn janet_cstring(str: [*:0]const u8) [*:0]const u8;

/// Wraps that string as a `Value`, which is what `raise.panicv` carries.
pub extern fn janet_wrap_string(x: [*:0]const u8) repr.Value;

/// The out-of-band C-raise flag: `raise.raiseRecord` sets it and
/// `raise.tookCRaise` takes it. A module cannot see the runtime's
/// `signal.zig`, so it asks across the boundary.
pub extern fn janet_zig_c_raise_record() void;
pub extern fn janet_zig_c_raise_take() c_int;

/// `raise.total`'s abort, for a raise that cannot happen and would leave the
/// runtime inconsistent if it did.
pub extern fn janet_zig_fatal(message: [*:0]const u8) noreturn;

/// The signal a raise records. It takes the wire width because the published
/// entry point does; the caller here holds an enum member and converts, and
/// the clamp on the far side is then a no-op.
pub extern fn janet_zig_signal_record(sig: c_uint, message: repr.Value) void;

// ==========================================================================
// The module interface's own forty-five
// ==========================================================================
//
// `module.zig` calls these; they are declared here rather than there so that
// `cabi_check.zig` compares each against the definition `capi.zig` publishes.
// **What an unchecked declaration costs**: a `janet_getmethod` declaring
// `abi.Method` where the definition takes `method_type.CMethod` is two layouts
// agreeing only by luck, and a `janet_wrap_abstract` declaring a non-optional
// pointer against a definition that accepts null loses the null. Neither is
// something a linker can catch, and an author's `.so` is the one compilation
// where getting it wrong is not this project's crash to debug.

pub extern fn janet_fixarity(argc: i32, fix: i32) void;
pub extern fn janet_arity(argc: i32, min: i32, max: i32) void;
pub extern fn janet_getnumber(argv: [*]const Value, n: i32) f64;
pub extern fn janet_getinteger(argv: [*]const Value, n: i32) i32;
pub extern fn janet_getsize(argv: [*]const Value, n: i32) usize;
pub extern fn janet_getuinteger(argv: [*]const Value, n: i32) u32;
pub extern fn janet_getboolean(argv: [*]const Value, n: i32) bool;
pub extern fn janet_getabstract(argv: [*]const Value, n: i32, at: *const abi.AbstractType) ?*anyopaque;

// The three views, and the range. **A slice cannot cross**, so each carries
// the `extern` struct `abi.zig` declares and `module.zig` rebuilds the slice
// where there is one. `janet_getrange` takes the argument count as well,
// because it reads two slots and an absent second slot is what makes the end
// default -- `args.getRangeAbi` has the argument.
pub extern fn janet_getbytes(argv: [*]const Value, n: i32) abi.ByteView;
pub extern fn janet_getindexed(argv: [*]const Value, n: i32) abi.IndexedView;
pub extern fn janet_getdictionary(argv: [*]const Value, n: i32) abi.DictView;
pub extern fn janet_getrange(argv: [*]const Value, argc: i32, n: i32, length: i32) abi.Range;

// The same three views over a `Value` rather than an argument slot, which is
// what reads an element *out* of a view. **The out-parameter is the optional**:
// the definitions answer `?T` and so does `module.zig`, and a `callconv(.c)`
// return can carry neither an optional nor a slice. None can raise.
pub extern fn janet_bytes_view(x: Value, out: *abi.ByteView) bool;
pub extern fn janet_indexed_view(x: Value, out: *abi.IndexedView) bool;
pub extern fn janet_dictionary_view(x: Value, out: *abi.DictView) bool;
pub extern fn janet_wrap_number(x: f64) Value;
pub extern fn janet_wrap_nil() Value;
pub extern fn janet_wrap_abstract(p: ?*anyopaque) Value;
pub extern fn janet_abstract(at: *const abi.AbstractType, size: usize) ?*anyopaque;
pub extern fn janet_calloc(n: usize, size: usize) ?*anyopaque;
pub extern fn janet_free(p: ?*anyopaque) void;
pub extern fn janet_cfuns_ext(env: ?*abi.Env, prefix: ?[*:0]const u8, table: [*]const abi.Reg) void;
pub extern fn janet_def(env: *abi.Env, name: [*:0]const u8, val: Value, doc: ?[*:0]const u8) void;
pub extern fn janet_checkint(x: Value) c_int;
pub extern fn janet_checktype(x: Value, t: c_uint) c_int;
pub extern fn janet_unwrap_integer(x: Value) i32;
pub extern fn janet_unwrap_number(x: Value) f64;
pub extern fn janet_unwrap_keyword(x: Value) [*:0]const u8;
pub extern fn janet_getmethod(method: [*:0]const u8, methods: [*]const method_type.CMethod, out: *Value) c_int;
pub extern fn janet_nextmethod(methods: [*]const method_type.CMethod, key: Value) Value;

/// Appends to the buffer a `*abi.Render` stands for, which is what
/// `module.push` and `module.format` do and the only thing an author may do
/// with a render. The definition is `capi.janet_buffer_push_bytes` over
/// `buffers.pushBytes`; the pointer and the length are the slice that takes,
/// because a `callconv(.c)` signature cannot carry one.
pub extern fn janet_buffer_push_bytes(render: *abi.Render, bytes: [*]const u8, len: usize) void;

/// Keeps a value reachable for the collection in progress, which is the whole
/// of what an abstract type's `gcmark` callback does with a payload that holds
/// one. `module.mark` calls it; the definition is `gc/mark.zig`'s `mark`, which
/// a module cannot import because it reads the thread-local VM.
pub extern fn janet_mark(x: Value) void;

/// Records an abstract type under its name, so the unmarshaller can find it
/// again. `module.registerAbstract` calls it; the definition is
/// `registry.registerAbstractType`, and it raises when the name is already
/// taken by a *different* type, because the name is what a marshalled abstract
/// carries and two answers to it would make the stream ambiguous.
pub extern fn janet_register_abstract_type(at: *const abi.AbstractType) void;

// ==========================================================================
// The two marshal capabilities
// ==========================================================================
//
// One declaration per `marsh.zig` entry point, and `module.zig` names them
// `push*` and `pull*`. **The capability is the state struct**: an
// `*abi.Marshal` is a pointer to `marsh.MarshalState` and an `*abi.Unmarshal`
// to `marsh.UnmarshalState`, and `marsh.zig` casts back at each entry point --
// which is why the definitions `capi.zig` publishes take the same two opaque
// types these declarations do, and `cabi_check.zig` needs no substitution for
// either. The runtime's own abstract types call `marsh.*` directly and reach
// none of these.
//
// Four cannot fail and carry no report: the two flag reads,
// `janet_marshal_abstract` and `janet_unmarshal_remaining`.

pub extern fn janet_marshal_size(m: *abi.Marshal, n: usize) void;
pub extern fn janet_marshal_int(m: *abi.Marshal, x: i32) void;
pub extern fn janet_marshal_int64(m: *abi.Marshal, x: i64) void;
pub extern fn janet_marshal_byte(m: *abi.Marshal, b: u8) void;
pub extern fn janet_marshal_bytes(m: *abi.Marshal, bytes: [*]const u8, len: usize) void;
pub extern fn janet_marshal_janet(m: *abi.Marshal, x: Value) void;
pub extern fn janet_marshal_abstract(m: *abi.Marshal, p: ?*anyopaque) void;
pub extern fn janet_marshal_ptr(m: *abi.Marshal, p: ?*const anyopaque) void;
pub extern fn janet_marshal_flags(m: *abi.Marshal) c_int;

pub extern fn janet_unmarshal_size(u: *abi.Unmarshal) usize;
pub extern fn janet_unmarshal_int(u: *abi.Unmarshal) i32;
pub extern fn janet_unmarshal_int64(u: *abi.Unmarshal) i64;
pub extern fn janet_unmarshal_byte(u: *abi.Unmarshal) u8;
pub extern fn janet_unmarshal_bytes(u: *abi.Unmarshal, dest: [*]u8, len: usize) void;
pub extern fn janet_unmarshal_janet(u: *abi.Unmarshal) Value;
pub extern fn janet_unmarshal_abstract(u: *abi.Unmarshal, size: usize) ?*anyopaque;
pub extern fn janet_unmarshal_abstract_reuse(u: *abi.Unmarshal, p: ?*anyopaque) void;
pub extern fn janet_unmarshal_ptr(u: *abi.Unmarshal) ?*anyopaque;
pub extern fn janet_unmarshal_ensure(u: *abi.Unmarshal, size: usize) void;
pub extern fn janet_unmarshal_remaining(u: *abi.Unmarshal) usize;
pub extern fn janet_unmarshal_flags(u: *abi.Unmarshal) c_int;

// ==========================================================================
// Construction, and mutation through the `Value`
// ==========================================================================
//
// **Every one of these answers a `Value` or takes one, and none carries a
// pointer to an aggregate.** That is `DESIGN.md` section 15's rule applied in
// the construction direction. Upstream's constructors answer the *unwrapped*
// heap type -- an interned string, an array's pointer -- and wrapping it is a
// second call; answering the `Value` directly is one crossing instead of two
// and puts no heap pointer on the author's side at any point.
//
// **The naming rule, once: a crossing whose namesake in the retired header
// takes or answers an aggregate *pointer* does not share its name.** It is
// spelled `new_` when it constructs and `_value` when it mutates, and the
// difference being marked is what crosses rather than how wide it is -- so
// `janet_wrap_boolean` keeps its name and takes a `bool` where the header
// declared an `int`, exactly as `janet_getboolean` did at Part 7. Nothing
// links against these by C signature -- `DESIGN.md` section 11 retired the
// header and installs none -- so the Zig type says the true thing.
//
// `tools/check/exports.txt` records only that the *name* was `JANET_API`,
// which is what its own header says it records.
//
// The bytes, the items and the pairs cross as a pointer and a length for the
// reason every other slice here does, and `module.zig` is where the slice is
// taken apart.

pub extern fn janet_wrap_boolean(b: bool) Value;
// The other direction, and the only way to read a boolean out of a `Value`:
// `janet_getboolean` reads an argument slot, and a value that arrived any
// other way -- a comparator's answer, an element of a view -- has no slot.
// Janet's truthiness rather than the boolean itself, because that is what
// decides an `if` and therefore what a callee's answer means.
pub extern fn janet_truthy(x: Value) bool;
pub extern fn janet_wrap_pointer(p: ?*anyopaque) Value;
pub extern fn janet_unwrap_pointer(x: Value) ?*anyopaque;

pub extern fn janet_new_string(bytes: [*]const u8, len: usize) Value;
pub extern fn janet_new_symbol(bytes: [*]const u8, len: usize) Value;
pub extern fn janet_new_keyword(bytes: [*]const u8, len: usize) Value;
pub extern fn janet_new_tuple(items: [*]const Value, len: usize) Value;
pub extern fn janet_new_array(items: [*]const Value, len: usize) Value;
pub extern fn janet_new_buffer(bytes: [*]const u8, len: usize) Value;
pub extern fn janet_new_struct(kvs: [*]const abi.KV, len: usize) Value;
pub extern fn janet_new_table(kvs: [*]const abi.KV, len: usize) Value;

// `get`, `put` and `length` are Janet's own, over any value: the runtime
// decides what each type means by them, so a module does not carry a switch
// per collection. `janet_get` cannot fail on a type -- Janet's `get` answers
// nil for anything with no indexed access -- but it can raise from an abstract
// type's `get` callback, so it flattens a report like the rest.
pub extern fn janet_get(ds: Value, key: Value) Value;
pub extern fn janet_put(ds: Value, key: Value, val: Value) void;
pub extern fn janet_length(x: Value) i32;

// The two appends, which `get` and `put` have no spelling for: `put` writes at
// an index and these extend. Their names carry a `_value` suffix because the
// C names without it belong to functions taking the aggregate's pointer, and
// these take its `Value`.
pub extern fn janet_array_push_value(v: Value, x: Value) void;
pub extern fn janet_buffer_push_value(v: Value, bytes: [*]const u8, len: usize) void;

// ==========================================================================
// Calling back into Janet
// ==========================================================================
//
// **Two shapes, because the runtime has two.** `vm/entry.zig`'s `call` runs a
// callee on the current fiber and raises on anything but a return; its `pcall`
// runs one on a fresh fiber and *reports* the signal, the value and the fiber.
// The first is what a module reaches for and the second is for a module that
// has to look at a yield or an error rather than propagate it.
//
// `janet_call_value` flattens a raise into a report like every other raising
// crossing here, so a yield or a debug signal inside it arrives on the
// author's side as `error.JanetSignal` carrying the message `call` coerced it
// into. `janet_pcall_value` reports rather than raises by its own nature, so it
// carries no report at all: the signal *is* its answer.
//
// **`janet_pcall_value`'s two out-parameters are the shape Part 7b chose**, and for
// the same reason. A `callconv(.c)` return cannot carry a struct holding a
// `Value` and an enum without an `extern` layout, and `DESIGN.md` section 15's
// invariant says this boundary adds none; the enum returns directly as its
// `c_uint`, the two values come back through pointers, and `module.zig`
// assembles the struct an author reads.
//
// **The naming rule applies to three of these five**, and it is the same rule
// stated above: a crossing whose namesake in the retired header takes or
// answers an aggregate pointer does not share its name. The three that call
// and that ask a fiber its status each took a function's or a fiber's pointer
// there; here a function and a fiber are `Value`s like everything else, so
// each carries the `_value` suffix that already marks the two appends. The
// rooting pair keeps its names, because a root took a value there too, and
// answering `bool` where the header declared an `int` is a width, which the
// rule says keeps a name.

pub extern fn janet_call_value(f: Value, args: [*]const Value, len: usize) Value;
pub extern fn janet_pcall_value(
    f: Value,
    args: [*]const Value,
    len: usize,
    out_value: *Value,
    out_fiber: *Value,
) abi.Signal;
pub extern fn janet_fiber_status_value(fiber: Value) abi.FiberStatus;

// The precise pair, which is what a module holding a value across one of the
// two calls above needs and the only rooting that crosses. `gclock` and
// `gcunlock` do not: `DESIGN.md` section 15 says why.
pub extern fn janet_gcroot(v: Value) void;
pub extern fn janet_gcunroot(v: Value) bool;

// ==========================================================================
// Scheduling work through the event loop
// ==========================================================================
//
// **The whole of the loop is one sentence: when something happens, resume a
// fiber with a value.** A module brings its own source of "something happens"
// -- its own thread, its own library's poll -- and three operations are what
// it takes to join in: suspend, knock, wake. `await` is the suspend and needs
// no symbol at all; `janet_post` is the knock and `janet_wake` is the wake.
// `janet_current_loop` and `janet_root_fiber_value` are what a cfunction has
// to hold before it suspends.
//
// **The naming rule applies twice, and differently each time.** The retired
// header's own spelling of "the loop" names a function that *runs* the loop to
// completion, where this answers a capability -- so this one takes a longer
// name, in the shape the header used for its two accessors of the running
// fiber, rather than assert a sameness that is not there. The fiber accessor
// is the other case and is the rule as Part 9 restated it: the header's
// answers an aggregate pointer and this answers a `Value`, so it carries the
// `_value` suffix. `janet_post` and `janet_wake` are names the header never
// had at all. `tools/check/exports.txt` records only that a name was
// `JANET_API`, which is exactly why a shared spelling has to be earned.
//
// **`janet_post` is the one crossing callable from a thread with no VM**, and
// the only one that does not check that its caller is running Janet. It reads
// no thread-local: `ev.evPostEvent` takes the target VM explicitly and a
// `*abi.Loop` is that pointer.
//
// `GenericMessage`, which the runtime moves the callback and the context in,
// does not appear here and never crosses. `DESIGN.md` section 15 says why.

/// The loop this cfunction is running on. Raises where the build has none.
pub extern fn janet_current_loop() *abi.Loop;

/// The fiber `await` suspends and `wake` puts back. Raises where there is
/// none, which is a program not running under the loop at all.
pub extern fn janet_root_fiber_value() Value;

/// Ask the loop thread to run `cb(wake, ctx)` at its next turn. Cannot raise
/// and does not allocate.
pub extern fn janet_post(l: *abi.Loop, cb: abi.PostCallback, ctx: *anyopaque) void;

/// Put `fiber` back on the run queue with `value`, answering whether it took.
/// Cannot raise: the callback it runs inside has no scope above it.
pub extern fn janet_wake(w: *abi.Wake, fiber: Value, value: Value) bool;
