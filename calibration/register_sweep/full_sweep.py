#!/usr/bin/env python3
"""Comprehensive parameter sweep for the 4-bit bus register.

1-D sensitivity for every worthy simulation parameter (one varied at a time,
rest at GUI defaults) + 2-D interaction maps for the key pairs. Metric = the
worst-case read-back logic margin over patterns 1010/0101. Writes per-sweep
CSVs, SVG heatmaps for the maps, and a combined SWEEP_RESULTS.md.

Uses text output (robust regardless of the JSON-NaN fix). NaN margin = the
solver couldn't converge (near-singular corner), shown as "!!"/grey.
"""
import re
import subprocess

BIN = "/Users/ioni/Documents/dev/vacuum_pcb/.build/release/vacuum-cli"
BOARD = "register.vpcb"
BITS = ["J1.B0", "J1.B1", "J1.B2", "J1.B3"]
PATTERNS = {
    "1010": {"J1.B0": "vac", "J1.B1": "atm", "J1.B2": "vac", "J1.B3": "atm"},
    "0101": {"J1.B0": "atm", "J1.B1": "vac", "J1.B2": "atm", "J1.B3": "vac"},
}
THRESH = 0.3   # margin >= this = "works reliably"


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


DEFAULTS = {"resistance": 0.15, "leak": 0.025, "pumpMax": 0.1, "flow": 30,
            "gateThreshold": 0.3, "gateHysteresis": 0.08, "onConductance": 5,
            "offConductance": 0.0005, "busDrive": 5, "droop": -0.14}

ONED = [
    ("resistance",    "R/mm — resistor strength (higher = weaker pull)", [0.03, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.4, 0.6, 0.8]),
    ("leak",          "leak — sealing (higher = leakier)",              [0.002, 0.005, 0.01, 0.02, 0.03, 0.04, 0.05, 0.07, 0.1]),
    ("pumpMax",       "pump deadhead (lower = deeper vacuum)",          [0.02, 0.05, 0.08, 0.1, 0.12, 0.15, 0.18, 0.2, 0.25, 0.3]),
    ("flow",          "pump flow capacity (rail stiffness)",            [5, 10, 15, 20, 30, 40, 50, 60]),
    ("gateThreshold", "gate activation threshold",                      [0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5, 0.55]),
    ("gateHysteresis", "gate hysteresis (switching band)",              [0.02, 0.04, 0.06, 0.08, 0.1, 0.12, 0.15, 0.2]),
    ("onConductance", "transistor ON conductance",                      [1, 2, 3, 5, 7, 10, 15]),
    ("offConductance", "transistor OFF / leakage",                      [0.0001, 0.0002, 0.0005, 0.001, 0.002, 0.005, 0.01]),
    ("busDrive",      "bus drive conductance (write strength)",         [1, 2, 5, 10, 20]),
    ("droop",         "pump droop exponent (curve shape)",              [-0.5, -0.3, -0.14, 0.0, 0.3, 0.5]),
]

# (xparam, xvals, yparam, yvals)  -> map of yparam(rows) x xparam(cols)
MAPS = [
    ("resistance", [0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.4], "leak", [0.005, 0.0125, 0.025, 0.05, 0.075, 0.1]),
    ("pumpMax", [0.05, 0.08, 0.1, 0.12, 0.15, 0.18, 0.2], "leak", [0.005, 0.0125, 0.025, 0.05, 0.075, 0.1]),
    ("gateThreshold", [0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5], "pumpMax", [0.05, 0.08, 0.1, 0.12, 0.15, 0.18, 0.2]),
    ("gateThreshold", [0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5], "leak", [0.005, 0.0125, 0.025, 0.05, 0.075, 0.1]),
]


def log(s):
    print(s, flush=True)


def sym(m):
    if m != m:    return "!!"
    if m >= 0.6:  return "++"
    if m >= 0.3:  return "+ "
    if m >= 0.1:  return "~ "
    if m > 0.0:   return ". "
    return "X "


