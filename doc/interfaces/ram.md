# RAM — Interface Documentation

Implementation: `rtl/mem/axi_ram.sv`. 64 KiB AXI4 RAM, simulation model
and SW backing store (instructions + data + stack). Base `0x0000_0000`,
size `soc_pkg::RAM_BYTES`.

## Bus behavior

- 32-bit data, 12-bit ID, active-low `aresetn`, always-ready slave
  (`awready/arready/wready` tied high — legal and deadlock-free behind
  the interconnect's skid buffers).
- **INCR bursts** with sizes 0–2 (1/2/4 bytes), strobe-accurate, with
  narrow-transfer lane masking on reads (data on aligned lanes).
- FIXED/WRAP bursts and size > 2 complete with **SLVERR** (beats still
  consumed so the protocol stays alive).
- Word-indexed storage; out-of-range beats within a burst read as zero /
  drop writes.

## Image preload

- `HEX_FILE` string parameter, else `+SW_HEX=<path>` plusarg
  (`$readmemh`). SW-driven tests use the plusarg; default is zero-filled.

## Verification

No standalone unit TB (memory model, not custom logic — per PHASE1).
Exercised by every integration test (RAM write/read at `RAM_BASE`) and
implicitly by all SW tests.
