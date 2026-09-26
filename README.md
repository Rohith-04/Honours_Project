# Near-Data Accelerator Extension for a VeeR EL2 RISC-V SoC

An Honours project extending a **VeeR EL2 RV32IMC RISC-V SoC** with a custom **Near-Data Accelerator (NDA)** for memory-intensive reduction operations.

The project is being developed as a complete SoC rather than as an isolated RTL block. It includes the processor, AXI4 interconnect, memory, peripherals, verification infrastructure, software tests, and the planned NDA, Hardware Performance Monitor (HPM), and watchdog.

## Project Overview

The NDA is intended to perform simple data-intensive operations close to the memory interface instead of requiring the CPU to load and process every element.

Supported/planned operations include:

- Sum
- Minimum
- Maximum
- Argmax

A software command configures the NDA with an address range and operation. The NDA then accesses the data through its AXI4 master interface and reports completion through an interrupt.

The main objective is to measure the trade-off between CPU execution and hardware acceleration rather than assume that the accelerator is automatically beneficial. The evaluation will compare:

- Execution cycles
- AXI bus transactions
- Interrupt and setup overhead
- Array size
- Hardware resource usage

The expected result is a crossover point where NDA execution becomes more efficient than the software implementation.

## Architecture

### Phase 1: Baseline SoC

The current SoC contains:

| Block | Description |
|---|---|
| **VeeR EL2** | RV32IMC RISC-V processor core |
| **AXI4 Interconnect** | Parameterised AXI4 fabric |
| **64 KiB AXI RAM** | Program and data memory at `0x0000_0000` |
| **UART** | Console output at `0x1000_0000` |
| **Timer** | Free-running counter with compare/match interrupt at `0x1001_0000` |
| **GPIO** | 8 bidirectional GPIO pins at `0x1002_0000` |
| **64→32 AXI Adapter** | Converts the VeeR EL2 64-bit IFU/LSU interface to the 32-bit SoC fabric |

The current configuration uses one AXI master and four slaves.

### Phase 2: NDA and Monitoring Hardware

The second phase adds:

| Block | Description |
|---|---|
| **NDA Reduction Engine** | AXI4 master for reading array data and performing reductions |
| **NDA Control Interface** | AXI4-Lite programming interface |
| **Hardware Performance Monitor** | Tracks cycles, bus transactions, NDA activity, and software fallback activity |
| **NDA Watchdog** | Detects stalled NDA operation and allows software fallback |

The NDA is intended to connect to the existing parameterised AXI fabric as an additional master rather than requiring a new interconnect architecture.

## AXI Interconnect

The interconnect is parameterised for:

- Number of masters
- Number of slaves
- Address width
- ID width
- Slave base addresses
- Slave address ranges

The current SoC uses a **1-master × 4-slave** configuration with **12-bit AXI IDs**.

A generator script produces flattened wrappers for different M×N configurations:

```text
scripts/axi_interconnect_wrap.py
```

The crossbar uses store-and-forward buffering with skid buffers on the datapath.

Signals that are not part of the AXI transaction itself, such as NDA handshakes, watchdog status, HPM observation signals, and interrupts, remain separate sideband signals.

## Verification

Verification is organised into three levels:

```text
unit → integration → software
```

### Level 1: Unit Verification

Individual IP blocks are verified through their wrappers using a reusable AXI master BFM.

Current unit tests cover:

- GPIO
- Timer
- UART
- RAM

### Level 2: Integration Verification

The complete AXI fabric is tested for:

- Address decoding
- Cross-talk between slaves
- Back-to-back transactions
- DECERR responses
- Recovery after an error

### Level 3: Software Verification

Compiled RISC-V software is executed on the VeeR EL2 core.

Tests verify the complete path:

```text
C program
   ↓
RISC-V compiler
   ↓
VeeR EL2
   ↓
64→32 AXI adapter
   ↓
AXI interconnect
   ↓
Peripheral / RAM
```

Software tests currently check console output, signature values, and `ebreak` retirement. The timer test also observes its interrupt line.

