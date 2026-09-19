// =============================================================================
// axi_true_mem.sv — Minimal AXI4 RAM for SoC bring-up + SW tests
//
// Superset of axi_stub_mem: same always-ready single outstanding behavior,
// but with real storage, byte-strobe writes, INCR burst support, and
// optional $readmemh preload via +SW_HEX=<path>.
//
// Without +SW_HEX the array is NOP-filled (RV addi x0,x0,0) so VeeR boot
// fetches spin harmlessly — identical to the stub for mid/top bring-up.
//
// Params:
//   MEM_BYTES — byte size (default 131072 = 128 KB @ 0x0000_0000)
//   NOP       — idle fill word (little-endian bytes)
//   objcopy emits 1 byte/entry (`-O verilog` default), so storage is a
//   byte array: $readmemh maps 1 token -> 1 byte. Words assemble LE.
//
// Addressing: byte index = s_addr mod MEM_BYTES (mirror in 16 MB window).
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module axi_true_mem #(
    parameter int unsigned MEM_BYTES = 131072,         // 128 KB
    parameter logic [31:0] NOP       = 32'h0000_0013   // RV NOP
) (
    input  logic        clk,
    input  logic        rst,          // active-high (matches xbar rst)

    // Write address
    input  logic [7:0]  s_awid,
    input  logic [31:0] s_awaddr,
    input  logic [7:0]  s_awlen,
    input  logic        s_awvalid,
    output logic        s_awready,
    // Write data
    input  logic [31:0] s_wdata,
    input  logic [3:0]  s_wstrb,
    input  logic        s_wlast,
    input  logic        s_wvalid,
    output logic        s_wready,
    // Write response
    output logic [7:0]  s_bid,
    output logic [1:0]  s_bresp,
    output logic        s_bvalid,
    input  logic        s_bready,
    // Read address
    input  logic [7:0]  s_arid,
    input  logic [31:0] s_araddr,
    input  logic [7:0]  s_arlen,
    input  logic        s_arvalid,
    output logic        s_arready,
    // Read data
    output logic [7:0]  s_rid,
    output logic [31:0] s_rdata,
    output logic [1:0]  s_rresp,
    output logic        s_rlast,
    output logic        s_rvalid,
    input  logic        s_rready
);

    // ------------------------------------------------------------------
    // Storage (byte array to match objcopy -O verilog byte hex)
    // ------------------------------------------------------------------
    logic [7:0] mem [0:MEM_BYTES-1];

    // NOP fill, then optional hex overlay (+SW_HEX=path, `objcopy -O verilog`)
    initial begin : preload
        string hex_path;
        integer i;
        for (i = 0; i < MEM_BYTES; i += 4) begin
            mem[i]   = NOP[7:0];
            mem[i+1] = NOP[15:8];
            mem[i+2] = NOP[23:16];
            mem[i+3] = NOP[31:24];
        end
        if ($value$plusargs("SW_HEX=%s", hex_path)) begin
            $display("[axi_true_mem] loading %s", hex_path);
            $readmemh(hex_path, mem);
        end else begin
            $display("[axi_true_mem] no +SW_HEX, NOP-filled (%0d bytes)", MEM_BYTES);
        end
    end

    // Byte index into the window (mirror above MEM_BYTES)
    function automatic int unsigned bidx(input logic [31:0] byte_addr);
        return byte_addr & (MEM_BYTES - 1);
    endfunction

    // Little-endian word fetch at byte address a (a must be word-aligned
    // for full words; unaligned reads assemble from consecutive bytes)
    function automatic logic [31:0] read_word(input logic [31:0] a);
        automatic int unsigned b = bidx(a);
        return {mem[b+3], mem[b+2], mem[b+1], mem[b]};
    endfunction

    // ------------------------------------------------------------------
    // Always-ready (no backpressure), like the stub
    // ------------------------------------------------------------------
    assign s_awready = 1'b1;
    assign s_wready  = 1'b1;
    assign s_arready = 1'b1;

    // ------------------------------------------------------------------
    // Write path: single outstanding, burst-aware via wlast
    // NOTE: plain `always` (not always_ff) so the initial NOP/$readmemh
    // preload may share the mem driver (VCS ICPD rule on always_ff).
    // ------------------------------------------------------------------
    logic        aw_active;
    logic [7:0]  aw_id;
    logic [31:0] aw_addr;
    logic        b_valid;

    always @(posedge clk) begin
        if (rst) begin
            aw_active <= 1'b0;
            aw_id     <= '0;
            aw_addr   <= '0;
            b_valid   <= 1'b0;
        end else begin
            // Latch address on AW handshake
            if (s_awvalid && s_awready) begin
                aw_active <= 1'b1;
                aw_id     <= s_awid;
                aw_addr   <= s_awaddr;
            end
            // Store data beats with strobes; complete on wlast
            if (aw_active && s_wvalid && s_wready) begin
                automatic int unsigned b = bidx(aw_addr);
                if (s_wstrb[0]) mem[b]   <= s_wdata[7:0];
                if (s_wstrb[1]) mem[b+1] <= s_wdata[15:8];
                if (s_wstrb[2]) mem[b+2] <= s_wdata[23:16];
                if (s_wstrb[3]) mem[b+3] <= s_wdata[31:24];
                aw_addr <= aw_addr + 32'd4;
                if (s_wlast) begin
                    aw_active <= 1'b0;
                    b_valid   <= 1'b1;
                end
            end
            if (b_valid && s_bready) b_valid <= 1'b0;
        end
    end

    assign s_bvalid = b_valid;
    assign s_bresp  = 2'b00;
    assign s_bid    = aw_id;

    // ------------------------------------------------------------------
    // Read path: burst-aware, one beat per cycle after AR
    // ------------------------------------------------------------------
    logic        ar_active;
    logic [7:0]  ar_id;
    logic [31:0] ar_addr;
    logic [7:0]  ar_left;   // beats remaining including current
    logic        r_valid;

    always @(posedge clk) begin
        if (rst) begin
            ar_active <= 1'b0;
            ar_id     <= '0;
            ar_addr   <= '0;
            ar_left   <= '0;
            r_valid   <= 1'b0;
        end else begin
            if (s_arvalid && s_arready) begin
                ar_active <= 1'b1;
                ar_id     <= s_arid;
                ar_addr   <= s_araddr;
                ar_left   <= s_arlen + 8'd1;  // arlen = beats-1
                r_valid   <= 1'b1;
            end else if (ar_active && r_valid && s_rready) begin
                ar_addr <= ar_addr + 32'd4;
                if (ar_left <= 8'd1) begin
                    ar_active <= 1'b0;
                    r_valid   <= 1'b0;
                end else begin
                    ar_left <= ar_left - 8'd1;
                end
            end
        end
    end

    assign s_rvalid = r_valid;
    assign s_rdata  = read_word(ar_addr);
    assign s_rresp  = 2'b00;
    assign s_rlast  = (ar_left <= 8'd1);
    assign s_rid    = ar_id;

endmodule

`default_nettype wire
