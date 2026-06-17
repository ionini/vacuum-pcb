import Foundation

/// Post-routing layout compactor — the "Minimize" action.
///
/// This is the classic EDA **placement** problem: arrange components to shrink
/// the die while keeping the board buildable. It runs in two phases, the
/// standard "global placement, then route" decomposition:
///
///  * **Phase 1 — placement search (no routing in the loop).** Simulated
///    annealing over component poses against a fast *proxy* cost that
///    correlates with a small, routable die:
///      `cost = area + λ·wirelength + μ·overlap`
///    where wirelength is total **HPWL** (per-net half-perimeter of its pins —
///    the standard wirelength proxy, and the rigorous form of "pull connected
///    parts together") and overlap penalises component bodies sitting on top of
///    each other (DRC doesn't catch body overlap, and with routing out of the
///    loop nothing else would). Because no routing or DRC runs per move, this
///    explores thousands of moves cheaply instead of the ~8 the old
///    route-every-move design managed in a second.
///
///  * **Phase 2 — realise & validate.** Re-route the nets that moved (keeping
///    untouched nets' existing routing), shrink-fit the outline, and adopt the
///    result only if it re-routes within the DRC baseline *and* is a genuine
///    improvement — a smaller die, or (when the die can't shrink) a tidier
///    layout with less wirelength. Otherwise the input is returned unchanged,
///    so Minimize never breaks a board, it just declines.
///
/// Why annealing rather than gradient descent / a force-directed placer:
/// the realised objective (does it route? does DRC pass?) is
/// non-differentiable and the grid/rotation space is discrete, so there's no
/// gradient to follow and a plain hill-climb wedges in local minima. Annealing
/// accepts cost-worse moves with a temperature-decaying probability and climbs
/// back out.
///
/// Edge features (vacuum source / atmosphere vent / port / connector) are
/// constrained to **slide along a board edge**, never inward: they physically
/// bore out to the perimeter, so the optimiser may reposition them along an
/// edge (which lets the outline contract around them) but must not drag them
/// into the interior.
enum Minimizer {

    /// Component kinds that bore out to the board edge and so must stay on the
    /// perimeter, sliding along an edge rather than moving freely.
    private static let edgeFeatureKinds: Set<ComponentKind> = [.vacuumSource, .atmVent, .port]

    // Proxy-cost weights (cost = area + wWire·HPWL + wOverlap·overlap). Area is
    // in mm², HPWL in mm, overlap in mm²; the multipliers put wirelength and
    // overlap on a comparable footing with area for the boards we deal with.
    private static let wWire = 2.0
    private static let wOverlap = 16.0
    /// Penalty per cross-silicone via (~mm²-equivalent). These vias leak and
    /// need spacing, so the placement/orientation search should prefer routing
    /// that stays on one plate. Weighted below `wOverlap` so it nudges without
    /// overriding the die-area goal. Tunable.
    private static let wVia = 4.0

    // MARK: - Options

    struct Options {
        /// Cap on placement-search trials. Phase 1 is cheap (no routing), so
        /// this can be generous.
        var maxIterations: Int
        /// Wall-clock budget for the placement search (seconds). Phase 2 runs
        /// afterwards regardless. Kept ~1 s because the search runs on the main
        /// actor (see `PhysicalInspector.minimize`).
        var timeBudget: TimeInterval
        /// Seed for the internal PRNG — deterministic, so a board minimises the
        /// same way each run.
        var seed: UInt64
        /// Breathing room (mm) left around the features when shrink-fitting.
        var margin: Double
        /// Run the placement-independent transistor-orientation pre-pass before
        /// the search, flipping transistors to cut cross-silicone vias. On by
        /// default; the result is only kept if it still routes within baseline.
        var optimizeOrientation: Bool = true

        static func make(forComponentCount n: Int) -> Options {
            Options(
                // Generous cap so long (CLI / overnight) runs are bounded by
                // `timeBudget`, not by iterations; the in-app button's short
                // budget stops well before this.
                maxIterations: min(2_000_000, max(20_000, n * 4_000)),
                timeBudget: 3.0,
                seed: 0x5EED_FACE,
                margin: 3.0,
                optimizeOrientation: true
            )
        }
    }

    // MARK: - Stats

