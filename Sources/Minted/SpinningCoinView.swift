import SceneKit
import SwiftUI

/// The full 3D coin, alive: idles in a slow spin, and a drag flicks it with
/// momentum. Use this where one coin is the hero (a detail sheet, an award
/// moment); for grids of many coins use `CoinThumbnailView`.
public struct SpinningCoinView: UIViewRepresentable {
    private let design: CoinDesign
    private let idlePeriod: Double
    private let initialRotation: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - design: the coin to mint.
    ///   - idlePeriod: seconds per idle revolution; slower reads as heavier.
    ///   - initialRotation: radians around y applied at creation, so hosts
    ///     can present the coin's back (pass .pi) or any starting pose.
    public init(design: CoinDesign, idlePeriod: Double = 11, initialRotation: Double = 0) {
        self.design = design
        self.idlePeriod = idlePeriod
        self.initialRotation = initialRotation
    }

    public func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        mint(into: view, coordinator: context.coordinator)

        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.pan(_:)))
        view.addGestureRecognizer(pan)
        return view
    }

    public func updateUIView(_ view: SCNView, context: Context) {
        // Re-mint only when the design actually changed, so unrelated
        // SwiftUI updates never interrupt a spin in progress.
        if context.coordinator.designKey != design.cacheKey {
            mint(into: view, coordinator: context.coordinator)
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    private func mint(into view: SCNView, coordinator: Coordinator) {
        view.scene = CoinScene.makeScene(design: design)
        coordinator.designKey = design.cacheKey
        coordinator.idlePeriod = idlePeriod
        coordinator.coin = view.scene?.rootNode.childNode(withName: CoinScene.coinNodeName,
                                                          recursively: true)
        coordinator.coin?.eulerAngles.y = Float(initialRotation)
        if !reduceMotion {
            coordinator.coin?.runAction(
                .repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: idlePeriod)),
                forKey: "idle")
        }
    }

    public final class Coordinator: NSObject {
        var coin: SCNNode?
        var designKey: String?
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
                let translation = gesture.translation(in: view)
                coin.eulerAngles.y += Float(translation.x) * 0.012
                gesture.setTranslation(.zero, in: view)
            case .ended, .cancelled:
                let velocity = gesture.velocity(in: view).x
                let spin = SCNAction.rotateBy(x: 0, y: CGFloat(velocity) * 0.0022, z: 0,
                                              duration: 1.4)
                spin.timingMode = .easeOut
                let period = idlePeriod
                coin.runAction(spin, forKey: "momentum") { [weak self, weak coin] in
                    guard let self, self.idleWasRunning, let coin else { return }
                    coin.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0,
                                                            duration: period)),
                                   forKey: "idle")
                }
            default:
                break
            }
        }
    }
}
