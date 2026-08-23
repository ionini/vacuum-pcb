import Foundation
import Euclid

/// "Export for Bambu Studio": produces one printable model STL **per plate**,
/// each with its own aligned print-critical *modifier* STL (and an optional
/// JSON manifest). Every plate loads into Bambu Studio as its own multipart
/// object, so the two plates stay separable — arrange them independently or
/// print them in separate jobs.
///
/// The model STLs carry the plates **already laid out for printing** —
/// side by side on the bed (z = 0), the bottom plate flipped to its
/// print orientation (silicone face down, channel arches up) — so each object
/// slices as-is, with **no "Split objects" step** (splitting a multipart
/// object is what detaches modifiers from their model). Each plate's modifier
/// shells receive exactly the same rigid transform as their plate, so model
/// and modifier stay aligned part for part.
///
/// The stencil (silicone cutting template) and mold frame have no pneumatic
/// features, so they ship as separate plain STLs — import them as their own
/// objects whenever you print them, and arrange freely.
///
/// Workflow, once per plate: select `<base>_top_model.stl` and
/// `<base>_top_modifier.stl` together, answer "Yes" to load them as a single
/// object, switch the `_modifier` part to a Modifier — then repeat for the
/// `_bottom` pair. Never select both plates' files in one go: Bambu's
/// load-together prompt folds the whole selection into ONE object, which is
/// exactly the inseparable-plates problem the per-plate pairs exist to fix.
enum BambuExport {

    /// Bed gap between laid-out bodies, mm.
    static let layoutGap = 10.0

    /// Which region the `_modifier` STL claims.
    ///
    /// `.pneumatics` (the original): the envelope AROUND the channels/valves/
    /// vias — assign it print-critical settings (more walls, solid infill)
    /// while the global preset stays light.
    ///
    /// `.voids` (inverted): the complement — everything that is NOT pneumatic
    /// envelope, screw clamp zone or connector footprint. The global preset
    /// (the validated airtight one) keeps governing the important regions and
    /// the modifier only downgrades the filler (e.g. low sparse infill).
    /// Fail-safe: losing the modifier merely wastes material, it cannot make
    /// a board leak.
    enum ModifierStyle: String {
        case pneumatics
        case voids
    }

    // MARK: - File names

    static func modelFilename(_ base: String, plate: Plate) -> String {
        "\(base)_\(plate.rawValue)_model.stl"
    }
    static func modifierFilename(_ base: String, plate: Plate) -> String {
        "\(base)_\(plate.rawValue)_modifier.stl"
    }
    static func stencilFilename(_ base: String) -> String { "\(base)_stencil.stl" }
    /// One gasket stencil per `.bottomExtend` connector; `name` is the
    /// connector's (deduplicated) label from `PlateBuilder`, sanitized here
    /// the same way the base is so any label makes a legal filename.
    static func connectorStencilFilename(_ base: String, connector name: String) -> String {
        "\(base)_stencil_\(sanitizedBaseName(name)).stl"
    }
    static func moldFilename(_ base: String) -> String { "\(base)_mold.stl" }
    static func manifestFilename(_ base: String) -> String { "\(base)_bambu_export.json" }

    /// A filesystem-safe base name derived from a board / file name (drops any
    /// directory + extension, maps anything but letters/digits/-/_ to "_").
    static func sanitizedBaseName(_ raw: String) -> String {
        let stem = (raw as NSString).lastPathComponent
        let noExt = (stem as NSString).deletingPathExtension
        let cleaned = noExt.isEmpty ? stem : noExt
        let safe = String(cleaned.map { ch in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_" ? ch : "_"
        })
        return safe.isEmpty ? "vacuum-pcb" : safe
    }

    // MARK: - Bodies / meshes

    /// The separate printed solids the model STL ships, in the GUI's order,
    /// empty bodies dropped. Mirrors `STLExportDocument` and the CLI `export`.
    static func modelBodies(_ out: PlateBuilder.Output) -> [Mesh] {
        ([out.topPlate, out.bottomPlate, out.stencil]
         + out.connectorStencils.map(\.mesh)
         + [out.moldFrame]).filter { !$0.isEmpty }
    }

