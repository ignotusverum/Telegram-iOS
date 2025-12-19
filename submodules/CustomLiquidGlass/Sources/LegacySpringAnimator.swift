import UIKit

public final class LegacySpringAnimator {

    public private(set) var current: CGPoint = .zero

    public private(set) var velocity: CGPoint = .zero

    public var target: CGPoint = .zero

    public var mass: CGFloat = 1.0

    public var stiffness: CGFloat = 300.0

    public var damping: CGFloat = 20.0

    private var lastTime: CFTimeInterval = 0

    public var isSettled: Bool {
        let displacement = hypot(current.x - target.x, current.y - target.y)
        let speed = hypot(velocity.x, velocity.y)
        return displacement < 0.5 && speed < 0.5
    }

    public var normalizedVelocity: CGPoint {
        let maxSpeed: CGFloat = 500
        return CGPoint(
            x: max(-1, min(1, velocity.x / maxSpeed)),
            y: max(-1, min(1, velocity.y / maxSpeed))
        )
    }

    public init(mass: CGFloat = 1.0, stiffness: CGFloat = 300.0, damping: CGFloat = 20.0) {
        self.mass = mass
        self.stiffness = stiffness
        self.damping = damping
    }

    public func step() {
        let now = CACurrentMediaTime()

        let dt: CGFloat
        if lastTime == 0 {
            dt = 1.0 / 120.0
        } else {
            dt = min(CGFloat(now - lastTime), 1.0 / 30.0)
        }
        lastTime = now

        let displacement = CGPoint(
            x: current.x - target.x,
            y: current.y - target.y
        )

        let springForce = CGPoint(
            x: -stiffness * displacement.x,
            y: -stiffness * displacement.y
        )

        let dampingForce = CGPoint(
            x: -damping * velocity.x,
            y: -damping * velocity.y
        )

        let acceleration = CGPoint(
            x: (springForce.x + dampingForce.x) / mass,
            y: (springForce.y + dampingForce.y) / mass
        )

        velocity.x += acceleration.x * dt
        velocity.y += acceleration.y * dt
        current.x += velocity.x * dt
        current.y += velocity.y * dt
    }

    public func setPosition(_ position: CGPoint, animated: Bool) {
        target = position

        if !animated {
            current = position
            velocity = .zero
            lastTime = 0
        }
    }

    public func addVelocity(_ v: CGPoint) {
        velocity.x += v.x
        velocity.y += v.y
    }

    public func reset() {
        current = .zero
        velocity = .zero
        target = .zero
        lastTime = 0
    }

    public func resetTiming() {
        lastTime = 0
    }
}
