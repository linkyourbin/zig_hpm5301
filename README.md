# zig_hpm5301

Bare-metal Zig firmware for HPM5301IEG1.

The active firmware is a first Zig CMSIS-DAP v2 probe implementation. It brings up
USB0 high speed, exposes a vendor CMSIS-DAP bulk interface, and drives SWD through
HPM5301 FGPIO pins.

## Current Status

- CPU clock: 360 MHz
- USB: USB0 high-speed device, CMSIS-DAP v2 style bulk endpoints
- SWD backend: FGPIO bit-banged PA27/PA28
- Current USB serial string: `YBLINK-ZIG-0062-RDBLOCK`
- Build output: `zig-out/bin/zig_hpm5301_dap`

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
YBLINK CMSIS-DAP -- 1209:5301-0:YBLINK-ZIG-0062-RDBLOCK
```

Then try a target over SWD:

```sh
probe-rs info --probe 1209:5301:YBLINK --chip STM32F405RG --protocol swd --speed 1000000 --non-interactive
```

Fast STM32F405RG download test:

```sh
./download_stm32f405_fast.sh app.elf
```

This uses `target-overrides/STM32F4_Series_f405_page_32k.yaml`, which keeps the
stock probe-rs STM32F4 flash algorithm but changes the 1 MiB flash page size
from 1 KiB to 32 KiB. That reduces program-page calls from 1024 to 32 and avoids
the main host/flash-algorithm overhead seen in the stock command.

`YBLINK-ZIG-0062-RDBLOCK` uses direct fast paths for normal SWD transfers,
faster request-phase block writes, direct block reads, and cycle-counter based
CMSIS-DAP delays. On STM32F405RG with `app.elf` at requested 20000 kHz, the
stock target description finished in 35.76 s. Raw 32 KiB SRAM benchmark was
about 54.8 KiB/s read and 76.7 KiB/s write.

## Source Layout

- `src/main.zig`: boot metadata, runtime section init, DAP probe app
- `src/hpm5301.zig`: clock setup, GPIO/FGPIO, USB pin/clock helpers
- `src/usb_hs.zig`: blocking USB0 high-speed device driver
- `src/cmsis_dap.zig`: CMSIS-DAP command parser
- `src/swj.zig`: SWD/SWJ protocol engine
- `src/fast_gpio.zig`: direct FGPIO SWD pin backend
- `src/hpm5301_flash_xip.ld`: XIP flash linker script with `.fast` and `.noncacheable`
- `target-overrides/`: optional probe-rs target descriptions for benchmarks
