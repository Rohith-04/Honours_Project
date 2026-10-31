// =============================================================================
// tb_nda_unit.sv — LEVEL 1: DUT = nda_wrapper only.
//
// The NDA has two AXI ports: a CSR slave (driven by the BFM) and a read
// master (which reads from an axi_ram instance).  This test wires both
// and exercises:
//   - Reset values
//   - Each error code and check order
//   - All four operations (SUM, MIN, MAX, ARGMAX) on known arrays
//   - SUM exceeding 32 bits
//   - ARGMAX ties (first index wins)
//   - Single element
//   - W1C, IRQ gating
//   - START while BUSY → SLVERR
//   - Writes to RO registers → SLVERR
// =============================================================================

`resetall
`timescale 1ns / 1ps

import soc_pkg::*;
import tb_pkg::*;
`include "tb_tasks.svh"

module tb_nda_unit;

  logic clk = 1'b0;
  logic aresetn;
  always #(tb_pkg::CLK_PERIOD_NS/2) clk = ~clk;

  `ifdef FSDB_DUMP
  initial begin
    $fsdbDumpfile("tb_nda_unit.fsdb");
    $fsdbDumpvars(0, tb_nda_unit);
  end
  `endif

  initial begin
    repeat (500_000) @(posedge clk);
    $display("TEST tb_nda_unit: FAIL (global timeout)");
    $fatal(1, "Global simulation timeout");
  end

  // --- BFM for CSR access ---
  axi_master_bfm bfm_if (.clk(clk), .aresetn(aresetn));

  // --- NDA read master → simple AXI RAM ---
  // The NDA only uses AR and R channels. We instantiate an axi_ram
  // and connect it as the NDA's read target.

  wire [11:0]  nda_arid;
  wire [31:0]  nda_araddr;
  wire [7:0]   nda_arlen;
  wire [2:0]   nda_arsize;
  wire [1:0]   nda_arburst;
  wire         nda_arvalid;
  wire         nda_arready;
  wire [11:0]  nda_rid;
  wire [31:0]  nda_rdata;
  wire [1:0]   nda_rresp;
  wire         nda_rlast;
  wire         nda_rvalid;
  wire         nda_rready;
  logic stall_ar = 0, stall_r = 0, inject_error = 0;
  wire ram_arready, ram_rvalid;
  wire [1:0] ram_rresp;
  wire [31:0] ram_rdata;
  wire [11:0] ram_rid;
  wire ram_rlast;
`ifdef NDA_PIPELINED
  localparam bit PIPELINED = 1;
