//
//  SimTestRunner.swift
//  Vacuum PCB
//
//  Replays a parsed [TestCase] (see TestDSL.swift) against the *live*
//  `SimulationState` instead of physical hardware. The bench-side runner drove
//  outputs over BLE and read thresholded telemetry channels; here `set` writes
//  `SimulationState.inputPressures` and `assert` / `waitfor` read a probe's
//  pressure, thresholded at 0.5 under the user-selected polarity.
//
//  Timing is in *simulated* seconds (`SimulationState.elapsedSimSeconds`): each
//  await yields the main actor so the 60 Hz `SimulationClock` advances the
//  integrator between checks, and `wait` / `waitfor` therefore honour the
//  time-scale slider. Everything is main-actor isolated (it touches the state
//  and publishes to SwiftUI); the run is one cancellable Task with a generation
//  token so a superseded run can't clobber state after a restart.
//

import Foundation
import Observation

/// Session model backing the Simulate tab's test drawer: the editable script
/// source, the logical-pin → named-port overrides, the polarity convention, and
/// the live runner. Owned by `DocumentView` (like `validationModel`) so it
/// survives Simulate-tab switches; not persisted into the `.vpcb`.
@MainActor
@Observable
final class SimTestModel {
    /// The DSL script the user pastes / edits.
    var source: String = SimTestModel.exampleScript

    /// Whether the bottom test drawer is shown.
    var showPanel: Bool = false

    /// User overrides of the positional auto-map (`out<N>` → input id,
    /// `ch<N>` → probe id). Absent entries fall back to the Nth input / probe.
    var outOverrides: [Int: UUID] = [:]
    var chOverrides: [Int: UUID] = [:]

    /// The live runner (results + running state).
    let runner = SimTestRunner()

    /// Resolve `out<N>` to a board input: an explicit override if it still
    /// exists, otherwise the Nth input in network order.
    func input(forOutput n: Int, network: PneumaticNetwork) -> PneumaticNetwork.Input? {
        if let id = outOverrides[n], let match = network.inputs.first(where: { $0.id == id }) {
            return match
        }
        return network.inputs.indices.contains(n) ? network.inputs[n] : nil
    }

    /// Resolve `ch<N>` to a board probe: an explicit override if it still
    /// exists, otherwise the Nth probe in network order.
    func probe(forChannel n: Int, network: PneumaticNetwork) -> PneumaticNetwork.Probe? {
        if let id = chOverrides[n], let match = network.probes.first(where: { $0.id == id }) {
            return match
        }
        return network.probes.indices.contains(n) ? network.probes[n] : nil
    }

    static let exampleScript = """
    # Inverter test — drives input 0 (out0) and reads probe 0 (ch0).
    # Convention: 1 = vacuum, 0 = atmosphere. An inverter flips the level:
    #   input vacuum (1)     -> output atmosphere (0)
    #   input atmosphere (0) -> output vacuum (1)
    #
    # NOTE: waits are in SIMULATED time. A stage settles over a few *seconds*
    # (not the milliseconds a real bench uses), so a pasted bench script's
    # `300ms` would assert mid-transition — use whole-second waits. Raise the
    # toolbar time-scale slider to run these waits faster in wall-clock.

    test high input gives low output
      set out0 1        # input -> vacuum
      wait 2s
      assert ch0 0      # output pulled to atmosphere

    test low input gives high output
      set out0 0        # input -> atmosphere
      wait 6s
      assert ch0 1      # output pulled to vacuum

    # `waitfor` blocks until a probe reaches a level (or times out) — handy
    # when you'd rather not hard-code a settle time.
    test output flips to vacuum
      set out0 0
      waitfor ch0 1 timeout 15s
    """
}

@MainActor
@Observable
final class SimTestRunner {
    enum Status: Equatable { case pending, running, passed, failed, skipped }

    struct StepResult: Identifiable {
        let id = UUID()
        let label: String
        var status: Status = .pending
        var detail: String?
    }

    struct TestResult: Identifiable {
        let id = UUID()
        let name: String
        var steps: [StepResult]
        var status: Status = .pending
    }

    private(set) var results: [TestResult] = []
    private(set) var isRunning = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    var passedCount: Int { results.filter { $0.status == .passed }.count }
    var failedCount: Int { results.filter { $0.status == .failed }.count }

    // MARK: - Control

    func run(_ tests: [TestCase], state: SimulationState, model: SimTestModel) {
        generation += 1
        let gen = generation
        task?.cancel()

        results = tests.map { t in
            TestResult(name: t.name, steps: t.steps.map { StepResult(label: $0.label) })
        }
        isRunning = true

        task = Task { [weak self] in
            await self?.execute(tests, gen: gen, state: state, model: model)
        }
    }

    func stop() { task?.cancel() }

