import SwiftUI
import UIKit

// MARK: - Silhouette

/// The coin's outline.
public enum CoinSilhouette {
    /// Gentle eight-lobe wax-seal scallop.
    case seal
    /// Soft-cornered octagon.
    case octagon
    case circle
    /// Rounded diamond (a squircle on point).
    case diamond
    /// Any outline, as a CGPath in the normalized 0...1 y-down square.
    /// Paths that are not normalized are refit to the square defensively,
    /// so an SVGPath result can be handed straight in.
    case custom(CGPath)
}

// CGPath payloads are treated as immutable once handed over.
extension CoinSilhouette: @unchecked Sendable {}

// MARK: - Engraving

/// The engraved backdrop behind the center art.
public enum CoinEngraving: String, CaseIterable, Sendable {
    /// Rosette ring sectors in enamel, the gold face showing through the
    /// gaps. The signature cloisonne look, and the default.
    case petals
    /// Radiating sunburst wedges over an enamel field disc, like a
    /// commemorative medal.
    case rays
    /// A fine grate of crossing bars, enamel showing through the cells.
    case lattice
    /// Smooth enamel, letting the art carry the coin.
    case plain
}

// MARK: - Palette

/// The coin's colors. The metal, front face included, is always one gold;
/// color appears only in the enamel cells between the metal, the way a
/// hard-enamel pin works.
public struct CoinPalette {
    /// The enamel behind the art. With the default `.petals` engraving this
    /// colors the rosette petals; with `.rays` or `.lattice` it colors the
    /// field disc the gold pattern sits on.
    public var field: UIColor
    /// The center art's enamel (its upper cells when the art is split).
    public var art: UIColor
    /// The art's lower cells when `artSplit` drops below 1. Nil reuses `art`.
    public var artLower: UIColor?
    /// Where the art's color splits, as a fraction of its height measured
    /// from the top; 1 means the art is one solid color.
    public var artSplit: CGFloat
    /// The metal everywhere else: body, rim, wire, and engraving.
    public var gold: UIColor

    /// A warm rose gold that reads as real metal under the studio lights.
    public static let roseGold = UIColor(red: 1.0, green: 0.80, blue: 0.52, alpha: 1)

    public init(field: UIColor = UIColor(red: 0.16, green: 0.20, blue: 0.58, alpha: 1),
                art: UIColor = UIColor(red: 0.94, green: 0.91, blue: 0.84, alpha: 1),
                artLower: UIColor? = nil,
                artSplit: CGFloat = 1.0,
                gold: UIColor = CoinPalette.roseGold) {
        self.field = field
        self.art = art
        self.artLower = artLower
        self.artSplit = artSplit
        self.gold = gold
    }
}

// UIColor is immutable; the struct is safe to send.
extension CoinPalette: @unchecked Sendable {}

// MARK: - Design

/// Everything needed to mint one coin: the silhouette, the raised art, the
/// enamel colors, the engraving, and the arc lettering. The whole medallion
/// is built from 2D paths at runtime; no 3D model assets are involved.
public struct CoinDesign {
    public var silhouette: CoinSilhouette
    public var palette: CoinPalette
    public var engraving: CoinEngraving
    /// Engraved along the top arc, letters upright, reading left to right.
    public var topText: String
    /// Engraved along the bottom arc, same reading direction.
    public var bottomText: String
    /// The raised center art in normalized 0...1, y-down (SwiftUI space).
    /// The initializers normalize whatever they are given; when assigning
    /// directly, run the path through `SVGPath.normalized` first.
    public var art: CGPath

    /// Mint a coin from any CGPath. The path is refit into the normalized
    /// square on the way in, so any coordinate space works.
    public init(art: CGPath,
                silhouette: CoinSilhouette = .seal,
                palette: CoinPalette = CoinPalette(),
                engraving: CoinEngraving = .petals,
                topText: String = "",
                bottomText: String = "") {
        self.silhouette = silhouette
        self.palette = palette
        self.engraving = engraving
        self.topText = topText
        self.bottomText = bottomText
        self.art = SVGPath.normalized(art)
    }

    /// Mint a coin from a SwiftUI Path, e.g. a Shape's output.
    public init(art path: Path,
                silhouette: CoinSilhouette = .seal,
                palette: CoinPalette = CoinPalette(),
                engraving: CoinEngraving = .petals,
                topText: String = "",
                bottomText: String = "") {
        self.init(art: path.cgPath, silhouette: silhouette, palette: palette,
                  engraving: engraving, topText: topText, bottomText: bottomText)
    }

