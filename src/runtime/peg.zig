//! Parsing expression grammars: the matcher, the compiler that feeds it, the
//! bytecode verifier that guards the unmarshalled form, and the six
//! cfunctions over all three.
//!
//! One file, because the compiler emits the bytecode the matcher runs and the
//! verifier accepts, so the three share a private instruction encoding that
//! has no other consumer. A split would put a boundary between two halves of
//! one instruction set.
//!
//! `-Dpeg` decides whether this file is compiled at all: it is the whole of
//! PEG support, types included, so a `-Dpeg=false` build has nothing here to
//! name.
//!
//! Every raise this file decides is returned as an error. Three kinds of call
//! inside the matcher raise through these frames whatever this file does:
//!
//!  - the array and buffer pushes, reached from `pushcap` on almost every
//!    capturing rule;
//!  - a call into arbitrary Janet code, which `(cmt ...)` and `(/ ...)` make
//!    with the captures so far, in the middle of the matcher's own recursion;
//!  - the allocators the compiler reaches.
//!
//! The second does not go away: a matchtime function is user code, and user
//! code raises.
//!
//! There are two recursions and two depth counters. `PegState.depth` and
//! `Builder.depth` each say at their own declaration how they differ.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const abi = @import("abi");
const abstract_type = @import("../api/abstract_type.zig");
const abstracts = @import("value/abstracts.zig");
const access = @import("value/helpers/access.zig");
const args_core = @import("args.zig");
const arrays = @import("value/arrays.zig");
const buffers = @import("value/buffers.zig");
const config = @import("config");
const constants = @import("constants");
const corefn = @import("corefn.zig");
const fatal = @import("fatal.zig");
const gc_alloc = @import("gc.zig");
const gc_mark = @import("gc/mark.zig");
const inttypes = @import("value/ints.zig");
const marsh = @import("marsh.zig");
const method_type = @import("method_type.zig");
const numscan = @import("scan.zig");
const pp_describe = @import("pp.zig");
const pp_format = @import("pp/format.zig");
const raise = @import("../api/raise.zig");
const registry = @import("registry.zig");
const repr = @import("repr");
const scratch_vector = @import("scratch_vector.zig");
const stdio = @import("stdio.zig");
const strings = @import("value/strings.zig");
const structs = @import("value/structs.zig");
const tables = @import("value/tables.zig");
const tuples = @import("value/tuples.zig");
const utils = @import("utils.zig");
const value = @import("value.zig");
const vm_entry = @import("vm/entry.zig");
const vm_state = @import("vm/state.zig");
const wrap = @import("value/helpers/wrap.zig");

// ==========================================================================
// Constants
// ==========================================================================

/// Six without `config.int_types` and eight with it, because a double capture
/// has room for 53 bits and the wider widths need a boxed integer to land in.
const max_readint_width: i32 = if (config.int_types) 8 else 6;

/// The abstract type a compiled peg is, and what `peg/match` checks its first
/// argument against before compiling it.
pub const pegType = abstract_type.define(Peg, .{
    .name = "core/peg",
    .gcmark = pegMark,
    .get = pegGetter,
    .marshal = pegMarshal,
    .unmarshal = pegUnmarshal,
    .next = pegNext,
});

/// The methods reached through `(:match peg text)` and its four siblings.
///
/// `findMethod` scans this table linearly and `nextmethod` walks it in order,
/// so the order here is the order `(keys peg)` reports, and a caller may
/// depend on it.
const peg_methods = [_]method_type.Method{
    .{ .name = "match", .cfun = cfunPegMatch },
    .{ .name = "find", .cfun = cfunPegFind },
    .{ .name = "find-all", .cfun = cfunPegFindAll },
    .{ .name = "replace", .cfun = cfunPegReplace },
    .{ .name = "replace-all", .cfun = cfunPegReplaceAll },
    .{ .name = null, .cfun = null },
};

/// Every special a grammar may name, and the compiler behind it. Several
/// spellings share a compiler, as `(<- ...)`, `(capture ...)` and
/// `(quote ...)` do.
///
/// Kept in lexical order, because `findSpecial` below binary-searches it. The
/// `comptime` block at the end of the file checks that, so a table out of
/// order fails the build rather than silently failing to find half its
/// entries.
const peg_specials = [_]SpecialPair{
    .{ .name = "!", .special = specNot },
    .{ .name = "$", .special = specPosition },
    .{ .name = "%", .special = specAccumulate },
    .{ .name = "*", .special = specSequence },
    .{ .name = "+", .special = specChoice },
    .{ .name = "->", .special = specReference },
    .{ .name = "/", .special = specReplace },
    .{ .name = "<-", .special = specCapture },
    .{ .name = ">", .special = specLook },
    .{ .name = "?", .special = specOpt },
    .{ .name = "??", .special = specDebug },
    .{ .name = "accumulate", .special = specAccumulate },
    .{ .name = "any", .special = specAny },
    .{ .name = "argument", .special = specArgument },
    .{ .name = "at-least", .special = specAtleast },
    .{ .name = "at-most", .special = specAtmost },
    .{ .name = "backmatch", .special = specBackmatch },
    .{ .name = "backref", .special = specReference },
    .{ .name = "between", .special = specBetween },
    .{ .name = "capture", .special = specCapture },
    .{ .name = "choice", .special = specChoice },
    .{ .name = "cms", .special = specMatchtimeSplice },
    .{ .name = "cmt", .special = specMatchtime },
    .{ .name = "column", .special = specColumn },
    .{ .name = "constant", .special = specConstant },
    .{ .name = "debug", .special = specDebug },
    .{ .name = "drop", .special = specDrop },
    .{ .name = "error", .special = specError },
    .{ .name = "group", .special = specGroup },
    .{ .name = "if", .special = specIf },
    .{ .name = "if-not", .special = specIfnot },
    .{ .name = "int", .special = specIntLe },
    .{ .name = "int-be", .special = specIntBe },
    .{ .name = "lenprefix", .special = specLenprefix },
    .{ .name = "line", .special = specLine },
    .{ .name = "look", .special = specLook },
    .{ .name = "not", .special = specNot },
    .{ .name = "nth", .special = specNth },
    .{ .name = "number", .special = specCaptureNumber },
    .{ .name = "only-tags", .special = specOnlyTags },
    .{ .name = "opt", .special = specOpt },
    .{ .name = "position", .special = specPosition },
    .{ .name = "quote", .special = specCapture },
    .{ .name = "range", .special = specRange },
    .{ .name = "repeat", .special = specRepeat },
    .{ .name = "replace", .special = specReplace },
    .{ .name = "sequence", .special = specSequence },
    .{ .name = "set", .special = specSet },
    .{ .name = "some", .special = specSome },
    .{ .name = "split", .special = specSplit },
    .{ .name = "sub", .special = specSub },
    .{ .name = "thru", .special = specThru },
    .{ .name = "til", .special = specTil },
    .{ .name = "to", .special = specTo },
    .{ .name = "uint", .special = specUintLe },
    .{ .name = "uint-be", .special = specUintBe },
    .{ .name = "unref", .special = specUnref },
};

/// The budget both recursions start from, which is `config.recursion_guard`.
const recursion_guard: i32 = config.recursion_guard;

// ==========================================================================
// Types
// ==========================================================================

/// The compiler's state: the grammar tables it resolves names against, the
/// two scratch vectors it emits into, and the two counters below.
const Builder = struct {
    grammar: *tables.Table,
    default_grammar: ?*tables.Table,
    tags: *tables.Table,
    constants: scratch_vector.Vector(repr.Value),
    bytecode: scratch_vector.Vector(u32),
    /// The form currently being compiled, named by every grammar error.
    form: repr.Value,
    /// The *compiler's* recursion budget, which is not reset: one grammar gets
    /// one budget. It starts at `config.recursion_guard` and post-decrements,
    /// which is the opposite of `PegState.depth`.
    depth: c_int,
    nexttag: u32,
    has_backref: bool,
};

/// A capture-stack watermark, saved so that a failed alternative can rewind to
/// it. All three fields are container counts and take their type from the
/// container.
const CapState = struct {
    cap: usize,
    tcap: usize,
    scratch: usize,
};

/// Line and column, both 1-indexed.
const LineCol = struct {
    line: i32,
    col: i32,
};

/// Whether captures are collected as values or concatenated into `scratch`.
/// `(% ...)` and `(<- ...)` swap between them and put the old mode back.
const Mode = enum(c_int) {
    normal = 0,
    accumulate = 1,
};

/// A compiled peg: the bytecode, the constants it names, and whether any rule
/// in it is a back-reference.
///
/// The two runs are named as `functions.FuncDef`'s are. A compiled peg is
/// marshalled and unmarshalled, so the widths here are observable and stay:
/// `bytecode_len` is a `usize` and `num_constants` a `u32` because that is the
/// serialised form.
pub const Peg = struct {
    bytecode: ?[*]u32 = null,
    constants: ?[*]repr.Value = null,
    bytecode_len: usize = 0,
    num_constants: u32 = 0,
    has_backref: bool = false,

    /// The two runs, named as `functions.FuncDef`'s are. A compiled peg is
    /// marshalled and unmarshalled, so the widths here are observable and
    /// stay: `bytecode_len` is a `usize` and `num_constants` a `u32` because
    /// that is the serialised form.
    pub inline fn instructions(self: anytype) utils.View(@TypeOf(self), u32) {
        if (self.bytecode_len == 0) return &.{};
        return self.bytecode.?[0..self.bytecode_len];
    }

    pub inline fn constantValues(self: anytype) utils.View(@TypeOf(self), repr.Value) {
        if (self.num_constants == 0) return &.{};
        return self.constants.?[0..self.num_constants];
    }
};

/// What the five matching cfunctions share: the compiled peg, the matcher
/// state, the text, the substitution where there is one, and the offset to
/// start at.
const PegCall = struct {
    peg: *Peg,
    s: PegState,
    bytes: abi.ByteView,
    subst: repr.Value,
    start: i32,
};

/// Captured patterns and match state. Internal to this file in C and in Zig,
/// so it is a native struct: nothing outside ever sees the layout.
const PegState = struct {
    text_start: [*]const u8,
    /// Restricted by `(sub ...)`, `(til ...)` and `(split ...)` while their
    /// inner pattern runs, and put back afterwards.
    text_end: [*]const u8,
    /// The real end of input, which the line map needs whatever `text_end`
    /// currently says.
    outer_text_end: [*]const u8,
    bytecode: [*]const u32,
    constants: [*]const repr.Value,
    captures: *arrays.Array,
    scratch: *buffers.Buffer,
    tags: *buffers.Buffer,
    tagged_captures: *arrays.Array,
    extrav: ?[*]const repr.Value,
    linemap: ?[*]i32,
    extrac: i32,
    /// The matcher's recursion budget, reset per call by `pegCallReset`, so
    /// that `peg/find` starts fresh at every offset it tries. It starts at
    /// `recursion_guard` and `down1` pre-decrements it, comparing against
    /// zero, where `Builder.depth` post-decrements. The difference stays
    /// because the off-by-one is observable in the message a deep grammar
    /// produces.
    depth: i32,
    linemaplen: i32,
    has_backref: bool,
    mode: Mode,

    inline fn ruleAt(s: *const PegState, index: u32) [*]const u32 {
        return s.bytecode + index;
    }
};

/// Space kept in the bytecode for a rule whose body is not written yet.
///
/// A special has to place its rule on the bytecode stack before compiling its
/// children, so that a child referring back to it finds an index. `Reserve`
/// keeps the builder rather than the bytecode pointer, because compiling those
/// children is what reallocates the vector.
const Reserve = struct {
    builder: *Builder,
    index: u32,
    size: i32,
};

/// What compiles one special: the builder, and the special's arguments with
/// the head of the form already taken off.
const Special = *const fn (*Builder, []const repr.Value) raise.Error!void;

