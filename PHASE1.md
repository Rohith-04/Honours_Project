# Phase 1 — Baseline SoC IP Requirements

Phase 1 goal: VeeR EL2 core + a minimal, correctly-verified set of
peripherals, before any of the custom IPs (NDA, HPM, WDT)
are touched. This is the "basic IP requirements" your mentor directed —
build the SoC bottom-up with a solid baseline first.

**Phase 1 is not done until every IP below has passed all three
verification levels** (`unit` → `integration` → `sw`), per
`PROJECT_STRUCTURE.md`. Software-driven verification specifically matters
to your mentor — a peripheral isn't "working" until it's demonstrated
through compiled C running on the real core (e.g. UART output visibly
correct), not just correct signals in Verdi.

---

## 0. Interconnect & Core Integration Requirements

These apply across all of Phase 1, not to one specific IP:

- **AXI4, 32-bit data width, 12-bit IDs, single master (VeeR) for now.**
  `NUM_MASTERS` parameterized but instantiated at 1, `ID_WIDTH = 12`
  everywhere (see `PROJECT_STRUCTURE.md` §3).
- **Data-width adaptation is required and not optional.** VeeR EL2
  exposes 64-bit system AXI buses on its IFU and LSU interfaces; the
  interconnect here is 32-bit. Simply wiring the lower 32 bits of
  `WDATA`/`RDATA` and ignoring the rest is an *incomplete* integration,
  not a converter — it will silently break on any transaction that
  relies on `WSTRB`, unaligned access, or full 64-bit transfers. A proper
  64-to-32 adaptation must handle: `WDATA`/`WSTRB`/`RDATA`, transfer size,
  address alignment, and correct AXI transaction semantics on both the
  IFU and LSU paths. This needs to be resolved and verified (ideally at
  the integration level, before relying on any software-driven test)
  rather than assumed to be "good enough."
- **Memory map and CSR offsets live in `rtl/soc/soc_pkg.sv` only.** No
  other file (RTL wrapper, testbench, C header) hand-derives an address
  independently.

### Baseline Memory Map

| Address Range               | Device |
|------------------------------|--------|
| `0x0000_0000` – `0x0000_FFFF` | RAM    |
| `0x1000_0000` – `0x1000_0FFF` | UART   |
| `0x1001_0000` – `0x1001_0FFF` | Timer  |
| `0x1002_0000` – `0x1002_0FFF` | GPIO   |

(Adjust ranges if your address decode granularity differs — the point is
this table exists in exactly one place: `soc_pkg.sv`.)

- **Firmware must configure the `mrac` CSR at boot.**
  `sw/common/startup.S` must write the `mrac` region access control
  register (CSR `0x7C0`) to mark the peripheral region (region 1,
  `0x1000_0000`–`0x1FFF_FFFF`, covering UART/Timer/GPIO) as
  side-effecting (`sideeffect1` = 1) and non-cacheable (`cacheable1` =
  0), followed by a `fence`. Reset value for these bits is 0, so without
  this write MMIO register behavior (coalescing/buffering) is undefined.
  Required per the VeeR EL2 Programmer's Reference Manual, Memory Map
  chapter.

---

## 1. RAM

**Purpose:** backing store for the compiled software image (instructions
+ data) and general scratch memory during simulation.

**Requirements:**
- Must support both instruction fetch (IFU) and load/store (LSU) access
  from the core, through the width-adapted 32-bit AXI path.
- Must be loadable from a memory image (`$readmemh` or equivalent) built
  from the compiled ELF, per the existing ELF → hex flow.
- Size: sized for Phase 1 test programs — doesn't need to be large, but
  should be big enough for `.text`, `.data`, and a stack for every test
  program in `sw/*_test/`.

**Verification:**
- *Unit:* not typically needed as a standalone DUT (it's a memory model,
  not custom logic) — but if `axi_true_mem.sv` has any custom timing
  behavior, a minimal BFM-driven read/write test is worth having.
- *Integration:* implicitly exercised by every other peripheral's
  integration test, since program/stack live here.
- *SW:* implicitly exercised by every software test — if RAM is broken,
  nothing else will run.

---

## 2. UART

**Purpose:** the first software-visible output channel — this is how
every later test (including NDA, eventually) reports pass/fail from
software without needing a physical board.

**Register map (offsets from UART_BASE, see `soc_pkg.sv`):**
| Offset | Register | Function |
|--------|----------|----------|
| `0x00` | TXDATA   | Write byte to transmit |
| `0x04` | RXDATA   | Read received byte |
| `0x08` | STATUS   | TX/RX ready flags |

