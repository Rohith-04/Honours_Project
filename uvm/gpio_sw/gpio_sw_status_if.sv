// Read-only bridge from the real-core harness to the UVM test. This interface
// neither controls the CPU nor drives AXI; it publishes checker completion.
interface gpio_sw_status_if(input logic clk);
  timeunit 1ns; timeprecision 1ps;
  wire done, passed, uart_ok, ebreak_seen;
  wire [31:0] signature, pc;
endinterface
