const Font = @import("font6x8.zig");
const I2c = @import("i2c_bitbang.zig");

pub const width: u16 = 128;
pub const pages: u8 = 8;
pub const address_0: u8 = 0x3c;
pub const address_1: u8 = 0x3d;

pub const Display = struct {
    bus: I2c.Bus,
    addr: u8,

    pub fn init(self: Display) bool {
        const init_commands = [_]u8{
            0xae, // display off
            0xd5, 0x80, // clock divide
            0xa8, 0x3f, // multiplex 1/64
            0xd3, 0x00, // display offset
            0x40, // start line 0
            0x8d, 0x14, // charge pump on
            0x20, 0x00, // horizontal addressing
            0xa1, // segment remap
            0xc8, // COM scan decrement
            0xda, 0x12, // COM pins
            0x81, 0xcf, // contrast
            0xd9, 0xf1, // pre-charge
            0xdb, 0x40, // VCOMH
            0xa4, // resume RAM display
            0xa6, // normal display
            0x2e, // deactivate scroll
            0xaf, // display on
        };

        const ok = self.commands(init_commands[0..]);
        if (ok) {
            self.fill(0x00);
        }
        return ok;
    }

    pub fn command(self: Display, byte: u8) bool {
        return self.commands(&[_]u8{byte});
    }

    pub fn commands(self: Display, bytes: []const u8) bool {
        return self.bus.writeRegisterBytes(self.addr, 0x00, bytes);
    }

    pub fn fill(self: Display, pattern: u8) void {
        self.setFullWindow();
        self.bus.start();
        _ = self.bus.writeByte(self.addr << 1);
        _ = self.bus.writeByte(0x40);

        var page: u8 = 0;
        while (page < pages) : (page += 1) {
            var col: u16 = 0;
            while (col < width) : (col += 1) {
                _ = self.bus.writeByte(pattern);
            }
        }

        self.bus.stop();
    }

    pub fn drawTwoColorTestText(self: Display) void {
        const line1 = "ZIG ON";
        const line2 = "HPM5301";
        const scale: u16 = 2;

        self.drawTextFrame(
            line1,
            centerX(line1, scale),
            0,
            line2,
            centerX(line2, scale),
            32,
            scale,
        );
    }

    pub fn drawTextFrame(
        self: Display,
        line1: []const u8,
        line1_x: u16,
        line1_y: u16,
        line2: []const u8,
        line2_x: u16,
        line2_y: u16,
        scale: u16,
    ) void {
        self.setFullWindow();
        self.bus.start();
        _ = self.bus.writeByte(self.addr << 1);
        _ = self.bus.writeByte(0x40);

        var page: u16 = 0;
        while (page < pages) : (page += 1) {
            var x: u16 = 0;
            while (x < width) : (x += 1) {
                var value: u8 = 0;
                var bit: u8 = 0;
                while (bit < 8) : (bit += 1) {
                    const y = page * 8 + bit;
                    if (twoColorLayoutPixel(x, y) or
                        textPixel(x, y, line1, line1_x, line1_y, scale) or
                        textPixel(x, y, line2, line2_x, line2_y, scale))
                    {
                        value |= @as(u8, 1) << @as(u3, @intCast(bit));
                    }
                }
                _ = self.bus.writeByte(value);
            }
        }

        self.bus.stop();
    }

    fn setFullWindow(self: Display) void {
        _ = self.commands(&[_]u8{
            0x21, 0x00, 0x7f, // column 0..127
            0x22, 0x00, 0x07, // page 0..7
        });
    }
};

fn twoColorLayoutPixel(x: u16, y: u16) bool {
    if (y == 17) return x >= 8 and x < 120;
    if (y == 30) return x >= 18 and x < 110;
    if (y == 50) return x >= 18 and x < 110;
    return false;
}

fn textPixel(x: u16, y: u16, text: []const u8, origin_x: u16, origin_y: u16, scale: u16) bool {
    if (x < origin_x or y < origin_y) return false;

    const rel_x = x - origin_x;
    const rel_y = y - origin_y;
    const font_x = rel_x / scale;
    const font_y = rel_y / scale;
    if (font_y >= Font.height) return false;

    const glyph_index = font_x / Font.cell_width;
    const glyph_col = font_x % Font.cell_width;
    if (glyph_col >= Font.width) return false;

    var index: u16 = 0;
    for (text) |ch| {
        if (index == glyph_index) {
            if (Font.glyphFor(ch)) |glyph| {
                const column = Font.bitmap[glyph.bitmap_offset + glyph_col];
                return (column & (@as(u8, 1) << @as(u3, @intCast(font_y)))) != 0;
            }
            return false;
        }
        index += 1;
    }

    return false;
}

fn centerX(text: []const u8, scale: u16) u16 {
    var chars: u16 = 0;
    for (text) |_| {
        chars += 1;
    }

    const text_width = chars * Font.cell_width * scale;
    if (text_width >= width) return 0;
    return (width - text_width) / 2;
}
