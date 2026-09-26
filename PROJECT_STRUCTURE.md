# Honours SoC — Project Structure & Verification Flow

Reference document for the rebuilt project. This is the single place that
describes *how the repo is organized and why* — if something doesn't fit
this structure, that's a signal to update this doc deliberately, not to
quietly deviate from it.

---

## 1. Core Principles (locked in before any code was written)

These govern every structural decision below. If a future change conflicts
with one of these, that's worth noticing and deciding about explicitly —
not drifting into by accident.

1. **DUT boundary must be explicit and singular at every verification
   level.** At any given test, there is exactly one thing being validated;
   everything else is either known-good stimulus or already-proven
   infrastructure.
2. **The top-level integration file instantiates only — no behavioral
   logic.** This rules out an entire class of bugs by construction, not by
   inspection.
3. **Verification proceeds in independently-checkpointed rungs**, and each
   rung must actually pass before the next is trusted:
   `unit` → `integration` → `sw`. Skipping a rung deletes a
   fault-isolation boundary — any skip is a deliberate, named tradeoff,
   not a default.
4. **Single source of truth for anything both RTL and verification depend
   on** (memory map, CSR offsets). Two independent hand-derivations of the
   same fact is how a shared wrong assumption survives unnoticed.
5. **A failure must be traceable to a specific boundary, not a list of
   suspects.** If the honest answer to "what broke" is "could be any of
   six things," that test is missing a checker at an intermediate
   interface.
6. **Reusable test infrastructure sits below all three levels**, not
   duplicated per level, and itself defers to the BFM as the only way of
   touching the bus.
7. **Tooling should make the hierarchy visible, not compensate for its
   absence.** Structure first, tooling reflects it.
8. **Provision for committed scope, not imagined scope — but make growth
   additive.** Don't build slave/master ports for IP that doesn't exist
   yet (the mistake the old 5x16 crossbar made). Do build structural
   seams (parameters, not hardcoded counts) for growth that's actually
   planned, so adding it later is a config change, not a rewrite.

---

## 2. Directory Structure

```
Honours_Project/
├── .gitignore
├── Makefile
├── README.md
│
├── Cores-VeeR-EL2/          # VeeR EL2 core source (untouched)
│
├── ips/                     # External/reused IP — source of truth, never edited
│   ├── uart/
│   ├── timer/
│   └── gpio/
│
├── rtl/
│   ├── soc/
│   │   ├── honours_soc.sv      # TOP — instantiate only
│   │   └── soc_pkg.sv          # Single source of truth: memory map + CSR offsets
│   ├── interconnect/
│   │   └── axi_interconnect.sv # NUM_MASTERS / NUM_SLAVES parameterized
│   ├── wrappers/                # Project-specific CSR logic per IP
│   │   ├── uart_wrapper.sv
│   │   ├── timer_wrapper.sv
│   │   ├── gpio_wrapper.sv
│   │   └── wdt_wrapper.sv
│   └── mem/
│       └── axi_ram.sv
│
├── bfm/
│   └── axi_master_bfm.sv    # Reusable AXI4 master BFM — mimics VeeR's master port
│
├── tb/
│   ├── common/
│   │   ├── tb_tasks.svh      # soc_reset, soc_start, uart_send, etc. — calls BFM only
│   │   └── tb_pkg.sv
│   ├── unit/                 # LEVEL 1 — BFM -> one wrapper. No interconnect, no core.
│   │   ├── tb_uart_unit.sv
│   │   ├── tb_timer_unit.sv
│   │   ├── tb_gpio_unit.sv
│   │   └── tb_wdt_unit.sv
│   ├── integration/          # LEVEL 2 — BFM -> interconnect -> wrapper(s). No core.
│   │   └── tb_soc_integration.sv
│   └── sw/                   # LEVEL 3 — real VeeR core + compiled software. Only place core appears.
│       └── tb_soc_sw.sv
│
├── sw/
│   ├── common/
│   │   ├── startup.S
│   │   └── linker.ld
│   ├── uart_test/
│   ├── timer_test/
│   ├── gpio_test/
│   └── wdt_test/
│
├── scripts/
│   ├── build_sw.sh
│   └── elf2hex.sh
│
├── run/
│   ├── unit/
│   ├── integration/
│   └── sw/
│
├── waves/                    # .rc files named to match test level + IP, not cryptic
│   ├── unit_uart.rc
│   ├── unit_timer.rc
│   ├── unit_gpio.rc
│   ├── unit_wdt.rc
│   ├── integration.rc
│   └── sw.rc
│
└── doc/
    ├── architecture/
    ├── interfaces/
    └── verification/
```

### Why this shape

- **`tb/unit`, `tb/integration`, `tb/sw` are the verification ladder made
  literal.** A reviewer sees the hierarchy from folder names alone —
  no inference required.
- **`bfm/` is its own top-level directory**, not buried inside a
  testbench file. It's a named, reusable verification component with the
  same status as RTL.
