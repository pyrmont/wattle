//! Janet's constants, opcodes and flags, owned by Zig.
//!
//! Its own module, below the subsystems: a constant is spelled by the
//! bootstrap, the client and the runtime alike. A constant is not a
//! declaration the compiler can
//! re-derive -- a wrong opcode number is a working program giving a wrong
//! answer rather than a build failure -- so these were extracted from a
//! translation of Janet's headers over 31 configurations and diffed, rather
//! than transcribed by hand. `helpers.promoteIntLiteral` is kept for that
//! reason: it is C's integer-literal promotion, and the type it yields depends
//! on the target's `long`.
//!
//! **What is not here, and why each is somewhere better.**
//!
//!   - **Ten constants that carry the build's configuration** -- the
//!     `JANET_VM_HAS_*` family, the nanbox bits and `JANET_CURRENT_CONFIG_BITS`
//!     -- are computed from `@import("config")` below rather than transcribed,
//!     because their value follows `-D` flags.
//!   - **Ten more that a config header set** -- the version quintet,
//!     `JANET_BUILD`, and the four limits -- are `Config` fields, for the same
//!     reason.
//!   - **Six platform predicates** (`JANET_APPLE`, `JANET_64`, ...) are
//!     `@import("builtin")`'s, which knows them exactly.
//!   - **The code-generating macros** (`JANET_REG_*`, `JANET_FN_*`,
//!     `JANET_ATEND_*`, `JANET_API`) are not values at all. `DESIGN.md`
//!     sections 5 and 6 retire them rather than reproduce them.
//!
//! Every value here is invariant across the configurations the build offers,
//! except the ten below that follow a `-D` flag and are computed from
//! `@import("config")` rather than written down.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");
const repr = @import("repr");

const helpers = std.zig.c_translation.helpers;

// ---------------------------------------------------------------------------
// The ten derived from the build's configuration
//
// Each restates one `config` field and nothing else, so that the two cannot
// drift: `build.zig`'s `janetConfig` is the one derivation.
// ---------------------------------------------------------------------------

/// `0x0` under the tagged layout, `0x1` otherwise.
pub const JANET_NANBOX_BIT: c_int = if (config.value_repr == .tagged) 0x0 else 0x1;

/// `0x2` in a single-threaded build, `0` otherwise.
pub const JANET_SINGLE_THREADED_BIT: c_int = if (config.single_threaded) 0x2 else 0;

// The pointer shift exists so that a target with more than 47 bits of address
// space still fits a pointer in a NaN-boxed payload: aarch64 that is **not**
// Apple, because aarch64 macOS uses the same 47-bit userland address space as
// amd64. `build.zig` owns the predicate and `repr.pointer_shift` is the shift;
// this constant reads them and adds nothing, so the three cannot drift.
//
// They had drifted, and the cost is worth knowing: the predicate was once
// written `apple and aarch64`, which is the inverse, while
// `registry.zig`'s `checkPointerAlign` masked with a separately spelled shift.
// On aarch64 Linux the alignment check was **off** on the only targets that
// shift at all; on aarch64 macOS it ran with a zero mask and checked nothing.

/// `0x4 << shift` under nanbox-64, and `0` under every other layout.
pub const JANET_NANBOX_POINTER_SHIFT_BITS: c_int =
    if (config.value_repr == .nanbox_64 and repr.pointer_shift != 0)
        @as(c_int, 0x4) << @intCast(repr.pointer_shift)
    else
        0;

/// The three bits above, or'd: what a native module compares against its own to
/// refuse a mismatched runtime.
pub const JANET_CURRENT_CONFIG_BITS: c_int =
    JANET_SINGLE_THREADED_BIT | JANET_NANBOX_BIT | JANET_NANBOX_POINTER_SHIFT_BITS;

// Four predicates the runtime reads as values rather than as comptime
// conditions. Each restates one `config` field; these are the spellings the
// rest of the tree uses.

/// `1` unless the build is single-threaded.
pub const JANET_VM_THREAD_LOCAL: c_int = if (config.single_threaded) 0 else 1;

