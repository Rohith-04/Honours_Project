class gpio_bus_driver extends uvm_driver #(gpio_bus_item);
  `uvm_component_utils(gpio_bus_driver)
  gpio_config cfg;
  virtual gpio_axi_if vif;
  mailbox #(gpio_bus_item) aw_queue, w_queue, b_queue, ar_queue, r_queue;
  semaphore slots;
  int unsigned accepted, completed, peak_inflight;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(gpio_config)::get(this, "", "cfg", cfg))
      `uvm_fatal("CONFIG", "gpio_bus_driver requires cfg")
    vif = cfg.axi_vif;
    aw_queue = new(); w_queue = new(); b_queue = new();
    ar_queue = new(); r_queue = new(); slots = new(cfg.queue_depth);
  endfunction

  task run_phase(uvm_phase phase);
    vif.driver_cb.awvalid <= 0; vif.driver_cb.wvalid <= 0;
    vif.driver_cb.arvalid <= 0; vif.driver_cb.bready <= 0; vif.driver_cb.rready <= 0;
    vif.driver_cb.awid <= 0; vif.driver_cb.awaddr <= 0;
    vif.driver_cb.awlen <= 0; vif.driver_cb.awsize <= 2; vif.driver_cb.awburst <= 1;
    vif.driver_cb.wdata <= 0; vif.driver_cb.wstrb <= 0;
    vif.driver_cb.arid <= 0; vif.driver_cb.araddr <= 0;
    vif.driver_cb.arlen <= 0; vif.driver_cb.arsize <= 2; vif.driver_cb.arburst <= 1;
    do @(vif.driver_cb); while (vif.driver_cb.aresetn !== 1'b1);
    fork
      collect_requests(); drive_aw(); drive_w(); receive_b(); drive_ar(); receive_r();
      begin
        // Initial reset is supported. Fail explicitly on later resets rather
        // than silently losing sequence responses and leaking queue slots.
        @(negedge vif.aresetn);
        `uvm_fatal("RESET", "Mid-run reset cancellation is not supported by this GPIO VIP")
      end
    join
  endtask

  task collect_requests();
    gpio_bus_item req, owned;
    forever begin
      slots.get(1);
      seq_item_port.get_next_item(req);
      // item_done releases the sequence's object for reuse. Own a deep copy
      // first, and preserve sequence/transaction IDs for asynchronous replies.
      if (!$cast(owned, req.clone())) `uvm_fatal("COPY", "Request clone failed")
      owned.set_id_info(req);
      `uvm_info("GPIO_REQUEST", owned.convert2string(), UVM_HIGH)
      accepted++;
      if (accepted - completed > peak_inflight) peak_inflight = accepted - completed;
      if (owned.write) begin
        aw_queue.put(owned); w_queue.put(owned); b_queue.put(owned);
      end else begin
        ar_queue.put(owned); r_queue.put(owned);
      end
      seq_item_port.item_done();
    end
  endtask

  task drive_aw();
    gpio_bus_item req;
    int cycles;
    forever begin
      aw_queue.get(req);
      repeat (req.aw_delay) @(vif.driver_cb);
      vif.driver_cb.awid <= req.id; vif.driver_cb.awaddr <= req.addr;
      vif.driver_cb.awvalid <= 1;
      cycles = 0;
      do begin
        @(vif.driver_cb);
        if (++cycles > cfg.timeout_cycles) `uvm_fatal("TIMEOUT", "AW handshake stalled")
      end while (vif.driver_cb.awready !== 1'b1);
      vif.driver_cb.awvalid <= 0;
    end
  endtask

  task drive_w();
    gpio_bus_item req;
    int cycles;
    forever begin
      w_queue.get(req);
      repeat (req.w_delay) @(vif.driver_cb);
      vif.driver_cb.wdata <= req.data; vif.driver_cb.wstrb <= req.strb;
      vif.driver_cb.wvalid <= 1;
      cycles = 0;
      do begin
        @(vif.driver_cb);
        if (++cycles > cfg.timeout_cycles) `uvm_fatal("TIMEOUT", "W handshake stalled")
      end while (vif.driver_cb.wready !== 1'b1);
      vif.driver_cb.wvalid <= 0;
    end
  endtask

  task drive_ar();
    gpio_bus_item req;
    int cycles;
    forever begin
      ar_queue.get(req);
      repeat (req.ar_delay) @(vif.driver_cb);
      vif.driver_cb.arid <= req.id; vif.driver_cb.araddr <= req.addr;
      vif.driver_cb.arvalid <= 1;
      cycles = 0;
      do begin
        @(vif.driver_cb);
        if (++cycles > cfg.timeout_cycles) `uvm_fatal("TIMEOUT", "AR handshake stalled")
      end while (vif.driver_cb.arready !== 1'b1);
      vif.driver_cb.arvalid <= 0;
    end
  endtask

  task receive_b();
    gpio_bus_item req, rsp;
    int cycles;
    forever begin
      b_queue.get(req);
      // Wait for VALID with READY low, then introduce a deliberate stall.
      // Holding READY low before VALID alone does not prove backpressure.
      cycles = 0;
      do begin
        @(vif.driver_cb);
        if (++cycles > cfg.timeout_cycles) `uvm_fatal("TIMEOUT", "B response missing")
      end while (vif.driver_cb.bvalid !== 1'b1);
      repeat (req.response_delay) @(vif.driver_cb);
      vif.driver_cb.bready <= 1;
      @(vif.driver_cb);
      if (vif.driver_cb.bvalid !== 1'b1 || vif.driver_cb.bid !== req.id)
        `uvm_error("RESPONSE", "B VALID/ID does not match queued request")
      if (!$cast(rsp, req.clone())) `uvm_fatal("COPY", "Response clone failed")
      rsp.set_id_info(req); rsp.response = vif.driver_cb.bresp;
      `uvm_info("GPIO_RESPONSE", rsp.convert2string(), UVM_HIGH)
      vif.driver_cb.bready <= 0;
      completed++; slots.put(1); seq_item_port.put_response(rsp);
    end
  endtask

  task receive_r();
    gpio_bus_item req, rsp;
    int cycles;
    forever begin
      r_queue.get(req);
      cycles = 0;
      do begin
        @(vif.driver_cb);
        if (++cycles > cfg.timeout_cycles) `uvm_fatal("TIMEOUT", "R response missing")
      end while (vif.driver_cb.rvalid !== 1'b1);
      repeat (req.response_delay) @(vif.driver_cb);
      vif.driver_cb.rready <= 1;
      @(vif.driver_cb);
      if (vif.driver_cb.rvalid !== 1'b1 || vif.driver_cb.rid !== req.id)
        `uvm_error("RESPONSE", "R VALID/ID does not match queued request")
      if (!$cast(rsp, req.clone())) `uvm_fatal("COPY", "Response clone failed")
      rsp.set_id_info(req); rsp.response = vif.driver_cb.rresp;
      rsp.read_data = vif.driver_cb.rdata;
      `uvm_info("GPIO_RESPONSE", rsp.convert2string(), UVM_HIGH)
      vif.driver_cb.rready <= 0;
      completed++; slots.put(1); seq_item_port.put_response(rsp);
    end
  endtask
endclass

class gpio_pin_driver extends uvm_driver #(gpio_pin_item);
  `uvm_component_utils(gpio_pin_driver)
  gpio_config cfg;
  virtual gpio_pin_if vif;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(gpio_config)::get(this, "", "cfg", cfg))
      `uvm_fatal("CONFIG", "gpio_pin_driver requires cfg")
    vif = cfg.pin_vif;
  endfunction
  task run_phase(uvm_phase phase);
    gpio_pin_item req;
    vif.driver_cb.external_value <= '0;
    vif.driver_cb.external_enable <= '1;
    do @(vif.driver_cb); while (vif.driver_cb.aresetn !== 1'b1);
    forever begin
      seq_item_port.get_next_item(req);
      if (req.hold_cycles == 0) `uvm_fatal("PIN", "hold_cycles must be positive")
      vif.driver_cb.external_value <= req.value;
      vif.driver_cb.external_enable <= req.enable;
      repeat (req.hold_cycles) @(vif.driver_cb);
      seq_item_port.item_done();
    end
  endtask
endclass
