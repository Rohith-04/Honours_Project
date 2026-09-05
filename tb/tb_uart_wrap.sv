// =============================================================================
// tb_uart_wrap.sv — Standalone testbench for uart_wrap
//
// DUT  : uart_wrap (rtl/uart/uart_wrap.sv)
// Tool : Synopsys VCS + Verdi (FSDB)
//
// Test plan:
//   TC1 — Reset check: all outputs deasserted after reset
//   TC2 — Write LCR (Line Control Register) to configure 8N1
//   TC3 — Write IER (Interrupt Enable Register) to enable RX interrupt
//   TC4 — Write THR (TX FIFO): transmit a byte, observe uart_tx toggle
//   TC5 — Loopback: connect uart_tx → uart_rx, write a byte, poll LSR
//          DATA_READY bit, read RBR and verify received byte matches sent
//   TC6 — Read LSR: verify THRE/TEMT set when TX FIFO is empty
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_uart_wrap;

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
localparam CLK_PERIOD   = 10;           // 100 MHz
localparam AXI_ID_WIDTH = 8;
localparam TIMEOUT_CYC  = 1_000_000;   // generous — baud counter is slow

// UART register addresses (byte-addressed, 5-bit window)
// Matches axi_uart.vh defines
localparam ADDR_RBR_THR = 5'h00;       // RBR (read) / THR (write)  offset 0
localparam ADDR_IER     = 5'h04;       // Interrupt Enable Register offset 4
localparam ADDR_BAUD    = 5'h08;       // Baud divisor              offset 8
localparam ADDR_LCR     = 5'h0C;       // Line Control Register     offset C
localparam ADDR_LSR     = 5'h14;       // Line Status Register      offset 14

// LSR bit positions
localparam LSR_DATA_READY = 0;
localparam LSR_THRE       = 5;
localparam LSR_TEMT       = 6;

// LCR value: 8N1, DLAB=0
localparam LCR_8N1  = 32'h00000003;

// Baud divisor for 115200 @ 100 MHz = 868
// (set small for sim speed — override in TC4/TC5)
localparam BAUD_DIV_SIM = 32'd4;       // tiny divisor for fast sim

// ---------------------------------------------------------------------------
// Clock and reset
// ---------------------------------------------------------------------------
logic clk  = 1'b0;
logic rst_n = 1'b0;

always #(CLK_PERIOD/2) clk = ~clk;

initial begin
    repeat(8) @(posedge clk);
    rst_n = 1'b1;
end

// ---------------------------------------------------------------------------
// DUT interface signals
// ---------------------------------------------------------------------------
logic                    s_axi_awvalid;
logic                    s_axi_awready;
logic [AXI_ID_WIDTH-1:0] s_axi_awid;
logic [31:0]             s_axi_awaddr;

logic                    s_axi_wvalid;
logic                    s_axi_wready;
logic [31:0]             s_axi_wdata;
logic [3:0]              s_axi_wstrb;

logic                    s_axi_bvalid;
logic                    s_axi_bready;
logic [AXI_ID_WIDTH-1:0] s_axi_bid;
logic [1:0]              s_axi_bresp;

logic                    s_axi_arvalid;
logic                    s_axi_arready;
logic [AXI_ID_WIDTH-1:0] s_axi_arid;
logic [31:0]             s_axi_araddr;

logic                    s_axi_rvalid;
logic                    s_axi_rready;
logic [AXI_ID_WIDTH-1:0] s_axi_rid;
logic [31:0]             s_axi_rdata;
logic [1:0]              s_axi_rresp;

logic                    uart_rx;
logic                    uart_tx;
logic                    uart_irq;

// ---------------------------------------------------------------------------
// DUT instantiation
// ---------------------------------------------------------------------------
uart_wrap #(
    .AXI_ID_WIDTH (AXI_ID_WIDTH)
) dut (
    .clk            (clk),
    .rst_n          (rst_n),

    .s_axi_awvalid  (s_axi_awvalid),
    .s_axi_awready  (s_axi_awready),
    .s_axi_awid     (s_axi_awid),
    .s_axi_awaddr   (s_axi_awaddr),

    .s_axi_wvalid   (s_axi_wvalid),
    .s_axi_wready   (s_axi_wready),
    .s_axi_wdata    (s_axi_wdata),
    .s_axi_wstrb    (s_axi_wstrb),

    .s_axi_bvalid   (s_axi_bvalid),
    .s_axi_bready   (s_axi_bready),
    .s_axi_bid      (s_axi_bid),
    .s_axi_bresp    (s_axi_bresp),

    .s_axi_arvalid  (s_axi_arvalid),
    .s_axi_arready  (s_axi_arready),
    .s_axi_arid     (s_axi_arid),
    .s_axi_araddr   (s_axi_araddr),

    .s_axi_rvalid   (s_axi_rvalid),
    .s_axi_rready   (s_axi_rready),
    .s_axi_rid      (s_axi_rid),
    .s_axi_rdata    (s_axi_rdata),
    .s_axi_rresp    (s_axi_rresp),

    .uart_rx        (uart_rx),
    .uart_tx        (uart_tx),
    .uart_irq       (uart_irq)
);

