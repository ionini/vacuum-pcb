#!/usr/bin/env python3
"""Isolation truth table: with 1010 stored, drive the bus to 0101 under each
(WRITE,READ) combination, then read back. Shows which control state protects
the stored data from a driven bus."""
import re
import subprocess

BIN = "/Users/ioni/Documents/dev/vacuum_pcb/.build/release/vacuum-cli"
BITS = ["J1.B0", "J1.B1", "J1.B2", "J1.B3"]
P1010 = {"J1.B0": "vac", "J1.B1": "atm", "J1.B2": "vac", "J1.B3": "atm"}
P0101 = {"J1.B0": "atm", "J1.B1": "vac", "J1.B2": "atm", "J1.B3": "vac"}


def bits(pat=None, val=None):
    return ",".join(f"{b}={val or pat[b]}" for b in BITS)


def sim(board, phases):
    cmd = [BIN, "simulate", board]
    for ph in phases:
        cmd += ["--phase", ph]
    for b in BITS:
        cmd += ["--probe", b]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True)
    ch = out.stdout.split("── phase")[-1]
    vals = {}
    for m in re.finditer(r"(\S+)\s+\[port\]\s+P=(\S+)", ch):
        try:
            vals[m.group(1)] = float(m.group(2))
        except ValueError:
            vals[m.group(1)] = float("nan")
    return vals


def verdict(rb):
    lo = [rb[b] for b in ("J1.B0", "J1.B2")]
    hi = [rb[b] for b in ("J1.B1", "J1.B3")]
    if max(lo) < 0.3 and min(hi) > 0.7:
        return "HELD 1010 (protected)"
    if min(lo) > 0.7 and max(hi) < 0.3:
        return "WROTE 0101 (bus won)"
    return "CORRUPTED"


store = "J1.VAC=vac,J1.READ=vac,J1.WRITE=atm," + bits(P1010)
read = "J1.WRITE=vac,J1.READ=atm," + bits(val="nan")

for name, board in [("OLD", "register_old.vpcb"), ("NEW", "register.vpcb")]:
    print(f"=== {name}: stored 1010, drive bus=0101 under each (WRITE,READ) ===")
    for w in ("atm", "vac"):
        for r in ("atm", "vac"):
            dist = f"J1.WRITE={w},J1.READ={r}," + bits(P0101)
            rb = sim(board, [store, dist, read])
            print(f"  WRITE={w}  READ={r}  ->  {verdict(rb)}")
    print()
