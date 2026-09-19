# =============================================================================
# Makefile — Honours Project VCS simulation
#
# Usage:
#   make <module>.sim       compile + simulate
#   make <module>.verdi     compile + simulate + open Verdi
#   make <module>.clean     remove run/<module>/ only
#   make clean              remove entire run/ directory
#
# Examples:
#   make interconnect.sim
#   make interconnect.verdi
#   make top.sim
#   make interconnect.clean
#   make clean
#
# Adding a new module:
#   1. Add tb/tb_<module>.sv
#   2. Add waves/<module>.rc
#   3. Add <module>_TOP, <module>_FILES, <module>_RC entries below
# =============================================================================

PROJ_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# VeeR EL2 root (used for $RV_ROOT expansion inside design/flist)
export RV_ROOT := $(PROJ_ROOT)/Cores-VeeR-EL2

.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# Tool settings
# ---------------------------------------------------------------------------
VCS   := vcs
VERDI := verdi

VERDI_HOME  ?= $(shell echo $$VERDI_HOME)
FSDB_PLI     = $(VERDI_HOME)/share/PLI/VCS/LINUX64

VCS_FLAGS := \
    -full64                                  \
    -sverilog                                \
    -timescale=1ns/1ps                       \
    +define+FSDB                             \
    -kdb                                     \
    +vcs+lic+wait                            \
    -debug_access+all                        \
    -debug_region+cell                       \
    -P $(FSDB_PLI)/novas.tab                 \
    $(FSDB_PLI)/pli.a

# ---------------------------------------------------------------------------
# Module definitions
# ---------------------------------------------------------------------------

# --- interconnect ---
interconnect_TOP   := tb_axi_interconnect_5x16
interconnect_FILES := \
    $(PROJ_ROOT)/rtl/interconnect/priority_encoder.v \
    $(PROJ_ROOT)/rtl/interconnect/arbiter.v          \
    $(PROJ_ROOT)/rtl/interconnect/axi_interconnect.v \
    $(PROJ_ROOT)/rtl/interconnect/axi_interconnect_wrap_5x16.v \
    $(PROJ_ROOT)/tb/tb_axi_interconnect_5x16.sv
interconnect_RC    := $(PROJ_ROOT)/waves/axi_interconnect_5x16.rc

# --- uart ---
uart_TOP     := tb_uart_wrap
uart_FILES   := \
    $(PROJ_ROOT)/ips/uart/src/rtl/uart_parity_bit_compute.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/uart_receiver.v           \
    $(PROJ_ROOT)/ips/uart/src/rtl/uart_transmitter.v        \
    $(PROJ_ROOT)/ips/uart/src/rtl/uart_controller.v         \
    $(PROJ_ROOT)/ips/uart/src/rtl/axi_internal_fifo.v       \
    $(PROJ_ROOT)/ips/uart/src/rtl/axi_uart_top.v            \
    $(PROJ_ROOT)/rtl/uart/uart_wrap.sv                      \
    $(PROJ_ROOT)/tb/tb_uart_wrap.sv
uart_INCDIRS := +incdir+$(PROJ_ROOT)/ips/uart/src/include
uart_RC      := $(PROJ_ROOT)/waves/uart.rc

# --- nda (uncomment when ready) ---
# nda_TOP   := tb_nda_reduction_engine
# nda_FILES := \
#     $(PROJ_ROOT)/rtl/nda/nda_reduction_engine.sv \
#     $(PROJ_ROOT)/tb/tb_nda_reduction_engine.sv
# nda_RC    := $(PROJ_ROOT)/waves/nda.rc

# --- top (full SoC, structural bring-up) ---
top_GEN      := $(PROJ_ROOT)/run/top/veer_gen
top_TOP      := tb_honours_soc
top_FILES    := \
    $(top_GEN)/common_defines.vh \
    $(RV_ROOT)/design/include/el2_def.sv \
    $(RV_ROOT)/design/el2_lockstep_pkg.sv \
    -f $(RV_ROOT)/design/flist \
    $(PROJ_ROOT)/rtl/interconnect/priority_encoder.v \
    $(PROJ_ROOT)/rtl/interconnect/arbiter.v \
    $(PROJ_ROOT)/rtl/interconnect/axi_interconnect.v \
    $(PROJ_ROOT)/rtl/interconnect/axi_interconnect_wrap_5x16.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/uart_parity_bit_compute.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/uart_receiver.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/uart_transmitter.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/uart_controller.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/axi_internal_fifo.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/axi_uart_top.v \
    $(PROJ_ROOT)/rtl/uart/uart_wrap.sv \
    $(PROJ_ROOT)/rtl/soc/axi64_to_32_bridge.sv \
    $(PROJ_ROOT)/rtl/soc/axi_true_mem.sv \
    $(PROJ_ROOT)/rtl/soc/honours_soc.sv \
    $(PROJ_ROOT)/tb/tb_honours_soc.sv
