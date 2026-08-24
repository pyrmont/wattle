//! The core environment: `src/core/corelib.c` and `src/core/run.c` entire.
//! Thirty-six cfunctions, the native-module loader, the bootstrap's inline
//! assembler, the environment that every other `janet_lib_*` is registered
//! into, and the three entry points that run Janet source in one. This is
//! Phase 10 Part 10.
//!
//! ## Two files, one selector
//!
//! Part 4's consolidation rule asks whether the pieces convert in different
//! increments, and these do not. They are also one subject rather than two
//! that happen to land together: `corelib.c` builds the core environment and
//! `run.c` is the only thing in the tree that runs code *in* one without
//! being handed a fiber first. `janet_dobytes` reads a `JanetTable *env` and
//! nothing else in `run.c` means anything without it. Part 5's rule -- a
//! selector's subject is a subsystem, not a file -- decides the rest.
//!
//! ## What a raise looks like here, and where it does not appear
//!
//! A cfunction that decides to raise returns `raise.Error` from an `Impl`
//! function and delivers it in a two-line C face, which is the shape Part 9
//! settled. A cfunction that makes no such decision has no error channel and
//! is written as the plain `JanetCFunction` it is: `(describe x)` cannot fail
//! on its own account, and giving it an error union it never returns would be
//! ceremony rather than shape.
//!
//! Neither kind is jump-free, which is why the marker above is still here.
//! `janet_arity`, `janet_getstring` and their thirty relatives are
//! `-Dargs-core`'s C faces, `janet_panic_type` is another, and a call to one
//! from this object crosses the C ABI and therefore raises by jumping. That is
//! Part 4's seam rule -- an error union cannot cross a subsystem seam -- and
//! not something this increment could have avoided. Every frame between such a
//! call and the fiber's try scope holds nothing: the scratch allocations these
//! functions make are `janet_smalloc`'s, which the collector releases on the
//! unwind.
//!
//! ## The bootstrap half is compiled only into the image generator
//!
//! `janet_core_env` has two implementations in the C original, chosen by
//! `JANET_BOOTSTRAP`: the generator assembles the environment from scratch,
//! and the runtime unmarshals it from the image. Both are here, behind
//! `corefn.bootstrap`, and Zig does not analyse the branch it does not take --
//! so the inline assembler below is checked by `-Dboot=zig` and by nothing
//! else. That is the same exposure Part 8 recorded for `JANET_MARSHAL_DEBUG`,
//! except that here there *is* a configuration that compiles it, and the
//! acceptance matrix runs it.
//!
//! ## Feature gates are read off the translated macros
//!
//! `janet_load_libs` calls seven `janet_lib_*` functions that exist only in
//! some configurations, and this file asks `@hasDecl(c, "JANET_PEG")` and its
//! kin rather than having `build.zig` restate each condition. `state_abi.h`
//! restates four macros on the stated grounds that "translate-c does not
//! surface a macro defined with no value"; under Zig 0.16 it does, as a
//! zero-length string constant, which `@hasDecl` finds. The restatements are
//! left alone -- they are wanted as *values* at their own call sites -- but a
//! new gate does not need one.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");
const corefn = @import("corefn");
const options = @import("options");
const raise = @import("raise");
const pp_format = @import("pp_format.zig");
const c = abi.c;
const stdio = @import("stdio.zig");
const trace_frames = @import("trace_frames.zig");
const printer = @import("printer.zig");
const lifecycle = @import("lifecycle.zig");
const containers = @import("containers.zig");
const arglayer = @import("arglayer.zig");

/// The fiber's pushes, raise-capable since Part 17a. `(native ...)` roots the
/// module's environment on the fiber stack before running third-party code.
const fiber_core = @import("fiber_core.zig");
const clib = @import("dynlib.zig");
const asm_core = @import("asm_core.zig");
const ev_loop = @import("ev_loop.zig");
const evloop = @import("evloop.zig");
const inttypes = @import("inttypes.zig");
const io_core = @import("io_core.zig");
const marsh = @import("marsh.zig");
const math = @import("math.zig");
const os_surface = @import("os_surface.zig");
const parser_core = @import("parser_core.zig");
const peg = @import("peg.zig");

const windows = builtin.os.tag == .windows;

/// `src/core/util.h`, which `abi.zig` deliberately does not translate.
extern fn safe_memcpy(dest: ?*anyopaque, src: ?*const anyopaque, len: usize) callconv(.c) void;
extern fn janet_def_addflags(def: *c.JanetFuncDef) callconv(.c) void;
extern fn get_processed_name(name: [*:0]const u8) callconv(.c) [*c]u8;

extern fn janet_lib_io(env: *c.JanetTable) callconv(.c) void;
extern fn janet_lib_math(env: *c.JanetTable) callconv(.c) void;
extern fn janet_lib_array(env: *c.JanetTable) callconv(.c) void;
extern fn janet_lib_tuple(env: *c.JanetTable) callconv(.c) void;
extern fn janet_lib_buffer(env: *c.JanetTable) callconv(.c) void;
extern fn janet_lib_table(env: *c.JanetTable) callconv(.c) void;
extern fn janet_lib_struct(env: *c.JanetTable) callconv(.c) void;
extern fn janet_lib_fiber(env: *c.JanetTable) callconv(.c) void;
extern fn janet_lib_os(env: *c.JanetTable) callconv(.c) void;
extern fn janet_lib_string(env: *c.JanetTable) callconv(.c) void;
extern fn janet_lib_marsh(env: *c.JanetTable) callconv(.c) void;
extern fn janet_lib_parse(env: *c.JanetTable) callconv(.c) void;
extern fn janet_lib_compile(env: *c.JanetTable) callconv(.c) void;
extern fn janet_lib_debug(env: *c.JanetTable) callconv(.c) void;
extern fn janet_lib_asm(env: *c.JanetTable) callconv(.c) void;
extern fn janet_lib_peg(env: *c.JanetTable) callconv(.c) void;
extern fn janet_lib_inttypes(env: *c.JanetTable) callconv(.c) void;
extern fn janet_lib_net(env: *c.JanetTable) callconv(.c) void;
extern fn janet_lib_ev(env: *c.JanetTable) callconv(.c) void;
extern fn janet_lib_filewatch(env: *c.JanetTable) callconv(.c) void;
extern fn janet_lib_ffi(env: *c.JanetTable) callconv(.c) void;

/// `stdin` and `stdout`, which cannot be named from Zig portably. `io.c` keeps
/// these two beside `stdio.err` for the reason its comment there gives:
/// translate-c renders the three handles a different way on each of this
/// project's platforms, and on mingw the rendering is a compile error at the
/// reference rather than at the use. They are scaffold in the sense "Target"
/// gives the word -- no C caller has one -- and they go with `janet_dynprintf`
/// in Part 17.
/// `janet_eprintf`, which `janet.h` spells as a variadic macro over
/// `janet_dynprintf` and translate-c therefore cannot render at all. Part 7
/// established the shape: Zig cannot define a C variadic on every target here,
/// but calling one is ordinary, so the macro is written out. `trace_frames.zig`
/// carries the same three lines for the same reason.
inline fn eprintf(comptime format: [:0]const u8, args: anytype) void {
    // `pp_format.dynprintf` can raise: `(dyn :err)` may be a Janet function, and
    // calling it can. This position cannot carry one -- it is a trace or a
    // diagnostic on the way out -- so the raise is reported exactly as the C
    // face reported it before Part 18 deleted the variadic.
    raise.reported(pp_format.dynprintf("err", @ptrCast(@alignCast(stdio.err())), format, args));
}

const has_ev = @hasDecl(c, "JANET_EV");
const has_net = @hasDecl(c, "JANET_NET");
const has_ffi = @hasDecl(c, "JANET_FFI");
const has_peg = @hasDecl(c, "JANET_PEG");
const has_assembler = @hasDecl(c, "JANET_ASSEMBLER");
const has_int_types = @hasDecl(c, "JANET_INT_TYPES");
const has_filewatch = @hasDecl(c, "JANET_FILEWATCH");
const has_dynamic_modules = @hasDecl(c, "JANET_DYNAMIC_MODULES");
const bits64 = @hasDecl(c, "JANET_64");

/// `JANET_OUT_OF_MEMORY`, which is fatal rather than raising.
inline fn allocated(pointer: ?*anyopaque) *anyopaque {
    if (pointer) |p| return p;
    c.janet_zig_out_of_memory();
}

inline fn wrapInteger(x: i32) c.Janet {
    return c.janet_wrap_number(@floatFromInt(x));
}

// ==========================================================================
// Loading a native module.
// ==========================================================================

fn janet_nativeImpl(name: [*c]const u8, err: [*c]c.JanetString) raise.Raising(c.JanetModule) {
    try lifecycle.sandboxAssert(c.JANET_SANDBOX_DYNAMIC_MODULES);
    const processed_name = get_processed_name(name);
    const lib = clib.load(@ptrCast(processed_name));
    if (name != processed_name) c.janet_free(processed_name);
    if (clib.failed(lib)) {
        err.* = c.janet_cstring(clib.lastError());
        return null;
    }
    const init: c.JanetModule = @ptrCast(@alignCast(try clib.symbol(lib, "_janet_init")));
    if (init == null) {
        err.* = c.janet_cstring("could not find the _janet_init symbol");
        return null;
    }
    const getter: c.JanetModconf = @ptrCast(@alignCast(try clib.symbol(lib, "_janet_mod_config")));
    if (getter == null) {
        err.* = c.janet_cstring("could not find the _janet_mod_config symbol");
        return null;
    }
    const modconf = getter.?();
    const host: c.JanetBuildConfig = .{
        .major = c.JANET_VERSION_MAJOR,
        .minor = c.JANET_VERSION_MINOR,
        .patch = c.JANET_VERSION_PATCH,
        .bits = c.JANET_CURRENT_CONFIG_BITS,
    };
    if (host.major != modconf.major or
        host.minor != modconf.minor or
        host.bits != modconf.bits)
    {
        var errbuf: [128]u8 = undefined;
        // The `%.d` in the host's minor position is the C original's and is
        // reproduced: it is precision zero, so a zero minor version prints as
        // nothing at all. `FOUND.md` has it.
        _ = c.snprintf(
            &errbuf,
            errbuf.len,
            "config mismatch - host %d.%.d.%d(%.4x) vs. module %d.%d.%d(%.4x) - native needs to be recompiled!",
            host.major,
            host.minor,
            host.patch,
            host.bits,
            modconf.major,
            modconf.minor,
            modconf.patch,
            modconf.bits,
        );
        err.* = c.janet_cstring(&errbuf);
        return null;
    }
    return init;
}

