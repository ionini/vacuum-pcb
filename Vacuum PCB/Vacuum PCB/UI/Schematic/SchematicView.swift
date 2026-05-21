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

    var body: some View {
        ScrollView {
            ComponentPaletteView(
                onAdd: addComponent,
                onAddLibraryPart: addLibraryPart
            )
        }
        .alert("Can't add part", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func addComponent(kind: ComponentKind, portDirection: PortDirection?) {
        let label = document.circuit.logic.nextLabel(for: kind, portDirection: portDirection)
        let id = UUID()
        let component = Component(
            id: id,
            kind: kind,
            label: label,
            resistorSize: kind == .resistor ? .medium : nil,
            portDirection: portDirection
        )
        document.circuit.logic.components.append(component)
        document.circuit.schematic.setPosition(spawnPosition(), for: id)
        selection = .component(id)
    }

    /// Instantiates a library part. Enforces the layer-count check up
    /// front: a part designed against more channel layers than the
    /// parent has would land internal routes at invalid depths in the
    /// parent's stack, so we refuse instead of silently bumping (per the
    /// v1 design decision).
    private func addLibraryPart(_ part: PartsLibrary.Part) {
        let parentTop    = document.circuit.physical.topLayers
        let parentBottom = document.circuit.physical.bottomLayers
        let partTop      = part.document.physical.topLayers
        let partBottom   = part.document.physical.bottomLayers
        if partTop > parentTop || partBottom > parentBottom {
            alertMessage = "\"\(part.displayName)\" needs " +
                "topLayers ≥ \(partTop) and bottomLayers ≥ \(partBottom). " +
                "Current document has \(parentTop)/\(parentBottom). " +
                "Bump the channel-layer counts in settings before adding this part."
            return
        }
        let label = document.circuit.logic.nextLabel(for: .subpart)
        let id = UUID()
        // Pin the placed instance to the live library's current content
        // hash and stash a snapshot in the document so later edits to the
        // library don't cascade into this design.
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
        // Default placement near the centre of the parent board so the
        // expanded internals are visible without scrolling.
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
}
