// =============================================================================
// tb_soc_integration.sv — LEVEL 2: BFM -> honours_soc (interconnect + all 4
// slaves + RAM). No core.
//
// DUT = interconnect address decode/routing + wrappers, together.
// Checks: correct slave per address (RAM/UART/Timer/GPIO), no cross-talk
// between peripherals, back-to-back transactions to different slaves,
// DECERR (2'b11) on unmapped addresses (read + write).
// =============================================================================

`resetall
`timescale 1ns / 1ps

import soc_pkg::*;
import tb_pkg::*;
`include "tb_tasks.svh"

module tb_soc_integration;

  logic clk = 1'b0;
  logic aresetn;
  always #(tb_pkg::CLK_PERIOD_NS/2) clk = ~clk;

  `ifdef FSDB_DUMP
  initial begin
    $fsdbDumpfile("tb_soc_integration.fsdb");
    $fsdbDumpvars(0, tb_soc_integration);
  end
  `endif

  initial begin
    repeat (2_000_000) @(posedge clk);
    $display("TEST tb_soc_integration: FAIL (global timeout)");
    $finish;
  end

  axi_master_bfm bfm_if (.clk(clk), .aresetn(aresetn));

  // Periodic interconnect-path monitor (SOC_DEBUG only). Prints the core
  // FSM state, grant, both handshake halves, and the RAM write-channel
  // state every 500 cycles so a stall shows exactly where it sticks.
  `ifdef SOC_DEBUG
  initial begin
    repeat (50) @(posedge clk);
    repeat (20) begin
      repeat (500) @(posedge clk);
      $display("[SOC_MON %0t] xbar_state=%0d grant=%b gport=%0d req=%b | s_awv=%b s_awr=%b s_wv=%b s_wr=%b s_bv=%b | m_awv=%b m_awr=%b m_wv=%b m_wr=%b m_bv=%b | ram_wact=%b ram_wbeats=%0d ram_bvalid=%b",
               $time,
               dut.u_xbar.axi_interconnect_inst.state_reg,
               dut.u_xbar.axi_interconnect_inst.grant_valid,
               dut.u_xbar.axi_interconnect_inst.grant_encoded,
               dut.u_xbar.axi_interconnect_inst.request,
               bfm_if.awvalid, bfm_if.awready,
               bfm_if.wvalid, bfm_if.wready, bfm_if.bvalid,
               dut.u_xbar.axi_interconnect_inst.m_axi_awvalid,
               dut.u_xbar.axi_interconnect_inst.m_axi_awready,
               dut.u_xbar.axi_interconnect_inst.m_axi_wvalid,
               dut.u_xbar.axi_interconnect_inst.m_axi_wready,
               dut.u_xbar.axi_interconnect_inst.m_axi_bvalid,
               dut.u_ram.w_active, dut.u_ram.w_beats,
               dut.u_ram.s_axi_bvalid);
      $display("[SOC_MON %0t] READ side: s_arv=%b s_arr=%b s_rv=%b | m_arv=%b m_arr=%b m_rv=%b m_rr=%b | ram_ract=%b ram_rv=%b ram_rlast=%b",
               $time,
               bfm_if.arvalid, bfm_if.arready, bfm_if.rvalid,
               dut.u_xbar.axi_interconnect_inst.m_axi_arvalid,
               dut.u_xbar.axi_interconnect_inst.m_axi_arready,
               dut.u_xbar.axi_interconnect_inst.m_axi_rvalid,
               dut.u_xbar.axi_interconnect_inst.m_axi_rready,
               dut.u_ram.r_active, dut.u_ram.s_axi_rvalid,
               dut.u_ram.s_axi_rlast);
    end
  end
  `endif

  logic [soc_pkg::GPIO_WIDTH-1:0] gpio_in_drv;
  wire  [soc_pkg::GPIO_WIDTH-1:0] gpio_out_mon;
  wire uart_tx_mon, uart_irq_mon, timer_irq_mon;

  honours_soc dut (
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
    .s_axi_rready  (bfm_if.rready),
    .uart_rx_i     (1'b1),
    .uart_tx_o     (uart_tx_mon),
    .uart_irq_o    (uart_irq_mon),
    .timer_irq_o   (timer_irq_mon),
    .gpio_in       (gpio_in_drv),
    .gpio_out      (gpio_out_mon)
  );

  initial begin
    logic [1:0]  resp;
    logic [31:0] rdata;

    bfm_if.reset_master();
    gpio_in_drv = '0;
    soc_reset(aresetn);

    // --- 1. RAM write/read through the interconnect ---
    bfm_if.write(soc_pkg::RAM_BASE + 32'h0, 32'hDEAD_BEEF, 4'hF, resp);
    check_equal("ram_wr_resp", 32'h0, {30'b0, resp});
    bfm_if.write(soc_pkg::RAM_BASE + 32'h4, 32'h1234_5678, 4'hF, resp);
    check_equal("ram_wr1_resp", 32'h0, {30'b0, resp});
    bfm_if.read(soc_pkg::RAM_BASE + 32'h0, rdata, resp);
    check_equal("ram_rd_resp", 32'h0, {30'b0, resp});
    check_equal("ram_rd0", 32'hDEAD_BEEF, rdata);
    bfm_if.read(soc_pkg::RAM_BASE + 32'h4, rdata, resp);
    check_equal("ram_rd1", 32'h1234_5678, rdata);

    // --- 2. Each slave decodes at its base ---
    // UART: LSR readable
    bfm_if.read(soc_pkg::UART_BASE + soc_pkg::UART_LSR, rdata, resp);
    check_equal("uart_lsr_resp", 32'h0, {30'b0, resp});
    // Timer: COMPARE write/read
    timer_write(bfm_if, soc_pkg::TIMER_COMPARE, 32'h55, resp);
    check_equal("timer_wr_resp", 32'h0, {30'b0, resp});
    timer_read(bfm_if, soc_pkg::TIMER_COMPARE, rdata, resp);
    check_equal("timer_cmp", 32'h55, rdata);
    // GPIO: DIR/OUT write/read
    gpio_write(bfm_if, soc_pkg::GPIO_DIR, 32'hFF, resp);
    check_equal("gpio_dir_resp", 32'h0, {30'b0, resp});
    gpio_write(bfm_if, soc_pkg::GPIO_OUT, 32'hA5, resp);
    check_equal("gpio_out_resp", 32'h0, {30'b0, resp});
    gpio_read(bfm_if, soc_pkg::GPIO_OUT, rdata, resp);
    check_equal("gpio_out_val", 32'hA5, rdata);

    // --- 3. No cross-talk: program Timer, re-check GPIO + RAM ---
    timer_write(bfm_if, soc_pkg::TIMER_COMPARE, 32'h1111, resp);
    check_equal("timer_wr2_resp", 32'h0, {30'b0, resp});
    gpio_read(bfm_if, soc_pkg::GPIO_OUT, rdata, resp);
    check_equal("gpio_unaffected", 32'hA5, rdata);
    bfm_if.read(soc_pkg::RAM_BASE + 32'h0, rdata, resp);
    check_equal("ram_unaffected", 32'hDEAD_BEEF, rdata);

    // --- 4. Back-to-back across slaves ---
    bfm_if.write(soc_pkg::RAM_BASE + 32'h8, 32'hAAAA_AAAA, 4'hF, resp);
    check_equal("btb_ram_wr", 32'h0, {30'b0, resp});
    gpio_write(bfm_if, soc_pkg::GPIO_OUT, 32'h5A, resp);
    check_equal("btb_gpio_wr", 32'h0, {30'b0, resp});
    bfm_if.read(soc_pkg::RAM_BASE + 32'h8, rdata, resp);
    check_equal("btb_ram_rd", 32'hAAAA_AAAA, rdata);
    gpio_read(bfm_if, soc_pkg::GPIO_OUT, rdata, resp);
    check_equal("btb_gpio_rd", 32'h5A, rdata);

    // --- 5. Decode errors: unmapped + past-RAM-end ---
    bfm_if.read(32'h2000_0000, rdata, resp);
    check_equal("decerr_rd", 32'h3, {30'b0, resp});
    bfm_if.write(32'h2000_0004, 32'h0, 4'hF, resp);
    check_equal("decerr_wr", 32'h3, {30'b0, resp});
    bfm_if.read(32'h0001_0000, rdata, resp); // just past 64 KiB RAM
    check_equal("ram_oob_decerr", 32'h3, {30'b0, resp});

    // --- 6. Slaves still healthy after errors ---
    gpio_read(bfm_if, soc_pkg::GPIO_OUT, rdata, resp);
    check_equal("healthy_after_decerr", 32'h5A, rdata);

    report_results("tb_soc_integration");
  end

endmodule

`resetall
