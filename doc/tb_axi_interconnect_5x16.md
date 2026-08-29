# tb_axi_interconnect_5x16 — Testbench Documentation

## Overview

This document describes the VCS + Verdi testbench for the **5-master × 16-slave AXI4 interconnect** generated from `scripts/axi_interconnect_wrap.py`.

| Item | Value |
|---|---|
| DUT | `axi_interconnect_wrap_5x16` |
| Masters (slave ports on DUT) | 5 |
| Slaves (master ports on DUT) | 16 |
| DATA_WIDTH | 32 bits |
| ADDR_WIDTH | 32 bits |
| ID_WIDTH | 8 bits |
| Slave address window | 24-bit (16 MB each) |
| Total address space | 0x0000_0000 – 0x0FFF_FFFF (256 MB) |
| Arbiter type | Round-robin (blocking, acknowledge-based) |
| Simulator | Synopsys VCS |
| Waveform viewer | Synopsys Verdi (FSDB) |

---

## File Structure

```
Project/
├── rtl/interconnect/
│   ├── axi_interconnect.v        # Core interconnect RTL
│   ├── arbiter.v                 # Round-robin arbiter
│   └── priority_encoder.v       # Priority encoder
├── scripts/
│   └── axi_interconnect_wrap.py # Jinja2 wrapper generator
├── run/
│   ├── axi_interconnect_wrap_5x16.v  # Generated 5×16 wrapper
│   ├── run_sim.sh                    # VCS compile + sim driver
│   ├── run.tcl                       # UCLi script (run + quit)
│   ├── wave.rc                       # Verdi waveform config
│   └── filelist.f                    # Source list for Verdi -f
├── tb/
│   └── tb_axi_interconnect_5x16.sv  # This testbench
└── doc/
    └── tb_axi_interconnect_5x16.md  # This document
```

---

## How to Run

### Compile and simulate (no GUI)
```bash
cd Project
./run/run_sim.sh
```

### Compile, simulate, and open Verdi
```bash
./run/run_sim.sh gui
```

### Clean build artefacts
```bash
./run/run_sim.sh clean
```

Logs are written to `run/compile.log` and `run/sim.log`.  
The FSDB waveform is written to `run/tb_axi_interconnect_5x16.fsdb`.

---

## Address Map

Each slave port receives a 24-bit (16 MB) window. Base addresses are auto-computed by the interconnect core's `calcBaseAddrs` function (contiguous, aligned):

| Slave | Base address | End address |
|---|---|---|
| 0 | 0x0000_0000 | 0x00FF_FFFF |
| 1 | 0x0100_0000 | 0x01FF_FFFF |
| 2 | 0x0200_0000 | 0x02FF_FFFF |
| 3 | 0x0300_0000 | 0x03FF_FFFF |
| 4 | 0x0400_0000 | 0x04FF_FFFF |
| 5 | 0x0500_0000 | 0x05FF_FFFF |
| 6 | 0x0600_0000 | 0x06FF_FFFF |
| 7 | 0x0700_0000 | 0x07FF_FFFF |
| 8 | 0x0800_0000 | 0x08FF_FFFF |
| 9 | 0x0900_0000 | 0x09FF_FFFF |
| 10 | 0x0A00_0000 | 0x0AFF_FFFF |
| 11 | 0x0B00_0000 | 0x0BFF_FFFF |
| 12 | 0x0C00_0000 | 0x0CFF_FFFF |
| 13 | 0x0D00_0000 | 0x0DFF_FFFF |
| 14 | 0x0E00_0000 | 0x0EFF_FFFF |
| 15 | 0x0F00_0000 | 0x0FFF_FFFF |

Addresses ≥ 0x1000_0000 are out-of-range and produce a decode error response.

---

## Architecture

### Interconnect type
The DUT is a **shared-bus interconnect**, not a crossbar. Only one transaction is in flight at a time. The arbiter serialises competing requests from all 5 masters across both read and write channels.

### Arbiter
The arbiter operates on `S_COUNT × 2 = 10` request lines (one write + one read per master). The grant encoding packs master index in the upper bits and a read/write flag in bit 0:

```
grant_encoded[CL_S_COUNT:1] = s_select  (which master)
grant_encoded[0]             = read      (1=read, 0=write)
```

### State machine
Eight states in the interconnect core:

| State | Description |
|---|---|
| IDLE | Wait for arbiter grant |
| DECODE | Look up slave index from address |
| WRITE | Forward W-channel beats to selected slave |
| WRITE_RESP | Wait for B-channel from slave, forward to master |
| WRITE_DROP | Drop W beats for undecodable address, return SLVERR |
| READ | Forward R-channel beats from slave to master |
| READ_DROP | Generate DECERR read beats for undecodable address |
| WAIT_IDLE | Wait until grant is released before returning to IDLE |

