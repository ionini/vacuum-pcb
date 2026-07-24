# Print-parameter sweeps, and what Bambu Studio actually does

Boards leak at the walls, and the settings that fix that are not derivable — they
have to be printed. A sweep puts many copies of one coupon on a single plate, each
with different settings, so one print answers the question instead of one print per
guess.

The rig lives in [`calibration/print_sweep/`](calibration/print_sweep/README.md) —
that README is the usage guide. This document records the **slicer behaviour** the
rig had to be built around, because most of it is invisible until it has already
cost you a print, and none of it is specific to sweeps.

The first sweep (24 coupons, resistor bore 0.30–0.45 mm × flow ratio 1.01–1.06,
7h 26m on an A1 mini with a 0.2 nozzle) is the worked example throughout.

## Flow ratio *is* a per-object setting

`print_flow_ratio` — "Object flow ratio" in the UI — multiplies the filament's
flow ratio for one object only. Set it per object in `model_settings.config`:

```xml
<object id="6">
  <metadata key="name" value="b0.35-f1.04"/>
  <metadata key="extruder" value="1"/>
  <metadata key="print_flow_ratio" value="1.029703"/>   <!-- 1.04 / 1.01 -->
```

It is a *process* key, not a filament one, which is why it can be overridden per
object at all; `filament_flow_ratio` cannot. Measured: filament per cell steps
1.000 / 1.010 / 1.020 / 1.030 / 1.040 / 1.050 across six rows, matching G-code
post-processing to 0.001.

This matters beyond convenience. A sweep expressed in the 3mf survives re-slicing;
a sweep stamped onto G-code does not (below). **Check for a per-object option
before reaching for post-processing.** Flow ratio is the only one of interest here
— speed and fan have no per-object form, so sweeping those still means
post-processing, with everything that follows.

## Bambu Studio re-slices a sliced project and silently discards a G-code stamp

A `.gcode.3mf` carries the models *and* the sliced G-code, so Studio can
regenerate from the model — and it does. Measured: a `.gcode` exported from Studio
after opening a post-processed `READY.gcode.3mf` came back flat, every row
extruding 227.2 mm where the rows should have spanned +5%, row 0 matching the
un-stamped baseline exactly.

There is no warning, and the plate is geometrically identical either way, so the
failure only shows up as a bench result that says "nothing mattered". Any
post-processed payload must reach the printer without passing back through the
slicer: microSD, or FTPS upload (port 990, user `bblp`, password = the printer's
Access Code, LAN Mode on), then start it from the printer's screen. Neither
prompts for filament mapping, so the right spool has to be loaded.
`calibration/print_sweep/check_sweep.py` proves from a file alone whether the
sweep is still in it.

## A 3mf's embedded settings are honoured only if it claims to be BambuStudio

Rewrite `<metadata name="Application">` in `3D/3dmodel.model` and Studio treats
the file as a foreign 3mf, silently slicing with whatever presets are default —
observed: a 0.4 mm nozzle and 0.2 mm layers where the project said 0.2 and 0.14.
Authoring a plate around an existing project's settings therefore means copying
that metadata header verbatim.

## `max_volumetric_speed` is measured before the flow-ratio multiplier

The ceiling (2.5 mm³/s here) binds already: sparse infill leaves the slicer
sitting exactly on it. But the filament it *commands* comes to 2.525 mm³/s —
precisely 2.5 × 1.01. The limit applies to the geometric extrusion rate, so the
real ceiling on the E in the file is `limit × flow_ratio`.

Consequence for any tool that rewrites E: raising flow needs no compensating
slowdown, because a native slice at the higher flow ratio would not slow down
either. Clamping anyway makes the plate print unlike the thing it is meant to
predict. Raising *speed* does need the clamp — that is the case the slicer really
would have slowed.

## Arc fitting means chord length is not path length

`enable_arc_fitting` is on by default, so most moves are `G2`/`G3`. Their chord
under-measures the path by up to ~7% on tight arcs (measured: r = 0.831 mm, chord
0.9 mm → arc/chord = 1.057). Any mm³/s computed from the chord is inflated by the
same factor — enough to "discover" 20 057 volumetric-ceiling violations in an
untouched slice. Integrate the arc from `I`/`J` instead.

## CLI quirks (`BambuStudio --slice`)

- It **ignores `gcode_label_objects`**, so a headless slice has no
  `; printing object …` fences. Identify objects by move coordinates instead; the
  comments are a cross-check when present, not a dependency.
- It leaves **`printer_model_id` empty** in `slice_info.config` where a GUI export
  writes e.g. `N1`. Bambu Studio then refuses to send the job with *"Not all
  filaments used in slicing are mapped to the printer"*. Look the id up by printer
  name in the installed profiles (`…/Resources/profiles/*/machine/*.json`,
  `type: machine_model` → `model_id`) rather than hardcoding it.
- `--export-3mf` wants a **bare filename**. Combined with `--outputdir`, an
  absolute path gets concatenated and the export fails.
- Settings come from the 3mf itself, so a project 3mf slices with its own presets
  and needs no `--load-settings`.

## Geometry notes that fall out of the sweep

- **A resistor's bore is geometrically clean.** The volume a bore removes matches
  an ideal circular channel to 0.3% (0.35 → 0.50 mm removes 3.11 mm³ vs 3.10
  predicted over 31.0 mm of channel, for size L). So R ∝ 1/d⁴ is a sound
  first-order guide when choosing a bore — though the printed bore is not the
  modelled one, which is the point of printing the sweep.
- **Widening a bore changes the infill, not just the hole.** Across 0.35 → 0.70 mm
  the slicer converts sparse infill into solid around the channel (5130 → 1930
  sparse moves, 24050 → 33560 solid) at near-constant filament per part. Wider
  bores are therefore denser around the channel, which aids sealing on its own —
  a confound when reading a bore axis.
- **An embossed label is not in a sealing path**, for this coupon: the channel
  void sits at z 1.40–1.80 in a plate spanning 0.05–3.05, so a 0.3 mm emboss lands
  ~1.25 mm above the channel roof, and neither the top nor the bottom face carries
  a bore mouth (the ports exit through the edges). Worth re-checking for any
  geometry where a channel runs nearer a face.
- **`Mesh.text` (Euclid) centres its extrusion on z = 0**, it does not extrude +Z.
  Align embossed text by the glyphs' measured bounds; assuming otherwise yields
  half the requested emboss with the other half buried.

## Print-time arithmetic

~18.5 min per 25 × 8 × 3 mm coupon on the 0.2 nozzle / 6-wall / 20 mm/s-outer-wall
profile. 24 cells is 7h 26m, 60 cells 18h 42m. A by-layer plate is also
all-or-nothing: a failure near the top layer costs every cell. Trimming rows is
the cheapest way to cut both.

By-layer is nonetheless the right choice when the coupon normally prints as part
of a much larger board — each layer lands on plastic that cooled while the head
visited the other cells, which is the realistic case. It does rule out fan and
temperature as axes, since spin-up and thermal lag are slower than the per-object
dwell; those need sequential printing.
