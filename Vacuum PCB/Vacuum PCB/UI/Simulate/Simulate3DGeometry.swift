import Foundation
import Euclid

/// Render model for the Simulate tab's 3D view: the routed channel network
/// (plus the component cavities air moves through) as loose display meshes,
/// each tagged with where its pressure tint comes from on a publish, and the
/// polylines the flow-dot animation marches along.
///
/// Pure geometry — no SceneKit. Built off the main thread per network
/// revision (`Simulate3DModel`), then `Simulate3DSceneView` turns each unit
/// into one tintable node. Meshes are concatenated primitives, not CSG
/// unions, same trick as `PlateBuilder.volumeMesh`: internal faces are
/// invisible on an opaque solid and skipping the boolean keeps a full-board
/// rebuild cheap.
///
/// The tint units deliberately mirror `SimulatePhysicalCanvas`:
///   * channel spans colour by *local* pressure — each same-layer run of a
///     span's polyline interpolates between the span's two solved end
///     pressures at the run's arc-length midpoint, so supply-run sag reads in
///     3D exactly as it does in the 2D heatmap (flat per-net colour when
///     channel resistance is 0, because the engine mirrors hub pressures);
///   * layer changes inside a span become *vertical* via tubes — geometry the
///     2D view has to drop as zero-length;
///   * nets whose channel graph kept no drawable geometry fall back to raw
///     route tubes at hub pressure.
///
/// The flow paths mirror `FlowOverlayCache`'s candidates (span runs, resistor
/// serpentines, transistor source→drain bridges) with the same
/// node1 → node2 ordering, so `FlowReport`'s signed flows drive dot direction
/// unchanged — plus the vertical via runs, which carry their span's flow.
struct Simulate3DGeometry {

    /// Where a unit's tint comes from each publish. Optional net ids follow
    /// the 2D canvases' convention for unconnected pins: no net = sitting at
    /// atmosphere, not invisible.
    enum PressureSource {
        /// Interpolate between two solver nodes' pressures at parameter `t`
        /// (0 = node1, 1 = node2) — a channel-span run or its via tie.
        case spanInterpolated(node1: UUID, node2: UUID, t: Double)
        /// A canonical flattened net's hub pressure.
        case net(UUID?)
        /// A pre-merge net id (test points store this level's id).
        case rawNet(UUID)
        /// Mean of two nets — the resistor-body convention shared with the
        /// 2D canvases.
        case mean(UUID?, UUID?)
    }

    /// One tintable solid in the scene.
    struct Unit {
        let mesh: Mesh
        let source: PressureSource
        /// Layers whose visibility pills control this unit; hidden when none
        /// is visible. Empty = always visible.
        let layers: [Layer]
        /// Transistor component whose open fraction drives a subtle emissive
        /// bump on the gate dome (the 2D view's inner-dot equivalent).
        var opennessComponent: UUID? = nil
        /// LED "p" net: the unit glows lit-yellow as
        /// `params.gateOpenness(forPressure:)` rises, like the 2D body.
        var ledNet: UUID? = nil
    }

    /// Where a flow path's per-publish Q comes from. Mirrors
    /// `FlowOverlayCache.Source`.
    enum FlowSource {
        case span(Int)           // index into channelGraph.spans / spanFlows
        case resistor(UUID)
        case transistor(UUID)
    }

    /// One world-mm polyline dots can march along, ordered so positive flow
    /// runs first → last (the solver's node1 → node2 convention).
    struct FlowPath {
        let source: FlowSource
        let points: [Vector]
        /// Arc-length table aligned with `points` (`cumLengths[0] == 0`),
        /// true 3D length so vertical via runs pace correctly.
        let cumLengths: [Double]
        /// Hidden when none of these layers is visible.
        let layers: [Layer]

        var totalLength: Double { cumLengths.last ?? 0 }

        /// Point at arc position `s`, clamped to the path.
        func point(at s: Double) -> Vector {
            guard let total = cumLengths.last, total > 0 else { return points.first ?? .zero }
            let s = max(0, min(s, total))
            // Paths are short (a handful of waypoints); linear scan beats
            // binary search bookkeeping at these sizes.
            var i = 1
            while i < cumLengths.count - 1 && cumLengths[i] < s { i += 1 }
            let a = cumLengths[i - 1], b = cumLengths[i]
            let t = b > a ? (s - a) / (b - a) : 0
            return points[i - 1] + (points[i] - points[i - 1]) * t
        }