- **`rtl/soc/honours_soc.sv` doesn't share a folder with behavioral
  logic** (memory model, bridges) — nothing in `rtl/soc/` undermines the
  "this file can't be the bug" guarantee except the file itself.
- **`soc_pkg.sv`** is imported by RTL wrappers, the BFM, and every tb
  level. If SW needs the same addresses as C `#define`s, generate
  `sw/common/soc_map.h` from this file — never hand-duplicate it.

---

## 3. Interconnect Sizing

- **Slaves (locked for baseline): RAM, UART, Timer, GPIO, WDT — 5 total.**
  Each gets an address range in `soc_pkg.sv` and its own wrapper in
  `rtl/wrappers/`.
- **Masters: `NUM_MASTERS` is a real parameter, including arbitration
  logic, from day one — instantiated and verified at `NUM_MASTERS=1`
  now.** VeeR is the only master today. The NDA accelerator becomes a
  second master later (AXI4 DMA master port) — that addition should be a
  parameter bump and a port connection, not a rewrite of decode/arbitration
  logic that already works for RAM/UART/Timer/GPIO/WDT.
- **WDT is an AXI slave** for its register interface (config, kick,
  status) — same pattern as every other peripheral, routed through the
  same crossbar. Its separate signal-tap monitoring behavior (what it
  watches to decide when to trip) is a later design decision and doesn't
  affect its slave-port shape today.

---

## 4. Verification Ladder (per IP)

For each of UART / Timer / GPIO / WDT:

```
LEVEL 1 — tb/unit/tb_<ip>_unit.sv
    BFM --AXI--> <ip>_wrapper
    DUT = wrapper + CSR logic only. No interconnect, no core.
    Checks: register read/write behavior, IP-specific function
    (UART TX/RX, timer count/compare, GPIO in/out/dir, WDT config/kick/status)

LEVEL 2 — tb/integration/tb_soc_integration.sv
    BFM --AXI--> interconnect --AXI--> <ip>_wrapper (all 5 slaves present)
    DUT = interconnect address decode/routing + wrapper, together.
    Checks: correct slave selected per address, no cross-talk between
    peripherals, back-to-back transactions to different slaves.

LEVEL 3 — tb/sw/tb_soc_sw.sv
    Real VeeR core --AXI--> interconnect --AXI--> <ip>_wrapper
    DUT = the toolchain-to-hardware path (compiler, startup, linker,
    memory image, core fetch/decode/execute).
    Checks: same behavior as Level 1/2, but driven by compiled C instead
    of the BFM. If Level 1/2 passed and Level 3 fails, the bug is in the
    software/toolchain path, not the RTL — that's the fault-isolation
    payoff of doing Levels 1 and 2 first.
```

A given IP is not "done" until it has passed all three levels.

---

## 5. Makefile / Command Flow

```makefile
# Targets map 1:1 onto tb/ directories
make unit        IP=uart|timer|gpio|wdt
make integration
make sw          IP=uart|timer|gpio|wdt
make verdi       LEVEL=unit|integration|sw   IP=<ip>   # opens waves/<level>_<ip>.rc
make clean
```

Typical flow for bringing up one new IP:

```bash
# 1. Write/refine the wrapper
vim rtl/wrappers/uart_wrapper.sv

# 2. Level 1 — unit test against the BFM only
make unit IP=uart
make verdi LEVEL=unit IP=uart      # debug if it fails

# 3. Level 2 — once ALL wrappers exist, integration test through the real interconnect
make integration
make verdi LEVEL=integration IP=uart

# 4. Level 3 — software-driven, through the real core
make sw IP=uart
make verdi LEVEL=sw IP=uart
```

Do not skip from Level 1 straight to Level 3 without a stated reason —
that's the exact seam that gave the fault-traceability problem last time.

---

## 6. Repo Hygiene

- `csrc/`, `*.sdb`, `simv`, `*.vpd`, `*.fsdb`, `*.log`, `DVEfiles/` — all
  simulator scratch, all in `.gitignore`. Never commit these.
- No loose scratch files at repo root (`report.txt`, `unknownSignals.txt`,
  etc.) — if a debug dump needs to persist, it goes under `run/<level>/`
  or gets deleted once used.
- `ips/*` is never edited directly. If an IP needs adaptation, that logic
  goes in `rtl/wrappers/`, not in the IP's own source tree.

---

## 7. What's Deliberately Deferred

- NDA accelerator, HPM, watchdog *behavior* (only WDT's register shell is
  in baseline scope) — second wave, after RAM/UART/Timer/GPIO/WDT-shell
  pass all three verification levels.
- WDT's signal-tap logic (what triggers a trip) — depends on decisions
  not yet made about what it's watching.
- AXI4 signal-level HPM snoop details — open item, deferred to the HPM
  phase.
- VeeR EL2 MPU data access window configuration for MMIO regions — open
  item, needs resolving before or during Level 2/3 testing.
