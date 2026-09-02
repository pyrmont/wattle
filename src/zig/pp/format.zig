//! Janet's format-string engine: the parser for a conversion specifier, and the
//! two drivers that walk a format string and render one item per specifier.
//!
//! Adapted, like the C it replaces, from Lua's `lstrlib.c`. A specifier is
//! rewritten into an ordinary C one and handed to `c.snprintf` for the numeric
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
//! None of that is here. Every caller was a Zig caller carrying a tuple and
//! flattening it into C's calling convention on the last line; `formatTuple`
//! below takes the tuple instead. The walk happens once, at compile time, so
//! the engine *indexes* rather than pulls, and the specifier and the value it
//! renders are checked against each other at the call site. A conversion
//! handed the wrong type or the wrong width is a compile error rather than a
//! `va_arg` reading whatever the caller happened to push.
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
const repr = @import("repr");
const c = @import("cabi");
const pp_describe = @import("../pp.zig");
const args_core = @import("../args.zig");
const raise = @import("../raise.zig");
const pretty = @import("pretty.zig");
const buffers = @import("../value/buffers.zig");
const strings = @import("../value/strings.zig");
const vm_state = @import("../vm/state.zig");
const wrap = @import("../value/helpers/wrap.zig");
const utils = @import("../utils.zig");
const host = @import("host");
const io_core = @import("../io.zig");
const vm_entry = @import("../vm/entry.zig");
const abi = @import("abi");

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

// ------------------------------------------------------ the specifier parser

