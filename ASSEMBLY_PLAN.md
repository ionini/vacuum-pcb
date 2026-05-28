# Assembly Mode — V1 Design Plan

A mode that lets a `.vpcb` document instantiate **connector-bearing subparts** so that two (or more) standalone designs can be wired together at the schematic level via their mating connectors. Unlocks the path that V1 of the connector primitive deliberately blocks (`CONNECTOR_PLAN.md`, Q7).

The mode is **derived**: a document is in assembly mode iff its logic graph contains at least one subpart whose library snapshot contains a `.connector` primitive. There is no on-disk flag.

## Scope (V1)

- **New first-class relation: `Mating`.** Pairs two connector instances — opposite roles, matching pin count — and is the sole way to electrically join two boards across a connector.
- **Subpart sockets.** A subpart that contains internal `.connector` primitives exposes each one as a *socket* on its schematic boundary symbol. Sockets render as a block of N pins grouped by role. The subpart stays a black box for everything else (DRC, ratsnest, routing).
- **Schematic-only editing.** While the document is in assembly mode, the Physical tab, the 3D Preview tab, and the Simulate-physical-canvas (screw heatmap) are disabled. Only the Schematic editor and the Simulate-schematic-canvas remain available.
- **Schematic drag-snap UX.** A connector or socket can be dragged onto a compatible counterpart in the schematic; on snap, a `Mating` is created and the two halves render butted edge-to-edge as a single composite block, keeping the role of each half visually distinct.
- **No recursion in V1.** A subpart-with-connector cannot itself contain a subpart-with-connector. Existing flatten-time error path is reused.
- **No multi-board physical/CAD output in V1.** Assembly documents have no STL export and no 3D preview — they're a schematic + simulation product. Each subpart's `.vpcb` is still printable standalone.

## What stays the same

- Each `.vpcb` is still one plate stack when opened on its own. The connector primitive plan (`CONNECTOR_PLAN.md`) is unchanged.
- Subpart resolution / library lookup / cycle detection are unchanged.
- Net topology *inside* each subpart is owned by that subpart's own `.vpcb`. The parent's responsibilities are: top-level nets, top-level placements, and matings between connectors.

## Topology being modeled

A parent document in assembly mode owns:

1. A top-level board (its own components + nets + placements + routes + boardOutline + optional own connectors) — same shape as today.
2. A set of subpart placements. Each connector-bearing subpart contributes its own (private, library-defined) plate stack.
3. A list of `Mating` records pairing connectors. Each Mating defines N pin-to-pin equivalences (pin i of A ≡ pin i of B for all i in 0..<N) that the flatten step expands into net merges.

A `Mating` may pair any of: (top-level connector ↔ top-level connector), (top-level connector ↔ subpart socket), or (subpart socket ↔ subpart socket). All three forms use the same record; the endpoint type is what differs.

## Data model changes

### `LogicGraph.swift`

- Add `matings: [Mating]` (default `[]`).
- New struct `Mating`:
  - `id: UUID`
  - `a: ConnectorEndpoint`
  - `b: ConnectorEndpoint`
- New enum `ConnectorEndpoint`:
  - `.topLevel(ComponentID)` — a top-level `.connector` component.
  - `.subpartSocket(placement: ComponentID, connector: ComponentID)` — a connector inside a specific subpart placement.
- Computed/derived: `CircuitDocument.isAssembly: Bool` — `true` iff any subpart's library snapshot contains a `.connector` primitive. No stored flag.

### `CircuitDocument.swift`

- Bump `currentSchemaVersion` from 4 → 5. Migration is a no-op for existing v4 documents (no pre-existing matings).
- `flattened()` change: instead of erroring on a connector-bearing subpart, expand the subpart as today **and** consume any `Matings` referencing its sockets, merging the corresponding pin-pair nets.
- A flatten-time error remains for the **recursion** case (a connector-bearing subpart that itself contains a connector-bearing subpart) — reuses the existing typed-error surface.

### `PhysicalLayout.swift`

- Unchanged. Assembly mode doesn't add physical state to the parent.

## Schematic view

### Subpart sockets

- `SubpartBoundary` (or the equivalent boundary-pin computation in `PartsLibrary`) gains a list of sockets in addition to its existing boundary pins.
- A socket renders as a tab on one edge of the subpart symbol: a rectangle with N pin labels in a row, role indicator, and a snap-target affordance.
- Socket location on the subpart symbol: derived from the connector's edge anchor inside the library file (north/south/east/west), so the socket sits on the visually correct side of the subpart symbol.

