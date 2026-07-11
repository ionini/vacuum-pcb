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

    // MARK: - Debug-ports mode

    /// Debug print replaces the protrusion with an inset row of edge bores:
    /// `connectorDebugPortPitch` centre-to-centre, centred on the anchor,
    /// pins `connectorDebugPortInset` inside the edge (local -X), one
    /// pitch-wide slot per pin, and the rect flush with the edge at x = 0.
    /// Screw count must have no effect — debug boards print none.
    @Test(arguments: [1, 2, 5, 8])
    func debugPortsFootprintLayout(n: Int) {
        let m = ManufacturingConstants.defaults
        let dPitch = ComponentKind.connectorDebugPortPitch
        let inset = ComponentKind.connectorDebugPortInset

        let fp = ComponentKind.connectorFootprint(
            pinCount: n, screwCount: 4, role: .bottomExtend,
            debugPorts: true, manufacturing: m
        )
        #expect(fp.pins.count == n)
        #expect(fp.pins.allSatisfy { abs($0.offset.x + inset) <= tol })
        let ys = fp.pins.map(\.offset.y).sorted()
        let gaps = zip(ys.dropFirst(), ys).map { $0 - $1 }
        #expect(gaps.allSatisfy { abs($0 - dPitch) <= tol })
        #expect(abs(ys.first! + ys.last!) <= tol)          // centred on the anchor
        #expect(abs(fp.exclusionRect.size.height - Double(n) * dPitch) <= tol)
        #expect(abs(fp.exclusionRect.size.width - inset) <= tol)
        #expect(abs(fp.exclusionRect.origin.x + inset) <= tol)
        #expect(abs(fp.exclusionRect.origin.x + fp.exclusionRect.size.width) <= tol) // maxX = edge

        // Screw count is irrelevant in debug mode.
        let fp2 = ComponentKind.connectorFootprint(
            pinCount: n, screwCount: 2, role: .bottomExtend,
            debugPorts: true, manufacturing: m
        )
        #expect(fp.pins == fp2.pins)
        #expect(fp.exclusionRect == fp2.exclusionRect)
    }

    /// The role flip orders debug pins exactly like the normal footprint,
    /// so toggling debug never swaps which physical end is pin 1.
    @Test(arguments: [ConnectorRole.bottomExtend, .topExtend])
    func debugPortsRoleFlipMatchesNormal(role: ConnectorRole) {
        let m = ManufacturingConstants.defaults
        func keysByY(_ fp: Footprint) -> [String] {
            fp.pins.sorted { $0.offset.y < $1.offset.y }.map(\.key)
        }
        let normal = ComponentKind.connectorFootprint(pinCount: 5, role: role, manufacturing: m)
        let debug = ComponentKind.connectorFootprint(pinCount: 5, role: role, debugPorts: true, manufacturing: m)
        #expect(keysByY(normal) == keysByY(debug))
    }

    /// Off (or omitted) leaves the classic mating footprint untouched, and
    /// the flag rides through `Component.footprint(_:)`.
    @Test func debugPortsDefaultsOffAndThreadsThroughComponent() {
        let m = ManufacturingConstants.defaults
        let classic = ComponentKind.connectorFootprint(pinCount: 4, role: .topExtend, manufacturing: m)
        let explicitOff = ComponentKind.connectorFootprint(
            pinCount: 4, role: .topExtend, debugPorts: false, manufacturing: m
        )
        #expect(classic.pins == explicitOff.pins)
        #expect(classic.exclusionRect == explicitOff.exclusionRect)

        let comp = Component(
            kind: .connector, label: "J1",
            connectorPinCount: 4, connectorRole: .topExtend,
            connectorDebugPorts: true
        )
        let viaComponent = comp.footprint(m)
        let direct = ComponentKind.connectorFootprint(
            pinCount: 4, role: .topExtend, debugPorts: true, manufacturing: m
        )
        #expect(viaComponent.pins == direct.pins)
        #expect(viaComponent.exclusionRect == direct.exclusionRect)
    }

    // MARK: - Per-socket layers (debug mode)

    /// Per-socket layers bake into `absoluteLayer` positionally by pin
    /// number; missing entries fall back to the role's plate at depth 0;
    /// the normal (mating) footprint never carries absolute layers.
    @Test func debugPortLayersBakeIntoFootprint() {
        let m = ManufacturingConstants.defaults
        let layers = [Layer(plate: .top, depth: 0), Layer(plate: .bottom, depth: 1)]
        let fp = ComponentKind.connectorFootprint(
            pinCount: 3, role: .bottomExtend, debugPorts: true,
            debugPortLayers: layers, manufacturing: m
        )
        #expect(fp.pin("1")?.absoluteLayer == layers[0])
        #expect(fp.pin("2")?.absoluteLayer == layers[1])
        #expect(fp.pin("3")?.absoluteLayer
                == ComponentKind.connectorDebugPortDefaultLayer(role: .bottomExtend))
        #expect(fp.pin("3")?.absoluteLayer == Layer(plate: .bottom, depth: 0))

        let normal = ComponentKind.connectorFootprint(pinCount: 3, role: .bottomExtend, manufacturing: m)
        #expect(normal.pins.allSatisfy { $0.absoluteLayer == nil })
    }

    /// F on one socket advances it through the top-then-bottom layer cycle
    /// and stores the result on the component; the choice survives turning
    /// debug off and back on; cycling it home collapses the array to nil.
    @Test func cycleDebugPortLayerRoundTrips() {
        var doc = VPCBDocument(circuit: .blank())
        let comp = Component(
            kind: .connector, label: "J1",
            connectorPinCount: 2, connectorRole: .bottomExtend,
            connectorDebugPorts: true
        )
        doc.circuit.logic.components.append(comp)
        let bottom0 = Layer(plate: .bottom, depth: 0)
        let top0 = Layer(plate: .top, depth: 0)

        // Role default is bottom0; one advance wraps pin 2 to top0.
        PhysicalActions.cycleConnectorDebugPorts(document: &doc, componentId: comp.id, pinKeys: ["2"])
        var c = doc.circuit.logic.components[0]
        #expect(c.connectorDebugPortLayers == [bottom0, top0])
        #expect(c.connectorDebugPortLayer("1") == bottom0)
        #expect(c.connectorDebugPortLayer("2") == top0)
        #expect(c.footprint(ManufacturingConstants.defaults).pin("2")?.absoluteLayer == top0)

        // Toggling debug off keeps the stored layers (that's the memory).
        doc.circuit.logic.components[0].connectorDebugPorts = nil
        #expect(doc.circuit.logic.components[0].connectorDebugPortLayers == [bottom0, top0])
        doc.circuit.logic.components[0].connectorDebugPorts = true

        // Advancing pin 2 again returns the row to the role default → nil.
        PhysicalActions.cycleConnectorDebugPorts(document: &doc, componentId: comp.id, pinKeys: ["2"])
        c = doc.circuit.logic.components[0]
        #expect(c.connectorDebugPortLayers == nil)
        #expect(c.connectorDebugPortLayer("2") == bottom0)
    }

    /// F with the whole debug connector selected advances every socket in
    /// lockstep and leaves `placement.layer` (the role plate) alone.
    @Test func flipLayerOnSelectedDebugConnectorCyclesAllSockets() {
        var doc = VPCBDocument(circuit: .blank())
        let comp = Component(
            kind: .connector, label: "J1",
            connectorPinCount: 3, connectorRole: .bottomExtend,
            connectorDebugPorts: true
        )
        doc.circuit.logic.components.append(comp)
        doc.circuit.physical.placements.append(Placement(
            componentId: comp.id, position: Point(x: 0, y: 0),
            rotation: .r0, layer: .bottom
        ))

        PhysicalActions.flipLayer(document: &doc, selection: .placement(comp.id))
        let c = doc.circuit.logic.components[0]
        let top0 = Layer(plate: .top, depth: 0)
        #expect(c.connectorDebugPortLayers == [top0, top0, top0])
        #expect(doc.circuit.physical.placements[0].layer == .bottom)
    }
}
