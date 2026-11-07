# Separate passive/software flow. Example: make -C uvm sw-gpio
PASSIVE_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
UVM_ROOT := $(abspath $(PASSIVE_ROOT)/..)
PROJ_ROOT := $(abspath $(UVM_ROOT)/..)
VCS_HOME ?= /home/student/snps_tools_target/vcs/U-2023.03
VERDI_HOME ?= /home/student/snps_tools_target/verdi/U-2023.03-SP1
export VCS_HOME
SW_PROGRAM ?= gpio_test
UVM_TEST ?= gpio_sw_test
HPM ?= 1
SEED ?= 1
WAVES ?= 0
SIM_ARGS ?=
RUN_ROOT ?= $(PROJ_ROOT)/run/uvm/gpio_sw$(if $(filter 0,$(HPM)),_nohpm,)
PROGRAM_DIR := $(if $(filter /%,$(SW_PROGRAM)),$(SW_PROGRAM),$(PROJ_ROOT)/sw/$(SW_PROGRAM))
PROGRAM_NAME := $(notdir $(patsubst %/,%,$(PROGRAM_DIR)))
BUILD_DIR := $(RUN_ROOT)/build$(if $(filter 1,$(WAVES)),_waves,)
TEST_DIR := $(RUN_ROOT)/$(PROGRAM_NAME)/seed_$(SEED)$(if $(filter 1,$(WAVES)),_waves,)
VEER_ROOT := $(PROJ_ROOT)/Cores-VeeR-EL2
VEER_BUILD := $(RUN_ROOT)/veer_config
VEER_CONFIG := $(VEER_BUILD)/common_defines.vh
VEER_FLIST := $(VEER_BUILD)/flist.sw
VCS_FLAGS := -full64 -sverilog -timescale=1ns/1ps -ntb_opts uvm-1.2 -nc +define+RV_OPENSOURCE
ifeq ($(HPM),0)
VCS_FLAGS += +define+SOC_DISABLE_HPM
else ifneq ($(HPM),1)
$(error HPM must be 0 or 1)
endif
ifeq ($(WAVES),1)
VCS_FLAGS += -debug_access+all -kdb +define+FSDB_DUMP \
    -P $(VERDI_HOME)/share/PLI/VCS/LINUX64/novas.tab \
       $(VERDI_HOME)/share/PLI/VCS/LINUX64/pli.a
endif
INCLUDES := +incdir+$(PROJ_ROOT)/tb/common +incdir+$(PROJ_ROOT)/ips/uart/src/include \
    +incdir+$(VEER_ROOT)/design/include +incdir+$(VEER_ROOT)/design/lib \
    +incdir+$(VEER_BUILD) +incdir+$(UVM_ROOT)/gpio

# Match the root software flow's integration sources. The core's generated
# configuration/file-list rules are reused below instead of reimplemented.
SOC_FILES := $(PROJ_ROOT)/rtl/soc/soc_pkg.sv \
    $(PROJ_ROOT)/rtl/mem/axi_ram.sv \
    $(PROJ_ROOT)/rtl/wrappers/uart_wrapper.sv \
    $(PROJ_ROOT)/rtl/wrappers/timer_wrapper.sv \
    $(PROJ_ROOT)/rtl/wrappers/gpio_wrapper.sv \
    $(PROJ_ROOT)/rtl/wrappers/nda_wrapper.sv \
    $(PROJ_ROOT)/rtl/wrappers/wdt_wrapper.sv \
    $(PROJ_ROOT)/rtl/wrappers/hpm_wrapper.sv \
    $(PROJ_ROOT)/rtl/soc/honours_soc.sv \
    $(PROJ_ROOT)/rtl/soc/veer_axi_adapter.sv
UART_FILES := $(addprefix $(PROJ_ROOT)/ips/uart/src/rtl/,uart_parity_bit_compute.v \
    uart_receiver.v uart_transmitter.v uart_controller.v axi_internal_fifo.v axi_uart_top.v)
XBAR_FILES := $(addprefix $(PROJ_ROOT)/rtl/interconnect/,priority_encoder.v arbiter.v \
    axi_interconnect.v axi_interconnect_wrap_1x4.v axi_interconnect_wrap_2x7.v axi_interconnect_wrap_2x6.v)
VIP_FILES := $(UVM_ROOT)/gpio/gpio_axi_if.sv $(UVM_ROOT)/gpio/gpio_pin_if.sv \
    $(UVM_ROOT)/gpio/gpio_vip_pkg.sv $(PASSIVE_ROOT)/gpio_sw_status_if.sv \
    $(PASSIVE_ROOT)/gpio_sw_pkg.sv
TB_FILES := $(PROJ_ROOT)/bfm/axi_master_bfm.sv $(PROJ_ROOT)/tb/common/tb_pkg.sv \
    $(PROJ_ROOT)/tb/sw/tb_soc_sw.sv $(PASSIVE_ROOT)/tb_gpio_sw_uvm.sv
