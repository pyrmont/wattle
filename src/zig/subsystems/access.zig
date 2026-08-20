//! Indexed and keyed access as its callers see it: `-Dvalue-access`'s
//! implementation when the selector says Zig, and the C symbols wearing the
//! same signatures when it says C.
//!
//! Phase 10 Part 17c. `janet_in`, `janet_getindex`, `janet_length`,
//! `janet_lengthv`, `janet_putindex`, `janet_put` and the iteration protocol
//! behind `next` are what the interpreter reaches at seven opcodes and what a
//! dozen subsystems reach besides. Panicking *is* their contract — `janet_in`
//! raises on a key that is wrong for the container, `janet_length` on a value
//! with no length — so they are the layer that most obviously had to stop
//! jumping before the third `setjmp` could go.
//!
//! `janet_get` is deliberately **not** here, and a caller still writes
//! `c.janet_get(...)`. It answers nil for a key it cannot use rather than
//! raising, which is Phase 10's fourth rule — a function that cannot raise
//! should not pretend it can — and a façade that listed it would put a `try`
//! on it at every call site, which is a lie about what it does. It resolves to
//! whichever implementation the selector linked, exactly as before, because it
//! is the same symbol either way.

const options = @import("options");

const impl = if (options.value_access)
    @import("value_access.zig")
else
    @import("value_access_extern.zig");

pub const next = impl.next;
pub const nextImpl = impl.nextImpl; // janet_next_impl
pub const in = impl.in;
pub const get = impl.getImpl; // janet_get
pub const getIndex = impl.getIndex; // janet_getindex
pub const length = impl.length;
pub const lengthv = impl.lengthv;
pub const putIndex = impl.putIndex; // janet_putindex
pub const put = impl.put;
