import SwiftUI

/// Layout of one mating socket on a subpart's schematic symbol: where on
/// the symbol it sits (centre offset from the symbol's centre) and how
/// large the visible tab is. Used to draw the socket and to anchor mating
/// bus-lines.
struct SymbolSocketLayout {
    let connectorId: UUID
    let label: String
    let pinCount: Int
    /// Resolved pin names in pin order (mirrors `BoundarySocket.pinNames`),
    /// shown as the socket tab's tooltip so an imported connector's pin
    /// names stay visible in the parent design.
    let pinNames: [String]
    let role: ConnectorRole
    let side: SymbolSide
    /// Centre of the socket tab in symbol-local coordinates (origin at the
    /// symbol's centre).
    let centre: CGPoint
}

/// Schematic-side geometry of a component symbol — bounding box and pin offsets
/// relative to the symbol's center. Schematic positions are SwiftUI points, not
/// millimeters; this is purely view layout.
struct ComponentSymbolMetrics {
    var size: CGSize
    var pinOffsets: [String: CGPoint]
    /// Subpart sockets exposed for assembly-mode mating. Empty for every
    /// non-subpart component. Populated only when the resolved part has
    /// `.connector` primitives.
    var sockets: [SymbolSocketLayout] = []

    static func metrics(for kind: ComponentKind) -> ComponentSymbolMetrics {
        switch kind {
        case .transistor:
            return ComponentSymbolMetrics(
                size: CGSize(width: 80, height: 80),
                pinOffsets: [
                    "gate": CGPoint(x: -40, y: 0),
                    "a": CGPoint(x: 0, y: -40),
                    "b": CGPoint(x: 0, y: 40),
                ]
            )
        case .resistor:
            return ComponentSymbolMetrics(
                size: CGSize(width: 90, height: 30),
                pinOffsets: [
                    "1": CGPoint(x: -45, y: 0),
                    "2": CGPoint(x: 45, y: 0),
                ]
            )
        case .vacuumSource, .atmVent:
            return ComponentSymbolMetrics(
                size: CGSize(width: 60, height: 50),
                pinOffsets: ["p": CGPoint(x: 30, y: 0)]
            )
        case .port:
            return ComponentSymbolMetrics(
                size: CGSize(width: 60, height: 30),
                pinOffsets: ["p": CGPoint(x: 30, y: 0)]
            )
        case .subpart:
            // Subpart metrics are library-driven — go through
            // `metrics(for: Component)` to get a real layout.
            return ComponentSymbolMetrics(size: CGSize(width: 100, height: 80), pinOffsets: [:])
        case .screw:
            // Screws are mechanical only; never rendered on the schematic.
            // Return a small placeholder so any defensive call site still
            // gets a valid metrics object.
            return ComponentSymbolMetrics(size: CGSize(width: 24, height: 24), pinOffsets: [:])
        case .led:
            // Slightly bigger than the transistor so the LED stands out on
            // the schematic. Single pin on the left edge.
            return ComponentSymbolMetrics(
                size: CGSize(width: 90, height: 90),
                pinOffsets: ["p": CGPoint(x: -45, y: 0)]
            )
        case .connector:
            // Connector metrics need the instance's pin count — go through
            // `metrics(for: Component)` to lay pins out properly. Return a
            // minimal placeholder for defensive callers (matches the subpart
            // fallback above).
            return ComponentSymbolMetrics(size: CGSize(width: 70, height: 70), pinOffsets: [:])
        }
    }

