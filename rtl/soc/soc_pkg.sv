// =============================================================================
// soc_pkg.sv — Single source of truth: memory map + CSR offsets
//
// Everything that depends on an address or register offset (RTL wrappers,
// BFM, testbenches, and generated C headers) derives it from here.
// Nothing hand-derives an address independently.
//
// Baseline: 1 master (VeeR) x 4 slaves (RAM, UART, Timer, GPIO).
// AXI: 32-bit data, 32-bit addr, ID_WIDTH = 12 (matches the UART IP).
// =============================================================================

package soc_pkg;

  // --- Bus parameters -------------------------------------------------------
  localparam int unsigned AXI_DATA_WIDTH = 32;
  localparam int unsigned AXI_ADDR_WIDTH = 32;
  localparam int unsigned AXI_ID_WIDTH   = 12;

  // --- Slave base addresses / sizes -----------------------------------------
  localparam logic [31:0] RAM_BASE   = 32'h0000_0000;
  localparam int unsigned RAM_BYTES  = 65536; // 64 KiB

  localparam logic [31:0] UART_BASE  = 32'h1000_0000;
  localparam logic [31:0] TIMER_BASE = 32'h1001_0000;
  localparam logic [31:0] GPIO_BASE  = 32'h1002_0000;

  // --- UART register offsets (byte addresses) --------------------------------
  // The wrapper exposes the underlying ips/uart register map directly
  // (word index on addr[4:2]: RBR/THR=0, IER=1, BAUD_DIV=2, LCR=3, LSR=5).
  localparam logic [31:0] UART_RBR  = 32'h00; // RX data (read)
  localparam logic [31:0] UART_THR  = 32'h00; // TX data (write)
  localparam logic [31:0] UART_IER  = 32'h04; // IRQ enable (RX DATA_READY gated on this)
  localparam logic [31:0] UART_BAUD = 32'h08; // baud divisor
  localparam logic [31:0] UART_LCR  = 32'h0C; // line control
  localparam logic [31:0] UART_LSR  = 32'h14; // line status

  // LSR bit positions (see ips/uart axi_uart.vh)
  localparam int unsigned UART_LSR_DATA_READY = 0;
  localparam int unsigned UART_LSR_THRE       = 5;
  localparam int unsigned UART_LSR_TEMT       = 6;

  // --- Timer register offsets (fully custom RTL, see timer_wrapper.sv) -------
  localparam logic [31:0] TIMER_CTRL    = 32'h00;
  localparam logic [31:0] TIMER_COUNT   = 32'h04;
  localparam logic [31:0] TIMER_COMPARE = 32'h08;

  // TIMER_CTRL bits
  localparam int unsigned TIMER_CTRL_ENABLE = 0; // 1 = count
  localparam int unsigned TIMER_CTRL_MATCH  = 1; // sticky match flag, write-1-to-clear

  // --- GPIO register offsets (fully custom RTL, see gpio_wrapper.sv) ---------
  localparam logic [31:0] GPIO_OUT = 32'h00;
  localparam logic [31:0] GPIO_IN  = 32'h04;
  localparam logic [31:0] GPIO_DIR = 32'h08;

  localparam int unsigned GPIO_WIDTH = 8; // pins; registers carry them in low bits

endpackage
