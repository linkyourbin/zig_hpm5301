#!/usr/bin/env bash
set -euo pipefail

CHIP="HPM5301"
PROTOCOL="jtag"
SPEED="20000"
ELF="zig-out/bin/zig_hpm5301_dap"
FLASH_PROBE="0d28:0204"

zig build

probe-rs download --probe "$FLASH_PROBE" --chip "$CHIP" --protocol "$PROTOCOL" --speed "$SPEED" --binary-format elf "$ELF"
