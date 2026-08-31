import Foundation
import Euclid
import Compression

/// Native Bambu Studio project (`.3mf`) writer: printable objects whose parts
/// arrive **with their per-part setting overrides already applied** — no
/// per-setting clicking in Bambu Studio (its UI has no way to attach a preset
/// to a part, only one-by-one overrides; this writes them into the file
/// instead). Ported from the validated writer on `claude/bambu-3mf-export`
/// (there specialized to a pre-marked modifier envelope), generalized here to
/// any number of parts per object, each with its own subtype and override
/// rows — what the resistors-only export needs (`_resistors` as a *normal*
/// part carrying the porous-infill recipe).
///
/// Format learned from a real BambuStudio-02.07 project (see BAMBU_EXPORT.md)
/// and cross-checked against a hand-built infill-resistor test project
/// (2026-08-29): a ZIP containing OPC boilerplate, a root `3D/3dmodel.model`
/// whose objects reference per-object mesh files (3MF *production*
/// extension), and `Metadata/model_settings.config` where each `<part>`
/// carries a `subtype` (`normal_part` / `modifier_part`) plus
/// `<metadata key value>` rows — both the part's name/matrix AND its per-part
/// setting overrides use that same encoding, keyed by the *parent object*, so
/// two objects can share nothing and still get different overrides.
/// `Metadata/project_settings.config` (the full global preset snapshot, 500+
/// keys) is deliberately NOT written: synthesizing it is fragile, and
/// omitting it means Bambu keeps whatever global preset the user has selected
/// (the airtight profile) while still applying the per-part config.
///
/// Everything is deterministic: fixed ZIP timestamps, counter-derived UUIDs,
/// caller-ordered override rows, first-seen vertex ordering.
enum Bambu3MF {

    /// Ordered `key = value` rows written into a part's per-part config.
    typealias Overrides = [(key: String, value: String)]

    // MARK: - Project assembly

    /// One part of a printable object: a mesh in the object's (shared)
    /// coordinate space, its Bambu subtype, and optional per-part overrides.
    struct ProjectPart {
        var name: String
        var mesh: Mesh
        /// `modifier_part` when true (settings-only volume), `normal_part`
        /// when false (printed solid — which may still carry overrides,
        /// e.g. the porous `_resistors` part).
        var isModifier: Bool = false
        var overrides: Overrides = []
    }

    /// One printable object (one entry in Bambu's Objects tree).
    struct ProjectObject {
        var name: String
        var parts: [ProjectPart]
    }

    /// Bed centre the laid-out row is shifted to via build-item transforms
    /// (A1 mini bed is 180×180). Mesh coordinates stay identical to the STL
    /// export; only the 3MF build items carry the shift, so a different bed
    /// just re-arranges in Bambu.
    static let bedCentre = (x: 90.0, y: 90.0)

