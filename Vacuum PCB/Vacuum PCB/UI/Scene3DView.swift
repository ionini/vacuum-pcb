import SwiftUI
import SceneKit
import Euclid

/// SceneKit-backed 3D preview of the two plates.
///
/// Built once with `makeNSView`; `updateNSView` only swaps the plate geometries
/// on existing nodes so orbit / zoom state survives document edits. Camera is
/// orthographic and seeded at the standard iso angle (looking down the +X+Y+Z
/// octant toward origin, with Z as visual up).
///
/// Camera control mirrors the flow_simulator setup: the controller's pivot is
/// pinned to the model's centroid instead of letting SceneKit recompute it
/// from the bounding box, which would drift as geometry changes. Orbit uses
/// angle-mapping with inertia for a smoother feel than the default trackball.
struct Scene3DView: NSViewRepresentable {
    var top: Mesh
    var bottom: Mesh
    var boardOutline: Rect

    final class Coordinator {
        let scene = SCNScene()
        let modelRoot = SCNNode()
        let topNode = SCNNode()
        let bottomNode = SCNNode()
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

        // Model root holds both plates and absorbs the centering translation
        // that puts the board centroid at world origin. Doing the centering on
        // a parent node (instead of mutating mesh transforms) keeps Euclid
        // meshes in their authored world coordinates.
        c.scene.rootNode.addChildNode(c.modelRoot)
        c.modelRoot.addChildNode(c.topNode)
        c.modelRoot.addChildNode(c.bottomNode)

        // Orthographic + iso vantage. Z is the plate-normal axis in our
        // coordinate system, so up = (0,0,1) and the camera sits in the
        // +X / -Y / +Z octant — same dimetric angle as flow_simulator's
        // (0, 60, 60), just re-axised because our up is Z.
        c.camera.usesOrthographicProjection = true
        c.camera.zNear = 0.01
        c.camera.zFar = 10_000
        c.cameraNode.camera = c.camera
        c.cameraNode.name = "Main Camera"
        c.scene.rootNode.addChildNode(c.cameraNode)
        view.pointOfView = c.cameraNode

        addLights(to: c.scene)
        applyGeometries(coordinator: c)
        applyFraming(coordinator: c, animated: false)
        configureCameraController(view.defaultCameraController, target: SCNVector3Zero)

        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let c = context.coordinator
        applyGeometries(coordinator: c)
        // Re-frame only when the board outline actually changed — otherwise
        // every document edit would yank the user's orbit back to the seeded
        // iso angle. ortho scale is reapplied alongside the recenter because
        // both depend on board size.
        if c.lastOutline != boardOutline {
            applyFraming(coordinator: c, animated: true)
        }
    }

    // MARK: - Geometry

    private func applyGeometries(coordinator c: Coordinator) {
        c.topNode.geometry = scnGeometry(for: top, color: .systemBlue)
        c.bottomNode.geometry = scnGeometry(for: bottom, color: .systemTeal)
    }

    private func scnGeometry(for mesh: Mesh, color: NSColor) -> SCNGeometry {
        let geometry = SCNGeometry(mesh)
        let material = SCNMaterial()
        material.diffuse.contents = color.withAlphaComponent(0.55)
        material.transparency = 0.55
        material.isDoubleSided = true
        material.lightingModel = .blinn
        geometry.materials = [material]
        return geometry
    }

    // MARK: - Framing

    private func applyFraming(coordinator c: Coordinator, animated: Bool) {
        let cx = boardOutline.origin.x + boardOutline.size.width / 2
        let cy = boardOutline.origin.y + boardOutline.size.height / 2
        // Center the model so orbit (which pivots around world origin) feels
        // natural. Z stays at 0 because the silicone plane already sits there.
        let translate = SCNAction.move(to: SCNVector3(-cx, -cy, 0),
                                       duration: animated ? 0.25 : 0)
        c.modelRoot.runAction(translate)

        let diag = (boardOutline.size.width * boardOutline.size.width
                  + boardOutline.size.height * boardOutline.size.height).squareRoot()
        let viewSpan = max(diag, 20)

        // Orthographic scale = half-height of the visible world in mm. Pad a bit
        // so the plates aren't kissing the viewport edge.
        c.camera.orthographicScale = viewSpan * 0.65

        // Camera position: pull back along the iso ray by enough distance that
        // zFar comfortably contains the plates. The actual distance doesn't
        // matter for an ortho camera (no perspective), but it does for clipping.
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

        // A single directional key from above-front so plate edges read with
        // some shading even though materials are mostly translucent.
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 700
        key.eulerAngles = SCNVector3(-Double.pi / 3, Double.pi / 6, 0)
        scene.rootNode.addChildNode(key)
    }
}
