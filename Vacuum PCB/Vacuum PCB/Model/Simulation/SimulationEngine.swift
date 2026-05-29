import Foundation

/// Backward-Euler integrator on top of a `PneumaticNetwork`.
///
/// Each tick we build a sparse-but-dense (small N) admittance matrix Y of
/// conductances between free nets, fold the C/dt term into the diagonal, and
/// solve `(Y + C/dt) P_new = (C/dt) P_old + Σ G·P_pinned` for the free nets.
///
/// Transistor conductance depends on the gate net's pressure, which itself
/// changes during the solve. We iterate the conductance evaluation against
/// the previous step's pressures (Gauss-Seidel style); two or three passes
/// converge for the gate switching dynamics we care about. The smoothed
/// sigmoidal ramp around the gate threshold keeps the integrator stable so
/// long state doesn't ping-pong.
enum SimulationEngine {

    /// One time step. `pressures` is mutated in place. `inputs` is a snapshot
    /// of user-set input port pressures keyed by component id.
    static func step(
        network: PneumaticNetwork,
        params: SimulationParameters,
        pressures: inout [UUID: Double],
        inputs: [UUID: Double],
        transistorOpenness: inout [UUID: Double]
    ) {
        // Anchor table: net id → fixed pressure value. ATM vents and any
        // input toggled to atmosphere pin their nets at 1.0. Inputs toggled
        // to vacuum are *not* anchored — they join the shared pump manifold
        // below, so they share the pump's finite Q-vs-P budget rather than
        // acting as perfect infinite sources.
        var anchored: [UUID: Double] = [:]
        for boundary in network.hardBoundaries {
            anchored[boundary.netId] = boundary.value
        }
        // Only *hard* inputs clamp their net. Soft (bus) inputs are stamped
        // as finite-conductance edges further below so they never pin a net.
        for input in network.inputs where !input.soft {
            if (inputs[input.id] ?? 1.0) >= 0.5 {
                anchored[input.netId] = 1.0
            }
        }

        // Manifold-tapped nets: every `vacuumSource` plus every input the
        // user has toggled to Vac. In real hardware these all hang off one
        // physical vacuum line, so they share a single Q-vs-P curve. We
        // tie them together with a stiff conductance below and stamp a
        // single pump edge on a canonical member.
        var manifoldNets = Set<UUID>()
        for pump in network.pumps { manifoldNets.insert(pump.netId) }
        for input in network.inputs where !input.soft && (inputs[input.id] ?? 1.0) < 0.5 {
            manifoldNets.insert(input.netId)
        }

        // Build free-net index. Pinned nets get pinned directly in
        // `pressures`; only free nets become unknowns.
        var freeIndex: [UUID: Int] = [:]
        var freeIds: [UUID] = []
        for net in network.nets {
            if anchored[net.id] == nil {
                freeIndex[net.id] = freeIds.count
                freeIds.append(net.id)
            }
        }
        // Force anchored nets to their boundary value so the rest of the
        // solver and the UI both read consistent state.
        for (netId, value) in anchored {
            pressures[netId] = value
        }
        guard !freeIds.isEmpty else { return }

        let dt = max(params.dtSeconds, 1e-6)

        let n = freeIds.count
        // One contiguous buffer for the row-major NxN matrix and a parallel
        // RHS / solution vector. Nested-array variants were burning
        // measurable time on per-step allocations at 60 Hz; a single
        // `[Double]` reuses across the two iterations and stresses the
        // allocator only when the network shape actually changes.
        var y = [Double](repeating: 0, count: n * n)
        var rhs = [Double](repeating: 0, count: n)
        var solution = [Double](repeating: 0, count: n)

        // One pass is enough when gate states change slowly. Two gives us a
        // little extra robustness when an input flip causes a cascade.
        for _ in 0..<2 {
            for i in 0..<(n * n) { y[i] = 0 }
            for i in 0..<n { rhs[i] = 0 }

            // 1. Capacitance + previous-state RHS.
            for (idx, netId) in freeIds.enumerated() {
                let c = network.capacitanceByNet[netId] ?? params.nodeBaseCapacitance
                let cOverDt = c / dt
                y[idx * n + idx] += cOverDt
                rhs[idx] += cOverDt * (pressures[netId] ?? 1.0)
            }

            // 2. Resistor edges. Conductance = 1 / (length * R_per_mm).
            for r in network.resistors {
                let length = max(0.1, r.pathLengthMm)
                let g = 1.0 / (length * params.resistorResistancePerMm)
                stamp(&y, &rhs, n: n, freeIndex: freeIndex, anchored: anchored,
                      net1: r.net1, net2: r.net2, g: g)
            }

            // 3. Shared pump. Every manifold-tapped net (VAC component or
            // vacuum-toggled input) sits on the same physical vacuum line,
            // so they share one Q-vs-P budget. Tie the non-canonical taps
            // to a canonical one with a stiff edge — they collapse to one
            // node in the matrix — then stamp a single pump edge from the
            // canonical net to the virtual `pumpMaxVacuum` anchor.
            let manifoldFreeOrdered: [UUID] = network.nets.compactMap {
                manifoldNets.contains($0.id) && freeIndex[$0.id] != nil ? $0.id : nil
            }
            if let canonical = manifoldFreeOrdered.first {
                // Stiff enough to dominate every other edge in the matrix
                // (resistor G ~ 1, transistor on G = 5) without being so
                // large that pivoting struggles.
                let stiffG = max(params.transistorOnConductance * 200, 1000)
                for netId in manifoldFreeOrdered where netId != canonical {
                    stamp(&y, &rhs, n: n, freeIndex: freeIndex, anchored: anchored,
                          net1: canonical, net2: netId, g: stiffG)
                }
                let manifoldP = pressures[canonical] ?? 1.0
                let g = params.pumpConductance(forNetPressure: manifoldP)
                if g > 0, let idx = freeIndex[canonical] {
                    y[idx * n + idx] += g
                    rhs[idx] += g * params.pumpMaxVacuum
                }
            }

            // 4. Transistor edges. Conductance depends on gate net pressure
            // (whatever was last solved / anchored).
            for t in network.transistors {
                let gatePressure = anchored[t.gateNet] ?? pressures[t.gateNet] ?? 1.0
                let g = params.conductance(forGatePressure: gatePressure)
                transistorOpenness[t.id] = openness(forGatePressure: gatePressure, params: params)
                stamp(&y, &rhs, n: n, freeIndex: freeIndex, anchored: anchored,
                      net1: t.aNet, net2: t.bNet, g: g)
            }

            // 4b. Soft (bus) input drives. A bidirectional connector pin the
            // user has asserted pulls its net toward a rail through a finite
            // conductance — strong enough to move an idle bus, weak enough
            // that an on-board driver can contend. A floating selection
            // (absent or NaN) drives nothing. The drive target is a virtual
            // anchor (atmosphere = 1.0, or the pump's deadhead for Vac), so
            // we fold it straight into the diagonal + RHS like a free↔anchored
            // edge. If the net is already pinned (some hard boundary owns it)
            // it isn't in `freeIndex` and the soft drive is correctly ignored.
            for input in network.inputs where input.soft {
                guard let raw = inputs[input.id], !raw.isNaN else { continue }
                guard let idx = freeIndex[input.netId] else { continue }
                let target = raw < 0.5 ? params.pumpMaxVacuum : 1.0
                let g = params.busDriveConductance
                y[idx * n + idx] += g
                rhs[idx] += g * target
            }

            // 5. Solve. Dense Gaussian elimination — N is small (number of
            // free nets, typically <30 for hobby designs).
            solve(matrix: &y, rhs: &rhs, n: n, into: &solution)
            for (idx, netId) in freeIds.enumerated() {
                pressures[netId] = solution[idx]
            }
        }
    }

