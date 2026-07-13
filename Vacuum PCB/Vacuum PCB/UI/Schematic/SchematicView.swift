import SwiftUI

/// The Schematic tab content: just the canvas plus the bottom
/// selection-details strip. The component palette lives in the document
/// inspector (right column) now.
struct SchematicView: View {
    @Binding var document: VPCBDocument
    @Binding var selection: SchematicSelection
    @Binding var netDrawState: NetDrawState
    /// Threaded down so this view can plant the Inspector toolbar toggle
    /// as the rightmost toolbar item.
    @Binding var showInspector: Bool
    /// Passed in from DocumentView so the Export menu can sit immediately
    /// before the Inspector toggle on the trailing edge.
    let exportMenu: ExportMenuButton
    /// Draw VAC/ATM rail nets as compact tap symbols (vs. wires). Shared with
    /// the canvas + Simulate view through the same AppStorage key.
    @AppStorage("schematicShowRailTaps") private var showRailTaps = true
    /// Show a small hideable marker on each net that has a physical testing
    /// point. Shared with the canvas through the same AppStorage key.
    @AppStorage("schematicShowTestPoints") private var showTestPoints = true

    var body: some View {
        VStack(spacing: 0) {
            SchematicCanvasView(
                document: $document,
                selection: $selection,
                netDrawState: $netDrawState
            )
            Divider()
            InspectorStrip(document: $document, selection: $selection)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: $showRailTaps) {
                    Label("Rail taps", systemImage: "powerplug")
                }
                .toggleStyle(.button)
                .help("Show VAC/ATM rail nets as compact tap symbols instead of wires")
            }
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: $showTestPoints) {
                    Label("Test points", systemImage: "scope")
                }
                .toggleStyle(.button)
                .help("Show a marker on nets that have a physical testing point")
            }
            ToolbarItem(placement: .primaryAction) { exportMenu }
            ToolbarItem(placement: .primaryAction) {
                InspectorToggleButton(showInspector: $showInspector)
            }
        }
    }
}

/// Right-hand inspector content for the Schematic tab. Owns the
/// component palette (was the leading column of the schematic before)
/// plus the alert that surfaces "library part doesn't fit this board"
/// when the user tries to drop an incompatible subpart.
struct SchematicInspector: View {
    @Binding var document: VPCBDocument
    @Binding var selection: SchematicSelection

    @State private var alertMessage: String?
    /// Library part the user just attempted to add when the document
    /// would flip into assembly mode as a result. Held here while the
    /// confirmation sheet is up; cleared by either button.
    @State private var pendingAssemblyEntry: PartsLibrary.Part?
    /// Library part the user just attempted to add when it needs more
    /// channel layers than the current document has. Held here while the
    /// "bump layers to fit?" confirmation is up; cleared by either button.
    @State private var pendingLayerBump: PartsLibrary.Part?

