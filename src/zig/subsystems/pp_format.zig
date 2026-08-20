//! Janet's format-string engine: the parser for a conversion specifier, and the
//! two drivers that walk a format string and render one item per specifier.
//!
//! Adapted, like the C it replaces, from Lua's `lstrlib.c`. A specifier is
//! rewritten into an ordinary C one and handed to `snprintf` for the numeric
//! and string conversions; the seven Janet-specific ones — `%v`, `%V`, `%t`,
//! `%T`, `%j`, and the eight spellings of pretty-printing — are rendered here.
//!
//! ## The variadic ABI is gone, and with it the last C in `pp.c`
//!
//! This engine used to be reached through a C variadic shell. `janet_formatc`,
//! `janet_formatb`, `janet_formatbv` and `janet_panicf` kept C bodies and this
//! file **pulled** its arguments: `janet_zig_formatbv` took the `va_list` as an
//! opaque pointer it never dereferenced and asked C for the next argument of
//! whatever type the specifier it had just parsed called for, through six
//! three-line `va_arg` accessors in `pp.c`. That order was forced -- only the
//! engine knows what type comes next, because only the engine has parsed the
//! format string -- and the shells were there because Zig 0.16 cannot name a
//! `va_list` on `aarch64-linux`, where `std.builtin.VaList` is a
//! `@compileError("disabled due to miscompilations")` under the LLVM backend.
//!
//! Part 18 deleted all of it. Every caller was a Zig caller already, and every
//! one of them was carrying a tuple and flattening it into C's calling
//! convention on the last line; `formatTuple` below takes the tuple instead.
//! The walk happens once, at compile time, so the engine *indexes* rather than
//! pulls, and the specifier and the value it renders are checked against each
//! other at the call site. `FOUND.md` has four entries that are exactly the
//! mistake that check now rejects.
//!
//! ## Two loops, not one engine
//!
//! `formatTuple` and `janet_buffer_format` look like the same function and
//! are not. `%D` and `%d` are separate cases in the first and one case in the
//! second; `%s` reads a `const char *` in the first and a Janet value through
//! `janet_getcbytes` in the second; `%S` and `%T` exist only in the first, and
//! only the second can run out of arguments. They are two loops here as they
//! are two functions in C, sharing the specifier parser, the item buffer and
//! the pretty-flag decoding rather than being folded into one driver with a
//! source parameter.
//!
const std = @import("std");
const options = @import("options");
const abi = @import("abi");
const c = abi.c;
const stdio = @import("stdio.zig");
const printer = @import("printer.zig");
const containers = @import("containers.zig");
const arglayer = @import("arglayer.zig");
const raise = @import("raise");
const pretty = @import("pp_pretty.zig");

/// `MAX_ITEM`: the scratch one rendered conversion goes into.
const max_item = 256;
/// `MAX_FORMAT`: the scratch the rewritten specifier is built in.
const max_format = 32;
/// `FMT_FLAGS`, and the count that makes a repeat detectable.
const fmt_flags = "-+ #0";
/// `FMT_REPLACE_INTTYPES`: the conversions whose length modifier is rewritten.
const fmt_replace_inttypes = "diouxX";

/// `JANET_COLUMNS` and `JANET_RECURSION_GUARD`.
const columns_default: c_int = 80;
const recursion_guard: c_int = 1024;

const pretty_color: c_int = 1;
const pretty_oneline: c_int = 2;
const pretty_notrunc: c_int = 4;

extern fn snprintf(buffer: [*c]u8, size: usize, format: [*c]const u8, ...) callconv(.c) c_int;

// ------------------------------------------------------ the specifier parser

