const symbol_characters = [8]u32{
    0x00000000, 0xf7ffec72, 0xc7ffffff, 0x07fffffe,
    0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff,
};

export fn janet_is_symbol_char(character: u8) callconv(.c) c_int {
    const mask = symbol_characters[character >> 5] & (@as(u32, 1) << @intCast(character & 0x1f));
    return @bitCast(mask);
}

export fn janet_valid_utf8(string: [*c]const u8, length: i32) callconv(.c) c_int {
    if (length < 0) return 1;
    const bytes = string[0..@intCast(length)];
    var index: usize = 0;
    while (index < bytes.len) {
        const first = bytes[index];
        const width: usize = if (first < 0x80)
            1
        else if (first >> 5 == 0x06)
            2
        else if (first >> 4 == 0x0e)
            3
        else if (first >> 3 == 0x1e)
            4
        else
            return 0;

        const next = index + width;
        if (next > bytes.len) return 0;
        for (bytes[index + 1 .. next]) |continuation| {
            if (continuation >> 6 != 2) return 0;
        }
        if (width == 2 and first < 0xc2) return 0;
        if (first == 0xe0 and bytes[index + 1] < 0xa0) return 0;
        if (first == 0xf0 and bytes[index + 1] < 0x90) return 0;
        index = next;
    }
    return 1;
}
