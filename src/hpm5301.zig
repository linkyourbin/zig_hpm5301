pub const gpio_port_a: usize = 0;
pub const gpio_port_b: usize = 1;

pub const pad_ctl_i2c_gpio: u32 = (1 << 8) | (1 << 17) | (1 << 18);
pub const pad_ctl_i2c_hw: u32 = pad_ctl_i2c_gpio;
pub const pad_ctl_led: u32 = (1 << 17) | (1 << 18) | (1 << 24);

const GPIO0_BASE: usize = 0xF00D0000;
const IOC_BASE: usize = 0xF4040000;
const SYSCTL_BASE: usize = 0xF4000000;
const PLLCTLV2_BASE: usize = 0xF40C0000;
const PCFG_BASE: usize = 0xF40C8000;

const SYSCTL_RESOURCE_LINKABLE_START = 256;
const SYSCTL_RESOURCE_I2C2 = 275;
const SYSCTL_RESOURCE_GPIO = 305;
const SYSCTL_RESOURCE_HDMA = 306;
const SYSCTL_RESOURCE_GPIO_OFFSET = SYSCTL_RESOURCE_GPIO - SYSCTL_RESOURCE_LINKABLE_START;
const SYSCTL_RESOURCE_CLK_TOP_I2C2 = 80;
const SYSCTL_CLOCK_CLK_TOP_I2C2 = 15;

const IOC_PAD_FUNC_CTL_LOOP_BACK_MASK: u32 = 1 << 16;
const IOC_PB08_FUNC_CTL_I2C2_SCL: u32 = 4;
const IOC_PB09_FUNC_CTL_I2C2_SDA: u32 = 4;

pub const GpioPin = struct {
    pad: usize,
    port: usize,
    pin: u5,
    pad_ctl: u32,

    pub fn configureOutput(self: GpioPin) void {
        configurePad(self);
        gpio().oe[self.port].set = self.mask();
    }

    pub fn configureOpenDrain(self: GpioPin) void {
        configurePad(self);
        gpio().do[self.port].clear = self.mask();
        self.release();
    }

    pub fn set(self: GpioPin) void {
        gpio().do[self.port].set = self.mask();
    }

    pub fn clear(self: GpioPin) void {
        gpio().do[self.port].clear = self.mask();
    }

    pub fn driveLow(self: GpioPin) void {
        gpio().do[self.port].clear = self.mask();
        gpio().oe[self.port].set = self.mask();
    }

    pub fn release(self: GpioPin) void {
        gpio().oe[self.port].clear = self.mask();
    }

    pub fn read(self: GpioPin) bool {
        return (gpio().di[self.port].value & self.mask()) != 0;
    }

    fn mask(self: GpioPin) u32 {
        return @as(u32, 1) << self.pin;
    }
};

pub const Led = struct {
    pin: GpioPin,
    delay_cycles: u32,

    pub fn init(self: Led) void {
        self.pin.configureOutput();
        self.off();
    }

    pub fn on(self: Led) void {
        self.pin.set();
    }

    pub fn off(self: Led) void {
        self.pin.clear();
    }

    pub fn blink(self: Led, count: u32) void {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            self.on();
            delayCycles(self.delay_cycles);
            self.off();
            delayCycles(self.delay_cycles);
        }
        delayCycles(self.delay_cycles * 2);
    }
};

pub const ClockPlan = struct {
    pll0_hz: u32,
    cpu0_hz: u32,
    ahb0_hz: u32,
};

pub const max_clock_plan = ClockPlan{
    .pll0_hz = 720_000_000,
    .cpu0_hz = 360_000_000,
    .ahb0_hz = 120_000_000,
};

pub fn enableGpioClock() void {
    enablePeripheralClock(SYSCTL_RESOURCE_GPIO);
}

