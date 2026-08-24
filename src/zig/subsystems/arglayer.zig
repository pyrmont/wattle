//! The argument layer as its callers see it.
//!
//! It had a second arm until Phase 11 Part 26: `-Dargs-core=c` resolved this
//! to `args_core_extern.zig`, the C symbols wearing the same signatures. Phase
//! 10 Part 18 spent that selector and the shim was stranded behind a
//! comptime-`false` branch for eight parts.
//!
//! Phase 10 Part 17b. Every cfunction in the runtime opens with two or three
//! calls into this layer — `janet_fixarity`, then a getter per argument — and
//! until this part every one of them was a C-ABI call that raised by jumping.
//! There were 656 of them. They are the largest single population of jumps in
//! the tree and the first thing Part 17 has to convert, because the third
//! `setjmp` cannot go while any of them remains.
//!
//! ## Why this file exists rather than a conditional import per caller
//!
//! `vm_run.zig` imports `vm_calls` and `value_wrap` at its own head, which was
//! right for two importers when each of those was a comptime `if`. This layer
//! has twenty-eight, and twenty-eight copies of the same two-line conditional
//! is worse than one copy plus an import. The conditionals are gone and the
//! argument stands without them: naming each declaration makes the layer's Zig
//! interface a thing a reader can look at, which the C header stopped being
//! once the getters were generated rather than written.
//!
//! It cannot be a *module* in `build.zig`'s sense, which would be the obvious
//! answer. `args_core.zig` is already in the root module — the root imports it
//! for its `export`s — and a second module instance over the same file would
//! compile it twice and define every `janet_get*` twice. One module, one
//! instance, and this file is a plain re-export inside it.
//!
//! ## What a caller writes
//!
//!     const arglayer = @import("arglayer.zig");
//!
//!     fn cfunSlice(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
//!         try arglayer.fixarity(argc, 2);
//!         const s = try arglayer.getString(argv, 0);
//!         ...
//!     }
//!
//! The `try` is the entire point. Under the C ABI the same call raised by
//! jumping past this frame, which was invisible at the call site and could not
//! be forgotten *or* observed; now forgetting it is a compile error and every
//! raise-capable path is visible in the signature.

const impl = @import("args_core.zig");

pub const fixarity = impl.fixarity;
pub const arity = impl.arity;

pub const getNumber = impl.getNumber;
pub const getArray = impl.getArray;
pub const getTuple = impl.getTuple;
pub const getTable = impl.getTable;
pub const getStruct = impl.getStruct;
pub const getString = impl.getString;
pub const getKeyword = impl.getKeyword;
pub const getSymbol = impl.getSymbol;
pub const getBuffer = impl.getBuffer;
pub const getFiber = impl.getFiber;
pub const getFunction = impl.getFunction;
pub const getCFunction = impl.getCFunction;
pub const getBoolean = impl.getBoolean;
pub const getPointer = impl.getPointer;

pub const optNumber = impl.optNumber;
pub const optTuple = impl.optTuple;
pub const optStruct = impl.optStruct;
pub const optString = impl.optString;
pub const optKeyword = impl.optKeyword;
pub const optSymbol = impl.optSymbol;
pub const optFiber = impl.optFiber;
pub const optFunction = impl.optFunction;
pub const optCFunction = impl.optCFunction;
pub const optBoolean = impl.optBoolean;
pub const optPointer = impl.optPointer;

pub const optBuffer = impl.optBuffer;
pub const optTable = impl.optTable;
pub const optArray = impl.optArray;

pub const getNat = impl.getNat;
pub const getInteger = impl.getInteger;
pub const getUInteger = impl.getUInteger;
pub const getInteger16 = impl.getInteger16;
pub const getUInteger16 = impl.getUInteger16;
pub const getInteger8 = impl.getInteger8;
pub const getUInteger8 = impl.getUInteger8;
pub const getFloat = impl.getFloat;
pub const getSize = impl.getSize;
pub const getInteger64 = impl.getInteger64;
pub const getUInteger64 = impl.getUInteger64;

pub const optNat = impl.optNat;
pub const optInteger = impl.optInteger;
pub const optInteger64 = impl.optInteger64;
pub const optSize = impl.optSize;
pub const optUInteger = impl.optUInteger;
pub const optUInteger64 = impl.optUInteger64;

pub const getSlice = impl.getSlice;
pub const getHalfRange = impl.getHalfRange;
pub const getArgIndex = impl.getArgIndex;
pub const getStartRange = impl.getStartRange;
pub const getEndRange = impl.getEndRange;

pub const getIndexed = impl.getIndexed;
pub const getDictionary = impl.getDictionary;
pub const getBytes = impl.getBytes;
pub const getAbstract = impl.getAbstract;
pub const optAbstract = impl.optAbstract;

pub const getCBytes = impl.getCBytes;
pub const getCString = impl.getCString;
pub const optCBytes = impl.optCBytes;
pub const optCString = impl.optCString;
pub const getFlags = impl.getFlags;

pub const panicType = impl.panicType;
pub const panicAbstract = impl.panicAbstract;
