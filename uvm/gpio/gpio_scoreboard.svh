class gpio_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(gpio_scoreboard)
  uvm_analysis_imp #(gpio_sample, gpio_scoreboard) samples;
  gpio_bus_item addresses[$], expected_b[$], expected_r[$];
  bit [GPIO_WIDTH-1:0] output_value, direction;
  // Contention is deliberately four-state. A bit reference would erase X.
  logic [GPIO_WIDTH-1:0] previous_input;
  int unsigned checks, reads, writes, error_responses, pin_checks;
  int unsigned aw_stalls, w_stalls, ar_stalls, b_stalls, r_stalls;
  int unsigned read_write_overlap, zero_strobes, ignored_upper_strobes;
  int unsigned pad_checks, contention_samples;
  bit [GPIO_WIDTH-1:0] output_zero_seen, output_one_seen;
  bit [GPIO_WIDTH-1:0] input_zero_seen, input_one_seen;
  bit saw_reset;

  // Coverage is sampled from accepted bus activity, never from sequence intent.
  covergroup accesses with function sample(bit wr, bit [11:0] offset,
                                            bit [3:0] strobe, bit error);
    option.per_instance = 1;
    operation: coverpoint wr;
    register_offset: coverpoint offset {
      bins out_reg = {0}; bins in_reg = {4}; bins dir_reg = {8};
      bins invalid = default;
    }
    byte_enable: coverpoint strobe iff (wr) {
      bins none = {0}; bins low_byte = {1}; bins all_bytes = {15};
      bins upper_only = {2, 4, 8, 14};
    }
    status: coverpoint error;
    operation_status: cross operation, status;
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent); samples = new("samples", this); accesses = new();
  endfunction

  function void compare(string label, logic [31:0] expected, logic [31:0] actual);
    checks++;
    if (actual !== expected)
      `uvm_error("GPIO_CHECK", $sformatf("%s expected=%08h actual=%08h", label, expected, actual))
  endfunction

  function void write(gpio_sample s);
    gpio_bus_item req;
    logic [GPIO_WIDTH-1:0] expected_pad;
    if (s.reset_n !== 1'b1) begin
      addresses.delete(); expected_b.delete(); expected_r.delete();
      output_value = 0; direction = 0; previous_input = 0;
      saw_reset = 1;
      compare("reset pins", 0, s.pins_out);
      return;
    end
    if (!saw_reset) `uvm_fatal("RESET", "Monitor did not observe initial reset")

    compare("output pins = OUT & DIR", output_value & direction, s.pins_out);
    compare("output-enable probe agrees with modeled DIR", direction, s.output_enable);
    for (int i = 0; i < GPIO_WIDTH; i++) begin
      if (s.pins_out[i] === 1'b0) output_zero_seen[i] = 1;
      if (s.pins_out[i] === 1'b1) output_one_seen[i] = 1;
      if (s.pins_in[i] === 1'b0) input_zero_seen[i] = 1;
      if (s.pins_in[i] === 1'b1) input_one_seen[i] = 1;
      // This truth table is independent of the interface's net resolution.
      if (direction[i] && s.external_enable[i]) begin
        expected_pad[i] = output_value[i] == s.external_value[i] ? output_value[i] : 1'bx;
        if (expected_pad[i] === 1'bx && s.pad_mode) contention_samples++;
      end else if (direction[i]) expected_pad[i] = output_value[i];
      else if (s.external_enable[i]) expected_pad[i] = s.external_value[i];
      else expected_pad[i] = 0; // documented weak pull-down
    end
    if (s.pad_mode) begin
      compare("resolved pad", {{(32-GPIO_WIDTH){1'b0}}, expected_pad},
        {{(32-GPIO_WIDTH){1'b0}}, s.pad});
      compare("pad-to-input connection", {{(32-GPIO_WIDTH){1'b0}}, expected_pad},
        {{(32-GPIO_WIDTH){1'b0}}, s.pins_in});
      pad_checks++;
    end
    pin_checks++;
    if (s.awvalid && !s.awready) aw_stalls++;
    if (s.wvalid && !s.wready) w_stalls++;
    if (s.arvalid && !s.arready) ar_stalls++;
    if (s.bvalid && !s.bready) b_stalls++;
    if (s.rvalid && !s.rready) r_stalls++;
    if ((s.arvalid || s.rvalid) && (s.awvalid || s.wvalid || s.bvalid))
      read_write_overlap++;

    // Retire responses before admitting new work on this edge. Expected
    // read data is captured at AR, so stalls cannot change the reference.
    if (s.bvalid && s.bready) begin
      if (expected_b.size() == 0) `uvm_fatal("ORPHAN", "B without accepted AW/W")
      req = expected_b.pop_front();
      compare("BID", req.id, s.bid); compare("BRESP", req.response, s.bresp);
      if (req.response != 0) error_responses++;
      writes++;
    end
    if (s.rvalid && s.rready) begin
      if (expected_r.size() == 0) `uvm_fatal("ORPHAN", "R without accepted AR")
      req = expected_r.pop_front();
      compare("RID", req.id, s.rid); compare("RRESP", req.response, s.rresp);
      compare("RDATA", req.read_data, s.rdata);
      if (req.response != 0) error_responses++;
      reads++;
    end
    // Reads and writes on the same edge see the pre-write register value.
    // IN at AR reflects the pin sampled on the preceding rising edge.
    if (s.arvalid && s.arready) begin
      req = gpio_bus_item::type_id::create("expected_read");
      req.addr = s.araddr; req.id = s.arid; req.response = 0;
      case (s.araddr[11:0])
        GPIO_OUT: req.read_data = output_value;
        GPIO_IN:  req.read_data = previous_input;
        GPIO_DIR: req.read_data = direction;
        default: begin req.read_data = 0; req.response = 2; end
      endcase
      expected_r.push_back(req);
      accesses.sample(0, s.araddr[11:0], 0, req.response != 0);
    end
    if (s.awvalid && s.awready) begin
      req = gpio_bus_item::type_id::create("write_address");
      req.addr = s.awaddr; req.id = s.awid;
      addresses.push_back(req);
    end
    if (s.wvalid && s.wready) begin
      if (addresses.size() == 0) `uvm_fatal("ORPHAN", "Accepted W without AW")
      req = addresses.pop_front(); req.response = 0;
      case (req.addr[11:0])
        GPIO_OUT: if (s.wstrb[0]) output_value = s.wdata[GPIO_WIDTH-1:0];
        GPIO_DIR: if (s.wstrb[0]) direction = s.wdata[GPIO_WIDTH-1:0];
        default: req.response = 2;
      endcase
      if (s.wstrb == 0) zero_strobes++;
      if (s.wstrb != 0 && !s.wstrb[0]) ignored_upper_strobes++;
      expected_b.push_back(req);
      accesses.sample(1, req.addr[11:0], s.wstrb, req.response != 0);
    end
    previous_input = s.pins_in;
  endfunction

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (addresses.size() || expected_b.size() || expected_r.size())
      `uvm_error("DRAIN", "Test ended with outstanding monitored transactions")
    if (reads == 0 || writes == 0 || pin_checks == 0)
      `uvm_error("EMPTY", "Test did not exercise reads, writes, and pins")
  endfunction
  function void report_phase(uvm_phase phase);
    `uvm_info("GPIO_COUNTS", $sformatf(
      "reads=%0d writes=%0d checks=%0d errors_expected=%0d overlap_cycles=%0d stalls(AW/W/AR/B/R)=%0d/%0d/%0d/%0d/%0d coverage=%0.1f%%",
      reads, writes, checks, error_responses, read_write_overlap,
      aw_stalls, w_stalls, ar_stalls, b_stalls, r_stalls, accesses.get_inst_coverage()), UVM_LOW)
  endfunction
endclass