export fn janet_native(name: [*c]const u8, err: [*c]c.JanetString) callconv(.c) c.JanetModule {
    return raise.reported(janet_nativeImpl(name, err));
}

// ==========================================================================
// module/expand-path.
// ==========================================================================

fn dynCString(name: [*:0]const u8, dflt: [*:0]const u8) raise.Raising([*:0]const u8) {
    const x = c.janet_dyn(name);
    if (c.janet_checktype(x, c.JANET_NIL) != 0) return dflt;
    if (c.janet_checktype(x, c.JANET_STRING) == 0) {
        return pp_format.panicf("expected string, got %v", .{x});
    }
    const jstr = c.janet_unwrap_string(x);
    const cstr: [*:0]const u8 = @ptrCast(jstr);
    if (std.mem.len(cstr) != @as(usize, @intCast(c.janet_string_length(jstr)))) {
        return pp_format.panicf("string %v contains embedded 0s", .{x});
    }
    return cstr;
}

inline fn isPathSep(ch: u8) bool {
    if (windows and ch == '\\') return true;
    return ch == '/';
}

/// `strncmp` against a literal, which is what the C original's chain of
/// `strncmp(template + i, ":all:", 5)` calls does. It reads through the
/// template's NUL rather than past it, so a template ending in a colon is
/// compared safely and answers no match.
inline fn matches(p: [*c]const u8, comptime literal: [:0]const u8) bool {
    return c.strncmp(p, literal.ptr, literal.len) == 0;
}

fn cfunExpandPath(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 2);
    const input: [*:0]const u8 = @ptrCast(try arglayer.getCString(argv, 0));
    const template: [*:0]const u8 = @ptrCast(try arglayer.getCString(argv, 1));
    const curfile = try dynCString("current-file", "");
    const syspath = try dynCString("syspath", "");
    const out = c.janet_buffer(0);
    const tlen = std.mem.len(template);
    const input_len = std.mem.len(input);

    // The name component: everything after the last separator.
    var name: usize = input_len;
    while (name > 0) {
        if (isPathSep(input[name - 1])) break;
        name -= 1;
    }

    // The directory component of `(dyn :current-file)`. This walk starts at
    // the terminator and tests the character it is *on* rather than the one
    // before it, so a path with a single leading separator reports the current
    // directory. That is the C original's and is reproduced.
    const curfile_len = std.mem.len(curfile);
    var curname: usize = curfile_len;
    while (curname > 0) {
        if (isPathSep(curfile[curname])) break;
        curname -= 1;
    }
    const curdir: [*:0]const u8 = if (curname == 0) "." else curfile;
    const curlen: i32 = if (curname == 0) 1 else @intCast(curname);

    var i: usize = 0;
    while (i < tlen) : (i += 1) {
        if (template[i] != ':') {
            try containers.bufferPushU8(out, template[i]);
            continue;
        }
        const rest: [*c]const u8 = template + i;
        if (matches(rest, ":all:")) {
            try containers.bufferPushCString(out, input);
            i += 4;
        } else if (matches(rest, ":@all:")) {
            if (input[0] == '@') {
                var p: usize = 0;
                while (input[p] != 0 and !isPathSep(input[p])) p += 1;
                const len = p - 1;
                const str: [*]u8 = @ptrCast(allocated(c.janet_smalloc(len + 1)));
                @memcpy(str[0..len], input[1 .. 1 + len]);
                str[len] = 0;
                _ = try pp_format.formatb(out, "%V", .{c.janet_dyn(@ptrCast(str))});
                c.janet_sfree(str);
                try containers.bufferPushCString(out, input + p);
            } else {
                try containers.bufferPushCString(out, input);
            }
            i += 5;
        } else if (matches(rest, ":cur:")) {
            try containers.bufferPushBytes(out, @ptrCast(curdir), curlen);
            i += 4;
        } else if (matches(rest, ":dir:")) {
            try containers.bufferPushBytes(out, @ptrCast(input), @intCast(name));
            i += 4;
        } else if (matches(rest, ":sys:")) {
            try containers.bufferPushCString(out, syspath);
            i += 4;
        } else if (matches(rest, ":name:")) {
            try containers.bufferPushCString(out, input + name);
            i += 5;
        } else if (matches(rest, ":native:")) {
            try containers.bufferPushCString(out, if (windows) ".dll" else ".so");
            i += 7;
        } else {
            try containers.bufferPushU8(out, ':');
        }
    }

    normalizePath(out);
    return c.janet_wrap_buffer(out);
}

/// Collapse `.` and `..` segments in place. The C original walks two pointers
/// into `out->data`; this walks two indices, which is the same traversal and
/// does not have to reason about what `janet_buffer(0)` left in `data`.
///
/// `dot_count` carries three states rather than a count: non-negative is a run
/// of leading dots in the current segment, and -1 means the segment has a
/// non-dot character in it and the dots are no longer leading.
fn normalizePath(out: *c.JanetBuffer) void {
    const data = out.data;
    const end: usize = @intCast(out.count);
    var scan: usize = 0;
    var print: usize = 0;
    var normal_section_count: i32 = 0;
    var dot_count: i32 = 0;
    while (scan < end) : (scan += 1) {
        const ch = data[scan];
        if (ch == '.') {
            if (dot_count >= 0) {
                dot_count += 1;
            } else {
                data[print] = '.';
                print += 1;
            }
        } else if (isPathSep(ch)) {
            if (dot_count == 1) {
                // A bare "." segment: drop it and the separator with it.
            } else if (dot_count == 2) {
                if (normal_section_count > 0) {
                    print -= 1; // unprint the last separator
                    while (print > 0 and !isPathSep(data[print - 1])) print -= 1;
                    normal_section_count -= 1;
                } else {
                    data[print] = '.';
                    data[print + 1] = '.';
                    data[print + 2] = '/';
                    print += 3;
                }
            } else if (scan == 0 or dot_count != 0) {
                while (dot_count > 0) : (dot_count -= 1) {
                    data[print] = '.';
                    print += 1;
                }
                if (scan > 0) normal_section_count += 1;
                data[print] = '/';
                print += 1;
            }
            dot_count = 0;
        } else {
            while (dot_count > 0) : (dot_count -= 1) {
                data[print] = '.';
                print += 1;
            }
            dot_count = -1;
            data[print] = ch;
            print += 1;
        }
    }
    out.count = @intCast(print);
}

// ==========================================================================
// The cfunction surface.
// ==========================================================================

fn cfunDyn(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 2);
    const env = c.janet_vm.fiber.*.env;
    const value = if (env != null) c.janet_table_get(env, argv[0]) else c.janet_wrap_nil();
    if (argc == 2 and c.janet_checktype(value, c.JANET_NIL) != 0) return argv[1];
    return value;
}

fn cfunSetdyn(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 2);
    if (c.janet_vm.fiber.*.env == null) {
        c.janet_vm.fiber.*.env = c.janet_table(2);
    }
    c.janet_table_put(c.janet_vm.fiber.*.env, argv[0], argv[1]);
    return argv[1];
}

fn cfunNative(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 2);
    const argv0 = argv[0];
    const path = try arglayer.getString(argv, 0);
    var err: c.JanetString = null;
    const env = if (argc == 2) try arglayer.getTable(argv, 1) else c.janet_table(0);
    const init = try janet_nativeImpl(@ptrCast(path), &err);
    if (init == null) {
        return pp_format.panicf("could not load native %S: %S", .{ path, err });
    }
    // Rooted against a collection triggered from inside the module's entry
    // point, which runs arbitrary third-party code.
    try fiber_core.push(c.janet_vm.fiber, c.janet_wrap_table(env));
    try raise.crossing(init.?(env));
    c.janet_table_put(env, c.janet_ckeywordv("native"), argv0);
    return c.janet_wrap_table(env);
}

fn cfunDescribe(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    const b = c.janet_buffer(0);
    var i: i32 = 0;
    while (i < argc) : (i += 1) try printer.descriptionB(b, argv[@intCast(i)]);
    return c.janet_stringv(b.*.data, b.*.count);
}

/// `string`, `symbol`, `keyword` and `buffer` differ only in what they wrap
/// the concatenation in.
fn Concat(comptime finish: anytype) type {
    return struct {
        fn cfun(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
            const b = c.janet_buffer(0);
            var i: i32 = 0;
            while (i < argc) : (i += 1) try printer.toStringB(b, argv[@intCast(i)]);
            return finish(b);
        }
    };
}

fn finishString(b: *c.JanetBuffer) c.Janet {
    return c.janet_stringv(b.data, b.count);
}

fn finishSymbol(b: *c.JanetBuffer) c.Janet {
    return c.janet_symbolv(b.data, b.count);
}

fn finishKeyword(b: *c.JanetBuffer) c.Janet {
    return c.janet_keywordv(b.data, b.count);
}

