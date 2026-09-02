//! The runtime's shared substrate: the collection hashes, the dictionary probe
//! every table and struct lookup
//! goes through, the two string comparisons, the key sort, and four host
//! services.
//!
//! Nothing here raises, so `defer` is legal and used.
//!
//! `registry.zig` has the half that does own VM state — the cfunction
//! registry, the registration entry points, the abstract-type registry, and
//! bindings.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const order = @import("value/helpers/order.zig");
const fatal = @import("fatal.zig");
const repr = @import("repr");
const vm_state = @import("vm/state.zig");
const c = @import("cabi");
const strings = @import("value/strings.zig");
const tuples = @import("value/tuples.zig");
const structs = @import("value/structs.zig");
const abi = @import("abi");
const tables = @import("value/tables.zig");

const windows = builtin.os.tag == .windows;

// ------------------------------------------------------------------- heads

// Four head accessors, forwarding to the file that owns each head. They are
// here so that a caller wanting one of the four need not import four files;
// the arithmetic and the offset are the owner's, in one place each.

pub fn structHead(st: [*]const tables.KV) *structs.StructHead {
    return structs.head(st);
}

pub fn abstractHead(abstract: ?*const anyopaque) *abi.AbstractHead {
    return abi.abstractHead(abstract);
}

pub fn stringHead(s: [*]const u8) *strings.StringHead {
    return strings.head(s);
}

pub fn tupleHead(tuple: [*]const repr.Value) *tuples.TupleHead {
    return tuples.head(tuple);
}

// ------------------------------------------------------------- name tables
//
// Four tables of static strings, read from eleven files: every type name a
// message prints, every fiber status a trace names, the base64 alphabet, and
// the two hex digits an escape is built from.

pub const base64: [65]u8 = ("0123456789" ++
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ" ++
    "abcdefghijklmnopqrstuvwxyz" ++
    "_=" ++ "\x00").*;

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

/// Indexed by `JanetSignal`. Fourteen rather than sixteen: the eight user
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

/// Indexed by `JanetFiberStatus`. The first twelve line up with the signal
/// names above and the last four do not, which is why there are two tables.
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

// ------------------------------------------------------ the dictionary probe
//
// The probe itself and the collection hashes are `value.zig`'s, the bucket the
// two dictionary leaves share. What is left here is the one function with no
// dictionary in it, and a private `isNil` for `sortedKeys` -- a file may
// duplicate a private predicate.

inline fn isNil(val: repr.Value) bool {
    return repr.checkType(val, repr.Tag.nil);
}

// ------------------------------------------------------ strings and searching

/// Compare a Janet string with a C string, without interning the second.
///
/// The Janet string knows its length and may contain a NUL; the C string ends
/// at one. So the loop stops at whichever comes first and the answer is decided
/// after it: equal only if both ended together.
///
/// `index` outlives the loop, which is why it is declared above it here as it
/// is in the C original -- the value it holds when the loop breaks is what
/// decides the result.
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

/// Binary search a sorted array of structs whose first member is a `char *`.
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

/// Fill `index_buffer` with the occupied bucket indices of a dictionary, in
/// key order, and answer how many there were.
///
/// The caller owns a buffer of at least `cap` entries. The sort is insertion
/// sort over the indices rather than over the buckets, so nothing in the
/// dictionary moves; Janet's own comment calls it "simple insertion sort here
/// for now" and both the algorithm and the comparison order are kept, because
/// `janet_compare` decides key order for every printed table.
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

// --------------------------------------------------------------- host services

/// `c.strerror` that is thread-safe where the host offers it.
///
/// Three cases, and they are the C original's. Microsoft's `c.strerror` is
/// already thread-safe, so Windows calls it directly. glibc's `c.strerror_r`
/// is the GNU one -- it *returns* the message and may not touch the buffer at
/// all, which is why its result is returned rather than the buffer. Everyone
/// else has the XSI one, which fills the buffer and returns an `int`.
///
/// The buffer is `vm.strerror_buf`, so the answer is valid until the next
/// call on the same thread.
pub fn strerrorSafe(e: c_int) [*:0]const u8 {
    if (windows) return @ptrCast(c.strerror(e));
    const buf: [*]u8 = @ptrCast(&vm_state.current().strerror_buf);
    const size = @sizeOf(@TypeOf(vm_state.current().strerror_buf));
    if (builtin.target.isGnuLibC()) return @ptrCast(gnuStrerrorR(e, buf, size));
    _ = c.strerror_r(e, buf, size);
    return @ptrCast(buf);
}

