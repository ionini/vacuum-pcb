import Testing
import Foundation
@testable import Vacuum_PCB

/// The connector's screw/pin layout (`ComponentKind.connectorRow`) is the
/// single source of truth the footprint, CAD cutters, 2-D symbols, and outline
/// geometry all read. These lock its contract: `screwCount == 2` reproduces the
/// original two-end-cap geometry exactly (backwards compatibility), and 3+
/// screws split the pins into near-even groups with a fully-cleared screw
/// between each.
@MainActor
struct ConnectorScrewLayoutTests {
    private let pitch = ComponentKind.connectorTubePitch       // within-group pin spacing
    private let offset = ComponentKind.connectorEndCapOffset   // screw ↔ pin clearance
    private let tol = 1e-9

    private func approx(_ a: [Double], _ b: [Double]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { abs($0 - $1) <= tol }
    }

    /// Ascending list reads the same forwards as negated-reversed → symmetric
    /// about the anchor at 0.
    private func isSymmetric(_ xs: [Double]) -> Bool {
        approx(xs, xs.reversed().map { -$0 })
    }

    // MARK: - Backwards compatibility

    /// Two screws must land exactly where the pre-screw-count formula put them:
    /// end caps `connectorEndCapOffset` past the pin span, pins on a centred
    /// `connectorTubePitch` grid.
    @Test func twoScrewsMatchLegacyFormula() {
        for n in 1...12 {
            let halfSpan = Double(n - 1) / 2 * pitch
            let legacyEndCap = halfSpan + offset
            let legacyPins = (0..<n).map { -halfSpan + Double($0) * pitch }

            let row = ComponentKind.connectorRow(pinCount: n, screwCount: 2)
            #expect(approx(row.screwYs, [-legacyEndCap, legacyEndCap]))
            #expect(approx(row.pinYs, legacyPins))
        }
    }

    // MARK: - The prompt's worked examples

    /// 7 pins, 3 screws → screw · 3 pins · screw · 4 pins · screw. The middle
    /// screw sits in the (widened) gap between pin 3 and pin 4.
    @Test func sevenPinsThreeScrews() {
        let row = ComponentKind.connectorRow(pinCount: 7, screwCount: 3)
        #expect(approx(row.screwYs, [-28.5, -2.5, 28.5]))
        #expect(approx(row.pinYs, [-20.5, -15.5, -10.5, 5.5, 10.5, 15.5, 20.5]))
    }

    /// 8 pins, 3 screws → 4 | 4, so the middle screw lands dead centre.
    @Test func eightPinsThreeScrews() {
        let row = ComponentKind.connectorRow(pinCount: 8, screwCount: 3)
        #expect(approx(row.screwYs, [-31, 0, 31]))
        #expect(approx(row.pinYs, [-23, -18, -13, -8, 8, 13, 18, 23]))
    }

    // MARK: - General grouping invariants

    /// For any pin/screw count: the right number of each, everything symmetric,
    /// within-group gaps are one pitch and the `screwCount - 2` interior screws
    /// each open a `2 × offset` gap between groups (with the screw at its
    /// midpoint).
    @Test(arguments: [(7, 3), (8, 3), (7, 4), (12, 5), (10, 2), (5, 6), (1, 2)])
    func groupingInvariants(n: Int, s: Int) {
        let maxS = ComponentKind.connectorMaxScrewCount(pinCount: n)
        let expectedS = min(max(2, s), maxS)
        let groupCount = expectedS - 1

        let row = ComponentKind.connectorRow(pinCount: n, screwCount: s)
        #expect(row.pinYs.count == n)
        #expect(row.screwYs.count == expectedS)
        #expect(row.pinYs == row.pinYs.sorted())
        #expect(row.screwYs == row.screwYs.sorted())
        // End caps and outermost pins are always symmetric (equal end
        // clearance on both ends). Interior screws are only symmetric when the
        // groups come out equal-sized — an odd split like 7 → 3 | 4 is meant
        // to be asymmetric.
        #expect(abs(row.screwYs.first! + row.screwYs.last!) < tol)
        #expect(abs(row.pinYs.first! + row.pinYs.last!) < tol)
        if n % groupCount == 0 {
            #expect(isSymmetric(row.screwYs))
            #expect(isSymmetric(row.pinYs))
        }

        // Consecutive pin gaps: one pitch within a group, 2·offset across a
        // group boundary. So exactly groupCount-1 wide gaps, the rest narrow.
        let gaps = zip(row.pinYs.dropFirst(), row.pinYs).map { $0 - $1 }
        let wide = gaps.filter { abs($0 - 2 * offset) < 1e-6 }.count
        let narrow = gaps.filter { abs($0 - pitch) < 1e-6 }.count
        #expect(wide == groupCount - 1)
        #expect(narrow == n - groupCount)

        // Each interior screw is the midpoint of one wide (between-group) gap.
        let pinYs = row.pinYs
        let interiorScrews = Array(row.screwYs.dropFirst().dropLast())
        for sy in interiorScrews {
            var onAGap = false
            for i in 1..<pinYs.count {
                let lo: Double = pinYs[i - 1]
                let hi: Double = pinYs[i]
                let isWideGap: Bool = (hi - lo) > pitch + 1e-6
                let mid: Double = (lo + hi) / 2
                if isWideGap && abs(sy - mid) < 1e-6 {
                    onAGap = true
                    break
                }
            }
            #expect(onAGap)
        }
    }

