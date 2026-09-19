// =============================================================================
// tb_core_uart.sv — Middle-layer + SW UART test on honours_soc
//
// Modes (selected by +SW_HEX):
//   middle (no +SW_HEX): SB-routed UART via forced s03 -> xbar -> m05.
//     Proves decode + routing SW will use, without toolchain/boot image.
//   sw (+SW_HEX=<hex>):  VeeR executes the image from m00 true RAM; TB only
//     monitors uart_tx for the expected string. No forces on m05/s03.
//
// DUT  : honours_soc (m00 = axi_true_mem, NOP init or hex image)
// Tool : VCS + Verdi (FSDB)
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_core_uart;

// ---------------------------------------------------------------------------
// Parameters (match honours_soc memory map + uart_tasks model)
// ---------------------------------------------------------------------------
localparam CLK_PERIOD    = 10;
localparam EXTINT_W      = 31;
localparam TIMEOUT_CYC   = 200_000;
localparam GLOBAL_CYCLES = 5_000_000;

localparam UART_BASE     = 32'h2000_3000;
localparam ADDR_RBR_THR  = 5'h00;
localparam ADDR_IER      = 5'h04;
localparam ADDR_BAUD     = 5'h08;
localparam ADDR_LCR      = 5'h0C;
localparam ADDR_LSR      = 5'h14;

localparam LSR_DATA_READY = 0;
localparam LSR_THRE       = 5;
localparam LSR_TEMT       = 6;

localparam LCR_8N1       = 32'h0000_0003;
localparam BAUD_DIV_SIM  = 32'd100;
localparam RESERVED_ADDR = 32'h2000_4000;

// ---------------------------------------------------------------------------
// Clock and reset (rst_n driven by reset_soc())
// ---------------------------------------------------------------------------
logic clk   = 1'b0;
logic rst_n = 1'b0;

always #(CLK_PERIOD/2) clk = ~clk;

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
logic              uart_rx;
logic              uart_tx;
logic              jtag_tck  = 1'b0;
logic              jtag_tms  = 1'b1;
logic              jtag_tdi  = 1'b0;
logic              jtag_trst_n;
logic              jtag_tdo;
logic              jtag_tdo_en;
logic [EXTINT_W:1] extintsrc_req = '0;

assign jtag_trst_n = rst_n;
assign uart_rx = uart_tx;   // loopback for middle mode (harmless in SW mode)

// ---------------------------------------------------------------------------
// s03 hook drivers (proper regs, NO force — connected to dut ports)
// ---------------------------------------------------------------------------
logic [7:0]  tb_s03_awid    = '0;
logic [31:0] tb_s03_awaddr  = '0;
logic [7:0]  tb_s03_awlen   = '0;
logic [2:0]  tb_s03_awsize  = 3'b010;
logic [1:0]  tb_s03_awburst = 2'b01;
logic        tb_s03_awvalid = 1'b0;
wire         tb_s03_awready;
logic [31:0] tb_s03_wdata   = '0;
logic [3:0]  tb_s03_wstrb   = 4'hF;
logic        tb_s03_wlast   = 1'b1;
logic        tb_s03_wvalid  = 1'b0;
wire         tb_s03_wready;
wire [7:0]   tb_s03_bid;
wire [1:0]   tb_s03_bresp;
wire         tb_s03_bvalid;
logic        tb_s03_bready  = 1'b0;
logic [7:0]  tb_s03_arid    = '0;
logic [31:0] tb_s03_araddr  = '0;
logic [7:0]  tb_s03_arlen   = '0;
logic [2:0]  tb_s03_arsize  = 3'b010;
logic [1:0]  tb_s03_arburst = 2'b01;
logic        tb_s03_arvalid = 1'b0;
wire         tb_s03_arready;
wire [7:0]   tb_s03_rid;
wire [31:0]  tb_s03_rdata;
wire [1:0]   tb_s03_rresp;
wire         tb_s03_rlast;
wire         tb_s03_rvalid;
logic        tb_s03_rready  = 1'b0;

