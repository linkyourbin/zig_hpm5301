const swj_mod = @import("swj.zig");

pub const packet_size: usize = 512;
pub const packet_count: u8 = 1;

const cmd_dap_info: u8 = 0x00;
const cmd_dap_host_status: u8 = 0x01;
const cmd_dap_connect: u8 = 0x02;
const cmd_dap_disconnect: u8 = 0x03;
const cmd_dap_transfer_configure: u8 = 0x04;
const cmd_dap_transfer: u8 = 0x05;
const cmd_dap_transfer_block: u8 = 0x06;
const cmd_dap_transfer_abort: u8 = 0x07;
const cmd_dap_write_abort: u8 = 0x08;
const cmd_dap_delay: u8 = 0x09;
const cmd_dap_reset_target: u8 = 0x0a;
const cmd_dap_swj_pins: u8 = 0x10;
const cmd_dap_swj_clock: u8 = 0x11;
const cmd_dap_swj_sequence: u8 = 0x12;
const cmd_dap_swd_configure: u8 = 0x13;
const cmd_dap_swd_sequence: u8 = 0x1d;

const dap_ok: u8 = 0x00;
const dap_error: u8 = 0xff;

const transfer_request_value_match: u8 = 1 << 4;
const transfer_request_match_mask: u8 = 1 << 5;