    /// Returns a 0…1 "open fraction" suitable for UI rendering. 0 = closed
    /// (gate at atm), 1 = fully open (gate at vacuum).
    private static func openness(forGatePressure p: Double, params: SimulationParameters) -> Double {
        let g = params.conductance(forGatePressure: p)
        let span = params.transistorOnConductance - params.transistorOffConductance
        guard span > 0 else { return 0 }
        return max(0, min(1, (g - params.transistorOffConductance) / span))
    }

    /// Stamps a single conductive edge into the matrix. Two-port version of
    /// the MNA stamp — for a free↔free edge it contributes to both diagonals
    /// and both off-diagonals; for a free↔anchored edge it folds the anchor
    /// value into the RHS instead of growing the matrix.
    ///
    /// The matrix is a row-major flat `[Double]` of length n*n; index it as
    /// `y[row * n + col]`.
    private static func stamp(
        _ y: inout [Double],
        _ rhs: inout [Double],
        n: Int,
        freeIndex: [UUID: Int],
        anchored: [UUID: Double],
        net1: UUID, net2: UUID, g: Double
    ) {
        if net1 == net2 { return }  // self-loop = no-op
        let i = freeIndex[net1]
        let j = freeIndex[net2]
        switch (i, j) {
        case let (ii?, jj?):
            y[ii * n + ii] += g
            y[jj * n + jj] += g
            y[ii * n + jj] -= g
            y[jj * n + ii] -= g
        case let (ii?, nil):
            if let p2 = anchored[net2] {
                y[ii * n + ii] += g
                rhs[ii] += g * p2
            }
        case let (nil, jj?):
            if let p1 = anchored[net1] {
                y[jj * n + jj] += g
                rhs[jj] += g * p1
            }
        case (nil, nil):
            // Both endpoints anchored: edge has no degrees of freedom.
            break
        }
    }

    /// Gaussian elimination with partial pivoting on a row-major flat
    /// matrix. Writes the solution into the caller-provided buffer to
    /// avoid an allocation on every step.
    private static func solve(matrix: inout [Double], rhs: inout [Double], n: Int, into x: inout [Double]) {
        guard n > 0 else { return }
        for k in 0..<n {
            // Partial pivot — find the row with the largest |matrix[r][k]|
            // and swap rows k and maxRow so the pivot is well-conditioned.
            var maxRow = k
            var maxVal = abs(matrix[k * n + k])
            for r in (k + 1)..<n {
                let v = abs(matrix[r * n + k])
                if v > maxVal { maxVal = v; maxRow = r }
            }
            if maxRow != k {
                for c in 0..<n {
                    let tmp = matrix[k * n + c]
                    matrix[k * n + c] = matrix[maxRow * n + c]
                    matrix[maxRow * n + c] = tmp
                }
                let tmp = rhs[k]; rhs[k] = rhs[maxRow]; rhs[maxRow] = tmp
            }
            let pivot = matrix[k * n + k]
            if abs(pivot) < 1e-12 {
                // Singular column — leave row as-is, treat unknown as previous value.
                continue
            }
            for r in (k + 1)..<n {
                let factor = matrix[r * n + k] / pivot
                if factor == 0 { continue }
                for c in k..<n {
                    matrix[r * n + c] -= factor * matrix[k * n + c]
                }
                rhs[r] -= factor * rhs[k]
            }
        }
        for k in stride(from: n - 1, through: 0, by: -1) {
            var sum = rhs[k]
            for c in (k + 1)..<n {
                sum -= matrix[k * n + c] * x[c]
            }
            let pivot = matrix[k * n + k]
            x[k] = abs(pivot) < 1e-12 ? rhs[k] : sum / pivot
        }
    }
}
