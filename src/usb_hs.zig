const hpm = @import("hpm5301.zig");

pub const usb_max_packet: usize = 512;
pub const dap_packet: usize = 4096;

const USB_BASE: usize = 0xF300C000;

const REG_DEVICEADDR: usize = 0x154;
const REG_ENDPTLISTADDR: usize = 0x158;
const REG_USBCMD: usize = 0x140;
const REG_USBSTS: usize = 0x144;
const REG_USBINTR: usize = 0x148;
const REG_PORTSC1: usize = 0x184;
const REG_OTGSC: usize = 0x1A4;
const REG_USBMODE: usize = 0x1A8;
const REG_ENDPTSETUPSTAT: usize = 0x1AC;
const REG_ENDPTPRIME: usize = 0x1B0;
const REG_ENDPTFLUSH: usize = 0x1B4;
const REG_ENDPTSTAT: usize = 0x1B8;
const REG_ENDPTCOMPLETE: usize = 0x1BC;
const REG_ENDPTCTRL: usize = 0x1C0;
const REG_ENDPTNAK: usize = 0x178;
const REG_ENDPTNAKEN: usize = 0x17C;
const REG_OTG_CTRL0: usize = 0x200;
const REG_PHY_CTRL0: usize = 0x210;
const REG_PHY_CTRL1: usize = 0x214;
const REG_PHY_STATUS: usize = 0x224;

const USBCMD_RS: u32 = 1 << 0;
const USBCMD_RST: u32 = 1 << 1;
const USBCMD_ITC_MASK: u32 = 0xff << 16;

const USBSTS_UI: u32 = 1 << 0;
const USBSTS_PCI: u32 = 1 << 2;
const USBSTS_URI: u32 = 1 << 6;
const USBSTS_SLI: u32 = 1 << 8;

const USBINTR_UE: u32 = 1 << 0;
const USBINTR_UEE: u32 = 1 << 1;
const USBINTR_PCE: u32 = 1 << 2;
const USBINTR_URE: u32 = 1 << 6;
const USBINTR_SLE: u32 = 1 << 8;

const USBMODE_CM_DEVICE: u32 = 0b10;
const USBMODE_ES: u32 = 1 << 2;
const USBMODE_SLOM: u32 = 1 << 3;

const PORTSC1_PFSC: u32 = 1 << 24;
const PORTSC1_PTW: u32 = 1 << 28;
const PORTSC1_STS: u32 = 1 << 29;

const OTGSC_VD: u32 = 1 << 0;
const OTG_CTRL0_POWER_MASK: u32 = 1 << 9;
const OTG_CTRL0_UTMI_RESET_SW: u32 = 1 << 11;
const OTG_CTRL0_UTMI_SUSPENDM_SW: u32 = 1 << 12;
const OTG_CTRL0_WKDPDMCHG_EN: u32 = 1 << 25;

const PHY_CTRL0_DP_DM_PULLDOWN_BITS: u32 = 0x0010_00e0;
const PHY_CTRL0_VBUS_VALID_OVERRIDE_EN: u32 = 1 << 0;
const PHY_CTRL0_SESS_VALID_OVERRIDE_EN: u32 = 1 << 1;
const PHY_CTRL0_VBUS_VALID_OVERRIDE: u32 = 1 << 12;
const PHY_CTRL0_SESS_VALID_OVERRIDE: u32 = 1 << 13;
const PHY_CTRL1_UTMI_OTG_SUSPENDM: u32 = 1 << 1;
const PHY_CTRL1_UTMI_CFG_RST_N: u32 = 1 << 20;
const PHY_STATUS_UTMI_CLK_VALID: u32 = 1 << 31;

const ENDPTCTRL_RXS: u32 = 1 << 0;
const ENDPTCTRL_RXT_MASK: u32 = 0b11 << 2;
const ENDPTCTRL_RXR: u32 = 1 << 6;
const ENDPTCTRL_RXE: u32 = 1 << 7;
const ENDPTCTRL_TXS: u32 = 1 << 16;
const ENDPTCTRL_TXT_MASK: u32 = 0b11 << 18;
const ENDPTCTRL_TXR: u32 = 1 << 22;
const ENDPTCTRL_TXE: u32 = 1 << 23;
const EP_TYPE_CONTROL: u32 = 0;
const EP_TYPE_BULK: u32 = 2;

