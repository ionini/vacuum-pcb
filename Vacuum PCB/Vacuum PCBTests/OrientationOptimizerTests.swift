import Testing
import Foundation
@testable import Vacuum_PCB

/// Tests for the transistor-orientation pre-pass that Minimize runs to cut
/// cross-silicone vias. The optimizer's objective (how many nets touch both
/// plates) depends only on each transistor's flip, never on XY/route, so the
/// optimizer-level tests build placements + nets without routing.
///
/// Main-actor isolated for the same reason as `MinimizerTests`: the model layer
/// is main-actor-isolated under the project's default isolation.
@MainActor
struct OrientationOptimizerTests {

    // MARK: - Fixtures

    /// Two transistors in series (Q1.b → Q2.gate) fed from VAC, output to a
    /// port, all placed gate-on-top (`layer: .top`). Unrouted.
    ///
    /// With every transistor gate-up, all three nets cross the silicone:
    ///  * vrail = {VAC.p (top), Q1.a (pad → bottom)}
    ///  * stage = {Q1.b (pad → bottom), Q2.gate (top)}
    ///  * outn  = {Q2.b (pad → bottom), OUT.p (top)}
    /// VAC and OUT are fixed on top, so the alternating chain can't be made
    /// fully same-plate — exactly one crossing is forced. The optimum is 1.
    private func transistorChain() -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 100, height: 60))
        let vac = Component(kind: .vacuumSource, label: "VAC")
        let t1 = Component(kind: .transistor, label: "Q1")
        let t2 = Component(kind: .transistor, label: "Q2")
        let out = Component(kind: .port, label: "OUT", portDirection: .output)
        doc.logic.components = [vac, t1, t2, out]
        doc.logic.nets = [
            Net(label: "vrail", pins: [PinRef(componentId: vac.id, pinKey: "p"),
                                       PinRef(componentId: t1.id, pinKey: "a")]),
            Net(label: "stage", pins: [PinRef(componentId: t1.id, pinKey: "b"),
                                       PinRef(componentId: t2.id, pinKey: "gate")]),
            Net(label: "outn", pins: [PinRef(componentId: t2.id, pinKey: "b"),
                                      PinRef(componentId: out.id, pinKey: "p")]),
        ]
        doc.physical.placements = [
            Placement(componentId: vac.id, position: Point(x: 12, y: 30), rotation: .r180, layer: .top),
            Placement(componentId: t1.id, position: Point(x: 36, y: 30), rotation: .r0, layer: .top),
            Placement(componentId: t2.id, position: Point(x: 60, y: 30), rotation: .r0, layer: .top),
            Placement(componentId: out.id, position: Point(x: 88, y: 30), rotation: .r0, layer: .top),
        ]
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

    private func minimizeOptions(seed: UInt64 = 7) -> Minimizer.Options {
        Minimizer.Options(maxIterations: 150, timeBudget: 1e9, seed: seed, margin: 3.0)
    }

    // MARK: - Optimizer (route-independent)

    @Test("Reduces cross-silicone nets to the analytic minimum")
    func reducesCrossings() {
        let r = OrientationOptimizer.optimize(transistorChain(), seed: 7)
        #expect(r.crossingBefore == 3)   // all three nets cross with gate-on-top
        #expect(r.crossingAfter == 1)    // VAC + OUT both fixed top force exactly one
        #expect(r.flipsApplied >= 1)
    }

    @Test("Deterministic for a fixed seed")
    func deterministic() {
        let doc = transistorChain()
        let a = OrientationOptimizer.optimize(doc, seed: 42)
        let b = OrientationOptimizer.optimize(doc, seed: 42)
        let sameLayers = a.layerForTransistor == b.layerForTransistor
        #expect(sameLayers)
        #expect(a.crossingAfter == b.crossingAfter)
    }

    @Test("Only transistors are flippable — subparts and other kinds are excluded")
    func onlyTransistorsFlippable() {
        let doc = transistorChain()
        let ids = OrientationOptimizer.flippableTransistorIds(doc)
        let kinds = Set(ids.compactMap { id in doc.logic.components.first { $0.id == id }?.kind })
        #expect(kinds == [.transistor])   // not VAC, not the port — and by the same filter, not subparts
        #expect(ids.count == 2)
    }

    @Test("An already-optimal orientation is a no-op on a second pass")
    func idempotent() {
        var doc = transistorChain()
        let first = OrientationOptimizer.optimize(doc, seed: 7)
        _ = OrientationOptimizer.apply(first, to: &doc)
        let second = OrientationOptimizer.optimize(doc, seed: 7)
        #expect(second.flipsApplied == 0)
        #expect(second.crossingAfter == first.crossingAfter)
    }

    @Test("No transistors → no flips, nothing to change")
    func noTransistors() {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 40, height: 30))
        let vac = Component(kind: .vacuumSource, label: "VAC")
        let out = Component(kind: .port, label: "OUT", portDirection: .output)
        doc.logic.components = [vac, out]
        doc.logic.nets = [Net(label: "n1", pins: [PinRef(componentId: vac.id, pinKey: "p"),
                                                  PinRef(componentId: out.id, pinKey: "p")])]
        doc.physical.placements = [
            Placement(componentId: vac.id, position: Point(x: 8, y: 15), rotation: .r0, layer: .top),
            Placement(componentId: out.id, position: Point(x: 30, y: 15), rotation: .r0, layer: .top),
        ]
        let r = OrientationOptimizer.optimize(doc)
        #expect(r.flipsApplied == 0)
        #expect(r.layerForTransistor.isEmpty)
    }

    // MARK: - Minimizer integration

    @Test("Minimize plumbs the orientation result and cuts vias when enabled")
    func minimizeReducesVias() {
        var input = transistorChain()
        route(&input)
        let baseline = DRC.check(input).count
        let (result, stats) = Minimizer.report(input, options: minimizeOptions())
        #expect(stats.crossSiliconeViasBefore >= 1)
        #expect(stats.orientationFlips >= 1)
        #expect(stats.finalIssues <= baseline)
        #expect(result.physical.crossSiliconeViaPositions().count < stats.crossSiliconeViasBefore)
    }

    @Test("Disabling the orientation pass flips nothing")
    func toggleOff() {
        var input = transistorChain()
        route(&input)
        var opts = minimizeOptions()
        opts.optimizeOrientation = false
        let (_, stats) = Minimizer.report(input, options: opts)
        #expect(stats.orientationFlips == 0)
    }

    @Test("Cheap via counter is an upper bound on the exact paired count")
    func viaCounterProxy() {
        var input = transistorChain()
        route(&input)
        let exact = input.physical.crossSiliconeViaPositions().count
        let proxy = Minimizer.crossSiliconeViaCount(input)
        #expect(exact >= 1)         // the routed gate-on-top chain crosses the silicone
        #expect(proxy >= exact)     // proxy counts paired crossings without XY matching
    }
}
