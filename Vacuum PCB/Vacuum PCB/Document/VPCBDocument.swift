import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Custom UTI for `.vpcb` design files. Conforms to JSON so generic JSON tooling
    /// can still inspect them. Not declared in Info.plist for MVP — works for in-app
    /// pickers but won't be recognized by Finder system-wide.
    static let vacuumPCB = UTType(exportedAs: "com.ionini.vacuum-pcb", conformingTo: .json)
}

struct VPCBDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.vacuumPCB, .json] }
    static var writableContentTypes: [UTType] { [.vacuumPCB] }

    var circuit: CircuitDocument

    init() {
        self.circuit = .blank()
    }

    init(circuit: CircuitDocument) {
        self.circuit = circuit
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.circuit = try CircuitDocument.decoded(from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try circuit.encoded()
        return FileWrapper(regularFileWithContents: data)
    }
}

extension CircuitDocument {
    /// Empty starting document used when the user chooses File → New.
    static func blank() -> CircuitDocument {
        CircuitDocument(
            logic: LogicGraph(components: [], nets: []),
            physical: PhysicalLayout(
                placements: [],
                routes: [],
                boardOutline: Rect(origin: .zero, size: Size(width: 50, height: 30))
            )
        )
    }
}
