#!/bin/bash
# build_sw.sh — compile one Phase 1 SW test to a word-hex RAM image.
# Usage: build_sw.sh <test_dir> <out_dir>
#   test_dir contains main.c (plus optional extra .c); links with
#   sw/common/startup.S + signature.c against sw/common/linker.ld.
# Requires riscv64-unknown-elf-gcc in PATH (lab machine / VeeR flow).
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: build_sw.sh <test_dir> <out_dir>" >&2
    exit 1
fi

TEST_DIR="$1"
OUT_DIR="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMON="$ROOT/sw/common"

CROSS="${CROSS_PREFIX:-riscv64-unknown-elf}"
CC="$CROSS-gcc"
OBJCOPY="$CROSS-objcopy"

# Fallback for machines where the toolchain lives outside PATH
# (e.g. /opt/riscv on the lab workstation).
if ! command -v "$CC" >/dev/null 2>&1; then
    if [ -x "/opt/riscv/bin/$CC" ]; then
        export PATH="/opt/riscv/bin:$PATH"
        echo "[build_sw] using toolchain at /opt/riscv/bin"
    else
        echo "[build_sw] error: $CC not in PATH and no /opt/riscv fallback" >&2
        exit 1
    fi
fi

# Matches the VeeR tools flow for older GCC (rv32imc, ilp32).
MARCH="${MARCH:-rv32imc_zicsr_zifencei}"
MABI="${MABI:-ilp32}"
case "${HAVE_HPM:-1}" in
    0|1) ;;
    *) echo "HAVE_HPM must be 0 or 1" >&2; exit 1 ;;
esac

mkdir -p "$OUT_DIR"

# Regenerate the address header so C can never drift from soc_pkg.sv.
python3 "$ROOT/scripts/gen_soc_map.py"

SRCS=("$COMMON/startup.S" "$COMMON/signature.c" "$TEST_DIR"/main.c)
# Allow extra C sources per test (e.g. future helpers).
for extra in "$TEST_DIR"/*.c; do
    case "$extra" in
        "$TEST_DIR/main.c") ;;
        *) SRCS+=("$extra") ;;
    esac
done

echo "[build_sw] test=$(basename "$TEST_DIR") march=$MARCH abi=$MABI"
"$CC" -march="$MARCH" -mabi="$MABI" \
    -DHAVE_HPM="${HAVE_HPM:-1}" \
    -ffreestanding -nostartfiles -nostdlib -fno-builtin \
    -O1 -g \
    -I"$COMMON" \
    -T "$COMMON/linker.ld" \
    -o "$OUT_DIR/test.elf" \
    "${SRCS[@]}" \
    -Wl,-Map="$OUT_DIR/test.map"

"$OBJCOPY" -O binary --gap-fill 0 "$OUT_DIR/test.elf" "$OUT_DIR/test.bin"
python3 "$ROOT/scripts/elf2hex.py" "$OUT_DIR/test.bin" "$OUT_DIR/test.hex" 0

echo "[build_sw] wrote $OUT_DIR/test.elf $OUT_DIR/test.hex"