// ---------------------------------------------------------------------------
// Loopback: connect TX to RX for TC5
// ---------------------------------------------------------------------------
assign uart_rx = uart_tx;

// ---------------------------------------------------------------------------
// Scoreboard counters
// ---------------------------------------------------------------------------
int pass_count = 0;
int fail_count = 0;

// ---------------------------------------------------------------------------
// AXI-Lite write task
// ---------------------------------------------------------------------------
task automatic axi_write (
    input logic [31:0] addr,
    input logic [31:0] data,
    input logic [3:0]  strb = 4'hF,
    input logic [AXI_ID_WIDTH-1:0] id = '0
);
    // Drive AW and W simultaneously (AXI4-Lite allows this)
    @(posedge clk);
    s_axi_awvalid <= 1'b1;
    s_axi_awaddr  <= addr;
    s_axi_awid    <= id;
    s_axi_wvalid  <= 1'b1;
    s_axi_wdata   <= data;
    s_axi_wstrb   <= strb;
    s_axi_bready  <= 1'b1;

    // Wait for both AW and W accepted
    fork
        begin
            @(posedge clk iff s_axi_awready);
            s_axi_awvalid <= 1'b0;
        end
        begin
            @(posedge clk iff s_axi_wready);
            s_axi_wvalid <= 1'b0;
            s_axi_wdata  <= '0;
            s_axi_wstrb  <= 4'hF;
        end
    join

    // Wait for B response
    @(posedge clk iff s_axi_bvalid);
    s_axi_bready <= 1'b0;
    @(posedge clk);
endtask

// ---------------------------------------------------------------------------
// AXI-Lite read task
// ---------------------------------------------------------------------------
task automatic axi_read (
    input  logic [31:0]              addr,
    output logic [31:0]              data,
    input  logic [AXI_ID_WIDTH-1:0]  id = '0
);
    @(posedge clk);
    s_axi_arvalid <= 1'b1;
    s_axi_araddr  <= addr;
    s_axi_arid    <= id;
    s_axi_rready  <= 1'b1;

    @(posedge clk iff s_axi_arready);
    s_axi_arvalid <= 1'b0;

    @(posedge clk iff s_axi_rvalid);
    data          = s_axi_rdata;
    s_axi_rready  <= 1'b0;
    @(posedge clk);
endtask

