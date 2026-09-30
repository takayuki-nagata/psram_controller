# Copyright (c) 2026 Takayuki Nagata
# SPDX-License-Identifier: MIT

"""Shared test environment for tb_psram_controller: clock, reset, host driver,
address map and the W955D8MBYA model backdoor.

The host driver is the only place that knows the controller's bus protocol, so the
tests themselves stay the same when the interface changes.
"""

import os

from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

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
    def __init__(self, dut):
        self.dut = dut
        self.period_ps = 2 * round(1e6 / clk_mhz() / 2)
        self.clock = None

    # ------------------------------------------------------------ setup
    async def start(self, wait_init: bool = True):
        dut = self.dut
        self.clock = Clock(dut.clk, self.period_ps, unit="ps")
        self.clock.start()
        self._idle_inputs()
        dut.rst_n.value = 0
        for _ in range(10):
            await FallingEdge(dut.clk)
        dut.rst_n.value = 1
        if wait_init:
            await self.wait_init()

    def _idle_inputs(self):
        dut = self.dut
        dut.req.value = 0
        dut.we.value = 0
        dut.addr.value = 0
        dut.wdata.value = 0
        dut.wstrb.value = 0

    async def wait_init(self, timeout_us: float = 2000.0):
        """Wait until the controller finished the PSRAM power-up sequence."""
        cycles = int(timeout_us * 1e6 / self.period_ps)
        for _ in range(cycles):
            await FallingEdge(self.dut.clk)
            if self.dut.busy.value == 0:
                return
        raise TimeoutError("controller did not finish initialization")

    # ------------------------------------------------------------ host bus
    async def access(self, we: bool, addr: int, wdata: int = 0, wstrb: int = 0xF, max_cycles: int = 500) -> int:
        """One access through the host interface; returns rdata (reads) or 0."""
        dut = self.dut
        await FallingEdge(dut.clk)
        while dut.busy.value == 1:
            await FallingEdge(dut.clk)
        dut.req.value = 1
        dut.we.value = int(we)
        dut.addr.value = addr
        dut.wdata.value = wdata
        dut.wstrb.value = wstrb
        await FallingEdge(dut.clk)
        self._idle_inputs()
        for _ in range(max_cycles):
            if dut.ready.value == 1:
                value = dut.rdata.value
                if not we and not value.is_resolvable:
                    raise AssertionError(f"read of {addr:#08x} returned {value} (X/Z)")
                return 0 if we else value.to_unsigned()
            await FallingEdge(dut.clk)
        raise TimeoutError(f"no response for {'write' if we else 'read'} of {addr:#08x}")

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
        """End of every test: let the last transaction settle, then require a clean model."""
        await Timer(1, unit="us")
        errors = self.model_errors()
        if errors:
            raise ModelErrors(f"PSRAM model reported {errors} protocol/timing violation(s); see the log")