DESIGN_FILES := $(SOC_FILES) $(UART_FILES) $(XBAR_FILES) $(VIP_FILES) $(TB_FILES)
# Invalidate the cached simulator when core sources or include files change.
CORE_DEPENDENCIES := $(wildcard $(VEER_ROOT)/design/*.sv $(VEER_ROOT)/design/*/*.sv \
    $(VEER_ROOT)/design/*/*.v $(VEER_ROOT)/design/*/*.vh \
    $(VEER_ROOT)/verification/block/dcls/*.sv) \
    $(VEER_ROOT)/testbench/axi_lsu_dma_bridge.sv $(VEER_ROOT)/testbench/user_cells.sv
UART_HEADERS := $(wildcard $(PROJ_ROOT)/ips/uart/src/include/*.vh)

.PHONY: gpio compile regression verdi help
gpio: compile
	@test -f $(PROGRAM_DIR)/main.c || { echo "Missing C program: $(PROGRAM_DIR)/main.c"; exit 1; }
	@mkdir -p $(TEST_DIR)
	HAVE_HPM=$(HPM) $(PROJ_ROOT)/scripts/build_sw.sh $(PROGRAM_DIR) $(TEST_DIR)
	cd $(TEST_DIR) && $(BUILD_DIR)/simv -l sim.log +UVM_TESTNAME=$(UVM_TEST) \
	    +SW_TEST=gpio +SW_HEX=test.hex +ntb_random_seed=$(SEED) $(SIM_ARGS)
	python3 -B $(UVM_ROOT)/scripts/check_uvm.py $(TEST_DIR)/sim.log $(UVM_TEST)

compile: $(BUILD_DIR)/simv
$(VEER_CONFIG): $(VEER_ROOT)/configs/veer.config $(VEER_ROOT)/tools/picmap $(PROJ_ROOT)/Makefile
	$(MAKE) -C $(PROJ_ROOT) VEER_BUILD=$(VEER_BUILD) $(VEER_CONFIG)
$(VEER_FLIST): $(VEER_ROOT)/testbench/flist $(PROJ_ROOT)/Makefile
	$(MAKE) -C $(PROJ_ROOT) VEER_BUILD=$(VEER_BUILD) $(VEER_FLIST)

$(BUILD_DIR)/simv: $(VEER_CONFIG) $(VEER_FLIST) $(DESIGN_FILES) \
    $(CORE_DEPENDENCIES) $(UART_HEADERS) $(wildcard $(UVM_ROOT)/gpio/*.svh) \
    $(PROJ_ROOT)/tb/common/tb_tasks.svh $(PASSIVE_ROOT)/Makefile
	@test -s $(VEER_BUILD)/pic_map_auto.h || { echo "Missing/empty VeeR PIC map"; exit 1; }
	@mkdir -p $(BUILD_DIR)
	cd $(BUILD_DIR) && RV_ROOT=$(VEER_ROOT) $(VCS_HOME)/bin/vcs $(VCS_FLAGS) \
	    -top tb_gpio_sw_uvm -Mdir=$(BUILD_DIR)/csrc $(INCLUDES) -l compile.log -o $(BUILD_DIR)/simv \
	    $(VEER_CONFIG) $(VEER_ROOT)/design/include/el2_def.sv $(VEER_BUILD)/el2_pdef.vh \
	    -f $(VEER_FLIST) $(DESIGN_FILES)

regression: compile
	$(MAKE) --no-print-directory gpio SW_PROGRAM=gpio_test
	$(MAKE) --no-print-directory gpio SW_PROGRAM=gpio_uvm_test

# View paths are independent of WAVES: this target only opens an existing dump.
verdi:
	@test -f $(RUN_ROOT)/$(PROGRAM_NAME)/seed_$(SEED)_waves/tb_gpio_sw_uvm.fsdb || { echo "Generate with sw-gpio WAVES=1 and matching SW_PROGRAM/SEED/RUN_ROOT first"; exit 1; }
	cd $(RUN_ROOT)/$(PROGRAM_NAME)/seed_$(SEED)_waves && $(VERDI_HOME)/bin/verdi \
	    -dbdir $(RUN_ROOT)/build_waves/simv.daidir \
	    -ssf $(RUN_ROOT)/$(PROGRAM_NAME)/seed_$(SEED)_waves/tb_gpio_sw_uvm.fsdb \
	    -sswr $(PASSIVE_ROOT)/waves.rc

help:
	@printf '%s\n' \
	    'Passive software GPIO UVM: CPU owns AXI; UVM only observes.' \
	    'make -C uvm sw-gpio                         Existing sw/gpio_test C program' \
	    'make -C uvm sw-gpio SW_PROGRAM=gpio_uvm_test Expanded walking/direction C test' \
	    'make -C uvm sw-regression                   Run both C programs' \
	    'make -C uvm sw-gpio HPM=0                   Verify the 2x6 build' \
	    'make -C uvm sw-gpio WAVES=1                 Generate software FSDB/KDB' \
	    'make -C uvm sw-verdi                        Open its saved waveform groups' \
	    'Options: SW_PROGRAM (name in sw/ or absolute directory), SEED, HPM=0|1,' \
	    'WAVES=0|1, RUN_ROOT=/absolute/path, SIM_ARGS, VCS_HOME, VERDI_HOME.' \
	    'RUN_ROOT defaults to <project>/run/uvm/gpio_sw (gpio_sw_nohpm for HPM=0).' \
	    'Software builds regenerate the tracked sw/common/soc_map.h.' \
	    'See uvm/gpio_sw/README.md for ownership, coverage, and remaining limits.'