fn finishBuffer(b: *c.JanetBuffer) c.Janet {
    return c.janet_wrap_buffer(b);
}

fn cfunIsAbstract(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    return c.janet_wrap_boolean(c.janet_checktype(argv[0], c.JANET_ABSTRACT));
}

fn cfunScanNumber(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    var number: f64 = undefined;
    try arglayer.arity(argc, 1, 2);
    const view = try arglayer.getBytes(argv, 0);
    const base = try arglayer.optInteger(argv, argc, 1, 0);
    if (!(base == 0 or (base >= 2 and base <= 36))) {
        return pp_format.panicf("expected base between 2 and 36, got %d", .{base});
    }
    if (c.janet_scan_number_base(view.bytes, view.len, base, &number) != 0) {
        return c.janet_wrap_nil();
    }
    return c.janet_wrap_number(number);
}

fn cfunTuple(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    return c.janet_wrap_tuple(c.janet_tuple_n(argv, argc));
}

fn cfunArray(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    const array = c.janet_array(argc);
    array.*.count = argc;
    safe_memcpy(@ptrCast(array.*.data), @ptrCast(argv), @as(usize, @intCast(argc)) * @sizeOf(c.Janet));
    return c.janet_wrap_array(array);
}

fn cfunSlice(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    var bytes: [*c]const u8 = undefined;
    var blen: i32 = undefined;
    var items: [*c]const c.Janet = undefined;
    var ilen: i32 = undefined;
    if (c.janet_bytes_view(argv[0], &bytes, &blen) != 0) {
        const range = try arglayer.getSlice(argc, argv);
        return c.janet_stringv(bytes + @as(usize, @intCast(range.start)), range.end - range.start);
    } else if (c.janet_indexed_view(argv[0], &items, &ilen) != 0) {
        const range = try arglayer.getSlice(argc, argv);
        return c.janet_wrap_tuple(c.janet_tuple_n(items + @as(usize, @intCast(range.start)), range.end - range.start));
    }
    // `-Dargs-core`'s C face, so this raise arrives as a jump through a frame
    // that holds nothing. The message it builds is the fault layer's and has
    // no spelling on this side of the seam.
    return arglayer.panicType(argv[0], 0, c.JANET_TFLAG_BYTES | c.JANET_TFLAG_INDEXED);
}

fn cfunRange(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 3);
    var start: f64 = 0;
    var stop: f64 = 0;
    var step: f64 = 1;
    var count: f64 = 0;
    if (argc == 3) {
        start = try arglayer.getNumber(argv, 0);
        stop = try arglayer.getNumber(argv, 1);
        step = try arglayer.getNumber(argv, 2);
        count = if (step != 0.0) (stop - start) / step else 0.0;
    } else if (argc == 2) {
        start = try arglayer.getNumber(argv, 0);
        stop = try arglayer.getNumber(argv, 1);
        count = stop - start;
    } else {
        stop = try arglayer.getNumber(argv, 0);
        count = stop;
    }
    if (std.math.isInf(step)) return raise.panic("infinite step not allowed");
    count = if (count > 0.0) count else 0.0;
    janetAssert(count >= 0.0, "bad range code");
    if (count > @as(f64, @floatFromInt(std.math.maxInt(i32)))) {
        return pp_format.panicf("range is too large, %f elements", .{count});
    }
    const int_count: i32 = @intFromFloat(@ceil(count));
    if (step > 0.0) {
        janetAssert(start + @as(f64, @floatFromInt(int_count)) * step >= stop, "bad range code");
    } else {
        janetAssert(start + @as(f64, @floatFromInt(int_count)) * step <= stop, "bad range code");
    }
    const array = c.janet_array(int_count);
    var i: i32 = 0;
    while (i < int_count) : (i += 1) {
        array.*.data[@intCast(i)] = c.janet_wrap_number(start + @as(f64, @floatFromInt(i)) * step);
    }
    array.*.count = int_count;
    return c.janet_wrap_array(array);
}

/// `janet_assert`, which prints and aborts rather than raising. Both call
/// sites in `range` are checking the arithmetic above them rather than
/// anything the caller supplied.
inline fn janetAssert(condition: bool, message: [*c]const u8) void {
    if (!condition) c.janet_zig_fatal(message);
}

fn cfunTable(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    if (argc & 1 != 0) return raise.panic("expected even number of arguments");
    const table = c.janet_table(argc >> 1);
    var i: i32 = 0;
    while (i < argc) : (i += 2) {
        c.janet_table_put(table, argv[@intCast(i)], argv[@intCast(i + 1)]);
    }
    return c.janet_wrap_table(table);
}

fn cfunGetproto(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    if (c.janet_checktype(argv[0], c.JANET_TABLE) != 0) {
        const t = c.janet_unwrap_table(argv[0]);
        return if (t.*.proto != null) c.janet_wrap_table(t.*.proto) else c.janet_wrap_nil();
    }
    if (c.janet_checktype(argv[0], c.JANET_STRUCT) != 0) {
        const st = c.janet_unwrap_struct(argv[0]);
        const proto = c.janet_struct_proto(st);
        return if (proto != null) c.janet_wrap_struct(proto) else c.janet_wrap_nil();
    }
    return pp_format.panicf("expected struct or table, got %v", .{argv[0]});
}

fn cfunStruct(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    if (argc & 1 != 0) return raise.panic("expected even number of arguments");
    const st = c.janet_struct_begin(argc >> 1);
    var i: i32 = 0;
    while (i < argc) : (i += 2) {
        c.janet_struct_put(st, argv[@intCast(i)], argv[@intCast(i + 1)]);
    }
    return c.janet_wrap_struct(c.janet_struct_end(st));
}

fn cfunGensym(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    _ = argv;
    try arglayer.fixarity(argc, 0);
    return c.janet_wrap_symbol(c.janet_symbol_gen());
}

fn cfunGccollect(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    _ = argv;
    _ = argc;
    c.janet_collect();
    return c.janet_wrap_nil();
}

fn cfunGcsetinterval(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const s = try arglayer.getSize(argv, 0);
    // Limited to 48 bits, and only where a size is wider than that.
    if (bits64 and (s >> 48) != 0) return raise.panic("interval too large");
    c.janet_vm.gc_interval = s;
    return c.janet_wrap_nil();
}

fn cfunGcinterval(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    _ = argv;
    try arglayer.fixarity(argc, 0);
    return c.janet_wrap_number(@floatFromInt(c.janet_vm.gc_interval));
}

fn cfunType(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const t = c.janet_type(argv[0]);
    if (t == c.JANET_ABSTRACT) {
        return c.janet_ckeywordv(c.janet_abstract_type(c.janet_unwrap_abstract(argv[0])).*.name);
    }
    return c.janet_ckeywordv(c.janet_type_names[@intCast(t)]);
}

fn cfunHash(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    return c.janet_wrap_number(@floatFromInt(c.janet_hash(argv[0])));
}

fn cfunGetline(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    const in = c.janet_dynfile("in", @ptrCast(@alignCast(stdio.in())));
    const out = c.janet_dynfile("out", @ptrCast(@alignCast(stdio.out())));
    try arglayer.arity(argc, 0, 3);
    const buf = if (argc >= 2) try arglayer.getBuffer(argv, 1) else c.janet_buffer(10);
    if (argc >= 1) {
        const prompt = try arglayer.getString(argv, 0);
        _ = c.fprintf(out, "%s", prompt);
        _ = c.fflush(out);
    }
    buf.*.count = 0;
    while (true) {
        const ch = c.fgetc(in);
        if (c.feof(in) != 0 or ch < 0) break;
        try containers.bufferPushU8(buf, @intCast(ch));
        if (ch == '\n') break;
    }
    return c.janet_wrap_buffer(buf);
}

fn cfunTrace(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const func = try arglayer.getFunction(argv, 0);
    func.*.gc.flags |= c.JANET_FUNCFLAG_TRACE;
    return argv[0];
}

fn cfunUntrace(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    const func = try arglayer.getFunction(argv, 0);
    func.*.gc.flags &= ~@as(i32, c.JANET_FUNCFLAG_TRACE);
    return argv[0];
}

fn cfunCheckInt(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    return c.janet_wrap_boolean(c.janet_checkint(argv[0]));
}

fn cfunCheckNat(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.fixarity(argc, 1);
    if (c.janet_checkint(argv[0]) == 0) return c.janet_wrap_false();
    return c.janet_wrap_boolean(@intFromBool(c.janet_unwrap_integer(argv[0]) >= 0));
}

/// The four `janet_checktypes` predicates, which differ only in the mask.
fn TypeFlagPredicate(comptime flags: c_int) type {
    return struct {
        fn cfun(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
            try arglayer.fixarity(argc, 1);
            return c.janet_wrap_boolean(c.janet_checktypes(argv[0], flags));
        }
    };
}

fn cfunSignal(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 1, 2);
    const payload = if (argc == 2) argv[1] else c.janet_wrap_nil();
    if (c.janet_checkint(argv[0]) != 0) {
        const s = c.janet_unwrap_integer(argv[0]);
        if (s < 0 or s > 9) {
            return pp_format.panicf("expected user signal between 0 and 9, got %d", .{s});
        }
        return raise.signal(@intCast(c.JANET_SIGNAL_USER0 + s), payload);
    }
    const kw = try arglayer.getKeyword(argv, 0);
    for (c.janet_signal_names, 0..) |signal_name, i| {
        if (c.janet_cstrcmp(kw, signal_name) == 0) {
            return raise.signal(@intCast(i), payload);
        }
    }
    return pp_format.panicf("unknown signal %v", .{argv[0]});
}

