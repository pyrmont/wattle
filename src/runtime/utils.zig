//! The runtime's shared substrate: the four head accessors, the name tables a
//! message prints from, the two string searches, the key sort, the host
//! services and the allocator layer.
//!
//! Nothing here raises, so `defer` is legal and used.
//!
//! `registry.zig` has the half that does own VM state: the cfunction registry,
//! the registration entry points, the abstract-type registry, and bindings.
//! The dictionary probe and the collection hashes are `value.zig`'s.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");
const builtin = @import("builtin");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const c = @import("cabi");
const config = @import("config");
const fatal = @import("fatal.zig");
const order = @import("value/helpers/order.zig");
const repr = @import("repr");
const strings = @import("value/strings.zig");
const structs = @import("value/structs.zig");
const tables = @import("value/tables.zig");
const tuples = @import("value/tuples.zig");
const vm_state = @import("vm/state.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The vtable behind `heap`.
const allocator_vtable: std.mem.Allocator.VTable = .{
    .alloc = allocatorAlloc,
    .resize = allocatorResize,
    .remap = allocatorRemap,
    .free = allocatorFree,
};

/// The alphabet a base64 encoding draws from, NUL-terminated so a caller may
/// pass it to a C routine.
pub const base64: [65]u8 = ("0123456789" ++
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ" ++
    "abcdefghijklmnopqrstuvwxyz" ++
    "_=" ++ "\x00").*;

/// glibc's `strerror_r` under its own signature.
///
/// glibc's is a different function with the same name: it returns `char *` and
/// may return a static string without touching the buffer at all. One symbol
/// cannot be declared twice, so this is a cast of the first rather than a
/// second `extern`, and it is reached only under `strerrorSafe`'s comptime
/// test.
const gnuStrerrorR: GnuStrerrorR = @ptrCast(&c.strerror_r);

/// Whether this target is a BSD, Apple included.
///
/// `arc4random` arrived on macOS at 10.7, which every version this project
/// supports is past, so the test is by family rather than by version.
const has_arc4random = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

/// Janet's heap, as the standard interface.
///
/// Failure is reported the standard way, `error.OutOfMemory`, rather than
/// aborting, because the containers that take an `Allocator` are written to
/// that contract. A caller that cannot report it writes
/// `catch fatal.outOfMemory()`.
///
/// The vtable has no state, so `ptr` is `undefined` and must never be read,
/// which the standard interface documents as legal for a stateless allocator.
pub const heap: std.mem.Allocator = .{ .ptr = undefined, .vtable = &allocator_vtable };

/// The strictest alignment `malloc` guarantees. A request above it aborts,
/// because nothing in the tree asks for one and a silent misalignment is the
/// alternative.
const max_malloc_align: std.mem.Alignment = .fromByteUnits(@alignOf(std.c.max_align_t));

/// Indexed by `abi.Signal`. Fourteen rather than sixteen: the eight user
/// signals are the middle of the range and `interrupt` and `await` close it.
pub const signalNames: [14][*:0]const u8 = .{
    "ok",
    "error",
    "debug",
    "yield",
    "user0",
    "user1",
    "user2",
    "user3",
    "user4",
    "user5",
    "user6",
    "user7",
    "interrupt",
    "await",
};

/// Indexed by `fibers.FiberStatus`. The first twelve line up with the signal
/// names above and the last four do not, so there are two tables.
pub const statusNames: [16][*:0]const u8 = .{
    "dead",
    "error",
    "debug",
    "pending",
    "user0",
    "user1",
    "user2",
    "user3",
    "user4",
    "user5",
    "user6",
    "user7",
    "interrupted",
    "suspended",
    "new",
    "alive",
};

/// Indexed by `repr.Tag`, so the order is Janet's and not alphabetical.
/// A caller writes `typeNames[@intFromEnum(tag)]`: the tag is an `enum(u4)`
/// and an enum is deliberately not an index.
pub const typeNames: [16][*:0]const u8 = .{
    "number",
    "nil",
    "boolean",
    "fiber",
    "string",
    "symbol",
    "keyword",
    "array",
    "tuple",
    "table",
    "struct",
    "buffer",
    "function",
    "cfunction",
    "abstract",
    "pointer",
};

/// Whether this target is Windows.
const windows = builtin.os.tag == .windows;

// ==========================================================================
// Aliased types
// ==========================================================================

/// The signature glibc's `strerror_r` actually has.
const GnuStrerrorR = *const fn (c_int, [*]u8, usize) callconv(.c) [*]u8;

// ==========================================================================
// Types
// ==========================================================================

/// The element view a fixed-layout accessor returns, taking the receiver's
/// constness into the result.
///
/// `Self` is the receiver's pointer type and `T` the element. A receiver that
/// is not a pointer is a compile error.
///
/// Zig's constness is shallow, so an accessor has to do this by hand. A
/// `*const FuncDef` names a pointer that may not be written through, and the
/// `[*]u32` inside it is a separate pointer with its own constness, so
/// `fn instructions(self: *const FuncDef) []u32` compiles and lets a caller
/// with a read-only funcdef rewrite its bytecode. Making every result
/// `[]const T` is no better, because there are legitimate writers and each of
/// them already has a mutable receiver.
///
/// `reserved` and `spare` deliberately do not use this: their whole purpose is
/// to give a writer the storage outside the live range, so they take a mutable
/// receiver and a mutable result.
pub fn View(comptime Self: type, comptime T: type) type {
    const info = @typeInfo(Self);
    if (info != .pointer) @compileError("a fixed-layout accessor takes a pointer receiver");
    return if (info.pointer.is_const) []const T else []T;
}

// ==========================================================================
// Public functions
// ==========================================================================

/// The four head accessors, each forwarding to the file that owns that head.
///
/// They are here so that a caller wanting one of the four need not import four
/// files. The arithmetic and the offset are the owner's, in one place each.
pub fn abstractHead(abstract: ?*const anyopaque) *abi.AbstractHead {
    return abi.abstractHead(abstract);
}

pub fn stringHead(s: [*]const u8) *strings.StringHead {
    return strings.head(s);
}

pub fn structHead(st: [*]const tables.KV) *structs.StructHead {
    return structs.head(st);
}

pub fn tupleHead(tuple: [*]const repr.Value) *tuples.TupleHead {
    return tuples.head(tuple);
}

/// The typed allocation layer.
///
/// Out of memory is fatal in this runtime: no caller anywhere can act on the
/// failure, and `fatal.outOfMemory` aborts, so the check belongs at the hook
/// rather than as an `orelse` repeated at every allocating line. `rawAlloc`
/// and `rawRealloc` are the byte-counted forms the collector and the four
/// flexible-array heads need; the rest each return a pointer of the type asked
/// for rather than an `?*anyopaque` for the caller to cast. `n` reaches
/// `malloc` exactly as computed, zero included.
pub inline fn alloc(comptime T: type) *T {
    return @ptrCast(@alignCast(rawAlloc(@sizeOf(T))));
}

pub inline fn allocMany(comptime T: type, n: usize) [*]T {
    return @ptrCast(@alignCast(rawAlloc(n *% @sizeOf(T))));
}

pub inline fn allocManyZeroed(comptime T: type, n: usize) [*]T {
    return @ptrCast(@alignCast(calloc(n, @sizeOf(T)) orelse fatal.outOfMemory()));
}

/// C's conversion of a signed count to `size_t`: sign-extend to the pointer
/// width, then reinterpret.
///
/// `n` is the count. For a negative count this yields a very large size, which
/// is what the callers below need: `@intCast` would trap on exactly the values
/// this exists to convert, so the conversion is written out.
///
/// Every call site is a place where a count that may be negative still becomes
/// a size. Where the count comes from a program the argument is rejected before
/// it reaches here, and the sites that remain are index arithmetic over
/// quantities the runtime derives. One copy, so the population is countable.
pub inline fn asSize(n: i32) usize {
    return @bitCast(@as(isize, n));
}

/// The four hooks Janet's heap is built on.
///
/// Every allocation the runtime makes arrives at one of them, which is what
/// makes replacing them a supported thing to do. The typed layer sits on top
/// rather than beside.
pub fn calloc(nmemb: usize, size: usize) ?*anyopaque {
    return std.c.calloc(nmemb, size);
}

pub fn free(ptr: ?*anyopaque) void {
    std.c.free(ptr);
}

pub fn malloc(size: usize) ?*anyopaque {
    return std.c.malloc(size);
}

pub fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    return std.c.realloc(ptr, size);
}

