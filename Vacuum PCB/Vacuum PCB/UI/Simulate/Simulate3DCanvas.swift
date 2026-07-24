import SwiftUI
import SceneKit
import Euclid

/// Read-only 3D view of the live simulation: the routed channel network as
/// solid tubes inside a ghosted printed body, every tube tinted by its local
/// pressure, with the physical view's marching-dot mass-flow animation
/// running along the same paths in 3D (including up the via bores, which the
/// 2D overlay has to drop as zero-length).
///
/// Rendering follows the two-rate split the Simulate tab is built around
/// (see `SimulationClock` / `FlowOverlayView` for the war stories):
///   * `body` re-evaluates on the ~20 Hz publish — it derives a plain-value
///     `Simulate3DFrame` (colour steps + per-path flow strengths) and hands
///     it to the representable, which mutates only the SceneKit materials
///     whose quantised colour actually moved;
///   * the dot animation runs on a 30 Hz main-thread timer owned by the
///     coordinator, touching only pre-built nodes — no SwiftUI evaluation,
///     no observable reads, freezes with the transport.
///
/// Geometry (tube meshes, component cavities, dot polylines) rebuilds off
/// the main thread only when `SimulationState.networkRevision` moves, same
/// invalidation the 2D overlay cache keys on.
///
/// Assembly documents render at their flattened (stacked) coordinates — the
/// mated world-space layout the 2D canvas shows stays a 2D-only feature for
/// now.
struct Simulate3DCanvas: View {
    /// Parent document — used for the board outline (framing) only; all
    /// rendered content comes from the simulator's flattened snapshot.
    let document: CircuitDocument
    let state: SimulationState
    let visible: LayerVisibility
    let showFlow: Bool
    /// Ghosted printed-body slabs on/off (toolbar "Body" toggle).
    let showBody: Bool
    /// Owned by DocumentView so orbit / zoom survive tab switches.
    let cameraStore: Scene3DCameraStore?

    @State private var model = Simulate3DModel()