/// One parsed conversion specifier.
const Specifier = struct {
    /// The rewritten C specifier, NUL-terminated, ready for `snprintf`.
    form: [max_format]u8,
    /// The digits of the field width and of the precision, each NUL-padded.
    /// They are kept as text because the pretty conversions read them with
    /// `atoi` while `snprintf` reads them out of `form`.
    width: [3]u8,
    precision: [3]u8,
    /// How far into the format string the parse got: the index of the
    /// conversion character itself.
    at: usize,

    /// True when the specifier is a bare `%s` with no flags, width or
    /// precision, which both drivers special-case to avoid `snprintf`.
    inline fn isPlain(self: *const Specifier) bool {
        return self.form[2] == 0;
    }

    /// `strchr(form, '.')`: whether a precision was given. Without one,
    /// `snprintf` will write as many bytes as the argument has.
    fn hasPrecision(self: *const Specifier) bool {
        return std.mem.indexOfScalar(u8, std.mem.sliceTo(&self.form, 0), '.') != null;
    }

    /// `atoi` over one of the two digit fields.
    fn number(digits: *const [3]u8) c_int {
        var value: c_int = 0;
        for (digits) |digit| {
            if (digit < '0' or digit > '9') break;
            value = value * 10 + (digit - '0');
        }
        return value;
    }
};

/// The length modifier `%d` and its five siblings are rewritten to, so that a
/// conversion always reads a fixed-width 64-bit argument.
///
/// C spells this `PRId64` and its kin. Deriving it from the width of `long` is
/// what those macros do, and it keeps the answer right on `riscv32`, where a
/// 64-bit argument needs `ll` and `l` would read half of one.
const int64_modifier = if (@sizeOf(c_long) == 8) "l" else "ll";

/// The six conversions of `fmt_replace_inttypes`, and only those.
///
/// `%D` and `%I` are deliberately absent, which reproduces a defect rather than
/// tidying one. C's `format_mappings` table carries entries for both, but
/// `scanformat` consults it only for characters in `FMT_REPLACE_INTTYPES`,
/// which are lower case — so the two upper-case entries are dead, `%D` and `%I`
/// reach `snprintf` unrewritten, and what they print is whatever the host libc
/// makes of an invalid conversion. `FOUND.md` has the measurement.
fn intMapping(conversion: u8) []const u8 {
    return switch (conversion) {
        'd' => int64_modifier ++ "d",
        'i' => int64_modifier ++ "i",
        'o' => int64_modifier ++ "o",
        'u' => int64_modifier ++ "u",
        'x' => int64_modifier ++ "x",
        'X' => int64_modifier ++ "X",
        else => unreachable,
    };
}

/// `scanformat`. Reads one specifier starting just after the `%`, and rebuilds
/// it into `form` with the integer conversions widened.
///
/// The rebuild copies through the conversion character inclusively, so `%5d`
/// becomes `%5lld` rather than `%5` — which is why an unrecognised conversion
/// can be named in full in the panic message that reports it.
fn scanFormat(strfrmt: [*c]const u8, start: usize) raise.Raising(Specifier) {
    var spec = Specifier{ .form = undefined, .width = .{ 0, 0, 0 }, .precision = .{ 0, 0, 0 }, .at = start };

    var p = start;
    while (strfrmt[p] != 0 and std.mem.indexOfScalar(u8, fmt_flags, strfrmt[p]) != null) p += 1;
    if (p - start >= fmt_flags.len + 1) return raise.panic("invalid format (repeated flags)");

    if (isDigit(strfrmt[p])) {
        spec.width[0] = strfrmt[p];
        p += 1;
    }
    if (isDigit(strfrmt[p])) {
        spec.width[1] = strfrmt[p];
        p += 1;
    }
    if (strfrmt[p] == '.') {
        p += 1;
        if (isDigit(strfrmt[p])) {
            spec.precision[0] = strfrmt[p];
            p += 1;
        }
        if (isDigit(strfrmt[p])) {
            spec.precision[1] = strfrmt[p];
            p += 1;
        }
    }
    if (isDigit(strfrmt[p])) return raise.panic("invalid format (width or precision too long)");

    var out: usize = 0;
    spec.form[out] = '%';
    out += 1;
    var from = start;
    while (from <= p) {
        const byte = strfrmt[from];
        if (byte != 0 and std.mem.indexOfScalar(u8, fmt_replace_inttypes, byte) != null) {
            const mapping = intMapping(byte);
            @memcpy(spec.form[out..][0..mapping.len], mapping);
            out += mapping.len;
            from += 1;
        } else {
            spec.form[out] = byte;
            out += 1;
            from += 1;
        }
    }
    spec.form[out] = 0;
    spec.at = p;
    return spec;
}

