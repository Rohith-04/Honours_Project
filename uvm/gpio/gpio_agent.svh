class gpio_agent extends uvm_agent;
  `uvm_component_utils(gpio_agent)
  gpio_config cfg;
  gpio_bus_sequencer bus_sequencer;
  gpio_pin_sequencer pin_sequencer;
  gpio_bus_driver bus_driver;
  gpio_pin_driver pin_driver;
  gpio_monitor monitor;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(gpio_config)::get(this, "", "cfg", cfg))
      `uvm_fatal("CONFIG", "gpio_agent requires cfg")
    if (cfg.axi_vif == null || cfg.pin_vif == null ||
        cfg.queue_depth == 0 || cfg.queue_depth > 64 || cfg.timeout_cycles == 0)
      `uvm_fatal("CONFIG", "Invalid GPIO virtual interfaces, queue depth, or timeout")
    is_active = cfg.is_active;
    uvm_config_db#(gpio_config)::set(this, "*", "cfg", cfg);
    monitor = gpio_monitor::type_id::create("monitor", this);
    if (is_active == UVM_ACTIVE) begin
      bus_sequencer = gpio_bus_sequencer::type_id::create("bus_sequencer", this);
      pin_sequencer = gpio_pin_sequencer::type_id::create("pin_sequencer", this);
      bus_driver = gpio_bus_driver::type_id::create("bus_driver", this);
      pin_driver = gpio_pin_driver::type_id::create("pin_driver", this);
    end
  endfunction
  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (is_active == UVM_ACTIVE) begin
      bus_driver.seq_item_port.connect(bus_sequencer.seq_item_export);
      pin_driver.seq_item_port.connect(pin_sequencer.seq_item_export);
    end
  endfunction
endclass

class gpio_env extends uvm_env;
  `uvm_component_utils(gpio_env)
  gpio_config cfg;
  gpio_agent agent;
  gpio_scoreboard scoreboard;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(gpio_config)::get(this, "", "cfg", cfg))
      `uvm_fatal("CONFIG", "gpio_env requires cfg")
    uvm_config_db#(gpio_config)::set(this, "agent", "cfg", cfg);
    agent = gpio_agent::type_id::create("agent", this);
    scoreboard = gpio_scoreboard::type_id::create("scoreboard", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    agent.monitor.samples.connect(scoreboard.samples);
  endfunction
endclass
