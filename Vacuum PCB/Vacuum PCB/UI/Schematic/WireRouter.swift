import SwiftUI

/// Direction a wire leaves a pin — the axis-aligned "exit" perpendicular to
/// the symbol edge the pin sits on. Drives orthogonal routing so wires stub
/// out of a component cleanly instead of cutting diagonally across its body.
enum ExitDir {
    case up, down, left, right

    /// Snaps a pin's offset-from-symbol-centre to its dominant axis. A pin on
    /// the right edge (offset +x) exits `.right`; a top pin (offset −y, screen
    /// coords) exits `.up`. A centred pin (zero offset) falls back to `.right`.
    static func from(_ offset: CGPoint) -> ExitDir {
        if offset == .zero { return .right }
        if abs(offset.x) >= abs(offset.y) {
            return offset.x >= 0 ? .right : .left
        }
        return offset.y >= 0 ? .down : .up   // +y is down on screen
    }

    /// Exit perpendicular to a symbol edge — used to route mating bus-lines
    /// out of subpart connector sockets.
    init(side: SymbolSide) {
        switch side {
        case .left:   self = .left
        case .right:  self = .right
        case .top:    self = .up
        case .bottom: self = .down
        }
    }

    var vector: CGPoint {
        switch self {
        case .up:    return CGPoint(x: 0, y: -1)
        case .down:  return CGPoint(x: 0, y: 1)
        case .left:  return CGPoint(x: -1, y: 0)
        case .right: return CGPoint(x: 1, y: 0)
        }
    }

    var isHorizontal: Bool { self == .left || self == .right }
}

/// Builds and strokes orthogonal (Manhattan) wires between pins: each wire
/// leaves its pin along the pin's exit direction for a short stub, then
/// bridges to the other pin with the fewest 90° corners (straight when the
/// stubs line up, an L for one turn, a Z for two). Corners are rounded when
/// stroked. Pure geometry — no view/model state — so it unit-tests cleanly
/// and is shared by the renderer (`NetLinesView`) and the right-click
/// hit-test (`SchematicCanvasView`).
enum WireRouter {

    /// Orthogonal polyline from pin `a` (exiting `da`) to pin `b` (exiting
    /// `db`). `db == nil` marks a free end — used for the rubber-band line to
    /// the cursor, which only stubs out of the fixed pin. The returned points
    /// are de-duplicated and collinear-merged, so aligned pins yield a plain
    /// two-point straight line (zero corners).
    static func route(from a: CGPoint, _ da: ExitDir,
                      to b: CGPoint, _ db: ExitDir?,
                      stub: CGFloat = 14,
                      waypoints: [CGPoint] = [],
                      obstacles: [CGRect] = [],
                      laneOffset: CGFloat = 0) -> [CGPoint] {
        let a1 = CGPoint(x: a.x + da.vector.x * stub, y: a.y + da.vector.y * stub)

        // Hand-routed: thread the wire through the user's waypoints. Pins still
        // stub out along their exit; obstacle/lane logic is skipped because the
        // path is explicit.
        if !waypoints.isEmpty {
            var anchors: [CGPoint] = [a1]
            anchors.append(contentsOf: waypoints)
            if let db {
                anchors.append(CGPoint(x: b.x + db.vector.x * stub, y: b.y + db.vector.y * stub))
            }
            var wp: [CGPoint] = [a]
            for next in anchors {
                if let last = wp.last,
                   abs(last.x - next.x) > 0.01, abs(last.y - next.y) > 0.01 {
                    wp.append(CGPoint(x: next.x, y: last.y))   // one orthogonal corner
                }
                wp.append(next)
            }
            wp.append(b)
            return clean(wp)
        }

        var pts: [CGPoint] = [a, a1]

        if let db {
            let b1 = CGPoint(x: b.x + db.vector.x * stub, y: b.y + db.vector.y * stub)
            pts += bridge(a1, da, b1, db, obstacles: obstacles, laneOffset: laneOffset)
            pts.append(b1)
            pts.append(b)
        } else {
            // Free end (cursor): leave the pin outward, then one turn to the
            // target — perpendicular-first when heading straight out would
            // overshoot, so the stub never doubles back through the body.
            if da.isHorizontal {
                pts.append(leavesOutward(da, b.x - a1.x)
                    ? CGPoint(x: b.x, y: a1.y)
                    : CGPoint(x: a1.x, y: b.y))
            } else {
                pts.append(leavesOutward(da, b.y - a1.y)
                    ? CGPoint(x: a1.x, y: b.y)
                    : CGPoint(x: b.x, y: a1.y))
            }
            pts.append(b)
        }
        return clean(pts)
    }

