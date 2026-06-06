import Foundation
import Euclid

/// Mechanical-fastener constants and CSG geometry for `.screw` placements.
/// Dimensions are hardcoded for one M2-class fastener profile — promote to
/// `ManufacturingConstants` if/when designs need multiple sizes in one
/// document.
enum ScrewGeometry {
    /// Countersink head cavity carved into the top plate from the top face
    /// downward. Sized for a flanged M2 head sitting flush with the board.
    /// Depth is per-document (`ManufacturingConstants.screwHeadDepth`).
    static let headDiameter: Double = 5.1
    /// Clearance bore through both plates (and through the silicone, which
    /// the user punches at assembly). Sized so an M2 shaft slips through.
    static let throughDiameter: Double = 2.2
    /// Hex-nut pocket carved into the bottom plate from the bottom face
    /// upward. The pocket is sized by parallel-face distance (across flats);
    /// the inscribed circle radius is `acrossFlats / 2`, the circumscribed
    /// circle radius is `acrossFlats / sqrt(3)`. Depth is per-document
    /// (`ManufacturingConstants.screwNutDepth`).
    static let hexAcrossFlats: Double = 4.1

    /// Lateral print-material thickness at the volcano's top (the crater
    /// rim). Sets the radius of the flat plateau; the base radius comes
    /// from `ManufacturingConstants.screwDomeBaseDiameter` so the sides
    /// taper inward Mt-Fuji-style as the volcano rises. Must stay
    /// strictly positive so the cavity cylinder leaves a visible rim.
    static let domeRimMargin: Double = 0.75

    struct CSG {
        var topCutters: [Mesh] = []
        var bottomCutters: [Mesh] = []
        /// Volcano domes to UNION with the plate before the cutters are
        /// subtracted, so the protruding head / nut still sits inside
        /// printed material on the sides.
        var topAdditions: [Mesh] = []
        var bottomAdditions: [Mesh] = []
    }

