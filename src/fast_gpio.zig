const hpm = @import("hpm5301.zig");
const swj = @import("swj.zig");

const port_a: usize = 0;
const port_b: usize = 1;

const pin_tdo: u5 = 26;
const pin_swclk_tck: u5 = 27;
const pin_swdio_tms: u5 = 28;
const pin_tdi: u5 = 29;
const pin_nreset: u5 = 10;
const pad_nreset: usize = 42;

const swclk_tck: u32 = @as(u32, 1) << pin_swclk_tck;
const swdio_tms: u32 = @as(u32, 1) << pin_swdio_tms;
const tdi: u32 = @as(u32, 1) << pin_tdi;
const tdo: u32 = @as(u32, 1) << pin_tdo;
const nreset: u32 = @as(u32, 1) << pin_nreset;

const output_mask_a = swclk_tck | swdio_tms | tdi;
const output_mask_b = nreset;

pub const ProbePins = struct {
    half_period_delay: u8 = swdDelayForHz(1_000_000),
    write_half_period_delay: u8 = swdWriteDelayForHz(1_000_000),
    output_a: u32 = swdio_tms | tdi,
    output_b: u32 = nreset,

    pub fn init() ProbePins {
        hpm.configureGpioPad(pin_tdo, false);
        hpm.configureGpioPad(pin_swclk_tck, false);
        hpm.configureGpioPad(pin_swdio_tms, true);
        hpm.configureGpioPad(pin_tdi, false);
        hpm.configureGpioPad(pad_nreset, true);

        hpm.assignPinToFastGpio(port_a, pin_tdo);
        hpm.assignPinToFastGpio(port_a, pin_swclk_tck);
        hpm.assignPinToFastGpio(port_a, pin_swdio_tms);
        hpm.assignPinToFastGpio(port_a, pin_tdi);
        hpm.assignPinToFastGpio(port_b, pin_nreset);

        const pins = ProbePins{};
        writeDo(port_a, pins.output_a);
        writeDo(port_b, pins.output_b);
        oeSet(port_a, output_mask_a);
        oeSet(port_b, output_mask_b);
        oeClear(port_a, tdo);
        return pins;
    }

    pub fn setClockHz(self: *ProbePins, hz: u32) void {
        self.half_period_delay = swdDelayForHz(hz);
        self.write_half_period_delay = swdWriteDelayForHz(hz);
    }

    pub inline fn swdioOutput(_: *ProbePins) void {
        oeSet(port_a, swdio_tms);
    }

    pub inline fn swdioInput(_: *ProbePins) void {
        oeClear(port_a, swdio_tms);
    }

    pub inline fn setSwdioTms(self: *ProbePins, high: bool) void {
        self.writeALevel(swdio_tms, high);
    }

    pub inline fn setTdi(self: *ProbePins, high: bool) void {
        self.writeALevel(tdi, high);
    }

    pub inline fn setSwclkTck(self: *ProbePins, high: bool) void {
        self.writeALevel(swclk_tck, high);
    }

    pub inline fn setReset(self: *ProbePins, high: bool) void {
        if (high) {
            self.output_b |= nreset;
        } else {
            self.output_b &= ~nreset;
        }
        writeDo(port_b, self.output_b);
    }

    pub inline fn swclkCycle(self: *ProbePins) void {
        doClear(port_a, swclk_tck);
        self.delayHalf();
        self.output_a |= swclk_tck;
        doSet(port_a, swclk_tck);
        self.delayHalf();
    }

    pub inline fn swclkSampleSwdio(self: *ProbePins) bool {
        doClear(port_a, swclk_tck);
        self.delayHalf();
        const bit = (readDi(port_a) & swdio_tms) != 0;
        self.output_a |= swclk_tck;
        doSet(port_a, swclk_tck);
        self.delayHalf();
        return bit;
    }

    pub inline fn swdWriteBitCycle(self: *ProbePins, high: bool) void {
        if (high) {
            self.output_a = (self.output_a | swdio_tms) & ~swclk_tck;
        } else {
            self.output_a &= ~(swdio_tms | swclk_tck);
        }
        writeDo(port_a, self.output_a);
        self.delayHalf();
        self.output_a |= swclk_tck;
        writeDo(port_a, self.output_a);
        self.delayHalf();
    }

    pub inline fn swdWriteBits(self: *ProbePins, bits_in: u32, count: usize) void {
        var bits = bits_in;
        const delay = self.write_half_period_delay;
        var output = self.output_a;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if ((bits & 1) != 0) {
                output = (output | swdio_tms) & ~swclk_tck;
            } else {
                output &= ~(swdio_tms | swclk_tck);
            }
            writeDo(port_a, output);
            delayHalfCount(delay);
            output |= swclk_tck;
            doSet(port_a, swclk_tck);
            delayHalfCount(delay);
            bits >>= 1;
        }
        self.output_a = output;
    }

    pub inline fn swdWriteDataBits(self: *ProbePins, bits_in: u32, count: usize) void {
        const delay = self.write_half_period_delay;
        if (delay != 1) {
            self.swdWriteBits(bits_in, count);
            return;
        }

        var bits = bits_in;
        var output = self.output_a;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if ((bits & 1) != 0) {
                output = (output | swdio_tms) & ~swclk_tck;
            } else {
                output &= ~(swdio_tms | swclk_tck);
            }
            writeDo(port_a, output);
            delayHalfCount(delay);
            output |= swclk_tck;
            doSet(port_a, swclk_tck);
            bits >>= 1;
        }
        self.output_a = output;
    }

    pub inline fn swclkSampleSwdioBits(self: *ProbePins, count: usize) u32 {
        const delay = self.half_period_delay;
        var value: u32 = 0;
        var bit: usize = 0;
        while (bit < count) : (bit += 1) {
            doClear(port_a, swclk_tck);
            delayHalfCount(delay);
            if ((readDi(port_a) & swdio_tms) != 0) value |= @as(u32, 1) << @intCast(bit);
            doSet(port_a, swclk_tck);
            delayHalfCount(delay);
        }
        self.output_a |= swclk_tck;
        return value;
    }

    pub inline fn swclkSampleSwdio3Bits(self: *ProbePins) u8 {
        const delay = self.half_period_delay;
        var value: u8 = 0;

        doClear(port_a, swclk_tck);
        delayHalfCount(delay);
        if ((readDi(port_a) & swdio_tms) != 0) value |= 1;
        doSet(port_a, swclk_tck);
        delayHalfCount(delay);

        doClear(port_a, swclk_tck);
        delayHalfCount(delay);
        if ((readDi(port_a) & swdio_tms) != 0) value |= 2;
        doSet(port_a, swclk_tck);
        delayHalfCount(delay);

        doClear(port_a, swclk_tck);
        delayHalfCount(delay);
        if ((readDi(port_a) & swdio_tms) != 0) value |= 4;
        doSet(port_a, swclk_tck);
        delayHalfCount(delay);

        self.output_a |= swclk_tck;
        return value;
    }

    pub inline fn tckCycle(self: *ProbePins) void {
        self.swclkCycle();
    }

    pub inline fn tckSampleTdo(self: *ProbePins) bool {
        doClear(port_a, swclk_tck);
        self.delayHalf();
        const bit = (readDi(port_a) & tdo) != 0;
        self.output_a |= swclk_tck;
        doSet(port_a, swclk_tck);
        self.delayHalf();
        return bit;
    }

    pub fn currentPinState(_: *ProbePins) u8 {
        const di_a = readDi(port_a);
        const di_b = readDi(port_b);
        var pins: u8 = 0x20;
        if ((di_a & swclk_tck) != 0) pins |= 0x01;
        if ((di_a & swdio_tms) != 0) pins |= 0x02;
        if ((di_a & tdi) != 0) pins |= 0x04;
        if ((di_a & tdo) != 0) pins |= 0x08;
        if ((di_b & nreset) != 0) pins |= 0x80;
        return pins;
    }

    pub inline fn swdWriteBlockFast(self: *ProbePins, swd_request: u8, data: []const u8, count: usize, wait_retries: usize) swj.WriteBlockResult {
        self.swdioOutput();
        var done: usize = 0;
        var input: usize = 0;

        while (done < count) {
            if (input + 4 > data.len) return .{ .status = .protocol_error, .done = done };
            const write_data = readLe32(data[input .. input + 4]);
            const parity: u32 = if (swj.oddParity(write_data)) 1 else 0;
            var retry = wait_retries;

            while (true) {
                const ack = self.swdWriteRequestReadAck(swd_request);
                switch (ack) {
                    0b001 => {
                        self.swclkCycle();
                        self.swdioOutput();
                        self.swdWriteBits(write_data, 32);
                        self.swdWriteBits(parity, 1);
                        self.setSwdioTms(true);
                        break;
                    },
                    0b010 => {
                        self.swclkCycle();
                        self.swdioOutput();
                        self.setSwdioTms(true);
                        if (retry == 0) return .{ .status = .wait, .done = done };
                        retry -= 1;
                    },
                    0b100 => {
                        self.swclkCycle();
                        self.swdioOutput();
                        self.setSwdioTms(true);
                        return .{ .status = .fault, .done = done };
                    },
                    0b111 => {
                        self.finishProtocolErrorFast();
                        return .{ .status = .no_ack, .done = done };
                    },
                    else => {
                        self.finishProtocolErrorFast();
                        return .{ .status = .protocol_error, .done = done };
                    },
                }
            }

            input += 4;
            done += 1;
        }

        return .{ .status = .ok, .done = done };
    }

    pub inline fn swdWriteTransferFast(self: *ProbePins, swd_request: u8, write_data: u32) swj.TransferStatus {
        self.swdioOutput();
        const ack = self.swdWriteRequestReadAck(swd_request);
        switch (ack) {
            0b001 => {
                self.swclkCycle();
                self.swdioOutput();
                self.swdWriteBits(write_data, 32);
                self.swdWriteBits(if (swj.oddParity(write_data)) 1 else 0, 1);
                self.setSwdioTms(true);
                return .ok;
            },
            0b010 => {
                self.swclkCycle();
                self.swdioOutput();
                self.setSwdioTms(true);
                return .wait;
            },
            0b100 => {
                self.swclkCycle();
                self.swdioOutput();
                self.setSwdioTms(true);
                return .fault;
            },
            0b111 => {
                self.finishProtocolErrorFast();
                return .no_ack;
            },
            else => {
                self.finishProtocolErrorFast();
                return .protocol_error;
            },
        }
    }

    pub inline fn swdReadTransferFast(self: *ProbePins, swd_request: u8) swj.TransferResult {
        self.swdioOutput();
        const ack = self.swdWriteRequestReadAck(swd_request);
        switch (ack) {
            0b001 => {
                const data = self.swclkSampleSwdioBits(32);
                const parity = self.swclkSampleSwdio();
                self.swclkCycle();
                self.swdioOutput();
                self.setSwdioTms(true);
                if (parity == swj.oddParity(data)) return .{ .status = .ok, .data = data };
                return .{ .status = .parity_error, .data = data };
            },
            0b010 => {
                self.swclkCycle();
                self.swdioOutput();
                self.setSwdioTms(true);
                return .{ .status = .wait };
            },
            0b100 => {
                self.swclkCycle();
                self.swdioOutput();
                self.setSwdioTms(true);
                return .{ .status = .fault };
            },
            0b111 => {
                self.finishProtocolErrorFast();
                return .{ .status = .no_ack };
            },
            else => {
                self.finishProtocolErrorFast();
                return .{ .status = .protocol_error };
            },
        }
    }

    inline fn swdWriteRequestReadAck(self: *ProbePins, swd_request: u8) u8 {
        self.swdWriteBits(swd_request, 8);
        self.swdioInput();
        self.swclkCycle();
        return self.swclkSampleSwdio3Bits();
    }

    inline fn finishProtocolErrorFast(self: *ProbePins) void {
        self.swdioInput();
        _ = self.swclkSampleSwdioBits(34);
        self.swdioOutput();
        self.setSwdioTms(true);
    }

    inline fn writeALevel(self: *ProbePins, mask: u32, high: bool) void {
        if (high) {
            self.output_a |= mask;
        } else {
            self.output_a &= ~mask;
        }
        writeDo(port_a, self.output_a);
    }

    inline fn delayHalf(self: *ProbePins) void {
        delayHalfCount(self.half_period_delay);
    }
};

