# Using the controller in another project (VUX9K)

This IP is meant to be used as a git submodule and a Veryl path dependency. Everything a
host project needs is in `rtl/` (Veryl only, no hand-written SystemVerilog); the board
demo in `demo/tangnano9k/` is a separate Veryl project and is not pulled in.

## 1. Add the submodule and the Veryl dependency

```sh
git submodule add <url of this repository> vendor/psram_controller
git -C vendor/psram_controller checkout <tag>   # pin a tagged, hardware-verified release
```

`Veryl.toml` of the host project:

```toml
[dependencies]
psram = { path = "vendor/psram_controller" }
```

Veryl then builds the IP together with the host project and prefixes its modules and
packages with the dependency name, so they cannot clash with the host's own modules:

| In this repository | Seen by the host (`psram = ...`) | Generated file (`veryl build --out-dir build/veryl`) |
|---|---|---|
| `psram_pkg` | `psram::psram_pkg` → `psram_psram_pkg` | `build/veryl/dependencies/psram/rtl/psram_pkg.sv` |
| `psram_core` | `psram_psram_core` | `.../rtl/psram_core.sv` |
| `psram_phy` | `psram_psram_phy` | `.../rtl/psram_phy.sv` |
| `psram_controller` | `psram::psram_controller` → `psram_psram_controller` | `.../rtl/psram_controller.sv` |

A host project that keeps its own file lists (VUX9K's Makefile and
`sim/runners/sim_runner.py`) adds these four files, `psram_pkg.sv` first.
Checked with Veryl 0.21.0: a subdirectory with its own `Veryl.toml` is skipped by the
host's source scan, so only the dependency mechanism brings the IP in.

## 2. Instantiate

```veryl
inst u_psram: psram::psram_controller #(
    CLK_HZ: 18_000_000,
) (
    clk, rst_n,
    req_valid, req_ready, req_we, req_addr, req_wdata, req_wstrb,
    rsp_valid, rsp_rdata, init_done,
    O_psram_ck, O_psram_ck_n, O_psram_cs_n, O_psram_reset_n,
    IO_psram_dq, IO_psram_rwds,
    dbg_sample: _,
);
```

The `O_psram_*` / `IO_psram_*` ports go straight to top-level ports with the pin
constraints of [`demo/tangnano9k/tangnano9k.cst`](../demo/tangnano9k/tangnano9k.cst)
(lines for `O_psram_*` and `IO_psram_*`), Bank 1, LVCMOS18.

## 3. Interface contract

- **Clock**: `CLK_HZ` is the system clock frequency; the PSRAM clock is `CLK_HZ / 2`.
  Tested at 18 MHz and 27 MHz in simulation, formally and on the Tang Nano 9K (full 8 MB
  memory test). The whole
  transaction must fit in tCSM (4 us): about 40 cycles, so `CLK_HZ` >= 10 MHz.
- **Request**: accepted in a cycle with `req_valid && req_ready`. Once `req_valid` is
  raised it must stay High with `req_we`/`req_addr`/`req_wdata`/`req_wstrb` unchanged
  until accepted. `req_ready` is Low until `init_done` (about 200 us after reset) and
  while a request is in flight.
- **Response**: exactly one per request, `rsp_valid` High for one cycle; `rsp_rdata`
  is valid in that cycle for reads. `req_ready` is High again in the same cycle, so the
  next request can be accepted back-to-back.
- **Latency**: a 32-bit access takes about 38 cycles from acceptance to response.
- **Addresses**: byte address, 4-byte aligned (`req_addr[1:0]` ignored).
  `req_addr[23] = 0`: 8 MB of memory; `= 1`: register space, see `psram_pkg::REG_ADDR_*`
  (ID0 `0x800000`, ID1 `0x800004`, CR0 `0x800020`, CR1 `0x800024`).
  A register value `v` is written to both dies with
  `req_wdata = {v[7:0], v[7:0], v[15:8], v[15:8]}`; register writes ignore `req_wstrb`.
- **Byte enables**: `req_wstrb[i]` writes byte `i` of `req_wdata` (memory writes).
- **Reset**: `rst_n` is asynchronous, active Low; a reset during a transaction aborts it
  (no response) and restarts the PSRAM power-up sequence.

## 4. What the host project has to provide (VUX9K)

- A stall in the CPU bus: VUX9K's `unified_cpu` expects load data exactly one cycle after
  the address. A bridge (e.g. `soc/psram/soc_psram_bridge.veryl`) turns a load/store to
  the PSRAM window into a held request and stalls the CPU until `rsp_valid`.
- An address window for the 8 MB (a free region of `soc_addr_decoder`).
- The PSRAM pins on `board_top` and in its `.cst`, and the model
  (`sim/model/w955d8mbya_*.sv`) in the SoC testbench.

## 5. Checks in this repository

| Command | What it proves |
|---|---|
| `make test-sim` | cocotb tests at 18 and 27 MHz against a datasheet-based W955D8MBYA model with timing checkers; data checked through the interface and in the model memory |
| `make formal` | SymbiYosys proofs of the interface contract, tCSM, bus direction and RESET# (`formal/`) |
| `make lint` | Verilator `-Wall`, warnings fatal |
| `make eqy` | refactors equivalent to a base commit |
| `make sta` | nextpnr timing at 27 MHz, 5 seeds |
| `make test-hw` | board demo: pin trace of an ID0 read and a memory test on the Tang Nano 9K |