    var body: some View {
        let revision = state.networkRevision
        ZStack {
            if let built = model.built {
                Simulate3DSceneView(
                    geometry: built,
                    geometryRevision: model.builtRevision,
                    frame: Self.makeFrame(geometry: built, state: state),
                    visible: visible,
                    showFlow: showFlow,
                    showBody: showBody,
                    cameraStore: cameraStore
                )
            } else {
                ProgressView("Building 3D view…")
            }
            if model.built != nil && model.builtRevision != revision {
                ProgressView("Rebuilding…")
                    .padding(10)
                    .glassEffect(in: .rect(cornerRadius: 10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 12)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            model.requestBuild(revision: revision, flat: state.flattenedDoc,
                               network: state.network)
        }
        .onChange(of: revision) { _, new in
            model.requestBuild(revision: new, flat: state.flattenedDoc,
                               network: state.network)
        }
    }

    /// Resolve every unit's tint and every flow path's strength from the
    /// currently *published* state. Reading `pressureByNet` / `flows` /
    /// `transistorOpenness` here (inside `body`) is what re-invokes this view
    /// on the 20 Hz publish — the representable below never reads observables.
    @MainActor
    static func makeFrame(geometry: Simulate3DGeometry, state: SimulationState) -> Simulate3DFrame {
        let maxVac = state.params.pumpMaxVacuum

        var tintSteps: [Int] = []
        var emissionSteps: [Int] = []
        var glowSteps: [Int] = []
        tintSteps.reserveCapacity(geometry.units.count)
        emissionSteps.reserveCapacity(geometry.units.count)
        glowSteps.reserveCapacity(geometry.units.count)

        for unit in geometry.units {
            // Unconnected pins (nil net) sit at atmosphere — the 2D bodies'
            // convention for missing `netByPin` entries.
            func pressure(_ id: UUID?) -> Double {
                id.map { state.pressure(net: $0) } ?? 1.0
            }
            let p: Double
            switch unit.source {
            case .spanInterpolated(let n1, let n2, let t):
                let p1 = state.pressure(net: n1), p2 = state.pressure(net: n2)
                p = p1 + (p2 - p1) * t
            case .net(let id):
                p = pressure(id)
            case .rawNet(let id):
                p = state.pressure(rawNet: id)
            case .mean(let a, let b):
                p = (pressure(a) + pressure(b)) / 2
            }
            let ramp = PressureColor.rampPosition(for: p, maxVacuum: maxVac)
            tintSteps.append(Int((ramp * Double(Simulate3DFrame.tintStepCount - 1)).rounded()))

            let openness = unit.opennessComponent.flatMap { state.transistorOpenness[$0] } ?? 0
            emissionSteps.append(Int((max(0, min(1, openness)) * 24).rounded()))

            let lit = unit.ledNet
                .map { state.params.gateOpenness(forPressure: state.pressure(net: $0)) } ?? 0
            glowSteps.append(Int((max(0, min(1, lit)) * 24).rounded()))
        }

        // Flow strengths, normalised exactly like the 2D overlay: full scale
        // is the pump's free-flow ceiling, falling back to the largest live
        // component flow on pump-less (bus-driven) fixtures.
        let flows = state.flows
        var qRef = flows.pumpFreeFlowMax
        if qRef <= 0 {
            qRef = max(flows.flowByResistor.values.map { abs($0) }.max() ?? 0,
                       flows.flowByTransistor.values.map { abs($0) }.max() ?? 0)
        }
        let qMin = qRef * 0.01

        var strengths: [Float] = []
        var reversed: [Bool] = []
        strengths.reserveCapacity(geometry.flowPaths.count)
        reversed.reserveCapacity(geometry.flowPaths.count)
        for path in geometry.flowPaths {
            let q: Double
            switch path.source {
            case .span(let s):        q = s < flows.spanFlows.count ? flows.spanFlows[s] : 0
            case .resistor(let id):   q = flows.flowByResistor[id] ?? 0
            case .transistor(let id): q = flows.flowByTransistor[id] ?? 0
            }
            if qRef > 0 && abs(q) >= qMin {
                strengths.append(Float(min(1.0, abs(q) / qRef)))
            } else {
                strengths.append(0)
            }
            reversed.append(q < 0)
        }

        return Simulate3DFrame(tintSteps: tintSteps,
                               emissionSteps: emissionSteps,
                               glowSteps: glowSteps,
                               flowStrengths: strengths,
                               flowReversed: reversed,
                               isPlaying: state.isPlaying,
                               timeScale: state.params.timeScale)
    }
}

/// Plain-value snapshot of one publish, handed from SwiftUI to the SceneKit
/// coordinator. Everything quantised so the apply pass can skip untouched
/// materials.
struct Simulate3DFrame {
    static let tintStepCount = 96

    /// Per-unit colour LUT index (0…tintStepCount-1), aligned with
    /// `Simulate3DGeometry.units`.
    var tintSteps: [Int] = []
    /// Per-unit transistor-openness emissive bump, quantised 0…24.
    var emissionSteps: [Int] = []
    /// Per-unit LED lit glow, quantised 0…24.
    var glowSteps: [Int] = []
    /// Per-path |Q| / reference (0 = below threshold), aligned with
    /// `Simulate3DGeometry.flowPaths`.
    var flowStrengths: [Float] = []
    var flowReversed: [Bool] = []
    var isPlaying: Bool = false
    var timeScale: Double = 1

    static let idle = Simulate3DFrame()
}

/// Off-main geometry cache for the 3D Simulate view. Same shape as
/// DocumentView's preview `rebuild()`: capture value snapshots, build on a
/// utility queue, deliver on main with a token check so a stale build can't
/// clobber a newer one.
@MainActor
@Observable
final class Simulate3DModel {
    private(set) var built: Simulate3DGeometry?
    private(set) var builtRevision: Int = .min
    @ObservationIgnored private var inFlightRevision: Int?

    func requestBuild(revision: Int, flat: CircuitDocument, network: PneumaticNetwork) {
        guard builtRevision != revision, inFlightRevision != revision else { return }
        inFlightRevision = revision
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let geometry = Simulate3DGeometry.build(flat: flat, network: network)
            DispatchQueue.main.async {
                self?.finishBuild(revision: revision, geometry: geometry)
            }
        }
    }

    private func finishBuild(revision: Int, geometry: Simulate3DGeometry) {
        guard inFlightRevision == revision else { return }
        inFlightRevision = nil
        built = geometry
        builtRevision = revision
    }
}

/// SceneKit-backed scene: one node per tint unit, ghost body slabs, and a
/// pooled dot swarm for the flow animation. Mirrors `Scene3DView`'s camera /
/// framing / pose-persistence behaviour so the two 3D views feel identical
/// in the hand.
struct Simulate3DSceneView {
    var geometry: Simulate3DGeometry
    var geometryRevision: Int
    var frame: Simulate3DFrame
    var visible: LayerVisibility
    var showFlow: Bool
    var showBody: Bool
    var cameraStore: Scene3DCameraStore?

