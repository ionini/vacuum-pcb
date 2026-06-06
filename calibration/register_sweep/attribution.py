#!/usr/bin/env python3
"""Is the data loss caused by the DRIVEN BUS bleeding through leaky isolation
(user's hypothesis), or just the leak killing the latch regardless?

For each isolation-leak level (off-conductance), compare two cases in the same
idle state (READ=atm, WRITE=atm):
  FLOAT  : bus left floating       -> tests whether the latch holds on its own
  DRIVE  : bus driven to 0101      -> tests whether driving corrupts it
If FLOAT holds but DRIVE corrupts at the same leak -> the bus is bleeding into
storage (hypothesis confirmed). If both fail together -> it's just latch loss."""
import re
import subprocess

BIN = "/Users/ioni/Documents/dev/vacuum_pcb/.build/release/vacuum-cli"
BITS = ["J1.B0", "J1.B1", "J1.B2", "J1.B3"]
P1010 = {"J1.B0": "vac", "J1.B1": "atm", "J1.B2": "vac", "J1.B3": "atm"}
P0101 = {"J1.B0": "atm", "J1.B1": "vac", "J1.B2": "atm", "J1.B3": "vac"}


def bits(pat=None, val=None):
    return ",".join(f"{b}={val or pat[b]}" for b in BITS)


def margin(board, offc, drive):
    store = "J1.VAC=vac,J1.READ=vac,J1.WRITE=atm," + bits(P1010)
    mid = "J1.READ=atm,J1.WRITE=atm," + (bits(P0101) if drive else bits(val="nan"))
    read = "J1.WRITE=vac,J1.READ=atm," + bits(val="nan")
    cmd = [BIN, "simulate", board, "--param", f"offConductance={offc}",
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


for name, board in [("OLD", "register_old.vpcb"), ("NEW", "register.vpcb")]:
    print(f"=== {name}: survival margin vs isolation leak ===")
    print("  offCond   bus FLOAT   bus DRIVEN")
    for offc in [0.005, 0.01, 0.02, 0.03, 0.04, 0.05, 0.07, 0.1]:
        mf = margin(board, offc, drive=False)
        md = margin(board, offc, drive=True)
        flag = "   <- driving bus corrupts it" if (mf > 0.3 and md < 0.3) else ""
        print("  %-8s %9.2f %11.2f%s" % (offc, mf, md, flag))
    print()
