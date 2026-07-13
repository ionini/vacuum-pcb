import Testing
import Foundation
@testable import Vacuum_PCB

/// `FlowAnalysis` reconstructs Q = G·ΔP after the solve; these tests pin the
/// two properties that make the readout trustworthy: mass conservation
/// (Σ consumer draw = pump throughput at settle) and correct attribution
/// (the ranked rows point at the paths actually doing the drawing).
@MainActor
struct FlowAnalysisTests {

    /// VAC —R1— mid —R2— ATM, sealed (leak 0). One boundary consumer (R1),
    /// series continuity through both resistors, and the pump edge carries
    /// exactly what the consumer draws.
    @Test("Series divider: flow is conserved end to end")
    func seriesDividerConservation() throws {
        var doc = CircuitDocument.blank()
        let pump = Component(kind: .vacuumSource, label: "P1")
        let r1 = Component(kind: .resistor, label: "R1", resistorSize: .medium)
        let r2 = Component(kind: .resistor, label: "R2", resistorSize: .medium)
        let vent = Component(kind: .atmVent, label: "V1")
        doc.logic.components = [pump, r1, r2, vent]
        doc.logic.nets = [
            Net(label: "rail", pins: [PinRef(componentId: pump.id, pinKey: "p"),
                                      PinRef(componentId: r1.id, pinKey: "1")]),
            Net(label: "mid", pins: [PinRef(componentId: r1.id, pinKey: "2"),
                                     PinRef(componentId: r2.id, pinKey: "1")]),
            Net(label: "vent", pins: [PinRef(componentId: r2.id, pinKey: "2"),
                                      PinRef(componentId: vent.id, pinKey: "p")]),
        ]

        var params = SimulationParameters.defaults
        params.leakConductance = 0
        let network = Validators.buildNetwork(doc)
        let settled = Validators.simulateToSettle(network: network, params: params,
                                                  inputs: [:], maxSteps: 50000, epsilon: 1e-9)
        #expect(settled.converged)

        let report = FlowAnalysis.report(network: network, params: params,
                                         pressures: settled.pressures, inputs: [:])
        #expect(!report.subdivided)
        #expect(report.spanFlows.isEmpty)

        // Series continuity: the same air moves through both resistors,
        // toward the rail (negative in the node1→node2 sign convention,
        // since node1 is the rail/mid side).
        let q1 = try #require(report.flowByResistor[r1.id])
        let q2 = try #require(report.flowByResistor[r2.id])
        #expect(q1 < 0)
        #expect(abs(q1 - q2) < 1e-6)

        // Exactly one boundary consumer: R1, drawing |q1| into the rail.
        #expect(report.consumers.count == 1)
        let consumer = try #require(report.consumers.first)
        #expect(consumer.componentId == r1.id)
        #expect(consumer.kind == .resistor)
        #expect(abs(consumer.q - (-q1)) < 1e-9)

        // The pump removes what the consumer draws (residual = the C/dt
        // term at the settle epsilon).
        #expect(abs(report.pumpThroughput - consumer.q) < 1e-5)
        let railP = try #require(report.railPressure)
        #expect(railP > params.pumpMaxVacuum && railP < 1)
    }

