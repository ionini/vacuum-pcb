#!/usr/bin/env python3
"""Parameter sweep for the 4-bit bus register: map the logic margin (and thus
the working "sweet spot") over R/mm x leak.

Per (resistance, leak) cell we write two patterns (1010 and its complement
0101), hold (float the bus), read back, and compute the worst-case logic
margin across both patterns and all 4 bits:

    margin = min(stored-0 readback) - max(stored-1 readback)

A stored 1 = vac (low pressure), stored 0 = atm (high pressure), non-inverting.
margin >> 0  -> robust;  margin <= 0 -> register can't be read reliably.
"""
import json
import re
import subprocess

BIN = "/Users/ioni/Documents/dev/vacuum_pcb/.build/release/vacuum-cli"
BOARD = "register.vpcb"

# logic-1 = vac, logic-0 = atm. Two complementary patterns so every bit cell
# is exercised storing both a 1 and a 0.
PATTERNS = {
    "1010": {"J1.B0": "vac", "J1.B1": "atm", "J1.B2": "vac", "J1.B3": "atm"},
    "0101": {"J1.B0": "atm", "J1.B1": "vac", "J1.B2": "atm", "J1.B3": "vac"},
}
BITS = ["J1.B0", "J1.B1", "J1.B2", "J1.B3"]


def readback(resistance, leak, drives):
    """Store -> hold -> read; return {bit: readback pressure} from read phase."""
    store = "J1.VAC=vac,J1.READ=vac,J1.WRITE=atm," + ",".join(
        f"{b}={drives[b]}" for b in BITS)
    hold = "J1.WRITE=vac,J1.READ=vac," + ",".join(f"{b}=nan" for b in BITS)
    read = "J1.READ=atm"
    cmd = [BIN, "simulate", BOARD,
           "--param", f"resistance={resistance}", "--param", f"leak={leak}",
           "--phase", store, "--phase", hold, "--phase", read]
    for b in BITS:
        cmd += ["--probe", b]
    # Text output, not --json: the CLI's JSON writer aborts on NaN, and the
    # solver emits NaN at near-singular corners (low R/mm + low leak). Text
    # prints NaN as "nan", which we capture below as an "unstable" cell.
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError:
        return None
    last = out.stdout.split("── phase")[-1]   # read-phase block
    vals = {}
    for m in re.finditer(r"(\S+)\s+\[port\]\s+P=(\S+)", last):
        try:
            vals[m.group(1)] = float(m.group(2))
        except ValueError:
            vals[m.group(1)] = float("nan")
    if not all(b in vals for b in BITS):
        return None
    return vals


def margin(resistance, leak):
    worst = 1e9
    for drives in PATTERNS.values():
        rb = readback(resistance, leak, drives)
        if rb is None or any(rb[b] != rb[b] for b in BITS):  # crashed or NaN (unstable)
            return float("nan")
        ones = [rb[b] for b in BITS if drives[b] == "vac"]   # stored 1 -> want low
        zeros = [rb[b] for b in BITS if drives[b] == "atm"]  # stored 0 -> want high
        m = min(zeros) - max(ones)
        worst = min(worst, m)
    return worst


RESISTANCES = [0.05, 0.075, 0.10, 0.15, 0.20, 0.30, 0.40]
LEAKS = [0.005, 0.0125, 0.025, 0.05, 0.10, 0.20]


def sym(m):
    if m != m:    return "!!"   # crashed / singular
    if m >= 0.6:  return "++"   # rock-solid
    if m >= 0.3:  return "+ "   # works, good margin
    if m >= 0.1:  return "~ "   # marginal
    if m > 0.0:   return ". "   # barely
    return "X "                 # broken


grid = {}
print("computing %d cells (x2 patterns)..." % (len(RESISTANCES) * len(LEAKS)))
for r in RESISTANCES:
    for lk in LEAKS:
        grid[(r, lk)] = margin(r, lk)

# --- margin table ---
print("\nLOGIC MARGIN  (rows = R/mm, cols = leak ; default = R/mm 0.15, leak 0.025)\n")
print("  R/mm \\ leak   " + "".join("%7s" % lk for lk in LEAKS))
for r in RESISTANCES:
    row = "  %-12s" % r + "".join("%7.2f" % grid[(r, lk)] for lk in LEAKS)
    print(row)

# --- pass/fail map ---
print("\nWORKS?  (++ >=0.6, + good >=0.3, ~ marginal >=0.1, . barely>0, X broken<=0, !! solver-unstable)\n")
print("  R/mm \\ leak   " + "".join("%7s" % lk for lk in LEAKS))
for r in RESISTANCES:
    row = "  %-12s" % r + "".join("%7s" % sym(grid[(r, lk)]) for lk in LEAKS)
    print(row)

# --- CSV ---
with open("register_margin.csv", "w") as f:
    f.write("resistance," + ",".join("leak_%s" % lk for lk in LEAKS) + "\n")
    for r in RESISTANCES:
        f.write(str(r) + "," + ",".join("%.4f" % grid[(r, lk)] for lk in LEAKS) + "\n")
print("\nwrote register_margin.csv")