const endpoint_count: usize = 16;
const qhd_words: usize = 16;
const qtd_words: usize = 8;

const vendor_code_ms20: u8 = 0x20;

var qhd_list: [endpoint_count * 2][qhd_words]u32 align(2048) linksection(".noncacheable") = undefined;
var qtd_list: [endpoint_count * 2][qtd_words]u32 align(32) linksection(".noncacheable") = undefined;

pub var out_buffer: [dap_packet]u8 align(32) linksection(".noncacheable") = undefined;
pub var in_buffer: [dap_packet]u8 align(32) linksection(".noncacheable") = undefined;

pub const Device = struct {
    configured: bool = false,

    pub fn init(self: *Device) void {
        self.configured = false;
        hpm.enableUsb0Clock();
        hpm.initUsb0PinsPa24Pa25();
        clearEndpointState();

        regModify(REG_PHY_CTRL0, struct {
            fn f(v: u32) u32 {
                return v | PHY_CTRL0_DP_DM_PULLDOWN_BITS;
            }
        }.f);
        regModify(REG_OTG_CTRL0, struct {
            fn f(v: u32) u32 {
                return v | OTG_CTRL0_POWER_MASK;
            }
        }.f);
        hpm.delayCycles(3_600_000);
        regModify(REG_PHY_CTRL0, struct {
            fn f(v: u32) u32 {
                return v | PHY_CTRL0_VBUS_VALID_OVERRIDE |
                    PHY_CTRL0_SESS_VALID_OVERRIDE |
                    PHY_CTRL0_VBUS_VALID_OVERRIDE_EN |
                    PHY_CTRL0_SESS_VALID_OVERRIDE_EN;
            }
        }.f);

        self.deviceInit();
        regWrite(REG_ENDPTLISTADDR, @intFromPtr(&qhd_list));
        regWrite(REG_USBSTS, regRead(REG_USBSTS));
        regWrite(REG_USBINTR, USBINTR_UE | USBINTR_UEE | USBINTR_PCE | USBINTR_URE | USBINTR_SLE);
        regModify(REG_OTGSC, struct {
            fn f(v: u32) u32 {
                return v | OTGSC_VD;
            }
        }.f);
        regModify(REG_USBCMD, struct {
            fn f(v: u32) u32 {
                return v | USBCMD_RS;
            }
        }.f);
    }

    pub fn pollSetupAndReset(self: *Device) void {
        const status = regRead(REG_USBSTS);
        if ((status & USBSTS_URI) != 0) {
            regWrite(REG_USBSTS, USBSTS_URI);
            self.busReset();
        }
        if ((regRead(REG_ENDPTSETUPSTAT) & 1) != 0) {
            self.handleSetup();
        }
        if ((status & (USBSTS_UI | USBSTS_PCI | USBSTS_SLI)) != 0) {
            regWrite(REG_USBSTS, status & (USBSTS_UI | USBSTS_PCI | USBSTS_SLI));
        }
    }

    pub fn readPacket(self: *Device, buf: []u8) usize {
        while (true) {
            self.waitConfigured();
            const len = transferOutWithControl(self, 2, buf);
            if (self.configured) return len;
        }
    }

    pub fn writePacket(self: *Device, data: []const u8) void {
        self.waitConfigured();
        transferIn(1, data);
        if (data.len > usb_max_packet and data.len % usb_max_packet == 0) transferIn(1, data[0..0]);
    }

    pub fn waitConfigured(self: *Device) void {
        while (!self.configured) self.pollSetupAndReset();
    }

    fn deviceInit(_: *Device) void {
        phyInit();
        regModify(REG_USBCMD, struct {
            fn f(v: u32) u32 {
                return v | USBCMD_RST;
            }
        }.f);
        while ((regRead(REG_USBCMD) & USBCMD_RST) != 0) {}

        regModify(REG_USBMODE, struct {
            fn f(v: u32) u32 {
                return (v & ~@as(u32, 0b11)) | USBMODE_CM_DEVICE;
            }
        }.f);
        regModify(REG_USBMODE, struct {
            fn f(v: u32) u32 {
                return (v & ~(USBMODE_ES | USBMODE_SLOM)) | USBMODE_CM_DEVICE;
            }
        }.f);
        regModify(REG_PORTSC1, struct {
            fn f(v: u32) u32 {
                return v & ~(PORTSC1_STS | PORTSC1_PTW | PORTSC1_PFSC);
            }
        }.f);
        regModify(REG_USBCMD, struct {
            fn f(v: u32) u32 {
                return v & ~USBCMD_ITC_MASK;
            }
        }.f);
    }

    fn busReset(self: *Device) void {
        self.configured = false;
        var i: usize = 1;
        while (i < endpoint_count) : (i += 1) {
            regWrite(REG_ENDPTCTRL + i * 4, (EP_TYPE_BULK << 18) | (EP_TYPE_BULK << 2));
        }

        regWrite(REG_ENDPTNAK, regRead(REG_ENDPTNAK));
        regWrite(REG_ENDPTNAKEN, 0);
        regWrite(REG_USBSTS, regRead(REG_USBSTS));
        regWrite(REG_ENDPTSETUPSTAT, regRead(REG_ENDPTSETUPSTAT));
        regWrite(REG_ENDPTCOMPLETE, regRead(REG_ENDPTCOMPLETE));

        while (regRead(REG_ENDPTPRIME) != 0) {}
        regWrite(REG_ENDPTFLUSH, 0xffff_ffff);
        while (regRead(REG_ENDPTFLUSH) != 0) {}

        clearEndpointState();
        initQhd(0, 64, EP_TYPE_CONTROL);
        initQhd(1, 64, EP_TYPE_CONTROL);
        openEndpoint(0, false, EP_TYPE_CONTROL, 64);
        openEndpoint(0, true, EP_TYPE_CONTROL, 64);
        regWrite(REG_DEVICEADDR, 0);
    }

    fn handleSetup(self: *Device) void {
        regWrite(REG_ENDPTSETUPSTAT, 1);
        const setup = setupPacket();
        const req_type = setup[0];
        const req = setup[1];
        const value = readLe16(setup[2..4]);
        const index = readLe16(setup[4..6]);
        const length = readLe16(setup[6..8]);

        if ((req_type & 0x60) == 0x00) {
            switch (req) {
                0x00 => controlIn(zero2[0..@min(length, 2)]),
                0x05 => {
                    regWrite(REG_DEVICEADDR, (@as(u32, value & 0x7f) << 25) | (1 << 24));
                    statusIn();
                },
                0x06 => self.getDescriptor(value, length),
                0x08 => controlIn(config_value[0..@min(length, 1)]),
                0x09 => {
                    self.configured = (value & 0xff) != 0;
                    if (self.configured) {
                        openEndpoint(2, false, EP_TYPE_BULK, usb_max_packet);
                        openEndpoint(1, true, EP_TYPE_BULK, usb_max_packet);
                    }
                    statusIn();
                },
                else => stallEp0(),
            }
            return;
        }

        if ((req_type & 0x60) == 0x40 and req == vendor_code_ms20) {
            if (index == 7) {
                controlIn(ms_os_20_descriptor[0..@min(length, ms_os_20_descriptor.len)]);
                return;
            }
            if (index == 4) {
                controlIn(ms_os_10_compat_id_descriptor[0..@min(length, ms_os_10_compat_id_descriptor.len)]);
                return;
            }
        }

        stallEp0();
    }

    fn getDescriptor(_: *Device, value: u16, length: u16) void {
        const desc_type: u8 = @intCast(value >> 8);
        const desc_index: u8 = @intCast(value & 0xff);
        switch (desc_type) {
            1 => controlIn(device_descriptor[0..@min(length, device_descriptor.len)]),
            2 => controlIn(config_descriptor[0..@min(length, config_descriptor.len)]),
            3 => {
                const desc = stringDescriptor(desc_index) orelse {
                    stallEp0();
                    return;
                };
                controlIn(desc[0..@min(length, desc.len)]);
            },
            15 => controlIn(bos_descriptor[0..@min(length, bos_descriptor.len)]),
            else => stallEp0(),
        }
    }
};

