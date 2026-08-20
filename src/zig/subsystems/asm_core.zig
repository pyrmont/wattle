//! The assembler's driver, and the first of Janet's three `setjmp` sites to
//! disappear.
//!
//! Phase 5 took the assembler's encoding, decoding and disassembly; what stayed
//! behind was the part that holds state and the part that fails. This is both:
//! the `JanetAssembler` record, the environment chain, the per-field
//! orchestration in `janet_asm1`, and the error escape that until now was a
//! `jmp_buf` with a parent chain hanging off it.
//!
//! ## Why this jump goes first, and why it is not a Janet signal
//!
//! `asm.c`'s escape has nothing to do with `janet_vm.signal_buf`. It is a
//! private `setjmp` in `janet_asm1`, reached by `janet_asm_error` from anywhere
//! inside one assembly, and its only job is to abandon a half-built funcdef and
//! report a message. That makes it the one jump in the runtime that an ordinary
//! Zig error replaces outright, with no bridge and no C face: `janet_asm`
//! already returns a `JanetAssembleResult` rather than raising, so the
//! perimeter never changes shape.
//!
//! So the error set here is local — `AsmError`, one member — rather than
//! `raise.Error`. Nothing in this file publishes a signal or touches
//! `janet_vm`, and borrowing the runtime's error would suggest otherwise.
//!
//! ## The parent chain collapses into ordinary propagation
//!
//! A nested assembly — a `:defs` entry — is `janet_asm1` calling itself with
//! the outer assembler as `parent`. In C the child's failure jumps *into the
//! parent's handler*, having first copied its message across:
//!
//! ```c
//! if (NULL != a.parent) {
//!     janet_asm_deinit(&a);
//!     a.parent->errmessage = a.errmessage;
//!     janet_asm_longjmp(a.parent);
//! }
//! ```
//!
//! That makes the parent's own check on the child's result — `if (subres.status
//! != JANET_ASSEMBLE_OK) janet_asm_errorv(&a, subres.error);` — **unreachable
//! whenever there is a parent**, which is always, since that branch only runs
//! for a nested call. Here the child returns its result, the parent's check is
//! the live path, and the message reaches the top by being handed up one frame
//! at a time. Same message, same status, one mechanism instead of two.
//!
//! ## What `defer` does and does not buy
//!
//! The four tables an assembler owns are released by `defer` rather than
//! `errdefer`, because the C releases them on every path and not only on
//! failure. That is the whole reason this port is worth making:
//! `janet_asm_deinit` is called from three places in C — the success path, the
//! nested-error path, and the top-level error path — and from one here.
//!
//! It does **not** make the file jump-proof, and the marker is deliberately
//! absent rather than forgotten. A Janet panic can still cross these frames:
//! `janet_formatc` renders `%v`, which runs an abstract type's `tostring`, and
//! `janet_table_put` hashes a key that may be abstract too. Such a jump skips
//! the `errdefer` and strands the four tables — which is exactly what it does
//! to `janet_asm_deinit` in the C original, so the leak is reproduced rather
//! than introduced. It closes when the formatter and the containers convert,
//! not here.
//!
//! Half of that came true and the leak did not close. Phase 10 Part 4 moved
//! the formatter, and `janet_formatc` still jumps: rendering `%v` runs an
//! abstract type's `tostring` callback, which is a C function pointer whatever
//! language the formatter is written in. It is the containers and the
//! callbacks that have to convert, not the formatter.

const std = @import("std");
const abi = @import("abi");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");
const corefn = @import("corefn");
const arglayer = @import("arglayer.zig");
const lifecycle = @import("lifecycle.zig");
const disasm = @import("disasm.zig");
const asm_encode = @import("asm_encode.zig");
const c = abi.c;

/// The assembler's own failure, and not a Janet signal. One member, because
/// the message travels in the assembler rather than in the error.
const AsmError = error{Assembly};

// ------------------------------------------------- the results Zig hands back

/// `JanetAsmHeaderResult` in `src/core/asm.c`, and `HeaderResult` in
/// `asm_encode.zig`. Declared a third time here rather than shared, because the
/// three are the same three fields and a header for one struct used by one
/// caller each way is more machinery than it saves.
const HeaderResult = extern struct {
    error_message: [*c]const u8,
    indexed_error: i32,
};

/// `JanetAsmBytecodeResult`.
const BytecodeResult = extern struct {
    count: i32,
    error_message: [*c]const u8,
    indexed_error: i32,
    error_index: i32,
};