    /// Builds the complete `.3mf` archive. Parts keep the coordinates their
    /// meshes carry (identity part matrices); the whole set of objects is
    /// centred on the bed with one shared build-item translation, so
    /// relative alignment between parts and between objects is untouched.
    static func projectData(
        objects input: [ProjectObject],
        title: String = "Vacuum PCB Bambu export"
    ) -> Data {
        // Global mesh-object id counter: ids must be unique across the whole
        // package (the reference projects keep them globally unique too).
        var nextId = 1
        func takeId() -> Int { defer { nextId += 1 } ; return nextId }

        struct MeshPart {
            var id: Int
            var source: ProjectPart
            var xml: String   // <object …><mesh>…</mesh></object>
        }
        struct FileObject {
            var rootId: Int
            var name: String
            var path: String  // "/3D/Objects/object_1.model"
            var parts: [MeshPart]
        }

        // Centre the combined row on the bed via one shared translation
        // (computed over every part of every object, so a part poking past
        // its object's model body still ends up on the bed).
        let allBounds = input.flatMap(\.parts).map(\.mesh.bounds)
        let combined = allBounds.dropFirst().reduce(allBounds.first ?? .empty) { $0.union($1) }
        let dx = bedCentre.x - (combined.min.x + combined.max.x) / 2
        let dy = bedCentre.y - (combined.min.y + combined.max.y) / 2

        var fileObjects: [FileObject] = []
        for (index, object) in input.enumerated() {
            let parts = object.parts.map { part in
                let id = takeId()
                return MeshPart(id: id, source: part,
                                xml: meshObjectXML(id: id, mesh: part.mesh))
            }
            let rootId = takeId()
            fileObjects.append(FileObject(
                rootId: rootId, name: object.name,
                path: "/3D/Objects/object_\(index + 1).model",
                parts: parts
            ))
        }

        // ---- 3D/Objects/object_N.model (one per printable object) ----
        var files: [(path: String, data: Data)] = []
        for fo in fileObjects {
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:BambuStudio="http://schemas.bambulab.com/package/2021" xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06" requiredextensions="p">
             <metadata name="BambuStudio:3mfVersion">1</metadata>
             <resources>
            \(fo.parts.map(\.xml).joined(separator: "\n"))
             </resources>
             <build/>
            </model>
            """
            files.append((String(fo.path.dropFirst()), Data(xml.utf8)))
        }

        // ---- 3D/3dmodel.model (root: components + build) ----
        var rootResources = ""
        var buildItems = ""
        for fo in fileObjects {
            let components = fo.parts.map {
                """
                    <component p:path="\(fo.path)" objectid="\($0.id)" p:UUID="\(uuid(fo.rootId, $0.id))" transform="1 0 0 0 1 0 0 0 1 0 0 0"/>
                """
            }.joined(separator: "\n")
            rootResources += """
              <object id="\(fo.rootId)" p:UUID="\(uuid(fo.rootId, 0))" type="model">
               <components>
            \(components)
               </components>
              </object>

            """
            buildItems += """
              <item objectid="\(fo.rootId)" p:UUID="\(uuid(fo.rootId, 9999))" transform="1 0 0 0 1 0 0 0 1 \(num(dx)) \(num(dy)) 0" printable="1"/>

            """
        }
        let rootModel = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:BambuStudio="http://schemas.bambulab.com/package/2021" xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06" requiredextensions="p">
         <metadata name="Application">VacuumPCB (BambuStudio-compatible)</metadata>
         <metadata name="BambuStudio:3mfVersion">1</metadata>
         <metadata name="Title">\(xmlEscape(title))</metadata>
         <resources>
        \(rootResources) </resources>
         <build p:UUID="\(uuid(0, 0))">
        \(buildItems) </build>
        </model>
        """
        files.insert(("3D/3dmodel.model", Data(rootModel.utf8)), at: 0)

        // ---- 3D/_rels/3dmodel.model.rels ----
        let objectRels = fileObjects.enumerated().map { i, fo in
            """
             <Relationship Target="\(fo.path)" Id="rel-\(i + 1)" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
            """
        }.joined(separator: "\n")
        files.append(("3D/_rels/3dmodel.model.rels", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \(objectRels)
        </Relationships>
        """.utf8)))

        // ---- Metadata/model_settings.config ----
        // Per-part rows: name + matrix first, then the caller's override rows
        // in caller order — Bambu itself writes them alphabetized, but it
        // reads them order-independently (keys are looked up, not scanned).
        var settings = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<config>\n"
        let identity16 = "1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1"
        for fo in fileObjects {
            settings += "  <object id=\"\(fo.rootId)\">\n"
            settings += "    <metadata key=\"name\" value=\"\(xmlEscape(fo.name))\"/>\n"
            settings += "    <metadata key=\"extruder\" value=\"1\"/>\n"
            for part in fo.parts {
                settings += "    <part id=\"\(part.id)\" subtype=\"\(part.source.isModifier ? "modifier_part" : "normal_part")\">\n"
                settings += "      <metadata key=\"name\" value=\"\(xmlEscape(part.source.name))\"/>\n"
                settings += "      <metadata key=\"matrix\" value=\"\(identity16)\"/>\n"
                for row in part.source.overrides {
                    settings += "      <metadata key=\"\(xmlEscape(row.key))\" value=\"\(xmlEscape(row.value))\"/>\n"
                }
                settings += "    </part>\n"
            }
            settings += "  </object>\n"
        }
        settings += "  <plate>\n"
        settings += "    <metadata key=\"plater_id\" value=\"1\"/>\n"
        settings += "    <metadata key=\"plater_name\" value=\"\"/>\n"
        settings += "    <metadata key=\"locked\" value=\"false\"/>\n"
        for fo in fileObjects {
            settings += "    <model_instance>\n"
            settings += "      <metadata key=\"object_id\" value=\"\(fo.rootId)\"/>\n"
            settings += "      <metadata key=\"instance_id\" value=\"0\"/>\n"
            settings += "      <metadata key=\"identify_id\" value=\"\(100 + fo.rootId)\"/>\n"
            settings += "    </model_instance>\n"
        }
        settings += "  </plate>\n</config>\n"
        files.append(("Metadata/model_settings.config", Data(settings.utf8)))

        // ---- OPC boilerplate ----
        files.append(("[Content_Types].xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
         <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
         <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
        </Types>
        """.utf8)))
        files.append(("_rels/.rels", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
         <Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
        </Relationships>
        """.utf8)))

        var zip = ZipWriter()
        for file in files { zip.addFile(path: file.path, data: file.data) }
        return zip.finish()
    }

    // MARK: - Mesh → 3MF XML

    /// `<object id><mesh><vertices>…<triangles>…` for one Euclid mesh.
    /// Triangulates, dedups vertices (first-seen order), keeps Euclid's CCW
    /// winding (3MF, like STL, wants outward CCW).
    static func meshObjectXML(id: Int, mesh: Mesh) -> String {
        var vertexIndex: [Vector: Int] = [:]
        var vertexOrder: [Vector] = []
        var triangles: [(Int, Int, Int)] = []
        for polygon in mesh.triangulate().polygons {
            var ids: [Int] = []
            for vertex in polygon.vertices {
                let p = vertex.position
                if let existing = vertexIndex[p] {
                    ids.append(existing)
                } else {
                    let new = vertexOrder.count
                    vertexIndex[p] = new
                    vertexOrder.append(p)
                    ids.append(new)
                }
            }
            if ids.count == 3 { triangles.append((ids[0], ids[1], ids[2])) }
        }
        var xml = "  <object id=\"\(id)\" p:UUID=\"\(uuid(id, id))\" type=\"model\">\n   <mesh>\n    <vertices>\n"
        for p in vertexOrder {
            xml += "     <vertex x=\"\(num(p.x))\" y=\"\(num(p.y))\" z=\"\(num(p.z))\"/>\n"
        }
        xml += "    </vertices>\n    <triangles>\n"
        for t in triangles {
            xml += "     <triangle v1=\"\(t.0)\" v2=\"\(t.1)\" v3=\"\(t.2)\"/>\n"
        }
        xml += "    </triangles>\n   </mesh>\n  </object>"
        return xml
    }

    /// Shortest round-trip decimal for a coordinate (Swift's Double
    /// description), with "-0.0" and integer values normalised.
    static func num(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 {
            let i = Int64(v)
            return i == 0 ? "0" : "\(i)"
        }
        return "\(v)"
    }

    /// Deterministic UUID from two counters — valid RFC-4122-shaped, stable
    /// across runs (the reference project uses patterned counters too).
    static func uuid(_ a: Int, _ b: Int) -> String {
        String(format: "%08x-0000-4000-8000-%012x", UInt32(truncatingIfNeeded: a), UInt64(truncatingIfNeeded: b))
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Minimal deterministic ZIP writer

/// Just enough ZIP (PKWARE APPNOTE) for a 3MF: local file headers + central
/// directory + end record. Entries are DEFLATE-compressed via the system
/// Compression framework (`COMPRESSION_ZLIB` == raw DEFLATE, which is what
/// ZIP method 8 wants), falling back to STORED when compression doesn't help.
/// Timestamps are fixed (1980-01-01) so archives are byte-deterministic.
struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var entryCount: UInt16 = 0

    mutating func addFile(path: String, data: Data) {
        let nameBytes = Data(path.utf8)
        let crc = ZipWriter.crc32(data)
        let deflated = ZipWriter.deflate(data)
        let (method, payload): (UInt16, Data) = {
            if let deflated, deflated.count < data.count { return (8, deflated) }
            return (0, data)
        }()
        let offset = UInt32(body.count)

        // Local file header.
        body.appendLE(UInt32(0x04034b50))
        body.appendLE(UInt16(20))                    // version needed
        body.appendLE(UInt16(0))                     // flags
        body.appendLE(method)
        body.appendLE(UInt16(0))                     // mod time (fixed)
        body.appendLE(UInt16(0x21))                  // mod date: 1980-01-01
        body.appendLE(crc)
        body.appendLE(UInt32(payload.count))
        body.appendLE(UInt32(data.count))
        body.appendLE(UInt16(nameBytes.count))
        body.appendLE(UInt16(0))                     // extra len
        body.append(nameBytes)
        body.append(payload)

        // Central directory entry.
        central.appendLE(UInt32(0x02014b50))
        central.appendLE(UInt16(20))                 // version made by
        central.appendLE(UInt16(20))                 // version needed
        central.appendLE(UInt16(0))
        central.appendLE(method)
        central.appendLE(UInt16(0))
        central.appendLE(UInt16(0x21))
        central.appendLE(crc)
        central.appendLE(UInt32(payload.count))
        central.appendLE(UInt32(data.count))
        central.appendLE(UInt16(nameBytes.count))
        central.appendLE(UInt16(0))                  // extra
        central.appendLE(UInt16(0))                  // comment
        central.appendLE(UInt16(0))                  // disk
        central.appendLE(UInt16(0))                  // internal attrs
        central.appendLE(UInt32(0))                  // external attrs
        central.appendLE(offset)
        central.append(nameBytes)

        entryCount += 1
    }

    func finish() -> Data {
        var out = body
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.appendLE(UInt32(0x06054b50))             // EOCD
        out.appendLE(UInt16(0))                      // disk
        out.appendLE(UInt16(0))                      // cd disk
        out.appendLE(entryCount)
        out.appendLE(entryCount)
        out.appendLE(UInt32(central.count))
        out.appendLE(cdOffset)
        out.appendLE(UInt16(0))                      // comment len
        return out
    }

    /// Raw DEFLATE (no zlib wrapper) via the Compression framework; nil when
    /// incompressible or empty.
    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count
        var dst = Data(count: capacity)
        let written = dst.withUnsafeMutableBytes { d -> Int in
            data.withUnsafeBytes { s -> Int in
                guard let dp = d.bindMemory(to: UInt8.self).baseAddress,
                      let sp = s.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(dp, capacity, sp, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return dst.prefix(written)
    }

    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data {
            c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt16) {
        append(UInt8(v & 0xFF)); append(UInt8(v >> 8))
    }
    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF)); append(UInt8(v >> 24))
    }
}
