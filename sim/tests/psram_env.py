# Copyright (c) 2026 Takayuki Nagata
# SPDX-License-Identifier: MIT

"""Shared test environment for tb_psram_controller: clock, reset, host driver,
address map and the W955D8MBYA model backdoor.

The host driver is the only place that knows the controller's bus protocol, so the
tests themselves stay the same when the interface changes.
"""

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, Timer

# ---------------------------------------------------------------- address map
# Memory space: byte address, 4-byte aligned. Each 32-bit host word is one 16-bit word
# in each die (die 0 = DQ[7:0], die 1 = DQ[15:8]), so the die word address is addr[22:2].
MEM_BYTES = 8 * 1024 * 1024
DIE_WORDS = 1 << 21

# Register space: addr[23] = 1; die register addresses (datasheet Table 5) CA[16] and CA[0]
# are word address bits 3 and 0, i.e. host address bits 5 and 2.
REG_ID0 = 0x800000
REG_ID1 = 0x800004
REG_CR0 = 0x800020
REG_CR1 = 0x800024

ID0_VALUE = 0x005F
ID1_VALUE = 0x000F
CR0_DEFAULT = 0x8F1F

T_VCS_NS = 150_000


def clk_mhz() -> float:
    return float(os.environ.get("PSRAM_CLK_MHZ", "27"))


def die_words(word: int) -> tuple[int, int]:
    """Host 32-bit word -> (die 0 word, die 1 word). The first byte of a die word
    ([15:8]) is transferred on the rising CK edge, i.e. in host bits [15:0]."""
    d0 = ((word & 0xFF) << 8) | ((word >> 16) & 0xFF)
    d1 = (((word >> 8) & 0xFF) << 8) | ((word >> 24) & 0xFF)
    return d0, d1


def host_word(d0: int, d1: int) -> int:
    """(die 0 word, die 1 word) -> host 32-bit word; inverse of die_words()."""
    return ((d0 >> 8) & 0xFF) | (((d1 >> 8) & 0xFF) << 8) | ((d0 & 0xFF) << 16) | ((d1 & 0xFF) << 24)


def reg_write_data(value: int) -> int:
    """Host write data that loads the same 16-bit register value into both dies."""
    return host_word(value, value)


class ModelErrors(AssertionError):
    pass


