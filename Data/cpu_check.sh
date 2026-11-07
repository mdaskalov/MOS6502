#!/bin/sh
# Compares the package with AppleWin's 6502: builds AppleWin's own CPU code
# from a checkout (cpu_check_applewin.cpp) and the checker (cpu_check.swift,
# with the package's sources), runs random single instructions of every
# opcode on both.
# Usage: ./cpu_check.sh path/to/AppleWin [CASES_PER_OPCODE]
set -e
cd "$(dirname "$0")"
if [ ! -f "$1/source/CPU/cpu6502.h" ]; then
    echo "usage: $0 path/to/AppleWin [CASES_PER_OPCODE]" >&2
    exit 2
fi
OUT="${TMPDIR:-/tmp}/mos6502_cpu_check"
mkdir -p "$OUT"
swiftc -O -wmo -parse-as-library -cross-module-optimization -module-name MOS6502 \
    -emit-module -emit-module-path "$OUT/MOS6502.swiftmodule" \
    -emit-library -static -o "$OUT/libMOS6502.a" ../Sources/MOS6502/*.swift
clang++ -std=c++17 -O2 -w -I "$1/source/CPU" -o "$OUT/applewin" cpu_check_applewin.cpp
swiftc -O -wmo -parse-as-library -I "$OUT" -L "$OUT" -lMOS6502 -o "$OUT/check" cpu_check.swift
"$OUT/applewin" "$OUT/cases.bin" "${2:-1000}"
"$OUT/check" "$OUT/cases.bin"
