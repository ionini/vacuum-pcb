#!/usr/bin/env python3
"""Stage 2: stamp per-cell G-code overrides onto a sliced sweep plate.

Reads the cell map written by build_plate.py and rewrites the G-code so each
coupon prints with its own flow ratio (and, if the map asks, its own speed
factor / fan speed). The slicer cannot do this: flow ratio and fan are filament
settings, one value per plate.

    python3 apply_matrix.py --gcode plate_1.gcode --map sweep_map.json

Cells are identified by POSITION, not by the slicer's object comments: every
extrusion move is assigned to the coupon footprint it falls inside. That works
on a GUI export and a `BambuStudio --slice` run alike (the CLI silently drops
`gcode_label_objects`), and it fails loudly rather than quietly if the G-code
does not match the map. When the object comments *are* present they are used as
an independent cross-check of the geometric assignment.

What is rewritten, inside a coupon's footprint only:
  * E on extrusion moves            x flow multiplier (target / sliced flow ratio)
  * F on extrusion moves            x speed factor, clamped to
                                    filament_max_volumetric_speed the way the
                                    slicer measures it (geometrically, before
                                    flow ratio — see the clamp for why)
  * M106 (part fan) inside a labelled object block, when the map sets fan
Retractions, wipes, travels, layer changes and the start/end G-code are never
touched.
"""
import argparse
import hashlib
import json
import math
import os
import re
import shutil
import sys
import zipfile

FILAMENT_AREA = math.pi * (1.75 / 2) ** 2  # mm^2 of 1.75 mm filament
SLACK = 1.005  # tolerance on the volumetric ceiling, see the clamp below

MOVE = re.compile(r"^G([0123])(?=[ \t]|$)")
WORD = re.compile(r"([XYZEFIJ])(-?\d*\.?\d+(?:[eE][-+]?\d+)?)")
OBJ_START = re.compile(r"^; printing object (.+) id:(\d+) copy (\d+)")
OBJ_STOP = re.compile(r"^; stop printing object (.+) id:(\d+) copy (\d+)")
FAN = re.compile(r"^(M106)((?:\s+P(\d+))?)\s+S([\d.]+)")


def extruded_length(g, x, y, nx, ny, words):
    """The path length the slicer computed E for.

    Arc fitting is on, so most moves are G2/G3 and their chord is shorter than
    the path — measuring the chord inflates mm^3/s by up to ~7% on tight arcs
    and would clamp moves the slicer had already brought exactly to the
    ceiling. I/J are the centre offset from the current position.
    """
    chord = math.hypot(nx - x, ny - y)
    if g not in (2, 3) or ("I" not in words and "J" not in words):
        return chord
    i = float(words.get("I", 0.0))
    j = float(words.get("J", 0.0))
    r = math.hypot(i, j)
    if r < 1e-9:
        return chord
    cx, cy = x + i, y + j
    a0 = math.atan2(y - cy, x - cx)
    a1 = math.atan2(ny - cy, nx - cx)
    sweep = (a0 - a1) if g == 2 else (a1 - a0)
    sweep %= 2 * math.pi
    if sweep < 1e-9:
        sweep = 2 * math.pi      # start == end means a full circle
    return r * sweep


def fmt(v):
    """Bambu's number style: no trailing zeros, no leading zero on |v| < 1."""
    s = f"{v:.6f}".rstrip("0").rstrip(".")
    if s.startswith("0."):
        s = s[1:]
    elif s.startswith("-0."):
        s = "-" + s[2:]
    return s or "0"


def fmt_f(v):
    return f"{v:.0f}" if abs(v - round(v)) < 1e-6 else f"{v:.1f}"


