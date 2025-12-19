import UIKit
import Metal

/// Protocol for views that need backdrop capture for glass effects.
public protocol BackdropClient: AnyObject {
    /// Unique identifier for this client.
    var backdropClientID: UUID { get }

    /// The frame in window coordinates that needs to be captured.
    var captureFrame: CGRect { get }

    /// Padding to add around the capture frame.
    var capturePadding: CGFloat { get }

    /// Whether this client currently needs backdrop capture (e.g., isLifted || isAnimating).
    var needsBackdrop: Bool { get }

    /// The window containing this client.
    var backdropWindow: UIWindow? { get }

    /// Called before capture begins. Client should hide any views that shouldn't appear in the backdrop.
    func prepareForCapture()

    /// Called after capture completes. Client should restore any views that were hidden.
    func restoreAfterCapture()

    /// Called when a new backdrop texture is available.
    /// - Parameters:
    ///   - texture: The captured backdrop texture.
    ///   - unionRect: The union rect of all clients that were captured (in window coordinates).
    ///   - screenScale: The screen scale used for capture.
    func didReceiveBackdrop(_ texture: MTLTexture, unionRect: CGRect, screenScale: CGFloat)
}
