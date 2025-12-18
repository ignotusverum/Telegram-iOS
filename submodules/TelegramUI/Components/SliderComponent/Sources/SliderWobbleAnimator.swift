import UIKit
import simd

/// Spring-based animator for squash & stretch effect with configurable limits
final class SliderWobbleAnimator {

    // MARK: - Limits

    struct Limits {
        var maxWidth: CGFloat = 1.4
        var minWidth: CGFloat = 0.7
        var maxHeight: CGFloat = 1.3
        var minHeight: CGFloat = 0.8

        static let `default` = Limits()

        static let subtle = Limits(
            maxWidth: 1.2,
            minWidth: 0.85,
            maxHeight: 1.15,
            minHeight: 0.9
        )

        static let dramatic = Limits(
            maxWidth: 1.6,
            minWidth: 0.6,
            maxHeight: 1.4,
            minHeight: 0.7
        )
    }

    var limits: Limits = .default

    // MARK: - Output

    /// Normalized velocity for shader (-1 to 1)
    var normalizedVelocity: SIMD2<Float> {
        SIMD2<Float>(
            Float(clampedVelocity.x / maxVelocity),
            Float(clampedVelocity.y / maxVelocity)
        )
    }

    // MARK: - State

    private(set) var velocity: CGPoint = .zero
    private(set) var clampedVelocity: CGPoint = .zero
    private var targetVelocity: CGPoint = .zero
    private var springVelocity: CGPoint = .zero
    private(set) var isActive: Bool = false

    // MARK: - Configuration

    var maxVelocity: CGFloat = 1200.0
    var stiffness: CGFloat = 280.0
    var damping: CGFloat = 22.0
    var threshold: CGFloat = 0.005

    // MARK: - Compatibility

    var isSettled: Bool { !isActive }

    // MARK: - Update

    func update(deltaTime dt: CGFloat) {
        guard isActive else { return }

        // Spring toward target
        let dx = targetVelocity.x - velocity.x
        let dy = targetVelocity.y - velocity.y

        let ax = stiffness * dx - damping * springVelocity.x
        let ay = stiffness * dy - damping * springVelocity.y

        springVelocity.x += ax * dt
        springVelocity.y += ay * dt

        velocity.x += springVelocity.x * dt
        velocity.y += springVelocity.y * dt

        clampedVelocity = clampToLimits(velocity)

        // Check settled
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

    /// Compatibility wrapper
    func update(dt: CGFloat) {
        update(deltaTime: dt)
    }

    // MARK: - Clamping

    private func clampToLimits(_ v: CGPoint) -> CGPoint {
        let deformStrength: CGFloat = 0.4
        let maxVelForWidth = (limits.maxWidth - 1.0) / deformStrength * maxVelocity
        let minVelForWidth = (limits.minWidth - 1.0) / deformStrength * maxVelocity

        var clamped = v
        clamped.x = max(minVelForWidth, min(maxVelForWidth, v.x))
        clamped.y = max(-maxVelocity, min(maxVelocity, v.y))

        return clamped
    }

    // MARK: - Input

    /// Smoothly track velocity during drag (spring follows target)
    func trackVelocity(_ v: CGPoint) {
        targetVelocity = v
        isActive = true
    }

    func trackVelocity(_ v: CGFloat) {
        trackVelocity(CGPoint(x: v, y: 0))
    }

    /// Instantly set velocity (no spring, for initialization)
    func setVelocity(_ v: CGPoint) {
        velocity = v
        clampedVelocity = clampToLimits(v)
        targetVelocity = velocity
        springVelocity = .zero
        isActive = true
    }

    func release() {
        targetVelocity = .zero
        isActive = true
    }

    func release(withVelocity v: CGPoint) {
        // Keep current velocity, spring back to zero
        targetVelocity = .zero
        isActive = true
    }

    func stop() {
        velocity = .zero
        clampedVelocity = .zero
        targetVelocity = .zero
        springVelocity = .zero
        isActive = false
    }

    // MARK: - Compatibility with old API

    func triggerLift() {
        setVelocity(CGPoint(x: 0, y: -800))
    }

    func triggerDrop() {
        setVelocity(CGPoint(x: 0, y: 600))
    }
}

// MARK: - Pan Gesture

extension SliderWobbleAnimator {

    func handlePan(_ gesture: UIPanGestureRecognizer, in view: UIView) {
        let v = gesture.velocity(in: view)

        switch gesture.state {
        case .began, .changed:
            // Smoothly track velocity during drag
            trackVelocity(v)

        case .ended, .cancelled:
            // Spring back to zero on release
            release(withVelocity: v)

        default:
            break
        }
    }
}
