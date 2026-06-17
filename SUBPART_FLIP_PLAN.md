# Subpart flip — design spec (follow-up, not yet implemented)

## Why

The transistor-orientation optimizer (`OrientationOptimizer`, run by Minimize)
flips bare transistors to cut cross-silicone vias. It is **scoped to top-level
`.transistor` components** because a subpart instance's boundary pins are pinned
to the library plate via `absoluteLayer` (`Footprint.subpartFootprint`), so
toggling a subpart's `Placement.layer` does not move its pins.

That means the lever doesn't reach the vias that dominate subpart-assembled
boards — the inter-block crossings between latches/gates. Measured headlessly
with `vacuum-cli minimize --json`, real assembled boards carry these:

| Board | top-level cross-silicone vias |
|---|---|
| `4bit register with bus 2` | 13 |
| `XOR` | 2 |
| `SR Latch` | 1 |

The via-penalty in the SA cost already trims some by rerouting (XOR `2→1`), but it
cannot move a subpart's pins to the other plate. Cutting those vias structurally
requires **flipping whole subpart instances** — mirroring the block across the
silicone so its boundary pins swap plates. This is a larger change because a
subpart is a real two-plate sandwich, so "flip" means physically mirroring its
internal geometry, not just relabeling a plate.

## What flipping a subpart means

A subpart instance flipped across the silicone plane:
- every boundary pin's plate inverts (`top ↔ bottom`), depth re-mapped against the
  destination plate's layer count;
- its internal channels/dimples/bores/vias are reflected through the membrane
  plane, so the printed block is the mirror of the library part;
- its own internal cross-silicone vias are unchanged in count (mirroring is a
  rigid reflection), but the parent-side nets that reach its pins can now land
  same-plate.

Manufacturability gate: the mirrored block must be printable. For flatten-routed
assemblies (top-level routes over co-placed subparts) this means the CAD must emit
the subpart's solids reflected. For socket-mated assemblies (each subpart prints
separately, joined at connectors) a flip is a per-block fabrication choice and may
be cheaper to support.

## Changes required

1. **Placement flag.** Add `var flipped: Bool = false` to `Placement`
   (`PhysicalLayout.swift`), Codable with default-false back-compat (mirror the
   `depth` decode). Only meaningful for `.subpart` (and, redundantly, transistors
   — where it would equal toggling `layer`).

2. **Boundary-pin plate inversion.** In `Placement.resolvedPlate` /
   `resolvedLayer` (`Footprint.swift`), when the owning instance is a flipped
   subpart, return `absolute.plate.opposite` and mirror `absolute.depth` against
   `layerCount(for:)` of the destination plate. Today `absoluteLayer` wins
   unconditionally — this is the core behavioral change and everything else
   follows from it.

3. **Mirrored-subpart geometry (the bulk of the work).** `PlateBuilder` / the CAD
   pipeline must reflect a flipped subpart's emitted solids — channels, dimples,
   pads, drop bores, cross-silicone vias — across `z = 0`. This is where the
   complexity and risk live (CSG, watertightness, DRC depth-reach).

4. **Apply the same mirror to every consumer of subpart internals:**
   simulation-flatten (`CircuitDocument.flattened`), continuity, volumes, and STL
   export. The flattened netlist and the printed geometry must agree with the
   inverted boundary, or sim/DRC will disagree with the board.

5. **Generalize the optimizer.** `OrientationOptimizer` currently treats only
   `.transistor` as flippable nodes. Generalize "flippable instance" to include
   subparts: a subpart contributes *all its boundary pins inverting together* to
   the cut objective (one flip bit per instance), and — if the goal is total via
   count rather than just boundary crossings — also account for the block's
   internal crossing count (read from the snapshot; rigid under a flip, so it's a
   constant per instance and can be ignored for the boundary-cut objective).
   The existing `fixedMask` / `netTransistorPins` model extends directly: a
   flipped subpart pin flips its mask bit.

6. **UI.** Extend `PhysicalActions.flipLayer` to toggle `flipped` for subparts
   with a distinct affordance/glyph (it's a heavier operation than a transistor
   flip — it mirrors a block), and show flipped subparts mirrored on the canvas.

## Risk / sequencing

Steps 1–2 and 5 are mechanical and low-risk (data + objective). Steps 3–4 are the
real work and the gating risk: the CAD must produce a correct mirrored solid and
every internals-consumer must mirror identically. Recommend implementing 3–4
behind the `flipped` flag with thorough STL/sim parity tests on a single mirrored
leaf cell *before* wiring subparts into the optimizer (step 5), so the optimizer
never produces a block the CAD can't print.

The transistor-level optimizer already in place is independent of this and needs
no changes when subpart flipping lands — it simply becomes the `subpart == false`
case of the generalized node set.
