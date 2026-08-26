//! Janet's constants, opcodes and flags, owned by Zig.
//!
//! Phase 12 increment 4, and the companion to `src/zig/types.zig`: that file
//! took the types out of the `@cImport`, this one takes the values. Together
//! they are what has to exist before `janet.h` can stop being translated,
//! because a constant is not a declaration the compiler can re-derive -- a
//! wrong opcode number is a working program giving a wrong answer rather than
//! a build failure.
//!
//! **These are translate-c's own output**, extracted from the translation of
//! `janet.h` and the internal headers for **31 configurations** and diffed,
//! rather than transcribed by hand. `zig build translate` is the step that
//! produces one; the extraction reads the `pub const` text out of it, so the
//! right-hand sides below are the compiler's reading of the C and not a
//! person's. `helpers.promoteIntLiteral` is kept for the same reason `[*c]` is
//! kept in `types.zig`: it is C's integer-literal promotion, and the type it
//! yields depends on the target's `long`.
//!
//! **What is not here, and why each is somewhere better.**
//!
//!   - **Ten constants that carry the build's configuration** -- the
//!     `JANET_VM_HAS_*` family, the nanbox bits and `JANET_CURRENT_CONFIG_BITS`
//!     -- are computed from `@import("config")` below rather than transcribed,
//!     because their value follows `-D` flags. Increment 1 moved the
//!     configuration the runtime read as `@hasDecl(c, "JANET_X")`; it did not
//!     see the configuration the runtime read as a *value*, which is what
//!     `src/zig/state_abi.h` exists to provide. See `phase_12.md`'s rule 16.
//!   - **Ten more that `janetconf.h` sets** -- the version quintet,
//!     `JANET_BUILD`, and the four limits -- are `Config` fields, for the same
//!     reason and by the same argument.
//!   - **Six platform predicates** (`JANET_APPLE`, `JANET_64`, ...) are
//!     `@import("builtin")`'s, which increment 1 settled.
//!   - **The code-generating macros** (`JANET_REG_*`, `JANET_FN_*`,
//!     `JANET_ATEND_*`, `JANET_API`) are not values at all. translate-c renders
//!     every one of them as `@compileError`, which is the mechanical statement
//!     of the same thing, and `DESIGN.md` §§5 and 6 retire them rather than
//!     port them.
//!
//! `src/zig/constants_check.zig` holds this file to the `@cImport` for as long
//! as both exist -- value, type and signedness, per configuration. Like
//! `types_check.zig` it is an oracle with a fixed lifetime: it dies with the
//! header, so its whole value has to be spent before the header goes.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");

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
/// They had drifted. Increment 1 wrote the clause as `apple and aarch64`,
/// which is the inverse, and left `registry.zig`'s `checkPointerAlign`
/// guarding on `config` while masking with `c.JANET_NANBOX_64_POINTER_SHIFT`
/// -- two sources for one fact, in adjacent lines. On aarch64 Linux the guard
/// then returned early and the alignment check was **off** on the only targets
/// that shift at all; on aarch64 macOS it ran with a zero mask and so checked
/// nothing. Fixed in this increment, and it is why the oracle checks `Config`
/// against the header rather than only the constants.
pub const JANET_NANBOX_64_POINTER_SHIFT: c_int = config.nanbox_pointer_shift;

/// `janet.h`: `(SHIFT ? (0x4 << SHIFT) : 0)`, and `0` where the shift is not
/// defined at all -- which is every layout but nanbox-64.
pub const JANET_NANBOX_POINTER_SHIFT_BITS: c_int =
    if (config.value_repr == .nanbox_64 and JANET_NANBOX_64_POINTER_SHIFT != 0)
        @as(c_int, 0x4) << @intCast(JANET_NANBOX_64_POINTER_SHIFT)
    else
        0;

/// `janet.h`'s three-way or, which `janet_config_current` reports and a native
/// module compares against its own to refuse a mismatched runtime.
pub const JANET_CURRENT_CONFIG_BITS: c_int =
    JANET_SINGLE_THREADED_BIT | JANET_NANBOX_BIT | JANET_NANBOX_POINTER_SHIFT_BITS;

// The four `src/zig/state_abi.h` defines. That header exists precisely because
// "translate-c does not surface a macro defined with no value", so it restates
// `#ifdef JANET_EV` and its neighbours as constants Zig can read -- which made
// it a configuration channel that increment 1's `@hasDecl` sweep could not
// see. They are `config` fields now, and `state_abi.h`'s block goes with the
// header.

/// `state_abi.h`: `1` unless `JANET_SINGLE_THREADED`.
pub const JANET_VM_THREAD_LOCAL: c_int = if (config.single_threaded) 0 else 1;

/// `state_abi.h`: `1` under `JANET_EV`.
pub const JANET_VM_HAS_EV: c_int = if (config.ev) 1 else 0;

/// `state_abi.h`: `1` under `JANET_NET`.
pub const JANET_VM_HAS_NET: c_int = if (config.net) 1 else 0;

/// `state_abi.h`: `0` under `JANET_NO_INTERPRETER_INTERRUPT`.
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

