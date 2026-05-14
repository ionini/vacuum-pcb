# Vacuum PCB — Design Notes

A working journal of the project's intent, the design decisions we've locked in,
where the code stands today, and what's left. Update this as decisions change.

---

## What this is

A macOS desktop app for designing **pneumatic logic circuits** — vacuum-driven
"transistors" built from two 3D-printed plastic plates sandwiching a thin
silicone sheet — and exporting them as 3D-printable STL geometry.

Workflow: draw a logic schematic (components + nets) → place components and
route the channels in a physical view → export an STL → print → assemble with a
silicone sheet → plug in blunt-tip needles to apply vacuum.

A vacuum transistor: two source/drain holes on the top plate sit above a
hemispherical dimple in the bottom plate. The silicone seals them in the
relaxed state. Pulling vacuum on the dimple (gate) deflects the silicone
downward, connecting the two source/drain channels. NMOS-equivalent;
vacuum-active.

---

## Scope (locked iter 0)

- **Personal hobby tool**, single user, local-first.
- Data model is kept clean enough to open up later, but no plugins, no web, no
  multi-user, no accounts. Hardcoded manufacturing constants tuned to one
  printer / one silicone sheet / one needle gauge.

---

## Primitives (the only things on the canvas)

Five component kinds, no more in MVP:

1. **Transistor** — NMOS-equivalent. 3 pins: `gate`, `a`, `b`. `a`/`b` are
   symmetric. Vacuum on `gate` connects `a`↔`b`.
2. **Resistor** — flow restrictor, sized `S` / `M` / `L`. Realized as a
   serpentine channel between its two pins.
3. **Vacuum source** — edge port to the vacuum pump; the "active rail".
4. **Atmospheric vent** — edge port to atmosphere; the "ground rail".
5. **External port** — generic edge-entry tube terminal (input or output).

**Not in MVP:** PMOS-equivalent / normally-closed transistors, capacitors
(compliant chambers), one-way valves, hierarchical sub-circuits, latches as
primitives. Latches are built from transistors + feedback.

---

## Physical architecture

A single 3-layer sandwich for the whole board:

```
        top plate (printed plastic)
        ───────── silicone face ─────────   ← inner face, z = +siliconeThickness/2
        silicone sheet (one continuous piece)
        ───────── silicone face ─────────   ← inner face, z = -siliconeThickness/2
        bottom plate (printed plastic)
```