    /// Connector symbol metrics. Rectangle with N pins arranged along the
    /// inward edge (-X side at r0); the outward edge (+X side) is the visual
    /// hint of "this is the side that protrudes off the plate". Vertical
    /// pitch follows the schematic's existing 28-point spacing.
    private static func connectorMetrics(pinCount: Int) -> ComponentSymbolMetrics {
        let n = max(1, pinCount)
        let spacing: CGFloat = 28
        let margin: CGFloat = 28
        let height = max(70, CGFloat(n) * spacing + margin)
        let width: CGFloat = 80
        let halfW = width / 2
        let band = CGFloat(n - 1) * spacing
        var offsets: [String: CGPoint] = [:]
        for i in 0..<n {
            let y = -band / 2 + CGFloat(i) * spacing
            offsets["\(i + 1)"] = CGPoint(x: -halfW, y: y)
        }
        return ComponentSymbolMetrics(size: CGSize(width: width, height: height), pinOffsets: offsets)
    }

    /// Library-aware metrics. For primitives this delegates to the kind-only
    /// version; for subparts it lays out one pin per `BoundaryPin`, grouping
    /// by side and spacing along that side. `snapshots` resolves the sub-part
    /// against the parent doc's pinned library copy — pass the parent
    /// document's `librarySnapshots` so the schematic symbol matches what the
    /// CAD pipeline will export.
    static func metrics(for component: Component, snapshots: [String: CircuitDocument] = [:]) -> ComponentSymbolMetrics {
        if component.kind == .connector {
            return connectorMetrics(pinCount: component.connectorPinCount ?? 1)
        }
        guard component.kind == .subpart,
              let part = component.resolvedPart(snapshots: snapshots)
        else { return metrics(for: component.kind) }
        return subpartMetrics(pins: part.pins, sockets: part.sockets)
    }

    private static func subpartMetrics(
        pins: [BoundaryPin],
        sockets: [BoundarySocket] = []
    ) -> ComponentSymbolMetrics {
        // Along-edge footprint each item claims. A pin keeps the schematic's
        // 28-pt pitch; a socket tab is 56 pt along its edge (see `socketTab`),
        // so it needs a wider slot with a little breathing room. Both pins
        // and sockets share an edge, so we pack them into one band per side —
        // otherwise a connector tab lands on top of a boundary-pin dot.
        let pinSlot: CGFloat = 28
        let socketSlot: CGFloat = 64
        let margin: CGFloat = 20
        let minSide: CGFloat = 70

        func pinsOn(_ side: SymbolSide) -> [BoundaryPin] { pins.filter { $0.side == side } }
        func socketsOn(_ side: SymbolSide) -> [BoundarySocket] {
            sockets.filter { $0.side == side }.sorted { $0.offsetFraction < $1.offsetFraction }
        }
        // Edge length needed to seat every pin and socket on that side.
        func edgeLength(_ side: SymbolSide) -> CGFloat {
            CGFloat(pinsOn(side).count) * pinSlot + CGFloat(socketsOn(side).count) * socketSlot
        }

        // Height accommodates the busier vertical side; width the busier
        // horizontal one. Slack via `margin` keeps the end items off the
        // corners.
        let height = max(minSide, max(edgeLength(.left), edgeLength(.right)) + margin)
        let width  = max(minSide, max(edgeLength(.top), edgeLength(.bottom)) + margin)
        let halfW = width / 2
        let halfH = height / 2

        var offsets: [String: CGPoint] = [:]
        var socketLayouts: [SymbolSocketLayout] = []

        // Pack one edge: sockets first (in board order), then pins, each
        // centred in its own slot with the whole band centred on the side.
        func layout(_ side: SymbolSide) {
            let total = edgeLength(side)
            var cursor = -total / 2
            func along(slot: CGFloat) -> CGFloat {
                defer { cursor += slot }
                return cursor + slot / 2
            }
            func point(_ a: CGFloat) -> CGPoint {
                switch side {
                case .left:   return CGPoint(x: -halfW, y: a)
                case .right:  return CGPoint(x: halfW, y: a)
                case .top:    return CGPoint(x: a, y: -halfH)
                case .bottom: return CGPoint(x: a, y: halfH)
                }
            }
            for socket in socketsOn(side) {
                socketLayouts.append(SymbolSocketLayout(
                    connectorId: socket.connectorId,
                    label: socket.label,
                    pinCount: socket.pinCount,
                    pinNames: socket.pinNames,
                    role: socket.role,
                    side: socket.side,
                    centre: point(along(slot: socketSlot))
                ))
            }
            for pin in pinsOn(side) {
                offsets[pin.portId.uuidString] = point(along(slot: pinSlot))
            }
        }
        layout(.left)
        layout(.right)
        layout(.top)
        layout(.bottom)

        return ComponentSymbolMetrics(
            size: CGSize(width: width, height: height),
            pinOffsets: offsets,
            sockets: socketLayouts
        )
    }

