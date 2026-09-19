# Honours SoC Structure and Testing Flow

## 1. Project Overview

The SoC is organized as a collection of reusable IP, RTL owned by the
project, verification environments, software tests, and simulation/build
infrastructure.

The current architecture is centered around:

``` text
                    +----------------+
                    |   VeeR EL2     |
                    |   RISC-V Core  |
                    +-------+--------+
                            |
                         AXI
                            |
                            v
                 +----------------------+
                 |  AXI Interconnect    |
                 |      32-bit          |
                 +----+------------+----+
                      |            |
                      v            v
                    RAM          UART
                                  |
                                  v
                               uart_tx
```

The eventual system will add the NDA accelerator as another
AXI-connected peripheral:

``` text
                    +----------------+
                    |   VeeR EL2     |
                    +-------+--------+
                            |
                            v
                 +----------------------+
                 |  AXI Interconnect    |
                 +---+-------+-------+--+
                     |       |       |
                     v       v       v
                    RAM    UART     NDA
```

The goal is to validate each layer independently before using the full
SoC to test software-driven accelerator operation.

------------------------------------------------------------------------

# 2. Repository Structure

The intended project structure is:

``` text
Honours_Project/
├── Cores-VeeR-EL2/
│
├── ips/
│   └── uart/
│
├── rtl/
│   ├── soc/
│   │   ├── honours_soc.sv
│   │   └── soc_pkg.sv
│   │
│   ├── interconnect/
│   ├── memory/
│   └── ...
│
├── tb/
│   ├── soc/
│   ├── uart/
│   └── interconnect/
│
├── sw/
│   ├── common/
│   │   ├── startup.S
│   │   └── linker.ld
│   │
│   ├── uart_test/
│   │   └── main.c
│   │
│   └── nda_test/
│       └── main.c
│
├── scripts/
│
├── run/
│   ├── soc/
│   ├── uart/
│   └── interconnect/
│
├── doc/
│   ├── architecture/
│   ├── interfaces/
│   └── verification/
│
└── README.md
```

## Directory Responsibilities

  -----------------------------------------------------------------------
  Directory                           Purpose
  ----------------------------------- -----------------------------------
  `Cores-VeeR-EL2/`                   VeeR EL2 CPU source

  `ips/`                              External/reused IP blocks

  `rtl/`                              Project-owned RTL

  `rtl/soc/`                          Top-level SoC integration

  `rtl/interconnect/`                 AXI interconnect implementation

  `tb/`                               Hardware verification testbenches

  `sw/`                               Bare-metal software running on VeeR

  `scripts/`                          Build and helper scripts

  `run/`                              Simulation scripts, filelists, and
                                      generated simulation data

  `doc/`                              Architecture and verification
                                      documentation
  -----------------------------------------------------------------------

The UART repository is kept under:

``` text
ips/uart/
```

rather than copying individual RTL files into the main `rtl/` directory.
This preserves the IP's original organization, dependencies,
documentation, and license information.

If adaptation is required, a project-owned wrapper can be placed under:

``` text
rtl/uart/axi_uart_wrapper.sv
```

The hierarchy then becomes:

``` text
honours_soc
    |
    +-- VeeR EL2
    |
    +-- AXI Interconnect
    |
    +-- RAM
    |
    +-- axi_uart_wrapper
             |
             +-- ips/uart/axi_uart_top
```

------------------------------------------------------------------------

# 3. SoC Top-Level Structure

The top-level SoC should be responsible for system integration rather
than implementing the internal behavior of individual peripherals.

The main responsibilities of `honours_soc.sv` are:

-   Instantiate the VeeR core
-   Instantiate the AXI interconnect
-   Instantiate memories
-   Instantiate peripherals
-   Connect AXI interfaces
-   Connect clocks and resets
-   Connect interrupts
-   Connect external pins
-   Establish the system address map

Conceptually:

``` text
rtl/soc/honours_soc.sv
        |
        +-- VeeR EL2
        |
        +-- AXI Interconnect
        |
        +-- RAM
        |
        +-- UART
        |
        +-- NDA
        |
        +-- future peripherals
```

The top-level file should remain mostly structural. Peripheral
implementation should stay inside its own IP or RTL module.

------------------------------------------------------------------------

# 4. Memory Map

A simple initial memory map can be:

``` text
Address Range             Device
------------------------------------------------
0x0000_0000 - 0x0000_FFFF RAM
0x1000_0000 - 0x1000_0FFF UART
0x2000_0000 - 0x2000_0FFF NDA
```

The exact addresses are part of the SoC architecture and should be kept
in one place, preferably:

``` text
rtl/soc/soc_pkg.sv
```

This same memory map becomes the contract between hardware and software.

For example, software accessing:

``` c
*(volatile unsigned int *)0x10000000
```

is performing an MMIO access to the UART.

------------------------------------------------------------------------

# 5. Important AXI Data-Width Issue

