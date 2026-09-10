import SwiftUI
import SceneKit
import UIKit

/// A coin minted from a finished piece of pin artwork.
///
/// `CoinDesign` builds a coin out of vector cells, which suits art you author
/// as paths. When you already have the finished pin as an image, this is the
/// faster and more faithful route: the artwork itself becomes the coin's
/// face, the outline is traced from the image, and the gold in the art is
/// detected and rendered as real metal that catches light.
///
///     let coin = try ArtworkCoin(image: UIImage(named: "eiffel-pin")!)
///     SpinningArtworkCoinView(coin: coin)
///
/// Everything is derived from the image at load time, so a new pin means a
/// new PNG and nothing else.
public struct ArtworkCoin {

    /// The pin's outline in normalized 0...1, y down.
    public let silhouette: CGPath
    /// Inset copies of the outline; the rim band is drawn between them.
    public let rimBands: [CGPath]
    /// The artwork, cropped square to the pin and with anything outside it
    /// cleared so texture filtering cannot drag a fringe across the edge.
    public let face: UIImage
    /// White where the artwork is gold, black elsewhere. Drives metalness.
    public let metalness: UIImage
    /// Relief baked from the gold, so painted frames and wires stand proud.
    public let relief: UIImage
    /// The pin's bounding box inside the square face, for texture mapping.
    public let contentBox: CGRect

    public enum Failure: Error {
        /// The image had no pin in it, or it filled the whole frame with no
        /// clear background to key against.
        case noPinFound(String)
    }

    /// Analyze a finished pin image into everything the mint needs.
    ///
    /// - Parameters:
    ///   - image: the pin on a plain light background.
    ///   - rimWidth: rim band width as a fraction of the coin. `nil` measures
    ///     the frame the artwork paints and matches it, which keeps the metal
    ///     on the frame instead of over the art.
    public init(image: UIImage, rimWidth: CGFloat? = nil) throws {
        guard let analysis = ArtworkAnalyzer.analyze(image: image, rimWidth: rimWidth) else {
            throw Failure.noPinFound(ArtworkAnalyzer.stage)
        }
        silhouette = analysis.silhouette
        rimBands = analysis.rimBands
        face = analysis.face
        metalness = analysis.metalness
        relief = analysis.relief
        contentBox = analysis.contentBox
    }
}

// MARK: - Scene

public enum ArtworkCoinScene {

    public static let coinNodeName = "minted.artwork.coin"
    public static let tiltNodeName = "minted.artwork.tilt"

    /// Body thickness, in coin-diameter units. Pins are thin.
    private static let thickness: CGFloat = 0.055

    public static func makeScene(coin: ArtworkCoin, gold: UIColor = CoinPalette.roseGold) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear
        scene.lightingEnvironment.contents = studioEnvironment
        scene.lightingEnvironment.intensity = 0.85

        let tilt = SCNNode()
        tilt.name = tiltNodeName
        tilt.eulerAngles = SCNVector3(-0.14, 0, 0)
        scene.rootNode.addChildNode(tilt)

        let node = SCNNode()
        node.name = coinNodeName
        tilt.addChildNode(node)

        // SCNShape spreads texture coordinates across the shape's bounding
        // box while the face image is square with the pin centred in it, so
        // the UVs are remapped to the box the pin occupies. Without this a
        // tall pin squeezes its artwork inward and shows flat margins.
        let box = coin.contentBox
        let uv = SCNMatrix4Mult(
            SCNMatrix4MakeScale(Float(box.width), Float(box.height), 1),
            SCNMatrix4MakeTranslation(Float(box.minX), Float(box.minY), 0))

        let faceMaterial = SCNMaterial()
        faceMaterial.lightingModel = .physicallyBased
        faceMaterial.diffuse.contents = coin.face
        faceMaterial.metalness.contents = coin.metalness
        faceMaterial.normal.contents = coin.relief
        faceMaterial.normal.intensity = 0.55
        faceMaterial.roughness.contents = 0.55
        for property in [faceMaterial.diffuse, faceMaterial.metalness, faceMaterial.normal] {
            property.wrapS = .clamp
            property.wrapT = .clamp
            property.contentsTransform = uv
        }

        let body = shapeNode(path: coin.silhouette, depth: thickness, material: goldMaterial(gold))
        body.geometry?.materials = [faceMaterial, backMaterial(gold), goldMaterial(gold),
                                    goldMaterial(gold), goldMaterial(gold)]
        node.addChildNode(body)

        // Rim bands sit between the outline and its inset copies, so metal
        // never spills past the artwork the way a centred stroke does.
        var previous = coin.silhouette
        for (index, inner) in coin.rimBands.enumerated() {
            let band = CGMutablePath()
            band.addPath(previous)
            band.addPath(reversed(inner))
            node.addChildNode(shapeNode(path: band, depth: 0.03,
                                        material: goldMaterial(gold),
                                        rise: 0.005 + CGFloat(index) * 0.006))
            previous = inner
        }

