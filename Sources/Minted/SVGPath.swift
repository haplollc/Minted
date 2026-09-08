import CoreGraphics
import Foundation

/// A parser for the SVG path "d" mini-language, plus the normalization
/// helpers the rest of the package builds on. The parser implements the
/// SVG 1.1 grammar itself: implicit command repetition, numbers packed
/// against signs and exponents, packed arc flags, and the spec's arc
/// parameterization. It is structure based, not tuned to any one file, so
/// it accepts output from Illustrator, Figma, and hand-writing alike.
public enum SVGPath {

    // MARK: Parsing

    /// Parses one "d" attribute into a CGPath in the data's own units,
    /// y-down exactly as SVG defines it. Malformed data returns nil rather
    /// than a best-effort partial path, so callers can trust what they get.
    public static func path(from data: String) -> CGPath? {
        var scanner = PathScanner(data)
        let path = CGMutablePath()

        var command: Character?
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        // Reflection anchors for the shorthand curves. Each survives only
        // while consecutive commands stay in its curve family, which is
        // exactly the spec's rule for when S and T may reflect.
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?

        while true {
            scanner.skipSeparators()
            if scanner.isAtEnd { break }

            if let letter = scanner.nextCommandLetter() {
                command = letter
            } else {
                // A number where a letter should be: the previous command
                // repeats implicitly. A repeated moveto continues as lineto,
                // and nothing but a letter may follow a closepath.
                switch command {
                case "M": command = "L"
                case "m": command = "l"
                case "Z", "z", nil: return nil
                default: break
                }
            }
            guard let cmd = command else { return nil }
            // Every path must open with a moveto.
            if path.isEmpty, cmd != "M", cmd != "m" { return nil }

            let relative = cmd.isLowercase
            let origin = relative ? current : .zero
            func place(_ p: CGPoint) -> CGPoint {
                CGPoint(x: origin.x + p.x, y: origin.y + p.y)
            }

            switch Character(cmd.uppercased()) {
            case "M":
                guard let p = scanner.nextPoint() else { return nil }
                current = place(p)
                subpathStart = current
                path.move(to: current)
                lastCubicControl = nil; lastQuadControl = nil

            case "L":
                guard let p = scanner.nextPoint() else { return nil }
                current = place(p)
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil

            case "H":
                guard let x = scanner.nextNumber() else { return nil }
                current.x = relative ? current.x + x : x
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil

            case "V":
                guard let y = scanner.nextNumber() else { return nil }
                current.y = relative ? current.y + y : y
                path.addLine(to: current)
                lastCubicControl = nil; lastQuadControl = nil

            case "C":
                guard let a = scanner.nextPoint(), let b = scanner.nextPoint(),
                      let e = scanner.nextPoint() else { return nil }
                let c1 = place(a), c2 = place(b), end = place(e)
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end
                lastCubicControl = c2; lastQuadControl = nil

            case "S":
                guard let b = scanner.nextPoint(), let e = scanner.nextPoint() else { return nil }
                let c1 = lastCubicControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                let c2 = place(b), end = place(e)
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end
                lastCubicControl = c2; lastQuadControl = nil

            case "Q":
                guard let a = scanner.nextPoint(), let e = scanner.nextPoint() else { return nil }
                let control = place(a), end = place(e)
                path.addQuadCurve(to: end, control: control)
                current = end
                lastQuadControl = control; lastCubicControl = nil

            case "T":
                guard let e = scanner.nextPoint() else { return nil }
                let control = lastQuadControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                let end = place(e)
                path.addQuadCurve(to: end, control: control)
                current = end
                lastQuadControl = control; lastCubicControl = nil

            case "A":
                guard let rx = scanner.nextNumber(), let ry = scanner.nextNumber(),
                      let rotation = scanner.nextNumber(),
                      let largeArc = scanner.nextFlag(), let sweep = scanner.nextFlag(),
                      let e = scanner.nextPoint() else { return nil }
                let end = place(e)
                appendArc(to: path, from: current, to: end, rx: rx, ry: ry,
                          rotationDegrees: rotation, largeArc: largeArc, sweep: sweep)
                current = end
                lastCubicControl = nil; lastQuadControl = nil

            case "Z":
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil; lastQuadControl = nil

            default:
                return nil
            }
        }
        return path.isEmpty ? nil : path
    }