pub fn Dap(comptime SwjType: type) type {
    return struct {
        const Self = @This();

        swj: *SwjType,
        connected_port: swj_mod.Port = .disabled,
        transfer_idle_cycles: u8 = 0,
        wait_retries: usize = 100,
        match_retries: usize = 0,
        match_mask: u32 = 0xffff_ffff,

        pub fn init(swj: *SwjType) Self {
            return .{ .swj = swj };
        }

        pub fn process(self: *Self, request: []const u8, response: []u8) usize {
            if (request.len == 0 or response.len == 0) return 0;
            response[0] = request[0];

            return switch (request[0]) {
                cmd_dap_info => self.dapInfo(request, response),
                cmd_dap_host_status => fixedStatus(response, 2, dap_ok),
                cmd_dap_connect => self.connect(request, response),
                cmd_dap_disconnect => self.disconnect(response),
                cmd_dap_transfer_configure => self.transferConfigure(request, response),
                cmd_dap_transfer => self.transfer(request, response),
                cmd_dap_transfer_block => self.transferBlock(request, response),
                cmd_dap_transfer_abort => fixedStatus(response, 2, dap_ok),
                cmd_dap_write_abort => self.writeAbort(request, response),
                cmd_dap_delay => fixedStatus(response, 2, dap_ok),
                cmd_dap_reset_target => self.resetTarget(response),
                cmd_dap_swj_pins => self.swjPins(request, response),
                cmd_dap_swj_clock => self.swjClock(request, response),
                cmd_dap_swj_sequence => self.swjSequence(request, response),
                cmd_dap_swd_configure => self.swdConfigure(request, response),
                cmd_dap_swd_sequence => self.swdSequence(request, response),
                else => fixedStatus(response, 2, dap_error),
            };
        }

        fn dapInfo(_: *Self, request: []const u8, response: []u8) usize {
            if (request.len < 2) return fixedStatus(response, 2, 0);
            const id = request[1];
            return switch (id) {
                0x01 => infoString(response, "YBLINK"),
                0x02 => infoString(response, "YBLINK CMSIS-DAP"),
                0x03 => infoString(response, "YBLINK"),
                0x04 => infoString(response, "0.1.0-zig"),
                0xf0 => infoU8(response, 0x01),
                0xfe => infoU8(response, packet_count),
                0xff => infoU16(response, packet_size),
                else => infoEmpty(response),
            };
        }

        fn connect(self: *Self, request: []const u8, response: []u8) usize {
            const wanted = if (request.len >= 2) request[1] else 0;
            const port: swj_mod.Port = switch (wanted) {
                0, 1, 2 => .swd,
                else => .disabled,
            };
            self.connected_port = port;
            self.swj.connect(port);
            response[1] = @intFromEnum(port);
            return 2;
        }

        fn disconnect(self: *Self, response: []u8) usize {
            self.connected_port = .disabled;
            response[1] = dap_ok;
            return 2;
        }

        fn transferConfigure(self: *Self, request: []const u8, response: []u8) usize {
            if (request.len < 6) return fixedStatus(response, 2, dap_error);
            self.transfer_idle_cycles = request[1];
            self.wait_retries = readLe16(request[2..4]);
            self.match_retries = readLe16(request[4..6]);
            self.swj.setIdleCycles(self.transfer_idle_cycles);
            response[1] = dap_ok;
            return 2;
        }

        fn transfer(self: *Self, request: []const u8, response: []u8) usize {
            if (request.len < 3) return fixedStatus(response, 2, dap_error);
            const transfer_count = request[2];
            var req_index: usize = 3;
            var rsp_index: usize = 4;
            var completed: u8 = 0;
            var status: swj_mod.TransferStatus = .ok;

            response[1] = 0;
            response[2] = 0;

            var i: u8 = 0;
            while (i < transfer_count) : (i += 1) {
                if (req_index >= request.len) {
                    status = .protocol_error;
                    break;
                }

                const transfer_request = request[req_index];
                req_index += 1;

                if ((transfer_request & transfer_request_match_mask) != 0) {
                    if (req_index + 4 > request.len) {
                        status = .protocol_error;
                        break;
                    }
                    self.match_mask = readLe32(request[req_index .. req_index + 4]);
                    req_index += 4;
                    completed += 1;
                    continue;
                }

                const read = (transfer_request & 0x02) != 0;
                var write_data: u32 = 0;
                if (!read) {
                    if (req_index + 4 > request.len) {
                        status = .protocol_error;
                        break;
                    }
                    write_data = readLe32(request[req_index .. req_index + 4]);
                    req_index += 4;
                }

                var result = self.retryTransfer(transfer_request & 0x0f, write_data);
                if ((transfer_request & transfer_request_value_match) != 0 and read and result.status == .ok) {
                    var retry = self.match_retries;
                    const expected = if (req_index + 4 <= request.len) readLe32(request[req_index .. req_index + 4]) else 0;
                    if (req_index + 4 <= request.len) req_index += 4;
                    while (((result.data ^ expected) & self.match_mask) != 0 and retry > 0) {
                        retry -= 1;
                        result = self.retryTransfer(transfer_request & 0x0f, 0);
                        if (result.status != .ok) break;
                    }
                    if (((result.data ^ expected) & self.match_mask) != 0 and result.status == .ok) {
                        result.status = .wait;
                    }
                }

                status = result.status;
                if (status != .ok) break;

                if (read) {
                    if (rsp_index + 4 > response.len) {
                        status = .protocol_error;
                        break;
                    }
                    writeLe32(response[rsp_index .. rsp_index + 4], result.data);
                    rsp_index += 4;
                }
                completed += 1;
            }

            response[1] = completed;
            response[2] = status.dapAck();
            return rsp_index;
        }

        fn transferBlock(self: *Self, request: []const u8, response: []u8) usize {
            if (request.len < 6) return fixedStatus(response, 2, dap_error);
            const count = readLe16(request[2..4]);
            const transfer_request = request[4];
            const read = (transfer_request & 0x02) != 0;

            var completed: usize = 0;
            var status: swj_mod.TransferStatus = .ok;
            var rsp_index: usize = 5;

            if (read) {
                while (completed < count) {
                    const result = self.retryTransfer(transfer_request & 0x0f, 0);
                    status = result.status;
                    if (status != .ok) break;
                    if (rsp_index + 4 > response.len) {
                        status = .protocol_error;
                        break;
                    }
                    writeLe32(response[rsp_index .. rsp_index + 4], result.data);
                    rsp_index += 4;
                    completed += 1;
                }
            } else {
                const payload = request[5..];
                const result = self.swj.swdWriteBlock(transfer_request & 0x0f, payload, count, self.wait_retries);
                status = result.status;
                completed = result.done;
                rsp_index = 5;
            }

            response[1] = @intCast(completed & 0xff);
            response[2] = @intCast((completed >> 8) & 0xff);
            response[3] = @intCast((completed >> 16) & 0xff);
            response[4] = status.dapAck();
            return rsp_index;
        }

        fn writeAbort(self: *Self, request: []const u8, response: []u8) usize {
            if (request.len >= 6) {
                const abort_data = readLe32(request[2..6]);
                _ = self.retryTransfer(0x00, abort_data);
            }
            return fixedStatus(response, 2, dap_ok);
        }

        fn resetTarget(self: *Self, response: []u8) usize {
            _ = self.swj.setPins(0x00, 0x80);
            spinDelay(7_200_000);
            _ = self.swj.setPins(0x80, 0x80);
            spinDelay(7_200_000);
            response[1] = dap_ok;
            response[2] = 1;
            return 3;
        }

        fn swjPins(self: *Self, request: []const u8, response: []u8) usize {
            if (request.len < 7) return fixedStatus(response, 2, dap_error);
            const values = request[1];
            const select = request[2];
            const wait_us = readLe32(request[3..7]);
            const state = self.swj.setPins(values, select);
            if (wait_us != 0) spinDelay(wait_us * 72);
            response[1] = state;
            return 2;
        }

        fn swjClock(self: *Self, request: []const u8, response: []u8) usize {
            if (request.len < 5) return fixedStatus(response, 2, dap_error);
            self.swj.setClockHz(readLe32(request[1..5]));
            response[1] = dap_ok;
            return 2;
        }

        fn swjSequence(self: *Self, request: []const u8, response: []u8) usize {
            if (request.len < 2) return fixedStatus(response, 2, dap_error);
            const bit_count: usize = if (request[1] == 0) 256 else request[1];
            const byte_count = (@as(usize, bit_count) + 7) / 8;
            if (request.len < 2 + byte_count) return fixedStatus(response, 2, dap_error);
            self.swj.swjSequence(bit_count, request[2 .. 2 + byte_count]);
            response[1] = dap_ok;
            return 2;
        }

        fn swdConfigure(self: *Self, request: []const u8, response: []u8) usize {
            if (request.len < 2) return fixedStatus(response, 2, dap_error);
            const cfg = request[1];
            const turnaround = (cfg & 0x03) + 1;
            const data_phase = (cfg & 0x04) != 0;
            self.swj.configureSwd(turnaround, data_phase);
            response[1] = dap_ok;
            return 2;
        }

        fn swdSequence(self: *Self, request: []const u8, response: []u8) usize {
            if (request.len < 2) return fixedStatus(response, 2, dap_error);
            const sequence_count = request[1];
            var req_index: usize = 2;
            var rsp_index: usize = 1;
            var seq: u8 = 0;
            while (seq < sequence_count) : (seq += 1) {
                if (req_index >= request.len) return fixedStatus(response, 2, dap_error);
                const info = request[req_index];
                req_index += 1;
                const bit_count = if ((info & 0x3f) == 0) 64 else (info & 0x3f);
                const byte_count = (@as(usize, bit_count) + 7) / 8;
                if ((info & 0x80) != 0) {
                    if (rsp_index + byte_count > response.len) return fixedStatus(response, 2, dap_error);
                    self.swj.swdReadSequence(bit_count, response[rsp_index .. rsp_index + byte_count]);
                    rsp_index += byte_count;
                } else {
                    if (req_index + byte_count > request.len) return fixedStatus(response, 2, dap_error);
                    self.swj.swdWriteSequence(bit_count, request[req_index .. req_index + byte_count]);
                    req_index += byte_count;
                }
            }
            return rsp_index;
        }

        fn retryTransfer(self: *Self, request: u8, write_data: u32) swj_mod.TransferResult {
            var retry = self.wait_retries;
            while (true) {
                const result = self.swj.swdTransfer(request, write_data);
                if (result.status != .wait or retry == 0) return result;
                retry -= 1;
            }
        }
    };
}

