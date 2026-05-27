# Connector Primitive — V1 Design Plan

A new schematic primitive that adds a mating interface (a protrusion of tubes + screws) to the edge of a top-level design's plate stack. Two designs designed with matching connectors can be physically clamped together by the user; the app does not enforce mating in V1.

## Scope (V1)

- New primitive: **connector**. Lives on the edge of the top-level design's plate.
- Each `.vpcb` still produces exactly **one plate stack** (2 plates + 1 silicone). Connectors only add edge protrusions to `boardOutline`.
- **Subparts cannot contain connectors.** Import is blocked with a clear error.
- **No in-app mating logic**: no auto-net-merge, no schematic snap-to-mate, no physical position locking between mated components. Two halves of a real-world coupling are designed as two separate `.vpcb` files; the human pairs them by eye.

## Physical topology (the thing being modeled)

Mating is **asymmetric**:
- One side (role `.bottomExtend`): bottom plate **and silicone** extend out as a protrusion. Tubes go up through the silicone, exposed at the top of the silicone (no top plate there).
- Other side (role `.topExtend`): only the top plate extends. Tubes go down through the top plate, exposed at its underside.
- When mated by hand: bottom-extend's silicone is clamped between bottom-extend's bottom plate (below) and top-extend's top plate (above). Tubes align face-to-face through the silicone gasket.
- Two end-cap screws clamp the sandwich.

Two designs that should mate share pin count but have opposite roles. Pairing is the user's responsibility outside the app.

## Data model changes

### `LogicGraph.swift`

- Add `ComponentKind.connector`.
- Add to `Component`:
  - `connectorPinCount: Int?` (per-instance, like `resistorSize`).
  - `connectorRole: ConnectorRole?`.
- New enum `ConnectorRole`:
  - `.bottomExtend` — bottom plate + silicone extend; tubes exposed up through silicone.
  - `.topExtend` — top plate extends; tubes exposed down through top plate.

### `PhysicalLayout.swift`

- Add `edgeAnchor: EdgeAnchor?` (optional) to `Placement`. Only set for connector placements.
- New struct `EdgeAnchor { edge: Edge, offsetAlongEdge: Double }`.
- New enum `Edge { north, south, east, west }`.
- For connector placements, `position` and `rotation` are **derived** from `edgeAnchor` + `boardOutline` (not stored independently).

### `Footprint.swift`

- Extend `ComponentKind.footprint(...)` to accept pin count and role for the connector kind. Returns a dynamically generated footprint:
  - N tube pins at grid-pitch spacing along the edge axis.
  - 2 end-cap screw pins, one beyond the first tube and one beyond the last.
  - Pin layer derived from role:
    - `.bottomExtend` → bottom plate (depth 0).
    - `.topExtend` → top plate (depth 0).

### `CircuitDocument.swift`

- Bump `currentSchemaVersion` from 3 → 4. Migration is a no-op for existing documents (no pre-existing connectors).
- `flattened()`: scan each subpart's library snapshot for any `Component.kind == .connector`. If found, return a typed error that the import UI surfaces.

## Geometry & manufacturing — reuse existing constants

No new user-facing dimension knobs. All values come from `ManufacturingConstants.swift`:

- **Tube diameter** = existing via diameter.
- **Pin pitch along edge** = existing grid pitch.
- **Protrusion depth** (perpendicular to edge) = derived (silicone thickness + screw shaft length + margin). Single computed value, not per-instance.
- **Connector width margin** beyond end-cap screws = baked constant, 0.5 × pin-pitch on each side.
- **Silicone extension** (`.bottomExtend` only) = flush with the protrusion's outer edge.
- **Screws**: 2 end caps only. No intermediates regardless of pin count. Existing `ScrewGeometry.swift` volcano-dome geometry (M2-class).

**Per-instance parameters are only**: pin count, role, edge, offset along edge.

Slot layout along the edge for an N-pin connector: `[S] [tube × N] [S]` — N+2 slots, the 2 outer ones are end-cap screws.

## Schematic view

- Connector renders as a free-floating element, like `port`. **No plate-edge concept in the schematic.**
- Visual: a stylized rectangle with N pin labels on one side (the "inward" routing side); the opposite side is decorative (the would-be outward face).
- Role is indicated visually (TBD — e.g., text label or hatch direction).
- Routes attach to the pin row like any other primitive's footprint pins.

## Physical view

- Connector placements are constrained to one of 4 plate edges (N/S/E/W).
- **Drag along the edge**: dragging updates `edgeAnchor.offsetAlongEdge`; snaps to the existing grid pitch (same snap as other placements).
- **Drag to a different edge**: drag past an edge boundary re-anchors to the nearest edge and updates `EdgeAnchor.edge`.
- **Corners disallowed**: a connector needs ≥ 1 pin-pitch clearance from each adjacent corner. DRC enforced.
- **One connector per edge in V1.** DRC enforced.
- **Rotation is derived from edge** — the connector always points outward perpendicular to its edge. No independent rotation control.

