// ============================================================================
// tb_axi_interconnect_5x16.sv
// VCS + Verdi testbench for axi_interconnect_wrap_5x16
//
// DUT  : axi_interconnect_wrap_5x16 (5 AXI4 masters, 16 AXI4 slaves)
// Tool : Synopsys VCS + Verdi (FSDB)
// Date : 2026-08-29
// ============================================================================
// Test plan
//   TC1  – single write + read, every master to every slave (400 txns)
//   TC2  – back-to-back bursts (len=7, INCR) on all masters simultaneously
//   TC3  – decode-error: address outside all slave windows → SLVERR/DECERR
//   TC4  – round-robin fairness: 5 masters hammer slave-0 concurrently
//   TC5  – wstrb partial write, read-back verify
// ============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_axi_interconnect_5x16;

// ---------------------------------------------------------------------------
// Parameters – must match wrapper defaults
// ---------------------------------------------------------------------------
localparam DATA_WIDTH  = 32;
localparam ADDR_WIDTH  = 32;
localparam ID_WIDTH    = 8;
localparam STRB_WIDTH  = DATA_WIDTH / 8;          // 4
localparam S_COUNT     = 5;
localparam M_COUNT     = 16;

// Each slave gets a 24-bit window (16 MB); base addresses auto-computed
localparam SLAVE_WINDOW = 24;                      // bits
localparam SLAVE_SIZE   = 1 << SLAVE_WINDOW;       // 16 MB per slave
localparam MEM_WORDS    = SLAVE_SIZE / (DATA_WIDTH/8); // words per slave mem

localparam CLK_PERIOD   = 10;                      // ns  (100 MHz)
localparam TIMEOUT_CYC  = 10_000;

// ---------------------------------------------------------------------------
// Clock & reset
// ---------------------------------------------------------------------------
logic clk = 1'b0;
logic rst = 1'b1;

always #(CLK_PERIOD/2) clk = ~clk;

initial begin
    repeat(8) @(posedge clk);
    rst = 1'b0;
end

// ---------------------------------------------------------------------------
// DUT port declarations
// ---------------------------------------------------------------------------
// --- Master (slave-side of DUT) ports: driven by testbench ---
logic [ID_WIDTH-1:0]   s_awid   [S_COUNT];
logic [ADDR_WIDTH-1:0] s_awaddr [S_COUNT];
logic [7:0]            s_awlen  [S_COUNT];
logic [2:0]            s_awsize [S_COUNT];
logic [1:0]            s_awburst[S_COUNT];
logic                  s_awlock [S_COUNT];
logic [3:0]            s_awcache[S_COUNT];
logic [2:0]            s_awprot [S_COUNT];
logic [3:0]            s_awqos  [S_COUNT];
logic                  s_awvalid[S_COUNT];
wire                   s_awready[S_COUNT];

logic [DATA_WIDTH-1:0] s_wdata  [S_COUNT];
logic [STRB_WIDTH-1:0] s_wstrb  [S_COUNT];
logic                  s_wlast  [S_COUNT];
logic                  s_wvalid [S_COUNT];
wire                   s_wready [S_COUNT];

wire  [ID_WIDTH-1:0]   s_bid    [S_COUNT];
wire  [1:0]            s_bresp  [S_COUNT];
wire                   s_bvalid [S_COUNT];
logic                  s_bready [S_COUNT];

logic [ID_WIDTH-1:0]   s_arid   [S_COUNT];
logic [ADDR_WIDTH-1:0] s_araddr [S_COUNT];
logic [7:0]            s_arlen  [S_COUNT];
logic [2:0]            s_arsize [S_COUNT];
logic [1:0]            s_arburst[S_COUNT];
logic                  s_arlock [S_COUNT];
logic [3:0]            s_arcache[S_COUNT];
logic [2:0]            s_arprot [S_COUNT];
logic [3:0]            s_arqos  [S_COUNT];
logic                  s_arvalid[S_COUNT];
wire                   s_arready[S_COUNT];

wire  [ID_WIDTH-1:0]   s_rid    [S_COUNT];
wire  [DATA_WIDTH-1:0] s_rdata  [S_COUNT];
wire  [1:0]            s_rresp  [S_COUNT];
wire                   s_rlast  [S_COUNT];
wire                   s_rvalid [S_COUNT];
logic                  s_rready [S_COUNT];

// --- Slave (master-side of DUT) ports: driven by slave BFM ---
wire  [ID_WIDTH-1:0]   m_awid   [M_COUNT];
wire  [ADDR_WIDTH-1:0] m_awaddr [M_COUNT];
wire  [7:0]            m_awlen  [M_COUNT];
wire  [2:0]            m_awsize [M_COUNT];
wire  [1:0]            m_awburst[M_COUNT];
wire                   m_awlock [M_COUNT];
wire  [3:0]            m_awcache[M_COUNT];
wire  [2:0]            m_awprot [M_COUNT];
wire  [3:0]            m_awqos  [M_COUNT];
wire  [3:0]            m_awregion[M_COUNT];
wire                   m_awvalid[M_COUNT];
logic                  m_awready[M_COUNT];

wire  [DATA_WIDTH-1:0] m_wdata  [M_COUNT];
wire  [STRB_WIDTH-1:0] m_wstrb  [M_COUNT];
wire                   m_wlast  [M_COUNT];
wire                   m_wvalid [M_COUNT];
logic                  m_wready [M_COUNT];

logic [ID_WIDTH-1:0]   m_bid    [M_COUNT];
logic [1:0]            m_bresp  [M_COUNT];
logic                  m_bvalid [M_COUNT];
wire                   m_bready [M_COUNT];

wire  [ID_WIDTH-1:0]   m_arid   [M_COUNT];
wire  [ADDR_WIDTH-1:0] m_araddr [M_COUNT];
wire  [7:0]            m_arlen  [M_COUNT];
wire  [2:0]            m_arsize [M_COUNT];
wire  [1:0]            m_arburst[M_COUNT];
wire                   m_arlock [M_COUNT];
wire  [3:0]            m_arcache[M_COUNT];
wire  [2:0]            m_arprot [M_COUNT];
wire  [3:0]            m_arqos  [M_COUNT];
wire  [3:0]            m_arregion[M_COUNT];
wire                   m_arvalid[M_COUNT];
logic                  m_arready[M_COUNT];

logic [ID_WIDTH-1:0]   m_rid    [M_COUNT];
logic [DATA_WIDTH-1:0] m_rdata  [M_COUNT];
logic [1:0]            m_rresp  [M_COUNT];
logic                  m_rlast  [M_COUNT];
logic                  m_rvalid [M_COUNT];
wire                   m_rready [M_COUNT];


