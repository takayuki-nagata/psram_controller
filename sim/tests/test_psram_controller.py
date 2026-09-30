# Copyright (c) 2026 Takayuki Nagata
# SPDX-License-Identifier: MIT

"""cocotb tests of psram_controller against the W955D8MBYA model (sim/model/).

Every test ends with PsramEnv.finish(), which fails on any protocol or timing violation
the model reported. Data is checked both through the host interface and in the model
memory (backdoor), so an access that lands on the wrong PSRAM word is caught even when
the read-back through the same wrong path would look right.
"""

import random

import cocotb
from cocotb.triggers import FallingEdge
from psram_env import (
    CR0_DEFAULT,
    ID0_VALUE,
    ID1_VALUE,
    MEM_BYTES,
    REG_CR0,
    REG_ID0,
    REG_ID1,
    T_VCS_NS,
    PsramEnv,
    die_words,
    reg_write_data,
)


def strobe_merge(old: int, new: int, wstrb: int) -> int:
    mask = sum(0xFF << (8 * i) for i in range(4) if wstrb >> i & 1)
    return (old & ~mask) | (new & mask)


async def write_and_check(env: PsramEnv, addr: int, data: int):
    await env.write(addr, data)
    stored = env.backdoor_word(addr)
    assert stored == data, f"write {data:#010x} to {addr:#08x}: model memory holds {stored!r:}"


@cocotb.test()
async def test_init(dut):
    """Power-up sequence: not ready until initialized, no access before tVCS, model clean."""
    env = PsramEnv(dut)
    await env.start(wait_init=False)
    assert dut.init_done.value == 0 and dut.req_ready.value == 0, "controller ready during initialization"
    cycles = 0
    while dut.init_done.value == 0:
        await FallingEdge(dut.clk)
        cycles += 1
        assert cycles * env.period_ps / 1000 < 2 * T_VCS_NS, "initialization takes too long"
    assert cycles * env.period_ps / 1000 >= T_VCS_NS, "initialization shorter than tVCS"
    await env.finish()


@cocotb.test()
async def test_id_registers(dut):
    """ID0/ID1 register reads return the Winbond values of both dies."""
    env = PsramEnv(dut)
    await env.start()
    for addr, value in ((REG_ID0, ID0_VALUE), (REG_ID1, ID1_VALUE)):
        got = await env.read(addr)
        expected = reg_write_data(value)
        assert got == expected, f"register {addr:#08x}: read {got:#010x}, expected {expected:#010x}"
    await env.finish()


@cocotb.test()
async def test_cr0_write(dut):
    """CR0 write (zero latency, no RWDS mask) and read-back, then restore the default."""
    env = PsramEnv(dut)
    await env.start()
    got = await env.read(REG_CR0)
    assert got == reg_write_data(CR0_DEFAULT), f"CR0 default read {got:#010x}"
    new = (CR0_DEFAULT & ~0x3) | 0x2  # wrapped burst length 16 bytes
    await env.write(REG_CR0, reg_write_data(new))
    assert env.model_cr0(0) == new and env.model_cr0(1) == new, "CR0 not written in both dies"
    got = await env.read(REG_CR0)
    assert got == reg_write_data(new), f"CR0 read-back {got:#010x}"
    await env.write(REG_CR0, reg_write_data(CR0_DEFAULT))
    assert env.model_cr0(0) == CR0_DEFAULT and env.model_cr0(1) == CR0_DEFAULT
    # Memory accesses still work with the restored configuration
    await write_and_check(env, 0x100, 0x13579BDF)
    assert await env.read(0x100) == 0x13579BDF
    await env.finish()


