#!/usr/bin/env python3
"""both-atm idle, bus pulled to atm/vac, sweeping HOW HARD it's pulled
(busDrive conductance). Default busDrive=5 ~ one on-board transistor; a real
vacuum/atm line tied to the bus is much stronger. Does a strong external pull
overpower the register's read-mode defense and corrupt the stored 1010 — and
does the new design (deeper drive) resist longer? margin>0 = held."""
import re
import subprocess

BIN = "/Users/ioni/Documents/dev/vacuum_pcb/.build/release/vacuum-cli"
BITS = ["J1.B0", "J1.B1", "J1.B2", "J1.B3"]
P1010 = {"J1.B0": "vac", "J1.B1": "atm", "J1.B2": "vac", "J1.B3": "atm"}


def bits(pat=None, val=None):
    return ",".join(f"{b}={val or pat[b]}" for b in BITS)


def survive(board, drive_val, busdrive, leak=0.025):
    store = "J1.VAC=vac,J1.READ=vac,J1.WRITE=atm," + bits(P1010)
    disturb = "J1.WRITE=atm,J1.READ=atm," + bits(val=drive_val)
    read = "J1.WRITE=vac,J1.READ=atm," + bits(val="nan")
    cmd = [BIN, "simulate", board, "--param", f"leak={leak}",
           "--param", f"busDrive={busdrive}",
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
    ones = [v[b] for b in BITS if P1010[b] == "vac"]
    zeros = [v[b] for b in BITS if P1010[b] == "atm"]
    return min(zeros) - max(ones)


for drive in ("atm", "vac"):
    print(f"\n=== both-atm, bus pulled to {drive.upper()} vs pull strength (busDrive) ===")
    print("  busDrive    OLD     NEW   (margin; <=0 = data destroyed)")
    for bd in [2, 5, 10, 20, 40, 80, 150]:
        mo = survive("register_old.vpcb", drive, bd)
        mn = survive("register.vpcb", drive, bd)
        print("  %-9s %7.2f %7.2f" % (bd, mo, mn))
