//! Fails when a wasm binary imports from any module but `wasi_snapshot_preview1`.
//!
//! Zig turns an unresolved `extern fn` into an import from the module `env`
//! rather than into a link error, so a function wasi-libc declares and does
//! not define leaves a binary that links, installs, and is refused by the host
//! the first time it is run: wasmtime says "unknown import: `env::mkstemp` has
//! not been defined" and exits. Turning `rdynamic` off and setting
//! `link_z_defs` changes neither half of that.
//!
//! So the check is here, over the bytes, where it fails the build that made
//! the binary and can name the function. It reads the import section, section
//! id 2, which holds every import in module/field pairs.
//!
//! Usage: `wasm-imports <file.wasm>`.

const std = @import("std");

/// The one module a WASI command-line binary may import from.
const allowed = "wasi_snapshot_preview1";

/// What a wasm file opens with: the magic, then the format version.
const magic = "\x00asm";
const version = 1;

/// The section id the imports are in.
const import_section = 2;

/// A reader over the bytes, which every parse step below advances.
const Cursor = struct {
    bytes: []const u8,
    at: usize = 0,

    fn byte(self: *Cursor) !u8 {
        if (self.at >= self.bytes.len) return error.Truncated;
        defer self.at += 1;
        return self.bytes[self.at];
    }

    /// LEB128, unsigned. Every length, count and index in the format is one.
    fn leb(self: *Cursor) !u32 {
        var result: u32 = 0;
        var shift: u5 = 0;
        while (true) {
            const b = try self.byte();
            result |= @as(u32, b & 0x7f) << shift;
            if (b & 0x80 == 0) return result;
            shift = std.math.add(u5, shift, 7) catch return error.Malformed;
        }
    }

    fn take(self: *Cursor, n: usize) ![]const u8 {
        if (self.at + n > self.bytes.len) return error.Truncated;
        defer self.at += n;
        return self.bytes[self.at .. self.at + n];
    }

    /// A name is a length and that many bytes.
    fn name(self: *Cursor) ![]const u8 {
        return self.take(try self.leb());
    }

    /// A limits record: a flag byte, a minimum, and a maximum when the flag
    /// says there is one. Part of a table and a memory import's descriptor.
    fn limits(self: *Cursor) !void {
        const flags = try self.byte();
        _ = try self.leb();
        if (flags & 0x01 != 0) _ = try self.leb();
    }
};

/// Reports every import whose module is not `allowed`, and returns how many
/// there were.
fn checkImports(bytes: []const u8, path: []const u8) !usize {
    var cursor: Cursor = .{ .bytes = bytes };
    if (!std.mem.eql(u8, try cursor.take(4), magic)) return error.NotWasm;
    if (std.mem.readInt(u32, (try cursor.take(4))[0..4], .little) != version) return error.NotWasm;

    var rejected: usize = 0;
    while (cursor.at < bytes.len) {
        const id = try cursor.byte();
        const size = try cursor.leb();
        const body = try cursor.take(size);
        if (id != import_section) continue;

        var imports: Cursor = .{ .bytes = body };
        var left = try imports.leb();
        while (left > 0) : (left -= 1) {
            const module = try imports.name();
            const field = try imports.name();
            switch (try imports.byte()) {
                // A function import names a type; the other three describe
                // what they import inline.
                0x00 => _ = try imports.leb(),
                0x01 => {
                    _ = try imports.byte();
                    try imports.limits();
                },
                0x02 => try imports.limits(),
                0x03 => {
                    _ = try imports.byte();
                    _ = try imports.byte();
                },
                else => return error.Malformed,
            }
            if (std.mem.eql(u8, module, allowed)) continue;
            rejected += 1;
            std.debug.print(
                "{s}: imports `{s}::{s}`, which no WASI host defines\n",
                .{ path, module, field },
            );
        }
    }
    return rejected;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();

    var args = try init.minimal.args.iterateAllocator(arena);
    defer args.deinit();
    _ = args.skip();
    const path = args.next() orelse {
        std.debug.print("usage: wasm-imports <file.wasm>\n", .{});
        return 2;
    };

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .unlimited);
    const rejected = try checkImports(bytes, path);
    if (rejected != 0) {
        std.debug.print(
            "{d} import(s) from outside `{s}`. Every one is an `extern fn` " ++
                "this target has no definition for.\n",
            .{ rejected, allowed },
        );
    }
    return if (rejected == 0) 0 else 1;
}
