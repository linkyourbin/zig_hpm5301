#!/usr/bin/env bash
set -euo pipefail

CHIP="${CHIP:-STM32F405RG}"
PROTOCOL="${PROTOCOL:-swd}"
SPEED="${SPEED:-20000}"
PROBE="${PROBE:-1209:5301}"
ELF="${1:-app.elf}"
OVERRIDE="${OVERRIDE:-target-overrides/STM32F4_Series_f405_page_32k.yaml}"

probe-rs download \
  --probe "$PROBE" \
  --chip-description-path "$OVERRIDE" \
  --chip "$CHIP" \
  --protocol "$PROTOCOL" \
  --speed "$SPEED" \
  "$ELF"