/// `1` under the event loop.
pub const JANET_VM_HAS_EV: c_int = if (config.ev) 1 else 0;

/// `1` under networking.
pub const JANET_VM_HAS_NET: c_int = if (config.net) 1 else 0;

/// `0` when the interpreter does not check for an interrupt between
/// instructions.
pub const JANET_VM_HAS_INTERRUPT: c_int = if (config.interpreter_interrupt) 1 else 0;

/// Null on Windows, where a handle is a pointer, and `-1` on POSIX, where it is
/// a file descriptor. The only constant here whose *type*
/// changes with the target rather than its value.
pub const JANET_HANDLE_NONE = if (builtin.os.tag == .windows)
    @as(?*anyopaque, null)
else
    -@as(c_int, 1);

// ---------------------------------------------------------------------------
// The rest, invariant across all 31 configurations swept
// ---------------------------------------------------------------------------

// `JANET_SIGNAL_*` and `JANET_STATUS_*` are `abi.Signal` and
// `fibers.FiberStatus`, two `enum(c_uint)` declarations -- where Janet's
// sixteen signal *names* are fourteen members and two aliases, which a list of
// constants cannot say.

// The sixteen `JanetType` values are `repr.Tag`'s members, an `enum(u4)` in
// the module that owns the representation. The masks below are the one thing
// left that needs their numbering.

pub const JANET_ASYNC_EVENT_INIT: c_int = 0;
pub const JANET_ASYNC_EVENT_MARK: c_int = 1;
pub const JANET_ASYNC_EVENT_DEINIT: c_int = 2;
pub const JANET_ASYNC_EVENT_CLOSE: c_int = 3;
pub const JANET_ASYNC_EVENT_ERR: c_int = 4;
pub const JANET_ASYNC_EVENT_HUP: c_int = 5;
pub const JANET_ASYNC_EVENT_READ: c_int = 6;
pub const JANET_ASYNC_EVENT_WRITE: c_int = 7;
pub const JANET_ASYNC_EVENT_COMPLETE: c_int = 8;
pub const JANET_ASYNC_EVENT_FAILED: c_int = 9;
pub const JANET_ASYNC_LISTEN_READ: c_int = 1;
pub const JANET_ASYNC_LISTEN_WRITE: c_int = 2;
pub const JANET_ASYNC_LISTEN_BOTH: c_int = 3;

pub const JANET_PARSE_ROOT: c_int = 0;
pub const JANET_PARSE_ERROR: c_int = 1;
pub const JANET_PARSE_PENDING: c_int = 2;
pub const JANET_PARSE_DEAD: c_int = 3;

pub const JANET_OAT_SLOT: c_int = 0;
pub const JANET_OAT_ENVIRONMENT: c_int = 1;
pub const JANET_OAT_CONSTANT: c_int = 2;
pub const JANET_OAT_INTEGER: c_int = 3;
pub const JANET_OAT_TYPE: c_int = 4;
pub const JANET_OAT_SIMPLETYPE: c_int = 5;
pub const JANET_OAT_LABEL: c_int = 6;
pub const JANET_OAT_FUNCDEF: c_int = 7;

pub const JINT_0: c_int = 0;
pub const JINT_S: c_int = 1;
pub const JINT_L: c_int = 2;
pub const JINT_SS: c_int = 3;
pub const JINT_SL: c_int = 4;
pub const JINT_ST: c_int = 5;
pub const JINT_SI: c_int = 6;
pub const JINT_SD: c_int = 7;
pub const JINT_SU: c_int = 8;
pub const JINT_SSS: c_int = 9;
pub const JINT_SSI: c_int = 10;
pub const JINT_SSU: c_int = 11;
pub const JINT_SES: c_int = 12;
pub const JINT_SC: c_int = 13;

