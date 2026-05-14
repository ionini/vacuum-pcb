import Foundation
import Euclid

/// Produces the top and bottom plate solids for a CircuitDocument.
/// Coordinate system: model XY → world XY (mm). Z is the plate-normal axis.
/// Silicone occupies z ∈ [-siliconeThickness/2, +siliconeThickness/2].
/// Top plate sits above the silicone, bottom plate below.
///
/// Channels run as round bores through the *midline* of each plate (not as open
/// grooves on the silicone face). Transistor pins (gate / source / drain) connect
/// the channel network to the silicone face via vertical drop bores. Edge ports
/// enter horizontally at the midline.
enum PlateBuilder {

    struct Output {
        let topPlate: Mesh
        let bottomPlate: Mesh
    }

    static func build(_ doc: CircuitDocument) -> Output {
        let m = doc.manufacturing
        let outline = doc.physical.boardOutline

        let topInnerZ = m.siliconeThickness / 2                  // top plate's silicone-facing face
        let bottomInnerZ = -m.siliconeThickness / 2              // bottom plate's silicone-facing face
        let topMidZ = topInnerZ + m.plateThickness / 2           // channel midline, top
        let bottomMidZ = bottomInnerZ - m.plateThickness / 2     // channel midline, bottom

        var top = plateBase(outline: outline, thickness: m.plateThickness,
                            innerZ: topInnerZ, side: .top)
        var bottom = plateBase(outline: outline, thickness: m.plateThickness,
                               innerZ: bottomInnerZ, side: .bottom)

        var topCutters: [Mesh] = []
        var bottomCutters: [Mesh] = []

        // 1. Channels — round bores swept along Manhattan polylines at the plate midline.
        for route in doc.physical.routes {
            for segment in route.segments {
                let midZ: Double
                switch segment.layer {
                case .top:    midZ = topMidZ
                case .bottom: midZ = bottomMidZ
                }
                let channel = channelMesh(
                    waypoints: segment.waypoints.map(\.position),
                    radius: m.channelDiameter / 2,
                    midZ: midZ
                )
                appendCutter(channel, layer: segment.layer, top: &topCutters, bottom: &bottomCutters)
            }
        }

        // 2. Component features.
        let componentsById = Dictionary(uniqueKeysWithValues: doc.logic.components.map { ($0.id, $0) })

        for placement in doc.physical.placements {
            guard let component = componentsById[placement.componentId] else { continue }
            switch component.kind {
            case .transistor:
                // Dimple on the placement's plate.
                let dimple = dimpleMesh(
                    at: placement.position, layer: placement.layer, m: m,
                    topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ
                )
                appendCutter(dimple, layer: placement.layer, top: &topCutters, bottom: &bottomCutters)

                // Drop bore at each transistor pin, connecting channel midline to the
                // silicone face on whichever plate the pin sits on.
                let footprint = component.footprint
                for pin in footprint.pins {
                    let pinLayer = placement.resolvedLayer(of: pin)
                    let pinWorld = placement.worldPosition(of: pin)
                    let drop = dropBoreMesh(
                        at: pinWorld, onLayer: pinLayer, radius: m.channelDiameter / 2,
                        topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ,
                        topMidZ: topMidZ, bottomMidZ: bottomMidZ
                    )
                    appendCutter(drop, layer: pinLayer, top: &topCutters, bottom: &bottomCutters)
                }

            case .resistor:
                let serpentine = resistorSerpentineMesh(
                    placement: placement, component: component, m: m,
                    topMidZ: topMidZ, bottomMidZ: bottomMidZ
                )
                appendCutter(serpentine, layer: placement.layer, top: &topCutters, bottom: &bottomCutters)

            case .port, .vacuumSource, .atmVent:
                let bore = portBoreMesh(
                    placement: placement, outline: outline, m: m,
                    topMidZ: topMidZ, bottomMidZ: bottomMidZ
                )
                appendCutter(bore, layer: placement.layer, top: &topCutters, bottom: &bottomCutters)
            }
        }

        if !topCutters.isEmpty {
            top = top.subtracting(Mesh.union(topCutters))
        }
        if !bottomCutters.isEmpty {
            bottom = bottom.subtracting(Mesh.union(bottomCutters))
        }

        // Euclid's BSP CSG can leave hairline cracks where curved surfaces meet flat ones.
        // makeWatertight inserts missing edge vertices without altering shape, and slicers
        // refuse to print non-manifold STLs.
        if !top.isWatertight { top = top.makeWatertight() }
        if !bottom.isWatertight { bottom = bottom.makeWatertight() }

        return Output(topPlate: top, bottomPlate: bottom)
    }

