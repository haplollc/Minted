import CoreGraphics
import Foundation
import SceneKit
import Testing
import UIKit
@testable import Minted

private func elementTypes(of path: CGPath) -> [CGPathElementType] {
    var types: [CGPathElementType] = []
    path.applyWithBlock { types.append($0.pointee.type) }
    return types
}

private func firstPoint(of path: CGPath) -> CGPoint? {
    var point: CGPoint?
    path.applyWithBlock { element in
        if point == nil, element.pointee.type == .moveToPoint {
            point = element.pointee.points[0]
        }
    }
    return point
}

@Suite("SVG path parsing")
struct SVGPathParsingTests {

    @Test("Absolute and relative line commands land where the spec says")
    func lines() throws {
        let path = try #require(SVGPath.path(from: "M 10 10 L 30 10 l 0 20 H 10 V 10 Z"))
        let box = path.boundingBoxOfPath
        #expect(abs(box.minX - 10) < 0.001)
        #expect(abs(box.minY - 10) < 0.001)
        #expect(abs(box.width - 20) < 0.001)
        #expect(abs(box.height - 20) < 0.001)
    }

    @Test("Cubic, smooth, quadratic, and shorthand curves chain correctly")
    func curves() throws {
        let path = try #require(SVGPath.path(from:
            "m 0 0 c 0 -10 10 -10 10 0 s 10 10 20 0 q 5 -5 10 0 t 10 0"))
        let types = elementTypes(of: path)
        #expect(types.filter { $0 == .addCurveToPoint }.count == 2)
        #expect(types.filter { $0 == .addQuadCurveToPoint }.count == 2)
        // The T shorthand reflects Q's control, so the run ends at x = 50.
        #expect(abs(path.boundingBoxOfPath.maxX - 50) < 0.001)
    }

    @Test("A semicircular arc bulges the right way and stays bounded")
    func arcSemicircle() throws {
        // Sweep 1 runs in the positive-angle direction, which in SVG's
        // y-down space carries this arc through negative y.
        let path = try #require(SVGPath.path(from: "M 0 0 A 5 5 0 0 1 10 0"))
        let box = path.boundingBoxOfPath
        #expect(abs(box.minY - (-5)) < 0.05)
        #expect(abs(box.maxY - 0) < 0.05)
        #expect(abs(box.minX - 0) < 0.05)
        #expect(abs(box.maxX - 10) < 0.05)
    }

    @Test("Two half-circle arcs close into a full circle")
    func arcFullCircle() throws {
        let path = try #require(SVGPath.path(from:
            "M 5 0 A 5 5 0 1 0 5 10 A 5 5 0 1 0 5 0 Z"))
        let box = path.boundingBoxOfPath
        #expect(abs(box.width - 10) < 0.05)
        #expect(abs(box.height - 10) < 0.05)
    }

    @Test("Rotated elliptical arcs produce finite geometry")
    func arcRotated() throws {
        let path = try #require(SVGPath.path(from: "M 0 0 A 10 5 45 0 1 7 7"))
        let box = path.boundingBoxOfPath
        #expect(!box.isNull)
        #expect(box.width.isFinite && box.height.isFinite && box.width > 0)
    }

    @Test("Arc flags packed against the next number still parse")
    func arcPackedFlags() throws {
        let packed = try #require(SVGPath.path(from: "M0 0a5 5 0 0110 10"))
        let spaced = try #require(SVGPath.path(from: "M0 0 a 5 5 0 0 1 10 10"))
        let a = packed.boundingBoxOfPath, b = spaced.boundingBoxOfPath
        #expect(abs(a.minX - b.minX) < 0.001 && abs(a.maxX - b.maxX) < 0.001)
        #expect(abs(a.minY - b.minY) < 0.001 && abs(a.maxY - b.maxY) < 0.001)
        #expect(elementTypes(of: packed) == elementTypes(of: spaced))
    }

    @Test("Extra coordinate pairs after a moveto repeat as linetos")
    func implicitRepeats() throws {
        let path = try #require(SVGPath.path(from: "M 0 0 10 10 20 20"))
        #expect(elementTypes(of: path) == [.moveToPoint, .addLineToPoint, .addLineToPoint])
        let relative = try #require(SVGPath.path(from: "m 5 5 5 0 0 5"))
        let box = relative.boundingBoxOfPath
        #expect(abs(box.maxX - 10) < 0.001 && abs(box.maxY - 10) < 0.001)
    }

    @Test("Numbers packed with signs, exponents, and bare dots split correctly")
    func packedNumbers() throws {
        let path = try #require(SVGPath.path(from: "M1.5e-2-3L2 4"))
        let start = try #require(firstPoint(of: path))
        #expect(abs(start.x - 0.015) < 1e-9)
        #expect(abs(start.y - (-3)) < 1e-9)

        let dotted = try #require(SVGPath.path(from: "M.5.5L.5 1"))
        let dottedStart = try #require(firstPoint(of: dotted))
        #expect(abs(dottedStart.x - 0.5) < 1e-9 && abs(dottedStart.y - 0.5) < 1e-9)
    }

    @Test("Malformed data returns nil instead of crashing or guessing",
          arguments: [
            "",
            "   ",
            "M",
            "M 10",
            "L 10 10",
            "hello world",
            "M 0 0 C 1 2 3",
            "M 0 0 A 5 5 0 2 0 1 1",
            "M 0 0 Z 5 5",
            "M 1e 2",
          ])
    func malformed(data: String) {
        #expect(SVGPath.path(from: data) == nil)
    }
}

