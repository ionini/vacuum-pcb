#!/usr/bin/env python3
"""Validate the new internalLeak (channel-to-channel) parameter on the register.
  - idle column: store 1010, hold (bus floated), read  -> retention vs leak
  - bus column : store 1010, idle while DRIVING bus to 0101, read -> is the
    corruption bus-coupled? (the user's hypothesis: bus bleeds into storage)
margin>0 = data survived; internalLeak=0 must match the old behaviour."""
import re
import subprocess

BIN = "/Users/ioni/Documents/dev/vacuum_pcb/.build/release/vacuum-cli"
BITS = ["J1.B0", "J1.B1", "J1.B2", "J1.B3"]
P1010 = {"J1.B0": "vac", "J1.B1": "atm", "J1.B2": "vac", "J1.B3": "atm"}
P0101 = {"J1.B0": "atm", "J1.B1": "vac", "J1.B2": "atm", "J1.B3": "vac"}


def bits(pat=None, val=None):
    return ",".join(f"{b}={val or pat[b]}" for b in BITS)


def margin(il, drive_bus):
    store = "J1.VAC=vac,J1.READ=vac,J1.WRITE=atm," + bits(P1010)
    mid = ("J1.READ=atm,J1.WRITE=atm," + bits(P0101)) if drive_bus \
        else ("J1.WRITE=vac,J1.READ=vac," + bits(val="nan"))
    read = "J1.WRITE=vac,J1.READ=atm," + bits(val="nan")
    cmd = [BIN, "simulate", "register.vpcb", "--param", f"internalLeak={il}",
           "--phase", store, "--phase", mid, "--phase", read]
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
    ones = [v[b] for b in BITS if P1010[b] == "vac"]
    zeros = [v[b] for b in BITS if P1010[b] == "atm"]
    return min(zeros) - max(ones)


print("internalLeak   idle(hold)   bus-driven   (margin; <=0 = data lost)")
for il in [0.0, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0]:
    mi = margin(il, drive_bus=False)
    mb = margin(il, drive_bus=True)
    flag = "  <- bus-driven corrupts first" if (mi > 0.3 and mb < 0.3) else ""
    print("  %-12s %9.2f %11.2f%s" % (il, mi, mb, flag))
