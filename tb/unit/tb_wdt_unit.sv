// =============================================================================
// tb_wdt_unit.sv — LEVEL 1: DUT = wdt_wrapper only.
//
// Tests:
//   - Reset values (CTRL=0, STATUS=0, TRIP_COUNT=0, TIMEOUT=default)
//   - No trip on a long busy period with steady progress
//   - Trip after TIMEOUT cycles with no progress
//   - TRIP_COUNT increments
//   - Re-arm on next busy rise
//   - Disabled when EN=0
//   - Disabled when TIMEOUT=0
//   - W1C clear of TRIPPED
//   - IRQ behavior
// =============================================================================

`resetall
`timescale 1ns / 1ps

import soc_pkg::*;
import tb_pkg::*;
`include "tb_tasks.svh"

module tb_wdt_unit;

  logic clk = 1'b0;
  logic aresetn;
  always #(tb_pkg::CLK_PERIOD_NS/2) clk = ~clk;

  `ifdef FSDB_DUMP
  initial begin
    $fsdbDumpfile("tb_wdt_unit.fsdb");
    $fsdbDumpvars(0, tb_wdt_unit);
  end
  `endif

  initial begin
    repeat (500_000) @(posedge clk);
    $display("TEST tb_wdt_unit: FAIL (global timeout)");
    $fatal(1, "Global simulation timeout");
  end

  axi_master_bfm bfm_if (.clk(clk), .aresetn(aresetn));

  // Sideband stimulus
  logic nda_busy_stim  = 0;
  logic nda_progress_stim = 0;

  wire wdt_abort_w;
  wire wdt_trip_w;
  wire wdt_irq_w;

  wdt_wrapper #(
    .ID_WIDTH   (soc_pkg::AXI_ID_WIDTH),
    .ADDR_WIDTH (soc_pkg::AXI_ADDR_WIDTH)
  ) dut (
    .clk           (clk),
    .aresetn       (aresetn),
    .s_axi_awid    (bfm_if.awid),
    .s_axi_awaddr  (bfm_if.awaddr),
    .s_axi_awlen   (bfm_if.awlen),
    .s_axi_awsize  (bfm_if.awsize),
    .s_axi_awburst (bfm_if.awburst),
    .s_axi_awvalid (bfm_if.awvalid),
    .s_axi_awready (bfm_if.awready),
    .s_axi_wdata   (bfm_if.wdata),
    .s_axi_wstrb   (bfm_if.wstrb),
    .s_axi_wvalid  (bfm_if.wvalid),
    .s_axi_wready  (bfm_if.wready),
    .s_axi_bid     (bfm_if.bid),
    .s_axi_bresp   (bfm_if.bresp),
    .s_axi_bvalid  (bfm_if.bvalid),
    .s_axi_bready  (bfm_if.bready),
    .s_axi_arid    (bfm_if.arid),
    .s_axi_araddr  (bfm_if.araddr),
    .s_axi_arlen   (bfm_if.arlen),
    .s_axi_arsize  (bfm_if.arsize),
    .s_axi_arburst (bfm_if.arburst),
    .s_axi_arvalid (bfm_if.arvalid),
    .s_axi_arready (bfm_if.arready),
    .s_axi_rid     (bfm_if.rid),
    .s_axi_rdata   (bfm_if.rdata),
    .s_axi_rresp   (bfm_if.rresp),
    .s_axi_rlast   (bfm_if.rlast),
    .s_axi_rvalid  (bfm_if.rvalid),
    .s_axi_rready  (bfm_if.rready),

    .nda_busy_i    (nda_busy_stim),
    .nda_progress_i(nda_progress_stim),
    .abort_o       (wdt_abort_w),
    .trip_o        (wdt_trip_w),
    .irq_o         (wdt_irq_w)
  );

  logic [1:0] resp;
  logic [31:0] rdata;

  initial begin
    bfm_if.reset_master();
    soc_reset(aresetn);

    // === 1. Reset values ===
    wdt_read(bfm_if, soc_pkg::WDT_CTRL, rdata, resp);
    check_equal("rst_ctrl", 32'h0, rdata);
    wdt_read(bfm_if, soc_pkg::WDT_TIMEOUT, rdata, resp);
    check_equal("rst_timeout", soc_pkg::WDT_TIMEOUT_DEFAULT, rdata);
    wdt_read(bfm_if, soc_pkg::WDT_STATUS, rdata, resp);
    check_equal("rst_status", 32'h0, rdata);
    wdt_read(bfm_if, soc_pkg::WDT_TRIP_COUNT, rdata, resp);
    check_equal("rst_trip_count", 32'h0, rdata);
    check_equal("rst_irq", 32'h0, {31'b0, wdt_irq_w});

    // === 2. No false trip with steady progress ===
    // Enable WDT with a small timeout, drive busy + progress every cycle
    wdt_write(bfm_if, soc_pkg::WDT_TIMEOUT, 32'd10, resp);
    wdt_write(bfm_if, soc_pkg::WDT_CTRL, 32'h1, resp); // EN=1

    nda_busy_stim = 1;
    nda_progress_stim = 1; // progress every cycle
    repeat (50) @(posedge clk);
    nda_busy_stim = 0;
    nda_progress_stim = 0;
    @(posedge clk);

    wdt_read(bfm_if, soc_pkg::WDT_STATUS, rdata, resp);
    check_equal("no_false_trip", 32'h0, {31'b0, rdata[soc_pkg::WDT_STATUS_TRIPPED]});
    wdt_read(bfm_if, soc_pkg::WDT_TRIP_COUNT, rdata, resp);
    check_equal("no_false_trip_count", 32'h0, rdata);

    // === 3. Trip after TIMEOUT cycles with no progress ===
    // Enable, drive busy but NO progress, wait TIMEOUT+1 cycles
    wdt_write(bfm_if, soc_pkg::WDT_TIMEOUT, 32'd20, resp);
    wdt_write(bfm_if, soc_pkg::WDT_CTRL, 32'h1, resp); // ensure EN=1

    nda_busy_stim = 1;
    nda_progress_stim = 0; // no progress!
    repeat (25) @(posedge clk); // > 20 cycles → should trip

    wdt_read(bfm_if, soc_pkg::WDT_STATUS, rdata, resp);
    check_equal("trip_set", 32'h1, {31'b0, rdata[soc_pkg::WDT_STATUS_TRIPPED]});
    wdt_read(bfm_if, soc_pkg::WDT_TRIP_COUNT, rdata, resp);
    check_equal("trip_count_1", 32'h1, rdata);
    // Abort pulse should have fired (it's a one-cycle pulse, so it's
    // likely already gone — check trip_o was observable via a monitor)
    // The trip_o is the same signal, but it's a pulse. We check the
    // sticky TRIPPED flag instead.

    nda_busy_stim = 0; // end busy
    @(posedge clk);

    // === 4. W1C clear of TRIPPED ===
    wdt_write(bfm_if, soc_pkg::WDT_STATUS, 32'h1, resp); // W1C bit 0
    wdt_read(bfm_if, soc_pkg::WDT_STATUS, rdata, resp);
    check_equal("tripped_cleared", 32'h0, {31'b0, rdata[soc_pkg::WDT_STATUS_TRIPPED]});

    // === 5. Re-arm on next busy rise ===
    nda_busy_stim = 1;
    nda_progress_stim = 0;
    repeat (25) @(posedge clk); // should trip again

    wdt_read(bfm_if, soc_pkg::WDT_STATUS, rdata, resp);
    check_equal("rearm_trip", 32'h1, {31'b0, rdata[soc_pkg::WDT_STATUS_TRIPPED]});
    wdt_read(bfm_if, soc_pkg::WDT_TRIP_COUNT, rdata, resp);
    check_equal("rearm_count", 32'h2, rdata);

    nda_busy_stim = 0;
    @(posedge clk);
    wdt_write(bfm_if, soc_pkg::WDT_STATUS, 32'h1, resp);

    // === 6. Disabled when EN=0 ===
    wdt_write(bfm_if, soc_pkg::WDT_CTRL, 32'h0, resp); // EN=0
    nda_busy_stim = 1;
    nda_progress_stim = 0;
    repeat (50) @(posedge clk); // should NOT trip
    wdt_read(bfm_if, soc_pkg::WDT_STATUS, rdata, resp);
    check_equal("disabled_no_trip", 32'h0, {31'b0, rdata[soc_pkg::WDT_STATUS_TRIPPED]});
    wdt_read(bfm_if, soc_pkg::WDT_TRIP_COUNT, rdata, resp);
    check_equal("disabled_count", 32'h2, rdata); // still 2
    nda_busy_stim = 0;
    @(posedge clk);

    // === 7. Disabled when TIMEOUT=0 ===
    wdt_write(bfm_if, soc_pkg::WDT_CTRL, 32'h1, resp); // EN=1
    wdt_write(bfm_if, soc_pkg::WDT_TIMEOUT, 32'h0, resp);
    nda_busy_stim = 1;
    nda_progress_stim = 0;
    repeat (50) @(posedge clk); // should NOT trip
    wdt_read(bfm_if, soc_pkg::WDT_STATUS, rdata, resp);
    check_equal("timeout0_no_trip", 32'h0, {31'b0, rdata[soc_pkg::WDT_STATUS_TRIPPED]});
    nda_busy_stim = 0;
    @(posedge clk);

    // === 8. IRQ behavior ===
    wdt_write(bfm_if, soc_pkg::WDT_TIMEOUT, 32'd10, resp);
    wdt_write(bfm_if, soc_pkg::WDT_CTRL, 32'h5, resp); // EN=1 + IRQ_EN=1
    nda_busy_stim = 1;
    nda_progress_stim = 0;
    repeat (15) @(posedge clk); // should trip

    wdt_read(bfm_if, soc_pkg::WDT_STATUS, rdata, resp);
    check_equal("irq_trip_set", 32'h1, {31'b0, rdata[soc_pkg::WDT_STATUS_TRIPPED]});
    check_equal("irq_asserted", 32'h1, {31'b0, wdt_irq_w});
    nda_busy_stim = 0;
    @(posedge clk);
    // IRQ should stay high while TRIPPED is set
    check_equal("irq_still_high", 32'h1, {31'b0, wdt_irq_w});
    // Clear TRIPPED → IRQ drops
    wdt_write(bfm_if, soc_pkg::WDT_STATUS, 32'h1, resp);
    #1;
    check_equal("irq_drops", 32'h0, {31'b0, wdt_irq_w});

    wdt_read(bfm_if, WDT_CTRL, rdata, resp);
    check_equal("ctrl_irq_enable_readback", 5, rdata);
    // Exact timeout: arm at busy rise, then trip on the fifth idle cycle.
    wdt_write(bfm_if, WDT_TIMEOUT, 5, resp);
    @(negedge clk); nda_busy_stim = 1;
    @(posedge clk); #1;
    repeat (4) begin
      @(posedge clk); #1;
      check_equal("no_early_trip", 0, wdt_trip_w);
    end
    @(posedge clk); #1;
    check_equal("exact_timeout_pulse", 1, wdt_trip_w);
    check_equal("abort_matches_trip", 1, wdt_abort_w);
    @(posedge clk); #1;
    check_equal("one_cycle_trip", 0, wdt_trip_w);
    @(negedge clk); nda_busy_stim = 0;
    wdt_write(bfm_if, WDT_STATUS, 1, resp);
    wdt_write(bfm_if, WDT_TIMEOUT, 100, resp);
    @(negedge clk); nda_busy_stim = 1;
    repeat (3) @(negedge clk);
    wdt_write(bfm_if, WDT_CTRL, 0, resp);
    repeat (110) @(negedge clk);
    wdt_read(bfm_if, WDT_STATUS, rdata, resp);
    check_equal("disable_while_armed", 0, rdata);
    nda_busy_stim = 0;
    @(negedge clk);
    wdt_write(bfm_if, WDT_CTRL, 1, resp);
    @(negedge clk); nda_busy_stim = 1;
    repeat (3) @(negedge clk);
    wdt_write(bfm_if, WDT_TIMEOUT, 0, resp);
    repeat (110) @(negedge clk);
    wdt_read(bfm_if, WDT_STATUS, rdata, resp);
    check_equal("timeout_zero_while_armed", 0, rdata);
    report_results("tb_wdt_unit");
  end

endmodule

`resetall
