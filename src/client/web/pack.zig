//! The web packer: names a web program's files by one hash of their contents
//! and writes the loader that refers to them.
//!
//! `build.zig`'s `wattleWeb` runs this on the build machine. It takes the
//! program's name, the runtime, the image, `wasi.js` and an output directory,
//! and writes four files there:
//!
//! | file | contents |
//! | --- | --- |
//! | `wattle-<hash>.wasm` | the runtime |
//! | `<name>-<hash>.wimage` | the image |
//! | `wasi-<hash>.js` | `wasi.js` |
//! | `<name>.js` | an ES module that imports the third and fetches the first two |
//!
//! `<hash>` is the first sixteen hexadecimal digits of one SHA-256 over the
//! runtime, the image and `wasi.js`, each preceded by its length. The three
//! files share it, so files with different hashes are from different builds
//! and one directory's worth can be deleted by hash. A change to any of the
//! three gives all three new names, so a cache that keys on the URL cannot
//! serve an old runtime or image beside a new loader. `<name>.js` keeps a fixed
//! name, because it is what a page imports, and a page that caches it is the
//! page's concern.

// ==========================================================================
// Standard library imports
// ==========================================================================

const std = @import("std");

// ==========================================================================
// Constants
// ==========================================================================

/// The loader, with the names of the runtime, the image and `wasi.js` in that
/// order.
///
/// `run` fetches the runtime and the image, runs the image and returns
/// `{ status, stdout, stderr, error }`. A caller passes other URLs to serve the
/// files from elsewhere.
const loader =
    \\import {{ start }} from "./{2s}";
    \\
    \\export async function run({{
    \\  wasm = new URL("./{0s}", import.meta.url),
    \\  image = new URL("./{1s}", import.meta.url),
    \\}} = {{}}) {{
    \\  const [binary, bytes] = await Promise.all([
    \\    fetch(wasm).then((response) => response.arrayBuffer()),
    \\    fetch(image).then((response) => response.arrayBuffer()),
    \\  ]);
    \\  const wattle = await start(await WebAssembly.compile(binary));
    \\  return wattle.runImage(new Uint8Array(bytes));
    \\}}
    \\
;

/// How many bytes of the digest a name spells.
const hash_bytes = 8;

// ==========================================================================
// Public functions
// ==========================================================================

/// Usage: `pack <name> <wasm> <image> <wasi.js> <out-dir>`. Returns 0 on
/// success and 2 on a wrong argument count.
pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 6) {
        std.debug.print("usage: pack <name> <wasm> <image> <wasi.js> <out-dir>\n", .{});
        return 2;
    }
    const name = args[1];
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, args[5]);
    var out = try cwd.openDir(init.io, args[5], .{});
    defer out.close(init.io);

    const wasm = try cwd.readFileAlloc(init.io, args[2], arena, .unlimited);
    const image = try cwd.readFileAlloc(init.io, args[3], arena, .unlimited);
    const support = try cwd.readFileAlloc(init.io, args[4], arena, .unlimited);

    const hash = hashed(&.{ wasm, image, support });
    const wasm_name = try std.fmt.allocPrint(arena, "wattle-{s}.wasm", .{hash});
    const image_name = try std.fmt.allocPrint(arena, "{s}-{s}.wimage", .{ name, hash });
    const support_name = try std.fmt.allocPrint(arena, "wasi-{s}.js", .{hash});
    const loader_name = try std.fmt.allocPrint(arena, "{s}.js", .{name});
    const loader_text = try std.fmt.allocPrint(arena, loader, .{ wasm_name, image_name, support_name });

    try out.writeFile(init.io, .{ .sub_path = wasm_name, .data = wasm });
    try out.writeFile(init.io, .{ .sub_path = image_name, .data = image });
    try out.writeFile(init.io, .{ .sub_path = support_name, .data = support });
    try out.writeFile(init.io, .{ .sub_path = loader_name, .data = loader_text });
    return 0;
}

// ==========================================================================
// Private functions
// ==========================================================================

/// The first `hash_bytes` bytes of the SHA-256 over `parts`, in lowercase
/// hexadecimal.
///
/// Each part is preceded by its length as eight little-endian bytes, so that
/// moving a byte from the end of one part to the start of the next changes the
/// hash.
fn hashed(parts: []const []const u8) [hash_bytes * 2]u8 {
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    for (parts) |part| {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, part.len, .little);
        sha.update(&length);
        sha.update(part);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    sha.final(&digest);
    return std.fmt.bytesToHex(digest[0..hash_bytes].*, .lower);
}
