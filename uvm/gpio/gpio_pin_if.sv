interface gpio_pin_if(input logic clk, input logic aresetn);
  timeunit 1ns; timeprecision 1ps;
  // Direct mode preserves the original isolated-IP tests. Pad mode connects
  // the split RTL input/output ports through explicit resolved digital pads.
  bit pad_mode = 0;
  logic [soc_pkg::GPIO_WIDTH-1:0] external_value = '0;
  logic [soc_pkg::GPIO_WIDTH-1:0] external_enable = '1;
  wire [soc_pkg::GPIO_WIDTH-1:0] gpio_in;
  wire  [soc_pkg::GPIO_WIDTH-1:0] gpio_out;
  wire [soc_pkg::GPIO_WIDTH-1:0] output_enable;
  tri0 [soc_pkg::GPIO_WIDTH-1:0] pad;
  for (genvar i = 0; i < soc_pkg::GPIO_WIDTH; i++) begin : gen_pad
    assign pad[i] = output_enable[i] ? gpio_out[i] : 1'bz;
    assign pad[i] = external_enable[i] ? external_value[i] : 1'bz;
  end
  assign gpio_in = pad_mode ? pad : external_value;

  clocking driver_cb @(posedge clk);
    default input #1step output #0;
    input aresetn;
    output external_value, external_enable;
  endclocking
  clocking monitor_cb @(posedge clk);
    default input #1step;
    input aresetn, gpio_in, gpio_out, output_enable, pad;
    input pad_mode, external_value, external_enable;
  endclocking
endinterface
