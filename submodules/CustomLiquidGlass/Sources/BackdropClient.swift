import UIKit
import Metal

public protocol BackdropClient: AnyObject {
    var backdropClientID: UUID { get }

    var captureFrame: CGRect { get }

    var capturePadding: CGFloat { get }

    var needsBackdrop: Bool { get }

    var backdropWindow: UIWindow? { get }

    func prepareForCapture()

    func restoreAfterCapture()

    func didReceiveBackdrop(_ texture: MTLTexture, unionRect: CGRect, screenScale: CGFloat)
}
