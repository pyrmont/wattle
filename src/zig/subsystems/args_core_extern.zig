//! `args_core.zig`'s Zig interface, resolved to the C symbols instead of the
//! Zig bodies. `subsystems/arglayer.zig` picks between the two on `-Dargs-core`.
//!
//! Phase 10 Part 17b. Every signature here is derived from the C declaration by
//! `raise.declared` rather than written out, for the reason that helper gives:
//! sixty-odd declarations that must match `janet.h` exactly are sixty-odd
//! chances to drift, and a drifted one is a silent ABI mismatch rather than a
//! compile error.
//!
//! Under this selector the error is **declared and never returned** — the C
//! body raises from the inside by jumping, so the Zig frame that called it is
//! jumped through rather than returned to. That is what keeps `-Dargs-core=c` a
//! selector rather than a second dialect its callers have to know about, and it
//! is why the file carries the marker: every call here can be jumped out of.
//!
//! Everything here is also a call across a compilation boundary, which is the
//! cost the selector is charged rather than the port: the argument layer is
//! reached two or three times at the head of every cfunction in the runtime,
//! and under `-Dargs-core=zig` those are ordinary in-module calls the optimizer
//! can see through.

const abi = @import("abi");
const raise = @import("raise");
const c = abi.c;

pub const fixarity = raise.declared(c.janet_fixarity).call;
pub const arity = raise.declared(c.janet_arity).call;

pub const getNumber = raise.declared(c.janet_getnumber).call;
pub const getArray = raise.declared(c.janet_getarray).call;
pub const getTuple = raise.declared(c.janet_gettuple).call;
pub const getTable = raise.declared(c.janet_gettable).call;
pub const getStruct = raise.declared(c.janet_getstruct).call;
pub const getString = raise.declared(c.janet_getstring).call;
pub const getKeyword = raise.declared(c.janet_getkeyword).call;
pub const getSymbol = raise.declared(c.janet_getsymbol).call;
pub const getBuffer = raise.declared(c.janet_getbuffer).call;
pub const getFiber = raise.declared(c.janet_getfiber).call;
pub const getFunction = raise.declared(c.janet_getfunction).call;
pub const getCFunction = raise.declared(c.janet_getcfunction).call;
pub const getBoolean = raise.declared(c.janet_getboolean).call;
pub const getPointer = raise.declared(c.janet_getpointer).call;

pub const optNumber = raise.declared(c.janet_optnumber).call;
pub const optTuple = raise.declared(c.janet_opttuple).call;
pub const optStruct = raise.declared(c.janet_optstruct).call;
pub const optString = raise.declared(c.janet_optstring).call;
pub const optKeyword = raise.declared(c.janet_optkeyword).call;
pub const optSymbol = raise.declared(c.janet_optsymbol).call;
pub const optFiber = raise.declared(c.janet_optfiber).call;
pub const optFunction = raise.declared(c.janet_optfunction).call;
pub const optCFunction = raise.declared(c.janet_optcfunction).call;
pub const optBoolean = raise.declared(c.janet_optboolean).call;
pub const optPointer = raise.declared(c.janet_optpointer).call;

pub const optBuffer = raise.declared(c.janet_optbuffer).call;
pub const optTable = raise.declared(c.janet_opttable).call;
pub const optArray = raise.declared(c.janet_optarray).call;

pub const getNat = raise.declared(c.janet_getnat).call;
pub const getInteger = raise.declared(c.janet_getinteger).call;
pub const getUInteger = raise.declared(c.janet_getuinteger).call;
pub const getInteger16 = raise.declared(c.janet_getinteger16).call;
pub const getUInteger16 = raise.declared(c.janet_getuinteger16).call;
pub const getInteger8 = raise.declared(c.janet_getinteger8).call;
pub const getUInteger8 = raise.declared(c.janet_getuinteger8).call;
pub const getFloat = raise.declared(c.janet_getfloat).call;
pub const getSize = raise.declared(c.janet_getsize).call;
pub const getInteger64 = raise.declared(c.janet_getinteger64).call;
pub const getUInteger64 = raise.declared(c.janet_getuinteger64).call;

pub const optNat = raise.declared(c.janet_optnat).call;
pub const optInteger = raise.declared(c.janet_optinteger).call;
pub const optInteger64 = raise.declared(c.janet_optinteger64).call;
pub const optSize = raise.declared(c.janet_optsize).call;
pub const optUInteger = raise.declared(c.janet_optuinteger).call;
pub const optUInteger64 = raise.declared(c.janet_optuinteger64).call;

pub const getSlice = raise.declared(c.janet_getslice).call;
pub const getHalfRange = raise.declared(c.janet_gethalfrange).call;
pub const getArgIndex = raise.declared(c.janet_getargindex).call;
pub const getStartRange = raise.declared(c.janet_getstartrange).call;
pub const getEndRange = raise.declared(c.janet_getendrange).call;

pub const getIndexed = raise.declared(c.janet_getindexed).call;
pub const getDictionary = raise.declared(c.janet_getdictionary).call;
pub const getBytes = raise.declared(c.janet_getbytes).call;
pub const getAbstract = raise.declared(c.janet_getabstract).call;
pub const optAbstract = raise.declared(c.janet_optabstract).call;

pub const getCBytes = raise.declared(c.janet_getcbytes).call;
pub const getCString = raise.declared(c.janet_getcstring).call;
pub const optCBytes = raise.declared(c.janet_optcbytes).call;
pub const optCString = raise.declared(c.janet_optcstring).call;
pub const getFlags = raise.declared(c.janet_getflags).call;

/// The two fault reporters, which never return in either implementation.
/// `raise.declared` does not apply: it wraps a function that comes back, and
/// these are `JANET_NO_RETURN`. The Zig side answers with the bare error set so
/// that a caller writes `return arglayer.panicType(...)`, and these two do the same
/// with a body the compiler knows is unreachable past the call.
pub fn panicType(x: c.Janet, n: i32, expected: c_int) raise.Error {
    try raise.crossing(c.janet_panic_type(x, n, expected));
}

pub fn panicAbstract(x: c.Janet, n: i32, at: *const c.JanetAbstractType) raise.Error {
    try raise.crossing(c.janet_panic_abstract(x, n, at));
}
