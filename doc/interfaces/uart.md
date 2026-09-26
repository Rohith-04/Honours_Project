# UART — Interface Documentation

Wrapper: `rtl/wrappers/uart_wrapper.sv` around the untouched
`ips/uart` core (`axi_uart_top`). Base `0x1000_0000` (`soc_pkg::UART_BASE`).

## Pattern

Wrap-only. The third-party IP is never edited; the wrapper is pure
pass-through of the AXI handshake plus clock/reset handling. The IP's
native register map is exposed directly (no CSR remapping).

## Register map (byte offsets from UART_BASE)

| Offset | Reg   | Access | Function                                              |
|--------|-------|--------|-------------------------------------------------------|
| `0x00` | RBR   | R      | RX data byte (read; **each read PULLS the RX FIFO**)  |
| `0x00` | THR   | W      | TX data byte (write pushes TX FIFO)                   |
| `0x04` | IER   | R/W    | IRQ enable, bit 0 (must be 1 for LSR DATA_READY)      |
| `0x08` | BAUD  | R/W    | Baud divisor (writable only when LCR[7] DLAB = 1)     |
| `0x0C` | LCR   | R/W    | Line control: [2]=2-stop, [3]=parity en, [4]=parity mode, [7]=DLAB |
| `0x14` | LSR   | R      | Line status: [0]=DATA_READY, [5]=THRE, [6]=TEMT       |

Reset: LCR = 0 (8N1, DLAB = 0), IER = 0, divisor = 868 (115200 baud at
100 MHz). Standard setup: `LCR=0x80` → `BAUD=100` → `LCR=0x03` → `IER=1`.

## Clocks / reset / bus

- Both `fixed_clk_i` (baud domain) and `axi_aclk_i` tied to the SoC clock
  (100 MHz, matching the IP's `_UART_MAIN_CLOCK_FREQ_`).
- Active-low `aresetn` straight to the IP. ID width 12 end-to-end.
- AXI4-Lite slave behavior; the wrapper **assumes single-beat**
  (`awlen/arlen == 0`) and ignores len/size/burst qualifiers.
- The IP keys writes off `awvalid & wvalid` asserted **together** — the
  BFM overlaps AW+W and drops them the cycle bvalid appears (holding
  longer double-pushes THR; same-cycle drop is mandatory, not optional).
  AR is held until rvalid for the same reason (RBR double-pull).

## Timing notes (divisor = 100 @ 100 MHz)

- TX bit time ≈ (div+1) clocks = 1010 ns; RX samples at (div−1).
  ~1% mismatch is reliable; do not use tiny divisors.
- LSR `DATA_READY` = RX-byte-available **AND** `IER[0]` — an RX test with
  `IER = 0` will never see data-ready (verified in IP source).
- Pins: `uart_tx_o` (idle high), `uart_rx_i`, `uart_irq_o` (RX interrupt,
  currently unused by SW).

## Verification

`tb/unit/tb_uart_unit.sv`: config resps, TX byte sampled on the wire,
LSR THRE/TEMT, direct-drive RX byte, loopback TX→RX match.