top_INCDIRS  := \
    +incdir+$(top_GEN) \
    +incdir+$(RV_ROOT)/design/include \
    +incdir+$(RV_ROOT)/design/lib \
    +incdir+$(RV_ROOT)/testbench \
    +incdir+$(PROJ_ROOT)/ips/uart/src/include \
    +incdir+$(PROJ_ROOT)/tb
top_RC       := $(PROJ_ROOT)/waves/top.rc

# --- mid (SoC middle layer: SB-routed UART via s03, same RTL as top) ---
mid_GEN      := $(top_GEN)
mid_TOP      := tb_core_uart
mid_FILES    := \
    $(top_GEN)/common_defines.vh \
    $(RV_ROOT)/design/include/el2_def.sv \
    $(RV_ROOT)/design/el2_lockstep_pkg.sv \
    -f $(RV_ROOT)/design/flist \
    $(PROJ_ROOT)/rtl/interconnect/priority_encoder.v \
    $(PROJ_ROOT)/rtl/interconnect/arbiter.v \
    $(PROJ_ROOT)/rtl/interconnect/axi_interconnect.v \
    $(PROJ_ROOT)/rtl/interconnect/axi_interconnect_wrap_5x16.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/uart_parity_bit_compute.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/uart_receiver.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/uart_transmitter.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/uart_controller.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/axi_internal_fifo.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/axi_uart_top.v \
    $(PROJ_ROOT)/rtl/uart/uart_wrap.sv \
    $(PROJ_ROOT)/rtl/soc/axi64_to_32_bridge.sv \
    $(PROJ_ROOT)/rtl/soc/axi_true_mem.sv \
    $(PROJ_ROOT)/rtl/soc/honours_soc.sv \
    $(PROJ_ROOT)/tb/tb_core_uart.sv
mid_INCDIRS  := $(top_INCDIRS)
mid_RC       := $(PROJ_ROOT)/waves/mid.rc

# --- usw (single SW test: core executes, byte on uart_tx, no tasks/forces) ---
usw_GEN      := $(top_GEN)
usw_TOP      := tb_uart_sw_simple
usw_FILES    := \
    $(top_GEN)/common_defines.vh \
    $(RV_ROOT)/design/include/el2_def.sv \
    $(RV_ROOT)/design/el2_lockstep_pkg.sv \
    -f $(RV_ROOT)/design/flist \
    $(PROJ_ROOT)/rtl/interconnect/priority_encoder.v \
    $(PROJ_ROOT)/rtl/interconnect/arbiter.v \
    $(PROJ_ROOT)/rtl/interconnect/axi_interconnect.v \
    $(PROJ_ROOT)/rtl/interconnect/axi_interconnect_wrap_5x16.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/uart_parity_bit_compute.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/uart_receiver.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/uart_transmitter.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/uart_controller.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/axi_internal_fifo.v \
    $(PROJ_ROOT)/ips/uart/src/rtl/axi_uart_top.v \
    $(PROJ_ROOT)/rtl/uart/uart_wrap.sv \
    $(PROJ_ROOT)/rtl/soc/axi64_to_32_bridge.sv \
    $(PROJ_ROOT)/rtl/soc/axi_true_mem.sv \
    $(PROJ_ROOT)/rtl/soc/honours_soc.sv \
    $(PROJ_ROOT)/tb/tb_uart_sw_simple.sv
usw_INCDIRS  := $(top_INCDIRS)
usw_RC       := $(PROJ_ROOT)/waves/usw.rc

# UART SW image (built by sw/uart_test/Makefile)
UART_SW_HEX  := $(PROJ_ROOT)/sw/uart_test/build/uart_test.hex

