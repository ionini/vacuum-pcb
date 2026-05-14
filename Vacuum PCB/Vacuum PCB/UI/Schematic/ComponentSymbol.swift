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
                    "gate": CGPoint(x: -40, y:   0),
                    "a":    CGPoint(x:   0, y: -40),
                    "b":    CGPoint(x:   0, y:  40),
                ]
            )
        case .resistor:
            return ComponentSymbolMetrics(
                size: CGSize(width: 90, height: 30),
                pinOffsets: [
                    "1": CGPoint(x: -45, y: 0),
                    "2": CGPoint(x:  45, y: 0),
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
        }
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

    private var metrics: ComponentSymbolMetrics {
        ComponentSymbolMetrics.metrics(for: component.kind)
    }

    var body: some View {
        ZStack {
            symbolShape
                .fill(fillColor)
                .overlay(symbolShape.stroke(strokeColor, lineWidth: isSelected ? 2.5 : 1.5))
                .frame(width: metrics.size.width, height: metrics.size.height)
            label
        }
        .frame(width: metrics.size.width, height: metrics.size.height)
    }

    private var symbolShape: AnyShape {
        switch component.kind {
        case .transistor: AnyShape(Circle())
        case .resistor:   AnyShape(RoundedRectangle(cornerRadius: 6))
        case .vacuumSource, .atmVent, .port:
                          AnyShape(RoundedRectangle(cornerRadius: 4))
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
        }
    }

    private var fillColor: Color {
        switch component.kind {
        case .transistor:    return Color.blue.opacity(0.18)
        case .resistor:      return Color.orange.opacity(0.20)
        case .vacuumSource:  return Color.red.opacity(0.18)
        case .atmVent:       return Color.green.opacity(0.18)
        case .port:          return Color.purple.opacity(0.18)
        }
    }

    private var strokeColor: Color {
        isSelected ? Color.accentColor : Color.primary.opacity(0.6)
    }
}