inline fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

// ------------------------------------------------------- rendering one item

/// The scratch a `snprintf` conversion is rendered into, and the check that
/// what came back fits. C keeps `item` and `nb` as two locals per loop; making
/// them one value is what stops a driver from pushing a stale `item`.
const Item = struct {
    bytes: [max_item]u8 = undefined,
    count: c_int = 0,

    /// Render through `snprintf` with the rebuilt specifier.
    fn render(self: *Item, spec: *const Specifier, arg: anytype) void {
        self.count = snprintf(&self.bytes, max_item, &spec.form, arg);
    }

    /// Append what was rendered, if anything. A driver that wrote to the
    /// buffer directly leaves `count` at zero and pushes nothing here.
    fn flush(self: *const Item, b: *c.JanetBuffer) raise.Raising(void) {
        if (self.count >= max_item) return raise.panic("format buffer overflow");
        if (self.count > 0) try containers.bufferPushBytes(b, &self.bytes, self.count);
    }
};

/// The pretty printer's three flags and two numbers, decoded from the
/// conversion character and the specifier's width and precision.
///
/// Eight characters select the same printer: case picks colour, `q`/`Q` and
/// `n`/`N` pick one-line, and `m`/`M` and `n`/`N` pick no truncation.
const PrettyOpts = struct {
    depth: c_int,
    columns: c_int,
    flags: c_int,

    fn decode(conversion: u8, spec: *const Specifier) PrettyOpts {
        var depth = Specifier.number(&spec.precision);
        if (depth < 1) depth = recursion_guard;

        const has_color = conversion == 'P' or conversion == 'Q' or conversion == 'M' or conversion == 'N';
        var has_oneline = conversion == 'Q' or conversion == 'q' or conversion == 'N' or conversion == 'n';
        const has_notrunc = conversion == 'M' or conversion == 'm' or conversion == 'N' or conversion == 'n';

        var columns = Specifier.number(&spec.width);
        if (columns == 0) {
            columns = columns_default;
        } else if (columns < 0) {
            // Unreachable: the width field holds only digits, because '-' is
            // consumed as a flag before it. Reproduced from the C, and
            // recorded in `FOUND.md`.
            has_oneline = true;
        }

        return .{
            .depth = depth,
            .columns = columns,
            .flags = (if (has_color) pretty_color else 0) |
                (if (has_oneline) pretty_oneline else 0) |
                (if (has_notrunc) pretty_notrunc else 0),
        };
    }
};

/// The eight pretty conversions and `%j`, which both drivers render the same
/// way once the value and the barrier are in hand.
fn renderPretty(b: *c.JanetBuffer, conversion: u8, spec: *const Specifier, x: c.Janet, startlen: i32) raise.Raising(void) {
    if (conversion == 'j') {
        var depth = Specifier.number(&spec.precision);
        if (depth < 1) depth = recursion_guard;
        _ = try pretty.jdnImpl(b, depth, x, startlen, b.count);
        return;
    }
    const opts = PrettyOpts.decode(conversion, spec);
    _ = try pretty.prettyBuffer(b, opts.depth, opts.columns, opts.flags, x, startlen, b.count);
}

/// `typestr`. An abstract value reports its own type's name rather than
/// `"abstract"`, which is the whole point of `%t` over `%T`.
fn typestr(x: c.Janet) [*c]const u8 {
    const t = c.janet_type(x);
    if (t == c.JANET_ABSTRACT) return c.janet_abstract_type(c.janet_unwrap_abstract(x)).*.name;
    return c.janet_type_names[@intCast(t)];
}