/// The bytecode's operation, as one type rather than seventy-seven integers.
///
/// **The numbers are the bytecode**, so each is written out and none is
/// implied by position: an instruction's low byte is this value, a marshalled
/// funcdef carries it, and `disasm` prints its name. The `JOP_*` constants
/// below are what these were and are asserted against member for member at
/// the bottom of this block, so a renumbering is a compile error rather than a
/// silently different image.
///
/// **Non-exhaustive**, and that is the debugger rather than defensiveness. Bit
/// 7 of the instruction word is the breakpoint bit: setting it produces a
/// value no arm names, `runVm`'s `_ =>` arm raises `debug`, and that is how a
/// breakpoint stops the loop (`vm.zig`, the arm at the end of the dispatch).
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
    make_struct = 67,
    make_table = 68,
    make_tuple = 69,
    make_bracket_tuple = 70,
    greater_than_equal = 71,
    less_than_equal = 72,
    next = 73,
    not_equals = 74,
    not_equals_immediate = 75,
    cancel = 76,
    _,

    /// How many opcodes there are -- `JOP_INSTRUCTION_COUNT`, which is one
    /// past the last and is not itself an opcode. `verify.zig`'s type table
    /// and `bytecode.zig`'s name table are both this long.
    pub const count: usize = 77;

    pub inline fn fromWord(word: u32) Opcode {
        return @enumFromInt(@as(u8, @truncate(word)));
    }

    pub inline fn number(self: Opcode) u8 {
        return @intFromEnum(self);
    }
};

pub const JANET_ASSEMBLE_OK: c_int = 0;
pub const JANET_ASSEMBLE_ERROR: c_int = 1;

pub const JANET_COMPILE_OK: c_int = 0;
pub const JANET_COMPILE_ERROR: c_int = 1;

pub const JANET_BINDING_NONE: c_int = 0;
pub const JANET_BINDING_DEF: c_int = 1;
pub const JANET_BINDING_VAR: c_int = 2;
pub const JANET_BINDING_MACRO: c_int = 3;
pub const JANET_BINDING_DYNAMIC_DEF: c_int = 4;
pub const JANET_BINDING_DYNAMIC_MACRO: c_int = 5;
pub const JANET_BINDING_DEP_NONE: c_int = 0;
pub const JANET_BINDING_DEP_RELAXED: c_int = 1;
pub const JANET_BINDING_DEP_NORMAL: c_int = 2;
pub const JANET_BINDING_DEP_STRICT: c_int = 3;

/// A compiled PEG rule's operation, which is the first word of every rule in
/// the compiled program.
///
/// The numbers are the compiled form and are marshalled with it, so each is
/// written out. Non-exhaustive because the word comes out of a `peg` abstract
/// that unmarshalling may have been handed from anywhere: `peg.zig`'s
/// verifier is what rejects an unknown rule, and it can only do that if an
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

    /// One past the last rule -- the bound `peg.zig`'s verifier checks a
    /// rule word against before dispatching on it.
    pub const count: u32 = 39;

    pub inline fn fromWord(word: u32) PegRule {
        return @enumFromInt(word);
    }

    pub inline fn number(self: PegRule) u32 {
        return @intFromEnum(self);
    }
};

pub const JANET_INT_NONE: c_int = 0;
pub const JANET_INT_S64: c_int = 1;
pub const JANET_INT_U64: c_int = 2;

// `JANET_SIGNAL_PLAN_*` are `signal.Plan`, an `enum(c_uint)` in the file that
// decides a plan, because nothing outside the raise protocol names one and no
// symbol carries it.

pub const JANET_TRACE_NAME_NONE: c_int = 0;
pub const JANET_TRACE_NAME_ANONYMOUS: c_int = 1;
pub const JANET_TRACE_NAME_FUNCTION: c_int = 2;
pub const JANET_TRACE_NAME_CFUNCTION: c_int = 3;
pub const JANET_TRACE_NAME_CFUNCTION_BARE: c_int = 4;
pub const JANET_TRACE_LOC_NONE: c_int = 0;
pub const JANET_TRACE_LOC_SOURCEMAP: c_int = 1;
pub const JANET_TRACE_LOC_PC: c_int = 2;
pub const JANET_TRACE_LOC_CFUN_LINE: c_int = 3;

