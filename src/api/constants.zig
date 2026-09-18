//! Janet's constants, opcodes and flags, owned by Zig.
//!
//! Its own module, below the subsystems. Every importer is under
//! `src/runtime/`, apart from `src/module.zig`, which reads the marshalling
//! flags.
//!
//! A constant is not a declaration the compiler can re-derive. A wrong opcode
//! number produces a working program with wrong behaviour rather than a build
//! failure, so every value here is written out. `helpers.promoteIntLiteral` is
//! kept for the same reason: it is C's integer-literal promotion, and the type
//! it yields depends on the target's `long`.
//!
//! Every value here is invariant across the configurations the build offers,
//! except the eight computed from `@import("config")` below, which follow a
//! `-D` flag.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Project imports
// ==========================================================================

const config = @import("config");
const repr = @import("repr");

// ==========================================================================
// Constants
// ==========================================================================

pub const JANET_BUFFER_FLAG_NO_REALLOC = helpers.promoteIntLiteral(c_int, 0x10000, .hex);

/// The three bits above, or'd. A module and the runtime each put this in an
/// `abi.BuildConfig`, and `src/runtime/env.zig` compares the two at load, so a
/// module built under different options fails the load.
pub const JANET_CURRENT_CONFIG_BITS: c_int =
    JANET_SINGLE_THREADED_BIT | JANET_NANBOX_BIT | JANET_NANBOX_POINTER_SHIFT_BITS;

/// The compiler's three lint levels, in ascending strictness.
/// `src/runtime/compiler.zig` declares an enum whose members take these values.
pub const JANET_C_LINT_RELAXED: c_int = 0;
pub const JANET_C_LINT_NORMAL: c_int = 1;
pub const JANET_C_LINT_STRICT: c_int = 2;

/// The two flags a definition may set, as single bits in ascending order.
/// `src/runtime/compiler.zig` and `src/runtime/compiler/specials.zig` read
/// them.
pub const JANET_DEFFLAG_NO_SHADOWCHECK = @as(c_int, 1);
pub const JANET_DEFFLAG_NO_UNUSED = @as(c_int, 2);

/// The three error kinds a `do` reports, as single bits in ascending order.
/// `src/runtime/env.zig` or's them into the flag word it returns.
pub const JANET_DO_ERROR_RUNTIME = @as(c_int, 0x01);
pub const JANET_DO_ERROR_COMPILE = @as(c_int, 0x02);
pub const JANET_DO_ERROR_PARSE = @as(c_int, 0x04);

/// What a completed event-loop task gives back, numbered in ascending order.
/// `src/runtime/ev.zig` switches on the tag to decide how to build the value a
/// fiber is resumed with, and `src/runtime/os/process.zig` sets a tag.
pub const JANET_EV_TCTAG_NIL = @as(c_int, 0);
pub const JANET_EV_TCTAG_INTEGER = @as(c_int, 1);
pub const JANET_EV_TCTAG_STRING = @as(c_int, 2);
pub const JANET_EV_TCTAG_STRINGF = @as(c_int, 3);
pub const JANET_EV_TCTAG_KEYWORD = @as(c_int, 4);
pub const JANET_EV_TCTAG_ERR_STRING = @as(c_int, 5);
pub const JANET_EV_TCTAG_ERR_STRINGF = @as(c_int, 6);
pub const JANET_EV_TCTAG_ERR_KEYWORD = @as(c_int, 7);
pub const JANET_EV_TCTAG_BOOLEAN = @as(c_int, 8);

/// A fiber's flag word: a mask and a shift for the status field, then three
/// single bits in ascending order. `src/runtime/signal.zig` and
/// `src/runtime/value/fibers.zig` read them.
pub const JANET_FIBER_STATUS_MASK = helpers.promoteIntLiteral(c_int, 0x3F0000, .hex);
pub const JANET_FIBER_STATUS_OFFSET = @as(c_int, 16);
pub const JANET_FIBER_EV_FLAG_CANCELED = helpers.promoteIntLiteral(c_int, 0x10000, .hex);
pub const JANET_FIBER_EV_FLAG_SUSPENDED = helpers.promoteIntLiteral(c_int, 0x20000, .hex);
pub const JANET_FIBER_FLAG_ROOT = helpers.promoteIntLiteral(c_int, 0x40000, .hex);

