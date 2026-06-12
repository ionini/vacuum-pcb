import Foundation
import Euclid

/// Shared validation battery — the single source of truth behind both
/// `vacuum-cli` (mesh / sweep / margins / staleness / verify) and the in-app
/// Validate panel. Pure compute over a `CircuitDocument`; every function is a
/// plain static on a value type (like `PlateBuilder` / `DRC`), so callers may
/// run them off the main actor via GCD the same way the 3D preview rebuild
/// does. Formatting (terminal vs SwiftUI) lives in the callers.
enum Validators {

    // MARK: - Headless simulation core (shared with the CLI's simulate path)

    static func buildNetwork(_ doc: CircuitDocument) -> PneumaticNetwork {
        PneumaticNetwork.build(from: doc.flattenedForSimulation().document)
    }

    /// Seed initial net pressures: everything at atmosphere; hard boundaries
    /// and pumps prime to their rail; hard inputs toggled to Vac join the pump
    /// manifold. Mirrors `SimulationState.initialPressures`.
    static func seedPressures(
        network: PneumaticNetwork, params: SimulationParameters, inputs: [UUID: Double]
    ) -> [UUID: Double] {
        var out: [UUID: Double] = [:]
        for net in network.nets { out[net.id] = 1.0 }
        for boundary in network.hardBoundaries { out[boundary.netId] = boundary.value }
        for pump in network.pumps { out[pump.netId] = params.pumpMaxVacuum }
        for input in network.inputs where !input.soft {
            let v = inputs[input.id] ?? 1.0
            out[input.netId] = v < 0.5 ? params.pumpMaxVacuum : 1.0
        }
        return out
    }

    /// Solve from a blank state to convergence, or up to `maxSteps`. "Converged"
    /// means the largest per-net pressure change between steps fell below
    /// `epsilon`; a circuit that never settles is oscillating / metastable.
    static func simulateToSettle(
        network: PneumaticNetwork, params: SimulationParameters,
        inputs: [UUID: Double], maxSteps: Int, epsilon: Double
    ) -> (pressures: [UUID: Double], converged: Bool, steps: Int) {
        var pressures = seedPressures(network: network, params: params, inputs: inputs)
        var transistors: [UUID: Double] = [:]
        var steps = 0
        var converged = false
        for _ in 0..<max(1, maxSteps) {
            let prev = pressures
            SimulationEngine.step(
                network: network, params: params,
                pressures: &pressures, inputs: inputs, transistorOpenness: &transistors
            )
            steps += 1
            var maxDelta = 0.0
            for (netId, v) in pressures { maxDelta = max(maxDelta, abs(v - (prev[netId] ?? v))) }
            if maxDelta < epsilon { converged = true; break }
        }
        return (pressures, converged, steps)
    }

    // MARK: - Mesh (printability)

    struct MeshBody {
        let name: String
        let empty: Bool
        let required: Bool
        let watertight: Bool
        let signedVolume: Double
        let polygons: Int
        let size: (x: Double, y: Double, z: Double)
        /// An empty optional body (stencil disabled) passes; otherwise the body
        /// must stitch watertight with a positive (right-side-out) volume.
        var pass: Bool { empty ? !required : (watertight && signedVolume > 0) }
    }
    struct MeshResult { let bodies: [MeshBody]; var pass: Bool { bodies.allSatisfy(\.pass) } }

    /// Build the printed solids and judge each the way the STL export will see
    /// it (per-body `makeWatertight`). Plates are required; the stencil is
    /// optional (empty when `stencilThickness == 0`).
    static func mesh(_ doc: CircuitDocument) -> MeshResult {
        let out = PlateBuilder.build(doc)
        func body(_ name: String, _ m: Mesh, required: Bool) -> MeshBody {
            if m.isEmpty {
                return MeshBody(name: name, empty: true, required: required,
                                watertight: false, signedVolume: 0, polygons: 0, size: (0, 0, 0))
            }
            let s = m.makeWatertight()
            let b = s.bounds
            return MeshBody(
                name: name, empty: false, required: required,
                watertight: s.isWatertight, signedVolume: s.signedVolume,
                polygons: s.polygons.count,
                size: (b.max.x - b.min.x, b.max.y - b.min.y, b.max.z - b.min.z)
            )
        }
        return MeshResult(bodies: [
            body("topPlate", out.topPlate, required: true),
            body("bottomPlate", out.bottomPlate, required: true),
            body("stencil", out.stencil, required: false),
        ])
    }

    // MARK: - Exhaustive logic sweep + convergence

    struct SweepRow { let bits: [Int]; let probes: [Double]; let converged: Bool; let steps: Int }
    struct SweepResult {
        let inputLabels: [String]
        let probeLabels: [String]
        /// Inputs pinned (not enumerated), formatted "LABEL=vac/atm".
        let heldLabels: [String]
        let rows: [SweepRow]
        /// Non-nil when 2^(#swept inputs) exceeded the cap — the sweep was skipped.
        let tooManyCombos: Int?
        var allConverged: Bool { tooManyCombos == nil && rows.allSatisfy(\.converged) }
    }

