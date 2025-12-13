import UIKit

final class LegacyWobbleAnimator {

    private(set) var current: CGFloat = 0
    private var target: CGFloat = 0
    private var springVelocity: CGFloat = 0

    var stiffness: CGFloat = 280.0
    var damping: CGFloat = 22.0
    var maxVelocity: CGFloat = 800.0

    var normalizedValue: CGFloat {
        max(-1, min(1, current / maxVelocity))
    }

    var isSettled: Bool {
        abs(current - target) < 1 && abs(springVelocity) < 1
    }

    func update(dt: CGFloat) {
        let dx = target - current
        let ax = stiffness * dx - damping * springVelocity

        springVelocity += ax * dt
        current += springVelocity * dt
    }

    func trackVelocity(_ velocity: CGFloat) {
        target = velocity
    }

    func release() {
        target = 0
    }

    func reset() {
        current = 0
        target = 0
        springVelocity = 0
    }
}
