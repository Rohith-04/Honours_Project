// =============================================================================
// nda_wrapper.sv — Near-Data Accelerator (NDA)
//
// AXI4-Lite CSR slave + AXI4 read master.  Software configures an address
// range and operation; the NDA streams the array over its read master,
// reduces it, and reports completion by interrupt and status flag.
//
// Operations: SUM (64-bit accumulator), MIN, MAX, ARGMAX over 32-bit signed
// integers.  FSM: IDLE → CHECK → RUN → DRAIN → (back to IDLE with DONE/ERR).
//
// See "NDA, HPM and WDT Design Document" §3 for full specification.
// =============================================================================

`resetall
`timescale 1ns / 1ps
`default_nettype none

module nda_wrapper #(
  parameter int unsigned ID_WIDTH       = 12,
  parameter int unsigned ADDR_WIDTH     = 32,
  parameter int unsigned BURST_LEN       = soc_pkg::NDA_BURST_LEN,
  parameter int unsigned MAX_OUTSTANDING = soc_pkg::NDA_MAX_OUTSTANDING
)(
  input  wire                  clk,
  input  wire                  aresetn,

  // --- CSR AXI4-Lite slave port (single-beat only) ---------------------------
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

  // --- AXI4 read master port (AR + R only; AW/W/B tied off) -------------------
  output wire [ID_WIDTH-1:0]   m_axi_arid,
  output wire [ADDR_WIDTH-1:0] m_axi_araddr,
  output wire [7:0]            m_axi_arlen,
  output wire [2:0]            m_axi_arsize,
  output wire [1:0]            m_axi_arburst,
  output wire                  m_axi_arvalid,
  input  wire                  m_axi_arready,
  input  wire [ID_WIDTH-1:0]   m_axi_rid,
  input  wire [31:0]           m_axi_rdata,
  input  wire [1:0]            m_axi_rresp,
  input  wire                  m_axi_rlast,
  input  wire                  m_axi_rvalid,
  output wire                  m_axi_rready,

  // --- Sideband ---------------------------------------------------------------
  output wire                  nda_busy_o,
  output wire                  nda_progress_o,
  input  wire                  wdt_abort_i,
  output wire                  irq_o
);

  wire _unused = &{1'b0, s_axi_awsize, s_axi_awburst, s_axi_arsize,
                   s_axi_arburst, s_axi_wstrb, m_axi_rid};

  // ===========================================================================
  // CSR registers
  // ===========================================================================
  logic [3:0]  op_reg;
  logic [31:0] src_base_reg;
  logic [31:0] len_reg;
  logic        irq_en_reg;
  logic        done_flag;
  logic        err_flag;
  logic [3:0]  err_code_reg;
  logic [3:0]  drain_error_code;
  logic [31:0] result_lo_reg;
  logic [31:0] result_hi_reg;
  logic [31:0] cycles_reg;

  // ===========================================================================
  // Control FSM
  // ===========================================================================
  typedef enum logic [1:0] {IDLE, CHECK, RUN, DRAIN} fsm_t;
  fsm_t fsm;

  wire nda_busy = (fsm != IDLE);

  logic        start_req;
  logic        abort_req;

  // Address generator
  logic [31:0] cur_addr;          // next address to issue AR for
  logic [31:0] elem_to_issue;     // elements remaining to issue
  logic [31:0] total_elements;     // total elements in this job
  logic [31:0] elem_received;     // R beats consumed in RUN (OKAY only)
  logic [31:0] elem_idx;           // element index (for ARGMAX)
  logic [15:0] outstanding;        // outstanding burst count

  // Datapath
  logic signed [63:0] sum_acc;
  logic [31:0]        best_val;
  logic [31:0]        best_idx;

  // ===========================================================================
  // CSR write FSM (AXI handshake only — register writes in main always_ff)
  // ===========================================================================
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wstate_t;
  wstate_t wstate;

  logic [ID_WIDTH-1:0]   w_id;
  logic [ADDR_WIDTH-1:0] w_addr;
  logic                  w_is_burst;
  logic [7:0]            w_left;

  // w_fire: the cycle the W beat is accepted
  wire w_fire = (wstate == W_DATA) && s_axi_wvalid;

  // Write response (combinational decode)
  logic [1:0] w_bresp;
  always_comb begin
    w_bresp = 2'b00; // OKAY default
    if (w_is_burst) begin
      w_bresp = 2'b10;
    end else begin
      case (w_addr[11:0])
        12'h000: if (s_axi_wstrb[0] && s_axi_wdata[0] && nda_busy) w_bresp = 2'b10;
        12'h004: ; // STATUS W1C — always OK
        12'h008, 12'h00C, 12'h010: if (nda_busy) w_bresp = 2'b10; // OP/SRC/LEN while BUSY
        12'h014, 12'h018, 12'h01C: w_bresp = 2'b10; // RO registers
        default: w_bresp = 2'b10; // undefined offset
      endcase
    end
  end

  assign s_axi_awready = (wstate == W_IDLE);
  assign s_axi_wready  = (wstate == W_DATA);

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
            w_left     <= s_axi_awlen;
            wstate     <= W_DATA;
          end
        end
        W_DATA: begin
          if (s_axi_wvalid) begin
            if (w_left != 0) w_left <= w_left - 1'b1;
            else begin
              s_axi_bid    <= w_id;
              s_axi_bresp  <= w_bresp;
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
  // CSR read FSM
  // ===========================================================================
  typedef enum logic [1:0] {R_IDLE, R_RESP} rstate_t;
  rstate_t rstate;

  logic [ID_WIDTH-1:0]   r_id;
  logic [ADDR_WIDTH-1:0] r_addr;
  logic                  r_is_burst;
  logic [7:0]            r_left;
  assign s_axi_rlast = (r_left == 0);

  // Read data and response (combinational — uses s_axi_araddr directly)
  logic [31:0] r_rdata;
  logic [1:0]  r_rresp;
  always_comb begin
    r_rresp = 2'b00;
    r_rdata = 32'h0;
    if (s_axi_arlen != 0 || s_axi_arsize != 2 || s_axi_arburst != 1) begin
      r_rresp = 2'b10;
    end else begin
      case (s_axi_araddr[11:0])
        12'h000: r_rdata = {29'b0, irq_en_reg, 2'b0}; // CTRL (START/ABORT read 0)
        12'h004: r_rdata = {24'b0, err_code_reg, 1'b0, err_flag, done_flag, nda_busy};
        12'h008: r_rdata = {28'b0, op_reg};
        12'h00C: r_rdata = src_base_reg;
        12'h010: r_rdata = len_reg;
        12'h014: r_rdata = result_lo_reg;
        12'h018: r_rdata = result_hi_reg;
        12'h01C: r_rdata = cycles_reg;
        default: r_rresp = 2'b10;
      endcase
    end
  end

  assign s_axi_arready = (rstate == R_IDLE);

  always_ff @(posedge clk or negedge aresetn) begin
    if (!aresetn) begin
      rstate       <= R_IDLE;
      r_id         <= '0;
      r_addr       <= '0;
      r_is_burst   <= 1'b0;
      r_left       <= 0;
      s_axi_rvalid <= 1'b0;
      s_axi_rresp  <= 2'b00;
      s_axi_rdata  <= 32'h0;
      s_axi_rid    <= '0;
    end else begin
      case (rstate)
        R_IDLE: begin
          if (s_axi_arvalid) begin
            r_id       <= s_axi_arid;
            r_addr     <= s_axi_araddr;
            r_is_burst <= (s_axi_arlen != 8'd0);
            r_left     <= s_axi_arlen;
            s_axi_rid    <= s_axi_arid;
            s_axi_rdata  <= r_rdata;
            s_axi_rresp   <= r_rresp;
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

  // ===========================================================================
  // AXI read master — registered request, held through acceptance
  // ===========================================================================

  // Burst length: min of remaining elements, BURST_LEN, and beats to 4KB boundary
  wire [31:0] beats_to_boundary = (32'h1000 - {20'b0, cur_addr[11:0]}) >> 2;
  wire [31:0] burst_len_raw = (elem_to_issue < BURST_LEN) ?
                              elem_to_issue : BURST_LEN[31:0];
  wire [31:0] burst_len = (burst_len_raw < beats_to_boundary) ?
                          burst_len_raw : beats_to_boundary;

  logic ar_pending;
  wire ar_fire = ar_pending && m_axi_arready;
  wire abort_now = abort_req || wdt_abort_i;

  // A presented request survives abort until accepted. DRAIN must then
  // consume its response as well as those already outstanding.
  always_ff @(posedge clk or negedge aresetn) begin
    if (!aresetn) ar_pending <= 1'b0;
    else if (ar_fire) ar_pending <= 1'b0;
    else if (fsm == RUN && !abort_now && elem_to_issue != 0 &&
             outstanding < MAX_OUTSTANDING) ar_pending <= 1'b1;
  end

  assign m_axi_arid    = '0;              // constant ARID
  assign m_axi_araddr  = cur_addr;
  assign m_axi_arlen   = burst_len - 1;
  assign m_axi_arsize  = 3'b010;          // 4 bytes
  assign m_axi_arburst = 2'b01;           // INCR
  assign m_axi_arvalid = ar_pending;

  // R channel
  assign m_axi_rready = (fsm == RUN) || (fsm == DRAIN);
  wire r_fire = m_axi_rvalid & m_axi_rready;

  // ===========================================================================
  // Sideband outputs
  // ===========================================================================
  assign nda_busy_o     = nda_busy;
  assign nda_progress_o = r_fire;
  assign irq_o          = (done_flag || err_flag) && irq_en_reg;

  // ===========================================================================
  // Main always_ff: FSM + registers + datapath + address gen + cycle counter
  // ===========================================================================
  // Range check helper: 35-bit arithmetic to prevent wrap on huge LEN
  wire [34:0] range_end = {3'b0, src_base_reg} + ({3'b0, len_reg} << 2);

  always_ff @(posedge clk or negedge aresetn) begin
    if (!aresetn) begin
      // Registers
      op_reg        <= 4'd0;
      src_base_reg  <= 32'h0;
      len_reg       <= 32'h0;
      irq_en_reg    <= 1'b0;
      done_flag     <= 1'b0;
      err_flag      <= 1'b0;
      err_code_reg  <= 4'h0;
      drain_error_code <= 4'h0;
      result_lo_reg <= 32'h0;
      result_hi_reg <= 32'h0;
      cycles_reg    <= 32'h0;
      start_req     <= 1'b0;
      abort_req     <= 1'b0;

      // FSM
      fsm           <= IDLE;
      cur_addr      <= 32'h0;
      elem_to_issue <= 32'h0;
      total_elements <= 32'h0;
      elem_received  <= 32'h0;
      elem_idx       <= 32'h0;
      outstanding   <= 16'h0;

      // Datapath
      sum_acc   <= 64'sd0;
      best_val  <= 32'h0;
      best_idx  <= 32'h0;
    end else begin
      abort_req <= 1'b0;
      if (fsm == RUN || fsm == DRAIN) begin
        case ({ar_fire, (r_fire && m_axi_rlast)})
          2'b10: outstanding <= outstanding + 16'd1;
          2'b01: outstanding <= outstanding - 16'd1;
          default: ;
        endcase
      end
      // --- Cycle counter: counts while not in IDLE ---
      if (fsm != IDLE)
        cycles_reg <= cycles_reg + 32'd1;

      // --- CSR write effects (w_fire from CSR write FSM) ---
      if (w_fire && w_bresp == 2'b00) begin
        case (w_addr[11:0])
          12'h000: begin // CTRL
            if (s_axi_wstrb[0] && s_axi_wdata[0] && !nda_busy) start_req <= 1'b1;
            if (s_axi_wstrb[0] && s_axi_wdata[1] && nda_busy) abort_req <= 1'b1;
            if (s_axi_wstrb[0])              irq_en_reg <= s_axi_wdata[2];
          end
          12'h004: begin // STATUS W1C
            if (s_axi_wstrb[0] && s_axi_wdata[1]) done_flag <= 1'b0;
            if (s_axi_wstrb[0] && s_axi_wdata[2]) begin
              err_flag    <= 1'b0;
              err_code_reg <= 4'h0;
            end
          end
          12'h008: if (s_axi_wstrb[0]) op_reg <= s_axi_wdata[3:0];
          12'h00C: for (int b = 0; b < 4; b++)
            if (s_axi_wstrb[b]) src_base_reg[b*8 +: 8] <= s_axi_wdata[b*8 +: 8];
          12'h010: for (int b = 0; b < 4; b++)
            if (s_axi_wstrb[b]) len_reg[b*8 +: 8] <= s_axi_wdata[b*8 +: 8];
          default: ; // RO or undefined — no register write
        endcase
      end

      // --- FSM ---
      case (fsm)
        IDLE: begin
          if (start_req) begin
            start_req    <= 1'b0;
            // Clear previous job flags
            done_flag    <= 1'b0;
            err_flag     <= 1'b0;
            err_code_reg <= 4'h0;
            cycles_reg   <= 32'd1; // one cycle since the accepted START write
            fsm          <= CHECK;
          end
        end

        CHECK: begin
          // Config checks in fixed order (first error wins)
          if (abort_now) begin
            err_flag <= 1'b1;
            err_code_reg <= soc_pkg::NDA_ERR_ABORTED;
            done_flag <= 1'b1;
            fsm <= IDLE;
          end else if (len_reg == 0) begin
            err_flag    <= 1'b1;
            err_code_reg <= soc_pkg::NDA_ERR_BAD_LEN;
            done_flag   <= 1'b1;
            fsm         <= IDLE;
          end else if (op_reg > 4'd3) begin
            err_flag    <= 1'b1;
            err_code_reg <= soc_pkg::NDA_ERR_BAD_OP;
            done_flag   <= 1'b1;
            fsm         <= IDLE;
          end else if (src_base_reg[1:0] != 2'b00) begin
            err_flag    <= 1'b1;
            err_code_reg <= soc_pkg::NDA_ERR_MISALIGNED;
            done_flag   <= 1'b1;
            fsm         <= IDLE;
          end else if (src_base_reg < soc_pkg::NDA_DATA_BASE ||
                      src_base_reg >= soc_pkg::NDA_DATA_END) begin
            err_flag    <= 1'b1;
            err_code_reg <= soc_pkg::NDA_ERR_BAD_ADDR;
            done_flag   <= 1'b1;
            fsm         <= IDLE;
          end else begin
            // Range check: 35-bit arithmetic
            if (range_end > soc_pkg::NDA_DATA_END) begin
              err_flag    <= 1'b1;
              err_code_reg <= soc_pkg::NDA_ERR_BAD_RANGE;
              done_flag   <= 1'b1;
              fsm         <= IDLE;
            end else begin
              // All checks pass — initialize for RUN
              cur_addr      <= src_base_reg;
              elem_to_issue <= len_reg;
              total_elements <= len_reg;
              elem_received  <= 32'h0;
              elem_idx       <= 32'h0;
              outstanding    <= 16'h0;
              // Datapath init
              sum_acc  <= 64'sd0;
              best_val <= (op_reg == soc_pkg::NDA_OP_MIN) ?
                          32'h7FFF_FFFF : 32'h8000_0000;
              best_idx <= 32'h0;
              fsm      <= RUN;
            end
          end
        end

        RUN: begin
          // --- Address generator: issue AR ---
          if (ar_fire) begin
            cur_addr      <= cur_addr + (burst_len << 2);
            elem_to_issue <= elem_to_issue - burst_len;
          end

          // --- R beat consumer + datapath ---
          if (r_fire) begin
            if (m_axi_rresp != 2'b00) begin
              // Bus error — enter DRAIN
              drain_error_code <= soc_pkg::NDA_ERR_BUS_ERROR;
              fsm          <= DRAIN;
            end else begin
              // Feed to datapath
              case (op_reg)
                soc_pkg::NDA_OP_SUM: begin
                  sum_acc <= sum_acc + $signed(m_axi_rdata);
                end
                soc_pkg::NDA_OP_MIN: begin
                  if ($signed(m_axi_rdata) < $signed(best_val))
                    best_val <= m_axi_rdata;
                end
                soc_pkg::NDA_OP_MAX: begin
                  if ($signed(m_axi_rdata) > $signed(best_val))
                    best_val <= m_axi_rdata;
                end
                soc_pkg::NDA_OP_ARGMAX: begin
                  if ($signed(m_axi_rdata) > $signed(best_val)) begin
                    best_val <= m_axi_rdata;
                    best_idx <= elem_idx;
                  end
                end
                default: ;
              endcase
              elem_received  <= elem_received + 32'd1;
              elem_idx       <= elem_idx + 32'd1;
            end
            // Outstanding accounting is shared by RUN and DRAIN above.
          end

          // --- Abort check ---
          if (abort_now && !(r_fire && m_axi_rresp != 2'b00)) begin
            abort_req    <= 1'b0;
            drain_error_code <= soc_pkg::NDA_ERR_ABORTED;
            fsm          <= DRAIN;
          end

          // --- Completion check (all elements received, including this cycle) ---
          begin : completion_check
            logic [31:0] recv_after;
            logic [63:0] next_sum;
            logic [31:0] next_best;
            logic [31:0] next_bidx;
            logic        this_beat;
            this_beat = r_fire && (m_axi_rresp == 2'b00);
            recv_after = elem_received + (this_beat ? 32'd1 : 32'd0);
            // Compute next-cycle accumulator values for latching
            next_sum  = sum_acc + (this_beat ? $signed(m_axi_rdata) : 64'sd0);
            next_best = (this_beat && ($signed(m_axi_rdata) > $signed(best_val))) ?
                         m_axi_rdata : best_val;
            next_bidx = (this_beat && ($signed(m_axi_rdata) > $signed(best_val))) ?
                         elem_idx : best_idx;
            if (recv_after == total_elements && total_elements != 0 &&
                !abort_now) begin
              done_flag <= 1'b1;
              case (op_reg)
                soc_pkg::NDA_OP_SUM: begin
                  result_lo_reg <= next_sum[31:0];
                  result_hi_reg <= next_sum[63:32];
                end
                soc_pkg::NDA_OP_MIN: begin
                  result_lo_reg <= (this_beat &&
                    ($signed(m_axi_rdata) < $signed(best_val))) ?
                    m_axi_rdata : best_val;
                  result_hi_reg <= 32'h0;
                end
                soc_pkg::NDA_OP_MAX: begin
                  result_lo_reg <= next_best;
                  result_hi_reg <= 32'h0;
                end
                soc_pkg::NDA_OP_ARGMAX: begin
                  result_lo_reg <= next_best;
                  result_hi_reg <= next_bidx;
                end
                default: ;
              endcase
              fsm <= IDLE;
            end
          end
        end

        DRAIN: begin
          // Wait for all outstanding R responses
          if (outstanding == 16'h0 && !ar_pending) begin
            err_flag <= 1'b1;
            err_code_reg <= drain_error_code;
            done_flag <= 1'b1;
            fsm       <= IDLE;
          end
        end

        default: fsm <= IDLE;
      endcase
    end
  end

  // synthesis translate_off
  initial begin
    assert (BURST_LEN >= 1 && BURST_LEN <= 256 &&
            MAX_OUTSTANDING >= 1 && MAX_OUTSTANDING <= 65535)
      else $fatal(1, "Invalid NDA burst/outstanding parameters");
  end
  assert property (@(posedge clk) disable iff (!aresetn)
    m_axi_arvalid && !m_axi_arready |=>
      m_axi_arvalid && $stable({m_axi_araddr, m_axi_arlen}))
    else $fatal(1, "NDA withdrew or changed stalled AR");
  // synthesis translate_on
endmodule

`resetall