pub const ProbeSwj = swj.Swj(ProbePins);

pub const LazyProbePins = struct {
    pins: ?ProbePins = null,
    clock_hz: u32 = 1_000_000,

    pub fn init() LazyProbePins {
        return .{};
    }

    pub fn setClockHz(self: *LazyProbePins, hz: u32) void {
        self.clock_hz = hz;
        if (self.pins) |*pins| pins.setClockHz(hz);
    }

    pub inline fn swdioOutput(self: *LazyProbePins) void {
        self.ensure().swdioOutput();
    }

    pub inline fn swdioInput(self: *LazyProbePins) void {
        self.ensure().swdioInput();
    }

    pub inline fn setSwdioTms(self: *LazyProbePins, high: bool) void {
        self.ensure().setSwdioTms(high);
    }

    pub inline fn setTdi(self: *LazyProbePins, high: bool) void {
        self.ensure().setTdi(high);
    }

    pub inline fn setSwclkTck(self: *LazyProbePins, high: bool) void {
        self.ensure().setSwclkTck(high);
    }

    pub inline fn setReset(self: *LazyProbePins, high: bool) void {
        self.ensure().setReset(high);
    }

    pub inline fn swclkCycle(self: *LazyProbePins) void {
        self.ensure().swclkCycle();
    }

    pub inline fn swclkSampleSwdio(self: *LazyProbePins) bool {
        return self.ensure().swclkSampleSwdio();
    }

    pub inline fn swdWriteBitCycle(self: *LazyProbePins, high: bool) void {
        self.ensure().swdWriteBitCycle(high);
    }

    pub inline fn swdWriteBits(self: *LazyProbePins, bits_in: u32, count: usize) void {
        self.ensure().swdWriteBits(bits_in, count);
    }

    pub inline fn swdWriteDataBits(self: *LazyProbePins, bits_in: u32, count: usize) void {
        self.ensure().swdWriteDataBits(bits_in, count);
    }

    pub inline fn swclkSampleSwdioBits(self: *LazyProbePins, count: usize) u32 {
        return self.ensure().swclkSampleSwdioBits(count);
    }

    pub inline fn swclkSampleSwdio3Bits(self: *LazyProbePins) u8 {
        return self.ensure().swclkSampleSwdio3Bits();
    }

    pub inline fn tckCycle(self: *LazyProbePins) void {
        self.ensure().tckCycle();
    }

    pub inline fn tckSampleTdo(self: *LazyProbePins) bool {
        return self.ensure().tckSampleTdo();
    }

    pub fn currentPinState(self: *LazyProbePins) u8 {
        return self.ensure().currentPinState();
    }

    pub inline fn swdWriteBlockFast(self: *LazyProbePins, swd_request: u8, data: []const u8, count: usize, wait_retries: usize) swj.WriteBlockResult {
        return self.ensure().swdWriteBlockFast(swd_request, data, count, wait_retries);
    }

    pub inline fn swdWriteTransferFast(self: *LazyProbePins, swd_request: u8, write_data: u32) swj.TransferStatus {
        return self.ensure().swdWriteTransferFast(swd_request, write_data);
    }

    pub inline fn swdReadTransferFast(self: *LazyProbePins, swd_request: u8) swj.TransferResult {
        return self.ensure().swdReadTransferFast(swd_request);
    }

    inline fn ensure(self: *LazyProbePins) *ProbePins {
        if (self.pins == null) {
            self.pins = ProbePins.init();
            self.pins.?.setClockHz(self.clock_hz);
        }
        return &self.pins.?;
    }
};

