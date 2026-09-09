import Metal
import SceneKit
import UIKit

/// Builds the SceneKit scene for a coin: one solid gold body extruded from
/// the silhouette, enamel cells set nearly flush into the face, a raised
/// gold wire drawing the art the way cloisonne does, and a studio lighting
/// environment so the metal actually glints as it turns.
public enum CoinScene {

    /// Node names, for tests and for finding the spinnable node.
    public static let coinNodeName = "minted.coin"
    public static let tiltNodeName = "minted.tilt"

    // Coin proportions, in coin-diameter units (the coin is 1.0 wide).
    private static let baseDepth: CGFloat = 0.10
    private static let artScale: CGFloat = 0.50
    private static let wireWidth: CGFloat = 0.012
    private static let fieldRadius: Double = 0.30
    private static let textRadius: Double = 0.378
    private static let capHeight: Double = 0.054

    public static func makeScene(design: CoinDesign) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear
        scene.lightingEnvironment.contents = studioEnvironment
        scene.lightingEnvironment.intensity = 1.5

        // A slight fixed tilt gives the coin depth even in still renders;
        // the child spins so the tilt never wobbles.
        let tilt = SCNNode()
        tilt.name = tiltNodeName
        tilt.eulerAngles = SCNVector3(-0.14, 0, 0)
        scene.rootNode.addChildNode(tilt)

        let coin = SCNNode()
        coin.name = coinNodeName
        tilt.addChildNode(coin)

        let gold = design.palette.gold
        let silhouette = design.silhouettePath()

        // The coin body: solid gold, orange-peel textured on the back like a
        // die-struck pin's reverse. SCNShape hands out five material slots:
        // front, back, side, front chamfer, back chamfer.
        let base = shapeNode(path: silhouette, depth: baseDepth, material: goldMaterial(gold))
        base.geometry?.materials = [goldMaterial(gold), orangePeelGoldMaterial(gold),
                                    goldMaterial(gold), goldMaterial(gold), goldMaterial(gold)]
        coin.addChildNode(base)

        // The rim: two stacked gold bands, wider then narrower, so the lip
        // reads as a rounded roll of metal without relying on chamfers.
        // Never set chamferRadius on an SCNShape built from polyline paths:
        // it silently produces empty geometry. The stacked bands are the fix.
        coin.addChildNode(shapeNode(path: stroked(silhouette, width: 0.052),
                                    depth: 0.03, material: goldMaterial(gold), rise: 0.012))
        coin.addChildNode(shapeNode(path: stroked(silhouette, width: 0.030),
                                    depth: 0.03, material: goldMaterial(gold), rise: 0.022))

        // The engraving backdrop behind the art. Every slab keeps its back
        // buried inside the body via `rise`, so nothing pokes out the
        // coin's reverse.
        switch design.engraving {
        case .petals:
            // Rosette petals, gold showing through the gaps.
            coin.addChildNode(shapeNode(path: design.petalPath(), depth: 0.03,
                                        material: enamelMaterial(design.palette.field),
                                        rise: 0.006))
        case .rays:
            // Classic medal look: an enamel field disc with gold sunbursts.
            coin.addChildNode(shapeNode(path: design.innerDiscPath(radius: fieldRadius),
                                        depth: 0.03,
                                        material: enamelMaterial(design.palette.field),
                                        rise: 0.005))
            coin.addChildNode(shapeNode(path: design.raysPath(), depth: 0.03,
                                        material: goldMaterial(gold), rise: 0.010))
        case .lattice:
            coin.addChildNode(shapeNode(path: design.innerDiscPath(radius: fieldRadius),
                                        depth: 0.03,
                                        material: enamelMaterial(design.palette.field),
                                        rise: 0.005))
            coin.addChildNode(shapeNode(path: design.latticePath(radius: fieldRadius),
                                        depth: 0.03, material: goldMaterial(gold), rise: 0.010))
        case .plain:
            break   // bare gold face, letting the art carry the coin
        }

        // The art as enamel cells with a raised gold wire hugging every
        // edge: the gold draws the design, the enamel fills it. A split
        // below 1 divides the cells into two colors along the seam.
        let artPath = centered(design.art, scale: artScale)
        if design.palette.artSplit >= 1 {
            coin.addChildNode(shapeNode(path: artPath, depth: 0.03,
                                        material: enamelMaterial(design.palette.art),
                                        rise: 0.012))
        } else {
            let cells = design.artCells(scaledArt: artPath, splitY: design.palette.artSplit)
            coin.addChildNode(shapeNode(path: cells.upper, depth: 0.03,
                                        material: enamelMaterial(design.palette.art),
                                        rise: 0.012))
            coin.addChildNode(shapeNode(path: cells.lower, depth: 0.03,
                                        material: enamelMaterial(design.palette.artLower
                                                                 ?? design.palette.art),
                                        rise: 0.012))
        }
        coin.addChildNode(shapeNode(path: stroked(artPath, width: wireWidth), depth: 0.03,
                                    material: goldMaterial(gold), rise: 0.02))

