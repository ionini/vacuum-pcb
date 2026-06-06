#!/usr/bin/env python3
"""Compare OLD vs NEW 4-bit register for (a) read-disturb (does repeated reading
corrupt the stored bits?) and (b) static logic margin. Same store/hold/read
protocol; logic 1 = vac (low P), 0 = atm (high P)."""
import re
import subprocess

BIN = "/Users/ioni/Documents/dev/vacuum_pcb/.build/release/vacuum-cli"
BITS = ["J1.B0", "J1.B1", "J1.B2", "J1.B3"]
BOARDS = [("OLD", "register_old.vpcb"), ("NEW", "register.vpcb")]
PAT = {"J1.B0": "vac", "J1.B1": "atm", "J1.B2": "vac", "J1.B3": "atm"}  # 1010


def sim(board, phases, params=None):
    cmd = [BIN, "simulate", board]
    for k, v in (params or {}).items():
        cmd += ["--param", f"{k}={v}"]
    for ph in phases:
        cmd += ["--phase", ph]
    for b in BITS:
        cmd += ["--probe", b]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True)
    res = []
    for ch in out.stdout.split("── phase")[1:]:
        vals = {}
        for m in re.finditer(r"(\S+)\s+\[port\]\s+P=(\S+)", ch):
            try:
                vals[m.group(1)] = float(m.group(2))
            except ValueError:
                vals[m.group(1)] = float("nan")
        res.append(vals)
    return res


store = "J1.VAC=vac,J1.READ=vac,J1.WRITE=atm," + ",".join(f"{b}={PAT[b]}" for b in BITS)
hold = "J1.WRITE=vac,J1.READ=vac," + ",".join(f"{b}=nan" for b in BITS)
read = "J1.READ=atm"

# store, then 6 x (hold, read)
labels = ["store"]
phases = [store]
for i in range(6):
    labels += ["hold", "read%d" % (i + 1)]
    phases += [hold, read]


def row(v):
    return "  ".join("%s=%.2f" % (b.split(".")[1], v[b]) for b in BITS)


print("=== READ-DISTURB: store 1010, read 6× with holds between ===")
print("(stored 1 should stay ~0.1 / vac on B0,B2 ; stored 0 ~1.0 / atm on B1,B3)\n")
for name, board in BOARDS:
    res = sim(board, phases)
    print(name)
    for i, lab in enumerate(labels):
        if lab.startswith("read"):
            print("  %-7s %s" % (lab, row(res[i])))
    print()


def margin(board, params):
    worst = 1e9
    for pat in ({"J1.B0": "vac", "J1.B1": "atm", "J1.B2": "vac", "J1.B3": "atm"},
                {"J1.B0": "atm", "J1.B1": "vac", "J1.B2": "atm", "J1.B3": "vac"}):
        st = "J1.VAC=vac,J1.READ=vac,J1.WRITE=atm," + ",".join(f"{b}={pat[b]}" for b in BITS)
        res = sim(board, [st, hold, read], params)
        rb = res[-1]
        if any(rb[b] != rb[b] for b in BITS):
            return float("nan")
        ones = [rb[b] for b in BITS if pat[b] == "vac"]
        zeros = [rb[b] for b in BITS if pat[b] == "atm"]
        worst = min(worst, min(zeros) - max(ones))
    return worst


print("=== STATIC LEAK MARGIN: OLD vs NEW (default other params) ===\n")
print("  leak     OLD     NEW")
for lk in [0.005, 0.0125, 0.025, 0.035, 0.04, 0.05, 0.06]:
    mo = margin("register_old.vpcb", {"leak": lk})
    mn = margin("register.vpcb", {"leak": lk})
    print("  %-7s %6.2f  %6.2f" % (lk, mo, mn))