# VeeR config headers (el2_param.vh / el2_pdef.vh / common_defines.vh) are
# generated on demand into run/top/veer_gen (git-ignored, survives .clean
# of other modules). Regenerate with `make top-gen` after veer.config edits.
.PHONY: top-gen
top-gen:
	@mkdir -p $(top_GEN)
	@if [ ! -f "$(top_GEN)/el2_param.vh" ]; then \
	    echo "[make] Generating VeeR config headers..."; \
	    BUILD_PATH=$(top_GEN) $(RV_ROOT)/configs/veer.config -target=default; \
	else \
	    echo "[make] VeeR headers up to date: $(top_GEN)"; \
	fi

# top/mid/usw need generated headers before compile+sim
top.sim top.verdi mid.sim mid.verdi usw.sim usw.verdi: top-gen

# ---------------------------------------------------------------------------
# Pattern rules:  make <module>.sim | <module>.verdi | <module>.clean
# ---------------------------------------------------------------------------

# Derive module name from the stem before the dot
define module_vars
  MOD      := $(1)
  TOP      := $($(1)_TOP)
  FILES    := $($(1)_FILES)
  INCDIRS  := $($(1)_INCDIRS)
  RC       := $($(1)_RC)
  RUNDIR   := $(PROJ_ROOT)/run/$(1)
  SIMV     := $(PROJ_ROOT)/run/$(1)/simv
  FSDB     := $(PROJ_ROOT)/run/$(1)/$($(1)_TOP).fsdb
endef

%.sim:
	$(eval $(call module_vars,$*))
	@if [ -z "$(TOP)" ]; then echo "ERROR: module '$*' not defined in Makefile"; exit 1; fi
	@mkdir -p $(RUNDIR)
	@echo "[make] Compiling $(MOD) (top: $(TOP))..."
	$(VCS) $(VCS_FLAGS) \
	    $(INCDIRS) \
	    -l $(RUNDIR)/compile.log \
	    -o $(SIMV) \
	    $(FILES)
	@echo "[make] Compile done. Log: $(RUNDIR)/compile.log"
	@echo "[make] Simulating $(MOD)..."
	cd $(RUNDIR) && $(SIMV) \
	    +vcs+fsdbon \
	    +vcs+lic+wait \
	    -l $(RUNDIR)/sim.log
	@echo "[make] Simulation done. FSDB: $(FSDB)"

%.verdi:
	$(eval $(call module_vars,$*))
	@if [ -z "$(TOP)" ]; then echo "ERROR: module '$*' not defined in Makefile"; exit 1; fi
	@mkdir -p $(RUNDIR)
	@echo "[make] Compiling $(MOD) (top: $(TOP))..."
	$(VCS) $(VCS_FLAGS) \
	    $(INCDIRS) \
	    -l $(RUNDIR)/compile.log \
	    -o $(SIMV) \
	    $(FILES)
	@echo "[make] Compile done."
	@echo "[make] Simulating $(MOD)..."
	cd $(RUNDIR) && $(SIMV) \
	    +vcs+fsdbon \
	    +vcs+lic+wait \
	    -l $(RUNDIR)/sim.log
	@echo "[make] Opening Verdi..."
	@if [ -f "$(RC)" ]; then \
	    $(VERDI) \
	        -dbdir $(SIMV).daidir \
	        -ssf   $(FSDB) \
	        -sswr  $(RC) \
	        & \
	else \
	    echo "WARNING: $(RC) not found, opening without signal groups."; \
	    $(VERDI) \
	        -dbdir $(SIMV).daidir \
	        -ssf   $(FSDB) \
	        & \
	fi

%.clean:
	$(eval MOD := $*)
	@echo "[make] Cleaning run/$(MOD)/..."
	rm -rf $(PROJ_ROOT)/run/$(MOD)
	@echo "[make] Done."

# ---------------------------------------------------------------------------
# Global clean — wipe entire run/ directory (waves/ is never touched)
# ---------------------------------------------------------------------------
.PHONY: clean
clean:
	@echo "[make] Cleaning entire run/ directory..."
	rm -rf $(PROJ_ROOT)/run
	@echo "[make] Done."