extern fn janet_zig_asm_parse_header(assembler: ?*anyopaque, source: c.Janet) callconv(.c) HeaderResult;
extern fn janet_zig_asm_parse_slots(assembler: ?*anyopaque, source: c.Janet) callconv(.c) HeaderResult;
extern fn janet_zig_asm_scan_constants(assembler: ?*anyopaque, source: c.Janet) callconv(.c) BytecodeResult;
extern fn janet_zig_asm_fill_constants(assembler: ?*anyopaque, source: c.Janet) callconv(.c) HeaderResult;
extern fn janet_zig_asm_scan_sourcemap(assembler: ?*anyopaque, source: c.Janet) callconv(.c) BytecodeResult;
extern fn janet_zig_asm_fill_sourcemap(assembler: ?*anyopaque, source: c.Janet) callconv(.c) HeaderResult;
extern fn janet_zig_asm_scan_symbolmap(assembler: ?*anyopaque, source: c.Janet) callconv(.c) BytecodeResult;
extern fn janet_zig_asm_fill_symbolmap(assembler: ?*anyopaque, source: c.Janet) callconv(.c) HeaderResult;
extern fn janet_zig_asm_scan_environments(assembler: ?*anyopaque, source: c.Janet) callconv(.c) BytecodeResult;
extern fn janet_zig_asm_fill_environments(assembler: ?*anyopaque, source: c.Janet) callconv(.c) HeaderResult;
extern fn janet_zig_asm_finalize(assembler: ?*anyopaque) callconv(.c) HeaderResult;
extern fn janet_zig_asm_scan_defs(source: c.Janet) callconv(.c) BytecodeResult;
extern fn janet_zig_asm_def_at(source: c.Janet, index: i32) callconv(.c) c.Janet;
extern fn janet_zig_asm_register_def(assembler: ?*anyopaque, source: c.Janet, index: i32) callconv(.c) void;
extern fn janet_zig_asm_scan_bytecode(assembler: ?*anyopaque, source: c.Janet) callconv(.c) BytecodeResult;
extern fn janet_zig_asm_fill_bytecode(assembler: ?*anyopaque, source: c.Janet) callconv(.c) BytecodeResult;

// ------------------------------------------------------------ the assembler

