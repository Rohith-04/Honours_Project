# Near-Data Accelerator Extension for a VeeR EL2 RISC-V SoC

An Honours project extending a **VeeR EL2 RV32IMC RISC-V SoC** with a custom **Near-Data Accelerator (NDA)** for memory-intensive reduction operations.

The project is a complete SoC rather than an isolated RTL block. It includes the processor, AXI4 interconnect, memory, peripherals, verification infrastructure, software tests, the NDA, Hardware Performance Monitor (HPM), and NDA watchdog (WDT).

**Phase 2 directed correctness baseline (2026-10-31):** RTL fixes, unit and
integration verification, and NDA/HPM/WDT software tests on VeeR are complete.
Run `make phase2` and `make phase2 HPM=0`. See
[the Phase 2 verification record](doc/verification/phase2.md) for coverage,
software interrupts, HPM enable semantics, commands and recovery limits.
Performance measurements remain deferred. **GPIO UVM verification was added
on 2026-11-07:** separate active standalone and software-driven passive flows
are available under `uvm/`. See [GPIO UVM verification](#gpio-uvm-verification)
and [the passive software flow](uvm/gpio_sw/README.md).

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
| **GPIO** | 8-bit GPIO with split inputs and direction-masked outputs at `0x1002_0000` |
| **64→32 AXI Adapter** | Converts the VeeR EL2 64-bit IFU/LSU interface to the 32-bit SoC fabric |

### Phase 2: NDA, HPM, and WDT — Directed Baseline Through Software

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

The crossbar serialises transactions through a single FSM, with round-robin
arbitration across AW/AR request entries. Ownership lasts through the response
handshake. `BURST_LEN` limits the beats in one NDA burst; CPU wait time also
depends on competing requests, slave response latency and backpressure, so
this is not an unconditional clock-cycle latency bound.

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

### GPIO UVM Verification

The project currently has one per-IP UVM VIP, for GPIO, with two separately
selectable environments. Both use the installed VCS UVM 1.2 library, typed
SystemVerilog interfaces, factory creation and `uvm_config_db::set/get`.

| Flow | Stimulus owner | UVM checking |
|---|---|---|
| Active standalone (`uvm/gpio/`) | UVM bus and pin drivers directly exercise `gpio_wrapper` | Protocol assertions, pin/register scoreboard, coverage |
| Software-driven passive (`uvm/gpio_sw/`) | C executes on VeeR through the width adapter and SoC fabric | Passive GPIO monitor/scoreboard, protocol assertions, software completion |

In active mode, independent AW/W/B/AR/R driver workers support queued requests
and channel overlap. The six tests cover registers, pins, strobes, invalid
accesses, response backpressure, a factory override, and GPIO plan cases
SOC-027/028/029. Plan tests add a resolved digital-pad model for loopback and
intentional contention, with an explicit simulation-only DIR/OE probe.

In passive mode, the agent creates **no drivers or sequencers**. Its virtual
AXI interface contains read-only observation copies from the GPIO slave port;
CPU fetches, RAM and UART traffic are excluded from the GPIO model. C performs
register comparisons, while UVM independently checks observed accesses and
pin behavior. `cfg` supplies interface handles/settings, not transaction data.

The software path is:

```text
C program → ELF → RAM hex image → VeeR executes loads/stores
         → 64-to-32 adapter → interconnect → GPIO
                                            ↓
                                 passive monitor → scoreboard
```

The preserved `sw/gpio_test/main.c` checks DIR, OUT patterns and IN=`0xA5`.
The separate `sw/gpio_uvm_test/main.c` adds reset/upper-bit checks, walking-one,
walking-zero, alternating/zero/ones patterns and per-bit direction switching.
Each program runs in its own simulation. Both perform C-side comparisons and
return zero only when those comparisons pass. `startup.S` converts the return
value into a RAM status marker at `0x7FF0`: `0x50515353` for success or `0xDEAD`
for failure. UVM also requires the UART success tag, ebreak observation and
clean independent checking; the marker alone cannot establish success.

```sh
# Active GPIO tests: all six, or only the three spreadsheet GPIO cases.
make -C uvm regression
make -C uvm plan-regression

# Passive UVM: original C, expanded C, or both programs.
make -C uvm sw-gpio
make -C uvm sw-gpio SW_PROGRAM=gpio_uvm_test
make -C uvm sw-regression

# Help for each flow; the original root Make targets remain available.
make -C uvm help
make -C uvm sw-help
```

November 7 results, VCS U-2023.03 / UVM 1.2:

| Test | Result |
|---|---|
| Active smoke / pipeline / factory override | PASS: 845 / 2132 / 2544 checks |
| SOC-027 / SOC-028 / SOC-029 active plan tests | PASS: 727 / 4403 / 5274 checks |
| Passive original C | PASS: 38232 checks; 6 GPIO reads, 8 writes |
| Passive expanded C | PASS: 83970 checks; 76 GPIO reads, 41 writes |
| Passive original C with `HPM=0` | PASS: 38232 checks |
| Deliberately failing C / injected output glitch | Correctly rejected with nonzero Make status |

All positive UVM runs reported zero UVM warnings/errors/fatals. Counts include
clock-by-clock comparisons; they do not measure verification-plan closure.
The original non-UVM GPIO software test also passed after adding the optional
harness completion mode used by UVM. Full non-GPIO software regressions were
not rerun for that harness change.

The passive software harness still supplies fixed external input `0xA5`.
Software controls OUT/DIR but cannot drive physical input pins by writing
read-only IN. External input sweeps/contention belong to the active pad-model
tests; passive software bus-fault handling and reset-in-flight remain uncovered.
The active VIP supports single-beat GPIO accesses and explicitly rejects
mid-run reset. UVM for the other IPs and complete plan closure remain future work.

See [the active VIP guide](uvm/README.md), [verification-plan mapping](uvm/PLAN_COVERAGE.md),
[passive flow guide and results](uvm/gpio_sw/README.md), and
[active waveform walkthrough](uvm/waves/README.md). The root
[`verification_plan.xlsx`](verification_plan.xlsx) is a plan; proposed test
names are not evidence that every checkpoint is implemented.

### Verification Results

Historical results are listed below. The current regression uses VCS
**U-2023.03_Full64** and is documented in `doc/verification/phase2.md`.

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

- Synopsys VCS (GPIO UVM verified with `U-2023.03`)
- Installed UVM 1.2 library for the UVM flows (`-ntb_opts uvm-1.2`)
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

The UVM flows have separate, automatically populated waveform views:

```sh
# Active GPIO: pins, resolved pads, registers, AXI and glitch-checker groups.
make -C uvm gpio TEST=soc_gpio_dir_test WAVES=1
make -C uvm verdi TEST=soc_gpio_dir_test

# Passive software: core trace, completion, GPIO and CPU bus activity.
make -C uvm sw-gpio SW_PROGRAM=gpio_uvm_test WAVES=1
make -C uvm sw-verdi SW_PROGRAM=gpio_uvm_test
```

The viewers select wave-enabled outputs automatically; only generation needs
`WAVES=1`. Match the test/program, seed and run root. The active view contains
nine groups/46 entries; the passive view contains seven groups/59 entries.
Both were restored and validated in Verdi batch mode.

#### Clean build

```bash
make clean
rm -rf csrc
```

The current flow gives each target its own compilation directory and explicit
simulation top. The historical root `csrc` is not used by ordinary targets.
Cleaning is unnecessary for the Phase 2 regression.
`make clean` also removes UVM outputs under `run/`; preserve logs/waves needed
for review before cleaning.

### Simulation Output

```text
run/phase2/<target>/sim.log
run/phase2_nohpm/<target>/sim.log
run/uvm/gpio/<test>/seed_<seed>[_waves]/sim.log
run/uvm/gpio_sw/<program>/seed_<seed>[_waves]/sim.log
run/uvm/gpio_sw_nohpm/<program>/seed_<seed>[_waves]/sim.log
```

UVM compile state is isolated per flow. The passive flow generates core
configuration under its run root's `veer_config/`. `RUN_ROOT` overrides must
be absolute; use separate passive roots for different HPM configurations.
Software builds regenerate tracked `sw/common/soc_map.h`, so avoid concurrent
software image builds and inspect the generated header's diff.

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
├── uvm/
│   ├── gpio/                # Active standalone GPIO VIP and plan tests
│   ├── gpio_sw/             # Separate C-driven passive UVM, waveform view
│   ├── scripts/             # UVM log validator and its self-tests
│   ├── waves/               # Active GPIO restore view and walkthrough
│   └── PLAN_COVERAGE.md     # Spreadsheet checkpoint mapping and limits
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

### Phase 2 — Directed Correctness Baseline Complete

Current results: NDA unit 48 checks (49 with queued responder), WDT unit 29,
HPM unit 24, integration 128 with HPM and 124 without. All six software tests
pass in both configurations; the absent-HPM software variant skips its CSRs.

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

The counts above describe the original October 17 checkpoint. The October 31
baseline expands those tests, adds a queued AXI responder, concurrent-master
integration, HPM-disabled regressions, C drivers, PIC-serviced NDA/WDT IRQs,
and temporary-stall watchdog fallback/restart. `scripts/check_sim.py` makes
failure logs fail Make even when the simulator returns zero.

### What's Next

The following items remain to complete the project:

1. **Performance crossover sweep** — after reviewing the verified baseline,
   collect CPU/NDA cycles and bus events across array sizes and configurations.
   No performance measurements have been collected in this implementation work.

2. **Remaining UVM and broader coverage** — GPIO active and software-driven
   passive UVM are now implemented; the
   remaining work is per-IP VIPs for the other blocks, reset/protocol corner
   cases, broader coverage and complete spreadsheet checkpoint closure.

3. **Permanent-fault recovery architecture** — if required, define isolation
   and reset behavior for a slave that never returns outstanding responses.

4. **HPM area comparison** — build the SoC with `ENABLE_HPM = 0` and compare the synthesis area report against the full build. Report the HPM wrapper area alone (hierarchical report) and the whole-SoC delta (includes the crossbar port).

5. **FPGA implementation** — port the SoC to the target FPGA, synthesise, and measure actual resource usage (LUTs, FFs, BRAM) and timing closure. Compare against the simulation-only memory models.

6. **Final performance analysis** — collect crossover n, decompose fixed cost b (CSR writes, startup latency, completion notice), and compare against the software cost a. Document the result as a measured trade-off, not an assumption.

## Limitations

1. The interconnect serialises transactions through a single FSM and holds
   ownership through response completion. Arbitration is over AW/AR entries;
   latency depends on requests, slave responses and backpressure. Burst length
   alone does not establish a fixed CPU wait bound.

2. Timer software testing uses polling. The timer interrupt line is observed by the testbench but is not yet serviced by software running on the core.

3. The current memory models are simulation-only. Synthesis and timing closure have not been performed.

4. The NDA data window is fixed at the 64 KiB RAM region. If the crossover point grows beyond approximately 16 K elements, a larger memory will be needed.

5. Watchdog recovery requires outstanding AXI responses eventually to complete.
   Temporary stalls are verified through C fallback and restart; permanent
   slave nonresponse is not recoverable by the current serialized fabric.

6. Performance crossover results do not exist yet. HPM ENABLE gates CYCLES
   and NDA_BUSY; bus-event and FALLBACKS counters count continuously.

## External IP and Licensing

The VeeR EL2 core is open-source hardware from Western Digital / CHIPS Alliance.

The AXI interconnect is derived from Alex Forencich's open-source AXI infrastructure and is distributed under the MIT license where indicated by the source headers.

Third-party components retain their respective licenses. Project-specific RTL and verification infrastructure are original work for this Honours project.
