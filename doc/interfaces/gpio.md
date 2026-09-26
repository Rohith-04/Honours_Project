# GPIO — Interface Documentation

Implementation: `rtl/wrappers/gpio_wrapper.sv`. Fully custom RTL, no
external `ips/` source. Base `0x1002_0000` (`soc_pkg::GPIO_BASE`).
8 pins (`soc_pkg::GPIO_WIDTH`); registers carry them in the low bits,
upper bits RAZ/WI.

## Register map (byte offsets from GPIO_BASE)

| Offset | Reg | Access | Function                              |
|--------|-----|--------|---------------------------------------|
| `0x00` | OUT | R/W    | Output values (low 8 bits)            |
| `0x04` | IN  | R      | Synchronized input pins (**writes get SLVERR**) |
| `0x08` | DIR | R/W    | Per-bit direction, 1 = output         |

Pins: `gpio_out = OUT & DIR`. Reset: all zero (all inputs, outputs low).
`IN` passes through one sync flop (2-cycle margin in tests).

## Bus / reset

- Single-beat AXI4 slave (12-bit ID, active-low `aresetn`).
- Bursts, out-of-range offsets, and writes to `IN` complete with SLVERR.

## Verification

`tb/unit/tb_gpio_unit.sv`: DIR/OUT programming with pin checks (masked
and full), register readbacks, driven-pin `IN` readback, RO-write and
bad-offset SLVERR. Brought up first as the simplest end-to-end ladder
proof.