pub fn initMaxClock() ClockPlan {
    const s = sysctl();
    const p = pllctl();
    const cfg = pcfg();

    // Same target as HPM5301EVKLite SDK board_init_clock: CPU 360 MHz, AHB 120 MHz.
    cfg.dcdc_mode = (cfg.dcdc_mode & ~@as(u32, 0x0fff)) | 1175;

    p.pll[0].config &= ~@as(u32, 0x1);
    p.pll[0].div[0] = (p.pll[0].div[0] & ~@as(u32, 0x3f)) | 0; // 720 MHz / 1.0
    waitPllDivStable(0, 0);
    p.pll[0].div[1] = (p.pll[0].div[1] & ~@as(u32, 0x3f)) | 1; // 720 MHz / 1.2
    waitPllDivStable(0, 1);
    p.pll[0].div[2] = (p.pll[0].div[2] & ~@as(u32, 0x3f)) | 4; // 720 MHz / 1.8
    waitPllDivStable(0, 2);

    p.pll[0].mfn = 0;
    p.pll[0].mfi = 30; // 24 MHz * 30 = 720 MHz
    waitPllStable(0);

    setClock(0, 1, 2); // CPU0: PLL0CLK0 / 2 = 360 MHz
    setClock(2, 1, 6); // AHB0: PLL0CLK0 / 6 = 120 MHz

    s.affiliate[0].set = 1;
    return max_clock_plan;
}

pub fn initI2c2PinsPb08Pb09() void {
    configurePadFunction(40, IOC_PB08_FUNC_CTL_I2C2_SCL | IOC_PAD_FUNC_CTL_LOOP_BACK_MASK, pad_ctl_i2c_hw);
    configurePadFunction(41, IOC_PB09_FUNC_CTL_I2C2_SDA | IOC_PAD_FUNC_CTL_LOOP_BACK_MASK, pad_ctl_i2c_hw);
}

pub fn enableI2c2Clock() void {
    enableClockResource(SYSCTL_RESOURCE_CLK_TOP_I2C2);
    setClock(SYSCTL_CLOCK_CLK_TOP_I2C2, 0, 1);
    enablePeripheralClock(SYSCTL_RESOURCE_I2C2);
}

pub fn enableHdmaClock() void {
    enablePeripheralClock(SYSCTL_RESOURCE_HDMA);
}

pub fn delayCycles(cycles: u32) void {
    var i: u32 = 0;
    while (i < cycles) : (i += 1) {
        asm volatile ("nop");
    }
}

fn enableClockResource(resource: usize) void {
    const s = sysctl();
    s.resource[resource] = 1;
    while ((s.resource[resource] & 0x40000000) != 0) {}
}

fn enablePeripheralClock(resource: usize) void {
    const offset = resource - SYSCTL_RESOURCE_LINKABLE_START;
    const s = sysctl();
    s.group0[offset / 32].set = @as(u32, 1) << @intCast(offset % 32);
    s.affiliate[0].set = 1;
    while ((s.resource[resource] & 0x40000000) != 0) {}
}

fn configurePad(pin: GpioPin) void {
    configurePadFunction(pin.pad, 0, pin.pad_ctl);
}

fn configurePadFunction(pad: usize, func_ctl: u32, pad_ctl: u32) void {
    const pads: *volatile [456]IocPad = @ptrFromInt(IOC_BASE);
    pads[pad].func_ctl = func_ctl;
    pads[pad].pad_ctl = pad_ctl;
}

fn setClock(node: usize, mux: u32, divide_by: u32) void {
    const s = sysctl();
    s.clock[node] = (s.clock[node] & ~@as(u32, 0x0000_07ff)) |
        ((mux << 8) & 0x700) |
        ((divide_by - 1) & 0xff);
    while ((s.clock[node] & 0x4000_0000) != 0) {}
}

fn waitPllStable(pll: usize) void {
    const p = pllctl();
    while (true) {
        const status = p.pll[pll].mfi;
        if ((status & 0x1000_0000) == 0) break;
        if ((status & 0x8000_0000) == 0 and (status & 0x2000_0000) != 0) break;
    }
}

