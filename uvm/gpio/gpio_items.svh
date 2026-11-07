class gpio_bus_item extends uvm_sequence_item;
  `uvm_object_utils(gpio_bus_item)
  bit write;
  bit [31:0] addr, data;
  bit [3:0] strb = 4'hf;
  rand bit [AXI_ID_WIDTH-1:0] id;
  rand int unsigned aw_delay, w_delay, ar_delay, response_delay;
  logic [31:0] read_data;
  logic [1:0] response;
  constraint bounded_delays {
    aw_delay inside {[0:5]}; w_delay inside {[0:5]};
    ar_delay inside {[0:5]}; response_delay inside {[0:6]};
  }
  function new(string name = "gpio_bus_item"); super.new(name); endfunction
  function string convert2string();
    return $sformatf("%s tx=%0d id=%03h addr=%08h data=%08h strb=%h rdata=%08h resp=%b delays(AW/W/AR/response)=%0d/%0d/%0d/%0d",
      write ? "WRITE" : "READ", get_transaction_id(), id, addr, data, strb,
      read_data, response, aw_delay, w_delay, ar_delay, response_delay);
  endfunction
  function void do_copy(uvm_object rhs);
    gpio_bus_item other;
    super.do_copy(rhs);
    if (!$cast(other, rhs)) `uvm_fatal("COPY", "Expected gpio_bus_item")
    write = other.write; addr = other.addr; data = other.data;
    strb = other.strb; id = other.id;
    aw_delay = other.aw_delay; w_delay = other.w_delay;
    ar_delay = other.ar_delay; response_delay = other.response_delay;
    read_data = other.read_data; response = other.response;
  endfunction
endclass

// Factory override changes timing while keeping the same driver and sequences.
class gpio_backpressure_item extends gpio_bus_item;
  `uvm_object_utils(gpio_backpressure_item)
  constraint longer_stalls { response_delay inside {[4:6]}; }
  function new(string name = "gpio_backpressure_item"); super.new(name); endfunction
endclass

class gpio_pin_item extends uvm_sequence_item;
  `uvm_object_utils(gpio_pin_item)
  rand bit [GPIO_WIDTH-1:0] value;
  bit [GPIO_WIDTH-1:0] enable = '1;
  int unsigned hold_cycles = 4;
  function new(string name = "gpio_pin_item"); super.new(name); endfunction
endclass

class gpio_config extends uvm_object;
  `uvm_object_utils(gpio_config)
  virtual gpio_axi_if axi_vif;
  virtual gpio_pin_if pin_vif;
  uvm_active_passive_enum is_active = UVM_ACTIVE;
  int unsigned queue_depth = 8;
  int unsigned timeout_cycles = 1000;
  function new(string name = "gpio_config"); super.new(name); endfunction
endclass

typedef uvm_sequencer #(gpio_bus_item) gpio_bus_sequencer;
typedef uvm_sequencer #(gpio_pin_item) gpio_pin_sequencer;

// One immutable sample per edge lets a scoreboard resolve concurrent AR/W
// handshakes consistently, without depending on analysis-port callback order.
class gpio_sample extends uvm_sequence_item;
  `uvm_object_utils(gpio_sample)
  logic reset_n;
  logic [AXI_ID_WIDTH-1:0] awid, bid, arid, rid;
  logic [31:0] awaddr, wdata, araddr, rdata;
  logic [3:0] wstrb;
  logic awvalid, awready, wvalid, wready, bvalid, bready;
  logic arvalid, arready, rvalid, rready;
  logic [1:0] bresp, rresp;
  logic [GPIO_WIDTH-1:0] pins_in, pins_out;
  logic [GPIO_WIDTH-1:0] output_enable, pad, external_value, external_enable;
  bit pad_mode;
  function new(string name = "gpio_sample"); super.new(name); endfunction
endclass
