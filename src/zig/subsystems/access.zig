//! Indexed and keyed access as its callers see it.
//!
//! It had a second arm until Phase 11 Part 26: `-Dvalue-access=c` resolved
//! this to `value_access_extern.zig`, the C symbols wearing the same
//! signatures. Phase 10 Part 18 spent the selector; the shim then sat behind a
//! comptime-`false` branch that nothing analyses.
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

const impl = @import("value_access.zig");

pub const next = impl.next;
pub const nextImpl = impl.nextImpl; // janet_next_impl
pub const in = impl.in;
pub const get = impl.getImpl; // janet_get
pub const getIndex = impl.getIndex; // janet_getindex
pub const length = impl.length;
pub const lengthv = impl.lengthv;
pub const putIndex = impl.putIndex; // janet_putindex
pub const put = impl.put;