    /// Group sizes stay as even as possible, with the remainder on the trailing
    /// groups (so 7 pins / 3 screws is 3 | 4, never 4 | 3).
    @Test func remainderTrailsAndGroupsStayBalanced() {
        // 7 pins, 4 screws → 3 groups → [2, 2, 3].
        let row = ComponentKind.connectorRow(pinCount: 7, screwCount: 4)
        // Group sizes = run lengths of narrow (within-group) gaps + 1.
        let gaps = zip(row.pinYs.dropFirst(), row.pinYs).map { $0 - $1 }
        var sizes: [Int] = []
        var current = 1
        for g in gaps {
            if abs(g - pitch) < 1e-6 { current += 1 } else { sizes.append(current); current = 1 }
        }
        sizes.append(current)
        #expect(sizes == [2, 2, 3])
    }

    // MARK: - Clamping

    @Test func screwCountClampsToValidRange() {
        // Too many screws → capped at pinCount + 1 (one pin per group).
        #expect(ComponentKind.connectorRow(pinCount: 4, screwCount: 99).screwYs.count == 5)
        // Too few → floored at 2.
        #expect(ComponentKind.connectorRow(pinCount: 4, screwCount: 0).screwYs.count == 2)
        #expect(ComponentKind.connectorRow(pinCount: 4, screwCount: -3).screwYs.count == 2)
        // A 1-pin connector can only ever take the two end caps.
        #expect(ComponentKind.connectorMaxScrewCount(pinCount: 1) == 2)
        #expect(ComponentKind.connectorMaxScrewCount(pinCount: 4) == 5)
        #expect(ComponentKind.connectorMinScrewCount == 2)
    }

    // MARK: - Footprint integration

    /// The footprint keeps one pin per pin (screws are mechanical-only) but the
    /// protrusion gets longer when interior screws are added, and the role flip
    /// still puts pin 1 at the expected end.
    @Test func footprintReflectsScrewCount() {
        let m = ManufacturingConstants.defaults
        let fp2 = ComponentKind.connectorFootprint(pinCount: 7, screwCount: 2, role: .bottomExtend, manufacturing: m)
        let fp3 = ComponentKind.connectorFootprint(pinCount: 7, screwCount: 3, role: .bottomExtend, manufacturing: m)
        #expect(fp2.pins.count == 7)
        #expect(fp3.pins.count == 7)
        #expect(fp3.exclusionRect.size.height > fp2.exclusionRect.size.height)

        let row = ComponentKind.connectorRow(pinCount: 7, screwCount: 3)
        // bottomExtend: pin "1" sits at the largest local Y.
        let p1Bottom = fp3.pins.first { $0.key == "1" }!.offset.y
        #expect(abs(p1Bottom - row.pinYs.last!) < tol)
        // topExtend: pin "1" sits at the smallest local Y.
        let fpTop = ComponentKind.connectorFootprint(pinCount: 7, screwCount: 3, role: .topExtend, manufacturing: m)
        let p1Top = fpTop.pins.first { $0.key == "1" }!.offset.y
        #expect(abs(p1Top - row.pinYs.first!) < tol)
    }
}
