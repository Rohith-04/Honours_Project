# AXI4 Interconnect — Honours Project

## Overview

This project implements and verifies a parameterised AXI4 interconnect fabric as part of
an Honours degree research project. The interconnect is the central infrastructure
component of a custom SoC that integrates three novel IP blocks: an NDA Reduction Engine,
an NDA Watchdog, and a Hardware Performance Monitor (HPM).

The interconnect routes AXI4 transactions between an arbitrary number of master and slave
interfaces using a centralised round-robin arbiter and address-decode state machine. The
5-master, 16-slave configuration (axi_interconnect_wrap_5x16) is the target variant for
this SoC.

## Repository Layout

```
Project/
  doc/                          Design documentation and signal lists
    Signal_List.md              Custom IP signal definitions (NDA, Watchdog, HPM)
    tb_axi_interconnect_5x16.md Testbench documentation
    Block diagram with Signal List.pdf
    Honours_Abstract.pdf

  rtl/
    interconnect/
      axi_interconnect.v        Parameterised AXI4 interconnect core (Alex Forencich)
      arbiter.v                 Round-robin arbiter with blocking and acknowledge
      priority_encoder.v        Leading-one priority encoder used by the arbiter

  run/
    axi_interconnect_wrap_5x16.v  Auto-generated 5x16 port-flattened wrapper
    axi_interconnect_wrap_4x4.v   Auto-generated 4x4 variant (reference)
    filelist.f                  Verdi elaboration file list
    run.tcl                     UCLi script (run + quit)
    run_sim.sh                  Top-level compile and simulation script
    wave.rc                     Verdi nWave signal restore file

  scripts/
    axi_interconnect_wrap.py    Python wrapper generator for arbitrary MxN configurations

  tb/
    tb_axi_interconnect_5x16.sv  SystemVerilog testbench (VCS + Verdi)
```

## Design Description

### Interconnect Core

The core module (`axi_interconnect.v`) implements a non-pipelined, store-and-forward
crossbar with the following architecture:

- A single 8-state FSM handles one transaction at a time per arbitration slot
  (STATE_IDLE, STATE_DECODE, STATE_WRITE, STATE_WRITE_RESP, STATE_WRITE_DROP,
  STATE_READ, STATE_READ_DROP, STATE_WAIT_IDLE)
- A round-robin arbiter (`arbiter.v`) with blocking-acknowledge serialises competing
  master requests; write and read channels are arbitrated independently
- Address decode is performed combinationally against a configurable base-address and
  address-width table; out-of-range accesses return DECERR (bresp/rresp = 2'b11)
- Skid buffers on the W and R data paths decouple the upstream and downstream ready
  signals to avoid combinational ready loops

### Wrapper Generator

`scripts/axi_interconnect_wrap.py` generates a Verilog wrapper for any MxN configuration.
The wrapper unpacks and repacks the flat concatenated port vectors of the core into
individually named AXI ports (s00_axi_*, m00_axi_*, ...) as required by most SoC
integration flows.

### SoC Context

The interconnect connects the following masters and slaves in the full SoC:

| Port   | Role                          |
|--------|-------------------------------|
| s00    | CPU AXI master                |
| s01    | NDA Reduction Engine (data)   |
| s02-04 | Reserved / future expansion   |
| m00-15 | Peripheral and memory slaves  |

Custom IP signals that sit outside the AXI bus (NDA/Watchdog handshakes, HPM snoop tap,
interrupt lines) are documented in `doc/Signal_List.md`.

## Simulation

### Requirements

- Synopsys VCS (tested: VCS U-2023.03-SP1)
- Synopsys Verdi (tested: U-2023.03-SP1)

### Running the Simulation

All commands are run from the project root.

Compile and simulate:

```
./run/run_sim.sh
```

Compile, simulate, and open Verdi with the pre-configured waveform view:

```
./run/run_sim.sh gui
```

Remove all build artefacts:

```
./run/run_sim.sh clean
```

Logs are written to `run/compile.log` and `run/sim.log`. The FSDB waveform is written to
`run/tb_axi_interconnect_5x16.fsdb`.

### Waveform View

The file `run/wave.rc` is a Verdi nWave signal restore file. It pre-loads the following
signal groups: Clock & Reset, Master 0 AW/W/B, Master 0 AR/R, Slave 0 AW/W/B,
Slave 0 AR/R, and Arbiter. It is loaded automatically by `run_sim.sh gui` via the
`-sswr` flag.

## Test Plan

The testbench (`tb/tb_axi_interconnect_5x16.sv`) covers five test cases:

| TC | Description                                           | Transactions |
|----|-------------------------------------------------------|-------------|
| 1  | Single write + read, all 5 masters x 16 slaves        | 160          |
| 2  | Back-to-back INCR bursts (len=7) with read-back verify| 16           |
| 3  | Decode error: out-of-bounds address (DECERR expected) | 2            |
| 4  | Round-robin fairness: 5 masters concurrent to slave 0 | 5            |
| 5  | Partial write-strobe write with read-back verify      | 3            |

A scoreboard with a sparse reference memory model checks every read response against the
expected value derived from preceding writes.

## Current Status

| Item                          | Status                          |
|-------------------------------|---------------------------------|
| Interconnect RTL              | Complete                        |
| Wrapper generator (5x16)      | Complete                        |
| Testbench (TC1-TC5)           | Complete                        |
| Simulation (VCS)              | Passing — 96/96 checks, 0 fails |
| Waveform debug (Verdi)        | Working                         |
| NDA Reduction Engine RTL      | In progress                     |
| NDA Watchdog RTL              | In progress                     |
| Hardware Performance Monitor  | In progress                     |
| Full SoC integration          | Not started                     |
| Synthesis / timing closure    | Not started                     |

## Known Limitations

- The interconnect serialises all transactions through a single FSM. There is no
  concurrent multi-master throughput; a second master must wait for the current
  transaction to reach STATE_WAIT_IDLE before arbitration runs again.
- The testbench slave BFM uses SystemVerilog associative arrays for memory, which are
  not synthesisable. They are simulation-only constructs.
- TC4 verifies absence of deadlock under concurrent access but does not measure or
  assert the arbitration order quantitatively.

## Dependencies and Licensing

The interconnect core (`rtl/interconnect/`) is derived from the open-source work of
Alex Forencich and is used under the MIT License. See the file header in
`rtl/interconnect/axi_interconnect.v` for the full licence text.

All other files in this repository are original work produced for the Honours project.