fn cfunMemcmp(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    try arglayer.arity(argc, 2, 5);
    const a = try arglayer.getBytes(argv, 0);
    const b = try arglayer.getBytes(argv, 1);
    const len = try arglayer.optNat(argv, argc, 2, if (a.len < b.len) a.len else b.len);
    const offset_a = try arglayer.optNat(argv, argc, 3, 0);
    const offset_b = try arglayer.optNat(argv, argc, 4, 0);
    // The C original adds these as `int32_t`, which overflows for a large
    // offset and a large length and lets the comparison read off the end of
    // both views. Signed overflow is undefined, so there is nothing to
    // reproduce: the sum is taken wide and the check answers correctly.
    // `FOUND.md` records the C behaviour.
    if (@as(i64, offset_a) + @as(i64, len) > a.len) {
        return pp_format.panicf("invalid offset-a: %d", .{offset_a});
    }
    if (@as(i64, offset_b) + @as(i64, len) > b.len) {
        return pp_format.panicf("invalid offset-b: %d", .{offset_b});
    }
    const result = c.memcmp(
        a.bytes + @as(usize, @intCast(offset_a)),
        b.bytes + @as(usize, @intCast(offset_b)),
        @intCast(len),
    );
    return wrapInteger(result);
}

const SandboxOption = struct { name: [:0]const u8, flag: u32 };

/// The C original terminates this table with a null name and scans to it; the
/// length is the terminator here, which is the one difference. The order is
/// the original's and is what `(sandbox ...)` reports on an unknown keyword
/// only by not finding it, so nothing depends on it.
const sandbox_options = [_]SandboxOption{
    .{ .name = "all", .flag = c.JANET_SANDBOX_ALL },
    .{ .name = "asm", .flag = c.JANET_SANDBOX_ASM },
    .{ .name = "chroot", .flag = c.JANET_SANDBOX_CHROOT },
    .{ .name = "compile", .flag = c.JANET_SANDBOX_COMPILE },
    .{ .name = "env", .flag = c.JANET_SANDBOX_ENV },
    .{ .name = "exit", .flag = c.JANET_SANDBOX_EXIT },
    .{ .name = "ffi", .flag = c.JANET_SANDBOX_FFI },
    .{ .name = "ffi-define", .flag = c.JANET_SANDBOX_FFI_DEFINE },
    .{ .name = "ffi-jit", .flag = c.JANET_SANDBOX_FFI_JIT },
    .{ .name = "ffi-use", .flag = c.JANET_SANDBOX_FFI_USE },
    .{ .name = "fs", .flag = c.JANET_SANDBOX_FS },
    .{ .name = "fs-read", .flag = c.JANET_SANDBOX_FS_READ },
    .{ .name = "fs-temp", .flag = c.JANET_SANDBOX_FS_TEMP },
    .{ .name = "fs-write", .flag = c.JANET_SANDBOX_FS_WRITE },
    .{ .name = "hrtime", .flag = c.JANET_SANDBOX_HRTIME },
    .{ .name = "modules", .flag = c.JANET_SANDBOX_DYNAMIC_MODULES },
    .{ .name = "net", .flag = c.JANET_SANDBOX_NET },
    .{ .name = "net-connect", .flag = c.JANET_SANDBOX_NET_CONNECT },
    .{ .name = "net-listen", .flag = c.JANET_SANDBOX_NET_LISTEN },
    .{ .name = "sandbox", .flag = c.JANET_SANDBOX_SANDBOX },
    .{ .name = "signal", .flag = c.JANET_SANDBOX_SIGNAL },
    .{ .name = "subprocess", .flag = c.JANET_SANDBOX_SUBPROCESS },
    .{ .name = "threads", .flag = c.JANET_SANDBOX_THREADS },
    .{ .name = "unmarshal", .flag = c.JANET_SANDBOX_UNMARSHAL },
};

fn cfunSandbox(argc: i32, argv: [*c]c.Janet) align(corefn.alignment) raise.Raising(c.Janet) {
    var flags: u32 = 0;
    var i: i32 = 0;
    while (i < argc) : (i += 1) {
        const kw = try arglayer.getKeyword(argv, i);
        var found = false;
        for (sandbox_options) |option| {
            if (c.janet_cstrcmp(kw, option.name.ptr) == 0) {
                flags |= option.flag;
                found = true;
                break;
            }
        }
        if (!found) return pp_format.panicf("unknown capability %v", .{argv[@intCast(i)]});
    }
    try lifecycle.sandbox(flags);
    return c.janet_wrap_nil();
}

// ==========================================================================
// The bootstrap's inline assembler.
//
// Compiled into the image generator and nowhere else. Zig does not analyse a
// comptime-false branch, so everything under `corefn.bootstrap` below is
// checked by `-Dboot=zig` and by no other configuration.
// ==========================================================================

inline fn opword(op: anytype) u32 {
    return @intCast(op);
}

inline fn opSSS(op: anytype, a: u32, b: u32, d: u32) u32 {
    return opword(op) | (a << 8) | (b << 16) | (d << 24);
}

inline fn opSS(op: anytype, a: u32, b: u32) u32 {
    return opword(op) | (a << 8) | (b << 16);
}

inline fn opSSI(op: anytype, a: u32, b: u32, i: i32) u32 {
    return opword(op) | (a << 8) | (b << 16) | (@as(u32, @bitCast(i)) << 24);
}

inline fn opS(op: anytype, a: u32) u32 {
    return opword(op) | (a << 8);
}

inline fn opSI(op: anytype, a: u32, i: i32) u32 {
    return opword(op) | (a << 8) | (@as(u32, @bitCast(i)) << 16);
}

fn quickAsm(
    flags: i32,
    name: [*:0]const u8,
    arity: i32,
    min_arity: i32,
    max_arity: i32,
    slots: i32,
    bytecode: []const u32,
) *c.JanetFuncDef {
    const def = c.janet_funcdef_alloc();
    def.*.arity = arity;
    def.*.min_arity = min_arity;
    def.*.max_arity = max_arity;
    def.*.flags = flags;
    def.*.slotcount = slots;
    const size = bytecode.len * @sizeOf(u32);
    def.*.bytecode = @ptrCast(@alignCast(allocated(c.janet_malloc(size))));
    def.*.bytecode_length = @intCast(bytecode.len);
    def.*.name = c.janet_cstring(name);
    @memcpy(def.*.bytecode[0..bytecode.len], bytecode);
    janet_def_addflags(def);
    return def;
}

fn quickAsmDef(
    env: *c.JanetTable,
    flags: i32,
    name: [*:0]const u8,
    arity: i32,
    min_arity: i32,
    max_arity: i32,
    slots: i32,
    bytecode: []const u32,
    doc: [*:0]const u8,
) void {
    const def = quickAsm(flags, name, arity, min_arity, max_arity, slots, bytecode);
    c.janet_def(env, name, c.janet_wrap_function(c.janet_thunk(def)), doc);
}

/// The variadic operators. Registers: 0 args, 1 argn, 2 jump flag,
/// 3 accumulator, 4 operand, 5 loop iterator.
fn templatizeVarop(
    env: *c.JanetTable,
    flags: i32,
    name: [*:0]const u8,
    nullary: i32,
    unary: i32,
    op: anytype,
    doc: [*:0]const u8,
) void {
    const varop_asm = [_]u32{
        opSS(c.JOP_LENGTH, 1, 0), // argn = count(args)

        // Check nullary
        opSSS(c.JOP_EQUALS_IMMEDIATE, 2, 1, 0),
        opSI(c.JOP_JUMP_IF_NOT, 2, 3),
        opSI(c.JOP_LOAD_INTEGER, 3, nullary),
        opS(c.JOP_RETURN, 3),

        // Check unary
        opSSI(c.JOP_EQUALS_IMMEDIATE, 2, 1, 1),
        opSI(c.JOP_JUMP_IF_NOT, 2, 5),
        opSI(c.JOP_LOAD_INTEGER, 3, unary),
        opSSI(c.JOP_GET_INDEX, 4, 0, 0),
        opSSS(op, 3, 3, 4),
        opS(c.JOP_RETURN, 3),

        // Two or more arguments: prime the loop
        opSSI(c.JOP_GET_INDEX, 3, 0, 0),
        opSI(c.JOP_LOAD_INTEGER, 5, 1),
        // Main loop
        opSSS(c.JOP_IN, 4, 0, 5),
        opSSS(op, 3, 3, 4),
        opSSI(c.JOP_ADD_IMMEDIATE, 5, 5, 1),
        opSSI(c.JOP_EQUALS, 2, 5, 1),
        opSI(c.JOP_JUMP_IF_NOT, 2, -4),

        opS(c.JOP_RETURN, 3),
    };
    quickAsmDef(
        env,
        flags | c.JANET_FUNCDEF_FLAG_VARARG,
        name,
        0,
        0,
        std.math.maxInt(i32),
        6,
        &varop_asm,
        doc,
    );
}

/// The variadic comparators. Registers: 0 args, 1 argn, 2 jump flag, 3 last
/// value, 4 next operand, 5 loop iterator.
fn templatizeComparator(
    env: *c.JanetTable,
    flags: i32,
    name: [*:0]const u8,
    invert: bool,
    op: anytype,
    doc: [*:0]const u8,
) void {
    const comparator_asm = [_]u32{
        opSS(c.JOP_LENGTH, 1, 0),
        opSSS(c.JOP_LESS_THAN_IMMEDIATE, 2, 1, 2),
        opSI(c.JOP_JUMP_IF, 2, 10),

        // Prime the loop
        opSSI(c.JOP_GET_INDEX, 3, 0, 0),
        opSI(c.JOP_LOAD_INTEGER, 5, 1),

        // Main loop
        opSSS(c.JOP_IN, 4, 0, 5),
        opSSS(op, 2, 3, 4),
        opSI(c.JOP_JUMP_IF_NOT, 2, 7),
        opSSI(c.JOP_ADD_IMMEDIATE, 5, 5, 1),
        opSS(c.JOP_MOVE_NEAR, 3, 4),
        opSSI(c.JOP_EQUALS, 2, 5, 1),
        opSI(c.JOP_JUMP_IF_NOT, 2, -6),

        // Done
        opS(if (invert) c.JOP_LOAD_FALSE else c.JOP_LOAD_TRUE, 3),
        opS(c.JOP_RETURN, 3),

        // Failed
        opS(if (invert) c.JOP_LOAD_TRUE else c.JOP_LOAD_FALSE, 3),
        opS(c.JOP_RETURN, 3),
    };
    quickAsmDef(
        env,
        flags | c.JANET_FUNCDEF_FLAG_VARARG,
        name,
        0,
        0,
        std.math.maxInt(i32),
        6,
        &comparator_asm,
        doc,
    );
}

