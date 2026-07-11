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
        // Test points are physical debug taps, not declared functional outputs,
        // so they don't gate the sweep / robustness comparison — a probe on a
        // marginal internal node shouldn't fail Validate. They still read live
        // in the Simulate sidebar (which reads the network directly).
        let observed = network.probes.filter { !$0.isTestPoint }
        let probeLabels = observed.map { $0.label.isEmpty ? "<unnamed>" : $0.label }
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
                bits: bits, probes: observed.map { r.pressures[$0.netId] ?? 1.0 },
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

    // MARK: - Volume collisions
    //
    // Independent geometric short-check: decompose the (flattened) board into
    // physical volumes — which already merge everything *meant* to connect
    // (routes, same-plate vias, resistor serpentines) — then test whether any
    // two *separate* volumes physically touch on the same plate. Because every
    // intended connection is already inside one volume, an overlap between two
    // volumes is an *un*intended one: two distinct nets fused in the print.
    //
    // It works on the real 3D channel geometry (true bore radii, per-depth Z),
    // so it sees inter-depth proximity and flattened subpart channels that the
    // 2D centreline-distance DRC can miss. Pads/footprint bodies aren't modelled
    // here — DRC's exclusion-zone checks cover those.

    struct CollisionResult {
        struct Hit: Identifiable {
            let id = UUID()
            let plate: Plate
            /// The two colliding volume ids (e.g. "T4", "T9").
            let a: String
            let b: String
            /// The two colliding nets' labels (the actual shorted nets).
            let netA: String
            let netB: String
            /// Approximate board-mm location of the overlap.
            let at: Point
            let layerA: Layer
            let layerB: Layer
            /// How deep the two bores overlap, mm (wall-to-wall penetration).
            let overlap: Double
        }
        let hits: [Hit]
        let volumeCount: Int
        var pass: Bool { hits.isEmpty }
    }

    static func volumeCollisions(_ doc: CircuitDocument) -> CollisionResult {
        let flat = doc.flattenedForSimulation().document
        let m = flat.manufacturing
        let vols = physicalVolumes(flat)
        let netLabel = Dictionary(flat.logic.nets.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })

        // One straight channel run (or a degenerate point = a pad/dimple
        // sphere), in 3D, tagged with its owning volume. `component` is set for
        // transistor body features so a transistor's own pad pair (its valve
        // gap) isn't mistaken for a short.
        struct Edge {
            let a: Vector, b: Vector
            let r: Double
            let plate: Plate
            let layer: Layer
            let vol: Int
            let component: UUID?
            /// Owning net for single-net geometry (channel / via / pad / dimple);
            /// nil for a resistor serpentine, which bridges two nets and so is
            /// never treated as "same net" with anything (always checked).
            let net: UUID?
            // AABB (inflated by r) for cheap broad-phase rejection.
            let lo: Vector, hi: Vector
        }
        func makeEdge(_ p: Point, _ q: Point, z: Double, r: Double, layer: Layer, vol: Int,
                      component: UUID? = nil, net: UUID? = nil) -> Edge {
            let a = Vector(p.x, p.y, z), b = Vector(q.x, q.y, z)
            return Edge(a: a, b: b, r: r, plate: layer.plate, layer: layer, vol: vol, component: component, net: net,
                        lo: Vector(min(a.x, b.x) - r, min(a.y, b.y) - r, min(a.z, b.z) - r),
                        hi: Vector(max(a.x, b.x) + r, max(a.y, b.y) + r, max(a.z, b.z) + r))
        }

        var edges: [Edge] = []
        for (vi, v) in vols.enumerated() {
            let channelR = m.channelDiameter / 2
            for seg in v.segments where seg.positions.count >= 2 {
                let z = m.midZ(for: seg.layer)
                for k in 0..<(seg.positions.count - 1) {
                    edges.append(makeEdge(seg.positions[k], seg.positions[k + 1], z: z, r: channelR, layer: seg.layer, vol: vi, net: seg.net))
                }
            }
            // Resistor serpentines are deliberately NOT collision edges: a
            // resistor bridges two nets (so it isn't single-net, and its two
            // ends legitimately touch both those nets' channels), and it lives
            // inside the transistor footprint where DRC already bars foreign
            // channels. Including it only produced false positives (its own VAC
            // end touching the VAC rail), never a short DRC doesn't already
            // catch. (Still painted in the highlight via PlateBuilder.volumeMesh.)
            for via in v.vias where via.layers.count >= 2 {
                let zs = via.layers.map { m.midZ(for: $0) }
                let lo = zs.min()!, hi = zs.max()!
                let a = Vector(via.pos.x, via.pos.y, lo), b = Vector(via.pos.x, via.pos.y, hi)
                let r = m.channelDiameter / 2
                edges.append(Edge(a: a, b: b, r: r, plate: via.layers[0].plate, layer: via.layers[0], vol: vi,
                                  component: nil, net: via.net,
                                  lo: Vector(a.x - r, a.y - r, lo - r), hi: Vector(a.x + r, a.y + r, hi + r)))
            }
            // Transistor / LED body cavities — pads & dimples, as spheres at the
            // silicone face (a degenerate point-edge), centred on the feature's
            // bore (`pinPos`). The full bore radius makes the sphere reach the
            // channel midline, so a pad/dimple overlapping a foreign channel
            // registers too. Pads sit on the plate opposite the gate.
            for ft in v.features {
                let plate = ft.kind == .pad ? ft.plate.opposite : ft.plate
                let z = plate == .top ? m.siliconeThickness / 2 : -m.siliconeThickness / 2
                edges.append(makeEdge(ft.pinPos, ft.pinPos, z: z, r: ft.radius,
                                      layer: Layer(plate: plate, depth: 0), vol: vi, component: ft.component, net: ft.net))
            }
        }

        // Cross-volume, same-plate segment pairs whose bores genuinely overlap.
        // Legal different-net channels are kept ≥ minChannelSpacing apart, so a
        // sub-(r1+r2) distance is an actual fusion; the small margin keeps a
        // touch of floating-point slack from a hair-tangent edge case.
        let margin = 0.05
        var seen = Set<Int>()   // packed volume-pair key
        var hits: [CollisionResult.Hit] = []
        for i in 0..<edges.count {
            let e = edges[i]
            for j in (i + 1)..<edges.count {
                let f = edges[j]
                if e.vol == f.vol || e.plate != f.plate { continue }
                // Same net overlapping itself is never a short — it's the net
                // connecting to itself (e.g. a rail whose channels cross mid-span
                // and so landed in separate volumes). A real short is two
                // *different* nets, which keep distinct ids and still flag.
                if let en = e.net, let fn = f.net, en == fn { continue }
                // A transistor's own pad pair (and pad↔gate) sit intentionally
                // close — skip features that share a component.
                if let ec = e.component, ec == f.component { continue }
                if e.hi.x < f.lo.x || f.hi.x < e.lo.x
                || e.hi.y < f.lo.y || f.hi.y < e.lo.y
                || e.hi.z < f.lo.z || f.hi.z < e.lo.z { continue }
                let d = segmentDistance(e.a, e.b, f.a, f.b)
                let limit = e.r + f.r - margin
                guard d < limit else { continue }
                let key = min(e.vol, f.vol) * vols.count + max(e.vol, f.vol)
                guard seen.insert(key).inserted else { continue }
                let mid = (e.a + f.a) * 0.5
                hits.append(CollisionResult.Hit(
                    plate: e.plate, a: vols[e.vol].id, b: vols[f.vol].id,
                    netA: e.net.flatMap { netLabel[$0] } ?? "?",
                    netB: f.net.flatMap { netLabel[$0] } ?? "(resistor)",
                    at: Point(x: mid.x, y: mid.y), layerA: e.layer, layerB: f.layer, overlap: limit - d))
            }
        }
        return CollisionResult(hits: hits, volumeCount: vols.count)
    }

    /// Shortest distance between two 3-D line segments (clamped closest points).
    private static func segmentDistance(_ p1: Vector, _ q1: Vector, _ p2: Vector, _ q2: Vector) -> Double {
        func clamp(_ x: Double) -> Double { x < 0 ? 0 : (x > 1 ? 1 : x) }
        let d1 = q1 - p1, d2 = q2 - p2, r = p1 - p2
        let a = d1.dot(d1), e = d2.dot(d2), f = d2.dot(r)
        let eps = 1e-9
        var s = 0.0, t = 0.0
        if a <= eps && e <= eps { return r.length }
        if a <= eps {
            t = clamp(f / e)
        } else {
            let c = d1.dot(r)
            if e <= eps {
                s = clamp(-c / a)
            } else {
                let b = d1.dot(d2)
                let denom = a * e - b * b
                s = denom > eps ? clamp((b * f - c * e) / denom) : 0
                t = (b * s + f) / e
                if t < 0 { t = 0; s = clamp(-c / a) }
                else if t > 1 { t = 1; s = clamp((b - c) / a) }
            }
        }
        return ((p1 + d1 * s) - (p2 + d2 * t)).length
    }

    // MARK: - UI-facing report

    /// A follow-up the Validate panel can offer for a failing gate (the CLI
    /// ignores these). Either reopen a failing margin corner in the Simulate
    /// tab, or jump to the 3D preview with the named volumes highlighted (used
    /// by the collision gate to show the two cavities that touch).
    struct ReportAction: Identifiable {
        enum Target {
            case openInSimulate(SimulationParameters)
            case showVolumes([String])
        }
        let id = UUID()
        let label: String
        let target: Target
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
