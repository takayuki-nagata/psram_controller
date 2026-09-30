# Tang Nano 9K PSRAM Controller Design Specification (Clean-Room Implementation)

This document specifies the architecture, protocol, and physical interface of the clean-room PSRAM controller designed for the **Winbond W955D8MBYA** 64Mbit HyperBus PSRAM embedded inside the Gowin GW1NR-9C FPGA on the **Tang Nano 9K** development board.

---

## 1. Reference Official Documents

This design was created strictly from the following official vendor documentation without referencing any third-party proprietary source code or tutorials:

1. **Winbond W955D8MBYA Data Sheet**:
   - Document: *W955D8MBYA 64Mb 1.8V Octal/x8 PSRAM* (Revision: A01-001, Publication Date: Jun. 05, 2019)
   - Relevant sections: Section 6 (Functional Description), Section 7 (HyperBus Transaction Details), Section 8 (Memory Space), Section 9 (Register Space), Section 11 (Electrical Specifications), Section 12 (Timing Specifications).
2. **Gowin GW1NR Series FPGA Data Sheet**:
   - Document: `DS117-3.2.5E` (2026-07-31)
   - Relevant sections: Table 1-2 (Memory Capacity & Width: QN88P = PSRAM 64M 16 bits), Section 2.2.2 (PSRAM Features: 166MHz, 32Mb x 2, DDR, 8 bits/die, 1.8V).
3. **Gowin GW1NR-9 Device Pinout**:
   - Document: `UG803-1.6.5E` (2025-03-14)
   - Relevant sections: Pin table (Bank 1 / Bank 3 I/O cells and internal QN88P package bonding).
4. **Gowin PSRAM Memory Interface HS IP User Guide**:
   - Document: `IPUG943-1.5E` (2026-03-09)
   - Relevant sections: Section 3.1 (Supported PSRAM Models: W955D8MKY-6I / W955D8MBYA), Table 6-1 (Static Parameters).
5. **Apycula GW1N-9C Chip Database**:
   - Source: `apycula/GW1N-9C.msgpack.xz` (`sip_cst['GW1NR-9C']['QFN88P']`)
   - Relevant sections: Physical IOB / IOL mapping for internal PSRAM signals.

---

## 2. Hardware Physical Interface (Physical Layer)

The GW1NR-LV9QN88PC6/I5 (QFN88P package) integrates two 32Mbit x8 PSRAM dies (Channel 0 and Channel 1) in a System-in-Package (SiP) configuration. These dies connect directly to the IOBs of FPGA Bank 1 (1.8V domain).

### Internal PSRAM Pinout Table
| Signal Name | Direction | Physical IOB | Description |
|---|---|---|---|
| `O_psram_ck[0]` | Output | `IOL8A` | Channel 0 Single-ended Clock |
| `O_psram_ck_n[0]` | Output | `IOL7A` | Channel 0 Inverted Differential Clock |
| `O_psram_cs_n[0]` | Output | `IOL6B` | Channel 0 Chip Select (Active-Low) |
| `O_psram_reset_n[0]`| Output | `IOL2A` | Channel 0 Hardware Reset (Active-Low) |
| `IO_psram_rwds[0]` | Inout | `IOL17A` | Channel 0 Read/Write Data Strobe / Mask |
| `IO_psram_dq[0]` | Inout | `IOL2B` | Channel 0 Data bit 0 |
| `IO_psram_dq[1]` | Inout | `IOL3A` | Channel 0 Data bit 1 |
| `IO_psram_dq[2]` | Inout | `IOL3B` | Channel 0 Data bit 2 |
| `IO_psram_dq[3]` | Inout | `IOL4A` | Channel 0 Data bit 3 |
| `IO_psram_dq[4]` | Inout | `IOL9A` | Channel 0 Data bit 4 |
| `IO_psram_dq[5]` | Inout | `IOL14A`| Channel 0 Data bit 5 |
| `IO_psram_dq[6]` | Inout | `IOL16A`| Channel 0 Data bit 6 |
| `IO_psram_dq[7]` | Inout | `IOL17B`| Channel 0 Data bit 7 |
| `O_psram_ck[1]` | Output | `IOL23B`| Channel 1 Single-ended Clock |
| `O_psram_ck_n[1]` | Output | `IOL23A`| Channel 1 Inverted Differential Clock |
| `O_psram_cs_n[1]` | Output | `IOL22A`| Channel 1 Chip Select (Active-Low) |
| `O_psram_reset_n[1]`| Output | `IOL18A`| Channel 1 Hardware Reset (Active-Low) |
| `IO_psram_rwds[1]` | Inout | `IOL27B`| Channel 1 Read/Write Data Strobe / Mask |
| `IO_psram_dq[8]` | Inout | `IOL18B`| Channel 1 Data bit 0 |
| `IO_psram_dq[9]` | Inout | `IOL20A`| Channel 1 Data bit 1 |
| `IO_psram_dq[10]` | Inout | `IOL20B`| Channel 1 Data bit 2 |
| `IO_psram_dq[11]` | Inout | `IOL21A`| Channel 1 Data bit 3 |
| `IO_psram_dq[12]` | Inout | `IOL24B`| Channel 1 Data bit 4 |
| `IO_psram_dq[13]` | Inout | `IOL25A`| Channel 1 Data bit 5 |
| `IO_psram_dq[14]` | Inout | `IOL26A`| Channel 1 Data bit 6 |
| `IO_psram_dq[15]` | Inout | `IOL27A`| Channel 1 Data bit 7 |

*Note: The controller operates Channel 0 and Channel 1 in lockstep, forming a unified **16-bit DDR data bus (`DQ[15:0]`)** with two byte-mask strobes (`RWDS[1:0]`).*

