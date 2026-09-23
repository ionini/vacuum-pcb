import Foundation

/// Shared geometry of the channel inside a resistor footprint.
///
/// Used by both the CAD pipeline (which sweeps a `resistorChannelDiameter`
/// bore along these waypoints) and the physical-canvas placement glyph (which
/// strokes them for the visual preview). Keeping one source of truth means the
/// body the user sees on the board matches the channel they're about to print.
///
/// Two path styles exist, selected by `ManufacturingConstants.smoothResistors`:
///
/// * **Legacy zigzag** (`path`): a square wave — horizontal plateaus at ±y
///   joined by vertical jumps. Dense sizes leave walls between neighbouring
///   bore surfaces far below what a 0.2 mm nozzle can print (L at defaults:
///   0.909 mm pitch − 0.6 mm bore = 0.31 mm, a single fragile extrusion), and
///   every jump is two 90° corners where the nozzle reverses right at those
///   walls. Both smear plastic into the bore — the printed-resistor clogs of
///   2026-08-26.
/// * **Smooth meander** (`smoothPath`): parallel vertical legs joined by
///   tangent arcs (quarter arcs + plateaus, collapsing to semicircular
///   U-turns at max density). No corners anywhere, and the leg pitch is
///   chosen so every printed wall between neighbouring bore surfaces is at
///   least the requested `minWall`.
enum ResistorGeometry {
    /// How many vertical jumps the legacy polyline makes between +y and −y
    /// plateaus inside the footprint. S = 0 (a straight wire), denser values
    /// give more flow restriction.
    static func transitions(for size: ResistorSize) -> Int {
        switch size {
        case .small:      return 0
        case .medium:     return 3
        case .large:      return 10
        case .extraLarge: return 15
        }
    }

    /// The resistor channel polyline for `size` under the document's
    /// manufacturing constants — the one entry point every consumer (CAD
    /// sweep, simulation length, router obstacle stamping, canvas glyphs)
    /// should use, so they all agree on the same shape.
    static func waypoints(for size: ResistorSize, m: ManufacturingConstants) -> [Point] {
        let halfLen = ManufacturingConstants.resistorFootprintLength / 2
        let halfWid = ManufacturingConstants.resistorFootprintWidth / 2
        guard m.smoothResistors else {
            return path(transitions: transitions(for: size),
                        halfLen: halfLen, halfWid: halfWid)
        }
        // The wall floor is 0.5 mm — two clean 0.2 mm-nozzle perimeters —
        // even if the user relaxes the DRC bar below that: walls thinner than
        // this are what clogged the zigzag in the first place.
        return smoothPath(size: size,
                          bore: m.resistorChannelDiameter,
                          minWall: max(0.5, m.minWallThickness),
                          halfLen: halfLen, halfWid: halfWid)
    }

    /// Polyline in component-local coordinates: pin1 at (−halfLen, 0), pin2 at
    /// (+halfLen, 0). For non-zero `transitions`, a short horizontal **lead**
    /// on the y = 0 axis pads both ends so the bore enters and exits along
    /// the resistor's main axis before turning, matching the look of a
    /// schematic resistor symbol and keeping the joining transport channels
    /// co-linear with the resistor.
    static func path(
        transitions: Int,
        halfLen: Double,
        halfWid: Double,
        lead: Double = 1.0
    ) -> [Point] {
        let pin1 = Point(x: -halfLen, y: 0)
        let pin2 = Point(x: halfLen, y: 0)
        if transitions <= 0 {
            return [pin1, pin2]
        }
        // Cap the lead so it never eats more than 40% of each half-length,
        // even for tiny footprints.
        let l = min(max(0, lead), halfLen * 0.4)
        let plateauY = halfWid * 0.5
        let zigzagStartX = -halfLen + l
        let zigzagEndX   =  halfLen - l

        var pts: [Point] = []
        pts.append(pin1)
        // Straight lead-in along the centerline.
        pts.append(Point(x: zigzagStartX, y: 0))
        // Lift to the first plateau.
        var currentY = plateauY
        pts.append(Point(x: zigzagStartX, y: currentY))
        // Walls (vertical jumps) evenly spaced inside the zigzag region.
        let spacing = (zigzagEndX - zigzagStartX) / Double(transitions + 1)
        for i in 0..<transitions {
            let x = zigzagStartX + Double(i + 1) * spacing
            pts.append(Point(x: x, y: currentY))
            currentY = -currentY
            pts.append(Point(x: x, y: currentY))
        }
        // Run out at the last plateau, drop to baseline, then straight lead
        // out to pin2.
        pts.append(Point(x: zigzagEndX, y: currentY))
        pts.append(Point(x: zigzagEndX, y: 0))
        pts.append(pin2)
        return pts
    }

    // MARK: - Smooth meander

