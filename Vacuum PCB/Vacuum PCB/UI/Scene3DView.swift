import SwiftUI
import SceneKit
import Euclid

#if canImport(AppKit)
typealias PlatformGestureRecognizer = NSGestureRecognizer
#elseif canImport(UIKit)
typealias PlatformGestureRecognizer = UIGestureRecognizer
#endif

/// Per-element visibility of the printed stack in the 3D preview. Each plate
/// face and its routing channels toggle independently, so the user can peel the
/// model back element by element; `PreviewDisplayMode` below offers the common
/// combinations as one-click presets.
struct PreviewVisibility: OptionSet, Hashable {
    let rawValue: Int

    static let topPlate       = PreviewVisibility(rawValue: 1 << 0)
    static let bottomPlate    = PreviewVisibility(rawValue: 1 << 1)
    static let topChannels    = PreviewVisibility(rawValue: 1 << 2)
    static let bottomChannels = PreviewVisibility(rawValue: 1 << 3)
    static let stencil        = PreviewVisibility(rawValue: 1 << 4)
    static let mold           = PreviewVisibility(rawValue: 1 << 5)

    /// Printable body: both plates + the silicone sheet, channels hidden.
    static let body: PreviewVisibility     = [.topPlate, .bottomPlate, .stencil]
    /// Plates + channels — the default working view.
    static let both: PreviewVisibility     = [.topPlate, .bottomPlate, .topChannels, .bottomChannels, .stencil]
    /// Routing solids only, plates peeled away.
    static let channels: PreviewVisibility = [.topChannels, .bottomChannels]
    /// Casting aid: silicone sheet sitting in its frame.
    static let moldView: PreviewVisibility = [.stencil, .mold]
}

/// Named visibility presets surfaced as a segmented picker. Selecting one sets
/// every element at once; the individual `PreviewVisibility` toggles then let
/// the user deviate from a preset (e.g. "Both" minus the top plate).
enum PreviewDisplayMode: String, CaseIterable, Hashable {
    case bodyOnly
    case both
    case featuresOnly
    case mold

    var label: String {
        switch self {
        case .bodyOnly:     return "Body"
        case .both:         return "Both"
        case .featuresOnly: return "Channels"
        case .mold:         return "Mold"
        }
    }