/// One row of `peg_specials`: the name a grammar spells, and its compiler.
const SpecialPair = struct {
    name: [:0]const u8,
    special: Special,
};

/// What `verifyBytecode` reports.
const Verdict = struct {
    /// Whether every instruction is one the matcher can run. A rejected
    /// program's `has_backref` is not meaningful.
    ok: bool,
    /// Whether any instruction is a back-reference. The matcher reads this
    /// before it starts, since the walk itself cannot report it in time.
    has_backref: bool,
};

// ==========================================================================
// Public functions
// ==========================================================================

/// Registers the six `peg/*` cfunctions and the abstract type they return.
pub fn libPeg(env: *tables.Table) raise.Error!void {
    const entries = comptime [_]corefn.Entry{
        corefn.reg("peg/compile", &cfunPegCompile, @src(), "(peg/compile peg)", "Compiles a peg source data structure into a <core/peg>. This will speed up matching " ++
            "if the same peg will be used multiple times. `(dyn :peg-grammar)` replaces " ++
            "`default-peg-grammar` for the grammar of the peg."),
        corefn.reg("peg/match", &cfunPegMatch, @src(), "(peg/match peg text &opt start & args)", "Match a Parsing Expression Grammar to a byte string and return an array of captured values. " ++
            "Returns nil if text does not match the language defined by peg. The syntax of PEGs is documented on the Janet website."),
        corefn.reg("peg/find", &cfunPegFind, @src(), "(peg/find peg text &opt start & args)", "Find first index where the peg matches in text. Returns an integer, or nil if not found."),
        corefn.reg("peg/find-all", &cfunPegFindAll, @src(), "(peg/find-all peg text &opt start & args)", "Find all indexes where the peg matches in text. Returns an array of integers."),
        corefn.reg("peg/replace", &cfunPegReplace, @src(), "(peg/replace peg subst text &opt start & args)", "Replace first match of `peg` in `text` with `subst`, returning a new buffer. " ++
            "The peg does not need to make captures to do replacement. " ++
            "If `subst` is a function, it will be called with the " ++
            "matching text followed by any captures. " ++
            "If no matches are found, returns the input string in a new buffer."),
        corefn.reg("peg/replace-all", &cfunPegReplaceAll, @src(), "(peg/replace-all peg subst text &opt start & args)", "Replace all matches of `peg` in `text` with `subst`, returning a new buffer. " ++
            "The peg does not need to make captures to do replacement. " ++
            "If `subst` is a function, it will be called with the " ++
            "matching text followed by any captures."),
    };
    corefn.install(env, entries);
    try registry.registerAbstractType(&pegType);
}

// ==========================================================================
// Private functions
// ==========================================================================

/// Passes a non-null allocation through. Running out of memory is fatal here
/// rather than raising, so a null ends the process.
inline fn allocated(pointer: ?*anyopaque) ?*anyopaque {
    if (pointer == null) fatal.outOfMemory();
    return pointer;
}

/// A text position as an address.
///
/// Text positions are compared rather than only walked, and Zig has no
/// relational operator on pointers, so every ordering test between two cursors
/// goes through here.
inline fn at(pointer: [*]const u8) usize {
    return @intFromPtr(pointer);
}

/// Sets the bit for `ch` in a character-set bitmap.
fn bitmapSet(bitmap: *[8]u32, ch: u8) void {
    bitmap[ch >> 5] |= @as(u32, 1) << @truncate(ch & 0x1F);
}

/// Frees the builder's two scratch vectors, on the way out of a grammar error
/// as well as at the end of a successful compile.
fn builderCleanup(b: *Builder) void {
    scratch_vector.free(&b.constants);
    scratch_vector.free(&b.bytecode);
}

/// Rewinds after a failure, dropping the captures the failed branch made.
fn capLoad(s: *PegState, cs: CapState) void {
    s.scratch.count = cs.scratch;
    s.captures.count = cs.cap;
    s.tags.count = @intCast(cs.tcap);
    s.tagged_captures.count = cs.tcap;
}

/// Rewinds after a success, keeping the tagged captures so that a later
/// `(-> :tag)` can still find them.
fn capLoadKeept(s: *PegState, cs: CapState) void {
    s.scratch.count = cs.scratch;
    s.captures.count = cs.cap;
}

/// The watermark of all three capture stacks as they stand.
fn capSave(s: *PegState) CapState {
    return .{
        .scratch = s.scratch.count,
        .cap = s.captures.count,
        .tcap = s.tagged_captures.count,
    };
}

/// `(peg/compile peg)`.
fn cfunPegCompile(argv: []repr.Value) raise.Error!repr.Value {
    try args_core.fixarity(argv, 1);
    return wrap.fromAbstract(try compilePeg(argv[0]));
}

/// `(peg/find peg text &opt start & args)`, which is the first offset the
/// pattern matches at, or nil.
fn cfunPegFind(argv: []repr.Value) raise.Error!repr.Value {
    var call = try pegCfunInit(argv, false);
    var i = call.start;
    while (i < call.bytes.len) : (i += 1) {
        pegCallReset(&call);
        if (try pegRule(&call.s, call.s.bytecode, args_core.viewBytes(call.bytes).ptr + @as(usize, @intCast(i))) != null) {
            return wrap.fromInteger(i);
        }
    }
    return wrap.fromNil();
}

/// `(peg/find-all peg text &opt start & args)`.
fn cfunPegFindAll(argv: []repr.Value) raise.Error!repr.Value {
    var call = try pegCfunInit(argv, false);
    const ret = arrays.new(0);
    var i = call.start;
    while (i < call.bytes.len) : (i += 1) {
        pegCallReset(&call);
        if (try pegRule(&call.s, call.s.bytecode, args_core.viewBytes(call.bytes).ptr + @as(usize, @intCast(i))) != null) {
            try arrays.push(ret, wrap.fromInteger(i));
        }
    }
    return wrap.fromArray(ret);
}

/// `(peg/match peg text &opt start & args)`, which is the captures as an
/// array, or nil where the pattern does not match.
fn cfunPegMatch(argv: []repr.Value) raise.Error!repr.Value {
    var call = try pegCfunInit(argv, false);
    const result = try pegRule(&call.s, call.s.bytecode, args_core.viewBytes(call.bytes).ptr + @as(usize, @intCast(call.start)));
    return if (result != null) wrap.fromArray(call.s.captures) else wrap.fromNil();
}

/// `(peg/replace peg subst text &opt start & args)`.
fn cfunPegReplace(argv: []repr.Value) raise.Error!repr.Value {
    return pegReplaceGeneric(argv, true);
}

/// `(peg/replace-all peg subst text &opt start & args)`.
fn cfunPegReplaceAll(argv: []repr.Value) raise.Error!repr.Value {
    return pegReplaceGeneric(argv, false);
}

/// The compiler's entry point: a grammar as a Janet value, compiled into the
/// abstract the matcher runs. `(dyn :peg-grammar)` supplies the defaults a
/// name falls back to.
fn compilePeg(x: repr.Value) raise.Error!*Peg {
    var builder: Builder = .{
        .grammar = tables.new(0),
        .default_grammar = null,
        .tags = undefined,
        .constants = .empty,
        .bytecode = .empty,
        .nexttag = 1,
        .form = x,
        .depth = recursion_guard,
        .has_backref = false,
    };
    const default_grammarv = vm_state.dyn("peg-grammar");
    if (repr.checkType(default_grammarv, repr.Tag.table)) {
        builder.default_grammar = wrap.toTable(default_grammarv);
    }
    builder.tags = tables.new(0);
    _ = try pegCompile1(&builder, x);
    const peg = makePeg(&builder);
    builderCleanup(&builder);
    return peg;
}

/// Spends a frame of the matcher's budget. Pre-decrement and compare against
/// zero, so the budget is spent one frame before the message says it is.
inline fn down1(s: *PegState) raise.Error!void {
    s.depth -= 1;
    if (s.depth == 0) return raise.panic("peg/match recursed too deeply");
}

/// Closes a reservation with a rule of one word of body.
fn emit1(r: Reserve, op: constants.PegRule, arg: u32) void {
    const body = [_]u32{arg};
    emitRule(r, op, 1, &body);
}

/// Closes a reservation with a rule of two words of body.
fn emit2(r: Reserve, op: constants.PegRule, arg1: u32, arg2: u32) void {
    const body = [_]u32{ arg1, arg2 };
    emitRule(r, op, 2, &body);
}

/// Closes a reservation with a rule of three words of body.
fn emit3(r: Reserve, op: constants.PegRule, arg1: u32, arg2: u32, arg3: u32) void {
    const body = [_]u32{ arg1, arg2, arg3 };
    emitRule(r, op, 3, &body);
}

/// Emits a rule whose body is bytes rather than words, which is
/// `constants.PegRule.literal`. No reservation, because it has no children to
/// compile.
fn emitBytes(b: *Builder, op: constants.PegRule, bytes: []const u8) void {
    const next_rule: u32 = @intCast(b.bytecode.items.len);
    scratch_vector.push(&b.bytecode, op.number());
    scratch_vector.push(&b.bytecode, @as(u32, @intCast(bytes.len)));
    scratch_vector.pushN(&b.bytecode, 0, (bytes.len + 3) >> 2);
    if (bytes.len != 0) {
        const dest: [*]u8 = @ptrCast(b.bytecode.items.ptr + next_rule + 2);
        @memcpy(dest[0..bytes.len], bytes);
    }
}

/// Adds `val` to the constant table and returns its index.
fn emitConstant(b: *Builder, val: repr.Value) u32 {
    const cindex: u32 = @intCast(b.constants.items.len);
    scratch_vector.push(&b.constants, val);
    return cindex;
}

/// Writes a reserved rule's opcode and body, checking that the reservation was
/// the size the body needs.
fn emitRule(r: Reserve, op: constants.PegRule, n: i32, body: [*]const u32) void {
    pegAssert(r.size == n + 1, "bad reserve");
    r.builder.bytecode.items[r.index] = op.number();
    const count: usize = @intCast(n);
    @memcpy(r.builder.bytecode.items[r.index + 1 ..][0..count], body[0..count]);
}

/// The number a capture tag keyword is given, the same number for every
/// mention of it in one grammar. A tag rides in one byte of the tag buffer, so
/// a grammar may name up to 255 of them.
fn emitTag(b: *Builder, t: repr.Value) raise.Error!u32 {
    if (!wrap.isKeyword(t))
        return pegPanicf(b, "expected keyword for capture tag, got %v", .{t});
    const check = tables.get(b.tags, t);
    if (repr.checkType(check, repr.Tag.nil)) {
        const tag = b.nexttag;
        b.nexttag +%= 1;
        // A tag rides in one byte of the tag buffer, so 255 is the ceiling.
        if (tag > 255) return pegPanic(b, "too many tags - up to 255 tags are supported per peg");
        tables.put(b.tags, t, wrap.fromNumber(@floatFromInt(tag)));
        return tag;
    }
    return @intFromFloat(wrap.toNumber(check));
}

/// Prints to `(dyn :err)`, which is what `(??)` renders through.
///
/// Written out here the same way `debug.zig` writes it out, except that the
/// format is a run-time value: `(??)` picks between a coloured and a plain
/// rendering per line.
inline fn eprintf(comptime format: [:0]const u8, args: anytype) raise.Error!void {
    // `pp/format.dynprintf` can raise: `(dyn :err)` may be a Janet function,
    // and calling it can. Every caller here is raising, so the raise is
    // returned.
    return pp_format.dynprintf("err", stdio.err(), format, args);
}

/// The compiler for the special `sym` names, or nothing where the name is not
/// a special.
///
/// A binary search over `peg_specials`, written out rather than run through
/// `utils.strbinsearch`, which takes the name in the first word of each
/// element where this table is a Zig struct. The comparison is still
/// `utils.cstrcmp`'s, including its treatment of an embedded NUL.
fn findSpecial(sym: [*:0]const u8) ?Special {
    var low: usize = 0;
    var hi: usize = peg_specials.len;
    while (low < hi) {
        const mid = low + (hi - low) / 2;
        const comp = utils.cstrcmp(sym, peg_specials[mid].name.ptr);
        if (comp < 0) {
            hi = mid;
        } else if (comp > 0) {
            low = mid + 1;
        } else {
            return peg_specials[mid].special;
        }
    }
    return null;
}