    /// Print-friendly serpentine. Vertical legs on a uniform pitch, joined by
    /// tangent arcs; enters and exits along y = 0 like the legacy path so the
    /// joining transport channels stay co-linear with the pins.
    ///
    /// Guarantees, at any bore the document sets:
    /// * every wall between neighbouring bore surfaces ≥ `minWall`
    ///   (pitch = region/n with n capped at `region / (bore + minWall)`);
    /// * no polyline corner tighter than the turn radius
    ///   `min(pitch, amplitude)/2` — the nozzle never has to reverse;
    /// * the bore edge stays ≥ 0.35 mm inside the footprint's long sides, so
    ///   two resistors placed footprint-to-footprint keep a ≥ 0.7 mm wall.
    ///
    /// Within those constraints the leg count is chosen so the total channel
    /// length — which *is* the simulated resistance — lands as close as
    /// possible to the legacy zigzag's length for the same size. At defaults
    /// (0.6 mm bore) that is ~31 mm for L against the zigzag's 34 mm; XL
    /// cannot reach its legacy 44 mm printably and packs the same maximum
    /// density as L.
    static func smoothPath(
        size: ResistorSize,
        bore: Double,
        minWall: Double,
        halfLen: Double,
        halfWid: Double,
        lead: Double = 1.0
    ) -> [Point] {
        let pin1 = Point(x: -halfLen, y: 0)
        let pin2 = Point(x: halfLen, y: 0)
        let straight = [pin1, pin2]
        guard size != .small else { return straight }

        let l = min(max(0, lead), halfLen * 0.4)
        let xL = -halfLen + l
        let xR = halfLen - l
        let region = xR - xL
        // Bore edge stays this far inside the footprint's ±halfWid sides.
        let edgeMargin = 0.35
        let amplitude = halfWid - edgeMargin - bore / 2
        let maxLegs = Int((region / max(0.01, bore + minWall)).rounded(.down))
        guard maxLegs >= 2, amplitude > max(0.2, bore / 2) else { return straight }

        // Pick the leg count whose length lands closest to the legacy zigzag
        // length for this size — that keeps documents that flip the toggle as
        // close as the wall guarantee allows to the resistance they simulated.
        let target = length(of: path(transitions: transitions(for: size),
                                     halfLen: halfLen, halfWid: halfWid, lead: lead))
        var best = straight
        var bestError = abs(length(of: straight) - target)
        for legs in 2...maxLegs {
            let candidate = comb(legs: legs, amplitude: amplitude,
                                 xL: xL, xR: xR, halfLen: halfLen)
            let error = abs(length(of: candidate) - target)
            if error < bestError {
                best = candidate
                bestError = error
            }
        }
        return best
    }

    /// Polyline length in mm — the quantity the simulation converts into
    /// resistance (`resistorResistancePerMm`).
    static func length(of pts: [Point]) -> Double {
        guard pts.count >= 2 else { return 0 }
        var total = 0.0
        for i in 0..<(pts.count - 1) {
            let dx = pts[i + 1].x - pts[i].x
            let dy = pts[i + 1].y - pts[i].y
            total += (dx * dx + dy * dy).squareRoot()
        }
        return total
    }

    /// The comb itself: `legs` vertical runs on pitch `region/legs`, joined by
    /// quarter arcs + apex plateaus (a plateau of zero width = a semicircular
    /// U-turn). Leg 0 runs upward; entry/exit quarter arcs meet y = 0 tangent
    /// to the leads.
    private static func comb(
        legs n: Int, amplitude: Double, xL: Double, xR: Double, halfLen: Double
    ) -> [Point] {
        let pitch = (xR - xL) / Double(n)
        let rt = min(pitch / 2, amplitude / 2)
        // Center the comb (legs + entry/exit arcs) inside the region.
        let span = Double(n - 1) * pitch + 2 * rt
        let x0 = xL + rt + (xR - xL - span) / 2
        let legX = { (i: Int) in x0 + Double(i) * pitch }
        let legTopY = amplitude - rt
        let eps = 1e-9

        var pts: [Point] = [Point(x: -halfLen, y: 0)]
        func add(_ x: Double, _ y: Double) {
            let p = Point(x: x, y: y)
            if let last = pts.last, abs(last.x - p.x) < eps, abs(last.y - p.y) < eps { return }
            pts.append(p)
        }
        /// Appends chords of the arc around `center`, from `from` to `to`
        /// (radians, signed sweep, start point assumed already appended).
        /// ≤45° per chord keeps the sagitta ≤ 0.08·rt — well under print
        /// resolution, and chords only ever err toward *thicker* walls.
        func arc(_ cx: Double, _ cy: Double, from: Double, to: Double) {
            let sweep = to - from
            let steps = max(1, Int(ceil(abs(sweep) / (Double.pi / 4))))
            for i in 1...steps {
                let a = from + sweep * Double(i) / Double(steps)
                add(cx + rt * cos(a), cy + rt * sin(a))
            }
        }

        // Lead in, then quarter arc up into leg 0.
        add(x0 - rt, 0)
        arc(x0 - rt, rt, from: -.pi / 2, to: 0)

        for i in 0..<n {
            let up = i % 2 == 0
            let x = legX(i)
            if i == n - 1 {
                // Last leg: run to the exit handoff at |y| = rt, then quarter
                // arc onto the centerline heading for pin 2.
                if up {
                    add(x, -rt)
                    arc(x + rt, -rt, from: .pi, to: .pi / 2)
                } else {
                    add(x, rt)
                    arc(x + rt, rt, from: .pi, to: 3 * .pi / 2)
                }
            } else {
                // Full leg, then the turn onto the next leg: quarter arc to
                // the apex, plateau (zero-width at max density), quarter arc
                // down the other side.
                let nextX = legX(i + 1)
                if up {
                    add(x, legTopY)
                    arc(x + rt, legTopY, from: .pi, to: .pi / 2)
                    add(nextX - rt, amplitude)
                    arc(nextX - rt, legTopY, from: .pi / 2, to: 0)
                } else {
                    add(x, -legTopY)
                    arc(x + rt, -legTopY, from: .pi, to: 3 * .pi / 2)
                    add(nextX - rt, -amplitude)
                    arc(nextX - rt, -legTopY, from: -.pi / 2, to: 0)
                }
            }
        }
        add(halfLen, 0)
        return pts
    }
}
