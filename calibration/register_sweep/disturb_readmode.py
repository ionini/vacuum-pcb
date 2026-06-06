#!/usr/bin/env python3
"""Your actual scenario: register idle in BOTH-ATM (WRITE=atm, READ=atm = read
mode, register driving the bus), then you pull the bus to vac or atm. Does the
stored data survive the contention, and how does it hold up as leak rises?
Compares OLD vs NEW. Stored pattern 1010; survival margin = min(stored-0
readback) - max(stored-1 readback). >0 = held, <=0 = corrupted."""
import re
import subprocess

BIN = "/Users/ioni/Documents/dev/vacuum_pcb/.build/release/vacuum-cli"
BITS = ["J1.B0", "J1.B1", "J1.B2", "J1.B3"]
P1010 = {"J1.B0": "vac", "J1.B1": "atm", "J1.B2": "vac", "J1.B3": "atm"}


def bits(pat=None, val=None):
    return ",".join(f"{b}={val or pat[b]}" for b in BITS)


def survive(board, drive, leak):
    """drive: 'atm' / 'vac' (uniform bus pull) or dict (pattern). Returns margin."""
    store = "J1.VAC=vac,J1.READ=vac,J1.WRITE=atm," + bits(P1010)
    busdrive = bits(drive) if isinstance(drive, dict) else bits(val=drive)
    disturb = "J1.WRITE=atm,J1.READ=atm," + busdrive          # both-atm, bus pulled
    read = "J1.WRITE=vac,J1.READ=atm," + bits(val="nan")       # read back
    cmd = [BIN, "simulate", board, "--param", f"leak={leak}",
           "--phase", store, "--phase", disturb, "--phase", read]
    for b in BITS:
        cmd += ["--probe", b]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True)
    ch = out.stdout.split("── phase")[-1]
    v = {}
    for m in re.finditer(r"(\S+)\s+\[port\]\s+P=(\S+)", ch):
        try:
            v[m.group(1)] = float(m.group(2))
        except ValueError:
            v[m.group(1)] = float("nan")
    if any(v[b] != v[b] for b in BITS):
        return float("nan")
    ones = [v[b] for b in BITS if P1010[b] == "vac"]   # stored 1 -> want low
    zeros = [v[b] for b in BITS if P1010[b] == "atm"]  # stored 0 -> want high
    return min(zeros) - max(ones)


P0101 = {"J1.B0": "atm", "J1.B1": "vac", "J1.B2": "atm", "J1.B3": "vac"}
LEAKS = [0.005, 0.0125, 0.025, 0.035, 0.04, 0.05]
for label, drive in [("bus pulled to ATM", "atm"),
                     ("bus pulled to VAC", "vac"),
                     ("bus driven OPPOSITE (0101)", P0101)]:
    print(f"\n=== both-atm idle, {label} -> does stored 1010 survive? ===")
    print("  leak      OLD     NEW")
    for lk in LEAKS:
        print("  %-7s %7.2f %7.2f" % (lk, survive("register_old.vpcb", drive, lk),
                                      survive("register.vpcb", drive, lk)))
