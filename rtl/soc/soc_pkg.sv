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
  // VeeR default core-local PIC and the SoC's external interrupt source IDs.
  localparam logic [31:0] PIC_BASE = 32'hF00C_0000;
  localparam int unsigned IRQ_UART = 1;
  localparam int unsigned IRQ_TIMER = 2;
  localparam int unsigned IRQ_NDA = 3;
  localparam int unsigned IRQ_WDT = 4;

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

  // ===========================================================================
  // Phase 2: Custom IP (NDA / HPM / WDT) — bases, offsets, build config
  //
  // The three CSR regions live in the 0x5000_xxxx range.
  // All offsets are byte addresses relative to the base.
  // ===========================================================================

  // --- Build configuration (feeds wrapper generator + generated C header) ---
`ifdef SOC_DISABLE_HPM
  localparam bit          ENABLE_HPM  = 1'b0;
`else
  localparam bit          ENABLE_HPM  = 1'b1;
`endif
  localparam int unsigned NUM_MASTERS = 2;    // M0=CPU, M1=NDA
  localparam int unsigned NUM_SLAVES  = 6 + (ENABLE_HPM ? 1 : 0); // HPM is always last

  // --- Custom IP base addresses -----------------------------------------------
  localparam logic [31:0] NDA_BASE = 32'h5000_0000;
  localparam logic [31:0] HPM_BASE = 32'h5000_1000;
  localparam logic [31:0] WDT_BASE = 32'h5000_2000;

  // Each CSR region is 4 KiB (12-bit address width).
  localparam int unsigned CSR_REGION_BITS = 12; // 4 KiB per CSR block

  // --- NDA data window (currently the RAM region) -----------------------------
  localparam logic [31:0] NDA_DATA_BASE = RAM_BASE;
  localparam logic [31:0] NDA_DATA_END  = RAM_BASE + RAM_BYTES;

  // --- NDA register offsets (byte addresses from NDA_BASE) ---------------------
  localparam logic [31:0] NDA_CTRL      = 32'h00;
  localparam logic [31:0] NDA_STATUS    = 32'h04;
  localparam logic [31:0] NDA_OP        = 32'h08;
  localparam logic [31:0] NDA_SRC_BASE  = 32'h0C;
  localparam logic [31:0] NDA_LEN       = 32'h10;
  localparam logic [31:0] NDA_RESULT_LO = 32'h14;
  localparam logic [31:0] NDA_RESULT_HI = 32'h18;
  localparam logic [31:0] NDA_CYCLES    = 32'h1C;

  // NDA_CTRL bits
  localparam int unsigned NDA_CTRL_START  = 0; // self-clearing
  localparam int unsigned NDA_CTRL_ABORT  = 1; // self-clearing
  localparam int unsigned NDA_CTRL_IRQ_EN = 2;

  // NDA_STATUS bits
  localparam int unsigned NDA_STATUS_BUSY     = 0; // RO
  localparam int unsigned NDA_STATUS_DONE     = 1; // W1C
  localparam int unsigned NDA_STATUS_ERR      = 2; // W1C
  localparam int unsigned NDA_STATUS_CODE_LSB = 4; // [7:4] RO error code

  // NDA_OP encodings
  localparam logic [3:0] NDA_OP_SUM    = 4'd0;
  localparam logic [3:0] NDA_OP_MIN    = 4'd1;
  localparam logic [3:0] NDA_OP_MAX    = 4'd2;
  localparam logic [3:0] NDA_OP_ARGMAX = 4'd3;

  // NDA error codes
  localparam logic [3:0] NDA_ERR_NONE       = 4'h0;
  localparam logic [3:0] NDA_ERR_BAD_LEN    = 4'h1;
  localparam logic [3:0] NDA_ERR_BAD_OP     = 4'h2;
  localparam logic [3:0] NDA_ERR_MISALIGNED = 4'h3;
  localparam logic [3:0] NDA_ERR_BAD_ADDR   = 4'h4;
  localparam logic [3:0] NDA_ERR_BAD_RANGE  = 4'h5;
  localparam logic [3:0] NDA_ERR_BUS_ERROR  = 4'h6;
  localparam logic [3:0] NDA_ERR_ABORTED    = 4'h7;

  // --- NDA parameters (module-level, swept in experiments) --------------------
  localparam int unsigned NDA_BURST_LEN       = 16;  // beats per read burst
  localparam int unsigned NDA_MAX_OUTSTANDING = 4;   // reads in flight

  // --- WDT register offsets (byte addresses from WDT_BASE) --------------------
  localparam logic [31:0] WDT_CTRL       = 32'h00;
  localparam logic [31:0] WDT_TIMEOUT    = 32'h04;
  localparam logic [31:0] WDT_STATUS     = 32'h08;
  localparam logic [31:0] WDT_TRIP_COUNT = 32'h0C;

  // WDT_CTRL bits
  localparam int unsigned WDT_CTRL_EN     = 0;
  localparam int unsigned WDT_CTRL_IRQ_EN = 2;

  // WDT_STATUS bits
  localparam int unsigned WDT_STATUS_TRIPPED = 0; // W1C
  localparam int unsigned WDT_STATUS_ARMED   = 1; // RO

  // WDT default timeout
  localparam int unsigned WDT_TIMEOUT_DEFAULT = 4096;

  // --- HPM register offsets (byte addresses from HPM_BASE) --------------------
  localparam logic [31:0] HPM_CTRL = 32'h00;

  // HPM_CTRL bits
  localparam int unsigned HPM_CTRL_ENABLE   = 0;
  localparam int unsigned HPM_CTRL_CLEAR    = 1;  // self-clearing
  localparam int unsigned HPM_CTRL_SNAPSHOT = 2;  // self-clearing

  // HPM counter register pairs (LO at offset, HI at offset+4)
  localparam logic [31:0] HPM_CYCLES_LO     = 32'h10;
  localparam logic [31:0] HPM_CPU_AR_LO     = 32'h18;
  localparam logic [31:0] HPM_CPU_AW_LO     = 32'h20;
  localparam logic [31:0] HPM_CPU_RBEATS_LO = 32'h28;
  localparam logic [31:0] HPM_CPU_WBEATS_LO = 32'h30;
  localparam logic [31:0] HPM_NDA_AR_LO     = 32'h38;
  localparam logic [31:0] HPM_NDA_RBEATS_LO = 32'h40;
  localparam logic [31:0] HPM_NDA_BUSY_LO   = 32'h48;
  localparam logic [31:0] HPM_FALLBACKS_LO  = 32'h50;
  // each counter's HI word is at LO + 4

  // HPM number of counters (for array sizing in RTL)
  localparam int unsigned HPM_NUM_COUNTERS = 9;

endpackage