        addLights(to: scene)
        return scene
    }

    // MARK: Geometry

    private static func shapeNode(path: CGPath, depth: CGFloat, material: SCNMaterial,
                                  rise: CGFloat = 0) -> SCNNode {
        var transform = CGAffineTransform.identity
            .scaledBy(x: 1, y: -1)
            .translatedBy(x: -0.5, y: -0.5)
        let remapped = (path.copy(using: &transform) ?? path).normalized(using: .winding)
        let bezier = UIBezierPath(cgPath: remapped)
        bezier.flatness = 0.001
        let shape = SCNShape(path: bezier, extrusionDepth: depth)
        shape.materials = [material]
        let node = SCNNode(geometry: shape)
        if rise != 0 {
            node.position.z = Float(thickness / 2 - depth / 2 + rise)
        }
        return node
    }

    /// A ring wound the other way, so adding it to a path cuts a hole.
    private static func reversed(_ path: CGPath) -> CGPath {
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint:
                points.append(element.pointee.points[0])
            default: break
            }
        }
        guard let first = points.last else { return path }
        let out = CGMutablePath()
        out.move(to: first)
        for point in points.dropLast().reversed() { out.addLine(to: point) }
        out.closeSubpath()
        return out
    }

    // MARK: Materials and light

    private static func goldMaterial(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = 1.0
        m.roughness.contents = 0.28
        return m
    }

    private static func backMaterial(_ color: UIColor) -> SCNMaterial {
        let m = goldMaterial(color)
        m.normal.contents = orangePeel
        m.normal.intensity = 0.5
        m.roughness.contents = 0.36
        return m
    }

    private static func addLights(to scene: SCNScene) {
        func light(_ intensity: CGFloat, _ color: UIColor, _ angles: SCNVector3) -> SCNNode {
            let node = SCNNode()
            node.light = SCNLight()
            node.light?.type = .directional
            node.light?.intensity = intensity
            node.light?.color = color
            node.eulerAngles = angles
            return node
        }
        // Painted artwork blows out under a full metal rig, so this one is
        // deliberately soft; the gold still reads via the metalness mask.
        scene.rootNode.addChildNode(light(400, UIColor(red: 1, green: 0.96, blue: 0.9, alpha: 1),
                                          SCNVector3(-0.5, 0.4, 0)))
        scene.rootNode.addChildNode(light(150, UIColor(red: 0.88, green: 0.92, blue: 1, alpha: 1),
                                          SCNVector3(-0.15, -0.9, 0)))
        scene.rootNode.addChildNode(light(250, UIColor(red: 1, green: 0.93, blue: 0.85, alpha: 1),
                                          SCNVector3(-0.3, .pi - 0.4, 0)))

        let camera = SCNCamera()
        camera.fieldOfView = 26
        camera.zNear = 0.1
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 2.75)
        scene.rootNode.addChildNode(cameraNode)
        cameraNode.addChildNode(light(160, UIColor(red: 1, green: 0.97, blue: 0.92, alpha: 1),
                                      SCNVector3(0, 0, 0)))
    }

    /// A studio room for reflections: repeated softboxes so a turning coin
    /// always has a highlight to catch, plus a warm floor bounce.
    private static let studioEnvironment: UIImage = {
        let size = CGSize(width: 1024, height: 512)
        return UIGraphicsImageRenderer(size: size).image { context in
            let ctx = context.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let surround = CGGradient(colorsSpace: space, colors: [
                UIColor(red: 0.30, green: 0.28, blue: 0.25, alpha: 1).cgColor,
                UIColor(red: 0.20, green: 0.19, blue: 0.19, alpha: 1).cgColor,
                UIColor(red: 0.10, green: 0.08, blue: 0.07, alpha: 1).cgColor,
            ] as CFArray, locations: [0, 0.55, 1])!
            ctx.drawLinearGradient(surround, start: .zero,
                                   end: CGPoint(x: 0, y: size.height), options: [])

            func softbox(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat,
                         white: CGFloat, alpha: CGFloat) {
                let colors = [UIColor(white: white, alpha: alpha).cgColor,
                              UIColor(white: white, alpha: 0).cgColor]
                guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray,
                                                locations: [0, 1]) else { return }
                ctx.saveGState()
                ctx.translateBy(x: cx, y: cy)
                ctx.scaleBy(x: rx / ry, y: 1)
                ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                                       endCenter: .zero, endRadius: ry, options: [])
                ctx.restoreGState()
            }
            for (fraction, white) in [(0.10, 0.95), (0.43, 0.70), (0.76, 0.86)] {
                softbox(cx: size.width * fraction, cy: size.height * 0.14,
                        rx: size.width * 0.22, ry: size.height * 0.16, white: white, alpha: 1)
            }
            softbox(cx: size.width * 0.5, cy: size.height * 0.92,
                    rx: size.width * 0.60, ry: size.height * 0.12, white: 0.45, alpha: 0.3)
        }
    }()

    /// Orange-peel relief for the coin's back, like a die-struck medal.
    private static let orangePeel: UIImage = {
        let side: CGFloat = 512
        var generator = SeededGenerator(seed: 0xC01B)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let ctx = context.cgContext
            ctx.setFillColor(UIColor(white: 0.5, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            func layer(count: Int, radius: ClosedRange<CGFloat>, spread: CGFloat) {
                for _ in 0..<count {
                    let x = CGFloat.random(in: 0...side, using: &generator)
                    let y = CGFloat.random(in: 0...side, using: &generator)
                    let r = CGFloat.random(in: radius, using: &generator)
                    let bright = 0.5 + CGFloat.random(in: -spread...spread, using: &generator)
                    let colors = [UIColor(white: bright, alpha: 0.35).cgColor,
                                  UIColor(white: bright, alpha: 0).cgColor]
                    guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                                                    colors: colors as CFArray,
                                                    locations: [0, 1]) else { continue }
                    ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: x, y: y),
                                           startRadius: 0, endCenter: CGPoint(x: x, y: y),
                                           endRadius: r, options: [])
                }
            }
            layer(count: 400, radius: 10...16, spread: 0.05)
            layer(count: 2600, radius: 4...8, spread: 0.07)
            layer(count: 4000, radius: 2...3, spread: 0.09)
        }
    }()

    /// Deterministic randomness so the back never shimmers between renders.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }
}

