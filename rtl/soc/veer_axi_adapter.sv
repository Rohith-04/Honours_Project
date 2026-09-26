// =============================================================================
// veer_axi_adapter.sv — VeeR (64-bit) to SoC (32-bit) AXI mux + width adapter
//
// Phase 1 SW prerequisite (PHASE1.md §0): VeeR EL2 exposes 64-bit AXI data
// on IFU/LSU/SB; honours_soc exposes a single 32-bit AXI4 slave port.
// Lower-32-bits wiring is explicitly NOT a converter. This module is the
// proper adaptation: AW/AR arbitration across the three VeeR masters,
// 64-bit single-beat transactions split into 1-2 32-bit single-beat
// sub-transactions, correct WSTRB/RDATA lane handling, size/alignment
// checks, and merged BRESP/RRESP.
//
// Scope (matches observed VeeR behavior, see design/lsu/el2_lsu_bus_buffer.sv
// and design/ifu/el2_ifu_mem_ctl.sv):
//   - Input: single-beat only (awlen/arlen == 0). Bursts complete with
//     SLVERR without forwarding (VeeR never sends them).
//   - Input size 0..3. size==3 (8B) must be 8B-aligned -> 2 sub-beats.
//     size<3 -> 1 sub-beat on the half selected by addr[2], size preserved
//     so the 32-bit slave's own narrow/lane logic applies.
//   - Only INCR is forwarded (VeeR always sends INCR); other bursts SLVERR.
//   - One 64-bit transaction outstanding at a time (writes and reads share
//     the single SoC port). Slave readys deassert while busy, which
//     back-pressures VeeR legally via AXI handshakes.
//   - IFU is read-only in practice (its AW/W outputs are tied 0); the IFU
//     write slot exists only to terminate the port benignly.
//   - Master ID is 12-bit: {6'b0, src[1:0], id4[3:0]} with
//     src = 00 LSU / 01 IFU / 10 SB. Return BID/RID from the SoC is ignored;
//     the captured source + original ID is returned (serialization makes
//     this exact).
//
// Sub-beat discipline is OVERLAPPED (AW+W asserted together, held until both
// handshake, then wait B) — required by ips/uart (see bfm docs). Reads are
// AR-then-R. m_bready/m_rready are tied high (single outstanding).
// =============================================================================

