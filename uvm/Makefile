# From the project root: make -C uvm gpio TEST=gpio_pipeline_test SEED=1
# Outputs stay in the ignored root run/ tree; no legacy BFM/RTL is rewritten.
UVM_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PROJ_ROOT := $(abspath $(UVM_ROOT)/..)
VCS_HOME ?= /home/student/snps_tools_target/vcs/U-2023.03
VERDI_HOME ?= /home/student/snps_tools_target/verdi/U-2023.03-SP1
export VCS_HOME
VCS := $(VCS_HOME)/bin/vcs
TEST ?= gpio_smoke_test
SEED ?= 1
WAVES ?= 0
RUN_ROOT ?= $(PROJ_ROOT)/run/uvm/gpio
BUILD_DIR := $(RUN_ROOT)/build$(if $(filter 1,$(WAVES)),_waves,)
TEST_DIR := $(RUN_ROOT)/$(TEST)/seed_$(SEED)$(if $(filter 1,$(WAVES)),_waves,)
SIM_ARGS ?=
WAVE_VIEW ?= $(UVM_ROOT)/waves/gpio.rc
# The viewer always opens an FSDB-enabled run, even without WAVES=1 on its
# command line. WAVES continues to control compile/simulation targets.
VERDI_BUILD_DIR = $(RUN_ROOT)/build_waves
VERDI_TEST_DIR = $(RUN_ROOT)/$(TEST)/seed_$(SEED)_waves
VCS_FLAGS := -full64 -sverilog -timescale=1ns/1ps -ntb_opts uvm-1.2 -nc
ifeq ($(WAVES),1)
VCS_FLAGS += -debug_access+all -kdb +define+FSDB_DUMP \
    -P $(VERDI_HOME)/share/PLI/VCS/LINUX64/novas.tab \
       $(VERDI_HOME)/share/PLI/VCS/LINUX64/pli.a
endif
GPIO_FILES := $(PROJ_ROOT)/rtl/soc/soc_pkg.sv \
    $(PROJ_ROOT)/rtl/wrappers/gpio_wrapper.sv \
    $(UVM_ROOT)/gpio/gpio_axi_if.sv $(UVM_ROOT)/gpio/gpio_pin_if.sv \
    $(UVM_ROOT)/gpio/gpio_vip_pkg.sv $(UVM_ROOT)/gpio/tb_gpio_uvm.sv