/// `pushtypes`. Renders a type *set* — the bitmask an argument check reports —
/// as `"a, b or c"`.
fn pushtypes(b: *c.JanetBuffer, typeflags: c_int) raise.Raising(void) {
    var types = typeflags;
    var first = true;
    var i: usize = 0;
    while (types != 0) : ({
        i += 1;
        types >>= 1;
    }) {
        if (1 & types == 0) continue;
        if (first) {
            first = false;
        } else {
            // The last one is joined with "or" rather than a comma, and
            // `types == 1` is exactly the test for being on it.
            try containers.bufferPushCString(b, if (types == 1) " or " else ", ");
        }
        try containers.bufferPushCString(b, c.janet_type_names[i]);
    }
}

// ------------------------------------------------ the comptime-tuple driver

/// One step of a format string, decided at compile time.
///
/// The variadic driver this replaces could not do it: only the engine knows
/// what type comes next, because only the engine has parsed the format string,
/// and a `va_list` cursor can only be advanced forwards at runtime. A tuple is
/// indexed instead, so the walk happens once, at compile time, and what comes
/// out is a straight line of literal pushes and renders.
const Op = union(enum) {
    /// A run of bytes copied through, including a `%%` that became one `%`.
    literal: []const u8,
    /// One conversion: the rewritten specifier, the conversion character, and
    /// which element of the argument tuple it consumes.
    conversion: struct {
        spec: Specifier,
        conversion: u8,
        arg: usize,
    },
};

/// `format[i]`, or the NUL the runtime parser would have found past the end.
/// `scanFormat` walks off the end of a specifier deliberately -- a trailing
/// `%` leaves it reading the terminator -- and a slice has to say so.
fn byteAt(comptime format: []const u8, comptime i: usize) u8 {
    return if (i < format.len) format[i] else 0;
}

/// `scanFormat` at compile time. Same grammar and the same rewrite, with the
/// two faults reported as compile errors: a format string is a literal here,
/// so a bad one is a bug in this tree rather than in a Janet program.
fn comptimeScan(comptime format: []const u8, comptime start: usize) Specifier {
    comptime {
        var spec = Specifier{
            .form = [_]u8{0} ** max_format,
            .width = .{ 0, 0, 0 },
            .precision = .{ 0, 0, 0 },
            .at = start,
        };

        var p = start;
        while (byteAt(format, p) != 0 and
            std.mem.indexOfScalar(u8, fmt_flags, byteAt(format, p)) != null) p += 1;
        if (p - start >= fmt_flags.len + 1)
            @compileError("invalid format (repeated flags): " ++ format);

        if (isDigit(byteAt(format, p))) {
            spec.width[0] = byteAt(format, p);
            p += 1;
        }
        if (isDigit(byteAt(format, p))) {
            spec.width[1] = byteAt(format, p);
            p += 1;
        }
        if (byteAt(format, p) == '.') {
            p += 1;
            if (isDigit(byteAt(format, p))) {
                spec.precision[0] = byteAt(format, p);
                p += 1;
            }
            if (isDigit(byteAt(format, p))) {
                spec.precision[1] = byteAt(format, p);
                p += 1;
            }
        }
        if (isDigit(byteAt(format, p)))
            @compileError("invalid format (width or precision too long): " ++ format);

        var out: usize = 0;
        spec.form[out] = '%';
        out += 1;
        var from = start;
        while (from <= p) {
            const byte = byteAt(format, from);
            if (byte != 0 and std.mem.indexOfScalar(u8, fmt_replace_inttypes, byte) != null) {
                const mapping = intMapping(byte);
                for (mapping) |m| {
                    spec.form[out] = m;
                    out += 1;
                }
                from += 1;
            } else {
                spec.form[out] = byte;
                out += 1;
                from += 1;
            }
        }
        spec.form[out] = 0;
        spec.at = p;
        return spec;
    }
}

