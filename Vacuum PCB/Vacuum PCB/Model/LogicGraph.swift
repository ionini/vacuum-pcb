import Foundation

enum ComponentKind: String, Codable, CaseIterable {
    case transistor
    case resistor
    case vacuumSource
    case atmVent
    case port
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

    init(
        id: UUID = UUID(),
        kind: ComponentKind,
        label: String,
        resistorSize: ResistorSize? = nil,
        portDirection: PortDirection? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.resistorSize = resistorSize
        self.portDirection = portDirection
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
