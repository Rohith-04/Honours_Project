// =============================================================================
// soc_tasks.sv — SoC bring-up primitives (textual include, not a package)
//
// Include AFTER clk/rst_n/dut/check/pass_count/fail_count are defined.
// Assumes: logic clk, logic rst_n, honours_soc dut, check(string,bit).
// Uses only static tasks (force-incompatible with automatic args).
// =============================================================================

task reset_soc();
    rst_n = 1'b0;
    repeat (8) @(posedge clk);
    rst_n = 1'b1;
endtask

task start_soc();
    repeat (4) @(posedge clk);
    check("uart_tx idle high after reset", uart_tx === 1'b1);
endtask

task stop_soc();
    $display("");
    $display("============================================");
    $display(" complete: %0d PASS  %0d FAIL", pass_count, fail_count);
    $display("============================================");
    if (fail_count == 0)
        $display(" ALL CHECKS PASSED");
    else
        $display(" FAILURES DETECTED");
    $display("============================================");
    $finish;
endtask

// Wait for live VeeR fetch through xbar to m00 (TC2-TC4 collapsed).
// Returns nothing; logs fails via check/fail_count.
task wait_for_core();
    int n;
    // TC2: VeeR issues a read
    n = 0;
    while (dut.ifu_arvalid !== 1'b1 && dut.lsu_arvalid !== 1'b1
           && n < TIMEOUT_CYC) begin
        @(posedge clk); n++;
    end
    check("VeeR issued AXI read (ifu/lsu arvalid)",
        (dut.ifu_arvalid === 1'b1) || (dut.lsu_arvalid === 1'b1));
    // TC3: reset vector via s01
    n = 0;
    while (dut.u_xbar.s01_axi_arvalid !== 1'b1 && n < TIMEOUT_CYC) begin
        @(posedge clk); n++;
    end
    check("s01 fetch valid seen", dut.u_xbar.s01_axi_arvalid === 1'b1);
    check("s01 fetch targets 0x0000_0000 (reset vector)",
        dut.u_xbar.s01_axi_araddr === 32'h0000_0000);
    // TC4: m00 answers
    n = 0;
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
endtask

// SW image is preloaded by axi_true_mem via +SW_HEX (no TB copy needed).
// Kept as explicit step so flow reads: reset -> load -> start -> wait.
task load_program();
    string hex_path;
    if ($value$plusargs("SW_HEX=%s", hex_path))
        $display("[load_program] image: %s (preloaded by axi_true_mem)", hex_path);
    else
        $display("[load_program] no +SW_HEX — running NOP image (bring-up)");
endtask