`resetall
`timescale 1ns / 1ps
`default_nettype none

module veer_axi_adapter #(
  parameter int unsigned LSU_ID_W = 3,
  parameter int unsigned IFU_ID_W = 3,
  parameter int unsigned SB_ID_W  = 1,
  parameter int unsigned ADDR_W   = 32,
  parameter int unsigned M_ID_W   = 12
)(
  input  wire                  clk,
  input  wire                  aresetn,

  // --- LSU (full read+write master, 64-bit) ---
  input  wire [LSU_ID_W-1:0]   lsu_awid,
  input  wire [ADDR_W-1:0]     lsu_awaddr,
  input  wire [7:0]            lsu_awlen,
  input  wire [2:0]            lsu_awsize,
  input  wire [1:0]            lsu_awburst,
  input  wire                  lsu_awvalid,
  output logic                 lsu_awready,
  input  wire [63:0]           lsu_wdata,
  input  wire [7:0]            lsu_wstrb,
  input  wire                  lsu_wlast,
  input  wire                  lsu_wvalid,
  output logic                 lsu_wready,
  output logic [LSU_ID_W-1:0]  lsu_bid,
  output logic [1:0]           lsu_bresp,
  output logic                 lsu_bvalid,
  input  wire                  lsu_bready,
  input  wire [LSU_ID_W-1:0]   lsu_arid,
  input  wire [ADDR_W-1:0]     lsu_araddr,
  input  wire [7:0]            lsu_arlen,
  input  wire [2:0]            lsu_arsize,
  input  wire [1:0]            lsu_arburst,
  input  wire                  lsu_arvalid,
  output logic                 lsu_arready,
  output logic [LSU_ID_W-1:0]  lsu_rid,
  output logic [63:0]          lsu_rdata,
  output logic [1:0]           lsu_rresp,
  output logic                 lsu_rlast,
  output logic                 lsu_rvalid,
  input  wire                  lsu_rready,
  // sideband (consumed as ignore; present for direct VeeR wiring)
  input  wire [3:0]            lsu_awregion,
  input  wire [3:0]            lsu_awcache,
  input  wire [2:0]            lsu_awprot,
  input  wire [3:0]            lsu_awqos,
  input  wire                  lsu_awlock,
  input  wire [3:0]            lsu_arregion,
  input  wire [3:0]            lsu_arcache,
  input  wire [2:0]            lsu_arprot,
  input  wire [3:0]            lsu_arqos,
  input  wire                  lsu_arlock,

  // --- IFU (read-only in practice, 64-bit) ---
  input  wire [IFU_ID_W-1:0]   ifu_awid,
  input  wire [ADDR_W-1:0]     ifu_awaddr,
  input  wire [7:0]            ifu_awlen,
  input  wire [2:0]            ifu_awsize,
  input  wire [1:0]            ifu_awburst,
  input  wire                  ifu_awvalid,
  output logic                 ifu_awready,
  input  wire [63:0]           ifu_wdata,
  input  wire [7:0]            ifu_wstrb,
  input  wire                  ifu_wlast,
  input  wire                  ifu_wvalid,
  output logic                 ifu_wready,
  output logic [IFU_ID_W-1:0]  ifu_bid,
  output logic [1:0]           ifu_bresp,
  output logic                 ifu_bvalid,
  input  wire                  ifu_bready,
  input  wire [IFU_ID_W-1:0]   ifu_arid,
  input  wire [ADDR_W-1:0]     ifu_araddr,
  input  wire [7:0]            ifu_arlen,
  input  wire [2:0]            ifu_arsize,
  input  wire [1:0]            ifu_arburst,
  input  wire                  ifu_arvalid,
  output logic                 ifu_arready,
  output logic [IFU_ID_W-1:0]  ifu_rid,
  output logic [63:0]          ifu_rdata,
  output logic [1:0]           ifu_rresp,
  output logic                 ifu_rlast,
  output logic                 ifu_rvalid,
  input  wire                  ifu_rready,
  input  wire [3:0]            ifu_awregion,
  input  wire [3:0]            ifu_awcache,
  input  wire [2:0]            ifu_awprot,
  input  wire [3:0]            ifu_awqos,
  input  wire                  ifu_awlock,
  input  wire [3:0]            ifu_arregion,
  input  wire [3:0]            ifu_arcache,
  input  wire [2:0]            ifu_arprot,
  input  wire [3:0]            ifu_arqos,
  input  wire                  ifu_arlock,

  // --- SB (debug master, 64-bit) ---
  input  wire [SB_ID_W-1:0]    sb_awid,
  input  wire [ADDR_W-1:0]     sb_awaddr,
  input  wire [7:0]            sb_awlen,
  input  wire [2:0]            sb_awsize,
  input  wire [1:0]            sb_awburst,
  input  wire                  sb_awvalid,
  output logic                 sb_awready,
  input  wire [63:0]           sb_wdata,
  input  wire [7:0]            sb_wstrb,
  input  wire                  sb_wlast,
  input  wire                  sb_wvalid,
  output logic                 sb_wready,
  output logic [SB_ID_W-1:0]   sb_bid,
  output logic [1:0]           sb_bresp,
  output logic                 sb_bvalid,
  input  wire                  sb_bready,
  input  wire [SB_ID_W-1:0]    sb_arid,
  input  wire [ADDR_W-1:0]     sb_araddr,
  input  wire [7:0]            sb_arlen,
  input  wire [2:0]            sb_arsize,
  input  wire [1:0]            sb_arburst,
  input  wire                  sb_arvalid,
  output logic                 sb_arready,
  output logic [SB_ID_W-1:0]   sb_rid,
  output logic [63:0]          sb_rdata,
  output logic [1:0]           sb_rresp,
  output logic                 sb_rlast,
  output logic                 sb_rvalid,
  input  wire                  sb_rready,
  input  wire [3:0]            sb_awregion,
  input  wire [3:0]            sb_awcache,
  input  wire [2:0]            sb_awprot,
  input  wire [3:0]            sb_awqos,
  input  wire                  sb_awlock,
  input  wire [3:0]            sb_arregion,
  input  wire [3:0]            sb_arcache,
  input  wire [2:0]            sb_arprot,
  input  wire [3:0]            sb_arqos,
  input  wire                  sb_arlock,

  // --- SoC side (single 32-bit master port -> honours_soc s_axi_*) ---
  output logic [M_ID_W-1:0]    m_awid,
  output logic [ADDR_W-1:0]    m_awaddr,
  output logic [7:0]           m_awlen,
  output logic [2:0]           m_awsize,
  output logic [1:0]           m_awburst,
  output logic                 m_awvalid,
  input  wire                  m_awready,
  output logic [31:0]          m_wdata,
  output logic [3:0]           m_wstrb,
  output logic                 m_wlast,
  output logic                 m_wvalid,
  input  wire                  m_wready,
  input  wire [M_ID_W-1:0]     m_bid,
  input  wire [1:0]            m_bresp,
  input  wire                  m_bvalid,
  output logic                 m_bready,
  output logic [M_ID_W-1:0]    m_arid,
  output logic [ADDR_W-1:0]    m_araddr,
  output logic [7:0]           m_arlen,
  output logic [2:0]           m_arsize,
  output logic [1:0]           m_arburst,
  output logic                 m_arvalid,
  input  wire                  m_arready,
  input  wire [M_ID_W-1:0]     m_rid,
  input  wire [31:0]           m_rdata,
  input  wire [1:0]            m_rresp,
  input  wire                  m_rlast,
  input  wire                  m_rvalid,
  output logic                 m_rready
);

  wire _unused = &{1'b0, lsu_awregion, lsu_awcache, lsu_awprot, lsu_awqos,
                    lsu_awlock, lsu_arregion, lsu_arcache, lsu_arprot,
                    lsu_arqos, lsu_arlock, ifu_awregion, ifu_awcache,
                    ifu_awprot, ifu_awqos, ifu_awlock, ifu_arregion,
                    ifu_arcache, ifu_arprot, ifu_arqos, ifu_arlock,
                    sb_awregion, sb_awcache, sb_awprot, sb_awqos,
                    sb_awlock, sb_arregion, sb_arcache, sb_arprot,
                    sb_arqos, sb_arlock, lsu_wlast, ifu_wlast, sb_wlast,
                    m_bid, m_rid, m_rlast};

  // Source tags for debug + unique master IDs.
  localparam logic [1:0] SRC_LSU = 2'b00;
  localparam logic [1:0] SRC_IFU = 2'b01;
  localparam logic [1:0] SRC_SB  = 2'b10;

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_WCAP,      // wait W beat after AW handshake
    ST_WSUB0,     // first (or only) 32-bit write sub-beat
    ST_WSUB0_B,   // wait B for first sub-beat (2-beat case)
    ST_WSUB1,     // second 32-bit write sub-beat
    ST_WSUB1_B,   // wait B for second sub-beat
    ST_WRESP,     // return merged B
    ST_WERR,      // input protocol error -> SLVERR B
    ST_RSUB0,     // first (or only) 32-bit read sub-beat (AR + wait R)
    ST_RSUB1,     // second 32-bit read sub-beat
    ST_RRESP,     // return assembled R
    ST_RERR       // input protocol error -> SLVERR R
  } state_t;

  state_t state;

  // Latched 64-bit request.
  logic [1:0]      req_src;     // SRC_* of the active transaction
  logic            req_is_write;
  logic [ADDR_W-1:0] req_addr;
  logic [2:0]      req_size;
  logic [63:0]     req_wdata;
  logic [7:0]      req_wstrb;
  logic [3:0]      req_id4;     // zero-extended original ID
  logic [2:0]      req_orig3;   // original ID bits (LSU/IFU 3b, SB in [0])
  logic            req_two_beats;
  logic            req_err;     // latched input-side protocol error

  // Sub-beat handshake flags + captured responses.
  logic aw_hs, w_hs, ar_hs;
  logic [1:0] bresp0, bresp1;
  logic [31:0] rdata0, rdata1;
  logic [1:0] rresp0, rresp1;

  // Decoded sub-beat fields (combinational from latched request).
  wire second = (state == ST_WSUB1 || state == ST_WSUB1_B ||
                 state == ST_RSUB1);
  wire [ADDR_W-1:0] sub_addr_w;
  wire [31:0] sub_wdata;
  wire [3:0]  sub_wstrb;
  wire [2:0]  sub_size_w;
  wire [ADDR_W-1:0] sub_addr_r;
  wire [2:0]  sub_size_r;

  // Write sub-beats: size 3 -> two full-word beats; else the half
  // selected by addr[2] with the original narrow size preserved.
  assign sub_size_w = req_two_beats ? 3'b010 : req_size;
  assign sub_addr_w = req_two_beats
                      ? (second ? (req_addr + 32'd4) : req_addr)
                      : req_addr;
  assign sub_wdata  = req_two_beats
                      ? (second ? req_wdata[63:32] : req_wdata[31:0])
                      : (req_addr[2] ? req_wdata[63:32] : req_wdata[31:0]);
  assign sub_wstrb  = req_two_beats
                      ? (second ? req_wstrb[7:4] : req_wstrb[3:0])
                      : (req_addr[2] ? req_wstrb[7:4] : req_wstrb[3:0]);

  assign sub_size_r = req_two_beats ? 3'b010 : req_size;
  assign sub_addr_r = req_two_beats
                      ? (second ? (req_addr + 32'd4) : req_addr)
                      : req_addr;

  function automatic logic [1:0] merge_resp(input logic [1:0] a,
                                            input logic [1:0] b);
    // Worst-wins: DECERR(11) > SLVERR(10) > EXOKAY(01) > OKAY(00).
    if (a == 2'b11 || b == 2'b11) return 2'b11;
    if (a == 2'b10 || b == 2'b10) return 2'b10;
    if (a == 2'b01 || b == 2'b01) return 2'b01;
    return 2'b00;
  endfunction

  // Assembled 64-bit read data.
  wire [63:0] rdata_asm;
  assign rdata_asm = req_two_beats ? {rdata1, rdata0}
                   : (req_addr[2] ? {rdata0, 32'b0} : {32'b0, rdata0});
  wire [1:0] rresp_asm;
  assign rresp_asm = req_two_beats ? merge_resp(rresp0, rresp1) : rresp0;

  wire [1:0] bresp_asm;
  assign bresp_asm = req_two_beats ? merge_resp(bresp0, bresp1) : bresp0;

  // Priority: IFU fetch > LSU read > SB read > LSU write > SB write.
  // (IFU write never arbitrates: ifu_awvalid is tied 0 by the core.)
  wire grant_ifu_rd = ifu_arvalid;
  wire grant_lsu_rd = !grant_ifu_rd && lsu_arvalid;
  wire grant_sb_rd  = !grant_ifu_rd && !grant_lsu_rd && sb_arvalid;
  wire grant_lsu_wr = !grant_ifu_rd && !grant_lsu_rd && !grant_sb_rd && lsu_awvalid;
  wire grant_sb_wr  = !grant_ifu_rd && !grant_lsu_rd && !grant_sb_rd &&
                      !grant_lsu_wr && sb_awvalid;

  always_ff @(posedge clk or negedge aresetn) begin
    if (!aresetn) begin
      state        <= ST_IDLE;
      req_src      <= SRC_LSU;
      req_is_write <= 1'b0;
      req_addr     <= '0;
      req_size     <= '0;
      req_wdata    <= '0;
      req_wstrb    <= '0;
      req_id4      <= '0;
      req_orig3    <= '0;
      req_two_beats <= 1'b0;
      req_err      <= 1'b0;
      aw_hs <= 1'b0; w_hs <= 1'b0; ar_hs <= 1'b0;
      bresp0 <= 2'b00; bresp1 <= 2'b00;
      rdata0 <= '0; rdata1 <= '0;
      rresp0 <= 2'b00; rresp1 <= 2'b00;
    end else begin
      case (state)
        ST_IDLE: begin
          aw_hs <= 1'b0; w_hs <= 1'b0; ar_hs <= 1'b0;
          // Latch the granted request. AW/AR handshake completes here
          // (ready asserted combinationally below for exactly the grant).
          if (grant_ifu_rd) begin
            req_src <= SRC_IFU; req_is_write <= 1'b0;
            req_addr <= ifu_araddr; req_size <= ifu_arsize;
            req_id4 <= {1'b0, ifu_arid}; req_orig3 <= ifu_arid;
            if (ifu_arlen != 8'd0 || ifu_arburst != 2'b01 ||
                ifu_arsize > 3'd3 ||
                (ifu_arsize == 3'd3 && ifu_araddr[2:0] != 3'b000)) begin
              req_err <= 1'b1; state <= ST_RERR;
            end else begin
              req_err <= 1'b0;
              req_two_beats <= (ifu_arsize == 3'd3);
              state <= ST_RSUB0;
            end
          end else if (grant_lsu_rd) begin
            req_src <= SRC_LSU; req_is_write <= 1'b0;
            req_addr <= lsu_araddr; req_size <= lsu_arsize;
            req_id4 <= {1'b0, lsu_arid}; req_orig3 <= lsu_arid;
            if (lsu_arlen != 8'd0 || lsu_arburst != 2'b01 ||
                lsu_arsize > 3'd3 ||
                (lsu_arsize == 3'd3 && lsu_araddr[2:0] != 3'b000)) begin
              req_err <= 1'b1; state <= ST_RERR;
            end else begin
              req_err <= 1'b0;
              req_two_beats <= (lsu_arsize == 3'd3);
              state <= ST_RSUB0;
            end
          end else if (grant_sb_rd) begin
            req_src <= SRC_SB; req_is_write <= 1'b0;
            req_addr <= sb_araddr; req_size <= sb_arsize;
            req_id4 <= {3'b0, sb_arid}; req_orig3 <= {2'b0, sb_arid};
            if (sb_arlen != 8'd0 || sb_arburst != 2'b01 ||
                sb_arsize > 3'd3 ||
                (sb_arsize == 3'd3 && sb_araddr[2:0] != 3'b000)) begin
              req_err <= 1'b1; state <= ST_RERR;
            end else begin
              req_err <= 1'b0;
              req_two_beats <= (sb_arsize == 3'd3);
              state <= ST_RSUB0;
            end
          end else if (grant_lsu_wr) begin
            req_src <= SRC_LSU; req_is_write <= 1'b1;
            req_addr <= lsu_awaddr; req_size <= lsu_awsize;
            req_id4 <= {1'b0, lsu_awid}; req_orig3 <= lsu_awid;
            if (lsu_awlen != 8'd0 || lsu_awburst != 2'b01 ||
                lsu_awsize > 3'd3 ||
                (lsu_awsize == 3'd3 && lsu_awaddr[2:0] != 3'b000)) begin
              req_err <= 1'b1; state <= ST_WERR;
            end else begin
              req_err <= 1'b0;
              req_two_beats <= (lsu_awsize == 3'd3);
              state <= ST_WCAP;
            end
          end else if (grant_sb_wr) begin
            req_src <= SRC_SB; req_is_write <= 1'b1;
            req_addr <= sb_awaddr; req_size <= sb_awsize;
            req_id4 <= {3'b0, sb_awid}; req_orig3 <= {2'b0, sb_awid};
            if (sb_awlen != 8'd0 || sb_awburst != 2'b01 ||
                sb_awsize > 3'd3 ||
                (sb_awsize == 3'd3 && sb_awaddr[2:0] != 3'b000)) begin
              req_err <= 1'b1; state <= ST_WERR;
            end else begin
              req_err <= 1'b0;
              req_two_beats <= (sb_awsize == 3'd3);
              state <= ST_WCAP;
            end
          end
        end

        ST_WCAP: begin
          // Wait for the W beat of the latched master, then issue sub-beat 0.
          if (req_src == SRC_LSU && lsu_wvalid) begin
            req_wdata <= lsu_wdata; req_wstrb <= lsu_wstrb;
            aw_hs <= 1'b0; w_hs <= 1'b0;
            state <= ST_WSUB0;
          end else if (req_src == SRC_SB && sb_wvalid) begin
            req_wdata <= sb_wdata; req_wstrb <= sb_wstrb;
            aw_hs <= 1'b0; w_hs <= 1'b0;
            state <= ST_WSUB0;
          end
        end

        ST_WSUB0: begin
          if (m_awvalid && m_awready) aw_hs <= 1'b1;
          if (m_wvalid && m_wready) w_hs <= 1'b1;
          if ((aw_hs || (m_awvalid && m_awready)) &&
              (w_hs || (m_wvalid && m_wready))) begin
            aw_hs <= 1'b0; w_hs <= 1'b0;
            state <= ST_WSUB0_B;
          end
        end

        ST_WSUB0_B: begin
          if (m_bvalid) begin
            bresp0 <= m_bresp;
            state <= req_two_beats ? ST_WSUB1 : ST_WRESP;
          end
        end

        ST_WSUB1: begin
          if (m_awvalid && m_awready) aw_hs <= 1'b1;
          if (m_wvalid && m_wready) w_hs <= 1'b1;
          if ((aw_hs || (m_awvalid && m_awready)) &&
              (w_hs || (m_wvalid && m_wready))) begin
            aw_hs <= 1'b0; w_hs <= 1'b0;
            state <= ST_WSUB1_B;
          end
        end

        ST_WSUB1_B: begin
          if (m_bvalid) begin
            bresp1 <= m_bresp;
            state <= ST_WRESP;
          end
        end

        ST_WRESP: begin
          // Hold B until the originating master accepts (they tie bready=1,
          // so this is normally a single cycle).
          if ((req_src == SRC_LSU && lsu_bready) ||
              (req_src == SRC_SB && sb_bready) ||
              (req_src == SRC_IFU && ifu_bready)) begin
            state <= ST_IDLE;
          end
        end

        ST_WERR: begin
          // Drain the W beat so the master doesn't hang, then SLVERR.
          if (req_src == SRC_LSU && lsu_wvalid) state <= ST_WRESP;
          else if (req_src == SRC_SB && sb_wvalid) state <= ST_WRESP;
          bresp0 <= 2'b10; bresp1 <= 2'b10;
        end

        ST_RSUB0: begin
          if (m_arvalid && m_arready) ar_hs <= 1'b1;
          if (ar_hs || (m_arvalid && m_arready)) begin
            if (m_rvalid) begin
              rdata0 <= m_rdata; rresp0 <= m_rresp;
              ar_hs <= 1'b0;
              state <= req_two_beats ? ST_RSUB1 : ST_RRESP;
            end
          end
        end

        ST_RSUB1: begin
          if (m_arvalid && m_arready) ar_hs <= 1'b1;
          if (ar_hs || (m_arvalid && m_arready)) begin
            if (m_rvalid) begin
              rdata1 <= m_rdata; rresp1 <= m_rresp;
              ar_hs <= 1'b0;
              state <= ST_RRESP;
            end
          end
        end

        ST_RRESP: begin
          if ((req_src == SRC_LSU && lsu_rready) ||
              (req_src == SRC_IFU && ifu_rready) ||
              (req_src == SRC_SB && sb_rready)) begin
            state <= ST_IDLE;
          end
        end

        ST_RERR: begin
          rdata0 <= 32'h0; rdata1 <= 32'h0;
          rresp0 <= 2'b10; rresp1 <= 2'b10;
          state <= ST_RRESP;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

  // --- Slave-side ready/valid ---
  always_comb begin
    lsu_awready = 1'b0; lsu_wready = 1'b0;
    lsu_bvalid = 1'b0; lsu_arready = 1'b0; lsu_rvalid = 1'b0;
    ifu_awready = 1'b0; ifu_wready = 1'b0;
    ifu_bvalid = 1'b0; ifu_arready = 1'b0; ifu_rvalid = 1'b0;
    sb_awready = 1'b0; sb_wready = 1'b0;
    sb_bvalid = 1'b0; sb_arready = 1'b0; sb_rvalid = 1'b0;
    if (state == ST_IDLE) begin
      if (grant_ifu_rd) ifu_arready = 1'b1;
      else if (grant_lsu_rd) lsu_arready = 1'b1;
      else if (grant_sb_rd) sb_arready = 1'b1;
      else if (grant_lsu_wr) lsu_awready = 1'b1;
      else if (grant_sb_wr) sb_awready = 1'b1;
    end else if (state == ST_WCAP) begin
      if (req_src == SRC_LSU) lsu_wready = 1'b1;
      else if (req_src == SRC_SB) sb_wready = 1'b1;
    end else if (state == ST_WERR) begin
      if (req_src == SRC_LSU) lsu_wready = 1'b1;
      else if (req_src == SRC_SB) sb_wready = 1'b1;
      // B asserted below in WRESP-style handling via WERR->WRESP.
    end else if (state == ST_WRESP) begin
      if (req_src == SRC_LSU) lsu_bvalid = 1'b1;
      else if (req_src == SRC_SB) sb_bvalid = 1'b1;
      else if (req_src == SRC_IFU) ifu_bvalid = 1'b1;
    end else if (state == ST_RRESP) begin
      if (req_src == SRC_LSU) lsu_rvalid = 1'b1;
      else if (req_src == SRC_IFU) ifu_rvalid = 1'b1;
      else if (req_src == SRC_SB) sb_rvalid = 1'b1;
    end
  end

  // Slave response payloads.
  always_comb begin
    lsu_bid = req_orig3[LSU_ID_W-1:0]; lsu_bresp = bresp_asm;
    ifu_bid = req_orig3[IFU_ID_W-1:0]; ifu_bresp = bresp_asm;
    sb_bid = req_orig3[SB_ID_W-1:0]; sb_bresp = bresp_asm;
    lsu_rid = req_orig3[LSU_ID_W-1:0];
    ifu_rid = req_orig3[IFU_ID_W-1:0];
    sb_rid = req_orig3[SB_ID_W-1:0];
    lsu_rdata = rdata_asm; lsu_rresp = rresp_asm; lsu_rlast = 1'b1;
    ifu_rdata = rdata_asm; ifu_rresp = rresp_asm; ifu_rlast = 1'b1;
    sb_rdata = rdata_asm; sb_rresp = rresp_asm; sb_rlast = 1'b1;
  end

  // --- Master-side (32-bit) drive ---
  // m_bready/m_rready tied high: single outstanding, never miss a beat.
  assign m_bready = 1'b1;
  assign m_rready = 1'b1;

  always_comb begin
    m_awid = {6'b0, req_src, req_id4};
    m_awaddr = sub_addr_w;
    m_awlen = 8'd0;
    m_awsize = sub_size_w;
    m_awburst = 2'b01;
    m_awvalid = 1'b0;
    m_wdata = sub_wdata;
    m_wstrb = sub_wstrb;
    m_wlast = 1'b1;
    m_wvalid = 1'b0;
    m_arid = {6'b0, req_src, req_id4};
    m_araddr = sub_addr_r;
    m_arlen = 8'd0;
    m_arsize = sub_size_r;
    m_arburst = 2'b01;
    m_arvalid = 1'b0;
    if (state == ST_WSUB0 || state == ST_WSUB1) begin
      // Overlapped: hold each valid until its own handshake completes.
      m_awvalid = !aw_hs;
      m_wvalid = !w_hs;
    end else if (state == ST_RSUB0 || state == ST_RSUB1) begin
      m_arvalid = !ar_hs;
    end
  end

  // --- Protocol assertions (cheap handshake rules) ---
  // Check stability only across edges where VALID was already asserted
  // (a fresh VALID after an idle gap legitimately presents a new address).
  // synthesis translate_off
  logic m_awvalid_q, m_arvalid_q;
  always @(posedge clk or negedge aresetn) begin
    if (!aresetn) begin
      m_awvalid_q <= 1'b0;
      m_arvalid_q <= 1'b0;
    end else begin
      if (m_awvalid_q && m_awvalid && !m_awready) begin
        assert ($stable(m_awaddr) && $stable(m_awsize) && $stable(m_awlen))
        else $error("[adapter] AWADDR/AWSIZE/AWLEN changed while AWVALID held and !AWREADY");
      end
      if (m_arvalid_q && m_arvalid && !m_arready) begin
        assert ($stable(m_araddr) && $stable(m_arsize) && $stable(m_arlen))
        else $error("[adapter] ARADDR/ARSIZE/ARLEN changed while ARVALID held and !ARREADY");
      end
      m_awvalid_q <= m_awvalid;
      m_arvalid_q <= m_arvalid;
    end
  end
  // synthesis translate_on

  // --- Debug tracing (sim only, +ADP_DEBUG plusarg) ---
  // synthesis translate_off
  logic adp_debug;
  initial adp_debug = $test$plusargs("ADP_DEBUG");

  function automatic string src_name(input logic [1:0] s);
    case (s)
      SRC_LSU: return "LSU";
      SRC_IFU: return "IFU";
      SRC_SB:  return "SB";
      default: return "???";
    endcase
  endfunction

  always @(posedge clk) begin
    if (aresetn && adp_debug) begin
      case (state)
        ST_IDLE: begin
          if (grant_ifu_rd) $display("[ADP %0t] grant IFU_RD addr=0x%0h size=%0d", $time, ifu_araddr, ifu_arsize);
          else if (grant_lsu_rd) $display("[ADP %0t] grant LSU_RD addr=0x%0h size=%0d", $time, lsu_araddr, lsu_arsize);
          else if (grant_sb_rd) $display("[ADP %0t] grant SB_RD addr=0x%0h size=%0d", $time, sb_araddr, sb_arsize);
          else if (grant_lsu_wr) $display("[ADP %0t] grant LSU_WR addr=0x%0h size=%0d", $time, lsu_awaddr, lsu_awsize);
          else if (grant_sb_wr) $display("[ADP %0t] grant SB_WR addr=0x%0h size=%0d", $time, sb_awaddr, sb_awsize);
        end
        ST_WSUB0: if (m_awvalid && m_awready && m_wvalid && m_wready)
          $display("[ADP %0t] %s WR sub0 AW+W hs addr=0x%0h", $time, src_name(req_src), sub_addr_w);
        ST_WSUB0_B: if (m_bvalid)
          $display("[ADP %0t] %s WR sub0 B resp=%b", $time, src_name(req_src), m_bresp);
        ST_WSUB1: if (m_awvalid && m_awready && m_wvalid && m_wready)
          $display("[ADP %0t] %s WR sub1 AW+W hs addr=0x%0h", $time, src_name(req_src), sub_addr_w);
        ST_WSUB1_B: if (m_bvalid)
          $display("[ADP %0t] %s WR sub1 B resp=%b", $time, src_name(req_src), m_bresp);
        ST_WRESP: $display("[ADP %0t] %s WR done resp=%b", $time, src_name(req_src), bresp_asm);
        ST_WERR: $display("[ADP %0t] %s WR input-error -> SLVERR", $time, src_name(req_src));
        ST_RSUB0: begin
          if (m_arvalid && m_arready)
            $display("[ADP %0t] %s RD sub0 AR hs addr=0x%0h", $time, src_name(req_src), sub_addr_r);
          if (m_rvalid && (ar_hs || (m_arvalid && m_arready)))
            $display("[ADP %0t] %s RD sub0 R data=0x%0h resp=%b", $time, src_name(req_src), m_rdata, m_rresp);
        end
        ST_RSUB1: begin
          if (m_arvalid && m_arready)
            $display("[ADP %0t] %s RD sub1 AR hs addr=0x%0h", $time, src_name(req_src), sub_addr_r);
          if (m_rvalid && (ar_hs || (m_arvalid && m_arready)))
            $display("[ADP %0t] %s RD sub1 R data=0x%0h resp=%b", $time, src_name(req_src), m_rdata, m_rresp);
        end
        ST_RRESP: $display("[ADP %0t] %s RD done data=0x%0h resp=%b", $time, src_name(req_src), rdata_asm, rresp_asm);
        ST_RERR: $display("[ADP %0t] %s RD input-error -> SLVERR", $time, src_name(req_src));
        default: ;
      endcase
    end
  end
  // synthesis translate_on

endmodule

`resetall
