module tb_gpio_sw_uvm;
  timeunit 1ns; timeprecision 1ps;
  import uvm_pkg::*;
  import gpio_sw_pkg::*;
  `include "uvm_macros.svh"

  // Reuse the verified core/adapter/SoC wiring and UART/signature checkers.
  // Only UVM may end the run in EXTERNAL_COMPLETION mode.
  tb_soc_sw #(.EXTERNAL_COMPLETION(1)) system (
    .completion_done(status.done),
    .completion_pass(status.passed),
    .completion_uart_ok(status.uart_ok),
    .completion_signature(status.signature)
  );
  gpio_axi_if axi(system.clk, system.aresetn);
  gpio_pin_if pins(system.clk, system.aresetn);
  gpio_sw_status_if status(system.clk);

  // These are observation copies, not connections back into the DUT. Tap the
  // GPIO slave port so UART/RAM/software fetches never enter the GPIO model.
  // The reusable interface has initial values and clocking-block outputs for
  // active mode. A procedural observation copy does not claim always_comb's
  // exclusive-writer contract; the passive topology creates no active driver.
  always @* begin
    axi.awid = system.dut.u_gpio.s_axi_awid;
    axi.awaddr = system.dut.u_gpio.s_axi_awaddr;
    axi.awlen = system.dut.u_gpio.s_axi_awlen;
    axi.awsize = system.dut.u_gpio.s_axi_awsize;
    axi.awburst = system.dut.u_gpio.s_axi_awburst;
    axi.awvalid = system.dut.u_gpio.s_axi_awvalid;
    axi.awready = system.dut.u_gpio.s_axi_awready;
    axi.wdata = system.dut.u_gpio.s_axi_wdata;
    axi.wstrb = system.dut.u_gpio.s_axi_wstrb;
    axi.wvalid = system.dut.u_gpio.s_axi_wvalid;
    axi.wready = system.dut.u_gpio.s_axi_wready;
    axi.bid = system.dut.u_gpio.s_axi_bid;
    axi.bresp = system.dut.u_gpio.s_axi_bresp;
    axi.bvalid = system.dut.u_gpio.s_axi_bvalid;
    axi.bready = system.dut.u_gpio.s_axi_bready;
    axi.arid = system.dut.u_gpio.s_axi_arid;
    axi.araddr = system.dut.u_gpio.s_axi_araddr;
    axi.arlen = system.dut.u_gpio.s_axi_arlen;
    axi.arsize = system.dut.u_gpio.s_axi_arsize;
    axi.arburst = system.dut.u_gpio.s_axi_arburst;
    axi.arvalid = system.dut.u_gpio.s_axi_arvalid;
    axi.arready = system.dut.u_gpio.s_axi_arready;
    axi.rid = system.dut.u_gpio.s_axi_rid;
    axi.rdata = system.dut.u_gpio.s_axi_rdata;
    axi.rresp = system.dut.u_gpio.s_axi_rresp;
    axi.rvalid = system.dut.u_gpio.s_axi_rvalid;
    axi.rready = system.dut.u_gpio.s_axi_rready;
    pins.external_value = system.dut.u_gpio.gpio_in;
  end
  assign pins.gpio_out = system.dut.u_gpio.gpio_out;
  assign pins.output_enable = system.dut.u_gpio.dir_reg;
  assign status.ebreak_seen = system.saw_ebreak;
  assign status.pc = system.tr_pc;

  initial begin
    uvm_config_db#(virtual gpio_axi_if)::set(null, "uvm_test_top", "axi_vif", axi);
    uvm_config_db#(virtual gpio_pin_if)::set(null, "uvm_test_top", "pin_vif", pins);
    uvm_config_db#(virtual gpio_sw_status_if)::set(null, "uvm_test_top", "status_vif", status);
    run_test();
  end
`ifdef FSDB_DUMP
  initial begin
    $fsdbDumpfile("tb_gpio_sw_uvm.fsdb");
    $fsdbDumpvars(0, tb_gpio_sw_uvm);
  end
`endif
endmodule