### Mating creation (V1: inspector-driven)

**V1 ships an inspector-driven Mate picker, not a drag-snap UX.** The Q5
grilling locked drag-snap as the target experience, but landing the
position-coupling + butted-block rendering is a substantial schematic
canvas rewrite; we ship the data model + flatten + DRC + sim integration
first behind a simpler inspector flow, and the polished drag-snap stays
as immediate-next work.

What ships:
- When a top-level connector is selected, the inspector strip shows a
  "Mate to…" menu listing compatible peers (opposite role, matching pin
  count, neither already mated). Picking one creates a `Mating`.
- When a subpart with sockets is selected, the inspector shows one
  "Mate to…" row per socket, prefixed with the socket's full label
  (e.g., "U1.J2").
- A mated endpoint shows "Mated to <peer>" plus an "Unmate" button.
- The mating itself renders on the schematic canvas as a thick indigo
  bus-line connecting the two endpoint centres (top-level connector
  centre or the subpart socket-tab centre).
- Sockets render on the subpart symbol as labeled tabs on the relevant
  edge ("J1 ▼4" for a 4-pin bottom-extend connector), passive in V1 (no
  selection / drag from the symbol).

Future drag-snap polish (V1.1):
- Drag a connector / socket toward a compatible peer; auto-snap on
  proximity, coupling positions so the pair drags as one composite.
- Render the mated halves butted edge-to-edge with distinct role shapes.
- Drag-apart to unmate.

### DRC / palette interaction

