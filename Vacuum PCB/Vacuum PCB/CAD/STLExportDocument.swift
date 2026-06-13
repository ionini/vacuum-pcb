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
        // The bodies are separate printed solids, so we concatenate their
        // polygons into one multi-solid mesh — slicers happily handle multi-solid
        // STLs. `Mesh(_:)` just stores the polygons; we deliberately avoid
        // `Mesh.merge`, which runs a boolean CSG union whenever bodies' bounds
        // overlap (top/bottom plates are concentric), wasting time fusing solids
        // we want kept separate. `makeWatertight` stitches the hairline cracks
        // Euclid's BSP CSG can leave where curved surfaces meet flat ones —
        // slicers refuse non-manifold STLs, so it has to run on the export path.
        // The preview path skips it because SceneKit renders fine without
        // manifoldness and stitching is one of Euclid's heavier passes.
        let combined = Mesh(meshes.flatMap { $0.makeWatertight().polygons })
        let data = combined.stlData()
        return FileWrapper(regularFileWithContents: data)
    }
}
