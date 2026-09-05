// =============================================================================
// uart_wrap.sv — AXI4-Lite wrapper for the BSC/CIC-IPN AXI-UART IP
//
// Wraps:  ips/uart/src/rtl/axi_uart_top.v
//
// The IP has two clocks:
//   fixed_clk_i  — baud-rate / UART logic clock (same as system clock here)
//   axi_aclk_i   — AXI bus clock
// Both are driven from the single soc_clk input in this wrapper.
//
// The IP uses 5-bit byte-addressed AXI addresses internally.
// The interconnect delivers 32-bit addresses; the wrapper strips the upper bits
// — the slave decode window must be sized to at least 32 bytes.
//
// Parameters exposed for easy tuning from the SoC top:
//   AXI_ID_WIDTH  — must match the interconnect master-side ID width (default 8)
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module uart_wrap #(
    parameter AXI_ID_WIDTH = 8          // match interconnect M-port ID width
) (
    // -------------------------------------------------------------------------
    // Clocks and reset
    // -------------------------------------------------------------------------
    input  logic                     clk,       // system clock (AXI + UART baud)
    input  logic                     rst_n,     // active-low synchronous reset

    // -------------------------------------------------------------------------
    // AXI4-Lite slave interface  (from interconnect master port)
    // -------------------------------------------------------------------------
    // Write address
    input  logic                     s_axi_awvalid,
    output logic                     s_axi_awready,
    input  logic [AXI_ID_WIDTH-1:0]  s_axi_awid,
    input  logic [31:0]              s_axi_awaddr,
    // Write data
    input  logic                     s_axi_wvalid,
    output logic                     s_axi_wready,
    input  logic [31:0]              s_axi_wdata,
    input  logic [3:0]               s_axi_wstrb,
    // Write response
    output logic                     s_axi_bvalid,
    input  logic                     s_axi_bready,
    output logic [AXI_ID_WIDTH-1:0]  s_axi_bid,
    output logic [1:0]               s_axi_bresp,
    // Read address
    input  logic                     s_axi_arvalid,
    output logic                     s_axi_arready,
    input  logic [AXI_ID_WIDTH-1:0]  s_axi_arid,
    input  logic [31:0]              s_axi_araddr,
    // Read data
    output logic                     s_axi_rvalid,
    input  logic                     s_axi_rready,
    output logic [AXI_ID_WIDTH-1:0]  s_axi_rid,
    output logic [31:0]              s_axi_rdata,
    output logic [1:0]               s_axi_rresp,

    // -------------------------------------------------------------------------
    // UART physical interface
    // -------------------------------------------------------------------------
    input  logic                     uart_rx,
    output logic                     uart_tx,

    // -------------------------------------------------------------------------
    // Interrupt to CPU PIC
    // -------------------------------------------------------------------------
    output logic                     uart_irq    // high = RX data available
);

    // -------------------------------------------------------------------------
    // Address width the IP expects is 5 bits (32-byte window, byte-addressed)
    // Strip the upper address bits — the interconnect slave decode ensures
    // only addresses within this slave's window reach here.
    // -------------------------------------------------------------------------
    localparam IP_ADDR_W = 5;

    // Internal ID wires — IP has 12-bit IDs internally
    localparam IP_ID_W = 12;

    wire [IP_ID_W-1:0] ip_awid  = {{(IP_ID_W-AXI_ID_WIDTH){1'b0}}, s_axi_awid};
    wire [IP_ID_W-1:0] ip_arid  = {{(IP_ID_W-AXI_ID_WIDTH){1'b0}}, s_axi_arid};
    wire [IP_ID_W-1:0] ip_bid;
    wire [IP_ID_W-1:0] ip_rid;

    assign s_axi_bid = ip_bid[AXI_ID_WIDTH-1:0];
    assign s_axi_rid = ip_rid[AXI_ID_WIDTH-1:0];

    // -------------------------------------------------------------------------
    // Instantiate axi_uart_top
    // -------------------------------------------------------------------------
    axi_uart_top u_axi_uart (
        // clocks / reset
        .fixed_clk_i    (clk),
        .axi_aclk_i     (clk),
        .axi_aresetn_i  (rst_n),

        // write address channel
        .axi_awid_i     (ip_awid),
        .axi_awaddr_i   (s_axi_awaddr[IP_ADDR_W-1:0]),
        .axi_awvalid_i  (s_axi_awvalid),
        .axi_awready_o  (s_axi_awready),

        // write data channel
        .axi_wdata_i    (s_axi_wdata),
        .axi_wstrb_i    (s_axi_wstrb),
        .axi_wvalid_i   (s_axi_wvalid),
        .axi_wready_o   (s_axi_wready),

        // write response channel
        .axi_bid_o      (ip_bid),
        .axi_bresp_o    (s_axi_bresp),
        .axi_bvalid_o   (s_axi_bvalid),
        .axi_bready_i   (s_axi_bready),

        // read address channel
        .axi_arid_i     (ip_arid),
        .axi_araddr_i   (s_axi_araddr[IP_ADDR_W-1:0]),
        .axi_arvalid_i  (s_axi_arvalid),
        .axi_arready_o  (s_axi_arready),

        // read data channel
        .axi_rid_o      (ip_rid),
        .axi_rdata_o    (s_axi_rdata),
        .axi_rresp_o    (s_axi_rresp),
        .axi_rvalid_o   (s_axi_rvalid),
        .axi_rready_i   (s_axi_rready),

        // UART physical
        .uart_rx_i      (uart_rx),
        .uart_tx_o      (uart_tx),

        // interrupt
        .read_interrupt_o (uart_irq)
    );

endmodule

`default_nettype wire
