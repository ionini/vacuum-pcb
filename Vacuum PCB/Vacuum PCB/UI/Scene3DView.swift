import SwiftUI
import SceneKit
import Euclid

struct Scene3DView: NSViewRepresentable {
    var top: Mesh
    var bottom: Mesh
    var boardOutline: Rect

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = NSColor.windowBackgroundColor
        view.antialiasingMode = .multisampling4X
        view.scene = makeScene()
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        view.scene = makeScene()
    }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()

        let topGeom = scnGeometry(for: top, color: NSColor.systemBlue)
        let bottomGeom = scnGeometry(for: bottom, color: NSColor.systemTeal)
        scene.rootNode.addChildNode(SCNNode(geometry: topGeom))
        scene.rootNode.addChildNode(SCNNode(geometry: bottomGeom))

        // Camera framed on the board's centroid.
        let cx = boardOutline.origin.x + boardOutline.size.width / 2
        let cy = boardOutline.origin.y + boardOutline.size.height / 2
        let diag = (boardOutline.size.width * boardOutline.size.width
                  + boardOutline.size.height * boardOutline.size.height).squareRoot()

        let camera = SCNCamera()
        camera.zNear = 0.1
        camera.zFar = max(diag * 6, 500)
        camera.fieldOfView = 35

        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(cx + diag * 0.4, cy - diag * 0.5, diag * 0.9)
        cameraNode.look(at: SCNVector3(cx, cy, 0))
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 350
        scene.rootNode.addChildNode(ambient)

        return scene
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
}
