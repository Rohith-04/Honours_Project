// =============================================================================
// tb_gpio_unit.sv — LEVEL 1: DUT = gpio_wrapper only. BFM drives it directly.
// No interconnect, no core. If this fails, the bug is in gpio_wrapper —
// nowhere else, by construction.
//
// Checks: DIR/OUT programming + pin reflection, IN readback of driven pins,
// RO-write and out-of-range SLVERR behavior, response codes.
// =============================================================================

`resetall
`timescale 1ns / 1ps

import soc_pkg::*;
import tb_pkg::*;
`include "tb_tasks.svh"

module tb_gpio_unit;

  logic clk = 1'b0;
  logic aresetn;
  always #(tb_pkg::CLK_PERIOD_NS/2) clk = ~clk;

  `ifdef FSDB_DUMP
  initial begin
    $fsdbDumpfile("tb_gpio_unit.fsdb");
    $fsdbDumpvars(0, tb_gpio_unit);
  end
  `endif

  // Global watchdog: fail loud, never hang.
  initial begin
    repeat (500_000) @(posedge clk);
    $display("TEST tb_gpio_unit: FAIL (global timeout)");
    $fatal(1, "Global simulation timeout");
  end

  axi_master_bfm bfm_if (.clk(clk), .aresetn(aresetn));

  logic [soc_pkg::GPIO_WIDTH-1:0] gpio_in_drv;
  wire  [soc_pkg::GPIO_WIDTH-1:0] gpio_out_mon;

  gpio_wrapper #(
    .ID_WIDTH   (soc_pkg::AXI_ID_WIDTH),
    .ADDR_WIDTH (soc_pkg::AXI_ADDR_WIDTH),
    .WIDTH      (soc_pkg::GPIO_WIDTH)
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
    .gpio_in       (gpio_in_drv),
    .gpio_out      (gpio_out_mon)
  );

  // NOTE: bfm_if.wlast is driven by the BFM write task; bfm_if.rlast is
  // driven by the slave. Neither is tied off here (single-driver rule).

  initial begin
    logic [1:0]  resp;
    logic [31:0] rdata;

    bfm_if.reset_master();
    gpio_in_drv = '0;
    soc_reset(aresetn);

    // --- 1. All-output, pattern on pins ---
    gpio_write(bfm_if, soc_pkg::GPIO_DIR, 32'hFF, resp);
    check_equal("dir_ff_resp", 32'h0, {30'b0, resp});
    gpio_write(bfm_if, soc_pkg::GPIO_OUT, 32'hA5, resp);
    check_equal("out_a5_resp", 32'h0, {30'b0, resp});
    repeat (2) @(posedge clk);
    check_equal("pins_a5", 32'hA5, {24'b0, gpio_out_mon});

    // --- 2. Clear outputs ---
    gpio_write(bfm_if, soc_pkg::GPIO_OUT, 32'h00, resp);
    check_equal("out_00_resp", 32'h0, {30'b0, resp});
    repeat (2) @(posedge clk);
    check_equal("pins_00", 32'h00, {24'b0, gpio_out_mon});

    // --- 3. Partial direction masks output ---
    gpio_write(bfm_if, soc_pkg::GPIO_DIR, 32'h0F, resp);
    check_equal("dir_0f_resp", 32'h0, {30'b0, resp});
    gpio_write(bfm_if, soc_pkg::GPIO_OUT, 32'hFF, resp);
    check_equal("out_ff_resp", 32'h0, {30'b0, resp});
    repeat (2) @(posedge clk);
    check_equal("pins_masked", 32'h0F, {24'b0, gpio_out_mon});

    // --- 4. Read back programmed registers ---
    gpio_read(bfm_if, soc_pkg::GPIO_DIR, rdata, resp);
    check_equal("dir_rd_resp", 32'h0, {30'b0, resp});
    check_equal("dir_rd_val", 32'h0F, rdata);
    gpio_read(bfm_if, soc_pkg::GPIO_OUT, rdata, resp);
    check_equal("out_rd_resp", 32'h0, {30'b0, resp});
    check_equal("out_rd_val", 32'hFF, rdata);

    // --- 5. Input path: drive pins, read IN ---
    gpio_write(bfm_if, soc_pkg::GPIO_DIR, 32'h00, resp);
    check_equal("dir_00_resp", 32'h0, {30'b0, resp});
    gpio_in_drv = 8'h3C;
    repeat (3) @(posedge clk); // sync flop + margin
    gpio_read(bfm_if, soc_pkg::GPIO_IN, rdata, resp);
    check_equal("in_rd_resp", 32'h0, {30'b0, resp});
    check_equal("in_rd_val", 32'h3C, rdata);

    // --- 6. Negative cases: RO write + bad offset -> SLVERR ---
    gpio_write(bfm_if, soc_pkg::GPIO_IN, 32'hFF, resp);
    check_equal("in_wr_slverr", 32'h2, {30'b0, resp});
    gpio_read(bfm_if, 32'h0C, rdata, resp);
    check_equal("bad_off_slverr", 32'h2, {30'b0, resp});

    report_results("tb_gpio_unit");
  end

endmodule

`resetall