    /// The single multi-solid, watertight model mesh in *design* space —
    /// byte-identical to what a plain "Save STL" writes (shared
    /// `combinedModelMesh`). Not what the Bambu model file ships (that one is
    /// laid out for printing, see `printLayout`); kept as the parity reference.
    static func modelMesh(_ out: PlateBuilder.Output) -> Mesh {
        STLExportDocument.combinedModelMesh(modelBodies(out))
    }

    /// One printed body posed for the bed, with its (optional) modifier
    /// envelope carrying the identical rigid transform. `plate` is set for
    /// the two plate bodies (each becomes its own Bambu object with its own
    /// modifier) and nil for the stencil / mold.
    struct LayoutBody {
        var name: String
        var plate: Plate?
        var model: Mesh
        var modifier: Mesh?
    }

    /// Poses every printable body for the bed: each is dropped so it rests on
    /// z = 0 and shifted along +X into a row (`layoutGap` apart, min corner at
    /// y = 0), in a fixed order (top plate, bottom plate, stencil, mold) so
    /// output is deterministic. The bottom plate is first rotated a half turn
    /// about X — its print orientation (silicone face down, channel arches
    /// up), the flip the user otherwise applies by hand in the slicer.
    ///
    /// Rigid transforms only (rotation + translation, never mirroring), and
    /// each plate's modifier gets its plate's exact transform — that is what
    /// keeps model and modifier aligned after layout. Translation is computed
    /// from the *model* body's post-rotation bounds, so a modifier margin
    /// poking past a plate face can't shift the plate's bed position.
    ///
    /// `modifierPlates` limits which plates get a modifier *built* (the voids
    /// style is real CSG, so a single-plate open skips the other plate's
    /// work); every body is still posed, so positions are identical whichever
    /// subset is requested.
    static func printLayout(
        _ out: PlateBuilder.Output, doc: CircuitDocument,
        margins: PlateBuilder.ModifierMargins,
        style: ModifierStyle = .pneumatics,
        modifierPlates: Set<Plate> = [.top, .bottom]
    ) -> [LayoutBody] {
        let flip = Euclid.Rotation.pitch(.pi)
        func plateModifier(_ plate: Plate) -> Mesh? {
            guard modifierPlates.contains(plate) else { return nil }
            switch style {
            case .pneumatics:
                return PlateBuilder.buildModifier(doc, margins: margins, plate: plate)
            case .voids:
                return PlateBuilder.buildInvertedModifier(doc, margins: margins, plate: plate)
            }
        }
        let posed: [(name: String, plate: Plate?, model: Mesh, modifier: Mesh?, rotation: Euclid.Rotation?)] =
            [
                ("top", .top, out.topPlate, plateModifier(.top), nil),
                ("bottom", .bottom, out.bottomPlate, plateModifier(.bottom), flip),
                ("stencil", nil, out.stencil, nil, nil),
            ]
            // One gasket stencil per `.bottomExtend` connector, posed like the
            // board stencil. The `stencil_` prefix is what `payload` keys the
            // per-connector filenames off.
            + out.connectorStencils.map { ("stencil_\($0.name)", nil, $0.mesh, nil, nil) }
            + [("mold", nil, out.moldFrame, nil, nil)]
        var xCursor = 0.0
        var bodies: [LayoutBody] = []
        for entry in posed where !entry.model.isEmpty {
            // Watertight before posing so the model solids ship slicer-clean,
            // exactly like the plain export path.
            var model = entry.model.makeWatertight()
            var modifier = entry.modifier
            if let rotation = entry.rotation {
                model = model.rotated(by: rotation)
                modifier = modifier?.rotated(by: rotation)
            }
            let bb = model.bounds
            let t = Vector(xCursor - bb.min.x, -bb.min.y, -bb.min.z)
            model = model.translated(by: t)
            modifier = modifier?.translated(by: t)
            bodies.append(LayoutBody(
                name: entry.name,
                plate: entry.plate,
                model: model,
                modifier: (modifier?.polygons.isEmpty ?? true) ? nil : modifier
            ))
            xCursor += (bb.max.x - bb.min.x) + layoutGap
        }
        return bodies
    }

