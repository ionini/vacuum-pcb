#!/usr/bin/env python3
"""Build a Bambu Studio plate that sweeps resistor bore diameter x flow ratio.

One plate carrying COLS x ROWS copies of the same coupon (the top plate of a
board), laid out on a deterministic grid:

    columns (X, left -> right)  = resistor bore diameter  — GEOMETRY, so each
                                  column is its own mesh, exported from the
                                  .vpcb with `resistorChannelDiameter` set
    rows    (Y, front -> back)  = filament flow ratio     — G-CODE, applied
                                  afterwards by apply_matrix.py

Bore diameter cannot be swept in the slicer (it is part of the model), and flow
ratio cannot be swept per object (it is a filament setting), so the sweep is
split across the two stages. This script does stage 1: mesh generation + plate
authoring + the cell map that stage 2 and the bench read from.

    python3 build_plate.py --vpcb "L resistor thinner.vpcb" \
                           --template "Resistor test.3mf" --out sweep

writes  sweep/bore_flow_sweep.3mf   open in Bambu Studio, slice, export G-code
        sweep/sweep_map.json        cell -> bore / flow / bed position
        sweep/sweep_map.md          the same table for the lab notebook
        sweep/collection_sheet.svg  true-scale sheet to lay the coupons out on

The template .3mf supplies the print/filament/printer settings verbatim — the
plate is rebuilt around them, nothing about the process is changed here.
"""
import argparse
import json
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

# --- the sweep ---------------------------------------------------------------

# Columns: resistor bore diameter, mm. Resistance runs as ~1/d^4 (Poiseuille),
# so the relative-R column in the map spans ~16x across this list.
BORES = [0.35, 0.40, 0.45, 0.50, 0.60, 0.70]

# Rows: *effective* filament flow ratio. apply_matrix.py converts each to a
# multiplier against the flow ratio the plate was sliced with.
FLOWS = [0.98, 1.00, 1.02, 1.04, 1.06, 1.08, 1.10, 1.12, 1.14, 1.16]

# --- plate geometry ---------------------------------------------------------

BED = (180.0, 180.0)  # A1 mini
PITCH_X = 28.0        # 25 mm coupon + 3 mm gap  (X is the binding axis)
PITCH_Y = 13.0        # 8 mm coupon + 5 mm gap

FILAMENT_AREA = math.pi * (1.75 / 2) ** 2  # mm^2, for the R estimate only


# --- geometry helpers -------------------------------------------------------

def read_binary_stl(path):
    """-> (vertices, triangles), vertices deduplicated, degenerates dropped."""
    with open(path, "rb") as fh:
        data = fh.read()
    count = struct.unpack("<I", data[80:84])[0]
    index = {}
    verts = []
    tris = []
    off = 84
    for _ in range(count):
        xyz = struct.unpack("<9f", data[off + 12:off + 48])
        corner = []
        for j in range(3):
            key = (round(xyz[j * 3], 5), round(xyz[j * 3 + 1], 5), round(xyz[j * 3 + 2], 5))
            k = index.get(key)
            if k is None:
                k = len(verts)
                index[key] = k
                verts.append(key)
            corner.append(k)
        if len(set(corner)) == 3:
            tris.append(corner)
        off += 50
    return verts, tris


def centre_on_origin(verts):
    """Bambu's import convention: XY centred, Z centred (the build item's tz
    then lifts the mesh onto the bed)."""
    xs = [v[0] for v in verts]
    ys = [v[1] for v in verts]
    zs = [v[2] for v in verts]
    cx = (min(xs) + max(xs)) / 2
    cy = (min(ys) + max(ys)) / 2
    cz = (min(zs) + max(zs)) / 2
    size = (max(xs) - min(xs), max(ys) - min(ys), max(zs) - min(zs))
    return [(v[0] - cx, v[1] - cy, v[2] - cz) for v in verts], size