fn waitPllDivStable(pll: usize, div: usize) void {
    const p = pllctl();
    while (true) {
        const status = p.pll[pll].div[div];
        if ((status & 0x1000_0000) == 0) break;
        if ((status & 0x8000_0000) == 0 and (status & 0x2000_0000) != 0) break;
    }
}

fn gpio() *volatile Gpio {
    return @ptrFromInt(GPIO0_BASE);
}

fn sysctl() *volatile Sysctl {
    return @ptrFromInt(SYSCTL_BASE);
}

fn pllctl() *volatile Pllctlv2 {
    return @ptrFromInt(PLLCTLV2_BASE);
}

fn pcfg() *volatile Pcfg {
    return @ptrFromInt(PCFG_BASE);
}

const GpioPortData = extern struct {
    value: u32,
    set: u32,
    clear: u32,
    toggle: u32,
};

const GpioInputPort = extern struct {
    value: u32,
    reserved: [12]u8,
};

const Gpio = extern struct {
    di: [15]GpioInputPort,
    reserved0: [16]u8,
    do: [15]GpioPortData,
    reserved1: [16]u8,
    oe: [15]GpioPortData,
};

const IocPad = extern struct {
    func_ctl: u32,
    pad_ctl: u32,
};

const SysctlGroup = extern struct {
    value: u32,
    set: u32,
    clear: u32,
    toggle: u32,
};

const Sysctl = extern struct {
    resource: [311]u32,
    reserved0: [804]u8,
    group0: [2]SysctlGroup,
    reserved1: [224]u8,
    affiliate: [1]SysctlGroup,
    reserved2: [3824]u8,
    clock: [41]u32,
    reserved3: [1884]u8,
    global00: u32,
};

const Pll = extern struct {
    mfi: u32,
    mfn: u32,
    mfd: u32,
    ss_step: u32,
    ss_stop: u32,
    config: u32,
    locktime: u32,
    steptime: u32,
    advanced: u32,
    reserved0: [28]u8,
    div: [3]u32,
    reserved1: [52]u8,
};

const Pllctlv2 = extern struct {
    xtal: u32,
    reserved0: [124]u8,
    pll: [3]Pll,
};

const Pcfg = extern struct {
    bandgap: u32,
    ldo1p1: u32,
    ldo2p5: u32,
    reserved0: [4]u8,
    dcdc_mode: u32,
};

comptime {
    if (@offsetOf(Gpio, "do") != 0x100) @compileError("GPIO DO offset mismatch");
    if (@offsetOf(Gpio, "oe") != 0x200) @compileError("GPIO OE offset mismatch");
    if (@offsetOf(Sysctl, "group0") != 0x800) @compileError("SYSCTL GROUP0 offset mismatch");
    if (@offsetOf(Sysctl, "affiliate") != 0x900) @compileError("SYSCTL AFFILIATE offset mismatch");
    if (@offsetOf(Sysctl, "clock") != 0x1800) @compileError("SYSCTL CLOCK offset mismatch");
    if (@offsetOf(Sysctl, "global00") != 0x2000) @compileError("SYSCTL GLOBAL00 offset mismatch");
    if (@offsetOf(Pllctlv2, "pll") != 0x80) @compileError("PLLCTLV2 PLL offset mismatch");
    if (@offsetOf(Pll, "div") != 0x40) @compileError("PLLCTLV2 DIV offset mismatch");
    if (@offsetOf(Pllctlv2, "pll") + @offsetOf(Pll, "div") != 0xc0) @compileError("PLLCTLV2 PLL0 DIV absolute offset mismatch");
    if (@offsetOf(Pcfg, "dcdc_mode") != 0x10) @compileError("PCFG DCDC_MODE offset mismatch");
}