/// A file handle's flags, as single bits in ascending order.
/// `src/runtime/ev/stream.zig` reads them.
pub const JANET_FILE_WRITE = @as(c_int, 1);
pub const JANET_FILE_READ = @as(c_int, 2);
pub const JANET_FILE_APPEND = @as(c_int, 4);
pub const JANET_FILE_UPDATE = @as(c_int, 8);
pub const JANET_FILE_NOT_CLOSEABLE = @as(c_int, 16);
pub const JANET_FILE_CLOSED = @as(c_int, 32);
pub const JANET_FILE_BINARY = @as(c_int, 64);
pub const JANET_FILE_NONIL = @as(c_int, 512);

/// A stack frame's size in `Value` slots. `src/runtime/vm.zig` and
/// `src/runtime/marsh.zig` subtract it from a stack pointer to reach the frame
/// header.
pub const JANET_FRAME_SIZE = @as(c_int, 4);

/// The tag of each builtin defined with inline bytecode, numbered in
/// ascending order. `src/runtime/env.zig` passes a tag to `quickAsmDef`, and
/// `src/runtime/compiler/specials.zig` reads them.
pub const JANET_FUN_DEBUG = @as(c_int, 1);
pub const JANET_FUN_ERROR = @as(c_int, 2);
pub const JANET_FUN_APPLY = @as(c_int, 3);
pub const JANET_FUN_YIELD = @as(c_int, 4);
pub const JANET_FUN_RESUME = @as(c_int, 5);
pub const JANET_FUN_IN = @as(c_int, 6);
pub const JANET_FUN_PUT = @as(c_int, 7);
pub const JANET_FUN_LENGTH = @as(c_int, 8);
pub const JANET_FUN_ADD = @as(c_int, 9);
pub const JANET_FUN_SUBTRACT = @as(c_int, 10);
pub const JANET_FUN_MULTIPLY = @as(c_int, 11);
pub const JANET_FUN_DIVIDE = @as(c_int, 12);
pub const JANET_FUN_BAND = @as(c_int, 13);
pub const JANET_FUN_BOR = @as(c_int, 14);
pub const JANET_FUN_BXOR = @as(c_int, 15);
pub const JANET_FUN_LSHIFT = @as(c_int, 16);
pub const JANET_FUN_RSHIFT = @as(c_int, 17);
pub const JANET_FUN_RSHIFTU = @as(c_int, 18);
pub const JANET_FUN_BNOT = @as(c_int, 19);
pub const JANET_FUN_GT = @as(c_int, 20);
pub const JANET_FUN_LT = @as(c_int, 21);
pub const JANET_FUN_GTE = @as(c_int, 22);
pub const JANET_FUN_LTE = @as(c_int, 23);
pub const JANET_FUN_EQ = @as(c_int, 24);
pub const JANET_FUN_NEQ = @as(c_int, 25);
pub const JANET_FUN_PROP = @as(c_int, 26);
pub const JANET_FUN_GET = @as(c_int, 27);
pub const JANET_FUN_NEXT = @as(c_int, 28);
pub const JANET_FUN_MODULO = @as(c_int, 29);
pub const JANET_FUN_REMAINDER = @as(c_int, 30);
pub const JANET_FUN_CMP = @as(c_int, 31);
pub const JANET_FUN_CANCEL = @as(c_int, 32);
pub const JANET_FUN_DIVIDE_FLOOR = @as(c_int, 33);

pub const JANET_HASH_KEY_SIZE = @as(c_int, 16);

/// The largest integer a double represents exactly, which is 2^53.
pub const JANET_INTMAX_DOUBLE = @as(f64, 9007199254740992.0);

/// 2^53 as a C integer literal, whose type follows the target's `long`.
pub const JANET_INTMAX_INT64 = helpers.promoteIntLiteral(c_int, 9007199254740992, .decimal);

/// The smallest integer a double represents exactly, which is -2^53.
pub const JANET_INTMIN_DOUBLE = -@as(f64, 9007199254740992.0);

/// The two marshalling flags, as single bits in ascending order.
/// `src/runtime/marsh.zig` reads them out of a marshalling state's flag word,
/// and `module.isUnsafe` reports the first.
pub const JANET_MARSHAL_UNSAFE = helpers.promoteIntLiteral(c_int, 0x20000, .hex);
pub const JANET_MARSHAL_NO_CYCLES = helpers.promoteIntLiteral(c_int, 0x40000, .hex);

/// The two collector bits in a heap block's flag word, in ascending order.
/// `src/runtime/gc/mark.zig` reads them.
pub const JANET_MEM_REACHABLE = @as(c_int, 0x100);
pub const JANET_MEM_DISABLED = @as(c_int, 0x200);

