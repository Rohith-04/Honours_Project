# SW Stack (Phase 1 Bare Metal)

Everything the core executes lives in `sw/`. No libc, no traps beyond
the halt/trap handler in `startup.S`.

## `sw/common/`

| File | Role |
|------|------|
| `startup.S` | Reset entry at `0x0`: `mtvec`, stack, `mfdc`, `mrac`, result-word clear, call `main`, signature write, `ebreak` halt loop; trap handler records `0xDEAD` + `ebreak` |
| `linker.ld` | All sections in 64 KiB RAM at `0x0`; `.text.init` (`_start`) first; `.signature` pinned at `0x7FF0`; `_stack_top = 0x10000` |
| `soc_map.h` | **Generated** by `scripts/gen_soc_map.py` from `rtl/soc/soc_pkg.sv` — never hand-edit; bases, sizes, offsets, bit positions, absolute register addresses, result-word pointer |
| `io.h` | `mmio_write32` (with `fence`, per PRM) / `mmio_read32` via volatile pointers |
| `uart.h` | Polled driver: init `LCR=0x80 → BAUD=100 → LCR=0x03 → IER=1` (`IER=1` mandatory — IP gates `DATA_READY` on it), THRE-polled `putc/puts`, `drain_tx` on THRE+TEMT |
| `result.h` / `signature.c` | Pass/fail convention (`main` returns 0/1) + the pinned `.signature` result word |

## Reset configuration (`startup.S`)

- `mrac` CSR `0x7C0` = `0x8`: region 1 (`0x1000_0000`–`0x1FFF_FFFF`,
  UART/Timer/GPIO) side-effecting + non-cacheable (`sideeffect1`=bit 3);
  every other region stays idempotent + non-cacheable (safe bring-up: no
  caching anywhere, strict ordering). Followed by `fence` + `fence.i`.
- `mfdc` CSR `0x7F9` = `0x4` (`wbcd`): Write-Buffer coalescing off, so
  back-to-back MMIO writes (e.g. UART THR bytes) can never merge.
  `fence.i` before and after, per the PRM. Mirrors
  `Cores-VeeR-EL2/testbench/asm/icache.s`.

## Per-test programs (`sw/*_test/main.c`)

Poll-only, report over UART, return 0/1. Bring-up order GPIO → UART →
Timer. `gpio_test`: DIR/OUT patterns with readbacks + input check
(harness drives `gpio_in` to `0xA5`). `uart_test`: LSR idle check, sends
`UART HELLO` + `UART OK`. `timer_test`: reload-while-disabled,
free-run to `COMPARE=100`, match-flag poll, W1C clear,
count-holds-while-disabled. No VeeR interrupt plumbing yet
(`timer_irq_o` is TB-checked, not core-handled).

## Build flow (`scripts/build_sw.sh`, `scripts/elf2hex.py`)

```
build_sw.sh sw/<ip>_test run/sw_<ip>/
  riscv64-unknown-elf-gcc -march=rv32imc_zicsr_zifencei -mabi=ilp32
    -ffreestanding -nostartfiles -nostdlib
    -T sw/common/linker.ld startup.S signature.c main.c -> test.elf
  objcopy -O binary --gap-fill 0 -> test.bin
  elf2hex.py -> test.hex   (word-oriented $readmemh: `@<word_index>`
                            + 8-digit LE words; NOT the VeeR byte-hex format)
```

`test.hex` is consumed via `axi_ram`'s `+SW_HEX` plusarg. `build_sw.sh`
regenerates `soc_map.h` first, uses `/opt/riscv/bin` as fallback when
the toolchain is not on `PATH`, and fails loudly otherwise.