    /// Diagnostics from one `report` run — lets the UI (and tests / tuning) see
    /// what the search did and whether the compacted result was adopted.
    struct Stats {
        var baselineIssues = 0
        var iterations = 0
        var accepted = 0
        var rejected = 0
        var adopted = false      // false ⇒ couldn't beat the input without breaking it
        var areaBefore = 0.0
        var areaAfter = 0.0
        var wirelengthBefore = 0.0
        var wirelengthAfter = 0.0
        var finalIssues = 0
        // Cross-silicone vias before/after, and how many transistors the
        // orientation pre-pass flipped. Exact counts (the headline numbers).
        var crossSiliconeViasBefore = 0
        var crossSiliconeViasAfter = 0
        var orientationFlips = 0
        var outlineBefore = Rect(origin: .zero, size: Size(width: 0, height: 0))
        var outlineAfter = Rect(origin: .zero, size: Size(width: 0, height: 0))
        // The phase-2 candidate as evaluated by the adopt/revert gate (before
        // the decision) — so a revert can be told apart from "no improvement".
        var candidateArea = 0.0
        var candidateIssues = 0
        var candidateOutline = Rect(origin: .zero, size: Size(width: 0, height: 0))
        var elapsed = 0.0

        var summary: String {
            String(
                format: "iters=%d acc=%d rej=%d adopted=%@ | area %.0f→%.0f | wire %.0f→%.0f | outline %.0f×%.0f→%.0f×%.0f | cand area=%.0f outline=%.0f×%.0f DRC=%d | DRC %d→%d | vias %d→%d flips=%d | %.2fs",
                iterations, accepted, rejected, adopted ? "Y" : "N",
                areaBefore, areaAfter, wirelengthBefore, wirelengthAfter,
                outlineBefore.size.width, outlineBefore.size.height,
                outlineAfter.size.width, outlineAfter.size.height,
                candidateArea, candidateOutline.size.width, candidateOutline.size.height, candidateIssues,
                baselineIssues, finalIssues,
                crossSiliconeViasBefore, crossSiliconeViasAfter, orientationFlips, elapsed
            )
        }
    }

    // MARK: - Entry point

    /// Returns a compacted copy of `doc`. Only the physical projection changes;
    /// the logic graph is untouched. If the search can't beat the starting area
    /// without breaking something, the result equals the input.
    static func minimize(_ input: CircuitDocument, options optionsIn: Options? = nil) -> CircuitDocument {
        report(input, options: optionsIn).doc
    }