/// The line and column `position` falls on, which is what `(line)` and
/// `(column)` capture.
///
/// The line map is built on first use and then kept, because `(line)` and
/// `(column)` are usually either absent from a grammar or all over it. It is
/// `gc.smalloc` scratch rather than an owned allocation, and nothing frees it:
/// the collector reclaims scratch at the next unwind, which is what makes the
/// matcher's panic paths harmless.
fn getLinecolFromPosition(s: *PegState, position: i32) LineCol {
    if (s.linemaplen < 0) {
        const outer = s.text_start[0 .. at(s.outer_text_end) - at(s.text_start)];
        var newline_count: i32 = 0;
        for (outer) |byte| {
            if (byte == '\n') newline_count += 1;
        }
        const mem: [*]i32 = @ptrCast(@alignCast(gc_alloc.smalloc(@sizeOf(i32) * @as(usize, @intCast(newline_count)))));
        var index: usize = 0;
        for (outer, 0..) |byte, offset| {
            if (byte == '\n') {
                mem[index] = @intCast(offset);
                index += 1;
            }
        }
        s.linemaplen = newline_count;
        s.linemap = mem;
    }

    // Binary search for the line, with three departures from the classic
    // shape, all of them the C original's and all of them load-bearing:
    // a newline belongs to the line before it, the not-found case needs the
    // greatest newline index below `position`, and `lo == 0` with a first
    // newline already past `position` means the first line.
    var hi = s.linemaplen;
    var lo: i32 = 0;
    while (lo + 1 < hi) {
        const mid = lo + @divTrunc(hi - lo, 2);
        if (s.linemap.?[@intCast(mid)] >= position) {
            hi = mid;
        } else {
            lo = mid;
        }
    }
    if (s.linemaplen == 0 or (lo == 0 and s.linemap.?[0] >= position)) {
        return .{ .line = 1, .col = position + 1 };
    }
    return .{ .line = lo + 2, .col = position - s.linemap.?[@intCast(lo)] };
}

/// Copies a finished `Builder` into the abstract value the matcher runs. The
/// header, the bytecode and the constants share one allocation, at the offsets
/// `pegUnmarshal` also computes.
fn makePeg(b: *Builder) *Peg {
    const bytecode_start = sizePadded(@sizeOf(Peg), @sizeOf(u32));
    const bytecode_size = b.bytecode.items.len * @sizeOf(u32);
    const constants_start = sizePadded(bytecode_start + bytecode_size, @sizeOf(repr.Value));
    const constants_size = b.constants.items.len * @sizeOf(repr.Value);
    const total_size = constants_start + constants_size;
    const mem: [*]u8 = @ptrCast(abstracts.newBytes(&pegType, total_size));
    const peg: *Peg = @ptrCast(@alignCast(mem));
    peg.bytecode = @ptrCast(@alignCast(mem + bytecode_start));
    peg.constants = @ptrCast(@alignCast(mem + constants_start));
    peg.num_constants = @intCast(b.constants.items.len);
    @memcpy(peg.bytecode.?[0..b.bytecode.items.len], b.bytecode.items);
    @memcpy(peg.constants.?[0..b.constants.items.len], b.constants.items);
    peg.bytecode_len = @intCast(b.bytecode.items.len);
    peg.has_backref = b.has_backref;
    return peg;
}

/// Whether an instruction of `n` words starting at `index` runs off the end of
/// a program of `limit` words.
///
/// `n > limit` is tested first and is not redundant. Without it the
/// subtraction underflows for a program shorter than the instruction, which is
/// the case the test exists for. `n` is 64-bit because two callers compute it
/// from an operand the stream supplied.
inline fn overflows(index: u32, limit: u32, n: u64) bool {
    return n > limit or index > limit - @as(u32, @intCast(n));
}

/// A grammar error unless the special was given between `min` and `max`
/// arguments. A negative bound is no bound.
fn pegArity(b: *Builder, arity: usize, min: i32, max: i32) raise.Error!void {
    if (min >= 0 and arity < min)
        return pegPanicf(b, "arity mismatch, expected at least %d, got %d", .{ min, @as(i64, @intCast(arity)) });
    if (max >= 0 and arity > max)
        return pegPanicf(b, "arity mismatch, expected at most %d, got %d", .{ max, @as(i64, @intCast(arity)) });
}

/// Prints and aborts. Reached only by a `reserve` that disagrees with the
/// `emit` closing it, which is a program error in this file rather than
/// anything a grammar can provoke.
inline fn pegAssert(condition: bool, message: [*:0]const u8) void {
    if (!condition) fatal.fatal(message);
}

/// Resets the matcher between two attempts at successive offsets. The
/// recursion budget is part of what is reset, so a long input does not run
/// `peg/find` out of depth.
fn pegCallReset(call: *PegCall) void {
    call.s.depth = recursion_guard;
    call.s.captures.count = 0;
    call.s.tagged_captures.count = 0;
    call.s.scratch.count = 0;
    call.s.tags.count = 0;
}

/// The state every `peg/...` call needs, including compiling the pattern where
/// it arrives as source rather than as a `<core/peg>`.
fn pegCfunInit(argv: []repr.Value, get_replace: bool) raise.Error!PegCall {
    var ret: PegCall = undefined;
    const min: usize = if (get_replace) 3 else 2;
    try args_core.arity(argv, @intCast(min), -1);
    if (repr.checkType(argv[0], repr.Tag.abstract) and
        abi.abstractHead(wrap.toAbstract(argv[0])).type == &pegType)
    {
        ret.peg = @ptrCast(@alignCast(wrap.toAbstract(argv[0])));
    } else {
        ret.peg = try compilePeg(argv[0]);
    }
    if (get_replace) {
        ret.subst = argv[1];
        ret.bytes = try args_core.getBytes(argv, 2);
    } else {
        ret.bytes = try args_core.getBytes(argv, 1);
    }
    if (argv.len > min) {
        ret.start = try args_core.getHalfRange(argv, min, @intCast(ret.bytes.len), "offset");
        ret.s.extrac = @intCast(argv.len - min - 1);
        ret.s.extrav = tuples.newFrom(argv[min + 1 ..]);
    } else {
        ret.start = 0;
        ret.s.extrac = 0;
        ret.s.extrav = null;
    }
    ret.s.mode = .normal;
    ret.s.text_start = args_core.viewBytes(ret.bytes).ptr;
    ret.s.text_end = args_core.viewBytes(ret.bytes).ptr + @as(usize, @intCast(ret.bytes.len));
    ret.s.outer_text_end = ret.s.text_end;
    ret.s.depth = recursion_guard;
    ret.s.captures = arrays.new(0);
    ret.s.tagged_captures = arrays.new(0);
    ret.s.scratch = buffers.new(10);
    ret.s.tags = buffers.new(10);
    ret.s.constants = ret.peg.constants.?;
    ret.s.bytecode = ret.peg.bytecode.?;
    ret.s.linemap = null;
    ret.s.linemaplen = -1;
    ret.s.has_backref = ret.peg.has_backref;
    return ret;
}

/// Compiles a Janet value into a rule and returns its index in the bytecode.
///
/// A keyword is resolved against the grammar tables first, then the compiled
/// form is cached, so a rule named twice is emitted once.
fn pegCompile1(b: *Builder, peg_in: repr.Value) raise.Error!u32 {
    var peg = peg_in;

    // Keep track of the form being compiled, for error messages.
    const old_form = b.form;
    const old_grammar = b.grammar;
    b.form = peg;

    // Resolve keyword references.
    var i: i32 = recursion_guard;
    var grammar: *tables.Table = old_grammar;
    while (i > 0 and wrap.isKeyword(peg)) : (i -= 1) {
        // A miss gives back a null holder and a nil value, and the nil is
        // what the test below reads; the search continues from the table it
        // started from. A separate test of the holder would be dead, because
        // the two results agree.
        const found = tables.getEx(grammar, peg);
        var next_peg = found.value;
        grammar = found.holder orelse grammar;
        if (repr.checkType(next_peg, repr.Tag.nil)) {
            next_peg = if (b.default_grammar) |defaults|
                tables.get(defaults, peg)
            else
                wrap.fromNil();
            if (repr.checkType(next_peg, repr.Tag.nil)) return pegPanic(b, "unknown rule");
        }
        peg = next_peg;
        b.form = peg;
        b.grammar = grammar;
    }
    if (i == 0) return pegPanic(b, "reference chain too deep");

    // Check the cache. A tuple gets only the local cache: in a different
    // grammar the same tuple can compile to a different rule, because
    // `(+ :a :b)` depends on whatever `:a` and `:b` are bound to there.
    const check = if (repr.checkType(peg, repr.Tag.tuple))
        tables.rawget(grammar, peg)
    else
        tables.get(grammar, peg);
    if (!repr.checkType(check, repr.Tag.nil)) {
        b.form = old_form;
        b.grammar = old_grammar;
        return @intFromFloat(wrap.toNumber(check));
    }

    // Check depth. Post-decrement, so the budget is spent one form later than
    // the matcher's pre-decrementing `down1`.
    const depth_before = b.depth;
    b.depth -= 1;
    if (depth_before == 0) return pegPanic(b, "peg grammar recursed too deeply");

    // The final rule to return.
    var rule: u32 = @intCast(b.bytecode.items.len);

    // Add to the cache. A struct or a dictionary abstract is not cached,
    // because the rule it compiles to is not settled yet, and caching its main
    // rule is just as effective.
    const copied_grammar = repr.checkType(peg, repr.Tag.@"struct") or
        (repr.checkType(peg, repr.Tag.abstract) and args_core.checkdictionary(peg));
    if (!copied_grammar) {
        var which_grammar = grammar;
        // A primitive pattern goes in the global cache, the root grammar table.
        if (!repr.checkType(peg, repr.Tag.tuple)) {
            while (which_grammar.proto) |proto| which_grammar = proto;
        }
        tables.put(which_grammar, peg, wrap.fromNumber(@floatFromInt(rule)));
    }

    switch (repr.typeOf(peg)) {
        repr.Tag.boolean => {
            const r = reserve(b, 2);
            emit1(r, if (wrap.toBoolean(peg)) constants.PegRule.nchar else constants.PegRule.notnchar, 0);
        },
        repr.Tag.number => {
            const n = try pegGetinteger(b, peg);
            const r = reserve(b, 2);
            if (n < 0) {
                emit1(r, constants.PegRule.notnchar, @bitCast(-n));
            } else {
                emit1(r, constants.PegRule.nchar, @bitCast(n));
            }
        },
        repr.Tag.string => {
            const str = wrap.toString(peg);
            emitBytes(b, constants.PegRule.literal, str[0..strings.head(str).length]);
        },
        repr.Tag.buffer => {
            const buf = wrap.toBuffer(peg);
            emitBytes(b, constants.PegRule.literal, buf.slice());
        },
        repr.Tag.table => {
            // Build a grammar table.
            const new_grammar = tables.clone(wrap.toTable(peg));
            new_grammar.proto = grammar;
            grammar = new_grammar;
            b.grammar = grammar;
            const main_rule = tables.rawget(grammar, value.fromBytes("main", .keyword));
            if (repr.checkType(main_rule, repr.Tag.nil))
                return pegPanic(b, "grammar requires :main rule");
            rule = try pegCompile1(b, main_rule);
        },
        repr.Tag.@"struct" => rule = try pegGrammar(b, peg, grammar),
        repr.Tag.abstract => {
            if (!copied_grammar) return pegPanic(b, "unexpected peg source");
            rule = try pegGrammar(b, peg, grammar);
        },
        repr.Tag.tuple => {
            const tup = wrap.toTuple(peg);
            const len = tuples.head(tup).length;
            if (len == 0) return pegPanic(b, "tuple in grammar must have non-zero length");
            if (args_core.checkint(tup[0])) {
                const n = wrap.toInteger(tup[0]);
                if (n < 0) return pegPanicf(b, "expected non-negative integer, got %d", .{n});
                try specRepeat(b, tup[0..@intCast(len)]);
            } else if (!wrap.isSymbol(tup[0])) {
                return pegPanicf(b, "expected grammar command, found %v", .{tup[0]});
            } else {
                const sym = wrap.toSymbol(tup[0]);
                const special = findSpecial(sym) orelse
                    return pegPanicf(b, "unknown special %S", .{sym});
                try special(b, tup[1..@intCast(len)]);
            }
        },
        else => return pegPanic(b, "unexpected peg source"),
    }

    // Increase depth again.
    b.depth += 1;
    b.form = old_form;
    b.grammar = old_grammar;
    return rule;
}

