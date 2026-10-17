// =============================================================================
// tb_hpm_unit.sv — LEVEL 1: DUT = hpm_wrapper only.
//
// Tests:
//   - Reset values (CTRL=0, all counters 0)
//   - Counters match a known traffic pattern exactly
//   - SNAPSHOT consistency
//   - CLEAR resets all counters
//   - ENABLE gating (CYCLES only counts while enabled)
//   - FALLBACKS increments on wdt_trip pulse
//   - Read undefined offset → SLVERR
//   - Write to counter register (RO) → SLVERR
// =============================================================================

`resetall
`timescale 1ns / 1ps

import soc_pkg::*;
import tb_pkg::*;
`include "tb_tasks.svh"

module tb_hpm_unit;

  logic clk = 1'b0;
  logic aresetn;
  always #(tb_pkg::CLK_PERIOD_NS/2) clk = ~clk;

  `ifdef FSDB_DUMP
  initial begin
    $fsdbDumpfile("tb_hpm_unit.fsdb");
    $fsdbDumpvars(0, tb_hpm_unit);
  end
  `endif

  initial begin
    repeat (500_000) @(posedge clk);
    $display("TEST tb_hpm_unit: FAIL (global timeout)");
    $finish;
  end

  axi_master_bfm bfm_if (.clk(clk), .aresetn(aresetn));

  // Tap point stimulus — driven on negedge to avoid race with always_ff
  logic m0_ar_v = 0, m0_ar_r = 0;
  logic m0_aw_v = 0, m0_aw_r = 0;
  logic m0_r_v = 0, m0_r_r = 0;
  logic m0_w_v = 0, m0_w_r = 0;
  logic m1_ar_v = 0, m1_ar_r = 0;
  logic m1_r_v = 0, m1_r_r = 0;
  logic nda_busy_stim = 0;
  logic wdt_trip_stim = 0;

  hpm_wrapper #(
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

    // Tap points
    .m0_ar_valid   (m0_ar_v & m0_ar_r),
    .m0_ar_ready   (1'b1),
    .m0_aw_valid   (m0_aw_v & m0_aw_r),
    .m0_aw_ready   (1'b1),
    .m0_r_valid    (m0_r_v & m0_r_r),
    .m0_r_ready    (1'b1),
    .m0_w_valid    (m0_w_v & m0_w_r),
    .m0_w_ready    (1'b1),
    .m1_ar_valid   (m1_ar_v & m1_ar_r),
    .m1_ar_ready   (1'b1),
    .m1_r_valid    (m1_r_v & m1_r_r),
    .m1_r_ready    (1'b1),
    .nda_busy      (nda_busy_stim),
    .wdt_trip      (wdt_trip_stim)
  );

  logic [1:0] resp;
  logic [31:0] rdata, rdata_hi;

  initial begin
    bfm_if.reset_master();
    soc_reset(aresetn);

    // === 1. Reset values: CTRL=0, all counters 0 ===
    hpm_read(bfm_if, soc_pkg::HPM_CTRL, rdata, resp);
    check_equal("rst_ctrl", 32'h0, rdata);
    hpm_read(bfm_if, soc_pkg::HPM_CYCLES_LO, rdata, resp);
    check_equal("rst_cycles_lo", 32'h0, rdata);
    hpm_read(bfm_if, soc_pkg::HPM_CYCLES_LO + 4, rdata, resp);
    check_equal("rst_cycles_hi", 32'h0, rdata);
    hpm_read(bfm_if, soc_pkg::HPM_CPU_AR_LO, rdata, resp);
    check_equal("rst_cpu_ar", 32'h0, rdata);

    // === 2. Enable and run known traffic pattern ===
    hpm_write(bfm_if, soc_pkg::HPM_CTRL, 32'h1, resp); // ENABLE=1
    @(posedge clk);

    // Drive stimulus on negedge so it's stable before the next posedge.
    // Pattern over 5 active cycles:
    //   C1: CPU AR + NDA AR, nda_busy=1
    //   C2: CPU AW + CPU R beat + NDA R beat, nda_busy=1
    //   C3: CPU R beat + CPU W beat + NDA R beat, nda_busy=1
    //   C4: CPU R beat + NDA AR + WDT trip, nda_busy=0
    //   C5: idle
    //
    // Expected counts:
    //   CYCLES    = 5 (cycles while enabled, including CSR write overhead)
    //   CPU_AR    = 1
    //   CPU_AW    = 1
    //   CPU_R     = 3 (C2, C3, C4)
    //   CPU_W     = 1 (C3)
    //   NDA_AR    = 2 (C1, C4)
    //   NDA_R     = 2 (C2, C3)
    //   NDA_BUSY  = 3 (C1, C2, C3)
    //   FALLBACKS = 1 (C4)

    // C1
    @(negedge clk);
    m0_ar_v = 1; m0_ar_r = 1;
    m1_ar_v = 1; m1_ar_r = 1;
    nda_busy_stim = 1;
    @(negedge clk);
    m0_ar_v = 0; m0_ar_r = 0;
    m1_ar_v = 0; m1_ar_r = 0;

    // C2
    m0_aw_v = 1; m0_aw_r = 1;
    m0_r_v = 1; m0_r_r = 1;
    m1_r_v = 1; m1_r_r = 1;
    @(negedge clk);
    m0_aw_v = 0; m0_aw_r = 0;
    m0_r_v = 0; m0_r_r = 0;
    m1_r_v = 0; m1_r_r = 0;

    // C3
    m0_r_v = 1; m0_r_r = 1;
    m0_w_v = 1; m0_w_r = 1;
    m1_r_v = 1; m1_r_r = 1;
    @(negedge clk);
    m0_r_v = 0; m0_r_r = 0;
    m0_w_v = 0; m0_w_r = 0;
    m1_r_v = 0; m1_r_r = 0;

    // C4
    m0_r_v = 1; m0_r_r = 1;
    m1_ar_v = 1; m1_ar_r = 1;
    wdt_trip_stim = 1;
    nda_busy_stim = 0;
    @(negedge clk);
    m0_r_v = 0; m0_r_r = 0;
    m1_ar_v = 0; m1_ar_r = 0;
    wdt_trip_stim = 0;

    // C5: idle
    @(posedge clk);

    // === 3. Snapshot and read counters ===
    // Write ENABLE + SNAPSHOT (0x5) in one go. Don't disable first.
    hpm_write(bfm_if, soc_pkg::HPM_CTRL, 32'h5, resp); // ENABLE + SNAPSHOT
    @(posedge clk);

    // Read counters
    // CYCLES: at least 5 (enable was on for 5+ stimulus cycles + CSR write cycles)
    hpm_read(bfm_if, soc_pkg::HPM_CYCLES_LO, rdata, resp);
    check_equal("cycles_lo_5plus", 32'h1, {31'b0, (rdata >= 32'd5)});
    hpm_read(bfm_if, soc_pkg::HPM_CYCLES_LO + 4, rdata, resp);
    check_equal("cycles_hi", 32'h0, rdata);

    // CPU_AR: 1 handshake (C1)
    hpm_read(bfm_if, soc_pkg::HPM_CPU_AR_LO, rdata, resp);
    check_equal("cpu_ar", 32'd1, rdata);

    // CPU_AW: 1 handshake (C2)
    hpm_read(bfm_if, soc_pkg::HPM_CPU_AW_LO, rdata, resp);
    check_equal("cpu_aw", 32'd1, rdata);

    // CPU_R_BEATS: 3 beats (C2, C3, C4)
    hpm_read(bfm_if, soc_pkg::HPM_CPU_RBEATS_LO, rdata, resp);
    check_equal("cpu_r_beats", 32'd3, rdata);

    // CPU_W_BEATS: 1 beat (C3)
    hpm_read(bfm_if, soc_pkg::HPM_CPU_WBEATS_LO, rdata, resp);
    check_equal("cpu_w_beats", 32'd1, rdata);

    // NDA_AR: 2 handshakes (C1, C4)
    hpm_read(bfm_if, soc_pkg::HPM_NDA_AR_LO, rdata, resp);
    check_equal("nda_ar", 32'd2, rdata);

    // NDA_R_BEATS: 2 beats (C2, C3)
    hpm_read(bfm_if, soc_pkg::HPM_NDA_RBEATS_LO, rdata, resp);
    check_equal("nda_r_beats", 32'd2, rdata);

    // NDA_BUSY: 3 cycles (C1, C2, C3)
    hpm_read(bfm_if, soc_pkg::HPM_NDA_BUSY_LO, rdata, resp);
    check_equal("nda_busy", 32'd3, rdata);

    // FALLBACKS: 1 trip (C4)
    hpm_read(bfm_if, soc_pkg::HPM_FALLBACKS_LO, rdata, resp);
    check_equal("fallbacks", 32'd1, rdata);

    // === 4. CLEAR all counters ===
    hpm_write(bfm_if, soc_pkg::HPM_CTRL, 32'h3, resp); // ENABLE + CLEAR
    @(posedge clk);
    // Snapshot to update shadow registers. CYCLES will have accumulated
    // a few cycles between CLEAR and SNAPSHOT — that's correct behavior.
    hpm_write(bfm_if, soc_pkg::HPM_CTRL, 32'h5, resp); // ENABLE + SNAPSHOT
    @(posedge clk);

    hpm_read(bfm_if, soc_pkg::HPM_CYCLES_LO, rdata, resp);
    check_equal("clear_cycles_small", 32'h1, {31'b0, (rdata <= 32'd10)});
    hpm_read(bfm_if, soc_pkg::HPM_CPU_AR_LO, rdata, resp);
    check_equal("clear_cpu_ar", 32'd0, rdata);
    hpm_read(bfm_if, soc_pkg::HPM_FALLBACKS_LO, rdata, resp);
    check_equal("clear_fallbacks", 32'd0, rdata);

    // === 5. ENABLE gating: CYCLES should not increment while disabled ===
    hpm_write(bfm_if, soc_pkg::HPM_CTRL, 32'h0, resp); // DISABLE
    // Drive some events while disabled
    @(negedge clk);
    m0_ar_v = 1; m0_ar_r = 1;
    repeat (3) @(negedge clk);
    m0_ar_v = 0; m0_ar_r = 0;
    @(posedge clk);

    // Re-enable, snapshot, and check CPU_AR is still 0 (events not counted
    // because enable was off — except CPU_AR counts regardless of enable
    // per design doc; only CYCLES is enable-gated)
    hpm_write(bfm_if, soc_pkg::HPM_CTRL, 32'h5, resp); // ENABLE + SNAPSHOT
    @(posedge clk);

    // CPU_AR counts regardless of enable (only CYCLES is gated)
    // So CPU_AR should be 3 (3 cycles of ar handshake while disabled)
    hpm_read(bfm_if, soc_pkg::HPM_CPU_AR_LO, rdata, resp);
    check_equal("disabled_cpu_ar_counted", 32'd3, rdata);
    // CYCLES should be small (only counted after re-enable, not while disabled)
    hpm_read(bfm_if, soc_pkg::HPM_CYCLES_LO, rdata, resp);
    check_equal("enable_gating_cycles", 32'h1, {31'b0, (rdata <= 32'd20)});

    // === 6. Write to counter register (RO) → SLVERR ===
    hpm_write(bfm_if, soc_pkg::HPM_CYCLES_LO, 32'h1234, resp);
    check_equal("ro_write_slverr", 32'h2, {30'b0, resp});

    // === 7. Read undefined offset → SLVERR ===
    hpm_read(bfm_if, 32'h04, rdata, resp); // 0x04 is undefined (gap)
    check_equal("undef_read_slverr", 32'h2, {30'b0, resp});

    report_results("tb_hpm_unit");
  end

endmodule

`resetall
