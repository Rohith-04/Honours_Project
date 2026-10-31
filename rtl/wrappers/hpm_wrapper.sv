// =============================================================================
// hpm_wrapper.sv — Hardware Performance Monitor (HPM)
//
// Passive monitor: taps AXI handshakes on interconnect master-facing ports
// and counts events.  Never drives the bus.  64-bit counters with
// snapshot/clear/enable control.  ENABLE_HPM = 0 removes it entirely.
//
// See "NDA, HPM and WDT Design Document" §5 for full specification.
// =============================================================================

`resetall
`timescale 1ns / 1ps
`default_nettype none

module hpm_wrapper #(
  parameter int unsigned ID_WIDTH   = 12,
  parameter int unsigned ADDR_WIDTH = 32
)(
  input  wire                  clk,
  input  wire                  aresetn,

  input  wire [ID_WIDTH-1:0]   s_axi_awid,
  input  wire [ADDR_WIDTH-1:0] s_axi_awaddr,
  input  wire [7:0]            s_axi_awlen,
  input  wire [2:0]            s_axi_awsize,
  input  wire [1:0]            s_axi_awburst,
  input  wire                  s_axi_awvalid,
  output logic                 s_axi_awready,
  input  wire [31:0]           s_axi_wdata,
  input  wire [3:0]            s_axi_wstrb,
  input  wire                  s_axi_wvalid,
  output logic                 s_axi_wready,
  output logic [ID_WIDTH-1:0]  s_axi_bid,
  output logic [1:0]           s_axi_bresp,
  output logic                 s_axi_bvalid,
  input  wire                  s_axi_bready,
  input  wire [ID_WIDTH-1:0]   s_axi_arid,
  input  wire [ADDR_WIDTH-1:0] s_axi_araddr,
  input  wire [7:0]            s_axi_arlen,
  input  wire [2:0]            s_axi_arsize,
  input  wire [1:0]            s_axi_arburst,
  input  wire                  s_axi_arvalid,
  output logic                 s_axi_arready,
  output logic [ID_WIDTH-1:0]  s_axi_rid,
  output logic [31:0]          s_axi_rdata,
  output logic [1:0]           s_axi_rresp,
  output wire                  s_axi_rlast,
  output logic                 s_axi_rvalid,
  input  wire                  s_axi_rready,

  // --- Tap point inputs (handshake wires only, never address/data) ----------
  // M0 (CPU) taps
  input  wire                  m0_ar_valid,
  input  wire                  m0_ar_ready,
  input  wire                  m0_aw_valid,
  input  wire                  m0_aw_ready,
  input  wire                  m0_r_valid,
  input  wire                  m0_r_ready,
  input  wire                  m0_w_valid,
  input  wire                  m0_w_ready,
  // M1 (NDA) taps
  input  wire                  m1_ar_valid,
  input  wire                  m1_ar_ready,
  input  wire                  m1_r_valid,
  input  wire                  m1_r_ready,
  // NDA busy (level, not AXI)
  input  wire                  nda_busy,
  // WDT trip pulse
  input  wire                  wdt_trip
);

  wire _unused = &{1'b0, s_axi_awsize, s_axi_awburst, s_axi_arsize,
                   s_axi_arburst, s_axi_wstrb};

  // ===========================================================================
  // Counters (64-bit, index order matches soc_pkg HPM_*_LO offsets)
  //
  // 0: CYCLES      — clock cycles while enabled
  // 1: CPU_AR      — M0 arvalid & arready
  // 2: CPU_AW      — M0 awvalid & awready
  // 3: CPU_R_BEATS — M0 rvalid & rready
  // 4: CPU_W_BEATS — M0 wvalid & wready
  // 5: NDA_AR      — M1 arvalid & arready
  // 6: NDA_R_BEATS — M1 rvalid & rready
  // 7: NDA_BUSY    — cycles while NDA busy
  // 8: FALLBACKS   — WDT trip pulses
  // ===========================================================================
  localparam int unsigned NUM_CNT = soc_pkg::HPM_NUM_COUNTERS;

  logic [63:0] cnt       [0:NUM_CNT-1]; // live counters
  logic [63:0] cnt_snap  [0:NUM_CNT-1]; // snapshot shadow registers

  logic        enable_reg;

  // ===========================================================================
  // CSR write FSM (drives only AXI handshake + combinational request wires)
  // ===========================================================================
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wstate_t;
  wstate_t wstate;

  logic [ID_WIDTH-1:0]   w_id;
  logic [ADDR_WIDTH-1:0] w_addr;
  logic                  w_is_burst;
  logic [7:0]            w_left;

  assign s_axi_awready = (wstate == W_IDLE);
  assign s_axi_wready  = (wstate == W_DATA);

  wire w_fire = (wstate == W_DATA) && s_axi_wvalid;
  wire w_hit_ctrl = (w_addr[11:0] == 12'h000);
  // Only CTRL is writable; all counter regs are RO
  wire w_ok = !w_is_burst && w_hit_ctrl;

  // Combinational request signals — CSR FSM is sole driver; counter block reads
  wire csr_wr_fire   = w_fire && w_ok && s_axi_wstrb[0];
  wire csr_enable_wr = csr_wr_fire;
  wire csr_enable_val = s_axi_wdata[0];
  wire csr_clear_wr  = csr_wr_fire && s_axi_wdata[1];
  wire csr_snap_wr   = csr_wr_fire && s_axi_wdata[2];

  always_ff @(posedge clk or negedge aresetn) begin
    if (!aresetn) begin
      wstate       <= W_IDLE;
      w_id         <= '0;
      w_addr       <= '0;
      w_is_burst   <= 1'b0;
      w_left       <= 0;
      s_axi_bvalid <= 1'b0;
      s_axi_bresp  <= 2'b00;
      s_axi_bid    <= '0;
    end else begin
      case (wstate)
        W_IDLE: begin
          if (s_axi_awvalid) begin
            w_id       <= s_axi_awid;
            w_addr     <= s_axi_awaddr;
            w_is_burst <= (s_axi_awlen != 0 || s_axi_awsize != 2 || s_axi_awburst != 1);
            w_left <= s_axi_awlen;
            wstate     <= W_DATA;
          end
        end
        W_DATA: begin
          if (s_axi_wvalid) begin
            if (w_left != 0) w_left <= w_left - 1'b1;
            else begin
              s_axi_bid    <= w_id;
              s_axi_bresp  <= w_ok ? 2'b00 : 2'b10;
              s_axi_bvalid <= 1'b1;
              wstate       <= W_RESP;
            end
          end
        end
        W_RESP: begin
          if (s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
            wstate       <= W_IDLE;
          end
        end
        default: wstate <= W_IDLE;
      endcase
    end
  end

  // ===========================================================================
  // Counter logic (sole driver of cnt, cnt_snap, enable_reg)
  // ===========================================================================
  // Tap event wires
  wire ev_cycles    = enable_reg;
  wire ev_cpu_ar    = m0_ar_valid & m0_ar_ready;
  wire ev_cpu_aw    = m0_aw_valid & m0_aw_ready;
  wire ev_cpu_r     = m0_r_valid  & m0_r_ready;
  wire ev_cpu_w     = m0_w_valid  & m0_w_ready;
  wire ev_nda_ar    = m1_ar_valid & m1_ar_ready;
  wire ev_nda_r     = m1_r_valid  & m1_r_ready;
  wire ev_nda_busy  = nda_busy & enable_reg;
  wire ev_fallback  = wdt_trip;

  wire [NUM_CNT-1:0] ev = {ev_fallback, ev_nda_busy, ev_nda_r, ev_nda_ar,
                           ev_cpu_w, ev_cpu_r, ev_cpu_aw, ev_cpu_ar, ev_cycles};

  always_ff @(posedge clk or negedge aresetn) begin
    if (!aresetn) begin
      for (int i = 0; i < NUM_CNT; i++) begin
        cnt[i]      <= 64'h0;
        cnt_snap[i] <= 64'h0;
      end
      enable_reg  <= 1'b0;
    end else begin
      // --- Apply CSR writes ---
      if (csr_enable_wr) enable_reg <= csr_enable_val;

      // --- Clear all counters ---
      if (csr_clear_wr) begin
        for (int i = 0; i < NUM_CNT; i++)
          cnt[i] <= 64'h0;
      end else begin
        // --- Increment counters on events ---
        for (int i = 0; i < NUM_CNT; i++) begin
          if (ev[i])
            cnt[i] <= cnt[i] + 64'd1;
        end
      end

      // --- Snapshot all counters into shadow registers ---
      if (csr_snap_wr) begin
        for (int i = 0; i < NUM_CNT; i++)
          cnt_snap[i] <= cnt[i];
      end
    end
  end

  // ===========================================================================
  // CSR read FSM
  // ===========================================================================
  typedef enum logic [1:0] {R_IDLE, R_RESP} rstate_t;
  rstate_t rstate;
  logic [7:0] r_left;
  assign s_axi_rlast = (r_left == 0);

  logic [ID_WIDTH-1:0]   r_id;
  logic [ADDR_WIDTH-1:0] r_addr;
  logic                  r_is_burst;

  // Counter register address decode — uses s_axi_araddr directly (not r_addr,
  // which is registered and won't update until next cycle)
  // CTRL=0x00, then 9 counters at LO/HI pairs starting at 0x10
  logic [3:0] cnt_idx;
  logic       cnt_lo;
  logic       valid_counter_addr;

  wire [11:0] ar_off = s_axi_araddr[11:0];

  always_comb begin
    cnt_idx = 4'h0;
    cnt_lo = 1'b0;
    valid_counter_addr = 1'b0;
    // Counter LO/HI pairs at 0x10, 0x18, 0x20, ... 0x54
    if (ar_off >= 12'h010 && ar_off <= 12'h054) begin
      cnt_idx = (ar_off[11:3] - 5'd2); // 0x10>>3 = 2, subtract base
      cnt_lo = ~ar_off[2];
      valid_counter_addr = (cnt_idx < NUM_CNT);
    end
  end

  // Read data mux — uses s_axi_araddr directly for combinational decode
  logic [31:0] r_rdata_comb;
  logic [1:0]  r_rresp_comb;
  always_comb begin
    r_rdata_comb = 32'h0;
    r_rresp_comb = 2'b00;
    if (s_axi_arlen != 0 || s_axi_arsize != 2 || s_axi_arburst != 1 || ar_off[1:0] != 0) begin
      r_rresp_comb = 2'b10;
    end else begin
      if (ar_off == 12'h000) begin
        // CTRL
        r_rdata_comb = {29'b0, 1'b0, 1'b0, enable_reg};
      end else if (valid_counter_addr) begin
        // Counter snapshot register
        if (cnt_lo)
          r_rdata_comb = cnt_snap[cnt_idx][31:0];
        else
          r_rdata_comb = cnt_snap[cnt_idx][63:32];
      end else begin
        r_rresp_comb = 2'b10;
      end
    end
  end

  assign s_axi_arready = (rstate == R_IDLE);

  always_ff @(posedge clk or negedge aresetn) begin
    if (!aresetn) begin
      rstate       <= R_IDLE;
      r_left       <= 0;
      r_id         <= '0;
      r_addr       <= '0;
      r_is_burst   <= 1'b0;
      s_axi_rvalid <= 1'b0;
      s_axi_rresp  <= 2'b00;
      s_axi_rdata  <= 32'h0;
      s_axi_rid    <= '0;
    end else begin
      case (rstate)
        R_IDLE: begin
          if (s_axi_arvalid) begin
            r_left <= s_axi_arlen;
            r_id       <= s_axi_arid;
            r_addr     <= s_axi_araddr;
            r_is_burst <= (s_axi_arlen != 8'd0);
            s_axi_rid    <= s_axi_arid;
            s_axi_rdata  <= r_rdata_comb;
            s_axi_rresp   <= r_rresp_comb;
            s_axi_rvalid  <= 1'b1;
            rstate       <= R_RESP;
          end
        end
        R_RESP: begin
          if (s_axi_rready) begin
            if (r_left != 0) r_left <= r_left - 1'b1;
            else begin
              s_axi_rvalid <= 1'b0;
              rstate       <= R_IDLE;
            end
          end
        end
        default: rstate <= R_IDLE;
      endcase
    end
  end

endmodule

`resetall
