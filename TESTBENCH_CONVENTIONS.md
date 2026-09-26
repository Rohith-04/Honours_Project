# Testbench Conventions — Code-Level Patterns

Companion to `PROJECT_STRUCTURE.md` and `PHASE1.md`. Those cover *what*
and *why*; this covers *how a test file is actually written* so every
`tb/unit/tb_<ip>_unit.sv` looks like a variant of the same pattern, not a
one-off. Consistency here is what makes the hierarchy visible at the code
level, not just the directory level.

Worked example throughout: UART. The same shape applies to Timer and
GPIO.

---

## 1. Test Lifecycle (every unit test follows this shape)

```
1. Instantiate DUT + BFM
2. Reset          (soc_reset — common task)
3. Configure       (IP-specific setup via BFM writes)
4. Stimulus        (drive the scenario being tested)
5. Check           (self-checking — compare actual vs. expected, no
                     manual waveform reading required to know pass/fail)
6. Report          (single PASS/FAIL banner, parseable by the Makefile)
```

Every test file should have these six sections identifiable at a glance —
comment-delimit them if it helps readability.

---

## 2. Self-Checking Pattern (checker task in `tb/common`)

Never rely on someone reading a waveform to determine pass/fail. Every
test ends with a machine-parseable result. Put this in
`tb/common/tb_tasks.svh` and use it everywhere:

```systemverilog
// tb/common/tb_tasks.svh

int unsigned pass_count = 0;
int unsigned fail_count = 0;

task automatic check_equal(
  input string    name,
  input logic [31:0] expected,
  input logic [31:0] actual
);
  if (expected === actual) begin
    pass_count++;
    $display("[PASS] %s: expected=0x%0h actual=0x%0h", name, expected, actual);
  end else begin
    fail_count++;
    $display("[FAIL] %s: expected=0x%0h actual=0x%0h", name, expected, actual);
  end
endtask

task automatic report_results(input string test_name);
  $display("==============================================");
  if (fail_count == 0) begin
    $display("TEST %s: PASS (%0d checks)", test_name, pass_count);
  end else begin
    $display("TEST %s: FAIL (%0d passed, %0d failed)",
              test_name, pass_count, fail_count);
  end
  $display("==============================================");
  $finish;
endtask
```

The Makefile / CI wrapper greps simulation output for the literal string
`TEST <name>: PASS` — this is what makes `make unit IP=uart` return a
clean pass/fail without you reading a log by hand every time.

---

## 3. BFM Usage Pattern

The BFM exposes simple procedural calls — no test should ever poke AXI
signals directly. If a test needs to touch a signal the BFM doesn't
expose, that's a sign the BFM's interface is incomplete, not a reason to
bypass it.

```systemverilog
// tb/common/tb_tasks.svh (continued) — IP-specific helper tasks
// These are the ONLY sanctioned way to interact with a peripheral from
// a test. They all bottom out in bfm.write/bfm.read — one implementation
// of "how to issue a transaction," reused by unit, integration, and
// (conceptually) mirrored by real software in tb/sw.

task automatic uart_send(virtual axi_master_bfm bfm, input byte c);
  bfm.write(soc_pkg::UART_BASE + soc_pkg::UART_TXDATA, {24'b0, c});
endtask

task automatic uart_read_status(virtual axi_master_bfm bfm, output logic [31:0] status);
  bfm.read(soc_pkg::UART_BASE + soc_pkg::UART_STATUS, status);
endtask
```

Naming convention: `<ip>_<action>` — `uart_send`, `timer_wait_match`,
`gpio_set_dir`. Keep them one AXI-level action each; compose
sequences (e.g. "send a whole string") in the test itself, not by
growing a task into a mini-program.

---

## 4. Unit Test File Template

```systemverilog
// tb/unit/tb_uart_unit.sv
//
// LEVEL 1 — DUT = uart_wrapper only. BFM drives it directly.
// No interconnect, no core. If this fails, the bug is in uart_wrapper
// or the underlying ips/uart core — nowhere else, by construction.

`include "tb_tasks.svh"
import soc_pkg::*;

