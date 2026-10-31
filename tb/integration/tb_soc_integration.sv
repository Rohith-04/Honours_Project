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
    $fatal(1, "Global simulation timeout");
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
               dut.gen_xbar_2x7.u_xbar.axi_interconnect_inst.state_reg,
               dut.gen_xbar_2x7.u_xbar.axi_interconnect_inst.grant_valid,
               dut.gen_xbar_2x7.u_xbar.axi_interconnect_inst.grant_encoded,
               dut.gen_xbar_2x7.u_xbar.axi_interconnect_inst.request,
               bfm_if.awvalid, bfm_if.awready,
               bfm_if.wvalid, bfm_if.wready, bfm_if.bvalid,
               dut.gen_xbar_2x7.u_xbar.axi_interconnect_inst.m_axi_awvalid,
               dut.gen_xbar_2x7.u_xbar.axi_interconnect_inst.m_axi_awready,
               dut.gen_xbar_2x7.u_xbar.axi_interconnect_inst.m_axi_wvalid,
               dut.gen_xbar_2x7.u_xbar.axi_interconnect_inst.m_axi_wready,
               dut.gen_xbar_2x7.u_xbar.axi_interconnect_inst.m_axi_bvalid,
               dut.u_ram.w_active, dut.u_ram.w_beats,
               dut.u_ram.s_axi_bvalid);
      $display("[SOC_MON %0t] READ side: s_arv=%b s_arr=%b s_rv=%b | m_arv=%b m_arr=%b m_rv=%b m_rr=%b | ram_ract=%b ram_rv=%b ram_rlast=%b",
               $time,
               bfm_if.arvalid, bfm_if.arready, bfm_if.rvalid,
               dut.gen_xbar_2x7.u_xbar.axi_interconnect_inst.m_axi_arvalid,
               dut.gen_xbar_2x7.u_xbar.axi_interconnect_inst.m_axi_arready,
               dut.gen_xbar_2x7.u_xbar.axi_interconnect_inst.m_axi_rvalid,
               dut.gen_xbar_2x7.u_xbar.axi_interconnect_inst.m_axi_rready,
               dut.u_ram.r_active, dut.u_ram.s_axi_rvalid,
               dut.u_ram.s_axi_rlast);
    end
  end
  `endif

  logic [soc_pkg::GPIO_WIDTH-1:0] gpio_in_drv;
  wire  [soc_pkg::GPIO_WIDTH-1:0] gpio_out_mon;
  wire uart_tx_mon, uart_irq_mon, timer_irq_mon;
  wire nda_irq_mon, wdt_irq_mon;
  logic inject_stall = 0;
  int nda_addresses = 0, nda_beats = 0;
  int first_r_wait = -1, max_first_r_latency = 0;
  always @(posedge clk) if (aresetn) begin
    if (dut.nda_arvalid && dut.nda_arready) begin
      nda_addresses++;
      first_r_wait = 0;
      assert ({1'b0, dut.nda_araddr[11:0]} + (({5'b0, dut.nda_arlen} + 1) << 2) <= 4096)
        else $fatal(1, "NDA burst crosses 4KiB");
    end
    else if (first_r_wait >= 0) first_r_wait++;
    if (dut.nda_rvalid && dut.nda_rready) begin
      nda_beats++;
      if (first_r_wait >= 0) begin
        if (!inject_stall && first_r_wait > max_first_r_latency)
          max_first_r_latency = first_r_wait;
        first_r_wait = -1;
      end
    end
  end
  generate
    if (soc_pkg::ENABLE_HPM) begin : gen_fault_7
      initial begin
        wait (inject_stall);
        wait (dut.nda_arvalid && dut.nda_arready);
        @(negedge clk);
        force dut.gen_xbar_2x7.u_xbar.axi_interconnect_inst.m_axi_rready_reg = '0;
        repeat (512) @(negedge clk);
        release dut.gen_xbar_2x7.u_xbar.axi_interconnect_inst.m_axi_rready_reg;
      end
    end else begin : gen_fault_6
      initial begin
        wait (inject_stall);
        wait (dut.nda_arvalid && dut.nda_arready);
        @(negedge clk);
        force dut.gen_xbar_2x6.u_xbar.axi_interconnect_inst.m_axi_rready_reg = '0;
        repeat (512) @(negedge clk);
        release dut.gen_xbar_2x6.u_xbar.axi_interconnect_inst.m_axi_rready_reg;
      end
    end
  endgenerate

  task automatic wait_done(output logic [31:0] status);
    logic [1:0] response;
    for (int t = 0; t < 10000; t++) begin
      nda_read(bfm_if, NDA_STATUS, status, response);
      if (status[1]) return;
    end
    $fatal(1, "Integrated NDA completion timeout");
  endtask

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
    .nda_irq_o     (nda_irq_mon),
    .wdt_irq_o     (wdt_irq_mon),
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

    bfm_if.write_delayed(32'h204, 32'h1234abcd, 12'habc, resp);
    check_equal("delayed_write_resp", 0, resp);
    bfm_if.read_stalled(32'h204, 12'h789, rdata, resp);
    check_equal("stalled_read_resp", 0, resp);
    check_equal("stalled_read_data", 32'h1234abcd, rdata);
    // Phase 2: real memory, independent NDA master, concurrent M0 traffic.
    for (int i = 0; i < 129; i++)
      bfm_if.write(32'hff8 + i*4, i-64, 4'hf, resp);
    if (ENABLE_HPM) hpm_write(bfm_if, HPM_CTRL, 3, resp);
    for (int op = 0; op < 4; op++) begin
      nda_write(bfm_if, NDA_OP, op, resp);
      nda_write(bfm_if, NDA_SRC_BASE, 32'hff8, resp);
      nda_write(bfm_if, NDA_LEN, 129, resp);
      nda_write(bfm_if, NDA_CTRL, 5, resp);
      repeat (8) begin
        gpio_read(bfm_if, GPIO_OUT, rdata, resp);
        check_equal("gpio_during_nda", 32'h5a, rdata);
        bfm_if.write(32'h200, 32'hcafef00d, 4'hf, resp);
        bfm_if.read(32'h200, rdata, resp);
        check_equal("ram_during_nda", 32'hcafef00d, rdata);
      end
      wait_done(rdata);
      check_equal("nda_integrated_status", 2, rdata);
      check_equal("nda_integrated_irq", 1, nda_irq_mon);
      nda_read(bfm_if, NDA_RESULT_LO, rdata, resp);
      case (op)
        0: check_equal("sum_129", 0, rdata);
        1: check_equal("min_129", -64, rdata);
        default: check_equal("max_129", 64, rdata);
      endcase
      nda_read(bfm_if, NDA_RESULT_HI, rdata, resp);
      check_equal("result_hi", op == 3 ? 128 : 0, rdata);
      nda_write(bfm_if, NDA_STATUS, 6, resp);
      check_equal("nda_irq_cleared", 0, nda_irq_mon);
    end
    check_equal("nda_burst_count", 36, nda_addresses);
    check_equal("nda_element_count", 516, nda_beats);
    check_equal("wdt_default_latency_margin", 1,
      max_first_r_latency > 0 && WDT_TIMEOUT_DEFAULT >= 8 * max_first_r_latency);
    if (ENABLE_HPM) begin
      hpm_write(bfm_if, HPM_CTRL, 4, resp);
      hpm_read(bfm_if, HPM_NDA_AR_LO, rdata, resp);
      check_equal("hpm_real_nda_ar", 36, rdata);
      hpm_read(bfm_if, HPM_NDA_RBEATS_LO, rdata, resp);
      check_equal("hpm_real_nda_beats", 516, rdata);
    end else begin
      bfm_if.read(HPM_BASE, rdata, resp);
      check_equal("hpm_absent_decerr", 3, resp);
    end
    // Full AXI malformed CSR bursts must drain and leave the fabric usable.
    begin
      logic [31:0] words[];
      words = new[3];
      foreach (words[i]) words[i] = 1;
      bfm_if.write_burst(NDA_BASE + NDA_CTRL, words, resp);
      check_equal("nda_burst_write_rejected", 2, resp);
      bfm_if.read_burst(WDT_BASE, words, resp);
      check_equal("wdt_burst_read_rejected", 2, resp);
      bfm_if.read_burst(NDA_BASE, words, resp);
      check_equal("nda_burst_read_rejected", 2, resp);
      bfm_if.write_burst(WDT_BASE, words, resp);
      check_equal("wdt_burst_write_rejected", 2, resp);
      if (ENABLE_HPM) begin
        bfm_if.write_burst(HPM_BASE, words, resp);
        check_equal("hpm_burst_write_rejected", 2, resp);
        bfm_if.read_burst(HPM_BASE, words, resp);
        check_equal("hpm_burst_read_rejected", 2, resp);
      end
      nda_read(bfm_if, NDA_STATUS, rdata, resp);
      check_equal("rejected_start_no_side_effect", 0, rdata);
    end
    // Temporary stall: one trip, ABORTED, drained bus, clean next job.
    wdt_write(bfm_if, WDT_TIMEOUT, 128, resp);
    wdt_write(bfm_if, WDT_CTRL, 5, resp);
    nda_write(bfm_if, NDA_OP, NDA_OP_SUM, resp);
    inject_stall = 1;
    nda_write(bfm_if, NDA_CTRL, 1, resp);
    wait_done(rdata);
    check_equal("wdt_aborted_nda", 32'h76, rdata);
    wdt_read(bfm_if, WDT_TRIP_COUNT, rdata, resp);
    check_equal("wdt_trip_once", 1, rdata);
    check_equal("wdt_irq", 1, wdt_irq_mon);
    if (ENABLE_HPM) begin
      hpm_write(bfm_if, HPM_CTRL, 5, resp);
      hpm_read(bfm_if, HPM_FALLBACKS_LO, rdata, resp);
      check_equal("hpm_real_fallback", 1, rdata);
    end
    wdt_write(bfm_if, WDT_STATUS, 1, resp);
    check_equal("wdt_irq_cleared", 0, wdt_irq_mon);
    wdt_write(bfm_if, WDT_TIMEOUT, WDT_TIMEOUT_DEFAULT, resp);
    nda_write(bfm_if, NDA_CTRL, 1, resp);
    wait_done(rdata);
    check_equal("post_abort_status", 2, rdata);
    nda_read(bfm_if, NDA_RESULT_LO, rdata, resp);
    check_equal("post_abort_result", 0, rdata);
    report_results("tb_soc_integration");
  end

endmodule

`resetall
