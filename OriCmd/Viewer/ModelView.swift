import AppKit
import SceneKit
import simd

/// A 3D model to turn and look at: dragging turns it, a mouse wheel or a pinch
/// brings it nearer, dragging with Option or two fingers on a trackpad moves it, a
/// double click shows it as at first. Z is up, as 3D printing and CAD programs have
/// it; the model is centered and brought to one size, whatever its units.
final class ModelView: NSView {
    private let sceneView = ModelSceneView()
    let triangleCount: Int

    init(model: MeshDocument) {
        triangleCount = model.triangleCount
        super.init(frame: .zero)
        let scene = SCNScene()
        let node = SCNNode(geometry: Self.geometry(model))
        let center = (model.minimum + model.maximum) / 2
        let radius = max(simd_length(model.maximum - model.minimum) / 2, .leastNormalMagnitude)
        node.pivot = SCNMatrix4MakeTranslation(CGFloat(center.x), CGFloat(center.y), CGFloat(center.z))
        node.scale = SCNVector3(1 / CGFloat(radius), 1 / CGFloat(radius), 1 / CGFloat(radius))
        node.eulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(node)

        // Seen from the front, a little from the right and above, all of it in view.
        let camera = SCNCamera()
        camera.fieldOfView = 35
        camera.automaticallyAdjustsZRange = true
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let distance = 1.0 / sin(35 / 2 * CGFloat.pi / 180)
        let direction = simd_normalize(SIMD3<Double>(0.55, 0.45, 1))
        cameraNode.position = SCNVector3(direction.x * distance, direction.y * distance, direction.z * distance)
        cameraNode.look(at: SCNVector3Zero)
        // A light from the viewer (it turns with the view), one from above (tops are
        // lighter than sides, as in a room) and a soft one all around.
        let key = SCNLight()
        key.type = .directional
        key.intensity = 650
        let keyNode = SCNNode()
        keyNode.light = key
        cameraNode.addChildNode(keyNode)
        let top = SCNLight()
        top.type = .directional
        top.intensity = 450
        let topNode = SCNNode()
        topNode.light = top
        topNode.eulerAngles = SCNVector3(-CGFloat.pi / 2 - 0.4, 0.5, 0)
        scene.rootNode.addChildNode(topNode)
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 230
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)
        scene.rootNode.addChildNode(cameraNode)

        sceneView.scene = scene
        sceneView.pointOfView = cameraNode
        sceneView.allowsCameraControl = true
        sceneView.defaultCameraController.interactionMode = .orbitTurntable
        sceneView.defaultCameraController.target = SCNVector3Zero
        sceneView.antialiasingMode = .multisampling4X
        sceneView.backgroundColor = .underPageBackgroundColor
        sceneView.frame = bounds
        sceneView.autoresizingMask = [.width, .height]
        addSubview(sceneView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The model takes the mouse and the trackpad.
    var firstResponderView: NSView { sceneView }

    /// The view as a picture (for the regression checks: SceneKit does not draw into
    /// the window's cached picture).
    func snapshot() -> NSImage { sceneView.snapshot() }

    /// Brings the model nearer (`lines` > 0) or farther, as a mouse wheel does.
    func zoom(lines: CGFloat) {
        sceneView.zoom(lines: lines)
    }

    /// Triangles with a normal each (flat faces, as STL describes them), both sides
    /// lit: STL files often have some triangles facing the wrong way.
    private static func geometry(_ model: MeshDocument) -> SCNGeometry {
        func source(_ vectors: [SIMD3<Float>], _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
            let data = vectors.withUnsafeBufferPointer { Data(buffer: $0) }
            return SCNGeometrySource(data: data, semantic: semantic, vectorCount: vectors.count, usesFloatComponents: true,
                                     componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0,
                                     dataStride: MemoryLayout<SIMD3<Float>>.stride)
        }
        let indices = Array(0..<UInt32(model.positions.count)).withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(data: indices, primitiveType: .triangles, primitiveCount: model.triangleCount,
                                         bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: [source(model.positions, .vertex), source(model.normals, .normal)],
                                   elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = NSColor(calibratedRed: 0.72, green: 0.76, blue: 0.82, alpha: 1)
        material.specular.contents = NSColor(white: 0.3, alpha: 1)
        material.shininess = 0.25
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }
}

/// SceneKit's view with a mouse wheel that brings the model nearer (SceneKit's own
/// moves the view sideways, which the trackpad's scrolling still does).
private final class ModelSceneView: SCNView {
    override func scrollWheel(with event: NSEvent) {
        guard !event.hasPreciseScrollingDeltas,
              event.modifierFlags.isDisjoint(with: [.option, .command, .control, .shift]) else {
            return super.scrollWheel(with: event)
        }
        // The wheel turned away from the user brings the model nearer, whatever the
        // scrolling direction setting.
        zoom(lines: event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY)
    }

    /// Nearer for `lines` > 0.
    func zoom(lines: CGFloat) {
        defaultCameraController.dolly(toTarget: -Float(lines) * 0.12)
    }
}
