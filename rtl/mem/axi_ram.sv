// =============================================================================
// axi_ram.sv — 64 KiB AXI4 RAM (simulation + SW backing store)
//
// - 32-bit data, 12-bit ID, INCR bursts, sizes 0..2 (1/2/4 bytes) with
//   strobes. FIXED/WRAP bursts and size > 2 complete with SLVERR.
// - Preloadable from a hex image: HEX_FILE parameter, or +SW_HEX=<path>
//   plusarg when the parameter is empty (SW-driven tests use the plusarg).
// - Always-ready slave (awready/arready/wready tied high) — legal AXI and
//   deadlock-free behind the interconnect's skid buffers.
// =============================================================================

`resetall
`timescale 1ns / 1ps
`default_nettype none

module axi_ram #(
  parameter int unsigned ADDR_WIDTH = 32,
  parameter int unsigned ID_WIDTH   = 12,
  parameter int unsigned MEM_BYTES  = 65536,
  parameter string       HEX_FILE   = ""
)(
  input  wire                  clk,
  input  wire                  aresetn,

  // Write address
  input  wire [ID_WIDTH-1:0]   s_axi_awid,
  input  wire [ADDR_WIDTH-1:0] s_axi_awaddr,
  input  wire [7:0]            s_axi_awlen,
  input  wire [2:0]            s_axi_awsize,
  input  wire [1:0]            s_axi_awburst,
  input  wire                  s_axi_awvalid,
  output logic                 s_axi_awready,
  // Write data
  input  wire [31:0]           s_axi_wdata,
  input  wire [3:0]            s_axi_wstrb,
  input  wire                  s_axi_wlast,
  input  wire                  s_axi_wvalid,
  output logic                 s_axi_wready,
  // Write response
  output logic [ID_WIDTH-1:0]  s_axi_bid,
  output logic [1:0]           s_axi_bresp,
  output logic                 s_axi_bvalid,
  input  wire                  s_axi_bready,
  // Read address
  input  wire [ID_WIDTH-1:0]   s_axi_arid,
  input  wire [ADDR_WIDTH-1:0] s_axi_araddr,
  input  wire [7:0]            s_axi_arlen,
  input  wire [2:0]            s_axi_arsize,
  input  wire [1:0]            s_axi_arburst,
  input  wire                  s_axi_arvalid,
  output logic                 s_axi_arready,
  // Read data
  output logic [ID_WIDTH-1:0]  s_axi_rid,
  output logic [31:0]          s_axi_rdata,
  output logic [1:0]           s_axi_rresp,
  output logic                 s_axi_rlast,
  output logic                 s_axi_rvalid,
  input  wire                  s_axi_rready
);

  localparam int unsigned WORDS = MEM_BYTES / 4;

  logic [31:0] mem [0:WORDS-1];

  // --- Preload ---------------------------------------------------------------
  initial begin : preload
    string hex_path;
    integer i;
    for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'h0;
    hex_path = HEX_FILE;
    if (hex_path == "") begin
      if ($value$plusargs("SW_HEX=%s", hex_path)) begin
        $display("[axi_ram] loading hex image: %s", hex_path);
        $readmemh(hex_path, mem);
      end
    end else begin
      $display("[axi_ram] loading hex image: %s", hex_path);
      $readmemh(hex_path, mem);
    end
  end

  // --- Write channel ----------------------------------------------------------
  // Always ready; latch command on AW handshake, apply strobed bytes per
  // beat, respond on WLAST.
  logic [ID_WIDTH-1:0] w_id;
  logic [31:0]         w_addr;
  logic [7:0]          w_len;
  logic [2:0]          w_size;
  logic                w_err;   // latched: unsupported burst/size
  logic [8:0]          w_beats; // beats remaining including current
  logic                w_active;

  // Accept a new command only when fully idle (no active burst, no pending
  // response). The BFM holds awvalid until bvalid, so ungated latching
  // would re-latch the same command while the response is pending.
  wire w_busy;
  assign w_busy        = w_active || s_axi_bvalid;
  assign s_axi_awready = ~w_busy;
  // W ready ONLY when a write command is latched — never tie high. The
  // interconnect consumes the master-side W beat the same cycle its slave
  // side is ready and retires single-beat writes immediately after; an
  // eager wready lets it swallow W in the AW-latch cycle, before w_active
  // registers. Result is w_active=1 with no W left to come: the core waits
  // for B, the RAM waits for W — deadlock (seen as B TIMEOUT at Level 2).
  // Gating W on w_active stalls the core in WRITE until we can actually
  // accept, exactly like the timer/gpio wrappers (W_DATA-gated) and the
  // UART IP (FSM-gated) already do.
  assign s_axi_wready  = w_active;

  // NOTE: plain `always`, not `always_ff` — `mem` is also written by the
  // `initial` preload block above, and VCS rejects variables shared between
  // `always_ff` and any other process (ICPD). Simulation-only model.
  always @(posedge clk or negedge aresetn) begin
    if (!aresetn) begin
      w_active     <= 1'b0;
      w_beats      <= '0;
      s_axi_bvalid <= 1'b0;
      s_axi_bresp  <= 2'b00;
      s_axi_bid    <= '0;
    end else begin
      if (s_axi_bvalid && s_axi_bready)
        s_axi_bvalid <= 1'b0;

      if (s_axi_awvalid && !w_busy) begin
        w_id     <= s_axi_awid;
        w_addr   <= s_axi_awaddr;
        w_len    <= s_axi_awlen;
        w_size   <= s_axi_awsize;
        w_err    <= (s_axi_awburst != 2'b01) || (s_axi_awsize > 3'd2);
        w_beats  <= {1'b0, s_axi_awlen} + 9'd1;
        w_active <= 1'b1;
`ifdef RAM_DEBUG
        $display("[RAM_DBG %0t] AW latch: addr=0x%0h len=%0d size=%0d burst=%b err=%b",
                 $time, s_axi_awaddr, s_axi_awlen, s_axi_awsize, s_axi_awburst,
                 (s_axi_awburst != 2'b01) || (s_axi_awsize > 3'd2));