/// Walk a format string once, at compile time, into the steps that render it.
fn compileFormat(comptime format: []const u8) []const Op {
    comptime {
        var ops: []const Op = &.{};
        var literal_from: usize = 0;
        var i: usize = 0;
        var argi: usize = 0;

        while (i < format.len) {
            if (format[i] != '%') {
                i += 1;
                continue;
            }
            if (i > literal_from) ops = ops ++ &[_]Op{.{ .literal = format[literal_from..i] }};
            i += 1;
            if (byteAt(format, i) == '%') {
                ops = ops ++ &[_]Op{.{ .literal = "%" }};
                i += 1;
                literal_from = i;
                continue;
            }

            const spec = comptimeScan(format, i);
            ops = ops ++ &[_]Op{.{ .conversion = .{
                .spec = spec,
                .conversion = byteAt(format, spec.at),
                .arg = argi,
            } }};
            argi += 1;
            i = spec.at + 1;
            literal_from = i;
        }
        if (literal_from < format.len) ops = ops ++ &[_]Op{.{ .literal = format[literal_from..] }};
        return ops;
    }
}

/// Render one conversion. The coercions are what the `va_arg` accessors used
/// to be, and they are the whole point of the change: `@as` rejects a
/// narrowing, so a caller handing `%d` a 64-bit value is a compile error where
/// it used to be undefined behaviour. `FOUND.md` has four entries that are
/// exactly this mistake, three of them in code this runtime still runs.
inline fn renderConversion(
    b: *c.JanetBuffer,
    comptime spec: Specifier,
    comptime conversion: u8,
    arg: anytype,
    startlen: i32,
) raise.Raising(void) {
    const local: Specifier = spec;
    var item = Item{};
    switch (conversion) {
        // `%c` reads an `int` and is rendered as one: its specifier is not in
        // the rewritten set, so `snprintf` reads an `int` back.
        'c' => item.render(&local, @as(c_int, arg)),
        // `%d` and `%i` render 64 bits: `scanFormat` rewrote the specifier to
        // `%lld`. The variadic driver still pulled an `int32_t` and widened it,
        // because that is what C's `janet_formatbv` did -- an artifact of the
        // `va_list`, not of the conversion. Nothing pulls now, so the value the
        // caller passed is the value that renders, and the three `int64_t`
        // indices in `args_core.zig` stop being undefined. `FOUND.md` records
        // both sites under Part 8's rule: a mismatched vararg width has no
        // defined behaviour to reproduce, so the port gets it right.
        'd', 'i' => item.render(&local, @as(i64, arg)),
        'D', 'I' => item.render(&local, @as(i64, arg)),
        'x', 'X', 'o', 'u' => item.render(&local, @as(u64, arg)),
        'a', 'A', 'e', 'E', 'f', 'g', 'G' => item.render(&local, @as(f64, arg)),

        's', 'S' => {
            const str = asCString(arg);
            // `%s` is a C string and `%S` a Janet one, which is the only
            // difference: the second knows its length without walking.
            const len: i32 = if (conversion == 's')
                @intCast(std.mem.len(str))
            else
                c.janet_string_length(str);
            if (local.isPlain()) {
                try containers.bufferPushBytes(b, str, len);
            } else if (len != @as(i32, @intCast(std.mem.len(str)))) {
                // A width or precision means `snprintf`, which stops at the
                // first NUL and would silently drop the rest.
                return raise.panic("string contains zeros");
            } else if (!local.hasPrecision() and len >= 100) {
                return raise.panic("no precision and string is too long to be formatted");
            } else {
                item.render(&local, str);
            }
        },

        'V' => try printer.toStringB(b, @as(c.Janet, arg)),
        'v' => try printer.descriptionB(b, @as(c.Janet, arg)),
        't' => try containers.bufferPushCString(b, typestr(@as(c.Janet, arg))),
        'T' => try pushtypes(b, @as(c_int, arg)),

        'M', 'm', 'N', 'n', 'Q', 'q', 'P', 'p', 'j' => try renderPretty(
            b,
            conversion,
            &local,
            @as(c.Janet, arg),
            startlen,
        ),

        // Also where 'n', 'L', 'l' and 'h' land, none of which Janet has. The
        // variadic driver raised here; a literal cannot, so this is the one
        // place the two disagree, and it disagrees in the safer direction.
        else => @compileError(
            "invalid conversion '" ++ [_]u8{conversion} ++ "' to 'format'",
        ),
    }
    try item.flush(b);
}

