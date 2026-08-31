//! Janet's constants, opcodes and flags, owned by Zig.
//!
//! The companion to `src/zig/types.zig`: that file owns the Janet types, this
//! one owns the values. A constant is not a declaration the compiler can
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
// The ten the header derives from the build's configuration
//
// Each cites the clause it mirrors, on the same terms as `build.zig`'s
// `janetConfig`: it has to be exact, and the disagreement is silent. One of
// them was already wrong when this file was written -- see
// `JANET_NANBOX_64_POINTER_SHIFT`.
// ---------------------------------------------------------------------------

/// `janet.h`: `0x0` under `JANET_NO_NANBOX`, `0x1` otherwise.
pub const JANET_NANBOX_BIT: c_int = if (config.value_repr == .tagged) 0x0 else 0x1;

/// `janet.h`: `0x2` under `JANET_SINGLE_THREADED`, `0` otherwise.
pub const JANET_SINGLE_THREADED_BIT: c_int = if (config.single_threaded) 0x2 else 0;

/// `janet.h`'s pointer shift, which exists so that a target with more than 47
/// bits of address space still fits a pointer in a NaN-boxed payload.
///
/// The header's clause is
///
///     #if (defined(_M_ARM64) || defined(__aarch64__)) && !defined(JANET_APPLE)
///
/// -- aarch64 that is **not** Apple, because aarch64 macOS uses the same
/// 47-bit userland address space as amd64. `build.zig` is where the predicate
/// lives now; this constant is `config.nanbox_pointer_shift` and nothing else,
/// so that the two cannot drift.
///
/// The predicate and the shift are one declaration for a reason: they had
/// drifted. The clause was once written `apple and aarch64`, which is the
/// inverse, while `registry.zig`'s `checkPointerAlign` guarded on `config` and
/// masked with a separately spelled shift -- two sources for one fact, in
/// adjacent lines. On aarch64 Linux the guard returned early and the alignment
/// check was **off** on the only targets that shift at all; on aarch64 macOS
/// it ran with a zero mask and checked nothing.
// The shift itself is `repr.pointer_shift`, in the module that shifts.

/// `janet.h`: `(SHIFT ? (0x4 << SHIFT) : 0)`, and `0` where the shift is not
/// defined at all -- which is every layout but nanbox-64.
pub const JANET_NANBOX_POINTER_SHIFT_BITS: c_int =
    if (config.value_repr == .nanbox_64 and repr.pointer_shift != 0)
        @as(c_int, 0x4) << @intCast(repr.pointer_shift)
    else
        0;

/// `janet.h`'s three-way or, which `janet_config_current` reports and a native
/// module compares against its own to refuse a mismatched runtime.
pub const JANET_CURRENT_CONFIG_BITS: c_int =
    JANET_SINGLE_THREADED_BIT | JANET_NANBOX_BIT | JANET_NANBOX_POINTER_SHIFT_BITS;

// Four predicates the runtime reads as values rather than as `#ifdef`s. Each
// restates one `config` field; these are the spellings the rest of the tree
// uses, and `c_int` because a C caller may read them.

/// `1` unless the build is single-threaded.
pub const JANET_VM_THREAD_LOCAL: c_int = if (config.single_threaded) 0 else 1;

/// `1` under the event loop.
pub const JANET_VM_HAS_EV: c_int = if (config.ev) 1 else 0;

/// `1` under networking.
pub const JANET_VM_HAS_NET: c_int = if (config.net) 1 else 0;

/// `0` when the interpreter does not check for an interrupt between
/// instructions.
pub const JANET_VM_HAS_INTERRUPT: c_int = if (config.interpreter_interrupt) 1 else 0;

/// `janet.h`: `NULL` on Windows, where a handle is a pointer, and `(-1)` on
/// POSIX, where it is a file descriptor. The only constant here whose *type*
/// changes with the target rather than its value.
pub const JANET_HANDLE_NONE = if (builtin.os.tag == .windows)
    @as(?*anyopaque, null)
else
    -@as(c_int, 1);

// ---------------------------------------------------------------------------
// The rest, invariant across all 31 configurations swept
// ---------------------------------------------------------------------------

// `JANET_SIGNAL_*` and `JANET_STATUS_*` are `types.Signal` and
// `types.FiberStatus`, two `enum(c_uint)` declarations -- where Janet's
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

pub const JOP_NOOP: c_int = 0;
pub const JOP_ERROR: c_int = 1;
pub const JOP_TYPECHECK: c_int = 2;
pub const JOP_RETURN: c_int = 3;

pub const JOP_RETURN_NIL: c_int = 4;