class PsramEnv:
    """All host-side driving happens right after a falling clock edge, and all sampling at
    falling edges, so values are stable and the controller sees them at the next rising edge."""

    def __init__(self, dut):
        self.dut = dut
        self.period_ps = 2 * round(1e6 / clk_mhz() / 2)
        self.clock = None
        self.accepted = 0
        self.responses = 0
        self._monitor = None

    # ------------------------------------------------------------ setup
    async def start(self, wait_init: bool = True):
        dut = self.dut
        self.clock = Clock(dut.clk, self.period_ps, unit="ps")
        self.clock.start()
        self.idle_inputs()
        dut.rst_n.value = 0
        for _ in range(10):
            await FallingEdge(dut.clk)
        dut.rst_n.value = 1
        self._monitor = cocotb.start_soon(self._protocol_monitor())
        if wait_init:
            await self.wait_init()

    def idle_inputs(self):
        dut = self.dut
        dut.req_valid.value = 0
        dut.req_we.value = 0
        dut.req_addr.value = 0
        dut.req_wdata.value = 0
        dut.req_wstrb.value = 0

    async def wait_init(self, timeout_us: float = 2000.0):
        """Wait (at falling edges) until the controller finished the PSRAM power-up sequence."""
        cycles = int(timeout_us * 1e6 / self.period_ps)
        for _ in range(cycles):
            await FallingEdge(self.dut.clk)
            if self.dut.init_done.value == 1:
                return
        raise TimeoutError("controller did not finish initialization")

    async def _protocol_monitor(self):
        """Host interface rules, checked on every cycle of every test:
        at most one request in flight, exactly one response per accepted request,
        req_ready Low before init_done, request payload stable until accepted."""
        dut = self.dut
        outstanding = 0
        held = None
        while True:
            # After the falling edge settled: the inputs the controller will sample at the next
            # rising edge, and its state (req_ready, rsp_valid) since the last one
            await FallingEdge(dut.clk)
            await ReadOnly()
            if dut.rst_n.value == 0:
                outstanding, held = 0, None
                continue
            # A response registered at the last rising edge
            if dut.rsp_valid.value == 1:
                assert outstanding == 1, "rsp_valid without an accepted request"
                outstanding -= 1
                self.responses += 1
            valid = dut.req_valid.value == 1
            ready = dut.req_ready.value == 1
            if ready:
                assert dut.init_done.value == 1, "req_ready before init_done"
            payload = (
                int(dut.req_we.value),
                int(dut.req_addr.value),
                int(dut.req_wdata.value),
                int(dut.req_wstrb.value),
            )
            if held is not None:
                assert valid and payload == held, "request withdrawn or changed before it was accepted"
            if valid and ready:  # accepted at the next rising edge
                assert outstanding == 0, "controller accepted a second request while one is in flight"
                outstanding += 1
                self.accepted += 1
                held = None
            elif valid:
                held = payload

    # ------------------------------------------------------------ host bus
    async def request(self, we: bool, addr: int, wdata: int = 0, wstrb: int = 0xF, max_cycles: int = 500):
        """Present a request and hold it until accepted. Call right after a falling edge;
        returns right after the falling edge that follows the accepting rising edge."""
        dut = self.dut
        dut.req_valid.value = 1
        dut.req_we.value = int(we)
        dut.req_addr.value = addr
        dut.req_wdata.value = wdata
        dut.req_wstrb.value = wstrb
        for _ in range(max_cycles):
            await ReadOnly()
            ready = dut.req_ready.value == 1
            await FallingEdge(dut.clk)
            if ready:
                self.idle_inputs()
                return
        raise TimeoutError(f"request for {addr:#08x} not accepted")

    async def response(self, we: bool, addr: int, max_cycles: int = 500) -> int:
        """Wait (at falling edges) for the response; returns rsp_rdata for reads."""
        dut = self.dut
        for _ in range(max_cycles):
            if dut.rsp_valid.value == 1:
                value = dut.rsp_rdata.value
                if not we and not value.is_resolvable:
                    raise AssertionError(f"read of {addr:#08x} returned {value} (X/Z)")
                return 0 if we else value.to_unsigned()
            await FallingEdge(dut.clk)
        raise TimeoutError(f"no response for {'write' if we else 'read'} of {addr:#08x}")

    async def access(self, we: bool, addr: int, wdata: int = 0, wstrb: int = 0xF) -> int:
        """One access; returns rdata (reads) or 0. Starts and ends right after a falling edge."""
        await self.request(we, addr, wdata, wstrb)
        return await self.response(we, addr)

    async def write(self, addr: int, data: int, wstrb: int = 0xF):
        await self.access(True, addr, data, wstrb)

    async def read(self, addr: int) -> int:
        return await self.access(False, addr)

    # ------------------------------------------------------------ model backdoor
    def _die(self, i: int):
        return self.dut.psram.die0 if i == 0 else self.dut.psram.die1

    def backdoor_word(self, addr: int) -> int | None:
        """Host word stored at addr in the model memory (None if any byte is unwritten)."""
        waddr = (addr >> 2) & (DIE_WORDS - 1)
        vals = [self._die(i).mem[waddr].value for i in (0, 1)]
        if not all(v.is_resolvable for v in vals):
            return None
        return host_word(vals[0].to_unsigned(), vals[1].to_unsigned())

    def backdoor_write(self, addr: int, word: int):
        waddr = (addr >> 2) & (DIE_WORDS - 1)
        d0, d1 = die_words(word)
        self._die(0).mem[waddr].value = d0
        self._die(1).mem[waddr].value = d1

    def model_cr0(self, die: int) -> int:
        return self._die(die).cr0.value.to_unsigned()

    def model_errors(self) -> int:
        return self.dut.psram.error_count.value.to_unsigned()

    async def finish(self):
        """End of every test: let the last transaction settle, then require a clean model
        and a response for every accepted request."""
        await Timer(1, unit="us")
        assert self.accepted == self.responses, f"{self.accepted} requests accepted, {self.responses} responses"
        errors = self.model_errors()
        if errors:
            raise ModelErrors(f"PSRAM model reported {errors} protocol/timing violation(s); see the log")
