import UIKit
import simd

public final class SpringWobbleAnimator {

    public struct Limits {
        public var maxWidth: CGFloat = 1.4
        public var minWidth: CGFloat = 0.7
        public var maxHeight: CGFloat = 1.3
        public var minHeight: CGFloat = 0.8

        public static let `default` = Limits()

        public static let subtle = Limits(
            maxWidth: 1.2,
            minWidth: 0.85,
            maxHeight: 1.15,
            minHeight: 0.9
        )

        public static let dramatic = Limits(
            maxWidth: 1.6,
            minWidth: 0.6,
            maxHeight: 1.4,
            minHeight: 0.7
        )

        public init(maxWidth: CGFloat = 1.4, minWidth: CGFloat = 0.7, maxHeight: CGFloat = 1.3, minHeight: CGFloat = 0.8) {
            self.maxWidth = maxWidth
            self.minWidth = minWidth
            self.maxHeight = maxHeight
            self.minHeight = minHeight
        }
    }

    public var limits: Limits = .default

    public var normalizedVelocity: SIMD2<Float> {
        SIMD2<Float>(
            Float(clampedVelocity.x / maxVelocity),
            Float(clampedVelocity.y / maxVelocity)
        )
    }

    public private(set) var velocity: CGPoint = .zero
    public private(set) var clampedVelocity: CGPoint = .zero
    private var targetVelocity: CGPoint = .zero
    private var springVelocity: CGPoint = .zero
    public private(set) var isActive: Bool = false

    public var maxVelocity: CGFloat = 1200.0
    public var stiffness: CGFloat = 280.0
    public var damping: CGFloat = 22.0
    public var threshold: CGFloat = 0.005

    public var isSettled: Bool { !isActive }

    public init() {}

    public func update(deltaTime dt: CGFloat) {
        guard isActive else { return }

        let dx = targetVelocity.x - velocity.x
        let dy = targetVelocity.y - velocity.y

        let ax = stiffness * dx - damping * springVelocity.x
        let ay = stiffness * dy - damping * springVelocity.y

        springVelocity.x += ax * dt
        springVelocity.y += ay * dt

        velocity.x += springVelocity.x * dt
        velocity.y += springVelocity.y * dt

        clampedVelocity = clampToLimits(velocity)

        let dist = hypot(velocity.x - targetVelocity.x, velocity.y - targetVelocity.y)
        let speed = hypot(springVelocity.x, springVelocity.y)

        if dist < threshold * maxVelocity && speed < threshold * maxVelocity {
            velocity = targetVelocity
            clampedVelocity = clampToLimits(velocity)
            springVelocity = .zero
            if targetVelocity == .zero {
                isActive = false
            }
        }
    }

    public func update(dt: CGFloat) {
        update(deltaTime: dt)
    }

    private func clampToLimits(_ v: CGPoint) -> CGPoint {
        let deformStrength: CGFloat = 0.4
        let maxVelForWidth = (limits.maxWidth - 1.0) / deformStrength * maxVelocity
        let minVelForWidth = (limits.minWidth - 1.0) / deformStrength * maxVelocity

        var clamped = v
        clamped.x = max(minVelForWidth, min(maxVelForWidth, v.x))
        clamped.y = max(-maxVelocity, min(maxVelocity, v.y))

        return clamped
    }

    public func trackVelocity(_ v: CGPoint) {
        targetVelocity = v
        isActive = true
    }

    public func trackVelocity(_ v: CGFloat) {
        trackVelocity(CGPoint(x: v, y: 0))
    }

    public func setVelocity(_ v: CGPoint) {
        velocity = v
        clampedVelocity = clampToLimits(v)
        targetVelocity = velocity
        springVelocity = .zero
        isActive = true
    }

    public func release() {
        targetVelocity = .zero
        isActive = true
    }

    public func release(withVelocity v: CGPoint) {
        targetVelocity = .zero
        isActive = true
    }

    public func stop() {
        velocity = .zero
        clampedVelocity = .zero
        targetVelocity = .zero
        springVelocity = .zero
        isActive = false
    }

    public func triggerLift() {
        setVelocity(CGPoint(x: 0, y: -800))
    }

    public func triggerDrop() {
        setVelocity(CGPoint(x: 0, y: 600))
    }
}

extension SpringWobbleAnimator {

    public func handlePan(_ gesture: UIPanGestureRecognizer, in view: UIView) {
        let v = gesture.velocity(in: view)

        switch gesture.state {
        case .began, .changed:
            trackVelocity(v)

        case .ended, .cancelled:
            release(withVelocity: v)

        default:
            break
        }
    }
}
