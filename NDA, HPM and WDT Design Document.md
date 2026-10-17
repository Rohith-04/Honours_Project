# NDA, HPM and WDT: Design Document

Rohith · Honours Project (VeeR EL2 SoC) · Version 1.0, 17 Oct 2026

## 1. Purpose and scope

This document specifies the three custom blocks of the Honours SoC: the near-data accelerator (NDA), the hardware performance monitor (HPM), and the NDA watchdog (WDT). They are the second wave, built on the verified Phase 1 baseline (VeeR core, RAM, UART, Timer, GPIO).

The project is an experiment, not a product pitch. Its main objective is to measure the actual crossover point where NDA execution beats a software loop, by comparing execution cycles, AXI bus transactions, setup and interrupt overhead, array size, and hardware resource usage. The accelerator is not assumed to be beneficial. The HPM exists to make that measurement possible, and the WDT exists to make failure safe.

**Performance model.** Crossover n = b / (a − c), valid only when a > c, where a is software cycles per element, c is NDA cycles per element, and b is the NDA fixed cost with no element processing. Section 3.9 decomposes b.

**Out of scope for this revision.** Floating point, preserve-and-resume watchdog semantics, energy modelling, and NDA operation over a NoC.

## 2. System context

### 2.1 Bus parameters

- AXI4 interconnect, 32-bit data, 32-bit address, ID\_WIDTH 12 (from soc\_pkg.sv).
- The VeeR core bus is 64-bit. A width adapter sits between the core and the interconnect. The NDA attaches on the interconnect side, so it never passes through the adapter.
- Consequence for the experiment: the software baseline pays the adapter cost and the NDA does not. Report this as a caveat, or measure the adapter contribution separately.

### 2.2 Masters and slaves

| Port | Type | Block |
| --- | --- | --- |
| M0 | AXI master | VeeR core (via width adapter) |
| M1 | AXI master | NDA read engine |
| S0–S3 | AXI slave | RAM, UART, Timer, GPIO (existing) |
| S4 | AXI-Lite slave | NDA CSRs |
| S5 | AXI-Lite slave | WDT CSRs |
| S6 | AXI-Lite slave | HPM CSRs (last, so ENABLE\_HPM = 0 removes it without renumbering) |

The interconnect moves from 1×4 to 2×7 (2×6 when ENABLE\_HPM = 0). NUM\_MASTERS is already a real parameter with arbitration logic, so this is a port and parameter change.

### 2.3 Memory map

The three CSR regions live in the 0x5000\_xxxx range. The bases below are the design baseline and live only in soc\_pkg.sv.

| Block | Base |
| --- | --- |
| NDA | 0x5000\_0000 |
| HPM | 0x5000\_1000 |
| WDT | 0x5000\_2000 |

### 2.4 Interrupts

Two lines go to the core: NDA and WDT. The HPM has none.

## 3. NDA

### 3.1 Function

Software configures an address range and an operation. The NDA streams the array over its own AXI4 read port, reduces it, and reports completion by interrupt and status flag. Operations are SUM, MIN, MAX and ARGMAX over 32-bit signed integers. The result is at most two 32-bit words.

### 3.2 Structure

- **CSR slave** (AXI-Lite): registers and config checks.
- **Control FSM**: IDLE → CHECK → RUN → DRAIN → DONE or ERR.
- **Address generator**: splits the array into bursts of BURST\_LEN beats, never crossing a 4 KB boundary, with up to MAX\_OUTSTANDING reads in flight.
- **AXI read master**: AR and R channels only. AW, W and B are tied off. A single constant ARID is used, so responses return in order and no reorder logic is needed.
- **Reduce datapath**: single lane, one element per R beat (the bus is 32-bit).
- **Cycle counter**: counts START accepted to DONE or ERR.

### 3.3 FSM behaviour

- **IDLE**: waits for START.
- **CHECK**: runs the config checks in the fixed order of section 3.6. Any failure goes straight to ERR with no bus traffic.
- **RUN**: issues ARs and consumes R beats until all elements are reduced.
- **DRAIN**: entered on BUS\_ERROR or ABORT. The NDA stops issuing new ARs, waits for every outstanding R response, discards the data, then goes to ERR.
- **DONE or ERR**: BUSY clears, DONE is set (and ERR on error), IRQ asserts if enabled.

