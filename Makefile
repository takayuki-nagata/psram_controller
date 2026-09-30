# Copyright (c) 2026 Takayuki Nagata
# SPDX-License-Identifier: MIT

# Makefile for the Tang Nano 9K PSRAM Controller
#
# rtl/             the controller IP (Veryl project at the repository root)
# demo/tangnano9k/ board demo (separate Veryl project depending on the IP)
# All generated files go under build/.

VENV_PATH ?= .venv
UV ?= uv
VERYL ?= veryl
YOSYS ?= yosys
NEXTPNR ?= nextpnr-himbaechel
GOWIN_PACK ?= gowin_pack
OPENFPGALOADER ?= openFPGALoader
PYTHON ?= $(if $(wildcard $(VENV_PATH)/bin/python),$(VENV_PATH)/bin/python,python3)
RUFF ?= $(PYTHON) -m ruff
IVERILOG ?= iverilog
VVP ?= vvp
SERIAL_PORT ?= /dev/ttyUSB3

OSS_CAD_SUITE_BIN ?= $(HOME)/.local/oss-cad-suite/bin
CARGO_BIN ?= $(HOME)/.cargo/bin
export PATH := $(CARGO_BIN):$(OSS_CAD_SUITE_BIN):$(PATH)

BUILD_DIR      := build
VERYL_OUT_DIR  := $(BUILD_DIR)/veryl
DEMO_DIR       := demo/tangnano9k
DEMO_BUILD_DIR := $(BUILD_DIR)/demo
DEMO_VERYL_DIR := $(DEMO_BUILD_DIR)/veryl
DEMO_SIM_DIR   := $(DEMO_BUILD_DIR)/sim
DEMO_SYNTH_DIR := $(DEMO_BUILD_DIR)/synth
CST_FILE       := $(DEMO_DIR)/tangnano9k.cst

.PHONY: all setup fmt check lint eqy test test-sim veryl veryl-demo sim-demo synth pnr bitstream sta prog-sram test-hw clean

all: test bitstream

# ===== Python environment (cocotb, pytest), same versions as VUX9K =====
setup:
	$(UV) venv --python 3.13 $(VENV_PATH)
	$(UV) pip install --python $(VENV_PATH)/bin/python cocotb==2.0.1 pytest==9.1.1 pytest-xdist pyserial ruff==0.16.8

# ===== Code quality =====
fmt:
	$(VERYL) fmt
	cd $(DEMO_DIR) && $(VERYL) fmt
	$(RUFF) format

check:
	$(VERYL) fmt --check
	$(VERYL) check
	cd $(DEMO_DIR) && $(VERYL) fmt --check
	cd $(DEMO_DIR) && $(VERYL) check
	$(RUFF) format --check
	$(RUFF) check