    // MARK: - Execution

    private enum Outcome {
        case pass
        case fail(String)
        case cancelled
    }

    private func execute(_ tests: [TestCase], gen: Int, state: SimulationState, model: SimTestModel) async {
        // Snapshot the user's manual transport + input toggles so the run leaves
        // them exactly as it found them (mirrors the bench leaving outputs safe).
        let priorInputs = state.inputPressures
        let priorPlaying = state.isPlaying
        defer {
            // Only the current run owns shared state; a superseded run leaves it alone.
            if gen == generation {
                state.inputPressures = priorInputs
                state.isPlaying = priorPlaying
                isRunning = false
            }
        }

        // The integrator only advances while playing; force it on for the run
        // so the sim-time waits below actually progress.
        state.isPlaying = true

        for ti in tests.indices {
            if Task.isCancelled { return }
            results[ti].status = .running

            // Known start: snap pressures to atmosphere and clear every input the
            // test drives to logic 0, so tests don't bleed into one another.
            state.reset()
            for out in referencedOutputs(in: tests[ti]) {
                if let input = model.input(forOutput: out, network: state.network) {
                    state.inputPressures[input.id] = drivePressure(false)
                }
            }

            var failed = false
            for si in tests[ti].steps.indices {
                if Task.isCancelled {
                    results[ti].steps[si].status = .skipped
                    return
                }
                if failed {
                    results[ti].steps[si].status = .skipped
                    continue
                }
                results[ti].steps[si].status = .running
                switch await run(tests[ti].steps[si], state: state, model: model) {
                case .pass:
                    results[ti].steps[si].status = .passed
                case let .fail(msg):
                    results[ti].steps[si].status = .failed
                    results[ti].steps[si].detail = msg
                    failed = true
                case .cancelled:
                    results[ti].steps[si].status = .skipped
                    return
                }
            }
            results[ti].status = failed ? .failed : .passed
        }
    }

    private func run(_ step: TestStep, state: SimulationState, model: SimTestModel) async -> Outcome {
        switch step {
        case let .set(output, on):
            guard let input = model.input(forOutput: output, network: state.network) else {
                return .fail("out\(output) isn't mapped to an input port")
            }
            state.inputPressures[input.id] = drivePressure(on)
            return .pass

        case let .wait(seconds):
            return await advanceSim(seconds, state: state)

        case let .assert(channel, expected):
            guard let actual = currentLevel(channel, state: state, model: model) else {
                return .fail("ch\(channel) isn't mapped to a probe")
            }
            return actual == expected
                ? .pass
                : .fail("expected \(expected ? 1 : 0), got \(actual ? 1 : 0)")

        case let .waitFor(channel, expected, timeout):
            guard model.probe(forChannel: channel, network: state.network) != nil else {
                return .fail("ch\(channel) isn't mapped to a probe")
            }
            let deadline = state.elapsedSimSeconds + timeout
            while state.elapsedSimSeconds < deadline {
                if Task.isCancelled { return .cancelled }
                if currentLevel(channel, state: state, model: model) == expected { return .pass }
                do { try await Task.sleep(for: .milliseconds(30)) } catch { return .cancelled }
            }
            let got = currentLevel(channel, state: state, model: model).map { $0 ? "1" : "0" } ?? "no map"
            return .fail("timeout; ch\(channel) still \(got)")
        }
    }

    // MARK: - Sim-time + polarity helpers

    /// Suspend until the integrator has advanced `seconds` of *sim* time. Each
    /// `Task.sleep` yields the main actor so the 60 Hz clock can tick the
    /// integrator between checks; this honours the time-scale slider for free.
    private func advanceSim(_ seconds: Double, state: SimulationState) async -> Outcome {
        let target = state.elapsedSimSeconds + seconds
        while state.elapsedSimSeconds < target {
            if Task.isCancelled { return .cancelled }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return .cancelled }
        }
        return .pass
    }

    /// The sim pressure representing a logic level: `1` / high = vacuum (0.0),
    /// `0` / low = atmosphere (1.0).
    private func drivePressure(_ on: Bool) -> Double { on ? 0.0 : 1.0 }

    /// Current logic level read at a mapped probe: vacuum (pressure < 0.5)
    /// reads as `1`. `nil` when the channel isn't mapped to any probe.
    private func currentLevel(_ ch: Int, state: SimulationState, model: SimTestModel) -> Bool? {
        guard let probe = model.probe(forChannel: ch, network: state.network) else { return nil }
        return state.pressure(probe: probe) < 0.5
    }

    private func referencedOutputs(in test: TestCase) -> [Int] {
        var seen = Set<Int>()
        for s in test.steps { if case let .set(o, _) = s { seen.insert(o) } }
        return Array(seen)
    }
}