    /// Same as `minimize`, but also returns run diagnostics. Internal so the UI
    /// and tests can inspect what happened.
    static func report(_ input: CircuitDocument, options optionsIn: Options? = nil)
        -> (doc: CircuitDocument, stats: Stats) {
        let start = Date()
        let outline = input.physical.boardOutline
        let pitch = max(0.0001, input.manufacturing.gridPitch)
        let baseline = blockingIssueCount(input)

        var stats = Stats(baselineIssues: baseline,
                          areaBefore: area(of: input) ?? 0,
                          wirelengthBefore: hpwl(of: input),
                          crossSiliconeViasBefore: input.physical.crossSiliconeViaPositions().count,
                          outlineBefore: outline)
        func finish(_ d: CircuitDocument, adopted: Bool) -> (doc: CircuitDocument, stats: Stats) {
            stats.adopted = adopted
            stats.areaAfter = area(of: d) ?? 0
            stats.wirelengthAfter = hpwl(of: d)
            stats.finalIssues = blockingIssueCount(d)
            stats.crossSiliconeViasAfter = d.physical.crossSiliconeViaPositions().count
            stats.outlineAfter = d.physical.boardOutline
            stats.elapsed = Date().timeIntervalSince(start)
            return (d, stats)
        }

        guard outline.size.width > 0, outline.size.height > 0,
              input.physical.placements.count >= 2 else { return finish(input, adopted: false) }

        let options = optionsIn ?? .make(forComponentCount: input.physical.placements.count)

        // ── Phase 1: simulated-annealing placement search ─────────────────────
        // Perturb one component's pose at a time (translate / rotate; edge
        // features slide along their edge), then **incrementally re-route** the
        // nets the move disturbs *plus their congested neighbours* with the
        // negotiated rip-up router — so a part can pack tighter and the router
        // renegotiates the local channels around it instead of failing. A move
        // is rejected outright unless it keeps DRC within the baseline; among
        // DRC-legal moves, annealing accepts cost improvements always and
        // cost-worse moves with a cooling probability, so it climbs out of the
        // local minima the old greedy repair got stuck in. The best DRC-clean
        // layout seen is carried into phase 2.
        // ── Phase 0: orientation pre-pass (placement-independent) ─────────────
        // Flipping a transistor moves its gate/pads to the opposite plate
        // without touching XY, so the count of nets that must cross the silicone
        // depends only on this assignment. Solve it first, re-route the disturbed
        // nets, and keep it only if it still builds within baseline — otherwise
        // discard the flips and anneal from the original layout (never break a
        // board). The annealer then places/routes this improved orientation.
        var working = input
        if options.optimizeOrientation {
            var oriented = input
            let result = OrientationOptimizer.optimize(input, seed: options.seed)
            let flips = OrientationOptimizer.apply(result, to: &oriented)
            if flips > 0 {
                let moved = Set(result.layerForTransistor.keys)
                var movedNets: Set<UUID> = []
                for net in oriented.logic.nets
                where net.pins.contains(where: { moved.contains($0.componentId) }) {
                    movedNets.insert(net.id)
                }
                reroute(&oriented, nets: movedNets)
                if blockingIssueCount(oriented) <= baseline {
                    working = oriented
                    stats.orientationFlips = flips
                }
            }
        }
        var rng = SplitMix64(seed: options.seed)
        let deadline = Date().addingTimeInterval(options.timeBudget)
        let movable = movableIndices(input)

        var current = working
        var currentCost = cost(of: current)
        var bestCost = currentCost
        // Initial temperature: a small fraction of the starting cost, so early
        // moves that worsen cost by a few percent are usually accepted and the
        // search can rearrange before cooling locks it in.
        let t0 = max(1.0, currentCost * 0.04)

        if !movable.isEmpty {
            for iter in 0..<options.maxIterations {
                if Date() >= deadline { break }
                stats.iterations += 1
                let progress = Double(iter) / Double(max(1, options.maxIterations))
                let temperature = max(t0 * 1e-3, t0 * (1 - progress))   // linear cool

                // Bias selection toward components far from the board centre
                // (moving an extreme feature inward is what lets the die shrink)
                // and those displaced from their net centroid.
                let index = pickComponent(current, movable, &rng)
                var trial = current
                guard proposeMove(&trial, index: index, jump: 1 - progress,
                                  pitch: pitch, rng: &rng) else { stats.rejected += 1; continue }

                let nets = ripUpNets(trial, index: index)
                reroute(&trial, nets: nets)
                guard blockingIssueCount(trial) <= baseline else { stats.rejected += 1; continue }

                let c = cost(of: trial)
                let dCost = c - currentCost
                if dCost <= 0 || rng.unitDouble() < exp(-dCost / temperature) {
                    current = trial
                    currentCost = c
                    stats.accepted += 1
                    if c < bestCost - 1e-9 { bestCost = c; working = trial }
                } else {
                    stats.rejected += 1
                }
            }
        }

        // ── Phase 2: shrink-fit & adopt ──────────────────────────────────────
        // `working` is already re-routed and within the DRC baseline (every
        // accepted repair preserved that), so tighten the outline around it.
        let candidate = shrinkFit(working, baseline: baseline, pitch: pitch, margin: options.margin)

        let candIssues = blockingIssueCount(candidate)
        stats.candidateArea = area(of: candidate) ?? 0
        stats.candidateIssues = candIssues
        stats.candidateOutline = candidate.physical.boardOutline
        // Adopt a result that still builds (DRC ≤ baseline) and is a genuine
        // improvement — either:
        //   * a smaller *die* (`boardOutline` area — the headline goal; we
        //     measure the die, not the feature box, which can grow as edge
        //     features ride out to the perimeter), or
        //   * when the die can't shrink, a meaningfully tidier layout (≥1% less
        //     total wirelength). This is what pulls a displaced component back
        //     toward its net on a board whose outline is already minimal.
        let inDie = areaOf(input.physical.boardOutline)
        let candDie = areaOf(candidate.physical.boardOutline)
        let smaller = candDie < inDie - 1e-6
        let tidier = candDie <= inDie + 1e-6 && hpwl(of: candidate) < hpwl(of: input) * 0.99
        // An orientation win shows up as fewer cross-silicone vias with the die
        // unchanged (flips don't move XY). Adopt it even when area/wirelength are
        // flat, as long as the board still builds and the wiring didn't bloat to
        // buy it. Exact counter here — the gate runs once per report.
        let viasIn = input.physical.crossSiliconeViaPositions().count
        let viasOut = candidate.physical.crossSiliconeViaPositions().count
        let fewerVias = candDie <= inDie + 1e-6
            && viasOut < viasIn
            && hpwl(of: candidate) <= hpwl(of: input) * 1.01
        if candIssues <= baseline, smaller || tidier || fewerVias {
            return finish(candidate, adopted: true)
        }
        return finish(input, adopted: false)
    }

    // MARK: - Proxy cost

    /// `area + wWire·HPWL + wOverlap·overlap + wVia·vias` — the phase-1 objective.
    private static func cost(of doc: CircuitDocument) -> Double {
        let a = area(of: doc) ?? 0
        return a + wWire * hpwl(of: doc) + wOverlap * overlapPenalty(of: doc)
            + wVia * Double(crossSiliconeViaCount(doc))
    }

