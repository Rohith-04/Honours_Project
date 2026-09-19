// =============================================================================
// mem_tasks.sv — SW-mode UART TX monitor (no forces)
//
// Decodes the uart_tx serial line (8N1, divisor BAUD_DIV_SIM) into bytes and
// compares against an expected string. Used by make uart.sw where the VeeR
// core (not the TB) programs the UART.
//
// Timing: TX holds each bit (start + 8 data LSB-first + stop) for
// BAUD_DIV_SIM+1 clocks. Sample mid-bit for robustness.
// =============================================================================

task automatic uart_expect_string(input string exp_str);
    int baud_clks;
    int bit_clks;
    byte unsigned rx_byte;
    baud_clks = BAUD_DIV_SIM + 1;
    bit_clks  = baud_clks;
    for (int ci = 0; ci < exp_str.len(); ci++) begin
        byte unsigned want;
        int timeout;
        want = exp_str[ci];
        // Wait for start bit (falling edge) with timeout
        timeout = 0;
        while (uart_tx !== 1'b0 && timeout < TIMEOUT_CYC) begin
            @(posedge clk); timeout++;
        end
        if (uart_tx !== 1'b0) begin
            $error("[UART_MON] TIMEOUT waiting for start bit of char %0d ('%c')", ci, want);
            fail_count++;
            return;
        end
        // Mid-start-bit
        repeat (baud_clks/2) @(posedge clk);
        // 8 data bits, LSB first, mid-bit sample
        rx_byte = 8'h00;
        for (int b = 0; b < 8; b++) begin
            repeat (bit_clks) @(posedge clk);
            rx_byte[b] = uart_tx;
        end
        // Stop bit
        repeat (bit_clks) @(posedge clk);
        if (rx_byte !== want) begin
            $error("[UART_MON] char %0d: expected 0x%0h ('%c') got 0x%0h", ci, want, want, rx_byte);
            fail_count++;
            return;
        end else begin
            $display("[UART_MON] char %0d OK: 0x%0h ('%c')", ci, rx_byte, rx_byte);
        end
    end
    $display("[UART_MON] string \"%s\" received OK", exp_str);
endtask
