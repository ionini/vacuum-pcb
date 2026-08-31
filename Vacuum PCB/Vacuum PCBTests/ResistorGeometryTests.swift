import Testing
import Foundation
@testable import Vacuum_PCB

/// Covers the resistor channel paths — the legacy zigzag's stability and the
/// smooth meander's printability guarantees (`smoothResistors`).
///
/// The model layer is implicitly `@MainActor` (project default), so these run
/// on the main actor like the rest of the geometry tests.
@MainActor
struct ResistorGeometryTests {

    private let halfLen = ManufacturingConstants.resistorFootprintLength / 2
    private let halfWid = ManufacturingConstants.resistorFootprintWidth / 2

    private func mfg(smooth: Bool, bore: Double = 0.6, minWall: Double = 0.5) -> ManufacturingConstants {
        var m = ManufacturingConstants.defaults
        m.smoothResistors = smooth
        m.resistorChannelDiameter = bore
        m.minWallThickness = minWall
        return m
    }

    /// x-positions of the meander's vertical legs (segments that are long and
    /// purely vertical — turn-arc chords are shorter and always slanted).
    private func legXs(_ pts: [Point]) -> [Double] {
        var xs: [Double] = []
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            guard abs(a.x - b.x) < 1e-9, abs(a.y - b.y) > 0.2 else { continue }
            if xs.last.map({ abs($0 - a.x) > 1e-9 }) ?? true { xs.append(a.x) }
        }
        return xs.sorted()
    }

    // MARK: - Legacy stability

    @Test("smoothResistors off reproduces the legacy zigzag exactly, per size")
    func legacyPathUnchanged() {
        let m = mfg(smooth: false)
        for size in ResistorSize.allCases {
            let new = ResistorGeometry.waypoints(for: size, m: m)
            let old = ResistorGeometry.path(
                transitions: ResistorGeometry.transitions(for: size),
                halfLen: halfLen, halfWid: halfWid)
            #expect(new.count == old.count)
            for (a, b) in zip(new, old) {
                #expect(abs(a.x - b.x) < 1e-12 && abs(a.y - b.y) < 1e-12)
            }
        }
    }

    // MARK: - Smooth meander guarantees

    @Test("Smooth legs keep a printable wall between neighbouring bores at any size")
    func smoothWallsArePrintable() {
        let m = mfg(smooth: true)
        let bore = m.resistorChannelDiameter
        for size in [ResistorSize.medium, .large, .extraLarge] {
            let pts = ResistorGeometry.waypoints(for: size, m: m)
            let xs = legXs(pts)
            #expect(xs.count >= 2, "\(size) should meander")
            for i in 0..<(xs.count - 1) {
                let wall = (xs[i + 1] - xs[i]) - bore
                #expect(wall >= 0.5 - 1e-9,
                        "\(size): wall \(wall) between legs at \(xs[i])/\(xs[i + 1])")
            }
        }
    }

    @Test("Smooth path has no sharp corners — every vertex turns ≤ 50°")
    func smoothHasNoSharpCorners() {
        let m = mfg(smooth: true)
        for size in [ResistorSize.medium, .large, .extraLarge] {
            let pts = ResistorGeometry.waypoints(for: size, m: m)
            for i in 1..<(pts.count - 1) {
                let ax = pts[i].x - pts[i - 1].x, ay = pts[i].y - pts[i - 1].y
                let bx = pts[i + 1].x - pts[i].x, by = pts[i + 1].y - pts[i].y
                let la = (ax * ax + ay * ay).squareRoot()
                let lb = (bx * bx + by * by).squareRoot()
                #expect(la > 1e-9 && lb > 1e-9, "\(size): zero-length segment at \(i)")
                let cosTurn = (ax * bx + ay * by) / (la * lb)
                let turnDeg = acos(max(-1, min(1, cosTurn))) * 180 / .pi
                #expect(turnDeg <= 50 + 1e-6, "\(size): \(turnDeg)° corner at \(pts[i])")
            }
        }
    }

    @Test("Smooth path stays inside the footprint with edge margin, and docks at the pins on the centerline")
    func smoothStaysInFootprintAndDocks() {
        let m = mfg(smooth: true)
        let bore = m.resistorChannelDiameter
        for size in ResistorSize.allCases {
            let pts = ResistorGeometry.waypoints(for: size, m: m)
            let maxY = pts.map { abs($0.y) }.max() ?? 0
            #expect(maxY + bore / 2 <= halfWid - 0.35 + 1e-9)
            #expect(pts.allSatisfy { abs($0.x) <= halfLen + 1e-9 })
            // Pins + straight leads on the centerline at both ends.
            #expect(pts.first == Point(x: -halfLen, y: 0))
            #expect(pts.last == Point(x: halfLen, y: 0))
            #expect(abs(pts[1].y) < 1e-9)
            #expect(abs(pts[pts.count - 2].y) < 1e-9)
        }
    }

    @Test("Smooth lengths track the legacy sim resistance as closely as the wall bar allows")
    func smoothLengthsTrackLegacy() {
        let m = mfg(smooth: true)
        func len(_ size: ResistorSize) -> Double {
            ResistorGeometry.length(of: ResistorGeometry.waypoints(for: size, m: m))
        }
        // S is a straight tube in both styles.
        #expect(abs(len(.small) - ManufacturingConstants.resistorFootprintLength) < 1e-9)
        // M's legacy 20 mm is reachable with comfortable walls.
        #expect(len(.medium) > 17 && len(.medium) < 21.5)
        // L's legacy 34 mm is NOT reachable at 0.5 mm walls — the smooth L
        // packs the closest printable density (~29 mm at 0.6 mm bore).
        #expect(len(.large) > 27 && len(.large) < 32)
        // XL's legacy 44 mm is unreachable too; it saturates at max density,
        // i.e. the same comb as L.
        #expect(abs(len(.extraLarge) - len(.large)) < 1e-9)
        // Monotone: more size never means less resistance.
        #expect(len(.small) < len(.medium) && len(.medium) < len(.large))
    }

    @Test("A wider bore repacks the comb: walls hold, legs thin out")
    func widerBoreRepacks() {
        let wide = mfg(smooth: true, bore: 0.9)
        let pts = ResistorGeometry.waypoints(for: .large, m: wide)
        let xs = legXs(pts)
        #expect(xs.count >= 2)
        for i in 0..<(xs.count - 1) {
            #expect((xs[i + 1] - xs[i]) - 0.9 >= 0.5 - 1e-9)
        }
        let narrow = mfg(smooth: true, bore: 0.6)
        let narrowLegs = legXs(ResistorGeometry.waypoints(for: .large, m: narrow))
        #expect(xs.count < narrowLegs.count)
    }

    @Test("A raised DRC min wall widens the resistor walls too")
    func drcWallFollows() {
        let m = mfg(smooth: true, bore: 0.6, minWall: 0.8)
        let xs = legXs(ResistorGeometry.waypoints(for: .large, m: m))
        for i in 0..<(xs.count - 1) {
            #expect((xs[i + 1] - xs[i]) - 0.6 >= 0.8 - 1e-9)
        }
    }

    // MARK: - Simulation plumbing

    @Test("The simulated resistor length follows the document's smooth flag")
    func simLengthFollowsFlag() {
        var doc = CircuitDocument.blank()
        let r = Component(kind: .resistor, label: "R1", resistorSize: .large)
        doc.logic.components = [r]
        doc.logic.nets = [
            Net(label: "a", pins: [PinRef(componentId: r.id, pinKey: "1")]),
            Net(label: "b", pins: [PinRef(componentId: r.id, pinKey: "2")]),
        ]
        doc.physical.placements = [
            Placement(componentId: r.id, position: Point(x: 25, y: 15),
                      rotation: .r0, layer: .top, depth: 0),
        ]

        doc.manufacturing.smoothResistors = false
        let legacy = PneumaticNetwork.build(from: doc).resistors.first?.pathLengthMm ?? 0
        doc.manufacturing.smoothResistors = true
        let smooth = PneumaticNetwork.build(from: doc).resistors.first?.pathLengthMm ?? 0

        #expect(abs(legacy - 34.0) < 1e-9)
        #expect(abs(smooth - ResistorGeometry.length(
            of: ResistorGeometry.waypoints(for: .large, m: doc.manufacturing))) < 1e-9)
        #expect(smooth < legacy && smooth > 27)
    }
}
