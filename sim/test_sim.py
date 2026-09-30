# Copyright (c) 2026 Takayuki Nagata
# SPDX-License-Identifier: MIT

"""pytest entry point for the cocotb testbenches.

Each case runs one cocotb test of sim/tests/test_psram_controller.py at one system
clock frequency (the ones the IP is used at: 18 MHz in VUX9K, 27 MHz on the demo board).
Select with node IDs, e.g.  pytest -s "sim/test_sim.py::test_controller[18MHz-test_random]"
"""

import pytest
from runner import run

CLK_MHZ = [18, 27]

# Known controller bugs, found by these tests; strict, so fixing one fails the run until
# its entry is removed here.
DATA_PHASE_LATE = "data phase one PSRAM clock late (latency counted from the 3rd CA clock)"
ADDR_MAP = "die word address is addr[21:1] instead of addr[22:2]"
REG_WRITE = "register writes use the memory write latency instead of zero latency"
KNOWN_BUGS = {
    "test_id_registers": ADDR_MAP,
    "test_cr0_write": f"{REG_WRITE}; {ADDR_MAP}",
    "test_write_strobes": DATA_PHASE_LATE,
    "test_address_walk": f"{DATA_PHASE_LATE}; {ADDR_MAP}",
    "test_neighbours": DATA_PHASE_LATE,
    "test_boundaries": DATA_PHASE_LATE,
    "test_random": DATA_PHASE_LATE,
    "test_back_to_back": DATA_PHASE_LATE,
    "test_reset_during_access": DATA_PHASE_LATE,
}

TESTS = [
    "test_init",
    "test_id_registers",
    "test_cr0_write",
    "test_write_strobes",
    "test_address_walk",
    "test_neighbours",
    "test_boundaries",
    "test_random",
    "test_back_to_back",
    "test_reset_during_access",
]


def _case(name: str):
    if name in KNOWN_BUGS:
        return pytest.param(name, marks=pytest.mark.xfail(reason=KNOWN_BUGS[name], strict=True))
    return name


@pytest.mark.parametrize("testcase", [_case(t) for t in TESTS])
@pytest.mark.parametrize("mhz", CLK_MHZ, ids=[f"{m}MHz" for m in CLK_MHZ])
def test_controller(mhz, testcase):
    run(
        "tb_psram_controller",
        "test_psram_controller",
        testcase=testcase,
        run_name=f"{testcase}_{mhz}MHz",
        extra_env={"PSRAM_CLK_MHZ": str(mhz)},
    )
