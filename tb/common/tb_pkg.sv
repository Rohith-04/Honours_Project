// =============================================================================
// tb_pkg.sv — Shared testbench constants (clock, reset, timeouts).
// Imported by every TB alongside soc_pkg.
// =============================================================================

package tb_pkg;
  localparam real CLK_PERIOD_NS = 10.0; // 100 MHz
  localparam int  RST_CYCLES    = 10;   // reset hold
  localparam int  POLL_MAX      = 100000; // bounded-poll ceiling for slow events
endpackage