/// Fills `out` with `n` cryptographically random bytes, and returns 0 on
/// success.
///
/// `out` is the buffer and `n` its length. The result is -1 where the build has
/// no source of randomness and on any failure of the host's.
///
/// Three implementations, exactly as Janet picks them. Windows draws from
/// `rand_s` an `unsigned int` at a time; BSD and macOS have `arc4random_buf`;
/// everywhere else reads `/dev/urandom`, because Janet's comment records that
/// `getrandom` "doesn't seem to be uniformly supported on linux distros".
///
/// Only one of the three is compiled for any target: the Linux arm is
/// type-checked by the Linux cross-compile in the acceptance matrix and by
/// nothing on this host.
pub fn cryptorand(out: [*]u8, n: usize) c_int {
    if (!config.cryptorand) return -1;

    if (windows) {
        var i: usize = 0;
        while (i < n) : (i += @sizeOf(c_uint)) {
            var v: c_uint = undefined;
            if (c.rand_s(&v) != 0) return -1;
            var j: usize = 0;
            while (j < @sizeOf(c_uint) and i + j < n) : (j += 1) {
                out[i + j] = @truncate(v & 0xff);
                v = v >> 8;
            }
        }
        return 0;
    }

    if (has_arc4random) {
        c.arc4random_buf(out, n);
        return 0;
    }

    const randfd = c.retryIntr(std.c.open, .{ "/dev/urandom", @as(std.c.O, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }) });
    if (randfd < 0) return -1;

    var cursor = out;
    var left = n;
    while (left > 0) {
        const nread = c.retryIntr(std.c.read, .{ randfd, cursor, left });
        if (nread <= 0) {
            closeRetrying(randfd);
            return -1;
        }
        cursor += @intCast(nread);
        left -= @intCast(nread);
    }
    closeRetrying(randfd);
    return 0;
}