pub const JANET_ARG_EXPECT_NAT: c_int = 0;
pub const JANET_ARG_EXPECT_SIZE: c_int = 1;
pub const JANET_ARG_EXPECT_S32: c_int = 2;
pub const JANET_ARG_EXPECT_U32: c_int = 3;
pub const JANET_ARG_EXPECT_S16: c_int = 4;
pub const JANET_ARG_EXPECT_U16: c_int = 5;
pub const JANET_ARG_EXPECT_S8: c_int = 6;
pub const JANET_ARG_EXPECT_U8: c_int = 7;
pub const JANET_ARG_EXPECT_FLOAT: c_int = 8;
pub const JANET_ARG_EXPECT_S64: c_int = 9;
pub const JANET_ARG_EXPECT_U64: c_int = 10;
pub const JANET_ARG_OK: c_int = 0;
pub const JANET_ARG_TYPE: c_int = 1;
pub const JANET_ARG_ABSTRACT: c_int = 2;
pub const JANET_ARG_EXPECT: c_int = 3;
pub const JANET_ARG_RANGE_INCLUSIVE: c_int = 4;
pub const JANET_ARG_RANGE_EXCLUSIVE: c_int = 5;
pub const JANET_ARG_FLAG: c_int = 6;
pub const JANET_ARG_ZEROS: c_int = 7;
pub const JANET_ARG_ARITY_FIX: c_int = 8;
pub const JANET_ARG_ARITY_MIN: c_int = 9;
pub const JANET_ARG_ARITY_MAX: c_int = 10;
pub const JANET_ARG_BYTES_FAULT: c_int = 0;
pub const JANET_ARG_BYTES_STRING: c_int = 1;
pub const JANET_ARG_BYTES_BUFFER: c_int = 2;
pub const JANET_ARG_BYTES_ABSTRACT: c_int = 3;
pub const JANET_ARG_CBYTES_FAULT: c_int = 0;
pub const JANET_ARG_CBYTES_COPY: c_int = 1;
pub const JANET_ARG_CBYTES_TERMINATE: c_int = 2;
pub const JANET_ARG_CBYTES_VIEW: c_int = 3;

// `JANET_MEMORY_*` -- the eighteen heap-block types -- are `types.MemoryType`,
// an `enum(u8)` because `JANET_MEM_TYPEBITS` is `0xFF`: the stored width and
// the vocabulary are one declaration, and `JanetGCObject` reads and writes it.

pub const JANETC_REGTEMP_0: c_int = 0;
pub const JANETC_REGTEMP_1: c_int = 1;
pub const JANETC_REGTEMP_2: c_int = 2;
pub const JANETC_REGTEMP_3: c_int = 3;
pub const JANETC_REGTEMP_4: c_int = 4;
pub const JANETC_REGTEMP_5: c_int = 5;
pub const JANETC_REGTEMP_6: c_int = 6;
pub const JANETC_REGTEMP_7: c_int = 7;

pub const JANET_C_LINT_RELAXED: c_int = 0;
pub const JANET_C_LINT_NORMAL: c_int = 1;
pub const JANET_C_LINT_STRICT: c_int = 2;

pub const JANET_LITTLE_ENDIAN = @as(c_int, 1);

pub const JANET_INTMAX_DOUBLE = @as(f64, 9007199254740992.0);

pub const JANET_INTMIN_DOUBLE = -@as(f64, 9007199254740992.0);

pub const JANET_INTMAX_INT64 = helpers.promoteIntLiteral(c_int, 9007199254740992, .decimal);

pub const JANET_INTMIN_INT64 = -helpers.promoteIntLiteral(c_int, 9007199254740992, .decimal);

// `JANET_TFLAG_*` -- the sixteen `1 << type` masks and their five named
// unions -- are `repr.TagSet`, a `packed struct(u16)` whose bit layout is
// asserted there against Janet's; the two published symbols that take one as
// an `int` convert in `capi.zig`, and the bytecode's `JOP_TYPECHECK` operand
// is the sixteen bits the set already is. `repr.tag_count` is the count.

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

pub const JANET_STACKFRAME_TAILCALL = @as(c_int, 1);
pub const JANET_STACKFRAME_ENTRANCE = @as(c_int, 2);

pub const JANET_FRAME_SIZE = @as(c_int, 4);

pub const JANET_FUNCFLAG_TRACE = @as(c_int, 1) << @as(c_int, 16);

