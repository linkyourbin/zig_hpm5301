# zig_hpm5301

Bare-metal Zig firmware for HPM5301IEG1.

The active firmware is a first Zig CMSIS-DAP v2 probe implementation. It brings up
USB0 high speed, exposes a vendor CMSIS-DAP bulk interface, and drives SWD through
HPM5301 FGPIO pins.

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

## Build

```sh
zig build

## Flash

```sh
probe-rs download --chip HPM5301 --protocol jtag --speed 20000 --binary-format elf zig-out/bin/zig_hpm5301_dap
```

## Source Layout

- `src/main.zig`: boot metadata, runtime section init, DAP probe app
- `src/hpm5301.zig`: clock setup, GPIO/FGPIO, USB pin/clock helpers
- `src/usb_hs.zig`: blocking USB0 high-speed device driver
- `src/cmsis_dap.zig`: CMSIS-DAP command parser
- `src/swj.zig`: SWD/SWJ protocol engine
- `src/fast_gpio.zig`: direct FGPIO SWD pin backend
- `src/hpm5301_flash_xip.ld`: XIP flash linker script with `.fast` and `.noncacheable`