    // MARK: - Plate base

    private static func plateBase(
        outline: Rect, thickness: Double, innerZ: Double, side: Layer
    ) -> Mesh {
        let cx = outline.origin.x + outline.size.width / 2
        let cy = outline.origin.y + outline.size.height / 2
        let cz = side == .top ? innerZ + thickness / 2 : innerZ - thickness / 2
        return Mesh.cube(
            center: Vector(cx, cy, cz),
            size: Vector(outline.size.width, outline.size.height, thickness)
        )
    }

    // MARK: - Channels

    /// Builds a round-bore channel running through `midZ` along a Manhattan polyline.
    /// Each waypoint contributes a sphere joint; each segment contributes a cylinder
    /// laid along its axis. Spheres + cylinders fully overlap so the union is closed.
    private static func channelMesh(
        waypoints: [Point], radius: Double, midZ: Double
    ) -> Mesh {
        guard waypoints.count >= 2 else { return Mesh.empty }

        var parts: [Mesh] = []
        parts.reserveCapacity(2 * waypoints.count)

        // Spheres at each waypoint so junctions are watertight at any branching angle.
        for p in waypoints {
            parts.append(Mesh.sphere(radius: radius, slices: 16)
                .translated(by: Vector(p.x, p.y, midZ)))
        }

        // Cylinders between adjacent waypoints. Euclid's cylinder is Y-oriented;
        // roll(90°) lays it along X, identity leaves it along Y. Length is the
        // Euclidean span so this also handles diagonal segments cleanly.
        for i in 0..<(waypoints.count - 1) {
            let a = waypoints[i]
            let b = waypoints[i + 1]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > 0 else { continue }

            let cx = (a.x + b.x) / 2
            let cy = (a.y + b.y) / 2
            let cyl = Mesh.cylinder(radius: radius, height: len, slices: 16)
            let oriented: Mesh
            if abs(dx) >= abs(dy) {
                // Horizontal: lay cylinder along X.
                oriented = cyl.rotated(by: Euclid.Rotation.roll(.halfPi))
            } else {
                // Vertical (in XY): keep along Y.
                oriented = cyl
            }
            parts.append(oriented.translated(by: Vector(cx, cy, midZ)))
        }
        return Mesh.union(parts)
    }

    // MARK: - Drop bores

    /// Vertical cylinder connecting a pin location at channel-midline depth to the
    /// silicone-facing surface of `layer`. Overshoots both ends by a small epsilon
    /// so CSG cuts are clean rather than tangent.
    private static func dropBoreMesh(
        at p: Point, onLayer layer: Layer, radius: Double,
        topInnerZ: Double, bottomInnerZ: Double,
        topMidZ: Double, bottomMidZ: Double
    ) -> Mesh {
        let eps = 0.05
        let zLo: Double, zHi: Double
        switch layer {
        case .top:
            // Drop from midline DOWN to silicone face.
            zLo = topInnerZ - eps
            zHi = topMidZ + eps
        case .bottom:
            // Drop from midline UP to silicone face.
            zLo = bottomMidZ - eps
            zHi = bottomInnerZ + eps
        }
        let len = zHi - zLo
        let cz = (zLo + zHi) / 2
        return Mesh.cylinder(radius: radius, height: len, slices: 16)
            .rotated(by: Euclid.Rotation.pitch(.halfPi))
            .translated(by: Vector(p.x, p.y, cz))
    }

    // MARK: - Dimples

