// =============================================================================
// honours_soc.sv — SoC TOP. Instantiate only. No behavioral logic.
//
// Phase 2: 2-master × 7-slave AXI4 interconnect.
//   M0 = CPU (via width adapter or BFM), M1 = NDA read engine
//   S0=RAM, S1=UART, S2=Timer, S3=GPIO, S4=NDA CSR, S5=WDT CSR, S6=HPM CSR
//
// Sideband signals (not part of AXI transactions):
//   nda_busy/progress → WDT, wdt_abort → NDA, wdt_trip → HPM,
//   tap wires from M0/M1 → HPM.
//
// Reset: active-low aresetn in; interconnect active-high rst derived here.
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

  // --- CPU master-facing AXI4 port (M0) ---
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
  output wire [soc_pkg::GPIO_WIDTH-1:0] gpio_out,
  // NDA interrupt
  output wire                  nda_irq_o,
  // WDT interrupt
  output wire                  wdt_irq_o
);

  wire xrst; // interconnect active-high reset, converted at boundary
  assign xrst = ~aresetn;

  // ===========================================================================
  // Interconnect slave-facing master ports (m00=RAM ... m06=HPM CSR)
  // ===========================================================================
  // S_COUNT=2, M_COUNT=7 (or 6 when ENABLE_HPM=0)
  localparam int unsigned NS = NUM_SLAVES;

  wire [ID_WIDTH-1:0]   m_axi_awid   [0:6];
  wire [ADDR_WIDTH-1:0] m_axi_awaddr [0:6];
  wire [7:0]            m_axi_awlen  [0:6];
  wire [2:0]            m_axi_awsize [0:6];
  wire [1:0]            m_axi_awburst[0:6];
  wire                  m_axi_awvalid[0:6];
  wire                  m_axi_awready[0:6];
  wire [DATA_WIDTH-1:0] m_axi_wdata  [0:6];
  wire [DATA_WIDTH/8-1:0] m_axi_wstrb[0:6];
  wire                  m_axi_wlast  [0:6];
  wire                  m_axi_wvalid [0:6];
  wire                  m_axi_wready [0:6];
  wire [ID_WIDTH-1:0]   m_axi_bid    [0:6];
  wire [1:0]            m_axi_bresp  [0:6];
  wire                  m_axi_bvalid [0:6];
  wire                  m_axi_bready [0:6];
  wire [ID_WIDTH-1:0]   m_axi_arid   [0:6];
  wire [ADDR_WIDTH-1:0] m_axi_araddr [0:6];
  wire [7:0]            m_axi_arlen  [0:6];
  wire [2:0]            m_axi_arsize [0:6];
  wire [1:0]            m_axi_arburst[0:6];
  wire                  m_axi_arvalid[0:6];
  wire                  m_axi_arready[0:6];
  wire [ID_WIDTH-1:0]   m_axi_rid    [0:6];
  wire [DATA_WIDTH-1:0] m_axi_rdata  [0:6];
  wire [1:0]            m_axi_rresp  [0:6];
  wire                  m_axi_rlast  [0:6];
  wire                  m_axi_rvalid [0:6];
  wire                  m_axi_rready [0:6];

  // Single-beat slaves (UART, Timer, GPIO, NDA CSR, WDT CSR, HPM CSR) have
  // no RLAST port — tie high so the interconnect retires reads on first beat.
  assign m_axi_rlast[1] = 1'b1; // UART
  assign m_axi_rlast[2] = 1'b1; // Timer
  assign m_axi_rlast[3] = 1'b1; // GPIO
  assign m_axi_rlast[4] = 1'b1; // NDA CSR
  assign m_axi_rlast[5] = 1'b1; // WDT CSR
  assign m_axi_rlast[6] = 1'b1; // HPM CSR

  // ===========================================================================
  // NDA AXI read master → interconnect s01
  // ===========================================================================
  wire [ID_WIDTH-1:0]   nda_arid;
  wire [ADDR_WIDTH-1:0] nda_araddr;
  wire [7:0]            nda_arlen;
  wire [2:0]            nda_arsize;
  wire [1:0]            nda_arburst;
  wire                  nda_arvalid;
  wire                  nda_arready;
  wire [ID_WIDTH-1:0]   nda_rid;
  wire [31:0]           nda_rdata;
  wire [1:0]            nda_rresp;
  wire                  nda_rlast;
  wire                  nda_rvalid;
  wire                  nda_rready;

  // ===========================================================================
  // Sideband wires
  // ===========================================================================
  wire nda_busy_w;
  wire nda_progress_w;
  wire wdt_abort_w;
  wire wdt_trip_w;

  // ===========================================================================
  // Interconnect (2x7 or 2x6 depending on ENABLE_HPM)
  // ===========================================================================
  generate
    if (soc_pkg::ENABLE_HPM) begin : gen_xbar_2x7
      axi_interconnect_wrap_2x7 #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .ID_WIDTH   (ID_WIDTH),
        .M00_BASE_ADDR (soc_pkg::RAM_BASE),
        .M00_ADDR_WIDTH(32'd16),  // 64 KiB
        .M01_BASE_ADDR (soc_pkg::UART_BASE),
        .M01_ADDR_WIDTH(32'd12),
        .M02_BASE_ADDR (soc_pkg::TIMER_BASE),
        .M02_ADDR_WIDTH(32'd12),
        .M03_BASE_ADDR (soc_pkg::GPIO_BASE),
        .M03_ADDR_WIDTH(32'd12),
        .M04_BASE_ADDR (soc_pkg::NDA_BASE),
        .M04_ADDR_WIDTH(32'd12),
        .M05_BASE_ADDR (soc_pkg::WDT_BASE),
        .M05_ADDR_WIDTH(32'd12),
        .M06_BASE_ADDR (soc_pkg::HPM_BASE),
        .M06_ADDR_WIDTH(32'd12)
      ) u_xbar (
        .clk (clk),
        .rst (xrst),

        // S00: CPU master
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

        // S01: NDA master
        .s01_axi_awid    ({ID_WIDTH{1'b0}}),
        .s01_axi_awaddr  ({ADDR_WIDTH{1'b0}}),
        .s01_axi_awlen   (8'd0),
        .s01_axi_awsize  (3'd0),
        .s01_axi_awburst (2'd0),
        .s01_axi_awlock  (1'b0),
        .s01_axi_awcache (4'b0),
        .s01_axi_awprot  (3'b0),
        .s01_axi_awqos   (4'b0),
        .s01_axi_awuser  (1'b0),
        .s01_axi_awvalid (1'b0),
        .s01_axi_awready (),
        .s01_axi_wdata   ({DATA_WIDTH{1'b0}}),
        .s01_axi_wstrb   ({(DATA_WIDTH/8){1'b0}}),
        .s01_axi_wlast   (1'b0),
        .s01_axi_wuser   (1'b0),
        .s01_axi_wvalid  (1'b0),
        .s01_axi_wready  (),
        .s01_axi_bid     (),
        .s01_axi_bresp   (),
        .s01_axi_buser   (),
        .s01_axi_bvalid  (),
        .s01_axi_bready  (1'b1),
        .s01_axi_arid    (nda_arid),
        .s01_axi_araddr  (nda_araddr),
        .s01_axi_arlen   (nda_arlen),
        .s01_axi_arsize  (nda_arsize),
        .s01_axi_arburst (nda_arburst),
        .s01_axi_arlock  (1'b0),
        .s01_axi_arcache (4'b0),
        .s01_axi_arprot  (3'b0),
        .s01_axi_arqos   (4'b0),
        .s01_axi_aruser  (1'b0),
        .s01_axi_arvalid (nda_arvalid),
        .s01_axi_arready (nda_arready),
        .s01_axi_rid     (nda_rid),
        .s01_axi_rdata   (nda_rdata),
        .s01_axi_rresp   (nda_rresp),
        .s01_axi_rlast   (nda_rlast),
        .s01_axi_ruser   (),
        .s01_axi_rvalid  (nda_rvalid),
        .s01_axi_rready  (nda_rready),

        // M00: RAM
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

        // M01: UART
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

        // M02: Timer
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

        // M03: GPIO
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
        .m03_axi_rready  (m_axi_rready[3]),

        // M04: NDA CSR
        .m04_axi_awid    (m_axi_awid[4]),
        .m04_axi_awaddr  (m_axi_awaddr[4]),
        .m04_axi_awlen   (m_axi_awlen[4]),
        .m04_axi_awsize  (m_axi_awsize[4]),
        .m04_axi_awburst (m_axi_awburst[4]),
        .m04_axi_awlock  (),
        .m04_axi_awcache (),
        .m04_axi_awprot  (),
        .m04_axi_awqos   (),
        .m04_axi_awregion(),
        .m04_axi_awuser  (),
        .m04_axi_awvalid (m_axi_awvalid[4]),
        .m04_axi_awready (m_axi_awready[4]),
        .m04_axi_wdata   (m_axi_wdata[4]),
        .m04_axi_wstrb   (m_axi_wstrb[4]),
        .m04_axi_wlast   (m_axi_wlast[4]),
        .m04_axi_wuser   (),
        .m04_axi_wvalid  (m_axi_wvalid[4]),
        .m04_axi_wready  (m_axi_wready[4]),
        .m04_axi_bid     (m_axi_bid[4]),
        .m04_axi_bresp   (m_axi_bresp[4]),
        .m04_axi_buser   (1'b0),
        .m04_axi_bvalid  (m_axi_bvalid[4]),
        .m04_axi_bready  (m_axi_bready[4]),
        .m04_axi_arid    (m_axi_arid[4]),
        .m04_axi_araddr  (m_axi_araddr[4]),
        .m04_axi_arlen   (m_axi_arlen[4]),
        .m04_axi_arsize  (m_axi_arsize[4]),
        .m04_axi_arburst (m_axi_arburst[4]),
        .m04_axi_arlock  (),
        .m04_axi_arcache (),
        .m04_axi_arprot  (),
        .m04_axi_arqos   (),
        .m04_axi_arregion(),
        .m04_axi_aruser  (),
        .m04_axi_arvalid (m_axi_arvalid[4]),
        .m04_axi_arready (m_axi_arready[4]),
        .m04_axi_rid     (m_axi_rid[4]),
        .m04_axi_rdata   (m_axi_rdata[4]),
        .m04_axi_rresp   (m_axi_rresp[4]),
        .m04_axi_rlast   (m_axi_rlast[4]),
        .m04_axi_ruser   (1'b0),
        .m04_axi_rvalid  (m_axi_rvalid[4]),
        .m04_axi_rready  (m_axi_rready[4]),

        // M05: WDT CSR
        .m05_axi_awid    (m_axi_awid[5]),
        .m05_axi_awaddr  (m_axi_awaddr[5]),
        .m05_axi_awlen   (m_axi_awlen[5]),
        .m05_axi_awsize  (m_axi_awsize[5]),
        .m05_axi_awburst (m_axi_awburst[5]),
        .m05_axi_awlock  (),
        .m05_axi_awcache (),
        .m05_axi_awprot  (),
        .m05_axi_awqos   (),
        .m05_axi_awregion(),
        .m05_axi_awuser  (),
        .m05_axi_awvalid (m_axi_awvalid[5]),
        .m05_axi_awready (m_axi_awready[5]),
        .m05_axi_wdata   (m_axi_wdata[5]),
        .m05_axi_wstrb   (m_axi_wstrb[5]),
        .m05_axi_wlast   (m_axi_wlast[5]),
        .m05_axi_wuser   (),
        .m05_axi_wvalid  (m_axi_wvalid[5]),
        .m05_axi_wready  (m_axi_wready[5]),
        .m05_axi_bid     (m_axi_bid[5]),
        .m05_axi_bresp   (m_axi_bresp[5]),
        .m05_axi_buser   (1'b0),
        .m05_axi_bvalid  (m_axi_bvalid[5]),
        .m05_axi_bready  (m_axi_bready[5]),
        .m05_axi_arid    (m_axi_arid[5]),
        .m05_axi_araddr  (m_axi_araddr[5]),
        .m05_axi_arlen   (m_axi_arlen[5]),
        .m05_axi_arsize  (m_axi_arsize[5]),
        .m05_axi_arburst (m_axi_arburst[5]),
        .m05_axi_arlock  (),
        .m05_axi_arcache (),
        .m05_axi_arprot  (),
        .m05_axi_arqos   (),
        .m05_axi_arregion(),
        .m05_axi_aruser  (),
        .m05_axi_arvalid (m_axi_arvalid[5]),
        .m05_axi_arready (m_axi_arready[5]),
        .m05_axi_rid     (m_axi_rid[5]),
        .m05_axi_rdata   (m_axi_rdata[5]),
        .m05_axi_rresp   (m_axi_rresp[5]),
        .m05_axi_rlast   (m_axi_rlast[5]),
        .m05_axi_ruser   (1'b0),
        .m05_axi_rvalid  (m_axi_rvalid[5]),
        .m05_axi_rready  (m_axi_rready[5]),

        // M06: HPM CSR
        .m06_axi_awid    (m_axi_awid[6]),
        .m06_axi_awaddr  (m_axi_awaddr[6]),
        .m06_axi_awlen   (m_axi_awlen[6]),
        .m06_axi_awsize  (m_axi_awsize[6]),
        .m06_axi_awburst (m_axi_awburst[6]),
        .m06_axi_awlock  (),
        .m06_axi_awcache (),
        .m06_axi_awprot  (),
        .m06_axi_awqos   (),
        .m06_axi_awregion(),
        .m06_axi_awuser  (),
        .m06_axi_awvalid (m_axi_awvalid[6]),
        .m06_axi_awready (m_axi_awready[6]),
        .m06_axi_wdata   (m_axi_wdata[6]),
        .m06_axi_wstrb   (m_axi_wstrb[6]),
        .m06_axi_wlast   (m_axi_wlast[6]),
        .m06_axi_wuser   (),
        .m06_axi_wvalid  (m_axi_wvalid[6]),
        .m06_axi_wready  (m_axi_wready[6]),
        .m06_axi_bid     (m_axi_bid[6]),
        .m06_axi_bresp   (m_axi_bresp[6]),
        .m06_axi_buser   (1'b0),
        .m06_axi_bvalid  (m_axi_bvalid[6]),
        .m06_axi_bready  (m_axi_bready[6]),
        .m06_axi_arid    (m_axi_arid[6]),
        .m06_axi_araddr  (m_axi_araddr[6]),
        .m06_axi_arlen   (m_axi_arlen[6]),
        .m06_axi_arsize  (m_axi_arsize[6]),
        .m06_axi_arburst (m_axi_arburst[6]),
        .m06_axi_arlock  (),
        .m06_axi_arcache (),
        .m06_axi_arprot  (),
        .m06_axi_arqos   (),
        .m06_axi_arregion(),
        .m06_axi_aruser  (),
        .m06_axi_arvalid (m_axi_arvalid[6]),
        .m06_axi_arready (m_axi_arready[6]),
        .m06_axi_rid     (m_axi_rid[6]),
        .m06_axi_rdata   (m_axi_rdata[6]),
        .m06_axi_rresp   (m_axi_rresp[6]),
        .m06_axi_rlast   (m_axi_rlast[6]),
        .m06_axi_ruser   (1'b0),
        .m06_axi_rvalid  (m_axi_rvalid[6]),
        .m06_axi_rready  (m_axi_rready[6])
      );
    end else begin : gen_xbar_2x6
      // ENABLE_HPM=0: 2x6 interconnect (no HPM port)
      axi_interconnect_wrap_2x6 #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .ID_WIDTH   (ID_WIDTH),
        .M00_BASE_ADDR (soc_pkg::RAM_BASE),
        .M00_ADDR_WIDTH(32'd16),
        .M01_BASE_ADDR (soc_pkg::UART_BASE),
        .M01_ADDR_WIDTH(32'd12),
        .M02_BASE_ADDR (soc_pkg::TIMER_BASE),
        .M02_ADDR_WIDTH(32'd12),
        .M03_BASE_ADDR (soc_pkg::GPIO_BASE),
        .M03_ADDR_WIDTH(32'd12),
        .M04_BASE_ADDR (soc_pkg::NDA_BASE),
        .M04_ADDR_WIDTH(32'd12),
        .M05_BASE_ADDR (soc_pkg::WDT_BASE),
        .M05_ADDR_WIDTH(32'd12)
      ) u_xbar (
        .clk (clk),
        .rst (xrst),

        // S00: CPU master
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

        // S01: NDA master
        .s01_axi_awid    ({ID_WIDTH{1'b0}}),
        .s01_axi_awaddr  ({ADDR_WIDTH{1'b0}}),
        .s01_axi_awlen   (8'd0),
        .s01_axi_awsize  (3'd0),
        .s01_axi_awburst (2'd0),
        .s01_axi_awlock  (1'b0),
        .s01_axi_awcache (4'b0),
        .s01_axi_awprot  (3'b0),
        .s01_axi_awqos   (4'b0),
        .s01_axi_awuser  (1'b0),
        .s01_axi_awvalid (1'b0),
        .s01_axi_awready (),
        .s01_axi_wdata   ({DATA_WIDTH{1'b0}}),
        .s01_axi_wstrb   ({(DATA_WIDTH/8){1'b0}}),
        .s01_axi_wlast   (1'b0),
        .s01_axi_wuser   (1'b0),
        .s01_axi_wvalid  (1'b0),
        .s01_axi_wready  (),
        .s01_axi_bid     (),
        .s01_axi_bresp   (),
        .s01_axi_buser   (),
        .s01_axi_bvalid  (),
        .s01_axi_bready  (1'b1),
        .s01_axi_arid    (nda_arid),
        .s01_axi_araddr  (nda_araddr),
        .s01_axi_arlen   (nda_arlen),
        .s01_axi_arsize  (nda_arsize),
        .s01_axi_arburst (nda_arburst),
        .s01_axi_arlock  (1'b0),
        .s01_axi_arcache (4'b0),
        .s01_axi_arprot  (3'b0),
        .s01_axi_arqos   (4'b0),
        .s01_axi_aruser  (1'b0),
        .s01_axi_arvalid (nda_arvalid),
        .s01_axi_arready (nda_arready),
        .s01_axi_rid     (nda_rid),
        .s01_axi_rdata   (nda_rdata),
        .s01_axi_rresp   (nda_rresp),
        .s01_axi_rlast   (nda_rlast),
        .s01_axi_ruser   (),
        .s01_axi_rvalid  (nda_rvalid),
        .s01_axi_rready  (nda_rready),

        // M00: RAM
        .m00_axi_awid    (m_axi_awid[0]),    .m00_axi_awaddr  (m_axi_awaddr[0]),
        .m00_axi_awlen   (m_axi_awlen[0]),  .m00_axi_awsize  (m_axi_awsize[0]),
        .m00_axi_awburst (m_axi_awburst[0]),.m00_axi_awlock  (),.m00_axi_awcache (),
        .m00_axi_awprot  (),.m00_axi_awqos   (),.m00_axi_awregion(),.m00_axi_awuser  (),
        .m00_axi_awvalid (m_axi_awvalid[0]),.m00_axi_awready (m_axi_awready[0]),
        .m00_axi_wdata   (m_axi_wdata[0]),  .m00_axi_wstrb   (m_axi_wstrb[0]),
        .m00_axi_wlast   (m_axi_wlast[0]),  .m00_axi_wuser   (),
        .m00_axi_wvalid  (m_axi_wvalid[0]), .m00_axi_wready  (m_axi_wready[0]),
        .m00_axi_bid     (m_axi_bid[0]),    .m00_axi_bresp   (m_axi_bresp[0]),
        .m00_axi_buser   (1'b0),            .m00_axi_bvalid  (m_axi_bvalid[0]),
        .m00_axi_bready  (m_axi_bready[0]),
        .m00_axi_arid    (m_axi_arid[0]),    .m00_axi_araddr  (m_axi_araddr[0]),
        .m00_axi_arlen   (m_axi_arlen[0]),  .m00_axi_arsize  (m_axi_arsize[0]),
        .m00_axi_arburst (m_axi_arburst[0]),.m00_axi_arlock  (),.m00_axi_arcache (),
        .m00_axi_arprot  (),.m00_axi_arqos   (),.m00_axi_arregion(),.m00_axi_aruser  (),
        .m00_axi_arvalid (m_axi_arvalid[0]),.m00_axi_arready (m_axi_arready[0]),
        .m00_axi_rid     (m_axi_rid[0]),    .m00_axi_rdata   (m_axi_rdata[0]),
        .m00_axi_rresp   (m_axi_rresp[0]),  .m00_axi_rlast   (m_axi_rlast[0]),
        .m00_axi_ruser   (1'b0),            .m00_axi_rvalid  (m_axi_rvalid[0]),
        .m00_axi_rready  (m_axi_rready[0]),

        // M01: UART
        .m01_axi_awid    (m_axi_awid[1]),    .m01_axi_awaddr  (m_axi_awaddr[1]),
        .m01_axi_awlen   (m_axi_awlen[1]),  .m01_axi_awsize  (m_axi_awsize[1]),
        .m01_axi_awburst (m_axi_awburst[1]),.m01_axi_awlock  (),.m01_axi_awcache (),
        .m01_axi_awprot  (),.m01_axi_awqos   (),.m01_axi_awregion(),.m01_axi_awuser  (),
        .m01_axi_awvalid (m_axi_awvalid[1]),.m01_axi_awready (m_axi_awready[1]),
        .m01_axi_wdata   (m_axi_wdata[1]),  .m01_axi_wstrb   (m_axi_wstrb[1]),
        .m01_axi_wlast   (m_axi_wlast[1]),  .m01_axi_wuser   (),
        .m01_axi_wvalid  (m_axi_wvalid[1]), .m01_axi_wready  (m_axi_wready[1]),
        .m01_axi_bid     (m_axi_bid[1]),    .m01_axi_bresp   (m_axi_bresp[1]),
        .m01_axi_buser   (1'b0),            .m01_axi_bvalid  (m_axi_bvalid[1]),
        .m01_axi_bready  (m_axi_bready[1]),
        .m01_axi_arid    (m_axi_arid[1]),    .m01_axi_araddr  (m_axi_araddr[1]),
        .m01_axi_arlen   (m_axi_arlen[1]),  .m01_axi_arsize  (m_axi_arsize[1]),
        .m01_axi_arburst (m_axi_arburst[1]),.m01_axi_arlock  (),.m01_axi_arcache (),
        .m01_axi_arprot  (),.m01_axi_arqos   (),.m01_axi_arregion(),.m01_axi_aruser  (),
        .m01_axi_arvalid (m_axi_arvalid[1]),.m01_axi_arready (m_axi_arready[1]),
        .m01_axi_rid     (m_axi_rid[1]),    .m01_axi_rdata   (m_axi_rdata[1]),
        .m01_axi_rresp   (m_axi_rresp[1]),  .m01_axi_rlast   (m_axi_rlast[1]),
        .m01_axi_ruser   (1'b0),            .m01_axi_rvalid  (m_axi_rvalid[1]),
        .m01_axi_rready  (m_axi_rready[1]),

        // M02: Timer
        .m02_axi_awid    (m_axi_awid[2]),    .m02_axi_awaddr  (m_axi_awaddr[2]),
        .m02_axi_awlen   (m_axi_awlen[2]),  .m02_axi_awsize  (m_axi_awsize[2]),
        .m02_axi_awburst (m_axi_awburst[2]),.m02_axi_awlock  (),.m02_axi_awcache (),
        .m02_axi_awprot  (),.m02_axi_awqos   (),.m02_axi_awregion(),.m02_axi_awuser  (),
        .m02_axi_awvalid (m_axi_awvalid[2]),.m02_axi_awready (m_axi_awready[2]),
        .m02_axi_wdata   (m_axi_wdata[2]),  .m02_axi_wstrb   (m_axi_wstrb[2]),
        .m02_axi_wlast   (m_axi_wlast[2]),  .m02_axi_wuser   (),
        .m02_axi_wvalid  (m_axi_wvalid[2]), .m02_axi_wready  (m_axi_wready[2]),
        .m02_axi_bid     (m_axi_bid[2]),    .m02_axi_bresp   (m_axi_bresp[2]),
        .m02_axi_buser   (1'b0),            .m02_axi_bvalid  (m_axi_bvalid[2]),
        .m02_axi_bready  (m_axi_bready[2]),
        .m02_axi_arid    (m_axi_arid[2]),    .m02_axi_araddr  (m_axi_araddr[2]),
        .m02_axi_arlen   (m_axi_arlen[2]),  .m02_axi_arsize  (m_axi_arsize[2]),
        .m02_axi_arburst (m_axi_arburst[2]),.m02_axi_arlock  (),.m02_axi_arcache (),
        .m02_axi_arprot  (),.m02_axi_arqos   (),.m02_axi_arregion(),.m02_axi_aruser  (),
        .m02_axi_arvalid (m_axi_arvalid[2]),.m02_axi_arready (m_axi_arready[2]),
        .m02_axi_rid     (m_axi_rid[2]),    .m02_axi_rdata   (m_axi_rdata[2]),
        .m02_axi_rresp   (m_axi_rresp[2]),  .m02_axi_rlast   (m_axi_rlast[2]),
        .m02_axi_ruser   (1'b0),            .m02_axi_rvalid  (m_axi_rvalid[2]),
        .m02_axi_rready  (m_axi_rready[2]),

        // M03: GPIO
        .m03_axi_awid    (m_axi_awid[3]),    .m03_axi_awaddr  (m_axi_awaddr[3]),
        .m03_axi_awlen   (m_axi_awlen[3]),  .m03_axi_awsize  (m_axi_awsize[3]),
        .m03_axi_awburst (m_axi_awburst[3]),.m03_axi_awlock  (),.m03_axi_awcache (),
        .m03_axi_awprot  (),.m03_axi_awqos   (),.m03_axi_awregion(),.m03_axi_awuser  (),
        .m03_axi_awvalid (m_axi_awvalid[3]),.m03_axi_awready (m_axi_awready[3]),
        .m03_axi_wdata   (m_axi_wdata[3]),  .m03_axi_wstrb   (m_axi_wstrb[3]),
        .m03_axi_wlast   (m_axi_wlast[3]),  .m03_axi_wuser   (),
        .m03_axi_wvalid  (m_axi_wvalid[3]), .m03_axi_wready  (m_axi_wready[3]),
        .m03_axi_bid     (m_axi_bid[3]),    .m03_axi_bresp   (m_axi_bresp[3]),
        .m03_axi_buser   (1'b0),            .m03_axi_bvalid  (m_axi_bvalid[3]),
        .m03_axi_bready  (m_axi_bready[3]),
        .m03_axi_arid    (m_axi_arid[3]),    .m03_axi_araddr  (m_axi_araddr[3]),
        .m03_axi_arlen   (m_axi_arlen[3]),  .m03_axi_arsize  (m_axi_arsize[3]),
        .m03_axi_arburst (m_axi_arburst[3]),.m03_axi_arlock  (),.m03_axi_arcache (),
        .m03_axi_arprot  (),.m03_axi_arqos   (),.m03_axi_arregion(),.m03_axi_aruser  (),
        .m03_axi_arvalid (m_axi_arvalid[3]),.m03_axi_arready (m_axi_arready[3]),
        .m03_axi_rid     (m_axi_rid[3]),    .m03_axi_rdata   (m_axi_rdata[3]),
        .m03_axi_rresp   (m_axi_rresp[3]),  .m03_axi_rlast   (m_axi_rlast[3]),
        .m03_axi_ruser   (1'b0),            .m03_axi_rvalid  (m_axi_rvalid[3]),
        .m03_axi_rready  (m_axi_rready[3]),

        // M04: NDA CSR
        .m04_axi_awid    (m_axi_awid[4]),    .m04_axi_awaddr  (m_axi_awaddr[4]),
        .m04_axi_awlen   (m_axi_awlen[4]),  .m04_axi_awsize  (m_axi_awsize[4]),
        .m04_axi_awburst (m_axi_awburst[4]),.m04_axi_awlock  (),.m04_axi_awcache (),
        .m04_axi_awprot  (),.m04_axi_awqos   (),.m04_axi_awregion(),.m04_axi_awuser  (),
        .m04_axi_awvalid (m_axi_awvalid[4]),.m04_axi_awready (m_axi_awready[4]),
        .m04_axi_wdata   (m_axi_wdata[4]),  .m04_axi_wstrb   (m_axi_wstrb[4]),
        .m04_axi_wlast   (m_axi_wlast[4]),  .m04_axi_wuser   (),
        .m04_axi_wvalid  (m_axi_wvalid[4]), .m04_axi_wready  (m_axi_wready[4]),
        .m04_axi_bid     (m_axi_bid[4]),    .m04_axi_bresp   (m_axi_bresp[4]),
        .m04_axi_buser   (1'b0),            .m04_axi_bvalid  (m_axi_bvalid[4]),
        .m04_axi_bready  (m_axi_bready[4]),
        .m04_axi_arid    (m_axi_arid[4]),    .m04_axi_araddr  (m_axi_araddr[4]),
        .m04_axi_arlen   (m_axi_arlen[4]),  .m04_axi_arsize  (m_axi_arsize[4]),
        .m04_axi_arburst (m_axi_arburst[4]),.m04_axi_arlock  (),.m04_axi_arcache (),
        .m04_axi_arprot  (),.m04_axi_arqos   (),.m04_axi_arregion(),.m04_axi_aruser  (),
        .m04_axi_arvalid (m_axi_arvalid[4]),.m04_axi_arready (m_axi_arready[4]),
        .m04_axi_rid     (m_axi_rid[4]),    .m04_axi_rdata   (m_axi_rdata[4]),
        .m04_axi_rresp   (m_axi_rresp[4]),  .m04_axi_rlast   (m_axi_rlast[4]),
        .m04_axi_ruser   (1'b0),            .m04_axi_rvalid  (m_axi_rvalid[4]),
        .m04_axi_rready  (m_axi_rready[4]),

        // M05: WDT CSR
        .m05_axi_awid    (m_axi_awid[5]),    .m05_axi_awaddr  (m_axi_awaddr[5]),
        .m05_axi_awlen   (m_axi_awlen[5]),  .m05_axi_awsize  (m_axi_awsize[5]),
        .m05_axi_awburst (m_axi_awburst[5]),.m05_axi_awlock  (),.m05_axi_awcache (),
        .m05_axi_awprot  (),.m05_axi_awqos   (),.m05_axi_awregion(),.m05_axi_awuser  (),
        .m05_axi_awvalid (m_axi_awvalid[5]),.m05_axi_awready (m_axi_awready[5]),
        .m05_axi_wdata   (m_axi_wdata[5]),  .m05_axi_wstrb   (m_axi_wstrb[5]),
        .m05_axi_wlast   (m_axi_wlast[5]),  .m05_axi_wuser   (),
        .m05_axi_wvalid  (m_axi_wvalid[5]), .m05_axi_wready  (m_axi_wready[5]),
        .m05_axi_bid     (m_axi_bid[5]),    .m05_axi_bresp   (m_axi_bresp[5]),
        .m05_axi_buser   (1'b0),            .m05_axi_bvalid  (m_axi_bvalid[5]),
        .m05_axi_bready  (m_axi_bready[5]),
        .m05_axi_arid    (m_axi_arid[5]),    .m05_axi_araddr  (m_axi_araddr[5]),
        .m05_axi_arlen   (m_axi_arlen[5]),  .m05_axi_arsize  (m_axi_arsize[5]),
        .m05_axi_arburst (m_axi_arburst[5]),.m05_axi_arlock  (),.m05_axi_arcache (),
        .m05_axi_arprot  (),.m05_axi_arqos   (),.m05_axi_arregion(),.m05_axi_aruser  (),
        .m05_axi_arvalid (m_axi_arvalid[5]),.m05_axi_arready (m_axi_arready[5]),
        .m05_axi_rid     (m_axi_rid[5]),    .m05_axi_rdata   (m_axi_rdata[5]),
        .m05_axi_rresp   (m_axi_rresp[5]),  .m05_axi_rlast   (m_axi_rlast[5]),
        .m05_axi_ruser   (1'b0),            .m05_axi_rvalid  (m_axi_rvalid[5]),
        .m05_axi_rready  (m_axi_rready[5])
      );
    end
  endgenerate

  // ===========================================================================
  // m00: RAM
  // ===========================================================================
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

  // ===========================================================================
  // m01: UART
  // ===========================================================================
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

  // ===========================================================================
  // m02: Timer
  // ===========================================================================
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

  // ===========================================================================
  // m03: GPIO
  // ===========================================================================
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

  // ===========================================================================
  // m04: NDA (CSR slave + AXI read master)
  // ===========================================================================
  nda_wrapper #(
    .ID_WIDTH   (ID_WIDTH),
    .ADDR_WIDTH (ADDR_WIDTH)
  ) u_nda (
    .clk           (clk),
    .aresetn       (aresetn),

    // CSR slave (from interconnect m04)
    .s_axi_awid    (m_axi_awid[4]),
    .s_axi_awaddr  (m_axi_awaddr[4]),
    .s_axi_awlen   (m_axi_awlen[4]),
    .s_axi_awsize  (m_axi_awsize[4]),
    .s_axi_awburst (m_axi_awburst[4]),
    .s_axi_awvalid (m_axi_awvalid[4]),
    .s_axi_awready (m_axi_awready[4]),
    .s_axi_wdata   (m_axi_wdata[4]),
    .s_axi_wstrb   (m_axi_wstrb[4]),
    .s_axi_wvalid  (m_axi_wvalid[4]),
    .s_axi_wready  (m_axi_wready[4]),
    .s_axi_bid     (m_axi_bid[4]),
    .s_axi_bresp   (m_axi_bresp[4]),
    .s_axi_bvalid  (m_axi_bvalid[4]),
    .s_axi_bready  (m_axi_bready[4]),
    .s_axi_arid    (m_axi_arid[4]),
    .s_axi_araddr  (m_axi_araddr[4]),
    .s_axi_arlen   (m_axi_arlen[4]),
    .s_axi_arsize  (m_axi_arsize[4]),
    .s_axi_arburst (m_axi_arburst[4]),
    .s_axi_arvalid (m_axi_arvalid[4]),
    .s_axi_arready (m_axi_arready[4]),
    .s_axi_rid     (m_axi_rid[4]),
    .s_axi_rdata   (m_axi_rdata[4]),
    .s_axi_rresp   (m_axi_rresp[4]),
    .s_axi_rvalid  (m_axi_rvalid[4]),
    .s_axi_rready  (m_axi_rready[4]),

    // Read master (to interconnect s01)
    .m_axi_arid    (nda_arid),
    .m_axi_araddr  (nda_araddr),
    .m_axi_arlen   (nda_arlen),
    .m_axi_arsize  (nda_arsize),
    .m_axi_arburst (nda_arburst),
    .m_axi_arvalid (nda_arvalid),
    .m_axi_arready (nda_arready),
    .m_axi_rid     (nda_rid),
    .m_axi_rdata   (nda_rdata),
    .m_axi_rresp   (nda_rresp),
    .m_axi_rlast   (nda_rlast),
    .m_axi_rvalid  (nda_rvalid),
    .m_axi_rready  (nda_rready),

    // Sideband
    .nda_busy_o    (nda_busy_w),
    .nda_progress_o(nda_progress_w),
    .wdt_abort_i   (wdt_abort_w),
    .irq_o         (nda_irq_o)
  );

  // ===========================================================================
  // m05: WDT CSR
  // ===========================================================================
  wdt_wrapper #(
    .ID_WIDTH   (ID_WIDTH),
    .ADDR_WIDTH (ADDR_WIDTH)
  ) u_wdt (
    .clk           (clk),
    .aresetn       (aresetn),
    .s_axi_awid    (m_axi_awid[5]),
    .s_axi_awaddr  (m_axi_awaddr[5]),
    .s_axi_awlen   (m_axi_awlen[5]),
    .s_axi_awsize  (m_axi_awsize[5]),
    .s_axi_awburst (m_axi_awburst[5]),
    .s_axi_awvalid (m_axi_awvalid[5]),
    .s_axi_awready (m_axi_awready[5]),
    .s_axi_wdata   (m_axi_wdata[5]),
    .s_axi_wstrb   (m_axi_wstrb[5]),
    .s_axi_wvalid  (m_axi_wvalid[5]),
    .s_axi_wready  (m_axi_wready[5]),
    .s_axi_bid     (m_axi_bid[5]),
    .s_axi_bresp   (m_axi_bresp[5]),
    .s_axi_bvalid  (m_axi_bvalid[5]),
    .s_axi_bready  (m_axi_bready[5]),
    .s_axi_arid    (m_axi_arid[5]),
    .s_axi_araddr  (m_axi_araddr[5]),
    .s_axi_arlen   (m_axi_arlen[5]),
    .s_axi_arsize  (m_axi_arsize[5]),
    .s_axi_arburst (m_axi_arburst[5]),
    .s_axi_arvalid (m_axi_arvalid[5]),
    .s_axi_arready (m_axi_arready[5]),
    .s_axi_rid     (m_axi_rid[5]),
    .s_axi_rdata   (m_axi_rdata[5]),
    .s_axi_rresp   (m_axi_rresp[5]),
    .s_axi_rvalid  (m_axi_rvalid[5]),
    .s_axi_rready  (m_axi_rready[5]),

    // Sideband
    .nda_busy_i    (nda_busy_w),
    .nda_progress_i(nda_progress_w),
    .abort_o       (wdt_abort_w),
    .trip_o        (wdt_trip_w),
    .irq_o         (wdt_irq_o)
  );

  // ===========================================================================
  // m06: HPM CSR (conditional on ENABLE_HPM)
  // ===========================================================================
  generate
    if (soc_pkg::ENABLE_HPM) begin : gen_hpm
      hpm_wrapper #(
        .ID_WIDTH   (ID_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH)
      ) u_hpm (
        .clk           (clk),
        .aresetn       (aresetn),
        .s_axi_awid    (m_axi_awid[6]),
        .s_axi_awaddr  (m_axi_awaddr[6]),
        .s_axi_awlen   (m_axi_awlen[6]),
        .s_axi_awsize  (m_axi_awsize[6]),
        .s_axi_awburst (m_axi_awburst[6]),
        .s_axi_awvalid (m_axi_awvalid[6]),
        .s_axi_awready (m_axi_awready[6]),
        .s_axi_wdata   (m_axi_wdata[6]),
        .s_axi_wstrb   (m_axi_wstrb[6]),
        .s_axi_wvalid  (m_axi_wvalid[6]),
        .s_axi_wready  (m_axi_wready[6]),
        .s_axi_bid     (m_axi_bid[6]),
        .s_axi_bresp   (m_axi_bresp[6]),
        .s_axi_bvalid  (m_axi_bvalid[6]),
        .s_axi_bready  (m_axi_bready[6]),
        .s_axi_arid    (m_axi_arid[6]),
        .s_axi_araddr  (m_axi_araddr[6]),
        .s_axi_arlen   (m_axi_arlen[6]),
        .s_axi_arsize  (m_axi_arsize[6]),
        .s_axi_arburst (m_axi_arburst[6]),
        .s_axi_arvalid (m_axi_arvalid[6]),
        .s_axi_arready (m_axi_arready[6]),
        .s_axi_rid     (m_axi_rid[6]),
        .s_axi_rdata   (m_axi_rdata[6]),
        .s_axi_rresp   (m_axi_rresp[6]),
        .s_axi_rvalid  (m_axi_rvalid[6]),
        .s_axi_rready  (m_axi_rready[6]),

        // Tap points
        .m0_ar_valid   (s_axi_arvalid & s_axi_arready),
        .m0_ar_ready   (1'b1),
        .m0_aw_valid   (s_axi_awvalid & s_axi_awready),
        .m0_aw_ready   (1'b1),
        .m0_r_valid    (s_axi_rvalid & s_axi_rready),
        .m0_r_ready    (1'b1),
        .m0_w_valid    (s_axi_wvalid & s_axi_wready),
        .m0_w_ready    (1'b1),
        .m1_ar_valid   (nda_arvalid & nda_arready),
        .m1_ar_ready   (1'b1),
        .m1_r_valid    (nda_rvalid & nda_rready),
        .m1_r_ready    (1'b1),
        .nda_busy      (nda_busy_w),
        .wdt_trip      (wdt_trip_w)
      );
    end
  endgenerate

endmodule

`resetall
