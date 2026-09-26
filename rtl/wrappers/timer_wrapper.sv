// =============================================================================
// timer_wrapper.sv — Fully custom timer (no external ips/ source)
//
// Register map (offsets from TIMER_BASE, see soc_pkg):
//   0x00 CTRL    [0]=enable (RW), [1]=match sticky flag (W1C), rest RAZ
//   0x04 COUNT   current count (RW — write reloads the counter)
//   0x08 COMPARE match value (RW)
//
// Behavior: free-running 32-bit counter, increments each clk while enabled.
// When enabled and COUNT == COMPARE, the match flag sets and irq_o asserts
// (level, match & enable). Clear with a write-1-to-clear of CTRL[1].
// Single-beat AXI only; bursts (len != 0) and out-of-range offsets
// complete with SLVERR. Writes to undefined offsets are ignored for state
// but still complete (with SLVERR).
// =============================================================================

`resetall
`timescale 1ns / 1ps
`default_nettype none

module timer_wrapper #(
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
  output logic                 s_axi_rvalid,
  input  wire                  s_axi_rready,

  output wire                  irq_o
);

  wire _unused = &{1'b0, s_axi_awsize, s_axi_awburst, s_axi_arsize,
                   s_axi_arburst};

  // --- Write command pulse (combinational decode of the accepted beat) --------
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wstate_t;
  wstate_t wstate;

  logic [ID_WIDTH-1:0]   w_id;
  logic [ADDR_WIDTH-1:0] w_addr;
  logic                  w_is_burst;

  assign s_axi_awready = (wstate == W_IDLE);
  assign s_axi_wready  = (wstate == W_DATA);

  // Fires for exactly the cycle the W beat is accepted.
  wire w_fire = (wstate == W_DATA) && s_axi_wvalid;
  wire w_hit_ctrl    = (w_addr[11:0] == 12'h000);
  wire w_hit_count   = (w_addr[11:0] == 12'h004);
  wire w_hit_compare = (w_addr[11:0] == 12'h008);
  wire w_ok = !w_is_burst && (w_hit_ctrl || w_hit_count || w_hit_compare);

  always_ff @(posedge clk or negedge aresetn) begin
    if (!aresetn) begin
      wstate       <= W_IDLE;
      w_id         <= '0;
      w_addr       <= '0;
      w_is_burst   <= 1'b0;
      s_axi_bvalid <= 1'b0;
      s_axi_bresp  <= 2'b00;
      s_axi_bid    <= '0;
    end else begin
      case (wstate)
        W_IDLE: begin
          if (s_axi_awvalid) begin
            w_id       <= s_axi_awid;
            w_addr     <= s_axi_awaddr;
            w_is_burst <= (s_axi_awlen != 8'd0);
            wstate     <= W_DATA;
          end
        end
        W_DATA: begin
          if (s_axi_wvalid) begin
            s_axi_bid    <= w_id;
            s_axi_bresp  <= w_ok ? 2'b00 : 2'b10;
            s_axi_bvalid <= 1'b1;
            wstate       <= W_RESP;
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

  // --- Registers: single driver -------------------------------------------------
  logic        enable;
  logic        match;
  logic [31:0] count;
  logic [31:0] compare;

  assign irq_o = match & enable;

  always_ff @(posedge clk or negedge aresetn) begin
    if (!aresetn) begin
      enable  <= 1'b0;
      match   <= 1'b0;
      count   <= 32'h0;
      compare <= 32'h0;
    end else begin
      if (w_fire && w_ok) begin
        if (w_hit_ctrl && s_axi_wstrb[0]) begin
          enable <= s_axi_wdata[0];
          if (s_axi_wdata[1]) match <= 1'b0; // W1C
        end
        if (w_hit_count && (|s_axi_wstrb)) count <= s_axi_wdata; // reload
        if (w_hit_compare && (|s_axi_wstrb)) compare <= s_axi_wdata;
      end
      if (enable)
        count <= count + 32'd1;
      if (enable && (count == compare))
        match <= 1'b1;
    end
  end

  // --- AXI read FSM: IDLE -> RESP -----------------------------------------------
  typedef enum logic [1:0] {R_IDLE, R_RESP} rstate_t;
  rstate_t rstate;

  assign s_axi_arready = (rstate == R_IDLE);

  always_ff @(posedge clk or negedge aresetn) begin
    if (!aresetn) begin
      rstate       <= R_IDLE;
      s_axi_rvalid <= 1'b0;
      s_axi_rresp  <= 2'b00;
      s_axi_rdata  <= 32'h0;
      s_axi_rid    <= '0;
    end else begin
      case (rstate)
        R_IDLE: begin
          if (s_axi_arvalid) begin
            s_axi_rid <= s_axi_arid;
            if ((s_axi_arlen != 8'd0) ||
                (s_axi_araddr[11:0] != 12'h000 &&
                 s_axi_araddr[11:0] != 12'h004 &&
                 s_axi_araddr[11:0] != 12'h008)) begin
              s_axi_rresp <= 2'b10;
              s_axi_rdata <= 32'h0;
            end else begin
              s_axi_rresp <= 2'b00;
              case (s_axi_araddr[3:2])
                2'b00: s_axi_rdata <= {30'b0, match, enable};
                2'b01: s_axi_rdata <= count;
                2'b10: s_axi_rdata <= compare;
                default: begin
                  s_axi_rresp <= 2'b10;
                  s_axi_rdata <= 32'h0;
                end
              endcase
            end
            s_axi_rvalid <= 1'b1;
            rstate       <= R_RESP;
          end
        end
        R_RESP: begin
          if (s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
            rstate       <= R_IDLE;
          end
        end
        default: rstate <= R_IDLE;
      endcase
    end
  end

endmodule

`resetall
