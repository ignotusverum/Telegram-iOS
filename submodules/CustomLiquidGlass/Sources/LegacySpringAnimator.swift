import UIKit

/// Physics-based spring animator for smooth position movement
public final class LegacySpringAnimator {

    // MARK: - State

    /// Current animated position
    public private(set) var current: CGPoint = .zero

    /// Current velocity
    public private(set) var velocity: CGPoint = .zero

    /// Target position
    public var target: CGPoint = .zero

    // MARK: - Spring Parameters

    /// Mass affects momentum (higher = more inertia)
    public var mass: CGFloat = 1.0

    /// Stiffness affects snap speed (higher = faster return to target)
    public var stiffness: CGFloat = 300.0

    /// Damping affects oscillation (higher = less bounce)
    public var damping: CGFloat = 20.0

    // MARK: - Internal

    private var lastTime: CFTimeInterval = 0

    /// Whether the spring has settled (velocity and displacement below threshold)
    public var isSettled: Bool {
        let displacement = hypot(current.x - target.x, current.y - target.y)
        let speed = hypot(velocity.x, velocity.y)
        return displacement < 0.5 && speed < 0.5
    }

    /// Velocity normalized to -1...1 range for shader slime effect
    public var normalizedVelocity: CGPoint {
        let maxSpeed: CGFloat = 500
        return CGPoint(
            x: max(-1, min(1, velocity.x / maxSpeed)),
            y: max(-1, min(1, velocity.y / maxSpeed))
        )
    }

    // MARK: - Initialization

    public init(mass: CGFloat = 1.0, stiffness: CGFloat = 300.0, damping: CGFloat = 20.0) {
        self.mass = mass
        self.stiffness = stiffness
        self.damping = damping
    }

    // MARK: - Animation

    /// Step the spring simulation forward by one frame
    /// Call this on every frame (CADisplayLink callback)
    public func step() {
        let now = CACurrentMediaTime()

        // Calculate delta time, capped to avoid explosion after long pauses
        let dt: CGFloat
        if lastTime == 0 {
            dt = 1.0 / 120.0
        } else {
            dt = min(CGFloat(now - lastTime), 1.0 / 30.0)
        }
        lastTime = now

        // Spring force: F = -kx - cv
        // Where k = stiffness, c = damping, x = displacement, v = velocity

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

        // Semi-implicit Euler integration (more stable than basic Euler)
        velocity.x += acceleration.x * dt
        velocity.y += acceleration.y * dt
        current.x += velocity.x * dt
        current.y += velocity.y * dt
    }

    /// Set position immediately or animate to it
    /// - Parameters:
    ///   - position: Target position
    ///   - animated: If false, jumps immediately without animation
    public func setPosition(_ position: CGPoint, animated: Bool) {
        target = position

        if !animated {
            current = position
            velocity = .zero
            lastTime = 0
        }
    }

    /// Add impulse velocity (e.g., from gesture release)
    public func addVelocity(_ v: CGPoint) {
        velocity.x += v.x
        velocity.y += v.y
    }

    /// Reset animator state
    public func reset() {
        current = .zero
        velocity = .zero
        target = .zero
        lastTime = 0
    }

    /// Reset timing without affecting position/velocity
    /// Call this when layout changes to prevent stale delta time calculations
    public func resetTiming() {
        lastTime = 0
    }
}
