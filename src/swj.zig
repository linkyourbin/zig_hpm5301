pub const Port = enum(u8) {
    disabled = 0,
    swd = 1,
    jtag = 2,
};

pub const TransferStatus = enum(u8) {
    ok = 1,
    wait = 2,
    fault = 4,
    no_ack = 7,
    protocol_error = 0x10,
    parity_error = 0x20,

    pub fn dapAck(self: TransferStatus) u8 {
        return switch (self) {
            .ok => 0x01,
            .wait => 0x02,
            .fault => 0x04,
            .no_ack => 0x07,
            .protocol_error, .parity_error => 0x00,
        };
    }
};

pub const TransferResult = struct {
    status: TransferStatus,
    data: u32 = 0,
};

pub const WriteBlockResult = struct {
    status: TransferStatus,
    done: usize,
};

pub fn Swj(comptime PinsType: type) type {
    return struct {
        const Self = @This();

        pins: PinsType,
        idle_cycles: u8 = 0,
        turnaround_cycles: u8 = 1,
        data_phase_on_wait_fault: bool = false,

        pub fn init(pins: PinsType) Self {
            return .{ .pins = pins };
        }

        pub fn setClockHz(self: *Self, hz: u32) void {
            self.pins.setClockHz(hz);
        }

        pub fn setIdleCycles(self: *Self, cycles: u8) void {
            self.idle_cycles = cycles;
        }

        pub fn configureSwd(self: *Self, turnaround_count: u8, data_phase_on_wait_fault: bool) void {
            self.turnaround_cycles = if (turnaround_count < 1) 1 else if (turnaround_count > 4) 4 else turnaround_count;
            self.data_phase_on_wait_fault = data_phase_on_wait_fault;
        }

        pub fn connect(self: *Self, port: Port) void {
            switch (port) {
                .swd => self.connectSwd(),
                .jtag => self.connectJtag(),
                .disabled => {},
            }
        }

        pub fn swjSequence(self: *Self, bit_count: usize, data: []const u8) void {
            self.swdWriteSequence(bit_count, data);
        }

        pub fn swdWriteSequence(self: *Self, bit_count: usize, data: []const u8) void {
            self.pins.swdioOutput();
            var bit_index: usize = 0;
            while (bit_index < bit_count) : (bit_index += 1) {
                const bit = ((data[bit_index / 8] >> @intCast(bit_index % 8)) & 1) != 0;
                self.pins.swdWriteBitCycle(bit);
            }
        }

        pub fn swdReadSequence(self: *Self, bit_count: usize, out: []u8) void {
            for (out) |*byte| byte.* = 0;
            self.pins.swdioInput();
            var bit_index: usize = 0;
            while (bit_index < bit_count) : (bit_index += 1) {
                if (self.pins.swclkSampleSwdio()) {
                    out[bit_index / 8] |= @as(u8, 1) << @intCast(bit_index % 8);
                }
            }
            self.pins.swdioOutput();
            self.pins.setSwdioTms(true);
        }

        pub fn setPins(self: *Self, values: u8, select: u8) u8 {
            if ((select & 0x01) != 0) self.pins.setSwclkTck((values & 0x01) != 0);
            if ((select & 0x02) != 0) {
                self.pins.swdioOutput();
                self.pins.setSwdioTms((values & 0x02) != 0);
            }
            if ((select & 0x04) != 0) self.pins.setTdi((values & 0x04) != 0);
            if ((select & 0x80) != 0) self.pins.setReset((values & 0x80) != 0);
            return self.pins.currentPinState();
        }

        pub fn pinState(self: *Self) u8 {
            return self.pins.currentPinState();
        }

        pub fn swdTransfer(self: *Self, request: u8, write_data: u32) TransferResult {
            const rn_w = (request & 0x02) != 0;
            const swd_request = makeSwdRequest(request);

            if (self.canUseFastPath()) {
                if (rn_w) {
                    return self.pins.swdReadTransferFast(swd_request);
                }
                return .{ .status = self.pins.swdWriteTransferFast(swd_request, write_data) };
            }

            self.pins.swdioOutput();
            self.pins.swdWriteBits(swd_request, 8);

            self.pins.swdioInput();
            self.turnaround();
            const ack: u8 = self.pins.swclkSampleSwdio3Bits();

            switch (ack) {
                0b001 => {
                    if (rn_w) {
                        const data = self.pins.swclkSampleSwdioBits(32);
                        const parity = self.pins.swclkSampleSwdio();
                        self.turnaround();
                        self.pins.swdioOutput();
                        self.idle();
                        if (parity == oddParity(data)) {
                            return .{ .status = .ok, .data = data };
                        }
                        return .{ .status = .parity_error, .data = data };
                    }

                    self.turnaround();
                    self.pins.swdioOutput();
                    self.pins.swdWriteDataBits(write_data, 32);
                    self.pins.swdWriteDataBits(if (oddParity(write_data)) 1 else 0, 1);
                    self.idle();
                    return .{ .status = .ok };
                },
                0b010 => {
                    self.handleWaitFaultDataPhase(rn_w);
                    self.turnaround();
                    self.pins.swdioOutput();
                    self.idle();
                    return .{ .status = .wait };
                },
                0b100 => {
                    self.handleWaitFaultDataPhase(rn_w);
                    self.turnaround();
                    self.pins.swdioOutput();
                    self.idle();
                    return .{ .status = .fault };
                },
                0b111 => {
                    self.finishProtocolError();
                    return .{ .status = .no_ack };
                },
                else => {
                    self.finishProtocolError();
                    return .{ .status = .protocol_error };
                },
            }
        }

        pub fn swdWriteBlock(self: *Self, request: u8, data: []const u8, count: usize, wait_retries: usize) WriteBlockResult {
            if (self.canUseFastPath()) {
                return self.pins.swdWriteBlockFast(makeSwdRequest(request), data, count, wait_retries);
            }

            const swd_request = makeSwdRequest(request);
            var done: usize = 0;
            var input: usize = 0;

            self.pins.swdioOutput();
            while (done < count) {
                if (input + 4 > data.len) return .{ .status = .protocol_error, .done = done };
                const write_data = readLe32(data[input .. input + 4]);
                var retry = wait_retries;
                while (true) {
                    const status = self.swdWriteTransferPrecomputed(swd_request, write_data);
                    if (status != .wait or retry == 0) {
                        if (status != .ok) return .{ .status = status, .done = done };
                        break;
                    }
                    retry -= 1;
                }
                input += 4;
                done += 1;
            }

            return .{ .status = .ok, .done = done };
        }

        fn swdWriteTransferPrecomputed(self: *Self, swd_request: u8, write_data: u32) TransferStatus {
            self.pins.swdioOutput();
            self.pins.swdWriteBits(swd_request, 8);
            self.pins.swdioInput();
            self.turnaround();
            const ack: u8 = self.pins.swclkSampleSwdio3Bits();

            switch (ack) {
                0b001 => {
                    self.turnaround();
                    self.pins.swdioOutput();
                    self.pins.swdWriteDataBits(write_data, 32);
                    self.pins.swdWriteDataBits(if (oddParity(write_data)) 1 else 0, 1);
                    self.idle();
                    return .ok;
                },
                0b010 => {
                    self.handleWaitFaultDataPhase(false);
                    self.turnaround();
                    self.pins.swdioOutput();
                    self.idle();
                    return .wait;
                },
                0b100 => {
                    self.handleWaitFaultDataPhase(false);
                    self.turnaround();
                    self.pins.swdioOutput();
                    self.idle();
                    return .fault;
                },
                0b111 => {
                    self.finishProtocolError();
                    return .no_ack;
                },
                else => {
                    self.finishProtocolError();
                    return .protocol_error;
                },
            }
        }

        fn connectSwd(self: *Self) void {
            const line_reset = [_]u8{0xff} ** 8;
            const jtag_to_swd = [_]u8{ 0x9e, 0xe7 };
            const idle_bits = [_]u8{0x00};
            self.swjSequence(64, line_reset[0..]);
            self.swjSequence(16, jtag_to_swd[0..]);
            self.swjSequence(64, line_reset[0..]);
            self.swjSequence(8, idle_bits[0..]);
        }

        fn connectJtag(self: *Self) void {
            self.pins.swdioOutput();
            self.pins.setSwdioTms(true);
            self.pins.setTdi(true);
            var i: usize = 0;
            while (i < 8) : (i += 1) self.pins.tckCycle();
            self.pins.setSwdioTms(false);
            self.pins.tckCycle();
        }

        fn turnaround(self: *Self) void {
            var i: u8 = 0;
            while (i < self.turnaround_cycles) : (i += 1) self.pins.swclkCycle();
        }

        fn idle(self: *Self) void {
            if (self.idle_cycles != 0) {
                self.pins.setSwdioTms(false);
                var i: u8 = 0;
                while (i < self.idle_cycles) : (i += 1) self.pins.swclkCycle();
            }
            self.pins.setSwdioTms(true);
        }

        fn handleWaitFaultDataPhase(self: *Self, rn_w: bool) void {
            if (!self.data_phase_on_wait_fault) return;
            if (rn_w) {
                _ = self.pins.swclkSampleSwdioBits(33);
            } else {
                self.turnaround();
                self.pins.swdioOutput();
                self.pins.swdWriteBits(0, 33);
                self.pins.swdioInput();
            }
        }

        fn finishProtocolError(self: *Self) void {
            self.pins.swdioInput();
            _ = self.pins.swclkSampleSwdioBits(@as(usize, self.turnaround_cycles) + 33);
            self.pins.swdioOutput();
            self.idle();
        }

        inline fn canUseFastPath(self: *Self) bool {
            return self.turnaround_cycles == 1 and self.idle_cycles == 0 and !self.data_phase_on_wait_fault;
        }
    };
}

pub fn makeSwdRequest(dap_request: u8) u8 {
    const ap: u8 = if ((dap_request & 0x01) != 0) 1 else 0;
    const read: u8 = if ((dap_request & 0x02) != 0) 1 else 0;
    const a2: u8 = if ((dap_request & 0x04) != 0) 1 else 0;
    const a3: u8 = if ((dap_request & 0x08) != 0) 1 else 0;
    const parity = (ap ^ read ^ a2 ^ a3) & 1;
    return 1 | (ap << 1) | (read << 2) | (a2 << 3) | (a3 << 4) | (parity << 5) | (1 << 7);
}

pub fn oddParity(value: u32) bool {
    var bits = value;
    bits ^= bits >> 16;
    bits ^= bits >> 8;
    bits ^= bits >> 4;
    return ((@as(u32, 0x6996) >> @intCast(bits & 0x0f)) & 1) != 0;
}

fn readLe32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}