    /// Extracts every path element from an SVG document, merges them into
    /// one CGPath, and normalizes into the 0...1 y-down square: via the
    /// viewBox when the document declares one (preserving where the artist
    /// placed the art in its frame), by tight bounds otherwise.
    public static func path(fromSVGFileData data: Data) -> CGPath? {
        let extractor = SVGDocumentExtractor()
        let parser = XMLParser(data: data)
        parser.delegate = extractor
        parser.parse()

        let merged = CGMutablePath()
        for d in extractor.pathData {
            // One malformed path should not sink a document's worth of art.
            if let piece = path(from: d) { merged.addPath(piece) }
        }
        guard !merged.isEmpty else { return nil }

        if let viewBox = extractor.viewBox, viewBox.width > 0, viewBox.height > 0,
           let fitted = fitting(merged, frame: viewBox) {
            return fitted
        }
        return normalized(merged)
    }

    // MARK: Normalization

    /// Refits any path into the normalized 0...1 y-down square, centered,
    /// preserving aspect ratio: the longest side of the bounding box spans
    /// exactly 1. Degenerate paths come back unchanged.
    public static func normalized(_ path: CGPath) -> CGPath {
        let box = path.boundingBoxOfPath
        guard !box.isNull, box.width > 0 || box.height > 0 else { return path }
        return fitting(path, frame: box) ?? path
    }

