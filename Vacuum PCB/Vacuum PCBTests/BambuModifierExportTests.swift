import Testing
import Foundation
import Euclid
@testable import Vacuum_PCB

/// Covers the first-pass "Export for Bambu Studio" workflow: the printable
/// model STL plus an aligned print-critical *modifier* envelope
/// (`PlateBuilder.buildModifier` + `BambuExport`).
///
/// The model layer is implicitly `@MainActor` (project default), so these run
/// on the main actor like the rest of the geometry tests.
@MainActor
struct BambuModifierExportTests {

    // MARK: - Fixtures

    /// A small representative board with every feature class the modifier must
    /// cover: one straight channel, one bent channel (a 90° junction), a
    /// transistor valve (gate dimple + source/drain pads + drop bores) and a
    /// cross-silicone via (a vertical air passage). Geometry-only — nets carry
    /// no pins, which is all the CAD walk needs.
    private func representativeDoc() -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 80, height: 40))
        doc.physical.bottomLayers = 2

        let q = Component(kind: .transistor, label: "Q1")
        let nStraight = Net(label: "straight", pins: [])
        let nBend = Net(label: "bend", pins: [])
        let nVia = Net(label: "via", pins: [])
        doc.logic.components = [q]
        doc.logic.nets = [nStraight, nBend, nVia]
        doc.physical.placements = [
            Placement(componentId: q.id, position: Point(x: 40, y: 20), rotation: .r0, layer: .top, depth: 0),
        ]

        let top0 = Layer(plate: .top, depth: 0)
        let bot0 = Layer(plate: .bottom, depth: 0)
        doc.physical.routes = [
            // Straight channel, top plate.
            Route(netId: nStraight.id, segments: [Segment(waypoints: [
                Waypoint(position: Point(x: 5, y: 30)),
                Waypoint(position: Point(x: 55, y: 30)),
            ], layer: top0)]),
            // Bent channel (one 90° bend / junction), top plate.
            Route(netId: nBend.id, segments: [Segment(waypoints: [
                Waypoint(position: Point(x: 10, y: 8)),
                Waypoint(position: Point(x: 30, y: 8)),
                Waypoint(position: Point(x: 30, y: 24)),
            ], layer: top0)]),
            // Cross-silicone via at (62,20): the twin markers on both plates.
            Route(netId: nVia.id, segments: [
                Segment(waypoints: [
                    Waypoint(position: Point(x: 62, y: 20), kind: .via),
                    Waypoint(position: Point(x: 72, y: 20)),
                ], layer: top0),
                Segment(waypoints: [
                    Waypoint(position: Point(x: 62, y: 20), kind: .via),
                    Waypoint(position: Point(x: 72, y: 10)),
                ], layer: bot0),
            ]),
        ]
        return doc
    }

    /// A board with a single straight top-plate channel — lets us measure the
    /// modifier's cross-section in isolation.
    private func singleChannelDoc() -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 80, height: 40))
        let n = Net(label: "c", pins: [])
        doc.logic.nets = [n]
        doc.physical.routes = [Route(netId: n.id, segments: [Segment(waypoints: [
            Waypoint(position: Point(x: 5, y: 20)),
            Waypoint(position: Point(x: 55, y: 20)),
        ], layer: Layer(plate: .top, depth: 0))])]
        return doc
    }

    // MARK: - Bounds helpers

    private func overlaps(_ a: Bounds, _ b: Bounds) -> Bool {
        a.min.x <= b.max.x && a.max.x >= b.min.x &&
        a.min.y <= b.max.y && a.max.y >= b.min.y &&
        a.min.z <= b.max.z && a.max.z >= b.min.z
    }
    private func width(_ b: Bounds) -> Vector { Vector(b.max.x - b.min.x, b.max.y - b.min.y, b.max.z - b.min.z) }

    // MARK: - Tests

    @Test("Both the model and modifier meshes are non-empty")
    func bothMeshesNonEmpty() {
        let doc = representativeDoc()
        let model = BambuExport.modelMesh(PlateBuilder.build(doc))
        let modifier = PlateBuilder.buildModifier(doc)
        #expect(!model.polygons.isEmpty)
        #expect(!modifier.polygons.isEmpty)
    }

    @Test("Modifier and model share one coordinate frame (modifier bbox overlaps and fits inside the model)")
    func sharedCoordinateFrame() {
        let doc = representativeDoc()
        let model = BambuExport.modelMesh(PlateBuilder.build(doc))
        let modifier = PlateBuilder.buildModifier(doc)
        // The whole point of the export: same coordinate system / origin /
        // scale / units, so the two bounding boxes overlap...
        #expect(overlaps(model.bounds, modifier.bounds))
        // ...and, since the features sit inside the board, the modifier fits
        // within the model's bounds (a gross scale/origin mismatch would throw
        // it far outside). Small epsilon for a margin poking past an edge.
        let eps = 2.0
        #expect(modifier.bounds.min.x >= model.bounds.min.x - eps)
        #expect(modifier.bounds.min.y >= model.bounds.min.y - eps)
        #expect(modifier.bounds.min.z >= model.bounds.min.z - eps)
        #expect(modifier.bounds.max.x <= model.bounds.max.x + eps)
        #expect(modifier.bounds.max.y <= model.bounds.max.y + eps)
        #expect(modifier.bounds.max.z <= model.bounds.max.z + eps)
    }

    @Test("Modifier surrounds a channel's walls/roof/floor rather than filling only its void")
    func modifierSurroundsChannel() {
        let doc = singleChannelDoc()
        let m = doc.manufacturing
        let margins = PlateBuilder.ModifierMargins.defaults
        let modifier = PlateBuilder.buildModifier(doc, margins: margins)
        #expect(!modifier.polygons.isEmpty)

        let w = width(modifier.bounds)
        // Cross-section across the channel (Y) grows by 2·marginXY beyond the
        // printed void; the height (Z) grows by 2·marginZ. Both must exceed the
        // bare channel diameter (i.e. overlap the surrounding printed walls,
        // roof and floor) — not merely fill the empty channel.
        let expectedY = m.channelDiameter + 2 * margins.xy    // 1.5 + 2.0 = 3.5
        let expectedZ = m.channelDiameter + 2 * margins.z     // 1.5 + 1.2 = 2.7
        let tol = 0.2   // 16-slice tessellation under-fills the true radius a hair
        #expect(w.y > m.channelDiameter)                       // surrounds the side walls
        #expect(w.z > m.channelDiameter)                       // surrounds roof + floor
        #expect(abs(w.y - expectedY) < tol)                    // by ~marginXY each side
        #expect(abs(w.z - expectedZ) < tol)                    // by ~marginZ each side
        // marginXY and marginZ act independently: XY margin (1.0) > Z (0.6),
        // so the section is wider than it is tall by ~2·(xy − z).
        #expect(w.y - w.z > 0.5)
    }

    @Test("Building the modifier does not alter the printable model mesh")
    func modifierDoesNotAlterModel() {
        let doc = representativeDoc()
        let before = BambuExport.modelMesh(PlateBuilder.build(doc)).stlData()
        _ = PlateBuilder.buildModifier(doc)
        let after = BambuExport.modelMesh(PlateBuilder.build(doc)).stlData()
        #expect(before == after)
    }

    @Test("Print layout: plates rest on the bed, side by side, each with its own aligned modifier — no Split needed")
    func printLayoutIsPrintReady() {
        let doc = representativeDoc()
        let out = PlateBuilder.build(doc)
        let bodies = BambuExport.printLayout(out, doc: doc, margins: .defaults)

        let top = bodies.first { $0.name == "top" }
        let bottom = bodies.first { $0.name == "bottom" }
        #expect(top != nil)
        #expect(bottom != nil)
        guard let top, let bottom else { return }

        // Every body rests on the bed (z = 0) — the sandwich is gone.
        for body in bodies {
            #expect(abs(body.model.bounds.min.z) < 1e-6, "\(body.name) must rest on z=0")
        }
        // Bodies are strictly separated along X (no overlap → nothing to split).
        let sorted = bodies.map(\.model.bounds).sorted { $0.min.x < $1.min.x }
        for i in 0..<(sorted.count - 1) {
            #expect(sorted[i].max.x < sorted[i + 1].min.x, "bodies must not overlap in X")
        }
        // Each plate's modifier travelled with its plate: it overlaps its own
        // plate's bounds (the representative doc has features on both plates)
        // and not the other plate's X band.
        for plate in [top, bottom] {
            #expect(plate.modifier != nil, "\(plate.name) should carry a modifier")
            guard let modifier = plate.modifier else { continue }
            #expect(overlaps(modifier.bounds, plate.model.bounds))
            let other = plate.name == "top" ? bottom : top
            #expect(modifier.bounds.max.x < other.model.bounds.min.x
                 || modifier.bounds.min.x > other.model.bounds.max.x,
                 "\(plate.name) modifier must stay in its own plate's X band")
        }
        // The flip is a rigid transform: the bottom plate's laid-out volume
        // matches its design-space volume (a mirror would flip the sign).
        #expect(abs(bottom.model.signedVolume - out.bottomPlate.makeWatertight().signedVolume)
                < 0.01 * abs(out.bottomPlate.makeWatertight().signedVolume) + 1e-6)
    }

    @Test("Resistor envelope is one clean watertight box over the footprint")
    func resistorEnvelopeIsCleanBox() {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 80, height: 40))
        let r = Component(kind: .resistor, label: "R1")
        doc.logic.components = [r]
        doc.physical.placements = [
            Placement(componentId: r.id, position: Point(x: 40, y: 20), rotation: .r0, layer: .top, depth: 0),
        ]
        let m = doc.manufacturing
        let margins = PlateBuilder.ModifierMargins.defaults
        let modifier = PlateBuilder.buildModifier(doc, margins: margins)

        // A single box: watertight (the CSG-unioned serpentine blob wasn't) …
        #expect(modifier.isWatertight)
        // … sized footprint + margins, not the inflated-tube bulge.
        let w = width(modifier.bounds)
        let expectedX = ManufacturingConstants.resistorFootprintLength + 2 * margins.xy
        let expectedY = ManufacturingConstants.resistorFootprintWidth + 2 * margins.xy
        let expectedZ = m.resistorChannelDiameter + 2 * margins.z
        #expect(abs(w.x - expectedX) < 1e-6)
        #expect(abs(w.y - expectedY) < 1e-6)
        #expect(abs(w.z - expectedZ) < 1e-6)
        // Centred on the placement, at the channel midline.
        let b = modifier.bounds
        #expect(abs((b.min.x + b.max.x) / 2 - 40) < 1e-6)
        #expect(abs((b.min.y + b.max.y) / 2 - 20) < 1e-6)
        #expect(abs((b.min.z + b.max.z) / 2 - m.midZ(for: Layer(plate: .top, depth: 0))) < 1e-6)
    }

    @Test("Per-plate modifier split covers each plate's own features")
    func perPlateModifierSplit() {
        let doc = representativeDoc()
        let all = PlateBuilder.buildModifier(doc)
        let top = PlateBuilder.buildModifier(doc, plate: .top)
        let bottom = PlateBuilder.buildModifier(doc, plate: .bottom)
        #expect(!top.polygons.isEmpty)      // straight + bent channels, valve gate
        #expect(!bottom.polygons.isEmpty)   // via stub segment, valve pads
        // Nothing is lost by splitting (the cross-silicone via is deliberately
        // duplicated into both plates, so the split can only grow).
        #expect(top.polygons.count + bottom.polygons.count >= all.polygons.count)
        // Top-plate features live in the top plate's Z half (above the
        // silicone midplane minus the roof/floor margin); bottom mirrored.
        #expect(top.bounds.max.z > 0)
        #expect(bottom.bounds.min.z < 0)
    }

    @Test("The Bambu model STL is byte-identical to the plain Save STL export")
    func modelMatchesPlainExport() {
        let doc = representativeDoc()
        let out = PlateBuilder.build(doc)
        let bambuModel = BambuExport.modelMesh(out).stlData()
        // The exact expression the shipped "Save STL" / Bambu-open path uses
        // (per-body makeWatertight, polygons concatenated into one multi-solid).
        let bodies = BambuExport.modelBodies(out)
        let shipped = Mesh(bodies.flatMap { $0.makeWatertight().polygons }).stlData()
        #expect(bambuModel == shipped)
    }

    @Test("Export output is deterministic for an unchanged model")
    func deterministicOutput() {
        let doc = representativeDoc()
        let model1 = BambuExport.modelMesh(PlateBuilder.build(doc)).stlData()
        let model2 = BambuExport.modelMesh(PlateBuilder.build(doc)).stlData()
        #expect(model1 == model2)
        let mod1 = PlateBuilder.buildModifier(doc).stlData()
        let mod2 = PlateBuilder.buildModifier(doc).stlData()
        #expect(mod1 == mod2)
        // And the full laid-out payload — every file, byte for byte.
        let p1 = BambuExport.payload(doc: doc, baseName: "det")
        let p2 = BambuExport.payload(doc: doc, baseName: "det")
        #expect(p1.files.map(\.name) == p2.files.map(\.name))
        for (a, b) in zip(p1.files, p2.files) {
            #expect(a.data == b.data, "\(a.name) must be deterministic")
        }
    }

    @Test("Margins scale the envelope: bigger margins → bigger modifier")
    func largerMarginsGrowEnvelope() {
        let doc = singleChannelDoc()
        let small = PlateBuilder.buildModifier(doc, margins: .init(xy: 0.5, z: 0.3))
        let large = PlateBuilder.buildModifier(doc, margins: .init(xy: 2.0, z: 1.5))
        #expect(width(large.bounds).y > width(small.bounds).y)
        #expect(width(large.bounds).z > width(small.bounds).z)
    }

    @Test("writeDirectory writes both STLs plus the manifest, and reports overlapping bounds")
    func writeDirectoryProducesAlignedFiles() throws {
        let doc = representativeDoc()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bambu-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let r = try BambuExport.writeDirectory(doc: doc, baseName: "widget", directory: dir)

        #expect(FileManager.default.fileExists(atPath: r.modelURL.path))
        #expect(FileManager.default.fileExists(atPath: r.modifierURL.path))
        #expect(r.modelURL.lastPathComponent == "widget_model.stl")
        #expect(r.modifierURL.lastPathComponent == "widget_modifier.stl")
        #expect(r.manifestURL?.lastPathComponent == "widget_bambu_export.json")
        #expect(overlaps(r.modelMesh.bounds, r.modifierMesh.bounds))
        // Default manufacturing has a stencil and a mold — they ship as
        // separate standalone objects beside the pair.
        #expect(r.auxiliaryURLs.map(\.lastPathComponent).sorted()
                == ["widget_mold.stl", "widget_stencil.stl"])
        for aux in r.auxiliaryURLs {
            #expect(FileManager.default.fileExists(atPath: aux.path))
        }

        // Files are non-trivial and the STLs on disk match the returned meshes.
        let modelData = try Data(contentsOf: r.modelURL)
        let modifierData = try Data(contentsOf: r.modifierURL)
        #expect(modelData == r.modelMesh.stlData())
        #expect(modifierData == r.modifierMesh.stlData())

        // Manifest shape.
        let manifest = try Data(contentsOf: #require(r.manifestURL))
        let obj = try JSONSerialization.jsonObject(with: manifest) as? [String: Any]
        #expect(obj?["units"] as? String == "millimeters")
        #expect(obj?["model"] as? String == "widget_model.stl")
        #expect(obj?["modifier"] as? String == "widget_modifier.stl")
        #expect(obj?["modifierMarginXY"] as? Double == 1.0)
        #expect(obj?["modifierMarginZ"] as? Double == 0.6)
    }

    @Test("Manifest can be suppressed")
    func manifestOptional() throws {
        let doc = representativeDoc()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bambu-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try BambuExport.writeDirectory(doc: doc, baseName: "widget", directory: dir, includeManifest: false)
        #expect(r.manifestURL == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("widget_bambu_export.json").path))
    }
}