fn phyInit() void {
    regModify(REG_PHY_CTRL0, struct {
        fn f(v: u32) u32 {
            return v & ~PHY_CTRL0_DP_DM_PULLDOWN_BITS;
        }
    }.f);
    regModify(REG_OTG_CTRL0, struct {
        fn f(v: u32) u32 {
            return (v | OTG_CTRL0_UTMI_RESET_SW) & ~OTG_CTRL0_UTMI_SUSPENDM_SW;
        }
    }.f);
    regModify(REG_PHY_CTRL1, struct {
        fn f(v: u32) u32 {
            return v & ~PHY_CTRL1_UTMI_CFG_RST_N;
        }
    }.f);
    while ((regRead(REG_OTG_CTRL0) & OTG_CTRL0_UTMI_RESET_SW) == 0) {}
    regModify(REG_OTG_CTRL0, struct {
        fn f(v: u32) u32 {
            return v | OTG_CTRL0_UTMI_SUSPENDM_SW;
        }
    }.f);
    hpm.delayCycles(1800);
    regModify(REG_OTG_CTRL0, struct {
        fn f(v: u32) u32 {
            return (v & ~OTG_CTRL0_WKDPDMCHG_EN) & ~OTG_CTRL0_UTMI_RESET_SW;
        }
    }.f);
    regModify(REG_PHY_STATUS, struct {
        fn f(v: u32) u32 {
            return v | PHY_STATUS_UTMI_CLK_VALID;
        }
    }.f);
    while ((regRead(REG_PHY_STATUS) & PHY_STATUS_UTMI_CLK_VALID) == 0) {}
    regModify(REG_PHY_CTRL1, struct {
        fn f(v: u32) u32 {
            return v | PHY_CTRL1_UTMI_CFG_RST_N | PHY_CTRL1_UTMI_OTG_SUSPENDM;
        }
    }.f);
}

