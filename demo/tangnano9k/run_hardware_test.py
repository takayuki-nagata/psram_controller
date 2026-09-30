#!/usr/bin/env python3
# Copyright (c) 2026 Takayuki Nagata
# SPDX-License-Identifier: MIT

"""Monitor the USB-UART output to verify Tang Nano 9K PSRAM Controller hardware test."""

import argparse
import re
import subprocess
import sys
import time

import serial


def analyze_trace(trace_lines):
    """Analyze real-time pin trace output from FPGA."""
    print("\n" + "=" * 65)
    print("            REAL-TIME PIN TRACE ANALYSIS REPORT")
    print("=" * 65)

    ca_cycles = []
    response_cycles = []
    rwds_high_count = 0
    chip_active = False

    state_names = {
        0: "RESET_ASSERT",
        1: "RESET_WAIT",
        2: "IDLE",
        3: "SEND_CA",
        4: "WAIT_LATENCY",
        5: "WRITE_DATA",
        6: "READ_DATA",
        7: "RECOVERY",
    }

    print(
        f"{'CYC':>4} | {'STATE':<12} | {'TM':>2} | {'CS#':>3} {'CK':>2} {'OE':>2} | "
        f"{'RWDS':>4} | {'DQ[15:8]':>8} {'DQ[7:0]':>7} | NOTES"
    )
    print("-" * 65)

    for line in trace_lines:
        m = re.match(
            r"C([0-9A-F]{2}):\s*([0-9A-F])\s+([0-9A-F]{2})\s+([01])\s+([01])\s+([01])\s+([01]{2})\s+([0-9A-F]{2})\s+([0-9A-F]{2})",
            line.strip(),
        )
        if not m:
            continue

        cyc = int(m.group(1), 16)
        st_num = int(m.group(2), 16)
        st_name = state_names.get(st_num, f"UNKNOWN({st_num})")
        tm = m.group(3)
        cs = m.group(4)
        ck = m.group(5)
        oe = m.group(6)
        rwds = m.group(7)
        dq1 = m.group(8)
        dq0 = m.group(9)

        note = ""
        # Check CA phase
        if oe == "1":
            note = f"FPGA driving CA (0x{dq1}{dq0})"
            ca_cycles.append(cyc)
        else:
            # OE is 0 (FPGA listening to PSRAM)
            if rwds != "00":
                rwds_high_count += 1
            if dq1 != "FF" or dq0 != "FF":
                chip_active = True
                note = f"<-- CHIP ACTIVE! DQ=0x{dq1}{dq0}"
                response_cycles.append((cyc, dq1, dq0, rwds))

        print(f"{cyc:4d} | {st_name:<12} | {tm:>2} | {cs:>3} {ck:>2} {oe:>2} | {rwds:>4} | {dq1:>8} {dq0:>7} | {note}")

    print("-" * 65)
    print("=== DIAGNOSTIC SUMMARY ===")
    if chip_active:
        print(
            f"[*] CHIP RESPONSE DETECTED! First response at cycle {response_cycles[0][0]}: "
            f"DQ=0x{response_cycles[0][1]}{response_cycles[0][2]}, RWDS={response_cycles[0][3]}"
        )
        for c, d1, d0, rw in response_cycles:
            print(f"    - Cycle {c:2d}: DQ[15:8]=0x{d1} DQ[7:0]=0x{d0} RWDS={rw}")
        # Check ID0 value
        id0_found = any(d0 == "5F" or d1 == "5F" for _, d1, d0, _ in response_cycles)
        if id0_found:
            print("[+] Winbond PSRAM ID0 match confirmed (0x5F / Winbond 32Mb die)!")
        else:
            print("[?] Non-default register value received. Check bus alignment or die configuration.")
    else:
        print("[-] NO CHIP RESPONSE: DQ remained 0xFFFF (pull-up / Hi-Z) throughout trace!")
        print("    Possible causes: PSRAM not powered, reset polarity/timing, or clock not reaching chip.")

    if rwds_high_count > 0:
        print(f"[*] RWDS was driven High for {rwds_high_count} cycles (indicates 2x Fixed Latency mode).")
    else:
        print("[*] RWDS remained Low throughout (indicates 1x Variable Latency or unasserted).")
    print("=" * 65 + "\n")


def main():
    parser = argparse.ArgumentParser(description="Tang Nano 9K PSRAM Hardware Test Monitor")
    parser.add_argument("--port", default="/dev/ttyUSB3", help="Serial port (default: /dev/ttyUSB3)")
    parser.add_argument("--baud", type=int, default=115200, help="Baud rate (default: 115200)")
    parser.add_argument("--timeout", type=float, default=8.0, help="Timeout in seconds (default: 8.0)")
    parser.add_argument("--prog-cmd", default=None, help="Optional command to program FPGA while listening")
    args = parser.parse_args()

    print(f"=== Opening {args.port} at {args.baud} baud (Timeout: {args.timeout}s) ===")
    try:
        ser = serial.Serial(args.port, args.baud, timeout=0.05)
    except serial.SerialException as e:
        print(f"ERROR: Failed to open serial port {args.port}: {e}", file=sys.stderr)
        return 1

    ser.reset_input_buffer()

    if args.prog_cmd:
        print(f"=== Executing program command: {args.prog_cmd} ===")
        res = subprocess.run(args.prog_cmd, shell=True)
        if res.returncode != 0:
            print(f"ERROR: Program command failed with exit code {res.returncode}", file=sys.stderr)
            ser.close()
            return res.returncode
        print("=== FPGA configured! Listening for PSRAM test output... ===")

    start_time = time.time()
    collected = ""
    trace_lines = []
    in_trace = False
    passed = False
    failed = False

    try:
        while time.time() - start_time < args.timeout:
            raw = ser.read(128)
            if raw:
                text = raw.decode("utf-8", errors="replace")
                sys.stdout.write(text)
                sys.stdout.flush()
                collected += text

                for line in text.splitlines():
                    if "=== PSRAM TRACE" in line:
                        in_trace = True
                    elif "=== END TRACE" in line:
                        in_trace = False
                    elif in_trace and line.startswith("C"):
                        trace_lines.append(line)

                if "TEST PASSED" in collected:
                    passed = True
                    break
                elif "TEST FAILED" in collected or "FAIL!" in collected or "ERROR" in collected:
                    failed = True
                    break
            else:
                time.sleep(0.01)
    finally:
        ser.close()

    if trace_lines:
        analyze_trace(trace_lines)

    print("\n------------------------------------------------------------")
    if passed:
        print(">>> SUCCESS: PSRAM Hardware Read/Write Test PASSED on Tang Nano 9K! <<<")
        return 0
    elif failed:
        print(">>> FAILURE: PSRAM Hardware Test Reported ERROR! <<<", file=sys.stderr)
        return 1
    else:
        print(f">>> TIMEOUT: Did not receive expected response within {args.timeout}s <<<", file=sys.stderr)
        if collected:
            print(f"Received so far: {repr(collected)}")
        return 2


if __name__ == "__main__":
    sys.exit(main())
