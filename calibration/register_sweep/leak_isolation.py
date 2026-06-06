#!/usr/bin/env python3
"""Test the hypothesis: internal print leak degrades the bus<->storage isolation,
so driving the bus writes into the register even in the protected state.

Proxy: raise transistor OFF-conductance (the closed-valve / isolation leak path
between bus and storage). Run the user's exact sequence (store 1010, idle
both-atm while driving the bus to 0101, read back). If the read-back flips
TOWARD the driven 0101 as isolation degrades, that's the bus leaking into
storage = hypothesis confirmed."""
import re
import subprocess

BIN = "/Users/ioni/Documents/dev/vacuum_pcb/.build/release/vacuum-cli"
BITS = ["J1.B0", "J1.B1", "J1.B2", "J1.B3"]
P1010 = {"J1.B0": "vac", "J1.B1": "atm", "J1.B2": "vac", "J1.B3": "atm"}


def bits(pat=None, val=None):
    return ",".join(f"{b}={val or pat[b]}" for b in BITS)


def readback(board, offc, leak=0.025):
    store = "J1.VAC=vac,J1.READ=vac,J1.WRITE=atm," + bits(P1010)
    disturb = "J1.READ=atm,J1.WRITE=atm," + bits({"J1.B0": "atm", "J1.B1": "vac", "J1.B2": "atm", "J1.B3": "vac"})
    read = "J1.WRITE=vac,J1.READ=atm," + bits(val="nan")
    cmd = [BIN, "simulate", board, "--param", f"offConductance={offc}", "--param", f"leak={leak}",
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
    return v


def verdict(v):
    lo = [v[b] for b in ("J1.B0", "J1.B2")]   # stored "1"
    hi = [v[b] for b in ("J1.B1", "J1.B3")]   # stored "0"
    if max(lo) < 0.3 and min(hi) > 0.7:
        return "HELD 1010"
    if min(lo) > 0.7 and max(hi) < 0.3:
        return "→ WROTE 0101 (bus leaked in!)"
    return "CORRUPTED"


print("Stored 1010, drove bus to 0101 in idle, read back — vs isolation leak (off-conductance).")
print("Watch B0/B2 (stored '1'=vac): if they climb toward 1.0, the bus is bleeding into storage.\n")
for name, board in [("OLD", "register_old.vpcb"), ("NEW", "register.vpcb")]:
    print(f"=== {name} ===")
    print("  offCond   B0    B1    B2    B3    verdict")
    for offc in [0.0005, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0]:
        v = readback(board, offc)
        bb = "  ".join("%.2f" % v[b] for b in BITS)
        print("  %-8s %s   %s" % (offc, bb, verdict(v)))
    print()
