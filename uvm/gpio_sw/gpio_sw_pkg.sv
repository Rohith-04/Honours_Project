package gpio_sw_pkg;
  timeunit 1ns; timeprecision 1ps;
  import uvm_pkg::*;
  import soc_pkg::*;
  import gpio_vip_pkg::*;
  `include "uvm_macros.svh"

  // A separate software test reuses the VIP's passive monitor/scoreboard.
  // No active test is inherited, and no sequence or driver is started here.
  class gpio_sw_test extends uvm_test;
    `uvm_component_utils(gpio_sw_test)
    gpio_config cfg;
    gpio_env env;
    virtual gpio_sw_status_if status;
    int unsigned completion_checks;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      cfg = gpio_config::type_id::create("cfg");
      cfg.is_active = UVM_PASSIVE;
      if (!uvm_config_db#(virtual gpio_axi_if)::get(this, "", "axi_vif", cfg.axi_vif) ||
          !uvm_config_db#(virtual gpio_pin_if)::get(this, "", "pin_vif", cfg.pin_vif) ||
          !uvm_config_db#(virtual gpio_sw_status_if)::get(this, "", "status_vif", status))
        `uvm_fatal("CONFIG", "Software GPIO test requires AXI, pin, and status observations")
      uvm_config_db#(gpio_config)::set(this, "env", "cfg", cfg);
      env = gpio_env::type_id::create("env", this);
    endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      if (env.agent.bus_driver != null || env.agent.bus_sequencer != null ||
          env.agent.pin_driver != null || env.agent.pin_sequencer != null)
        `uvm_fatal("OWNERSHIP", "Passive software environment must not create drivers/sequencers")
      uvm_top.print_topology();
    endfunction
    function void check_completion(string label, bit valid);
      completion_checks++;
      if (!valid) `uvm_error("SOFTWARE", label)
    endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      `uvm_info("SOFTWARE", "VeeR executes C; GPIO VIP only observes slave AXI and physical pins", UVM_LOW)
      fork
        begin
          wait (status.done === 1'b1);
        end
        begin
          repeat (5_000_000) @(posedge status.clk);
          `uvm_fatal("TIMEOUT", $sformatf("Software did not finish; PC=%08h", status.pc))
        end
      join_any
      disable fork;
      check_completion("software harness reported failure", status.passed === 1'b1);
      check_completion("missing GPIO OK UART tag or FAIL text observed", status.uart_ok === 1'b1);
      check_completion("missing software ebreak", status.ebreak_seen === 1'b1);
      check_completion("incorrect independent RAM signature", status.signature === 32'h50515353);
      repeat (3) @(cfg.axi_vif.monitor_cb);
      phase.drop_objection(this);
    endtask
    function void report_phase(uvm_phase phase);
      uvm_report_server server;
      server = uvm_report_server::get_server();
      `uvm_info("SOFTWARE_COUNTS", $sformatf("GPIO reads=%0d writes=%0d; completion checks=%0d",
        env.scoreboard.reads, env.scoreboard.writes, completion_checks), UVM_LOW)
      if (server.get_severity_count(UVM_ERROR) == 0 && server.get_severity_count(UVM_FATAL) == 0)
        $display("TEST %s: PASS (%0d checks)", get_type_name(), env.scoreboard.checks + completion_checks);
      else $display("TEST %s: FAIL", get_type_name());
    endfunction
  endclass
endpackage