/// The `%s` and `%S` coercion. Anything that is already a NUL-terminated run
/// of bytes is accepted and nothing else is; a Janet value handed to `%s` is
/// the mistake `FOUND.md` records twice in `os.c`, and it is a compile error
/// here rather than a denormal in the message.
inline fn asCString(arg: anytype) [*c]const u8 {
    const T = @TypeOf(arg);
    return switch (@typeInfo(T)) {
        .pointer => @ptrCast(arg),
        else => @compileError("format: %s and %S want a C string, not " ++ @typeName(T)),
    };
}

/// `janet_formatbv`'s replacement: append a formatted message to a buffer.
///
/// The format string is `comptime` and the arguments are a tuple, so the
/// specifier and the value it renders are checked against each other at the
/// call site.
pub fn formatTuple(
    b: *c.JanetBuffer,
    comptime format: [:0]const u8,
    args: anytype,
) raise.Raising(void) {
    const ops = comptime compileFormat(format);
    comptime {
        var wanted: usize = 0;
        for (ops) |op| {
            if (op == .conversion) wanted += 1;
        }
        const given = @typeInfo(@TypeOf(args)).@"struct".fields.len;
        if (wanted != given) @compileError(std.fmt.comptimePrint(
            "format \"{s}\" has {d} conversions and was given {d} arguments",
            .{ format, wanted, given },
        ));
    }

    const startlen = b.count;
    inline for (ops) |op| {
        switch (op) {
            .literal => |text| try containers.bufferPushBytes(b, text.ptr, text.len),
            .conversion => |cv| try renderConversion(
                b,
                cv.spec,
                cv.conversion,
                args[cv.arg],
                startlen,
            ),
        }
    }
}

// ---------------------------------------------------- the three entry points

/// `janet_formatc`: render into a scratch buffer and return a Janet string.
///
/// The `errdefer` is new. C could not have one — the raise left through a
/// `longjmp` and the buffer it had allocated was stranded — and decision 1
/// bought it back. Nothing observable changes; a raise from `%v`'s `tostring`
/// callback simply stops leaking the scratch.
pub fn formatc(comptime format: [:0]const u8, args: anytype) raise.Raising(c.JanetString) {
    var buffer: c.JanetBuffer = undefined;
    _ = c.janet_buffer_init(&buffer, @intCast(format.len));
    errdefer c.janet_buffer_deinit(&buffer);
    try formatTuple(&buffer, format, args);
    const result = c.janet_string(buffer.data, buffer.count);
    c.janet_buffer_deinit(&buffer);
    return result;
}

/// `janet_formatb`: append to a buffer the caller owns, and hand it back.
pub fn formatb(
    buffer: *c.JanetBuffer,
    comptime format: [:0]const u8,
    args: anytype,
) raise.Raising(*c.JanetBuffer) {
    try formatTuple(buffer, format, args);
    return buffer;
}

