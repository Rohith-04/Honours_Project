// =============================================================================
// uart_wrap.sv — AXI4-Lite wrapper for the BSC/CIC-IPN AXI-UART IP
//
// Wraps:  ips/uart/src/rtl/axi_uart_top.v
//
// WHY THE SHIM: axi_uart_top gates its responses on held request valids
//   bvalid_o = (awvalid & wvalid & ~sync) ? bvalid : 0
//   rvalid_o = (arvalid & ~sync) ? rvalid : 0
// A standard AXI manager (the xbar, VeeR LSU) drops aw/arvalid after the
// ready handshake and only waits for b/rvalid — which the IP then kills,
// hanging reads (proven: s03->xbar->m05 LSR reads TIMEOUT while writes
// squeak through on same-cycle capture). The shim below presents a
// standard AXI4-Lite target upstream (ready-then-response-held) while
// holding the IP-side valids until the IP answers.
//
// Clocks: fixed_clk_i = axi_aclk_i = clk (single SoC clock).
// The IP uses 5-bit byte addresses; the upper 32-bit window bits are
// stripped here (slave decode sized >= 32 bytes).
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module uart_wrap #(
    parameter AXI_ID_WIDTH = 8          // match interconnect M-port ID width
) (
    // -------------------------------------------------------------------------
    // Clocks and reset
    // -------------------------------------------------------------------------
    input  logic                     clk,       // system clock (AXI + UART baud)
    input  logic                     rst_n,     // active-low synchronous reset

    // -------------------------------------------------------------------------
    // AXI4-Lite slave interface  (from interconnect master port, STANDARD)
    // -------------------------------------------------------------------------
    // Write address
    input  logic                     s_axi_awvalid,
    output logic                     s_axi_awready,
    input  logic [AXI_ID_WIDTH-1:0]  s_axi_awid,
    input  logic [31:0]              s_axi_awaddr,
    // Write data
    input  logic                     s_axi_wvalid,
    output logic                     s_axi_wready,
    input  logic [31:0]              s_axi_wdata,
    input  logic [3:0]               s_axi_wstrb,
    // Write response
    output logic                     s_axi_bvalid,
    input  logic                     s_axi_bready,
    output logic [AXI_ID_WIDTH-1:0]  s_axi_bid,
    output logic [1:0]               s_axi_bresp,
    // Read address
    input  logic                     s_axi_arvalid,
    output logic                     s_axi_arready,
    input  logic [AXI_ID_WIDTH-1:0]  s_axi_arid,
    input  logic [31:0]              s_axi_araddr,
    // Read data
    output logic                     s_axi_rvalid,
    input  logic                     s_axi_rready,
    output logic [AXI_ID_WIDTH-1:0]  s_axi_rid,
    output logic [31:0]              s_axi_rdata,
    output logic [1:0]               s_axi_rresp,

    // -------------------------------------------------------------------------
    // UART physical interface
    // -------------------------------------------------------------------------
    input  logic                     uart_rx,
    output logic                     uart_tx,

    // -------------------------------------------------------------------------
    // Interrupt to CPU PIC
    // -------------------------------------------------------------------------
    output logic                     uart_irq    // high = RX data available
);

    localparam IP_ADDR_W = 5;
    localparam IP_ID_W   = 12;

    // ------------------------------------------------------------------
    // Write shim: IDLE -> IP -> RESP (independent of read shim)
    // ------------------------------------------------------------------
    typedef enum logic [1:0] { W_IDLE, W_IP, W_RESP } wstate_t;
    wstate_t wstate, wstate_n;

    logic [AXI_ID_WIDTH-1:0] w_id;
    logic [IP_ADDR_W-1:0]    w_addr;
    logic [31:0]             w_data;
    logic [3:0]              w_strb;
    logic [AXI_ID_WIDTH-1:0] w_bid;
    logic [1:0]              w_bresp;

    logic ip_awvalid, ip_wvalid;
    wire  ip_awready, ip_wready, ip_bvalid;
    wire [IP_ID_W-1:0] ip_bid;
    wire [1:0]         ip_bresp;

    // Upstream handshake: accept AW+W together (AXI-Lite single beat)
    assign s_axi_awready = (wstate == W_IDLE);
    assign s_axi_wready  = (wstate == W_IDLE);
    assign s_axi_bvalid  = (wstate == W_RESP);
    assign s_axi_bid     = w_bid;
    assign s_axi_bresp   = w_bresp;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wstate <= W_IDLE;
            w_id   <= '0;
            w_addr <= '0;
            w_data <= '0;
            w_strb <= '0;
            w_bid  <= '0;
            w_bresp <= 2'b00;
        end else begin
            wstate <= wstate_n;
            case (wstate)
                W_IDLE: begin
                    if (s_axi_awvalid && s_axi_wvalid) begin
                        w_id   <= s_axi_awid;
                        w_addr <= s_axi_awaddr[IP_ADDR_W-1:0];
                        w_data <= s_axi_wdata;
                        w_strb <= s_axi_wstrb;
                    end
                end
                W_IP: begin
                    if (ip_bvalid) begin
                        w_bid   <= ip_bid[AXI_ID_WIDTH-1:0];
                        w_bresp <= ip_bresp;
                    end
                end
                W_RESP: begin
                    if (s_axi_bready) begin
                        w_bid   <= '0;
                        w_bresp <= 2'b00;
                    end
                end
            endcase
        end
    end

    always_comb begin
        wstate_n   = wstate;
        ip_awvalid = 1'b0;
        ip_wvalid  = 1'b0;
        case (wstate)
            W_IDLE: if (s_axi_awvalid && s_axi_wvalid) wstate_n = W_IP;
            W_IP: begin
                ip_awvalid = 1'b1;
                ip_wvalid  = 1'b1;
                if (ip_bvalid) wstate_n = W_RESP;
            end
            W_RESP: if (s_axi_bready) wstate_n = W_IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // Read shim: IDLE -> IP -> RESP (independent of write shim)
    // ------------------------------------------------------------------
    typedef enum logic [1:0] { R_IDLE, R_IP, R_RESP } rstate_t;
    rstate_t rstate, rstate_n;

    logic [AXI_ID_WIDTH-1:0] r_id;
    logic [IP_ADDR_W-1:0]    r_addr;
    logic [AXI_ID_WIDTH-1:0] r_rid;
    logic [31:0]             r_rdata;
    logic [1:0]              r_rresp;

    logic ip_arvalid;
    wire  ip_arready, ip_rvalid;
    wire [IP_ID_W-1:0] ip_rid;
    wire [31:0]        ip_rdata;
    wire [1:0]         ip_rresp;

    assign s_axi_arready = (rstate == R_IDLE);
    assign s_axi_rvalid  = (rstate == R_RESP);
    assign s_axi_rid     = r_rid;
    assign s_axi_rdata   = r_rdata;
    assign s_axi_rresp   = r_rresp;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate <= R_IDLE;
            r_id   <= '0;
            r_addr <= '0;
            r_rid  <= '0;
            r_rdata <= '0;
            r_rresp <= 2'b00;
        end else begin
            rstate <= rstate_n;
            case (rstate)
                R_IDLE: begin
                    if (s_axi_arvalid) begin
                        r_id   <= s_axi_arid;
                        r_addr <= s_axi_araddr[IP_ADDR_W-1:0];
                    end
                end
                R_IP: begin
                    if (ip_rvalid) begin
                        r_rid   <= ip_rid[AXI_ID_WIDTH-1:0];
                        r_rdata <= ip_rdata;
                        r_rresp <= ip_rresp;
                    end
                end
                R_RESP: begin
                    if (s_axi_rready) begin
                        r_rid   <= '0;
                        r_rdata <= '0;
                        r_rresp <= 2'b00;
                    end
                end
            endcase
        end
    end

    always_comb begin
        rstate_n   = rstate;
        ip_arvalid = 1'b0;
        case (rstate)
            R_IDLE: if (s_axi_arvalid) rstate_n = R_IP;
            R_IP: begin
                ip_arvalid = 1'b1;
                if (ip_rvalid) rstate_n = R_RESP;
            end
            R_RESP: if (s_axi_rready) rstate_n = R_IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // Instantiate axi_uart_top (quirky side, held valids)
    // ------------------------------------------------------------------
    wire [IP_ID_W-1:0] ip_awid = {{(IP_ID_W-AXI_ID_WIDTH){1'b0}}, w_id};
    wire [IP_ID_W-1:0] ip_arid = {{(IP_ID_W-AXI_ID_WIDTH){1'b0}}, r_id};

    axi_uart_top u_axi_uart (
        // clocks / reset
        .fixed_clk_i    (clk),
        .axi_aclk_i     (clk),
        .axi_aresetn_i  (rst_n),

        // write address channel
        .axi_awid_i     (ip_awid),
        .axi_awaddr_i   (w_addr),
        .axi_awvalid_i  (ip_awvalid),
        .axi_awready_o  (ip_awready),

        // write data channel
        .axi_wdata_i    (w_data),
        .axi_wstrb_i    (w_strb),
        .axi_wvalid_i   (ip_wvalid),
        .axi_wready_o   (ip_wready),

        // write response channel
        .axi_bid_o      (ip_bid),
        .axi_bresp_o    (ip_bresp),
        .axi_bvalid_o   (ip_bvalid),
        .axi_bready_i   (1'b1),

        // read address channel
        .axi_arid_i     (ip_arid),
        .axi_araddr_i   (r_addr),
        .axi_arvalid_i  (ip_arvalid),
        .axi_arready_o  (ip_arready),

        // read data channel
        .axi_rid_o      (ip_rid),
        .axi_rdata_o    (ip_rdata),
        .axi_rresp_o    (ip_rresp),
        .axi_rvalid_o   (ip_rvalid),
        .axi_rready_i   (1'b1),

        // UART physical
        .uart_rx_i      (uart_rx),
        .uart_tx_o      (uart_tx),

        // interrupt
        .read_interrupt_o (uart_irq)
    );

endmodule

`default_nettype wire