honours_soc dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .uart_rx        (uart_rx),
    .uart_tx        (uart_tx),
    .jtag_tck       (jtag_tck),
    .jtag_tms       (jtag_tms),
    .jtag_tdi       (jtag_tdi),
    .jtag_trst_n    (jtag_trst_n),
    .jtag_tdo       (jtag_tdo),
    .jtag_tdo_en    (jtag_tdo_en),
    .extintsrc_req  (extintsrc_req),
    .tb_s03_awid    (tb_s03_awid),
    .tb_s03_awaddr  (tb_s03_awaddr),
    .tb_s03_awlen   (tb_s03_awlen),
    .tb_s03_awsize  (tb_s03_awsize),
    .tb_s03_awburst (tb_s03_awburst),
    .tb_s03_awvalid (tb_s03_awvalid),
    .tb_s03_awready (tb_s03_awready),
    .tb_s03_wdata   (tb_s03_wdata),
    .tb_s03_wstrb   (tb_s03_wstrb),
    .tb_s03_wlast   (tb_s03_wlast),
    .tb_s03_wvalid  (tb_s03_wvalid),
    .tb_s03_wready  (tb_s03_wready),
    .tb_s03_bid     (tb_s03_bid),
    .tb_s03_bresp   (tb_s03_bresp),
    .tb_s03_bvalid  (tb_s03_bvalid),
    .tb_s03_bready  (tb_s03_bready),
    .tb_s03_arid    (tb_s03_arid),
    .tb_s03_araddr  (tb_s03_araddr),
    .tb_s03_arlen   (tb_s03_arlen),
    .tb_s03_arsize  (tb_s03_arsize),
    .tb_s03_arburst (tb_s03_arburst),
    .tb_s03_arvalid (tb_s03_arvalid),
    .tb_s03_arready (tb_s03_arready),
    .tb_s03_rid     (tb_s03_rid),
    .tb_s03_rdata   (tb_s03_rdata),
    .tb_s03_rresp   (tb_s03_rresp),
    .tb_s03_rlast   (tb_s03_rlast),
    .tb_s03_rvalid  (tb_s03_rvalid),
    .tb_s03_rready  (tb_s03_rready)
);

// ---------------------------------------------------------------------------
// Scoreboard + shared tasks
// ---------------------------------------------------------------------------
int pass_count = 0;
int fail_count = 0;

task check(input string name, input bit ok);
    if (ok) begin
        $display("[TB] PASS: %s", name);
        pass_count++;
    end else begin
        $error("[TB] FAIL: %s", name);
        fail_count++;
    end
endtask

`include "common/soc_tasks.sv"
`include "common/axi_tasks.sv"
`include "common/uart_tasks.sv"
`include "common/mem_tasks.sv"

// ---------------------------------------------------------------------------
// Watchdog + waves
// ---------------------------------------------------------------------------
initial begin
    repeat (GLOBAL_CYCLES) @(posedge clk);
    $error("[TB] GLOBAL TIMEOUT");
    $finish;
end

initial begin
    $fsdbDumpfile("tb_core_uart.fsdb");
    $fsdbDumpvars(0, tb_core_uart);
    $fsdbDumpMDA();
end

// ---------------------------------------------------------------------------
// Stimulus
// ---------------------------------------------------------------------------
initial begin
    string hex_path;
    bit    sw_mode;
    sw_mode = $value$plusargs("SW_HEX=%s", hex_path);

    reset_soc();
    load_program();
    start_soc();
    check("xbar FSM IDLE after reset",
        dut.u_xbar.axi_interconnect_inst.state_reg === 3'd0);
    wait_for_core();

    if (sw_mode) begin
        // ---- SW mode: CPU drives UART, TB only monitors ----
        $display("[TB] SW mode, image: %s", hex_path);
        // uart_test sends "Hi\n" (see sw/uart_test/main.c)
        uart_expect_string("Hi\n");
        check("SW UART string received", fail_count == 0);
    end else begin
        // ---- Middle mode: SB-routed UART through xbar ----
        int fails_before;
        $display("[TB] Middle mode: s03 -> xbar -> m05 UART");
        fails_before = fail_count;
        uart_xbar_write(UART_BASE + 32'(ADDR_LCR), LCR_8N1);
        uart_xbar_write(UART_BASE + 32'(ADDR_IER), 32'h0000_0001);
        uart_xbar_write(UART_BASE + 32'(ADDR_LCR), 32'h0000_0083);
        uart_xbar_write(UART_BASE + 32'(ADDR_BAUD), BAUD_DIV_SIM);
        uart_xbar_write(UART_BASE + 32'(ADDR_LCR), LCR_8N1);
        check("UART config writes OKAY", fail_count == fails_before);
        uart_xbar_write(UART_BASE + 32'(ADDR_RBR_THR), 32'h0000_00A5);
        uart_xbar_poll_lsr(LSR_TEMT, "TEMT");
        uart_xbar_poll_lsr(LSR_DATA_READY, "DATA_READY(flush)");
        uart_xbar_drain();
        uart_xbar_write(UART_BASE + 32'(ADDR_RBR_THR), 32'h0000_0037);
        uart_xbar_poll_lsr(LSR_DATA_READY, "DATA_READY");
        begin
            logic [31:0] rbr;
            uart_xbar_read(UART_BASE + 32'(ADDR_RBR_THR), rbr);
            check("UART loopback byte 0x37", rbr[7:0] === 8'h37);
        end
        s03_expect_decerr(RESERVED_ADDR);
    end

    stop_soc();
end

endmodule

`default_nettype wire
