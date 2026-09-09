import Metal
import SceneKit
import UIKit

/// Renders coins to still images off the main thread and caches them, so a
/// grid can show dozens of coins without running dozens of live SceneKit
/// views. Memory cache first, then disk, then a real render.
public final class CoinSnapshotter: @unchecked Sendable {
    public static let shared = CoinSnapshotter()

    private let memory = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "minted.snapshot")
    private let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    private let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("MintedCoins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Bump when the rendered look changes so stale disk renders regenerate.
    private static let version = "v5"

    /// A still render of the coin, `pixelSize` square, from cache when
    /// possible. The key folds in the design fingerprint, the size, and the
    /// renderer version, so any visible change re-renders.
    public func snapshot(design: CoinDesign, pixelSize: CGFloat) async -> UIImage? {
        guard pixelSize > 0 else { return nil }
        let key = "\(design.cacheKey)-\(Int(pixelSize))-\(Self.version)"
        if let cached = memory.object(forKey: key as NSString) { return cached }

        let file = directory.appendingPathComponent("\(key).png")
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
                    memory.setObject(image, forKey: key as NSString)
                    continuation.resume(returning: image)
                    return
                }
                let scene = CoinScene.makeScene(design: design)
                renderer.scene = scene
                let image = renderer.snapshot(atTime: 0,
                                              with: CGSize(width: pixelSize, height: pixelSize),
                                              antialiasingMode: .multisampling4X)
                renderer.scene = nil
                memory.setObject(image, forKey: key as NSString)
                try? image.pngData()?.write(to: file)
                continuation.resume(returning: image)
            }
        }
    }
}
