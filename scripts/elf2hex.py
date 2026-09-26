#!/usr/bin/env python3
"""elf2hex.py — convert a linked ELF's binary image to word-oriented hex.

Usage: elf2hex.py <input.bin> <output.hex> [base_addr]
  input.bin   flat binary from `objcopy -O binary --gap-fill 0` whose
              byte 0 corresponds to base_addr (our linker puts RAM at 0x0,
              so base is 0).
  output.hex  $readmemh-compatible file: `@<word_index>` markers followed
              by 8-digit words, little-endian (matches axi_ram's 32-bit
              word memory). Sparse runs of all-zero words are skipped with
              a new @ marker, keeping files small.

This is NOT the VeeR testbench byte-hex format (one byte per line); that
format would load one byte per 32-bit word here and corrupt the image.
"""
import sys


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    src, dst = sys.argv[1], sys.argv[2]
    base = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0
    data = open(src, "rb").read()
    if base % 4:
        print("[elf2hex] base must be word-aligned", file=sys.stderr)
        return 1
    nwords = (len(data) + 3) // 4
    padded = data + b"\x00" * ((-len(data)) % 4)
    words = [
        int.from_bytes(padded[4 * i:4 * i + 4], "little")
        for i in range(nwords)
    ]
    with open(dst, "w") as f:
        idx = None
        for i, w in enumerate(words):
            if w == 0:
                idx = None  # defer; new marker when data resumes
                continue
            wa = base // 4 + i
            if wa != idx:
                f.write(f"@{wa:08X}\n")
            f.write(f"{w:08X}\n")
            idx = wa + 1
    print(f"[elf2hex] {nwords} words ({len(data)} bytes) -> {dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
