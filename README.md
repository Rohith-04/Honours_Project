# Near-Data Accelerator Extension for a VeeR EL2 RISC-V SoC

An Honours project extending a **VeeR EL2 RV32IMC RISC-V SoC** with a custom **Near-Data Accelerator (NDA)** for memory-intensive reduction operations.

The project is a complete SoC rather than an isolated RTL block. It includes the processor, AXI4 interconnect, memory, peripherals, verification infrastructure, software tests, the NDA, Hardware Performance Monitor (HPM), and NDA watchdog (WDT).

## Project Overview

The NDA performs simple data-intensive operations close to the memory interface, eliminating the need for the CPU to load and process every element. Software configures the NDA with an address range and operation; the NDA streams the array over its own AXI4 read port, reduces it, and reports completion via interrupt and status flag.

Supported operations (32-bit signed integers):

- Sum (64-bit accumulator, no overflow for arrays that fit the data window)
- Minimum
- Maximum
- Argmax (first index wins on ties)

The main objective is to measure the actual crossover point where NDA execution beats a software loop, by comparing execution cycles, AXI bus transactions, setup and interrupt overhead, and array size. The accelerator is not assumed to be beneficial — the HPM exists to make the measurement possible, and the WDT exists to make failure safe.

**Performance model:** crossover n = b / (a − c), valid when a > c, where a is software cycles per element, c is NDA cycles per element, and b is the NDA fixed cost with no element processing.

## Architecture

### Phase 1: Baseline SoC ✓ Complete

| Block | Description |
|---|---|
| **VeeR EL2** | RV32IMC RISC-V processor core |
| **AXI4 Interconnect** | Parameterised AXI4 fabric (1×4, expandable) |
| **64 KiB AXI RAM** | Program and data memory at `0x0000_0000` |
| **UART** | Console output at `0x1000_0000` |
| **Timer** | Free-running counter with compare/match interrupt at `0x1001_0000` |
| **GPIO** | 8 bidirectional GPIO pins at `0x1002_0000` |
| **64→32 AXI Adapter** | Converts the VeeR EL2 64-bit IFU/LSU interface to the 32-bit SoC fabric |

### Phase 2: NDA, HPM, and WDT ✓ RTL and Unit Verification Complete

| Block | Base Address | Description |
|---|---|---|
| **NDA** | `0x5000_0000` | AXI4 read master + AXI4-Lite CSR slave. SUM/MIN/MAX/ARGMAX over 32-bit signed integers. Burst address generation with 4 KB boundary splitting. Configurable `BURST_LEN` and `MAX_OUTSTANDING`. |
| **WDT** | `0x5000_2000` | Progress-based NDA watchdog. Arms on busy rise, reloads on each accepted R beat. Trips after `TIMEOUT` idle cycles, sends abort pulse to NDA, increments trip counter. |
| **HPM** | `0x5000_1000` | Passive AXI monitor. 9×64-bit counters covering CPU and NDA bus activity plus NDA busy cycles and WDT fallbacks. Atomic snapshot, clear, and enable gating. |

The Phase 2 SoC uses a **2-master × 7-slave** AXI4 interconnect (or 2×6 when `ENABLE_HPM = 0`). M0 is the CPU (via width adapter), M1 is the NDA read engine. S0–S3 are the existing Phase 1 slaves; S4–S6 are the NDA, WDT, and HPM CSR regions.

## Memory Map

| Address Range | Device |
|---|---|
| `0x0000_0000` – `0x0000_FFFF` | RAM (64 KiB) |
| `0x1000_0000` – `0x1000_0FFF` | UART |
| `0x1001_0000` – `0x1001_0FFF` | Timer |
| `0x1002_0000` – `0x1002_0FFF` | GPIO |
| `0x5000_0000` – `0x5000_0FFF` | NDA CSRs |
| `0x5000_1000` – `0x5000_1FFF` | HPM CSRs |
| `0x5000_2000` – `0x5000_2FFF` | WDT CSRs |

All bases and offsets are defined exclusively in `rtl/soc/soc_pkg.sv`.

## NDA Register Map

| Offset | Name | Access | Description |
|---|---|---|---|
| `0x00` | CTRL | RW | `[0]` START (self-clearing), `[1]` ABORT (self-clearing), `[2]` IRQ_EN |
| `0x04` | STATUS | RO/W1C | `[0]` BUSY, `[1]` DONE (W1C), `[2]` ERR (W1C), `[7:4]` ERR_CODE |
| `0x08` | OP | RW | `[3:0]` 0=SUM, 1=MIN, 2=MAX, 3=ARGMAX |
| `0x0C` | SRC_BASE | RW | Array start address, 4-byte aligned |
| `0x10` | LEN | RW | Element count, nonzero |
| `0x14` | RESULT_LO | RO | SUM`[31:0]`, or the MIN/MAX/ARGMAX value |
| `0x18` | RESULT_HI | RO | SUM`[63:32]`, or the ARGMAX index |
| `0x1C` | CYCLES | RO | Cycles from START accepted to DONE or ERR |