/// `apply`. Registers: 0 function, 1 args, 2 argn, 3 jump flag, 4 iterator,
/// 5 loop value.
fn makeApply(env: *c.JanetTable) void {
    const apply_asm = [_]u32{
        opSS(c.JOP_LENGTH, 2, 1),
        opSSS(c.JOP_EQUALS_IMMEDIATE, 3, 2, 0), // immediate tail call if no args
        opSI(c.JOP_JUMP_IF, 3, 9),

        opSI(c.JOP_LOAD_INTEGER, 4, 0),

        opSSS(c.JOP_IN, 5, 1, 4),
        opSSI(c.JOP_ADD_IMMEDIATE, 4, 4, 1),
        opSSI(c.JOP_EQUALS, 3, 4, 2),
        opSI(c.JOP_JUMP_IF, 3, 3),
        opS(c.JOP_PUSH, 5),
        opword(c.JOP_JUMP) | (@as(u32, @bitCast(@as(i32, -5))) << 8),

        opS(c.JOP_PUSH_ARRAY, 5),

        opS(c.JOP_TAILCALL, 0),
    };
    quickAsmDef(
        env,
        c.JANET_FUN_APPLY | c.JANET_FUNCDEF_FLAG_VARARG,
        "apply",
        1,
        1,
        std.math.maxInt(i32),
        6,
        &apply_asm,
        "(apply f & args)\n\n" ++
            "Applies a function f to a variable number of arguments. Each " ++
            "element in args is used as an argument to f, except the last " ++
            "element in args, which is expected to be an array or a tuple. " ++
            "Each element in this last argument is then also pushed as an " ++
            "argument to f.",
    );
}

fn opOnly(comptime op: anytype) [1]u32 {
    return .{opword(op)};
}

// ==========================================================================
// Setting up the environment.
// ==========================================================================

fn loadLibs(env: *c.JanetTable) raise.Raising(void) {
    const entries = [_]corefn.Entry{
        corefn.reg("native", &cfunNative, @src(), "(native path &opt env)", "Load a native module from the given path. The path " ++
            "must be an absolute or relative path on the file system, and is " ++
            "usually a .so file on Unix systems, and a .dll file on Windows. " ++
            "Returns an environment table that contains functions and other values " ++
            "from the native module."),
        corefn.reg("describe", &cfunDescribe, @src(), "(describe x)", "Returns a string that is a human-readable description of `x`. " ++
            "For recursive data structures, the string returned contains a " ++
            "pointer value from which the identity of `x` " ++
            "can be determined."),
        corefn.reg("string", &Concat(finishString).cfun, @src(), "(string & xs)", "Creates a string by concatenating the elements of `xs` together. If an " ++
            "element is not a byte sequence, it is converted to bytes via `describe`. " ++
            "Returns the new string."),
        corefn.reg("symbol", &Concat(finishSymbol).cfun, @src(), "(symbol & xs)", "Creates a symbol by concatenating the elements of `xs` together. If an " ++
            "element is not a byte sequence, it is converted to bytes via `describe`. " ++
            "Returns the new symbol."),
        corefn.reg("keyword", &Concat(finishKeyword).cfun, @src(), "(keyword & xs)", "Creates a keyword by concatenating the elements of `xs` together. If an " ++
            "element is not a byte sequence, it is converted to bytes via `describe`. " ++
            "Returns the new keyword."),
        corefn.reg("buffer", &Concat(finishBuffer).cfun, @src(), "(buffer & xs)", "Creates a buffer by concatenating the elements of `xs` together. If an " ++
            "element is not a byte sequence, it is converted to bytes via `describe`. " ++
            "Returns the new buffer."),
        corefn.reg("abstract?", &cfunIsAbstract, @src(), "(abstract? x)", "Check if x is an abstract type."),
        corefn.reg("table", &cfunTable, @src(), "(table & kvs)", "Creates a new table from a variadic number of keys and values. " ++
            "kvs is a sequence k1, v1, k2, v2, k3, v3, ... If kvs has " ++
            "an odd number of elements, an error will be thrown. Returns the " ++
            "new table."),
        corefn.reg("array", &cfunArray, @src(), "(array & items)", "Create a new array that contains items. Returns the new array."),
        corefn.reg("scan-number", &cfunScanNumber, @src(), "(scan-number str &opt base)", "Parse a number from a byte sequence and return that number, either an integer " ++
            "or a real. The number " ++
            "must be in the same format as numbers in janet source code. Will return nil " ++
            "on an invalid number. Optionally provide a base - if a base is provided, no " ++
            "radix specifier is expected at the beginning of the number."),
        corefn.reg("tuple", &cfunTuple, @src(), "(tuple & items)", "Creates a new tuple that contains items. Returns the new tuple."),
        corefn.reg("struct", &cfunStruct, @src(), "(struct & kvs)", "Create a new struct from a sequence of key value pairs. " ++
            "kvs is a sequence k1, v1, k2, v2, k3, v3, ... If kvs has " ++
            "an odd number of elements, an error will be thrown. Returns the " ++
            "new struct."),
        corefn.reg("gensym", &cfunGensym, @src(), "(gensym)", "Returns a new symbol that is unique across the runtime. This means it " ++
            "will not collide with any already created symbols during compilation, so " ++
            "it can be used in macros to generate automatic bindings."),
        corefn.reg("gccollect", &cfunGccollect, @src(), "(gccollect)", "Run garbage collection. You should probably not call this manually."),
        corefn.reg("gcsetinterval", &cfunGcsetinterval, @src(), "(gcsetinterval interval)", "Set an integer number of bytes to allocate before running garbage collection. " ++
            "Low values for interval will be slower but use less memory. " ++
            "High values will be faster but use more memory."),
        corefn.reg("gcinterval", &cfunGcinterval, @src(), "(gcinterval)", "Returns the integer number of bytes to allocate before running an iteration " ++
            "of garbage collection."),
        corefn.reg("type", &cfunType, @src(), "(type x)", "Returns the type of `x` as a keyword. `x` is one of:\n\n" ++
            "* :number\n" ++
            "* :nil\n" ++
            "* :boolean\n" ++
            "* :fiber\n" ++
            "* :string\n" ++
            "* :symbol\n" ++
            "* :keyword\n" ++
            "* :array\n" ++
            "* :tuple\n" ++
            "* :table\n" ++
            "* :struct\n" ++
            "* :buffer\n" ++
            "* :function\n" ++
            "* :cfunction\n" ++
            "* :pointer\n\n" ++
            "or another keyword for an abstract type."),
        corefn.reg("hash", &cfunHash, @src(), "(hash value)", "Gets a hash for any value. The hash is an integer can be used " ++
            "as a cheap hash function for all values. If two values are strictly equal, " ++
            "then they will have the same hash value."),
        corefn.reg("getline", &cfunGetline, @src(), "(getline &opt prompt buf env)", "Reads a line of input into a buffer, including the newline character, using a prompt. " ++
            "An optional environment table can be provided for auto-complete. " ++
            "Returns the modified buffer. " ++
            "Use this function to implement a simple interface for a terminal program."),
        corefn.reg("dyn", &cfunDyn, @src(), "(dyn key &opt default)", "Get a dynamic binding. Returns the default value (or nil) if no binding found."),
        corefn.reg("setdyn", &cfunSetdyn, @src(), "(setdyn key value)", "Set a dynamic binding. Returns value."),
        corefn.reg("trace", &cfunTrace, @src(), "(trace func)", "Enable tracing on a function. Returns the function."),
        corefn.reg("untrace", &cfunUntrace, @src(), "(untrace func)", "Disables tracing on a function. Returns the function."),
        corefn.reg("module/expand-path", &cfunExpandPath, @src(), "(module/expand-path path template)", "Expands a path template as found in `module/paths` for `module/find`. " ++
            "This takes in a path (the argument to require) and a template string, " ++
            "to expand the path to a path that can be used for importing files. " ++
            "The replacements are as follows:\n\n" ++
            "* :all: -- the value of path verbatim.\n\n" ++
            "* :@all: -- Same as :all:, but if `path` starts with the @ character, " ++
            "the first path segment is replaced with a dynamic binding " ++
            "`(dyn <first path segment as keyword>)`.\n\n" ++
            "* :cur: -- the directory portion, if any, of (dyn :current-file)\n\n" ++
            "* :dir: -- the directory portion, if any, of the path argument\n\n" ++
            "* :name: -- the name component of path, with extension if given\n\n" ++
            "* :native: -- the extension used to load natives, .so or .dll\n\n" ++
            "* :sys: -- the system path, or (dyn :syspath)"),
        corefn.reg("int?", &cfunCheckInt, @src(), "(int? x)", "Check if x can be exactly represented as a 32 bit signed two's complement integer."),
        corefn.reg("nat?", &cfunCheckNat, @src(), "(nat? x)", "Check if x can be exactly represented as a non-negative 32 bit signed two's complement integer."),
        corefn.reg("bytes?", &TypeFlagPredicate(c.JANET_TFLAG_BYTES).cfun, @src(), "(bytes? x)", "Check if x is a string, symbol, keyword, or buffer."),
        corefn.reg("indexed?", &TypeFlagPredicate(c.JANET_TFLAG_INDEXED).cfun, @src(), "(indexed? x)", "Check if x is an array or tuple."),
        corefn.reg("dictionary?", &TypeFlagPredicate(c.JANET_TFLAG_DICTIONARY).cfun, @src(), "(dictionary? x)", "Check if x is a table or struct."),
        corefn.reg("lengthable?", &TypeFlagPredicate(c.JANET_TFLAG_LENGTHABLE).cfun, @src(), "(lengthable? x)", "Check if x is a bytes, indexed, or dictionary."),
        corefn.reg("slice", &cfunSlice, @src(), "(slice x &opt start end)", "Extract a sub-range of an indexed data structure or byte sequence."),
        corefn.reg("range", &cfunRange, @src(), "(range & args)", "Create an array of values [start, end) with a given step. " ++
            "With one argument, returns a range [0, end). With two arguments, returns " ++
            "a range [start, end). With three, returns a range with optional step size."),
        corefn.reg("signal", &cfunSignal, @src(), "(signal what x)", "Raise a signal with payload x. `what` can be an integer\n" ++
            "from 0 through 7 indicating user(0-7), or one of:\n\n" ++
            "* :ok\n" ++
            "* :error\n" ++
            "* :debug\n" ++
            "* :yield\n" ++
            "* :user(0-7)\n" ++
            "* :interrupt\n" ++
            "* :await"),
        corefn.reg("memcmp", &cfunMemcmp, @src(), "(memcmp a b &opt len offset-a offset-b)", "Compare memory. Takes two byte sequences `a` and `b`, and " ++
            "return 0 if they have identical contents, a negative integer if a is less than b, " ++
            "and a positive integer if a is greater than b. Optionally take a length and offsets " ++
            "to compare slices of the bytes sequences."),
        corefn.reg("getproto", &cfunGetproto, @src(), "(getproto x)", "Get the prototype of a table or struct. Will return nil if `x` has no prototype."),
        corefn.reg("sandbox", &cfunSandbox, @src(), "(sandbox & forbidden-capabilities)", "Disable feature sets to prevent the interpreter from using certain system resources. " ++
            "Once a feature is disabled, there is no way to re-enable it. Capabilities can be:\n\n" ++
            "* :all - disallow all (except IO to stdout, stderr, and stdin)\n" ++
            "* :asm - disallow calling `asm` and `disasm` functions.\n" ++
            "* :chroot - disallow calling `os/posix-chroot`\n" ++
            "* :compile - disallow calling `compile`. This will disable a lot of functionality, such as `eval`.\n" ++
            "* :env - disallow reading and write env variables\n" ++
            "* :exit - disallow calling `os/exit` or otherwise early exiting the process in trivial ways.\n" ++
            "* :ffi - disallow FFI (recommended if disabling anything else)\n" ++
            "* :ffi-define - disallow loading new FFI modules and binding new functions\n" ++
            "* :ffi-jit - disallow calling `ffi/jitfn`\n" ++
            "* :ffi-use - disallow using any previously bound FFI functions and memory-unsafe functions.\n" ++
            "* :fs - disallow access to the file system\n" ++
            "* :fs-read - disallow read access to the file system\n" ++
            "* :fs-temp - disallow creating temporary files\n" ++
            "* :fs-write - disallow write access to the file system\n" ++
            "* :hrtime - disallow high-resolution timers\n" ++
            "* :modules - disallow load dynamic modules (natives)\n" ++
            "* :net - disallow network access\n" ++
            "* :net-connect - disallow making outbound network connections\n" ++
            "* :net-listen - disallow accepting inbound network connections\n" ++
            "* :sandbox - disallow calling this function\n" ++
            "* :signal - disallow adding or removing signal handlers\n" ++
            "* :subprocess - disallow running subprocesses\n" ++
            "* :threads - disallow spawning threads with `ev/thread`. Certain helper threads may still be spawned.\n" ++
            "* :unmarshal - disallow calling the `unmarshal` function.\n"),
        corefn.end,
    };
    corefn.install(env, &entries);
    try io_core.janet_lib_ioImpl(env);
    try math.janet_lib_mathImpl(env);
    janet_lib_array(env);
    janet_lib_tuple(env);
    janet_lib_buffer(env);
    janet_lib_table(env);
    janet_lib_struct(env);
    try fiber_core.janet_lib_fiberImpl(env);
    try os_surface.janet_lib_osImpl(env);
    janet_lib_parse(env);
    janet_lib_compile(env);
    janet_lib_debug(env);
    janet_lib_string(env);
    janet_lib_marsh(env);
    if (has_peg) try peg.janet_lib_pegImpl(env);
    if (has_assembler) try asm_core.janet_lib_asmImpl(env);
    if (has_int_types) try inttypes.janet_lib_inttypesImpl(env);
    if (has_ev) {
        try ev_loop.janet_lib_evImpl(env);
        if (has_filewatch) janet_lib_filewatch(env);
    }
    if (has_net) janet_lib_net(env);
    if (has_ffi) janet_lib_ffi(env);
}

