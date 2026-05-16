import Foundation

enum ComponentKind: String, Codable, CaseIterable {
    case transistor
    case resistor
    case vacuumSource
    case atmVent
    case port
    /// Instance of a reusable circuit defined in another `.vpcb` file in the
    /// parts library. The instance reads its pin layout and internal geometry
    /// from `partRef` on each open — by-reference, not embedded.
    case subpart
    /// Mechanical fastener punched through both plates: countersink head
    /// cavity on the top, clearance bore through to the bottom, hex-nut
    /// pocket on the underside. No pins; doesn't participate in the
    /// netlist. Placed and dragged on the physical canvas only.
    case screw
    /// Visual indicator. Same dimple-on-the-placement-layer construction
    /// as a transistor's gate (without source/drain pads), plus a
    /// cylindrical viewing hole through the opposite plate so the
    /// silicone deflection is visible from outside. One fluid pin; when
    /// the net is at vacuum the silicone gets sucked into the dimple
    /// (LED "on"); at atmosphere it sits flat (LED "off").
    case led
}

enum ResistorSize: String, Codable, CaseIterable {
    case small = "S"
    case medium = "M"
    case large = "L"
}

enum PortDirection: String, Codable, CaseIterable {
    case input
    case output
}

struct Component: Codable, Identifiable, Hashable {
    var id: UUID
    var kind: ComponentKind
    var label: String
    var resistorSize: ResistorSize?
    var portDirection: PortDirection?
    /// Filename (relative to the user's parts folder) of the library .vpcb this
    /// instance references. Only meaningful for `.subpart`. Filename-only is
    /// deliberate: rename = relink.
    var partRef: String?

    init(
        id: UUID = UUID(),
        kind: ComponentKind,
        label: String,
        resistorSize: ResistorSize? = nil,
        portDirection: PortDirection? = nil,
        partRef: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.resistorSize = resistorSize
        self.portDirection = portDirection
        self.partRef = partRef
    }
}

struct PinRef: Codable, Hashable {
    var componentId: UUID
    var pinKey: String
}

struct Net: Codable, Identifiable, Hashable {
    var id: UUID
    var label: String
    var pins: [PinRef]

    init(id: UUID = UUID(), label: String, pins: [PinRef]) {
        self.id = id
        self.label = label
        self.pins = pins
    }
}

struct LogicGraph: Codable, Hashable {
    var components: [Component]
    var nets: [Net]
}

extension LogicGraph {
    /// Picks the next unused label for a new component of `kind`.
    ///
    /// Transistors / resistors / ports always carry a numeric suffix (Q1, R1, IN1, OUT1).
    /// Rails (VAC, VENT) prefer the bare prefix when available, falling back to a
    /// numbered form when there's already one on the canvas. Whitespace-significant
    /// matches against existing labels so user-renamed components don't collide.
    func nextLabel(for kind: ComponentKind, portDirection: PortDirection? = nil) -> String {
        let used = Set(components.map(\.label))
        let prefix: String
        let allowUnnumbered: Bool
        switch kind {
        case .transistor:    prefix = "Q";    allowUnnumbered = false
        case .resistor:      prefix = "R";    allowUnnumbered = false
        case .vacuumSource:  prefix = "VAC";  allowUnnumbered = true
        case .atmVent:       prefix = "VENT"; allowUnnumbered = true
        case .port:
            switch portDirection {
            case .input:  prefix = "IN";  allowUnnumbered = false
            case .output: prefix = "OUT"; allowUnnumbered = false
            case nil:     prefix = "P";   allowUnnumbered = false
            }
        case .subpart:
            prefix = "U"; allowUnnumbered = false
        case .screw:
            prefix = "S"; allowUnnumbered = false
        case .led:
            prefix = "D"; allowUnnumbered = false
        }
        if allowUnnumbered, !used.contains(prefix) {
            return prefix
        }
        var n = 1
        while used.contains("\(prefix)\(n)") { n += 1 }
        return "\(prefix)\(n)"
    }

    /// Picks the next unused net label (n1, n2, ...).
    func nextNetLabel() -> String {
        let used = Set(nets.map(\.label))
        var n = 1
        while used.contains("n\(n)") { n += 1 }
        return "n\(n)"
    }
}
