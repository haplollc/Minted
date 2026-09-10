import UIKit
import Accelerate

/// Turns a finished pin image into the outline, rim bands, and texture maps a
/// coin needs. Every step here exists because a simpler version of it failed
/// on real artwork, and the comments say which failure.
enum ArtworkAnalyzer {

    /// Set when analysis bails, so callers can say why.
    nonisolated(unsafe) static var stage = ""

    struct Analysis {
        let silhouette: CGPath
        let rimBands: [CGPath]
        let face: UIImage
        let metalness: UIImage
        let relief: UIImage
        let contentBox: CGRect
    }

    /// Working resolution for the baked textures.
    private static let textureSize = 512

    static func analyze(image: UIImage, rimWidth: CGFloat?) -> Analysis? {
        guard let source = image.cgImage else { stage = "cgImage"; return nil }
        let width = source.width, height = source.height
        guard var pixels = rgba(from: source) else { stage = "rgba"; return nil }

        var mask = pinMask(pixels: &pixels, width: width, height: height)
        guard let bounds = maskBounds(mask, width: width, height: height) else {
            stage = "maskBounds(pin px \(count(mask)))"; return nil
        }

        // Square crop centred on the pin, so the face image and the outline
        // share one frame of reference.
        let span = max(bounds.width, bounds.height)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let crop = CGRect(x: centre.x - span / 2, y: centre.y - span / 2,
                          width: span, height: span)

        // Smooth the outline just enough that SceneKit will extrude it. Thin
        // spires break tessellation outright, and a shape that fails to
        // tessellate renders as nothing at all.
        var outlineMask = mask
        for radius in [span * 0.015, span * 0.010, span * 0.007, span * 0.004] {
            let candidate = opened(mask, width: width, height: height, radius: Int(radius))
            let kept = count(candidate)
            guard kept > count(mask) / 2 else { continue }
            outlineMask = candidate
            if Double(count(mask) - kept) / Double(count(mask)) < 0.03 { break }
        }

        guard let ring = contour(outlineMask, width: width, height: height,
                                 crop: crop, span: span) else {
            stage = "contour(outline px \(count(outlineMask)))"; return nil
        }

        let faceImage = croppedTexture(source: source, crop: crop, mask: mask,
                                       width: width, height: height)
        guard let faceCG = faceImage.cgImage, var facePixels = rgba(from: faceCG) else {
            stage = "facePixels"; return nil
        }
        let goldMask = goldMask(pixels: &facePixels, side: textureSize)

        let band = rimWidth ?? measuredRimWidth(ring: ring, gold: &facePixels, side: textureSize)
        let inner = offsetInward(ring, by: band)

        let contentBox = boundingBox(of: ring)
        return Analysis(
            silhouette: path(from: ring),
            rimBands: [path(from: inner)],
            face: faceImage,
            metalness: grayImage(goldMask, side: textureSize),
            relief: normalMap(goldMask, side: textureSize),
            contentBox: contentBox)
    }

    // MARK: Masking

    /// The pin itself: real colour or dark ink, never the soft drop shadow.
    ///
    /// Flooding the paper inward from the border seems obvious and is wrong:
    /// a pin's shadow is a desaturated halo that the flood happily eats, so
    /// pins gain a ragged aura and swallow any caption beneath them. Keying
    /// on content ignores shadows, which are neither saturated nor dark.
    private static func pinMask(pixels: inout [UInt8], width: Int, height: Int) -> [Bool] {
        var mask = [Bool](repeating: false, count: width * height)
        for index in 0..<(width * height) {
            let r = Int(pixels[index * 4]), g = Int(pixels[index * 4 + 1]), b = Int(pixels[index * 4 + 2])
            let maxC = max(r, max(g, b)), minC = min(r, min(g, b))
            mask[index] = (maxC - minC > 55) || (maxC < 140)
        }
        mask = closed(mask, width: width, height: height, radius: 8)
        mask = fillHoles(mask, width: width, height: height)
        mask = largestComponent(mask, width: width, height: height)
        return eroded(mask, width: width, height: height, radius: 4)
    }

