// =============================================================================
// axi_stub_mem.sv — Minimal AXI4 slave stub for SoC bring-up
//
// Purpose: give the SoC interconnect a responding slave on m00 (DRAM window)
// so VeeR's reset-vector fetch completes during structural bring-up.
// Single outstanding transaction, single-beat only (arlen/awlen ignored,
// always returns one beat with rlast=1). NOT a full memory model.
//
// Params:
//   RESP        — bresp/rresp to return (2'b00 OKAY, 2'b11 DECERR)
//   RDATA_VALUE — 32-bit word returned on every read (default RV NOP)
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module axi_stub_mem #(
    parameter [1:0]  RESP        = 2'b00,
    parameter [31:0] RDATA_VALUE = 32'h0000_0013   // RV NOP (addi x0,x0,0)
) (
    input  logic        clk,
    input  logic        rst,          // active-high (matches xbar rst)

    // Write address
    input  logic [7:0]  s_awid,
    input  logic [31:0] s_awaddr,
    input  logic [7:0]  s_awlen,
    input  logic        s_awvalid,
    output logic        s_awready,
    // Write data
    input  logic [31:0] s_wdata,
    input  logic [3:0]  s_wstrb,
    input  logic        s_wlast,
    input  logic        s_wvalid,
    output logic        s_wready,
    // Write response
    output logic [7:0]  s_bid,
    output logic [1:0]  s_bresp,
    output logic        s_bvalid,
    input  logic        s_bready,
    // Read address
    input  logic [7:0]  s_arid,
    input  logic [31:0] s_araddr,
    input  logic [7:0]  s_arlen,
    input  logic        s_arvalid,
    output logic        s_arready,
    // Read data
    output logic [7:0]  s_rid,
    output logic [31:0] s_rdata,
    output logic [1:0]  s_rresp,
    output logic        s_rlast,
    output logic        s_rvalid,
    input  logic        s_rready
);

    // Always ready for address/data — single-beat, no backpressure
    assign s_awready = 1'b1;
    assign s_wready  = 1'b1;
    assign s_arready = 1'b1;

    // Write response: pulse one cycle after both AW and W seen together.
    // (wlast single-beat assumed; awlen ignored.)
    logic aw_seen, w_seen;
    always_ff @(posedge clk) begin
        if (rst) begin
            aw_seen <= 1'b0;
            w_seen  <= 1'b0;
        end else begin
            if (s_awvalid) aw_seen <= 1'b1;
            if (s_wvalid)  w_seen  <= 1'b1;
            if (s_bvalid && s_bready) begin
                aw_seen <= 1'b0;
                w_seen  <= 1'b0;
            end
        end
    end

    assign s_bvalid = aw_seen && w_seen;
    assign s_bresp  = RESP;
    assign s_bid    = s_awid;   // reflect ID (FORWARD_ID=0 safe: IDs ignored)

    // Read response: pulse one cycle after AR accepted
    logic ar_seen;
    always_ff @(posedge clk) begin
        if (rst) begin
            ar_seen <= 1'b0;
        end else begin
            if (s_arvalid) ar_seen <= 1'b1;
            if (s_rvalid && s_rready) ar_seen <= 1'b0;
        end
    end

    assign s_rvalid = ar_seen;
    assign s_rdata  = RDATA_VALUE;
    assign s_rresp  = RESP;
    assign s_rlast  = 1'b1;
    assign s_rid    = s_arid;

endmodule

`default_nettype wire
