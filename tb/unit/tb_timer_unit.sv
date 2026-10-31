// =============================================================================
// tb_timer_unit.sv — LEVEL 1: DUT = timer_wrapper only. BFM drives it directly.
// No interconnect, no core. If this fails, the bug is in timer_wrapper —
// nowhere else, by construction.
//
// Checks: reset values, COUNT reload determinism (disabled), free-run +
// COMPARE match -> irq, CTRL readback, W1C clear, disable clears irq,
// out-of-range SLVERR.
// =============================================================================

`resetall
`timescale 1ns / 1ps

import soc_pkg::*;
import tb_pkg::*;
`include "tb_tasks.svh"

module tb_timer_unit;

  logic clk = 1'b0;
  logic aresetn;
  always #(tb_pkg::CLK_PERIOD_NS/2) clk = ~clk;

  `ifdef FSDB_DUMP
  initial begin
    $fsdbDumpfile("tb_timer_unit.fsdb");
    $fsdbDumpvars(0, tb_timer_unit);
  end
  `endif

  initial begin
    repeat (500_000) @(posedge clk);
    $display("TEST tb_timer_unit: FAIL (global timeout)");
    $fatal(1, "Global simulation timeout");
  end

  axi_master_bfm bfm_if (.clk(clk), .aresetn(aresetn));

  wire irq_mon;

  timer_wrapper #(
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
    .s_axi_rvalid  (bfm_if.rvalid),
    .s_axi_rready  (bfm_if.rready),
    .irq_o         (irq_mon)
  );

  // NOTE: bfm_if.wlast is driven by the BFM write task; bfm_if.rlast is
  // driven by the slave. Neither is tied off here (single-driver rule).

  initial begin
    logic [1:0]  resp;
    logic [31:0] rdata;
    logic [31:0] c1, c2;
    int t;

    bfm_if.reset_master();
    soc_reset(aresetn);

    // --- 1. Reset values: CTRL==0, irq==0 ---
    timer_read(bfm_if, soc_pkg::TIMER_CTRL, rdata, resp);
    check_equal("rst_ctrl_resp", 32'h0, {30'b0, resp});
    check_equal("rst_ctrl_val", 32'h0, rdata);
    check_equal("rst_irq", 32'h0, {31'b0, irq_mon});

    // --- 2. Reload determinism while disabled ---
    timer_write(bfm_if, soc_pkg::TIMER_COUNT, 32'h1234, resp);
    check_equal("reload_resp", 32'h0, {30'b0, resp});
    timer_read(bfm_if, soc_pkg::TIMER_COUNT, rdata, resp);
    check_equal("reload_val", 32'h1234, rdata);

    // --- 3. Free-run + compare match ---
    timer_write(bfm_if, soc_pkg::TIMER_COMPARE, 32'd100, resp);
    check_equal("cmp_resp", 32'h0, {30'b0, resp});
    timer_write(bfm_if, soc_pkg::TIMER_COUNT, 32'd0, resp);
    check_equal("cnt0_resp", 32'h0, {30'b0, resp});
    timer_write(bfm_if, soc_pkg::TIMER_CTRL, 32'h1, resp); // enable
    check_equal("en_resp", 32'h0, {30'b0, resp});

    t = 0;
    while (irq_mon !== 1'b1 && t < 1000) begin
      @(posedge clk);
      t++;
    end
    check_equal("irq_fires", 32'h1, {31'b0, irq_mon});
    timer_read(bfm_if, soc_pkg::TIMER_CTRL, rdata, resp);
    check_equal("match_flag", 32'h3, rdata); // enable + match

    // --- 4. W1C clear (keep enable) ---
    timer_write(bfm_if, soc_pkg::TIMER_CTRL, 32'h3, resp);
    check_equal("w1c_resp", 32'h0, {30'b0, resp});
    timer_read(bfm_if, soc_pkg::TIMER_CTRL, rdata, resp);
    check_equal("match_cleared", 32'h1, rdata);
    check_equal("irq_cleared", 32'h0, {31'b0, irq_mon});

    // --- 5. Counter advances while enabled ---
    timer_read(bfm_if, soc_pkg::TIMER_COUNT, c1, resp);
    repeat (10) @(posedge clk);
    timer_read(bfm_if, soc_pkg::TIMER_COUNT, c2, resp);
    check_equal("count_advances", 32'h1, {31'b0, (c2 > c1)});

    // --- 6. Disable: irq deasserts, count holds ---
    timer_write(bfm_if, soc_pkg::TIMER_CTRL, 32'h0, resp);
    check_equal("dis_resp", 32'h0, {30'b0, resp});
    timer_read(bfm_if, soc_pkg::TIMER_COUNT, c1, resp);
    repeat (5) @(posedge clk);
    timer_read(bfm_if, soc_pkg::TIMER_COUNT, c2, resp);
    check_equal("count_holds", c1, c2);

    // --- 7. Negative case: bad offset -> SLVERR ---
    timer_read(bfm_if, 32'h0C, rdata, resp);
    check_equal("bad_off_slverr", 32'h2, {30'b0, resp});

    report_results("tb_timer_unit");
  end

endmodule

`resetall