- Palette intercept (see Q9 in this plan's grilling): when the user attempts to drop a connector-bearing subpart into a non-assembly document, a confirm prompt fires explaining the consequences (Physical and 3D Preview disabled, no STL export, sim is schematic-only). Cancel aborts the drop; confirm commits it and the document becomes an assembly immediately.
- If the document is already an assembly, no prompt — drops proceed silently.
- No prompt on document open.

## Mode gating

While `circuit.isAssembly == true`:

- **Physical tab**: hidden or shown disabled with an "Assembly mode: physical editing unavailable in V1" placeholder. Pre-existing top-level placements, routes, and `boardOutline` are preserved untouched in the document — they're just frozen from editing.
- **3D Preview tab**: same treatment. No CSG build runs.
- **Simulate-physical-canvas**: disabled. The Simulate tab still works but with only its schematic canvas; the physical/screw-heatmap canvas is hidden.
- **Export menu**: STL / Bambu / Flow Simulator export disabled (the latter relies on USDZ from a flattened single-board doc; multi-board USDZ is out of V1).
- **Schematic tab and Simulate-schematic-canvas**: fully usable.

Exiting assembly mode is automatic: remove the last connector-bearing subpart placement and the derived flag clears; tabs become usable again, with pre-existing physical state intact.

## Simulation

- `SimulationFlatten` consumes the flattened document — net merges from matings are already applied. No simulator-side changes required to honor matings.
- `SimulateSchematicCanvas`: renders the parent's schematic with subparts as black boxes whose **boundary pins and sockets animate pressure**. Mated halves animate as a pair; pressure colors cross the mating boundary because the two pin-pairs are now on the same net post-flatten.
- `SimulatePhysicalCanvas`: disabled while in assembly mode (per gating section).

## DRC additions

New DRC rules specific to assembly mode:

- **Mating compatibility**: both endpoints must resolve, must be of `kind == .connector`, must have opposite roles, and must have matching `connectorPinCount`.
- **No double-mating**: each connector instance appears in at most one `Mating`.
- **Endpoint resolves**: `.subpartSocket(placement, connector)` resolves only if the placement exists and the library snapshot contains a component with that id and `.connector` kind.
- **Recursion block**: a subpart-with-connector that itself contains a subpart-with-connector remains a flatten-time typed error (no UI changes from today).

Existing DRC for routes, layer mismatches, etc. continues to operate on the flattened netlist — no parent-doc-level changes.

## Persistence / migration

- Schema bump 4 → 5. New JSON field: `matings: [Mating]` on `LogicGraph` (omitted when empty for v4 compatibility on read).
- Existing v4 documents migrate cleanly (no matings present).
- A document being in assembly mode does **not** persist a flag — readers compute `isAssembly` from the snapshot graph at open time.

## Files to touch (implementor's checklist)

- `Vacuum PCB/Vacuum PCB/Model/LogicGraph.swift` — `Mating`, `ConnectorEndpoint`, `matings: [Mating]` on `LogicGraph`.
- `Vacuum PCB/Vacuum PCB/Model/CircuitDocument.swift` — schema v5 bump, migration, `isAssembly` accessor, flatten-time mating expansion (replacing the current "block on connector-bearing subpart" branch), recursion-only flatten error.
- `Vacuum PCB/Vacuum PCB/Model/PartsLibrary.swift` — expose sockets alongside boundary pins on `Part`.
- `Vacuum PCB/Vacuum PCB/Model/DRC.swift` — mating compatibility / no-double-mating / endpoint resolution checks.
- `Vacuum PCB/Vacuum PCB/UI/Schematic/SchematicView.swift` — palette intercept + confirm prompt; assembly-mode banner.
- `Vacuum PCB/Vacuum PCB/UI/Schematic/SchematicCanvasView.swift` — socket rendering on subpart symbols; drag-snap interaction; mated-pair composite rendering.
- `Vacuum PCB/Vacuum PCB/UI/Schematic/ComponentSymbol.swift` — socket shape + role indicator.
- `Vacuum PCB/Vacuum PCB/UI/Schematic/InspectorStrip.swift` — "Unmate" action when a mated connector is selected.
- `Vacuum PCB/Vacuum PCB/UI/Schematic/ComponentPaletteView.swift` — allow connector-bearing parts in the palette (today they're filtered out), gated through the confirm prompt.
- `Vacuum PCB/Vacuum PCB/UI/DocumentView.swift` — tab gating: hide / disable Physical, 3D Preview while `circuit.isAssembly`; gate Export menu.
- `Vacuum PCB/Vacuum PCB/UI/Simulate/SimulateView.swift` — hide the physical/screw-heatmap canvas while in assembly mode.

## Out of V1 (future)

- **Drag-snap schematic mating UX.** Q5's target experience — drag a
  connector / socket toward a compatible peer, auto-snap, render the
  pair butted edge-to-edge, drag apart to unmate. V1 ships an
  inspector-driven Mate picker instead; data model + flatten + DRC are
  ready for the polished UX to land later.
- **Multi-board physical view (Q6 option b).** Each board with its own outline, top-level board still editable, subpart boards read-only, routes confined within a board.
- **Multi-board STL / 3D preview / Bambu / Flow Simulator export.** Requires a CAD pipeline rework to emit N plate stacks and to position them in world space.
- **Recursive assembly.** Subpart-of-subpart-with-connector chains. V1
  blocks any subpart that itself contains matings.
- **In-physical mating UX.** Dragging boards together to imply a Mating (mating expressed in physical, not just schematic).
- **DRC for mate compatibility beyond pin count / role.** Pin labels / pneumatic-direction mismatch warnings, screw-pattern check, etc.
- **"Expand subpart in sim" toggle.** Inline a subpart's internal schematic in the Simulate canvas to watch pressure inside it.

## Locked design decisions (from grilling)

| #  | Decision | Choice |
|----|---|---|
| Q1 | Persistent assembly flag or derived state? | **(a) Derived.** `isAssembly` is computed from "any subpart contains `.connector`". No on-disk flag. |
| Q2 | Does the top-level keep its own board in assembly mode? | **(a) Yes.** Top-level components + own connectors + VAC/VENT/port routing still apply. Multi-board picture is top-level + N subpart boards. |
| Q3 | How is mating represented in the model? | **(a) Explicit `Mating` records.** N pin-pair net merges are derived at flatten time. DRC enforces compatibility. |
| Q4 | How do subpart-internal connectors become matable? | **(a) Bubble up as sockets** on the subpart's schematic symbol. Matings address them as `(placementID, internalConnectorID)`. Subpart stays a black box otherwise. |
| Q5 | Schematic UX for creating a Mating? | **(a) Drag-snap.** Compatible halves snap together on drop; mated pair renders as butted edge-to-edge composite. Drag apart to unmate. |
| Q6 | Physical tab in assembly mode? | **(a) Disabled in V1.** Multi-board editing deferred; pre-existing top-level physical state is preserved frozen. |
| Q7 | Simulate-physical-canvas in assembly mode? | **Disabled.** The screw-pressure heatmap doesn't apply to multi-board. Simulate keeps its schematic canvas only. |
| Q8 | Simulate-schematic-canvas: black boxes or inline subparts? | **(a) Black boxes.** Boundary pins and sockets animate. To watch pressure inside a subpart, open its `.vpcb` standalone. |
| Q9 | Entry-to-assembly UX? | **(a) Prompt on palette drop** when adding a connector-bearing subpart to a non-assembly document. No prompt on doc open. No prompt when the doc is already an assembly. |
