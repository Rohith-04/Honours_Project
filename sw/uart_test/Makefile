# sw/uart_test/Makefile — builds uart_test.hex for `make uart.sw`
# Toolchain: /opt/riscv (riscv64-unknown-elf-gcc, -march=rv32imc -mabi=ilp32)

RISCV_PREFIX ?= /opt/riscv/bin/riscv64-unknown-elf-
CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump

CFLAGS  := -march=rv32imc -mabi=ilp32 -O0 -g \
           -nostdlib -ffreestanding -Wall -Wextra
LDFLAGS := -T ../../sw/common/linker.ld -nostdlib

BUILD := build
ELF   := $(BUILD)/uart_test.elf
HEX   := $(BUILD)/uart_test.hex
DUMP  := $(BUILD)/uart_test.dis

all: $(HEX) $(DUMP)

$(BUILD):
	@mkdir -p $(BUILD)

$(ELF): main.c ../../sw/common/startup.S | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

$(HEX): $(ELF)
	$(OBJCOPY) -O verilog $< $@
	@echo "[sw] hex: $@"

$(DUMP): $(ELF)
	$(OBJDUMP) -d $< > $@
	@echo "[sw] dis: $@"

clean:
	rm -rf $(BUILD)

.PHONY: all clean
