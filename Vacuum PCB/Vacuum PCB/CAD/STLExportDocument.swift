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

    /// The single multi-solid, watertight mesh the STL export ships for a set
    /// of separate printed bodies (top/bottom plate, stencil, mold frame).
    ///
    /// The bodies are separate printed solids, so we concatenate their polygons
    /// into one multi-solid mesh — slicers happily handle multi-solid STLs.
    /// `Mesh(_:)` just stores the polygons; we deliberately avoid `Mesh.merge`,
    /// which runs a boolean CSG union whenever bodies' bounds overlap (top/bottom
    /// plates are concentric), wasting time fusing solids we want kept separate.
    /// `makeWatertight` stitches the hairline cracks Euclid's BSP CSG can leave
    /// where curved surfaces meet flat ones — slicers refuse non-manifold STLs,
    /// so it has to run on the export path. The preview path skips it because
    /// SceneKit renders fine without manifoldness and stitching is one of
    /// Euclid's heavier passes.
    ///
    /// Shared by the `.fileExporter` "Save STL" path and the Bambu Studio export
    /// (`BambuExport`) so the Bambu *model* file is byte-identical to a plain
    /// "Save STL".
    static func combinedModelMesh(_ meshes: [Mesh]) -> Mesh {
        Mesh(meshes.filter { !$0.isEmpty }.flatMap { $0.makeWatertight().polygons })
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = Self.combinedModelMesh(meshes).stlData()
        return FileWrapper(regularFileWithContents: data)
    }
}

/// Transient FileDocument used by `.fileExporter` to write a Bambu Studio export
/// *directory* containing the model STL, the aligned print-critical modifier
/// STL, and (optionally) a small JSON manifest. Reading is unsupported.
///
/// The file contents are prebuilt (off the main thread) and handed in as
/// `filename → Data`, so `fileWrapper` only has to assemble the directory —
/// no CSG runs at save time.
struct BambuExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }
    static var writableContentTypes: [UTType] { [.folder] }

    let files: [(name: String, data: Data)]

    init(files: [(name: String, data: Data)]) {
        self.files = files
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        var children: [String: FileWrapper] = [:]
        for file in files {
            let wrapper = FileWrapper(regularFileWithContents: file.data)
            wrapper.preferredFilename = file.name
            children[file.name] = wrapper
        }
        return FileWrapper(directoryWithFileWrappers: children)
    }
}
