const hpm = @import("hpm5301.zig");

const I2C2_BASE: usize = 0xF0068000;
const DMAMUX_BASE: usize = 0xF00C4000;
const HDMA_BASE: usize = 0xF00C8000;

const I2C_SOURCE_HZ: u32 = 24_000_000;
const I2C_TRANSFER_MAX: u32 = 4096;
const DMA_CHANNEL: usize = 0;
const DMA_MASK: u32 = 1 << DMA_CHANNEL;
const DMAMUX_SRC_I2C2: u32 = 0x26;
const RETRY_LIMIT: u32 = 2_000_000;

const status_fifo_empty: u32 = 0x0001;
const status_fifo_full: u32 = 0x0002;
const status_addr_hit: u32 = 0x0008;
const status_cmpl: u32 = 0x0200;
const status_bus_busy: u32 = 0x0800;

const ctrl_phase_start: u32 = 0x1000;
const ctrl_phase_addr: u32 = 0x0800;
const ctrl_phase_data: u32 = 0x0400;
const ctrl_phase_stop: u32 = 0x0200;

const cmd_issue_transfer: u32 = 1;
const cmd_clear_fifo: u32 = 4;
const cmd_reset: u32 = 5;

const setup_t_sudat_shift: u5 = 24;
const setup_t_sp_shift: u5 = 21;
const setup_t_hddat_shift: u5 = 16;
const setup_t_sclratio_shift: u5 = 13;
const setup_t_sclhi_shift: u5 = 4;
const setup_dmaen: u32 = 0x08;
const setup_master: u32 = 0x04;
const setup_iicen: u32 = 0x01;

pub const Bus = struct {
    dma_enabled: bool = true,

    pub fn init(self: Bus) void {
        _ = self;
        hpm.enableI2c2Clock();
        hpm.enableHdmaClock();
        hpm.initI2c2PinsPb08Pb09();

        const port = i2c();
        port.ctrl = 0;
        port.cmd = cmd_reset;
        port.setup &= ~setup_iicen;
        port.cmd = cmd_clear_fifo;
        port.status = 0xffff;

        configureTimingFast(port);
        configureDmamux();
    }

    pub fn writeRegisterBytes(self: Bus, addr: u8, control: u8, bytes: []const u8) bool {
        var header_and_payload = FrameWriter.begin(control);
        if (bytes.len > header_and_payload.capacity()) return false;

        header_and_payload.appendSlice(bytes);
        return self.writeBytes(addr, header_and_payload.slice());
    }

    pub fn writeBytes(self: Bus, addr: u8, bytes: []const u8) bool {
        if (bytes.len == 0 or bytes.len > I2C_TRANSFER_MAX) return false;
        if (self.dma_enabled and bytes.len >= 64) {
            if (writeDma(addr, bytes)) return true;
        }
        return writePolling(addr, bytes);
    }
};

const FrameWriter = struct {
    buffer: *[I2C_TRANSFER_MAX]u8,
    len: usize,

    fn begin(control: u8) FrameWriter {
        frame_buffer[0] = control;
        return .{
            .buffer = &frame_buffer,
            .len = 1,
        };
    }

    fn capacity(self: FrameWriter) usize {
        return self.buffer.len - self.len;
    }

    fn appendSlice(self: *FrameWriter, bytes: []const u8) void {
        for (bytes) |byte| {
            self.buffer[self.len] = byte;
            self.len += 1;
        }
    }

    fn slice(self: FrameWriter) []const u8 {
        return self.buffer[0..self.len];
    }
};

var frame_buffer: [I2C_TRANSFER_MAX]u8 align(32) = [_]u8{0} ** I2C_TRANSFER_MAX;

fn writePolling(addr: u8, bytes: []const u8) bool {
    const port = i2c();
    if (!startWrite(port, addr, bytes.len, false)) return false;

    var index: usize = 0;
    var retry: u32 = 0;
    while (index < bytes.len) {
        if ((port.status & status_fifo_full) == 0) {
            port.data = bytes[index];
            index += 1;
            retry = 0;
        } else {
            retry += 1;
            if (retry > RETRY_LIMIT) return false;
        }
    }

    return finishWrite(port);
}