### 3.4 Datapath

- SUM uses a 64-bit signed accumulator, so it cannot overflow for any array that fits the data window.
- MIN and MAX keep a running best value.
- ARGMAX keeps a running best value and the element index. On ties the first index wins.
- Results: SUM in RESULT\_HI:RESULT\_LO. MIN, MAX in RESULT\_LO. ARGMAX value in RESULT\_LO, index in RESULT\_HI.

### 3.5 Register map

AXI4-Lite, 32-bit registers, offsets from the NDA base.

| Offset | Name | Access | Fields |
| --- | --- | --- | --- |
| 0x00 | CTRL | RW | \[0\] START (self-clearing), \[1\] ABORT (self-clearing), \[2\] IRQ\_EN |
| 0x04 | STATUS | RO / W1C | \[0\] BUSY (RO), \[1\] DONE (W1C), \[2\] ERR (W1C), \[7:4\] ERR\_CODE (RO) |
| 0x08 | OP | RW | \[3:0\] 0 = SUM, 1 = MIN, 2 = MAX, 3 = ARGMAX, 4 to 15 reserved |
| 0x0C | SRC\_BASE | RW | Array start address, 4-byte aligned |
| 0x10 | LEN | RW | Element count, nonzero |
| 0x14 | RESULT\_LO | RO | SUM\[31:0\], or the MIN, MAX, ARGMAX value |
| 0x18 | RESULT\_HI | RO | SUM\[63:32\], or the ARGMAX index |
| 0x1C | CYCLES | RO | Cycles from START accepted to DONE or ERR |

### 3.6 Error codes and check order

| Code | Name | Cause |
| --- | --- | --- |
| 0x0 | NONE | No error |
| 0x1 | BAD\_LEN | LEN = 0 |
| 0x2 | BAD\_OP | OP is a reserved encoding |
| 0x3 | MISALIGNED | SRC\_BASE not 4-byte aligned |
| 0x4 | BAD\_ADDR | SRC\_BASE outside the data window |
| 0x5 | BAD\_RANGE | SRC\_BASE valid, but SRC\_BASE + LEN×4 passes the end of the window or wraps |
| 0x6 | BUS\_ERROR | Any SLVERR or DECERR on an AXI read |
| 0x7 | ABORTED | Stopped by ABORT, from software or the WDT |

Codes 1 to 5 mean the job never started. Codes 6 and 7 mean it started and was cut short, so software can test code < 6.

Check order at START, fixed so the code is deterministic and the first error wins:

1. LEN = 0
2. OP reserved
3. SRC\_BASE misaligned
4. SRC\_BASE outside the data window
5. Range overflow

The data window is \[NDA\_DATA\_BASE, NDA\_DATA\_END), taken from soc\_pkg (currently the RAM region). The range check computes SRC\_BASE + LEN×4 in at least 34 bits so a huge LEN cannot wrap past the check. The static checks cannot see holes inside the window, so BUS\_ERROR remains the backstop.

### 3.7 Behaviour rules

- On any error, ERR and DONE are both set, BUSY clears, and results are invalid. A polling loop on DONE always terminates, and software then checks ERR.
- Errors are sticky and the first one wins. Writing 1 to ERR clears it and ERR\_CODE. A new START clears DONE, ERR and ERR\_CODE.
- IRQ is level-asserted while (DONE or ERR) and IRQ\_EN, and drops when software clears the flags.
- CSR access errors are not job errors and never touch STATUS. They return SLVERR on the AXI-Lite response: START while BUSY, writes to OP, SRC\_BASE or LEN while BUSY, writes to read-only registers, and accesses to undefined offsets.
- Configuration writes while BUSY are rejected rather than latched, which avoids shadow registers.
- A hang is not detected inside the NDA. That is the WDT’s job.

### 3.8 Parameters

| Parameter | Meaning |
| --- | --- |
| BURST\_LEN | Beats per read burst, swept in experiments |
| MAX\_OUTSTANDING | Reads in flight, swept in experiments |
| NDA\_DATA\_BASE / NDA\_DATA\_END | Allowed data window, from soc\_pkg |

BURST\_LEN and MAX\_OUTSTANDING are module parameters rather than CSRs, to save area and keep the read engine simple. Making them runtime-writable is a later option if re-synthesis per sweep point becomes painful.

