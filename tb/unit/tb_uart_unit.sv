// =============================================================================
// tb_uart_unit.sv — LEVEL 1: DUT = uart_wrapper (+ untouched ips/uart core).
// BFM drives it directly. No interconnect, no core.
//
// Setup (proven against this IP): LCR=0x03 (8N1, DLAB=0), divisor=100 via
// the DLAB sequence (LCR=0x80, BAUD=100, LCR=0x03), IER=1 for RX.
// TX bit time is (div+1) clocks; RX samples at (div-1) — at div=100 the
// mismatch is ~1% and reliable (see TB history in git).
//
// Checks: config resps, TX byte on uart_tx_o (sampled), LSR THRE/TEMT,
// direct-drive RX byte + DATA_READY, loopback TX->RX byte match.
// NOTE: every RBR read PULLS the RX FIFO — RBR is read exactly once per
// expected byte; LSR is safe to poll.
// =============================================================================

`resetall
`timescale 1ns / 1ps

import soc_pkg::*;
import tb_pkg::*;
`include "tb_tasks.svh"

module tb_uart_unit;

  logic clk = 1'b0;
  logic aresetn;
  always #(tb_pkg::CLK_PERIOD_NS/2) clk = ~clk;

  `ifdef FSDB_DUMP
  initial begin
    $fsdbDumpfile("tb_uart_unit.fsdb");
    $fsdbDumpvars(0, tb_uart_unit);
  end
  `endif

  initial begin
    repeat (5_000_000) @(posedge clk);
    $display("TEST tb_uart_unit: FAIL (global timeout)");
    $fatal(1, "Global simulation timeout");
  end

  axi_master_bfm bfm_if (.clk(clk), .aresetn(aresetn));

  logic uart_rx_drv = 1'b1;
  logic loopback_en = 1'b0;
  wire  uart_tx_mon;
  wire  uart_rx_line;

  assign uart_rx_line = loopback_en ? uart_tx_mon : uart_rx_drv;

  uart_wrapper #(
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
    .uart_rx_i     (uart_rx_line),
    .uart_tx_o     (uart_tx_mon),
    .uart_irq_o    ()
  );

  // Baud timing (100 MHz ref, divisor 100 programmed below).
  localparam real TBIT_TX_NS = 1010.0; // TX: (div+1) clocks
  localparam real TBIT_RX_NS = 1000.0; // RX drive: div clocks

  // Drive one RX frame (start + 8N1 + stop) LSB-first.
  task automatic uart_rx_byte(input byte b);
    int i;
    uart_rx_drv = 1'b0; #(TBIT_RX_NS);
    for (i = 0; i < 8; i++) begin
      uart_rx_drv = b[i]; #(TBIT_RX_NS);
    end
    uart_rx_drv = 1'b1; #(TBIT_RX_NS);
  endtask

  // Poll LSR until bit[pos] sets (or timeout -> FAIL + finish).
  task automatic poll_lsr_bit(input int pos, input string what);
    logic [1:0]  resp;
    logic [31:0] lsr;
    int t = 0;
    bfm_if.read(soc_pkg::UART_BASE + soc_pkg::UART_LSR, lsr, resp);
    while (lsr[pos] !== 1'b1 && t < 5000) begin
      bfm_if.read(soc_pkg::UART_BASE + soc_pkg::UART_LSR, lsr, resp);
      t++;
    end
    if (lsr[pos] !== 1'b1) begin
      $display("[FAIL] %s: LSR bit%0d never set (lsr=0x%0h)", what, pos, lsr);
      fail_count++;
      report_results("tb_uart_unit");
    end
  endtask

  // Discard stale RX bytes (at most FIFO depth 32 + margin).
  task automatic drain_rx();
    logic [1:0]  resp;
    logic [31:0] lsr, dummy;
    int i;
    for (i = 0; i < 40; i++) begin
      bfm_if.read(soc_pkg::UART_BASE + soc_pkg::UART_LSR, lsr, resp);
      if (lsr[soc_pkg::UART_LSR_DATA_READY] !== 1'b1) break;
      bfm_if.read(soc_pkg::UART_BASE + soc_pkg::UART_RBR, dummy, resp);
    end
  endtask

  initial begin
    logic [1:0]  resp;
    logic [31:0] rdata, lsr;
    logic [7:0]  got;
    int t, i;

    bfm_if.reset_master();
    soc_reset(aresetn);

    // --- 1. Configure: 8N1 + divisor 100 (DLAB sequence) + IER ---
    bfm_if.write(soc_pkg::UART_BASE + soc_pkg::UART_LCR, 32'h80, 4'hF, resp); // DLAB=1
    check_equal("lcr_dlab_resp", 32'h0, {30'b0, resp});
    bfm_if.write(soc_pkg::UART_BASE + soc_pkg::UART_BAUD, 32'd100, 4'hF, resp);
    check_equal("baud_resp", 32'h0, {30'b0, resp});
    bfm_if.write(soc_pkg::UART_BASE + soc_pkg::UART_LCR, 32'h03, 4'hF, resp); // 8N1
    check_equal("lcr_8n1_resp", 32'h0, {30'b0, resp});
    bfm_if.write(soc_pkg::UART_BASE + soc_pkg::UART_IER, 32'h01, 4'hF, resp);
    check_equal("ier_resp", 32'h0, {30'b0, resp});

    // --- 2. TX: send 0x48, sample the wire ---
    uart_send(bfm_if, 8'h48, resp);
    check_equal("tx_bresp", 32'h0, {30'b0, resp});
    t = 0;
    while (uart_tx_mon !== 1'b0 && t < 30000) begin
      #100;
      t++;
    end
    if (uart_tx_mon !== 1'b0) begin
      $display("[FAIL] tx_start: no start bit seen");
      fail_count++;
      report_results("tb_uart_unit");
    end
    #(TBIT_TX_NS * 1.5);
    for (i = 0; i < 8; i++) begin
      got[i] = uart_tx_mon;
      #(TBIT_TX_NS);
    end
    check_equal("tx_stop_bit", 32'h1, {31'b0, uart_tx_mon});
    check_equal("tx_byte", 32'h48, {24'b0, got});

    // --- 3. LSR: THRE + TEMT set, no RX pending ---
    poll_lsr_bit(soc_pkg::UART_LSR_TEMT, "tx_done");
    uart_read_lsr(bfm_if, lsr, resp);
    check_equal("lsr_resp", 32'h0, {30'b0, resp});
    check_equal("lsr_thre_temt", 32'h3, {30'b0, lsr[6:5]});
    check_equal("lsr_no_rx", 32'h0, {31'b0, lsr[soc_pkg::UART_LSR_DATA_READY]});

    // --- 4. Direct-drive RX: 0xA5 ---
    uart_rx_byte(8'hA5);
    #(TBIT_RX_NS * 2);
    poll_lsr_bit(soc_pkg::UART_LSR_DATA_READY, "rx_ready");
    bfm_if.read(soc_pkg::UART_BASE + soc_pkg::UART_RBR, rdata, resp);
    check_equal("rx_bresp", 32'h0, {30'b0, resp});
    check_equal("rx_byte", 32'hA5, {24'b0, rdata[7:0]});
    // DATA_READY clears after the (single) byte is pulled
    uart_read_lsr(bfm_if, lsr, resp);
    check_equal("lsr_rx_clear", 32'h0,
                {31'b0, lsr[soc_pkg::UART_LSR_DATA_READY]});

    // --- 5. Loopback: TX 0x3C -> RX, read back ---
    drain_rx();
    loopback_en = 1'b1;
    uart_send(bfm_if, 8'h3C, resp);
    check_equal("lb_tx_resp", 32'h0, {30'b0, resp});
    poll_lsr_bit(soc_pkg::UART_LSR_DATA_READY, "lb_ready");
    bfm_if.read(soc_pkg::UART_BASE + soc_pkg::UART_RBR, rdata, resp);
    check_equal("lb_byte", 32'h3C, {24'b0, rdata[7:0]});
    loopback_en = 1'b0;

    report_results("tb_uart_unit");
  end

endmodule

`resetall
