// =============================================================================
// uart_tasks.sv — UART access routed through xbar (s03 hooks -> m05)
//
// Thin wrappers over s03_write/read_full (proper drivers, no force).
// Register model: LCR/IER/BAUD/THR/RBR/LSR, div=100, drain stale loopback.
// Requires axi_tasks.sv included first.
// =============================================================================

task uart_xbar_write(
    input logic [31:0] addr,
    input logic [31:0] data
);
    s03_write_full(addr, data, 4'hF);
endtask

task uart_xbar_read(
    input  logic [31:0] addr,
    output logic [31:0] data
);
    s03_read_full(addr, data);
endtask

task automatic uart_xbar_poll_lsr(input int bit_pos, input string name);
    logic [31:0] lsr;
    int count;
    count = 0;
    do begin
        uart_xbar_read(UART_BASE + 32'(ADDR_LSR), lsr);
        count++;
        if (count > 2000) begin
            $error("[TB] TIMEOUT waiting for UART LSR[%0d] (%s)", bit_pos, name);
            fail_count++;
            return;
        end
    end while (lsr[bit_pos] !== 1'b1);
endtask

task automatic uart_xbar_drain();
    logic [31:0] lsr;
    logic [31:0] dummy;
    for (int i = 0; i < 40; i++) begin
        uart_xbar_read(UART_BASE + 32'(ADDR_LSR), lsr);
        if (lsr[LSR_DATA_READY] !== 1'b1)
            break;
        uart_xbar_read(UART_BASE + 32'(ADDR_RBR_THR), dummy);
        $display("[DRAIN] discarded stale RX byte 0x%0h", dummy[7:0]);
    end
endtask

// Full 8N1 + loopback-byte sequence used by middle + SW bring-up.
task uart_xbar_loopback_byte(input logic [7:0] expect_byte);
    int fails_before;
    fails_before = fail_count;
    uart_xbar_write(UART_BASE + 32'(ADDR_LCR), LCR_8N1);
    uart_xbar_write(UART_BASE + 32'(ADDR_IER), 32'h0000_0001);
    uart_xbar_write(UART_BASE + 32'(ADDR_LCR), 32'h0000_0083); // DLAB=1
    uart_xbar_write(UART_BASE + 32'(ADDR_BAUD), BAUD_DIV_SIM);
    uart_xbar_write(UART_BASE + 32'(ADDR_LCR), LCR_8N1);       // DLAB=0
    check("UART config writes OKAY", fail_count == fails_before);
    fails_before = fail_count;
    uart_xbar_write(UART_BASE + 32'(ADDR_RBR_THR), 32'(expect_byte));
    uart_xbar_poll_lsr(LSR_TEMT, "TEMT");
    check("UART TX completed (TEMT)", fail_count == fails_before);
    uart_xbar_poll_lsr(LSR_DATA_READY, "DATA_READY");
    begin
        logic [31:0] rbr;
        uart_xbar_read(UART_BASE + 32'(ADDR_RBR_THR), rbr);
        check($sformatf("UART loopback 0x%0h", expect_byte), rbr[7:0] === expect_byte);
    end
endtask
