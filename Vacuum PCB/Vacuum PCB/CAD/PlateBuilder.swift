import Foundation
import Euclid

/// Produces the top and bottom plate solids for a CircuitDocument.
/// Coordinate system: model XY → world XY (mm). Z is the plate-normal axis.
/// Silicone occupies z ∈ [-siliconeThickness/2, +siliconeThickness/2].
/// Top plate sits above the silicone; bottom plate sits below.
/// Channels are grooves cut into each plate's silicone-facing inner face.
enum PlateBuilder {

    struct Output {
        let topPlate: Mesh
        let bottomPlate: Mesh
    }

    static func build(_ doc: CircuitDocument) -> Output {
        let m = doc.manufacturing
        let outline = doc.physical.boardOutline

        let topInnerZ = m.siliconeThickness / 2
        let bottomInnerZ = -m.siliconeThickness / 2

        var top = plateBase(outline: outline, thickness: m.plateThickness,
                            innerZ: topInnerZ, side: .top)
        var bottom = plateBase(outline: outline, thickness: m.plateThickness,
                               innerZ: bottomInnerZ, side: .bottom)

        // Collect cutters per plate, union, then subtract once. Far cheaper than N
        // sequential subtractions, each of which rebuilds the plate's BSP tree.
        var topCutters: [Mesh] = []
        var bottomCutters: [Mesh] = []

        // User-drawn channels.
        for route in doc.physical.routes {
            for segment in route.segments {
                let channel = channelMeshForSegment(
                    waypoints: segment.waypoints.map(\.position),
                    layer: segment.layer, m: m,
                    topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ
                )
                appendCutter(channel, layer: segment.layer, top: &topCutters, bottom: &bottomCutters)
            }
        }

        let componentsById = Dictionary(uniqueKeysWithValues: doc.logic.components.map { ($0.id, $0) })

        for placement in doc.physical.placements {
            guard let component = componentsById[placement.componentId] else { continue }
            switch component.kind {
            case .transistor:
                let dimple = dimpleMesh(
                    at: placement.position, layer: placement.layer, m: m,
                    topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ
                )
                appendCutter(dimple, layer: placement.layer, top: &topCutters, bottom: &bottomCutters)

            case .resistor:
                let serpentine = resistorSerpentineMesh(
                    placement: placement, component: component, m: m,
                    topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ
                )
                appendCutter(serpentine, layer: placement.layer, top: &topCutters, bottom: &bottomCutters)

            case .port, .vacuumSource, .atmVent:
                let bore = portBoreMesh(
                    placement: placement, outline: outline, m: m,
                    topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ
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

        // Euclid's BSP CSG can leave hairline cracks where a curved surface meets a flat
        // one (cylinder bore through a plate face, etc.). makeWatertight inserts missing
        // edge vertices without altering shape, and slicers refuse to print non-manifold
        // STLs. Skip the fix-up if already watertight to save work.
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

    /// Carves a Manhattan polyline into a plate as a groove open on the silicone face.
    /// Each pair of waypoints contributes an axis-aligned cuboid; small "joiner" squares
    /// at each waypoint ensure corner meets are watertight without manual fillets.
    private static func channelMeshForSegment(
        waypoints: [Point], layer: Layer, m: ManufacturingConstants,
        topInnerZ: Double, bottomInnerZ: Double
    ) -> Mesh {
        guard waypoints.count >= 2 else { return Mesh.empty }

        let w = m.channelWidth
        let h = m.channelHeight
        let eps = 0.05

        let zLo: Double, zHi: Double
        switch layer {
        case .top:    zLo = topInnerZ - eps;    zHi = topInnerZ + h
        case .bottom: zLo = bottomInnerZ - h;   zHi = bottomInnerZ + eps
        }
        let cz = (zLo + zHi) / 2
        let sz = zHi - zLo

        var parts: [Mesh] = []
        parts.reserveCapacity(2 * waypoints.count)

        for i in 0..<(waypoints.count - 1) {
            let a = waypoints[i]
            let b = waypoints[i + 1]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let cx: Double, cy: Double, sx: Double, sy: Double
            if abs(dx) >= abs(dy) {
                cx = (a.x + b.x) / 2
                cy = a.y
                sx = max(abs(dx), w)
                sy = w
            } else {
                cx = a.x
                cy = (a.y + b.y) / 2
                sx = w
                sy = max(abs(dy), w)
            }
            parts.append(Mesh.cube(center: Vector(cx, cy, cz), size: Vector(sx, sy, sz)))
        }
        for p in waypoints {
            parts.append(Mesh.cube(center: Vector(p.x, p.y, cz), size: Vector(w, w, sz)))
        }
        return Mesh.union(parts)
    }

    // MARK: - Dimples

    private static func dimpleMesh(
        at center: Point, layer: Layer, m: ManufacturingConstants,
        topInnerZ: Double, bottomInnerZ: Double
    ) -> Mesh {
        let radius = m.dimpleDiameter / 2
        let depth = m.dimpleDepth
        let eps = 0.05
        let h = depth + eps
        let cz: Double
        switch layer {
        case .top:    cz = topInnerZ - eps + h / 2     // spans innerZ - eps … innerZ + depth
        case .bottom: cz = bottomInnerZ + eps - h / 2  // spans innerZ - depth … innerZ + eps
        }
        // Euclid cylinder is oriented along Y. Rotate to Z-axis.
        return Mesh.cylinder(radius: radius, height: h, slices: 32)
            .rotated(by: Euclid.Rotation.pitch(.halfPi))
            .translated(by: Vector(center.x, center.y, cz))
    }

    // MARK: - Resistor serpentine

    private static func resistorSerpentineMesh(
        placement: Placement, component: Component, m: ManufacturingConstants,
        topInnerZ: Double, bottomInnerZ: Double
    ) -> Mesh {
        let footprint = component.footprint
        let halfLen: Double
        let halfWid: Double
        switch component.resistorSize ?? .medium {
        case .small:  halfLen = 3.0
        case .medium: halfLen = 5.0
        case .large:  halfLen = 8.0
        }
        halfWid = footprint.boundingRect.size.height / 2

        // Single Z-bend zigzag in component-local frame, traveling pin "1" → pin "2".
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
        return channelMeshForSegment(
            waypoints: world, layer: placement.layer, m: m,
            topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ
        )
    }

    // MARK: - Edge ports

    private static func portBoreMesh(
        placement: Placement, outline: Rect, m: ManufacturingConstants,
        topInnerZ: Double, bottomInnerZ: Double
    ) -> Mesh {
        let radius = m.portBoreDiameter / 2
        let bz: Double
        switch placement.layer {
        case .top:    bz = topInnerZ + m.channelHeight / 2
        case .bottom: bz = bottomInnerZ - m.channelHeight / 2
        }
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