fn writeDma(addr: u8, bytes: []const u8) bool {
    const port = i2c();
    const controller = hdma();
    const ch = &controller.chctrl[DMA_CHANNEL];

    ch.ctrl &= ~@as(u32, 1);
    controller.inttcsts = DMA_MASK;
    controller.intabortsts = DMA_MASK;
    controller.interrsts = DMA_MASK;
    controller.inthalfsts = DMA_MASK;

    ch.srcaddr = @intFromPtr(bytes.ptr);
    ch.dstaddr = I2C2_BASE + @offsetOf(I2c, "data");
    ch.transize = @intCast(bytes.len);
    ch.llpointer = 0;
    ch.chanreqctrl = (@as(u32, DMA_CHANNEL) << 24) | (@as(u32, DMA_CHANNEL) << 16);
    ch.ctrl = dmaCtrl(true);

    if (!startWrite(port, addr, bytes.len, true)) {
        port.setup &= ~setup_dmaen;
        ch.ctrl &= ~@as(u32, 1);
        return false;
    }

    if (!waitDmaDone(controller)) {
        port.setup &= ~setup_dmaen;
        ch.ctrl &= ~@as(u32, 1);
        return false;
    }

    port.setup &= ~setup_dmaen;
    return finishWrite(port);
}

fn startWrite(port: *volatile I2c, addr: u8, len: usize, use_dma: bool) bool {
    if (!waitClear(&port.status, status_bus_busy)) return false;

    port.status = status_cmpl;
    port.cmd = cmd_clear_fifo;
    port.addr = addr;
    port.ctrl =
        ctrl_phase_start |
        ctrl_phase_stop |
        ctrl_phase_addr |
        ctrl_phase_data |
        dataCount(@intCast(len));

    if (use_dma) port.setup |= setup_dmaen;
    port.cmd = cmd_issue_transfer;

    if (!waitSet(&port.status, status_addr_hit)) return false;
    port.status = status_addr_hit;
    return true;
}

fn finishWrite(port: *volatile I2c) bool {
    if (!waitSet(&port.status, status_cmpl)) return false;
    port.status = status_cmpl;
    return (dataCountLeft(port) == 0);
}

fn configureTimingFast(port: *volatile I2c) void {
    const timing = fastModeTiming(I2C_SOURCE_HZ);
    port.tpm = 0;
    port.setup =
        (timing.t_sudat << setup_t_sudat_shift) |
        (timing.t_sp << setup_t_sp_shift) |
        (timing.t_hddat << setup_t_hddat_shift) |
        ((timing.t_sclratio - 1) << setup_t_sclratio_shift) |
        (timing.t_sclhi << setup_t_sclhi_shift) |
        setup_master |
        setup_iicen;
}

fn fastModeTiming(src_hz: u32) Timing {
    const tpclk = @as(i32, @intCast(@as(u64, 10_000_000_000) / src_hz));
    const t_high: i32 = 6000;
    const t_low: i32 = 13000;
    const t_sclratio: i32 = 2;
    const setup_time: i32 = 1000;
    const hold_time: i32 = 3000;
    const period: i32 = @intCast(@as(u64, 10_000_000_000) / 400_000);
    const t_sp = divFloor(500, tpclk);
    const t_sudat = max0(divFloor(setup_time - 2 * tpclk, tpclk) - 2 - t_sp);
    const t_hddat = max0(divFloor(hold_time - 2 * tpclk, tpclk) - 2 - t_sp);
    const t1 = divFloor(t_high - 2 * tpclk, tpclk) - 2 - t_sp;
    const t2 = divFloor(divFloor(period, 1 + t_sclratio) - 2 * tpclk, tpclk) - 2 - t_sp;
    const t3 = divFloor(divFloor(t_low - 2 * tpclk, tpclk) - 2 - t_sp, t_sclratio);
    const t_sclhi = max3(t1, t2, t3);

    return .{
        .t_sp = @intCast(max0(t_sp)),
        .t_sudat = @intCast(t_sudat),
        .t_hddat = @intCast(t_hddat),
        .t_sclratio = @intCast(t_sclratio),
        .t_sclhi = @intCast(t_sclhi),
    };
}

fn configureDmamux() void {
    dmamux().muxcfg[DMA_CHANNEL] = 0x8000_0000 | DMAMUX_SRC_I2C2;
}

