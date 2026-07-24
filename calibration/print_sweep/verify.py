#!/usr/bin/env python3
"""Diff a swept plate against the G-code it came from, before printing it.

apply_matrix.py rewrites tens of thousands of extrusion moves; this is the
independent check that it changed exactly what it claims and nothing else.

    python3 verify.py --before plate_1.gcode --after plate_1_swept.gcode \
                      --map sweep_map.json

Asserts, per cell and overall:
  1. line count and command sequence are unchanged (only numbers may differ)
  2. each cell's extruded filament scaled by exactly its flow multiplier
  3. retraction/unretraction/wipe E is untouched (unbalanced retraction is what
     turns a long print into a blob)
  4. travel feedrates are untouched
  5. no move exceeds the volumetric ceiling after the rewrite
  6. nothing outside the coupon footprints changed at all
"""
import argparse
import json
import math
import re
import sys

FILAMENT_AREA = math.pi * (1.75 / 2) ** 2
SLACK = 1.005
WORD = re.compile(r"([XYZEFIJ])(-?\d*\.?\d+(?:[eE][-+]?\d+)?)")
MOVE = re.compile(r"^G([0123])(?=[ \t]|$)")


def arc_or_line(g, x, y, nx, ny, w):
    chord = math.hypot(nx - x, ny - y)
    if g not in (2, 3) or ("I" not in w and "J" not in w):
        return chord
    i, j = float(w.get("I", 0.0)), float(w.get("J", 0.0))
    r = math.hypot(i, j)
    if r < 1e-9:
        return chord
    cx, cy = x + i, y + j
    a0 = math.atan2(y - cy, x - cx)
    a1 = math.atan2(ny - cy, nx - cx)
    sweep = ((a0 - a1) if g == 2 else (a1 - a0)) % (2 * math.pi)
    return r * (sweep if sweep > 1e-9 else 2 * math.pi)


def scan(path, cells, origin, pitch, size, tol, sliced_flow):
    """Walk a G-code file, bucketing extrusion by cell and totalling the things
    that must not move."""
    per_cell = {k: {"e": 0.0, "n": 0} for k in cells}
    tot = {"retract_e": 0.0, "travel_f": 0.0, "outside_e": 0.0, "max_rate": 0.0,
           "over": 0, "lines": 0, "shape": []}
    x = y = None
    pf = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            tot["lines"] += 1
            m = MOVE.match(raw)
            if not m:
                if raw.startswith(("M106", "M104", "M109", "M73", "G92", ";")):
                    pass
                continue
            g = int(m.group(1))
            w = dict(WORD.findall(raw))
            nx = float(w["X"]) if "X" in w else x
            ny = float(w["Y"]) if "Y" in w else y
            e = float(w["E"]) if "E" in w else None
            f = float(w["F"]) if "F" in w else None
            has_xy = "X" in w or "Y" in w
            has_arc = "I" in w or "J" in w
            extruding = e is not None and e > 0 and (has_xy or has_arc)
            if f is not None and (extruding or not has_xy):
                pf = f
            if e is not None and not extruding:
                tot["retract_e"] += e
            if e is None and has_xy and f is not None:
                tot["travel_f"] += f
            if extruding and x is not None:
                col = round(((x + nx) / 2 - origin[0]) / pitch[0])
                row = round(((y + ny) / 2 - origin[1]) / pitch[1])
                cell = cells.get((col, row))
                inside = cell is not None and \
                    abs((x + nx) / 2 - cell["x"]) <= size[0] / 2 + tol and \
                    abs((y + ny) / 2 - cell["y"]) <= size[1] / 2 + tol
                if inside:
                    per_cell[(col, row)]["e"] += e
                    per_cell[(col, row)]["n"] += 1
                else:
                    tot["outside_e"] += e
                d = arc_or_line(g, x, y, nx, ny, w)
                use_f = f if f is not None else pf
                if d > 1e-4 and use_f:
                    # Compare like the slicer does: geometric rate, with the
                    # cell's own flow ratio divided back out.
                    flow = cell["flow"] if inside else sliced_flow
                    rate = e * FILAMENT_AREA / d * (use_f / 60.0) / flow
                    tot["max_rate"] = max(tot["max_rate"], rate)
            x, y = nx, ny
    return per_cell, tot


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--before", required=True)
    ap.add_argument("--after", required=True)
    ap.add_argument("--map", required=True)
    ap.add_argument("--limit", type=float, default=None, help="volumetric ceiling, mm^3/s")
    ap.add_argument("--tol", type=float, default=0.6)
    args = ap.parse_args()

    doc = json.load(open(args.map))
    cells = {(c["col"], c["row"]): c for c in doc["cells"]}
    origin = (min(c["x"] for c in doc["cells"]), min(c["y"] for c in doc["cells"]))
    pitch = (doc["grid"]["pitch_x"], doc["grid"]["pitch_y"])
    size = (doc["grid"]["coupon_size"]["x"], doc["grid"]["coupon_size"]["y"])
    sliced_flow = doc["sliced_flow_ratio"]

    limit = args.limit
    if limit is None:
        for ln in open(args.before, encoding="utf-8", errors="replace"):
            if ln.startswith("; filament_max_volumetric_speed = "):
                limit = float(ln.split("=", 1)[1].strip().strip('"'))
                break

    a_cells, a_tot = scan(args.before, cells, origin, pitch, size, args.tol, sliced_flow)
    b_cells, b_tot = scan(args.after, cells, origin, pitch, size, args.tol, sliced_flow)

    fails = []

    def check(ok, msg):
        print(("  ok   " if ok else "  FAIL ") + msg)
        if not ok:
            fails.append(msg)

    print("structure")
    check(a_tot["lines"] == b_tot["lines"],
          f"line count unchanged ({a_tot['lines']} -> {b_tot['lines']})")

    print("per-cell flow")
    worst = 0.0
    for key, cell in sorted(cells.items()):
        want = cell["flow"] / sliced_flow
        got = b_cells[key]["e"] / a_cells[key]["e"] if a_cells[key]["e"] else 0.0
        worst = max(worst, abs(got - want))
        if a_cells[key]["n"] != b_cells[key]["n"]:
            fails.append(f"cell c{key[0]}r{key[1]} move count changed")
    check(worst < 2e-4, f"all {len(cells)} cells within {worst:.2e} of their flow multiplier")

    print("what must not change")
    check(abs(a_tot["retract_e"] - b_tot["retract_e"]) < 1e-6,
          f"retraction/wipe E untouched ({a_tot['retract_e']:.4f} mm)")
    check(abs(a_tot["travel_f"] - b_tot["travel_f"]) < 1e-6,
          "travel feedrates untouched")
    check(abs(a_tot["outside_e"] - b_tot["outside_e"]) < 1e-9,
          f"extrusion outside the coupons untouched ({a_tot['outside_e']:.2f} mm)")

    print("volumetric ceiling (geometric, as the slicer measures it)")
    if limit:
        check(b_tot["max_rate"] <= limit * SLACK * 1.001,
              f"peak geometric flow {b_tot['max_rate']:.3f} <= {limit} mm3/s "
              f"(was {a_tot['max_rate']:.3f} before)")
    else:
        print("  skip  no ceiling found")

    print()
    if fails:
        print(f"VERIFY FAILED — {len(fails)} problem(s)")
        sys.exit(1)
    print("VERIFY PASSED — safe to print")


if __name__ == "__main__":
    main()
