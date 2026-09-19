// =============================================================================
// axi64_to_32_bridge.sv — 64-bit AXI manager to 32-bit AXI subordinate
//
// Bridges one VeeR 64-bit AXI port (LSU/IFU/SB) to a 32-bit xbar port.
// Single outstanding per direction; read and write paths independent.
//
// Conversion: every sub-access is 4 bytes (size 2'b10). A 64-bit request
// of totalBytes = (len+1)<<size becomes nSub = max(1, totalBytes/4)
// 4B sub-beats covering the same byte region in the same ORDER
// (critical-word-first safe; WRAP keeps its region, 4B granularity).
// Sub-word accesses (size<2, single) align down with wstrb shifted
// (writes) or lanes extracted, rest zero (reads).
//
// Responses sticky-worst; IDs round-trip (tag latched, zero-extended).
// Limitation: split 8B halves are not atomic (no AMO/LR-SC in SW here).
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module axi64_to_32_bridge #(
    parameter int S_ID_W = 3,   // VeeR-side tag width (LSU/IFU=3, SB=1)
    parameter int M_ID_W = 8    // xbar-side ID width
) (
    input  logic                clk,
    input  logic                rst_n,

    // ---------------- 64-bit side (VeeR) ----------------
    input  logic [S_ID_W-1:0]   s_awid,
    input  logic [31:0]         s_awaddr,
    input  logic [7:0]          s_awlen,
    input  logic [2:0]          s_awsize,
    input  logic [1:0]          s_awburst,
    input  logic                s_awlock,
    input  logic [3:0]          s_awcache,
    input  logic [2:0]          s_awprot,
    input  logic [3:0]          s_awqos,
    input  logic                s_awvalid,
    output logic                s_awready,
    input  logic [63:0]         s_wdata,
    input  logic [7:0]          s_wstrb,
    input  logic                s_wlast,
    input  logic                s_wvalid,
    output logic                s_wready,
    output logic [S_ID_W-1:0]   s_bid,
    output logic [1:0]          s_bresp,
    output logic                s_bvalid,
    input  logic                s_bready,
    input  logic [S_ID_W-1:0]   s_arid,
    input  logic [31:0]         s_araddr,
    input  logic [7:0]          s_arlen,
    input  logic [2:0]          s_arsize,
    input  logic [1:0]          s_arburst,
    input  logic                s_arlock,
    input  logic [3:0]          s_arcache,
    input  logic [2:0]          s_arprot,
    input  logic [3:0]          s_arqos,
    input  logic                s_arvalid,
    output logic                s_arready,
    output logic [S_ID_W-1:0]   s_rid,
    output logic [63:0]         s_rdata,
    output logic [1:0]          s_rresp,
    output logic                s_rlast,
    output logic                s_rvalid,
    input  logic                s_rready,

    // ---------------- 32-bit side (xbar) ----------------
    output logic [M_ID_W-1:0]   m_awid,
    output logic [31:0]         m_awaddr,
    output logic [7:0]          m_awlen,
    output logic [2:0]          m_awsize,
    output logic [1:0]          m_awburst,
    output logic                m_awlock,
    output logic [3:0]          m_awcache,
    output logic [2:0]          m_awprot,
    output logic [3:0]          m_awqos,
    output logic                m_awvalid,
    input  logic                m_awready,
    output logic [31:0]         m_wdata,
    output logic [3:0]          m_wstrb,
    output logic                m_wlast,
    output logic                m_wvalid,
    input  logic                m_wready,
    input  logic [M_ID_W-1:0]   m_bid,
    input  logic [1:0]          m_bresp,
    input  logic                m_bvalid,
    output logic                m_bready,
    output logic [M_ID_W-1:0]   m_arid,
    output logic [31:0]         m_araddr,
    output logic [7:0]          m_arlen,
    output logic [2:0]          m_arsize,
    output logic [1:0]          m_arburst,
    output logic                m_arlock,
    output logic [3:0]          m_arcache,
    output logic [2:0]          m_arprot,
    output logic [3:0]          m_arqos,
    output logic                m_arvalid,
    input  logic                m_arready,
    input  logic [M_ID_W-1:0]   m_rid,
    input  logic [31:0]         m_rdata,
    input  logic [1:0]          m_rresp,
    input  logic                m_rlast,
    input  logic                m_rvalid,
    output logic                m_rready
);

    function automatic [8:0] nsub64(input logic [7:0] len64, input logic [2:0] size64);
        automatic logic [16:0] total;
        total = (17'(len64) + 17'd1) << size64;
        if (total <= 17'd4)
            return 9'd1;
        else
            return total[8:0] >> 2;
    endfunction

    function automatic [1:0] worse(input logic [1:0] a, input logic [1:0] b);
        if (a == 2'b11 || b == 2'b11) return 2'b11;
        if (a == 2'b10 || b == 2'b10) return 2'b10;
        if (a == 2'b01 || b == 2'b01) return 2'b01;
        return 2'b00;
    endfunction

    // Sub-address for sub-beat i (4B steps, WRAP region preserved)
    function automatic [31:0] subaddr(
        input logic [31:0] base, input logic [1:0] burst,
        input logic [16:0] total, input logic [8:0] i);
        automatic logic [31:0] region;
        if (burst == 2'b00)
            return {base[31:2], 2'b00};
        region = {15'd0, total[16:0]};
        if (burst == 2'b10)
            return (base & ~(region - 32'd1)) | ((base + (32'(i) << 2)) & (region - 32'd1));
        else
            return base + (32'(i) << 2);
    endfunction

    // ==================================================================
    // WRITE path
    // ==================================================================
    typedef enum logic [2:0] { W_IDLE, W_RUN, W_RESP } wstate_t;
    wstate_t wstate;

    logic [S_ID_W-1:0] w_id;
    logic [31:0]       w_base;
    logic [2:0]        w_size;
    logic [1:0]        w_burst;
    logic              w_lock;
    logic [3:0]        w_cache, w_qos;
    logic [2:0]        w_prot;
    logic [8:0]        w_nsub, w_sub;
    logic [1:0]        w_rsp;
    logic              w_aw_done, w_w_done;   // current sub handshake flags

    // W-data FIFO: 16 x {data,strb,last}. Beats consumed strictly in order
    // and popped on sub completion, so the current sub's beat is the head.
    logic [63:0] wf_data [0:15];
    logic [7:0]  wf_strb [0:15];
    logic        wf_last [0:15];
    logic [4:0]  wf_wp, wf_rp;
    wire         wf_full = ((wf_wp - wf_rp) == 5'd16);
    wire         wf_empty = (wf_wp == wf_rp);

    wire [16:0] w_total = {8'd0, w_nsub} << 2;
    wire [31:0] w_eff   = subaddr(w_base, w_burst, w_total, w_sub);
    wire        w_single = (w_nsub == 9'd1);
    wire        w_have  = !wf_empty;
    wire [63:0] w_b64   = wf_data[wf_rp[3:0]];
    wire [7:0]  w_s64   = wf_strb[wf_rp[3:0]];
    // Half select: single subs use the word containing effaddr; pairs
    // alternate low/high per 8B beat (head popped only on completion).
    wire        w_half  = w_single ? w_eff[2] : w_sub[0];
    wire [31:0] w_halfdata = w_half ? w_b64[63:32] : w_b64[31:0];
    wire [3:0]  w_halfstrb = w_half ? w_s64[7:4]   : w_s64[3:0];
    wire [31:0] w_lane_data;
    wire [3:0]  w_lane_strb;
    assign w_lane_data = (w_single && w_size <= 3'd1) ?
        (w_size == 3'd0 ? (32'(w_halfdata[7:0])  << (w_eff[1:0]*8)) :
                          (32'(w_halfdata[15:0]) << (w_eff[1:0]*8))) : w_halfdata;
    assign w_lane_strb = (w_single && w_size <= 3'd1) ?
        (w_size == 3'd0 ? (4'b0001 << w_eff[1:0]) :
                          (4'b0011 << w_eff[1:0])) : w_halfstrb;

    assign s_awready = (wstate == W_IDLE);
    assign s_wready  = !wf_full;

    assign m_awid     = {{(M_ID_W-S_ID_W){1'b0}}, w_id};
    assign m_awaddr   = {w_eff[31:2], 2'b00};
    assign m_awlen    = 8'd0;
    assign m_awsize   = 3'b010;
    assign m_awburst  = 2'b01;
    assign m_awlock   = w_lock;
    assign m_awcache  = w_cache;
    assign m_awprot   = w_prot;
    assign m_awqos    = w_qos;
    assign m_awvalid  = (wstate == W_RUN) && !w_aw_done;
    assign m_wdata    = w_lane_data;
    assign m_wstrb    = w_lane_strb;
    assign m_wlast    = 1'b1;
    assign m_wvalid   = (wstate == W_RUN) && !w_w_done && w_have;
    assign m_bready   = 1'b1;

    assign s_bid    = w_id;
    assign s_bresp  = w_rsp;
    assign s_bvalid = (wstate == W_RESP);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wstate <= W_IDLE;
            w_id <= '0; w_base <= '0; w_size <= '0; w_burst <= 2'b01;
            w_lock <= 0; w_cache <= '0; w_prot <= '0; w_qos <= '0;
            w_nsub <= 9'd0; w_sub <= 9'd0; w_rsp <= 2'b00;
            w_aw_done <= 0; w_w_done <= 0;
            wf_wp <= 5'd0; wf_rp <= 5'd0;
        end else begin
            if (s_wvalid && s_wready) begin
                wf_data[wf_wp[3:0]] <= s_wdata;
                wf_strb[wf_wp[3:0]] <= s_wstrb;
                wf_last[wf_wp[3:0]] <= s_wlast;
                wf_wp <= wf_wp + 5'd1;
            end
            case (wstate)
                W_IDLE: begin
                    if (s_awvalid && s_awready) begin
                        w_id    <= s_awid;
                        w_base  <= s_awaddr;
                        w_size  <= s_awsize;
                        w_burst <= s_awburst;
                        w_lock  <= s_awlock;
                        w_cache <= s_awcache;
                        w_prot  <= s_awprot;
                        w_qos   <= s_awqos;
                        w_nsub  <= nsub64(s_awlen, s_awsize);
                        w_sub   <= 9'd0;
                        w_rsp   <= 2'b00;
                        w_aw_done <= 1'b0;
                        w_w_done  <= 1'b0;
                        wstate <= W_RUN;
                    end
                end
                W_RUN: begin
                    if (m_awvalid && m_awready) w_aw_done <= 1'b1;
                    if (m_wvalid  && m_wready)  w_w_done  <= 1'b1;
                    if (m_bvalid) begin
                        w_rsp <= worse(w_rsp, m_bresp);
                        // Pop the head beat once fully consumed: singles pop
                        // now; pairs pop on their odd (second) half.
                        if (w_single || w_sub[0]) wf_rp <= wf_rp + 5'd1;
                        if (w_sub + 9'd1 >= w_nsub) begin
                            wstate <= W_RESP;
                        end else begin
                            w_sub <= w_sub + 9'd1;
                            w_aw_done <= 1'b0;
                            w_w_done  <= 1'b0;
                        end
                    end
                end
                W_RESP: begin
                    if (s_bready && s_bvalid) wstate <= W_IDLE;
                end
            endcase
        end
    end

    // m_bready is tied high: each single-beat sub gets exactly one B pulse,
    // accepted the cycle it appears; sticky-worst accumulates across subs.

    // ==================================================================
    // READ path
    // ==================================================================
    typedef enum logic [1:0] { R_IDLE, R_RUN, R_SEND } rstate_t;
    rstate_t rstate;

    logic [S_ID_W-1:0] r_id;
    logic [31:0]       r_base;
    logic [7:0]        r_len64;
    logic [2:0]        r_size;
    logic [1:0]        r_burst;
    logic              r_lock;
    logic [3:0]        r_cache, r_qos;
    logic [2:0]        r_prot;
    logic [8:0]        r_nsub, r_sub;    // sub-beats collected
    logic [8:0]        r_sent;           // 8B beats presented upstream
    logic [1:0]        r_rsp;
    logic [31:0]       r_even;           // even sub of current pair
    logic [63:0]       r_hold;
    logic              r_holdv;

    wire [16:0] r_total = {8'd0, r_nsub} << 2;
    wire [31:0] r_eff   = subaddr(r_base, r_burst, r_total, r_sub);
    wire        r_single = (r_nsub == 9'd1);
    wire [8:0]  r_nbeats64 = r_single ? 9'd1 : ({1'd0, r_len64} + 9'd1);

    function automatic [63:0] lane64(input logic [2:0] off, input logic [2:0] sz, input logic [31:0] w);
        case (sz)
            3'd0: return 64'(w[7:0]) << (off*8);
            3'd1: return 64'(w[15:0]) << (off*8);
            default: return off[2] ? {w, 32'd0} : {32'd0, w};
        endcase
    endfunction

    assign s_arready = (rstate == R_IDLE);
    logic r_ar_done;
    assign m_arid     = {{(M_ID_W-S_ID_W){1'b0}}, r_id};
    assign m_araddr   = {r_eff[31:2], 2'b00};
    assign m_arlen    = 8'd0;
    assign m_arsize   = 3'b010;
    assign m_arburst  = 2'b01;
    assign m_arlock   = r_lock;
    assign m_arcache  = r_cache;
    assign m_arprot   = r_prot;
    assign m_arqos    = r_qos;
    assign m_arvalid  = (rstate == R_RUN) && !r_ar_done;
    assign m_rready   = (rstate == R_RUN);

    assign s_rid    = r_id;
    assign s_rdata  = r_hold;
    assign s_rresp  = r_rsp;
    assign s_rlast  = (rstate == R_SEND) && (r_sent + 9'd1 >= r_nbeats64);
    assign s_rvalid = (rstate == R_SEND);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate <= R_IDLE;
            r_id <= '0; r_base <= '0; r_len64 <= '0; r_size <= '0;
            r_burst <= 2'b01; r_lock <= 0; r_cache <= '0; r_prot <= '0; r_qos <= '0;
            r_nsub <= 9'd0; r_sub <= 9'd0; r_sent <= 9'd0; r_rsp <= 2'b00;
            r_even <= 32'd0; r_hold <= 64'd0; r_holdv <= 1'b0;
            r_ar_done <= 1'b0;
        end else begin
            case (rstate)
                R_IDLE: begin
                    if (s_arvalid && s_arready) begin
                        r_id    <= s_arid;
                        r_base  <= s_araddr;
                        r_len64 <= s_arlen;
                        r_size  <= s_arsize;
                        r_burst <= s_arburst;
                        r_lock  <= s_arlock;
                        r_cache <= s_arcache;
                        r_prot  <= s_arprot;
                        r_qos   <= s_arqos;
                        r_nsub  <= nsub64(s_arlen, s_arsize);
                        r_sub   <= 9'd0;
                        r_sent  <= 9'd0;
                        r_rsp   <= 2'b00;
                        r_holdv <= 1'b0;
                        r_ar_done <= 1'b0;
                        rstate <= R_RUN;
                    end
                end
                R_RUN: begin
                    if (m_arvalid && m_arready) r_ar_done <= 1'b1;
                    if (m_rvalid && m_rready) begin
                        r_rsp <= worse(r_rsp, m_rresp);
                        if (r_single) begin
                            r_hold  <= lane64(r_base[2:0], r_size, m_rdata);
                            r_holdv <= 1'b1;
                            r_sub   <= r_sub + 9'd1;
                            rstate  <= R_SEND;
                        end else if (!r_sub[0]) begin
                            r_even <= m_rdata;
                            r_sub  <= r_sub + 9'd1;
                            r_ar_done <= 1'b0;
                        end else begin
                            r_hold  <= {m_rdata, r_even};
                            r_holdv <= 1'b1;
                            r_sub   <= r_sub + 9'd1;
                            rstate  <= R_SEND;
                        end
                    end
                end
                R_SEND: begin
                    if (s_rready && s_rvalid) begin
                        r_holdv <= 1'b0;
                        r_sent  <= r_sent + 9'd1;
                        r_ar_done <= 1'b0;
                        if (r_sent + 9'd1 >= r_nbeats64)
                            rstate <= R_IDLE;
                        else
                            rstate <= R_RUN;
                    end
                end
            endcase
        end
    end

endmodule

`default_nettype wire