    /// Drive every 0/1 combination of the network's inputs (vac=0 / atm=1),
    /// solve each to convergence, and record probe levels. Exhaustive: 2^n.
    /// Inputs whose label appears in `holds` are *pinned* to that value instead
    /// of enumerated — e.g. a VAC power rail held at vacuum, so the sweep
    /// doesn't waste a bit toggling the supply off (a non-operational state
    /// that can legitimately fail to settle and isn't a real defect).
    static func sweep(
        network: PneumaticNetwork, params: SimulationParameters,
        maxSteps: Int, epsilon: Double, maxCombos: Int, holds: [String: Double] = [:]
    ) -> SweepResult {
        let swept = network.inputs.filter { holds[$0.label] == nil }
        let held = network.inputs.filter { holds[$0.label] != nil }
        let n = swept.count
        let total = 1 << n
        let inLabels = swept.map { $0.label.isEmpty ? "<unnamed>" : $0.label }
        let heldLabels = held.map { "\($0.label)=\(holds[$0.label]! < 0.5 ? "vac" : "atm")" }
        let probeLabels = network.probes.map { $0.label.isEmpty ? "<unnamed>" : $0.label }
        if total > maxCombos {
            return SweepResult(inputLabels: inLabels, probeLabels: probeLabels,
                               heldLabels: heldLabels, rows: [], tooManyCombos: total)
        }
        var heldMap: [UUID: Double] = [:]
        for inp in held { heldMap[inp.id] = holds[inp.label]! }
        var rows: [SweepRow] = []
        rows.reserveCapacity(total)
        for combo in 0..<total {
            var inputMap = heldMap
            var bits: [Int] = []
            for (k, inp) in swept.enumerated() {
                let bit = (combo >> k) & 1
                bits.append(bit)
                inputMap[inp.id] = bit == 1 ? 1.0 : 0.0
            }
            let r = simulateToSettle(network: network, params: params, inputs: inputMap, maxSteps: maxSteps, epsilon: epsilon)
            rows.append(SweepRow(
                bits: bits, probes: network.probes.map { r.pressures[$0.netId] ?? 1.0 },
                converged: r.converged, steps: r.steps
            ))
        }
        return SweepResult(inputLabels: inLabels, probeLabels: probeLabels,
                           heldLabels: heldLabels, rows: rows, tooManyCombos: nil)
    }

    // MARK: - Margin sweep (robustness across parameter variation)

    /// One failing parameter corner, carrying the exact `SimulationParameters`
    /// that produced it so a caller can reopen that operating point (e.g. the
    /// Validate panel's "Open in Simulate" button).
    struct MarginFailure {
        let label: String
        let detail: String
        let params: SimulationParameters
    }
    struct MarginResult {
        let tol: Double
        let corners: Int
        let inputCombos: Int
        let keys: [String]
        let failures: [MarginFailure]
        var pass: Bool { failures.isEmpty }
    }

    /// Re-run the exhaustive sweep across ±tol parameter corners and assert no
    /// probe's logic level (<0.5 vac / ≥0.5 atm) flips versus nominal and every
    /// corner still converges. `progress` fires once per corner.
    static func margins(
        network: PneumaticNetwork, base: SimulationParameters,
        tol: Double, maxSteps: Int, epsilon: Double, maxCombos: Int,
        holds: [String: Double] = [:],
        progress: ((_ corner: Int, _ total: Int, _ desc: String, _ converged: Bool, _ flips: Int) -> Void)? = nil
    ) -> MarginResult {
        func level(_ p: Double) -> Int { p < 0.5 ? 0 : 1 }
        let allKeys: [(name: String, set: (inout SimulationParameters, Double) -> Void, base: Double)] = [
            ("resistance", { $0.resistorResistancePerMm = $1 }, base.resistorResistancePerMm),
            ("flow", { $0.pumpFlowCapacity = $1 }, base.pumpFlowCapacity),
            ("gateThreshold", { $0.gateThreshold = $1 }, base.gateThreshold),
            ("leak", { $0.leakConductance = $1 }, base.leakConductance),
            ("internalLeak", { $0.internalLeakConductance = $1 }, base.internalLeakConductance),
        ]
        // ±tol of a zero base is still zero, so a key at 0 (internalLeak by
        // default) would only duplicate every existing corner — drop it.
        let keys = allKeys.filter { $0.base != 0 }
        let cornerCount = 1 << keys.count
        let nominal = sweep(network: network, params: base, maxSteps: maxSteps, epsilon: epsilon, maxCombos: maxCombos, holds: holds)
        if let tooMany = nominal.tooManyCombos {
            return MarginResult(tol: tol, corners: cornerCount, inputCombos: 0, keys: keys.map(\.name),
                                failures: [MarginFailure(label: "nominal", detail: "\(tooMany) input combinations exceed the cap — raise it to brute-force", params: base)])
        }
        var failures: [MarginFailure] = []
        if !nominal.allConverged { failures.append(MarginFailure(label: "nominal", detail: "some input combinations never settle", params: base)) }
        for corner in 0..<cornerCount {
            var p = base
            var desc: [String] = []
            for (j, key) in keys.enumerated() {
                let hi = (corner >> j) & 1 == 1
                key.set(&p, key.base * (hi ? 1 + tol : 1 - tol))
                desc.append("\(key.name)\(hi ? "↑" : "↓")")
            }
            let sw = sweep(network: network, params: p, maxSteps: maxSteps, epsilon: epsilon, maxCombos: maxCombos, holds: holds)
            var flips = 0
            for (ri, row) in sw.rows.enumerated() where ri < nominal.rows.count {
                for (pi, pv) in row.probes.enumerated() where level(pv) != level(nominal.rows[ri].probes[pi]) {
                    flips += 1
                }
            }
            progress?(corner + 1, cornerCount, desc.joined(separator: " "), sw.allConverged, flips)
            let label = desc.joined(separator: " ")
            if !sw.allConverged { failures.append(MarginFailure(label: label, detail: "did not converge", params: p)) }
            if flips > 0 { failures.append(MarginFailure(label: label, detail: "\(flips) probe bit-flip(s) vs nominal", params: p)) }
        }
        return MarginResult(tol: tol, corners: cornerCount, inputCombos: nominal.rows.count, keys: keys.map(\.name), failures: failures)
    }

