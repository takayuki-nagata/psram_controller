# Using the controller in another project (VUX9K)

This IP is meant to be used as a git submodule and a Veryl path dependency. Everything a
host project needs is in `rtl/` (Veryl only, no hand-written SystemVerilog); the board
demo in `demo/tangnano9k/` is a separate Veryl project and is not pulled in.

## 1. Add the submodule and the Veryl dependency

```sh
git submodule add https://github.com/takayuki-nagata/psram_controller.git vendor/psram_controller
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
    CLK_HZ         : 18_000_000,
    MAX_BURST_WORDS: 8,          // default 1: no bursts
) (
    clk, rst_n,
    req_valid, req_ready, req_we, req_addr, req_wdata, req_wstrb, req_len,
    rsp_valid, rsp_last, rsp_rdata, wdata_next, init_done,
    O_psram_ck, O_psram_ck_n, O_psram_cs_n, O_psram_reset_n,
    IO_psram_dq, IO_psram_rwds,
    dbg_sample: _,
);
```

Without bursts (v0.1.0 behaviour, cycle for cycle): keep `MAX_BURST_WORDS` at 1, tie
`req_len` to `1'b0`, and leave `rsp_last` (equal to `rsp_valid` then) and `wdata_next`
(always Low then) unconnected.

The `O_psram_*` / `IO_psram_*` ports go straight to top-level ports with the pin
constraints of [`demo/tangnano9k/tangnano9k.cst`](../demo/tangnano9k/tangnano9k.cst)
(lines for `O_psram_*` and `IO_psram_*`), Bank 1, LVCMOS18.

## 3. Interface contract

