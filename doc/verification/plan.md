# Verification Plan — Status (Phase 1)

Ladder per IP: `unit` → `integration` → `sw`. An IP is done only when all
three pass. Conventions: `TESTBENCH_CONVENTIONS.md`. Tool: VCS U-2023.03.
Doc map: architecture in `doc/architecture/` (SoC, SW stack),
interfaces in `doc/interfaces/` (per-slave + adapter + interconnect),
rung details in `doc/verification/sw.md`, bring-up history in
`doc/verification/debug.md`.

## Rung 1 — unit (BFM -> wrapper, no interconnect, no core)

| Test | DUT | Status |
|------|-----|--------|
| `tb/unit/tb_gpio_unit.sv` | `gpio_wrapper` | written, awaiting sim |
| `tb/unit/tb_timer_unit.sv` | `timer_wrapper` | written, awaiting sim |
| `tb/unit/tb_uart_unit.sv` | `uart_wrapper` + `ips/uart` | written, awaiting sim |

Run: `make unit IP=gpio|timer|uart` (from repo root).

## Rung 2 — integration (BFM -> honours_soc, no core)

| Test | DUT | Status |
|------|-----|--------|
| `tb/integration/tb_soc_integration.sv` | interconnect + 4 slaves + RAM | **PASS (22 checks, 2026-09-26)** |

Run: `make integration`. Asserts decode per slave, cross-talk,
back-to-back, DECERR on `0x2000_0000` (R+W) and `0x0001_0000`,
post-error health. Probe: `make integration DEFINES=+define+SOC_DEBUG`.

## Rung 3 — sw (real VeeR + C, only place the core appears)

| Test | Status |
|------|--------|
| `make sw IP=gpio` | **PASS** (console tag + signature) |
| `make sw IP=uart` | **PASS** (console tag + signature) |
| `make sw IP=timer` | **PASS** (console tag + signature + irq seen) |

Full detail: `doc/verification/sw.md` (harness, triple check, VeeR
config, timing). Bring-up order was `gpio` → `uart` → `timer`
(poll-only, no VeeR IRQ plumbing yet).

## What Rung 3 caught (fixed, see `doc/verification/debug.md`)

- Arbiter grant-hold body missing → every read misdirected into WRITE.
- Floating RLAST on UART/Timer/GPIO → first peripheral read parks the
  xbar in READ (master-side check still passes; next op hangs).
- Removed WRITE→READ divert was only papering over the first bug.

## Known TB sensitivities (do not "fix" by loosening)

- UART BFM discipline: overlapped AW+W held to bvalid, same-cycle drop
  (double-push/double-pull otherwise). In `bfm/axi_master_bfm.sv`.
- RBR reads pull the RX FIFO: exactly one read per expected byte; LSR
  is safe to poll; drain between phases.
- TX/RX baud asymmetry (`div+1` vs `div-1`): divisor 100, TX sampled at
  1010 ns/bit, RX driven at 1000 ns/bit.
- RX `DATA_READY` requires `IER = 1`.
- SW ebreak detect needs trace exception `ecause==3`, not just
  `insn==ebreak` (`inst_wb` moves on before the exception valid fires).
- After RTL edits: `make clean && rm -rf csrc` before rebuilding —
  `./csrc` silently reuses stale objects (`-nc` does not prevent this).