`endif
      end

      if (w_active && s_axi_wvalid) begin
        // Apply this beat at byte granularity.
        logic [31:0] beat_addr;
        logic [31:0] word_addr;
        logic [1:0]  lane_off;
        integer b;
        beat_addr = w_addr + (({1'b0, w_len} + 9'd1 - w_beats) << w_size);
        word_addr = (beat_addr >> 2);
        lane_off  = beat_addr[1:0];
        if (!w_err && (word_addr < WORDS)) begin
          for (b = 0; b < 4; b = b + 1) begin
            if (s_axi_wstrb[b] && (b >= lane_off) &&
                (b < lane_off + (4'd1 << w_size)))
              mem[word_addr][b*8 +: 8] <= s_axi_wdata[b*8 +: 8];
          end
        end
        if (s_axi_wlast || (w_beats == 9'd1)) begin
          w_active     <= 1'b0;
          s_axi_bid    <= w_id;
          s_axi_bresp  <= w_err ? 2'b10 : 2'b00;
          s_axi_bvalid <= 1'b1;
`ifdef RAM_DEBUG
          $display("[RAM_DBG %0t] B fire: resp=%b (werr=%b)", $time,
                   w_err ? 2'b10 : 2'b00, w_err);
`endif
        end
        w_beats <= w_beats - 9'd1;
      end
    end
  end

  // --- Read channel ------------------------------------------------------------
  // Latch command on AR handshake; present one beat per cycle (held while
  // the master stalls); retire on the last accepted beat.
  logic [ID_WIDTH-1:0] r_id;
  logic [31:0]         r_addr;
  logic [2:0]          r_size;
  logic                r_err;
  logic [8:0]          r_beats_left; // beats remaining including current
  logic [8:0]          r_done;       // beats already accepted
  logic                r_active;

  assign s_axi_arready = ~r_active;
  assign s_axi_rid     = r_id;
  assign s_axi_rlast   = (r_beats_left == 9'd1);
  assign s_axi_rresp   = r_err ? 2'b10 : 2'b00;

  always_ff @(posedge clk or negedge aresetn) begin
    if (!aresetn) begin
      r_active     <= 1'b0;
      r_beats_left <= '0;
      r_done       <= '0;
      s_axi_rvalid <= 1'b0;
    end else begin
      if (s_axi_arvalid && !r_active) begin
        r_id         <= s_axi_arid;
        r_addr       <= s_axi_araddr;
        r_size       <= s_axi_arsize;
        r_err        <= (s_axi_arburst != 2'b01) || (s_axi_arsize > 3'd2);
        r_beats_left <= {1'b0, s_axi_arlen} + 9'd1;
        r_done       <= '0;
        r_active     <= 1'b1;
        s_axi_rvalid <= 1'b1;
`ifdef RAM_DEBUG
        $display("[RAM_DBG %0t] AR latch: addr=0x%0h len=%0d size=%0d burst=%b err=%b",
                 $time, s_axi_araddr, s_axi_arlen, s_axi_arsize, s_axi_arburst,
                 (s_axi_arburst != 2'b01) || (s_axi_arsize > 3'd2));
`endif
      end else if (r_active && s_axi_rvalid && s_axi_rready) begin
`ifdef RAM_DEBUG
        $display("[RAM_DBG %0t] R beat: beat_addr=0x%0h data=0x%0h resp=%b last=%b",
                 $time, r_addr + (r_done << r_size), s_axi_rdata,
                 s_axi_rresp, s_axi_rlast);
`endif
        r_done <= r_done + 9'd1;
        if (r_beats_left == 9'd1) begin
          r_active     <= 1'b0;
          s_axi_rvalid <= 1'b0;
        end else begin
          r_beats_left <= r_beats_left - 9'd1;
        end
      end
    end
  end

  // Narrow-transfer lane masking: data appears on its aligned byte lanes.
  always_comb begin
    logic [31:0] beat_addr;
    logic [31:0] word_addr;
    logic [1:0]  lane_off;
    logic [3:0]  lane_mask;
    integer b;
    beat_addr = r_addr + (r_done << r_size);
    word_addr = beat_addr >> 2;
    lane_off  = beat_addr[1:0];
    lane_mask = 4'b0;
    for (b = 0; b < 4; b = b + 1)
      if ((b >= lane_off) && (b < lane_off + (4'd1 << r_size)))
        lane_mask[b] = 1'b1;
    if (!r_active || r_err || (word_addr >= WORDS))
      s_axi_rdata = 32'h0;
    else
      s_axi_rdata = mem[word_addr] & {{8{lane_mask[3]}}, {8{lane_mask[2]}},
                                       {8{lane_mask[1]}}, {8{lane_mask[0]}}};
  end

endmodule

`resetall
