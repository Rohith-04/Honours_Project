// =============================================================================
// tb_tasks.svh — Shared test tasks. Include once per TB (`include
// "tb_tasks.svh") after `import soc_pkg::*; import tb_pkg::*;`.
//
// Rule: these helpers (and bfm.write/bfm.read underneath) are the ONLY
// sanctioned way to interact with a peripheral from a test.
// =============================================================================
`ifndef TB_TASKS_SVH
`define TB_TASKS_SVH

// --- Reset -------------------------------------------------------------------
// Active-low, held RST_CYCLES bit-times, then released. Delay-based (no
// clock-edge waits): an event control on a task INPUT argument freezes the
// sampled value at call time, so `@(posedge clk)` inside the task would
// never fire and the caller would hang silently. `ref` drives the real pin
// for the whole duration (an `output` arg would only copy out on return,
// skipping the low phase entirely).
task automatic soc_reset(ref logic aresetn);
  aresetn = 1'b0;
  #(tb_pkg::CLK_PERIOD_NS * tb_pkg::RST_CYCLES);
  aresetn = 1'b1;
  #(tb_pkg::CLK_PERIOD_NS * 2);
endtask

// --- Self-checking -------------------------------------------------------------
int unsigned pass_count = 0;
int unsigned fail_count = 0;

task automatic check_equal(
  input string         name,
  input logic [31:0]   expected,
  input logic [31:0]   actual
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

// --- IP helpers: one AXI-level action each --------------------------------------
// NOTE on the UART map: offsets below are the IP's native registers,
// exposed directly by uart_wrapper (see soc_pkg UART_*). IER must be set
// for LSR DATA_READY to assert (IP gates it on the irq-enable bit).

task automatic uart_send(
  virtual axi_master_bfm bfm,
  input byte c,
  output logic [1:0] resp
);
  bfm.write(soc_pkg::UART_BASE + soc_pkg::UART_THR, {24'b0, c}, 4'hF, resp);
endtask

task automatic uart_read_lsr(
  virtual axi_master_bfm bfm,
  output logic [31:0] lsr,
  output logic [1:0]  resp
);
  bfm.read(soc_pkg::UART_BASE + soc_pkg::UART_LSR, lsr, resp);
endtask

task automatic timer_write(
  virtual axi_master_bfm bfm,
  input logic [31:0] offset,
  input logic [31:0] data,
  output logic [1:0] resp
);
  bfm.write(soc_pkg::TIMER_BASE + offset, data, 4'hF, resp);
endtask

task automatic timer_read(
  virtual axi_master_bfm bfm,
  input logic [31:0]  offset,
  output logic [31:0] data,
  output logic [1:0]  resp
);
  bfm.read(soc_pkg::TIMER_BASE + offset, data, resp);
endtask

task automatic gpio_write(
  virtual axi_master_bfm bfm,
  input logic [31:0] offset,
  input logic [31:0] data,
  output logic [1:0] resp
);
  bfm.write(soc_pkg::GPIO_BASE + offset, data, 4'hF, resp);
endtask

task automatic gpio_read(
  virtual axi_master_bfm bfm,
  input logic [31:0]  offset,
  output logic [31:0] data,
  output logic [1:0]  resp
);
  bfm.read(soc_pkg::GPIO_BASE + offset, data, resp);
endtask

// --- NDA helpers ---------------------------------------------------------------
task automatic nda_write(
  virtual axi_master_bfm bfm,
  input logic [31:0] offset,
  input logic [31:0] data,
  output logic [1:0] resp
);
  bfm.write(soc_pkg::NDA_BASE + offset, data, 4'hF, resp);
endtask

task automatic nda_read(
  virtual axi_master_bfm bfm,
  input logic [31:0]  offset,
  output logic [31:0] data,
  output logic [1:0]  resp
);
  bfm.read(soc_pkg::NDA_BASE + offset, data, resp);
endtask

// --- WDT helpers ---------------------------------------------------------------
task automatic wdt_write(
  virtual axi_master_bfm bfm,
  input logic [31:0] offset,
  input logic [31:0] data,
  output logic [1:0] resp
);
  bfm.write(soc_pkg::WDT_BASE + offset, data, 4'hF, resp);
endtask

task automatic wdt_read(
  virtual axi_master_bfm bfm,
  input logic [31:0]  offset,
  output logic [31:0] data,
  output logic [1:0]  resp
);
  bfm.read(soc_pkg::WDT_BASE + offset, data, resp);
endtask

// --- HPM helpers ---------------------------------------------------------------
task automatic hpm_write(
  virtual axi_master_bfm bfm,
  input logic [31:0] offset,
  input logic [31:0] data,
  output logic [1:0] resp
);
  bfm.write(soc_pkg::HPM_BASE + offset, data, 4'hF, resp);
endtask

task automatic hpm_read(
  virtual axi_master_bfm bfm,
  input logic [31:0]  offset,
  output logic [31:0] data,
  output logic [1:0]  resp
);
  bfm.read(soc_pkg::HPM_BASE + offset, data, resp);
endtask

`endif
