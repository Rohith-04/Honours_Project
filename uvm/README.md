# GPIO UVM VIP

This directory contains the first per-IP UVM VIP: an end-to-end environment
for the existing `rtl/wrappers/gpio_wrapper.sv`. All UVM source and tooling
live here. The original RTL, BFM tests, and root Makefile are unchanged.
The installed VCS UVM 1.2 library supplies UVM; no download is required.

The separate [software-driven passive environment](gpio_sw/README.md) runs
C on the real VeeR core and reuses this VIP's monitor/scoreboard without
creating drivers or sequencers. Use `make -C uvm sw-gpio` for the original
GPIO program, `make -C uvm sw-gpio SW_PROGRAM=gpio_uvm_test` for expanded C
patterns, or `make -C uvm sw-regression` for both. The active commands below
and their tests remain available independently.

## Run from the project root

```sh
# Compile and run the directed register/pin test.
make -C uvm gpio

# Exercise queued requests and independent AW/W/B/AR/R workers.
make -C uvm gpio TEST=gpio_pipeline_test SEED=1

# Replace the request type through the factory; require longer B/R stalls.
make -C uvm gpio TEST=gpio_factory_test SEED=1

# Run all six tests, the three spreadsheet GPIO checkpoints, or compile only.
make -C uvm regression
make -C uvm plan-regression
make -C uvm compile

# Change the driver's bounded request capacity through config_db.
make -C uvm gpio TEST=gpio_pipeline_test SEED=2 SIM_ARGS=+GPIO_QUEUE_DEPTH=2
make -C uvm gpio TEST=gpio_smoke_test SEED=2 SIM_ARGS=+GPIO_QUEUE_DEPTH=1

# Trace config_db lookups/assignments in the simulation log.
make -C uvm gpio SIM_ARGS=+UVM_CONFIG_DB_TRACE

# Show request/reply addresses, data, IDs, and channel delays.
make -C uvm gpio SIM_ARGS=+UVM_VERBOSITY=UVM_HIGH

# Build a separate debug executable, dump FSDB, then open Verdi.
make -C uvm gpio TEST=gpio_pipeline_test WAVES=1
make -C uvm verdi TEST=gpio_pipeline_test

# Check that failure diagnostics cannot be accepted as a passing log.
make -C uvm check-log-parser
```

Override `VCS_HOME` and `VERDI_HOME` for another installation. `RUN_ROOT`
must be absolute when overridden. Results default to
`run/uvm/gpio/<test>/seed_<seed>/sim.log`; wave runs use a `_waves` suffix.
Shared compile state is in `run/uvm/gpio/build/` or `build_waves/`.
Seed/configuration reruns overwrite that test/seed log; use another
`RUN_ROOT` to preserve a previous run. Do not run concurrent compiles into
the same build directory.

`scripts/check_uvm.py` requires the named test's nonempty PASS banner,
zero UVM ERROR/FATAL summaries, and no failure/assertion diagnostics.
VCS process exit status alone is insufficient. Assertions remain enabled
in ordinary runs. `WAVES=1` also enables FSDB and the Verdi debug database.
The viewer automatically loads `waves/gpio.rc`, grouping pads, GPIO registers,
AXI channels, and glitch-checker state. See [the waveform walkthrough](waves/README.md)
for the recommended test and signals for each checkpoint. `verdi` always selects
the wave-enabled run; only compilation/simulation needs `WAVES=1`.

## Structure and ownership

```text
tb_gpio_uvm
  gpio_axi_if ---------------------- GPIO AXI ports
  gpio_pin_if ---------------------- GPIO input/output pins
  gpio_wrapper                       unchanged DUT

gpio_smoke_test / gpio_pipeline_test / gpio_factory_test
  gpio_env
    gpio_agent
      bus_sequencer -> bus_driver -> gpio_axi_if
      pin_sequencer -> pin_driver -> gpio_pin_if
      monitor -> sampled bus/pin edges -> scoreboard
```