def mesh_model_xml(object_id, uuid, verts, tris):
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<model unit="millimeter" xml:lang="en-US" '
           'xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" '
           'xmlns:BambuStudio="http://schemas.bambulab.com/package/2021" '
           'xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06" '
           'requiredextensions="p">',
           ' <metadata name="BambuStudio:3mfVersion">1</metadata>',
           ' <resources>',
           f'  <object id="{object_id}" p:UUID="{uuid}" type="model">',
           '   <mesh>',
           '    <vertices>']
    for x, y, z in verts:
        out.append(f'     <vertex x="{x:.7g}" y="{y:.7g}" z="{z:.7g}"/>')
    out.append('    </vertices>')
    out.append('    <triangles>')
    for a, b, c in tris:
        out.append(f'     <triangle v1="{a}" v2="{b}" v3="{c}"/>')
    out.append('    </triangles>')
    out += ['   </mesh>', '  </object>', ' </resources>', '</model>', '']
    return "\n".join(out)


def uuid_for(kind, n):
    """Deterministic, well-formed UUIDs — Bambu only needs them unique."""
    tail = f"{kind:04x}{n:04x}"
    return f"{tail[:8]}-{n:04x}-4c03-9d28-80fed5dfa1dc"


# --- stage 1a: one mesh per bore diameter -----------------------------------

