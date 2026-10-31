# Phase 2 directed baseline

This is the current Phase 2 correctness baseline. The older Phase 1 planning
and bring-up documents remain historical references. UVM, performance
characterization, synthesis and FPGA implementation are separate work.

## Reproduce

Use the workstation's existing Synopsys license environment. Do not put license
server configuration in the repository. `VCS_HOME` and `VERDI_HOME` may be
overridden; Make supplies this workstation's installation paths as defaults.

```sh
make phase2
make phase2 HPM=0
```

The first command runs seven unit tests, a second NDA run against a queued
AXI responder, integration, and six software tests. The second repeats the
baseline with the HPM removed from the fabric. Logs and compilation state
are isolated under `run/phase2/` and `run/phase2_nohpm/`; the extra NDA run is
under `pipeline/unit_nda/`. Historical `run/unit_*`, `run/sw_*`, root `csrc/`,
and `build/veer/` are preserved.

Individual commands remain available:

```sh
make unit IP=nda
make unit IP=wdt
make unit IP=hpm
make integration
make sw IP=nda
make sw IP=hpm
make sw IP=wdt
```

`RUN_ROOT=/absolute/path` selects another output directory. Each target uses
an explicit simulation top and its own VCS `-Mdir`. The simulator log must
contain the expected PASS banner and no failure/fatal messages: VCS on this
workstation can return exit status zero after `$fatal`, so process status
alone is insufficient. `scripts/check_sim.py` enforces this for ordinary Make
targets and Verdi runs.

## Configuration and software

The subsystem map remains the one in `rtl/soc/soc_pkg.sv`, not the separate
team memory-map PDF. CPU is M0; NDA is M1. RAM/UART/timer/GPIO/NDA/WDT/HPM
are slave ports 0 through 6. `HPM=0` selects the 2x6 fabric and defines
`HAVE_HPM=0` for C; the HPM region returns DECERR. The HPM software executable
then explicitly skips HPM accesses; the integration test checks absence.

Software uses `sw/common/nda.h`, `hpm.h`, and `wdt.h`. MMIO writes fence;
NDA START publishes source-array stores with a memory/compiler fence. Boot
sets MRAC regions 1 and 5 side-effecting/non-cacheable and initializes BSS.
The linker checks that code/data do not overlap the signature at 0x7ff0.

VeeR configuration is generated separately into `build/veer_phase2/`, with
`RV_ROOT` and `BUILD_PATH` supplied. The generated PIC address-mask header
must be nonempty. The historical `build/veer/pic_map_auto.h` was empty;
that configuration could execute polling tests but produced unknown PIC
register writes. No vendor core RTL was changed to fix this integration issue.

The software harness routes active-high level interrupts to VeeR PIC sources:

| Source | Device |
|---|---|
| 1 | UART |
| 2 | Timer |
| 3 | NDA |
| 4 | WDT |

The PIC base and source IDs are defined in `soc_pkg` and generated into the
C map. The harness checks the PIC base against the generated VeeR configuration.
`phase2_irq.h` configures the core-local PIC, uses direct `mtvec`, claims the
source, clears the peripheral, clears the gateway, and returns with `mret`.
It does not enable interrupt nesting. NDA and WDT programs check that their
ISR ran exactly once. The timer baseline remains polling-based.

## Contracts

- The serial fabric retains transaction ownership through the response
  handshake. Round robin operates on AW/AR request entries. It does not
  provide multiple concurrently serviced memory transactions.
- Phase 2 CSR slaves support aligned, word-sized, single-beat INCR accesses.
  Unsupported size/burst/offset accesses return SLVERR with no write effects.
  Rejected full-AXI bursts consume/return the declared beat count and drive
  RLAST on the final read response, so the fabric can recover.
- Byte strobes apply to writable bytes. START/ABORT/W1C require byte-zero
  strobe. OP/SRC/LEN writes and START while BUSY are rejected.
- NDA holds an already presented AR through acceptance even after abort.
  Accepted responses are drained and discarded. Completion error status and
  IRQ become visible only after draining. A same-cycle read error takes
  priority over abort. ABORT while idle has no effect on the next job.
- NDA CYCLES counts elapsed clocks from accepted START write through completion.
- WDT arms on busy rise, reloads on accepted data, and trips on the TIMEOUT-th
  cycle without progress after arming/reload. Progress wins at the timeout
  boundary. EN=0 or TIMEOUT=0 disarms; re-enabling during a job does not create
  a new busy edge. Each trip is one abort pulse; the next job can re-arm.