    func pinOffset(_ key: String) -> CGPoint {
        pinOffsets[key] ?? .zero
    }

    /// Returns a copy reoriented by `quarterTurns` 90° clockwise steps. Pin
    /// offsets and socket centres rotate by `(x,y) → (-y,x)` (screen coords,
    /// y-down), the bounding `size` swaps width/height on odd turns so pins
    /// stay glued to the symbol edges, and each socket's `side` follows. The
    /// symbol's label is drawn separately and intentionally NOT rotated, so
    /// text stays upright. The single source of truth for schematic rotation —
    /// every pin-position consumer threads the component's rotation through here.
    func rotated(by quarterTurns: Int) -> ComponentSymbolMetrics {
        let q = ((quarterTurns % 4) + 4) % 4
        guard q != 0 else { return self }
        func rot(_ p: CGPoint) -> CGPoint {
            switch q {
            case 1:  return CGPoint(x: -p.y, y: p.x)
            case 2:  return CGPoint(x: -p.x, y: -p.y)
            default: return CGPoint(x: p.y, y: -p.x)
            }
        }
        let newSize = (q % 2 == 1)
            ? CGSize(width: size.height, height: size.width)
            : size
        let newSockets = sockets.map { s in
            SymbolSocketLayout(
                connectorId: s.connectorId,
                label: s.label,
                pinCount: s.pinCount,
                pinNames: s.pinNames,
                role: s.role,
                side: s.side.rotated(by: q),
                centre: rot(s.centre)
            )
        }
        return ComponentSymbolMetrics(
            size: newSize,
            pinOffsets: pinOffsets.mapValues(rot),
            sockets: newSockets
        )
    }
}

/// Visual symbol of one component on the schematic. Drawn as a stylized shape
/// matching the kind, with the component label inside.
struct ComponentSymbolView: View {
    let component: Component
    let isSelected: Bool
    /// Schematic orientation in 90° clockwise quarter-turns. Rotates the
    /// symbol's box + pins/sockets; the label text stays upright.
    var rotationQuarterTurns: Int = 0
    @Environment(\.librarySnapshots) private var librarySnapshots

    private var metrics: ComponentSymbolMetrics {
        ComponentSymbolMetrics.metrics(for: component, snapshots: librarySnapshots)
            .rotated(by: rotationQuarterTurns)
    }

    /// Boundary-pin label lookup for subparts — keyed by the pin's UUID
    /// string. Returns nil for primitive pins, which carry their own glyphs
    /// (no boundary-pin label needed).
    private var boundaryPinLabel: (String) -> String? {
        guard component.kind == .subpart,
              let part = component.resolvedPart(snapshots: librarySnapshots)
        else { return { _ in nil } }
        let map = Dictionary(uniqueKeysWithValues: part.pins.map { ($0.portId.uuidString, $0.label) })
        return { map[$0] }
    }

    var body: some View {
        let m = metrics
        return ZStack {
            symbolShape
                .fill(fillColor)
                .overlay(symbolShape.stroke(strokeColor, lineWidth: isSelected ? 2.5 : 1.5))
                .frame(width: m.size.width, height: m.size.height)
            label
            // Subpart mating sockets render as labeled tabs on the
            // appropriate edge. Inert in V1 — selection / drag / mating
            // happen through the inspector (creating + un-mating).
            ForEach(Array(m.sockets.enumerated()), id: \.offset) { _, socket in
                socketTab(socket)
                    .offset(x: socket.centre.x, y: socket.centre.y)
            }
        }
        .frame(width: m.size.width, height: m.size.height)
    }