/// Sign-extends the low `width` bytes of `from`, the way `(int n)` reads them.
fn pegConvertU64S64(from: u64, width: i32) i64 {
    const amount: u6 = @intCast(8 * (8 - width));
    return @as(i64, @bitCast(from << amount)) >> amount;
}

/// A grammar error unless the special was given exactly `arity` arguments.
fn pegFixarity(b: *Builder, argc: usize, arity: i32) raise.Error!void {
    if (argc != arity) {
        return pegPanicf(b, "expected %d argument%s, got %d", .{
            arity,
            @as([*]const u8, if (arity == 1) "" else "s"),
            @as(i64, @intCast(argc)),
        });
    }
}

/// A special's integer argument, or a grammar error.
fn pegGetinteger(b: *Builder, x: repr.Value) raise.Error!i32 {
    if (!args_core.checkint(x))
        return pegPanicf(b, "expected integer, got %v", .{x});
    return wrap.toInteger(x);
}

/// A special's non-negative integer argument, or a grammar error.
fn pegGetnat(b: *Builder, x: repr.Value) raise.Error!i32 {
    const i = try pegGetinteger(b, x);
    if (i < 0)
        return pegPanicf(b, "expected non-negative integer, got %v", .{x});
    return i;
}

/// A special's two-character range argument, or a grammar error. An empty
/// range is refused here rather than compiled to a rule that never matches.
fn pegGetrange(b: *Builder, x: repr.Value) raise.Error![*]const u8 {
    if (!repr.checkType(x, repr.Tag.string))
        return pegPanic(b, "expected string for character range");
    const str = wrap.toString(x);
    if (strings.head(str).length != 2)
        return pegPanicf(b, "expected string to have length 2, got %v", .{x});
    if (str[1] < str[0])
        return pegPanicf(b, "range %v is empty", .{x});
    return str;
}

/// A special's character-set argument, or a grammar error.
fn pegGetset(b: *Builder, x: repr.Value) raise.Error![*]const u8 {
    if (!repr.checkType(x, repr.Tag.string))
        return pegPanic(b, "expected string for character set");
    return wrap.toString(x);
}

/// The method lookup behind `(:match peg text)` and its siblings.
fn pegGetter(_: *Peg, key: repr.Value) raise.Error!?repr.Value {
    return args_core.findMethod(key, @ptrCast(&peg_methods));
}

/// Compiles a struct or a dictionary abstract as a grammar, and returns its
/// `:main` rule.
///
/// `peg` is the grammar's source and `outer` the grammar it is inside. The
/// keyword pairs of `peg` are copied into a table whose prototype is `outer`,
/// which becomes the grammar its rules are compiled in. A table is compiled as
/// a grammar by cloning rather than through this.
fn pegGrammar(b: *Builder, peg: repr.Value, outer: *tables.Table) raise.Error!u32 {
    var pairs = (try args_core.keyvals(peg)).?;
    // Sized so that no `put` below grows it, so nothing is allocated while a
    // run is held.
    const grammar = tables.new(2 * pairs.count + 2);
    while (try pairs.next()) |kv| {
        if (wrap.isKeyword(kv.key)) tables.put(grammar, kv.key, kv.value);
    }
    grammar.proto = outer;
    b.grammar = grammar;
    const main_rule = tables.rawget(grammar, value.fromBytes("main", .keyword));
    if (repr.checkType(main_rule, repr.Tag.nil)) return pegPanic(b, "grammar requires :main rule");
    return pegCompile1(b, main_rule);
}

/// Traces the constants, which are the only Janet values a compiled peg
/// refers to.
fn pegMark(peg: *Peg, _: usize) void {
    for (peg.constantValues()) |x| gc_mark.mark(x);
}

/// Writes the two counts, then the bytecode, then the constants.
fn pegMarshal(peg: *Peg, m: *abi.Marshal) raise.Error!void {
    try marsh.marshalSize(m, peg.bytecode_len);
    try marsh.marshalInt(m, @bitCast(peg.num_constants));
    marsh.marshalAbstract(m, peg);
    for (peg.instructions()) |instruction| try marsh.marshalInt(m, @bitCast(instruction));
    for (peg.constantValues()) |x| try marsh.marshalJanet(m, x);
}

/// The iteration order behind `next` and `(keys peg)`.
fn pegNext(_: *Peg, key: repr.Value) raise.Error!repr.Value {
    return args_core.nextmethod(@ptrCast(&peg_methods), key);
}

/// Every grammar error goes through here, and each frees the two scratch
/// vectors on the way out.
fn pegPanic(b: *Builder, msg: [*]const u8) raise.Error {
    builderCleanup(b);
    return pp_format.panicf("grammar error in %p, %s", .{ b.form, msg });
}

/// `pegPanic` with a formatted message.
fn pegPanicf(b: *Builder, comptime format: [:0]const u8, args: anytype) raise.Error {
    // The formatter can raise, since `%v` runs a `tostring` callback, and
    // that raise is the real one, so it wins over the grammar error below. It
    // is also a second exit from a partially built grammar, so the vectors
    // have to come back on this path too.
    const msg = pp_format.formatc(format, args) catch |err| {
        builderCleanup(b);
        return err;
    };
    return pegPanic(b, msg);
}

/// The body of `peg/replace` and `peg/replace-all`, which differ only in
/// whether the walk stops at the first match.
fn pegReplaceGeneric(argv: []repr.Value, only_one: bool) raise.Error!repr.Value {
    var call = try pegCfunInit(argv, true);
    const ret = buffers.new(0);
    var trail: i32 = 0;
    var i = call.start;
    while (i < call.bytes.len) {
        pegCallReset(&call);
        const result = try pegRule(&call.s, call.s.bytecode, args_core.viewBytes(call.bytes).ptr + @as(usize, @intCast(i)));
        if (result) |matched| {
            if (trail < i) {
                try buffers.pushBytes(ret, args_core.viewBytes(call.bytes)[@intCast(trail)..@intCast(i)]);
                trail = i;
            }
            var nexti: i32 = @intCast(at(matched) - at(args_core.viewBytes(call.bytes).ptr));
            const subst = try registry.textSubstitution(
                &call.subst,
                args_core.viewBytes(call.bytes)[@intCast(i)..@intCast(nexti)],
                call.s.captures,
            );
            try buffers.pushBytes(ret, args_core.viewBytes(subst));
            trail = nexti;
            if (nexti == i) nexti += 1;
            i = nexti;
            if (only_one) break;
        } else {
            i += 1;
        }
    }
    if (trail < call.bytes.len) {
        try buffers.pushBytes(ret, args_core.viewBytes(call.bytes)[@intCast(trail)..@intCast(call.bytes.len)]);
    }
    return wrap.fromBuffer(ret);
}