fn clearEndpointState() void {
    for (&qhd_list) |*qhd| {
        for (qhd) |*word| word.* = 0;
    }
    for (&qtd_list) |*qtd| {
        for (qtd) |*word| word.* = 0;
    }
}

fn epIndex(ep: usize, in_dir: bool) usize {
    return 2 * ep + if (in_dir) @as(usize, 1) else 0;
}

fn initQhd(index: usize, mps: usize, ep_type: u32) void {
    _ = ep_type;
    const cap = (@as(u32, @intCast(mps & 0x07ff)) << 16) | (1 << 29);
    qhd_list[index][0] = cap;
    qhd_list[index][2] = 1;
}

fn openEndpoint(ep: usize, in_dir: bool, ep_type: u32, mps: usize) void {
    initQhd(epIndex(ep, in_dir), mps, ep_type);
    const reg = REG_ENDPTCTRL + ep * 4;
    if (in_dir) {
        const value = (regRead(reg) & ~ENDPTCTRL_TXT_MASK) | ENDPTCTRL_TXE | ENDPTCTRL_TXR | (ep_type << 18);
        regWrite(reg, value);
    } else {
        const value = (regRead(reg) & ~ENDPTCTRL_RXT_MASK) | ENDPTCTRL_RXE | ENDPTCTRL_RXR | (ep_type << 2);
        regWrite(reg, value);
    }
}

fn controlIn(data: []const u8) void {
    if (data.len > in_buffer.len) {
        stallEp0();
        return;
    }
    for (data, 0..) |byte, i| in_buffer[i] = byte;
    transferIn(0, in_buffer[0..data.len]);
    _ = transfer(0, false, out_buffer[0..0]);
}

fn statusIn() void {
    transferIn(0, in_buffer[0..0]);
}

fn transferIn(ep: usize, data: []const u8) void {
    _ = transfer(ep, true, @constCast(data));
}