### 3.9 Decomposing the fixed cost b

The CYCLES register measures the hardware portion. Software measures the whole thing with mcycle. The difference is the part the NDA cannot see.

| Component | How to measure |
| --- | --- |
| CSR programming (OP, SRC\_BASE, LEN, START writes) | mcycle around the writes |
| Startup latency (START to first AR, AR to first R beat) | CYCLES with LEN = 1 |
| Drain and finish | CYCLES minus streaming time |
| Completion notice (poll loop or IRQ entry) | mcycle from DONE to software resuming |

The per-element cost c comes from the slope of CYCLES against LEN. The software cost a comes from the same array run in a C loop.

## 4. WDT

### 4.1 Function

The WDT detects an NDA that has stopped making progress and forces a safe stop so software can fall back to the C loop. Semantics are discard-and-restart: the partial result is thrown away and the job is redone in software. Preserve-and-resume is deferred.

### 4.2 Mechanism

- The WDT watches progress, not total time, so a large array cannot false-trip it.
- Inputs from the NDA: busy, and progress, a one-cycle pulse per accepted R beat.
- The counter arms when busy rises and reloads on every progress pulse.
- If it reaches TIMEOUT cycles with no progress, the WDT trips: it sets the sticky TRIPPED flag, asserts abort into the NDA (OR-ed with CTRL.ABORT), increments TRIP\_COUNT, and raises its IRQ if enabled.
- The NDA drains and reports ERR\_CODE = ABORTED. Software then runs the fallback loop.
- The WDT re-arms on the next busy rise. It trips at most once per job.

### 4.3 Register map

| Offset | Name | Access | Fields |
| --- | --- | --- | --- |
| 0x00 | CTRL | RW | \[0\] EN, \[2\] IRQ\_EN |
| 0x04 | TIMEOUT | RW | Cycles without progress before trip. 0 disables tripping |
| 0x08 | STATUS | RO / W1C | \[0\] TRIPPED (W1C), \[1\] ARMED (RO) |
| 0x0C | TRIP\_COUNT | RO | Number of trips since reset |

### 4.4 Constraints

- WDT\_TIMEOUT\_DEFAULT is 4096 cycles. This is a decision, not a measurement: it sits far above any plausible AR-to-first-R latency through a store-and-forward crossbar shared with CPU traffic, and the only cost is a few thousand cycles of delay before fallback on a job that has already stalled.
- A simulation check requires WDT\_TIMEOUT\_DEFAULT ≥ 8 × the worst-case AR-to-first-R latency measured in the testbench, so the default stays safe if the interconnect changes.
- Under round-robin arbitration (section 6.1) the NDA waits at most one CPU transaction plus its own pipeline latency, so the same margin covers contention.
- TIMEOUT is writable, so experiments can lower it to provoke a trip.

## 5. HPM

### 5.1 Function

The HPM is a passive monitor. It taps AXI handshakes and counts events. It never drives the bus. It is decoupled behind a synthesis-time parameter, ENABLE\_HPM, so its area can be measured by building with and without it.

### 5.2 Tap points

Taps sit on the interconnect master-facing ports, after the width adapter, so both masters are seen at 32-bit beat granularity. A 64-bit CPU access therefore appears as two beats. CSR accesses to the NDA, HPM and WDT are counted as CPU traffic, which is intended: setup overhead is part of b. Only handshake wires are tapped, never address or data buses, so the monitor adds no wide fan-in. Bytes moved are beats × 4.

| Counter | Tapped signals | Event counted |
| --- | --- | --- |
| CPU\_AR | M0 arvalid & arready | One accepted read address |
| CPU\_AW | M0 awvalid & awready | One accepted write address |
| CPU\_R\_BEATS | M0 rvalid & rready | One read data beat |
| CPU\_W\_BEATS | M0 wvalid & wready | One write data beat |
| NDA\_AR | M1 arvalid & arready | One accepted read address |
| NDA\_R\_BEATS | M1 rvalid & rready | One read data beat |
| NDA\_BUSY | NDA STATUS.BUSY (not AXI) | One cycle while busy |
| FALLBACKS | WDT trip pulse (not AXI) | One trip |
| CYCLES | Clock | One cycle while ENABLE is set |

### 5.3 Counters

Each counter is 64 bits and exposed as a LO and HI pair.

