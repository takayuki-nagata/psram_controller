# Copyright (c) 2026 Takayuki Nagata
# SPDX-License-Identifier: MIT

# Makefile for Tang Nano 9K PSRAM Controller

VERYL ?= veryl
YOSYS ?= yosys
NEXTPNR ?= nextpnr-himbaechel
GOWIN_PACK ?= gowin_pack
OPENFPGALOADER ?= openFPGALoader
PYTHON ?= python3
SERIAL_PORT ?= /dev/ttyUSB3
IVERILOG ?= iverilog
VVP ?= vvp

OSS_CAD_SUITE_BIN ?= $(HOME)/.local/oss-cad-suite/bin
CARGO_BIN ?= $(HOME)/.cargo/bin
export PATH := $(CARGO_BIN):$(OSS_CAD_SUITE_BIN):$(PATH)

BUILD_DIR := build
SYNTH_DIR := $(BUILD_DIR)/synth
SIM_DIR   := $(BUILD_DIR)/sim
CST_FILE  := tangnano9k.cst

.PHONY: all fmt check veryl sim synth pnr bitstream prog-sram test-hw clean

all: sim bitstream

# Code Quality: Formatting and Static Analysis
fmt:
	$(VERYL) fmt

check:
	$(VERYL) check

# Step 1: Veryl Build (transpile to SystemVerilog)
veryl:
	@mkdir -p $(BUILD_DIR)
	$(VERYL) build

# Step 2: RTL Simulation (Icarus Verilog)
SIM_SRCS := src/psram_pkg.sv \
            src/psram_core.sv \
            src/psram_phy_io.sv \
            src/psram_controller.sv \
            src/psram_tracer.sv \
            src/uart/clk_timer.sv \
            src/uart/fifo_sync.sv \
            src/uart/shift_registers.sv \
            src/uart/uart_rx.sv \
            src/uart/uart_tx.sv \
            src/uart/uart_controller.sv \
            src/psram_top.sv \
            sim/tb_psram_model.sv \
            sim/tb_psram_top.sv

sim: veryl
	@mkdir -p $(SIM_DIR)
	$(IVERILOG) -g2012 -o $(SIM_DIR)/tb_psram_top $(SIM_SRCS)
	$(VVP) $(SIM_DIR)/tb_psram_top

# Step 3: Synthesis (Yosys)
SYNTH_SRCS := src/psram_pkg.sv \
              src/psram_core.sv \
              src/psram_phy_io.sv \
              src/psram_controller.sv \
              src/psram_tracer.sv \
              src/uart/clk_timer.sv \
              src/uart/fifo_sync.sv \
              src/uart/shift_registers.sv \
              src/uart/uart_rx.sv \
              src/uart/uart_tx.sv \
              src/uart/uart_controller.sv \
              src/psram_top.sv

$(SYNTH_DIR)/psram.json: veryl $(SYNTH_SRCS)
	@mkdir -p $(SYNTH_DIR)
	$(YOSYS) -p "\
		read_verilog -sv $(SYNTH_SRCS); \
		synth_gowin -top psram_top -nowidelut -no-rw-check -json $(SYNTH_DIR)/psram.json; \
	"

synth: $(SYNTH_DIR)/psram.json

# Step 4: Place and Route (nextpnr-himbaechel)
$(SYNTH_DIR)/psram_pnr.json: $(SYNTH_DIR)/psram.json $(CST_FILE)
	$(NEXTPNR) --device GW1NR-LV9QN88PC6/I5 \
		--vopt family=GW1N-9C \
		--vopt cst=$(CST_FILE) \
		--json $(SYNTH_DIR)/psram.json \
		--write $(SYNTH_DIR)/psram_pnr.json \
		--freq 27.0 \
		--seed 2

pnr: $(SYNTH_DIR)/psram_pnr.json

# Step 5: Bitstream Packing (gowin_pack)
$(SYNTH_DIR)/pack.fs: $(SYNTH_DIR)/psram_pnr.json
	$(GOWIN_PACK) -d GW1N-9C -o $(SYNTH_DIR)/pack.fs $(SYNTH_DIR)/psram_pnr.json

bitstream: $(SYNTH_DIR)/pack.fs
	@echo "=== Bitstream $(SYNTH_DIR)/pack.fs Built Successfully! ==="

# Step 6: Program SRAM ONLY (Never write to Flash!)
prog-sram: $(SYNTH_DIR)/pack.fs
	@echo "=== Programming Tang Nano 9K SRAM (Flash write is strictly prohibited) ==="
	$(OPENFPGALOADER) -b tangnano9k $(SYNTH_DIR)/pack.fs

# Step 7: Automated Hardware Verification via $(SERIAL_PORT)
test-hw: $(SYNTH_DIR)/pack.fs
	$(PYTHON) scripts/run_hardware_test.py --port $(SERIAL_PORT) --baud 115200 \
		--prog-cmd "$(OPENFPGALOADER) -b tangnano9k $(SYNTH_DIR)/pack.fs"

clean:
	rm -rf $(BUILD_DIR) .build dependencies psram_controller.f
