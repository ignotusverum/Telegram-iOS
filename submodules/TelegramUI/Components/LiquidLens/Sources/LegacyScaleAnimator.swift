import UIKit

final class LegacyScaleAnimator {

    private(set) var current: CGFloat = 0.0
    var target: CGFloat = 0.0

    private var velocity: CGFloat = 0.0
    private var lastTime: CFTimeInterval = 0

    var stiffness: CGFloat = 400.0
    var damping: CGFloat = 28.0

    var isSettled: Bool {
        abs(current - target) < 0.001 && abs(velocity) < 0.01
    }

    func step() {
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

    func setValue(_ value: CGFloat, animated: Bool) {
        target = value
        if !animated {
            current = value
            velocity = 0
            lastTime = 0
        }
    }

    func reset() {
        current = 0.0
        target = 0.0
        velocity = 0
        lastTime = 0
    }

    func resetTiming() {
        lastTime = 0
    }
}