    /// Cheap per-iteration count of silicone-crossing vias: per route, the paired
    /// count of depth-0 `.via` waypoints on opposite plates. Mirrors the T0/B0
    /// rule in `PhysicalLayout.crossSiliconeViaPositions` but skips its O(n²) XY
    /// matching — the negotiated router emits a crossing as one via waypoint on
    /// each plate, so `min(top, bottom)` per route is the crossing count. A cost
    /// proxy only; Stats and the adopt gate use the exact counter. Internal so
    /// tests can pin it to the exact count.
    static func crossSiliconeViaCount(_ doc: CircuitDocument) -> Int {
        var total = 0
        for route in doc.physical.routes {
            var top = 0, bottom = 0
            for seg in route.segments where seg.layer.depth == 0 {
                for wp in seg.waypoints where wp.kind == .via {
                    if seg.layer.plate == .top { top += 1 } else { bottom += 1 }
                }
            }
            total += min(top, bottom)
        }
        return total
    }

    /// Total half-perimeter wirelength: for each net, the half-perimeter of the
    /// bounding box of its pins' world positions. The standard wirelength proxy
    /// — minimising it pulls each net's components together (the rigorous form
    /// of "give them gravity to each other"). Internal so tests can assert on it.
    static func hpwl(of doc: CircuitDocument) -> Double {
        var total = 0.0
        for net in doc.logic.nets {
            var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
            var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
            var count = 0
            for pin in net.pins {
                guard let placement = doc.physical.placements.first(where: { $0.componentId == pin.componentId }),
                      let comp = doc.logic.components.first(where: { $0.id == pin.componentId }),
                      let fp = comp.footprint(doc.manufacturing, snapshots: doc.librarySnapshots).pin(pin.pinKey)
                else { continue }
                let w = placement.worldPosition(of: fp)
                minX = min(minX, w.x); minY = min(minY, w.y)
                maxX = max(maxX, w.x); maxY = max(maxY, w.y)
                count += 1
            }
            if count >= 2 { total += (maxX - minX) + (maxY - minY) }
        }
        return total
    }

    /// Sum of pairwise overlap area between component exclusion zones (rotated
    /// to world AABBs). DRC never flags two component bodies overlapping in XY,
    /// so without this the proxy would happily stack parts on top of each other.
    private static func overlapPenalty(of doc: CircuitDocument) -> Double {
        struct Box { let minX, minY, maxX, maxY: Double }
        var boxes: [Box] = []
        for p in doc.physical.placements {
            guard let comp = doc.logic.components.first(where: { $0.id == p.componentId }) else { continue }
            let rect = comp.footprint(doc.manufacturing, snapshots: doc.librarySnapshots).exclusionRect
            if rect.size.width == 0, rect.size.height == 0 { continue }
            let ext = rotatedExtents(rect, p.rotation)
            boxes.append(Box(minX: p.position.x + ext.min.x, minY: p.position.y + ext.min.y,
                             maxX: p.position.x + ext.max.x, maxY: p.position.y + ext.max.y))
        }
        var total = 0.0
        for i in 0..<boxes.count {
            for j in (i + 1)..<boxes.count {
                let dx = min(boxes[i].maxX, boxes[j].maxX) - max(boxes[i].minX, boxes[j].minX)
                let dy = min(boxes[i].maxY, boxes[j].maxY) - max(boxes[i].minY, boxes[j].minY)
                if dx > 0, dy > 0 { total += dx * dy }
            }
        }
        return total
    }

    // MARK: - Local repair

    /// Component indices the search is allowed to move. Everything with a
    /// footprint except screws — screws are user-placed mechanical features and
    /// stay put (moving one could pull a mount off its intended spot).
    private static func movableIndices(_ doc: CircuitDocument) -> [Int] {
        doc.physical.placements.indices.filter { i in
            guard let c = doc.logic.components.first(where: { $0.id == doc.physical.placements[i].componentId })
            else { return false }
            return c.kind != .screw
        }
    }

    /// Roulette-picks a movable component, weighting toward parts far from the
    /// board centre (pulling an extreme feature inward is what lets the die
    /// shrink) and parts displaced from their net centroid (loose wiring).
    private static func pickComponent(
        _ doc: CircuitDocument, _ movable: [Int], _ rng: inout SplitMix64
    ) -> Int {
        let o = doc.physical.boardOutline
        let cx = (o.minX + o.maxX) / 2, cy = (o.minY + o.maxY) / 2
        var weights: [Double] = []
        var total = 0.0
        for i in movable {
            let p = doc.physical.placements[i].position
            let w = 1.0 + hypot(p.x - cx, p.y - cy) + displacementToNetCentroid(doc, i)
            weights.append(w); total += w
        }
        var pick = rng.unitDouble() * total
        for (k, w) in weights.enumerated() {
            pick -= w
            if pick <= 0 { return movable[k] }
        }
        return movable[movable.count - 1]
    }

