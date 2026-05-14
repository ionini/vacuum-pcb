import SwiftUI

/// The Schematic tab content: palette on the left, canvas in the middle.
/// The inspector strip is owned by DocumentView so it's shared with other tabs.
struct SchematicView: View {
    @Binding var document: VPCBDocument
    @Binding var selection: SchematicSelection
    @Binding var netDrawState: NetDrawState

    var body: some View {
        HStack(spacing: 0) {
            ComponentPaletteView(onAdd: addComponent)
            Divider()
            SchematicCanvasView(
                document: $document,
                selection: $selection,
                netDrawState: $netDrawState
            )
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

    /// New components spawn in a loose grid so they don't all stack on the same
    /// point. Uses current component count to compute next spawn slot.
    private func spawnPosition() -> Point {
        let n = document.circuit.logic.components.count
        let col = n % 5
        let row = n / 5
        return Point(x: 120 + Double(col) * 120, y: 100 + Double(row) * 110)
    }
}