### Verification Results

Results below are from **VCS U-2023.03-SP1**, as of **2026-09-26**.

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

## AXI Master BFM

The reusable BFM is located at:

```text
bfm/axi_master_bfm.sv
```

It models the 32-bit AXI master interface used by the SoC fabric.

The BFM supports the transaction patterns required by the current IP and RAM tests. It also includes a timeout so that a stalled transaction terminates the simulation instead of hanging indefinitely.

At the software-verification level, the BFM is removed from the datapath and the VeeR EL2 core becomes the actual AXI master through the width adapter.

## Simulation

### Requirements

The current verification environment requires:

- Synopsys VCS, tested with `U-2023.03-SP1`
- Verdi for waveform inspection
- `riscv64-unknown-elf-gcc`
- `perl` for VeeR configuration

The RISC-V toolchain is expected to be available through `PATH`. The build also falls back to:

```text
/opt/riscv
```

when required.

### Common Commands

#### Unit tests

```bash
make unit IP=gpio
make unit IP=timer
make unit IP=uart
make unit IP=ram
```

#### Integration test

```bash
make integration
```

For the interconnect path monitor:

```bash
make integration DEFINES=+define+SOC_DEBUG
```

#### Software tests

```bash
make sw IP=gpio
make sw IP=uart
make sw IP=timer
```

These commands build the software image, boot the VeeR EL2 core, and check the expected console output, signature, and `ebreak` retirement.

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

`csrc` contains shared incremental compilation state and may need to be removed when debugging stale build artifacts.

### Simulation Output

Simulation logs are written to:

```text
run/<target>/sim.log
```

Debug tracing can be enabled through plusargs without rebuilding:

```text
+ADP_DEBUG
+XBAR_DEBUG
```

## Repository Structure

```text
Honours_Project/
├── Cores-VeeR-EL2/          # VeeR EL2 core source
├── ips/
│   └── uart/                # Third-party UART
├── rtl/
│   ├── soc/                 # SoC top-level, package, AXI adapter
│   ├── interconnect/        # Parameterised AXI4 interconnect
│   ├── wrappers/            # Peripheral wrappers and protocol glue
│   └── mem/                 # AXI RAM
├── bfm/                     # Reusable AXI4 master BFM
├── tb/
│   ├── unit/                # Level 1 tests
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

### Completed

- VeeR EL2 integrated into the SoC
- Parameterised AXI4 interconnect
- 64 KiB AXI RAM
- UART integration
- Timer RTL and integration
- GPIO RTL and integration
- 64-bit to 32-bit AXI adapter
- Reusable AXI master BFM
- Unit verification
- AXI interconnect integration verification
- Software-level peripheral verification
- Reproducible ELF-to-hex software flow
- Centralised SoC memory map

### In Progress / Planned

- NDA reduction engine
- NDA AXI4 master interface
- NDA AXI4-Lite control interface
- Hardware Performance Monitor
- NDA watchdog
- Two-master AXI configuration
- Software driver for NDA operations
- Software versus NDA performance measurements
- FPGA implementation
- Hardware resource and timing measurements

## Limitations

The current implementation has several known limitations:

1. The interconnect currently serialises transactions through a single FSM. This is sufficient for the current single-master configuration but will need to be revisited when the NDA becomes a concurrent second master.

2. Timer software testing currently uses polling. The timer interrupt line is observed by the testbench but is not yet serviced by software running on the core.

3. The current memory models are simulation-only. Synthesis and timing closure have not yet been performed.

4. The NDA, HPM, and watchdog are planned Phase 2 hardware. Performance crossover results therefore do not exist yet.

## External IP and Licensing

The VeeR EL2 core is open-source hardware from Western Digital / CHIPS Alliance.

The AXI interconnect is derived from Alex Forencich's open-source AXI infrastructure and is distributed under the MIT license where indicated by the source headers.

Third-party components retain their respective licenses. Project-specific RTL and verification infrastructure are original work for this Honours project.
