//! The runtime's shared substrate: everything in `src/core/util.c` that is not
//! registration, resolution or the clock.
//!
//! Phase 5 took the three hash helpers and `janet_tablen`; Phase 10 Part 5
//! added the four out-of-line head accessors; Phase 10 Part 17f took the rest
//! of what `-Dutilities` owns — the collection hashes, the dictionary probe
//! every table and struct lookup goes through, the two string comparisons, the
//! key sort, and the four host services `util.c` kept beside them.
//!
//! Nothing here raises. That is what makes it the part of `util.c` that could
//! be ported without touching the raise mechanism, and it is why the file has
//! no jump-transparent marker: there is no frame here a C raise can be thrown
//! through, so `defer` is legal and used.
//!
//! `registry.zig` has the half that does own VM state — the cfunction
//! registry, the registration entry points, the abstract-type registry, and
//! bindings.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const order = @import("value/helpers/order.zig");
const kind = @import("value/helpers/kind.zig");
const wrap = @import("value/helpers/wrap.zig");
const fatal = @import("fatal.zig");
const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");

const windows = builtin.os.tag == .windows;

// ------------------------------------------------------------------- heads

// The out-of-line twins of four macros in `janet.h`, moved out of `capi.c` in
// Phase 10 Part 5. C spells each `(janet_struct_head)(st)` -- parenthesised so
// the macro does not eat the definition -- and provides it for an embedder who
// reaches Janet through the shared library rather than the header.
//
// These four are the *published* abi and nothing else. The arithmetic is
// `types.zig`'s since increment 5e; what is left here is the C signature it
// wears -- `callconv(.c)` and a `[*c]` return, which is the ABI's shape rather
// than the accessor's (rule 65). Decision 5 moves this pair of properties to
// `capi.zig`, at which point these bodies move with them and this section goes
// away entirely.
//
// The arithmetic is not delegated to `c.janet_*_head` either. Each name is
// both a macro and a prototype in `janet.h`, and which of the two translate-c
// hands back is not something this file should depend on: if it were the
// prototype, the body below would be a call to itself.

pub fn structHead(st: [*]const types.JanetKV) *types.JanetStructHead {
    return types.structHead(st);
}

pub fn abstractHead(abstract: ?*const anyopaque) *types.JanetAbstractHead {
    return types.abstractHead(abstract);
}

pub fn stringHead(s: [*]const u8) *types.JanetStringHead {
    return types.stringHead(s);
}

pub fn tupleHead(tuple: [*]const types.Janet) *types.JanetTupleHead {
    return types.tupleHead(tuple);
}

// ------------------------------------------------------------- name tables
//
// Four tables of static strings. `janet.h` exports the three name tables and
// `util.h` the base64 alphabet, and between them they are read from eleven Zig
// files and from `fiber.c` and `debug.c` -- every type name a message prints,
// every fiber status a trace names, and the two hex digits an escape is built
// from.
//
// They are data rather than code, and they move here because they were the
// last thing in `util.c` and because `-Dutilities` is where the rest of that
// file's substrate went. The C declarations are unchanged, so a reader of
// either arm sees the same symbols.

pub const base64: [65]u8 = ("0123456789" ++
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ" ++
    "abcdefghijklmnopqrstuvwxyz" ++
    "_=" ++ "\x00").*;

/// Indexed by `JanetType`, so the order is `janet.h`'s and not alphabetical.
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
// The probe itself, the collection hashes and the whole hashing section moved
// to `value.zig` -- `phase_12.md` decision 3 and the increment below it. What
// is left here is the one function that had no dictionary in it, and a private
// `isNil` for `sortedKeys`, which is batch 2's rule: a file may duplicate a
// private predicate.

inline fn isNil(val: types.Janet) bool {
    return kind.checkType(val, constants.JANET_NIL) != 0;
}

