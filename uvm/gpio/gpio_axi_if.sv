// GPIO's supported AXI subset: one 32-bit INCR beat, independent channels.
// Clocking-block inputs sample before the active edge; outputs drive after it.
// This keeps UVM stimulus and checking away from the RTL's NBA updates.
interface gpio_axi_if(input logic clk, input logic aresetn);
  timeunit 1ns; timeprecision 1ps;
  logic [soc_pkg::AXI_ID_WIDTH-1:0] awid, bid, arid, rid;
  logic [31:0] awaddr, wdata, araddr, rdata;
  logic [7:0] awlen, arlen;
  logic [2:0] awsize, arsize;
  logic [1:0] awburst, arburst, bresp, rresp;
  logic [3:0] wstrb;
  logic awvalid = 0, wvalid = 0, arvalid = 0;
  logic bready = 0, rready = 0;
  logic awready, wready, bvalid, arready, rvalid;

  clocking driver_cb @(posedge clk);
    default input #1step output #0;
    input aresetn, awready, wready, bid, bresp, bvalid;
    input arready, rid, rdata, rresp, rvalid;
    output awid, awaddr, awlen, awsize, awburst, awvalid;
    output wdata, wstrb, wvalid, bready;
    output arid, araddr, arlen, arsize, arburst, arvalid, rready;
  endclocking

  clocking monitor_cb @(posedge clk);
    default input #1step;
    input aresetn, awid, awaddr, awlen, awsize, awburst, awvalid, awready;
    input wdata, wstrb, wvalid, wready, bid, bresp, bvalid, bready;
    input arid, araddr, arlen, arsize, arburst, arvalid, arready;
    input rid, rdata, rresp, rvalid, rready;
  endclocking

  // A stalled transfer must survive the following edge, including an edge
  // that accepts it. Checking only the payload would miss a dropped VALID.
  assert property (@(posedge clk) disable iff (!aresetn)
    awvalid && !awready |=> awvalid &&
    $stable({awid, awaddr, awlen, awsize, awburst}))
    else $error("GPIO VIP: AW changed while stalled");
  assert property (@(posedge clk) disable iff (!aresetn)
    wvalid && !wready |=> wvalid && $stable({wdata, wstrb}))
    else $error("GPIO VIP: W changed while stalled");
  assert property (@(posedge clk) disable iff (!aresetn)
    arvalid && !arready |=> arvalid &&
    $stable({arid, araddr, arlen, arsize, arburst}))
    else $error("GPIO VIP: AR changed while stalled");
  assert property (@(posedge clk) disable iff (!aresetn)
    bvalid && !bready |=> bvalid && $stable({bid, bresp}))
    else $error("GPIO VIP: B changed while stalled");
  assert property (@(posedge clk) disable iff (!aresetn)
    rvalid && !rready |=> rvalid && $stable({rid, rdata, rresp}))
    else $error("GPIO VIP: R changed while stalled");
endinterface
