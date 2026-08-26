//! The assembler: `(asm ...)` from a Janet data structure to a `JanetFuncDef`.
//!
//! Two files until Phase 12 increment 6f, and the boundary between them was
//! **the C-ABI seam itself** rather than anything about the subject.
//! `asm_core.zig` was the driver -- argument checking, the error paths, the
//! `JanetFuncDef` it hands back -- and `asm_encode.zig` was the opcode table
//! and the per-field scan/fill passes over it. `port/TREE.md` puts them
//! together: one name, `bytecode`, for what Janet publishes as one thing.
//!
//! ## Merging them spent twenty-eight seam entries, and Zig gave no choice
//!
//! Sixteen `janet_zig_asm_*` were `export fn` here and `extern fn` there;
//! twelve `janet_c_asm_*` went the other way. An `extern fn` declaration and an
//! `export fn` definition of one name cannot share a file --
//!
//!     error: duplicate struct member name 'thing'
//!
//! -- so the merge either converts them or does not happen. They are ordinary
//! Zig functions now, called directly, and **every one of the twenty-eight
//! linker symbols is still exported** through the `comptime` block below.
//! That is not tidiness: all twenty-eight are in the library's 690 and in no
//! header, which is Phase 12 item 3's population. Deciding whether an export
//! with no header is wanted belongs to that item; this increment only stops
//! the file calling itself through the C ABI.
//!
//! The naming is increment 5d's, unchanged: strip the prefix, camelCase the
//! underscores, and let `@export` carry the C spelling. One name could not
//! take it straight -- `janet_c_asm_get_field` is `getFieldByName`, because
//! `getField` was already a private helper in the driver half.
//!
//! `BytecodeResult` and `HeaderResult` were declared identically in both files,
//! for the same reason the seam existed: neither could see the other's. One
//! copy now.

const std = @import("std");

const types = @import("types");
const constants = @import("constants");
const c = @import("cabi");
const raise = @import("raise");
const corefn = @import("corefn");

const args_core = @import("args.zig");
const fatal = @import("fatal.zig");
const pp_format = @import("pp/format.zig");
const utils = @import("utils.zig");
const vm_lifecycle = @import("vm/lifecycle.zig");
const disasm = @import("bytecode/disasm.zig");
const verify = @import("bytecode/verify.zig");
const functions = @import("value/functions.zig");
const order = @import("value/helpers/order.zig");
const strings = @import("value/strings.zig");
const structs = @import("value/structs.zig");
const tables = @import("value/tables.zig");
const kind = @import("value/helpers/kind.zig");
const value = @import("value.zig");
const wrap = @import("value/helpers/wrap.zig");
const pp_describe = @import("pp.zig");

// ---------------------------------------------------------------------------
// The driver -- what `asm_core.zig` was.
// ---------------------------------------------------------------------------

/// The assembler's own failure, and not a Janet signal. One member, because
/// the message travels in the assembler rather than in the error.
const AsmError = error{Assembly};

// ------------------------------------------------- the results Zig hands back

/// `JanetAsmHeaderResult` in `src/core/asm.c`, and `HeaderResult` in
/// `asm_encode.zig`. Declared a third time here rather than shared, because the
/// three are the same three fields and a header for one struct used by one
/// caller each way is more machinery than it saves.
pub const HeaderResult = extern struct {
    error_message: ?[*:0]const u8,
    indexed_error: i32,
};

/// `JanetAsmBytecodeResult`.
pub const BytecodeResult = extern struct {
    count: i32,
    error_message: ?[*:0]const u8,
    indexed_error: i32,
    error_index: i32,
};

// ------------------------------------------------------------ the assembler

/// `JanetAssembler`, minus the `jmp_buf`.
///
/// The layout is nobody's business but this file's: `asm_encode.zig` reaches an
/// assembler through `?*anyopaque` and the fourteen accessors below, which is
/// the seam Phase 5 drew and which this increment does not move.
const Assembler = struct {
    parent: ?*Assembler,
    def: *types.JanetFuncDef,
    errmessage: ?[*:0]const u8,
    errindex: i32,

    environments_capacity: i32,
    defs_capacity: i32,
    bytecode_count: i32,

    name: types.Janet,
    labels: types.JanetTable,
    slots: types.JanetTable,
    envs: types.JanetTable,
    defs: types.JanetTable,

    fn init(self: *Assembler, parent: ?*Assembler, def: *types.JanetFuncDef) void {
        self.* = .{
            .parent = parent,
            .def = def,
            .errmessage = null,
            .errindex = 0,
            .environments_capacity = 0,
            .defs_capacity = 0,
            .bytecode_count = 0,
            .name = wrap.fromNil(),
            .labels = undefined,
            .slots = undefined,
            .envs = undefined,
            .defs = undefined,
        };
        // `janet_table_init` returns the table it initialised, which the C
        // ignores at every one of these four call sites.
        _ = tables.init(&self.labels, 0);
        _ = tables.init(&self.slots, 0);
        _ = tables.init(&self.envs, 0);
        _ = tables.init(&self.defs, 0);
    }

    /// Release the four tables. The C original notes that it does not touch the
    /// parents, and neither does this: a parent is released by its own frame.
    fn deinit(self: *Assembler) void {
        tables.deinit(&self.slots);
        tables.deinit(&self.labels);
        tables.deinit(&self.envs);
        tables.deinit(&self.defs);
    }

    /// `janet_asm_error`. The index suffix is appended exactly when `errindex`
    /// is non-negative, which is how a bytecode fault names its instruction and
    /// a header fault does not.
    fn fail(self: *Assembler, message: ?[*:0]const u8) AsmError {
        self.errmessage = if (self.errindex < 0)
            pp_format.formatcReported("%s", .{message})
        else
            pp_format.formatcReported("%s, instruction %d", .{ message, self.errindex });
        return error.Assembly;
    }

    /// `janet_asm_errorv`. The message is already a Janet string and is taken
    /// unaltered, index or no index.
    fn failv(self: *Assembler, message: ?[*:0]const u8) AsmError {
        self.errmessage = message;
        return error.Assembly;
    }

    /// Report whichever way the callee asked for. Every `janet_zig_asm_*` entry
    /// point answers with a message and a flag saying whether it wants the
    /// instruction index appended, and every one of `janet_asm1`'s call sites
    /// spelled the same two-line test out. It is one function here.
    fn report(self: *Assembler, message: ?[*:0]const u8, indexed: bool) AsmError {
        if (indexed) return self.fail(message);
        return self.failv(message);
    }
};

/// `janet_asm_addenv`. Resolves a closure environment by name, walking the
/// parent chain and memoising into `envs` on the way back down.
///
/// Three return values, and they are a code rather than a size: an index, -1
/// for "this is the current function's own name", and -2 for "no parent has
/// it". `doarg_1` in C distinguishes the last from the others by testing
/// `< -1`, so the two negatives cannot be collapsed.
fn addEnv(a: *Assembler, envname: types.Janet) i32 {
    if (order.equals(a.name, envname) != 0) return -1;
    const check = tables.get(&a.envs, envname);
    if (kind.checkType(check, constants.JANET_NUMBER) != 0) {
        return @intFromFloat(wrap.toNumber(check));
    }
    const parent = a.parent orelse return -2;
    const res = addEnv(parent, envname);
    if (res < -1) return res;

    const def = a.def;
    const envindex = def.environments_length;
    tables.put(&a.envs, envname, wrap.fromNumber(@floatFromInt(envindex)));
    if (envindex >= a.environments_capacity) {
        const newcap = 2 * envindex;
        def.environments = @ptrCast(@alignCast(utils.realloc(
            @ptrCast(def.environments),
            @as(usize, @intCast(newcap)) * @sizeOf(i32),
        ) orelse fatal.outOfMemory()));
        a.environments_capacity = newcap;
    }
    def.environments.?[@intCast(envindex)] = res;
    def.environments_length = envindex + 1;
    return envindex;
}

