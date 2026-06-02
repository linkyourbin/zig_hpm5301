#!/usr/bin/env bash
set -euo pipefail

CHIP="HPM5301"
PROTOCOL="jtag"
SPEED="20000"
ELF="zig-out/bin/zig_hpm5301_dap"

zig build

probe-rs download --chip "$CHIP" --protocol "$PROTOCOL" --speed "$SPEED" --binary-format elf "$ELF" || \
probe-rs download --connect-under-reset --chip "$CHIP" --protocol "$PROTOCOL" --speed 1000 --binary-format elf "$ELF"
# probe-rs reset --chip "$CHIP" --protocol "$PROTOCOL" --speed "$SPEED"