    /// Gold in the artwork: warm, and either glossy or blown out. Used for
    /// metalness and for the relief that makes painted trim stand proud.
    private static func goldMask(pixels: inout [UInt8], side: Int) -> [Bool] {
        var mask = [Bool](repeating: false, count: side * side)
        var luminance = [Float](repeating: 0, count: side * side)
        for index in 0..<(side * side) {
            let r = Float(pixels[index * 4]), g = Float(pixels[index * 4 + 1])
            let b = Float(pixels[index * 4 + 2])
            luminance[index] = 0.299 * r + 0.587 * g + 0.114 * b
            mask[index] = r > b + 28 && g > b * 0.82 && g > r * 0.52 && r > 120
        }
        let blurred = boxBlur(luminance, side: side, radius: 4)
        for index in 0..<(side * side) {
            let local = abs(luminance[index] - blurred[index])
            mask[index] = mask[index] && (local > 9 || luminance[index] > 225)
        }
        return closed(mask, width: side, height: side, radius: 2)
    }

    /// How far the artwork's own painted frame runs inward from the outline.
    ///
    /// One fixed rim width covers the frame on chunky pins but eats buildings
    /// and trees at the edge of narrow ones, which reads as cropped art.
    private static func measuredRimWidth(ring: [CGPoint], gold: inout [UInt8], side: Int) -> CGFloat {
        var frameInk = [Bool](repeating: false, count: side * side)
        for index in 0..<(side * side) {
            let r = Float(gold[index * 4]), g = Float(gold[index * 4 + 1])
            let b = Float(gold[index * 4 + 2])
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            frameInk[index] = r > b + 12 && lum > 130
        }
        let inside = rasterize(ring, side: side)
        let depth = distanceInside(inside, side: side)
        var frame = 0
        for step in 1...25 {
            var total = 0, warm = 0
            for index in 0..<(side * side) where inside[index] {
                let d = depth[index]
                if d > Float(step - 1) && d <= Float(step) {
                    total += 1
                    if frameInk[index] { warm += 1 }
                }
            }
            if total < 60 { break }
            if Double(warm) / Double(total) > 0.60 {
                frame = step
            } else if step > 3 {
                break
            }
        }
        return min(0.030, max(0.018, CGFloat(frame) / CGFloat(side) * 1.15))
    }
}

// MARK: - Pixels

private extension ArtworkAnalyzer {