    /// Mutates one component's pose in place. Edge features (and connectors)
    /// slide along their edge; interior parts either rotate (a quarter of the
    /// time) or translate — half the translations aim a fraction of the way
    /// toward the net centroid (tightens wiring), half are a random jump whose
    /// reach scales with `jump` ∈ [0,1] (hot early, cold late). Returns false
    /// if the result is a no-op (clamped/snapped back to where it started).
    private static func proposeMove(
        _ doc: inout CircuitDocument, index: Int, jump: Double, pitch: Double,
        rng: inout SplitMix64
    ) -> Bool {
        guard let info = footprintInfo(doc, index) else { return false }
        let comp = info.comp
        let outline = doc.physical.boardOutline
        let before = doc.physical.placements[index]
        let isConnector = comp.kind == .connector && before.edgeAnchor != nil
        let isEdge = isConnector || edgeFeatureKinds.contains(comp.kind)
        let target = netCentroidTarget(doc, index)

        if isEdge {
            let edge = isConnector ? before.edgeAnchor!.edge
                                   : nearestEdge(to: before.position, in: outline)
            let len = edgeLength(edge, in: outline)
            let clearance = isConnector ? info.fp.exclusionRect.size.height / 2
                : max(info.fp.boundingRect.size.width, info.fp.boundingRect.size.height) / 2
            let curOff = offsetAlongEdge(before.position, edge: edge, outline: outline)
            // Aim toward the net centroid's projection on the edge, plus jitter.
            let aim = target.map { offsetAlongEdge($0, edge: edge, outline: outline) } ?? curOff
            let span = max(pitch, len * 0.25 * (0.2 + jump))
            let raw = curOff + (aim - curOff) * 0.5 + (rng.unitDouble() * 2 - 1) * span
            var off = (raw / pitch).rounded() * pitch
            off = len - clearance >= clearance ? max(clearance, min(len - clearance, off)) : len / 2
            let inset = isConnector ? 0 : edgeInset(info.fp)
            placeOnEdge(&doc.physical.placements[index], edge: edge, offset: off, inset: inset,
                        isConnector: isConnector, outline: outline)
        } else if !isConnector, comp.kind != .connector, rng.unitDouble() < 0.25 {
            // Rotate to one of the four orientations (not the current one).
            let options = Rotation.allCases.filter { $0 != before.rotation }
            doc.physical.placements[index].rotation = options[rng.below(options.count)]
        } else {
            let ext = rotatedExtents(info.fp.boundingRect, before.rotation)
            let dest: Point
            if let target, rng.unitDouble() < 0.5, let c = pinCentroid(doc, index) {
                let frac = 0.3 + 0.7 * rng.unitDouble()
                dest = Point(x: before.position.x + (target.x - c.x) * frac,
                             y: before.position.y + (target.y - c.y) * frac)
            } else {
                let span = max(pitch, max(outline.size.width, outline.size.height) * 0.3 * (0.1 + jump))
                dest = Point(x: before.position.x + (rng.unitDouble() * 2 - 1) * span,
                             y: before.position.y + (rng.unitDouble() * 2 - 1) * span)
            }
            doc.physical.placements[index].position = clampInside(
                dest, ext: ext, outline: outline, pitch: pitch)
        }

        let after = doc.physical.placements[index]
        return after.rotation != before.rotation
            || abs(after.position.x - before.position.x) > 0.01
            || abs(after.position.y - before.position.y) > 0.01
    }

    /// Nets to rip up when component `index` moves: just the nets the moved
    /// component touches. Everything else keeps its existing (often hand-)
    /// routing as a fixed obstacle, so the move's cost reflects only the moved
    /// net's change — re-routing neighbours too would replace good hand routes
    /// with longer auto ones and drown the signal. The negotiated router still
    /// threads the ripped nets around all the frozen routing.
    private static func ripUpNets(_ doc: CircuitDocument, index: Int) -> Set<UUID> {
        let id = doc.physical.placements[index].componentId
        var nets: Set<UUID> = []
        for net in doc.logic.nets where net.pins.contains(where: { $0.componentId == id }) {
            nets.insert(net.id)
        }
        return nets
    }

    /// Centroid of the foreign pins this component shares nets with — the point
    /// its connections pull toward. Nil if it has no connected foreign pins.
    private static func netCentroidTarget(_ doc: CircuitDocument, _ index: Int) -> Point? {
        let id = doc.physical.placements[index].componentId
        var sumX = 0.0, sumY = 0.0, n = 0
        for net in doc.logic.nets where net.pins.contains(where: { $0.componentId == id }) {
            for pin in net.pins where pin.componentId != id {
                guard let p = doc.physical.placements.first(where: { $0.componentId == pin.componentId }),
                      let c = doc.logic.components.first(where: { $0.id == pin.componentId }),
                      let fp = c.footprint(doc.manufacturing, snapshots: doc.librarySnapshots).pin(pin.pinKey)
                else { continue }
                let w = p.worldPosition(of: fp)
                sumX += w.x; sumY += w.y; n += 1
            }
        }
        guard n > 0 else { return nil }
        return Point(x: sumX / Double(n), y: sumY / Double(n))
    }