pub const JOP_ADD_IMMEDIATE: c_int = 5;

pub const JOP_ADD: c_int = 6;

pub const JOP_SUBTRACT_IMMEDIATE: c_int = 7;

pub const JOP_SUBTRACT: c_int = 8;

pub const JOP_MULTIPLY_IMMEDIATE: c_int = 9;

pub const JOP_MULTIPLY: c_int = 10;

pub const JOP_DIVIDE_IMMEDIATE: c_int = 11;

pub const JOP_DIVIDE: c_int = 12;

pub const JOP_DIVIDE_FLOOR: c_int = 13;

pub const JOP_MODULO: c_int = 14;
pub const JOP_REMAINDER: c_int = 15;
pub const JOP_BAND: c_int = 16;
pub const JOP_BOR: c_int = 17;
pub const JOP_BXOR: c_int = 18;
pub const JOP_BNOT: c_int = 19;

pub const JOP_SHIFT_LEFT: c_int = 20;
pub const JOP_SHIFT_LEFT_IMMEDIATE: c_int = 21;
pub const JOP_SHIFT_RIGHT: c_int = 22;
pub const JOP_SHIFT_RIGHT_IMMEDIATE: c_int = 23;
pub const JOP_SHIFT_RIGHT_UNSIGNED: c_int = 24;
pub const JOP_SHIFT_RIGHT_UNSIGNED_IMMEDIATE: c_int = 25;

pub const JOP_MOVE_FAR: c_int = 26;
pub const JOP_MOVE_NEAR: c_int = 27;

pub const JOP_JUMP: c_int = 28;

pub const JOP_JUMP_IF: c_int = 29;
pub const JOP_JUMP_IF_NOT: c_int = 30;
pub const JOP_JUMP_IF_NIL: c_int = 31;
pub const JOP_JUMP_IF_NOT_NIL: c_int = 32;

pub const JOP_GREATER_THAN: c_int = 33;
pub const JOP_GREATER_THAN_IMMEDIATE: c_int = 34;

pub const JOP_LESS_THAN: c_int = 35;
pub const JOP_LESS_THAN_IMMEDIATE: c_int = 36;

pub const JOP_EQUALS: c_int = 37;

pub const JOP_EQUALS_IMMEDIATE: c_int = 38;

pub const JOP_COMPARE: c_int = 39;

pub const JOP_LOAD_NIL: c_int = 40;
pub const JOP_LOAD_TRUE: c_int = 41;
pub const JOP_LOAD_FALSE: c_int = 42;
pub const JOP_LOAD_INTEGER: c_int = 43;
pub const JOP_LOAD_CONSTANT: c_int = 44;
pub const JOP_LOAD_UPVALUE: c_int = 45;
pub const JOP_LOAD_SELF: c_int = 46;

pub const JOP_SET_UPVALUE: c_int = 47;

pub const JOP_CLOSURE: c_int = 48;
pub const JOP_PUSH: c_int = 49;

pub const JOP_PUSH_2: c_int = 50;
pub const JOP_PUSH_3: c_int = 51;
pub const JOP_PUSH_ARRAY: c_int = 52;

pub const JOP_CALL: c_int = 53;
pub const JOP_TAILCALL: c_int = 54;
pub const JOP_RESUME: c_int = 55;
pub const JOP_SIGNAL: c_int = 56;
pub const JOP_PROPAGATE: c_int = 57;
pub const JOP_IN: c_int = 58;
pub const JOP_GET: c_int = 59;
pub const JOP_PUT: c_int = 60;

pub const JOP_GET_INDEX: c_int = 61;

pub const JOP_PUT_INDEX: c_int = 62;

pub const JOP_LENGTH: c_int = 63;

pub const JOP_MAKE_ARRAY: c_int = 64;
pub const JOP_MAKE_BUFFER: c_int = 65;
pub const JOP_MAKE_STRING: c_int = 66;
pub const JOP_MAKE_STRUCT: c_int = 67;
pub const JOP_MAKE_TABLE: c_int = 68;
pub const JOP_MAKE_TUPLE: c_int = 69;
pub const JOP_MAKE_BRACKET_TUPLE: c_int = 70;

pub const JOP_GREATER_THAN_EQUAL: c_int = 71;

pub const JOP_LESS_THAN_EQUAL: c_int = 72;

pub const JOP_NEXT: c_int = 73;

pub const JOP_NOT_EQUALS: c_int = 74;
pub const JOP_NOT_EQUALS_IMMEDIATE: c_int = 75;

pub const JOP_CANCEL: c_int = 76;

pub const JOP_INSTRUCTION_COUNT: c_int = 77;

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