GPIO_HEADERS := $(wildcard $(UVM_ROOT)/gpio/*.svh)
GPIO_PLAN_TESTS := soc_gpio_out_test soc_gpio_dir_test soc_gpio_walking_test
GPIO_TESTS := gpio_smoke_test gpio_pipeline_test gpio_factory_test $(GPIO_PLAN_TESTS)

.PHONY: gpio compile regression plan-regression verdi check-log-parser help sw-gpio sw-regression sw-verdi sw-help
gpio: compile
	@mkdir -p $(TEST_DIR)
	cd $(TEST_DIR) && $(BUILD_DIR)/simv -l sim.log \
	    +UVM_TESTNAME=$(TEST) +ntb_random_seed=$(SEED) $(SIM_ARGS)
	python3 -B $(UVM_ROOT)/scripts/check_uvm.py $(TEST_DIR)/sim.log $(TEST)

# Keep gpio as the default target; help only prints usage and never builds.
help:
	@printf '%s\n' \
	    'Usage (from the project root): make -C uvm <target> [VARIABLE=value ...]' \
	    '' \
	    'Targets:' \
	    '  gpio              Compile, simulate, and validate one GPIO test (default)' \
	    '  compile           Compile the GPIO UVM testbench without running it' \
	    '  regression        Run all six GPIO tests; stop on failure' \
	    '  plan-regression   Run SOC-027/028/029 tests with the resolved pad model' \
	    '  check-log-parser  Run the simulation-log validator tests' \
	    '  verdi             Open an existing wave run with grouped signals loaded' \
	    '  help              Show this help without invoking VCS or Verdi' \
	    '  sw-gpio           Separate passive UVM test: C runs on VeeR' \
	    '  sw-regression     Run original and expanded GPIO C programs with passive UVM' \
	    '  sw-verdi          Open the software-driven waveform view' \
	    '  sw-help           Show passive software-flow options' \
	    '' \
	    'Tests (TEST=...):' \
	    '  gpio_smoke_test     Register, pin, strobe, and error checks (default)' \
	    '  gpio_pipeline_test  Smoke plus queued requests and channel overlap' \
	    '  gpio_factory_test   Pipeline with a factory override for longer stalls' \
	    '  soc_gpio_out_test   SOC-027: output patterns, IN loopback, upper bits' \
	    '  soc_gpio_dir_test   SOC-028: direction switching and pad contention' \
	    '  soc_gpio_walking_test SOC-029: full walking/alternating pattern sweep' \
	    '' \
	    'Options:' \
	    '  SEED=1             Simulator random seed (default: 1)' \
	    '  WAVES=0|1          Enable FSDB and Verdi debug compilation (default: 0)' \
	    '  SIM_ARGS="..."     Extra simulator plusargs; quote multiple arguments' \
	    '  WAVE_VIEW=/path.rc Override the default grouped GPIO waveform view' \
	    '  RUN_ROOT=/abs/path Output root (default: <project>/run/uvm/gpio)' \
	    '  VCS_HOME=/path     Override the VCS installation directory' \
	    '  VERDI_HOME=/path   Override the Verdi installation directory' \
	    '' \
	    'Examples:' \
	    '  make -C uvm gpio TEST=gpio_pipeline_test SEED=1' \
	    '  make -C uvm regression SEED=2' \
	    '  make -C uvm plan-regression SEED=1' \
	    '  make -C uvm gpio TEST=gpio_pipeline_test SIM_ARGS=+GPIO_QUEUE_DEPTH=2' \
	    '  make -C uvm gpio SIM_ARGS="+UVM_CONFIG_DB_TRACE +UVM_VERBOSITY=UVM_HIGH"' \
	    '  make -C uvm gpio TEST=gpio_pipeline_test WAVES=1' \
	    '  make -C uvm verdi TEST=gpio_pipeline_test' \
	    '  make -C uvm sw-gpio SW_PROGRAM=gpio_uvm_test' \
	    '' \
	    'Logs: <RUN_ROOT>/<TEST>/seed_<SEED>/sim.log (wave runs add _waves)' \
	    'GPIO_QUEUE_DEPTH accepts 1-64; pipeline/factory tests require at least 2.' \
	    'Generate waves with gpio WAVES=1; verdi uses matching TEST, SEED, RUN_ROOT.' \
	    'Waveform walkthrough: uvm/waves/README.md.' \
	    'See uvm/README.md for the VIP architecture, contracts, and limitations.'

# Separate passive implementation; existing active tests and defaults stay put.
sw-gpio sw-regression sw-verdi sw-help:
	$(MAKE) -C $(UVM_ROOT)/gpio_sw $(patsubst sw-%,%,$@)

compile: $(BUILD_DIR)/simv
$(BUILD_DIR)/simv: $(GPIO_FILES) $(GPIO_HEADERS) $(UVM_ROOT)/Makefile
	@mkdir -p $(BUILD_DIR)
	cd $(BUILD_DIR) && $(VCS) $(VCS_FLAGS) -top tb_gpio_uvm \
	    -Mdir=$(BUILD_DIR)/csrc +incdir+$(UVM_ROOT)/gpio \
	    -l compile.log -o $(BUILD_DIR)/simv $(GPIO_FILES)

regression: compile
	@set -e; for test in $(GPIO_TESTS); do \
	    $(MAKE) --no-print-directory gpio TEST=$$test SEED=$(SEED); done

plan-regression: compile
	@set -e; for test in $(GPIO_PLAN_TESTS); do \
	    $(MAKE) --no-print-directory gpio TEST=$$test SEED=$(SEED); done

check-log-parser:
	python3 -B $(UVM_ROOT)/scripts/test_check_uvm.py

# Generate FSDB first, then open the matching dump and restore signal groups.
verdi:
	@test -f $(VERDI_TEST_DIR)/tb_gpio_uvm.fsdb || { echo "Run make -C uvm gpio WAVES=1 TEST=$(TEST) SEED=$(SEED) first (with matching RUN_ROOT)"; exit 1; }
	@test -d $(VERDI_BUILD_DIR)/simv.daidir || { echo "Missing Verdi database; rebuild with gpio WAVES=1"; exit 1; }
	@test -f "$(WAVE_VIEW)" || { echo "Missing waveform view: $(WAVE_VIEW)"; exit 1; }
	cd $(VERDI_TEST_DIR) && $(VERDI_HOME)/bin/verdi -dbdir $(VERDI_BUILD_DIR)/simv.daidir \
	    -ssf $(VERDI_TEST_DIR)/tb_gpio_uvm.fsdb -sswr "$(abspath $(WAVE_VIEW))"
