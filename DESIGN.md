# Vacuum PCB — Design Notes

A working journal of the project's design decisions, architectural rationale,
and known open questions. See `README.md` for the user-facing pitch and
workflow.

This document is for engineering context: *why* the code is shaped the way it
is. Update it when decisions change.

---

## Scope assumptions

- **Personal hobby tool**, single user, local-first.
- Data model is kept clean enough to open up later, but no plugins, no web,
  no multi-user, no accounts. Manufacturing constants live in the document
  and are tuned for one printer / one silicone sheet / one needle gauge.

---

## Logic ↔ Physical binding

KiCad-style **pure layout** projection.

- **Logic view** owns the netlist (which components exist, which terminals
  share which net). It's the source of truth.
- **Physical view** owns placements + routes. It's a *projection* —
  placement and routing can change freely, but you cannot add/remove
  components or change connectivity from the physical view.
- Unplaced components live in a "parking lot" sidebar.
- **DRC** runs continuously against the document: unrouted nets,
  minimum-spacing violations between routes on the same layer, layer
  mismatches at pins. Errors are computed from the document, not stored.
- **Export STL** is gated on a clean DRC.

Why this regime (vs bidirectional): the bidirectional approach has
unsolvable ambiguities (e.g., "draw a tube touching three components — does
that merge three nets?"). The strict-projection model is mechanical and
unambiguous.

---

## Tech stack

- **Swift + SwiftUI** — app shell, schematic / physical editors, document
  persistence, 3D preview. macOS-only (single user, hobby scope).
- **[Euclid](https://github.com/nicklockwood/Euclid)** — pure-Swift mesh
  CSG library (MIT), embedded as a SwiftPM dependency. After every CSG
  operation we call `makeWatertight()` to heal hairline cracks at
  curved/flat surface intersections, since slicers reject non-manifold
  STLs.
- **SceneKit** for the in-app 3D preview (Euclid bridges to `SCNGeometry`
  natively).
- **Codable JSON** for document storage. One `.vpcb` file per design.
  Pretty-printed with sorted keys → deterministic, diff-friendly.
- Custom UTI `com.ionini.vacuum-pcb`, declared programmatically (not in
  Info.plist) — works in the app's pickers; Finder doesn't recognize the
  type system-wide, which is fine for MVP.
- **SwiftLint** as a build phase. Config at the repo root. Sandboxing is
  disabled for the script phase so it can read the config one level above
  `SRCROOT`.

Build: standard Xcode project with `PBXFileSystemSynchronizedRootGroup`, so
new files dropped into the source folder are auto-picked-up — no
`.pbxproj` edits needed for source.

App sandbox is on (`ENABLE_APP_SANDBOX = YES`) with
`com.apple.security.files.user-selected.read-write` granted so the STL save
panel works.

---

## Manufacturing constants

Defaults in `ManufacturingConstants.defaults`. Tuned after the
XOR-with-LED test print. Per-document; a printed plate is bound to the
parameters it was generated for.

| Field                     | Default   | Notes |
| ------------------------- | --------- | --- |
| `plateThickness`          | 3.0 mm    | |
| `channelDiameter`         | 1.5 mm    | Reused for source/drain/gate drop bores (one number to print-validate). |
| `portBoreDiameter`        | 1.7 mm    | Sized for a 17-gauge blunt needle press-fit. Adjustable per-document; bore can taper from this diameter outward via `portBoreTaperDegrees`. |
| `siliconeThickness`       | 0.1 mm    | Code default only — the sheet actually on hand is 0.5 mm; set per-document. |
| `dimpleDiameter`          | 5.0 mm    | Dome cavity depth is `dimpleDiameter/2 + dimpleSphereOffset`. |
| `dimpleDepth`             | 1.0 mm    | Legacy flat-cylinder depth; kept for codable compatibility, unused by the dome geometry. |
| `dimpleSphereOffset`      | 1.0 mm    | |
| `gridPitch`               | 1.0 mm    | |
| `minChannelSpacing`       | 1.5 mm    | Centerline-to-centerline comfort spacing: auto-router keep-out halo and the sim's channel-proximity window. *Not* a DRC limit. |
| `minWallThickness`        | 0.5 mm    | The DRC-enforced wall limit — edge-to-edge (diameter-aware), channel vs. any nearby feature. |
| `resistorChannelDiameter` | 0.6 mm    | Serpentine orifice bore; S/M/L change zigzag count, not width. |

The physical layout also stores `topLayers` / `bottomLayers` (number of
stacked channel layers per plate, default 1 each) and per-placement
`depth` — set to `0` for the silicone-facing layer, higher to nest
outward into the plate.

---

## Data model (one `Codable` tree per `.vpcb` file)

```
CircuitDocument
├── schemaVersion: Int                      (current: 2)
├── manufacturing: ManufacturingConstants
├── logic: LogicGraph
│   ├── components: [Component]             // id, kind, label, resistorSize?,
│   │                                       //   portDirection?, partRef?
│   └── nets: [Net]                         // id, label, pins: [PinRef]
├── schematic: SchematicLayout
│   └── positions: [UUID: Point]            // schematic-side XY
└── physical: PhysicalLayout
    ├── placements: [Placement]             // componentId, position, rotation,
    │                                       //   layer, depth
    ├── routes: [Route]                     // netId, segments
    ├── boardOutline: Rect
    ├── topLayers / bottomLayers: Int
```

Invariants:
- All ids are `UUID`. Stable across renames.
- Pin keys are strings statically published by each `ComponentKind` (no
  enum per kind — cheap forward-compat). Sub-part instances use the
  library file's boundary-pin UUIDs as their pin keys.
- Coordinates are floats in millimeters.
- Routes may be partial; DRC reports unrouted nets.
- No derived state in the document (DRC errors, ratsnest lines, the
  flattened CAD doc are all computed on demand).
- `Waypoint.kind` includes a `via` case — a via at that XY subtracts a
  cylinder through both plates and the silicone region, allowing the
  route to switch plates.
- `Placement.layer` is which plate the component's primary features
  (dimple for transistor, bore for port-likes, serpentine for resistor)
  live on. Pin layers are derived: each `FootprintPin` declares its layer
  as `same` or `opposite` relative to the placement layer.

### Schema migrations

`schemaVersion` is bumped when on-disk format changes. Each migration
runs at decode time in `CircuitDocument.migrateInPlace(_:)` and is
designed to keep world geometry identical to what was written.

- **v1 → v2**: sub-part `Placement.position` previously stored the
  library outline's *centre* in parent-world; v2 stores its *top-left
  corner*. Shifts each sub-part placement by the rotated half-extent so
  pins stay where they were on screen.

---

## Sub-parts (reusable circuits)

A `.vpcb` dropped into the user's Parts folder becomes a library part
indexed by filename. `PartsLibrary.shared` rescans the folder at launch
and via `Library → Reload`.

- **Boundary pins** are computed from each library file's `port` /
  `vacuumSource` / `atmVent` components. Their schematic positions
  project onto the nearest edge of the schematic bbox to assign
  left/right/top/bottom sides; physical anchor comes from the matching
  `Placement`. Rails are exposed as pins (rather than auto-merged by
  name) so the parent wires its own VAC/VENT explicitly.
- **Library lookup is by filename**: renaming a library file breaks
  every parent that references it, by design. Filename-only refs match
  the v1 reference-model decision (no internal UUID inside library
  files).
- **Nested sub-parts are supported.** A library file may itself contain
  `.subpart` instances; `CircuitDocument.flattened()` recurses through
  the tree, pre-flattening each child in its own coordinate frame and
  then translating into the parent's. Rotation composes one level at a
  time (so the existing 2-arg `composeRotation` is still sufficient).
- **Reference cycles** between library files (A → B → A) are tolerated
  at load and broken at use site: `flattened(visiting:)` and
  `SubpartExpandedView` carry a `Set<String>` of filenames already on
  the expansion stack, and a hit renders as a red "Cycle: A → B → A"
  placeholder (same affordance as the missing-part placeholder).
- **Missing parts** (library file deleted or renamed) render as a red
  "Missing: X.vpcb" placeholder and are silently dropped from the
  flattened CAD doc.

DRC, Ratsnest, schematic-side rendering, and the parking lot all treat
sub-parts as black boxes regardless of nesting depth — they only see the
parent file's components and the sub-part's boundary pins. Only
`flattened()` (and therefore PlateBuilder + SimulatorExporter) and
`SubpartExpandedView` recurse.

---

## CAD pipeline

`PlateBuilder.build(_:)` consumes a flattened document and returns one
`Mesh` per plate plus a merged-CSG result for the 3D preview.

Per kind, the cutter mesh subtracted from the relevant plate is:
- **Transistor**: dimple dome on `placement.layer`, two source/drain
  drop bores through to the silicone face on the opposite plate, gate
  drop bore on the placement plate side.
- **Resistor**: serpentine channel between the two pins, generated by
  `ResistorGeometry`.
- **Port / VAC / VENT**: edge-entry horizontal cylindrical bore at the
  channel midline, exiting via the rotation-implied edge.
- **Screw**: countersink head cavity on the top plate, clearance bore
  through, hex-nut pocket underneath. See `ScrewGeometry`.
- **LED**: dimple on `placement.layer` plus a wider viewing hole through
  the opposite plate.
- **Via**: vertical cylinder spanning between the two twins of the
  via-waypoint, cutting whichever plate(s) it passes through.

Routes are extruded as channel-diameter cylinders along the polyline.
After all cutters are subtracted, each plate mesh gets a
`makeWatertight()` pass so slicers accept it.

`SimulatorExporter` shares the same flattened-doc input and emits a
simpler graph format for the (future) boolean-logic simulator.

---

## Open questions / known gaps

- **Physical validation cadence.** Manufacturing constants are now tuned
  for the XOR-with-LED print; need more print cycles to confirm
  channel/dimple/wall thicknesses behave as expected with the current
  silicone sheet.
- **Resistor pneumatic behavior.** S/M/L serpentine lengths are arbitrary
  — they create *some* flow restriction but actual resistance values
  haven't been measured. For a functional inverter we just need
  R1 > R_transistor_on; real values will matter for multi-stage circuits.
- **Through-via physical mechanism.** Vias cut the silicone around the
  perimeter, leaving a hole that the silicone seals around. Manufacturing
  tolerance there hasn't been print-tested.
- **PMOS-equivalent / normally-closed transistors.** Required for
  CMOS-style logic with low static draw; without it, every gate leaks
  vacuum through pull-ups.
- **File format for sharing.** The custom UTI works for the user's own
  files. Publishing example circuits would require either an Info.plist
  UTI declaration so Finder recognizes `.vpcb`, or a fallback to `.json`.
- **Schematic-side layout source.** Schematic XY positions live in the
  document. We may want a "graph layout" mode that recomputes positions
  on demand, but the stored fallback stays useful for hand-tuned layouts.

---

## Where things live in the repo

```
Vacuum PCB/
├── Vacuum PCB.xcodeproj/
└── Vacuum PCB/                          ← synchronized source root
    ├── Vacuum_PCBApp.swift              ← @main, DocumentGroup, Library menu
    ├── Model/                           ← pure-value Codable schema + logic
    │   ├── Geometry.swift               (Point, Rect, Size, Rotation, Layer)
    │   ├── LogicGraph.swift             (Component, PinRef, Net, ComponentKind…)
    │   ├── SchematicLayout.swift
    │   ├── PhysicalLayout.swift         (Placement, Route, Segment, Waypoint…)
    │   ├── ManufacturingConstants.swift
    │   ├── Footprint.swift              (per-kind pin offsets + exclusion zones)
    │   ├── ResistorGeometry.swift       (serpentine polyline generator)
    │   ├── CircuitDocument.swift        (top-level + Codable + flatten + migration)
    │   ├── PartsLibrary.swift           (library scan, boundary-pin computation)
    │   ├── DRC.swift                    (continuity + spacing + layer checks)
    │   ├── Ratsnest.swift               (unrouted-net visualization)
    │   ├── AutoPlacer.swift             (force-directed placement)
    │   └── AutoRouter.swift             (Kruskal-MST + per-pair A* routing)
    ├── Document/
    │   └── VPCBDocument.swift           (SwiftUI FileDocument + UTType.vacuumPCB)
    ├── Examples/
    │   ├── Examples.swift               (Examples.inverter() — source of truth)
    │   └── inverter.vpcb                (bundled example)
    ├── CAD/
    │   ├── PlateBuilder.swift           (CSG pipeline → per-plate meshes)
    │   ├── ScrewGeometry.swift          (countersink + hex-pocket cutter)
    │   ├── SimulatorExporter.swift      (flattened-doc → boolean-sim graph)
    │   └── STLExportDocument.swift      (.fileExporter target)
    ├── UI/
    │   ├── DocumentView.swift           (tabs, sidebar, Export)
    │   ├── Scene3DView.swift            (SCNView wrapper)
    │   ├── KeyEventCatcher.swift
    │   ├── ScrollEventCatcher.swift
    │   ├── ZoomToolbar.swift
    │   ├── SchematicSelection.swift
    │   ├── Schematic/                   (schematic editor)
    │   │   ├── SchematicView.swift
    │   │   ├── SchematicCanvasView.swift
    │   │   ├── ComponentPaletteView.swift
    │   │   ├── ComponentNodeView.swift
    │   │   ├── ComponentSymbol.swift
    │   │   ├── PinHandle.swift
    │   │   ├── NetEdgeBuilder.swift
    │   │   ├── NetLinesView.swift
    │   │   └── InspectorStrip.swift
    │   ├── Physical/                    (physical editor + 2D preview)
    │   │   ├── PhysicalView.swift
    │   │   ├── PhysicalCanvasView.swift
    │   │   ├── CanvasTransform.swift
    │   │   ├── PhysicalSelection.swift
    │   │   ├── PlacementBodyView.swift
    │   │   ├── ParkingLotView.swift
    │   │   ├── RoutesOverlay.swift
    │   │   ├── RatsnestOverlay.swift
    │   │   └── SubpartExpandedView.swift
    │   └── Settings/
    │       └── ManufacturingSettingsView.swift
    └── Assets.xcassets
```
