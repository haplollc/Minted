import SwiftUI

/// A still render of the coin, cached to memory and disk, for showing many
/// coins at once. Shows the flat outline while the render is in flight and
/// fades the gold in once it lands.
public struct CoinThumbnailView: View {
    private let design: CoinDesign
    private let size: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    public init(design: CoinDesign, size: CGFloat = 150) {
        self.design = design
        self.size = size
    }

    public var body: some View {
        ZStack {
            CoinLineArt(design: design, size: size)
                .opacity(image == nil ? 0.35 : 0)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(width: size, height: size)
        .task(id: renderKey) {
            let rendered = await CoinSnapshotter.shared.snapshot(design: design,
                                                                 pixelSize: size * displayScale)
            withAnimation(.easeOut(duration: 0.25)) { image = rendered }
        }
    }

    /// Re-render when the design or the pixel size changes, nothing else.
    private var renderKey: String {
        "\(design.cacheKey)-\(Int(size * displayScale))"
    }
}
