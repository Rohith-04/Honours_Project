# SoC Architecture (Phase 1 Baseline)

`rtl/soc/honours_soc.sv` — instantiate-only top. One 32-bit AXI4 master
port in, 1x4 interconnect, four slaves (RAM / UART / Timer / GPIO).
No behavioral logic in this file, by construction.

## Block view

```
              +----------------------------- honours_soc ----------------------------+
              |                                                                      |
 master (BFM  |   +--------+   m00(RAM)    +---------+                                |
  @L1/L2,     |   |  1x4   |---------------| axi_ram |                                |
  VeeR-side   +-->| xbar   |   m01(UART)   +---------+   uart_tx_o / uart_rx_i        |
  adapter @L3)     |        |---------------| uart_wrapper  |---- irq_o           |
              |   |        |   m02(TIMER)  +---------+   timer_irq_o                |
              |   |        |---------------| timer_wrapper ------------------------+ |
              |   |        |   m03(GPIO)   +---------+   gpio_in/out[7:0]           |
               |   +--------+---------------| gpio_wrapper  |                      |
              +----------------------------------------------------------------------+

Level 3 path (see doc/verification/sw.md): real VeeR EL2 (64-bit
LSU/IFU/SB, ICCM/DCCM/ICache off) -> veer_axi_adapter (3:1 mux +
64-to-32, doc/interfaces/adapter.md) -> honours_soc.s_axi_* above.
SW stack: doc/architecture/sw.md.
```

## Memory map

See `soc_pkg.sv` (single source of truth) and `PHASE1.md` §0. Summary:
RAM `0x0000_0000` (64 KiB); UART `0x1000_0000`; Timer `0x1001_0000`;
GPIO `0x1002_0000` (each 4 KiB window).

## Clock / reset

- Single 100 MHz clock everywhere in Phase 1 (UART baud domain tied to
  it; matches the IP's 100 MHz default).
- Active-low `aresetn` is the internal standard; converted at wrapper
  boundaries for active-high-`rst` blocks (interconnect core).
- VeeR `rst_l` (active-low, async-assert/sync-deassert) arrives with the
  core at Level 3; TBs deassert synchronously via `soc_reset`.

## Growth seams (parameterized, not built)

- `S_COUNT`/`M_COUNT` real parameters, instantiated 1x4; NDA becomes a
  second master later by parameter bump + connection.
- WDT, HPM, NDA are fully deferred (whole IPs, not shells).