/// `janet_dynprintf`. Write a formatted message to whatever `(dyn name)` names,
/// falling back to `dflt_file` when the dynamic binding is absent.
///
/// This was the fourth C variadic and the last one out. `name` stays a runtime
/// pointer because C allowed NULL and the empty string to mean "use the default
/// directly"; only `format` had to become `comptime`, and every caller passed a
/// literal already.
///
/// The `defer` is new and closes two leaks the C had, both on paths that leave
/// the switch without reaching `janet_buffer_deinit`: an abstract that is not a
/// file, and the raise from `assertWriteable`. `FOUND.md` records them. The
/// order of the two is C's -- format first, then check the file -- so the
/// message a non-writeable file raises is unchanged.
pub fn dynprintf(
    name: [*c]const u8,
    /// `?*anyopaque` rather than a `FILE *`: `io_core.zig` declares `FILE`
    /// opaque on purpose and every caller reaches its handle through its own
    /// `stdio.err` declaration over `@cImport`'s translation. They are
    /// the same pointer and not the same Zig type.
    dflt_file: ?*anyopaque,
    comptime format: [:0]const u8,
    args: anytype,
) raise.Raising(void) {
    var x: c.Janet = undefined;
    var xtype: c.JanetType = undefined;
    if (name == null or name[0] == 0) {
        x = c.janet_wrap_nil();
        xtype = c.JANET_NIL;
    } else {
        x = c.janet_dyn(name);
        xtype = c.janet_type(x);
    }

    switch (xtype) {
        c.JANET_NIL, c.JANET_ABSTRACT => {
            var f: ?*anyopaque = dflt_file;
            var buffer: c.JanetBuffer = undefined;
            _ = c.janet_buffer_init(&buffer, @intCast(format.len));
            defer c.janet_buffer_deinit(&buffer);
            try formatTuple(&buffer, format, args);
            if (xtype == c.JANET_ABSTRACT) {
                const abstract = c.janet_unwrap_abstract(x);
                if (c.janet_abstract_type(abstract) != @as(*const c.JanetAbstractType, @ptrCast(&janet_file_type))) return;
                const iofile: *c.JanetFile = @ptrCast(@alignCast(abstract));
                janet_zig_io_assert_writeable(iofile);
                _ = try raise.crossing({});
                f = iofile.file;
            }
            _ = janet_io_write(f, buffer.data, @intCast(buffer.count));
        },
        c.JANET_FUNCTION => {
            const fun = c.janet_unwrap_function(x);
            const buf = c.janet_buffer(@intCast(format.len));
            try formatTuple(buf, format, args);
            var call_args = [_]c.Janet{c.janet_wrap_buffer(buf)};
            _ = c.janet_call(fun, 1, &call_args);
            _ = try raise.crossing({});
        },
        c.JANET_BUFFER => try formatTuple(c.janet_unwrap_buffer(x), format, args),
        // Other values simply do nothing, which is the C original's `default`.
        else => {},
    }
}

/// The three symbols `dynprintf` takes from `io_core.zig` through the C ABI
/// rather than by import, because importing would make this file depend on the
/// whole io surface and would pull that surface into this subsystem's
/// contract. `janet_file_type` is an `export const` there and is compared by
/// address, so an extern declaration is the same object.
extern fn janet_zig_io_assert_writeable(iof: *c.JanetFile) callconv(.c) void;
extern fn janet_io_write(handle: ?*anyopaque, src: [*c]const u8, count: usize) callconv(.c) i32;
extern const janet_file_type: c.JanetAbstractType;

/// `formatc` at a site that cannot carry a raise.
///
/// Eleven call sites in six files are like this, and they are one population
/// rather than six problems: a C-ABI face, or an internal result type whose
/// error channel is a message pointer rather than an error union. Rule 11
/// describes it -- a raise converts as far as the nearest fixed boundary and
/// stops there -- and rule 19 says what retires it, which is an ordinary
/// import rather than a report. Part 18 has the rest of that work.
///
/// Until then this is what the variadic shell already did: `janet_formatc`
/// reached a panicking face, which recorded the raise and returned a blank
/// string. Behaviour is unchanged; what changes is that the site says so.
pub fn formatcReported(comptime format: [:0]const u8, args: anytype) c.JanetString {
    return raise.reported(formatc(format, args));
}

