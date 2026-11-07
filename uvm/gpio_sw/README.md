# Software-driven GPIO with passive UVM

This is a separate implementation from the active GPIO environment in
`uvm/gpio/`. Both remain available. The existing `sw/gpio_test/main.c` is
unchanged. `sw/gpio_uvm_test/main.c` adds explicit output walking-one/zero,
alternating/zero/ones patterns, upper-bit checks, direction switching, and
readback through the CPU.

## Run from the project root

```sh
# Existing C program, real VeeR core, passive GPIO verification.
make -C uvm sw-gpio

# Expanded C GPIO scenario.
make -C uvm sw-gpio SW_PROGRAM=gpio_uvm_test

# Both programs. Compile-only is available through the separate Makefile.
make -C uvm sw-regression
make -C uvm/gpio_sw compile

# The fabric without HPM uses separate outputs/configuration.
make -C uvm sw-gpio HPM=0

# Waveforms: core, software completion, and observed GPIO are grouped.
make -C uvm sw-gpio SW_PROGRAM=gpio_uvm_test WAVES=1
make -C uvm sw-verdi SW_PROGRAM=gpio_uvm_test

make -C uvm sw-help
```

Defaults: `SW_PROGRAM=gpio_test`, `SEED=1`, `HPM=1`. A program name selects
`sw/<name>/main.c`; an absolute directory is also accepted. `RUN_ROOT` must
be absolute when overridden. `SIM_ARGS`, `VCS_HOME`, `VERDI_HOME`, and
`WAVES=0|1` work as in the active flow. `UVM_TEST` defaults to `gpio_sw_test`.
The selected C program must use the GPIO UART tag and common startup/result
conventions. No host-side C/DPI routine generates AXI transactions.

Default outputs are `run/uvm/gpio_sw/` (`gpio_sw_nohpm/` for HPM=0):

- `veer_config/`: generated core configuration and filtered source list.
- `build/` or `build_waves/`: simulator and private compile state.
- `<program>/seed_<seed>[_waves]/`: ELF/map/bin/hex, simulation log, FSDB.

The root Makefile's configuration rules generate a fresh, isolated core
configuration. The existing software builder generates the C image and
regenerates the tracked `sw/common/soc_map.h`; inspect any resulting diff.
Avoid concurrent software image builds because that generated header is shared.
Use a separate custom `RUN_ROOT` for each HPM configuration, as the default
paths already do; reusing one custom output tree for different HPM values is
not supported by the cached build layout.
Image initialization occurs before reset release and is harness setup,
not a runtime bus driver.

## Ownership and flow

```text
C load/store instructions running on VeeR
    → core IFU/LSU/SB → width adapter → SoC interconnect → GPIO
                                                        ↓
                               read-only interface copies → UVM monitor
                                                        ↓
                                              independent scoreboard
```

`tb_gpio_sw_uvm.sv` instantiates the existing `tb_soc_sw` with
`EXTERNAL_COMPLETION=1`. That opt-in mode exposes completion status instead
of ending simulation; the default legacy mode still performs its original
checks and calls `$finish`. The UART receiver, RAM signature, core trace,
core configuration, and SoC wiring are reused rather than duplicated.

The separate `gpio_sw_test` creates the existing `gpio_env` with
`cfg.is_active=UVM_PASSIVE`. It checks that both drivers and both sequencers
are absent. Factory creation and typed `uvm_config_db::set/get` still apply
to configuration, interfaces, environment, monitor, and scoreboard. No active
sequence is started and no UVM signal assignment feeds the core or SoC.

`axi` contains observation copies from `system.dut.u_gpio`'s slave ports.
The copies keep the shared VIP's virtual interface type while leaving the
hardware completely owned by the CPU/fabric. Tapping this boundary excludes
instruction fetch, UART, RAM, NDA and other peripheral traffic from the GPIO
reference model. `pins` observes the actual GPIO input/output and DIR probe.

The existing software harness supplies the fixed external input `0xA5`.
This is an external fixture, not a value written by software to the read-only
IN register. There is no random pin stimulus or contention in this mode.
The active plan tests retain their resolved-pad and external-drive scenarios.

## Checking and completion