    /// Centroid of this component's own pins in world space (its body's
    /// connection point); the component's anchor if it has no pins.
    private static func pinCentroid(_ doc: CircuitDocument, _ index: Int) -> Point? {
        guard let info = footprintInfo(doc, index) else { return nil }
        let placement = doc.physical.placements[index]
        let pins = info.fp.pins
        guard !pins.isEmpty else { return placement.position }
        var sx = 0.0, sy = 0.0
        for fp in pins { let w = placement.worldPosition(of: fp); sx += w.x; sy += w.y }
        return Point(x: sx / Double(pins.count), y: sy / Double(pins.count))
    }

    /// How far this component sits from its net centroid — used to repair the
    /// most-displaced parts first.
    private static func displacementToNetCentroid(_ doc: CircuitDocument, _ index: Int) -> Double {
        guard let t = netCentroidTarget(doc, index), let c = pinCentroid(doc, index) else { return 0 }
        return hypot(t.x - c.x, t.y - c.y)
    }

    // MARK: - Re-routing & validity

    /// Rips up the given nets and re-routes them with the negotiated-congestion
    /// router, treating every *other* net's route as a fixed obstacle. This is
    /// the incremental rip-up the search leans on: only the disturbed nets (and
    /// the congested neighbours the caller folds into `nets`) renegotiate,
    /// while the rest of the hand/auto routing stays put — keeping DRC near the
    /// baseline instead of failing a full from-scratch re-route.
    private static func reroute(_ doc: inout CircuitDocument, nets: Set<UUID>) {
        guard !nets.isEmpty else { return }
        doc.physical.routes.removeAll { nets.contains($0.netId) }
        for entry in AutoRouter.planNegotiated(doc, ripUp: nets) {
            if let i = doc.physical.routes.firstIndex(where: { $0.netId == entry.netId }) {
                doc.physical.routes[i].segments.append(entry.segment)
            } else {
                doc.physical.routes.append(Route(netId: entry.netId, segments: [entry.segment]))
            }
        }
    }

    private static func blockingIssueCount(_ doc: CircuitDocument) -> Int { DRC.check(doc).count }

    // MARK: - Bounding box / objective

    private static func area(of doc: CircuitDocument) -> Double? {
        guard let box = featureBox(doc, includeConnectors: true) else { return nil }
        return box.size.width * box.size.height
    }

