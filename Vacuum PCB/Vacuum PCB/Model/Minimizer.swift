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
                timeBudget: 1.0,
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

        // ── Phase 1: placement search on the proxy cost (no routing) ──────────
        var rng = SplitMix64(seed: options.seed)
        var working = input
        var currentCost = cost(of: working)
        var best = working
        var bestCost = currentCost

        let maxIter = max(1, options.maxIterations)
        let t0 = max(currentCost * 0.05, 1e-6)
        let tMin = max(currentCost * 1e-4, 1e-9)
        let alpha = pow(tMin / t0, 1.0 / Double(maxIter))
        var temperature = t0
        let deadline = Date().addingTimeInterval(options.timeBudget)

        var iter = 0
        while iter < maxIter {
            defer { iter += 1; temperature *= alpha }
            if iter & 0x3F == 0, Date() >= deadline { break }
            stats.iterations += 1
            let progress = Double(iter) / Double(maxIter)

            var trial = working
            guard applyRandomMove(to: &trial, pitch: pitch, progress: progress, rng: &rng) else { continue }
            let trialCost = cost(of: trial)
            let dE = trialCost - currentCost
            if dE < 0 || Double.random(in: 0..<1, using: &rng) < exp(-dE / max(temperature, 1e-12)) {
                working = trial
                currentCost = trialCost
                stats.accepted += 1
                if trialCost < bestCost { best = trial; bestCost = trialCost }
            } else {
                stats.rejected += 1
            }
        }

        // ── Phase 2: realise & validate ──────────────────────────────────────
        var candidate = best
        // Re-route only the nets whose pins actually moved; nets the search
        // didn't touch keep their original (hand-drawn) routing. Re-routing the
        // whole board from scratch would discard good hand-routing the greedy
        // single-pass router can't reproduce on a congested design.
        reroute(&candidate, nets: movedNets(from: input, to: candidate))
        if blockingIssueCount(candidate) <= baseline {
            candidate = shrinkFit(candidate, baseline: baseline, pitch: pitch, margin: options.margin)
        }

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

    // MARK: - Moves

    /// Applies one random perturbation to `doc`. Returns false when no move
    /// could be formed (no eligible component). No routing happens here — the
    /// move is scored by the proxy cost only.
    private static func applyRandomMove(
        to doc: inout CircuitDocument, pitch: Double, progress: Double, rng: inout SplitMix64
    ) -> Bool {
        var freeIdx: [Int] = []
        var edgeIdx: [Int] = []     // edge features + connectors: slide along an edge
        for (i, p) in doc.physical.placements.enumerated() {
            guard let kind = doc.logic.components.first(where: { $0.id == p.componentId })?.kind
            else { continue }
            if kind == .connector, p.edgeAnchor != nil { edgeIdx.append(i) }
            else if edgeFeatureKinds.contains(kind) { edgeIdx.append(i) }
            else { freeIdx.append(i) }
        }
        guard !freeIdx.isEmpty || !edgeIdx.isEmpty else { return false }

        // Pick an edge feature ~1 in 5 when both kinds exist (most of the work
        // is interior compaction), or always when there are no free bodies.
        let pickEdge = !edgeIdx.isEmpty && (freeIdx.isEmpty || Int.random(in: 0..<5, using: &rng) == 0)
        if pickEdge {
            return slideAlongEdge(&doc, index: edgeIdx.randomElement(using: &rng)!,
                                  pitch: pitch, progress: progress, rng: &rng)
        }

        let i = freeIdx.randomElement(using: &rng)!
        switch Int.random(in: 0..<100, using: &rng) {
        case 0..<70:
            translate(&doc, index: i, pitch: pitch, progress: progress, rng: &rng)
        case 70..<85 where freeIdx.count >= 2:
            var j = freeIdx.randomElement(using: &rng)!
            while j == i { j = freeIdx.randomElement(using: &rng)! }
            swap(&doc, i: i, j: j, pitch: pitch)
        default:
            rotate(&doc, index: i, pitch: pitch)
        }
        return true
    }

    private static func translate(
        _ doc: inout CircuitDocument, index: Int, pitch: Double, progress: Double, rng: inout SplitMix64
    ) {
        guard let info = footprintInfo(doc, index) else { return }
        let ext = rotatedExtents(info.fp.boundingRect, doc.physical.placements[index].rotation)
        let span = max(doc.physical.boardOutline.size.width, doc.physical.boardOutline.size.height)
        let baseCells = min(12, max(1, Int((span / pitch / 8).rounded())))
        let cells = max(1, Int((Double(baseCells) * (1.0 - 0.85 * progress)).rounded()))
        var dx = Double(Int.random(in: -cells...cells, using: &rng)) * pitch
        let dy = Double(Int.random(in: -cells...cells, using: &rng)) * pitch
        if dx == 0, dy == 0 { dx = Bool.random(using: &rng) ? pitch : -pitch }
        let p = doc.physical.placements[index].position
        doc.physical.placements[index].position = clampInside(
            Point(x: p.x + dx, y: p.y + dy), ext: ext, outline: doc.physical.boardOutline, pitch: pitch)
    }

    private static func rotate(_ doc: inout CircuitDocument, index: Int, pitch: Double) {
        guard let info = footprintInfo(doc, index) else { return }
        let next: Rotation
        switch doc.physical.placements[index].rotation {
        case .r0:   next = .r90
        case .r90:  next = .r180
        case .r180: next = .r270
        case .r270: next = .r0
        }
        doc.physical.placements[index].rotation = next
        let ext = rotatedExtents(info.fp.boundingRect, next)
        doc.physical.placements[index].position = clampInside(
            doc.physical.placements[index].position, ext: ext, outline: doc.physical.boardOutline, pitch: pitch)
    }

    private static func swap(_ doc: inout CircuitDocument, i: Int, j: Int, pitch: Double) {
        let pi = doc.physical.placements[i].position
        let pj = doc.physical.placements[j].position
        doc.physical.placements[i].position = pj
        doc.physical.placements[j].position = pi
        for idx in [i, j] {
            if let info = footprintInfo(doc, idx) {
                let ext = rotatedExtents(info.fp.boundingRect, doc.physical.placements[idx].rotation)
                doc.physical.placements[idx].position = clampInside(
                    doc.physical.placements[idx].position, ext: ext,
                    outline: doc.physical.boardOutline, pitch: pitch)
            }
        }
    }

    /// Slides an edge feature (or a connector) along a board edge, never
    /// inward. Connectors keep their assigned `edgeAnchor.edge`; bare edge
    /// features (vent / vacuum / port) ride whichever edge they're nearest and
    /// have their bore rotated to point outward along it.
    private static func slideAlongEdge(
        _ doc: inout CircuitDocument, index: Int, pitch: Double, progress: Double, rng: inout SplitMix64
    ) -> Bool {
        guard let info = footprintInfo(doc, index) else { return false }
        let outline = doc.physical.boardOutline
        let comp = info.comp

        let edge: Edge
        let clearance: Double
        if comp.kind == .connector, let anchor = doc.physical.placements[index].edgeAnchor {
            edge = anchor.edge
            clearance = info.fp.exclusionRect.size.height / 2
        } else {
            edge = nearestEdge(to: doc.physical.placements[index].position, in: outline)
            clearance = max(info.fp.boundingRect.size.width, info.fp.boundingRect.size.height) / 2
        }

        let len = edgeLength(edge, in: outline)
        guard len - clearance > clearance else { return true }   // edge too short to slide
        let current = offsetAlongEdge(doc.physical.placements[index].position, edge: edge, outline: outline)
        let baseCells = min(10, max(1, Int((len / pitch / 6).rounded())))
        let cells = max(1, Int((Double(baseCells) * (1.0 - 0.85 * progress)).rounded()))
        var delta = Double(Int.random(in: -cells...cells, using: &rng)) * pitch
        if delta == 0 { delta = Bool.random(using: &rng) ? pitch : -pitch }
        var off = ((current + delta) / pitch).rounded() * pitch
        off = max(clearance, min(len - clearance, off))

        let inset = comp.kind == .connector ? 0 : edgeInset(info.fp)
        placeOnEdge(&doc.physical.placements[index], edge: edge, offset: off, inset: inset,
                    isConnector: comp.kind == .connector, outline: outline)
        return true
    }

    // MARK: - Re-routing & validity

    /// Nets with at least one pin whose pose changed between `a` and `b` — the
    /// ones whose routing must be regenerated. Everything else keeps its
    /// original routing.
    private static func movedNets(from a: CircuitDocument, to b: CircuitDocument) -> Set<UUID> {
        let eps = 0.01
        var movedComponents: Set<UUID> = []
        for placement in b.physical.placements {
            guard let before = a.physical.placements.first(where: { $0.componentId == placement.componentId })
            else { movedComponents.insert(placement.componentId); continue }
            if abs(before.position.x - placement.position.x) > eps
                || abs(before.position.y - placement.position.y) > eps
                || before.rotation != placement.rotation
                || before.layer != placement.layer
                || before.depth != placement.depth {
                movedComponents.insert(placement.componentId)
            }
        }
        var nets: Set<UUID> = []
        for net in b.logic.nets where net.pins.contains(where: { movedComponents.contains($0.componentId) }) {
            nets.insert(net.id)
        }
        return nets
    }

    /// Re-plans only the given nets (the ones whose pins moved), leaving other
    /// routing intact. Used in phase 2 and by the shrink-fit's edge re-anchor.
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

/// Deterministic, seedable PRNG (SplitMix64), so a board minimises identically
/// on every run — reproducible for debugging and tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
