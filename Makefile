# =============================================================================
# Makefile — Honours SoC (VCS + Verdi)
#
#   make unit IP=gpio|timer|uart|ram   run a Level-1 unit test
#   make integration                run the Level-2 integration test
#   make sw IP=gpio|uart|timer       run a Level-3 SW test (real VeeR + C)
#   make verdi LEVEL=unit IP=gpio   re-run with FSDB dump + open Verdi
#   make verdi LEVEL=integration    (IP not needed for integration)
#   make verdi LEVEL=sw IP=gpio     (rebuilds SW hex + simv with FSDB)
#   make clean                      remove run/ and build/
#
# Plain runs need only VCS. Verdi runs additionally need VERDI_HOME set
# (for the FSDB PLI) and recompile with -debug_access+all + FSDB_DUMP.
# Wave .rc files are curated later; verdi opens without one for now.
#
# SW tests additionally need riscv64-unknown-elf-gcc in PATH (lab machine /
# VeeR flow) and perl (for the VeeR config generator, usually present).
# =============================================================================

PROJ_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

VCS   := vcs
VERDI := verdi

VERDI_HOME ?= $(shell echo $$VERDI_HOME)
FSDB_PLI    = $(VERDI_HOME)/share/PLI/VCS/LINUX64

# Extra compile defines from the command line, e.g.
#   make unit IP=ram DEFINES=+define+RAM_DEBUG
DEFINES ?=

# NOTE: -nc (no incremental compile) is deliberate. VCS's incremental cache
# (./csrc, shared across targets) silently reused stale interconnect objects
# after rtl/ edits, so a fix showed zero effect and cost a full debug cycle
# chasing a ghost. Full rebuilds of this design take seconds; silent
# staleness is unacceptable in a verification flow.
VCS_FLAGS := \
    -full64 \
    -sverilog \
    -timescale=1ns/1ps \
    -nc

VCS_FLAGS_VERDI := \
    $(VCS_FLAGS) \
    -debug_access+all \
    +define+FSDB_DUMP \
    -P $(FSDB_PLI)/novas.tab \
    $(FSDB_PLI)/pli.a

INCDIRS := \
    +incdir+$(PROJ_ROOT)/tb/common \
    +incdir+$(PROJ_ROOT)/ips/uart/src/include

UART_IP := \
    $(PROJ_ROOT)/ips/uart/src/rtl/uart_parity_bit_compute.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/uart_receiver.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/uart_transmitter.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/uart_controller.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/axi_internal_fifo.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/axi_uart_top.v

XBAR := \
    $(PROJ_ROOT)/rtl/interconnect/priority_encoder.v \
    $(PROJ_ROOT)/rtl/interconnect/arbiter.v \
    $(PROJ_ROOT)/rtl/interconnect/axi_interconnect.v \
    $(PROJ_ROOT)/rtl/interconnect/axi_interconnect_wrap_1x4.v

SOC := \
    $(PROJ_ROOT)/rtl/soc/soc_pkg.sv \
    $(PROJ_ROOT)/rtl/mem/axi_ram.sv \
    $(PROJ_ROOT)/rtl/wrappers/uart_wrapper.sv \
    $(PROJ_ROOT)/rtl/wrappers/timer_wrapper.sv \
    $(PROJ_ROOT)/rtl/wrappers/gpio_wrapper.sv \
    $(PROJ_ROOT)/rtl/soc/honours_soc.sv

BFM_TB := \
    $(PROJ_ROOT)/bfm/axi_master_bfm.sv \
    $(PROJ_ROOT)/tb/common/tb_pkg.sv

# --- per-IP unit file lists ----------------------------------------------------
gpio_UNIT := $(PROJ_ROOT)/rtl/soc/soc_pkg.sv \
             $(PROJ_ROOT)/rtl/wrappers/gpio_wrapper.sv \
             $(BFM_TB) $(PROJ_ROOT)/tb/unit/tb_gpio_unit.sv
gpio_TOP  := tb_gpio_unit

