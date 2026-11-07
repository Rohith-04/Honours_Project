# GPIO verification-plan traceability

Source: root `verification_plan.xlsx`, sheet **SoC**, rows **28–30**.
The spreadsheet is unchanged. Its C/SV names describe proposed tests;
this document maps implemented standalone SV tests to those checkpoints.
The test names below match the spreadsheet's SV column.

| Plan ID | UVM test / sequence | Implemented component checks | Remaining SoC scope |
|---|---|---|---|
| SOC-027 (row 28) | `soc_gpio_out_test` / `soc_gpio_out_sequence` | DIR all outputs; zero, ones, A5, 5A, 3C; OUT readback; continuous output checks; resolved-pad IN loopback; upper bits set on writes and checked zero on readback | `soc_gpio_out.c` through VeeR/adapter/fabric is not implemented here |
| SOC-028 (row 29) | `soc_gpio_dir_test` / `soc_gpio_dir_sequence` | External inputs; each pin switches input→output→input while the other seven drive; OUT versus previous external value; conflict resolves X on the selected pin; release recovers the output; floating input weakly zero; per-event output disturbance checks | `soc_gpio_dir.c` and real pad-cell/electrical behavior are outside this harness |
| SOC-029 (row 30) | `soc_gpio_walking_test` / `soc_gpio_walking_sequence` | For OUT and external input separately: 00, FF, AA, 55, walking-one and walking-zero for all eight pins; every pattern read back; input activity leaves OUT/DIR unchanged; monitor checks both levels on every input/output bit | `soc_gpio_walking.c` through the complete SoC is not implemented here |

Run just these checkpoints:

```sh
make -C uvm plan-regression SEED=1
```

Run the original smoke/pipeline/factory tests plus these three:

```sh
make -C uvm regression SEED=1
```

## Explicit digital-pad contract

The RTL exports separate `gpio_in` and masked `gpio_out` signals. It has no
public output-enable port or bidirectional pad cell. The UVM pin interface
therefore offers two modes:

- Existing tests keep direct mode: external values directly drive `gpio_in`.
- Plan tests use pad mode: `gpio_in` samples a resolved net shared by the
  internal output driver, an optional external driver, and a weak pull-down.

An internal driver is enabled when DIR is one. The harness obtains that
enable from the explicit `dut.dir_reg` probe in `tb_gpio_uvm.sv`; the
scoreboard checks it against its independent bus-derived DIR model.
This is a verification adapter for an unexported control signal, not a new
RTL interface. Moving to another DUT hierarchy requires updating that one
probe or providing a real OE port.

| Internal enable | External enable | Resolved pad |
|---|---|---|
| 0 | 0 | Weak zero |
| 0 | 1 | External value |
| 1 | 0 | OUT value |
| 1 | 1, values equal | Common value |
| 1 | 1, values opposite | X |

Input readback follows the RTL's one-clock input sampling latency. Both
the response object and reference model retain four-state values, so an
expected conflict is checked as X, never converted to zero. The chosen
pull-down and equal-strength resolution are explicit testbench assumptions;
they do not specify a board or physical I/O-cell electrical contract.

The scoreboard compares pad resolution using its own truth table and
continuously checks `gpio_out = OUT & DIR`. A separate event checker tracks
all `gpio_out` changes, including pulses between clock samples. An accepted
OUT write can affect output-enabled bits; a DIR write can affect only bits
whose direction changes. A bit may transition at most once on that edge.
This checks disturbance of unchanged output bits at simulator event/time
resolution, not analog pulse widths or physical timing closure.

The checker has an opt-in negative test. It must fail:

```sh
make -C uvm gpio TEST=soc_gpio_out_test SEED=99 SIM_ARGS=+GPIO_INJECT_GLITCH
```

The harness injects a one-nanosecond pulse between rising clock samples.
`GPIO_GLITCH` must report the transition and Make must return nonzero.
Ordinary runs do not force any signals.

## Coverage boundaries

These tests implement the GPIO **component-level SV checkpoints** under the
documented digital-pad contract. They do not close the whole SoC rows or
their proposed C programs. The earlier access covergroup remains a limited
register/protocol coverage metric; its percentage does not represent plan
completion. Explicit sequences, assertions, and per-test checks provide the
checkpoint evidence.

Related reset/core/system requirements (SOC-002, SOC-005/006, SOC-030–034,
SYS-01) retain their broader scope. Reset-in-flight remains unsupported by
the active VIP. No root spreadsheet status or expected behavior was changed
to make a regression pass.

## Executed results — 2026-11-07

VCS U-2023.03 with installed UVM 1.2:

| Command | Result |
|---|---|
| `make -C uvm plan-regression SEED=1` | PASS: SOC-027 727 checks; SOC-028 4403; SOC-029 5274 |
| `make -C uvm regression SEED=1` | All six PASS; original smoke/pipeline/factory now report 845/2132/2544 checks with the additional OE comparisons |
| `make -C uvm gpio TEST=soc_gpio_dir_test SEED=1 WAVES=1` | PASS: 4403 checks; FSDB and Verdi KDB generated |
| `make -C uvm gpio TEST=soc_gpio_out_test SEED=99 SIM_ARGS=+GPIO_INJECT_GLITCH` | Expected failure: two GPIO_GLITCH errors at 302/303 ns; Make exits nonzero |
| `make -C uvm check-log-parser` | PASS: seven tests |
| `make -C uvm help` | PASS: includes plan tests and plan-regression |

SOC-028 observed 264 conflicting-pin samples and verified X readback for
each selected pin. The injected glitch test reported no sampled scoreboard
mismatches: the pulse fell entirely between clock samples and was caught by
the event checker, demonstrating why both checks are needed. All six positive
UVM tests reported zero UVM warnings/errors/fatals. The compile retains the
existing VCS unsupported-Linux warning (`LNX_OS_VERUN`). The Verdi GUI was
not opened. Design RTL and the root spreadsheet remain unchanged; full-SoC
software/integration regressions were not rerun for this testbench-only change.

## Software-driven passive path

`make -C uvm sw-regression` now runs both the original `sw/gpio_test` and
expanded `sw/gpio_uvm_test` programs on VeeR through the adapter/fabric with
passive UVM GPIO checking. The expanded program adds C-side OUT walking-one,
walking-zero, alternating/zero/ones patterns, whole-register upper-bit checks,
and per-bit direction switching/readback. This covers software-accessible
subsets of SOC-027/028/029; it does not replace their remaining pad/input
requirements or provide the separately named proposed C programs above.

The software harness's external input remains fixed at `0xA5`; this path
does not test resolved-pad loopback, external input pattern sweeps or driver
contention. The active tests retain those digital-pad checks. See
[gpio_sw/README.md](gpio_sw/README.md) for the passive topology, result
ownership, run commands, and current verification record.