# ---------------------------------------------------------------------------
# Single-command SW test: `make usw` — builds C image, runs simple TB.
# TB = tb_uart_sw_simple (core executes, byte on uart_tx, no tasks/forces).
# ---------------------------------------------------------------------------
.PHONY: usw
usw: top-gen
	@echo "[make] Building uart_test image..."
	@$(MAKE) -C $(PROJ_ROOT)/sw/uart_test
	@if [ ! -f "$(UART_SW_HEX)" ]; then echo "ERROR: $(UART_SW_HEX) not built"; exit 1; fi
	@mkdir -p $(PROJ_ROOT)/run/usw
	@echo "[make] Compiling usw (top: $(usw_TOP))..."
	$(VCS) $(VCS_FLAGS) \
	    $(usw_INCDIRS) \
	    -l $(PROJ_ROOT)/run/usw/compile.log \
	    -o $(PROJ_ROOT)/run/usw/simv \
	    $(usw_FILES)
	@echo "[make] Compile done. Log: $(PROJ_ROOT)/run/usw/compile.log"
	@echo "[make] Simulating usw (SW_HEX=$(UART_SW_HEX))..."
	cd $(PROJ_ROOT)/run/usw && $(PROJ_ROOT)/run/usw/simv \
	    +vcs+fsdbon \
	    +vcs+lic+wait \
	    +SW_HEX=$(UART_SW_HEX) \
	    -l $(PROJ_ROOT)/run/usw/sim.log
	@echo "[make] Simulation done. Log: $(PROJ_ROOT)/run/usw/sim.log FSDB: $(PROJ_ROOT)/run/usw/$(usw_TOP).fsdb"

# ---------------------------------------------------------------------------
# UART SW test: `make uart.sw` — build C image, run core-driven UART on SoC
# Uses the mid simv (tb_core_uart + true RAM) with +SW_HEX=<image>.
# ---------------------------------------------------------------------------
.PHONY: uart.sw uart.sw.clean
uart.sw: top-gen
	@echo "[make] Building uart_test image..."
	@$(MAKE) -C $(PROJ_ROOT)/sw/uart_test
	@if [ ! -f "$(UART_SW_HEX)" ]; then echo "ERROR: $(UART_SW_HEX) not built"; exit 1; fi
	@mkdir -p $(PROJ_ROOT)/run/mid
	@echo "[make] Compiling mid (top: $(mid_TOP))..."
	$(VCS) $(VCS_FLAGS) \
	    $(mid_INCDIRS) \
	    -l $(PROJ_ROOT)/run/mid/compile.log \
	    -o $(PROJ_ROOT)/run/mid/simv \
	    $(mid_FILES)
	@echo "[make] Compile done. Log: $(PROJ_ROOT)/run/mid/compile.log"
	@echo "[make] Simulating uart.sw (SW_HEX=$(UART_SW_HEX))..."
	cd $(PROJ_ROOT)/run/mid && $(PROJ_ROOT)/run/mid/simv \
	    +vcs+fsdbon \
	    +vcs+lic+wait \
	    +SW_HEX=$(UART_SW_HEX) \
	    -l $(PROJ_ROOT)/run/mid/sw.log
	@echo "[make] Simulation done. Log: $(PROJ_ROOT)/run/mid/sw.log FSDB: $(PROJ_ROOT)/run/mid/$(mid_TOP).fsdb"

uart.sw.clean:
	@echo "[make] Cleaning sw/uart_test/build/..."
	rm -rf $(PROJ_ROOT)/sw/uart_test/build
	@echo "[make] Done."

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
.PHONY: help
help:
	@echo ""
	@echo "Usage:"
	@echo "  make <module>.sim       Compile + simulate"
	@echo "  make <module>.verdi     Compile + simulate + open Verdi"
	@echo "  make <module>.clean     Remove run/<module>/ only"
	@echo "  make uart.sw            Build uart_test C image + core-driven SoC run"
	@echo "  make uart.sw.clean      Remove sw/uart_test/build/ only"
	@echo "  make clean              Remove entire run/ directory"
	@echo ""
	@echo "Available modules:"
	@echo "  interconnect            tb_axi_interconnect_5x16  (waves/axi_interconnect_5x16.rc)"
	@echo "  uart                    tb_uart_wrap              (waves/uart.rc)"
	@echo "  top                     tb_honours_soc            (waves/top.rc)"
	@echo "  mid                     tb_core_uart              (waves/mid.rc)"
	@echo "  usw                     tb_uart_sw_simple         (waves/usw.rc)"
	@echo "  nda                     (not yet — add tb and waves/*.rc first)"
	@echo ""
	@echo "Examples:"
	@echo "  make interconnect.sim"
	@echo "  make interconnect.verdi"
	@echo "  make interconnect.clean"
	@echo "  make mid.sim            SB-routed middle layer (no SW image)"
	@echo "  make uart.sw            SW-driven UART (VeeR executes C image)"
	@echo "  make clean"
	@echo ""
