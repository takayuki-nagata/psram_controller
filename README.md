# Tang Nano 9K PSRAM Controller

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Hardware: Tang Nano 9K](https://img.shields.io/badge/Hardware-Tang%20Nano%209K-orange.svg)](https://wiki.sipeed.com/hardware/en/tang/Tang-Nano-9K/Nano-9K.html)
[![Language: Veryl](https://img.shields.io/badge/Language-Veryl%20HDL-green.svg)](https://veryl-lang.org/)
[![Toolchain: Open--Source](https://img.shields.io/badge/Toolchain-Yosys%20%7C%20nextpnr%20%7C%20Apycula-purple.svg)](https://github.com/YosysHQ/oss-cad-suite-build)
[![Simulation: PASS](https://img.shields.io/badge/Simulation-100%25%20PASS-brightgreen.svg)](#1-run-the-tests)
[![Silicon: Verified](https://img.shields.io/badge/Silicon-100%25%20Verified-brightgreen.svg)](#3-run-the-hardware-test)

A clean-room, robust **HyperBus PSRAM Controller** designed for the **Winbond W955D8MBYA** 64Mbit (8MB) PSRAM embedded inside the Gowin GW1NR-9C FPGA on the **Tang Nano 9K** development board.

Written in modern **Veryl HDL**, synthesized with **Yosys**, placed and routed with **nextpnr-himbaechel**, and fully verified both in RTL simulation (**Icarus Verilog**) and on real silicon.

---

## Key Highlights

- **16-bit DDR Data Bus**: Operates the two internal 32Mb x8 dies in lockstep for 16-bit wide DDR data transfers (one CK edge per system clock cycle; `CLK_HZ` parameter, tested at 18 and 27 MHz).
- **Center-Aligned Clocking**: PSRAM CK is registered on `negedge clk`, so that every CK edge is half a system clock after the data changes, giving generous setup and hold margins without complex PLLs or DLLs.
- **Fixed Latency Mode**: Operates at 2x Fixed Latency (12 PSRAM clock cycles, counted from the third CA clock), supporting deterministic read and write transactions; register writes with zero latency.
- **Clean-Room Specification**: Developed strictly from official vendor datasheets (Winbond & Gowin) without proprietary IP dependencies.
- **Built-in Real-Time Pin Tracer**: Includes an on-chip logic analyzer (`psram_tracer`) that records 64 cycles of physical pin states (CS#, CK, OE, RWDS, DQ, FSM State, Timer) and prints them via UART for instant hardware diagnostics.
- **100% Open-Source Toolchain**: Fully reproducible using `veryl`, `yosys`, `nextpnr`, `apycula`, `openFPGALoader`, and `iverilog`.
- **SRAM-Only Safety**: Hardware verification runs entirely in volatile FPGA SRAM (`openFPGALoader -b tangnano9k pack.fs`), protecting the on-board SPI Flash memory from wear.

---

## Architecture Overview

```mermaid
flowchart LR
    subgraph Host ["Host Interface / SoC"]
        CPU["Host Bus / RISC-V CPU"]
    end

    subgraph PSRAM_Ctrl ["psram_controller"]
        Core["psram_core (FSM)"]
        PHY["psram_phy (I/O & Tri-State)"]
        Tracer["psram_tracer (Logic Analyzer)"]
    end

    subgraph SiP ["Embedded SiP (Bank 1 1.8V)"]
        Die0["Winbond 32Mb Die 0\n(DQ[7:0], RWDS[0])"]
        Die1["Winbond 32Mb Die 1\n(DQ[15:8], RWDS[1])"]
    end

    CPU -->|"req, we, addr[23:0], wdata[31:0], wstrb[3:0]"| Core
    Core -->|"rdata[31:0], ready, busy"| CPU
    Core <--> PHY
    PHY <-->|"O_psram_ck, cs_n, reset_n\nIO_psram_dq, rwds"| SiP
    Core -.->|"Sample Pins"| Tracer
```

### Finite State Machine (FSM)

```mermaid
stateDiagram-v2
    [*] --> RESET_ASSERT: Power-On
    RESET_ASSERT --> RESET_WAIT: tRP >= 200ns
    RESET_WAIT --> IDLE: tVCS >= 150us
    IDLE --> SEND_CA: req == 1 (Assert CS#)
    SEND_CA --> WAIT_LATENCY: 6 DDR bytes sent
    WAIT_LATENCY --> WRITE_DATA: we == 1 (12 clock cycles)
    WAIT_LATENCY --> READ_DATA: we == 0 (12 clock cycles)
    WRITE_DATA --> RECOVERY: Word 0 & 1 driven
    READ_DATA --> RECOVERY: Word 0 & 1 sampled
    RECOVERY --> IDLE: CS# deasserted (tRWR >= 36ns, pulse ready)
```

---

## Hardware Pinout (GW1NR-LV9 QFN88P)

The two 32Mbit x8 PSRAM dies are packaged in SiP and internally bonded to FPGA Bank 1 IOBs:

| Signal | Dir | IOB | Tang Nano 9K Internal Function |
|---|---|---|---|
| `O_psram_ck[0]` / `ck[1]` | Out | `IOL8A` / `IOL23B` | Differential Clock (+) for Die 0 / Die 1 |
| `O_psram_ck_n[0]` / `ck_n[1]` | Out | `IOL7A` / `IOL23A` | Differential Clock (-) for Die 0 / Die 1 |
| `O_psram_cs_n[0]` / `cs_n[1]` | Out | `IOL6B` / `IOL22A` | Chip Select (Active-Low) for Die 0 / Die 1 |
| `O_psram_reset_n[0]` / `reset_n[1]` | Out | `IOL2A` / `IOL18A` | Hardware Reset (Active-Low) |
| `IO_psram_rwds[0]` / `rwds[1]` | Inout | `IOL17A` / `IOL27B` | Read Strobe / Write Byte Mask for Die 0 / Die 1 |
| `IO_psram_dq[7:0]` | Inout | `IOL2B..IOL17B` | 8-bit DDR Data Bus for Die 0 |
| `IO_psram_dq[15:8]` | Inout | `IOL18B..IOL27A` | 8-bit DDR Data Bus for Die 1 |

*Complete pin mappings are specified in [`tangnano9k.cst`](demo/tangnano9k/tangnano9k.cst) and documented in [`docs/spec.md`](docs/spec.md).*

---

## Directory Structure

```text
├── Makefile                   # setup, check, lint, formal, test-sim, eqy, sim-demo, bitstream, sta, test-hw
├── Veryl.toml                 # Veryl project of the controller IP (rtl/ only)
├── rtl/                       # Controller IP (all Veryl)
│   ├── psram_pkg.veryl        # Datasheet timing (ns), CA bits, register addresses
│   ├── psram_core.veryl       # HyperBus protocol FSM
│   ├── psram_phy.veryl        # PSRAM clock (falling edge) and DQ/RWDS tri-state buffers
│   └── psram_controller.veryl # Top: valid/ready host interface, CLK_HZ parameter
├── sim/
│   ├── model/                 # W955D8MBYA model with protocol/timing checkers (2 dies)
│   ├── tb/                    # cocotb toplevel
│   ├── tests/                 # cocotb tests and the host driver/protocol monitor
│   ├── runner.py              # build/run helper (cocotb_tools.runner)
│   └── test_sim.py            # pytest entry point (18 and 27 MHz)
├── formal/                    # SymbiYosys properties of psram_core
├── scripts/                   # run_eqy.py (make eqy), lint.vlt (Verilator waivers)
├── demo/tangnano9k/           # Board demo (separate Veryl project using the IP)
│   ├── Veryl.toml             # Depends on the IP via `psram = { path = "../.." }`
│   ├── psram_board.veryl      # Board top: crystal or rPLL (18 MHz) clock
│   ├── psram_top.veryl        # Self-test: pin trace, full 8 MB memory test, UART & LEDs
│   ├── psram_tracer.veryl     # 64-sample on-chip logic analyzer
│   ├── uart/                  # UART transmitter & receiver
│   ├── tb_psram_top.sv        # Demo simulation testbench
│   ├── tangnano9k.cst         # Gowin physical pin constraint file
│   └── run_hardware_test.py   # Hardware UART monitor & pin trace analyzer
├── docs/
│   ├── spec.md                # Technical design specification
│   └── integration.md         # Using the IP from another project (VUX9K)
└── .github/workflows/ci.yml   # CI: make check, lint, formal, test-sim, sim-demo, sta
```

Generated SystemVerilog is not committed. `make veryl` / `make veryl-demo` write it under `build/`
(invoked automatically by `make sim-demo` / `make bitstream`). Projects using the IP as a Veryl
dependency see its modules with the dependency name as prefix (e.g. `psram_psram_controller`).

---

## Quick Start Guide

### Prerequisites

Install the open-source FPGA toolchain (versions used in CI, same as VUX9K):
- **[Veryl](https://veryl-lang.org/)** 0.21.0
- **[OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)** 2026-08-21 (Yosys, eqy, SymbiYosys, nextpnr-himbaechel, Apycula, openFPGALoader, Icarus Verilog, Verilator)
- **[uv](https://docs.astral.sh/uv/)**, then `make setup` for the Python environment (cocotb 2.0.1, pytest, pyserial, ruff)

### 1. Run the tests

```bash
make setup     # once
make test      # check + lint + formal + test-sim + sim-demo
```

| Target | What it checks |
|---|---|
| `make check` / `make lint` | Veryl format/check, ruff; Verilator `-Wall` on the IP (warnings fatal) |
| `make formal` | SymbiYosys proofs of `psram_core` ([formal/](formal/)): interface contract, tCSM, bus direction, RESET# |
| `make test-sim` | cocotb tests ([sim/tests/](sim/tests/)) at 18 and 27 MHz against a datasheet-based W955D8MBYA model ([sim/model/](sim/model/)) that checks the protocol and timing; data is checked through the interface and in the model memory |
| `make sim-demo` | the board demo in simulation (Icarus Verilog) |
| `make eqy` | formal equivalence of a refactor against a base commit (`EQY_BASE`, default `HEAD`) |
| `make sta` | nextpnr timing at 27 MHz, 5 seeds |

### 2. Build the FPGA bitstream

```bash
make bitstream                  # 27 MHz from the crystal
make bitstream DEMO_CLK_MHZ=18  # 18 MHz from the rPLL, as in VUX9K
```

The bitstream is `build/demo/synth_<N>mhz/pack.fs`.

### 3. Run the hardware test

Connect the Tang Nano 9K board via USB and run:

```bash
make test-hw                    # or: make test-hw DEMO_CLK_MHZ=18
```

This command:
1. Programs `pack.fs` into the FPGA **SRAM** (volatile; never touches the SPI Flash).
2. Listens to the USB serial port (`/dev/ttyUSB3` by default at 115200 baud; override with `make test-hw SERIAL_PORT=/dev/ttyUSBx`).
3. The board reads ID0 with a 64-cycle pin trace, writes and reads back four words, then runs
   the full memory test over all 8 MB (write f(addr); read f(addr) and write ~f(addr); read
   ~f(addr)), about 12 s at 27 MHz and 19 s at 18 MHz. A failure prints the expected and read
   value and the address. The script parses the trace and reports the result.

Excerpt of the hardware output (read of ID0: the chip drives the first byte with RWDS High
on the rising CK edge of clock 15, the controller samples it in READ_DATA cycle 1 and the
second byte in cycle 2):
```text
=== PSRAM TRACE (ID0) ===
CYC: S TM C K OE RW D1 D0
C00: 2 00 1 0 0 11 FF FF
C01: 3 00 0 0 1 11 E0 E0
...
C1E: 6 01 0 1 0 11 00 00
C1F: 6 02 0 0 0 00 5F 5F
C20: 6 03 0 0 0 00 5F 5F
...
=== END TRACE ===

[PSRAM] TEST PASSED! 64Mb OK
>>> SUCCESS: PSRAM Hardware Read/Write Test PASSED on Tang Nano 9K! <<<
```

---

## Host Bus Interface Specification

`psram_controller` has a valid/ready request channel and a one-cycle response. Parameter
`CLK_HZ` (default 27 MHz) is the system clock frequency; the PSRAM clock is `CLK_HZ / 2`.
The tests run at 18 MHz (VUX9K) and 27 MHz (this board).

| Port | Direction | Width | Description |
|---|---|---|---|
| `clk` | Input | 1 | System clock (`CLK_HZ`) |
| `rst_n` | Input | 1 | Active-Low asynchronous reset |
| `req_valid` | Input | 1 | Request valid; hold (with the payload unchanged) until accepted |
| `req_ready` | Output | 1 | Request accepted in a cycle with `req_valid && req_ready` |
| `req_we` | Input | 1 | `1`: write, `0`: read |
| `req_addr` | Input | 24 | Byte address, 4-byte aligned (bit 23: `0` = memory, `1` = register space) |
| `req_wdata` | Input | 32 | Write data |
| `req_wstrb` | Input | 4 | Byte enables for memory writes |
| `rsp_valid` | Output | 1 | One-cycle response, exactly one per accepted request |
| `rsp_rdata` | Output | 32 | Read data, valid with `rsp_valid` |
| `init_done` | Output | 1 | PSRAM power-up sequence finished (`req_ready` is Low until then) |
| `dbg_sample` | Output | 32 | FSM/pin state for an on-chip tracer; leave unconnected if unused |

One request is in flight at a time; `req_ready` is High again in the cycle of `rsp_valid`,
so the next request can be accepted back-to-back. Register space: ID0 `0x800000`,
ID1 `0x800004`, CR0 `0x800020`, CR1 `0x800024` (a register write loads `wdata[7:0]`/`[23:16]`
into die 0 and `wdata[15:8]`/`[31:24]` into die 1).

---|---|---|---|
| `clk` | Input | 1 | 27 MHz system clock |
| `rst_n` | Input | 1 | Active-Low asynchronous reset |
| `req` | Input | 1 | Access request pulse (assert for 1 cycle) |
| `we` | Input | 1 | `1`: Write, `0`: Read |
| `addr` | Input | 24 | Byte address (bit 23: `0` = Memory Space, `1` = Register Space) |
| `wdata` | Input | 32 | 32-bit write word |
| `wstrb` | Input | 4 | Byte write masks (`1`: write byte, `0`: mask) |
| `rdata` | Output | 32 | 32-bit read word (valid when `ready` pulses) |
| `ready` | Output | 1 | 1-cycle completion pulse |
| `busy` | Output | 1 | High while a transaction is in progress |

---

## License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.