/// Evaluates a peg rule.
///
/// `s` is the matcher state, `rule_in` the rule to run and `text_in` where to
/// run it. On a match the result is the address just past the matched text,
/// with every capture on the stacks valid; on no match it is null, possibly
/// with extra captures a successful child left behind for the caller to
/// rewind.
///
/// The `while (true)` below is a tail call written out: a rule that ends in
/// another rule assigns `rule` and `continue`s rather than recursing, which is
/// what keeps `(some ...)` over a long input off the machine stack. Every
/// other arm returns, so falling out of the `switch` is not reachable.
fn pegRule(s: *PegState, rule_in: [*]const u32, text_in: [*]const u8) raise.Error!?[*]const u8 {
    var rule = rule_in;
    var text = text_in;
    while (true) {
        switch (constants.PegRule.fromWord(rule[0])) {
            .literal => {
                const len: usize = rule[1];
                if (at(text) +% len > at(s.text_end)) return null;
                const bytes: [*]const u8 = @ptrCast(rule + 2);
                if (len != 0 and !std.mem.eql(u8, text[0..len], bytes[0..len])) return null;
                return skip(text, len);
            },

            .debug => {
                var buffer: [32]u8 = @splat(0);
                const remaining = at(s.outer_text_end) - at(text);
                const shown = @min(remaining, 31);
                @memcpy(buffer[0..shown], text[0..shown]);
                try eprintf("?? at [%s] (index %d)\n", .{
                    @as([*]const u8, &buffer),
                    @as(i32, @intCast(at(text) - at(s.text_start))),
                });
                const has_color = repr.truthy(vm_state.dyn("err-color"));
                if (s.scratch.count != 0) {
                    try eprintf("accumulate buffer: %v\n", .{wrap.fromBuffer(s.scratch)});
                }
                if (s.captures.count != 0) {
                    try eprintf("stack [%d]:\n", .{@as(i64, @intCast(s.captures.count))});
                    for (s.captures.slice(), 0..) |capture, index| {
                        // Two calls rather than one: the format string is
                        // `comptime`, so a runtime `has_color` cannot choose
                        // between two of them.
                        const i: i32 = @intCast(index);
                        if (has_color)
                            try eprintf("  [%d]: %M\n", .{ i, capture })
                        else
                            try eprintf("  [%d]: %m\n", .{ i, capture });
                    }
                }
                if (s.tagged_captures.count != 0) {
                    try eprintf("tag stack [%d]:\n", .{@as(i64, @intCast(s.tagged_captures.count))});
                    for (s.tagged_captures.slice(), 0..) |capture, index| {
                        const i: i32 = @intCast(index);
                        const tag = @as(i32, s.tags.slice()[index]);
                        if (has_color)
                            try eprintf("  [%d] tag=%d: %M\n", .{ i, tag, capture })
                        else
                            try eprintf("  [%d] tag=%d: %m\n", .{ i, tag, capture });
                    }
                }
                return text;
            },

            .nchar => {
                const n: usize = rule[1];
                return if (at(text) +% n > at(s.text_end)) null else skip(text, n);
            },

            .notnchar => {
                const n: usize = rule[1];
                return if (at(text) +% n > at(s.text_end)) text else null;
            },

            .range => {
                const lo: u8 = @truncate(rule[1]);
                const hi: u8 = @truncate(rule[1] >> 16);
                if (at(text) < at(s.text_end) and text[0] >= lo and text[0] <= hi) return text + 1;
                return null;
            },

            .set => {
                if (at(text) >= at(s.text_end)) return null;
                const word = rule[1 + (text[0] >> 5)];
                const mask = @as(u32, 1) << @truncate(text[0] & 0x1F);
                return if (word & mask != 0) text + 1 else null;
            },

            .look => {
                const offset: i32 = @bitCast(rule[1]);
                const looked = shift(text, offset);
                if (at(looked) < at(s.text_start) or at(looked) > at(s.text_end)) return null;
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[2]), looked);
                up1(s);
                return if (result != null) text else null;
            },

            .choice => {
                const len = rule[1];
                const args = rule + 2;
                if (len == 0) return null;
                try down1(s);
                const cs = capSave(s);
                for (args[0 .. len - 1]) |alternative| {
                    if (try pegRule(s, s.ruleAt(alternative), text)) |result| {
                        up1(s);
                        return result;
                    }
                    capLoad(s, cs);
                }
                up1(s);
                rule = s.ruleAt(args[len - 1]);
                continue;
            },

            .sequence => {
                const len = rule[1];
                const args = rule + 2;
                if (len == 0) return text;
                try down1(s);
                var cursor: ?[*]const u8 = text;
                var i: u32 = 0;
                while (i < len - 1) : (i += 1) {
                    const from = cursor orelse break;
                    cursor = try pegRule(s, s.ruleAt(args[i]), from);
                }
                up1(s);
                text = cursor orelse return null;
                rule = s.ruleAt(args[len - 1]);
                continue;
            },

            .@"if" => {
                const rule_a = s.ruleAt(rule[1]);
                const rule_b = s.ruleAt(rule[2]);
                try down1(s);
                const result = try pegRule(s, rule_a, text);
                up1(s);
                if (result == null) return null;
                rule = rule_b;
                continue;
            },

            .ifnot => {
                const rule_a = s.ruleAt(rule[1]);
                const rule_b = s.ruleAt(rule[2]);
                try down1(s);
                const cs = capSave(s);
                const result = try pegRule(s, rule_a, text);
                if (result != null) {
                    up1(s);
                    return null;
                }
                capLoad(s, cs);
                up1(s);
                rule = rule_b;
                continue;
            },

            .not => {
                const rule_a = s.ruleAt(rule[1]);
                try down1(s);
                const cs = capSave(s);
                const result = try pegRule(s, rule_a, text);
                if (result != null) {
                    up1(s);
                    return null;
                }
                capLoad(s, cs);
                up1(s);
                return text;
            },

            .thru, constants.PegRule.to => {
                const rule_a = s.ruleAt(rule[1]);
                var next_text: ?[*]const u8 = null;
                const cs = capSave(s);
                try down1(s);
                while (at(text) <= at(s.text_end)) {
                    const cs2 = capSave(s);
                    next_text = try pegRule(s, rule_a, text);
                    if (next_text != null) {
                        if (constants.PegRule.fromWord(rule[0]) == .to) capLoad(s, cs2);
                        break;
                    }
                    capLoad(s, cs2);
                    text += 1;
                }
                up1(s);
                if (at(text) > at(s.text_end)) {
                    capLoad(s, cs);
                    return null;
                }
                return if (constants.PegRule.fromWord(rule[0]) == .to) text else next_text;
            },

            .between => {
                const lo = rule[1];
                const hi = rule[2];
                const rule_a = s.ruleAt(rule[3]);
                var captured: u32 = 0;
                const cs = capSave(s);
                try down1(s);
                while (captured < hi) {
                    const cs2 = capSave(s);
                    const next_text = try pegRule(s, rule_a, text) orelse {
                        capLoad(s, cs2);
                        break;
                    };
                    // What stops `(any "")` spinning: a rule that matches
                    // nothing counts once and then ends the loop.
                    if (next_text == text and hi == std.math.maxInt(u32)) {
                        capLoad(s, cs2);
                        break;
                    }
                    captured += 1;
                    text = next_text;
                }
                up1(s);
                if (captured < lo) {
                    capLoad(s, cs);
                    return null;
                }
                return text;
            },

            .gettag => {
                const search = rule[1];
                const tag = rule[2];
                var i: i32 = @as(i32, @intCast(s.tags.count)) - 1;
                while (i >= 0) : (i -= 1) {
                    if (@as(u32, s.tags.slice()[@intCast(i)]) == search) {
                        try pushcap(s, s.tagged_captures.slice()[@intCast(i)], tag);
                        return text;
                    }
                }
                return null;
            },

            .position => {
                try pushcap(s, wrap.fromNumber(@floatFromInt(at(text) - at(s.text_start))), rule[1]);
                return text;
            },

            .line => {
                const lc = getLinecolFromPosition(s, @intCast(at(text) - at(s.text_start)));
                try pushcap(s, wrap.fromNumber(@floatFromInt(lc.line)), rule[1]);
                return text;
            },

            .column => {
                const lc = getLinecolFromPosition(s, @intCast(at(text) - at(s.text_start)));
                try pushcap(s, wrap.fromNumber(@floatFromInt(lc.col)), rule[1]);
                return text;
            },

            .argument => {
                // Signed, and both ends are tested. `(argument n)` takes a
                // non-negative index from the compiler, but this word may have
                // come off a stream instead, and `extrav` is null whenever
                // `peg/match` was called with no extra arguments at all.
                const index: i32 = @bitCast(rule[1]);
                const capture = if (index < 0 or index >= s.extrac)
                    wrap.fromNil()
                else
                    s.extrav.?[@intCast(index)];
                try pushcap(s, capture, rule[2]);
                return text;
            },

            .constant => {
                try pushcap(s, s.constants[rule[1]], rule[2]);
                return text;
            },

            .capture => {
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[1]), text);
                up1(s);
                const matched = result orelse return null;
                const len: i32 = @intCast(at(matched) - at(text));
                // Specialized pushcap - avoid intermediate string creation.
                if (!s.has_backref and s.mode == .accumulate) {
                    try buffers.pushBytes(s.scratch, text[0..@intCast(len)]);
                } else {
                    try pushcap(s, value.fromBytes(text[0..@intCast(len)], .string), rule[2]);
                }
                return matched;
            },

            .capture_num => {
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[1]), text);
                up1(s);
                const matched = result orelse return null;
                const len: i32 = @intCast(at(matched) - at(text));
                const base: i32 = @bitCast(rule[2]);
                const x = numscan.scanNumberBase(text, len, base) orelse return null;
                if (!s.has_backref and s.mode == .accumulate) {
                    try buffers.pushBytes(s.scratch, text[0..@intCast(len)]);
                } else {
                    try pushcap(s, wrap.fromNumber(x), rule[3]);
                }
                return matched;
            },

            .accumulate => {
                const tag = rule[2];
                const oldmode = s.mode;
                if (tag == 0 and oldmode == .accumulate) {
                    rule = s.ruleAt(rule[1]);
                    continue;
                }
                const cs = capSave(s);
                s.mode = .accumulate;
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[1]), text);
                up1(s);
                s.mode = oldmode;
                const matched = result orelse return null;
                const cap = value.fromBytes(s.scratch.slice()[@intCast(cs.scratch)..@intCast(s.scratch.count)], .string);
                capLoadKeept(s, cs);
                try pushcap(s, cap, tag);
                return matched;
            },

            .drop => {
                const cs = capSave(s);
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[1]), text);
                up1(s);
                const matched = result orelse return null;
                capLoad(s, cs);
                return matched;
            },

            .only_tags => {
                const cs = capSave(s);
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[1]), text);
                up1(s);
                const matched = result orelse return null;
                capLoadKeept(s, cs);
                return matched;
            },

            .group => {
                const tag = rule[2];
                const oldmode = s.mode;
                const cs = capSave(s);
                s.mode = .normal;
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[1]), text);
                up1(s);
                s.mode = oldmode;
                const matched = result orelse return null;
                const taken = s.captures.slice()[@intCast(cs.cap)..];
                const sub_captures = arrays.new(taken.len);
                @memcpy(sub_captures.reserved()[0..taken.len], taken);
                sub_captures.count = taken.len;
                capLoadKeept(s, cs);
                try pushcap(s, wrap.fromArray(sub_captures), tag);
                return matched;
            },

            .nth => {
                var nth = rule[1];
                if (nth > std.math.maxInt(i32)) nth = std.math.maxInt(i32);
                const tag = rule[3];
                const oldmode = s.mode;
                const cs = capSave(s);
                s.mode = .normal;
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[2]), text);
                up1(s);
                s.mode = oldmode;
                const matched = result orelse return null;
                const num_sub_captures: i32 = @intCast(s.captures.count - cs.cap);
                if (num_sub_captures <= @as(i32, @intCast(nth))) return null;
                const cap = s.captures.slice()[cs.cap + nth];
                capLoadKeept(s, cs);
                try pushcap(s, cap, tag);
                return matched;
            },

            .sub => {
                const text_start = text;
                const rule_window = s.ruleAt(rule[1]);
                const rule_subpattern = s.ruleAt(rule[2]);
                try down1(s);
                const window = try pegRule(s, rule_window, text);
                up1(s);
                const window_end = window orelse return null;
                const saved_end = s.text_end;
                s.text_end = window_end;
                try down1(s);
                const next_text = try pegRule(s, rule_subpattern, text_start);
                up1(s);
                s.text_end = saved_end;
                if (next_text == null) return null;
                return window_end;
            },

            .til => {
                const rule_terminus = s.ruleAt(rule[1]);
                const rule_subpattern = s.ruleAt(rule[2]);
                var terminus_start = text;
                var terminus_end: ?[*]const u8 = null;
                try down1(s);
                while (at(terminus_start) <= at(s.text_end)) {
                    const cs2 = capSave(s);
                    terminus_end = try pegRule(s, rule_terminus, terminus_start);
                    capLoad(s, cs2);
                    if (terminus_end != null) break;
                    terminus_start += 1;
                }
                up1(s);
                const found = terminus_end orelse return null;
                const saved_end = s.text_end;
                s.text_end = terminus_start;
                try down1(s);
                const matched = try pegRule(s, rule_subpattern, text);
                up1(s);
                s.text_end = saved_end;
                if (matched == null) return null;
                return found;
            },

            .split => {
                const saved_end = s.text_end;
                const rule_separator = s.ruleAt(rule[1]);
                const rule_subpattern = s.ruleAt(rule[2]);
                var chunk_start = text;
                var chunk_end: [*]const u8 = text;
                while (at(text) <= at(saved_end)) {
                    // Find the next separator, or the end of the text.
                    const cs = capSave(s);
                    try down1(s);
                    while (at(text) <= at(saved_end)) {
                        chunk_end = text;
                        const check = try pegRule(s, rule_separator, text);
                        capLoad(s, cs);
                        if (check) |next| {
                            text = next;
                            break;
                        }
                        text += 1;
                    }
                    up1(s);

                    // Match between splits.
                    s.text_end = chunk_end;
                    try down1(s);
                    const subpattern_end = try pegRule(s, rule_subpattern, chunk_start);
                    up1(s);
                    s.text_end = saved_end;
                    if (subpattern_end == null) return null;

                    // Ensure forward progress.
                    if (text == chunk_start) return null;
                    chunk_start = text;
                }
                s.text_end = saved_end;
                return s.text_end;
            },

            .replace, constants.PegRule.matchsplice, constants.PegRule.matchtime => {
                const tag = rule[3];
                const oldmode = s.mode;
                const cs = capSave(s);
                s.mode = .normal;
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[1]), text);
                up1(s);
                s.mode = oldmode;
                const matched = result orelse return null;

                var cap = wrap.fromNil();
                const constant = s.constants[rule[2]];
                switch (repr.typeOf(constant)) {
                    repr.Tag.@"struct" => {
                        if (s.captures.count != 0) {
                            cap = structs.get(
                                wrap.toStruct(constant),
                                s.captures.slice()[@intCast(s.captures.count - 1)],
                            );
                        }
                    },
                    repr.Tag.table => {
                        if (s.captures.count != 0) {
                            cap = tables.get(
                                wrap.toTable(constant),
                                s.captures.slice()[@intCast(s.captures.count - 1)],
                            );
                        }
                    },
                    // A dictionary abstract is looked up as a table is, and any
                    // other abstract is the replacement itself.
                    repr.Tag.abstract => {
                        if (!args_core.checkdictionary(constant)) {
                            cap = constant;
                        } else if (s.captures.count != 0) {
                            cap = try access.get(
                                constant,
                                s.captures.slice()[@intCast(s.captures.count - 1)],
                            );
                        }
                    },
                    // Both of these run arbitrary Janet code in the middle of
                    // the matcher's recursion.
                    repr.Tag.cfunction => {
                        cap = try raise.cfunction(wrap.toCfunction(constant))(
                            s.captures.slice()[@intCast(cs.cap)..],
                        );
                    },
                    repr.Tag.function => {
                        cap = try vm_entry.call(
                            wrap.toFunction(constant),
                            s.captures.slice()[@intCast(cs.cap)..],
                        );
                    },
                    else => cap = constant,
                }
                capLoadKeept(s, cs);
                if (constants.PegRule.fromWord(rule[0]) != .replace and !repr.truthy(cap)) return null;
                // Gathered rather than read a run at a time, because
                // `pushcap` grows the capture array: a run is good only until
                // the next call that can allocate, and every element here is
                // pushed through one. An array or a tuple is borrowed, so the
                // rule this serves pays nothing it did not pay before.
                var elements: ?args_core.Gathered = if (constants.PegRule.fromWord(rule[0]) == .matchsplice)
                    try args_core.gather(cap)
                else
                    null;
                if (elements) |*gathered| {
                    for (gathered.items) |element| try pushcap(s, element, tag);
                    gathered.free();
                } else {
                    try pushcap(s, cap, tag);
                }
                return matched;
            },

            .@"error" => {
                const oldmode = s.mode;
                s.mode = .normal;
                const old_cap = s.captures.count;
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[1]), text);
                up1(s);
                s.mode = oldmode;
                if (result == null) return null;
                if (s.captures.count > old_cap) {
                    return raise.panicv(s.captures.slice()[@intCast(s.captures.count - 1)]);
                }
                const start: i32 = @intCast(at(text) - at(s.text_start));
                const lc = getLinecolFromPosition(s, start);
                return pp_format.panicf("match error at line %d, column %d", .{ lc.line, lc.col });
            },

            .backmatch => {
                const search = rule[1];
                var i: i32 = @as(i32, @intCast(s.tags.count)) - 1;
                while (i >= 0) : (i -= 1) {
                    if (@as(u32, s.tags.slice()[@intCast(i)]) != search) continue;
                    const capture = s.tagged_captures.slice()[@intCast(i)];
                    if (!repr.checkType(capture, repr.Tag.string)) return null;
                    const bytes = wrap.toString(capture);
                    const len: usize = strings.head(bytes).length;
                    if (at(text) +% len > at(s.text_end)) return null;
                    if (len != 0 and !std.mem.eql(u8, text[0..len], bytes[0..len])) return null;
                    return skip(text, len);
                }
                return null;
            },

            .lenprefix => {
                const oldmode = s.mode;
                s.mode = .normal;
                const cs = capSave(s);
                try down1(s);
                const length_match = try pegRule(s, s.ruleAt(rule[1]), text);
                up1(s);
                // The mode and the captures go back before every exit, this
                // one included: a caller that put the matcher into accumulate
                // mode gets it back that way whether the length pattern
                // matched or not.
                s.mode = oldmode;
                var next_text = length_match orelse {
                    capLoad(s, cs);
                    return null;
                };
                const num_sub_captures: i32 = @intCast(s.captures.count - cs.cap);
                if (num_sub_captures <= 0) {
                    capLoad(s, cs);
                    return null;
                }
                const lencap = s.captures.slice()[@intCast(cs.cap)];
                if (!args_core.checkint(lencap)) {
                    capLoad(s, cs);
                    return null;
                }
                // Signed on purpose. A length pattern can capture a negative,
                // and a negative repeat count runs the body zero times, which
                // is what a program sees. Unsigned it would wrap and loop for
                // ever.
                const nrep = wrap.toInteger(lencap);
                // Drop the captures the length pattern made.
                capLoad(s, cs);
                var i: i32 = 0;
                while (i < nrep) : (i += 1) {
                    try down1(s);
                    const stepped = try pegRule(s, s.ruleAt(rule[2]), next_text);
                    up1(s);
                    next_text = stepped orelse {
                        capLoad(s, cs);
                        return null;
                    };
                }
                return next_text;
            },

            .readint => {
                const tag = rule[2];
                const signedness = rule[1] & 0x10;
                const endianness = rule[1] & 0x20;
                const width: i32 = @intCast(rule[1] & 0xF);
                const uwidth: usize = @intCast(width);
                if (at(text) +% uwidth > at(s.text_end)) return null;
                var accum: u64 = 0;
                if (endianness != 0) {
                    for (text[0..uwidth]) |byte| accum = (accum << 8) | byte;
                } else {
                    var i = width - 1;
                    while (i >= 0) : (i -= 1) accum = (accum << 8) | text[@intCast(i)];
                }

                // Above six bytes a `double` capture would lose precision, so
                // the wider widths need a boxed integer to land in and are
                // only reachable when `config.int_types` provides one.
                var capture_value: repr.Value = undefined;
                if (config.int_types and width > 6) {
                    capture_value = if (signedness != 0)
                        inttypes.wrapS64(pegConvertU64S64(accum, width))
                    else
                        inttypes.wrapU64(accum);
                } else {
                    const double_value: f64 = if (signedness != 0)
                        @floatFromInt(pegConvertU64S64(accum, width))
                    else
                        @floatFromInt(accum);
                    capture_value = wrap.fromNumber(double_value);
                }

                try pushcap(s, capture_value, tag);
                return skip(text, uwidth);
            },

            .unref => {
                const tcap = s.tags.count;
                try down1(s);
                const result = try pegRule(s, s.ruleAt(rule[1]), text);
                up1(s);
                const matched = result orelse return null;
                const final_tcap = s.tags.count;
                // Truncate the tagged captures to exclude the given tag. With
                // no tag, drop all of them.
                var w = tcap;
                if (rule[2] != 0) {
                    for (tcap..final_tcap) |i| {
                        if (s.tags.slice()[i] != @as(u8, @truncate(rule[2]))) {
                            s.tags.slice()[w] = s.tags.slice()[i];
                            s.tagged_captures.slice()[w] = s.tagged_captures.slice()[i];
                            w += 1;
                        }
                    }
                }
                s.tags.count = w;
                s.tagged_captures.count = w;
                return matched;
            },

            else => return raise.panic("unexpected opcode"),
        }
    }
}

