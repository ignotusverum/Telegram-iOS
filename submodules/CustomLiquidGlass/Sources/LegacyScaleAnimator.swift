import UIKit

public final class LegacyScaleAnimator {

    public private(set) var current: CGFloat = 0.0
    public var target: CGFloat = 0.0

    private var velocity: CGFloat = 0.0
    private var lastTime: CFTimeInterval = 0

    public var stiffness: CGFloat = 400.0
    public var damping: CGFloat = 28.0

    public var isSettled: Bool {
        abs(current - target) < 0.001 && abs(velocity) < 0.01
    }

    public init() {}

    public func step() {
        let now = CACurrentMediaTime()

        let dt: CGFloat
        if lastTime == 0 {
            dt = 1.0 / 120.0
        } else {
            dt = min(CGFloat(now - lastTime), 1.0 / 30.0)
        }
        lastTime = now

        let displacement = current - target
        let springForce = -stiffness * displacement
        let dampingForce = -damping * velocity
        let acceleration = springForce + dampingForce

        velocity += acceleration * dt
        current += velocity * dt
    }

    public func setValue(_ value: CGFloat, animated: Bool) {
        target = value
        if !animated {
            current = value
            velocity = 0
            lastTime = 0
        }
    }

    public func reset() {
        current = 0.0
        target = 0.0
        velocity = 0
        lastTime = 0
    }

    public func resetTiming() {
        lastTime = 0
    }
}