    // MARK: Coordinator

    final class Coordinator: NSObject {
        let scene = SCNScene()
        let modelRoot = SCNNode()
        let unitsRoot = SCNNode()
        let dotsRoot = SCNNode()
        let topSlabNode = SCNNode()
        let bottomSlabNode = SCNNode()
        let sheetSlabNode = SCNNode()
        let camera = SCNCamera()
        let cameraNode = SCNNode()
        var cameraStore: Scene3DCameraStore?
        var lastOutline: Rect?
        var geometryRevision: Int = .min

        // Aligned with geometry.units.
        var units: [Simulate3DGeometry.Unit] = []
        var unitNodes: [SCNNode] = []
        var unitMaterials: [SCNMaterial] = []
        var lastTint: [Int] = []
        var lastEmission: [Int] = []
        var lastGlow: [Int] = []

        // Aligned with geometry.flowPaths.
        var flowPaths: [Simulate3DGeometry.FlowPath] = []
        var pathVisible: [Bool] = []
        var phases: [Double] = []

        var frame: Simulate3DFrame = .idle
        var showFlow = true
        var lastVisible: LayerVisibility?
        /// Dot spacing (mm) after the pool-budget stretch; recomputed each
        /// publish from the active path set.
        var effectivePeriod: Double = 6
        var basePeriod: Double = 6
        var dotRadius: Double = 0.6

        var dotPool: [SCNNode] = []
        /// One shared geometry per strength bucket — swapping a node's bucket
        /// is a reference assignment, no copies.
        var bucketGeometries: [SCNGeometry] = []
        var timer: Timer?
        var lastTickAt: CFTimeInterval?

        /// Colour LUT indexed by tint step; built once.
        let colorLUT: [PlatformColor] = (0..<Simulate3DFrame.tintStepCount).map {
            PressureColor.platformStrokeColor(
                rampPosition: Double($0) / Double(Simulate3DFrame.tintStepCount - 1))
        }

        deinit {
            timer?.invalidate()
        }

        // MARK: Dot animation clock