    var body: some View {
        VStack(spacing: 0) {
            SchematicContextSection(document: $document, selection: $selection)
            ScrollView {
                ComponentPaletteView(
                    onAdd: addComponent,
                    onAddLibraryPart: addLibraryPart
                )
            }
        }
        .alert("Can't add part", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .alert("Enter assembly mode?", isPresented: Binding(
            get: { pendingAssemblyEntry != nil },
            set: { if !$0 { pendingAssemblyEntry = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingAssemblyEntry = nil }
            Button("Add and enter assembly mode") {
                if let part = pendingAssemblyEntry {
                    pendingAssemblyEntry = nil
                    commitLibraryPart(part)
                }
            }
        } message: {
            Text("""
                "\(pendingAssemblyEntry?.displayName ?? "This part")" contains a connector. \
                Adding it switches this document into Assembly mode, which disables the \
                Physical and 3D Preview tabs and the Simulate physical canvas. STL / Bambu / \
                Flow Simulator export is also unavailable in assembly mode. The schematic \
                editor and Simulate schematic canvas remain available. \
                Remove the part later to leave assembly mode.
                """
            )
        }
        .alert("Add more layers?", isPresented: Binding(
            get: { pendingLayerBump != nil },
            set: { if !$0 { pendingLayerBump = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingLayerBump = nil }
            Button("Bump layers and add") {
                if let part = pendingLayerBump {
                    pendingLayerBump = nil
                    bumpLayersToFit(part)
                    addLibraryPart(part)
                }
            }
        } message: {
            Text(layerBumpMessage(for: pendingLayerBump))
        }
    }

    /// Grows the document's channel-layer counts so the part's internal
    /// routes land at valid depths. Only ever increases the counts (a part
    /// reaching this path needs more than the parent has), so it never
    /// evicts existing routes/vias.
    private func bumpLayersToFit(_ part: PartsLibrary.Part) {
        document.circuit.physical.topLayers = max(
            document.circuit.physical.topLayers, part.document.physical.topLayers
        )
        document.circuit.physical.bottomLayers = max(
            document.circuit.physical.bottomLayers, part.document.physical.bottomLayers
        )
    }

    /// Spells out the before/after channel-layer counts for the bump prompt.
    private func layerBumpMessage(for part: PartsLibrary.Part?) -> String {
        guard let part else { return "" }
        let parentTop    = document.circuit.physical.topLayers
        let parentBottom = document.circuit.physical.bottomLayers
        let newTop       = max(parentTop, part.document.physical.topLayers)
        let newBottom    = max(parentBottom, part.document.physical.bottomLayers)
        return "\"\(part.displayName)\" needs \(newTop) top / \(newBottom) bottom " +
            "channel layers. This document has \(parentTop)/\(parentBottom). " +
            "Bump the channel-layer counts to \(newTop)/\(newBottom) and add the part? " +
            "Adding layers is non-destructive — your existing routing is untouched."
    }

    private func addComponent(kind: ComponentKind, portDirection: PortDirection?) {
        let component = SchematicActions.makeComponent(
            kind: kind, portDirection: portDirection, in: document.circuit)
        document.circuit.logic.components.append(component)
        document.circuit.schematic.setPosition(spawnPosition(), for: component.id)
        selection = .component(component.id)
    }

    /// Instantiates a library part. Enforces the layer-count check up
    /// front: a part designed against more channel layers than the
    /// parent has would land internal routes at invalid depths in the
    /// parent's stack, so we refuse instead of silently bumping (per the
    /// v1 design decision).
    private func addLibraryPart(_ part: PartsLibrary.Part) {
        // V1 of assembly mode is one level deep — a subpart that is itself
        // an assembly (has matings of its own) can't be expanded yet.
        // Refuse outright with a clear message; the connector-bearing case
        // below remains supported.
        if !part.document.logic.matings.isEmpty {
            alertMessage = "\"\(part.displayName)\" is itself an assembly. " +
                "V1 of Assembly mode supports one level of nesting only — " +
                "this part can't be used as a subpart."
            return
        }
        let parentTop    = document.circuit.physical.topLayers
        let parentBottom = document.circuit.physical.bottomLayers
        let partTop      = part.document.physical.topLayers
        let partBottom   = part.document.physical.bottomLayers
        if partTop > parentTop || partBottom > parentBottom {
            // The part needs more channel layers than this document has.
            // Growing the layer count is non-destructive (only shrinking
            // evicts routes/vias), so rather than refusing outright we offer
            // to bump the document's counts up to fit — no round-trip through
            // the Physical tab required. Confirm first so the user knows the
            // board stack is about to change.
            pendingLayerBump = part
            return
        }
        // Grid-pitch check. Child routes/placements snap to multiples of
        // the child's pitch; they only land on the parent's grid when the
        // child pitch is an integer multiple of the parent's. A finer
        // child in a coarser parent would strand routes between parent
        // cells, so refuse and tell the user how far to drop the parent.
        let parentPitch = document.circuit.manufacturing.gridPitch
        let partPitch   = part.document.manufacturing.gridPitch
        if parentPitch > 0, partPitch > 0 {
            let ratio = partPitch / parentPitch
            let rounded = ratio.rounded()
            let alignsToGrid = rounded >= 1 && abs(ratio - rounded) < 1e-6
            if !alignsToGrid {
                alertMessage = "\"\(part.displayName)\" was designed at " +
                    "grid pitch \(formatPitch(partPitch)) mm. " +
                    "Current document has \(formatPitch(parentPitch)) mm — " +
                    "bump it to \(formatPitch(partPitch)) mm before adding this part."
                return
            }
        }
        // Adding a connector-bearing part flips a non-assembly document
        // into assembly mode (Physical / 3D Preview / Simulate-physical
        // disabled, export disabled). Ask the user to confirm before
        // making that switch. Documents already in assembly mode skip the
        // prompt — they're already committed.
        if part.document.containsConnector, !document.circuit.isAssembly {
            pendingAssemblyEntry = part
            return
        }
        commitLibraryPart(part)
    }

    /// Final placement step shared between the direct-add path and the
    /// "after the assembly-mode confirm" path. Pins the part to its
    /// snapshot, inserts the component + schematic position + centred
    /// physical placement, and selects the new instance.
    private func commitLibraryPart(_ part: PartsLibrary.Part) {
        let label = document.circuit.logic.nextLabel(for: .subpart)
        let id = UUID()
        let hash = part.document.contentHash()
        if document.circuit.librarySnapshots[hash] == nil {
            document.circuit.librarySnapshots[hash] = part.document
        }
        let component = Component(
            id: id,
            kind: .subpart,
            label: label,
            partRef: part.filename,
            partRefHash: hash
        )
        document.circuit.logic.components.append(component)
        document.circuit.schematic.setPosition(spawnPosition(), for: id)
        let outline = document.circuit.physical.boardOutline
        let centre = Point(
            x: outline.origin.x + outline.size.width / 2,
            y: outline.origin.y + outline.size.height / 2
        )
        document.circuit.physical.placements.append(
            Placement(componentId: id, position: centre, rotation: .r0, layer: .top, depth: 0)
        )
        selection = .component(id)
    }

    /// New components spawn in a loose grid so they don't all stack on
    /// the same point. Uses the current component count to compute the
    /// next spawn slot.
    private func spawnPosition() -> Point {
        let n = document.circuit.logic.components.count
        let col = n % 5
        let row = n / 5
        return Point(x: 120 + Double(col) * 120, y: 100 + Double(row) * 110)
    }

    /// Compact mm formatting for alert text — `%g` trims trailing zeros so
    /// 1.0 reads as "1" and 0.5 as "0.5" instead of "1.000000".
    private func formatPitch(_ pitch: Double) -> String {
        String(format: "%g", pitch)
    }
}

/// Contextual action block at the top of the schematic inspector. Mirrors
/// `PhysicalContextSection` — shows nothing when the selection is empty,
/// surfaces Delete when one or more components or a net is selected. The
/// ⌫ shortcut still works on macOS; this is the only way to delete on
/// iPad (no hardware Delete without an external keyboard).
struct SchematicContextSection: View {
    @Binding var document: VPCBDocument
    @Binding var selection: SchematicSelection
    /// Observed so the Paste button appears the instant something is copied
    /// (and stays available even with nothing selected).
    @ObservedObject private var clipboard = SchematicClipboard.shared

    var body: some View {
        Group {
            if !selection.isEmpty || clipboard.hasContent {
                VStack(alignment: .leading, spacing: 6) {
                    if !selection.isEmpty {
                        Text(header)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                    if !selection.components.isEmpty {
                        Button {
                            SchematicActions.rotate(document: &document, selection: selection)
                        } label: {
                            Label(rotateLabel, systemImage: "rotate.right")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        Button {
                            SchematicActions.copy(document: document, selection: selection)
                        } label: {
                            Label(copyLabel, systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                    if clipboard.hasContent {
                        Button {
                            SchematicActions.paste(document: &document, selection: &selection)
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                    if !selection.isEmpty {
                        Button(role: .destructive) {
                            SchematicActions.delete(document: &document, selection: &selection)
                        } label: {
                            Label(deleteLabel, systemImage: "trash")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
            }
        }
    }

    private var copyLabel: String {
        selection.components.count > 1
            ? "Copy \(selection.components.count) components"
            : "Copy"
    }

    private var header: String {
        let n = selection.components.count
        if n > 0 && selection.net != nil {
            return "\(n) component\(n == 1 ? "" : "s") + net"
        }
        if n > 1 { return "\(n) components" }
        if n == 1 { return "Component" }
        return "Net"
    }

    private var rotateLabel: String {
        selection.components.count > 1
            ? "Rotate \(selection.components.count) components 90°"
            : "Rotate 90°"
    }

    private var deleteLabel: String {
        if selection.components.count > 1 { return "Delete \(selection.components.count) components" }
        if selection.components.count == 1 && selection.net == nil { return "Delete component" }
        if selection.components.isEmpty && selection.net != nil { return "Delete net" }
        return "Delete"
    }
}

/// Mutations the schematic canvas and its inspector both trigger. Lifted
/// out of `SchematicCanvasView` so the inspector's Delete button drives
/// the same path the ⌫ shortcut does on macOS.
enum SchematicActions {
    /// Delete every selected component and the selected net (if any).
    /// Component deletion cascades into nets (orphan nets dropped when
    /// they fall below two pins) and into physical state (routes on
    /// killed nets, the component's own placement). Net deletion also
    /// removes any physical routes on that net.
    static func delete(document: inout VPCBDocument, selection: inout SchematicSelection) {
        for id in selection.components {
            deleteComponent(id, in: &document)
        }
        if let netId = selection.net {
            deleteNet(netId, in: &document)
        }
        // Cascade: drop any waypoints whose wire no longer exists (the net was
        // deleted, or a component deletion dissolved it).
        document.circuit.schematic.pruneWaypoints(connectedIn: document.circuit.logic.nets)
        selection = .none
    }

    /// Rotate every selected component 90° clockwise on the schematic.
    /// Schematic-only cosmetic reorientation — it moves which side the pins
    /// sit on; the physical/CAD layout is untouched. No-op when no component
    /// is selected. Selection is preserved so repeated presses keep turning
    /// the same component.
    static func rotate(document: inout VPCBDocument, selection: SchematicSelection) {
        for id in selection.components {
            document.circuit.schematic.rotate(componentId: id, by: 1)
        }
    }

    /// Builds a fresh primitive component with a unique label. Pure — the
    /// caller appends it and assigns its schematic position. Shared by the
    /// palette's click-to-add and the canvas's drag-to-place drop.
    static func makeComponent(kind: ComponentKind, portDirection: PortDirection?,
                              in circuit: CircuitDocument) -> Component {
        Component(
            id: UUID(),
            kind: kind,
            label: circuit.logic.nextLabel(for: kind, portDirection: portDirection),
            resistorSize: kind == .resistor ? .medium : nil,
            portDirection: portDirection,
            connectorPinCount: kind == .connector ? 4 : nil,
            connectorRole: kind == .connector ? .bottomExtend : nil
        )
    }

    private static func deleteComponent(_ id: UUID, in document: inout VPCBDocument) {
        document.circuit.logic.components.removeAll { $0.id == id }
        document.circuit.schematic.remove(componentId: id)
        for i in document.circuit.logic.nets.indices {
            document.circuit.logic.nets[i].pins.removeAll { $0.componentId == id }
        }
        let dead = document.circuit.logic.nets.filter { $0.pins.count < 2 }.map(\.id)
        document.circuit.logic.nets.removeAll { dead.contains($0.id) }
        document.circuit.physical.routes.removeAll { dead.contains($0.netId) }
        document.circuit.physical.placements.removeAll { $0.componentId == id }
    }

    private static func deleteNet(_ id: UUID, in document: inout VPCBDocument) {
        document.circuit.logic.nets.removeAll { $0.id == id }
        document.circuit.physical.routes.removeAll { $0.netId == id }
    }
}