// MARK: - Views

/// The artwork coin, alive: idles in a slow spin, drag to flick it.
public struct SpinningArtworkCoinView: UIViewRepresentable {
    private let coin: ArtworkCoin
    private let idlePeriod: Double
    private let initialRotation: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(coin: ArtworkCoin, idlePeriod: Double = 11, initialRotation: Double = 0) {
        self.coin = coin
        self.idlePeriod = idlePeriod
        self.initialRotation = initialRotation
    }

    public func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        view.scene = ArtworkCoinScene.makeScene(coin: coin)
        let node = view.scene?.rootNode.childNode(withName: ArtworkCoinScene.coinNodeName,
                                                  recursively: true)
        node?.eulerAngles.y = Float(initialRotation)
        context.coordinator.coin = node
        context.coordinator.idlePeriod = idlePeriod
        if !reduceMotion {
            node?.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0,
                                                     duration: idlePeriod)), forKey: "idle")
        }
        view.addGestureRecognizer(UIPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.pan(_:))))
        return view
    }

    public func updateUIView(_ view: SCNView, context: Context) {}

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator: NSObject {
        var coin: SCNNode?
        var idlePeriod: Double = 11
        private var idleWasRunning = false

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let coin, let view = gesture.view else { return }
            switch gesture.state {
            case .began:
                idleWasRunning = coin.action(forKey: "idle") != nil
                coin.removeAction(forKey: "idle")
                coin.removeAction(forKey: "momentum")
            case .changed:
                coin.eulerAngles.y += Float(gesture.translation(in: view).x) * 0.012
                gesture.setTranslation(.zero, in: view)
            case .ended, .cancelled:
                let spin = SCNAction.rotateBy(x: 0, y: gesture.velocity(in: view).x * 0.0022,
                                              z: 0, duration: 1.4)
                spin.timingMode = .easeOut
                let period = idlePeriod
                coin.runAction(spin, forKey: "momentum") { [weak self, weak coin] in
                    guard let self, self.idleWasRunning, let coin else { return }
                    coin.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0,
                                                            duration: period)), forKey: "idle")
                }
            default:
                break
            }
        }
    }
}

// MARK: - Bundled reference art

public extension ArtworkCoin {

    /// Pin artwork that ships with the package, for demos and for seeing the
    /// pipeline work before you supply your own.
    enum Sample: String, CaseIterable {
        case eiffelTower = "eiffel-tower"
        case swissAlps = "swiss-alps"
        case amsterdamCanals = "amsterdam-canals"
        case alhambra
        case acropolis
        case santorini
        case mountFuji = "mount-fuji"
        case kinkakuJi = "kinkaku-ji"

        public var image: UIImage? {
            guard let url = Bundle.module.url(forResource: rawValue, withExtension: "jpg",
                                              subdirectory: "ReferenceArt")
                ?? Bundle.module.url(forResource: rawValue, withExtension: "jpg"),
                  let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }
    }

    /// Mint one of the bundled sample pins.
    init(sample: Sample) throws {
        guard let image = sample.image else { throw Failure.noPinFound("missing bundled art") }
        try self.init(image: image)
    }
}
