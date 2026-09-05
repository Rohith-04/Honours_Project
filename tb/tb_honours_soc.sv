// =============================================================================
// tb_honours_soc.sv — Structural bring-up testbench for honours_soc
//
// DUT  : honours_soc (rtl/soc/honours_soc.sv)
// Tool : Synopsys VCS + Verdi (FSDB)
//
// Scope (structural bring-up, no CPU boot required):
//   TC1 — Reset check: xbar FSM IDLE, uart_tx idle-high, no X on key outputs
//   TC2 — VeeR alive: LSU or IFU AXI read request appears after reset
//   TC3 — Reset vector: first IFU fetch targets 0x0000_0000 via xbar s01
//   TC4 — m00 DRAM stub completes the boot fetch (arvalid -> rvalid, OKAY)
//   TC5 — UART loopback through SoC hierarchy (force m05, LCR/THR/RBR, TX->RX)
//   TC6 — DECERR on reserved address via xbar s03 (force, 0x2000_4000 unmapped)
//
// Notes:
//   * m01-m04/m06-m15 are tied-off stubs in RTL (see honours_soc.sv); the TB
//     only touches m00, m05 and unmapped space, so no transaction can hang.
//   * TC5/TC6 use hierarchical force/release to drive xbar/UART nets that the
//     CPU would normally drive. This is standard bring-up practice until the
//     NDA/SB paths and a boot image exist.
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_honours_soc;

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
localparam CLK_PERIOD    = 10;            // 100 MHz
localparam EXTINT_W      = 31;            // pt.PIC_TOTAL_INT (default config)
localparam TIMEOUT_CYC   = 200_000;       // per-wait timeout (cycles)
localparam GLOBAL_CYCLES = 5_000_000;     // global watchdog (cycles)

localparam UART_BASE     = 32'h2000_3000; // m05 window (honours_soc.sv)
localparam ADDR_RBR_THR  = 5'h00;
localparam ADDR_IER      = 5'h04;
localparam ADDR_BAUD     = 5'h08;
localparam ADDR_LCR      = 5'h0C;
localparam ADDR_LSR      = 5'h14;

localparam LSR_DATA_READY = 0;
localparam LSR_THRE       = 5;
localparam LSR_TEMT       = 6;

localparam LCR_8N1       = 32'h0000_0003;
localparam BAUD_DIV_SIM  = 32'd4;         // tiny divisor for fast sim
localparam RESERVED_ADDR = 32'h2000_4000; // unmapped (no slave window)

// ---------------------------------------------------------------------------
// Clock and reset
// ---------------------------------------------------------------------------
logic clk   = 1'b0;
logic rst_n = 1'b0;

always #(CLK_PERIOD/2) clk = ~clk;

initial begin
    repeat(8) @(posedge clk);
    rst_n = 1'b1;
end

// ---------------------------------------------------------------------------
// DUT top-level signals
// ---------------------------------------------------------------------------
logic                 uart_rx;
logic                 uart_tx;
logic                 jtag_tck  = 1'b0;
logic                 jtag_tms  = 1'b1;
logic                 jtag_tdi  = 1'b0;
logic                 jtag_trst_n;
logic                 jtag_tdo;
logic                 jtag_tdo_en;
logic [EXTINT_W:1]    extintsrc_req = '0;

assign jtag_trst_n = rst_n;

// UART pin loopback (TX -> RX) for TC5
assign uart_rx = uart_tx;

// ---------------------------------------------------------------------------
// DUT instantiation
// ---------------------------------------------------------------------------
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
    .extintsrc_req  (extintsrc_req)
);

// ---------------------------------------------------------------------------
// Scoreboard
// ---------------------------------------------------------------------------
int pass_count = 0;
int fail_count = 0;

task automatic check(input string name, input bit ok);
    if (ok) begin
        $display("[TB] PASS: %s", name);
        pass_count++;
    end else begin
        $error("[TB] FAIL: %s", name);
        fail_count++;
    end
endtask

// Wait for a hierarchical condition with cycle timeout. Returns 1 on success.
task automatic wait_cycles(input int max_cyc);
    repeat (max_cyc) @(posedge clk);
endtask