timer_UNIT := $(PROJ_ROOT)/rtl/soc/soc_pkg.sv \
              $(PROJ_ROOT)/rtl/wrappers/timer_wrapper.sv \
              $(BFM_TB) $(PROJ_ROOT)/tb/unit/tb_timer_unit.sv
timer_TOP  := tb_timer_unit

uart_UNIT := $(PROJ_ROOT)/rtl/soc/soc_pkg.sv \
             $(UART_IP) $(PROJ_ROOT)/rtl/wrappers/uart_wrapper.sv \
             $(BFM_TB) $(PROJ_ROOT)/tb/unit/tb_uart_unit.sv
uart_TOP  := tb_uart_unit

ram_UNIT := $(PROJ_ROOT)/rtl/soc/soc_pkg.sv \
            $(PROJ_ROOT)/rtl/mem/axi_ram.sv \
            $(BFM_TB) $(PROJ_ROOT)/tb/unit/tb_ram_unit.sv
ram_TOP  := tb_ram_unit

integration_FILES := $(SOC) $(UART_IP) $(XBAR) $(BFM_TB) \
                     $(PROJ_ROOT)/tb/integration/tb_soc_integration.sv
integration_TOP   := tb_soc_integration

# --- Level 3 (SW): real VeeR EL2 + adapter + SoC + compiled C -----------------
VEER_ROOT  := $(PROJ_ROOT)/Cores-VeeR-EL2
VEER_BUILD := $(PROJ_ROOT)/build/veer
VEER_FLIST := $(VEER_BUILD)/flist.sw

# VeeR config for SW sims: AXI4 master, no ICCM/DCCM/ICache (all fetches and
# data go over AXI to our RAM; SRAM exports float). Regenerate when
# veer.config changes. Adapter ID widths (3/3/1) match these defaults.
$(VEER_BUILD)/common_defines.vh: $(VEER_ROOT)/configs/veer.config
	@mkdir -p $(VEER_BUILD)
	@echo "[make] generating VeeR config (axi4, no iccm/dccm/icache)..."
	BUILD_PATH=$(VEER_BUILD) $(VEER_ROOT)/configs/veer.config \
	    -target=default -set build_axi4 \
	    -set iccm_enable=0 -set icache_enable=0 -set dccm_enable=0

# Filtered design file list: drop only the testbench-side shim
# (testbench/veer_wrapper.sv) — we instantiate design/el2_veer_wrapper
# directly. NOTE: match the full path; a bare "veer_wrapper.sv" pattern
# also kills design/el2_veer_wrapper.sv and orphans el2_mem/dmi_* as tops.
$(VEER_FLIST): $(VEER_ROOT)/testbench/flist Makefile
	@mkdir -p $(VEER_BUILD)
	@grep -v "testbench/veer_wrapper.sv" $(VEER_ROOT)/testbench/flist > $(VEER_FLIST)

SW_INCDIRS := $(INCDIRS) \
    +incdir+$(VEER_ROOT)/design/include \
    +incdir+$(VEER_ROOT)/design/lib \
    +incdir+$(VEER_BUILD)

# Mirrors Cores-VeeR-EL2/tools/Makefile `defines`: these three must be
# parsed BEFORE -f flist (el2_def.sv defines el2_pkg, needed by
# el2_lockstep_pkg.sv and el2_param.vh).
VEER_DEFS := $(VEER_BUILD)/common_defines.vh \
    $(VEER_ROOT)/design/include/el2_def.sv \
    $(VEER_BUILD)/el2_pdef.vh

sw_FILES = $(SOC) $(UART_IP) $(XBAR) \
    $(PROJ_ROOT)/rtl/soc/veer_axi_adapter.sv \
    $(BFM_TB) \
    $(PROJ_ROOT)/tb/sw/tb_soc_sw.sv
sw_TOP := tb_soc_sw
sw_VCSFLAGS := +define+RV_OPENSOURCE

