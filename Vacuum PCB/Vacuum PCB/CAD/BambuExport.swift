import Foundation
import Euclid

/// "Export for Bambu Studio": produces the printable model STL plus an aligned
/// print-critical *modifier* STL (and an optional JSON manifest), ready to be
/// loaded into Bambu Studio as one multipart object.
///
/// The model STL carries the two plates **already laid out for printing** —
/// side by side on the bed (z = 0), the bottom plate flipped to its
/// print orientation (silicone face down, channel arches up) — so the object
/// slices as-is, with **no "Split objects" step** (splitting a multipart
/// object is what detaches modifiers from their model). Each plate's modifier
/// shells receive exactly the same rigid transform as their plate, so model
/// and modifier stay aligned part for part.
///
/// The stencil (silicone cutting template) and mold frame have no pneumatic
/// features, so they ship as separate plain STLs — import them as their own
/// objects whenever you print them, and arrange freely.
///
/// Workflow: select `<base>_model.stl` and `<base>_modifier.stl` together,
/// answer "Yes" to load them as a single object, switch the `_modifier` part
/// to a Modifier, and slice.
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

    static func modelFilename(_ base: String) -> String { "\(base)_model.stl" }
    static func modifierFilename(_ base: String) -> String { "\(base)_modifier.stl" }
    static func stencilFilename(_ base: String) -> String { "\(base)_stencil.stl" }
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
        [out.topPlate, out.bottomPlate, out.stencil, out.moldFrame].filter { !$0.isEmpty }
    }

    /// The single multi-solid, watertight model mesh in *design* space —
    /// byte-identical to what a plain "Save STL" writes (shared
    /// `combinedModelMesh`). Not what the Bambu model file ships (that one is
    /// laid out for printing, see `printLayout`); kept as the parity reference.
    static func modelMesh(_ out: PlateBuilder.Output) -> Mesh {
        STLExportDocument.combinedModelMesh(modelBodies(out))
    }

    /// One printed body posed for the bed, with its (optional) modifier
    /// envelope carrying the identical rigid transform.
    struct LayoutBody {
        var name: String
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
    static func printLayout(
        _ out: PlateBuilder.Output, doc: CircuitDocument,
        margins: PlateBuilder.ModifierMargins,
        style: ModifierStyle = .pneumatics
    ) -> [LayoutBody] {
        let flip = Euclid.Rotation.pitch(.pi)
        func plateModifier(_ plate: Plate) -> Mesh {
            switch style {
            case .pneumatics:
                return PlateBuilder.buildModifier(doc, margins: margins, plate: plate)
            case .voids:
                return PlateBuilder.buildInvertedModifier(doc, margins: margins, plate: plate)
            }
        }
        let posed: [(name: String, model: Mesh, modifier: Mesh?, rotation: Euclid.Rotation?)] = [
            ("top", out.topPlate, plateModifier(.top), nil),
            ("bottom", out.bottomPlate, plateModifier(.bottom), flip),
            ("stencil", out.stencil, nil, nil),
            ("mold", out.moldFrame, nil, nil),
        ]
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
    /// the shape matches the documented example.
    static func manifestData(
        base: String, margins: PlateBuilder.ModifierMargins,
        style: ModifierStyle = .pneumatics,
        hasStencil: Bool, hasMold: Bool
    ) -> Data {
        var extra = ""
        if hasStencil { extra += "\n  \"stencil\": \"\(stencilFilename(base))\"," }
        if hasMold { extra += "\n  \"mold\": \"\(moldFilename(base))\"," }
        let json = """
        {
          "units": "millimeters",
          "layout": "print",
          "model": "\(modelFilename(base))",
          "modifier": "\(modifierFilename(base))",\(extra)
          "modifierStyle": "\(style.rawValue)",
          "modifierMarginXY": \(margins.xy),
          "modifierMarginZ": \(margins.z)
        }
        """
        return Data(json.utf8)
    }

    // MARK: - Payload

    /// The prebuilt contents of a Bambu export, ready to write to disk or hand
    /// to a `BambuExportDocument`.
    ///
    /// `modelMesh` holds the two plates in print layout (the `_model.stl`
    /// contents); `modifierMesh` their combined modifier shells
    /// (`_modifier.stl`). The stencil/mold files, when present, are in `files`
    /// only. `pairFilenames` names the two files that belong together as one
    /// multipart object — what the one-click "Open with Modifier" hands to
    /// Bambu Studio.
    struct Payload {
        var files: [(name: String, data: Data)]
        var pairFilenames: [String]
        var modelMesh: Mesh
        var modifierMesh: Mesh
    }

    /// Builds every file's contents for `doc`. Runs the CAD pipeline (CSG), so
    /// call it off the main thread. Pass `prebuiltModel` (the preview's already
    /// computed `Output`) to skip rebuilding the model plates.
    static func payload(
        doc: CircuitDocument,
        baseName: String,
        margins: PlateBuilder.ModifierMargins = .defaults,
        style: ModifierStyle = .pneumatics,
        includeManifest: Bool = true,
        prebuiltModel: PlateBuilder.Output? = nil
    ) -> Payload {
        let out = prebuiltModel ?? PlateBuilder.build(doc)
        let bodies = printLayout(out, doc: doc, margins: margins, style: style)
        let plates = bodies.filter { $0.name == "top" || $0.name == "bottom" }
        // One multi-solid model of both plates (polygon concatenation like the
        // plain export — the bodies are separate printed solids) and one
        // modifier of both plates' shells. No `makeWatertight` on the
        // modifier: its shells are meant to overlap and slicers union them
        // per layer, so stitching is both unnecessary and would risk
        // non-determinism.
        let model = Mesh(plates.flatMap { $0.model.polygons })
        let modifier = Mesh(plates.compactMap(\.modifier).flatMap(\.polygons))
        var files: [(name: String, data: Data)] = [
            (modelFilename(baseName), model.stlData()),
            (modifierFilename(baseName), modifier.stlData()),
        ]
        let pair = [modelFilename(baseName), modifierFilename(baseName)]
        // Stencil + mold: separate plain objects (no pneumatics → no
        // modifier), so they never join the multipart object and can be
        // arranged / printed independently.
        var hasStencil = false, hasMold = false
        for body in bodies where body.name == "stencil" || body.name == "mold" {
            if body.name == "stencil" {
                hasStencil = true
                files.append((stencilFilename(baseName), body.model.stlData()))
            } else {
                hasMold = true
                files.append((moldFilename(baseName), body.model.stlData()))
            }
        }
        if includeManifest {
            files.append((manifestFilename(baseName),
                          manifestData(base: baseName, margins: margins, style: style,
                                       hasStencil: hasStencil, hasMold: hasMold)))
        }
        return Payload(files: files, pairFilenames: pair, modelMesh: model, modifierMesh: modifier)
    }

    // MARK: - Write to disk (CLI)

    struct WriteResult {
        var modelURL: URL
        var modifierURL: URL
        /// Standalone bodies written beside the pair (stencil / mold), if any.
        var auxiliaryURLs: [URL]
        var manifestURL: URL?
        var modelMesh: Mesh
        var modifierMesh: Mesh
    }

    /// Writes the model + modifier pair, any standalone stencil/mold bodies,
    /// and the optional manifest into `directory` (created if needed).
    /// Returns URLs + meshes for reporting and tests.
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
        let aux = [stencilFilename(baseName), moldFilename(baseName)].compactMap { urls[$0] }
        return WriteResult(
            modelURL: urls[modelFilename(baseName)]!,
            modifierURL: urls[modifierFilename(baseName)]!,
            auxiliaryURLs: aux,
            manifestURL: includeManifest ? urls[manifestFilename(baseName)] : nil,
            modelMesh: p.modelMesh,
            modifierMesh: p.modifierMesh
        )
    }
}