pub const JANET_SIGNAL_OK: c_int = 0;
pub const JANET_SIGNAL_ERROR: c_int = 1;
pub const JANET_SIGNAL_DEBUG: c_int = 2;
pub const JANET_SIGNAL_YIELD: c_int = 3;
pub const JANET_SIGNAL_USER0: c_int = 4;
pub const JANET_SIGNAL_USER1: c_int = 5;
pub const JANET_SIGNAL_USER2: c_int = 6;
pub const JANET_SIGNAL_USER3: c_int = 7;
pub const JANET_SIGNAL_USER4: c_int = 8;
pub const JANET_SIGNAL_USER5: c_int = 9;
pub const JANET_SIGNAL_USER6: c_int = 10;
pub const JANET_SIGNAL_USER7: c_int = 11;
pub const JANET_SIGNAL_USER8: c_int = 12;
pub const JANET_SIGNAL_USER9: c_int = 13;
pub const JANET_SIGNAL_INTERRUPT: c_int = 12;
pub const JANET_SIGNAL_EVENT: c_int = 13;

pub const JANET_STATUS_DEAD: c_int = 0;
pub const JANET_STATUS_ERROR: c_int = 1;
pub const JANET_STATUS_DEBUG: c_int = 2;
pub const JANET_STATUS_PENDING: c_int = 3;
pub const JANET_STATUS_USER0: c_int = 4;
pub const JANET_STATUS_USER1: c_int = 5;
pub const JANET_STATUS_USER2: c_int = 6;
pub const JANET_STATUS_USER3: c_int = 7;
pub const JANET_STATUS_USER4: c_int = 8;
pub const JANET_STATUS_USER5: c_int = 9;
pub const JANET_STATUS_USER6: c_int = 10;
pub const JANET_STATUS_USER7: c_int = 11;
pub const JANET_STATUS_USER8: c_int = 12;
pub const JANET_STATUS_USER9: c_int = 13;
pub const JANET_STATUS_NEW: c_int = 14;
pub const JANET_STATUS_ALIVE: c_int = 15;

pub const JANET_NUMBER: c_int = 0;
pub const JANET_NIL: c_int = 1;
pub const JANET_BOOLEAN: c_int = 2;
pub const JANET_FIBER: c_int = 3;
pub const JANET_STRING: c_int = 4;
pub const JANET_SYMBOL: c_int = 5;
pub const JANET_KEYWORD: c_int = 6;
pub const JANET_ARRAY: c_int = 7;
pub const JANET_TUPLE: c_int = 8;
pub const JANET_TABLE: c_int = 9;
pub const JANET_STRUCT: c_int = 10;
pub const JANET_BUFFER: c_int = 11;
pub const JANET_FUNCTION: c_int = 12;
pub const JANET_CFUNCTION: c_int = 13;
pub const JANET_ABSTRACT: c_int = 14;
pub const JANET_POINTER: c_int = 15;

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

pub const JANET_SIGNAL_PLAN_TOP_LEVEL: c_int = 0;
pub const JANET_SIGNAL_PLAN_RAISE: c_int = 1;
pub const JANET_SIGNAL_PLAN_COERCE: c_int = 2;

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

pub const JANET_MEMORY_NONE: c_int = 0;
pub const JANET_MEMORY_STRING: c_int = 1;
pub const JANET_MEMORY_SYMBOL: c_int = 2;
pub const JANET_MEMORY_ARRAY: c_int = 3;
pub const JANET_MEMORY_TUPLE: c_int = 4;
pub const JANET_MEMORY_TABLE: c_int = 5;
pub const JANET_MEMORY_STRUCT: c_int = 6;
pub const JANET_MEMORY_FIBER: c_int = 7;
pub const JANET_MEMORY_BUFFER: c_int = 8;
pub const JANET_MEMORY_FUNCTION: c_int = 9;
pub const JANET_MEMORY_ABSTRACT: c_int = 10;
pub const JANET_MEMORY_FUNCENV: c_int = 11;
pub const JANET_MEMORY_FUNCDEF: c_int = 12;
pub const JANET_MEMORY_THREADED_ABSTRACT: c_int = 13;
pub const JANET_MEMORY_TABLE_WEAKK: c_int = 14;
pub const JANET_MEMORY_TABLE_WEAKV: c_int = 15;
pub const JANET_MEMORY_TABLE_WEAKKV: c_int = 16;
pub const JANET_MEMORY_ARRAY_WEAK: c_int = 17;

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

pub const JANET_COUNT_TYPES = JANET_POINTER + @as(c_int, 1);