        // Minted beads inside the rim, and the lettering around the arcs of
        // the gold margin, deep enough in relief to read.
        coin.addChildNode(shapeNode(path: design.beadPath(), depth: 0.03,
                                    material: goldMaterial(gold), rise: 0.013))
        if !design.topText.isEmpty {
            coin.addChildNode(shapeNode(path: design.arcTextPath(design.topText,
                                                                 textRadius: textRadius,
                                                                 capHeight: capHeight,
                                                                 onTop: true),
                                        depth: 0.03, material: engravedGoldMaterial(),
                                        rise: 0.018))
        }
        if !design.bottomText.isEmpty {
            coin.addChildNode(shapeNode(path: design.arcTextPath(design.bottomText,
                                                                 textRadius: textRadius,
                                                                 capHeight: capHeight,
                                                                 onTop: false),
                                        depth: 0.03, material: engravedGoldMaterial(),
                                        rise: 0.018))
        }

        // Key light for a hot specular hit; the environment does the rest.
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 800
        key.light?.color = UIColor(red: 1, green: 0.96, blue: 0.9, alpha: 1)
        key.eulerAngles = SCNVector3(-0.5, 0.4, 0)
        scene.rootNode.addChildNode(key)

        // Cool fill from the far side so a spinning face never goes muddy.
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 300
        fill.light?.color = UIColor(red: 0.88, green: 0.92, blue: 1, alpha: 1)
        fill.eulerAngles = SCNVector3(-0.15, -0.9, 0)
        scene.rootNode.addChildNode(fill)

        // Warm kicker aimed at the back so the reverse gleams too.
        let back = SCNNode()
        back.light = SCNLight()
        back.light?.type = .directional
        back.light?.intensity = 500
        back.light?.color = UIColor(red: 1, green: 0.93, blue: 0.85, alpha: 1)
        back.eulerAngles = SCNVector3(-0.3, .pi - 0.4, 0)
        scene.rootNode.addChildNode(back)