/// Assembled from scratch, in the image generator. Everything here ends up in
/// the image, so this is the only place these thirty-odd bindings exist.
fn bootstrapCoreEnv(replacements: [*c]c.JanetTable) raise.Raising(*c.JanetTable) {
    const env: *c.JanetTable = if (replacements != null) replacements else c.janet_table(0);

    quickAsmDef(env, c.JANET_FUN_CMP, "cmp", 2, 2, 2, 2, &opOnly(c.JOP_COMPARE | (1 << 24)) ++ opOnly(c.JOP_RETURN), "(cmp x y)\n\n" ++
        "Returns -1 if x is strictly less than y, 1 if y is strictly greater " ++
        "than x, and 0 otherwise. To return 0, x and y must be the exact same type.");
    quickAsmDef(env, c.JANET_FUN_NEXT, "next", 2, 1, 2, 2, &opOnly(c.JOP_NEXT | (1 << 24)) ++ opOnly(c.JOP_RETURN), "(next x &opt key)\n\n" ++
        "Gets the next key in `x`. Can be used to iterate through " ++
        "the keys of `x` in an unspecified order. Keys are guaranteed " ++
        "to be seen only once per iteration if `x` is not mutated " ++
        "during iteration. If `key` is `nil`, returns the first key. " ++
        "If `nil` is returned, there are no more keys to iterate " ++
        "through.\n" ++
        "\n" ++
        "`x` can be a bytes, indexed, dictionary, fiber, or abstract " ++
        "type with a suitable `next` method.");
    quickAsmDef(env, c.JANET_FUN_PROP, "propagate", 2, 2, 2, 2, &opOnly(c.JOP_PROPAGATE | (1 << 24)) ++ opOnly(c.JOP_RETURN), "(propagate x fiber)\n\n" ++
        "Propagate a signal from a fiber to the current fiber and " ++
        "set the last value of the current fiber to `x`.  The signal " ++
        "value is then available as the status of the current fiber. " ++
        "The resulting stack trace from the current fiber will include " ++
        "frames from fiber. If fiber is in a state that can be resumed, " ++
        "resuming the current fiber will first resume `fiber`. " ++
        "This function can be used to re-raise an error without losing " ++
        "the original stack trace.");
    quickAsmDef(env, c.JANET_FUN_DEBUG, "debug", 1, 0, 1, 1, &opOnly(c.JOP_SIGNAL | (2 << 24)) ++ opOnly(c.JOP_RETURN), "(debug &opt x)\n\n" ++
        "Throws a debug signal that can be caught by a parent fiber and used to inspect " ++
        "the running state of the current fiber. Returns the value passed in by resume.");
    quickAsmDef(env, c.JANET_FUN_ERROR, "error", 1, 1, 1, 1, &opOnly(c.JOP_ERROR), "(error e)\n\n" ++
        "Throws an error e that can be caught and handled by a parent fiber.");
    quickAsmDef(env, c.JANET_FUN_YIELD, "yield", 1, 0, 1, 2, &opOnly(c.JOP_SIGNAL | (3 << 24)) ++ opOnly(c.JOP_RETURN), "(yield &opt x)\n\n" ++
        "Yield a value to a parent fiber. When a fiber yields, its execution is paused until " ++
        "another thread resumes it. The fiber will then resume, and the last yield call will " ++
        "return the value that was passed to resume.");
    quickAsmDef(env, c.JANET_FUN_CANCEL, "cancel", 2, 2, 2, 2, &opOnly(c.JOP_CANCEL | (1 << 24)) ++ opOnly(c.JOP_RETURN), "(cancel fiber err)\n\n" ++
        "Resume a fiber but have it immediately raise an error. This lets a programmer unwind a pending fiber. " ++
        "Returns the same result as resume.");
    quickAsmDef(env, c.JANET_FUN_RESUME, "resume", 2, 1, 2, 2, &opOnly(c.JOP_RESUME | (1 << 24)) ++ opOnly(c.JOP_RETURN), "(resume fiber &opt x)\n\n" ++
        "Resume a new or suspended fiber and optionally pass in a value to the fiber that " ++
        "will be returned to the last yield in the case of a pending fiber, or the argument to " ++
        "the dispatch function in the case of a new fiber. Returns either the return result of " ++
        "the fiber's dispatch function, or the value from the next yield call in fiber.");
    quickAsmDef(env, c.JANET_FUN_IN, "in", 3, 2, 3, 4, &in_asm, "(in x key &opt dflt)\n\n" ++
        "Get value in `x` at `key`. For bytes and indexed " ++
        "types, `key` must be a non-negative interger in " ++
        "bounds or an error is raised. For dictionaries " ++
        "`key` must be a non-nil value and if not found, " ++
        "will return `dflt` if provided or `nil` otherwise.\n" ++
        "\n" ++
        "`x` can be a bytes, indexed, dictionary, fiber, or " ++
        "abstract type with a suitable `get` method.");
    // The C original passes `sizeof(in_asm)` here rather than `sizeof(get_asm)`.
    // The two arrays are the same length, so it is a copy-paste slip with no
    // effect; the slice below is `get_asm`'s own, which is what the C meant.
    quickAsmDef(env, c.JANET_FUN_GET, "get", 3, 2, 3, 4, &get_asm, "(get x key &opt dflt)\n\n" ++
        "Get the value mapped to `key` in `x`. Returns `dflt` " ++
        "or `nil` if `key` is not found. Similar to `in`, but " ++
        "will not throw an error if `key` is invalid for `x`. " ++
        "However, if `x` is an abstract type, its getter may " ++
        "throw an error.\n" ++
        "\n" ++
        "`x` can be a bytes, indexed, dictionary, fiber, or " ++
        "abstract type with a suitable `get` method.");
    quickAsmDef(env, c.JANET_FUN_PUT, "put", 3, 3, 3, 3, &opOnly(c.JOP_PUT | (1 << 16) | (2 << 24)) ++ opOnly(c.JOP_RETURN), "(put x key val)\n\n" ++
        "Associate `key` with `val` for mutable `x`. Arrays " ++
        "and buffers only accept non-negative integer keys, " ++
        "and will expand if an out of bounds value is " ++
        "provided. For an array, extra space will be filled " ++
        "with `nil`s, while for buffers, 0 bytes are used " ++
        "instead. For a table, putting a key that is in the " ++
        "table prototype will hide the association defined by " ++
        "the prototype, but will not mutate the prototype " ++
        "table. Putting a `nil` value into a table will " ++
        "remove the table's corresponding association. " ++
        "Returns `x`.");
    quickAsmDef(env, c.JANET_FUN_LENGTH, "length", 1, 1, 1, 1, &opOnly(c.JOP_LENGTH) ++ opOnly(c.JOP_RETURN), "(length ds)\n\n" ++
        "Returns the length or count of a data structure in constant time as an integer. For " ++
        "structs and tables, returns the number of key-value pairs in the data structure.");
    quickAsmDef(env, c.JANET_FUN_BNOT, "bnot", 1, 1, 1, 1, &opOnly(c.JOP_BNOT) ++ opOnly(c.JOP_RETURN), "(bnot x)\n\nReturns the bit-wise inverse of integer x.");
    makeApply(env);

    // Variadic operators
    templatizeVarop(env, c.JANET_FUN_ADD, "+", 0, 0, c.JOP_ADD, "(+ & xs)\n\n" ++
        "Returns the sum of all xs. If xs is empty, return 0.");
    templatizeVarop(env, c.JANET_FUN_SUBTRACT, "-", 0, 0, c.JOP_SUBTRACT, "(- & xs)\n\n" ++
        "Returns the difference of xs. If xs is empty, returns 0. If xs has one element, returns the " ++
        "negative value of that element. Otherwise, returns the first element in xs minus the sum of " ++
        "the rest of the elements.");
    templatizeVarop(env, c.JANET_FUN_MULTIPLY, "*", 1, 1, c.JOP_MULTIPLY, "(* & xs)\n\n" ++
        "Returns the product of all elements in xs. If xs is empty, returns 1.");
    templatizeVarop(env, c.JANET_FUN_DIVIDE, "/", 1, 1, c.JOP_DIVIDE, "(/ & xs)\n\n" ++
        "Returns the quotient of xs. If xs is empty, returns 1. If xs has one value x, returns " ++
        "the reciprocal of x. Otherwise return the first value of xs repeatedly divided by the remaining " ++
        "values.");
    templatizeVarop(env, c.JANET_FUN_DIVIDE_FLOOR, "div", 1, 1, c.JOP_DIVIDE_FLOOR, "(div & xs)\n\n" ++
        "Returns the floored division of xs. If xs is empty, returns 1. If xs has one value x, returns " ++
        "the reciprocal of x. Otherwise return the first value of xs repeatedly divided by the remaining " ++
        "values.");
    templatizeVarop(env, c.JANET_FUN_MODULO, "mod", 0, 1, c.JOP_MODULO, "(mod & xs)\n\n" ++
        "Returns the result of applying the modulo operator on the first value of xs with each remaining value. " ++
        "`(mod x 0)` is defined to be `x`.");
    templatizeVarop(env, c.JANET_FUN_REMAINDER, "%", 0, 1, c.JOP_REMAINDER, "(% & xs)\n\n" ++
        "Returns the remainder of dividing the first value of xs by each remaining value.");
    templatizeVarop(env, c.JANET_FUN_BAND, "band", -1, -1, c.JOP_BAND, "(band & xs)\n\n" ++
        "Returns the bit-wise and of all values in xs. Each x in xs must be an integer.");
    templatizeVarop(env, c.JANET_FUN_BOR, "bor", 0, 0, c.JOP_BOR, "(bor & xs)\n\n" ++
        "Returns the bit-wise or of all values in xs. Each x in xs must be an integer.");
    templatizeVarop(env, c.JANET_FUN_BXOR, "bxor", 0, 0, c.JOP_BXOR, "(bxor & xs)\n\n" ++
        "Returns the bit-wise xor of all values in xs. Each x in xs must be an integer.");
    templatizeVarop(env, c.JANET_FUN_LSHIFT, "blshift", 1, 1, c.JOP_SHIFT_LEFT, "(blshift x & shifts)\n\n" ++
        "Returns the value of x bit shifted left by the sum of all values in shifts. x " ++
        "and each element in shift must be an integer.");
    templatizeVarop(env, c.JANET_FUN_RSHIFT, "brshift", 1, 1, c.JOP_SHIFT_RIGHT, "(brshift x & shifts)\n\n" ++
        "Returns the value of x bit shifted right by the sum of all values in shifts. x " ++
        "and each element in shift must be an integer.");
    templatizeVarop(env, c.JANET_FUN_RSHIFTU, "brushift", 1, 1, c.JOP_SHIFT_RIGHT_UNSIGNED, "(brushift x & shifts)\n\n" ++
        "Returns the value of x bit shifted right by the sum of all values in shifts. x " ++
        "and each element in shift must be an integer. The sign of x is not preserved, so " ++
        "for positive shifts the return value will always be positive.");

    // Variadic comparators
    templatizeComparator(env, c.JANET_FUN_GT, ">", false, c.JOP_GREATER_THAN, "(> & xs)\n\n" ++
        "Check if xs is in descending order. Returns a boolean.");
    templatizeComparator(env, c.JANET_FUN_LT, "<", false, c.JOP_LESS_THAN, "(< & xs)\n\n" ++
        "Check if xs is in ascending order. Returns a boolean.");
    templatizeComparator(env, c.JANET_FUN_GTE, ">=", false, c.JOP_GREATER_THAN_EQUAL, "(>= & xs)\n\n" ++
        "Check if xs is in non-ascending order. Returns a boolean.");
    templatizeComparator(env, c.JANET_FUN_LTE, "<=", false, c.JOP_LESS_THAN_EQUAL, "(<= & xs)\n\n" ++
        "Check if xs is in non-descending order. Returns a boolean.");
    templatizeComparator(env, c.JANET_FUN_EQ, "=", false, c.JOP_EQUALS, "(= & xs)\n\n" ++
        "Check if all values in xs are equal. Returns a boolean.");
    templatizeComparator(env, c.JANET_FUN_NEQ, "not=", true, c.JOP_EQUALS, "(not= & xs)\n\n" ++
        "Check if any values in xs are not equal. Returns a boolean.");

    // Platform detection
    c.janet_def(env, "janet/version", c.janet_cstringv(c.JANET_VERSION), "The version number of the running janet program.");
    c.janet_def(env, "janet/build", c.janet_cstringv(c.JANET_BUILD), "The build identifier of the running janet program.");
    c.janet_def(env, "janet/config-bits", wrapInteger(c.JANET_CURRENT_CONFIG_BITS), "The flag set of config options from janetconf.h which is used to check " ++
        "if native modules are compatible with the host program.");

    // Allow references to the environment
    c.janet_def(env, "root-env", c.janet_wrap_table(env), "The root environment used to create environments with (make-env).");

    try loadLibs(env);
    c.janet_gcroot(c.janet_wrap_table(env));
    return env;
}

