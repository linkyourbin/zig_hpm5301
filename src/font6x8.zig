pub const Glyph = struct {
    codepoint: u8,
    width: u8,
    height: u8,
    x_advance: u8,
    bitmap_offset: usize,
};

pub const width: u16 = 6;
pub const height: u16 = 8;
pub const cell_width: u16 = 6;

pub const glyphs = [_]Glyph{
    .{ .codepoint = ' ', .width = 6, .height = 8, .x_advance = 6, .bitmap_offset = 0 },
    .{ .codepoint = 'Z', .width = 6, .height = 8, .x_advance = 6, .bitmap_offset = 6 },
    .{ .codepoint = 'I', .width = 6, .height = 8, .x_advance = 6, .bitmap_offset = 12 },
    .{ .codepoint = 'G', .width = 6, .height = 8, .x_advance = 6, .bitmap_offset = 18 },
    .{ .codepoint = 'O', .width = 6, .height = 8, .x_advance = 6, .bitmap_offset = 24 },
    .{ .codepoint = 'N', .width = 6, .height = 8, .x_advance = 6, .bitmap_offset = 30 },
    .{ .codepoint = 'H', .width = 6, .height = 8, .x_advance = 6, .bitmap_offset = 36 },
    .{ .codepoint = 'P', .width = 6, .height = 8, .x_advance = 6, .bitmap_offset = 42 },
    .{ .codepoint = 'M', .width = 6, .height = 8, .x_advance = 6, .bitmap_offset = 48 },
    .{ .codepoint = '5', .width = 6, .height = 8, .x_advance = 6, .bitmap_offset = 54 },
    .{ .codepoint = '3', .width = 6, .height = 8, .x_advance = 6, .bitmap_offset = 60 },
    .{ .codepoint = '0', .width = 6, .height = 8, .x_advance = 6, .bitmap_offset = 66 },
    .{ .codepoint = '1', .width = 6, .height = 8, .x_advance = 6, .bitmap_offset = 72 },
};

pub fn glyphFor(ch: u8) ?Glyph {
    return switch (ch) {
        ' ' => glyphs[0],
        'Z' => glyphs[1],
        'I' => glyphs[2],
        'G' => glyphs[3],
        'O' => glyphs[4],
        'N' => glyphs[5],
        'H' => glyphs[6],
        'P' => glyphs[7],
        'M' => glyphs[8],
        '5' => glyphs[9],
        '3' => glyphs[10],
        '0' => glyphs[11],
        '1' => glyphs[12],
        else => null,
    };
}

// Column-major 6x8 glyphs copied from fonts.c ssd1306xled_font6x8.
pub const bitmap = [_]u8{
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // space
    0x00, 0x61, 0x51, 0x49, 0x45, 0x43, // Z
    0x00, 0x00, 0x41, 0x7f, 0x41, 0x00, // I
    0x00, 0x3e, 0x41, 0x49, 0x49, 0x7a, // G
    0x00, 0x3e, 0x41, 0x41, 0x41, 0x3e, // O
    0x00, 0x7f, 0x04, 0x08, 0x10, 0x7f, // N
    0x00, 0x7f, 0x08, 0x08, 0x08, 0x7f, // H
    0x00, 0x7f, 0x09, 0x09, 0x09, 0x06, // P
    0x00, 0x7f, 0x02, 0x0c, 0x02, 0x7f, // M
    0x00, 0x27, 0x45, 0x45, 0x45, 0x39, // 5
    0x00, 0x21, 0x41, 0x45, 0x4b, 0x31, // 3
    0x00, 0x3e, 0x51, 0x49, 0x45, 0x3e, // 0
    0x00, 0x00, 0x42, 0x7f, 0x40, 0x00, // 1
};
