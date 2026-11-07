# GPIO Verdi waveform walkthrough

The view `gpio.rc` loads automatically through the UVM Makefile. It uses
the selected run's FSDB and restores signal groups without saving a particular
FSDB path, test, seed, or workstation directory in the view.

## Open the direction/contention test first

From the project root:

```sh
# Generate or refresh the waveform and its matching debug database.
make -C uvm gpio TEST=soc_gpio_dir_test SEED=1 WAVES=1

# Open Verdi with all GPIO groups already populated.
make -C uvm verdi TEST=soc_gpio_dir_test SEED=1
```

The `verdi` target always opens the `_waves` run and `build_waves` database.
You do not need `WAVES=1` on the viewer command. Keep `TEST`, `SEED`, and any
custom absolute `RUN_ROOT` consistent between generation and viewing.
Verdi session files are written inside the selected run directory.
If you already generated the matching FSDB, only the second command is needed.

For another saved view, use `WAVE_VIEW=/absolute/path/custom.rc`. In an
already open nWave window, use **File → Restore Signal** and select
`uvm/waves/gpio.rc`. Use **Zoom All** to locate activity, then zoom around a
write or read; individual clock cycles are 10 ns.

## Groups and what to inspect

| Group | Signals | What they tell you |
|---|---|---|
| `01_clock_reset` | `clk`, `aresetn` | Reset is active low; clock period is 10 ns |
| `02_GPIO_pads_binary` | `pad_mode`, `external_enable`, `external_value`, `output_enable`, `gpio_out`, `pad`, `gpio_in`, `in_sync` | Who drives each pin, resolution/loopback, and input sampling |
| `03_GPIO_registers` | `out_reg`, `dir_reg`, `in_sync`, `wstate`, `rstate` | Programmed values and DUT channel state |
| `04_AXI_write_address_AW` | AW VALID/READY/address/ID/qualifiers | Accepted write address and stalls |
| `05_AXI_write_data_W` | W VALID/READY/data/strobes | Accepted write data and enabled bytes |
| `06_AXI_write_response_B` | B VALID/READY/ID/response | Write completion and deliberate response stalls |
| `07_AXI_read_address_AR` | AR VALID/READY/address/ID/qualifiers | Accepted read request |
| `08_AXI_read_response_R` | R VALID/READY/ID/data/response | Returned data and read completion |
| `09_output_glitch_checker` | `observed_awaddr`, `allowed_changes`, `changed_this_edge`, `previous_output` | Which output bits a write may change, and which have transitioned |

Pin buses use binary so a single X bit remains obvious. Registers, addresses,
IDs and data use hexadecimal. `in_sync` appears twice intentionally: next to
the pads for latency inspection and next to the register state for readback.

## Follow one write and read

GPIO register addresses are OUT `0x10020000`, IN `0x10020004`, and
DIR `0x10020008`.

1. Find an edge where `awvalid && awready` is one. Note `awaddr` and `awid`.
2. Find the associated `wvalid && wready` edge. Inspect `wdata` and
   `wstrb[0]`; byte zero controls the implemented eight GPIO bits.
3. Immediately after that edge, the addressed OUT/DIR register updates.
   `gpio_out` follows `out_reg & dir_reg`.
4. `bvalid` announces a response. The driver deliberately keeps `bready`
   low for a while; write completion occurs at `bvalid && bready`.
   `bid` must equal the original `awid`.
5. For a read, capture `araddr`/`arid` on `arvalid && arready`. The GPIO
   captures that register's value at this edge. Inspect `rdata` when
   `rvalid` appears; it must remain stable until `rvalid && rready`.

`bresp/rresp` binary `00` means OKAY and `10` means SLVERR. OUT/DIR may
update before B is accepted; delayed response acceptance must not repeat the
write. The GPIO write FSM is 0=IDLE, 1=DATA, 2=RESP; read FSM is 0=IDLE,
1=RESP. A read and write accepted on the same edge use the pre-write value
for the read. This VIP only generates single-beat transfers.

## Inspect each verification-plan case