pub const RULE_LITERAL: c_int = 0;
pub const RULE_NCHAR: c_int = 1;
pub const RULE_NOTNCHAR: c_int = 2;
pub const RULE_RANGE: c_int = 3;
pub const RULE_SET: c_int = 4;
pub const RULE_LOOK: c_int = 5;
pub const RULE_CHOICE: c_int = 6;
pub const RULE_SEQUENCE: c_int = 7;
pub const RULE_IF: c_int = 8;
pub const RULE_IFNOT: c_int = 9;
pub const RULE_NOT: c_int = 10;
pub const RULE_BETWEEN: c_int = 11;
pub const RULE_GETTAG: c_int = 12;
pub const RULE_CAPTURE: c_int = 13;
pub const RULE_POSITION: c_int = 14;
pub const RULE_ARGUMENT: c_int = 15;
pub const RULE_CONSTANT: c_int = 16;
pub const RULE_ACCUMULATE: c_int = 17;
pub const RULE_GROUP: c_int = 18;
pub const RULE_REPLACE: c_int = 19;
pub const RULE_MATCHTIME: c_int = 20;
pub const RULE_ERROR: c_int = 21;
pub const RULE_DROP: c_int = 22;
pub const RULE_BACKMATCH: c_int = 23;
pub const RULE_TO: c_int = 24;
pub const RULE_THRU: c_int = 25;
pub const RULE_LENPREFIX: c_int = 26;
pub const RULE_READINT: c_int = 27;
pub const RULE_LINE: c_int = 28;
pub const RULE_COLUMN: c_int = 29;
pub const RULE_UNREF: c_int = 30;

pub const RULE_CAPTURE_NUM: c_int = 31;

pub const RULE_SUB: c_int = 32;
pub const RULE_TIL: c_int = 33;
pub const RULE_SPLIT: c_int = 34;
pub const RULE_NTH: c_int = 35;

pub const RULE_ONLY_TAGS: c_int = 36;

pub const RULE_MATCHSPLICE: c_int = 37;
pub const RULE_DEBUG: c_int = 38;

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

pub const JANETC_SHADOW_NONE: c_int = 0;
pub const JANETC_SHADOW_MACRO: c_int = 1;
pub const JANETC_SHADOW_GLOBAL_HIDES_GLOBAL: c_int = 2;
pub const JANETC_SHADOW_LOCAL_HIDES_GLOBAL: c_int = 3;
pub const JANETC_SHADOW_LOCAL_HIDES_LOCAL: c_int = 4;

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

pub const JANET_FUNCDEF_FLAG_VARARG = helpers.promoteIntLiteral(c_int, 0x10000, .hex);
pub const JANET_FUNCDEF_FLAG_NEEDSENV = helpers.promoteIntLiteral(c_int, 0x20000, .hex);
pub const JANET_FUNCDEF_FLAG_HASSYMBOLMAP = helpers.promoteIntLiteral(c_int, 0x40000, .hex);
pub const JANET_FUNCDEF_FLAG_HASNAME = helpers.promoteIntLiteral(c_int, 0x80000, .hex);
pub const JANET_FUNCDEF_FLAG_HASSOURCE = helpers.promoteIntLiteral(c_int, 0x100000, .hex);
pub const JANET_FUNCDEF_FLAG_HASDEFS = helpers.promoteIntLiteral(c_int, 0x200000, .hex);
pub const JANET_FUNCDEF_FLAG_HASENVS = helpers.promoteIntLiteral(c_int, 0x400000, .hex);
pub const JANET_FUNCDEF_FLAG_HASSOURCEMAP = helpers.promoteIntLiteral(c_int, 0x800000, .hex);
pub const JANET_FUNCDEF_FLAG_STRUCTARG = helpers.promoteIntLiteral(c_int, 0x1000000, .hex);
pub const JANET_FUNCDEF_FLAG_HASCLOBITSET = helpers.promoteIntLiteral(c_int, 0x2000000, .hex);
pub const JANET_FUNCDEF_FLAG_NAMEDARGS = helpers.promoteIntLiteral(c_int, 0x4000000, .hex);
pub const JANET_FUNCDEF_FLAG_TAG = helpers.promoteIntLiteral(c_int, 0xFFFF, .hex);

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
// them -- are `types.Sandbox`, a `packed struct(u32)` whose twenty bit
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

