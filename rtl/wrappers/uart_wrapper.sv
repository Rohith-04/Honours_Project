// =============================================================================
// uart_wrapper.sv — AXI4 slave wrapper around the untouched ips/uart core
//
// - Exposes the IP's native register map directly (see soc_pkg UART_*
//   offsets: RBR/THR, IER, BAUD_DIV, LCR, LSR). No CSR remapping.
// - Single-beat transactions only (BFM issues awlen/arlen == 0). The
//   wrapper passes the AXI handshake straight through to the IP's AXI4-Lite
//   port and ignores len/size/burst qualifiers.
// - fixed_clk_i (UART baud domain) is tied to the AXI clock, matching the
//   IP's default _UART_MAIN_CLOCK_FREQ_ of 100 MHz at 100 MHz operation.
// - Reset: active-low aresetn in, straight to the IP's axi_aresetn_i.
//   (Per PROJECT_STRUCTURE.md reset convention.)
// - ID width is 12 bits end-to-end (matches the IP's _AXI_UART_ID_WIDTH_).
// =============================================================================

`resetall
`timescale 1ns / 1ps
`default_nettype none

module uart_wrapper #(
  parameter int unsigned ID_WIDTH   = 12,
  parameter int unsigned ADDR_WIDTH = 32
)(
  input  wire                  clk,
  input  wire                  aresetn,

  // AXI4 slave port (single-beat use; len/size/burst ignored)
  input  wire [ID_WIDTH-1:0]   s_axi_awid,
  input  wire [ADDR_WIDTH-1:0] s_axi_awaddr,
  input  wire [7:0]            s_axi_awlen,
  input  wire [2:0]            s_axi_awsize,
  input  wire [1:0]            s_axi_awburst,
  input  wire                  s_axi_awvalid,
  output wire                  s_axi_awready,
  input  wire [31:0]           s_axi_wdata,
  input  wire [3:0]            s_axi_wstrb,
  input  wire                  s_axi_wvalid,
  output wire                  s_axi_wready,
  output wire [ID_WIDTH-1:0]   s_axi_bid,
  output wire [1:0]            s_axi_bresp,
  output wire                  s_axi_bvalid,
  input  wire                  s_axi_bready,
  input  wire [ID_WIDTH-1:0]   s_axi_arid,
  input  wire [ADDR_WIDTH-1:0] s_axi_araddr,
  input  wire [7:0]            s_axi_arlen,
  input  wire [2:0]            s_axi_arsize,
  input  wire [1:0]            s_axi_arburst,
  input  wire                  s_axi_arvalid,
  output wire                  s_axi_arready,
  output wire [ID_WIDTH-1:0]   s_axi_rid,
  output wire [31:0]           s_axi_rdata,
  output wire [1:0]            s_axi_rresp,
  output wire                  s_axi_rvalid,
  input  wire                  s_axi_rready,

  // UART pins + interrupt
  input  wire                  uart_rx_i,
  output wire                  uart_tx_o,
  output wire                  uart_irq_o
);

  // Unused qualifiers (single-beat assumption, documented above).
  wire _unused = &{1'b0, s_axi_awlen, s_axi_awsize, s_axi_awburst,
                   s_axi_arlen, s_axi_arsize, s_axi_arburst};

  axi_uart_top u_uart (
    .fixed_clk_i   (clk),
    .axi_aclk_i    (clk),
    .axi_aresetn_i (aresetn),

    .axi_awid_i    (s_axi_awid),
    .axi_awaddr_i  (s_axi_awaddr[4:0]),
    .axi_awvalid_i (s_axi_awvalid),
    .axi_awready_o (s_axi_awready),

    .axi_wdata_i   (s_axi_wdata),
    .axi_wstrb_i   (s_axi_wstrb),
    .axi_wvalid_i  (s_axi_wvalid),
    .axi_wready_o  (s_axi_wready),

    .axi_bid_o     (s_axi_bid),
    .axi_bresp_o   (s_axi_bresp),
    .axi_bvalid_o  (s_axi_bvalid),
    .axi_bready_i  (s_axi_bready),

    .axi_arid_i    (s_axi_arid),
    .axi_araddr_i  (s_axi_araddr[4:0]),
    .axi_arvalid_i (s_axi_arvalid),
    .axi_arready_o (s_axi_arready),

    .axi_rid_o     (s_axi_rid),
    .axi_rdata_o   (s_axi_rdata),
    .axi_rresp_o   (s_axi_rresp),
    .axi_rvalid_o  (s_axi_rvalid),
    .axi_rready_i  (s_axi_rready),

    .read_interrupt_o (uart_irq_o),
    .uart_rx_i        (uart_rx_i),
    .uart_tx_o        (uart_tx_o)
  );

endmodule

`resetall