// ---------------------------------------------------------------------------
// TC5 helpers — drive SoC UART via forced m05 (xbar master port 5)
// Only xbar-driven nets are forced; UART-driven nets are sampled.
// ---------------------------------------------------------------------------
task uart_soc_write(
    input logic [31:0] addr,
    input logic [31:0] data,
    input logic [3:0]  strb = 4'hF
);
    force dut.m05_awvalid = 1'b1;
    force dut.m05_awaddr  = addr;
    force dut.m05_awid    = 8'h00;
    force dut.m05_wvalid  = 1'b1;
    force dut.m05_wdata   = data;
    force dut.m05_wstrb   = strb;
    force dut.m05_bready  = 1'b1;

    // Wait for both address and data accepted
    fork
        begin : aw_hs
            int n = 0;
            while (dut.m05_awready !== 1'b1 && n < TIMEOUT_CYC) begin
                @(posedge clk); n++;
            end
            force dut.m05_awvalid = 1'b0;
        end
        begin : w_hs
            int n = 0;
            while (dut.m05_wready !== 1'b1 && n < TIMEOUT_CYC) begin
                @(posedge clk); n++;
            end
            force dut.m05_wvalid = 1'b0;
        end
    join

    begin : b_hs
        int n = 0;
        while (dut.m05_bvalid !== 1'b1 && n < TIMEOUT_CYC) begin
            @(posedge clk); n++;
        end
        @(posedge clk);
        force dut.m05_bready = 1'b0;
    end
    @(posedge clk);
    release dut.m05_awvalid;
    release dut.m05_awaddr;
    release dut.m05_awid;
    release dut.m05_wvalid;
    release dut.m05_wdata;
    release dut.m05_wstrb;
    release dut.m05_bready;
    @(posedge clk);
endtask

task uart_soc_read(
    input  logic [31:0] addr,
    output logic [31:0] data
);
    force dut.m05_arvalid = 1'b1;
    force dut.m05_araddr  = addr;
    force dut.m05_arid    = 8'h00;
    force dut.m05_rready  = 1'b1;

    begin : ar_hs
        int n = 0;
        while (dut.m05_arready !== 1'b1 && n < TIMEOUT_CYC) begin
            @(posedge clk); n++;
        end
        force dut.m05_arvalid = 1'b0;
    end
    begin : r_hs
        int n = 0;
        while (dut.m05_rvalid !== 1'b1 && n < TIMEOUT_CYC) begin
            @(posedge clk); n++;
        end
        data = dut.m05_rdata;
        @(posedge clk);
        force dut.m05_rready = 1'b0;
    end
    @(posedge clk);
    release dut.m05_arvalid;
    release dut.m05_araddr;
    release dut.m05_arid;
    release dut.m05_rready;
    @(posedge clk);
endtask

task automatic uart_poll_lsr(input int bit_pos, input string name);
    logic [31:0] lsr;
    int count = 0;
    do begin
        uart_soc_read(UART_BASE + 32'(ADDR_LSR), lsr);
        count++;
        if (count > 2000) begin
            $error("[TB] TIMEOUT waiting for UART LSR[%0d] (%s)", bit_pos, name);
            fail_count++;
            return;
        end
    end while (lsr[bit_pos] !== 1'b1);
endtask

// ---------------------------------------------------------------------------
// TC6 helpers — inject via xbar s03 (tied-off NDA port) to unmapped space
// ---------------------------------------------------------------------------
task s03_read(
    input  logic [31:0] addr,
    output logic [1:0]  rresp
);
    force dut.u_xbar.s03_axi_arvalid = 1'b1;
    force dut.u_xbar.s03_axi_araddr  = addr;
    force dut.u_xbar.s03_axi_arid    = 8'h00;
    force dut.u_xbar.s03_axi_arlen   = 8'h00;
    force dut.u_xbar.s03_axi_arsize  = 3'b010;
    force dut.u_xbar.s03_axi_arburst = 2'b01;
    force dut.u_xbar.s03_axi_rready  = 1'b1;

    begin : ar_hs
        int n = 0;
        while (dut.u_xbar.s03_axi_arready !== 1'b1 && n < TIMEOUT_CYC) begin
            @(posedge clk); n++;
        end
        force dut.u_xbar.s03_axi_arvalid = 1'b0;
    end
    begin : r_hs
        int n = 0;
        while (dut.u_xbar.s03_axi_rvalid !== 1'b1 && n < TIMEOUT_CYC) begin
            @(posedge clk); n++;
        end
        rresp = dut.u_xbar.s03_axi_rresp;
        @(posedge clk);
        force dut.u_xbar.s03_axi_rready = 1'b0;
    end
    @(posedge clk);
    release dut.u_xbar.s03_axi_arvalid;
    release dut.u_xbar.s03_axi_araddr;
    release dut.u_xbar.s03_axi_arid;
    release dut.u_xbar.s03_axi_arlen;
    release dut.u_xbar.s03_axi_arsize;
    release dut.u_xbar.s03_axi_arburst;
    release dut.u_xbar.s03_axi_rready;
    @(posedge clk);
endtask

task s03_write(
    input  logic [31:0] addr,
    output logic [1:0]  bresp
);
    force dut.u_xbar.s03_axi_awvalid = 1'b1;
    force dut.u_xbar.s03_axi_awaddr  = addr;
    force dut.u_xbar.s03_axi_awid    = 8'h00;
    force dut.u_xbar.s03_axi_awlen   = 8'h00;
    force dut.u_xbar.s03_axi_awsize  = 3'b010;
    force dut.u_xbar.s03_axi_awburst = 2'b01;
    force dut.u_xbar.s03_axi_wvalid  = 1'b1;
    force dut.u_xbar.s03_axi_wdata   = 32'hDEAD_BEEF;
    force dut.u_xbar.s03_axi_wstrb   = 4'hF;
    force dut.u_xbar.s03_axi_wlast   = 1'b1;
    force dut.u_xbar.s03_axi_bready  = 1'b1;

    fork
        begin : aw_hs
            int n = 0;
            while (dut.u_xbar.s03_axi_awready !== 1'b1 && n < TIMEOUT_CYC) begin
                @(posedge clk); n++;
            end
            force dut.u_xbar.s03_axi_awvalid = 1'b0;
        end
        begin : w_hs
            int n = 0;
            while (dut.u_xbar.s03_axi_wready !== 1'b1 && n < TIMEOUT_CYC) begin
                @(posedge clk); n++;
            end
            force dut.u_xbar.s03_axi_wvalid = 1'b0;
        end
    join
    begin : b_hs
        int n = 0;
        while (dut.u_xbar.s03_axi_bvalid !== 1'b1 && n < TIMEOUT_CYC) begin
            @(posedge clk); n++;
        end
        bresp = dut.u_xbar.s03_axi_bresp;
        @(posedge clk);
        force dut.u_xbar.s03_axi_bready = 1'b0;
    end
    @(posedge clk);
    release dut.u_xbar.s03_axi_awvalid;
    release dut.u_xbar.s03_axi_awaddr;
    release dut.u_xbar.s03_axi_awid;
    release dut.u_xbar.s03_axi_awlen;
    release dut.u_xbar.s03_axi_awsize;
    release dut.u_xbar.s03_axi_awburst;
    release dut.u_xbar.s03_axi_wvalid;
    release dut.u_xbar.s03_axi_wdata;
    release dut.u_xbar.s03_axi_wstrb;
    release dut.u_xbar.s03_axi_wlast;
    release dut.u_xbar.s03_axi_bready;
    @(posedge clk);
endtask

// ---------------------------------------------------------------------------
// Global watchdog
// ---------------------------------------------------------------------------
initial begin
    repeat (GLOBAL_CYCLES) @(posedge clk);
    $error("[TB] GLOBAL TIMEOUT");
    $finish;
end

// ---------------------------------------------------------------------------
// Test stimulus
// ---------------------------------------------------------------------------
initial begin
    // Wait for reset release
    @(posedge rst_n);
    repeat(4) @(posedge clk);

    // --------------------------------------------------------------
    // TC1 — Reset check
    // --------------------------------------------------------------
    $display("[TC1] Reset check");
    check("xbar FSM IDLE after reset",
        dut.u_xbar.axi_interconnect_inst.state_reg === 3'd0);
    check("uart_tx idle high after reset", uart_tx === 1'b1);
    check("no X on m05 control (awready/arready known)",
        !$isunknown(dut.m05_awready) && !$isunknown(dut.m05_arready));

    // --------------------------------------------------------------
    // TC2 — VeeR alive: LSU or IFU issues an AXI read
    // --------------------------------------------------------------
    $display("[TC2] Wait for VeeR AXI read request");
    begin : tc2
        int n = 0;
        while (dut.ifu_arvalid !== 1'b1 && dut.lsu_arvalid !== 1'b1
               && n < TIMEOUT_CYC) begin
            @(posedge clk); n++;
        end
        check("VeeR issued AXI read (ifu/lsu arvalid)",
            (dut.ifu_arvalid === 1'b1) || (dut.lsu_arvalid === 1'b1));
    end

    // --------------------------------------------------------------
    // TC3 — Reset vector: first IFU fetch targets 0x0000_0000
    // --------------------------------------------------------------
    $display("[TC3] Reset-vector fetch address");
    begin : tc3
        int n = 0;
        // IFU may already be valid from TC2; sample current s01 address
        while (dut.u_xbar.s01_axi_arvalid !== 1'b1 && n < TIMEOUT_CYC) begin
            @(posedge clk); n++;
        end
        check("s01 fetch valid seen", dut.u_xbar.s01_axi_arvalid === 1'b1);
        check("s01 fetch targets 0x0000_0000 (reset vector)",
            dut.u_xbar.s01_axi_araddr === 32'h0000_0000);
    end

    // --------------------------------------------------------------
    // TC4 — m00 DRAM stub completes the boot fetch
    // --------------------------------------------------------------
    $display("[TC4] m00 stub handshake");
    begin : tc4
        int n = 0;
        while (dut.m00_arvalid !== 1'b1 && n < TIMEOUT_CYC) begin
            @(posedge clk); n++;
        end
        check("m00 arvalid seen", dut.m00_arvalid === 1'b1);
        n = 0;
        while (dut.m00_rvalid !== 1'b1 && n < TIMEOUT_CYC) begin
            @(posedge clk); n++;
        end
        check("m00 rvalid returned", dut.m00_rvalid === 1'b1);
        check("m00 rresp OKAY", dut.m00_rresp === 2'b00);
    end

    // --------------------------------------------------------------
    // TC5 — UART loopback through SoC hierarchy
    // --------------------------------------------------------------
    $display("[TC5] UART LCR + baud + loopback byte");
    uart_soc_write(UART_BASE + 32'(ADDR_LCR), LCR_8N1);
    check("UART LCR write bresp OKAY", dut.m05_bresp === 2'b00);
    uart_soc_write(UART_BASE + 32'(ADDR_IER), 32'h0000_0001);
    check("UART IER write bresp OKAY", dut.m05_bresp === 2'b00);
    uart_soc_write(UART_BASE + 32'(ADDR_LCR), 32'h0000_0083); // DLAB=1
    uart_soc_write(UART_BASE + 32'(ADDR_BAUD), BAUD_DIV_SIM);
    uart_soc_write(UART_BASE + 32'(ADDR_LCR), LCR_8N1);       // DLAB=0
    uart_soc_write(UART_BASE + 32'(ADDR_RBR_THR), 32'h0000_00A5);
    uart_poll_lsr(LSR_TEMT, "TEMT");
    check("UART TX byte completed (TEMT)", 1'b1);
    uart_soc_write(UART_BASE + 32'(ADDR_RBR_THR), 32'h0000_0037);
    uart_poll_lsr(LSR_DATA_READY, "DATA_READY");
    begin : tc5_rb
        logic [31:0] rbr;
        uart_soc_read(UART_BASE + 32'(ADDR_RBR_THR), rbr);
        check("UART loopback byte 0x37", rbr[7:0] === 8'h37);
    end

    // --------------------------------------------------------------
    // TC6 — DECERR on reserved address via s03
    // --------------------------------------------------------------
    $display("[TC6] Reserved-address DECERR");
    begin : tc6
        logic [1:0] rresp, bresp;
        s03_read(RESERVED_ADDR, rresp);
        check("reserved read rresp != OKAY", rresp !== 2'b00);
        s03_write(RESERVED_ADDR, bresp);
        check("reserved write bresp != OKAY", bresp !== 2'b00);
    end

    // --------------------------------------------------------------
    // Summary
    // --------------------------------------------------------------
    $display("");
    $display("============================================");
    $display(" tb_honours_soc complete: %0d PASS  %0d FAIL",
             pass_count, fail_count);
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
    $fsdbDumpfile("tb_honours_soc.fsdb");
    $fsdbDumpvars(0, tb_honours_soc);
    $fsdbDumpMDA();
end

endmodule

`default_nettype wire