- HPM preserves the existing selective enable semantics: ENABLE gates CYCLES
  and NDA_BUSY. Bus-event and FALLBACKS counters run continuously. CLEAR wins
  over increments. SNAPSHOT saves all pre-edge live values together; reads
  return that immutable snapshot. CLEAR does not clear a previous snapshot.
  Disable first, then snapshot to obtain a frozen cycle count without the
  disable-edge increment ambiguity.

## Coverage and stimulus classification

Final regression results on 2026-10-31, VCS U-2023.03_Full64, Rocky Linux 8.10:

| Target | HPM=1 | HPM=0 |
|---|---|---|
| GPIO / timer / UART / RAM unit | PASS: 17 / 17 / 15 / 17 checks | Same |
| NDA unit, RAM responder | PASS: 48 checks | PASS: 48 checks |
| NDA unit, queued responder | PASS: 49 checks | PASS: 49 checks |
| WDT unit | PASS: 29 checks | PASS: 29 checks |
| HPM standalone unit | PASS: 24 checks | PASS: 24 checks (isolated block) |
| SoC integration | PASS: 128 checks | PASS: 124 checks |
| GPIO / UART / timer software | PASS: 2 / 2 / 3 harness checks | Same |
| NDA / WDT software | PASS: 3 / 3 harness checks | Same |
| HPM software | PASS: 2 harness checks plus C checks | PASS: absent-HPM accesses skipped |

Software harness counts do not count each C comparison: the main return value
and signature reflect those comparisons. These are freshly executed directed
tests, not the README's historical October 17 results.

| Test | Directed coverage | Classification |
|---|---|---|
| NDA unit | Reductions, signed multi-burst sums, ties, static errors and huge length, W1C/IRQ, zero strobes, pending-AR abort stability, injected bus error, hardware abort, drain-before-IRQ, restart | EXTERNAL |
| NDA queued-responder variant | Same cases with two queued bursts; explicitly checks simultaneous AR/RLAST was exercised | EXTERNAL |
| WDT unit | Progress reload, one trip/job, exact timeout and pulse width, IRQ/W1C/readback, next-job rearm, disable and zero timeout during busy | EXTERNAL |
| HPM unit | Exact synthetic event counts, selective enable, clear, stable/replaced snapshots, illegal/unaligned accesses | EXTERNAL |
| Integration | Real 2x7/2x6 decode, concurrent M0/NDA memory and GPIO traffic, four reductions across 4 KiB, exact NDA/HPM counts, delayed W and B/R backpressure with IDs, CSR burst rejection, temporary stall/trip/drain/restart, default timeout margin check | EXTERNAL |
| NDA C | 24 operation/length combinations crossing 4 KiB, wide positive/negative sums, signed extremes/ties, five static job errors, PIC-serviced completion, independent C reference | INTERNAL scenario |
| HPM C | Real CPU/NDA traffic, exact NDA address/beat counts, snapshots, frozen cycles, clear | INTERNAL scenario |
| WDT C | Injected temporary stall, PIC-serviced WDT IRQ, ABORTED, exact trip/fallback count, full C recomputation, successful next NDA job | EXTERNAL |
| GPIO C | Harness supplies 0xa5 input pattern | EXTERNAL |
| UART/timer C | Software-originated peripheral activity; timer IRQ is observed, not serviced | INTERNAL scenarios |

Classification is by stimulus origin, not checker location. All software
programs execute on real VeeR through the width adapter and fabric. Boot image
initialization is part of the software harness. The shared harness still ties
GPIO input to 0xa5; thus the complete harness is not literally clock/reset-only
even for internally stimulated scenarios. UART monitoring, signature reads,
and IRQ observation are passive checkers.

Software PASS requires the appropriate UART tag, no FAIL text, an ebreak,
and the independent RAM signature. NDA/WDT also require an observed IRQ;
C checks ISR counts, reference results and error status before returning PASS.

## Limits

WDT validation covers a **temporary** stall: the receiver's RREADY is held low
for 512 clocks, then released without corrupting RAM VALID/data. The WDT trips
at 128 idle clocks; NDA drains before software recomputes the entire array.
A permanently nonresponding slave can hold both DRAIN and the shared fabric
forever. No AXI cancellation, isolation/reset controller, or bounded permanent
fault recovery is claimed.

This is a directed simulation baseline, not exhaustive AXI compliance or
coverage closure. HPM 64-bit rollover, complete adapter input combinations,
all reset-in-flight cases, broader parameter sweeps, randomized verification,
and formal checking remain useful future verification work. RAM is still a
simulation model. No measured performance, area, timing or FPGA claim is made.