.PHONY: sw
sw: $(VEER_BUILD)/common_defines.vh $(VEER_FLIST)
	@if [ "$(IP)" != "gpio" -a "$(IP)" != "uart" -a "$(IP)" != "timer" ]; then \
	    echo "usage: make sw IP=gpio|uart|timer"; exit 1; fi
	@mkdir -p $(PROJ_ROOT)/run/sw_$(IP)
	@echo "[make] building SW image for $(IP)..."
	$(PROJ_ROOT)/scripts/build_sw.sh \
	    $(PROJ_ROOT)/sw/$(IP)_test $(PROJ_ROOT)/run/sw_$(IP)
	@echo "[make] compiling sw $(IP) (VeeR + SoC)..."
	@RV_ROOT=$(VEER_ROOT) $(VCS) $(VCS_FLAGS) $(sw_VCSFLAGS) $(DEFINES) $(SW_INCDIRS) \
	    -l $(PROJ_ROOT)/run/sw_$(IP)/compile.log \
	    -o $(PROJ_ROOT)/run/sw_$(IP)/simv \
	    $(VEER_DEFS) \
	    -f $(VEER_FLIST) \
	    $(sw_FILES)
	@echo "[make] simulating sw $(IP)..."
	cd $(PROJ_ROOT)/run/sw_$(IP) && ./simv \
	    -l $(PROJ_ROOT)/run/sw_$(IP)/sim.log \
	    +SW_TEST=$(IP) +SW_HEX=test.hex

# --- unit -----------------------------------------------------------------------
.PHONY: unit
unit:
	@if [ -z "$(IP)" ]; then echo "usage: make unit IP=gpio|timer|uart|ram"; exit 1; fi
	@if [ -z "$($(IP)_TOP)" ]; then echo "unknown IP '$(IP)' (gpio|timer|uart|ram)"; exit 1; fi
	@mkdir -p $(PROJ_ROOT)/run/unit_$(IP)
	@echo "[make] compiling unit $(IP)..."
	$(VCS) $(VCS_FLAGS) $(DEFINES) $(INCDIRS) \
	    -l $(PROJ_ROOT)/run/unit_$(IP)/compile.log \
	    -o $(PROJ_ROOT)/run/unit_$(IP)/simv \
	    $($(IP)_UNIT)
	@echo "[make] simulating unit $(IP)..."
	cd $(PROJ_ROOT)/run/unit_$(IP) && ./simv \
	    -l $(PROJ_ROOT)/run/unit_$(IP)/sim.log

# --- integration ------------------------------------------------------------------
.PHONY: integration
integration:
	@mkdir -p $(PROJ_ROOT)/run/integration
	@echo "[make] compiling integration..."
	$(VCS) $(VCS_FLAGS) $(DEFINES) $(INCDIRS) \
	    -l $(PROJ_ROOT)/run/integration/compile.log \
	    -o $(PROJ_ROOT)/run/integration/simv \
	    $(integration_FILES)
	@echo "[make] simulating integration..."
	cd $(PROJ_ROOT)/run/integration && ./simv \
	    -l $(PROJ_ROOT)/run/integration/sim.log