## CAD pipeline (`PlateBuilder.swift`)

For each connector placement:
1. Read `edgeAnchor` (edge + offset).
2. Compute the rectangular protrusion footprint based on pin count and edge orientation.
3. Extend `boardOutline` geometry on the specified edge with this protrusion:
   - `.bottomExtend` role → extend bottom plate **and** silicone outline.
   - `.topExtend` role → extend top plate outline only.
4. Place tubes (vias) at the N pin positions inside the protrusion. Existing via geometry; the existing silicone stencil punch logic already exposes them.
5. Place 2 end-cap screws using existing `ScrewGeometry.swift`.

The silicone stencil already punches at via positions; no special handling needed for the exposed-tube case beyond extending the stencil outline with the protrusion shape.

## Inspector strip

- **Pin count**: stepper, min 1.
- **Role**: 2-segment picker (`.bottomExtend` / `.topExtend`) with labels like "Carries silicone" / "Mates with silicone".
- **Edge + offset**: shown in the physical-view inspector; offset editable; edge changes by dragging across.

Mirrors the existing `resistorSize` (picker) and `portDirection` (toggle) controls in `InspectorStrip.swift`.

## DRC

- Pin count ≥ 1.
- Corner clearance ≥ 1 pin-pitch from each adjacent corner.
- No two connectors on the same edge.
- Edge length ≥ (N + 2) × pin-pitch + 2 × width-margin.

## Persistence / migration

- Schema version 3 → 4.
- New JSON fields: `connectorPinCount`, `connectorRole` on `Component`; `edgeAnchor` on `Placement`.
- New `ComponentKind` case `connector` in encoded form.
- Existing v3 documents migrate cleanly (no connectors present).

## Subpart imports

`CircuitDocument.flattened()` returns a typed error if any imported library snapshot contains a `connector` component. The import UI surfaces the error as a clear blocking message ("This part contains connectors and cannot be used as a subpart yet").

## Files to touch (implementor's checklist)

- `Vacuum PCB/Vacuum PCB/Model/LogicGraph.swift` — `ComponentKind.connector`, `ConnectorRole`, fields on `Component`.
- `Vacuum PCB/Vacuum PCB/Model/Footprint.swift` — dynamic footprint generation for connector kind.
- `Vacuum PCB/Vacuum PCB/Model/Geometry.swift` — `Edge` enum.
- `Vacuum PCB/Vacuum PCB/Model/PhysicalLayout.swift` — `EdgeAnchor`, `Placement.edgeAnchor`.
- `Vacuum PCB/Vacuum PCB/Model/CircuitDocument.swift` — schema v4 bump + migration + flatten-time check.
- `Vacuum PCB/Vacuum PCB/CAD/PlateBuilder.swift` — protrusion extension, tube placement, end-cap screws.
- `Vacuum PCB/Vacuum PCB/UI/Schematic/InspectorStrip.swift` — pin count stepper, role picker.
- `Vacuum PCB/Vacuum PCB/UI/Schematic/ComponentPaletteView.swift` — connector palette entry.
- `Vacuum PCB/Vacuum PCB/UI/Schematic/SchematicCanvasView.swift` — connector symbol rendering.
- `Vacuum PCB/Vacuum PCB/UI/Physical/PhysicalCanvasView.swift` — edge-constrained drag for connector placements.

## Out of V1 (future)

- In-app connector-to-connector mating: schematic snap, auto-net-merge, DRC for mate compatibility.
- Physical position locking between mated components (one drags, the other follows).
- Subparts containing connectors → multi-assembly output (the original Q1 option (a) deferred).
- Intermediate screws on long connectors (the original Q4 option (b)/(c)).
- User-configurable dimensions per connector.
- Multiple connectors per edge.
- Custom pin labels.

## Locked design decisions (from grilling)

| # | Decision | Choice |
|---|---|---|
| Q1 | Multi-assembly output for mated subparts? | **No — V1 has one plate stack per `.vpcb`.** Connectors are edge features on top-level designs only. |
| Q2 | How is the connector's role set? | **(a) Per-instance, explicit field on `Component`.** Like `portDirection`. |
| Q3 | Plate-edge concept in the schematic? | **None.** Schematic is free-floating, like `port`. Edge constraint is physical-only. |
| Q4 | Screw placement and spacing? | **(a) Two end-cap screws only.** No intermediates in V1. |
| Q5 | How is edge position stored? | **(a) Optional `edgeAnchor` on `Placement`.** All 4 edges allowed, corners disallowed, rotation derived, one connector per edge. |
| Q6 | New manufacturing constants? | **None.** Reuse via diameter, grid pitch, silicone thickness, existing screw hardware. Per-instance params: pin count, role, edge anchor. |
| Q7 | Subpart import of connector-having `.vpcb`? | **(a) Block with a typed error at flatten time.** |