    // MARK: - Manifest

    /// The optional manifest naming the files and recording the margins used.
    /// Hand-rolled with a fixed key order so the bytes are deterministic and
    /// the shape matches the documented example. `objects` lists one entry
    /// per plate — its model file plus its modifier file (`null` when the
    /// plate has no pneumatic features to envelope).
    static func manifestData(
        base: String, objects: [PlateObject],
        margins: PlateBuilder.ModifierMargins,
        style: ModifierStyle = .pneumatics,
        hasStencil: Bool, connectorStencilFiles: [String] = [], hasMold: Bool
    ) -> Data {
        let objectLines = objects.map { o -> String in
            let modifier = o.modifierFilename.map { "\"\($0)\"" } ?? "null"
            return "    { \"name\": \"\(o.plate.rawValue)\", " +
                   "\"model\": \"\(o.modelFilename)\", \"modifier\": \(modifier) }"
        }.joined(separator: ",\n")
        var extra = ""
        if hasStencil { extra += "\n  \"stencil\": \"\(stencilFilename(base))\"," }
        if !connectorStencilFiles.isEmpty {
            let list = connectorStencilFiles.map { "\"\($0)\"" }.joined(separator: ", ")
            extra += "\n  \"connectorStencils\": [\(list)],"
        }
        if hasMold { extra += "\n  \"mold\": \"\(moldFilename(base))\"," }
        let json = """
        {
          "units": "millimeters",
          "layout": "print",
          "objects": [
        \(objectLines)
          ],\(extra)
          "modifierStyle": "\(style.rawValue)",
          "modifierMarginXY": \(margins.xy),
          "modifierMarginZ": \(margins.z)
        }
        """
        return Data(json.utf8)
    }

    // MARK: - Payload

    /// One plate as its own Bambu Studio multipart object: the plate's model
    /// file plus (when the plate has pneumatic features and its modifier was
    /// requested via `modifierPlates`) the aligned modifier file.
    struct PlateObject {
        var plate: Plate
        var modelFilename: String
        var modifierFilename: String?
        var modelMesh: Mesh
        var modifierMesh: Mesh?
    }

    /// The prebuilt contents of a Bambu export, ready to write to disk or hand
    /// to a `BambuExportDocument`.
    ///
    /// `objects` holds one entry per plate — each names the model + modifier
    /// pair Bambu Studio loads as ONE multipart object; keeping the plates as
    /// two objects is what lets them be arranged and printed independently.
    /// The stencil/mold files, when present, are in `files` only.
    struct Payload {
        var files: [(name: String, data: Data)]
        var objects: [PlateObject]
    }

