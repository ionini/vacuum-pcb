import SwiftUI

/// The main schematic editor canvas: components positioned by their schematic XY,
/// net lines drawn underneath, click-to-deselect background, rubber-band line
/// when drawing a net, marquee box-select on empty canvas, and keyboard
/// shortcuts (ESC to cancel / deselect, ⌫ to delete the selection).
struct SchematicCanvasView: View {
    @Binding var document: VPCBDocument
    @Binding var selection: SchematicSelection
    @Binding var netDrawState: NetDrawState

    @State private var mouseLocation: CGPoint = .zero
    /// Shared multi-component drag state. Lives here so every ComponentNodeView
    /// that participates in the same drag reads the same translation and
    /// follows in tandem.
    @State private var multiDrag: SchematicMultiDrag?
    @State private var marquee: MarqueeRect?

    struct MarqueeRect: Equatable {
        var startScreen: CGPoint
        var currentScreen: CGPoint

        var rect: CGRect {
            CGRect(
                x: min(startScreen.x, currentScreen.x),
                y: min(startScreen.y, currentScreen.y),
                width: abs(currentScreen.x - startScreen.x),
                height: abs(currentScreen.y - startScreen.y)
            )
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(NSColor.controlBackgroundColor)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !NSEvent.modifierFlags.contains(.command) {
                        selection = .none
                    }
                    netDrawState = .idle
                }
                .gesture(marqueeGesture)

            NetLinesView(document: document.circuit, selection: selection)

            ForEach(document.circuit.logic.components) { component in
                let pos = document.circuit.schematic.position(for: component.id)
                    ?? Point(x: 200, y: 200)
                ComponentNodeView(
                    component: component,
                    document: $document,
                    selection: $selection,
                    netDrawState: $netDrawState,
                    multiDrag: $multiDrag
                )
                .position(x: pos.x, y: pos.y)
            }

            if case .awaitingSecondPin(let firstPin) = netDrawState,
               let start = pinScreenPosition(firstPin) {
                rubberBand(from: start, to: mouseLocation)
            }

            marqueeOverlay

            // NSEvent-monitor key catcher.
            KeyEventCatcher(handlers: [
                KeyCodes.delete: { deleteSelection() },
                KeyCodes.forwardDelete: { deleteSelection() },
                KeyCodes.escape: {
                    netDrawState = .idle
                    selection = .none
                },
            ])

            // Right-click a net line to remove the pin at its non-anchor
            // end from the net.
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

    // MARK: - Marquee

    @ViewBuilder private var marqueeOverlay: some View {
        if let m = marquee {
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .overlay(
                    Rectangle()
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.0, dash: [4, 3]))
                )
                .frame(width: m.rect.width, height: m.rect.height)
                .position(x: m.rect.midX, y: m.rect.midY)
                .allowsHitTesting(false)
        }
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                marquee = MarqueeRect(
                    startScreen: value.startLocation,
                    currentScreen: value.location
                )
            }
            .onEnded { value in
                defer { marquee = nil }
                let rect = MarqueeRect(
                    startScreen: value.startLocation,
                    currentScreen: value.location
                ).rect
                guard rect.width > 2 || rect.height > 2 else { return }
                applyMarquee(rect: rect, additive: NSEvent.modifierFlags.contains(.command))
            }
    }

    /// Includes a component if any of its pins falls inside the marquee — pin
    /// positions are what the user is visually aiming at, and they cover the
    /// component's footprint sufficiently for marquee selection.
    private func applyMarquee(rect: CGRect, additive: Bool) {
        var hits: Set<UUID> = []
        for component in document.circuit.logic.components {
            guard let center = document.circuit.schematic.position(for: component.id) else { continue }
            let metrics = ComponentSymbolMetrics.metrics(for: component.kind)
            // Use the component's bounding rect (centered on its schematic
            // position) as the hit area. Marquee that touches any pixel of
            // the symbol counts as hit.
            let halfW = metrics.size.width / 2
            let halfH = metrics.size.height / 2
            let bodyRect = CGRect(
                x: center.x - halfW, y: center.y - halfH,
                width: metrics.size.width, height: metrics.size.height
            )
            if rect.intersects(bodyRect) {
                hits.insert(component.id)
            }
        }
        var next = additive ? selection : SchematicSelection.none
        next.net = nil
        next.components.formUnion(hits)
        selection = next
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
            if selection.contains(net: killed) { selection.net = nil }
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
        for id in selection.components {
            deleteComponent(id)
        }
        if let netId = selection.net {
            deleteNet(netId)
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