    // MARK: - Subpart snapshot staleness / self-containment

    struct StalenessResult {
        let hardProblems: [String]
        let stale: [String]
        let info: [String]
        var pass: Bool { hardProblems.isEmpty && stale.isEmpty }
    }

    /// Verify the design is self-contained (every subpart pinned to an embedded
    /// snapshot) and, with `libDir`, current (snapshots match the on-disk
    /// library). Internal hash drift across schema migrations is info, not a gate.
    static func staleness(_ doc: CircuitDocument, libDir: String?) -> StalenessResult {
        var hard: [String] = []
        var info: [String] = []
        func walk(_ d: CircuitDocument, _ path: String) {
            for c in d.logic.components where c.kind == .subpart {
                let name = "\(path)\(c.label) (\(c.partRef ?? "?"))"
                guard let h = c.partRefHash else {
                    hard.append("\(name): no snapshot pin — resolves against the live parts folder, not a frozen copy")
                    continue
                }
                if d.librarySnapshots[h] == nil {
                    hard.append("\(name): pinned to \(h.prefix(10))… but no matching embedded snapshot — falls back to live library")
                }
            }
            for (key, snap) in d.librarySnapshots {
                if snap.contentHash() != key {
                    info.append("snapshot \(key.prefix(10))… under \(path.isEmpty ? "<root>" : path) no longer hashes to its key (benign across schema migrations)")
                }
                walk(snap, "\(path)\(key.prefix(8))/")
            }
        }
        walk(doc, "")

        var stale: [String] = []
        if let libDir {
            for c in doc.logic.components where c.kind == .subpart {
                guard let fn = c.partRef else { continue }
                let url = URL(fileURLWithPath: libDir).appendingPathComponent(fn)
                guard let data = try? Data(contentsOf: url),
                      let live = try? CircuitDocument.decoded(from: data) else {
                    hard.append("subpart '\(c.label)': library file '\(fn)' not found under \(libDir)")
                    continue
                }
                guard let h = c.partRefHash, let pinned = doc.librarySnapshots[h] else { continue }
                if live.effectiveHash() != pinned.effectiveHash() {
                    stale.append("subpart '\(c.label)' (\(fn)): on-disk library differs from the embedded snapshot — stale (Update from Library)")
                }
            }
        }
        return StalenessResult(hardProblems: hard, stale: stale, info: info)
    }

    // MARK: - Connectivity (top-level DRC + ratsnest)

    struct ConnResult {
        let drcIssues: [DRC.Issue]
        let unrouted: Int
        var pass: Bool { drcIssues.isEmpty && unrouted == 0 }
    }
    static func connectivity(_ doc: CircuitDocument) -> ConnResult {
        ConnResult(drcIssues: DRC.check(doc), unrouted: Ratsnest.missingEdges(doc).count)
    }

    // MARK: - UI-facing report

    /// An actionable parameter set attached to a report (e.g. reopen a failing
    /// margin corner in the Simulate tab). Surface-agnostic; the CLI ignores it.
    struct ReportAction: Identifiable {
        let id = UUID()
        let label: String
        let params: SimulationParameters
    }

    /// A single gate's outcome, surface-agnostic. The Validate panel renders a
    /// list of these; the CLI prints its own format.
    struct Report: Identifiable {
        enum Status { case pass, fail, warn, pending, running }
        let id: String
        var title: String
        var status: Status
        var detail: [String]
        var actions: [ReportAction] = []
    }
}
