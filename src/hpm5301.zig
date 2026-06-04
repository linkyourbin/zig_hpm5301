pub const gpio_port_a: usize = 0;
pub const gpio_port_b: usize = 1;

pub const pad_ctl_led: u32 = (1 << 17) | (1 << 18) | (1 << 24);

const GPIO0_BASE: usize = 0xF00D0000;
const FGPIO_BASE: usize = 0x000C0000;
const GPIOM_BASE: usize = 0xF00D8000;
const IOC_BASE: usize = 0xF4040000;
const SYSCTL_BASE: usize = 0xF4000000;
const PLLCTLV2_BASE: usize = 0xF40C0000;
const PCFG_BASE: usize = 0xF40C8000;

const SYSCTL_RESOURCE_LINKABLE_START = 256;
const SYSCTL_RESOURCE_GPIO = 305;
const SYSCTL_RESOURCE_USB0 = 308;

const IOC_FUNC_USB0: u32 = 25;
const IOC_PAD_FUNC_CTL_ANALOG_MASK: u32 = 1 << 31;
const GPIOM_SELECT_FGPIO: u32 = 2;
const GPIOM_HIDE: u32 = 1 << 4;

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

pub fn enableUsb0Clock() void {
    enablePeripheralClock(SYSCTL_RESOURCE_USB0);
}

pub fn initUsb0PinsPa24Pa25() void {
    configurePadFunction(24, IOC_PAD_FUNC_CTL_ANALOG_MASK, 0);
    configurePadFunction(25, IOC_PAD_FUNC_CTL_ANALOG_MASK, 0);
    configurePadFunction(448, IOC_FUNC_USB0, 0);
    configurePadFunction(449, IOC_FUNC_USB0, 0);
}

pub fn configureGpioPad(pad: usize, pull_up: bool) void {
    const pull: u32 = if (pull_up) (1 << 8) | (1 << 9) | (1 << 17) else 0;
    const ctl = (7 << 0) | (3 << 4) | (1 << 12) | pull | (1 << 18);
    configurePadFunction(pad, 0, ctl);
}

pub fn assignPinToFastGpio(port: usize, pin: usize) void {
    gpiom().assign[port].pin[pin] = GPIOM_SELECT_FGPIO | GPIOM_HIDE;
}

pub fn fastGpio() *volatile Gpio {
    return @ptrFromInt(FGPIO_BASE);
}

pub fn delayCycles(cycles: u32) void {
    var i: u32 = 0;
    while (i < cycles) : (i += 1) {
        asm volatile ("nop");
    }
}

pub fn delayMicros(us_in: u32) void {
    const us = @min(us_in, 3_000_000);
    const ticks = us * (max_clock_plan.cpu0_hz / 1_000_000);
    const start = coreCycle32();
    while (coreCycle32() -% start < ticks) {}
}

inline fn coreCycle32() u32 {
    return asm volatile ("csrr %[value], cycle"
        : [value] "=r" (-> u32),
    );
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

fn gpiom() *volatile Gpiom {
    return @ptrFromInt(GPIOM_BASE);
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

const GpiomPort = extern struct {
    pin: [32]u32,
};

const Gpiom = extern struct {
    assign: [15]GpiomPort,
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
    if (@offsetOf(Gpiom, "assign") != 0) @compileError("GPIOM ASSIGN offset mismatch");
    if (@offsetOf(Sysctl, "group0") != 0x800) @compileError("SYSCTL GROUP0 offset mismatch");
    if (@offsetOf(Sysctl, "affiliate") != 0x900) @compileError("SYSCTL AFFILIATE offset mismatch");
    if (@offsetOf(Sysctl, "clock") != 0x1800) @compileError("SYSCTL CLOCK offset mismatch");
    if (@offsetOf(Sysctl, "global00") != 0x2000) @compileError("SYSCTL GLOBAL00 offset mismatch");
    if (@offsetOf(Pllctlv2, "pll") != 0x80) @compileError("PLLCTLV2 PLL offset mismatch");
    if (@offsetOf(Pll, "div") != 0x40) @compileError("PLLCTLV2 DIV offset mismatch");
    if (@offsetOf(Pllctlv2, "pll") + @offsetOf(Pll, "div") != 0xc0) @compileError("PLLCTLV2 PLL0 DIV absolute offset mismatch");
    if (@offsetOf(Pcfg, "dcdc_mode") != 0x10) @compileError("PCFG DCDC_MODE offset mismatch");
}
