// =============================================================================
// tb_ram_unit.sv — LEVEL 1 (diagnostic): DUT = axi_ram only, BFM direct.
// Splits RAM logic from the interconnect path while debugging the
// Level-2 hang (GPIO unit passes, so BFM + wrapper style are proven).
//
// Checks: word write/read across the range, byte-strobe partial writes,
// 4-beat INCR burst write/read, back-to-back bursts.
// =============================================================================

`resetall
`timescale 1ns / 1ps

import soc_pkg::*;
import tb_pkg::*;
`include "tb_tasks.svh"

module tb_ram_unit;

  logic clk = 1'b0;
  logic aresetn;
  always #(tb_pkg::CLK_PERIOD_NS/2) clk = ~clk;

  `ifdef FSDB_DUMP
  initial begin
    $fsdbDumpfile("tb_ram_unit.fsdb");
    $fsdbDumpvars(0, tb_ram_unit);
  end
  `endif

  initial begin
    repeat (500_000) @(posedge clk);
    $display("TEST tb_ram_unit: FAIL (global timeout)");
    $fatal(1, "Global simulation timeout");
  end

  axi_master_bfm bfm_if (.clk(clk), .aresetn(aresetn));

  axi_ram #(
    .ADDR_WIDTH (soc_pkg::AXI_ADDR_WIDTH),
    .ID_WIDTH   (soc_pkg::AXI_ID_WIDTH),
    .MEM_BYTES  (soc_pkg::RAM_BYTES)
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
    .s_axi_wlast   (bfm_if.wlast),
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
    .s_axi_rready  (bfm_if.rready)
  );

  initial begin
    logic [1:0]  resp;
    logic [31:0] rdata;
    logic [31:0] wburst [];
    logic [31:0] rburst [];

    bfm_if.reset_master();
    soc_reset(aresetn);

    // --- 1. Word write/read across the range ---
    bfm_if.write(32'h0000_0000, 32'hDEAD_BEEF, 4'hF, resp);
    check_equal("w0_resp", 32'h0, {30'b0, resp});
    bfm_if.write(32'h0000_0004, 32'h1234_5678, 4'hF, resp);
    check_equal("w1_resp", 32'h0, {30'b0, resp});
    bfm_if.write(32'h0000_FFFC, 32'hA5A5_A5A5, 4'hF, resp);
    check_equal("wlast_resp", 32'h0, {30'b0, resp});
    bfm_if.read(32'h0000_0000, rdata, resp);
    check_equal("r0", 32'hDEAD_BEEF, rdata);
    bfm_if.read(32'h0000_0004, rdata, resp);
    check_equal("r1", 32'h1234_5678, rdata);
    bfm_if.read(32'h0000_FFFC, rdata, resp);
    check_equal("rlast", 32'hA5A5_A5A5, rdata);

    // --- 2. Byte-strobe partial write ---
    bfm_if.write(32'h0000_0010, 32'h1234_5678, 4'hF, resp);
    check_equal("full_resp", 32'h0, {30'b0, resp});
    bfm_if.write(32'h0000_0010, 32'hA500_0000, 4'h8, resp);
    check_equal("strb_resp", 32'h0, {30'b0, resp});
    bfm_if.read(32'h0000_0010, rdata, resp);
    check_equal("strb_val", 32'hA534_5678, rdata);

    // --- 3. 4-beat INCR burst write/read ---
    wburst = new[4];
    wburst[0] = 32'h1111_1111;
    wburst[1] = 32'h2222_2222;
    wburst[2] = 32'h3333_3333;
    wburst[3] = 32'h4444_4444;
    bfm_if.write_burst(32'h0000_0100, wburst, resp);
    check_equal("burst_wr_resp", 32'h0, {30'b0, resp});
    rburst = new[4];
    bfm_if.read_burst(32'h0000_0100, rburst, resp);
    check_equal("burst_rd_resp", 32'h0, {30'b0, resp});
    check_equal("burst_b0", 32'h1111_1111, rburst[0]);
    check_equal("burst_b1", 32'h2222_2222, rburst[1]);
    check_equal("burst_b2", 32'h3333_3333, rburst[2]);
    check_equal("burst_b3", 32'h4444_4444, rburst[3]);

    // --- 4. Back-to-back bursts ---
    wburst[0] = 32'hDEAD_0001;
    wburst[1] = 32'hDEAD_0002;
    wburst[2] = 32'hDEAD_0003;
    wburst[3] = 32'hDEAD_0004;
    bfm_if.write_burst(32'h0000_0200, wburst, resp);
    check_equal("btb_wr_resp", 32'h0, {30'b0, resp});
    rburst = new[4];
    bfm_if.read_burst(32'h0000_0200, rburst, resp);
    check_equal("btb_b3", 32'hDEAD_0004, rburst[3]);

    report_results("tb_ram_unit");
  end

endmodule

`resetall