fn fixedStatus(response: []u8, len: usize, status: u8) usize {
    if (response.len > 1) response[1] = status;
    return len;
}

fn infoEmpty(response: []u8) usize {
    response[1] = 0;
    return 2;
}

fn infoU8(response: []u8, value: u8) usize {
    response[1] = 1;
    response[2] = value;
    return 3;
}

fn infoU16(response: []u8, value: usize) usize {
    response[1] = 2;
    response[2] = @intCast(value & 0xff);
    response[3] = @intCast((value >> 8) & 0xff);
    return 4;
}

fn infoString(response: []u8, value: []const u8) usize {
    const count = if (value.len + 1 > response.len - 2) response.len - 2 else value.len + 1;
    response[1] = @intCast(count);
    var i: usize = 0;
    while (i + 1 < count) : (i += 1) response[2 + i] = value[i];
    response[2 + count - 1] = 0;
    return 2 + count;
}

fn readLe16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readLe32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn writeLe32(out: []u8, value: u32) void {
    out[0] = @intCast(value & 0xff);
    out[1] = @intCast((value >> 8) & 0xff);
    out[2] = @intCast((value >> 16) & 0xff);
    out[3] = @intCast((value >> 24) & 0xff);
}

fn spinDelay(cycles: u32) void {
    var i: u32 = 0;
    while (i < cycles) : (i += 1) asm volatile ("nop");
}