def export_bore_meshes(vpcb, bores, cli, workdir):
    """Write the .vpcb once per bore with `resistorChannelDiameter` overridden
    and export its top plate alone. -> [(bore, verts, tris, size)]"""
    with open(vpcb) as fh:
        doc = json.load(fh)
    if "resistorChannelDiameter" not in doc.get("manufacturing", {}):
        sys.exit(f"error: {vpcb} has no manufacturing.resistorChannelDiameter")

    meshes = []
    for bore in bores:
        doc["manufacturing"]["resistorChannelDiameter"] = bore
        vp = os.path.join(workdir, f"bore_{bore:.2f}.vpcb")
        stl = os.path.join(workdir, f"bore_{bore:.2f}.stl")
        with open(vp, "w") as fh:
            json.dump(doc, fh, indent=2)
        r = subprocess.run([cli, "export", vp, "--body", "topPlate", "--out", stl, "--json"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"error: export failed for bore {bore}:\n{r.stdout}\n{r.stderr}")
        body = json.loads(r.stdout)["bodies"][0]
        if not body["watertight"]:
            sys.exit(f"error: bore {bore} top plate is not watertight — a slicer would reject it")
        verts, tris = read_binary_stl(stl)
        verts, size = centre_on_origin(verts)
        meshes.append((bore, verts, tris, size, body["signedVolume"]))
        print(f"  bore {bore:.2f} mm -> {len(tris)} triangles, "
              f"{size[0]:.1f}x{size[1]:.1f}x{size[2]:.1f} mm, {body['signedVolume']:.1f} mm3")
    return meshes


# --- stage 1b: author the plate ---------------------------------------------

def grid_positions(cols, rows):
    """Cell centres in bed coordinates, centred on the bed. Row 0 is the FRONT
    of the bed (low Y), column 0 the left (low X)."""
    span_x = (cols - 1) * PITCH_X
    span_y = (rows - 1) * PITCH_Y
    x0 = BED[0] / 2 - span_x / 2
    y0 = BED[1] / 2 - span_y / 2
    return [[(x0 + c * PITCH_X, y0 + r * PITCH_Y) for c in range(cols)] for r in range(rows)]


def template_metadata(template):
    """The template's <metadata> header, verbatim.

    Bambu Studio only honours a 3mf's embedded project settings when
    `<metadata name="Application">` names BambuStudio — rewrite that line and it
    treats the file as a foreign 3mf and silently slices with whatever presets
    happen to be default (a 0.4 nozzle, in testing). So the header is copied as
    it stands; provenance goes in the plate name instead.
    """
    with zipfile.ZipFile(template) as z:
        model = z.read("3D/3dmodel.model").decode("utf-8")
    head = [ln for ln in model.split("<resources>")[0].splitlines()
            if ln.strip().startswith("<metadata ")]
    if not any('name="Application"' in ln and "BambuStudio" in ln for ln in head):
        sys.exit(f"error: {template} has no BambuStudio Application metadata — "
                 "Bambu Studio would ignore its print settings")
    return head


def build_3mf(template, meshes, flows, out_path):
    """Rebuild the template's plate as len(meshes) objects x len(flows)
    instances, keeping every settings file byte-for-byte."""
    cols, rows = len(meshes), len(flows)
    centres = grid_positions(cols, rows)
    size = meshes[0][3]
    half = (size[0] / 2, size[1] / 2, size[2] / 2)

    # Bed fit is a hard error: an off-bed instance silently disappears in Bambu.
    for r in range(rows):
        for c in range(cols):
            cx, cy = centres[r][c]
            if not (0 < cx - half[0] and cx + half[0] < BED[0]
                    and 0 < cy - half[1] and cy + half[1] < BED[1]):
                sys.exit(f"error: cell c{c}r{r} at ({cx:.1f},{cy:.1f}) falls off the "
                         f"{BED[0]:.0f}x{BED[1]:.0f} bed — reduce the grid or the pitch")

    names = [f"bore-{m[0]:.2f}" for m in meshes]
    wrapper_ids = [2 + 2 * i for i in range(cols)]   # mirrors Bambu's even ids
    inner_ids = [101 + i for i in range(cols)]

    model = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<model unit="millimeter" xml:lang="en-US" '
             'xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" '
             'xmlns:BambuStudio="http://schemas.bambulab.com/package/2021" '
             'xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06" '
             'requiredextensions="p">']
    model += template_metadata(template)
    model.append(' <resources>')
    for i in range(cols):
        model.append(f'  <object id="{wrapper_ids[i]}" p:UUID="{uuid_for(0xa0, wrapper_ids[i])}" type="model">')
        model.append('   <components>')
        model.append(f'    <component p:path="/3D/Objects/object_{inner_ids[i]}.model" '
                     f'objectid="{inner_ids[i]}" p:UUID="{uuid_for(0xb0, inner_ids[i])}" '
                     f'transform="1 0 0 0 1 0 0 0 1 0 0 0"/>')
        model.append('   </components>')
        model.append('  </object>')
    model.append(' </resources>')
    model.append(f' <build p:UUID="{uuid_for(0xc0, 1)}">')

    cells = []
    item = 0
    # Instance order is column-major so instance_id (and therefore the G-code's
    # "copy N") counts up through the rows of one column: copy = row index.
    for c in range(cols):
        for r in range(rows):
            cx, cy = centres[r][c]
            model.append(f'  <item objectid="{wrapper_ids[c]}" p:UUID="{uuid_for(0xd0, item)}" '
                         f'transform="1 0 0 0 1 0 0 0 1 {cx:g} {cy:g} {half[2]:g}" printable="1"/>')
            cells.append({"col": c, "row": r, "object": names[c], "instance": r,
                          "bore": meshes[c][0], "flow": flows[r],
                          "x": round(cx, 3), "y": round(cy, 3)})
            item += 1
    model += [' </build>', '</model>', '']

    # model_settings.config: object + part per column, one plate, all instances.
    ms = ['<?xml version="1.0" encoding="UTF-8"?>', '<config>']
    for i in range(cols):
        ms.append(f'  <object id="{wrapper_ids[i]}">')
        ms.append(f'    <metadata key="name" value="{names[i]}"/>')
        ms.append('    <metadata key="extruder" value="1"/>')
        ms.append(f'    <metadata face_count="{len(meshes[i][2])}"/>')
        ms.append(f'    <part id="{inner_ids[i]}" subtype="normal_part">')
        ms.append(f'      <metadata key="name" value="{names[i]}"/>')
        ms.append('      <metadata key="matrix" value="1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1"/>')
        ms.append(f'      <mesh_stat face_count="{len(meshes[i][2])}" edges_fixed="0" '
                  'degenerate_facets="0" facets_removed="0" facets_reversed="0" backwards_edges="0"/>')
        ms.append('    </part>')
        ms.append('  </object>')
    ms += ['  <plate>',
           '    <metadata key="plater_id" value="1"/>',
           '    <metadata key="plater_name" value="bore x flow"/>',
           '    <metadata key="locked" value="false"/>',
           '    <metadata key="filament_map_mode" value="Auto For Flush"/>',
           '    <metadata key="filament_maps" value="1"/>']
    ident = 1000
    for c in range(cols):
        for r in range(rows):
            ms.append('    <model_instance>')
            ms.append(f'      <metadata key="object_id" value="{wrapper_ids[c]}"/>')
            ms.append(f'      <metadata key="instance_id" value="{r}"/>')
            ms.append(f'      <metadata key="identify_id" value="{ident}"/>')
            ms.append('    </model_instance>')
            ident += 2
    ms += ['  </plate>', '</config>', '']

    rels = ['<?xml version="1.0" encoding="UTF-8"?>',
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">']
    for i in range(cols):
        rels.append(f' <Relationship Target="/3D/Objects/object_{inner_ids[i]}.model" '
                    f'Id="rel-{i + 1}" '
                    'Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>')
    rels += ['</Relationships>', '']

    # Everything else (settings, content types, package rels) rides along from
    # the template untouched; stale plate thumbnails are regenerated on slice.
    # The one setting forced on is gcode_label_objects: the per-object comment
    # fences it emits are how apply_matrix.py finds each cell in the G-code, and
    # a CLI slice leaves it off. It only adds comments + M624/M625.
    carry = {}
    with zipfile.ZipFile(template) as z:
        for info in z.infolist():
            if info.filename.startswith(("3D/", "Metadata/model_settings")):
                continue
            blob = z.read(info.filename)
            if info.filename == "Metadata/project_settings.config":
                settings = json.loads(blob)
                settings["gcode_label_objects"] = "1"
                blob = json.dumps(settings, indent=4).encode("utf-8")
            carry[info.filename] = blob

    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as z:
        for name, blob in carry.items():
            z.writestr(name, blob)
        z.writestr("3D/3dmodel.model", "\n".join(model))
        z.writestr("3D/_rels/3dmodel.model.rels", "\n".join(rels))
        z.writestr("Metadata/model_settings.config", "\n".join(ms))
        for i in range(cols):
            z.writestr(f"3D/Objects/object_{inner_ids[i]}.model",
                       mesh_model_xml(inner_ids[i], uuid_for(0xe0, inner_ids[i]),
                                      meshes[i][1], meshes[i][2]))
    return cells, centres, size


# --- the map ----------------------------------------------------------------

def relative_resistance(bore, ref):
    """Poiseuille: R ~ 1/d^4 for a round bore. A guide for reading the bench
    numbers, not a prediction — the printed bore is not the modelled one."""
    return (ref / bore) ** 4


def write_map(cells, meshes, flows, sliced_flow_ratio, out_dir, size):
    cols, rows = len(meshes), len(flows)
    ref = meshes[0][0]
    doc = {
        "grid": {"cols": cols, "rows": rows, "pitch_x": PITCH_X, "pitch_y": PITCH_Y,
                 "coupon_size": {"x": size[0], "y": size[1], "z": size[2]}, "bed": BED},
        "axes": {"x": "resistor bore diameter (mm)", "y": "effective flow ratio"},
        "bores": [m[0] for m in meshes],
        "flows": flows,
        "sliced_flow_ratio": sliced_flow_ratio,
        "cells": cells,
    }
    with open(os.path.join(out_dir, "sweep_map.json"), "w") as fh:
        json.dump(doc, fh, indent=2)

    md = ["# Resistor bore x flow-ratio sweep — cell map", "",
          f"Plate: {cols} columns (bore) x {rows} rows (flow) = {cols * rows} coupons, "
          f"{size[0]:.0f}x{size[1]:.0f}x{size[2]:.0f} mm each.",
          f"Column pitch {PITCH_X:g} mm, row pitch {PITCH_Y:g} mm. "
          "**Row 0 is the FRONT of the bed** (low Y), column 0 the left (low X).", "",
          "## Columns — resistor bore diameter (geometry)", "",
          "| col | bore mm | est. R relative to " + f"{ref:.2f} mm | bed X mm |",
          "|---|---|---|---|"]
    for c in range(cols):
        x = [cell["x"] for cell in cells if cell["col"] == c][0]
        md.append(f"| {c} | {meshes[c][0]:.2f} | {relative_resistance(meshes[c][0], ref):.3f}x | {x:.1f} |")
    md += ["", "R estimate is ideal Poiseuille (1/d^4) on the *modelled* bore — the point of",
           "the print is that the printed bore is not the modelled one.", "",
           "## Rows — effective flow ratio (G-code)", "",
           "| row | flow ratio | E multiplier | bed Y mm |", "|---|---|---|---|"]
    for r in range(rows):
        y = [cell["y"] for cell in cells if cell["row"] == r][0]
        md.append(f"| {r} | {flows[r]:.2f} | {flows[r] / sliced_flow_ratio:.4f} | {y:.1f} |")
    md += ["", f"Sliced at flow ratio {sliced_flow_ratio:g}; the multiplier is what",
           "apply_matrix.py scales each cell's extrusion by.", "",
           "## Results", "",
           "| col | row | bore | flow | R measured | leaks? | notes |", "|---|---|---|---|---|---|---|"]
    for cell in cells:
        md.append(f"| {cell['col']} | {cell['row']} | {cell['bore']:.2f} | {cell['flow']:.2f} |  |  |  |")
    md.append("")
    with open(os.path.join(out_dir, "sweep_map.md"), "w") as fh:
        fh.write("\n".join(md))


def write_collection_sheet(cells, meshes, flows, out_dir, size):
    """A true-scale sheet to lay the coupons on as they come off the plate —
    60 identical parts are indistinguishable once they leave the bed."""
    cols, rows = len(meshes), len(flows)
    pad, label = 22.0, 10.0
    w = pad * 2 + cols * PITCH_X
    h = pad * 2 + rows * PITCH_Y + label
    s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}mm" height="{h}mm" '
         f'viewBox="0 0 {w} {h}">',
         '<style>text{font-family:Helvetica,Arial,sans-serif}</style>',
         f'<rect x="0" y="0" width="{w}" height="{h}" fill="#fff"/>',
         f'<text x="{pad}" y="{label}" font-size="4.2" font-weight="bold">'
         f'resistor bore x flow sweep — lay each coupon in its box (true scale)</text>',
         f'<text x="{pad}" y="{label + 5}" font-size="3">bed front (low Y) is at the BOTTOM; '
         f'column 0 / left = smallest bore</text>']
    for r in range(rows):
        # SVG y grows downward, the bed's Y grows away from the user: flip rows
        # so the sheet reads the same way round as the plate in front of you.
        for c in range(cols):
            x = pad + c * PITCH_X + (PITCH_X - size[0]) / 2
            y = label + pad + (rows - 1 - r) * PITCH_Y + (PITCH_Y - size[1]) / 2
            s.append(f'<rect x="{x:.2f}" y="{y:.2f}" width="{size[0]:.2f}" height="{size[1]:.2f}" '
                     'fill="none" stroke="#888" stroke-width="0.25" stroke-dasharray="1.5 1"/>')
            s.append(f'<text x="{x + 1:.2f}" y="{y + size[1] / 2 + 1.1:.2f}" font-size="2.6" '
                     f'fill="#333">c{c}r{r} {meshes[c][0]:.2f} / {flows[r]:.2f}</text>')
    for c in range(cols):
        x = pad + c * PITCH_X + PITCH_X / 2
        s.append(f'<text x="{x:.2f}" y="{label + pad - 3:.2f}" font-size="3.2" '
                 f'text-anchor="middle" font-weight="bold">{meshes[c][0]:.2f}</text>')
    for r in range(rows):
        y = label + pad + (rows - 1 - r) * PITCH_Y + PITCH_Y / 2 + 1
        s.append(f'<text x="{pad - 3:.2f}" y="{y:.2f}" font-size="3.2" '
                 f'text-anchor="end" font-weight="bold">{flows[r]:.2f}</text>')
    s.append(f'<text x="{pad + cols * PITCH_X / 2:.2f}" y="{h - pad / 2:.2f}" font-size="3.2" '
             'text-anchor="middle">bore diameter, mm  (rows = flow ratio)</text>')
    s.append('</svg>')
    with open(os.path.join(out_dir, "collection_sheet.svg"), "w") as fh:
        fh.write("\n".join(s))


