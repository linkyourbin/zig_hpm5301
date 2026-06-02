# zig_hpm5301

Bare-metal Zig firmware for the HPM5301IEG1 board.

The current demo drives a 0.96 inch two-color SSD1306 OLED over bit-banged I2C and uses PA10 as a debug LED. The code is split into small reusable Zig modules for HPM5301 register access, GPIO, bit-banged I2C, and SSD1306 display control.

## Hardware

- MCU: HPM5301IEG1
- OLED: SSD1306 0.96 inch two-color I2C module
- Debug LED: PA10

Working OLED wiring:

| OLED | HPM5301IEG1 |
| --- | --- |
| SCL | J3-5 PB08 |
| SDA | J3-3 PB09 |
| VCC | 3.3V |
| GND | GND |

## Build

```sh
zig build
```

Output files are generated under `zig-out/bin/`.

## Flash

Use the included probe-rs script:

```sh
./flash.sh
```

The script builds first, then downloads `zig-out/bin/ssd1306_i2c_test` using:

```sh
probe-rs download --chip HPM5301 --protocol jtag --speed 20000 --binary-format elf zig-out/bin/ssd1306_i2c_test
```

## Source Layout

- `src/main.zig`: boot metadata and application flow
- `src/hpm5301.zig`: clock setup, GPIO, delay, and register definitions
- `src/i2c_bitbang.zig`: reusable open-drain bit-banged I2C bus
- `src/ssd1306.zig`: SSD1306 initialization and frame drawing
- `src/font6x8.zig`: small 6x8 font table
- `src/hpm5301_flash_xip.ld`: linker script for XIP flash boot