/// `janet_get1`. A lookup that answers nil for anything that is not a table or
/// a struct, which is what lets `janet_asm1` ask for a field of a source it has
/// not yet validated.
fn getField(ds: types.Janet, key: types.Janet) types.Janet {
    return switch (kind.typeOf(ds)) {
        constants.JANET_TABLE => tables.get(wrap.toTable(ds), key),
        constants.JANET_STRUCT => structs.get(wrap.toStruct(ds), key),
        else => wrap.fromNil(),
    };
}

// --------------------------------------------------------- the field accessors

// The seam `asm_encode.zig` reaches an assembler through. Fourteen accessors
// over an opaque pointer, unchanged in name and signature from the C ones they
// replace, so the encode layer does not learn which side it is talking to.

inline fn asmOf(context: ?*anyopaque) *Assembler {
    return @ptrCast(@alignCast(context.?));
}

pub fn argumentTable(context: ?*anyopaque, argument_type: i32) ?*types.JanetTable {
    const a = asmOf(context);
    return switch (argument_type) {
        constants.JANET_OAT_SLOT => &a.slots,
        constants.JANET_OAT_ENVIRONMENT => &a.envs,
        constants.JANET_OAT_LABEL => &a.labels,
        constants.JANET_OAT_FUNCDEF => &a.defs,
        else => null,
    };
}

pub fn funcdef(context: ?*anyopaque) callconv(.c) *types.JanetFuncDef {
    return asmOf(context).def;
}

pub fn setName(context: ?*anyopaque, name: types.Janet) void {
    asmOf(context).name = name;
}

pub fn bytecodeCount(context: ?*anyopaque) i32 {
    return asmOf(context).bytecode_count;
}

pub fn setBytecodeCount(context: ?*anyopaque, count: i32) void {
    asmOf(context).bytecode_count = count;
}

pub fn addEnvironment(context: ?*anyopaque, name: types.Janet) i32 {
    return addEnv(asmOf(context), name);
}

/// Walk `environment + 1` links up the parent chain. The `+ 1` is the C
/// original's and is load-bearing: environment 0 means the immediate parent,
/// not the assembler itself.
pub fn parentForEnvironment(context: ?*anyopaque, environment: u32) ?*anyopaque {
    var a: ?*Assembler = asmOf(context);
    var remaining = environment + 1;
    while (remaining > 0) : (remaining -= 1) {
        a = (a orelse return null).parent;
        if (a == null) return null;
    }
    return a;
}

pub fn argumentBoundsError(x: types.Janet, nbytes: i32, too_large: i32) [*:0]const u8 {
    // Through a sentinel pointer rather than a slice, because `%s` renders a
    // NUL-terminated run of bytes and a slice is not one.
    const plural: [*]const u8 = if (nbytes > 1) "s" else "";
    // Two calls rather than one: the format string is `comptime` now, so a
    // runtime `if` cannot choose between two of them.
    return if (too_large != 0)
        pp_format.formatcReported("instruction argument %v is too large, must be %d byte%s", .{ x, nbytes, plural })
    else
        pp_format.formatcReported("instruction argument %v is too small, must be %d byte%s", .{ x, nbytes, plural });
}

pub fn unknownInstruction(val: types.Janet) [*:0]const u8 {
    return pp_format.formatcReported("unknown instruction %v", .{val});
}

pub fn resolutionError(val: types.Janet, failure: i32) [*:0]const u8 {
    return switch (failure) {
        1 => pp_format.formatcReported("unknown type %v", .{val}),
        2 => pp_format.formatcReported("unknown name %v", .{val}),
        3 => pp_format.formatcReported("unknown environment %v", .{val}),
        else => pp_format.formatcReported("error parsing instruction argument %v", .{val}),
    };
}

pub fn getFieldByName(source: types.Janet, name: [*:0]const u8) types.Janet {
    return getField(source, value.fromBytes(std.mem.span(name), .keyword));
}

pub fn invalidError(status: i32) [*:0]const u8 {
    return pp_format.formatcReported("invalid assembly (%d)", .{status});
}

// ---------------------------------------------------------------- the driver

fn allocate(comptime T: type, count: i32) [*]T {
    const bytes = @sizeOf(T) * @as(usize, @intCast(count));
    return @ptrCast(@alignCast(utils.malloc(bytes) orelse fatal.outOfMemory()));
}

/// The body of one assembly, in the C original's order. Every step either
/// succeeds or returns `error.Assembly` with the message already in the
/// assembler; the caller releases the tables.
fn assemble(a: *Assembler, source: types.Janet, flags: c_int) AsmError!void {
    const def = a.def;

    {
        const header = parseHeader(a, source);
        if (header.error_message != null) return a.report(header.error_message, header.indexed_error != 0);
    }

    {
        const slots = parseSlots(a, source);
        if (slots.error_message != null) return a.report(slots.error_message, slots.indexed_error != 0);
        const scanned = scanConstants(a, source);
        def.constants_length = scanned.count;
        if (scanned.count > 0) {
            def.constants = allocate(types.Janet, scanned.count);
            _ = fillConstants(a, source);
        } else {
            def.constants = null;
        }
    }

    // Sub funcdefs. The recursion is what the parent chain exists for, and the
    // child's result is checked here rather than jumped past -- see the note at
    // the head of this file about the branch that was unreachable in C.
    {
        const definitions = scanDefs(source);
        var i: i32 = 0;
        while (i < definitions.count) : (i += 1) {
            const subsource = defAt(source, i);
            const subdef = try asmNested(a, subsource, flags);
            registerDef(a, subsource, def.defs_length);
            const newlen = def.defs_length + 1;
            if (a.defs_capacity < newlen) {
                def.defs = @ptrCast(@alignCast(utils.realloc(
                    @ptrCast(def.defs),
                    @as(usize, @intCast(newlen)) * @sizeOf(*types.JanetFuncDef),
                ) orelse fatal.outOfMemory()));
                a.defs_capacity = newlen;
            }
            def.defs.?[@intCast(def.defs_length)] = subdef;
            def.defs_length = newlen;
        }
    }

    {
        const x = getField(source, value.fromBytes("bytecode", .keyword));
        var bytecode = scanBytecode(a, x);
        if (bytecode.error_message != null) {
            a.errindex = bytecode.error_index;
            return a.report(bytecode.error_message, bytecode.indexed_error != 0);
        }
        def.bytecode_length = bytecode.count;
        def.bytecode = allocate(u32, bytecode.count);
        bytecode = fillBytecode(a, x);
        if (bytecode.error_message != null) {
            a.errindex = bytecode.error_index;
            return a.report(bytecode.error_message, bytecode.indexed_error != 0);
        }
    }

    // Everything from here reports without an instruction index.
    a.errindex = -1;

    {
        const sourcemap = scanSourcemap(a, source);
        if (sourcemap.error_message != null) return a.fail(sourcemap.error_message);
        if (sourcemap.count > 0) {
            def.sourcemap = allocate(types.JanetSourceMapping, sourcemap.count);
            const filled = janet_zig_asm_fill_sourcemapImpl(a, source);
            if (filled.error_message != null) return a.fail(filled.error_message);
        }
    }

    def.symbolmap = null;
    def.symbolmap_length = 0;
    {
        const symbolmap = scanSymbolmap(a, source);
        if (symbolmap.count > 0) {
            def.symbolmap_length = symbolmap.count;
            def.symbolmap = allocate(types.JanetSymbolMap, symbolmap.count);
            const filled = janet_zig_asm_fill_symbolmapImpl(a, source);
            if (filled.error_message != null) return a.fail(filled.error_message);
        }
    }
    if (def.symbolmap_length != 0) def.flags |= constants.JANET_FUNCDEF_FLAG_HASSYMBOLMAP;

    {
        const environments = scanEnvironments(a, source);
        if (environments.count >= 0) {
            def.environments_length = environments.count;
            if (environments.count > 0) {
                def.environments = @ptrCast(@alignCast(utils.realloc(
                    @ptrCast(def.environments),
                    @as(usize, @intCast(environments.count)) * @sizeOf(i32),
                ) orelse fatal.outOfMemory()));
            }
            const filled = fillEnvironments(a, source);
            if (filled.error_message != null) return a.fail(filled.error_message);
        }
    }

    {
        const finalized = finalize(a);
        if (finalized.error_message != null) return a.failv(finalized.error_message);
    }
}

