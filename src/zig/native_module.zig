const c = @cImport({
    @cInclude("janet.h");
});

export fn janet_zig_native_identity(argc: i32, argv: [*c]c.Janet, out: *c.Janet) callconv(.c) c_int {
    _ = argc;
    out.* = argv[0];
    return 1;
}
