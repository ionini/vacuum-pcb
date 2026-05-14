import SwiftUI
import UniformTypeIdentifiers
import Euclid

extension UTType {
    static let stl: UTType = UTType(filenameExtension: "stl") ?? .data
}

/// Transient FileDocument used by `.fileExporter` to save built plate meshes as a
/// single binary STL. Reading is unsupported — this document type only writes.
struct STLExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.stl] }
    static var writableContentTypes: [UTType] { [.stl] }

    let meshes: [Mesh]

    init(meshes: [Mesh]) {
        self.meshes = meshes
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Mesh.merge concatenates polygons without doing CSG. Slicers happily handle
        // multi-solid STLs, so top + bottom go out as one file.
        let combined = Mesh.merge(meshes)
        let data = combined.stlData()
        return FileWrapper(regularFileWithContents: data)
    }
}