        init(source: FlowSource, points: [Vector], layers: [Layer]) {
            self.source = source
            self.points = points
            var cum: [Double] = [0]
            cum.reserveCapacity(points.count)
            for i in 1..<max(1, points.count) {
                cum.append(cum[i - 1] + (points[i] - points[i - 1]).length)
            }
            self.cumLengths = cum
            self.layers = layers
        }
    }

    var units: [Unit] = []
    var flowPaths: [FlowPath] = []
    /// Ghost printed body: plain slabs (no CSG carve — this view is about the
    /// air, not the plastic), rendered translucent like the Preview's plates.
    var topSlab: Mesh = .empty
    var bottomSlab: Mesh = .empty
    var sheetSlab: Mesh = .empty
    var boardOutline: Rect = Rect(origin: Point(x: 0, y: 0), size: Size(width: 0, height: 0))
    /// Channel radius (mm) — sizes the flow dots.
    var channelRadius: Double = 1

    static let empty = Simulate3DGeometry()

    // MARK: - Build

    /// Decompose the simulator's flattened document + network into display
    /// units. Pure value-in/value-out so it can run on a background queue;
    /// same inputs the 2D physical canvas renders from.
    static func build(flat: CircuitDocument, network: PneumaticNetwork) -> Simulate3DGeometry {
        let m = flat.manufacturing
        var g = Simulate3DGeometry()
        g.boardOutline = flat.physical.boardOutline
        g.channelRadius = m.channelDiameter / 2

        let channelR = m.channelDiameter / 2
        let graph = network.channelGraph

        // ── Channel spans: same-layer runs + vertical via ties ─────────────
        var spanCovered = Set<UUID>()
        for (i, span) in graph.spans.enumerated() where span.polyline.count >= 2 {
            let hub = graph.hubBySubNode[span.node1] ?? span.node1
            spanCovered.insert(hub)

            // Arc-length parameterisation for the tint interpolation. Matches
            // the 2D canvas: layer-change pairs (via bores) contribute no
            // length, so both views agree on where along the span a point is.
            var cum: [Double] = [0]
            for k in 1..<span.polyline.count {
                let a = span.polyline[k - 1], b = span.polyline[k]
                let d = a.layer == b.layer ? hypot(b.p.x - a.p.x, b.p.y - a.p.y) : 0
                cum.append(cum[k - 1] + d)
            }
            let total = cum[cum.count - 1]
            func tint(_ lo: Double, _ hi: Double) -> PressureSource {
                let t = total > 0 ? (lo + hi) / (2 * total) : 0.5
                return .spanInterpolated(node1: span.node1, node2: span.node2, t: t)
            }

            var run: [Point] = []
            var runStart = 0.0
            func flushRun(endCum: Double, layer: Layer) {
                guard run.count >= 2 else { run = []; return }
                let z = m.midZ(for: layer)
                g.units.append(Unit(mesh: tubeMesh(waypoints: run, radius: channelR, midZ: z),
                                    source: tint(runStart, endCum),
                                    layers: [layer]))
                g.flowPaths.append(FlowPath(source: .span(i),
                                            points: run.map { Vector($0.x, $0.y, z) },
                                            layers: [layer]))
                run = []
            }

            for k in 1..<span.polyline.count {
                let a = span.polyline[k - 1], b = span.polyline[k]
                if a.layer == b.layer {
                    if run.isEmpty { runStart = cum[k - 1] }
                    if run.isEmpty { run.append(a.p) }
                    run.append(b.p)
                    if k == span.polyline.count - 1 { flushRun(endCum: cum[k], layer: a.layer) }
                } else {
                    // Layer change: close the current run, then emit the via
                    // bore as a vertical tube. The 2D overlay drops these as
                    // zero-length; in 3D they're the payoff — dots climb
                    // between layers.
                    flushRun(endCum: cum[k - 1], layer: a.layer)
                    let zA = m.midZ(for: a.layer), zB = m.midZ(for: b.layer)
                    g.units.append(Unit(mesh: verticalTube(at: a.p, radius: channelR, z1: zA, z2: zB),
                                        source: tint(cum[k - 1], cum[k]),
                                        layers: [a.layer, b.layer]))
                    g.flowPaths.append(FlowPath(source: .span(i),
                                                points: [Vector(a.p.x, a.p.y, zA),
                                                         Vector(b.p.x, b.p.y, zB)],
                                                layers: [a.layer, b.layer]))
                }
            }
        }

        // ── Route fallback for nets whose graph kept no drawable geometry ──
        for route in flat.physical.routes where !spanCovered.contains(route.netId) {
            for segment in route.segments {
                let pts = segment.waypoints.map(\.position)
                guard pts.count >= 2 else { continue }
                g.units.append(Unit(mesh: tubeMesh(waypoints: pts, radius: channelR,
                                                   midZ: m.midZ(for: segment.layer)),
                                    source: .net(route.netId),
                                    layers: [segment.layer]))
            }
        }

        // ── Component cavities ──────────────────────────────────────────────
        let netByPin = PneumaticNetwork.pinToNetMap(flat)
        let componentById = Dictionary(flat.logic.components.map { ($0.id, $0) },
                                       uniquingKeysWith: { a, _ in a })
        let topInnerZ = m.siliconeThickness / 2
        let bottomInnerZ = -m.siliconeThickness / 2
        let outline = flat.physical.boardOutline

        for placement in flat.physical.placements {
            guard let component = componentById[placement.componentId] else { continue }
            let placementLayer = Layer(plate: placement.layer, depth: placement.depth)

            func net(_ pinKey: String) -> UUID? {
                netByPin[PinRef(componentId: component.id, pinKey: pinKey)]
            }
            func world(_ local: Point) -> Point {
                let c = cos(placement.rotation.radians), s = sin(placement.rotation.radians)
                return Point(x: placement.position.x + local.x * c - local.y * s,
                             y: placement.position.y + local.x * s + local.y * c)
            }

            switch component.kind {
            case .resistor:
                let local = ResistorGeometry.path(
                    transitions: ResistorGeometry.transitions(for: component.resistorSize ?? .medium),
                    halfLen: ManufacturingConstants.resistorFootprintLength / 2,
                    halfWid: ManufacturingConstants.resistorFootprintWidth / 2
                )
                guard local.count >= 2 else { continue }
                let pts = local.map(world)
                let z = m.midZ(for: placementLayer)
                g.units.append(Unit(mesh: tubeMesh(waypoints: pts,
                                                   radius: m.resistorChannelDiameter / 2, midZ: z),
                                    source: .mean(net("1"), net("2")),
                                    layers: [placementLayer]))
                g.flowPaths.append(FlowPath(source: .resistor(component.id),
                                            points: pts.map { Vector($0.x, $0.y, z) },
                                            layers: [placementLayer]))

            case .transistor:
                // Gate dome on the placement plate, tinted by the gate net.
                g.units.append(Unit(mesh: PlateBuilder.dimpleMesh(
                                        at: placement.position, layer: placement.layer, m: m,
                                        topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ),
                                    source: .net(net("gate")),
                                    layers: [placementLayer],
                                    opennessComponent: component.id))
                // Source/drain pad lobes on the opposite plate, one per pin
                // net. Both candidate lobes are built and each pin takes the
                // nearer one — the lathe handedness flips sides with rotation
                // (see PlateBuilder.volumeMesh), so a fixed mapping is wrong.
                let fp = component.footprint(m)
                let oppPlate = placement.layer.opposite
                let oppZ = oppPlate == .top ? topInnerZ : bottomInnerZ
                let oppLayer = Layer(plate: oppPlate, depth: 0)
                if let pinA = fp.pin("a"), let pinB = fp.pin("b") {
                    func placedLobe(_ positive: Bool) -> Mesh {
                        PlateBuilder.padLobeSolid(R: m.padsDiameter / 2, sep: m.padsSeparation,
                                                  fillet: m.padsFilletRadius, positiveSide: positive)
                            .rotated(by: Euclid.Rotation.roll(.radians(placement.rotation.radians)))
                            .translated(by: Vector(placement.position.x, placement.position.y, oppZ))
                    }
                    func centroid(_ mesh: Mesh) -> Point {
                        let b = mesh.bounds
                        return Point(x: (b.min.x + b.max.x) / 2, y: (b.min.y + b.max.y) / 2)
                    }
                    func dist2(_ p: Point, _ q: Point) -> Double {
                        (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)
                    }
                    let lobes = [placedLobe(true), placedLobe(false)]
                    let centers = lobes.map(centroid)
                    let aWorld = world(pinA.offset), bWorld = world(pinB.offset)
                    // Pin "a" takes its nearest lobe, pin "b" the other.
                    let aIdx = dist2(centers[0], aWorld) <= dist2(centers[1], aWorld) ? 0 : 1
                    g.units.append(Unit(mesh: lobes[aIdx], source: .net(net("a")), layers: [oppLayer]))
                    g.units.append(Unit(mesh: lobes[1 - aIdx], source: .net(net("b")), layers: [oppLayer]))
                    g.flowPaths.append(FlowPath(source: .transistor(component.id),
                                                points: [Vector(aWorld.x, aWorld.y, oppZ),
                                                         Vector(bWorld.x, bWorld.y, oppZ)],
                                                layers: [oppLayer]))
                }

            case .led:
                g.units.append(Unit(mesh: PlateBuilder.ledDimpleMesh(
                                        at: placement.position, layer: placement.layer, m: m,
                                        topInnerZ: topInnerZ, bottomInnerZ: bottomInnerZ),
                                    source: .net(net("p")),
                                    layers: [placementLayer],
                                    ledNet: net("p")))

            case .port, .vacuumSource, .atmVent:
                g.units.append(Unit(mesh: PlateBuilder.portBoreMesh(
                                        placement: placement, outline: outline, m: m,
                                        topMidZ: m.midZ(for: .top), bottomMidZ: m.midZ(for: .bottom)),
                                    source: .net(net("p")),
                                    layers: [placementLayer]))

            case .subpart, .screw, .connector:
                // Screws are air-inert; connector socket geometry is CAD-only
                // detail (their nets still show through the routed channels);
                // subpart markers were inlined by the flatten.
                break
            }
        }

        // ── Testing points: vertical probe bores, tinted like the 2D rings ──
        let topOuterZ = topInnerZ + m.plateThickness(forLayerCount: flat.physical.topLayers)
        let bottomOuterZ = bottomInnerZ - m.plateThickness(forLayerCount: flat.physical.bottomLayers)
        for tp in flat.physical.testPoints {
            guard let world = flat.physical.testPointWorld(tp) else { continue }
            let layer = Layer(plate: tp.plate, depth: tp.depth)
            g.units.append(Unit(mesh: PlateBuilder.testPointBoreSolid(
                                    at: world, plate: tp.plate,
                                    innerZ: m.midZ(for: layer),
                                    outerZ: tp.plate == .top ? topOuterZ : bottomOuterZ,
                                    m: m),
                                source: .rawNet(tp.netId),
                                layers: [layer]))
        }

        // ── Ghost body slabs ────────────────────────────────────────────────
        let cx = outline.origin.x + outline.size.width / 2
        let cy = outline.origin.y + outline.size.height / 2
        func slab(zLo: Double, zHi: Double) -> Mesh {
            guard outline.size.width > 0, outline.size.height > 0, zHi > zLo else { return .empty }
            return Mesh.cube(center: Vector(cx, cy, (zLo + zHi) / 2),
                             size: Vector(outline.size.width, outline.size.height, zHi - zLo))
        }
        g.topSlab = slab(zLo: topInnerZ, zHi: topOuterZ)
        g.bottomSlab = slab(zLo: bottomOuterZ, zHi: bottomInnerZ)
        g.sheetSlab = slab(zLo: bottomInnerZ, zHi: topInnerZ)

        return g
    }