---

## 3. HyperBus Protocol Specification

### 3.1 Power-on & Hardware Reset Sequence
- Upon power-up or system reset, `O_psram_reset_n` is asserted Low.
- `tRP` (RESET# pulse width) must be >= 200 ns.
- After releasing `RESET#` High, the controller waits `tVCS` (>= 150 us) before issuing any command.

### 3.2 Command-Address (CA) Phase
Following `CS#` assertion Low, a 48-bit (6-byte) Command-Address packet is transmitted in Double Data Rate (DDR) mode over 3 PSRAM clock cycles (6 clock edges):

- **Byte 0** (Clock 1 High): `CA[47:40]`
  - `CA[47]`: R/W# (`1` = Read, `0` = Write)
  - `CA[46]`: Address Space (`0` = Memory Space, `1` = Register Space)
  - `CA[45]`: Burst Type (`0` = Wrapped Burst, `1` = Linear / Register)
  - `CA[44:40]`: Reserved (all `0`)
- **Byte 1** (Clock 1 Low): `CA[39:32]`
  - `CA[39:34]`: Reserved (all `0`)
  - `CA[33:32]`: Row Address A20..A19
- **Byte 2** (Clock 2 High): `CA[31:24]`
  - `CA[31:24]`: Row Address A18..A11
- **Byte 3** (Clock 2 Low): `CA[23:16]`
  - `CA[23:22]`: Row Address A10..A9
  - `CA[21:16]`: Upper Column Address A8..A3 (Half-Page)
- **Byte 4** (Clock 3 High): `CA[15:8]`
  - `CA[15:8]`: Reserved (all `0`)
- **Byte 5** (Clock 3 Low): `CA[7:0]`
  - `CA[7:3]`: Reserved (all `0`)
  - `CA[2:0]`: Lower Column Address A2..A0 (Word in Half-Page)

*Note: HyperBus addresses 16-bit words. A byte address `addr` is translated via `word_addr = addr[22:1]`.*

### 3.3 Latency Phase
- By default, the memory chip operates in **Fixed Latency Mode** (`CR0[3] = 1`) with Initial Latency = 6 clocks (`CR0[7:4] = 0001b`).
- In Fixed Latency mode, the latency period is always **2 x Initial Latency = 12 PSRAM clock cycles** (24 DDR half-cycles / system clock cycles), regardless of refresh collision.

### 3.4 Data Phase
- **Write Transaction**:
  - The controller drives `DQ[15:0]` on both clock edges.
  - `RWDS[1:0]` acts as byte write masks (`0` = write byte, `1` = mask byte).
  - A 32-bit word is written across 2 DDR half-cycles (Word 0 on edge 1, Word 1 on edge 2).
- **Read Transaction**:
  - The PSRAM drives `DQ[15:0]` and transitions `RWDS` synchronously with data edges.
  - The controller samples Word 0 on edge 1 and Word 1 on edge 2.

### 3.5 CS# Recovery Time
- Upon completing a transaction, `CS#` is de-asserted High.
- The controller enforces `tRWR` (Read-to-Write / Chip-Select Recovery Time >= 36 ns) before initiating the next access.

---

## 4. Controller Architecture

### 4.1 Host Bus Interface
| Signal | Direction | Width | Description |
|---|---|---|---|
| `clk` | Input | 1 | 27 MHz System Clock |
| `rst_n` | Input | 1 | Asynchronous Active-Low Reset |
| `req` | Input | 1 | Access request pulse (1 cycle) |
| `we` | Input | 1 | Write Enable (`1` = Write, `0` = Read) |
| `addr` | Input | 24 | Byte Address (bit 23: `0` = Memory, `1` = Register) |
| `wdata` | Input | 32 | 32-bit Write Data |
| `wstrb` | Input | 4 | Byte write strobes (`1` = write, `0` = mask) |
| `rdata` | Output | 32 | 32-bit Read Data |
| `ready` | Output | 1 | Access completion pulse (1 cycle) |
| `busy` | Output | 1 | High while an access transaction is in progress |

### 4.2 Finite State Machine (FSM)
1. `RESET_ASSERT`: Holds `O_psram_reset_n` Low for `tRP` (>= 200 ns).
2. `RESET_WAIT`: Drives `O_psram_reset_n` High and waits `tVCS` (150 us).
3. `IDLE`: Awaits `req` (`busy = 0`, `ready = 0`).
4. `SEND_CA`: Drives `CS# = 0` and transmits the 48-bit CA packet over 6 system cycles.
5. `WAIT_LATENCY`: Waits 12 PSRAM clocks (24 system cycles).
6. `WRITE_DATA`: Drives 32-bit `wdata` in two DDR half-cycles (Word 0, Word 1).
7. `READ_DATA`: Samples 32-bit `rdata` in two DDR half-cycles (Word 0, Word 1).
8. `RECOVERY`: De-asserts `CS# = 1`, waits `tRWR`, pulses `ready = 1`, and returns to `IDLE`.

---

## 5. RISC-V SoC Integration Guide

To connect `psram_controller` to a RISC-V processor (e.g., `unified_cpu` in the VUX9K SoC):
1. In the address decoder, map PSRAM to an address space (e.g., `0x8000_0000` - `0x807F_FFFF` for 64Mbit).
2. Route the CPU's memory read/write requests to `req`, `we`, `addr`, `wdata`, and `wstrb`.
3. When `busy` is asserted, stall the CPU pipeline (`MEM_WAIT` state).
4. When `ready` pulses, latch `rdata` into the CPU load data register and resume execution.
