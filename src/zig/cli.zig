//! The `janet` client: the environment the command line runs in.
//!
//! **This is its own compilation**, and `build.zig` gives it `types`,
//! `constants` and `cabi` alone: it *links* the runtime rather than importing
//! it, so `c.janet_init` and its neighbours are C-ABI calls on purpose. That
//! is what an embedder writes, which is the point of the client being one.

const std = @import("std");
const repr = @import("repr");
const constants = @import("constants");
const c = @import("cabi");
const interop = @import("interop.zig");

/// `janet_cstringv` and its two siblings, which `cabi.zig` does not carry.
///
/// **This program is an embedder.** `build.zig` gives its module only `types`,
/// `constants` and `cabi`, because it *links* the runtime object rather than
/// importing it. `value.fromBytes` is therefore out of reach here, and should
/// be: importing `value.zig` would compile a second copy of the whole value
/// layer into an executable that already links one. `boot.zig` is in the same
/// position and carries the same three lines. So these spell the two C calls
/// the macro composed, which is what any embedder writes.
inline fn stringv(bytes: []const u8) repr.Value {
    return c.janet_wrap_string(c.janet_string(bytes.ptr, @intCast(bytes.len)));
}

inline fn symbolv(bytes: []const u8) repr.Value {
    return c.janet_wrap_symbol(c.janet_symbol(bytes.ptr, @intCast(bytes.len)));
}

/// A keyword is a symbol under a different tag; `janet.h:1844` is
/// `#define janet_keyword janet_symbol`.
inline fn keywordv(bytes: []const u8) repr.Value {
    return c.janet_wrap_keyword(c.janet_symbol(bytes.ptr, @intCast(bytes.len)));
}

pub fn main(init: std.process.Init) !u8 {
    interop.setIo(init.io);
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len == 0) return 1;
    return std.math.cast(u8, run(arguments)) orelse 1;
}

/// Build the environment the CLI runs in, resolve `cli-main`, and hand it a
/// fiber.
fn run(arguments: []const [:0]const u8) c_int {
    if (c.janet_init() != 0) return 1;
    defer c.janet_deinit();

    const replacements = c.janet_table(0);
    c.janet_table_put(replacements, symbolv("getline"), interop.lineGetterValue());
    const env = c.janet_core_env(replacements);

    var err: repr.Value = c.janet_wrap_nil();
    if (interop.register(env, &err)) return 1;

    const args = c.janet_array(@intCast(arguments.len));
    for (arguments[1..]) |argument| c.janet_array_push(args, stringv(argument));
    c.janet_table_put(env, keywordv("executable"), stringv(arguments[0]));

    var main_function: repr.Value = c.janet_wrap_nil();
    if (c.janet_resolve(env, c.janet_csymbol("cli-main"), &main_function) == constants.JANET_BINDING_NONE)
        return 1;

    var main_args = [_]repr.Value{c.janet_wrap_array(args)};
    // `janet_fiber` answers null when the callee's arity rejects the arguments.
    // `cli-main` takes one, and the core image is what guarantees it, so the
    // `.?` is a claim about the image rather than about this call.
    const fiber = c.janet_fiber(c.janet_unwrap_function(main_function), 64, 1, &main_args).?;
    _ = c.janet_gcroot(c.janet_wrap_fiber(fiber));
    fiber.env = env;
    return c.janet_loop_fiber(fiber);
}