    private static func dimpleMesh(
        at center: Point, layer: Layer, m: ManufacturingConstants,
        topInnerZ: Double, bottomInnerZ: Double
    ) -> Mesh {
        let radius = m.dimpleDiameter / 2
        let eps = 0.05
        let h = m.dimpleDepth + eps
        let cz: Double
        switch layer {
        case .top:    cz = topInnerZ - eps + h / 2     // spans innerZ-eps … innerZ+depth
        case .bottom: cz = bottomInnerZ + eps - h / 2  // spans innerZ-depth … innerZ+eps
        }
        return Mesh.cylinder(radius: radius, height: h, slices: 32)
            .rotated(by: Euclid.Rotation.pitch(.halfPi))
            .translated(by: Vector(center.x, center.y, cz))
    }

    // MARK: - Resistor serpentine

    private static func resistorSerpentineMesh(
        placement: Placement, component: Component, m: ManufacturingConstants,
        topMidZ: Double, bottomMidZ: Double
    ) -> Mesh {
        let footprint = component.footprint
        let halfLen: Double
        switch component.resistorSize ?? .medium {
        case .small:  halfLen = 3.0
        case .medium: halfLen = 5.0
        case .large:  halfLen = 8.0
        }
        let halfWid = footprint.boundingRect.size.height / 2

        // Single Z-bend zigzag in component-local frame, pin "1" → pin "2".
        let y = halfWid * 0.6
        let local: [Point] = [
            Point(x: -halfLen, y: 0),
            Point(x: -halfLen, y:  y),
            Point(x:  0,       y:  y),
            Point(x:  0,       y: -y),
            Point(x:  halfLen, y: -y),
            Point(x:  halfLen, y: 0),
        ]
        let world = local.map { transformLocalToWorld($0, placement: placement) }
        let midZ = placement.layer == .top ? topMidZ : bottomMidZ
        return channelMesh(waypoints: world, radius: m.channelDiameter / 2, midZ: midZ)
    }

    // MARK: - Edge ports

    private static func portBoreMesh(
        placement: Placement, outline: Rect, m: ManufacturingConstants,
        topMidZ: Double, bottomMidZ: Double
    ) -> Mesh {
        let radius = m.portBoreDiameter / 2
        let bz = placement.layer == .top ? topMidZ : bottomMidZ
        let p = placement.position
        let eps = 0.5  // overshoot past board edge so the bore breaks the surface cleanly

        switch placement.rotation {
        case .r0:    // exits +X edge
            let edgeFar = outline.maxX + eps
            let length = edgeFar - p.x
            let cx = (edgeFar + p.x) / 2
            return Mesh.cylinder(radius: radius, height: length, slices: 24)
                .rotated(by: Euclid.Rotation.roll(.halfPi))
                .translated(by: Vector(cx, p.y, bz))
        case .r180:  // exits -X edge
            let edgeFar = outline.minX - eps
            let length = p.x - edgeFar
            let cx = (edgeFar + p.x) / 2
            return Mesh.cylinder(radius: radius, height: length, slices: 24)
                .rotated(by: Euclid.Rotation.roll(.halfPi))
                .translated(by: Vector(cx, p.y, bz))
        case .r90:   // exits +Y edge
            let edgeFar = outline.maxY + eps
            let length = edgeFar - p.y
            let cy = (edgeFar + p.y) / 2
            return Mesh.cylinder(radius: radius, height: length, slices: 24)
                .translated(by: Vector(p.x, cy, bz))
        case .r270:  // exits -Y edge
            let edgeFar = outline.minY - eps
            let length = p.y - edgeFar
            let cy = (edgeFar + p.y) / 2
            return Mesh.cylinder(radius: radius, height: length, slices: 24)
                .translated(by: Vector(p.x, cy, bz))
        }
    }

    // MARK: - Transform helpers

    private static func transformLocalToWorld(_ p: Point, placement: Placement) -> Point {
        let r = placement.rotation.radians
        let c = cos(r)
        let s = sin(r)
        return Point(
            x: placement.position.x + p.x * c - p.y * s,
            y: placement.position.y + p.x * s + p.y * c
        )
    }

    private static func appendCutter(
        _ mesh: Mesh, layer: Layer,
        top: inout [Mesh], bottom: inout [Mesh]
    ) {
        switch layer {
        case .top:    top.append(mesh)
        case .bottom: bottom.append(mesh)
        }
    }
}
