//! Argument extraction: checking whether a cfunction's arguments are what it
//! asked for, and saying so.
//!
//! A `get*` function reads one argument and raises where it is not what was
//! asked for; an `opt*` function takes a default for an absent or nil slot.
//! `fixarity` and `arity` check the count. `getSlice` and `getRange` fold a
//! slice argument, `getFlags` decodes a keyword of flag characters, and
//! `items`, `bytesView` and `dictionaryView` classify a value without raising
//! at all.
//!
//! Deciding and saying are one layer here. A getter that formats its own
//! complaint allocates and allocation can raise, so the kernels, the wording,
//! every `get` and `opt` getter, and the three probes are one subsystem.
//!
//! ## Why the kernels report a fault instead of raising
//!
//! Three probes must not raise at all. `items`, `bytesView` and
//! `dictionaryView` report "not that kind of value" to the pretty printer, the
//! bytecode reader and the compiler's constant folding, and `checkabstract`
//! gives back null; a kernel that raised would need a non-raising twin for
//! each of them. A kernel that fills in a `Fault` serves both, and the wording
//! still lives in exactly one place, `raiseFault`. `argBytes` and `argCbytes`
//! each say at their own declaration where that line falls for them.
//!
//! ## What raises, and what a raise costs
//!
//! A getter returns `raise.Error!T` and the `opt` layer above it calls that
//! form, so a default-taking wrapper propagates an error rather than losing
//! one. Nothing here catches its own error.
//!
//! The `bytes` callback is not the only thing here that can raise. `getCBytes`
//! calls `gc.smalloc` and `buffers.pushU8`, `optBuffer` and its two siblings
//! allocate, `getSlice` calls `access.length`, and with integer types enabled
//! `getInteger64` calls `ints.unwrapS64`. Nothing here is stranded across any
//! of them.
//!
//! ## The published bridges
//!
//! A published getter receives a bare pointer and, in most of the family, no
//! count at all: `getBytesAbi(argv, n)` has nowhere to put one.
//! The Zig side takes a slice, because the tree calls it a great many times
//! and `argv[n]` should be checked. `IndexAbi` makes the join, and each
//! `*Abi` name is where that is paid. `argSlot` is where the check happens: a
//! kernel reads its argument through it, and a slot past the end reads as
//! nil.
//!
//! A bare pointer stays at the border rather than at the directory: what a C
//! caller hands over is a bare pointer, and a slice built here would state a
//! length the caller never passed. What each bridge does is write down the
//! assertion the caller is already making by calling at all. The spelling is
//! `[*]const repr.Value`, still a bare pointer, still sliced no further than
//! the `n` the caller passed, and saying that null is not among the things it
//! accepts.
//!
//! ## The Zig side of the layer
//!
//! Everything above has two faces: an implementation returning
//! `raise.Error!T`, and a wrapper published under the C name. A Zig caller
//! takes the first, and the `get*` and `opt*` constants are the names it is
//! reachable by. Nothing here is exported: they are aliases for an importer,
//! and the exported set is unchanged. The names are upstream's with the prefix
//! dropped and the words separated, which is the only liberty taken:
//! `getcstring` reads `getCString` here.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstracts = @import("value/abstracts.zig");
const access = @import("value/helpers/access.zig");
pub const arrays = @import("value/arrays.zig");
pub const buffers = @import("value/buffers.zig");
const fatal = @import("fatal.zig");
const gc_alloc = @import("gc.zig");
const method_type = @import("method_type.zig");
const options = @import("options");
const pp_format = @import("pp/format.zig");
const raise = @import("../api/raise.zig");
const repr = @import("repr");
const strings = @import("value/strings.zig");
const structs = @import("value/structs.zig");
pub const tables = @import("value/tables.zig");
const tuples = @import("value/tuples.zig");
const utils = @import("utils.zig");
const value = @import("value.zig");
const vm_state = @import("vm/state.zig");
const wrap = @import("value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// The nine numeric kernels, one per width. Each checks with the predicate its
/// width names, converts the double, and fills in a `.wrong_number` fault
/// otherwise. `argInteger` and `argNat` are written out instead, because an
/// integer is unwrapped rather than converted.
pub const argFloat = numberGetter(f32, .float, checkfloat);
pub const argInteger16 = numberGetter(i16, .s16, checkint16);
pub const argInteger64 = numberGetter(i64, .s64, checkint64);
pub const argInteger8 = numberGetter(i8, .s8, checkint8);
pub const argSize = numberGetter(usize, .size, checksize);
pub const argUinteger = numberGetter(u32, .u32, checkuint);
pub const argUinteger16 = numberGetter(u16, .u16, checkuint16);
pub const argUinteger64 = numberGetter(u64, .u64, checkuint64);
pub const argUinteger8 = numberGetter(u8, .u8, checkuint8);

/// The two arity checks by count, for a caller that has one and no vector.
///
/// `fixArityAbi` fills the table's `fixarity` from this, and
/// `test/args_core.zig` asserts against counts no contract would build a
/// vector for: `arityCount(99, 1, -1)` says what ninety-nine arguments would
/// do without allocating them.
pub const arityCount = checkArity;
pub const fixarityCount = fixArity;

/// `getAbstractPtr`, published.
pub const getAbstractAbi = IndexAbi(getAbstractPtr).abi;

/// The four range helpers under the names the C surface uses, because there
/// the name says `get` and the implementation does not. Every other getter
/// already wears its published name.
pub const getArgIndex = argIndex;
pub const getEndRange = endRange;
pub const getHalfRange = halfRange;
pub const getStartRange = startRange;

/// The fourteen type getters, as a Zig caller names them.
pub const getArray = GetArray.get;
pub const getBoolean = GetBoolean.get;
pub const getBuffer = GetBuffer.get;
pub const getCFunction = GetCFunction.get;
pub const getFiber = GetFiber.get;
pub const getFunction = GetFunction.get;
pub const getKeyword = GetKeyword.get;
pub const getNumber = GetNumber.get;
pub const getPointer = GetPointer.get;
pub const getString = GetString.get;
pub const getStruct = GetStruct.get;
pub const getSymbol = GetSymbol.get;
pub const getTable = GetTable.get;
pub const getTuple = GetTuple.get;

/// The three view getters, published. Each takes `argv` and `n` and reports a
/// raise through `raise.reportToAbi`.
pub const getBytesAbi = IndexAbi(getBytes).abi;
pub const getDictionaryAbi = IndexAbi(getDictionary).abi;
pub const getIndexedAbi = IndexAbi(indexedAbi).abi;

/// The eleven numeric getters, as a Zig caller names them.
pub const getFloat = GetFloat.get;
pub const getInteger = GetInteger.get;
pub const getInteger16 = GetInteger16.get;
pub const getInteger64 = GetInteger64.get;
pub const getInteger8 = GetInteger8.get;
pub const getNat = GetNat.get;
pub const getSize = GetSize.get;
pub const getUInteger = GetUInteger.get;
pub const getUInteger16 = GetUInteger16.get;
pub const getUInteger64 = GetUInteger64.get;
pub const getUInteger8 = GetUInteger8.get;

/// Whether this build compiles `value/ints.zig`.
///
/// With integer types enabled the two 64-bit getters accept an `int/s64` or
/// `int/u64` abstract as well as a number, and the conversion raises its own
/// message rather than filling in a fault, so the whole decision is there and
/// there is nothing for a kernel to report.
///
/// `inttypes.unwrapS64` is reached by import and its raise is returned, and
/// the difference is not cosmetic. A `raise.toAbi` form here would turn a
/// refusal into a report nobody consumes: the getter gives back zero, its
/// caller continues with a value the user never supplied, and the outstanding
/// report kills the process at the next scope boundary with a message naming
/// neither the slot nor the builtin. `(string/format "%d" "x")` is the
/// reproduction, because `pp/format.zig` is one of the callers. It is the
/// defect `res/check/swallowed.janet` exists to find.
const int_types_enabled = options.int_types_core;

/// The 64-bit range is 2^53, the largest integer a double represents exactly,
/// rather than `maxInt(i64)`. Beyond it the round trip would accept values a
/// double cannot distinguish from their neighbours.
const intmax_double: f64 = 9007199254740992.0;
const intmin_double: f64 = -9007199254740992.0;

/// The two 64-bit conversions, where the configuration has them.
///
/// `-Dint-types=false` compiles no `value/ints.zig` at all, and `Wide` names
/// nothing in this namespace in that case. Zig does not analyse the untaken
/// arm of a comptime-known `if`, which is what makes the empty struct
/// sufficient rather than a stub.
const inttypes = if (options.int_types_core) @import("value/ints.zig") else struct {};

/// The three mutable containers, whose default is a fresh empty one of the
/// given capacity rather than a value the caller supplies.
pub const optArray = OptLen(GetArray, arrays.new).get;
pub const optBuffer = OptLen(GetBuffer, buffers.new).get;
pub const optTable = OptLen(GetTable, tables.new).get;

/// The eleven type getters that take a default.
pub const optBoolean = Opt(GetBoolean).get;
pub const optCFunction = Opt(GetCFunction).get;
pub const optFiber = Opt(GetFiber).get;
pub const optFunction = Opt(GetFunction).get;
pub const optKeyword = Opt(GetKeyword).get;
pub const optNumber = Opt(GetNumber).get;
pub const optPointer = Opt(GetPointer).get;
pub const optString = Opt(GetString).get;
pub const optStruct = Opt(GetStruct).get;
pub const optSymbol = Opt(GetSymbol).get;
pub const optTuple = Opt(GetTuple).get;

/// The six numeric getters that take a default.
pub const optInteger = Opt(GetInteger).get;
pub const optInteger64 = Opt(GetInteger64).get;
pub const optNat = Opt(GetNat).get;
pub const optSize = Opt(GetSize).get;
pub const optUInteger = Opt(GetUInteger).get;
pub const optUInteger64 = Opt(GetUInteger64).get;

// ==========================================================================
// Aliased types
// ==========================================================================

/// `dictionaryView`'s result, and `getSlice`'s.
///
/// Both are declared in `abi.zig` because a module author receives them:
/// `getDictionaryAbi` and `getRangeAbi` return them by value across the
/// boundary, so the two compilations have to spell the same fields. The
/// operations that build them are here, which is the split every other crossed
/// layout has. `abi.zig` has what each field means.
pub const DictView = abi.DictView;
pub const Range = abi.Range;

// ==========================================================================
// Types
// ==========================================================================

/// A getter over the numeric widths, whose kernels report through a `*Fault`
/// rather than raising.
fn ArgGetter(comptime T: type, comptime kernel: anytype) type {
    return struct {
        pub const Value = T;
        pub fn get(argv: []const repr.Value, n: usize) raise.Error!T {
            var fault: Fault = undefined;
            return kernel(argv, n, &fault) orelse raiseFault(argv, fault);
        }
        pub const abi = IndexAbi(get).abi;
    };
}

/// Either the bytes, or the abstract whose callback still has to be run.
///
/// The second arm is a leftover and nothing depends on it. The split was built
/// for a `bytes` callback that could raise, so that a caller which may not
/// raise could stop before reaching one. It cannot raise, `abi.zig` declaring
/// `bytes` as `callconv(.c)`, and both callers of `argBytes` take this arm
/// straight into `abstractBytes`, so the kernel could give back the view
/// itself. Collapsing it is a later increment's; nothing here is wrong, only
/// wider than it needs to be.
pub const Bytes = union(enum) {
    view: abi.ByteView,
    abstract: abstracts.Abstract,
};

/// Which shape `getCBytes` must use.
///
/// `view` is only for the shapes that come with their own terminator: a
/// string, a symbol and a keyword are interned with one. An abstract's `bytes`
/// callback gives back a view of the module author's choosing and nothing
/// requires a terminator after it, so it is copied and terminated the way an
/// unresizable buffer is. Otherwise `getCBytes` would give back a pointer
/// whose C string runs past the end of the view.
///
/// Both copying shapes mutate or allocate, so neither is performed here. It
/// cannot fault, so it takes no fault.
pub const CBytes = enum { copy_buffer, copy_view, terminate, view };

/// What a site reports when what it read the second time is longer than what
/// it measured the first.
///
/// A site that measures, allocates and then copies reads its value twice, and
/// an abstract answers both reads through callbacks that run code. The copy
/// holds itself to what was measured and reports this rather than writing past
/// what it allocated.
pub const grew_message = "indexed value grew while being read";

/// What that site reports when the second read is shorter instead.
pub const shrank_message = "indexed value shrank while being read";

/// The elements of an indexed value, read one run at a time. `chunks` returns
/// a `Chunks`.
///
/// An array or a tuple is one run. An abstract is as many runs as its `chunk`
/// callback gives, and `next` asks the callback for the run that holds the
/// first element not yet returned.
///
/// A run stays valid until the next call that can allocate or run Janet code,
/// or until the next `next` on the same value.
///
/// ```zig
/// var it = (try args.chunks(x)) orelse return fault;
/// while (try it.next()) |run| {
///     // run is a []const repr.Value
/// }
/// ```
pub const Chunks = struct {
    /// Where the elements come from.
    source: Source,
    /// The value's length, which is what a run is checked against rather than
    /// what reading stops at.
    len: usize,
    /// The position of the next element to return.
    index: usize = 0,
    /// The position reading stops at. `chunks` sets it to `len` and `window`
    /// narrows it.
    limit: usize,

    /// Where the elements come from.
    pub const Source = union(enum) {
        contiguous: []const repr.Value,
        abstract: struct { payload: *anyopaque, at: *const abi.AbstractType },
    };

    /// Returns the next run, or null when every element has been returned.
    ///
    /// This function raises if a `chunk` callback returns a run that does not
    /// hold the index it was asked for, or that reaches past the length.
    ///
    /// It is `inline`. The branch on the source then folds into the caller's
    /// loop, so a site reading an array or a tuple pays no call for the single
    /// run it gets back.
    pub inline fn next(self: *Chunks) raise.Error!?[]const repr.Value {
        if (self.index >= self.limit) return null;
        switch (self.source) {
            .contiguous => |elements| {
                const run = elements[self.index..self.limit];
                self.index = self.limit;
                return run;
            },
            .abstract => |a| {
                const run = try takeChunk(a.payload, a.at, self.index, self.len);
                // Clipped to the window at both ends. A run reaching past
                // `limit` is a correct answer from a type whose runs are
                // longer than what was asked for, which is every type worth
                // having, so it is cut rather than refused.
                const from = self.index - run.start;
                const to = @min(run.len, self.limit - run.start);
                const elements = run.items.?[from..to];
                self.index = run.start + to;
                return elements;
            },
        }
    }

    /// Narrows the iterator to the half-open range `[from, to)`.
    ///
    /// `from` and `to` are positions in the value, and the caller has already
    /// checked both against its length: `getSlice` does that against
    /// `access.length`. A `to` at or below `from` reads nothing.
    ///
    /// The window is where reading now stands, so a `from` below what has
    /// already been read rewinds: a site making two passes over one value
    /// rewinds between them rather than building a second iterator, and reads
    /// `length` once instead of twice.
    pub fn window(self: *Chunks, from: usize, to: usize) void {
        self.index = from;
        self.limit = to;
    }
};

/// What a numeric kernel expected, and the only place the nouns are written.
///
/// A kernel reports `.s16` and `Expect.name` spells it "16 bit
/// signed integer", which is what makes the wording live in one place.
pub const Expect = enum {
    nat,
    size,
    s32,
    u32,
    s16,
    u16,
    s8,
    u8,
    float,
    s64,
    u64,

    fn name(self: Expect) [*:0]const u8 {
        return switch (self) {
            .nat => "non-negative 32 bit signed integer",
            .size => "size",
            .s32 => "32 bit signed integer",
            .u32 => "32 bit unsigned integer",
            .s16 => "16 bit signed integer",
            .u16 => "16 bit unsigned integer",
            .s8 => "8 bit signed integer",
            .u8 => "8 bit unsigned integer",
            .float => "float number",
            .s64 => "64 bit signed integer",
            .u64 => "64 bit unsigned integer",
        };
    }
};

/// Why a kernel refused, with exactly what its message renders.
///
/// A tagged union rather than a code beside a wide payload: a field is
/// reachable only from the arm that filled it, so nothing has to say which
/// kinds may read `slot`, and `raiseFault`'s switch is exhaustive without an
/// `else`.
pub const Fault = union(enum) {
    wrong_type: struct { slot: usize, expected: repr.TagSet },
    wrong_abstract: struct { slot: usize, at: *const abi.AbstractType },
    wrong_number: struct { slot: usize, expected: Expect },
    /// Both range kinds. `inclusive` is the closed-interval rendering, which
    /// is `halfRange`'s; `argIndex` reports the half-open one.
    ///
    /// The three quantities are `i64` because the message is fixed: `%d`
    /// renders that width, and the digits a program sees are the same for
    /// every index this runtime can produce.
    range: struct { which: [*:0]const u8, raw: i64, lo: i64, hi: i64, inclusive: bool },
    bad_flag: struct { byte: u8, permitted: [*:0]const u8 },
    embedded_zero,
    arity_fix: struct { got: i32, want: i32 },
    arity_min: struct { got: i32, want: i32 },
    arity_max: struct { got: i32, want: i32 },
};

/// The fourteen type getters. Each checks the tag and unwraps it, raising
/// `panicType` otherwise, and publishes its own `abi` shim.
/// An indexed value's elements in one block. `gather` returns a `Gathered`.
///
/// A site that needs every element at once, rather than a run at a time, asks
/// for this: the elements of an array or a tuple are borrowed where they lie,
/// and an abstract's runs are copied into one block.
///
/// ```zig
/// var got = (try args.gather(x)) orelse return fault;
/// // got.items is a []const repr.Value
/// got.free();
/// ```
pub const Gathered = struct {
    items: []const repr.Value,
    /// Whether `items` is a copy this made or the value's own storage.
    copied: bool,

    /// Releases the copy where one was made, and does nothing where the
    /// elements were borrowed.
    ///
    /// This is called on the path that returns rather than through a `defer`.
    /// A copy is on the scratch heap, so a raise between `gather` and here
    /// abandons it and the sweep at the end of the next collection reclaims
    /// it, which is the rule `scratch_vector.zig` states for every user of
    /// that heap.
    ///
    /// The cast is over memory this allocated, which is handed out as `const`
    /// because a reader has no business writing to it.
    pub fn free(self: *Gathered) void {
        if (self.copied) gc_alloc.scratch_heap.free(@constCast(self.items));
    }
};

pub const GetArray = TypeGetter(wrap.toArray, repr.Tag.array, repr.TagSet.one(.array));
pub const GetBoolean = TypeGetter(wrap.toBoolean, repr.Tag.boolean, repr.TagSet.one(.boolean));
pub const GetBuffer = TypeGetter(wrap.toBuffer, repr.Tag.buffer, repr.TagSet.one(.buffer));
pub const GetCFunction = TypeGetter(wrap.toCfunction, repr.Tag.cfunction, repr.TagSet.one(.cfunction));
pub const GetFiber = TypeGetter(wrap.toFiber, repr.Tag.fiber, repr.TagSet.one(.fiber));
pub const GetFunction = TypeGetter(wrap.toFunction, repr.Tag.function, repr.TagSet.one(.function));
pub const GetKeyword = TypeGetter(wrap.toKeyword, repr.Tag.keyword, repr.TagSet.one(.keyword));
pub const GetNumber = TypeGetter(wrap.toNumber, repr.Tag.number, repr.TagSet.one(.number));
pub const GetPointer = TypeGetter(wrap.toPointer, repr.Tag.pointer, repr.TagSet.one(.pointer));
pub const GetString = TypeGetter(wrap.toString, repr.Tag.string, repr.TagSet.one(.string));
pub const GetStruct = TypeGetter(wrap.toStruct, repr.Tag.@"struct", repr.TagSet.one(.@"struct"));
pub const GetSymbol = TypeGetter(wrap.toSymbol, repr.Tag.symbol, repr.TagSet.one(.symbol));
pub const GetTable = TypeGetter(wrap.toTable, repr.Tag.table, repr.TagSet.one(.table));
pub const GetTuple = TypeGetter(wrap.toTuple, repr.Tag.tuple, repr.TagSet.one(.tuple));

/// The nine numeric getters. Each calls the kernel its width names and turns a
/// fault into the raise it renders.
pub const GetFloat = ArgGetter(f32, argFloat);
pub const GetInteger = ArgGetter(i32, argInteger);
pub const GetInteger16 = ArgGetter(i16, argInteger16);
pub const GetInteger8 = ArgGetter(i8, argInteger8);
pub const GetNat = ArgGetter(i32, argNat);
pub const GetSize = ArgGetter(usize, argSize);
pub const GetUInteger = ArgGetter(u32, argUinteger);
pub const GetUInteger16 = ArgGetter(u16, argUinteger16);
pub const GetUInteger8 = ArgGetter(u8, argUinteger8);

/// The two 64-bit getters, which take the abstract types as well where the
/// configuration has them. See `int_types_enabled`.
pub const GetInteger64 = Wide(i64, if (int_types_enabled) inttypes.unwrapS64 else {}, argInteger64);
pub const GetUInteger64 = Wide(u64, if (int_types_enabled) inttypes.unwrapU64 else {}, argUinteger64);

/// The index family: `f(argv, n)` published as `abi(argv, n)`. Passing `n`
/// asserts that `n` is in range, so the slice is exactly long enough for it.
///
/// Two shapes rather than five. Four getters are left on this bridge, none of
/// them boolean and none past three parameters, so the `bool`-to-`c_int`
/// conversion and the arities above three are gone with the surface that
/// needed them.
fn IndexAbi(comptime f: anytype) type {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    const P = @typeInfo(info.return_type.?).error_union.payload;
    return switch (info.params.len) {
        2 => struct {
            pub fn abi(argv: [*]const repr.Value, n: i32) callconv(.c) P {
                vm_state.requireJanetThread();
                return f(argv[0..@intCast(n + 1)], @intCast(n)) catch raise.reportToAbi(P);
            }
        },
        3 => struct {
            pub fn abi(argv: [*]const repr.Value, n: i32, third: info.params[2].type.?) callconv(.c) P {
                vm_state.requireJanetThread();
                return f(argv[0..@intCast(n + 1)], @intCast(n), third) catch raise.reportToAbi(P);
            }
        },
        else => @compileError("IndexAbi: unhandled arity"),
    };
}

/// An optional argument: the default where the slot is absent or nil, and
/// `G`'s result otherwise. The fall-through is a `return` of an error union,
/// so a bad argument does not jump out of the frame that looked at
/// it.
pub fn Opt(comptime G: type) type {
    // A pointer default may be absent; a number default may not.
    const D = if (@typeInfo(G.Value) == .pointer) ?G.Value else G.Value;
    return struct {
        pub fn get(argv: []const repr.Value, n: usize, dflt: D) raise.Error!D {
            if (argIsdefault(argv, n)) return dflt;
            return @as(D, try G.get(argv, n));
        }
    };
}

/// The form for a container whose default is a fresh empty one of the given
/// capacity, built by `construct`, rather than a value the caller supplies.
pub fn OptLen(comptime G: type, comptime construct: anytype) type {
    return struct {
        pub fn get(argv: []const repr.Value, n: usize, dflt_len: usize) raise.Error!G.Value {
            if (argIsdefault(argv, n)) return construct(dflt_len);
            return G.get(argv, n);
        }
    };
}

/// A getter: check the type, then unwrap it.
///
/// The payload type is read off the unwrap function rather than written out
/// fourteen times, so a representation change, `-Dnanbox=false` returning a
/// different Zig type for several of these, cannot make the published
/// signature disagree with what the getter gives back.
fn TypeGetter(comptime unwrap: anytype, comptime janet_type: repr.Tag, comptime typeflags: repr.TagSet) type {
    return struct {
        pub const Value = @typeInfo(@TypeOf(unwrap)).@"fn".return_type.?;
        pub fn get(argv: []const repr.Value, n: usize) raise.Error!Value {
            var fault: Fault = undefined;
            if (!argChecktype(argv, n, janet_type, typeflags, &fault)) {
                return raiseFault(argv, fault);
            }
            return unwrap(argSlot(argv, n));
        }
        pub const abi = IndexAbi(get).abi;
    };
}

/// A 64-bit getter, which reaches `unwrap` where the configuration has the
/// abstract types and `kernel` where it does not.
fn Wide(comptime T: type, comptime unwrap: anytype, comptime kernel: anytype) type {
    return struct {
        pub const Value = T;
        pub fn get(argv: []const repr.Value, n: usize) raise.Error!T {
            if (int_types_enabled) return unwrap(argSlot(argv, n));
            var fault: Fault = undefined;
            return kernel(argv, n, &fault) orelse raiseFault(argv, fault);
        }
        pub const abi = IndexAbi(get).abi;
    };
}

// ==========================================================================
// Public functions
// ==========================================================================

/// The erased payload address, or nothing.
///
/// The pointer stays erased here on purpose. This is the classification layer,
/// and what it reports is that an abstract of that type is at this address;
/// the type arrives one layer up, at `getAbstract(comptime T, ...)` and at
/// `module.zig`'s form for authors, where the cast is the checked one. Making
/// the kernel generic over `T` would drag the fault protocol into the typed
/// layer, where the getters already raise and have no use for it.
pub fn argAbstract(
    argv: []const repr.Value,
    n: usize,
    at: *const abi.AbstractType,
    fault: *Fault,
) ?*anyopaque {
    const x = argSlot(argv, n);
    if (repr.checkType(x, repr.Tag.abstract)) {
        const abstractx = wrap.toAbstract(x);
        if (abi.abstractHead(abstractx).type == at) return abstractx;
    }
    fault.* = .{ .wrong_abstract = .{ .slot = n, .at = at } };
    return null;
}

/// An argument index folded against `length`, reported as a half-open range.
/// See `range` for how it differs from `argHalfrange`.
pub fn argArgindex(
    argv: []const repr.Value,
    n: usize,
    length: i32,
    which: [*:0]const u8,
    fault: *Fault,
) ?i32 {
    return range(argv, n, length, which, fault, false);
}

/// Whether `count` is within `min` and `max`. A negative bound means unbounded
/// on that side, which is how a cfunction with no maximum spells itself.
pub fn argArity(count: i32, min: i32, max: i32, fault: *Fault) bool {
    if (min >= 0 and count < min) {
        fault.* = .{ .arity_min = .{ .got = count, .want = min } };
        return false;
    }
    if (max >= 0 and count > max) {
        fault.* = .{ .arity_max = .{ .got = count, .want = max } };
        return false;
    }
    return true;
}

/// Classifies a byte-like value, and for the abstract case stops. See `Bytes`
/// for why the stop buys nothing now, and what would collapse it.
pub fn argBytes(x: repr.Value, n: usize, fault: *Fault) ?Bytes {
    switch (repr.typeOf(x)) {
        repr.Tag.string, repr.Tag.symbol, repr.Tag.keyword => {
            const string = wrap.toString(x);
            return .{ .view = .{
                .bytes = string,
                .len = strings.head(string).length,
            } };
        },
        repr.Tag.buffer => {
            const buffer = wrap.toBuffer(x);
            return .{ .view = .{
                .bytes = buffer.data.?,
                .len = @intCast(buffer.count),
            } };
        },
        repr.Tag.abstract => {
            const abst = wrap.toAbstract(x);
            if (abi.abstractHead(abst).type.bytes != null) return .{ .abstract = abst };
        },
        else => {},
    }
    fault.* = .{ .wrong_type = .{ .slot = n, .expected = repr.TagSet.bytes } };
    return null;
}

/// Which shape `getCBytes` must use for the argument at `n`. It cannot fault,
/// so it takes no fault.
pub fn argCbytes(argv: []const repr.Value, n: usize) CBytes {
    const x = argSlot(argv, n);
    if (repr.checkType(x, repr.Tag.buffer)) {
        const buffer = wrap.toBuffer(x);
        if (buffers.isForeign(buffer) and buffer.count == buffer.capacity) {
            return .copy_buffer;
        }
        return .terminate;
    }
    if (repr.checkType(x, repr.Tag.abstract)) return .copy_view;
    return .view;
}

/// Whether the argument at `n` has the tag `janet_type`, filling in a
/// `.wrong_type` fault naming `typeflags` otherwise.
pub fn argChecktype(
    argv: []const repr.Value,
    n: usize,
    janet_type: repr.Tag,
    typeflags: repr.TagSet,
    fault: *Fault,
) bool {
    if (repr.checkType(argSlot(argv, n), janet_type)) return true;
    fault.* = .{ .wrong_type = .{ .slot = n, .expected = typeflags } };
    return false;
}

/// A table's or a struct's entries.
///
/// Three quantities rather than two: the slice is the whole hash array, `cap`
/// long, and `len` is how many of its slots are occupied. A walk over a
/// dictionary reads every slot and skips the empty ones, so neither number
/// alone describes it.
pub fn argDictionary(
    argv: []const repr.Value,
    n: usize,
    fault: *Fault,
) ?DictView {
    const x = argSlot(argv, n);
    if (repr.checkType(x, repr.Tag.table)) {
        const table = wrap.toTable(x);
        return .{
            .kvs = table.data.?,
            .cap = @intCast(table.capacity),
            .len = @intCast(table.count),
        };
    } else if (repr.checkType(x, repr.Tag.@"struct")) {
        const structure = wrap.toStruct(x);
        return .{
            .kvs = structure,
            .cap = structs.head(structure).capacity,
            .len = structs.head(structure).length,
        };
    }
    fault.* = .{ .wrong_type = .{ .slot = n, .expected = repr.TagSet.dictionary } };
    return null;
}

/// Whether `count` is exactly `fix`, filling in an `.arity_fix` fault
/// otherwise.
pub fn argFixarity(count: i32, fix: i32, fault: *Fault) bool {
    if (count == fix) return true;
    fault.* = .{ .arity_fix = .{ .got = count, .want = fix } };
    return false;
}

/// The bits of `flags` that `keyw`'s characters name, or nothing.
///
/// The 64-flag ceiling is the result type's, and exceeding it is the caller's
/// mistake rather than the user's. A `u64` has no bit for a sixty-fifth flag,
/// so a `flags` set longer than 64 characters cannot be honoured; clamping it
/// instead would turn the caller's mistake into a wrong result about the
/// user's input, rejecting a keyword that names a character the quoted set
/// visibly contains. The set is written by whoever registered the cfunction,
/// so that is who the diagnosis names.
pub fn argFlags(
    keyw: [*]const u8,
    klen: usize,
    flags: [*:0]const u8,
    fault: *Fault,
) ?u64 {
    var ret: u64 = 0;
    const flen: usize = std.mem.len(flags);
    if (flen > 64) fatal.fatal("permitted flag set is longer than 64 characters");
    for (keyw[0..klen]) |byte| {
        var i: usize = 0;
        while (i < flen) : (i += 1) {
            if (flags[i] == byte) {
                ret |= @as(u64, 1) << @intCast(i);
                break;
            }
        }
        if (i == flen) {
            fault.* = .{ .bad_flag = .{ .byte = byte, .permitted = flags } };
            return null;
        }
    }
    return ret;
}

/// An index folded against `length`, reported as a closed range. See `range`
/// for how it differs from `argArgindex`.
pub fn argHalfrange(
    argv: []const repr.Value,
    n: usize,
    length: i32,
    which: [*:0]const u8,
    fault: *Fault,
) ?i32 {
    return range(argv, n, length, which, fault, true);
}

/// `argArgindex`, raising rather than filling in a fault.
pub fn argIndex(argv: []const repr.Value, n: usize, length: i32, which: [*:0]const u8) raise.Error!i32 {
    var fault: Fault = undefined;
    return argArgindex(argv, n, length, which, &fault) orelse raiseFault(argv, fault);
}

/// The elements of an array or a tuple, as the range they are.
///
/// A collection with no elements has a null data pointer, `arrays.init(a, 0)`
/// leaving it so, and slicing a null pointer traps even for an empty range, so
/// the empty slice is built here rather than at each caller.
pub fn argIndexed(
    argv: []const repr.Value,
    n: usize,
    fault: *Fault,
) ?[]const repr.Value {
    const x = argSlot(argv, n);
    if (repr.checkType(x, repr.Tag.array)) {
        const array = wrap.toArray(x);
        const elements = array.data orelse return &.{};
        return elements[0..@intCast(array.count)];
    } else if (repr.checkType(x, repr.Tag.tuple)) {
        const tuple = wrap.toTuple(x);
        return tuple[0..tuples.head(tuple).length];
    }
    fault.* = .{ .wrong_type = .{ .slot = n, .expected = repr.TagSet.indexed } };
    return null;
}

/// The argument at `n` as an `i32`, filling in a `.wrong_number` fault
/// otherwise.
pub fn argInteger(argv: []const repr.Value, n: usize, fault: *Fault) ?i32 {
    const x = argSlot(argv, n);
    if (!checkint(x)) {
        fault.* = .{ .wrong_number = .{ .slot = n, .expected = .s32 } };
        return null;
    }
    return wrap.toInteger(x);
}

/// The shared head of every `opt` getter: an argument past the end of the
/// list, or an explicit nil, both mean use the default.
pub fn argIsdefault(argv: []const repr.Value, n: usize) bool {
    if (n >= argv.len) return true;
    return repr.checkType(argv[n], repr.Tag.nil);
}

/// The entry `method` names in `methods`, or nothing.
pub fn argMethod(
    method: [*:0]const u8,
    methods: [*]const method_type.CMethod,
) ?*const method_type.CMethod {
    var entry = methods;
    while (entry[0].name) |name| : (entry += 1) {
        if (utils.cstrcmp(method, name) == 0) return &entry[0];
    }
    return null;
}

/// The argument at `n` as a non-negative `i32`, filling in a `.wrong_number`
/// fault otherwise.
pub fn argNat(argv: []const repr.Value, n: usize, fault: *Fault) ?i32 {
    const x = argSlot(argv, n);
    if (checkint(x)) {
        const ret = wrap.toInteger(x);
        if (ret >= 0) return ret;
    }
    fault.* = .{ .wrong_number = .{ .slot = n, .expected = .nat } };
    return null;
}

/// The entry whose name the caller should wrap as a keyword, or the
/// terminating entry, the one with a null name, where the walk runs off the
/// end. Wrapping allocates, so it is not done here.
///
/// The walk advances past the matched entry and past every entry it rejects,
/// which is what makes this an iterator rather than a lookup: a nil key starts
/// at the head, and any other key resumes after the one it names.
pub fn argNextmethod(
    methods: [*]const method_type.CMethod,
    key: repr.Value,
) [*]const method_type.CMethod {
    var entry = methods;
    if (!repr.checkType(key, repr.Tag.nil)) {
        while (entry[0].name) |name| {
            const matched = keyeq(key, name);
            entry += 1;
            if (matched) break;
        }
    }
    return entry;
}

/// Whether `x` has the tag `janet_type` and bytes equal to `cstring`.
pub fn argStrlike(janet_type: repr.Tag, x: repr.Value, cstring: [*:0]const u8) bool {
    if (repr.typeOf(x) != janet_type) return false;
    return utils.cstrcmp(wrap.toString(x), cstring) == 0;
}

/// Whether `bytes` has no zero in it, over the length the caller measured.
///
/// The view is what is searched, rather than a walk to the first terminator.
/// The two are the same question only where a terminator is known to sit at
/// `len`; for a view with no terminator, walking reads past the end and
/// reports about whatever follows it.
pub fn argZeros(bytes: []const u8, fault: *Fault) bool {
    if (std.mem.indexOfScalar(u8, bytes, 0) == null) return true;
    fault.* = .embedded_zero;
    return false;
}

/// Raises unless `argv`'s length is within `min` and `max`.
pub fn arity(argv: []const repr.Value, min: i32, max: i32) raise.Error!void {
    return checkArity(@intCast(argv.len), min, max);
}

/// The bytes of anything byte-like, or nothing.
///
/// The abstract arm runs third-party code, and this frame reports no raise at
/// all, which it can do because `abi.zig` declares `bytes` as `callconv(.c)`.
/// The arm is spelled out here rather than shared with `getBytes` because the
/// two give back different types: a slice and a view.
pub fn bytesView(str: repr.Value) ?[]const u8 {
    var fault: Fault = undefined;
    const bytes = argBytes(str, 0, &fault) orelse return null;
    return switch (bytes) {
        .view => |view| viewBytes(view),
        .abstract => |abst| viewBytes(abstractBytes(abst)),
    };
}

/// `bytesView`, published.
///
/// An out-parameter here and an optional on both sides of it. `bytesView` and
/// `dictionaryView` give back `?T`, which is the shape the header argues for;
/// a `callconv(.c)` return admits neither an optional nor a slice, so absence
/// becomes the `bool` and the value becomes the `extern` view. `module.zig`
/// rebuilds the optional, so an author sees the same shape a runtime caller
/// does and nobody outside these functions reads a zero beside an
/// out-parameter. `toIndexedAbi` has the same shape.
///
/// Neither `bytesViewAbi` nor `dictionaryViewAbi` can raise: `bytesView`'s abstract arm runs a `bytes`
/// callback, which `abi.zig` declares `callconv(.c)`, so there is no report to
/// flatten.
pub fn bytesViewAbi(x: repr.Value, out: *abi.ByteView) callconv(.c) bool {
    vm_state.requireJanetThread();
    const bytes = bytesView(x) orelse return false;
    out.* = .{ .bytes = bytes.ptr, .len = bytes.len };
    return true;
}

/// Raises unless `count` is within `min` and `max`.
pub fn checkArity(count: i32, min: i32, max: i32) raise.Error!void {
    var fault: Fault = undefined;
    if (!argArity(count, min, max, &fault)) return raiseFault(null, fault);
}

/// `checkArity`, published. It is written out rather than taken from
/// `raise.panicking`, so that the boundary's thread check is charged only to
/// the crossings a module reaches through the table. `marsh.zig`'s
/// `marshalAbi` is `raise.panicking`'s one call site.
pub fn checkArityAbi(argc: i32, min: i32, max: i32) callconv(.c) void {
    vm_state.requireJanetThread();
    return checkArity(argc, min, max) catch raise.reportToAbi(void);
}

/// The payload address where `x` is an abstract of type `at`, or null.
///
/// The non-raising probe, and it is why the kernels report rather than raise:
/// this one has to give back null rather than stop the caller.
pub fn checkabstract(x: repr.Value, at: *const abi.AbstractType) ?*anyopaque {
    var argv = [_]repr.Value{x};
    var fault: Fault = undefined;
    return argAbstract(&argv, 0, at, &fault);
}

/// Whether `x` is a double exactly representable as an `f32`.
///
/// The lower bound is `-std.math.floatMax(f32)`, the most negative finite
/// float, which is what every sibling range test's lower bound is:
/// `checkint8`'s is the minimum `i8`. The smallest positive normal float as a
/// bound would reject 0.0, every negative value and every subnormal, and say
/// that `-1.5` is not representable as a float.
///
/// The round trip determines the rest: a value inside the range that does not
/// survive the narrowing is not representable, and a NaN or an infinity fails
/// the range test before it gets there.
pub fn checkfloat(x: repr.Value) bool {
    if (!repr.checkType(x, repr.Tag.number)) return false;
    const dval = wrap.toNumber(x);
    if (!(dval >= -std.math.floatMax(f32) and dval <= std.math.floatMax(f32))) return false;
    const narrowed: f32 = @floatCast(dval);
    const back: f64 = @floatCast(narrowed);
    return dval == back;
}

/// Whether `x` is an array, a tuple or an abstract whose type has a `chunk`
/// callback.
///
/// It reads the tag and, for an abstract, its type, and calls no callback.
pub fn checkindexed(x: repr.Value) bool {
    if (repr.checkTypes(x, repr.TagSet.indexed)) return true;
    if (!repr.checkType(x, repr.Tag.abstract)) return false;
    return abi.abstractHead(wrap.toAbstract(x)).type.chunk != null;
}

/// Whether `x` is a double exactly representable as an `i32`.
pub fn checkint(x: repr.Value) bool {
    return checkNumber(i32, x);
}

/// Whether `x` is a double exactly representable as an `i16`.
pub fn checkint16(x: repr.Value) bool {
    return checkNumber(i16, x);
}

/// Whether `x` is a double exactly representable as an `i64` within 2^53. See
/// `intmax_double`.
pub fn checkint64(x: repr.Value) bool {
    if (!repr.checkType(x, repr.Tag.number)) return false;
    const dval = wrap.toNumber(x);
    if (!(dval >= intmin_double and dval <= intmax_double)) return false;
    const truncated: i64 = @intFromFloat(dval);
    const back: f64 = @floatFromInt(truncated);
    return dval == back;
}

/// Whether `x` is a double exactly representable as an `i8`.
pub fn checkint8(x: repr.Value) bool {
    return checkNumber(i8, x);
}

/// Whether `x` is a double exactly representable as a `usize`.
///
/// The range test comes before the conversion, so the conversion is always in
/// range. Its upper bound is 2 to the width of `usize`, exclusive, which is
/// exact as a double. `maxInt(usize)` is not exact on a 64-bit target: it
/// rounds up to 2^64, so an inclusive test against it admits 2^64 and the
/// conversion is then out of range. Converting first is undefined for a
/// negative or enormous double and saturates on every supported target; the
/// two orders agree on every input, negatives, NaN, 1e300 and 2^64 included,
/// because saturation and rejection agree on all of them.
pub fn checksize(x: repr.Value) bool {
    if (!repr.checkType(x, repr.Tag.number)) return false;
    const dval = wrap.toNumber(x);
    const size_hi: f64 = @floatFromInt(std.math.maxInt(usize));
    const size_limit: f64 = comptime std.math.ldexp(@as(f64, 1.0), @bitSizeOf(usize));
    if (!(dval >= 0 and dval < size_limit)) return false;
    const truncated: usize = @intFromFloat(dval);
    const back: f64 = @floatFromInt(truncated);
    if (dval != back) return false;
    // SIZE_MAX exceeds 2^53 on every 64-bit target, so this is the branch that
    // runs there; the other is for platforms with a narrower size_t.
    if (size_hi > intmax_double) return dval <= intmax_double;
    return dval <= size_hi;
}

/// Whether `x` is a double exactly representable as a `u32`.
pub fn checkuint(x: repr.Value) bool {
    return checkNumber(u32, x);
}

/// Whether `x` is a double exactly representable as a `u16`.
pub fn checkuint16(x: repr.Value) bool {
    return checkNumber(u16, x);
}

/// Whether `x` is a double exactly representable as a `u64` within 2^53. See
/// `intmax_double`.
pub fn checkuint64(x: repr.Value) bool {
    if (!repr.checkType(x, repr.Tag.number)) return false;
    const dval = wrap.toNumber(x);
    if (!(dval >= 0 and dval <= intmax_double)) return false;
    const truncated: u64 = @intFromFloat(dval);
    const back: f64 = @floatFromInt(truncated);
    return dval == back;
}

/// Whether `x` is a double exactly representable as a `u8`.
pub fn checkuint8(x: repr.Value) bool {
    return checkNumber(u8, x);
}

/// Returns the elements of an array, a tuple or an abstract with a `chunk`
/// callback, read one run at a time.
///
/// `x` is the value. This function returns null if `x` is none of the three.
/// It raises if an abstract's `length` callback raises.
///
/// See `Chunks` for how long a run stays valid.
pub fn chunks(x: repr.Value) raise.Error!?Chunks {
    if (items(x)) |elements| {
        return .{ .source = .{ .contiguous = elements }, .len = elements.len, .limit = elements.len };
    }
    if (!repr.checkType(x, repr.Tag.abstract)) return null;
    const abst = wrap.toAbstract(x);
    const at = abi.abstractHead(abst).type;
    if (at.chunk == null) return null;
    const len = try access.length(x);
    return .{
        .source = .{ .abstract = .{ .payload = abst, .at = at } },
        .len = @intCast(len),
        .limit = @intCast(len),
    };
}

/// The entries of a table or a struct, or nothing.
pub fn dictionaryView(tab: repr.Value) ?DictView {
    var argv = [_]repr.Value{tab};
    var fault: Fault = undefined;
    return argDictionary(&argv, 0, &fault);
}

/// `dictionaryView`, published. See `bytesViewAbi`.
pub fn dictionaryViewAbi(x: repr.Value, out: *abi.DictView) callconv(.c) bool {
    vm_state.requireJanetThread();
    out.* = dictionaryView(x) orelse return false;
    return true;
}

/// The end of a slice argument at `n`, folded against `length`. An absent or
/// nil slot takes `length`.
pub fn endRange(argv: []const repr.Value, n: usize, length: i32) raise.Error!i32 {
    if (argIsdefault(argv, n)) return length;
    return halfRange(argv, n, length, "end");
}

/// The method a keyword names, or nothing.
///
/// The `?Value` form of `getmethod`, and what an abstract type's `get`
/// callback gives back: absence is `null` rather than a zero beside an
/// out-parameter the caller then has to know not to read.
pub fn findMethod(key: repr.Value, methods: [*]const method_type.CMethod) ?repr.Value {
    if (!repr.checkType(key, repr.Tag.keyword)) return null;
    const found = argMethod(wrap.toKeyword(key), methods) orelse return null;
    return wrap.fromCfunction(found.cfun);
}

/// Raises unless `count` is exactly `fix`.
pub fn fixArity(count: i32, fix: i32) raise.Error!void {
    var fault: Fault = undefined;
    if (!argFixarity(count, fix, &fault)) return raiseFault(null, fault);
}

/// `fixArity`, published. See `checkArityAbi`.
pub fn fixArityAbi(argc: i32, fix: i32) callconv(.c) void {
    vm_state.requireJanetThread();
    return fixArity(argc, fix) catch raise.reportToAbi(void);
}

/// Raises unless `argv`'s length is exactly `fix`.
///
/// `fixArity` and `checkArity` keep their count-taking form beside this,
/// because the table's `fixarity(argc, fix)` is handed a count and no `argv`
/// at all: there is nothing for a slice to be made of. Two names for one
/// implementation; Zig has no overloading and this is the shape that would
/// need it.
pub fn fixarity(argv: []const repr.Value, fix: i32) raise.Error!void {
    return fixArity(@intCast(argv.len), fix);
}

/// An argument of this abstract type, already cast to its payload.
///
/// This is the shape `module.zig` gives a module author, given to the runtime
/// as well. The runtime checked the type against `at`, so the cast is the
/// checked one and not a claim the caller is making on its own.
pub inline fn getAbstract(
    comptime T: type,
    argv: []const repr.Value,
    n: usize,
    at: *const abi.AbstractType,
) raise.Error!*T {
    return @ptrCast(@alignCast((try getAbstractPtr(argv, n, at)).?));
}

/// The erased form, which is what `getAbstractAbi` publishes across the
/// boundary and what `optAbstract` and `getAbstract` are written over.
///
/// A payload address is never null, being a fixed offset into a block the
/// allocator just returned, but the published signature gives back a nullable
/// pointer and the boundary is where that stays.
pub fn getAbstractPtr(argv: []const repr.Value, n: usize, at: *const abi.AbstractType) raise.Error!?*anyopaque {
    var fault: Fault = undefined;
    return argAbstract(argv, n, at, &fault) orelse raiseFault(argv, fault);
}

/// `gather` over an argument slot, raising rather than answering null.
///
/// `argv` is the frame and `n` the slot. This function raises `panicIndexed`'s
/// refusal where the slot is not indexed, and raises where `gather` does.
///
/// The contiguous answer is taken from the slot directly rather than through
/// `gather`, which would have to build a frame of its own to ask the same
/// question.
pub fn gatherArg(argv: []const repr.Value, n: usize) raise.Error!Gathered {
    var fault: Fault = undefined;
    if (argIndexed(argv, n, &fault)) |elements| return .{ .items = elements, .copied = false };
    const x = argSlot(argv, n);
    return (try gather(x)) orelse panicIndexed(x, @intCast(n), repr.TagSet.none);
}

/// Returns every element of an indexed value in one block.
///
/// `x` is the value. This function returns null where `x` is not indexed, and
/// raises where `chunks` and `Chunks.next` do.
///
/// An array or a tuple already holds its elements in one block, so that block
/// is borrowed and nothing is allocated. An abstract's runs are copied into
/// one, which the caller releases with `Gathered.free`. See `Gathered` for
/// what a raise in between leaves behind.
///
/// A site reads runs where it can and gathers where it cannot: passing the
/// elements on as an argument list, or handing them to something outside this
/// runtime, needs one block and no iterator can give it.
///
/// A copy is not a root. It lives on the scratch heap, which the collector
/// does not walk for values, so what it holds stays alive through the value it
/// was taken from, which the caller is still holding.
pub fn gather(x: repr.Value) raise.Error!?Gathered {
    // Answered without an iterator where the value already holds one block,
    // which is what an array or a tuple is and what nearly every call is.
    if (items(x)) |elements| return .{ .items = elements, .copied = false };
    var source = (try chunks(x)) orelse return null;
    switch (source.source) {
        // Unreachable: `items` above answers for every contiguous
        // value, so `chunks` reaching here has taken the abstract arm.
        .contiguous => |elements| return .{ .items = elements, .copied = false },
        .abstract => {
            // Allocated at the length rather than grown into, the count being
            // known before the first run is taken.
            const block = gc_alloc.scratch_heap.alloc(repr.Value, source.len) catch
                fatal.outOfMemory();
            var at: usize = 0;
            while (try source.next()) |run| {
                @memcpy(block[at..][0..run.len], run);
                at += run.len;
            }
            return .{ .items = block, .copied = true };
        },
    }
}

/// The bytes of the argument at `n`, as a view.
///
/// The abstract branch runs the type's `bytes` callback, which is a function
/// pointer from a native module. It runs here rather than inside `argBytes`
/// for the reason `Bytes` gives, which no longer determines anything.
pub fn getBytes(argv: []const repr.Value, n: usize) raise.Error!abi.ByteView {
    var fault: Fault = undefined;
    const bytes = argBytes(argSlot(argv, n), n, &fault) orelse return raiseFault(argv, fault);
    return switch (bytes) {
        .view => |view| view,
        .abstract => |abst| abstractBytes(abst),
    };
}

/// The argument at `n` as a NUL-terminated C string.
///
/// The two buffer shapes are performed here rather than in the kernel: one
/// pushes a byte and one calls `gc.smalloc`, and both can raise.
pub fn getCBytes(argv: []const repr.Value, n: usize) raise.Error![*:0]const u8 {
    var fault: Fault = undefined;
    var cstr: [*:0]const u8 = undefined;
    var len: usize = undefined;
    switch (argCbytes(argv, n)) {
        .copy_buffer => {
            // Make a copy with `gc_alloc.smalloc` in the rare case we have
            // a buffer that cannot be realloced and pushing a 0 byte would
            // raise.
            const buffer = wrap.toBuffer(argSlot(argv, n));
            const count: usize = @intCast(buffer.count);
            const copy: [*]u8 = @ptrCast(gc_alloc.smalloc(count + 1));
            @memcpy(copy[0..count], buffer.slice()[0..count]);
            copy[count] = 0;
            cstr = @ptrCast(copy);
            len = @intCast(buffer.count);
        },
        .copy_view => {
            // An abstract's `bytes` callback gives back a view with no
            // terminator of its own, so the terminator is added here. A
            // zero-length view still gets the one byte, which is it.
            const view = try getBytes(argv, n);
            const copy: [*]u8 = @ptrCast(gc_alloc.smalloc(view.len + 1));
            if (view.len != 0) @memcpy(copy[0..view.len], view.bytes.?[0..view.len]);
            copy[view.len] = 0;
            cstr = @ptrCast(copy);
            len = view.len;
        },
        .terminate => {
            // Ensure trailing 0
            const buffer = wrap.toBuffer(argSlot(argv, n));
            try buffers.pushU8(buffer, 0);
            buffer.count -= 1;
            cstr = @ptrCast(buffer.data.?);
            len = buffer.count;
        },
        .view => {
            const view = try getBytes(argv, n);
            cstr = @ptrCast(view.bytes.?);
            len = view.len;
        },
    }
    if (!argZeros(cstr[0..len], &fault)) return raiseFault(argv, fault);
    return cstr;
}

/// `getCBytes`, refusing anything that is not a string.
pub fn getCString(argv: []const repr.Value, n: usize) raise.Error![*:0]const u8 {
    var fault: Fault = undefined;
    if (!argChecktype(argv, n, repr.Tag.string, repr.TagSet.one(.string), &fault)) {
        return raiseFault(argv, fault);
    }
    return getCBytes(argv, n);
}

/// The entries of the table or struct at `n`.
pub fn getDictionary(argv: []const repr.Value, n: usize) raise.Error!DictView {
    var fault: Fault = undefined;
    return argDictionary(argv, n, &fault) orelse raiseFault(argv, fault);
}

/// The bits of `flags` that the keyword at `n` names.
pub fn getFlags(argv: []const repr.Value, n: usize, flags: [*:0]const u8) raise.Error!u64 {
    const keyw = try GetKeyword.get(argv, n);
    var fault: Fault = undefined;
    return argFlags(keyw, strings.head(keyw).length, flags, &fault) orelse
        raiseFault(argv, fault);
}

/// The elements of the array or tuple at `n`.
pub fn getIndexed(argv: []const repr.Value, n: usize) raise.Error![]const repr.Value {
    var fault: Fault = undefined;
    return argIndexed(argv, n, &fault) orelse raiseFault(argv, fault);
}

/// The two ends of a slice argument sitting at `n` and `n + 1`, folded against
/// `length`.
///
/// `getSlice`'s general form, and a separate function rather than a widening
/// of it. `getSlice` is `(x &opt start end)` exactly: it checks its own arity,
/// reads the length out of `argv[0]` and starts at slot 1, which is what every
/// core builtin taking a slice needs. A module author's ends are not always in
/// those slots and the length is not always a Janet value's, a wrap width or a
/// C library's buffer size being a count of the module's own, so both are
/// parameters here.
///
/// An absent or nil slot takes the whole range, which is `startRange` and
/// `endRange`'s rule and not a new one; an end below the start is clamped up
/// to it, which is `getSlice`'s.
pub fn getRange(argv: []const repr.Value, n: usize, length: i32) raise.Error!Range {
    var out: Range = undefined;
    out.start = try startRange(argv, n, length);
    out.end = try endRange(argv, n + 1, length);
    if (out.end < out.start) out.end = out.start;
    return out;
}

/// `getRange`, published, with the argument count where the rest of the family
/// has none.
///
/// `IndexAbi` cannot generate this one. It builds the slice `argv[0..n + 1]`,
/// which is exactly the assertion a caller passing `n` makes and is long
/// enough for every getter that reads one slot. This getter reads `argv[n + 1]`
/// as well, and that slot's absence is what makes the end default, a
/// distinction only a count records.
pub fn getRangeAbi(argv: [*]const repr.Value, argc: i32, n: i32, length: i32) callconv(.c) Range {
    vm_state.requireJanetThread();
    return getRange(argv[0..@intCast(argc)], @intCast(n), length) catch raise.reportToAbi(Range);
}

/// `(x &opt start end)`, the slice argument every core builtin taking one
/// uses. It checks its own arity and reads the length out of `argv[0]`.
///
/// `access.length` can raise through this frame, which is stranded by nothing
/// at that point.
pub fn getSlice(argv: []const repr.Value) raise.Error!Range {
    try checkArity(@intCast(argv.len), 1, 3);
    var range_out: Range = undefined;
    const length = try access.length(argv[0]);
    range_out.start = try startRange(argv, 1, length);
    range_out.end = try endRange(argv, 2, length);
    if (range_out.end < range_out.start) range_out.end = range_out.start;
    return range_out;
}

/// The cfunction a method name resolves to, written into `out`, and 1 or 0 for
/// whether one was found.
pub fn getmethod(
    method: [*:0]const u8,
    methods: [*]const method_type.CMethod,
    out: *repr.Value,
) c_int {
    const found = argMethod(method, methods) orelse return 0;
    out.* = wrap.fromCfunction(found.cfun);
    return 1;
}

/// `argHalfrange`, raising rather than filling in a fault.
pub fn halfRange(argv: []const repr.Value, n: usize, length: i32, which: [*:0]const u8) raise.Error!i32 {
    var fault: Fault = undefined;
    return argHalfrange(argv, n, length, which, &fault) orelse raiseFault(argv, fault);
}

/// The run of an indexed abstract that holds `index`.
///
/// `x` is the abstract, `index` the element asked for and `len` the length it
/// reported. The run is whole rather than cut at `index`, so its `start` may
/// be below `index`.
///
/// This function raises if `x` is not an abstract with a `chunk` callback, if
/// `index` is not below `len`, or where `Chunks.next` raises for the run.
///
/// See `Chunks` for how long a run stays valid.
pub fn indexedChunk(x: repr.Value, index: usize, len: usize) raise.Error!abi.Chunk {
    if (!repr.checkType(x, repr.Tag.abstract)) {
        return pp_format.panicf("expected indexed abstract, got %v", .{x});
    }
    const abst = wrap.toAbstract(x);
    const at = abi.abstractHead(abst).type;
    if (at.chunk == null) return pp_format.panicf("expected indexed abstract, got %v", .{x});
    if (index >= len) {
        return pp_format.panicf("index %u is past the end of %t of length %u", .{
            @as(u64, index),
            x,
            @as(u64, len),
        });
    }
    return takeChunk(abst, at, index, len);
}

/// `indexedChunk`, published.
pub fn indexedChunkAbi(x: repr.Value, index: usize, len: usize) callconv(.c) abi.Chunk {
    vm_state.requireJanetThread();
    return indexedChunk(x, index, len) catch raise.reportToAbi(abi.Chunk);
}

/// The elements of an array or a tuple, or nothing.
///
/// `x` is the value. This function returns null if `x` is neither, including
/// when it is an abstract with a `chunk` callback. The slice is the value's
/// own storage. See `chunks` for reading any indexed value.
pub fn items(x: repr.Value) ?[]const repr.Value {
    var argv = [_]repr.Value{x};
    var fault: Fault = undefined;
    return argIndexed(&argv, 0, &fault);
}

/// Whether `x` is a keyword whose bytes equal `cstring`.
pub fn keyeq(x: repr.Value, cstring: [*:0]const u8) bool {
    return argStrlike(repr.Tag.keyword, x, cstring);
}

/// The keyword naming the method after `key` in `methods`, or nil at the end.
/// Wrapping the name allocates, so the kernel stops at the entry.
pub fn nextmethod(methods: [*]const method_type.CMethod, key: repr.Value) repr.Value {
    const found = argNextmethod(methods, key);
    if (found[0].name) |name| return value.fromBytes(std.mem.span(name), .keyword);
    return wrap.fromNil();
}

/// `getAbstractPtr` with a default for an absent or nil slot.
pub fn optAbstract(
    argv: []const repr.Value,
    n: usize,
    at: *const abi.AbstractType,
    dflt: ?*anyopaque,
) raise.Error!?*anyopaque {
    if (argIsdefault(argv, n)) return dflt;
    return getAbstractPtr(argv, n, at);
}

/// `getCBytes` with a default for an absent or nil slot.
pub fn optCBytes(argv: []const repr.Value, n: usize, dflt: ?[*:0]const u8) raise.Error!?[*:0]const u8 {
    if (argIsdefault(argv, n)) return dflt;
    return getCBytes(argv, n);
}

/// `getCString` with a default for an absent or nil slot.
pub fn optCString(argv: []const repr.Value, n: usize, dflt: ?[*:0]const u8) raise.Error!?[*:0]const u8 {
    if (argIsdefault(argv, n)) return dflt;
    return getCString(argv, n);
}

/// The wrong abstract type in a slot.
pub fn panicAbstract(x: repr.Value, n: i32, at: *const abi.AbstractType) raise.Error {
    return pp_format.panicf("bad slot #%d, expected %s, got %v", .{ n, at.name, x });
}

/// `panicAbstract`, published, which reports its raise rather than returning
/// it.
pub fn panicAbstractAbi(x: repr.Value, n: i32, at: *const abi.AbstractType) void {
    raise.report(panicAbstract(x, n, at));
}

/// The wrong type in a slot a site reads through the indexed protocol.
///
/// `x` is the value in slot `n`, and `also` is the other types the site
/// accepts, empty where it reads an indexed value alone. The refusal names
/// `indexed value` where `panicType` would name array and tuple.
pub fn panicIndexed(x: repr.Value, n: i32, also: repr.TagSet) raise.Error {
    return pp_format.panicf("bad slot #%d, expected %K, got %v", .{ n, also.with(repr.TagSet.indexed), x });
}

/// The wrong type in a slot.
///
/// It lives with the argument layer rather than with the rest of the panic
/// family so that the two slot diagnostics' format strings sit in one place,
/// beside the faults that build them.
pub fn panicType(x: repr.Value, n: i32, expected: repr.TagSet) raise.Error {
    return pp_format.panicf("bad slot #%d, expected %T, got %v", .{ n, expected, x });
}

/// `panicType`, published.
///
/// The abi keeps Janet's `int`. A mask bit above fifteen names no tag, so the
/// narrowing loses nothing; the internal set is sixteen bits wide and this is
/// one of the two symbols that convert.
pub fn panicTypeAbi(x: repr.Value, n: i32, expected: c_int) void {
    raise.report(panicType(x, n, repr.TagSet.fromBits(@truncate(@as(c_uint, @bitCast(expected))))));
}

/// The start of a slice argument at `n`, folded against `length`. An absent or
/// nil slot takes 0.
pub fn startRange(argv: []const repr.Value, n: usize, length: i32) raise.Error!i32 {
    if (argIsdefault(argv, n)) return 0;
    return halfRange(argv, n, length, "start");
}

/// Whether `x` is a string whose bytes equal `cstring`.
pub fn streq(x: repr.Value, cstring: [*:0]const u8) bool {
    return argStrlike(repr.Tag.string, x, cstring);
}

/// Whether `x` is a symbol whose bytes equal `cstring`.
pub fn symeq(x: repr.Value, cstring: [*:0]const u8) bool {
    return argStrlike(repr.Tag.symbol, x, cstring);
}

/// `indexedOf`, published as `to_indexed`.
///
/// An out-parameter and a `bool` for the optional, as `bytesViewAbi` uses.
/// Unlike `bytesViewAbi` and `dictionaryViewAbi`, this can raise, because an
/// abstract's `length` callback can. A raise is reported and gives back false.
pub fn toIndexedAbi(x: repr.Value, out: *abi.Indexed) callconv(.c) bool {
    vm_state.requireJanetThread();
    out.* = (indexedOf(x) catch return raise.reportToAbi(bool)) orelse return false;
    return true;
}

/// A byte view as the range it describes.
///
/// `ByteView` is `extern` because an abstract type's `bytes` callback returns
/// one across the module boundary, so its two fields cannot be a slice. Its
/// pointer is optional, and slicing a null pointer traps even for an empty
/// range, so a null pointer becomes the empty slice here rather than at each
/// call site.
pub inline fn viewBytes(view: abi.ByteView) []const u8 {
    if (view.bytes) |p| return p[0..view.len];
    return &.{};
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Runs an abstract's `bytes` callback: the one place third-party code is
/// reached for a byte view.
///
/// `abi.zig` declares `bytes` as `callconv(.c)`, so it has no way to raise,
/// which is what lets `bytesView`, a frame that reports no raise at all, reach
/// it as freely as `getBytes` does.
inline fn abstractBytes(abst: abstracts.Abstract) abi.ByteView {
    const head = abi.abstractHead(abst);
    return head.type.bytes.?(abst, head.size);
}

/// Whether `x` is a number exactly representable in `T`.
fn checkNumber(comptime T: type, x: repr.Value) bool {
    if (!repr.checkType(x, repr.Tag.number)) return false;
    return checkRange(T, wrap.toNumber(x));
}

/// Whether `dval` is exactly representable in `T`: a range test followed by a
/// round trip through the integer type, which is what rejects a fractional
/// value.
///
/// The range test always precedes the conversion, so the conversion is in
/// range whenever it runs and Zig's safety check cannot fire. NaN fails the
/// first comparison and never reaches it.
fn checkRange(comptime T: type, dval: f64) bool {
    const lo: f64 = @floatFromInt(std.math.minInt(T));
    const hi: f64 = @floatFromInt(std.math.maxInt(T));
    if (!(dval >= lo and dval <= hi)) return false;
    const truncated: T = @intFromFloat(dval);
    const back: f64 = @floatFromInt(truncated);
    return dval == back;
}

/// The indexed value at `n` as the struct the boundary accepts.
///
/// The published `getindexed`. It reads an indexed abstract as well as an
/// array or a tuple, which the runtime's own `getIndexed` does not, and raises
/// `panicIndexed`'s refusal for anything else. `module.getIndexed` builds a
/// `module.Indexed` from the result.
fn indexedAbi(argv: []const repr.Value, n: usize) raise.Error!abi.Indexed {
    var fault: Fault = undefined;
    const x = argSlot(argv, n);
    if (argIndexed(argv, n, &fault)) |elements| {
        return .{ .items = elements.ptr, .len = elements.len, .value = x };
    }
    return (try indexedOf(x)) orelse panicIndexed(x, @intCast(n), repr.TagSet.none);
}

/// An indexed value as the boundary gives it to a module, or nothing.
///
/// An array's or a tuple's elements are its own storage. An abstract's are
/// left to `indexedChunk`, so `items` is null and `len` is what its `length`
/// callback reported.
///
/// This function raises if an abstract's `length` callback raises.
fn indexedOf(x: repr.Value) raise.Error!?abi.Indexed {
    const it = (try chunks(x)) orelse return null;
    return switch (it.source) {
        .contiguous => |elements| .{ .items = elements.ptr, .len = elements.len, .value = x },
        .abstract => .{ .items = null, .len = it.len, .value = x },
    };
}

/// Builds one numeric kernel: the predicate `check`, the noun `expect`, and
/// the conversion to `T`.
///
/// The argument at `n`, or nil where the call passed no such argument.
///
/// `argv` is the frame and `n` is the slot. This function cannot fault.
///
/// Every kernel reads its argument through this, and so does a cfunction
/// that reads a slot before its arity has been checked. A cfunction may read a slot
/// before anything has checked its arity, and each of the seven `slice`
/// bindings does: `getSlice` is what checks the arity, and it runs after the
/// value has been read. A slot past the end reads as nil, so such a call
/// reports a fault naming a nil rather than reading past the end of the
/// frame.
pub inline fn argSlot(argv: []const repr.Value, n: usize) repr.Value {
    if (n >= argv.len) return wrap.fromNil();
    return argv[n];
}

/// Every width except `argInteger` converts the double; that one unwraps an
/// integer, which is a distinct operation under a tagged representation where
/// an integer is not stored as a double.
fn numberGetter(
    comptime T: type,
    comptime expect: Expect,
    comptime check: fn (repr.Value) bool,
) fn ([]const repr.Value, usize, *Fault) ?T {
    return struct {
        fn get(argv: []const repr.Value, n: usize, fault: *Fault) ?T {
            const x = argSlot(argv, n);
            if (!check(x)) {
                fault.* = .{ .wrong_number = .{ .slot = n, .expected = expect } };
                return null;
            }
            const dval = wrap.toNumber(x);
            return switch (@typeInfo(T)) {
                .float => @floatCast(dval),
                else => @intFromFloat(dval),
            };
        }
    }.get;
}

/// Turns a fault into the raise its message renders.
///
/// `argv` may be null for the arms that name no slot: the arity kinds, the
/// range kinds, the flag kind and the embedded zero all render without
/// touching the argument list, and the two arity checks are reached from a
/// count with no argument list to pass.
///
/// The three arms that do name a slot read it through `argSlot`, because the
/// fault they render can be about a slot the call never passed.
fn raiseFault(argv: ?[]const repr.Value, fault: Fault) raise.Error {
    return switch (fault) {
        .wrong_type => |f| panicType(argSlot(argv.?, f.slot), @intCast(f.slot), f.expected),
        .wrong_abstract => |f| panicAbstract(argSlot(argv.?, f.slot), @intCast(f.slot), f.at),
        .wrong_number => |f| pp_format.panicf(
            "bad slot #%d, expected %s, got %v",
            .{ @as(i32, @intCast(f.slot)), f.expected.name(), argSlot(argv.?, f.slot) },
        ),
        // The three arguments to "%d" below are `i64`. There is no va_list
        // here: "%d" renders the 64 bits its specifier asks for, so the width
        // of the arguments is the width the conversion reads, and the digits
        // are what a program sees for every index this runtime can produce.
        .range => |f| if (f.inclusive) pp_format.panicf(
            "%s index %d out of range [%d,%d]",
            .{ f.which, f.raw, f.lo, f.hi },
        ) else pp_format.panicf(
            "%s index %d out of range [%d,%d)",
            .{ f.which, f.raw, f.lo, f.hi },
        ),
        // The byte is cast to `c_char` before it is passed, so a keyword byte
        // above 127 reaches "%c" as a negative int wherever `char` is signed.
        // It makes no difference to what prints, "%c" converting its argument
        // back to an `unsigned char`, and the cast is kept because the sign is
        // visible to anything that reads the argument as an int first.
        .bad_flag => |f| pp_format.panicf(
            "unexpected flag %c, expected one of \"%s\"",
            .{ @as(c_char, @bitCast(f.byte)), f.permitted },
        ),
        .embedded_zero => raise.panic("bytes contain embedded 0s"),
        .arity_fix => |f| pp_format.panicf(
            "arity mismatch, expected %d, got %d",
            .{ f.want, f.got },
        ),
        .arity_min => |f| pp_format.panicf(
            "arity mismatch, expected at least %d, got %d",
            .{ f.want, f.got },
        ),
        .arity_max => |f| pp_format.panicf(
            "arity mismatch, expected at most %d, got %d",
            .{ f.want, f.got },
        ),
    };
}

/// The shared walk behind `argHalfrange` and `argArgindex`.
///
/// The two differ in two places and are otherwise the same: the half-range
/// folds a negative index against `length + 1` and reports a closed interval,
/// the argument index folds against `length` and reports a half-open one. Both
/// accept `length` itself.
fn range(
    argv: []const repr.Value,
    n: usize,
    length: i32,
    which: [*:0]const u8,
    fault: *Fault,
    comptime inclusive: bool,
) ?i32 {
    const raw = argInteger(argv, n, fault) orelse return null;
    const fold: i64 = if (inclusive) @as(i64, length) + 1 else @as(i64, length);
    var not_raw: i64 = raw;
    if (not_raw < 0) not_raw += fold;
    if (not_raw < 0 or not_raw > length) {
        fault.* = .{ .range = .{
            .which = which,
            .raw = raw,
            .lo = -fold,
            .hi = length,
            .inclusive = inclusive,
        } };
        return null;
    }
    return @intCast(not_raw);
}

/// Runs an abstract's `chunk` callback for `index` and checks the run.
///
/// `payload` and `at` are the abstract and its type, and `len` is the length
/// the run is checked against.
///
/// This function raises if the run does not hold `index` or reaches past
/// `len`.
///
/// It is `inline` because `Chunks.next` is, for the reason given there.
inline fn takeChunk(payload: *anyopaque, at: *const abi.AbstractType, index: usize, len: usize) raise.Error!abi.Chunk {
    const run = at.chunk.?(payload, index);
    const end = run.start +| run.len;
    if (run.start > index or end <= index or end > len) {
        return pp_format.panicf("chunk of %t does not hold index %u", .{
            wrap.fromAbstract(payload),
            @as(u64, index),
        });
    }
    return run;
}
