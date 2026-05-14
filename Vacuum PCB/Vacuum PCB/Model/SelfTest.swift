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