/// `JanetAssembler`, minus the `jmp_buf`.
///
/// The layout is nobody's business but this file's: `asm_encode.zig` reaches an
/// assembler through `?*anyopaque` and the fourteen accessors below, which is
/// the seam Phase 5 drew and which this increment does not move.
const Assembler = struct {
    parent: ?*Assembler,
    def: *c.JanetFuncDef,
    errmessage: [*c]const u8,
    errindex: i32,

    environments_capacity: i32,
    defs_capacity: i32,
    bytecode_count: i32,

    name: c.Janet,
    labels: c.JanetTable,
    slots: c.JanetTable,
    envs: c.JanetTable,
    defs: c.JanetTable,

    fn init(self: *Assembler, parent: ?*Assembler, def: *c.JanetFuncDef) void {
        self.* = .{
            .parent = parent,
            .def = def,
            .errmessage = null,
            .errindex = 0,
            .environments_capacity = 0,
            .defs_capacity = 0,
            .bytecode_count = 0,
            .name = c.janet_wrap_nil(),
            .labels = undefined,
            .slots = undefined,
            .envs = undefined,
            .defs = undefined,
        };
        // `janet_table_init` returns the table it initialised, which the C
        // ignores at every one of these four call sites.
        _ = c.janet_table_init(&self.labels, 0);
        _ = c.janet_table_init(&self.slots, 0);
        _ = c.janet_table_init(&self.envs, 0);
        _ = c.janet_table_init(&self.defs, 0);
    }

    /// Release the four tables. The C original notes that it does not touch the
    /// parents, and neither does this: a parent is released by its own frame.
    fn deinit(self: *Assembler) void {
        c.janet_table_deinit(&self.slots);
        c.janet_table_deinit(&self.labels);
        c.janet_table_deinit(&self.envs);
        c.janet_table_deinit(&self.defs);
    }

    /// `janet_asm_error`. The index suffix is appended exactly when `errindex`
    /// is non-negative, which is how a bytecode fault names its instruction and
    /// a header fault does not.
    fn fail(self: *Assembler, message: [*c]const u8) AsmError {
        self.errmessage = if (self.errindex < 0)
            pp_format.formatcReported("%s", .{message})
        else
            pp_format.formatcReported("%s, instruction %d", .{ message, self.errindex });
        return error.Assembly;
    }

    /// `janet_asm_errorv`. The message is already a Janet string and is taken
    /// unaltered, index or no index.
    fn failv(self: *Assembler, message: [*c]const u8) AsmError {
        self.errmessage = message;
        return error.Assembly;
    }

    /// Report whichever way the callee asked for. Every `janet_zig_asm_*` entry
    /// point answers with a message and a flag saying whether it wants the
    /// instruction index appended, and every one of `janet_asm1`'s call sites
    /// spelled the same two-line test out. It is one function here.
    fn report(self: *Assembler, message: [*c]const u8, indexed: bool) AsmError {
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
fn addEnv(a: *Assembler, envname: c.Janet) i32 {
    if (c.janet_equals(a.name, envname) != 0) return -1;
    const check = c.janet_table_get(&a.envs, envname);
    if (c.janet_checktype(check, c.JANET_NUMBER) != 0) {
        return @intFromFloat(c.janet_unwrap_number(check));
    }
    const parent = a.parent orelse return -2;
    const res = addEnv(parent, envname);
    if (res < -1) return res;

    const def = a.def;
    const envindex = def.environments_length;
    c.janet_table_put(&a.envs, envname, c.janet_wrap_number(@floatFromInt(envindex)));
    if (envindex >= a.environments_capacity) {
        const newcap = 2 * envindex;
        def.environments = @ptrCast(@alignCast(c.janet_realloc(
            @ptrCast(def.environments),
            @as(usize, @intCast(newcap)) * @sizeOf(i32),
        ) orelse c.janet_zig_out_of_memory()));
        a.environments_capacity = newcap;
    }
    def.environments[@intCast(envindex)] = res;
    def.environments_length = envindex + 1;
    return envindex;
}

/// `janet_get1`. A lookup that answers nil for anything that is not a table or
/// a struct, which is what lets `janet_asm1` ask for a field of a source it has
/// not yet validated.
fn getField(ds: c.Janet, key: c.Janet) c.Janet {
    return switch (c.janet_type(ds)) {
        c.JANET_TABLE => c.janet_table_get(c.janet_unwrap_table(ds), key),
        c.JANET_STRUCT => c.janet_struct_get(c.janet_unwrap_struct(ds), key),
        else => c.janet_wrap_nil(),
    };
}

// --------------------------------------------------------- the field accessors

// The seam `asm_encode.zig` reaches an assembler through. Fourteen accessors
// over an opaque pointer, unchanged in name and signature from the C ones they
// replace, so the encode layer does not learn which side it is talking to.

inline fn asmOf(context: ?*anyopaque) *Assembler {
    return @ptrCast(@alignCast(context.?));
}

export fn janet_c_asm_argument_table(context: ?*anyopaque, argument_type: i32) callconv(.c) ?*c.JanetTable {
    const a = asmOf(context);
    return switch (argument_type) {
        c.JANET_OAT_SLOT => &a.slots,
        c.JANET_OAT_ENVIRONMENT => &a.envs,
        c.JANET_OAT_LABEL => &a.labels,
        c.JANET_OAT_FUNCDEF => &a.defs,
        else => null,
    };
}

export fn janet_c_asm_funcdef(context: ?*anyopaque) callconv(.c) *c.JanetFuncDef {
    return asmOf(context).def;
}

export fn janet_c_asm_set_name(context: ?*anyopaque, name: c.Janet) callconv(.c) void {
    asmOf(context).name = name;
}

export fn janet_c_asm_bytecode_count(context: ?*anyopaque) callconv(.c) i32 {
    return asmOf(context).bytecode_count;
}

export fn janet_c_asm_set_bytecode_count(context: ?*anyopaque, count: i32) callconv(.c) void {
    asmOf(context).bytecode_count = count;
}

export fn janet_c_asm_add_environment(context: ?*anyopaque, name: c.Janet) callconv(.c) i32 {
    return addEnv(asmOf(context), name);
}

/// Walk `environment + 1` links up the parent chain. The `+ 1` is the C
/// original's and is load-bearing: environment 0 means the immediate parent,
/// not the assembler itself.
export fn janet_c_asm_parent_for_environment(context: ?*anyopaque, environment: u32) callconv(.c) ?*anyopaque {
    var a: ?*Assembler = asmOf(context);
    var remaining = environment + 1;
    while (remaining > 0) : (remaining -= 1) {
        a = (a orelse return null).parent;
        if (a == null) return null;
    }
    return a;
}

export fn janet_c_asm_argument_bounds_error(x: c.Janet, nbytes: i32, too_large: i32) callconv(.c) [*c]const u8 {
    // Through a sentinel pointer rather than a slice, because `%s` renders a
    // NUL-terminated run of bytes and a slice is not one.
    const plural: [*c]const u8 = if (nbytes > 1) "s" else "";
    // Two calls rather than one: the format string is `comptime` now, so a
    // runtime `if` cannot choose between two of them.
    return if (too_large != 0)
        pp_format.formatcReported("instruction argument %v is too large, must be %d byte%s", .{ x, nbytes, plural })
    else
        pp_format.formatcReported("instruction argument %v is too small, must be %d byte%s", .{ x, nbytes, plural });
}

export fn janet_c_asm_unknown_instruction(value: c.Janet) callconv(.c) [*c]const u8 {
    return pp_format.formatcReported("unknown instruction %v", .{value});
}

export fn janet_c_asm_resolution_error(value: c.Janet, kind: i32) callconv(.c) [*c]const u8 {
    return switch (kind) {
        1 => pp_format.formatcReported("unknown type %v", .{value}),
        2 => pp_format.formatcReported("unknown name %v", .{value}),
        3 => pp_format.formatcReported("unknown environment %v", .{value}),
        else => pp_format.formatcReported("error parsing instruction argument %v", .{value}),
    };
}

export fn janet_c_asm_get_field(source: c.Janet, name: [*c]const u8) callconv(.c) c.Janet {
    return getField(source, c.janet_ckeywordv(name));
}

export fn janet_c_asm_invalid_error(status: i32) callconv(.c) [*c]const u8 {
    return pp_format.formatcReported("invalid assembly (%d)", .{status});
}

// ---------------------------------------------------------------- the driver

fn allocate(comptime T: type, count: i32) [*]T {
    const bytes = @sizeOf(T) * @as(usize, @intCast(count));
    return @ptrCast(@alignCast(c.janet_malloc(bytes) orelse c.janet_zig_out_of_memory()));
}

/// The body of one assembly, in the C original's order. Every step either
/// succeeds or returns `error.Assembly` with the message already in the
/// assembler; the caller releases the tables.
fn assemble(a: *Assembler, source: c.Janet, flags: c_int) AsmError!void {
    const def = a.def;

    {
        const header = janet_zig_asm_parse_header(a, source);
        if (header.error_message != null) return a.report(header.error_message, header.indexed_error != 0);
    }

    {
        const slots = janet_zig_asm_parse_slots(a, source);
        if (slots.error_message != null) return a.report(slots.error_message, slots.indexed_error != 0);
        const constants = janet_zig_asm_scan_constants(a, source);
        def.constants_length = constants.count;
        if (constants.count > 0) {
            def.constants = allocate(c.Janet, constants.count);
            _ = janet_zig_asm_fill_constants(a, source);
        } else {
            def.constants = null;
        }
    }

    // Sub funcdefs. The recursion is what the parent chain exists for, and the
    // child's result is checked here rather than jumped past -- see the note at
    // the head of this file about the branch that was unreachable in C.
    {
        const definitions = janet_zig_asm_scan_defs(source);
        var i: i32 = 0;
        while (i < definitions.count) : (i += 1) {
            const subsource = janet_zig_asm_def_at(source, i);
            const subdef = try asmNested(a, subsource, flags);
            janet_zig_asm_register_def(a, subsource, def.defs_length);
            const newlen = def.defs_length + 1;
            if (a.defs_capacity < newlen) {
                def.defs = @ptrCast(@alignCast(c.janet_realloc(
                    @ptrCast(def.defs),
                    @as(usize, @intCast(newlen)) * @sizeOf(*c.JanetFuncDef),
                ) orelse c.janet_zig_out_of_memory()));
                a.defs_capacity = newlen;
            }
            def.defs[@intCast(def.defs_length)] = subdef;
            def.defs_length = newlen;
        }
    }

    {
        const x = getField(source, c.janet_ckeywordv("bytecode"));
        var bytecode = janet_zig_asm_scan_bytecode(a, x);
        if (bytecode.error_message != null) {
            a.errindex = bytecode.error_index;
            return a.report(bytecode.error_message, bytecode.indexed_error != 0);
        }
        def.bytecode_length = bytecode.count;
        def.bytecode = allocate(u32, bytecode.count);
        bytecode = janet_zig_asm_fill_bytecode(a, x);
        if (bytecode.error_message != null) {
            a.errindex = bytecode.error_index;
            return a.report(bytecode.error_message, bytecode.indexed_error != 0);
        }
    }

    // Everything from here reports without an instruction index.
    a.errindex = -1;

    {
        const sourcemap = janet_zig_asm_scan_sourcemap(a, source);
        if (sourcemap.error_message != null) return a.fail(sourcemap.error_message);
        if (sourcemap.count > 0) {
            def.sourcemap = allocate(c.JanetSourceMapping, sourcemap.count);
            const filled = asm_encode.janet_zig_asm_fill_sourcemapImpl(a, source);
            if (filled.error_message != null) return a.fail(filled.error_message);
        }
    }

    def.symbolmap = null;
    def.symbolmap_length = 0;
    {
        const symbolmap = janet_zig_asm_scan_symbolmap(a, source);
        if (symbolmap.count > 0) {
            def.symbolmap_length = symbolmap.count;
            def.symbolmap = allocate(c.JanetSymbolMap, symbolmap.count);
            const filled = asm_encode.janet_zig_asm_fill_symbolmapImpl(a, source);
            if (filled.error_message != null) return a.fail(filled.error_message);
        }
    }
    if (def.symbolmap_length != 0) def.flags |= c.JANET_FUNCDEF_FLAG_HASSYMBOLMAP;

    {
        const environments = janet_zig_asm_scan_environments(a, source);
        if (environments.count >= 0) {
            def.environments_length = environments.count;
            if (environments.count > 0) {
                def.environments = @ptrCast(@alignCast(c.janet_realloc(
                    @ptrCast(def.environments),
                    @as(usize, @intCast(environments.count)) * @sizeOf(i32),
                ) orelse c.janet_zig_out_of_memory()));
            }
            const filled = janet_zig_asm_fill_environments(a, source);
            if (filled.error_message != null) return a.fail(filled.error_message);
        }
    }

    {
        const finalized = janet_zig_asm_finalize(a);
        if (finalized.error_message != null) return a.failv(finalized.error_message);
    }
}

/// One nested assembly, for a `:defs` entry. Reports its parent's message on
/// the way out, which is the propagation C did with a jump.
fn asmNested(parent: *Assembler, source: c.Janet, flags: c_int) AsmError!*c.JanetFuncDef {
    const result = asm1(parent, source, flags);
    if (result.status != c.JANET_ASSEMBLE_OK) return parent.failv(result.@"error");
    return result.funcdef;
}

/// `janet_asm1`. Owns one assembler, and is the frame the whole of an assembly
/// unwinds to.
fn asm1(parent: ?*Assembler, source: c.Janet, flags: c_int) c.JanetAssembleResult {
    var a: Assembler = undefined;
    a.init(parent, c.janet_funcdef_alloc());
    defer a.deinit();

    assemble(&a, source, flags) catch {
        return .{
            .funcdef = null,
            .@"error" = a.errmessage,
            .status = c.JANET_ASSEMBLE_ERROR,
        };
    };
    return .{
        .funcdef = a.def,
        .@"error" = null,
        .status = c.JANET_ASSEMBLE_OK,
    };
}

/// `janet_asm`. The public entry, and unchanged in shape: it reports a result
/// rather than raising, which is why removing the jump underneath it needs no
/// C face and changes nothing a caller can see.
export fn janet_asm(source: c.Janet, flags: c_int) callconv(.c) c.JanetAssembleResult {
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

fn cfunAsm(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_ASM);
    try arglayer.fixarity(argc, 1);
    const res = janet_asm(argv[0], 0);
    if (res.status != c.JANET_ASSEMBLE_OK) {
        const message = res.@"error" orelse c.janet_cstring("invalid assembly");
        return raise.panicv(c.janet_wrap_string(message));
    }
    return c.janet_wrap_function(c.janet_thunk(res.funcdef));
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

fn cfunDisasm(argc: i32, argv: [*c]c.Janet) raise.Raising(c.Janet) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_ASM);
    try arglayer.arity(argc, 1, 2);
    const f = try arglayer.getFunction(argv, 0);
    if (argc != 2) return disasm.disassembleField(f.*.def, .all);

    const kw = try arglayer.getKeyword(argv, 1);
    for (disasm_fields) |entry| {
        if (c.janet_cstrcmp(kw, entry.name) == 0) {
            return disasm.disassembleField(f.*.def, entry.field);
        }
    }
    return pp_format.panicf("unknown disasm key %v", .{argv[1]});
}

export fn janet_lib_asm(env: *c.JanetTable) callconv(.c) void {
    raise.reported(janet_lib_asmImpl(env));
}

pub fn janet_lib_asmImpl(env: *c.JanetTable) raise.Raising(void) {
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