/// Compares a Janet string with a C string, without interning the second.
///
/// `str` and `other` are the two. The Janet string has its length in its head
/// and may
/// contain a NUL where the C string ends at one, so the loop stops at whichever
/// comes first and the result is decided after it: equal only if both ended
/// together.
///
/// `index` is declared above the loop because it outlives it: the value it
/// has when the loop breaks is what decides the result.
pub fn cstrcmp(str: [*:0]const u8, other: [*:0]const u8) c_int {
    const len = stringHead(str).length;
    var index: i32 = 0;
    while (index < len) : (index += 1) {
        const at: usize = @intCast(index);
        const mine = str[at];
        const theirs = other[at];
        if (mine < theirs) return -1;
        if (mine > theirs) return 1;
        if (theirs == 0) break;
    }
    return if (other[@intCast(index)] == 0) 0 else -1;
}

/// Turns a bare module name into a path the dynamic loader treats as relative
/// to the working directory.
///
/// `name` is the module name. `dlopen("foo.so")` searches the loader's path
/// where `dlopen("./foo.so")` does not. A name that already starts with `.` or
/// contains a `/` is returned as it stands, so a caller must not free the
/// result unconditionally: it may be the argument. Janet's signature drops
/// the `const` to say so, and that is kept rather than improved.
///
/// Loading a library is `dynlib.zig`'s. This is the part of module loading that
/// is the same on every platform.
pub fn getProcessedName(name: [*]const u8) [*]u8 {
    if (name[0] == '.') return @constCast(name);
    var len: usize = 0;
    while (name[len] != 0) : (len += 1) {
        if (name[len] == '/') return @constCast(name);
    }
    const ret: [*]u8 = @ptrCast(std.c.malloc(len + 3) orelse fatal.outOfMemory());
    ret[0] = '.';
    ret[1] = '/';
    @memcpy(ret[2 .. len + 3], name[0 .. len + 1]);
    return ret;
}

/// Allocates `size` bytes, suitably aligned for any Janet type, or aborts.
pub fn rawAlloc(size: usize) *anyopaque {
    return malloc(size) orelse fatal.outOfMemory();
}

/// Grows or moves `ptr` to `size` bytes, or aborts.
///
/// A null `ptr` is an allocation, which is `realloc(3)`'s own rule and the one
/// several growth paths in the tree rely on.
pub fn rawRealloc(ptr: ?*anyopaque, size: usize) *anyopaque {
    return realloc(ptr, size) orelse fatal.outOfMemory();
}

/// Grows or moves `n` contiguous `T`. A null `old` allocates.
pub inline fn resizeMany(comptime T: type, old: ?[*]T, n: usize) [*]T {
    return @ptrCast(@alignCast(rawRealloc(@ptrCast(old), n *% @sizeOf(T))));
}