    /// VAC —R1— isolated node, global leak on. The node's whole leak inflow
    /// arrives through the pull-up, and the rail's own leak shows up as the
    /// un-attributed "rail leak" row; together they equal the pump load.
    @Test("Leak floor: pull-up carries its node's leak, rail leak is its own row")
    func leakAttribution() throws {
        var doc = CircuitDocument.blank()
        let pump = Component(kind: .vacuumSource, label: "P1")
        let r1 = Component(kind: .resistor, label: "R1", resistorSize: .medium)
        doc.logic.components = [pump, r1]
        doc.logic.nets = [
            Net(label: "rail", pins: [PinRef(componentId: pump.id, pinKey: "p"),
                                      PinRef(componentId: r1.id, pinKey: "1")]),
            Net(label: "node", pins: [PinRef(componentId: r1.id, pinKey: "2")]),
        ]

        let params = SimulationParameters.defaults   // leak 0.025
        let network = Validators.buildNetwork(doc)
        let settled = Validators.simulateToSettle(network: network, params: params,
                                                  inputs: [:], maxSteps: 50000, epsilon: 1e-9)
        #expect(settled.converged)

        let report = FlowAnalysis.report(network: network, params: params,
                                         pressures: settled.pressures, inputs: [:])

        let nodeNet = try #require(doc.logic.nets.first { $0.label == "node" })
        let nodeP = try #require(settled.pressures[nodeNet.id])
        let pullUp = try #require(report.consumers.first { $0.componentId == r1.id })
        // At settle the node neither charges nor discharges: pull-up draw ==
        // the node's leak inflow.
        #expect(abs(pullUp.q - params.leakConductance * (1 - nodeP)) < 1e-6)

        let railLeak = try #require(report.consumers.first { $0.kind == .railLeak })
        #expect(railLeak.q > 0)
        let totalDraw = report.consumers.reduce(0) { $0 + $1.q }
        #expect(abs(report.pumpThroughput - totalDraw) < 1e-5)
    }

    /// The feature's headline scenario: VAC —R1— node —T1— vent, gate driven
    /// by an input. Gate at vacuum (valve open) turns the pull-up into
    /// continuous static draw; gate at atmosphere leaves only the leak floor.
    @Test("Static draw: open vent path multiplies the pull-up's flow")
    func staticDrawThroughOpenTransistor() throws {
        var doc = CircuitDocument.blank()
        let pump = Component(kind: .vacuumSource, label: "P1")
        let r1 = Component(kind: .resistor, label: "R1", resistorSize: .medium)
        let t1 = Component(kind: .transistor, label: "T1")
        let vent = Component(kind: .atmVent, label: "V1")
        let gate = Component(kind: .port, label: "G", portDirection: .input)
        doc.logic.components = [pump, r1, t1, vent, gate]
        doc.logic.nets = [
            Net(label: "rail", pins: [PinRef(componentId: pump.id, pinKey: "p"),
                                      PinRef(componentId: r1.id, pinKey: "1")]),
            Net(label: "node", pins: [PinRef(componentId: r1.id, pinKey: "2"),
                                      PinRef(componentId: t1.id, pinKey: "a")]),
            Net(label: "vent", pins: [PinRef(componentId: t1.id, pinKey: "b"),
                                      PinRef(componentId: vent.id, pinKey: "p")]),
            Net(label: "gate", pins: [PinRef(componentId: t1.id, pinKey: "gate"),
                                      PinRef(componentId: gate.id, pinKey: "p")]),
        ]

        var params = SimulationParameters.defaults
        params.leakConductance = 0.005
        let network = Validators.buildNetwork(doc)
        let input = try #require(network.inputs.first)

        func draw(gateValue: Double) -> (pullUpQ: Double, railP: Double) {
            let inputs = [input.id: gateValue]
            let settled = Validators.simulateToSettle(network: network, params: params,
                                                      inputs: inputs, maxSteps: 50000,
                                                      epsilon: 1e-9)
            #expect(settled.converged)
            let report = FlowAnalysis.report(network: network, params: params,
                                             pressures: settled.pressures, inputs: inputs)
            let pullUp = report.consumers.first { $0.componentId == r1.id }
            return (pullUp?.q ?? 0, report.railPressure ?? 1)
        }

        let closed = draw(gateValue: 1.0)   // gate at atm — valve shut
        let open = draw(gateValue: 0.0)     // gate at vac — valve conducting

        #expect(closed.pullUpQ > 0)                       // leak floor, not zero
        #expect(open.pullUpQ > closed.pullUpQ * 5)        // continuous static draw
        #expect(open.railP > closed.railP)                // and the rail sags for it
    }
}
