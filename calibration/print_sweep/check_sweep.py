#!/usr/bin/env python3
"""Does this G-code actually carry the sweep? Answer from the file alone.

    python3 check_sweep.py --gcode "whatever I am about to print.gcode" \
                           --map sweep_map.json

Needed because a sliced project (.gcode.3mf) contains both the models and the
stamped G-code, so Bambu Studio may re-slice it and silently throw the sweep
away — and the plate looks identical either way. Accepts a .gcode or a
.gcode.3mf (reads the plate payload out of the container).

Cells in one column share geometry exactly, so the ratio of extruded filament
between rows of a column is the ratio of their flow ratios, with no reference
file required. Sub-1% steps are well clear of the noise: per-cell totals run to
~230 mm of filament, and identical geometry means the only difference is the
multiplier.
"""
import argparse
import json
import math
import re
import sys
import zipfile

WORD = re.compile(r"([XYZEFIJ])(-?\d*\.?\d+(?:[eE][-+]?\d+)?)")
MOVE = re.compile(r"^G([0123])(?=[ \t]|$)")


def read_lines(path):
    if path.endswith(".3mf"):
        with zipfile.ZipFile(path) as z:
            inner = [n for n in z.namelist() if re.fullmatch(r"Metadata/plate_\d+\.gcode", n)]
            if len(inner) != 1:
                sys.exit(f"error: expected one plate G-code in {path}, found {inner}")
            return z.read(inner[0]).decode("utf-8", "replace").splitlines()
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read().splitlines()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gcode", required=True)
    ap.add_argument("--map", required=True)
    ap.add_argument("--tol", type=float, default=0.6)
    args = ap.parse_args()

    doc = json.load(open(args.map))
    cells = {(c["col"], c["row"]): c for c in doc["cells"]}
    ox = min(c["x"] for c in doc["cells"])
    oy = min(c["y"] for c in doc["cells"])
    px, py = doc["grid"]["pitch_x"], doc["grid"]["pitch_y"]
    sx, sy = doc["grid"]["coupon_size"]["x"], doc["grid"]["coupon_size"]["y"]
    cols = doc["grid"]["cols"]
    rows = doc["grid"]["rows"]

    totals = {k: 0.0 for k in cells}
    x = y = None
    for raw in read_lines(args.gcode):
        m = MOVE.match(raw)
        if not m:
            continue
        w = dict(WORD.findall(raw))
        nx = float(w["X"]) if "X" in w else x
        ny = float(w["Y"]) if "Y" in w else y
        e = float(w["E"]) if "E" in w else None
        if (e and e > 0 and ("X" in w or "Y" in w or "I" in w or "J" in w)
                and x is not None):
            mx, my = (x + nx) / 2, (y + ny) / 2
            key = (round((mx - ox) / px), round((my - oy) / py))
            cell = cells.get(key)
            if cell and abs(mx - cell["x"]) <= sx / 2 + args.tol \
                    and abs(my - cell["y"]) <= sy / 2 + args.tol:
                totals[key] += e
        x, y = nx, ny

    missing = [k for k, v in totals.items() if v == 0]
    if missing:
        sys.exit(f"error: {len(missing)} cells got no extrusion — this G-code does not "
                 f"match this map (e.g. {sorted(missing)[:4]})")

    print(f"{args.gcode}\n")
    print("  Filament per cell (mm), and the flow step each row implies within its column.")
    print("  A file carrying the sweep steps down each column; a re-sliced one is flat.\n")
    base_flow = cells[(0, 0)]["flow"]
    header = "  row  flow   " + "".join(f"{'c%d' % c:>16}" for c in range(cols))
    print(header)
    worst = 0.0
    for r in range(rows):
        want = cells[(0, r)]["flow"] / base_flow
        line = f"  r{r:<3} {cells[(0, r)]['flow']:.2f} "
        for c in range(cols):
            got = totals[(c, r)] / totals[(c, 0)]
            worst = max(worst, abs(got - want))
            line += f"  {totals[(c, r)]:7.1f} ({got:.3f})"
        print(line + f"   want {want:.3f}")
    print()

    # A flat file would show every ratio at 1.000, i.e. an error equal to the
    # full span of the sweep.
    span = max(c["flow"] for c in doc["cells"]) / base_flow - 1
    if worst < max(0.002, span * 0.1):
        print(f"PRESENT — row ratios track the map (worst deviation {worst:.4f}); "
              "this file carries the sweep")
        return
    flat = all(abs(totals[(c, r)] / totals[(c, 0)] - 1) < 0.002
               for c in range(cols) for r in range(rows))
    if flat:
        print(f"ABSENT — every row extrudes the same (expected up to {span:+.1%} across "
              "the rows). This G-code was sliced from the model without the flow stamp: "
              "re-slicing threw it away. Do not print it.")
    else:
        print(f"MISMATCH — row ratios do not track the map (worst deviation {worst:.4f}). "
              "This is neither a clean stamped file nor a clean re-slice.")
    sys.exit(1)


if __name__ == "__main__":
    main()
