import SwiftUI

/// The flat, quiet version of a coin: the same silhouette and art as the
/// minted medallion, drawn as pale line work. Good for locked, pending, and
/// placeholder states; `CoinThumbnailView` uses it while renders load.
public struct CoinLineArt: View {
    private let design: CoinDesign
    private let size: CGFloat
    private let lineColor: Color

    public init(design: CoinDesign, size: CGFloat = 150, lineColor: Color = .secondary) {
        self.design = design
        self.size = size
        self.lineColor = lineColor
    }

    public var body: some View {
        ZStack {
            NormalizedPathShape(path: design.silhouettePath())
                .stroke(lineColor, lineWidth: max(1.4, size * 0.012))
            NormalizedPathShape(path: design.silhouettePath())
                .scale(0.88)
                .stroke(lineColor.opacity(0.6), lineWidth: max(1, size * 0.008))
            NormalizedPathShape(path: design.art, fitted: 0.54)
                .stroke(lineColor, lineWidth: max(1.2, size * 0.010))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Renders a normalized 0...1 CGPath into any rect, optionally refit around
/// the center at a fraction of the frame (for centering glyph art).
/// Unchecked because Shape demands Sendable and the stored CGPath, treated
/// as immutable, is not annotated.
public struct NormalizedPathShape: Shape, @unchecked Sendable {
    public var path: CGPath
    public var fitted: CGFloat?

    public init(path: CGPath, fitted: CGFloat? = nil) {
        self.path = path
        self.fitted = fitted
    }

    public func path(in rect: CGRect) -> Path {
        var transform: CGAffineTransform
        if let fitted {
            let box = path.boundingBoxOfPath
            guard box.width > 0, box.height > 0 else { return Path() }
            let fit = fitted * min(rect.width, rect.height) / max(box.width, box.height)
            transform = CGAffineTransform.identity
                .translatedBy(x: rect.midX, y: rect.midY)
                .scaledBy(x: fit, y: fit)
                .translatedBy(x: -box.midX, y: -box.midY)
        } else {
            transform = CGAffineTransform(scaleX: rect.width, y: rect.height)
                .translatedBy(x: rect.minX, y: rect.minY)
        }
        return Path(path.copy(using: &transform) ?? path)
    }
}
