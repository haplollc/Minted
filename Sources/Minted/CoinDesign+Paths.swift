import CoreText
import SwiftUI
import UIKit

// Decorative geometry, all in the normalized 0...1 y-down square, shared by
// the 3D mint and the flat line art.
extension CoinDesign {

    /// The silhouette outline, for both the 3D coin and the flat rendering.
    func silhouettePath() -> CGPath {
        if case .custom(let outline) = silhouette {
            return SVGPath.normalized(outline)
        }
        let path = CGMutablePath()
        let steps = 240
        for i in 0...steps {
            let theta = Double(i) / Double(steps) * 2 * .pi
            let r = radius(at: theta)
            let point = CGPoint(x: 0.5 + r * cos(theta), y: 0.5 + r * sin(theta))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// Polar radius of the silhouette at an angle, so decorations can follow
    /// the coin's actual edge instead of assuming a circle. Custom outlines
    /// are treated as roughly round: decorations sit at a safe radius.
    func radius(at theta: Double) -> Double {
        switch silhouette {
        case .seal:    return 0.46 + 0.04 * cos(8 * theta)
        case .octagon: return 0.44 + 0.03 * cos(8 * theta + .pi)
        case .circle:  return 0.48
        case .diamond:
            let c = abs(cos(theta - .pi / 4)), s = abs(sin(theta - .pi / 4))
            return 0.46 / pow(pow(c, 3.2) + pow(s, 3.2), 1 / 3.2)
        case .custom:  return 0.46
        }
    }

    /// Rosette petals behind the art: ring sectors with the gold face
    /// showing through the gaps, so the backdrop is drawn by the metal as
    /// much as by the enamel.
    func petalPath(inner: Double = 0.19, outer: Double = 0.30) -> CGPath {
        let path = CGMutablePath()
        let count = 10
        let gap = 0.22
        for i in 0..<count {
            let start = (Double(i) + gap / 2) / Double(count) * 2 * .pi
            let end = (Double(i) + 1 - gap / 2) / Double(count) * 2 * .pi
            path.move(to: CGPoint(x: 0.5 + inner * cos(start), y: 0.5 + inner * sin(start)))
            path.addArc(center: CGPoint(x: 0.5, y: 0.5), radius: inner,
                        startAngle: start, endAngle: end, clockwise: false)
            path.addLine(to: CGPoint(x: 0.5 + outer * cos(end), y: 0.5 + outer * sin(end)))
            path.addArc(center: CGPoint(x: 0.5, y: 0.5), radius: outer,
                        startAngle: end, endAngle: start, clockwise: true)
            path.closeSubpath()
        }
        return path
    }

    /// The art split into upper and lower enamel cells, so one glyph carries
    /// two colors the way a two-tone pin does. Real path intersection, so
    /// winding rules (cut-out windows) survive the split.
    func artCells(scaledArt: CGPath, splitY: CGFloat) -> (upper: CGPath, lower: CGPath) {
        let box = scaledArt.boundingBoxOfPath
        let seam = box.minY + box.height * splitY
        let top = CGPath(rect: CGRect(x: -1, y: -1, width: 3, height: seam + 1), transform: nil)
        let bottom = CGPath(rect: CGRect(x: -1, y: seam, width: 3, height: 3), transform: nil)
        return (scaledArt.intersection(top, using: .winding),
                scaledArt.intersection(bottom, using: .winding))
    }

    /// The inner disc the art sits on.
    func innerDiscPath(radius r: Double = 0.30) -> CGPath {
        CGPath(ellipseIn: CGRect(x: 0.5 - r, y: 0.5 - r, width: 2 * r, height: 2 * r),
               transform: nil)
    }

    /// A ring of small minted beads tracing the silhouette, just inside the rim.
    func beadPath() -> CGPath {
        let path = CGMutablePath()
        let count = 44
        let bead = 0.011
        for i in 0..<count {
            let theta = Double(i) / Double(count) * 2 * .pi
            let r = radius(at: theta) * 0.90
            let cx = 0.5 + r * cos(theta), cy = 0.5 + r * sin(theta)
            path.addEllipse(in: CGRect(x: cx - bead, y: cy - bead,
                                       width: 2 * bead, height: 2 * bead))
        }
        return path
    }

    /// Short sunburst ticks around the field's edge, clear in the middle.
    func raysPath(inner: Double = 0.225, outer: Double = 0.292) -> CGPath {
        let path = CGMutablePath()
        let count = 28
        for i in 0..<count {
            let mid = Double(i) / Double(count) * 2 * .pi
            let half = .pi / Double(count) * 0.30
            path.move(to: CGPoint(x: 0.5 + inner * cos(mid - half),
                                  y: 0.5 + inner * sin(mid - half)))
            path.addLine(to: CGPoint(x: 0.5 + outer * cos(mid - half),
                                     y: 0.5 + outer * sin(mid - half)))
            path.addLine(to: CGPoint(x: 0.5 + outer * cos(mid + half),
                                     y: 0.5 + outer * sin(mid + half)))
            path.addLine(to: CGPoint(x: 0.5 + inner * cos(mid + half),
                                     y: 0.5 + inner * sin(mid + half)))
            path.closeSubpath()
        }
        return path
    }

    /// A fine grate of crossing bars clipped to the inner disc, so enamel
    /// shows through the cells the way it does on a classic enamel pin.
    func latticePath(radius r: Double = 0.295) -> CGPath {
        let path = CGMutablePath()
        let bar = 0.005
        let spacing = 0.082
        var offset = -r + spacing
        while offset < r - 0.01 {
            let half = (r * r - offset * offset).squareRoot()
            // Vertical bar at x = 0.5 + offset.
            path.addRect(CGRect(x: 0.5 + offset - bar, y: 0.5 - half,
                                width: 2 * bar, height: 2 * half))
            // Horizontal bar at y = 0.5 + offset.
            path.addRect(CGRect(x: 0.5 - half, y: 0.5 + offset - bar,
                                width: 2 * half, height: 2 * bar))
            offset += spacing
        }
        return path
    }

    /// Letters laid along an arc, engraving-style: the top arc reads over the
    /// coin's crown, the bottom arc under its base, both letters-upright.
    func arcTextPath(_ text: String, textRadius: Double, capHeight: Double,
                     onTop: Bool) -> CGPath {
        let font = CTFontCreateWithName("AvenirNext-Bold" as CFString, 10, nil)
        let scale = capHeight / Double(CTFontGetCapHeight(font))

        // Measure per-letter advances so the run centers itself on the arc.
        var letters: [(path: CGPath, advance: Double)] = []
        for char in text.utf16 {
            var ch = char
            var glyph = CGGlyph()
            guard CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1) else { continue }
            var advance = CGSize()
            var g = glyph
            CTFontGetAdvancesForGlyphs(font, .horizontal, &g, &advance, 1)
            let letter = CTFontCreatePathForGlyph(font, glyph, nil)
            letters.append((letter ?? CGMutablePath(), Double(advance.width) * scale))
        }
        guard !letters.isEmpty else { return CGMutablePath() }
        var tracking = capHeight * 0.24
        var total = letters.reduce(0) { $0 + $1.advance + tracking } - tracking
        var sweep = total / textRadius
        // Long texts shrink to fit a fixed arc instead of sweeping into the
        // art's corners; letter paths rescale with the same factor below.
        let maxSweep = 1.9
        var shrink = 1.0
        if sweep > maxSweep {
            shrink = maxSweep / sweep
            tracking *= shrink
            total = letters.reduce(0) { $0 + $1.advance * shrink + tracking } - tracking
            sweep = total / textRadius
        }

        let combined = CGMutablePath()
        // Top text runs clockwise over the crown; bottom text counter-clockwise
        // under the base, so both read left to right with feet toward center.
        var angle = onTop ? (-.pi / 2 - sweep / 2) : (.pi / 2 + sweep / 2)
        for letter in letters {
            let advance = letter.advance * shrink
            let step = (advance + tracking) / textRadius
            let mid = onTop ? angle + step / 2 : angle - step / 2
            let cx = 0.5 + textRadius * cos(mid)
            let cy = 0.5 + textRadius * sin(mid)
            // CoreText glyphs are y-up; our space is y-down, so the flip and
            // the upright rotation happen in one transform per letter.
            let upright = onTop ? mid + .pi / 2 : mid - .pi / 2
            var transform = CGAffineTransform.identity
                .translatedBy(x: cx, y: cy)
                .rotated(by: upright)
                .scaledBy(x: scale * shrink, y: -scale * shrink)
                .translatedBy(x: -letter.advance / scale / 2, y: -Double(CTFontGetCapHeight(font)) / 2)
            if let placed = letter.path.copy(using: &transform) {
                combined.addPath(placed)
            }
            angle = onTop ? angle + step : angle - step
        }
        return combined
    }
}
