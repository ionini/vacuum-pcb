# Export for Bambu Studio (print-critical modifier)

First-pass workflow for slicing print-critical pneumatic features (channels,
valve chambers/seals, vias, and the thin walls/roofs/floors around them) with
different settings in Bambu Studio, using its **modifier volume** feature.

It writes **two aligned STLs** plus standalone bodies:

```
<base>_model.stl       top + bottom plate, laid out for printing (see below)
<base>_modifier.stl    the print-critical modifier envelope, laid out identically
<base>_stencil.stl     silicone cutting template — separate object (when enabled)
<base>_mold.stl        casting frame — separate object (when enabled)
<base>_bambu_export.json   optional manifest
```

**Print layout, not design layout.** The model ships the two plates side by
side on the bed (10 mm apart, resting at z = 0), with the bottom plate already
flipped to its print orientation (silicone face down, channel arches up). This
is what makes the multipart-with-modifier workflow actually sliceable: the
first version shipped the bodies in design position (plates sandwiched around
the silicone gap), which forced a "Split objects" step in Bambu — and
splitting a multipart object detaches the modifier. With the layout baked in
there is nothing to split; the object prints as loaded.

Each plate's modifier shells receive **exactly the same rigid transform**
(rotation + translation, never a mirror) as their plate, so model and modifier
stay aligned part for part. The stencil and mold have no pneumatic features,
so they ship as separate plain STLs — import them as their own objects
whenever you print them.

This is **not** a slicer, G-code post-processor, or `.3mf` writer. A native
`.3mf` that pre-marks the second mesh as a modifier is a possible later step.

## Geometry approach — the modifier envelope

The modifier must overlap the *printed material* around each feature, not sit
inside the empty channel void (the void was removed from the model, so a
void-shaped modifier would barely intersect anything). So it is **regenerated
from the same modeling primitives `PlateBuilder.build` cuts, inflated, and
deliberately NOT subtracted** (`PlateBuilder.buildModifier`, in
`Vacuum PCB/Vacuum PCB/CAD/PlateBuilder.swift`):

- **Channels** — same waypoint polylines, rebuilt as a tube grown to an
  anisotropic capsule: radius `r + marginXY` across, half-height `r + marginZ`
  tall (built round, then Z-scaled about the channel midline so the wall margin
  and the roof/floor margin are honoured independently).
- **Resistors** — one plain box over the serpentine footprint
  (`footprint + marginXY` in XY, `resistorChannelDiameter + 2·marginZ` tall,
  centred on the channel midline). Deliberately *not* the inflated serpentine
  tube: unioning ~dozens of heavily overlapping inflated legs made Euclid's BSP
  emit degenerate faces (missing triangles in Bambu) and bulged past the
  footprint. The box is watertight by construction, tighter, and still covers
  the thin inter-leg walls — the actual print-critical part.
- **Vias & vertical drop bores** — vertical cylinders, radius grown by `marginXY`,
  Z span extended by `marginZ` past each end into the surrounding roof/floor.