/// Reads a compiled peg back from a stream, and verifies its bytecode before
/// returning it.
fn pegUnmarshal(u: *abi.Unmarshal) raise.Error!*Peg {
    const bytecode_len = try marsh.unmarshalSize(u);
    const num_constants: u32 = @bitCast(try marsh.unmarshalInt(u));

    // The two counts together are bounded by the bytes left in the stream,
    // and that is what keeps the size arithmetic below honest. One instruction
    // word is at least one byte on the wire, and so is one constant, since a
    // constant begins with a lead byte; both are read from the same bytes, so
    // a stream promising `w` words and `c` constants has at least `w + c`
    // bytes remaining. The test is written as a subtraction rather than as a
    // sum because `bytecode_len` is a `usize` off the wire and the sum of the
    // two can wrap.
    //
    // Without the bound the product feeding `total_size` wraps: a
    // `bytecode_len` above 2^62 wraps `bytecode_size`, and on a 32-bit target
    // a `num_constants` of 2^29 wraps the constants term to zero. Either way
    // the abstract comes out the size of its header and the loop that fills it
    // writes past the allocation until the stream runs out.
    //
    // It is a denial-of-service bound too: where the product does not wrap,
    // `num_constants` is a u32 the stream chooses freely, so seventeen bytes
    // of input would otherwise ask for 2^32 values: 32 GiB, or 64 GiB where a
    // `Value` is sixteen bytes wide. With the bound the reservation is
    // linear in the bytes actually supplied.
    const remaining = marsh.unmarshalRemaining(u);
    if (bytecode_len > remaining or num_constants > remaining - bytecode_len) {
        return raise.panic("invalid peg bytecode");
    }

    // Offsets, which have to match `makePeg`.
    const bytecode_start = sizePadded(@sizeOf(Peg), @sizeOf(u32));
    const bytecode_size = bytecode_len * @sizeOf(u32);
    const constants_start = sizePadded(bytecode_start + bytecode_size, @sizeOf(repr.Value));
    const total_size = constants_start + @sizeOf(repr.Value) * @as(usize, num_constants);

    const mem: [*]u8 = @ptrCast(try marsh.unmarshalAbstract(u, total_size));
    const peg: *Peg = @ptrCast(@alignCast(mem));
    const bytecode: [*]u32 = @ptrCast(@alignCast(mem + bytecode_start));
    const consts: [*]repr.Value = @ptrCast(@alignCast(mem + constants_start));
    peg.bytecode = null;
    peg.constants = null;
    peg.bytecode_len = bytecode_len;
    peg.num_constants = num_constants;

    for (bytecode[0..peg.bytecode_len]) |*word| word.* = @bitCast(try marsh.unmarshalInt(u));
    for (consts[0..peg.num_constants]) |*constant| constant.* = try marsh.unmarshalJanet(u);

    // After here, nothing raises except the rejection at the end.

    // The low thirty-two bits of a length the stream chose, whatever `usize`
    // is on this target. The bound checked above is what makes the truncation
    // safe.
    const blen: u32 = @truncate(peg.bytecode_len);
    const clen: u32 = peg.num_constants;
    const op_flags: [*]u8 = @ptrCast(allocated(utils.calloc(1, blen)).?);
    defer utils.free(op_flags);

    const verdict = verifyBytecode(bytecode, blen, clen, op_flags);
    if (!verdict.ok) {
        return raise.panic("invalid peg bytecode");
    }

    peg.bytecode = bytecode;
    peg.constants = consts;
    peg.has_backref = verdict.has_backref;
    return peg;
}

/// Adds a capture, to whichever of the three stacks the current mode and the
/// grammar's use of backrefs call for.
fn pushcap(s: *PegState, capture: repr.Value, tag: u32) raise.Error!void {
    if (s.mode == .accumulate) try pp_describe.toStringB(s.scratch, capture);
    if (s.mode == .normal) try arrays.push(s.captures, capture);
    if (s.has_backref) {
        try arrays.push(s.tagged_captures, capture);
        try buffers.pushU8(s.tags, @truncate(tag));
    }
}

/// Takes `size` words of bytecode for a rule an `emit` will fill in.
fn reserve(b: *Builder, size: i32) Reserve {
    const r: Reserve = .{
        .builder = b,
        .index = @intCast(b.bytecode.items.len),
        .size = size,
    };
    scratch_vector.pushN(&b.bytecode, 0, @intCast(size));
    return r;
}

/// `text + n` for a signed `n`, which is the offset `(> n rule)` takes.
inline fn shift(pointer: [*]const u8, delta: i32) [*]const u8 {
    return @ptrFromInt(@intFromPtr(pointer) +% @as(usize, @bitCast(@as(isize, delta))));
}

/// Rounds `offset` up so that an array of `size`-byte elements placed there is
/// aligned, which is what lets the header, the bytecode and the constants
/// share one allocation.
fn sizePadded(offset: usize, size: usize) usize {
    const x = size + offset - 1;
    return x - (x % size);
}

/// `text + n` for an `n` that came out of bytecode. Wrapping rather than
/// checked, because that is what C's pointer arithmetic does on a 32-bit host,
/// and because the verifier rather than this arithmetic is what keeps `n`
/// sane.
inline fn skip(pointer: [*]const u8, delta: usize) [*]const u8 {
    return @ptrFromInt(@intFromPtr(pointer) +% delta);
}

/// `(% patt)` and `(accumulate patt)`.
fn specAccumulate(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specCap1(b, argv, constants.PegRule.accumulate);
}

/// `(any patt)`.
fn specAny(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specRepeater(b, argv, 0);
}

/// `(argument n &opt tag)`, which captures one of the extra arguments
/// `peg/match` was given.
fn specArgument(b: *Builder, argv: []const repr.Value) raise.Error!void {
    try pegArity(b, argv.len, 1, 2);
    const r = reserve(b, 3);
    const tag: u32 = if (argv.len == 2) try emitTag(b, argv[1]) else 0;
    const index = try pegGetnat(b, argv[0]);
    emit2(r, constants.PegRule.argument, @bitCast(index), tag);
}

