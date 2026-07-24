# Print-parameter sweep on one plate

Prints many copies of one coupon, each with different settings, so a single
plate answers "which settings actually seal a channel?" instead of one print per
guess.

Built for the question: **the resistor bore is 0.35 mm and the coupon leaks — can
a wider bore plus more flow seal better while still giving a usable resistor
value?** Bore and flow pull in opposite directions (more flow shrinks the printed
bore, a wider bore lowers resistance), so they have to be swept together.

    columns (X, left -> right)  resistor bore diameter — GEOMETRY
    rows    (Y, front -> back)  filament flow ratio    — G-CODE

The split is forced by where each parameter lives. Bore diameter is part of the
model, so every column is a separately generated mesh. Flow ratio is a
*filament* setting — one value per plate, not per object — so it cannot be swept
in the slicer at all and is stamped onto the sliced G-code afterwards.

## Workflow

```bash
# 1. meshes + plate + cell map  (needs vacuum-cli built: swift build -c release)
python3 build_plate.py --vpcb "L resistor thinner.vpcb" \
                       --template "Resistor test.3mf" --out sweep

# 2. slice it — in Bambu Studio, or headless:
/Applications/BambuStudio.app/Contents/MacOS/BambuStudio \
    --slice 1 --outputdir sweep/sliced sweep/bore_flow_sweep.3mf

# 3. stamp the per-cell flow ratios on
python3 apply_matrix.py --gcode sweep/sliced/plate_1.gcode --map sweep/sweep_map.json

# 4. check it before committing hours of printing to it
python3 verify.py --before sweep/sliced/plate_1.gcode \
                  --after sweep/sliced/plate_1_swept.gcode --map sweep/sweep_map.json
```

`--template` supplies the print/filament/printer settings verbatim: the plate is
rebuilt around them and nothing about the process is changed, so the sweep is
anchored to whatever profile the real boards print with. Its objects are
discarded — only settings are borrowed.

Step 3 also accepts a `.gcode.3mf` sliced file and repacks it (md5 included) so
the plate can still be sent from Bambu Studio or Handy.

## Reading the plate

Sixty identical-looking coupons are indistinguishable the moment they leave the
bed, so `collection_sheet.svg` prints at true scale with one labelled box per
cell — lay each coupon in its box as it comes off. `sweep_map.md` carries the
same table plus empty columns for measured R and leak result.

Row 0 is the **front** of the bed (low Y), column 0 the **left** (low X).

## Two traps worth remembering

**A 3mf's settings are only honoured if it claims to be BambuStudio.** Rewriting
`<metadata name="Application">` in `3D/3dmodel.model` makes Bambu Studio treat
the file as a foreign 3mf and silently slice with default presets — a 0.4 mm
nozzle where the project said 0.2. `build_plate.py` copies the template's
metadata header verbatim for exactly this reason.

**Arc fitting means chord length is not path length.** `enable_arc_fitting` is
on, so most moves are `G2`/`G3` and the chord under-measures the path by up to
~7% on tight arcs. Any mm³/s computed from the chord is inflated by the same
factor, which is enough to "discover" ceiling violations that are not there.
`extruded_length()` integrates the arc properly.

## Why the volumetric clamp is not optional

The slicer enforces `filament_max_volumetric_speed` (2.5 mm³/s here) at slice
time — sparse infill comes out at exactly 2.5, i.e. already on the ceiling.
Scaling E up for a higher flow ratio without touching F would ask for ~2.9 mm³/s
and the printer would simply fail to keep up: silent under-extrusion, in the
cells that were supposed to be *over*-extruding. `apply_matrix.py` re-applies the
ceiling by slowing those moves, which is what the slicer would have done natively.

## Caveats on the experiment itself

* **R ∝ 1/d⁴.** The bore list spans a ~16x resistance range. The R column in the
  map is ideal Poiseuille on the *modelled* bore, from the mesh's own measured
  cross-section (a 0.35 -> 0.50 mm change removes 3.11 mm³ of material, matching
  a circular bore over 31 mm of channel to 0.3%). The printed bore is not the
  modelled one — that is the whole point of printing this.
* **Widening the bore changes the infill, not just the hole.** Across
  0.35 -> 0.70 mm the slicer converts sparse infill into solid infill around the
  channel (5130 -> 1930 sparse moves, 24050 -> 33560 solid). Wider-bore columns
  are therefore denser around the channel, which helps sealing on its own. It is
  a confound, not a bug, but do not attribute all of the column effect to the
  bore.
* **By-layer printing is deliberate.** Each coupon's layer lands on plastic that
  cooled while the head visited the other 59, which matches a coupon printed as
  part of a much larger board — not one printed alone. Fan and nozzle
  temperature cannot be swept this way (spin-up and thermal lag are far slower
  than the per-object dwell); `apply_matrix.py` supports both if the map asks,
  but they need sequential printing.
* **Print time scales with cell count**: ~18.7 min per coupon on the 0.2 nozzle
  / 6-wall / 20 mm/s-outer-wall profile, so 60 cells is ~18h 40m by layer. A
  by-layer plate is also all-or-nothing — a failure at layer 15 of 22 costs every
  cell. Trimming the flow rows is the cheapest way to cut both.