const in_asm = [_]u32{
    opword(c.JOP_IN) | (1 << 24),
    opword(c.JOP_LOAD_NIL) | (3 << 8),
    opword(c.JOP_EQUALS) | (3 << 8) | (3 << 24),
    opword(c.JOP_JUMP_IF) | (3 << 8) | (2 << 16),
    opword(c.JOP_RETURN),
    opword(c.JOP_RETURN) | (2 << 8),
};

const get_asm = [_]u32{
    opword(c.JOP_GET) | (1 << 24),
    opword(c.JOP_LOAD_NIL) | (3 << 8),
    opword(c.JOP_EQUALS) | (3 << 8) | (3 << 24),
    opword(c.JOP_JUMP_IF) | (3 << 8) | (2 << 16),
    opword(c.JOP_RETURN),
    opword(c.JOP_RETURN) | (2 << 8),
};

/// The core image, generated by `janet-boot` and embedded rather than linked.
///
/// It was `janet-image.c` until Phase 11 Part 19 -- 2,007,197 bytes of hex
/// literals wrapped in `#include "janet.h"`, carrying 324,310 bytes of image,
/// and the last C translation unit compiled into anything this tree produces.
/// `build.zig` hands the generator's output to this module as an anonymous
/// import; `@embedFile` is what replaces the two `extern const`s.
///
/// Referenced only from the runtime branch below, and a container-level
/// declaration is analysed only when something references it -- so the
/// bootstrap build, which has no image and is what produces one, never asks
/// for the import. That is the same laziness the `extern` relied on, one step
/// earlier: it used to be the linker that was never asked.
///
/// **The length is one byte shorter than it was, deliberately.** The C emitter
/// appended a `0` so the array had a terminator, and `janet_core_image_size`
/// was that array's `sizeof` -- so the runtime handed `unmarshal` 324,311
/// bytes for a 324,310-byte image and read the extra one only if the stream
/// asked it to, which it does not. `@embedFile` still gives a sentinel-
/// terminated array, and `.len` is the image.
/// `pub` for `test/core_env.zig`, which asserts that unmarshalling consumes
/// exactly `core_image.len` bytes. That is the claim the shortened length
/// rests on, and it is not one the runtime itself has any reason to make.
pub const core_image = @embedFile("janet_image");

