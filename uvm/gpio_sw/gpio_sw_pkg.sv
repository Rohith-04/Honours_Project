package gpio_sw_pkg;
  timeunit 1ns; timeprecision 1ps;
  import uvm_pkg::*;
  import soc_pkg::*;
  import gpio_vip_pkg::*;
  `include "uvm_macros.svh"

  // =========================================================================
  // gpio_ext_monitor
  //
  // External VIP component. Watches the AXI observation interface and
  // captures gpio_out exactly when an accepted write to the OUT register
  // (awaddr[11:0] == GPIO_OUT offset) completes on the W channel.
  //
  // Using the AXI write handshake as the trigger — rather than watching
  // gpio_out change — avoids false captures caused by DIR writes that
  // restore masked output bits (e.g. the DIR-walking loop writes DIR=mask
  // each iteration, which changes gpio_out back to 0xA5 on enabled pins
  // without any OUT register write occurring).
  //
  // Sequence mirrors sw/gpio_uvm_test/main.c in execution order:
  //   Fixed patterns (4)  : 0x00, 0xFF, 0xAA, 0x55
  //   Walking one+zero (16): 0x01,0xFE, 0x02,0xFD, 0x04,0xFB, 0x08,0xF7,
  //                          0x10,0xEF, 0x20,0xDF, 0x40,0xBF, 0x80,0x7F
  //   Pre-dir-walk write  : 0xA5
  //   Final clear         : 0x00
  // Total: 21 OUT writes captured.
  // =========================================================================
  class gpio_ext_monitor extends uvm_component;
    `uvm_component_utils(gpio_ext_monitor)

    virtual gpio_axi_if axi_vif;
    virtual gpio_pin_if pin_vif;

    // Hardcoded sequence matching C execution order exactly (22 entries).
    // Declared with a literal bound [0:21] — VCS cannot resolve a class
    // localparam as an unpacked array bound in an inline initialiser.
    localparam int NUM_PATTERNS = 22;
    logic [7:0] expected_seq[0:21];

    int unsigned seq_index  = 0;
    int unsigned vip_checks = 0;
    int unsigned vip_errors = 0;

    // Exposed as plain logic for the wave file.
    logic [7:0] captured = '0;

    // Latched AW address: the AW and W channels can handshake in different
    // cycles. Hold the address from AW acceptance until W acceptance.
    logic [31:0] pending_awaddr = '0;
    bit           aw_pending     = 0;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual gpio_axi_if)::get(this, "", "axi_vif", axi_vif))
        `uvm_fatal("CONFIG", "gpio_ext_monitor requires axi_vif")
      if (!uvm_config_db#(virtual gpio_pin_if)::get(this, "", "pin_vif", pin_vif))
        `uvm_fatal("CONFIG", "gpio_ext_monitor requires pin_vif")
      // Fixed patterns (4): indices 0-3
      expected_seq[0]  = 8'h00; expected_seq[1]  = 8'hFF;
      expected_seq[2]  = 8'hAA; expected_seq[3]  = 8'h55;
      // Walking one then zero, interleaved per bit (16): indices 4-19
      expected_seq[4]  = 8'h01; expected_seq[5]  = 8'hFE;
      expected_seq[6]  = 8'h02; expected_seq[7]  = 8'hFD;
      expected_seq[8]  = 8'h04; expected_seq[9]  = 8'hFB;
      expected_seq[10] = 8'h08; expected_seq[11] = 8'hF7;
      expected_seq[12] = 8'h10; expected_seq[13] = 8'hEF;
      expected_seq[14] = 8'h20; expected_seq[15] = 8'hDF;
      expected_seq[16] = 8'h40; expected_seq[17] = 8'hBF;
      expected_seq[18] = 8'h80; expected_seq[19] = 8'h7F;
      // Pre-dir-walk write (index 20), final OUT=0x00 (index 21).
      // The final write occurs after DIR=0 then DIR=mask so output_enable
      // is 0xFF again when OUT=0 lands on AXI — both are captured.
      expected_seq[20] = 8'hA5;
      expected_seq[21] = 8'h00;
    endfunction

    task run_phase(uvm_phase phase);
      wait (axi_vif.aresetn === 1'b1);
      @(axi_vif.monitor_cb);

      forever begin
        @(axi_vif.monitor_cb);

        // Latch AW address on AW handshake.
        if (axi_vif.monitor_cb.awvalid && axi_vif.monitor_cb.awready) begin
          pending_awaddr = axi_vif.monitor_cb.awaddr;
          aw_pending     = 1;
        end

        // Capture on W handshake if the pending address is the OUT register.
        if (axi_vif.monitor_cb.wvalid && axi_vif.monitor_cb.wready && aw_pending) begin
          if (pending_awaddr[11:0] == soc_pkg::GPIO_OUT) begin
            // gpio_out updates combinatorially one cycle after the W beat;
            // sample the wdata[7:0] from the AXI channel directly — this is
            // what C wrote and what will appear on gpio_out next cycle.
            captured = axi_vif.monitor_cb.wdata[soc_pkg::GPIO_WIDTH-1:0];

            if (seq_index < NUM_PATTERNS) begin
              vip_checks++;
              if (captured !== expected_seq[seq_index]) begin
                vip_errors++;
                `uvm_error("GPIO_EXT_VIP",
                  $sformatf("Pattern[%0d]: expected=0x%02h actual=0x%02h",
                    seq_index, expected_seq[seq_index], captured))
              end else begin
                `uvm_info("GPIO_EXT_VIP",
                  $sformatf("Pattern[%0d]: captured=0x%02h OK",
                    seq_index, captured), UVM_MEDIUM)
              end
              seq_index++;
            end else begin
              `uvm_error("GPIO_EXT_VIP",
                $sformatf("Unexpected extra OUT write: captured=0x%02h (seq_index=%0d)",
                  captured, seq_index))
            end
          end
          aw_pending = 0;
        end
      end
    endtask

    function void check_phase(uvm_phase phase);
      super.check_phase(phase);
      if (seq_index < NUM_PATTERNS)
        `uvm_error("GPIO_EXT_VIP",
          $sformatf("Only %0d of %0d expected OUT writes were observed",
            seq_index, NUM_PATTERNS))
      `uvm_info("GPIO_EXT_VIP",
        $sformatf("vip_checks=%0d vip_errors=%0d seq_index=%0d/%0d",
          vip_checks, vip_errors, seq_index, NUM_PATTERNS), UVM_LOW)
    endfunction
  endclass

  // =========================================================================
  // gpio_sw_test
  //
  // Reuses the VIP passive gpio_env (monitor + scoreboard, no drivers).
  // Additionally instantiates gpio_ext_monitor to perform the external
  // sequence comparison described above.
  // =========================================================================
  class gpio_sw_test extends uvm_test;
    `uvm_component_utils(gpio_sw_test)

    gpio_config      cfg;
    gpio_env         env;
    gpio_ext_monitor ext_mon;

    virtual gpio_sw_status_if status;
    int unsigned completion_checks;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      cfg           = gpio_config::type_id::create("cfg");
      cfg.is_active = UVM_PASSIVE;

      if (!uvm_config_db#(virtual gpio_axi_if)::get(this, "", "axi_vif", cfg.axi_vif)    ||
          !uvm_config_db#(virtual gpio_pin_if)::get(this, "", "pin_vif", cfg.pin_vif)     ||
          !uvm_config_db#(virtual gpio_sw_status_if)::get(this, "", "status_vif", status))
        `uvm_fatal("CONFIG",
          "Software GPIO test requires axi_vif, pin_vif, and status_vif")

      uvm_config_db#(gpio_config)::set(this, "env", "cfg", cfg);
      env = gpio_env::type_id::create("env", this);

      // Supply both interfaces to the external monitor via config_db.
      uvm_config_db#(virtual gpio_axi_if)::set(this, "ext_mon", "axi_vif", cfg.axi_vif);
      uvm_config_db#(virtual gpio_pin_if)::set(this, "ext_mon", "pin_vif", cfg.pin_vif);
      ext_mon = gpio_ext_monitor::type_id::create("ext_mon", this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      if (env.agent.bus_driver   != null || env.agent.bus_sequencer != null ||
          env.agent.pin_driver   != null || env.agent.pin_sequencer != null)
        `uvm_fatal("OWNERSHIP",
          "Passive software environment must not create drivers/sequencers")
      uvm_top.print_topology();
    endfunction

    function void check_completion(string label, bit valid);
      completion_checks++;
      if (!valid) `uvm_error("SOFTWARE", label)
    endfunction

    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      `uvm_info("SOFTWARE",
        "VeeR executes C; GPIO VIP observes slave AXI, pins, and output sequence",
        UVM_LOW)
      fork
        begin
          wait (status.done === 1'b1);
        end
        begin
          repeat (5_000_000) @(posedge status.clk);
          `uvm_fatal("TIMEOUT",
            $sformatf("Software did not finish; PC=%08h", status.pc))
        end
      join_any
      disable fork;

      // Allow the ext_mon run_phase a couple of cycles to register the final
      // gpio_out=0x00 transition before we evaluate check_phase.
      repeat (5) @(cfg.axi_vif.monitor_cb);

      check_completion("software harness reported failure",
        status.passed    === 1'b1);
      check_completion("missing GPIO OK UART tag or FAIL text observed",
        status.uart_ok   === 1'b1);
      check_completion("missing software ebreak",
        status.ebreak_seen === 1'b1);
      check_completion("incorrect independent RAM signature",
        status.signature === 32'h50515353);

      repeat (3) @(cfg.axi_vif.monitor_cb);
      phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
      uvm_report_server server;
      server = uvm_report_server::get_server();
      `uvm_info("SOFTWARE_COUNTS",
        $sformatf(
          "GPIO reads=%0d writes=%0d; completion checks=%0d; vip_checks=%0d vip_errors=%0d",
          env.scoreboard.reads, env.scoreboard.writes,
          completion_checks,
          ext_mon.vip_checks, ext_mon.vip_errors), UVM_LOW)
      if (server.get_severity_count(UVM_ERROR) == 0 &&
          server.get_severity_count(UVM_FATAL) == 0)
        $display("TEST %s: PASS (%0d checks)", get_type_name(),
          env.scoreboard.checks + completion_checks + ext_mon.vip_checks);
      else
        $display("TEST %s: FAIL", get_type_name());
    endfunction
  endclass

endpackage
