import Foundation
import Euclid

/// Mechanical-fastener constants and cutter geometry for `.screw`
/// placements. Dimensions are hardcoded for one M2-class fastener profile —
/// promote to `ManufacturingConstants` if/when designs need multiple sizes
/// in one document.
enum ScrewGeometry {
    /// Countersink head cavity carved into the top plate from the top face
    /// downward. Sized for a flanged M2 head sitting flush with the board.
    static let headDiameter: Double = 5.1
    static let headDepth: Double = 2.7
    /// Clearance bore through both plates (and through the silicone, which
    /// the user punches at assembly). Sized so an M2 shaft slips through.
    static let throughDiameter: Double = 2.2
    /// Hex-nut pocket carved into the bottom plate from the bottom face
    /// upward. The pocket is sized by parallel-face distance (across flats);
    /// the inscribed circle radius is `acrossFlats / 2`, the circumscribed
    /// circle radius is `acrossFlats / sqrt(3)`.
    static let hexAcrossFlats: Double = 4.1
    static let hexDepth: Double = 1.7

    /// Builds the three cutters one screw contributes, partitioned by which
    /// plate they should be subtracted from:
    ///   * countersink → top plate only
    ///   * through-hole → both plates (returned in both arrays)
    ///   * hex pocket  → bottom plate only
    /// The hex prism rotates with the placement's rotation so users can line
    /// nuts up with their assembly's hex driver direction.
    static func cutters(
        at p: Point, rotation: Rotation,
        topInnerZ: Double, topThickness: Double,
        bottomInnerZ: Double, bottomThickness: Double
    ) -> (top: [Mesh], bottom: [Mesh]) {
        // Slight overshoot so the cutter doesn't sit exactly coplanar with
        // the plate face — Euclid's BSP CSG occasionally drops a face on
        // coplanar boundaries.
        let eps = 0.05
        let topFace = topInnerZ + topThickness
        let bottomFace = bottomInnerZ - bottomThickness

        let countersink = verticalCylinder(
            radius: headDiameter / 2,
            zLo: topFace - headDepth - eps,
            zHi: topFace + eps,
            slices: 24
        ).translated(by: Vector(p.x, p.y, 0))

        let through = verticalCylinder(
            radius: throughDiameter / 2,
            zLo: bottomFace - eps,
            zHi: topFace + eps,
            slices: 16
        ).translated(by: Vector(p.x, p.y, 0))

        let hexPrism = hexPrism(
            acrossFlats: hexAcrossFlats,
            zLo: bottomFace - eps,
            zHi: bottomFace + hexDepth + eps,
            rotation: rotation.radians,
            at: p
        )

        return (
            top:    [countersink, through],
            bottom: [through, hexPrism]
        )
    }

    /// Vertical cylinder centred on the Z axis, then caller translates to XY.
    /// Matches the pattern in `PlateBuilder` (Mesh.cylinder is Y-aligned by
    /// default, pitch by halfPi rotates it onto Z).
    private static func verticalCylinder(
        radius: Double, zLo: Double, zHi: Double, slices: Int
    ) -> Mesh {
        let len = zHi - zLo
        let cz = (zLo + zHi) / 2
        return Mesh.cylinder(radius: radius, height: len, slices: slices)
            .rotated(by: Euclid.Rotation.pitch(.halfPi))
            .translated(by: Vector(0, 0, cz))
    }

    /// Six-sided prism with parallel-face spacing `acrossFlats`, extruded
    /// between `zLo` and `zHi`. Built as two end caps + six side quads —
    /// avoids reaching for `Mesh.extrude` whose path-coercion rules differ
    /// across Euclid versions.
    private static func hexPrism(
        acrossFlats: Double,
        zLo: Double, zHi: Double,
        rotation: Double,
        at p: Point
    ) -> Mesh {
        // Hexagon with parallel-face distance `acrossFlats` has apothem
        // half that, and circumradius apothem / cos(30°) = acrossFlats / √3.
        let circumradius: Double = acrossFlats / sqrt(3.0)
        let sides: Int = 6
        // Start at 30° so two flats are perpendicular to the X axis at
        // rotation=0 — matches the orientation a hex driver would attack.
        let startAngle: Double = Double.pi / 6
        var bottomVerts: [Vector] = []
        var topVerts: [Vector] = []
        for i in 0..<sides {
            let step: Double = Double(i) * 2.0 * Double.pi / Double(sides)
            let a: Double = startAngle + step + rotation
            let x: Double = p.x + circumradius * cos(a)
            let y: Double = p.y + circumradius * sin(a)
            bottomVerts.append(Vector(x, y, zLo))
            topVerts.append(Vector(x, y, zHi))
        }
        var polygons: [Polygon] = []
        // Bottom cap: outward normal points -Z, so winding is reversed.
        let bottomVertices = bottomVerts.reversed().map { Vertex($0) }
        if let bottom = Polygon(bottomVertices) {
            polygons.append(bottom)
        }
        let topVertices = topVerts.map { Vertex($0) }
        if let top = Polygon(topVertices) {
            polygons.append(top)
        }
        // Side faces: each pair of adjacent vertices forms a quad.
        for i in 0..<sides {
            let j = (i + 1) % sides
            let quad: [Vertex] = [
                Vertex(bottomVerts[i]),
                Vertex(bottomVerts[j]),
                Vertex(topVerts[j]),
                Vertex(topVerts[i]),
            ]
            if let q = Polygon(quad) {
                polygons.append(q)
            }
        }
        return Mesh(polygons)
    }
}
