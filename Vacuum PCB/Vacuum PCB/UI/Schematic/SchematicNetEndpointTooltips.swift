import SwiftUI

/// Shared "what is this pin" labeling, so the pin hover chip
/// (`PinHandleView`) and the net-endpoint tooltips below render the same text.
enum SchematicPinDescriptor {
    /// User-facing pin name. Primitive pin keys are already friendly
    /// ("gate", "a", "1", "p"); subpart instance pin keys are port UUIDs, so
    /// we resolve them back to the boundary component's label; connectors map
    /// their numeric keys to the user-set pin name.
    static func name(_ component: Component, key: String, snapshots: [String: CircuitDocument]) -> String {
        if let pin = component.subpartBoundaryPin(key: key, snapshots: snapshots) {
            return pin.label
        }
        if component.kind == .connector {
            return component.connectorPinName(key)
        }
        return key
    }

    /// Short description of what the pin is for. Returns nil when the type
    /// would be redundant with the key (e.g. a resistor terminal named "1").
    static func type(_ component: Component, key: String, snapshots: [String: CircuitDocument]) -> String? {
        switch component.kind {
        case .transistor:
            switch key {
            case "gate": return "Gate"
            case "a", "b": return "Source/Drain"
            default: return nil
            }
        case .resistor: return nil
        case .vacuumSource: return "Vacuum rail"
        case .atmVent: return "Atm vent"
        case .port:
            switch component.portDirection {
            case .input:  return "Input port"
            case .output: return "Output port"
            case nil:     return "Port"
            }
        case .subpart:
            guard let pin = component.subpartBoundaryPin(key: key, snapshots: snapshots)
            else { return nil }
            switch pin.kind {
            case .port:
                return pin.label.uppercased().hasPrefix("IN")  ? "Input port"
                     : pin.label.uppercased().hasPrefix("OUT") ? "Output port"
                     : "Port"
            case .vacuumSource: return "Vacuum rail"
            case .atmVent:      return "Atm vent"
            default:            return nil
            }
        case .screw:
            return nil
        case .led:
            return "Indicator"
        case .connector:
            return "Connector pin \(key)"
        }
    }
}

/// Floating labels at the endpoints of the currently-hovered net. Lets the user
/// see *what's on both ends* of a connection without tracing the wire — and,
/// when an endpoint sits outside the viewport, the label is pinned to the
/// viewport edge in the endpoint's direction (with a small arrow) so the user
/// still learns where the wire leads.
///
/// Drawn in the canvas's *unscaled* (viewport) space rather than inside the
/// scaled subtree: the chips stay a fixed, readable size at any zoom, and edge
/// clamping is trivial against the known viewport rect.
struct SchematicNetEndpointTooltips: View {
    struct Endpoint: Identifiable {
        let id: PinRef
        let title: String
        let subtitle: String?
        /// Endpoint position in unscaled schematic coordinates.
        let point: CGPoint
    }

    let endpoints: [Endpoint]
    let zoom: Double
    let pan: CGSize
    let viewSize: CGSize

    /// Keep clamped chips clear of the viewport corners. Horizontal inset is
    /// wider since chips grow sideways with their label.
    private let insetX: CGFloat = 78
    private let insetY: CGFloat = 20

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(endpoints) { ep in
                let p = placement(for: ep.point)
                chip(ep, clamped: p.clamped, direction: p.direction)
                    .position(p.center)
            }
        }
        .frame(width: viewSize.width, height: viewSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Where to put a chip for an endpoint at `schematic` coords: at the
    /// projected screen point when it's on-screen (nudged up so it doesn't
    /// cover the pin), or clamped to the viewport edge in the endpoint's
    /// direction when it's off-screen.
    private func placement(for schematic: CGPoint) -> (center: CGPoint, clamped: Bool, direction: CGVector) {
        let screen = CGPoint(
            x: schematic.x * zoom + pan.width,
            y: schematic.y * zoom + pan.height
        )
        let minX = insetX, maxX = max(insetX, viewSize.width - insetX)
        let minY = insetY, maxY = max(insetY, viewSize.height - insetY)

        let cx = min(max(screen.x, minX), maxX)
        let cy = min(max(screen.y, minY), maxY)
        let clamped = abs(cx - screen.x) > 0.5 || abs(cy - screen.y) > 0.5

        if clamped {
            // Arrow points from the chip toward the true (off-screen) endpoint.
            return (CGPoint(x: cx, y: cy), true, CGVector(dx: screen.x - cx, dy: screen.y - cy))
        }
        // On-screen: sit a touch above the pin, kept inside the viewport.
        let lifted = max(minY, screen.y - 18)
        return (CGPoint(x: cx, y: lifted), false, .zero)
    }

    private func chip(_ ep: Endpoint, clamped: Bool, direction: CGVector) -> some View {
        HStack(spacing: 3) {
            if clamped {
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .rotationEffect(.radians(atan2(direction.dy, direction.dx)))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(ep.title)
                    .font(.system(size: 10, weight: .semibold))
                if let subtitle = ep.subtitle {
                    Text(subtitle)
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor.opacity(0.6), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        .transition(.opacity)
    }
}
