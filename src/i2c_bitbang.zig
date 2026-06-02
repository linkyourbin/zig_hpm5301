const hpm = @import("hpm5301.zig");

pub const Bus = struct {
    scl: hpm.GpioPin,
    sda: hpm.GpioPin,
    delay_cycles: u32,

    pub fn init(self: Bus) void {
        self.scl.configureOpenDrain();
        self.sda.configureOpenDrain();
        self.release();
    }

    pub fn release(self: Bus) void {
        self.scl.release();
        self.sda.release();
    }

    pub fn writeRegisterBytes(self: Bus, addr: u8, control: u8, bytes: []const u8) bool {
        self.start();
        var ok = self.writeByte(addr << 1);
        ok = self.writeByte(control) and ok;
        for (bytes) |byte| {
            ok = self.writeByte(byte) and ok;
        }
        self.stop();
        return ok;
    }

    pub fn start(self: Bus) void {
        self.sda.release();
        self.scl.release();
        self.delay();
        self.sda.driveLow();
        self.delay();
        self.scl.driveLow();
        self.delay();
    }

    pub fn stop(self: Bus) void {
        self.sda.driveLow();
        self.delay();
        self.scl.release();
        self.delay();
        self.sda.release();
        self.delay();
    }

    pub fn writeByte(self: Bus, data: u8) bool {
        var mask: u8 = 0x80;
        while (mask != 0) : (mask >>= 1) {
            if ((data & mask) != 0) {
                self.sda.release();
            } else {
                self.sda.driveLow();
            }

            self.delay();
            self.scl.release();
            self.delay();
            self.scl.driveLow();
            self.delay();
        }

        self.sda.release();
        self.delay();
        self.scl.release();
        self.delay();
        const ack = !self.sda.read();
        self.scl.driveLow();
        self.delay();
        return ack;
    }

    fn delay(self: Bus) void {
        hpm.delayCycles(self.delay_cycles);
    }
};
