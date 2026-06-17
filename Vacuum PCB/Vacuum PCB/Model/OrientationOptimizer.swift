import Foundation

/// Chooses each top-level transistor's flip — which plate holds its gate
/// (`Placement.layer`) — to minimise the number of nets that must cross the
/// silicone membrane (cross-silicone vias, the leaky, hard-to-make kind).
///
/// A transistor's gate sits on its placement plate and its source/drain pads on
/// the *opposite* plate, so flipping a transistor swaps the plate of every one
/// of its pins. Whether a net needs a cross-silicone via depends **only** on
/// which plate each of its pins resolves to — never on XY position or rotation —
/// so orientation is a clean, placement-independent combinatorial problem:
/// assign a plate to each transistor to minimise the count of nets that touch
/// both plates. That is the signed-graph / min-uncut form of the placement-layer
/// problem; we solve it with a deterministic multi-start single-flip hill-climb
/// (the classic KL/FM move-the-best-cell descent), which reaches the optimum on
/// the structured netlists these boards are while staying microsecond-cheap.
///
/// Scope: only top-level `.transistor` components are flipped. Subpart instances
/// are immune — their boundary pins carry an `absoluteLayer` pinned to the
/// library plate, so toggling a subpart's `layer` doesn't move its pins; those
/// pins fall into the fixed contribution below and are never chosen as movable.
enum OrientationOptimizer {

    struct Result {
        /// Only the transistors whose chosen plate differs from the input.
        var layerForTransistor: [UUID: Plate]
        /// Cross-silicone net count before / after the search.
        var crossingBefore: Int
        var crossingAfter: Int
        /// How many transistors the search wants to flip (== layerForTransistor.count).
        var flipsApplied: Int
    }

    // MARK: - Public API

    /// Top-level transistor component ids that have a placement, in document
    /// order. These are the only flippable nodes. Subparts and every other kind
    /// are excluded.
    static func flippableTransistorIds(_ doc: CircuitDocument) -> [UUID] {
        let placed = Set(doc.physical.placements.map(\.componentId))
        return doc.logic.components
            .filter { $0.kind == .transistor && placed.contains($0.id) }
            .map(\.id)
    }

    /// Solves for the orientation that minimises cross-silicone nets. Pure and
    /// deterministic for a given `seed`. The returned `layerForTransistor` lists
    /// only the transistors that should change; call `apply` to write them.
    static func optimize(_ doc: CircuitDocument, seed: UInt64 = 0x5EED_FACE) -> Result {
        let p = Problem(doc)
        let n = p.transistorIds.count
        let initial = p.initialLayers
        let crossingBefore = p.crossing(initial)
        guard n > 0 else {
            return Result(layerForTransistor: [:],
                          crossingBefore: crossingBefore,
                          crossingAfter: crossingBefore,
                          flipsApplied: 0)
        }

        var rng = SplitMix64(seed: seed)
        // Restart 0 starts from the current layout, so the search can never
        // return a worse-than-input assignment and reports 0 flips when the
        // board is already optimal.
        var best = initial
        var bestCount = crossingBefore
        var bestFlips = 0

        let restarts = min(8, 1 + n)
        for r in 0..<restarts {
            var layers: [Plate]
            if r == 0 {
                layers = initial
            } else {
                layers = (0..<n).map { _ in rng.below(2) == 0 ? Plate.top : Plate.bottom }
            }
            p.hillClimb(&layers)
            let count = p.crossing(layers)
            let flips = zip(layers, initial).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
            // Prefer fewer crossings; tie → fewer flips from the current layout
            // (least disruptive); tie → earliest restart (we only replace on a
            // strict improvement of the (count, flips) pair).
            if count < bestCount || (count == bestCount && flips < bestFlips) {
                best = layers
                bestCount = count
                bestFlips = flips
            }
        }

        var changed: [UUID: Plate] = [:]
        for i in 0..<n where best[i] != initial[i] {
            changed[p.transistorIds[i]] = best[i]
        }
        return Result(layerForTransistor: changed,
                      crossingBefore: crossingBefore,
                      crossingAfter: bestCount,
                      flipsApplied: changed.count)
    }

    /// Writes the chosen plates onto the document's transistor placements (depth
    /// reset to 0 — identical semantics to the manual flip in
    /// `PhysicalActions.flipLayer`). Returns the number of placements changed.
    /// Never touches the logic graph.
    @discardableResult
    static func apply(_ result: Result, to doc: inout CircuitDocument) -> Int {
        var changed = 0
        for (id, plate) in result.layerForTransistor {
            guard let i = doc.physical.placements.firstIndex(where: { $0.componentId == id })
            else { continue }
            if doc.physical.placements[i].layer != plate {
                doc.physical.placements[i].layer = plate
                doc.physical.placements[i].depth = 0
                changed += 1
            }
        }
        return changed
    }

    // MARK: - Problem model

