// =============================================================================
// tb_soc_sw.sv — LEVEL 3: real VeeR EL2 + veer_axi_adapter + honours_soc.
//
// DUT = the toolchain-to-hardware path (compiler, startup.S, linker.ld,
// hex image, core fetch/execute, width adapter, interconnect, wrappers).
// The BFM does not appear here; the core is the only master.
//
// Wiring: VeeR (64-bit LSU/IFU/SB) -> veer_axi_adapter (3:1 mux + 64->32)
//         -> honours_soc.s_axi_* (32-bit) -> RAM/UART/Timer/GPIO.
// VeeR config for this TB: build_axi4=1, iccm/dccm/icache DISABLED (SRAM
// exports float; all fetches/loads go to AXI). Adapter ID params (3/3/1)
// must match the generated el2_param.vh (defaults: lsu_num_nbload=4,
// icache_ln_sz=64).
//
// Checks (all three must hold for PASS):
//   1. UART console contains the per-test "<NAME> OK" tag (mentor-critical
//      software-visible channel; sampled at (div+1) clocks/bit, div=100).
//   2. Signature word at 0x0000_7FF0 == 'PASS' (independent of UART).
//   3. ebreak retired (trace port insn == 0x00100073); any trap in these
//      poll-only tests writes 0xDEAD + ebreaks, so ebreak alone is not
//      sufficient — it must come WITH 1+2.
// Plusarg: +SW_TEST=gpio|uart|timer selects the expected tag (+SW_HEX is
// consumed directly by axi_ram for the program image).
// =============================================================================

`resetall
`timescale 1ns / 1ps

