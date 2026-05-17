import Foundation
import Euclid

enum SelfTest {

    /// Encode → decode → re-encode the bundled inverter and assert the two encodings
    /// match byte-for-byte. Catches schema drift, missing Codable conformances, and
    /// encoder non-determinism. DEBUG-only; calls preconditionFailure on mismatch.
    static func runJSONRoundTrip() {
        let original = Examples.inverter()
        do {
            let firstPass = try original.encoded()
            let decoded = try CircuitDocument.decoded(from: firstPass)
            let secondPass = try decoded.encoded()

            guard firstPass == secondPass else {
                let a = String(data: firstPass,  encoding: .utf8) ?? "<non-utf8>"
                let b = String(data: secondPass, encoding: .utf8) ?? "<non-utf8>"
                preconditionFailure(
                    "JSON round-trip mismatch.\nFirst pass:\n\(a)\n\nSecond pass:\n\(b)"
                )
            }
            guard decoded == original else {
                preconditionFailure("Decoded document not equal to original.")
            }

            #if DEBUG
            let url = scratchURL(named: "inverter.vpcb")
            try firstPass.write(to: url, options: [.atomic])
            NSLog("[SelfTest] JSON round-trip OK. Sample written to \(url.path).")
            #endif
        } catch {
            preconditionFailure("JSON round-trip threw: \(error)")
        }
    }

    /// Build the inverter's plate meshes, merge, and write a binary STL to scratch.
    /// Smoke-tests the CAD pipeline + Euclid integration. DEBUG-only.
    static func runSTLSmokeTest() {
        let doc = Examples.inverter()
        let start = Date()
        let result = PlateBuilder.build(doc)
        let elapsed = Date().timeIntervalSince(start)

        let combined = Mesh.merge([result.topPlate, result.bottomPlate])
        let polyCount = combined.polygons.count
        guard polyCount > 0 else {
            preconditionFailure("PlateBuilder produced an empty mesh (no polygons).")
        }

        let data = combined.stlData()
        let url = scratchURL(named: "inverter-plates.stl")
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            preconditionFailure("STL write failed: \(error)")
        }
        NSLog(String(
            format: "[SelfTest] CAD OK in %.2fs. %d polygons, %d KB STL → %@",
            elapsed, polyCount, data.count / 1024, url.path as NSString
        ))
        NSLog("[SelfTest] top isWatertight: \(result.topPlate.isWatertight), bottom isWatertight: \(result.bottomPlate.isWatertight)")
    }

    /// Round-trips the user's first composite library part (a `.vpcb` that
    /// itself contains `.subpart` instances) through `flattened()` and asserts
    /// the recursion produced sensible output: no subparts left behind, no
    /// UUID collisions across expansions, at least one primitive placement.
    /// Silently skips when no composite part is present — runs against real
    /// user data when available, doesn't fail when not.
    static func runNestedSubpartFlatten() {
        let lib = PartsLibrary.shared
        guard let composite = lib.parts.first(where: { part in
            part.document.logic.components.contains(where: { $0.kind == .subpart })
        }) else {
            #if DEBUG
            NSLog("[SelfTest] Nested flatten skipped: no composite parts in library.")
            #endif
            return
        }

        // Synthetic parent with one instance of the composite at r0/(0,0).
        // Keeps coordinates trivially inspectable on failure.
        let instanceId = UUID()
        let parent = CircuitDocument(
            logic: LogicGraph(
                components: [Component(
                    id: instanceId, kind: .subpart, label: "U1",
                    partRef: composite.filename
                )],
                nets: []
            ),
            physical: PhysicalLayout(
                placements: [Placement(
                    componentId: instanceId,
                    position: .zero, rotation: .r0,
                    layer: .top, depth: 0
                )],
                routes: [],
                boardOutline: composite.document.physical.boardOutline
            )
        )

        let flat = parent.flattened()

        let leakedSubparts = flat.logic.components.filter { $0.kind == .subpart }
        guard leakedSubparts.isEmpty else {
            preconditionFailure(
                "Nested flatten left \(leakedSubparts.count) subpart components: " +
                "\(leakedSubparts.map(\.label))"
            )
        }
        guard !flat.physical.placements.isEmpty else {
            preconditionFailure(
                "Nested flatten of '\(composite.filename)' produced no primitive placements."
            )
        }
        let placementIds = flat.physical.placements.map(\.componentId)
        guard Set(placementIds).count == placementIds.count else {
            preconditionFailure("Nested flatten produced duplicate placement UUIDs.")
        }
        let componentIds = flat.logic.components.map(\.id)
        guard Set(componentIds).count == componentIds.count else {
            preconditionFailure("Nested flatten produced duplicate component UUIDs.")
        }

        #if DEBUG
        NSLog(
            "[SelfTest] Nested flatten OK. '\(composite.filename)' → " +
            "\(flat.physical.placements.count) placements, " +
            "\(flat.physical.routes.count) routes."
        )
        #endif
    }

    /// Writable scratch directory under Application Support so the round-tripped
    /// example can be inspected on disk. Created on first use.
    private static func scratchURL(named filename: String) -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory

        let dir = base.appendingPathComponent("Vacuum PCB", isDirectory: true)
            .appendingPathComponent("Examples", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }
}
