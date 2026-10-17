// =============================================================================
// wdt_wrapper.sv — NDA Watchdog Timer (WDT)
//
// Watches NDA progress, not total time.  Arms when NDA busy rises, reloads
// on every progress pulse (one per accepted R beat).  If TIMEOUT cycles
// pass with no progress, the WDT trips: sets TRIPPED, asserts abort into
// the NDA, increments TRIP_COUNT, raises IRQ if enabled.
//
// See "NDA, HPM and WDT Design Document" §4 for full specification.
// =============================================================================

`resetall
`timescale 1ns / 1ps
`default_nettype none

module wdt_wrapper #(
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

  // --- Sideband from/to NDA ---
  input  wire                  nda_busy_i,
  input  wire                  nda_progress_i,
  output wire                  abort_o,
  output wire                  trip_o,
  output wire                  irq_o
);

  wire _unused = &{1'b0, s_axi_awsize, s_axi_awburst, s_axi_arsize,
                   s_axi_arburst, s_axi_wstrb};

  // ===========================================================================
  // CSR registers
  // ===========================================================================
  logic        en_reg;
  logic        irq_en_reg;
  logic [31:0] timeout_reg;
  logic        tripped;
  logic        armed;
  logic [31:0] trip_count_reg;

  // Watchdog counter
  logic [31:0] wdt_counter;
  logic        prev_busy;

  // Trip pulse (one cycle)
  logic        trip_pulse;

  // ===========================================================================
  // CSR write FSM (declared before watchdog block that references w_fire/w_ok)
  // ===========================================================================
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wstate_t;
  wstate_t wstate;

  logic [ID_WIDTH-1:0]   w_id;
  logic [ADDR_WIDTH-1:0] w_addr;
  logic                  w_is_burst;

  assign s_axi_awready = (wstate == W_IDLE);
  assign s_axi_wready  = (wstate == W_DATA);

  wire w_fire = (wstate == W_DATA) && s_axi_wvalid;
  wire w_hit_ctrl    = (w_addr[11:0] == 12'h000);
  wire w_hit_timeout = (w_addr[11:0] == 12'h004);
  wire w_hit_status  = (w_addr[11:0] == 12'h008);
  // TRIP_COUNT is read-only
  wire w_ok = !w_is_burst && (w_hit_ctrl || w_hit_timeout || w_hit_status);

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

  // ===========================================================================
  // Watchdog logic (references w_fire/w_ok from CSR write FSM above)
  // ===========================================================================
  wire timeout_active = en_reg && (timeout_reg != 0);

  always_ff @(posedge clk or negedge aresetn) begin
    if (!aresetn) begin
      en_reg         <= 1'b0;
      irq_en_reg     <= 1'b0;
      timeout_reg    <= soc_pkg::WDT_TIMEOUT_DEFAULT;
      tripped        <= 1'b0;
      armed          <= 1'b0;
      trip_count_reg <= 32'h0;
      wdt_counter    <= 32'h0;
      prev_busy      <= 1'b0;
      trip_pulse     <= 1'b0;
    end else begin
      trip_pulse <= 1'b0;

      // Detect busy rising edge to arm
      if (timeout_active && nda_busy_i && !prev_busy) begin
        // Re-arm: clear tripped from previous job, reload counter
        armed       <= 1'b1;
        tripped     <= 1'b0;
        wdt_counter <= timeout_reg;
      end

      // Disarm when NDA goes idle
      if (!nda_busy_i && prev_busy) begin
        armed <= 1'b0;
      end

      // While armed and busy
      if (armed && nda_busy_i) begin
        if (nda_progress_i) begin
          // Progress — reload counter
          wdt_counter <= timeout_reg;
        end else begin
          if (wdt_counter == 32'd0) begin
            // Trip!
            tripped      <= 1'b1;
            armed       <= 1'b0;
            trip_pulse  <= 1'b1;
            trip_count_reg <= trip_count_reg + 32'd1;
          end else begin
            wdt_counter <= wdt_counter - 32'd1;
          end
        end
      end

      // CSR writes
      if (w_fire && w_ok) begin
        if (w_hit_ctrl && s_axi_wstrb[0]) begin
          en_reg     <= s_axi_wdata[0];
          irq_en_reg <= s_axi_wdata[2];
        end
        if (w_hit_timeout && (|s_axi_wstrb)) timeout_reg <= s_axi_wdata;
        if (w_hit_status && s_axi_wdata[0]) tripped <= 1'b0; // W1C
      end

      prev_busy <= nda_busy_i;
    end
  end

  // ===========================================================================
  // CSR read FSM (same pattern as timer_wrapper)
  // ===========================================================================
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
                 s_axi_araddr[11:0] != 12'h008 &&
                 s_axi_araddr[11:0] != 12'h00C)) begin
              s_axi_rresp <= 2'b10;
              s_axi_rdata <= 32'h0;
            end else begin
              s_axi_rresp <= 2'b00;
              case (s_axi_araddr[3:2])
                2'b00: s_axi_rdata <= {29'b0, irq_en_reg, 2'b0, en_reg}; // CTRL
                2'b01: s_axi_rdata <= timeout_reg;                     // TIMEOUT
                2'b10: s_axi_rdata <= {30'b0, armed, tripped};          // STATUS
                2'b11: s_axi_rdata <= trip_count_reg;                   // TRIP_COUNT
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

  // ===========================================================================
  // Outputs
  // ===========================================================================
  assign abort_o = trip_pulse;
  assign trip_o  = trip_pulse;
  assign irq_o   = tripped & irq_en_reg;

endmodule

`resetall
