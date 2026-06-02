# zig_hpm5301

Bare-metal Zig firmware for HPM5301IEG1.

The active firmware is a first Zig CMSIS-DAP v2 probe implementation. It brings up
USB0 high speed, exposes a vendor CMSIS-DAP bulk interface, and drives SWD through
HPM5301 FGPIO pins. PA10 is kept as a debug LED during boot.

## Current Status

- CPU clock: 360 MHz
- USB: USB0 high-speed device, CMSIS-DAP v2 style bulk endpoints
- SWD backend: FGPIO bit-banged PA27/PA28
- Build output: `zig-out/bin/zig_hpm5301_dap`
- Previous SSD1306/I2C modules remain in `src/` but are not the active app

## Pin Map

| Probe signal | HPM5301 pin | J3 pin | Target signal |
| --- | --- | ---: | --- |
| SWCLK | PA27 | 23 | SWCLK |
| SWDIO | PA28 | 21 | SWDIO |
| nRESET | PB10 | 26 | NRST |
| GND | GND | 25/30/34/39 | GND |

Optional JTAG pins are reserved for the next step:

| Probe signal | HPM5301 pin | J3 pin |
| --- | --- | ---: |
| TDO | PA26 | 24 |
| TDI | PA29 | 19 |

USB0 uses the board USB connector through PA24/PA25.

## Build

```sh
zig build
```

## Flash

```sh
./flash.sh
```

The script builds first, then downloads:

```sh
probe-rs download --chip HPM5301 --protocol jtag --speed 20000 --binary-format elf zig-out/bin/zig_hpm5301_dap
```

## Smoke Test

After flashing and reconnecting USB, check enumeration:

```sh
probe-rs list
```

Expected USB identity:

```text
YBLINK CMSIS-DAP -- 1209:5301-0:YBLINK
```

Then try a target over SWD:

```sh
probe-rs info --probe 1209:5301:YBLINK --chip STM32F405RG --protocol swd --speed 1000000 --non-interactive
```

## Source Layout

- `src/main.zig`: boot metadata, runtime section init, active app selection
- `src/hpm5301.zig`: clock setup, GPIO/FGPIO, USB pin/clock helpers
- `src/usb_hs.zig`: blocking USB0 high-speed device driver
- `src/cmsis_dap.zig`: CMSIS-DAP command parser
- `src/swj.zig`: SWD/SWJ protocol engine
- `src/fast_gpio.zig`: direct FGPIO SWD pin backend
- `src/hpm5301_flash_xip.ld`: XIP flash linker script with `.fast` and `.noncacheable`
