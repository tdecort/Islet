import AppKit
import SceneKit

/// Pictures of AirPods for the connection notice. AirPods Pro come from a 3D model shipped
/// with Islet: SceneKit renders it turning into place, frame by frame, the first time it is
/// needed. AirPods Max use Apple's render from macOS when it is there. Anything else keeps
/// its SF Symbol.
enum HeadphoneArt {
    /// The turn-in, first frame to last; the last frame is the resting pose.
    struct Turn {
        let frames: [NSImage]
        let duration: TimeInterval
        var still: NSImage { frames[frames.count - 1] }
    }

    private static var turns: [String: Turn] = [:]
    private static var stills: [String: NSImage] = [:]
    private static let lock = NSLock()

    /// Renders the AirPods Pro turn ahead of time, off the main thread.
    static func prewarm() {
        DispatchQueue.global(qos: .utility).async { _ = turn(for: "airpodspro") }
    }

    static func turn(for symbol: String) -> Turn? {
        guard symbol == "airpodspro" else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let cached = turns[symbol] { return cached }
        guard let frames = renderTurn(), !frames.isEmpty else { return nil }
        let t = Turn(frames: frames, duration: 1.7)
        turns[symbol] = t
        return t
    }

    /// A still picture for the device behind this symbol, or nil to keep the symbol.
    static func image(for symbol: String) -> NSImage? {
        if let t = turn(for: symbol) { return t.still }
        if let cached = stills[symbol] { return cached }
        guard symbol == "airpodsmax",
            let max = Bundle(path: "/System/Library/PrivateFrameworks/HeadphoneAssets.framework")?.image(forResource: "B515d-Default")
        else { return nil }
        stills[symbol] = max
        return max
    }

    // MARK: Rendering

    /// The model inside the app, or in the source tree when run from a build folder.
    private static var modelURL: URL? {
        let name = "AirPodsPro3/AirPodsPro3.usdc"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/\(name)"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// A full turn that slows down as it lands on a three-quarter view, while the earbuds
    /// rise out of the case.
    private static func renderTurn(frameCount: Int = 52, pixels: CGFloat = 132) -> [NSImage]? {
        guard let url = modelURL, let scene = try? SCNScene(url: url, options: [.convertToYUp: true]),
            let device = MTLCreateSystemDefaultDevice()
        else { return nil }

        // Centre the model on a pivot the camera looks at.
        let model = SCNNode()
        for child in scene.rootNode.childNodes { model.addChildNode(child) }
        let (lo, hi) = model.boundingBox
        model.position = SCNVector3(-(lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, -(lo.z + hi.z) / 2)
        let pivot = SCNNode()
        pivot.addChildNode(model)
        scene.rootNode.addChildNode(pivot)
        let radius = Swift.max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 30
        camera.camera?.zNear = Double(radius * 0.01)
        camera.camera?.zFar = Double(radius * 10)
        camera.position = SCNVector3(0, radius * 0.25, radius * 2.15)
        camera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camera)

        // Soft studio light: an even environment, one key light from the top left.
        scene.lightingEnvironment.contents = NSColor(white: 0.9, alpha: 1)
        scene.lightingEnvironment.intensity = 1.6
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-0.6, 0.5, 0)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 350
        scene.rootNode.addChildNode(fill)
        scene.background.contents = NSColor.clear

        // Both earbuds hang under one node of the model; the case (lid included) is the rest.
        let earbuds = model.childNode(withName: "YamPaavUOjSVJHE", recursively: true)
        let restingBuds = earbuds?.position
        // How far down the earbuds sit in the case: stems in their slots, tops showing.
        // Measured in the model's space, then expressed in the earbuds' parent space,
        // which the model scales.
        let sunk = earbuds?.parent?.convertVector(SCNVector3(0, -(hi.y - lo.y) * 0.32, 0), from: model)

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        let rest = -22.0, start = rest - 360
        return (0..<frameCount).map { i in
            let t = Double(i) / Double(frameCount - 1)
            let spin = 1 - pow(1 - t, 3)
            pivot.eulerAngles = SCNVector3(0, CGFloat((start + (rest - start) * spin) * .pi / 180), 0)
            if let earbuds, let restingBuds, let sunk {
                // They start rising a third of the way in, with a soft overshoot at the top.
                let r = Swift.max(0, Swift.min(1, (t - 0.3) / 0.6))
                let c1 = 1.7, c3 = c1 + 1
                let lift = r == 0 ? 0 : 1 + c3 * pow(r - 1, 3) + c1 * pow(r - 1, 2)
                let down = 1 - CGFloat(lift)
                earbuds.position = SCNVector3(
                    restingBuds.x + sunk.x * down, restingBuds.y + sunk.y * down, restingBuds.z + sunk.z * down)
            }
            return renderer.snapshot(atTime: 0, with: CGSize(width: pixels, height: pixels), antialiasingMode: .multisampling4X)
        }
    }
}