/// `0x0` under the tagged layout, `0x1` otherwise.
pub const JANET_NANBOX_BIT: c_int = if (config.value_repr == .tagged) 0x0 else 0x1;

/// `0x4 << shift` under nanbox-64, and `0` under every other layout.
///
/// The shift lets a target with more than 47 bits of address space still fit
/// a pointer in a NaN-boxed payload: aarch64 that is not Apple, because
/// aarch64 macOS has the same 47-bit userland address space as amd64.
/// `build.zig` owns the predicate and `repr.pointer_shift` is the shift, and
/// this constant reads both and adds nothing, so the three cannot drift.
pub const JANET_NANBOX_POINTER_SHIFT_BITS: c_int =
    if (config.value_repr == .nanbox_64 and repr.pointer_shift != 0)
        @as(c_int, 0x4) << @intCast(repr.pointer_shift)
    else
        0;

/// The pretty printer's three option bits, in ascending order. Nothing under
/// `src/` reads them; `test/pp_pretty.zig` passes them to the printer.
pub const JANET_PRETTY_COLOR = @as(c_int, 1);
pub const JANET_PRETTY_ONELINE = @as(c_int, 2);
pub const JANET_PRETTY_NOTRUNC = @as(c_int, 4);

/// `0x2` in a single-threaded build, `0` otherwise.
pub const JANET_SINGLE_THREADED_BIT: c_int = if (config.single_threaded) 0x2 else 0;

/// The two stack-frame flags, as single bits in ascending order.
/// `src/runtime/debug.zig` reads them.
pub const JANET_STACKFRAME_TAILCALL = @as(c_int, 1);
pub const JANET_STACKFRAME_ENTRANCE = @as(c_int, 2);

/// A stream's flags, as single bits in ascending order.
/// `src/runtime/ev/stream.zig`, `src/runtime/net.zig` and
/// `src/runtime/filewatch.zig` read them.
pub const JANET_STREAM_CLOSED = @as(c_int, 0x1);
pub const JANET_STREAM_SOCKET = @as(c_int, 0x2);
pub const JANET_STREAM_UNREGISTERED = @as(c_int, 0x4);
pub const JANET_STREAM_READABLE = @as(c_int, 0x200);
pub const JANET_STREAM_WRITABLE = @as(c_int, 0x400);
pub const JANET_STREAM_ACCEPTABLE = @as(c_int, 0x800);
pub const JANET_STREAM_UDPSERVER = @as(c_int, 0x1000);
pub const JANET_STREAM_NOT_CLOSEABLE = @as(c_int, 0x2000);
pub const JANET_STREAM_TOCLOSE = helpers.promoteIntLiteral(c_int, 0x10000, .hex);
pub const JANET_STREAM_NODUPS = helpers.promoteIntLiteral(c_int, 0x20000, .hex);

/// How a stack trace names a location, numbered in ascending order.
/// `src/runtime/debug.zig` reads them.
pub const JANET_TRACE_LOC_NONE: c_int = 0;
pub const JANET_TRACE_LOC_SOURCEMAP: c_int = 1;
pub const JANET_TRACE_LOC_PC: c_int = 2;
pub const JANET_TRACE_LOC_CFUN_LINE: c_int = 3;

/// How a stack trace names a frame, numbered in ascending order.
/// `src/runtime/debug.zig` reads them.
pub const JANET_TRACE_NAME_NONE: c_int = 0;
pub const JANET_TRACE_NAME_ANONYMOUS: c_int = 1;
pub const JANET_TRACE_NAME_FUNCTION: c_int = 2;
pub const JANET_TRACE_NAME_CFUNCTION: c_int = 3;
pub const JANET_TRACE_NAME_CFUNCTION_BARE: c_int = 4;

pub const JANET_TUPLE_FLAG_BRACKETCTOR = helpers.promoteIntLiteral(c_int, 0x10000, .hex);

/// `1` under the event loop.
pub const JANET_VM_HAS_EV: c_int = if (config.ev) 1 else 0;

/// `0` when the interpreter does not check for an interrupt between
/// instructions.
pub const JANET_VM_HAS_INTERRUPT: c_int = if (config.interpreter_interrupt) 1 else 0;

/// `1` under networking.
pub const JANET_VM_HAS_NET: c_int = if (config.net) 1 else 0;

/// `1` unless the build is single-threaded.
pub const JANET_VM_THREAD_LOCAL: c_int = if (config.single_threaded) 0 else 1;