/// `memcpy` that tolerates a zero length with a null pointer.
///
/// The C original's comment says it exists to "avoid some undefined behavior
/// that was common in the code base", and the behaviour is C's rule that a
/// null pointer may not be passed to `memcpy` even for zero bytes. Zig has the
/// same rule from the other side: a zero-length slice cannot be constructed
/// from a null pointer, so the early return is load-bearing here rather than
/// merely careful.
pub fn safeMemcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) void {
    if (len == 0) return;
    const to: [*]u8 = @ptrCast(dest.?);
    const from: [*]const u8 = @ptrCast(src.?);
    @memcpy(to[0..len], from[0..len]);
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
    const len = stringHead(str).*.length;
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
/// types differ and C has no generics; the one invariant is that the name is
/// first. Zig could express this properly, and deliberately does not: the
/// signature is `janet.h`'s and every caller is still reached through it.
pub fn strbinsearch(
    tab: ?*const anyopaque,
    tabcount: usize,
    itemsize: usize,
    key: [*:0]const u8,
) callconv(.c) ?*const anyopaque {
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
/// dictionary moves; the C original's comment calls it "simple insertion sort
/// here for now" and the port keeps both the algorithm and the comparison
/// order, because `janet_compare` decides key order for every printed table.
pub fn sortedKeys(
    dict: [*]const types.JanetKV,
    cap: i32,
    index_buffer: ?[*]i32,
) callconv(.c) i32 {
    var next_index: i32 = 0;
    var i: i32 = 0;
    while (i < cap) : (i += 1) {
        if (!isNil(dict[@intCast(i)].key)) {
            index_buffer.?[@intCast(next_index)] = i;
            next_index += 1;
        }
    }

    i = 1;
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

/// `strerror` that is thread-safe where the host offers it.
///
/// Three cases, and they are the C original's. Microsoft's `strerror` is
/// already thread-safe, so Windows calls it directly. glibc's `strerror_r`
/// is the GNU one -- it *returns* the message and may not touch the buffer at
/// all, which is why its result is returned rather than the buffer. Everyone
/// else has the XSI one, which fills the buffer and returns an `int`.
///
/// The buffer is `janet_vm.strerror_buf`, so the answer is valid until the next
/// call on the same thread.
pub fn janet_strerror(e: c_int) [*:0]const u8 {
    if (windows) return @ptrCast(strerror(e));
    const buf: [*]u8 = @ptrCast(&c.vm().strerror_buf);
    const size = @sizeOf(@TypeOf(c.vm().strerror_buf));
    if (builtin.target.isGnuLibC()) return @ptrCast(gnuStrerrorR(e, buf, size));
    _ = strerror_r(e, buf, size);
    return @ptrCast(buf);
}

extern fn strerror(e: c_int) callconv(.c) [*]u8;

/// The XSI signature, which is the one every libc in this project's reach but
/// glibc actually has.
extern fn strerror_r(e: c_int, buf: [*]u8, len: usize) callconv(.c) c_int;

/// glibc's `strerror_r` is a different function with the same name: it returns
/// `char *`, and may answer a static string without touching the buffer at all.
/// One symbol cannot be declared twice, so the second signature is a cast of
/// the first rather than a second `extern`, and the cast is reached only under
/// the comptime test above.
const GnuStrerrorR = *const fn (c_int, [*]u8, usize) callconv(.c) [*]u8;
const gnuStrerrorR: GnuStrerrorR = @ptrCast(&strerror_r);

/// Fill `out` with `n` cryptographically random bytes, answering 0 on success.
///
/// Three implementations, exactly as the C original picks them. Windows draws
/// from `rand_s` an `unsigned int` at a time; BSD and macOS have
/// `arc4random_buf`; everywhere else reads `/dev/urandom`, because the C
/// original's comment records that `getrandom` "doesn't seem to be uniformly
/// supported on linux distros".
///
/// Only one of the three is compiled for any target, which is the shape Phase
/// 10's rule 5 warns about: the Linux arm is type-checked by the Linux
/// cross-compile in the acceptance matrix and by nothing on this host.
pub fn cryptorand(out: [*]u8, n: usize) callconv(.c) c_int {
    if (!config.cryptorand) return -1;

    if (windows) {
        var i: usize = 0;
        while (i < n) : (i += @sizeOf(c_uint)) {
            var v: c_uint = undefined;
            if (rand_s(&v) != 0) return -1;
            var j: usize = 0;
            while (j < @sizeOf(c_uint) and i + j < n) : (j += 1) {
                out[i + j] = @truncate(v & 0xff);
                v = v >> 8;
            }
        }
        return 0;
    }

    if (has_arc4random) {
        arc4random_buf(out, n);
        return 0;
    }

    var randfd: c_int = undefined;
    while (true) {
        randfd = std.c.open("/dev/urandom", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (!(randfd < 0 and errno() == EINTR)) break;
    }
    if (randfd < 0) return -1;

    var cursor = out;
    var left = n;
    while (left > 0) {
        var nread: isize = undefined;
        while (true) {
            nread = std.c.read(randfd, cursor, left);
            if (!(nread < 0 and errno() == EINTR)) break;
        }
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
    while (true) {
        if (!(std.c.close(fd) < 0 and errno() == EINTR)) break;
    }
}

/// `JANET_BSD || MAC_OS_X_VERSION_10_7` as the C original spells it. The second
/// comes from `<AvailabilityMacros.h>` and is defined on every macOS the
/// project supports, so the test is "a BSD, Apple included".
const has_arc4random = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

extern fn arc4random_buf(buf: [*]u8, nbytes: usize) callconv(.c) void;
extern fn rand_s(v: *c_uint) callconv(.c) c_int;

inline fn errno() c_int {
    return std.c._errno().*;
}

const EINTR: c_int = @intFromEnum(std.c.E.INTR);

// ------------------------------------------------------ dynamic module names

/// Turn a bare module name into a path the dynamic loader will treat as
/// relative to the working directory.
///
/// `dlopen("foo.so")` searches the loader's path; `dlopen("./foo.so")` does
/// not. A name that already starts with `.` or contains a `/` is left alone
/// and returned as-is, which is why the caller must not free the result
/// unconditionally -- it may be the argument. The C original's signature drops
/// the `const` to say so, and the port keeps that rather than improving it.
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

// `error_clib`, `load_clib`, `symbol_clib` and `free_clib` are not here.
// `get_processed_name` above is the part of `util.c`'s dynamic-module section
// that is the same on every platform; the rest is per-platform and lives in
// `dynlib.zig`, under this same selector, because one of the four raises and
// two callers share all of them.

// ------------------------------------------------------- allocator wrappers

// `janet.h` declares each of these beside a macro of the same name, the way it
// does the four head accessors above, and for the same reason: an embedder who
// reaches Janet through the shared library has no macro. Inside the runtime
// every call takes the macro, so nothing in the tree calls these four.
//
// They are ported rather than deleted. Phase 10's second decision ends the C
// ABI, which makes them dead weight -- but what the finished runtime exports is
// Phase 11's question, and deleting an exported symbol here would answer it
// early.

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
