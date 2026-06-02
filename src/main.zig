const hpm = @import("hpm5301.zig");
const Usb = @import("usb_hs.zig");
const FastGpio = @import("fast_gpio.zig");
const CmsisDap = @import("cmsis_dap.zig");

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
extern var __fast_load_start__: u8;
extern var __fast_start__: u8;
extern var __fast_end__: u8;
extern var __data_load_start__: u8;
extern var __data_start__: u8;
extern var __data_end__: u8;
extern var __bss_start__: u8;
extern var __bss_end__: u8;

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
    initRuntimeSections();
    runDapProbe();
}

fn runDapProbe() noreturn {
    hpm.enableGpioClock();
    LOG_LED.init();
    LOG_LED.blink(1);
    _ = hpm.initMaxClock();
    LOG_LED.blink(2);

    var usb = Usb.Device{};
    usb.init();
    LOG_LED.blink(3);
    usb.waitConfigured();
    LOG_LED.blink(4);

    const pins = FastGpio.LazyProbePins.init();
    var probe_swj = FastGpio.LazyProbeSwj.init(pins);
    var dap = CmsisDap.Dap(FastGpio.LazyProbeSwj).init(&probe_swj);

    while (true) {
        usb.pollSetupAndReset();
        const request_len = usb.readPacket(Usb.out_buffer[0..]);
        const response_len = dap.process(Usb.out_buffer[0..request_len], Usb.in_buffer[0..]);
        usb.writePacket(Usb.in_buffer[0..response_len]);
    }
}

fn initRuntimeSections() void {
    copySection(&__fast_load_start__, &__fast_start__, &__fast_end__);
    copySection(&__data_load_start__, &__data_start__, &__data_end__);
    zeroSection(&__bss_start__, &__bss_end__);
}

fn copySection(src_start: *u8, dst_start: *u8, dst_end: *u8) void {
    var src: [*]u8 = @ptrCast(src_start);
    var dst: [*]u8 = @ptrCast(dst_start);
    const end = @intFromPtr(dst_end);
    while (@intFromPtr(dst) < end) {
        dst[0] = src[0];
        dst += 1;
        src += 1;
    }
}

fn zeroSection(start: *u8, end_ptr: *u8) void {
    var dst: [*]u8 = @ptrCast(start);
    const end = @intFromPtr(end_ptr);
    while (@intFromPtr(dst) < end) {
        dst[0] = 0;
        dst += 1;
    }
}

comptime {
    if (@sizeOf(BootHeader) != 16) @compileError("BootHeader layout mismatch");
    if (@sizeOf(FwInfo) != 128) @compileError("FwInfo layout mismatch");
}