    // MARK: - Primitives

    /// Loose channel tube: junction spheres + connecting cylinders,
    /// concatenated (no CSG). Same construction — and the same
    /// roll(π/2 − θ) cylinder orientation convention — as
    /// `PlateBuilder.channelMesh`, minus the boolean union and the printable
    /// flat floor, neither of which a tinted display solid needs.
    static func tubeMesh(waypoints: [Point], radius: Double, midZ: Double) -> Mesh {
        guard waypoints.count >= 2 else { return .empty }
        var polys: [Euclid.Polygon] = []
        for p in waypoints {
            polys += Mesh.sphere(radius: radius + 0.005, slices: 12)
                .translated(by: Vector(p.x, p.y, midZ))
                .polygons
        }
        for i in 0..<(waypoints.count - 1) {
            let a = waypoints[i], b = waypoints[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > 0 else { continue }
            let theta = atan2(dy, dx)
            polys += Mesh.cylinder(radius: radius, height: len, slices: 12)
                .rotated(by: Euclid.Rotation.roll(.radians(.pi / 2 - theta)))
                .translated(by: Vector((a.x + b.x) / 2, (a.y + b.y) / 2, midZ))
                .polygons
        }
        return Mesh(polys)
    }

    /// Vertical via tube between two channel-layer midlines. Same pitched
    /// cylinder as `PlateBuilder.viaCutterMesh`, without the CSG overshoot.
    static func verticalTube(at p: Point, radius: Double, z1: Double, z2: Double) -> Mesh {
        let lo = min(z1, z2), hi = max(z1, z2)
        guard hi > lo else { return .empty }
        return Mesh.cylinder(radius: radius, height: hi - lo, slices: 12)
            .rotated(by: Euclid.Rotation.pitch(.halfPi))
            .translated(by: Vector(p.x, p.y, (lo + hi) / 2))
    }
}