| Counter | Counts |
| --- | --- |
| CYCLES | Clock cycles while enabled |
| CPU\_AR / CPU\_AW | Read and write address handshakes from the CPU |
| CPU\_R\_BEATS / CPU\_W\_BEATS | Data beats for the CPU |
| NDA\_AR / NDA\_R\_BEATS | Address handshakes and data beats for the NDA |
| NDA\_BUSY | Cycles the NDA is busy |
| FALLBACKS | WDT trip pulses (hardware-forced fallbacks only) |

### 5.4 Register map

| Offset | Name | Access | Fields |
| --- | --- | --- | --- |
| 0x00 | CTRL | RW | \[0\] ENABLE, \[1\] CLEAR (self-clearing), \[2\] SNAPSHOT (self-clearing) |
| 0x10 | CYCLES\_LO / 0x14 CYCLES\_HI | RO | Snapshot of CYCLES |
| 0x18 / 0x1C | CPU\_AR | RO | Snapshot |
| 0x20 / 0x24 | CPU\_AW | RO | Snapshot |
| 0x28 / 0x2C | CPU\_R\_BEATS | RO | Snapshot |
| 0x30 / 0x34 | CPU\_W\_BEATS | RO | Snapshot |
| 0x38 / 0x3C | NDA\_AR | RO | Snapshot |
| 0x40 / 0x44 | NDA\_R\_BEATS | RO | Snapshot |
| 0x48 / 0x4C | NDA\_BUSY | RO | Snapshot |
| 0x50 / 0x54 | FALLBACKS | RO | Snapshot |

SNAPSHOT latches all live counters into shadow registers in one cycle, so software reads a consistent set. Reading the HPM does not disturb the snapshot, even though those reads are themselves bus traffic.

### 5.5 ENABLE\_HPM = 0

With ENABLE\_HPM = 0 the HPM leaves the design completely, so the area comparison between the two builds is honest. The HPM wrapper, its S6 crossbar port, the tap wires and the FALLBACKS input are all absent, and the SoC is generated as 2×6 instead of 2×7. The HPM region stays unmapped, so accesses return DECERR from the crossbar. A stub or tied-off slave is rejected because it would leave area in a build that is meant to have none.

Area is reported two ways: the HPM wrapper alone from the hierarchical report, and the whole-SoC difference between the two builds. The second figure also includes the crossbar port and is the real cost of having an HPM.

This needs two things. The wrapper generator (scripts/axi\_interconnect\_wrap.py) takes the slave count from soc\_pkg.sv, and HPM is always the last slave so nothing else renumbers. C code is built with a HAVE\_HPM flag generated from the same parameter, so software never touches an absent block.

## 6. Integration

- The top-level SoC file only instantiates blocks and wires memory-map and crossbar addresses, as in Phase 1. Project-specific CSR logic stays in per-block wrappers.
- Wiring added: NDA master to M1, the three CSR slaves to S4 to S6, nda\_busy and nda\_progress to the WDT, wdt\_abort to the NDA, wdt\_trip to the HPM FALLBACKS counter, and tap wires from both master ports to the HPM.
- **ID width check.** In a Forencich-style crossbar, slave-side IDs gain bits that identify the master. At NUM\_MASTERS = 2 the ID seen by existing slaves may exceed 12 bits. Check what the generated wrapper does before the NDA goes in, or the UART ID port will be the wrong width.
- **Known limitation.** The interconnect serializes transactions through a single FSM. That was sufficient for one master. With the NDA as a second concurrent master, CPU and NDA traffic will serialize, which affects the measured crossover and is documented as part of the result rather than hidden.

### 6.1 Arbitration (to implement in the xbar)

The crossbar must arbitrate between M0 (CPU) and M1 (NDA) with a round-robin arbiter. This is not implemented yet and has to be added to the xbar. The existing arbiter.v is the starting point.

- Policy: round-robin, so neither master can starve the other. When both are requesting, the master that lost the last grant wins the next.
- Granularity: per transaction, not per beat. A granted master holds the crossbar until its transaction completes, because the interconnect serializes through a single FSM.
- Streams: the NDA only reads and the CPU reads and writes. Arbitration runs on the combined request stream, so a CPU write can land between two NDA bursts.
- Consequence: CPU latency while the NDA streams is bounded by one NDA burst, which BURST\_LEN sets. NDA latency is bounded by one CPU transaction. The second bound feeds the WDT timeout (section 4.4).
- Test: with both masters requesting continuously, grants alternate, and neither waits longer than one foreign transaction.