/// One nested assembly, for a `:defs` entry. Reports its parent's message on
/// the way out, which is the propagation C did with a jump.
fn asmNested(parent: *Assembler, source: types.Janet, flags: c_int) AsmError!*types.JanetFuncDef {
    const result = asm1(parent, source, flags);
    if (result.status != constants.JANET_ASSEMBLE_OK) return parent.failv(result.@"error");
    return result.funcdef.?;
}

/// `janet_asm1`. Owns one assembler, and is the frame the whole of an assembly
/// unwinds to.
fn asm1(parent: ?*Assembler, source: types.Janet, flags: c_int) types.JanetAssembleResult {
    var a: Assembler = undefined;
    a.init(parent, functions.defs.new());
    defer a.deinit();

    assemble(&a, source, flags) catch {
        return .{
            .funcdef = null,
            .@"error" = a.errmessage,
            .status = constants.JANET_ASSEMBLE_ERROR,
        };
    };
    return .{
        .funcdef = a.def,
        .@"error" = null,
        .status = constants.JANET_ASSEMBLE_OK,
    };
}

/// `janet_asm`. The public entry, and unchanged in shape: it reports a result
/// rather than raising, which is why removing the jump underneath it needs no
/// abi and changes nothing a caller can see.
pub fn assembleValue(source: types.Janet, flags: c_int) types.JanetAssembleResult {
    return asm1(null, source, flags);
}

// ==========================================================================
// asm and disasm, the cfunction surface
// ==========================================================================
//
// Phase 10 Part 17g. The last two cfunctions written in C, and the reason the
// cfunction type could not become a Zig one: a registry row holds a single
// type, and a C body cannot carry an error union.
//
// `disasm`'s fifteen-way keyword dispatch is the densest use of
// `janet_cstrcmp` in the tree. It is kept as a linear chain of comparisons
// rather than turned into a `std.StaticStringMap`, because the order decides
// which of two keys that share a prefix wins and because `janet_cstrcmp`
// compares against the *string head's* length -- the port's job here is to
// move it, not to improve it.

fn cfunAsm(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_ASM);
    try args_core.fixarity(argv, 1);
    const res = assembleValue(argv[0], 0);
    if (res.status != constants.JANET_ASSEMBLE_OK) {
        const message = res.@"error" orelse strings.cstring("invalid assembly");
        return raise.panicv(wrap.fromString(message));
    }
    return wrap.fromFunction(functions.thunk(res.funcdef.?));
}

/// The keyword-to-field table `disasm`'s optional second argument selects on.
/// One entry per `disasm.Field`, in the C original's comparison order.
const disasm_fields = [_]struct { name: [*:0]const u8, field: disasm.Field }{
    .{ .name = "arity", .field = .arity },
    .{ .name = "min-arity", .field = .min_arity },
    .{ .name = "max-arity", .field = .max_arity },
    .{ .name = "bytecode", .field = .bytecode },
    .{ .name = "source", .field = .source },
    .{ .name = "name", .field = .name },
    .{ .name = "vararg", .field = .vararg },
    .{ .name = "structarg", .field = .structarg },
    .{ .name = "namedargs", .field = .namedargs },
    .{ .name = "slotcount", .field = .slotcount },
    .{ .name = "symbolmap", .field = .symbolmap },
    .{ .name = "constants", .field = .constants },
    .{ .name = "sourcemap", .field = .sourcemap },
    .{ .name = "environments", .field = .environments },
    .{ .name = "defs", .field = .defs },
};

fn cfunDisasm(argv: []types.Janet) raise.Raising(types.Janet) {
    try vm_lifecycle.sandboxAssert(constants.JANET_SANDBOX_ASM);
    try args_core.arity(argv, 1, 2);
    const f = try args_core.getFunction(argv, 0);
    if (@as(i32, @intCast(argv.len)) != 2) return disasm.disassembleField(f.*.def.?, .all);

    const kw = try args_core.getKeyword(argv, 1);
    for (disasm_fields) |entry| {
        if (utils.cstrcmp(kw, entry.name) == 0) {
            return disasm.disassembleField(f.*.def.?, entry.field);
        }
    }
    return pp_format.panicf("unknown disasm key %v", .{argv[1]});
}

pub fn libAsm(env: *types.JanetTable) void {
    raise.reported(janet_lib_asmImpl(env));
}

pub fn janet_lib_asmImpl(env: *types.JanetTable) raise.Raising(void) {
    const entries = [_]corefn.Entry{
        corefn.reg("asm", &cfunAsm, @src(), "(asm assembly)", "Returns a new function that is the compiled result of the assembly.\n" ++
            "The syntax for the assembly can be found on the Janet website, and should correspond\n" ++
            "to the return value of disasm. Will throw an\n" ++
            "error on invalid assembly."),
        corefn.reg("disasm", &cfunDisasm, @src(), "(disasm func &opt field)", "Returns assembly that could be used to compile the given function. " ++
            "func must be a function, not a c function. Will throw on error on a badly " ++
            "typed argument. If given a field name, will only return that part of the function assembly. " ++
            "Possible fields are:\n\n" ++
            "* :arity - number of required and optional arguments.\n" ++
            "* :min-arity - minimum number of arguments function can be called with.\n" ++
            "* :max-arity - maximum number of arguments function can be called with.\n" ++
            "* :vararg - true if function can take a variable number of arguments.\n" ++
            "* :structarg - true if function can take a variable number of arguments using the &keys option.\n" ++
            "* :namedargs - if function can take a variable number of arguments using the &named option, this will be the number of named arguments.\n" ++
            "* :bytecode - array of parsed bytecode instructions. Each instruction is a tuple.\n" ++
            "* :source - name of source file that this function was compiled from.\n" ++
            "* :name - name of function.\n" ++
            "* :slotcount - how many virtual registers, or slots, this function uses. Corresponds to stack space used by function.\n" ++
            "* :symbolmap - all symbols and their slots.\n" ++
            "* :constants - an array of constants referenced by this function.\n" ++
            "* :sourcemap - a mapping of each bytecode instruction to a line and column in the source file.\n" ++
            "* :environments - an internal mapping of which enclosing functions are referenced for bindings.\n" ++
            "* :defs - other function definitions that this function may instantiate.\n"),
        corefn.end,
    };
    corefn.install(env, &entries);
}

