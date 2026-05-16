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

/// SceneKit-backed 3D preview of the two plates.
///
/// Built once with `makeNSView`; `updateNSView` only swaps geometries on the
/// existing nodes so orbit / zoom state survives document edits. Camera is
/// orthographic and seeded at the standard iso angle (Z-up, viewed from the
/// +X / -Y / +Z octant).
///
/// Camera control mirrors the flow_simulator setup: the controller's pivot is
/// pinned to the model centroid instead of letting SceneKit recompute it from
/// the bounding box, which would drift as geometry changes.
struct Scene3DView: NSViewRepresentable {
    var top: Mesh
    var bottom: Mesh
    var topFeatures: Mesh
    var bottomFeatures: Mesh
    var boardOutline: Rect
    var displayMode: PreviewDisplayMode

    final class Coordinator {
        let scene = SCNScene()
        let modelRoot = SCNNode()
        let topNode = SCNNode()
        let bottomNode = SCNNode()
        let topFeaturesNode = SCNNode()
        let bottomFeaturesNode = SCNNode()
        let camera = SCNCamera()
        let cameraNode = SCNNode()
        var lastOutline: Rect?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let c = context.coordinator
        let view = SCNView()
        view.scene = c.scene
        view.backgroundColor = NSColor.windowBackgroundColor
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false

        c.scene.rootNode.addChildNode(c.modelRoot)
        c.modelRoot.addChildNode(c.topNode)
        c.modelRoot.addChildNode(c.bottomNode)
        c.modelRoot.addChildNode(c.topFeaturesNode)
        c.modelRoot.addChildNode(c.bottomFeaturesNode)

        c.camera.usesOrthographicProjection = true
        c.camera.zNear = 0.01
        c.camera.zFar = 10_000
        c.cameraNode.camera = c.camera
        c.cameraNode.name = "Main Camera"
        c.scene.rootNode.addChildNode(c.cameraNode)
        view.pointOfView = c.cameraNode

        addLights(to: c.scene)
        applyGeometries(coordinator: c)
        applyDisplayMode(coordinator: c)
        applyFraming(coordinator: c, animated: false)
        configureCameraController(view.defaultCameraController, target: SCNVector3Zero)

        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let c = context.coordinator
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
    }

    private func plateGeometry(for mesh: Mesh, color: NSColor) -> SCNGeometry {
        let geometry = SCNGeometry(mesh)
        let material = SCNMaterial()
        material.diffuse.contents = color.withAlphaComponent(0.55)
        material.transparency = 0.55
        material.isDoubleSided = true
        material.lightingModel = .blinn
        // Plates have internal cavities (channels, dome dimples, etc.). Without
        // this, double-sided translucent geometry depth-occludes itself and
        // back faces blend inconsistently — some show through, some don't —
        // which looked patchy on the curved dome walls.
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        return geometry
    }

    /// Feature solids are rendered opaque and slightly emissive so they pop
    /// against the translucent plate body in `both` mode and read clearly on
    /// their own in `featuresOnly`. Color tracks layer to match the schematic
    /// and physical canvas conventions.
    private func featuresGeometry(for mesh: Mesh, color: NSColor) -> SCNGeometry {
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
        case .both:
            c.topNode.isHidden = false
            c.bottomNode.isHidden = false
            c.topFeaturesNode.isHidden = false
            c.bottomFeaturesNode.isHidden = false
        case .featuresOnly:
            c.topNode.isHidden = true
            c.bottomNode.isHidden = true
            c.topFeaturesNode.isHidden = false
            c.bottomFeaturesNode.isHidden = false
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
        ambient.light?.intensity = 300
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 700
        key.eulerAngles = SCNVector3(-Double.pi / 3, Double.pi / 6, 0)
        scene.rootNode.addChildNode(key)
    }
}
