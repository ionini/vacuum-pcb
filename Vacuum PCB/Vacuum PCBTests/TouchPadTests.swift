import Testing
import Foundation
@testable import Vacuum_PCB

/// `ComponentKind.touchPad` — a finger-covered input. Physically it is a
/// testing-point bore (vertical tapered tap out to the plate face); in the
/// simulator it is a hard input with two states: *open* (the bore vents the
/// net to atmosphere, the default) and *covered* (`NaN`: drives nothing, the
/// net floats and whatever else hangs on it — a resistor to VAC — decides).
@MainActor
struct TouchPadTests {

    // MARK: - Fixtures

    /// VAC ── R(large) ── N ── T1 (pad), with OUT1 probing N. The circuit
    /// Ioni uses on the bench: open pad → N at atmosphere; covered → the
    /// resistor pulls N down to vacuum.
    private struct Divider {
        var doc: CircuitDocument
        let pad: Component
        let probe: Component
        let netN: UUID
    }

    private func makeDivider() -> Divider {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 60, height: 40))
        let vac = Component(kind: .vacuumSource, label: "VAC")
        let r = Component(kind: .resistor, label: "R1", resistorSize: .large)
        let pad = Component(kind: .touchPad, label: "T1")
        let out = Component(kind: .port, label: "OUT1", portDirection: .output)
        doc.logic.components = [vac, r, pad, out]
        let rail = Net(label: "rail", pins: [
            PinRef(componentId: vac.id, pinKey: "p"),
            PinRef(componentId: r.id, pinKey: "1"),
        ])
        let n = Net(label: "N", pins: [
            PinRef(componentId: r.id, pinKey: "2"),
            PinRef(componentId: pad.id, pinKey: "p"),
            PinRef(componentId: out.id, pinKey: "p"),
        ])
        doc.logic.nets = [rail, n]
        doc.physical.placements = [
            Placement(componentId: vac.id, position: Point(x: 5, y: 20), rotation: .r180, layer: .top),
            Placement(componentId: r.id, position: Point(x: 25, y: 20), rotation: .r0, layer: .top),
            Placement(componentId: pad.id, position: Point(x: 45, y: 20), rotation: .r0, layer: .top),
            Placement(componentId: out.id, position: Point(x: 55, y: 20), rotation: .r0, layer: .top),
        ]
        return Divider(doc: doc, pad: pad, probe: out, netN: n.id)
    }

    /// Fixed-step headless run, the way `vacuum-cli simulate` does it.
    private func settle(_ network: PneumaticNetwork, inputs: [UUID: Double],
                        params: SimulationParameters = .defaults,
                        steps: Int = 4000) -> [UUID: Double] {
        let pressures = Validators.seedPressures(network: network, params: params, inputs: inputs)
        let compiled = SimulationEngine.compile(
            network: network, params: params,
            hardInputStates: SimulationEngine.hardInputStates(network: network, inputs: inputs))
        guard compiled.freeCount > 0 else {
            var p = pressures
            var t: [UUID: Double] = [:]
            for _ in 0..<steps {
                SimulationEngine.step(network: network, params: params, pressures: &p,
                                      inputs: inputs, transistorOpenness: &t)
            }
            return p
        }
        let soft = SimulationEngine.softInputValues(network: network, inputs: inputs)
        var run = SimulationEngine.makeRunState(compiled: compiled, pressures: pressures,
                                                transistorOpenness: [:])
        for _ in 0..<steps {
            SimulationEngine.step(compiled: compiled, params: params, state: &run, softInputValues: soft)
        }
        return SimulationEngine.publish(compiled: compiled, state: run).pressures
    }

    // MARK: - Network / engine

    @Test("A touch pad builds as a hard, touch-pad-flagged input on its net")
    func buildsAsInput() {
        let d = makeDivider()
        let net = PneumaticNetwork.build(from: d.doc)
        let inputs = net.inputs.filter { $0.id == d.pad.id }
        #expect(inputs.count == 1)
        #expect(inputs.first?.isTouchPad == true)
        #expect(inputs.first?.soft == false)
        #expect(inputs.first?.netId == d.netN)
        // It is an input, not a probe.
        #expect(!net.probes.contains { $0.id == d.pad.id })
    }

    @Test("Hard-input state: NaN is 'covered' only for a pad; absent = open/atm")
    func hardInputStateResolution() {
        let pad = PneumaticNetwork.Input(id: UUID(), label: "T1", netId: UUID(), isTouchPad: true)
        let port = PneumaticNetwork.Input(id: UUID(), label: "IN1", netId: UUID())
        #expect(SimulationEngine.hardInputState(pad, raw: nil) == .atm)
        #expect(SimulationEngine.hardInputState(pad, raw: 1.0) == .atm)
        #expect(SimulationEngine.hardInputState(pad, raw: .nan) == .none)
        #expect(SimulationEngine.hardInputState(pad, raw: 0.0) == .vac)
        // A plain input keeps the historical NaN → vac fall-through.
        #expect(SimulationEngine.hardInputState(port, raw: .nan) == .vac)
        #expect(SimulationEngine.hardInputState(port, raw: nil) == .atm)
        #expect(PneumaticNetwork.Input.touchPadIsCovered(PneumaticNetwork.Input.touchPadCoveredValue))
        #expect(!PneumaticNetwork.Input.touchPadIsCovered(PneumaticNetwork.Input.touchPadOpenValue))
        #expect(!PneumaticNetwork.Input.touchPadIsCovered(nil))
    }

    @Test("Open pad vents the divider node to atmosphere; covering it lets R pull vacuum")
    func dividerFlipsWhenCovered() {
        let d = makeDivider()
        let net = PneumaticNetwork.build(from: d.doc)
        let probe = net.probes.first { $0.id == d.probe.id }!
        let params = SimulationParameters.defaults

        // Default (no entry) = open: N is a hard atm anchor.
        let open = settle(net, inputs: [:])
        #expect(abs((open[probe.nodeId] ?? 0) - 1.0) < 1e-6)

        // Covered: N floats and R to VAC pulls it down. With the bench-fitted
        // global leak (0.013) an L resistor only gets a floating net part way
        // (~0.6 atm — leak-limited, exactly the register sweet-spot finding),
        // so assert a clear drop here and the full rail with the leak off.
        let covered = settle(net, inputs: [d.pad.id: PneumaticNetwork.Input.touchPadCoveredValue])
        let pN = covered[probe.nodeId] ?? 1
        #expect(pN < 0.75, "covered pad should pull well below atmosphere, got \(pN)")

        var sealed = params
        sealed.leakConductance = 0
        let tight = settle(net, inputs: [d.pad.id: PneumaticNetwork.Input.touchPadCoveredValue],
                           params: sealed, steps: 20000)
        let pTight = tight[probe.nodeId] ?? 1
        #expect(abs(pTight - sealed.pumpMaxVacuum) < 0.05,
                "leak-free covered pad should sit at the rail, got \(pTight)")

        // Explicit open value restores atmosphere.
        let reopened = settle(net, inputs: [d.pad.id: PneumaticNetwork.Input.touchPadOpenValue])
        #expect(abs((reopened[probe.nodeId] ?? 0) - 1.0) < 1e-6)
    }

    @Test("Covering a pad changes the compile signature (recompile, not a stale anchor set)")
    func compileSignatureTracksCover() {
        let d = makeDivider()
        let net = PneumaticNetwork.build(from: d.doc)
        let open = SimulationEngine.hardInputStates(network: net, inputs: [:])
        let covered = SimulationEngine.hardInputStates(
            network: net, inputs: [d.pad.id: PneumaticNetwork.Input.touchPadCoveredValue])
        #expect(open != covered)
        #expect(covered.contains(.none))
    }

    // MARK: - Labels / footprint

    @Test("Pads are labelled T1, T2… (S is taken by screws) and are single-pin")
    func labelsAndPins() {
        var logic = LogicGraph(components: [], nets: [])
        #expect(logic.nextLabel(for: .touchPad) == "T1")
        logic.components.append(Component(kind: .touchPad, label: "T1"))
        #expect(logic.nextLabel(for: .touchPad) == "T2")
        #expect(ComponentKind.touchPad.pinKeys == ["p"])
        let fp = ComponentKind.touchPad.footprint(resistorSize: nil, manufacturing: .defaults)
        #expect(fp.pins.count == 1)
        #expect(fp.pins.first?.offset == .zero)
    }

    // MARK: - Physical: volumes + DRC (same as a testing point)

    /// Pad pin at the end of its net's route, so the volume decomposition
    /// picks the pin up as a hole and the pad as a vertical tap.
    private func makeRoutedPad(padAt p: Point, depth: Int = 0) -> (CircuitDocument, Component, UUID) {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 50, height: 30))
        let pad = Component(kind: .touchPad, label: "T1")
        doc.logic.components = [pad]
        let n = Net(label: "N", pins: [PinRef(componentId: pad.id, pinKey: "p")])
        doc.logic.nets = [n]
        doc.physical.placements = [
            Placement(componentId: pad.id, position: p, rotation: .r0, layer: .top, depth: depth),
        ]
        doc.physical.routes = [Route(netId: n.id, segments: [
            Segment(waypoints: [Waypoint(position: Point(x: 10, y: p.y)), Waypoint(position: p)],
                    layer: Layer(plate: .top, depth: depth)),
        ])]
        return (doc, pad, n.id)
    }

    @Test("A pad joins its cavity as a vertical tap, making the cavity external")
    func padIsAVolumeTap() {
        let (doc, _, netId) = makeRoutedPad(padAt: Point(x: 30, y: 15))
        let vols = physicalVolumes(doc)
        let v = vols.first { $0.nets.contains(netId) }
        #expect(v != nil)
        #expect(v?.testPoints.count == 1)
        #expect(v?.testPoints.first?.plate == .top)
        #expect(v?.testPoints.first?.pos == Point(x: 30, y: 15))
    }

    private func tapIssues(_ doc: CircuitDocument) -> [DRC.Issue] {
        DRC.check(doc).filter { if case .testPointClearance = $0.kind { return true }; return false }
    }

    @Test("A pad bore within the min wall of a foreign channel flags like a test point")
    func padClearanceAgainstForeignChannel() {
        var (doc, pad, _) = makeRoutedPad(padAt: Point(x: 30, y: 15))
        // Foreign channel whose nearest point (30,14) is 1 mm from the pad.
        let foreign = Net(label: "nc", pins: [])
        doc.logic.nets.append(foreign)
        doc.physical.routes.append(Route(netId: foreign.id, segments: [
            Segment(waypoints: [Waypoint(position: Point(x: 30, y: 14)), Waypoint(position: Point(x: 30, y: 5))],
                    layer: .top),
        ]))
        let issues = tapIssues(doc)
        #expect(issues.count == 1)
        #expect(issues.contains {
            if case .testPointClearance(pad.id, "T1", .channel, "nc", _, _, _) = $0.kind { return true }
            return false
        })
        // The fix handle is the pad's placement, not a (non-existent) test point.
        if let issue = issues.first {
            let sel = DRC.physicalSelection(for: issue, in: doc)
            #expect(sel?.placements.contains(pad.id) == true)
        }
    }

    @Test("A pad on its own net's channel does not flag")
    func padOwnNetIgnored() {
        let (doc, _, _) = makeRoutedPad(padAt: Point(x: 30, y: 15))
        #expect(tapIssues(doc).isEmpty)
    }

    @Test("A pad next to a testing point on the same plate flags the pair")
    func padVersusTestPoint() {
        var (doc, pad, _) = makeRoutedPad(padAt: Point(x: 30, y: 15))
        let other = Net(label: "tap", pins: [])
        doc.logic.nets.append(other)
        doc.physical.routes.append(Route(netId: other.id, segments: [
            Segment(waypoints: [Waypoint(position: Point(x: 31, y: 25)), Waypoint(position: Point(x: 31, y: 5))],
                    layer: .top),
        ]))
        // Bead 1 mm to the right of the pad: bore-to-bore wall = 1 − 1.7 < 0.
        doc.physical.testPoints.append(TestPoint(
            name: "TP1", netId: other.id, segmentIndex: 0, offset: 10,
            plate: .top, depth: 0, position: Point(x: 31, y: 15)))
        let issues = tapIssues(doc)
        #expect(issues.contains {
            if case .testPointClearance(_, _, .testPoint, _, _, _, _) = $0.kind { return true }
            return false
        })
        _ = pad
    }
}
