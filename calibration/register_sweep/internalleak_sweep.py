#!/usr/bin/env python3
"""internalLeak (channel-to-channel, geometry-based) sweep on the CURRENT
4-bit bus register (register_current.vpcb = "4bit register with bus 2.vpcb").

Metric = worst-case read-back logic margin over patterns 1010/0101
(min(zeros) - max(ones); >=0.3 = reliable, <=0 = data lost).

Hold modes between store and read:
  idle    - WRITE=vac, READ=vac, bus floated (nan). Pure retention in the
            normal hold state (bus transistor paths open, so the bus MUST
            float here - driving it writes through; verified empirically).
  disturb - WRITE=atm, READ=atm, bus DRIVEN to the opposite pattern.
            Both bus paths closed = truly isolated hold (verified: survives
            a driven opposite bus at internalLeak=0). The only couplings
            left are transistor off-leakage and internalLeak, so this is
            the pure cross-talk-through-plastic test: an external driver
            parks the bus at the inverse of the stored word.

Outputs: sens_internalLeak.csv, map_leak__internalLeak.csv + printed tables.
"""
import re
import subprocess

BIN = "/Users/ioni/Documents/dev/vacuum_pcb/.build/release/vacuum-cli"
BOARD = "register_current.vpcb"
BITS = ["J1.B0", "J1.B1", "J1.B2", "J1.B3"]
PATTERNS = {
    "1010": {"J1.B0": "vac", "J1.B1": "atm", "J1.B2": "vac", "J1.B3": "atm"},
    "0101": {"J1.B0": "atm", "J1.B1": "vac", "J1.B2": "atm", "J1.B3": "vac"},
}
OPP = {"vac": "atm", "atm": "vac"}
THRESH = 0.3


def bits(pat=None, val=None):
    return ",".join(f"{b}={val or pat[b]}" for b in BITS)


def readback(params, pattern, mode):
    store = "J1.VAC=vac,J1.READ=vac,J1.WRITE=atm," + bits(pattern)
    if mode == "idle":
        mid = "J1.WRITE=vac,J1.READ=vac," + bits(val="nan")
    else:  # disturb: isolated hold, bus driven to the opposite word
        mid = "J1.WRITE=atm,J1.READ=atm," + bits({b: OPP[pattern[b]] for b in BITS})
    read = "J1.WRITE=vac,J1.READ=atm," + bits(val="nan")
    cmd = [BIN, "simulate", BOARD]
    for k, v in params.items():
        cmd += ["--param", f"{k}={v}"]
    cmd += ["--phase", store, "--phase", mid, "--phase", read]
    for b in BITS:
        cmd += ["--probe", b]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError:
        return None
    last = out.stdout.split("── phase")[-1]
    vals = {}
    for m in re.finditer(r"(\S+)\s+\[port\]\s+P=(\S+)", last):
        try:
            vals[m.group(1)] = float(m.group(2))
        except ValueError:
            vals[m.group(1)] = float("nan")
    return vals if all(b in vals for b in BITS) else None


def margin(params, mode):
    worst = 1e9
    for pattern in PATTERNS.values():
        rb = readback(params, pattern, mode)
        if rb is None or any(rb[b] != rb[b] for b in BITS):
            return float("nan")
        ones = [rb[b] for b in BITS if pattern[b] == "vac"]
        zeros = [rb[b] for b in BITS if pattern[b] == "atm"]
        worst = min(worst, min(zeros) - max(ones))
    return worst


IL_VALUES = [0.0, 0.005, 0.01, 0.02, 0.03, 0.05, 0.075, 0.1, 0.15,
             0.2, 0.3, 0.4, 0.5, 0.7, 1.0]

print("1-D sweep: internalLeak (global leak at default 0.025)")
print("internalLeak   idle(hold)   disturb(bus=opposite)")
rows = ["internalLeak,idle,disturb"]
for il in IL_VALUES:
    mi = margin({"internalLeak": il}, "idle")
    md = margin({"internalLeak": il}, "disturb")
    mark = ""
    if mi < THRESH or md < THRESH:
        mark = "  <- below reliable" if min(mi, md) > 0 else "  <- DATA LOST"
    print("  %-12s %9.2f %12.2f%s" % (il, mi, md, mark))
    rows.append(f"{il},{mi},{md}")
with open("sens_internalLeak.csv", "w") as f:
    f.write("\n".join(rows) + "\n")

LEAKS = [0.005, 0.0125, 0.025, 0.035, 0.05]
ILS = [0.0, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0]
print("\n2-D map: rows=leak, cols=internalLeak, cell=worst disturb margin")
print("leak\\IL " + "".join("%8s" % il for il in ILS))
rows = ["leak/internalLeak," + ",".join(str(i) for i in ILS)]
for lk in LEAKS:
    line = "%-7s" % lk
    cells = [str(lk)]
    for il in ILS:
        m = margin({"leak": lk, "internalLeak": il}, "disturb")
        line += "%8.2f" % m
        cells.append(f"{m}")
    print(line)
    rows.append(",".join(cells))
with open("map_leak__internalLeak.csv", "w") as f:
    f.write("\n".join(rows) + "\n")
