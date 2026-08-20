//! A dynamically loaded Janet module written in Zig, and Phase 3's interop
//! proof that a `.so` outside the runtime can define a builtin.
//!
//! Phase 10 Part 17g moved the cfunction here from `src/zig/native_bridge.c`.
//! A cfunction returns `error{JanetSignal}!Janet` with Zig's own calling
//! convention now, so a C body cannot be one -- which is decision 2 arriving
//! at the place it is most visible, the native-module interface itself. The
//! bridge keeps the module entry point, because `JANET_MODULE_ENTRY` is a
//! macro and the loader looks the symbol up by name.
//!
//! `src/zig/interop.zig` has the note on what the link now rests on: Zig's
//! `.auto` calling convention, deterministic for a compiler version and
//! target rather than documented.

const abi = @import("abi.zig");
const c = abi.c;

/// `raise.CFunction`, spelled out -- this object is not the runtime's module.
const CFunction = *const fn (i32, [*c]c.Janet) error{JanetSignal}!c.Janet;

const alignment = 16;

/// `raise.crossing`, spelled out. This object is not the runtime's module, so
/// it cannot import `raise`; the note on `CFunction` above has the reason.
extern fn janet_zig_c_raise_take() callconv(.c) c_int;

inline fn crossing(value: anytype) error{JanetSignal}!@TypeOf(value) {
    if (janet_zig_c_raise_take() != 0) return error.JanetSignal;
    return value;
}

export fn janet_zig_native_identity(argc: i32, argv: [*c]c.Janet, out: *c.Janet) callconv(.c) c_int {
    _ = argc;
    out.* = argv[0];
    return 1;
}

fn nativeIdentity(argc: i32, argv: [*c]c.Janet) align(alignment) error{JanetSignal}!c.Janet {
    var result: c.Janet = undefined;
    try crossing(c.janet_fixarity(argc, 1));
    if (janet_zig_native_identity(argc, argv, &result) == 0) {
        try crossing(c.janet_panic("Zig native identity failed"));
    }
    return result;
}

/// The one definition `JANET_MODULE_ENTRY` installs, reached from the C
/// bridge so that the entry point stays where the loader looks for it.
export fn janet_zig_native_defs(env: *c.JanetTable) callconv(.c) void {
    const cfun: CFunction = &nativeIdentity;
    c.janet_def(
        env,
        "identity",
        c.janet_wrap_cfunction(@ptrCast(cfun)),
        "Round-trip a Janet value through a dynamically loaded Zig module.",
    );
}

// ------------------------------------------------------------ module entry

/// What `JANET_MODULE_ENTRY` spells as a macro: the two symbols the module
/// loader looks up by name.
///
/// `native_bridge.c` held these until Phase 10 Part 18, because the macro is a
/// preprocessor facility and translate-c cannot render one -- and because the
/// definitions it called were in this file, which made it a C-ABI crossing
/// between two Zig files, the shape rule 19 says to convert. Written out, it is
/// two exports and neither has anything to do with C -- which is the same
/// finding `stdio.zig` records about `stderr` and `io_core.zig` about
/// `JANET_EXIT`. Decision 2 ended the C ABI for module *authors*; the loader's
/// two symbol names are the interface itself and stay exactly as they were.
fn modConfig() callconv(.c) c.JanetBuildConfig {
    return c.janet_config_current();
}

fn modInit(env: *c.JanetTable) callconv(.c) void {
    janet_zig_native_defs(env);
}

comptime {
    @export(&modConfig, .{ .name = "_janet_mod_config" });
    @export(&modInit, .{ .name = "_janet_init" });
}
