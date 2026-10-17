# SW Harness — `tb/sw/tb_soc_sw.sv` (Level 3)

DUT = the toolchain-to-hardware path. The BFM does not appear; the real
VeeR EL2 is the only master. Wiring: `el2_veer_wrapper` (64-bit
LSU/IFU/SB) → `veer_axi_adapter` → `honours_soc.s_axi_*` (32-bit).

## VeeR configuration

- Instantiated as `design/el2_veer_wrapper` directly (not the testbench
  `veer_wrapper` shim). Generated config under `build/veer/`
  (`-set build_axi4 -set iccm_enable=0 -set icache_enable=0
  -set dccm_enable=0`): AXI4 masters, no ICCM/DCCM/ICache, so every
  fetch/load/store reaches AXI. Adapter ID widths (3/3/1) match the
  generated `el2_param.vh`.
- Ties: `rst_vec=0` (RAM base), `rst_l`/`dbg_rst_l`=TB reset,
  `mpc_reset_run_req=1`, all `*_bus_clk_en=1`, interrupts 0,
  JTAG/DMI/DMA quiet, `scan/mbist=0`, `core_id=0`. SRAM exports float
  (memories disabled).
- Compile order matters: `common_defines.vh`, `el2_def.sv` (defines
  `el2_pkg`), `el2_pdef.vh` must precede `-f flist` (see
  `Cores-VeeR-EL2/tools/Makefile` `defines`); the flist filter must drop
  only `testbench/veer_wrapper.sv`, never `design/el2_veer_wrapper.sv`.

## Checks (all required for PASS)

1. **UART console tag** — TX sampled at 1010 ns/bit (divisor 100),
   compared against the per-test tag (`GPIO OK` / `UART OK` /
   `TIMER OK`); any `FAIL` substring vetoes. Mentor-critical channel.
2. **Signature word** — `dut.u_ram.mem[0x7FF0>>2] == 'PASS'`,
   independent of UART (catches console-only illusions and trap `0xDEAD`).
3. **ebreak retire** — trace `insn == 0x00100073` **or**
   exception-valid with `ecause == 3` (breakpoint). The insn-only match
   is insufficient: `dec_i0_inst_wb` may have moved past the ebreak by
   the time the exception valid fires (verified in `el2_dec` source).
   Plus: timer run requires sticky `timer_irq_o` seen; `gpio_in` is
   driven to `8'hA5` for the input phase.

Plusargs: `+SW_TEST=gpio|uart|timer` selects the tag;
`+SW_HEX=test.hex` is consumed by `axi_ram` directly.

## Timing subtlety

`ebreak` fires microseconds after the last THR write, but the UART
still has ~160 µs of FIFO bytes to shift out. After ebreak the TB waits
(up to 5 ms) for the tag/`FAIL` to arrive instead of a fixed nap —
otherwise the monitor is killed mid-string and good tests fail the tag
check.

## Results (VCS U-2023.03, 2026-09-26)

| Test | Result |
|------|--------|
| `make sw IP=gpio` | PASS (tag + signature) |
| `make sw IP=uart` | PASS (tag + signature) |
| `make sw IP=timer` | PASS (tag + signature + irq) |

Run: `make sw IP=<ip>`. Debug: `+ADP_DEBUG` (adapter trace),
`make verdi LEVEL=sw IP=<ip>`.

## Wave views (`waves/sw_<ip>.rc`)

`make verdi LEVEL=sw IP=<ip>` recompiles with FSDB + kdb, re-sims, and
opens Verdi with `waves/sw_<ip>.rc` preloaded (`-sswr`; restore also
works via File → Restore Signal). Each file groups:

1. `clk_rst` — TB clock/reset.
2. `ifu_axi_64b` / `lsu_axi_64b` — VeeR 64-bit AXI channels at the
   `el2_veer_wrapper` pins; `sb_axi_quiet` — side-channel valids only
   (expected idle).
3. `adapter_soc32` — `u_adapter/state` plus the 32-bit master side
   (`m_*`); watch the 64→32 sub-beat splits here.
4. `trace_ebreak` — retire trace (`tr_valid/tr_insn/tr_exc/tr_cause`)
   and `saw_ebreak`.
5. `uart_m01` / `timer_m02` / `gpio_m03` — per-test peripheral group:
   TB monitors + wrapper-internal registers (`u_gpio/out_reg`,
   `u_timer/count` …) + the xbar master port (`dut/u_xbar/m0X_axi_*`)
   for that peripheral. The SoC-internal `m_axi_*[k]` fabric nets are
   alias-collapsed in the FSDB, so the wrapper ports are used instead.

All signal paths in the `.rc` files were round-trip validated (nWave
restore → save, zero missing) against the `tb_soc_sw` FSDB.