        let camera = SCNCamera()
        camera.fieldOfView = 26
        camera.zNear = 0.1
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 2.75)
        scene.rootNode.addChildNode(cameraNode)

        // Headlight riding the camera: whatever face the viewer sees is
        // never unlit, no matter how far the coin has turned.
        let headlight = SCNNode()
        headlight.light = SCNLight()
        headlight.light?.type = .directional
        headlight.light?.intensity = 320
        headlight.light?.color = UIColor(red: 1, green: 0.97, blue: 0.92, alpha: 1)
        cameraNode.addChildNode(headlight)

        return scene
    }

    // MARK: Geometry helpers

    /// An SCNShape node from a normalized 0...1 y-down path, remapped to a
    /// centered, y-up coin of diameter 1. A nonzero `rise` sits the slab's
    /// front that far proud of the coin face, back buried inside the base so
    /// nothing pokes through the coin's reverse.
    private static func shapeNode(path: CGPath, depth: CGFloat, material: SCNMaterial,
                                  rise: CGFloat = 0) -> SCNNode {
        var transform = CGAffineTransform.identity
            .scaledBy(x: 1, y: -1)
            .translatedBy(x: -0.5, y: -0.5)
        let remapped = path.copy(using: &transform) ?? path
        let bezier = UIBezierPath(cgPath: remapped)
        bezier.flatness = 0.001
        let shape = SCNShape(path: bezier, extrusionDepth: depth)
        shape.materials = [material]
        let node = SCNNode(geometry: shape)
        if rise != 0 {
            node.position.z = Float(baseDepth / 2 - depth / 2 + rise)
        }
        return node
    }

    /// The center art placed mid-face at the given fraction of the coin width.
    private static func centered(_ art: CGPath, scale: CGFloat) -> CGPath {
        let box = art.boundingBoxOfPath
        guard box.width > 0, box.height > 0 else { return art }
        let fit = scale / max(box.width, box.height)
        var transform = CGAffineTransform.identity
            .translatedBy(x: 0.5, y: 0.5)
            .scaledBy(x: fit, y: fit)
            .translatedBy(x: -box.midX, y: -box.midY)
        return art.copy(using: &transform) ?? art
    }

    private static func stroked(_ path: CGPath, width: CGFloat) -> CGPath {
        path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4)
    }

    // MARK: Materials

    private static func goldMaterial(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = 1.0
        m.roughness.contents = 0.28
        return m
    }

    /// A shade deeper than the face gold so engraved lettering stays legible
    /// under hot reflections while remaining unmistakably metal.
    private static func engravedGoldMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = UIColor(red: 0.60, green: 0.42, blue: 0.24, alpha: 1)
        m.metalness.contents = 0.55
        m.roughness.contents = 0.42
        return m
    }

    private static func enamelMaterial(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.metalness.contents = 0.0
        m.roughness.contents = 0.08
        return m
    }

    /// Orange-peel bump for the coin's back: soft random dimples fed to
    /// SceneKit as a height map.
    private static func orangePeelGoldMaterial(_ color: UIColor) -> SCNMaterial {
        let m = goldMaterial(color)
        m.normal.contents = orangePeelHeightMap
        m.normal.intensity = 0.5
        m.roughness.contents = 0.36
        return m
    }

    // MARK: Generated textures

    /// A studio "room" for reflections: a big soft key box, a second fill
    /// box, a diagonal window streak, and a warm floor bounce over a graded
    /// surround, so the metal picks up varied, photographic light instead of
    /// a flat gradient.
    private static let studioEnvironment: UIImage = {
        let size = CGSize(width: 1024, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let ctx = context.cgContext
            let space = CGColorSpaceCreateDeviceRGB()

            // Graded surround: dark warm floor up to a dim cool ceiling.
            let surround = CGGradient(colorsSpace: space, colors: [
                UIColor(red: 0.30, green: 0.28, blue: 0.25, alpha: 1).cgColor,
                UIColor(red: 0.20, green: 0.19, blue: 0.19, alpha: 1).cgColor,
                UIColor(red: 0.10, green: 0.08, blue: 0.07, alpha: 1).cgColor,
            ] as CFArray, locations: [0, 0.55, 1])!
            ctx.drawLinearGradient(surround, start: .zero,
                                   end: CGPoint(x: 0, y: size.height), options: [])

            /// A soft elliptical light drawn as a squashed radial gradient.
            func softbox(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat,
                         r: CGFloat, g: CGFloat, b: CGFloat, alpha: CGFloat) {
                let colors = [UIColor(red: r, green: g, blue: b, alpha: alpha).cgColor,
                              UIColor(red: r, green: g, blue: b, alpha: 0).cgColor]
                guard let gradient = CGGradient(colorsSpace: space,
                                                colors: colors as CFArray,
                                                locations: [0, 1]) else { return }
                ctx.saveGState()
                ctx.translateBy(x: cx, y: cy)
                ctx.scaleBy(x: rx / ry, y: 1)
                ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                                       endCenter: .zero, endRadius: ry, options: [])
                ctx.restoreGState()
            }

            // Light boxes repeat around the panorama so the coin catches a
            // bright reflection at every rotation angle; brightness varies so
            // the light still sweeps as it turns.
            for (fraction, brightness) in [(0.10, 1.0), (0.43, 0.72), (0.76, 0.88)] {
                softbox(cx: size.width * fraction, cy: size.height * 0.14,
                        rx: size.width * 0.22, ry: size.height * 0.16,
                        r: brightness, g: brightness * 0.97, b: brightness * 0.90, alpha: 1)
            }
            for (fraction, brightness) in [(0.26, 0.55), (0.60, 0.45), (0.93, 0.60)] {
                softbox(cx: size.width * fraction, cy: size.height * 0.32,
                        rx: size.width * 0.13, ry: size.height * 0.09,
                        r: brightness * 0.94, g: brightness * 0.94, b: brightness, alpha: 0.8)
            }
            ctx.saveGState()
            ctx.translateBy(x: size.width * 0.55, y: size.height * 0.55)
            ctx.rotate(by: -0.5)
            softbox(cx: 0, cy: 0, rx: size.width * 0.28, ry: size.height * 0.045,
                    r: 0.9, g: 0.92, b: 1.0, alpha: 0.5)
            ctx.restoreGState()
            softbox(cx: size.width * 0.5, cy: size.height * 0.92,
                    rx: size.width * 0.60, ry: size.height * 0.12,
                    r: 0.55, g: 0.42, b: 0.28, alpha: 0.6)
        }
    }()

    /// Orange-peel skin for the back: three sizes of soft dimples layered
    /// dense and overlapping, like the imperfect surface of a die-struck
    /// medal. Fed to SceneKit as a height map.
    private static let orangePeelHeightMap: UIImage = {
        let side: CGFloat = 512
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        var generator = SeededGenerator(seed: 0xC01B)
        return renderer.image { context in
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
                    ctx.drawRadialGradient(gradient,
                                           startCenter: CGPoint(x: x, y: y), startRadius: 0,
                                           endCenter: CGPoint(x: x, y: y), endRadius: r,
                                           options: [])
                }
            }
            layer(count: 400, radius: 10...16, spread: 0.05)   // broad undulation
            layer(count: 2600, radius: 4...8, spread: 0.07)    // the peel itself
            layer(count: 4000, radius: 2...3, spread: 0.09)    // fine grain
        }
    }()

    /// Deterministic randomness so the back texture never shimmers between
    /// renders of the same coin.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }
}
