# Timer — Interface Documentation

Implementation: `rtl/wrappers/timer_wrapper.sv`. Fully custom RTL, no
external `ips/` source — this file **is** the peripheral, not CSR glue.
Base `0x1001_0000` (`soc_pkg::TIMER_BASE`).

## Register map (byte offsets from TIMER_BASE)

| Offset | Reg     | Access | Function                                             |
|--------|---------|--------|------------------------------------------------------|
| `0x00` | CTRL    | R/W    | [0]=enable; [1]=match sticky flag (**W1C**); rest RAZ |
| `0x04` | COUNT   | R/W    | Current count (write = reload)                       |
| `0x08` | COMPARE | R/W    | Match value                                          |

Reset: all zero, `irq_o` low.

## Behavior

- Free-running 32-bit counter, +1 per clock while `enable`.
- When enabled and `COUNT == COMPARE`, `match` sets and `irq_o` asserts
  (level = `match & enable`). Clear with W1C of `CTRL[1]`; disabling also
  drops `irq_o` (flag itself holds until W1C).
- `COUNT` writes take effect immediately (reload); safe to reload while
  disabled for deterministic tests.

## Bus / reset

- Single-beat AXI4 slave (12-bit ID, active-low `aresetn`).
- Bursts (`len != 0`), out-of-range offsets, and undefined sub-words
  complete with **SLVERR**; legal transfers return OKAY.

## Verification

`tb/unit/tb_timer_unit.sv`: reset values, reload determinism while
disabled, free-run to `COMPARE = 100` with `irq_o` + flag, W1C clear,
count-holds-while-disabled, bad-offset SLVERR.