## 7. soc\_pkg.sv additions

To keep soc\_pkg.sv the single source of truth, add the following. The C header is generated from the same values.

```systemverilog
  // --- Custom IP bases ---
  localparam logic [31:0] NDA_BASE = 32'h5000_0000;
  localparam logic [31:0] HPM_BASE = 32'h5000_1000;
  localparam logic [31:0] WDT_BASE = 32'h5000_2000;

  // --- NDA data window ---
  localparam logic [31:0] NDA_DATA_BASE = RAM_BASE;
  localparam logic [31:0] NDA_DATA_END  = RAM_BASE + RAM_BYTES;

  // --- NDA register offsets ---
  localparam logic [31:0] NDA_CTRL      = 32'h00;
  localparam logic [31:0] NDA_STATUS    = 32'h04;
  localparam logic [31:0] NDA_OP        = 32'h08;
  localparam logic [31:0] NDA_SRC_BASE  = 32'h0C;
  localparam logic [31:0] NDA_LEN       = 32'h10;
  localparam logic [31:0] NDA_RESULT_LO = 32'h14;
  localparam logic [31:0] NDA_RESULT_HI = 32'h18;
  localparam logic [31:0] NDA_CYCLES    = 32'h1C;

  // NDA_CTRL bits
  localparam int unsigned NDA_CTRL_START  = 0;
  localparam int unsigned NDA_CTRL_ABORT  = 1;
  localparam int unsigned NDA_CTRL_IRQ_EN = 2;

  // NDA_STATUS bits
  localparam int unsigned NDA_STATUS_BUSY     = 0;
  localparam int unsigned NDA_STATUS_DONE     = 1; // W1C
  localparam int unsigned NDA_STATUS_ERR      = 2; // W1C
  localparam int unsigned NDA_STATUS_CODE_LSB = 4; // [7:4]

  // NDA_OP encodings
  localparam logic [3:0] NDA_OP_SUM    = 4'd0;
  localparam logic [3:0] NDA_OP_MIN    = 4'd1;
  localparam logic [3:0] NDA_OP_MAX    = 4'd2;
  localparam logic [3:0] NDA_OP_ARGMAX = 4'd3;

  // NDA error codes
  localparam logic [3:0] NDA_ERR_NONE       = 4'h0;
  localparam logic [3:0] NDA_ERR_BAD_LEN    = 4'h1;
  localparam logic [3:0] NDA_ERR_BAD_OP     = 4'h2;
  localparam logic [3:0] NDA_ERR_MISALIGNED = 4'h3;
  localparam logic [3:0] NDA_ERR_BAD_ADDR   = 4'h4;
  localparam logic [3:0] NDA_ERR_BAD_RANGE  = 4'h5;
  localparam logic [3:0] NDA_ERR_BUS_ERROR  = 4'h6;
  localparam logic [3:0] NDA_ERR_ABORTED    = 4'h7;

  // --- WDT register offsets / bits ---
  localparam logic [31:0] WDT_CTRL       = 32'h00;
  localparam logic [31:0] WDT_TIMEOUT    = 32'h04;
  localparam logic [31:0] WDT_STATUS     = 32'h08;
  localparam logic [31:0] WDT_TRIP_COUNT = 32'h0C;
  localparam int unsigned WDT_CTRL_EN     = 0;
  localparam int unsigned WDT_CTRL_IRQ_EN = 2;
  localparam int unsigned WDT_STATUS_TRIPPED = 0; // W1C
  localparam int unsigned WDT_STATUS_ARMED   = 1;

  // --- HPM register offsets / bits ---
  localparam logic [31:0] HPM_CTRL = 32'h00;
  localparam int unsigned HPM_CTRL_ENABLE   = 0;
  localparam int unsigned HPM_CTRL_CLEAR    = 1;
  localparam int unsigned HPM_CTRL_SNAPSHOT = 2;
  localparam logic [31:0] HPM_CYCLES_LO      = 32'h10;
  localparam logic [31:0] HPM_CPU_AR_LO      = 32'h18;
  localparam logic [31:0] HPM_CPU_AW_LO      = 32'h20;
  localparam logic [31:0] HPM_CPU_RBEATS_LO  = 32'h28;
  localparam logic [31:0] HPM_CPU_WBEATS_LO  = 32'h30;
  localparam logic [31:0] HPM_NDA_AR_LO      = 32'h38;
  localparam logic [31:0] HPM_NDA_RBEATS_LO  = 32'h40;
  localparam logic [31:0] HPM_NDA_BUSY_LO    = 32'h48;
  localparam logic [31:0] HPM_FALLBACKS_LO   = 32'h50;
  // each counter's HI word is at LO + 4
```

