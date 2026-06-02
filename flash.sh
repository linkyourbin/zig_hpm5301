#!/usr/bin/env bash
set -euo pipefail

CHIP="HPM5301"
PROTOCOL="jtag"
SPEED="20000"
ELF="zig-out/bin/zig_hpm5301_dap"
FLASH_PROBE="0d28:0204"

zig build

probe-rs download --probe "$FLASH_PROBE" --chip "$CHIP" --protocol "$PROTOCOL" --speed "$SPEED" --binary-format elf "$ELF" || \
probe-rs download --probe "$FLASH_PROBE" --connect-under-reset --chip "$CHIP" --protocol "$PROTOCOL" --speed 1000 --binary-format elf "$ELF"
probe-rs reset --probe "$FLASH_PROBE" --chip "$CHIP" --protocol "$PROTOCOL" --speed "$SPEED" || \
probe-rs reset --probe "$FLASH_PROBE" --connect-under-reset --chip "$CHIP" --protocol "$PROTOCOL" --speed 1000