/// One parsed conversion specifier.
const Specifier = struct {
    /// The rewritten C specifier, NUL-terminated, ready for `c.snprintf`.
    form: [max_format]u8,
    /// The digits of the field width and of the precision, each NUL-padded.
    /// They are kept as text because the pretty conversions read them with
    /// `atoi` while `c.snprintf` reads them out of `form`.
    width: [3]u8,
    precision: [3]u8,
    /// How far into the format string the parse got: the index of the
    /// conversion character itself.
    at: usize,

    /// True when the specifier is a bare `%s` with no flags, width or
    /// precision, which both drivers special-case to avoid `c.snprintf`.
    inline fn isPlain(self: *const Specifier) bool {
        return self.form[2] == 0;
    }

    /// `strchr(form, '.')`: whether a precision was given. Without one,
    /// `c.snprintf` will write as many bytes as the argument has.
    fn hasPrecision(self: *const Specifier) bool {
        return std.mem.indexOfScalar(u8, std.mem.sliceTo(&self.form, 0), '.') != null;
    }

    /// `atoi` over one of the two digit fields.
    fn number(digits: *const [3]u8) c_int {
        var val: c_int = 0;
        for (digits) |digit| {
            if (digit < '0' or digit > '9') break;
            val = val * 10 + (digit - '0');
        }
        return val;
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
/// **`%D` and `%I` are not conversions.** C's `format_mappings` table carries
/// entries for both, and `scanformat` consults that table only for the
/// characters in `FMT_REPLACE_INTTYPES`, which are lower case — so the two
/// upper-case entries are unreachable, the specifier reaches `c.snprintf`
/// unrewritten, and what it prints is whatever the host libc makes of an
/// unrecognised conversion. That is `%ld` on macOS, which accepts `%D` as a
/// BSD synonym, and nothing on glibc or musl. A conversion that means
/// different things on different hosts is not one, so both take the
/// invalid-conversion path here.
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
fn scanFormat(strfrmt: [*]const u8, start: usize) raise.Raising(Specifier) {
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

/// The scratch a `c.snprintf` conversion is rendered into, and the check that
/// what came back fits. C keeps `item` and `nb` as two locals per loop; making
/// them one value is what stops a driver from pushing a stale `item`.
const Item = struct {
    bytes: [max_item]u8 = undefined,
    count: c_int = 0,

    /// Render through `c.snprintf` with the rebuilt specifier.
    fn render(self: *Item, spec: *const Specifier, arg: anytype) void {
        self.count = c.snprintf(&self.bytes, max_item, @ptrCast(&spec.form), arg);
    }

    /// Append what was rendered, if anything. A driver that wrote to the
    /// buffer directly leaves `count` at zero and pushes nothing here.
    fn flush(self: *const Item, b: *buffers.Buffer) raise.Raising(void) {
        if (self.count >= max_item) return raise.panic("format buffer overflow");
        if (self.count > 0) try buffers.pushBytes(b, self.bytes[0..@intCast(self.count)]);
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
    flags: pretty.PrettyFlags,

    fn decode(conversion: u8, spec: *const Specifier) PrettyOpts {
        var depth = Specifier.number(&spec.precision);
        if (depth < 1) depth = recursion_guard;

        const has_color = conversion == 'P' or conversion == 'Q' or conversion == 'M' or conversion == 'N';
        const has_oneline = conversion == 'Q' or conversion == 'q' or conversion == 'N' or conversion == 'n';
        const has_notrunc = conversion == 'M' or conversion == 'm' or conversion == 'N' or conversion == 'n';

        // **The width cannot be negative**: `scanFormat` fills the field from
        // digits only, and a leading `-` is consumed as a flag before it. So a
        // zero is the only value that means anything other than a column
        // count, and it means "the default page". `%q` is how one-line output
        // is asked for.
        var columns = Specifier.number(&spec.width);
        if (columns == 0) columns = columns_default;

        return .{
            .depth = depth,
            .columns = columns,
            .flags = .{ .color = has_color, .oneline = has_oneline, .notrunc = has_notrunc },
        };
    }
};

/// The eight pretty conversions and `%j`, which both drivers render the same
/// way once the value and the barrier are in hand.
fn renderPretty(b: *buffers.Buffer, conversion: u8, spec: *const Specifier, x: repr.Value, startlen: usize) raise.Raising(void) {
    if (conversion == 'j') {
        var depth = Specifier.number(&spec.precision);
        if (depth < 1) depth = recursion_guard;
        _ = try pretty.jdn(b, depth, x, startlen, b.count);
        return;
    }
    const opts = PrettyOpts.decode(conversion, spec);
    _ = try pretty.prettyBuffer(b, opts.depth, opts.columns, opts.flags, x, startlen, b.count);
}

/// `typestr`. An abstract value reports its own type's name rather than
/// `"abstract"`, which is the whole point of `%t` over `%T`.
fn typestr(x: repr.Value) []const u8 {
    const t = repr.typeOf(x);
    if (t == .abstract) return abi.abstractHead(wrap.toAbstract(x)).type.name;
    return std.mem.span(utils.typeNames[@intFromEnum(t)]);
}

/// `pushtypes`. Renders a type *set* — the bitmask an argument check reports —
/// as `"a, b or c"`.
fn pushtypes(b: *buffers.Buffer, typeflags: repr.TagSet) raise.Raising(void) {
    var remaining = typeflags.bits();
    var first = true;
    var i: usize = 0;
    while (remaining != 0) : ({
        i += 1;
        remaining >>= 1;
    }) {
        if (1 & remaining == 0) continue;
        if (first) {
            first = false;
        } else {
            // The last one is joined with "or" rather than a comma, and
            // `remaining == 1` is exactly the test for being on it.
            try buffers.pushCString(b, if (remaining == 1) " or " else ", ");
        }
        try buffers.pushCString(b, utils.typeNames[i]);
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
/// a variadic driver would have read the wrong width and rendered whatever
/// that produced.
inline fn renderConversion(
    b: *buffers.Buffer,
    comptime spec: Specifier,
    comptime conversion: u8,
    arg: anytype,
    startlen: usize,
) raise.Raising(void) {
    const local: Specifier = spec;
    var item = Item{};
    switch (conversion) {
        // `%c` reads an `int` and is rendered as one: its specifier is not in
        // the rewritten set, so `c.snprintf` reads an `int` back.
        'c' => item.render(&local, @as(c_int, arg)),
        // `%d` and `%i` render 64 bits: `scanFormat` rewrote the specifier to
        // `%lld`. A variadic driver pulled an `int32_t` and widened it, which
        // was an artifact of the `va_list` rather than of the conversion.
        // Nothing pulls now, so the value the caller passed is the value that
        // renders.
        'd', 'i' => item.render(&local, @as(i64, arg)),
        'x', 'X', 'o', 'u' => item.render(&local, @as(u64, arg)),
        'a', 'A', 'e', 'E', 'f', 'g', 'G' => item.render(&local, @as(f64, arg)),

        's', 'S' => {
            const str = asCString(arg);
            // `%s` is a C string and `%S` a Janet one, which is the only
            // difference: the second knows its length without walking.
            const len: usize = if (conversion == 's')
                std.mem.len(str)
            else
                strings.head(str).length;
            if (local.isPlain()) {
                try buffers.pushBytes(b, str[0..len]);
            } else if (len != std.mem.len(str)) {
                // A width or precision means `c.snprintf`, which stops at the
                // first NUL and would silently drop the rest.
                return raise.panic("string contains zeros");
            } else if (!local.hasPrecision() and len >= 100) {
                return raise.panic("no precision and string is too long to be formatted");
            } else {
                item.render(&local, str);
            }
        },

        'V' => try pp_describe.toStringB(b, @as(repr.Value, arg)),
        'v' => try pp_describe.descriptionB(b, @as(repr.Value, arg)),
        't' => try buffers.pushBytes(b, typestr(@as(repr.Value, arg))),
        'T' => try pushtypes(b, @as(repr.TagSet, arg)),

        'M', 'm', 'N', 'n', 'Q', 'q', 'P', 'p', 'j' => try renderPretty(
            b,
            conversion,
            &local,
            @as(repr.Value, arg),
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
/// of bytes is accepted and nothing else is, so a Janet value handed to `%s`
/// is a compile error here rather than a denormal in the message.
inline fn asCString(arg: anytype) [*:0]const u8 {
    const T = @TypeOf(arg);
    return switch (@typeInfo(T)) {
        .pointer => @ptrCast(arg),
        .optional => @ptrCast(arg.?),
        else => @compileError("format: %s and %S want a C string, not " ++ @typeName(T)),
    };
}

/// `janet_formatbv`'s replacement: append a formatted message to a buffer.
///
/// The format string is `comptime` and the arguments are a tuple, so the
/// specifier and the value it renders are checked against each other at the
/// call site.
pub fn formatTuple(
    b: *buffers.Buffer,
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
            .literal => |text| try buffers.pushBytes(b, text),
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
/// The `errdefer` is new: C stranded the buffer it had allocated on the way
/// out. Nothing observable changes; a raise from `%v`'s `tostring` callback
/// simply stops leaking the scratch.
pub fn formatc(comptime format: [:0]const u8, args: anytype) raise.Raising(strings.String) {
    var buffer: buffers.Buffer = undefined;
    _ = buffers.init(&buffer, @intCast(format.len));
    errdefer buffers.deinit(&buffer);
    try formatTuple(&buffer, format, args);
    const result = strings.new(buffer.slice());
    buffers.deinit(&buffer);
    return result;
}

/// `janet_formatb`: append to a buffer the caller owns, and hand it back.
pub fn formatb(
    buffer: *buffers.Buffer,
    comptime format: [:0]const u8,
    args: anytype,
) raise.Raising(*buffers.Buffer) {
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
/// The `defer` covers the two paths that leave the switch without reaching a
/// hand-written `janet_buffer_deinit`: an abstract that is not a file, and the
/// raise from `assertWriteable`. The order of the two is C's -- format first,
/// then check the file -- so the message a non-writeable file raises is
/// unchanged.
pub fn dynprintf(
    name: ?[*:0]const u8,
    /// `host.FILE` rather than `io.FILE`, which is an alias for it: this file
    /// already imports `io.zig` for the abstract type, but the *host* is what
    /// decides what a `FILE` is and naming it there is what makes the
    /// declaration true on every target.
    dflt_file: ?*host.FILE,
    comptime format: [:0]const u8,
    args: anytype,
) raise.Raising(void) {
    var x: repr.Value = wrap.fromNil();
    var xtype: repr.Tag = .nil;
    if (name) |dyn_name| {
        // An empty name is the same as no name: neither is a dynamic binding.
        if (dyn_name[0] != 0) {
            x = vm_state.dyn(dyn_name);
            xtype = repr.typeOf(x);
        }
    }

    switch (xtype) {
        repr.Tag.nil, repr.Tag.abstract => {
            var f: ?*host.FILE = dflt_file;
            var buffer: buffers.Buffer = undefined;
            _ = buffers.init(&buffer, @intCast(format.len));
            defer buffers.deinit(&buffer);
            try formatTuple(&buffer, format, args);
            if (xtype == repr.Tag.abstract) {
                const abstract = wrap.toAbstract(x);
                if (abi.abstractHead(abstract).type != &io_core.fileType) return;
                const iofile: *io_core.File = @ptrCast(@alignCast(abstract));
                try io_core.assertWriteable(iofile);
                f = iofile.file;
            }
            _ = io_core.write(f, buffer.data.?, @intCast(buffer.count));
        },
        repr.Tag.function => {
            const fun = wrap.toFunction(x);
            const buf = buffers.new(@intCast(format.len));
            try formatTuple(buf, format, args);
            var call_args = [_]repr.Value{wrap.fromBuffer(buf)};
            _ = try vm_entry.call(fun, &call_args);
        },
        repr.Tag.buffer => try formatTuple(wrap.toBuffer(x), format, args),
        // Anything else prints nowhere, silently.
        else => {},
    }
}

/// `formatc` at a site that cannot carry a raise.
///
/// One caller is left: `bytecode.zig`, whose assembler answers a message
/// pointer rather than an error union, so a raise from the formatter has no
/// channel to travel in. Every other site was an abi over a raising kernel and
/// has been retired -- the kernel is reached by `@import` and the error is
/// returned.
///
/// It records the raise and returns a blank string, which nothing consumes:
/// the process dies at the next protected scope. That is the shape this is
/// down to one instance of.
pub fn formatcReported(comptime format: [:0]const u8, args: anytype) strings.String {
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
    return raise.panicv(wrap.fromString(message));
}
// -------------------------------------------------- the Janet-array driver

/// `janet_buffer_format`, which is what `string/format` and `buffer/format`
/// run. It needs no C at all: the arguments arrive as a `Janet` array.
/// `first` is the index of the first value the format string consumes.
///
/// It used to be the index of the one *before* it, stepped at the top of each
/// conversion -- which meant a caller with no format string in `argv` at all
/// passed -1, and `test/pp_format.zig` did. That is the backwards-walk shape
/// twice already found in this tree, and an index cannot be unsigned while it
/// exists. Stepping at the bottom of the conversion instead says the same
/// thing about the same values: every path between the bounds check and the
/// step either uses `arg` or returns.
pub fn bufferFormat(
    b: *buffers.Buffer,
    strfrmt: [*]const u8,
    first: usize,
    argv: []repr.Value,
) raise.Raising(void) {
    const startlen = b.count;
    var arg = first;
    var at: usize = 0;
    while (strfrmt[at] != 0) {
        if (strfrmt[at] != '%') {
            try buffers.pushU8(b, strfrmt[at]);
            at += 1;
            continue;
        }
        at += 1;
        if (strfrmt[at] == '%') {
            try buffers.pushU8(b, strfrmt[at]);
            at += 1;
            continue;
        }

        if (arg >= argv.len) return raise.panic("not enough values for format");

        const spec = try scanFormat(strfrmt, at);
        const conversion = strfrmt[spec.at];
        at = spec.at + 1;

        var item = Item{};
        switch (conversion) {
            'c' => item.render(&spec, @as(c_int, @intCast(try args_core.getInteger(argv, arg)))),
            // Unlike the variadic driver, the two integer spellings are one
            // case: the argument is a Janet number either way.
            'd', 'i' => item.render(&spec, try args_core.getInteger64(argv, arg)),
            'x', 'X', 'o', 'u' => item.render(&spec, try args_core.getUInteger64(argv, arg)),
            'a', 'A', 'e', 'E', 'f', 'g', 'G' => item.render(&spec, try args_core.getNumber(argv, arg)),

            's' => {
                const s = try args_core.getCBytes(argv, arg);
                if (spec.isPlain()) {
                    try buffers.pushCString(b, s);
                } else {
                    item.render(&spec, s);
                }
            },

            'V' => try pp_describe.toStringB(b, argv[arg]),
            'v' => try pp_describe.descriptionB(b, argv[arg]),
            't' => try buffers.pushBytes(b, typestr(argv[arg])),

            'M', 'm', 'N', 'n', 'Q', 'q', 'P', 'p', 'j' => try renderPretty(
                b,
                conversion,
                &spec,
                argv[arg],
                startlen,
            ),

            else => return panicf("invalid conversion '%s' to 'format'", .{&spec.form}),
        }
        try item.flush(b);
        arg += 1;
    }
}

pub const bufferFormatPanicking = raise.panickingArgv(bufferFormat).abi;

// ----------------------------------------------------------------- exports