pub const LazyProbeSwj = swj.Swj(LazyProbePins);

inline fn delayHalfCount(count: u8) void {
    switch (count) {
        0 => {},
        1 => asm volatile ("nop"),
        2 => {
            asm volatile ("nop");
            asm volatile ("nop");
        },
        3 => {
            asm volatile ("nop");
            asm volatile ("nop");
            asm volatile ("nop");
        },
        5 => {
            asm volatile ("nop");
            asm volatile ("nop");
            asm volatile ("nop");
            asm volatile ("nop");
            asm volatile ("nop");
        },
        else => |n| {
            var i: u8 = 0;
            while (i < n) : (i += 1) asm volatile ("nop");
        },
    }
}

fn swdDelayForHz(hz: u32) u8 {
    if (hz <= 250_000) return 96;
    if (hz <= 500_000) return 48;
    if (hz <= 1_000_000) return 24;
    if (hz <= 2_000_000) return 10;
    if (hz <= 3_000_000) return 7;
    if (hz <= 4_000_000) return 5;
    if (hz <= 8_000_000) return 3;
    if (hz <= 20_000_000) return 2;
    return 1;
}

fn swdWriteDelayForHz(hz: u32) u8 {
    return if (hz > 8_000_000) 1 else swdDelayForHz(hz);
}

fn readLe32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

inline fn readDi(port: usize) u32 {
    return hpm.fastGpio().di[port].value;
}

inline fn writeDo(port: usize, value: u32) void {
    hpm.fastGpio().do[port].value = value;
}

inline fn doSet(port: usize, mask: u32) void {
    hpm.fastGpio().do[port].set = mask;
}

inline fn doClear(port: usize, mask: u32) void {
    hpm.fastGpio().do[port].clear = mask;
}

inline fn oeSet(port: usize, mask: u32) void {
    hpm.fastGpio().oe[port].set = mask;
}

inline fn oeClear(port: usize, mask: u32) void {
    hpm.fastGpio().oe[port].clear = mask;
}