Build configuration, which also feeds the wrapper generator and the generated C header (HAVE\_HPM):

```systemverilog
  localparam bit          ENABLE_HPM  = 1'b1; // 0 removes the HPM and its xbar port
  localparam int unsigned NUM_MASTERS = 2;
  localparam int unsigned NUM_SLAVES  = 6 + (ENABLE_HPM ? 1 : 0); // HPM is always last
```

## 8. Verification plan

Verification follows the Phase 1 flow: wrapper unit tests, then integration, then software-driven tests on the real core. Testbench and C code both use names generated from soc\_pkg.sv.

### 8.1 NDA

- Each error code reachable, and the check order verified with inputs that violate two checks at once.
- All four operations on known arrays, including negative values, a single element, and ARGMAX ties.
- SUM exceeding 32 bits.
- A range that crosses a 4 KB boundary.
- BUS\_ERROR from a range that passes the window check but reaches an unmapped hole, with outstanding reads drained cleanly.
- ABORT mid-run: drain, ABORTED, no stale data on the next job.
- START while BUSY, writes to read-only registers, and undefined offsets all return SLVERR without changing STATUS.
- W1C behaviour, IRQ level behaviour, and IRQ\_EN gating.

### 8.2 WDT

- Injected stall (slave holds R off): trips after TIMEOUT, NDA reports ABORTED, TRIP\_COUNT increments.
- No false trip on a long array with steady progress.
- Re-arm on the next job. Disabled when EN = 0 or TIMEOUT = 0.

### 8.3 HPM

- Counters match a known traffic pattern exactly.
- SNAPSHOT consistency, CLEAR, and ENABLE gating.
- FALLBACKS increments on a WDT trip.
- Build with ENABLE\_HPM = 0: the HPM region returns DECERR and every other SoC test still passes.

### 8.4 Software-driven

- C program runs the NDA and the software loop on the same array, compares results, and reports through UART.
- Crossover sweep: mcycle and HPM counters across array sizes, BURST\_LEN and MAX\_OUTSTANDING. Software is crossover-unaware: it runs both the NDA and the C loop at every size, and the crossover is read off the results afterward.
- Fallback path: force a stall, confirm the C loop produces the correct result.

## 9. Decision log and remaining checks

Six items are decided. Two remain as checks to run during implementation, not design questions: items 2 and 5.

1. **AXI4 snoop signals: decided.** Handshake-only taps on M0 and M1, after the width adapter (section 5.2).
2. **VeeR EL2 access window for the 0x5000\_xxxx MMIO regions: open.** Expected to be the per-region access control CSR (MRAC): region 5 needs the side-effect bit set and cacheable clear. Verify against the EL2 programmer’s reference manual, check that the existing startup code already does this for region 1, and confirm with a software test that NDA, WDT and HPM CSR accesses reach the crossbar.
3. **Data window size: decided for now.** It stays at the 64 KiB RAM. Research a larger memory only if the crossover n grows beyond 16K elements.
4. **WDT default TIMEOUT: decided.** 4096 cycles, with a simulation check that it is at least 8× the worst-case latency (section 4.4).
5. **ID width of existing slaves at NUM\_MASTERS = 2: to verify.** Check the generated wrapper before the NDA goes in.
6. **Arbitration: decided.** Round-robin, to be implemented in the xbar (section 6.1).
7. **Software-chosen fallbacks: closed.** Software is crossover-unaware and never decides to skip the NDA, so the only fallback is the WDT-forced one. FALLBACKS counts exactly that. The crossover is a result read from the data, not something software acts on.
8. **ENABLE\_HPM = 0: decided in principle.** The HPM leaves the design entirely, including its crossbar port (section 5.5). The wrapper generator must take the slave count as a parameter.
