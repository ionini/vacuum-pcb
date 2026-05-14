import Foundation

struct CircuitDocument: Codable, Hashable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var manufacturing: ManufacturingConstants
    var logic: LogicGraph
    var physical: PhysicalLayout

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        manufacturing: ManufacturingConstants = .defaults,
        logic: LogicGraph,
        physical: PhysicalLayout
    ) {
        self.schemaVersion = schemaVersion
        self.manufacturing = manufacturing
        self.logic = logic
        self.physical = physical
    }
}

extension CircuitDocument {
    static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let jsonDecoder = JSONDecoder()

    func encoded() throws -> Data {
        try Self.jsonEncoder.encode(self)
    }

    static func decoded(from data: Data) throws -> CircuitDocument {
        try jsonDecoder.decode(CircuitDocument.self, from: data)
    }
}
