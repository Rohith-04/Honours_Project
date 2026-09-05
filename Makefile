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
    $(PROJ_ROOT)/rtl/soc/axi_stub_mem.sv \
    $(PROJ_ROOT)/rtl/soc/honours_soc.sv \
    $(PROJ_ROOT)/tb/tb_honours_soc.sv
top_INCDIRS  := \
    +incdir+$(top_GEN) \
    +incdir+$(RV_ROOT)/design/include \
    +incdir+$(RV_ROOT)/design/lib \
    +incdir+$(RV_ROOT)/testbench \
    +incdir+$(PROJ_ROOT)/ips/uart/src/include
top_RC       := $(PROJ_ROOT)/waves/top.rc

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

# top needs generated headers before compile+sim
top.sim top.verdi: top-gen

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
# Help
# ---------------------------------------------------------------------------
.PHONY: help
help:
	@echo ""
	@echo "Usage:"
	@echo "  make <module>.sim       Compile + simulate"
	@echo "  make <module>.verdi     Compile + simulate + open Verdi"
	@echo "  make <module>.clean     Remove run/<module>/ only"
	@echo "  make clean              Remove entire run/ directory"
	@echo ""
	@echo "Available modules:"
	@echo "  interconnect            tb_axi_interconnect_5x16  (waves/axi_interconnect_5x16.rc)"
	@echo "  uart                    tb_uart_wrap              (waves/uart.rc)"
	@echo "  top                     tb_honours_soc            (waves/top.rc)"
	@echo "  nda                     (not yet — add tb and waves/*.rc first)"
	@echo ""
	@echo "Examples:"
	@echo "  make interconnect.sim"
	@echo "  make interconnect.verdi"
	@echo "  make interconnect.clean"
	@echo "  make clean"
	@echo ""