# --- verdi --------------------------------------------------------------------------
# NOTE: LEVEL/IP dispatch uses shell conditionals (make `ifeq` cannot appear
# inside a recipe). $($(IP)_UNIT)/$($(IP)_TOP) still expand at parse time.
.PHONY: verdi
verdi:
	@if [ -z "$(LEVEL)" ]; then echo "usage: make verdi LEVEL=unit IP=gpio|timer|uart|ram | LEVEL=integration | LEVEL=sw IP=gpio|uart|timer"; exit 1; fi
	@if [ "$(LEVEL)" = "unit" ]; then \
	    if [ -z "$(IP)" -o -z "$($(IP)_TOP)" ]; then echo "unit needs IP=gpio|timer|uart|ram"; exit 1; fi; \
	    mkdir -p $(PROJ_ROOT)/run/unit_$(IP); \
	    echo "[make] compiling unit $(IP) with FSDB..."; \
	$(VCS) $(VCS_FLAGS_VERDI) $(DEFINES) $(INCDIRS) \
	        -l $(PROJ_ROOT)/run/unit_$(IP)/compile.log \
	        -o $(PROJ_ROOT)/run/unit_$(IP)/simv \
	        $($(IP)_UNIT); \
	    echo "[make] simulating unit $(IP)..."; \
	    cd $(PROJ_ROOT)/run/unit_$(IP) && ./simv -l sim.log; \
	    echo "[make] opening Verdi (no .rc yet — add waves/unit_$(IP).rc later)..."; \
	    $(VERDI) -dbdir $(PROJ_ROOT)/run/unit_$(IP)/simv.daidir \
	             -ssf $(PROJ_ROOT)/run/unit_$(IP)/$($(IP)_TOP).fsdb & \
	elif [ "$(LEVEL)" = "integration" ]; then \
	    mkdir -p $(PROJ_ROOT)/run/integration; \
	    echo "[make] compiling integration with FSDB..."; \
	$(VCS) $(VCS_FLAGS_VERDI) $(DEFINES) $(INCDIRS) \
	        -l $(PROJ_ROOT)/run/integration/compile.log \
	        -o $(PROJ_ROOT)/run/integration/simv \
	        $(integration_FILES); \
	    echo "[make] simulating integration..."; \
	    cd $(PROJ_ROOT)/run/integration && ./simv -l sim.log; \
	    echo "[make] opening Verdi (no .rc yet — add waves/integration.rc later)..."; \
	    $(VERDI) -dbdir $(PROJ_ROOT)/run/integration/simv.daidir \
	             -ssf $(PROJ_ROOT)/run/integration/$(integration_TOP).fsdb & \
	elif [ "$(LEVEL)" = "sw" ]; then \
	    if [ "$(IP)" != "gpio" -a "$(IP)" != "uart" -a "$(IP)" != "timer" ]; then echo "sw needs IP=gpio|uart|timer"; exit 1; fi; \
	    $(MAKE) --no-print-directory $(VEER_BUILD)/common_defines.vh $(VEER_FLIST); \
	    mkdir -p $(PROJ_ROOT)/run/sw_$(IP); \
	    echo "[make] building SW image for $(IP)..."; \
	    $(PROJ_ROOT)/scripts/build_sw.sh $(PROJ_ROOT)/sw/$(IP)_test $(PROJ_ROOT)/run/sw_$(IP); \
	    echo "[make] compiling sw $(IP) with FSDB..."; \
	    RV_ROOT=$(VEER_ROOT) $(VCS) $(VCS_FLAGS_VERDI) $(sw_VCSFLAGS) $(DEFINES) $(SW_INCDIRS) \
	        -l $(PROJ_ROOT)/run/sw_$(IP)/compile.log \
	        -o $(PROJ_ROOT)/run/sw_$(IP)/simv \
	        $(VEER_DEFS) \
	        -f $(VEER_FLIST) \
	        $(sw_FILES); \
	    echo "[make] simulating sw $(IP)..."; \
	    cd $(PROJ_ROOT)/run/sw_$(IP) && ./simv -l sim.log +SW_TEST=$(IP) +SW_HEX=test.hex; \
	    echo "[make] opening Verdi (no .rc yet — add waves/sw.rc later)..."; \
	    $(VERDI) -dbdir $(PROJ_ROOT)/run/sw_$(IP)/simv.daidir \
	             -ssf $(PROJ_ROOT)/run/sw_$(IP)/$(sw_TOP).fsdb & \
	else \
	    echo "unknown LEVEL '$(LEVEL)' (unit|integration|sw)"; exit 1; \
	fi

# --- clean ----------------------------------------------------------------------------
.PHONY: clean
clean:
	@echo "[make] removing run/ and build/..."
	rm -rf $(PROJ_ROOT)/run $(PROJ_ROOT)/build
	@echo "[make] done."
