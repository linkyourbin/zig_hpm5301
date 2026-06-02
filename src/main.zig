const hpm = @import("hpm5301.zig");
const I2c = @import("i2c_hw.zig");
const Ssd1306 = @import("ssd1306.zig");

const STARTUP_DELAY: u32 = 1_000_000;
const FRAME_DELAY: u32 = 8_000_000;
const LOG_DELAY: u32 = 500_000;

const APP_LOAD_ADDR: u32 = 0x80003000;
const APP_OFFSET: u32 = APP_LOAD_ADDR - 0x80001000;

const LOG_LED = hpm.Led{
    .pin = .{
        .pad = 10,
        .port = hpm.gpio_port_a,
        .pin = 10,
        .pad_ctl = hpm.pad_ctl_led,
    },
    .delay_cycles = LOG_DELAY,
};

const OLED_I2C = I2c.Bus{
    .dma_enabled = true,
};

const BootHeader = extern struct {
    tag: u8,
    version: u8,
    length: u16,
    flags: u32,
    sw_version: u16,
    fuse_version: u8,
    fw_count: u8,
    dc_block_offset: u16,
    sig_block_offset: u16,
};

const FwInfo = extern struct {
    offset: u32,
    size: u32,
    flags: u32,
    reserved0: u32,
    load_addr: u32,
    reserved1: u32,
    entry_point: u32,
    reserved2: u32,
    hash: [64]u8,
    iv: [32]u8,
};

extern var __stack_top__: u8;

export const nor_cfg_option: [4]u32 linksection(".nor_cfg_option") = .{
    0xfcf90002,
    0x00000005,
    0x00001000,
    0x00000000,
};

export const boot_header: BootHeader linksection(".boot_header") = .{
    .tag = 0xbf,
    .version = 0x10,
    .length = @sizeOf(BootHeader) + @sizeOf(FwInfo),
    .flags = 0,
    .sw_version = 0,
    .fuse_version = 0,
    .fw_count = 1,
    .dc_block_offset = 0,
    .sig_block_offset = 0,
};

export const fw_info: FwInfo linksection(".fw_info_table") = .{
    .offset = APP_OFFSET,
    .size = 0,
    .flags = 0,
    .reserved0 = 0,
    .load_addr = APP_LOAD_ADDR,
    .reserved1 = 0,
    .entry_point = APP_LOAD_ADDR,
    .reserved2 = 0,
    .hash = [_]u8{0} ** 64,
    .iv = [_]u8{0} ** 32,
};

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ .option push
        \\ .option norelax
        \\ la gp, __global_pointer$
        \\ .option pop
        \\ la sp, __stack_top__
        \\ tail zig_main
    );
}

export fn zig_main() noreturn {
    initBoard();
    LOG_LED.blink(1);

    _ = hpm.initMaxClock();
    LOG_LED.blink(2);

    runOledAt(Ssd1306.address_0, 2);
    runOledAt(Ssd1306.address_1, 3);

    while (true) {
        LOG_LED.blink(5);
    }
}

fn initBoard() void {
    hpm.enableGpioClock();
    LOG_LED.init();
    LOG_LED.blink(1);
    OLED_I2C.init();
    LOG_LED.blink(2);
    hpm.delayCycles(STARTUP_DELAY);
}

fn runOledAt(addr: u8, success_blinks: u32) void {
    const Display = Ssd1306.Display(I2c.Bus);
    const display = Display{
        .bus = OLED_I2C,
        .addr = addr,
    };

    if (!display.init()) return;

    LOG_LED.blink(success_blinks);
    display.drawTwoColorTestText();

    while (true) {
        LOG_LED.blink(1);
        hpm.delayCycles(FRAME_DELAY);
    }
}

comptime {
    if (@sizeOf(BootHeader) != 16) @compileError("BootHeader layout mismatch");
    if (@sizeOf(FwInfo) != 128) @compileError("FwInfo layout mismatch");
}
