// =============================================================================
// honours_soc.sv — SoC TOP. Instantiate only. No behavioral logic.
//
// Single 32-bit AXI4 master port (s_axi_*) fanned out by a 1x4
// interconnect to RAM / UART / Timer / GPIO. Base addresses and widths
// come from soc_pkg (single source of truth) via parameter override.
// Reset: active-low aresetn in; the interconnect core's active-high rst
// is derived by inversion AT THIS BOUNDARY (reset convention,
// PROJECT_STRUCTURE.md §3).
// =============================================================================

`resetall
`timescale 1ns / 1ps
`default_nettype none

module honours_soc
  import soc_pkg::*;
#(
  parameter int unsigned ID_WIDTH   = soc_pkg::AXI_ID_WIDTH,
  parameter int unsigned ADDR_WIDTH = soc_pkg::AXI_ADDR_WIDTH,
  parameter int unsigned DATA_WIDTH = soc_pkg::AXI_DATA_WIDTH
)(
  input  wire                  clk,
  input  wire                  aresetn,

  // Master-facing AXI4 port (BFM at Levels 1-2 rung boundary; VeeR-side
  // width adapter at Level 3). Single-beat or burst; slaves that only
  // support single-beat answer SLVERR to the rest.
  input  wire [ID_WIDTH-1:0]   s_axi_awid,
  input  wire [ADDR_WIDTH-1:0] s_axi_awaddr,
  input  wire [7:0]            s_axi_awlen,
  input  wire [2:0]            s_axi_awsize,
  input  wire [1:0]            s_axi_awburst,
  input  wire                  s_axi_awvalid,
  output wire                  s_axi_awready,
  input  wire [DATA_WIDTH-1:0] s_axi_wdata,
  input  wire [DATA_WIDTH/8-1:0] s_axi_wstrb,
  input  wire                  s_axi_wlast,
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
  output wire [DATA_WIDTH-1:0] s_axi_rdata,
  output wire [1:0]            s_axi_rresp,
  output wire                  s_axi_rlast,
  output wire                  s_axi_rvalid,
  input  wire                  s_axi_rready,

  // UART pins
  input  wire                  uart_rx_i,
  output wire                  uart_tx_o,
  output wire                  uart_irq_o,
  // Timer interrupt
  output wire                  timer_irq_o,
  // GPIO pins
  input  wire [soc_pkg::GPIO_WIDTH-1:0] gpio_in,
  output wire [soc_pkg::GPIO_WIDTH-1:0] gpio_out
);

  wire xrst; // interconnect active-high reset, converted at boundary
  assign xrst = ~aresetn;

  // --- Interconnect-facing slave ports (m00=RAM, m01=UART, m02=Timer, m03=GPIO)
  wire [ID_WIDTH-1:0]   m_axi_awid   [0:3];
  wire [ADDR_WIDTH-1:0] m_axi_awaddr [0:3];
  wire [7:0]            m_axi_awlen  [0:3];
  wire [2:0]            m_axi_awsize [0:3];
  wire [1:0]            m_axi_awburst[0:3];
  wire                  m_axi_awvalid[0:3];
  wire                  m_axi_awready[0:3];
  wire [DATA_WIDTH-1:0] m_axi_wdata  [0:3];
  wire [DATA_WIDTH/8-1:0] m_axi_wstrb[0:3];
  wire                  m_axi_wlast  [0:3];
  wire                  m_axi_wvalid [0:3];
  wire                  m_axi_wready [0:3];
  wire [ID_WIDTH-1:0]   m_axi_bid    [0:3];
  wire [1:0]            m_axi_bresp  [0:3];
  wire                  m_axi_bvalid [0:3];
  wire                  m_axi_bready [0:3];
  wire [ID_WIDTH-1:0]   m_axi_arid   [0:3];
  wire [ADDR_WIDTH-1:0] m_axi_araddr [0:3];
  wire [7:0]            m_axi_arlen  [0:3];
  wire [2:0]            m_axi_arsize [0:3];
  wire [1:0]            m_axi_arburst[0:3];
  wire                  m_axi_arvalid[0:3];
  wire                  m_axi_arready[0:3];
  wire [ID_WIDTH-1:0]   m_axi_rid    [0:3];
  wire [DATA_WIDTH-1:0] m_axi_rdata  [0:3];
  wire [1:0]            m_axi_rresp  [0:3];
  wire                  m_axi_rlast  [0:3];
  wire                  m_axi_rvalid [0:3];
  wire                  m_axi_rready [0:3];

  // UART/Timer/GPIO are single-beat slaves with no RLAST port: every read
  // beat is the last one. The interconnect retires reads only on RLAST, so
  // these tie-offs (like the buser/ruser ones at the wrapper) are required
  // boundary adaptation — without them the first peripheral read parks the
  // xbar in STATE_READ forever while still forwarding that one R to the
  // master (master-side check passes, the NEXT transaction hangs).
  assign m_axi_rlast[1] = 1'b1; // UART
  assign m_axi_rlast[2] = 1'b1; // Timer
  assign m_axi_rlast[3] = 1'b1; // GPIO

  axi_interconnect_wrap_1x4 #(
    .DATA_WIDTH (DATA_WIDTH),
    .ADDR_WIDTH (ADDR_WIDTH),
    .ID_WIDTH   (ID_WIDTH),
    .M00_BASE_ADDR (soc_pkg::RAM_BASE),
    .M00_ADDR_WIDTH(32'd16), // 64 KiB
    .M01_BASE_ADDR (soc_pkg::UART_BASE),
    .M01_ADDR_WIDTH(32'd12), // 4 KiB
    .M02_BASE_ADDR (soc_pkg::TIMER_BASE),
    .M02_ADDR_WIDTH(32'd12), // 4 KiB
    .M03_BASE_ADDR (soc_pkg::GPIO_BASE),
    .M03_ADDR_WIDTH(32'd12)  // 4 KiB
  ) u_xbar (
    .clk (clk),
    .rst (xrst),

    .s00_axi_awid    (s_axi_awid),
    .s00_axi_awaddr  (s_axi_awaddr),
    .s00_axi_awlen   (s_axi_awlen),
    .s00_axi_awsize  (s_axi_awsize),
    .s00_axi_awburst (s_axi_awburst),
    .s00_axi_awlock  (1'b0),
    .s00_axi_awcache (4'b0),
    .s00_axi_awprot  (3'b0),
    .s00_axi_awqos   (4'b0),
    .s00_axi_awuser  (1'b0),
    .s00_axi_awvalid (s_axi_awvalid),
    .s00_axi_awready (s_axi_awready),
    .s00_axi_wdata   (s_axi_wdata),
    .s00_axi_wstrb   (s_axi_wstrb),
    .s00_axi_wlast   (s_axi_wlast),
    .s00_axi_wuser   (1'b0),
    .s00_axi_wvalid  (s_axi_wvalid),
    .s00_axi_wready  (s_axi_wready),
    .s00_axi_bid     (s_axi_bid),
    .s00_axi_bresp   (s_axi_bresp),
    .s00_axi_buser   (),
    .s00_axi_bvalid  (s_axi_bvalid),
    .s00_axi_bready  (s_axi_bready),
    .s00_axi_arid    (s_axi_arid),
    .s00_axi_araddr  (s_axi_araddr),
    .s00_axi_arlen   (s_axi_arlen),
    .s00_axi_arsize  (s_axi_arsize),
    .s00_axi_arburst (s_axi_arburst),
    .s00_axi_arlock  (1'b0),
    .s00_axi_arcache (4'b0),
    .s00_axi_arprot  (3'b0),
    .s00_axi_arqos   (4'b0),
    .s00_axi_aruser  (1'b0),
    .s00_axi_arvalid (s_axi_arvalid),
    .s00_axi_arready (s_axi_arready),
    .s00_axi_rid     (s_axi_rid),
    .s00_axi_rdata   (s_axi_rdata),
    .s00_axi_rresp   (s_axi_rresp),
    .s00_axi_rlast   (s_axi_rlast),
    .s00_axi_ruser   (),
    .s00_axi_rvalid  (s_axi_rvalid),
    .s00_axi_rready  (s_axi_rready),

    .m00_axi_awid    (m_axi_awid[0]),
    .m00_axi_awaddr  (m_axi_awaddr[0]),
    .m00_axi_awlen   (m_axi_awlen[0]),
    .m00_axi_awsize  (m_axi_awsize[0]),
    .m00_axi_awburst (m_axi_awburst[0]),
    .m00_axi_awlock  (),
    .m00_axi_awcache (),
    .m00_axi_awprot  (),
    .m00_axi_awqos   (),
    .m00_axi_awregion(),
    .m00_axi_awuser  (),
    .m00_axi_awvalid (m_axi_awvalid[0]),
    .m00_axi_awready (m_axi_awready[0]),
    .m00_axi_wdata   (m_axi_wdata[0]),
    .m00_axi_wstrb   (m_axi_wstrb[0]),
    .m00_axi_wlast   (m_axi_wlast[0]),
    .m00_axi_wuser   (),
    .m00_axi_wvalid  (m_axi_wvalid[0]),
    .m00_axi_wready  (m_axi_wready[0]),
    .m00_axi_bid     (m_axi_bid[0]),
    .m00_axi_bresp   (m_axi_bresp[0]),
    .m00_axi_buser   (1'b0),
    .m00_axi_bvalid  (m_axi_bvalid[0]),
    .m00_axi_bready  (m_axi_bready[0]),
    .m00_axi_arid    (m_axi_arid[0]),
    .m00_axi_araddr  (m_axi_araddr[0]),
    .m00_axi_arlen   (m_axi_arlen[0]),
    .m00_axi_arsize  (m_axi_arsize[0]),
    .m00_axi_arburst (m_axi_arburst[0]),
    .m00_axi_arlock  (),
    .m00_axi_arcache (),
    .m00_axi_arprot  (),
    .m00_axi_arqos   (),
    .m00_axi_arregion(),
    .m00_axi_aruser  (),
    .m00_axi_arvalid (m_axi_arvalid[0]),
    .m00_axi_arready (m_axi_arready[0]),
    .m00_axi_rid     (m_axi_rid[0]),
    .m00_axi_rdata   (m_axi_rdata[0]),
    .m00_axi_rresp   (m_axi_rresp[0]),
    .m00_axi_rlast   (m_axi_rlast[0]),
    .m00_axi_ruser   (1'b0),
    .m00_axi_rvalid  (m_axi_rvalid[0]),
    .m00_axi_rready  (m_axi_rready[0]),

    .m01_axi_awid    (m_axi_awid[1]),
    .m01_axi_awaddr  (m_axi_awaddr[1]),
    .m01_axi_awlen   (m_axi_awlen[1]),
    .m01_axi_awsize  (m_axi_awsize[1]),
    .m01_axi_awburst (m_axi_awburst[1]),
    .m01_axi_awlock  (),
    .m01_axi_awcache (),
    .m01_axi_awprot  (),
    .m01_axi_awqos   (),
    .m01_axi_awregion(),
    .m01_axi_awuser  (),
    .m01_axi_awvalid (m_axi_awvalid[1]),
    .m01_axi_awready (m_axi_awready[1]),
    .m01_axi_wdata   (m_axi_wdata[1]),
    .m01_axi_wstrb   (m_axi_wstrb[1]),
    .m01_axi_wlast   (m_axi_wlast[1]),
    .m01_axi_wuser   (),
    .m01_axi_wvalid  (m_axi_wvalid[1]),
    .m01_axi_wready  (m_axi_wready[1]),
    .m01_axi_bid     (m_axi_bid[1]),
    .m01_axi_bresp   (m_axi_bresp[1]),
    .m01_axi_buser   (1'b0),
    .m01_axi_bvalid  (m_axi_bvalid[1]),
    .m01_axi_bready  (m_axi_bready[1]),
    .m01_axi_arid    (m_axi_arid[1]),
    .m01_axi_araddr  (m_axi_araddr[1]),
    .m01_axi_arlen   (m_axi_arlen[1]),
    .m01_axi_arsize  (m_axi_arsize[1]),
    .m01_axi_arburst (m_axi_arburst[1]),
    .m01_axi_arlock  (),
    .m01_axi_arcache (),
    .m01_axi_arprot  (),
    .m01_axi_arqos   (),
    .m01_axi_arregion(),
    .m01_axi_aruser  (),
    .m01_axi_arvalid (m_axi_arvalid[1]),
    .m01_axi_arready (m_axi_arready[1]),
    .m01_axi_rid     (m_axi_rid[1]),
    .m01_axi_rdata   (m_axi_rdata[1]),
    .m01_axi_rresp   (m_axi_rresp[1]),
    .m01_axi_rlast   (m_axi_rlast[1]),
    .m01_axi_ruser   (1'b0),
    .m01_axi_rvalid  (m_axi_rvalid[1]),
    .m01_axi_rready  (m_axi_rready[1]),

    .m02_axi_awid    (m_axi_awid[2]),
    .m02_axi_awaddr  (m_axi_awaddr[2]),
    .m02_axi_awlen   (m_axi_awlen[2]),
    .m02_axi_awsize  (m_axi_awsize[2]),
    .m02_axi_awburst (m_axi_awburst[2]),
    .m02_axi_awlock  (),
    .m02_axi_awcache (),
    .m02_axi_awprot  (),
    .m02_axi_awqos   (),
    .m02_axi_awregion(),
    .m02_axi_awuser  (),
    .m02_axi_awvalid (m_axi_awvalid[2]),
    .m02_axi_awready (m_axi_awready[2]),
    .m02_axi_wdata   (m_axi_wdata[2]),
    .m02_axi_wstrb   (m_axi_wstrb[2]),
    .m02_axi_wlast   (m_axi_wlast[2]),
    .m02_axi_wuser   (),
    .m02_axi_wvalid  (m_axi_wvalid[2]),
    .m02_axi_wready  (m_axi_wready[2]),
    .m02_axi_bid     (m_axi_bid[2]),
    .m02_axi_bresp   (m_axi_bresp[2]),
    .m02_axi_buser   (1'b0),
    .m02_axi_bvalid  (m_axi_bvalid[2]),
    .m02_axi_bready  (m_axi_bready[2]),
    .m02_axi_arid    (m_axi_arid[2]),
    .m02_axi_araddr  (m_axi_araddr[2]),
    .m02_axi_arlen   (m_axi_arlen[2]),
    .m02_axi_arsize  (m_axi_arsize[2]),
    .m02_axi_arburst (m_axi_arburst[2]),
    .m02_axi_arlock  (),
    .m02_axi_arcache (),
    .m02_axi_arprot  (),
    .m02_axi_arqos   (),
    .m02_axi_arregion(),
    .m02_axi_aruser  (),
    .m02_axi_arvalid (m_axi_arvalid[2]),
    .m02_axi_arready (m_axi_arready[2]),
    .m02_axi_rid     (m_axi_rid[2]),
    .m02_axi_rdata   (m_axi_rdata[2]),
    .m02_axi_rresp   (m_axi_rresp[2]),
    .m02_axi_rlast   (m_axi_rlast[2]),
    .m02_axi_ruser   (1'b0),
    .m02_axi_rvalid  (m_axi_rvalid[2]),
    .m02_axi_rready  (m_axi_rready[2]),

    .m03_axi_awid    (m_axi_awid[3]),
    .m03_axi_awaddr  (m_axi_awaddr[3]),
    .m03_axi_awlen   (m_axi_awlen[3]),
    .m03_axi_awsize  (m_axi_awsize[3]),
    .m03_axi_awburst (m_axi_awburst[3]),
    .m03_axi_awlock  (),
    .m03_axi_awcache (),
    .m03_axi_awprot  (),
    .m03_axi_awqos   (),
    .m03_axi_awregion(),
    .m03_axi_awuser  (),
    .m03_axi_awvalid (m_axi_awvalid[3]),
    .m03_axi_awready (m_axi_awready[3]),
    .m03_axi_wdata   (m_axi_wdata[3]),
    .m03_axi_wstrb   (m_axi_wstrb[3]),
    .m03_axi_wlast   (m_axi_wlast[3]),
    .m03_axi_wuser   (),
    .m03_axi_wvalid  (m_axi_wvalid[3]),
    .m03_axi_wready  (m_axi_wready[3]),
    .m03_axi_bid     (m_axi_bid[3]),
    .m03_axi_bresp   (m_axi_bresp[3]),
    .m03_axi_buser   (1'b0),
    .m03_axi_bvalid  (m_axi_bvalid[3]),
    .m03_axi_bready  (m_axi_bready[3]),
    .m03_axi_arid    (m_axi_arid[3]),
    .m03_axi_araddr  (m_axi_araddr[3]),
    .m03_axi_arlen   (m_axi_arlen[3]),
    .m03_axi_arsize  (m_axi_arsize[3]),
    .m03_axi_arburst (m_axi_arburst[3]),
    .m03_axi_arlock  (),
    .m03_axi_arcache (),
    .m03_axi_arprot  (),
    .m03_axi_arqos   (),
    .m03_axi_arregion(),
    .m03_axi_aruser  (),
    .m03_axi_arvalid (m_axi_arvalid[3]),
    .m03_axi_arready (m_axi_arready[3]),
    .m03_axi_rid     (m_axi_rid[3]),
    .m03_axi_rdata   (m_axi_rdata[3]),
    .m03_axi_rresp   (m_axi_rresp[3]),
    .m03_axi_rlast   (m_axi_rlast[3]),
    .m03_axi_ruser   (1'b0),
    .m03_axi_rvalid  (m_axi_rvalid[3]),
    .m03_axi_rready  (m_axi_rready[3])
  );

  // m00: RAM
  axi_ram #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .ID_WIDTH   (ID_WIDTH),
    .MEM_BYTES  (soc_pkg::RAM_BYTES)
  ) u_ram (
    .clk           (clk),
    .aresetn       (aresetn),
    .s_axi_awid    (m_axi_awid[0]),
    .s_axi_awaddr  (m_axi_awaddr[0]),
    .s_axi_awlen   (m_axi_awlen[0]),
    .s_axi_awsize  (m_axi_awsize[0]),
    .s_axi_awburst (m_axi_awburst[0]),
    .s_axi_awvalid (m_axi_awvalid[0]),
    .s_axi_awready (m_axi_awready[0]),
    .s_axi_wdata   (m_axi_wdata[0]),
    .s_axi_wstrb   (m_axi_wstrb[0]),
    .s_axi_wlast   (m_axi_wlast[0]),
    .s_axi_wvalid  (m_axi_wvalid[0]),
    .s_axi_wready  (m_axi_wready[0]),
    .s_axi_bid     (m_axi_bid[0]),
    .s_axi_bresp   (m_axi_bresp[0]),
    .s_axi_bvalid  (m_axi_bvalid[0]),
    .s_axi_bready  (m_axi_bready[0]),
    .s_axi_arid    (m_axi_arid[0]),
    .s_axi_araddr  (m_axi_araddr[0]),
    .s_axi_arlen   (m_axi_arlen[0]),
    .s_axi_arsize  (m_axi_arsize[0]),
    .s_axi_arburst (m_axi_arburst[0]),
    .s_axi_arvalid (m_axi_arvalid[0]),
    .s_axi_arready (m_axi_arready[0]),
    .s_axi_rid     (m_axi_rid[0]),
    .s_axi_rdata   (m_axi_rdata[0]),
    .s_axi_rresp   (m_axi_rresp[0]),
    .s_axi_rlast   (m_axi_rlast[0]),
    .s_axi_rvalid  (m_axi_rvalid[0]),
    .s_axi_rready  (m_axi_rready[0])
  );

  // m01: UART
  uart_wrapper #(
    .ID_WIDTH   (ID_WIDTH),
    .ADDR_WIDTH (ADDR_WIDTH)
  ) u_uart (
    .clk           (clk),
    .aresetn       (aresetn),
    .s_axi_awid    (m_axi_awid[1]),
    .s_axi_awaddr  (m_axi_awaddr[1]),
    .s_axi_awlen   (m_axi_awlen[1]),
    .s_axi_awsize  (m_axi_awsize[1]),
    .s_axi_awburst (m_axi_awburst[1]),
    .s_axi_awvalid (m_axi_awvalid[1]),
    .s_axi_awready (m_axi_awready[1]),
    .s_axi_wdata   (m_axi_wdata[1]),
    .s_axi_wstrb   (m_axi_wstrb[1]),
    .s_axi_wvalid  (m_axi_wvalid[1]),
    .s_axi_wready  (m_axi_wready[1]),
    .s_axi_bid     (m_axi_bid[1]),
    .s_axi_bresp   (m_axi_bresp[1]),
    .s_axi_bvalid  (m_axi_bvalid[1]),
    .s_axi_bready  (m_axi_bready[1]),
    .s_axi_arid    (m_axi_arid[1]),
    .s_axi_araddr  (m_axi_araddr[1]),
    .s_axi_arlen   (m_axi_arlen[1]),
    .s_axi_arsize  (m_axi_arsize[1]),
    .s_axi_arburst (m_axi_arburst[1]),
    .s_axi_arvalid (m_axi_arvalid[1]),
    .s_axi_arready (m_axi_arready[1]),
    .s_axi_rid     (m_axi_rid[1]),
    .s_axi_rdata   (m_axi_rdata[1]),
    .s_axi_rresp   (m_axi_rresp[1]),
    .s_axi_rvalid  (m_axi_rvalid[1]),
    .s_axi_rready  (m_axi_rready[1]),
    .uart_rx_i     (uart_rx_i),
    .uart_tx_o     (uart_tx_o),
    .uart_irq_o    (uart_irq_o)
  );

  // m02: Timer
  timer_wrapper #(
    .ID_WIDTH   (ID_WIDTH),
    .ADDR_WIDTH (ADDR_WIDTH)
  ) u_timer (
    .clk           (clk),
    .aresetn       (aresetn),
    .s_axi_awid    (m_axi_awid[2]),
    .s_axi_awaddr  (m_axi_awaddr[2]),
    .s_axi_awlen   (m_axi_awlen[2]),
    .s_axi_awsize  (m_axi_awsize[2]),
    .s_axi_awburst (m_axi_awburst[2]),
    .s_axi_awvalid (m_axi_awvalid[2]),
    .s_axi_awready (m_axi_awready[2]),
    .s_axi_wdata   (m_axi_wdata[2]),
    .s_axi_wstrb   (m_axi_wstrb[2]),
    .s_axi_wvalid  (m_axi_wvalid[2]),
    .s_axi_wready  (m_axi_wready[2]),
    .s_axi_bid     (m_axi_bid[2]),
    .s_axi_bresp   (m_axi_bresp[2]),
    .s_axi_bvalid  (m_axi_bvalid[2]),
    .s_axi_bready  (m_axi_bready[2]),
    .s_axi_arid    (m_axi_arid[2]),
    .s_axi_araddr  (m_axi_araddr[2]),
    .s_axi_arlen   (m_axi_arlen[2]),
    .s_axi_arsize  (m_axi_arsize[2]),
    .s_axi_arburst (m_axi_arburst[2]),
    .s_axi_arvalid (m_axi_arvalid[2]),
    .s_axi_arready (m_axi_arready[2]),
    .s_axi_rid     (m_axi_rid[2]),
    .s_axi_rdata   (m_axi_rdata[2]),
    .s_axi_rresp   (m_axi_rresp[2]),
    .s_axi_rvalid  (m_axi_rvalid[2]),
    .s_axi_rready  (m_axi_rready[2]),
    .irq_o         (timer_irq_o)
  );

  // m03: GPIO
  gpio_wrapper #(
    .ID_WIDTH   (ID_WIDTH),
    .ADDR_WIDTH (ADDR_WIDTH),
    .WIDTH      (soc_pkg::GPIO_WIDTH)
  ) u_gpio (
    .clk           (clk),
    .aresetn       (aresetn),
    .s_axi_awid    (m_axi_awid[3]),
    .s_axi_awaddr  (m_axi_awaddr[3]),
    .s_axi_awlen   (m_axi_awlen[3]),
    .s_axi_awsize  (m_axi_awsize[3]),
    .s_axi_awburst (m_axi_awburst[3]),
    .s_axi_awvalid (m_axi_awvalid[3]),
    .s_axi_awready (m_axi_awready[3]),
    .s_axi_wdata   (m_axi_wdata[3]),
    .s_axi_wstrb   (m_axi_wstrb[3]),
    .s_axi_wvalid  (m_axi_wvalid[3]),
    .s_axi_wready  (m_axi_wready[3]),
    .s_axi_bid     (m_axi_bid[3]),
    .s_axi_bresp   (m_axi_bresp[3]),
    .s_axi_bvalid  (m_axi_bvalid[3]),
    .s_axi_bready  (m_axi_bready[3]),
    .s_axi_arid    (m_axi_arid[3]),
    .s_axi_araddr  (m_axi_araddr[3]),
    .s_axi_arlen   (m_axi_arlen[3]),
    .s_axi_arsize  (m_axi_arsize[3]),
    .s_axi_arburst (m_axi_arburst[3]),
    .s_axi_arvalid (m_axi_arvalid[3]),
    .s_axi_arready (m_axi_arready[3]),
    .s_axi_rid     (m_axi_rid[3]),
    .s_axi_rdata   (m_axi_rdata[3]),
    .s_axi_rresp   (m_axi_rresp[3]),
    .s_axi_rvalid  (m_axi_rvalid[3]),
    .s_axi_rready  (m_axi_rready[3]),
    .gpio_in       (gpio_in),
    .gpio_out      (gpio_out)
  );

endmodule

`resetall