pub const JANET_TFLAG_NIL = @as(c_int, 1) << JANET_NIL;
pub const JANET_TFLAG_BOOLEAN = @as(c_int, 1) << JANET_BOOLEAN;
pub const JANET_TFLAG_FIBER = @as(c_int, 1) << JANET_FIBER;
pub const JANET_TFLAG_NUMBER = @as(c_int, 1) << JANET_NUMBER;
pub const JANET_TFLAG_STRING = @as(c_int, 1) << JANET_STRING;
pub const JANET_TFLAG_SYMBOL = @as(c_int, 1) << JANET_SYMBOL;
pub const JANET_TFLAG_KEYWORD = @as(c_int, 1) << JANET_KEYWORD;
pub const JANET_TFLAG_ARRAY = @as(c_int, 1) << JANET_ARRAY;
pub const JANET_TFLAG_TUPLE = @as(c_int, 1) << JANET_TUPLE;
pub const JANET_TFLAG_TABLE = @as(c_int, 1) << JANET_TABLE;
pub const JANET_TFLAG_STRUCT = @as(c_int, 1) << JANET_STRUCT;
pub const JANET_TFLAG_BUFFER = @as(c_int, 1) << JANET_BUFFER;
pub const JANET_TFLAG_FUNCTION = @as(c_int, 1) << JANET_FUNCTION;
pub const JANET_TFLAG_CFUNCTION = @as(c_int, 1) << JANET_CFUNCTION;
pub const JANET_TFLAG_ABSTRACT = @as(c_int, 1) << JANET_ABSTRACT;
pub const JANET_TFLAG_POINTER = @as(c_int, 1) << JANET_POINTER;
pub const JANET_TFLAG_BYTES = ((JANET_TFLAG_STRING | JANET_TFLAG_SYMBOL) | JANET_TFLAG_BUFFER) | JANET_TFLAG_KEYWORD;
pub const JANET_TFLAG_INDEXED = JANET_TFLAG_ARRAY | JANET_TFLAG_TUPLE;
pub const JANET_TFLAG_DICTIONARY = JANET_TFLAG_TABLE | JANET_TFLAG_STRUCT;
pub const JANET_TFLAG_LENGTHABLE = (JANET_TFLAG_BYTES | JANET_TFLAG_INDEXED) | JANET_TFLAG_DICTIONARY;
pub const JANET_TFLAG_CALLABLE = ((JANET_TFLAG_FUNCTION | JANET_TFLAG_CFUNCTION) | JANET_TFLAG_LENGTHABLE) | JANET_TFLAG_ABSTRACT;

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

pub const JANET_NANBOX_TAGBITS = @as(c_ulonglong, 0xFFFF800000000000);
pub const JANET_NANBOX_PAYLOADBITS = @as(c_ulonglong, 0x00007FFFFFFFFFFF);

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

pub const JANET_SANDBOX_SANDBOX = @as(c_int, 1);
pub const JANET_SANDBOX_SUBPROCESS = @as(c_int, 2);
pub const JANET_SANDBOX_NET_CONNECT = @as(c_int, 4);
pub const JANET_SANDBOX_NET_LISTEN = @as(c_int, 8);
pub const JANET_SANDBOX_FFI_DEFINE = @as(c_int, 16);
pub const JANET_SANDBOX_FS_WRITE = @as(c_int, 32);
pub const JANET_SANDBOX_FS_READ = @as(c_int, 64);
pub const JANET_SANDBOX_HRTIME = @as(c_int, 128);
pub const JANET_SANDBOX_ENV = @as(c_int, 256);
pub const JANET_SANDBOX_DYNAMIC_MODULES = @as(c_int, 512);
pub const JANET_SANDBOX_FS_TEMP = @as(c_int, 1024);
pub const JANET_SANDBOX_FFI_USE = @as(c_int, 2048);
pub const JANET_SANDBOX_FFI_JIT = @as(c_int, 4096);
pub const JANET_SANDBOX_SIGNAL = @as(c_int, 8192);
pub const JANET_SANDBOX_CHROOT = @as(c_int, 16384);
pub const JANET_SANDBOX_FFI = (JANET_SANDBOX_FFI_DEFINE | JANET_SANDBOX_FFI_USE) | JANET_SANDBOX_FFI_JIT;
pub const JANET_SANDBOX_FS = (JANET_SANDBOX_FS_WRITE | JANET_SANDBOX_FS_READ) | JANET_SANDBOX_FS_TEMP;
pub const JANET_SANDBOX_NET = JANET_SANDBOX_NET_CONNECT | JANET_SANDBOX_NET_LISTEN;
pub const JANET_SANDBOX_COMPILE = helpers.promoteIntLiteral(c_int, 32768, .decimal);
pub const JANET_SANDBOX_ASM = helpers.promoteIntLiteral(c_int, 65536, .decimal);
pub const JANET_SANDBOX_THREADS = helpers.promoteIntLiteral(c_int, 131072, .decimal);
pub const JANET_SANDBOX_UNMARSHAL = helpers.promoteIntLiteral(c_int, 262144, .decimal);
pub const JANET_SANDBOX_EXIT = helpers.promoteIntLiteral(c_int, 524288, .decimal);
pub const JANET_SANDBOX_ALL = @as(c_uint, 0xFFFFFFFF);

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

pub const JANET_DOUBLE_OFFSET = helpers.promoteIntLiteral(c_int, 0xFFFF, .hex);

pub const JANET_HASH_KEY_SIZE = @as(c_int, 16);