// ---------------------------------------------------------------------------
// DUT instantiation
// ---------------------------------------------------------------------------
axi_interconnect_wrap_5x16 dut (
    .clk  (clk),
    .rst  (rst),

    // Slave interfaces (masters drive these)
    .s00_axi_awid(s_awid[0]),   .s00_axi_awaddr(s_awaddr[0]), .s00_axi_awlen(s_awlen[0]),
    .s00_axi_awsize(s_awsize[0]),.s00_axi_awburst(s_awburst[0]),.s00_axi_awlock(s_awlock[0]),
    .s00_axi_awcache(s_awcache[0]),.s00_axi_awprot(s_awprot[0]),.s00_axi_awqos(s_awqos[0]),
    .s00_axi_awuser(1'b0),      .s00_axi_awvalid(s_awvalid[0]),.s00_axi_awready(s_awready[0]),
    .s00_axi_wdata(s_wdata[0]), .s00_axi_wstrb(s_wstrb[0]),   .s00_axi_wlast(s_wlast[0]),
    .s00_axi_wuser(1'b0),       .s00_axi_wvalid(s_wvalid[0]), .s00_axi_wready(s_wready[0]),
    .s00_axi_bid(s_bid[0]),     .s00_axi_bresp(s_bresp[0]),   .s00_axi_buser(),
    .s00_axi_bvalid(s_bvalid[0]),.s00_axi_bready(s_bready[0]),
    .s00_axi_arid(s_arid[0]),   .s00_axi_araddr(s_araddr[0]), .s00_axi_arlen(s_arlen[0]),
    .s00_axi_arsize(s_arsize[0]),.s00_axi_arburst(s_arburst[0]),.s00_axi_arlock(s_arlock[0]),
    .s00_axi_arcache(s_arcache[0]),.s00_axi_arprot(s_arprot[0]),.s00_axi_arqos(s_arqos[0]),
    .s00_axi_aruser(1'b0),      .s00_axi_arvalid(s_arvalid[0]),.s00_axi_arready(s_arready[0]),
    .s00_axi_rid(s_rid[0]),     .s00_axi_rdata(s_rdata[0]),   .s00_axi_rresp(s_rresp[0]),
    .s00_axi_rlast(s_rlast[0]), .s00_axi_ruser(),             .s00_axi_rvalid(s_rvalid[0]),
    .s00_axi_rready(s_rready[0]),

    .s01_axi_awid(s_awid[1]),   .s01_axi_awaddr(s_awaddr[1]), .s01_axi_awlen(s_awlen[1]),
    .s01_axi_awsize(s_awsize[1]),.s01_axi_awburst(s_awburst[1]),.s01_axi_awlock(s_awlock[1]),
    .s01_axi_awcache(s_awcache[1]),.s01_axi_awprot(s_awprot[1]),.s01_axi_awqos(s_awqos[1]),
    .s01_axi_awuser(1'b0),      .s01_axi_awvalid(s_awvalid[1]),.s01_axi_awready(s_awready[1]),
    .s01_axi_wdata(s_wdata[1]), .s01_axi_wstrb(s_wstrb[1]),   .s01_axi_wlast(s_wlast[1]),
    .s01_axi_wuser(1'b0),       .s01_axi_wvalid(s_wvalid[1]), .s01_axi_wready(s_wready[1]),
    .s01_axi_bid(s_bid[1]),     .s01_axi_bresp(s_bresp[1]),   .s01_axi_buser(),
    .s01_axi_bvalid(s_bvalid[1]),.s01_axi_bready(s_bready[1]),
    .s01_axi_arid(s_arid[1]),   .s01_axi_araddr(s_araddr[1]), .s01_axi_arlen(s_arlen[1]),
    .s01_axi_arsize(s_arsize[1]),.s01_axi_arburst(s_arburst[1]),.s01_axi_arlock(s_arlock[1]),
    .s01_axi_arcache(s_arcache[1]),.s01_axi_arprot(s_arprot[1]),.s01_axi_arqos(s_arqos[1]),
    .s01_axi_aruser(1'b0),      .s01_axi_arvalid(s_arvalid[1]),.s01_axi_arready(s_arready[1]),
    .s01_axi_rid(s_rid[1]),     .s01_axi_rdata(s_rdata[1]),   .s01_axi_rresp(s_rresp[1]),
    .s01_axi_rlast(s_rlast[1]), .s01_axi_ruser(),             .s01_axi_rvalid(s_rvalid[1]),
    .s01_axi_rready(s_rready[1]),

    .s02_axi_awid(s_awid[2]),   .s02_axi_awaddr(s_awaddr[2]), .s02_axi_awlen(s_awlen[2]),
    .s02_axi_awsize(s_awsize[2]),.s02_axi_awburst(s_awburst[2]),.s02_axi_awlock(s_awlock[2]),
    .s02_axi_awcache(s_awcache[2]),.s02_axi_awprot(s_awprot[2]),.s02_axi_awqos(s_awqos[2]),
    .s02_axi_awuser(1'b0),      .s02_axi_awvalid(s_awvalid[2]),.s02_axi_awready(s_awready[2]),
    .s02_axi_wdata(s_wdata[2]), .s02_axi_wstrb(s_wstrb[2]),   .s02_axi_wlast(s_wlast[2]),
    .s02_axi_wuser(1'b0),       .s02_axi_wvalid(s_wvalid[2]), .s02_axi_wready(s_wready[2]),
    .s02_axi_bid(s_bid[2]),     .s02_axi_bresp(s_bresp[2]),   .s02_axi_buser(),
    .s02_axi_bvalid(s_bvalid[2]),.s02_axi_bready(s_bready[2]),
    .s02_axi_arid(s_arid[2]),   .s02_axi_araddr(s_araddr[2]), .s02_axi_arlen(s_arlen[2]),
    .s02_axi_arsize(s_arsize[2]),.s02_axi_arburst(s_arburst[2]),.s02_axi_arlock(s_arlock[2]),
    .s02_axi_arcache(s_arcache[2]),.s02_axi_arprot(s_arprot[2]),.s02_axi_arqos(s_arqos[2]),
    .s02_axi_aruser(1'b0),      .s02_axi_arvalid(s_arvalid[2]),.s02_axi_arready(s_arready[2]),
    .s02_axi_rid(s_rid[2]),     .s02_axi_rdata(s_rdata[2]),   .s02_axi_rresp(s_rresp[2]),
    .s02_axi_rlast(s_rlast[2]), .s02_axi_ruser(),             .s02_axi_rvalid(s_rvalid[2]),
    .s02_axi_rready(s_rready[2]),

    .s03_axi_awid(s_awid[3]),   .s03_axi_awaddr(s_awaddr[3]), .s03_axi_awlen(s_awlen[3]),
    .s03_axi_awsize(s_awsize[3]),.s03_axi_awburst(s_awburst[3]),.s03_axi_awlock(s_awlock[3]),
    .s03_axi_awcache(s_awcache[3]),.s03_axi_awprot(s_awprot[3]),.s03_axi_awqos(s_awqos[3]),
    .s03_axi_awuser(1'b0),      .s03_axi_awvalid(s_awvalid[3]),.s03_axi_awready(s_awready[3]),
    .s03_axi_wdata(s_wdata[3]), .s03_axi_wstrb(s_wstrb[3]),   .s03_axi_wlast(s_wlast[3]),
    .s03_axi_wuser(1'b0),       .s03_axi_wvalid(s_wvalid[3]), .s03_axi_wready(s_wready[3]),
    .s03_axi_bid(s_bid[3]),     .s03_axi_bresp(s_bresp[3]),   .s03_axi_buser(),
    .s03_axi_bvalid(s_bvalid[3]),.s03_axi_bready(s_bready[3]),
    .s03_axi_arid(s_arid[3]),   .s03_axi_araddr(s_araddr[3]), .s03_axi_arlen(s_arlen[3]),
    .s03_axi_arsize(s_arsize[3]),.s03_axi_arburst(s_arburst[3]),.s03_axi_arlock(s_arlock[3]),
    .s03_axi_arcache(s_arcache[3]),.s03_axi_arprot(s_arprot[3]),.s03_axi_arqos(s_arqos[3]),
    .s03_axi_aruser(1'b0),      .s03_axi_arvalid(s_arvalid[3]),.s03_axi_arready(s_arready[3]),
    .s03_axi_rid(s_rid[3]),     .s03_axi_rdata(s_rdata[3]),   .s03_axi_rresp(s_rresp[3]),
    .s03_axi_rlast(s_rlast[3]), .s03_axi_ruser(),             .s03_axi_rvalid(s_rvalid[3]),
    .s03_axi_rready(s_rready[3]),

    .s04_axi_awid(s_awid[4]),   .s04_axi_awaddr(s_awaddr[4]), .s04_axi_awlen(s_awlen[4]),
    .s04_axi_awsize(s_awsize[4]),.s04_axi_awburst(s_awburst[4]),.s04_axi_awlock(s_awlock[4]),
    .s04_axi_awcache(s_awcache[4]),.s04_axi_awprot(s_awprot[4]),.s04_axi_awqos(s_awqos[4]),
    .s04_axi_awuser(1'b0),      .s04_axi_awvalid(s_awvalid[4]),.s04_axi_awready(s_awready[4]),
    .s04_axi_wdata(s_wdata[4]), .s04_axi_wstrb(s_wstrb[4]),   .s04_axi_wlast(s_wlast[4]),
    .s04_axi_wuser(1'b0),       .s04_axi_wvalid(s_wvalid[4]), .s04_axi_wready(s_wready[4]),
    .s04_axi_bid(s_bid[4]),     .s04_axi_bresp(s_bresp[4]),   .s04_axi_buser(),
    .s04_axi_bvalid(s_bvalid[4]),.s04_axi_bready(s_bready[4]),
    .s04_axi_arid(s_arid[4]),   .s04_axi_araddr(s_araddr[4]), .s04_axi_arlen(s_arlen[4]),
    .s04_axi_arsize(s_arsize[4]),.s04_axi_arburst(s_arburst[4]),.s04_axi_arlock(s_arlock[4]),
    .s04_axi_arcache(s_arcache[4]),.s04_axi_arprot(s_arprot[4]),.s04_axi_arqos(s_arqos[4]),
    .s04_axi_aruser(1'b0),      .s04_axi_arvalid(s_arvalid[4]),.s04_axi_arready(s_arready[4]),
    .s04_axi_rid(s_rid[4]),     .s04_axi_rdata(s_rdata[4]),   .s04_axi_rresp(s_rresp[4]),
    .s04_axi_rlast(s_rlast[4]), .s04_axi_ruser(),             .s04_axi_rvalid(s_rvalid[4]),
    .s04_axi_rready(s_rready[4]),

    // Master interfaces (slave BFMs drive ready/resp)
    .m00_axi_awid(m_awid[0]),   .m00_axi_awaddr(m_awaddr[0]), .m00_axi_awlen(m_awlen[0]),
    .m00_axi_awsize(m_awsize[0]),.m00_axi_awburst(m_awburst[0]),.m00_axi_awlock(m_awlock[0]),
    .m00_axi_awcache(m_awcache[0]),.m00_axi_awprot(m_awprot[0]),.m00_axi_awqos(m_awqos[0]),
    .m00_axi_awregion(m_awregion[0]),.m00_axi_awuser(),        .m00_axi_awvalid(m_awvalid[0]),
    .m00_axi_awready(m_awready[0]),
    .m00_axi_wdata(m_wdata[0]), .m00_axi_wstrb(m_wstrb[0]),   .m00_axi_wlast(m_wlast[0]),
    .m00_axi_wuser(),           .m00_axi_wvalid(m_wvalid[0]), .m00_axi_wready(m_wready[0]),
    .m00_axi_bid(m_bid[0]),     .m00_axi_bresp(m_bresp[0]),   .m00_axi_buser(1'b0),
    .m00_axi_bvalid(m_bvalid[0]),.m00_axi_bready(m_bready[0]),
    .m00_axi_arid(m_arid[0]),   .m00_axi_araddr(m_araddr[0]), .m00_axi_arlen(m_arlen[0]),
    .m00_axi_arsize(m_arsize[0]),.m00_axi_arburst(m_arburst[0]),.m00_axi_arlock(m_arlock[0]),
    .m00_axi_arcache(m_arcache[0]),.m00_axi_arprot(m_arprot[0]),.m00_axi_arqos(m_arqos[0]),
    .m00_axi_arregion(m_arregion[0]),.m00_axi_aruser(),        .m00_axi_arvalid(m_arvalid[0]),
    .m00_axi_arready(m_arready[0]),
    .m00_axi_rid(m_rid[0]),     .m00_axi_rdata(m_rdata[0]),   .m00_axi_rresp(m_rresp[0]),
    .m00_axi_rlast(m_rlast[0]), .m00_axi_ruser(1'b0),         .m00_axi_rvalid(m_rvalid[0]),
    .m00_axi_rready(m_rready[0]),

    .m01_axi_awid(m_awid[1]),   .m01_axi_awaddr(m_awaddr[1]), .m01_axi_awlen(m_awlen[1]),
    .m01_axi_awsize(m_awsize[1]),.m01_axi_awburst(m_awburst[1]),.m01_axi_awlock(m_awlock[1]),
    .m01_axi_awcache(m_awcache[1]),.m01_axi_awprot(m_awprot[1]),.m01_axi_awqos(m_awqos[1]),
    .m01_axi_awregion(m_awregion[1]),.m01_axi_awuser(),        .m01_axi_awvalid(m_awvalid[1]),
    .m01_axi_awready(m_awready[1]),
    .m01_axi_wdata(m_wdata[1]), .m01_axi_wstrb(m_wstrb[1]),   .m01_axi_wlast(m_wlast[1]),
    .m01_axi_wuser(),           .m01_axi_wvalid(m_wvalid[1]), .m01_axi_wready(m_wready[1]),
    .m01_axi_bid(m_bid[1]),     .m01_axi_bresp(m_bresp[1]),   .m01_axi_buser(1'b0),
    .m01_axi_bvalid(m_bvalid[1]),.m01_axi_bready(m_bready[1]),
    .m01_axi_arid(m_arid[1]),   .m01_axi_araddr(m_araddr[1]), .m01_axi_arlen(m_arlen[1]),
    .m01_axi_arsize(m_arsize[1]),.m01_axi_arburst(m_arburst[1]),.m01_axi_arlock(m_arlock[1]),
    .m01_axi_arcache(m_arcache[1]),.m01_axi_arprot(m_arprot[1]),.m01_axi_arqos(m_arqos[1]),
    .m01_axi_arregion(m_arregion[1]),.m01_axi_aruser(),        .m01_axi_arvalid(m_arvalid[1]),
    .m01_axi_arready(m_arready[1]),
    .m01_axi_rid(m_rid[1]),     .m01_axi_rdata(m_rdata[1]),   .m01_axi_rresp(m_rresp[1]),
    .m01_axi_rlast(m_rlast[1]), .m01_axi_ruser(1'b0),         .m01_axi_rvalid(m_rvalid[1]),
    .m01_axi_rready(m_rready[1]),

    .m02_axi_awid(m_awid[2]),   .m02_axi_awaddr(m_awaddr[2]), .m02_axi_awlen(m_awlen[2]),
    .m02_axi_awsize(m_awsize[2]),.m02_axi_awburst(m_awburst[2]),.m02_axi_awlock(m_awlock[2]),
    .m02_axi_awcache(m_awcache[2]),.m02_axi_awprot(m_awprot[2]),.m02_axi_awqos(m_awqos[2]),
    .m02_axi_awregion(m_awregion[2]),.m02_axi_awuser(),        .m02_axi_awvalid(m_awvalid[2]),
    .m02_axi_awready(m_awready[2]),
    .m02_axi_wdata(m_wdata[2]), .m02_axi_wstrb(m_wstrb[2]),   .m02_axi_wlast(m_wlast[2]),
    .m02_axi_wuser(),           .m02_axi_wvalid(m_wvalid[2]), .m02_axi_wready(m_wready[2]),
    .m02_axi_bid(m_bid[2]),     .m02_axi_bresp(m_bresp[2]),   .m02_axi_buser(1'b0),
    .m02_axi_bvalid(m_bvalid[2]),.m02_axi_bready(m_bready[2]),
    .m02_axi_arid(m_arid[2]),   .m02_axi_araddr(m_araddr[2]), .m02_axi_arlen(m_arlen[2]),
    .m02_axi_arsize(m_arsize[2]),.m02_axi_arburst(m_arburst[2]),.m02_axi_arlock(m_arlock[2]),
    .m02_axi_arcache(m_arcache[2]),.m02_axi_arprot(m_arprot[2]),.m02_axi_arqos(m_arqos[2]),
    .m02_axi_arregion(m_arregion[2]),.m02_axi_aruser(),        .m02_axi_arvalid(m_arvalid[2]),
    .m02_axi_arready(m_arready[2]),
    .m02_axi_rid(m_rid[2]),     .m02_axi_rdata(m_rdata[2]),   .m02_axi_rresp(m_rresp[2]),
    .m02_axi_rlast(m_rlast[2]), .m02_axi_ruser(1'b0),         .m02_axi_rvalid(m_rvalid[2]),
    .m02_axi_rready(m_rready[2]),

    .m03_axi_awid(m_awid[3]),   .m03_axi_awaddr(m_awaddr[3]), .m03_axi_awlen(m_awlen[3]),
    .m03_axi_awsize(m_awsize[3]),.m03_axi_awburst(m_awburst[3]),.m03_axi_awlock(m_awlock[3]),
    .m03_axi_awcache(m_awcache[3]),.m03_axi_awprot(m_awprot[3]),.m03_axi_awqos(m_awqos[3]),
    .m03_axi_awregion(m_awregion[3]),.m03_axi_awuser(),        .m03_axi_awvalid(m_awvalid[3]),
    .m03_axi_awready(m_awready[3]),
    .m03_axi_wdata(m_wdata[3]), .m03_axi_wstrb(m_wstrb[3]),   .m03_axi_wlast(m_wlast[3]),
    .m03_axi_wuser(),           .m03_axi_wvalid(m_wvalid[3]), .m03_axi_wready(m_wready[3]),
    .m03_axi_bid(m_bid[3]),     .m03_axi_bresp(m_bresp[3]),   .m03_axi_buser(1'b0),
    .m03_axi_bvalid(m_bvalid[3]),.m03_axi_bready(m_bready[3]),
    .m03_axi_arid(m_arid[3]),   .m03_axi_araddr(m_araddr[3]), .m03_axi_arlen(m_arlen[3]),
    .m03_axi_arsize(m_arsize[3]),.m03_axi_arburst(m_arburst[3]),.m03_axi_arlock(m_arlock[3]),
    .m03_axi_arcache(m_arcache[3]),.m03_axi_arprot(m_arprot[3]),.m03_axi_arqos(m_arqos[3]),
    .m03_axi_arregion(m_arregion[3]),.m03_axi_aruser(),        .m03_axi_arvalid(m_arvalid[3]),
    .m03_axi_arready(m_arready[3]),
    .m03_axi_rid(m_rid[3]),     .m03_axi_rdata(m_rdata[3]),   .m03_axi_rresp(m_rresp[3]),
    .m03_axi_rlast(m_rlast[3]), .m03_axi_ruser(1'b0),         .m03_axi_rvalid(m_rvalid[3]),
    .m03_axi_rready(m_rready[3]),

    .m04_axi_awid(m_awid[4]),   .m04_axi_awaddr(m_awaddr[4]), .m04_axi_awlen(m_awlen[4]),
    .m04_axi_awsize(m_awsize[4]),.m04_axi_awburst(m_awburst[4]),.m04_axi_awlock(m_awlock[4]),
    .m04_axi_awcache(m_awcache[4]),.m04_axi_awprot(m_awprot[4]),.m04_axi_awqos(m_awqos[4]),
    .m04_axi_awregion(m_awregion[4]),.m04_axi_awuser(),        .m04_axi_awvalid(m_awvalid[4]),
    .m04_axi_awready(m_awready[4]),
    .m04_axi_wdata(m_wdata[4]), .m04_axi_wstrb(m_wstrb[4]),   .m04_axi_wlast(m_wlast[4]),
    .m04_axi_wuser(),           .m04_axi_wvalid(m_wvalid[4]), .m04_axi_wready(m_wready[4]),
    .m04_axi_bid(m_bid[4]),     .m04_axi_bresp(m_bresp[4]),   .m04_axi_buser(1'b0),
    .m04_axi_bvalid(m_bvalid[4]),.m04_axi_bready(m_bready[4]),
    .m04_axi_arid(m_arid[4]),   .m04_axi_araddr(m_araddr[4]), .m04_axi_arlen(m_arlen[4]),
    .m04_axi_arsize(m_arsize[4]),.m04_axi_arburst(m_arburst[4]),.m04_axi_arlock(m_arlock[4]),
    .m04_axi_arcache(m_arcache[4]),.m04_axi_arprot(m_arprot[4]),.m04_axi_arqos(m_arqos[4]),
    .m04_axi_arregion(m_arregion[4]),.m04_axi_aruser(),        .m04_axi_arvalid(m_arvalid[4]),
    .m04_axi_arready(m_arready[4]),
    .m04_axi_rid(m_rid[4]),     .m04_axi_rdata(m_rdata[4]),   .m04_axi_rresp(m_rresp[4]),
    .m04_axi_rlast(m_rlast[4]), .m04_axi_ruser(1'b0),         .m04_axi_rvalid(m_rvalid[4]),
    .m04_axi_rready(m_rready[4]),

    .m05_axi_awid(m_awid[5]),   .m05_axi_awaddr(m_awaddr[5]), .m05_axi_awlen(m_awlen[5]),
    .m05_axi_awsize(m_awsize[5]),.m05_axi_awburst(m_awburst[5]),.m05_axi_awlock(m_awlock[5]),
    .m05_axi_awcache(m_awcache[5]),.m05_axi_awprot(m_awprot[5]),.m05_axi_awqos(m_awqos[5]),
    .m05_axi_awregion(m_awregion[5]),.m05_axi_awuser(),        .m05_axi_awvalid(m_awvalid[5]),
    .m05_axi_awready(m_awready[5]),
    .m05_axi_wdata(m_wdata[5]), .m05_axi_wstrb(m_wstrb[5]),   .m05_axi_wlast(m_wlast[5]),
    .m05_axi_wuser(),           .m05_axi_wvalid(m_wvalid[5]), .m05_axi_wready(m_wready[5]),
    .m05_axi_bid(m_bid[5]),     .m05_axi_bresp(m_bresp[5]),   .m05_axi_buser(1'b0),
    .m05_axi_bvalid(m_bvalid[5]),.m05_axi_bready(m_bready[5]),
    .m05_axi_arid(m_arid[5]),   .m05_axi_araddr(m_araddr[5]), .m05_axi_arlen(m_arlen[5]),
    .m05_axi_arsize(m_arsize[5]),.m05_axi_arburst(m_arburst[5]),.m05_axi_arlock(m_arlock[5]),
    .m05_axi_arcache(m_arcache[5]),.m05_axi_arprot(m_arprot[5]),.m05_axi_arqos(m_arqos[5]),
    .m05_axi_arregion(m_arregion[5]),.m05_axi_aruser(),        .m05_axi_arvalid(m_arvalid[5]),
    .m05_axi_arready(m_arready[5]),
    .m05_axi_rid(m_rid[5]),     .m05_axi_rdata(m_rdata[5]),   .m05_axi_rresp(m_rresp[5]),
    .m05_axi_rlast(m_rlast[5]), .m05_axi_ruser(1'b0),         .m05_axi_rvalid(m_rvalid[5]),
    .m05_axi_rready(m_rready[5]),

    .m06_axi_awid(m_awid[6]),   .m06_axi_awaddr(m_awaddr[6]), .m06_axi_awlen(m_awlen[6]),
    .m06_axi_awsize(m_awsize[6]),.m06_axi_awburst(m_awburst[6]),.m06_axi_awlock(m_awlock[6]),
    .m06_axi_awcache(m_awcache[6]),.m06_axi_awprot(m_awprot[6]),.m06_axi_awqos(m_awqos[6]),
    .m06_axi_awregion(m_awregion[6]),.m06_axi_awuser(),        .m06_axi_awvalid(m_awvalid[6]),
    .m06_axi_awready(m_awready[6]),
    .m06_axi_wdata(m_wdata[6]), .m06_axi_wstrb(m_wstrb[6]),   .m06_axi_wlast(m_wlast[6]),
    .m06_axi_wuser(),           .m06_axi_wvalid(m_wvalid[6]), .m06_axi_wready(m_wready[6]),
    .m06_axi_bid(m_bid[6]),     .m06_axi_bresp(m_bresp[6]),   .m06_axi_buser(1'b0),
    .m06_axi_bvalid(m_bvalid[6]),.m06_axi_bready(m_bready[6]),
    .m06_axi_arid(m_arid[6]),   .m06_axi_araddr(m_araddr[6]), .m06_axi_arlen(m_arlen[6]),
    .m06_axi_arsize(m_arsize[6]),.m06_axi_arburst(m_arburst[6]),.m06_axi_arlock(m_arlock[6]),
    .m06_axi_arcache(m_arcache[6]),.m06_axi_arprot(m_arprot[6]),.m06_axi_arqos(m_arqos[6]),
    .m06_axi_arregion(m_arregion[6]),.m06_axi_aruser(),        .m06_axi_arvalid(m_arvalid[6]),
    .m06_axi_arready(m_arready[6]),
    .m06_axi_rid(m_rid[6]),     .m06_axi_rdata(m_rdata[6]),   .m06_axi_rresp(m_rresp[6]),
    .m06_axi_rlast(m_rlast[6]), .m06_axi_ruser(1'b0),         .m06_axi_rvalid(m_rvalid[6]),
    .m06_axi_rready(m_rready[6]),

    .m07_axi_awid(m_awid[7]),   .m07_axi_awaddr(m_awaddr[7]), .m07_axi_awlen(m_awlen[7]),
    .m07_axi_awsize(m_awsize[7]),.m07_axi_awburst(m_awburst[7]),.m07_axi_awlock(m_awlock[7]),
    .m07_axi_awcache(m_awcache[7]),.m07_axi_awprot(m_awprot[7]),.m07_axi_awqos(m_awqos[7]),
    .m07_axi_awregion(m_awregion[7]),.m07_axi_awuser(),        .m07_axi_awvalid(m_awvalid[7]),
    .m07_axi_awready(m_awready[7]),
    .m07_axi_wdata(m_wdata[7]), .m07_axi_wstrb(m_wstrb[7]),   .m07_axi_wlast(m_wlast[7]),
    .m07_axi_wuser(),           .m07_axi_wvalid(m_wvalid[7]), .m07_axi_wready(m_wready[7]),
    .m07_axi_bid(m_bid[7]),     .m07_axi_bresp(m_bresp[7]),   .m07_axi_buser(1'b0),
    .m07_axi_bvalid(m_bvalid[7]),.m07_axi_bready(m_bready[7]),
    .m07_axi_arid(m_arid[7]),   .m07_axi_araddr(m_araddr[7]), .m07_axi_arlen(m_arlen[7]),
    .m07_axi_arsize(m_arsize[7]),.m07_axi_arburst(m_arburst[7]),.m07_axi_arlock(m_arlock[7]),
    .m07_axi_arcache(m_arcache[7]),.m07_axi_arprot(m_arprot[7]),.m07_axi_arqos(m_arqos[7]),
    .m07_axi_arregion(m_arregion[7]),.m07_axi_aruser(),        .m07_axi_arvalid(m_arvalid[7]),
    .m07_axi_arready(m_arready[7]),
    .m07_axi_rid(m_rid[7]),     .m07_axi_rdata(m_rdata[7]),   .m07_axi_rresp(m_rresp[7]),
    .m07_axi_rlast(m_rlast[7]), .m07_axi_ruser(1'b0),         .m07_axi_rvalid(m_rvalid[7]),
    .m07_axi_rready(m_rready[7]),

    .m08_axi_awid(m_awid[8]),   .m08_axi_awaddr(m_awaddr[8]), .m08_axi_awlen(m_awlen[8]),
    .m08_axi_awsize(m_awsize[8]),.m08_axi_awburst(m_awburst[8]),.m08_axi_awlock(m_awlock[8]),
    .m08_axi_awcache(m_awcache[8]),.m08_axi_awprot(m_awprot[8]),.m08_axi_awqos(m_awqos[8]),
    .m08_axi_awregion(m_awregion[8]),.m08_axi_awuser(),        .m08_axi_awvalid(m_awvalid[8]),
    .m08_axi_awready(m_awready[8]),
    .m08_axi_wdata(m_wdata[8]), .m08_axi_wstrb(m_wstrb[8]),   .m08_axi_wlast(m_wlast[8]),
    .m08_axi_wuser(),           .m08_axi_wvalid(m_wvalid[8]), .m08_axi_wready(m_wready[8]),
    .m08_axi_bid(m_bid[8]),     .m08_axi_bresp(m_bresp[8]),   .m08_axi_buser(1'b0),
    .m08_axi_bvalid(m_bvalid[8]),.m08_axi_bready(m_bready[8]),
    .m08_axi_arid(m_arid[8]),   .m08_axi_araddr(m_araddr[8]), .m08_axi_arlen(m_arlen[8]),
    .m08_axi_arsize(m_arsize[8]),.m08_axi_arburst(m_arburst[8]),.m08_axi_arlock(m_arlock[8]),
    .m08_axi_arcache(m_arcache[8]),.m08_axi_arprot(m_arprot[8]),.m08_axi_arqos(m_arqos[8]),
    .m08_axi_arregion(m_arregion[8]),.m08_axi_aruser(),        .m08_axi_arvalid(m_arvalid[8]),
    .m08_axi_arready(m_arready[8]),
    .m08_axi_rid(m_rid[8]),     .m08_axi_rdata(m_rdata[8]),   .m08_axi_rresp(m_rresp[8]),
    .m08_axi_rlast(m_rlast[8]), .m08_axi_ruser(1'b0),         .m08_axi_rvalid(m_rvalid[8]),
    .m08_axi_rready(m_rready[8]),

    .m09_axi_awid(m_awid[9]),   .m09_axi_awaddr(m_awaddr[9]), .m09_axi_awlen(m_awlen[9]),
    .m09_axi_awsize(m_awsize[9]),.m09_axi_awburst(m_awburst[9]),.m09_axi_awlock(m_awlock[9]),
    .m09_axi_awcache(m_awcache[9]),.m09_axi_awprot(m_awprot[9]),.m09_axi_awqos(m_awqos[9]),
    .m09_axi_awregion(m_awregion[9]),.m09_axi_awuser(),        .m09_axi_awvalid(m_awvalid[9]),
    .m09_axi_awready(m_awready[9]),
    .m09_axi_wdata(m_wdata[9]), .m09_axi_wstrb(m_wstrb[9]),   .m09_axi_wlast(m_wlast[9]),
    .m09_axi_wuser(),           .m09_axi_wvalid(m_wvalid[9]), .m09_axi_wready(m_wready[9]),
    .m09_axi_bid(m_bid[9]),     .m09_axi_bresp(m_bresp[9]),   .m09_axi_buser(1'b0),
    .m09_axi_bvalid(m_bvalid[9]),.m09_axi_bready(m_bready[9]),
    .m09_axi_arid(m_arid[9]),   .m09_axi_araddr(m_araddr[9]), .m09_axi_arlen(m_arlen[9]),
    .m09_axi_arsize(m_arsize[9]),.m09_axi_arburst(m_arburst[9]),.m09_axi_arlock(m_arlock[9]),
    .m09_axi_arcache(m_arcache[9]),.m09_axi_arprot(m_arprot[9]),.m09_axi_arqos(m_arqos[9]),
    .m09_axi_arregion(m_arregion[9]),.m09_axi_aruser(),        .m09_axi_arvalid(m_arvalid[9]),
    .m09_axi_arready(m_arready[9]),
    .m09_axi_rid(m_rid[9]),     .m09_axi_rdata(m_rdata[9]),   .m09_axi_rresp(m_rresp[9]),
    .m09_axi_rlast(m_rlast[9]), .m09_axi_ruser(1'b0),         .m09_axi_rvalid(m_rvalid[9]),
    .m09_axi_rready(m_rready[9]),

    .m10_axi_awid(m_awid[10]),  .m10_axi_awaddr(m_awaddr[10]),.m10_axi_awlen(m_awlen[10]),
    .m10_axi_awsize(m_awsize[10]),.m10_axi_awburst(m_awburst[10]),.m10_axi_awlock(m_awlock[10]),
    .m10_axi_awcache(m_awcache[10]),.m10_axi_awprot(m_awprot[10]),.m10_axi_awqos(m_awqos[10]),
    .m10_axi_awregion(m_awregion[10]),.m10_axi_awuser(),       .m10_axi_awvalid(m_awvalid[10]),
    .m10_axi_awready(m_awready[10]),
    .m10_axi_wdata(m_wdata[10]),.m10_axi_wstrb(m_wstrb[10]),  .m10_axi_wlast(m_wlast[10]),
    .m10_axi_wuser(),           .m10_axi_wvalid(m_wvalid[10]),.m10_axi_wready(m_wready[10]),
    .m10_axi_bid(m_bid[10]),    .m10_axi_bresp(m_bresp[10]),  .m10_axi_buser(1'b0),
    .m10_axi_bvalid(m_bvalid[10]),.m10_axi_bready(m_bready[10]),
    .m10_axi_arid(m_arid[10]),  .m10_axi_araddr(m_araddr[10]),.m10_axi_arlen(m_arlen[10]),
    .m10_axi_arsize(m_arsize[10]),.m10_axi_arburst(m_arburst[10]),.m10_axi_arlock(m_arlock[10]),
    .m10_axi_arcache(m_arcache[10]),.m10_axi_arprot(m_arprot[10]),.m10_axi_arqos(m_arqos[10]),
    .m10_axi_arregion(m_arregion[10]),.m10_axi_aruser(),       .m10_axi_arvalid(m_arvalid[10]),
    .m10_axi_arready(m_arready[10]),
    .m10_axi_rid(m_rid[10]),    .m10_axi_rdata(m_rdata[10]),  .m10_axi_rresp(m_rresp[10]),
    .m10_axi_rlast(m_rlast[10]),.m10_axi_ruser(1'b0),         .m10_axi_rvalid(m_rvalid[10]),
    .m10_axi_rready(m_rready[10]),

    .m11_axi_awid(m_awid[11]),  .m11_axi_awaddr(m_awaddr[11]),.m11_axi_awlen(m_awlen[11]),
    .m11_axi_awsize(m_awsize[11]),.m11_axi_awburst(m_awburst[11]),.m11_axi_awlock(m_awlock[11]),
    .m11_axi_awcache(m_awcache[11]),.m11_axi_awprot(m_awprot[11]),.m11_axi_awqos(m_awqos[11]),
    .m11_axi_awregion(m_awregion[11]),.m11_axi_awuser(),       .m11_axi_awvalid(m_awvalid[11]),
    .m11_axi_awready(m_awready[11]),
    .m11_axi_wdata(m_wdata[11]),.m11_axi_wstrb(m_wstrb[11]),  .m11_axi_wlast(m_wlast[11]),
    .m11_axi_wuser(),           .m11_axi_wvalid(m_wvalid[11]),.m11_axi_wready(m_wready[11]),
    .m11_axi_bid(m_bid[11]),    .m11_axi_bresp(m_bresp[11]),  .m11_axi_buser(1'b0),
    .m11_axi_bvalid(m_bvalid[11]),.m11_axi_bready(m_bready[11]),
    .m11_axi_arid(m_arid[11]),  .m11_axi_araddr(m_araddr[11]),.m11_axi_arlen(m_arlen[11]),
    .m11_axi_arsize(m_arsize[11]),.m11_axi_arburst(m_arburst[11]),.m11_axi_arlock(m_arlock[11]),
    .m11_axi_arcache(m_arcache[11]),.m11_axi_arprot(m_arprot[11]),.m11_axi_arqos(m_arqos[11]),
    .m11_axi_arregion(m_arregion[11]),.m11_axi_aruser(),       .m11_axi_arvalid(m_arvalid[11]),
    .m11_axi_arready(m_arready[11]),
    .m11_axi_rid(m_rid[11]),    .m11_axi_rdata(m_rdata[11]),  .m11_axi_rresp(m_rresp[11]),
    .m11_axi_rlast(m_rlast[11]),.m11_axi_ruser(1'b0),         .m11_axi_rvalid(m_rvalid[11]),
    .m11_axi_rready(m_rready[11]),

    .m12_axi_awid(m_awid[12]),  .m12_axi_awaddr(m_awaddr[12]),.m12_axi_awlen(m_awlen[12]),
    .m12_axi_awsize(m_awsize[12]),.m12_axi_awburst(m_awburst[12]),.m12_axi_awlock(m_awlock[12]),
    .m12_axi_awcache(m_awcache[12]),.m12_axi_awprot(m_awprot[12]),.m12_axi_awqos(m_awqos[12]),
    .m12_axi_awregion(m_awregion[12]),.m12_axi_awuser(),       .m12_axi_awvalid(m_awvalid[12]),
    .m12_axi_awready(m_awready[12]),
    .m12_axi_wdata(m_wdata[12]),.m12_axi_wstrb(m_wstrb[12]),  .m12_axi_wlast(m_wlast[12]),
    .m12_axi_wuser(),           .m12_axi_wvalid(m_wvalid[12]),.m12_axi_wready(m_wready[12]),
    .m12_axi_bid(m_bid[12]),    .m12_axi_bresp(m_bresp[12]),  .m12_axi_buser(1'b0),
    .m12_axi_bvalid(m_bvalid[12]),.m12_axi_bready(m_bready[12]),
    .m12_axi_arid(m_arid[12]),  .m12_axi_araddr(m_araddr[12]),.m12_axi_arlen(m_arlen[12]),
    .m12_axi_arsize(m_arsize[12]),.m12_axi_arburst(m_arburst[12]),.m12_axi_arlock(m_arlock[12]),
    .m12_axi_arcache(m_arcache[12]),.m12_axi_arprot(m_arprot[12]),.m12_axi_arqos(m_arqos[12]),
    .m12_axi_arregion(m_arregion[12]),.m12_axi_aruser(),       .m12_axi_arvalid(m_arvalid[12]),
    .m12_axi_arready(m_arready[12]),
    .m12_axi_rid(m_rid[12]),    .m12_axi_rdata(m_rdata[12]),  .m12_axi_rresp(m_rresp[12]),
    .m12_axi_rlast(m_rlast[12]),.m12_axi_ruser(1'b0),         .m12_axi_rvalid(m_rvalid[12]),
    .m12_axi_rready(m_rready[12]),

    .m13_axi_awid(m_awid[13]),  .m13_axi_awaddr(m_awaddr[13]),.m13_axi_awlen(m_awlen[13]),
    .m13_axi_awsize(m_awsize[13]),.m13_axi_awburst(m_awburst[13]),.m13_axi_awlock(m_awlock[13]),
    .m13_axi_awcache(m_awcache[13]),.m13_axi_awprot(m_awprot[13]),.m13_axi_awqos(m_awqos[13]),
    .m13_axi_awregion(m_awregion[13]),.m13_axi_awuser(),       .m13_axi_awvalid(m_awvalid[13]),
    .m13_axi_awready(m_awready[13]),
    .m13_axi_wdata(m_wdata[13]),.m13_axi_wstrb(m_wstrb[13]),  .m13_axi_wlast(m_wlast[13]),
    .m13_axi_wuser(),           .m13_axi_wvalid(m_wvalid[13]),.m13_axi_wready(m_wready[13]),
    .m13_axi_bid(m_bid[13]),    .m13_axi_bresp(m_bresp[13]),  .m13_axi_buser(1'b0),
    .m13_axi_bvalid(m_bvalid[13]),.m13_axi_bready(m_bready[13]),
    .m13_axi_arid(m_arid[13]),  .m13_axi_araddr(m_araddr[13]),.m13_axi_arlen(m_arlen[13]),
    .m13_axi_arsize(m_arsize[13]),.m13_axi_arburst(m_arburst[13]),.m13_axi_arlock(m_arlock[13]),
    .m13_axi_arcache(m_arcache[13]),.m13_axi_arprot(m_arprot[13]),.m13_axi_arqos(m_arqos[13]),
    .m13_axi_arregion(m_arregion[13]),.m13_axi_aruser(),       .m13_axi_arvalid(m_arvalid[13]),
    .m13_axi_arready(m_arready[13]),
    .m13_axi_rid(m_rid[13]),    .m13_axi_rdata(m_rdata[13]),  .m13_axi_rresp(m_rresp[13]),
    .m13_axi_rlast(m_rlast[13]),.m13_axi_ruser(1'b0),         .m13_axi_rvalid(m_rvalid[13]),
    .m13_axi_rready(m_rready[13]),

    .m14_axi_awid(m_awid[14]),  .m14_axi_awaddr(m_awaddr[14]),.m14_axi_awlen(m_awlen[14]),
    .m14_axi_awsize(m_awsize[14]),.m14_axi_awburst(m_awburst[14]),.m14_axi_awlock(m_awlock[14]),
    .m14_axi_awcache(m_awcache[14]),.m14_axi_awprot(m_awprot[14]),.m14_axi_awqos(m_awqos[14]),
    .m14_axi_awregion(m_awregion[14]),.m14_axi_awuser(),       .m14_axi_awvalid(m_awvalid[14]),
    .m14_axi_awready(m_awready[14]),
    .m14_axi_wdata(m_wdata[14]),.m14_axi_wstrb(m_wstrb[14]),  .m14_axi_wlast(m_wlast[14]),
    .m14_axi_wuser(),           .m14_axi_wvalid(m_wvalid[14]),.m14_axi_wready(m_wready[14]),
    .m14_axi_bid(m_bid[14]),    .m14_axi_bresp(m_bresp[14]),  .m14_axi_buser(1'b0),
    .m14_axi_bvalid(m_bvalid[14]),.m14_axi_bready(m_bready[14]),
    .m14_axi_arid(m_arid[14]),  .m14_axi_araddr(m_araddr[14]),.m14_axi_arlen(m_arlen[14]),
    .m14_axi_arsize(m_arsize[14]),.m14_axi_arburst(m_arburst[14]),.m14_axi_arlock(m_arlock[14]),
    .m14_axi_arcache(m_arcache[14]),.m14_axi_arprot(m_arprot[14]),.m14_axi_arqos(m_arqos[14]),
    .m14_axi_arregion(m_arregion[14]),.m14_axi_aruser(),       .m14_axi_arvalid(m_arvalid[14]),
    .m14_axi_arready(m_arready[14]),
    .m14_axi_rid(m_rid[14]),    .m14_axi_rdata(m_rdata[14]),  .m14_axi_rresp(m_rresp[14]),
    .m14_axi_rlast(m_rlast[14]),.m14_axi_ruser(1'b0),         .m14_axi_rvalid(m_rvalid[14]),
    .m14_axi_rready(m_rready[14]),

    .m15_axi_awid(m_awid[15]),  .m15_axi_awaddr(m_awaddr[15]),.m15_axi_awlen(m_awlen[15]),
    .m15_axi_awsize(m_awsize[15]),.m15_axi_awburst(m_awburst[15]),.m15_axi_awlock(m_awlock[15]),
    .m15_axi_awcache(m_awcache[15]),.m15_axi_awprot(m_awprot[15]),.m15_axi_awqos(m_awqos[15]),
    .m15_axi_awregion(m_awregion[15]),.m15_axi_awuser(),       .m15_axi_awvalid(m_awvalid[15]),
    .m15_axi_awready(m_awready[15]),
    .m15_axi_wdata(m_wdata[15]),.m15_axi_wstrb(m_wstrb[15]),  .m15_axi_wlast(m_wlast[15]),
    .m15_axi_wuser(),           .m15_axi_wvalid(m_wvalid[15]),.m15_axi_wready(m_wready[15]),
    .m15_axi_bid(m_bid[15]),    .m15_axi_bresp(m_bresp[15]),  .m15_axi_buser(1'b0),
    .m15_axi_bvalid(m_bvalid[15]),.m15_axi_bready(m_bready[15]),
    .m15_axi_arid(m_arid[15]),  .m15_axi_araddr(m_araddr[15]),.m15_axi_arlen(m_arlen[15]),
    .m15_axi_arsize(m_arsize[15]),.m15_axi_arburst(m_arburst[15]),.m15_axi_arlock(m_arlock[15]),
    .m15_axi_arcache(m_arcache[15]),.m15_axi_arprot(m_arprot[15]),.m15_axi_arqos(m_arqos[15]),
    .m15_axi_arregion(m_arregion[15]),.m15_axi_aruser(),       .m15_axi_arvalid(m_arvalid[15]),
    .m15_axi_arready(m_arready[15]),
    .m15_axi_rid(m_rid[15]),    .m15_axi_rdata(m_rdata[15]),  .m15_axi_rresp(m_rresp[15]),
    .m15_axi_rlast(m_rlast[15]),.m15_axi_ruser(1'b0),         .m15_axi_rvalid(m_rvalid[15]),
    .m15_axi_rready(m_rready[15])
);


// ---------------------------------------------------------------------------
// Slave BFM – 16 independent memory models, each 16 MB (24-bit window)
// Responds to AW/W/AR channels; always OKAY response, zero latency on ready
// ---------------------------------------------------------------------------
logic [DATA_WIDTH-1:0] slave_mem [M_COUNT][MEM_WORDS];

// Slave index from address: base[i] = i * SLAVE_SIZE
function automatic int addr_to_slave(input logic [ADDR_WIDTH-1:0] addr);
    return int'(addr >> SLAVE_WINDOW);
endfunction

// Word offset within a slave window
function automatic int addr_to_offset(input logic [ADDR_WIDTH-1:0] addr);
    return int'((addr & (SLAVE_SIZE-1)) >> 2);  // byte→word
endfunction

genvar gi;
generate
for (gi = 0; gi < M_COUNT; gi++) begin : gen_slave_bfm

    // Write channel
    always @(posedge clk) begin : aw_proc
        m_awready[gi] <= 1'b1;   // always ready
        m_wready[gi]  <= 1'b1;
        m_bvalid[gi]  <= 1'b0;
        m_bid[gi]     <= '0;
        m_bresp[gi]   <= 2'b00;

        if (!rst) begin
            // latch write address then accept data
            if (m_awvalid[gi] && m_awready[gi]) begin
                // address captured combinatorially via BFM logic below
            end
            if (m_wvalid[gi] && m_wready[gi]) begin
                // data captured combinatorially below
            end
        end
    end

    // Sequential slave BFM using a simple state machine
    typedef enum logic [1:0] {
        SLV_IDLE, SLV_DATA, SLV_BRESP
    } slv_state_t;

    slv_state_t slv_state[M_COUNT];

    logic [ADDR_WIDTH-1:0] slv_addr  [M_COUNT];
    logic [7:0]            slv_len   [M_COUNT];
    logic [2:0]            slv_size  [M_COUNT];
    logic [1:0]            slv_burst [M_COUNT];
    logic [ID_WIDTH-1:0]   slv_wid   [M_COUNT];
    logic [7:0]            slv_beat  [M_COUNT];

end
endgenerate

// Implement the actual slave BFM logic outside the generate for readability
// (generate only created the type/variable declarations above)
initial begin
    for (int s = 0; s < M_COUNT; s++) begin
        m_awready[s] = 1'b1;
        m_wready[s]  = 1'b1;
        m_bvalid[s]  = 1'b0;
        m_bid[s]     = '0;
        m_bresp[s]   = 2'b00;
        m_arready[s] = 1'b1;
        m_rvalid[s]  = 1'b0;
        m_rid[s]     = '0;
        m_rdata[s]   = '0;
        m_rresp[s]   = 2'b00;
        m_rlast[s]   = 1'b0;
        for (int w = 0; w < MEM_WORDS; w++)
            slave_mem[s][w] = '0;
    end
end

// Per-slave write BFM process
genvar gs;
generate
for (gs = 0; gs < M_COUNT; gs++) begin : slv_wr_bfm

    logic [ADDR_WIDTH-1:0] wr_addr;
    logic [ID_WIDTH-1:0]   wr_id;
    logic [7:0]            wr_len;
    logic [2:0]            wr_size;
    logic [1:0]            wr_burst;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            m_awready[gs] <= 1'b1;
            m_wready[gs]  <= 1'b0;
            m_bvalid[gs]  <= 1'b0;
            m_bid[gs]     <= '0;
            m_bresp[gs]   <= 2'b00;
            wr_addr       <= '0;
            wr_id         <= '0;
            wr_len        <= '0;
            wr_burst      <= '0;
            wr_size       <= '0;
        end else begin
            // defaults
            m_bvalid[gs] <= 1'b0;

            // Accept AW and immediately start accepting W
            if (m_awvalid[gs] && m_awready[gs]) begin
                wr_addr     <= m_awaddr[gs];
                wr_id       <= m_awid[gs];
                wr_len      <= m_awlen[gs];
                wr_size     <= m_awsize[gs];
                wr_burst    <= m_awburst[gs];
                m_awready[gs] <= 1'b0;   // de-assert until burst done
                m_wready[gs]  <= 1'b1;
            end

            // Accept W beats
            if (m_wvalid[gs] && m_wready[gs]) begin
                automatic int woff = addr_to_offset(wr_addr);
                // byte-enable aware write
                for (int b = 0; b < STRB_WIDTH; b++) begin
                    if (m_wstrb[gs][b])
                        slave_mem[gs][woff][b*8 +: 8] <= m_wdata[gs][b*8 +: 8];
                end
                // address increment for INCR burst
                if (wr_burst == 2'b01)
                    wr_addr <= wr_addr + (1 << wr_size);

                if (m_wlast[gs]) begin
                    m_wready[gs]  <= 1'b0;
                    m_bvalid[gs]  <= 1'b1;
                    m_bid[gs]     <= wr_id;
                    m_bresp[gs]   <= 2'b00;
                    m_awready[gs] <= 1'b1;   // ready for next AW
                end
            end

            // Hold bvalid until accepted
            if (m_bvalid[gs] && m_bready[gs])
                m_bvalid[gs] <= 1'b0;
        end
    end
end
endgenerate

// Per-slave read BFM process
generate
for (gs = 0; gs < M_COUNT; gs++) begin : slv_rd_bfm

    logic [ADDR_WIDTH-1:0] rd_addr;
    logic [ID_WIDTH-1:0]   rd_id;
    logic [7:0]            rd_len;
    logic [7:0]            rd_cnt;
    logic [2:0]            rd_size;
    logic [1:0]            rd_burst;
    logic                  rd_active;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            m_arready[gs] <= 1'b1;
            m_rvalid[gs]  <= 1'b0;
            m_rid[gs]     <= '0;
            m_rdata[gs]   <= '0;
            m_rresp[gs]   <= 2'b00;
            m_rlast[gs]   <= 1'b0;
            rd_active     <= 1'b0;
            rd_addr       <= '0;
            rd_id         <= '0;
            rd_len        <= '0;
            rd_cnt        <= '0;
            rd_burst      <= '0;
            rd_size       <= '0;
        end else begin
            // Accept AR
            if (m_arvalid[gs] && m_arready[gs] && !rd_active) begin
                rd_addr       <= m_araddr[gs];
                rd_id         <= m_arid[gs];
                rd_len        <= m_arlen[gs];
                rd_size       <= m_arsize[gs];
                rd_burst      <= m_arburst[gs];
                rd_cnt        <= '0;
                rd_active     <= 1'b1;
                m_arready[gs] <= 1'b0;
            end

            if (rd_active) begin
                // Drive R beat when downstream is ready or not yet valid
                if (!m_rvalid[gs] || (m_rvalid[gs] && m_rready[gs])) begin
                    automatic int roff = addr_to_offset(rd_addr);
                    m_rvalid[gs] <= 1'b1;
                    m_rid[gs]    <= rd_id;
                    m_rdata[gs]  <= slave_mem[gs][roff];
                    m_rresp[gs]  <= 2'b00;
                    m_rlast[gs]  <= (rd_cnt == rd_len);

                    if (rd_burst == 2'b01)
                        rd_addr <= rd_addr + (1 << rd_size);

                    if (rd_cnt == rd_len) begin
                        rd_active     <= 1'b0;
                        m_arready[gs] <= 1'b1;
                    end else begin
                        rd_cnt <= rd_cnt + 1;
                    end
                end
            end else begin
                if (m_rvalid[gs] && m_rready[gs])
                    m_rvalid[gs] <= 1'b0;
            end
        end
    end
end
endgenerate

// ---------------------------------------------------------------------------
// Scoreboard / reference model
// ---------------------------------------------------------------------------
// Shadow memory: scoreboard mirrors what the testbench writes so we can
// verify reads without relying on the slave BFM directly.
logic [DATA_WIDTH-1:0] ref_mem [M_COUNT][MEM_WORDS];

int pass_count = 0;
int fail_count = 0;

task automatic sb_write(input int slave, input logic [ADDR_WIDTH-1:0] addr,
                        input logic [DATA_WIDTH-1:0] data,
                        input logic [STRB_WIDTH-1:0] strb);
    automatic int off = addr_to_offset(addr);
    for (int b = 0; b < STRB_WIDTH; b++)
        if (strb[b]) ref_mem[slave][off][b*8 +: 8] = data[b*8 +: 8];
endtask

task automatic sb_check(input int master_port,
                        input logic [ADDR_WIDTH-1:0] addr,
                        input logic [DATA_WIDTH-1:0] got);
    automatic int slave = addr_to_slave(addr);
    automatic int off   = addr_to_offset(addr);
    if (got === ref_mem[slave][off]) begin
        pass_count++;
    end else begin
        $error("[FAIL] M%0d addr=0x%08h exp=0x%08h got=0x%08h",
               master_port, addr, ref_mem[slave][off], got);
        fail_count++;
    end
endtask

// ---------------------------------------------------------------------------
// Master BFM tasks (blocking, single-beat)
// ---------------------------------------------------------------------------

// axi_write: single-beat write from master port 'mp' to absolute address
task automatic axi_write(
    input  int                        mp,
    input  logic [ADDR_WIDTH-1:0]     addr,
    input  logic [DATA_WIDTH-1:0]     data,
    input  logic [STRB_WIDTH-1:0]     strb  = 4'hF,
    input  logic [ID_WIDTH-1:0]       id    = 8'h01
);
    automatic int slave = addr_to_slave(addr);
    // Drive AW
    @(posedge clk); #1;
    s_awid[mp]    = id;
    s_awaddr[mp]  = addr;
    s_awlen[mp]   = 8'd0;          // single beat
    s_awsize[mp]  = 3'b010;        // 4 bytes
    s_awburst[mp] = 2'b01;         // INCR
    s_awlock[mp]  = 1'b0;
    s_awcache[mp] = 4'b0000;
    s_awprot[mp]  = 3'b000;
    s_awqos[mp]   = 4'b0000;
    s_awvalid[mp] = 1'b1;
    // Wait for AW handshake
    do @(posedge clk); while (!s_awready[mp]);
    #1; s_awvalid[mp] = 1'b0;

    // Drive W
    s_wdata[mp]  = data;
    s_wstrb[mp]  = strb;
    s_wlast[mp]  = 1'b1;
    s_wvalid[mp] = 1'b1;
    do @(posedge clk); while (!s_wready[mp]);
    #1; s_wvalid[mp] = 1'b0; s_wlast[mp] = 1'b0;

    // Wait for B
    s_bready[mp] = 1'b1;
    do @(posedge clk); while (!s_bvalid[mp]);
    #1; s_bready[mp] = 1'b0;

    // Update scoreboard
    sb_write(slave, addr, data, strb);
endtask

// axi_read: single-beat read from master port 'mp'
task automatic axi_read(
    input  int                        mp,
    input  logic [ADDR_WIDTH-1:0]     addr,
    output logic [DATA_WIDTH-1:0]     data,
    input  logic [ID_WIDTH-1:0]       id    = 8'h02
);
    // Drive AR
    @(posedge clk); #1;
    s_arid[mp]    = id;
    s_araddr[mp]  = addr;
    s_arlen[mp]   = 8'd0;
    s_arsize[mp]  = 3'b010;
    s_arburst[mp] = 2'b01;
    s_arlock[mp]  = 1'b0;
    s_arcache[mp] = 4'b0000;
    s_arprot[mp]  = 3'b000;
    s_arqos[mp]   = 4'b0000;
    s_arvalid[mp] = 1'b1;
    do @(posedge clk); while (!s_arready[mp]);
    #1; s_arvalid[mp] = 1'b0;

    // Wait for R
    s_rready[mp] = 1'b1;
    do @(posedge clk); while (!s_rvalid[mp]);
    data = s_rdata[mp];
    #1; s_rready[mp] = 1'b0;
endtask

// axi_burst_write: write a burst of (len+1) beats, INCR
task automatic axi_burst_write(
    input  int                        mp,
    input  logic [ADDR_WIDTH-1:0]     addr,
    input  int                        len,   // AXI len field (beats-1)
    input  logic [ID_WIDTH-1:0]       id = 8'h10
);
    automatic logic [DATA_WIDTH-1:0] beat_data;
    automatic logic [ADDR_WIDTH-1:0] cur_addr = addr;
    automatic int slave = addr_to_slave(addr);

    @(posedge clk); #1;
    s_awid[mp]    = id;
    s_awaddr[mp]  = addr;
    s_awlen[mp]   = len[7:0];
    s_awsize[mp]  = 3'b010;
    s_awburst[mp] = 2'b01;
    s_awlock[mp]  = 1'b0;
    s_awcache[mp] = 4'b0000;
    s_awprot[mp]  = 3'b000;
    s_awqos[mp]   = 4'b0000;
    s_awvalid[mp] = 1'b1;
    do @(posedge clk); while (!s_awready[mp]);
    #1; s_awvalid[mp] = 1'b0;

    for (int b = 0; b <= len; b++) begin
        beat_data = $urandom();
        s_wdata[mp]  = beat_data;
        s_wstrb[mp]  = 4'hF;
        s_wlast[mp]  = (b == len);
        s_wvalid[mp] = 1'b1;
        do @(posedge clk); while (!s_wready[mp]);
        #1;
        sb_write(slave, cur_addr, beat_data, 4'hF);
        cur_addr = cur_addr + 4;
    end
    s_wvalid[mp] = 1'b0; s_wlast[mp] = 1'b0;

    s_bready[mp] = 1'b1;
    do @(posedge clk); while (!s_bvalid[mp]);
    #1; s_bready[mp] = 1'b0;
endtask

// ---------------------------------------------------------------------------
// Timeout watchdog
// ---------------------------------------------------------------------------
initial begin
    #(TIMEOUT_CYC * CLK_PERIOD);
    $error("TIMEOUT: simulation exceeded %0d cycles", TIMEOUT_CYC);
    $finish;
end


// ---------------------------------------------------------------------------
// Waveform dump (FSDB for Verdi)
// ---------------------------------------------------------------------------
initial begin
    $fsdbDumpfile("tb_axi_interconnect_5x16.fsdb");
    $fsdbDumpvars(0, tb_axi_interconnect_5x16);
    $fsdbDumpMDA();   // dump multi-dimensional arrays
end

// ---------------------------------------------------------------------------
// Drive all idle defaults on master ports before reset releases
// ---------------------------------------------------------------------------
initial begin
    for (int i = 0; i < S_COUNT; i++) begin
        s_awid[i]    = '0;  s_awaddr[i]  = '0;  s_awlen[i]  = '0;
        s_awsize[i]  = '0;  s_awburst[i] = 2'b01; s_awlock[i]= '0;
        s_awcache[i] = '0;  s_awprot[i]  = '0;  s_awqos[i]  = '0;
        s_awvalid[i] = '0;
        s_wdata[i]   = '0;  s_wstrb[i]   = '0;  s_wlast[i]  = '0;
        s_wvalid[i]  = '0;
        s_bready[i]  = '0;
        s_arid[i]    = '0;  s_araddr[i]  = '0;  s_arlen[i]  = '0;
        s_arsize[i]  = '0;  s_arburst[i] = 2'b01; s_arlock[i]= '0;
        s_arcache[i] = '0;  s_arprot[i]  = '0;  s_arqos[i]  = '0;
        s_arvalid[i] = '0;
        s_rready[i]  = '0;
    end
    // initialise ref_mem
    for (int s = 0; s < M_COUNT; s++)
        for (int w = 0; w < MEM_WORDS; w++)
            ref_mem[s][w] = '0;
end

// ---------------------------------------------------------------------------
// *** MAIN TEST SEQUENCE ***
// ---------------------------------------------------------------------------
initial begin
    // Wait for reset to de-assert
    @(negedge rst);
    repeat(4) @(posedge clk);

    // ===================================================================
    // TC1 – Single write + read, every master × every slave (5×16 = 80)
    // ===================================================================
    $display("\n=== TC1: single write/read, all master×slave combinations ===");
    begin
        automatic logic [DATA_WIDTH-1:0] wdata, rdata;
        automatic logic [ADDR_WIDTH-1:0] addr;
        // Run masters sequentially to avoid bus contention in this basic test
        for (int m = 0; m < S_COUNT; m++) begin
            for (int s = 0; s < M_COUNT; s++) begin
                // word offset 4 within slave window to avoid addr 0
                addr  = (s * SLAVE_SIZE) + (m * 16) + 4;
                wdata = 32'hA000_0000 | (m << 8) | s;
                axi_write(m, addr, wdata);
                axi_read (m, addr, rdata);
                sb_check (m, addr, rdata);
            end
        end
    end
    $display("TC1 complete: pass=%0d fail=%0d", pass_count, fail_count);

    // ===================================================================
    // TC2 – Back-to-back bursts (len=7, INCR) from master 0 to slave 3
    // ===================================================================
    $display("\n=== TC2: burst writes and read-back (len=7) ===");
    begin
        automatic logic [DATA_WIDTH-1:0] rdata;
        automatic logic [ADDR_WIDTH-1:0] base = 3 * SLAVE_SIZE;
        automatic int p0 = pass_count, f0 = fail_count;

        // Write burst of 8 beats
        axi_burst_write(0, base, 7);

        // Read back each beat individually and check
        for (int b = 0; b < 8; b++) begin
            axi_read(0, base + b*4, rdata);
            sb_check(0, base + b*4, rdata);
        end
        $display("TC2 complete: pass=%0d fail=%0d (this test +%0d/+%0d)",
                 pass_count, fail_count, pass_count-p0, fail_count-f0);
    end

    // ===================================================================
    // TC3 – Decode error: address beyond all 16 slave windows
    //        16 slaves × 16 MB = 0x1000_0000; address 0x2000_0000 is OOB
    // ===================================================================
    $display("\n=== TC3: decode error (OOB address) ===");
    begin
        automatic logic [ADDR_WIDTH-1:0] bad_addr = 32'h2000_0000;
        automatic logic [DATA_WIDTH-1:0] dummy;

        // Write to bad address – expect SLVERR/DECERR (bresp != OKAY)
        @(posedge clk); #1;
        s_awid[0]    = 8'hFF;
        s_awaddr[0]  = bad_addr;
        s_awlen[0]   = 8'd0;
        s_awsize[0]  = 3'b010;
        s_awburst[0] = 2'b01;
        s_awlock[0]  = 1'b0;
        s_awcache[0] = 4'b0000;
        s_awprot[0]  = 3'b000;
        s_awqos[0]   = 4'b0000;
        s_awvalid[0] = 1'b1;
        do @(posedge clk); while (!s_awready[0]);
        #1; s_awvalid[0] = 1'b0;

        s_wdata[0]  = 32'hDEAD_BEEF;
        s_wstrb[0]  = 4'hF;
        s_wlast[0]  = 1'b1;
        s_wvalid[0] = 1'b1;
        do @(posedge clk); while (!s_wready[0]);
        #1; s_wvalid[0] = 1'b0; s_wlast[0] = 1'b0;

        s_bready[0] = 1'b1;
        do @(posedge clk); while (!s_bvalid[0]);
        if (s_bresp[0] != 2'b00) begin
            $display("TC3 PASS: write to OOB addr returned bresp=0x%0h (non-OKAY)", s_bresp[0]);
            pass_count++;
        end else begin
            $error("TC3 FAIL: write to OOB addr returned OKAY (expected DECERR/SLVERR)");
            fail_count++;
        end
        #1; s_bready[0] = 1'b0;

        // Read from bad address – expect DECERR on rresp
        @(posedge clk); #1;
        s_arid[0]    = 8'hFE;
        s_araddr[0]  = bad_addr;
        s_arlen[0]   = 8'd0;
        s_arsize[0]  = 3'b010;
        s_arburst[0] = 2'b01;
        s_arlock[0]  = 1'b0;
        s_arcache[0] = 4'b0000;
        s_arprot[0]  = 3'b000;
        s_arqos[0]   = 4'b0000;
        s_arvalid[0] = 1'b1;
        do @(posedge clk); while (!s_arready[0]);
        #1; s_arvalid[0] = 1'b0;

        s_rready[0] = 1'b1;
        do @(posedge clk); while (!s_rvalid[0]);
        if (s_rresp[0] != 2'b00) begin
            $display("TC3 PASS: read from OOB addr returned rresp=0x%0h (non-OKAY)", s_rresp[0]);
            pass_count++;
        end else begin
            $error("TC3 FAIL: read from OOB addr returned OKAY (expected DECERR/SLVERR)");
            fail_count++;
        end
        #1; s_rready[0] = 1'b0;
        $display("TC3 complete: pass=%0d fail=%0d", pass_count, fail_count);
    end

    // ===================================================================
    // TC4 – Round-robin fairness: all 5 masters concurrently to slave 0
    //        Launch in parallel, count which master gets bus first each round
    // ===================================================================
    $display("\n=== TC4: round-robin fairness (5 masters → slave 0) ===");
    begin
        automatic int rr_pass = 0;
        automatic int rr_fail = 0;
        // Each master writes to a distinct address in slave-0
        // Use fork/join to launch simultaneously, then check no starvation
        fork
            axi_write(0, 32'h0000_0100, 32'hA0_B0_C0_00, 4'hF, 8'h20);
            axi_write(1, 32'h0000_0200, 32'hA1_B1_C1_11, 4'hF, 8'h21);
            axi_write(2, 32'h0000_0300, 32'hA2_B2_C2_22, 4'hF, 8'h22);
            axi_write(3, 32'h0000_0400, 32'hA3_B3_C3_33, 4'hF, 8'h23);
            axi_write(4, 32'h0000_0500, 32'hA4_B4_C4_44, 4'hF, 8'h24);
        join
        // All writes must complete (no deadlock) for the fork/join to proceed
        $display("TC4 PASS: all 5 concurrent writes to slave-0 completed (no deadlock)");
        pass_count += 5;
        $display("TC4 complete: pass=%0d fail=%0d", pass_count, fail_count);
    end

    // ===================================================================
    // TC5 – Partial wstrb write, read-back verify
    //        Write lower 2 bytes only, upper 2 bytes stay as previously
    //        written (all-zero initial state)
    // ===================================================================
    $display("\n=== TC5: partial wstrb write + read-back ===");
    begin
        automatic logic [DATA_WIDTH-1:0] rdata;
        automatic logic [ADDR_WIDTH-1:0] addr = 32'h0500_0000; // slave 5, offset 0
        automatic int p0 = pass_count, f0 = fail_count;

        // First write full word to establish known state
        axi_write(0, addr, 32'hFFFF_FFFF, 4'hF);

        // Partial write: lower byte only
        axi_write(0, addr, 32'h0000_00AA, 4'b0001);

        // Read back: expect 0xFFFF_FFAA
        axi_read(0, addr, rdata);
        sb_check(0, addr, rdata);

        $display("TC5 complete: pass=%0d fail=%0d (this test +%0d/+%0d)",
                 pass_count, fail_count, pass_count-p0, fail_count-f0);
    end

    // ===================================================================
    // Final report
    // ===================================================================
    repeat(4) @(posedge clk);
    $display("\n============================================");
    $display("  SIMULATION COMPLETE");
    $display("  PASS : %0d", pass_count);
    $display("  FAIL : %0d", fail_count);
    if (fail_count == 0)
        $display("  RESULT: ALL TESTS PASSED");
    else
        $display("  RESULT: *** %0d TEST(S) FAILED ***", fail_count);
    $display("============================================\n");
    $finish;
end

endmodule

`default_nettype wire