@cocotb.test()
async def test_write_strobes(dut):
    """All 16 byte-strobe combinations merge into the stored word correctly."""
    env = PsramEnv(dut)
    await env.start()
    base = 0x1000
    for wstrb in range(16):
        addr = base + 4 * wstrb
        await env.write(addr, 0xFFFFFFFF)
        data = 0x11223344 ^ (wstrb * 0x01010101)
        await env.write(addr, data, wstrb)
        expected = strobe_merge(0xFFFFFFFF, data, wstrb)
        stored = env.backdoor_word(addr)
        assert stored == expected, f"wstrb={wstrb:04b}: model memory {stored!r}, expected {expected:#010x}"
        got = await env.read(addr)
        assert got == expected, f"wstrb={wstrb:04b}: read {got:#010x}, expected {expected:#010x}"
    await env.finish()


@cocotb.test()
async def test_address_walk(dut):
    """Walking-one addresses over the full 8 MB: every address bit reaches the PSRAM and
    no two addresses alias."""
    env = PsramEnv(dut)
    await env.start()
    addrs = [0] + [1 << b for b in range(2, 23)]
    addrs += [(MEM_BYTES - 4) ^ (1 << b) for b in range(2, 23)] + [MEM_BYTES - 4]
    values = {a: (0xA5000000 | i * 0x10101) & 0xFFFFFFFF for i, a in enumerate(addrs)}
    for a, v in values.items():
        await write_and_check(env, a, v)
    for a, v in values.items():
        got = await env.read(a)
        assert got == v, f"{a:#08x}: read {got:#010x}, expected {v:#010x} (address aliasing?)"
    await env.finish()


@cocotb.test()
async def test_neighbours(dut):
    """Consecutive words: writing one word must not disturb its neighbours."""
    env = PsramEnv(dut)
    await env.start()
    base = 0x2000
    for i in range(8):
        env.backdoor_write(base + 4 * i, 0xC0DE0000 | i)
    await write_and_check(env, base + 12, 0x12345678)
    for i in range(8):
        expected = 0x12345678 if i == 3 else 0xC0DE0000 | i
        stored = env.backdoor_word(base + 4 * i)
        assert stored == expected, f"word {i}: model memory {stored!r}, expected {expected:#010x}"
        got = await env.read(base + 4 * i)
        assert got == expected, f"word {i}: read {got:#010x}, expected {expected:#010x}"
    await env.finish()


@cocotb.test()
async def test_boundaries(dut):
    """First/last word, wrapped-burst group (32 B per die = 64 B host) and row (1 KB per
    die = 2 KB host) boundaries."""
    env = PsramEnv(dut)
    await env.start()
    addrs = [0x0, 0x3C, 0x40, 0x7C, 0x7FC, 0x800, 0x3FFFFC, 0x400000, MEM_BYTES - 4]
    for i, a in enumerate(addrs):
        await write_and_check(env, a, 0x5A5A0000 | i)
    for i, a in enumerate(addrs):
        assert await env.read(a) == 0x5A5A0000 | i, f"{a:#08x}"
    await env.finish()


@cocotb.test()
async def test_random(dut):
    """Random reads/writes/strobes against a scoreboard, with random idle gaps."""
    env = PsramEnv(dut)
    await env.start()
    rng = random.Random(0x5EED)
    scoreboard: dict[int, int] = {}
    pool = [rng.randrange(0, MEM_BYTES, 4) for _ in range(64)]
    for _ in range(1500):
        addr = rng.choice(pool)
        for _ in range(rng.randrange(4)):
            await FallingEdge(dut.clk)
        if addr in scoreboard and rng.random() < 0.4:
            got = await env.read(addr)
            assert got == scoreboard[addr], f"{addr:#08x}: read {got:#010x}, expected {scoreboard[addr]:#010x}"
        else:
            data = rng.getrandbits(32)
            wstrb = 0xF if addr not in scoreboard else rng.randrange(1, 16)
            await env.write(addr, data, wstrb)
            scoreboard[addr] = strobe_merge(scoreboard.get(addr, 0), data, wstrb)
            assert env.backdoor_word(addr) == scoreboard[addr], f"{addr:#08x}: model memory mismatch"
    await env.finish()