- **Transistor valves** — the gate dimple grown radially (`dimpleMesh`, clipped to
  its plate so it can't balloon), plus the source/drain sealing pads grown and
  merged across the seal strip (reduced `sep`) so the whole sealing area is
  covered.
- **Edge port bores** and **LED dimples** — grown radially via the same builders.
- **Testing-point taps** — vertical cylinders grown radially + extended.

All primitive shells are **concatenated** (like the multi-solid model STL and the
3D-preview highlight `volumeMesh`), not CSG-unioned. Overlapping/disconnected
closed shells are fine for a modifier — slicers union them per layer — and
concatenation keeps the export deterministic and cheap. The envelope is allowed
to extend through empty space: Bambu applies modifier settings only where it
overlaps printed material.

## Configurable margins

Defaults live in `PlateBuilder.ModifierMargins.defaults`
(`Vacuum PCB/Vacuum PCB/CAD/PlateBuilder.swift`):

```
modifierMarginXY = 1.0 mm   // wall coverage (radial / cross-section)
modifierMarginZ  = 0.6 mm   // roof + floor coverage (vertical)
```

Retune from the CLI with `--modifier-xy` / `--modifier-z`, or change the defaults
for the GUI.

## Generating the two test files

### CLI (headless — used for the test fixtures)

```sh
# from the repo root
swift build
./.build/debug/vacuum-cli export "Vacuum PCB/Vacuum PCB/Examples/inverter.vpcb" --bambu
# → Examples/inverter_bambu/{inverter_model.stl, inverter_modifier.stl,
#    inverter_stencil.stl, inverter_mold.stl, inverter_bambu_export.json}
```

Options:

```sh
vacuum-cli export <file.vpcb> --bambu \
    [--out DIR]            # destination dir (default: <base>_bambu beside the input)
    [--modifier-xy 1.0]    # wall margin (mm)
    [--modifier-z 0.6]     # roof/floor margin (mm)
    [--no-manifest]        # skip the JSON manifest
    [--json]               # machine-readable report
```

The `inverter.vpcb` example has channels (with bends) and transistor valves. For
a board that also exercises a cross-silicone **via**, use one with a through-hole
route (e.g. a register/latch board under `calibration/`), or the in-code
representative model in `BambuModifierExportTests.representativeDoc()`.

### GUI

Preview/Physical/Simulate toolbar → **Export…**:

- **Export for Bambu Studio…** — pick a location; a `<base>_bambu` folder with both
  STLs (+ manifest) is written.
- **Open in Bambu Studio (with Modifier)** (macOS) — builds the model + modifier to a
  temp dir and opens *both* in Bambu at once, so Bambu offers to load them as one
  object. One click; no file picking. Remember to switch the `_modifier` part to a
  Modifier (see step 5 below) or it prints as solid.
- **Open in Bambu Studio** — model only (no modifier), for a quick clean print.
- **Save STL file…** — the plain single-model export, unchanged.

## Manual acceptance test (do this once against a real slice)

1. Export with **Export for Bambu Studio** (GUI) or `vacuum-cli export … --bambu`.
2. In Bambu Studio, select `<base>_model.stl` **and** `<base>_modifier.stl` at
   once and open them (leave `_stencil` / `_mold` out — import those separately
   when you print them).
3. When asked whether to load them as a single (multipart) object, choose **Yes**.
4. Verify the two plates sit side by side ON the bed (no sandwich, nothing to
   split) and the modifier shells sit over each plate's channels/valves/vias.
5. In the Objects panel, change the `_modifier` part's type to **Modifier**.
6. Give the modifier a visibly different setting (e.g. much lower speed, or a
   different infill/wall count).
7. Slice the plate. Do **not** use "Split objects" — it detaches the modifier.
8. Inspect the speed and feature-type previews.
9. Confirm the changed settings apply **only** around channels, valve areas, vias
   and their surrounding walls — not across the whole part.
10. Confirm the modifier itself is **not** printed as extra solid geometry (it
    only alters settings where it overlaps the model).

## Not yet included in the modifier

- **Connector fluid tubes** and connector/screw structural geometry (structural,
  not print-critical pneumatics).
- The **stencil** (silicone cutting template) and **mold frame** — separate bodies,
  not part of the plate's channel network.
- Assembly-mode documents (the whole Export menu is disabled there, as for the
  normal STL export).

## Assumptions about feature geometry

- Channels are round bores swept along the routed waypoint polyline at the
  layer midline (`channelDiameter`); a via/drop bore is a vertical cylinder at
  `channelDiameter`; a valve is a transistor = gate dimple (`dimpleDiameter`) +
  source/drain pads (`padsDiameter`/`padsSeparation`) on the opposite plate; a
  resistor's serpentine stays inside its fixed 12×4 mm footprint. The modifier
  reuses exactly these primitives and constants, so it tracks any change to
  them.
- A via is only enveloped when its `.via` markers span ≥2 layers (same rule
  `build` uses to actually drill it).
- Subparts are flattened first, so a subpart's internal channels/valves are
  enveloped too.
