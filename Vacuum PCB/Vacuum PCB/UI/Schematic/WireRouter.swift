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
                      stub: CGFloat = 14) -> [CGPoint] {
        let a1 = CGPoint(x: a.x + da.vector.x * stub, y: a.y + da.vector.y * stub)

        var pts: [CGPoint] = [a, a1]

        if let db {
            let b1 = CGPoint(x: b.x + db.vector.x * stub, y: b.y + db.vector.y * stub)
            pts += bridge(a1, da, b1, db)
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
                               _ q: CGPoint, _ dq: ExitDir) -> [CGPoint] {
        switch (dp.isHorizontal, dq.isHorizontal) {
        case (true, true):
            let vx = channel(p.x, dp, q.x, dq, fallback: (p.x + q.x) / 2)
            return [CGPoint(x: vx, y: p.y), CGPoint(x: vx, y: q.y)]
        case (false, false):
            let hy = channel(p.y, dp, q.y, dq, fallback: (p.y + q.y) / 2)
            return [CGPoint(x: p.x, y: hy), CGPoint(x: q.x, y: hy)]
        case (true, false):
            // p horizontal, q vertical: leave p horizontally toward q when
            // that heads outward, else turn perpendicular (vertical) first.
            return leavesOutward(dp, q.x - p.x)
                ? [CGPoint(x: q.x, y: p.y)]
                : [CGPoint(x: p.x, y: q.y)]
        case (false, true):
            // p vertical, q horizontal.
            return leavesOutward(dp, q.y - p.y)
                ? [CGPoint(x: p.x, y: q.y)]
                : [CGPoint(x: q.x, y: p.y)]
        }
    }

    /// Perpendicular channel coordinate for a same-axis bridge. Each pin
    /// constrains the channel to its outward side (`.right`/`.down` need it
    /// at-or-beyond their stub; `.left`/`.up` at-or-before). A feasible band
    /// seats the channel at the pins' midpoint clamped into it (a centred Z);
    /// conflicting constraints fall back to the midpoint.
    private static func channel(_ p: CGFloat, _ dp: ExitDir,
                                _ q: CGFloat, _ dq: ExitDir,
                                fallback: CGFloat) -> CGFloat {
        var lo = -CGFloat.greatestFiniteMagnitude
        var hi =  CGFloat.greatestFiniteMagnitude
        for (coord, dir) in [(p, dp), (q, dq)] {
            switch dir {
            case .right, .down: lo = max(lo, coord)
            case .left, .up:    hi = min(hi, coord)
            }
        }
        guard lo <= hi else { return fallback }
        return min(max(fallback, lo), hi)
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
