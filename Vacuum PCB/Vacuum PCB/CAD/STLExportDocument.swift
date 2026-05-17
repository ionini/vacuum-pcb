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
        // multi-solid STLs, so top + bottom go out as one file. `makeWatertight`
        // stitches hairline cracks Euclid's BSP CSG can leave where curved
        // surfaces meet flat ones — slicers refuse non-manifold STLs, so it has
        // to run on the export path. The preview path skips it because
        // SceneKit renders fine without manifoldness and stitching is one of
        // Euclid's heavier passes.
        let combined = Mesh.merge(meshes.map { $0.makeWatertight() })
        let data = combined.stlData()
        return FileWrapper(regularFileWithContents: data)
    }
}
