import UIKit
import Metal
import QuartzCore

/// Coordinates backdrop capture for multiple BackdropClient instances.
/// Uses a shared texture pool to avoid redundant window captures.
public final class BackdropCoordinator {

    public static let shared = BackdropCoordinator()

    private struct WeakClient {
        weak var client: BackdropClient?
    }

    private let device: MTLDevice?
    private lazy var texturePool: DoubleBufferedTexturePool? = {
        guard let device = device else { return nil }
        return DoubleBufferedTexturePool(device: device)
    }()

    private var clients: [UUID: WeakClient] = [:]
    private var needsCapture: Bool = false
    private var lastCaptureTime: CFTimeInterval = 0
    private let throttleInterval: CFTimeInterval = 1.0 / 30.0

    private init() {
        self.device = MTLCreateSystemDefaultDevice()
    }

    /// Registers a client for backdrop capture.
    public func register(_ client: BackdropClient) {
        clients[client.backdropClientID] = WeakClient(client: client)
    }

    /// Unregisters a client from backdrop capture.
    public func unregister(_ client: BackdropClient) {
        clients.removeValue(forKey: client.backdropClientID)
        cleanupStaleClients()
    }

    /// Marks that a capture is needed. Call this when a client's state changes.
    public func setNeedsCapture() {
        needsCapture = true
    }

    /// Performs capture if needed. Call this from the display link.
    public func captureIfNeeded() {
        guard needsCapture else { return }

        // Throttle captures to avoid excessive CPU usage
        let now = CACurrentMediaTime()
        guard now - lastCaptureTime >= throttleInterval else { return }

        capture()
        needsCapture = false
        lastCaptureTime = now
    }

    private func capture() {
        cleanupStaleClients()

        // Get active clients that need backdrop
        let activeClients = clients.values.compactMap { $0.client }.filter { $0.needsBackdrop }
        guard !activeClients.isEmpty else { return }

        // Get the window from the first active client
        guard let window = activeClients.first?.backdropWindow else { return }
        let screenScale = window.screen.scale
        let screenBounds = window.screen.bounds

        // Compute union rect of all capture frames with padding
        var unionRect = CGRect.null
        for client in activeClients {
            let paddedFrame = client.captureFrame.insetBy(
                dx: -client.capturePadding,
                dy: -client.capturePadding
            )
            unionRect = unionRect.union(paddedFrame)
        }

        // Clamp to screen bounds
        unionRect = unionRect.intersection(CGRect(origin: .zero, size: screenBounds.size))
        guard !unionRect.isEmpty && !unionRect.isNull else { return }

        // Prepare clients for capture (hide views)
        for client in activeClients {
            client.prepareForCapture()
        }

        // Get context and render
        guard let texturePool = texturePool,
              let ctx = texturePool.getBackBuffer(size: unionRect.size, scale: screenScale) else {
            // Restore clients even if capture fails
            for client in activeClients {
                client.restoreAfterCapture()
            }
            return
        }

        ctx.saveGState()
        ctx.translateBy(x: -unionRect.origin.x * screenScale, y: -unionRect.origin.y * screenScale)
        ctx.scaleBy(x: screenScale, y: screenScale)
        window.layer.render(in: ctx)
        ctx.restoreGState()

        texturePool.unlockBackBuffer()

        // Restore clients after capture
        for client in activeClients {
            client.restoreAfterCapture()
        }

        // Swap buffers and get texture
        guard let texture = texturePool.swapAndGetTexture() else { return }

        // Notify all active clients
        for client in activeClients {
            client.didReceiveBackdrop(texture, unionRect: unionRect, screenScale: screenScale)
        }
    }

    private func cleanupStaleClients() {
        clients = clients.filter { $0.value.client != nil }
    }
}