module tb_uart_unit;

  logic clk = 0;
  logic rst_n;
  always #5 clk = ~clk; // 100MHz, adjust to match project convention

  // --- 1. Instantiate DUT + BFM ---
  axi_master_bfm bfm_if (.clk(clk), .rst_n(rst_n));

  uart_wrapper dut (
    .clk    (clk),
    .rst_n  (rst_n),
    .axi_if (bfm_if) // however your wrapper's AXI port is named
  );

  initial begin
    // --- 2. Reset ---
    soc_reset(rst_n);
    soc_start();

    // --- 3. Configure ---
    // (UART typically needs no config for a basic TX test; if baud rate
    //  or similar is configurable, set it here.)

    // --- 4. Stimulus ---
    uart_send(bfm_if, "H");
    uart_send(bfm_if, "i");

    // --- 5. Check ---
    // Confirm via the monitor/checker watching uart_tx, or via a
    // register readback if the wrapper exposes transmitted-byte status.
    // Example using a status register:
    logic [31:0] status;
    uart_read_status(bfm_if, status);
    check_equal("uart_tx_status_after_send", 32'h1, status);

    // --- 6. Report ---
    report_results("tb_uart_unit");
  end

endmodule
```

Every `tb/unit/*` file mirrors this exact skeleton with a different DUT
instantiation and different stimulus/check content. Someone should be
able to read one and immediately know how to read the rest.

---

## 5. Integration Test Difference

`tb/integration/tb_soc_integration.sv` follows the same six-section
shape, but:
- DUT is the interconnect + all 4 wrappers together (not one wrapper).
- Stimulus should include transactions to *multiple* slaves in sequence,
  specifically to catch cross-talk (e.g. write UART, then immediately
  read GPIO, confirm GPIO wasn't affected).
- Add at least one negative case: an address that doesn't map to any
  slave, confirming the interconnect handles it sanely (error response or
  defined behavior — decide what "correct" means here and check it).

---

## 6. SW-Driven Test Difference

`tb/sw/tb_soc_sw.sv` doesn't use the BFM at all — the real VeeR core is
the master. The self-checking pattern still applies, but the check
usually happens by monitoring UART console output against an expected
string, since that's the software-visible channel:

```systemverilog
// Simplified sketch — actual implementation depends on your UART monitor
string expected = "Hi\n";
string received;
// ... capture logic from uart_tx monitor ...
if (received == expected)
  $display("[PASS] SW UART output matched");
else
  $display("[FAIL] SW UART output: expected=\"%s\" actual=\"%s\"", expected, received);
```

This is the check your mentor specifically cares about — it validates
the entire toolchain-to-hardware path, not just the RTL.

Every C helper that performs a memory-mapped register write (`uart_send`,
timer writes, GPIO writes, etc.) must be followed by a `fence` instruction
(inline asm `asm volatile ("fence")`), per the VeeR EL2 Programmer's
Reference Manual, Memory Map chapter ("All memory-mapped register writes
must be followed by a `fence` instruction to enforce ordering and
synchronization"). This applies to `tb/sw` driver code only, not the BFM
(which issues raw AXI transactions with no core pipeline to fence).

---

## 7. Assertions (protocol-level, lives in RTL or bound in, not in the test)

Where it's cheap to do so, add SystemVerilog assertions at AXI interface
boundaries (wrapper input, interconnect ports) rather than relying solely
on the testbench to catch protocol violations. These act as an
independent checking layer — see the earlier discussion on why a single
checker (which could itself be wrong) isn't enough:

```systemverilog
// Example: address must remain stable while AWVALID is asserted and
// AWREADY is not yet high.
property axi_addr_stable;
  @(posedge clk) disable iff (!rst_n)
  (awvalid && !awready) |=> $stable(awaddr);
endproperty

assert property (axi_addr_stable)
  else $error("AWADDR changed while AWVALID asserted and AWREADY low");
```

Start with a small set covering the handshake rules you're most likely to
get wrong (valid held until ready, no combinational valid-on-ready
loops) rather than trying to assert the entire AXI spec at once.

---

## 8. Golden-Model Pattern (where applicable)

For IPs with computable expected behavior (Timer count value, GPIO
readback), compute the expected value independently in the testbench
rather than copying the RTL's internal logic into the check:

```systemverilog
// tb/unit/tb_timer_unit.sv — sketch
int unsigned expected_count;
int unsigned cycles_elapsed;

// ... drive some number of clock cycles after enabling the timer ...

expected_count = cycles_elapsed; // independently derived, not copied from RTL
timer_read_count(bfm_if, actual_count);
check_equal("timer_count_after_N_cycles", expected_count, actual_count);
```

The point: if the check is `actual == (whatever the RTL computes)`, the
test can never fail even when the RTL is wrong. The expected value must
come from an independent line of reasoning about what *should* happen.

---

## 9. Naming & File Conventions Summary

| Item | Convention |
|------|------------|
| Unit test file | `tb/unit/tb_<ip>_unit.sv` |
| Integration test file | `tb/integration/tb_soc_integration.sv` |
| SW test file | `tb/sw/tb_soc_sw.sv` |
| Common task | `<ip>_<action>` (e.g. `uart_send`, `gpio_set_dir`) |
| Checker task | `check_equal(name, expected, actual)` — always this signature |
| Final report | `report_results(test_name)` — always the last line of `initial` |
| Pass/fail banner | Literal `TEST <name>: PASS`/`FAIL` string, grepped by Makefile |
| Wave config | `waves/<level>_<ip>.rc` (matches `PROJECT_STRUCTURE.md` §2) |

Keeping these mechanical and identical across every IP is what lets
`make unit IP=<ip>` and `make verdi LEVEL=<level> IP=<ip>` work uniformly
without special-casing per peripheral.
