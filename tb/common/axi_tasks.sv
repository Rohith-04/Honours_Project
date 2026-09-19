// =============================================================================
// axi_tasks.sv — proper s03 (NDA-seat hook) AXI master drivers, NO force
//
// Drives dut.tb_s03_* ports procedurally with standard AXI handshakes:
// valid held until ready, response waited with timeout, clean deassert.
// Upstream of a standard xbar + shimmed UART, so drop-after-ready is
// correct here (the UART gating is hidden inside uart_wrap's shim).
//
// Requires (declared in the including TB, connected to dut):
//   regs: tb_s03_awid/addr/len/size/burst/valid, wdata/wstrb/wlast/valid,
//         bready, arid/addr/len/size/burst/valid, rready
//   wires sampled: tb_s03_awready/wready/bid/bresp/bvalid/arready/rid/
//                  rdata/rresp/rlast/rvalid
// Include AFTER clk/dut/fail_count. Static tasks.
// =============================================================================

task s03_write_full(
    input logic [31:0] addr,
    input logic [31:0] data,
    input logic [3:0]  strb = 4'hF
);
    bit aw_done;
    bit w_done;
    int n;
    @(posedge clk);
    tb_s03_awid    <= 8'h00;
    tb_s03_awaddr  <= addr;
    tb_s03_awlen   <= 8'h00;
    tb_s03_awsize  <= 3'b010;
    tb_s03_awburst <= 2'b01;
    tb_s03_awvalid <= 1'b1;
    tb_s03_wdata   <= data;
    tb_s03_wstrb   <= strb;
    tb_s03_wlast   <= 1'b1;
    tb_s03_wvalid  <= 1'b1;
    tb_s03_bready  <= 1'b1;

    // Hold each valid until its ready (standard, both may complete together)
    aw_done = 1'b0;
    w_done  = 1'b0;
    n = 0;
    while ((!aw_done || !w_done) && n < TIMEOUT_CYC) begin
        @(posedge clk); n++;
        if (!aw_done && tb_s03_awready === 1'b1) aw_done = 1'b1;
        if (!w_done  && tb_s03_wready  === 1'b1) w_done  = 1'b1;
    end
    if (!aw_done || !w_done) begin
        $error("[s03_write] HANDSHAKE TIMEOUT addr=0x%0h", addr);
        fail_count++;
    end
    @(posedge clk);
    tb_s03_awvalid <= 1'b0;
    tb_s03_wvalid  <= 1'b0;

    n = 0;
    while (tb_s03_bvalid !== 1'b1 && n < TIMEOUT_CYC) begin
        @(posedge clk); n++;
    end
    if (tb_s03_bvalid !== 1'b1) begin
        $error("[s03_write] BRESP TIMEOUT addr=0x%0h", addr);
        fail_count++;
    end else if (tb_s03_bresp !== 2'b00) begin
        $error("[s03_write] FAIL addr=0x%0h bresp=0x%0h", addr, tb_s03_bresp);
        fail_count++;
    end
    @(posedge clk);
    tb_s03_bready <= 1'b0;
    @(posedge clk);
endtask

task s03_read_full(
    input  logic [31:0] addr,
    output logic [31:0] data
);
    int n;
    @(posedge clk);
    tb_s03_arid    <= 8'h00;
    tb_s03_araddr  <= addr;
    tb_s03_arlen   <= 8'h00;
    tb_s03_arsize  <= 3'b010;
    tb_s03_arburst <= 2'b01;
    tb_s03_arvalid <= 1'b1;
    tb_s03_rready  <= 1'b1;

    n = 0;
    while (tb_s03_arready !== 1'b1 && n < TIMEOUT_CYC) begin
        @(posedge clk); n++;
    end
    if (tb_s03_arready !== 1'b1) begin
        $error("[s03_read] AR TIMEOUT addr=0x%0h", addr);
        $display("[s03_read] DBG st=%0d s01_av=%b s01_a=0x%08h s03_av=%b m00_av=%b m00_rv=%b m00_rr=%b s01_rv=%b ifu_rr=%b m01_av=%b m05_av=%b",
            dut.u_xbar.axi_interconnect_inst.state_reg,
            dut.u_xbar.s01_axi_arvalid, dut.u_xbar.s01_axi_araddr,
            dut.u_xbar.s03_axi_arvalid,
            dut.m00_arvalid, dut.m00_rvalid, dut.m00_rready,
            dut.u_xbar.s01_axi_rvalid, dut.ifu_rready,
            dut.u_xbar.m01_axi_arvalid, dut.m05_arvalid);
        fail_count++;
        data = 32'hXXXX_XXXX;
        return;
    end
    @(posedge clk);
    tb_s03_arvalid <= 1'b0;

    n = 0;
    while (tb_s03_rvalid !== 1'b1 && n < TIMEOUT_CYC) begin
        @(posedge clk); n++;
    end
    if (tb_s03_rvalid !== 1'b1) begin
        $error("[s03_read] R TIMEOUT addr=0x%0h", addr);
        fail_count++;
        data = 32'hXXXX_XXXX;
    end else begin
        data = tb_s03_rdata;
        if (tb_s03_rresp !== 2'b00) begin
            $error("[s03_read] FAIL addr=0x%0h rresp=0x%0h", addr, tb_s03_rresp);
            fail_count++;
        end
    end
    @(posedge clk);
    tb_s03_rready <= 1'b0;
    @(posedge clk);
endtask

// DECERR probe (unmapped space must NOT return OKAY)
task s03_expect_decerr(
    input logic [31:0] addr
);
    logic [1:0] saved_rresp;
    logic [31:0] dummy;
    int n;
    @(posedge clk);
    tb_s03_arid    <= 8'h00;
    tb_s03_araddr  <= addr;
    tb_s03_arlen   <= 8'h00;
    tb_s03_arsize  <= 3'b010;
    tb_s03_arburst <= 2'b01;
    tb_s03_arvalid <= 1'b1;
    tb_s03_rready  <= 1'b1;
    n = 0;
    while (tb_s03_arready !== 1'b1 && n < TIMEOUT_CYC) begin
        @(posedge clk); n++;
    end
    @(posedge clk);
    tb_s03_arvalid <= 1'b0;
    n = 0;
    while (tb_s03_rvalid !== 1'b1 && n < TIMEOUT_CYC) begin
        @(posedge clk); n++;
    end
    saved_rresp = tb_s03_rresp;
    dummy = tb_s03_rdata;
    @(posedge clk);
    tb_s03_rready <= 1'b0;
    @(posedge clk);
    check($sformatf("reserved read DECERR (rresp=0x%0h)", saved_rresp), saved_rresp !== 2'b00);
endtask