        /// 30 Hz march. Touches only pre-built nodes and plain values — no
        /// SwiftUI, no observables — and does nothing while paused, so a
        /// paused (or flow-hidden) tab costs zero.
        func tick() {
            let now = CACurrentMediaTime()
            let dt = min(0.1, now - (lastTickAt ?? now))
            lastTickAt = now
            guard frame.isPlaying, showFlow, !dotsRoot.isHidden else { return }

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            defer { SCNTransaction.commit() }

            let period = effectivePeriod
            // Anti-wagon-wheel cap, same rationale as the 2D overlay: a dash
            // pattern advancing ≈ its period per frame reads as stuck.
            let maxWallSpeed = period * 30.0 / 3.5
            let ts = max(0.1, frame.timeScale)

            var poolIdx = 0
            for (i, path) in flowPaths.enumerated() {
                let strength = i < frame.flowStrengths.count ? Double(frame.flowStrengths[i]) : 0
                guard strength > 0, pathVisible[i] else { continue }
                let total = path.totalLength
                guard total > 0.01 else { continue }

                // √ mapping compresses leak crawl → pump draw into a readable
                // speed range; direction flips with the flow's sign.
                let wallSpeed = min(maxWallSpeed, 9.0 * strength.squareRoot() * ts.squareRoot())
                let delta = dt * wallSpeed
                phases[i] += (i < frame.flowReversed.count && frame.flowReversed[i]) ? -delta : delta
                phases[i] = phases[i].truncatingRemainder(dividingBy: period)

                let phase = phases[i] < 0 ? phases[i] + period : phases[i]
                let bucket = min(7, max(0, Int(strength * 8)))
                var s = phase.truncatingRemainder(dividingBy: period)
                if s > total { continue }
                while s <= total {
                    guard poolIdx < dotPool.count else { break }
                    let node = dotPool[poolIdx]
                    node.position = SCNVector3(path.point(at: s))
                    if node.geometry !== bucketGeometries[bucket] {
                        node.geometry = bucketGeometries[bucket]
                    }
                    node.isHidden = false
                    poolIdx += 1
                    s += period
                }
            }
            for j in poolIdx..<dotPool.count {
                dotPool[j].isHidden = true
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: Scene construction

    fileprivate func makeSCNView(coordinator c: Coordinator) -> SCNView {
        let view = SCNView()
        view.scene = c.scene
        #if canImport(AppKit)
        view.backgroundColor = NSColor.windowBackgroundColor
        #elseif canImport(UIKit)
        view.backgroundColor = UIColor.systemBackground
        #endif
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false

        c.scene.rootNode.addChildNode(c.modelRoot)
        c.modelRoot.addChildNode(c.unitsRoot)
        c.modelRoot.addChildNode(c.dotsRoot)
        c.modelRoot.addChildNode(c.topSlabNode)
        c.modelRoot.addChildNode(c.bottomSlabNode)
        c.modelRoot.addChildNode(c.sheetSlabNode)

        c.camera.usesOrthographicProjection = true
        c.camera.zNear = 0.01
        c.camera.zFar = 10_000
        c.cameraNode.camera = c.camera
        c.cameraNode.name = "Main Camera"
        c.scene.rootNode.addChildNode(c.cameraNode)
        view.pointOfView = c.cameraNode

        addLights(to: c.scene)

        rebuildNodes(coordinator: c)
        applyVisibility(coordinator: c)
        applyFrame(coordinator: c)
        c.showFlow = showFlow
        c.dotsRoot.isHidden = !showFlow
        applyBodyVisibility(coordinator: c)
        applyFraming(coordinator: c, animated: false)
        configureCameraController(view.defaultCameraController, target: SCNVector3Zero)

        // Replay the orbit / zoom from a previous visit; the pivot is pinned
        // to the model centroid (origin) so a stale pose still points at the
        // board. Same contract as Scene3DView.
        c.cameraStore = cameraStore
        if let pose = cameraStore?.pose {
            c.cameraNode.transform = pose.transform
            c.camera.orthographicScale = pose.orthographicScale
        }

        // The dot clock: a plain repeating timer (not a TimelineView, not a
        // renderer delegate) so the march never touches SwiftUI evaluation
        // and stays on the main thread with the rest of the scene mutations.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak c] _ in
            c?.tick()
        }
        timer.tolerance = 1.0 / 120.0
        RunLoop.main.add(timer, forMode: .common)
        c.timer = timer

        return view
    }

    fileprivate static func capturePose(view: SCNView, coordinator c: Coordinator) {
        c.timer?.invalidate()
        c.timer = nil
        guard let store = c.cameraStore, let pov = view.pointOfView else { return }
        store.pose = Scene3DCameraPose(
            transform: pov.presentation.transform,
            orthographicScale: (pov.camera ?? c.camera).orthographicScale
        )
    }

    fileprivate func refresh(view: SCNView, coordinator c: Coordinator) {
        if c.geometryRevision != geometryRevision {
            rebuildNodes(coordinator: c)
            c.lastVisible = nil
        }
        if c.lastVisible != visible {
            applyVisibility(coordinator: c)
        }
        applyFrame(coordinator: c)
        c.showFlow = showFlow
        c.dotsRoot.isHidden = !showFlow
        applyBodyVisibility(coordinator: c)
        c.cameraStore = cameraStore
        if c.lastOutline != geometry.boardOutline {
            applyFraming(coordinator: c, animated: true)
        }
    }

    /// Rebuild every scene node from the freshly built geometry. Runs only
    /// when the network revision moves (document edits), not on publishes.
    private func rebuildNodes(coordinator c: Coordinator) {
        c.unitsRoot.childNodes.forEach { $0.removeFromParentNode() }
        c.units = geometry.units
        c.unitNodes = []
        c.unitMaterials = []
        c.unitNodes.reserveCapacity(geometry.units.count)
        c.unitMaterials.reserveCapacity(geometry.units.count)
        for unit in geometry.units {
            let node = SCNNode()
            let material = SCNMaterial()
            material.lightingModel = .blinn
            material.isDoubleSided = false
            if !unit.mesh.isEmpty {
                let scnGeometry = SCNGeometry(unit.mesh)
                scnGeometry.materials = [material]
                node.geometry = scnGeometry
            }
            c.unitsRoot.addChildNode(node)
            c.unitNodes.append(node)
            c.unitMaterials.append(material)
        }
        c.lastTint = Array(repeating: -1, count: geometry.units.count)
        c.lastEmission = Array(repeating: -1, count: geometry.units.count)
        c.lastGlow = Array(repeating: -1, count: geometry.units.count)

        c.flowPaths = geometry.flowPaths
        c.phases = Array(repeating: 0, count: geometry.flowPaths.count)
        c.pathVisible = Array(repeating: true, count: geometry.flowPaths.count)
        c.basePeriod = max(3.0, geometry.channelRadius * 4.5)
        c.effectivePeriod = c.basePeriod
        c.dotRadius = max(0.25, geometry.channelRadius * 0.55)
        rebuildDotPool(coordinator: c)

        c.topSlabNode.geometry = slabGeometry(for: geometry.topSlab, color: .systemBlue)
        c.bottomSlabNode.geometry = slabGeometry(for: geometry.bottomSlab, color: .systemTeal)
        c.sheetSlabNode.geometry = slabGeometry(for: geometry.sheetSlab, color: .systemYellow)

        c.geometryRevision = geometryRevision
    }

    /// Pre-size the dot pool and the per-strength-bucket geometries. Pool
    /// size is bounded (`applyFrame` stretches the dot spacing when a board
    /// would need more), so the per-frame cost has a hard ceiling.
    private func rebuildDotPool(coordinator c: Coordinator) {
        c.dotsRoot.childNodes.forEach { $0.removeFromParentNode() }
        c.dotPool = []
        c.bucketGeometries = (0..<8).map { bucket in
            let sphere = SCNSphere(radius: CGFloat(c.dotRadius))
            sphere.segmentCount = 10
            let material = SCNMaterial()
            let strength = (Double(bucket) + 0.5) / 8.0
            material.lightingModel = .constant
            material.diffuse.contents = PlatformColor.systemOrange
            material.emission.contents = PlatformColor.systemOrange
            material.transparency = CGFloat(0.55 + 0.45 * strength)
            sphere.materials = [material]
            return sphere
        }
        let poolSize = min(Self.dotBudget,
                           max(64, Int(totalPathLength() / c.basePeriod) + c.flowPaths.count))
        c.dotPool.reserveCapacity(poolSize)
        for _ in 0..<poolSize {
            let node = SCNNode(geometry: c.bucketGeometries[7])
            node.isHidden = true
            c.dotsRoot.addChildNode(node)
            c.dotPool.append(node)
        }
    }

    /// Hard ceiling on animated dot nodes; beyond it the spacing stretches.
    private static let dotBudget = 1400

    private func totalPathLength() -> Double {
        geometry.flowPaths.reduce(0) { $0 + $1.totalLength }
    }

    /// Push one publish's tints into the materials, skipping any unit whose
    /// quantised (colour, openness, glow) triple didn't move — a settled
    /// board costs nothing here.
    private func applyFrame(coordinator c: Coordinator) {
        let f = frame
        c.frame = f
        guard f.tintSteps.count == c.unitMaterials.count else { return }

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        for i in 0..<c.unitMaterials.count {
            let tint = f.tintSteps[i]
            let emission = i < f.emissionSteps.count ? f.emissionSteps[i] : 0
            let glow = i < f.glowSteps.count ? f.glowSteps[i] : 0
            guard tint != c.lastTint[i] || emission != c.lastEmission[i] || glow != c.lastGlow[i]
            else { continue }
            c.lastTint[i] = tint
            c.lastEmission[i] = emission
            c.lastGlow[i] = glow

            let color = c.colorLUT[max(0, min(c.colorLUT.count - 1, tint))]
            let material = c.unitMaterials[i]
            material.diffuse.contents = color
            if glow > 0 {
                // LED lit: yellow glow rising with the gate-openness ramp,
                // the 3D reading of the 2D body's yellow fill.
                let lit = Double(glow) / 24.0
                material.emission.contents =
                    PlatformColor.systemYellow.withAlphaComponent(CGFloat(0.35 + 0.5 * lit))
            } else if emission > 0 {
                // Transistor open fraction: the dome brightens as the valve
                // opens (the 2D inner-dot equivalent).
                let open = Double(emission) / 24.0
                material.emission.contents =
                    color.withAlphaComponent(CGFloat(0.15 + 0.45 * open))
            } else {
                // Baseline: slightly emissive so features pop against the
                // ghost body, matching the Preview tab's channel materials.
                material.emission.contents = color.withAlphaComponent(0.15)
            }
        }
        SCNTransaction.commit()

        // Stretch the dot spacing when the active paths would exceed the
        // pool. Recomputed per publish — the active set is what changes.
        var activeLength = 0.0
        for (i, path) in c.flowPaths.enumerated()
        where i < f.flowStrengths.count && f.flowStrengths[i] > 0 && c.pathVisible[i] {
            activeLength += path.totalLength
        }
        let projected = Int(activeLength / c.basePeriod) + 1
        c.effectivePeriod = projected > c.dotPool.count
            ? activeLength / Double(c.dotPool.count)
            : c.basePeriod
    }

    /// Per-layer pill filter → node visibility. Unit and path visibility use
    /// the same rule as the 2D canvases: shown when any of the piece's
    /// layers is visible (a via tie stays visible while either of its two
    /// layers is).
    private func applyVisibility(coordinator c: Coordinator) {
        func isVisible(_ layers: [Layer]) -> Bool {
            layers.isEmpty || layers.contains(where: { visible.contains($0) })
        }
        for (i, unit) in c.units.enumerated() where i < c.unitNodes.count {
            c.unitNodes[i].isHidden = !isVisible(unit.layers)
        }
        for (i, path) in c.flowPaths.enumerated() {
            c.pathVisible[i] = isVisible(path.layers)
        }
        c.lastVisible = visible
    }

    private func applyBodyVisibility(coordinator c: Coordinator) {
        c.topSlabNode.isHidden = !showBody
        c.bottomSlabNode.isHidden = !showBody
        c.sheetSlabNode.isHidden = !showBody
    }

    // MARK: Materials

    /// Ghost printed-body slab: the Preview tab's translucent plate recipe
    /// (single-layer blend + depth write) at a fixed low opacity — enough to
    /// orient the tubes inside the board without competing with the tints.
    private func slabGeometry(for mesh: Mesh, color: PlatformColor) -> SCNGeometry? {
        guard !mesh.isEmpty else { return nil }
        let geometry = SCNGeometry(mesh)
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.transparency = 0.16
        material.transparencyMode = .singleLayer
        material.writesToDepthBuffer = true
        material.isDoubleSided = true
        material.lightingModel = .blinn
        geometry.materials = [material]
        return geometry
    }

    // MARK: Framing (mirrors Scene3DView)

    private func applyFraming(coordinator c: Coordinator, animated: Bool) {
        let outline = geometry.boardOutline
        let cx = outline.origin.x + outline.size.width / 2
        let cy = outline.origin.y + outline.size.height / 2
        let translate = SCNAction.move(to: SCNVector3(-cx, -cy, 0),
                                       duration: animated ? 0.25 : 0)
        c.modelRoot.runAction(translate)

        let diag = (outline.size.width * outline.size.width
                  + outline.size.height * outline.size.height).squareRoot()
        let viewSpan = max(diag, 20)
        c.camera.orthographicScale = viewSpan * 0.65

        let dist = viewSpan * 2.5
        let p = dist / sqrt(3.0)
        c.cameraNode.position = SCNVector3(p, -p, p)
        c.cameraNode.look(at: SCNVector3Zero, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))

        c.lastOutline = outline
    }