# --- main -------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vpcb", required=True, help="source board (its top plate is the coupon)")
    ap.add_argument("--template", required=True, help=".3mf whose print settings to reuse")
    ap.add_argument("--out", required=True, help="output directory")
    ap.add_argument("--cli", default="./.build/release/vacuum-cli")
    ap.add_argument("--bores", type=float, nargs="+", default=BORES)
    ap.add_argument("--flows", type=float, nargs="+", default=FLOWS)
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    with zipfile.ZipFile(args.template) as z:
        settings = json.loads(z.read("Metadata/project_settings.config"))
    sliced_flow = float(settings["filament_flow_ratio"][0])
    print(f"template: {settings['printer_settings_id']}")
    print(f"          {settings['print_settings_id']}, flow ratio {sliced_flow:g}, "
          f"nozzle {settings['nozzle_diameter'][0]} mm, layer {settings['layer_height']} mm")

    print(f"exporting {len(args.bores)} bore variants of {os.path.basename(args.vpcb)}:")
    work = tempfile.mkdtemp(prefix="print_sweep.")
    try:
        meshes = export_bore_meshes(args.vpcb, args.bores, args.cli, work)
    finally:
        shutil.rmtree(work, ignore_errors=True)

    sizes = {tuple(round(v, 3) for v in m[3]) for m in meshes}
    if len(sizes) != 1:
        sys.exit(f"error: bore variants differ in size ({sizes}) — the grid assumes one footprint")

    out_3mf = os.path.join(args.out, "bore_flow_sweep.3mf")
    cells, _, size = build_3mf(args.template, meshes, args.flows, out_3mf)
    write_map(cells, meshes, args.flows, sliced_flow, args.out, size)
    write_collection_sheet(cells, meshes, args.flows, args.out, size)

    span_x = (len(meshes) - 1) * PITCH_X + size[0]
    span_y = (len(args.flows) - 1) * PITCH_Y + size[1]
    print(f"\nwrote {out_3mf}")
    print(f"  {len(cells)} coupons, {len(meshes)} bores x {len(args.flows)} flow ratios")
    print(f"  plate footprint {span_x:.1f} x {span_y:.1f} mm on a {BED[0]:.0f} x {BED[1]:.0f} bed "
          f"(gaps {PITCH_X - size[0]:.1f} / {PITCH_Y - size[1]:.1f} mm)")
    print(f"  map: {args.out}/sweep_map.json, sweep_map.md, collection_sheet.svg")
    print("\nNext: slice it (settings come from the template), export the G-code, then")
    print(f"  python3 apply_matrix.py --gcode <sliced> --map {args.out}/sweep_map.json")


if __name__ == "__main__":
    main()