    /// Interior corner points connecting the two stub ends `p` (leaving `dp`)
    /// and `q` (leaving `dq`). The connecting segments always start and finish
    /// on each pin's *outward* side, so a wire never doubles back through the
    /// body it just left — it leaves straight out, then turns. Same-axis exits
    /// route through a perpendicular channel constrained to each pin's outward
    /// side (a centred Z when the pins face, a perpendicular drop when they
    /// don't); mixed exits take the single corner that doesn't cross the body
    /// the wire is leaving.
    private static func bridge(_ p: CGPoint, _ dp: ExitDir,
                               _ q: CGPoint, _ dq: ExitDir,
                               obstacles: [CGRect], laneOffset: CGFloat) -> [CGPoint] {
        switch (dp.isHorizontal, dq.isHorizontal) {
        case (true, true):
            let vx = channel(p.x, dp, q.x, dq,
                             preferred: (p.x + q.x) / 2 + laneOffset,
                             spanMin: min(p.y, q.y), spanMax: max(p.y, q.y),
                             vertical: true, obstacles: obstacles)
            return [CGPoint(x: vx, y: p.y), CGPoint(x: vx, y: q.y)]
        case (false, false):
            let hy = channel(p.y, dp, q.y, dq,
                             preferred: (p.y + q.y) / 2 + laneOffset,
                             spanMin: min(p.x, q.x), spanMax: max(p.x, q.x),
                             vertical: false, obstacles: obstacles)
            return [CGPoint(x: p.x, y: hy), CGPoint(x: q.x, y: hy)]
        case (true, false):
            // p horizontal, q vertical: leave p horizontally toward q when
            // that heads outward, else turn perpendicular (vertical) first.
            let h = CGPoint(x: q.x, y: p.y), v = CGPoint(x: p.x, y: q.y)
            let prefer = leavesOutward(dp, q.x - p.x) ? h : v
            return chooseCorner(p, q, prefer, prefer == h ? v : h, obstacles: obstacles)
        case (false, true):
            // p vertical, q horizontal.
            let v = CGPoint(x: p.x, y: q.y), h = CGPoint(x: q.x, y: p.y)
            let prefer = leavesOutward(dp, q.y - p.y) ? v : h
            return chooseCorner(p, q, prefer, prefer == v ? h : v, obstacles: obstacles)
        }
    }

    /// Perpendicular channel coordinate for a same-axis bridge. Each pin
    /// constrains the channel to its outward side (`.right`/`.down` need it
    /// at-or-beyond their stub; `.left`/`.up` at-or-before). Within that band
    /// it seats at `preferred` (pins' midpoint plus the net's lane offset);
    /// when an obstacle blocks that line it slides to just past the nearest
    /// obstacle edge that's still in-band.
    private static func channel(_ p: CGFloat, _ dp: ExitDir,
                                _ q: CGFloat, _ dq: ExitDir,
                                preferred: CGFloat,
                                spanMin: CGFloat, spanMax: CGFloat,
                                vertical: Bool, obstacles: [CGRect]) -> CGFloat {
        var lo = -CGFloat.greatestFiniteMagnitude
        var hi =  CGFloat.greatestFiniteMagnitude
        for (coord, dir) in [(p, dp), (q, dq)] {
            switch dir {
            case .right, .down: lo = max(lo, coord)
            case .left, .up:    hi = min(hi, coord)
            }
        }
        guard lo <= hi else { return preferred }
        let base = min(max(preferred, lo), hi)
        guard !obstacles.isEmpty else { return base }

        func blocked(_ c: CGFloat) -> Bool {
            for r in obstacles {
                if vertical {
                    if c > r.minX, c < r.maxX, r.minY < spanMax, r.maxY > spanMin { return true }
                } else {
                    if c > r.minY, c < r.maxY, r.minX < spanMax, r.maxX > spanMin { return true }
                }
            }
            return false
        }
        if !blocked(base) { return base }
        let m: CGFloat = 8
        var candidates: [CGFloat] = []
        for r in obstacles {
            if vertical { candidates += [r.minX - m, r.maxX + m] }
            else        { candidates += [r.minY - m, r.maxY + m] }
        }
        let valid = candidates.filter { $0 >= lo && $0 <= hi && !blocked($0) }
        return valid.min(by: { abs($0 - base) < abs($1 - base) }) ?? base
    }