import soc_pkg::*;
import tb_pkg::*;
`include "tb_tasks.svh"

// Default mode retains the original standalone checker and $finish. A parent
// UVM top can request completion publication while owning simulation lifetime.
module tb_soc_sw #(
  parameter bit EXTERNAL_COMPLETION = 0
)(
  output bit completion_done = 0,
  output bit completion_pass = 0,
  output bit completion_uart_ok = 0,
  output logic [31:0] completion_signature = 0
);

  logic clk = 1'b0;
  logic aresetn;
  always #(tb_pkg::CLK_PERIOD_NS/2) clk = ~clk;

  `ifdef FSDB_DUMP
  initial begin
    if (!EXTERNAL_COMPLETION) begin
      $fsdbDumpfile("tb_soc_sw.fsdb");
      $fsdbDumpvars(0, tb_soc_sw);
    end
  end
  `endif

  initial begin
    repeat (5_000_000) @(posedge clk);
    $display("TEST sw: FAIL (global timeout)");
    $display("TIMEOUT PC=%h lsu AR=%h AW=%h adapter=%0d NDA fsm=%0d outstanding=%0d status=%h irq=%b/%b",
      tr_pc, lsu_araddr, lsu_awaddr,
      u_adapter.state, dut.u_nda.fsm, dut.u_nda.outstanding,
      dut.u_nda.err_code_reg, nda_irq_mon, wdt_irq_mon);
    $fatal(1, "Global simulation timeout");
  end

  // --- Test selection -------------------------------------------------------
  string sw_test;
  string tag_ok;
  initial begin
    if (!$value$plusargs("SW_TEST=%s", sw_test)) sw_test = "gpio";
    if (sw_test == "gpio") tag_ok = "GPIO OK";
    else if (sw_test == "uart") tag_ok = "UART OK";
    else if (sw_test == "timer") tag_ok = "TIMER OK";
    else if (sw_test == "nda") tag_ok = "NDA OK";
    else if (sw_test == "hpm") tag_ok = "HPM OK";
    else if (sw_test == "wdt") tag_ok = "WDT OK";
    else tag_ok = "UNKNOWN";
    $display("[tb_soc_sw] SW_TEST=%s expect_tag=\"%s\"", sw_test, tag_ok);
  end

  // --- VeeR AXI wires (64-bit) ----------------------------------------------
  logic lsu_awvalid, lsu_awready, lsu_wvalid, lsu_wready, lsu_wlast;
  logic lsu_bvalid, lsu_bready, lsu_arvalid, lsu_arready;
  logic lsu_rvalid, lsu_rready, lsu_rlast;
  logic [2:0] lsu_awid, lsu_arid, lsu_bid, lsu_rid;
  logic [31:0] lsu_awaddr, lsu_araddr;
  logic [3:0] lsu_awregion, lsu_awcache, lsu_arregion, lsu_arcache;
  logic [7:0] lsu_awlen, lsu_arlen;
  logic [2:0] lsu_awsize, lsu_arsize;
  logic [1:0] lsu_awburst, lsu_arburst;
  logic lsu_awlock, lsu_arlock;
  logic [2:0] lsu_awprot, lsu_arprot;
  logic [3:0] lsu_awqos, lsu_arqos;
  logic [63:0] lsu_wdata, lsu_rdata;
  logic [7:0] lsu_wstrb;
  logic [1:0] lsu_bresp, lsu_rresp;

  logic ifu_awvalid, ifu_awready, ifu_wvalid, ifu_wready, ifu_wlast;
  logic ifu_bvalid, ifu_bready, ifu_arvalid, ifu_arready;
  logic ifu_rvalid, ifu_rready, ifu_rlast;
  logic [2:0] ifu_awid, ifu_arid, ifu_bid, ifu_rid;
  logic [31:0] ifu_awaddr, ifu_araddr;
  logic [3:0] ifu_awregion, ifu_awcache, ifu_arregion, ifu_arcache;
  logic [7:0] ifu_awlen, ifu_arlen;
  logic [2:0] ifu_awsize, ifu_arsize;
  logic [1:0] ifu_awburst, ifu_arburst;
  logic ifu_awlock, ifu_arlock;
  logic [2:0] ifu_awprot, ifu_arprot;
  logic [3:0] ifu_awqos, ifu_arqos;
  logic [63:0] ifu_wdata, ifu_rdata;
  logic [7:0] ifu_wstrb;
  logic [1:0] ifu_bresp, ifu_rresp;

  logic sb_awvalid, sb_awready, sb_wvalid, sb_wready, sb_wlast;
  logic sb_bvalid, sb_bready, sb_arvalid, sb_arready;
  logic sb_rvalid, sb_rready, sb_rlast;
  logic sb_awid, sb_arid, sb_bid, sb_rid;
  logic [31:0] sb_awaddr, sb_araddr;
  logic [3:0] sb_awregion, sb_awcache, sb_arregion, sb_arcache;
  logic [7:0] sb_awlen, sb_arlen;
  logic [2:0] sb_awsize, sb_arsize;
  logic [1:0] sb_awburst, sb_arburst;
  logic sb_awlock, sb_arlock;
  logic [2:0] sb_awprot, sb_arprot;
  logic [3:0] sb_awqos, sb_arqos;
  logic [63:0] sb_wdata, sb_rdata;
  logic [7:0] sb_wstrb;
  logic [1:0] sb_bresp, sb_rresp;

  // --- Adapter -> SoC wires (32-bit) -----------------------------------------
  logic [11:0] s_awid, s_bid, s_arid, s_rid;
  logic [31:0] s_awaddr, s_araddr, s_wdata, s_rdata;
  logic [7:0] s_awlen, s_arlen;
  logic [2:0] s_awsize, s_arsize;
  logic [1:0] s_awburst, s_arburst;
  logic s_awvalid, s_awready, s_wlast, s_wvalid, s_wready;
  logic [3:0] s_wstrb;
  logic [1:0] s_bresp, s_rresp;
  logic s_bvalid, s_bready, s_arvalid, s_arready, s_rlast, s_rvalid, s_rready;

  wire uart_tx_mon;
  wire uart_irq_mon;
  wire timer_irq_mon;
  wire nda_irq_mon, wdt_irq_mon;
  logic saw_nda_irq = 0, saw_wdt_irq = 0;
  int irq_debug_count = 0;
  always @(posedge clk) begin
    if (nda_irq_mon) saw_nda_irq <= 1;
    if (wdt_irq_mon) saw_wdt_irq <= 1;
  end
  wire [soc_pkg::GPIO_WIDTH-1:0] gpio_out_mon;
  logic saw_timer_irq = 1'b0;
  always @(posedge clk) if (timer_irq_mon) saw_timer_irq <= 1'b1;

  // Trace (ebreak retire detection). insn==ebreak catches a clean retire;
  // exception+ecause==3 (breakpoint) catches the trap path, where inst_wb
  // may already have moved past the ebreak when the exception valid fires.
  wire [31:0] tr_insn;
  wire tr_valid, tr_exc;
  wire [31:0] tr_pc;
  wire [4:0] tr_cause;
  wire [31:1] pic_irqs;
  assign pic_irqs = (31'(uart_irq_mon) << (IRQ_UART-1)) |
                    (31'(timer_irq_mon) << (IRQ_TIMER-1)) |
                    (31'(nda_irq_mon) << (IRQ_NDA-1)) |
                    (31'(wdt_irq_mon) << (IRQ_WDT-1));
  initial assert (`RV_PIC_BASE_ADDR == soc_pkg::PIC_BASE)
    else $fatal(1, "Generated VeeR PIC base disagrees with soc_pkg");
  always @(posedge clk) begin
    if ($test$plusargs("IRQ_DEBUG") && (nda_irq_mon || wdt_irq_mon) &&
        irq_debug_count < 50 && tr_valid) begin
      irq_debug_count++;
      $display("IRQ_TRACE PC=%h insn=%h exc=%b cause=%h", tr_pc, tr_insn, tr_exc, tr_cause);
    end
  end
  always @(posedge nda_irq_mon or posedge wdt_irq_mon) begin
    if ($test$plusargs("IRQ_DEBUG"))
      $display("IRQ_STATE pc=%h claim=%h priority=%h threshold=%h current=%h enables=%h",
        tr_pc, veer.veer.pic_claimid, veer.veer.pic_pl,
        veer.veer.dec_tlu_meipt, veer.veer.dec_tlu_meicurpl,
        veer.veer.pic_ctrl_inst.intenable_reg);
  end

  el2_mem_if mem_export ();
  el2_mem_if icache_export ();

  el2_veer_wrapper veer (
    .clk            (clk),
    .rst_l          (aresetn),
    .dbg_rst_l      (aresetn),
    .rst_vec        (31'b0),
    .nmi_int        (1'b0),
    .nmi_vec        (31'b0),
    .jtag_id        ({4'b0001, 16'b0, 11'h045}),
    .trace_rv_i_insn_ip      (tr_insn),
    .trace_rv_i_address_ip   (tr_pc),
    .trace_rv_i_valid_ip     (tr_valid),
    .trace_rv_i_exception_ip (tr_exc),
    .trace_rv_i_ecause_ip    (tr_cause),
    .trace_rv_i_interrupt_ip (),
    .trace_rv_i_tval_ip      (),
    .lsu_axi_awvalid (lsu_awvalid), .lsu_axi_awready (lsu_awready),
    .lsu_axi_awid    (lsu_awid),    .lsu_axi_awaddr  (lsu_awaddr),
    .lsu_axi_awregion(lsu_awregion),.lsu_axi_awlen   (lsu_awlen),
    .lsu_axi_awsize  (lsu_awsize),  .lsu_axi_awburst (lsu_awburst),
    .lsu_axi_awlock  (lsu_awlock),  .lsu_axi_awcache (lsu_awcache),
    .lsu_axi_awprot  (lsu_awprot),  .lsu_axi_awqos   (lsu_awqos),
    .lsu_axi_wvalid  (lsu_wvalid),  .lsu_axi_wready  (lsu_wready),
    .lsu_axi_wdata   (lsu_wdata),   .lsu_axi_wstrb   (lsu_wstrb),
    .lsu_axi_wlast   (lsu_wlast),
    .lsu_axi_bvalid  (lsu_bvalid),  .lsu_axi_bready  (lsu_bready),
    .lsu_axi_bresp   (lsu_bresp),   .lsu_axi_bid     (lsu_bid),
    .lsu_axi_arvalid (lsu_arvalid), .lsu_axi_arready (lsu_arready),
    .lsu_axi_arid    (lsu_arid),    .lsu_axi_araddr  (lsu_araddr),
    .lsu_axi_arregion(lsu_arregion),.lsu_axi_arlen   (lsu_arlen),
    .lsu_axi_arsize  (lsu_arsize),  .lsu_axi_arburst (lsu_arburst),
    .lsu_axi_arlock  (lsu_arlock),  .lsu_axi_arcache (lsu_arcache),
    .lsu_axi_arprot  (lsu_arprot),  .lsu_axi_arqos   (lsu_arqos),
    .lsu_axi_rvalid  (lsu_rvalid),  .lsu_axi_rready  (lsu_rready),
    .lsu_axi_rid     (lsu_rid),     .lsu_axi_rdata   (lsu_rdata),
    .lsu_axi_rresp   (lsu_rresp),   .lsu_axi_rlast   (lsu_rlast),
    .ifu_axi_awvalid (ifu_awvalid), .ifu_axi_awready (ifu_awready),
    .ifu_axi_awid    (ifu_awid),    .ifu_axi_awaddr  (ifu_awaddr),
    .ifu_axi_awregion(ifu_awregion),.ifu_axi_awlen   (ifu_awlen),
    .ifu_axi_awsize  (ifu_awsize),  .ifu_axi_awburst (ifu_awburst),
    .ifu_axi_awlock  (ifu_awlock),  .ifu_axi_awcache (ifu_awcache),
    .ifu_axi_awprot  (ifu_awprot),  .ifu_axi_awqos   (ifu_awqos),
    .ifu_axi_wvalid  (ifu_wvalid),  .ifu_axi_wready  (ifu_wready),
    .ifu_axi_wdata   (ifu_wdata),   .ifu_axi_wstrb   (ifu_wstrb),
    .ifu_axi_wlast   (ifu_wlast),
    .ifu_axi_bvalid  (ifu_bvalid),  .ifu_axi_bready  (ifu_bready),
    .ifu_axi_bresp   (ifu_bresp),   .ifu_axi_bid     (ifu_bid),
    .ifu_axi_arvalid (ifu_arvalid), .ifu_axi_arready (ifu_arready),
    .ifu_axi_arid    (ifu_arid),    .ifu_axi_araddr  (ifu_araddr),
    .ifu_axi_arregion(ifu_arregion),.ifu_axi_arlen   (ifu_arlen),
    .ifu_axi_arsize  (ifu_arsize),  .ifu_axi_arburst (ifu_arburst),
    .ifu_axi_arlock  (ifu_arlock),  .ifu_axi_arcache (ifu_arcache),
    .ifu_axi_arprot  (ifu_arprot),  .ifu_axi_arqos   (ifu_arqos),
    .ifu_axi_rvalid  (ifu_rvalid),  .ifu_axi_rready  (ifu_rready),
    .ifu_axi_rid     (ifu_rid),     .ifu_axi_rdata   (ifu_rdata),
    .ifu_axi_rresp   (ifu_rresp),   .ifu_axi_rlast   (ifu_rlast),
    .sb_axi_awvalid  (sb_awvalid),  .sb_axi_awready  (sb_awready),
    .sb_axi_awid     (sb_awid),     .sb_axi_awaddr   (sb_awaddr),
    .sb_axi_awregion (sb_awregion), .sb_axi_awlen    (sb_awlen),
    .sb_axi_awsize   (sb_awsize),   .sb_axi_awburst  (sb_awburst),
    .sb_axi_awlock   (sb_awlock),   .sb_axi_awcache  (sb_awcache),
    .sb_axi_awprot   (sb_awprot),   .sb_axi_awqos    (sb_awqos),
    .sb_axi_wvalid   (sb_wvalid),   .sb_axi_wready   (sb_wready),
    .sb_axi_wdata    (sb_wdata),    .sb_axi_wstrb    (sb_wstrb),
    .sb_axi_wlast    (sb_wlast),
    .sb_axi_bvalid   (sb_bvalid),   .sb_axi_bready   (sb_bready),
    .sb_axi_bresp    (sb_bresp),    .sb_axi_bid      (sb_bid),
    .sb_axi_arvalid  (sb_arvalid),  .sb_axi_arready  (sb_arready),
    .sb_axi_arid     (sb_arid),     .sb_axi_araddr   (sb_araddr),
    .sb_axi_arregion (sb_arregion), .sb_axi_arlen    (sb_arlen),
    .sb_axi_arsize   (sb_arsize),   .sb_axi_arburst  (sb_arburst),
    .sb_axi_arlock   (sb_arlock),   .sb_axi_arcache  (sb_arcache),
    .sb_axi_arprot   (sb_arprot),   .sb_axi_arqos    (sb_arqos),
    .sb_axi_rvalid   (sb_rvalid),   .sb_axi_rready   (sb_rready),
    .sb_axi_rid      (sb_rid),      .sb_axi_rdata    (sb_rdata),
    .sb_axi_rresp    (sb_rresp),    .sb_axi_rlast    (sb_rlast),
    // DMA slave (unused): quiet.
    .dma_axi_awvalid (1'b0), .dma_axi_awid ('0), .dma_axi_awaddr ('0),
    .dma_axi_awsize  ('0), .dma_axi_awprot ('0), .dma_axi_awlen ('0),
    .dma_axi_awburst ('0),
    .dma_axi_wvalid  (1'b0), .dma_axi_wdata ('0), .dma_axi_wstrb ('0),
    .dma_axi_wlast   (1'b0),
    .dma_axi_bready  (1'b1),
    .dma_axi_arvalid (1'b0), .dma_axi_arid ('0), .dma_axi_araddr ('0),
    .dma_axi_arsize  ('0), .dma_axi_arprot ('0), .dma_axi_arlen ('0),
    .dma_axi_arburst ('0),
    .dma_axi_rready  (1'b1),
    .dma_axi_awready (), .dma_axi_wready (), .dma_axi_bvalid (),
    .dma_axi_bresp (), .dma_axi_bid (), .dma_axi_arready (),
    .dma_axi_rvalid (), .dma_axi_rid (), .dma_axi_rdata (),
    .dma_axi_rresp (), .dma_axi_rlast (),
    .lsu_bus_clk_en (1'b1), .ifu_bus_clk_en (1'b1),
    .dbg_bus_clk_en (1'b1), .dma_bus_clk_en (1'b1),
    .iccm_ecc_single_error (), .iccm_ecc_double_error (),
    .dccm_ecc_single_error (), .dccm_ecc_double_error (),
    .dccm_write_readback_error (),
    .el2_icache_export (icache_export.veer_icache_src),
    .timer_int (1'b0), .soft_int (1'b0),
    .extintsrc_req (pic_irqs),
    .dec_tlu_perfcnt0 (), .dec_tlu_perfcnt1 (),
    .dec_tlu_perfcnt2 (), .dec_tlu_perfcnt3 (),
    .jtag_tck (1'b0), .jtag_tms (1'b0), .jtag_tdi (1'b0),
    .jtag_trst_n (1'b1), .jtag_tdo (), .jtag_tdoEn (),
    .core_id (28'b0),
    .el2_mem_export (mem_export.veer_sram_src),
    .mpc_debug_halt_req (1'b0), .mpc_debug_run_req (1'b0),
    .mpc_reset_run_req (1'b1),
    .mpc_debug_halt_ack (), .mpc_debug_run_ack (), .debug_brkpt_status (),
    .i_cpu_halt_req (1'b0), .o_cpu_halt_ack (), .o_cpu_halt_status (),
    .o_debug_mode_status (), .i_cpu_run_req (1'b0), .o_cpu_run_ack (),
    .scan_mode (1'b0), .mbist_mode (1'b0),
    .dmi_core_enable (1'b0), .dmi_uncore_enable (1'b0),
    .dmi_uncore_en (), .dmi_uncore_wr_en (), .dmi_uncore_addr (),
    .dmi_uncore_wdata (), .dmi_uncore_rdata (32'b0), .dmi_active ()
  );

  veer_axi_adapter #(
    .LSU_ID_W (3), .IFU_ID_W (3), .SB_ID_W (1)
  ) u_adapter (
    .clk (clk), .aresetn (aresetn),
    .lsu_awid (lsu_awid), .lsu_awaddr (lsu_awaddr),
    .lsu_awlen (lsu_awlen), .lsu_awsize (lsu_awsize),
    .lsu_awburst (lsu_awburst), .lsu_awvalid (lsu_awvalid),
    .lsu_awready (lsu_awready),
    .lsu_wdata (lsu_wdata), .lsu_wstrb (lsu_wstrb),
    .lsu_wlast (lsu_wlast), .lsu_wvalid (lsu_wvalid),
    .lsu_wready (lsu_wready),
    .lsu_bid (lsu_bid), .lsu_bresp (lsu_bresp),
    .lsu_bvalid (lsu_bvalid), .lsu_bready (lsu_bready),
    .lsu_arid (lsu_arid), .lsu_araddr (lsu_araddr),
    .lsu_arlen (lsu_arlen), .lsu_arsize (lsu_arsize),
    .lsu_arburst (lsu_arburst), .lsu_arvalid (lsu_arvalid),
    .lsu_arready (lsu_arready),
    .lsu_rid (lsu_rid), .lsu_rdata (lsu_rdata),
    .lsu_rresp (lsu_rresp), .lsu_rlast (lsu_rlast),
    .lsu_rvalid (lsu_rvalid), .lsu_rready (lsu_rready),
    .lsu_awregion (lsu_awregion), .lsu_awcache (lsu_awcache),
    .lsu_awprot (lsu_awprot), .lsu_awqos (lsu_awqos),
    .lsu_awlock (lsu_awlock),
    .lsu_arregion (lsu_arregion), .lsu_arcache (lsu_arcache),
    .lsu_arprot (lsu_arprot), .lsu_arqos (lsu_arqos),
    .lsu_arlock (lsu_arlock),
    .ifu_awid (ifu_awid), .ifu_awaddr (ifu_awaddr),
    .ifu_awlen (ifu_awlen), .ifu_awsize (ifu_awsize),
    .ifu_awburst (ifu_awburst), .ifu_awvalid (ifu_awvalid),
    .ifu_awready (ifu_awready),
    .ifu_wdata (ifu_wdata), .ifu_wstrb (ifu_wstrb),
    .ifu_wlast (ifu_wlast), .ifu_wvalid (ifu_wvalid),
    .ifu_wready (ifu_wready),
    .ifu_bid (ifu_bid), .ifu_bresp (ifu_bresp),
    .ifu_bvalid (ifu_bvalid), .ifu_bready (ifu_bready),
    .ifu_arid (ifu_arid), .ifu_araddr (ifu_araddr),
    .ifu_arlen (ifu_arlen), .ifu_arsize (ifu_arsize),
    .ifu_arburst (ifu_arburst), .ifu_arvalid (ifu_arvalid),
    .ifu_arready (ifu_arready),
    .ifu_rid (ifu_rid), .ifu_rdata (ifu_rdata),
    .ifu_rresp (ifu_rresp), .ifu_rlast (ifu_rlast),
    .ifu_rvalid (ifu_rvalid), .ifu_rready (ifu_rready),
    .ifu_awregion (ifu_awregion), .ifu_awcache (ifu_awcache),
    .ifu_awprot (ifu_awprot), .ifu_awqos (ifu_awqos),
    .ifu_awlock (ifu_awlock),
    .ifu_arregion (ifu_arregion), .ifu_arcache (ifu_arcache),
    .ifu_arprot (ifu_arprot), .ifu_arqos (ifu_arqos),
    .ifu_arlock (ifu_arlock),
    .sb_awid (sb_awid), .sb_awaddr (sb_awaddr),
    .sb_awlen (sb_awlen), .sb_awsize (sb_awsize),
    .sb_awburst (sb_awburst), .sb_awvalid (sb_awvalid),
    .sb_awready (sb_awready),
    .sb_wdata (sb_wdata), .sb_wstrb (sb_wstrb),
    .sb_wlast (sb_wlast), .sb_wvalid (sb_wvalid),
    .sb_wready (sb_wready),
    .sb_bid (sb_bid), .sb_bresp (sb_bresp),
    .sb_bvalid (sb_bvalid), .sb_bready (sb_bready),
    .sb_arid (sb_arid), .sb_araddr (sb_araddr),
    .sb_arlen (sb_arlen), .sb_arsize (sb_arsize),
    .sb_arburst (sb_arburst), .sb_arvalid (sb_arvalid),
    .sb_arready (sb_arready),
    .sb_rid (sb_rid), .sb_rdata (sb_rdata),
    .sb_rresp (sb_rresp), .sb_rlast (sb_rlast),
    .sb_rvalid (sb_rvalid), .sb_rready (sb_rready),
    .sb_awregion (sb_awregion), .sb_awcache (sb_awcache),
    .sb_awprot (sb_awprot), .sb_awqos (sb_awqos),
    .sb_awlock (sb_awlock),
    .sb_arregion (sb_arregion), .sb_arcache (sb_arcache),
    .sb_arprot (sb_arprot), .sb_arqos (sb_arqos),
    .sb_arlock (sb_arlock),
    .m_awid (s_awid), .m_awaddr (s_awaddr),
    .m_awlen (s_awlen), .m_awsize (s_awsize), .m_awburst (s_awburst),
    .m_awvalid (s_awvalid), .m_awready (s_awready),
    .m_wdata (s_wdata), .m_wstrb (s_wstrb), .m_wlast (s_wlast),
    .m_wvalid (s_wvalid), .m_wready (s_wready),
    .m_bid (s_bid), .m_bresp (s_bresp),
    .m_bvalid (s_bvalid), .m_bready (s_bready),
    .m_arid (s_arid), .m_araddr (s_araddr),
    .m_arlen (s_arlen), .m_arsize (s_arsize), .m_arburst (s_arburst),
    .m_arvalid (s_arvalid), .m_arready (s_arready),
    .m_rid (s_rid), .m_rdata (s_rdata), .m_rresp (s_rresp),
    .m_rlast (s_rlast), .m_rvalid (s_rvalid), .m_rready (s_rready)
  );

  honours_soc dut (
    .clk (clk), .aresetn (aresetn),
    .s_axi_awid (s_awid), .s_axi_awaddr (s_awaddr),
    .s_axi_awlen (s_awlen), .s_axi_awsize (s_awsize),
    .s_axi_awburst (s_awburst), .s_axi_awvalid (s_awvalid),
    .s_axi_awready (s_awready),
    .s_axi_wdata (s_wdata), .s_axi_wstrb (s_wstrb),
    .s_axi_wlast (s_wlast), .s_axi_wvalid (s_wvalid),
    .s_axi_wready (s_wready),
    .s_axi_bid (s_bid), .s_axi_bresp (s_bresp),
    .s_axi_bvalid (s_bvalid), .s_axi_bready (s_bready),
    .s_axi_arid (s_arid), .s_axi_araddr (s_araddr),
    .s_axi_arlen (s_arlen), .s_axi_arsize (s_arsize),
    .s_axi_arburst (s_arburst), .s_axi_arvalid (s_arvalid),
    .s_axi_arready (s_arready),
    .s_axi_rid (s_rid), .s_axi_rdata (s_rdata),
    .s_axi_rresp (s_rresp), .s_axi_rlast (s_rlast),
    .s_axi_rvalid (s_rvalid), .s_axi_rready (s_rready),
    .uart_rx_i (1'b1), .uart_tx_o (uart_tx_mon), .uart_irq_o (uart_irq_mon),
    .timer_irq_o (timer_irq_mon),
    .nda_irq_o (nda_irq_mon), .wdt_irq_o (wdt_irq_mon),
    .gpio_in (8'hA5), .gpio_out (gpio_out_mon)
  );

  // EXTERNAL WDT scenario: pause RAM R handshakes once, then release.
  // Force the receiver READY register, preserving the RAM's held VALID/data.
  // This is backpressure, not cancellation of an accepted AXI request.
  generate
    if (soc_pkg::ENABLE_HPM) begin : gen_fault_7
      initial begin
        wait (sw_test == "wdt" && aresetn);
        wait (dut.nda_arvalid && dut.nda_arready);
        @(negedge clk);
        force dut.gen_xbar_2x7.u_xbar.axi_interconnect_inst.m_axi_rready_reg = '0;
        repeat (512) @(negedge clk);
        release dut.gen_xbar_2x7.u_xbar.axi_interconnect_inst.m_axi_rready_reg;
      end
    end else begin : gen_fault_6
      initial begin
        wait (sw_test == "wdt" && aresetn);
        wait (dut.nda_arvalid && dut.nda_arready);
        @(negedge clk);
        force dut.gen_xbar_2x6.u_xbar.axi_interconnect_inst.m_axi_rready_reg = '0;
        repeat (512) @(negedge clk);
        release dut.gen_xbar_2x6.u_xbar.axi_interconnect_inst.m_axi_rready_reg;
      end
    end
  endgenerate

  // --- UART console monitor (TX @ div=100 -> 1010 ns/bit) --------------------
  localparam real TBIT_NS = 1010.0;
  string uart_log = "";
  logic saw_ebreak = 1'b0;

  function automatic bit str_has(string hay, string needle);
    int h = hay.len(), n = needle.len();
    if (n == 0) return 1'b1;
    if (h < n) return 1'b0;
    for (int i = 0; i <= h - n; i++)
      if (hay.substr(i, i + n - 1) == needle) return 1'b1;
    return 1'b0;
  endfunction

  task automatic uart_monitor();
    byte b;
    forever begin
      wait (uart_tx_mon === 1'b0); // start bit
      #(TBIT_NS * 1.5);
      for (int i = 0; i < 8; i++) begin
        b[i] = uart_tx_mon;
        #(TBIT_NS);
      end
      uart_log = {uart_log, string'(b)};
      $write("%c", b);
    end
  endtask

  // ebreak retire detect via the trace port.
  always @(posedge clk) begin
    if (aresetn && tr_valid &&
        (tr_insn == 32'h00100073 ||
         (tr_exc && tr_cause == 5'h03)))
      saw_ebreak <= 1'b1;
  end

  initial begin
    logic [31:0] sig;
    bit uart_ok, sig_ok;

    aresetn = 1'b0;
    #(tb_pkg::CLK_PERIOD_NS * tb_pkg::RST_CYCLES);
    aresetn = 1'b1;
    #(tb_pkg::CLK_PERIOD_NS * 2);

    fork
      uart_monitor();
    join_none

    // Wait for SW ebreak, then give the TX FIFO time to drain onto the
    // wire: ebreak fires microseconds after the last THR write, but the
    // UART still has up to ~160us of bytes to shift out. Wait for the tag
    // (or FAIL) with a bounded timeout instead of a fixed nap.
    wait (saw_ebreak === 1'b1);
    begin
      int unsigned tmo = 0;
      while (!str_has(uart_log, tag_ok) && !str_has(uart_log, "FAIL") &&
             tmo < 5000) begin
        #(1000.0);
        tmo++;
      end
    end
    #(TBIT_NS * 2);
    // Stop the monitor before evaluating (kill the forked frame sampler).
    disable fork;

    $display("\n[tb_soc_sw] console log:\n%s", uart_log);
    uart_ok = str_has(uart_log, tag_ok);
    if (str_has(uart_log, "FAIL"))
      uart_ok = 1'b0;

    // Independent signature check (hierarchical RAM read, word 0x7FF0).
    sig = dut.u_ram.mem[32'h7FF0 >> 2];
    sig_ok = (sig == 32'h50515353);
    $display("[tb_soc_sw] sig=0x%08h uart_ok=%0d sig_ok=%0d ebreak=1 gpio_out=0x%02h timer_irq_seen=%0d",
             sig, uart_ok, sig_ok, gpio_out_mon, saw_timer_irq);
    check_equal("sw_uart_tag", 32'h1, {31'b0, uart_ok});
    check_equal("sw_signature", 32'h50515353, sig);
    if (sw_test == "timer")
      check_equal("sw_timer_irq", 32'h1, {31'b0, saw_timer_irq});
    if (sw_test == "nda") check_equal("sw_nda_irq", 1, saw_nda_irq);
    if (sw_test == "wdt") check_equal("sw_wdt_irq", 1, saw_wdt_irq);
    completion_signature = sig;
    completion_uart_ok = uart_ok;
    completion_pass = (fail_count == 0);
    completion_done = 1;
    if (!EXTERNAL_COMPLETION) report_results({"sw_", sw_test});
  end

endmodule

`resetall