// ---------------------------------------------------------------------------
// The opcode table and the field passes -- what `asm_encode.zig` was.
// ---------------------------------------------------------------------------

const ResolvedArgument = struct {
    value: i32,
    error_message: ?[*:0]const u8 = null,
};

pub const EncodeResult = extern struct {
    instruction: u32,
    error_message: ?[*:0]const u8,
    indexed_error: i32,
};

/// `janet_wrap_integer`, written out. `janet.h` declares it beside its macro
/// and `wrap.c` defines it only for the two nanbox layouts, so a Zig caller
/// that reaches the declaration does not link against `-Dnanbox=false`.
inline fn janet_c_asm_wrap_integer(val: i32) types.Janet {
    return wrap.fromNumber(@floatFromInt(val));
}
extern fn janet_def_addflags(definition: *types.JanetFuncDef) callconv(.c) void;

const OpcodeDefinition = struct {
    name: [*:0]const u8,
    opcode: u32,
};

const TypeAlias = struct {
    name: [*:0]const u8,
    mask: i32,
};

const type_aliases = [_]TypeAlias{
    .{ .name = "abstract", .mask = constants.JANET_TFLAG_ABSTRACT },
    .{ .name = "array", .mask = constants.JANET_TFLAG_ARRAY },
    .{ .name = "boolean", .mask = constants.JANET_TFLAG_BOOLEAN },
    .{ .name = "buffer", .mask = constants.JANET_TFLAG_BUFFER },
    .{ .name = "callable", .mask = constants.JANET_TFLAG_CALLABLE },
    .{ .name = "cfunction", .mask = constants.JANET_TFLAG_CFUNCTION },
    .{ .name = "dictionary", .mask = constants.JANET_TFLAG_DICTIONARY },
    .{ .name = "fiber", .mask = constants.JANET_TFLAG_FIBER },
    .{ .name = "function", .mask = constants.JANET_TFLAG_FUNCTION },
    .{ .name = "indexed", .mask = constants.JANET_TFLAG_INDEXED },
    .{ .name = "keyword", .mask = constants.JANET_TFLAG_KEYWORD },
    .{ .name = "nil", .mask = constants.JANET_TFLAG_NIL },
    .{ .name = "number", .mask = constants.JANET_TFLAG_NUMBER },
    .{ .name = "pointer", .mask = constants.JANET_TFLAG_POINTER },
    .{ .name = "string", .mask = constants.JANET_TFLAG_STRING },
    .{ .name = "struct", .mask = constants.JANET_TFLAG_STRUCT },
    .{ .name = "symbol", .mask = constants.JANET_TFLAG_SYMBOL },
    .{ .name = "table", .mask = constants.JANET_TFLAG_TABLE },
    .{ .name = "tuple", .mask = constants.JANET_TFLAG_TUPLE },
};

pub const opcodes = [_]OpcodeDefinition{
    .{ .name = "add", .opcode = constants.JOP_ADD },
    .{ .name = "addim", .opcode = constants.JOP_ADD_IMMEDIATE },
    .{ .name = "band", .opcode = constants.JOP_BAND },
    .{ .name = "bnot", .opcode = constants.JOP_BNOT },
    .{ .name = "bor", .opcode = constants.JOP_BOR },
    .{ .name = "bxor", .opcode = constants.JOP_BXOR },
    .{ .name = "call", .opcode = constants.JOP_CALL },
    .{ .name = "clo", .opcode = constants.JOP_CLOSURE },
    .{ .name = "cmp", .opcode = constants.JOP_COMPARE },
    .{ .name = "cncl", .opcode = constants.JOP_CANCEL },
    .{ .name = "div", .opcode = constants.JOP_DIVIDE },
    .{ .name = "divf", .opcode = constants.JOP_DIVIDE_FLOOR },
    .{ .name = "divim", .opcode = constants.JOP_DIVIDE_IMMEDIATE },
    .{ .name = "eq", .opcode = constants.JOP_EQUALS },
    .{ .name = "eqim", .opcode = constants.JOP_EQUALS_IMMEDIATE },
    .{ .name = "err", .opcode = constants.JOP_ERROR },
    .{ .name = "get", .opcode = constants.JOP_GET },
    .{ .name = "geti", .opcode = constants.JOP_GET_INDEX },
    .{ .name = "gt", .opcode = constants.JOP_GREATER_THAN },
    .{ .name = "gte", .opcode = constants.JOP_GREATER_THAN_EQUAL },
    .{ .name = "gtim", .opcode = constants.JOP_GREATER_THAN_IMMEDIATE },
    .{ .name = "in", .opcode = constants.JOP_IN },
    .{ .name = "jmp", .opcode = constants.JOP_JUMP },
    .{ .name = "jmpif", .opcode = constants.JOP_JUMP_IF },
    .{ .name = "jmpni", .opcode = constants.JOP_JUMP_IF_NIL },
    .{ .name = "jmpnn", .opcode = constants.JOP_JUMP_IF_NOT_NIL },
    .{ .name = "jmpno", .opcode = constants.JOP_JUMP_IF_NOT },
    .{ .name = "ldc", .opcode = constants.JOP_LOAD_CONSTANT },
    .{ .name = "ldf", .opcode = constants.JOP_LOAD_FALSE },
    .{ .name = "ldi", .opcode = constants.JOP_LOAD_INTEGER },
    .{ .name = "ldn", .opcode = constants.JOP_LOAD_NIL },
    .{ .name = "lds", .opcode = constants.JOP_LOAD_SELF },
    .{ .name = "ldt", .opcode = constants.JOP_LOAD_TRUE },
    .{ .name = "ldu", .opcode = constants.JOP_LOAD_UPVALUE },
    .{ .name = "len", .opcode = constants.JOP_LENGTH },
    .{ .name = "lt", .opcode = constants.JOP_LESS_THAN },
    .{ .name = "lte", .opcode = constants.JOP_LESS_THAN_EQUAL },
    .{ .name = "ltim", .opcode = constants.JOP_LESS_THAN_IMMEDIATE },
    .{ .name = "mkarr", .opcode = constants.JOP_MAKE_ARRAY },
    .{ .name = "mkbtp", .opcode = constants.JOP_MAKE_BRACKET_TUPLE },
    .{ .name = "mkbuf", .opcode = constants.JOP_MAKE_BUFFER },
    .{ .name = "mkstr", .opcode = constants.JOP_MAKE_STRING },
    .{ .name = "mkstu", .opcode = constants.JOP_MAKE_STRUCT },
    .{ .name = "mktab", .opcode = constants.JOP_MAKE_TABLE },
    .{ .name = "mktup", .opcode = constants.JOP_MAKE_TUPLE },
    .{ .name = "mod", .opcode = constants.JOP_MODULO },
    .{ .name = "movf", .opcode = constants.JOP_MOVE_FAR },
    .{ .name = "movn", .opcode = constants.JOP_MOVE_NEAR },
    .{ .name = "mul", .opcode = constants.JOP_MULTIPLY },
    .{ .name = "mulim", .opcode = constants.JOP_MULTIPLY_IMMEDIATE },
    .{ .name = "neq", .opcode = constants.JOP_NOT_EQUALS },
    .{ .name = "neqim", .opcode = constants.JOP_NOT_EQUALS_IMMEDIATE },
    .{ .name = "next", .opcode = constants.JOP_NEXT },
    .{ .name = "noop", .opcode = constants.JOP_NOOP },
    .{ .name = "prop", .opcode = constants.JOP_PROPAGATE },
    .{ .name = "push", .opcode = constants.JOP_PUSH },
    .{ .name = "push2", .opcode = constants.JOP_PUSH_2 },
    .{ .name = "push3", .opcode = constants.JOP_PUSH_3 },
    .{ .name = "pusha", .opcode = constants.JOP_PUSH_ARRAY },
    .{ .name = "put", .opcode = constants.JOP_PUT },
    .{ .name = "puti", .opcode = constants.JOP_PUT_INDEX },
    .{ .name = "rem", .opcode = constants.JOP_REMAINDER },
    .{ .name = "res", .opcode = constants.JOP_RESUME },
    .{ .name = "ret", .opcode = constants.JOP_RETURN },
    .{ .name = "retn", .opcode = constants.JOP_RETURN_NIL },
    .{ .name = "setu", .opcode = constants.JOP_SET_UPVALUE },
    .{ .name = "sig", .opcode = constants.JOP_SIGNAL },
    .{ .name = "sl", .opcode = constants.JOP_SHIFT_LEFT },
    .{ .name = "slim", .opcode = constants.JOP_SHIFT_LEFT_IMMEDIATE },
    .{ .name = "sr", .opcode = constants.JOP_SHIFT_RIGHT },
    .{ .name = "srim", .opcode = constants.JOP_SHIFT_RIGHT_IMMEDIATE },
    .{ .name = "sru", .opcode = constants.JOP_SHIFT_RIGHT_UNSIGNED },
    .{ .name = "sruim", .opcode = constants.JOP_SHIFT_RIGHT_UNSIGNED_IMMEDIATE },
    .{ .name = "sub", .opcode = constants.JOP_SUBTRACT },
    .{ .name = "subim", .opcode = constants.JOP_SUBTRACT_IMMEDIATE },
    .{ .name = "tcall", .opcode = constants.JOP_TAILCALL },
    .{ .name = "tchck", .opcode = constants.JOP_TYPECHECK },
};

