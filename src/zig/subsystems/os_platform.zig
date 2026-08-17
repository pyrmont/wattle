//! Compile-target classification and the non-panicking kernel behind Janet's
//! platform introspection functions.
//!
//! C retains Janet argument validation, keyword allocation, custom
//! `JANET_OS_NAME` / `JANET_ARCH_NAME` overrides, and fallback Janet values.

const std = @import("std");
const builtin = @import("builtin");

const os_name = switch (builtin.os.tag) {
    .windows => switch (builtin.abi) {
        .gnu => "mingw",
        else => "windows",
    },
    .macos, .ios, .tvos, .watchos, .visionos => "macos",
    .emscripten => "web",
    .linux => "linux",
    .hurd => "hurd",
    .freebsd => "freebsd",
    .netbsd => "netbsd",
    .openbsd => "openbsd",
    .dragonfly => "dragonfly",
    .illumos => "illumos",
    else => "posix",
};

const arch_name = if (builtin.os.tag == .emscripten)
    "wasm"
else switch (builtin.cpu.arch) {
    .x86_64 => "x64",
    .x86 => "x86",
    .aarch64 => "aarch64",
    .arm, .armeb, .thumb, .thumbeb => "arm",
    .riscv64 => "riscv64",
    .riscv32 => "riscv32",
    .sparc, .sparc64 => "sparc",
    .powerpc, .powerpcle => "ppc",
    .powerpc64, .powerpc64le => "ppc64",
    .s390x => "s390x",
    else => "unknown",
};

const compiler_name = if (builtin.abi == .msvc) "msvc" else "clang";

export fn janet_os_name() callconv(.c) [*:0]const u8 {
    return os_name;
}

export fn janet_os_arch() callconv(.c) [*:0]const u8 {
    return arch_name;
}

export fn janet_os_compiler() callconv(.c) [*:0]const u8 {
    return compiler_name;
}

/// Return the same approximation families used by os.c, or -1 when that C
/// implementation would return the caller's fallback value. Linux preserves
/// the C path's zero result when querying affinity fails.
export fn janet_os_cpu_count() callconv(.c) i32 {
    switch (builtin.os.tag) {
        .illumos => {
            const count = std.c.sysconf(@intFromEnum(std.c._SC.NPROCESSORS_CONF));
            return if (count < 0) -1 else @intCast(count);
        },
        .windows, .linux, .freebsd, .netbsd, .openbsd, .dragonfly => {
            const count = std.Thread.getCpuCount() catch
                return if (builtin.os.tag == .linux) 0 else -1;
            return std.math.cast(i32, count) orelse std.math.maxInt(i32);
        },
        else => return -1,
    }
}