/// C's integer-literal promotion, whose result type follows the target's
/// `long`. A literal a C header wrote as an `int` is spelled through it.
const helpers = std.zig.c_translation.helpers;

// ==========================================================================
// Types
// ==========================================================================

/// What the event loop is telling a listener. The callback in an event-loop
/// state is the only consumer and the loop is the only producer, so the
/// vocabulary is closed.
pub const AsyncEvent = enum(u32) {
    init = 0,
    mark = 1,
    deinit = 2,
    close = 3,
    err = 4,
    hup = 5,
    read = 6,
    write = 7,
    complete = 8,
    failed = 9,
};

/// Which half of a stream a listener is waiting on. Two independent bits, so
/// waiting on both is the two set rather than a third value.
pub const AsyncMode = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    _rest: u30 = 0,

    pub const reading: AsyncMode = .{ .read = true };
    pub const writing: AsyncMode = .{ .write = true };
    pub const both: AsyncMode = .{ .read = true, .write = true };
};

/// An instruction's operand shape, which the verifier, the two assembler
/// directions and the disassembler each dispatch on.
///
/// The letters are the C names' and are the operands in order: `s` a slot,
/// `l` a jump label, `t` a type mask, `i` a signed immediate, `u` an unsigned
/// immediate, `d` a subdefinition index, `c` a constant index, `e` an
/// environment index. `zero` is an instruction with no operands.
///
/// Exhaustive. The table in `src/runtime/bytecode/verify.zig` is the only
/// producer, it is built at comptime from a row per opcode, and nothing
/// outside this runtime can supply a value. That is what lets a switch over
/// this type drop its `else => unreachable`.
pub const InstructionType = enum(u8) {
    zero = 0,
    s = 1,
    l = 2,
    ss = 3,
    sl = 4,
    st = 5,
    si = 6,
    sd = 7,
    su = 8,
    sss = 9,
    ssi = 10,
    ssu = 11,
    ses = 12,
    sc = 13,
};

/// Which of the two 64-bit integer abstracts a value is, or neither.
/// `src/runtime/value/ints.zig`'s `isInt` is the only producer.
pub const IntType = enum(u32) {
    none = 0,
    s64 = 1,
    u64 = 2,
};

/// The bytecode's operation, as one type rather than seventy-seven integers.
///
/// The numbers are the bytecode, so each is written out and none is implied by
/// position: an instruction's low byte is this value, a marshalled funcdef
/// includes it, and `disasm` prints its name. The block under Tests asserts
/// every member's number, so a renumbering is a compile error rather than a
/// silently different image.
///
/// Non-exhaustive, for the debugger. Bit 7 of the instruction word is the
/// breakpoint bit: setting it produces a value no arm names, `runVm`'s `_ =>`
/// arm raises `debug`, and that is how a breakpoint stops the loop.
pub const Opcode = enum(u8) {
    noop = 0,
    @"error" = 1,
    typecheck = 2,
    @"return" = 3,
    return_nil = 4,
    add_immediate = 5,
    add = 6,
    subtract_immediate = 7,
    subtract = 8,
    multiply_immediate = 9,
    multiply = 10,
    divide_immediate = 11,
    divide = 12,
    divide_floor = 13,
    modulo = 14,
    remainder = 15,
    band = 16,
    bor = 17,
    bxor = 18,
    bnot = 19,
    shift_left = 20,
    shift_left_immediate = 21,
    shift_right = 22,
    shift_right_immediate = 23,
    shift_right_unsigned = 24,
    shift_right_unsigned_immediate = 25,
    move_far = 26,
    move_near = 27,
    jump = 28,
    jump_if = 29,
    jump_if_not = 30,
    jump_if_nil = 31,
    jump_if_not_nil = 32,
    greater_than = 33,
    greater_than_immediate = 34,
    less_than = 35,
    less_than_immediate = 36,
    equals = 37,
    equals_immediate = 38,
    compare = 39,
    load_nil = 40,
    load_true = 41,
    load_false = 42,
    load_integer = 43,
    load_constant = 44,
    load_upvalue = 45,
    load_self = 46,
    set_upvalue = 47,
    closure = 48,
    push = 49,
    push_2 = 50,
    push_3 = 51,
    push_array = 52,
    call = 53,
    tailcall = 54,
    @"resume" = 55,
    signal = 56,
    propagate = 57,
    in = 58,
    get = 59,
    put = 60,
    get_index = 61,
    put_index = 62,
    length = 63,
    make_array = 64,
    make_buffer = 65,
    make_string = 66,
    make_map = 67,
    make_table = 68,
    make_tuple = 69,
    make_vector = 70,
    greater_than_equal = 71,
    less_than_equal = 72,
    next = 73,
    not_equals = 74,
    not_equals_immediate = 75,
    cancel = 76,
    // Last on purpose, because it is the one opcode already decided to go:
    // there are no bracket tuples in Wattle, and the parser and boot depend
    // on them only until the Janet parser is removed. Here, its deletion is
    // one member and a lower `count`; anywhere else it leaves a hole, which
    // `bytecode/verify.zig`'s table refuses to compile.
    make_bracket_tuple = 77,
    _,

    /// How many opcodes there are: one past the last, and not itself an
    /// opcode. `src/runtime/bytecode/verify.zig`'s type table and
    /// `src/runtime/bytecode.zig`'s name table are both this long.
    pub const count: usize = 78;

    pub inline fn fromWord(word: u32) Opcode {
        return @enumFromInt(@as(u8, @truncate(word)));
    }

    pub inline fn number(self: Opcode) u8 {
        return @intFromEnum(self);
    }
};

