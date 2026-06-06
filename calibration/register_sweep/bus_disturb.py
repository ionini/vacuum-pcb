#!/usr/bin/env python3
"""Bus-disturb test: store 1010, then drive the bus to the opposite pattern
under various control states, then read back. If the stored data survives, the
write gate properly isolates storage from the bus. If it changes, driving the
bus corrupts the register.

Protocol reminder (validated): WRITE=atm = write ENABLED, WRITE=vac = hold;
READ=atm = read enabled, READ=vac = idle. So a true "idle/hold" is WRITE=vac."""
import re
import subprocess

BIN = "/Users/ioni/Documents/dev/vacuum_pcb/.build/release/vacuum-cli"
BITS = ["J1.B0", "J1.B1", "J1.B2", "J1.B3"]
P1010 = {"J1.B0": "vac", "J1.B1": "atm", "J1.B2": "vac", "J1.B3": "atm"}
P0101 = {"J1.B0": "atm", "J1.B1": "vac", "J1.B2": "atm", "J1.B3": "vac"}


def bits(pat, val=None):
    return ",".join(f"{b}={val if val else pat[b]}" for b in BITS)


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
    lo = [rb[b] for b in ("J1.B0", "J1.B2")]   # were stored "1" (vac/low)
    hi = [rb[b] for b in ("J1.B1", "J1.B3")]   # were stored "0" (atm/high)
    if max(lo) < 0.3 and min(hi) > 0.7:
        return "HELD 1010  ✓"
    if min(lo) > 0.7 and max(hi) < 0.3:
        return "OVERWRITTEN→0101"
    return "CORRUPTED (garbage)"


store = "J1.VAC=vac,J1.READ=vac,J1.WRITE=atm," + bits(P1010)
readback = "J1.WRITE=vac,J1.READ=atm," + bits(None, "nan")

# (label, disturb-phase) — store 1010, apply disturb, then read back.
DISTURBS = [
    ("idle (W=vac,R=vac) + drive bus 0101", "J1.WRITE=vac,J1.READ=vac," + bits(P0101)),
    ("idle (W=vac,R=vac) + drive bus all-ATM", "J1.WRITE=vac,J1.READ=vac," + bits(None, "atm")),
    ("idle (W=vac,R=vac) + drive bus all-VAC", "J1.WRITE=vac,J1.READ=vac," + bits(None, "vac")),
    ("BOTH ATM (W=atm,R=atm) + drive bus 0101", "J1.WRITE=atm,J1.READ=atm," + bits(P0101)),
    ("READ (W=vac,R=atm) + drive bus 0101", "J1.WRITE=vac,J1.READ=atm," + bits(P0101)),
]

for name, board in [("OLD", "register_old.vpcb"), ("NEW", "register.vpcb")]:
    print(f"=== {name} : stored 1010, then disturb, then read back ===")
    for label, dist in DISTURBS:
        rb = sim(board, [store, dist, readback])
        bb = "  ".join("%s=%.2f" % (b.split(".")[1], rb[b]) for b in BITS)
        print(f"  {label:42s} -> {bb}   {verdict(rb)}")
    print()
