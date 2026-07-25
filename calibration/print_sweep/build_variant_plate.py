#!/usr/bin/env python3
"""Build a plate of IDENTICAL coupons that differ only by per-object slicer
settings (infill density, flow ratio, ...), each labelled with its variant name.

    python3 build_variant_plate.py --vpcb coupon.vpcb --template settings.3mf \
        --out plate/ --variant "SPARSE" --variant "SOLID:sparse_infill_density=100%"

A variant is LABEL[:key=value[,key=value...]] — the label is embossed on the
coupon and the key=value pairs become per-object overrides in
model_settings.config (the same mechanism as the bore×flow sweep's
print_flow_ratio, so a re-slice keeps them). The first variant with no overrides
is the same-plate control — print-to-print spread is ~×/÷1.5, so comparisons
belong on one plate.

Built for the plenum investigation: sparse-vs-solid infill on the 3-channel
plenum coupon decides whether channel↔channel coupling is mediated by the
infill void network.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_plate import (BED, read_binary_stl, centre_on_origin,  # noqa: E402
                         mesh_model_xml, uuid_for, template_metadata)

GAP = 5.0  # mm between coupons on the bed


def parse_variant(spec):
    label, _, rest = spec.partition(":")
    settings = {}
    if rest:
        for pair in rest.split(","):
            k, _, v = pair.partition("=")
            if not v:
                sys.exit(f"error: variant {spec!r}: expected key=value, got {pair!r}")
            settings[k.strip()] = v.strip()
    return {"label": label.strip(), "settings": settings}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vpcb", required=True)
    ap.add_argument("--template", required=True, help=".3mf whose print settings to reuse")
    ap.add_argument("--out", required=True)
    ap.add_argument("--cli", default="./.build/release/vacuum-cli")
    ap.add_argument("--body", default="topPlate")
    ap.add_argument("--variant", action="append", required=True,
                    help="LABEL[:key=value,...] — repeatable, one coupon each")
    ap.add_argument("--label-size", type=float, default=4.0)
    args = ap.parse_args()

    variants = [parse_variant(s) for s in args.variant]
    if len({v["label"] for v in variants}) != len(variants):
        sys.exit("error: variant labels must be unique (they are the only marking)")

    os.makedirs(args.out, exist_ok=True)

    # One labelled mesh per variant (geometry identical, label differs).
    meshes = []
    work = tempfile.mkdtemp(prefix="variant_plate.")
    try:
        for v in variants:
            stl = os.path.join(work, v["label"] + ".stl")
            r = subprocess.run([args.cli, "export", args.vpcb, "--body", args.body,
                                "--label", v["label"], "--label-size", str(args.label_size),
                                "--out", stl, "--json"], capture_output=True, text=True)
            if r.returncode != 0:
                sys.exit(f"error: export failed for {v['label']}:\n{r.stdout}\n{r.stderr}")
            body = json.loads(r.stdout)["bodies"][0]
            if not body["watertight"]:
                sys.exit(f"error: {v['label']} not watertight")
            verts, tris = read_binary_stl(stl)
            verts, size = centre_on_origin(verts)
            meshes.append({**v, "verts": verts, "tris": tris, "size": size})
            print(f"  {v['label']:12s} {len(tris)} tris  "
                  f"{size[0]:.1f}x{size[1]:.1f}x{size[2]:.2f} mm  overrides: "
                  f"{v['settings'] or '(control)'}")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    size = meshes[0]["size"]
    n = len(meshes)
    pitch_y = size[1] + GAP
    span_y = (n - 1) * pitch_y
    if size[0] + 2 > BED[0] or span_y + size[1] + 2 > BED[1]:
        sys.exit(f"error: {n} coupons of {size[0]:.0f}x{size[1]:.0f} do not fit the bed")
    centres = [(BED[0] / 2, BED[1] / 2 - span_y / 2 + i * pitch_y) for i in range(n)]

    wrapper = [2 + 2 * i for i in range(n)]
    inner = [101 + i for i in range(n)]

    model = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<model unit="millimeter" xml:lang="en-US" '
             'xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" '
             'xmlns:BambuStudio="http://schemas.bambulab.com/package/2021" '
             'xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06" '
             'requiredextensions="p">']
    model += template_metadata(args.template)
    model.append(' <resources>')
    for i in range(n):
        model += [f'  <object id="{wrapper[i]}" p:UUID="{uuid_for(0xa0, wrapper[i])}" type="model">',
                  '   <components>',
                  f'    <component p:path="/3D/Objects/object_{inner[i]}.model" '
                  f'objectid="{inner[i]}" p:UUID="{uuid_for(0xb0, inner[i])}" '
                  'transform="1 0 0 0 1 0 0 0 1 0 0 0"/>',
                  '   </components>', '  </object>']
    model.append(' </resources>')
    model.append(f' <build p:UUID="{uuid_for(0xc0, 1)}">')
    for i, (cx, cy) in enumerate(centres):
        model.append(f'  <item objectid="{wrapper[i]}" p:UUID="{uuid_for(0xd0, i)}" '
                     f'transform="1 0 0 0 1 0 0 0 1 {cx:g} {cy:g} {size[2] / 2:g}" printable="1"/>')
    model += [' </build>', '</model>', '']

    ms = ['<?xml version="1.0" encoding="UTF-8"?>', '<config>']
    for i, m in enumerate(meshes):
        ms += [f'  <object id="{wrapper[i]}">',
               f'    <metadata key="name" value="{m["label"]}"/>',
               '    <metadata key="extruder" value="1"/>']
        for k, v in m["settings"].items():
            ms.append(f'    <metadata key="{k}" value="{v}"/>')
        ms += [f'    <metadata face_count="{len(m["tris"])}"/>',
               f'    <part id="{inner[i]}" subtype="normal_part">',
               f'      <metadata key="name" value="{m["label"]}"/>',
               '      <metadata key="matrix" value="1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1"/>',
               f'      <mesh_stat face_count="{len(m["tris"])}" edges_fixed="0" '
               'degenerate_facets="0" facets_removed="0" facets_reversed="0" backwards_edges="0"/>',
               '    </part>', '  </object>']
    ms += ['  <plate>',
           '    <metadata key="plater_id" value="1"/>',
           '    <metadata key="plater_name" value="variant plate"/>',
           '    <metadata key="locked" value="false"/>',
           '    <metadata key="filament_map_mode" value="Auto For Flush"/>',
           '    <metadata key="filament_maps" value="1"/>']
    for i in range(n):
        ms += ['    <model_instance>',
               f'      <metadata key="object_id" value="{wrapper[i]}"/>',
               '      <metadata key="instance_id" value="0"/>',
               f'      <metadata key="identify_id" value="{1000 + 2 * i}"/>',
               '    </model_instance>']
    ms += ['  </plate>', '</config>', '']

    rels = ['<?xml version="1.0" encoding="UTF-8"?>',
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">']
    for i in range(n):
        rels.append(f' <Relationship Target="/3D/Objects/object_{inner[i]}.model" '
                    f'Id="rel-{i + 1}" '
                    'Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>')
    rels += ['</Relationships>', '']

    out_3mf = os.path.join(args.out, "variant_plate.3mf")
    with zipfile.ZipFile(args.template) as zt, \
         zipfile.ZipFile(out_3mf, "w", zipfile.ZIP_DEFLATED) as z:
        for info in zt.infolist():
            if info.filename.startswith(("3D/", "Metadata/model_settings")):
                continue
            z.writestr(info.filename, zt.read(info.filename))
        z.writestr("3D/3dmodel.model", "\n".join(model))
        z.writestr("3D/_rels/3dmodel.model.rels", "\n".join(rels))
        z.writestr("Metadata/model_settings.config", "\n".join(ms))
        for i, m in enumerate(meshes):
            z.writestr(f"3D/Objects/object_{inner[i]}.model",
                       mesh_model_xml(inner[i], uuid_for(0xe0, inner[i]),
                                      m["verts"], m["tris"]))

    doc = {"coupon": os.path.basename(args.vpcb), "body": args.body,
           "cells": [{"label": m["label"], "settings": m["settings"],
                      "x": centres[i][0], "y": centres[i][1],
                      "size": {"x": size[0], "y": size[1]}}
                     for i, m in enumerate(meshes)]}
    with open(os.path.join(args.out, "variant_map.json"), "w") as fh:
        json.dump(doc, fh, indent=2)

    print(f"\nwrote {out_3mf}  ({n} coupons, front-to-back: "
          + ", ".join(m["label"] for m in meshes) + ")")
    print(f"map: {args.out}/variant_map.json")


if __name__ == "__main__":
    main()
