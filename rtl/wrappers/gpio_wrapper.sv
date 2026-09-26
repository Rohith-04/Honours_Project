// =============================================================================
// gpio_wrapper.sv — Fully custom GPIO (no external ips/ source)
//
// Register map (offsets from GPIO_BASE, see soc_pkg):
//   0x00 OUT  output values, low GPIO_WIDTH bits (RW)
//   0x04 IN   synchronized input pins, low bits (RO — writes get SLVERR)
//   0x08 DIR  per-bit direction, 1 = output (RW)
//
// Pins: gpio_out = OUT & DIR. Upper register bits are RAZ/WI.
// Single-beat AXI only; bursts (len != 0) and out-of-range offsets
// complete with SLVERR.
// =============================================================================

`resetall
`timescale 1ns / 1ps
`default_nettype none

module gpio_wrapper #(
  parameter int unsigned ID_WIDTH   = 12,
  parameter int unsigned ADDR_WIDTH = 32,
  parameter int unsigned WIDTH      = 8
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

  input  wire [WIDTH-1:0]      gpio_in,
  output wire [WIDTH-1:0]      gpio_out
);

  wire _unused = &{1'b0, s_axi_awsize, s_axi_awburst, s_axi_arsize,
                   s_axi_arburst, s_axi_wstrb};

  logic [WIDTH-1:0] out_reg;
  logic [WIDTH-1:0] dir_reg;
  logic [WIDTH-1:0] in_sync;

  assign gpio_out = out_reg & dir_reg;

  always_ff @(posedge clk or negedge aresetn) begin
    if (!aresetn) begin
      in_sync <= '0;
    end else begin
      in_sync <= gpio_in;
    end
  end

  // --- AXI write FSM: IDLE -> WDATA -> RESP -----------------------------------
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_RESP} wstate_t;
  wstate_t wstate;

  logic [ID_WIDTH-1:0]   w_id;
  logic [ADDR_WIDTH-1:0] w_addr;
  logic                  w_is_burst;

  assign s_axi_awready = (wstate == W_IDLE);
  assign s_axi_wready  = (wstate == W_DATA);

  always_ff @(posedge clk or negedge aresetn) begin
    if (!aresetn) begin
      wstate       <= W_IDLE;
      s_axi_bvalid <= 1'b0;
      s_axi_bresp  <= 2'b00;
      s_axi_bid    <= '0;
      out_reg      <= '0;
      dir_reg      <= '0;
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
            s_axi_bid <= w_id;
            if (w_is_burst || (w_addr[11:0] != 12'h000 &&
                               w_addr[11:0] != 12'h008)) begin
              // bursts, IN (RO), and out-of-range all get SLVERR
              s_axi_bresp <= 2'b10;
            end else begin
              s_axi_bresp <= 2'b00;
              if (w_addr[3:2] == 2'b00) begin        // OUT
                if (s_axi_wstrb[0]) out_reg <= s_axi_wdata[WIDTH-1:0];
              end else if (w_addr[3:2] == 2'b10) begin // DIR
                if (s_axi_wstrb[0]) dir_reg <= s_axi_wdata[WIDTH-1:0];
              end else begin
                s_axi_bresp <= 2'b10;
              end
            end
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

  // --- AXI read FSM: IDLE -> RESP ----------------------------------------------
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
                2'b00: s_axi_rdata <= {{(32-WIDTH){1'b0}}, out_reg};
                2'b01: s_axi_rdata <= {{(32-WIDTH){1'b0}}, in_sync};
                2'b10: s_axi_rdata <= {{(32-WIDTH){1'b0}}, dir_reg};
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
