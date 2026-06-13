import Testing
import Foundation
@testable import Vacuum_PCB

/// Invariants the "Minimize" action must hold. The minimiser is a pure
/// `CircuitDocument -> CircuitDocument` function, so these are property checks:
/// they don't pin an exact layout (annealing's specific output isn't a
/// contract), they pin the *guarantees* — never break the board, never grow
/// the area, stay deterministic, leave the netlist and connector edges alone.
///
/// Isolated to the main actor: the model layer (`Minimizer`, `DRC`,
/// `AutoRouter`, and the document types' synthesized `Equatable` conformances)
/// is main-actor-isolated under the project's default isolation, so the suite
/// must be too in order to call it and compare its results.
@MainActor
struct MinimizerTests {

    // MARK: - Fixtures

    /// Three primitives (vacuum source → resistor → output port) wired as two
    /// nets, placed with slack in the lower-left of a roomy board and routed by
    /// the auto-router so the starting layout is DRC-clean.
    private func placedRoutedFixture() -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 70, height: 40))

        let vac = Component(kind: .vacuumSource, label: "VAC")
        let r1 = Component(kind: .resistor, label: "R1", resistorSize: .medium)
        let out = Component(kind: .port, label: "OUT1", portDirection: .output)
        doc.logic.components = [vac, r1, out]
        doc.logic.nets = [
            Net(label: "n1", pins: [PinRef(componentId: vac.id, pinKey: "p"),
                                    PinRef(componentId: r1.id, pinKey: "1")]),
            Net(label: "n2", pins: [PinRef(componentId: r1.id, pinKey: "2"),
                                    PinRef(componentId: out.id, pinKey: "p")]),
        ]
        doc.physical.placements = [
            // VAC faces −X (its near left edge) so its edge outlet is a short
            // stub, not a 60 mm bore sweeping across the board and crossing n2.
            Placement(componentId: vac.id, position: Point(x: 10, y: 12), rotation: .r180, layer: .top),
            Placement(componentId: r1.id, position: Point(x: 26, y: 14), rotation: .r0, layer: .top),
            Placement(componentId: out.id, position: Point(x: 40, y: 18), rotation: .r0, layer: .top),
        ]
        route(&doc)
        return doc
    }

    /// A one-pin connector anchored to the south edge, wired to an output port.
    private func connectorFixture() -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 70, height: 40))

        let conn = Component(kind: .connector, label: "J1",
                             connectorPinCount: 1, connectorRole: .bottomExtend)
        let out = Component(kind: .port, label: "OUT1", portDirection: .output)
        doc.logic.components = [conn, out]
        doc.logic.nets = [
            Net(label: "n1", pins: [PinRef(componentId: conn.id, pinKey: "1"),
                                    PinRef(componentId: out.id, pinKey: "p")]),
        ]
        let anchor = EdgeAnchor(edge: .south, offsetAlongEdge: 35)
        doc.physical.placements = [
            Placement(componentId: conn.id,
                      position: anchor.worldPosition(in: doc.physical.boardOutline),
                      rotation: Edge.south.outwardRotation,
                      layer: .bottom, depth: 0, edgeAnchor: anchor),
            // bottomExtend connector pins land on the bottom plate, so the port
            // shares that plate for a same-layer route.
            Placement(componentId: out.id, position: Point(x: 35, y: 22), rotation: .r0, layer: .bottom),
        ]
        route(&doc)
        return doc
    }

    private func route(_ doc: inout CircuitDocument) {
        for entry in AutoRouter.plan(doc) {
            if let i = doc.physical.routes.firstIndex(where: { $0.netId == entry.netId }) {
                doc.physical.routes[i].segments.append(entry.segment)
            } else {
                doc.physical.routes.append(Route(netId: entry.netId, segments: [entry.segment]))
            }
        }
    }

    private func dieArea(_ doc: CircuitDocument) -> Double {
        doc.physical.boardOutline.size.width * doc.physical.boardOutline.size.height
    }

    /// Iteration-bounded (huge time budget) so runs are clock-independent and
    /// therefore deterministic across machines.
    private func testOptions(seed: UInt64 = 7) -> Minimizer.Options {
        Minimizer.Options(maxIterations: 150, timeBudget: 1e9, seed: seed, margin: 3.0)
    }

    // MARK: - Tests

    @Test("Starting fixture is DRC-clean (so the guarantees below are meaningful)")
    func fixtureIsClean() {
        #expect(DRC.check(placedRoutedFixture()).isEmpty)
    }

    @Test("Minimize never increases the DRC issue count — the core 'without breaking anything' guarantee")
    func neverWorsensDRC() {
        let input = placedRoutedFixture()
        let before = DRC.check(input).count
        let result = Minimizer.minimize(input, options: testOptions())
        #expect(DRC.check(result).count <= before)
    }

    @Test("Minimize never grows the die (outline) area")
    func doesNotIncreaseDieArea() {
        let input = placedRoutedFixture()
        let result = Minimizer.minimize(input, options: testOptions())
        // The feature box may grow as edge features move to the perimeter; the
        // die must never grow. Tiny epsilon for floating-point noise.
        #expect(dieArea(result) <= dieArea(input) + 1e-6)
    }

    @Test("Minimize shrinks the board outline when the layout has slack")
    func shrinksOutlineWhenSlack() {
        let input = placedRoutedFixture()
        let result = Minimizer.minimize(input, options: testOptions())
        #expect(dieArea(result) < dieArea(input))
    }

    @Test("Minimize is deterministic for a fixed seed")
    func isDeterministic() {
        let input = placedRoutedFixture()
        let a = Minimizer.minimize(input, options: testOptions(seed: 99))
        let b = Minimizer.minimize(input, options: testOptions(seed: 99))
        // Evaluate `==` here (main-actor context) rather than inside the
        // nonisolated `#expect` autoclosure, where the model types' main-actor
        // -isolated Equatable conformance can't be used.
        let identical = a.physical == b.physical
        #expect(identical)
    }

    @Test("Minimize leaves the logic graph (netlist) untouched")
    func logicGraphUnchanged() {
        let input = placedRoutedFixture()
        let result = Minimizer.minimize(input, options: testOptions())
        let unchanged = result.logic == input.logic
        #expect(unchanged)
    }

    @Test("A connector stays anchored to its original edge")
    func connectorStaysOnItsEdge() {
        let input = connectorFixture()
        let connId = input.logic.components.first { $0.kind == .connector }!.id
        let result = Minimizer.minimize(input, options: testOptions())
        let placement = result.physical.placements.first { $0.componentId == connId }
        let stillSouth = placement?.edgeAnchor?.edge == .south
        #expect(stillSouth)
    }

    @Test("Minimize on an empty document is a no-op, not a crash")
    func handlesEmptyDocument() {
        let result = Minimizer.minimize(.blank(), options: testOptions())
        #expect(result.physical.placements.isEmpty)
    }

    /// A genuinely loose single-layer board: a short chain of parts clustered in
    /// the corner of a large board, with lots of empty space. The compactor
    /// should adopt a result and shrink the outline.
    private func looseBoard() -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 120, height: 90))
        let vac = Component(kind: .vacuumSource, label: "VAC")
        let r1 = Component(kind: .resistor, label: "R1", resistorSize: .medium)
        let r2 = Component(kind: .resistor, label: "R2", resistorSize: .medium)
        let out = Component(kind: .port, label: "OUT1", portDirection: .output)
        doc.logic.components = [vac, r1, r2, out]
        doc.logic.nets = [
            Net(label: "n1", pins: [PinRef(componentId: vac.id, pinKey: "p"), PinRef(componentId: r1.id, pinKey: "1")]),
            Net(label: "n2", pins: [PinRef(componentId: r1.id, pinKey: "2"), PinRef(componentId: r2.id, pinKey: "1")]),
            Net(label: "n3", pins: [PinRef(componentId: r2.id, pinKey: "2"), PinRef(componentId: out.id, pinKey: "p")]),
        ]
        doc.physical.placements = [
            // VAC faces −X (its near left edge) so its outlet doesn't sweep the
            // full board width as a phantom channel across the other nets.
            Placement(componentId: vac.id, position: Point(x: 12, y: 12), rotation: .r180, layer: .top),
            Placement(componentId: r1.id, position: Point(x: 26, y: 16), rotation: .r0, layer: .top),
            Placement(componentId: r2.id, position: Point(x: 22, y: 30), rotation: .r0, layer: .top),
            Placement(componentId: out.id, position: Point(x: 34, y: 20), rotation: .r0, layer: .top),
        ]
        route(&doc)
        return doc
    }

    @Test("Minimize compacts a loose board: adopts a smaller, still-clean result")
    func compactsALooseBoard() {
        let input = looseBoard()
        #expect(DRC.check(input).isEmpty)   // fixture starts clean
        let (result, stats) = Minimizer.report(input, options: testOptions(seed: 3))
        #expect(stats.adopted)
        #expect(dieArea(result) < dieArea(input))
        #expect(stats.finalIssues <= stats.baselineIssues)
    }

    /// A board whose die is pinned at all four edges by vents (so the outline
    /// can't shrink), with a free resistor displaced into the wrong corner away
    /// from its net. Minimize should pull it back — adopting a tidier layout
    /// (less wirelength) even though the die size is unchanged.
    private func displacedOnFullDie() -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 40, height: 30))
        let vN = Component(kind: .atmVent, label: "VN")
        let vS = Component(kind: .atmVent, label: "VS")
        let vE = Component(kind: .atmVent, label: "VE")
        let vW = Component(kind: .atmVent, label: "VW")
        let r1 = Component(kind: .resistor, label: "R1", resistorSize: .medium)
        doc.logic.components = [vN, vS, vE, vW, r1]
        // R1 belongs near the north + east vents, but we place it in the SW
        // corner — far from both, so its wirelength is large.
        doc.logic.nets = [
            Net(label: "n1", pins: [PinRef(componentId: vN.id, pinKey: "p"), PinRef(componentId: r1.id, pinKey: "1")]),
            Net(label: "n2", pins: [PinRef(componentId: r1.id, pinKey: "2"), PinRef(componentId: vE.id, pinKey: "p")]),
        ]
        doc.physical.placements = [
            Placement(componentId: vN.id, position: Point(x: 20, y: 28), rotation: .r0, layer: .top),
            Placement(componentId: vS.id, position: Point(x: 20, y: 2), rotation: .r0, layer: .top),
            Placement(componentId: vE.id, position: Point(x: 38, y: 15), rotation: .r0, layer: .top),
            Placement(componentId: vW.id, position: Point(x: 2, y: 15), rotation: .r0, layer: .top),
            Placement(componentId: r1.id, position: Point(x: 8, y: 8), rotation: .r0, layer: .top),
        ]
        route(&doc)
        return doc
    }

    @Test("Minimize pulls a displaced component back even when the die can't shrink")
    func tidiesADisplacedComponent() {
        let input = displacedOnFullDie()
        let (result, stats) = Minimizer.report(input, options: testOptions(seed: 5))
        #expect(stats.adopted)
        // Wirelength drops sharply (the resistor moved back toward its net)…
        #expect(Minimizer.hpwl(of: result) < Minimizer.hpwl(of: input) * 0.99)
        // …without growing the die (the vents pin it; this is the tidier path)…
        #expect(dieArea(result) <= dieArea(input) + 1e-6)
        // …and without worsening DRC relative to the starting board.
        #expect(stats.finalIssues <= stats.baselineIssues)
    }
}