/// What an assembly operand names, which decides how the assembler resolves it
/// and which of the assembler's four tables it is looked up in.
///
/// Exhaustive. Every value comes from a `verify.instructions` row or from a
/// literal in `src/runtime/bytecode.zig`, and nothing outside this runtime
/// supplies a value.
pub const OperandKind = enum(u8) {
    slot = 0,
    environment = 1,
    constant = 2,
    integer = 3,
    type = 4,
    simple_type = 5,
    label = 6,
    funcdef = 7,
};

/// A compiled PEG rule's operation, which is the first word of every rule in
/// the compiled program.
///
/// The numbers are the compiled form and are marshalled with it, so each is
/// written out, and the block under Tests asserts every member's number.
/// Non-exhaustive because the word comes out of a `peg` abstract that
/// unmarshalling may have been given from anywhere: `src/runtime/peg.zig`'s
/// verifier is what rejects an unknown rule, and it can do that only if an
/// unknown value is constructible.
pub const PegRule = enum(u32) {
    literal = 0,
    nchar = 1,
    notnchar = 2,
    range = 3,
    set = 4,
    look = 5,
    choice = 6,
    sequence = 7,
    @"if" = 8,
    ifnot = 9,
    not = 10,
    between = 11,
    gettag = 12,
    capture = 13,
    position = 14,
    argument = 15,
    constant = 16,
    accumulate = 17,
    group = 18,
    replace = 19,
    matchtime = 20,
    @"error" = 21,
    drop = 22,
    backmatch = 23,
    to = 24,
    thru = 25,
    lenprefix = 26,
    readint = 27,
    line = 28,
    column = 29,
    unref = 30,
    capture_num = 31,
    sub = 32,
    til = 33,
    split = 34,
    nth = 35,
    only_tags = 36,
    matchsplice = 37,
    debug = 38,
    _,

    /// One past the last rule. `src/runtime/peg.zig`'s verifier checks a rule
    /// word against this bound before dispatching on it.
    pub const count: u32 = 39;

    pub inline fn fromWord(word: u32) PegRule {
        return @enumFromInt(word);
    }

    pub inline fn number(self: PegRule) u32 {
        return @intFromEnum(self);
    }
};

/// The eight temporary registers the compiler can hold at once, as a bit in
/// `RegisterAllocator.regtemps`. Numbered rather than named because the number
/// is the bit, and the emitter picks a register per operand position.
pub const RegisterTemp = enum(u3) {
    t0 = 0,
    t1 = 1,
    t2 = 2,
    t3 = 3,
    t4 = 4,
    t5 = 5,
    t6 = 6,
    t7 = 7,
};

// ==========================================================================
// Tests
// ==========================================================================

