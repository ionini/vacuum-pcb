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
    /// The print envelope (Bambu modifier volume): every pneumatic feature
    /// grown by the document's modifier margins. Not part of any preset —
    /// an overlay the user switches on to see (and tune) what the "solid
    /// around pneumatics" region will claim.
    static let envelope       = PreviewVisibility(rawValue: 1 << 6)

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
    /// Print-envelope (modifier) mesh in the same design space as the plates.
    /// Rendered as a translucent overlay when `visibility` contains
    /// `.envelope`. Carries its own revision so a padding change refreshes
    /// this node without the full geometry rebuild.
    var envelope: Mesh = Mesh([])
    var envelopeRevision: Int = 0
    var boardOutline: Rect
    /// Which elements of the stack are shown. Drives per-node `isHidden`.
    var visibility: PreviewVisibility
    /// Opacity of the printed-body materials (plates, silicone sheet, casting
    /// frame), 0…1. Feature solids stay opaque regardless — the body fades,
    /// the channels don't. Applied to the live materials on change, so the
    /// slider never forces a geometry rebuild.
    var bodyOpacity: Double = 0.55
    /// Every physical-volume cavity mesh, keyed by *highlight id*: one entry per
    /// volume section (`"T3#0"`, `"T3#1"`, …) plus one for a volume's resistor
    /// serpentines (`"T3#res"`), see `Volume.sectionID`. Each becomes a hidden
    /// — but hit-testable — node so a click in the scene resolves to a section
    /// (and through it a volume); the highlighted subset is un-hidden and tinted.
    /// Each mesh is split into body and via parts so the vias — where a cavity
    /// terminates into a through-hole — light in an accent of the volume colour.
    var volumeMeshes: [String: PlateBuilder.VolumeHighlightMesh] = [:]
    /// Cavities to glow, in priority order — the palette colour index is the
    /// position here, so a collision's two cavities get contrasting colours.
    /// Either a whole-volume id (`"T3"`: every node of that volume lights) or a
    /// single section id (`"T3#1"`: just that resistor-free stretch).
    var highlightedIDs: [String] = []
    /// Bumped by the owner whenever `top…/volumeMeshes` change. Lets a cheap
    /// highlight / visibility refresh skip the per-node geometry rebuild.
    var geometryRevision: Int = 0
    /// Invoked on a scene click with the resolved highlight id, or nil when the
    /// click missed every cavity (so the owner can clear the selection). A
    /// primary click (left / tap) reports the whole volume id (`"T3"`); a
    /// secondary one (right-click / long-press) reports the clicked section
    /// (`"T3#1"`) — the cavity only as far as its resistors.
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
        let envelopeNode = SCNNode()
        /// Parent of the per-volume cavity nodes (one per `Volume.id`). Each is
        /// hidden but kept hit-testable so a click resolves to a volume; the
        /// highlighted subset is un-hidden and tinted. Rebuilt only when the
        /// geometry revision changes.
        let pickRoot = SCNNode()
        var volumeNodes: [String: SCNNode] = [:]
        /// Geometry revision whose nodes are currently live, so a highlight- or
        /// visibility-only refresh can skip the (costlier) node rebuild.
        var lastGeometryRevision: Int?
        /// Envelope revision whose mesh is live on `envelopeNode` — padding
        /// tweaks bump it independently of the plate geometry revision.
        var lastEnvelopeRevision: Int?
        /// Body opacity currently baked into the plate/stencil/mold materials,
        /// so a refresh only touches them when the slider actually moved.
        var lastBodyOpacity: Double?
        let camera = SCNCamera()
        let cameraNode = SCNNode()
        var lastOutline: Rect?
        /// Captured from `Scene3DView` in `makeSCNView` so the static
        /// `dismantle…` hook (which only gets the coordinator) can save the
        /// pose on teardown.
        var cameraStore: Scene3DCameraStore?
        /// Refreshed from `Scene3DView` each update; invoked on a scene click
        /// with the resolved highlight id (or nil when the click missed).
        var onPickVolume: (String?) -> Void = { _ in }
        /// Current element visibility, refreshed each update. Picking consults
        /// it so a cavity whose plate's channels are hidden can't be hit — the
        /// pick nodes are always-invisible geometry, so without this a hidden
        /// bottom channel sitting in front of a visible top one would still
        /// swallow the click.
        var visibility: PreviewVisibility = .both

        /// Primary click / tap: select the whole volume under the cursor.
        @objc func handlePick(_ gr: PlatformGestureRecognizer) {
            pick(gr, wholeVolume: true)
        }

        /// Secondary click (right-click on Mac, long-press on iPad): select just
        /// the clicked section — the cavity up to its resistors.
        @objc func handleSecondaryPick(_ gr: PlatformGestureRecognizer) {
            #if canImport(UIKit)
            // A long-press fires .began (then .changed / .ended); act once.
            guard gr.state == .began else { return }
            #endif
            pick(gr, wholeVolume: false)
        }

        /// Hit-test the scene — including the hidden cavity nodes — and report
        /// the front-most *pickable* cavity under the cursor. SceneKit's
        /// `hitTest` maps the 2-D point through the live camera, so this honours
        /// the current orbit / zoom / pan for free. `ignoreHiddenNodes: false`
        /// lets the invisible pick nodes register; `.all` returns every hit
        /// near→far so we can skip the plate/feature solids in front — and the
        /// cavities of a plate whose channels are switched off — and land on
        /// the first visible-layer cavity.
        private func pick(_ gr: PlatformGestureRecognizer, wholeVolume: Bool) {
            guard let view = gr.view as? SCNView else { return }
            let p = gr.location(in: view)
            let hits = view.hitTest(p, options: [
                .searchMode: SCNHitTestSearchMode.all.rawValue,
                .ignoreHiddenNodes: false,
            ])
            let hid = hits.lazy
                .compactMap { Scene3DView.highlightID(of: $0.node) }
                .first { self.isPickable($0) }
            guard let hid else { onPickVolume(nil); return }
            let volumeID = Volume.volumeID(fromHighlightID: hid)
            // A right-click on a resistor serpentine has no "side" to pick;
            // fall back to the whole volume it joins.
            if wholeVolume || Volume.sectionKey(fromHighlightID: hid) == Volume.resistorsSectionKey {
                onPickVolume(volumeID)
            } else {
                onPickVolume(hid)
            }
        }

        /// A cavity can be clicked only while its plate's channels are shown.
        private func isPickable(_ hid: String) -> Bool {
            switch Volume.plate(ofVolumeID: Volume.volumeID(fromHighlightID: hid)) {
            case .top?:    return visibility.contains(.topChannels)
            case .bottom?: return visibility.contains(.bottomChannels)
            case nil:      return true
            }
        }
    }

    /// Extracts a highlight id (`Volume.sectionID` / `resistorsID`) from a pick
    /// node's name (`"vol:<id>"`), or nil for any other node (plates, features,
    /// lights).
    static func highlightID(of node: SCNNode) -> String? {
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
        c.modelRoot.addChildNode(c.envelopeNode)
        c.modelRoot.addChildNode(c.pickRoot)

        c.camera.usesOrthographicProjection = true
        c.camera.zNear = 0.01
        c.camera.zFar = 10_000
        // Screen-space ambient occlusion. Darkens contact lines and crevices
        // where geometry curves inward — gives same-colour adjacent features
        // (e.g. two channel tubes meeting at a waypoint) a visible seam in
        // both the "Channels" and "Both" preview modes. Plates render in the
        // transparent pass (their depth writes come from the single-layer
        // prepass, see plateGeometry), so SSAO — resolved from the opaque
        // geometry — still keys off the feature solids. Radius is in
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
        applyEnvelope(coordinator: c)
        c.lastGeometryRevision = geometryRevision
        c.lastEnvelopeRevision = envelopeRevision
        c.lastBodyOpacity = bodyOpacity
        applyHighlight(coordinator: c)
        applyVisibility(coordinator: c)
        applyFraming(coordinator: c, animated: false)
        configureCameraController(view.defaultCameraController, target: SCNVector3Zero)

        // Click / tap to select the volume under the cursor. A single click (no
        // drag) selects; a drag still orbits via `allowsCameraControl`, since the
        // recognizer fails the moment the pointer moves. The secondary gesture
        // (right-click / long-press) selects only the clicked section — the
        // cavity up to its resistors.
        c.onPickVolume = onPickVolume
        c.visibility = visibility
        #if canImport(AppKit)
        let pick = NSClickGestureRecognizer(target: c, action: #selector(Coordinator.handlePick(_:)))
        let secondary = NSClickGestureRecognizer(target: c, action: #selector(Coordinator.handleSecondaryPick(_:)))
        secondary.buttonMask = 0x2
        #elseif canImport(UIKit)
        let pick = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handlePick(_:)))
        let secondary = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.handleSecondaryPick(_:)))
        secondary.minimumPressDuration = 0.4
        #endif
        view.addGestureRecognizer(pick)
        view.addGestureRecognizer(secondary)

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
            c.lastBodyOpacity = bodyOpacity
        }
        if c.lastEnvelopeRevision != envelopeRevision {
            applyEnvelope(coordinator: c)
            c.lastEnvelopeRevision = envelopeRevision
        }
        if c.lastBodyOpacity != bodyOpacity {
            applyBodyOpacity(coordinator: c)
            c.lastBodyOpacity = bodyOpacity
        }
        applyHighlight(coordinator: c)
        applyVisibility(coordinator: c)
        c.onPickVolume = onPickVolume
        c.visibility = visibility
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

    /// Rebuild the per-section cavity nodes from `volumeMeshes`. Each starts
    /// hidden (so it doesn't render) but is kept in the scene and tagged
    /// `"vol:<highlight id>"` so a click can resolve back to it via `hitTest`.
    /// Only called when the geometry revision changes — highlight / visibility
    /// toggles reuse these nodes.
    private func applyVolumeNodes(coordinator c: Coordinator) {
        c.pickRoot.childNodes.forEach { $0.removeFromParentNode() }
        c.volumeNodes.removeAll(keepingCapacity: true)
        for (id, mesh) in volumeMeshes where !mesh.isEmpty {
            let node = SCNNode(geometry: mesh.body.isEmpty ? nil : SCNGeometry(mesh.body))
            node.name = "vol:" + id
            node.isHidden = true
            // Vias ride along as a child carrying the same pick name (so a click
            // on a via still resolves to its cavity) but their own material —
            // the accent tint applied in `applyHighlight`.
            if !mesh.vias.isEmpty {
                let vias = SCNNode(geometry: SCNGeometry(mesh.vias))
                vias.name = node.name
                node.addChildNode(vias)
            }
            c.pickRoot.addChildNode(node)
            c.volumeNodes[id] = node
        }
    }

    /// Glow the highlighted cavities (un-hide + tint by palette index) and hide
    /// the rest. A node lights when the highlight set names its own section id
    /// or its whole volume's id. Cheap — just toggles `isHidden` and swaps a
    /// material on existing nodes — so it runs on every refresh.
    private func applyHighlight(coordinator c: Coordinator) {
        for (id, node) in c.volumeNodes {
            let volumeID = Volume.volumeID(fromHighlightID: id)
            if let idx = highlightedIDs.firstIndex(where: { $0 == id || $0 == volumeID }) {
                node.isHidden = false
                let color = Self.palette[idx % Self.palette.count]
                node.geometry?.materials = [Self.highlightMaterial(color: color)]
                for via in node.childNodes {
                    via.geometry?.materials = [Self.viaMaterial(color: color)]
                }
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

    /// Material for a highlighted cavity's vias: the same hue pushed toward
    /// white and glowing harder, so a via reads as "part of this cavity" yet
    /// pops out of the tinted channel run — the eye finds where the cavity
    /// terminates in a through-hole without hunting.
    private static func viaMaterial(color: PlatformColor) -> SCNMaterial {
        // Pushed well toward white and near-fully emissive: the via has to
        // read as a bright cap on the tinted run, not a lighter shade of it.
        let accent = lightened(color, by: 0.75)
        let material = SCNMaterial()
        material.diffuse.contents = accent
        material.emission.contents = accent.withAlphaComponent(0.9)
        material.isDoubleSided = false
        material.lightingModel = .blinn
        return material
    }

    /// `color` mixed toward white by `fraction` (0 = unchanged, 1 = white), in
    /// sRGB so the result is stable across AppKit / UIKit colour spaces.
    private static func lightened(_ color: PlatformColor, by fraction: CGFloat) -> PlatformColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        #if canImport(AppKit)
        (color.usingColorSpace(.sRGB) ?? color).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return PlatformColor(red: r + (1 - r) * fraction,
                             green: g + (1 - g) * fraction,
                             blue: b + (1 - b) * fraction,
                             alpha: a)
    }

    private func plateGeometry(for mesh: Mesh, color: PlatformColor) -> SCNGeometry {
        let geometry = SCNGeometry(mesh)
        let material = SCNMaterial()
        // Full-alpha diffuse; `transparency` alone carries the user's body
        // opacity so `applyBodyOpacity` can retune it live on the same
        // material without rebuilding geometry.
        material.diffuse.contents = color
        material.transparency = Self.bodyTransparency(bodyOpacity)
        // Blend only the nearest surface. The plate mesh is the *carved*
        // solid, so a view ray crosses its outer skin, every channel wall,
        // and the back skin; plain alpha blending stacks all of those layers
        // in triangle order (CSG output — arbitrary), so raising the opacity
        // slider darkened the pile instead of solidifying the skin, with the
        // carved routes reading through at any setting. `.singleLayer` culls
        // the blend to the front surface — and only takes effect when the
        // material also writes depth (verified with an offscreen renderer:
        // without the depth write SceneKit silently ignores the mode). The
        // depth write happens in the transparent pass, after the opaque
        // feature solids have already rendered, so channels still show
        // through a low-opacity body in "Both" mode.
        material.transparencyMode = .singleLayer
        material.writesToDepthBuffer = true
        material.isDoubleSided = true
        material.lightingModel = .blinn
        geometry.materials = [material]
        return geometry
    }

    /// Body opacity mapped to material transparency, held a hair below fully
    /// opaque: at exactly 1.0 SceneKit reclassifies the plates as opaque-pass
    /// geometry, where their walls z-fight the coincident feature solids and
    /// the single-layer blend path no longer applies. 0.995 is visually
    /// indistinguishable from solid while staying on the transparent path.
    private static func bodyTransparency(_ opacity: Double) -> CGFloat {
        CGFloat(min(opacity, 0.995))
    }

    /// The envelope overlay never goes fully solid: capped at 0.70 on the
    /// body-opacity scale so the carving inside the region (the whole point
    /// of showing it, especially in Voids style) stays readable even with the
    /// plates pushed opaque. Below the cap it follows the slider as usual.
    private static func envelopeTransparency(_ opacity: Double) -> CGFloat {
        bodyTransparency(min(opacity, 0.70))
    }

    /// Push the current `bodyOpacity` onto the live printed-body materials
    /// (plates, stencil, mold). Cheap — mutates existing materials — so the
    /// opacity slider refreshes without the per-node geometry rebuild.
    private func applyBodyOpacity(coordinator c: Coordinator) {
        for node in [c.topNode, c.bottomNode, c.stencilNode, c.moldNode] {
            node.geometry?.firstMaterial?.transparency = Self.bodyTransparency(bodyOpacity)
        }
        c.envelopeNode.geometry?.firstMaterial?.transparency = Self.envelopeTransparency(bodyOpacity)
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
    /// set); what a hidden layer does switch off is *picking* its cavities — see
    /// `Coordinator.isPickable`.
    private func applyVisibility(coordinator c: Coordinator) {
        c.topNode.isHidden            = !visibility.contains(.topPlate)
        c.bottomNode.isHidden         = !visibility.contains(.bottomPlate)
        c.topFeaturesNode.isHidden    = !visibility.contains(.topChannels)
        c.bottomFeaturesNode.isHidden = !visibility.contains(.bottomChannels)
        c.stencilNode.isHidden        = !visibility.contains(.stencil)
        c.moldNode.isHidden           = !visibility.contains(.mold)
        c.envelopeNode.isHidden       = !visibility.contains(.envelope)
    }

    /// Print-envelope overlay: translucent purple skin over the grown feature
    /// shells, so the user sees exactly what the modifier volume will claim
    /// around the pneumatics. The envelope mesh is concatenated overlapping
    /// shells (deliberately un-unioned, like the export), so it needs the same
    /// single-layer transparency treatment as the carved plates — plain alpha
    /// blending would stack every overlapping shell wall into an unreadable
    /// pile. A touch of emission keeps it legible over the darker plate body.
    private func applyEnvelope(coordinator c: Coordinator) {
        guard !envelope.isEmpty else {
            c.envelopeNode.geometry = nil
            return
        }
        let geometry = SCNGeometry(envelope)
        let material = SCNMaterial()
        material.diffuse.contents = PlatformColor.systemPurple
        material.emission.contents = PlatformColor.systemPurple.withAlphaComponent(0.18)
        // Tracks the body-opacity slider like the plates do (applyBodyOpacity
        // retunes it live); the envelope is body-like — a region of the print,
        // not a feature solid.
        material.transparency = Self.envelopeTransparency(bodyOpacity)
        material.transparencyMode = .singleLayer
        material.writesToDepthBuffer = true
        material.isDoubleSided = true
        material.lightingModel = .blinn
        geometry.materials = [material]
        c.envelopeNode.geometry = geometry
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
