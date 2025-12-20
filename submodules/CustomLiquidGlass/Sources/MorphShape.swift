import Foundation
import CoreGraphics

public struct MorphShape: Equatable {
    public var center: CGPoint
    public var size: CGSize
    public var cornerRadius: CGFloat

    public init(center: CGPoint, size: CGSize, cornerRadius: CGFloat) {
        self.center = center
        self.size = size
        self.cornerRadius = cornerRadius
    }

    public init(frame: CGRect, cornerRadius: CGFloat) {
        self.center = CGPoint(x: frame.midX, y: frame.midY)
        self.size = frame.size
        self.cornerRadius = cornerRadius
    }

    public var frame: CGRect {
        CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    public static func circle(center: CGPoint, radius: CGFloat) -> MorphShape {
        MorphShape(
            center: center,
            size: CGSize(width: radius * 2, height: radius * 2),
            cornerRadius: radius
        )
    }

    public static func pill(center: CGPoint, size: CGSize) -> MorphShape {
        MorphShape(
            center: center,
            size: size,
            cornerRadius: min(size.width, size.height) / 2
        )
    }

    public static func roundedRect(frame: CGRect, cornerRadius: CGFloat) -> MorphShape {
        MorphShape(frame: frame, cornerRadius: cornerRadius)
    }

    public static func roundedRect(center: CGPoint, size: CGSize, cornerRadius: CGFloat) -> MorphShape {
        MorphShape(center: center, size: size, cornerRadius: cornerRadius)
    }

    public func lerp(to other: MorphShape, progress: CGFloat) -> MorphShape {
        MorphShape(
            center: CGPoint(
                x: center.x + (other.center.x - center.x) * progress,
                y: center.y + (other.center.y - center.y) * progress
            ),
            size: CGSize(
                width: size.width + (other.size.width - size.width) * progress,
                height: size.height + (other.size.height - size.height) * progress
            ),
            cornerRadius: cornerRadius + (other.cornerRadius - cornerRadius) * progress
        )
    }

    public func scaled(by scale: CGFloat) -> MorphShape {
        MorphShape(
            center: center,
            size: CGSize(width: size.width * scale, height: size.height * scale),
            cornerRadius: cornerRadius * scale
        )
    }

    public func offset(by delta: CGPoint) -> MorphShape {
        MorphShape(
            center: CGPoint(x: center.x + delta.x, y: center.y + delta.y),
            size: size,
            cornerRadius: cornerRadius
        )
    }
}