fn transfer(ep: usize, in_dir: bool, data: []u8) usize {
    const idx = epIndex(ep, in_dir);
    prepareQtd(idx, data);
    qhd_list[idx][2] = @intFromPtr(&qtd_list[idx]) & ~@as(u32, 0x1f);

    const bit = @as(u32, 1) << @intCast(ep);
    regWrite(REG_ENDPTPRIME, if (in_dir) bit << 16 else bit);
    const complete_bit = if (in_dir) bit << 16 else bit;
    while ((regRead(REG_ENDPTCOMPLETE) & complete_bit) == 0) {}
    regWrite(REG_ENDPTCOMPLETE, complete_bit);
    const remaining = (qhd_list[idx][3] >> 16) & 0x7fff;
    return data.len - @as(usize, @intCast(remaining));
}

fn transferOutWithControl(device: *Device, ep: usize, data: []u8) usize {
    const idx = epIndex(ep, false);
    prepareQtd(idx, data);
    qhd_list[idx][2] = @intFromPtr(&qtd_list[idx]) & ~@as(u32, 0x1f);

    const bit = @as(u32, 1) << @intCast(ep);
    regWrite(REG_ENDPTPRIME, bit);
    while ((regRead(REG_ENDPTCOMPLETE) & bit) == 0) {
        device.pollSetupAndReset();
        if (!device.configured) return 0;
    }
    regWrite(REG_ENDPTCOMPLETE, bit);
    const remaining = (qhd_list[idx][3] >> 16) & 0x7fff;
    return data.len - @as(usize, @intCast(remaining));
}

fn prepareQtd(idx: usize, data: []u8) void {
    for (&qtd_list[idx]) |*word| word.* = 0;
    const len: u32 = @intCast(data.len);
    qtd_list[idx][0] = 1;
    qtd_list[idx][1] = (len << 16) | (1 << 15) | (1 << 7);
    if (data.len != 0) {
        const addr: u32 = @intFromPtr(data.ptr);
        qtd_list[idx][2] = addr;
        var i: usize = 1;
        while (i < 5) : (i += 1) {
            qtd_list[idx][2 + i] = (addr & 0xffff_f000) + (@as(u32, @intCast(i)) << 12);
        }
    }
}

fn setupPacket() [8]u8 {
    const word0 = qhd_list[0][10];
    const word1 = qhd_list[0][11];
    return .{
        @intCast(word0 & 0xff),
        @intCast((word0 >> 8) & 0xff),
        @intCast((word0 >> 16) & 0xff),
        @intCast((word0 >> 24) & 0xff),
        @intCast(word1 & 0xff),
        @intCast((word1 >> 8) & 0xff),
        @intCast((word1 >> 16) & 0xff),
        @intCast((word1 >> 24) & 0xff),
    };
}

fn stallEp0() void {
    regModify(REG_ENDPTCTRL, struct {
        fn f(v: u32) u32 {
            return v | ENDPTCTRL_TXS | ENDPTCTRL_RXS;
        }
    }.f);
}

fn readLe16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn regRead(offset: usize) u32 {
    return @as(*volatile u32, @ptrFromInt(USB_BASE + offset)).*;
}

fn regWrite(offset: usize, value: u32) void {
    @as(*volatile u32, @ptrFromInt(USB_BASE + offset)).* = value;
}

fn regModify(offset: usize, f: fn (u32) u32) void {
    regWrite(offset, f(regRead(offset)));
}

const zero2 = [_]u8{ 0, 0 };
const config_value = [_]u8{1};
const ms_os_20_total_length: u16 = 198;

const device_descriptor = [_]u8{
    18, 1, 0x10, 0x02, 0xef, 0x02, 0x01, 64,
    0x09, 0x12, 0x01, 0x53, 0x15, 0x00, 1, 2, 3, 1,
};

const config_descriptor = [_]u8{
    9, 2, 41, 0, 2, 1, 0, 0x80, 50,
    9, 4, 0, 0, 2, 0xff, 0x00, 0x00, 4,
    7, 5, 0x02, 2, 0x00, 0x02, 0,
    7, 5, 0x81, 2, 0x00, 0x02, 0,
    9, 4, 1, 0, 0, 0xff, 0x00, 0x00, 5,
};

