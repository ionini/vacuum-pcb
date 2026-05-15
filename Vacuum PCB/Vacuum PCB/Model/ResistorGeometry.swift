import Foundation

/// Shared geometry of the channel inside a resistor footprint.
///
/// Used by both the CAD pipeline (which sweeps a 0.5 mm bore along these
/// waypoints) and the physical-canvas placement glyph (which strokes them for
/// the visual preview). Keeping one source of truth means the body the user
/// sees on the board matches the channel they're about to print.
enum ResistorGeometry {
    /// How many vertical jumps the polyline makes between +y and −y plateaus
    /// inside the footprint. S = 0 (a straight wire), denser values give more
    /// flow restriction.
    static func transitions(for size: ResistorSize) -> Int {
        switch size {
        case .small:  return 0
        case .medium: return 3
        case .large:  return 10
        }
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
        let pin2 = Point(x:  halfLen, y: 0)
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
}
