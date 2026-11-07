class gpio_plan_test extends gpio_smoke_test;
  `uvm_component_utils(gpio_plan_test)
  string plan_id;
  function new(string name, uvm_component parent);
    super.new(name, parent);
    use_pad_model = 1;
    // These tests check their plan checkpoints; legacy smoke requirements
    // (e.g. five illegal accesses) remain enforced by the legacy tests.
    require_smoke_coverage = 0;
  endfunction
  virtual function gpio_plan_sequence create_plan_sequence();
    `uvm_fatal("PLAN", "Select a concrete SOC-027/028/029 test")
    return null;
  endfunction
  task run_phase(uvm_phase phase);
    gpio_plan_sequence seq;
    phase.raise_objection(this);
    `uvm_info("PLAN", $sformatf("%s: starting standalone GPIO checkpoint test", plan_id), UVM_LOW)
    seq = create_plan_sequence();
    seq.pin_sequencer = env.agent.pin_sequencer;
    seq.axi = cfg.axi_vif;
    seq.start(env.agent.bus_sequencer);
    repeat (3) @(cfg.axi_vif.monitor_cb);
    phase.drop_objection(this);
  endtask
  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (env.scoreboard.pad_checks == 0)
      `uvm_error("PLAN", "No resolved-pad samples were checked")
    `uvm_info("PLAN", $sformatf("%s: pad_samples=%0d conflicting_pin_samples=%0d",
      plan_id, env.scoreboard.pad_checks, env.scoreboard.contention_samples), UVM_LOW)
  endfunction
endclass

class soc_gpio_out_test extends gpio_plan_test;
  `uvm_component_utils(soc_gpio_out_test)
  function new(string name, uvm_component parent);
    super.new(name, parent); plan_id = "SOC-027";
  endfunction
  virtual function gpio_plan_sequence create_plan_sequence();
    return soc_gpio_out_sequence::type_id::create("soc_gpio_out");
  endfunction
endclass

class soc_gpio_dir_test extends gpio_plan_test;
  `uvm_component_utils(soc_gpio_dir_test)
  function new(string name, uvm_component parent);
    super.new(name, parent); plan_id = "SOC-028";
  endfunction
  virtual function gpio_plan_sequence create_plan_sequence();
    return soc_gpio_dir_sequence::type_id::create("soc_gpio_dir");
  endfunction
  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (env.scoreboard.contention_samples == 0)
      `uvm_error("PLAN", "SOC-028 did not exercise conflicting pad drivers")
  endfunction
endclass

class soc_gpio_walking_test extends gpio_plan_test;
  `uvm_component_utils(soc_gpio_walking_test)
  function new(string name, uvm_component parent);
    super.new(name, parent); plan_id = "SOC-029";
  endfunction
  virtual function gpio_plan_sequence create_plan_sequence();
    return soc_gpio_walking_sequence::type_id::create("soc_gpio_walking");
  endfunction
  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (env.scoreboard.output_zero_seen !== {GPIO_WIDTH{1'b1}} ||
        env.scoreboard.output_one_seen !== {GPIO_WIDTH{1'b1}} ||
        env.scoreboard.input_zero_seen !== {GPIO_WIDTH{1'b1}} ||
        env.scoreboard.input_one_seen !== {GPIO_WIDTH{1'b1}})
      `uvm_error("PLAN", "SOC-029 did not observe both values on every input/output pin")
  endfunction
endclass