pub const JANET_EV_TCTAG_NIL = @as(c_int, 0);
pub const JANET_EV_TCTAG_INTEGER = @as(c_int, 1);
pub const JANET_EV_TCTAG_STRING = @as(c_int, 2);
pub const JANET_EV_TCTAG_STRINGF = @as(c_int, 3);
pub const JANET_EV_TCTAG_KEYWORD = @as(c_int, 4);
pub const JANET_EV_TCTAG_ERR_STRING = @as(c_int, 5);
pub const JANET_EV_TCTAG_ERR_STRINGF = @as(c_int, 6);
pub const JANET_EV_TCTAG_ERR_KEYWORD = @as(c_int, 7);
pub const JANET_EV_TCTAG_BOOLEAN = @as(c_int, 8);

pub const JANET_DO_ERROR_RUNTIME = @as(c_int, 0x01);
pub const JANET_DO_ERROR_COMPILE = @as(c_int, 0x02);
pub const JANET_DO_ERROR_PARSE = @as(c_int, 0x04);

pub const JANET_BUFFER_FLAG_NO_REALLOC = helpers.promoteIntLiteral(c_int, 0x10000, .hex);

pub const JANET_TUPLE_FLAG_BRACKETCTOR = helpers.promoteIntLiteral(c_int, 0x10000, .hex);

pub const JANET_MARSHAL_UNSAFE = helpers.promoteIntLiteral(c_int, 0x20000, .hex);
pub const JANET_MARSHAL_NO_CYCLES = helpers.promoteIntLiteral(c_int, 0x40000, .hex);

pub const JANET_PRETTY_COLOR = @as(c_int, 1);
pub const JANET_PRETTY_ONELINE = @as(c_int, 2);
pub const JANET_PRETTY_NOTRUNC = @as(c_int, 4);

// `JANET_SANDBOX_*` -- twenty capability bits and four names for unions of
// them -- are `vm_lifecycle.Sandbox`, a `packed struct(u32)` whose twenty bit
// positions are asserted there; `janet_sandbox` and `janet_sandbox_assert`
// keep the published `uint32_t` and convert.

pub const JANET_FILE_WRITE = @as(c_int, 1);
pub const JANET_FILE_READ = @as(c_int, 2);
pub const JANET_FILE_APPEND = @as(c_int, 4);
pub const JANET_FILE_UPDATE = @as(c_int, 8);
pub const JANET_FILE_NOT_CLOSEABLE = @as(c_int, 16);
pub const JANET_FILE_CLOSED = @as(c_int, 32);
pub const JANET_FILE_BINARY = @as(c_int, 64);
pub const JANET_FILE_SERIALIZABLE = @as(c_int, 128);
pub const JANET_FILE_NONIL = @as(c_int, 512);

pub const JANET_FIBER_STATUS_MASK = helpers.promoteIntLiteral(c_int, 0x3F0000, .hex);
pub const JANET_FIBER_STATUS_OFFSET = @as(c_int, 16);
pub const JANET_FIBER_EV_FLAG_CANCELED = helpers.promoteIntLiteral(c_int, 0x10000, .hex);
pub const JANET_FIBER_EV_FLAG_SUSPENDED = helpers.promoteIntLiteral(c_int, 0x20000, .hex);
pub const JANET_FIBER_FLAG_ROOT = helpers.promoteIntLiteral(c_int, 0x40000, .hex);
pub const JANET_FIBER_EV_FLAG_IN_FLIGHT = @as(c_int, 0x1);

pub const JANET_MEM_TYPEBITS = @as(c_int, 0xFF);
pub const JANET_MEM_REACHABLE = @as(c_int, 0x100);
pub const JANET_MEM_DISABLED = @as(c_int, 0x200);

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

pub const JANET_DEFFLAG_NO_SHADOWCHECK = @as(c_int, 1);
pub const JANET_DEFFLAG_NO_UNUSED = @as(c_int, 2);

// `JANET_DOUBLE_OFFSET` is `repr.double_offset`.

pub const JANET_HASH_KEY_SIZE = @as(c_int, 16);