    /// Placement-independent description of the orientation problem, derived once
    /// from a document and then queried by the search. All transistor references
    /// are integer indices into `transistorIds` for cheap incremental rescoring.
    private struct Problem {
        let transistorIds: [UUID]
        let initialLayers: [Plate]
        /// Per net: a 2-bit mask (bit0 = top, bit1 = bottom) of every pin that is
        /// **not** on a flippable transistor — the fixed plate contribution
        /// (ports, rails, resistors, subpart boundary pins). Subpart pins resolve
        /// through their `absoluteLayer`, so they land here automatically.
        let fixedMask: [Int]
        /// Per net: the flippable transistor pins on it, as (transistor index,
        /// `opposite` = pin is on the plate opposite the gate, i.e. a pad).
        let netTransistorPins: [[(t: Int, opposite: Bool)]]
        /// Per transistor: the nets it touches — flipping a transistor can only
        /// change these, so gain is recomputed only over them.
        let transistorNets: [[Int]]

        init(_ doc: CircuitDocument) {
            let ids = OrientationOptimizer.flippableTransistorIds(doc)
            var indexOf: [UUID: Int] = [:]
            for (i, id) in ids.enumerated() { indexOf[id] = i }

            var placementByComp: [UUID: Placement] = [:]
            for pl in doc.physical.placements { placementByComp[pl.componentId] = pl }
            var componentById: [UUID: Component] = [:]
            for c in doc.logic.components { componentById[c.id] = c }

            // Footprint resolution (esp. subparts) isn't free; cache per component.
            var footprintCache: [UUID: Footprint] = [:]
            func footprint(_ comp: Component) -> Footprint {
                if let f = footprintCache[comp.id] { return f }
                let f = comp.footprint(doc.manufacturing, snapshots: doc.librarySnapshots)
                footprintCache[comp.id] = f
                return f
            }

            transistorIds = ids
            initialLayers = ids.map { placementByComp[$0]?.layer ?? .bottom }

            var fixed = [Int](repeating: 0, count: doc.logic.nets.count)
            var netPins = [[(t: Int, opposite: Bool)]](repeating: [], count: doc.logic.nets.count)
            var adj = [[Int]](repeating: [], count: ids.count)

            for (netIdx, net) in doc.logic.nets.enumerated() {
                for pinRef in net.pins {
                    guard let comp = componentById[pinRef.componentId],
                          let placement = placementByComp[pinRef.componentId],
                          let fpPin = footprint(comp).pin(pinRef.pinKey)
                    else { continue }
                    if let t = indexOf[pinRef.componentId] {
                        // Flippable transistor pin: its plate follows the flip.
                        netPins[netIdx].append((t, fpPin.relativeLayer == .opposite))
                        adj[t].append(netIdx)
                    } else {
                        // Fixed pin: fold its resolved plate into the mask.
                        fixed[netIdx] |= Problem.bit(placement.resolvedPlate(of: fpPin))
                    }
                }
            }

            fixedMask = fixed
            netTransistorPins = netPins
            transistorNets = adj
        }

        static func bit(_ plate: Plate) -> Int { plate == .top ? 0b01 : 0b10 }

        /// Whether net `i` touches both plates under `layers` (⇒ needs a via).
        func netCrosses(_ i: Int, _ layers: [Plate]) -> Bool {
            var mask = fixedMask[i]
            for (t, opposite) in netTransistorPins[i] {
                let plate = opposite ? layers[t].opposite : layers[t]
                mask |= Problem.bit(plate)
                if mask == 0b11 { return true }
            }
            return mask == 0b11
        }

        /// Total number of cross-silicone nets under `layers`.
        func crossing(_ layers: [Plate]) -> Int {
            var total = 0
            for i in 0..<fixedMask.count where netCrosses(i, layers) { total += 1 }
            return total
        }

        /// Descend by repeatedly applying the single best positive-gain flip,
        /// recomputing each candidate's gain only over the nets it touches. Ties
        /// go to the lowest transistor index (strict `>` keeps the first seen).
        func hillClimb(_ layers: inout [Plate]) {
            let n = transistorIds.count
            guard n > 0 else { return }
            while true {
                var bestT = -1
                var bestGain = 0
                for t in 0..<n {
                    let g = gain(t, layers)
                    if g > bestGain { bestGain = g; bestT = t }
                }
                guard bestT >= 0 else { break }
                layers[bestT] = layers[bestT].opposite
            }
        }

        /// Reduction in cross-silicone net count from flipping transistor `t`,
        /// evaluated only over the nets `t` touches.
        func gain(_ t: Int, _ layers: [Plate]) -> Int {
            var flipped = layers
            flipped[t] = layers[t].opposite
            var delta = 0
            for i in transistorNets[t] {
                let before = netCrosses(i, layers) ? 1 : 0
                let after = netCrosses(i, flipped) ? 1 : 0
                delta += before - after
            }
            return delta
        }
    }
}
