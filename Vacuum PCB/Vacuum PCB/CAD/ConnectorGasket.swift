import Foundation

/// Pure XY math for a `.bottomExtend` connector's silicone gasket — the
/// stadium-shaped strip of silicone the clamp screws crush around the pin
/// tubes — and the per-connector stencil that cuts it.
///
/// The connector's silicone is deliberately NOT part of the board sheet's
/// stencil: a mated connector works as a *crushed gasket*, so its silicone
/// wants a compact band concentric to the pin/screw row (all the screw force
/// lands on the sealing band, none is wasted flattening sheet-sized slab),
/// wider hole relief than the board sheet (crushing makes the silicone flow
/// inward and close the holes), and generous screw clearance (silicone
/// squeezed onto the screw threads carries the clamp load instead of the
/// nut). One casting frame still pours everything at once — the board sheet's
/// stencil and these per-connector stencils then cut the pieces apart.
///
/// One source of truth: `PlateBuilder` (the gasket stencil mesh), `DRC` (the
/// stencil tear check), and tests all read this layout.
enum ConnectorGasket {

    struct Layout {
        /// World-space bounding rect of the gasket capsule. Together with
        /// `cornerRadius` (half the capsule's short side) this renders as a
        /// stadium concentric to the connector's pin/screw row.
        var outline: Rect
        /// The capsule's end radius — `capsuleRadius(m)`, also exactly half
        /// the outline's short dimension.
        var cornerRadius: Double
        /// Pin (tube) holes: world centre + cut diameter (`pinHoleDiameter`).
        var pinHoles: [(position: Point, diameter: Double)]
        /// End-cap screw clearance holes: world centre + cut diameter
        /// (`screwHoleDiameter`).
        var screwHoles: [(position: Point, diameter: Double)]

        /// Every hole the gasket stencil cuts, pins first.
        var holes: [(position: Point, diameter: Double)] { pinHoles + screwHoles }
    }

    /// Diameter of a pin (tube) hole in the gasket.
    static func pinHoleDiameter(_ m: ManufacturingConstants) -> Double {
        m.channelDiameter + m.connectorGasketViaPadding
    }

    /// Diameter of an end-cap screw clearance hole in the gasket.
    static func screwHoleDiameter(_ m: ManufacturingConstants) -> Double {
        m.screwThroughDiameter + m.connectorGasketScrewPadding
    }

    /// Radial extent of the gasket around each hole centre on the row: the
    /// (padded) pin hole radius plus the gasket band width.
    static func capsuleRadius(_ m: ManufacturingConstants) -> Double {
        pinHoleDiameter(m) / 2 + m.connectorGasketWidth
    }

    /// Gasket layout for one connector, given the world-space centres of its
    /// pin tubes and end-cap screws (both on the connector's row line —
    /// axis-aligned, since placements rotate in quarter turns). The capsule is
    /// the bounding box of every centre inflated by `capsuleRadius`, so it
    /// spans the full row — screws included, they're what crush it — and stays
    /// concentric to the holes. Returns nil when there are no centres.
    static func layout(
        pinCentres: [Point], screwCentres: [Point], m: ManufacturingConstants
    ) -> Layout? {
        let centres = pinCentres + screwCentres
        guard let first = centres.first else { return nil }
        let r = capsuleRadius(m)
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for c in centres.dropFirst() {
            minX = min(minX, c.x); maxX = max(maxX, c.x)
            minY = min(minY, c.y); maxY = max(maxY, c.y)
        }
        let outline = Rect(
            origin: Point(x: minX - r, y: minY - r),
            size: Size(width: maxX - minX + 2 * r, height: maxY - minY + 2 * r)
        )
        let pinDiameter = pinHoleDiameter(m)
        let screwDiameter = screwHoleDiameter(m)
        return Layout(
            outline: outline,
            cornerRadius: r,
            pinHoles: pinCentres.map { ($0, pinDiameter) },
            screwHoles: screwCentres.map { ($0, screwDiameter) }
        )
    }
}
