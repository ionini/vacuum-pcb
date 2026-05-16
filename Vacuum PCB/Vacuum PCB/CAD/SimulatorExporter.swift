import Foundation
import SceneKit
import Euclid

/// Builds a USDZ that conforms to the Flow Simulator's named-mesh contract
/// (see flow_simulator/README.md: `FluidVolume`, `VacuumInlet_*`,
/// `AtmosphereInlet_*`, `OutputOutlet_*`, `Gate_<suffix>`, `Blocker_<suffix>`).
///
/// The exporter generates extra bodies that *aren't* part of the regular 3D
/// preview or the physical view — they only matter for the simulator. The
/// approach mirrors what the user described:
///   * Port/rail components grow a 1 mm cylinder extending past the board
///     edge as the boundary stub.
///   * Each transistor contributes a `Gate_<label>` chunk (the dimple
///     cavity, the "sense" volume) and a `Blocker_<label>` chunk (the slab
///     between the two source/drain drop bores at the silicone face of the
///     opposite plate). Same `<label>` so the simulator pairs them.
///   * `FluidVolume` is the union of every channel, drop bore, resistor
///     serpentine and port bore — plus a small vertical tube through the
///     silicone gap at each via waypoint so top↔bottom connect.
///
/// Geometry helpers are duplicated from `PlateBuilder` (rather than
/// promoted to a shared module) since the exporter's needs differ slightly
/// — it wants raw fluid volumes, not subtractive cutters — and keeping the
/// duplication confined here avoids leaking export concerns into the
/// CAD-for-print pipeline.
enum SimulatorExporter {
    enum ExportError: Error { case writeFailed }