pub fn parseHeader(
    assembler: ?*anyopaque,
    source: types.Janet,
) callconv(.c) HeaderResult {
    if (kind.checkType(source, constants.JANET_STRUCT) == 0 and
        kind.checkType(source, constants.JANET_TABLE) == 0)
    {
        return headerFailure("expected struct or table for assembly source");
    }
    const definition = funcdef(assembler);
    var val = getFieldByName(source, "name");
    setName(assembler, val);
    if (kind.checkType(val, constants.JANET_NIL) == 0) definition.*.name = pp_describe.toString(val);

    val = getFieldByName(source, "arity");
    definition.*.arity = if (args_core.checkint(val) != 0) integerValue(val) else 0;
    if (definition.*.arity < 0) return headerFailure("arity must be non-negative");

    val = getFieldByName(source, "max-arity");
    definition.*.max_arity = if (args_core.checkint(val) != 0) integerValue(val) else definition.*.arity;
    if (definition.*.max_arity < definition.*.arity) {
        return headerFailure("max-arity must be greater than or equal to arity");
    }

    val = getFieldByName(source, "min-arity");
    definition.*.min_arity = if (args_core.checkint(val) != 0) integerValue(val) else definition.*.arity;
    if (definition.*.min_arity > definition.*.arity) {
        return headerFailure("min-arity must be less than or equal to arity");
    }

    val = getFieldByName(source, "vararg");
    if (kind.truthy(val) != 0) definition.*.flags |= constants.JANET_FUNCDEF_FLAG_VARARG;
    definition.*.slotcount = definition.*.arity + @intFromBool(definition.*.flags & constants.JANET_FUNCDEF_FLAG_VARARG != 0);

    val = getFieldByName(source, "structarg");
    if (kind.truthy(val) != 0) definition.*.flags |= constants.JANET_FUNCDEF_FLAG_STRUCTARG;

    val = getFieldByName(source, "namedargs");
    if (args_core.checkint(val) != 0) {
        definition.*.flags |= constants.JANET_FUNCDEF_FLAG_NAMEDARGS;
        definition.*.named_args_count = integerValue(val);
    }

    val = getFieldByName(source, "source");
    if (kind.checkType(val, constants.JANET_STRING) != 0) definition.*.source = wrap.toString(val);
    return .{ .error_message = null, .indexed_error = 0 };
}

pub fn parseSlots(
    assembler: ?*anyopaque,
    source: types.Janet,
) callconv(.c) HeaderResult {
    const slots_value = getFieldByName(source, "slots");
    var items: ?[*]const types.Janet = null;
    var length: i32 = 0;
    if (args_core.indexedView(slots_value, &items, &length) == 0) return headerSuccess();
    const slots = argumentTable(assembler, constants.JANET_OAT_SLOT).?;
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        const val = items.?[@intCast(index)];
        if (kind.checkType(val, constants.JANET_TUPLE) != 0) {
            const aliases = wrap.toTuple(val);
            var alias_index: i32 = 0;
            while (alias_index < types.tupleHead(aliases).length) : (alias_index += 1) {
                const alias = aliases[@intCast(alias_index)];
                if (kind.checkType(alias, constants.JANET_SYMBOL) == 0) {
                    return headerFailure("slot names must be symbols");
                }
                tables.put(slots, alias, janet_c_asm_wrap_integer(index));
            }
        } else if (kind.checkType(val, constants.JANET_SYMBOL) != 0) {
            tables.put(slots, val, janet_c_asm_wrap_integer(index));
        } else {
            return headerFailure("slot names must be symbols or tuple of symbols");
        }
    }
    return headerSuccess();
}

pub fn scanConstants(
    _: ?*anyopaque,
    source: types.Janet,
) callconv(.c) BytecodeResult {
    const consts = getFieldByName(source, "constants");
    var items: ?[*]const types.Janet = null;
    var length: i32 = 0;
    if (args_core.indexedView(consts, &items, &length) == 0) return bytecodeSuccess(0);
    return bytecodeSuccess(length);
}

pub fn fillConstants(
    assembler: ?*anyopaque,
    source: types.Janet,
) callconv(.c) void {
    const consts = getFieldByName(source, "constants");
    var items: ?[*]const types.Janet = null;
    var length: i32 = 0;
    if (args_core.indexedView(consts, &items, &length) == 0) unreachable;
    const definition = funcdef(assembler);
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        definition.*.constants.?[@intCast(index)] = items.?[@intCast(index)];
    }
}

pub fn scanSourcemap(
    assembler: ?*anyopaque,
    source: types.Janet,
) callconv(.c) BytecodeResult {
    const sourcemap = getFieldByName(source, "sourcemap");
    var items: ?[*]const types.Janet = null;
    var length: i32 = 0;
    if (args_core.indexedView(sourcemap, &items, &length) == 0) return bytecodeSuccess(0);
    if (length != funcdef(assembler).*.bytecode_length) {
        return bytecodeFailure("sourcemap must have the same length as the bytecode", true, -1);
    }
    return bytecodeSuccess(length);
}

