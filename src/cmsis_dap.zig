const swj_mod = @import("swj.zig");

pub const packet_size: usize = 1024;
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
const cmd_dap_queue_commands: u8 = 0x7e;
const cmd_dap_execute_commands: u8 = 0x7f;

const dap_ok: u8 = 0x00;
const dap_error: u8 = 0xff;

const dap_transfer_ok: u8 = 1 << 0;
const dap_transfer_wait: u8 = 1 << 1;
const dap_transfer_fault: u8 = 1 << 2;
const dap_transfer_no_ack: u8 = 0x07;
const dap_transfer_error: u8 = 1 << 3;
const dap_transfer_mismatch: u8 = 1 << 4;

const transfer_request_apndp: u8 = 1 << 0;
const transfer_request_rnw: u8 = 1 << 1;
const transfer_request_value_match: u8 = 1 << 4;
const transfer_request_match_mask: u8 = 1 << 5;
const dp_rdbuff_read: u8 = transfer_request_rnw | (1 << 2) | (1 << 3);
const check_posted_writes = true;

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
                cmd_dap_queue_commands, cmd_dap_execute_commands => self.executeCommands(request, response),
                cmd_dap_info => self.dapInfo(request, response),
                cmd_dap_host_status => fixedStatus(response, 2, dap_ok),
                cmd_dap_connect => self.connect(request, response),
                cmd_dap_disconnect => self.disconnect(response),
                cmd_dap_transfer_configure => self.transferConfigure(request, response),
                cmd_dap_transfer => self.transfer(request, response),
                cmd_dap_transfer_block => self.transferBlock(request, response),
                cmd_dap_transfer_abort => fixedStatus(response, 2, dap_ok),
                cmd_dap_write_abort => self.writeAbort(request, response),
                cmd_dap_delay => self.dapDelay(request, response),
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
                0x09 => infoString(response, "0.1.0-zig"),
                0xf0 => infoU8(response, 0x01),
                0xfb, 0xfc, 0xfd => infoU32(response, 0),
                0xfe => infoU8(response, packet_count),
                0xff => infoU16(response, packet_size),
                else => infoEmpty(response),
            };
        }

        fn executeCommands(self: *Self, request: []const u8, response: []u8) usize {
            if (request.len < 2) {
                response[0] = cmd_dap_execute_commands;
                response[1] = 0;
                return 2;
            }

            const requested = request[1];
            var input: usize = 2;
            var output: usize = 2;
            var executed: u8 = 0;
            response[0] = cmd_dap_execute_commands;

            var i: u8 = 0;
            while (i < requested and input < request.len and output < response.len) : (i += 1) {
                const request_len = commandRequestLen(request[input..]) orelse {
                    response[output] = dap_error;
                    output += 1;
                    input += 1;
                    executed += 1;
                    continue;
                };
                if (input + request_len > request.len) break;

                var sub_response: [packet_size]u8 = undefined;
                const response_len = self.process(request[input .. input + request_len], sub_response[0..]);
                if (output + response_len > response.len) break;
                for (sub_response[0..response_len], 0..) |byte, n| response[output + n] = byte;
                input += request_len;
                output += response_len;
                executed += 1;
            }

            response[1] = executed;
            return output;
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
            if (request.len < 3) {
                response[1] = 0;
                response[2] = dap_transfer_error;
                return 3;
            }
            if (self.connected_port != .swd) {
                response[1] = 0;
                response[2] = 0;
                return 3;
            }

            const transfer_count: usize = request[2];
            var req_index: usize = 3;
            var rsp_index: usize = 3;
            var completed: u8 = 0;
            var status: u8 = 0;
            var post_read = false;
            var check_write = false;

            var i: usize = 0;
            while (i < transfer_count) : (i += 1) {
                if (req_index >= request.len) {
                    status = dap_transfer_error;
                    break;
                }

                const transfer_request = request[req_index];
                req_index += 1;

                if ((transfer_request & transfer_request_match_mask) != 0) {
                    if (req_index + 4 > request.len) {
                        status = dap_transfer_error;
                        break;
                    }
                    self.match_mask = readLe32(request[req_index .. req_index + 4]);
                    req_index += 4;
                    status = dap_transfer_ok;
                    completed += 1;
                    check_write = false;
                    continue;
                }

                const read = (transfer_request & transfer_request_rnw) != 0;
                if (read) {
                    if (post_read) {
                        const result = if ((transfer_request & (transfer_request_apndp | transfer_request_value_match)) == transfer_request_apndp)
                            self.retryTransfer(transfer_request, 0)
                        else blk: {
                            post_read = false;
                            break :blk self.retryTransfer(dp_rdbuff_read, 0);
                        };
                        status = transferStatus(result.status);
                        if (status != dap_transfer_ok) break;
                        if (rsp_index + 4 > response.len) {
                            status = dap_transfer_error;
                            break;
                        }
                        writeLe32(response[rsp_index .. rsp_index + 4], result.data);
                        rsp_index += 4;
                    }

                    if ((transfer_request & transfer_request_value_match) != 0) {
                        if (req_index + 4 > request.len) {
                            status = dap_transfer_error;
                            break;
                        }
                        const expected = readLe32(request[req_index .. req_index + 4]);
                        req_index += 4;

                        if ((transfer_request & transfer_request_apndp) != 0) {
                            const result = self.retryTransfer(transfer_request, 0);
                            status = transferStatus(result.status);
                            if (status != dap_transfer_ok) break;
                        }

                        var retry = self.match_retries;
                        while (true) {
                            const result = self.retryTransfer(transfer_request, 0);
                            status = transferStatus(result.status);
                            if (status != dap_transfer_ok) break;
                            if ((result.data & self.match_mask) == expected) break;
                            if (retry == 0) {
                                status = dap_transfer_mismatch;
                                break;
                            }
                            retry -= 1;
                        }
                        if (status != dap_transfer_ok) break;
                        post_read = false;
                    } else if ((transfer_request & transfer_request_apndp) != 0) {
                        if (!post_read) {
                            const result = self.retryTransfer(transfer_request, 0);
                            status = transferStatus(result.status);
                            if (status != dap_transfer_ok) break;
                            post_read = true;
                        }
                    } else {
                        const result = self.retryTransfer(transfer_request, 0);
                        status = transferStatus(result.status);
                        if (status != dap_transfer_ok) break;
                        if (rsp_index + 4 > response.len) {
                            status = dap_transfer_error;
                            break;
                        }
                        writeLe32(response[rsp_index .. rsp_index + 4], result.data);
                        rsp_index += 4;
                    }
                    check_write = false;
                } else {
                    if (post_read) {
                        const result = self.retryTransfer(dp_rdbuff_read, 0);
                        status = transferStatus(result.status);
                        if (status != dap_transfer_ok) break;
                        if (rsp_index + 4 > response.len) {
                            status = dap_transfer_error;
                            break;
                        }
                        writeLe32(response[rsp_index .. rsp_index + 4], result.data);
                        rsp_index += 4;
                        post_read = false;
                    }

                    if (req_index + 4 > request.len) {
                        status = dap_transfer_error;
                        break;
                    }
                    const write_data = readLe32(request[req_index .. req_index + 4]);
                    req_index += 4;

                    if ((transfer_request & transfer_request_match_mask) != 0) {
                        self.match_mask = write_data;
                        status = dap_transfer_ok;
                        check_write = false;
                    } else {
                        const result = self.retryTransfer(transfer_request, write_data);
                        status = transferStatus(result.status);
                        if (status != dap_transfer_ok) break;
                        check_write = true;
                    }
                }
                completed += 1;
            }

            if (status == dap_transfer_ok) {
                if (post_read) {
                    const result = self.retryTransfer(dp_rdbuff_read, 0);
                    status = transferStatus(result.status);
                    if (status == dap_transfer_ok and rsp_index + 4 <= response.len) {
                        writeLe32(response[rsp_index .. rsp_index + 4], result.data);
                        rsp_index += 4;
                    } else if (status == dap_transfer_ok) {
                        status = dap_transfer_error;
                    }
                } else if (check_write and check_posted_writes) {
                    const result = self.retryTransfer(dp_rdbuff_read, 0);
                    status = transferStatus(result.status);
                }
            }

            response[1] = completed;
            response[2] = status;
            return rsp_index;
        }

        fn transferBlock(self: *Self, request: []const u8, response: []u8) usize {
            if (request.len < 5) {
                response[1] = 0;
                response[2] = 0;
                response[3] = dap_transfer_error;
                return 4;
            }
            if (self.connected_port != .swd) {
                response[1] = 0;
                response[2] = 0;
                response[3] = 0;
                return 4;
            }

            const count = readLe16(request[2..4]);
            const transfer_request = request[4];
            const read = (transfer_request & transfer_request_rnw) != 0;

            var completed: usize = 0;
            var status: u8 = 0;
            var rsp_index: usize = 4;

            if (count == 0) {
                status = dap_transfer_ok;
            } else if ((transfer_request & (transfer_request_value_match | transfer_request_match_mask)) != 0) {
                status = dap_transfer_error;
            } else if (read) {
                var request_value = transfer_request;
                if ((request_value & transfer_request_apndp) != 0) {
                    const result = self.retryTransfer(request_value, 0);
                    status = transferStatus(result.status);
                    if (status != dap_transfer_ok) {
                        writeLe16(response[1..3], completed);
                        response[3] = status;
                        return rsp_index;
                    }
                }

                while (completed < count) {
                    if (completed + 1 == count and (transfer_request & transfer_request_apndp) != 0) {
                        request_value = dp_rdbuff_read;
                    }
                    const result = self.retryTransfer(request_value, 0);
                    status = transferStatus(result.status);
                    if (status != dap_transfer_ok) break;
                    if (rsp_index + 4 > response.len) {
                        status = dap_transfer_error;
                        break;
                    }
                    writeLe32(response[rsp_index .. rsp_index + 4], result.data);
                    rsp_index += 4;
                    completed += 1;
                }
            } else {
                const payload = request[5..];
                const result = self.swj.swdWriteBlock(transfer_request, payload, count, self.wait_retries);
                status = transferStatus(result.status);
                completed = result.done;
                if (status == dap_transfer_ok and check_posted_writes) {
                    const check = self.retryTransfer(dp_rdbuff_read, 0);
                    status = transferStatus(check.status);
                }
            }

            writeLe16(response[1..3], completed);
            response[3] = status;
            return rsp_index;
        }

        fn writeAbort(self: *Self, request: []const u8, response: []u8) usize {
            if (request.len >= 6) {
                const abort_data = readLe32(request[2..6]);
                _ = self.retryTransfer(0x00, abort_data);
            }
            return fixedStatus(response, 2, dap_ok);
        }

        fn dapDelay(_: *Self, request: []const u8, response: []u8) usize {
            if (request.len < 3) return fixedStatus(response, 2, dap_error);
            delayMicros(readLe16(request[1..3]));
            return fixedStatus(response, 2, dap_ok);
        }

        fn resetTarget(self: *Self, response: []u8) usize {
            const low_state = self.swj.setPins(0x00, 0x80);
            delayMicros(20_000);
            const high_state = self.swj.setPins(0x80, 0x80);
            delayMicros(20_000);
            const reset_changed = ((low_state & 0x80) == 0) and ((high_state & 0x80) != 0);
            response[1] = dap_ok;
            response[2] = if (reset_changed) 1 else 0;
            return 3;
        }

        fn swjPins(self: *Self, request: []const u8, response: []u8) usize {
            if (request.len < 7) return fixedStatus(response, 2, dap_error);
            const values = request[1];
            const select = request[2] & ~@as(u8, 0x20);
            const wait_us = readLe32(request[3..7]);
            var state = self.swj.setPins(values, select);
            if (wait_us != 0) {
                const loops = @min(wait_us, 3_000_000) * 72;
                var i: u32 = 0;
                while (i < loops and ((state ^ values) & select) != 0) : (i += 1) {
                    if ((i & 0xff) == 0) state = self.swj.pinState();
                    asm volatile ("nop");
                }
            }
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
            if (self.connected_port != .swd or request.len < 2) return fixedStatus(response, 2, dap_error);
            response[1] = dap_ok;
            const sequence_count = request[1];
            var req_index: usize = 2;
            var rsp_index: usize = 2;
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
                const result = self.swj.swdTransfer(request & 0x0f, write_data);
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

fn infoU32(response: []u8, value: u32) usize {
    response[1] = 4;
    writeLe32(response[2..6], value);
    return 6;
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

fn writeLe16(out: []u8, value: usize) void {
    out[0] = @intCast(value & 0xff);
    out[1] = @intCast((value >> 8) & 0xff);
}

fn transferStatus(status: swj_mod.TransferStatus) u8 {
    return switch (status) {
        .ok => dap_transfer_ok,
        .wait => dap_transfer_wait,
        .fault => dap_transfer_fault,
        .no_ack => dap_transfer_no_ack,
        .protocol_error, .parity_error => dap_transfer_error,
    };
}

fn delayMicros(us_in: u32) void {
    spinDelay(@min(us_in, 3_000_000) * 72);
}

fn commandRequestLen(request: []const u8) ?usize {
    if (request.len == 0) return null;
    return switch (request[0]) {
        cmd_dap_info => if (request.len >= 2) 2 else null,
        cmd_dap_host_status => if (request.len >= 3) 3 else null,
        cmd_dap_connect => if (request.len >= 2) 2 else null,
        cmd_dap_disconnect, cmd_dap_transfer_abort, cmd_dap_reset_target => 1,
        cmd_dap_transfer_configure => if (request.len >= 6) 6 else null,
        cmd_dap_swj_clock => if (request.len >= 5) 5 else null,
        cmd_dap_swj_pins => if (request.len >= 7) 7 else null,
        cmd_dap_swd_configure => if (request.len >= 2) 2 else null,
        cmd_dap_delay => if (request.len >= 3) 3 else null,
        cmd_dap_write_abort => if (request.len >= 6) 6 else null,
        cmd_dap_swj_sequence => swjSequenceRequestLen(request),
        cmd_dap_swd_sequence => swdSequenceRequestLen(request),
        cmd_dap_transfer => transferRequestLen(request),
        cmd_dap_transfer_block => transferBlockRequestLen(request),
        cmd_dap_queue_commands, cmd_dap_execute_commands => null,
        else => 1,
    };
}

fn swjSequenceRequestLen(request: []const u8) ?usize {
    if (request.len < 2) return null;
    const bits: usize = if (request[1] == 0) 256 else request[1];
    const bytes = (bits + 7) / 8;
    return if (request.len >= 2 + bytes) 2 + bytes else null;
}

fn swdSequenceRequestLen(request: []const u8) ?usize {
    if (request.len < 2) return null;
    const sequence_count = request[1];
    var input: usize = 2;
    var seq: u8 = 0;
    while (seq < sequence_count) : (seq += 1) {
        if (input >= request.len) return null;
        const info = request[input];
        input += 1;
        const bits: usize = if ((info & 0x3f) == 0) 64 else (info & 0x3f);
        const bytes = (bits + 7) / 8;
        if ((info & 0x80) == 0) {
            if (input + bytes > request.len) return null;
            input += bytes;
        }
    }
    return input;
}

fn transferRequestLen(request: []const u8) ?usize {
    if (request.len < 3) return null;
    const count = request[2];
    var input: usize = 3;
    var i: u8 = 0;
    while (i < count) : (i += 1) {
        if (input >= request.len) return null;
        const dap_request = request[input];
        input += 1;
        if ((dap_request & transfer_request_rnw) != 0) {
            if ((dap_request & transfer_request_value_match) != 0) {
                if (input + 4 > request.len) return null;
                input += 4;
            }
        } else {
            if (input + 4 > request.len) return null;
            input += 4;
        }
    }
    return input;
}

fn transferBlockRequestLen(request: []const u8) ?usize {
    if (request.len < 5) return null;
    const count: usize = readLe16(request[2..4]);
    const dap_request = request[4];
    if ((dap_request & transfer_request_rnw) != 0) return 5;
    const len = 5 + count * 4;
    return if (request.len >= len) len else null;
}

fn spinDelay(cycles: u32) void {
    var i: u32 = 0;
    while (i < cycles) : (i += 1) asm volatile ("nop");
}