const bos_descriptor = [_]u8{
    5, 15, 33, 0, 1,
    28, 16, 5, 0,
    0xdf, 0x60, 0xdd, 0xd8, 0x89, 0x45, 0xc7, 0x4c,
    0x9c, 0xd2, 0x65, 0x9d, 0x9e, 0x64, 0x8a, 0x9f,
    0x00, 0x00, 0x03, 0x06,
    lo(ms_os_20_total_length), hi(ms_os_20_total_length), vendor_code_ms20, 0,
};

const string0 = [_]u8{ 4, 3, 0x09, 0x04 };
const string1 = utf16String("YBLINK");
const string2 = utf16String("YBLINK CMSIS-DAP");
const string3 = utf16String("YBLINK-ZIG-0057-DATA6");
const string4 = utf16String("YBLINK CMSIS-DAP");
const string5 = utf16String("YBLINK Auxiliary Interface");
const string_msft100 = [_]u8{
    18, 3,
    'M', 0, 'S', 0, 'F', 0, 'T', 0, '1', 0, '0', 0, '0', 0,
    vendor_code_ms20, 0,
};

fn stringDescriptor(index: u8) ?[]const u8 {
    return switch (index) {
        0 => string0[0..],
        1 => string1[0..],
        2 => string2[0..],
        3 => string3[0..],
        4 => string4[0..],
        5 => string5[0..],
        0xee => string_msft100[0..],
        else => null,
    };
}

fn utf16String(comptime s: []const u8) [2 + s.len * 2]u8 {
    var out: [2 + s.len * 2]u8 = undefined;
    out[0] = out.len;
    out[1] = 3;
    for (s, 0..) |ch, i| {
        out[2 + i * 2] = ch;
        out[3 + i * 2] = 0;
    }
    return out;
}

const ms_os_20_descriptor = [_]u8{
    10, 0, 0, 0, 0x00, 0x00, 0x03, 0x06,
    lo(ms_os_20_total_length), hi(ms_os_20_total_length),
    8, 0, 2, 0, 0, 0, 160, 0,
    20, 0, 3, 0,
    'W', 'I', 'N', 'U', 'S', 'B', 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    132, 0, 4, 0, 7, 0, 42, 0,
    'D', 0, 'e', 0, 'v', 0, 'i', 0, 'c', 0, 'e', 0,
    'I', 0, 'n', 0, 't', 0, 'e', 0, 'r', 0, 'f', 0,
    'a', 0, 'c', 0, 'e', 0, 'G', 0, 'U', 0, 'I', 0,
    'D', 0, 's', 0, 0, 0,
    80, 0,
    '{', 0,
    'C', 0, 'D', 0, 'B', 0, '3', 0, 'B', 0, '5', 0, 'A', 0, 'D', 0, '-', 0,
    '2', 0, '9', 0, '3', 0, 'B', 0, '-', 0,
    '4', 0, '6', 0, '6', 0, '3', 0, '-', 0,
    'A', 0, 'A', 0, '3', 0, '6', 0, '-',
    0, '1', 0, 'A', 0, 'A', 0, 'E', 0, '4', 0, '6', 0, '4', 0, '6', 0, '3', 0,
    '7', 0, '7', 0, '6', 0,
    '}', 0, 0, 0, 0, 0,
    8, 0, 2, 0, 1, 0, 28, 0,
    20, 0, 3, 0,
    'W', 'I', 'N', 'U', 'S', 'B', 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
};

const ms_os_10_compat_id_descriptor = [_]u8{
    64, 0, 0, 0,
    0x00, 0x01,
    0x04, 0x00,
    2,
    0, 0, 0, 0, 0, 0, 0,
    0,
    0,
    'W', 'I', 'N', 'U', 'S', 'B', 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0,
    1,
    0,
    'W', 'I', 'N', 'U', 'S', 'B', 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0,
};

fn lo(value: u16) u8 {
    return @intCast(value & 0xff);
}

fn hi(value: u16) u8 {
    return @intCast((value >> 8) & 0xff);
}

fn le16Bytes(comptime value: u16) [2]u8 {
    return .{ lo(value), hi(value) };
}

comptime {
    if (ms_os_20_descriptor.len != ms_os_20_total_length) {
        @compileError("MS OS 2.0 descriptor length mismatch");
    }
}