# ===== Veryl build =====
IP_VERYL_SRCS   := $(wildcard rtl/*.veryl) Veryl.toml
DEMO_VERYL_SRCS := $(IP_VERYL_SRCS) $(wildcard $(DEMO_DIR)/*.veryl) $(wildcard $(DEMO_DIR)/uart/*.veryl) $(DEMO_DIR)/Veryl.toml

$(VERYL_OUT_DIR)/.stamp: $(IP_VERYL_SRCS)
	@mkdir -p $(VERYL_OUT_DIR)
	$(VERYL) build --quiet --out-dir $(VERYL_OUT_DIR)
	@touch $@

$(DEMO_VERYL_DIR)/.stamp: $(DEMO_VERYL_SRCS)
	@mkdir -p $(DEMO_VERYL_DIR)
	cd $(DEMO_DIR) && $(VERYL) build --quiet --out-dir $(CURDIR)/$(DEMO_VERYL_DIR)
	@touch $@

veryl: $(VERYL_OUT_DIR)/.stamp
veryl-demo: $(DEMO_VERYL_DIR)/.stamp

# Controller IP as seen by a user of the Veryl dependency (modules prefixed "psram_")
DEMO_IP_SRCS := $(DEMO_VERYL_DIR)/dependencies/psram/rtl/psram_pkg.sv \
                $(DEMO_VERYL_DIR)/dependencies/psram/rtl/psram_core.sv \
                $(DEMO_VERYL_DIR)/dependencies/psram/rtl/psram_phy.sv \
                $(DEMO_VERYL_DIR)/dependencies/psram/rtl/psram_controller.sv

DEMO_SRCS := $(DEMO_IP_SRCS) \
             $(DEMO_VERYL_DIR)/psram_tracer.sv \
             $(DEMO_VERYL_DIR)/uart/clk_timer.sv \
             $(DEMO_VERYL_DIR)/uart/fifo_sync.sv \
             $(DEMO_VERYL_DIR)/uart/shift_registers.sv \
             $(DEMO_VERYL_DIR)/uart/uart_rx.sv \
             $(DEMO_VERYL_DIR)/uart/uart_tx.sv \
             $(DEMO_VERYL_DIR)/uart/uart_controller.sv \
             $(DEMO_VERYL_DIR)/psram_top.sv

# Controller IP sources, compilation order (packages first)
IP_SRCS := $(VERYL_OUT_DIR)/rtl/psram_pkg.sv \
           $(VERYL_OUT_DIR)/rtl/psram_core.sv \
           $(VERYL_OUT_DIR)/rtl/psram_phy.sv \
           $(VERYL_OUT_DIR)/rtl/psram_controller.sv

# Verilator lint of the IP, every warning fatal (waivers: scripts/lint.vlt)
VERILATOR ?= verilator
lint: $(VERYL_OUT_DIR)/.stamp
	$(VERILATOR) --lint-only -Wall --top-module psram_controller scripts/lint.vlt $(IP_SRCS)

# ===== Formal equivalence of a refactor against a base commit (default HEAD) =====
EQY_BASE ?= HEAD
EQY_TOP  ?= psram_controller
EQY_NOMATCH ?=
eqy: $(VERYL_OUT_DIR)/.stamp
	$(PYTHON) scripts/run_eqy.py --base $(EQY_BASE) --top $(EQY_TOP) --veryl $(VERYL) \
		$(if $(EQY_NOMATCH),--nomatch $(EQY_NOMATCH))

# ===== cocotb tests of the IP against the W955D8MBYA model (sim/) =====
PYTEST_ARGS ?= -n auto
test-sim: $(VERYL_OUT_DIR)/.stamp
	$(PYTHON) -m pytest $(PYTEST_ARGS) sim/test_sim.py

test: check lint test-sim sim-demo

# ===== Demo: RTL smoke simulation (Icarus Verilog) =====
sim-demo: $(DEMO_VERYL_DIR)/.stamp
	@mkdir -p $(DEMO_SIM_DIR)
	$(IVERILOG) -g2012 -o $(DEMO_SIM_DIR)/tb_psram_top $(DEMO_SRCS) sim/model/w955d8mbya_die.sv sim/model/w955d8mbya_model.sv $(DEMO_DIR)/tb_psram_top.sv
	$(VVP) $(DEMO_SIM_DIR)/tb_psram_top

# ===== Demo: synthesis, place and route, bitstream =====
$(DEMO_SYNTH_DIR)/psram.json: $(DEMO_VERYL_DIR)/.stamp
	@mkdir -p $(DEMO_SYNTH_DIR)
	$(YOSYS) -p "\
		read_verilog -sv $(DEMO_SRCS); \
		synth_gowin -top psram_top -nowidelut -no-rw-check -json $@; \
	"

synth: $(DEMO_SYNTH_DIR)/psram.json

$(DEMO_SYNTH_DIR)/psram_pnr.json: $(DEMO_SYNTH_DIR)/psram.json $(CST_FILE)
	$(NEXTPNR) --device GW1NR-LV9QN88PC6/I5 \
		--vopt family=GW1N-9C \
		--vopt cst=$(CST_FILE) \
		--json $< \
		--write $@ \
		--freq 27.0 \
		--seed 2

pnr: $(DEMO_SYNTH_DIR)/psram_pnr.json

# Timing across several placement seeds (nextpnr fails the run if any clock misses)
STA_FREQ  ?= 27.0
STA_SEEDS ?= 2 3 5 7 11
sta: $(DEMO_SYNTH_DIR)/psram.json $(CST_FILE)
	@for seed in $(STA_SEEDS); do \
		echo "=== nextpnr seed $$seed @ $(STA_FREQ) MHz ==="; \
		$(NEXTPNR) --device GW1NR-LV9QN88PC6/I5 --vopt family=GW1N-9C --vopt cst=$(CST_FILE) \
			--json $< --write $(DEMO_SYNTH_DIR)/sta_seed$$seed.json \
			--freq $(STA_FREQ) --seed $$seed --quiet --log $(DEMO_SYNTH_DIR)/sta_seed$$seed.log || exit 1; \
		grep 'Max frequency' $(DEMO_SYNTH_DIR)/sta_seed$$seed.log | tail -1; \
	done

$(DEMO_SYNTH_DIR)/pack.fs: $(DEMO_SYNTH_DIR)/psram_pnr.json
	$(GOWIN_PACK) -d GW1N-9C -o $@ $<

bitstream: $(DEMO_SYNTH_DIR)/pack.fs
	@echo "=== Bitstream $< Built Successfully! ==="

# Program SRAM ONLY (never write to Flash)
prog-sram: $(DEMO_SYNTH_DIR)/pack.fs
	@echo "=== Programming Tang Nano 9K SRAM (Flash write is strictly prohibited) ==="
	$(OPENFPGALOADER) -b tangnano9k $<

# Automated hardware verification via $(SERIAL_PORT)
test-hw: $(DEMO_SYNTH_DIR)/pack.fs
	$(PYTHON) $(DEMO_DIR)/run_hardware_test.py --port $(SERIAL_PORT) --baud 115200 \
		--prog-cmd "$(OPENFPGALOADER) -b tangnano9k $<"

clean:
	rm -rf $(BUILD_DIR) .build $(DEMO_DIR)/.build dependencies
