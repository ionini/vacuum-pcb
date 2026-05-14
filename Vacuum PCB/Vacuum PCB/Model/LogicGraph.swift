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
