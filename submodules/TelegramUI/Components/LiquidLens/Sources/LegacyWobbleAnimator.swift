import UIKit
import simd

final class LegacyWobbleAnimator {

    private(set) var horizontalValue: CGFloat = 0
    private(set) var verticalValue: CGFloat = 0
    var value: CGFloat { horizontalValue }

    var normalizedVelocity: SIMD2<Float> {
        SIMD2<Float>(Float(horizontalValue), Float(verticalValue))
    }

    var isSettled: Bool {
        abs(horizontalValue) < 0.001 &&
        abs(verticalValue) < 0.001 &&
        abs(velocity.x) < 1.0 &&
        abs(velocity.y) < 1.0
    }

    private var velocity: CGPoint = .zero
    private var targetVelocity: CGPoint = .zero

    var surfaceTension: CGFloat = 180.0
    var viscosity: CGFloat = 12.0
    var inertia: CGFloat = 0.8
    var maxDeform: CGFloat = 0.2
    var velocityScale: CGFloat = 0.0008
    var idleTimeout: CGFloat = 0.3

    private var lastVelocityTrackTime: CFTimeInterval = 0

    func trackVelocity(_ v: CGPoint) {
        targetVelocity = v
        lastVelocityTrackTime = CACurrentMediaTime()
    }

    func trackVelocity(_ v: CGFloat) {
        trackVelocity(CGPoint(x: v, y: 0))
    }

    func release() {
        targetVelocity = .zero
    }

    func triggerLift() {
        velocity.y -= 800
    }

    func triggerDrop() {
        velocity.y += 600
    }

    func reset() {
        horizontalValue = 0
        verticalValue = 0
        velocity = .zero
        targetVelocity = .zero
        lastVelocityTrackTime = 0
    }

    func update(dt: CGFloat) {
        // Auto-release if idle for too long
        if lastVelocityTrackTime > 0 {
            let timeSinceLastTrack = CACurrentMediaTime() - lastVelocityTrackTime
            if timeSinceLastTrack > idleTimeout && targetVelocity != .zero {
                targetVelocity = .zero
            }
        }

        let targetDeform = CGPoint(
            x: clamp(targetVelocity.x * velocityScale, -maxDeform, maxDeform),
            y: clamp(targetVelocity.y * velocityScale, -maxDeform, maxDeform)
        )

        let currentDeform = CGPoint(x: horizontalValue, y: verticalValue)

        let tensionForce = CGPoint(
            x: (targetDeform.x - currentDeform.x) * surfaceTension,
            y: (targetDeform.y - currentDeform.y) * surfaceTension
        )

        let dampingForce = CGPoint(
            x: -velocity.x * viscosity,
            y: -velocity.y * viscosity
        )

        velocity.x += (tensionForce.x + dampingForce.x) * dt / inertia
        velocity.y += (tensionForce.y + dampingForce.y) * dt / inertia

        horizontalValue += velocity.x * dt
        verticalValue += velocity.y * dt

        horizontalValue = clamp(horizontalValue, -maxDeform, maxDeform)
        verticalValue = clamp(verticalValue, -maxDeform, maxDeform)
    }

    private func clamp(_ value: CGFloat, _ min: CGFloat, _ max: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, min), max)
    }
}