    /// Maps `frame` onto the unit square (longest side spanning 1, centered)
    /// and carries the path along for the ride.
    private static func fitting(_ path: CGPath, frame: CGRect) -> CGPath? {
        let scale = 1 / max(frame.width, frame.height)
        var transform = CGAffineTransform.identity
            .translatedBy(x: 0.5, y: 0.5)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -frame.midX, y: -frame.midY)
        return path.copy(using: &transform)
    }

    // MARK: Arc conversion

    /// Converts one elliptical arc segment to cubic Beziers using the SVG
    /// spec's endpoint-to-center parameterization (SVG 1.1 appendix F.6),
    /// including the out-of-range fixups for zero and undersized radii.
    private static func appendArc(to path: CGMutablePath, from start: CGPoint, to end: CGPoint,
                                  rx: Double, ry: Double, rotationDegrees: Double,
                                  largeArc: Bool, sweep: Bool) {
        // F.6.2: zero radii degrade to a straight line; coincident endpoints
        // draw nothing at all.
        var rx = abs(rx), ry = abs(ry)
        if rx < .ulpOfOne || ry < .ulpOfOne {
            if start != end { path.addLine(to: end) }
            return
        }
        if start == end { return }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        // F.6.5.1: the midpoint form, in the ellipse's own axes.
        let dx = Double(start.x - end.x) / 2, dy = Double(start.y - end.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        // F.6.6.2: radii too small to span the endpoints scale up to fit.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let grow = lambda.squareRoot()
            rx *= grow; ry *= grow
        }

        // F.6.5.2: the center, still in the ellipse's axes.
        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var factor = denominator == 0 ? 0 : (numerator / denominator).squareRoot()
        if largeArc == sweep { factor = -factor }
        let cxp = factor * rx * y1p / ry
        let cyp = -factor * ry * x1p / rx

        // F.6.5.3: back to user space.
        let cx = cosPhi * cxp - sinPhi * cyp + Double(start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + Double(start.y + end.y) / 2

        // F.6.5.4 through F.6.5.6: start angle and signed sweep extent.
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let lengths = ((ux * ux + uy * uy) * (vx * vx + vy * vy)).squareRoot()
            guard lengths > 0 else { return 0 }
            var a = acos(min(1, max(-1, dot / lengths)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
        let theta1 = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy).truncatingRemainder(dividingBy: 2 * .pi)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        // Split into quarter-turn-or-less pieces; each is one cubic with the
        // standard tangent-length approximation.
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / Double(segments)
        let alpha = 4.0 / 3.0 * tan(step / 4)

        func point(at t: Double) -> CGPoint {
            CGPoint(x: cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi,
                    y: cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
        }
        func derivative(at t: Double) -> CGPoint {
            CGPoint(x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi,
                    y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
        }

        var t = theta1
        var from = start
        for segment in 0..<segments {
            let t2 = t + step
            // The last piece lands exactly on the endpoint the data named,
            // so subpaths stay watertight.
            let to = segment == segments - 1 ? end : point(at: t2)
            let d1 = derivative(at: t), d2 = derivative(at: t2)
            path.addCurve(to: to,
                          control1: CGPoint(x: from.x + alpha * d1.x, y: from.y + alpha * d1.y),
                          control2: CGPoint(x: to.x - alpha * d2.x, y: to.y - alpha * d2.y))
            t = t2
            from = to
        }
    }
}

// MARK: - Document extraction

/// Pulls "d" attributes and the viewBox out of an SVG document. Element
/// names match by local part, so namespace prefixes do not matter.
private final class SVGDocumentExtractor: NSObject, XMLParserDelegate {
    var pathData: [String] = []
    var viewBox: CGRect?

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch local.lowercased() {
        case "svg":
            guard viewBox == nil,
                  let raw = attributes["viewBox"] ?? attributes["viewbox"] else { break }
            let parts = raw.split(whereSeparator: { " ,\t\n\r".contains($0) })
                .compactMap { Double($0) }
            if parts.count == 4 {
                viewBox = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
            }
        case "path":
            if let d = attributes["d"] { pathData.append(d) }
        default:
            break
        }
    }
}

// MARK: - Lexing

/// A hand-rolled lexer for path data. Everything meaningful in the grammar
/// is ASCII, so it walks UTF-8 bytes directly.
private struct PathScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(_ string: String) {
        bytes = Array(string.utf8)
    }

    var isAtEnd: Bool { index >= bytes.count }

    /// Whitespace and commas separate tokens and carry no meaning.
    mutating func skipSeparators() {
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: " "), UInt8(ascii: "\t"),
                 UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: ","):
                index += 1
            default:
                return
            }
        }
    }

    /// Consumes one command letter, if a valid one is next.
    mutating func nextCommandLetter() -> Character? {
        guard index < bytes.count, bytes[index] < 128 else { return nil }
        let letter = Character(UnicodeScalar(bytes[index]))
        guard "MmLlHhVvCcSsQqTtAaZz".contains(letter) else { return nil }
        index += 1
        return letter
    }

    /// Lexes one number: sign, mantissa, optional exponent. A second decimal
    /// point ends the number, so ".5.5" is two numbers, and so does a sign,
    /// so "1.5e-2-3" is 1.5e-2 followed by -3.
    mutating func nextNumber() -> Double? {
        skipSeparators()
        let start = index
        var i = index

        func digits(from position: inout Int) -> Bool {
            let first = position
            while position < bytes.count,
                  bytes[position] >= UInt8(ascii: "0"), bytes[position] <= UInt8(ascii: "9") {
                position += 1
            }
            return position > first
        }

        if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") {
            i += 1
        }
        let hasIntegerPart = digits(from: &i)
        var hasFractionPart = false
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            hasFractionPart = digits(from: &i)
        }
        guard hasIntegerPart || hasFractionPart else {
            index = start
            return nil
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            var j = i + 1
            if j < bytes.count, bytes[j] == UInt8(ascii: "+") || bytes[j] == UInt8(ascii: "-") {
                j += 1
            }
            // An "e" with no digits after it is not an exponent; leave it be.
            if digits(from: &j) { i = j }
        }
        guard let value = Double(String(decoding: bytes[index..<i], as: UTF8.self)) else {
            index = start
            return nil
        }
        index = i
        return value
    }

    /// Arc flags are single 0/1 characters and may be packed hard against
    /// the next number ("0110 10" is two flags then a point), so they get
    /// their own lexer instead of going through nextNumber.
    mutating func nextFlag() -> Bool? {
        skipSeparators()
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "0"): index += 1; return false
        case UInt8(ascii: "1"): index += 1; return true
        default: return nil
        }
    }

    mutating func nextPoint() -> CGPoint? {
        guard let x = nextNumber(), let y = nextNumber() else { return nil }
        return CGPoint(x: x, y: y)
    }
}