@cocotb.test()
async def test_back_to_back(dut):
    """Requests issued in the first cycle the controller can accept them."""
    env = PsramEnv(dut)
    await env.start()
    data = {0x3000 + 4 * i: 0x0F0F0000 + i for i in range(16)}
    for a, v in data.items():
        await env.write(a, v)
    for a, v in data.items():
        assert await env.read(a) == v, f"{a:#08x}"
    for a, v in data.items():
        assert env.backdoor_word(a) == v, f"{a:#08x}: model memory"
    await env.finish()


@cocotb.test()
async def test_reset_during_access(dut):
    """Reset in the middle of a transaction: the controller re-initializes the PSRAM
    and works afterwards."""
    env = PsramEnv(dut)
    await env.start()
    await env.write(0x4000, 0x11111111)
    await env.request(True, 0x4004, 0x22222222)  # in flight from here on
    for _ in range(10):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 0
    env.accepted = env.responses  # the in-flight request is dropped by the reset
    for _ in range(5):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    await env.wait_init()
    await write_and_check(env, 0x4008, 0x33333333)
    assert await env.read(0x4008) == 0x33333333
    await env.finish()


@cocotb.test()
async def test_handshake(dut):
    """valid/ready: a request is held while the controller is busy (and before init_done),
    accepted exactly once, and answered exactly once."""
    env = PsramEnv(dut)
    await env.start(wait_init=False)
    # Presented during initialization: held until init_done, then accepted
    env.backdoor_write(0x5000, 0xAAAA5555)
    await env.request(False, 0x5000, max_cycles=100_000)
    assert dut.init_done.value == 1
    assert await env.response(False, 0x5000) == 0xAAAA5555
    # Presented while busy with a read: not accepted until the read has been answered
    await env.request(False, 0x5000)
    dut.req_valid.value = 1
    dut.req_we.value = 1
    dut.req_addr.value = 0x5004
    dut.req_wdata.value = 0x12345678
    dut.req_wstrb.value = 0xF
    busy_cycles = 0
    while True:
        await FallingEdge(dut.clk)
        if dut.rsp_valid.value == 1:
            assert dut.rsp_rdata.value.to_unsigned() == 0xAAAA5555
            break
        assert dut.req_ready.value == 0, "req_ready while a request is in flight"
        busy_cycles += 1
    assert busy_cycles > 10
    # The held write is accepted in the cycle of the read response (back-to-back)
    assert dut.req_ready.value == 1, "controller not ready in the cycle of its response"
    await env.request(True, 0x5004, 0x12345678)
    await env.response(True, 0x5004)
    assert env.backdoor_word(0x5004) == 0x12345678
    await env.finish()
    assert env.accepted == 3 and env.responses == 3


# Documentation of the die mapping used by the backdoor (kept executable)
assert die_words(0x44332211) == (0x1133, 0x2244)


async def _latency(env: PsramEnv, we: bool, addr: int, wdata: int = 0x01020304) -> int:
    """N such that a request accepted in cycle 0 (req_valid && req_ready) gets rsp_valid
    in cycle N."""
    await env.request(we, addr, wdata)
    cycles = 1  # request() returns in cycle 1 (after the falling edge that follows acceptance)
    while env.dut.rsp_valid.value == 0:
        await FallingEdge(env.dut.clk)
        cycles += 1
    return cycles


@cocotb.test()
async def test_latency(dut):
    """Access latency, documented in README/docs for integrators (same at 18 and 27 MHz)."""
    env = PsramEnv(dut)
    await env.start()
    measured = {
        "memory write": await _latency(env, True, 0x6000),
        "memory read": await _latency(env, False, 0x6000),
        "register write": await _latency(env, True, REG_CR0, reg_write_data(CR0_DEFAULT)),
    }
    dut._log.info(f"latency (cycles): {measured}")
    assert measured == {"memory write": 34, "memory read": 35, "register write": 12}, measured
    await env.finish()
