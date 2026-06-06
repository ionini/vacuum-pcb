import SwiftUI
import SceneKit
import Euclid

/// What to show in the 3D preview. `bodyOnly` is the printable view; the other
/// two modes peel the plates back to expose the routing solids.
enum PreviewDisplayMode: String, CaseIterable, Hashable {
    case bodyOnly
    case both
    case featuresOnly

    var label: String {
        switch self {
        case .bodyOnly:     return "Body"
        case .both:         return "Both"
        case .featuresOnly: return "Channels"
        }
    }
}

/// A saved camera point of view — the orbit angle and orthographic zoom the
/// user left the 3D preview at.
struct Scene3DCameraPose {
    var transform: SCNMatrix4
    var orthographicScale: CGFloat
}

/// Reference holder so a `Scene3DCameraPose` survives `Scene3DView` being torn
/// down and rebuilt. Owned by `DocumentView` (which outlives the per-tab views,
/// unlike the SCNView): the view writes the latest pose here when it's
/// dismantled on a tab switch and reads it back on the next build, so returning
/// to the Preview tab keeps the angle the user left it at rather than snapping
/// to the default iso view.
final class Scene3DCameraStore {
    var pose: Scene3DCameraPose?
    init() {}
}

/// SceneKit-backed 3D preview of the two plates.
///
/// Built once with `makePlatformView`; `updatePlatformView` only swaps
/// geometries on the existing nodes so orbit / zoom state survives document
/// edits. Camera is orthographic and seeded at the standard iso angle
/// (Z-up, viewed from the +X / -Y / +Z octant).
///
/// Camera control mirrors the flow_simulator setup: the controller's pivot is
/// pinned to the model centroid instead of letting SceneKit recompute it from
/// the bounding box, which would drift as geometry changes.
struct Scene3DView {
    var top: Mesh
    var bottom: Mesh
    var topFeatures: Mesh
    var bottomFeatures: Mesh
    var stencil: Mesh
    var boardOutline: Rect
    var displayMode: PreviewDisplayMode
    /// Outlives this view (lives in `DocumentView`) so orbit / zoom can be
    /// replayed after a tab switch tears the SCNView down. `nil` falls back to
    /// the default iso framing — fine for previews / tests.
    var cameraStore: Scene3DCameraStore? = nil

    final class Coordinator {
        let scene = SCNScene()
        let modelRoot = SCNNode()
        let topNode = SCNNode()
        let bottomNode = SCNNode()
        let topFeaturesNode = SCNNode()
        let bottomFeaturesNode = SCNNode()
        let stencilNode = SCNNode()
        let camera = SCNCamera()
        let cameraNode = SCNNode()
        var lastOutline: Rect?
        /// Captured from `Scene3DView` in `makeSCNView` so the static
        /// `dismantle…` hook (which only gets the coordinator) can save the
        /// pose on teardown.
        var cameraStore: Scene3DCameraStore?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

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
        c.modelRoot.addChildNode(c.topNode)
        c.modelRoot.addChildNode(c.bottomNode)
        c.modelRoot.addChildNode(c.topFeaturesNode)
        c.modelRoot.addChildNode(c.bottomFeaturesNode)
        c.modelRoot.addChildNode(c.stencilNode)

        c.camera.usesOrthographicProjection = true
        c.camera.zNear = 0.01
        c.camera.zFar = 10_000
        // Screen-space ambient occlusion. Darkens contact lines and crevices
        // where geometry curves inward — gives same-colour adjacent features
        // (e.g. two channel tubes meeting at a waypoint) a visible seam in
        // both the "Channels" and "Both" preview modes. Plates currently
        // don't write to the depth buffer (see plateGeometry), so they don't
        // participate in SSAO — only the feature solids do. Radius is in
        // scene units (mm); 2.5 mm picks up channel-junction crevices and
        // dimple boundaries without smearing across the whole part.
        c.camera.screenSpaceAmbientOcclusionIntensity = 1.5
        c.camera.screenSpaceAmbientOcclusionRadius = 2.5
        c.camera.screenSpaceAmbientOcclusionBias = 0.03
        c.cameraNode.camera = c.camera
        c.cameraNode.name = "Main Camera"
        c.scene.rootNode.addChildNode(c.cameraNode)
        view.pointOfView = c.cameraNode

        addLights(to: c.scene)
        applyGeometries(coordinator: c)
        applyDisplayMode(coordinator: c)
        applyFraming(coordinator: c, animated: false)
        configureCameraController(view.defaultCameraController, target: SCNVector3Zero)

        // Replay the orbit / zoom from a previous visit to the Preview tab, if
        // any. `applyFraming` above already recentred `modelRoot` for the
        // current board, and the orbit pivot is pinned to the centroid
        // (origin), so a pose saved against a differently-sized board still
        // points at the model.
        c.cameraStore = cameraStore
        if let pose = cameraStore?.pose {
            c.cameraNode.transform = pose.transform
            c.camera.orthographicScale = pose.orthographicScale
        }

        return view
    }