VeeR EL2 exposes 64-bit system data buses on its IFU and LSU interfaces,
while the current SoC AXI interconnect is 32-bit.

Therefore, the following connection is not a valid complete integration:

``` text
VeeR 64-bit AXI
       |
       v
32-bit AXI Interconnect
```

A proper data-width adaptation is required.

The current use of only the lower 32 bits should be treated as an
incomplete integration and not as a functional 64-to-32 AXI converter.

The eventual integration needs to account for:

-   `WDATA`
-   `WSTRB`
-   `RDATA`
-   transfer size
-   address alignment
-   AXI transaction semantics
-   IFU/LSU integration and arbitration

This should be resolved before relying on software-driven SoC testing.

------------------------------------------------------------------------

# 6. Hardware Testing

Hardware testing is performed at multiple levels.

## 6.1 Block-Level Testing

Each RTL block should first have an independent testbench.

Examples:

``` text
tb/
├── uart/
│   └── tb_uart.sv
│
└── interconnect/
    └── tb_axi_interconnect.sv
```

For the UART, test:

-   Reset behavior
-   Register reads/writes
-   TX operation
-   RX operation
-   Baud-rate generation
-   FIFO behavior
-   Parity, if supported
-   Error handling

For the AXI interconnect, test:

-   Address decoding
-   Master/slave routing
-   Arbitration
-   Read transactions
-   Write transactions
-   Responses
-   Backpressure
-   Invalid addresses

For the NDA, first test the accelerator independently before integrating
it into the SoC.

------------------------------------------------------------------------

# 7. SoC-Level Hardware Testing

After individual blocks pass, create:

``` text
tb/soc/tb_honours_soc.sv
```

The SoC testbench contains:

``` text
tb_honours_soc
       |
       v
 honours_soc
       |
       +-- VeeR
       +-- AXI interconnect
       +-- RAM
       +-- UART
       +-- NDA
```

At this level, the testbench verifies that the blocks work together.

A useful initial hardware-only sequence is:

``` text
Reset
  |
  v
CPU starts
  |
  v
AXI transaction
  |
  v
Address decode
  |
  v
Correct peripheral selected
  |
  v
Peripheral response
  |
  v
PASS
```

------------------------------------------------------------------------

# 8. Software Testing Flow

The software testing flow is different from a normal RTL testbench.

The C program is not directly simulated.

Instead:

``` text
                 C source
                    |
                    v
            RISC-V cross compiler
                    |
                    v
                  ELF
                    |
                    v
             Memory image
                    |
                    v
             Simulated RAM
                    |
                    v
                VeeR EL2
                    |
                    v
                   AXI
                    |
                    v
             SoC peripherals
```

The CPU executes the compiled RISC-V instructions cycle by cycle inside
the RTL simulator.

------------------------------------------------------------------------

# 9. Bare-Metal Software

Software should initially be simple bare-metal programs.

Example:

``` text
sw/
├── common/
│   ├── startup.S
│   └── linker.ld
│
└── uart_test/
    └── main.c
```

`startup.S` provides the processor entry point and initializes the stack
before calling `main()`.

`linker.ld` defines where program sections are placed in the simulated
SoC memory.

------------------------------------------------------------------------

# 10. Simple UART Software Test

A minimal UART programming model might define:

``` c
#define UART_BASE    0x10000000UL
#define UART_TXDATA  (*(volatile unsigned int *)(UART_BASE + 0x00))
```

A simple driver can then be:

``` c
static void uart_putc(char c)
{
    UART_TXDATA = c;
}

int main(void)
{
    uart_putc('H');
    uart_putc('i');
    uart_putc('\n');

    while (1)
        ;

    return 0;
}
```

The resulting hardware flow is:

``` text
uart_test/main.c
       |
       v
RISC-V compiler
       |
       v
uart_test.elf
       |
       v
uart_test.hex
       |
       v
Simulated RAM
       |
       v
VeeR executes program
       |
       v
CPU performs AXI write
       |
       v
AXI Interconnect
       |
       v
UART TXDATA register
       |
       v
UART transmitter
       |
       v
uart_tx
```

------------------------------------------------------------------------

# 11. ELF to Memory Image

The compiled ELF must be converted into a memory format that the
simulated RAM can load.

A typical flow is:

``` bash
riscv32-unknown-elf-objcopy \
    -O verilog \
    uart_test.elf \
    uart_test.hex
```

The simulated RAM can then load the image:

``` systemverilog
initial begin
    $readmemh("uart_test.hex", memory);
end
```

The exact conversion command depends on the memory model and simulator
flow.

------------------------------------------------------------------------

# 12. UART Output in Simulation

The SoC testbench monitors the UART TX pin:

``` text
uart_tx
   |
   v
UART monitor
   |
   v
Decode serial bits
   |
   v
ASCII character
   |
   v
Simulator console
```

The final simulation output can look like:

