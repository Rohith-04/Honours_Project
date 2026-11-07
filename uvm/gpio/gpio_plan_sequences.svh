// One external-drive change, synchronized through the existing pin driver.
class gpio_external_sequence extends uvm_sequence #(gpio_pin_item);
  `uvm_object_utils(gpio_external_sequence)
  bit [GPIO_WIDTH-1:0] value, enable;
  function new(string name = "gpio_external_sequence"); super.new(name); endfunction
  task body();
    gpio_pin_item req;
    req = gpio_pin_item::type_id::create("external_drive");
    start_item(req);
    req.value = value; req.enable = enable; req.hold_cycles = 4;
    finish_item(req);
  endtask
endclass

class gpio_plan_sequence extends gpio_base_sequence;
  `uvm_object_utils(gpio_plan_sequence)
  gpio_pin_sequencer pin_sequencer;
  virtual gpio_axi_if axi;
  localparam bit [GPIO_WIDTH-1:0] ALL_PINS = '1;
  function new(string name = "gpio_plan_sequence"); super.new(name); endfunction
  task external_drive(bit [GPIO_WIDTH-1:0] value, bit [GPIO_WIDTH-1:0] enable);
    gpio_external_sequence seq;
    seq = gpio_external_sequence::type_id::create("external");
    seq.value = value; seq.enable = enable;
    seq.start(pin_sequencer);
  endtask
  task expect_input(logic [GPIO_WIDTH-1:0] expected);
    // Allow the pad to settle and pass through the RTL's input sampling flop.
    repeat (2) @(axi.monitor_cb);
    access(0, GPIO_BASE + GPIO_IN, 0, 15, 0, 1,
           {{(32-GPIO_WIDTH){1'b0}}, expected});
  endtask
  task expect_register(bit [31:0] offset, bit [GPIO_WIDTH-1:0] expected);
    access(0, GPIO_BASE + offset, 0, 15, 0, 1, 32'(expected));
  endtask
endclass

// verification_plan.xlsx / SoC row 28 / SOC-027.
class soc_gpio_out_sequence extends gpio_plan_sequence;
  `uvm_object_utils(soc_gpio_out_sequence)
  function new(string name = "soc_gpio_out_sequence"); super.new(name); endfunction
  task body();
    bit [GPIO_WIDTH-1:0] patterns[5] = '{'0, '1, 8'ha5, 8'h5a, 8'h3c};
    external_drive(0, 0);
    access(1, GPIO_BASE + GPIO_DIR, 32'hffffffff);
    expect_register(GPIO_DIR, ALL_PINS);
    foreach (patterns[i]) begin
      // Set upper bits too: they must read zero and must not affect the pads.
      access(1, GPIO_BASE + GPIO_OUT, 32'hffffff00 | 32'(patterns[i]));
      expect_register(GPIO_OUT, patterns[i]);
      expect_input(patterns[i]);
    end
  endtask
endclass

// SoC row 29 / SOC-028: each pin changes direction while other pins drive.
class soc_gpio_dir_sequence extends gpio_plan_sequence;
  `uvm_object_utils(soc_gpio_dir_sequence)
  function new(string name = "soc_gpio_dir_sequence"); super.new(name); endfunction
  task body();
    bit [GPIO_WIDTH-1:0] output_pattern = 8'ha5;
    bit [GPIO_WIDTH-1:0] selected, other_outputs, external_pattern;
    logic [GPIO_WIDTH-1:0] expected;
    external_drive(8'h5a, ALL_PINS);
    expect_input(8'h5a);
    access(1, GPIO_BASE + GPIO_OUT, 32'(output_pattern));
    external_pattern = ~output_pattern;
    for (int i = 0; i < GPIO_WIDTH; i++) begin
      selected = GPIO_WIDTH'(1 << i);
      other_outputs = ALL_PINS ^ selected;
      external_drive(0, 0);
      access(1, GPIO_BASE + GPIO_DIR, 32'(other_outputs));
      external_drive(external_pattern, selected);
      expect_input((output_pattern & other_outputs) | (external_pattern & selected));
      // Switch input -> output without removing the opposite external value.
      // Equal-strength drivers resolve to X only on this selected pad.
      access(1, GPIO_BASE + GPIO_DIR, 32'(ALL_PINS));
      expected = output_pattern;
      expected[i] = 1'bx;
      expect_input(expected);
      expect_register(GPIO_OUT, output_pattern);
      expect_register(GPIO_DIR, ALL_PINS);
      external_drive(0, 0);
      expect_input(output_pattern); // output uses OUT, not the former input
      access(1, GPIO_BASE + GPIO_DIR, 32'(other_outputs));
      expect_input(output_pattern & other_outputs); // selected pad weakly low
      external_drive(external_pattern, selected);
      expect_input((output_pattern & other_outputs) | (external_pattern & selected));
      expect_register(GPIO_DIR, other_outputs);
    end
    external_drive(0, 0);
  endtask
endclass

// SoC row 30 / SOC-029: deterministic patterns in both signal directions.
class soc_gpio_walking_sequence extends gpio_plan_sequence;
  `uvm_object_utils(soc_gpio_walking_sequence)
  function new(string name = "soc_gpio_walking_sequence"); super.new(name); endfunction
  task body();
    bit [GPIO_WIDTH-1:0] patterns[$];
    bit [GPIO_WIDTH-1:0] one;
    patterns.push_back('0); patterns.push_back('1);
    patterns.push_back(8'haa); patterns.push_back(8'h55);
    for (int i = 0; i < GPIO_WIDTH; i++) begin
      one = GPIO_WIDTH'(1 << i);
      patterns.push_back(one); patterns.push_back(~one);
    end
    external_drive(0, 0);
    access(1, GPIO_BASE + GPIO_DIR, 32'(ALL_PINS));
    foreach (patterns[i]) begin
      access(1, GPIO_BASE + GPIO_OUT, 32'(patterns[i]));
      expect_register(GPIO_OUT, patterns[i]);
      expect_input(patterns[i]);
    end
    access(1, GPIO_BASE + GPIO_DIR, 0);
    foreach (patterns[i]) begin
      external_drive(patterns[i], ALL_PINS);
      expect_input(patterns[i]);
      expect_register(GPIO_DIR, 0);
      expect_register(GPIO_OUT, patterns[patterns.size()-1]);
    end
  endtask
endclass