| File | Responsibility |
|---|---|
| `gpio/gpio_axi_if.sv` | AXI signals, drive/sample clocking blocks, stalled-transfer assertions |
| `gpio/gpio_pin_if.sv` | GPIO pin stimulus and sampled observations |
| `gpio/gpio_items.svh` | Requests/responses, pin items, configuration, sampled-edge objects |
| `gpio/gpio_driver.svh` | Bounded request admission, five independent bus workers, pin driver |
| `gpio/gpio_monitor.svh` | Passive interface observations; no DUT hierarchy access |
| `gpio/gpio_scoreboard.svh` | Independent register/pin model, response matching, coverage |
| `gpio/gpio_agent.svh` | Active/passive construction, sequencer/driver wiring, environment |
| `gpio/gpio_sequences.svh` | Register/error/strobe, pipeline, and external-input scenarios |
| `gpio/gpio_plan_sequences.svh` | SOC-027/028/029 output, direction/contention, and full pattern tests |
| `gpio/gpio_tests.svh` | Configuration, objections, test selection, factory override, completion checks |
| `gpio/gpio_plan_tests.svh` | Spreadsheet-named tests and component checkpoint checks |
| `gpio/tb_gpio_uvm.sv` | Clock/reset, DUT/interface wiring, config_db set, run_test, watchdog |
| `gpio/gpio_vip_pkg.sv` | Package imports and dependency order |

## Factory and config_db

Factory macros register components/objects. Components, items, and sequences
are created with `type_id::create()`. `gpio_factory_test` overrides
`gpio_bus_item` with `gpio_backpressure_item`; its sequences verify the
created dynamic type, and the replacement constrains response stalls.

The HDL top sets typed virtual interfaces at `uvm_test_top` using
`uvm_config_db::set`. The test gets them, creates `gpio_config`, and sets
that object for the environment. The environment sets it for the agent,
and the agent sets it for its driver/monitor children. Each consumer checks
its `get()` result; missing interfaces or invalid queue/timeout values are
fatal. The optional `GPIO_QUEUE_DEPTH` plusarg demonstrates a scalar set/get.
Default depth is eight; supported configuration is 1–64.

Transactions carry bus data through sequencer/driver TLM and asynchronous
responses. They are not sent through config_db. The pin sequencer is separate
so external input activity can run concurrently with bus traffic.

## Pipeline contract

The bus driver admits requests into bounded storage, clones each request,
preserves its UVM sequence/transaction IDs, then calls `item_done()`. The
sequence may reuse its original object immediately. Independent AW, W, AR,
B, and R workers process owned requests. Each channel preserves order; AW
and W may arrive in either order, and read/write traffic can overlap.
Single-beat replies use `put_response()` and are retrieved with
`get_response(..., transaction_id)`. The pipeline sequence intentionally
queues a batch before collecting replies.

`peak_inflight` counts driver-owned requests, including those waiting in
queues. It does **not** mean the GPIO hardware accepts eight outstanding
transactions. The DUT accepts one read and one write independently; the next
request legally waits with VALID and payload held stable. Request capacity
is released only after the B/R handshake. Replies already queued to a
sequence are not included in that capacity. These finite sequences retain
their responses until explicitly collected.

The response workers first observe VALID with READY low, then delay READY.
This guarantees that response backpressure was actually exercised. Timeouts
bound missing handshakes/responses; a separate HDL watchdog bounds the test.
Clocking blocks sample pre-edge and drive after the edge, avoiding RTL/UVM
race conditions.

## Functional checks

The monitor publishes one new, immutable observation per rising edge.
The scoreboard uses only interfaces, not the DUT's internal registers or
the sequence's intended values. It checks:

- Reset values; continuous output value `OUT & DIR`.
- OUT/DIR low-byte writes, zero strobes, ignored upper byte strobes, and
  read-as-zero upper register bits for the current eight-pin configuration.
- Synchronized IN data, captured at read-address acceptance from the previous
  clock's external input sample.
- Read-only IN writes, undefined/misaligned offsets, SLVERR, and no effects
  from invalid writes.
- Read values captured at AR acceptance, including reads concurrent with
  writes (the read sees the pre-write value on the same edge).
- B/R IDs, response ordering, no orphan replies, no unfinished requests,
  and agreement between driver and monitor completion counts.
- Stable VALID/payload under stalls on all five channels.
- With the plan tests' pad model enabled: resolved pad values, output-enable
  agreement with modeled DIR, loopback, and intentional four-state contention.