/// Cannot raise: every failure is a `HeaderResult` carrying a message, which
/// is the assembler's own channel. The signature said `raise.Raising` through
/// the hinge and never returned an error, which cost its two callers in
/// `asm_core.zig` a `catch` they could not do anything with -- the assembler
/// has its own error set and a `JanetSignal` cannot travel through it.
pub fn janet_zig_asm_fill_sourcemapImpl(
    assembler: ?*anyopaque,
    source: types.Janet,
) HeaderResult {
    const sourcemap = getFieldByName(source, "sourcemap");
    var items: ?[*]const types.Janet = null;
    var length: i32 = 0;
    if (args_core.indexedView(sourcemap, &items, &length) == 0) unreachable;
    const definition = funcdef(assembler);
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        const entry = items.?[@intCast(index)];
        if (kind.checkType(entry, constants.JANET_TUPLE) == 0) return headerFailure("expected tuple");
        const tuple = wrap.toTuple(entry);
        if (args_core.checkint(tuple[0]) == 0) return headerFailure("expected integer");
        if (args_core.checkint(tuple[1]) == 0) return headerFailure("expected integer");
        definition.*.sourcemap.?[@intCast(index)] = .{
            .line = integerValue(tuple[0]),
            .column = integerValue(tuple[1]),
        };
    }
    return headerSuccess();
}

pub fn fillSourcemap(
    assembler: ?*anyopaque,
    source: types.Janet,
) callconv(.c) HeaderResult {
    return janet_zig_asm_fill_sourcemapImpl(assembler, source);
}

pub fn scanSymbolmap(
    _: ?*anyopaque,
    source: types.Janet,
) callconv(.c) BytecodeResult {
    const symbolmap = getFieldByName(source, "symbolmap");
    var items: ?[*]const types.Janet = null;
    var length: i32 = 0;
    if (args_core.indexedView(symbolmap, &items, &length) == 0) return bytecodeSuccess(0);
    return bytecodeSuccess(length);
}

/// Cannot raise: every failure is a `HeaderResult` carrying a message, which
/// is the assembler's own channel. The signature said `raise.Raising` through
/// the hinge and never returned an error, which cost its two callers in
/// `asm_core.zig` a `catch` they could not do anything with -- the assembler
/// has its own error set and a `JanetSignal` cannot travel through it.
pub fn janet_zig_asm_fill_symbolmapImpl(
    assembler: ?*anyopaque,
    source: types.Janet,
) HeaderResult {
    const symbolmap = getFieldByName(source, "symbolmap");
    var items: ?[*]const types.Janet = null;
    var length: i32 = 0;
    if (args_core.indexedView(symbolmap, &items, &length) == 0) unreachable;
    const definition = funcdef(assembler);
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        const entry = items.?[@intCast(index)];
        if (kind.checkType(entry, constants.JANET_TUPLE) == 0) return headerFailure("expected tuple");
        const tuple = wrap.toTuple(entry);
        const birth_pc: u32 = if (kind.checkType(tuple[0], constants.JANET_KEYWORD) != 0 and
            utils.cstrcmp(wrap.toKeyword(tuple[0]), "upvalue") == 0)
            maximum_u32
        else if (args_core.checkint(tuple[0]) != 0)
            @bitCast(integerValue(tuple[0]))
        else
            return headerFailure("expected integer");
        if (args_core.checkint(tuple[1]) == 0) return headerFailure("expected integer");
        if (args_core.checkint(tuple[2]) == 0) return headerFailure("expected integer");
        if (kind.checkType(tuple[3], constants.JANET_SYMBOL) == 0) return headerFailure("expected symbol");
        definition.*.symbolmap.?[@intCast(index)] = .{
            .birth_pc = birth_pc,
            .death_pc = @bitCast(integerValue(tuple[1])),
            .slot_index = @bitCast(integerValue(tuple[2])),
            .symbol = wrap.toSymbol(tuple[3]),
        };
    }
    return headerSuccess();
}

pub fn fillSymbolmap(
    assembler: ?*anyopaque,
    source: types.Janet,
) callconv(.c) HeaderResult {
    return janet_zig_asm_fill_symbolmapImpl(assembler, source);
}

pub fn scanEnvironments(
    _: ?*anyopaque,
    source: types.Janet,
) callconv(.c) BytecodeResult {
    const environments = getFieldByName(source, "environments");
    var items: ?[*]const types.Janet = null;
    var length: i32 = 0;
    if (args_core.indexedView(environments, &items, &length) == 0) {
        return bytecodeSuccess(-1);
    }
    return bytecodeSuccess(length);
}

pub fn fillEnvironments(
    assembler: ?*anyopaque,
    source: types.Janet,
) callconv(.c) HeaderResult {
    const environments = getFieldByName(source, "environments");
    var items: ?[*]const types.Janet = null;
    var length: i32 = 0;
    if (args_core.indexedView(environments, &items, &length) == 0) unreachable;
    const definition = funcdef(assembler);
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        const val = items.?[@intCast(index)];
        if (args_core.checkint(val) == 0) return headerFailure("expected integer");
        definition.*.environments.?[@intCast(index)] = integerValue(val);
    }
    return headerSuccess();
}

pub fn finalize(assembler: ?*anyopaque) HeaderResult {
    const definition = funcdef(assembler);
    const verify_status = verify.verify(definition);
    if (verify_status != 0) {
        return .{
            .error_message = invalidError(verify_status),
            .indexed_error = 0,
        };
    }
    janet_def_addflags(definition);
    return headerSuccess();
}

pub fn scanDefs(source: types.Janet) BytecodeResult {
    var definitions = getFieldByName(source, "closures");
    if (kind.checkType(definitions, constants.JANET_NIL) != 0) {
        definitions = getFieldByName(source, "defs");
    }
    var items: ?[*]const types.Janet = null;
    var length: i32 = 0;
    if (args_core.indexedView(definitions, &items, &length) == 0) {
        return bytecodeSuccess(0);
    }
    return bytecodeSuccess(length);
}

pub fn defAt(source: types.Janet, index: i32) types.Janet {
    var definitions = getFieldByName(source, "closures");
    if (kind.checkType(definitions, constants.JANET_NIL) != 0) {
        definitions = getFieldByName(source, "defs");
    }
    var items: ?[*]const types.Janet = null;
    var length: i32 = 0;
    if (args_core.indexedView(definitions, &items, &length) == 0) unreachable;
    return items.?[@intCast(index)];
}

pub fn registerDef(
    assembler: ?*anyopaque,
    source: types.Janet,
    index: i32,
) callconv(.c) void {
    const name = getFieldByName(source, "name");
    if (kind.checkType(name, constants.JANET_NIL) == 0) {
        const definitions = argumentTable(assembler, constants.JANET_OAT_FUNCDEF).?;
        tables.put(definitions, name, janet_c_asm_wrap_integer(index));
    }
}