**Functional requirements:**
- TX: write to TXDATA → byte transmitted serially → visible in
  simulation console via the TB's UART monitor.
- RX: receive path, if used in Phase 1 (or stub if not needed yet — note
  it in `doc/verification/` either way, don't leave it silently
  unimplemented without saying so).
- Baud rate generation, FIFO behavior (if the IP has one), and basic
  error handling as provided by the underlying `ips/uart/` core — your
  wrapper's job is CSR mapping, not reimplementing the UART itself.

**Verification:**
- *Unit:* BFM writes to TXDATA, checker confirms correct serial output
  on `uart_tx`. Cover reset behavior, back-to-back writes, and (if
  applicable) FIFO full/empty behavior.
- *Integration:* same, but transaction routed through the real
  interconnect — confirms address decode picks UART correctly and other
  slaves are unaffected.
- *SW:* C program writes a known string via `uart_putc`-style calls;
  simulation console output is checked against the expected string. This
  is the test your mentor explicitly cares about — hexdump/console output
  matching, not just correct waveforms.

---

## 3. Timer

**Purpose:** basic hardware timer — needed both as a baseline peripheral
and later likely useful for the HPM (and, in Phase 2, the WDT).

**Implementation note:** the timer is fully custom RTL with no external
`ips/` source — `rtl/wrappers/timer_wrapper.sv` *is* the full
implementation, not just CSR glue around a third-party core.

**Register map (offsets from TIMER_BASE):**
| Offset | Register | Function |
|--------|----------|----------|
| `0x00` | CTRL     | Enable/disable, mode select |
| `0x04` | COUNT    | Current count value (read), or reload (write, if supported) |
| `0x08` | COMPARE  | Compare/match value for interrupt or event generation |

**Functional requirements:**
- Free-running or reloadable count (decide which mode(s) Phase 1 needs —
  free-running is simplest and likely sufficient for baseline).
- Compare match behavior: what happens when COUNT reaches COMPARE
  (interrupt, flag, or both) — needs to be decided and documented before
  the unit test is written, since the test needs the same yes/no answer.

**Verification:**
- *Unit:* BFM configures CTRL/COMPARE, checker confirms COUNT increments
  correctly and match behavior fires as specified.
- *Integration:* confirms timer is correctly addressed and doesn't
  interfere with other peripherals' transactions while running.
- *SW:* C program configures the timer, busy-waits or handles an
  interrupt (if implemented), and reports result via UART.

---

## 4. GPIO

**Purpose:** baseline peripheral, likely simplest of the three to bring
up — useful as a first end-to-end proof of the ladder before UART/Timer
complexity.

**Implementation note:** GPIO is fully custom RTL with no external
`ips/` source — `rtl/wrappers/gpio_wrapper.sv` *is* the full
implementation, not just CSR glue around a third-party core.

**Register map (offsets from GPIO_BASE):**
| Offset | Register | Function |
|--------|----------|----------|
| `0x00` | OUT      | Output value |
| `0x04` | IN       | Input value (read-only) |
| `0x08` | DIR      | Direction (per-bit input/output select) |

**Functional requirements:**
- Per-bit direction control via DIR.
- Writes to OUT reflected on output pins for bits configured as output.
- Reads from IN reflect external pin state for bits configured as input.

**Verification:**
- *Unit:* BFM sets DIR, writes OUT, checker confirms pin-level output;
  drives external input, checker confirms IN reads correctly.
- *Integration:* same, through the real interconnect.
- *SW:* C program toggles GPIO output in a pattern, checked either via
  waveform or via a UART report of what was driven (reuses the UART
  peripheral as your software-visible confirmation channel, same pattern
  as section 5 below).

---

## 5. Phase 1 Exit Criteria

Phase 1 is complete when:
- [ ] RAM, UART, Timer, GPIO each have passing `tb/unit`
      tests.
- [ ] `tb/integration` passes with all 4 slaves present on the real
      interconnect (single master, VeeR only).
- [ ] `tb/sw` passes for UART, Timer, and GPIO — each
      demonstrated via compiled C running on the real VeeR core, with
      results visible/checkable via UART console output.
- [ ] The 64-to-32 AXI width adaptation is implemented and verified
      (not just "lower 32 bits connected") — confirmed at minimum during
      `tb/integration`.
- [ ] `soc_pkg.sv` is the only place addresses/CSR offsets are defined;
      no hand-duplicated addresses in wrappers, testbenches, or C code.

Only once this is true does Phase 2 (NDA accelerator, HPM, WDT)
begin.