    /// AABB over every placement's rotated footprint plus every route waypoint.
    /// `includeConnectors == false` skips connector protrusions. Internal so
    /// tests can assert area against the same measure the objective uses.
    static func featureBox(_ doc: CircuitDocument, includeConnectors: Bool) -> Rect? {
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        var any = false
        func add(_ x: Double, _ y: Double) {
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y); any = true
        }
        for p in doc.physical.placements {
            guard let comp = doc.logic.components.first(where: { $0.id == p.componentId }) else { continue }
            if comp.kind == .connector, !includeConnectors { continue }
            let rect = comp.footprint(doc.manufacturing, snapshots: doc.librarySnapshots).boundingRect
            if rect.size.width == 0, rect.size.height == 0 { add(p.position.x, p.position.y); continue }
            let r = p.rotation.radians, c = cos(r), s = sin(r)
            for corner in [
                Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY),
                Point(x: rect.maxX, y: rect.maxY), Point(x: rect.minX, y: rect.maxY),
            ] {
                add(p.position.x + corner.x * c - corner.y * s, p.position.y + corner.x * s + corner.y * c)
            }
        }
        for route in doc.physical.routes {
            for seg in route.segments {
                for wp in seg.waypoints { add(wp.position.x, wp.position.y) }
            }
        }
        guard any else { return nil }
        return Rect(origin: Point(x: minX, y: minY), size: Size(width: maxX - minX, height: maxY - minY))
    }

    // MARK: - Outline shrink-fit

    /// Shrinks the board outline to the compacted layout, re-anchoring edge
    /// features and connectors onto the new (smaller) edges and re-routing
    /// them. Bisects an interpolation factor between the original outline and a
    /// tight target, keeping the smallest outline that still re-routes within
    /// the DRC baseline.
    private static func shrinkFit(
        _ doc: CircuitDocument, baseline: Int, pitch: Double, margin: Double
    ) -> CircuitDocument {
        let original = doc.physical.boardOutline
        guard let core = featureBox(doc, includeConnectors: false) else { return doc }
        var tight = snapRectOutward(
            Rect(origin: Point(x: core.minX - margin, y: core.minY - margin),
                 size: Size(width: core.size.width + 2 * margin, height: core.size.height + 2 * margin)),
            pitch: pitch)
        tight = grownToHostConnectors(doc, tight)

        guard tight.size.width * tight.size.height < original.size.width * original.size.height
        else { return doc }

        var lo = 0.0, hi = 1.0
        var bestDoc = doc
        for _ in 0..<7 {
            let t = (lo + hi) / 2
            let candidate = snapRectOutward(lerpRect(original, tight, t), pitch: pitch)
            var trial = doc
            let movedNets = applyOutline(&trial, outline: candidate, pitch: pitch)
            reroute(&trial, nets: movedNets)
            if blockingIssueCount(trial) <= baseline { lo = t; bestDoc = trial } else { hi = t }
        }
        return bestDoc
    }

    /// Writes a new outline and re-anchors every edge feature / connector onto
    /// it, returning the nets that therefore need re-routing.
    private static func applyOutline(
        _ doc: inout CircuitDocument, outline: Rect, pitch: Double
    ) -> Set<UUID> {
        doc.physical.boardOutline = outline
        var nets: Set<UUID> = []
        for i in doc.physical.placements.indices {
            guard let comp = doc.logic.components.first(where: { $0.id == doc.physical.placements[i].componentId })
            else { continue }
            let isConnector = comp.kind == .connector && doc.physical.placements[i].edgeAnchor != nil
            guard isConnector || edgeFeatureKinds.contains(comp.kind) else { continue }
            let fp = comp.footprint(doc.manufacturing, snapshots: doc.librarySnapshots)
            let edge: Edge = isConnector ? doc.physical.placements[i].edgeAnchor!.edge
                                         : nearestEdge(to: doc.physical.placements[i].position, in: outline)
            let clearance = isConnector ? fp.exclusionRect.size.height / 2
                                        : max(fp.boundingRect.size.width, fp.boundingRect.size.height) / 2
            let len = edgeLength(edge, in: outline)
            var off = (offsetAlongEdge(doc.physical.placements[i].position, edge: edge, outline: outline) / pitch).rounded() * pitch
            off = len - clearance >= clearance ? max(clearance, min(len - clearance, off)) : len / 2
            let inset = isConnector ? 0 : edgeInset(fp)
            placeOnEdge(&doc.physical.placements[i], edge: edge, offset: off, inset: inset,
                        isConnector: isConnector, outline: outline)
            for net in doc.logic.nets where net.pins.contains(where: { $0.componentId == comp.id }) {
                nets.insert(net.id)
            }
        }
        return nets
    }

    private static func grownToHostConnectors(_ doc: CircuitDocument, _ rect: Rect) -> Rect {
        var needW = 0.0, needH = 0.0
        for p in doc.physical.placements {
            guard let anchor = p.edgeAnchor,
                  let comp = doc.logic.components.first(where: { $0.id == p.componentId }),
                  comp.kind == .connector else { continue }
            let row = comp.footprint(doc.manufacturing, snapshots: doc.librarySnapshots).exclusionRect.size.height
            switch anchor.edge {
            case .north, .south: needW = max(needW, row)
            case .east, .west:   needH = max(needH, row)
            }
        }
        var out = rect
        if out.size.width < needW { out.origin.x = (out.minX + out.size.width / 2) - needW / 2; out.size.width = needW }
        if out.size.height < needH { out.origin.y = (out.minY + out.size.height / 2) - needH / 2; out.size.height = needH }
        return out
    }

    // MARK: - Edge geometry

    private static func nearestEdge(to p: Point, in outline: Rect) -> Edge {
        let dS = abs(p.y - outline.minY), dN = abs(outline.maxY - p.y)
        let dW = abs(p.x - outline.minX), dE = abs(outline.maxX - p.x)
        let m = min(min(dS, dN), min(dW, dE))
        if m == dS { return .south }
        if m == dN { return .north }
        if m == dW { return .west }
        return .east
    }

    private static func edgeLength(_ edge: Edge, in outline: Rect) -> Double {
        switch edge {
        case .north, .south: return outline.size.width
        case .east, .west:   return outline.size.height
        }
    }

    /// Distance of `p` from the edge's start corner, measured along the edge
    /// (south/north from the west end; east/west from the south end) — matches
    /// `EdgeAnchor`'s convention.
    private static func offsetAlongEdge(_ p: Point, edge: Edge, outline: Rect) -> Double {
        switch edge {
        case .north, .south: return p.x - outline.minX
        case .east, .west:   return p.y - outline.minY
        }
    }

    /// Places a placement on `edge` at `offset` along it, rotation pointing
    /// outward. Bare edge features (vent / vacuum / port) anchor at their
    /// channel-side end, so they're set `inset` *inward* from the edge line —
    /// the outward-pointing bore still reaches the edge, but the feeding
    /// channel clears the outer face (otherwise it hugs the wall → thin-wall
    /// DRC). Connectors keep their anchor on the edge (their pins live out in
    /// the protrusion) and stay in sync via `edgeAnchor`.
    private static func placeOnEdge(
        _ placement: inout Placement, edge: Edge, offset: Double, inset: Double,
        isConnector: Bool, outline: Rect
    ) {
        let anchor = EdgeAnchor(edge: edge, offsetAlongEdge: offset)
        var pos = anchor.worldPosition(in: outline)
        if !isConnector {
            let n = edge.outwardNormal
            pos = Point(x: pos.x - n.x * inset, y: pos.y - n.y * inset)
        }
        placement.position = pos
        placement.rotation = edge.outwardRotation
        if isConnector { placement.edgeAnchor = anchor }
    }

    /// How far a bare edge feature's channel-side anchor sits inside the edge:
    /// its outward bore reach, so the bore tip lands on the edge.
    private static func edgeInset(_ fp: Footprint) -> Double { fp.boundingRect.size.width / 2 }

    // MARK: - Small geometry helpers

    private static func footprintInfo(_ doc: CircuitDocument, _ index: Int) -> (comp: Component, fp: Footprint)? {
        let id = doc.physical.placements[index].componentId
        guard let comp = doc.logic.components.first(where: { $0.id == id }) else { return nil }
        return (comp, comp.footprint(doc.manufacturing, snapshots: doc.librarySnapshots))
    }

    private static func rotatedExtents(_ rect: Rect, _ rotation: Rotation) -> (min: Point, max: Point) {
        let r = rotation.radians, c = cos(r), s = sin(r)
        let corners = [
            Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY),
            Point(x: rect.maxX, y: rect.maxY), Point(x: rect.minX, y: rect.maxY),
        ].map { Point(x: $0.x * c - $0.y * s, y: $0.x * s + $0.y * c) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return (Point(x: xs.min()!, y: ys.min()!), Point(x: xs.max()!, y: ys.max()!))
    }

    private static func clampInside(
        _ p: Point, ext: (min: Point, max: Point), outline: Rect, pitch: Double
    ) -> Point {
        func axis(_ v: Double, lo: Double, hi: Double, center: Double) -> Double {
            guard lo <= hi else { return (center / pitch).rounded() * pitch }
            var s = (v / pitch).rounded() * pitch
            if s < lo { s = (lo / pitch).rounded(.up) * pitch }
            if s > hi { s = (hi / pitch).rounded(.down) * pitch }
            return s
        }
        let x = axis(p.x, lo: outline.minX - ext.min.x, hi: outline.maxX - ext.max.x,
                     center: (outline.minX + outline.maxX) / 2 - (ext.min.x + ext.max.x) / 2)
        let y = axis(p.y, lo: outline.minY - ext.min.y, hi: outline.maxY - ext.max.y,
                     center: (outline.minY + outline.maxY) / 2 - (ext.min.y + ext.max.y) / 2)
        return Point(x: x, y: y)
    }

    private static func snapRectOutward(_ r: Rect, pitch: Double) -> Rect {
        let x0 = (r.minX / pitch).rounded(.down) * pitch
        let y0 = (r.minY / pitch).rounded(.down) * pitch
        let x1 = (r.maxX / pitch).rounded(.up) * pitch
        let y1 = (r.maxY / pitch).rounded(.up) * pitch
        return Rect(origin: Point(x: x0, y: y0), size: Size(width: x1 - x0, height: y1 - y0))
    }

    private static func lerpRect(_ a: Rect, _ b: Rect, _ t: Double) -> Rect {
        func l(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        return Rect(origin: Point(x: l(a.minX, b.minX), y: l(a.minY, b.minY)),
                    size: Size(width: l(a.size.width, b.size.width), height: l(a.size.height, b.size.height)))
    }

    private static func areaOf(_ r: Rect) -> Double { r.size.width * r.size.height }
}

/// Small, fast, seedable PRNG (SplitMix64) so a minimise run is reproducible
/// for a given seed — the determinism the tests pin — while parallel CLI
/// restarts each get a distinct, independent stream from a distinct seed.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform double in [0, 1) with 53 bits of mantissa.
    mutating func unitDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Uniform integer in [0, n).
    mutating func below(_ n: Int) -> Int {
        guard n > 0 else { return 0 }
        return Int(next() % UInt64(n))
    }
}