/// glibc's `c.strerror_r` is a different function with the same name: it returns
/// `char *`, and may answer a static string without touching the buffer at all.
/// One symbol cannot be declared twice, so the second signature is a cast of
/// the first rather than a second `extern`, and the cast is reached only under
/// the comptime test above.
const GnuStrerrorR = *const fn (c_int, [*]u8, usize) callconv(.c) [*]u8;
const gnuStrerrorR: GnuStrerrorR = @ptrCast(&c.strerror_r);

/// Fill `out` with `n` cryptographically random bytes, answering 0 on success.
///
/// Three implementations, exactly as Janet picks them. Windows draws from
/// `c.rand_s` an `unsigned int` at a time; BSD and macOS have `c.arc4random_buf`;
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

fn closeRetrying(fd: c_int) void {
    _ = c.retryIntr(std.c.close, .{fd});
}

/// `JANET_BSD || MAC_OS_X_VERSION_10_7` as the C original spells it. The second
/// comes from `<AvailabilityMacros.h>` and is defined on every macOS the
/// project supports, so the test is "a BSD, Apple included".
const has_arc4random = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

// ------------------------------------------------------ dynamic module names

/// Turn a bare module name into a path the dynamic loader will treat as
/// relative to the working directory.
///
/// `dlopen("foo.so")` searches the loader's path; `dlopen("./foo.so")` does
/// not. A name that already starts with `.` or contains a `/` is left alone
/// and returned as-is, which is why the caller must not free the result
/// unconditionally -- it may be the argument. Janet's signature drops the
/// `const` to say so, and that is kept rather than improved.
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

// Loading a library is `dynlib.zig`'s. `getProcessedName` above is the part of
// module loading that is the same on every platform; the rest is per-platform.

// ------------------------------------------------------- allocator wrappers

// The four hooks Janet's heap is built on. Every allocation the runtime makes
// arrives at one of them, which is what makes replacing them a supported thing
// to do; the typed layer below sits on top rather than beside.

pub fn malloc(size: usize) ?*anyopaque {
    return std.c.malloc(size);
}

pub fn free(ptr: ?*anyopaque) void {
    std.c.free(ptr);
}

pub fn calloc(nmemb: usize, size: usize) ?*anyopaque {
    return std.c.calloc(nmemb, size);
}

pub fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    return std.c.realloc(ptr, size);
}

// ------------------------------------------------------- the typed interface
//
// Out of memory is fatal in this runtime and always was: there is no caller
// anywhere that can carry the failure, and `janet_out_of_memory` aborts. So
// the check belongs at the hook rather than as `orelse fatal.outOfMemory()`
// repeated at every allocating line, which is what it had been.
//
// `rawAlloc` and `rawRealloc` are the byte-counted forms the collector and the
// four flexible-array heads want; `alloc`, `allocSlice` and `resizeSlice` are
// what everything else wants, and each answers a pointer or a slice of the
// type asked for rather than an `?*anyopaque` for the caller to cast.

/// `size` bytes, suitably aligned for any Janet type, or a fatal abort.
pub fn rawAlloc(size: usize) *anyopaque {
    return malloc(size) orelse fatal.outOfMemory();
}

/// Grow or move `ptr` to `size` bytes, or a fatal abort. A null `ptr` is an
/// allocation, which is `realloc(3)`'s own rule and the one several growth
/// paths in the tree rely on.
pub fn rawRealloc(ptr: ?*anyopaque, size: usize) *anyopaque {
    return realloc(ptr, size) orelse fatal.outOfMemory();
}

/// One `T`, uninitialised.
pub inline fn alloc(comptime T: type) *T {
    return @ptrCast(@alignCast(rawAlloc(@sizeOf(T))));
}

/// `n` contiguous `T`, uninitialised.
///
/// A many-pointer rather than a slice because the fields these fill are a
/// pointer and a separate count that the owner grows -- `vm_state.Vector(T)`'s
/// header says why growth belongs to the owner. `n` reaches `malloc` exactly
/// as computed, zero included, so this is `malloc(n * @sizeOf(T))` with the
/// failure already handled and the cast already made.
pub inline fn allocMany(comptime T: type, n: usize) [*]T {
    return @ptrCast(@alignCast(rawAlloc(n *% @sizeOf(T))));
}