    /// Snapshot the live orbit / zoom into the store so it survives the SCNView
    /// being torn down on a tab switch.
    ///
    /// Reads the *presentation* transform off `view.pointOfView`, not the model
    /// node's `transform`. With `allowsCameraControl`, SceneKit's camera
    /// controller drives the on-screen camera through the presentation layer,
    /// leaving the model node frozen at whatever `applyFraming` last set (the
    /// iso angle). Reading the model node would therefore capture — and replay
    /// — a pose identical to the default, which is exactly "no persistence".
    fileprivate static func capturePose(view: SCNView, coordinator c: Coordinator) {
        guard let store = c.cameraStore, let pov = view.pointOfView else { return }
        store.pose = Scene3DCameraPose(
            transform: pov.presentation.transform,
            orthographicScale: (pov.camera ?? c.camera).orthographicScale
        )
    }

    fileprivate func refresh(view: SCNView, coordinator c: Coordinator) {
        applyGeometries(coordinator: c)
        applyDisplayMode(coordinator: c)
        if c.lastOutline != boardOutline {
            applyFraming(coordinator: c, animated: true)
        }
    }

    // MARK: - Geometry

    private func applyGeometries(coordinator c: Coordinator) {
        c.topNode.geometry = plateGeometry(for: top, color: .systemBlue)
        c.bottomNode.geometry = plateGeometry(for: bottom, color: .systemTeal)
        c.topFeaturesNode.geometry = featuresGeometry(for: topFeatures, color: .systemBlue)
        c.bottomFeaturesNode.geometry = featuresGeometry(for: bottomFeatures, color: .systemTeal)
        // Stencil reuses the plate material so it reads as a printed body
        // rather than a routing feature. Yellow distinguishes it from the
        // blue/teal of the plates without competing with them visually.
        c.stencilNode.geometry = stencil.isEmpty
            ? nil
            : plateGeometry(for: stencil, color: .systemYellow)
    }

    private func plateGeometry(for mesh: Mesh, color: PlatformColor) -> SCNGeometry {
        let geometry = SCNGeometry(mesh)
        let material = SCNMaterial()
        material.diffuse.contents = color.withAlphaComponent(0.55)
        material.transparency = 0.55
        material.isDoubleSided = true
        material.lightingModel = .blinn
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        return geometry
    }

    /// Feature solids are rendered opaque and slightly emissive so they pop
    /// against the translucent plate body in `both` mode and read clearly on
    /// their own in `featuresOnly`. Color tracks layer to match the schematic
    /// and physical canvas conventions.
    private func featuresGeometry(for mesh: Mesh, color: PlatformColor) -> SCNGeometry {
        let geometry = SCNGeometry(mesh)
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color.withAlphaComponent(0.15)
        material.isDoubleSided = false
        material.lightingModel = .blinn
        geometry.materials = [material]
        return geometry
    }

    private func applyDisplayMode(coordinator c: Coordinator) {
        switch displayMode {
        case .bodyOnly:
            c.topNode.isHidden = false
            c.bottomNode.isHidden = false
            c.topFeaturesNode.isHidden = true
            c.bottomFeaturesNode.isHidden = true
            c.stencilNode.isHidden = false
        case .both:
            c.topNode.isHidden = false
            c.bottomNode.isHidden = false
            c.topFeaturesNode.isHidden = false
            c.bottomFeaturesNode.isHidden = false
            c.stencilNode.isHidden = false
        case .featuresOnly:
            c.topNode.isHidden = true
            c.bottomNode.isHidden = true
            c.topFeaturesNode.isHidden = false
            c.bottomFeaturesNode.isHidden = false
            // Channels-only mode hides every printed body so the routing
            // solids read clearly. The stencil is a body, so it goes too.
            c.stencilNode.isHidden = true
        }
    }

    // MARK: - Framing

    private func applyFraming(coordinator c: Coordinator, animated: Bool) {
        let cx = boardOutline.origin.x + boardOutline.size.width / 2
        let cy = boardOutline.origin.y + boardOutline.size.height / 2
        let translate = SCNAction.move(to: SCNVector3(-cx, -cy, 0),
                                       duration: animated ? 0.25 : 0)
        c.modelRoot.runAction(translate)

        let diag = (boardOutline.size.width * boardOutline.size.width
                  + boardOutline.size.height * boardOutline.size.height).squareRoot()
        let viewSpan = max(diag, 20)
        c.camera.orthographicScale = viewSpan * 0.65

        let dist = viewSpan * 2.5
        let p = dist / sqrt(3.0)
        c.cameraNode.position = SCNVector3(p, -p, p)
        c.cameraNode.look(at: SCNVector3Zero, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))

        c.lastOutline = boardOutline
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
extension Scene3DView: NSViewRepresentable {
    func makeNSView(context: Context) -> SCNView { makeSCNView(coordinator: context.coordinator) }
    func updateNSView(_ view: SCNView, context: Context) { refresh(view: view, coordinator: context.coordinator) }
    static func dismantleNSView(_ view: SCNView, coordinator: Coordinator) { capturePose(view: view, coordinator: coordinator) }
}
#elseif canImport(UIKit)
extension Scene3DView: UIViewRepresentable {
    func makeUIView(context: Context) -> SCNView { makeSCNView(coordinator: context.coordinator) }
    func updateUIView(_ view: SCNView, context: Context) { refresh(view: view, coordinator: context.coordinator) }
    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) { capturePose(view: view, coordinator: coordinator) }
}
#endif