**SOC-027 — output and IN loopback**

```sh
make -C uvm gpio TEST=soc_gpio_out_test WAVES=1
make -C uvm verdi TEST=soc_gpio_out_test
```

Focus on groups 02/03 and the AXI read data. With `pad_mode=1`,
`external_enable=00000000`, and `dir_reg=FF`, check that `out_reg`,
`gpio_out`, `pad`, and `gpio_in` agree. `in_sync` samples `gpio_in` on
the rising edge; an IN read accepted on that same edge sees the previous
`in_sync` value. The sequence allows settling before comparing IN readback.
Upper bits written to OUT/DIR do not appear in register readback.

**SOC-028 — direction switching and conflict**

Use the first command pair in this guide. Expand group 02 and follow one
bit, starting with bit zero. The test moves that bit through these states:

| `output_enable[i]` | `external_enable[i]` | Expected pad |
|---|---|---|
| 0 | 1 | `external_value[i]` |
| 1 | 1, opposing values | X on this bit |
| 1 | 0 | `out_reg[i]` |
| 0 | 0 | Weak zero |
| 0 | 1 | External value again |

Other bits keep their programmed outputs while the selected bit changes
direction. The X during deliberate conflict is expected; it propagates into
`in_sync` and the selected bit of an IN read. The scoreboard checks it as X.
After external release, the resolved pad recovers. This is the documented
digital pad model, not an analog I/O-cell simulation.

For the verified seed-one direction run, zoom to **600–1100 ns**. Bit zero
first conflicts at **645 ns** (`pad=1010010x`), `in_sync` captures that X at
**655 ns**, and the external driver releases at **1045 ns**. These times
are specific to this test/seed/build; use the signal transitions for other runs.

**SOC-029 — independent pin patterns**

```sh
make -C uvm gpio TEST=soc_gpio_walking_test WAVES=1
make -C uvm verdi TEST=soc_gpio_walking_test
```

In the first section, DIR is FF and OUT/pads walk through 00, FF, AA, 55,
then walking-one and walking-zero values. Each pattern is read back. In the
second section, DIR is 00, external values repeat the patterns, output pins
remain zero, and IN reads follow the external pins.

## Inspect driver pipelining

```sh
make -C uvm gpio TEST=gpio_pipeline_test WAVES=1
make -C uvm verdi TEST=gpio_pipeline_test
```

Start with groups 04–08. Look for read activity while a write request or
response is still active. When VALID is high and READY is low, the associated
address/data/ID must stay stable. AW and W can be presented in either order;
the GPIO accepts W only after accepting AW. The next AW/AR may be waiting
while the previous response is stalled. This is useful visible evidence of
channel concurrency; it does not mean eight hardware transactions were accepted.

This test uses `pad_mode=0`: GPIO inputs come directly from `external_value`.
The resolved `pad` signal is not the selected input path in this mode.

UVM request objects, mailboxes and sequence transaction IDs are class data,
not ordinary HDL signals in this saved view. To follow those, run with
`SIM_ARGS=+UVM_VERBOSITY=UVM_HIGH` and match `GPIO_REQUEST`/`GPIO_RESPONSE`
lines by `tx=`. The waveform's AWID/BID and ARID/RID are AXI IDs; they have
a different role from the UVM transaction ID.

The negative `+GPIO_INJECT_GLITCH` scenario deliberately fails. If you dump
that run, zoom around 302–303 ns: the one-nanosecond output pulse falls
between clock samples and the event checker reports it. Its Verdi view is
opened separately after the failed simulation command; the failure is expected.

## Validation

The installed Verdi U-2023.03-SP1 restored this view in batch mode from the
SOC-028 FSDB and saved the restored signal list. All nine groups and all 46
signal entries were restored. `fsdbreport` independently confirmed the example
contention times above. Verdi fell back from its unavailable Elite license
to the available Apex license and completed successfully. The viewer recipe
was checked with `make -C uvm -n verdi TEST=soc_gpio_dir_test`; RTL and UVM
simulation code were unchanged, so no simulation regression was rerun.