- **Clock**: `CLK_HZ` is the system clock frequency; the PSRAM clock is `CLK_HZ / 2`.
  Tested at 18 MHz and 27 MHz in simulation, formally and on the Tang Nano 9K (full 8 MB
  memory test, single words and 16-word bursts). The longest transaction must fit in tCSM
  (4 us), see [tCSM and the lowest clock](#tcsm-and-the-lowest-clock).
- **Bursts**: `MAX_BURST_WORDS` (1, 2, 4, 8 or 16; default 1) is the longest burst;
  `req_len` (`max(1, clog2(MAX_BURST_WORDS))` bits) is the number of words - 1,
  N = `req_len` + 1. A burst (`req_len` > 0) must be a memory access with `req_addr`
  aligned to 4N bytes. Register accesses
  use `req_len = 0` (the controller treats them as single words regardless). Words are
  transferred in ascending address order from `req_addr`.
- **Request**: accepted in a cycle with `req_valid && req_ready`. Once `req_valid` is
  raised it must stay High with `req_we`/`req_addr`/`req_wdata`/`req_wstrb`/`req_len`
  unchanged until accepted. `req_ready` is Low until `init_done` (about 200 us after
  reset) and while a request is in flight.
- **Response**: reads get one response per word, writes one response: `rsp_valid` High
  for one cycle, `rsp_rdata` valid in that cycle for reads, `rsp_last` High with the
  last (for writes and single words: the only) response.
- **Burst write data**: word 0 is `req_wdata` with byte enables `req_wstrb` at
  acceptance. Word k (1..N-1) is `req_wdata` with byte enables `req_wstrb` in cycle
  29 + 2k, the cycle after `wdata_next` is High; both are don't-care in all other cycles
  after acceptance, and `req_valid` may be Low meanwhile. Any byte enables are allowed
  per word, `4'b0000` included (the word is not written but still takes its two cycles),
  and the data of disabled bytes may be X.
- **Timing**: fixed, see [the table below](#timing); no RWDS-dependent or variable
  latency. Checked cycle by cycle by `test_latency` (18 and 27 MHz) and proven for every
  length by `make formal`.
- **Addresses**: byte address, 4-byte aligned (`req_addr[1:0]` ignored).
  `req_addr[23] = 0`: 8 MB of memory; `= 1`: register space, see `psram_pkg::REG_ADDR_*`
  (ID0 `0x800000`, ID1 `0x800004`, CR0 `0x800020`, CR1 `0x800024`).
  A register value `v` is written to both dies with
  `req_wdata = {v[7:0], v[7:0], v[15:8], v[15:8]}`; register writes ignore `req_wstrb`.
  Do not change CR0's latency or burst fields: the controller relies on the default fixed
  latency, and on the default 32-byte wrapped burst for bursts of up to 16 words.
- **Byte enables**: `req_wstrb[i]` writes byte `i` of `req_wdata` (memory writes; per
  word in a burst write, see above). They drive the RWDS write masks; a disabled byte
  leaves the PSRAM byte unchanged.
- **Reset**: `rst_n` is asynchronous, active Low; a reset during a transaction aborts it
  (no further response) and restarts the PSRAM power-up sequence.

### Timing

Cycles after acceptance (cycle 0 = the cycle with `req_valid && req_ready`),
N = `req_len` + 1, k = 0..N-1 the word index, and

    R = ceil(36 ns * CLK_HZ)    (tRWR in system cycles; R = 1 for CLK_HZ <= 27.77 MHz)

R is the only term that depends on `CLK_HZ`. All other numbers are fixed. "req_ready"
is the cycle `req_ready` is High again, so the next request can be accepted in it.

| Access | `rsp_valid` | `rsp_last` | `wdata_next` | `req_ready` |
|---|---|---|---|---|
| read, `req_len = 0` | 34 + R | 34 + R | - | 34 + R |
| memory write, `req_len = 0` | 33 + R | 33 + R | - | 33 + R |
| register write | 11 + R | 11 + R | - | 11 + R |
| burst read, N >= 2 | 32 + 2k | 30 + 2N | - | 32 + 2N + R |
| burst write, N >= 2 | 31 + 2N + R | 31 + 2N + R | 28 + 2k, k = 1..N-1 | 31 + 2N + R |

At 18 and 27 MHz (R = 1):

| Access | `rsp_valid` | `rsp_last` | `wdata_next` | `req_ready` |
|---|---|---|---|---|
| read, `req_len = 0` | 35 | 35 | - | 35 |
| memory write, `req_len = 0` | 34 | 34 | - | 34 |
| register write | 12 | 12 | - | 12 |
| burst read, N >= 2 | 32 + 2k | 30 + 2N | - | 33 + 2N |
| burst write, N >= 2 | 32 + 2N | 32 + 2N | 28 + 2k, k = 1..N-1 | 32 + 2N |

For example, at 18 MHz an 8-word burst read delivers its words in cycles 32, 34, ..., 46
and is ready again in cycle 49; an 8-word burst write needs word k in cycle 29 + 2k
(31, 33, ..., 43) and responds and is ready in cycle 48. A single-word read through
`req_len = 0` keeps v0.1.0's 35 cycles, although a 1-word burst would have its data in
cycle 32: v0.1.0 responded after the CS# recovery.

### tCSM and the lowest clock

CS# is Low for 30 + 2N cycles in a read of N words and 29 + 2N in a write, at most
30 + 2 `MAX_BURST_WORDS`. With one cycle of margin the controller requires

    (31 + 2 * MAX_BURST_WORDS) / CLK_HZ <= 4 us

| `MAX_BURST_WORDS` | 1 | 2 | 4 | 8 | 16 |
|---|---|---|---|---|---|
| lowest `CLK_HZ` | 8.25 MHz | 8.75 MHz | 9.75 MHz | 11.75 MHz | 15.75 MHz |

`psram_core` checks this (and that `MAX_BURST_WORDS` is a power of 2 up to 16) with an
elaboration-time `$error`. Veryl emits the check inside `` `ifndef SYNTHESIS ``, so it
fires in Verilator (lint and simulation), Icarus Verilog and the formal flow, but not in
Yosys synthesis: run one of those on every configuration. `make formal` proves the CS#
Low bound in cycles for every length.

## 4. What the host project has to provide (VUX9K)

- A stall in the CPU bus: VUX9K's `unified_cpu` expects load data exactly one cycle after
  the address. A bridge (e.g. `soc/psram/soc_psram_bridge.veryl`) turns a load/store to
  the PSRAM window into a held request and stalls the CPU until `rsp_valid`.
- For bursts (cache line fills and write-backs): a line buffer that takes one read word
  per `rsp_valid`, and for writes supplies word k in the cycle after `wdata_next` (e.g. a
  block RAM read enabled by `wdata_next`).
- An address window for the 8 MB (a free region of `soc_addr_decoder`).
- The PSRAM pins on `board_top` and in its `.cst`, and the model
  (`sim/model/w955d8mbya_*.sv`) in the SoC testbench.

## 5. Checks in this repository

| Command | What it proves |
|---|---|
| `make test-sim` | cocotb tests at 18 and 27 MHz (`MAX_BURST_WORDS` 16, plus the single-word tests at 1) against a datasheet-based W955D8MBYA model with timing checkers; data checked through the interface and in the model memory; bursts of every length |
| `make formal` | SymbiYosys proofs of the interface contract including the timing table, tCSM, bus direction and RESET# (`formal/`), with `MAX_BURST_WORDS` 16 and 1 |
| `make lint` | Verilator `-Wall`, warnings fatal |
| `make eqy` | refactors equivalent to a base commit |
| `make sta` | nextpnr timing at 27 MHz, 5 seeds |
| `make test-hw` | board demo: pin trace of an ID0 read and a full 8 MB memory test (single words and 16-word bursts) on the Tang Nano 9K |