/// Fills `index_buffer` with the occupied bucket indices of a dictionary, in
/// key order, and returns how many there were.
///
/// `dict` is the hash array, `cap` its capacity and `index_buffer` a buffer of
/// at least `cap` entries the caller owns. The sort is insertion sort over the
/// indices rather than over the buckets, so nothing in the dictionary moves.
/// Both the algorithm and the comparison order are kept as upstream has them,
/// because `order.compare` decides key order for every printed table.
pub fn sortedKeys(
    dict: [*]const tables.KV,
    cap: i32,
    index_buffer: ?[*]i32,
) i32 {
    var next_index: i32 = 0;
    for (0..@as(usize, @intCast(cap))) |i| {
        if (!isNil(dict[i].key)) {
            // `index_buffer` is the caller's `i32` array, so the bucket index
            // is narrowed here, at that boundary.
            index_buffer.?[@intCast(next_index)] = @intCast(i);
            next_index += 1;
        }
    }

    var i: i32 = 1;
    while (i < next_index) : (i += 1) {
        const index_to_insert = index_buffer.?[@intCast(i)];
        const lhs = dict[@intCast(index_to_insert)].key;
        var j: i32 = i - 1;
        while (j >= 0) : (j -= 1) {
            index_buffer.?[@intCast(j + 1)] = index_buffer.?[@intCast(j)];
            const rhs = dict[@intCast(index_buffer.?[@intCast(j)])].key;
            if (order.compare(lhs, rhs) >= 0) {
                index_buffer.?[@intCast(j + 1)] = index_to_insert;
                break;
            } else if (j == 0) {
                index_buffer.?[0] = index_to_insert;
            }
        }
    }

    return next_index;
}

/// Binary-searches a sorted array of structs whose first member is a
/// `char *`.
///
/// `tab` is the array, `tabcount` its length, `itemsize` the stride and `key`
/// the name. The result is null when the name is absent.
///
/// The item size is a parameter rather than a type because the callers' element
/// types differ; the one invariant is that the name is first. Zig could express
/// this with a generic, and the tables it searches are built by hand and
/// compared byte for byte by `test/utils.zig`, so the untyped form is what the
/// contract tests.
pub fn strbinsearch(
    tab: ?*const anyopaque,
    tabcount: usize,
    itemsize: usize,
    key: [*:0]const u8,
) ?*const anyopaque {
    const base: [*]const u8 = @ptrCast(tab.?);
    var low: usize = 0;
    var hi: usize = tabcount;
    while (low < hi) {
        const mid = low + ((hi - low) / 2);
        const item: *const [*:0]const u8 = @ptrCast(@alignCast(base + mid * itemsize));
        const comp = cstrcmp(key, item.*);
        if (comp < 0) {
            hi = mid;
        } else if (comp > 0) {
            low = mid + 1;
        } else {
            return @ptrCast(item);
        }
    }
    return null;
}

/// Returns `strerror`'s message, thread-safely where the host offers it.
///
/// `e` is the error number. Three cases, one per host. Microsoft's `strerror`
/// is already thread-safe, so Windows calls it directly. glibc's `strerror_r`
/// is the GNU one, which returns the message and may not touch the buffer at
/// all, so its result is returned rather than the buffer. Everyone else has the
/// XSI one, which fills the buffer and returns an `int`.
///
/// The buffer is the VM's `strerror_buf`, so the result is valid until the next
/// call on the same thread.
pub fn strerrorSafe(e: c_int) [*:0]const u8 {
    if (windows) return @ptrCast(c.strerror(e));
    const buf: [*]u8 = @ptrCast(&vm_state.current().strerror_buf);
    const size = @sizeOf(@TypeOf(vm_state.current().strerror_buf));
    if (builtin.target.isGnuLibC()) return @ptrCast(gnuStrerrorR(e, buf, size));
    _ = c.strerror_r(e, buf, size);
    return @ptrCast(buf);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// The four functions `allocator_vtable` names, over Janet's own hooks.
///
/// `malloc` cannot promise an alignment stricter than `max_align_t`, so a
/// request above it aborts. `resize` can promise an in-place result only where
/// the block is not growing, because `realloc` may move.
fn allocatorAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (@intFromEnum(alignment) > @intFromEnum(max_malloc_align))
        fatal.fatal("allocation alignment exceeds what janet_malloc guarantees");
    return @ptrCast(malloc(len));
}

fn allocatorFree(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    free(@ptrCast(memory.ptr));
}

fn allocatorRemap(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    return @ptrCast(realloc(@ptrCast(memory.ptr), new_len));
}

fn allocatorResize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    // `realloc` may move, so an in-place resize can only be promised where the
    // block is not growing.
    return new_len <= memory.len;
}

/// Closes `fd`, retrying an interrupted call. `cryptorand` is the one caller.
fn closeRetrying(fd: c_int) void {
    _ = c.retryIntr(std.c.close, .{fd});
}

/// Whether a value is nil. `sortedKeys` is the one caller, and a file may
/// duplicate a private predicate.
inline fn isNil(val: repr.Value) bool {
    return repr.checkType(val, repr.Tag.nil);
}