    /// Builds the cutters and dome additions one screw contributes,
    /// partitioned by plate.
    ///
    /// `protrusion` is the distance the head's outer face (and the nut's
    /// outer face) stick past the plate's outer surface. 0 keeps the
    /// legacy geometry — head flush with its plate's outer surface, nut
    /// flush with the opposite plate's. A positive value reduces the inlay
    /// and rises a volcano of the *same* height around the protruding
    /// portion: the head / nut top ends up flush with the volcano's flat
    /// plateau, and the cavity's open crater lets the driver still reach
    /// the fastener.
    ///
    /// `headSide` chooses which plate hosts the countersink (and which
    /// hosts the hex-nut pocket on the opposite plate). `.top` is the
    /// legacy orientation; `.bottom` flips the screw upside down so the
    /// head sinks into the bottom plate and the nut into the top.
    static func meshes(
        at p: Point, rotation: Rotation,
        topInnerZ: Double, topThickness: Double,
        bottomInnerZ: Double, bottomThickness: Double,
        protrusion: Double,
        domeBaseDiameter: Double,
        headDepth: Double,
        nutDepth: Double,
        headSide: Plate = .top
    ) -> CSG {
        let eps = 0.05
        let topFace = topInnerZ + topThickness
        let bottomFace = bottomInnerZ - bottomThickness
        let prot = max(0, protrusion)
        // The volcano rises by exactly `prot`, so its flat plateau ends up
        // flush with the fastener's protruding outer face; the open crater
        // (the cavity cylinder, carved later) keeps the head / nut reachable
        // from straight above. `prot == 0` builds no dome at all (flush).
        let domeHeight = prot

        let hexSide = headSide.opposite
        // Outer face Z of the head's / nut's host plate, plus the unit Z
        // direction that points *out* of the assembly through that face
        // (+1 for the top plate, -1 for the bottom). Using the outward
        // sign lets the same expressions describe both orientations.
        let headFace = (headSide == .top) ? topFace : bottomFace
        let hexFace = (hexSide == .top) ? topFace : bottomFace
        let headOut: Double = (headSide == .top) ? 1 : -1
        let hexOut: Double = (hexSide == .top) ? 1 : -1

        // Head cavity: cylinder of length `headDepth`. With `prot` > 0 it
        // shifts outward so the head's outer face sits `prot` past
        // `headFace` — flush with the volcano plateau (also `prot` tall) —
        // while the open crater keeps the head reachable.
        let headInner = headFace - headOut * (headDepth - prot)
        let headOuter = headFace + headOut * domeHeight
        let countersinkZLo = min(headInner, headOuter) - eps
        let countersinkZHi = max(headInner, headOuter) + eps
        let countersink = verticalCylinder(
            radius: headDiameter / 2,
            zLo: countersinkZLo,
            zHi: countersinkZHi,
            slices: 24
        ).translated(by: Vector(p.x, p.y, 0))

        // Hex pocket: mirror of the head cavity on the opposite plate.
        let hexInner = hexFace - hexOut * (nutDepth - prot)
        let hexOuter = hexFace + hexOut * domeHeight
        let hexZLo = min(hexInner, hexOuter) - eps
        let hexZHi = max(hexInner, hexOuter) + eps
        let hexPrismMesh = hexPrism(
            acrossFlats: hexAcrossFlats,
            zLo: hexZLo,
            zHi: hexZHi,
            rotation: rotation.radians,
            at: p
        )

        // Through-hole spans the screw's full vertical extent (pocket
        // bottom to head cavity top). Where the wider cavities cover, it's
        // a no-op (the wider mesh dominates); where the head's bottom or
        // the nut's top sit outside the plate (protrusion > headDepth /
        // nutDepth), the through-hole provides the narrow shaft tube
        // connecting the cavities through the dome material.
        let throughZLo = min(countersinkZLo, hexZLo)
        let throughZHi = max(countersinkZHi, hexZHi)
        let through = verticalCylinder(
            radius: throughDiameter / 2,
            zLo: throughZLo,
            zHi: throughZHi,
            slices: 16
        ).translated(by: Vector(p.x, p.y, 0))

        var csg = CSG()
        switch headSide {
        case .top:
            csg.topCutters = [countersink, through]
            csg.bottomCutters = [through, hexPrismMesh]
        case .bottom:
            csg.bottomCutters = [countersink, through]
            csg.topCutters = [through, hexPrismMesh]
        }

        if prot > 0 {
            let hexCircumR = hexAcrossFlats / sqrt(3.0)
            let headR = headDiameter / 2
            // Both domes share the user's base diameter. Clamp at the
            // greater rim so the frustum never inverts (the rim must sit
            // strictly inside the base by at least 0.05 mm).
            let baseR = max(domeBaseDiameter / 2,
                            max(headR, hexCircumR) + domeRimMargin + 0.05)
            let headDome = volcanoDome(
                at: p, baseZ: headFace, side: headSide,
                height: domeHeight,
                baseRadius: baseR,
                topRadius: headR + domeRimMargin
            )
            let hexDome = volcanoDome(
                at: p, baseZ: hexFace, side: hexSide,
                height: domeHeight,
                baseRadius: baseR,
                topRadius: hexCircumR + domeRimMargin
            )
            switch headSide {
            case .top:
                csg.topAdditions.append(headDome)
                csg.bottomAdditions.append(hexDome)
            case .bottom:
                csg.bottomAdditions.append(headDome)
                csg.topAdditions.append(hexDome)
            }
        }

        return csg
    }

    /// Truncated-cone (Mt-Fuji-shaped) dome attached to the plate's outer
    /// face. Sides taper from `baseRadius` at the plate up to `topRadius`
    /// at height `h`, where a flat plateau caps the volcano. The cavity
    /// cylinder is subtracted later, carving the crater through the
    /// plateau and supplying head / nut access from above.
    private static func volcanoDome(
        at p: Point, baseZ: Double, side: Plate,
        height h: Double, baseRadius rBase: Double, topRadius rTop: Double
    ) -> Mesh {
        // Profile in lathe XY (X = radial, Y = axial), traced as a closed
        // trapezoid. Lathe revolves around Y to make the frustum.
        let pts: [Vector] = [
            Vector(0, 0, 0),         // axis at base
            Vector(rBase, 0, 0),     // outer rim at base
            Vector(rTop, h, 0),      // outer rim at plateau
            Vector(0, h, 0),         // axis at plateau
        ]
        let path = Path(pts.map { PathPoint.point($0) })
        let lathe = Mesh.lathe(path, slices: 24)
        // Euclid's `Rotation.pitch(θ)` is internally a rotation by `-θ`
        // (same quirk as `roll`, see the comment on `portBoreMesh` in
        // `PlateBuilder`). So `pitch(+π/2)` sends lathe-Y → world `-Z` and
        // `pitch(-π/2)` sends lathe-Y → world `+Z`. The top dome rises in
        // +Z, the bottom dome drops in -Z.
        let oriented: Mesh
        switch side {
        case .top:    oriented = lathe.rotated(by: Euclid.Rotation.pitch(-.halfPi))
        case .bottom: oriented = lathe.rotated(by: Euclid.Rotation.pitch(.halfPi))
        }
        return oriented.translated(by: Vector(p.x, p.y, baseZ))
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
