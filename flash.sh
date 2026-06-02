#!/usr/bin/env bash
set -euo pipefail

CHIP="HPM5301"
PROTOCOL="jtag"
SPEED="20000"
ELF="zig-out/bin/ssd1306_i2c_test"

zig build

probe-rs download --chip "$CHIP" --protocol "$PROTOCOL" --speed "$SPEED" --binary-format elf "$ELF"
# probe-rs reset --chip "$CHIP" --protocol "$PROTOCOL" --speed "$SPEED"