/// Unmarshalled from the image, in the runtime. Memoized in `janet_vm`, which
/// is what makes the replacements argument meaningful only on the first call.
fn imageCoreEnv(replacements: [*c]c.JanetTable) raise.Raising(*c.JanetTable) {
    if (c.janet_vm.core_env) |memoized| return memoized;

    const dict = try coreLookupTable(replacements);

    const marsh_out = try raise.crossing(try marsh.unmarshal(
        core_image,
        core_image.len,
        0,
        dict,
        null,
    ));

    c.janet_gcroot(marsh_out);
    const env = c.janet_unwrap_table(marsh_out);
    c.janet_vm.core_env = env;

    // Invert the image dict here rather than in `boot.janet`, where it would
    // break deterministic builds.
    var lidv = c.janet_wrap_nil();
    var midv = c.janet_wrap_nil();
    _ = c.janet_resolve(env, c.janet_csymbol("load-image-dict"), &lidv);
    _ = c.janet_resolve(env, c.janet_csymbol("make-image-dict"), &midv);

    // A smaller corelib may not have either, so check rather than assume.
    if (c.janet_checktype(lidv, c.JANET_TABLE) != 0 and c.janet_checktype(midv, c.JANET_TABLE) != 0) {
        const lid = c.janet_unwrap_table(lidv);
        const mid = c.janet_unwrap_table(midv);
        var i: i32 = 0;
        while (i < lid.*.capacity) : (i += 1) {
            const kv = lid.*.data + @as(usize, @intCast(i));
            if (c.janet_checktype(kv.*.key, c.JANET_NIL) == 0) {
                c.janet_table_put(mid, kv.*.value, kv.*.key);
            }
        }
    }

    return env;
}

export fn janet_core_env(replacements: [*c]c.JanetTable) callconv(.c) *c.JanetTable {
    return raise.reported(coreEnv(replacements));
}

pub fn coreEnv(replacements: [*c]c.JanetTable) raise.Raising(*c.JanetTable) {
    return if (corefn.bootstrap)
        bootstrapCoreEnv(replacements)
    else
        imageCoreEnv(replacements);
}

export fn janet_core_lookup_table(replacements: [*c]c.JanetTable) callconv(.c) *c.JanetTable {
    return raise.reported(coreLookupTable(replacements));
}

pub fn coreLookupTable(replacements: [*c]c.JanetTable) raise.Raising(*c.JanetTable) {
    const dict = c.janet_table(512);
    try loadLibs(dict);

    if (replacements != null) {
        var i: i32 = 0;
        while (i < replacements.*.capacity) : (i += 1) {
            const kv = replacements.*.data[@intCast(i)];
            if (c.janet_checktype(kv.key, c.JANET_NIL) == 0) {
                c.janet_table_put(dict, kv.key, kv.value);
            }
        }
    }

    return dict;
}

// ==========================================================================
// src/core/run.c: running source in an environment.
// ==========================================================================

/// Parse, compile and run `bytes`, one top-level form at a time.
///
/// The return value is a set of `JANET_DO_ERROR_*` flags rather than a signal,
/// and diagnostics go to stderr, because this is the entry point an embedder
/// calls before there is anything to catch a raise. Nothing here returns
/// `raise.Error`: `janet_continue` reports a `JanetSignal` and the compiler
/// reports a status, so the failures this function handles arrive as values
/// already.
export fn janet_dobytes(
    env: [*c]c.JanetTable,
    bytes: [*c]const u8,
    len: i32,
    source_path: [*c]const u8,
    out: [*c]c.Janet,
) callconv(.c) c_int {
    return raise.reported(janet_dobytesImpl(env, bytes, len, source_path, out));
}

pub fn janet_dobytesImpl(
    env: [*c]c.JanetTable,
    bytes: [*c]const u8,
    len: i32,
    source_path: [*c]const u8,
    out: [*c]c.Janet,
) raise.Raising(c_int) {
    var errflags: c_int = 0;
    var done = false;
    var index: i32 = 0;
    var ret = c.janet_wrap_nil();
    var fiber: [*c]c.JanetFiber = null;
    const where: c.JanetString = if (source_path != null) c.janet_cstring(source_path) else null;

    if (where != null) c.janet_gcroot(c.janet_wrap_string(where));
    const path: [*c]const u8 = if (source_path != null) source_path else "<unknown>";
    const parser: *c.JanetParser = @ptrCast(@alignCast(c.janet_abstract(
        &c.janet_parser_type,
        @sizeOf(c.JanetParser),
    )));
    c.janet_parser_init(parser);
    c.janet_gcroot(c.janet_wrap_abstract(parser));

    while (!done) {
        while (c.janet_parser_has_more(parser) != 0) {
            const form = c.janet_parser_produce(parser);
            const cres = c.janet_compile(form, env, where);
            if (cres.status == c.JANET_COMPILE_OK) {
                const f = c.janet_thunk(cres.funcdef);
                fiber = c.janet_fiber(f, 64, 0, null);
                fiber.*.env = env;
                const status = c.janet_continue(fiber, c.janet_wrap_nil(), &ret);
                if (status != c.JANET_SIGNAL_OK and status != c.JANET_SIGNAL_EVENT) {
                    try trace_frames.stacktraceExt(fiber, ret, "");
                    errflags |= c.JANET_DO_ERROR_RUNTIME;
                    done = true;
                }
            } else {
                var line: i32 = @intCast(parser.line);
                var col: i32 = @intCast(parser.column);
                if (cres.error_mapping.line > 0 and cres.error_mapping.column > 0) {
                    line = cres.error_mapping.line;
                    col = cres.error_mapping.column;
                }
                const ctx = try pp_format.formatc("%s:%d:%d: compile error", .{ path, line, col });
                const errstr = try pp_format.formatc("%s: %s", .{ ctx, cres.@"error" });
                ret = c.janet_wrap_string(errstr);
                if (cres.macrofiber != null) {
                    eprintf("%s", .{ctx});
                    try trace_frames.stacktraceExt(cres.macrofiber, ret, "");
                } else {
                    eprintf("%s\n", .{errstr});
                }
                errflags |= c.JANET_DO_ERROR_COMPILE;
                done = true;
            }
        }

        if (done) break;

        switch (c.janet_parser_status(parser)) {
            c.JANET_PARSE_DEAD => done = true,
            c.JANET_PARSE_ERROR => {
                errflags |= c.JANET_DO_ERROR_PARSE;
                const line: i32 = @intCast(parser.line);
                const col: i32 = @intCast(parser.column);
                const errstr = try pp_format.formatc("%s:%d:%d: parse error: %s", .{ path, line, col, c.janet_parser_error(parser) });
                ret = c.janet_wrap_string(errstr);
                eprintf("%s\n", .{errstr});
                done = true;
            },
            else => {
                if (index >= len) {
                    try parser_core.eofChecked(parser);
                } else {
                    try parser_core.consumeChecked(parser, bytes[@intCast(index)]);
                    index += 1;
                }
            },
        }
    }

    _ = c.janet_gcunroot(c.janet_wrap_abstract(parser));
    if (where != null) _ = c.janet_gcunroot(c.janet_wrap_string(where));
    if (has_ev) {
        // Enter the event loop if we are not already in it.
        if (c.janet_vm.stackn == 0) {
            if (fiber != null) c.janet_gcroot(c.janet_wrap_fiber(fiber));
            try evloop.loop();
            if (fiber != null) {
                _ = c.janet_gcunroot(c.janet_wrap_fiber(fiber));
                if (errflags == 0) ret = fiber.*.last_value;
            }
        }
    }
    if (out != null) out.* = ret;
    return errflags;
}

export fn janet_dostring(
    env: [*c]c.JanetTable,
    str: [*c]const u8,
    source_path: [*c]const u8,
    out: [*c]c.Janet,
) callconv(.c) c_int {
    var len: i32 = 0;
    while (str[@intCast(len)] != 0) len += 1;
    return janet_dobytes(env, str, len, source_path, out);
}

/// Run a fiber to completion, through the event loop where there is one.
export fn janet_loop_fiber(fiber: [*c]c.JanetFiber) callconv(.c) c_int {
    return raise.reported(loopFiber(fiber));
}

pub fn loopFiber(fiber: [*c]c.JanetFiber) raise.Raising(c_int) {
    if (has_ev) {
        c.janet_schedule(fiber, c.janet_wrap_nil());
        try evloop.loop();
        return @intCast(c.janet_fiber_status(fiber));
    }
    var out: c.Janet = undefined;
    const status = c.janet_continue(fiber, c.janet_wrap_nil(), &out);
    if (status != c.JANET_SIGNAL_OK and status != c.JANET_SIGNAL_EVENT) {
        try trace_frames.stacktraceExt(fiber, out, "");
    }
    return @intCast(status);
}
