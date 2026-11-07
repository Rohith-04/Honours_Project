package gpio_vip_pkg;
  timeunit 1ns; timeprecision 1ps;
  import uvm_pkg::*;
  import soc_pkg::*;
  `include "uvm_macros.svh"
  `include "gpio_items.svh"
  `include "gpio_driver.svh"
  `include "gpio_monitor.svh"
  `include "gpio_scoreboard.svh"
  `include "gpio_agent.svh"
  `include "gpio_sequences.svh"
  `include "gpio_plan_sequences.svh"
  `include "gpio_tests.svh"
  `include "gpio_plan_tests.svh"
endpackage
