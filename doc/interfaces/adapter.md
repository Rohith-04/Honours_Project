# Adapter — VeeR (64-bit) to SoC (32-bit) AXI

Implementation: `rtl/soc/veer_axi_adapter.sv`. 3:1 mux (LSU / IFU / SB)
plus 64-to-32 width conversion, upstream of `honours_soc.s_axi_*`.
This is the PHASE1 §0 prerequisite: lower-32-bits wiring is explicitly
not a converter; this module is the proper adaptation.

## Ports

- Three 64-bit AXI slave ports (`lsu_*`, `ifu_*`, `sb_*`): ID widths
  3 / 3 / 1 (`LSU_ID_W`, `IFU_ID_W`, `SB_ID_W`; match generated
  `el2_param.vh`: `lsu_num_nbload=4`, `icache_ln_sz=64`), 32-bit addr,
  64-bit data / 8-bit strobe, plus region/cache/prot/qos/lock sideband
  (accepted for direct VeeR wiring, ignored inside).
- One 32-bit AXI master port (`m_*`): 12-bit ID, matches the
  `honours_soc` s-port exactly.

## Translation rules

- Input is single-beat only (`awlen/arlen == 0`, INCR). Bursts,
  non-INCR, `size > 3`, or 8B-misaligned inputs complete SLVERR without
  forwarding (VeeR never sends them; the error path keeps AXI alive).
- `size == 3` (8B, must have `addr[2:0] == 0`) splits into **two**
  32-bit sub-beats: `addr` + `addr+4`, full-word halves of WDATA/WSTRB,
  RDATA reassembled `{high, low}`.
- `size < 3` forwards **one** beat on the half selected by `addr[2]`,
  original address and size preserved, so the 32-bit slave's own
  narrow/lane logic applies; reads assemble the word into the matching
  64-bit half (AXI narrow-read lane semantics).
- Sub-beats are single-beat (`len=0`, INCR) with **overlapped** AW+W
  (both held until both handshake, then wait B) — required by `ips/uart`.
  `m_bready`/`m_rready` tied high (single outstanding, never miss a beat).
- Master ID: `{6'b0, src[1:0], id4[3:0]}`, src = 00 LSU / 01 IFU / 10 SB.
  Return BID/RID from the SoC is ignored; the captured source + original
  ID is returned (exact under serialization). RESP merges worst-wins:
  DECERR > SLVERR > EXOKAY > OKAY.

## Arbitration

One 64-bit transaction outstanding at a time (reads and writes share the
single SoC port). Fixed priority: IFU_RD > LSU_RD > SB_RD > LSU_WR >
SB_WR. Slave readys deassert while busy, back-pressuring VeeR legally.
(IFU write never arbitrates — the core ties those outputs to 0.)

## Verification

Exercised by every `tb/sw` run (all VeeR fetch/data traffic passes
through it). Sim-only `+ADP_DEBUG` tracing (grants, sub-beat
handshakes, B/R captures) and held-VALID handshake assertions live in
the file under `translate_off`.
