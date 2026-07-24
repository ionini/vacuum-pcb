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

Every coupon carries its own `bore x flow` label embossed 0.3 mm proud on its top
face (`vacuum-cli export --label`), so a part still says what it is after it
leaves the bed. That makes each *cell* a distinct mesh: a 4 x 6 plate is 24
objects, not 4 objects with 6 instances. The label sits ~1.25 mm above the
channel roof and the top face has no bore mouths, so it is not in a sealing path.

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

Each coupon is self-identifying, so nothing has to be tracked by position.
`sweep_map.md` lists every cell with its label and empty columns for measured R
and leak result; `collection_sheet.svg` prints at true scale as a plate map, handy
for sorting parts but no longer required.

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

## The volumetric ceiling, and why the sweep does *not* fight it

`filament_max_volumetric_speed` (2.5 mm³/s here) binds already: sparse infill
leaves the slicer sitting exactly on it. But measure the filament actually
commanded and it comes to 2.525 mm³/s — precisely 2.5 × 1.01. **Bambu applies the
ceiling to the geometric extrusion rate, before the flow-ratio multiplier**, so
the real limit on the E in the file is `limit × flow_ratio`.

That is why a pure flow-ratio change gets no clamping here. A native re-slice at
flow 1.06 would not slow down either, so clamping would make the plate print
*unlike* the thing it is supposed to predict — and the point of the sweep is that
the winning number can be typed straight into the filament profile. The clamp
still binds if the map sweeps speed, which is the case the slicer really would
have slowed. Getting this backwards costs ~11 000 needlessly slowed moves per
plate and a sweep whose fast rows do not match production.

## Caveats on the experiment itself

* **R ∝ 1/d⁴.** The map quotes each column's resistance against the source
  board's own bore, as ideal Poiseuille on the *modelled* geometry. That model is
  trustworthy for the mesh: the volume a bore removes matches a circular channel
  over 31.0 mm to 0.3% (0.35 -> 0.50 mm removes 3.11 mm³ vs 3.10 predicted). The
  printed bore is not the modelled one — that is the whole point of printing this.
* **Widening the bore changes the infill, not just the hole.** Over a wide bore
  range the slicer converts sparse infill into solid around the channel (measured
  across 0.35 -> 0.70 mm: 5130 -> 1930 sparse moves, 24050 -> 33560 solid).
  Wider-bore columns are therefore denser around the channel, which helps sealing
  on its own. A confound, not a bug — but do not attribute all of the column
  effect to the bore.
* **By-layer printing is deliberate.** Each coupon's layer lands on plastic that
  cooled while the head visited the other 59, which matches a coupon printed as
  part of a much larger board — not one printed alone. Fan and nozzle
  temperature cannot be swept this way (spin-up and thermal lag are far slower
  than the per-object dwell); `apply_matrix.py` supports both if the map asks,
  but they need sequential printing.
* **Print time scales with cell count**: ~18.5 min per coupon on the 0.2 nozzle
  / 6-wall / 20 mm/s-outer-wall profile — 24 cells is 7h 26m, 60 cells 18h 42m. A
  by-layer plate is also all-or-nothing: a failure near the top layer costs every
  cell. Trimming the flow rows is the cheapest way to cut both.