pub fn scanBytecode(
    assembler: ?*anyopaque,
    source: types.Janet,
) callconv(.c) BytecodeResult {
    var items: ?[*]const types.Janet = null;
    var length: i32 = 0;
    if (args_core.indexedView(source, &items, &length) == 0) {
        return bytecodeFailure("bytecode expected", true, 0);
    }
    const labels = argumentTable(assembler, constants.JANET_OAT_LABEL).?;
    var bytecode_length: i32 = 0;
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        const instruction = items.?[@intCast(index)];
        if (kind.checkType(instruction, constants.JANET_KEYWORD) != 0) {
            tables.put(labels, instruction, janet_c_asm_wrap_integer(bytecode_length));
        } else if (kind.checkType(instruction, constants.JANET_TUPLE) != 0) {
            bytecode_length += 1;
        } else {
            return bytecodeFailure("expected assembly instruction", true, index);
        }
    }
    return bytecodeSuccess(bytecode_length);
}

pub fn fillBytecode(
    assembler: ?*anyopaque,
    source: types.Janet,
) callconv(.c) BytecodeResult {
    var items: ?[*]const types.Janet = null;
    var length: i32 = 0;
    if (args_core.indexedView(source, &items, &length) == 0) unreachable;
    const definition = funcdef(assembler);
    setBytecodeCount(assembler, 0);
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        const instruction = items.?[@intCast(index)];
        if (kind.checkType(instruction, constants.JANET_KEYWORD) != 0) continue;
        const tuple = wrap.toTuple(instruction);
        const encoded = if (types.tupleHead(tuple).length == 0) success(0) else zigAsmEncode(assembler, tuple);
        if (encoded.error_message != null) {
            return .{
                .count = bytecodeCount(assembler),
                .error_message = encoded.error_message,
                .indexed_error = encoded.indexed_error,
                .error_index = index,
            };
        }
        const count = bytecodeCount(assembler);
        definition.*.bytecode.?[@intCast(count)] = encoded.instruction;
        setBytecodeCount(assembler, count + 1);
    }
    return bytecodeSuccess(bytecodeCount(assembler));
}

pub fn zigAsmEncode(
    assembler: ?*anyopaque,
    arguments: [*]const types.Janet,
) callconv(.c) EncodeResult {
    if (!hasLengthAtLeast(arguments, 1)) return success(0);
    if (kind.checkType(arguments[0], constants.JANET_SYMBOL) == 0) {
        return indexedFailure("expected symbol in assembly instruction");
    }
    const opcode = findOpcode(wrap.toSymbol(arguments[0])) orelse
        return exactFailure(unknownInstruction(arguments[0]));
    const instruction_type = verify.instructions[opcode];
    var instruction = opcode;
    switch (instruction_type) {
        constants.JINT_0 => {
            if (!hasLength(arguments, 1)) return indexedFailure("expected 0 arguments: (op)");
        },
        constants.JINT_S => {
            if (!hasLength(arguments, 2)) return indexedFailure("expected 1 argument: (op, slot)");
            const argument = packArgument(assembler, constants.JANET_OAT_SLOT, 1, 2, false, arguments[1]);
            if (argument.error_message != null) return argument;
            instruction |= argument.instruction;
        },
        constants.JINT_L => {
            if (!hasLength(arguments, 2)) return indexedFailure("expected 1 argument: (op, label)");
            const argument = packArgument(assembler, constants.JANET_OAT_LABEL, 1, 3, true, arguments[1]);
            if (argument.error_message != null) return argument;
            instruction |= argument.instruction;
        },
        constants.JINT_SS => {
            if (!hasLength(arguments, 3)) return indexedFailure("expected 2 arguments: (op, slot, slot)");
            const first = packArgument(assembler, constants.JANET_OAT_SLOT, 1, 1, false, arguments[1]);
            if (first.error_message != null) return first;
            const second = packArgument(assembler, constants.JANET_OAT_SLOT, 2, 2, false, arguments[2]);
            if (second.error_message != null) return second;
            instruction |= first.instruction | second.instruction;
        },
        constants.JINT_SL => {
            if (!hasLength(arguments, 3)) return indexedFailure("expected 2 arguments: (op, slot, label)");
            const slot = packArgument(assembler, constants.JANET_OAT_SLOT, 1, 1, false, arguments[1]);
            if (slot.error_message != null) return slot;
            const label = packArgument(assembler, constants.JANET_OAT_LABEL, 2, 2, true, arguments[2]);
            if (label.error_message != null) return label;
            instruction |= slot.instruction | label.instruction;
        },
        constants.JINT_ST => {
            if (!hasLength(arguments, 3)) return indexedFailure("expected 2 arguments: (op, slot, type)");
            const slot = packArgument(assembler, constants.JANET_OAT_SLOT, 1, 1, false, arguments[1]);
            if (slot.error_message != null) return slot;
            const value_type = packArgument(assembler, constants.JANET_OAT_TYPE, 2, 2, false, arguments[2]);
            if (value_type.error_message != null) return value_type;
            instruction |= slot.instruction | value_type.instruction;
        },
        constants.JINT_SI, constants.JINT_SU => {
            if (!hasLength(arguments, 3)) return indexedFailure("expected 2 arguments: (op, slot, integer)");
            const slot = packArgument(assembler, constants.JANET_OAT_SLOT, 1, 1, false, arguments[1]);
            if (slot.error_message != null) return slot;
            const immediate = packArgument(
                assembler,
                constants.JANET_OAT_INTEGER,
                2,
                2,
                instruction_type == constants.JINT_SI,
                arguments[2],
            );
            if (immediate.error_message != null) return immediate;
            instruction |= slot.instruction | immediate.instruction;
        },
        constants.JINT_SD => {
            if (!hasLength(arguments, 3)) return indexedFailure("expected 2 arguments: (op, slot, funcdef)");
            const slot = packArgument(assembler, constants.JANET_OAT_SLOT, 1, 1, false, arguments[1]);
            if (slot.error_message != null) return slot;
            const definition = packArgument(assembler, constants.JANET_OAT_FUNCDEF, 2, 2, false, arguments[2]);
            if (definition.error_message != null) return definition;
            instruction |= slot.instruction | definition.instruction;
        },
        constants.JINT_SSS => {
            if (!hasLength(arguments, 4)) return indexedFailure("expected 3 arguments: (op, slot, slot, slot)");
            const first = packArgument(assembler, constants.JANET_OAT_SLOT, 1, 1, false, arguments[1]);
            if (first.error_message != null) return first;
            const second = packArgument(assembler, constants.JANET_OAT_SLOT, 2, 1, false, arguments[2]);
            if (second.error_message != null) return second;
            const third = packArgument(assembler, constants.JANET_OAT_SLOT, 3, 1, false, arguments[3]);
            if (third.error_message != null) return third;
            instruction |= first.instruction | second.instruction | third.instruction;
        },
        constants.JINT_SSI, constants.JINT_SSU => {
            if (!hasLength(arguments, 4)) return indexedFailure("expected 3 arguments: (op, slot, slot, integer)");
            const first = packArgument(assembler, constants.JANET_OAT_SLOT, 1, 1, false, arguments[1]);
            if (first.error_message != null) return first;
            const second = packArgument(assembler, constants.JANET_OAT_SLOT, 2, 1, false, arguments[2]);
            if (second.error_message != null) return second;
            const immediate = packArgument(
                assembler,
                constants.JANET_OAT_INTEGER,
                3,
                1,
                instruction_type == constants.JINT_SSI,
                arguments[3],
            );
            if (immediate.error_message != null) return immediate;
            instruction |= first.instruction | second.instruction | immediate.instruction;
        },
        constants.JINT_SES => {
            if (!hasLength(arguments, 4)) return indexedFailure("expected 3 arguments: (op, slot, environment, envslot)");
            const slot = packArgument(assembler, constants.JANET_OAT_SLOT, 1, 1, false, arguments[1]);
            if (slot.error_message != null) return slot;
            const environment = packArgument(assembler, constants.JANET_OAT_ENVIRONMENT, 0, 1, false, arguments[2]);
            if (environment.error_message != null) return environment;
            const parent = parentForEnvironment(assembler, environment.instruction) orelse
                return indexedFailure("invalid environment index");
            const environment_slot = packArgument(parent, constants.JANET_OAT_SLOT, 3, 1, false, arguments[3]);
            if (environment_slot.error_message != null) return environment_slot;
            instruction |= slot.instruction | (environment.instruction << 16) | environment_slot.instruction;
        },
        constants.JINT_SC => {
            if (!hasLength(arguments, 3)) return indexedFailure("expected 2 arguments: (op, slot, constant)");
            const slot = packArgument(assembler, constants.JANET_OAT_SLOT, 1, 1, false, arguments[1]);
            if (slot.error_message != null) return slot;
            const constant = packArgument(assembler, constants.JANET_OAT_CONSTANT, 2, 2, false, arguments[2]);
            if (constant.error_message != null) return constant;
            instruction |= slot.instruction | constant.instruction;
        },
        else => return indexedFailure("unknown instruction layout"),
    }
    return success(instruction);
}

