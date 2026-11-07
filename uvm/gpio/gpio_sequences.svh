class gpio_base_sequence extends uvm_sequence #(gpio_bus_item);
  `uvm_object_utils(gpio_base_sequence)
  bit require_override;
  function new(string name = "gpio_base_sequence");
    super.new(name);
    // Pipeline sequences collect replies after issuing a batch. The driver's
    // admission semaphore bounds live requests; do not drop UVM replies at 8.
    set_response_queue_depth(-1);
  endfunction

  task issue(bit wr, bit [31:0] address, bit [31:0] value,
             bit [3:0] strobe, output int transaction_id,
             input int aw_wait = -1, int w_wait = -1, int ar_wait = -1);
    gpio_bus_item req;
    req = gpio_bus_item::type_id::create("req");
    if (require_override && req.get_type_name() != "gpio_backpressure_item")
      `uvm_fatal("FACTORY", "gpio_bus_item factory override was not applied")
    start_item(req);
    if (!req.randomize()) `uvm_fatal("RANDOMIZE", "GPIO request randomization failed")
    req.write = wr; req.addr = address; req.data = value; req.strb = strobe;
    if (aw_wait >= 0) req.aw_delay = aw_wait;
    if (w_wait >= 0) req.w_delay = w_wait;
    if (ar_wait >= 0) req.ar_delay = ar_wait;
    finish_item(req);
    transaction_id = req.get_transaction_id();
  endtask

  task receive(int transaction_id, bit [1:0] expected_response = 0,
               bit check_data = 0, logic [31:0] expected_data = 0);
    gpio_bus_item rsp;
    get_response(rsp, transaction_id);
    if (rsp.get_transaction_id() != transaction_id || rsp.response !== expected_response)
      `uvm_error("SEQUENCE", $sformatf("Reply id=%0d resp=%b; expected id=%0d resp=%b",
        rsp.get_transaction_id(), rsp.response, transaction_id, expected_response))
    if (check_data && rsp.read_data !== expected_data)
      `uvm_error("SEQUENCE", $sformatf("Read %08h returned %08h; expected %08h",
        rsp.addr, rsp.read_data, expected_data))
  endtask

  task access(bit wr, bit [31:0] address, bit [31:0] value = 0,
              bit [3:0] strobe = 15, bit [1:0] expected_response = 0,
              bit check_data = 0, logic [31:0] expected_data = 0);
    int id;
    issue(wr, address, value, strobe, id);
    receive(id, expected_response, check_data, expected_data);
  endtask
endclass

class gpio_smoke_sequence extends gpio_base_sequence;
  `uvm_object_utils(gpio_smoke_sequence)
  function new(string name = "gpio_smoke_sequence"); super.new(name); endfunction
  task body();
    access(0, GPIO_BASE + GPIO_OUT, 0, 15, 0, 1, 0);
    access(0, GPIO_BASE + GPIO_DIR, 0, 15, 0, 1, 0);
    access(1, GPIO_BASE + GPIO_DIR, 32'hff);
    access(1, GPIO_BASE + GPIO_OUT, 32'ha5);
    access(0, GPIO_BASE + GPIO_OUT, 0, 15, 0, 1, 32'ha5);
    access(0, GPIO_BASE + GPIO_DIR, 0, 15, 0, 1, 32'hff);
    // With eight implemented pins, only byte zero changes OUT or DIR.
    access(1, GPIO_BASE + GPIO_OUT, 0, 0);
    access(1, GPIO_BASE + GPIO_OUT, 0, 14);
    access(0, GPIO_BASE + GPIO_OUT, 0, 15, 0, 1, 32'ha5);
    access(1, GPIO_BASE + GPIO_OUT, 32'hdeadbe3c, 1);
    access(0, GPIO_BASE + GPIO_OUT, 0, 15, 0, 1, 32'h3c);
    access(1, GPIO_BASE + GPIO_DIR, 32'h0f);
    access(1, GPIO_BASE + GPIO_OUT, 32'hffffffff);
    access(0, GPIO_BASE + GPIO_OUT, 0, 15, 0, 1, 32'hff);
    for (int bit_index = 0; bit_index < GPIO_WIDTH; bit_index++) begin
      access(1, GPIO_BASE + GPIO_DIR, 32'(1 << bit_index));
      access(0, GPIO_BASE + GPIO_DIR, 0, 15, 0, 1, 32'(1 << bit_index));
    end
    access(1, GPIO_BASE + GPIO_DIR, 0);
    access(1, GPIO_BASE + GPIO_IN, 32'hff, 15, 2);
    access(1, GPIO_BASE + 12, 32'hff, 15, 2);
    access(1, GPIO_BASE + 1, 32'hff, 15, 2);
    access(0, GPIO_BASE + 12, 0, 15, 2, 1, 0);
    access(0, GPIO_BASE + 1, 0, 15, 2, 1, 0);
    // Bad writes must leave both writable registers unchanged.
    access(0, GPIO_BASE + GPIO_OUT, 0, 15, 0, 1, 32'hff);
    access(0, GPIO_BASE + GPIO_DIR, 0, 15, 0, 1, 0);
    access(0, GPIO_BASE + GPIO_IN);
  endtask
endclass

class gpio_pipeline_sequence extends gpio_base_sequence;
  `uvm_object_utils(gpio_pipeline_sequence)
  function new(string name = "gpio_pipeline_sequence"); super.new(name); endfunction
  task body();
    int ids[$];
    int id;
    access(1, GPIO_BASE + GPIO_DIR, 32'hff);
    // Do not wait for a bus response after finish_item. AW/W/AR and B/R
    // workers overlap, bounded by cfg.queue_depth. Read-only IN accesses
    // avoid imposing cross-channel read-after-write ordering that AXI lacks.
    for (int i = 0; i < 32; i++) begin
      // Adjacent requests of each direction also stress same-channel queues
      // at depth two. Strict read/write alternation could hide AR stalls.
      for (int lane = 0; lane < 2; lane++) begin
        issue(1, GPIO_BASE + GPIO_OUT, 32'((2*i + lane) ^ 8'ha5), 15, id,
              lane ? 0 : 4, lane ? 4 : 0);
        ids.push_back(id);
      end
      repeat (2) begin
        issue(0, GPIO_BASE + GPIO_IN, 0, 15, id, -1, -1, 0);
        ids.push_back(id);
      end
    end
    foreach (ids[i]) receive(ids[i]);
    access(0, GPIO_BASE + GPIO_OUT, 0, 15, 0, 1, 32'(63 ^ 8'ha5));
  endtask
endclass

class gpio_final_input_sequence extends gpio_base_sequence;
  `uvm_object_utils(gpio_final_input_sequence)
  function new(string name = "gpio_final_input_sequence"); super.new(name); endfunction
  task body();
    access(0, GPIO_BASE + GPIO_IN, 0, 15, 0, 1, 32'h3c);
  endtask
endclass

class gpio_input_sequence extends uvm_sequence #(gpio_pin_item);
  `uvm_object_utils(gpio_input_sequence)
  function new(string name = "gpio_input_sequence"); super.new(name); endfunction
  task body();
    gpio_pin_item req;
    for (int i = 0; i < 64; i++) begin
      req = gpio_pin_item::type_id::create("pins");
      start_item(req);
      if (!req.randomize()) `uvm_fatal("RANDOMIZE", "GPIO pins randomization failed")
      req.hold_cycles = 1 + i % 5;
      finish_item(req);
    end
    req = gpio_pin_item::type_id::create("final_pins");
    start_item(req); req.value = 8'h3c; req.hold_cycles = 5; finish_item(req);
  endtask
endclass