comptime {
    // `Opcode` numbers its own members, and this table restates each number. A
    // member added, removed or renumbered fails here until the table changes
    // with it. `count` is asserted against the last member plus one.
    const expected_opcode = [_]struct { Opcode, comptime_int }{
        .{ .noop, 0 },                  .{ .@"error", 1 },                        .{ .typecheck, 2 },               .{ .@"return", 3 },
        .{ .return_nil, 4 },            .{ .add_immediate, 5 },                   .{ .add, 6 },                     .{ .subtract_immediate, 7 },
        .{ .subtract, 8 },              .{ .multiply_immediate, 9 },              .{ .multiply, 10 },               .{ .divide_immediate, 11 },
        .{ .divide, 12 },               .{ .divide_floor, 13 },                   .{ .modulo, 14 },                 .{ .remainder, 15 },
        .{ .band, 16 },                 .{ .bor, 17 },                            .{ .bxor, 18 },                   .{ .bnot, 19 },
        .{ .shift_left, 20 },           .{ .shift_left_immediate, 21 },           .{ .shift_right, 22 },            .{ .shift_right_immediate, 23 },
        .{ .shift_right_unsigned, 24 }, .{ .shift_right_unsigned_immediate, 25 }, .{ .move_far, 26 },               .{ .move_near, 27 },
        .{ .jump, 28 },                 .{ .jump_if, 29 },                        .{ .jump_if_not, 30 },            .{ .jump_if_nil, 31 },
        .{ .jump_if_not_nil, 32 },      .{ .greater_than, 33 },                   .{ .greater_than_immediate, 34 }, .{ .less_than, 35 },
        .{ .less_than_immediate, 36 },  .{ .equals, 37 },                         .{ .equals_immediate, 38 },       .{ .compare, 39 },
        .{ .load_nil, 40 },             .{ .load_true, 41 },                      .{ .load_false, 42 },             .{ .load_integer, 43 },
        .{ .load_constant, 44 },        .{ .load_upvalue, 45 },                   .{ .load_self, 46 },              .{ .set_upvalue, 47 },
        .{ .closure, 48 },              .{ .push, 49 },                           .{ .push_2, 50 },                 .{ .push_3, 51 },
        .{ .push_array, 52 },           .{ .call, 53 },                           .{ .tailcall, 54 },               .{ .@"resume", 55 },
        .{ .signal, 56 },               .{ .propagate, 57 },                      .{ .in, 58 },                     .{ .get, 59 },
        .{ .put, 60 },                  .{ .get_index, 61 },                      .{ .put_index, 62 },              .{ .length, 63 },
        .{ .make_array, 64 },           .{ .make_buffer, 65 },                    .{ .make_string, 66 },            .{ .make_map, 67 },
        .{ .make_table, 68 },           .{ .make_tuple, 69 },                     .{ .make_vector, 70 },            .{ .greater_than_equal, 71 },
        .{ .less_than_equal, 72 },      .{ .next, 73 },                           .{ .not_equals, 74 },             .{ .not_equals_immediate, 75 },
        .{ .cancel, 76 },               .{ .make_bracket_tuple, 77 },
    };
    std.debug.assert(expected_opcode.len == @typeInfo(Opcode).@"enum".fields.len);
    for (expected_opcode) |row| std.debug.assert(@intFromEnum(row[0]) == row[1]);
    std.debug.assert(Opcode.count == @intFromEnum(Opcode.make_bracket_tuple) + 1);
}

comptime {
    // `PegRule` numbers its own members, and this table restates each number. A
    // member added, removed or renumbered fails here until the table changes
    // with it. `count` is asserted against the last member plus one.
    const expected_peg_rule = [_]struct { PegRule, comptime_int }{
        .{ .literal, 0 },    .{ .nchar, 1 },        .{ .notnchar, 2 },   .{ .range, 3 },
        .{ .set, 4 },        .{ .look, 5 },         .{ .choice, 6 },     .{ .sequence, 7 },
        .{ .@"if", 8 },      .{ .ifnot, 9 },        .{ .not, 10 },       .{ .between, 11 },
        .{ .gettag, 12 },    .{ .capture, 13 },     .{ .position, 14 },  .{ .argument, 15 },
        .{ .constant, 16 },  .{ .accumulate, 17 },  .{ .group, 18 },     .{ .replace, 19 },
        .{ .matchtime, 20 }, .{ .@"error", 21 },    .{ .drop, 22 },      .{ .backmatch, 23 },
        .{ .to, 24 },        .{ .thru, 25 },        .{ .lenprefix, 26 }, .{ .readint, 27 },
        .{ .line, 28 },      .{ .column, 29 },      .{ .unref, 30 },     .{ .capture_num, 31 },
        .{ .sub, 32 },       .{ .til, 33 },         .{ .split, 34 },     .{ .nth, 35 },
        .{ .only_tags, 36 }, .{ .matchsplice, 37 }, .{ .debug, 38 },
    };
    std.debug.assert(expected_peg_rule.len == @typeInfo(PegRule).@"enum".fields.len);
    for (expected_peg_rule) |row| std.debug.assert(@intFromEnum(row[0]) == row[1]);
    std.debug.assert(PegRule.count == @intFromEnum(PegRule.debug) + 1);
}