---

## Testbench Structure

### Slave BFM
Each of the 16 slave ports has a synthesisable RTL slave BFM (`slv_wr_bfm` / `slv_rd_bfm` generate blocks). Each BFM:
- Maintains a `logic [31:0] slave_mem[MEM_WORDS]` array (16 MB of storage).
- Accepts AW immediately (`awready = 1` after reset).
- Accepts W beats with byte-enable awareness.
- Returns `OKAY` B-response after `wlast`.
- Accepts AR immediately and streams R beats with correct `rlast`.

### Scoreboard
A software reference model mirrors every write the testbench issues into `ref_mem[slave][word]`. On every read, `sb_check` compares the returned data against the reference and increments `pass_count` or `fail_count` accordingly. A mismatch prints a `$error` line with master port, address, expected, and actual values.

### Master BFM tasks

| Task | Description |
|---|---|
| `axi_write(mp, addr, data, strb, id)` | Single-beat write from master port `mp` |
| `axi_read(mp, addr, data, id)` | Single-beat read from master port `mp` |
| `axi_burst_write(mp, addr, len, id)` | INCR burst write, `len+1` beats of random data |

All tasks are blocking and drive/sample signals using the `@(posedge clk); #1;` pattern to ensure clean setup/hold timing.

---

## Test Cases

### TC1 — Single write + read, all master × slave combinations
- Every master (0–4) performs a single-beat write then read to one address in every slave window (0–15).
- Total: 80 write + 80 read transactions.
- Pass criterion: all read-back values match the scoreboard reference.

### TC2 — Back-to-back burst (INCR, len=7)
- Master 0 issues an 8-beat INCR burst write to slave 3.
- Each beat carries a random data word; the scoreboard records all 8.
- Reads back each beat individually and checks against the reference.
- Pass criterion: all 8 read values match.

### TC3 — Decode error (out-of-bounds address)
- Master 0 attempts a write and a read to address `0x2000_0000`, which is outside all 16 slave windows.
- Pass criterion:
  - Write response `bresp ≠ 2'b00` (SLVERR or DECERR).
  - Read response `rresp ≠ 2'b00`.

### TC4 — Round-robin fairness
- All 5 masters issue writes to distinct addresses within slave 0 simultaneously (SystemVerilog `fork/join`).
- Pass criterion: all 5 writes complete without deadlock (fork/join returns).
- Verifies the arbiter correctly rotates among all masters rather than starving any one.

### TC5 — Partial wstrb write and read-back
- Master 0 writes `0xFFFF_FFFF` with `wstrb=4'hF` to an address in slave 5.
- Then writes `0x0000_00AA` with `wstrb=4'b0001` (byte 0 only).
- Read back should return `0xFFFF_FFAA`.
- Pass criterion: scoreboard check passes.

---

## Waveform Groups (Verdi)

The `wave.rc` script pre-configures the following signal groups on Verdi startup:

| Group | Signals |
|---|---|
| Clock & Reset | `clk`, `rst` |
| DUT State | `state_reg` inside the interconnect core |
| Master 0 (AW/W/B) | All AW, W, and B channel signals for master port 0 |
| Master 0 (AR/R) | All AR and R channel signals for master port 0 |
| Slave 0 (AW/W/B) | All AW, W, and B channel signals for slave port 0 |
| Slave 0 (AR/R) | All AR and R channel signals for slave port 0 |
| Arbiter | `grant`, `grant_valid`, `grant_encoded` |

To add more signals in Verdi: drag from the signal browser, or use `wvAddSignal` in the Tcl console.

---

## Pass / Fail Criteria

The simulation prints a final summary:

```
============================================
  SIMULATION COMPLETE
  PASS : <N>
  FAIL : <N>
  RESULT: ALL TESTS PASSED
============================================
```

Exit status is 0 (VCS `$finish`) regardless of test result; check `FAIL : 0` in the log or grep for `$error` lines. Any `$error` call also increments the VCS error count which is reported in `sim.log`.

---

## Known Limitations

- The slave BFM always responds with `OKAY`; it does not model `SLVERR` from the slave side.
- The BFM does not model FIXED or WRAP burst types — only INCR is tested.
- The interconnect is shared-bus, so only one transaction is in-flight at once; true concurrent throughput testing is not applicable.
- `USER` sideband signals are tied to zero throughout; they are not verified.
