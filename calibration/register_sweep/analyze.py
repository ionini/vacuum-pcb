#!/usr/bin/env python3
"""Follow-up analysis: confirm the failure mode, pin the leak cliff at default
R/mm, and check pump-depth sensitivity. Reuses the text-parse approach."""
import re
import subprocess

BIN = "/Users/ioni/Documents/dev/vacuum_pcb/.build/release/vacuum-cli"
BOARD = "register.vpcb"
BITS = ["J1.B0", "J1.B1", "J1.B2", "J1.B3"]
PATTERNS = {
    "1010": {"J1.B0": "vac", "J1.B1": "atm", "J1.B2": "vac", "J1.B3": "atm"},
    "0101": {"J1.B0": "atm", "J1.B1": "vac", "J1.B2": "atm", "J1.B3": "vac"},
}


def run(params, drives):
    store = "J1.VAC=vac,J1.READ=vac,J1.WRITE=atm," + ",".join(f"{b}={drives[b]}" for b in BITS)
    hold = "J1.WRITE=vac,J1.READ=vac," + ",".join(f"{b}=nan" for b in BITS)
    cmd = [BIN, "simulate", BOARD]
    for k, v in params.items():
        cmd += ["--param", f"{k}={v}"]
    cmd += ["--phase", store, "--phase", hold, "--phase", "J1.READ=atm"]
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


def margin(params):
    worst = 1e9
    for drives in PATTERNS.values():
        rb = run(params, drives)
        if rb is None or any(rb[b] != rb[b] for b in BITS):
            return float("nan")
        ones = [rb[b] for b in BITS if drives[b] == "vac"]
        zeros = [rb[b] for b in BITS if drives[b] == "atm"]
        worst = min(worst, min(zeros) - max(ones))
    return worst


print("=== Read-back of pattern 1010 (B0=1,B1=0,B2=1,B3=0) — working vs broken ===")
for lk in (0.025, 0.05):
    rb = run({"resistance": 0.15, "leak": lk}, PATTERNS["1010"])
    print(f"  R/mm=0.15 leak={lk}:  " +
          "  ".join(f"{b.split('.')[1]}={rb[b]:.2f}" for b in BITS) +
          f"   margin={margin({'resistance':0.15,'leak':lk}):.3f}")

print("\n=== Fine leak cliff @ R/mm=0.15 (default) ===")
for lk in [0.02, 0.025, 0.03, 0.035, 0.04, 0.045, 0.05]:
    print(f"  leak={lk:.3f}   margin={margin({'resistance': 0.15, 'leak': lk}):.3f}")

print("\n=== Pump deadhead sweep @ R/mm=0.15, leak=0.025 (pumpMax: lower=deeper vac, default 0.1) ===")
for pm in [0.05, 0.1, 0.15, 0.2, 0.3, 0.4]:
    print(f"  pumpMax={pm:.2f}   margin={margin({'resistance': 0.15, 'leak': 0.025, 'pumpMax': pm}):.3f}")