``` text
================================
      VeeR SoC Simulation
================================

UART: Hello from VeeR!

UART TEST: PASS
```

This provides a software-visible output channel without requiring a
physical FPGA board.

------------------------------------------------------------------------

# 13. Hardware and Software Testing Together

The important distinction is:

### Hardware-only test

``` text
Testbench
    |
    v
RTL
    |
    v
Expected signal/register behavior
```

Example:

``` text
AXI write to UART TXDATA
        |
        v
UART transmits expected serial data
```

### Software-driven test

``` text
C program
    |
    v
Compiled RISC-V instructions
    |
    v
VeeR
    |
    v
AXI
    |
    v
Interconnect
    |
    v
UART
    |
    v
uart_tx
    |
    v
Testbench
```

The second test validates the complete software-to-hardware path.

------------------------------------------------------------------------

# 14. NDA Testing Strategy

The NDA accelerator should not be introduced as the first end-to-end
test.

First establish:

``` text
1. NDA RTL works
2. NDA register interface works
3. AXI interconnect works
4. VeeR can access peripherals
5. UART provides software-visible output
```

Then integrate the NDA.

The final software-driven test becomes:

``` text
                   C Program
                      |
                      v
                   VeeR EL2
                      |
                      v
                     AXI
                      |
              +-------+-------+
              |               |
              v               v
             UART            NDA
              |               |
              |               v
              |          Accelerator
              |               |
              |               v
              |            Result
              |               |
              +-------+-------+
                      |
                      v
              Simulation Console
```

For example:

``` c
NDA_INPUT = test_value;
NDA_CONTROL = 1;

while (!(NDA_STATUS & 1))
    ;

result = NDA_OUTPUT;

uart_print("NDA DONE\n");
```

The UART acts as the software-visible debug and result channel.

------------------------------------------------------------------------

# 15. Verification Ladder

The recommended verification sequence is:

``` text
LEVEL 1
Individual RTL blocks
        |
        v
UART / AXI / NDA testbenches
        |
        v
LEVEL 2
SoC hardware integration
        |
        v
VeeR + RAM + AXI + UART
        |
        v
LEVEL 3
Bare-metal software
        |
        v
C program executes on VeeR
        |
        v
LEVEL 4
Software-driven peripheral tests
        |
        v
CPU -> AXI -> UART
        |
        v
LEVEL 5
Software-driven NDA test
        |
        v
CPU -> AXI -> NDA -> result
```

The purpose of this ordering is to avoid debugging multiple unknown
systems simultaneously.

If the NDA standalone test passes but the software NDA test fails, the
problem is much more likely to be in:

-   SoC integration
-   AXI transactions
-   Address decoding
-   Register mapping
-   Software assumptions
-   Data-width adaptation
-   Reset/clock behavior

rather than in the NDA datapath itself.

------------------------------------------------------------------------

# 16. Make Commands

The exact targets depend on the current Makefiles, but the intended
workflow should be kept simple.

## UART IP

From the UART IP directory:

``` bash
cd ips/uart
make
```

Use the UART project's own Makefile for IP-level compilation/linting
when required.

## RTL Simulation

From the appropriate simulation directory:

``` bash
cd run/soc
./run_sim.sh
```

or, if a Makefile is provided:

``` bash
make
make sim
```

## Software

From a software test directory:

``` bash
cd sw/uart_test
make
```

Expected outputs:

``` text
build/
├── uart_test.elf
├── uart_test.bin
└── uart_test.hex
```

## Run Software on the Simulated SoC

The simulator should receive the generated memory image:

``` bash
./run_sim.sh ../../sw/uart_test/build/uart_test.hex
```

The final goal is a single repeatable command such as:

``` bash
make sim SW=uart_test
```

which performs:

``` text
Compile RTL
    |
    v
Compile software
    |
    v
Generate memory image
    |
    v
Start simulator
    |
    v
Load program into RAM
    |
    v
Release CPU reset
    |
    v
Execute software
    |
    v
Monitor UART
    |
    v
Report PASS/FAIL
```

------------------------------------------------------------------------

# 17. Recommended Development Order

The immediate implementation order is:

``` text
1. Organize SoC top
        |
2. Resolve VeeR/interconnect interface
        |
3. Integrate RAM
        |
4. Integrate UART
        |
5. Create SoC testbench
        |
6. Establish bare-metal toolchain
        |
7. Create startup code and linker script
        |
8. Compile a minimal C program
        |
9. Load program into simulated RAM
        |
10. Execute C on VeeR
        |
11. Verify UART output
        |
12. Add NDA
        |
13. Test NDA registers from software
        |
14. Run NDA computation from software
```

The UART therefore serves two purposes:

1.  It is a real SoC peripheral.
2.  It becomes the first software-visible output mechanism for debugging
    the complete system.

Once the software-driven UART flow works, the same infrastructure can be
reused for the NDA and future peripherals.