The passive scoreboard checks accepted writes, read data/IDs/responses,
output masking, reset values, input sampling and unfinished transactions.
The interface assertions check stalled AXI payload/VALID stability.
Software independently compares its register reads and returns zero/nonzero.

The UVM test holds its run objection until the reused harness has observed
ebreak and allowed the UART FIFO to drain. It then requires all of:

- Harness checks passed.
- UART contains `GPIO OK` and no FAIL text.
- The core produced an ebreak indication.
- Independent RAM signature at `0x7FF0` equals `0x50515353`.
- Passive scoreboard and protocol assertions report no errors.

UVM check/report phases run before the simulator exits. `check_uvm.py` also
requires the exact UVM test PASS banner and clean error/fatal summaries,
because the simulator can return zero after a failure.

Negative infrastructure check (must return nonzero):

```sh
make -C uvm sw-gpio SW_PROGRAM="$PWD/uvm/gpio_sw/negative"
```

The fixture performs real GPIO accesses but prints `GPIO FAIL` and returns
one. It must fail UART/signature/completion checks; a clean passive GPIO
model alone cannot turn failing software into a PASS.

## Coverage limits

This flow exercises the complete software-to-GPIO path, including adapter
and interconnect, for the selected programs. The expanded C program covers
the software-accessible OUT/direction/pattern subset of SOC-027/028/029.
It does not close shared-pad loopback/contention, external input pattern
sweeps, software bus-fault handling, or reset-in-flight. Fixed input `0xA5`
does not make the full harness literally clock/reset-only. There is no
forced AXI backpressure or pipelined UVM driver in the passive flow: bus
timing is generated by the real hardware. The active flow remains responsible
for the deliberate protocol corner cases and pad-model scenarios.

## Waveform guide

`sw-verdi` automatically restores `waves.rc` in this directory. Group 02
shows completion, signature, PC, ebreak trace, and UART. Group 03 shows the
GPIO pins/registers. Groups 04/05 show only GPIO accesses from the CPU;
groups 06/07 show LSU traffic and instruction fetches at the core boundary.
In the expanded program, find OUT writes at `0x10020000` with patterns
00/FF/AA/55 followed by walking-one/zero. DIR writes use `0x10020008`.
The GPIO input stays A5 throughout because this mode uses the fixed fixture.
At successful completion, `signature=50515353`, `uart_ok=1`,
`ebreak_seen=1`, and finally `done=passed=1`.

## Verification record — 2026-11-07

VCS U-2023.03 with installed UVM 1.2:

| Command | Result |
|---|---|
| `make -C uvm sw-regression` | Both PASS: original C 38232 checks (6 reads, 8 writes); expanded C 83970 checks (76 reads, 41 writes) |
| `make -C uvm sw-gpio HPM=0` | PASS: original C, 38232 checks in the 2x6 build |
| `make -C uvm sw-gpio SW_PROGRAM=gpio_uvm_test WAVES=1` | PASS: 83970 checks; FSDB/KDB generated |
| `make -C uvm sw-gpio SW_PROGRAM="$PWD/uvm/gpio_sw/negative"` | Expected failure: UART, signature and harness-status checks fail; Make returns nonzero |
| `make -C uvm regression SEED=1` | All six original active/pad-model tests PASS, unchanged counts |
| `make sw IP=gpio RUN_ROOT="$PWD/run/uvm/gpio_sw/legacy"` | Original non-UVM software flow PASS, two harness checks |
| `make -C uvm sw-help` | PASS; passive commands/options displayed |

All positive UVM runs reported zero UVM warnings/errors/fatals. The passive
topology contains no drivers/sequencers. Its monitor independently checked
the GPIO slave boundary; UART/software fetch traffic was excluded. Generated
`soc_map.h` had no content diff. Compile warnings are the existing unsupported
Linux (`LNX_OS_VERUN`) and uninstantiated upstream lockstep interface (`UII-L`).

The software waveform view was restored and saved using Verdi U-2023.03-SP1
batch mode: all seven groups and 59 signal entries were present. Verdi used
the available Apex license after an Elite-license fallback warning. No GUI
was opened by this verification. Full non-GPIO software regressions were not
rerun; design RTL and vendor sources were not changed.