    /// Builds every file's contents for `doc`. Runs the CAD pipeline (CSG), so
    /// call it off the main thread. Pass `prebuiltModel` (the preview's already
    /// computed `Output`) to skip rebuilding the model plates; restrict
    /// `modifierPlates` when only one plate's pair will be used (skips the
    /// other plate's modifier CSG, everything else stays byte-identical).
    static func payload(
        doc: CircuitDocument,
        baseName: String,
        margins: PlateBuilder.ModifierMargins = .defaults,
        style: ModifierStyle = .pneumatics,
        includeManifest: Bool = true,
        prebuiltModel: PlateBuilder.Output? = nil,
        modifierPlates: Set<Plate> = [.top, .bottom]
    ) -> Payload {
        let out = prebuiltModel ?? PlateBuilder.build(doc)
        let bodies = printLayout(out, doc: doc, margins: margins, style: style,
                                 modifierPlates: modifierPlates)
        // A model + modifier pair per plate (each file a multi-solid polygon
        // concatenation like the plain export). No `makeWatertight` on the
        // modifiers: their shells are meant to overlap and slicers union them
        // per layer, so stitching is both unnecessary and would risk
        // non-determinism.
        var files: [(name: String, data: Data)] = []
        var objects: [PlateObject] = []
        for body in bodies {
            guard let plate = body.plate else { continue }
            let modelName = modelFilename(baseName, plate: plate)
            files.append((modelName, body.model.stlData()))
            var modifierName: String?
            if let modifier = body.modifier {
                let name = modifierFilename(baseName, plate: plate)
                modifierName = name
                files.append((name, modifier.stlData()))
            }
            objects.append(PlateObject(
                plate: plate,
                modelFilename: modelName, modifierFilename: modifierName,
                modelMesh: body.model, modifierMesh: body.modifier))
        }
        // Stencil + connector gasket stencils + mold: separate plain objects
        // (no pneumatics → no modifier), so they never join a multipart
        // object and can be arranged / printed independently.
        var hasStencil = false, hasMold = false
        var connectorStencilFiles: [String] = []
        for body in bodies where body.plate == nil {
            if body.name == "stencil" {
                hasStencil = true
                files.append((stencilFilename(baseName), body.model.stlData()))
            } else if body.name.hasPrefix("stencil_") {
                let name = connectorStencilFilename(
                    baseName, connector: String(body.name.dropFirst("stencil_".count)))
                connectorStencilFiles.append(name)
                files.append((name, body.model.stlData()))
            } else {
                hasMold = true
                files.append((moldFilename(baseName), body.model.stlData()))
            }
        }
        if includeManifest {
            files.append((manifestFilename(baseName),
                          manifestData(base: baseName, objects: objects,
                                       margins: margins, style: style,
                                       hasStencil: hasStencil,
                                       connectorStencilFiles: connectorStencilFiles,
                                       hasMold: hasMold)))
        }
        return Payload(files: files, objects: objects)
    }

    // MARK: - Write to disk (CLI)

    struct WriteResult {
        /// One plate's pair on disk (`modifierURL`/`modifierMesh` nil when
        /// the plate has no pneumatic features to envelope).
        struct ExportedObject {
            var plate: Plate
            var modelURL: URL
            var modifierURL: URL?
            var modelMesh: Mesh
            var modifierMesh: Mesh?
        }
        var objects: [ExportedObject]
        /// Standalone bodies written beside the pairs (stencil / mold), if any.
        var auxiliaryURLs: [URL]
        var manifestURL: URL?
    }

    /// Writes each plate's model + modifier pair, any standalone stencil/mold
    /// bodies, and the optional manifest into `directory` (created if
    /// needed). Returns URLs + meshes for reporting and tests.
    @discardableResult
    static func writeDirectory(
        doc: CircuitDocument,
        baseName: String,
        directory: URL,
        margins: PlateBuilder.ModifierMargins = .defaults,
        style: ModifierStyle = .pneumatics,
        includeManifest: Bool = true
    ) throws -> WriteResult {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let p = payload(doc: doc, baseName: baseName, margins: margins, style: style,
                        includeManifest: includeManifest)
        var urls: [String: URL] = [:]
        for file in p.files {
            let url = directory.appendingPathComponent(file.name)
            try file.data.write(to: url, options: .atomic)
            urls[file.name] = url
        }
        // Every written file that isn't a plate pair or the manifest is a
        // standalone auxiliary body (stencil, connector gasket stencils,
        // mold), in the payload's order.
        let pairFiles = Set(p.objects.flatMap {
            [$0.modelFilename] + ($0.modifierFilename.map { [$0] } ?? [])
        })
        let aux = p.files.map(\.name)
            .filter { $0 != manifestFilename(baseName) && !pairFiles.contains($0) }
            .compactMap { urls[$0] }
        return WriteResult(
            objects: p.objects.map { o in
                WriteResult.ExportedObject(
                    plate: o.plate,
                    modelURL: urls[o.modelFilename]!,
                    modifierURL: o.modifierFilename.flatMap { urls[$0] },
                    modelMesh: o.modelMesh,
                    modifierMesh: o.modifierMesh)
            },
            auxiliaryURLs: aux,
            manifestURL: includeManifest ? urls[manifestFilename(baseName)] : nil
        )
    }
}