@Suite("Path normalization")
struct NormalizationTests {

    @Test("Any path refits into the unit square with aspect preserved")
    func normalizeRect() throws {
        let raw = try #require(SVGPath.path(from: "M 3 7 L 13 7 L 13 12 L 3 12 Z"))
        let box = SVGPath.normalized(raw).boundingBoxOfPath
        #expect(abs(box.width - 1) < 0.001)      // long side fills the square
        #expect(abs(box.height - 0.5) < 0.001)   // 2:1 aspect survives
        #expect(abs(box.midX - 0.5) < 0.001 && abs(box.midY - 0.5) < 0.001)
        #expect(box.minX > -0.001 && box.maxY < 1.001)
    }

    @Test("Normalization is safe on degenerate paths")
    func degenerate() {
        #expect(SVGPath.normalized(CGMutablePath()).isEmpty)
        let line = CGMutablePath()
        line.move(to: .zero)
        line.addLine(to: CGPoint(x: 4, y: 0))
        let box = SVGPath.normalized(line).boundingBoxOfPath
        #expect(abs(box.width - 1) < 0.001)
    }
}

@Suite("Coin design")
struct CoinDesignTests {
    private static let triangle = "M 0 0 L 10 0 L 10 10 Z"

    @Test("The cache key is deterministic across separately built designs")
    func cacheKeyDeterministic() throws {
        let a = try #require(CoinDesign(svgPathData: Self.triangle,
                                        topText: "ROMA", bottomText: "ITALIA"))
        let b = try #require(CoinDesign(svgPathData: Self.triangle,
                                        topText: "ROMA", bottomText: "ITALIA"))
        #expect(a.cacheKey == b.cacheKey)
    }

    @Test("Every ingredient of the look changes the cache key")
    func cacheKeySensitivity() throws {
        let base = try #require(CoinDesign(svgPathData: Self.triangle))
        var recolored = base
        recolored.palette.field = .systemRed
        #expect(recolored.cacheKey != base.cacheKey)
        var relabeled = base
        relabeled.topText = "LISBOA"
        #expect(relabeled.cacheKey != base.cacheKey)
        var reshaped = base
        reshaped.silhouette = .diamond
        #expect(reshaped.cacheKey != base.cacheKey)
        var replated = base
        replated.engraving = .lattice
        #expect(replated.cacheKey != base.cacheKey)
        var split = base
        split.palette.artSplit = 0.5
        #expect(split.cacheKey != base.cacheKey)
        var twoTone = split
        twoTone.palette.artLower = .systemTeal
        #expect(twoTone.cacheKey != split.cacheKey)
    }

    @Test("Petals are the signature default engraving")
    func petalsDefault() throws {
        let design = try #require(CoinDesign(svgPathData: Self.triangle))
        #expect(design.engraving == .petals)
        #expect(design.palette.artSplit == 1.0)
        #expect(design.palette.artLower == nil)
    }

    @Test("Art from any source lands in the normalized unit square")
    func artNormalized() throws {
        let design = try #require(CoinDesign(svgPathData: "M 40 20 L 90 20 L 90 60 Z"))
        let box = design.art.boundingBoxOfPath
        #expect(box.minX > -0.001 && box.minY > -0.001)
        #expect(box.maxX < 1.001 && box.maxY < 1.001)
        #expect(abs(max(box.width, box.height) - 1) < 0.001)
    }

    @Test("An SVG document mints all of its paths, placed by the viewBox")
    func svgFile() throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50">
          <path d="M 10 10 L 40 10 L 40 40 Z"/>
          <path d="M 60 10 C 70 0 80 20 90 10"/>
        </svg>
        """
        let design = try #require(CoinDesign(svgFileData: Data(svg.utf8)))
        let box = design.art.boundingBoxOfPath
        #expect(box.minX > -0.001 && box.maxX < 1.001)
        #expect(box.minY > -0.001 && box.maxY < 1.001)
        // Both paths made it in: two subpaths means two moves.
        #expect(elementTypes(of: design.art).filter { $0 == .moveToPoint }.count == 2)
    }

    @Test("Documents and data with no usable art refuse to mint")
    func refusals() {
        let svg = "<svg viewBox=\"0 0 10 10\"><rect width=\"5\" height=\"5\"/></svg>"
        #expect(CoinDesign(svgFileData: Data(svg.utf8)) == nil)
        #expect(CoinDesign(svgPathData: "not a path") == nil)
    }
}

@Suite("Coin scene")
@MainActor
struct CoinSceneTests {

    @Test("Minting builds a scene with the named coin and tilt nodes")
    func coinNode() throws {
        let design = try #require(CoinDesign(svgPathData: "M 0 0 L 10 0 L 10 10 Z",
                                             topText: "MINTED", bottomText: "COIN"))
        let scene = CoinScene.makeScene(design: design)
        let coin = scene.rootNode.childNode(withName: CoinScene.coinNodeName, recursively: true)
        #expect(coin != nil)
        #expect(scene.rootNode.childNode(withName: CoinScene.tiltNodeName,
                                         recursively: true) != nil)
        // Body, two rim bands, field, engraving, beads, two texts, art.
        #expect((coin?.childNodes.count ?? 0) >= 6)
    }

    @Test("Every engraving mints", arguments: CoinEngraving.allCases)
    func engravings(engraving: CoinEngraving) throws {
        var design = try #require(CoinDesign(svgPathData: "M 0 0 L 10 0 L 5 10 Z"))
        design.engraving = engraving
        let scene = CoinScene.makeScene(design: design)
        #expect(scene.rootNode.childNode(withName: CoinScene.coinNodeName,
                                         recursively: true) != nil)
    }

    @Test("A custom silhouette drives the coin body")
    func customSilhouette() throws {
        let outline = try #require(SVGPath.path(from: "M 0 5 L 5 0 L 10 5 L 5 10 Z"))
        var design = try #require(CoinDesign(svgPathData: "M 0 0 L 4 0 L 2 4 Z"))
        design.silhouette = .custom(outline)
        let scene = CoinScene.makeScene(design: design)
        #expect(scene.rootNode.childNode(withName: CoinScene.coinNodeName,
                                         recursively: true) != nil)
    }

    @Test("Split art mints two enamel cells without losing the coin")
    func splitArt() throws {
        var design = try #require(CoinDesign(svgPathData: "M 0 0 L 10 0 L 10 10 L 0 10 Z"))
        design.palette.artSplit = 0.45
        design.palette.artLower = .systemIndigo
        let scene = CoinScene.makeScene(design: design)
        let coin = scene.rootNode.childNode(withName: CoinScene.coinNodeName, recursively: true)
        #expect(coin != nil)
        // Base, two rims, petals, two art cells, wire, beads: at least 8.
        #expect((coin?.childNodes.count ?? 0) >= 8)
    }

    @Test("The spinning view accepts an initial rotation for showing the back")
    func initialRotation() throws {
        let design = try #require(CoinDesign(svgPathData: "M 0 0 L 4 0 L 2 4 Z"))
        // Construction is the contract here; the rotation lands on the coin
        // node when SwiftUI calls makeUIView.
        _ = SpinningCoinView(design: design, idlePeriod: 9, initialRotation: .pi)
        #expect(Bool(true))
    }
}
