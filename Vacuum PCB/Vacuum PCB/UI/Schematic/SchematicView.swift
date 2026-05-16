import SwiftUI

/// The Schematic tab content: palette on the left, canvas in the middle.
/// The inspector strip is owned by DocumentView so it's shared with other tabs.
struct SchematicView: View {
    @Binding var document: VPCBDocument
    @Binding var selection: SchematicSelection
    @Binding var netDrawState: NetDrawState

    @State private var alertMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ComponentPaletteView(
                    onAdd: addComponent,
                    onAddLibraryPart: addLibraryPart
                )
                Divider()
                SchematicCanvasView(
                    document: $document,
                    selection: $selection,
                    netDrawState: $netDrawState
                )
            }
            Divider()
            InspectorStrip(document: $document, selection: $selection)
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

    /// Instantiates a library part. Enforces the layer-count check up front:
    /// a part designed against more channel layers than the parent has would
    /// land internal routes at invalid depths in the parent's stack, so we
    /// refuse instead of silently bumping (per the v1 design decision).
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
        let component = Component(
            id: id,
            kind: .subpart,
            label: label,
            partRef: part.filename
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

    /// New components spawn in a loose grid so they don't all stack on the same
    /// point. Uses current component count to compute next spawn slot.
    private func spawnPosition() -> Point {
        let n = document.circuit.logic.components.count
        let col = n % 5
        let row = n / 5
        return Point(x: 120 + Double(col) * 120, y: 100 + Double(row) * 110)
    }
}