Error codes: `BAD_LEN(1)`, `BAD_OP(2)`, `MISALIGNED(3)`, `BAD_ADDR(4)`, `BAD_RANGE(5)`, `BUS_ERROR(6)`, `ABORTED(7)`. Checks 1–5 run at START before any bus traffic.

## AXI Interconnect

The interconnect is parameterised for number of masters, number of slaves, address width, ID width, slave base addresses, and slave address ranges.

A generator script produces flattened wrappers for different M×N configurations:

```text
scripts/axi_interconnect_wrap.py
```

Phase 1 used `axi_interconnect_wrap_1x4.v`. Phase 2 uses `axi_interconnect_wrap_2x7.v` (or `_2x6` without HPM). Sideband signals (NDA handshakes, WDT abort, HPM tap wires, interrupts) remain separate from the AXI fabric.

The crossbar serialises transactions through a single FSM. With two concurrent masters, CPU and NDA traffic serialise under round-robin arbitration. CPU latency while the NDA streams is bounded by one NDA burst (`BURST_LEN`). This is a known limitation documented as part of the crossover measurement.

## Verification

Verification is organised into three levels:

```text
unit → integration → software
```

### Level 1: Unit Verification

Individual IP blocks are verified directly against the AXI master BFM.

### Level 2: Integration Verification

The complete AXI fabric is tested with all slaves present through the real interconnect.

### Level 3: Software Verification

Compiled RISC-V C runs on the VeeR EL2 core through the full SoC path.

### Verification Results

Results from **VCS U-2023.03-SP1**.

#### Phase 1 — as of 2026-09-26

| Test | Result |
|---|---|
| `make unit IP=gpio` | PASS — 17/17 checks |
| `make unit IP=timer` | PASS — 17/17 checks |
| `make unit IP=uart` | PASS — 15/15 checks |
| `make unit IP=ram` | PASS — 17/17 checks |
| `make integration` | PASS — 22 checks |
| `make sw IP=gpio` | PASS |
| `make sw IP=uart` | PASS |
| `make sw IP=timer` | PASS |

#### Phase 2 — as of 2026-10-17

| Test | Result |
|---|---|
| `make unit IP=nda` | PASS — 33/33 checks |
| `make unit IP=wdt` | PASS — 19/19 checks |
| `make unit IP=hpm` | PASS — 21/21 checks |

## AXI Master BFM

```text
bfm/axi_master_bfm.sv
```

Models the 32-bit AXI master interface. Used at Level 1 and Level 2. Supports single-beat and INCR burst reads and writes, with a configurable timeout that terminates the simulation on a stalled handshake rather than hanging.

At Level 3 the BFM is removed from the datapath and the VeeR EL2 core becomes the AXI master through the width adapter.

## Simulation

### Requirements

- Synopsys VCS, tested with `U-2023.03-SP1`
- Verdi for waveform inspection
- `riscv64-unknown-elf-gcc`
- `perl` for VeeR configuration

### Common Commands

#### Unit tests

```bash
make unit IP=gpio
make unit IP=timer
make unit IP=uart
make unit IP=ram
make unit IP=nda
make unit IP=wdt
make unit IP=hpm
```

#### Integration test

```bash
make integration
```

#### Software tests

```bash
make sw IP=gpio
make sw IP=uart
make sw IP=timer
```

#### Waveforms

```bash
make verdi LEVEL=unit IP=<ip>
make verdi LEVEL=integration
make verdi LEVEL=sw IP=<ip>
```

#### Clean build

```bash
make clean
rm -rf csrc
```

`csrc` contains shared incremental compilation state and should be removed when debugging stale build artifacts.

### Simulation Output

```text
run/<target>/sim.log
```

## Repository Structure

```text
Honours_Project/
├── Cores-VeeR-EL2/          # VeeR EL2 core source
├── ips/
│   └── uart/                # Third-party UART
├── rtl/
│   ├── soc/                 # SoC top-level, package, AXI adapter
│   ├── interconnect/        # Parameterised AXI4 interconnect (1x4, 2x6, 2x7)
│   ├── wrappers/            # Peripheral wrappers: uart, timer, gpio, nda, wdt, hpm
│   └── mem/                 # AXI RAM
├── bfm/                     # Reusable AXI4 master BFM
├── tb/
│   ├── unit/                # Level 1 tests (gpio, timer, uart, ram, nda, wdt, hpm)
│   ├── integration/         # Level 2 tests
│   └── sw/                  # Level 3 software tests
├── sw/
│   ├── common/              # Startup, linker script, drivers
│   └── *_test/              # Peripheral-specific software tests
├── scripts/                 # Build and generation scripts
├── doc/                     # Architecture, interface, and verification docs
├── run/                     # Simulation output
├── build/                   # Generated VeeR configuration
└── waves/                   # Waveform files/views
```