def svg_map(fn, title, xlabel, xvals, ylabel, yvals, M, default=None):
    STOPS = [(-0.1, (215, 48, 39)), (0.4, (255, 255, 191)), (0.9, (26, 152, 80))]

    def color(m):
        if m != m:
            return (160, 160, 160)
        if m <= STOPS[0][0]:
            return STOPS[0][1]
        for (a, ca), (b, cb) in zip(STOPS, STOPS[1:]):
            if m <= b:
                t = (m - a) / (b - a)
                return tuple(int(ca[i] + t * (cb[i] - ca[i])) for i in range(3))
        return STOPS[-1][1]

    cw, ch = 80, 42
    x0, y0 = 150, 76
    W = x0 + cw * len(xvals) + 30
    H = y0 + ch * len(yvals) + 72
    s = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" font-family="sans-serif">' % (W, H)]
    s.append('<text x="%d" y="26" font-size="17" font-weight="bold">%s</text>' % (x0, title))
    s.append('<text x="%d" y="46" font-size="11" fill="#555">green = latches reliably &#183; red = loses bits &#183; grey = solver unstable</text>' % x0)
    s.append('<text x="%d" y="%d" font-size="13" font-weight="bold">%s</text>' % (x0, H - 14, xlabel))
    s.append('<text x="22" y="%d" font-size="13" font-weight="bold" transform="rotate(-90 22 %d)">%s</text>' % (y0 + ch * len(yvals) // 2, y0 + ch * len(yvals) // 2, ylabel))
    for j, xv in enumerate(xvals):
        s.append('<text x="%d" y="%d" font-size="11" text-anchor="middle">%s</text>' % (x0 + cw * j + cw // 2, y0 - 8, xv))
    for i, yv in enumerate(yvals):
        s.append('<text x="%d" y="%d" font-size="11" text-anchor="end">%s</text>' % (x0 - 10, y0 + ch * i + ch // 2 + 4, yv))
        for j, m in enumerate(M[i]):
            cr, cg, cb = color(m)
            x, y = x0 + cw * j, y0 + ch * i
            s.append('<rect x="%d" y="%d" width="%d" height="%d" fill="rgb(%d,%d,%d)" stroke="white"/>' % (x, y, cw, ch, cr, cg, cb))
            txt = "nan" if m != m else "%.2f" % m
            tc = "black" if (m == m and m > 0.25) else "white"
            s.append('<text x="%d" y="%d" font-size="11" text-anchor="middle" fill="%s">%s</text>' % (x + cw // 2, y + ch // 2 + 4, tc, txt))
    if default:
        dj, di = default
        s.append('<rect x="%d" y="%d" width="%d" height="%d" fill="none" stroke="#1133cc" stroke-width="3"/>' % (x0 + cw * dj, y0 + ch * di, cw, ch))
        s.append('<text x="%d" y="%d" font-size="10" fill="#1133cc" font-weight="bold">default</text>' % (x0 + cw * dj + 3, y0 + ch * di + ch - 4))
    s.append('</svg>')
    open(fn, "w").write("\n".join(s))


md = ["# 4-bit register — comprehensive parameter sweep\n",
      "Metric = worst-case read-back logic margin over patterns 1010 / 0101 "
      "(≥0.3 = latches reliably, ≈0 = loses its bits, `!!` = solver unstable). "
      "1-D: one param varied, rest at GUI defaults. Maps: the two named params co-varied.\n",
      "**Defaults:** " + ", ".join(f"{k}={v}" for k, v in DEFAULTS.items()) + "\n"]

md.append("\n## 1-D sensitivity (working window @ margin ≥ %.1f)\n" % THRESH)
for param, desc, vals in ONED:
    log("[1D] %s" % param)
    ms = []
    for v in vals:
        m = margin({param: v})
        ms.append(m)
        log("    %s=%s -> %.3f" % (param, v, m))
    passing = [v for v, m in zip(vals, ms) if (m == m and m >= THRESH)]
    win = (min(passing), max(passing)) if passing else None
    with open("sens_%s.csv" % param, "w") as f:
        f.write("value,margin\n")
        for v, m in zip(vals, ms):
            f.write("%s,%.4f\n" % (v, m))
    md.append("\n**%s** — %s  (default **%s**)\n" % (param, desc, DEFAULTS[param]))
    md.append("| %s | %s |" % (param, " | ".join(str(v) for v in vals)))
    md.append("|" + "---|" * (len(vals) + 1))
    md.append("| margin | %s |" % " | ".join(("%.2f" % m if m == m else "nan") for m in ms))
    md.append("| works | %s |" % " | ".join(sym(m).strip() for m in ms))
    if win:
        inside = "inside" if win[0] <= DEFAULTS[param] <= win[1] else "**OUTSIDE**"
        md.append("\nWorking window: **%s … %s** (default %s %s)." % (win[0], win[1], DEFAULTS[param], inside))
    else:
        md.append("\nWorking window: **none in tested range**.")

md.append("\n\n## 2-D interaction maps  (++ ≥0.6, + ≥0.3, ~ ≥0.1, . >0, X broken, !! unstable)\n")
for xparam, xvals, yparam, yvals in MAPS:
    log("[2D] %s x %s" % (yparam, xparam))
    M = []
    for yv in yvals:
        row = [margin({xparam: xv, yparam: yv}) for xv in xvals]
        M.append(row)
        log("    %s=%s : %s" % (yparam, yv, " ".join("%.2f" % m if m == m else "nan" for m in row)))
    base = "map_%s__%s" % (yparam, xparam)
    with open(base + ".csv", "w") as f:
        f.write("%s\\%s,%s\n" % (yparam, xparam, ",".join(str(x) for x in xvals)))
        for yv, row in zip(yvals, M):
            f.write("%s,%s\n" % (yv, ",".join("%.4f" % m if m == m else "nan" for m in row)))
    dflt = None
    if DEFAULTS[xparam] in xvals and DEFAULTS[yparam] in yvals:
        dflt = (xvals.index(DEFAULTS[xparam]), yvals.index(DEFAULTS[yparam]))
    svg_map(base + ".svg", "register margin: %s vs %s" % (yparam, xparam), xparam, xvals, yparam, yvals, M, dflt)
    md.append("\n**%s (rows) × %s (cols)** — `%s.svg`\n" % (yparam, xparam, base))
    md.append("```")
    md.append("  %-12s" % (yparam + "\\" + xparam) + "".join("%7s" % x for x in xvals))
    for yv, row in zip(yvals, M):
        md.append("  %-12s" % yv + "".join("%7s" % sym(m) for m in row))
    md.append("```")

open("SWEEP_RESULTS.md", "w").write("\n".join(md))
log("\nDONE — wrote SWEEP_RESULTS.md, sens_*.csv, map_*.csv, map_*.svg")