    var visibility: PreviewVisibility {
        switch self {
        case .bodyOnly:     return .body
        case .both:         return .both
        case .featuresOnly: return .channels
        case .mold:         return .moldView
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
    var moldFrame: Mesh
    var boardOutline: Rect
    /// Which elements of the stack are shown. Drives per-node `isHidden`.
    var visibility: PreviewVisibility
    /// Every physical-volume cavity mesh, keyed by `Volume.id`. Each becomes a
    /// hidden — but hit-testable — node so a click in the scene resolves to a
    /// volume; the highlighted subset is un-hidden and tinted.
    var volumeMeshes: [String: Mesh] = [:]
    /// Volumes to glow, in priority order — the palette colour index is the
    /// position here, so a collision's two cavities get contrasting colours.
    var highlightedIDs: [String] = []
    /// Bumped by the owner whenever `top…/volumeMeshes` change. Lets a cheap
    /// highlight / visibility refresh skip the per-node geometry rebuild.
    var geometryRevision: Int = 0
    /// Invoked on a scene click with the resolved volume id, or nil when the
    /// click missed every cavity (so the owner can clear the selection).
    var onPickVolume: (String?) -> Void = { _ in }
    /// Outlives this view (lives in `DocumentView`) so orbit / zoom can be
    /// replayed after a tab switch tears the SCNView down. `nil` falls back to
    /// the default iso framing — fine for previews / tests.
    var cameraStore: Scene3DCameraStore? = nil

    final class Coordinator: NSObject {
        let scene = SCNScene()
        let modelRoot = SCNNode()
        let topNode = SCNNode()
        let bottomNode = SCNNode()
        let topFeaturesNode = SCNNode()
        let bottomFeaturesNode = SCNNode()
        let stencilNode = SCNNode()
        let moldNode = SCNNode()
        /// Parent of the per-volume cavity nodes (one per `Volume.id`). Each is
        /// hidden but kept hit-testable so a click resolves to a volume; the
        /// highlighted subset is un-hidden and tinted. Rebuilt only when the
        /// geometry revision changes.
        let pickRoot = SCNNode()
        var volumeNodes: [String: SCNNode] = [:]
        /// Geometry revision whose nodes are currently live, so a highlight- or
        /// visibility-only refresh can skip the (costlier) node rebuild.
        var lastGeometryRevision: Int?
        let camera = SCNCamera()
        let cameraNode = SCNNode()
        var lastOutline: Rect?
        /// Captured from `Scene3DView` in `makeSCNView` so the static
        /// `dismantle…` hook (which only gets the coordinator) can save the
        /// pose on teardown.
        var cameraStore: Scene3DCameraStore?
        /// Refreshed from `Scene3DView` each update; invoked on a scene click
        /// with the resolved volume id (or nil when the click missed).
        var onPickVolume: (String?) -> Void = { _ in }

        /// Click / tap handler: hit-test the scene — including the hidden cavity
        /// nodes — and report the front-most volume under the cursor. SceneKit's
        /// `hitTest` maps the 2-D point through the live camera, so this honours
        /// the current orbit / zoom / pan for free. `ignoreHiddenNodes: false`
        /// lets the invisible pick nodes register; `.all` returns every hit
        /// near→far so we can skip the plate/feature solids in front and land on
        /// the first volume.
        @objc func handlePick(_ gr: PlatformGestureRecognizer) {
            guard let view = gr.view as? SCNView else { return }
            let p = gr.location(in: view)
            let hits = view.hitTest(p, options: [
                .searchMode: SCNHitTestSearchMode.all.rawValue,
                .ignoreHiddenNodes: false,
            ])
            let id = hits.lazy.compactMap { Scene3DView.volumeID(of: $0.node) }.first
            onPickVolume(id)
        }
    }

    /// Extracts a `Volume.id` from a pick node's name (`"vol:<id>"`), or nil for
    /// any other node (plates, features, lights).
    static func volumeID(of node: SCNNode) -> String? {
        guard let name = node.name, name.hasPrefix("vol:") else { return nil }
        return String(name.dropFirst(4))
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
        c.modelRoot.addChildNode(c.moldNode)
        c.modelRoot.addChildNode(c.pickRoot)

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
        applyVolumeNodes(coordinator: c)
        c.lastGeometryRevision = geometryRevision
        applyHighlight(coordinator: c)
        applyVisibility(coordinator: c)
        applyFraming(coordinator: c, animated: false)
        configureCameraController(view.defaultCameraController, target: SCNVector3Zero)

        // Click / tap to select the volume under the cursor. A single click (no
        // drag) selects; a drag still orbits via `allowsCameraControl`, since the
        // recognizer fails the moment the pointer moves.
        c.onPickVolume = onPickVolume
        #if canImport(AppKit)
        let pick = NSClickGestureRecognizer(target: c, action: #selector(Coordinator.handlePick(_:)))
        #elseif canImport(UIKit)
        let pick = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handlePick(_:)))
        #endif
        view.addGestureRecognizer(pick)

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
        // Geometry (plates, features, per-volume cavities) only changes on a
        // rebuild, flagged by a new revision. A highlight or visibility toggle
        // reuses the existing nodes, so it skips the rebuild and just re-tints /
        // re-hides — keeping row clicks and layer toggles cheap on big boards.
        if c.lastGeometryRevision != geometryRevision {
            applyGeometries(coordinator: c)
            applyVolumeNodes(coordinator: c)
            c.lastGeometryRevision = geometryRevision
        }
        applyHighlight(coordinator: c)
        applyVisibility(coordinator: c)
        c.onPickVolume = onPickVolume
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
        // Casting frame reads as a printed body like the plates/stencil; orange
        // sets it apart from the yellow stencil it surrounds in the Mold view.
        c.moldNode.geometry = moldFrame.isEmpty
            ? nil
            : plateGeometry(for: moldFrame, color: .systemOrange)
    }

    /// Rebuild the per-volume cavity nodes from `volumeMeshes`. Each starts
    /// hidden (so it doesn't render) but is kept in the scene and tagged
    /// `"vol:<id>"` so a click can resolve back to it via `hitTest`. Only called
    /// when the geometry revision changes — highlight / visibility toggles reuse
    /// these nodes.
    private func applyVolumeNodes(coordinator c: Coordinator) {
        c.pickRoot.childNodes.forEach { $0.removeFromParentNode() }
        c.volumeNodes.removeAll(keepingCapacity: true)
        for (id, mesh) in volumeMeshes where !mesh.isEmpty {
            let node = SCNNode(geometry: SCNGeometry(mesh))
            node.name = "vol:" + id
            node.isHidden = true
            c.pickRoot.addChildNode(node)
            c.volumeNodes[id] = node
        }
    }

    /// Glow the highlighted cavities (un-hide + tint by palette index) and hide
    /// the rest. Cheap — just toggles `isHidden` and swaps a material on existing
    /// nodes — so it runs on every refresh.
    private func applyHighlight(coordinator c: Coordinator) {
        for (id, node) in c.volumeNodes {
            if let idx = highlightedIDs.firstIndex(of: id) {
                node.isHidden = false
                node.geometry?.materials = [Self.highlightMaterial(color: Self.palette[idx % Self.palette.count])]
            } else {
                node.isHidden = true
            }
        }
    }

    /// Contrasting glow colours, indexed by a volume's position in
    /// `highlightedIDs`. Picked to stand out against the blue/teal plates and
    /// from each other (e.g. the two cavities of a collision).
    static let palette: [PlatformColor] = [.systemPink, .systemGreen, .systemYellow, .systemPurple]

    /// Material for a highlighted cavity: shaded exactly like the feature
    /// channels (depth-tested, so it picks up the same ambient-occlusion crevices
    /// and lighting that give the normal channels their form) — just tinted and a
    /// touch more emissive so it reads as "this is the highlighted cavity". The
    /// cavity mesh is built a hair proud of the real channel, so it sits on top
    /// of the matching feature geometry rather than z-fighting it.
    private static func highlightMaterial(color: PlatformColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color.withAlphaComponent(0.30)
        material.isDoubleSided = false
        material.lightingModel = .blinn
        return material
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

    /// Show / hide each element by its `PreviewVisibility` bit. The per-volume
    /// pick nodes are independent of this (their visibility tracks the highlight
    /// set), so a hidden layer never disables click-to-select.
    private func applyVisibility(coordinator c: Coordinator) {
        c.topNode.isHidden            = !visibility.contains(.topPlate)
        c.bottomNode.isHidden         = !visibility.contains(.bottomPlate)
        c.topFeaturesNode.isHidden    = !visibility.contains(.topChannels)
        c.bottomFeaturesNode.isHidden = !visibility.contains(.bottomChannels)
        c.stencilNode.isHidden        = !visibility.contains(.stencil)
        c.moldNode.isHidden           = !visibility.contains(.mold)
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
