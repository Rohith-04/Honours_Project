// =============================================================================
// tb_uart_sw_simple.sv — ONE test: VeeR executes code, byte shows on uart_tx.
//
// No tasks, no includes, no force. DUT = honours_soc with true RAM.
// Run: make usw.sim SW_HEX=<path>  (or via make uart.sw)
// Image (sw/uart_test) programs UART div=100 and sends "Hi\n".
// This TB only watches the uart_tx pin and decodes 8N1.
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_uart_sw_simple;

localparam CLK_PERIOD = 10;          // 100 MHz
localparam BAUD_DIV   = 100;         // must match sw image
localparam BIT_CLKS   = BAUD_DIV + 1;

// ---------------------------------------------------------------------------
logic clk   = 1'b0;
logic rst_n = 1'b0;
always #(CLK_PERIOD/2) clk = ~clk;

initial begin
    repeat (8) @(posedge clk);
    rst_n = 1'b1;
end

// ---------------------------------------------------------------------------
logic uart_rx;
logic uart_tx;
assign uart_rx = uart_tx;            // loopback, harmless

honours_soc dut (
    .clk           (clk),
    .rst_n         (rst_n),
    .uart_rx       (uart_rx),
    .uart_tx       (uart_tx),
    .jtag_tck      (1'b0),
    .jtag_tms      (1'b1),
    .jtag_tdi      (1'b0),
    .jtag_trst_n   (rst_n),
    .jtag_tdo      (),
    .jtag_tdo_en   (),
    .extintsrc_req ('0)
    // tb_s03_* hooks left unconnected -> idle defaults, NDA seat empty
);

// ---------------------------------------------------------------------------
initial begin
    $fsdbDumpfile("tb_uart_sw_simple.fsdb");
    $fsdbDumpvars(0, tb_uart_sw_simple);
    $fsdbDumpMDA();
end

// Global watchdog: 3 chars * ~1010 clks + boot slack, generous
initial begin
    repeat (2_000_000) @(posedge clk);
    $error("[SIMPLE] TIMEOUT — no complete string on uart_tx");
    $display(" SIMPLE RESULT: FAIL");
    $finish;
end

// ---------------------------------------------------------------------------
// The one test: expect "Hi\n" on uart_tx, 8N1, LSB first, mid-bit sampling
// ---------------------------------------------------------------------------
initial begin : test
    byte unsigned want[3];
    byte unsigned got;
    want[0] = 8'h48;  // H
    want[1] = 8'h69;  // i
    want[2] = 8'h0A;  // \n

    @(posedge rst_n);
    repeat (4) @(posedge clk);

    for (int ci = 0; ci < 3; ci++) begin
        // wait for start bit falling edge
        while (uart_tx !== 1'b0) @(posedge clk);
        // mid-start-bit
        repeat (BIT_CLKS/2) @(posedge clk);
        got = 8'h00;
        for (int b = 0; b < 8; b++) begin
            repeat (BIT_CLKS) @(posedge clk);
            got[b] = uart_tx;
        end
        repeat (BIT_CLKS) @(posedge clk);  // stop bit
        if (got !== want[ci]) begin
            $error("[SIMPLE] char %0d: want 0x%02h got 0x%02h", ci, want[ci], got);
            $display(" SIMPLE RESULT: FAIL");
            $finish;
        end
        $display("[SIMPLE] char %0d OK: '%c' (0x%02h)", ci, got, got);
    end

    $display(" SIMPLE RESULT: PASS — \"Hi\" on uart_tx from the core");
    $finish;
end

endmodule

`default_nettype wire
