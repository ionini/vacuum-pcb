import Testing
import Foundation
@testable import Vacuum_PCB

/// The Validate battery runs on a GCD worker that used to compute to
/// completion even after the run was superseded (re-run) or invalidated
/// (design edit) — the token only silenced its result posts, so an abandoned
/// margins sweep kept a core pinned for minutes while the user edited.
/// `isCancelled` threads a cooperative cancellation poll through
/// sweep → simulateToSettle and margins → sweep; these tests pin the
/// contract: cancelled results say so, carry only partial rows, and are
/// never judged as pass/converged.
@MainActor
struct ValidatorsCancellationTests {

    /// Two driveable input ports → 2 swept bits → 4 sweep combinations.
    private func twoInputDoc() -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 50, height: 30))
        for label in ["A", "B"] {
            let port = Component(kind: .port, label: label, portDirection: .input)
            doc.logic.components.append(port)
            doc.logic.nets.append(Net(label: "n\(label)", pins: [PinRef(componentId: port.id, pinKey: "p")]))
        }
        return doc
    }

    @Test("A nil / never-firing isCancelled leaves the sweep untouched")
    func sweepUncancelledRunsAllCombos() {
        let net = Validators.buildNetwork(twoInputDoc())
        let sw = Validators.sweep(network: net, params: .defaults,
                                  maxSteps: 2000, epsilon: 1e-5, maxCombos: 64,
                                  isCancelled: { false })
        #expect(!sw.cancelled)
        #expect(sw.rows.count == 4)
    }

    @Test("Cancelling before the first combination yields an empty, unjudgeable sweep")
    func sweepCancelledUpFront() {
        let net = Validators.buildNetwork(twoInputDoc())
        let sw = Validators.sweep(network: net, params: .defaults,
                                  maxSteps: 2000, epsilon: 1e-5, maxCombos: 64,
                                  isCancelled: { true })
        #expect(sw.cancelled)
        #expect(sw.rows.isEmpty)
        // A cancelled sweep must never read as "all converged" (rows.allSatisfy
        // on an empty array would otherwise say true).
        #expect(!sw.allConverged)
    }

    @Test("Cancelling mid-sweep stops before all combinations run")
    func sweepCancelledMidway() {
        let net = Validators.buildNetwork(twoInputDoc())
        // The poll fires at the top of every combination and periodically
        // inside each settle, so flipping true from the third poll onward
        // cancels no later than combination 1 of 4.
        var polls = 0
        let sw = Validators.sweep(network: net, params: .defaults,
                                  maxSteps: 2000, epsilon: 1e-5, maxCombos: 64,
                                  isCancelled: { polls += 1; return polls > 3 })
        #expect(sw.cancelled)
        #expect(sw.rows.count < 4)
        #expect(!sw.allConverged)
    }

    @Test("A cancelled margins run reports cancelled, not pass")
    func marginsCancelled() {
        let net = Validators.buildNetwork(twoInputDoc())
        let m = Validators.margins(network: net, base: .defaults,
                                   tol: 0.2, maxSteps: 2000, epsilon: 1e-5, maxCombos: 64,
                                   isCancelled: { true })
        #expect(m.cancelled)
        #expect(!m.pass)
        #expect(m.failures.isEmpty)
    }

    @Test("Margins cancelled between corners keeps the corners already judged")
    func marginsCancelledMidCorners() {
        let net = Validators.buildNetwork(twoInputDoc())
        var sawCorner = 0
        // Let the nominal sweep and the first corner finish, then cancel.
        let m = Validators.margins(network: net, base: .defaults,
                                   tol: 0.2, maxSteps: 2000, epsilon: 1e-5, maxCombos: 64,
                                   isCancelled: { sawCorner >= 1 },
                                   progress: { c, _, _, _, _ in sawCorner = c })
        #expect(m.cancelled)
        #expect(!m.pass)
        #expect(m.inputCombos == 4)   // nominal completed before the cancel
    }

    @Test("An uncancelled margins run is unchanged by the hook")
    func marginsUncancelled() {
        let net = Validators.buildNetwork(twoInputDoc())
        let m = Validators.margins(network: net, base: .defaults,
                                   tol: 0.2, maxSteps: 2000, epsilon: 1e-5, maxCombos: 64,
                                   isCancelled: { false })
        #expect(!m.cancelled)
        #expect(m.inputCombos == 4)
    }
}