/// `(at-least n patt)`.
fn specAtleast(b: *Builder, argv: []const repr.Value) raise.Error!void {
    try pegFixarity(b, argv.len, 2);
    const r = reserve(b, 4);
    const n = try pegGetnat(b, argv[0]);
    const subrule = try pegCompile1(b, argv[1]);
    emit3(r, constants.PegRule.between, @bitCast(n), std.math.maxInt(u32), subrule);
}

/// `(at-most n patt)`.
fn specAtmost(b: *Builder, argv: []const repr.Value) raise.Error!void {
    try pegFixarity(b, argv.len, 2);
    const r = reserve(b, 4);
    const n = try pegGetnat(b, argv[0]);
    const subrule = try pegCompile1(b, argv[1]);
    emit3(r, constants.PegRule.between, 0, @bitCast(n), subrule);
}

/// `(backmatch &opt tag)`, which matches the text of a tagged capture.
fn specBackmatch(b: *Builder, argv: []const repr.Value) raise.Error!void {
    b.has_backref = true;
    return specTag1(b, argv, constants.PegRule.backmatch);
}

/// `(between lo hi patt)`, which every other repetition special compiles to.
fn specBetween(b: *Builder, argv: []const repr.Value) raise.Error!void {
    try pegFixarity(b, argv.len, 3);
    const r = reserve(b, 4);
    const lo = try pegGetnat(b, argv[0]);
    const hi = try pegGetnat(b, argv[1]);
    const subrule = try pegCompile1(b, argv[2]);
    emit3(r, constants.PegRule.between, @bitCast(lo), @bitCast(hi), subrule);
}

/// The two-rule branching specials, whose rule is `[rule, rule]` and whose
/// first rule decides whether the second runs.
fn specBranch(b: *Builder, argv: []const repr.Value, op: constants.PegRule) raise.Error!void {
    try pegFixarity(b, argv.len, 2);
    const r = reserve(b, 3);
    const rule_a = try pegCompile1(b, argv[0]);
    const rule_b = try pegCompile1(b, argv[1]);
    emit2(r, op, rule_a, rule_b);
}

/// The capturing specials, whose rule is `[rule, tag]`.
fn specCap1(b: *Builder, argv: []const repr.Value, op: constants.PegRule) raise.Error!void {
    try pegArity(b, argv.len, 1, 2);
    const r = reserve(b, 3);
    const tag: u32 = if (argv.len == 2) try emitTag(b, argv[1]) else 0;
    const rule = try pegCompile1(b, argv[0]);
    emit2(r, op, rule, tag);
}

/// `(<- patt)`, `(capture patt)` and `(quote patt)`.
fn specCapture(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specCap1(b, argv, constants.PegRule.capture);
}

/// `(number patt &opt base tag)`, which scans the matched text as a number.
fn specCaptureNumber(b: *Builder, argv: []const repr.Value) raise.Error!void {
    try pegArity(b, argv.len, 1, 3);
    const r = reserve(b, 4);
    var base: u32 = 0;
    if (argv.len >= 2 and !repr.checkType(argv[1], repr.Tag.nil)) {
        if (!args_core.checkint(argv[1]))
            return pegPanicf(b, "expected integer between 2 and 36, got %v", .{argv[1]});
        base = @bitCast(wrap.toInteger(argv[1]));
        if (base < 2 or base > 36)
            return pegPanicf(b, "expected integer between 2 and 36, got %v", .{argv[1]});
    }
    const tag: u32 = if (argv.len == 3) try emitTag(b, argv[2]) else 0;
    const rule = try pegCompile1(b, argv[0]);
    emit3(r, constants.PegRule.capture_num, rule, base, tag);
}

/// `(+ patt ...)` and `(choice patt ...)`.
fn specChoice(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specVariadic(b, argv, constants.PegRule.choice);
}

/// `(column &opt tag)`.
fn specColumn(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specTag1(b, argv, constants.PegRule.column);
}

/// `(constant k &opt tag)`, which captures `k` without consuming text.
fn specConstant(b: *Builder, argv: []const repr.Value) raise.Error!void {
    try pegArity(b, argv.len, 1, 2);
    const r = reserve(b, 3);
    const tag: u32 = if (argv.len == 2) try emitTag(b, argv[1]) else 0;
    emit2(r, constants.PegRule.constant, emitConstant(b, argv[0]), tag);
}

/// `(??)` and `(debug)`, which print the matcher's position and captures.
fn specDebug(b: *Builder, argv: []const repr.Value) raise.Error!void {
    try pegArity(b, argv.len, 0, 0);
    const r = reserve(b, 1);
    const empty = [_]u32{0};
    emitRule(r, constants.PegRule.debug, 0, &empty);
}

/// `(drop patt)`.
fn specDrop(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specOnerule(b, argv, constants.PegRule.drop);
}

/// `(error &opt patt)`. With no argument the pattern is the empty match, so
/// the error is raised wherever it is reached.
fn specError(b: *Builder, argv: []const repr.Value) raise.Error!void {
    if (argv.len == 0) {
        const r = reserve(b, 2);
        const rule = try pegCompile1(b, wrap.fromNumber(0));
        emit1(r, constants.PegRule.@"error", rule);
        return;
    }
    return specOnerule(b, argv, constants.PegRule.@"error");
}

/// `(group patt &opt tag)`.
fn specGroup(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specCap1(b, argv, constants.PegRule.group);
}

/// `(if cond patt)`.
fn specIf(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specBranch(b, argv, constants.PegRule.@"if");
}

/// `(if-not cond patt)`.
fn specIfnot(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specBranch(b, argv, constants.PegRule.ifnot);
}

/// `(int-be width &opt tag)`.
fn specIntBe(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specReadint(b, argv, 0x30);
}

/// `(int width &opt tag)`.
fn specIntLe(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specReadint(b, argv, 0x10);
}

/// `(lenprefix n patt)`, where the first rule's capture is how many times the
/// second runs.
fn specLenprefix(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specBranch(b, argv, constants.PegRule.lenprefix);
}

/// `(line &opt tag)`.
fn specLine(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specTag1(b, argv, constants.PegRule.line);
}

/// `(> n patt)` and `(look n patt)`, which match `patt` at an offset without
/// consuming it.
fn specLook(b: *Builder, argv: []const repr.Value) raise.Error!void {
    try pegArity(b, argv.len, 1, 2);
    const r = reserve(b, 3);
    const rulearg: i32 = if (argv.len == 2) 1 else 0;
    const offset: i32 = if (argv.len == 2) try pegGetinteger(b, argv[0]) else 0;
    const subrule = try pegCompile1(b, argv[@intCast(rulearg)]);
    emit2(r, constants.PegRule.look, @bitCast(offset), subrule);
}

/// `(cmt patt fn &opt tag)`.
fn specMatchtime(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specMatchtimeImpl(b, argv, constants.PegRule.matchtime);
}

/// The two matchtime specials, which check that the second argument is
/// something callable and put it in the constant table.
fn specMatchtimeImpl(b: *Builder, argv: []const repr.Value, op: constants.PegRule) raise.Error!void {
    try pegArity(b, argv.len, 2, 3);
    const r = reserve(b, 4);
    const subrule = try pegCompile1(b, argv[0]);
    const fun = argv[1];
    if (!repr.checkType(fun, repr.Tag.function) and
        !repr.checkType(fun, repr.Tag.cfunction))
    {
        return pegPanicf(b, "expected function or cfunction, got %v", .{fun});
    }
    const tag: u32 = if (argv.len == 3) try emitTag(b, argv[2]) else 0;
    const cindex = emitConstant(b, fun);
    emit3(r, op, subrule, cindex, tag);
}

/// `(cms patt fn &opt tag)`.
fn specMatchtimeSplice(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specMatchtimeImpl(b, argv, constants.PegRule.matchsplice);
}

/// `(! patt)` and `(not patt)`.
fn specNot(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specOnerule(b, argv, constants.PegRule.not);
}

/// `(nth n patt &opt tag)`.
fn specNth(b: *Builder, argv: []const repr.Value) raise.Error!void {
    try pegArity(b, argv.len, 2, 3);
    const r = reserve(b, 4);
    const nth = try pegGetnat(b, argv[0]);
    const rule = try pegCompile1(b, argv[1]);
    const tag: u32 = if (argv.len == 3) try emitTag(b, argv[2]) else 0;
    emit3(r, constants.PegRule.nth, @bitCast(nth), rule, tag);
}

/// The specials whose rule is `[rule]`.
fn specOnerule(b: *Builder, argv: []const repr.Value, op: constants.PegRule) raise.Error!void {
    try pegFixarity(b, argv.len, 1);
    const r = reserve(b, 2);
    const rule = try pegCompile1(b, argv[0]);
    emit1(r, op, rule);
}

/// `(only-tags patt)`.
fn specOnlyTags(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specOnerule(b, argv, constants.PegRule.only_tags);
}

/// `(? patt)` and `(opt patt)`.
fn specOpt(b: *Builder, argv: []const repr.Value) raise.Error!void {
    try pegFixarity(b, argv.len, 1);
    const r = reserve(b, 4);
    const subrule = try pegCompile1(b, argv[0]);
    emit3(r, constants.PegRule.between, 0, 1, subrule);
}

/// `($ &opt tag)` and `(position &opt tag)`.
fn specPosition(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specTag1(b, argv, constants.PegRule.position);
}

/// `(range "az" ...)`. A single range compiles to a range rule and several
/// compile to a set.
fn specRange(b: *Builder, argv: []const repr.Value) raise.Error!void {
    try pegArity(b, argv.len, 1, -1);
    if (argv.len == 1) {
        const r = reserve(b, 2);
        const str = try pegGetrange(b, argv[0]);
        emit1(r, constants.PegRule.range, @as(u32, str[0]) | (@as(u32, str[1]) << 16));
    } else {
        // More than one range compiles to a set instead.
        const r = reserve(b, 9);
        var bitmap: [8]u32 = @splat(0);
        for (argv) |a| {
            const str = try pegGetrange(b, a);
            var ch: u32 = str[0];
            while (ch <= str[1]) : (ch += 1) bitmapSet(&bitmap, @truncate(ch));
        }
        emitRule(r, constants.PegRule.set, 8, &bitmap);
    }
}

/// The four fixed-width integer specials, whose mask says the width's
/// signedness and byte order.
fn specReadint(b: *Builder, argv: []const repr.Value, mask: u32) raise.Error!void {
    try pegArity(b, argv.len, 1, 2);
    const r = reserve(b, 3);
    const tag: u32 = if (argv.len == 2) try emitTag(b, argv[1]) else 0;
    const width = try pegGetnat(b, argv[0]);
    if (width < 0 or width > max_readint_width) {
        return pegPanicf(b, "width must be between 0 and %d, got %d", .{ max_readint_width, width });
    }
    emit2(r, constants.PegRule.readint, mask | @as(u32, @bitCast(width)), tag);
}

/// `(-> tag)` and `(backref tag)`, which recapture a tagged capture.
fn specReference(b: *Builder, argv: []const repr.Value) raise.Error!void {
    try pegArity(b, argv.len, 1, 2);
    const r = reserve(b, 3);
    const search = try emitTag(b, argv[0]);
    const tag: u32 = if (argv.len == 2) try emitTag(b, argv[1]) else 0;
    b.has_backref = true;
    emit2(r, constants.PegRule.gettag, search, tag);
}

/// `(repeat n patt)`, and the `(n patt)` form a grammar writes with an integer
/// at the head.
fn specRepeat(b: *Builder, argv: []const repr.Value) raise.Error!void {
    try pegFixarity(b, argv.len, 2);
    const r = reserve(b, 4);
    const n = try pegGetnat(b, argv[0]);
    const subrule = try pegCompile1(b, argv[1]);
    emit3(r, constants.PegRule.between, @bitCast(n), @bitCast(n), subrule);
}