fn waitDmaDone(controller: *volatile Dma) bool {
    var retry: u32 = 0;
    while (true) {
        if ((controller.inttcsts & DMA_MASK) != 0) {
            controller.inttcsts = DMA_MASK;
            return true;
        }
        if ((controller.intabortsts & DMA_MASK) != 0 or (controller.interrsts & DMA_MASK) != 0) {
            controller.intabortsts = DMA_MASK;
            controller.interrsts = DMA_MASK;
            return false;
        }
        retry += 1;
        if (retry > RETRY_LIMIT * 4) return false;
    }
}

fn waitSet(reg: *volatile u32, mask: u32) bool {
    var retry: u32 = 0;
    while ((reg.* & mask) == 0) {
        retry += 1;
        if (retry > RETRY_LIMIT) return false;
    }
    return true;
}

fn waitClear(reg: *volatile u32, mask: u32) bool {
    var retry: u32 = 0;
    while ((reg.* & mask) != 0) {
        retry += 1;
        if (retry > RETRY_LIMIT) return false;
    }
    return true;
}

fn dataCount(len: u32) u32 {
    const mapped = if (len == I2C_TRANSFER_MAX) 0 else len;
    return ((mapped >> 8) << 24) | (mapped & 0xff);
}

fn dataCountLeft(port: *volatile I2c) u32 {
    const count_low = port.ctrl & 0xff;
    const count_high = (port.ctrl >> 24) & 0xff;
    return (count_high << 8) | count_low;
}

fn dmaCtrl(start: bool) u32 {
    const priority: u32 = 0;
    const src_burst_size: u32 = 0;
    const src_width: u32 = 0;
    const dst_width: u32 = 0;
    const dst_mode_handshake: u32 = 1;
    const src_addr_inc: u32 = 0;
    const dst_addr_fixed: u32 = 2;
    const interrupt_mask_half: u32 = 1 << 4;
    const enable: u32 = if (start) 1 else 0;

    return (priority << 29) |
        (src_burst_size << 24) |
        (src_width << 21) |
        (dst_width << 18) |
        (dst_mode_handshake << 16) |
        (src_addr_inc << 14) |
        (dst_addr_fixed << 12) |
        interrupt_mask_half |
        enable;
}

fn divFloor(a: i32, b: i32) i32 {
    return @divTrunc(a, b);
}

fn max0(value: i32) i32 {
    return if (value < 0) 0 else value;
}

fn max3(a: i32, b: i32, c: i32) i32 {
    var out = a;
    if (b > out) out = b;
    if (c > out) out = c;
    return max0(out);
}

fn i2c() *volatile I2c {
    return @ptrFromInt(I2C2_BASE);
}

fn dmamux() *volatile Dmamux {
    return @ptrFromInt(DMAMUX_BASE);
}

fn hdma() *volatile Dma {
    return @ptrFromInt(HDMA_BASE);
}

const Timing = struct {
    t_sp: u32,
    t_sudat: u32,
    t_hddat: u32,
    t_sclratio: u32,
    t_sclhi: u32,
};

const I2c = extern struct {
    reserved0: [16]u8,
    cfg: u32,
    inten: u32,
    status: u32,
    addr: u32,
    data: u32,
    ctrl: u32,
    cmd: u32,
    setup: u32,
    tpm: u32,
};

const Dmamux = extern struct {
    muxcfg: [64]u32,
};

const DmaChannel = extern struct {
    ctrl: u32,
    transize: u32,
    srcaddr: u32,
    chanreqctrl: u32,
    dstaddr: u32,
    reserved0: u32,
    llpointer: u32,
    reserved1: u32,
};

const Dma = extern struct {
    reserved0: [4]u8,
    idmisc: u32,
    reserved1: [8]u8,
    dmacfg: u32,
    dmactrl: u32,
    chabort: u32,
    reserved2: [8]u8,
    inthalfsts: u32,
    inttcsts: u32,
    intabortsts: u32,
    interrsts: u32,
    chen: u32,
    reserved3: [8]u8,
    chctrl: [32]DmaChannel,
};

comptime {
    if (@offsetOf(I2c, "cfg") != 0x10) @compileError("I2C CFG offset mismatch");
    if (@offsetOf(I2c, "data") != 0x20) @compileError("I2C DATA offset mismatch");
    if (@offsetOf(I2c, "tpm") != 0x30) @compileError("I2C TPM offset mismatch");
    if (@offsetOf(Dma, "chctrl") != 0x40) @compileError("HDMA CHCTRL offset mismatch");
}
