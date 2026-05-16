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
        /// Union of every channel / drop bore / dimple / serpentine / port bore
        /// that was subtracted from the top plate. Used by the 3D preview's
        /// "features only" mode to show the routing solids without the plate.
        let topFeatures: Mesh
        let bottomFeatures: Mesh
    }

    static func build(_ doc: CircuitDocument) -> Output {
        let m = doc.manufacturing
        let outline = doc.physical.boardOutline

        let topInnerZ = m.siliconeThickness / 2                  // top plate's silicone-facing face
        let bottomInnerZ = -m.siliconeThickness / 2              // bottom plate's silicone-facing face

        // Per-plate thicknesses scale with the number of channel layers in
        // each plate. With layerCount == 1 they reduce to today's
        // `plateThickness` value, so single-layer designs print bit-identical
        // geometry.
        let topThickness = m.plateThickness(forLayerCount: doc.physical.topLayers)
        let bottomThickness = m.plateThickness(forLayerCount: doc.physical.bottomLayers)

        var top = plateBase(outline: outline, thickness: topThickness,
                            innerZ: topInnerZ, side: .top)
        var bottom = plateBase(outline: outline, thickness: bottomThickness,
                               innerZ: bottomInnerZ, side: .bottom)

        // Depth-0 midline z's, used by drop bores / dimples / port bores
        // (all of which anchor to the silicone-facing channel layer).
        let topMidZ = m.midZ(for: Layer(plate: .top, depth: 0))
        let bottomMidZ = m.midZ(for: Layer(plate: .bottom, depth: 0))

        var topCutters: [Mesh] = []
        var bottomCutters: [Mesh] = []

        // 1. Channels — round bores swept along Manhattan polylines at the
        // layer's midline. Layer carries both the plate and the depth, so
        // multi-layer routing falls out automatically.
        for route in doc.physical.routes {
            for segment in route.segments {
                let midZ = m.midZ(for: segment.layer)
                let channel = channelMesh(
                    waypoints: segment.waypoints.map(\.position),
                    radius: m.channelDiameter / 2,
                    midZ: midZ
                )
                appendCutter(channel, plate: segment.layer.plate,
                             top: &topCutters, bottom: &bottomCutters)
            }
        }

        // 2. Component features. All components anchor at depth 0; geometry
        // unchanged from single-layer.
        let componentsById = Dictionary(uniqueKeysWithValues: doc.logic.components.map { ($0.id, $0) })

        for placement in doc.physical.placements {
            guard let component = componentsById[placement.componentId] else { continue }
            switch component.kind {
            case .transistor:
                let dimple = dimpleMesh(
                    at: placement.position, layer: placement.layer, m: m,
                    topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ
                )
                appendCutter(dimple, plate: placement.layer,
                             top: &topCutters, bottom: &bottomCutters)

                // Source/drain pad cavities on the opposite plate's silicone
                // face. Both pads come out of a single sphere with the middle
                // strip carved out; the drop bores land inside the cavity.
                let pads = padsCavityMesh(
                    placement: placement, m: m,
                    topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ
                )
                appendCutter(pads, plate: placement.layer.opposite,
                             top: &topCutters, bottom: &bottomCutters)

                // Drop bore at each transistor pin, connecting channel midline to the
                // silicone face on whichever plate the pin sits on.
                let footprint = component.footprint(m)
                for pin in footprint.pins {
                    let pinPlate = placement.resolvedPlate(of: pin)
                    let pinWorld = placement.worldPosition(of: pin)
                    let drop = dropBoreMesh(
                        at: pinWorld, onPlate: pinPlate, radius: m.channelDiameter / 2,
                        topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ,
                        topMidZ: topMidZ, bottomMidZ: bottomMidZ
                    )
                    appendCutter(drop, plate: pinPlate,
                                 top: &topCutters, bottom: &bottomCutters)
                }

            case .resistor:
                let serpentine = resistorSerpentineMesh(
                    placement: placement, component: component, m: m,
                    topMidZ: topMidZ, bottomMidZ: bottomMidZ
                )
                appendCutter(serpentine, plate: placement.layer,
                             top: &topCutters, bottom: &bottomCutters)

            case .port, .vacuumSource, .atmVent:
                let bore = portBoreMesh(
                    placement: placement, outline: outline, m: m,
                    topMidZ: topMidZ, bottomMidZ: bottomMidZ
                )
                appendCutter(bore, plate: placement.layer,
                             top: &topCutters, bottom: &bottomCutters)
            }
        }

        // 3. Vias — vertical bores spanning min(twin.z) … max(twin.z) at the
        // marked XY. With multi-layer plates, twins can sit on the same plate
        // at different depths (a vertical tube *inside* one plate, no
        // silicone crossing), or on opposite plates (today's behaviour).
        // Dedup by position because each via is represented twice in the
        // document (once at each end of its twin pair).
        struct ViaGroup { var position: Point; var layers: Set<Layer> }
        var viaGroups: [ViaGroup] = []
        for route in doc.physical.routes {
            for segment in route.segments {
                for wp in segment.waypoints where wp.kind == .via {
                    if let idx = viaGroups.firstIndex(where: { approxEqualXY($0.position, wp.position) }) {
                        viaGroups[idx].layers.insert(segment.layer)
                    } else {
                        viaGroups.append(ViaGroup(position: wp.position, layers: [segment.layer]))
                    }
                }
            }
        }
        for group in viaGroups {
            guard group.layers.count >= 2 else { continue }
            let zs = group.layers.map { m.midZ(for: $0) }
            let zLo = zs.min()!, zHi = zs.max()!
            let cutter = viaCutterMesh(at: group.position, radius: m.channelDiameter / 2,
                                       zLo: zLo, zHi: zHi)
            // A via cuts whichever plate(s) it actually passes through. If
            // every layer in the group is on the same plate, only that plate
            // gets the cutter (no need to drill the opposite slab).
            let plates = Set(group.layers.map { $0.plate })
            if plates.contains(.top) { topCutters.append(cutter) }
            if plates.contains(.bottom) { bottomCutters.append(cutter) }
        }

        // Union the cutter sets once and reuse: the subtractions consume the
        // same union the preview's features-only mode renders, so we avoid
        // building it twice.
        let topFeatures = topCutters.isEmpty ? Mesh.empty : Mesh.union(topCutters)
        let bottomFeatures = bottomCutters.isEmpty ? Mesh.empty : Mesh.union(bottomCutters)

        if !topCutters.isEmpty    { top = top.subtracting(topFeatures) }
        if !bottomCutters.isEmpty { bottom = bottom.subtracting(bottomFeatures) }

        // Euclid's BSP CSG can leave hairline cracks where curved surfaces meet flat ones.
        // makeWatertight inserts missing edge vertices without altering shape, and slicers
        // refuse to print non-manifold STLs.
        if !top.isWatertight { top = top.makeWatertight() }
        if !bottom.isWatertight { bottom = bottom.makeWatertight() }

        return Output(
            topPlate: top, bottomPlate: bottom,
            topFeatures: topFeatures, bottomFeatures: bottomFeatures
        )
    }

    // MARK: - Plate base

    private static func plateBase(
        outline: Rect, thickness: Double, innerZ: Double, side: Plate
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

        // Cylinders between adjacent waypoints. Euclid's cylinder is Y-axis
        // aligned. Roll(α) rotates around Z; the convention here is such that
        // roll(π/2) sends a horizontal-segment cylinder along X (the original
        // Manhattan-only code relied on this). Generalising: α = π/2 − θ,
        // where θ = atan2(dy, dx) is the segment angle in XY. This puts the
        // cylinder's long axis exactly along the segment so the joint spheres
        // line up at any angle.
        for i in 0..<(waypoints.count - 1) {
            let a = waypoints[i]
            let b = waypoints[i + 1]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > 0 else { continue }

            let cx = (a.x + b.x) / 2
            let cy = (a.y + b.y) / 2
            let theta = atan2(dy, dx)
            let cyl = Mesh.cylinder(radius: radius, height: len, slices: 16)
                .rotated(by: Euclid.Rotation.roll(.radians(.pi / 2 - theta)))
                .translated(by: Vector(cx, cy, midZ))
            parts.append(cyl)
        }
        return Mesh.union(parts)
    }

    // MARK: - Drop bores

    /// Vertical cylinder connecting a pin location at channel-midline depth to the
    /// silicone-facing surface of `layer`. Overshoots both ends by a small epsilon
    /// so CSG cuts are clean rather than tangent.
    private static func dropBoreMesh(
        at p: Point, onPlate plate: Plate, radius: Double,
        topInnerZ: Double, bottomInnerZ: Double,
        topMidZ: Double, bottomMidZ: Double
    ) -> Mesh {
        let eps = 0.05
        let zLo: Double, zHi: Double
        switch plate {
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

    // MARK: - Via

    /// Vertical cylinder spanning between the two twins of a via. With
    /// multi-layer plates the twins can be on the same plate at different
    /// depths (a tube *inside* one plate), or on opposite plates (the
    /// traditional silicone-crossing via). Either way the cutter is one
    /// cylinder; the caller decides which plate(s) it should subtract from.
    /// Silicone between top and bottom plates is the user's job to punch at
    /// the same XY at assembly.
    private static func viaCutterMesh(
        at p: Point, radius: Double, zLo: Double, zHi: Double
    ) -> Mesh {
        let eps = 0.05
        let lo = zLo - eps
        let hi = zHi + eps
        let len = hi - lo
        let cz = (hi + lo) / 2
        return Mesh.cylinder(radius: radius, height: len, slices: 24)
            .rotated(by: Euclid.Rotation.pitch(.halfPi))
            .translated(by: Vector(p.x, p.y, cz))
    }

    private static func approxEqualXY(_ a: Point, _ b: Point, eps: Double = 0.05) -> Bool {
        abs(a.x - b.x) < eps && abs(a.y - b.y) < eps
    }

    // MARK: - Dimples

    /// Dome-shaped dimple cavity: a sphere whose centre sits
    /// `dimpleSphereOffset` mm into the silicone gap from the plate's
    /// silicone-facing surface. The cap that intrudes into the plate is the
    /// cavity — widest at the surface, tapering inward. Intersected with a
    /// half-space cube so the cutter is bounded at the plate surface; otherwise
    /// the rest of the sphere would render through the silicone gap in the
    /// channels-only view.
    private static func dimpleMesh(
        at center: Point, layer: Plate, m: ManufacturingConstants,
        topInnerZ: Double, bottomInnerZ: Double
    ) -> Mesh {
        let radius = m.dimpleDiameter / 2
        let offset = m.dimpleSphereOffset
        let eps = 0.05
        let cz: Double
        let clipLo: Double
        let clipHi: Double
        switch layer {
        case .top:
            cz = topInnerZ - offset
            clipLo = topInnerZ - eps               // overshoot surface by eps for clean CSG
            clipHi = topInnerZ + radius + 1        // safely above the cap's deepest point
        case .bottom:
            cz = bottomInnerZ + offset
            clipLo = bottomInnerZ - radius - 1
            clipHi = bottomInnerZ + eps
        }
        let sphere = Mesh.sphere(radius: radius, slices: 32)
            .translated(by: Vector(center.x, center.y, cz))
        let clipper = Mesh.cube(
            center: Vector(center.x, center.y, (clipLo + clipHi) / 2),
            size: Vector(2 * radius + 1, 2 * radius + 1, clipHi - clipLo)
        )
        return sphere.intersection(clipper)
    }

    // MARK: - Source/drain pads

    /// Source/drain pad cavities for one transistor placement, returned as a
    /// single cutter mesh to be subtracted from the opposite plate. Built in
    /// the placement's local frame and then rotated/translated to world:
    ///
    /// 1. Sphere of diameter `padsDiameter` centred at the gate on the
    ///    opposite plate's silicone face.
    /// 2. Intersected with the plate-body half-space (so the half on the
    ///    silicone-gap side doesn't leak across into the other plate's view).
    /// 3. With the central strip of width `padsSeparation` along local X
    ///    subtracted — that's the silicone septum between source and drain.
    ///
    /// The drop bores at the pin offsets land inside these cavities, joining
    /// them to the channel midline below.
    private static func padsCavityMesh(
        placement: Placement, m: ManufacturingConstants,
        topInnerZ: Double, bottomInnerZ: Double
    ) -> Mesh {
        let radius = m.padsDiameter / 2
        let sep = m.padsSeparation
        let eps = 0.05
        let oppositePlate = placement.layer.opposite
        let oppositeInnerZ = oppositePlate == .top ? topInnerZ : bottomInnerZ

        // Local frame: sphere centred at origin on the silicone face (z = 0).
        // Plate body extends in +Z (pads on top plate) or -Z (pads on bottom).
        let sphere = Mesh.sphere(radius: radius, slices: 32)

        // Half-space cube spanning the plate-body side with eps overshoot at
        // the face, generous in XY/Z to fully contain the cap.
        let pad = radius + 0.5
        let bodyHalfHeight = radius + 0.5
        let bodyCubeCenterZ = oppositePlate == .top
            ? bodyHalfHeight - eps
            : -bodyHalfHeight + eps
        let bodyCube = Mesh.cube(
            center: Vector(0, 0, bodyCubeCenterZ),
            size: Vector(2 * pad, 2 * pad, 2 * bodyHalfHeight)
        )

        // Strip cube carved out of the cap to separate the two pads. Width is
        // padsSeparation along local X; height/depth generous so the strip
        // cleanly cuts through the sphere.
        let stripCube = Mesh.cube(
            center: .zero,
            size: Vector(sep, 2 * pad, 2 * bodyHalfHeight + 1)
        )

        let cavityLocal = sphere.intersection(bodyCube).subtracting(stripCube)

        let rotated = cavityLocal.rotated(
            by: Euclid.Rotation.roll(.radians(placement.rotation.radians))
        )
        return rotated.translated(by: Vector(
            placement.position.x, placement.position.y, oppositeInnerZ
        ))
    }

    // MARK: - Resistor serpentine

    private static func resistorSerpentineMesh(
        placement: Placement, component: Component, m: ManufacturingConstants,
        topMidZ: Double, bottomMidZ: Double
    ) -> Mesh {
        _ = topMidZ; _ = bottomMidZ
        // Footprint is the same physical size for S/M/L; the resistor size
        // picks how many times the channel zigzags inside it. Path generator
        // is shared with the physical-canvas glyph so the preview and the
        // printed channel match. Resistors are pure tubes — they can live on
        // any channel-layer depth, so the serpentine's midZ comes from the
        // placement's depth (defaults to 0 for legacy files).
        let halfLen = ManufacturingConstants.resistorFootprintLength / 2
        let halfWid = ManufacturingConstants.resistorFootprintWidth / 2
        let transitions = ResistorGeometry.transitions(for: component.resistorSize ?? .medium)
        let local = ResistorGeometry.path(transitions: transitions, halfLen: halfLen, halfWid: halfWid)
        let world = local.map { transformLocalToWorld($0, placement: placement) }
        let midZ = m.midZ(for: Layer(plate: placement.layer, depth: placement.depth))
        return channelMesh(waypoints: world, radius: m.resistorChannelDiameter / 2, midZ: midZ)
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
        _ mesh: Mesh, plate: Plate,
        top: inout [Mesh], bottom: inout [Mesh]
    ) {
        switch plate {
        case .top:    top.append(mesh)
        case .bottom: bottom.append(mesh)
        }
    }
}