    /// Mint a coin from the "d" attribute of an SVG path element. Fails when
    /// the data does not parse.
    public init?(svgPathData: String,
                 silhouette: CoinSilhouette = .seal,
                 palette: CoinPalette = CoinPalette(),
                 engraving: CoinEngraving = .petals,
                 topText: String = "",
                 bottomText: String = "") {
        guard let parsed = SVGPath.path(from: svgPathData) else { return nil }
        self.init(art: parsed, silhouette: silhouette, palette: palette,
                  engraving: engraving, topText: topText, bottomText: bottomText)
    }

    /// Mint a coin from a whole SVG document: every path element merges into
    /// one piece of art, placed by the document's viewBox. Fails when no
    /// path element yields usable geometry.
    public init?(svgFileData: Data,
                 silhouette: CoinSilhouette = .seal,
                 palette: CoinPalette = CoinPalette(),
                 engraving: CoinEngraving = .petals,
                 topText: String = "",
                 bottomText: String = "") {
        guard let merged = SVGPath.path(fromSVGFileData: svgFileData) else { return nil }
        self.silhouette = silhouette
        self.palette = palette
        self.engraving = engraving
        self.topText = topText
        self.bottomText = bottomText
        // Already normalized against the viewBox; refitting to tight bounds
        // here would throw away the artist's placement.
        self.art = merged
    }
}

// Paths are treated as immutable once stored; everything else is a value.
extension CoinDesign: @unchecked Sendable {}

// MARK: - Cache key

extension CoinDesign {
    /// A stable fingerprint of everything that affects the coin's look:
    /// the silhouette, every palette color, the engraving, both texts, and
    /// the art path element by element. Same design, same key, across
    /// launches, so snapshots can cache to disk. When the renderer itself
    /// changes look, bump the snapshotter's version instead.
    public var cacheKey: String {
        var hasher = StableHasher()
        switch silhouette {
        case .seal:
            hasher.combine("seal")
        case .octagon:
            hasher.combine("octagon")
        case .circle:
            hasher.combine("circle")
        case .diamond:
            hasher.combine("diamond")
        case .custom(let outline):
            hasher.combine("custom")
            hasher.combine(outline)
        }
        hasher.combine(palette.field)
        hasher.combine(palette.art)
        if let lower = palette.artLower {
            hasher.combine("artLower")
            hasher.combine(lower)
        } else {
            hasher.combine("noArtLower")
        }
        hasher.combine(Double(palette.artSplit))
        hasher.combine(palette.gold)
        hasher.combine(engraving.rawValue)
        hasher.combine(topText)
        hasher.combine(bottomText)
        hasher.combine(art)
        return String(format: "%016llx", hasher.value)
    }
}

/// FNV-1a, 64 bit: tiny, and stable across launches, which Swift's seeded
/// Hasher deliberately is not.
struct StableHasher {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func combine(_ byte: UInt8) {
        value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
    }

    mutating func combine(_ string: String) {
        for byte in string.utf8 { combine(byte) }
        combine(UInt8(0xFF))   // terminator, so "ab"+"c" differs from "a"+"bc"
    }

    mutating func combine(_ number: Double) {
        withUnsafeBytes(of: number.bitPattern.littleEndian) {
            for byte in $0 { combine(byte) }
        }
    }

    mutating func combine(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            combine(Double(r)); combine(Double(g)); combine(Double(b)); combine(Double(a))
        } else {
            // Pattern and catalog colors: fall back to raw components.
            for component in color.cgColor.components ?? [] { combine(Double(component)) }
        }
    }

    mutating func combine(_ path: CGPath) {
        // applyWithBlock's closure is marked escaping, so mutate a local
        // copy it can capture and fold the result back in afterward.
        var folded = self
        path.applyWithBlock { element in
            let e = element.pointee
            folded.combine(UInt8(truncatingIfNeeded: e.type.rawValue))
            let pointCount: Int
            switch e.type {
            case .moveToPoint, .addLineToPoint: pointCount = 1
            case .addQuadCurveToPoint: pointCount = 2
            case .addCurveToPoint: pointCount = 3
            default: pointCount = 0
            }
            for i in 0..<pointCount {
                folded.combine(Double(e.points[i].x))
                folded.combine(Double(e.points[i].y))
            }
        }
        self = folded
    }
}