class Grid:
    """Maps a bed coordinate to the coupon that owns it."""

    def __init__(self, doc, tol):
        g = doc["grid"]
        self.pitch = (g["pitch_x"], g["pitch_y"])
        self.size = (g["coupon_size"]["x"], g["coupon_size"]["y"])
        self.tol = tol
        self.cells = {(c["col"], c["row"]): c for c in doc["cells"]}
        self.origin = (min(c["x"] for c in doc["cells"]), min(c["y"] for c in doc["cells"]))
        self.cols = max(c["col"] for c in doc["cells"]) + 1
        self.rows = max(c["row"] for c in doc["cells"]) + 1

    def at(self, x, y):
        """-> cell dict, or None when the point is outside every coupon (purge
        line, skirt, travel over a gap)."""
        col = round((x - self.origin[0]) / self.pitch[0])
        row = round((y - self.origin[1]) / self.pitch[1])
        cell = self.cells.get((col, row))
        if cell is None:
            return None
        if (abs(x - cell["x"]) <= self.size[0] / 2 + self.tol
                and abs(y - cell["y"]) <= self.size[1] / 2 + self.tol):
            return cell
        return None


def load_gcode(path):
    """-> (lines, repack) where repack(new_lines, dest) writes the same
    container back out. A .gcode.3mf keeps its wrapper so the plate can still be
    sent from Bambu Studio / Handy."""
    if path.endswith(".3mf"):
        with zipfile.ZipFile(path) as z:
            inner = [n for n in z.namelist() if re.fullmatch(r"Metadata/plate_\d+\.gcode", n)]
            if len(inner) != 1:
                sys.exit(f"error: expected exactly one plate G-code in {path}, found {inner}")
            name = inner[0]
            blob = z.read(name).decode("utf-8", "replace")
            entries = {n: z.read(n) for n in z.namelist()}

        def repack(text, dest):
            digest = hashlib.md5(text.encode("utf-8")).hexdigest().upper()
            with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as out:
                for n, data in entries.items():
                    if n == name:
                        data = text.encode("utf-8")
                    elif n == name + ".md5":
                        data = digest.encode("utf-8")
                    out.writestr(n, data)
        return blob.splitlines(), repack

    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        blob = fh.read()

    def repack(text, dest):
        with open(dest, "w", encoding="utf-8") as fh:
            fh.write(text)
    return blob.splitlines(), repack


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gcode", required=True, help="sliced plate (.gcode or .gcode.3mf)")
    ap.add_argument("--map", required=True, help="sweep_map.json from build_plate.py")
    ap.add_argument("--out", help="default: <input>_swept.<ext> beside the input")
    ap.add_argument("--max-volumetric", type=float, default=None,
                    help="override filament_max_volumetric_speed (mm^3/s); "
                         "read from the G-code config block by default")
    ap.add_argument("--tol", type=float, default=0.6,
                    help="mm a move may sit outside a coupon footprint and still "
                         "count as that coupon's (default 0.6)")
    args = ap.parse_args()

    with open(args.map) as fh:
        doc = json.load(fh)
    grid = Grid(doc, args.tol)
    sliced_flow = doc["sliced_flow_ratio"]
    lines, repack = load_gcode(args.gcode)

    limit = args.max_volumetric
    for ln in lines:
        if limit is None and ln.startswith("; filament_max_volumetric_speed = "):
            limit = float(ln.split("=", 1)[1].strip().strip('"'))
        if ln.startswith("; filament_flow_ratio = "):
            got = float(ln.split("=", 1)[1].strip().strip('"'))
            if abs(got - sliced_flow) > 1e-9:
                sys.exit(f"error: the map was built for flow ratio {sliced_flow}, but this "
                         f"G-code was sliced at {got} — rebuild the map or re-slice")
    if limit is None:
        sys.exit("error: no filament_max_volumetric_speed in the G-code; pass --max-volumetric")

    wants_fan = any(c.get("fan") is not None for c in doc["cells"])

    # --- rewrite -------------------------------------------------------------
    out = []
    x = y = None                # last commanded position
    print_f = None              # last commanded feedrate on a print move
    obj = None                  # (name, id, copy) of the labelled block we are in
    labels_seen = 0
    stats = {k: {"moves": 0, "e_in": 0.0, "e_out": 0.0, "clamped": 0} for k in grid.cells}
    unassigned = {"moves": 0, "e": 0.0}
    mismatch = []
    fan_restore = None

    for raw in lines:
        line = raw
        m = OBJ_START.match(line)
        if m:
            obj = (m.group(1), int(m.group(2)), int(m.group(3)))
            labels_seen += 1
        elif OBJ_STOP.match(line):
            obj = None
            if fan_restore is not None:
                out.append(fan_restore)
                fan_restore = None

        mm = MOVE.match(line)
        if not mm:
            if wants_fan and obj is not None:
                fm = FAN.match(line)
                if fm and (fm.group(3) in (None, "1")):
                    pass  # handled below once the cell is known
            out.append(line)
            continue

        words = dict(WORD.findall(line))
        nx = float(words["X"]) if "X" in words else x
        ny = float(words["Y"]) if "Y" in words else y
        e = float(words["E"]) if "E" in words else None
        f = float(words["F"]) if "F" in words else None
        has_xy = "X" in words or "Y" in words
        has_arc = "I" in words or "J" in words

        # An extrusion move: a real XY/arc displacement laying down material.
        # Everything else (retract, unretract, wipe with E<0, travel, Z hop)
        # passes through byte-for-byte.
        is_extrusion = e is not None and e > 0 and (has_xy or has_arc)
        if f is not None and (is_extrusion or not has_xy):
            print_f = f            # standalone "G1 F960" also sets the print feed

        cell = None
        if is_extrusion and x is not None and y is not None:
            start = grid.at(x, y)
            end = grid.at(nx, ny)
            if start is not None and end is not None and start is end:
                cell = start
            elif start is not None or end is not None:
                cell = None        # straddles a gap: leave it alone

        if cell is None:
            if is_extrusion:
                unassigned["moves"] += 1
                unassigned["e"] += e
            out.append(line)
            x, y = nx, ny
            continue

        key = (cell["col"], cell["row"])
        if obj is not None and cell.get("object"):
            # Cross-check the geometric assignment against the slicer's own
            # object name, which build_plate.py set per cell.
            if cell["object"] not in obj[0] and (obj[0], key) not in mismatch:
                mismatch.append((obj[0], key))

        flow_mult = cell["flow"] / sliced_flow
        speed_mult = cell.get("speed", 1.0)
        # Clamp against the number that actually gets written: on micron-scale
        # moves E rounds to a few units in the last place, which is several
        # percent, and a clamp computed on the unrounded value would leave the
        # emitted move just over the ceiling.
        e_str = fmt(e * flow_mult)
        e_new = float(e_str)
        f_new = (f if f is not None else print_f)
        if f_new is not None:
            f_new *= speed_mult

        # Re-apply the volumetric ceiling the slicer honoured at slice time.
        #
        # Bambu applies max_volumetric_speed to the *geometric* extrusion rate,
        # before the flow-ratio multiplier: sparse infill comes out of the slicer
        # at 2.5 x 1.01 = 2.525 mm^3/s of actual filament, i.e. exactly 2.500
        # once flow ratio is divided out. So the ceiling on the E we write is
        # limit x this cell's flow ratio — which means a pure flow change needs
        # no clamping at all, exactly as a native re-slice at that flow ratio
        # would need none. That is what makes the sweep transferable: what wins
        # here is what typing the same number into the filament profile gives.
        # The clamp still binds when speed is swept, which is the case the
        # slicer really would have slowed down.
        # SLACK absorbs the slicer's own rounding.
        ceiling = limit * cell["flow"]
        dist = extruded_length(int(mm.group(1)), x, y, nx, ny, words)
        clamped = False
        if f_new is not None and dist > 1e-4:
            rate = e_new * FILAMENT_AREA / dist * (f_new / 60.0)
            if rate > ceiling * SLACK:
                f_new = ceiling * 60.0 * dist / (e_new * FILAMENT_AREA)
                clamped = True

        line = re.sub(r"E-?\d*\.?\d+(?:[eE][-+]?\d+)?", "E" + e_str, line, count=1)
        if f_new is not None:
            if "F" in words:
                line = re.sub(r"F-?\d*\.?\d+(?:[eE][-+]?\d+)?", "F" + fmt_f(f_new), line, count=1)
            elif speed_mult != 1.0 or clamped:
                line = line.rstrip() + " F" + fmt_f(f_new)

        st = stats[key]
        st["moves"] += 1
        st["e_in"] += e
        st["e_out"] += e_new
        st["clamped"] += 1 if clamped else 0

        if wants_fan and obj is not None and cell.get("fan") is not None and fan_restore is None:
            out.append(f"M106 P1 S{round(cell['fan'] * 255 / 100)} ; sweep cell "
                       f"c{cell['col']}r{cell['row']}")
            fan_restore = "M106 P1 S0 ; sweep cell end"

        out.append(line)
        x, y = nx, ny

    # --- checks --------------------------------------------------------------
    missing = [k for k, s in stats.items() if s["moves"] == 0]
    if missing:
        sys.exit(f"error: {len(missing)} of {len(stats)} cells got no extrusion moves "
                 f"(e.g. {sorted(missing)[:5]}) — does this G-code come from this plate?")
    if mismatch:
        sys.exit(f"error: the slicer's object labels disagree with the grid positions "
                 f"({len(mismatch)} cases, e.g. {mismatch[0]}) — the map does not "
                 f"describe this plate")
    if wants_fan and labels_seen == 0:
        sys.exit("error: the map sets a fan speed, which needs the slicer's per-object "
                 "comments — slice with gcode_label_objects on (a GUI export has it)")

    dest = args.out
    if dest is None:
        base, ext = os.path.splitext(args.gcode)
        if base.endswith(".gcode"):
            base, ext = os.path.splitext(base)[0], ".gcode" + ext
        dest = base + "_swept" + ext
    text = "\n".join(out) + "\n"
    repack(text, dest)

    # --- report --------------------------------------------------------------
    print(f"cells: {len(stats)}   object labels: "
          f"{'present (cross-checked)' if labels_seen else 'absent (position-only)'}")
    print(f"volumetric ceiling: {limit} mm3/s")
    print(f"unassigned extrusion moves (purge line, skirt, gap crossings): "
          f"{unassigned['moves']} ({unassigned['e']:.1f} mm of filament) — left untouched")
    print()
    print("  row  flow   E multiplier            clamped moves per column")
    print("  " + "-" * 62)
    for row in range(grid.rows):
        cells = [grid.cells[(c, row)] for c in range(grid.cols)]
        got = [stats[(c, row)]["e_out"] / stats[(c, row)]["e_in"] for c in range(grid.cols)]
        clamps = [stats[(c, row)]["clamped"] for c in range(grid.cols)]
        want = cells[0]["flow"] / sliced_flow
        print(f"  r{row:<3} {cells[0]['flow']:.2f}  want {want:.4f} got "
              f"{min(got):.4f}-{max(got):.4f}   " + " ".join(f"{c:5d}" for c in clamps))
    print()
    total_in = sum(s["e_in"] for s in stats.values())
    total_out = sum(s["e_out"] for s in stats.values())
    print(f"extrusion inside coupons: {total_in:.1f} -> {total_out:.1f} mm filament "
          f"({100 * (total_out / total_in - 1):+.2f}%)")
    print(f"wrote {dest}")
    print("NOTE: the printer's own time/progress estimate (M73) is not recalculated; "
          "clamped moves make the real print slightly longer than the header says.")


if __name__ == "__main__":
    main()
