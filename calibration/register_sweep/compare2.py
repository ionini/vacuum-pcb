#!/usr/bin/env python3
"""OLD vs NEW: pump-depth headroom + fine leak cliff."""
import re
import subprocess

BIN = "/Users/ioni/Documents/dev/vacuum_pcb/.build/release/vacuum-cli"
BITS = ["J1.B0", "J1.B1", "J1.B2", "J1.B3"]
hold = "J1.WRITE=vac,J1.READ=vac," + ",".join(f"{b}=nan" for b in BITS)
read = "J1.READ=atm"


def margin(board, params):
    worst = 1e9
    for pat in ({"J1.B0": "vac", "J1.B1": "atm", "J1.B2": "vac", "J1.B3": "atm"},
                {"J1.B0": "atm", "J1.B1": "vac", "J1.B2": "atm", "J1.B3": "vac"}):
        st = "J1.VAC=vac,J1.READ=vac,J1.WRITE=atm," + ",".join(f"{b}={pat[b]}" for b in BITS)
        cmd = [BIN, "simulate", board]
        for k, v in params.items():
            cmd += ["--param", f"{k}={v}"]
        cmd += ["--phase", st, "--phase", hold, "--phase", read]
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
        if any(vals[b] != vals[b] for b in BITS):
            return float("nan")
        ones = [vals[b] for b in BITS if pat[b] == "vac"]
        zeros = [vals[b] for b in BITS if pat[b] == "atm"]
        worst = min(worst, min(zeros) - max(ones))
    return worst


print("=== PUMP DEADHEAD headroom (higher pumpMax = shallower vacuum) ===\n")
print("  pumpMax    OLD     NEW")
for pm in [0.05, 0.1, 0.15, 0.18, 0.2, 0.22, 0.25]:
    print("  %-9s %6.2f  %6.2f" % (pm, margin("register_old.vpcb", {"pumpMax": pm}),
                                   margin("register.vpcb", {"pumpMax": pm})))

print("\n=== FINE LEAK CLIFF ===\n")
print("  leak     OLD     NEW")
for lk in [0.034, 0.036, 0.038, 0.040, 0.042]:
    print("  %-7s %6.2f  %6.2f" % (lk, margin("register_old.vpcb", {"leak": lk}),
                                   margin("register.vpcb", {"leak": lk})))