    /// Renders one mating socket as a small labeled tab on the subpart
    /// symbol's relevant edge. The tab body is oriented perpendicular to
    /// the side it sits on (wider along the side, thinner pointing
    /// outward) so it reads as "this is the connector mounted on this
    /// edge". Role glyph (▼ bottom-extend / ▲ top-extend) sits next to
    /// the pin-count label.
    private func socketTab(_ socket: SymbolSocketLayout) -> some View {
        let width: CGFloat
        let height: CGFloat
        switch socket.side {
        case .top, .bottom: width = 56; height = 18
        case .left, .right: width = 18; height = 56
        }
        let roleGlyph = socket.role == .bottomExtend ? "▼" : "▲"
        return RoundedRectangle(cornerRadius: 3)
            .fill(Color.indigo.opacity(0.30))
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(Color.indigo.opacity(0.65), lineWidth: 1))
            .frame(width: width, height: height)
            .overlay(
                Text("\(socket.label) \(roleGlyph)\(socket.pinCount)")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Color.indigo)
                    .lineLimit(1)
                    .fixedSize()
            )
            .help(socketTooltip(socket))
    }

    /// Lists the imported connector's pins (number → name) so the names are
    /// reachable from the parent design without opening the source part.
    private func socketTooltip(_ socket: SymbolSocketLayout) -> String {
        let pins = socket.pinNames.enumerated()
            .map { "\($0.offset + 1): \($0.element)" }
            .joined(separator: "\n")
        return "\(socket.label) — \(socket.pinCount) pins\n\(pins)"
    }

    private var symbolShape: AnyShape {
        switch component.kind {
        case .transistor: AnyShape(Circle())
        case .resistor:   AnyShape(RoundedRectangle(cornerRadius: 6))
        case .vacuumSource, .atmVent, .port:
                          AnyShape(RoundedRectangle(cornerRadius: 4))
        case .subpart:    AnyShape(RoundedRectangle(cornerRadius: 6))
        case .screw:      AnyShape(Circle())
        case .led:        AnyShape(Circle())
        case .connector:  AnyShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    @ViewBuilder private var label: some View {
        VStack(spacing: 0) {
            Text(component.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            if component.kind == .resistor, let size = component.resistorSize {
                Text(size.rawValue)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            if component.kind == .vacuumSource {
                Text("VAC").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if component.kind == .atmVent {
                Text("ATM").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if component.kind == .port, let dir = component.portDirection {
                Text(dir == .input ? "IN" : "OUT")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if component.kind == .subpart {
                Text(component.partRef.map(displayName(forFilename:)) ?? "missing part")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if component.kind == .led {
                Text("LED").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if component.kind == .connector {
                let n = component.connectorPinCount ?? 1
                let roleTag = (component.connectorRole ?? .bottomExtend) == .bottomExtend ? "▼" : "▲"
                Text("\(n)P \(roleTag)").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private func displayName(forFilename name: String) -> String {
        name.lowercased().hasSuffix(".vpcb") ? String(name.dropLast(5)) : name
    }

    private var fillColor: Color {
        switch component.kind {
        case .transistor:    return Color.blue.opacity(0.18)
        case .resistor:      return Color.orange.opacity(0.20)
        case .vacuumSource:  return Color.red.opacity(0.18)
        case .atmVent:       return Color.green.opacity(0.18)
        case .port:          return Color.purple.opacity(0.18)
        case .subpart:       return Color.teal.opacity(0.18)
        case .screw:         return Color.gray.opacity(0.25)
        case .led:           return Color.yellow.opacity(0.30)
        case .connector:     return Color.indigo.opacity(0.18)
        }
    }

    private var strokeColor: Color {
        isSelected ? Color.accentColor : Color.primary.opacity(0.6)
    }
}