## Current Status

### Phase 1 — Complete

- VeeR EL2 integrated into the SoC
- Parameterised AXI4 interconnect
- 64 KiB AXI RAM
- UART integration
- Timer RTL and integration
- GPIO RTL and integration
- 64-bit to 32-bit AXI adapter
- Reusable AXI master BFM
- Unit verification (GPIO, Timer, UART, RAM)
- AXI interconnect integration verification
- Software-level peripheral verification (GPIO, UART, Timer)
- Reproducible ELF-to-hex software flow
- Centralised SoC memory map in `soc_pkg.sv`

### Phase 2 — RTL and Unit Verification Complete

- NDA reduction engine (`nda_wrapper.sv`) — SUM, MIN, MAX, ARGMAX, all error codes, burst address generation
- NDA AXI4 read master interface — AR/R channels, constant ARID, configurable burst length and outstanding depth
- NDA AXI4-Lite control interface — CSR slave with W1C status, IRQ gating, SLVERR on illegal accesses
- NDA watchdog (`wdt_wrapper.sv`) — progress-based timeout, abort pulse, trip counting
- Hardware Performance Monitor (`hpm_wrapper.sv`) — 9×64-bit counters, atomic snapshot, `ENABLE_HPM` synthesis gate
- 2-master × 7-slave AXI interconnect wrapper (generated)
- 2-master × 6-slave wrapper for `ENABLE_HPM = 0` (generated)
- SoC top-level updated to 2×7 with full sideband wiring
- `soc_pkg.sv` extended with all Phase 2 bases, offsets, and build configuration
- Unit verification: NDA (33 checks), WDT (19 checks), HPM (21 checks)

### What's Next

The following items remain to complete the project:

1. **Integration verification for Phase 2** — extend `tb/integration/tb_soc_integration.sv` to exercise NDA, WDT, and HPM through the 2×7 interconnect. Verify address decode, cross-talk, and round-robin arbitration between CPU and NDA traffic.

2. **Software driver for NDA** — write a C driver in `sw/common/` that configures the NDA over MMIO, polls or handles the IRQ, reads results, and fences appropriately. Verify `mrac` region 5 is set in `startup.S` (side-effect bit for `0x5000_xxxx`).

3. **NDA software test** — `sw/nda_test/`: run the same array through both the NDA and a software loop, compare results via UART, confirm correctness before any performance measurement.

4. **Performance crossover sweep** — use `mcycle` and HPM counters to measure NDA CYCLES, CPU cycles, and AXI transactions across varying array sizes, `BURST_LEN`, and `MAX_OUTSTANDING`. Software is crossover-unaware; it runs both paths at every size and the crossover is read off the data.

5. **WDT integration test** — inject a simulated bus stall (slave holds R off), confirm trip after `TIMEOUT`, NDA reports `ABORTED`, `TRIP_COUNT` increments, and the software fallback loop produces the correct result.

6. **HPM area comparison** — build the SoC with `ENABLE_HPM = 0` and compare the synthesis area report against the full build. Report the HPM wrapper area alone (hierarchical report) and the whole-SoC delta (includes the crossbar port).

7. **FPGA implementation** — port the SoC to the target FPGA, synthesise, and measure actual resource usage (LUTs, FFs, BRAM) and timing closure. Compare against the simulation-only memory models.

8. **Final performance analysis** — collect crossover n, decompose fixed cost b (CSR writes, startup latency, completion notice), and compare against the software cost a. Document the result as a measured trade-off, not an assumption.

## Limitations

1. The interconnect serialises transactions through a single FSM. With two concurrent masters, CPU and NDA traffic serialise under round-robin arbitration. CPU latency while the NDA streams is bounded by one NDA burst; this affects the measured crossover and is documented in the results rather than hidden.

2. Timer software testing uses polling. The timer interrupt line is observed by the testbench but is not yet serviced by software running on the core.

3. The current memory models are simulation-only. Synthesis and timing closure have not been performed.

4. The NDA data window is fixed at the 64 KiB RAM region. If the crossover point grows beyond approximately 16 K elements, a larger memory will be needed.

5. Integration verification and software-driven tests for Phase 2 blocks are not yet complete. Performance crossover results therefore do not exist yet.

## External IP and Licensing

The VeeR EL2 core is open-source hardware from Western Digital / CHIPS Alliance.

The AXI interconnect is derived from Alex Forencich's open-source AXI infrastructure and is distributed under the MIT license where indicated by the source headers.

Third-party components retain their respective licenses. Project-specific RTL and verification infrastructure are original work for this Honours project.