`soc_gpio_out_test`, `soc_gpio_dir_test`, and `soc_gpio_walking_test` map to
the root workbook's SOC-027/028/029. See [PLAN_COVERAGE.md](PLAN_COVERAGE.md)
for exact checkpoints, the simulation-only OE probe, digital-pad resolution,
event-based glitch checks, and remaining C/full-SoC scope.
That document also records the current six-test results after plan alignment;
the original results at the end of this README are historical.

The original smoke test checks 40 bus completions. Pipeline and factory tests each
check 170; check counts vary with seed because pin comparisons also run every
clock. Pipeline tests additionally require multiple admitted requests,
read/write overlap, and observed AW/W/AR stalls. All tests require B/R stalls,
zero/upper-only strobes, and five expected error replies.

The covergroup samples observed operation, register offset, strobe classes,
and error response. Its percentage describes only these declared bins; it
does not establish exhaustive functional, code, or protocol coverage.

## Scope and extension points

This is a standalone GPIO VIP, with no core, interconnect, or other IPs in
its test harness. It uses the repository's fixed 32-bit bus, 12-bit IDs, and
eight pins. All transfers are aligned word-sized single-beat INCR except
deliberate invalid offsets. The legacy GPIO RTL ignores size/burst qualifiers
and cannot drain a real multi-beat burst; this VIP does not claim full AXI4
burst compliance or change that behavior.

Initial reset is verified. Mid-run reset cancellation is explicitly rejected
by the active driver until response cancellation and queue flushing are
designed. Queue depth one is a serial smoke configuration; pipeline tests
require at least two. Active mode is tested; passive mode omits drivers and
sequencers but requires an external stimulus owner and observation of reset.
Further work includes reset-in-flight, broader parameterization, and full-SoC
reuse. Other IPs should get their own VIP directories and functional models;
factor out shared AXI machinery when adding the next concrete user.

## Original verification record — 2026-11-07, before plan alignment

Executed with VCS U-2023.03 and its installed UVM 1.2. These historical counts
predate the additional OE/pad comparisons. Each positive UVM run
reported zero UVM warnings, errors, and fatals and passed the log validator.

| Command | Result |
|---|---|
| `make -C uvm regression SEED=1` | PASS: smoke 478 checks; pipeline 1284; factory override 1490 |
| `make -C uvm gpio TEST=gpio_pipeline_test SEED=2 SIM_ARGS=+GPIO_QUEUE_DEPTH=2` | PASS: 1417 checks, peak admitted requests 2 |
| `make -C uvm gpio TEST=gpio_smoke_test SEED=2 SIM_ARGS='+GPIO_QUEUE_DEPTH=1 +UVM_CONFIG_DB_TRACE +UVM_VERBOSITY=UVM_HIGH'` | PASS: 470 checks; interface/configuration get/set and request/reply traces present |
| `make -C uvm gpio TEST=gpio_pipeline_test SEED=1 WAVES=1` | PASS: 1284 checks; FSDB and Verdi KDB generated |
| `make -C uvm check-log-parser` | PASS: seven validator tests |
| `make unit IP=gpio RUN_ROOT="$PWD/run/uvm/gpio/legacy"` | PASS: original BFM unit test, 17 checks |
| `make -C uvm gpio TEST=gpio_smoke_test SEED=0 SIM_ARGS=+GPIO_QUEUE_DEPTH=0` | Expected rejection: configuration fatal and nonzero Make status |

Seed-one pipeline activity included 170 completed transactions, peak request
admission of eight, 354 read/write overlap cycles, and stalls on AW/W/AR/B/R
of 260/303/106/334/313 clocks. The two-entry run also observed every channel's
stall condition. The declared covergroup reported 100% for these runs; that
is limited to the bins described above.

The initial two-entry stimulus alternated directions and missed AR stalls.
Pairing requests by direction closed that stimulus gap while retaining the
required checks. The initial legacy command with default outputs failed
because an existing compile log was not writable; the isolated command above
passed without changing file permissions. Compile logs retain the existing
VCS unsupported-Linux warning (`LNX_OS_VERUN`). The Verdi GUI was not opened;
FSDB generation and the debug database were verified. Full-SoC regressions
were not rerun because this change adds a standalone verification flow and
does not modify design RTL or the existing build recipes.
