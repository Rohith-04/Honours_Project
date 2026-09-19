// =============================================================================
// honours_soc.sv — Top-level SoC
//
// Components instantiated:
//   - el2_veer_wrapper   (Cores-VeeR-EL2/design/el2_veer_wrapper.sv)
//   - axi_interconnect_wrap_5x16  (rtl/interconnect/)
//   - uart_wrap          (rtl/uart/uart_wrap.sv)
//
// Memory map (32-bit address space):
//   0x0000_0000 – 0x00FF_FFFF   DRAM        (m00, 16 MB)
//   0x0100_0000 – 0x01FF_FFFF   ICCM mirror (m01, 16 MB — slave BFM in TB)
//   0x2000_0000 – 0x2000_0FFF   NDA ctrl    (m02, 4 KB — stub / unconnected)
//   0x2000_1000 – 0x2000_1FFF   Watchdog    (m03, 4 KB — stub)
//   0x2000_2000 – 0x2000_2FFF   HPM         (m04, 4 KB — stub)
//   0x2000_3000 – 0x2000_3FFF   UART        (m05, 4 KB)
//   0x2000_4000 – 0xFFFF_FFFF   Reserved    (m06-m15, decode error)
//
// Master port assignment (interconnect slave-side = CPU masters):
//   s00 — VeeR LSU  (Load/Store Unit, 64-bit → lower 32-bit used)
//   s01 — VeeR IFU  (Instruction Fetch Unit, 64-bit → lower 32-bit used)
//   s02 — VeeR SB   (System Bus / debug)
//   s03 — NDA data path (reserved — tied off)
//   s04 — Reserved  (tied off)
//
// NOTE: VeeR LSU and IFU AXI data buses are 64-bit. The interconnect uses
//       32-bit data. The connections here use the lower 32 bits only and
//       zero-extend / truncate accordingly. A proper AXI data-width converter
//       is needed for production use. This is marked TODO below.
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module honours_soc
import el2_pkg::*;
#(
    `include "el2_param.vh"
) (
    // -------------------------------------------------------------------------
    // Top-level I/O
    // -------------------------------------------------------------------------
    input  logic        clk,
    input  logic        rst_n,

    // UART physical
    input  logic        uart_rx,
    output logic        uart_tx,

    // JTAG (pass-through to VeeR debug)
    input  logic        jtag_tck,
    input  logic        jtag_tms,
    input  logic        jtag_tdi,
    input  logic        jtag_trst_n,
    output logic        jtag_tdo,
    output logic        jtag_tdo_en,

    // External interrupt bus to VeeR PIC (tie off unused sources)
    input  logic [pt.PIC_TOTAL_INT:1] extintsrc_req,

    // ------------------------------------------------------------------
    // s03 test hooks (NDA seat): let the TB drive the tied-off NDA master
    // port as a proper AXI master. Defaults keep old TBs compiling and the
    // port idle; tb_core_uart drives these procedurally (NO force).
    // When NDA RTL lands, these hooks are replaced by the engine.
    // ------------------------------------------------------------------
    input  logic [7:0]  tb_s03_awid    = '0,
    input  logic [31:0] tb_s03_awaddr  = '0,
    input  logic [7:0]  tb_s03_awlen   = '0,
    input  logic [2:0]  tb_s03_awsize  = 3'b010,
    input  logic [1:0]  tb_s03_awburst = 2'b01,
    input  logic        tb_s03_awvalid = 1'b0,
    output logic        tb_s03_awready,
    input  logic [31:0] tb_s03_wdata   = '0,
    input  logic [3:0]  tb_s03_wstrb   = 4'hF,
    input  logic        tb_s03_wlast   = 1'b1,
    input  logic        tb_s03_wvalid  = 1'b0,
    output logic        tb_s03_wready,
    output logic [7:0]  tb_s03_bid,
    output logic [1:0]  tb_s03_bresp,
    output logic        tb_s03_bvalid,
    input  logic        tb_s03_bready  = 1'b1,
    input  logic [7:0]  tb_s03_arid    = '0,
    input  logic [31:0] tb_s03_araddr  = '0,
    input  logic [7:0]  tb_s03_arlen   = '0,
    input  logic [2:0]  tb_s03_arsize  = 3'b010,
    input  logic [1:0]  tb_s03_arburst = 2'b01,
    input  logic        tb_s03_arvalid = 1'b0,
    output logic        tb_s03_arready,
    output logic [7:0]  tb_s03_rid,
    output logic [31:0] tb_s03_rdata,
    output logic [1:0]  tb_s03_rresp,
    output logic        tb_s03_rlast,
    output logic        tb_s03_rvalid,
    input  logic        tb_s03_rready  = 1'b1
);

    // =========================================================================
    // Local parameters
    // =========================================================================
    localparam XBAR_DATA_W = 32;
    localparam XBAR_ADDR_W = 32;
    localparam XBAR_ID_W   = 8;
    localparam XBAR_STRB_W = XBAR_DATA_W / 8;

    // Memory map — base addresses and sizes fed to interconnect
    // Each slave window is 2^SLAVE_WINDOW bytes (matches wrap_5x16 generator)
    localparam SLAVE_WINDOW = 24;   // 16 MB per slot

    // =========================================================================
    // VeeR clock-enable signals (1:1 ratio — all enabled)
    // =========================================================================
    logic lsu_bus_clk_en, ifu_bus_clk_en, dbg_bus_clk_en, dma_bus_clk_en;
    assign lsu_bus_clk_en = 1'b1;
    assign ifu_bus_clk_en = 1'b1;
    assign dbg_bus_clk_en = 1'b1;
    assign dma_bus_clk_en = 1'b1;

    // =========================================================================
    // VeeR AXI buses (native widths)
    // LSU / IFU data width = 64-bit; interconnect = 32-bit
    // Lower 32 bits are used; upper 32 bits are zero on write, ignored on read
    // TODO: insert AXI data-width converter for each 64-bit master
    // =========================================================================

    // --- LSU (master 0, s00) ---
    logic                         lsu_awvalid, lsu_awready;
    logic [pt.LSU_BUS_TAG-1:0]    lsu_awid;
    logic [31:0]                  lsu_awaddr;
    logic [7:0]                   lsu_awlen;
    logic [2:0]                   lsu_awsize;
    logic [1:0]                   lsu_awburst;
    logic                         lsu_awlock;
    logic [3:0]                   lsu_awcache;
    logic [2:0]                   lsu_awprot;
    logic [3:0]                   lsu_awqos;
    logic                         lsu_wvalid,  lsu_wready;
    logic [63:0]                  lsu_wdata;
    logic [7:0]                   lsu_wstrb;
    logic                         lsu_wlast;
    logic                         lsu_bvalid,  lsu_bready;
    logic [1:0]                   lsu_bresp;
    logic [pt.LSU_BUS_TAG-1:0]    lsu_bid;
    logic                         lsu_arvalid, lsu_arready;
    logic [pt.LSU_BUS_TAG-1:0]    lsu_arid;
    logic [31:0]                  lsu_araddr;
    logic [7:0]                   lsu_arlen;
    logic [2:0]                   lsu_arsize;
    logic [1:0]                   lsu_arburst;
    logic                         lsu_arlock;
    logic [3:0]                   lsu_arcache;
    logic [2:0]                   lsu_arprot;
    logic [3:0]                   lsu_arqos;
    logic                         lsu_rvalid,  lsu_rready;
    logic [pt.LSU_BUS_TAG-1:0]    lsu_rid;
    logic [63:0]                  lsu_rdata;
    logic [1:0]                   lsu_rresp;
    logic                         lsu_rlast;

    // --- IFU (master 1, s01) ---
    logic                         ifu_awvalid, ifu_awready;
    logic [pt.IFU_BUS_TAG-1:0]    ifu_awid;
    logic [31:0]                  ifu_awaddr;
    logic [7:0]                   ifu_awlen;
    logic [2:0]                   ifu_awsize;
    logic [1:0]                   ifu_awburst;
    logic                         ifu_awlock;
    logic [3:0]                   ifu_awcache;
    logic [2:0]                   ifu_awprot;
    logic [3:0]                   ifu_awqos;
    logic                         ifu_wvalid,  ifu_wready;
    logic [63:0]                  ifu_wdata;
    logic [7:0]                   ifu_wstrb;
    logic                         ifu_wlast;
    logic                         ifu_bvalid,  ifu_bready;
    logic [1:0]                   ifu_bresp;
    logic [pt.IFU_BUS_TAG-1:0]    ifu_bid;
    logic                         ifu_arvalid, ifu_arready;
    logic [pt.IFU_BUS_TAG-1:0]    ifu_arid;
    logic [31:0]                  ifu_araddr;
    logic [7:0]                   ifu_arlen;
    logic [2:0]                   ifu_arsize;
    logic [1:0]                   ifu_arburst;
    logic                         ifu_arlock;
    logic [3:0]                   ifu_arcache;
    logic [2:0]                   ifu_arprot;
    logic [3:0]                   ifu_arqos;
    logic                         ifu_rvalid,  ifu_rready;
    logic [pt.IFU_BUS_TAG-1:0]    ifu_rid;
    logic [63:0]                  ifu_rdata;
    logic [1:0]                   ifu_rresp;
    logic                         ifu_rlast;

    // --- SB / debug (master 2, s02) ---
    logic                         sb_awvalid, sb_awready;
    logic [pt.SB_BUS_TAG-1:0]     sb_awid;
    logic [31:0]                  sb_awaddr;
    logic [7:0]                   sb_awlen;
    logic [2:0]                   sb_awsize;
    logic [1:0]                   sb_awburst;
    logic                         sb_awlock;
    logic [3:0]                   sb_awcache;
    logic [2:0]                   sb_awprot;
    logic [3:0]                   sb_awqos;
    logic                         sb_wvalid,  sb_wready;
    logic [63:0]                  sb_wdata;
    logic [7:0]                   sb_wstrb;
    logic                         sb_wlast;
    logic                         sb_bvalid,  sb_bready;
    logic [1:0]                   sb_bresp;
    logic [pt.SB_BUS_TAG-1:0]     sb_bid;
    logic                         sb_arvalid, sb_arready;
    logic [pt.SB_BUS_TAG-1:0]     sb_arid;
    logic [31:0]                  sb_araddr;
    logic [7:0]                   sb_arlen;
    logic [2:0]                   sb_arsize;
    logic [1:0]                   sb_arburst;
    logic                         sb_arlock;
    logic [3:0]                   sb_arcache;
    logic [2:0]                   sb_arprot;
    logic [3:0]                   sb_arqos;
    logic                         sb_rvalid,  sb_rready;
    logic [pt.SB_BUS_TAG-1:0]     sb_rid;
    logic [63:0]                  sb_rdata;
    logic [1:0]                   sb_rresp;
    logic                         sb_rlast;

    // =========================================================================
    // 64-to-32 AXI width bridges (VeeR 64-bit -> 32-bit xbar)
    // One per CPU master; s03/s04 (NDA) are already 32-bit. See
    // axi64_to_32_bridge.sv for the conversion rule.
    // =========================================================================
    // Bridge <-> xbar (32-bit) wires
    logic [XBAR_ID_W-1:0] br_s00_awid, br_s00_arid, br_s00_bid, br_s00_rid;
    logic [31:0]  br_s00_awaddr, br_s00_araddr, br_s00_wdata, br_s00_rdata;
    logic [7:0]   br_s00_awlen, br_s00_arlen;
    logic [2:0]   br_s00_awsize, br_s00_arsize;
    logic [1:0]   br_s00_awburst, br_s00_arburst;
    logic         br_s00_awlock, br_s00_arlock;
    logic [3:0]   br_s00_awcache, br_s00_arcache;
    logic [2:0]   br_s00_awprot, br_s00_arprot;
    logic [3:0]   br_s00_awqos, br_s00_arqos;
    logic         br_s00_awvalid, br_s00_awready;
    logic [3:0]   br_s00_wstrb;
    logic         br_s00_wlast, br_s00_wvalid, br_s00_wready;
    logic [1:0]   br_s00_bresp, br_s00_rresp;
    logic         br_s00_bvalid, br_s00_bready;
    logic         br_s00_arvalid, br_s00_arready;
    logic         br_s00_rlast, br_s00_rvalid, br_s00_rready;

    logic [XBAR_ID_W-1:0] br_s01_awid, br_s01_arid, br_s01_bid, br_s01_rid;
    logic [31:0]  br_s01_awaddr, br_s01_araddr, br_s01_wdata, br_s01_rdata;
    logic [7:0]   br_s01_awlen, br_s01_arlen;
    logic [2:0]   br_s01_awsize, br_s01_arsize;
    logic [1:0]   br_s01_awburst, br_s01_arburst;
    logic         br_s01_awlock, br_s01_arlock;
    logic [3:0]   br_s01_awcache, br_s01_arcache;
    logic [2:0]   br_s01_awprot, br_s01_arprot;
    logic [3:0]   br_s01_awqos, br_s01_arqos;
    logic         br_s01_awvalid, br_s01_awready;
    logic [3:0]   br_s01_wstrb;
    logic         br_s01_wlast, br_s01_wvalid, br_s01_wready;
    logic [1:0]   br_s01_bresp, br_s01_rresp;
    logic         br_s01_bvalid, br_s01_bready;
    logic         br_s01_arvalid, br_s01_arready;
    logic         br_s01_rlast, br_s01_rvalid, br_s01_rready;

    logic [XBAR_ID_W-1:0] br_s02_awid, br_s02_arid, br_s02_bid, br_s02_rid;
    logic [31:0]  br_s02_awaddr, br_s02_araddr, br_s02_wdata, br_s02_rdata;
    logic [7:0]   br_s02_awlen, br_s02_arlen;
    logic [2:0]   br_s02_awsize, br_s02_arsize;
    logic [1:0]   br_s02_awburst, br_s02_arburst;
    logic         br_s02_awlock, br_s02_arlock;
    logic [3:0]   br_s02_awcache, br_s02_arcache;
    logic [2:0]   br_s02_awprot, br_s02_arprot;
    logic [3:0]   br_s02_awqos, br_s02_arqos;
    logic         br_s02_awvalid, br_s02_awready;
    logic [3:0]   br_s02_wstrb;
    logic         br_s02_wlast, br_s02_wvalid, br_s02_wready;
    logic [1:0]   br_s02_bresp, br_s02_rresp;
    logic         br_s02_bvalid, br_s02_bready;
    logic         br_s02_arvalid, br_s02_arready;
    logic         br_s02_rlast, br_s02_rvalid, br_s02_rready;

    axi64_to_32_bridge #(.S_ID_W(pt.LSU_BUS_TAG), .M_ID_W(XBAR_ID_W)) u_br_s00 (
        .clk(clk), .rst_n(rst_n),
        .s_awid(lsu_awid),         .s_awaddr(lsu_awaddr),
        .s_awlen(lsu_awlen),       .s_awsize(lsu_awsize),
        .s_awburst(lsu_awburst),   .s_awlock(lsu_awlock),
        .s_awcache(lsu_awcache),   .s_awprot(lsu_awprot),
        .s_awqos(lsu_awqos),       .s_awvalid(lsu_awvalid),
        .s_awready(lsu_awready),   .s_wdata(lsu_wdata),
        .s_wstrb(lsu_wstrb),       .s_wlast(lsu_wlast),
        .s_wvalid(lsu_wvalid),     .s_wready(lsu_wready),
        .s_bid(lsu_bid),           .s_bresp(lsu_bresp),
        .s_bvalid(lsu_bvalid),     .s_bready(lsu_bready),
        .s_arid(lsu_arid),         .s_araddr(lsu_araddr),
        .s_arlen(lsu_arlen),       .s_arsize(lsu_arsize),
        .s_arburst(lsu_arburst),   .s_arlock(lsu_arlock),
        .s_arcache(lsu_arcache),   .s_arprot(lsu_arprot),
        .s_arqos(lsu_arqos),       .s_arvalid(lsu_arvalid),
        .s_arready(lsu_arready),   .s_rid(lsu_rid),
        .s_rdata(lsu_rdata),       .s_rresp(lsu_rresp),
        .s_rlast(lsu_rlast),       .s_rvalid(lsu_rvalid),
        .s_rready(lsu_rready),
        .m_awid(br_s00_awid),      .m_awaddr(br_s00_awaddr),
        .m_awlen(br_s00_awlen),    .m_awsize(br_s00_awsize),
        .m_awburst(br_s00_awburst),.m_awlock(br_s00_awlock),
        .m_awcache(br_s00_awcache),.m_awprot(br_s00_awprot),
        .m_awqos(br_s00_awqos),    .m_awvalid(br_s00_awvalid),
        .m_awready(br_s00_awready),.m_wdata(br_s00_wdata),
        .m_wstrb(br_s00_wstrb),    .m_wlast(br_s00_wlast),
        .m_wvalid(br_s00_wvalid),  .m_wready(br_s00_wready),
        .m_bid(br_s00_bid),        .m_bresp(br_s00_bresp),
        .m_bvalid(br_s00_bvalid),  .m_bready(br_s00_bready),
        .m_arid(br_s00_arid),      .m_araddr(br_s00_araddr),
        .m_arlen(br_s00_arlen),    .m_arsize(br_s00_arsize),
        .m_arburst(br_s00_arburst),.m_arlock(br_s00_arlock),
        .m_arcache(br_s00_arcache),.m_arprot(br_s00_arprot),
        .m_arqos(br_s00_arqos),    .m_arvalid(br_s00_arvalid),
        .m_arready(br_s00_arready),.m_rid(br_s00_rid),
        .m_rdata(br_s00_rdata),    .m_rresp(br_s00_rresp),
        .m_rlast(br_s00_rlast),    .m_rvalid(br_s00_rvalid),
        .m_rready(br_s00_rready)
    );

    axi64_to_32_bridge #(.S_ID_W(pt.IFU_BUS_TAG), .M_ID_W(XBAR_ID_W)) u_br_s01 (
        .clk(clk), .rst_n(rst_n),
        .s_awid(ifu_awid),         .s_awaddr(ifu_awaddr),
        .s_awlen(ifu_awlen),       .s_awsize(ifu_awsize),
        .s_awburst(ifu_awburst),   .s_awlock(ifu_awlock),
        .s_awcache(ifu_awcache),   .s_awprot(ifu_awprot),
        .s_awqos(ifu_awqos),       .s_awvalid(ifu_awvalid),
        .s_awready(ifu_awready),   .s_wdata(ifu_wdata),
        .s_wstrb(ifu_wstrb),       .s_wlast(ifu_wlast),
        .s_wvalid(ifu_wvalid),     .s_wready(ifu_wready),
        .s_bid(ifu_bid),           .s_bresp(ifu_bresp),
        .s_bvalid(ifu_bvalid),     .s_bready(ifu_bready),
        .s_arid(ifu_arid),         .s_araddr(ifu_araddr),
        .s_arlen(ifu_arlen),       .s_arsize(ifu_arsize),
        .s_arburst(ifu_arburst),   .s_arlock(ifu_arlock),
        .s_arcache(ifu_arcache),   .s_arprot(ifu_arprot),
        .s_arqos(ifu_arqos),       .s_arvalid(ifu_arvalid),
        .s_arready(ifu_arready),   .s_rid(ifu_rid),
        .s_rdata(ifu_rdata),       .s_rresp(ifu_rresp),
        .s_rlast(ifu_rlast),       .s_rvalid(ifu_rvalid),
        .s_rready(ifu_rready),
        .m_awid(br_s01_awid),      .m_awaddr(br_s01_awaddr),
        .m_awlen(br_s01_awlen),    .m_awsize(br_s01_awsize),
        .m_awburst(br_s01_awburst),.m_awlock(br_s01_awlock),
        .m_awcache(br_s01_awcache),.m_awprot(br_s01_awprot),
        .m_awqos(br_s01_awqos),    .m_awvalid(br_s01_awvalid),
        .m_awready(br_s01_awready),.m_wdata(br_s01_wdata),
        .m_wstrb(br_s01_wstrb),    .m_wlast(br_s01_wlast),
        .m_wvalid(br_s01_wvalid),  .m_wready(br_s01_wready),
        .m_bid(br_s01_bid),        .m_bresp(br_s01_bresp),
        .m_bvalid(br_s01_bvalid),  .m_bready(br_s01_bready),
        .m_arid(br_s01_arid),      .m_araddr(br_s01_araddr),
        .m_arlen(br_s01_arlen),    .m_arsize(br_s01_arsize),
        .m_arburst(br_s01_arburst),.m_arlock(br_s01_arlock),
        .m_arcache(br_s01_arcache),.m_arprot(br_s01_arprot),
        .m_arqos(br_s01_arqos),    .m_arvalid(br_s01_arvalid),
        .m_arready(br_s01_arready),.m_rid(br_s01_rid),
        .m_rdata(br_s01_rdata),    .m_rresp(br_s01_rresp),
        .m_rlast(br_s01_rlast),    .m_rvalid(br_s01_rvalid),
        .m_rready(br_s01_rready)
    );

    axi64_to_32_bridge #(.S_ID_W(pt.SB_BUS_TAG), .M_ID_W(XBAR_ID_W)) u_br_s02 (
        .clk(clk), .rst_n(rst_n),
        .s_awid(sb_awid),          .s_awaddr(sb_awaddr),
        .s_awlen(sb_awlen),        .s_awsize(sb_awsize),
        .s_awburst(sb_awburst),    .s_awlock(sb_awlock),
        .s_awcache(sb_awcache),    .s_awprot(sb_awprot),
        .s_awqos(sb_awqos),        .s_awvalid(sb_awvalid),
        .s_awready(sb_awready),    .s_wdata(sb_wdata),
        .s_wstrb(sb_wstrb),        .s_wlast(sb_wlast),
        .s_wvalid(sb_wvalid),      .s_wready(sb_wready),
        .s_bid(sb_bid),            .s_bresp(sb_bresp),
        .s_bvalid(sb_bvalid),      .s_bready(sb_bready),
        .s_arid(sb_arid),          .s_araddr(sb_araddr),
        .s_arlen(sb_arlen),        .s_arsize(sb_arsize),
        .s_arburst(sb_arburst),    .s_arlock(sb_arlock),
        .s_arcache(sb_arcache),    .s_arprot(sb_arprot),
        .s_arqos(sb_arqos),        .s_arvalid(sb_arvalid),
        .s_arready(sb_arready),    .s_rid(sb_rid),
        .s_rdata(sb_rdata),        .s_rresp(sb_rresp),
        .s_rlast(sb_rlast),        .s_rvalid(sb_rvalid),
        .s_rready(sb_rready),
        .m_awid(br_s02_awid),      .m_awaddr(br_s02_awaddr),
        .m_awlen(br_s02_awlen),    .m_awsize(br_s02_awsize),
        .m_awburst(br_s02_awburst),.m_awlock(br_s02_awlock),
        .m_awcache(br_s02_awcache),.m_awprot(br_s02_awprot),
        .m_awqos(br_s02_awqos),    .m_awvalid(br_s02_awvalid),
        .m_awready(br_s02_awready),.m_wdata(br_s02_wdata),
        .m_wstrb(br_s02_wstrb),    .m_wlast(br_s02_wlast),
        .m_wvalid(br_s02_wvalid),  .m_wready(br_s02_wready),
        .m_bid(br_s02_bid),        .m_bresp(br_s02_bresp),
        .m_bvalid(br_s02_bvalid),  .m_bready(br_s02_bready),
        .m_arid(br_s02_arid),      .m_araddr(br_s02_araddr),
        .m_arlen(br_s02_arlen),    .m_arsize(br_s02_arsize),
        .m_arburst(br_s02_arburst),.m_arlock(br_s02_arlock),
        .m_arcache(br_s02_arcache),.m_arprot(br_s02_arprot),
        .m_arqos(br_s02_arqos),    .m_arvalid(br_s02_arvalid),
        .m_arready(br_s02_arready),.m_rid(br_s02_rid),
        .m_rdata(br_s02_rdata),    .m_rresp(br_s02_rresp),
        .m_rlast(br_s02_rlast),    .m_rvalid(br_s02_rvalid),
        .m_rready(br_s02_rready)
    );

    // =========================================================================
    // UART interrupt wiring
    // =========================================================================
    logic uart_irq;

    // =========================================================================
    // Memory export interface (required by el2_veer_wrapper)
    // =========================================================================
    el2_mem_if el2_mem_export ();
    el2_mem_if el2_icache_export ();

    // =========================================================================
    // VeeR EL2 core
    // =========================================================================
    el2_veer_wrapper #(.pt(pt)) u_veer (
        .clk                        (clk),
        .rst_l                      (rst_n),
        .dbg_rst_l                  (rst_n),
        .rst_vec                    (31'h0000_0000),
        .nmi_int                    (1'b0),
        .nmi_vec                    (31'h1111_1111),
        .jtag_id                    (31'h0),

        // Trace (unused)
        .trace_rv_i_insn_ip         (),
        .trace_rv_i_address_ip      (),
        .trace_rv_i_valid_ip        (),
        .trace_rv_i_exception_ip    (),
        .trace_rv_i_ecause_ip       (),
        .trace_rv_i_interrupt_ip    (),
        .trace_rv_i_tval_ip         (),

`ifdef RV_BUILD_AXI4
        // --- LSU AXI ---
        .lsu_axi_awvalid            (lsu_awvalid),
        .lsu_axi_awready            (lsu_awready),
        .lsu_axi_awid               (lsu_awid),
        .lsu_axi_awaddr             (lsu_awaddr),
        .lsu_axi_awregion           (),
        .lsu_axi_awlen              (lsu_awlen),
        .lsu_axi_awsize             (lsu_awsize),
        .lsu_axi_awburst            (lsu_awburst),
        .lsu_axi_awlock             (lsu_awlock),
        .lsu_axi_awcache            (lsu_awcache),
        .lsu_axi_awprot             (lsu_awprot),
        .lsu_axi_awqos              (lsu_awqos),
        .lsu_axi_wvalid             (lsu_wvalid),
        .lsu_axi_wready             (lsu_wready),
        .lsu_axi_wdata              (lsu_wdata),
        .lsu_axi_wstrb              (lsu_wstrb),
        .lsu_axi_wlast              (lsu_wlast),
        .lsu_axi_bvalid             (lsu_bvalid),
        .lsu_axi_bready             (lsu_bready),
        .lsu_axi_bresp              (lsu_bresp),
        .lsu_axi_bid                (lsu_bid),
        .lsu_axi_arvalid            (lsu_arvalid),
        .lsu_axi_arready            (lsu_arready),
        .lsu_axi_arid               (lsu_arid),
        .lsu_axi_araddr             (lsu_araddr),
        .lsu_axi_arregion           (),
        .lsu_axi_arlen              (lsu_arlen),
        .lsu_axi_arsize             (lsu_arsize),
        .lsu_axi_arburst            (lsu_arburst),
        .lsu_axi_arlock             (lsu_arlock),
        .lsu_axi_arcache            (lsu_arcache),
        .lsu_axi_arprot             (lsu_arprot),
        .lsu_axi_arqos              (lsu_arqos),
        .lsu_axi_rvalid             (lsu_rvalid),
        .lsu_axi_rready             (lsu_rready),
        .lsu_axi_rid                (lsu_rid),
        .lsu_axi_rdata              (lsu_rdata),
        .lsu_axi_rresp              (lsu_rresp),
        .lsu_axi_rlast              (lsu_rlast),

        // --- IFU AXI ---
        .ifu_axi_awvalid            (ifu_awvalid),
        .ifu_axi_awready            (ifu_awready),
        .ifu_axi_awid               (ifu_awid),
        .ifu_axi_awaddr             (ifu_awaddr),
        .ifu_axi_awregion           (),
        .ifu_axi_awlen              (ifu_awlen),
        .ifu_axi_awsize             (ifu_awsize),
        .ifu_axi_awburst            (ifu_awburst),
        .ifu_axi_awlock             (ifu_awlock),
        .ifu_axi_awcache            (ifu_awcache),
        .ifu_axi_awprot             (ifu_awprot),
        .ifu_axi_awqos              (ifu_awqos),
        .ifu_axi_wvalid             (ifu_wvalid),
        .ifu_axi_wready             (ifu_wready),
        .ifu_axi_wdata              (ifu_wdata),
        .ifu_axi_wstrb              (ifu_wstrb),
        .ifu_axi_wlast              (ifu_wlast),
        .ifu_axi_bvalid             (ifu_bvalid),
        .ifu_axi_bready             (ifu_bready),
        .ifu_axi_bresp              (ifu_bresp),
        .ifu_axi_bid                (ifu_bid),
        .ifu_axi_arvalid            (ifu_arvalid),
        .ifu_axi_arready            (ifu_arready),
        .ifu_axi_arid               (ifu_arid),
        .ifu_axi_araddr             (ifu_araddr),
        .ifu_axi_arregion           (),
        .ifu_axi_arlen              (ifu_arlen),
        .ifu_axi_arsize             (ifu_arsize),
        .ifu_axi_arburst            (ifu_arburst),
        .ifu_axi_arlock             (ifu_arlock),
        .ifu_axi_arcache            (ifu_arcache),
        .ifu_axi_arprot             (ifu_arprot),
        .ifu_axi_arqos              (ifu_arqos),
        .ifu_axi_rvalid             (ifu_rvalid),
        .ifu_axi_rready             (ifu_rready),
        .ifu_axi_rid                (ifu_rid),
        .ifu_axi_rdata              (ifu_rdata),
        .ifu_axi_rresp              (ifu_rresp),
        .ifu_axi_rlast              (ifu_rlast),

        // --- SB AXI ---
        .sb_axi_awvalid             (sb_awvalid),
        .sb_axi_awready             (sb_awready),
        .sb_axi_awid                (sb_awid),
        .sb_axi_awaddr              (sb_awaddr),
        .sb_axi_awregion            (),
        .sb_axi_awlen               (sb_awlen),
        .sb_axi_awsize              (sb_awsize),
        .sb_axi_awburst             (sb_awburst),
        .sb_axi_awlock              (sb_awlock),
        .sb_axi_awcache             (sb_awcache),
        .sb_axi_awprot              (sb_awprot),
        .sb_axi_awqos               (sb_awqos),
        .sb_axi_wvalid              (sb_wvalid),
        .sb_axi_wready              (sb_wready),
        .sb_axi_wdata               (sb_wdata),
        .sb_axi_wstrb               (sb_wstrb),
        .sb_axi_wlast               (sb_wlast),
        .sb_axi_bvalid              (sb_bvalid),
        .sb_axi_bready              (sb_bready),
        .sb_axi_bresp               (sb_bresp),
        .sb_axi_bid                 (sb_bid),
        .sb_axi_arvalid             (sb_arvalid),
        .sb_axi_arready             (sb_arready),
        .sb_axi_arid                (sb_arid),
        .sb_axi_araddr              (sb_araddr),
        .sb_axi_arregion            (),
        .sb_axi_arlen               (sb_arlen),
        .sb_axi_arsize              (sb_arsize),
        .sb_axi_arburst             (sb_arburst),
        .sb_axi_arlock              (sb_arlock),
        .sb_axi_arcache             (sb_arcache),
        .sb_axi_arprot              (sb_arprot),
        .sb_axi_arqos               (sb_arqos),
        .sb_axi_rvalid              (sb_rvalid),
        .sb_axi_rready              (sb_rready),
        .sb_axi_rid                 (sb_rid),
        .sb_axi_rdata               (sb_rdata),
        .sb_axi_rresp               (sb_rresp),
        .sb_axi_rlast               (sb_rlast),

        // --- DMA AXI (not used — tie off) ---
        .dma_axi_awvalid            (1'b0),
        .dma_axi_awready            (),
        .dma_axi_awid               ('0),
        .dma_axi_awaddr             (32'b0),
        .dma_axi_awsize             (3'b0),
        .dma_axi_awprot             (3'b0),
        .dma_axi_awlen              (8'b0),
        .dma_axi_awburst            (2'b0),
        .dma_axi_wvalid             (1'b0),
        .dma_axi_wready             (),
        .dma_axi_wdata              (64'b0),
        .dma_axi_wstrb              (8'b0),
        .dma_axi_wlast              (1'b0),
        .dma_axi_bvalid             (),
        .dma_axi_bready             (1'b1),
        .dma_axi_bresp              (),
        .dma_axi_bid                (),
        .dma_axi_arvalid            (1'b0),
        .dma_axi_arready            (),
        .dma_axi_arid               ('0),
        .dma_axi_araddr             (32'b0),
        .dma_axi_arsize             (3'b0),
        .dma_axi_arprot             (3'b0),
        .dma_axi_arlen              (8'b0),
        .dma_axi_arburst            (2'b0),
        .dma_axi_rvalid             (),
        .dma_axi_rready             (1'b1),
        .dma_axi_rid                (),
        .dma_axi_rdata              (),
        .dma_axi_rresp              (),
        .dma_axi_rlast              (),
`endif

        // Clock enables
        .lsu_bus_clk_en             (lsu_bus_clk_en),
        .ifu_bus_clk_en             (ifu_bus_clk_en),
        .dbg_bus_clk_en             (dbg_bus_clk_en),
        .dma_bus_clk_en             (dma_bus_clk_en),

        // Debug halt/run — tie to "run after reset" (matches VeeR tb_top:
        // mpc_reset_run_req=1, all halt/run req=0). Leaving these
        // unconnected holds the core in halt (X) so no IFU/LSU AXI appears.
        .mpc_debug_halt_req         (1'b0),
        .mpc_debug_run_req          (1'b0),
        .mpc_reset_run_req          (1'b1),
        .mpc_debug_halt_ack         (),
        .mpc_debug_run_ack          (),
        .debug_brkpt_status         (),
        .i_cpu_halt_req             (1'b0),
        .o_cpu_halt_ack             (),
        .o_cpu_halt_status          (),
        .o_debug_mode_status        (),
        .i_cpu_run_req              (1'b0),
        .o_cpu_run_ack              (),

        // ECC (unused outputs)
        .iccm_ecc_single_error      (),
        .iccm_ecc_double_error      (),
        .dccm_ecc_single_error      (),
        .dccm_ecc_double_error      (),
        .dccm_write_readback_error  (),

        // ICache export
        .el2_icache_export          (el2_icache_export),

        // Interrupts
        .timer_int                  (1'b0),
        .soft_int                   (1'b0),
        .extintsrc_req              (extintsrc_req),

        // Perf counters (unused)
        .dec_tlu_perfcnt0           (),
        .dec_tlu_perfcnt1           (),
        .dec_tlu_perfcnt2           (),
        .dec_tlu_perfcnt3           (),

        // JTAG
        .jtag_tck                   (jtag_tck),
        .jtag_tms                   (jtag_tms),
        .jtag_tdi                   (jtag_tdi),
        .jtag_trst_n                (jtag_trst_n),
        .jtag_tdo                   (jtag_tdo),
        .jtag_tdoEn                 (jtag_tdo_en),

        .core_id                    (28'h0),
        .el2_mem_export             (el2_mem_export)
    );

    // =========================================================================
    // AXI Interconnect 5x16
    //
    // Base address table (passed to wrapper as parameters):
    //   m00: 0x0000_0000  DRAM
    //   m01: 0x0100_0000  ICCM
    //   m02: 0x2000_0000  NDA ctrl (stub)
    //   m03: 0x2000_1000  Watchdog (stub)
    //   m04: 0x2000_2000  HPM      (stub)
    //   m05: 0x2000_3000  UART
    //   m06-m15: unconnected slaves (interconnect returns DECERR)
    // =========================================================================

    // Interconnect master-port buses (m = slave-facing)
    // m00 = DRAM stub (axi_stub_mem, responds OKAY+NOP so boot fetch completes)
    // m05 = UART (real). m01-m04/m06-m15 remain tied stubs (DECERR via DROP
    //       only for unmapped addresses; in-range hits to dead slaves hang —
    //       TB must avoid those addresses, see testbench).

    // --- m00 DRAM stub wires ---
    logic                    m00_awvalid, m00_awready;
    logic [XBAR_ID_W-1:0]    m00_awid;
    logic [31:0]             m00_awaddr;
    logic [7:0]              m00_awlen;
    logic [2:0]              m00_awsize;
    logic [1:0]              m00_awburst;
    logic                    m00_awlock;
    logic [3:0]              m00_awcache;
    logic [2:0]              m00_awprot;
    logic [3:0]              m00_awqos;
    logic [3:0]              m00_awregion;
    logic                    m00_wvalid,  m00_wready;
    logic [31:0]             m00_wdata;
    logic [3:0]              m00_wstrb;
    logic                    m00_wlast;
    logic                    m00_bvalid,  m00_bready;
    logic [XBAR_ID_W-1:0]    m00_bid;
    logic [1:0]              m00_bresp;
    logic                    m00_arvalid, m00_arready;
    logic [XBAR_ID_W-1:0]    m00_arid;
    logic [31:0]             m00_araddr;
    logic [7:0]              m00_arlen;
    logic [2:0]              m00_arsize;
    logic [1:0]              m00_arburst;
    logic                    m00_arlock;
    logic [3:0]              m00_arcache;
    logic [2:0]              m00_arprot;
    logic [3:0]              m00_arqos;
    logic [3:0]              m00_arregion;
    logic                    m00_rvalid,  m00_rready;
    logic [XBAR_ID_W-1:0]    m00_rid;
    logic [31:0]             m00_rdata;
    logic [1:0]              m00_rresp;
    logic                    m00_rlast;

    // --- m05 UART wires ---
    logic                    m05_awvalid, m05_awready;
    logic [XBAR_ID_W-1:0]    m05_awid;
    logic [31:0]             m05_awaddr;
    logic [7:0]              m05_awlen;
    logic [2:0]              m05_awsize;
    logic [1:0]              m05_awburst;
    logic                    m05_awlock;
    logic [3:0]              m05_awcache;
    logic [2:0]              m05_awprot;
    logic [3:0]              m05_awqos;
    logic [3:0]              m05_awregion;
    logic                    m05_wvalid,  m05_wready;
    logic [31:0]             m05_wdata;
    logic [3:0]              m05_wstrb;
    logic                    m05_wlast;
    logic                    m05_bvalid,  m05_bready;
    logic [XBAR_ID_W-1:0]    m05_bid;
    logic [1:0]              m05_bresp;
    logic                    m05_arvalid, m05_arready;
    logic [XBAR_ID_W-1:0]    m05_arid;
    logic [31:0]             m05_araddr;
    logic [7:0]              m05_arlen;
    logic [2:0]              m05_arsize;
    logic [1:0]              m05_arburst;
    logic                    m05_arlock;
    logic [3:0]              m05_arcache;
    logic [2:0]              m05_arprot;
    logic [3:0]              m05_arqos;
    logic [3:0]              m05_arregion;
    logic                    m05_rvalid,  m05_rready;
    logic [XBAR_ID_W-1:0]    m05_rid;
    logic [31:0]             m05_rdata;
    logic [1:0]              m05_rresp;
    logic                    m05_rlast;

    // Interconnect instantiation
    // The auto-generated wrapper has flat named ports s00_axi_*, m00_axi_*, …
    // Masters s03/s04 and slaves m01-m04/m06-m15 (except m00/m05) are tied off.
    axi_interconnect_wrap_5x16 #(
        .M00_BASE_ADDR (32'h0000_0000), .M00_ADDR_WIDTH (32'd24),
        .M01_BASE_ADDR (32'h0100_0000), .M01_ADDR_WIDTH (32'd24),
        .M02_BASE_ADDR (32'h2000_0000), .M02_ADDR_WIDTH (32'd12),
        .M03_BASE_ADDR (32'h2000_1000), .M03_ADDR_WIDTH (32'd12),
        .M04_BASE_ADDR (32'h2000_2000), .M04_ADDR_WIDTH (32'd12),
        .M05_BASE_ADDR (32'h2000_3000), .M05_ADDR_WIDTH (32'd12),
        .M06_BASE_ADDR (32'h3000_0000), .M06_ADDR_WIDTH (32'd24),
        .M07_BASE_ADDR (32'h3100_0000), .M07_ADDR_WIDTH (32'd24),
        .M08_BASE_ADDR (32'h3200_0000), .M08_ADDR_WIDTH (32'd24),
        .M09_BASE_ADDR (32'h3300_0000), .M09_ADDR_WIDTH (32'd24),
        .M10_BASE_ADDR (32'h3400_0000), .M10_ADDR_WIDTH (32'd24),
        .M11_BASE_ADDR (32'h3500_0000), .M11_ADDR_WIDTH (32'd24),
        .M12_BASE_ADDR (32'h3600_0000), .M12_ADDR_WIDTH (32'd24),
        .M13_BASE_ADDR (32'h3700_0000), .M13_ADDR_WIDTH (32'd24),
        .M14_BASE_ADDR (32'h3800_0000), .M14_ADDR_WIDTH (32'd24),
        .M15_BASE_ADDR (32'h3900_0000), .M15_ADDR_WIDTH (32'd24)
    ) u_xbar (
        .clk    (clk),
        .rst    (~rst_n),   // interconnect uses active-high reset

        // ----------------------------------------------------------------
        // Slave (master) ports — CPU buses
        // ----------------------------------------------------------------

        // s00 — LSU via 64→32 bridge
        .s00_axi_awid       (br_s00_awid),
        .s00_axi_awaddr     (br_s00_awaddr),
        .s00_axi_awlen      (br_s00_awlen),
        .s00_axi_awsize     (br_s00_awsize),
        .s00_axi_awburst    (br_s00_awburst),
        .s00_axi_awlock     (br_s00_awlock),
        .s00_axi_awcache    (br_s00_awcache),
        .s00_axi_awprot     (br_s00_awprot),
        .s00_axi_awqos      (br_s00_awqos),
        .s00_axi_awuser     (1'b0),
        .s00_axi_awvalid    (br_s00_awvalid),
        .s00_axi_awready    (br_s00_awready),
        .s00_axi_wdata      (br_s00_wdata),
        .s00_axi_wstrb      (br_s00_wstrb),
        .s00_axi_wlast      (br_s00_wlast),
        .s00_axi_wuser      (1'b0),
        .s00_axi_wvalid     (br_s00_wvalid),
        .s00_axi_wready     (br_s00_wready),
        .s00_axi_bid        (br_s00_bid),
        .s00_axi_bresp      (br_s00_bresp),
        .s00_axi_buser      (),
        .s00_axi_bvalid     (br_s00_bvalid),
        .s00_axi_bready     (br_s00_bready),
        .s00_axi_arid       (br_s00_arid),
        .s00_axi_araddr     (br_s00_araddr),
        .s00_axi_arlen      (br_s00_arlen),
        .s00_axi_arsize     (br_s00_arsize),
        .s00_axi_arburst    (br_s00_arburst),
        .s00_axi_arlock     (br_s00_arlock),
        .s00_axi_arcache    (br_s00_arcache),
        .s00_axi_arprot     (br_s00_arprot),
        .s00_axi_arqos      (br_s00_arqos),
        .s00_axi_aruser     (1'b0),
        .s00_axi_arvalid    (br_s00_arvalid),
        .s00_axi_arready    (br_s00_arready),
        .s00_axi_rid        (br_s00_rid),
        .s00_axi_rdata      (br_s00_rdata),
        .s00_axi_rresp      (br_s00_rresp),
        .s00_axi_rlast      (br_s00_rlast),
        .s00_axi_ruser      (),
        .s00_axi_rvalid     (br_s00_rvalid),
        .s00_axi_rready     (br_s00_rready),

        // s01 — IFU via 64→32 bridge
        .s01_axi_awid       (br_s01_awid),
        .s01_axi_awaddr     (br_s01_awaddr),
        .s01_axi_awlen      (br_s01_awlen),
        .s01_axi_awsize     (br_s01_awsize),
        .s01_axi_awburst    (br_s01_awburst),
        .s01_axi_awlock     (br_s01_awlock),
        .s01_axi_awcache    (br_s01_awcache),
        .s01_axi_awprot     (br_s01_awprot),
        .s01_axi_awqos      (br_s01_awqos),
        .s01_axi_awuser     (1'b0),
        .s01_axi_awvalid    (br_s01_awvalid),
        .s01_axi_awready    (br_s01_awready),
        .s01_axi_wdata      (br_s01_wdata),
        .s01_axi_wstrb      (br_s01_wstrb),
        .s01_axi_wlast      (br_s01_wlast),
        .s01_axi_wuser      (1'b0),
        .s01_axi_wvalid     (br_s01_wvalid),
        .s01_axi_wready     (br_s01_wready),
        .s01_axi_bid        (br_s01_bid),
        .s01_axi_bresp      (br_s01_bresp),
        .s01_axi_buser      (),
        .s01_axi_bvalid     (br_s01_bvalid),
        .s01_axi_bready     (br_s01_bready),
        .s01_axi_arid       (br_s01_arid),
        .s01_axi_araddr     (br_s01_araddr),
        .s01_axi_arlen      (br_s01_arlen),
        .s01_axi_arsize     (br_s01_arsize),
        .s01_axi_arburst    (br_s01_arburst),
        .s01_axi_arlock     (br_s01_arlock),
        .s01_axi_arcache    (br_s01_arcache),
        .s01_axi_arprot     (br_s01_arprot),
        .s01_axi_arqos      (br_s01_arqos),
        .s01_axi_aruser     (1'b0),
        .s01_axi_arvalid    (br_s01_arvalid),
        .s01_axi_arready    (br_s01_arready),
        .s01_axi_rid        (br_s01_rid),
        .s01_axi_rdata      (br_s01_rdata),
        .s01_axi_rresp      (br_s01_rresp),
        .s01_axi_rlast      (br_s01_rlast),
        .s01_axi_ruser      (),
        .s01_axi_rvalid     (br_s01_rvalid),
        .s01_axi_rready     (br_s01_rready),

        // s02 — SB via 64→32 bridge
        .s02_axi_awid       (br_s02_awid),
        .s02_axi_awaddr     (br_s02_awaddr),
        .s02_axi_awlen      (br_s02_awlen),
        .s02_axi_awsize     (br_s02_awsize),
        .s02_axi_awburst    (br_s02_awburst),
        .s02_axi_awlock     (br_s02_awlock),
        .s02_axi_awcache    (br_s02_awcache),
        .s02_axi_awprot     (br_s02_awprot),
        .s02_axi_awqos      (br_s02_awqos),
        .s02_axi_awuser     (1'b0),
        .s02_axi_awvalid    (br_s02_awvalid),
        .s02_axi_awready    (br_s02_awready),
        .s02_axi_wdata      (br_s02_wdata),
        .s02_axi_wstrb      (br_s02_wstrb),
        .s02_axi_wlast      (br_s02_wlast),
        .s02_axi_wuser      (1'b0),
        .s02_axi_wvalid     (br_s02_wvalid),
        .s02_axi_wready     (br_s02_wready),
        .s02_axi_bid        (br_s02_bid),
        .s02_axi_bresp      (br_s02_bresp),
        .s02_axi_buser      (),
        .s02_axi_bvalid     (br_s02_bvalid),
        .s02_axi_bready     (br_s02_bready),
        .s02_axi_arid       (br_s02_arid),
        .s02_axi_araddr     (br_s02_araddr),
        .s02_axi_arlen      (br_s02_arlen),
        .s02_axi_arsize     (br_s02_arsize),
        .s02_axi_arburst    (br_s02_arburst),
        .s02_axi_arlock     (br_s02_arlock),
        .s02_axi_arcache    (br_s02_arcache),
        .s02_axi_arprot     (br_s02_arprot),
        .s02_axi_arqos      (br_s02_arqos),
        .s02_axi_aruser     (1'b0),
        .s02_axi_arvalid    (br_s02_arvalid),
        .s02_axi_arready    (br_s02_arready),
        .s02_axi_rid        (br_s02_rid),
        .s02_axi_rdata      (br_s02_rdata),
        .s02_axi_rresp      (br_s02_rresp),
        .s02_axi_rlast      (br_s02_rlast),
        .s02_axi_ruser      (),
        .s02_axi_rvalid     (br_s02_rvalid),
        .s02_axi_rready     (br_s02_rready),

        // s03 — NDA seat: TB-driven test hooks (idle by default).
        // No force needed; tb_core_uart drives tb_s03_* procedurally.
        .s03_axi_awid       (tb_s03_awid),
        .s03_axi_awaddr     (tb_s03_awaddr),
        .s03_axi_awlen      (tb_s03_awlen),
        .s03_axi_awsize     (tb_s03_awsize),
        .s03_axi_awburst    (tb_s03_awburst),
        .s03_axi_awlock     (1'b0),
        .s03_axi_awcache    (4'b0),
        .s03_axi_awprot     (3'b0),
        .s03_axi_awqos      (4'b0),
        .s03_axi_awuser     (1'b0),
        .s03_axi_awvalid    (tb_s03_awvalid),
        .s03_axi_awready    (tb_s03_awready),
        .s03_axi_wdata      (tb_s03_wdata),
        .s03_axi_wstrb      (tb_s03_wstrb),
        .s03_axi_wlast      (tb_s03_wlast),
        .s03_axi_wuser      (1'b0),
        .s03_axi_wvalid     (tb_s03_wvalid),
        .s03_axi_wready     (tb_s03_wready),
        .s03_axi_bid        (tb_s03_bid),
        .s03_axi_bresp      (tb_s03_bresp),
        .s03_axi_buser      (),
        .s03_axi_bvalid     (tb_s03_bvalid),
        .s03_axi_bready     (tb_s03_bready),
        .s03_axi_arid       (tb_s03_arid),
        .s03_axi_araddr     (tb_s03_araddr),
        .s03_axi_arlen      (tb_s03_arlen),
        .s03_axi_arsize     (tb_s03_arsize),
        .s03_axi_arburst    (tb_s03_arburst),
        .s03_axi_arlock     (1'b0),
        .s03_axi_arcache    (4'b0),
        .s03_axi_arprot     (3'b0),
        .s03_axi_arqos      (4'b0),
        .s03_axi_aruser     (1'b0),
        .s03_axi_arvalid    (tb_s03_arvalid),
        .s03_axi_arready    (tb_s03_arready),
        .s03_axi_rid        (tb_s03_rid),
        .s03_axi_rdata      (tb_s03_rdata),
        .s03_axi_rresp      (tb_s03_rresp),
        .s03_axi_rlast      (tb_s03_rlast),
        .s03_axi_ruser      (),
        .s03_axi_rvalid     (tb_s03_rvalid),
        .s03_axi_rready     (tb_s03_rready),

        // s04 — reserved (tied off)
        .s04_axi_awid       ('0), .s04_axi_awaddr('0), .s04_axi_awlen('0),
        .s04_axi_awsize     ('0), .s04_axi_awburst('0), .s04_axi_awlock('0),
        .s04_axi_awcache    ('0), .s04_axi_awprot('0), .s04_axi_awqos('0),
        .s04_axi_awuser     ('0), .s04_axi_awvalid(1'b0), .s04_axi_awready(),
        .s04_axi_wdata      ('0), .s04_axi_wstrb('0), .s04_axi_wlast(1'b0),
        .s04_axi_wuser      ('0), .s04_axi_wvalid(1'b0), .s04_axi_wready(),
        .s04_axi_bid        (), .s04_axi_bresp(), .s04_axi_buser(),
        .s04_axi_bvalid     (), .s04_axi_bready(1'b1),
        .s04_axi_arid       ('0), .s04_axi_araddr('0), .s04_axi_arlen('0),
        .s04_axi_arsize     ('0), .s04_axi_arburst('0), .s04_axi_arlock('0),
        .s04_axi_arcache    ('0), .s04_axi_arprot('0), .s04_axi_arqos('0),
        .s04_axi_aruser     ('0), .s04_axi_arvalid(1'b0), .s04_axi_arready(),
        .s04_axi_rid        (), .s04_axi_rdata(), .s04_axi_rresp(),
        .s04_axi_rlast      (), .s04_axi_ruser(), .s04_axi_rvalid(),
        .s04_axi_rready     (1'b1),

        // ----------------------------------------------------------------
        // Master ports — peripheral slaves
        // ----------------------------------------------------------------
        // m00 — DRAM stub (wired to axi_stub_mem below)
        .m00_axi_awid       (m00_awid),
        .m00_axi_awaddr     (m00_awaddr),
        .m00_axi_awlen      (m00_awlen),
        .m00_axi_awsize     (m00_awsize),
        .m00_axi_awburst    (m00_awburst),
        .m00_axi_awlock     (m00_awlock),
        .m00_axi_awcache    (m00_awcache),
        .m00_axi_awprot     (m00_awprot),
        .m00_axi_awqos      (m00_awqos),
        .m00_axi_awregion   (m00_awregion),
        .m00_axi_awuser     (),
        .m00_axi_awvalid    (m00_awvalid),
        .m00_axi_awready    (m00_awready),
        .m00_axi_wdata      (m00_wdata),
        .m00_axi_wstrb      (m00_wstrb),
        .m00_axi_wlast      (m00_wlast),
        .m00_axi_wuser      (),
        .m00_axi_wvalid     (m00_wvalid),
        .m00_axi_wready     (m00_wready),
        .m00_axi_bid        (m00_bid),
        .m00_axi_bresp      (m00_bresp),
        .m00_axi_buser      ('0),
        .m00_axi_bvalid     (m00_bvalid),
        .m00_axi_bready     (m00_bready),
        .m00_axi_arid       (m00_arid),
        .m00_axi_araddr     (m00_araddr),
        .m00_axi_arlen      (m00_arlen),
        .m00_axi_arsize     (m00_arsize),
        .m00_axi_arburst    (m00_arburst),
        .m00_axi_arlock     (m00_arlock),
        .m00_axi_arcache    (m00_arcache),
        .m00_axi_arprot     (m00_arprot),
        .m00_axi_arqos      (m00_arqos),
        .m00_axi_arregion   (m00_arregion),
        .m00_axi_aruser     (),
        .m00_axi_arvalid    (m00_arvalid),
        .m00_axi_arready    (m00_arready),
        .m00_axi_rid        (m00_rid),
        .m00_axi_rdata      (m00_rdata),
        .m00_axi_rresp      (m00_rresp),
        .m00_axi_rlast      (m00_rlast),
        .m00_axi_ruser      ('0),
        .m00_axi_rvalid     (m00_rvalid),
        .m00_axi_rready     (m00_rready),

        // m01-m04: stub slaves (tied off, interconnect returns DECERR for
        // out-of-range; connect real memories/peripherals here)
        .m01_axi_awid(), .m01_axi_awaddr(), .m01_axi_awlen(), .m01_axi_awsize(),
        .m01_axi_awburst(), .m01_axi_awlock(), .m01_axi_awcache(), .m01_axi_awprot(),
        .m01_axi_awqos(), .m01_axi_awregion(), .m01_axi_awuser(), .m01_axi_awvalid(),
        .m01_axi_awready(1'b0), .m01_axi_wdata(), .m01_axi_wstrb(), .m01_axi_wlast(),
        .m01_axi_wuser(), .m01_axi_wvalid(), .m01_axi_wready(1'b0),
        .m01_axi_bid('0), .m01_axi_bresp(2'b11), .m01_axi_buser('0),
        .m01_axi_bvalid(1'b0), .m01_axi_bready(),
        .m01_axi_arid(), .m01_axi_araddr(), .m01_axi_arlen(), .m01_axi_arsize(),
        .m01_axi_arburst(), .m01_axi_arlock(), .m01_axi_arcache(), .m01_axi_arprot(),
        .m01_axi_arqos(), .m01_axi_arregion(), .m01_axi_aruser(), .m01_axi_arvalid(),
        .m01_axi_arready(1'b0), .m01_axi_rid('0), .m01_axi_rdata('0),
        .m01_axi_rresp(2'b11), .m01_axi_rlast(1'b1), .m01_axi_ruser('0),
        .m01_axi_rvalid(1'b0), .m01_axi_rready(),

        // m02-m04 and m06-m15: same stub pattern (omitted for brevity)
        // TODO: connect NDA ctrl, watchdog, HPM when implemented
        .m02_axi_awid(), .m02_axi_awaddr(), .m02_axi_awlen(), .m02_axi_awsize(),
        .m02_axi_awburst(), .m02_axi_awlock(), .m02_axi_awcache(), .m02_axi_awprot(),
        .m02_axi_awqos(), .m02_axi_awregion(), .m02_axi_awuser(), .m02_axi_awvalid(),
        .m02_axi_awready(1'b0), .m02_axi_wdata(), .m02_axi_wstrb(), .m02_axi_wlast(),
        .m02_axi_wuser(), .m02_axi_wvalid(), .m02_axi_wready(1'b0),
        .m02_axi_bid('0), .m02_axi_bresp(2'b11), .m02_axi_buser('0),
        .m02_axi_bvalid(1'b0), .m02_axi_bready(),
        .m02_axi_arid(), .m02_axi_araddr(), .m02_axi_arlen(), .m02_axi_arsize(),
        .m02_axi_arburst(), .m02_axi_arlock(), .m02_axi_arcache(), .m02_axi_arprot(),
        .m02_axi_arqos(), .m02_axi_arregion(), .m02_axi_aruser(), .m02_axi_arvalid(),
        .m02_axi_arready(1'b0), .m02_axi_rid('0), .m02_axi_rdata('0),
        .m02_axi_rresp(2'b11), .m02_axi_rlast(1'b1), .m02_axi_ruser('0),
        .m02_axi_rvalid(1'b0), .m02_axi_rready(),

        .m03_axi_awid(), .m03_axi_awaddr(), .m03_axi_awlen(), .m03_axi_awsize(),
        .m03_axi_awburst(), .m03_axi_awlock(), .m03_axi_awcache(), .m03_axi_awprot(),
        .m03_axi_awqos(), .m03_axi_awregion(), .m03_axi_awuser(), .m03_axi_awvalid(),
        .m03_axi_awready(1'b0), .m03_axi_wdata(), .m03_axi_wstrb(), .m03_axi_wlast(),
        .m03_axi_wuser(), .m03_axi_wvalid(), .m03_axi_wready(1'b0),
        .m03_axi_bid('0), .m03_axi_bresp(2'b11), .m03_axi_buser('0),
        .m03_axi_bvalid(1'b0), .m03_axi_bready(),
        .m03_axi_arid(), .m03_axi_araddr(), .m03_axi_arlen(), .m03_axi_arsize(),
        .m03_axi_arburst(), .m03_axi_arlock(), .m03_axi_arcache(), .m03_axi_arprot(),
        .m03_axi_arqos(), .m03_axi_arregion(), .m03_axi_aruser(), .m03_axi_arvalid(),
        .m03_axi_arready(1'b0), .m03_axi_rid('0), .m03_axi_rdata('0),
        .m03_axi_rresp(2'b11), .m03_axi_rlast(1'b1), .m03_axi_ruser('0),
        .m03_axi_rvalid(1'b0), .m03_axi_rready(),

        .m04_axi_awid(), .m04_axi_awaddr(), .m04_axi_awlen(), .m04_axi_awsize(),
        .m04_axi_awburst(), .m04_axi_awlock(), .m04_axi_awcache(), .m04_axi_awprot(),
        .m04_axi_awqos(), .m04_axi_awregion(), .m04_axi_awuser(), .m04_axi_awvalid(),
        .m04_axi_awready(1'b0), .m04_axi_wdata(), .m04_axi_wstrb(), .m04_axi_wlast(),
        .m04_axi_wuser(), .m04_axi_wvalid(), .m04_axi_wready(1'b0),
        .m04_axi_bid('0), .m04_axi_bresp(2'b11), .m04_axi_buser('0),
        .m04_axi_bvalid(1'b0), .m04_axi_bready(),
        .m04_axi_arid(), .m04_axi_araddr(), .m04_axi_arlen(), .m04_axi_arsize(),
        .m04_axi_arburst(), .m04_axi_arlock(), .m04_axi_arcache(), .m04_axi_arprot(),
        .m04_axi_arqos(), .m04_axi_arregion(), .m04_axi_aruser(), .m04_axi_arvalid(),
        .m04_axi_arready(1'b0), .m04_axi_rid('0), .m04_axi_rdata('0),
        .m04_axi_rresp(2'b11), .m04_axi_rlast(1'b1), .m04_axi_ruser('0),
        .m04_axi_rvalid(1'b0), .m04_axi_rready(),

        // m05 — UART
        .m05_axi_awid       (m05_awid),
        .m05_axi_awaddr     (m05_awaddr),
        .m05_axi_awlen      (m05_awlen),
        .m05_axi_awsize     (m05_awsize),
        .m05_axi_awburst    (m05_awburst),
        .m05_axi_awlock     (m05_awlock),
        .m05_axi_awcache    (m05_awcache),
        .m05_axi_awprot     (m05_awprot),
        .m05_axi_awqos      (m05_awqos),
        .m05_axi_awregion   (m05_awregion),
        .m05_axi_awuser     (),
        .m05_axi_awvalid    (m05_awvalid),
        .m05_axi_awready    (m05_awready),
        .m05_axi_wdata      (m05_wdata),
        .m05_axi_wstrb      (m05_wstrb),
        .m05_axi_wlast      (m05_wlast),
        .m05_axi_wuser      (),
        .m05_axi_wvalid     (m05_wvalid),
        .m05_axi_wready     (m05_wready),
        .m05_axi_bid        (m05_bid),
        .m05_axi_bresp      (m05_bresp),
        .m05_axi_buser      ('0),
        .m05_axi_bvalid     (m05_bvalid),
        .m05_axi_bready     (m05_bready),
        .m05_axi_arid       (m05_arid),
        .m05_axi_araddr     (m05_araddr),
        .m05_axi_arlen      (m05_arlen),
        .m05_axi_arsize     (m05_arsize),
        .m05_axi_arburst    (m05_arburst),
        .m05_axi_arlock     (m05_arlock),
        .m05_axi_arcache    (m05_arcache),
        .m05_axi_arprot     (m05_arprot),
        .m05_axi_arqos      (m05_arqos),
        .m05_axi_arregion   (m05_arregion),
        .m05_axi_aruser     (),
        .m05_axi_arvalid    (m05_arvalid),
        .m05_axi_arready    (m05_arready),
        .m05_axi_rid        (m05_rid),
        .m05_axi_rdata      (m05_rdata),
        .m05_axi_rresp      (m05_rresp),
        .m05_axi_rlast      (m05_rlast),
        .m05_axi_ruser      ('0),
        .m05_axi_rvalid     (m05_rvalid),
        .m05_axi_rready     (m05_rready),

        // m06-m15: stub (tied off)
        .m06_axi_awid(), .m06_axi_awaddr(), .m06_axi_awlen(), .m06_axi_awsize(),
        .m06_axi_awburst(), .m06_axi_awlock(), .m06_axi_awcache(), .m06_axi_awprot(),
        .m06_axi_awqos(), .m06_axi_awregion(), .m06_axi_awuser(), .m06_axi_awvalid(),
        .m06_axi_awready(1'b0), .m06_axi_wdata(), .m06_axi_wstrb(), .m06_axi_wlast(),
        .m06_axi_wuser(), .m06_axi_wvalid(), .m06_axi_wready(1'b0),
        .m06_axi_bid('0), .m06_axi_bresp(2'b11), .m06_axi_buser('0),
        .m06_axi_bvalid(1'b0), .m06_axi_bready(),
        .m06_axi_arid(), .m06_axi_araddr(), .m06_axi_arlen(), .m06_axi_arsize(),
        .m06_axi_arburst(), .m06_axi_arlock(), .m06_axi_arcache(), .m06_axi_arprot(),
        .m06_axi_arqos(), .m06_axi_arregion(), .m06_axi_aruser(), .m06_axi_arvalid(),
        .m06_axi_arready(1'b0), .m06_axi_rid('0), .m06_axi_rdata('0),
        .m06_axi_rresp(2'b11), .m06_axi_rlast(1'b1), .m06_axi_ruser('0),
        .m06_axi_rvalid(1'b0), .m06_axi_rready(),

        .m07_axi_awid(), .m07_axi_awaddr(), .m07_axi_awlen(), .m07_axi_awsize(),
        .m07_axi_awburst(), .m07_axi_awlock(), .m07_axi_awcache(), .m07_axi_awprot(),
        .m07_axi_awqos(), .m07_axi_awregion(), .m07_axi_awuser(), .m07_axi_awvalid(),
        .m07_axi_awready(1'b0), .m07_axi_wdata(), .m07_axi_wstrb(), .m07_axi_wlast(),
        .m07_axi_wuser(), .m07_axi_wvalid(), .m07_axi_wready(1'b0),
        .m07_axi_bid('0), .m07_axi_bresp(2'b11), .m07_axi_buser('0),
        .m07_axi_bvalid(1'b0), .m07_axi_bready(),
        .m07_axi_arid(), .m07_axi_araddr(), .m07_axi_arlen(), .m07_axi_arsize(),
        .m07_axi_arburst(), .m07_axi_arlock(), .m07_axi_arcache(), .m07_axi_arprot(),
        .m07_axi_arqos(), .m07_axi_arregion(), .m07_axi_aruser(), .m07_axi_arvalid(),
        .m07_axi_arready(1'b0), .m07_axi_rid('0), .m07_axi_rdata('0),
        .m07_axi_rresp(2'b11), .m07_axi_rlast(1'b1), .m07_axi_ruser('0),
        .m07_axi_rvalid(1'b0), .m07_axi_rready(),

        .m08_axi_awid(), .m08_axi_awaddr(), .m08_axi_awlen(), .m08_axi_awsize(),
        .m08_axi_awburst(), .m08_axi_awlock(), .m08_axi_awcache(), .m08_axi_awprot(),
        .m08_axi_awqos(), .m08_axi_awregion(), .m08_axi_awuser(), .m08_axi_awvalid(),
        .m08_axi_awready(1'b0), .m08_axi_wdata(), .m08_axi_wstrb(), .m08_axi_wlast(),
        .m08_axi_wuser(), .m08_axi_wvalid(), .m08_axi_wready(1'b0),
        .m08_axi_bid('0), .m08_axi_bresp(2'b11), .m08_axi_buser('0),
        .m08_axi_bvalid(1'b0), .m08_axi_bready(),
        .m08_axi_arid(), .m08_axi_araddr(), .m08_axi_arlen(), .m08_axi_arsize(),
        .m08_axi_arburst(), .m08_axi_arlock(), .m08_axi_arcache(), .m08_axi_arprot(),
        .m08_axi_arqos(), .m08_axi_arregion(), .m08_axi_aruser(), .m08_axi_arvalid(),
        .m08_axi_arready(1'b0), .m08_axi_rid('0), .m08_axi_rdata('0),
        .m08_axi_rresp(2'b11), .m08_axi_rlast(1'b1), .m08_axi_ruser('0),
        .m08_axi_rvalid(1'b0), .m08_axi_rready(),

        .m09_axi_awid(), .m09_axi_awaddr(), .m09_axi_awlen(), .m09_axi_awsize(),
        .m09_axi_awburst(), .m09_axi_awlock(), .m09_axi_awcache(), .m09_axi_awprot(),
        .m09_axi_awqos(), .m09_axi_awregion(), .m09_axi_awuser(), .m09_axi_awvalid(),
        .m09_axi_awready(1'b0), .m09_axi_wdata(), .m09_axi_wstrb(), .m09_axi_wlast(),
        .m09_axi_wuser(), .m09_axi_wvalid(), .m09_axi_wready(1'b0),
        .m09_axi_bid('0), .m09_axi_bresp(2'b11), .m09_axi_buser('0),
        .m09_axi_bvalid(1'b0), .m09_axi_bready(),
        .m09_axi_arid(), .m09_axi_araddr(), .m09_axi_arlen(), .m09_axi_arsize(),
        .m09_axi_arburst(), .m09_axi_arlock(), .m09_axi_arcache(), .m09_axi_arprot(),
        .m09_axi_arqos(), .m09_axi_arregion(), .m09_axi_aruser(), .m09_axi_arvalid(),
        .m09_axi_arready(1'b0), .m09_axi_rid('0), .m09_axi_rdata('0),
        .m09_axi_rresp(2'b11), .m09_axi_rlast(1'b1), .m09_axi_ruser('0),
        .m09_axi_rvalid(1'b0), .m09_axi_rready(),

        .m10_axi_awid(), .m10_axi_awaddr(), .m10_axi_awlen(), .m10_axi_awsize(),
        .m10_axi_awburst(), .m10_axi_awlock(), .m10_axi_awcache(), .m10_axi_awprot(),
        .m10_axi_awqos(), .m10_axi_awregion(), .m10_axi_awuser(), .m10_axi_awvalid(),
        .m10_axi_awready(1'b0), .m10_axi_wdata(), .m10_axi_wstrb(), .m10_axi_wlast(),
        .m10_axi_wuser(), .m10_axi_wvalid(), .m10_axi_wready(1'b0),
        .m10_axi_bid('0), .m10_axi_bresp(2'b11), .m10_axi_buser('0),
        .m10_axi_bvalid(1'b0), .m10_axi_bready(),
        .m10_axi_arid(), .m10_axi_araddr(), .m10_axi_arlen(), .m10_axi_arsize(),
        .m10_axi_arburst(), .m10_axi_arlock(), .m10_axi_arcache(), .m10_axi_arprot(),
        .m10_axi_arqos(), .m10_axi_arregion(), .m10_axi_aruser(), .m10_axi_arvalid(),
        .m10_axi_arready(1'b0), .m10_axi_rid('0), .m10_axi_rdata('0),
        .m10_axi_rresp(2'b11), .m10_axi_rlast(1'b1), .m10_axi_ruser('0),
        .m10_axi_rvalid(1'b0), .m10_axi_rready(),

        .m11_axi_awid(), .m11_axi_awaddr(), .m11_axi_awlen(), .m11_axi_awsize(),
        .m11_axi_awburst(), .m11_axi_awlock(), .m11_axi_awcache(), .m11_axi_awprot(),
        .m11_axi_awqos(), .m11_axi_awregion(), .m11_axi_awuser(), .m11_axi_awvalid(),
        .m11_axi_awready(1'b0), .m11_axi_wdata(), .m11_axi_wstrb(), .m11_axi_wlast(),
        .m11_axi_wuser(), .m11_axi_wvalid(), .m11_axi_wready(1'b0),
        .m11_axi_bid('0), .m11_axi_bresp(2'b11), .m11_axi_buser('0),
        .m11_axi_bvalid(1'b0), .m11_axi_bready(),
        .m11_axi_arid(), .m11_axi_araddr(), .m11_axi_arlen(), .m11_axi_arsize(),
        .m11_axi_arburst(), .m11_axi_arlock(), .m11_axi_arcache(), .m11_axi_arprot(),
        .m11_axi_arqos(), .m11_axi_arregion(), .m11_axi_aruser(), .m11_axi_arvalid(),
        .m11_axi_arready(1'b0), .m11_axi_rid('0), .m11_axi_rdata('0),
        .m11_axi_rresp(2'b11), .m11_axi_rlast(1'b1), .m11_axi_ruser('0),
        .m11_axi_rvalid(1'b0), .m11_axi_rready(),

        .m12_axi_awid(), .m12_axi_awaddr(), .m12_axi_awlen(), .m12_axi_awsize(),
        .m12_axi_awburst(), .m12_axi_awlock(), .m12_axi_awcache(), .m12_axi_awprot(),
        .m12_axi_awqos(), .m12_axi_awregion(), .m12_axi_awuser(), .m12_axi_awvalid(),
        .m12_axi_awready(1'b0), .m12_axi_wdata(), .m12_axi_wstrb(), .m12_axi_wlast(),
        .m12_axi_wuser(), .m12_axi_wvalid(), .m12_axi_wready(1'b0),
        .m12_axi_bid('0), .m12_axi_bresp(2'b11), .m12_axi_buser('0),
        .m12_axi_bvalid(1'b0), .m12_axi_bready(),
        .m12_axi_arid(), .m12_axi_araddr(), .m12_axi_arlen(), .m12_axi_arsize(),
        .m12_axi_arburst(), .m12_axi_arlock(), .m12_axi_arcache(), .m12_axi_arprot(),
        .m12_axi_arqos(), .m12_axi_arregion(), .m12_axi_aruser(), .m12_axi_arvalid(),
        .m12_axi_arready(1'b0), .m12_axi_rid('0), .m12_axi_rdata('0),
        .m12_axi_rresp(2'b11), .m12_axi_rlast(1'b1), .m12_axi_ruser('0),
        .m12_axi_rvalid(1'b0), .m12_axi_rready(),

        .m13_axi_awid(), .m13_axi_awaddr(), .m13_axi_awlen(), .m13_axi_awsize(),
        .m13_axi_awburst(), .m13_axi_awlock(), .m13_axi_awcache(), .m13_axi_awprot(),
        .m13_axi_awqos(), .m13_axi_awregion(), .m13_axi_awuser(), .m13_axi_awvalid(),
        .m13_axi_awready(1'b0), .m13_axi_wdata(), .m13_axi_wstrb(), .m13_axi_wlast(),
        .m13_axi_wuser(), .m13_axi_wvalid(), .m13_axi_wready(1'b0),
        .m13_axi_bid('0), .m13_axi_bresp(2'b11), .m13_axi_buser('0),
        .m13_axi_bvalid(1'b0), .m13_axi_bready(),
        .m13_axi_arid(), .m13_axi_araddr(), .m13_axi_arlen(), .m13_axi_arsize(),
        .m13_axi_arburst(), .m13_axi_arlock(), .m13_axi_arcache(), .m13_axi_arprot(),
        .m13_axi_arqos(), .m13_axi_arregion(), .m13_axi_aruser(), .m13_axi_arvalid(),
        .m13_axi_arready(1'b0), .m13_axi_rid('0), .m13_axi_rdata('0),
        .m13_axi_rresp(2'b11), .m13_axi_rlast(1'b1), .m13_axi_ruser('0),
        .m13_axi_rvalid(1'b0), .m13_axi_rready(),

        .m14_axi_awid(), .m14_axi_awaddr(), .m14_axi_awlen(), .m14_axi_awsize(),
        .m14_axi_awburst(), .m14_axi_awlock(), .m14_axi_awcache(), .m14_axi_awprot(),
        .m14_axi_awqos(), .m14_axi_awregion(), .m14_axi_awuser(), .m14_axi_awvalid(),
        .m14_axi_awready(1'b0), .m14_axi_wdata(), .m14_axi_wstrb(), .m14_axi_wlast(),
        .m14_axi_wuser(), .m14_axi_wvalid(), .m14_axi_wready(1'b0),
        .m14_axi_bid('0), .m14_axi_bresp(2'b11), .m14_axi_buser('0),
        .m14_axi_bvalid(1'b0), .m14_axi_bready(),
        .m14_axi_arid(), .m14_axi_araddr(), .m14_axi_arlen(), .m14_axi_arsize(),
        .m14_axi_arburst(), .m14_axi_arlock(), .m14_axi_arcache(), .m14_axi_arprot(),
        .m14_axi_arqos(), .m14_axi_arregion(), .m14_axi_aruser(), .m14_axi_arvalid(),
        .m14_axi_arready(1'b0), .m14_axi_rid('0), .m14_axi_rdata('0),
        .m14_axi_rresp(2'b11), .m14_axi_rlast(1'b1), .m14_axi_ruser('0),
        .m14_axi_rvalid(1'b0), .m14_axi_rready(),

        .m15_axi_awid(), .m15_axi_awaddr(), .m15_axi_awlen(), .m15_axi_awsize(),
        .m15_axi_awburst(), .m15_axi_awlock(), .m15_axi_awcache(), .m15_axi_awprot(),
        .m15_axi_awqos(), .m15_axi_awregion(), .m15_axi_awuser(), .m15_axi_awvalid(),
        .m15_axi_awready(1'b0), .m15_axi_wdata(), .m15_axi_wstrb(), .m15_axi_wlast(),
        .m15_axi_wuser(), .m15_axi_wvalid(), .m15_axi_wready(1'b0),
        .m15_axi_bid('0), .m15_axi_bresp(2'b11), .m15_axi_buser('0),
        .m15_axi_bvalid(1'b0), .m15_axi_bready(),
        .m15_axi_arid(), .m15_axi_araddr(), .m15_axi_arlen(), .m15_axi_arsize(),
        .m15_axi_arburst(), .m15_axi_arlock(), .m15_axi_arcache(), .m15_axi_arprot(),
        .m15_axi_arqos(), .m15_axi_arregion(), .m15_axi_aruser(), .m15_axi_arvalid(),
        .m15_axi_arready(1'b0), .m15_axi_rid('0), .m15_axi_rdata('0),
        .m15_axi_rresp(2'b11), .m15_axi_rlast(1'b1), .m15_axi_ruser('0),
        .m15_axi_rvalid(1'b0), .m15_axi_rready()
    );

    // NOTE: IDs and 64-bit data now round-trip through u_br_s00/s01/s02
    // (no truncation); the old s0x_bid_w/xbar_s0x_rdata assigns are gone.

    // =========================================================================
    // m00 DRAM — true RAM (NOP-filled without +SW_HEX, program image with it).
    // Superset of the old NOP stub: VeeR boot fetches spin harmlessly in
    // bring-up and execute real code in uart.sw.
    // =========================================================================
    axi_true_mem #(
        .MEM_BYTES (131072),          // 128 KB @ 0x0000_0000 (mirrored in window)
        .NOP       (32'h0000_0013)   // RV NOP
    ) u_dram_stub (
        .clk        (clk),
        .rst        (~rst_n),
        .s_awid     (m00_awid),
        .s_awaddr   (m00_awaddr),
        .s_awlen    (m00_awlen),
        .s_awvalid  (m00_awvalid),
        .s_awready  (m00_awready),
        .s_wdata    (m00_wdata),
        .s_wstrb    (m00_wstrb),
        .s_wlast    (m00_wlast),
        .s_wvalid   (m00_wvalid),
        .s_wready   (m00_wready),
        .s_bid      (m00_bid),
        .s_bresp    (m00_bresp),
        .s_bvalid   (m00_bvalid),
        .s_bready   (m00_bready),
        .s_arid     (m00_arid),
        .s_araddr   (m00_araddr),
        .s_arlen    (m00_arlen),
        .s_arvalid  (m00_arvalid),
        .s_arready  (m00_arready),
        .s_rid      (m00_rid),
        .s_rdata    (m00_rdata),
        .s_rresp    (m00_rresp),
        .s_rlast    (m00_rlast),
        .s_rvalid   (m00_rvalid),
        .s_rready   (m00_rready)
    );

    // =========================================================================
    // UART wrapper
    // =========================================================================
    uart_wrap #(
        .AXI_ID_WIDTH (XBAR_ID_W)
    ) u_uart (
        .clk            (clk),
        .rst_n          (rst_n),

        .s_axi_awvalid  (m05_awvalid),
        .s_axi_awready  (m05_awready),
        .s_axi_awid     (m05_awid),
        .s_axi_awaddr   (m05_awaddr),
        .s_axi_wvalid   (m05_wvalid),
        .s_axi_wready   (m05_wready),
        .s_axi_wdata    (m05_wdata),
        .s_axi_wstrb    (m05_wstrb),
        .s_axi_bvalid   (m05_bvalid),
        .s_axi_bready   (m05_bready),
        .s_axi_bid      (m05_bid),
        .s_axi_bresp    (m05_bresp),
        .s_axi_arvalid  (m05_arvalid),
        .s_axi_arready  (m05_arready),
        .s_axi_arid     (m05_arid),
        .s_axi_araddr   (m05_araddr),
        .s_axi_rvalid   (m05_rvalid),
        .s_axi_rready   (m05_rready),
        .s_axi_rid      (m05_rid),
        .s_axi_rdata    (m05_rdata),
        .s_axi_rresp    (m05_rresp),

        .uart_rx        (uart_rx),
        .uart_tx        (uart_tx),
        .uart_irq       (uart_irq)
    );

    // =========================================================================
    // Interrupt routing
    // =========================================================================
    // VeeR PIC external interrupt sources:
    //   extintsrc_req[1] = UART RX interrupt
    //   The ext interrupt input is driven from outside; we OR in uart_irq here
    //   by leaving the external extintsrc_req port open and letting the top-level
    //   tie uart_irq into the appropriate bit through the extintsrc_req port.
    //
    // NOTE: the actual wiring depends on how extintsrc_req is driven externally.
    // In the testbench, connect uart_irq to extintsrc_req[1].

endmodule

`default_nettype wire
