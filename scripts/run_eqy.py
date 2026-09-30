# Copyright (c) 2026 Takayuki Nagata
# SPDX-License-Identifier: MIT

"""
Formal equivalence check of the working tree's IP against a base commit (make eqy).

For behavior-preserving refactors (same approach as VUX9K's scripts/run_eqy.py):
proves with Yosys eqy that <top> built from the working tree (gate) is equivalent
to <top> built from --base (gold). The base is exported with `git archive` into a
temporary directory and built there with the same `veryl`.

Both sides are flattened below <top>, so a refactor may change submodule
interfaces or move logic between submodules; only <top>'s own ports must match.
The sources of each side are the Veryl output for rtl/ plus any hand-written
rtl/*.sv, packages first.

Everything lands in build/eqy/: gold-<sha>/ (cached per base commit) and <top>/.
Exit code: 0 when equivalent, non-zero otherwise.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
EQY_DIR = REPO_ROOT / "build" / "eqy"


def run(cmd, **kwargs):
    return subprocess.run(cmd, check=True, **kwargs)


def rtl_files(tree: Path, veryl_out: Path) -> list[Path]:
    files = sorted(veryl_out.glob("rtl/*.sv")) + sorted(tree.glob("rtl/*.sv"))
    return [f for f in files if f.name.endswith("_pkg.sv")] + [f for f in files if not f.name.endswith("_pkg.sv")]


def build_gold(base: str, veryl: str) -> Path:
    """Sources of `base`, built once per commit into build/eqy/gold-<sha>/."""
    sha = run(["git", "rev-parse", "--verify", f"{base}^{{commit}}"], cwd=REPO_ROOT, capture_output=True, text=True)
    sha = sha.stdout.strip()
    gold = EQY_DIR / f"gold-{sha[:12]}"
    if (gold / ".done").exists():
        return gold
    shutil.rmtree(gold, ignore_errors=True)
    with tempfile.TemporaryDirectory(prefix="psram-eqy-") as tmp:
        archive = run(["git", "archive", sha], cwd=REPO_ROOT, capture_output=True).stdout
        run(["tar", "-x", "-C", tmp], input=archive)
        print(f"=== eqy: building gold RTL of {base} ({sha[:12]}) with {veryl} ===")
        run([veryl, "build", "--quiet", "--out-dir", "build/veryl"], cwd=tmp, stdout=subprocess.DEVNULL)
        gold.mkdir(parents=True)
        files = rtl_files(Path(tmp), Path(tmp) / "build" / "veryl")
        for f in files:
            shutil.copyfile(f, gold / f.name)
    (gold / "order.txt").write_text("\n".join(f.name for f in files))
    (gold / ".done").touch()
    return gold


def snapshot(files: list[Path], dst: Path) -> list[Path]:
    shutil.rmtree(dst, ignore_errors=True)
    dst.mkdir(parents=True)
    out = []
    for f in files:
        shutil.copyfile(f, dst / f.name)
        out.append(dst / f.name)
    return out


def eqy_config(top: str, gold: list[Path], gate: list[Path], depth: int, nomatch: list[str]) -> str:
    def side(name, files):
        return (
            f"[{name}]\n"
            f"read_verilog -sv {' '.join(str(f) for f in files)}\n"
            f"hierarchy -top {top}\n"
            f"prep -flatten -top {top}\n"
            "memory_map\n"
        )

    match = "\n[match *]\n" + "".join(f"gold-nomatch {p}\ngate-nomatch {p}\n" for p in nomatch) if nomatch else ""
    return (
        side("gold", gold)
        + "\n"
        + side("gate", gate)
        + "\n[options]\ninsbuf off\n"
        + match
        + f"\n[strategy sby]\nuse sby\ndepth {depth}\nengine smtbmc bitwuzla\n"
    )


def main():
    parser = argparse.ArgumentParser(description="Check RTL equivalence of the working tree against a base commit.")
    parser.add_argument("--base", default="HEAD", help="Commit whose RTL is the reference (default: HEAD)")
    parser.add_argument("--top", default="psram_controller", help="Module to compare (default: psram_controller)")
    parser.add_argument("--depth", type=int, default=5, help="sby induction depth per partition (default: 5)")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    parser.add_argument("--veryl", default=os.environ.get("VERYL", "veryl"))
    parser.add_argument(
        "--nomatch",
        nargs="*",
        default=[],
        help="Net-name patterns not to match between gold and gate (e.g. 'u_core.ca_packet*')",
    )
    args = parser.parse_args()
    sys.stdout.reconfigure(line_buffering=True)

    gate_out = REPO_ROOT / "build" / "veryl"
    if not (gate_out / "rtl").exists():
        raise SystemExit("run_eqy.py: build/veryl is missing; run `make veryl` first")

    gold_src = build_gold(args.base, args.veryl)
    gold_files = [gold_src / n for n in (gold_src / "order.txt").read_text().split()]
    work = EQY_DIR / args.top
    work.mkdir(parents=True, exist_ok=True)
    gold = snapshot(gold_files, work / "gold")
    gate = snapshot(rtl_files(REPO_ROOT, gate_out), work / "gate")
    config = work / f"{args.top}.eqy"
    config.write_text(eqy_config(args.top, gold, gate, args.depth, args.nomatch))

    print(f"=== eqy: {args.top} of the working tree vs {args.base} (log: {work / args.top / 'logfile.txt'}) ===")
    result = subprocess.run(["eqy", "-f", "-j", str(args.jobs), config.name], cwd=work)
    verdict = "EQUIVALENT" if result.returncode == 0 else "NOT PROVEN EQUIVALENT"
    print(f"=== eqy: {args.top} vs {args.base}: {verdict} ===")
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