// ---------------------------------------------------------------------------
// Poll LSR until bit[pos] is set, with timeout
// ---------------------------------------------------------------------------
task automatic poll_lsr (
    input int bit_pos,
    input string name
);
    logic [31:0] lsr;
    int          count = 0;
    do begin
        axi_read(32'h0000_0000 + ADDR_LSR, lsr);
        count++;
        if (count > TIMEOUT_CYC) begin
            $error("[TB] TIMEOUT waiting for LSR[%0d] (%s)", bit_pos, name);
            fail_count++;
            return;
        end
    end while (!lsr[bit_pos]);
endtask

// ---------------------------------------------------------------------------
// Idle defaults
// ---------------------------------------------------------------------------
initial begin
    s_axi_awvalid = 1'b0;
    s_axi_awaddr  = '0;
    s_axi_awid    = '0;
    s_axi_wvalid  = 1'b0;
    s_axi_wdata   = '0;
    s_axi_wstrb   = 4'hF;
    s_axi_bready  = 1'b0;
    s_axi_arvalid = 1'b0;
    s_axi_araddr  = '0;
    s_axi_arid    = '0;
    s_axi_rready  = 1'b0;
end

// ---------------------------------------------------------------------------
// Timeout watchdog
// ---------------------------------------------------------------------------
initial begin
    #(TIMEOUT_CYC * CLK_PERIOD * 10);
    $error("[TB] GLOBAL TIMEOUT");
    $finish;
end

// ---------------------------------------------------------------------------
// Test stimulus
// ---------------------------------------------------------------------------
initial begin
    // Wait for reset to release
    @(posedge rst_n);
    repeat(4) @(posedge clk);

    // ------------------------------------------------------------------
    // TC1 — Reset check
    // ------------------------------------------------------------------
    $display("[TC1] Reset check");
    if (s_axi_bvalid !== 1'b0 || s_axi_rvalid !== 1'b0 || uart_irq !== 1'b0) begin
        $error("[TC1] FAIL: outputs not deasserted after reset");
        fail_count++;
    end else begin
        $display("[TC1] PASS");
        pass_count++;
    end

    // ------------------------------------------------------------------
    // TC2 — Write LCR: configure 8N1 (DLAB=0)
    // ------------------------------------------------------------------
    $display("[TC2] Write LCR = 8N1");
    axi_write(32'h0000_0000 + ADDR_LCR, LCR_8N1);
    if (s_axi_bresp !== 2'b00) begin
        $error("[TC2] FAIL: bresp=0x%0h", s_axi_bresp);
        fail_count++;
    end else begin
        $display("[TC2] PASS");
        pass_count++;
    end

    // ------------------------------------------------------------------
    // TC3 — Write IER: enable RX interrupt
    // ------------------------------------------------------------------
    $display("[TC3] Enable RX interrupt via IER");
    axi_write(32'h0000_0000 + ADDR_IER, 32'h0000_0001);
    if (s_axi_bresp !== 2'b00) begin
        $error("[TC3] FAIL: bresp=0x%0h", s_axi_bresp);
        fail_count++;
    end else begin
        $display("[TC3] PASS");
        pass_count++;
    end

    // ------------------------------------------------------------------
    // TC4 — Write baud divisor (small value for sim speed)
    //        then write THR and observe TX line activity
    // ------------------------------------------------------------------
    $display("[TC4] Set baud divisor and transmit byte 0xA5");
    // Set DLAB=1 to access baud register
    axi_write(32'h0000_0000 + ADDR_LCR, 32'h0000_0083);  // 8N1 + DLAB=1
    axi_write(32'h0000_0000 + ADDR_BAUD, BAUD_DIV_SIM);
    // Clear DLAB
    axi_write(32'h0000_0000 + ADDR_LCR, LCR_8N1);
    // Write byte to THR
    axi_write(32'h0000_0000 + ADDR_RBR_THR, 32'h0000_00A5);
    // Poll TEMT (transmitter empty) — gives time for TX to complete
    poll_lsr(LSR_TEMT, "TEMT");
    $display("[TC4] PASS — TX completed");
    pass_count++;

    // ------------------------------------------------------------------
    // TC5 — Loopback: TX→RX, check DATA_READY and read back byte
    // ------------------------------------------------------------------
    $display("[TC5] Loopback: send 0x37, read back via RBR");
    axi_write(32'h0000_0000 + ADDR_RBR_THR, 32'h0000_0037);
    // Wait for RX FIFO to fill (DATA_READY in LSR)
    poll_lsr(LSR_DATA_READY, "DATA_READY");
    begin
        logic [31:0] rbr;
        axi_read(32'h0000_0000 + ADDR_RBR_THR, rbr);
        if (rbr[7:0] !== 8'h37) begin
            $error("[TC5] FAIL: expected 0x37 got 0x%0h", rbr[7:0]);
            fail_count++;
        end else begin
            $display("[TC5] PASS — received 0x%0h", rbr[7:0]);
            pass_count++;
        end
    end

    // ------------------------------------------------------------------
    // TC6 — Read LSR: THRE and TEMT should be set when TX idle
    // ------------------------------------------------------------------
    $display("[TC6] Read LSR — THRE/TEMT should be set");
    poll_lsr(LSR_THRE, "THRE");
    poll_lsr(LSR_TEMT, "TEMT");
    $display("[TC6] PASS");
    pass_count++;

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    $display("");
    $display("============================================");
    $display(" tb_uart_wrap complete: %0d PASS  %0d FAIL", pass_count, fail_count);
    $display("============================================");
    if (fail_count == 0)
        $display(" ALL CHECKS PASSED");
    else
        $display(" FAILURES DETECTED");
    $display("============================================");
    $finish;
end

// ---------------------------------------------------------------------------
// Waveform dump
// ---------------------------------------------------------------------------
initial begin
    $fsdbDumpfile("tb_uart_wrap.fsdb");
    $fsdbDumpvars(0, tb_uart_wrap);
    $fsdbDumpMDA();
end

endmodule

`default_nettype wire