Channels (a.k.a. "vias" in the user's vocabulary) run as **round bores through
each plate's midline**, not as grooves cut into the silicone-facing surface.

- Transistor **dimples** are bored *into the silicone-facing surface* of the
  plate the placement points at (bottom plate by default).
- Transistor **source/drain holes** are vertical drop bores connecting the
  channel midline to the silicone face on the opposite plate from the dimple.
- The transistor **gate** also has a drop bore connecting its plate's channel
  midline to the dimple chamber.
- **Edge ports** are horizontal cylindrical bores at the channel midline,
  exiting one of the four board edges depending on placement rotation.

Two plates total → routing is effectively 2-layer with `top`/`bottom` per
segment. Through-plate vias (a tube punching through the silicone sheet) are
**reserved for v2** — the schema includes a `via` waypoint kind today, but the
CAD pipeline ignores it. The MVP inverter avoids needing vias by routing the
gate input on the bottom plate end-to-end.

---

## Logic ↔ Physical binding

KiCad-style **pure layout** projection.

- **Logic view** owns the netlist (which components exist, which terminals
  share which net). It's the source of truth.
- **Physical view** owns placements + routes. It's a *projection* — placement
  and routing can change freely, but you cannot add/remove components or
  change connectivity from the physical view.
- Unplaced components live in a "parking lot" off to the side of the board.
- A live **DRC** (iter 4) reports unrouted nets and exclusion-zone violations.
- **Export is gated** on a clean DRC.

Why this regime (vs bidirectional): the bidirectional approach has unsolvable
ambiguities (e.g., "draw a tube touching three components — does that merge
three nets?"). The strict-projection model is mechanical and unambiguous.

---

## Tech stack

- **Swift + SwiftUI** for the app shell, schematic/physical editors, document
  persistence, 3D preview. macOS-only (single user, hobby scope).
- **[Euclid](https://github.com/nicklockwood/Euclid)** for CSG and STL export
  — pure-Swift mesh CSG library, MIT, embedded as a SwiftPM dependency. After
  every CSG operation we call `makeWatertight()` to heal hairline cracks at
  curved/flat surface intersections, since slicers reject non-manifold STLs.
- **SceneKit** for the in-app 3D preview (Euclid bridges to `SCNGeometry`
  natively).
- **Codable JSON** for document storage. One `.vpcb` file per design.
- Custom UTI `com.ionini.vacuum-pcb` (declared programmatically, not in
  Info.plist — works for in-app pickers but Finder doesn't recognize the type
  system-wide, which is fine for MVP).

Build: standard Xcode project with `PBXFileSystemSynchronizedRootGroup`, so
new files dropped into the source folder are auto-picked-up — no `.pbxproj`
edits needed.

App sandbox is on (`ENABLE_APP_SANDBOX = YES`) with
`com.apple.security.files.user-selected.read-write` granted so the STL save
panel works.

---

## Manufacturing constants (locked defaults, per-document)

| Field                    | Value     |
| ------------------------ | --------- |
| `plateThickness`         | 5.0 mm    |
| `channelDiameter`        | 1.5 mm    |
| `portBoreDiameter`       | 1.6 mm    |
| `siliconeThickness`      | 0.5 mm    |
| `dimpleDiameter`         | 5.0 mm    |
| `dimpleDepth`            | 1.0 mm    |
| `gridPitch`              | 1.0 mm    |
| `minChannelSpacing`      | 1.5 mm    |

Channel diameter is reused for source/drain/gate drop bores (one number to
print-validate). Port bore is slightly wider so a 17-gauge blunt needle
press-fits. Manufacturing constants live **in the document**, not in user
preferences — a printed plate is bound to the parameters it was generated for.

Tune these once after the first physical print/test pass.

---

## Data model (one `Codable` tree per `.vpcb` file)

```
CircuitDocument
├── schemaVersion: Int                      (1)
├── manufacturing: ManufacturingConstants
├── logic: LogicGraph
│   ├── components: [Component]             // id, kind, label, resistorSize?, portDirection?
│   └── nets: [Net]                         // id, label, pins: [PinRef]
└── physical: PhysicalLayout
    ├── placements: [Placement]             // componentId, position, rotation, layer
    ├── routes: [Route]                     // netId, segments
    └── boardOutline: Rect
```

Key invariants:
- All ids are `UUID`. Stable across renames.
- Pin keys are strings statically published by each `ComponentKind` (no enum
  per kind — cheap forward-compat).
- Coordinates are floats in millimeters.
- Routes may be partial; DRC reports unrouted nets.
- No derived state in the document (routed/unrouted status, DRC errors are
  computed from the document, not stored).
- Schema is JSON-pretty-printed with sorted keys → deterministic and
  diff-friendly.

`Waypoint.kind` includes a `via` case that the MVP CAD pipeline ignores —
reserved so v2 (through-plate vias) doesn't need a schema migration.

`Placement.layer` is which plate the component's primary features (dimple for
transistor, bore for port-likes, serpentine for resistor) live on. Pin layers
are derived: each `FootprintPin` declares its layer as `same` or `opposite`
relative to the placement layer.

---

## Where we are: iters 1 + 2 done

### Iter 1 — hardcoded inverter → watertight STL ✓

The smallest possible vertical slice: hardcoded inverter document → CAD
pipeline → watertight binary STL. Validated as printable on the user's bench
(inverter physically works).

### Iter 2 — schematic editor ✓

Interactive circuit construction. Click palette buttons to spawn components,
drag to position, click pin → pin to create / extend nets. The schematic is
view-only metadata — `SchematicLayout.positions` — independent of physical
placement.

✅ `SchematicLayout` added to the document (component → schematic XY positions)
✅ `LogicGraph.nextLabel(for:portDirection:)` auto-labels (`Q1`, `R1`, `VAC`,
   `VENT`, `IN1`, `OUT1`, …)
✅ Tabbed UI: **Schematic** / **Physical** (iter-3 placeholder) / **3D Preview**
✅ Component palette (6 buttons: Q, R, VAC, ATM, IN, OUT)
✅ Stylized per-kind symbols with labels (rounded shapes, color-coded)
✅ Drag-to-move components on the canvas
✅ Pin handles with expanded hit zones
✅ Click-pin → click-pin net interaction with rubber-band line
   - both pins free: create net
   - one on net: extend
   - on different nets: merge
   - on same net: remove the second pin from the net (auto-deletes net <2 pins)
   - same pin twice: cancel
✅ Rat's nest net rendering (line from each pin to net's first pin)
✅ Selection + delete (component cascades to placements + net memberships;
   net cascades to routes)
✅ Double-click label inline rename
✅ Inspector strip with per-selection controls (resistor S/M/L picker, port
   input/output toggle, net label field)
✅ "Physical layout out of date" hint when netlist diverges from placements

**Known iter-2 gaps (not blockers, deferred):**
- **No net selection from the canvas.** Net lines are non-hit-testable, so
  nets can be edited only by removing all their pins. Net renaming via the
  inspector requires reaching a selected state we can't get into yet. Fix in
  iter 3 or by adding a sidebar net list.
- **No multi-select, no marquee, no copy/paste.**
- **The 3D Preview lags the schematic.** Any schematic-only addition (no
  placement yet) doesn't appear in CAD. The sidebar surfaces this.

---

## What's still missing for the user to actually use this tool

The MVP α target ("design one inverter, click button, export STL, print, verify")
is technically reachable today: open the app, File → New (auto-seeded with the
inverter), Export STL. But you can't *edit* anything — the document is read-only
in practice. Everything below this point is about turning it into a real tool.

### Iter 3 — Physical editor

Where the interesting routing/placement work happens.

- Parking lot for unplaced components on the side of the canvas.
- Drag from parking lot onto the board → creates a `Placement`.
- Rotate (R), flip layer (F), delete (⌫).
- Manhattan polyline tool: click pin → click waypoints → click pin to commit.
  Snap to grid. 90° bends only.
- Per-segment layer assignment; layer toggle button to draw on top vs bottom.
- Selection, drag-to-modify, segment delete with rejoin.
- Live visual feedback: highlight the net you're routing, show endpoints.

### Iter 4 — DRC

The thing that turns "you can edit it" into "you can trust it."

- Net continuity check: every net's pins must be reachable via routed segments.
  Reports unrouted nets and disconnected sub-nets.
- Exclusion zone violations: foreign channels crossing a component's footprint
  exclusion rect.
- Minimum spacing: parallel channels too close together.
- Pin-layer / route-layer mismatches: route ends at a pin on the wrong layer.
- DRC errors as first-class document-derived state shown in a sidebar panel,
  with click-to-zoom on the offending element.
- Gate the **Export STL** button on zero DRC errors.

### Iter 5 — Quality of life

Mechanical but high-impact.

- `UndoManager` integration. The data model is already pure-value-type
  `Codable`, so snapshot-and-push-undo is trivial.
- Autosave (DocumentGroup gives this near-free if `ReferenceFileDocument`).
- Settings UI for manufacturing constants (currently in-doc only, no editor).
- "File → Open Sample" submenu enumerating bundled example circuits.
- Optional USDZ export (we already produce Euclid meshes that SceneKit reads —
  a USDZ writer is a few dozen lines).

### Iter 6+ — The features deferred from iter 0

- **Through-plate vias.** Schema already reserves the `via` waypoint kind.
  CAD-side: a `via` waypoint subtracts a cylinder through the silicone region
  at that XY, allowing routes to switch plates. Will need a physical mechanism
  (the silicone sheet has a punched hole at the via XY, sealed around the
  perimeter — tricky). Required for SR latches and any output→input feedback
  that crosses plates.
- **PMOS-equivalent / normally-closed transistors.** Dimple geometry flipped.
  Required for CMOS-style logic with low static draw; without it, every gate
  leaks vacuum through pull-ups.
- **Capacitor primitive.** Compliant chamber for delay / filtering.
- **Boolean simulation.** Propagate `0`/`1` (atm/vacuum) through the netlist
  to validate logic before printing. Cheap to implement; high value.
- **Pneumatic (analog) simulation.** SPICE-style with pressure/flow values.
  Research-grade; defer indefinitely.
- **Sub-circuit / hierarchical components.** Once you've built a NAND from
  transistors, drop it as a single block elsewhere.
- **Autorouter.** Generally a tarpit; defer until you've manually routed
  enough designs to know what tradeoffs you want.

---

## Open questions / known gaps

- **Physical validation.** Nothing in the CAD pipeline has been print-tested
  yet. First print of the inverter may reveal that channel diameter, dimple
  depth, drop bore length, or silicone-face wall thickness need adjusting.
  After the first print, tune the defaults in
  `ManufacturingConstants.defaults` and add a comment explaining why.
- **Resistor pneumatic behavior.** The S/M/L serpentine lengths are arbitrary
  — they create *some* flow restriction but the actual resistance values
  haven't been measured or designed. For a functional inverter we just need
  R1 > R_transistor_on, which any non-zero serpentine satisfies. Real values
  will matter once we have multi-stage circuits.
- **Port press-fit tolerance.** `portBoreDiameter = 1.6 mm` is sized for a
  17-gauge blunt needle (1.473 mm OD). The 0.13 mm gap relies on resin/PLA
  shrinkage to grip. May need adjustment per material.
- **Schematic-side layout persistence.** We haven't decided whether schematic
  XY positions live in the document, in app prefs, or are recomputed by graph
  layout. Document-side is the safer default.
- **Through-via physical mechanism.** When we add vias in v2, we'll need to
  decide whether the silicone sheet is punched (with the channel network
  bridging the puncture) or whether the via is a separate component that
  routes around the silicone entirely. Punching is simpler in CAD but harder
  in manufacturing.
- **File format for sharing.** The custom UTI is fine for the user's own
  files. If we ever publish examples, we'll need either an Info.plist UTI
  declaration so Finder recognizes `.vpcb`, or a fallback to `.json`.

---

## Where things live in the repo

```
Vacuum PCB/
├── Vacuum PCB.xcodeproj/
└── Vacuum PCB/                   ← synchronized source root
    ├── Vacuum_PCBApp.swift       ← @main, DocumentGroup, DEBUG self-test
    ├── Model/                    ← pure-value Codable schema
    │   ├── Geometry.swift            (Point, Rect, Size, Rotation, Layer)
    │   ├── LogicGraph.swift          (Component, PinRef, Net, ComponentKind…)
    │   ├── PhysicalLayout.swift      (Placement, Route, Segment, Waypoint…)
    │   ├── ManufacturingConstants.swift
    │   ├── Footprint.swift           (per-kind pin offsets + exclusion zones)
    │   ├── CircuitDocument.swift     (top-level + JSON Codable helpers)
    │   └── SelfTest.swift            (DEBUG launch self-checks)
    ├── Document/
    │   └── VPCBDocument.swift        (SwiftUI FileDocument + UTType.vacuumPCB)
    ├── Examples/
    │   ├── Examples.swift            (Examples.inverter() — source of truth)
    │   └── inverter.vpcb             (bundled example, regen on every launch)
    ├── CAD/
    │   ├── PlateBuilder.swift        (the CSG pipeline)
    │   └── STLExportDocument.swift   (.fileExporter target)
    ├── UI/
    │   ├── DocumentView.swift        (sidebar stats + Scene3DView + Export)
    │   └── Scene3DView.swift         (SCNView wrapper)
    └── Assets.xcassets
```

Top-level `Examples/inverter.vpcb` is the bundled artifact; the in-sandbox copy
at `~/Library/Containers/com.ionini.Vacuum-PCB/Data/Library/Application Support/Vacuum PCB/Examples/inverter.vpcb`
is the round-tripped one written by `SelfTest` for inspection. The `.stl` next
to it is the smoke-test CAD output.