    static func rgba(from image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &buffer, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    static func count(_ mask: [Bool]) -> Int {
        mask.reduce(0) { $0 + ($1 ? 1 : 0) }
    }

    static func maskBounds(_ mask: [Bool], width: Int, height: Int) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Morphology

    static func dilated(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        guard radius > 0 else { return mask }
        var out = mask
        for _ in 0..<radius {
            var next = out
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x
                    if out[index] { continue }
                    if (x > 0 && out[index - 1]) || (x < width - 1 && out[index + 1])
                        || (y > 0 && out[index - width]) || (y < height - 1 && out[index + width]) {
                        next[index] = true
                    }
                }
            }
            out = next
        }
        return out
    }

    static func eroded(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        guard radius > 0 else { return mask }
        var out = mask
        for _ in 0..<radius {
            var next = out
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x
                    guard out[index] else { continue }
                    if x == 0 || x == width - 1 || y == 0 || y == height - 1
                        || !out[index - 1] || !out[index + 1]
                        || !out[index - width] || !out[index + width] {
                        next[index] = false
                    }
                }
            }
            out = next
        }
        return out
    }

    static func closed(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        eroded(dilated(mask, width: width, height: height, radius: radius),
               width: width, height: height, radius: radius)
    }

    static func opened(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        dilated(eroded(mask, width: width, height: height, radius: radius),
                width: width, height: height, radius: radius)
    }

    /// Flood the complement from the border; whatever it cannot reach is a
    /// hole, and holes belong to the pin.
    static func fillHoles(_ mask: [Bool], width: Int, height: Int) -> [Bool] {
        var outside = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        for x in 0..<width {
            for y in [0, height - 1] {
                let index = y * width + x
                if !mask[index] && !outside[index] { outside[index] = true; stack.append(index) }
            }
        }
        for y in 0..<height {
            for x in [0, width - 1] {
                let index = y * width + x
                if !mask[index] && !outside[index] { outside[index] = true; stack.append(index) }
            }
        }
        while let index = stack.popLast() {
            let x = index % width, y = index / width
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                let neighbour = ny * width + nx
                if !mask[neighbour] && !outside[neighbour] {
                    outside[neighbour] = true
                    stack.append(neighbour)
                }
            }
        }
        return (0..<(width * height)).map { mask[$0] || !outside[$0] }
    }

    /// Caption text and stray marks are their own blobs; keep the pin only.
    static func largestComponent(_ mask: [Bool], width: Int, height: Int) -> [Bool] {
        var labels = [Int](repeating: 0, count: width * height)
        var best: [Int] = [], bestSize = 0, label = 0
        for start in 0..<(width * height) where mask[start] && labels[start] == 0 {
            label += 1
            var stack = [start], component: [Int] = []
            labels[start] = label
            while let index = stack.popLast() {
                component.append(index)
                let x = index % width, y = index / width
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let neighbour = ny * width + nx
                    if mask[neighbour] && labels[neighbour] == 0 {
                        labels[neighbour] = label
                        stack.append(neighbour)
                    }
                }
            }
            if component.count > bestSize { bestSize = component.count; best = component }
        }
        var out = [Bool](repeating: false, count: width * height)
        for index in best { out[index] = true }
        return out
    }

    // MARK: Contours

    /// Trace the mask's outer boundary and simplify it into the normalized
    /// crop frame. Moore-neighbour tracing: from each boundary pixel, sweep
    /// its neighbours clockwise starting from where we arrived, so concave
    /// notches like a scalloped pin top survive intact.
    static func contour(_ mask: [Bool], width: Int, height: Int,
                        crop: CGRect, span: CGFloat) -> [CGPoint]? {
        func filled(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < width && y >= 0 && y < height && mask[y * width + x]
        }
        var start: (Int, Int)? = nil
        outer: for y in 0..<height {
            for x in 0..<width where mask[y * width + x] { start = (x, y); break outer }
        }
        guard let origin = start else { return nil }

        // Clockwise from west.
        let ring: [(Int, Int)] = [(-1, 0), (-1, -1), (0, -1), (1, -1),
                                  (1, 0), (1, 1), (0, 1), (-1, 1)]
        func index(of neighbour: (Int, Int), around centre: (Int, Int)) -> Int {
            let dx = neighbour.0 - centre.0, dy = neighbour.1 - centre.1
            return ring.firstIndex { $0 == (dx, dy) } ?? 0
        }

        var trace: [(Int, Int)] = [origin]
        var current = origin
        var backtrack = (origin.0 - 1, origin.1)   // west of the start is empty
        let limit = width * height * 4
        while trace.count < limit {
            let from = index(of: backtrack, around: current)
            var moved = false
            for step in 1...8 {
                let slot = (from + step) % 8
                let candidate = (current.0 + ring[slot].0, current.1 + ring[slot].1)
                if filled(candidate.0, candidate.1) {
                    let previous = (from + step - 1) % 8
                    backtrack = (current.0 + ring[previous].0, current.1 + ring[previous].1)
                    current = candidate
                    trace.append(current)
                    moved = true
                    break
                }
            }
            if !moved { break }
            if current == origin && trace.count > 3 { break }
        }
        guard trace.count > 8 else { return nil }

        let points = trace.map { point in
            CGPoint(x: (CGFloat(point.0) - crop.minX) / span,
                    y: (CGFloat(point.1) - crop.minY) / span)
        }
        var simplified = simplify(points, tolerance: 1.4 / span)
        // Keep outlines light enough for SceneKit to extrude reliably.
        var tolerance = 1.4 / span
        while simplified.count > 130, tolerance < 40 / span {
            tolerance *= 1.4
            simplified = simplify(points, tolerance: tolerance)
        }
        return simplified.count >= 6 ? simplified : nil
    }

    /// Douglas-Peucker over a closed ring, anchored at two far-apart points
    /// so the start-equals-end chord cannot collapse the whole outline.
    static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 6 else { return points }
        var ring = points
        if ring.first == ring.last { ring.removeLast() }
        let anchor = ring.indices.max {
            hypot(ring[$0].x - ring[0].x, ring[$0].y - ring[0].y)
                < hypot(ring[$1].x - ring[0].x, ring[$1].y - ring[0].y)
        } ?? ring.count - 1
        let head = openSimplify(Array(ring[0...anchor]), tolerance: tolerance)
        let tail = openSimplify(Array(ring[anchor...]) + [ring[0]], tolerance: tolerance)
        return Array(head.dropLast()) + Array(tail.dropLast())
    }

    static func openSimplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true; keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (from, to) = stack.popLast() {
            guard to > from + 1 else { continue }
            let a = points[from], b = points[to]
            let dx = b.x - a.x, dy = b.y - a.y
            let length = max(hypot(dx, dy), 1e-9)
            var worst = from, worstDistance: CGFloat = 0
            for index in (from + 1)..<to {
                let p = points[index]
                let distance = abs(dx * (a.y - p.y) - dy * (a.x - p.x)) / length
                if distance > worstDistance { worstDistance = distance; worst = index }
            }
            if worstDistance > tolerance {
                keep[worst] = true
                stack.append((from, worst)); stack.append((worst, to))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    // MARK: Geometry

    static func path(from ring: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.move(to: ring[0])
        for point in ring.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    static func boundingBox(of ring: [CGPoint]) -> CGRect {
        let xs = ring.map(\.x), ys = ring.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!,
                      width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    static func area(_ ring: [CGPoint]) -> CGFloat {
        var total: CGFloat = 0
        for index in ring.indices {
            let a = ring[index], b = ring[(index + 1) % ring.count]
            total += a.x * b.y - b.x * a.y
        }
        return abs(total) / 2
    }

    /// Offset a ring inward along vertex bisectors.
    ///
    /// Eroding the mask and tracing it again gives a second ring that
    /// wanders relative to the first, pinching the rim to nothing on smooth
    /// curves. Offsetting the same polygon keeps the band concentric.
    static func offsetInward(_ ring: [CGPoint], by distance: CGFloat) -> [CGPoint] {
        func offset(_ sign: CGFloat) -> [CGPoint] {
            ring.indices.map { index in
                let previous = ring[(index - 1 + ring.count) % ring.count]
                let current = ring[index]
                let next = ring[(index + 1) % ring.count]
                func unit(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
                    let dx = b.x - a.x, dy = b.y - a.y
                    let length = max(hypot(dx, dy), 1e-9)
                    return CGPoint(x: dx / length, y: dy / length)
                }
                let e1 = unit(previous, current), e2 = unit(current, next)
                let n1 = CGPoint(x: e1.y * sign, y: -e1.x * sign)
                let n2 = CGPoint(x: e2.y * sign, y: -e2.x * sign)
                var bx = n1.x + n2.x, by = n1.y + n2.y
                var length = hypot(bx, by)
                if length < 1e-6 { bx = n1.x; by = n1.y; length = 1 }
                let miter = min(2.5, 1.0 / max(0.4, length / 2))
                return CGPoint(x: current.x + bx / length * distance * miter,
                               y: current.y + by / length * distance * miter)
            }
        }
        // Y-down flips the usual winding test, so try both and keep whichever
        // actually shrinks the shape.
        let a = offset(1), b = offset(-1)
        return area(a) < area(b) ? a : b
    }

    static func rasterize(_ ring: [CGPoint], side: Int) -> [Bool] {
        var buffer = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(data: &buffer, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return [Bool](repeating: false, count: side * side) }
        context.setFillColor(gray: 1, alpha: 1)
        let scaled = CGMutablePath()
        scaled.addPath(path(from: ring),
                       transform: CGAffineTransform(scaleX: CGFloat(side), y: CGFloat(side)))
        context.addPath(scaled)
        context.fillPath()
        return buffer.map { $0 > 127 }
    }

    /// Chamfer distance from the mask's edge, inward.
    static func distanceInside(_ mask: [Bool], side: Int) -> [Float] {
        let large: Float = 1e6
        var distance = mask.map { $0 ? large : 0 }
        for y in 0..<side {
            for x in 0..<side {
                let index = y * side + x
                guard mask[index] else { continue }
                var best = distance[index]
                if x > 0 { best = min(best, distance[index - 1] + 1) }
                if y > 0 { best = min(best, distance[index - side] + 1) }
                distance[index] = best
            }
        }
        for y in stride(from: side - 1, through: 0, by: -1) {
            for x in stride(from: side - 1, through: 0, by: -1) {
                let index = y * side + x
                guard mask[index] else { continue }
                var best = distance[index]
                if x < side - 1 { best = min(best, distance[index + 1] + 1) }
                if y < side - 1 { best = min(best, distance[index + side] + 1) }
                distance[index] = best
            }
        }
        return distance
    }

    static func boxBlur(_ values: [Float], side: Int, radius: Int) -> [Float] {
        var out = values
        var temporary = values
        for y in 0..<side {
            for x in 0..<side {
                var total: Float = 0, samples: Float = 0
                for offset in -radius...radius {
                    let sx = x + offset
                    guard sx >= 0, sx < side else { continue }
                    total += values[y * side + sx]; samples += 1
                }
                temporary[y * side + x] = total / max(samples, 1)
            }
        }
        for y in 0..<side {
            for x in 0..<side {
                var total: Float = 0, samples: Float = 0
                for offset in -radius...radius {
                    let sy = y + offset
                    guard sy >= 0, sy < side else { continue }
                    total += temporary[sy * side + x]; samples += 1
                }
                out[y * side + x] = total / max(samples, 1)
            }
        }
        return out
    }

    // MARK: Textures

    /// The artwork, cropped square to the pin. Anything outside the pin is
    /// replaced by its rim colour: those pixels sit outside the silhouette so
    /// they never render, but clearing them stops texture filtering from
    /// dragging a caption or a neighbour's edge across the coin's rim.
    static func croppedTexture(source: CGImage, crop: CGRect, mask: [Bool],
                               width: Int, height: Int) -> UIImage {
        let side = textureSize
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            let scale = CGFloat(side) / crop.width
            ctx.cgContext.translateBy(x: 0, y: CGFloat(side))
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            ctx.cgContext.translateBy(x: -crop.minX, y: -crop.minY)
            ctx.cgContext.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let cg = drawn.cgImage, var pixels = rgba(from: cg) else { return drawn }

        // Sample the mask into the crop's frame so it lines up with what was
        // just drawn.
        var inside = [Bool](repeating: false, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let sx = Int(crop.minX + CGFloat(x) * crop.width / CGFloat(side))
                let sy = Int(crop.minY + CGFloat(y) * crop.height / CGFloat(side))
                guard sx >= 0, sx < width, sy >= 0, sy < height else { continue }
                inside[y * side + x] = mask[sy * width + sx]
            }
        }
        guard inside.contains(true), inside.contains(false) else { return drawn }

        // Everything outside the pin (a caption, a neighbouring pin's edge,
        // the drop shadow) is replaced by the pin's own rim colour. Those
        // pixels sit outside the silhouette so they never render, but
        // clearing them stops texture filtering from dragging a fringe
        // across the coin's edge.
        let core = eroded(inside, width: side, height: side, radius: 3)
        var edgeR = 0, edgeG = 0, edgeB = 0, edgeCount = 0
        for index in 0..<(side * side) where inside[index] && !core[index] {
            edgeR += Int(pixels[index * 4])
            edgeG += Int(pixels[index * 4 + 1])
            edgeB += Int(pixels[index * 4 + 2])
            edgeCount += 1
        }
        let fill: (UInt8, UInt8, UInt8) = edgeCount > 0
            ? (UInt8(edgeR / edgeCount), UInt8(edgeG / edgeCount), UInt8(edgeB / edgeCount))
            : (230, 226, 216)

        // Bleed the artwork a few pixels past the outline first, so sampling
        // right at the rim still lands on real art rather than flat fill.
        let bleed = dilated(inside, width: side, height: side, radius: 6)
        var source = pixels
        for _ in 0..<6 {
            var next = source
            for y in 0..<side {
                for x in 0..<side {
                    let index = y * side + x
                    guard bleed[index], !inside[index], next[index * 4 + 3] == 0 else { continue }
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < side, ny >= 0, ny < side else { continue }
                        let neighbour = ny * side + nx
                        if inside[neighbour] || next[neighbour * 4 + 3] != 0 {
                            for channel in 0..<4 {
                                next[index * 4 + channel] = source[neighbour * 4 + channel]
                            }
                            break
                        }
                    }
                }
            }
            source = next
        }
        for index in 0..<(side * side) where !inside[index] && !bleed[index] {
            pixels[index * 4] = fill.0
            pixels[index * 4 + 1] = fill.1
            pixels[index * 4 + 2] = fill.2
            pixels[index * 4 + 3] = 255
        }
        for index in 0..<(side * side) where !inside[index] && bleed[index] {
            for channel in 0..<4 { pixels[index * 4 + channel] = source[index * 4 + channel] }
        }

        let context = CGContext(data: &pixels, width: side, height: side,
                                bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cleaned = context?.makeImage() else { return drawn }
        return UIImage(cgImage: cleaned)
    }

    static func grayImage(_ mask: [Bool], side: Int) -> UIImage {
        var buffer = mask.map { $0 ? UInt8(255) : UInt8(0) }
        let context = CGContext(data: &buffer, width: side, height: side,
                                bitsPerComponent: 8, bytesPerRow: side,
                                space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        guard let image = context?.makeImage() else { return UIImage() }
        return UIImage(cgImage: image)
    }

    /// Treat the gold as a height field and bake its slopes into a normal
    /// map, so painted frames and wires catch light like metal standing
    /// proud of the enamel instead of reading as a flat print.
    static func normalMap(_ mask: [Bool], side: Int) -> UIImage {
        let height = boxBlur(mask.map { $0 ? Float(1) : 0 }, side: side, radius: 2)
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        let strength: Float = 2.4
        for y in 0..<side {
            for x in 0..<side {
                let index = y * side + x
                let left = height[y * side + max(x - 1, 0)]
                let right = height[y * side + min(x + 1, side - 1)]
                let up = height[max(y - 1, 0) * side + x]
                let down = height[min(y + 1, side - 1) * side + x]
                var nx = -(right - left) / 2 * strength
                var ny = -(down - up) / 2 * strength
                var nz: Float = 1
                let length = max(sqrt(nx * nx + ny * ny + nz * nz), 1e-6)
                nx /= length; ny /= length; nz /= length
                buffer[index * 4] = UInt8((nx * 0.5 + 0.5) * 255)
                buffer[index * 4 + 1] = UInt8((ny * 0.5 + 0.5) * 255)
                buffer[index * 4 + 2] = UInt8((nz * 0.5 + 0.5) * 255)
                buffer[index * 4 + 3] = 255
            }
        }
        let context = CGContext(data: &buffer, width: side, height: side,
                                bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let image = context?.makeImage() else { return UIImage() }
        return UIImage(cgImage: image)
    }
}