/// Grow or move `n` contiguous `T`. A null `old` allocates.
pub inline fn resizeMany(comptime T: type, old: ?[*]T, n: usize) [*]T {
    return @ptrCast(@alignCast(rawRealloc(@ptrCast(old), n *% @sizeOf(T))));
}

/// `n` contiguous zeroed `T`, which is `calloc`'s guarantee and not a
/// `@memset` after the fact.
pub inline fn allocManyZeroed(comptime T: type, n: usize) [*]T {
    return @ptrCast(@alignCast(calloc(n, @sizeOf(T)) orelse fatal.outOfMemory()));
}

// -------------------------------------------------- Janet's heap as an Allocator
//
// `std.ArrayListUnmanaged` and the rest of `std` want a `std.mem.Allocator`,
// and Janet's hooks are exactly the three functions one needs. The vtable has
// no state, so `ptr` is `undefined` and must never be read -- which the
// standard interface already documents as legal for a stateless allocator.
//
// The one thing `malloc` cannot promise is an alignment stricter than
// `max_align_t`. Nothing in the tree asks for one; a request that did would be
// a silent misalignment, so it aborts instead.

const max_malloc_align: std.mem.Alignment = .fromByteUnits(@alignOf(std.c.max_align_t));

fn allocatorAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (@intFromEnum(alignment) > @intFromEnum(max_malloc_align))
        fatal.fatal("allocation alignment exceeds what janet_malloc guarantees");
    return @ptrCast(malloc(len));
}

fn allocatorResize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    // `realloc` may move, so an in-place resize can only be promised where the
    // block is not growing.
    return new_len <= memory.len;
}

fn allocatorRemap(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    return @ptrCast(realloc(@ptrCast(memory.ptr), new_len));
}

fn allocatorFree(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    free(@ptrCast(memory.ptr));
}

const allocator_vtable: std.mem.Allocator.VTable = .{
    .alloc = allocatorAlloc,
    .resize = allocatorResize,
    .remap = allocatorRemap,
    .free = allocatorFree,
};

/// Janet's heap, as the standard interface. Failure is reported the standard
/// way -- `error.OutOfMemory` -- rather than aborting, because the containers
/// that take an `Allocator` are written to that contract; a caller that cannot
/// carry it writes `catch fatal.outOfMemory()`.
pub const heap: std.mem.Allocator = .{ .ptr = undefined, .vtable = &allocator_vtable };

/// C's conversion of a signed count to `size_t`: sign-extend to the pointer
/// width, then reinterpret.
///
/// **For a negative count it yields a very large size, and that is the
/// point.** It is what the C original does, and `@intCast` would trap on
/// exactly the values it exists to carry, so the conversion is written out.
///
/// **Every call site is a place a count that may be negative still becomes a
/// size.** Where the count comes from a program the argument is rejected
/// before it reaches here; the sites that remain are index arithmetic over
/// quantities the runtime derives. One copy, so the population is countable.
pub inline fn asSize(n: i32) usize {
    return @bitCast(@as(isize, n));
}

/// The element view a fixed-layout accessor returns, carrying the receiver's
/// constness into the result.
///
/// **Zig's constness is shallow, so an accessor has to do this by hand.** A
/// `*const JanetFuncDef` names a pointer that may not be written *through*,
/// and the `[*]u32` inside it is a separate pointer with its own constness --
/// so `fn instructions(self: *const JanetFuncDef) []u32` compiles, and lets a
/// caller holding a read-only funcdef rewrite its bytecode. Making every
/// result `[]const T` is not the answer either: there are legitimate writers,
/// and they hold a mutable receiver already.
///
/// Taking `self: anytype` and mapping the pointer's constness onto the result
/// leaves both call sites alone and makes only the wrong one a compile error.
/// `reserved` and `spare` deliberately do *not* use this: their whole purpose
/// is to hand a writer the storage outside the live range, so they keep a
/// mutable receiver and a mutable result.
pub fn View(comptime Self: type, comptime T: type) type {
    const info = @typeInfo(Self);
    if (info != .pointer) @compileError("a fixed-layout accessor takes a pointer receiver");
    return if (info.pointer.is_const) []const T else []T;
}
