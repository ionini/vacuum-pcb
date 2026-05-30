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

        static func make(forComponentCount n: Int) -> Options {
            Options(
                maxIterations: min(20000, max(2000, n * 800)),
                timeBudget: 3.0,
                seed: 0x5EED_FACE,
                margin: 3.0
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
                format: "iters=%d acc=%d rej=%d adopted=%@ | area %.0f→%.0f | wire %.0f→%.0f | outline %.0f×%.0f→%.0f×%.0f | cand area=%.0f outline=%.0f×%.0f DRC=%d | DRC %d→%d | %.2fs",
                iterations, accepted, rejected, adopted ? "Y" : "N",
                areaBefore, areaAfter, wirelengthBefore, wirelengthAfter,
                outlineBefore.size.width, outlineBefore.size.height,
                outlineAfter.size.width, outlineAfter.size.height,
                candidateArea, candidateOutline.size.width, candidateOutline.size.height, candidateIssues,
                baselineIssues, finalIssues, elapsed
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
                          outlineBefore: outline)
        func finish(_ d: CircuitDocument, adopted: Bool) -> (doc: CircuitDocument, stats: Stats) {
            stats.adopted = adopted
            stats.areaAfter = area(of: d) ?? 0
            stats.wirelengthAfter = hpwl(of: d)
            stats.finalIssues = blockingIssueCount(d)
            stats.outlineAfter = d.physical.boardOutline
            stats.elapsed = Date().timeIntervalSince(start)
            return (d, stats)
        }

        guard outline.size.width > 0, outline.size.height > 0,
              input.physical.placements.count >= 2 else { return finish(input, adopted: false) }

        let options = optionsIn ?? .make(forComponentCount: input.physical.placements.count)

        // ── Phase 1: greedy, routing-aware local repair ───────────────────────
        // Pull each component toward the centroid of what it's wired to,
        // re-routing only its own nets and keeping the move only when it stays
        // DRC-clean *and* lowers the cost. A part already well placed has no
        // improving move, so it stays put — the search fixes a displaced part
        // (and tightens the wiring everywhere it can) without scrambling the
        // rest, which would force a full re-route the single-pass router can't
        // realise on a congested board. Most-displaced parts are repaired first
        // so a tight time budget is spent where it matters. Passes repeat until
        // a pass makes no progress, the iteration cap, or the deadline.
        var working = input
        let deadline = Date().addingTimeInterval(options.timeBudget)
        let maxPasses = max(2, options.maxIterations / max(1, input.physical.placements.count) / 4)
        passLoop: for _ in 0..<maxPasses {
            // Recompute each pass: a component's slack (distance from its net
            // centroid) shrinks as it's repaired, so the ordering re-prioritises.
            let order = working.physical.placements.indices
                .map { (index: $0, slack: displacementToNetCentroid(working, $0)) }
                .filter { $0.slack > pitch }
                .sorted { $0.slack > $1.slack }
            if order.isEmpty { break }
            var improvedThisPass = false
            for entry in order {
                if Date() >= deadline { break passLoop }
                stats.iterations += 1
                if tryRepair(&working, index: entry.index, baseline: baseline, pitch: pitch) {
                    stats.accepted += 1
                    improvedThisPass = true
                } else {
                    stats.rejected += 1
                }
            }
            if !improvedThisPass { break }
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
        if candIssues <= baseline, smaller || tidier {
            return finish(candidate, adopted: true)
        }
        return finish(input, adopted: false)
    }

    // MARK: - Proxy cost

    /// `area + wWire·HPWL + wOverlap·overlap` — the phase-1 objective.
    private static func cost(of doc: CircuitDocument) -> Double {
        let a = area(of: doc) ?? 0
        return a + wWire * hpwl(of: doc) + wOverlap * overlapPenalty(of: doc)
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

    /// Tries to improve component `index` by nudging it toward the centroid of
    /// the foreign pins it shares nets with (the wirelength-minimising target),
    /// re-routing only its own nets. A few fractions of the full step are tried
    /// (a full jump can overshoot or overlap); the cheapest variant that stays
    /// within the DRC `baseline` *and* lowers the overall cost is kept. Returns
    /// true if `working` was improved. Edge features slide along their edge
    /// toward the target rather than moving inward.
    private static func tryRepair(
        _ working: inout CircuitDocument, index: Int, baseline: Int, pitch: Double
    ) -> Bool {
        guard let info = footprintInfo(working, index),
              let target = netCentroidTarget(working, index),
              let myCentroid = pinCentroid(working, index)
        else { return false }
        let comp = info.comp
        let outline = working.physical.boardOutline
        let placement = working.physical.placements[index]
        let isConnector = comp.kind == .connector && placement.edgeAnchor != nil
        let isEdge = isConnector || edgeFeatureKinds.contains(comp.kind)

        // The nets that must be re-routed when this component moves.
        var nets: Set<UUID> = []
        for net in working.logic.nets where net.pins.contains(where: { $0.componentId == comp.id }) {
            nets.insert(net.id)
        }

        let baseCost = cost(of: working)
        var bestDoc: CircuitDocument?
        var bestCost = baseCost
        let dxFull = target.x - myCentroid.x, dyFull = target.y - myCentroid.y

        for frac in [1.0, 0.5] {
            var trial = working
            if isEdge {
                let edge = isConnector ? placement.edgeAnchor!.edge
                                       : nearestEdge(to: placement.position, in: outline)
                let clearance = isConnector ? info.fp.exclusionRect.size.height / 2
                    : max(info.fp.boundingRect.size.width, info.fp.boundingRect.size.height) / 2
                let len = edgeLength(edge, in: outline)
                let desired = Point(x: placement.position.x + dxFull * frac,
                                    y: placement.position.y + dyFull * frac)
                var off = (offsetAlongEdge(desired, edge: edge, outline: outline) / pitch).rounded() * pitch
                off = len - clearance >= clearance ? max(clearance, min(len - clearance, off)) : len / 2
                let inset = isConnector ? 0 : edgeInset(info.fp)
                placeOnEdge(&trial.physical.placements[index], edge: edge, offset: off, inset: inset,
                            isConnector: isConnector, outline: outline)
            } else {
                let ext = rotatedExtents(info.fp.boundingRect, placement.rotation)
                trial.physical.placements[index].position = clampInside(
                    Point(x: placement.position.x + dxFull * frac, y: placement.position.y + dyFull * frac),
                    ext: ext, outline: outline, pitch: pitch)
            }
            // Skip if the clamped/snapped result is a no-op.
            let np = trial.physical.placements[index].position
            if abs(np.x - placement.position.x) < 0.01, abs(np.y - placement.position.y) < 0.01 { continue }

            reroute(&trial, nets: nets)
            guard blockingIssueCount(trial) <= baseline else { continue }
            let c = cost(of: trial)
            if c < bestCost - 1e-6 { bestCost = c; bestDoc = trial }
        }
        if let bestDoc { working = bestDoc; return true }
        return false
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

    /// Re-plans only the given nets (the ones whose moved component touches),
    /// leaving other routing intact. Used by the local repair and the
    /// shrink-fit's edge re-anchor.
    private static func reroute(_ doc: inout CircuitDocument, nets: Set<UUID>) {
        guard !nets.isEmpty else { return }
        doc.physical.routes.removeAll { nets.contains($0.netId) }
        applyPlan(&doc)
    }

    private static func applyPlan(_ doc: inout CircuitDocument) {
        for entry in AutoRouter.plan(doc) {
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