fn packArgument(
    assembler: ?*anyopaque,
    argument_type: i32,
    byte_index: u5,
    byte_count: i32,
    signed: bool,
    val: types.Janet,
) EncodeResult {
    const resolved = resolveArgument(assembler, argument_type, val);
    if (resolved.error_message != null) return exactFailure(resolved.error_message);
    const bit_count: u5 = @intCast(byte_count * 8);
    const maximum: i32 = (@as(i32, 1) << (bit_count - @intFromBool(signed))) - 1;
    const minimum: i32 = if (signed) -maximum - 1 else 0;
    if (resolved.value < minimum) {
        return exactFailure(argumentBoundsError(val, byte_count, 0));
    }
    if (resolved.value > maximum) {
        return exactFailure(argumentBoundsError(val, byte_count, 1));
    }
    const bits: u32 = @bitCast(resolved.value);
    return success(bits << (byte_index * 8));
}

fn resolveArgument(assembler: ?*anyopaque, argument_type: i32, val: types.Janet) ResolvedArgument {
    const table = argumentTable(assembler, argument_type);
    var result: i32 = -1;
    switch (kind.typeOf(val)) {
        constants.JANET_NUMBER => {
            const number = wrap.toNumber(val);
            if (number < minimum_i32_float or number > maximum_i32_float or @trunc(number) != number) {
                return resolutionFailure(val, 0);
            }
            result = @intFromFloat(number);
        },
        constants.JANET_TUPLE => {
            if (argument_type != constants.JANET_OAT_TYPE) return resolutionFailure(val, 0);
            const tuple = wrap.toTuple(val);
            result = 0;
            var index: i32 = 0;
            while (index < types.tupleHead(tuple).length) : (index += 1) {
                const part = resolveArgument(assembler, constants.JANET_OAT_SIMPLETYPE, tuple[@intCast(index)]);
                if (part.error_message != null) return part;
                result |= part.value;
            }
        },
        constants.JANET_KEYWORD => {
            if (table != null and argument_type == constants.JANET_OAT_LABEL) {
                const found = tables.get(table.?, val);
                if (kind.checkType(found, constants.JANET_NUMBER) == 0) return resolutionFailure(val, 0);
                result = @intFromFloat(wrap.toNumber(found));
                result -= bytecodeCount(assembler);
            } else if (argument_type == constants.JANET_OAT_TYPE or argument_type == constants.JANET_OAT_SIMPLETYPE) {
                result = findTypeMask(wrap.toKeyword(val)) orelse return resolutionFailure(val, 1);
            } else {
                return resolutionFailure(val, 0);
            }
        },
        constants.JANET_SYMBOL => {
            const argument_table = table orelse return resolutionFailure(val, 0);
            const found = tables.get(argument_table, val);
            if (kind.checkType(found, constants.JANET_NUMBER) == 0) return resolutionFailure(val, 2);
            result = @intFromFloat(wrap.toNumber(found));
            if (argument_type == constants.JANET_OAT_ENVIRONMENT and result == -1) {
                result = addEnvironment(assembler, val);
                if (result < -1) return resolutionFailure(val, 3);
            }
        },
        else => return resolutionFailure(val, 0),
    }
    if (argument_type == constants.JANET_OAT_SLOT) {
        const definition = funcdef(assembler);
        if (result >= definition.*.slotcount) definition.*.slotcount = result + 1;
    }
    return .{ .value = result };
}

fn resolutionFailure(val: types.Janet, failure: i32) ResolvedArgument {
    return .{ .value = -1, .error_message = resolutionError(val, failure) };
}

fn hasLength(arguments: [*]const types.Janet, expected: i32) bool {
    return types.tupleHead(arguments).length == expected;
}

fn hasLengthAtLeast(arguments: [*]const types.Janet, minimum: i32) bool {
    return types.tupleHead(arguments).length >= minimum;
}

fn findOpcode(name: [*:0]const u8) ?u32 {
    var lower: usize = 0;
    var upper: usize = opcodes.len;
    while (lower < upper) {
        const middle = lower + (upper - lower) / 2;
        const comparison = utils.cstrcmp(name, opcodes[middle].name);
        if (comparison == 0) return opcodes[middle].opcode;
        if (comparison < 0) {
            upper = middle;
        } else {
            lower = middle + 1;
        }
    }
    return null;
}

fn findTypeMask(name: [*:0]const u8) ?i32 {
    var lower: usize = 0;
    var upper: usize = type_aliases.len;
    while (lower < upper) {
        const middle = lower + (upper - lower) / 2;
        const comparison = utils.cstrcmp(name, type_aliases[middle].name);
        if (comparison == 0) return type_aliases[middle].mask;
        if (comparison < 0) {
            upper = middle;
        } else {
            lower = middle + 1;
        }
    }
    return null;
}

fn success(instruction: u32) EncodeResult {
    return .{ .instruction = instruction, .error_message = null, .indexed_error = 0 };
}

fn indexedFailure(message: [*:0]const u8) EncodeResult {
    return .{ .instruction = 0, .error_message = message, .indexed_error = 1 };
}

fn exactFailure(message: ?[*:0]const u8) EncodeResult {
    return .{ .instruction = 0, .error_message = message, .indexed_error = 0 };
}

fn bytecodeSuccess(count: i32) BytecodeResult {
    return .{ .count = count, .error_message = null, .indexed_error = 0, .error_index = -1 };
}

fn bytecodeFailure(message: [*:0]const u8, indexed: bool, index: i32) BytecodeResult {
    return .{
        .count = 0,
        .error_message = message,
        .indexed_error = @intFromBool(indexed),
        .error_index = index,
    };
}

fn headerFailure(message: [*:0]const u8) HeaderResult {
    return .{ .error_message = message, .indexed_error = 1 };
}

fn headerSuccess() HeaderResult {
    return .{ .error_message = null, .indexed_error = 0 };
}

fn integerValue(val: types.Janet) i32 {
    return @intFromFloat(wrap.toNumber(val));
}

const minimum_i32_float: f64 = -2147483648.0;
const maximum_i32_float: f64 = 2147483647.0;
const maximum_u32: u32 = 0xffffffff;
