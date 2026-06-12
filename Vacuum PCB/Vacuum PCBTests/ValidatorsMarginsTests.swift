import Testing
import Foundation
@testable import Vacuum_PCB

/// The margin sweep varies every simulation parameter that can plausibly
/// drift — including `internalLeakConductance` once a design uses it. A key
/// whose base value is 0 is dropped (±tol of 0 is still 0, so its corners
/// would only duplicate the others).
@MainActor
struct ValidatorsMarginsTests {

    @Test("internalLeak joins the margin corners only when non-zero")
    func internalLeakKeyGatedOnBase() {
        let network = Validators.buildNetwork(CircuitDocument.blank())
        var params = SimulationParameters.defaults

        let nominal = Validators.margins(network: network, base: params,
                                         tol: 0.2, maxSteps: 50, epsilon: 1e-4, maxCombos: 16)
        #expect(!nominal.keys.contains("internalLeak"))
        #expect(nominal.corners == 16)

        params.internalLeakConductance = 0.05
        let withLeak = Validators.margins(network: network, base: params,
                                          tol: 0.2, maxSteps: 50, epsilon: 1e-4, maxCombos: 16)
        #expect(withLeak.keys.contains("internalLeak"))
        #expect(withLeak.corners == 32)
    }
}