/// `janet_panicf`: raise with a formatted message.
///
/// This was `raise.panicf` until the variadic surface went. It moved here
/// rather than staying there because `raise.zig` is the shared mechanism and
/// this needs the pretty printer -- `%v` and the eight spellings of `%q` run
/// it -- which is a subsystem. The 185 call sites say `pp_format.panicf` now.
pub fn panicf(comptime format: [:0]const u8, args: anytype) raise.Error {
    // Rendering `%v` runs an abstract type's `tostring` callback, so the
    // formatter really can raise. That raise is the real one and wins; the
    // variadic spelling had to detect it through a flag, and this returns it.
    const message = formatc(format, args) catch |err| return err;
    return raise.panicv(c.janet_wrap_string(message));
}
// -------------------------------------------------- the Janet-array driver

/// `janet_buffer_format`, which is what `string/format` and `buffer/format`
/// run. It needs no C at all: the arguments arrive as a `Janet` array.
pub fn bufferFormat(
    b: *c.JanetBuffer,
    strfrmt: [*c]const u8,
    argstart: i32,
    argc: i32,
    argv: [*c]c.Janet,
) raise.Raising(void) {
    const startlen = b.count;
    var arg = argstart;
    var at: usize = 0;
    while (strfrmt[at] != 0) {
        if (strfrmt[at] != '%') {
            try containers.bufferPushU8(b, strfrmt[at]);
            at += 1;
            continue;
        }
        at += 1;
        if (strfrmt[at] == '%') {
            try containers.bufferPushU8(b, strfrmt[at]);
            at += 1;
            continue;
        }

        arg += 1;
        if (arg >= argc) return raise.panic("not enough values for format");

        const spec = try scanFormat(strfrmt, at);
        const conversion = strfrmt[spec.at];
        at = spec.at + 1;

        var item = Item{};
        switch (conversion) {
            'c' => item.render(&spec, @as(c_int, @intCast(try arglayer.getInteger(argv, arg)))),
            // Unlike the variadic driver, the four integer spellings are one
            // case: the argument is a Janet number either way.
            'D', 'I', 'd', 'i' => item.render(&spec, try arglayer.getInteger64(argv, arg)),
            'x', 'X', 'o', 'u' => item.render(&spec, try arglayer.getUInteger64(argv, arg)),
            'a', 'A', 'e', 'E', 'f', 'g', 'G' => item.render(&spec, try arglayer.getNumber(argv, arg)),

            's' => {
                const s = try arglayer.getCBytes(argv, arg);
                if (spec.isPlain()) {
                    try containers.bufferPushCString(b, s);
                } else {
                    item.render(&spec, s);
                }
            },

            'V' => try printer.toStringB(b, argv[@intCast(arg)]),
            'v' => try printer.descriptionB(b, argv[@intCast(arg)]),
            't' => try containers.bufferPushCString(b, typestr(argv[@intCast(arg)])),

            'M', 'm', 'N', 'n', 'Q', 'q', 'P', 'p', 'j' => try renderPretty(
                b,
                conversion,
                &spec,
                argv[@intCast(arg)],
                startlen,
            ),

            else => return panicf("invalid conversion '%s' to 'format'", .{&spec.form}),
        }
        try item.flush(b);
    }
}

pub const bufferFormatPanicking = raise.panicking(bufferFormat).face;

// ----------------------------------------------------------------- exports

comptime {
    // `janet_buffer_format` is internal and hidden, exactly as the C build
    // hides it. `janet_zig_formatbv` stood beside it until the variadic
    // surface went; the tuple driver has no C face, because it has no C
    // caller and could not have one.
    // Gated on the selector rather than unconditional, so that a *contract*
    // module can root itself at this file and instantiate the comptime-generic
    // drivers without redefining the runtime's symbols. `root.zig` gates the
    // import on the same flag, so this costs the runtime nothing.
    if (options.pp) @export(&bufferFormatPanicking, .{ .name = "janet_buffer_format", .visibility = .hidden });
}
