module tb_gpio_uvm;
  timeunit 1ns; timeprecision 1ps;
  import uvm_pkg::*;
  import gpio_vip_pkg::*;
  `include "uvm_macros.svh"
  bit clk = 0;
  bit aresetn = 0;
  always #5ns clk = ~clk;
  gpio_axi_if axi(clk, aresetn);
  gpio_pin_if pins(clk, aresetn);

  gpio_wrapper #(
    .ID_WIDTH(soc_pkg::AXI_ID_WIDTH),
    .ADDR_WIDTH(soc_pkg::AXI_ADDR_WIDTH),
    .WIDTH(soc_pkg::GPIO_WIDTH)
  ) dut (
    .clk(clk), .aresetn(aresetn),
    .s_axi_awid(axi.awid), .s_axi_awaddr(axi.awaddr),
    .s_axi_awlen(axi.awlen), .s_axi_awsize(axi.awsize), .s_axi_awburst(axi.awburst),
    .s_axi_awvalid(axi.awvalid), .s_axi_awready(axi.awready),
    .s_axi_wdata(axi.wdata), .s_axi_wstrb(axi.wstrb),
    .s_axi_wvalid(axi.wvalid), .s_axi_wready(axi.wready),
    .s_axi_bid(axi.bid), .s_axi_bresp(axi.bresp),
    .s_axi_bvalid(axi.bvalid), .s_axi_bready(axi.bready),
    .s_axi_arid(axi.arid), .s_axi_araddr(axi.araddr),
    .s_axi_arlen(axi.arlen), .s_axi_arsize(axi.arsize), .s_axi_arburst(axi.arburst),
    .s_axi_arvalid(axi.arvalid), .s_axi_arready(axi.arready),
    .s_axi_rid(axi.rid), .s_axi_rdata(axi.rdata), .s_axi_rresp(axi.rresp),
    .s_axi_rvalid(axi.rvalid), .s_axi_rready(axi.rready),
    .gpio_in(pins.gpio_in), .gpio_out(pins.gpio_out)
  );

  // The RTL exports split input/output signals but no OE signal. Keep this
  // verification-only probe explicit; the scoreboard independently checks
  // the probe against bus-programmed DIR. No design interface is changed.
  assign pins.output_enable = dut.dir_reg;

  // Sampled checks can miss a pulse between clocks. Track output changes at
  // simulator event resolution: only bits affected by an accepted OUT/DIR
  // write may change, and each may transition at most once on that edge.
  logic [31:0] observed_awaddr;
  logic [soc_pkg::GPIO_WIDTH-1:0] allowed_changes, changed_this_edge, previous_output;
  realtime update_edge = -1;
  always @(posedge clk) begin
    update_edge = $realtime;
    allowed_changes = '0;
    changed_this_edge = '0;
    if (aresetn) begin
      if (axi.awvalid && axi.awready) observed_awaddr = axi.awaddr;
      if (axi.wvalid && axi.wready && axi.wstrb[0]) begin
        case (observed_awaddr[11:0])
          soc_pkg::GPIO_OUT: allowed_changes = pins.output_enable;
          soc_pkg::GPIO_DIR: allowed_changes = pins.output_enable ^ axi.wdata[soc_pkg::GPIO_WIDTH-1:0];
          default: allowed_changes = '0;
        endcase
      end
    end
  end
  always @(pins.gpio_out or negedge aresetn) begin : check_output_events
    logic [soc_pkg::GPIO_WIDTH-1:0] changed;
    for (int i = 0; i < soc_pkg::GPIO_WIDTH; i++)
      changed[i] = (pins.gpio_out[i] !== previous_output[i]);
    if (aresetn && changed != 0) begin
      if ($realtime != update_edge || |(changed & ~allowed_changes) ||
          |(changed & changed_this_edge))
        `uvm_error("GPIO_GLITCH", "Unexpected output transition or disturbance of unchanged pins")
      changed_this_edge |= changed;
    end
    previous_output = pins.gpio_out;
  end

  // Negative checker test only: a pulse entirely between clock samples must
  // still fail. No RTL source is patched and ordinary runs never force pins.
  bit injected_value;
  initial if ($test$plusargs("GPIO_INJECT_GLITCH")) begin
    wait (aresetn);
    repeat (20) @(negedge clk);
    #2ns;
    injected_value = ~pins.gpio_out[0];
    force pins.gpio_out[0] = injected_value;
    #1ns;
    release pins.gpio_out[0];
  end

  initial begin
    // Reset changes on a falling edge; every clocking block sees a complete
    // initial reset interval before any driver begins accepting requests.
    repeat (10) @(negedge clk);
    aresetn = 1;
  end
  initial begin
    int unsigned queue_depth;
    uvm_config_db#(virtual gpio_axi_if)::set(null, "uvm_test_top", "axi_vif", axi);
    uvm_config_db#(virtual gpio_pin_if)::set(null, "uvm_test_top", "pin_vif", pins);
    if ($value$plusargs("GPIO_QUEUE_DEPTH=%d", queue_depth))
      uvm_config_db#(int unsigned)::set(null, "uvm_test_top", "queue_depth", queue_depth);
    run_test();
  end
  initial begin
    repeat (100_000) @(posedge clk);
    `uvm_fatal("TIMEOUT", "GPIO UVM global watchdog expired")
  end
`ifdef FSDB_DUMP
  initial begin
    $fsdbDumpfile("tb_gpio_uvm.fsdb");
    $fsdbDumpvars(0, tb_gpio_uvm);
  end
`endif
endmodule
