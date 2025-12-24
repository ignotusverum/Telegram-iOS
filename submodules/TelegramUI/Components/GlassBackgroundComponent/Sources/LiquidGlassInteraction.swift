import UIKit

public final class LiquidGlassInteraction: NSObject, UIInteraction {

    public struct Configuration {
        public var pressedScale: CGFloat = 1.15
        public var maxStretchFactor: CGFloat = 0.25
        public var stretchSensitivity: CGFloat = 80.0
        public var springDamping: CGFloat = 0.6
        public var springResponse: CGFloat = 0.35
        public var shimmerEnabled: Bool = true
        public var shimmerOpacity: Float = 0.4
        public var shimmerRadius: CGFloat = 40.0

        public init() {}

        public static var subtle: Configuration {
            var config = Configuration()
            config.pressedScale = 1.02
            return config
        }
    }

    public var configuration: Configuration

    public private(set) weak var view: UIView?

    /// The view to apply transforms to. If nil, uses the view the interaction is attached to.
    public weak var targetView: UIView?

    private var gestureRecognizer: LiquidGlassGestureRecognizer?
    private var shimmerLayer: CAGradientLayer?
    private var initialTouchPoint: CGPoint = .zero
    private var isActive: Bool = false

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        super.init()
    }

    public func willMove(to view: UIView?) {
        if let oldView = self.view {
            gestureRecognizer.map { oldView.removeGestureRecognizer($0) }
            shimmerLayer?.removeFromSuperlayer()
        }
    }

    public func didMove(to view: UIView?) {
        self.view = view

        guard let view = view else { return }

        let gesture = LiquidGlassGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.delegate = self
        view.addGestureRecognizer(gesture)
        self.gestureRecognizer = gesture
    }

    private func ensureShimmerLayer() {
        guard configuration.shimmerEnabled, shimmerLayer == nil, let targetView = effectiveTargetView else { return }
        setupShimmerLayer(for: targetView)
    }

    private func setupShimmerLayer(for view: UIView) {
        let shimmer = CAGradientLayer()
        shimmer.type = .radial
        shimmer.colors = [
            UIColor.white.withAlphaComponent(0.6).cgColor,
            UIColor.white.withAlphaComponent(0.0).cgColor
        ]
        shimmer.locations = [0.0, 1.0]
        shimmer.startPoint = CGPoint(x: 0.5, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1.0, y: 1.0)
        shimmer.opacity = 0
        shimmer.frame = CGRect(
            x: -configuration.shimmerRadius,
            y: -configuration.shimmerRadius,
            width: configuration.shimmerRadius * 2,
            height: configuration.shimmerRadius * 2
        )
        shimmer.cornerRadius = configuration.shimmerRadius

        view.layer.addSublayer(shimmer)
        self.shimmerLayer = shimmer
    }

    private var effectiveTargetView: UIView? {
        return targetView ?? view
    }

    @objc private func handleGesture(_ gesture: LiquidGlassGestureRecognizer) {
        guard let targetView = effectiveTargetView else {
            return
        }

        switch gesture.state {
        case .began:
            handleTouchBegan(gesture, in: targetView)

        case .changed:
            handleTouchMoved(gesture, in: targetView)

        case .ended, .cancelled, .failed:
            handleTouchEnded(in: targetView)

        default:
            break
        }
    }

    private func handleTouchBegan(_ gesture: LiquidGlassGestureRecognizer, in view: UIView) {
        isActive = true
        ensureShimmerLayer()
        initialTouchPoint = gesture.location(in: view)

        // Remove any existing animations
        view.layer.removeAnimation(forKey: "bounceBack")

        let scaleTransform = CATransform3DMakeScale(
            configuration.pressedScale,
            configuration.pressedScale,
            1.0
        )

        UIView.animate(
            withDuration: 0.15,
            delay: 0,
            options: [.curveEaseOut, .allowUserInteraction],
            animations: {
                view.layer.transform = scaleTransform
            }
        )

        // Shimmer appears at center of view on tap
        if configuration.shimmerEnabled, let shimmer = shimmerLayer {
            shimmer.removeAllAnimations()

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shimmer.position = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            shimmer.transform = CATransform3DIdentity
            shimmer.opacity = configuration.shimmerOpacity
            CATransaction.commit()

            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = configuration.shimmerOpacity
            fadeIn.duration = 0.15
            shimmer.add(fadeIn, forKey: "fadeIn")
        }
    }

    private func handleTouchMoved(_ gesture: LiquidGlassGestureRecognizer, in view: UIView) {
        guard isActive else { return }

        let currentPoint = gesture.location(in: view)
        let translation = CGPoint(
            x: currentPoint.x - initialTouchPoint.x,
            y: currentPoint.y - initialTouchPoint.y
        )

        let distance = hypot(translation.x, translation.y)
        // Smooth easing for stretch - asymptotic approach to max
        let normalizedDistance = distance / configuration.stretchSensitivity
        let stretchAmount = configuration.maxStretchFactor * (1.0 - exp(-normalizedDistance))

        let angle = atan2(translation.y, translation.x)

        let stretchX = 1.0 + stretchAmount * abs(cos(angle))
        let stretchY = 1.0 + stretchAmount * abs(sin(angle))

        let volumeCompensation = 1.0 / sqrt(stretchX * stretchY)

        let scaleX = configuration.pressedScale * stretchX * volumeCompensation
        let scaleY = configuration.pressedScale * stretchY * volumeCompensation

        var transform = CATransform3DIdentity
        transform = CATransform3DScale(transform, scaleX, scaleY, 1.0)

        let translateAmount = stretchAmount * 8.0
        transform = CATransform3DTranslate(
            transform,
            translateAmount * cos(angle),
            translateAmount * sin(angle),
            0
        )

        view.layer.transform = transform
    }

    private func handleTouchEnded(in view: UIView) {
        guard isActive else { return }
        isActive = false

        // Use UIView spring animation for better layout integration
        UIView.animate(
            withDuration: 0.5,
            delay: 0,
            usingSpringWithDamping: configuration.springDamping,
            initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState],
            animations: {
                view.layer.transform = CATransform3DIdentity
            }
        )

        // Shimmer fades out with expansion
        if configuration.shimmerEnabled, let shimmer = shimmerLayer {
            shimmer.opacity = 0
            shimmer.transform = CATransform3DMakeScale(1.5, 1.5, 1.0)

            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = configuration.shimmerOpacity
            fadeOut.toValue = 0
            fadeOut.duration = 0.3

            let expand = CABasicAnimation(keyPath: "transform.scale")
            expand.fromValue = 1.0
            expand.toValue = 1.5
            expand.duration = 0.3

            let group = CAAnimationGroup()
            group.animations = [fadeOut, expand]
            group.duration = 0.3

            shimmer.add(group, forKey: "fadeOutExpand")
        }
    }

    public func simulatePress() {
        guard let view = view, let gesture = gestureRecognizer else { return }
        handleTouchBegan(gesture, in: view)
    }

    public func simulateRelease() {
        guard let view = view else { return }
        handleTouchEnded(in: view)
    }
}

extension LiquidGlassInteraction: UIGestureRecognizerDelegate {

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return true
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return false
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return false
    }
}

private class LiquidGlassGestureRecognizer: UIGestureRecognizer {

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .possible {
            state = .began
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .began || state == .changed else { return }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .began || state == .changed else { return }
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .began || state == .changed else { return }
        state = .cancelled
    }

    override func reset() {
        super.reset()
    }
}
