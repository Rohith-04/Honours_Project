class gpio_smoke_test extends uvm_test;
  `uvm_component_utils(gpio_smoke_test)
  gpio_config cfg;
  gpio_env env;
  bit run_pipeline, use_factory_override;
  bit use_pad_model;
  bit require_smoke_coverage = 1;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = gpio_config::type_id::create("cfg");
    // HDL publishes typed virtual interfaces once; the test owns policy,
    // then the env/agent pass one configuration object to their children.
    if (!uvm_config_db#(virtual gpio_axi_if)::get(this, "", "axi_vif", cfg.axi_vif))
      `uvm_fatal("CONFIG", "Missing gpio_axi_if")
    if (!uvm_config_db#(virtual gpio_pin_if)::get(this, "", "pin_vif", cfg.pin_vif))
      `uvm_fatal("CONFIG", "Missing gpio_pin_if")
    cfg.pin_vif.pad_mode = use_pad_model;
    void'(uvm_config_db#(int unsigned)::get(this, "", "queue_depth", cfg.queue_depth));
    uvm_config_db#(gpio_config)::set(this, "env", "cfg", cfg);
    env = gpio_env::type_id::create("env", this);
  endfunction
  function void end_of_elaboration_phase(uvm_phase phase);
    super.end_of_elaboration_phase(phase);
    uvm_top.print_topology();
  endfunction

  task run_phase(uvm_phase phase);
    gpio_smoke_sequence smoke;
    gpio_pipeline_sequence pipeline_seq;
    gpio_input_sequence inputs;
    phase.raise_objection(this);
    inputs = gpio_input_sequence::type_id::create("inputs");
    smoke = gpio_smoke_sequence::type_id::create("smoke");
    smoke.require_override = use_factory_override;
    fork
      inputs.start(env.agent.pin_sequencer);
      smoke.start(env.agent.bus_sequencer);
    join
    if (run_pipeline) begin
      pipeline_seq = gpio_pipeline_sequence::type_id::create("pipeline_seq");
      pipeline_seq.require_override = use_factory_override;
      inputs = gpio_input_sequence::type_id::create("pipeline_inputs");
      fork
        inputs.start(env.agent.pin_sequencer);
        pipeline_seq.start(env.agent.bus_sequencer);
      join
    end
    // Both stimulus sequences are drained. Read IN through a final sequence
    // and check the stable external value independently of the scoreboard.
    begin
      gpio_final_input_sequence final_seq;
      final_seq = gpio_final_input_sequence::type_id::create("final_seq");
      final_seq.require_override = use_factory_override;
      final_seq.start(env.agent.bus_sequencer);
    end
    repeat (3) @(cfg.axi_vif.monitor_cb);
    phase.drop_objection(this);
  endtask

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (env.agent.bus_driver.accepted != env.agent.bus_driver.completed ||
        env.agent.bus_driver.completed != env.scoreboard.reads + env.scoreboard.writes)
      `uvm_error("DRAIN", "Driver/monitor completion counts disagree")
    if (require_smoke_coverage && (env.scoreboard.error_responses < 5 || env.scoreboard.zero_strobes == 0 ||
        env.scoreboard.ignored_upper_strobes == 0 ||
        env.scoreboard.b_stalls == 0 || env.scoreboard.r_stalls == 0))
      `uvm_error("COVERAGE", "Required GPIO errors/strobes/backpressure were not exercised")
    if (run_pipeline && (env.agent.bus_driver.peak_inflight < 2 ||
        env.scoreboard.read_write_overlap == 0 || env.scoreboard.aw_stalls == 0 ||
        env.scoreboard.w_stalls == 0 || env.scoreboard.ar_stalls == 0))
      `uvm_error("PIPELINE", "Required request queueing/channel overlap/stalls were not exercised")
    `uvm_info("PIPELINE", $sformatf("accepted=%0d completed=%0d peak_inflight=%0d",
      env.agent.bus_driver.accepted, env.agent.bus_driver.completed,
      env.agent.bus_driver.peak_inflight), UVM_LOW)
  endfunction
  function void report_phase(uvm_phase phase);
    uvm_report_server server;
    server = uvm_report_server::get_server();
    if (server.get_severity_count(UVM_ERROR) == 0 &&
        server.get_severity_count(UVM_FATAL) == 0)
      $display("TEST %s: PASS (%0d checks)", get_type_name(), env.scoreboard.checks);
    else $display("TEST %s: FAIL", get_type_name());
  endfunction
endclass

class gpio_pipeline_test extends gpio_smoke_test;
  `uvm_component_utils(gpio_pipeline_test)
  function new(string name, uvm_component parent);
    super.new(name, parent); run_pipeline = 1;
  endfunction
endclass

class gpio_factory_test extends gpio_pipeline_test;
  `uvm_component_utils(gpio_factory_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    gpio_bus_item::type_id::set_type_override(gpio_backpressure_item::get_type());
    use_factory_override = 1;
    super.build_phase(phase);
    `uvm_info("FACTORY", "gpio_bus_item overridden with gpio_backpressure_item", UVM_LOW)
  endfunction
endclass
