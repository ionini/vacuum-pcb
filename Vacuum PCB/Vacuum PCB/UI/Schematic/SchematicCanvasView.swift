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

            // NSEvent-monitor key catcher. Hidden Buttons with
            // .keyboardShortcut used to live here but their delivery was
            // unreliable — focus drifts to the inspector TextField or to a
            // tapped child, and the shortcut quietly stops firing. The
            // monitor sits at the window level and only defers to events
            // owned by a text-editing first responder (so inline rename
            // still gets its Delete key).
            KeyEventCatcher(handlers: [
                KeyCodes.delete: { deleteSelection() },
                KeyCodes.forwardDelete: { deleteSelection() },
                KeyCodes.escape: {
                    netDrawState = .idle
                    selection = .none
                },
            ])

            // Right-click a net line to remove the pin at its non-anchor
            // end from the net. If the net drops below 2 pins, the whole
            // net is deleted (and any physical routes for it are cleaned
            // up too) — same toggle semantics as the click-pin → click-pin
            // gesture.
            RightClickCatcher { pt in handleRightClick(at: pt) }
                .allowsHitTesting(true)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let pos): mouseLocation = pos
            case .ended: break
            }
        }
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

    // MARK: - Right-click on a net line

    /// Walks the same edges NetLinesView draws, picks the closest line within
    /// `threshold`, then removes whichever endpoint the click is nearer to.
    /// Falling back to "closer endpoint" matters for the MST layout where
    /// neither end of an edge is the anchor — under the old star-only logic
    /// we always removed the non-anchor end, which made little sense for
    /// component-to-component edges.
    private func handleRightClick(at pt: CGPoint) {
        let threshold: Double = 8
        var best: (netId: UUID, pinToRemove: PinRef, distance: Double)?
        for net in document.circuit.logic.nets {
            for edge in NetEdgeBuilder.edges(for: net, in: document.circuit) {
                let d = distanceFromPoint(pt, toSegmentFrom: edge.a.point, to: edge.b.point)
                guard d <= threshold else { continue }
                if d < (best?.distance ?? .greatestFiniteMagnitude) {
                    let aDist = hypot(Double(pt.x - edge.a.point.x), Double(pt.y - edge.a.point.y))
                    let bDist = hypot(Double(pt.x - edge.b.point.x), Double(pt.y - edge.b.point.y))
                    let pin = aDist < bDist ? edge.a.pin : edge.b.pin
                    best = (net.id, pin, d)
                }
            }
        }
        guard let hit = best else { return }
        removePin(hit.pinToRemove, fromNet: hit.netId)
    }

    private func removePin(_ pin: PinRef, fromNet netId: UUID) {
        guard let i = document.circuit.logic.nets.firstIndex(where: { $0.id == netId })
        else { return }
        document.circuit.logic.nets[i].pins.removeAll { $0 == pin }
        if document.circuit.logic.nets[i].pins.count < 2 {
            let killed = document.circuit.logic.nets[i].id
            document.circuit.logic.nets.remove(at: i)
            document.circuit.physical.routes.removeAll { $0.netId == killed }
            if case .net(let id) = selection, id == killed { selection = .none }
        }
    }

    private func distanceFromPoint(_ p: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return hypot(Double(p.x - a.x), Double(p.y - a.y)) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        return hypot(Double(p.x - (a.x + CGFloat(t) * dx)),
                     Double(p.y - (a.y + CGFloat(t) * dy)))
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