    static func exportUSDZ(_ doc: CircuitDocument, to url: URL) throws {
        let bodies = buildBodies(for: doc)
        let scene = SCNScene()
        for body in bodies where !body.mesh.polygons.isEmpty {
            let geometry = SCNGeometry(body.mesh)
            let node = SCNNode(geometry: geometry)
            node.name = body.name
            scene.rootNode.addChildNode(node)
        }
        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
            throw ExportError.writeFailed
        }
    }

    // MARK: - Body planning

    private struct Body { let name: String; let mesh: Mesh }

    private static func buildBodies(for doc: CircuitDocument) -> [Body] {
        let m = doc.manufacturing
        let outline = doc.physical.boardOutline

        // Z-layout mirrors the print pipeline. Depth-0 midlines are used for
        // every component feature (drop bores, dimples, port bores, blocker,
        // gate); routes look up their own layer's midline.
        let topInnerZ    =  m.siliconeThickness / 2
        let bottomInnerZ = -m.siliconeThickness / 2
        let topMidZ      = m.midZ(for: Layer(plate: .top, depth: 0))
        let bottomMidZ   = m.midZ(for: Layer(plate: .bottom, depth: 0))

        var fluidParts: [Mesh] = []
        var inletOutletBodies: [Body] = []
        var transistorBodies: [Body] = []

        let componentsById = Dictionary(
            uniqueKeysWithValues: doc.logic.components.map { ($0.id, $0) }
        )

        // 1. Component contributions.
        for placement in doc.physical.placements {
            guard let component = componentsById[placement.componentId] else { continue }
            switch component.kind {
            case .transistor:
                let footprint = component.footprint
                // Drop bores at each transistor pin contribute to the fluid
                // volume so the channels reach the silicone face.
                for pin in footprint.pins {
                    let pinPlate = placement.resolvedPlate(of: pin)
                    let pinWorld = placement.worldPosition(of: pin)
                    fluidParts.append(dropBoreMesh(
                        at: pinWorld, onPlate: pinPlate,
                        radius: m.channelDiameter / 2,
                        topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ,
                        topMidZ: topMidZ, bottomMidZ: bottomMidZ
                    ))
                }
                // Gate_<label>: the dimple cavity itself, where vacuum is
                // sensed. Lives on the placement layer at the silicone face.
                let gateMesh = gateBody(
                    placement: placement, m: m,
                    topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ
                )
                transistorBodies.append(Body(name: "Gate_\(component.label)", mesh: gateMesh))
                // Blocker_<label>: thin slab at the silicone face on the
                // *opposite* plate, spanning between the two source/drain
                // drop bores. Closed by default — silicone seals — and opens
                // when the simulator's gate trigger lets it.
                let blockerMesh = blockerBody(
                    placement: placement, footprint: footprint, m: m,
                    topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ
                )
                transistorBodies.append(Body(name: "Blocker_\(component.label)", mesh: blockerMesh))

            case .resistor:
                let halfLen = ManufacturingConstants.resistorFootprintLength / 2
                let halfWid = ManufacturingConstants.resistorFootprintWidth / 2
                let transitions = ResistorGeometry.transitions(for: component.resistorSize ?? .medium)
                let local = ResistorGeometry.path(transitions: transitions, halfLen: halfLen, halfWid: halfWid)
                let world = local.map { localToWorld($0, placement: placement) }
                let midZ = m.midZ(for: Layer(plate: placement.layer, depth: placement.depth))
                fluidParts.append(channelMesh(
                    waypoints: world,
                    radius: m.resistorChannelDiameter / 2,
                    midZ: midZ
                ))

            case .port, .vacuumSource, .atmVent:
                fluidParts.append(portBoreMesh(
                    placement: placement, outline: outline, m: m,
                    topMidZ: topMidZ, bottomMidZ: bottomMidZ
                ))
                inletOutletBodies.append(Body(
                    name: simulatorInletName(for: component),
                    mesh: inletStubMesh(
                        placement: placement, outline: outline, m: m,
                        topMidZ: topMidZ, bottomMidZ: bottomMidZ
                    )
                ))
            }
        }

        // 2. Route channels + via tubes so layers connect at each via.
        // Via tubes are collected separately so we can compute their full z
        // span from both twins (twins may be on different plates or on the
        // same plate at different depths).
        struct ViaGroup { var position: Point; var layers: Set<Layer> }
        var viaGroups: [ViaGroup] = []
        for route in doc.physical.routes {
            for segment in route.segments {
                let midZ = m.midZ(for: segment.layer)
                fluidParts.append(channelMesh(
                    waypoints: segment.waypoints.map(\.position),
                    radius: m.channelDiameter / 2,
                    midZ: midZ
                ))
                for wp in segment.waypoints where wp.kind == .via {
                    if let idx = viaGroups.firstIndex(where: {
                        abs($0.position.x - wp.position.x) < 0.05 &&
                        abs($0.position.y - wp.position.y) < 0.05
                    }) {
                        viaGroups[idx].layers.insert(segment.layer)
                    } else {
                        viaGroups.append(ViaGroup(position: wp.position, layers: [segment.layer]))
                    }
                }
            }
        }
        for group in viaGroups where group.layers.count >= 2 {
            let zs = group.layers.map { m.midZ(for: $0) }
            fluidParts.append(viaTubeMesh(
                at: group.position, radius: m.channelDiameter / 2,
                zLo: zs.min()!, zHi: zs.max()!
            ))
        }

        let fluidVolume = fluidParts.isEmpty ? Mesh.empty : Mesh.union(fluidParts).makeWatertight()
        var bodies: [Body] = [Body(name: "FluidVolume", mesh: fluidVolume)]
        bodies.append(contentsOf: inletOutletBodies)
        bodies.append(contentsOf: transistorBodies)
        return bodies
    }

    private static func simulatorInletName(for component: Component) -> String {
        let label = component.label
        switch component.kind {
        case .vacuumSource: return "VacuumInlet_\(label)"
        case .atmVent:      return "AtmosphereInlet_\(label)"
        case .port:
            switch component.portDirection {
            case .input:  return "AtmosphereInlet_\(label)"   // external atmosphere signal
            case .output: return "OutputOutlet_\(label)"      // pressure probe
            case .none:   return "AtmosphereInlet_\(label)"
            }
        default: return label
        }
    }

    // MARK: - Geometry helpers (mirror PlateBuilder)

    private static func channelMesh(waypoints: [Point], radius: Double, midZ: Double) -> Mesh {
        guard waypoints.count >= 2 else { return .empty }
        var parts: [Mesh] = []
        parts.reserveCapacity(2 * waypoints.count)
        for p in waypoints {
            parts.append(Mesh.sphere(radius: radius, slices: 16)
                .translated(by: Vector(p.x, p.y, midZ)))
        }
        for i in 0..<(waypoints.count - 1) {
            let a = waypoints[i], b = waypoints[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > 0 else { continue }
            let cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2
            let theta = atan2(dy, dx)
            let cyl = Mesh.cylinder(radius: radius, height: len, slices: 16)
                .rotated(by: Euclid.Rotation.roll(.radians(.pi / 2 - theta)))
                .translated(by: Vector(cx, cy, midZ))
            parts.append(cyl)
        }
        return Mesh.union(parts)
    }

    private static func dropBoreMesh(
        at p: Point, onPlate plate: Plate, radius: Double,
        topInnerZ: Double, bottomInnerZ: Double,
        topMidZ: Double, bottomMidZ: Double
    ) -> Mesh {
        let eps = 0.05
        let zLo: Double, zHi: Double
        switch plate {
        case .top:    zLo = topInnerZ - eps;     zHi = topMidZ + eps
        case .bottom: zLo = bottomMidZ - eps;    zHi = bottomInnerZ + eps
        }
        let len = zHi - zLo
        let cz = (zLo + zHi) / 2
        return Mesh.cylinder(radius: radius, height: len, slices: 16)
            .rotated(by: Euclid.Rotation.pitch(.halfPi))
            .translated(by: Vector(p.x, p.y, cz))
    }

    /// Vertical tube spanning the via's twin layers so the fluid volume
    /// bridges across them. Same role the via cutter plays in the print
    /// pipeline; range is provided by the caller from the twins' midZs.
    private static func viaTubeMesh(
        at p: Point, radius: Double, zLo: Double, zHi: Double
    ) -> Mesh {
        let eps = 0.05
        let lo = zLo - eps
        let hi = zHi + eps
        let len = hi - lo
        let cz = (hi + lo) / 2
        return Mesh.cylinder(radius: radius, height: len, slices: 16)
            .rotated(by: Euclid.Rotation.pitch(.halfPi))
            .translated(by: Vector(p.x, p.y, cz))
    }

    private static func portBoreMesh(
        placement: Placement, outline: Rect, m: ManufacturingConstants,
        topMidZ: Double, bottomMidZ: Double
    ) -> Mesh {
        let radius = m.portBoreDiameter / 2
        let bz = placement.layer == .top ? topMidZ : bottomMidZ
        let p = placement.position
        let eps = 0.5
        switch placement.rotation {
        case .r0:
            let edge = outline.maxX + eps
            let length = edge - p.x
            let cx = (edge + p.x) / 2
            return Mesh.cylinder(radius: radius, height: length, slices: 24)
                .rotated(by: Euclid.Rotation.roll(.halfPi))
                .translated(by: Vector(cx, p.y, bz))
        case .r180:
            let edge = outline.minX - eps
            let length = p.x - edge
            let cx = (edge + p.x) / 2
            return Mesh.cylinder(radius: radius, height: length, slices: 24)
                .rotated(by: Euclid.Rotation.roll(.halfPi))
                .translated(by: Vector(cx, p.y, bz))
        case .r90:
            let edge = outline.maxY + eps
            let length = edge - p.y
            let cy = (edge + p.y) / 2
            return Mesh.cylinder(radius: radius, height: length, slices: 24)
                .translated(by: Vector(p.x, cy, bz))
        case .r270:
            let edge = outline.minY - eps
            let length = p.y - edge
            let cy = (edge + p.y) / 2
            return Mesh.cylinder(radius: radius, height: length, slices: 24)
                .translated(by: Vector(p.x, cy, bz))
        }
    }

    /// 1 mm cylinder extending past the board edge in the port's exit
    /// direction. Acts as the boundary-condition stub the simulator hooks
    /// pressure values onto.
    private static func inletStubMesh(
        placement: Placement, outline: Rect, m: ManufacturingConstants,
        topMidZ: Double, bottomMidZ: Double
    ) -> Mesh {
        let radius = m.portBoreDiameter / 2
        let bz = placement.layer == .top ? topMidZ : bottomMidZ
        let stubLen: Double = 1.0
        switch placement.rotation {
        case .r0:
            let edge = outline.maxX
            let cx = edge + stubLen / 2
            return Mesh.cylinder(radius: radius, height: stubLen, slices: 24)
                .rotated(by: Euclid.Rotation.roll(.halfPi))
                .translated(by: Vector(cx, placement.position.y, bz))
        case .r180:
            let edge = outline.minX
            let cx = edge - stubLen / 2
            return Mesh.cylinder(radius: radius, height: stubLen, slices: 24)
                .rotated(by: Euclid.Rotation.roll(.halfPi))
                .translated(by: Vector(cx, placement.position.y, bz))
        case .r90:
            let edge = outline.maxY
            let cy = edge + stubLen / 2
            return Mesh.cylinder(radius: radius, height: stubLen, slices: 24)
                .translated(by: Vector(placement.position.x, cy, bz))
        case .r270:
            let edge = outline.minY
            let cy = edge - stubLen / 2
            return Mesh.cylinder(radius: radius, height: stubLen, slices: 24)
                .translated(by: Vector(placement.position.x, cy, bz))
        }
    }

    /// Gate sense volume: the dimple cavity. Hemispherical-ish cylinder
    /// recessed into the silicone-facing surface of the placement's plate.
    private static func gateBody(
        placement: Placement, m: ManufacturingConstants,
        topInnerZ: Double, bottomInnerZ: Double
    ) -> Mesh {
        let radius = m.dimpleDiameter / 2
        let depth = m.dimpleDepth
        let cz: Double
        switch placement.layer {
        case .top:    cz = topInnerZ + depth / 2          // recessed upward
        case .bottom: cz = bottomInnerZ - depth / 2       // recessed downward
        }
        return Mesh.cylinder(radius: radius, height: depth, slices: 32)
            .rotated(by: Euclid.Rotation.pitch(.halfPi))
            .translated(by: Vector(placement.position.x, placement.position.y, cz))
    }

    /// Closed-by-default slab that bridges the two source/drain drop bores
    /// across the silicone gap. Silicone seals it until the matching gate
    /// pulls it open; once open, the slab volume connects bore A to bore B.
    ///
    /// The slab spans the full silicone gap in Z, with a small overhang into
    /// both plates so that it reliably overlaps the bore tops in the
    /// simulator's voxel grid (each bore terminates at its plate's
    /// silicone-facing surface). In XY it covers both bores by at least one
    /// full bore diameter past each pin centre — slimmer margins lose the
    /// connection when the importer rounds to its cell size.
    private static func blockerBody(
        placement: Placement, footprint: Footprint, m: ManufacturingConstants,
        topInnerZ: Double, bottomInnerZ: Double
    ) -> Mesh {
        guard let pinA = footprint.pin("a"), let pinB = footprint.pin("b") else { return .empty }
        let aWorld = placement.worldPosition(of: pinA)
        let bWorld = placement.worldPosition(of: pinB)
        let centerXY = Point(x: (aWorld.x + bWorld.x) / 2, y: (aWorld.y + bWorld.y) / 2)
        let pinPitch = ((aWorld.x - bWorld.x) * (aWorld.x - bWorld.x)
                      + (aWorld.y - bWorld.y) * (aWorld.y - bWorld.y)).squareRoot()
        let theta = atan2(bWorld.y - aWorld.y, bWorld.x - aWorld.x)

        let boreOverlap = 0.3
        let length = pinPitch + 2 * m.channelDiameter
        let height = m.channelDiameter + 0.6
        let thickness = m.siliconeThickness + 2 * boreOverlap
        let centerZ = (topInnerZ + bottomInnerZ) / 2

        return Mesh.cube(center: .zero, size: Vector(length, height, thickness))
            .rotated(by: Euclid.Rotation.yaw(.radians(theta)))
            .translated(by: Vector(centerXY.x, centerXY.y, centerZ))
    }

    // MARK: - Misc

    private static func localToWorld(_ p: Point, placement: Placement) -> Point {
        let r = placement.rotation.radians
        let c = cos(r), s = sin(r)
        return Point(
            x: placement.position.x + p.x * c - p.y * s,
            y: placement.position.y + p.x * s + p.y * c
        )
    }
}