    private func configureCameraController(_ controller: SCNCameraController, target: SCNVector3) {
        controller.automaticTarget = false
        controller.target = target
        controller.interactionMode = .orbitAngleMapping
        controller.inertiaEnabled = true
        controller.inertiaFriction = 0.05
    }

    private func addLights(to scene: SCNScene) {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 180
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 700
        key.eulerAngles = SCNVector3(-Double.pi / 3, Double.pi / 6, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 350
        fill.eulerAngles = SCNVector3(-Double.pi / 6, -2 * Double.pi / 3, 0)
        scene.rootNode.addChildNode(fill)
    }
}

#if canImport(AppKit)
extension Simulate3DSceneView: NSViewRepresentable {
    func makeNSView(context: Context) -> SCNView { makeSCNView(coordinator: context.coordinator) }
    func updateNSView(_ view: SCNView, context: Context) { refresh(view: view, coordinator: context.coordinator) }
    static func dismantleNSView(_ view: SCNView, coordinator: Coordinator) { capturePose(view: view, coordinator: coordinator) }
}
#elseif canImport(UIKit)
extension Simulate3DSceneView: UIViewRepresentable {
    func makeUIView(context: Context) -> SCNView { makeSCNView(coordinator: context.coordinator) }
    func updateUIView(_ view: SCNView, context: Context) { refresh(view: view, coordinator: context.coordinator) }
    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) { capturePose(view: view, coordinator: coordinator) }
}
#endif