/// The two unbounded repetitions, which differ only in their lower bound.
fn specRepeater(b: *Builder, argv: []const repr.Value, min: u32) raise.Error!void {
    try pegFixarity(b, argv.len, 1);
    const r = reserve(b, 4);
    const subrule = try pegCompile1(b, argv[0]);
    emit3(r, constants.PegRule.between, min, std.math.maxInt(u32), subrule);
}

/// `(/ patt subst)` and `(replace patt subst)`.
fn specReplace(b: *Builder, argv: []const repr.Value) raise.Error!void {
    try pegArity(b, argv.len, 2, 3);
    const r = reserve(b, 4);
    const subrule = try pegCompile1(b, argv[0]);
    const constant = emitConstant(b, argv[1]);
    const tag: u32 = if (argv.len == 3) try emitTag(b, argv[2]) else 0;
    emit3(r, constants.PegRule.replace, subrule, constant, tag);
}

/// `(* patt ...)` and `(sequence patt ...)`.
fn specSequence(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specVariadic(b, argv, constants.PegRule.sequence);
}

/// `(set "abc")`.
fn specSet(b: *Builder, argv: []const repr.Value) raise.Error!void {
    try pegFixarity(b, argv.len, 1);
    const r = reserve(b, 9);
    const str = try pegGetset(b, argv[0]);
    var bitmap: [8]u32 = @splat(0);
    for (0..strings.head(str).length) |i| bitmapSet(&bitmap, str[i]);
    emitRule(r, constants.PegRule.set, 8, &bitmap);
}

/// `(some patt)`.
fn specSome(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specRepeater(b, argv, 1);
}

/// `(split sep patt)`.
fn specSplit(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specTworule(b, argv, constants.PegRule.split);
}

/// `(sub window patt)`.
fn specSub(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specTworule(b, argv, constants.PegRule.sub);
}

/// The specials whose rule is `[tag]`.
fn specTag1(b: *Builder, argv: []const repr.Value, op: constants.PegRule) raise.Error!void {
    try pegArity(b, argv.len, 0, 1);
    const r = reserve(b, 2);
    const tag: u32 = if (argv.len != 0) try emitTag(b, argv[0]) else 0;
    emit1(r, op, tag);
}

/// `(thru patt)`.
fn specThru(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specOnerule(b, argv, constants.PegRule.thru);
}

/// `(til stop patt)`.
fn specTil(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specTworule(b, argv, constants.PegRule.til);
}

/// `(to patt)`.
fn specTo(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specOnerule(b, argv, constants.PegRule.to);
}

/// The specials whose rule is `[rule, rule]` and that run the second inside
/// what the first matched.
fn specTworule(b: *Builder, argv: []const repr.Value, op: constants.PegRule) raise.Error!void {
    try pegFixarity(b, argv.len, 2);
    const r = reserve(b, 3);
    const subrule1 = try pegCompile1(b, argv[0]);
    const subrule2 = try pegCompile1(b, argv[1]);
    emit2(r, op, subrule1, subrule2);
}

/// `(uint-be width &opt tag)`.
fn specUintBe(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specReadint(b, argv, 0x20);
}

/// `(uint width &opt tag)`.
fn specUintLe(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specReadint(b, argv, 0x0);
}

/// `(unref patt &opt tag)`.
fn specUnref(b: *Builder, argv: []const repr.Value) raise.Error!void {
    return specCap1(b, argv, constants.PegRule.unref);
}

/// The specials whose rule is `[len, rules...]`.
fn specVariadic(b: *Builder, argv: []const repr.Value, op: constants.PegRule) raise.Error!void {
    const rule: u32 = @intCast(b.bytecode.items.len);
    scratch_vector.push(&b.bytecode, op.number());
    scratch_vector.push(&b.bytecode, @as(u32, @intCast(argv.len)));
    scratch_vector.pushN(&b.bytecode, 0, argv.len);
    for (argv, 0..) |arg, i| {
        const rulei = try pegCompile1(b, arg);
        // Re-read `b.bytecode.items`: compiling a child grows the vector, so
        // the earlier slice is stale.
        b.bytecode.items[rule + 2 + i] = rulei;
    }
}

/// Gives a frame of the matcher's budget back.
inline fn up1(s: *PegState) void {
    s.depth += 1;
}

/// Whether every instruction in `bytecode` is one the matcher can run.
///
/// Split out of `pegUnmarshal` so that a rejection is a returned `Verdict`
/// rather than a jump to a shared cleanup. `op_flags` records, per word,
/// whether it is referenced as a rule operand (`0x01`) or is itself an
/// instruction start (`0x02`); a word that is only referenced is an operand
/// pointing into the middle of another instruction, and is rejected. That is
/// stricter than a depth-first walk, which is deliberate: it also rejects
/// unreachable bytecode.
///
/// The matcher trusts this walk completely, since nothing in `pegRule`
/// bounds-checks a rule index. A compiled peg is an abstract type with
/// `marshal` and `unmarshal` callbacks, so its bytecode arrives from untrusted
/// bytes exactly as marshalled values do, and `pegUnmarshal` runs this before
/// it returns one.
fn verifyBytecode(
    bytecode: [*]const u32,
    blen: u32,
    clen: u32,
    op_flags: [*]u8,
) Verdict {
    var has_backref = false;
    // A program with no instructions has no first instruction to run, and
    // the matcher would read whatever is in the allocation at that word.
    if (blen == 0) return .{ .ok = false, .has_backref = false };
    var i: u32 = 0;
    while (i < blen) {
        const instr = bytecode[i];
        const rule = bytecode + i;
        op_flags[i] |= 0x02;

        switch (constants.PegRule.fromWord(instr)) {
            .literal => { // [byte count, packed bytes...]
                // Two words are read, the rule and its count, and the packed
                // bytes follow. The word count is 64-bit arithmetic
                // because `rule[1]` came off the stream: in 32 bits
                // `(0xFFFFFFFF + 3) >> 2` is zero, and a literal claiming four
                // billion bytes would be scored as occupying two words.
                if (overflows(i, blen, 2)) return .{ .ok = false, .has_backref = has_backref };
                const words: u64 = 2 + ((@as(u64, rule[1]) + 3) >> 2);
                if (overflows(i, blen, words)) return .{ .ok = false, .has_backref = has_backref };
                i += @intCast(words);
            },
            .debug => i += 1, // [0 words]
            .nchar,
            .notnchar,
            .range,
            .position,
            .line,
            .column,
            => i += 2, // [1 word]
            .backmatch => {
                i += 2; // [1 word]
                has_backref = true;
            },
            .set => i += 9, // [8 words]
            .look => { // [offset, rule]
                if (overflows(i, blen, 3)) return .{ .ok = false, .has_backref = has_backref };
                if (rule[2] >= blen) return .{ .ok = false, .has_backref = has_backref };
                op_flags[rule[2]] |= 0x01;
                i += 3;
            },
            .choice, constants.PegRule.sequence => { // [len, rules...]
                if (overflows(i, blen, 2)) return .{ .ok = false, .has_backref = has_backref };
                const len = rule[1];
                if (overflows(i, blen, 2 + @as(u64, len))) return .{ .ok = false, .has_backref = has_backref };
                for (rule[2..][0..len]) |referenced| {
                    if (referenced >= blen) return .{ .ok = false, .has_backref = has_backref };
                    op_flags[referenced] |= 0x01;
                }
                i += 2 +% len;
            },
            .@"if", constants.PegRule.ifnot, constants.PegRule.lenprefix => { // [rule_a, rule_b]
                if (overflows(i, blen, 3)) return .{ .ok = false, .has_backref = has_backref };
                if (rule[1] >= blen) return .{ .ok = false, .has_backref = has_backref };
                if (rule[2] >= blen) return .{ .ok = false, .has_backref = has_backref };
                op_flags[rule[1]] |= 0x01;
                op_flags[rule[2]] |= 0x01;
                i += 3;
            },
            .between => { // [lo, hi, rule]
                if (overflows(i, blen, 4)) return .{ .ok = false, .has_backref = has_backref };
                if (rule[3] >= blen) return .{ .ok = false, .has_backref = has_backref };
                op_flags[rule[3]] |= 0x01;
                i += 4;
            },
            .argument => i += 3, // [argument-index, tag]
            .gettag => { // [searchtag, tag]
                i += 3;
                has_backref = true;
            },
            .constant => { // [constant, tag]
                if (overflows(i, blen, 3)) return .{ .ok = false, .has_backref = has_backref };
                if (rule[1] >= clen) return .{ .ok = false, .has_backref = has_backref };
                i += 3;
            },
            .capture_num => { // [rule, base, tag]
                if (overflows(i, blen, 4)) return .{ .ok = false, .has_backref = has_backref };
                if (rule[1] >= blen) return .{ .ok = false, .has_backref = has_backref };
                op_flags[rule[1]] |= 0x01;
                i += 4;
            },
            .accumulate,
            .group,
            .capture,
            .unref,
            => { // [rule, tag]
                if (overflows(i, blen, 3)) return .{ .ok = false, .has_backref = has_backref };
                if (rule[1] >= blen) return .{ .ok = false, .has_backref = has_backref };
                op_flags[rule[1]] |= 0x01;
                i += 3;
            },
            .replace, constants.PegRule.matchtime, constants.PegRule.matchsplice => { // [rule, constant, tag]
                if (overflows(i, blen, 4)) return .{ .ok = false, .has_backref = has_backref };
                if (rule[1] >= blen) return .{ .ok = false, .has_backref = has_backref };
                if (rule[2] >= clen) return .{ .ok = false, .has_backref = has_backref };
                op_flags[rule[1]] |= 0x01;
                i += 4;
            },
            .sub, constants.PegRule.til, constants.PegRule.split => { // [rule, rule]
                if (overflows(i, blen, 3)) return .{ .ok = false, .has_backref = has_backref };
                if (rule[1] >= blen) return .{ .ok = false, .has_backref = has_backref };
                if (rule[2] >= blen) return .{ .ok = false, .has_backref = has_backref };
                op_flags[rule[1]] |= 0x01;
                op_flags[rule[2]] |= 0x01;
                i += 3;
            },
            .@"error",
            .drop,
            .only_tags,
            .not,
            .to,
            .thru,
            => { // [rule]
                if (overflows(i, blen, 2)) return .{ .ok = false, .has_backref = has_backref };
                if (rule[1] >= blen) return .{ .ok = false, .has_backref = has_backref };
                op_flags[rule[1]] |= 0x01;
                i += 2;
            },
            .readint => { // [width | (signedness << 4) | (endianness << 5), tag]
                // The width is the low four bits. The two flags above it are
                // part of the operand the compiler emits, so comparing the
                // whole word against the maximum width rejects three of the
                // four specials' own output.
                if (overflows(i, blen, 3)) return .{ .ok = false, .has_backref = has_backref };
                if ((rule[1] & 0xF) > max_readint_width) return .{ .ok = false, .has_backref = has_backref };
                i += 3;
            },
            .nth => { // [nth, rule, tag]
                if (overflows(i, blen, 4)) return .{ .ok = false, .has_backref = has_backref };
                if (rule[2] >= blen) return .{ .ok = false, .has_backref = has_backref };
                op_flags[rule[2]] |= 0x01;
                i += 4;
            },
            else => return .{ .ok = false, .has_backref = has_backref },
        }
    }

    // The last instruction cannot overflow.
    if (i != blen) return .{ .ok = false, .has_backref = has_backref };

    // Every referenced word has to be an instruction start as well.
    for (op_flags[0..blen]) |flag| {
        if (flag == 0x01) return .{ .ok = false, .has_backref = has_backref };
    }
    return .{ .ok = true, .has_backref = has_backref };
}

// ==========================================================================
// Tests
// ==========================================================================

comptime {
    for (peg_specials[1..], 0..) |entry, index| {
        if (std.mem.order(u8, peg_specials[index].name, entry.name) != .lt) {
            @compileError("peg_specials is not in lexical order at '" ++ entry.name ++ "'");
        }
    }
}
