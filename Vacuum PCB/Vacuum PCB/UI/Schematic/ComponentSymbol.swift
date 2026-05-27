import SwiftUI

/// Schematic-side geometry of a component symbol — bounding box and pin offsets
/// relative to the symbol's center. Schematic positions are SwiftUI points, not
/// millimeters; this is purely view layout.
struct ComponentSymbolMetrics {
    var size: CGSize
    var pinOffsets: [String: CGPoint]

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
        return subpartMetrics(pins: part.pins)
    }

    private static func subpartMetrics(pins: [BoundaryPin]) -> ComponentSymbolMetrics {
        let spacing: CGFloat = 28
        let margin: CGFloat = 20
        let minSide: CGFloat = 70

        let left   = pins.filter { $0.side == .left   }
        let right  = pins.filter { $0.side == .right  }
        let top    = pins.filter { $0.side == .top    }
        let bottom = pins.filter { $0.side == .bottom }

        // Height must accommodate the tallest vertical side; width similarly
        // for top/bottom. Add slack for label centerline.
        let vertCount = CGFloat(max(left.count, right.count))
        let horzCount = CGFloat(max(top.count, bottom.count))
        let height = max(minSide, vertCount * spacing + margin)
        let width  = max(minSide, horzCount * spacing + margin)

        let halfW = width / 2
        let halfH = height / 2

        var offsets: [String: CGPoint] = [:]
        // Helper: position the i-th pin out of n along a side. We centre the
        // pin band on the side and step `spacing` apart.
        func place(side group: [BoundaryPin], onSide side: SymbolSide) {
            let n = group.count
            guard n > 0 else { return }
            let band = CGFloat(n - 1) * spacing
            for (i, pin) in group.enumerated() {
                let along = -band / 2 + CGFloat(i) * spacing
                let key = pin.portId.uuidString
                switch side {
                case .left:   offsets[key] = CGPoint(x: -halfW, y: along)
                case .right:  offsets[key] = CGPoint(x: halfW, y: along)
                case .top:    offsets[key] = CGPoint(x: along, y: -halfH)
                case .bottom: offsets[key] = CGPoint(x: along, y: halfH)
                }
            }
        }
        place(side: left, onSide: .left)
        place(side: right, onSide: .right)
        place(side: top, onSide: .top)
        place(side: bottom, onSide: .bottom)

        return ComponentSymbolMetrics(size: CGSize(width: width, height: height), pinOffsets: offsets)
    }

    func pinOffset(_ key: String) -> CGPoint {
        pinOffsets[key] ?? .zero
    }
}

/// Visual symbol of one component on the schematic. Drawn as a stylized shape
/// matching the kind, with the component label inside.
struct ComponentSymbolView: View {
    let component: Component
    let isSelected: Bool
    @Environment(\.librarySnapshots) private var librarySnapshots

    private var metrics: ComponentSymbolMetrics {
        ComponentSymbolMetrics.metrics(for: component, snapshots: librarySnapshots)
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
        }
        .frame(width: m.size.width, height: m.size.height)
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
