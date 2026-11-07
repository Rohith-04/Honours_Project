class gpio_monitor extends uvm_monitor;
  `uvm_component_utils(gpio_monitor)
  gpio_config cfg;
  virtual gpio_axi_if axi;
  virtual gpio_pin_if pins;
  uvm_analysis_port #(gpio_sample) samples;
  function new(string name, uvm_component parent);
    super.new(name, parent); samples = new("samples", this);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(gpio_config)::get(this, "", "cfg", cfg))
      `uvm_fatal("CONFIG", "gpio_monitor requires cfg")
    axi = cfg.axi_vif; pins = cfg.pin_vif;
  endfunction
  task run_phase(uvm_phase phase);
    gpio_sample sample;
    forever begin
      @(axi.monitor_cb);
      sample = gpio_sample::type_id::create("sample");
      sample.reset_n = axi.monitor_cb.aresetn;
      sample.awid = axi.monitor_cb.awid; sample.awaddr = axi.monitor_cb.awaddr;
      sample.awvalid = axi.monitor_cb.awvalid; sample.awready = axi.monitor_cb.awready;
      sample.wdata = axi.monitor_cb.wdata; sample.wstrb = axi.monitor_cb.wstrb;
      sample.wvalid = axi.monitor_cb.wvalid; sample.wready = axi.monitor_cb.wready;
      sample.bid = axi.monitor_cb.bid; sample.bresp = axi.monitor_cb.bresp;
      sample.bvalid = axi.monitor_cb.bvalid; sample.bready = axi.monitor_cb.bready;
      sample.arid = axi.monitor_cb.arid; sample.araddr = axi.monitor_cb.araddr;
      sample.arvalid = axi.monitor_cb.arvalid; sample.arready = axi.monitor_cb.arready;
      sample.rid = axi.monitor_cb.rid; sample.rdata = axi.monitor_cb.rdata;
      sample.rresp = axi.monitor_cb.rresp; sample.rvalid = axi.monitor_cb.rvalid;
      sample.rready = axi.monitor_cb.rready;
      sample.pins_in = pins.monitor_cb.gpio_in;
      sample.pins_out = pins.monitor_cb.gpio_out;
      sample.output_enable = pins.monitor_cb.output_enable;
      sample.pad = pins.monitor_cb.pad;
      sample.pad_mode = pins.monitor_cb.pad_mode;
      sample.external_value = pins.monitor_cb.external_value;
      sample.external_enable = pins.monitor_cb.external_enable;
      samples.write(sample);
    end
  endtask
endclass
