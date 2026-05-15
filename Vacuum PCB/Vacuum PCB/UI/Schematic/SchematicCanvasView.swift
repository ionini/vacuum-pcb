import SwiftUI

/// The main schematic editor canvas: components positioned by their schematic XY,
/// net lines drawn underneath, click-to-deselect background, rubber-band line
/// when drawing a net, and keyboard shortcuts (ESC to cancel net, ⌫ to delete).
struct SchematicCanvasView: View {
    @Binding var document: VPCBDocument
    @Binding var selection: SchematicSelection
    @Binding var netDrawState: NetDrawState

    @State private var mouseLocation: CGPoint = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(NSColor.controlBackgroundColor)
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = .none
                    netDrawState = .idle
                }

            NetLinesView(document: document.circuit, selection: selection)

            ForEach(document.circuit.logic.components) { component in
                let pos = document.circuit.schematic.position(for: component.id)
                    ?? Point(x: 200, y: 200)
                ComponentNodeView(
                    component: component,
                    document: $document,
                    selection: $selection,
                    netDrawState: $netDrawState
                )
                .position(x: pos.x, y: pos.y)
            }

            if case .awaitingSecondPin(let firstPin) = netDrawState,
               let start = pinScreenPosition(firstPin) {
                rubberBand(from: start, to: mouseLocation)
            }

            // Hidden buttons drive keyboard shortcuts at the window level
            // without depending on SwiftUI focus — tapping a child view (a
            // component symbol, a pin handle) doesn't disturb them. They still
            // correctly defer to first-responder text fields (e.g. the inline
            // rename field), so typing Delete while renaming edits the text.
            keyShortcuts
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let pos): mouseLocation = pos
            case .ended: break
            }
        }
    }

    @ViewBuilder private var keyShortcuts: some View {
        Button("Delete selection") { deleteSelection() }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!selection.isDeletable)
            .opacity(0).frame(width: 0, height: 0)
        Button("Forward delete selection") { deleteSelection() }
            .keyboardShortcut(.deleteForward, modifiers: [])
            .disabled(!selection.isDeletable)
            .opacity(0).frame(width: 0, height: 0)
        Button("Cancel") {
            netDrawState = .idle
            selection = .none
        }
        .keyboardShortcut(.cancelAction)
        .opacity(0).frame(width: 0, height: 0)
    }

    // MARK: - Rubber band

    private func rubberBand(from a: CGPoint, to b: CGPoint) -> some View {
        Path { p in
            p.move(to: a)
            p.addLine(to: b)
        }
        .stroke(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 1.6, dash: [4, 3]))
        .allowsHitTesting(false)
    }

    private func pinScreenPosition(_ ref: PinRef) -> CGPoint? {
        guard let comp = document.circuit.logic.components.first(where: { $0.id == ref.componentId }),
              let center = document.circuit.schematic.position(for: ref.componentId)
        else { return nil }
        let metrics = ComponentSymbolMetrics.metrics(for: comp.kind)
        let off = metrics.pinOffset(ref.pinKey)
        return CGPoint(x: center.x + off.x, y: center.y + off.y)
    }

    // MARK: - Deletion

    private func deleteSelection() {
        switch selection {
        case .component(let id):
            deleteComponent(id)
        case .net(let id):
            deleteNet(id)
        case .pin, .none:
            break
        }
        selection = .none
    }

    private func deleteComponent(_ id: UUID) {
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

    private func deleteNet(_ id: UUID) {
        document.circuit.logic.nets.removeAll { $0.id == id }
        document.circuit.physical.routes.removeAll { $0.netId == id }
    }
}
