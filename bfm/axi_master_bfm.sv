// =============================================================================
// axi_master_bfm.sv — Reusable AXI4 master BFM (mimics the SoC master port)
//
// 32-bit data / 32-bit addr / 12-bit ID, single-beat transactions only
// (awlen/arlen == 0, size = 4 bytes, INCR). This is the ONLY sanctioned way
// for a test to touch the bus: tb_tasks.svh helpers bottom out in
// bfm.write / bfm.read. Never poke AXI signals directly; if the BFM can't
// express a scenario, extend the BFM — don't bypass it.
//
// Usage: instantiate in the TB, wire signals to the DUT slave port, pass
// the handle to tb_tasks helpers as `virtual axi_master_bfm`.
// Any handshake stall longer than TIMEOUT cycles ends the sim (fail loud,
// never hang).
// =============================================================================

`resetall
`timescale 1ns / 1ps

interface axi_master_bfm #(
  parameter int unsigned ID_WIDTH   = 12,
  parameter int unsigned ADDR_WIDTH = 32
)(
  input logic clk,
  input logic aresetn
);

  localparam int TIMEOUT = 10000;

  // AW channel (master -> slave outputs, slave -> master inputs)
  logic [ID_WIDTH-1:0]   awid;
  logic [ADDR_WIDTH-1:0] awaddr;
  logic [7:0]            awlen;
  logic [2:0]            awsize;
  logic [1:0]            awburst;
  logic                  awvalid;
  logic                  awready;
  // W channel
  logic [31:0]           wdata;
  logic [3:0]            wstrb;
  logic                  wlast;
  logic                  wvalid;
  logic                  wready;
  // B channel
  logic [ID_WIDTH-1:0]   bid;
  logic [1:0]            bresp;
  logic                  bvalid;
  logic                  bready;
  // AR channel
  logic [ID_WIDTH-1:0]   arid;
  logic [ADDR_WIDTH-1:0] araddr;
  logic [7:0]            arlen;
  logic [2:0]            arsize;
  logic [1:0]            arburst;
  logic                  arvalid;
  logic                  arready;
  // R channel
  logic [ID_WIDTH-1:0]   rid;
  logic [31:0]           rdata;
  logic [1:0]            rresp;
  logic                  rlast;
  logic                  rvalid;
  logic                  rready;

  task automatic timeout_finish(input string where);
    $display("[BFM TIMEOUT] no handshake on %s within %0d cycles — FAIL", where, TIMEOUT);
    $fatal(1, "AXI BFM timeout");
  endtask

  // Idle the master outputs. Call once after reset, before any transfer.
  task automatic reset_master();
    awid    = '0; awaddr = '0; awlen = '0; awsize = '0; awburst = '0;
    awvalid = 1'b0;
    wdata   = '0; wstrb = '0; wlast = 1'b0; wvalid = 1'b0;
    bready  = 1'b1;
    arid    = '0; araddr = '0; arlen = '0; arsize = '0; arburst = '0;
    arvalid = 1'b0;
    rready  = 1'b1;
  endtask

  // Single 32-bit write. strb is the AXI wstrb (4'hF = full word).
  //
  // IMPORTANT (learned from ips/uart): the UART IP's write FSM keys off
  // awvalid & wvalid TOGETHER, so AW and W are asserted simultaneously and
  // HELD until bvalid appears, then dropped in the same cycle (NBA).
  // Holding longer re-triggers the slave (double-push of THR); dropping
  // early loses the response. This overlapped discipline is legal AXI and
  // works with every slave in this SoC.
  task automatic write(
    input logic [31:0] addr,
    input logic [31:0] data,
    input logic [3:0]  strb,
    output logic [1:0] resp
  );
    int t;
    awid    <= '0;
    awaddr  <= addr;
    awlen   <= 8'd0;
    awsize  <= 3'b010;
    awburst <= 2'b01;
    awvalid <= 1'b1;
    wdata   <= data;
    wstrb   <= strb;
    wlast   <= 1'b1;
    wvalid  <= 1'b1;
    t = 0;
    while (bvalid !== 1'b1) begin
      @(posedge clk);
      t++;
      if (t > TIMEOUT) timeout_finish("B");
    end
    resp = bresp;
    awvalid <= 1'b0;
    wvalid  <= 1'b0;
    wlast   <= 1'b0;
    // Trailing wait: never start the next transfer on a stale bvalid.
    t = 0;
    while (bvalid === 1'b1) begin
      @(posedge clk);
      t++;
      if (t > TIMEOUT) timeout_finish("B-idle");
    end
  endtask

  // Single 32-bit read. AR held until rvalid, dropped the same cycle
  // (an RBR read double-pulls the RX FIFO if held longer).
  task automatic read(
    input logic [31:0]  addr,
    output logic [31:0] data,
    output logic [1:0]  resp
  );
    int t;
    arid    <= '0;
    araddr  <= addr;
    arlen   <= 8'd0;
    arsize  <= 3'b010;
    arburst <= 2'b01;
    arvalid <= 1'b1;
    t = 0;
    while (rvalid !== 1'b1) begin
      @(posedge clk);
      t++;
      if (t > TIMEOUT) timeout_finish("R");
    end
    data = rdata;
    resp = rresp;
    arvalid <= 1'b0;
    t = 0;
    while (rvalid === 1'b1) begin
      @(posedge clk);
      t++;
      if (t > TIMEOUT) timeout_finish("R-idle");
    end
  endtask

  // INCR burst write, word-sized beats, full strobes. data.size() = beats.
  // PHASED discipline (AW first, then W stream): RAM-only. The UART IP
  // needs overlapped AW+W and does not support bursts, so burst tasks
  // must never target it. Legal AXI; works through the interconnect.
  task automatic write_burst(
    input logic [31:0] addr,
    input logic [31:0] data [],
    output logic [1:0] resp
  );
    int t, i, n;
    n = data.size();
    if (n < 1 || n > 256) begin
      resp = 2'b10;
      return;
    end
    // --- address phase ---
    awid    <= '0;
    awaddr  <= addr;
    awlen   <= n[7:0] - 8'd1;
    awsize  <= 3'b010;
    awburst <= 2'b01;
    awvalid <= 1'b1;
    // Mandatory: hold the request visible for >=1 edge BEFORE sampling
    // ready. If the slave is already ready (RAM ties awready high), a
    // bare while-check would exit in the same timestep and the AW pulse
    // would never appear at any clock edge (zero-edge hazard).
    @(posedge clk);
    t = 0;
    while (awready !== 1'b1) begin
      @(posedge clk);
      t++;
      if (t > TIMEOUT) timeout_finish("AW-burst");
    end
    awvalid <= 1'b0;
    // --- data phase: one beat per accepted cycle ---
    wdata  <= data[0];
    wstrb  <= 4'hF;
    wlast  <= (n == 1);
    wvalid <= 1'b1;
    i = 0;
    t = 0;
    while (i < n) begin
      @(posedge clk);
      t++;
      if (t > TIMEOUT) timeout_finish("W-burst");
      if (wready === 1'b1) begin
        i++;
        if (i < n) begin
          wdata <= data[i];
          wlast <= (i == n - 1);
        end
      end
    end
    wvalid <= 1'b0;
    wlast  <= 1'b0;
    // --- response phase ---
    t = 0;
    while (bvalid !== 1'b1) begin
      @(posedge clk);
      t++;
      if (t > TIMEOUT) timeout_finish("B-burst");
    end
    resp = bresp;
    t = 0;
    while (bvalid === 1'b1) begin
      @(posedge clk);
      t++;
      if (t > TIMEOUT) timeout_finish("B-burst-idle");
    end
  endtask

  // INCR burst read, word-sized beats. Caller sizes data[] to the
  // expected beat count. resp accumulates any error beat. RAM-only
  // (phased AR, same rationale as write_burst).
  // NOTE: data[] is `inout`, not `output`. An `output` dynamic array
  // arrives EMPTY inside the task (copy-out-only semantics), so size()
  // reads 0 and the task would instantly return SLVERR with no bus
  // activity. `inout` gives copy-in/copy-out: size in, contents back.
  task automatic read_burst(
    input logic [31:0]  addr,
    inout logic [31:0]  data [],
    output logic [1:0]  resp
  );
    int t, i, n;
    n = data.size();
    resp = 2'b00;
    if (n < 1 || n > 256) begin
      resp = 2'b10;
      return;
    end
    arid    <= '0;
    araddr  <= addr;
    arlen   <= n[7:0] - 8'd1;
    arsize  <= 3'b010;
    arburst <= 2'b01;
    arvalid <= 1'b1;
    // Same zero-edge hazard guard as the AW phase above: the request must
    // be visible for >=1 edge before sampling ready.
    @(posedge clk);
    t = 0;
    while (arready !== 1'b1) begin
      @(posedge clk);
      t++;
      if (t > TIMEOUT) timeout_finish("AR-burst");
    end
    arvalid <= 1'b0;
    i = 0;
    t = 0;
    while (i < n) begin
      @(posedge clk);
      t++;
      if (t > TIMEOUT) timeout_finish("R-burst");
      if (rvalid === 1'b1) begin
        assert (rlast === (i == n - 1)) else $fatal(1, "Burst RLAST mismatch");
        data[i] = rdata;
        if (rresp !== 2'b00) resp = rresp;
        i++;
      end
    end
    t = 0;
    while (rvalid === 1'b1) begin
      @(posedge clk);
      t++;
      if (t > TIMEOUT) timeout_finish("R-burst-idle");
    end
  endtask

  // Protocol-directed transaction: AW completes before delayed W; B stalls.
  task automatic write_delayed(input logic [31:0] addr, data,
                                input logic [ID_WIDTH-1:0] id,
                                output logic [1:0] resp);
    int t;
    bready <= 0;
    awid <= id; awaddr <= addr; awlen <= 0; awsize <= 2;
    awburst <= 1; awvalid <= 1;
    @(posedge clk);
    t = 0;
    while (!awready) begin
      @(posedge clk);
      if (t++ > TIMEOUT) timeout_finish("delayed-AW");
    end
    awvalid <= 0;
    repeat (7) @(negedge clk);
    wdata <= data; wstrb <= 15; wlast <= 1; wvalid <= 1;
    @(posedge clk);
    t = 0;
    while (!wready) begin
      @(posedge clk);
      if (t++ > TIMEOUT) timeout_finish("delayed-W");
    end
    wvalid <= 0; wlast <= 0;
    t = 0;
    while (!bvalid) begin
      @(negedge clk);
      if (t++ > TIMEOUT) timeout_finish("stalled-B");
    end
    resp = bresp;
    repeat (5) begin
      @(negedge clk);
      assert (bvalid && bid == id && bresp == resp)
        else $fatal(1, "B response changed under backpressure");
    end
    bready <= 1;
    @(posedge clk); @(negedge clk);
  endtask

  task automatic read_stalled(input logic [31:0] addr,
                               input logic [ID_WIDTH-1:0] id,
                               output logic [31:0] data,
                               output logic [1:0] resp);
    int t;
    rready <= 0;
    arid <= id; araddr <= addr; arlen <= 0; arsize <= 2;
    arburst <= 1; arvalid <= 1;
    @(posedge clk);
    t = 0;
    while (!arready) begin
      @(posedge clk);
      if (t++ > TIMEOUT) timeout_finish("stalled-AR");
    end
    arvalid <= 0;
    t = 0;
    while (!rvalid) begin
      @(negedge clk);
      if (t++ > TIMEOUT) timeout_finish("stalled-R");
    end
    data = rdata; resp = rresp;
    repeat (5) begin
      @(negedge clk);
      assert (rvalid && rlast && rid == id && rdata == data && rresp == resp)
        else $fatal(1, "R response changed under backpressure");
    end
    rready <= 1;
    @(posedge clk); @(negedge clk);
  endtask

endinterface

`resetall