pub const JANET_FIBER_MASK_ERROR = @as(c_int, 2);
pub const JANET_FIBER_MASK_DEBUG = @as(c_int, 4);
pub const JANET_FIBER_MASK_YIELD = @as(c_int, 8);
pub const JANET_FIBER_MASK_USER0 = @as(c_int, 16) << @as(c_int, 0);
pub const JANET_FIBER_MASK_USER1 = @as(c_int, 16) << @as(c_int, 1);
pub const JANET_FIBER_MASK_USER2 = @as(c_int, 16) << @as(c_int, 2);
pub const JANET_FIBER_MASK_USER3 = @as(c_int, 16) << @as(c_int, 3);
pub const JANET_FIBER_MASK_USER4 = @as(c_int, 16) << @as(c_int, 4);
pub const JANET_FIBER_MASK_USER5 = @as(c_int, 16) << @as(c_int, 5);
pub const JANET_FIBER_MASK_USER6 = @as(c_int, 16) << @as(c_int, 6);
pub const JANET_FIBER_MASK_USER7 = @as(c_int, 16) << @as(c_int, 7);
pub const JANET_FIBER_MASK_USER8 = @as(c_int, 16) << @as(c_int, 8);
pub const JANET_FIBER_MASK_USER9 = @as(c_int, 16) << @as(c_int, 9);
pub const JANET_FIBER_MASK_USER = @as(c_int, 0x3FF0);
pub const JANET_FIBER_STATUS_MASK = helpers.promoteIntLiteral(c_int, 0x3F0000, .hex);
pub const JANET_FIBER_RESUME_SIGNAL = helpers.promoteIntLiteral(c_int, 0x400000, .hex);
pub const JANET_FIBER_STATUS_OFFSET = @as(c_int, 16);
pub const JANET_FIBER_BREAKPOINT = helpers.promoteIntLiteral(c_int, 0x1000000, .hex);
pub const JANET_FIBER_RESUME_NO_USEVAL = helpers.promoteIntLiteral(c_int, 0x2000000, .hex);
pub const JANET_FIBER_RESUME_NO_SKIP = helpers.promoteIntLiteral(c_int, 0x4000000, .hex);
pub const JANET_FIBER_DID_RAISE = helpers.promoteIntLiteral(c_int, 0x8000000, .hex);
pub const JANET_FIBER_FLAG_MASK = helpers.promoteIntLiteral(c_int, 0xF000000, .hex);
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

pub const JANET_SLOT_CONSTANT = helpers.promoteIntLiteral(c_int, 0x10000, .hex);
pub const JANET_SLOT_NAMED = helpers.promoteIntLiteral(c_int, 0x20000, .hex);
pub const JANET_SLOT_MUTABLE = helpers.promoteIntLiteral(c_int, 0x40000, .hex);
pub const JANET_SLOT_REF = helpers.promoteIntLiteral(c_int, 0x80000, .hex);
pub const JANET_SLOT_RETURNED = helpers.promoteIntLiteral(c_int, 0x100000, .hex);
pub const JANET_SLOT_DEP_NOTE = helpers.promoteIntLiteral(c_int, 0x200000, .hex);
pub const JANET_SLOT_DEP_WARN = helpers.promoteIntLiteral(c_int, 0x400000, .hex);
pub const JANET_SLOT_DEP_ERROR = helpers.promoteIntLiteral(c_int, 0x800000, .hex);
pub const JANET_SLOT_SPLICED = helpers.promoteIntLiteral(c_int, 0x1000000, .hex);

pub const JANET_SLOTTYPE_ANY = helpers.promoteIntLiteral(c_int, 0xFFFF, .hex);

pub const JANET_SCOPE_FUNCTION = @as(c_int, 1);
pub const JANET_SCOPE_ENV = @as(c_int, 2);
pub const JANET_SCOPE_TOP = @as(c_int, 4);
pub const JANET_SCOPE_UNUSED = @as(c_int, 8);
pub const JANET_SCOPE_CLOSURE = @as(c_int, 16);
pub const JANET_SCOPE_WHILE = @as(c_int, 32);

pub const JANET_FOPTS_TAIL = helpers.promoteIntLiteral(c_int, 0x10000, .hex);
pub const JANET_FOPTS_HINT = helpers.promoteIntLiteral(c_int, 0x20000, .hex);
pub const JANET_FOPTS_DROP = helpers.promoteIntLiteral(c_int, 0x40000, .hex);
pub const JANET_FOPTS_ACCEPT_SPLICE = helpers.promoteIntLiteral(c_int, 0x80000, .hex);

pub const JANET_DEFFLAG_NO_SHADOWCHECK = @as(c_int, 1);
pub const JANET_DEFFLAG_NO_UNUSED = @as(c_int, 2);

// `JANET_DOUBLE_OFFSET` is `repr.double_offset`.

pub const JANET_HASH_KEY_SIZE = @as(c_int, 16);