    /// For a single-corner (L) bridge, keeps the preferred corner unless one of
    /// its legs hits an obstacle and the alternate corner is clear.
    private static func chooseCorner(_ p: CGPoint, _ q: CGPoint,
                                     _ preferred: CGPoint, _ alternate: CGPoint,
                                     obstacles: [CGRect]) -> [CGPoint] {
        if !obstacles.isEmpty,
           legHitsObstacle(p, preferred, obstacles) || legHitsObstacle(preferred, q, obstacles),
           !(legHitsObstacle(p, alternate, obstacles) || legHitsObstacle(alternate, q, obstacles)) {
            return [alternate]
        }
        return [preferred]
    }

    /// Axis-aligned segment vs. obstacle-rect overlap test.
    private static func legHitsObstacle(_ a: CGPoint, _ b: CGPoint, _ obstacles: [CGRect]) -> Bool {
        let minX = min(a.x, b.x), maxX = max(a.x, b.x)
        let minY = min(a.y, b.y), maxY = max(a.y, b.y)
        for r in obstacles where r.minX < maxX && r.maxX > minX && r.minY < maxY && r.maxY > minY {
            return true
        }
        return false
    }

    /// Whether moving by `delta` along `dir`'s axis goes in `dir`'s outward
    /// sense (so a wire leaving the pin that way heads away from the body).
    private static func leavesOutward(_ dir: ExitDir, _ delta: CGFloat) -> Bool {
        switch dir {
        case .right, .down: return delta > 0
        case .left, .up:    return delta < 0
        }
    }

    /// Drops consecutive duplicates and collinear midpoints so a path that
    /// folds flat (e.g. perfectly aligned pins) renders as one clean segment.
    static func clean(_ pts: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in pts {
            if let last = out.last, approxEqual(last, p) { continue }
            out.append(p)
        }
        guard out.count > 2 else { return out }
        var merged: [CGPoint] = [out[0]]
        for i in 1..<(out.count - 1) {
            if !collinear(merged.last!, out[i], out[i + 1]) {
                merged.append(out[i])
            }
        }
        merged.append(out[out.count - 1])
        return merged
    }

    /// Rounds each interior corner of the polyline with `radius`, clamped to
    /// half the shorter adjoining leg so the arc never overshoots its segment.
    static func roundedPath(_ pts: [CGPoint], radius: CGFloat) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count >= 3 else {
            for p in pts.dropFirst() { path.addLine(to: p) }
            return path
        }
        for i in 1..<(pts.count - 1) {
            let prev = pts[i - 1], cur = pts[i], next = pts[i + 1]
            let r = min(radius, dist(prev, cur) / 2, dist(cur, next) / 2)
            path.addArc(tangent1End: cur, tangent2End: next, radius: r)
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    /// Shortest distance from `p` to the polyline (min over its segments).
    /// Used by the right-click "remove pin" hit-test.
    static func distance(from p: CGPoint, to polyline: [CGPoint]) -> CGFloat {
        guard polyline.count >= 2 else {
            return polyline.first.map { dist(p, $0) } ?? .greatestFiniteMagnitude
        }
        var best = CGFloat.greatestFiniteMagnitude
        for i in 0..<(polyline.count - 1) {
            best = min(best, distanceToSegment(p, polyline[i], polyline[i + 1]))
        }
        return best
    }

    /// Nearest point on the polyline to `p`, plus its arc-length from the
    /// start. Used to drop a new waypoint onto a wire and order it among any
    /// existing waypoints along the path.
    static func projection(of p: CGPoint, onto polyline: [CGPoint]) -> (point: CGPoint, arclength: CGFloat) {
        guard polyline.count >= 2 else { return (polyline.first ?? p, 0) }
        var best = (point: polyline[0], arclength: CGFloat(0), dist: CGFloat.greatestFiniteMagnitude)
        var acc: CGFloat = 0
        for i in 0..<(polyline.count - 1) {
            let a = polyline[i], b = polyline[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let segLen = (dx * dx + dy * dy).squareRoot()
            let t = segLen > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (segLen * segLen))) : 0
            let proj = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
            let d = hypot(p.x - proj.x, p.y - proj.y)
            if d < best.dist { best = (proj, acc + t * segLen, d) }
            acc += segLen
        }
        return (best.point, best.arclength)
    }

    // MARK: - Geometry helpers

    private static func approxEqual(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01
    }

    private static func collinear(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
        let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        return abs(cross) < 0.01
    }

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return dist(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        return dist(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}