`else
  localparam bit PIPELINED = 0;
`endif
  logic [31:0] queue_addr[0:7];
  logic [8:0] queue_left[0:7];
  logic [2:0] head = 0, tail = 0;
  logic [3:0] queued = 0;
  int delay_cycles = 0;
  bit simultaneous_seen = 0;
  assign nda_arready = !stall_ar && (PIPELINED ? queued < 2 : ram_arready);
  assign nda_rvalid = !stall_r && (PIPELINED ? (queued != 0 && delay_cycles == 0) : ram_rvalid);
  assign nda_rresp = inject_error ? 2'b10 : (PIPELINED ? 2'b00 : ram_rresp);
  assign nda_rlast = PIPELINED ? queue_left[head] == 1 : ram_rlast;
  assign nda_rid = PIPELINED ? 12'b0 : ram_rid;
  assign nda_rdata = PIPELINED ? u_ram.mem[queue_addr[head] >> 2] : ram_rdata;
  // An in-order slave with two queued bursts, independent AR/R channels.
  // Unlike axi_ram it can accept a new AR on the same edge as an RLAST.
  always @(posedge clk) begin
    if (!aresetn) begin
      head <= 0; tail <= 0; queued <= 0; delay_cycles <= 0;
      simultaneous_seen <= 0;
    end else if (PIPELINED) begin
      if (delay_cycles != 0) delay_cycles <= delay_cycles - 1;
      case ({nda_arvalid && nda_arready, nda_rvalid && nda_rready && nda_rlast})
        2'b10: queued <= queued + 1'b1;
        2'b01: queued <= queued - 1'b1;
        2'b11: simultaneous_seen <= 1;
        default: ;
      endcase
      if (nda_arvalid && nda_arready) begin
        queue_addr[tail] <= nda_araddr;
        queue_left[tail] <= {1'b0, nda_arlen} + 1'b1;
        tail <= tail + 1'b1;
        if (queued == 0) delay_cycles <= 8;
      end
      if (nda_rvalid && nda_rready) begin
        if (nda_rlast) head <= head + 1'b1;
        else begin
          queue_addr[head] <= queue_addr[head] + 4;
          queue_left[head] <= queue_left[head] - 1'b1;
        end
      end
    end
  end

  // Sideband
  wire nda_busy_w;
  wire nda_progress_w;
  logic wdt_abort_w = 1'b0; // explicitly injected hardware abort
  wire nda_irq_w;

  // --- DUT: NDA wrapper ---
  nda_wrapper #(
    .ID_WIDTH   (soc_pkg::AXI_ID_WIDTH),
    .ADDR_WIDTH (soc_pkg::AXI_ADDR_WIDTH),
    .BURST_LEN       (PIPELINED ? 2 : 4),
    .MAX_OUTSTANDING (2)
  ) dut (
    .clk           (clk),
    .aresetn       (aresetn),

    // CSR slave (from BFM)
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

    // Read master (to RAM)
    .m_axi_arid    (nda_arid),
    .m_axi_araddr  (nda_araddr),
    .m_axi_arlen   (nda_arlen),
    .m_axi_arsize  (nda_arsize),
    .m_axi_arburst (nda_arburst),
    .m_axi_arvalid (nda_arvalid),
    .m_axi_arready (nda_arready),
    .m_axi_rid     (nda_rid),
    .m_axi_rdata   (nda_rdata),
    .m_axi_rresp   (nda_rresp),
    .m_axi_rlast   (nda_rlast),
    .m_axi_rvalid  (nda_rvalid),
    .m_axi_rready  (nda_rready),

    .nda_busy_o    (nda_busy_w),
    .nda_progress_o(nda_progress_w),
    .wdt_abort_i   (wdt_abort_w),
    .irq_o         (nda_irq_w)
  );

  // --- Dummy RAM for NDA read master ---
  // We need a RAM that responds to the NDA's AR requests.
  // axi_ram handles both read and write; the NDA only reads, so we
  // tie off the write side.
  axi_ram #(
    .ADDR_WIDTH (32),
    .ID_WIDTH   (12),
    .MEM_BYTES  (4096) // 1 KiB — enough for test arrays
  ) u_ram (
    .clk           (clk),
    .aresetn       (aresetn),
    .s_axi_awid    (12'b0),
    .s_axi_awaddr  (32'b0),
    .s_axi_awlen   (8'd0),
    .s_axi_awsize  (3'd0),
    .s_axi_awburst (2'd0),
    .s_axi_awvalid (1'b0),
    .s_axi_awready (),
    .s_axi_wdata   (32'b0),
    .s_axi_wstrb   (4'b0),
    .s_axi_wlast   (1'b0),
    .s_axi_wvalid  (1'b0),
    .s_axi_wready  (),
    .s_axi_bid     (),
    .s_axi_bresp   (),
    .s_axi_bvalid  (),
    .s_axi_bready  (1'b1),
    .s_axi_arid    (nda_arid),
    .s_axi_araddr  (nda_araddr),
    .s_axi_arlen   (nda_arlen),
    .s_axi_arsize  (nda_arsize),
    .s_axi_arburst (nda_arburst),
    .s_axi_arvalid (nda_arvalid && !stall_ar && !PIPELINED),
    .s_axi_arready (ram_arready),
    .s_axi_rid     (ram_rid),
    .s_axi_rdata   (ram_rdata),
    .s_axi_rresp   (ram_rresp),
    .s_axi_rlast   (ram_rlast),
    .s_axi_rvalid  (ram_rvalid),
    .s_axi_rready  (nda_rready && !stall_r)
  );

  // --- Helper: write an array into RAM via BFM (using the RAM's write port) ---
  // Since the NDA's RAM is separate from the BFM, we need a second BFM
  // to write data into the RAM. But the RAM only has one slave port,
  // which is connected to the NDA master (read-only). We need to preload
  // the RAM before the NDA runs.
  //
  // Approach: use $readmemh or write via a separate path.
  // Simplest: add a second BFM connected to the RAM, switch mux.
  // But that adds complexity. Instead, we preload the RAM directly
  // by writing to its internal mem array from the testbench.
  //
  // The axi_ram module has `logic [31:0] mem [0:WORDS-1]` as an
  // internal array. We can access it hierarchically.

  // Helper task: preload RAM word
  task automatic ram_set(input int idx, input logic [31:0] val);
    u_ram.mem[idx] = val;
  endtask

  // Helper: wait for NDA done
  task automatic wait_nda_done;
    logic [31:0] status;
    logic [1:0]  resp_local;
    int t;
    t = 0;
    forever begin
      nda_read(bfm_if, soc_pkg::NDA_STATUS, status, resp_local);
      if (status[soc_pkg::NDA_STATUS_DONE]) break;
      @(posedge clk);
      t++;
      if (t > tb_pkg::POLL_MAX) begin
        $display("[FAIL] NDA timeout waiting for DONE");
        $fatal(1, "NDA completion timeout");
      end
    end
  endtask

  logic [1:0] resp;
  logic [31:0] rdata;
  logic [31:0] status;
  logic [31:0] result_lo, result_hi;
  int i;

  initial begin
    bfm_if.reset_master();
    soc_reset(aresetn);

    // === 1. Reset values ===
    nda_read(bfm_if, soc_pkg::NDA_CTRL, rdata, resp);
    check_equal("rst_ctrl", 32'h0, rdata);
    nda_read(bfm_if, soc_pkg::NDA_STATUS, rdata, resp);
    check_equal("rst_status", 32'h0, rdata);
    nda_read(bfm_if, soc_pkg::NDA_OP, rdata, resp);
    check_equal("rst_op", 32'h0, rdata);
    nda_read(bfm_if, soc_pkg::NDA_RESULT_LO, rdata, resp);
    check_equal("rst_result_lo", 32'h0, rdata);
    nda_read(bfm_if, soc_pkg::NDA_CYCLES, rdata, resp);
    check_equal("rst_cycles", 32'h0, rdata);
    check_equal("rst_irq", 32'h0, {31'b0, nda_irq_w});

    // === 2. Error: BAD_LEN (LEN=0) ===
    nda_write(bfm_if, soc_pkg::NDA_OP, soc_pkg::NDA_OP_SUM, resp);
    nda_write(bfm_if, soc_pkg::NDA_SRC_BASE, 32'h0000_0000, resp);
    nda_write(bfm_if, soc_pkg::NDA_LEN, 32'h0, resp);
    nda_write(bfm_if, soc_pkg::NDA_CTRL, 32'h1, resp); // START
    repeat (5) @(posedge clk); // let FSM process through CHECK and back to IDLE
    nda_read(bfm_if, soc_pkg::NDA_STATUS, status, resp);
    check_equal("bad_len_err", soc_pkg::NDA_ERR_BAD_LEN, status[7:4]);
    check_equal("bad_len_done", 32'h1, {31'b0, status[soc_pkg::NDA_STATUS_DONE]});
    check_equal("bad_len_err_flag", 32'h1, {31'b0, status[soc_pkg::NDA_STATUS_ERR]});
    check_equal("bad_len_busy", 32'h0, {31'b0, status[soc_pkg::NDA_STATUS_BUSY]});

    // Clear DONE/ERR
    nda_write(bfm_if, soc_pkg::NDA_STATUS, 32'h6, resp); // W1C bits 1+2

    // === 3. Error: BAD_OP (op=4, reserved) ===
    nda_write(bfm_if, soc_pkg::NDA_OP, 32'h4, resp);
    nda_write(bfm_if, soc_pkg::NDA_LEN, 32'h4, resp);
    nda_write(bfm_if, soc_pkg::NDA_CTRL, 32'h1, resp);
    repeat (5) @(posedge clk);
    nda_read(bfm_if, soc_pkg::NDA_STATUS, status, resp);
    check_equal("bad_op_code", soc_pkg::NDA_ERR_BAD_OP, status[7:4]);
    nda_write(bfm_if, soc_pkg::NDA_STATUS, 32'h6, resp);

    // === 4. Error: MISALIGNED (SRC_BASE not 4-byte aligned) ===
    nda_write(bfm_if, soc_pkg::NDA_OP, soc_pkg::NDA_OP_SUM, resp);
    nda_write(bfm_if, soc_pkg::NDA_SRC_BASE, 32'h0000_0002, resp);
    nda_write(bfm_if, soc_pkg::NDA_LEN, 32'h4, resp);
    nda_write(bfm_if, soc_pkg::NDA_CTRL, 32'h1, resp);
    repeat (5) @(posedge clk);
    nda_read(bfm_if, soc_pkg::NDA_STATUS, status, resp);
    check_equal("misalign_code", soc_pkg::NDA_ERR_MISALIGNED, status[7:4]);
    nda_write(bfm_if, soc_pkg::NDA_STATUS, 32'h6, resp);

    // === 5. Error: BAD_ADDR (SRC_BASE outside data window) ===
    nda_write(bfm_if, soc_pkg::NDA_SRC_BASE, 32'h2000_0000, resp);
    nda_write(bfm_if, soc_pkg::NDA_LEN, 32'h4, resp);
    nda_write(bfm_if, soc_pkg::NDA_CTRL, 32'h1, resp);
    repeat (5) @(posedge clk);
    nda_read(bfm_if, soc_pkg::NDA_STATUS, status, resp);
    check_equal("bad_addr_code", soc_pkg::NDA_ERR_BAD_ADDR, status[7:4]);
    nda_write(bfm_if, soc_pkg::NDA_STATUS, 32'h6, resp);

    // === 6. Error: BAD_RANGE (range exceeds data window) ===
    // Data window is 0x0 to 0x10000 (64 KiB). With 1 KiB RAM (0-0x400),
    // we use a smaller window for the unit test.
    // Actually NDA_DATA_BASE/END are from soc_pkg and cover 64 KiB.
    // The unit test RAM is only 1 KiB, but the NDA only checks the
    // address range against NDA_DATA_BASE/END, not actual RAM size.
    // BAD_RANGE: src_base=0, len = (0x10000/4)+1 = 16385
    nda_write(bfm_if, soc_pkg::NDA_SRC_BASE, 32'h0000_0000, resp);
    nda_write(bfm_if, soc_pkg::NDA_LEN, 32'h4001, resp); // 16385 elements = 65540 bytes > 64K
    nda_write(bfm_if, soc_pkg::NDA_CTRL, 32'h1, resp);
    repeat (5) @(posedge clk);
    nda_read(bfm_if, soc_pkg::NDA_STATUS, status, resp);
    check_equal("bad_range_code", soc_pkg::NDA_ERR_BAD_RANGE, status[7:4]);
    nda_write(bfm_if, soc_pkg::NDA_STATUS, 32'h6, resp);

    // === 7. Check order: LEN=0 and BAD_OP — LEN=0 should win ===
    nda_write(bfm_if, soc_pkg::NDA_OP, 32'h4, resp); // bad op
    nda_write(bfm_if, soc_pkg::NDA_LEN, 32'h0, resp); // bad len
    nda_write(bfm_if, soc_pkg::NDA_CTRL, 32'h1, resp);
    repeat (5) @(posedge clk);
    nda_read(bfm_if, soc_pkg::NDA_STATUS, status, resp);
    check_equal("check_order_len_first", soc_pkg::NDA_ERR_BAD_LEN, status[7:4]);
    nda_write(bfm_if, soc_pkg::NDA_STATUS, 32'h6, resp);

    // === 8. SUM operation on known array ===
    // Preload RAM: [10, 20, 30, 40] at address 0
    ram_set(0, 32'd10);
    ram_set(1, 32'd20);
    ram_set(2, 32'd30);
    ram_set(3, 32'd40);

    nda_write(bfm_if, soc_pkg::NDA_OP, soc_pkg::NDA_OP_SUM, resp);
    nda_write(bfm_if, soc_pkg::NDA_SRC_BASE, 32'h0000_0000, resp);
    nda_write(bfm_if, soc_pkg::NDA_LEN, 32'h4, resp);
    nda_write(bfm_if, soc_pkg::NDA_CTRL, 32'h1, resp);
    wait_nda_done;

    nda_read(bfm_if, soc_pkg::NDA_RESULT_LO, result_lo, resp);
    nda_read(bfm_if, soc_pkg::NDA_RESULT_HI, result_hi, resp);
    check_equal("sum_result_lo", 32'd100, result_lo); // 10+20+30+40=100
    check_equal("sum_result_hi", 32'h0, result_hi);
    nda_read(bfm_if, soc_pkg::NDA_STATUS, status, resp);
    check_equal("sum_no_err", 32'h0, {28'b0, status[7:4]});
    check_equal("sum_done", 32'h1, {31'b0, status[soc_pkg::NDA_STATUS_DONE]});
    nda_write(bfm_if, soc_pkg::NDA_STATUS, 32'h6, resp); // clear

    // === 9. SUM exceeding 32 bits ===
    // Use large values: 0x7FFFFFFF × 4 = 0x1FFFFFFFC
    ram_set(0, 32'h7FFF_FFFF);
    ram_set(1, 32'h7FFF_FFFF);
    ram_set(2, 32'h7FFF_FFFF);
    ram_set(3, 32'h7FFF_FFFF);

    nda_write(bfm_if, soc_pkg::NDA_OP, soc_pkg::NDA_OP_SUM, resp);
    nda_write(bfm_if, soc_pkg::NDA_SRC_BASE, 32'h0000_0000, resp);
    nda_write(bfm_if, soc_pkg::NDA_LEN, 32'h4, resp);
    nda_write(bfm_if, soc_pkg::NDA_CTRL, 32'h1, resp);
    wait_nda_done;

    nda_read(bfm_if, soc_pkg::NDA_RESULT_LO, result_lo, resp);
    nda_read(bfm_if, soc_pkg::NDA_RESULT_HI, result_hi, resp);
    check_equal("sum64_lo", 32'hFFFF_FFFC, result_lo);
    check_equal("sum64_hi", 32'h1, result_hi);
    nda_write(bfm_if, soc_pkg::NDA_STATUS, 32'h6, resp);

    // === 10. MIN operation with negatives ===
    ram_set(0, 32'h0000_000A);  // 10
    ram_set(1, 32'hFFFF_FFF6);  // -10
    ram_set(2, 32'h0000_00C8);  // 200
    ram_set(3, 32'h0000_0001);  // 1

    nda_write(bfm_if, soc_pkg::NDA_OP, soc_pkg::NDA_OP_MIN, resp);
    nda_write(bfm_if, soc_pkg::NDA_SRC_BASE, 32'h0000_0000, resp);
    nda_write(bfm_if, soc_pkg::NDA_LEN, 32'h4, resp);
    nda_write(bfm_if, soc_pkg::NDA_CTRL, 32'h1, resp);
    wait_nda_done;

    nda_read(bfm_if, soc_pkg::NDA_RESULT_LO, result_lo, resp);
    check_equal("min_result", 32'hFFFF_FFF6, result_lo); // -10
    nda_write(bfm_if, soc_pkg::NDA_STATUS, 32'h6, resp);

    // === 11. MAX operation ===
    nda_write(bfm_if, soc_pkg::NDA_OP, soc_pkg::NDA_OP_MAX, resp);
    nda_write(bfm_if, soc_pkg::NDA_CTRL, 32'h1, resp);
    wait_nda_done;

    nda_read(bfm_if, soc_pkg::NDA_RESULT_LO, result_lo, resp);
    check_equal("max_result", 32'h0000_00C8, result_lo); // 200
    nda_write(bfm_if, soc_pkg::NDA_STATUS, 32'h6, resp);

    // === 12. ARGMAX operation ===
    ram_set(0, 32'h0000_0005);  // idx 0, val 5
    ram_set(1, 32'h0000_000A);  // idx 1, val 10 (max)
    ram_set(2, 32'h0000_0003);  // idx 2, val 3
    ram_set(3, 32'h0000_0007);  // idx 3, val 7

    nda_write(bfm_if, soc_pkg::NDA_OP, soc_pkg::NDA_OP_ARGMAX, resp);
    nda_write(bfm_if, soc_pkg::NDA_SRC_BASE, 32'h0000_0000, resp);
    nda_write(bfm_if, soc_pkg::NDA_LEN, 32'h4, resp);
    nda_write(bfm_if, soc_pkg::NDA_CTRL, 32'h1, resp);
    wait_nda_done;

    nda_read(bfm_if, soc_pkg::NDA_RESULT_LO, result_lo, resp);
    nda_read(bfm_if, soc_pkg::NDA_RESULT_HI, result_hi, resp);
    check_equal("argmax_val", 32'h0000_000A, result_lo); // 10
    check_equal("argmax_idx", 32'h1, result_hi);          // index 1
    nda_write(bfm_if, soc_pkg::NDA_STATUS, 32'h6, resp);

    // === 13. ARGMAX ties: first index wins ===
    ram_set(0, 32'h0000_0064);  // idx 0, val 100 (first max)
    ram_set(1, 32'h0000_0064);  // idx 1, val 100 (tie)
    ram_set(2, 32'h0000_0032);  // idx 2, val 50
    ram_set(3, 32'h0000_0064);  // idx 3, val 100 (tie)

    nda_write(bfm_if, soc_pkg::NDA_OP, soc_pkg::NDA_OP_ARGMAX, resp);
    nda_write(bfm_if, soc_pkg::NDA_CTRL, 32'h1, resp);
    wait_nda_done;

    nda_read(bfm_if, soc_pkg::NDA_RESULT_HI, result_hi, resp);
    check_equal("argmax_tie_idx", 32'h0, result_hi); // first index
    nda_write(bfm_if, soc_pkg::NDA_STATUS, 32'h6, resp);

    // === 14. Single element ===
    ram_set(0, 32'h0000_002A);  // 42

    nda_write(bfm_if, soc_pkg::NDA_OP, soc_pkg::NDA_OP_SUM, resp);
    nda_write(bfm_if, soc_pkg::NDA_LEN, 32'h1, resp);
    nda_write(bfm_if, soc_pkg::NDA_CTRL, 32'h1, resp);
    wait_nda_done;

    nda_read(bfm_if, soc_pkg::NDA_RESULT_LO, result_lo, resp);
    check_equal("single_sum", 32'h2A, result_lo);
    nda_write(bfm_if, soc_pkg::NDA_STATUS, 32'h6, resp);

    // === 15. CYCLES register nonzero ===
    nda_read(bfm_if, soc_pkg::NDA_CYCLES, rdata, resp);
    check_equal("cycles_nonzero", 32'h1, {31'b0, (rdata != 0)});

    // === 16. IRQ enable + level behavior ===
    nda_write(bfm_if, soc_pkg::NDA_CTRL, 32'h4, resp); // IRQ_EN=1
    nda_write(bfm_if, soc_pkg::NDA_OP, soc_pkg::NDA_OP_SUM, resp);
    nda_write(bfm_if, soc_pkg::NDA_LEN, 32'h1, resp);
    nda_write(bfm_if, soc_pkg::NDA_CTRL, 32'h5, resp); // IRQ_EN + START
    wait_nda_done;
    check_equal("irq_asserted", 32'h1, {31'b0, nda_irq_w});
    // Clear DONE/ERR → IRQ drops
    nda_write(bfm_if, soc_pkg::NDA_STATUS, 32'h6, resp);
    #1; // let IRQ settle
    check_equal("irq_drops", 32'h0, {31'b0, nda_irq_w});

    // === 17. START while BUSY → SLVERR ===
    // Start a longer operation, then try to START again
    for (i = 0; i < 16; i++) ram_set(i, 32'd1);
    nda_write(bfm_if, soc_pkg::NDA_OP, soc_pkg::NDA_OP_SUM, resp);
    nda_write(bfm_if, soc_pkg::NDA_SRC_BASE, 32'h0000_0000, resp);
    nda_write(bfm_if, soc_pkg::NDA_LEN, 32'h10, resp);
    nda_write(bfm_if, soc_pkg::NDA_CTRL, 32'h1, resp); // START
    @(posedge clk); // NDA is now BUSY
    nda_write(bfm_if, soc_pkg::NDA_CTRL, 32'h1, resp); // START while BUSY
    // resp should be SLVERR (2'b10)
    check_equal("start_busy_slverr", 32'h2, {30'b0, resp});
    wait_nda_done;
    nda_write(bfm_if, soc_pkg::NDA_STATUS, 32'h6, resp);

    // === 18. Write to RO register → SLVERR ===
    nda_write(bfm_if, soc_pkg::NDA_RESULT_LO, 32'h1234, resp);
    check_equal("ro_write_slverr", 32'h2, {30'b0, resp});

    // === 19. Read undefined offset → SLVERR ===
    nda_read(bfm_if, 32'h20, rdata, resp); // offset 0x20 is undefined
    check_equal("undef_read_slverr", 32'h2, {30'b0, resp});

    // Signed accumulation including a negative final beat, across bursts.
    for (i = 0; i < 65; i++) ram_set(i, -3);
    nda_write(bfm_if, NDA_LEN, 65, resp);
    nda_write(bfm_if, NDA_CTRL, 1, resp);
    wait_nda_done;
    nda_read(bfm_if, NDA_RESULT_LO, rdata, resp);
    check_equal("negative_multiburst_lo", -195, rdata);
    nda_read(bfm_if, NDA_RESULT_HI, rdata, resp);
    check_equal("negative_multiburst_hi", 32'hffffffff, rdata);

    // Idle abort is a no-op, never a delayed abort of the next job.
    nda_write(bfm_if, NDA_CTRL, 2, resp);
    nda_write(bfm_if, NDA_CTRL, 1, resp);
    wait_nda_done;
    nda_read(bfm_if, NDA_STATUS, rdata, resp);
    check_equal("idle_abort_not_latched", 2, rdata);
    nda_write(bfm_if, NDA_LEN, 32'hffffffff, resp);
    nda_write(bfm_if, NDA_CTRL, 1, resp);
    wait_nda_done;
    nda_read(bfm_if, NDA_STATUS, rdata, resp);
    check_equal("huge_length_range_check", 32'h56, rdata);
    nda_write(bfm_if, NDA_LEN, 65, resp);
    nda_write(bfm_if, NDA_CTRL, 1, resp);
    wait_nda_done;

    // A zero-strobe START must not clear DONE or generate any work.
    bfm_if.write(NDA_BASE + NDA_CTRL, 1, 0, resp);
    nda_read(bfm_if, NDA_STATUS, rdata, resp);
    check_equal("zero_strobe_no_start", 2, rdata);

    // Abort with an unaccepted AR: VALID/address must persist to acceptance.
    stall_ar = 1;
    nda_write(bfm_if, NDA_CTRL, 1, resp);
    wait (nda_arvalid);
    nda_write(bfm_if, NDA_CTRL, 2, resp);
    repeat (5) @(negedge clk);
    check_equal("pending_ar_held_on_abort", 1, nda_arvalid);
    check_equal("pending_ar_address_stable", 0, nda_araddr);
    stall_ar = 0;
    wait_nda_done;
    nda_read(bfm_if, NDA_STATUS, rdata, resp);
    check_equal("pending_ar_abort_drained", 32'h76, rdata);

    // Inject SLVERR on accepted read data, drain, then restart cleanly.
    inject_error = 1;
    nda_write(bfm_if, NDA_CTRL, 1, resp);
    wait_nda_done;
    nda_read(bfm_if, NDA_STATUS, rdata, resp);
    check_equal("read_bus_error", 32'h66, rdata);
    inject_error = 0;
    nda_write(bfm_if, NDA_CTRL, 1, resp);
    wait_nda_done;
    nda_read(bfm_if, NDA_RESULT_LO, rdata, resp);
    check_equal("restart_after_error", -195, rdata);
    nda_read(bfm_if, NDA_STATUS, rdata, resp);
    check_equal("restart_status", 2, rdata);
    // Completion IRQ must wait for drain, never expose an unfinished error.
    stall_r = 1;
    nda_write(bfm_if, NDA_CTRL, 5, resp);
    wait (dut.outstanding != 0);
    @(negedge clk); wdt_abort_w = 1;
    @(negedge clk); wdt_abort_w = 0;
    repeat (5) @(negedge clk);
    check_equal("drain_still_busy", 1, nda_busy_w);
    check_equal("no_premature_error_irq", 0, nda_irq_w);
    stall_r = 0;
    wait_nda_done;
    nda_read(bfm_if, NDA_STATUS, rdata, resp);
    check_equal("hardware_abort_completed", 32'h76, rdata);
    check_equal("error_irq_after_drain", 1, nda_irq_w);
    if (PIPELINED) check_equal("simultaneous_ar_rlast_exercised", 1, simultaneous_seen);
    report_results("tb_nda_unit");
  end

endmodule

`resetall
